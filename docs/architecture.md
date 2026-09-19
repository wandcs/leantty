# LeanTTY Architecture

> Status: current implementation baseline
>
> Last updated: 2026-09-19
>
> Governing rules: [`project-principles.md`](project-principles.md)

This document describes the architecture that exists in the current source
tree, including the 1.6 Mosh integration. It is not a proposal for HSL or a
generic transport framework, nor evidence of a published 1.6 release.
Feature-specific future designs live in [`design/`](design/README.md), and only
[`next-work.md`](next-work.md) authorizes current work.

The 1.7 [terminal/session boundary design](design/terminal-session-boundaries.md)
separates session control, native VT state and GPU surfaces. Both debug and
release use the native renderer. Web terminal assets, the Bridge protocol and
serialized framebuffer recovery have been removed. This source state does not
claim formal release acceptance; evidence and remaining gates are in Next Work.

`TerminalSurfaceController` exposes input, resize, ready, pressure and system
effect callbacks. `SessionViewModel` owns local commands, authentication,
SSH/Mosh routing and connection-boundary output ordering.

### Native terminal

`PaneRuntime` owns `NativeTerminalController` across XComponent lifetimes. One
serial C++ worker owns the pinned Ghostty VT, official text/font objects and
EGL/GLES surface. Surface loss retains the VT; close stops input, drains admitted
commands and joins the worker before releasing the Pane. A regular VT with approximately 10,000 physical history lines and
a separate zero-history temporary Mosh VT preserve page ownership.
The first Mosh output frame begins its temporary page before admission, even
when it precedes the connection notification; the later notification is
idempotent. End-page and local completion output retain queue order.

Output is copied before admission: 256 KiB chunks, a 1 MiB native outstanding
byte limit, and a 2 MiB ArkTS pending/inflight limit. A zero admission result
accepts no bytes. Consumption events release pressure and complete ordered
barriers independently of frame presentation. Rejected capacity is retained in
ArkTS; missing callback progress or overflow fails visibly and stops the Session.
Input generations fence focus/authentication changes; replies retain their
original Session output generation and never enter local command routing.

The window/workspace owner sends native visibility directly through the Pane's
surface controller, including when backgrounding has suspended ArkUI component
updates. The VT worker pauses rendering, cursor blink and drag scroll for hidden
Panes while consuming output and producing replies. Visibility is independent of
focus so both split Panes render. Returning revalidates the Surface and advances
the display generation; only its successful frame can reopen input admission.

NativeWindow and EGL resources belong to the worker. Official text-line drawing
rasterizes graphemes into a bounded 2048-square RGBA atlas (16 MiB, at most 4096
cached tiles); GLES submits dirty frames with no idle redraw loop. The system
IME attaches only to a presented, focused Pane. Its preview stays local and its
committed text uses Ghostty's current-mode key encoder. The same worker owns
selection gestures, bounded clipboard formatting, history search and mouse
encoding. ArkUI owns the transient search input and IME preview; queries never
enter the session. Complete OSC frames retain their original output owner and
pass the existing clipboard, attention and user-activated link policy.
ArkUI's pre-IME key handler leaves ordinary text and editing keys to the IME;
the post-IME handler forwards keys returned unconsumed, preferring the platform
Unicode value. This preserves candidate selection without dropping digits in
IME modes that do not commit them through the text callback.
After local renderer retries report an unavailable surface, the controller
invalidates input and requests the existing Pane surface rebuild at most once
per 30 seconds. It retains the VT and Session; replacement presentation restores
input readiness. Surface identities reject late destruction of the old display.
NativeWindow creation rejection reports display unavailability through the same
path without terminating the VT worker. Invalid arguments and core/queue failures
remain errors; this distinction does not turn unrelated failures into recovery.
Repeated failures within that interval remain visibly unavailable; this bounded
rebuild is not evidence of recovery from every persistent driver failure.
Development replacement checks are recorded in the
[migration audit](native-terminal-migration-1.7.md). Formal candidate and release
gates remain separate in `next-work.md`.

## System shape

```text
HarmonyOS UIAbility / App Shell
  └─ ApplicationWorkspace (process scope)
      └─ AppViewModel
          └─ Tab
              └─ one or two Pane objects
                  └─ PaneRuntime
                      ├─ SessionViewModel
                      │   ├─ local ltty command line and interaction mode
                      │   ├─ SshSession lifecycle
                      │   ├─ SshClient → N-API → Rust/russh → SSH server
                      │   └─ MoshClient → N-API → SSH bootstrap + Rust/mosh-client → UDP server
                      └─ TerminalSurfaceController
                          └─ NativeTerminalController → N-API → Ghostty VT + EGL/GLES

System services
  ├─ HarmonyOS Asset Store and Preferences
  ├─ application-private files
  ├─ clipboard and Downloads
  ├─ window and lifecycle APIs
  └─ system browser
```

The core ownership rule is `App Shell → Tab → Pane → Session`. An XComponent,
array index, visible label or currently selected tab is never the identity of a
Session.

## Component responsibilities

| Component | Source | Owns | Must not own |
| --- | --- | --- | --- |
| UIAbility and page | `entryability/EntryAbility.ets`, `pages/Index.ets` | Application/window lifecycle, rendering the process workspace, active focus, UI callback binding and system integration | Workspace or Session ownership, SSH protocol rules or terminal byte interpretation |
| ApplicationWorkspace | `viewmodel/ApplicationWorkspace.ets` | The one process-scoped AppViewModel and stable split ratio across WindowStage/Page recreation | Persistence across process termination, protocol state or terminal rendering policy |
| AppViewModel | `viewmodel/AppViewModel.ets` | Stable Tab/Pane identifiers, active Tab/Pane, the Pane/runtime registry and ordered runtime disposal | SSH protocol state, terminal rendering policy or system focus adaptation |
| PaneRuntime | `viewmodel/PaneRuntime.ets` | The pairing and lifecycle of one Pane identity, SessionViewModel and TerminalSurfaceController | Cross-pane state or workspace ordering |
| SessionViewModel | `viewmodel/SessionViewModel.ets` | Local command/prompt interaction, terminal presentation and routing user actions to the owning Session | SSH lifecycle transitions, global Tab ordering or terminal rendering internals |
| SshSession | `model/ssh/SshSession.ets` | The allowed connection, authentication, host-verification, connected, failure, close, reconnect and transfer-handoff transitions for one Pane | Prompt text, terminal rendering or native transport decoding |
| SshClient | `model/ssh/SshClient.ets` | One N-API session handle, native event decoding and request/response correlation | UI text, Tab/Pane ownership or persistent asset policy |
| MoshClient | `model/mosh/MoshClient.ets` | One native Mosh handle, structured event correlation and shared bounded close completion | Protocol timers, prediction policy or terminal-page interpretation |
| Rust Mosh layer | `leantty_ssh/src/lib.rs` | SSH bootstrap, validated IPv4 endpoint, one library Session, ordered input, output flow and close/cancel | Pane selection, UI text or a second reachability timer |
| Rust SSH layer | `leantty_ssh/src/lib.rs` | Ordered jump/target connection phases, host-key callback, authentication transport, PTY, SSH channel, byte stream, cancellation, keepalive and route cleanup | ArkUI state and user-facing decisions |
| TerminalSurfaceController | `model/terminal/TerminalSurfaceController.ets` | Pane-owned terminal interaction and display attachment | SSH authentication or persistent terminal history |
| NativeTerminalController | `model/terminal/NativeTerminalController.ets` | Bounded command admission, callback generations, IME and display lifecycle | SSH state, credentials or persistence |
| Native terminal worker | `cpp/terminal/` | Ghostty VT, page/viewport, text layout and EGL/GLES presentation | Session routing or application persistence |
| DurableStateManager | `model/persistence/DurableStateManager.ets` | The mapping between durable asset names and runtime projections | Session/terminal restoration |

## Workspace and Session ownership

`AppViewModel` is the authoritative workspace model:

- a Tab owns `panes[]` and one `activePaneId`;
- a Pane has a stable ID and owns exactly one runtime;
- at most two Panes are allowed in a Tab;
- each runtime owns its own `SessionViewModel`, active SSH or Mosh client and
  native terminal controller; and
- removing a Pane or Tab unlinks and disposes its runtime through the same
  owner, so switching or closing cannot reuse another Pane's connection or terminal
  state.

`ApplicationWorkspace` owns one `AppViewModel` for the lifetime of the process.
HarmonyOS may rebuild the WindowStage and `Index` page while leaving that process
and its active Sessions alive, so page destruction only detaches surfaces and
UI callbacks. A replacement page reuses the same workspace, rebinds callbacks
and attaches new surfaces; it must not create or restore a second model.

`Index.ets` keeps `tabs` and `activeTabIndex` only as ArkUI rendering
projections. Existence, active identity, runtime lookup and destruction always
delegate back to the process-owned `AppViewModel`. The page routes focus and
system events and retains only the surfaces required by the current tab, a short
warm-tab policy or an active connected session. Explicit controlled application
close disconnects all runtimes before marking the durable generation clean.
Process termination releases the in-memory workspace; a later process
reconstructs only the bounded durable structure described below and never
restores a Session or terminal contents.

## Connection event chain

```text
keyboard input at ltty>
  → CommandParser / SshConfig and optional ProxyJump resolution
  → one resolved SshConnectionSpec snapshot owned by SshSession
  → SessionViewModel.connect; reconnect reuses the same snapshot
  → SshConnectOptions mapping at the SshClient boundary
  → SshClient.connect
  → N-API sshConnect
  → Rust/run_session sequences jump route, target route and interactive shell phases
  → Rust/russh jump/target TCP + SSH handshake
  → independently scoped host-key decision for each layer
  → server-directed private-key, keyboard-interactive and password authentication
  → PTY request + remote shell
  → structured lifecycle event consumed by SshSession
  → SessionViewModel presents the accepted event
  → raw output callback
  → TerminalSurfaceController
  → NativeTerminalController ordered command queue
  → native VT worker and GPU display
```

`run_session` is only the phase orchestrator. Each connection phase returns one
structured stop reason, `SessionRoute` owns the target/jump transport pair and
performs failure cleanup once, and the connected phase produces the single
final transport-close event. This keeps direct and ProxyJump routes on the same
error and cleanup contract without hiding protocol behavior behind another
transport abstraction.

`SshConnectionSpec` is the single ArkTS value object for a resolved connection:
target and jump endpoint labels, ports, users, named identities, connect
timeouts, keepalive policy and verbose mode. `CommandParseResult` adds only
parser status to that value, `SshSession` owns a defensive copy for reconnect,
and concrete private-key paths are resolved while mapping the value to
`SshConnectOptions`. No second field-by-field reconnect request is maintained.

Native IME and key events become terminal input after focus and generation
validation. `SessionViewModel` routes the input to local commands, authentication
or the connected Session. Terminal replies carry the original remote owner.

The native worker reports its first real grid and subsequent column/row changes.
The Session dispatches those dimensions to SSH or Mosh; pixel-only movement does
not trigger redundant remote resize notifications.

### Mosh connection

`mosh` resolves the existing Host and Identity configuration, then uses direct
SSH for host verification, authentication and a bounded `mosh-server` bootstrap
command. `MoshClient` binds the resulting native handle to the Pane's existing
`SshSession` lifecycle owner. Rust validates bootstrap output and the IPv4 UDP
endpoint before creating one `mosh-client` Session; this is a concrete path,
not a generic Transport layer. ProxyJump and remote commands are rejected.

The library owns prediction, initial attachment timeout and reachability.
LeanTTY reads the independent observer's current state, then consumes changes.
`Interrupted` is a warning, not an exit; `Responsive` restores the connected
presentation without replacing the Session. Initial attachment times out after
15 seconds. Native connected-state polling stops after the first connection.

Every Mosh Session uses one temporary terminal page, entered before its first
output. All repaints and Surface replay remain on that page. Close, cancellation,
failure and Pane disposal drain accepted output before restoring the original
page; generation/owner checks reject late callbacks. LeanTTY does not infer
Vim or less lifecycles from state-sync output. The library's graceful close has
a four-second ACK bound; immediate stop uses cancellation instead.

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
cross ArkTS, the terminal renderer or terminal output. Local paths stay beneath
the authorized Downloads root and use no-follow descriptor ownership. A
transfer never reuses the interactive PTY Session, and transfer, Pane and
generation identifiers reject late events after cancellation or teardown.
Temporary files are exclusive and task-owned; only an observed task may clean
its own partial object. The Pane's `SshSession` also consumes transfer
authentication and host-verification events so prompt handoff uses the same
allowed lifecycle transitions; byte progress and finalization remain owned by
`FileTransferLifecycle`.

## Host-key and authentication boundaries

Rust performs SSH transport and reports the received host-key state. The
Session owns the user interaction. An unknown key is not committed until the
user accepts it and `DurableStateManager.commitKnownHostLine` completes. A
changed key stops the connection; it is never replaced automatically.

Known-host reads and complete read/modify/write transactions share one queue in
`DurableStateManager`. Platform storage calls yield through the official async
Asset Store API; chunk verification and pointer publication still precede file
projection and acceptance. Background GC joins that queue so it cannot delete
an in-flight generation. Post-commit cleanup names only the immutable predecessor,
never every generation other than an old captured "current" value.

While trust is being saved, the Session shows pending feedback and accepts
Ctrl-C but no further answers. Mode transitions and disconnect invalidate the
pending decision before any async completion can resume a client. Local
`ssh-keygen -F/-R` operations also wait for the queue; their output is scoped to
the original terminal boundary, and new local input waits for completion.

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
layered failures and bounded output metrics. A terminal phase failure carries its
safe diagnostic status/reason in that same control event, so `SshClient` emits
the diagnostic before ending the Session without relying on cross-queue order.
PTY bytes, close state and nonterminal diagnostics use `TransportEvent`.
`SshClient` validates those native records and
emits one `SshClientMessage` to its Session owner; business state is never
reconstructed from string prefixes, embedded layer labels or JSON payloads.

## Terminal output and system effects

SSH and Mosh output enters the same bounded native command queue. VT consumption
releases pressure and completes ordered barriers; presentation is separately
acknowledged by the current display generation. Overflow or stalled progress
fails visibly rather than silently discarding bytes. Mosh input rejection stops
the Session and restores the retained local page before reporting the failure.

Remote bytes, links and OSC payloads remain untrusted. The native terminal
validates the bounded supported OSC effects; ArkTS checks the current Session
owner before clipboard, notification or browser effects. Terminal replies never
become local commands. Notifications discard remote title/body after validation;
OSC 52 supports clipboard writes only. Shared browser and file safety remain in
their owning services.

Native drawing leaves default-background cells transparent so the application
surface owns transparency. Explicit cell colors, inverse colors, glyphs,
selection and search decorations retain their own rendering semantics. EGL/GLES
is required. Display recovery retains the VT and rebuilds the GPU surface;
there is no DOM or CPU fallback.

## Lifecycle and terminal recovery

The Pane owns the VT independently of its XComponent. Detach or display recovery
keeps parsed history, modes, selection and page state in that worker; reattach
renders the retained state without serialized snapshots or output replay.
Hidden terminals consume output while rendering is suspended. Pane disposal
closes its Session and joins the worker before releasing resources.

Process termination does not preserve terminal contents or remote Sessions.
Durable shell work belongs in tmux or screen. The UIAbility publishes visibility,
enables system geometry auto-save and asks before terminating active Sessions;
the application does not replay its own window rectangle.

`PaneInfo.needsAttention` remains the sole authority for BEL attention. A
background system notification is only a removable external side effect: it
binds the first eligible stable Pane ID in one continuous hidden-window episode
and stores no Session, terminal output or second attention state. `EntryAbility`
passes a validated notification Want into short-lived `AppStorage`; `Index`
then resolves the current workspace and returns only when that Pane still
exists and still owns attention. Foreground return, attention handling and Pane
destruction cancel the side effect. A stale Want can open the application but
cannot reconstruct or redirect terminal ownership.

This notification path is not a background execution owner. When HarmonyOS
suspends application execution after the whole window is hidden, later SSH output can be
buffered but its BEL/OSC attention cannot be parsed and published until the app
runs again. LeanTTY does not add a resident service, foreground disguise or a
second lifecycle owner to bypass that lifecycle; durable remote work
still belongs in tmux or screen, and system notification is best effort.

## Persistent state

`UnexpectedExitRecoveryStore` owns one bounded, versioned Preferences record for
the current installation. At startup it classifies the previous generation as
clean or unclean, then marks the new generation running before UI content loads.
An unclean record restores only Tab order, one or two Panes per Tab, active
positions and split ratio. `AppViewModel` reconstructs fresh generation-scoped
Tab/Pane identities; all Panes start as local `ltty`, `IDLE`, without attention.
Normal application close marks the generation clean only after Pane runtimes
disconnect. Host data, titles, terminal contents, commands, credentials and
Session state never enter this record.

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
projections. Startup initializes the durable authority and loads font size;
SSH projections and verified-key loading are prepared lazily before the first
command that needs them. Writes to Host configuration, host trust, keys and font
size go through the durable authority. The first run after the storage change
migrates verified legacy files and Preferences; later runs remove projections
that no longer have a durable authority.

After SSH preparation, command models share one application-level `SshConfig`.
Host lookup, completion, connection parsing and edits therefore use the same
committed configuration across existing Panes. Command text and history remain
Pane-owned. Host edits and config imports commit synchronously through
`DurableStateManager`; a failed commit restores the previous in-memory view as
well as the projection rollback enforced by `SshConfigCommitPolicy`. Downloads
authorization may yield before import/export, so those operations use the shared
configuration current when authorization completes.

Persistent assets are configured to survive an ordinary uninstall for the same
application identity; exact asset/signature/lifecycle behavior remains a
physical-device release gate. Passwords, passphrases, command history, Session
state and terminal contents are never durable recovery data. Tab/Pane structure
uses only the separate app-private recovery record above; transparency uses
local Preferences. Neither is an uninstall-surviving Asset Store asset.
HarmonyOS owns main-window geometry through `setWindowRectAutoSave`; LeanTTY no
longer maintains a second durable rectangle, and geometry is not retained
across uninstall/reinstall.

## System-service boundaries

- Clipboard writes use the HarmonyOS local-device pasteboard. Clipboard reads
  occur for paste; accepted OSC 52 can write but never read the clipboard.
- Key/config export and file-transfer local I/O use the authorized Downloads
  boundary and refuse explicit overwrite; file transfer additionally uses
  no-follow descriptors and task-owned temporary files.
- The native terminal executes no remote JavaScript and has no WebView or
  network/file navigation surface. The standalone local HTML guide remains packaged.
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
