use std::{env, sync::Arc, time::Duration};

use anyhow::{bail, Context, Result};
use russh::{
    client,
    keys::{load_secret_key, PrivateKeyWithHashAlg},
};
use russh_sftp::{client::SftpSession, protocol::OpenFlags};
use tokio::io::AsyncWriteExt;

const COMPLETE: &[u8] = b"LEANTTY-SFTP-COMPLETE";
const INCOMING: &[u8] = b"LEANTTY-SFTP-INCOMING";
const EXISTING: &[u8] = b"LEANTTY-SFTP-EXISTING";

struct ControlledLocalhostClient;

impl client::Handler for ControlledLocalhostClient {
    type Error = anyhow::Error;

    async fn check_server_key(
        &mut self,
        _server_public_key: &russh::keys::ssh_key::PublicKey,
    ) -> Result<bool, Self::Error> {
        // test-e2e.sh owns the ephemeral localhost sshd and its host key.
        Ok(true)
    }
}

async fn create_exclusive(sftp: &SftpSession, path: &str, content: &[u8]) -> Result<()> {
    let mut file = sftp
        .open_with_flags(
            path,
            OpenFlags::CREATE | OpenFlags::EXCLUDE | OpenFlags::WRITE,
        )
        .await
        .with_context(|| format!("exclusive SFTP open failed for {path}"))?;
    file.write_all(content).await?;
    file.close().await?;
    Ok(())
}

async fn remove_if_present(sftp: &SftpSession, path: &str) {
    if sftp.try_exists(path).await.unwrap_or(false) {
        let _ = sftp.remove_file(path).await;
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    if args.len() != 6 {
        bail!("usage: fixture <host> <port> <user> <private-key> <remote-directory>");
    }
    let host = args[1].as_str();
    let port: u16 = args[2].parse().context("invalid SSH port")?;
    let user = args[3].as_str();
    let private_key = load_secret_key(&args[4], None).context("load fixture private key")?;
    let root = args[5].trim_end_matches('/');

    let config = client::Config {
        inactivity_timeout: Some(Duration::from_secs(10)),
        ..Default::default()
    };
    let mut ssh = client::connect(Arc::new(config), (host, port), ControlledLocalhostClient)
        .await
        .context("connect to controlled OpenSSH fixture")?;
    let auth = ssh
        .authenticate_publickey(
            user,
            PrivateKeyWithHashAlg::new(
                Arc::new(private_key),
                ssh.best_supported_rsa_hash().await?.flatten(),
            ),
        )
        .await?;
    if !auth.success() {
        bail!("controlled OpenSSH public-key authentication failed");
    }

    let channel = ssh.channel_open_session().await?;
    channel.request_subsystem(true, "sftp").await?;
    let sftp = SftpSession::new(channel.into_stream()).await?;

    let success_temp = format!("{root}/success.part");
    let success_final = format!("{root}/success.final");
    let conflict_temp = format!("{root}/conflict.part");
    let conflict_final = format!("{root}/conflict.final");
    for path in [
        &success_temp,
        &success_final,
        &conflict_temp,
        &conflict_final,
    ] {
        remove_if_present(&sftp, path).await;
    }

    let result = async {
        create_exclusive(&sftp, &success_temp, COMPLETE).await?;
        sftp.rename(&success_temp, &success_final).await?;
        if sftp.read(&success_final).await? != COMPLETE {
            bail!("successful standard rename changed the complete content");
        }

        create_exclusive(&sftp, &conflict_temp, INCOMING).await?;
        if sftp.try_exists(&conflict_final).await? {
            bail!("conflict target unexpectedly existed before simulated claim");
        }
        create_exclusive(&sftp, &conflict_final, EXISTING).await?;

        let exclusive_rejected = create_exclusive(&sftp, &conflict_final, b"REPLACE")
            .await
            .is_err();
        let rename_rejected = sftp.rename(&conflict_temp, &conflict_final).await.is_err();
        if !exclusive_rejected || !rename_rejected {
            bail!("OpenSSH accepted an exclusive open or standard rename conflict");
        }
        if sftp.read(&conflict_final).await? != EXISTING
            || sftp.read(&conflict_temp).await? != INCOMING
        {
            bail!("conflict changed the existing target or owned temporary file");
        }
        Ok::<(), anyhow::Error>(())
    }
    .await;

    for path in [
        &success_temp,
        &success_final,
        &conflict_temp,
        &conflict_final,
    ] {
        remove_if_present(&sftp, path).await;
    }
    let cleanup_complete = !sftp.try_exists(&success_temp).await?
        && !sftp.try_exists(&success_final).await?
        && !sftp.try_exists(&conflict_temp).await?
        && !sftp.try_exists(&conflict_final).await?;
    sftp.close().await?;
    result?;
    if !cleanup_complete {
        bail!("fixture cleanup left an owned remote path");
    }

    println!(
        "SFTP_INTEROP passed=true,exclusiveCreate=true,standardRename=true,\
         conflictPreserved=true,cleanupComplete=true"
    );
    Ok(())
}
