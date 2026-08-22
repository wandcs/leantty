# LeanTTY Architecture

> Status: current implementation baseline
>
> Last updated: 2026-08-22
>
> Governing rules: [`project-principles.md`](project-principles.md)

This document describes the architecture that exists in the current source
tree. It is not a proposal for Mosh, HSL or a generic transport framework.
Feature-specific future designs live in [`design/`](design/README.md), and only
[`next-work.md`](next-work.md) authorizes current work.

## System shape

```text
HarmonyOS UIAbility / App Shell
  └─ AppViewModel
      └─ Tab
          └─ one or two Pane objects
              └─ PaneRuntime
                  ├─ SessionViewModel
                  │   ├─ SshSession state
                  │   ├─ local ltty command line
                  │   └─ SshClient
                  │       └─ N-API → Rust/russh → SSH server
                  └─ TerminalSurfaceController
                      ├─ TerminalOutputBuffer
                      └─ TerminalBridge → ArkWeb/xterm.js

System services
  ├─ HarmonyOS Asset Store and Preferences
  ├─ application-private files
  ├─ clipboard and Downloads
  ├─ window and lifecycle APIs
  └─ system browser
```

The core ownership rule is `App Shell → Tab → Pane → Session`. A WebView,
array index, visible label or currently selected tab is never the identity of a
Session.

## Component responsibilities

| Component | Source | Owns | Must not own |
| --- | --- | --- | --- |
| UIAbility and page | `entryability/EntryAbility.ets`, `pages/Index.ets` | Application/window lifecycle, rendering the workspace, active focus and system integration | SSH protocol rules or terminal byte interpretation |
| AppViewModel | `viewmodel/AppViewModel.ets` | Stable Tab/Pane identifiers, active Tab/Pane and pane-visible state | Network connections or WebView instances |
| PaneRuntime | `pages/Index.ets` | The pairing of one Pane identity with one SessionViewModel and TerminalSurfaceController | Cross-pane state |
| SessionViewModel | `viewmodel/SessionViewModel.ets` | Local prompt modes, connection/authentication flow, error recovery and routing between SSH and the terminal surface | Global Tab ordering or Web rendering internals |
| SshClient | `model/ssh/SshClient.ets` | One N-API session handle, native event decoding and request/response correlation | UI text, Tab/Pane ownership or persistent asset policy |
| Rust SSH layer | `leantty_ssh/src/lib.rs` | russh connection, host-key callback, authentication transport, PTY, SSH channel, byte stream, cancellation and keepalive | ArkUI state and user-facing decisions |
| TerminalSurfaceController | `model/terminal/TerminalSurfaceController.ets` | One terminal surface lifecycle, in-process snapshot and detached output buffer | SSH authentication or persistent terminal history |
| TerminalBridge | `model/bridge/TerminalBridge.ets` | Validated ArkTS/ArkWeb message transport, output acknowledgements and backpressure | Session business state or terminal-content repair |
| ArkWeb/xterm.js | `resources/rawfile/terminal.html` | Terminal emulation, rendering, local selection, input encoding and size measurement | SSH state, credentials or application persistence |
| DurableStateManager | `model/persistence/DurableStateManager.ets` | The mapping between durable asset names and runtime projections | Session/terminal restoration |

## Workspace and Session ownership

`AppViewModel` is the authoritative workspace model:

- a Tab owns `panes[]` and one `activePaneId`;
- a Pane has a stable ID and owns exactly one runtime;
- at most two Panes are allowed in a Tab;
- each runtime owns its own `SessionViewModel`, SSH client, output buffer and
  Web terminal controller; and
- closing or switching one Pane cannot reuse another Pane's SSH or terminal
  state.

`Index.ets` renders by stable Pane identity, routes focus and interaction to the
active Pane, and retains only the surfaces required by the current tab, a short
warm-tab policy or an active connected session. The workspace model does not
persist across application termination.

## Connection event chain

```text
keyboard input at ltty>
  → CommandParser / SshConfig and optional ProxyJump resolution
  → SessionViewModel.connect
  → SshClient.connect
  → N-API sshConnect
  → Rust/russh jump/target TCP + SSH handshake
  → independently scoped host-key decision for each layer
  → server-directed private-key, keyboard-interactive and password authentication
  → PTY request + remote shell
  → raw output callback
  → SessionViewModel
  → TerminalSurfaceController
  → binary TerminalBridge packet
  → xterm.js
```

Terminal input follows the reverse path. xterm sends terminal data through the
versioned Bridge, `SessionViewModel` decides whether the current mode consumes
it as a local command, host-key answer, password/passphrase or connected PTY
input, and only connected PTY bytes reach Rust.

Resize starts with the dimensions measured by xterm. The result crosses the
validated Bridge, is routed to the owning Session, and becomes an SSH PTY
resize. UI estimates are not an authoritative terminal size.

## File-transfer event chain

At an idle `ltty>` prompt, `put/get` remains owned by the current Pane and uses
an independent, short-lived SFTP Session:

```text
local put/get command
  → CommandParser / Host and Identity resolution
  → Pane-owned transfer lifecycle
  → DownloadsAccessManager resolves system access
  → TransferFileManager opens and owns a bounded local file descriptor
  → FileTransferClient / N-API
  → Rust SFTP session and native byte stream
  → task-owned temporary file
  → no-overwrite final commit
  → structured progress/final result to the owning Pane
```

File bytes move only between the local descriptor and Rust/SFTP; they do not
cross ArkTS, the WebView Bridge or terminal output. Local paths stay beneath
the authorized Downloads root and use no-follow descriptor ownership. A
transfer never reuses the interactive PTY Session, and transfer, Pane and
generation identifiers reject late events after cancellation or teardown.
Temporary files are exclusive and task-owned; only an observed task may clean
its own partial object.

## Host-key and authentication boundaries

Rust performs SSH transport and reports the received host-key state. The
Session owns the user interaction. An unknown key is not committed until the
user accepts it and `DurableStateManager.commitKnownHostLine` completes. A
changed key stops the connection; it is never replaced automatically.

The current Rust session supports password, verified private-key and
keyboard-interactive authentication, including banners, multiple prompts,
multiple rounds, `remaining_methods` and `partial_success`. Jump and target
layers keep independent host-key and authentication state. Passwords,
passphrases and non-echoing responses cross ArkTS/N-API only for the active
Session and are cleared after submission or cancellation; Rust zeroizes secret
values where supported.

Native authentication prompts use structured `AuthEvent` records carrying the
Session generation, layer and round. Interactive Sessions and file transfers
share a structured `ControlEvent` for connection state, host-key decisions,
layered failures and bounded output metrics. PTY bytes, close state and safe
diagnostics use `TransportEvent`. `SshClient` validates those native records and
emits one `SshClientMessage` to its Session owner; business state is never
reconstructed from string prefixes, embedded layer labels or JSON payloads.

## Terminal Bridge and output flow

The control protocol is `H2|direction|channel|kind|payload` with explicit
direction, channel and message-kind allowlists. Terminal output uses binary
packets containing a magic value, sequence and byte length so raw SSH bytes do
not need to be rewritten as control text.

`TerminalBridge` limits in-flight messages and applies high/low-water
backpressure. xterm acknowledges rendered output; backpressure propagates to
the owning SSH session instead of letting unbounded output accumulate. If the
hard pending-data limit is nevertheless exceeded, the rejected bytes are
counted and logged as dropped output; that path must not be treated as complete
delivery.

Remote output, terminal titles, OSC sequences and Bridge messages are untrusted
input. xterm handles terminal emulation, while ArkTS validates the limited
system effects that can leave the terminal surface, such as clipboard writes
and URL opens.

## Lifecycle and terminal recovery

`TerminalSurfaceController` owns an in-memory framebuffer snapshot and output
received while its ArkWeb surface is detached. Before a surface is rebuilt, the
latest requested snapshot is committed; after attach, the snapshot is restored
before detached output is flushed. Clipboard, title and bell side effects are
not serialized into the framebuffer checkpoint.

This is renderer recovery, not Session persistence:

- the snapshot and detached-output buffer live only in the application process;
- application termination and reinstall do not restore terminal contents;
- an SSH disconnect remains visible and returns through the defined recovery
  path; and
- durable shell work belongs in a remote tool such as tmux or screen.

The UIAbility records foreground/background state, captures terminal
checkpoints before relevant surface teardown, restores window geometry, and
asks before terminating active sessions.

## Persistent state

The HarmonyOS Asset Store is the long-term authority for:

- OpenSSH `config`;
- OpenSSH `known_hosts`;
- every verified private/public key pair;
- terminal font size.

`DurableAssetStore` writes encrypted persistent records in 768-byte chunks. A
versioned manifest contains path, generation, chunk count, byte count and
SHA-256. All chunks are written and validated before the pointer is switched;
old/incomplete generations are then collected.

Application-private `.ssh` files and the font-size Preferences value are runtime
projections. At startup, `DurableStateManager` materializes the durable SSH
assets before normal use. Writes to Host configuration, host trust, keys, font
size go through the durable authority. The first run after the storage change
migrates verified legacy files and Preferences; later runs remove projections
that no longer have a durable authority.

Persistent assets are configured to survive an ordinary uninstall for the same
application identity; exact asset/signature/lifecycle behavior remains a
physical-device release gate. Passwords, passphrases, command history,
Tab/Pane/Session state, terminal contents and transparency mode are excluded.
HarmonyOS owns main-window geometry through `setWindowRectAutoSave`; LeanTTY no
longer maintains a second durable rectangle, and geometry is not retained
across uninstall/reinstall.

## System-service boundaries

- Clipboard writes use the HarmonyOS local-device pasteboard. Clipboard reads
  occur for paste; accepted OSC 52 can write but never read the clipboard.
- Key/config export and file-transfer local I/O use the authorized Downloads
  boundary and refuse explicit overwrite; file transfer additionally uses
  no-follow descriptors and task-owned temporary files.
- The embedded ArkWeb terminal has file access, online image access, DOM
  storage, mixed content and zoom disabled. Its packaged CSP still requires
  `unsafe-inline` and `unsafe-eval` for the current xterm bundle.
- Only credential-free HTTP and HTTPS links that pass normalization can be
  handed to the system browser.
- Signing identities, package artifacts and release evidence stay outside the
  source checkout as defined by [`release-process.md`](release-process.md).

## Stable extension rule

Do not introduce a generic Transport, workspace framework, persistence layer or
plugin boundary merely because a proposed feature might need one. Extend this
architecture only when an accepted capability has a real owner and lifecycle,
the change passes the project principles, and its executable work has entered
`next-work.md`.
