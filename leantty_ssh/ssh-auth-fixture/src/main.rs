use std::borrow::Cow;
use std::collections::HashMap;
use std::env;
use std::fs;
use std::io;
use std::net::SocketAddr;
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use russh::keys::{Algorithm, PrivateKey, PublicKey};
use russh::server::{Auth, Handler, Msg, Response, Server, Session};
use russh::{Channel, ChannelId, ChannelOpenFailure, MethodKind, MethodSet};
use russh_sftp::protocol::{Attrs, Data, FileAttributes, Handle, OpenFlags, Status, StatusCode};
use tokio::net::TcpListener;
use tokio::sync::Mutex;
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
const USER_NAVIGATION: &str = "navigation";
const USER_NAVIGATION_TWO: &str = "navigation-two";
const USER_NAVIGATION_THREE: &str = "navigation-three";
const PERF_PREPARE_COMMAND: &str = "ltty-perf-prepare";
const PERF_RUN_COMMAND: &str = "ltty-perf-run";
const PERF_MAX_CASE_ID_LENGTH: usize = 24;
const PERF_MAX_LINES: usize = 12_000;
const PERF_MIN_LINE_WIDTH: usize = 48;
const PERF_MAX_LINE_WIDTH: usize = 160;
const PERF_OUTPUT_CHUNK_BYTES: usize = 16 * 1024;
const PASTE_PREPARE_COMMAND: &str = "ltty-paste-prepare";
const INPUT_CHECK_COMMAND: &str = "ltty-input-check";
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
    Navigation,
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
            USER_NAVIGATION | USER_NAVIGATION_TWO | USER_NAVIGATION_THREE => Some(Self::Navigation),
            _ => None,
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
    pending_perf_request: Option<PerfStreamRequest>,
    pending_paste: Option<PasteTransfer>,
    channels: Arc<Mutex<HashMap<ChannelId, Option<Channel<Msg>>>>>,
    sftp_root: Arc<PathBuf>,
    sftp_delay: Duration,
    sftp_fault: SftpFault,
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
        )
    }

    fn with_sftp_root_delay_and_fault(
        credentials: Arc<Credentials>,
        sftp_root: Arc<PathBuf>,
        sftp_delay: Duration,
        sftp_fault: SftpFault,
    ) -> Self {
        Self {
            credentials,
            public_key_complete: false,
            password_complete: false,
            interactive_round: InteractiveRound::NotStarted,
            session_scenario: None,
            shell_input: Vec::new(),
            pending_perf_request: None,
            pending_paste: None,
            channels: Arc::new(Mutex::new(HashMap::new())),
            sftp_root,
            sftp_delay,
            sftp_fault,
        }
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
                if self.shell_input.len() < 256 {
                    self.shell_input.push(*byte);
                } else {
                    self.shell_input.clear();
                }
            }
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
            eprintln!("auth method=password scenario={scenario:?} result=reject");
            return Self::reject(&[MethodKind::Password], self.public_key_complete);
        }

        eprintln!("auth method=password scenario={scenario:?} result=matched");
        match scenario {
            Scenario::Password | Scenario::ChannelDenied | Scenario::Navigation => {
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
        eprintln!("auth method=publickey scenario={scenario:?} result=verified");
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
            | Self::Navigation => {
                vec![MethodKind::Password]
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

    fn new_client(&mut self, _: Option<SocketAddr>) -> Self {
        Self::with_sftp_root_delay_and_fault(
            Arc::clone(&self.credentials),
            Arc::clone(&self.sftp_root),
            self.sftp_delay,
            self.sftp_fault,
        )
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
        _public_key: &PublicKey,
    ) -> Result<Auth, Self::Error> {
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
        session.data(channel, b"LEANTTY_AUTH_FIXTURE_OK\r\nfixture> ".as_slice())?;
        Ok(())
    }

    async fn exec_request(
        &mut self,
        channel: ChannelId,
        _data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        eprintln!("channel callback=exec scenario={:?}", self.session_scenario);
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
            let captured = format!(
                "\r\nLEANTTY_INPUT_HEX:{}\r\nfixture> ",
                format_input_hex(data)
            );
            session.data(channel, captured.into_bytes())?;
            return Ok(());
        }
        session.data(channel, data.to_vec())?;
        match self.take_fixture_command(data) {
            Some(FixtureCommand::Perf(PerfCommand::Prepare(request))) => {
                let expected_bytes = perf_stream_expected_bytes(&request);
                eprintln!(
                    "perf case={} bytes={} state=prepared",
                    request.case_id, expected_bytes
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

#[derive(Debug, Eq, PartialEq)]
enum FixtureCommand {
    Perf(PerfCommand),
    Paste(PasteRequest),
    InputCheck(String),
    Exit,
    Bell(BellRequest),
}

fn parse_fixture_command(input: &[u8]) -> Option<FixtureCommand> {
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
}

fn parse_arguments(mut arguments: impl Iterator<Item = String>) -> Result<Arguments, String> {
    let executable = arguments
        .next()
        .unwrap_or_else(|| "ssh-auth-fixture".to_string());
    let usage = || {
        format!(
            "usage: {executable} <listen-address> <credentials-file> [run-seconds] [ready-file] [sftp-delay-ms] [sftp-fault]"
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
    })
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let arguments = parse_arguments(env::args()).map_err(|error| error.to_string())?;
    let sftp_root = arguments
        .credentials_path
        .parent()
        .ok_or("fixture credentials path has no parent")?
        .join("sftp-root");
    fs::create_dir_all(&sftp_root)?;
    let credentials = Arc::new(
        Credentials::load(&arguments.credentials_path).map_err(|error| error.to_string())?,
    );
    let socket = TcpListener::bind(&arguments.listen).await?;
    let address = socket.local_addr()?;
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
    );
    let running = fixture.run_on_socket(config, &socket);
    let handle = running.handle();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(arguments.run_seconds)).await;
        handle.shutdown("fixture lifetime expired".into());
    });
    if let Some(ready_path) = arguments.ready_path {
        fs::write(
            ready_path,
            format!("address={address}\npid={}\n", std::process::id()),
        )?;
    }
    println!(
        "LEANTTY_SSH_AUTH_FIXTURE_READY address={address} pid={}",
        std::process::id()
    );
    println!(
        "users={USER_PASSWORD},{USER_PUBLICKEY},{USER_PASSWORD_KBDINT},{USER_PUBLICKEY_PASSWORD},{USER_PUBLICKEY_KBDINT},{USER_KBDINT_MULTIROUND},{USER_KBDINT_ZERO},{USER_UNSUPPORTED},{USER_CHANNEL_DENIED},{USER_NAVIGATION},{USER_NAVIGATION_TWO},{USER_NAVIGATION_THREE}"
    );
    running.await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::error::Error;

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
    }

    #[test]
    fn propagates_sftp_fault_to_each_client_handler() {
        let mut fixture = FixtureServer::with_sftp_root_delay_and_fault(
            credentials(),
            Arc::new(PathBuf::from("/tmp/leantty-sftp-root")),
            Duration::ZERO,
            SftpFault::PutWriteRemove,
        );

        let client = fixture.new_client(None);

        assert_eq!(client.sftp_fault, SftpFault::PutWriteRemove);
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
