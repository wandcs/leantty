use std::fs::File as StdFile;
use std::future::Future;
use std::time::{Duration, Instant};

use russh_sftp::client::{error::Error as SftpError, SftpSession};
use russh_sftp::protocol::{OpenFlags, StatusCode};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

const COPY_BUFFER_SIZE: usize = 64 * 1024;
const PROGRESS_INTERVAL: Duration = Duration::from_millis(200);
const SFTP_OPERATION_TIMEOUT: Duration = Duration::from_secs(30);

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

enum OperationWait<T, E> {
    Completed(Result<T, E>),
    Cancelled,
    TimedOut,
}

async fn wait_for_operation<F, T, E>(
    operation: F,
    timeout: Duration,
    disconnect_rx: &mut tokio::sync::mpsc::Receiver<()>,
) -> OperationWait<T, E>
where
    F: Future<Output = Result<T, E>>,
{
    tokio::select! {
        biased;
        _ = disconnect_rx.recv() => OperationWait::Cancelled,
        result = operation => OperationWait::Completed(result),
        _ = tokio::time::sleep(timeout) => OperationWait::TimedOut,
    }
}

pub(crate) async fn bounded_operation<F, T, E>(
    operation: F,
    disconnect_rx: &mut tokio::sync::mpsc::Receiver<()>,
    code: &'static str,
    context: &str,
) -> Result<T, TransferFailure>
where
    F: Future<Output = Result<T, E>>,
    E: std::fmt::Display,
{
    match wait_for_operation(operation, SFTP_OPERATION_TIMEOUT, disconnect_rx).await {
        OperationWait::Completed(Ok(value)) => Ok(value),
        OperationWait::Completed(Err(error)) => Err(TransferFailure::io(code, context, error)),
        OperationWait::Cancelled => Err(TransferFailure::Cancelled),
        OperationWait::TimedOut => Err(TransferFailure::Failed {
            code: "SFTP_TIMEOUT",
            detail: format!("{context} timed out"),
        }),
    }
}

fn remote_temp_path(remote_path: &str, transfer_id: u32, nonce: u64) -> String {
    let directory = match remote_path.rsplit_once('/') {
        Some(("", _)) => "/",
        Some((directory, _)) => directory,
        None => "",
    };
    let temp_name = format!(".leantty-{transfer_id}-{nonce:016x}.part");
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
    disconnect_rx: &mut tokio::sync::mpsc::Receiver<()>,
) -> Result<Option<russh_sftp::client::fs::Metadata>, TransferFailure> {
    let result = wait_for_operation(
        sftp.symlink_metadata(path),
        SFTP_OPERATION_TIMEOUT,
        disconnect_rx,
    )
    .await;
    match result {
        OperationWait::Cancelled => Err(TransferFailure::Cancelled),
        OperationWait::TimedOut => Err(TransferFailure::Failed {
            code: "SFTP_TIMEOUT",
            detail: "remote metadata check timed out".to_string(),
        }),
        OperationWait::Completed(Ok(metadata)) => Ok(Some(metadata)),
        OperationWait::Completed(Err(SftpError::Status(status)))
            if status.status_code == StatusCode::NoSuchFile =>
        {
            Ok(None)
        }
        OperationWait::Completed(Err(error)) => Err(TransferFailure::io(
            "REMOTE_METADATA",
            "remote metadata check failed",
            error,
        )),
    }
}

async fn copy_with_cancel<R, W, F>(
    source: &mut R,
    destination: &mut W,
    expected_bytes: Option<u64>,
    read_failure_code: &'static str,
    disconnect_rx: &mut tokio::sync::mpsc::Receiver<()>,
    mut progress: F,
) -> Result<u64, TransferFailure>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
    F: FnMut(u64, u64),
{
    let total_bytes = expected_bytes.unwrap_or(0);
    let mut buffer = vec![0_u8; COPY_BUFFER_SIZE];
    let mut transferred = 0_u64;
    let mut last_progress = Instant::now();
    loop {
        let count = tokio::select! {
            biased;
            _ = disconnect_rx.recv() => return Err(TransferFailure::Cancelled),
            result = source.read(&mut buffer) => result.map_err(|error| {
                TransferFailure::io(read_failure_code, "file read failed", error)
            })?,
        };
        if count == 0 {
            if let Some(expected) = expected_bytes {
                if transferred != expected {
                    return Err(TransferFailure::Failed {
                        code: "SOURCE_CHANGED",
                        detail: format!(
                            "source size changed during transfer: copied {transferred} of {expected} bytes"
                        ),
                    });
                }
            }
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
            if let Some(metadata) = lstat_optional(sftp, remote_path, disconnect_rx).await? {
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
            let mut remote_file = bounded_operation(
                sftp.open_with_flags(
                    temp_path.clone(),
                    OpenFlags::CREATE | OpenFlags::EXCLUDE | OpenFlags::WRITE,
                ),
                disconnect_rx,
                "REMOTE_TEMP_CREATE",
                "exclusive remote temporary file creation failed",
            )
            .await?;
            let mut local_file = tokio::fs::File::from_std(local_file);
            let copied = copy_with_cancel(
                &mut local_file,
                &mut remote_file,
                Some(total_bytes),
                "READ",
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
            let close_result = bounded_operation(
                remote_file.close(),
                disconnect_rx,
                "REMOTE_CLOSE",
                "remote temporary file close failed",
            )
            .await;
            let result = match (copied, close_result) {
                (Ok(bytes), Ok(())) => match bounded_operation(
                    sftp.rename(&temp_path, remote_path),
                    disconnect_rx,
                    "REMOTE_COMMIT",
                    "no-replace remote commit failed",
                )
                .await
                {
                    Ok(()) => Ok((bytes, total_bytes)),
                    Err(TransferFailure::Failed {
                        code: "REMOTE_COMMIT",
                        detail,
                    }) => match lstat_optional(sftp, remote_path, disconnect_rx).await {
                        Ok(Some(_)) => Err(TransferFailure::Failed {
                            code: "REMOTE_CONFLICT",
                            detail: "remote target was claimed before commit".to_string(),
                        }),
                        _ => Err(TransferFailure::Failed {
                            code: "REMOTE_COMMIT",
                            detail,
                        }),
                    },
                    Err(error) => Err(error),
                },
                (Err(error), _) => Err(error),
                (Ok(_), Err(error)) => Err(error),
            };
            if result.is_err() {
                match tokio::time::timeout(SFTP_OPERATION_TIMEOUT, sftp.remove_file(&temp_path))
                    .await
                {
                    Err(_) => {
                        return Err(TransferFailure::Failed {
                            code: "REMOTE_CLEANUP",
                            detail: "remote temporary file cleanup timed out".to_string(),
                        });
                    }
                    Ok(Ok(())) => {}
                    Ok(Err(SftpError::Status(status)))
                        if status.status_code == StatusCode::NoSuchFile => {}
                    Ok(Err(error)) => {
                        return Err(TransferFailure::io(
                            "REMOTE_CLEANUP",
                            "remote temporary file cleanup failed",
                            error,
                        ));
                    }
                }
            }
            result
        }
        Direction::Get => {
            let metadata = lstat_optional(sftp, remote_path, disconnect_rx)
                .await?
                .ok_or_else(|| TransferFailure::Failed {
                    code: "REMOTE_NOT_FOUND",
                    detail: "remote source does not exist".to_string(),
                })?;
            if metadata.is_symlink() || !metadata.is_regular() {
                return Err(TransferFailure::Failed {
                    code: "REMOTE_PATH",
                    detail:
                        "remote source must be a regular file, not a directory or symbolic link"
                            .to_string(),
                });
            }
            let mut remote_file = bounded_operation(
                sftp.open(remote_path),
                disconnect_rx,
                "REMOTE_OPEN",
                "remote source open failed",
            )
            .await?;
            let opened_metadata = bounded_operation(
                remote_file.metadata(),
                disconnect_rx,
                "REMOTE_METADATA",
                "opened remote file fstat failed",
            )
            .await?;
            if !opened_metadata.is_regular() {
                return Err(TransferFailure::Failed {
                    code: "REMOTE_PATH",
                    detail: "opened remote source is not a regular file".to_string(),
                });
            }
            let expected_bytes = opened_metadata.size;
            let total_bytes = expected_bytes.unwrap_or(0);
            update(TransferUpdate::Progress {
                transferred: 0,
                total: total_bytes,
            });
            let mut local_file = tokio::fs::File::from_std(local_file);
            let copied = copy_with_cancel(
                &mut remote_file,
                &mut local_file,
                expected_bytes,
                "NETWORK",
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
            let remote_close = bounded_operation(
                remote_file.close(),
                disconnect_rx,
                "REMOTE_CLOSE",
                "remote source close failed",
            )
            .await;
            let result = match (copied, remote_close) {
                (Ok(bytes), Ok(())) => {
                    bounded_operation(
                        local_file.flush(),
                        disconnect_rx,
                        "LOCAL_FLUSH",
                        "local temporary file flush failed",
                    )
                    .await?;
                    bounded_operation(
                        local_file.sync_all(),
                        disconnect_rx,
                        "LOCAL_SYNC",
                        "local temporary file sync failed",
                    )
                    .await?;
                    Ok((bytes, total_bytes))
                }
                (Err(error), _) => Err(error),
                (Ok(_), Err(error)) => Err(error),
            };
            result
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        copy_with_cancel, remote_temp_path, wait_for_operation, OperationWait, TransferFailure,
    };
    use std::time::Duration;
    use std::{
        io,
        pin::Pin,
        task::{Context, Poll},
    };
    use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

    struct FailingReader;

    struct DiskFullWriter;

    impl AsyncRead for FailingReader {
        fn poll_read(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
            _buffer: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            Poll::Ready(Err(io::Error::new(
                io::ErrorKind::ConnectionReset,
                "controlled disconnect",
            )))
        }
    }

    impl AsyncWrite for DiskFullWriter {
        fn poll_write(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
            _buffer: &[u8],
        ) -> Poll<io::Result<usize>> {
            Poll::Ready(Err(io::Error::from_raw_os_error(28)))
        }

        fn poll_flush(self: Pin<&mut Self>, _context: &mut Context<'_>) -> Poll<io::Result<()>> {
            Poll::Ready(Ok(()))
        }

        fn poll_shutdown(self: Pin<&mut Self>, _context: &mut Context<'_>) -> Poll<io::Result<()>> {
            Poll::Ready(Ok(()))
        }
    }

    #[test]
    fn temporary_paths_stay_in_the_remote_target_directory() {
        assert_eq!(
            remote_temp_path("/srv/files/report.txt", 7, 1),
            "/srv/files/.leantty-7-0000000000000001.part"
        );
        assert_eq!(
            remote_temp_path("report.txt", 8, 2),
            ".leantty-8-0000000000000002.part"
        );
        assert_eq!(
            remote_temp_path("/report.txt", 9, 3),
            "/.leantty-9-0000000000000003.part"
        );
    }

    #[test]
    fn temporary_name_does_not_grow_with_the_remote_basename() {
        let basename = format!("{}.bin", "l".repeat(251));
        assert_eq!(basename.len(), 255);
        assert_eq!(
            remote_temp_path(&format!("/srv/files/{basename}"), u32::MAX, u64::MAX),
            "/srv/files/.leantty-4294967295-ffffffffffffffff.part"
        );
    }

    #[tokio::test]
    async fn operation_wait_honors_cancellation_outside_the_copy_loop() {
        let (disconnect_tx, mut disconnect_rx) = tokio::sync::mpsc::channel(1);
        disconnect_tx.send(()).await.unwrap();
        let pending = std::future::pending::<Result<(), std::io::Error>>();
        assert!(matches!(
            wait_for_operation(pending, Duration::from_secs(1), &mut disconnect_rx).await,
            OperationWait::Cancelled
        ));
    }

    #[tokio::test]
    async fn operation_wait_times_out_outside_the_copy_loop() {
        let (_disconnect_tx, mut disconnect_rx) = tokio::sync::mpsc::channel(1);
        let pending = std::future::pending::<Result<(), std::io::Error>>();
        assert!(matches!(
            wait_for_operation(pending, Duration::from_millis(1), &mut disconnect_rx).await,
            OperationWait::TimedOut
        ));
    }

    #[tokio::test]
    async fn copy_rejects_source_eof_before_the_known_size() {
        let mut source: &[u8] = b"short";
        let mut destination = tokio::io::sink();
        let (_disconnect_tx, mut disconnect_rx) = tokio::sync::mpsc::channel(1);

        let result = copy_with_cancel(
            &mut source,
            &mut destination,
            Some(8),
            "READ",
            &mut disconnect_rx,
            |_, _| {},
        )
        .await;

        assert!(matches!(
            result,
            Err(TransferFailure::Failed {
                code: "SOURCE_CHANGED",
                ..
            })
        ));
    }

    #[tokio::test]
    async fn copy_uses_the_direction_specific_read_failure_code() {
        let mut source = FailingReader;
        let mut destination = tokio::io::sink();
        let (_disconnect_tx, mut disconnect_rx) = tokio::sync::mpsc::channel(1);

        let result = copy_with_cancel(
            &mut source,
            &mut destination,
            Some(8),
            "NETWORK",
            &mut disconnect_rx,
            |_, _| {},
        )
        .await;

        assert!(matches!(
            result,
            Err(TransferFailure::Failed {
                code: "NETWORK",
                ..
            })
        ));
    }

    #[tokio::test]
    async fn copy_maps_disk_full_to_a_write_failure_without_reporting_progress() {
        let mut source: &[u8] = b"content";
        let mut destination = DiskFullWriter;
        let (_disconnect_tx, mut disconnect_rx) = tokio::sync::mpsc::channel(1);
        let mut progress_events = 0;

        let result = copy_with_cancel(
            &mut source,
            &mut destination,
            Some(7),
            "NETWORK",
            &mut disconnect_rx,
            |_, _| progress_events += 1,
        )
        .await;

        match result {
            Err(TransferFailure::Failed { code, detail }) => {
                assert_eq!(code, "WRITE");
                assert!(detail.contains("No space left on device"));
            }
            other => panic!("expected WRITE failure, got {other:?}"),
        }
        assert_eq!(progress_events, 0);
    }
}
