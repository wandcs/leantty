# LeanTTY Regression Test Standard

> Status: mandatory cross-version engineering standard
>
> Last updated: 2026-09-07
>
> Product acceptance: [`vision-acceptance.md`](vision-acceptance.md)

This document is the single authority for how every LeanTTY change is tested.
It turns the reliability and trust principles into repeatable evidence. `MUST`,
`MUST NOT`, `SHOULD` and `MAY` are normative. It contains no active task list:
feature-specific acceptance belongs in one technical design, while executable
gaps belong only in [`next-work.md`](next-work.md).

## Test levels and mandatory workflow

Testing has five evidence levels. Select the lowest set that completely covers
the affected event chain; do not run a higher or unrelated level merely because
it exists.

| Level | Trigger | Required evidence | Boundary |
| --- | --- | --- | --- |
| **L0 — documentation and static policy** | Every change; documentation-only changes may stop here | Authority/status/link consistency, public-source and prohibited-artifact policy when affected, plus `git diff --check` | Does not prove compiled or runtime behavior |
| **L1 — unit and helper** | Pure Rust, ArkTS, Web, parser, state-machine or PowerShell helper logic changes | Direct owner tests, newly exposed negative/recovery cases and the smallest related helper suite | Does not prove cross-language, package or device integration |
| **L2 — subsystem integration** | A change crosses Bridge/native/fixture/storage/build/package boundaries | Affected fixture/integration/workflow tests and, when the compiled boundary changes, the smallest applicable ARM64 build | Does not prove focus, keyboard, window or other physical behavior |
| **L3 — named physical scenario** | The changed result is visible only on a HarmonyOS PC or depends on real keyboard, clipboard, window, ArkWeb, lifecycle, filesystem service or SSH interoperability | Only the named physical scenario(s) that exercise the changed chain, plus their required setup/cleanup and a small main-path smoke | Is diagnostic/change-scoped evidence unless run against a formal retained candidate in acceptance mode |
| **L4 — formal release gate** | Only while preparing a new formal version for release | Full software gate, exact clean ARM64 candidate, complete applicable physical matrix, production/review identity, signing and release checks | The only level that may claim complete release acceptance |

Risk increases the depth of the affected-chain evidence, not the breadth of
unrelated regression. A small host-trust or terminal-byte change can require
strong L1–L3 negative and recovery coverage; it still does not authorize the L4
matrix during ordinary development.

### External research gate for test-system changes

Before changing device automation, input injection, focus or wait behavior,
fixtures, observation/oracle logic, failure classification, retry/rerun policy,
scenario partitioning or release-verification tooling, the implementing agent
MUST research the problem outside the current repository. A local code reading
or one failed run is not enough to authorize a fix.

The research MUST be performed when that individual task starts, so a previously
saved link list does not substitute for checking the currently applicable SDK
and tool behavior. It MUST cover, when available:

1. HarmonyOS/OpenHarmony official API documentation, guides, samples, source and
   version or release notes;
2. relevant upstream issues, pull requests and maintainer discussions;
3. Huawei developer-community and other reproducible reports of the same or a
   closely related symptom; and
4. official practices from comparable automation systems, used only as design
   patterns and never presented as proof of HarmonyOS behavior.

The task record MUST state the research date, precise question, source links,
applicable platform/tool versions, agreements, conflicts and unresolved gaps.
If no matching report is found, record that negative result instead of inventing
an implied platform guarantee. Search summaries and forum workarounds are leads;
prefer primary sources and trace each proposed workaround back to documented
semantics or a controlled experiment.

External research narrows hypotheses but does not replace the systematic local
investigation: reproduce the symptom, identify the last correct and first
incorrect component boundary, compare a working path, test one hypothesis at a
time, and verify on the physical ARM64 HarmonyOS PC when the claim is physical.
Only then may the change proceed. If the evidence contradicts the planned task,
update `next-work.md` and reframe the work rather than implementing the stale
plan.

### Root-cause and reframing gate

A failed check authorizes investigation, not an immediate patch. Before the
first behavior change, the task record MUST identify the expected contract, the
last correct and first incorrect component boundary, the authoritative state
owner, competing product/harness/environment hypotheses and the single
hypothesis tested next. The next run MUST be the cheapest level that can
distinguish those hypotheses.

The enclosing formal matrix MUST stop at its first failure and MUST NOT be used
as a reproduction loop. Earlier formal stages may be reused only under the
checkpoint rules; diagnosis uses the failed named stage, a narrower diagnostic
or a deterministic trigger. A new full matrix is forbidden while the failed
precondition or oracle remains ambiguous.

Reframing is mandatory at the earlier of these checkpoints:

- two materially different implementation attempts fail to close the same
  event chain;
- each attempted fix exposes another owner, cache, projection or layer;
- 90 minutes of active diagnosis pass without identifying one root cause; or
- the proposed test observes the claim only through another feature whose own
  state can fail independently.

At the checkpoint, stop editing and expensive execution. Record which
hypotheses were rejected, restate the authoritative owner and product contract,
remove superseded assumptions, and select a new smallest diagnostic. A third
implementation attempt requires this written reframe; elapsed time or previous
investment never justifies another speculative guard.

When the platform can produce several valid lifecycle outcomes and external
automation cannot select one reliably, do not repeat the physical action to hunt
the rarer branch. Use one real platform run to validate an actually observed
documented outcome, and use the smallest compile-time-isolated acceptance trigger
on the physical PC for every otherwise unselectable production recovery path.
The trigger may start the path but must not simulate its result or create a
second state model.

### Change-scoped feature and bug-fix verification

Before implementation, identify this event chain:

```text
user or external input
→ parser/UI entry
→ owning state model
→ Bridge/native/platform/server boundary
→ observable result
→ failure, cancellation, recovery and cleanup
```

Then use this sequence:

1. Map every changed owner and crossed boundary to the
   [change-to-evidence matrix](#change-to-evidence-matrix). Add or update a test
   for each newly exposed failure mode before or with the fix.
2. Run the affected L0–L3 checks only. Include positive behavior and the
   applicable failure, cancellation, recovery, stale-event, security and cleanup
   paths; omit unrelated feature suites.
3. Run the smallest stable main-path smoke that is already available in the
   selected environment. If the change requires a device or SSH session, this
   may include launch, one direct connection, basic input/output and clean close;
   it MUST NOT grow into a complete physical matrix.
4. Before committing, run `git diff --check` and record the selected commands,
   concise results and evidence paths. A failed, skipped or interrupted required
   check is not a pass.

All Rust formatting, compilation, clippy and tests run in WSL. Windows supplies
the OHOS SDK tools but is not a Rust build host.

Routine feature work and bug fixes use `tools/test-regression.ps1 -Group ...`
only with the explicitly mapped local groups. They MUST NOT run the ungrouped
full gate, `tools/verify-pc.ps1` or every named `verify-*-pc.ps1` scenario.
Documentation-only changes MAY stop at L0. Dependency or architecture changes
run the tests owned by the affected dependency or boundary; they do not become
L4 until a formal release is being prepared.

### Feature completion record

A feature or fix is complete for routine development only when its design,
commit or PR record states:

- the affected event chain and trust boundaries;
- the selected L0–L3 checks and why each is required;
- the relevant tests intentionally not run, especially the deferred L4 gate;
- the exact commands, results and retained evidence paths; and
- any boundary that can be verified only during formal release acceptance.

“All tests passed” without the selected scope is not an acceptable result. A
build, install, launch, screenshot or single successful connection MUST NOT be
described as feature acceptance unless it is the actual mapped postcondition.

### Formal release-package verification

Only when preparing a formal new version MUST the maintainer enter L4:

1. freeze an exact clean committed source identity;
2. run `tools/verify-pc.ps1`, which executes one complete ungrouped
   `tools/test-regression.ps1` before building the candidate;
3. retain the exact signed ARM64 candidate and run every applicable named
   `verify-*-pc.ps1` acceptance scenario against that unchanged HAP;
4. run the production/review, signing and publication checks required by
   [`release-process.md`](release-process.md); and
5. report the candidate SHA-256, harness identity, commands, results, evidence
   paths and cleanup outcome. Required remote checks MUST pass.

An earlier development full run, a set of diagnostics or an administrative
bypass never waives this release gate.

Before step 2, `prepare-formal-build-inputs.ps1` MUST prepare each networked
toolchain once: clean npm install and Web build, stable OHPM lock resolution,
and locked ARM64 Cargo fetch. It MUST hash tracked locks and generated inputs
before and after preparation, restore their exact bytes on failure or drift,
and retain the tool versions and input hashes. The full gate and candidate build
then run offline. A missing cache is a preparation failure, not permission for a
formal stage to fetch implicitly.

Formal Hvigor runs MUST disable the daemon and capture stdout, stderr and exit
code separately. The ArkTS warning gate accepts only an exact normalized
warning count and fingerprint bound to the recorded DevEco/Hvigor versions;
nonempty stderr is not itself a failure, and one added or changed warning is.
Generated release ZIPs MUST use ordinal entry order, normalized entry names,
one fixed timestamp and fixed external attributes. The workflow regression
MUST build the archive twice after source-mtime perturbation and compare hashes.

## Quality model

Every release candidate must preserve seven areas:

1. user trust and secret/data boundaries;
2. terminal input, output, resize and compatibility correctness;
3. SSH target, host-key, authentication, cancellation and recovery behavior;
4. Tab/Pane/Session ownership and isolation;
5. HarmonyOS keyboard, clipboard, window and lifecycle behavior;
6. a simple, observable and recoverable user path; and
7. exact source, artifact and release identity.

Passing a new feature scenario cannot compensate for a regression in one of
these permanent areas.

## Evidence layers

| Layer | Proves | Does not prove |
| --- | --- | --- |
| Documentation/source policy | Public tree, references and prohibited artifact rules are consistent | Runtime correctness |
| Rust pure-core tests | Key/file rules, known-host semantics, UTF-8 and other host-testable protocol policy | HarmonyOS/N-API integration |
| ArkTS unit tests | Ownership, parser, Bridge policy, interaction state, persistence format and pure UI policy | Real ArkUI/ArkWeb/device behavior |
| Web terminal policy tests | OSC 9/52/99/777, link, input, wheel, attention gate, snapshot and xterm policy against packaged resources | HarmonyOS WebView lifecycle |
| Build-workflow tests | Locking, candidate retention and script control-flow policy | Product interaction |
| Public CI | Secret scan, public-source checks, Rust fmt/clippy/tests and Web policy on clean hosted runners | DevEco build, signing or physical-PC behavior |
| Clean ARM64 HAP build | ArkTS, N-API, Rust and packaged resources integrate for the only supported ABI | Focus, clipboard, lifecycle or SSH interoperability |
| Signed install and launch | The selected test candidate can be installed and started on the target PC (`device-deployed`) | The changed behavior works |
| Physical-PC scenario | Device-visible event chain and real lifecycle behavior | Uncovered servers, networks or long-term use |
| Production manifest/signature | Exact commit, ABI, artifact hashes, signature and package identity | AppGallery approval or user outcome |
| Real-use/vision review | Sustained primary-device outcome and continued unique value | Future releases without renewed evidence |

Evidence must never be promoted across these boundaries. In particular,
`verify-pc.ps1 -SkipDevice`, a clean build, installation and application launch
are not substitutes for a physical interaction result.

## Standard commands

Routine change-scoped examples (select only those mapped to the change):

```powershell
.\tools\test-regression.ps1 -Group policy,tooling
.\tools\test-acceptance-harness.ps1
.\tools\dev-pc.ps1
```

The focused software groups are `policy`, `tooling`, `ssh-flow`, `web`,
`arkts`, `rust-core`, `rust-native` and `ssh-fixture`. Select them from the
changed event chain rather than running every group. Focused JSON evidence is
marked `software-focused`, `mode=focused` and `releaseEligible=false`.

| Group | Select when the changed chain owns |
| --- | --- |
| `policy` | Public-source policy, edited text and diff integrity; normally include before commit |
| `tooling` | Build/release scripts, candidate handling, HDC helpers or physical harness logic; includes automatic-variable and production/review artifact-role guards |
| `ssh-flow` | ArkTS/native SSH ordering or asynchronous key-generation control flow |
| `web` | Packaged terminal HTML/xterm policy or the offline user guide |
| `arkts` | Application state, parser, ownership, persistence, interaction or platform policy |
| `rust-core` | Host-testable SSH, known-host, key/file or protocol semantics |
| `rust-native` | N-API/OHOS native boundary and production feature isolation |
| `ssh-fixture` | Controlled authentication server behavior and fixture E2E |

File paths may suggest groups, but the event chain is authoritative. A change
crossing multiple owners selects multiple groups; an automatic diff heuristic
must never silently omit a boundary.

### Retained static contract checks

Static source inspection is limited to contracts that cannot be proved reliably
through a public behavior test alone. A retained check MAY protect a generated
interface, a cross-language or platform registration point, a forbidden security
pattern, an artifact boundary, or the test/release harness itself. It MUST NOT
freeze a product-private field or method name, local variable, helper call order,
or another implementation shape when an ArkTS, Rust, Web, build or physical test
can observe the result. Each failure must name the damaged responsibility.

| Check | Focused group | Stable contract protected |
| --- | --- | --- |
| `check-public-source.ps1` | `policy` | Public-tree secret, generated-file and prohibited-artifact policy |
| `test-mosh-client.cjs` | `arkts` | Current MoshClient admission/close and SessionViewModel input/error contracts with a substituted native boundary; host-only evidence, not ArkTS compilation or device scheduling |
| `check-ssh-transport-flow.ps1` | `ssh-flow` | One generated N-API transport/control event schema across Rust typings and ArkTS, including removal of the retired split callbacks |
| `check-keygen-async-flow.ps1` | `ssh-flow` | Cross-language asynchronous key-generation contract: blocking Rust work is isolated and the generated ArkTS API remains a Promise that callers await |
| `test-terminal-policy.mjs` | `web` | Locked/generated Web assets, terminal policy behavior and necessary Web/ArkTS platform or security boundaries; product-private ArkTS control flow belongs in ArkTS or physical behavior tests |
| `test-xterm-input-order-patch.mjs` | `web` | Version/hash-locked upstream transformation, generated-owner input/diff behavior and isolated callbacks; browser and PC tests prove event dispatch and IME integration |
| `test-build-workflows.ps1` | `tooling` | Build/release locking, candidate identity, acceptance-source restoration, workflow failure and evidence contracts; product-private control flow is outside this check |
| `test-release-evidence.ps1` (included by build-workflow tests) | `tooling` | Serialization overflow and failed replacement preserve the old checkpoint; unknown cleanup cannot pass the stage summary; original failures and actual versus planned model counts survive reporting |
| `test-device-regression.ps1` | `tooling` | Physical-harness input, evidence, cleanup and secret-safety contracts, plus unavoidable public ArkUI/lifecycle registration and filesystem security flags |
| Package-policy checks registered by `test-regression.ps1` | `tooling` and build stages | ABI, production/test-source isolation and release-package artifact boundaries |

Tests under `entry/src/test/` are organized by the owner or behavior they prove,
such as SSH, workspace, terminal interaction, transfer, key management and
formatting. A historical incident may explain why a test exists, but it does not
define a permanent catch-all test suite.

### Offline user-guide editorial gate

`test-user-guide.mjs` protects packaged/source byte parity, offline resource
policy and basic document contracts. `test-user-guide-preview.mjs`, registered
in `web` and `tooling`, tests the real HTTP allowlist, loopback binding and
listener cleanup. Neither test approves the guide's wording or task accuracy.

Use the separate [browser review entry](../tools/web-terminal/README.md#offline-user-guide-review)
while editing the guide. It previews only the fixed HTML snapshot, checks both
languages and TOC/task navigation at wide and compact desktop widths, and saves
screenshots plus versioned evidence. A reviewer MUST inspect the screenshots and
check both languages against delivered behavior. The runner MUST NOT label its
automatic result as editorial approval or physical acceptance. Source preview
may precede packaged-copy synchronization; parity remains required before build.

No HAP rebuild or full matrix is needed for changes confined to this host-side
review tool. Changes to HarmonyOS guide export, permissions or system-browser
routing still require their named physical event-chain checks.

`dev-pc.ps1` is the normal build/install/launch loop when the affected behavior
needs a device build; it is not an acceptance result. Before a named physical
scenario, run the bounded, non-repairing control-channel preflight:

```powershell
.\tools\preflight-device.ps1
```

A preflight pass proves only the ready HDC command channel, serialized UiTest
layout capture and an interactive screen layout. It does not install, launch,
unlock or prove LeanTTY behavior. Named diagnostic stages are focused evidence
and MUST NOT be presented as complete release acceptance.

The thin registered release entry runs the current candidate, harness and
physical checkpoints in the fixed order below:

```powershell
.\tools\verify-release-pc.ps1 `
  -Target '<physical-PC-target>' `
  -MoshAlternateWifiSsid '<saved alternate SSID>' `
  -EvidenceDirectory 'C:\path\outside\the\repository\release-verification'
```

Pass `-HapPath` only to start from an exact retained candidate instead of
rebuilding C1/C2. The entry invokes the existing scripts; it does not contain a
second device driver or acceptance implementation. It stops at the first
failure, writes `release-report.json` and `maintainer-summary.md` atomically,
and records stage duration, attempts, candidate/harness identity, cleanup and
planned/available actual model usage. It never retries a model request
automatically. Explicit `-Resume` requires the same report, retained candidate,
harness commit/tree, target, ports and distribution. An SSH failure additionally
prints the exact `verify-ssh-matrix-pc.ps1 -Resume` command bound to that stage's
existing evidence directory.

The Mosh stage requires one already saved alternate Wi-Fi that can reach the
same test LAN. The report stores only a hash identity for that SSID. It reports
`completeApplicablePhysicalMatrixClaimed=true` only after the eight formal Mosh
network/lifecycle scenarios and every other registered C3 stage pass against
the same candidate and harness. Production/review artifacts, signing and
publication remain C4 and later work in every case.

The Mosh order has one owner, `Get-LeanTTYMoshFormalScenarios`: compatibility,
runtime-reclaim, UDP pause, suspend, operator lock, operator lid, Wi-Fi pause,
then Wi-Fi network switch. A saved seven-stage prefix is not resumable as this
eight-stage matrix.

The lower-level commands called by the current registry are:

```powershell
.\tools\verify-pc.ps1
.\tools\verify-key-passphrase-pc.ps1
.\tools\verify-ssh-auth-pc.ps1 -DiagnosticHap -HapPath <signed-test-hap> -Only key-comment-change-and-restart
.\tools\verify-ssh-auth-pc.ps1 -DiagnosticHap -HapPath <signed-test-hap> -Only ecdsa-import-encrypted-and-restart
.\tools\verify-host-identity-pc.ps1 -HapPath <signed-test-hap>
.\tools\verify-host-identity-pc.ps1 -HapPath <signed-test-hap> -OpenSshCompatibility
.\tools\verify-host-identity-pc.ps1 -HapPath <signed-test-hap> -OpenSshCompatibility -DefaultEcdsa -PreserveExistingEd25519
.\tools\verify-background-bell-notification-pc.ps1 -HapPath <signed-test-hap>
.\tools\verify-background-bell-notification-pc.ps1 -HapPath <signed-test-hap> -Suppression
.\tools\verify-background-bell-notification-pc.ps1 -HapPath <signed-test-hap> -ColdStale
.\tools\verify-background-bell-notification-pc.ps1 -HapPath <signed-test-hap> -LateHandled
.\tools\verify-background-bell-notification-pc.ps1 -HapPath <signed-test-hap> -LateDestroyed
.\tools\verify-background-bell-notification-pc.ps1 -HapPath <signed-test-hap> -ManualDismiss
.\tools\verify-background-bell-permission-pc.ps1 -HapPath <signed-test-hap>
.\tools\verify-unexpected-recovery-uninstall-pc.ps1 -HapPath <signed-test-hap>
.\tools\verify-mosh-matrix-pc.ps1 -Target <physical-PC-target> -HapPath <signed-test-hap> -AlternateWifiSsid <saved-alternate-SSID>
.\tools\verify-long-task-notification-pc.ps1 -HapPath <signed-test-hap>
.\tools\verify-agent-compatibility-pc.ps1 -HapPath <signed-test-hap>
.\tools\verify-ssh-matrix-pc.ps1
```

`test-regression.ps1` without `-Group` runs public-source policy,
workflow/helper tests, Web terminal policy, trusted ArkTS tests, WSL Rust
fmt/clippy/core tests and diff checks. It writes full release-eligible local JSON
under `build/verification/` even when a check fails. A grouped invocation uses
the same check registry but is routine focused evidence only.

`verify-pc.ps1` is the formal release candidate gate. It reruns the software
gate, verifies generated-native source policy,
performs a clean ARM64 debug build and—unless `-SkipDevice` is used—installs and
launches the signed HAP on a physical PC. It retains the exact HAP outside the
volatile build tree with its SHA-256, Git identity and software evidence.

`verify-key-passphrase-pc.ps1` is the first feature-owned physical scenario. It
installs an already retained clean candidate, drives real application state,
records JSON evidence and never rebuilds the HAP.

`verify-ssh-auth-pc.ps1 -Only key-comment-change-and-restart` is the bounded
1.5 comment-maintenance scenario. It generates and encrypts one disposable key,
rejects a wrong passphrase, changes the visible comment, compares the exact
OpenSSH fingerprint and 0600 mode before/after/restart, then authenticates to
the controlled fixture with the unchanged passphrase and deletes the key.

`verify-ssh-auth-pc.ps1 -Only ecdsa-import-encrypted-and-restart` is the
bounded 1.5 imported-ECDSA scenario. It creates one runtime encrypted OpenSSH
P-256 fixture outside product storage, sends it into the application sandbox,
imports it through `key import`, rejects a wrong passphrase, authenticates to
the controlled server before and after app restart, compares the fingerprint
and 0600 mode, then deletes both the product Identity and source fixture with
independent absence audits. P-384/P-521 and unencrypted formats remain covered
by deterministic software fixtures; the physical scenario selects one curve
because it validates the shared platform and interaction chain.

`verify-host-identity-pc.ps1` is the bounded 1.5.1 Host/Identity scenario. It
uses the repository-controlled russh `key-install` account, installs one
disposable public key through the real `ssh-copy-id` password path, and accepts
subsequent public-key authentication only when the SHA-256 fingerprint matches
the installed key. It proves saved-Host authentication before and after app
restart, password fallback after `-i none`, and recovery after restoring the
binding. The scenario is diagnostic evidence for a supplied signed HAP; it
creates no system user, does not modify the system `sshd` or a real
`authorized_keys`, and must remove the Host, key, known-host entry, reverse
mapping, fixture process and screen-timeout lease independently.

The `-OpenSshCompatibility -DefaultEcdsa -PreserveExistingEd25519` variant is
the bounded 1.6 default-Identity scenario. It requires a test-signed debug HAP
with the repository's acceptance source enabled. The product first exports the
existing `id_ed25519`; acceptance-only code compares the active and exported
private bytes inside the application and returns only booleans. The script then
removes `id_ed25519` through `key rm`, imports one standard `id_ecdsa`, and uses
a temporary system-OpenSSH account that authorizes only that public key. It
proves default and Host-bound authentication before and after restart, removes
the ECDSA key, source, Host, account, known-host entry and reverse mapping, then
restores `id_ed25519` through `key import`. The final acceptance check requires
the restored private bytes and original public fingerprint to match before it
deletes the run-owned Downloads backup. A failed comparison retains the backup
and marks the run invalid.

`verify-agent-compatibility-pc.ps1` is the bounded 1.5 native Agent TUI
compatibility scenario. It uses the desktop user's default WSL distribution,
an isolated public-key-only OpenSSH server and an isolated test Tab, then runs
the selected installed Agent in direct SSH and/or remote tmux. Each result MUST
record the exact Agent version and authentication readiness. Missing
authentication is `not-assessed`, never pass; `-AllowPartialAuthentication`
only permits a partial evidence file to be retained without changing that
meaning. The controlled server MUST set `LANG=C.UTF-8` and `LC_ALL=C.UTF-8`
before its no-profile Bash starts, and the first connected session MUST record
`locale charmap` as exactly `UTF-8` before any Agent result can be assessed.
The SSH entry waits for either a host-key prompt or an observed connection;
absence of a prompt is not an exception-recovery branch. Focus, text, key and
log-query failures MUST propagate without being replaced by a later timeout.
A missing app-log observation alone is `unknown`, not proof of a product defect.
The harness records the current attempt's proven SSH boundary separately from
the app's state: connection plus the fresh fixture marker grant `shell-ready`,
and a fresh close observation grants `local`. It invalidates that evidence
before a new connection or disconnect action. An uncertain Ctrl+D is not retried.
The first failed selected check is persisted and stops subsequent Agent/mode
checks and local cleanup submission. Unconfirmed resource cleanup remains a
failure with its run-scoped identity; never claim removal or restart the entire
application to make a failed isolated Tab look recovered.
`test-agent-ssh-gate.ps1` executes these actual functions with external effects
replaced, including failure propagation, stale-boundary rejection and selection
stop. It runs through `test-agent-compatibility.ps1` in the `tooling` group; its
optional `-EvidencePath` records a standalone no-device result. These tests do
not prove physical SSH recovery or resource removal.
The fixture MUST NOT rely on SSH client locale forwarding: OpenSSH does not
accept client environment variables by default, and tmux replaces non-ASCII
output with underscores when its client locale is not UTF-8. A missing or
non-UTF-8 controlled locale is an environment failure, never a LeanTTY or Agent
compatibility result. Notification checks MUST use the Agent's native configured
signal and MUST NOT append a fixture BEL. Process-scoped trust and Agent settings MUST NOT
modify user configuration. OpenCode attention is enabled only through the
run-scoped temporary `OPENCODE_CONFIG_DIR`; the default-disabled user setting is
not treated as a product failure. Its notification prompt performs one bounded
`sleep` tool call so completion happens after the physical window is hidden;
the harness MUST wait for the interactive TUI and submit the prompt through
LeanTTY rather than use the startup `--prompt` option, which can race the
built-in notification subscriber. This is a timing precondition, not product workload. Proxy inheritance MAY use
values already present in the default WSL process, but evidence records only
variable names. Raw PTY input and output MUST be deleted after a content-free
wire summary is produced. That summary records only the count of exact OSC 99
`p=title,body` capability responses returned to the Agent, never the query
identifier or payload.
When the OSC 99 boundary itself is ambiguous, run the same scenario with
`-Osc99CapabilityProbe`. This zero-model diagnostic sends only the standard
OpenTUI capability query from the remote PTY and records whether the exact
bounded LeanTTY response returns once. It does not start an Agent, emit an
attention frame, minimize the window or prove native notification behavior;
its sole purpose is to distinguish a terminal response-path failure from an
Agent that queried the capability but did not later emit a notification.
When raw mode, alternate-screen ownership or resize remains ambiguous, run the
same scenario with `-InteractionOnlyProbe`. It starts each selected real Agent
TUI without submitting a prompt, records `plannedModelRequests=0`, samples only
content-free PTY termios and dimensions, sends a controlled physical English key
sequence and a real HarmonyOS Chinese IME composition, toggles the real window
size, restores the input method and window, exits the TUI and deletes raw PTY and
termios files. A pass proves physical English/Chinese input, raw-mode entry, the
Agent's observed alternate-screen choice and PTY resize propagation. It does not
prove the visual shape of CJK glyphs, notification, model output, OSC 52/8
activation or scrollback behavior. A visual CJK claim requires a current
screenshot or bounded human review under the verified UTF-8 fixture.
When native clipboard and Agent-owned virtualized history remain ambiguous, run
`-ProtocolInteractionProbe` only with Qwen in tmux. The run uses one short,
fixed model request, then requires Qwen's native `/copy` to emit OSC 52 and the
unchanged LeanTTY clipboard bridge to report a non-empty successful system
write. It fills history with Qwen's local `!seq` command without another model
request, requires `PageUp` to visibly change the viewport, records the
documented `Ctrl+End` restoration for bounded visual review, and deletes raw
PTY content. OSC 8 is an observation in this probe, not a pass condition: when
Qwen does not emit a non-empty URI frame, the result MUST say so and MUST NOT
inject an escape sequence or report hyperlink activation as verified.
The capture analyzer counts only OSC 8 frames with a non-empty URI as hyperlink
opens and records empty-URI resets and malformed frames separately. This rule
applies equally to direct frames and OSC sequences nested in tmux DCS wrappers;
raw `oscCounts["8"]` is not itself a hyperlink count.
`-OpenCodeForceOsc99Protocol` is a diagnostic-only upstream isolation switch
and MUST be limited to `-Agents opencode`. It records the OpenTUI override in
the result and bypasses capability detection, so its outcome can locate the
remaining boundary but can never count as normal-configuration compatibility
or release acceptance.
Direct and tmux results remain separate, and a diagnostic HAP result is not
release acceptance. The stable contract and current matrix are recorded in
[`design/agent-tui-compatibility.md`](design/agent-tui-compatibility.md).
The tmux fixture enables `focus-events` because DEC 1004 focus reporting is
otherwise consumed at the outer tmux boundary. A captured native signal proves
wire behavior, not system notification: if the physical app is suspended after
the window becomes hidden, a later Agent completion signal is recorded as a
product/lifecycle limitation rather than promoted to pass. OpenCode's OSC 99
must match the approved complete receive-only title/body subset before it can
enter the shared attention path; richer OSC 99 operations remain outside scope. Agent model usage
is recorded when the tool exposes run-scoped accounting; otherwise it is
`unavailable`, never estimated as zero.

Formal notification verdicts are applicability-aware while every interaction,
UTF-8, search, input, reconnect and applicable tmux-resume assertion remains
blocking. Codex direct/tmux, OpenCode direct and Qwen tmux require the complete
native-signal, generic system-notification and return chain. OpenCode tmux is
`not-emitted-by-agent` only when the final raw-free PTY summary contains no
native attention and the notification wait ended in the external Agent domain;
if OpenCode does emit a native signal, the complete LeanTTY notification chain
becomes required. Pi direct/tmux and Qwen direct must still emit their expected
native signal; when that signal is captured but the exact hidden-window
non-publication boundary occurs, record `platform-deferred` and
`systemNotification=not-observed`, never a notification pass. If those paths do
publish, generic payload and accurate return remain required. Privacy, harness,
environment, infrastructure, unexpected product and missing required-signal
failures are never downgraded by applicability. A mode may be compatible with
an explicit non-blocking classification only after all other assertions pass.

The acceptance result MUST use an exact retained candidate by default, record
candidate commit/tree/hash and clean harness commit/tree, and list every
harness-only path between them. An arbitrary HAP is diagnostic-only and
requires `-DiagnosticHap`. A verdict-policy repair may reuse the unchanged
candidate under R1/R2 only after the policy has a red/green software test, the
intervening paths stay on this scenario's allowlist, the clean harness is
requalified and this complete Agent scenario is rerun. Known applicability
limitations do not authorize additional model requests merely to reproduce the
same boundary.

### 2026-08-26 notification applicability research record

- **Question:** whether every Agent/mode must emit a native notification and
  complete a HarmonyOS system notification for the compatibility matrix to
  pass, or whether upstream emission and platform lifecycle are separate facts.
- **Primary/upstream evidence:** OpenTUI documents that notification selection
  is asynchronous, remote/multiplexer sessions often begin without a selected
  protocol, tmux requires DCS passthrough, and queuing an OSC sequence does not
  prove desktop display. OpenCode issue
  [#29099](https://github.com/anomalyco/opencode/issues/29099) records its TUI
  notification failure under tmux/zellij. Pi's shipped
  [`notify.ts`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/examples/extensions/notify.ts)
  is the native OSC 777 source used by the fixture. HarmonyOS documents that
  preventing background suspension requires a declared background-task
  capability and permission. Together with the observed hidden-window behavior,
  this supports the inference that ordinary UIAbility execution has no
  equivalent guarantee. See [OpenTUI notifications](https://opentui.com/docs/core-concepts/notifications/)
  and [HarmonyOS background task management](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V5/js-apis-resourceschedule-backgroundtaskmanager-V5).
- **Agreement with physical evidence:** OpenCode direct emitted complete OSC 99
  and passed, while tmux queried capability but emitted no complete attention;
  Pi direct/tmux emitted OSC 777 after the hidden window had suspended the
  application-side parser. The matrix therefore records wire emission,
  terminal handling and system display as distinct observations.
- **Remaining gap and stop rule:** future Agent or HarmonyOS versions may alter
  these paths. Reassess only when a version change or new native signal provides
  contrary evidence; do not add an Agent-specific workaround, background
  service or second session owner solely to turn a documented limitation into a
  synthetic pass.

The temporary WSL server is owned by its run-scoped
`leantty-agent-compat-<GUID>/sshd_config` and PID file. Cleanup MUST verify that
exact identity, check TERM success, poll the same PID with root permission and
use KILL only for that already-verified PID if it survives the bounded wait.
Stopping the Windows `wsl.exe` wrapper is not proof that Linux `sshd` stopped.
A cleanup pass is invalid if the exact listener or its `sudo` parent remains;
periodic independent process audits may invalidate older cleanup metadata
without invalidating separately proven PTY behavior.

`verify-ssh-matrix-pc.ps1` is the formal SSH physical entry. It runs four
isolated groups in the fixed order below against one retained candidate, stops
at the first failed group, and validates each group's acceptance mode,
candidate SHA-256, clean harness tree, Preferences boundary and cleanup result.
Non-setting groups require a byte-identical Preferences digest. The performance
group requires a byte-identical digest before its intentional transparency
changes, then requires the exact original transparency mode to be restored;
ArkData's serialized bytes are not a valid semantic oracle after those writes.
It does not silently retry or skip a failed group.

| SSH group | Owned public stages | Run-scoped state and primary oracle |
| --- | --- | --- |
| `transport-performance` | terminal key bytes, transport main path, SSH escape and five-mode performance matrix | Fresh fixture/reverse mapping and saved transparency baseline; controlled-server bytes, local escape actions plus device-clock render/performance records |
| `authentication-methods` | password, keyboard-interactive variants, unencrypted/encrypted Ed25519 and imported ECDSA public key plus fallback methods | Fresh credentials and disposable keys; controlled-server authentication result plus recovered session |
| `lifecycle-recovery` | Ctrl+C, Pane close, minimize/restore and process-stop cancellation | Fresh process/window/session boundary; prompt lifecycle state plus a subsequent controlled-server session |
| `pane-focus-attention` | BEL attention and parallel Pane authentication | Fresh single-Pane layout; layout-owned focus/attention state plus independent server authentication |

Each group creates its own fixture process, reverse mapping, known-host
boundary, app restart and evidence directory, then removes or restores those
resources. Groups for the same PC and fixture port MUST run serially. The
performance group captures the existing transparency mode and restores that
exact mode on both success and failure. Its evidence records the digest
comparison boundary and the one allowed, semantically restored setting.

For a routine diagnostic against an explicit test HAP, select one group with
`-DiagnosticHap -HapPath ... -Group <name>`; it remains diagnostic evidence. For
R1 acceptance against the unchanged retained candidate and clean harness, run
`verify-ssh-auth-pc.ps1 -Group <name> -VerifyPreferencesUnchanged`. `-Group`
and `-Only` are mutually exclusive; `-Only` remains ad-hoc diagnostic coverage.
After a formal matrix failure, diagnose only the failed group. Earlier group
passes may be retained and the failed plus remaining groups run in fixed order
only when every C3 reuse prerequisite below is still provable. Otherwise use
R3. No console-only or manually edited result may fill a missing checkpoint.

Public CI independently repeats the public subset. Neither CI nor a clean HAP
automatically proves a physical scenario.

## Acceptance-harness qualification and freeze

After C2 produces the exact retained test HAP and before any formal C3 matrix
stage, run `qualify-acceptance-harness-pc.ps1` with an explicit
`-ReviewHapPath`. A formal qualification requires a clean committed harness and
the HAP must resolve to a clean retained candidate. The qualifier runs the
focused software harness gate and one bounded `password-success` physical
scenario; it does not promote product behavior evidence or replace any C3
scenario.

The qualifier itself owns retained-candidate validation: it resolves the
explicit HAP before device setup and binds its hash and clean source identity to
the final qualification. Its inner `password-success -Only` invocation is a
control-channel diagnostic and therefore always passes `-DiagnosticHap` to the
SSH scenario. This prevents that scenario's product-specific compatibility
allowlist from rejecting unrelated harness-only changes while preserving the
outer candidate check, clean harness check, exact HAP hash, physical evidence
identity and `releaseEligible` decision. It does not make a formal
qualification diagnostic and does not widen the SSH matrix allowlist.

The passing record MUST prove all of the following for its declared context of
use:

- ready HDC plus serialized UiTest layout control before disposable state;
- at least one ordinary command with exact pre-Enter buffer equality, one input
  attempt, zero mismatch and one Enter;
- a runtime-generated non-echoing secret input and structured authentication
  result;
- semantic layout, filtered application logs and the repository-only controlled
  SSH server as independent observation channels;
- successful known-host, reverse-mapping, fixture-process and Preferences
  cleanup; and
- the release-package negative regression that rejects every registered
  acceptance-only marker.

The record separately identifies the review-test HAP/candidate SHA-256 and
source commit/tree, and the harness commit/tree. Only `runMode=formal`,
`result=passed`, `releaseEligible=true` is a release qualification. A dirty-tree
`-Diagnostic` run may develop or check the qualifier but MUST remain
`releaseEligible=false`.

Qualification freezes the harness contract for that formal matrix. Any change
to the review HAP bytes or candidate identity, harness commit/tree, input,
layout, log, fixture, cleanup or release-marker policy invalidates the record.
A device OS/Test Kit/control-channel change before the matrix also requires a
fresh qualification. If a harness defect appears after freezing, stop the
affected stage, classify it and repair the harness outside the running matrix;
then apply the C3 compatibility and R1-R4 rules instead of editing tools while
unrelated stages continue.

## Release-mode review smoke

`verify-review-smoke-pc.ps1 -HapPath <test-signed release-mode HAP>` is a separate
normal-product-path check. It installs and launches the selected ARM64 HAP,
creates one disposable idle Tab, splits and closes a Pane by keyboard, then
closes that Tab through its current UI control. It compares the surviving UI
identities, persisted workspace-only record and Settings digest with the baseline.
The report records package/harness identities, stage timings, cleanup and any
previous failed attempt. Development runs remain `acceptanceEligible=false`;
this script alone does not satisfy the formal C4 release gate.

Signing purpose, build mode and test capabilities are separate checks owned by
`device-package.ps1`. The SDK verifies the actual HAP signature; the extracted
Profile must be `debug` for device testing, irrespective of the filename. APPs,
production/unknown Profiles, wrong bundles and non-ARM64 packages are rejected
before installation. A review smoke requires `app.debug=false` and the shared
release-package audit must find no acceptance markers. Marker-based scenarios
require `app.debug=true` plus the native-input/submission capabilities. The
default `dev-pc.ps1` purpose is `acceptance`; the review script explicitly selects
`-HapPurpose review-smoke`. Do not use a release-mode review HAP for the harness
qualifier or other exact-command-input scenarios.

The smoke sends no ordinary text or Enter and does not call acceptance-only
commands, parse their log markers, access SSH credentials or change the network.
UiTest node identity is valid only within this observed run; titles may repeat.
The current persisted workspace supplies active Tab position because UiTest may
omit accessibility labels. An ambiguous identity or unknown input outcome stops
the attempt without repeating the action. Failed cleanup makes the run invalid.
Use `policy,tooling` for the local contracts and this one named scenario for L3;
do not start a full matrix to validate these tooling changes.

## Formal checkpoints and rerun policy

Full release testing is checkpointed work, not one indivisible terminal command.
A failure response is determined by evidence identity and affected state, not by
how expensive the previous run was.

Before freezing C0, run `test-release-readiness.ps1` against independent clean
production/review checkouts and one release-mode HAP. The drill runs only the
focused `policy,tooling,web,arkts` gate, offline Agent compatibility replay,
the shared full Agent-result constructor and atomic write/read-back path,
release-package marker audit, stable candidate-namespace check and both release
preflights. The synthetic Agent result represents the complete four-Agent by
direct/tmux matrix and forty local plus forty connected command observations;
it contains no terminal content or credentials and invokes no Agent or model.
The round trip must preserve all eight unique Agent/mode checks, the planned
eight-request contract, nested inventory/privacy and cleanup fields, and a JSON
size of at least 20,000 UTF-8 bytes. Its evidence must state `releaseEligible=false`,
`candidateCreated=false` and `agentModelInvocations=0`. Failure repairs the
corresponding product/tooling input before C0; the drill never creates or
substitutes for a formal candidate.

### Formal checkpoints

| Checkpoint | Required output | Reusable when |
| --- | --- | --- |
| **C0 — release source** | Clean committed commit/tree, finalized version and packaged resources; the same identity must be pushed before production/review release work | The exact source identity remains unchanged |
| **C1 — software gate** | Passing `test-regression.ps1` evidence bound to C0 | No source, dependency, workflow or required-toolchain input changed |
| **C2 — retained candidate** | Passing `verify-pc.ps1`, signed ARM64 HAP SHA-256 and manifest | C0/C1 remain valid and the candidate file/hash is unchanged |
| **QH — harness qualification** | Passing formal `harness-qualification.json` bound to the explicit C2 test HAP and clean harness | Candidate/HAP, harness, qualification contract and device Test Kit/control environment remain unchanged |
| **C3 — physical stage** | Named acceptance result, candidate/harness identity, attempt identity and successful cleanup | The stage is independent, all identities still match and no shared state was contaminated |
| **C4 — production/review artifacts** | Matching source/tree/version/ABI/native identity, signatures, hashes and artifact roles | No release input or artifact bytes changed |

“Complete applicable physical matrix” means every required C3 stage has a valid
Pass for one C2 candidate and a compatible clean harness. It does not require
one uninterrupted wall-clock process. It does require explicit checkpoint
evidence; operator memory, console scrollback or a diagnostic result cannot be
combined into release acceptance.

Checkpoint reuse is allowed only when the owning script/evidence format can
record and validate it. Until a scenario supports acceptance-mode resume, rerun
the smallest enclosing acceptance script rather than manually promoting an
`-Only`/`runMode=diagnostic` result. SSH groups are the acceptance-mode resume
boundary; individual stages inside a group are not.

Checkpoint JSON is replaced atomically after each independent group. It records
the exact candidate commit/tree/HAP hash, clean harness commit/tree, attempt and
previous-attempt identity, result and cleanup audits. A separate `progress.json`
may expose only scenario, Agent/mode or stage, counts and timestamps; it must
record `contentRecorded=false` and never contain PTY input/output, prompts,
Agent replies or credentials. SSH `-Resume` first validates the fixed-order
prefix and exact identities, then performs a read-only device/reverse/process
audit before selecting the next group. Agent/mode and notification workload
runs use the same atomic attempt/progress contract; a diagnostic retry remains
diagnostic and cannot be promoted to acceptance.

### What “restart from the beginning” means

Use these four scopes explicitly in reports and decisions:

1. **R1 — rerun the current stage:** restore that stage's declared initial state
   and execute only the failed named stage.
2. **R2 — continue from the failed checkpoint:** rerun the failed stage, retain
   earlier independent C3 passes, then execute only the remaining stages.
3. **R3 — rerun the full physical matrix on the same candidate:** retain C0–C2,
   invalidate all C3 results and rerun every applicable physical scenario.
4. **R4 — create a new candidate and restart the formal gate:** invalidate C1–C4,
   freeze the corrected source, rerun the software gate, build a new candidate
   and execute the complete physical and release gates.

Do not use the ambiguous instruction “rerun everything” without naming R1–R4.

### Evidence reuse prerequisites

R1 or R2 is permitted only when all of these are true:

- release commit/tree and candidate HAP SHA-256 are unchanged;
- the clean harness is identical or differs only through the scenario's explicit
  compatible harness/document allowlist;
- the failure domain is known and does not invalidate earlier observations;
- the failed stage can restore and verify its initial state;
- run-scoped accounts, keys, files, port mappings, sessions and application
  state were removed or restored; and
- earlier stages do not depend on state mutated by the failed stage.

If any prerequisite is unknown, do not guess. Escalate to R3; if product or
candidate identity changed, escalate to R4.

### Failure-to-rerun decision table

| Failure or change | Required response | Scope |
| --- | --- | --- |
| Routine L0–L3 test exposes a product defect | Fix the product and rerun the affected development tests; do not start L4 merely because a test failed | Change-scoped only |
| Formal product assertion fails and product code/resources/dependencies must change | Stop acceptance, discard the old candidate and verify the corrected source | **R4** |
| Harness defect is local to one named stage and earlier evidence did not use the faulty path | Commit the harness fix, prove it with a diagnostic, then rerun that stage in acceptance mode and continue | **R1/R2** |
| Harness defect affects shared input, layout, logging, fixture, cleanup or verdict logic used across physical scenarios | Keep the unchanged candidate only if compatibility is proven; invalidate prior physical verdicts | **R3** |
| Environment/infrastructure fails before or during one stage and cleanup is verified | Restore the precondition, rerun that stage and continue from its checkpoint | **R1/R2** |
| A consequential action was sent but its result is unknown | Never resend blindly; reset and verify the stage state, then rerun the stage | **R1**, or **R3** if reset/cleanup cannot be proven |
| Cleanup failed, shared state may remain, or evidence cannot identify what executed | Independently remove/verify state and invalidate all possibly affected physical evidence | **R3** by default; **R4** if candidate identity is also uncertain |
| Device reboot, OS update, application-data reset, test-device trust/permission change, or controlled server reset changes a matrix-wide precondition | Keep the same verified HAP only when its hash remains exact, then renew all physical evidence | **R3** |
| Source, dependency, lockfile, packaged resource, version, manifest, native library, HAP bytes or candidate hash changes | Build and verify a new formal candidate | **R4** |
| C1 software gate fails before a candidate exists | Diagnose with the smallest failing check, fix it, then rerun the complete C1 gate from a clean identity | Restart **C1**; no C3 work exists to repeat |
| Production/review build or signing fails for an external configuration reason while source/native identity and successful counterpart artifacts remain exact | Repair the external input and retry the failed build/checkpoint using the reuse options in `release-process.md` | Retry **C4**, not product tests |
| Evidence copy, report generation, GitHub upload or AppGallery network transfer fails while immutable artifacts and hashes remain intact | Retry only the failed external operation | No test rerun |
| AppGallery rejects a version after its GitHub Release was published | Preserve the immutable release, advance the version and follow the complete new release process | New version, **R4** |

### Failure handling procedure

At the first failure:

1. stop the enclosing matrix before executing unrelated later stages;
2. capture the stage, candidate/harness/attempt identities, failure domain,
   live status, relevant layout/screenshot/log evidence and cleanup result;
3. choose the smallest diagnostic that distinguishes product, harness,
   environment, infrastructure and unknown-outcome hypotheses;
4. do not repeat the same full matrix while the failing precondition is still
   unproved; and
5. after correction, apply the table above and record R1–R4 explicitly.

Repeated diagnostics are useful only when each run tests a different hypothesis
or establishes a missing precondition. A passing diagnostic never becomes
release acceptance by itself.

Each physical stage declares a conservative fixture budget. Fixture lifetime is
the sum of selected stages plus setup/cleanup margin, and the invoking terminal
or agent timeout MUST exceed that published lifetime plus cleanup margin. A
client-side pipe timeout or `EPIPE` is an interrupted run, not a product result;
inspect `live-status.json`, allow bounded cleanup to finish when possible and
apply the same R1–R4 rules.

Candidate source and harness identities are separate. Candidate reuse is
allowed only when the candidate commit is an ancestor of the clean harness and
every intervening path is on the scenario's explicit harness/document allowlist.
Any ArkTS, Rust, Web/package resource, dependency or build-input change requires
R4.

The retained-candidate namespace is derived from the normalized `origin`
repository identity, not a checkout's Git common directory. Independent
production, review and harness checkouts therefore resolve the same candidate
store while explicit HAP selection still has to match a retained manifest and
SHA-256 record.

## Candidate and evidence states

Retained candidates use only these monotonic modes:

| Mode | Meaning |
| --- | --- |
| `software` | Formal release software gate and exact clean ARM64 HAP build passed |
| `device-deployed` | The same HAP was installed and launched on a physical ARM64 HarmonyOS PC |
| `device-behavior` | One or more named physical behavior scenarios passed against the same HAP |

A later lower-layer run MUST NOT downgrade a candidate. `device-deployed` MUST
NOT be described as physical behavior acceptance. Physical behavior evidence
MUST NOT promote a dirty candidate: commit first, rebuild once, then test that
unchanged HAP. Source, dependency, packaged resource, signature, HAP, relevant
platform or affected server changes invalidate the corresponding evidence.

Evidence files are machine-local and MUST NOT contain credentials, passphrases,
private keys, fixed device identifiers, private host addresses or unredacted
logs. Physical evidence MUST identify both the tested candidate and the clean
committed automation harness when they come from different commits. Public
summaries carry only the minimum redacted identity and result.

## Physical automation protocol

`verify-agent-compatibility-pc.ps1 -DiagnosticHap -ExitBoundaryProbe` runs the
zero-model Agent exit boundary only: start the real TUI, send its documented
exit command once, await its child result and a fresh Bash prompt, then close
SSH once. It covers the selected direct/tmux callers; IME, resize, notification,
network and lifecycle checks are excluded, not passed. The shared Agent harness
invalidates prompt readiness before submitting a connected command. Failed or
unconfirmed TUI interactions leave cleanup to the isolated Tab, never a repeated
exit sequence. See the [exit-boundary repair](design/agent-exit-boundary-20260912.md).

`verify-agent-compatibility-pc.ps1 -DiagnosticHap -SshPrerequisiteProbe` is the
zero-model diagnostic for the Agent harness's SSH prerequisites. It skips Agent
configuration, inventory and launch, reuses the normal connect/locale/close
helpers, then runs the existing isolated-resource finalization. Fresh remote
shell readiness and command output prove the connection; the current close
event permits local cleanup. Failure stops the probe without retrying uncertain
input. Its three ordinary local commands also provide the minimum UiTest input
smoke when exact buffer, single Enter and resulting operation all pass. This
does not replace Agent/IME acceptance or establish natural-input reliability.

Shared verification primitives have one narrow owner. `candidate-store.ps1`
resolves retained HAP identity and SHA-256 provenance; `hdc-common.ps1` owns
checked HDC execution, confirmed non-empty device-file receive and the raw
UiTest layout capture/transfer; `device-regression.ps1` owns serialized UiTest,
bounded layout retry, shared fixture-readiness parsing and concurrently written
fixture-log reads. Scenario scripts retain their own entry points, budgets,
oracles, failure wording, evidence schema and cleanup decisions. New shared
helpers must extract an already repeated stable rule, not create a generic test
framework or move scenario judgment away from its owner.

The maintainer agent owns routine device acceptance whenever the connected PC
and repository tools make it objectively possible. It MUST inspect device state,
drive the scenario and read logs/layouts itself. User validation is requested
only for an objective blocker such as a locked device without its dedicated
local test credential, a disconnected device, missing permission, unavailable
controlled server or a necessarily subjective judgment.

Every automated physical scenario MUST:

- resolve a ready physical ARM64 PC at runtime and never commit its identifier;
- pass `preflight-device.ps1`, or perform the same ready-target, checked HDC and
  serialized layout controls internally, before installing or creating test
  state. The preflight MUST NOT launch, unlock or repair an unavailable device;
- install an exact retained candidate and record its SHA-256 before interaction;
- acquire a bounded screen-timeout override before launch and restore the prior
  device policy in `finally`, so unattended execution cannot silently relock;
  its duration MUST cover the sum of selected stage budgets plus setup/cleanup
  margin rather than use a shorter fixed default;
- when HarmonyOS explicitly reports a locked screen, unlock only the dedicated
  test PC from a current-user plaintext credential stored outside the repository;
  inject numeric physical-key events without putting plaintext in commands,
  logs or evidence, and never type a credential on an already unlocked device;
- preflight every control and observation channel, including application PID,
  structured logs, layout capture, focused terminal input and any HDC reverse
  mapping, before creating disposable device state; repeat the cheap target and
  mapping checks at stage boundaries. An `Offline`/missing target is an
  infrastructure stop, not authorization to restart HDC or repair the device;
- locate UI controls from current layout semantics and native bounds, not stale
  screenshots or Windows-scaled coordinates;
- preserve LeanTTY's current Pane subtree order when enumerating terminal
  inputs. `Index` mounts each Tab's Panes in model order; xterm textarea bounds
  follow each cursor and MUST NOT define left/right identity. A two-Pane focus
  check requires exactly two inputs and exclusive focus on the requested Pane.
  Exclude descendants of hidden/non-interactive retained Tab wrappers, but not
  xterm's intentionally transparent textarea. Equal Pane bounds require a
  geometry diagnostic; do not assume they are merely an accessibility artifact.
  Re-read the layout for each observation and do not persist hierarchy paths
  or accessibility IDs across a rebuild;
- never run two physical scenarios against the same target concurrently;
- inject ordinary terminal text as one focus-verified, coordinate-targeted
  serialized UiTest `inputText` operation. Inside the same device mutex, capture
  a fresh layout, require exactly one focused semantic text node, verify the
  caller's intended target, derive coordinates from that current node, and then
  inject the complete payload, then capture another layout under the same mutex
  and verify that the same target retains exclusive focus. Scope terminal
  post-input identity to the unchanged native Web instance: nonblank window ID
  and accessibility ID must match, and that Web identity must occur exactly once
  in each operation-local layout, with exactly one terminal input in its subtree.
  Native hierarchy is a child-index path, not instance identity; ancestor indices,
  virtual DOM hierarchy and cursor-following textarea bounds may change. Another Web,
  window, replaced native instance or ambiguous terminal remains a failure.
  Other text controls keep their operation-scoped field identity checks. Scope
  this identity to the current operation; never cache it across navigation or
  rebuilds. Owner loss stops the operation before any retry, Ctrl+C or Enter;
  only an inexact buffer with its original owner intact may be retried.
  Do not use focused `uiInput text` for arbitrary
  payloads: on UiTest 6.0.2.3 a payload such as `help` is parsed as the CLI help
  subcommand and returns success without delivering text. Reserve numeric
  physical-key events for shortcuts, modifiers and special-key semantics.
  Common helper-driven layout, click, text, key and screenshot operations MUST
  share the same device-scoped UiTest mutex because the platform interface is
  not concurrent;
- use `diagnose-text-input-pc.ps1 -Scenario pane-ownership -HapPath <signed HAP>`
  for the no-network/no-Enter split/close-left/resplit input boundary. It checks
  retained native input, full-width restoration, non-overlapping Web geometry
  and isolation from the new Pane, then closes only its disposable Tab/Panes.
  This is focused diagnostic evidence, not a release scenario;
- use `diagnose-text-input-pc.ps1 -Scenario ime-input -HapPath <signed debug HAP>`
  for the system-IME boundary without SSH or an Agent. One disposable local Tab
  checks English keys, pinyin commit and repeated ASCII after composition against
  the native input buffer. It uses system key events, not direct CJK text injection;
  an English-mode baseline and the expected Chinese candidate are preconditions.
  No Enter, network, model request or retry is allowed. A mismatch stops the probe
  before attribution; restore input mode, remove the owned Tab and return the
  screen-timeout policy. This is L3 system-IME evidence, not a human-keyboard
  reliability sample or a replacement for formal remote TUI acceptance;
- `diagnose-text-input-pc.ps1 -Scenario input-order -HapPath <signed debug HAP>`
  is a one-shot public-vector diagnostic, not a reliability sampling loop. Its
  per-Pane collector records numeric event metadata only, stops at 256 rows or
  20 seconds, and reports after capture. Never submit the vector or infer loss
  from input-event counts alone: ordinary keys can produce onData without an
  input event. Missing/truncated chunks invalidate the trace; no bad sample
  means insufficient causal evidence and no automatic retry;
- `diagnose-text-input-pc.ps1 -Scenario input-attribution -AttributionMode <0-3>`
  compares a test-only plain textarea and unchanged xterm handlers in the same
  ArkWeb. Modes 0/1 use one UiTest vector; 2/3 require a real keyboard and MUST
  announce READY only after arming. Each document accepts one arm, at most 256
  numeric rows and 20 seconds (automatic) or 60 seconds (manual). Observe the
  original deferred-diff callback without changing its delay or invocation count;
  compare public-vector equality in memory and retain no contents. The plain
  fixture owns test-only Bridge focus, not the normal terminal input path.
  Stop on mismatch or owner loss. A passing cell is not reliability sampling or
  causal proof; an operator key during setup invalidates that attempt. Arming
  submission and probe/timeout cleanup have separate evidence. No authentication,
  network change or vector submission belongs in this diagnostic;
- `input-attribution -AttributionMode 4` extends that diagnostic with one
  180-character UiTest call in a disposable idle xterm Tab. It observes the
  original diff scheduling/execution, onData, WebMessagePort post attempts and
  completion, owner-Surface receipt counts and native buffer equality. It keeps
  only numeric metadata, stops at 20 seconds or 4096 rows, and never submits the
  vector. Preserve the first mismatch trace; a clean trace does not authorize
  further sampling. This test-only observer may affect timing, so neither a
  clean result nor the synthetic browser reproduction proves a device cause;
  the 2026-09-06 mode-4 run exhausted this cap at character 156. Before another
  full-chain run, validate the vector/event budget in software and avoid relying
  on the 500-line hilog tail for a full native timeline. The later 4096-row cap
  has a 2365-row normal-vector regression; it does not validate the earlier run;
- attribution profiles 5/6/7 isolate observer effects, not product fixes.
  Profile 5 leaves detailed IDLE action/result logging on and the Web trace off;
  6 disables only those two test logs; 7 adds the mode-4 Web trace to 6. Each uses
  the same public 180-character call and one owner-buffer summary after a
  23-second window. Read logs only after injection; do not insert per-character
  queries or change injection pacing. Production/ACK logs, inactive observer
  checks and the final timer remain present, so controls are not zero overhead.
  Cancellation or Surface detach clears the temporary owner-local log gate;
  non-idle final state is invalid and its buffer is never read. A fixed contrast
  with no fault cannot rule out timing effects or justify repeated sampling;
- `tools/web-terminal/input-order-repro.html` and `verify-input-order-repro.mjs`
  isolate one synthetic input-order mechanism against the unchanged pinned npm
  xterm in a desktop browser. The fixed ten-page check is not HDC/IME input,
  physical acceptance, a frequency estimate or proof of LeanTTY's device fault.
  Keep it outside the normal pass gate: its expected missing output characterizes
  a candidate defect, not correct product behavior. See `input-order-repro.md`
  beside the page for dependencies, controls, scope and upstream references;
- `verify-xterm-input-order.mjs` is the separate correctness corpus for the
  build-time input repair. Run `upstream` and `packaged` against the same cases:
  pristine upstream must retain the known failures, and the repaired asset must
  pass. It uses actual DOM/timers without runtime method replacement. The `web`
  group also runs generated-owner unit cases and rejects patch/version/hash
  drift. Physical validation reuses profile 8, the plain/masked pair, Pane
  ownership and one zero-model physical IME TUI probe. Profile 8's old headline
  classifies the defect signature, not repair success: correction requires all
  50 DOM/output cases exact, 40 xterm/owner-Surface/native units, complete trace
  and successful cleanup. A corrected synthetic run does not attribute historical
  natural losses; `verify-input-synthetic-repro.mjs ... packaged` validates the
  existing trigger and cancellation boundaries against the corrected asset;
- attribution profile 8 is a controlled synthetic-order diagnostic on the
  physical PC, not natural-input sampling. Ten fixed sets run normal, delayed,
  early-keyup, input-only and plain-textarea controls. Use the actual disposable
  idle Pane's xterm for terminal cases; reset only public textarea.value between
  cases. Keep original xterm handlers and timers, no UiTest vector or vector
  Enter. Observe per-case DOM/onData and owner-Surface/native totals; the expected
  defect signature is ten missing outputs and forty successful controls, not
  correct product behavior. Stop on owner/security/replay/interference change,
  or the ten-second budget. A complete 51-row numeric report and the 23-second
  native summary are both required. Completion polling may overlap synthetic
  dispatch; do not claim zero observer overhead or equivalence to trusted input.
  `verify-input-synthetic-repro.mjs` checks the same trigger in Chrome before
  deployment and remains outside the normal correctness gate. A controlled
  device reproduction does not establish the cause of earlier natural losses;
- a disposable numeric password for an explicitly selected system-OpenSSH
  compatibility diagnostic may be entered as individual physical digit keys
  when the masked password buffer intentionally cannot be observed. Generate it
  per run, pass it to Linux account tooling through LF-only stdin, never put it
  in an HDC command or evidence, and delete plus absence-audit the account and
  home in `finally`; this exception does not authorize physical-key emulation
  for ordinary command text;
- before Enter can submit an ordinary local command, start from a verified empty
  state, read the acceptance-only native command buffer and require an ordinal
  character-for-character match. A mismatch may be cleared through the real
  `Ctrl+C` path and retried at most three total input attempts; log only lengths,
  the first mismatch index and attempt count. Enter is injected once only after
  the exact match. A missing exact submission acknowledgement is an unknown
  outcome and MUST NOT trigger another Enter. The final stage verdict still uses
  the controlled server, file/state or other business postcondition;
- before Enter can submit a repository-only command inside a controlled SSH
  fixture session, require the fixture's temporary current-line snapshot to
  match the expected bytes exactly. An incomplete line may be cleared with the
  fixture's verified `Ctrl+C` path and the text retried at most three total
  attempts; Enter remains single-shot and is forbidden before exact server-side
  observation. Retain only lengths, mismatch position and attempt counts in
  evidence, and remove the raw temporary snapshot with the fixture;
- activate the application, locate the current active terminal input and prove
  focus immediately before each command or hidden response; a system
  notification, dialog or foreground-window change invalidates that input
  attempt;
- generate disposable names and secrets at runtime, keep secret input non-echoing
  and scan captured layouts/logs for disclosure;
- wait on observable state or a non-secret structured log marker; fixed sleeps
  MAY pace polling but MUST NOT decide success. Full layout dumps and bounded
  HiLog snapshots are diagnostic observations: do not repeat them faster than
  their platform cost or request them when a cheaper stage postcondition exists;
- drive a requested Wi-Fi change through the visible system Settings UI. Before
  opening it, normalize the panel from its current semantic open/closed state;
  never send a blind Back action. Use the exact operator-supplied saved SSID only
  to select the row. Read the current target SSID from the checked
  `hidumper -s WifiDevice` system-service state, not localized Settings text or
  an acceptance-only product permission. The parser MUST require one active
  state, one connection state and at most one connected SSID, and fail as a
  harness error if that source schema drifts. Then judge readiness from the
  target SSID, active WLAN link, assigned link address and direct endpoint
  reachability. Record a longest-prefix classic route when the system exposes
  one, but do not require it before probing: HarmonyOS policy routing may make
  the endpoint reachable without listing that route in `netstat -rn`. A global
  route-table digest is not a transition oracle. Record these states in order;
  do not start the product recovery assertion until every required state holds;
- request the default filtered UiTest layout for routine semantic selection.
  Extended visual attributes (`dumpLayout -a`) MAY be requested only by a named
  diagnostic that consumes them; routine focus, disclosure and state checks MUST
  NOT pay that cost speculatively. A current unique focused input is sufficient
  for ordinary text injection; click and recapture only after an interaction that
  can invalidate focus or when the current layout does not prove unique focus;
- retain success screenshots only when pixels are the primary oracle or are
  required to audit a user-visible state that semantic evidence cannot prove.
  Performance and protocol scenarios use their declared device-clock, server or
  final-state oracle and upgrade to screenshot/layout/log diagnostics on failure;
- when a consequential input has been sent but its acknowledgement is missing,
  classify the outcome as unknown and restart that isolated scenario from a
  known state. Never blindly resend a command, secret, confirmation or fixture
  mutation that may already have taken effect;
- never treat the count of repeated hilog lines as lossless keyboard delivery.
  Acceptance-only input telemetry may confirm one submitted input event with a
  monotonic sequence and non-secret kind, but the stage verdict MUST still use
  the resulting product state or server outcome;
- cancel input through the application's real `Ctrl+C` state-machine path;
  ArkWeb's hidden textarea accessibility value MUST NOT be treated as the
  native local-command or secret-input buffer;
- cover the positive path plus applicable rejection, cancellation, retry,
  recovery and cleanup paths;
- report stage start/pass progress and duration so a stalled boundary is visible;
- write a machine-readable pass/fail record, including per-stage timing and the
  cleanup outcome, attempt/previous-attempt identity, candidate and harness
  identities, selected stages, failure domain and resource manifest; update a
  small live-status file at every stage boundary; and
- remove disposable device state in `finally` through the product's create/delete
  semantics first, then independently verify absence in the application sandbox.
  Direct filesystem deletion is emergency recovery, not accepted cleanup, and
  evidence promotion is forbidden when any run-scoped resource remains. A
  failed restoration of pre-test Wi-Fi marks the environment dirty and blocks
  another network scenario until recovered; it does not rewrite an already
  observed product transport verdict. Record the two results separately;

UI automation MUST model each consequential interaction as an explicit state
transition: action, expected dialog, confirmation action and observable
postcondition. Clicking a close/delete control without handling and verifying
its confirmation state is incomplete automation.

Background-BEL publication scenarios use the existing system notification
settings entry to establish an enabled fixture. Capture the original toggle
before mutation, confirm and reopen it to verify persistence, and restore that
original state even if a later action fails. The permission scenario separately
tests disabled/deferred and enabled/published behavior. Match complete runtime
Pane IDs with field boundaries; a BEL `fired` marker does not acknowledge the
asynchronous notification publication. A permission dialog is an obstructing
system surface, not evidence of Pane loss. Reject only the identified LeanTTY
notification prompt when returning from that fixture; never dismiss an unrelated
dialog. A previous refusal can prevent the platform from showing the prompt
again: report whether it appeared without clearing user data to force it.
Cleanup requires direct notification-card absence and restored system settings,
not a cancellation log for a notification that may never have existed.
`test-notification-regression.ps1`, included in the `tooling` group, exercises
the actual notification helpers and scenario publication/finally boundaries.

Long-task and Agent notification workloads establish and restore the same
permission fixture; earlier permission scenarios may leave notifications off.
`verify-long-task-notification-pc.ps1 -DiagnosticHap -ShellOnlyProbe` runs only
the real shell BEL/return/cleanup chain with zero model requests. It cannot
qualify as formal long-task acceptance. The Agent SSH prerequisite probe also
checks permission preparation/restoration without launching an Agent; it does
not prove Agent notification publication. See the
[2026-09-11 repair record](design/notification-fixture-permission-20260911.md).

Each named scenario declares one primary oracle for its claimed result. SSH and
transfer claims use the controlled server or final file/state; input-integrity
claims use actual echo or received bytes; UI/focus claims use the current layout
plus the resulting operation; visual claims use a screenshot or bounded human
review; performance claims use device-clock events. HDC exit codes, launch/PID,
hidden textarea values and HiLog line counts are setup or diagnostic evidence,
never a primary pass oracle. Add a second boundary observation only when risk or
ambiguity requires it; collecting every expensive observation at every poll is
not acceptance rigor.

Local commands used only to prove input or lifecycle recovery MUST avoid
unrelated permission requests. Top-level `help` synchronizes the offline guide
and may request Downloads access; use topic help for recovery and synthetic
search content, with a matching output oracle and sufficient scrollback data.
Actual guide/Downloads tests retain their permission contract. Do not grant a
permission globally, increase layout retries or change product permission policy
to make an unrelated recovery probe pass. `test-recovery-command-probes.ps1`
executes the real scenario command boundaries in the `tooling` group.

A composite scenario MUST give each independent product claim its own direct
oracle. Do not infer terminal page restoration from Search UI state, Session
ownership from a derived AppStorage projection, or network recovery from process
survival. Test page restoration, discarded-session isolation, search-history
isolation and transport recovery as separate postconditions, then aggregate
their verdicts without letting one feature stand in for another.

For Mosh page restoration, the baseline fingerprint MUST be captured in the
same xterm write callback that produces the saved snapshot, after queued output
has been parsed. The result fingerprint MUST be captured after replay and the
saved viewport have both completed, but before the page-replacement ACK or any
local recovery output. Compare buffer kind, dimensions, viewport and visible
cell content. A marker captured before the `mosh` command and a later Search
match are not page-restoration oracles.

Bind the baseline and Mosh-page fingerprint to the exact connection being
closed. A composite scenario that connects again in a surviving Pane must read
that connection's saved snapshot, even when both connections have equal
dimensions. Consume independent lifecycle evidence before fingerprint helpers
clear its logs; a correct page comparison must not weaken Pane-isolation checks.

Exact visible-page equality requires the same terminal dimensions. Different
dimensions invalidate that comparison; they do not establish lost content.
Resize coverage must separately compare replay with a live xterm resize,
including framebuffer, wrapping, cursor, viewport, subsequent writes and search
isolation. A composite network scenario may close its completed idle comparison
Pane before the exact page check, but that does not replace resize coverage.

Physical keyboard injection MAY be used only for a scenario whose contract is
the physical shortcut or special-key path, after the script verifies the focused
application and the resulting operation. Ordinary text uses the single UiTest
`inputText` path. ArkWeb's accessibility textarea is useful for focus preflight and
disclosure scans, but is not exact input evidence: on the target PC it can omit
rendered digits and diverge from the native buffer.

## Result classification

- **Pass:** every required assertion completed for one exact evidence identity.
- **Product failure:** the application produced an incorrect observable result.
- **Harness failure:** automation used a stale selector, invalid state model or
  unreliable observation.
- **Environment failure:** focus, notification, lock state or another desktop
  condition invalidated interaction while the device and tools remained usable.
- **Infrastructure failure:** the device, server, SDK, signing or transport
  could not establish the required precondition.
- **Unknown outcome:** a consequential action may have executed but its required
  acknowledgement or postcondition could not be observed; blind retry is unsafe.
- **Invalid/interrupted:** the candidate changed, evidence identity is missing,
  cleanup makes the result ambiguous, or the run stopped early.

Only **Pass** counts as acceptance. Infrastructure failures must be repaired and
rerun; they must not be relabeled as product passes or product regressions.
Unknown outcomes require a verified state reset before R1, otherwise R3.

Machine evidence MUST keep the business verdict and harness stability as two
orthogonal fields. A business postcondition that passes after an input retry is
`passed` plus `flaky-harness`, not a stable pass. Ordinary-command evidence must
remain content-free while reporting the semantic stage, expected/actual lengths,
input attempts and mismatches, Enter count, duration, failure domain and last
proven boundary. `passed` with one attempt is `stable`; a retry-success is
`flaky-harness`; a command-contract failure is `failed-harness`; and any action
whose side effect cannot be confirmed remains `unknown`. Environment or
infrastructure interruption before the contract can finish is `not-assessed`,
not a harness failure. A `not-exercised` automation value is valid only when the
selected scenario did not use that path.

## Change-to-evidence matrix

| Change area | Routine minimum level | Minimum additional evidence |
| --- | --- | --- |
| Parser/help/config semantics | L0–L1 | Parser tests, help/reference update, supported/unsupported cases and no side effect before validation |
| SSH host-key/auth/session lifecycle | L0–L3 | Controlled server, positive and negative protocol cases, cancellation/stale event cases, affected ARM64 boundary and named physical keyboard/session scenario |
| Mosh bootstrap/UDP/session page | L0–L3 | Parser/library-owner tests, bounded input/output and close/cancel checks, plus only the affected named physical Mosh scenario below; complete lifecycle/network matrix is reserved for the exact formal candidate |
| Terminal bytes/xterm/Bridge | L0–L3 | Raw-byte and malformed-message tests, flow-control/snapshot regression, large TUI output and affected physical renderer interaction |
| Tab/Pane/focus/shortcuts | L0–L3 | Ownership tests plus named physical keyboard, system/IME conflict, selection or cross-Tab scenario affected by the change |
| Clipboard or URL effects | L0–L3 | Policy tests for allowed/denied payloads plus affected physical system-service behavior and privacy/security review |
| Persistent assets/migration | L0–L3 | Format and failure-injection tests, atomic commit/delete/recovery and only the affected uninstall/reinstall, lock/reboot or different-signature physical scenario |
| Window/theme/font/lifecycle | L0–L3 | ArkTS policy tests, affected build boundary and named physical minimize/background/restore/restart behavior |
| Dependency upgrade | L0–L2, plus L3 when device behavior is owned | Lockfile/license/source checks plus all behavior owned by that dependency; xterm/russh updates require their affected terminal/SSH areas |
| Release or signing workflow | L0–L2 during development; L4 only for a release | Script regression, clean detached-checkout preflight, version alignment and the affected manifest/hash/candidate-continuity rules |
| Documentation-only | L0 | Link/reference, status/authority, TODO uniqueness, wording consistency and `git diff --check`; no build unless the document changes generated/package behavior |

Risk raises the depth of the mapped L0–L3 evidence. A tiny code diff in host
trust, authentication, terminal bytes, persistence or release identity remains
high risk, but routine risk alone does not authorize L4.

## Permanent automated regression areas

The automated suite should keep stable ownership over:

- exact known-host endpoint formatting/query/removal, including hashed and shared
  records;
- key name/path safety, pair verification, no-overwrite export and failure
  cleanup;
- supported command parsing and explicit rejection of unsafe/unknown syntax;
- `Tab → Pane → Session` creation, focus, close and isolation;
- cancellation and clean/unexpected close classification;
- Bridge direction/channel/kind validation, bounded payloads and ACK ordering;
- raw UTF-8 split boundaries and high-density TUI output;
- OSC 52, URL, selection, input, wheel, bell and snapshot policy;
- persistent record encoding, chunking, manifest integrity and generation
  failure; and
- build locks, candidate retention and release preflight behavior.

A test name should state the contract. Tests must avoid real credentials,
production hosts, device identifiers and unredacted logs.

## Acceptance-only product hooks

An acceptance-only entry is permitted only when a required physical condition
cannot be triggered or observed reliably through normal HarmonyOS/product
interfaces. It MUST be guarded by the compile-time `ACCEPTANCE_TESTS` field,
invoke the unchanged production event chain, expose no real credential, create no
parallel business state and have a named regression owner. Runtime hiding alone
is prohibited.

Controlled development diagnostics may observe necessary terminal contents or
isolated disposable fixture secrets under `security-model.md` → Logging boundary.
Record the collection scope, bounds, retention and cleanup before running them.
Ordinary debug use does not authorize real-secret capture. Shared evidence remains
redacted; this exception does not relax authentication, history or persistence tests.

Production ArkTS files MUST contain no acceptance-only entry or helper. The
versioned `acceptance-source.ps1` transformation injects the minimal guarded
ArkTS only while a debug/test HAP is compiling and restores every source file
byte-for-byte in `finally`. Release builds never run that transformation, set
`ACCEPTANCE_TESTS=false`, enable branch elimination as defense in depth, and
`build-all.ps1` scans both unsigned and signed release HAPs for every registered
acceptance marker and helper symbol. Finding one fails the formal build. New
hooks MUST add a unique marker to that package policy, an injection/restoration
test and a negative package test. Remove a hook when its associated gate
disappears or normal system control becomes reliable.

`performance-diagnostic-source.ps1` owns the debug ping/output probes. The
`performance-diagnostic-isolation` ArkTS check executes the real input/output
owners with public canaries, verifies debug metrics and production silence,
preserves Keypush and SSH input, and checks source restoration. Tooling tests
reject every registered performance marker in package entries. A hook-free
development build or synthetic ZIP is not formal release-package acceptance.
The bounded full-output oracle also rejects wrong content/order and ignores
out-of-frame prompt bytes. Automatic public-vector input and WebGL context-loss
triggers are disabled in ordinary debug packages. Enable them only for a dedicated
fixture run during build, restore the source afterward, and verify the retained
ordinary package disables them before returning the device to normal use. Remote
terminal output is not authority to inject input in an ordinary development session.

Acceptance configuration MUST NOT shorten or bypass the production timeout,
retry, authentication or cleanup policy being claimed. A shorter diagnostic
budget may bound fixture/process lifetime, but final timeout evidence must run
the unchanged product value or be explicitly labeled diagnostic and followed by
one real-duration production check.

## Permanent physical-PC regression areas

The formal release matrix exercises these areas on a physical ARM64 HarmonyOS
PC:

- application launch, window controls, geometry, theme and font restoration;
- physical keyboard input, modifiers, IME, focus and terminal query responses;
- Tab and two-Pane isolation, focus restoration and close confirmation;
- local selection, copy, paste, tmux mouse mode, OSC 52 and URL activation;
- direct password, encrypted/unencrypted keys, host trust and changed-key
  recovery against a controlled SSH server;
- cancel, timeout, server rejection, clean exit, unexpected close, reconnect
  and two concurrent Sessions;
- UTF-8, wide characters, resize, scrollback, Shell, tmux, editor and Agent TUI;
- minimize, background, lock, sleep, network loss/change, renderer exit and
  application termination; and
- persistent asset create/update/delete, ordinary uninstall/reinstall, reboot,
  lock state and different signing identity when applicable.

Routine feature iteration and bug fixes exercise only the affected subset plus
the smallest quickly completed main path. The exact feature-specific subset
belongs in the design and current work item. This list defines the permanent
formal-release regression domains, not a daily checkbox log.

## 2026-08-04 verification-scope decision

- **Reason:** Full software, build and physical matrices after every small
  iteration consume disproportionate time and make the evidence for the actual
  change harder to identify.
- **Decision:** Feature iterations and bug fixes use affected-chain tests plus a
  very quick main-path smoke. Complete regression runs only while preparing a
  formal release package.
- **Safety boundary:** Focused does not mean superficial. The affected chain
  still includes relevant failure, recovery, privacy and real-device behavior;
  release preparation still repeats the full gate on the exact package source.

## Controlled environments

Protocol claims require a controlled server configuration that records server
software/version, authentication methods, host-key algorithms, shell and test
account policy. Temporary credentials and server state belong outside the
repository and must be destroyed after the run.

Compatibility claims must identify the actual environment. “SSH-compatible”
does not mean every OpenSSH option, server product, crypto policy or enterprise
access system. User-visible supported behavior is documented in
[`user-guide.md`](user-guide.md); proposed coverage remains in the roadmap and
technical designs.

Per-change authentication regression uses the controlled repository fixture.
Representative real OpenSSH/PAM/TOTP servers belong to scheduled compatibility
or release checkpoints, not every harness edit; their evidence records exact
server policy and never replaces the deterministic fixture matrix.

Routine Mosh development uses `tools/verify-mosh-pc.ps1` after the persistent Windows and
Hyper-V UDP firewall components reported by `tools/configure-mosh-test-network.ps1` are
`ready`. SSH bootstrap uses a run-scoped HDC reverse mapping from device port 2223 to the
loopback WSL fixture on port 32223, so routine runs do not depend on a Windows TCP portproxy
or require UAC. The mapping is rejected if its device port is already owned and must be
absent after cleanup. The named physical diagnostic uses stock `mosh-server` and one
controlled PTY. The default compatibility scenario uses
the server's dynamic 60000–61000 endpoint. It runs real Bash, tmux, Vim and `less`; exercises
remote resize, sustained bidirectional traffic and DEC 1049 alternate-screen entry/exit; and
checks controlled UTF-8 wide/combining output on a current screenshot. A paced 242-line
workload must leave its last marker searchable and its first marker absent from local terminal
history. This records the protocol boundary: Mosh synchronizes terminal state, while SSH
transports a byte stream. The same scenario must use real `less` to move to the document's
first and last lines and find both markers. Applications such as `less` or tmux own reliable
remote history; LeanTTY must not claim transparent SSH-style scrollback. Before connecting, the
scenario writes one unique marker to the local page. During Mosh, that marker must be absent from
search while Mosh and controlled DEC 1049 content remain confined to the Session page. After
physical `Ctrl-^ .`, the original marker must return and all Mosh-only markers must be absent.
The close verdict waits for page-restoration acknowledgement, then verifies the Preferences
digest, bootstrap-negative search and paired device/fixture cleanup.
It never mutates the persistent network. A routine invocation remains
`acceptanceEligible=false`; formal release coverage uses
`verify-mosh-matrix-pc.ps1`, which passes `-Formal` and validates the retained
candidate, clean harness, fixed scenario order and paired cleanup.

`-Scenario agent-tui` is the change-scoped Mosh Agent diagnostic. It starts the installed,
authenticated Codex TUI in `direct interaction` mode and submits no prompt, so
`plannedModelRequests=0`. The scenario must prove raw PTY mode, one controlled physical English
marker, a real HarmonyOS resize, clean `/exit`, child exit code zero and a content-free capture
whose raw input and output were deleted. It records the exact Codex version and observed
alternate-screen choice. Missing installation or authentication is `external-agent`, not a
product failure. This scenario still requires baseline Mosh authentication, authenticated
disconnect, unchanged Preferences, secret audit and paired cleanup.

`-Scenario fixed-endpoint` requests the inclusive UDP range 60042–60044 through the product
command. It must prove that the exact stock server command was observed, the returned endpoint
falls inside the requested range, the controlled PTY command succeeds, authenticated close
restores `ltty>`, Preferences and persistent network state remain unchanged, no secret is
recorded, and device/fixture cleanup completes. Parser and native tests separately reject
invalid ranges and a bootstrap endpoint outside the request. This routine diagnostic closes
the fixed-port feature slice only; it does not replace dynamic, impairment or release coverage.

`-Scenario server-path` requests `/usr/bin/mosh-server` through the product command and must
prove that the controlled fixture executed that exact stock executable. It then requires one
exact PTY command, authenticated close, restored `ltty>`, unchanged Preferences and persistent
network state, no recorded secret, and paired device/fixture cleanup. Parser, native and fixture
tests separately reject relative paths, empty or traversal segments, shell syntax, duplicate or
separated options, extra arguments and paths over 1024 ASCII bytes; native bootstrap tests also
bound combined output to 4 KiB and distinguish missing from non-executable paths. This is a
routine diagnostic and remains `acceptanceEligible=false`.

`-Scenario prediction` uses normal PTY kernel echo and a real interactive `/bin/sh -i`, matching
the upstream stock fixture. Its UDP relay owns independent client-to-server and server-to-client
forwarding tasks with the same bounded one-way delay; one direction must never block the other.
Before impairment, `Always` must expose actual public VT output below the measured RTT while the
probe sends printable ASCII only—no Enter, control input, resize or repaint. Only after that proof
may the relay block both directions and test one more ASCII, `Never`, authority convergence,
Session isolation, authenticated close and cleanup. Failure to establish the pre-impairment
prediction stops the scenario and must not be bypassed by an ArkTS timer or renderer overlay.
Post-recovery convergence and the final real-shell smoke use fresh, shell-safe absolute marker
paths under the run-owned fixture directory. They submit ordinary `touch -- <path>` commands to
the same interactive shell and wait for the exact file; fixture-private commands cannot stand in
for the kernel-echo shell whose prediction behavior is being claimed.

The same routine accepts `-Scenario pause-recovery`, `-Scenario wifi-pause-recovery`,
`-Scenario wifi-network-switch`, `-Scenario suspend-recovery` and
`-Scenario server-disappearance`.
The pause scenario may add one temporary WSL `clsact` only when none already exists, drops
both directions for the exact dynamically selected UDP port, and must remove and independently
check that qdisc before success or failure cleanup. It passes only when LeanTTY observes the
library's `Interrupted(NoRecentContact)` without a Session close/error, then observes
`Responsive` recovery and executes a new exact command on the same surviving remote terminal
PID. The disappearance scenario kills only the controlled server PID, requires the same
interruption warning without an automatic close/error, and uses physical `Ctrl-^ .` to regain
the local prompt. It must distinguish authenticated peer close from the bounded local close that
follows an absent peer. The product must not duplicate the library's reachability timer or infer
server death from silence. These are routine diagnostics, not release acceptance, and WSL PID or
`tc` observations must never become product behavior.

The Wi-Fi pause scenario opens the HarmonyOS status-bar WLAN panel through current semantic UI
nodes, disables the actual `wlan0` interface, verifies both the toggle and IPv4 loss, then restores
Wi-Fi and verifies both before sending a recovery command. USB HDC remains only the control and
observation channel. Failure cleanup must re-enable Wi-Fi; it must not retain SSIDs, addresses or
other network identities in evidence.

The Wi-Fi network-switch scenario requires one operator-supplied SSID that is already saved on the
test PC. It first closes a recovered idle second Pane and verifies a one-Pane baseline. It discovers
the current network through the read-only `WifiDevice` system-service dump, runs one controlled Mosh
Session and one direct-LAN OpenSSH Session against the same stable WSL host, then uses the visible
system panel only to select the saved alternate network. It normalizes that panel from an observed
semantic state before opening or closing it and never infers connection state from localized text. The SSH
comparison uses the existing product-managed identity and never exports its key. Each SSH probe waits
for PTY resize, then requires an exact echoed marker in native output and the terminal search result.
The switch is valid only when the device source IPv4 or the matched endpoint-route identity changes,
and the target SSID, active link and direct endpoint probe all agree. The scenario records
each protocol's observed time, Session outcome, post-switch command and required reconnect action.
An SSH Session is classified as preserved, automatically disconnected, or unresponsive; the last
case is recovered through the product's local `~.` disconnect before reconnecting. A harmless empty
line distinguishes an already returned local prompt from a still-connected but unresponsive SSH
Pane without relying only on a transient close log. The harness retains Mosh switch logs before SSH
recovery clears the live buffer. A direct device-side TCP probe separates port reachability from a
LeanTTY reconnect failure, and a terminal mode probe resolves a missing readiness log before
classifying that failure. SSH reconnect and its exact post-switch command prove alternate-network
access to the stable LAN host; the Mosh same-PTY command is the recovery oracle. The scenario restores
the original network on success and failure. HDC is only the USB control channel. Raw system dumps,
SSIDs, addresses, route contents and system-panel layouts stay only in the run-owned temporary state
needed for selection and cleanup and are not retained as evidence. Evidence keeps ordered transition
names and redacted network identity only. A password prompt is an environment failure: the harness
never reads, accepts or stores Wi-Fi credentials.

The suspend scenario invokes the HarmonyOS test PC's `power-shell suspend`, waits five seconds,
then invokes `power-shell wakeup`. It must retain the same LeanTTY process and controlled remote
terminal PID, restore the visible terminal, and execute a new exact command before an authenticated
close. Evidence records suspend and recovery-command time, any reachability transition, unlock
result, secrets, Preferences and cleanup. This scenario proves controlled system suspend/wake. It
does not prove a physical lid-close event, an independent lock-screen event or a network switch.

`-Scenario operator-lock-recovery` is an operator-assisted independent lock-screen diagnostic.
After the baseline remote command, the operator presses `Win+L` and leaves the PC locked until the
harness observes the platform's locked launch result. The operator then unlocks the PC. The
scenario must retain the same LeanTTY process, stock Mosh server and controlled remote terminal,
execute a new exact command, close normally and complete the standard secret and cleanup audits.
It records the operator action and lock duration; it does not classify the lock as suspend, lid
close or network loss.

`-Scenario runtime-reclaim` deterministically drops the active Mosh Pane's ArkTS
Session state through an acceptance-only trigger, leaving native cleanup to the
production input-recovery path. It must preserve PID/start time and ordered
Tab/Pane identities, withhold the first ordinary character, observe an empty
local command buffer before any later command reset, request native cancellation,
and prove the stock server/PTY are absent. The recovery warning and usable local
command path must return without prior remote content in search history. Missing
or ambiguous owner observations fail the scenario; a headline pass cannot replace
the structured `runtimeReclaim` contract. The trigger and observations are removed
from production packages. This proves controlled state-loss recovery, not system
GC behavior, actual low-memory pressure or physical lid closure.

`-Scenario operator-lid-recovery` is the separate operator-assisted physical-lid diagnostic.
After the baseline command, the operator closes the test PC lid and leaves it closed until the
harness observes either the platform lock boundary or temporary device unavailability, then opens
and unlocks it. The scenario must regain an unlocked HDC control boundary and accept exactly one of
three product outcomes. If LeanTTY retains the same process and Session graph, the stock Mosh server
and controlled remote terminal must survive, execute a new exact command and close normally. If the
process survives but the Session graph is lost, the production recovery path must preserve the
workspace, withhold input, clean orphan native Sessions and return to local commands. If HarmonyOS replaces
the process, LeanTTY must relaunch into the recovered local workspace, show the recovery warning,
exclude the prior remote command and create no replacement Mosh Session; a local command must remain
usable. Its controlled `MOSH_SERVER_NETWORK_TMOUT` is derived from the declared operator budget plus
cleanup margin; the 30-second close-diagnostic timeout must not terminate a valid operator lifecycle
run. Process continuity is identified by both PID and Linux `/proc/<pid>/stat` start time, because a
restarted process may reuse the same numeric PID. Evidence records both values, server/PTY state at
replacement, input method, operator action and whether the closed-lid boundary appeared as `locked`
or `unavailable`; programmatic suspend and `Win+L` cannot substitute for this scenario. Command
injection remains automated and is not delegated to the operator.
Run the physical lid action once and record whichever supported outcome occurs.
Do not repeat it to hunt the uncommon same-process state-loss branch already
covered by runtime-reclaim.

`-Scenario pane-close` splits the current tab, connects Mosh in the newly active Pane, proves one
exact controlled PTY command, and closes that active Pane through the visible close button and
confirmation dialog. As soon as the surviving Pane is observable it must not contain the closed
Pane's unique terminal marker, and it immediately starts a second real Mosh Session. The second
controlled PTY command must pass while the first server and PTY exit, and the second server must
remain alive until its own authenticated close. This scenario pairs the ArkTS current-client owner
test with device-visible Pane disposal and rejects layout count, click success or log presence as a
standalone oracle.

`-Scenario session-isolation` first keeps two stock Mosh Sessions concurrently active in the two
Panes. The fixture must report distinct server and PTY PIDs and must compare consecutive bootstrap
keys in memory, recording only whether they differ. Each Pane executes its own exact command and
must find only its own unique terminal marker. The right Pane then closes through the visible close
button and confirmation dialog. The left Session must
then execute another exact command while its original server and PTY remain alive.
The right Pane then starts a real SSH shell while the left Mosh Session remains active. Both sides
again prove exact input and mutually exclusive output, after which closing Mosh must leave SSH able
to execute a new command. The scenario finally sends the fixture's controlled SSH exit command,
restores a local prompt, removes both temporary Hosts and known-host state, and verifies secret,
Preferences, fixture, process, network
and temporary-directory cleanup. Different layout nodes, PIDs, logs or key comparison alone are not
a pass; the primary oracle is the paired per-Pane remote command and terminal result before and
after opposite-side close. This routine remains `acceptanceEligible=false`.

`-Scenario surface-rebuild` terminates the active Pane's ArkWeb renderer through the
acceptance-only source transformation. The same Mosh page marker must remain searchable after
the replacement Surface reports ready, a new exact controlled PTY command must succeed, and the
original local page must still be restored after authenticated close. `-Scenario page-rebuild`
uses the UI-context router to destroy and replace the current `Index` page while the application
process remains alive. PID plus `/proc` start time must remain equal, the replacement page must log
that it reused the process workspace, the Mosh page must remain searchable, and a new exact remote
command plus authenticated close must succeed. This deterministically covers the page lifecycle
boundary when physical lid behavior selects the process-replacement branch. `-Scenario abnormal-exit`
injects one acceptance-only `MoshError` into the active `SessionViewModel`; it must traverse the
ordinary error handler, wait for page-replacement acknowledgement, restore the original marker,
discard the Mosh command from search and regain the local input boundary. The transformation must
restore production source in `finally`; neither trigger may exist in a production HAP. Both
page/renderer triggers and the abnormal-exit scenario retain the standard Preferences, secret,
process, fixture and temporary-directory audits.

`-Scenario input-rejection` requires a dedicated test HAP built inside
`Invoke-WithLeanTTYNativeAcceptanceSource -MoshInputRejectionOnly`; ordinary debug
builds do not include its arm API. A one-shot reservation of the selected Session's
entire empty input queue makes the unchanged native `try_send` return Full, then
releases the unused permits immediately. Do not flood input, stop the receiver or
replace the ArkTS write result. After actual remote output is received, the real
input handler must reject its short frame, acknowledge pending output before
restoring that Session's exact original page, show the fixed warning/advice and
leave no rejected input at the remote PTY. The other Mosh Session must execute a
new exact command on its original PTY. Search, secret and resource cleanup remain
required. Build transformations must restore source bytes; production/review-smoke
packages reject the arm and telemetry markers. Restore an ordinary test HAP after
this diagnostic; neither its injected package nor this routine is release or
performance evidence. Research and limits are recorded in
[`code-quality-diagnosis-1.6.md`](code-quality-diagnosis-1.6.md).

`-Scenario process-recovery` force-stops the LeanTTY application process while one controlled stock
Mosh Session is active, then relaunches the same installed test package. It must observe a new PID,
find the explicit workspace-recovered warning, prove the old remote command is absent from terminal
search, and execute a local `ltty>` command without reconnecting Mosh. The old server or PTY may still
be alive briefly and is fixture cleanup state, not a recovered product Session. This controlled
scenario must pass before the operator-assisted physical-lid scenario is interpreted.

## Performance and reliability measurement

Do not choose an optimization target from intuition. First record distributions
for the relevant workload and environment, such as startup, connect time, input
latency, sustained output, renderer ACK/backpressure, memory or sleep/recovery.
Keep correctness and loss detection as hard constraints.

A measured default is not a permanent optimum. Re-run the same workload after
changes to xterm, ArkWeb, Bridge flow control, Rust/russh, buffering or lifecycle
retention. A build-only comparison is not a user-experience result.

When the test system itself is being optimized, compare at least three runs of
the same candidate/HAP, harness identity, selected scenario and environment.
For a three-run sample, report every value plus min/median/max; do not invent a
P95 from an undersized sample. Record first-attempt pass rate, retry-success
rate, input mismatch rate, unknown/misclassified outcomes, cleanup failures,
run-time human intervention and reruns that produced no new evidence. A retry
that passes remains `flaky-harness`, never a stable first-attempt pass.

Test value is the explicit claim and failure boundary proved per unit of time,
not the number of cases or artifacts produced. A focused run and a formal full
matrix are different products: compare their costs only for the overlapping
claim, and never present the focused saving as equivalent L4 coverage. Repeated
runs requested to measure a distribution are measurement samples, not
no-new-evidence reruns; an unplanned repeat with unchanged inputs and no new
hypothesis is.

## Evidence record

Atomic JSON writers MUST reject serialization-depth warnings before replacing
the previous checkpoint. Stage summaries accept a declared cleanup only with a
proved `passed` verdict; null, unknown and malformed values cannot qualify the
stage. Cleanup producers use explicit `result`/`detail` fields, not success
inferred from prose. An absent legacy field remains `not-separately-reported`,
never proof that cleanup ran.

Every release-candidate conclusion must be attributable to:

- exact LeanTTY version, commit/tree and working-tree state;
- HAP/APP hash, ABI and signing role where relevant;
- device model, HarmonyOS version and connection/deployment route;
- SSH server, network and representative Shell/TUI workload;
- commands or manual actions performed;
- run mode, selected stages, attempt lineage, per-stage duration and retry count;
- classified failure domain and the last proven component boundary;
- every run-scoped key, mapping, process and temporary directory plus cleanup
  and independent absence audits;
- expected and observed results, including failures and exclusions; and
- which layer the evidence proves.

Private host, credential, signing and device details stay outside the public
repository. Public summaries must be redacted without removing the information
needed to understand the result.

Only reuse evidence when the candidate and affected event chain are unchanged.
A new package, signature, dependency, platform version or relevant source change
requires new evidence at the affected layers.

## Release and vision gates

Core quality failure blocks the release and the repair enters
`next-work.md`. A passing release gate does not prove that users can sustain
HarmonyOS PC as their primary command-line device. That longer outcome is
reviewed only through [`vision-acceptance.md`](vision-acceptance.md), using real
work cycles and the current alternative-product landscape.
