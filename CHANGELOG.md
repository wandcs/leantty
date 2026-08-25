# Changelog

## [Unreleased]

## [1.5.0] - In development

### Added

- Added English and Simplified Chinese resources for LeanTTY-owned native UI,
  notifications, accessibility text, terminal search controls and the initial
  offline-guide view. Explicit Chinese system languages use concise Chinese
  UI—including “分屏” rather than “窗格”—while every other or unknown language
  falls back to English. Terminal commands, local technical output and remote
  TTY content remain English or unchanged, and no persistent language setting
  is introduced.
- Added one restrained local notification for terminal attention only
  while the whole LeanTTY window is hidden. Each continuous background episode
  gets at most one notification attempt; later BELs remain visible through the
  existing in-app Pane attention without refreshing or chasing a notification
  the user has ignored or dismissed. The fixed content excludes remote output
  and host data and returns only to the first existing Pane that still owns
  attention; stale clicks merely open the app. Notification permission is
  requested contextually at most once after the first missed background BEL,
  while rejection leaves the terminal and existing in-app attention unchanged.
- Added bounded OSC 9, well-formed OSC 777 and a receive-only OSC 99 attention
  subset at the terminal Web boundary. OSC 99 accepts only complete title/body
  frames with `i/p/e/d` metadata. A bounded `p=?` query receives only the fixed
  `p=title,body` capability plus its echoed query ID; no chunk assembly, actions
  or lifecycle reports are implemented. Accepted sequences discard every remote field,
  then reuse the existing empty-payload Pane attention, notification throttling
  and return path; malformed, incomplete, control-bearing or over-1024-byte
  payloads have no LeanTTY system effect. This does not add background execution:
  notifications from output arriving after HarmonyOS suspends the hidden app
  remain best effort.
- Added a concise bilingual offline Agent workflow and a physical HarmonyOS PC
  compatibility baseline for Codex CLI, OpenCode, Pi Agent and Qwen Code over
  direct SSH and remote tmux. The guide keeps durable work in tmux/screen,
  documents only observed notification, input, clipboard and scrollback
  behavior, and treats late notifications after HarmonyOS suspension as best
  effort instead of adding an Agent task model or background service.
- Added import and use of existing OpenSSH ECDSA P-256, P-384 and P-521
  identities, including encrypted private keys. Imported ECDSA identities reuse
  the existing fingerprint, passphrase, comment, export, durable restart,
  direct/ProxyJump authentication, file-transfer and deletion paths. New-key
  generation remains limited to Ed25519 and RSA-4096.
- Added OpenSSH-compatible `ssh-keygen -c -f <identity>` comment maintenance.
  Encrypted keys request the existing passphrase through masked input before a
  visible new-comment prompt. LeanTTY preserves the fingerprint, public wire
  key, encryption state, passphrase, 0600 private permissions and durable key
  identity while committing one matching private/public comment; empty input
  removes it, and failed projection or durable commits restore the old pair.
- Added controlled `config import <Downloads-file-name>` and `config export
  [<Downloads-file-name>]` commands for one canonical OpenSSH config. Import
  validates before commit, preserves comments, whitespace, line endings,
  repeated Host patterns and unknown source text across later managed Host
  edits, rejects `Include`, `Match`, token expansion and a second unmanaged
  import unless `--replace` is explicit, and rolls the runtime projection back
  if durable commit fails.
  Export uses the existing Downloads authorization and never overwrites an
  existing file.
- Added one-shot `ssh -v` diagnostics for the current Pane and connection
  attempt. LeanTTY shows fixed, redacted jump/target stages and safely
  classifies name resolution, TCP, SSH version and key-exchange failures
  without enabling raw russh logs, persisting diagnostic state or exposing
  hosts, identities, paths, fingerprints, prompts, credentials or terminal
  content. Normal `ssh` and reconnect remain non-verbose by default.
- Added line-start SSH escapes for an active terminal: `~.` disconnects the
  current Pane's Session, `~?` lists only LeanTTY-supported escapes, `~I` shows
  a sanitized target and optional jump route, and `~~` sends one literal
  tilde. Recognition remains local to the current Pane, preserves ordered
  pasted input and leaves ordinary, mid-line and unknown escape text for the
  remote PTY.
- Added `host add|set ... --connect-timeout <1-300|default>` to manage a
  controlled OpenSSH `ConnectTimeout` directive for direct SSH,
  one-hop ProxyJump, reconnect and Host-based `put/get`. LeanTTY applies the
  configured whole-second value to TCP setup and the initial SSH handshake/key
  exchange, reports jump and target timeouts separately, keeps user-driven host
  verification and authentication waits outside the deadline, and retains the
  existing 15-second default when the directive is absent.
- Added controlled `ServerAliveInterval` and `ServerAliveCountMax` Host
  settings for direct SSH, one-hop ProxyJump, reconnect and Host-based
  `put/get`. LeanTTY keeps its existing `30s/3` reliability default, accepts
  intervals `0-3600` seconds (`0` disables probes) and counts `1-100`, applies
  target and named-jump values independently, and reports an encrypted-channel
  keepalive timeout through the existing Session close and reconnect path.

### Fixed

- Kept the selected offline-guide language while following page-internal
  section links. English links such as `Agent workflow` no longer fall back to
  the default Chinese page merely because the target is a child section rather
  than the language page root.
- Rearmed terminal attention delivery when a visible terminal is blurred, so
  an Agent's foreground-ready signal cannot suppress the first later eligible
  background signal; unread Pane state and native background-episode throttling
  remain unchanged.
- Centered the terminal cell grid around one shared 8 px minimum visual inset,
  including the scrollbar gutter, so character-cell rounding no longer leaves
  full-screen TUIs visibly closer to the bottom edge than the left and right
  edges. The scrollbar keeps its 8 px hit area and 2 px visible thumb while the
  fitted grid continues to use the maximum rows and columns allowed by that
  four-edge contract.
- Snapped a floating main-window resize to the nearest whole terminal cell for
  the current font when the user releases the dragged edge. Resizing from the
  left or top keeps the opposite edge fixed, while the fitted grid centers on
  one shared 8 px minimum visual inset including the scrollbar gutter. The
  scrollbar retains its 8 px hit area and 2 px visible thumb.
- Restored standard terminal color semantics under window transparency. LeanTTY
  now applies opacity only to its Chrome and content surfaces while keeping
  application-defined ANSI/TrueColor cell backgrounds opaque, removing the
  renderer alpha override that could separate block glyphs from their matching
  cell background. Its transparent xterm background also retains the fixed
  `#1E1E2E` logical RGB, so OSC 11-aware TUIs no longer derive near-black
  surfaces from transparent black. Default-background dim, italic, underline,
  overline, hyperlink and protected text no longer becomes an opaque theme-color
  block in the WebGL renderer, while real ANSI/256/TrueColor backgrounds remain
  opaque.
- Replaced native SSH control strings and tagged close results with structured
  events shared by interactive Sessions and file transfers. Session/generation,
  jump/target layer, stage, error code, host-key fields and diagnostics now stay
  typed across Rust, N-API and ArkTS instead of being reconstructed from text
  prefixes or JSON, while logs retain only whitelisted metadata.
- Made `key rm` report success only after both the durable key-pair authority
  and application-private projection are absent. Projection or Asset Store
  failures now restore the retained pair where possible, reapply private-key
  protection, show an actionable failure instead of a false deletion, and have
  failure-injection coverage for projection, durable and rollback faults.
- Made an active Host-based file transfer observe the same SSH connection
  driver as an interactive Session. A configured server-alive timeout now
  stops the transfer promptly with a clear network error, removes an owned
  download temporary file and allows an immediate retry instead of waiting for
  the separate SFTP operation timeout.

### Removed

- Removed the unused legacy local command spellings `alias`, `keys` and
  `key show`. Use `host`, `key list` and `ssh-keygen -y -f <identity>`
  respectively. OpenSSH Host aliases and their stored configuration remain
  supported.

## [1.4.0] - 2026-08-19

### Added

- Added one-hop OpenSSH `ProxyJump` connections through either a saved Host or
  the standard `ssh -J <jump> <target>` override. LeanTTY verifies and
  authenticates jump and target hosts independently, carries only the target
  shell through the terminal, reports failures by layer, and keeps cancellation,
  timeout and Pane ownership within the existing SSH Session model. `host
  add|set ... -J <jump>` persists the same setting in the single OpenSSH config;
  `ssh -G` explains the effective jump without exposing secrets. Multi-hop
  chains, `ProxyCommand`, forwarding and a second host or credential store remain
  outside this version.

### Changed

- Reduced cold startup work before the first interactive `ltty>` prompt. SSH
  configuration, known-host and key projection now prepares once after the
  first terminal frame is painted; an SSH-backed command submitted earlier
  waits for that same preparation and then runs normally. Explicit local help
  and exit paths remain immediately available, while durable cleanup is
  deferred to the application background lifecycle without adding a second
  cache or persistent state model.
- On the physical ARM64 HarmonyOS PC, the final 20-sample daily cold-start
  candidate reduced icon-click-to-first-letter paint from the 1.3 P50/P95 of
  2763/2811 ms to 1491/1519 ms (about 46%). Twenty retained-process warm starts
  remained effectively unchanged at 482/499 ms versus 474/494 ms on 1.3.
  In-place 1.3 upgrade, existing SSH assets, readiness failure/retry,
  background completion, renderer rebuild, focus restoration, and a probe-free
  Host/Key/input smoke were verified without weakening key protection.
- Made HarmonyOS the sole owner of restart window geometry, so the system
  starting window and the restored main window use the same saved bounds after
  a normal close. Removed the second durable window-rectangle store and the
  post-content move/resize sequence that caused a visible startup jump; window
  geometry is intentionally no longer retained across uninstall/reinstall.

### Fixed

- Reset remote PTY terminal modes only when an SSH Session releases its Pane's
  Terminal Surface. Alternate buffers, cursor and color changes, mouse/focus
  reporting, bracketed paste and keypad modes remain available inside an active
  Session, while normal exit, error, disconnect and reconnect no longer leak
  them into `ltty>` or the next server. The boundary preserves normal scrollback,
  rejects stale output/reset acknowledgements, and remains isolated across
  renderer recovery, tabs, panes and suspend/wake.

## [1.3.0] - 2026-08-16

**AppGallery review approved; released to users on 2026-08-17.**

### Added

- Added bounded foreground `put` and `get` commands for one file at a time
  between the authorized Downloads tree and an SFTP remote path. Existing
  Downloads subdirectories and explicit trailing-`/` directory targets retain
  the source basename without adding recursive transfer or directory creation.
  Explicit file-name conflicts fail; downloads whose final basename is selected
  by LeanTTY keep both files with a numbered name. Bounded Tab completion covers
  local files/directories, Host aliases and LeanTTY key names without prompting
  for Downloads access or enumerating remote directories. Local paths accept
  `./` as an explicit Downloads root. The first ambiguous Tab opens one
  transient candidate region below the command, the second enters selection,
  Tab/Shift+Tab and all four arrow keys navigate the displayed grid, Enter
  accepts without executing, and Esc restores the real prefix. Once selected,
  a candidate becomes the real command-line text: continued typing, Space,
  Backspace and Delete close the transient region and edit that visible text,
  while another Tab explicitly starts the next completion. Repeating an
  automatically appended directory `/` keeps one separator without opening a
  hidden live-filtering mode.
  The commands reuse existing Host, Identity, authentication and known-host rules,
  support an optional per-command port or identity, and keep file bytes in the
  Rust/native stream instead of ArkTS, ArkWeb or terminal output. A fixed-width
  30-cell line progress meter updates in place with percentage, transferred/total
  size, smoothed live speed and ETA, then exposes the finalizing stage without
  animation or a separate GUI. Its selected line-drawing glyphs are locked to
  the bundled font and covered by Regular/Bold one-cell advance regression tests. Completion
  output includes elapsed time and average speed. Restrained ANSI status colors
  keep text as the source of meaning; a single verified one-cell green dot marks
  successful final commit without resembling an expandable control.
  Each Pane now owns an explicit transfer lifecycle from local preparation
  through finalization and one terminal result; cancellation during Downloads
  preparation cannot later start a native transfer. File-transfer failures map
  to bounded actionable categories without echoing native/server detail, and
  SFTP channel/subsystem setup, session initialization, metadata, open, close,
  rename, cleanup and teardown waits have finite bounds and share the foreground
  cancellation path. Confirmed application termination waits for every Pane's
  existing transfer cancellation and cleanup promise before process exit; normal
  Pane close waits for that same Pane-owned completion path. Downloads permission
  preparation now races each Pane's cancellation without cancelling the shared
  system request, so a late permission result cannot open files or start native
  transfer work for a closed Pane. Completion candidates now reject terminal
  control characters and malformed Unicode before Host, key, file or directory
  names can reach the command line or candidate list.

### Fixed

- Restored the connected SSH Tab identity without remounting the Tab component.
  A connection through an OpenSSH `Host` alias now shows `user@alias`, while a
  direct target shows `user@host`; the stable title is owned by LeanTTY rather
  than untrusted remote OSC title sequences. The ArkUI V1 state path now remains
  linked from the page Tab array through ChromeBar to each observed Tab item, so
  title, connection-state and attention changes repaint with the stable Tab ID.
  Returning from a remote, failed or cancelled connection to the local `ltty>`
  prompt now restores the Tab title to `ltty` instead of retaining a stale Host.
- Unified disconnected local-command output around a lowercase `ltty>` prompt
  in the theme ANSI green, restrained semantic status colors, a one-cell green
  dot for committed writes, quiet query results, and compact two-line errors with
  actionable next steps. Host, key, SSH and file-transfer output now share one
  token owner and sanitize dynamic terminal text without exposing raw exception
  details.
- Clarified the terminal workspace hierarchy with three stable Chrome modes:
  Off remains opaque, Low/Medium share the regular surface set, and
  High/Extreme share the same quiet surfaces at a lower Chrome alpha. The terminal content still follows
  all five transparency levels, while rail, inactive, hovered and active Tab
  persistent surfaces keep a common per-mode alpha so desktop brightness cannot
  collapse their relative hierarchy. Opaque mode stops its active Tab at the
  same `surface0` used by the selected menu row. The two transparent Chrome
  modes compensate differently for their backdrops: Low/Medium use an 80%
  base-to-surface0 inactive blend and a 40% surface0-to-surface1 active blend;
  High/Extreme use surface0 for inactive Tabs and stop active Tabs at 75% toward
  surface1. Both retain separation without returning to the old full
  `surface1` through `overlay0` hierarchy.
- Shifted each non-off transparency preset one step clearer: Low now matches
  the former Medium baseline, Medium matches former High, High matches former
  Extreme. The content curve remains 100/82/72/60/45%, while Chrome uses the
  independent three-mode 100/94/86% mapping needed to keep navigation stable.
- Kept ANSI and true-color cell backgrounds consistent with LeanTTY's
  transparency instead of letting the xterm WebGL renderer force them fully
  opaque. Dense TUI surfaces such as Codex no longer appear as black blocks;
  foreground glyphs stay opaque, and the `Off` window remains fully opaque
  while its explicit cell backgrounds use the strongest bounded renderer alpha.
- Restored ordinary terminal key delivery through ArkWeb after the file-transfer
  keyboard interception change. Left/Right, `Ctrl+P` and other TUI-owned keys
  now reach the remote PTY again, while `Ctrl+C`, Tab, product search and
  workspace shortcuts retain their explicit behavior; `Ctrl+V` once again
  follows the system clipboard paste event instead of being lost before xterm.
- Kept SSH terminal input continuously usable after large writes. The existing
  single writer now has full actor-level regression coverage and supervised
  failure reporting; 1 MiB input is delivered without truncation or reordering,
  and subsequent input, output, resize, explicit disconnect and reconnect remain
  available without adding paste-size prompts, fixed delays or a second input path.
- Physical `Escape` now closes an active terminal search and restores the
  terminal focus on HarmonyOS PC. The Web surface reports only its bounded
  open/composing/closed ownership state, so IME composition gets its first
  `Escape` and ordinary terminal `Escape` remains untouched when search is not
  active.
### Security

- Added no-follow local source opening, native descriptor revalidation,
  exclusive local and remote temporary files, and no-overwrite final commits.
  Existing destination files are never replaced; task-owned partial files are
  cleaned on observed failure or cancellation, and transfer events are scoped
  by transfer, Pane and generation identifiers.
- Kept remote temporary basenames bounded and independent of the requested
  final basename, so valid long remote filenames do not exceed the server's
  per-component limit during an upload.
- Passwords, private-key passphrases and non-echoing keyboard-interactive
  responses now also mask and promptly clear the ArkWeb/xterm helper input.
  The typed Native-to-Web state is restored after renderer attachment, while
  ordinary command input remains accessible; device layout snapshots and logs
  are asserted not to contain temporary credentials.

### Development

- Added repository-only SFTP interoperability and physical-PC acceptance
  fixtures. The production GET-to-Downloads-to-PUT event chain has completed
  SHA-256-exact ARM64 device round trips with both 131,089-byte generated data
  and a 118,349,760-byte caller-provided file. The large-file pass exercised
  directory-target basename derivation, local auto-numbering, Tab completion,
  live progress/speed, finalization and exact cleanup. The acceptance-source
  injector now preserves an existing production `BorrowedFd` import and has a
  regression assertion for import uniqueness. A controlled delayed-SFTP
  physical-PC gate now proves that an in-flight GET cancelled by no-selection
  Ctrl+C returns to IDLE within 436 ms without exposing the numbered final file
  or retaining its task-owned temporary file. Additional delayed-SFTP gates use
  the real application and Pane confirmation dialogs: application close awaits
  one cancelled result and clean IDLE before process exit, while Pane close
  preserves the original process and a surviving Pane; neither path exposes a
  final file or retains local/remote task temporary objects. Controlled stalled-
  preparation gates prove the same behavior before authentication or native
  transfer begins, including absence of late progress, finalizing, or completion
  events. A controlled SFTP write-plus-remove failure gate proves that remote
  cleanup failure emits one actionable `REMOTE_CLEANUP`, returns the Pane to
  IDLE, never exposes the final name, and leaves only the identifiable random
  temporary name described to the user. Transfers now reject a known-size
  source that ends early, and remote GET read failures map to the network
  guidance instead of generic path/permission guidance. A physical-PC gate
  terminates the controlled SSH service after positive GET progress and proves
  one `NETWORK` result, clean IDLE, and no final or temporary local file. A
  compile-time-isolated local cleanup fault gate preserves the primary
  `REMOTE_NOT_FOUND` result, appends the actionable cleanup warning, returns to
  IDLE, never exposes the requested final name, and proves exactly one owned
  `.part` remains until the acceptance fixture removes it. A callback-
  backpressure gate forces a two-event native queue to drop intermediate
  progress while preserving finalization, exactly one completion, clean IDLE,
  no temporary file and a SHA-256-exact 8 MiB GET-to-PUT round trip. Forced-
  termination gates stop the application after positive GET/PUT progress and
   prove that no partial final name is exposed, restart remains usable, and only
   the documented identifiable local or remote temporary file may remain until
   explicit cleanup. A two-Pane late-event gate injects old completed events
   after one cancelled GET and one disconnected GET; both are rejected by the
   transfer/Pane/generation identity boundary without a false completion, final
  file or temporary-file leak, while both Panes and the original process remain
  usable. Authentication-stage device observation now combines a pre-submit,
  PID-scoped live hilog stream with the bounded tail snapshot, records which
  source observed each structured state, and captures layout, screenshot and
  diagnostics when neither source observes authentication before the deadline.
  A production `TransferFileManager` device probe now proves preflight and
  commit-time local conflicts preserve existing bytes, automatic conflicts
  choose the minimal available numbered name without retransmission, temporary
  files stay in the final directory, nested PUT owns the no-follow source FD,
  and task cleanup removes only its exact temporary path. A physical-PC
  authentication matrix completes transfers with password, unencrypted and
  encrypted keys, two-round keyboard-interactive, and command-local identity,
  then removes its disposable key through the product workflow. Separate
  device gates prove safe recovery with no SFTP subsystem, remote permission
  denial, unsupported reliable rename and local disk exhaustion. A zero-byte
  round trip is SHA-256 exact, and an 8 MiB GET completes while the real window
  is minimized, restores in the same process, then continues through PUT and
  cleanup. A selected-text Ctrl+C physical gate now copies the xterm-owned
  selection without cancelling the active GET, then completes GET, PUT and
  SHA-256 verification. Ctrl+C is routed before ArkWeb consumes selection copy;
  file-name gates now round-trip space, Unicode and 224-character basenames,
  while a fixed-font Tab matrix proves offline completion, bounded listing and
  unsafe-control filtering against the production command buffer. A production
  Downloads manager probe exhausts all 10,000 automatic names without changing
  occupied contents. An in-flight 8 MiB GET also survives real system suspend,
  wake and unlock in the same process, then completes PUT and exact cleanup.
  With a selection Ctrl+C copies without cancelling the transfer; without a
  selection it still sends ETX. The difficult-to-recreate first-permission
  matrix is no longer a 1.3 release gate: current production ownership and
  recovery paths remain covered, while a fresh denial/retry/single-flight pass
  is reopened only for a real user failure, a material platform-permission
  change, a security/data-integrity risk or direct candidate counter-evidence.
- Added a mandatory natural-Chinese editorial pass after every offline User
  Guide regeneration. The 1.3 guide now explains the final local-completion
  workflow in both languages, and its Chinese opening, task steps and recovery
  guidance have been rewritten around user actions instead of translated
  implementation phrasing.

## [1.2.0] - 2026-08-08

**AppGallery review approved; released to users on 2026-08-13.**

### Added

- Added current-surface terminal search with the fixed `Ctrl+Alt+F` entry,
  compact match navigation and isolated Pane/Tab lifecycle behavior.
- Added a bilingual offline User Guide that is generated only from top-level
  local help. The existing terminal help remains intact, then exposes its short
  file name as one Ctrl-clickable link while retaining the complete Downloads
  URI only in the OSC 8 target. Exact-byte reuse, owned-file replacement,
  foreign-file protection and a strict single-file URI allowlist keep the
  workflow bounded.

### Changed

- Refined the desktop terminal workspace with bounded Tab overflow, clearer
  inactive-Tab surface contrast without inter-Tab divider lines, Tab surfaces
  continuous with the terminal, a distinct new-Tab boundary and a lower-weight
  full-height split divider,
  restored HarmonyOS four-dot menu, themed controls and visible keyboard focus
  states. Stabilized the hierarchy at every transparency level by mapping the
  Chrome track, inactive Tabs and active/hover Tabs to Catppuccin
  `crust → mantle → base` surfaces instead of low-contrast per-Tab opacity.
- Replaced the full-Pane BEL warning frame with a finite Tab emphasis, a
  persistent leading status marker for unattended output and a local split
  source marker. Reduced-motion uses static feedback.
- Replaced the three-level transparency cycle with a locally retained,
  non-wrapping Off/Low/Medium/High/Extreme stepper. The active window derives
  separate coordinated Chrome and content alpha surfaces while ArkWeb/xterm
  WebGL remain transparent; inactive or unsupported windows fall back to opaque.
  Fixed the user-selected HarmonyOS Regular background material once at the
  window root for non-Off levels without adding a material setting, custom
  Gaussian effect or WebView reconstruction. Reprofiled the content levels to
  `1.00/0.90/0.82/0.72/0.60` and Chrome to `1.00/0.94/0.88/0.80/0.70`.
- Added Search to the four-dot menu and replaced three separate font-size rows
  with one non-wrapping `− current +` stepper. Tightened the search panel spacing
  and made both empty and unsuccessful queries visibly report `0/0` while
  retaining distinct accessible descriptions.
- Added grouped global shortcuts for the four menu step buttons: `Ctrl+-` /
  `Ctrl+=` adjust font size and `Ctrl+Alt+-` / `Ctrl+Alt+=` adjust transparency,
  including while the menu is open. Each button now shows its shortcut in a
  native hover tip and exposes the same key in its accessible description.
- Grouped terminal-search Previous/Next under one outlined navigation control
  with a separator while keeping Close independently outlined. All three icons
  now use consistent shortcut tips, accessible key descriptions and visible
  focus treatment; disabled navigation no longer fades its tip text.

### Security

- Updated `russh` from 0.62.4 to 0.62.5 to enforce established-channel
  validation in the repository-only SSH server fixture while retaining the
  production client's existing `ring`, RSA and no-default-features boundary.
  Isolated bounded channel writes from the session lifecycle so remote-window
  backpressure cannot block output handling, local cancellation or transport
  disconnect detection.

### Documentation

- Added the reviewed Chinese-default, complete-English User Guide source and a
  formal-release gate that requires its packaged bytes and version to match the
  finalized 1.2 Changelog and application version before a candidate is built.
- Recorded the exact retained 1.2 candidate and physical ARM64 PC evidence for
  terminal search ownership/lifecycle, UI/window review, SSH transport, BEL,
  five transparency levels and continuous-output performance distributions;
  real keyboard/IME, user-server TUI and subjective visual acceptance also
  completed without an observed issue. The target system has no discoverable
  user-level reduced-motion setting, so that device scenario is recorded as not
  applicable while the static fallback remains covered. Final User Guide
  permission, update/conflict, bilingual rendering and real Ctrl-click behavior
  were accepted after the visible link was shortened to the file name without
  changing its complete OSC 8 target.

## [1.1.1] - 2026-08-06

### Fixed

- Corrected the AppGallery production-package authorization for key export by
  using a release Profile that grants the requested Downloads directory access.

## [1.1.0] - 2026-08-05

### Development

- Added fixed workspace keyboard navigation: `Ctrl+Tab` and
  `Ctrl+Shift+Tab` cycle connected tabs in visual order while restoring each
  tab's active Pane, and `Ctrl+Alt+Left/Right` focuses the corresponding Pane
  only when a split exists. Exact modifier matching preserves ordinary terminal
  input and single-Pane pass-through.
- Extended the repository-only SSH fixture with exact input-byte reporting for
  workspace navigation acceptance. A three-tab, dual-Pane physical-PC matrix
  verifies forward/reverse wrapping, active-Pane restoration and plain Tab or
  single-Pane shortcut delivery without adding production HAP logic.
- Added an explicit diagnostic-HAP mode to physical SSH authentication
  verification. Diagnostic evidence is marked unretained and can never promote
  a release candidate; static checks guard command-history and Preferences
  boundaries, while an opt-in physical check compares in-memory Preferences
  digests before and after authentication without reading content or persisting
  either digest.
- Added a retained-candidate physical-PC SSH authentication harness for direct
  password, password-to-keyboard-interactive mixed echo, multi-round wrong-answer
  recovery, unencrypted/encrypted public keys, key-to-password and
  key-to-keyboard-interactive chains, parallel Pane authentication,
  minimize/restore continuity, and process-stop cleanup during hidden input. It
  uses runtime-only fixture credentials and disposable keys, foreground
  reactivation, paced per-key raw events, secret pre-submit delivery-count
  checks, layout/log leakage checks, an exact HDC reverse mapping and verified
  cleanup; no test entry or logic enters the HAP.
- Added controlled zero-prompt keyboard-interactive and unsupported-method
  acceptance cases, including automatic empty-response submission, explicit
  error classification and a successful recovery connection without retaining
  authentication state.
- Extended physical authentication acceptance with cancellation during hidden
  input and Pane closure during an active challenge. Both paths discard the
  partial answer, disconnect the abandoned Session and recover through a fresh
  password connection without exposing fixture values.
- Made the native SSH lifecycle tests executable in WSL through a dev-only
  dynamic N-API symbol mode. The regression gate now covers authentication
  exchange success/failure, response and exchange timeouts, cancellation,
  generation rejection and parallel-session channel isolation, while asserting
  that test-only symbol features are absent from the production dependency tree.
- Added structured SSH keyboard-interactive and multi-method authentication across
  Rust, N-API and ArkTS. The per-session state machine follows server-provided
  remaining methods and partial success, supports banners, mixed-echo multi-prompt
  and multi-round challenges, rejects stale or malformed responses, bounds protocol
  stages and network/user waits, and clears submitted or cancelled secrets.
- Added a repository-only controlled SSH authentication fixture for password,
  encrypted and unencrypted keys, partial-success method chains, mixed-echo
  prompts and multi-round keyboard-interactive acceptance. Runtime credentials
  are generated in a temporary directory and the fixture is excluded from the
  production native library and HAP build.
- Closed the engineering device-text injection gate with exact command
  readback before Enter, deterministic coverage that rejects the historical
  `echo` to `eho` corruption, and a physical ARM64 HarmonyOS PC probe that
  preserved `echo` and representative ASCII inputs exactly. Local `Ctrl+C`
  now clears the native command line, so device automation no longer mistakes
  xterm's hidden accessibility textarea for application input state. Physical
  scenarios now inject complete printable ASCII as deterministic raw key events
  and judge commands by structured results, avoiding both `uitest` failures
  after `Ctrl+C` and accessibility readback that omits rendered digits.
- Added OpenSSH-compatible `ssh-keygen -F` lookup for the single LeanTTY
  `known_hosts` authority, including plain, hashed, comma-separated, IPv4,
  IPv6, non-default-port and multi-algorithm records without changing assets.
- Made malformed or duplicate SSH options and unknown, `Match` or unsupported
  directives in the selected SSH config scope fail with an actionable error
  before connection, while preserving unrelated unmanaged config text.
- Established a mandatory regression standard with one local software gate,
  monotonic retained-candidate evidence modes and self-driven physical-PC
  scenarios that verify injected input, observable state, negative paths and
  secret non-disclosure without rebuilding the accepted HAP. Physical scenarios
  now preflight telemetry, report stage timing, clear input from observed state
  and independently record verified disposable-state cleanup while using a
  bounded, automatically restored screen-timeout lease. A dedicated test PC can
  also recover from lock using a repository-external local plaintext credential
  that is converted to non-secret physical-key events only after a lock error.
- Added `ssh-keygen -p -f <identity>` with non-echoing old/new passphrase
  prompts, verified atomic private-key replacement, durable retention and
  rollback on retention failure without changing the public key or comment.
- Made WSL the explicit host for Rust formatting, tests and ARM64 compilation;
  the PowerShell build gate now invokes WSL and uses the Windows OHOS NDK only
  for the target linker and archive tools.
- Added `key export <key-name> [<file-name>]` to copy a verified OpenSSH
  private/public key pair directly to Downloads under an optional basename,
  failing without overwrite when either destination name already exists.
- Serialized all build-output writers across worktrees of the same repository,
  made the native cache independent of cleaned Cargo output, and retained only
  the five most recent verified test-signed HAP candidates outside volatile
  build directories for rebuild-free device installation.
- Added owner-isolated persistent custody for SSH configuration, verified key
  pairs, trusted host keys, terminal font size and window geometry so the same
  application identity can rematerialize them after a normal uninstall and
  reinstall without exposing a backup or restore workflow. Physical ARM64
  HarmonyOS PC validation covers Ed25519 and RSA-4096 keys with and without
  passphrases, OpenSSH config, `known_hosts`, font and window state, explicit
  deletion, lock and system-reboot continuity, owner reinstall after a
  different-signature package boundary, and verified disposable-state cleanup.
- Added a fail-fast AppGallery release preflight and a single build, comparison
  and archive command that keeps production upload artifacts separate from the
  test-signed HAP used for device acceptance and review media.
- Removed the duplicated hard-coded release version from the build script;
  artifact naming now derives from the application version unless a formal
  release explicitly supplies and validates `-ReleaseId`.

### Fixed

- Preserved the visible terminal and scrollback when SSH closes by delivering
  final PTY bytes and the close event through one ordered native callback before
  the disconnected prompt and terminal checkpoint.
- Enabled the existing `russh` RSA feature so the advertised RSA-4096 key
  generation and passphrase-change paths use the supported implementation
  instead of failing with an unknown-algorithm error.
- Moved CPU-bound SSH key generation from the ArkUI event thread to an
  asynchronous native worker, preventing the system not-responding dialog
  during RSA-4096 generation while keeping the terminal menu interactive.
- Added bounded session-memory checkpoints so a terminal surface rebuilt after
  the app enters the background can recover its screen and scrollback even when
  SSH disconnects. Physical ARM64 PC validation now covers long sleep with a
  disconnect, renderer reconstruction without replayed side effects, and the
  absence of terminal-content recovery after process termination or a normal
  uninstall and reinstall.
- Ended accepted SSH host-key confirmation input with a new line before showing
  the next authentication prompt.
- Added OpenSSH-compatible `ssh-keygen -R` host-record removal and made changed
  host-key failures show the stored and received fingerprints plus the exact
  cleanup command for the effective host and port.
- Accepted the default OSC 52 clipboard selector emitted when tmux mouse
  selection ends, allowing the standard `MouseDragEnd1Pane` copy path to reach
  the HarmonyOS system clipboard without Shift or a second right-click.
  Physical ARM64 HarmonyOS PC validation covers exact tmux-buffer/system-
  clipboard agreement with `set-clipboard external/on`, `Ms`, Chinese and
  multiline text, tmux touchpad scrolling and TUI mouse input, Shift-drag local
  copy followed by `Ctrl+C`, and ordinary terminal selection.

### Documentation

- Recorded the public AppGallery release of 1.0.1 and selected the authorized
  1.1.0 authentication and workspace-navigation scope.
- Added current-source user, privacy, architecture, security and quality
  baselines, plus an explicit mapping from vision outcomes to roadmap and
  evidence paths.

## [1.0.1] - 2026-07-28

### Security

- Updated `russh` to 0.62.4 to address three remote panic conditions reported
  against earlier 0.62.x releases.

### Changed

- Renamed the application from HarmoTTY to LeanTTY and replaced the application
  identity, icon, bundle name, package names, local prompt and release artifact
  names with the LeanTTY identity.
- Removed the standalone Copy action from the tool menu while keeping the
  existing keyboard and selection-aware copy paths.
- Made unknown commands at the disconnected `ltty>` prompt point to both
  `help` and the direct `ssh user@host` path.

### Fixed

- Redrew the disconnected `ltty>` command line after edits so deleting or
  moving across Chinese wide characters no longer leaves stale terminal cells.
- Asked for confirmation before closing LeanTTY while any SSH session is
  active, while avoiding a duplicate prompt after confirming closure of the
  final connected tab.
- Let the top tab strip use all remaining title-bar width after window controls,
  fixed actions and drag space instead of imposing a fixed viewport cap.
- Cleared a pane's persistent bell-attention border when the user types or
  pastes in that pane, without letting background output or automatic focus
  restoration acknowledge it.
- Kept embedded Nerd Font icons inside their terminal cells so prompt and icon
  glyphs no longer overlap adjacent text.
- Restored the complete pure-core UTF-8 burst test fixture so Linux public CI
  compiles and runs the test suite.
- Balanced terminal insets around full-screen TUIs by offsetting the scrollbar
  gutter and centering unused cell-grid height without reducing rows or columns.
- Routed HTTP(S) and OSC 8 terminal links through the HarmonyOS system browser
  with `Ctrl+Click` normally and `Ctrl+Shift+Click` while tmux or another TUI
  owns mouse reporting, without stealing ordinary TUI mouse input or leaving
  xterm in text-selection drag mode after the browser handoff.

## [1.0.0] - 2026-07-26

**AppGallery submission rejected; not published.**

First stable submission candidate for ARM64 HarmonyOS PC. The application
package and signed `v1.0.0` tag remain immutable rejection evidence; no user
received this version.

### Security
- SSH host key verification against known_hosts
- Private key file permissions set to 0600
- ssh-copy-id uses POSIX single-quote encoding (prevents shell injection)
- Repository-external signing configuration keeps certificates, keystores, and passwords out of source control

### Added
- SSH private key authentication (ed25519, rsa)
- Key management commands: ssh-keygen, ssh-copy-id, key list/show/rm/import
- OpenSSH-style host management
- Command history with Up/Down navigation
- Multi-tab and dual-pane terminal sessions
- Selection-aware copy actions and system clipboard integration
- HarmonyOS PC window, theme, and font-size persistence

### Changed
- Upgraded russh from 0.49.2 to 0.62.2 (CVE fixes)
- ARM64 HarmonyOS PC is the only supported build and release target
- Tab, pane, and SSH session ownership use stable pane identifiers
- Terminal output delivery drains pending data before bridge teardown
- Normal SSH exit keeps the current terminal screen and xterm scrollback visible
- Terminal spacing, scrollbar, zoom behavior, and alternate-screen wheel ownership were aligned with desktop terminal use

### Fixed
- Half-open SSH sessions are detected instead of remaining falsely connected
- UTF-8 and final terminal bytes are delivered before close/EOF notification
- Focus, Tab traversal, clipboard, resize, reconnect, and window lifecycle behavior on the target PC
- Encrypted and unencrypted private-key authentication, host-key confirmation, and connection cancellation
- Alternate-screen TUI scrolling no longer leaks into normal scrollback
- Terminal history is no longer replayed when a page resumes or a disconnected surface is recycled

### Removed
- Legacy command names (keygen, keypub, keypush, keyrm, keyimport)
- x86_64 emulator packaging from the supported 1.0 build path
- Application-level terminal history replay and its duplicate buffer

### Documentation
- Product and technical principles define the 1.0 scope
- `docs/next-work.md` is the sole active project checklist
- Release, versioning, security, and third-party notice documents are included
