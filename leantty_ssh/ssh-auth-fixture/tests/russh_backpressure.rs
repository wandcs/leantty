use std::error::Error;
use std::io;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use russh::client;
use russh::keys::{Algorithm, PrivateKey, PrivateKeyWithHashAlg, PublicKey};
use russh::server::{self, Auth, Handler, Msg, Server as _, Session};
use russh::{Channel, ChannelMsg, Disconnect};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, watch};
use tokio::time::timeout;

const WINDOW_SIZE: usize = 16 * 1024;
const LARGE_PASTE_BYTES: usize = 512 * 1024;
const CONTINUOUS_INPUT_BYTES: usize = 1024 * 1024 + 17;
const INPUT_WRITE_CHUNK_BYTES: usize = 32 * 1024;
const SHORT_WAIT: Duration = Duration::from_millis(150);
const TEST_TIMEOUT: Duration = Duration::from_secs(5);

type TestResult<T = ()> = Result<T, Box<dyn Error + Send + Sync>>;

#[derive(Debug)]
enum ServerEvent {
    Data(Vec<u8>),
    Resize(u32, u32),
    Eof,
    Close,
}

#[derive(Clone)]
struct PausedServer {
    resume_rx: watch::Receiver<bool>,
    event_tx: mpsc::UnboundedSender<ServerEvent>,
}

impl server::Server for PausedServer {
    type Handler = Self;

    fn new_client(&mut self, _: Option<SocketAddr>) -> Self::Handler {
        self.clone()
    }
}

impl Handler for PausedServer {
    type Error = russh::Error;

    async fn auth_publickey(&mut self, _: &str, _: &PublicKey) -> Result<Auth, Self::Error> {
        Ok(Auth::Accept)
    }

    async fn channel_open_session(
        &mut self,
        mut channel: Channel<Msg>,
        reply: server::ChannelOpenHandle,
        _: &mut Session,
    ) -> Result<(), Self::Error> {
        let mut resume_rx = self.resume_rx.clone();
        let event_tx = self.event_tx.clone();
        reply.accept().await;
        tokio::spawn(async move {
            while !*resume_rx.borrow_and_update() {
                if resume_rx.changed().await.is_err() {
                    return;
                }
            }
            while let Some(message) = channel.wait().await {
                let event = match message {
                    ChannelMsg::Data { data } => ServerEvent::Data(data.to_vec()),
                    ChannelMsg::WindowChange {
                        col_width,
                        row_height,
                        ..
                    } => ServerEvent::Resize(col_width, row_height),
                    ChannelMsg::Eof => ServerEvent::Eof,
                    ChannelMsg::Close => ServerEvent::Close,
                    _ => continue,
                };
                let terminal = matches!(event, ServerEvent::Eof | ServerEvent::Close);
                if event_tx.send(event).is_err() || terminal {
                    return;
                }
            }
        });
        Ok(())
    }
}

struct TestClient;

impl client::Handler for TestClient {
    type Error = russh::Error;

    async fn check_server_key(&mut self, _: &PublicKey) -> Result<bool, Self::Error> {
        Ok(true)
    }
}

async fn connect_client(
    address: SocketAddr,
) -> TestResult<(client::Handle<TestClient>, Channel<client::Msg>)> {
    let config = Arc::new(client::Config {
        window_size: WINDOW_SIZE as u32,
        channel_buffer_size: 1,
        ..Default::default()
    });
    let key = Arc::new(PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519)?);
    let mut session = client::connect(config, address, TestClient).await?;
    let hash = session.best_supported_rsa_hash().await?.flatten();
    let result = session
        .authenticate_publickey("user", PrivateKeyWithHashAlg::new(key, hash))
        .await?;
    if !result.success() {
        return Err(io::Error::other("fixture public-key authentication failed").into());
    }
    let channel = session.channel_open_session().await?;
    Ok((session, channel))
}

fn server_config() -> TestResult<Arc<server::Config>> {
    Ok(Arc::new(server::Config {
        keys: vec![PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519)?],
        window_size: WINDOW_SIZE as u32,
        channel_buffer_size: 1,
        ..Default::default()
    }))
}

fn large_paste() -> Vec<u8> {
    (0..LARGE_PASTE_BYTES)
        .map(|index| (index % 251) as u8)
        .collect()
}

#[tokio::test]
async fn bounded_owned_writes_preserve_follow_up_after_one_mebibyte() -> TestResult {
    let socket = TcpListener::bind("127.0.0.1:0").await?;
    let address = socket.local_addr()?;
    let (_resume_tx, resume_rx) = watch::channel(true);
    let (event_tx, mut event_rx) = mpsc::unbounded_channel();
    let mut server = PausedServer {
        resume_rx,
        event_tx,
    };
    let running = server.run_on_socket(server_config()?, &socket);
    let server_handle = running.handle();

    let client = async move {
        let (session, channel) = connect_client(address).await?;
        let payload = (0..CONTINUOUS_INPUT_BYTES)
            .map(|index| (index % 251) as u8)
            .collect::<Vec<_>>();
        let follow_up = b"ltty-input-check after-large\r";

        for chunk in payload.chunks(INPUT_WRITE_CHUNK_BYTES) {
            channel.data_bytes(chunk.to_vec()).await?;
            tokio::task::yield_now().await;
        }
        channel.window_change(181, 49, 0, 0).await?;
        channel.data_bytes(follow_up.to_vec()).await?;
        channel.eof().await?;

        let mut received = Vec::with_capacity(payload.len() + follow_up.len());
        let mut resize_seen = false;
        timeout(TEST_TIMEOUT, async {
            while received.len() < payload.len() + follow_up.len() || !resize_seen {
                match event_rx.recv().await {
                    Some(ServerEvent::Data(data)) => received.extend_from_slice(&data),
                    Some(ServerEvent::Resize(cols, rows)) => {
                        resize_seen = cols == 181 && rows == 49;
                    }
                    Some(ServerEvent::Eof | ServerEvent::Close) | None => break,
                }
            }
        })
        .await?;

        assert_eq!(&received[..payload.len()], payload);
        assert_eq!(&received[payload.len()..], follow_up);
        if !resize_seen {
            return Err(io::Error::other("resize was lost after bounded input").into());
        }
        session
            .disconnect(Disconnect::ByApplication, "test complete", "")
            .await?;
        Ok::<(), Box<dyn Error + Send + Sync>>(())
    };

    let managed_client = async move {
        let result = timeout(Duration::from_secs(15), client).await;
        server_handle.shutdown("test complete".to_string());
        match result {
            Ok(result) => result,
            Err(error) => Err(error.into()),
        }
    };
    let (server_result, client_result) = tokio::join!(running, managed_client);
    server_result?;
    client_result
}

#[tokio::test]
async fn large_paste_and_resize_resume_after_remote_reads_again() -> TestResult {
    let socket = TcpListener::bind("127.0.0.1:0").await?;
    let address = socket.local_addr()?;
    let (resume_tx, resume_rx) = watch::channel(false);
    let (event_tx, mut event_rx) = mpsc::unbounded_channel();
    let mut server = PausedServer {
        resume_rx,
        event_tx,
    };
    let running = server.run_on_socket(server_config()?, &socket);
    let server_handle = running.handle();

    let client = async move {
        let (session, channel) = connect_client(address).await?;
        let payload = large_paste();
        let mut paste = Box::pin(channel.data(&payload[..]));
        if timeout(SHORT_WAIT, paste.as_mut()).await.is_ok() {
            return Err(io::Error::other("large paste bypassed remote-window backpressure").into());
        }

        let mut resize = Box::pin(channel.window_change(173, 47, 0, 0));
        let resize_pending = match timeout(SHORT_WAIT, resize.as_mut()).await {
            Ok(result) => {
                result?;
                false
            }
            Err(_) => true,
        };
        if event_rx.try_recv().is_ok() {
            return Err(io::Error::other("paused server consumed channel events").into());
        }

        resume_tx.send(true)?;
        timeout(TEST_TIMEOUT, paste.as_mut()).await??;
        drop(paste);
        if resize_pending {
            timeout(TEST_TIMEOUT, resize.as_mut()).await??;
        }
        drop(resize);
        channel.eof().await?;

        let mut received = Vec::with_capacity(payload.len());
        let mut resize_seen = false;
        timeout(TEST_TIMEOUT, async {
            while received.len() < payload.len() || !resize_seen {
                match event_rx.recv().await {
                    Some(ServerEvent::Data(data)) => received.extend_from_slice(&data),
                    Some(ServerEvent::Resize(cols, rows)) => {
                        resize_seen = cols == 173 && rows == 47;
                    }
                    Some(ServerEvent::Eof | ServerEvent::Close) | None => break,
                }
            }
        })
        .await?;
        if received != payload {
            return Err(io::Error::other("large paste was truncated or reordered").into());
        }
        if !resize_seen {
            return Err(io::Error::other("resize was lost during backpressure").into());
        }

        session
            .disconnect(Disconnect::ByApplication, "test complete", "")
            .await?;
        Ok::<(), Box<dyn Error + Send + Sync>>(())
    };

    let managed_client = async move {
        let result = timeout(Duration::from_secs(15), client).await;
        server_handle.shutdown("test complete".to_string());
        match result {
            Ok(result) => result,
            Err(error) => Err(error.into()),
        }
    };
    let (server_result, client_result) = tokio::join!(running, managed_client);
    server_result?;
    client_result
}

#[tokio::test]
async fn remote_disconnect_releases_backpressured_client_write() -> TestResult {
    let socket = TcpListener::bind("127.0.0.1:0").await?;
    let address = socket.local_addr()?;
    let proxy_socket = TcpListener::bind("127.0.0.1:0").await?;
    let proxy_address = proxy_socket.local_addr()?;
    let (_resume_tx, resume_rx) = watch::channel(false);
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let mut server = PausedServer {
        resume_rx,
        event_tx,
    };
    let running = server.run_on_socket(server_config()?, &socket);
    let server_handle = running.handle();

    let client = async move {
        let proxy = tokio::spawn(async move {
            let (mut client_stream, _) = proxy_socket.accept().await?;
            let mut server_stream = TcpStream::connect(address).await?;
            tokio::io::copy_bidirectional(&mut client_stream, &mut server_stream).await
        });
        let (mut session, channel) = connect_client(proxy_address).await?;
        let (_read_half, write_half) = channel.split();
        let payload = large_paste();
        let mut paste = tokio::spawn(async move { write_half.data(&payload[..]).await });
        if timeout(SHORT_WAIT, &mut paste).await.is_ok() {
            return Err(io::Error::other("large paste bypassed remote-window backpressure").into());
        }

        proxy.abort();
        if !proxy.await.unwrap_err().is_cancelled() {
            return Err(io::Error::other("TCP proxy did not stop on request").into());
        }
        let _ = timeout(TEST_TIMEOUT, &mut session)
            .await
            .map_err(|_| io::Error::other("client session did not finish after TCP disconnect"))?;
        paste.abort();
        let paste_error = timeout(TEST_TIMEOUT, paste).await?.unwrap_err();
        if !paste_error.is_cancelled() {
            return Err(io::Error::other("backpressured writer was not cancelled").into());
        }
        Ok::<(), Box<dyn Error + Send + Sync>>(())
    };

    let managed_client = async move {
        let result = timeout(Duration::from_secs(15), client).await;
        server_handle.shutdown("test complete".to_string());
        match result {
            Ok(result) => result,
            Err(error) => Err(error.into()),
        }
    };
    let (server_result, client_result) = tokio::join!(running, managed_client);
    server_result?;
    client_result
}
