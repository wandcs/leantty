use std::collections::HashMap;
use std::future::Future;
use std::net::Ipv4Addr;
use std::os::fd::BorrowedFd;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::{spawn, Function, Uint8Array};
use napi_ohos::threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode};
use napi_ohos::{Error, Result, Status};
use zeroize::{Zeroize, Zeroizing};

mod transfer;

use leantty_ssh_core::authentication::{
    sanitize_server_text, AuthAction, AuthChallenge, AuthFailure, AuthMethodKind, AuthPrompt,
    AuthStateMachine,
};
use leantty_ssh_core::keygen::{self};
use leantty_ssh_core::known_hosts::{find_known_host_entries, remove_known_host_entries};
use leantty_ssh_core::AuthMethod;
use mosh_client::{
    Bootstrap as MoshBootstrap, PredictionMode as MoshPredictionMode,
    Session as MoshProtocolSession, SessionExit as MoshSessionExit,
    SessionInterruption as MoshSessionInterruption, SessionReachability as MoshSessionReachability,
    SessionState as MoshProtocolState,
};

static NEXT_SESSION_ID: AtomicU32 = AtomicU32::new(1);

type WriteSender = tokio::sync::mpsc::Sender<Vec<u8>>;
type ResizeSender = tokio::sync::mpsc::Sender<(u32, u32)>;
type AuthSender = tokio::sync::mpsc::Sender<LayeredAuthMethod>;
type DisconnectSender = tokio::sync::mpsc::Sender<()>;
type OutputPauseSender = tokio::sync::mpsc::Sender<bool>;
type JsControlCallback =
    Arc<ThreadsafeFunction<ControlEvent, (), ControlEvent, Status, false, false, 64>>;
type JsTransportCallback =
    Arc<ThreadsafeFunction<TransportEvent, (), TransportEvent, Status, false, false, 64>>;
type JsAuthCallback = Arc<ThreadsafeFunction<AuthEvent, (), AuthEvent, Status, false, false, 64>>;
type JsFileTransferCallback =
    Arc<ThreadsafeFunction<FileTransferEvent, (), FileTransferEvent, Status, false, false, 64>>;

#[napi(object)]
pub struct TransportEvent {
    pub kind: String,
    pub data: Uint8Array,
    pub result: String,
    pub exit_code: i32,
    pub code: String,
    pub detail: String,
    pub layer: String,
    pub stage: String,
    pub status: String,
    pub reason: String,
}

#[napi(object)]
pub struct ControlEvent {
    pub kind: String,
    pub session_id: String,
    pub generation: u32,
    pub layer: String,
    pub stage: String,
    pub code: String,
    pub detail: String,
    pub fingerprint: String,
    pub known_host_line: String,
    pub algorithm: String,
    pub old_fingerprint: String,
    pub new_fingerprint: String,
    pub host: String,
    pub port: u32,
    pub metrics: String,
}

struct ChangedHostKeyControl {
    algorithm: String,
    old_fingerprint: String,
    new_fingerprint: String,
    host: String,
    port: u16,
}

impl ControlEvent {
    fn base(kind: &str, session_id: u32, generation: u32) -> Self {
        Self {
            kind: kind.to_string(),
            session_id: session_id.to_string(),
            generation,
            layer: String::new(),
            stage: String::new(),
            code: String::new(),
            detail: String::new(),
            fingerprint: String::new(),
            known_host_line: String::new(),
            algorithm: String::new(),
            old_fingerprint: String::new(),
            new_fingerprint: String::new(),
            host: String::new(),
            port: 0,
            metrics: String::new(),
        }
    }

    fn connected(session_id: u32, generation: u32) -> Self {
        Self::base("connected", session_id, generation)
    }

    fn error(
        session_id: u32,
        generation: u32,
        layer: ConnectionLayer,
        stage: &str,
        code: &str,
        detail: &str,
    ) -> Self {
        let mut event = Self::base("error", session_id, generation);
        event.layer = layer.as_str().to_string();
        event.stage = stage.to_string();
        event.code = code.to_string();
        event.detail = detail.to_string();
        event
    }

    fn warning(
        session_id: u32,
        generation: u32,
        layer: ConnectionLayer,
        stage: &str,
        code: &str,
        detail: &str,
    ) -> Self {
        let mut event = Self::error(session_id, generation, layer, stage, code, detail);
        event.kind = "warning".to_string();
        event
    }

    fn host_key_prompt(
        session_id: u32,
        generation: u32,
        layer: ConnectionLayer,
        fingerprint: String,
        known_host_line: String,
    ) -> Self {
        let mut event = Self::base("host_key_prompt", session_id, generation);
        event.layer = layer.as_str().to_string();
        event.stage = "host_key".to_string();
        event.fingerprint = fingerprint;
        event.known_host_line = known_host_line;
        event
    }

    fn host_key_changed(
        session_id: u32,
        generation: u32,
        layer: ConnectionLayer,
        changed: ChangedHostKeyControl,
    ) -> Self {
        let mut event = Self::base("host_key_changed", session_id, generation);
        event.layer = layer.as_str().to_string();
        event.stage = "host_key".to_string();
        event.algorithm = changed.algorithm;
        event.old_fingerprint = changed.old_fingerprint;
        event.new_fingerprint = changed.new_fingerprint;
        event.host = changed.host;
        event.port = changed.port.into();
        event
    }

    fn output_metrics(session_id: u32, generation: u32, metrics: String) -> Self {
        let mut event = Self::base("output_metrics", session_id, generation);
        event.layer = ConnectionLayer::Target.as_str().to_string();
        event.stage = "output".to_string();
        event.metrics = metrics;
        event
    }
}

impl TransportEvent {
    fn data(data: Vec<u8>) -> Self {
        Self {
            kind: "data".to_string(),
            data: data.into(),
            result: String::new(),
            exit_code: -1,
            code: String::new(),
            detail: String::new(),
            layer: String::new(),
            stage: String::new(),
            status: String::new(),
            reason: String::new(),
        }
    }

    fn close(exit_code: i32, layer: String, code: String, detail: String) -> Self {
        Self {
            kind: "close".to_string(),
            data: Vec::new().into(),
            result: String::new(),
            exit_code,
            code,
            detail,
            layer,
            stage: String::new(),
            status: String::new(),
            reason: String::new(),
        }
    }

    fn diagnostic(layer: ConnectionLayer, stage: &str, status: &str) -> Self {
        Self {
            kind: "diagnostic".to_string(),
            data: Vec::new().into(),
            result: String::new(),
            exit_code: -1,
            code: String::new(),
            detail: String::new(),
            layer: layer.as_str().to_string(),
            stage: stage.to_string(),
            status: status.to_string(),
            reason: String::new(),
        }
    }

    fn diagnostic_failure(layer: ConnectionLayer, stage: &str, reason: &str) -> Self {
        let mut event = Self::diagnostic(layer, stage, "failed");
        event.reason = reason.to_string();
        event
    }

    fn mosh_reachability(status: &str, reason: &str) -> Self {
        let mut event = Self::diagnostic(ConnectionLayer::Target, "mosh_udp", status);
        event.kind = "reachability".to_string();
        event.reason = reason.to_string();
        event
    }
}

#[napi(object)]
pub struct AuthPromptEvent {
    pub text: String,
    pub echo: bool,
}

#[napi(object)]
pub struct AuthEvent {
    pub kind: String,
    pub layer: String,
    pub session_id: String,
    pub generation: u32,
    pub round_id: u32,
    pub text: String,
    pub name: String,
    pub instructions: String,
    pub prompts: Vec<AuthPromptEvent>,
}

#[napi(object)]
pub struct FileTransferEvent {
    pub kind: String,
    pub transfer_id: String,
    pub pane_id: String,
    pub generation: u32,
    pub transferred_bytes: String,
    pub total_bytes: String,
    pub code: String,
    pub detail: String,
}

impl FileTransferEvent {
    fn stage(transfer_id: u32, pane_id: &str, generation: u32, kind: &str) -> Self {
        Self {
            kind: kind.to_string(),
            transfer_id: transfer_id.to_string(),
            pane_id: pane_id.to_string(),
            generation,
            transferred_bytes: "0".to_string(),
            total_bytes: "0".to_string(),
            code: String::new(),
            detail: String::new(),
        }
    }

    fn progress(
        transfer_id: u32,
        pane_id: &str,
        generation: u32,
        bytes: u64,
        total_bytes: u64,
    ) -> Self {
        let mut event = Self::stage(transfer_id, pane_id, generation, "progress");
        event.transferred_bytes = bytes.to_string();
        event.total_bytes = total_bytes.to_string();
        event
    }

    fn finalizing(
        transfer_id: u32,
        pane_id: &str,
        generation: u32,
        bytes: u64,
        total_bytes: u64,
    ) -> Self {
        let mut event = Self::stage(transfer_id, pane_id, generation, "finalizing");
        event.transferred_bytes = bytes.to_string();
        event.total_bytes = total_bytes.to_string();
        event
    }

    fn completed(
        transfer_id: u32,
        pane_id: &str,
        generation: u32,
        bytes: u64,
        total_bytes: u64,
    ) -> Self {
        let mut event = Self::stage(transfer_id, pane_id, generation, "completed");
        event.transferred_bytes = bytes.to_string();
        event.total_bytes = total_bytes.to_string();
        event
    }

    fn failed(transfer_id: u32, pane_id: &str, generation: u32, code: &str, detail: &str) -> Self {
        let mut event = Self::stage(transfer_id, pane_id, generation, "failed");
        event.code = code.to_string();
        event.detail = sanitize_server_text(detail);
        event
    }
}

impl AuthEvent {
    fn simple(kind: &str, layer: ConnectionLayer, session_id: u32, generation: u32) -> Self {
        Self {
            kind: kind.to_string(),
            layer: layer.as_str().to_string(),
            session_id: session_id.to_string(),
            generation,
            round_id: 0,
            text: String::new(),
            name: String::new(),
            instructions: String::new(),
            prompts: Vec::new(),
        }
    }

    fn banner(layer: ConnectionLayer, session_id: u32, generation: u32, text: &str) -> Self {
        Self {
            kind: "banner".to_string(),
            layer: layer.as_str().to_string(),
            session_id: session_id.to_string(),
            generation,
            round_id: 0,
            text: sanitize_server_text(text),
            name: String::new(),
            instructions: String::new(),
            prompts: Vec::new(),
        }
    }

    fn challenge(
        layer: ConnectionLayer,
        session_id: u32,
        generation: u32,
        challenge: AuthChallenge,
    ) -> Self {
        Self {
            kind: "challenge".to_string(),
            layer: layer.as_str().to_string(),
            session_id: session_id.to_string(),
            generation,
            round_id: challenge.round_id,
            text: String::new(),
            name: challenge.name,
            instructions: challenge.instructions,
            prompts: challenge
                .prompts
                .into_iter()
                .map(|prompt| AuthPromptEvent {
                    text: prompt.text,
                    echo: prompt.echo,
                })
                .collect(),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ConnectionLayer {
    Jump,
    Target,
}

impl ConnectionLayer {
    fn as_str(self) -> &'static str {
        match self {
            Self::Jump => "jump",
            Self::Target => "target",
        }
    }

    fn parse(value: &str) -> Option<Self> {
        match value {
            "jump" => Some(Self::Jump),
            "target" => Some(Self::Target),
            _ => None,
        }
    }
}

struct LayeredAuthMethod {
    layer: ConnectionLayer,
    method: AuthMethod,
}

#[derive(Clone, Copy)]
struct HostKeyDecision {
    layer: ConnectionLayer,
    accepted: bool,
}

type SharedHostKeyReceiver = Arc<tokio::sync::Mutex<tokio::sync::mpsc::Receiver<HostKeyDecision>>>;

async fn wait_for_host_key_decision(
    expected_layer: ConnectionLayer,
    receiver: &SharedHostKeyReceiver,
) -> bool {
    loop {
        let decision = receiver.lock().await.recv().await;
        match decision {
            Some(decision) if decision.layer == expected_layer => return decision.accepted,
            Some(decision) => {
                eprintln!(
                    "[LTTY_SSH] stage=host_key_response_rejected expected={} received={}",
                    expected_layer.as_str(),
                    decision.layer.as_str()
                );
            }
            None => return false,
        }
    }
}

const FINAL_DELIVERY_RETRY_ATTEMPTS: u32 = 128;
const FINAL_DELIVERY_RETRY_DELAY: Duration = Duration::from_millis(16);
const SSH_KEEPALIVE_INTERVAL_MAX_SECONDS: u32 = 3600;
const SSH_KEEPALIVE_COUNT_MAX: u32 = 100;
const AUTH_EXCHANGE_TIMEOUT: Duration = Duration::from_secs(30);
const AUTH_RESPONSE_TIMEOUT: Duration = Duration::from_secs(300);

fn build_client_config(interval_seconds: u32, count_max: u32) -> russh::client::Config {
    russh::client::Config {
        keepalive_interval: (interval_seconds > 0)
            .then(|| Duration::from_secs(interval_seconds as u64)),
        keepalive_max: count_max as usize,
        ..Default::default()
    }
}

fn validate_keepalive(interval_seconds: u32, count_max: u32, layer: &str) -> Result<()> {
    if interval_seconds > SSH_KEEPALIVE_INTERVAL_MAX_SECONDS {
        let message = format!(
            "{layer} server alive interval must be between 0 and {SSH_KEEPALIVE_INTERVAL_MAX_SECONDS}"
        );
        return Err(napi_error(&message));
    }
    if count_max == 0 || count_max > SSH_KEEPALIVE_COUNT_MAX {
        let message = format!(
            "{layer} server alive count max must be between 1 and {SSH_KEEPALIVE_COUNT_MAX}"
        );
        return Err(napi_error(&message));
    }
    Ok(())
}

#[derive(Default)]
struct OutputDeliveryMetrics {
    received_bytes: u64,
    napi_queued_bytes: u64,
    callback_retries: u64,
    final_delivery_failures: u64,
    final_delivery_failed_bytes: u64,
    output_batches: u64,
}

impl OutputDeliveryMetrics {
    fn record_callback_attempt(&mut self, status: Status, output_len: u64) -> bool {
        if status == Status::Ok {
            self.napi_queued_bytes += output_len;
            self.output_batches += 1;
            return true;
        }
        self.callback_retries += 1;
        false
    }

    fn record_final_delivery_failure(&mut self, output_len: u64) {
        self.final_delivery_failures += 1;
        self.final_delivery_failed_bytes += output_len;
    }

    fn summary(&self, output_paused: bool, final_snapshot: bool) -> String {
        format!(
            "received={},napiQueued={},callbackRetries={},\
             finalDeliveryFailures={},finalDeliveryFailedBytes={},batches={},paused={},final={}",
            self.received_bytes,
            self.napi_queued_bytes,
            self.callback_retries,
            self.final_delivery_failures,
            self.final_delivery_failed_bytes,
            self.output_batches,
            output_paused,
            final_snapshot
        )
    }
}

struct ShellSession {
    generation: u32,
    write_tx: WriteSender,
    resize_tx: ResizeSender,
    disconnect_tx: DisconnectSender,
    auth_tx: AuthSender,
    host_key_tx: tokio::sync::mpsc::Sender<HostKeyDecision>,
    output_pause_tx: OutputPauseSender,
}

struct MoshSession {
    generation: u32,
    write_tx: WriteSender,
    resize_tx: ResizeSender,
    disconnect_tx: DisconnectSender,
    auth_tx: AuthSender,
    host_key_tx: tokio::sync::mpsc::Sender<HostKeyDecision>,
    output_pause_tx: OutputPauseSender,
}

struct FileTransferSession {
    generation: u32,
    disconnect_tx: DisconnectSender,
    auth_tx: AuthSender,
    host_key_tx: tokio::sync::mpsc::Sender<HostKeyDecision>,
}

type SessionMap = Arc<Mutex<HashMap<u32, ShellSession>>>;

fn get_sessions() -> &'static SessionMap {
    use once_cell::sync::Lazy;
    static SESSIONS: Lazy<SessionMap> = Lazy::new(|| Arc::new(Mutex::new(HashMap::new())));
    &SESSIONS
}

type MoshSessionMap = Arc<Mutex<HashMap<u32, MoshSession>>>;

fn get_mosh_sessions() -> &'static MoshSessionMap {
    use once_cell::sync::Lazy;
    static SESSIONS: Lazy<MoshSessionMap> = Lazy::new(|| Arc::new(Mutex::new(HashMap::new())));
    &SESSIONS
}

type FileTransferSessionMap = Arc<Mutex<HashMap<u32, FileTransferSession>>>;

fn get_file_transfer_sessions() -> &'static FileTransferSessionMap {
    use once_cell::sync::Lazy;
    static SESSIONS: Lazy<FileTransferSessionMap> =
        Lazy::new(|| Arc::new(Mutex::new(HashMap::new())));
    &SESSIONS
}

fn napi_error(message: &str) -> Error {
    Error::new(Status::GenericFailure, message)
}

fn remove_session(session_id: u32) {
    if let Ok(mut sessions) = get_sessions().lock() {
        sessions.remove(&session_id);
    }
}

struct SessionCleanupGuard(u32);

impl Drop for SessionCleanupGuard {
    fn drop(&mut self) {
        remove_session(self.0);
    }
}

struct MoshSessionCleanupGuard(u32);

impl Drop for MoshSessionCleanupGuard {
    fn drop(&mut self) {
        if let Ok(mut sessions) = get_mosh_sessions().lock() {
            sessions.remove(&self.0);
        }
    }
}

struct FileTransferCleanupGuard(u32);

impl Drop for FileTransferCleanupGuard {
    fn drop(&mut self) {
        if let Ok(mut sessions) = get_file_transfer_sessions().lock() {
            sessions.remove(&self.0);
        }
    }
}

struct LocalTempCleanup(Option<PathBuf>);

impl LocalTempCleanup {
    fn keep(&mut self) {
        self.0 = None;
    }
}

impl Drop for LocalTempCleanup {
    fn drop(&mut self) {
        if let Some(path) = self.0.take() {
            let _ = std::fs::remove_file(path);
        }
    }
}

fn send_control(callback: &JsControlCallback, event: ControlEvent) -> bool {
    let status = callback.call(event, ThreadsafeFunctionCallMode::Blocking);
    if status != Status::Ok {
        eprintln!("[LTTY_SSH] callback=control status={}", status);
        return false;
    }
    true
}

fn send_control_error(
    callback: &JsControlCallback,
    session_id: u32,
    generation: u32,
    layer: ConnectionLayer,
    stage: &str,
    code: &str,
    detail: &str,
) {
    let _ = send_control(
        callback,
        ControlEvent::error(session_id, generation, layer, stage, code, detail),
    );
}

fn try_send_transport_data(callback: &JsTransportCallback, value: Vec<u8>) -> Status {
    let status = callback.call(
        TransportEvent::data(value),
        ThreadsafeFunctionCallMode::NonBlocking,
    );
    if status != Status::Ok && status != Status::QueueFull {
        eprintln!("[LTTY_SSH] callback=transport_data status={}", status);
    }
    status
}

fn send_transport_data_blocking(callback: &JsTransportCallback, value: Vec<u8>) -> bool {
    let status = callback.call(
        TransportEvent::data(value),
        ThreadsafeFunctionCallMode::Blocking,
    );
    if status != Status::Ok {
        eprintln!("[LTTY_MOSH] callback=transport_data status={}", status);
        return false;
    }
    true
}

fn send_transport_close(
    callback: &JsTransportCallback,
    exit_code: i32,
    layer: String,
    code: String,
    detail: String,
) -> bool {
    let status = callback.call(
        TransportEvent::close(exit_code, layer, code, detail),
        ThreadsafeFunctionCallMode::Blocking,
    );
    if status != Status::Ok {
        eprintln!("[LTTY_SSH] callback=transport_close status={}", status);
        return false;
    }
    true
}

fn send_transport_diagnostic(
    callback: &JsTransportCallback,
    enabled: bool,
    layer: ConnectionLayer,
    stage: &str,
    status: &str,
) {
    if !enabled {
        return;
    }
    let event = TransportEvent::diagnostic(layer, stage, status);
    let status = callback.call(event, ThreadsafeFunctionCallMode::Blocking);
    if status != Status::Ok {
        eprintln!("[LTTY_SSH] callback=transport_diagnostic status={}", status);
    }
}

fn send_transport_failure_diagnostic(
    callback: &JsTransportCallback,
    enabled: bool,
    layer: ConnectionLayer,
    stage: &str,
    reason: &str,
) {
    if !enabled {
        return;
    }
    let event = TransportEvent::diagnostic_failure(layer, stage, reason);
    let status = callback.call(event, ThreadsafeFunctionCallMode::Blocking);
    if status != Status::Ok {
        eprintln!("[LTTY_SSH] callback=transport_diagnostic status={}", status);
    }
}

fn mosh_reachability_fields(
    reachability: MoshSessionReachability,
) -> Option<(&'static str, &'static str)> {
    match reachability {
        MoshSessionReachability::AwaitingPeer => Some(("awaiting_peer", "")),
        MoshSessionReachability::Responsive => Some(("responsive", "")),
        MoshSessionReachability::Interrupted {
            reason: MoshSessionInterruption::NoRecentContact,
        } => Some(("interrupted", "no_recent_contact")),
        MoshSessionReachability::Interrupted {
            reason: MoshSessionInterruption::NoRecentReply,
        } => Some(("interrupted", "no_recent_reply")),
        _ => None,
    }
}

fn send_mosh_reachability(
    callback: &JsTransportCallback,
    reachability: MoshSessionReachability,
) -> bool {
    let Some((status, reason)) = mosh_reachability_fields(reachability) else {
        return true;
    };
    let result = callback.call(
        TransportEvent::mosh_reachability(status, reason),
        ThreadsafeFunctionCallMode::Blocking,
    );
    if result != Status::Ok {
        eprintln!("[LTTY_MOSH] callback=reachability status={result}");
        return false;
    }
    true
}

fn connect_failure_reason(error: &russh::Error, can_resolve_name: bool) -> &'static str {
    match error {
        russh::Error::IO(io_error) => match io_error.kind() {
            std::io::ErrorKind::ConnectionRefused => "tcp_refused",
            std::io::ErrorKind::TimedOut => "tcp_timeout",
            _ if can_resolve_name && io_error.raw_os_error().is_none() => "name_resolution",
            _ => "tcp_failed",
        },
        russh::Error::Version => "ssh_version",
        russh::Error::KexInit
        | russh::Error::Kex
        | russh::Error::NoCommonAlgo { .. }
        | russh::Error::UnknownAlgo
        | russh::Error::WrongServerSig
        | russh::Error::PacketAuth
        | russh::Error::StrictKeyExchangeViolation { .. }
        | russh::Error::DecryptionError => "key_exchange",
        _ => "transport_failed",
    }
}

fn send_auth_event(callback: &JsAuthCallback, event: AuthEvent) -> bool {
    let status = callback.call(event, ThreadsafeFunctionCallMode::Blocking);
    if status != Status::Ok {
        eprintln!("[LTTY_SSH] callback=auth status={}", status);
        return false;
    }
    true
}

fn send_file_transfer_event(
    callback: &JsFileTransferCallback,
    event: FileTransferEvent,
    final_event: bool,
) -> bool {
    let mode = if final_event {
        ThreadsafeFunctionCallMode::Blocking
    } else {
        ThreadsafeFunctionCallMode::NonBlocking
    };
    let status = callback.call(event, mode);
    if status != Status::Ok {
        eprintln!("[LTTY_SSH] callback=file_transfer status={}", status);
        return false;
    }
    true
}

fn should_flush_immediately(pending_empty: bool, decoded_len: usize) -> bool {
    pending_empty && decoded_len > 0 && decoded_len <= 256
}

struct ClientHandler {
    session_id: u32,
    generation: u32,
    layer: ConnectionLayer,
    host: String,
    port: u16,
    known_hosts_path: PathBuf,
    host_key_rx: SharedHostKeyReceiver,
    connect_progress_tx: tokio::sync::mpsc::Sender<ConnectProgress>,
    transport_callback: Option<JsTransportCallback>,
    verbose: bool,
    control_callback: JsControlCallback,
    auth_callback: JsAuthCallback,
}

impl russh::client::Handler for ClientHandler {
    type Error = russh::Error;

    async fn auth_banner(
        &mut self,
        banner: &str,
        _session: &mut russh::client::Session,
    ) -> std::result::Result<(), Self::Error> {
        if !send_auth_event(
            &self.auth_callback,
            AuthEvent::banner(self.layer, self.session_id, self.generation, banner),
        ) {
            return Err(russh::Error::SendError);
        }
        Ok(())
    }

    async fn check_server_key(
        &mut self,
        server_public_key: &russh::keys::ssh_key::PublicKey,
    ) -> std::result::Result<bool, Self::Error> {
        if let Some(callback) = &self.transport_callback {
            send_transport_diagnostic(callback, self.verbose, self.layer, "host_key", "started");
        }
        match russh::keys::known_hosts::check_known_hosts_path(
            &self.host,
            self.port,
            server_public_key,
            &self.known_hosts_path,
        ) {
            Ok(true) => {
                if let Some(callback) = &self.transport_callback {
                    send_transport_diagnostic(
                        callback,
                        self.verbose,
                        self.layer,
                        "host_key",
                        "succeeded",
                    );
                }
                Ok(true)
            }
            Ok(false) => {
                let fingerprint = server_public_key
                    .fingerprint(russh::keys::HashAlg::Sha256)
                    .to_string();
                let host = if self.port == 22 {
                    self.host.clone()
                } else {
                    format!("[{}]:{}", self.host, self.port)
                };
                let public_key = match server_public_key.to_openssh() {
                    Ok(value) => value,
                    Err(error) => {
                        send_control(
                            &self.control_callback,
                            ControlEvent::error(
                                self.session_id,
                                self.generation,
                                self.layer,
                                "host_key",
                                "host_key",
                                &error.to_string(),
                            ),
                        );
                        return Ok(false);
                    }
                };
                send_control(
                    &self.control_callback,
                    ControlEvent::host_key_prompt(
                        self.session_id,
                        self.generation,
                        self.layer,
                        format!("{} {}", server_public_key.algorithm(), fingerprint),
                        format!("{host} {public_key}"),
                    ),
                );
                if let Some(callback) = &self.transport_callback {
                    send_transport_diagnostic(
                        callback,
                        self.verbose,
                        self.layer,
                        "host_key",
                        "waiting",
                    );
                }
                let _ = self
                    .connect_progress_tx
                    .send(ConnectProgress::WaitingForUser)
                    .await;
                let accepted = wait_for_host_key_decision(self.layer, &self.host_key_rx).await;
                let _ = self
                    .connect_progress_tx
                    .send(ConnectProgress::NetworkActivityResumed)
                    .await;
                if let Some(callback) = &self.transport_callback {
                    send_transport_diagnostic(
                        callback,
                        self.verbose,
                        self.layer,
                        "host_key",
                        if accepted { "succeeded" } else { "failed" },
                    );
                }
                Ok(accepted)
            }
            Err(error) => {
                if let Some(callback) = &self.transport_callback {
                    send_transport_diagnostic(
                        callback,
                        self.verbose,
                        self.layer,
                        "host_key",
                        "failed",
                    );
                }
                let new_fingerprint = server_public_key
                    .fingerprint(russh::keys::HashAlg::Sha256)
                    .to_string();
                if let russh::keys::Error::KeyChanged { line } = error {
                    let old_fingerprint = russh::keys::known_hosts::known_host_keys_path(
                        &self.host,
                        self.port,
                        &self.known_hosts_path,
                    )
                    .ok()
                    .and_then(|keys| {
                        keys.into_iter()
                            .find(|(recorded_line, _)| *recorded_line == line)
                    })
                    .map(|(_, key)| key.fingerprint(russh::keys::HashAlg::Sha256).to_string())
                    .unwrap_or_else(|| "unavailable".to_string());
                    send_control(
                        &self.control_callback,
                        ControlEvent::host_key_changed(
                            self.session_id,
                            self.generation,
                            self.layer,
                            ChangedHostKeyControl {
                                algorithm: server_public_key.algorithm().to_string(),
                                old_fingerprint,
                                new_fingerprint,
                                host: self.host.clone(),
                                port: self.port,
                            },
                        ),
                    );
                } else {
                    send_control(
                        &self.control_callback,
                        ControlEvent::error(
                            self.session_id,
                            self.generation,
                            self.layer,
                            "host_key",
                            "host_key",
                            &error.to_string(),
                        ),
                    );
                }
                Ok(false)
            }
        }
    }
}

struct SessionReceivers {
    write_rx: tokio::sync::mpsc::Receiver<Vec<u8>>,
    resize_rx: tokio::sync::mpsc::Receiver<(u32, u32)>,
    disconnect_rx: tokio::sync::mpsc::Receiver<()>,
    auth_rx: tokio::sync::mpsc::Receiver<LayeredAuthMethod>,
    host_key_rx: Option<tokio::sync::mpsc::Receiver<HostKeyDecision>>,
    output_pause_rx: tokio::sync::mpsc::Receiver<bool>,
}

const INPUT_WRITE_CHUNK_BYTES: usize = 32 * 1024;

async fn send_scheduled_input<S, SF, R, RF, E>(
    bytes: Vec<u8>,
    resize_rx: &mut tokio::sync::mpsc::Receiver<(u32, u32)>,
    mut send_chunk: S,
    mut send_resize: R,
) -> (std::result::Result<(), E>, Vec<E>)
where
    S: FnMut(Vec<u8>) -> SF,
    SF: Future<Output = std::result::Result<(), E>>,
    R: FnMut((u32, u32)) -> RF,
    RF: Future<Output = std::result::Result<(), E>>,
{
    if bytes.is_empty() {
        return (send_chunk(bytes).await, Vec::new());
    }

    let mut resize_errors = Vec::new();
    let mut resize_open = true;
    let mut offset = 0;
    while offset < bytes.len() {
        let end = (offset + INPUT_WRITE_CHUNK_BYTES).min(bytes.len());
        let mut sending = Box::pin(send_chunk(bytes[offset..end].to_vec()));
        let write_result = loop {
            if !resize_open {
                break sending.as_mut().await;
            }
            tokio::select! {
              size = resize_rx.recv() => {
                match size {
                  Some(mut latest) => {
                    while let Ok(next) = resize_rx.try_recv() {
                      latest = next;
                    }
                    if let Err(error) = send_resize(latest).await {
                      resize_errors.push(error);
                    }
                  }
                  None => resize_open = false,
                }
              }
              result = sending.as_mut() => break result,
            }
        };
        if let Err(error) = write_result {
            return (Err(error), resize_errors);
        }
        offset = end;
        if offset < bytes.len() {
            tokio::task::yield_now().await;
        }
    }
    (Ok(()), resize_errors)
}

async fn run_channel_writer_core<R>(
    channel: russh::ChannelWriteHalf<russh::client::Msg>,
    mut write_rx: tokio::sync::mpsc::Receiver<Vec<u8>>,
    mut resize_rx: tokio::sync::mpsc::Receiver<(u32, u32)>,
    mut report: R,
) where
    R: FnMut(&'static str, String),
{
    loop {
        tokio::select! {
          data = write_rx.recv() => {
            match data {
              Some(bytes) => {
                let (write_result, resize_errors) = send_scheduled_input(
                  bytes,
                  &mut resize_rx,
                  |chunk| channel.data_bytes(chunk),
                  |(cols, rows)| channel.window_change(cols, rows, 0, 0),
                ).await;
                for error in resize_errors {
                  report("resize", error.to_string());
                }
                if let Err(error) = write_result {
                  report("write", error.to_string());
                }
              }
              None => break,
            }
          }
          size = resize_rx.recv() => {
            match size {
              Some((cols, rows)) => {
                if let Err(error) = channel.window_change(cols, rows, 0, 0).await {
                  report("resize", error.to_string());
                }
              }
              None => break,
            }
          }
        }
    }
}

async fn run_channel_writer(
    channel: russh::ChannelWriteHalf<russh::client::Msg>,
    write_rx: tokio::sync::mpsc::Receiver<Vec<u8>>,
    resize_rx: tokio::sync::mpsc::Receiver<(u32, u32)>,
    session_id: u32,
    generation: u32,
    control_callback: JsControlCallback,
) {
    run_channel_writer_core(channel, write_rx, resize_rx, |stage, detail| {
        let event = if stage == "resize" {
            ControlEvent::warning(
                session_id,
                generation,
                ConnectionLayer::Target,
                stage,
                "internal",
                &detail,
            )
        } else {
            ControlEvent::error(
                session_id,
                generation,
                ConnectionLayer::Target,
                stage,
                "internal",
                &detail,
            )
        };
        send_control(&control_callback, event);
    })
    .await;
}

fn channel_writer_exit_message(result: std::result::Result<(), tokio::task::JoinError>) -> String {
    match result {
        Ok(()) => "SSH channel writer stopped unexpectedly".to_string(),
        Err(error) => format!("SSH channel writer task failed: {error}"),
    }
}

enum ConnectWaitResult<T, E> {
    Connected(T),
    Failed(E),
    TimedOut,
    Cancelled,
}

enum AuthWaitResult {
    Command(AuthMethod),
    Cancelled,
    TimedOut,
}

enum AuthExchangeResult<T, E> {
    Completed(T),
    Failed(E),
    Cancelled,
    TimedOut,
}

async fn wait_for_auth_exchange<F, T, E>(
    exchange: F,
    timeout: Duration,
    disconnect_rx: &mut tokio::sync::mpsc::Receiver<()>,
) -> AuthExchangeResult<T, E>
where
    F: Future<Output = std::result::Result<T, E>>,
{
    tokio::select! {
      result = exchange => match result {
        Ok(value) => AuthExchangeResult::Completed(value),
        Err(error) => AuthExchangeResult::Failed(error),
      },
      _ = disconnect_rx.recv() => AuthExchangeResult::Cancelled,
      _ = tokio::time::sleep(timeout) => AuthExchangeResult::TimedOut,
    }
}

async fn wait_for_auth_command(
    expected_layer: ConnectionLayer,
    auth_rx: &mut tokio::sync::mpsc::Receiver<LayeredAuthMethod>,
    disconnect_rx: &mut tokio::sync::mpsc::Receiver<()>,
    timeout: Duration,
) -> AuthWaitResult {
    let deadline = tokio::time::sleep(timeout);
    tokio::pin!(deadline);
    loop {
        tokio::select! {
          command = auth_rx.recv() => match command {
            Some(command) if command.layer == expected_layer => {
              return AuthWaitResult::Command(command.method);
            }
            Some(command) => {
              eprintln!(
                "[LTTY_SSH] stage=auth_response_rejected expected={} received={}",
                expected_layer.as_str(),
                command.layer.as_str()
              );
            }
            None => return AuthWaitResult::Cancelled,
          },
          _ = disconnect_rx.recv() => return AuthWaitResult::Cancelled,
          _ = &mut deadline => return AuthWaitResult::TimedOut,
        }
    }
}

fn auth_method_kinds(methods: &russh::MethodSet) -> Vec<AuthMethodKind> {
    methods
        .iter()
        .filter_map(|method| match method {
            russh::MethodKind::PublicKey => Some(AuthMethodKind::PublicKey),
            russh::MethodKind::Password => Some(AuthMethodKind::Password),
            russh::MethodKind::KeyboardInteractive => Some(AuthMethodKind::KeyboardInteractive),
            _ => None,
        })
        .collect()
}

fn auth_failure_message(failure: AuthFailure) -> &'static str {
    match failure {
        AuthFailure::NoSupportedMethod => "no supported authentication method is available",
        AuthFailure::Rejected => "authentication was rejected",
        AuthFailure::UnexpectedCredential => "unexpected authentication credential",
        AuthFailure::UnexpectedChallenge => "unexpected keyboard-interactive challenge",
        AuthFailure::StaleChallenge => "stale keyboard-interactive response",
        AuthFailure::ResponseCountMismatch => {
            "keyboard-interactive response count does not match prompts"
        }
        AuthFailure::ProtocolLimitExceeded => "authentication protocol limit exceeded",
    }
}

enum AuthenticationOutcome {
    Authenticated,
    Cancelled,
    Failed(String),
}

async fn authenticate_private_key(
    ssh: &mut russh::client::Handle<ClientHandler>,
    user: &str,
    key_path: &str,
    passphrase: &str,
) -> std::result::Result<russh::client::AuthResult, String> {
    let key = keygen::load_private_key(key_path, passphrase)
        .map_err(|error| format!("private key could not be loaded: {error}"))?;
    let wrapped = russh::keys::key::PrivateKeyWithHashAlg::new(Arc::new(key), None);
    ssh.authenticate_publickey(user, wrapped)
        .await
        .map_err(|error| format!("public-key authentication failed: {error}"))
}

#[allow(clippy::too_many_arguments)]
async fn run_authentication(
    session_id: u32,
    generation: u32,
    layer: ConnectionLayer,
    user: &str,
    private_key_path: &str,
    private_key_requires_passphrase: bool,
    ssh: &mut russh::client::Handle<ClientHandler>,
    auth_callback: &JsAuthCallback,
    auth_rx: &mut tokio::sync::mpsc::Receiver<LayeredAuthMethod>,
    disconnect_rx: &mut tokio::sync::mpsc::Receiver<()>,
) -> AuthenticationOutcome {
    let mut state = AuthStateMachine::new(
        !private_key_path.is_empty(),
        private_key_requires_passphrase,
    );
    let mut result = match wait_for_auth_exchange(
        ssh.authenticate_none(user),
        AUTH_EXCHANGE_TIMEOUT,
        disconnect_rx,
    )
    .await
    {
        AuthExchangeResult::Completed(result) => result,
        AuthExchangeResult::Failed(error) => {
            return AuthenticationOutcome::Failed(format!(
                "authentication negotiation failed: {error}"
            ));
        }
        AuthExchangeResult::Cancelled => return AuthenticationOutcome::Cancelled,
        AuthExchangeResult::TimedOut => {
            return AuthenticationOutcome::Failed("authentication exchange timed out".to_string());
        }
    };

    loop {
        let (remaining_methods, partial_success) = match result {
            russh::client::AuthResult::Success => return AuthenticationOutcome::Authenticated,
            russh::client::AuthResult::Failure {
                ref remaining_methods,
                partial_success,
            } => (auth_method_kinds(remaining_methods), partial_success),
        };
        let action = state.select_next_method(&remaining_methods, partial_success);
        let action_name = match &action {
            AuthAction::AttemptPublicKey => "public_key",
            AuthAction::RequestPrivateKeyPassphrase => "private_key_passphrase",
            AuthAction::RequestPassword => "password",
            AuthAction::StartKeyboardInteractive => "keyboard_interactive",
            AuthAction::PresentChallenge(_) => "challenge",
            AuthAction::Fail(_) => "fail",
        };
        eprintln!(
            "[LTTY_SSH] session={} layer={} stage=auth_select action={} partial_success={}",
            session_id,
            layer.as_str(),
            action_name,
            partial_success
        );

        match action {
            AuthAction::AttemptPublicKey => {
                result = match wait_for_auth_exchange(
                    authenticate_private_key(ssh, user, private_key_path, ""),
                    AUTH_EXCHANGE_TIMEOUT,
                    disconnect_rx,
                )
                .await
                {
                    AuthExchangeResult::Completed(result) => result,
                    AuthExchangeResult::Failed(error) => {
                        return AuthenticationOutcome::Failed(error);
                    }
                    AuthExchangeResult::Cancelled => return AuthenticationOutcome::Cancelled,
                    AuthExchangeResult::TimedOut => {
                        return AuthenticationOutcome::Failed(
                            "authentication exchange timed out".to_string(),
                        );
                    }
                };
            }
            AuthAction::RequestPrivateKeyPassphrase => {
                if !send_auth_event(
                    auth_callback,
                    AuthEvent::simple("private_key_passphrase", layer, session_id, generation),
                ) {
                    return AuthenticationOutcome::Failed(
                        "authentication callback delivery failed".to_string(),
                    );
                }
                let mut command = match wait_for_auth_command(
                    layer,
                    auth_rx,
                    disconnect_rx,
                    AUTH_RESPONSE_TIMEOUT,
                )
                .await
                {
                    AuthWaitResult::Command(command) => command,
                    AuthWaitResult::Cancelled => return AuthenticationOutcome::Cancelled,
                    AuthWaitResult::TimedOut => {
                        return AuthenticationOutcome::Failed(
                            "authentication response timed out".to_string(),
                        );
                    }
                };
                let passphrase = match &mut command {
                    AuthMethod::PrivateKeyPassphrase(passphrase) => passphrase,
                    _ => {
                        return AuthenticationOutcome::Failed(
                            auth_failure_message(AuthFailure::UnexpectedCredential).to_string(),
                        );
                    }
                };
                if let AuthAction::Fail(failure) = state.submit_private_key_passphrase() {
                    return AuthenticationOutcome::Failed(
                        auth_failure_message(failure).to_string(),
                    );
                }
                result = match wait_for_auth_exchange(
                    authenticate_private_key(ssh, user, private_key_path, passphrase.as_str()),
                    AUTH_EXCHANGE_TIMEOUT,
                    disconnect_rx,
                )
                .await
                {
                    AuthExchangeResult::Completed(result) => result,
                    AuthExchangeResult::Failed(error) => {
                        return AuthenticationOutcome::Failed(error);
                    }
                    AuthExchangeResult::Cancelled => return AuthenticationOutcome::Cancelled,
                    AuthExchangeResult::TimedOut => {
                        return AuthenticationOutcome::Failed(
                            "authentication exchange timed out".to_string(),
                        );
                    }
                };
            }
            AuthAction::RequestPassword => {
                if !send_auth_event(
                    auth_callback,
                    AuthEvent::simple("password", layer, session_id, generation),
                ) {
                    return AuthenticationOutcome::Failed(
                        "authentication callback delivery failed".to_string(),
                    );
                }
                let mut command = match wait_for_auth_command(
                    layer,
                    auth_rx,
                    disconnect_rx,
                    AUTH_RESPONSE_TIMEOUT,
                )
                .await
                {
                    AuthWaitResult::Command(command) => command,
                    AuthWaitResult::Cancelled => return AuthenticationOutcome::Cancelled,
                    AuthWaitResult::TimedOut => {
                        return AuthenticationOutcome::Failed(
                            "authentication response timed out".to_string(),
                        );
                    }
                };
                let password = match &mut command {
                    AuthMethod::Password(password) => password,
                    _ => {
                        return AuthenticationOutcome::Failed(
                            auth_failure_message(AuthFailure::UnexpectedCredential).to_string(),
                        );
                    }
                };
                if let Err(failure) = state.submit_password() {
                    return AuthenticationOutcome::Failed(
                        auth_failure_message(failure).to_string(),
                    );
                }
                result = match wait_for_auth_exchange(
                    ssh.authenticate_password(user, password.as_str()),
                    AUTH_EXCHANGE_TIMEOUT,
                    disconnect_rx,
                )
                .await
                {
                    AuthExchangeResult::Completed(result) => result,
                    AuthExchangeResult::Failed(error) => {
                        return AuthenticationOutcome::Failed(format!(
                            "password authentication failed: {error}"
                        ));
                    }
                    AuthExchangeResult::Cancelled => return AuthenticationOutcome::Cancelled,
                    AuthExchangeResult::TimedOut => {
                        return AuthenticationOutcome::Failed(
                            "authentication exchange timed out".to_string(),
                        );
                    }
                };
            }
            AuthAction::StartKeyboardInteractive => {
                let mut response = match wait_for_auth_exchange(
                    ssh.authenticate_keyboard_interactive_start(user, None::<String>),
                    AUTH_EXCHANGE_TIMEOUT,
                    disconnect_rx,
                )
                .await
                {
                    AuthExchangeResult::Completed(response) => response,
                    AuthExchangeResult::Failed(error) => {
                        return AuthenticationOutcome::Failed(format!(
                            "keyboard-interactive authentication failed: {error}"
                        ));
                    }
                    AuthExchangeResult::Cancelled => return AuthenticationOutcome::Cancelled,
                    AuthExchangeResult::TimedOut => {
                        return AuthenticationOutcome::Failed(
                            "authentication exchange timed out".to_string(),
                        );
                    }
                };
                loop {
                    match response {
                        russh::client::KeyboardInteractiveAuthResponse::Success => {
                            return AuthenticationOutcome::Authenticated;
                        }
                        russh::client::KeyboardInteractiveAuthResponse::Failure {
                            remaining_methods,
                            partial_success,
                        } => {
                            result = russh::client::AuthResult::Failure {
                                remaining_methods,
                                partial_success,
                            };
                            break;
                        }
                        russh::client::KeyboardInteractiveAuthResponse::InfoRequest {
                            name,
                            instructions,
                            prompts,
                        } => {
                            let prompts = prompts
                                .into_iter()
                                .map(|prompt| AuthPrompt {
                                    text: prompt.prompt,
                                    echo: prompt.echo,
                                })
                                .collect();
                            let challenge =
                                match state.present_challenge(name, instructions, prompts) {
                                    AuthAction::PresentChallenge(challenge) => challenge,
                                    AuthAction::Fail(failure) => {
                                        return AuthenticationOutcome::Failed(
                                            auth_failure_message(failure).to_string(),
                                        );
                                    }
                                    _ => {
                                        return AuthenticationOutcome::Failed(
                                            auth_failure_message(AuthFailure::UnexpectedChallenge)
                                                .to_string(),
                                        );
                                    }
                                };
                            if !send_auth_event(
                                auth_callback,
                                AuthEvent::challenge(layer, session_id, generation, challenge),
                            ) {
                                return AuthenticationOutcome::Failed(
                                    "authentication callback delivery failed".to_string(),
                                );
                            }
                            let mut command = match wait_for_auth_command(
                                layer,
                                auth_rx,
                                disconnect_rx,
                                AUTH_RESPONSE_TIMEOUT,
                            )
                            .await
                            {
                                AuthWaitResult::Command(command) => command,
                                AuthWaitResult::Cancelled => {
                                    return AuthenticationOutcome::Cancelled;
                                }
                                AuthWaitResult::TimedOut => {
                                    return AuthenticationOutcome::Failed(
                                        "authentication response timed out".to_string(),
                                    );
                                }
                            };
                            let (round_id, responses) = match &mut command {
                                AuthMethod::KeyboardInteractiveResponses {
                                    round_id,
                                    responses,
                                } => (*round_id, responses),
                                _ => {
                                    return AuthenticationOutcome::Failed(
                                        auth_failure_message(AuthFailure::UnexpectedCredential)
                                            .to_string(),
                                    );
                                }
                            };
                            if let Err(failure) = state.validate_responses(round_id, responses) {
                                return AuthenticationOutcome::Failed(
                                    auth_failure_message(failure).to_string(),
                                );
                            }
                            let responses = std::mem::take(responses);
                            response = match wait_for_auth_exchange(
                                ssh.authenticate_keyboard_interactive_respond(responses),
                                AUTH_EXCHANGE_TIMEOUT,
                                disconnect_rx,
                            )
                            .await
                            {
                                AuthExchangeResult::Completed(response) => response,
                                AuthExchangeResult::Failed(error) => {
                                    return AuthenticationOutcome::Failed(format!(
                                        "keyboard-interactive response failed: {error}"
                                    ));
                                }
                                AuthExchangeResult::Cancelled => {
                                    return AuthenticationOutcome::Cancelled;
                                }
                                AuthExchangeResult::TimedOut => {
                                    return AuthenticationOutcome::Failed(
                                        "authentication exchange timed out".to_string(),
                                    );
                                }
                            };
                        }
                    }
                }
            }
            AuthAction::Fail(failure) => {
                return AuthenticationOutcome::Failed(auth_failure_message(failure).to_string());
            }
            AuthAction::PresentChallenge(_) => {
                return AuthenticationOutcome::Failed(
                    auth_failure_message(AuthFailure::UnexpectedChallenge).to_string(),
                );
            }
        }
    }
}

#[derive(Clone, Copy)]
enum ConnectProgress {
    WaitingForUser,
    NetworkActivityResumed,
}

async fn wait_for_connect<F, T, E>(
    connect: F,
    timeout: Duration,
    disconnect_rx: &mut tokio::sync::mpsc::Receiver<()>,
    progress_rx: &mut tokio::sync::mpsc::Receiver<ConnectProgress>,
) -> ConnectWaitResult<T, E>
where
    F: Future<Output = std::result::Result<T, E>>,
{
    tokio::pin!(connect);
    let deadline = tokio::time::sleep(timeout);
    tokio::pin!(deadline);
    let mut waiting_for_user = false;

    loop {
        tokio::select! {
          biased;
          result = &mut connect => return match result {
            Ok(value) => ConnectWaitResult::Connected(value),
            Err(error) => ConnectWaitResult::Failed(error),
          },
          _ = disconnect_rx.recv() => return ConnectWaitResult::Cancelled,
          progress = progress_rx.recv() => match progress {
            Some(ConnectProgress::WaitingForUser) => waiting_for_user = true,
            Some(ConnectProgress::NetworkActivityResumed) => {
              waiting_for_user = false;
              deadline.as_mut().reset(tokio::time::Instant::now() + timeout);
            }
            None => {}
          },
          _ = &mut deadline, if !waiting_for_user => return ConnectWaitResult::TimedOut,
        }
    }
}

async fn disconnect_client(ssh: &mut russh::client::Handle<ClientHandler>) {
    let _ = tokio::time::timeout(
        Duration::from_secs(1),
        ssh.disconnect(russh::Disconnect::ByApplication, "", ""),
    )
    .await;
}

async fn wait_for_jump_connection(
    jump: &mut Option<russh::client::Handle<ClientHandler>>,
) -> std::result::Result<(), russh::Error> {
    match jump.as_mut() {
        Some(handle) => handle.await,
        None => std::future::pending().await,
    }
}

type SshClientHandle = russh::client::Handle<ClientHandler>;
type SshChannel = russh::Channel<russh::client::Msg>;

struct SessionEndpoint {
    layer: ConnectionLayer,
    host: String,
    port: u16,
    user: String,
    private_key_path: String,
    private_key_requires_passphrase: bool,
    connect_timeout: Duration,
    server_alive_interval_seconds: u32,
    server_alive_count_max: u32,
}

struct SessionPhaseContext {
    session_id: u32,
    generation: u32,
    verbose: bool,
    known_hosts_path: PathBuf,
    host_key_rx: SharedHostKeyReceiver,
    transport_callback: JsTransportCallback,
    control_callback: JsControlCallback,
    auth_callback: JsAuthCallback,
}

impl SessionPhaseContext {
    fn client_handler(
        &self,
        endpoint: &SessionEndpoint,
        connect_progress_tx: tokio::sync::mpsc::Sender<ConnectProgress>,
    ) -> ClientHandler {
        ClientHandler {
            session_id: self.session_id,
            generation: self.generation,
            layer: endpoint.layer,
            host: endpoint.host.clone(),
            port: endpoint.port,
            known_hosts_path: self.known_hosts_path.clone(),
            host_key_rx: self.host_key_rx.clone(),
            connect_progress_tx,
            transport_callback: Some(self.transport_callback.clone()),
            verbose: self.verbose,
            control_callback: self.control_callback.clone(),
            auth_callback: self.auth_callback.clone(),
        }
    }
}

#[derive(Debug)]
struct SessionPhaseFailure {
    layer: ConnectionLayer,
    stage: &'static str,
    code: &'static str,
    detail: String,
    diagnostic_status: &'static str,
    diagnostic_reason: Option<&'static str>,
}

impl SessionPhaseFailure {
    fn failed(
        layer: ConnectionLayer,
        stage: &'static str,
        code: &'static str,
        detail: String,
    ) -> Self {
        Self {
            layer,
            stage,
            code,
            detail,
            diagnostic_status: "failed",
            diagnostic_reason: None,
        }
    }

    fn timed_out(
        layer: ConnectionLayer,
        stage: &'static str,
        code: &'static str,
        detail: String,
    ) -> Self {
        Self {
            layer,
            stage,
            code,
            detail,
            diagnostic_status: "timed_out",
            diagnostic_reason: None,
        }
    }

    fn connect_failed(layer: ConnectionLayer, detail: String, reason: &'static str) -> Self {
        Self {
            layer,
            stage: "connect",
            code: "network",
            detail,
            diagnostic_status: "failed",
            diagnostic_reason: Some(reason),
        }
    }
}

#[derive(Debug)]
enum SessionPhaseStop {
    Cancelled,
    Failed(SessionPhaseFailure),
}

type SessionPhaseResult<T> = std::result::Result<T, SessionPhaseStop>;

#[derive(Default)]
struct SessionRoute {
    jump: Option<SshClientHandle>,
    target: Option<SshClientHandle>,
}

impl SessionRoute {
    async fn disconnect(&mut self) {
        if let Some(target) = self.target.as_mut() {
            disconnect_client(target).await;
        }
        if let Some(jump) = self.jump.as_mut() {
            disconnect_client(jump).await;
        }
    }
}

fn report_session_phase_stop(context: &SessionPhaseContext, stop: &SessionPhaseStop) {
    let SessionPhaseStop::Failed(failure) = stop else {
        return;
    };
    if let Some(reason) = failure.diagnostic_reason {
        send_transport_failure_diagnostic(
            &context.transport_callback,
            context.verbose,
            failure.layer,
            failure.stage,
            reason,
        );
    } else {
        send_transport_diagnostic(
            &context.transport_callback,
            context.verbose,
            failure.layer,
            failure.stage,
            failure.diagnostic_status,
        );
    }
    send_control_error(
        &context.control_callback,
        context.session_id,
        context.generation,
        failure.layer,
        failure.stage,
        failure.code,
        &failure.detail,
    );
}

async fn finish_session_phase_stop(
    context: &SessionPhaseContext,
    route: &mut SessionRoute,
    stop: SessionPhaseStop,
) {
    report_session_phase_stop(context, &stop);
    route.disconnect().await;
}

async fn authenticate_session_endpoint(
    context: &SessionPhaseContext,
    endpoint: &SessionEndpoint,
    ssh: &mut SshClientHandle,
    auth_rx: &mut tokio::sync::mpsc::Receiver<LayeredAuthMethod>,
    disconnect_rx: &mut tokio::sync::mpsc::Receiver<()>,
) -> SessionPhaseResult<()> {
    send_transport_diagnostic(
        &context.transport_callback,
        context.verbose,
        endpoint.layer,
        "authentication",
        "started",
    );
    match run_authentication(
        context.session_id,
        context.generation,
        endpoint.layer,
        &endpoint.user,
        &endpoint.private_key_path,
        endpoint.private_key_requires_passphrase,
        ssh,
        &context.auth_callback,
        auth_rx,
        disconnect_rx,
    )
    .await
    {
        AuthenticationOutcome::Authenticated => {
            send_transport_diagnostic(
                &context.transport_callback,
                context.verbose,
                endpoint.layer,
                "authentication",
                "succeeded",
            );
            Ok(())
        }
        AuthenticationOutcome::Cancelled => Err(SessionPhaseStop::Cancelled),
        AuthenticationOutcome::Failed(error) => Err(SessionPhaseStop::Failed(
            SessionPhaseFailure::failed(endpoint.layer, "authentication", "auth", error),
        )),
    }
}

async fn establish_jump_session(
    context: &SessionPhaseContext,
    endpoint: &SessionEndpoint,
    route: &mut SessionRoute,
    receivers: &mut SessionReceivers,
) -> SessionPhaseResult<()> {
    send_transport_diagnostic(
        &context.transport_callback,
        context.verbose,
        ConnectionLayer::Jump,
        "connect",
        "started",
    );
    eprintln!(
        "[LTTY_SSH] session={} layer=jump stage=connect",
        context.session_id
    );
    let (progress_tx, mut progress_rx) = tokio::sync::mpsc::channel(2);
    let config = Arc::new(build_client_config(
        endpoint.server_alive_interval_seconds,
        endpoint.server_alive_count_max,
    ));
    let connect = russh::client::connect(
        config,
        (endpoint.host.as_str(), endpoint.port),
        context.client_handler(endpoint, progress_tx),
    );
    let jump = match wait_for_connect(
        connect,
        endpoint.connect_timeout,
        &mut receivers.disconnect_rx,
        &mut progress_rx,
    )
    .await
    {
        ConnectWaitResult::Connected(handle) => handle,
        ConnectWaitResult::Failed(error) => {
            return Err(SessionPhaseStop::Failed(
                SessionPhaseFailure::connect_failed(
                    ConnectionLayer::Jump,
                    error.to_string(),
                    connect_failure_reason(&error, true),
                ),
            ));
        }
        ConnectWaitResult::TimedOut => {
            return Err(SessionPhaseStop::Failed(SessionPhaseFailure::timed_out(
                ConnectionLayer::Jump,
                "connect",
                "network",
                format!(
                    "connection timed out after {} ms",
                    endpoint.connect_timeout.as_millis()
                ),
            )));
        }
        ConnectWaitResult::Cancelled => return Err(SessionPhaseStop::Cancelled),
    };
    eprintln!(
        "[LTTY_SSH] session={} layer=jump stage=kex_complete",
        context.session_id
    );
    send_transport_diagnostic(
        &context.transport_callback,
        context.verbose,
        ConnectionLayer::Jump,
        "connect",
        "succeeded",
    );
    route.jump = Some(jump);
    authenticate_session_endpoint(
        context,
        endpoint,
        route.jump.as_mut().expect("jump session must exist"),
        &mut receivers.auth_rx,
        &mut receivers.disconnect_rx,
    )
    .await
}

async fn establish_target_session(
    context: &SessionPhaseContext,
    endpoint: &SessionEndpoint,
    route: &mut SessionRoute,
    receivers: &mut SessionReceivers,
) -> SessionPhaseResult<()> {
    send_transport_diagnostic(
        &context.transport_callback,
        context.verbose,
        ConnectionLayer::Target,
        "connect",
        "started",
    );
    eprintln!(
        "[LTTY_SSH] session={} layer=target stage=connect",
        context.session_id
    );
    let (progress_tx, mut progress_rx) = tokio::sync::mpsc::channel(2);
    let config = Arc::new(build_client_config(
        endpoint.server_alive_interval_seconds,
        endpoint.server_alive_count_max,
    ));
    let handler = context.client_handler(endpoint, progress_tx);
    let target_uses_jump = route.jump.is_some();
    let connect_result = if let Some(jump) = route.jump.as_mut() {
        send_transport_diagnostic(
            &context.transport_callback,
            context.verbose,
            ConnectionLayer::Jump,
            "tunnel",
            "started",
        );
        let tunnel = match wait_for_auth_exchange(
            jump.channel_open_direct_tcpip(
                endpoint.host.clone(),
                endpoint.port.into(),
                "127.0.0.1",
                0,
            ),
            endpoint.connect_timeout,
            &mut receivers.disconnect_rx,
        )
        .await
        {
            AuthExchangeResult::Completed(channel) => channel,
            AuthExchangeResult::Failed(error) => {
                return Err(SessionPhaseStop::Failed(SessionPhaseFailure::failed(
                    ConnectionLayer::Jump,
                    "tunnel",
                    "channel",
                    format!("direct-tcpip failed: {error}"),
                )));
            }
            AuthExchangeResult::TimedOut => {
                return Err(SessionPhaseStop::Failed(SessionPhaseFailure::timed_out(
                    ConnectionLayer::Jump,
                    "tunnel",
                    "channel",
                    format!(
                        "direct-tcpip timed out after {} ms",
                        endpoint.connect_timeout.as_millis()
                    ),
                )));
            }
            AuthExchangeResult::Cancelled => return Err(SessionPhaseStop::Cancelled),
        };
        send_transport_diagnostic(
            &context.transport_callback,
            context.verbose,
            ConnectionLayer::Jump,
            "tunnel",
            "succeeded",
        );
        wait_for_connect(
            russh::client::connect_stream(config, tunnel.into_stream(), handler),
            endpoint.connect_timeout,
            &mut receivers.disconnect_rx,
            &mut progress_rx,
        )
        .await
    } else {
        wait_for_connect(
            russh::client::connect(config, (endpoint.host.as_str(), endpoint.port), handler),
            endpoint.connect_timeout,
            &mut receivers.disconnect_rx,
            &mut progress_rx,
        )
        .await
    };
    let target = match connect_result {
        ConnectWaitResult::Connected(handle) => handle,
        ConnectWaitResult::Failed(error) => {
            return Err(SessionPhaseStop::Failed(
                SessionPhaseFailure::connect_failed(
                    ConnectionLayer::Target,
                    error.to_string(),
                    connect_failure_reason(&error, !target_uses_jump),
                ),
            ));
        }
        ConnectWaitResult::TimedOut => {
            return Err(SessionPhaseStop::Failed(SessionPhaseFailure::timed_out(
                ConnectionLayer::Target,
                "connect",
                "network",
                format!(
                    "connection timed out after {} ms",
                    endpoint.connect_timeout.as_millis()
                ),
            )));
        }
        ConnectWaitResult::Cancelled => return Err(SessionPhaseStop::Cancelled),
    };
    eprintln!(
        "[LTTY_SSH] session={} layer=target stage=kex_complete",
        context.session_id
    );
    send_transport_diagnostic(
        &context.transport_callback,
        context.verbose,
        ConnectionLayer::Target,
        "connect",
        "succeeded",
    );
    route.target = Some(target);
    authenticate_session_endpoint(
        context,
        endpoint,
        route.target.as_mut().expect("target session must exist"),
        &mut receivers.auth_rx,
        &mut receivers.disconnect_rx,
    )
    .await
}

async fn open_interactive_shell(
    context: &SessionPhaseContext,
    route: &mut SessionRoute,
    connect_timeout: Duration,
    disconnect_rx: &mut tokio::sync::mpsc::Receiver<()>,
) -> SessionPhaseResult<SshChannel> {
    let ssh = route.target.as_mut().expect("target session must exist");
    send_transport_diagnostic(
        &context.transport_callback,
        context.verbose,
        ConnectionLayer::Target,
        "channel",
        "started",
    );
    let channel =
        match wait_for_auth_exchange(ssh.channel_open_session(), connect_timeout, disconnect_rx)
            .await
        {
            AuthExchangeResult::Completed(value) => value,
            AuthExchangeResult::Failed(error) => {
                return Err(SessionPhaseStop::Failed(SessionPhaseFailure::failed(
                    ConnectionLayer::Target,
                    "channel",
                    "channel",
                    error.to_string(),
                )));
            }
            AuthExchangeResult::TimedOut => {
                return Err(SessionPhaseStop::Failed(SessionPhaseFailure::timed_out(
                    ConnectionLayer::Target,
                    "channel",
                    "channel",
                    format!(
                        "session channel timed out after {} ms",
                        connect_timeout.as_millis()
                    ),
                )));
            }
            AuthExchangeResult::Cancelled => return Err(SessionPhaseStop::Cancelled),
        };
    send_transport_diagnostic(
        &context.transport_callback,
        context.verbose,
        ConnectionLayer::Target,
        "channel",
        "succeeded",
    );

    send_transport_diagnostic(
        &context.transport_callback,
        context.verbose,
        ConnectionLayer::Target,
        "pty",
        "started",
    );
    match wait_for_auth_exchange(
        channel.request_pty(false, "xterm-256color", 80, 24, 0, 0, &[]),
        connect_timeout,
        disconnect_rx,
    )
    .await
    {
        AuthExchangeResult::Completed(()) => send_transport_diagnostic(
            &context.transport_callback,
            context.verbose,
            ConnectionLayer::Target,
            "pty",
            "succeeded",
        ),
        AuthExchangeResult::Failed(error) => {
            return Err(SessionPhaseStop::Failed(SessionPhaseFailure::failed(
                ConnectionLayer::Target,
                "pty",
                "protocol",
                error.to_string(),
            )));
        }
        AuthExchangeResult::TimedOut => {
            return Err(SessionPhaseStop::Failed(SessionPhaseFailure::timed_out(
                ConnectionLayer::Target,
                "pty",
                "protocol",
                format!("request timed out after {} ms", connect_timeout.as_millis()),
            )));
        }
        AuthExchangeResult::Cancelled => return Err(SessionPhaseStop::Cancelled),
    }

    send_transport_diagnostic(
        &context.transport_callback,
        context.verbose,
        ConnectionLayer::Target,
        "shell",
        "started",
    );
    match wait_for_auth_exchange(channel.request_shell(true), connect_timeout, disconnect_rx).await
    {
        AuthExchangeResult::Completed(()) => send_transport_diagnostic(
            &context.transport_callback,
            context.verbose,
            ConnectionLayer::Target,
            "shell",
            "succeeded",
        ),
        AuthExchangeResult::Failed(error) => {
            return Err(SessionPhaseStop::Failed(SessionPhaseFailure::failed(
                ConnectionLayer::Target,
                "shell",
                "protocol",
                error.to_string(),
            )));
        }
        AuthExchangeResult::TimedOut => {
            return Err(SessionPhaseStop::Failed(SessionPhaseFailure::timed_out(
                ConnectionLayer::Target,
                "shell",
                "protocol",
                format!("request timed out after {} ms", connect_timeout.as_millis()),
            )));
        }
        AuthExchangeResult::Cancelled => return Err(SessionPhaseStop::Cancelled),
    }
    Ok(channel)
}

#[derive(Debug, Eq, PartialEq)]
struct SessionClose {
    exit_code: i32,
    layer: String,
    code: String,
    detail: String,
}

impl SessionClose {
    fn normal(exit_code: i32) -> Self {
        Self {
            exit_code,
            layer: String::new(),
            code: String::new(),
            detail: String::new(),
        }
    }

    fn keepalive_timeout(exit_code: i32, layer: ConnectionLayer) -> Self {
        Self {
            exit_code,
            layer: layer.as_str().to_string(),
            code: "keepalive_timeout".to_string(),
            detail: "SSH keepalive timed out. Check the network, then run the SSH command again."
                .to_string(),
        }
    }
}

async fn run_connected_session(
    context: &SessionPhaseContext,
    channel: SshChannel,
    mut route: SessionRoute,
    receivers: SessionReceivers,
    target_endpoint: &SessionEndpoint,
    jump_endpoint: Option<&SessionEndpoint>,
) -> SessionClose {
    eprintln!("[LTTY_SSH] session={} stage=connected", context.session_id);
    send_transport_diagnostic(
        &context.transport_callback,
        context.verbose,
        ConnectionLayer::Target,
        "session",
        "succeeded",
    );
    let _ = send_control(
        &context.control_callback,
        ControlEvent::connected(context.session_id, context.generation),
    );

    let mut ssh = route.target.take().expect("target session must exist");
    let mut jump_ssh = route.jump.take();
    let SessionReceivers {
        write_rx,
        resize_rx,
        mut disconnect_rx,
        auth_rx: _,
        host_key_rx: _,
        mut output_pause_rx,
    } = receivers;
    let (mut channel_read, channel_write) = channel.split();
    let mut channel_writer = tokio::spawn(run_channel_writer(
        channel_write,
        write_rx,
        resize_rx,
        context.session_id,
        context.generation,
        context.control_callback.clone(),
    ));
    let mut channel_writer_active = true;

    let mut pending_output: Vec<u8> = Vec::new();
    let mut output_tick = tokio::time::interval(Duration::from_millis(16));
    output_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    output_tick.tick().await;
    let mut metrics_tick = tokio::time::interval(Duration::from_secs(1));
    metrics_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    metrics_tick.tick().await;
    let mut output_paused = false;
    let mut delivery_metrics = OutputDeliveryMetrics::default();
    let mut exit_code: i32 = -1;
    let mut connection_task_ended = false;
    let mut connection_task_result = None;
    let mut connection_task_layer = ConnectionLayer::Target;
    let mut jump_connection_task_consumed = false;
    let mut local_disconnect_requested = false;

    loop {
        tokio::select! {
          _ = output_tick.tick() => {
            if !pending_output.is_empty() {
              let output = std::mem::take(&mut pending_output);
              let output_len = output.len() as u64;
              let status = try_send_transport_data(&context.transport_callback, output.clone());
              if !delivery_metrics.record_callback_attempt(status, output_len) {
                pending_output = output;
              }
            }
          }
          _ = metrics_tick.tick(), if cfg!(debug_assertions) => {
            let _ = send_control(
                &context.control_callback,
                ControlEvent::output_metrics(
                    context.session_id,
                    context.generation,
                    delivery_metrics.summary(output_paused, false),
                ),
            );
          }
          paused = output_pause_rx.recv() => {
            output_paused = paused.unwrap_or(false);
            eprintln!(
                "[LTTY_SSH] session={} output_paused={}",
                context.session_id, output_paused
            );
          }
          message = channel_read.wait(), if !output_paused && pending_output.len() < 512 * 1024 => {
            match message {
              Some(russh::ChannelMsg::Data { ref data }) |
              Some(russh::ChannelMsg::ExtendedData { ref data, .. }) => {
                delivery_metrics.received_bytes += data.len() as u64;
                let immediate = should_flush_immediately(pending_output.is_empty(), data.len());
                pending_output.extend_from_slice(data);
                if immediate || pending_output.len() >= 64 * 1024 {
                  let output = std::mem::take(&mut pending_output);
                  let output_len = output.len() as u64;
                  let status =
                      try_send_transport_data(&context.transport_callback, output.clone());
                  if !delivery_metrics.record_callback_attempt(status, output_len) {
                    pending_output = output;
                  }
                }
              }
              Some(russh::ChannelMsg::ExitStatus { exit_status }) => {
                exit_code = exit_status as i32;
                break;
              }
              Some(russh::ChannelMsg::Eof) => {}
              Some(russh::ChannelMsg::Close) => break,
              None => {
                connection_task_ended = true;
                break;
              }
              Some(_) => {}
            }
          }
          _ = disconnect_rx.recv() => {
            local_disconnect_requested = true;
            break;
          }
          result = &mut ssh => {
            connection_task_result = Some(result);
            break;
          }
          result = wait_for_jump_connection(&mut jump_ssh) => {
            connection_task_result = Some(result);
            connection_task_layer = ConnectionLayer::Jump;
            jump_connection_task_consumed = true;
            break;
          }
          result = &mut channel_writer, if channel_writer_active => {
            channel_writer_active = false;
            send_control_error(
                &context.control_callback,
                context.session_id,
                context.generation,
                ConnectionLayer::Target,
                "write",
                "internal",
                &channel_writer_exit_message(result),
            );
            break;
          }
        }
    }

    if channel_writer_active {
        channel_writer.abort();
        let _ = channel_writer.await;
    }
    if local_disconnect_requested {
        disconnect_client(&mut ssh).await;
    }

    if !pending_output.is_empty() {
        let final_output = std::mem::take(&mut pending_output);
        let output_len = final_output.len() as u64;
        let mut delivered = false;
        for attempt in 0..FINAL_DELIVERY_RETRY_ATTEMPTS {
            let status = try_send_transport_data(&context.transport_callback, final_output.clone());
            if delivery_metrics.record_callback_attempt(status, output_len) {
                delivered = true;
                break;
            }
            if attempt + 1 < FINAL_DELIVERY_RETRY_ATTEMPTS {
                tokio::time::sleep(FINAL_DELIVERY_RETRY_DELAY).await;
            }
        }
        if !delivered {
            delivery_metrics.record_final_delivery_failure(output_len);
            eprintln!(
                "[LTTY_SSH] session={} final_delivery_failed_bytes={}",
                context.session_id, output_len
            );
        }
    }
    let connection_result = if let Some(result) = connection_task_result {
        Some((connection_task_layer, result))
    } else if connection_task_ended {
        let completed_jump_result = if let Some(jump) = jump_ssh.as_mut() {
            tokio::time::timeout(Duration::ZERO, jump).await.ok()
        } else {
            None
        };
        if let Some(result) = completed_jump_result {
            jump_connection_task_consumed = true;
            Some((ConnectionLayer::Jump, result))
        } else {
            Some((ConnectionLayer::Target, ssh.await))
        }
    } else {
        None
    };
    if !jump_connection_task_consumed {
        if let Some(jump) = jump_ssh.as_mut() {
            disconnect_client(jump).await;
        }
    }
    let keepalive_timeout_layer = match connection_result {
        Some((layer, result)) => match result {
            Err(russh::Error::KeepaliveTimeout) => {
                let endpoint = if layer == ConnectionLayer::Jump {
                    jump_endpoint.unwrap_or(target_endpoint)
                } else {
                    target_endpoint
                };
                eprintln!(
                    "[LTTY_SSH] session={} layer={} stage=keepalive_timeout intervalSeconds={} max={}",
                    context.session_id,
                    layer.as_str(),
                    endpoint.server_alive_interval_seconds,
                    endpoint.server_alive_count_max
                );
                send_transport_diagnostic(
                    &context.transport_callback,
                    context.verbose,
                    layer,
                    "keepalive",
                    "timed_out",
                );
                Some(layer)
            }
            Err(error) => {
                eprintln!(
                    "[LTTY_SSH] session={} stage=connection_task_failed",
                    context.session_id
                );
                let _ = error;
                send_transport_diagnostic(
                    &context.transport_callback,
                    context.verbose,
                    layer,
                    "session",
                    "failed",
                );
                None
            }
            Ok(()) => None,
        },
        None => None,
    };
    let _ = send_control(
        &context.control_callback,
        ControlEvent::output_metrics(
            context.session_id,
            context.generation,
            delivery_metrics.summary(output_paused, true),
        ),
    );
    send_transport_diagnostic(
        &context.transport_callback,
        context.verbose,
        ConnectionLayer::Target,
        "session",
        if local_disconnect_requested {
            "cancelled"
        } else {
            "closed"
        },
    );
    match keepalive_timeout_layer {
        Some(layer) => SessionClose::keepalive_timeout(exit_code, layer),
        None => SessionClose::normal(exit_code),
    }
}
const MOSH_BOOTSTRAP_COMMAND_PREFIX: &str =
    "sh -c '[ -n \"$SSH_CONNECTION\" ] && printf \"\\nMOSH SSH_CONNECTION %s\\n\" \"$SSH_CONNECTION\"; exec ";
const MOSH_DEFAULT_SERVER: &str = "mosh-server";
const MOSH_SERVER_ARGUMENTS: &str = " new -s -c 256";
const MOSH_BOOTSTRAP_MAX_BYTES: usize = 4 * 1024;
const MOSH_SERVER_PATH_MAX_BYTES: usize = 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct MoshUdpPortRange {
    start: u16,
    end: u16,
}

impl MoshUdpPortRange {
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

fn mosh_udp_port_range(
    start: u32,
    end: u32,
) -> std::result::Result<Option<MoshUdpPortRange>, &'static str> {
    if start == 0 && end == 0 {
        return Ok(None);
    }
    if start == 0 || end == 0 || start > u16::MAX as u32 || end > u16::MAX as u32 {
        return Err("Mosh UDP port bounds must both be zero or between 1 and 65535");
    }
    if start > end {
        return Err("Mosh UDP port range start must not exceed its end");
    }
    Ok(Some(MoshUdpPortRange {
        start: start as u16,
        end: end as u16,
    }))
}

fn mosh_prediction_mode(value: &str) -> std::result::Result<MoshPredictionMode, &'static str> {
    match value {
        "adaptive" => Ok(MoshPredictionMode::Adaptive),
        "always" => Ok(MoshPredictionMode::Always),
        "never" => Ok(MoshPredictionMode::Never),
        _ => Err("Mosh prediction mode must be adaptive, always or never"),
    }
}

fn mosh_server_path(value: &str) -> std::result::Result<Option<&str>, &'static str> {
    if value.is_empty() {
        return Ok(None);
    }
    if value.len() > MOSH_SERVER_PATH_MAX_BYTES || !value.starts_with('/') || value.ends_with('/') {
        return Err("Mosh server path must be an absolute POSIX path of at most 1024 bytes");
    }
    if value.split('/').skip(1).any(|segment| {
        segment.is_empty()
            || segment == "."
            || segment == ".."
            || !segment.bytes().all(|byte| {
                byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'+' | b'-')
            })
    }) {
        return Err("Mosh server path contains an empty, relative or unsupported path segment");
    }
    Ok(Some(value))
}

fn mosh_bootstrap_command(
    server_path: Option<&str>,
    port_range: Option<MoshUdpPortRange>,
) -> String {
    let executable = server_path.unwrap_or(MOSH_DEFAULT_SERVER);
    let mut command = format!("{MOSH_BOOTSTRAP_COMMAND_PREFIX}{executable}{MOSH_SERVER_ARGUMENTS}");
    if let Some(port_range) = port_range {
        command.push_str(" -p ");
        command.push_str(&port_range.argument());
    }
    command.push('\'');
    command
}

fn append_mosh_bootstrap_output(
    output: &mut Vec<u8>,
    data: &[u8],
) -> std::result::Result<(), &'static str> {
    if output.len().saturating_add(data.len()) > MOSH_BOOTSTRAP_MAX_BYTES {
        return Err("mosh-server bootstrap output exceeded 4 KiB");
    }
    output.extend_from_slice(data);
    Ok(())
}

fn mosh_bootstrap_exit_error(exit_status: u32) -> Option<&'static str> {
    match exit_status {
        0 => None,
        126 => Some("configured mosh-server path is not executable"),
        127 => Some("configured mosh-server path does not exist"),
        _ => Some("mosh-server exited before creating a Session"),
    }
}

fn validate_mosh_server_port(
    server_port: u16,
    port_range: Option<MoshUdpPortRange>,
) -> std::result::Result<(), &'static str> {
    if port_range.is_some_and(|requested| !requested.contains(server_port)) {
        return Err("mosh-server returned a UDP port outside the requested range");
    }
    Ok(())
}

fn mosh_server_ipv4(output: &[u8]) -> std::result::Result<Ipv4Addr, &'static str> {
    let mut address = None;
    for raw_line in output.split_inclusive(|byte| *byte == b'\n') {
        let line = raw_line.strip_suffix(b"\n").unwrap_or(raw_line);
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        let Ok(text) = std::str::from_utf8(line) else {
            continue;
        };
        let fields: Vec<&str> = text.split(' ').collect();
        if fields.first() != Some(&"MOSH") || fields.get(1) != Some(&"SSH_CONNECTION") {
            continue;
        }
        if fields.len() != 6 || address.is_some() {
            return Err("invalid or ambiguous MOSH SSH_CONNECTION record");
        }
        address = Some(
            fields[4]
                .parse::<Ipv4Addr>()
                .map_err(|_| "Mosh bootstrap requires an IPv4 SSH server address")?,
        );
    }
    address.ok_or("Mosh bootstrap did not report the SSH server address")
}

async fn start_mosh_server(
    context: &SessionPhaseContext,
    route: &mut SessionRoute,
    connect_timeout: Duration,
    server_path: Option<&str>,
    port_range: Option<MoshUdpPortRange>,
    disconnect_rx: &mut tokio::sync::mpsc::Receiver<()>,
) -> SessionPhaseResult<MoshBootstrap> {
    let ssh = route.target.as_mut().expect("target session must exist");
    send_transport_diagnostic(
        &context.transport_callback,
        true,
        ConnectionLayer::Target,
        "mosh_bootstrap",
        "started",
    );
    let mut channel =
        match wait_for_auth_exchange(ssh.channel_open_session(), connect_timeout, disconnect_rx)
            .await
        {
            AuthExchangeResult::Completed(channel) => channel,
            AuthExchangeResult::Failed(error) => {
                return Err(SessionPhaseStop::Failed(SessionPhaseFailure::failed(
                    ConnectionLayer::Target,
                    "mosh_bootstrap",
                    "channel",
                    format!("Mosh bootstrap channel failed: {error}"),
                )));
            }
            AuthExchangeResult::TimedOut => {
                return Err(SessionPhaseStop::Failed(SessionPhaseFailure::timed_out(
                    ConnectionLayer::Target,
                    "mosh_bootstrap",
                    "network",
                    "Mosh bootstrap channel timed out".to_string(),
                )));
            }
            AuthExchangeResult::Cancelled => return Err(SessionPhaseStop::Cancelled),
        };
    let bootstrap_command = mosh_bootstrap_command(server_path, port_range);
    match wait_for_auth_exchange(
        channel.exec(true, bootstrap_command),
        connect_timeout,
        disconnect_rx,
    )
    .await
    {
        AuthExchangeResult::Completed(()) => {}
        AuthExchangeResult::Failed(error) => {
            return Err(SessionPhaseStop::Failed(SessionPhaseFailure::failed(
                ConnectionLayer::Target,
                "mosh_bootstrap",
                "server",
                format!("mosh-server could not start: {error}"),
            )));
        }
        AuthExchangeResult::TimedOut => {
            return Err(SessionPhaseStop::Failed(SessionPhaseFailure::timed_out(
                ConnectionLayer::Target,
                "mosh_bootstrap",
                "network",
                "mosh-server start timed out".to_string(),
            )));
        }
        AuthExchangeResult::Cancelled => return Err(SessionPhaseStop::Cancelled),
    }

    let mut output = Zeroizing::new(Vec::new());
    let mut exit_status = None;
    let deadline = tokio::time::sleep(connect_timeout);
    tokio::pin!(deadline);
    loop {
        tokio::select! {
            message = channel.wait() => match message {
                Some(russh::ChannelMsg::Data { data }) |
                Some(russh::ChannelMsg::ExtendedData { data, .. }) => {
                    if let Err(detail) = append_mosh_bootstrap_output(&mut output, &data) {
                        return Err(SessionPhaseStop::Failed(SessionPhaseFailure::failed(
                            ConnectionLayer::Target,
                            "mosh_bootstrap",
                            "protocol",
                            detail.to_string(),
                        )));
                    }
                }
                Some(russh::ChannelMsg::ExitStatus { exit_status: status }) => {
                    exit_status = Some(status);
                }
                Some(russh::ChannelMsg::Close) | None => break,
                Some(_) => {}
            },
            _ = disconnect_rx.recv() => return Err(SessionPhaseStop::Cancelled),
            _ = &mut deadline => {
                return Err(SessionPhaseStop::Failed(SessionPhaseFailure::timed_out(
                    ConnectionLayer::Target,
                    "mosh_bootstrap",
                    "network",
                    "mosh-server bootstrap timed out".to_string(),
                )));
            }
        }
    }
    if let Some(detail) = exit_status.and_then(mosh_bootstrap_exit_error) {
        return Err(SessionPhaseStop::Failed(SessionPhaseFailure::failed(
            ConnectionLayer::Target,
            "mosh_bootstrap",
            "server",
            detail.to_string(),
        )));
    }
    let server_address = mosh_server_ipv4(output.as_slice()).map_err(|detail| {
        SessionPhaseStop::Failed(SessionPhaseFailure::failed(
            ConnectionLayer::Target,
            "mosh_bootstrap",
            "protocol",
            detail.to_string(),
        ))
    })?;
    let bootstrap = MoshBootstrap::parse(server_address, output.as_slice()).map_err(|error| {
        SessionPhaseStop::Failed(SessionPhaseFailure::failed(
            ConnectionLayer::Target,
            "mosh_bootstrap",
            "protocol",
            format!("invalid mosh-server bootstrap: {error}"),
        ))
    })?;
    validate_mosh_server_port(bootstrap.server_addr().port(), port_range).map_err(|detail| {
        SessionPhaseStop::Failed(SessionPhaseFailure::failed(
            ConnectionLayer::Target,
            "mosh_bootstrap",
            "protocol",
            detail.to_string(),
        ))
    })?;
    send_transport_diagnostic(
        &context.transport_callback,
        true,
        ConnectionLayer::Target,
        "mosh_bootstrap",
        "succeeded",
    );
    Ok(bootstrap)
}

fn mosh_session_error_code(error: &mosh_client::SessionError) -> &'static str {
    match error {
        mosh_client::SessionError::Io(_) => "network",
        mosh_client::SessionError::InvalidTerminalSize => "terminal_size",
        mosh_client::SessionError::ConnectionTimeout => "connection_timeout",
        mosh_client::SessionError::Protocol => "protocol",
        mosh_client::SessionError::ResourceLimit => "resource_limit",
        mosh_client::SessionError::StateExhausted => "state_exhausted",
        mosh_client::SessionError::InternalState => "internal",
        _ => "internal",
    }
}

fn mosh_session_close_reason(exit: &MoshSessionExit) -> Option<&'static str> {
    match exit {
        MoshSessionExit::LocalClosed => Some("local_closed"),
        MoshSessionExit::RemoteClosed => Some("remote_closed"),
        _ => None,
    }
}

fn mosh_session_exit_failure(exit: &MoshSessionExit) -> Option<(&'static str, &'static str)> {
    match exit {
        MoshSessionExit::LocalClosed | MoshSessionExit::RemoteClosed => None,
        MoshSessionExit::Cancelled => Some((
            "cancelled",
            "Mosh protocol task stopped without a graceful close",
        )),
        MoshSessionExit::OwnerDropped => {
            Some(("internal", "Mosh protocol session owner was dropped"))
        }
        _ => Some((
            "internal",
            "Mosh protocol task returned an unknown exit reason",
        )),
    }
}

fn record_mosh_task_result(
    result: std::result::Result<
        std::result::Result<MoshSessionExit, mosh_client::SessionError>,
        tokio::task::JoinError,
    >,
    close_code: &mut String,
    close_detail: &mut String,
    close_reason: &mut String,
) {
    match result {
        Ok(Ok(exit)) => {
            if let Some(reason) = mosh_session_close_reason(&exit) {
                if close_reason.is_empty() {
                    *close_reason = reason.to_string();
                }
            } else if let Some((code, detail)) = mosh_session_exit_failure(&exit) {
                *close_code = code.to_string();
                *close_detail = detail.to_string();
            }
        }
        Ok(Err(error)) => {
            *close_code = mosh_session_error_code(&error).to_string();
            *close_detail = error.to_string();
        }
        Err(_) => {
            *close_code = "internal".to_string();
            *close_detail = "Mosh protocol task failed".to_string();
        }
    }
}

async fn run_mosh_protocol(
    context: &SessionPhaseContext,
    bootstrap: MoshBootstrap,
    prediction_mode: MoshPredictionMode,
    columns: u32,
    rows: u32,
    mut receivers: SessionReceivers,
) {
    send_transport_diagnostic(
        &context.transport_callback,
        true,
        ConnectionLayer::Target,
        "mosh_udp",
        "started",
    );
    let (mut session, task) = match MoshProtocolSession::connect_with_prediction_mode(
        bootstrap,
        columns,
        rows,
        prediction_mode,
    )
    .await
    {
        Ok(value) => value,
        Err(error) => {
            send_control_error(
                &context.control_callback,
                context.session_id,
                context.generation,
                ConnectionLayer::Target,
                "mosh_udp",
                mosh_session_error_code(&error),
                &error.to_string(),
            );
            let _ = send_transport_close(
                &context.transport_callback,
                -1,
                ConnectionLayer::Target.as_str().to_string(),
                mosh_session_error_code(&error).to_string(),
                error.to_string(),
            );
            return;
        }
    };
    let mut reachability = session.subscribe_reachability();
    let initial_reachability = reachability.current();
    let mut task = tokio::spawn(task.run());
    let mut state_tick = tokio::time::interval(Duration::from_millis(100));
    state_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut connected_reported = false;
    let mut output_paused = false;
    let mut close_code = String::new();
    let mut close_detail = String::new();
    let mut close_reason = String::new();
    let mut task_finished = false;
    let mut graceful_close_requested = false;
    let mut reachability_open = true;

    if !send_mosh_reachability(&context.transport_callback, initial_reachability) {
        close_code = "callback".to_string();
        close_detail = "Mosh reachability callback failed".to_string();
    }

    while close_code.is_empty() {
        tokio::select! {
            _ = state_tick.tick() => {
                if !connected_reported && session.state() == MoshProtocolState::Active {
                    connected_reported = true;
                    let _ = send_control(
                        &context.control_callback,
                        ControlEvent::connected(context.session_id, context.generation),
                    );
                    send_transport_diagnostic(
                        &context.transport_callback,
                        true,
                        ConnectionLayer::Target,
                        "mosh_udp",
                        "succeeded",
                    );
                }
            }
            output = session.next_output(), if !output_paused => match output {
                Some(output) => {
                    if !send_transport_data_blocking(&context.transport_callback, output) {
                        close_code = "callback".to_string();
                        close_detail = "Mosh terminal output callback failed".to_string();
                        break;
                    }
                }
                None => {
                    task_finished = true;
                    record_mosh_task_result(
                        (&mut task).await,
                        &mut close_code,
                        &mut close_detail,
                        &mut close_reason,
                    );
                    break;
                }
            },
            observation = reachability.changed(), if reachability_open => match observation {
                Some(observation) => {
                    if !send_mosh_reachability(&context.transport_callback, observation) {
                        close_code = "callback".to_string();
                        close_detail = "Mosh reachability callback failed".to_string();
                        break;
                    }
                }
                None => reachability_open = false,
            },
            input = receivers.write_rx.recv(), if !graceful_close_requested => match input {
                Some(input) => {
                    if let Err(error) = session.send_input(input).await {
                        close_code = "input".to_string();
                        close_detail = error.to_string();
                        break;
                    }
                }
                None => {
                    close_reason = "write_channel_closed".to_string();
                    break;
                }
            },
            size = receivers.resize_rx.recv(), if !graceful_close_requested => match size {
                Some((columns, rows)) => {
                    if let Err(error) = session.resize(columns, rows).await {
                        close_code = "terminal_size".to_string();
                        close_detail = error.to_string();
                        break;
                    }
                }
                None => {
                    close_reason = "resize_channel_closed".to_string();
                    break;
                }
            },
            paused = receivers.output_pause_rx.recv(), if !graceful_close_requested => {
                let was_paused = output_paused;
                output_paused = paused.unwrap_or(false);
                if was_paused && !output_paused {
                    if let Err(error) = session.request_repaint().await {
                        close_code = "repaint".to_string();
                        close_detail = error.to_string();
                        break;
                    }
                }
            },
            _ = receivers.disconnect_rx.recv(), if !graceful_close_requested => {
                while let Ok(input) = receivers.write_rx.try_recv() {
                    if let Err(error) = session.send_input(input).await {
                        close_code = "input".to_string();
                        close_detail = error.to_string();
                        break;
                    }
                }
                if !close_code.is_empty() {
                    break;
                }
                output_paused = false;
                graceful_close_requested = true;
                close_reason = "disconnect_requested".to_string();
                session.close();
            },
            result = &mut task => {
                task_finished = true;
                record_mosh_task_result(
                    result,
                    &mut close_code,
                    &mut close_detail,
                    &mut close_reason,
                );
                break;
            }
        }
    }
    if !task_finished {
        session.cancel();
        let _ = tokio::time::timeout(Duration::from_secs(1), &mut task).await;
    } else {
        while let Some(output) = session.next_output().await {
            if !send_transport_data_blocking(&context.transport_callback, output) {
                close_code = "callback".to_string();
                close_detail = "Mosh terminal output callback failed".to_string();
                break;
            }
        }
    }
    if !close_code.is_empty() {
        send_control_error(
            &context.control_callback,
            context.session_id,
            context.generation,
            ConnectionLayer::Target,
            "mosh_udp",
            &close_code,
            &close_detail,
        );
    }
    send_transport_diagnostic(
        &context.transport_callback,
        true,
        ConnectionLayer::Target,
        "mosh_udp",
        if close_code.is_empty() {
            "closed"
        } else {
            "failed"
        },
    );
    let transport_exit_code = if close_code.is_empty() { 0 } else { -1 };
    let transport_detail = if close_code.is_empty() {
        close_reason
    } else {
        close_detail
    };
    let _ = send_transport_close(
        &context.transport_callback,
        transport_exit_code,
        ConnectionLayer::Target.as_str().to_string(),
        close_code,
        transport_detail,
    );
}

#[allow(clippy::too_many_arguments)]
async fn run_mosh_session(
    session_id: u32,
    generation: u32,
    host: String,
    port: u16,
    user: String,
    private_key_path: String,
    private_key_requires_passphrase: bool,
    known_hosts_path: String,
    connect_timeout: Duration,
    server_alive_interval_seconds: u32,
    server_alive_count_max: u32,
    server_path: Option<String>,
    udp_port_range: Option<MoshUdpPortRange>,
    prediction_mode: MoshPredictionMode,
    columns: u32,
    rows: u32,
    transport_callback: JsTransportCallback,
    control_callback: JsControlCallback,
    auth_callback: JsAuthCallback,
    mut receivers: SessionReceivers,
) {
    let _cleanup_guard = MoshSessionCleanupGuard(session_id);
    let host_key_rx = Arc::new(tokio::sync::Mutex::new(
        receivers
            .host_key_rx
            .take()
            .expect("host key receiver must exist"),
    ));
    let context = SessionPhaseContext {
        session_id,
        generation,
        verbose: false,
        known_hosts_path: PathBuf::from(known_hosts_path),
        host_key_rx,
        transport_callback,
        control_callback,
        auth_callback,
    };
    let target_endpoint = SessionEndpoint {
        layer: ConnectionLayer::Target,
        host,
        port,
        user,
        private_key_path,
        private_key_requires_passphrase,
        connect_timeout,
        server_alive_interval_seconds,
        server_alive_count_max,
    };
    let mut route = SessionRoute::default();
    if let Err(stop) =
        establish_target_session(&context, &target_endpoint, &mut route, &mut receivers).await
    {
        finish_session_phase_stop(&context, &mut route, stop).await;
        return;
    }
    let bootstrap = match start_mosh_server(
        &context,
        &mut route,
        target_endpoint.connect_timeout,
        server_path.as_deref(),
        udp_port_range,
        &mut receivers.disconnect_rx,
    )
    .await
    {
        Ok(bootstrap) => bootstrap,
        Err(stop) => {
            finish_session_phase_stop(&context, &mut route, stop).await;
            return;
        }
    };
    route.disconnect().await;
    run_mosh_protocol(
        &context,
        bootstrap,
        prediction_mode,
        columns,
        rows,
        receivers,
    )
    .await;
}

#[allow(clippy::too_many_arguments)]
async fn run_session(
    session_id: u32,
    generation: u32,
    host: String,
    port: u16,
    user: String,
    private_key_path: String,
    private_key_requires_passphrase: bool,
    jump_host: String,
    jump_port: u16,
    jump_user: String,
    jump_private_key_path: String,
    jump_private_key_requires_passphrase: bool,
    jump_connect_timeout: Duration,
    jump_server_alive_interval_seconds: u32,
    jump_server_alive_count_max: u32,
    known_hosts_path: String,
    connect_timeout: Duration,
    server_alive_interval_seconds: u32,
    server_alive_count_max: u32,
    verbose: bool,
    transport_callback: JsTransportCallback,
    control_callback: JsControlCallback,
    auth_callback: JsAuthCallback,
    mut receivers: SessionReceivers,
) {
    let _cleanup_guard = SessionCleanupGuard(session_id);
    let host_key_rx = Arc::new(tokio::sync::Mutex::new(
        receivers
            .host_key_rx
            .take()
            .expect("host key receiver must exist"),
    ));
    let context = SessionPhaseContext {
        session_id,
        generation,
        verbose,
        known_hosts_path: PathBuf::from(known_hosts_path),
        host_key_rx,
        transport_callback,
        control_callback,
        auth_callback,
    };
    let target_endpoint = SessionEndpoint {
        layer: ConnectionLayer::Target,
        host,
        port,
        user,
        private_key_path,
        private_key_requires_passphrase,
        connect_timeout,
        server_alive_interval_seconds,
        server_alive_count_max,
    };
    let jump_endpoint = (!jump_host.is_empty()).then_some(SessionEndpoint {
        layer: ConnectionLayer::Jump,
        host: jump_host,
        port: jump_port,
        user: jump_user,
        private_key_path: jump_private_key_path,
        private_key_requires_passphrase: jump_private_key_requires_passphrase,
        connect_timeout: jump_connect_timeout,
        server_alive_interval_seconds: jump_server_alive_interval_seconds,
        server_alive_count_max: jump_server_alive_count_max,
    });
    let mut route = SessionRoute::default();

    if let Some(jump) = jump_endpoint.as_ref() {
        if let Err(stop) = establish_jump_session(&context, jump, &mut route, &mut receivers).await
        {
            finish_session_phase_stop(&context, &mut route, stop).await;
            return;
        }
    }
    if let Err(stop) =
        establish_target_session(&context, &target_endpoint, &mut route, &mut receivers).await
    {
        finish_session_phase_stop(&context, &mut route, stop).await;
        return;
    }
    let channel = match open_interactive_shell(
        &context,
        &mut route,
        target_endpoint.connect_timeout,
        &mut receivers.disconnect_rx,
    )
    .await
    {
        Ok(channel) => channel,
        Err(stop) => {
            finish_session_phase_stop(&context, &mut route, stop).await;
            return;
        }
    };
    let close = run_connected_session(
        &context,
        channel,
        route,
        receivers,
        &target_endpoint,
        jump_endpoint.as_ref(),
    )
    .await;
    let _ = send_transport_close(
        &context.transport_callback,
        close.exit_code,
        close.layer,
        close.code,
        close.detail,
    );
    eprintln!("[LTTY_SSH] session={} stage=closed", session_id);
}

#[allow(clippy::too_many_arguments)]
async fn run_file_transfer(
    transfer_id: u32,
    generation: u32,
    pane_id: String,
    direction: transfer::Direction,
    host: String,
    port: u16,
    user: String,
    private_key_path: String,
    private_key_requires_passphrase: bool,
    known_hosts_path: String,
    remote_path: String,
    local_file: std::fs::File,
    local_temp_path: String,
    connect_timeout: Duration,
    server_alive_interval_seconds: u32,
    server_alive_count_max: u32,
    control_callback: JsControlCallback,
    auth_callback: JsAuthCallback,
    transfer_callback: JsFileTransferCallback,
    mut disconnect_rx: tokio::sync::mpsc::Receiver<()>,
    mut auth_rx: tokio::sync::mpsc::Receiver<LayeredAuthMethod>,
    host_key_rx: tokio::sync::mpsc::Receiver<HostKeyDecision>,
) {
    let _cleanup_guard = FileTransferCleanupGuard(transfer_id);
    let mut local_temp_cleanup = LocalTempCleanup(if direction == transfer::Direction::Get {
        Some(PathBuf::from(local_temp_path))
    } else {
        None
    });
    let _ = send_file_transfer_event(
        &transfer_callback,
        FileTransferEvent::stage(transfer_id, &pane_id, generation, "preparing"),
        false,
    );
    let config = Arc::new(build_client_config(
        server_alive_interval_seconds,
        server_alive_count_max,
    ));
    let (connect_progress_tx, mut connect_progress_rx) = tokio::sync::mpsc::channel(2);
    let handler = ClientHandler {
        session_id: transfer_id,
        generation,
        layer: ConnectionLayer::Target,
        host: host.clone(),
        port,
        known_hosts_path: PathBuf::from(known_hosts_path),
        host_key_rx: Arc::new(tokio::sync::Mutex::new(host_key_rx)),
        connect_progress_tx,
        transport_callback: None,
        verbose: false,
        control_callback: control_callback.clone(),
        auth_callback: auth_callback.clone(),
    };
    let connect = russh::client::connect(config, (host.as_str(), port), handler);
    let mut ssh = match wait_for_connect(
        connect,
        connect_timeout,
        &mut disconnect_rx,
        &mut connect_progress_rx,
    )
    .await
    {
        ConnectWaitResult::Connected(handle) => handle,
        ConnectWaitResult::Failed(error) => {
            let _ = send_file_transfer_event(
                &transfer_callback,
                FileTransferEvent::failed(
                    transfer_id,
                    &pane_id,
                    generation,
                    "NETWORK",
                    &format!("connection failed: {error}"),
                ),
                true,
            );
            return;
        }
        ConnectWaitResult::TimedOut => {
            let _ = send_file_transfer_event(
                &transfer_callback,
                FileTransferEvent::failed(
                    transfer_id,
                    &pane_id,
                    generation,
                    "NETWORK_TIMEOUT",
                    "connection timed out",
                ),
                true,
            );
            return;
        }
        ConnectWaitResult::Cancelled => {
            let _ = send_file_transfer_event(
                &transfer_callback,
                FileTransferEvent::stage(transfer_id, &pane_id, generation, "cancelled"),
                true,
            );
            return;
        }
    };

    match run_authentication(
        transfer_id,
        generation,
        ConnectionLayer::Target,
        &user,
        &private_key_path,
        private_key_requires_passphrase,
        &mut ssh,
        &auth_callback,
        &mut auth_rx,
        &mut disconnect_rx,
    )
    .await
    {
        AuthenticationOutcome::Authenticated => {}
        AuthenticationOutcome::Cancelled => {
            let _ = ssh
                .disconnect(russh::Disconnect::ByApplication, "", "")
                .await;
            let _ = send_file_transfer_event(
                &transfer_callback,
                FileTransferEvent::stage(transfer_id, &pane_id, generation, "cancelled"),
                true,
            );
            return;
        }
        AuthenticationOutcome::Failed(error) => {
            let _ = send_file_transfer_event(
                &transfer_callback,
                FileTransferEvent::failed(transfer_id, &pane_id, generation, "AUTH", &error),
                true,
            );
            return;
        }
    }

    let channel = match transfer::bounded_operation(
        ssh.channel_open_session(),
        &mut disconnect_rx,
        "SFTP_UNAVAILABLE",
        "SFTP channel open failed",
    )
    .await
    {
        Ok(channel) => channel,
        Err(failure) => {
            send_file_transfer_failure(
                &transfer_callback,
                transfer_id,
                &pane_id,
                generation,
                failure,
            );
            return;
        }
    };
    if let Err(failure) = transfer::bounded_operation(
        channel.request_subsystem(true, "sftp"),
        &mut disconnect_rx,
        "SFTP_UNAVAILABLE",
        "SFTP subsystem request failed",
    )
    .await
    {
        send_file_transfer_failure(
            &transfer_callback,
            transfer_id,
            &pane_id,
            generation,
            failure,
        );
        return;
    }
    let sftp = match transfer::bounded_operation(
        russh_sftp::client::SftpSession::new(channel.into_stream()),
        &mut disconnect_rx,
        "SFTP_UNAVAILABLE",
        "SFTP initialization failed",
    )
    .await
    {
        Ok(sftp) => sftp,
        Err(failure) => {
            send_file_transfer_failure(
                &transfer_callback,
                transfer_id,
                &pane_id,
                generation,
                failure,
            );
            return;
        }
    };
    let _ = send_file_transfer_event(
        &transfer_callback,
        FileTransferEvent::stage(transfer_id, &pane_id, generation, "transferring"),
        false,
    );
    let transfer_wait = wait_for_file_transfer(
        transfer::execute(
            &sftp,
            direction,
            &remote_path,
            local_file,
            transfer_id,
            &mut disconnect_rx,
            |update| {
                let event = match update {
                    transfer::TransferUpdate::Progress { transferred, total } => {
                        FileTransferEvent::progress(
                            transfer_id,
                            &pane_id,
                            generation,
                            transferred,
                            total,
                        )
                    }
                    transfer::TransferUpdate::Finalizing { transferred, total } => {
                        FileTransferEvent::finalizing(
                            transfer_id,
                            &pane_id,
                            generation,
                            transferred,
                            total,
                        )
                    }
                };
                let _ = send_file_transfer_event(&transfer_callback, event, false);
            },
        ),
        &mut ssh,
    )
    .await;
    let result = match transfer_wait {
        FileTransferWaitResult::Completed(result) => {
            let _ = transfer::bounded_operation(
                sftp.close(),
                &mut disconnect_rx,
                "SFTP_CLOSE",
                "SFTP session close failed",
            )
            .await;
            let _ = transfer::bounded_operation(
                ssh.disconnect(russh::Disconnect::ByApplication, "", ""),
                &mut disconnect_rx,
                "NETWORK",
                "SSH transfer session disconnect failed",
            )
            .await;
            result
        }
        FileTransferWaitResult::ConnectionEnded(result) => {
            let (code, detail) = match result {
                Err(russh::Error::KeepaliveTimeout) => {
                    eprintln!(
                        "[LTTY_SSH] transfer={} stage=keepalive_timeout intervalSeconds={} max={}",
                        transfer_id, server_alive_interval_seconds, server_alive_count_max
                    );
                    (
                        "KEEPALIVE_TIMEOUT",
                        format!(
                        "SSH keepalive timed out after interval {server_alive_interval_seconds}s and count {server_alive_count_max}"
                    ),
                    )
                }
                Err(error) => ("NETWORK", format!("SSH transfer connection ended: {error}")),
                Ok(()) => (
                    "NETWORK",
                    "SSH transfer connection ended before the file transfer completed".to_string(),
                ),
            };
            Err(transfer::TransferFailure::Failed { code, detail })
        }
    };
    match result {
        Ok((bytes, total_bytes)) => {
            let delivered = send_file_transfer_event(
                &transfer_callback,
                FileTransferEvent::completed(transfer_id, &pane_id, generation, bytes, total_bytes),
                true,
            );
            if delivered {
                local_temp_cleanup.keep();
            }
        }
        Err(failure) => send_file_transfer_failure(
            &transfer_callback,
            transfer_id,
            &pane_id,
            generation,
            failure,
        ),
    }
}

enum FileTransferWaitResult<T> {
    Completed(T),
    ConnectionEnded(std::result::Result<(), russh::Error>),
}

async fn wait_for_file_transfer<F, D, T>(transfer: F, connection: D) -> FileTransferWaitResult<T>
where
    F: Future<Output = T>,
    D: Future<Output = std::result::Result<(), russh::Error>>,
{
    tokio::select! {
        biased;
        result = transfer => FileTransferWaitResult::Completed(result),
        result = connection => FileTransferWaitResult::ConnectionEnded(result),
    }
}

fn send_file_transfer_failure(
    callback: &JsFileTransferCallback,
    transfer_id: u32,
    pane_id: &str,
    generation: u32,
    failure: transfer::TransferFailure,
) {
    let event = match failure {
        transfer::TransferFailure::Cancelled => {
            FileTransferEvent::stage(transfer_id, pane_id, generation, "cancelled")
        }
        transfer::TransferFailure::Failed { code, detail } => {
            FileTransferEvent::failed(transfer_id, pane_id, generation, code, &detail)
        }
    };
    let _ = send_file_transfer_event(callback, event, true);
}

#[napi]
#[allow(clippy::too_many_arguments)]
pub fn ssh_connect(
    host: String,
    port: u32,
    user: String,
    private_key_path: String,
    private_key_requires_passphrase: bool,
    jump_host: String,
    jump_port: u32,
    jump_user: String,
    jump_private_key_path: String,
    jump_private_key_requires_passphrase: bool,
    jump_connect_timeout_ms: u32,
    jump_server_alive_interval_seconds: u32,
    jump_server_alive_count_max: u32,
    known_hosts_path: String,
    connect_timeout_ms: u32,
    server_alive_interval_seconds: u32,
    server_alive_count_max: u32,
    verbose: bool,
    generation: u32,
    on_transport: Function<'_, TransportEvent, ()>,
    on_control: Function<'_, ControlEvent, ()>,
    on_auth: Function<'_, AuthEvent, ()>,
) -> Result<String> {
    if host.trim().is_empty() {
        return Err(napi_error("host must not be empty"));
    }
    if port == 0 || port > u16::MAX as u32 {
        return Err(napi_error("port must be between 1 and 65535"));
    }
    if user.trim().is_empty() {
        return Err(napi_error("user must not be empty"));
    }
    if !jump_host.trim().is_empty() {
        if jump_port == 0 || jump_port > u16::MAX as u32 {
            return Err(napi_error("jump port must be between 1 and 65535"));
        }
        if jump_user.trim().is_empty() {
            return Err(napi_error("jump user must not be empty"));
        }
        if jump_connect_timeout_ms == 0 {
            return Err(napi_error("jump connect timeout must be positive"));
        }
        validate_keepalive(
            jump_server_alive_interval_seconds,
            jump_server_alive_count_max,
            "jump",
        )?;
        if host == jump_host && port == jump_port {
            return Err(napi_error("jump host must differ from target host"));
        }
    }
    if known_hosts_path.trim().is_empty() {
        return Err(napi_error("known_hosts path must not be empty"));
    }
    if connect_timeout_ms == 0 {
        return Err(napi_error("connect timeout must be positive"));
    }
    validate_keepalive(
        server_alive_interval_seconds,
        server_alive_count_max,
        "target",
    )?;
    if generation == 0 {
        return Err(napi_error("generation must be positive"));
    }

    let transport_callback = Arc::new(
        on_transport
            .build_threadsafe_function::<TransportEvent>()
            .max_queue_size::<64>()
            .build()?,
    );
    let control_callback = Arc::new(
        on_control
            .build_threadsafe_function::<ControlEvent>()
            .max_queue_size::<64>()
            .build()?,
    );
    let auth_callback = Arc::new(
        on_auth
            .build_threadsafe_function::<AuthEvent>()
            .max_queue_size::<64>()
            .build()?,
    );

    let (write_tx, write_rx) = tokio::sync::mpsc::channel(4096);
    let (resize_tx, resize_rx) = tokio::sync::mpsc::channel(8);
    let (disconnect_tx, disconnect_rx) = tokio::sync::mpsc::channel(1);
    let (auth_tx, auth_rx) = tokio::sync::mpsc::channel(1);
    let (host_key_tx, host_key_rx) = tokio::sync::mpsc::channel(1);
    let (output_pause_tx, output_pause_rx) = tokio::sync::mpsc::channel(8);
    let session_id = NEXT_SESSION_ID.fetch_add(1, Ordering::SeqCst);

    get_sessions()
        .lock()
        .map_err(|_| napi_error("session map lock poisoned"))?
        .insert(
            session_id,
            ShellSession {
                generation,
                write_tx,
                resize_tx,
                disconnect_tx,
                auth_tx,
                host_key_tx,
                output_pause_tx,
            },
        );

    let receivers = SessionReceivers {
        write_rx,
        resize_rx,
        disconnect_rx,
        auth_rx,
        host_key_rx: Some(host_key_rx),
        output_pause_rx,
    };

    spawn(run_session(
        session_id,
        generation,
        host,
        port as u16,
        user,
        private_key_path,
        private_key_requires_passphrase,
        jump_host,
        jump_port as u16,
        jump_user,
        jump_private_key_path,
        jump_private_key_requires_passphrase,
        Duration::from_millis(jump_connect_timeout_ms as u64),
        jump_server_alive_interval_seconds,
        jump_server_alive_count_max,
        known_hosts_path,
        Duration::from_millis(connect_timeout_ms as u64),
        server_alive_interval_seconds,
        server_alive_count_max,
        verbose,
        transport_callback,
        control_callback,
        auth_callback,
        receivers,
    ));

    Ok(session_id.to_string())
}

#[napi]
#[allow(clippy::too_many_arguments)]
pub fn mosh_connect(
    host: String,
    port: u32,
    user: String,
    private_key_path: String,
    private_key_requires_passphrase: bool,
    known_hosts_path: String,
    connect_timeout_ms: u32,
    server_alive_interval_seconds: u32,
    server_alive_count_max: u32,
    server_path: String,
    udp_port_start: u32,
    udp_port_end: u32,
    prediction_mode: String,
    columns: u32,
    rows: u32,
    generation: u32,
    on_transport: Function<'_, TransportEvent, ()>,
    on_control: Function<'_, ControlEvent, ()>,
    on_auth: Function<'_, AuthEvent, ()>,
) -> Result<String> {
    if host.trim().is_empty() {
        return Err(napi_error("host must not be empty"));
    }
    if port == 0 || port > u16::MAX as u32 {
        return Err(napi_error("port must be between 1 and 65535"));
    }
    if user.trim().is_empty() {
        return Err(napi_error("user must not be empty"));
    }
    if known_hosts_path.trim().is_empty() {
        return Err(napi_error("known_hosts path must not be empty"));
    }
    if connect_timeout_ms == 0 {
        return Err(napi_error("connect timeout must be positive"));
    }
    validate_keepalive(
        server_alive_interval_seconds,
        server_alive_count_max,
        "Mosh bootstrap target",
    )?;
    let server_path = mosh_server_path(&server_path)
        .map_err(napi_error)?
        .map(str::to_owned);
    let udp_port_range = mosh_udp_port_range(udp_port_start, udp_port_end).map_err(napi_error)?;
    let prediction_mode = mosh_prediction_mode(&prediction_mode).map_err(napi_error)?;
    if columns == 0 || columns > 500 || rows == 0 || rows > 200 {
        return Err(napi_error(
            "Mosh terminal size must be between 1x1 and 500x200",
        ));
    }
    if generation == 0 {
        return Err(napi_error("generation must be positive"));
    }

    let transport_callback = Arc::new(
        on_transport
            .build_threadsafe_function::<TransportEvent>()
            .max_queue_size::<64>()
            .build()?,
    );
    let control_callback = Arc::new(
        on_control
            .build_threadsafe_function::<ControlEvent>()
            .max_queue_size::<64>()
            .build()?,
    );
    let auth_callback = Arc::new(
        on_auth
            .build_threadsafe_function::<AuthEvent>()
            .max_queue_size::<64>()
            .build()?,
    );
    let (write_tx, write_rx) = tokio::sync::mpsc::channel(64);
    let (resize_tx, resize_rx) = tokio::sync::mpsc::channel(8);
    let (disconnect_tx, disconnect_rx) = tokio::sync::mpsc::channel(1);
    let (auth_tx, auth_rx) = tokio::sync::mpsc::channel(1);
    let (host_key_tx, host_key_rx) = tokio::sync::mpsc::channel(1);
    let (output_pause_tx, output_pause_rx) = tokio::sync::mpsc::channel(8);
    let session_id = NEXT_SESSION_ID.fetch_add(1, Ordering::SeqCst);
    get_mosh_sessions()
        .lock()
        .map_err(|_| napi_error("Mosh session map lock poisoned"))?
        .insert(
            session_id,
            MoshSession {
                generation,
                write_tx,
                resize_tx,
                disconnect_tx,
                auth_tx,
                host_key_tx,
                output_pause_tx,
            },
        );
    let receivers = SessionReceivers {
        write_rx,
        resize_rx,
        disconnect_rx,
        auth_rx,
        host_key_rx: Some(host_key_rx),
        output_pause_rx,
    };
    spawn(run_mosh_session(
        session_id,
        generation,
        host,
        port as u16,
        user,
        private_key_path,
        private_key_requires_passphrase,
        known_hosts_path,
        Duration::from_millis(connect_timeout_ms as u64),
        server_alive_interval_seconds,
        server_alive_count_max,
        server_path,
        udp_port_range,
        prediction_mode,
        columns,
        rows,
        transport_callback,
        control_callback,
        auth_callback,
        receivers,
    ));
    Ok(session_id.to_string())
}

#[napi]
#[allow(clippy::too_many_arguments)]
pub fn ssh_start_file_transfer(
    direction: String,
    host: String,
    port: u32,
    user: String,
    private_key_path: String,
    private_key_requires_passphrase: bool,
    known_hosts_path: String,
    connect_timeout_ms: u32,
    server_alive_interval_seconds: u32,
    server_alive_count_max: u32,
    generation: u32,
    pane_id: String,
    remote_path: String,
    local_path: String,
    local_descriptor: i32,
    on_control: Function<'_, ControlEvent, ()>,
    on_auth: Function<'_, AuthEvent, ()>,
    on_transfer: Function<'_, FileTransferEvent, ()>,
) -> Result<String> {
    let direction = match direction.as_str() {
        "put" => transfer::Direction::Put,
        "get" => transfer::Direction::Get,
        _ => return Err(napi_error("transfer direction must be put or get")),
    };
    if host.trim().is_empty() || user.trim().is_empty() {
        return Err(napi_error("transfer host and user must not be empty"));
    }
    if port == 0 || port > u16::MAX as u32 {
        return Err(napi_error("transfer port must be between 1 and 65535"));
    }
    if known_hosts_path.trim().is_empty() || remote_path.trim().is_empty() {
        return Err(napi_error(
            "known_hosts path and remote path must not be empty",
        ));
    }
    if connect_timeout_ms == 0 || generation == 0 || pane_id.trim().is_empty() {
        return Err(napi_error(
            "transfer timeout, generation and pane id must be valid",
        ));
    }
    validate_keepalive(
        server_alive_interval_seconds,
        server_alive_count_max,
        "transfer target",
    )?;
    let local_file = match direction {
        transfer::Direction::Put => {
            if local_descriptor < 0 || !local_path.is_empty() {
                return Err(napi_error(
                    "put requires an open local descriptor and no local temporary path",
                ));
            }
            let borrowed = unsafe { BorrowedFd::borrow_raw(local_descriptor) };
            let duplicated = borrowed.try_clone_to_owned().map_err(|error| {
                napi_error(&format!("local file descriptor duplicate failed: {error}"))
            })?;
            std::fs::File::from(duplicated)
        }
        transfer::Direction::Get => {
            if local_descriptor >= 0 || local_path.trim().is_empty() {
                return Err(napi_error(
                    "get requires a local temporary path and no local descriptor",
                ));
            }
            std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&local_path)
                .map_err(|error| {
                    napi_error(&format!(
                        "exclusive local temporary file creation failed: {error}"
                    ))
                })?
        }
    };
    let metadata = local_file
        .metadata()
        .map_err(|error| napi_error(&format!("local file descriptor fstat failed: {error}")))?;
    if !metadata.is_file() {
        return Err(napi_error("local file descriptor is not a regular file"));
    }

    let control_callback = Arc::new(
        on_control
            .build_threadsafe_function::<ControlEvent>()
            .max_queue_size::<64>()
            .build()?,
    );
    let auth_callback = Arc::new(
        on_auth
            .build_threadsafe_function::<AuthEvent>()
            .max_queue_size::<64>()
            .build()?,
    );
    let transfer_callback = Arc::new(
        on_transfer
            .build_threadsafe_function::<FileTransferEvent>()
            .max_queue_size::<64>()
            .build()?,
    );
    let (disconnect_tx, disconnect_rx) = tokio::sync::mpsc::channel(1);
    let (auth_tx, auth_rx) = tokio::sync::mpsc::channel(1);
    let (host_key_tx, host_key_rx) = tokio::sync::mpsc::channel(1);
    let transfer_id = NEXT_SESSION_ID.fetch_add(1, Ordering::SeqCst);
    get_file_transfer_sessions()
        .lock()
        .map_err(|_| napi_error("file transfer session map lock poisoned"))?
        .insert(
            transfer_id,
            FileTransferSession {
                generation,
                disconnect_tx,
                auth_tx,
                host_key_tx,
            },
        );
    spawn(run_file_transfer(
        transfer_id,
        generation,
        pane_id,
        direction,
        host,
        port as u16,
        user,
        private_key_path,
        private_key_requires_passphrase,
        known_hosts_path,
        remote_path,
        local_file,
        local_path,
        Duration::from_millis(connect_timeout_ms as u64),
        server_alive_interval_seconds,
        server_alive_count_max,
        control_callback,
        auth_callback,
        transfer_callback,
        disconnect_rx,
        auth_rx,
        host_key_rx,
    ));
    Ok(transfer_id.to_string())
}

fn parse_session_id(session_id: &str) -> Result<u32> {
    session_id
        .parse::<u32>()
        .map_err(|_| napi_error("invalid session id"))
}

fn is_current_auth_generation(session_generation: u32, received_generation: u32) -> bool {
    received_generation != 0 && session_generation == received_generation
}

struct AuthSessionChannels {
    generation: u32,
    auth_tx: AuthSender,
    host_key_tx: tokio::sync::mpsc::Sender<HostKeyDecision>,
    disconnect_tx: DisconnectSender,
}

fn find_auth_session_channels(id: u32) -> Result<AuthSessionChannels> {
    if let Some(session) = get_sessions()
        .lock()
        .map_err(|_| napi_error("session map lock poisoned"))?
        .get(&id)
    {
        return Ok(AuthSessionChannels {
            generation: session.generation,
            auth_tx: session.auth_tx.clone(),
            host_key_tx: session.host_key_tx.clone(),
            disconnect_tx: session.disconnect_tx.clone(),
        });
    }
    if let Some(session) = get_mosh_sessions()
        .lock()
        .map_err(|_| napi_error("Mosh session map lock poisoned"))?
        .get(&id)
    {
        return Ok(AuthSessionChannels {
            generation: session.generation,
            auth_tx: session.auth_tx.clone(),
            host_key_tx: session.host_key_tx.clone(),
            disconnect_tx: session.disconnect_tx.clone(),
        });
    }
    let sessions = get_file_transfer_sessions()
        .lock()
        .map_err(|_| napi_error("file transfer session map lock poisoned"))?;
    let session = sessions
        .get(&id)
        .ok_or_else(|| napi_error("session not found"))?;
    Ok(AuthSessionChannels {
        generation: session.generation,
        auth_tx: session.auth_tx.clone(),
        host_key_tx: session.host_key_tx.clone(),
        disconnect_tx: session.disconnect_tx.clone(),
    })
}

#[napi]
pub fn ssh_auth_password(
    session_id: String,
    generation: u32,
    layer: String,
    password: String,
) -> Result<()> {
    let id = parse_session_id(&session_id)?;
    let session = find_auth_session_channels(id)?;
    if !is_current_auth_generation(session.generation, generation) {
        return Err(napi_error("stale authentication generation"));
    }
    session
        .auth_tx
        .try_send(LayeredAuthMethod {
            layer: ConnectionLayer::parse(&layer)
                .ok_or_else(|| napi_error("authentication layer must be jump or target"))?,
            method: AuthMethod::Password(password),
        })
        .map_err(|error| napi_error(&format!("send failed: {}", error)))
}

#[napi]
pub fn ssh_auth_private_key_passphrase(
    session_id: String,
    generation: u32,
    layer: String,
    passphrase: String,
) -> Result<()> {
    let id = parse_session_id(&session_id)?;
    let session = find_auth_session_channels(id)?;
    if !is_current_auth_generation(session.generation, generation) {
        return Err(napi_error("stale authentication generation"));
    }
    session
        .auth_tx
        .try_send(LayeredAuthMethod {
            layer: ConnectionLayer::parse(&layer)
                .ok_or_else(|| napi_error("authentication layer must be jump or target"))?,
            method: AuthMethod::PrivateKeyPassphrase(passphrase),
        })
        .map_err(|error| napi_error(&format!("send failed: {}", error)))
}

#[napi]
pub fn ssh_auth_keyboard_interactive_responses(
    session_id: String,
    generation: u32,
    layer: String,
    round_id: u32,
    responses: Vec<String>,
) -> Result<()> {
    let id = parse_session_id(&session_id)?;
    let session = find_auth_session_channels(id)?;
    if !is_current_auth_generation(session.generation, generation) {
        return Err(napi_error("stale authentication generation"));
    }
    session
        .auth_tx
        .try_send(LayeredAuthMethod {
            layer: ConnectionLayer::parse(&layer)
                .ok_or_else(|| napi_error("authentication layer must be jump or target"))?,
            method: AuthMethod::KeyboardInteractiveResponses {
                round_id,
                responses,
            },
        })
        .map_err(|error| napi_error(&format!("send failed: {}", error)))
}

#[napi]
pub fn ssh_verify_host_key(
    session_id: String,
    generation: u32,
    layer: String,
    accepted: bool,
) -> Result<()> {
    let id = parse_session_id(&session_id)?;
    let session = find_auth_session_channels(id)?;
    if !is_current_auth_generation(session.generation, generation) {
        return Err(napi_error("stale host-key generation"));
    }
    session
        .host_key_tx
        .try_send(HostKeyDecision {
            layer: ConnectionLayer::parse(&layer)
                .ok_or_else(|| napi_error("host-key layer must be jump or target"))?,
            accepted,
        })
        .map_err(|error| napi_error(&format!("send failed: {}", error)))
}

#[napi]
pub fn ssh_write(session_id: String, data: String) -> Result<()> {
    let id = parse_session_id(&session_id)?;
    let sessions = get_sessions()
        .lock()
        .map_err(|_| napi_error("session map lock poisoned"))?;
    let session = sessions
        .get(&id)
        .ok_or_else(|| napi_error("session not found"))?;
    session
        .write_tx
        .try_send(data.into_bytes())
        .map_err(|error| napi_error(&format!("send failed: {}", error)))
}

#[napi]
pub fn ssh_resize(session_id: String, cols: u32, rows: u32) -> Result<()> {
    if cols == 0 || rows == 0 {
        return Err(napi_error("terminal size must be positive"));
    }
    let id = parse_session_id(&session_id)?;
    let sessions = get_sessions()
        .lock()
        .map_err(|_| napi_error("session map lock poisoned"))?;
    let session = sessions
        .get(&id)
        .ok_or_else(|| napi_error("session not found"))?;
    session
        .resize_tx
        .try_send((cols, rows))
        .map_err(|error| napi_error(&format!("send failed: {}", error)))
}

#[napi]
pub fn ssh_set_output_paused(session_id: String, paused: bool) -> Result<()> {
    let id = parse_session_id(&session_id)?;
    let sessions = get_sessions()
        .lock()
        .map_err(|_| napi_error("session map lock poisoned"))?;
    let session = sessions
        .get(&id)
        .ok_or_else(|| napi_error("session not found"))?;
    session
        .output_pause_tx
        .try_send(paused)
        .map_err(|error| napi_error(&format!("send failed: {}", error)))
}

#[napi]
pub fn ssh_disconnect(session_id: String) -> Result<()> {
    let id = parse_session_id(&session_id)?;
    let session = find_auth_session_channels(id)?;
    session
        .disconnect_tx
        .try_send(())
        .map_err(|error| napi_error(&format!("send failed: {}", error)))
}

#[napi]
pub fn mosh_write(session_id: String, data: String) -> Result<()> {
    let id = parse_session_id(&session_id)?;
    let sessions = get_mosh_sessions()
        .lock()
        .map_err(|_| napi_error("Mosh session map lock poisoned"))?;
    let session = sessions
        .get(&id)
        .ok_or_else(|| napi_error("Mosh session not found"))?;
    session
        .write_tx
        .try_send(data.into_bytes())
        .map_err(|error| napi_error(&format!("send failed: {error}")))
}

#[napi]
pub fn mosh_resize(session_id: String, columns: u32, rows: u32) -> Result<()> {
    if columns == 0 || columns > 500 || rows == 0 || rows > 200 {
        return Err(napi_error(
            "Mosh terminal size must be between 1x1 and 500x200",
        ));
    }
    let id = parse_session_id(&session_id)?;
    let sessions = get_mosh_sessions()
        .lock()
        .map_err(|_| napi_error("Mosh session map lock poisoned"))?;
    let session = sessions
        .get(&id)
        .ok_or_else(|| napi_error("Mosh session not found"))?;
    session
        .resize_tx
        .try_send((columns, rows))
        .map_err(|error| napi_error(&format!("send failed: {error}")))
}

#[napi]
pub fn mosh_set_output_paused(session_id: String, paused: bool) -> Result<()> {
    let id = parse_session_id(&session_id)?;
    let sessions = get_mosh_sessions()
        .lock()
        .map_err(|_| napi_error("Mosh session map lock poisoned"))?;
    let session = sessions
        .get(&id)
        .ok_or_else(|| napi_error("Mosh session not found"))?;
    session
        .output_pause_tx
        .try_send(paused)
        .map_err(|error| napi_error(&format!("send failed: {error}")))
}

#[napi]
pub fn mosh_disconnect(session_id: String) -> Result<()> {
    let id = parse_session_id(&session_id)?;
    let sessions = get_mosh_sessions()
        .lock()
        .map_err(|_| napi_error("Mosh session map lock poisoned"))?;
    let session = sessions
        .get(&id)
        .ok_or_else(|| napi_error("Mosh session not found"))?;
    session
        .disconnect_tx
        .try_send(())
        .map_err(|error| napi_error(&format!("send failed: {error}")))
}

#[napi]
pub fn cancel_all_sessions() -> Result<u32> {
    let mut requested = 0_u32;
    {
        let sessions = get_sessions()
            .lock()
            .map_err(|_| napi_error("SSH session map lock poisoned"))?;
        for session in sessions.values() {
            if session.disconnect_tx.try_send(()).is_ok() {
                requested += 1;
            }
        }
    }
    {
        let sessions = get_mosh_sessions()
            .lock()
            .map_err(|_| napi_error("Mosh session map lock poisoned"))?;
        for session in sessions.values() {
            if session.disconnect_tx.try_send(()).is_ok() {
                requested += 1;
            }
        }
    }
    {
        let sessions = get_file_transfer_sessions()
            .lock()
            .map_err(|_| napi_error("file transfer session map lock poisoned"))?;
        for session in sessions.values() {
            if session.disconnect_tx.try_send(()).is_ok() {
                requested += 1;
            }
        }
    }
    Ok(requested)
}

#[napi]
pub async fn ssh_generate_key_pair(
    algorithm: String,
    passphrase: String,
    output_dir: String,
    file_name: String,
    comment: String,
) -> Result<String> {
    let result = tokio::task::spawn_blocking(move || {
        keygen::generate_key_pair(&algorithm, &output_dir, &file_name, &passphrase, &comment)
    })
    .await
    .map_err(|error| napi_error(&format!("key generation task failed: {error}")))?
    .map_err(|error| napi_error(&error))?;
    let json = format!(
        "{{\"privatePath\":\"{}\",\"publicPath\":\"{}\",\"fingerprint\":\"{}\"}}",
        result.private_path, result.public_path, result.fingerprint
    );
    Ok(json)
}

#[napi]
pub fn ssh_change_private_key_passphrase(
    key_path: String,
    mut old_passphrase: String,
    mut new_passphrase: String,
) -> Result<()> {
    let result = keygen::change_private_key_passphrase(&key_path, &old_passphrase, &new_passphrase);
    old_passphrase.zeroize();
    new_passphrase.zeroize();
    result.map_err(|error| napi_error(&error))
}

#[napi]
pub fn ssh_read_key_comment(key_path: String, mut passphrase: String) -> Result<String> {
    let result = keygen::read_key_comment(&key_path, &passphrase);
    passphrase.zeroize();
    result.map_err(|error| napi_error(&error))
}

#[napi]
pub fn ssh_change_key_comment(
    key_path: String,
    mut passphrase: String,
    new_comment: String,
) -> Result<String> {
    let result = keygen::change_key_comment(&key_path, &passphrase, &new_comment);
    passphrase.zeroize();
    result.map_err(|error| napi_error(&error))
}

#[napi]
pub fn ssh_export_key_pair(
    private_path: String,
    public_path: String,
    output_dir: String,
    file_name: String,
) -> Result<()> {
    keygen::export_key_pair(&private_path, &public_path, &output_dir, &file_name)
        .map_err(|e| napi_error(&e))
}

#[napi]
pub fn ssh_read_public_key(key_path: String) -> Result<String> {
    keygen::read_public_key_fingerprint(&key_path).map_err(|e| napi_error(&e))
}

#[napi(object)]
pub struct KnownHostsRemovalResult {
    pub content: String,
    pub removed: u32,
}

#[napi(object)]
pub struct KnownHostsQueryResult {
    pub output: String,
    pub found: u32,
}

#[napi]
pub fn ssh_find_known_host_entries(
    content: String,
    host: String,
    port: u32,
) -> Result<KnownHostsQueryResult> {
    let port = u16::try_from(port)
        .ok()
        .filter(|value| *value > 0)
        .ok_or_else(|| napi_error("known_hosts port must be between 1 and 65535"))?;
    let result =
        find_known_host_entries(&content, &host, port).map_err(|error| napi_error(&error))?;
    Ok(KnownHostsQueryResult {
        output: result.output,
        found: result.found,
    })
}

#[napi]
pub fn ssh_remove_known_host_entries(
    content: String,
    host: String,
    port: u32,
) -> Result<KnownHostsRemovalResult> {
    let port = u16::try_from(port)
        .ok()
        .filter(|value| *value > 0)
        .ok_or_else(|| napi_error("known_hosts port must be between 1 and 65535"))?;
    let result =
        remove_known_host_entries(&content, &host, port).map_err(|error| napi_error(&error))?;
    Ok(KnownHostsRemovalResult {
        content: result.content,
        removed: result.removed,
    })
}

#[napi]
pub fn ssh_inspect_private_key(key_path: String) -> Result<String> {
    let inspected = keygen::inspect_private_key(&key_path).map_err(|e| napi_error(&e))?;
    Ok(format!(
        "{}\n{}\n{}\n{}",
        if inspected.encrypted { "true" } else { "false" },
        inspected.algorithm,
        inspected.fingerprint,
        inspected.public_key
    ))
}

#[napi]
pub fn ssh_protect_private_key(key_path: String) -> Result<()> {
    keygen::protect_private_key(&key_path).map_err(|e| napi_error(&e))
}

#[cfg(test)]
mod tests {
    use super::{
        append_mosh_bootstrap_output, build_client_config, channel_writer_exit_message,
        is_current_auth_generation, mosh_bootstrap_command, mosh_bootstrap_exit_error,
        mosh_prediction_mode, mosh_server_ipv4, mosh_server_path, mosh_session_close_reason,
        mosh_session_exit_failure, mosh_udp_port_range, run_channel_writer_core,
        send_scheduled_input, should_flush_immediately, transfer, validate_keepalive,
        validate_mosh_server_port, wait_for_auth_command, wait_for_auth_exchange, wait_for_connect,
        wait_for_file_transfer, wait_for_host_key_decision, AuthExchangeResult, AuthMethod,
        AuthWaitResult, ChangedHostKeyControl, ConnectProgress, ConnectWaitResult, ConnectionLayer,
        ControlEvent, FileTransferEvent, FileTransferWaitResult, HostKeyDecision,
        LayeredAuthMethod, MoshSessionExit, MoshSessionInterruption, MoshSessionReachability,
        OutputDeliveryMetrics, SessionClose, SessionPhaseFailure, TransportEvent,
        AUTH_EXCHANGE_TIMEOUT, AUTH_RESPONSE_TIMEOUT, INPUT_WRITE_CHUNK_BYTES,
    };
    use napi_ohos::Status;
    use russh::client;
    use russh::keys::{Algorithm, EcdsaCurve, PrivateKey, PrivateKeyWithHashAlg, PublicKey};
    use russh::server::{self, Auth, Handler, Msg, Server as _, Session};
    use russh::{Channel, ChannelMsg, Disconnect};
    use std::future::{pending, ready};
    use std::net::SocketAddr;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;
    use tokio::net::TcpListener;
    use tokio::sync::{mpsc, Notify};

    const ACTOR_TEST_WINDOW_BYTES: usize = 16 * 1024;

    #[test]
    fn mosh_prediction_mode_maps_only_the_standard_public_values() {
        assert_eq!(
            mosh_prediction_mode("adaptive"),
            Ok(mosh_client::PredictionMode::Adaptive)
        );
        assert_eq!(
            mosh_prediction_mode("always"),
            Ok(mosh_client::PredictionMode::Always)
        );
        assert_eq!(
            mosh_prediction_mode("never"),
            Ok(mosh_client::PredictionMode::Never)
        );
        for invalid in ["", "auto", "ALWAYS", "adaptive ", "always,never"] {
            assert_eq!(
                mosh_prediction_mode(invalid),
                Err("Mosh prediction mode must be adaptive, always or never")
            );
        }
    }

    #[test]
    fn mosh_udp_port_range_builds_only_valid_stock_server_arguments() {
        let dynamic = mosh_udp_port_range(0, 0).unwrap();
        let fixed = mosh_udp_port_range(60042, 60042).unwrap();
        let range = mosh_udp_port_range(60042, 60049).unwrap();

        assert_eq!(dynamic, None);
        assert_eq!(fixed.unwrap().argument(), "60042");
        assert_eq!(range.unwrap().argument(), "60042:60049");
        assert_eq!(
            mosh_bootstrap_command(None, dynamic),
            "sh -c '[ -n \"$SSH_CONNECTION\" ] && printf \"\\nMOSH SSH_CONNECTION %s\\n\" \"$SSH_CONNECTION\"; exec mosh-server new -s -c 256'"
        );
        assert!(mosh_bootstrap_command(None, fixed).ends_with(" -p 60042'"));
        assert!(mosh_bootstrap_command(None, range).ends_with(" -p 60042:60049'"));
    }

    #[test]
    fn mosh_server_path_builds_one_executable_without_shell_fragments() {
        let path = mosh_server_path("/home/deploy/.local/bin/mosh-server").unwrap();
        assert_eq!(mosh_server_path(""), Ok(None));
        assert_eq!(
            mosh_bootstrap_command(path, None),
            "sh -c '[ -n \"$SSH_CONNECTION\" ] && printf \"\\nMOSH SSH_CONNECTION %s\\n\" \"$SSH_CONNECTION\"; exec /home/deploy/.local/bin/mosh-server new -s -c 256'"
        );
        for invalid in [
            "mosh-server",
            "~/bin/mosh-server",
            "/opt//mosh-server",
            "/opt/../bin/mosh-server",
            "/opt/mosh-server;id",
            "/opt/mosh server",
            "/opt/$server",
        ] {
            assert!(mosh_server_path(invalid).is_err(), "accepted {invalid}");
        }
        let overlong = format!("/{}", "a".repeat(1024));
        assert!(mosh_server_path(&overlong).is_err());
    }

    #[test]
    fn mosh_bootstrap_distinguishes_server_start_failures_and_bounds_output() {
        assert_eq!(mosh_bootstrap_exit_error(0), None);
        assert_eq!(
            mosh_bootstrap_exit_error(126),
            Some("configured mosh-server path is not executable")
        );
        assert_eq!(
            mosh_bootstrap_exit_error(127),
            Some("configured mosh-server path does not exist")
        );
        assert_eq!(
            mosh_bootstrap_exit_error(1),
            Some("mosh-server exited before creating a Session")
        );
        let mut output = Vec::new();
        assert_eq!(
            append_mosh_bootstrap_output(&mut output, &[0; 4096]),
            Ok(())
        );
        assert_eq!(
            append_mosh_bootstrap_output(&mut output, &[1]),
            Err("mosh-server bootstrap output exceeded 4 KiB")
        );
    }

    #[test]
    fn mosh_udp_port_range_rejects_dynamic_fixed_and_order_conflicts() {
        assert!(mosh_udp_port_range(0, 60042).is_err());
        assert!(mosh_udp_port_range(60042, 0).is_err());
        assert!(mosh_udp_port_range(65536, 65536).is_err());
        assert!(mosh_udp_port_range(60050, 60042).is_err());

        let requested = mosh_udp_port_range(60042, 60049).unwrap();
        assert_eq!(validate_mosh_server_port(60042, requested), Ok(()));
        assert_eq!(validate_mosh_server_port(60049, requested), Ok(()));
        assert_eq!(
            validate_mosh_server_port(60050, requested),
            Err("mosh-server returned a UDP port outside the requested range")
        );
        assert_eq!(validate_mosh_server_port(60050, None), Ok(()));
    }

    #[test]
    fn mosh_graceful_close_exits_are_normal_and_hard_stops_are_failures() {
        assert_eq!(
            mosh_session_close_reason(&MoshSessionExit::LocalClosed),
            Some("local_closed")
        );
        assert_eq!(
            mosh_session_exit_failure(&MoshSessionExit::LocalClosed),
            None
        );
        assert_eq!(
            mosh_session_close_reason(&MoshSessionExit::RemoteClosed),
            Some("remote_closed")
        );
        assert_eq!(
            mosh_session_exit_failure(&MoshSessionExit::RemoteClosed),
            None
        );
        assert_eq!(
            mosh_session_exit_failure(&MoshSessionExit::Cancelled),
            Some((
                "cancelled",
                "Mosh protocol task stopped without a graceful close"
            ))
        );
        assert_eq!(
            mosh_session_exit_failure(&MoshSessionExit::OwnerDropped),
            Some(("internal", "Mosh protocol session owner was dropped"))
        );
    }

    #[test]
    fn mosh_bootstrap_uses_the_server_side_ipv4_from_ssh_connection() {
        let output = b"notice\r\nMOSH SSH_CONNECTION 192.0.2.10 50000 198.51.100.7 22\r\n\
MOSH CONNECT 60001 4NeCCgvZFe2RnPgrcU1PQw\r\n";

        assert_eq!(
            mosh_server_ipv4(output).unwrap(),
            "198.51.100.7".parse::<std::net::Ipv4Addr>().unwrap()
        );
    }

    #[test]
    fn mosh_bootstrap_rejects_missing_ambiguous_or_ipv6_server_addresses() {
        assert_eq!(
            mosh_server_ipv4(b"MOSH CONNECT 60001 4NeCCgvZFe2RnPgrcU1PQw\n"),
            Err("Mosh bootstrap did not report the SSH server address")
        );
        assert_eq!(
            mosh_server_ipv4(
                b"MOSH SSH_CONNECTION 192.0.2.10 50000 198.51.100.7 22\n\
MOSH SSH_CONNECTION 192.0.2.10 50000 198.51.100.8 22\n"
            ),
            Err("invalid or ambiguous MOSH SSH_CONNECTION record")
        );
        assert_eq!(
            mosh_server_ipv4(b"MOSH SSH_CONNECTION 2001:db8::1 50000 2001:db8::2 22\n"),
            Err("Mosh bootstrap requires an IPv4 SSH server address")
        );
    }

    #[test]
    fn mosh_bootstrap_rejects_noncanonical_ssh_connection_records() {
        assert_eq!(
            mosh_server_ipv4(b" MOSH SSH_CONNECTION 192.0.2.10 50000 198.51.100.7 22\n"),
            Err("Mosh bootstrap did not report the SSH server address")
        );
        assert_eq!(
            mosh_server_ipv4(b"MOSH  SSH_CONNECTION 192.0.2.10 50000 198.51.100.7 22\n"),
            Err("Mosh bootstrap did not report the SSH server address")
        );
    }

    #[test]
    fn diagnostic_transport_events_contain_only_fixed_metadata_fields() {
        let event =
            TransportEvent::diagnostic(ConnectionLayer::Target, "authentication", "waiting");
        assert_eq!(event.kind, "diagnostic");
        assert_eq!(event.layer, "target");
        assert_eq!(event.stage, "authentication");
        assert_eq!(event.status, "waiting");
        assert!(event.reason.is_empty());
        assert!(event.result.is_empty());
    }

    #[test]
    fn mosh_reachability_uses_only_fixed_status_and_reason_fields() {
        let awaiting = TransportEvent::mosh_reachability("awaiting_peer", "");
        assert_eq!(awaiting.kind, "reachability");
        assert_eq!(awaiting.layer, "target");
        assert_eq!(awaiting.stage, "mosh_udp");
        assert_eq!(awaiting.status, "awaiting_peer");
        assert!(awaiting.reason.is_empty());

        assert_eq!(
            super::mosh_reachability_fields(MoshSessionReachability::Responsive),
            Some(("responsive", ""))
        );
        assert_eq!(
            super::mosh_reachability_fields(MoshSessionReachability::Interrupted {
                reason: MoshSessionInterruption::NoRecentContact,
            }),
            Some(("interrupted", "no_recent_contact"))
        );
        assert_eq!(
            super::mosh_reachability_fields(MoshSessionReachability::Interrupted {
                reason: MoshSessionInterruption::NoRecentReply,
            }),
            Some(("interrupted", "no_recent_reply"))
        );
    }

    #[test]
    fn mosh_initial_attachment_timeout_is_a_connection_failure() {
        assert_eq!(
            super::mosh_session_error_code(&mosh_client::SessionError::ConnectionTimeout),
            "connection_timeout"
        );
    }

    #[test]
    fn control_errors_keep_identity_and_classification_separate_from_detail() {
        let event = ControlEvent::error(
            41,
            7,
            ConnectionLayer::Jump,
            "authentication",
            "auth",
            "target: opaque server detail",
        );
        assert_eq!(event.kind, "error");
        assert_eq!(event.session_id, "41");
        assert_eq!(event.generation, 7);
        assert_eq!(event.layer, "jump");
        assert_eq!(event.stage, "authentication");
        assert_eq!(event.code, "auth");
        assert_eq!(event.detail, "target: opaque server detail");
    }

    #[test]
    fn changed_host_key_control_events_use_dedicated_fields() {
        let event = ControlEvent::host_key_changed(
            42,
            8,
            ConnectionLayer::Target,
            ChangedHostKeyControl {
                algorithm: "ssh-ed25519".to_string(),
                old_fingerprint: "SHA256:old".to_string(),
                new_fingerprint: "SHA256:new".to_string(),
                host: "server.example.com".to_string(),
                port: 2222,
            },
        );
        assert_eq!(event.kind, "host_key_changed");
        assert_eq!(event.layer, "target");
        assert_eq!(event.algorithm, "ssh-ed25519");
        assert_eq!(event.old_fingerprint, "SHA256:old");
        assert_eq!(event.new_fingerprint, "SHA256:new");
        assert_eq!(event.host, "server.example.com");
        assert_eq!(event.port, 2222);
    }

    #[test]
    fn close_transport_errors_do_not_use_tagged_result_strings() {
        let event = TransportEvent::close(
            -1,
            "target".to_string(),
            "keepalive_timeout".to_string(),
            "SSH keepalive timed out. Check the network.".to_string(),
        );
        assert_eq!(event.kind, "close");
        assert_eq!(event.exit_code, -1);
        assert_eq!(event.layer, "target");
        assert_eq!(event.code, "keepalive_timeout");
        assert!(event.result.is_empty());
    }

    #[test]
    fn connect_failures_are_reduced_to_safe_fixed_reasons() {
        assert_eq!(
            super::connect_failure_reason(
                &russh::Error::IO(std::io::Error::from(std::io::ErrorKind::ConnectionRefused)),
                true,
            ),
            "tcp_refused"
        );
        assert_eq!(
            super::connect_failure_reason(&russh::Error::Version, true),
            "ssh_version"
        );
        assert_eq!(
            super::connect_failure_reason(&russh::Error::Kex, true),
            "key_exchange"
        );
        assert_eq!(
            super::connect_failure_reason(
                &russh::Error::IO(std::io::Error::from(std::io::ErrorKind::UnexpectedEof)),
                false,
            ),
            "tcp_failed"
        );
    }

    #[test]
    fn session_phase_failures_keep_structured_error_mapping() {
        let refused = SessionPhaseFailure::connect_failed(
            ConnectionLayer::Jump,
            "opaque io failure".to_string(),
            "tcp_refused",
        );
        assert_eq!(refused.layer, ConnectionLayer::Jump);
        assert_eq!(refused.stage, "connect");
        assert_eq!(refused.code, "network");
        assert_eq!(refused.diagnostic_status, "failed");
        assert_eq!(refused.diagnostic_reason, Some("tcp_refused"));

        let timeout = SessionPhaseFailure::timed_out(
            ConnectionLayer::Target,
            "channel",
            "channel",
            "session channel timed out after 15000 ms".to_string(),
        );
        assert_eq!(timeout.layer, ConnectionLayer::Target);
        assert_eq!(timeout.stage, "channel");
        assert_eq!(timeout.code, "channel");
        assert_eq!(timeout.diagnostic_status, "timed_out");
        assert_eq!(timeout.diagnostic_reason, None);
    }

    #[test]
    fn session_close_keeps_normal_and_keepalive_contracts_distinct() {
        assert_eq!(
            SessionClose::normal(0),
            SessionClose {
                exit_code: 0,
                layer: String::new(),
                code: String::new(),
                detail: String::new(),
            }
        );
        let timeout = SessionClose::keepalive_timeout(-1, ConnectionLayer::Jump);
        assert_eq!(timeout.exit_code, -1);
        assert_eq!(timeout.layer, "jump");
        assert_eq!(timeout.code, "keepalive_timeout");
        assert!(timeout.detail.contains("SSH keepalive timed out"));
    }

    #[derive(Debug)]
    enum ActorServerEvent {
        Data(Vec<u8>),
        Resize(u32, u32),
    }

    #[derive(Clone)]
    struct ActorServer {
        event_tx: mpsc::UnboundedSender<ActorServerEvent>,
    }

    impl server::Server for ActorServer {
        type Handler = Self;

        fn new_client(&mut self, _: Option<SocketAddr>) -> Self::Handler {
            self.clone()
        }
    }

    impl Handler for ActorServer {
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
            let event_tx = self.event_tx.clone();
            reply.accept().await;
            tokio::spawn(async move {
                while let Some(message) = channel.wait().await {
                    let event = match message {
                        ChannelMsg::Data { data } => ActorServerEvent::Data(data.to_vec()),
                        ChannelMsg::WindowChange {
                            col_width,
                            row_height,
                            ..
                        } => ActorServerEvent::Resize(col_width, row_height),
                        ChannelMsg::Eof | ChannelMsg::Close => return,
                        _ => continue,
                    };
                    if event_tx.send(event).is_err() {
                        return;
                    }
                }
            });
            Ok(())
        }
    }

    struct ActorClient;

    impl client::Handler for ActorClient {
        type Error = russh::Error;

        async fn check_server_key(&mut self, _: &PublicKey) -> Result<bool, Self::Error> {
            Ok(true)
        }
    }

    #[tokio::test]
    async fn locked_russh_stack_authenticates_standard_ecdsa_curves() {
        let socket = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = socket.local_addr().unwrap();
        let (event_tx, _event_rx) = mpsc::unbounded_channel();
        let mut server = ActorServer { event_tx };
        let config = Arc::new(server::Config {
            keys: vec![PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap()],
            ..Default::default()
        });
        let running = server.run_on_socket(config, &socket);
        let server_handle = running.handle();

        let client = async move {
            for curve in [
                EcdsaCurve::NistP256,
                EcdsaCurve::NistP384,
                EcdsaCurve::NistP521,
            ] {
                let config = Arc::new(client::Config::default());
                let key = Arc::new(
                    PrivateKey::random(&mut rand::rng(), Algorithm::Ecdsa { curve }).unwrap(),
                );
                let mut session = client::connect(config, address, ActorClient).await.unwrap();
                assert!(session
                    .authenticate_publickey("user", PrivateKeyWithHashAlg::new(key, None))
                    .await
                    .unwrap()
                    .success());
                session
                    .disconnect(Disconnect::ByApplication, "test complete", "")
                    .await
                    .unwrap();
            }
        };

        let managed_client = async move {
            let result = tokio::time::timeout(Duration::from_secs(15), client).await;
            server_handle.shutdown("test complete".to_string());
            result.expect("ECDSA authentication gate timed out");
        };
        let (server_result, ()) = tokio::join!(running, managed_client);
        server_result.unwrap();
    }

    #[tokio::test]
    async fn product_writer_actor_preserves_follow_up_after_one_mebibyte() {
        let socket = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = socket.local_addr().unwrap();
        let (event_tx, mut event_rx) = mpsc::unbounded_channel();
        let mut server = ActorServer { event_tx };
        let config = Arc::new(server::Config {
            keys: vec![PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap()],
            window_size: ACTOR_TEST_WINDOW_BYTES as u32,
            channel_buffer_size: 1,
            ..Default::default()
        });
        let running = server.run_on_socket(config, &socket);
        let server_handle = running.handle();

        let client = async move {
            let config = Arc::new(client::Config {
                window_size: ACTOR_TEST_WINDOW_BYTES as u32,
                channel_buffer_size: 1,
                ..Default::default()
            });
            let key = Arc::new(PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap());
            let mut session = client::connect(config, address, ActorClient).await.unwrap();
            let hash = session.best_supported_rsa_hash().await.unwrap().flatten();
            assert!(session
                .authenticate_publickey("user", PrivateKeyWithHashAlg::new(key, hash))
                .await
                .unwrap()
                .success());
            let channel = session.channel_open_session().await.unwrap();
            let (_read_half, write_half) = channel.split();
            let (write_tx, write_rx) = mpsc::channel(4096);
            let (resize_tx, resize_rx) = mpsc::channel(8);
            let errors = Arc::new(Mutex::new(Vec::<String>::new()));
            let reported_errors = Arc::clone(&errors);
            let writer = tokio::spawn(run_channel_writer_core(
                write_half,
                write_rx,
                resize_rx,
                move |_stage, error| reported_errors.lock().unwrap().push(error),
            ));

            let payload = (0..(1024 * 1024 + 17))
                .map(|index| (index % 251) as u8)
                .collect::<Vec<_>>();
            let follow_up = b"ltty-input-check actor\r";
            write_tx.send(payload.clone()).await.unwrap();
            resize_tx.send((181, 49)).await.unwrap();
            for byte in follow_up {
                write_tx.send(vec![*byte]).await.unwrap();
            }

            let mut received = Vec::with_capacity(payload.len() + follow_up.len());
            let mut resize_seen = false;
            tokio::time::timeout(Duration::from_secs(5), async {
                while received.len() < payload.len() + follow_up.len() || !resize_seen {
                    match event_rx.recv().await {
                        Some(ActorServerEvent::Data(data)) => received.extend_from_slice(&data),
                        Some(ActorServerEvent::Resize(cols, rows)) => {
                            resize_seen = cols == 181 && rows == 49;
                        }
                        None => break,
                    }
                }
            })
            .await
            .expect("product writer actor did not deliver input and resize");

            assert_eq!(&received[..payload.len()], payload);
            assert_eq!(&received[payload.len()..], follow_up);
            assert!(resize_seen);
            assert!(errors.lock().unwrap().is_empty());
            assert!(
                !writer.is_finished(),
                "product writer actor stopped unexpectedly"
            );
            writer.abort();
            assert!(writer.await.unwrap_err().is_cancelled());
            session
                .disconnect(Disconnect::ByApplication, "test complete", "")
                .await
                .unwrap();
        };

        let managed_client = async move {
            let result = tokio::time::timeout(Duration::from_secs(15), client).await;
            server_handle.shutdown("test complete".to_string());
            result.expect("product writer actor test timed out");
        };
        let (server_result, ()) = tokio::join!(running, managed_client);
        server_result.unwrap();
    }

    #[tokio::test]
    async fn channel_writer_panic_becomes_an_observable_error() {
        let writer = tokio::spawn(async {
            panic!("writer-test-panic");
        });
        let message = channel_writer_exit_message(writer.await);

        assert!(message.starts_with("SSH channel writer task failed:"));
        assert!(message.contains("panicked"));
    }

    #[tokio::test]
    async fn scheduled_input_is_bounded_and_services_resize_during_backpressure() {
        let payload = (0..(1024 * 1024 + 17))
            .map(|index| (index % 251) as u8)
            .collect::<Vec<_>>();
        let expected = payload.clone();
        let chunks = Arc::new(Mutex::new(Vec::<Vec<u8>>::new()));
        let send_count = Arc::new(AtomicUsize::new(0));
        let resize_seen = Arc::new(AtomicBool::new(false));
        let first_send_gate = Arc::new(Notify::new());
        let (resize_tx, mut resize_rx) = mpsc::channel(1);
        resize_tx.send((181, 49)).await.unwrap();

        let sent_chunks = Arc::clone(&chunks);
        let sent_count = Arc::clone(&send_count);
        let send_gate = Arc::clone(&first_send_gate);
        let observed_resize = Arc::clone(&resize_seen);
        let resize_gate = Arc::clone(&first_send_gate);
        let (write_result, resize_errors) = tokio::time::timeout(
            Duration::from_secs(1),
            send_scheduled_input(
                payload,
                &mut resize_rx,
                move |chunk| {
                    let chunks = Arc::clone(&sent_chunks);
                    let gate = Arc::clone(&send_gate);
                    let call = sent_count.fetch_add(1, Ordering::SeqCst);
                    async move {
                        if call == 0 {
                            tokio::time::timeout(Duration::from_millis(100), gate.notified())
                                .await
                                .map_err(|_| "resize was starved by backpressured input")?;
                        }
                        chunks.lock().unwrap().push(chunk);
                        Ok::<(), &'static str>(())
                    }
                },
                move |size| {
                    let resize_seen = Arc::clone(&observed_resize);
                    let gate = Arc::clone(&resize_gate);
                    async move {
                        assert_eq!(size, (181, 49));
                        resize_seen.store(true, Ordering::SeqCst);
                        gate.notify_one();
                        Ok::<(), &'static str>(())
                    }
                },
            ),
        )
        .await
        .expect("scheduled input did not finish");

        assert_eq!(write_result, Ok(()));
        assert!(resize_errors.is_empty());
        assert!(resize_seen.load(Ordering::SeqCst));
        let chunks = chunks.lock().unwrap();
        assert!(chunks.len() > 1);
        assert!(chunks
            .iter()
            .all(|chunk| chunk.len() <= INPUT_WRITE_CHUNK_BYTES));
        assert_eq!(chunks.concat(), expected);
    }

    #[tokio::test]
    async fn scheduled_input_keeps_small_writes_on_the_direct_path() {
        let payload = b"ordinary terminal input\r".to_vec();
        let expected = payload.clone();
        let chunks = Arc::new(Mutex::new(Vec::<Vec<u8>>::new()));
        let sent_chunks = Arc::clone(&chunks);
        let (_resize_tx, mut resize_rx) = mpsc::channel(1);

        let (write_result, resize_errors) = send_scheduled_input(
            payload,
            &mut resize_rx,
            move |chunk| {
                let chunks = Arc::clone(&sent_chunks);
                async move {
                    chunks.lock().unwrap().push(chunk);
                    Ok::<(), &'static str>(())
                }
            },
            |_| async { Ok::<(), &'static str>(()) },
        )
        .await;

        assert_eq!(write_result, Ok(()));
        assert!(resize_errors.is_empty());
        assert_eq!(chunks.lock().unwrap().as_slice(), &[expected]);
    }

    #[test]
    fn interactive_small_packets_flush_immediately() {
        assert!(should_flush_immediately(true, 1));
        assert!(should_flush_immediately(true, 256));
        assert!(!should_flush_immediately(true, 0));
        assert!(!should_flush_immediately(true, 257));
        assert!(!should_flush_immediately(false, 32));
    }

    #[test]
    fn file_transfer_events_keep_total_bytes_across_finalization() {
        let progress = FileTransferEvent::progress(7, "pane-a", 3, 32768, 131072);
        let finalizing = FileTransferEvent::finalizing(7, "pane-a", 3, 131072, 131072);
        let completed = FileTransferEvent::completed(7, "pane-a", 3, 131072, 131072);

        assert_eq!(progress.kind, "progress");
        assert_eq!(progress.transferred_bytes, "32768");
        assert_eq!(progress.total_bytes, "131072");
        assert_eq!(finalizing.kind, "finalizing");
        assert_eq!(finalizing.total_bytes, "131072");
        assert_eq!(completed.kind, "completed");
        assert_eq!(completed.transferred_bytes, "131072");
    }

    #[test]
    fn callback_retry_that_later_queues_is_not_a_delivery_failure() {
        let mut metrics = OutputDeliveryMetrics {
            received_bytes: 4,
            ..OutputDeliveryMetrics::default()
        };
        assert!(!metrics.record_callback_attempt(Status::QueueFull, 4));
        assert!(metrics.record_callback_attempt(Status::Ok, 4));
        assert_eq!(metrics.callback_retries, 1);
        assert_eq!(metrics.napi_queued_bytes, 4);
        assert_eq!(metrics.final_delivery_failures, 0);
        assert_eq!(metrics.final_delivery_failed_bytes, 0);
        assert!(metrics.summary(false, false).contains("callbackRetries=1"));
        assert!(metrics.summary(false, false).ends_with("final=false"));
    }

    #[test]
    fn exhausted_final_delivery_records_events_and_bytes() {
        let mut metrics = OutputDeliveryMetrics {
            received_bytes: 7,
            ..OutputDeliveryMetrics::default()
        };
        assert!(!metrics.record_callback_attempt(Status::Closing, 7));
        metrics.record_final_delivery_failure(7);
        assert_eq!(metrics.callback_retries, 1);
        assert_eq!(metrics.napi_queued_bytes, 0);
        assert_eq!(metrics.final_delivery_failures, 1);
        assert_eq!(metrics.final_delivery_failed_bytes, 7);
        assert!(metrics
            .summary(false, true)
            .contains("finalDeliveryFailures=1"));
        assert!(metrics
            .summary(false, true)
            .contains("finalDeliveryFailedBytes=7"));
        assert!(metrics.summary(false, true).ends_with("final=true"));
    }

    #[test]
    fn client_config_enables_bounded_keepalive_detection() {
        let config = build_client_config(30, 3);
        assert_eq!(config.keepalive_interval, Some(Duration::from_secs(30)));
        assert_eq!(config.keepalive_max, 3);
        assert_eq!(AUTH_EXCHANGE_TIMEOUT, Duration::from_secs(30));
        assert_eq!(AUTH_RESPONSE_TIMEOUT, Duration::from_secs(300));
    }

    #[test]
    fn client_config_can_disable_keepalive_probes() {
        let config = build_client_config(0, 7);
        assert_eq!(config.keepalive_interval, None);
        assert_eq!(config.keepalive_max, 7);
    }

    #[test]
    fn keepalive_bounds_reject_unrepresentable_values() {
        assert!(validate_keepalive(3600, 100, "target").is_ok());
        assert!(validate_keepalive(3601, 3, "target").is_err());
        assert!(validate_keepalive(30, 0, "target").is_err());
        assert!(validate_keepalive(30, 101, "target").is_err());
    }

    #[test]
    fn auth_generation_rejects_zero_stale_and_cross_session_values() {
        assert!(is_current_auth_generation(7, 7));
        assert!(!is_current_auth_generation(7, 0));
        assert!(!is_current_auth_generation(7, 6));
        assert!(!is_current_auth_generation(7, 8));
    }

    #[tokio::test]
    async fn auth_exchange_propagates_success_and_failure() {
        let (_disconnect_tx, mut disconnect_rx) = tokio::sync::mpsc::channel(1);
        let completed = wait_for_auth_exchange(
            async { Ok::<u32, &'static str>(41) },
            Duration::from_secs(1),
            &mut disconnect_rx,
        )
        .await;
        assert!(matches!(completed, AuthExchangeResult::Completed(41)));

        let failed = wait_for_auth_exchange(
            async { Err::<u32, &'static str>("rejected") },
            Duration::from_secs(1),
            &mut disconnect_rx,
        )
        .await;
        assert!(matches!(failed, AuthExchangeResult::Failed("rejected")));
    }

    #[tokio::test]
    async fn stalled_auth_exchange_times_out() {
        let (_disconnect_tx, mut disconnect_rx) = tokio::sync::mpsc::channel(1);
        let result = wait_for_auth_exchange(
            pending::<std::result::Result<(), ()>>(),
            Duration::from_millis(1),
            &mut disconnect_rx,
        )
        .await;

        assert!(matches!(result, AuthExchangeResult::TimedOut));
    }

    #[tokio::test]
    async fn stalled_auth_exchange_can_be_cancelled() {
        let (disconnect_tx, mut disconnect_rx) = tokio::sync::mpsc::channel(1);
        disconnect_tx.send(()).await.unwrap();
        let result = wait_for_auth_exchange(
            pending::<std::result::Result<(), ()>>(),
            Duration::from_secs(1),
            &mut disconnect_rx,
        )
        .await;

        assert!(matches!(result, AuthExchangeResult::Cancelled));
    }

    #[tokio::test]
    async fn auth_command_wait_times_out_and_can_be_cancelled() {
        let (_auth_tx, mut auth_rx) = tokio::sync::mpsc::channel(1);
        let (_disconnect_tx, mut disconnect_rx) = tokio::sync::mpsc::channel(1);
        let timed_out = wait_for_auth_command(
            ConnectionLayer::Target,
            &mut auth_rx,
            &mut disconnect_rx,
            Duration::from_millis(1),
        )
        .await;
        assert!(matches!(timed_out, AuthWaitResult::TimedOut));

        let (_auth_tx, mut auth_rx) = tokio::sync::mpsc::channel(1);
        let (disconnect_tx, mut disconnect_rx) = tokio::sync::mpsc::channel(1);
        disconnect_tx.send(()).await.unwrap();
        let cancelled = wait_for_auth_command(
            ConnectionLayer::Target,
            &mut auth_rx,
            &mut disconnect_rx,
            Duration::from_secs(1),
        )
        .await;
        assert!(matches!(cancelled, AuthWaitResult::Cancelled));
    }

    #[tokio::test]
    async fn parallel_auth_command_waits_keep_session_secrets_isolated() {
        let (first_auth_tx, mut first_auth_rx) = tokio::sync::mpsc::channel(1);
        let (second_auth_tx, mut second_auth_rx) = tokio::sync::mpsc::channel(1);
        let (_first_disconnect_tx, mut first_disconnect_rx) = tokio::sync::mpsc::channel(1);
        let (_second_disconnect_tx, mut second_disconnect_rx) = tokio::sync::mpsc::channel(1);
        first_auth_tx
            .send(LayeredAuthMethod {
                layer: ConnectionLayer::Target,
                method: AuthMethod::Password("first-secret".to_string()),
            })
            .await
            .unwrap();
        second_auth_tx
            .send(LayeredAuthMethod {
                layer: ConnectionLayer::Jump,
                method: AuthMethod::Password("second-secret".to_string()),
            })
            .await
            .unwrap();

        let (first, second) = tokio::join!(
            wait_for_auth_command(
                ConnectionLayer::Target,
                &mut first_auth_rx,
                &mut first_disconnect_rx,
                Duration::from_secs(1),
            ),
            wait_for_auth_command(
                ConnectionLayer::Jump,
                &mut second_auth_rx,
                &mut second_disconnect_rx,
                Duration::from_secs(1),
            )
        );

        match first {
            AuthWaitResult::Command(AuthMethod::Password(ref value)) => {
                assert_eq!(value, "first-secret");
            }
            _ => panic!("first session did not receive its own command"),
        }
        match second {
            AuthWaitResult::Command(AuthMethod::Password(ref value)) => {
                assert_eq!(value, "second-secret");
            }
            _ => panic!("second session did not receive its own command"),
        }
    }

    #[tokio::test]
    async fn auth_command_wait_discards_a_late_response_for_the_other_layer() {
        let (auth_tx, mut auth_rx) = tokio::sync::mpsc::channel(2);
        let (_disconnect_tx, mut disconnect_rx) = tokio::sync::mpsc::channel(1);
        auth_tx
            .send(LayeredAuthMethod {
                layer: ConnectionLayer::Jump,
                method: AuthMethod::Password("late-jump-secret".to_string()),
            })
            .await
            .unwrap();
        auth_tx
            .send(LayeredAuthMethod {
                layer: ConnectionLayer::Target,
                method: AuthMethod::Password("target-secret".to_string()),
            })
            .await
            .unwrap();

        let result = wait_for_auth_command(
            ConnectionLayer::Target,
            &mut auth_rx,
            &mut disconnect_rx,
            Duration::from_secs(1),
        )
        .await;

        match result {
            AuthWaitResult::Command(AuthMethod::Password(ref value)) => {
                assert_eq!(value, "target-secret");
            }
            _ => panic!("target did not receive its own authentication response"),
        }
    }

    #[tokio::test]
    async fn host_key_wait_discards_a_late_response_for_the_other_layer() {
        let (decision_tx, decision_rx) = tokio::sync::mpsc::channel(2);
        let receiver = Arc::new(tokio::sync::Mutex::new(decision_rx));
        decision_tx
            .send(HostKeyDecision {
                layer: ConnectionLayer::Jump,
                accepted: false,
            })
            .await
            .unwrap();
        decision_tx
            .send(HostKeyDecision {
                layer: ConnectionLayer::Target,
                accepted: true,
            })
            .await
            .unwrap();

        assert!(wait_for_host_key_decision(ConnectionLayer::Target, &receiver).await);
    }

    #[tokio::test]
    async fn stalled_connect_times_out() {
        let (_disconnect_tx, mut disconnect_rx) = tokio::sync::mpsc::channel(1);
        let (_progress_tx, mut progress_rx) = tokio::sync::mpsc::channel(1);
        let result = wait_for_connect(
            pending::<std::result::Result<(), ()>>(),
            Duration::from_millis(1),
            &mut disconnect_rx,
            &mut progress_rx,
        )
        .await;

        assert!(matches!(result, ConnectWaitResult::TimedOut));
    }

    #[tokio::test]
    async fn stalled_connect_can_be_cancelled() {
        let (disconnect_tx, mut disconnect_rx) = tokio::sync::mpsc::channel(1);
        let (_progress_tx, mut progress_rx) = tokio::sync::mpsc::channel(1);
        disconnect_tx.send(()).await.unwrap();
        let result = wait_for_connect(
            pending::<std::result::Result<(), ()>>(),
            Duration::from_secs(1),
            &mut disconnect_rx,
            &mut progress_rx,
        )
        .await;

        assert!(matches!(result, ConnectWaitResult::Cancelled));
    }

    #[tokio::test]
    async fn host_key_prompt_pauses_connect_timeout() {
        let (disconnect_tx, mut disconnect_rx) = tokio::sync::mpsc::channel(1);
        let (progress_tx, mut progress_rx) = tokio::sync::mpsc::channel(1);
        progress_tx
            .send(ConnectProgress::WaitingForUser)
            .await
            .unwrap();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(10)).await;
            disconnect_tx.send(()).await.unwrap();
        });

        let result = wait_for_connect(
            pending::<std::result::Result<(), ()>>(),
            Duration::from_millis(1),
            &mut disconnect_rx,
            &mut progress_rx,
        )
        .await;

        assert!(matches!(result, ConnectWaitResult::Cancelled));
    }

    #[tokio::test]
    async fn file_transfer_observes_keepalive_timeout_from_connection_driver() {
        let result = tokio::time::timeout(
            Duration::from_millis(50),
            wait_for_file_transfer(
                pending::<std::result::Result<(u64, u64), transfer::TransferFailure>>(),
                ready(Err(russh::Error::KeepaliveTimeout)),
            ),
        )
        .await
        .expect("connection completion should stop a pending transfer");

        assert!(matches!(
            result,
            FileTransferWaitResult::ConnectionEnded(Err(russh::Error::KeepaliveTimeout))
        ));
    }

    #[tokio::test]
    async fn completed_file_transfer_wins_over_simultaneous_connection_close() {
        let result = wait_for_file_transfer(
            ready(std::result::Result::<(u64, u64), transfer::TransferFailure>::Ok((7, 9))),
            ready(Ok(())),
        )
        .await;

        assert!(matches!(
            result,
            FileTransferWaitResult::Completed(Ok((7, 9)))
        ));
    }
}
