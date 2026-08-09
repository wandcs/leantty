use std::fs::File as StdFile;
use std::time::{Duration, Instant};

use russh_sftp::client::{error::Error as SftpError, SftpSession};
use russh_sftp::protocol::{OpenFlags, StatusCode};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

const COPY_BUFFER_SIZE: usize = 64 * 1024;
const PROGRESS_INTERVAL: Duration = Duration::from_millis(200);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Direction {
    Put,
    Get,
}

#[derive(Debug, Eq, PartialEq)]
pub(crate) enum TransferFailure {
    Cancelled,
    Failed { code: &'static str, detail: String },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum TransferUpdate {
    Progress { transferred: u64, total: u64 },
    Finalizing { transferred: u64, total: u64 },
}

impl TransferFailure {
    fn io(code: &'static str, context: &str, error: impl std::fmt::Display) -> Self {
        Self::Failed {
            code,
            detail: format!("{context}: {error}"),
        }
    }
}

fn remote_temp_path(remote_path: &str, transfer_id: u32, nonce: u64) -> String {
    let (directory, basename) = match remote_path.rsplit_once('/') {
        Some(("", basename)) => ("/", basename),
        Some((directory, basename)) => (directory, basename),
        None => ("", remote_path),
    };
    let temp_name = format!(".{basename}.leantty-{transfer_id}-{nonce:016x}.part");
    if directory.is_empty() {
        temp_name
    } else if directory == "/" {
        format!("/{temp_name}")
    } else {
        format!("{directory}/{temp_name}")
    }
}

async fn lstat_optional(
    sftp: &SftpSession,
    path: &str,
) -> Result<Option<russh_sftp::client::fs::Metadata>, TransferFailure> {
    match sftp.symlink_metadata(path).await {
        Ok(metadata) => Ok(Some(metadata)),
        Err(SftpError::Status(status)) if status.status_code == StatusCode::NoSuchFile => Ok(None),
        Err(error) => Err(TransferFailure::io(
            "REMOTE_METADATA",
            "remote metadata check failed",
            error,
        )),
    }
}

async fn copy_with_cancel<R, W, F>(
    source: &mut R,
    destination: &mut W,
    total_bytes: u64,
    disconnect_rx: &mut tokio::sync::mpsc::Receiver<()>,
    mut progress: F,
) -> Result<u64, TransferFailure>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
    F: FnMut(u64, u64),
{
    let mut buffer = vec![0_u8; COPY_BUFFER_SIZE];
    let mut transferred = 0_u64;
    let mut last_progress = Instant::now();
    loop {
        let count = tokio::select! {
            biased;
            _ = disconnect_rx.recv() => return Err(TransferFailure::Cancelled),
            result = source.read(&mut buffer) => result.map_err(|error| {
                TransferFailure::io("READ", "file read failed", error)
            })?,
        };
        if count == 0 {
            break;
        }
        tokio::select! {
            biased;
            _ = disconnect_rx.recv() => return Err(TransferFailure::Cancelled),
            result = destination.write_all(&buffer[..count]) => result.map_err(|error| {
                TransferFailure::io("WRITE", "file write failed", error)
            })?,
        }
        transferred += count as u64;
        if last_progress.elapsed() >= PROGRESS_INTERVAL {
            progress(transferred, total_bytes);
            last_progress = Instant::now();
        }
    }
    progress(transferred, total_bytes);
    Ok(transferred)
}

pub(crate) async fn execute<F>(
    sftp: &SftpSession,
    direction: Direction,
    remote_path: &str,
    local_file: StdFile,
    transfer_id: u32,
    disconnect_rx: &mut tokio::sync::mpsc::Receiver<()>,
    mut update: F,
) -> Result<(u64, u64), TransferFailure>
where
    F: FnMut(TransferUpdate),
{
    match direction {
        Direction::Put => {
            let total_bytes = local_file
                .metadata()
                .map_err(|error| {
                    TransferFailure::io("LOCAL_METADATA", "local source fstat failed", error)
                })?
                .len();
            update(TransferUpdate::Progress {
                transferred: 0,
                total: total_bytes,
            });
            if let Some(metadata) = lstat_optional(sftp, remote_path).await? {
                let (code, detail) = if metadata.is_dir() {
                    (
                        "REMOTE_PATH",
                        "remote target is a directory; add / to upload using the local file name",
                    )
                } else {
                    ("REMOTE_CONFLICT", "remote target already exists")
                };
                return Err(TransferFailure::Failed {
                    code,
                    detail: detail.to_string(),
                });
            }
            let temp_path = remote_temp_path(remote_path, transfer_id, rand::random());
            let mut remote_file = sftp
                .open_with_flags(
                    temp_path.clone(),
                    OpenFlags::CREATE | OpenFlags::EXCLUDE | OpenFlags::WRITE,
                )
                .await
                .map_err(|error| {
                    TransferFailure::io(
                        "REMOTE_TEMP_CREATE",
                        "exclusive remote temporary file creation failed",
                        error,
                    )
                })?;
            let mut local_file = tokio::fs::File::from_std(local_file);
            let copied = copy_with_cancel(
                &mut local_file,
                &mut remote_file,
                total_bytes,
                disconnect_rx,
                |transferred, total| {
                    update(TransferUpdate::Progress { transferred, total });
                },
            )
            .await;
            if let Ok(bytes) = &copied {
                update(TransferUpdate::Finalizing {
                    transferred: *bytes,
                    total: total_bytes,
                });
            }
            let close_result = remote_file.close().await;
            let result = match (copied, close_result) {
                (Ok(bytes), Ok(())) => match sftp.rename(&temp_path, remote_path).await {
                    Ok(()) => Ok((bytes, total_bytes)),
                    Err(error) => match lstat_optional(sftp, remote_path).await {
                        Ok(Some(_)) => Err(TransferFailure::Failed {
                            code: "REMOTE_CONFLICT",
                            detail: "remote target was claimed before commit".to_string(),
                        }),
                        _ => Err(TransferFailure::io(
                            "REMOTE_COMMIT",
                            "no-replace remote commit failed",
                            error,
                        )),
                    },
                },
                (Err(error), _) => Err(error),
                (Ok(_), Err(error)) => Err(TransferFailure::io(
                    "REMOTE_CLOSE",
                    "remote temporary file close failed",
                    error,
                )),
            };
            if result.is_err() {
                let _ = sftp.remove_file(&temp_path).await;
            }
            result
        }
        Direction::Get => {
            let metadata = lstat_optional(sftp, remote_path).await?.ok_or_else(|| {
                TransferFailure::Failed {
                    code: "REMOTE_NOT_FOUND",
                    detail: "remote source does not exist".to_string(),
                }
            })?;
            if metadata.is_symlink() || !metadata.is_regular() {
                return Err(TransferFailure::Failed {
                    code: "REMOTE_PATH",
                    detail:
                        "remote source must be a regular file, not a directory or symbolic link"
                            .to_string(),
                });
            }
            let mut remote_file = sftp.open(remote_path).await.map_err(|error| {
                TransferFailure::io("REMOTE_OPEN", "remote source open failed", error)
            })?;
            let opened_metadata = remote_file.metadata().await.map_err(|error| {
                TransferFailure::io("REMOTE_METADATA", "opened remote file fstat failed", error)
            })?;
            if !opened_metadata.is_regular() {
                return Err(TransferFailure::Failed {
                    code: "REMOTE_PATH",
                    detail: "opened remote source is not a regular file".to_string(),
                });
            }
            let total_bytes = opened_metadata.size.unwrap_or(0);
            update(TransferUpdate::Progress {
                transferred: 0,
                total: total_bytes,
            });
            let mut local_file = tokio::fs::File::from_std(local_file);
            let copied = copy_with_cancel(
                &mut remote_file,
                &mut local_file,
                total_bytes,
                disconnect_rx,
                |transferred, total| {
                    update(TransferUpdate::Progress { transferred, total });
                },
            )
            .await;
            if let Ok(bytes) = &copied {
                update(TransferUpdate::Finalizing {
                    transferred: *bytes,
                    total: total_bytes,
                });
            }
            let remote_close = remote_file.close().await;
            let result = match (copied, remote_close) {
                (Ok(bytes), Ok(())) => {
                    local_file.flush().await.map_err(|error| {
                        TransferFailure::io(
                            "LOCAL_FLUSH",
                            "local temporary file flush failed",
                            error,
                        )
                    })?;
                    local_file.sync_all().await.map_err(|error| {
                        TransferFailure::io("LOCAL_SYNC", "local temporary file sync failed", error)
                    })?;
                    Ok((bytes, total_bytes))
                }
                (Err(error), _) => Err(error),
                (Ok(_), Err(error)) => Err(TransferFailure::io(
                    "REMOTE_CLOSE",
                    "remote source close failed",
                    error,
                )),
            };
            result
        }
    }
}

#[cfg(test)]
mod tests {
    use super::remote_temp_path;

    #[test]
    fn temporary_paths_stay_in_the_remote_target_directory() {
        assert_eq!(
            remote_temp_path("/srv/files/report.txt", 7, 1),
            "/srv/files/.report.txt.leantty-7-0000000000000001.part"
        );
        assert_eq!(
            remote_temp_path("report.txt", 8, 2),
            ".report.txt.leantty-8-0000000000000002.part"
        );
        assert_eq!(
            remote_temp_path("/report.txt", 9, 3),
            "/.report.txt.leantty-9-0000000000000003.part"
        );
    }
}
