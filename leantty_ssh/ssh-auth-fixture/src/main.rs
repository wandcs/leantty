use std::borrow::Cow;
use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::{self, Read, Write};
use std::net::IpAddr;
use std::net::SocketAddr;
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::process::Command as StdCommand;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use russh::keys::{Algorithm, HashAlg, PrivateKey, PublicKey};
use russh::server::{Auth, Handler, Msg, Response, Server, Session};
use russh::{Channel, ChannelId, ChannelOpenFailure, MethodKind, MethodSet};
use russh_sftp::protocol::{Attrs, Data, FileAttributes, Handle, OpenFlags, Status, StatusCode};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UdpSocket};
use tokio::process::Command as TokioCommand;
use tokio::sync::Mutex;
use tokio::task::JoinHandle;
use zeroize::{Zeroize, Zeroizing};

const USER_PASSWORD: &str = "password";
const USER_PUBLICKEY: &str = "publickey";
const USER_PASSWORD_KBDINT: &str = "password-kbdint";
const USER_PUBLICKEY_PASSWORD: &str = "publickey-password";
const USER_PUBLICKEY_KBDINT: &str = "publickey-kbdint";
const USER_KBDINT_MULTIROUND: &str = "kbdint-multiround";
const USER_KBDINT_ZERO: &str = "kbdint-zero";
const USER_UNSUPPORTED: &str = "unsupported";
const USER_CHANNEL_DENIED: &str = "channel-denied";
const USER_KEY_INSTALL: &str = "key-install";
const USER_NAVIGATION: &str = "navigation";
const USER_NAVIGATION_TWO: &str = "navigation-two";
const USER_NAVIGATION_THREE: &str = "navigation-three";
const USER_MOSH: &str = "mosh";
const MOSH_BOOTSTRAP_COMMAND_PREFIX: &str = "sh -c '[ -n \"$SSH_CONNECTION\" ] && printf \"\\nMOSH SSH_CONNECTION %s\\n\" \"$SSH_CONNECTION\"; exec ";
const MOSH_DEFAULT_SERVER: &str = "mosh-server";
const MOSH_SERVER_ARGUMENTS: &str = " new -s -c 256";
const MOSH_FIXTURE_NETWORK_TIMEOUT_SECONDS: u64 = 30;
const MOSH_TERMINAL_SUBCOMMAND: &str = "--mosh-terminal";
const MOSH_CHECK_COMMAND: &str = "ltty-mosh-check";
const MOSH_SHELL_COMMAND: &str = "ltty-mosh-shell";
const MOSH_TMUX_COMMAND: &str = "ltty-mosh-tmux";
const MOSH_EDITOR_COMMAND: &str = "ltty-mosh-editor";
const MOSH_RESIZE_COMMAND: &str = "ltty-mosh-resize";
const MOSH_STREAM_COMMAND: &str = "ltty-mosh-stream";
const MOSH_UNICODE_COMMAND: &str = "ltty-mosh-unicode";
const MOSH_SCROLLBACK_COMMAND: &str = "ltty-mosh-scrollback";
const MOSH_LESS_COMMAND: &str = "ltty-mosh-less";
const MOSH_ALTERNATE_COMMAND: &str = "ltty-mosh-alternate";
const MOSH_AGENT_COMMAND: &str = "ltty-mosh-agent";
const MOSH_STREAM_INPUT_BYTES: usize = 512;
const MOSH_SCROLLBACK_LINES: usize = 240;
const MOSH_PREDICTION_RELAY_DELAY: Duration = Duration::from_millis(40);
const MOSH_PREDICTION_RELAY_PORT_MIN: u16 = 60_000;
const MOSH_PREDICTION_RELAY_PORT_MAX: u16 = 61_000;
const PERF_PREPARE_COMMAND: &str = "ltty-perf-prepare";
const PERF_RUN_COMMAND: &str = "ltty-perf-run";
const PERF_MAX_CASE_ID_LENGTH: usize = 24;
const PERF_MAX_LINES: usize = 12_000;
const PERF_MIN_LINE_WIDTH: usize = 48;
const PERF_MAX_LINE_WIDTH: usize = 160;
const PERF_OUTPUT_CHUNK_BYTES: usize = 16 * 1024;
const PASTE_PREPARE_COMMAND: &str = "ltty-paste-prepare";
const INPUT_CHECK_COMMAND: &str = "ltty-input-check";
const TERMINAL_DIRTY_COMMAND: &str = "ltty-terminal-dirty";
const EXIT_COMMAND: &str = "ltty-exit";
const BELL_COMMAND: &str = "ltty-bell";
const BELL_MIN_DELAY_MS: u64 = 100;
const BELL_MAX_DELAY_MS: u64 = 5_000;
const PASTE_MAX_BYTES: usize = 1024 * 1024;

#[derive(Clone)]
struct Credentials {
    password: String,
    account: String,
    token: String,
    second_token: String,
}

impl Drop for Credentials {
    fn drop(&mut self) {
        self.password.zeroize();
        self.account.zeroize();
        self.token.zeroize();
        self.second_token.zeroize();
    }
}

impl Credentials {
    fn load(path: &Path) -> Result<Self, String> {
        let contents = Zeroizing::new(
            fs::read_to_string(path)
                .map_err(|error| format!("unable to read credentials file: {error}"))?,
        );
        let mut entries = HashMap::new();
        for (index, line) in contents.lines().enumerate() {
            let (name, value) = line
                .split_once('=')
                .ok_or_else(|| format!("credentials line {} is malformed", index + 1))?;
            if !matches!(name, "password" | "account" | "token" | "second_token") {
                return Err(format!("credentials line {} has an unknown key", index + 1));
            }
            if value.is_empty() {
                return Err(format!("credentials line {} has an empty value", index + 1));
            }
            if entries
                .insert(name.to_string(), Zeroizing::new(value.to_string()))
                .is_some()
            {
                return Err(format!("credentials key {name} is duplicated"));
            }
        }

        let mut take = |name: &str| {
            entries
                .remove(name)
                .map(|value| value.to_string())
                .ok_or_else(|| format!("credentials key {name} is missing"))
        };
        Ok(Self {
            password: take("password")?,
            account: take("account")?,
            token: take("token")?,
            second_token: take("second_token")?,
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct CredentialMismatchSummary {
    expected_bytes: usize,
    received_bytes: usize,
    overlap_mismatches: usize,
    length_delta: i64,
}

fn credential_mismatch_summary(expected: &str, received: &str) -> CredentialMismatchSummary {
    let expected_bytes = expected.as_bytes();
    let received_bytes = received.as_bytes();
    CredentialMismatchSummary {
        expected_bytes: expected_bytes.len(),
        received_bytes: received_bytes.len(),
        overlap_mismatches: expected_bytes
            .iter()
            .zip(received_bytes.iter())
            .filter(|(expected, received)| expected != received)
            .count(),
        length_delta: received_bytes.len() as i64 - expected_bytes.len() as i64,
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Scenario {
    Password,
    PublicKey,
    PasswordKeyboardInteractive,
    PublicKeyPassword,
    PublicKeyKeyboardInteractive,
    KeyboardInteractiveMultiRound,
    KeyboardInteractiveZeroPrompt,
    UnsupportedMethod,
    ChannelDenied,
    KeyInstall,
    Navigation,
    Mosh,
}

impl Scenario {
    fn for_user(user: &str) -> Option<Self> {
        match user {
            USER_PASSWORD => Some(Self::Password),
            USER_PUBLICKEY => Some(Self::PublicKey),
            USER_PASSWORD_KBDINT => Some(Self::PasswordKeyboardInteractive),
            USER_PUBLICKEY_PASSWORD => Some(Self::PublicKeyPassword),
            USER_PUBLICKEY_KBDINT => Some(Self::PublicKeyKeyboardInteractive),
            USER_KBDINT_MULTIROUND => Some(Self::KeyboardInteractiveMultiRound),
            USER_KBDINT_ZERO => Some(Self::KeyboardInteractiveZeroPrompt),
            USER_UNSUPPORTED => Some(Self::UnsupportedMethod),
            USER_CHANNEL_DENIED => Some(Self::ChannelDenied),
            USER_KEY_INSTALL => Some(Self::KeyInstall),
            USER_NAVIGATION | USER_NAVIGATION_TWO | USER_NAVIGATION_THREE => Some(Self::Navigation),
            USER_MOSH => Some(Self::Mosh),
            _ => None,
        }
    }
}

#[derive(Clone)]
struct MoshFixture {
    server_address: IpAddr,
    ssh_port: u16,
    udp_port: Option<u16>,
    network_timeout_seconds: u64,
    control_directory: Arc<PathBuf>,
    executable_path: Arc<PathBuf>,
    previous_session_key: Arc<Mutex<Option<String>>>,
    next_session_index: Arc<AtomicU64>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct MoshPortRequest {
    start: u16,
    end: u16,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct MoshBootstrapRequest {
    server_path: Option<String>,
    port: Option<MoshPortRequest>,
}

impl MoshPortRequest {
    fn argument(self) -> String {
        if self.start == self.end {
            self.start.to_string()
        } else {
            format!("{}:{}", self.start, self.end)
        }
    }

    fn contains(self, port: u16) -> bool {
        (self.start..=self.end).contains(&port)
    }
}

fn mosh_session_control_name(session_index: u64) -> String {
    format!("mosh-session-{session_index}")
}

fn parse_mosh_bootstrap_request(data: &[u8]) -> Option<MoshBootstrapRequest> {
    let command = std::str::from_utf8(data).ok()?;
    let suffix = command.strip_prefix(MOSH_BOOTSTRAP_COMMAND_PREFIX)?;
    let (server, arguments) = suffix.split_once(MOSH_SERVER_ARGUMENTS)?;
    let server_path = if server == MOSH_DEFAULT_SERVER {
        None
    } else if valid_mosh_server_path(server) {
        Some(server.to_string())
    } else {
        return None;
    };
    if arguments == "'" {
        return Some(MoshBootstrapRequest {
            server_path,
            port: None,
        });
    }
    let request = arguments.strip_prefix(" -p ")?.strip_suffix('\'')?;
    let mut fields = request.split(':');
    let start_text = fields.next()?;
    let end_text = fields.next();
    if fields.next().is_some()
        || start_text.is_empty()
        || !start_text.bytes().all(|byte| byte.is_ascii_digit())
        || end_text
            .is_some_and(|text| text.is_empty() || !text.bytes().all(|byte| byte.is_ascii_digit()))
    {
        return None;
    }
    let start = start_text.parse::<u16>().ok().filter(|port| *port > 0)?;
    let end = end_text
        .map_or(Ok(start), |text| text.parse::<u16>())
        .ok()
        .filter(|port| *port > 0)?;
    (start <= end).then_some(MoshBootstrapRequest {
        server_path,
        port: Some(MoshPortRequest { start, end }),
    })
}

fn valid_mosh_server_path(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 1024
        && value.starts_with('/')
        && !value.ends_with('/')
        && !value.split('/').skip(1).any(|segment| {
            segment.is_empty()
                || segment == "."
                || segment == ".."
                || !segment.bytes().all(|byte| {
                    byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'+' | b'-')
                })
        })
}

fn rewrite_mosh_bootstrap_port(
    stdout: &[u8],
    server_port: u16,
    relay_port: u16,
) -> io::Result<Vec<u8>> {
    let text = std::str::from_utf8(stdout)
        .map_err(|_| io::Error::other("mosh-server stdout was not UTF-8"))?;
    let source = format!("MOSH CONNECT {server_port} ");
    let replacement = format!("MOSH CONNECT {relay_port} ");
    if text.matches(&source).count() != 1 {
        return Err(io::Error::other(
            "mosh-server bootstrap port could not be rewritten exactly once",
        ));
    }
    Ok(text.replacen(&source, &replacement, 1).into_bytes())
}

async fn start_mosh_prediction_relay(
    server_address: IpAddr,
    server_port: u16,
    control_directory: &Path,
) -> io::Result<u16> {
    let mut socket = None;
    for port in (MOSH_PREDICTION_RELAY_PORT_MIN..=MOSH_PREDICTION_RELAY_PORT_MAX).rev() {
        match UdpSocket::bind(SocketAddr::new(server_address, port)).await {
            Ok(candidate) => {
                socket = Some((port, candidate));
                break;
            }
            Err(error) if error.kind() == io::ErrorKind::AddrInUse => {}
            Err(error) => return Err(error),
        }
    }
    let (relay_port, downstream) = socket.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::AddrNotAvailable,
            "no controlled Mosh prediction relay port was available",
        )
    })?;
    let server_endpoint = SocketAddr::new(server_address, server_port);
    let upstream = UdpSocket::bind(SocketAddr::from(([0, 0, 0, 0], 0))).await?;
    upstream.connect(server_endpoint).await?;
    let pause_path = control_directory.join("mosh-prediction-relay-paused");
    let stats_path = control_directory.join("mosh-prediction-relay-stats");
    remove_file_if_present(&pause_path)?;
    fs::write(&stats_path, b"dropped=0\n")?;
    let downstream = Arc::new(downstream);
    let upstream = Arc::new(upstream);
    let client_endpoint = Arc::new(Mutex::new(None));
    let dropped = Arc::new(AtomicU64::new(0));
    tokio::spawn(forward_mosh_prediction_client_datagrams(
        Arc::clone(&downstream),
        Arc::clone(&upstream),
        Arc::clone(&client_endpoint),
        pause_path.clone(),
        stats_path.clone(),
        Arc::clone(&dropped),
    ));
    tokio::spawn(forward_mosh_prediction_server_datagrams(
        upstream,
        downstream,
        client_endpoint,
        pause_path,
        stats_path,
        dropped,
    ));
    Ok(relay_port)
}

fn record_mosh_prediction_drop(stats_path: &Path, dropped: &AtomicU64) {
    let value = dropped.fetch_add(1, Ordering::SeqCst).saturating_add(1);
    let _ = fs::write(stats_path, format!("dropped={value}\n"));
}

async fn forward_mosh_prediction_client_datagrams(
    downstream: Arc<UdpSocket>,
    upstream: Arc<UdpSocket>,
    client_endpoint: Arc<Mutex<Option<SocketAddr>>>,
    pause_path: PathBuf,
    stats_path: PathBuf,
    dropped: Arc<AtomicU64>,
) {
    let mut buffer = vec![0_u8; u16::MAX as usize];
    while let Ok((length, source)) = downstream.recv_from(&mut buffer).await {
        *client_endpoint.lock().await = Some(source);
        if pause_path.is_file() {
            record_mosh_prediction_drop(&stats_path, &dropped);
            continue;
        }
        tokio::time::sleep(MOSH_PREDICTION_RELAY_DELAY).await;
        if upstream.send(&buffer[..length]).await.is_err() {
            break;
        }
    }
}

async fn forward_mosh_prediction_server_datagrams(
    upstream: Arc<UdpSocket>,
    downstream: Arc<UdpSocket>,
    client_endpoint: Arc<Mutex<Option<SocketAddr>>>,
    pause_path: PathBuf,
    stats_path: PathBuf,
    dropped: Arc<AtomicU64>,
) {
    let mut buffer = vec![0_u8; u16::MAX as usize];
    while let Ok(length) = upstream.recv(&mut buffer).await {
        if pause_path.is_file() {
            record_mosh_prediction_drop(&stats_path, &dropped);
            continue;
        }
        let Some(client) = *client_endpoint.lock().await else {
            continue;
        };
        tokio::time::sleep(MOSH_PREDICTION_RELAY_DELAY).await;
        if downstream.send_to(&buffer[..length], client).await.is_err() {
            break;
        }
    }
}

impl MoshFixture {
    async fn bootstrap(
        &self,
        peer: SocketAddr,
        request: MoshBootstrapRequest,
    ) -> io::Result<Vec<u8>> {
        let connection = format!(
            "{} {} {} {}",
            peer.ip(),
            peer.port(),
            self.server_address,
            self.ssh_port
        );
        let session_path = self.control_directory.join("mosh-session");
        let isolation_enabled = self
            .control_directory
            .join("mosh-session-isolation")
            .is_file();
        let (terminal_control_directory, control_name) = if isolation_enabled {
            let session_index = self
                .next_session_index
                .fetch_add(1, Ordering::SeqCst)
                .saturating_add(1);
            let name = mosh_session_control_name(session_index);
            let directory = self.control_directory.join(&name);
            fs::create_dir(&directory)?;
            (directory, Some(name))
        } else {
            (self.control_directory.as_ref().clone(), None)
        };
        let input_path = terminal_control_directory.join("mosh-input-snapshot");
        let event_path = terminal_control_directory.join("mosh-event");
        for path in [&session_path, &input_path, &event_path] {
            match fs::remove_file(path) {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
        }

        let configured_port = self.udp_port.map(|port| MoshPortRequest {
            start: port,
            end: port,
        });
        let port_request = match (request.port, configured_port) {
            (Some(requested), Some(configured)) if requested != configured => {
                return Err(io::Error::other(
                    "product and fixture Mosh UDP port requests conflict",
                ));
            }
            (Some(requested), _) => Some(requested),
            (None, configured) => configured,
        };
        let server_executable = request
            .server_path
            .as_deref()
            .unwrap_or(MOSH_DEFAULT_SERVER);
        let mut command = TokioCommand::new(server_executable);
        command.args(["new", "-i", &self.server_address.to_string()]);
        let port_argument = port_request.map(MoshPortRequest::argument);
        if let Some(argument) = port_argument.as_ref() {
            command.args(["-p", argument]);
        }
        let output = command
            .args(["-c", "256", "--"])
            .arg(self.executable_path.as_ref())
            .arg(MOSH_TERMINAL_SUBCOMMAND)
            .arg(&terminal_control_directory)
            .env("SSH_CONNECTION", &connection)
            .env(
                "MOSH_SERVER_NETWORK_TMOUT",
                self.network_timeout_seconds.to_string(),
            )
            .output()
            .await?;
        if !output.status.success() {
            return Err(io::Error::other(format!(
                "mosh-server exited with status {}",
                output.status
            )));
        }
        let (server_port, pid) = parse_mosh_session_metadata(&output.stdout, &output.stderr)?;
        let session_key = parse_mosh_session_key(&output.stdout)?;
        let key_distinct_from_previous = {
            let mut previous = self.previous_session_key.lock().await;
            let distinct = previous.as_ref().is_none_or(|value| value != &session_key);
            *previous = Some(session_key);
            distinct
        };
        if port_request.is_some_and(|requested| !requested.contains(server_port)) {
            return Err(io::Error::other(
                "mosh-server returned a port outside the requested range",
            ));
        }
        let relay_enabled = self
            .control_directory
            .join("mosh-prediction-relay")
            .is_file();
        let (port, bootstrap_stdout) = if relay_enabled {
            let relay_port = start_mosh_prediction_relay(
                self.server_address,
                server_port,
                self.control_directory.as_ref(),
            )
            .await?;
            (
                relay_port,
                rewrite_mosh_bootstrap_port(&output.stdout, server_port, relay_port)?,
            )
        } else {
            (server_port, output.stdout)
        };
        let control_metadata = control_name
            .map(|name| format!("controlName={name}\n"))
            .unwrap_or_default();
        fs::write(
            &session_path,
            format!(
                "port={port}\nserverPort={server_port}\npid={pid}\nserver={server_executable}\nkeyDistinctFromPrevious={key_distinct_from_previous}\n{control_metadata}"
            ),
        )?;
        eprintln!(
            "mosh bootstrap result=ready port={port} serverPort={server_port} pid={pid} relay={relay_enabled}"
        );

        let mut bootstrap = format!("\nMOSH SSH_CONNECTION {connection}\n").into_bytes();
        bootstrap.extend_from_slice(&bootstrap_stdout);
        if bootstrap.len() > 4 * 1024 {
            return Err(io::Error::other("mosh bootstrap exceeded fixture limit"));
        }
        Ok(bootstrap)
    }
}

fn parse_mosh_session_key(stdout: &[u8]) -> io::Result<String> {
    let stdout_text = std::str::from_utf8(stdout)
        .map_err(|_| io::Error::other("mosh-server stdout was not UTF-8"))?;
    let mut key = None;
    for line in stdout_text.lines() {
        if let Some(rest) = line.strip_prefix("MOSH CONNECT ") {
            let mut fields = rest.split_ascii_whitespace();
            let port = fields.next().and_then(|value| value.parse::<u16>().ok());
            let parsed_key = fields.next();
            if port.is_none()
                || parsed_key.is_none_or(|value| value.len() != 22)
                || fields.next().is_some()
                || key.replace(parsed_key.unwrap().to_string()).is_some()
            {
                return Err(io::Error::other(
                    "mosh-server returned invalid bootstrap metadata",
                ));
            }
        }
    }
    key.ok_or_else(|| io::Error::other("mosh-server metadata was incomplete"))
}

fn parse_mosh_session_metadata(stdout: &[u8], stderr: &[u8]) -> io::Result<(u16, u32)> {
    let stdout_text = std::str::from_utf8(stdout)
        .map_err(|_| io::Error::other("mosh-server stdout was not UTF-8"))?;
    let stderr_text = std::str::from_utf8(stderr)
        .map_err(|_| io::Error::other("mosh-server stderr was not UTF-8"))?;
    let mut port = None;
    let mut pid = None;
    for line in stdout_text.lines() {
        if let Some(rest) = line.strip_prefix("MOSH CONNECT ") {
            let mut fields = rest.split_ascii_whitespace();
            let parsed_port = fields.next().and_then(|value| value.parse::<u16>().ok());
            let key = fields.next();
            if parsed_port.is_none()
                || key.is_none_or(|value| value.len() != 22)
                || fields.next().is_some()
                || port.replace(parsed_port.unwrap()).is_some()
            {
                return Err(io::Error::other(
                    "mosh-server returned invalid bootstrap metadata",
                ));
            }
        }
    }
    for line in stderr_text.lines() {
        if let Some(rest) = line.split_once("pid = ").map(|(_, rest)| rest) {
            let value = rest.trim_end_matches(']').trim();
            let parsed_pid = value.parse::<u32>().ok();
            if parsed_pid.is_none() || pid.replace(parsed_pid.unwrap()).is_some() {
                return Err(io::Error::other(
                    "mosh-server returned invalid process metadata",
                ));
            }
        }
    }
    match (port, pid) {
        (Some(port), Some(pid)) => Ok((port, pid)),
        _ => Err(io::Error::other("mosh-server metadata was incomplete")),
    }
}

fn is_valid_mosh_case_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 32
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn persist_mosh_input(path: &Path, input: &[u8]) -> io::Result<()> {
    fs::write(path, input)
}

fn remove_file_if_present(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn read_mosh_terminal_size() -> io::Result<(u16, u16)> {
    let output = StdCommand::new("sh")
        .args(["-c", "stty size < /dev/tty"])
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other(
            "unable to read the controlled Mosh PTY size",
        ));
    }
    let text = std::str::from_utf8(&output.stdout)
        .map_err(|_| io::Error::other("controlled Mosh PTY size was not UTF-8"))?;
    let mut fields = text.split_ascii_whitespace();
    let rows = fields.next().and_then(|value| value.parse::<u16>().ok());
    let columns = fields.next().and_then(|value| value.parse::<u16>().ok());
    if fields.next().is_some() || rows.is_none() || columns.is_none() {
        return Err(io::Error::other("controlled Mosh PTY size was malformed"));
    }
    Ok((rows.unwrap(), columns.unwrap()))
}

fn mosh_terminal_stty_args(kernel_echo: bool) -> Vec<&'static str> {
    if kernel_echo {
        Vec::new()
    } else {
        vec!["-icanon", "-echo", "min", "1", "time", "0"]
    }
}

fn write_mosh_terminal_event(
    path: &Path,
    kind: &str,
    case_id: &str,
    result: &str,
    details: &str,
) -> io::Result<()> {
    fs::write(
        path,
        format!("kind={kind}\ncase={case_id}\nresult={result}\n{details}"),
    )
}

fn run_mosh_shell(control_directory: &Path, case_id: &str, in_tmux: bool) -> io::Result<()> {
    let kind = if in_tmux { "tmux" } else { "shell" };
    let event_path = control_directory.join(format!("mosh-{kind}-event"));
    let ready_path = control_directory.join(format!("mosh-{kind}-ready"));
    let init_path = control_directory.join("mosh-bash-init");
    remove_file_if_present(&event_path)?;
    remove_file_if_present(&ready_path)?;
    fs::write(
        &init_path,
        b"PS1='ltty-bash> '\n\
          PROMPT_COMMAND='printf ready\\n > \"$LTTY_MOSH_READY\"'\n\
          ltty-shell-check() {\n\
            if [ \"$1\" = \"$LTTY_MOSH_CASE\" ] && { [ \"$LTTY_MOSH_EXPECT_TMUX\" != 1 ] || [ -n \"$TMUX\" ]; }; then\n\
              printf '\\r\\nLTTY_MOSH_%s_OK:%s\\r\\n' \"${LTTY_MOSH_KIND^^}\" \"$1\"\n\
              printf 'kind=%s\\ncase=%s\\nresult=passed\\n' \"$LTTY_MOSH_KIND\" \"$1\" > \"$LTTY_MOSH_EVENT\"\n\
            else\n\
              printf 'kind=%s\\ncase=%s\\nresult=failed\\n' \"$LTTY_MOSH_KIND\" \"$1\" > \"$LTTY_MOSH_EVENT\"\n\
            fi\n\
          }\n",
    )?;

    let mut command = if in_tmux {
        let socket = format!("leantty-mosh-{case_id}");
        let mut command = StdCommand::new("tmux");
        command.args([
            "-L",
            &socket,
            "-f",
            "/dev/null",
            "new-session",
            "-s",
            "mosh",
            "/bin/bash",
            "--noprofile",
            "--init-file",
        ]);
        command.arg(&init_path).arg("-i");
        command
    } else {
        let mut command = StdCommand::new("/bin/bash");
        command
            .args(["--noprofile", "--init-file"])
            .arg(&init_path)
            .arg("-i");
        command
    };
    let status = command
        .env("LTTY_MOSH_CASE", case_id)
        .env("LTTY_MOSH_KIND", kind)
        .env("LTTY_MOSH_EVENT", &event_path)
        .env("LTTY_MOSH_READY", &ready_path)
        .env("LTTY_MOSH_EXPECT_TMUX", if in_tmux { "1" } else { "0" })
        .status()?;
    if in_tmux {
        let _ = StdCommand::new("tmux")
            .args(["-L", &format!("leantty-mosh-{case_id}"), "kill-server"])
            .output();
    }
    if !status.success() {
        return Err(io::Error::other(format!(
            "controlled {kind} exited unsuccessfully"
        )));
    }
    let mut event = fs::read_to_string(&event_path)
        .map_err(|_| io::Error::other(format!("controlled {kind} result was missing")))?;
    event.push_str("closed=true\n");
    fs::write(event_path, event)
}

fn run_mosh_editor(control_directory: &Path, case_id: &str) -> io::Result<()> {
    let event_path = control_directory.join("mosh-editor-event");
    let ready_path = control_directory.join("mosh-editor-ready");
    let document_path = control_directory.join("mosh-editor-document");
    remove_file_if_present(&event_path)?;
    remove_file_if_present(&ready_path)?;
    remove_file_if_present(&document_path)?;
    let status = StdCommand::new("vim")
        .args(["-Nu", "NONE", "-n", "-i", "NONE"])
        .args(["-c", "call writefile(['ready'], $LTTY_MOSH_EDITOR_READY)"])
        .arg(&document_path)
        .env("LTTY_MOSH_EDITOR_READY", &ready_path)
        .status()?;
    let expected = format!("editor_{case_id}");
    let actual = fs::read_to_string(&document_path).unwrap_or_default();
    let passed = status.success() && actual.trim_end_matches(['\r', '\n']) == expected;
    write_mosh_terminal_event(
        &event_path,
        "editor",
        case_id,
        if passed { "passed" } else { "failed" },
        "closed=true\n",
    )
}

fn run_mosh_unicode(control_directory: &Path, case_id: &str) -> io::Result<String> {
    let event_path = control_directory.join("mosh-unicode-event");
    remove_file_if_present(&event_path)?;
    let output = format!(
        "LTTY_MOSH_UNICODE:{case_id}\r\nUTF8 | \u{4e2d}\u{6587}\u{5bbd}\u{5b57}\u{7b26} | e\u{301} | END\r\n"
    );
    let locale = StdCommand::new("locale").arg("charmap").output()?;
    let locale_charmap = String::from_utf8_lossy(&locale.stdout).trim().to_string();
    let passed = locale.status.success() && locale_charmap.eq_ignore_ascii_case("UTF-8");
    write_mosh_terminal_event(
        &event_path,
        "unicode",
        case_id,
        if passed { "passed" } else { "failed" },
        &format!(
            "localeCharmap={locale_charmap}\nutf8Bytes={}\nwideCharacters=5\ncombiningSequences=1\n",
            output.len()
        ),
    )?;
    Ok(output)
}

fn run_mosh_scrollback(
    control_directory: &Path,
    case_id: &str,
    stdout: &mut impl Write,
) -> io::Result<()> {
    let event_path = control_directory.join("mosh-scrollback-event");
    remove_file_if_present(&event_path)?;
    let mut emitted_bytes = 0_usize;
    let top = format!("LTTY_MOSH_SCROLL_TOP:{case_id}\r\n");
    stdout.write_all(top.as_bytes())?;
    stdout.flush()?;
    emitted_bytes += top.len();
    // Let the first state reach the client before it leaves the viewport. The
    // device scenario records whether Mosh state synchronization retains it;
    // it does not assume SSH-style byte-stream scrollback.
    std::thread::sleep(Duration::from_millis(500));
    for line in 1..=MOSH_SCROLLBACK_LINES {
        let output = format!(
            "LTTY_MOSH_SCROLL_LINE_{line:03}:{case_id}:0123456789abcdefghijklmnopqrstuvwxyz\r\n"
        );
        stdout.write_all(output.as_bytes())?;
        emitted_bytes += output.len();
        if line % 12 == 0 {
            stdout.flush()?;
            std::thread::sleep(Duration::from_millis(60));
        }
    }
    let bottom = format!("LTTY_MOSH_SCROLL_BOTTOM:{case_id}\r\n");
    stdout.write_all(bottom.as_bytes())?;
    stdout.flush()?;
    emitted_bytes += bottom.len();
    write_mosh_terminal_event(
        &event_path,
        "scrollback",
        case_id,
        "passed",
        &format!(
            "emittedLines={}\nemittedBytes={emitted_bytes}\ncontract=paced-terminal-state-output\n",
            MOSH_SCROLLBACK_LINES + 2
        ),
    )
}

fn run_mosh_less(control_directory: &Path, case_id: &str) -> io::Result<()> {
    let event_path = control_directory.join("mosh-less-event");
    let document_path = control_directory.join("mosh-less-document");
    remove_file_if_present(&event_path)?;
    remove_file_if_present(&document_path)?;
    let mut document = String::new();
    for line in 1..=180 {
        document.push_str(&format!(
            "LTTY_MOSH_LESS_LINE_{line:03}:{case_id}:controlled pager content\n"
        ));
    }
    document.push_str(&format!("LTTY_MOSH_LESS_LAST:{case_id}\n"));
    fs::write(&document_path, document.as_bytes())?;
    let status = StdCommand::new("less")
        .args(["-R", "+G"])
        .arg(&document_path)
        .env("LESSHISTFILE", "-")
        .status()?;
    write_mosh_terminal_event(
        &event_path,
        "less",
        case_id,
        if status.success() { "passed" } else { "failed" },
        "documentLines=181\nclosed=true\n",
    )
}

fn run_mosh_agent_tool(tool_path: &Path, arguments: &[&str]) -> io::Result<bool> {
    Ok(StdCommand::new("bash")
        .arg(tool_path)
        .args(arguments)
        .status()?
        .success())
}

fn run_mosh_agent(control_directory: &Path, case_id: &str) -> io::Result<()> {
    let event_path = control_directory.join("mosh-agent-event");
    let prepared_path = control_directory.join("mosh-agent-prepared");
    remove_file_if_present(&event_path)?;
    remove_file_if_present(&prepared_path)?;
    let tool_path = env::var_os("LEANTTY_MOSH_AGENT_TOOL")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute() && path.is_file())
        .ok_or_else(|| io::Error::other("controlled Agent compatibility tool is unavailable"))?;
    let run_root = control_directory.join(format!("leantty-agent-compat-{case_id}"));
    let run_root_text = run_root
        .to_str()
        .ok_or_else(|| io::Error::other("controlled Agent run root was not UTF-8"))?;
    for command in ["prepare", "configure", "inventory"] {
        if !run_mosh_agent_tool(&tool_path, &[command, run_root_text])? {
            return Err(io::Error::other(format!(
                "controlled Agent tool failed during {command}"
            )));
        }
    }
    fs::write(&prepared_path, b"ready\n")?;
    let launched = run_mosh_agent_tool(
        &tool_path,
        &["launch", run_root_text, "codex", "direct", "interaction"],
    )?;
    let capture_path = run_root.join("results/codex-direct-interaction.json");
    let capture_exists = capture_path.is_file();
    let _ = run_mosh_agent_tool(&tool_path, &["cleanup", run_root_text]);
    write_mosh_terminal_event(
        &event_path,
        "agent",
        case_id,
        if launched && capture_exists {
            "passed"
        } else {
            "failed"
        },
        "agent=codex\nmode=direct\nplannedModelRequests=0\nclosed=true\n",
    )
}

fn run_mosh_terminal(control_directory: &Path) -> io::Result<()> {
    if !control_directory.is_absolute() {
        return Err(io::Error::other(
            "mosh fixture control directory must be absolute",
        ));
    }
    let kernel_echo = control_directory.join("mosh-kernel-echo").is_file();
    let stty_args = mosh_terminal_stty_args(kernel_echo);
    if !stty_args.is_empty() {
        let stty = StdCommand::new("stty").args(stty_args).status()?;
        if !stty.success() {
            return Err(io::Error::other(
                "unable to configure the controlled Mosh PTY",
            ));
        }
    }

    let input_path = control_directory.join("mosh-input-snapshot");
    let event_path = control_directory.join("mosh-event");
    let prediction_event_path = control_directory.join("mosh-prediction-event");
    let ready_path = control_directory.join("mosh-terminal-ready");
    let pid_path = control_directory.join("mosh-terminal-pid");
    let resize_before_path = control_directory.join("mosh-resize-before");
    persist_mosh_input(&input_path, b"")?;
    let (initial_rows, initial_columns) = read_mosh_terminal_size()?;
    fs::write(
        &resize_before_path,
        format!("rows={initial_rows}\ncolumns={initial_columns}\n"),
    )?;
    fs::write(&pid_path, format!("{}\n", std::process::id()))?;
    fs::write(&ready_path, b"ready\n")?;

    if kernel_echo {
        let status = StdCommand::new("/bin/sh")
            .arg("-i")
            .env("PS1", "MOSH_SESSION> ")
            .env("LTTY_MOSH_PREDICTION_EVENT", &prediction_event_path)
            .status()?;
        if !status.success() {
            return Err(io::Error::other(
                "controlled Mosh prediction shell exited unsuccessfully",
            ));
        }
        return Ok(());
    }

    let mut stdin = io::stdin().lock();
    let mut stdout = io::stdout().lock();
    let mut input = Vec::new();
    let mut stream_case: Option<String> = None;
    let mut alternate_case: Option<String> = None;
    stdout.write_all(b"LTTY_MOSH_FIXTURE_READY\r\nmosh> ")?;
    stdout.flush()?;
    loop {
        let mut byte = [0_u8; 1];
        if stdin.read(&mut byte)? == 0 {
            fs::write(&event_path, b"result=eof\n")?;
            return Ok(());
        }
        if let Some(case_id) = alternate_case.take() {
            stdout.write_all(b"\x1b[?1049l")?;
            writeln!(stdout, "LTTY_MOSH_ALT_CLOSED:{case_id}\r")?;
            stdout.write_all(b"mosh> ")?;
            stdout.flush()?;
            let alternate_event = control_directory.join("mosh-alternate-event");
            write_mosh_terminal_event(
                &alternate_event,
                "alternate",
                &case_id,
                "passed",
                "entered=true\nclosed=true\n",
            )?;
            continue;
        }
        if let Some(case_id) = stream_case.clone() {
            match byte[0] {
                b'\r' | b'\n' => {
                    let passed = input.len() == MOSH_STREAM_INPUT_BYTES
                        && input.iter().all(|value| *value == b'P');
                    let stream_event = control_directory.join("mosh-stream-event");
                    write_mosh_terminal_event(
                        &stream_event,
                        "stream",
                        &case_id,
                        if passed { "passed" } else { "failed" },
                        &format!(
                            "inputBytes={}\noutputFrames={}\n",
                            input.len(),
                            input.len() / 16
                        ),
                    )?;
                    input.clear();
                    stream_case = None;
                    persist_mosh_input(&input_path, &input)?;
                    if passed {
                        writeln!(stdout, "\r\nLTTY_MOSH_STREAM_OK:{case_id}\r")?;
                    } else {
                        writeln!(stdout, "\r\nLTTY_MOSH_STREAM_FAILED:{case_id}\r")?;
                    }
                    stdout.write_all(b"mosh> ")?;
                    stdout.flush()?;
                }
                0x03 => {
                    input.clear();
                    stream_case = None;
                    persist_mosh_input(&input_path, &input)?;
                    stdout.write_all(b"^C\r\nmosh> ")?;
                    stdout.flush()?;
                }
                b'P' if input.len() < MOSH_STREAM_INPUT_BYTES => {
                    input.push(byte[0]);
                    if input.len() % 16 == 0 {
                        stdout.write_all(b".")?;
                        stdout.flush()?;
                    }
                    persist_mosh_input(&input_path, &input)?;
                }
                _ => {}
            }
            continue;
        }
        match byte[0] {
            b'\r' | b'\n' => {
                let command = std::str::from_utf8(&input).unwrap_or("").to_string();
                let mut fields = command.split_ascii_whitespace();
                let kind = fields.next().unwrap_or("").to_string();
                let case_id = fields.next().unwrap_or("");
                let no_more_fields = fields.next().is_none();
                let valid_case = no_more_fields && is_valid_mosh_case_id(case_id);
                let accepted = kind == MOSH_CHECK_COMMAND && valid_case;
                let case_id = case_id.to_string();
                input.clear();
                persist_mosh_input(&input_path, &input)?;
                if accepted {
                    fs::write(&event_path, format!("case={case_id}\nresult=passed\n"))?;
                    writeln!(stdout, "\r\nLTTY_MOSH_CHECK_OK:{case_id}\r")?;
                } else if valid_case && kind == MOSH_SHELL_COMMAND {
                    writeln!(stdout, "\r\nLTTY_MOSH_SHELL_START:{case_id}\r")?;
                    stdout.flush()?;
                    run_mosh_shell(control_directory, &case_id, false)?;
                    writeln!(stdout, "\r\nLTTY_MOSH_SHELL_CLOSED:{case_id}\r")?;
                } else if valid_case && kind == MOSH_TMUX_COMMAND {
                    writeln!(stdout, "\r\nLTTY_MOSH_TMUX_START:{case_id}\r")?;
                    stdout.flush()?;
                    run_mosh_shell(control_directory, &case_id, true)?;
                    writeln!(stdout, "\r\nLTTY_MOSH_TMUX_CLOSED:{case_id}\r")?;
                } else if valid_case && kind == MOSH_EDITOR_COMMAND {
                    writeln!(stdout, "\r\nLTTY_MOSH_EDITOR_START:{case_id}\r")?;
                    stdout.flush()?;
                    run_mosh_editor(control_directory, &case_id)?;
                    writeln!(stdout, "\r\nLTTY_MOSH_EDITOR_CLOSED:{case_id}\r")?;
                } else if valid_case && kind == MOSH_RESIZE_COMMAND {
                    let before = fs::read_to_string(&resize_before_path)?;
                    let (rows, columns) = read_mosh_terminal_size()?;
                    let after = format!("rows={rows}\ncolumns={columns}\n");
                    let resize_event = control_directory.join("mosh-resize-event");
                    write_mosh_terminal_event(
                        &resize_event,
                        "resize",
                        &case_id,
                        if before != after { "passed" } else { "failed" },
                        &format!("before={:?}\nafter={:?}\n", before.trim(), after.trim()),
                    )?;
                    writeln!(stdout, "\r\nLTTY_MOSH_RESIZE_OK:{case_id}\r")?;
                } else if valid_case && kind == MOSH_STREAM_COMMAND {
                    stream_case = Some(case_id.clone());
                    stdout.write_all(b"\r\nstream> ")?;
                    stdout.flush()?;
                    continue;
                } else if valid_case && kind == MOSH_UNICODE_COMMAND {
                    let output = run_mosh_unicode(control_directory, &case_id)?;
                    write!(stdout, "\r\n{output}")?;
                } else if valid_case && kind == MOSH_SCROLLBACK_COMMAND {
                    stdout.write_all(b"\r\n")?;
                    run_mosh_scrollback(control_directory, &case_id, &mut stdout)?;
                } else if valid_case && kind == MOSH_LESS_COMMAND {
                    writeln!(stdout, "\r\nLTTY_MOSH_LESS_START:{case_id}\r")?;
                    stdout.flush()?;
                    run_mosh_less(control_directory, &case_id)?;
                    writeln!(stdout, "\r\nLTTY_MOSH_LESS_CLOSED:{case_id}\r")?;
                } else if valid_case && kind == MOSH_ALTERNATE_COMMAND {
                    let alternate_event = control_directory.join("mosh-alternate-event");
                    remove_file_if_present(&alternate_event)?;
                    stdout.write_all(b"\x1b[?1049h\x1b[2J\x1b[H")?;
                    writeln!(stdout, "LTTY_MOSH_ALT_ACTIVE:{case_id}\r")?;
                    writeln!(
                        stdout,
                        "Press one controlled key to leave alternate screen.\r"
                    )?;
                    stdout.flush()?;
                    alternate_case = Some(case_id);
                    continue;
                } else if valid_case && kind == MOSH_AGENT_COMMAND {
                    writeln!(stdout, "\r\nLTTY_MOSH_AGENT_START:{case_id}\r")?;
                    stdout.flush()?;
                    run_mosh_agent(control_directory, &case_id)?;
                    writeln!(stdout, "\r\nLTTY_MOSH_AGENT_CLOSED:{case_id}\r")?;
                } else {
                    if kernel_echo {
                        fs::write(
                            &prediction_event_path,
                            format!("line={command}\nresult=converged\n"),
                        )?;
                    }
                    writeln!(stdout, "\r\nLTTY_MOSH_COMMAND_REJECTED\r")?;
                }
                stdout.write_all(b"mosh> ")?;
                stdout.flush()?;
            }
            0x03 => {
                input.clear();
                persist_mosh_input(&input_path, &input)?;
                stdout.write_all(b"^C\r\nmosh> ")?;
                stdout.flush()?;
            }
            0x08 | 0x7f => {
                input.pop();
                persist_mosh_input(&input_path, &input)?;
            }
            value if value.is_ascii() && !value.is_ascii_control() && input.len() < 256 => {
                input.push(value);
                persist_mosh_input(&input_path, &input)?;
            }
            _ => {}
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum InteractiveRound {
    NotStarted,
    WaitingForSecond,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
enum SftpFault {
    #[default]
    None,
    PutWriteRemove,
    PermissionDenied,
    RenameUnsupported,
    Unavailable,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
enum DirectTcpipBehavior {
    #[default]
    Disabled,
    ConnectFailed,
    Forward(SocketAddr),
    Stall,
}

impl DirectTcpipBehavior {
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "none" => Ok(Self::Disabled),
            "connect-failed" => Ok(Self::ConnectFailed),
            "stall" => Ok(Self::Stall),
            _ => value.parse::<SocketAddr>().map(Self::Forward).map_err(|_| {
                "direct-tcpip-target must be none, connect-failed, stall or an IP socket address"
                    .to_string()
            }),
        }
    }
}

impl SftpFault {
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "none" => Ok(Self::None),
            "put-write-remove" => Ok(Self::PutWriteRemove),
            "permission-denied" => Ok(Self::PermissionDenied),
            "rename-unsupported" => Ok(Self::RenameUnsupported),
            "unavailable" => Ok(Self::Unavailable),
            _ => Err(
                "sftp-fault must be none, put-write-remove, permission-denied, rename-unsupported or unavailable"
                    .to_string(),
            ),
        }
    }
}

#[derive(Clone)]
struct FixtureServer {
    credentials: Arc<Credentials>,
    public_key_complete: bool,
    password_complete: bool,
    interactive_round: InteractiveRound,
    session_scenario: Option<Scenario>,
    shell_input: Vec<u8>,
    input_snapshot_path: Option<Arc<PathBuf>>,
    pending_perf_request: Option<PerfStreamRequest>,
    pending_paste: Option<PasteTransfer>,
    channels: Arc<Mutex<HashMap<ChannelId, Option<Channel<Msg>>>>>,
    installed_key_fingerprint: Arc<Mutex<Option<String>>>,
    sftp_root: Arc<PathBuf>,
    sftp_delay: Duration,
    sftp_fault: SftpFault,
    direct_tcpip_behavior: DirectTcpipBehavior,
    mosh_fixture: Option<Arc<MoshFixture>>,
    peer_address: Option<SocketAddr>,
}

impl FixtureServer {
    #[cfg(test)]
    fn new(credentials: Arc<Credentials>) -> Self {
        Self::with_sftp_root(
            credentials,
            Arc::new(env::temp_dir().join("leantty-ssh-auth-fixture-test-sftp")),
        )
    }

    #[cfg(test)]
    fn with_sftp_root(credentials: Arc<Credentials>, sftp_root: Arc<PathBuf>) -> Self {
        Self::with_sftp_root_delay_and_fault(
            credentials,
            sftp_root,
            Duration::ZERO,
            SftpFault::None,
            DirectTcpipBehavior::Disabled,
        )
    }

    fn with_sftp_root_delay_and_fault(
        credentials: Arc<Credentials>,
        sftp_root: Arc<PathBuf>,
        sftp_delay: Duration,
        sftp_fault: SftpFault,
        direct_tcpip_behavior: DirectTcpipBehavior,
    ) -> Self {
        Self {
            credentials,
            public_key_complete: false,
            password_complete: false,
            interactive_round: InteractiveRound::NotStarted,
            session_scenario: None,
            shell_input: Vec::new(),
            input_snapshot_path: None,
            pending_perf_request: None,
            pending_paste: None,
            channels: Arc::new(Mutex::new(HashMap::new())),
            installed_key_fingerprint: Arc::new(Mutex::new(None)),
            sftp_root,
            sftp_delay,
            sftp_fault,
            direct_tcpip_behavior,
            mosh_fixture: None,
            peer_address: None,
        }
    }

    fn set_mosh_fixture(&mut self, fixture: MoshFixture) {
        self.mosh_fixture = Some(Arc::new(fixture));
    }

    fn set_input_snapshot_path(&mut self, path: PathBuf) {
        self.input_snapshot_path = Some(Arc::new(path));
    }

    fn persist_fixture_input(&self) -> io::Result<()> {
        if let Some(path) = self.input_snapshot_path.as_ref() {
            fs::write(path.as_ref(), &self.shell_input)?;
        }
        Ok(())
    }

    fn clear_fixture_input(&mut self) -> io::Result<()> {
        self.shell_input.clear();
        self.persist_fixture_input()
    }

    fn take_fixture_command(&mut self, data: &[u8]) -> Option<FixtureCommand> {
        let mut command = None;
        for byte in data {
            if matches!(*byte, b'\r' | b'\n') {
                if command.is_none() {
                    command = parse_fixture_command_line(&self.shell_input);
                    if command.is_none() && !self.shell_input.is_empty() {
                        eprintln!(
                            "fixture command bytes={} result=unrecognized",
                            format_input_hex(&self.shell_input)
                        );
                    }
                }
                self.shell_input.clear();
            } else if byte.is_ascii() && !byte.is_ascii_control() {
                if self.shell_input.len() < 2048 {
                    self.shell_input.push(*byte);
                } else {
                    self.shell_input.clear();
                }
            }
        }
        if let Err(error) = self.persist_fixture_input() {
            eprintln!("connected input snapshot result=error error={error}");
        }
        command
    }

    fn reject(methods: &[MethodKind], partial_success: bool) -> Auth {
        Auth::Reject {
            proceed_with_methods: Some(MethodSet::from(methods)),
            partial_success,
        }
    }

    fn none(&self, user: &str) -> Auth {
        if Scenario::for_user(user) == Some(Scenario::UnsupportedMethod) {
            eprintln!("auth method=none scenario=UnsupportedMethod result=reject");
            return Self::reject(&[MethodKind::HostBased], false);
        }
        Auth::reject()
    }

    fn password(&mut self, user: &str, password: &str) -> Auth {
        let Some(scenario) = Scenario::for_user(user) else {
            eprintln!("auth method=password scenario=unknown result=reject");
            return Self::reject(&[], false);
        };
        if password != self.credentials.password {
            let mismatch = credential_mismatch_summary(&self.credentials.password, password);
            eprintln!(
                "auth method=password scenario={scenario:?} result=reject expected_bytes={} received_bytes={} overlap_mismatches={} length_delta={}",
                mismatch.expected_bytes,
                mismatch.received_bytes,
                mismatch.overlap_mismatches,
                mismatch.length_delta
            );
            return Self::reject(&[MethodKind::Password], self.public_key_complete);
        }

        eprintln!("auth method=password scenario={scenario:?} result=matched");
        match scenario {
            Scenario::Password
            | Scenario::ChannelDenied
            | Scenario::Navigation
            | Scenario::Mosh => {
                self.session_scenario = Some(scenario);
                Auth::Accept
            }
            Scenario::KeyInstall => {
                self.session_scenario = Some(scenario);
                Auth::Accept
            }
            Scenario::PasswordKeyboardInteractive => {
                self.password_complete = true;
                Self::reject(&[MethodKind::KeyboardInteractive], true)
            }
            Scenario::PublicKeyPassword if self.public_key_complete => Auth::Accept,
            Scenario::PublicKeyPassword => Self::reject(&[MethodKind::PublicKey], false),
            _ => Self::reject(&scenario.initial_methods(), false),
        }
    }

    fn public_key(&mut self, user: &str) -> Auth {
        let Some(scenario) = Scenario::for_user(user) else {
            eprintln!("auth method=publickey scenario=unknown result=reject");
            return Self::reject(&[], false);
        };
        eprintln!("auth method=publickey scenario={scenario:?} result=presented");
        match scenario {
            Scenario::PublicKey => Auth::Accept,
            Scenario::PublicKeyPassword => {
                self.public_key_complete = true;
                Self::reject(&[MethodKind::Password], true)
            }
            Scenario::PublicKeyKeyboardInteractive => {
                self.public_key_complete = true;
                Self::reject(&[MethodKind::KeyboardInteractive], true)
            }
            _ => Self::reject(&scenario.initial_methods(), false),
        }
    }

    fn keyboard_interactive(&mut self, user: &str, answers: Option<Vec<Vec<u8>>>) -> Auth {
        let Some(scenario) = Scenario::for_user(user) else {
            eprintln!("auth method=keyboard-interactive scenario=unknown result=reject");
            return Self::reject(&[], false);
        };
        let answer_count = answers.as_ref().map_or(0, Vec::len);
        eprintln!(
            "auth method=keyboard-interactive scenario={scenario:?} answers={answer_count} password_complete={} publickey_complete={} round={:?}",
            self.password_complete, self.public_key_complete, self.interactive_round
        );
        match scenario {
            Scenario::PasswordKeyboardInteractive if !self.password_complete => {
                return Self::reject(&[MethodKind::Password], false);
            }
            Scenario::PublicKeyKeyboardInteractive if !self.public_key_complete => {
                return Self::reject(&[MethodKind::PublicKey], false);
            }
            Scenario::PasswordKeyboardInteractive | Scenario::PublicKeyKeyboardInteractive => {
                if let Some(answers) = answers {
                    if answers
                        == [
                            self.credentials.account.as_bytes(),
                            self.credentials.token.as_bytes(),
                        ]
                    {
                        return Auth::Accept;
                    }
                    return Self::reject(&[MethodKind::KeyboardInteractive], true);
                }
                return interactive_prompt(
                    "LeanTTY controlled authentication",
                    "Enter both temporary fixture values.",
                    &[("Account label: ", true), ("One-time code: ", false)],
                );
            }
            Scenario::KeyboardInteractiveMultiRound => match answers {
                None if self.interactive_round == InteractiveRound::NotStarted => {
                    return interactive_prompt(
                        "LeanTTY round one",
                        "The first response is visible.",
                        &[("Account label: ", true)],
                    );
                }
                Some(answers)
                    if self.interactive_round == InteractiveRound::NotStarted
                        && answers == [self.credentials.account.as_bytes()] =>
                {
                    self.interactive_round = InteractiveRound::WaitingForSecond;
                    return interactive_prompt(
                        "LeanTTY round two",
                        "The second response is secret.",
                        &[("Second one-time code: ", false)],
                    );
                }
                None if self.interactive_round == InteractiveRound::WaitingForSecond => {
                    return interactive_prompt(
                        "LeanTTY round two",
                        "The second response is secret.",
                        &[("Second one-time code: ", false)],
                    );
                }
                Some(answers)
                    if self.interactive_round == InteractiveRound::WaitingForSecond
                        && answers == [self.credentials.second_token.as_bytes()] =>
                {
                    return Auth::Accept;
                }
                _ => {
                    self.interactive_round = InteractiveRound::NotStarted;
                    return Self::reject(&[MethodKind::KeyboardInteractive], false);
                }
            },
            Scenario::KeyboardInteractiveZeroPrompt => match answers {
                None => {
                    return interactive_prompt(
                        "LeanTTY zero-prompt authentication",
                        "No response value is required.",
                        &[],
                    );
                }
                Some(answers) if answers.is_empty() => return Auth::Accept,
                Some(_) => {
                    return Self::reject(&[MethodKind::KeyboardInteractive], false);
                }
            },
            _ => {}
        }
        Self::reject(&scenario.initial_methods(), false)
    }
}

impl Scenario {
    fn initial_methods(self) -> Vec<MethodKind> {
        match self {
            Self::Password
            | Self::PasswordKeyboardInteractive
            | Self::ChannelDenied
            | Self::KeyInstall
            | Self::Navigation
            | Self::Mosh => {
                if self == Self::KeyInstall {
                    vec![MethodKind::PublicKey, MethodKind::Password]
                } else {
                    vec![MethodKind::Password]
                }
            }
            Self::PublicKey | Self::PublicKeyPassword | Self::PublicKeyKeyboardInteractive => {
                vec![MethodKind::PublicKey]
            }
            Self::KeyboardInteractiveMultiRound | Self::KeyboardInteractiveZeroPrompt => {
                vec![MethodKind::KeyboardInteractive]
            }
            Self::UnsupportedMethod => vec![MethodKind::HostBased],
        }
    }
}

fn interactive_prompt(
    name: &'static str,
    instructions: &'static str,
    prompts: &[(&'static str, bool)],
) -> Auth {
    Auth::Partial {
        name: Cow::Borrowed(name),
        instructions: Cow::Borrowed(instructions),
        prompts: Cow::Owned(
            prompts
                .iter()
                .map(|(prompt, echo)| (Cow::Borrowed(*prompt), *echo))
                .collect(),
        ),
    }
}

impl Server for FixtureServer {
    type Handler = Self;

    fn new_client(&mut self, peer_address: Option<SocketAddr>) -> Self {
        let mut client = Self::with_sftp_root_delay_and_fault(
            Arc::clone(&self.credentials),
            Arc::clone(&self.sftp_root),
            self.sftp_delay,
            self.sftp_fault,
            self.direct_tcpip_behavior,
        );
        client.input_snapshot_path = self.input_snapshot_path.as_ref().map(Arc::clone);
        client.installed_key_fingerprint = Arc::clone(&self.installed_key_fingerprint);
        client.mosh_fixture = self.mosh_fixture.as_ref().map(Arc::clone);
        client.peer_address = peer_address;
        client
    }

    fn handle_session_error(&mut self, error: <Self::Handler as Handler>::Error) {
        eprintln!("SSH fixture session failed: {error}");
    }
}

impl Handler for FixtureServer {
    type Error = russh::Error;

    async fn auth_none(&mut self, user: &str) -> Result<Auth, Self::Error> {
        Ok(self.none(user))
    }

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
        Ok(self.password(user, password))
    }

    async fn auth_publickey(
        &mut self,
        user: &str,
        public_key: &PublicKey,
    ) -> Result<Auth, Self::Error> {
        if Scenario::for_user(user) == Some(Scenario::KeyInstall) {
            let actual = public_key.fingerprint(HashAlg::Sha256).to_string();
            let installed = self.installed_key_fingerprint.lock().await;
            let accepted = installed.as_deref() == Some(actual.as_str());
            eprintln!(
                "auth method=publickey scenario=KeyInstall fingerprint={actual} result={}",
                if accepted { "accept" } else { "reject" }
            );
            if accepted {
                self.session_scenario = Some(Scenario::KeyInstall);
                return Ok(Auth::Accept);
            }
            return Ok(Self::reject(&[MethodKind::Password], false));
        }
        Ok(self.public_key(user))
    }

    async fn auth_keyboard_interactive<'a>(
        &'a mut self,
        user: &str,
        _submethods: &str,
        response: Option<Response<'a>>,
    ) -> Result<Auth, Self::Error> {
        let answers = response.map(|values| values.map(|value| value.to_vec()).collect());
        Ok(self.keyboard_interactive(user, answers))
    }

    async fn authentication_banner(&mut self) -> Result<Option<String>, Self::Error> {
        Ok(Some(
            "LeanTTY controlled SSH acceptance fixture — temporary credentials only\r\n"
                .to_string(),
        ))
    }

    async fn channel_open_session(
        &mut self,
        channel: Channel<Msg>,
        reply: russh::server::ChannelOpenHandle,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        if self.session_scenario == Some(Scenario::ChannelDenied) {
            eprintln!("channel open scenario=ChannelDenied result=deny");
            reply
                .reject(ChannelOpenFailure::AdministrativelyProhibited)
                .await;
            return Ok(());
        }
        eprintln!(
            "channel open scenario={:?} result=accept",
            self.session_scenario
        );
        self.channels
            .lock()
            .await
            .insert(channel.id(), Some(channel));
        reply.accept().await;
        Ok(())
    }

    async fn channel_open_direct_tcpip(
        &mut self,
        channel: Channel<Msg>,
        host_to_connect: &str,
        port_to_connect: u32,
        _originator_address: &str,
        _originator_port: u32,
        reply: russh::server::ChannelOpenHandle,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        let requested_target = host_to_connect.parse::<IpAddr>().ok().and_then(|address| {
            u16::try_from(port_to_connect)
                .ok()
                .map(|port| SocketAddr::new(address, port))
        });
        let allowed_target = match self.direct_tcpip_behavior {
            DirectTcpipBehavior::Disabled => {
                eprintln!("direct-tcpip result=deny reason=disabled");
                reply
                    .reject(ChannelOpenFailure::AdministrativelyProhibited)
                    .await;
                return Ok(());
            }
            DirectTcpipBehavior::ConnectFailed => {
                eprintln!("direct-tcpip result=connect-failed reason=injected");
                reply.reject(ChannelOpenFailure::ConnectFailed).await;
                return Ok(());
            }
            DirectTcpipBehavior::Stall => {
                eprintln!("direct-tcpip result=stall");
                return std::future::pending::<Result<(), Self::Error>>().await;
            }
            DirectTcpipBehavior::Forward(target) => target,
        };
        if requested_target != Some(allowed_target) {
            eprintln!(
                "direct-tcpip result=deny requested={host_to_connect}:{port_to_connect} allowed={allowed_target}"
            );
            reply
                .reject(ChannelOpenFailure::AdministrativelyProhibited)
                .await;
            return Ok(());
        }
        let Ok(mut target_stream) = TcpStream::connect(allowed_target).await else {
            eprintln!("direct-tcpip result=connect-failed target={allowed_target}");
            reply.reject(ChannelOpenFailure::ConnectFailed).await;
            return Ok(());
        };
        let mut channel_stream = channel.into_stream();
        reply.accept().await;
        eprintln!("direct-tcpip result=accept target={allowed_target}");
        tokio::spawn(async move {
            let _ = tokio::io::copy_bidirectional(&mut channel_stream, &mut target_stream).await;
            eprintln!("direct-tcpip result=closed target={allowed_target}");
        });
        Ok(())
    }

    async fn subsystem_request(
        &mut self,
        channel_id: ChannelId,
        name: &str,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        if name != "sftp" {
            session.channel_failure(channel_id)?;
            return Ok(());
        }
        if self.sftp_fault == SftpFault::Unavailable {
            self.channels.lock().await.remove(&channel_id);
            session.channel_failure(channel_id)?;
            eprintln!("channel subsystem=sftp result=unavailable");
            return Ok(());
        }
        let Some(Some(channel)) = self.channels.lock().await.remove(&channel_id) else {
            session.channel_failure(channel_id)?;
            return Ok(());
        };
        session.channel_success(channel_id)?;
        eprintln!("channel subsystem=sftp result=accept");
        let sftp_root = Arc::clone(&self.sftp_root);
        let sftp_delay = self.sftp_delay;
        let sftp_fault = self.sftp_fault;
        tokio::spawn(async move {
            russh_sftp::server::run(
                channel.into_stream(),
                FixtureSftp::with_behavior(sftp_root, sftp_delay, sftp_fault),
            )
            .await;
        });
        Ok(())
    }

    async fn pty_request(
        &mut self,
        channel: ChannelId,
        _term: &str,
        _col_width: u32,
        _row_height: u32,
        _pix_width: u32,
        _pix_height: u32,
        _modes: &[(russh::Pty, u32)],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)?;
        Ok(())
    }

    async fn shell_request(
        &mut self,
        channel: ChannelId,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        let shell_channel = self
            .channels
            .lock()
            .await
            .get_mut(&channel)
            .and_then(Option::take);
        let Some(mut shell_channel) = shell_channel else {
            session.channel_failure(channel)?;
            return Ok(());
        };
        // russh delivers each incoming channel message to this receiver before
        // invoking Handler::data. Leaving it unread fills the default 100-item
        // buffer and blocks the fixture session even though Handler::data is in use.
        tokio::spawn(async move { while shell_channel.wait().await.is_some() {} });
        session.channel_success(channel)?;
        let greeting = if self.session_scenario == Some(Scenario::Navigation) {
            b"\x1b]52;c;bGVhbnR0eS1rZXktcGFzdGU=\x07LEANTTY_AUTH_FIXTURE_OK\r\nfixture> ".as_slice()
        } else {
            b"LEANTTY_AUTH_FIXTURE_OK\r\nfixture> ".as_slice()
        };
        session.data(channel, greeting)?;
        Ok(())
    }

    async fn exec_request(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        eprintln!("channel callback=exec scenario={:?}", self.session_scenario);
        if self.session_scenario == Some(Scenario::Mosh) {
            let bootstrap_request = parse_mosh_bootstrap_request(data);
            let bootstrap = match (
                bootstrap_request,
                self.mosh_fixture.as_ref(),
                self.peer_address,
            ) {
                (Some(requested), Some(fixture), Some(peer)) => {
                    fixture.bootstrap(peer, requested).await
                }
                _ => Err(io::Error::other(
                    "invalid controlled Mosh bootstrap request",
                )),
            };
            session.channel_success(channel)?;
            match bootstrap {
                Ok(output) => {
                    session.data(channel, output)?;
                    session.exit_status_request(channel, 0)?;
                }
                Err(error) => {
                    eprintln!("mosh bootstrap result=failed error={error}");
                    session.data(channel, b"MOSH FIXTURE ERROR\n".as_slice())?;
                    session.exit_status_request(channel, 1)?;
                }
            }
            session.eof(channel)?;
            session.close(channel)?;
            return Ok(());
        }
        session.channel_success(channel)?;
        session.data(channel, b"LEANTTY_AUTH_FIXTURE_OK\n".as_slice())?;
        session.exit_status_request(channel, 0)?;
        session.eof(channel)?;
        session.close(channel)?;
        Ok(())
    }

    async fn data(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        if !self.channels.lock().await.contains_key(&channel) {
            return Ok(());
        }
        if let Some(transfer) = self.pending_paste.as_mut() {
            let remaining = transfer.payload.len() - transfer.received;
            let accepted = remaining.min(data.len());
            let expected = &transfer.payload[transfer.received..transfer.received + accepted];
            if data.len() > remaining || &data[..accepted] != expected {
                eprintln!("paste case={} result=mismatch", transfer.case_id);
                session.data(channel, b"\r\nLTTY_PASTE_FAIL\r\nfixture> ".as_slice())?;
                self.pending_paste = None;
                return Ok(());
            }
            transfer.received += accepted;
            eprintln!(
                "paste case={} received={} total={} state=progress",
                transfer.case_id,
                transfer.received,
                transfer.payload.len()
            );
            if transfer.received == transfer.payload.len() {
                let marker = format!(
                    "\r\nLTTY_PASTE_OK:{}:{}\r\nfixture> ",
                    transfer.case_id,
                    transfer.payload.len()
                );
                eprintln!(
                    "paste case={} bytes={} result=matched",
                    transfer.case_id,
                    transfer.payload.len()
                );
                session.data(channel, marker.into_bytes())?;
                self.pending_paste = None;
            }
            return Ok(());
        }
        if data.contains(&0x04) {
            session.data(channel, b"logout\r\n".as_slice())?;
            session.exit_status_request(channel, 0)?;
            session.eof(channel)?;
            session.close(channel)?;
            return Ok(());
        }
        if self.session_scenario == Some(Scenario::Navigation) {
            eprintln!("navigation input hex={}", format_input_hex(data));
            let captured = format!(
                "\r\nLEANTTY_INPUT_HEX:{}\r\nfixture> ",
                format_input_hex(data)
            );
            session.data(channel, captured.into_bytes())?;
            return Ok(());
        }
        if data.contains(&0x03) {
            self.clear_fixture_input()?;
            eprintln!("connected input state=cleared");
            session.data(channel, b"^C\r\nfixture> ".as_slice())?;
            return Ok(());
        }
        session.data(channel, data.to_vec())?;
        match self.take_fixture_command(data) {
            Some(FixtureCommand::KeyInstall(request)) => {
                *self.installed_key_fingerprint.lock().await = Some(request.fingerprint.clone());
                eprintln!(
                    "key-install fingerprint={} result=installed",
                    request.fingerprint
                );
                let response = format!("\r\n{}:0\r\n", request.marker);
                session.data(channel, response.into_bytes())?;
            }
            Some(FixtureCommand::Perf(PerfCommand::Prepare(request))) => {
                let expected_bytes = perf_stream_expected_bytes(&request);
                eprintln!(
                    "perf case={} lines={} width={} bytes={} state=prepared",
                    request.case_id, request.lines, request.line_width, expected_bytes
                );
                let begin = format!(
                    "\x1b]0;LTTY_PERF_BEGIN__:{}:{}\x07\r\nfixture> ",
                    request.case_id, expected_bytes
                );
                self.pending_perf_request = Some(request);
                session.data(channel, begin.into_bytes())?;
            }
            Some(FixtureCommand::Perf(PerfCommand::Run(case_id))) => {
                let Some(request) = self.pending_perf_request.take() else {
                    return Ok(());
                };
                if request.case_id != case_id {
                    self.pending_perf_request = Some(request);
                    return Ok(());
                }
                eprintln!("perf case={case_id} state=run");
                let payload = build_perf_stream_payload(&request);
                let end = format!(
                    "\x1b]0;LTTY_PERF_END__:{}\x07\r\nfixture> ",
                    request.case_id
                );
                let handle = session.handle();
                tokio::spawn(async move {
                    for chunk in payload.chunks(PERF_OUTPUT_CHUNK_BYTES) {
                        if handle.data(channel, chunk.to_vec()).await.is_err() {
                            return;
                        }
                        tokio::time::sleep(Duration::from_millis(5)).await;
                    }
                    let _ = handle.data(channel, end.into_bytes()).await;
                });
            }
            Some(FixtureCommand::Paste(request)) => {
                let payload = build_paste_payload(&request);
                let encoded = encode_base64(&payload);
                let response = format!(
                    "\x1b]52;c;{}\x07\r\nLTTY_PASTE_READY:{}:{}\r\nfixture> ",
                    encoded,
                    request.case_id,
                    payload.len()
                );
                self.pending_paste = Some(PasteTransfer {
                    case_id: request.case_id,
                    payload,
                    received: 0,
                });
                session.data(channel, response.into_bytes())?;
            }
            Some(FixtureCommand::InputCheck(case_id)) => {
                eprintln!("input case={case_id} result=matched");
                let response = format!("\r\nLTTY_INPUT_OK:{case_id}\r\nfixture> ");
                session.data(channel, response.into_bytes())?;
            }
            Some(FixtureCommand::TerminalDirty(case_id)) => {
                eprintln!("terminal dirty case={case_id} result=enabled");
                let response = format!(
                    "\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l\x1b[?1003h\x1b[?1006h\x1b[?1004h\x1b[?2004h\x1b]0;LTTY_DIRTY:{case_id}\x07\x1b[38;5;196mLTTY_DIRTY:{case_id}\x1b[0m"
                );
                session.data(channel, response.into_bytes())?;
            }
            Some(FixtureCommand::Exit) => {
                eprintln!("shell command=exit result=closed");
                session.data(channel, b"logout\r\n".as_slice())?;
                session.exit_status_request(channel, 0)?;
                session.eof(channel)?;
                session.close(channel)?;
            }
            Some(FixtureCommand::Bell(request)) => {
                eprintln!(
                    "bell case={} delay_ms={} state=scheduled",
                    request.case_id, request.delay_ms
                );
                let handle = session.handle();
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(request.delay_ms)).await;
                    let response = format!("\x07\r\nLTTY_BELL_OK:{}\r\nfixture> ", request.case_id);
                    let state = if handle.data(channel, response.into_bytes()).await.is_ok() {
                        "sent"
                    } else {
                        "send-failed"
                    };
                    eprintln!("bell case={} state={state}", request.case_id);
                });
            }
            None => {}
        }
        Ok(())
    }

    async fn window_change_request(
        &mut self,
        _channel: ChannelId,
        col_width: u32,
        row_height: u32,
        _pix_width: u32,
        _pix_height: u32,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        eprintln!("resize cols={col_width} rows={row_height}");
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct PerfStreamRequest {
    case_id: String,
    lines: usize,
    line_width: usize,
}

#[derive(Debug, Eq, PartialEq)]
enum PerfCommand {
    Prepare(PerfStreamRequest),
    Run(String),
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct PasteRequest {
    case_id: String,
    bytes: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct BellRequest {
    case_id: String,
    delay_ms: u64,
}

#[derive(Clone, Debug)]
struct PasteTransfer {
    case_id: String,
    payload: Vec<u8>,
    received: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct KeyInstallRequest {
    fingerprint: String,
    marker: String,
}

#[derive(Debug, Eq, PartialEq)]
enum FixtureCommand {
    KeyInstall(KeyInstallRequest),
    Perf(PerfCommand),
    Paste(PasteRequest),
    InputCheck(String),
    TerminalDirty(String),
    Exit,
    Bell(BellRequest),
}

fn parse_fixture_command(input: &[u8]) -> Option<FixtureCommand> {
    if let Some(request) = parse_key_install_command(input) {
        return Some(FixtureCommand::KeyInstall(request));
    }
    if let Some(command) = parse_perf_command(input) {
        return Some(FixtureCommand::Perf(command));
    }
    let command = std::str::from_utf8(input).ok()?;
    let mut parts = command.split_ascii_whitespace();
    let kind = parts.next()?;
    if kind == EXIT_COMMAND {
        return parts.next().is_none().then_some(FixtureCommand::Exit);
    }
    let case_id = parts.next()?;
    if kind == INPUT_CHECK_COMMAND {
        return (parts.next().is_none() && is_valid_perf_case_id(case_id))
            .then(|| FixtureCommand::InputCheck(case_id.to_string()));
    }
    if kind == TERMINAL_DIRTY_COMMAND {
        return (parts.next().is_none() && is_valid_perf_case_id(case_id))
            .then(|| FixtureCommand::TerminalDirty(case_id.to_string()));
    }
    if kind == BELL_COMMAND {
        let delay_ms = parts.next()?.parse::<u64>().ok()?;
        return (parts.next().is_none()
            && is_valid_perf_case_id(case_id)
            && (BELL_MIN_DELAY_MS..=BELL_MAX_DELAY_MS).contains(&delay_ms))
        .then(|| {
            FixtureCommand::Bell(BellRequest {
                case_id: case_id.to_string(),
                delay_ms,
            })
        });
    }
    if kind != PASTE_PREPARE_COMMAND {
        return None;
    }
    let bytes = parts.next()?.parse::<usize>().ok()?;
    if parts.next().is_some()
        || !is_valid_perf_case_id(case_id)
        || !(1..=PASTE_MAX_BYTES).contains(&bytes)
    {
        return None;
    }
    Some(FixtureCommand::Paste(PasteRequest {
        case_id: case_id.to_string(),
        bytes,
    }))
}

fn parse_key_install_command(input: &[u8]) -> Option<KeyInstallRequest> {
    let command = std::str::from_utf8(input).ok()?;
    let key_prefix = "(grep -qxF -- '";
    let key_start = command.find(key_prefix)? + key_prefix.len();
    let key_suffix = "' ~/.ssh/authorized_keys";
    let key_end = command[key_start..].find(key_suffix)? + key_start;
    let public_key = PublicKey::from_openssh(&command[key_start..key_end]).ok()?;

    let marker_prefix = "'__LTTY_KEYPUSH_";
    let marker_start = command.find(marker_prefix)? + 1;
    let marker_end = command[marker_start..].find('\'')? + marker_start;
    let marker = &command[marker_start..marker_end];
    let timestamp = marker.strip_prefix("__LTTY_KEYPUSH_")?;
    if timestamp.is_empty() || !timestamp.bytes().all(|value| value.is_ascii_digit()) {
        return None;
    }
    Some(KeyInstallRequest {
        fingerprint: public_key.fingerprint(HashAlg::Sha256).to_string(),
        marker: marker.to_string(),
    })
}

fn parse_fixture_command_line(input: &[u8]) -> Option<FixtureCommand> {
    if let Some(command) = parse_fixture_command(input) {
        return Some(command);
    }
    input
        .windows(5)
        .rposition(|window| window == b"ltty-")
        .and_then(|index| parse_fixture_command(&input[index..]))
}

fn build_paste_payload(request: &PasteRequest) -> Vec<u8> {
    let pattern = format!("LTTY_PASTE_{}|", request.case_id);
    pattern
        .bytes()
        .cycle()
        .take(request.bytes)
        .collect::<Vec<_>>()
}

fn encode_base64(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut output = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let first = chunk[0];
        let second = *chunk.get(1).unwrap_or(&0);
        let third = *chunk.get(2).unwrap_or(&0);
        output.push(TABLE[(first >> 2) as usize] as char);
        output.push(TABLE[(((first & 0x03) << 4) | (second >> 4)) as usize] as char);
        output.push(if chunk.len() > 1 {
            TABLE[(((second & 0x0f) << 2) | (third >> 6)) as usize] as char
        } else {
            '='
        });
        output.push(if chunk.len() > 2 {
            TABLE[(third & 0x3f) as usize] as char
        } else {
            '='
        });
    }
    output
}

fn is_valid_perf_case_id(case_id: &str) -> bool {
    !case_id.is_empty()
        && case_id.len() <= PERF_MAX_CASE_ID_LENGTH
        && case_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn parse_perf_command(input: &[u8]) -> Option<PerfCommand> {
    let command = std::str::from_utf8(input).ok()?;
    let mut parts = command.split_ascii_whitespace();
    let kind = parts.next()?;
    let case_id = parts.next()?;
    if !is_valid_perf_case_id(case_id) {
        return None;
    }
    if kind == PERF_RUN_COMMAND {
        return (parts.next().is_none()).then(|| PerfCommand::Run(case_id.to_string()));
    }
    if kind != PERF_PREPARE_COMMAND {
        return None;
    }
    let lines = parts.next()?.parse::<usize>().ok()?;
    let line_width = parts.next()?.parse::<usize>().ok()?;
    if parts.next().is_some()
        || !(1..=PERF_MAX_LINES).contains(&lines)
        || !(PERF_MIN_LINE_WIDTH..=PERF_MAX_LINE_WIDTH).contains(&line_width)
    {
        return None;
    }
    Some(PerfCommand::Prepare(PerfStreamRequest {
        case_id: case_id.to_string(),
        lines,
        line_width,
    }))
}

fn build_perf_stream_payload(request: &PerfStreamRequest) -> Vec<u8> {
    let mut payload = Vec::with_capacity((request.line_width + 2) * request.lines);
    for line in 0..request.lines {
        let prefix = format!("LTTY_PERF_{}_{line:05} ", request.case_id);
        payload.extend_from_slice(prefix.as_bytes());
        payload.resize(payload.len() + request.line_width - prefix.len(), b'X');
        payload.extend_from_slice(b"\r\n");
    }
    payload
}

fn perf_stream_expected_bytes(request: &PerfStreamRequest) -> usize {
    let prefix = format!("LTTY_PERF_{}_{:05} ", request.case_id, 0);
    (request.line_width - prefix.len()) * request.lines
}

fn format_input_hex(data: &[u8]) -> String {
    data.iter()
        .map(|value| format!("{value:02x}"))
        .collect::<Vec<_>>()
        .join(" ")
}

struct FixtureSftp {
    root: Arc<PathBuf>,
    files: HashMap<String, fs::File>,
    next_handle: u64,
    delay: Duration,
    fault: SftpFault,
}

impl FixtureSftp {
    #[cfg(test)]
    fn new(root: Arc<PathBuf>) -> Self {
        Self::with_behavior(root, Duration::ZERO, SftpFault::None)
    }

    fn with_behavior(root: Arc<PathBuf>, delay: Duration, fault: SftpFault) -> Self {
        Self {
            root,
            files: HashMap::new(),
            next_handle: 1,
            delay,
            fault,
        }
    }

    async fn delay_operation(&self) {
        if !self.delay.is_zero() {
            tokio::time::sleep(self.delay).await;
        }
    }

    fn path(&self, remote_path: &str) -> Result<PathBuf, StatusCode> {
        let relative = remote_path.strip_prefix('/').unwrap_or(remote_path);
        if relative.is_empty() {
            return Err(StatusCode::PermissionDenied);
        }
        let mut resolved = self.root.as_ref().clone();
        for component in relative.split('/') {
            if component.is_empty()
                || component == "."
                || component == ".."
                || component.contains('\\')
                || component.contains('\0')
            {
                return Err(StatusCode::PermissionDenied);
            }
            resolved.push(component);
        }
        Ok(resolved)
    }

    fn status(id: u32) -> Status {
        Status {
            id,
            status_code: StatusCode::Ok,
            error_message: "Ok".to_string(),
            language_tag: "en-US".to_string(),
        }
    }

    fn io_status(error: &io::Error) -> StatusCode {
        match error.kind() {
            io::ErrorKind::NotFound => StatusCode::NoSuchFile,
            io::ErrorKind::PermissionDenied => StatusCode::PermissionDenied,
            _ => StatusCode::Failure,
        }
    }
}

impl russh_sftp::server::Handler for FixtureSftp {
    type Error = StatusCode;

    fn unimplemented(&self) -> Self::Error {
        StatusCode::OpUnsupported
    }

    async fn open(
        &mut self,
        id: u32,
        filename: String,
        pflags: OpenFlags,
        _attrs: FileAttributes,
    ) -> Result<Handle, Self::Error> {
        if self.fault == SftpFault::PermissionDenied {
            eprintln!("sftp open id={id} path={filename} result=permission-denied");
            return Err(StatusCode::PermissionDenied);
        }
        let path = self.path(&filename)?;
        let options: fs::OpenOptions = pflags.into();
        let file = options
            .open(path)
            .map_err(|error| Self::io_status(&error))?;
        let handle = format!("file-{}", self.next_handle);
        self.next_handle += 1;
        self.files.insert(handle.clone(), file);
        eprintln!("sftp open id={id} handle={handle} flags={pflags:?}");
        Ok(Handle { id, handle })
    }

    async fn close(&mut self, id: u32, handle: String) -> Result<Status, Self::Error> {
        if self.files.remove(&handle).is_none() {
            return Err(StatusCode::Failure);
        }
        eprintln!("sftp close id={id} handle={handle} result=ok");
        Ok(Self::status(id))
    }

    async fn read(
        &mut self,
        id: u32,
        handle: String,
        offset: u64,
        len: u32,
    ) -> Result<Data, Self::Error> {
        self.delay_operation().await;
        let file = self.files.get(&handle).ok_or(StatusCode::Failure)?;
        let mut data = vec![0_u8; len as usize];
        let read = file
            .read_at(&mut data, offset)
            .map_err(|error| Self::io_status(&error))?;
        if read == 0 {
            eprintln!("sftp read id={id} handle={handle} offset={offset} len={len} result=eof");
            return Err(StatusCode::Eof);
        }
        data.truncate(read);
        eprintln!("sftp read id={id} handle={handle} offset={offset} len={len} bytes={read}");
        Ok(Data { id, data })
    }

    async fn write(
        &mut self,
        id: u32,
        handle: String,
        offset: u64,
        data: Vec<u8>,
    ) -> Result<Status, Self::Error> {
        self.delay_operation().await;
        if self.fault == SftpFault::PutWriteRemove {
            eprintln!("sftp write id={id} handle={handle} result=injected-failure");
            return Err(StatusCode::Failure);
        }
        let file = self.files.get(&handle).ok_or(StatusCode::Failure)?;
        let mut written = 0_usize;
        while written < data.len() {
            let count = file
                .write_at(&data[written..], offset + written as u64)
                .map_err(|error| Self::io_status(&error))?;
            if count == 0 {
                return Err(StatusCode::Failure);
            }
            written += count;
        }
        Ok(Self::status(id))
    }

    async fn lstat(&mut self, id: u32, path: String) -> Result<Attrs, Self::Error> {
        let metadata =
            fs::symlink_metadata(self.path(&path)?).map_err(|error| Self::io_status(&error))?;
        eprintln!("sftp lstat id={id} result=ok");
        Ok(Attrs {
            id,
            attrs: FileAttributes::from(&metadata),
        })
    }

    async fn fstat(&mut self, id: u32, handle: String) -> Result<Attrs, Self::Error> {
        let metadata = self
            .files
            .get(&handle)
            .ok_or(StatusCode::Failure)?
            .metadata()
            .map_err(|error| Self::io_status(&error))?;
        eprintln!("sftp fstat id={id} handle={handle} result=ok");
        Ok(Attrs {
            id,
            attrs: FileAttributes::from(&metadata),
        })
    }

    async fn remove(&mut self, id: u32, filename: String) -> Result<Status, Self::Error> {
        if self.fault == SftpFault::PutWriteRemove {
            eprintln!("sftp remove id={id} path={filename} result=injected-failure");
            return Err(StatusCode::PermissionDenied);
        }
        fs::remove_file(self.path(&filename)?).map_err(|error| Self::io_status(&error))?;
        Ok(Self::status(id))
    }

    async fn rename(
        &mut self,
        id: u32,
        oldpath: String,
        newpath: String,
    ) -> Result<Status, Self::Error> {
        if self.fault == SftpFault::RenameUnsupported {
            eprintln!("sftp rename id={id} old={oldpath} new={newpath} result=unsupported");
            return Err(StatusCode::OpUnsupported);
        }
        let old = self.path(&oldpath)?;
        let new = self.path(&newpath)?;
        fs::hard_link(&old, &new).map_err(|error| Self::io_status(&error))?;
        if let Err(error) = fs::remove_file(&old) {
            let _ = fs::remove_file(&new);
            return Err(Self::io_status(&error));
        }
        Ok(Self::status(id))
    }
}

struct Arguments {
    listen: String,
    credentials_path: PathBuf,
    run_seconds: u64,
    ready_path: Option<PathBuf>,
    sftp_delay_ms: u64,
    sftp_fault: SftpFault,
    direct_tcpip_behavior: DirectTcpipBehavior,
    server_output_drop_path: Option<PathBuf>,
    mosh_server_address: Option<IpAddr>,
    mosh_server_port: Option<u16>,
    mosh_network_timeout_seconds: u64,
}

fn parse_arguments(mut arguments: impl Iterator<Item = String>) -> Result<Arguments, String> {
    let executable = arguments
        .next()
        .unwrap_or_else(|| "ssh-auth-fixture".to_string());
    let usage = || {
        format!(
            "usage: {executable} <listen-address> <credentials-file> [run-seconds] [ready-file] [sftp-delay-ms] [sftp-fault] [direct-tcpip-target] [server-output-drop-file] [mosh-server-address] [mosh-server-port] [mosh-network-timeout-seconds]"
        )
    };
    let listen = arguments.next().ok_or_else(&usage)?;
    let credentials_path = PathBuf::from(arguments.next().ok_or_else(&usage)?);
    let run_seconds = arguments
        .next()
        .map(|value| {
            value
                .parse::<u64>()
                .map_err(|_| "run-seconds must be an unsigned integer".to_string())
        })
        .transpose()?
        .unwrap_or(900);
    if run_seconds == 0 {
        return Err("run-seconds must be greater than zero".to_string());
    }
    let ready_path = arguments.next().map(PathBuf::from);
    let sftp_delay_ms = arguments
        .next()
        .map(|value| {
            value
                .parse::<u64>()
                .map_err(|_| "sftp-delay-ms must be an unsigned integer".to_string())
        })
        .transpose()?
        .unwrap_or(0);
    if sftp_delay_ms > 5000 {
        return Err("sftp-delay-ms must be at most 5000".to_string());
    }
    let sftp_fault = arguments
        .next()
        .map(|value| SftpFault::parse(&value))
        .transpose()?
        .unwrap_or_default();
    let direct_tcpip_behavior = arguments
        .next()
        .map(|value| DirectTcpipBehavior::parse(&value))
        .transpose()?
        .unwrap_or_default();
    let server_output_drop_path = arguments.next().and_then(|value| {
        if value == "none" {
            None
        } else {
            Some(PathBuf::from(value))
        }
    });
    let mosh_server_address = arguments
        .next()
        .and_then(|value| (value != "none").then_some(value))
        .map(|value| {
            value
                .parse::<IpAddr>()
                .map_err(|_| "mosh-server-address must be an IP address".to_string())
        })
        .transpose()?;
    let mosh_server_port = arguments
        .next()
        .map(|value| {
            value
                .parse::<u16>()
                .map_err(|_| "mosh-server-port must be an unsigned 16-bit integer".to_string())
        })
        .transpose()?
        .and_then(|value| (value != 0).then_some(value));
    let mosh_network_timeout_seconds = arguments
        .next()
        .map(|value| {
            value
                .parse::<u64>()
                .map_err(|_| "mosh-network-timeout-seconds must be an unsigned integer".to_string())
        })
        .transpose()?
        .unwrap_or(MOSH_FIXTURE_NETWORK_TIMEOUT_SECONDS);
    if !(1..=7200).contains(&mosh_network_timeout_seconds) {
        return Err("mosh-network-timeout-seconds must be between 1 and 7200".to_string());
    }
    if arguments.next().is_some() {
        return Err(usage());
    }
    Ok(Arguments {
        listen,
        credentials_path,
        run_seconds,
        ready_path,
        sftp_delay_ms,
        sftp_fault,
        direct_tcpip_behavior,
        server_output_drop_path,
        mosh_server_address,
        mosh_server_port,
        mosh_network_timeout_seconds,
    })
}

fn spawn_server_output_drop_proxy(
    listener: TcpListener,
    target: SocketAddr,
    drop_path: PathBuf,
) -> JoinHandle<io::Result<()>> {
    tokio::spawn(async move {
        loop {
            let (client, client_address) = listener.accept().await?;
            let server = TcpStream::connect(target).await?;
            let connection_drop_path = drop_path.clone();
            tokio::spawn(async move {
                let (mut client_read, mut client_write) = client.into_split();
                let (mut server_read, mut server_write) = server.into_split();
                let client_to_server = tokio::io::copy(&mut client_read, &mut server_write);
                let server_to_client = async {
                    let mut buffer = [0_u8; 16 * 1024];
                    let mut dropping = false;
                    loop {
                        let read = server_read.read(&mut buffer).await?;
                        if read == 0 {
                            client_write.shutdown().await?;
                            return Ok::<(), io::Error>(());
                        }
                        if connection_drop_path.exists() {
                            if !dropping {
                                eprintln!(
                                    "transport proxy client={client_address} mode=drop-server-output"
                                );
                                dropping = true;
                            }
                            continue;
                        }
                        client_write.write_all(&buffer[..read]).await?;
                    }
                };
                tokio::pin!(client_to_server);
                tokio::pin!(server_to_client);
                tokio::select! {
                    _ = &mut client_to_server => {}
                    _ = &mut server_to_client => {}
                }
            });
        }
    })
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut raw_arguments = env::args();
    let _executable = raw_arguments.next();
    if raw_arguments.next().as_deref() == Some(MOSH_TERMINAL_SUBCOMMAND) {
        let control_directory = raw_arguments
            .next()
            .ok_or("mosh terminal control directory is missing")?;
        if raw_arguments.next().is_some() {
            return Err("mosh terminal accepts exactly one control directory".into());
        }
        return run_mosh_terminal(Path::new(&control_directory)).map_err(Into::into);
    }
    let arguments = parse_arguments(env::args()).map_err(|error| error.to_string())?;
    let sftp_root = arguments
        .credentials_path
        .parent()
        .ok_or("fixture credentials path has no parent")?
        .join("sftp-root");
    let input_snapshot_path = arguments
        .credentials_path
        .parent()
        .ok_or("fixture credentials path has no parent")?
        .join("connected-input-snapshot");
    match fs::remove_file(&input_snapshot_path) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    fs::create_dir_all(&sftp_root)?;
    let credentials = Arc::new(
        Credentials::load(&arguments.credentials_path).map_err(|error| error.to_string())?,
    );
    let (socket, address, _proxy) =
        if let Some(drop_path) = arguments.server_output_drop_path.clone() {
            let server_socket = TcpListener::bind("127.0.0.1:0").await?;
            let server_address = server_socket.local_addr()?;
            let public_socket = TcpListener::bind(&arguments.listen).await?;
            let public_address = public_socket.local_addr()?;
            let proxy = spawn_server_output_drop_proxy(public_socket, server_address, drop_path);
            (server_socket, public_address, Some(proxy))
        } else {
            let server_socket = TcpListener::bind(&arguments.listen).await?;
            let server_address = server_socket.local_addr()?;
            (server_socket, server_address, None)
        };
    let config = Arc::new(russh::server::Config {
        inactivity_timeout: Some(Duration::from_secs(arguments.run_seconds)),
        auth_rejection_time: Duration::from_millis(50),
        auth_rejection_time_initial: Some(Duration::ZERO),
        keys: vec![PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519)?],
        ..Default::default()
    });
    let mut fixture = FixtureServer::with_sftp_root_delay_and_fault(
        credentials,
        Arc::new(sftp_root),
        Duration::from_millis(arguments.sftp_delay_ms),
        arguments.sftp_fault,
        arguments.direct_tcpip_behavior,
    );
    if let Some(server_address) = arguments.mosh_server_address {
        if !server_address.is_ipv4() {
            return Err("controlled Mosh fixture currently requires IPv4".into());
        }
        fixture.set_mosh_fixture(MoshFixture {
            server_address,
            ssh_port: address.port(),
            udp_port: arguments.mosh_server_port,
            network_timeout_seconds: arguments.mosh_network_timeout_seconds,
            control_directory: Arc::new(
                arguments
                    .credentials_path
                    .parent()
                    .ok_or("fixture credentials path has no parent")?
                    .to_path_buf(),
            ),
            executable_path: Arc::new(env::current_exe()?),
            previous_session_key: Arc::new(Mutex::new(None)),
            next_session_index: Arc::new(AtomicU64::new(0)),
        });
    }
    fixture.set_input_snapshot_path(input_snapshot_path);
    fixture.clear_fixture_input()?;
    let running = fixture.run_on_socket(config, &socket);
    let handle = running.handle();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(arguments.run_seconds)).await;
        handle.shutdown("fixture lifetime expired".into());
    });
    if let Some(ready_path) = arguments.ready_path {
        let mut ready = format!("address={address}\npid={}\n", std::process::id());
        if let Some(drop_path) = &arguments.server_output_drop_path {
            ready.push_str(&format!(
                "server_output_drop_file={}\n",
                drop_path.display()
            ));
        }
        fs::write(ready_path, ready)?;
    }
    println!(
        "LEANTTY_SSH_AUTH_FIXTURE_READY address={address} pid={}",
        std::process::id()
    );
    println!(
        "users={USER_PASSWORD},{USER_PUBLICKEY},{USER_PASSWORD_KBDINT},{USER_PUBLICKEY_PASSWORD},{USER_PUBLICKEY_KBDINT},{USER_KBDINT_MULTIROUND},{USER_KBDINT_ZERO},{USER_UNSUPPORTED},{USER_CHANNEL_DENIED},{USER_NAVIGATION},{USER_NAVIGATION_TWO},{USER_NAVIGATION_THREE},{USER_MOSH}"
    );
    running.await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::error::Error;

    #[test]
    fn prediction_fixture_uses_kernel_echo_without_changing_other_scenarios() {
        assert_eq!(mosh_terminal_stty_args(true), Vec::<&'static str>::new());
        assert_eq!(
            mosh_terminal_stty_args(false),
            ["-icanon", "-echo", "min", "1", "time", "0"]
        );
    }

    #[test]
    fn names_concurrent_mosh_control_directories_without_session_secrets() {
        assert_eq!(mosh_session_control_name(1), "mosh-session-1");
        assert_eq!(mosh_session_control_name(42), "mosh-session-42");
    }

    #[test]
    fn prediction_relay_rewrites_only_the_authenticated_bootstrap_port() {
        let stdout = b"noise\nMOSH CONNECT 60001 4NeCCgvZFe2RnPgrcU1PQw\n";
        assert_eq!(
            rewrite_mosh_bootstrap_port(stdout, 60001, 61000).unwrap(),
            b"noise\nMOSH CONNECT 61000 4NeCCgvZFe2RnPgrcU1PQw\n"
        );
        assert!(rewrite_mosh_bootstrap_port(stdout, 60002, 61000).is_err());
    }

    #[test]
    fn accepts_only_the_product_mosh_bootstrap_server_and_port_contract() {
        let default_prefix =
            format!("{MOSH_BOOTSTRAP_COMMAND_PREFIX}{MOSH_DEFAULT_SERVER}{MOSH_SERVER_ARGUMENTS}");
        let custom_prefix =
            format!("{MOSH_BOOTSTRAP_COMMAND_PREFIX}/usr/bin/mosh-server{MOSH_SERVER_ARGUMENTS}");
        let dynamic = format!("{default_prefix}'");
        let fixed = format!("{default_prefix} -p 60042'");
        let range = format!("{custom_prefix} -p 60042:60049'");

        assert_eq!(
            parse_mosh_bootstrap_request(dynamic.as_bytes()),
            Some(MoshBootstrapRequest {
                server_path: None,
                port: None,
            })
        );
        assert_eq!(
            parse_mosh_bootstrap_request(fixed.as_bytes()),
            Some(MoshBootstrapRequest {
                server_path: None,
                port: Some(MoshPortRequest {
                    start: 60042,
                    end: 60042
                })
            })
        );
        assert_eq!(
            parse_mosh_bootstrap_request(range.as_bytes()),
            Some(MoshBootstrapRequest {
                server_path: Some("/usr/bin/mosh-server".to_string()),
                port: Some(MoshPortRequest {
                    start: 60042,
                    end: 60049
                })
            })
        );
        for invalid in [
            format!("{default_prefix} -p 0'"),
            format!("{default_prefix} -p 60050:60042'"),
            format!("{default_prefix} -p 60042 extra'"),
            format!("{default_prefix} --port 60042'"),
            format!("{MOSH_BOOTSTRAP_COMMAND_PREFIX}mosh-server;id{MOSH_SERVER_ARGUMENTS}'"),
            format!("{MOSH_BOOTSTRAP_COMMAND_PREFIX}/opt/../mosh-server{MOSH_SERVER_ARGUMENTS}'"),
            format!("{custom_prefix} extra'"),
        ] {
            assert_eq!(parse_mosh_bootstrap_request(invalid.as_bytes()), None);
        }
    }

    use russh::client;
    use tokio::io::AsyncReadExt;
    use tokio::time::timeout;

    type AsyncTestResult<T = ()> = Result<T, Box<dyn Error + Send + Sync>>;

    struct SftpTestClient;

    impl client::Handler for SftpTestClient {
        type Error = russh::Error;

        async fn check_server_key(&mut self, _: &PublicKey) -> Result<bool, Self::Error> {
            Ok(true)
        }
    }

    fn credentials() -> Arc<Credentials> {
        Arc::new(Credentials {
            password: "password-value".to_string(),
            account: "account-value".to_string(),
            token: "token-value".to_string(),
            second_token: "second-token-value".to_string(),
        })
    }

    fn assert_accept(auth: Auth) {
        assert!(matches!(auth, Auth::Accept));
    }

    fn assert_reject(auth: Auth, expected: &[MethodKind], partial_success: bool) {
        match auth {
            Auth::Reject {
                proceed_with_methods: Some(methods),
                partial_success: actual_partial,
            } => {
                assert_eq!(methods, MethodSet::from(expected));
                assert_eq!(actual_partial, partial_success);
            }
            _ => panic!("expected rejection"),
        }
    }

    #[test]
    fn summarizes_credential_mismatch_without_secret_values() {
        let substituted = credential_mismatch_summary("abcd", "abxd");
        assert_eq!(substituted.expected_bytes, 4);
        assert_eq!(substituted.received_bytes, 4);
        assert_eq!(substituted.overlap_mismatches, 1);
        assert_eq!(substituted.length_delta, 0);

        let truncated = credential_mismatch_summary("abcd", "abc");
        assert_eq!(truncated.expected_bytes, 4);
        assert_eq!(truncated.received_bytes, 3);
        assert_eq!(truncated.overlap_mismatches, 0);
        assert_eq!(truncated.length_delta, -1);
    }

    #[test]
    fn parses_only_bounded_optional_sftp_delay_and_known_fault_mode() {
        let parsed = parse_arguments(
            [
                "fixture",
                "127.0.0.1:22222",
                "/tmp/credentials",
                "900",
                "/tmp/ready",
                "125",
                "put-write-remove",
            ]
            .into_iter()
            .map(str::to_string),
        )
        .unwrap();
        assert_eq!(parsed.sftp_delay_ms, 125);
        assert_eq!(parsed.sftp_fault, SftpFault::PutWriteRemove);
        assert_eq!(parsed.direct_tcpip_behavior, DirectTcpipBehavior::Disabled);
        assert_eq!(parsed.server_output_drop_path, None);

        let jump = parse_arguments(
            [
                "fixture",
                "127.0.0.1:22222",
                "/tmp/credentials",
                "900",
                "/tmp/ready",
                "0",
                "none",
                "127.0.0.1:22223",
            ]
            .into_iter()
            .map(str::to_string),
        )
        .unwrap();
        assert_eq!(
            jump.direct_tcpip_behavior,
            DirectTcpipBehavior::Forward("127.0.0.1:22223".parse().unwrap())
        );

        let dropping = parse_arguments(
            [
                "fixture",
                "127.0.0.1:22222",
                "/tmp/credentials",
                "900",
                "/tmp/ready",
                "0",
                "none",
                "none",
                "/tmp/drop-server-output",
            ]
            .into_iter()
            .map(str::to_string),
        )
        .unwrap();
        assert_eq!(
            dropping.server_output_drop_path,
            Some(PathBuf::from("/tmp/drop-server-output"))
        );

        let stalled_jump = parse_arguments(
            [
                "fixture",
                "127.0.0.1:22222",
                "/tmp/credentials",
                "900",
                "/tmp/ready",
                "0",
                "none",
                "stall",
            ]
            .into_iter()
            .map(str::to_string),
        )
        .unwrap();
        assert_eq!(
            stalled_jump.direct_tcpip_behavior,
            DirectTcpipBehavior::Stall
        );

        let unreachable_jump = parse_arguments(
            [
                "fixture",
                "127.0.0.1:22222",
                "/tmp/credentials",
                "900",
                "/tmp/ready",
                "0",
                "none",
                "connect-failed",
            ]
            .into_iter()
            .map(str::to_string),
        )
        .unwrap();
        assert_eq!(
            unreachable_jump.direct_tcpip_behavior,
            DirectTcpipBehavior::ConnectFailed
        );

        for (value, expected) in [
            ("permission-denied", SftpFault::PermissionDenied),
            ("rename-unsupported", SftpFault::RenameUnsupported),
            ("unavailable", SftpFault::Unavailable),
        ] {
            let parsed = parse_arguments(
                [
                    "fixture",
                    "127.0.0.1:22222",
                    "/tmp/credentials",
                    "900",
                    "/tmp/ready",
                    "0",
                    value,
                ]
                .into_iter()
                .map(str::to_string),
            )
            .unwrap();
            assert_eq!(parsed.sftp_fault, expected);
        }

        let too_large = parse_arguments(
            [
                "fixture",
                "127.0.0.1:22222",
                "/tmp/credentials",
                "900",
                "/tmp/ready",
                "5001",
            ]
            .into_iter()
            .map(str::to_string),
        );
        assert!(too_large.is_err());

        let unknown_fault = parse_arguments(
            [
                "fixture",
                "127.0.0.1:22222",
                "/tmp/credentials",
                "900",
                "/tmp/ready",
                "0",
                "unknown",
            ]
            .into_iter()
            .map(str::to_string),
        );
        assert!(unknown_fault.is_err());

        let invalid_target = parse_arguments(
            [
                "fixture",
                "127.0.0.1:22222",
                "/tmp/credentials",
                "900",
                "/tmp/ready",
                "0",
                "none",
                "target.example.com:22",
            ]
            .into_iter()
            .map(str::to_string),
        );
        assert!(invalid_target.is_err());

        let mosh = parse_arguments(
            [
                "fixture",
                "0.0.0.0:22222",
                "/tmp/credentials",
                "900",
                "/tmp/ready",
                "0",
                "none",
                "none",
                "none",
                "192.0.2.10",
                "60042",
                "300",
            ]
            .into_iter()
            .map(str::to_string),
        )
        .unwrap();
        assert_eq!(
            mosh.mosh_server_address,
            Some("192.0.2.10".parse().unwrap())
        );
        assert_eq!(mosh.mosh_server_port, Some(60042));
        assert_eq!(mosh.mosh_network_timeout_seconds, 300);
    }

    #[test]
    fn parses_only_one_complete_mosh_session_record() {
        let stdout = b"MOSH CONNECT 60042 4NeCCgvZFe2RnPgrcU1PQw\n";
        let stderr = b"mosh-server (mosh 1.4.0)\n[mosh-server detached, pid = 4242]\n";
        assert_eq!(
            parse_mosh_session_metadata(stdout, stderr).unwrap(),
            (60042, 4242)
        );
        assert_eq!(
            parse_mosh_session_key(stdout).unwrap(),
            "4NeCCgvZFe2RnPgrcU1PQw"
        );
        assert!(parse_mosh_session_metadata(b"MOSH CONNECT 60042 short\n", stderr).is_err());
        assert!(parse_mosh_session_key(b"MOSH CONNECT 60042 short\n").is_err());
        assert!(parse_mosh_session_metadata(
            b"MOSH CONNECT 60042 4NeCCgvZFe2RnPgrcU1PQw\n\
MOSH CONNECT 60043 4NeCCgvZFe2RnPgrcU1PQw\n",
            stderr
        )
        .is_err());
    }

    #[test]
    fn propagates_sftp_fault_to_each_client_handler() {
        let mut fixture = FixtureServer::with_sftp_root_delay_and_fault(
            credentials(),
            Arc::new(PathBuf::from("/tmp/leantty-sftp-root")),
            Duration::ZERO,
            SftpFault::PutWriteRemove,
            DirectTcpipBehavior::Forward("127.0.0.1:22223".parse().unwrap()),
        );
        let snapshot = PathBuf::from("/tmp/leantty-connected-input-snapshot");
        fixture.set_input_snapshot_path(snapshot.clone());

        let client = fixture.new_client(None);

        assert_eq!(client.sftp_fault, SftpFault::PutWriteRemove);
        assert_eq!(
            client.direct_tcpip_behavior,
            DirectTcpipBehavior::Forward("127.0.0.1:22223".parse().unwrap())
        );
        assert_eq!(
            client
                .input_snapshot_path
                .as_ref()
                .map(|path| path.as_ref().as_path()),
            Some(snapshot.as_path())
        );
    }

    #[test]
    fn accepts_single_password_and_public_key_scenarios() {
        let mut fixture = FixtureServer::new(credentials());
        assert_accept(fixture.password(USER_PASSWORD, "password-value"));

        let mut fixture = FixtureServer::new(credentials());
        assert_accept(fixture.public_key(USER_PUBLICKEY));

        let mut fixture = FixtureServer::new(credentials());
        assert_accept(fixture.password(USER_NAVIGATION, "password-value"));
        assert_eq!(fixture.session_scenario, Some(Scenario::Navigation));

        let mut fixture = FixtureServer::new(credentials());
        assert_accept(fixture.password(USER_NAVIGATION_TWO, "password-value"));
        let mut fixture = FixtureServer::new(credentials());
        assert_accept(fixture.password(USER_NAVIGATION_THREE, "password-value"));

        let mut fixture = FixtureServer::new(credentials());
        assert_accept(fixture.password(USER_CHANNEL_DENIED, "password-value"));
        assert_eq!(fixture.session_scenario, Some(Scenario::ChannelDenied));

        let mut fixture = FixtureServer::new(credentials());
        assert_reject(
            fixture.public_key(USER_MOSH),
            &[MethodKind::Password],
            false,
        );
        assert_eq!(fixture.session_scenario, None);
        let mut fixture = FixtureServer::new(credentials());
        assert_accept(fixture.password(USER_MOSH, "password-value"));
        assert_eq!(fixture.session_scenario, Some(Scenario::Mosh));
    }

    #[test]
    fn formats_navigation_input_as_lowercase_hex() {
        assert_eq!(format_input_hex(b"\x1b[1;7D"), "1b 5b 31 3b 37 44");
        assert_eq!(format_input_hex(b"\t"), "09");
    }

    #[test]
    fn parses_only_bounded_perf_stream_commands() {
        assert_eq!(
            parse_perf_command(b"ltty-perf-prepare baseline_01 12000 80"),
            Some(PerfCommand::Prepare(PerfStreamRequest {
                case_id: "baseline_01".to_string(),
                lines: 12_000,
                line_width: 80,
            }))
        );
        assert_eq!(
            parse_perf_command(b"ltty-perf-run baseline_01"),
            Some(PerfCommand::Run("baseline_01".to_string()))
        );
        assert_eq!(
            parse_perf_command(b"ltty-perf-prepare baseline:01 100 80"),
            None
        );
        assert_eq!(
            parse_perf_command(b"ltty-perf-prepare baseline 12001 80"),
            None
        );
        assert_eq!(
            parse_perf_command(b"ltty-perf-prepare baseline 100 47"),
            None
        );
        assert_eq!(parse_perf_command(b"ltty-perf-run baseline extra"), None);
        assert_eq!(parse_perf_command(b"help"), None);
    }

    #[test]
    fn builds_exact_width_perf_stream_payload() {
        let request = PerfStreamRequest {
            case_id: "sample01".to_string(),
            lines: 3,
            line_width: 64,
        };
        let payload = build_perf_stream_payload(&request);
        assert_eq!(payload.len(), (64 + 2) * 3);
        assert_eq!(
            payload.iter().filter(|byte| **byte == b'X').count(),
            perf_stream_expected_bytes(&request)
        );
        for (index, line) in payload.chunks_exact(66).enumerate() {
            assert_eq!(&line[64..], b"\r\n");
            assert!(line.starts_with(format!("LTTY_PERF_sample01_{index:05} ").as_bytes()));
        }
    }

    #[test]
    fn parses_and_builds_bounded_paste_payloads() {
        let key = PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap();
        let public_key = key.public_key();
        let public_text = public_key.to_openssh().unwrap();
        let marker = "__LTTY_KEYPUSH_1735689600000";
        let key_install = format!(
            "mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && (grep -qxF -- '{public_text}' ~/.ssh/authorized_keys || printf '%s\\n' '{public_text}' >> ~/.ssh/authorized_keys); command_status=$?; printf '\\n%s:%s\\n' '{marker}' \"$command_status\""
        );
        assert_eq!(
            parse_fixture_command(key_install.as_bytes()),
            Some(FixtureCommand::KeyInstall(KeyInstallRequest {
                fingerprint: public_key.fingerprint(HashAlg::Sha256).to_string(),
                marker: marker.to_string(),
            }))
        );
        assert_eq!(
            parse_key_install_command(key_install.replace(marker, "__LTTY_KEYPUSH_bad").as_bytes()),
            None
        );

        let request = PasteRequest {
            case_id: "paste01".to_string(),
            bytes: PASTE_MAX_BYTES,
        };
        assert_eq!(
            parse_fixture_command(b"ltty-paste-prepare paste01 1048576"),
            Some(FixtureCommand::Paste(request.clone()))
        );
        assert_eq!(
            parse_fixture_command(b"ltty-paste-prepare paste01 1048577"),
            None
        );
        assert_eq!(
            parse_fixture_command(b"ltty-paste-prepare paste:01 10"),
            None
        );
        let payload = build_paste_payload(&request);
        assert_eq!(payload.len(), PASTE_MAX_BYTES);
        assert!(payload.starts_with(b"LTTY_PASTE_paste01|"));
        assert_eq!(
            parse_fixture_command(b"ltty-input-check input01"),
            Some(FixtureCommand::InputCheck("input01".to_string()))
        );
        assert_eq!(parse_fixture_command(b"ltty-input-check bad:id"), None);
        assert_eq!(
            parse_fixture_command(b"ltty-terminal-dirty dirty01"),
            Some(FixtureCommand::TerminalDirty("dirty01".to_string()))
        );
        assert_eq!(parse_fixture_command(b"ltty-terminal-dirty bad:id"), None);
        assert_eq!(
            parse_fixture_command(b"ltty-exit"),
            Some(FixtureCommand::Exit)
        );
        assert_eq!(
            parse_fixture_command_line(b"[Oltty-input-check input01"),
            Some(FixtureCommand::InputCheck("input01".to_string()))
        );
        assert_eq!(
            parse_fixture_command(b"ltty-bell bell01 800"),
            Some(FixtureCommand::Bell(BellRequest {
                case_id: "bell01".to_string(),
                delay_ms: 800,
            }))
        );
        assert_eq!(parse_fixture_command(b"ltty-bell bell01 99"), None);
        assert_eq!(parse_fixture_command(b"ltty-bell bell01 5001"), None);
        assert_eq!(parse_fixture_command(b"ltty-bell bad:id 800"), None);
        assert_eq!(parse_fixture_command(b"ltty-bell bell01 800 extra"), None);
    }

    #[test]
    fn encodes_standard_base64_with_padding() {
        assert_eq!(encode_base64(b""), "");
        assert_eq!(encode_base64(b"f"), "Zg==");
        assert_eq!(encode_base64(b"fo"), "Zm8=");
        assert_eq!(encode_base64(b"foo"), "Zm9v");
        assert_eq!(encode_base64(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn exposes_and_clears_connected_input_before_submission() {
        let root = env::temp_dir().join(format!("leantty-connected-input-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let snapshot = root.join("connected-input-snapshot");
        let mut fixture = FixtureServer::new(credentials());
        fixture.set_input_snapshot_path(snapshot.clone());

        assert_eq!(
            fixture.take_fixture_command(b"ltty-bell inative01 5000"),
            None
        );
        assert_eq!(fs::read(&snapshot).unwrap(), b"ltty-bell inative01 5000");
        fixture.clear_fixture_input().unwrap();
        assert_eq!(fs::read(&snapshot).unwrap(), b"");

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn enforces_password_then_keyboard_interactive_with_mixed_echo() {
        let mut fixture = FixtureServer::new(credentials());
        assert_reject(
            fixture.keyboard_interactive(USER_PASSWORD_KBDINT, None),
            &[MethodKind::Password],
            false,
        );
        assert_reject(
            fixture.password(USER_PASSWORD_KBDINT, "password-value"),
            &[MethodKind::KeyboardInteractive],
            true,
        );
        match fixture.keyboard_interactive(USER_PASSWORD_KBDINT, None) {
            Auth::Partial { prompts, .. } => {
                assert_eq!(prompts.len(), 2);
                assert!(prompts[0].1);
                assert!(!prompts[1].1);
            }
            _ => panic!("expected interactive prompts"),
        }
        assert_accept(fixture.keyboard_interactive(
            USER_PASSWORD_KBDINT,
            Some(vec![b"account-value".to_vec(), b"token-value".to_vec()]),
        ));
    }

    #[test]
    fn enforces_public_key_then_password() {
        let mut fixture = FixtureServer::new(credentials());
        assert_reject(
            fixture.password(USER_PUBLICKEY_PASSWORD, "password-value"),
            &[MethodKind::PublicKey],
            false,
        );
        assert_reject(
            fixture.public_key(USER_PUBLICKEY_PASSWORD),
            &[MethodKind::Password],
            true,
        );
        assert_accept(fixture.password(USER_PUBLICKEY_PASSWORD, "password-value"));
    }

    #[test]
    fn enforces_public_key_then_keyboard_interactive() {
        let mut fixture = FixtureServer::new(credentials());
        assert_reject(
            fixture.public_key(USER_PUBLICKEY_KBDINT),
            &[MethodKind::KeyboardInteractive],
            true,
        );
        assert_accept(fixture.keyboard_interactive(
            USER_PUBLICKEY_KBDINT,
            Some(vec![b"account-value".to_vec(), b"token-value".to_vec()]),
        ));
    }

    #[test]
    fn rejects_wrong_answer_and_restarts_multi_round_exchange() {
        let mut fixture = FixtureServer::new(credentials());
        assert!(matches!(
            fixture.keyboard_interactive(USER_KBDINT_MULTIROUND, None),
            Auth::Partial { .. }
        ));
        assert!(matches!(
            fixture.keyboard_interactive(
                USER_KBDINT_MULTIROUND,
                Some(vec![b"account-value".to_vec()])
            ),
            Auth::Partial { .. }
        ));
        assert_reject(
            fixture.keyboard_interactive(USER_KBDINT_MULTIROUND, Some(vec![b"wrong".to_vec()])),
            &[MethodKind::KeyboardInteractive],
            false,
        );
        assert_eq!(fixture.interactive_round, InteractiveRound::NotStarted);
    }

    #[test]
    fn accepts_two_round_keyboard_interactive_exchange() {
        let mut fixture = FixtureServer::new(credentials());
        assert!(matches!(
            fixture.keyboard_interactive(USER_KBDINT_MULTIROUND, None),
            Auth::Partial { .. }
        ));
        assert!(matches!(
            fixture.keyboard_interactive(
                USER_KBDINT_MULTIROUND,
                Some(vec![b"account-value".to_vec()])
            ),
            Auth::Partial { .. }
        ));
        assert_accept(fixture.keyboard_interactive(
            USER_KBDINT_MULTIROUND,
            Some(vec![b"second-token-value".to_vec()]),
        ));
    }

    #[test]
    fn accepts_zero_prompt_and_exposes_only_hostbased_for_unsupported_user() {
        let mut fixture = FixtureServer::new(credentials());
        match fixture.keyboard_interactive(USER_KBDINT_ZERO, None) {
            Auth::Partial { prompts, .. } => assert!(prompts.is_empty()),
            _ => panic!("expected zero-prompt interactive request"),
        }
        assert_accept(fixture.keyboard_interactive(USER_KBDINT_ZERO, Some(Vec::new())));

        let fixture = FixtureServer::new(credentials());
        assert_reject(
            fixture.none(USER_UNSUPPORTED),
            &[MethodKind::HostBased],
            false,
        );
    }

    #[test]
    fn credential_file_rejects_unknown_duplicate_and_missing_values() {
        let temp = env::temp_dir().join(format!("leantty-fixture-{}", std::process::id()));
        fs::create_dir_all(&temp).unwrap();
        let path = temp.join("credentials");

        fs::write(&path, "password=x\naccount=y\ntoken=z\nunknown=q\n").unwrap();
        assert!(Credentials::load(&path)
            .err()
            .unwrap()
            .contains("unknown key"));
        fs::write(
            &path,
            "password=x\npassword=y\naccount=a\ntoken=z\nsecond_token=q\n",
        )
        .unwrap();
        assert!(Credentials::load(&path)
            .err()
            .unwrap()
            .contains("duplicated"));
        fs::write(&path, "password=x\naccount=y\ntoken=z\n").unwrap();
        assert!(Credentials::load(&path).err().unwrap().contains("missing"));

        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn sftp_paths_allow_bounded_subdirectories_and_reject_traversal() {
        let root = Arc::new(PathBuf::from("/tmp/leantty-sftp-root"));
        let fixture = FixtureSftp::new(root.clone());
        assert_eq!(
            fixture.path("/inbox/source.bin").unwrap(),
            root.join("inbox").join("source.bin")
        );
        assert!(fixture.path("/inbox/../source.bin").is_err());
        assert!(fixture.path("/inbox//source.bin").is_err());
        assert!(fixture.path("/inbox\\source.bin").is_err());
    }

    #[tokio::test]
    async fn transport_proxy_drops_only_server_output_after_control_file_appears() -> AsyncTestResult
    {
        let temp = env::temp_dir().join(format!(
            "leantty-transport-proxy-{}-{:016x}",
            std::process::id(),
            rand::random::<u64>()
        ));
        fs::create_dir_all(&temp)?;
        let drop_path = temp.join("drop-server-output");

        let backend_listener = TcpListener::bind("127.0.0.1:0").await?;
        let backend_address = backend_listener.local_addr()?;
        let backend = tokio::spawn(async move {
            let (mut socket, _) = backend_listener.accept().await?;
            let mut buffer = [0_u8; 64];
            loop {
                let read = socket.read(&mut buffer).await?;
                if read == 0 {
                    return Ok::<(), io::Error>(());
                }
                socket.write_all(&buffer[..read]).await?;
            }
        });

        let proxy_listener = TcpListener::bind("127.0.0.1:0").await?;
        let proxy_address = proxy_listener.local_addr()?;
        let proxy =
            spawn_server_output_drop_proxy(proxy_listener, backend_address, drop_path.clone());
        let mut client = TcpStream::connect(proxy_address).await?;

        client.write_all(b"before").await?;
        let mut before = [0_u8; 6];
        client.read_exact(&mut before).await?;
        assert_eq!(&before, b"before");

        fs::write(&drop_path, b"drop")?;
        client.write_all(b"after").await?;
        let mut after = [0_u8; 5];
        assert!(
            timeout(Duration::from_millis(150), client.read_exact(&mut after))
                .await
                .is_err()
        );

        drop(client);
        timeout(Duration::from_secs(1), backend).await???;
        proxy.abort();
        fs::remove_dir_all(temp)?;
        Ok(())
    }

    #[tokio::test]
    async fn russh_keepalive_timeout_occurs_after_max_plus_one_intervals() -> AsyncTestResult {
        let temp = env::temp_dir().join(format!(
            "leantty-keepalive-proxy-{}-{:016x}",
            std::process::id(),
            rand::random::<u64>()
        ));
        fs::create_dir_all(&temp)?;
        let drop_path = temp.join("drop-server-output");

        let server_socket = TcpListener::bind("127.0.0.1:0").await?;
        let server_address = server_socket.local_addr()?;
        let server_config = Arc::new(russh::server::Config {
            keys: vec![PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519)?],
            ..Default::default()
        });
        let mut fixture = FixtureServer::new(credentials());
        let running = fixture.run_on_socket(server_config, &server_socket);
        let server_handle = running.handle();

        let proxy_socket = TcpListener::bind("127.0.0.1:0").await?;
        let proxy_address = proxy_socket.local_addr()?;
        let proxy = spawn_server_output_drop_proxy(proxy_socket, server_address, drop_path.clone());
        let client = async move {
            let client_config = Arc::new(client::Config {
                keepalive_interval: Some(Duration::from_millis(100)),
                keepalive_max: 3,
                ..Default::default()
            });
            let mut ssh = client::connect(client_config, proxy_address, SftpTestClient).await?;
            if !ssh
                .authenticate_password(USER_PASSWORD, "password-value")
                .await?
                .success()
            {
                return Err(io::Error::other("keepalive fixture password was rejected").into());
            }
            let channel = ssh.channel_open_session().await?;
            channel.request_shell(true).await?;
            fs::write(&drop_path, b"drop")?;

            let started = tokio::time::Instant::now();
            let result = timeout(Duration::from_secs(2), &mut ssh).await?;
            let elapsed = started.elapsed();
            if !matches!(result, Err(russh::Error::KeepaliveTimeout)) {
                return Err(io::Error::other(format!(
                    "expected russh keepalive timeout, got {result:?}"
                ))
                .into());
            }
            if !(Duration::from_millis(350)..Duration::from_millis(900)).contains(&elapsed) {
                return Err(io::Error::other(format!(
                    "keepalive timeout elapsed outside max-plus-one interval window: {elapsed:?}"
                ))
                .into());
            }
            Ok::<(), Box<dyn Error + Send + Sync>>(())
        };

        let managed_client = async move {
            let result = client.await;
            server_handle.shutdown("test complete".to_string());
            result
        };
        let (server_result, client_result) = tokio::join!(running, managed_client);
        proxy.abort();
        fs::remove_dir_all(temp)?;
        server_result
            .map_err(|error| -> Box<dyn Error + Send + Sync> { Box::new(error) })
            .and(client_result)
    }

    #[tokio::test]
    async fn silent_shell_stays_connected_when_ssh_keepalive_replies_arrive() -> AsyncTestResult {
        let server_socket = TcpListener::bind("127.0.0.1:0").await?;
        let server_address = server_socket.local_addr()?;
        let server_config = Arc::new(russh::server::Config {
            keys: vec![PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519)?],
            ..Default::default()
        });
        let mut fixture = FixtureServer::new(credentials());
        let running = fixture.run_on_socket(server_config, &server_socket);
        let server_handle = running.handle();

        let client = async move {
            let client_config = Arc::new(client::Config {
                keepalive_interval: Some(Duration::from_millis(100)),
                keepalive_max: 3,
                ..Default::default()
            });
            let mut ssh = client::connect(client_config, server_address, SftpTestClient).await?;
            if !ssh
                .authenticate_password(USER_PASSWORD, "password-value")
                .await?
                .success()
            {
                return Err(io::Error::other("silent-shell fixture password was rejected").into());
            }
            let channel = ssh.channel_open_session().await?;
            channel.request_shell(true).await?;

            if timeout(Duration::from_millis(650), &mut ssh).await.is_ok() {
                return Err(io::Error::other(
                    "silent shell closed despite receiving SSH keepalive replies",
                )
                .into());
            }
            ssh.disconnect(russh::Disconnect::ByApplication, "test complete", "")
                .await?;
            Ok::<(), Box<dyn Error + Send + Sync>>(())
        };

        let managed_client = async move {
            let result = timeout(Duration::from_secs(2), client).await;
            server_handle.shutdown("test complete".to_string());
            match result {
                Ok(result) => result,
                Err(error) => Err(error.into()),
            }
        };
        let (server_result, client_result) = tokio::join!(running, managed_client);
        server_result
            .map_err(|error| -> Box<dyn Error + Send + Sync> { Box::new(error) })
            .and(client_result)
    }

    #[tokio::test]
    async fn shell_channel_consumes_more_than_the_default_message_buffer() -> AsyncTestResult {
        let socket = TcpListener::bind("127.0.0.1:0").await?;
        let address = socket.local_addr()?;
        let config = Arc::new(russh::server::Config {
            keys: vec![PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519)?],
            ..Default::default()
        });
        let mut fixture = FixtureServer::new(credentials());
        let running = fixture.run_on_socket(config, &socket);
        let server_handle = running.handle();

        let client = async move {
            let mut ssh =
                client::connect(Arc::new(client::Config::default()), address, SftpTestClient)
                    .await?;
            if !ssh
                .authenticate_password(USER_PASSWORD, "password-value")
                .await?
                .success()
            {
                return Err(io::Error::other("shell fixture password was rejected").into());
            }
            let channel = ssh.channel_open_session().await?;
            channel.request_shell(true).await?;
            let (mut read_half, write_half) = channel.split();
            let reader = tokio::spawn(async move {
                let mut output = Vec::new();
                while output.len() < 4096 {
                    match read_half.wait().await {
                        Some(russh::ChannelMsg::Data { data }) => {
                            output.extend_from_slice(&data);
                            if output
                                .windows(b"LTTY_INPUT_OK:drain".len())
                                .any(|window| window == b"LTTY_INPUT_OK:drain")
                            {
                                return true;
                            }
                        }
                        Some(russh::ChannelMsg::Close) | None => return false,
                        Some(_) => {}
                    }
                }
                false
            });

            for _ in 0..120 {
                write_half.data_bytes(vec![b'x']).await?;
            }
            write_half.data_bytes(vec![b'\r']).await?;
            for byte in b"ltty-input-check drain\r" {
                write_half.data_bytes(vec![*byte]).await?;
            }
            if !timeout(Duration::from_secs(5), reader).await?? {
                return Err(io::Error::other(
                    "shell fixture did not process input after 100 messages",
                )
                .into());
            }
            ssh.disconnect(russh::Disconnect::ByApplication, "test complete", "")
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
        server_result
            .map_err(|error| -> Box<dyn Error + Send + Sync> { Box::new(error) })
            .and(client_result)
    }

    #[tokio::test]
    async fn streams_sftp_file_across_multiple_read_requests() -> AsyncTestResult {
        let temp = env::temp_dir().join(format!(
            "leantty-sftp-fixture-{}-{:016x}",
            std::process::id(),
            rand::random::<u64>()
        ));
        let sftp_root = temp.join("sftp-root");
        fs::create_dir_all(&sftp_root)?;
        let expected: Vec<u8> = (0..131_089).map(|index| (index % 251) as u8).collect();
        fs::write(sftp_root.join("source.bin"), &expected)?;

        let socket = TcpListener::bind("127.0.0.1:0").await?;
        let address = socket.local_addr()?;
        let config = Arc::new(russh::server::Config {
            keys: vec![PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519)?],
            ..Default::default()
        });
        let mut fixture = FixtureServer::with_sftp_root(credentials(), Arc::new(sftp_root.clone()));
        let running = fixture.run_on_socket(config, &socket);
        let server_handle = running.handle();

        let client = async move {
            let mut ssh =
                client::connect(Arc::new(client::Config::default()), address, SftpTestClient)
                    .await?;
            if !ssh
                .authenticate_password(USER_PASSWORD, "password-value")
                .await?
                .success()
            {
                return Err(io::Error::other("SFTP fixture password was rejected").into());
            }
            let channel = ssh.channel_open_session().await?;
            channel.request_subsystem(true, "sftp").await?;
            let sftp = russh_sftp::client::SftpSession::new(channel.into_stream()).await?;
            let mut file = sftp.open("/source.bin").await?;
            let mut actual = Vec::new();
            file.read_to_end(&mut actual).await?;
            file.close().await?;
            sftp.close().await?;
            ssh.disconnect(russh::Disconnect::ByApplication, "test complete", "")
                .await?;
            if actual != expected {
                return Err(io::Error::other("SFTP fixture changed streamed bytes").into());
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
        let result = server_result
            .map_err(|error| -> Box<dyn Error + Send + Sync> { Box::new(error) })
            .and(client_result);
        fs::remove_dir_all(temp)?;
        result
    }
}
