use std::error::Error;
use std::io;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use russh::client;
use russh::keys::{Algorithm, HashAlg, PrivateKey, PublicKey};
use russh::server::{self, Auth, Handler, Msg, Server as _, Session};
use russh::{Channel, ChannelMsg, ChannelOpenFailure, Disconnect};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio::time::timeout;

const JUMP_USER: &str = "jump-user";
const JUMP_PASSWORD: &str = "jump-password";
const TARGET_USER: &str = "target-user";
const TARGET_PASSWORD: &str = "target-password";
const PROBE: &[u8] = b"proxy-jump-probe";
const RESPONSE: &[u8] = b"target:proxy-jump-probe";
const TEST_TIMEOUT: Duration = Duration::from_secs(10);

type TestResult<T = ()> = Result<T, Box<dyn Error + Send + Sync>>;

#[derive(Debug, Eq, PartialEq)]
struct HostKeyEvent {
    layer: &'static str,
    fingerprint: String,
}

struct AcceptHostKey {
    layer: &'static str,
    event_tx: mpsc::UnboundedSender<HostKeyEvent>,
}

impl client::Handler for AcceptHostKey {
    type Error = russh::Error;

    async fn check_server_key(&mut self, key: &PublicKey) -> Result<bool, Self::Error> {
        let _ = self.event_tx.send(HostKeyEvent {
            layer: self.layer,
            fingerprint: key.fingerprint(HashAlg::Sha256).to_string(),
        });
        Ok(true)
    }
}

#[derive(Clone)]
struct TargetServer;

impl server::Server for TargetServer {
    type Handler = Self;

    fn new_client(&mut self, _: Option<SocketAddr>) -> Self::Handler {
        self.clone()
    }
}

impl Handler for TargetServer {
    type Error = russh::Error;

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
        Ok(if user == TARGET_USER && password == TARGET_PASSWORD {
            Auth::Accept
        } else {
            Auth::reject()
        })
    }

    async fn channel_open_session(
        &mut self,
        mut channel: Channel<Msg>,
        reply: server::ChannelOpenHandle,
        _: &mut Session,
    ) -> Result<(), Self::Error> {
        reply.accept().await;
        tokio::spawn(async move {
            let mut probe = Vec::with_capacity(PROBE.len());
            while let Some(message) = channel.wait().await {
                match message {
                    ChannelMsg::Data { data } => {
                        probe.extend_from_slice(&data);
                        if probe.len() >= PROBE.len() {
                            if probe == PROBE {
                                let _ = channel.data(RESPONSE).await;
                            }
                            return;
                        }
                    }
                    ChannelMsg::Close | ChannelMsg::Eof => return,
                    _ => {}
                }
            }
        });
        Ok(())
    }
}

#[derive(Clone)]
struct JumpServer {
    allowed_target: SocketAddr,
    tunnel_event_tx: mpsc::UnboundedSender<TunnelEvent>,
}

#[derive(Debug, Eq, PartialEq)]
enum TunnelEvent {
    Started,
    Stopped,
}

impl server::Server for JumpServer {
    type Handler = Self;

    fn new_client(&mut self, _: Option<SocketAddr>) -> Self::Handler {
        self.clone()
    }
}

impl Handler for JumpServer {
    type Error = russh::Error;

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
        Ok(if user == JUMP_USER && password == JUMP_PASSWORD {
            Auth::Accept
        } else {
            Auth::reject()
        })
    }

    async fn channel_open_direct_tcpip(
        &mut self,
        channel: Channel<Msg>,
        host_to_connect: &str,
        port_to_connect: u32,
        _: &str,
        _: u32,
        reply: server::ChannelOpenHandle,
        _: &mut Session,
    ) -> Result<(), Self::Error> {
        let requested_target = format!("{host_to_connect}:{port_to_connect}");
        if requested_target != self.allowed_target.to_string() {
            reply
                .reject(ChannelOpenFailure::AdministrativelyProhibited)
                .await;
            return Ok(());
        }

        let Ok(mut target_stream) = TcpStream::connect(self.allowed_target).await else {
            reply.reject(ChannelOpenFailure::ConnectFailed).await;
            return Ok(());
        };
        let mut channel_stream = channel.into_stream();
        let event_tx = self.tunnel_event_tx.clone();
        reply.accept().await;
        tokio::spawn(async move {
            let _ = event_tx.send(TunnelEvent::Started);
            let _ = tokio::io::copy_bidirectional(&mut channel_stream, &mut target_stream).await;
            let _ = event_tx.send(TunnelEvent::Stopped);
        });
        Ok(())
    }
}

fn server_config() -> TestResult<Arc<server::Config>> {
    Ok(Arc::new(server::Config {
        keys: vec![PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519)?],
        ..Default::default()
    }))
}

async fn authenticate_password(
    session: &mut client::Handle<AcceptHostKey>,
    user: &str,
    wrong_password: &str,
    password: &str,
) -> TestResult {
    if session
        .authenticate_password(user, wrong_password)
        .await?
        .success()
    {
        return Err(io::Error::other("server accepted the wrong layer password").into());
    }
    if !session
        .authenticate_password(user, password)
        .await?
        .success()
    {
        return Err(io::Error::other("server rejected the correct layer password").into());
    }
    Ok(())
}

#[tokio::test]
async fn nested_ssh_crosses_direct_tcpip_and_tears_down_with_jump() -> TestResult {
    let target_socket = TcpListener::bind("127.0.0.1:0").await?;
    let target_address = target_socket.local_addr()?;
    let jump_socket = TcpListener::bind("127.0.0.1:0").await?;
    let jump_address = jump_socket.local_addr()?;

    let mut target_server = TargetServer;
    let target_running = target_server.run_on_socket(server_config()?, &target_socket);
    let target_handle = target_running.handle();

    let (tunnel_event_tx, mut tunnel_event_rx) = mpsc::unbounded_channel();
    let mut jump_server = JumpServer {
        allowed_target: target_address,
        tunnel_event_tx,
    };
    let jump_running = jump_server.run_on_socket(server_config()?, &jump_socket);
    let jump_handle = jump_running.handle();

    let client = async move {
        let (host_key_tx, mut host_key_rx) = mpsc::unbounded_channel();
        let mut jump = client::connect(
            Arc::new(client::Config::default()),
            jump_address,
            AcceptHostKey {
                layer: "jump",
                event_tx: host_key_tx.clone(),
            },
        )
        .await?;
        authenticate_password(&mut jump, JUMP_USER, TARGET_PASSWORD, JUMP_PASSWORD).await?;

        let rejected_port = if target_address.port() == u16::MAX {
            target_address.port() - 1
        } else {
            target_address.port() + 1
        };
        if jump
            .channel_open_direct_tcpip("127.0.0.1", rejected_port.into(), "127.0.0.1", 0)
            .await
            .is_ok()
        {
            return Err(io::Error::other("jump server accepted an unapproved destination").into());
        }

        let tunnel = jump
            .channel_open_direct_tcpip(
                target_address.ip().to_string(),
                target_address.port().into(),
                "127.0.0.1",
                0,
            )
            .await?;
        if timeout(TEST_TIMEOUT, tunnel_event_rx.recv()).await? != Some(TunnelEvent::Started) {
            return Err(io::Error::other("jump tunnel did not start").into());
        }

        let mut target = client::connect_stream(
            Arc::new(client::Config::default()),
            tunnel.into_stream(),
            AcceptHostKey {
                layer: "target",
                event_tx: host_key_tx,
            },
        )
        .await?;
        authenticate_password(&mut target, TARGET_USER, JUMP_PASSWORD, TARGET_PASSWORD).await?;

        let channel = target.channel_open_session().await?;
        let mut target_stream = channel.into_stream();
        target_stream.write_all(PROBE).await?;
        let mut response = vec![0; RESPONSE.len()];
        timeout(TEST_TIMEOUT, target_stream.read_exact(&mut response)).await??;
        if response != RESPONSE {
            return Err(io::Error::other("target response changed inside the jump tunnel").into());
        }

        let jump_key = timeout(TEST_TIMEOUT, host_key_rx.recv())
            .await?
            .ok_or_else(|| io::Error::other("jump host-key callback was not observed"))?;
        let target_key = timeout(TEST_TIMEOUT, host_key_rx.recv())
            .await?
            .ok_or_else(|| io::Error::other("target host-key callback was not observed"))?;
        if jump_key.layer != "jump" || target_key.layer != "target" {
            return Err(io::Error::other("host-key callbacks lost their SSH layer").into());
        }
        if jump_key.fingerprint == target_key.fingerprint {
            return Err(io::Error::other("fixture did not expose distinct layer host keys").into());
        }

        drop(target_stream);
        target
            .disconnect(Disconnect::ByApplication, "test target teardown", "")
            .await?;
        let _ = timeout(TEST_TIMEOUT, &mut target)
            .await
            .map_err(|_| io::Error::other("target session did not close cleanly"))?;
        if timeout(TEST_TIMEOUT, tunnel_event_rx.recv()).await? != Some(TunnelEvent::Stopped) {
            return Err(io::Error::other("target teardown did not release the tunnel").into());
        }

        let cancelled_tunnel = jump
            .channel_open_direct_tcpip(
                target_address.ip().to_string(),
                target_address.port().into(),
                "127.0.0.1",
                0,
            )
            .await?;
        if timeout(TEST_TIMEOUT, tunnel_event_rx.recv()).await? != Some(TunnelEvent::Started) {
            return Err(io::Error::other("cancellation tunnel did not start").into());
        }
        let (cancel_key_tx, _cancel_key_rx) = mpsc::unbounded_channel();
        let mut cancelled_target = client::connect_stream(
            Arc::new(client::Config::default()),
            cancelled_tunnel.into_stream(),
            AcceptHostKey {
                layer: "target",
                event_tx: cancel_key_tx,
            },
        )
        .await?;
        authenticate_password(
            &mut cancelled_target,
            TARGET_USER,
            JUMP_PASSWORD,
            TARGET_PASSWORD,
        )
        .await?;

        jump.disconnect(Disconnect::ByApplication, "test jump teardown", "")
            .await?;
        let _ = timeout(TEST_TIMEOUT, &mut cancelled_target)
            .await
            .map_err(|_| io::Error::other("nested session survived jump teardown"))?;
        if timeout(TEST_TIMEOUT, tunnel_event_rx.recv()).await? != Some(TunnelEvent::Stopped) {
            return Err(io::Error::other("jump teardown did not release the tunnel").into());
        }
        Ok::<(), Box<dyn Error + Send + Sync>>(())
    };

    let managed_client = async move {
        let result = timeout(Duration::from_secs(30), client).await;
        jump_handle.shutdown("test complete".to_string());
        target_handle.shutdown("test complete".to_string());
        match result {
            Ok(result) => result,
            Err(error) => Err(error.into()),
        }
    };
    let (target_result, jump_result, client_result) =
        tokio::join!(target_running, jump_running, managed_client);
    target_result?;
    jump_result?;
    client_result
}
