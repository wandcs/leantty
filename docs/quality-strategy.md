# LeanTTY Regression Test Standard

> Status: mandatory cross-version engineering standard
>
> Last updated: 2026-08-22
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
| Web terminal policy tests | OSC 52, link, input, wheel, snapshot and xterm policy against packaged resources | HarmonyOS WebView lifecycle |
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
| `check-ssh-transport-flow.ps1` | `ssh-flow` | One generated N-API transport/control event schema across Rust typings and ArkTS, including removal of the retired split callbacks |
| `check-keygen-async-flow.ps1` | `ssh-flow` | Cross-language asynchronous key-generation contract: blocking Rust work is isolated and the generated ArkTS API remains a Promise that callers await |
| `test-build-workflows.ps1` | `tooling` | Build/release locking, candidate identity, acceptance-source restoration, workflow failure and evidence contracts; product-private control flow is outside this check |
| `test-device-regression.ps1` | `tooling` | Physical-harness input, evidence, cleanup and secret-safety contracts, plus unavoidable public ArkUI/lifecycle registration and filesystem security flags |
| Package-policy checks registered by `test-regression.ps1` | `tooling` and build stages | ABI, production/test-source isolation and release-package artifact boundaries |

Tests under `entry/src/test/` are organized by the owner or behavior they prove,
such as SSH, workspace, terminal interaction, transfer, key management and
formatting. A historical incident may explain why a test exists, but it does not
define a permanent catch-all test suite.

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

Formal release software gate, candidate build and deployment use one command:

```powershell
.\tools\verify-pc.ps1
.\tools\verify-key-passphrase-pc.ps1
.\tools\verify-ssh-auth-pc.ps1 -DiagnosticHap -HapPath <signed-test-hap> -Only key-comment-change-and-restart
.\tools\verify-ssh-auth-pc.ps1 -DiagnosticHap -HapPath <signed-test-hap> -Only ecdsa-import-encrypted-and-restart
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

`verify-ssh-matrix-pc.ps1` is the formal SSH physical entry. It runs four
isolated groups in the fixed order below against one retained candidate, stops
at the first failed group, and validates each group's acceptance mode,
candidate SHA-256, clean harness tree, unchanged Preferences and cleanup result.
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
exact mode on both success and failure.

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

## Formal checkpoints and rerun policy

Full release testing is checkpointed work, not one indivisible terminal command.
A failure response is determined by evidence identity and affected state, not by
how expensive the previous run was.

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
- never run two physical scenarios against the same target concurrently;
- inject ordinary terminal text as one complete, coordinate-targeted serialized
  UiTest `inputText` operation against the current semantic input node. Do not use
  focused `uiInput text` for arbitrary payloads: on UiTest 6.0.2.3 a payload such
  as `help` is parsed as the CLI help subcommand and returns success without
  delivering text. Reserve numeric physical-key events for shortcuts, modifiers
  and special-key semantics. Common helper-driven layout, click, text, key and
  screenshot operations MUST share one device-scoped UiTest mutex because the
  platform interface is not concurrent;
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
  evidence promotion is forbidden when any run-scoped resource remains.

UI automation MUST model each consequential interaction as an explicit state
transition: action, expected dialog, confirmation action and observable
postcondition. Clicking a close/delete control without handling and verifying
its confirmation state is incomplete automation.

Each named scenario declares one primary oracle for its claimed result. SSH and
transfer claims use the controlled server or final file/state; input-integrity
claims use actual echo or received bytes; UI/focus claims use the current layout
plus the resulting operation; visual claims use a screenshot or bounded human
review; performance claims use device-clock events. HDC exit codes, launch/PID,
hidden textarea values and HiLog line counts are setup or diagnostic evidence,
never a primary pass oracle. Add a second boundary observation only when risk or
ambiguity requires it; collecting every expensive observation at every poll is
not acceptance rigor.

Physical keyboard injection MAY be used only for a scenario whose contract is
the physical shortcut or special-key path, after the script verifies the focused
application and the resulting operation. Ordinary text uses the single UiTest
text path. ArkWeb's accessibility textarea is useful for focus preflight and
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
invoke the unchanged production event chain, expose no secret value, create no
parallel business state and have a named regression owner. Runtime hiding alone
is prohibited.

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
