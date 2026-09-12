# Agent TUI exit boundary repair

Research and diagnosis date: 2026-09-12. Scope: the Agent acceptance harness;
no product code, dependency, terminal renderer or candidate bytes change.
Outstanding execution remains in [next-work.md](../next-work.md).

## Failure and evidence boundary

The PR #181 R3 run completed QH, the eight Mosh checks and long-task notification,
then stopped in Agent compatibility. Codex direct/tmux passed; OpenCode direct
produced a successful child-exit capture but timed out waiting for a new SSH-close
event. The remaining Agent checks and SSH matrix were not run.

Expected order: TUI exit, fresh remote-shell return, one SSH close, local cleanup.
The last correct boundary was the raw-free Agent child result. The first wrong
boundary was a wait for another SSH-close event after log clearing; the retained
input log already reported native IDLE mode 0. That supports an earlier close but
does not identify which preceding key reached which process.

The harness sent Ctrl+C, Ctrl+C and Ctrl+D unconditionally for non-Codex TUIs.
It also retained a connection-time `shell-ready` marker while the TUI was running.
Interaction/protocol failure handlers could repeat the entire exit sequence.
The Agent owns its exit, Bash owns return to the interactive prompt, and LeanTTY's
Session owns SSH closure. None of those states can substitute for another.

The first software counterexample demonstrates the unsafe transition; it does
not prove historical device timing. A zero-model real-PC baseline additionally
showed an unacknowledged first exit, repeated exit keys in the failure handler,
and a subsequent SSH-close timeout. Its Agent eventually exited with code 0.
The temporary trust entry was independently removed through LeanTTY after the
original Tab was restored. Original failed reports remain unchanged.

Two host-PTY probes were inconclusive: the first mistook Bash bracketed-paste
for Agent readiness; the corrected probe did not acknowledge TUI exit. They are
not reproductions or passing evidence. The diagnostic stopped developing this
partial terminal emulator and returned to the existing physical-PC chain.
Both host probes' raw captures and temporary proxy-environment files were removed.

## External research

The affected baseline used OpenCode 1.18.23, Codex 0.149.1, Pi 0.84.4 and Qwen
0.23.0 on the already-running default WSL distribution. The physical control
baseline was ARM64 HarmonyOS PC, UiTest 6.0.2.3 and HDC 3.2.0d; device evidence
records the actual target and package identity, not a public hard-coded device ID.

- [OpenCode 1.18.23 bindings](https://github.com/anomalyco/opencode/blob/ef2880f379129aa048be9e9353e30aa168d42c17/packages/tui/src/config/keybind.ts)
  define Ctrl+C/Ctrl+D/leader-q as application exit. Its
  [application handler](https://github.com/anomalyco/opencode/blob/ef2880f379129aa048be9e9353e30aa168d42c17/packages/tui/src/app.tsx)
  enables these bindings for an empty focused prompt and exposes `/exit`.
  The current v2 documentation is not the version authority for this run.
- [Pi 0.84.4](https://github.com/badlogic/pi-mono/blob/b79e4cc834970cca69daebffab7df1da7d1e52c4/packages/coding-agent/src/modes/interactive/interactive-mode.ts)
  handles `/quit` directly; [Qwen 0.23.0](https://github.com/QwenLM/qwen-code/blob/98a9c964158697dd5631d15a62174684ff7bbb53/packages/cli/src/ui/commands/quitCommand.ts)
  exposes `/quit` with `/exit` as an alias. Codex retains the existing `/exit`
  path, previously observed passing in this exact candidate's formal run.
- The [GNU Bash manual](https://www.gnu.org/s/bash/manual/bash.html) distinguishes
  Readline EOF from interrupt and documents `PROMPT_COMMAND` before a new prompt.
  An EOF sent after the child exits can terminate the interactive SSH shell.
- [OpenHarmony 6.0 ArkXtest](https://github.com/openharmony/testfwk_arkxtest/blob/OpenHarmony-6.0-Release/README_zh.md)
  documents UI input/key injection, not the remote process consuming each key.
  A successful key-injection call cannot acknowledge TUI exit or shell return.
  Newer master input behavior is not evidence for installed UiTest 6.0.2.3.
- Upstream [OpenCode #3025](https://github.com/anomalyco/opencode/issues/3025)
  concerns an older Ctrl+D behavior; [Qwen #3185](https://github.com/QwenLM/qwen-code/issues/3185)
  concerns Windows `/quit` failure. Neither proves this WSL/device failure.
  Huawei developer-community searches found no matching reproducible report.
- [Playwright actionability](https://playwright.dev/docs/actionability) supplies
  the comparable pattern: validate the action's current precondition and await
  its postcondition. It is a design reference, not a HarmonyOS guarantee.

## Selected repair

Use one documented TUI exit command after normal interaction: `/exit` for
Codex/OpenCode and `/quit` for Pi/Qwen. An already-completed capture requires
observation only. Invalidate the input boundary before dispatch; a missing
acknowledgement cannot authorize another command, Enter or EOF. On an interaction
failure, restore any changed window state and leave termination to the isolated
Tab owner; never type an exit command into an uncertain TUI buffer.

The controlled Bash writes its readiness marker from `PROMPT_COMMAND`. The
connected-command helper removes the old marker immediately before its single
Enter and marks the shell busy. TUI completion requires both its child capture
and the new shell prompt marker. The dedicated SSH-close action alone sends
Ctrl+D, after fresh shell proof, and waits for the current native close event.
Direct SSH, tmux detach/reattach, normal interaction and protocol callers use the
same boundary; no terminal text parsing or product instrumentation is added.

Rejected alternatives: longer sleeps, accepting absent close events, blindly
retrying controls, changing OpenCode key bindings, or fixing the outer cleanup
headline instead of the failed transition. A universal terminal emulator or
generic event framework is disproportionate to this harness-local defect.

## Verification and release impact

The named `-DiagnosticHap -ExitBoundaryProbe` uses real authenticated TUIs with
no model prompt. It reuses connection, capture, isolated Tab and cleanup owners;
IME, resize, notification and lifecycle acceptance are not claimed. It stops at
the first failure. Physical results are recorded separately from software tests.

The owner regression contains 57 cases, including the four exit mappings,
already-exited capture, missing child/shell acknowledgement and no repeated exit
after failure. The selected `policy,tooling` group passes. An earlier group run
failed because a static check expected literal `-Text '/exit'`; that obsolete
spelling check was removed, while real-function exit tests retain the contract.

Physical validation completed in 329 seconds: OpenCode, Codex, Pi and Qwen each
passed direct and tmux exit, fresh shell return and intentional SSH close. All
eight retained SSH until the dedicated close action. Ten local commands and nine
connected-shell commands each used one input attempt and one Enter, with zero
mismatches. No model prompt, IME test, resize, Wi-Fi, lock or lid action was run.
The normal notification setting and original Tab were restored. An independent
audit confirmed absence of both diagnostic runs' trust entries, listeners,
processes, fixture directories and HDC mappings. The original HAP, frozen
checkouts and previous formal reports were unchanged. This is diagnostic
evidence, not completed C3 or a replay of the notification-driven Agent workload.

Evidence root: `build/verification/agent-exit-boundary-20260912/`. The failed
baseline is `device-legacy/result.json`; its separate recovery is
`legacy-residual-cleanup.json`. The corrected run is `device-explicit/result.json`
(SHA-256 `422314b17b8cbb2dd979521b89c139434aaedc0c85ac78df397353175db10cb3`);
the independent audit is `closing-audit.json`. The tested device harness file
has SHA-256 `e8c026e47563ed18ba4fbc9d5210ed20cc690c0615cdaa309e46d2cac2f9bb75`.
All physical evidence remains local and raw-free.

Next, bind the final clean harness to the unchanged candidate, renew QH and
establish the smallest trustworthy R2 continuation for Agent and SSH. This
Agent-local change does not itself invalidate earlier Mosh/lock/lid observations.
The existing outer runner rejects changed harness identities and failed cleanup
checkpoints even after independent recovery. A minimal, audited continuation
record is preferable to repeating unrelated human actions, but it must validate
the original reports, exact candidate, scoped changes, new QH and cleanup without
rewriting their verdicts. That continuation mechanism is not implemented by this
repair; no formal pass is manually spliced or promoted.

## Agent-local formal continuation

The subsequent R2 repair adds `verify-release-pc.ps1 -AgentContinuationPath`.
It creates a new report; ordinary `-Resume` retains its exact-harness rule.
Only an original registered report with a complete passing prefix, a failed
Agent stage and an unstarted SSH stage is eligible. The manifest pins the old
report, independent recovery and a fresh machine-local admission audit by
SHA-256. A recovery audit does not change the original Agent failure or cleanup.

The continuation owner checks candidate and invocation identity, original
harness ancestry/tree, prefix result files and cleanup, restored initial state
and the repaired Agent script hash. It admits only the named Agent repair,
reporting, tests and documentation paths. SSH auth may change only its
candidate-compatibility array; its remaining source must match the original
byte for byte. Changes to shared input, layout, logs, fixtures or cleanup reject
R2. This also fixes the formal allowlist omission for this repair document.

The new report records inherited stages as `reused`, with original result paths
and hashes. It always runs a new QH, then the full Agent stage and SSH matrix.
The original failed attempt remains the new Agent attempt's predecessor. Eight
new planned model requests are distinct from inherited work and the earlier
failed run's unavailable actual count. No model retry is automatic. Inherited
hashes are checked again on resume and before a complete-matrix claim.

The live admission audit checks each failed/diagnostic attempt's fingerprint,
listener, process and directory absence; reverse mappings; the restored Tab and
notification state; candidate hash; and platform continuity. It preserves its
observations and script locally. It neither manufactures stage verdicts nor
serves as a new product acceptance result. A stale/unknown audit stops before QH.

Research on 2026-09-12 compared [GitHub reruns](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs),
which retain the original commit, with [GitLab retries](https://docs.gitlab.com/ci/jobs/#retry-jobs),
which create a new job identity and artifacts. These support distinct attempt
lineage, not silent substitution of a repaired harness. Huawei's
[testing guidance](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/other-test)
retains preceding observations after script failure but does not define
cross-harness reuse. No matching Huawei community or upstream report established
such a guarantee; the OpenHarmony 6.0 README lookup on Gitee was unavailable.
The selected policy follows this repository's R2 contract, not an assumed OS API.

Current platform observations distinguish the two version fields:
`const.ohos.fullname` reports `OpenHarmony-6.1.1.135`, while the product software
field reports `HAD-W24 6.1.0.135(SP60C00E100R13P3log)`; UiTest is `6.0.2.3`.
The first admission observation found the PC locked, not a missing application;
it created no fixture or formal result. The documented local-credential helper
handles unlock before the next audit, preserving the app process.

The 47-case continuation regression passes, including altered invocation,
candidate, report hash, reused checkpoint, missing prefix, stale admission and
unproved cleanup. The original entry fails the new continuation contract test.
The focused `policy,tooling` gate passes seven checks. A live audit after normal
unlock validates all three previous Agent attempts' cleanup and the 16 reusable
physical stages. It sends no model request and performs no lock/lid/Wi-Fi test.
The process start counter and its measured clock rate exclude a reboot since
the original report started; the two version fields above and UiTest are stable.
Evidence is under `build/verification/agent-r2-continuation-20260912/`:
`software-final.json`, `admission-diagnostic-2/audit.json` and
`admission-diagnostic-2/continuation.json`. Fresh clean-harness formal QH and
Agent/SSH results are still required; this audit is not a C3 completion claim.

## Agent input context

The next formal R2 attempt passed QH but stopped before entering SSH trust
`yes`. Its single focused textarea retained type, hint, window and bounds while
its virtual hierarchy changed. Agent's focus helper returned the node without
its containing layout, so the shared guard used its legacy hierarchy comparison.
The failed capture did not preserve the native Web identity; that observation
alone cannot establish a product fault or prove the native owner was unchanged.

`Focus-TerminalInput` now returns the node and layout from one observation. Every
Agent-owned terminal text caller passes both to the existing shared guard. Local
commands carry the pair through the existing input-preparation callback; native
buffer equality and single-Enter submission remain owned by the shared submitter.
There is no persistent locator cache, shared-helper change or product change.

Research checked the versioned [OpenHarmony 6.0 hierarchy builder](https://github.com/openharmony/testfwk_arkxtest/blob/OpenHarmony-6.0-Release/uitest/core/ui_model.cpp)
and [UiTest guide](https://github.com/openharmony/docs/blob/OpenHarmony-6.0-Release/en/application-dev/application-test/uitest-guidelines.md)
on 2026-09-12. Hierarchy is assembled from child indices. The installed UiTest
6.0.2.3/HarmonyOS build is not asserted to be identical to that source.
[Playwright's current locator guidance](https://playwright.dev/docs/locators)
supports fresh, uniquely resolved targets as a design pattern, not a HarmonyOS
guarantee. Searches of upstream and Huawei discussions found no exact matching
report or cross-rebuild identity guarantee. The repair therefore preserves the
existing operation-local native Web rule rather than weakening it.

Actual Focus/Connect/shared-guard counterexamples fail without this repair and
pass with it. They cover same-Web reindexing, another Web/window, missing or
ambiguous owners, and post-input owner loss without another input or Enter.
Caller tests also check reference pairing, local preparation and complete layout
arguments. The focused policy/tooling gate passes seven checks, including 68
Agent SSH cases. The original-HAP zero-model SSH prerequisite passed in 125 seconds:
three local commands and one remote command each used one input and one Enter,
with no mismatch. Host trust, current shell readiness and normal close passed;
the isolated Tab, fingerprint, fixture, reverse mapping and policies were restored.
An independent absence audit passed. No model, Wi-Fi, lock or lid action ran.
Evidence: `build/verification/agent-input-context-20260912/` contains the red/green
counterexamples, `software-focused-desktop.json`, `device-ssh/result.json` and
`closing-audit.json`. The first focused run stopped at the sandbox's WSL identity
boundary; the same checks passed under the required desktop identity. This
diagnostic verdict cannot replace new formal QH or Agent/SSH acceptance.

## Agent notification observer

On 2026-09-12, the actual notification assertion reproduced an attribution defect:
inner-only attention with no outer or hidden-window evidence produced a product
failure. This does not establish the cause of PR 184's historical Qwen tmux
failure. The four earlier generic BEL controls are closed and are not rerun.

The Agent-only outer capture reuses util-linux script 2.41.3. It records byte
checkpoints before minimize and after the real window-hidden event, not
UIAbility.onBackground or cross-machine timestamps. Complete frames starting
after the second checkpoint prove only remote outer PTY observation. Early,
straddling, inner-only, missing-observation and publication-unconfirmed cases
stay harness/unknown failures. Generic payload and notification return remain
required; no Qwen exemption, fixture BEL in native acceptance, prompt change or
deadline increase is introduced.

Fresh research checked Qwen 0.23.0's [native BEL implementation](https://github.com/QwenLM/qwen-code/blob/v0.23.0/packages/cli/src/ui/hooks/useTerminalNotification.ts),
the [util-linux script contract](https://github.com/util-linux/util-linux/blob/v2.41/term-utils/script.1.adoc),
[Huawei window visibility guidance](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/faqs-arkui-1029)
and [Playwright condition assertions](https://playwright.dev/docs/test-assertions).
No matching upstream/Huawei report establishes this Qwen cause. Flush and an
extra PTY may perturb timing; a passing observer cannot exclude an uninstrumented
race. A signal during the checkpoint interval remains ambiguous, not a pass.

Development evidence under `build/verification/agent-attention-observer-20260912/`:

- The real assertion fails the inner-only counterexample before repair. Software
  coverage includes 11 assertion/owner/admission cases, six parser/checkpoint
  cases, real direct/tmux capture and early exit, and a non-notification launch.
  External Agent/npm effects are replaced by public test processes in the latter;
  no authentication or model is used. Existing 68 Agent SSH checks also pass.
- First physical preparation (13:17:14–13:19:18 +08:00) stopped before observer
  startup: a 739-character diagnostic command read back as an empty line; Enter
  count was zero. The cause remains unknown. The original result stays invalid
  because its host cleanup was unconfirmed. One exact fingerprint removal and
  the independent audit passed; no command was resent.
- Replacement preparation used the fixture's existing short-function pattern,
  retaining exact input verification and single Enter. At 13:22:17–13:24:36 it
  observed one pre-minimize BEL and one post-hide BEL, then the generic card and
  correct return. Raw output was deleted, normal cleanup and independent absence
  audit passed. All physical work used the original `0db0f090…95e71` HAP and
  made zero model requests. The passing result SHA-256 is
  `b90890e000322402a8b05b3a4d726ae50d10cb6ebd00dd815630e6259343cbf5`.
- After that device diagnostic, the unchanged capture body was moved out of the
  shared WSL dispatcher into `capture_notification.sh`. The final dispatcher
  and nested capture were verified with real PTY/tmux software tests; the shared
  `agent-compatibility-wsl.sh` and existing analyzer are byte-for-byte unchanged.
  The device result belongs to the pre-extraction implementation, not a new
  formal or post-extraction device run.

The selected next scope is R2: clean committed harness, fresh resource/platform/
identity admission and QH, then the complete Agent stage and the pending SSH
matrix under the fixed budget. Only Agent-specific files are admitted; changes
to the shared fixture/analyzer or product are still rejected. SSH's change is
its candidate-compatible file list only. The original HAP, old failed reports
and independent prefix remain immutable. An unmet reuse prerequisite escalates
under the existing R1–R4 rules; this diagnostic does not complete C3/C4.

## Pi startup ordering reframe

The subsequent formal R2 ran on the unchanged `7293a46` harness and original
`0db0f090…95e71` HAP from 13:56:50 to 14:11:48 on 2026-09-12 (+08:00).
Thirteen historical attempts were audited afresh; sixteen independent physical
stages were reused. New formal QH passed. Codex direct/tmux and OpenCode
direct/tmux passed; OpenCode tmux retained `not-emitted-by-agent`, not a verified
system notification. Pi direct failed; Pi tmux, both Qwen checks and SSH did not
run. This does not resolve the historical Qwen failure or complete C3/C4.

The original Agent result remains `invalid/interrupted`, with known-host cleanup
unconfirmed. One product-command removal of the exact residual fingerprint
passed with one input and one Enter. At 14:13:42 an independent audit confirmed
resource absence, restored workspace and policies, and unchanged candidate,
frozen sources, original reports and inherited evidence. The new Agent budget
was eight requests; actual model usage remains unavailable, with no automatic
model retries. Thirteen local and eight connected commands each had one input,
one Enter and no mismatch. These counts do not cover every TUI key event.

### Proven boundary and unresolved cause

- Expected contract: evaluate native attention emitted after the window is
  confirmed hidden, then observe the generic system card and return.
- Last correct boundary: the outer PTY captured a complete OSC 777 frame;
  the device logged window visibility false at 14:10:04.699.
- First unproved boundary: before-minimize offset was 32,301; after-hidden
  offset was 50,604. The first frame occupied bytes 43,088–43,120, inside that
  interval. The observation period had no post-checkpoint attention. Receipt
  and visibility ordering inside the interval remain unknown.
- Final capture contains another OSC 777 at 67,675–67,707 that was absent from
  the notification observation. The intervening workflow restores the foreground
  and performs input probes; this frame has no window-relative checkpoint and
  cannot qualify the earlier hidden-window assertion. Raw captures were deleted by the owner;
  only metadata summaries remain.
- State owners: Pi emits attention, the window owns visibility, and the Agent
  fixture must establish their test ordering. The observer correctly rejected
  this ambiguous sample; it does not by itself establish a product defect.

The fixture starts Pi with its short prompt before minimizing. Unlike OpenCode,
Pi uses no tools and has no `sleep 12` workload. The 700 ms delay and subsequent
layout/click/log work establish no ordering guarantee. This is a setup race,
not evidence that a longer delay will fix the product. The existing best-effort
exception only accepts its specific publication classification; it must not be
broadened to turn this harness failure into a pass.

### Research and bounded next decision

Research refreshed on 2026-09-12 for Pi 0.84.4, UiTest 6.0.2.3 and the recorded
HarmonyOS 6.1 test PC:

- Pi's versioned [official notify extension](https://raw.githubusercontent.com/earendil-works/pi/v0.84.4/packages/coding-agent/examples/extensions/notify.ts)
  emits OSC 777 on `agent_settled` in this environment. It has no synchronization
  with the client window. The upstream [settled-event discussion](https://github.com/earendil-works/pi/issues/2110)
  concerns Agent completion semantics, not this HarmonyOS timing failure.
- OpenHarmony's [window visibility API](https://github.com/openharmony/docs/blob/master/en/application-dev/reference/apis-arkui/arkts-apis-window-Window.md#onwindowvisibilitychange11)
  supplies the visibility callback, not ordering against remote output. The
  moving documentation is semantic guidance; the actual device log remains the
  evidence for this installed version. Huawei FAQ content was unavailable and
  no matching Huawei community report was found; neither establishes a platform
  notification defect.
- Playwright's [actionability guidance](https://playwright.dev/docs/actionability)
  illustrates waiting on preconditions before the tested action. It is a design
  pattern only, not proof of HarmonyOS behavior.

Reframe from “observe the launch/minimize race more precisely” to “establish the
background precondition before releasing the real workload.” The next cheapest
hypothesis test is a bounded Agent-only startup gate: hold the original launch,
confirm capture readiness and hidden-window checkpoint, then release exactly
once. First prove ordering, cancellation, expiry and unchanged output bytes
with a zero-model process/PTY test; validate the same entry on the PC before
spending another formal Agent budget. Do not intercept or replay notifications,
modify Pi's extension, weaken the oracle, add arbitrary sleep, or type into a
hidden terminal. This approach has not been implemented or physically verified.
If it requires shared WSL/analyzer or product changes, reassess R2/R3/R4 before
changing them. Executable work remains solely in Next Work.

Evidence root: `build/verification/agent-attention-observer-20260912/`.
`formal-admission/audit.json`, `formal/release-report.json`, the Agent attempt's
`result.json` and `captures/`, `residual-cleanup.json`, and
`formal-closing-audit.json` retain this run. Release report SHA-256:
`28aa001b21eb376f8b14b6d01bc32e1c57e4a6b3f7c1655ea4b1a91d20d8b8d6`;
Agent report: `8356055878c25ec4a943dbdb87629c7a790552530252214e189580d08ed152fa`.

## Hidden-window startup gate

The reframe above is now implemented and development-verified. The original
dispatcher reproduces premature child startup with an external Agent substitute
and no model. The repair holds the first Codex/Pi/Qwen notification launch inside
the existing outer PTY. The caller waits for readiness, minimizes through the
existing window owner, writes the after-hidden checkpoint, and releases once.
OpenCode retains its visible interactive prompt setup. Non-notification launches
and later tmux attachments retain the shared dispatcher's behavior.

The gate uses Python's standard-library [file lock](https://docs.python.org/3/library/fcntl.html)
to serialize release, cancellation and startup, then [exec](https://docs.python.org/3/library/os.html#os.execv)
to preserve the PTY, argv and environment. It consumes no terminal input and
relays no output. A 60-second maximum prevents abandoned startup; it is a failure
deadline, not a fixed workload delay. Missing readiness/hidden proof, expiry and
cancellation stop startup. Cancellation before readiness leaves a tombstone so
a delayed launch cannot run. Once startup is consumed, cancellation reports
that it cannot prove cancellation rather than pretending to stop the child.

There is no new dependency, notification injection, Agent prompt/extension
change, product change, shared fixture/analyzer change or oracle relaxation.
The SSH harness change only admits the two new Agent-specific files. All
existing shared/product rejection tests remain active.

Development evidence is under
`build/verification/agent-start-gate-20260912/`:

- `diagnosis.md` records the expected outcome, owners and distinguishing
  hypothesis before implementation. The old launch fails the premature-start
  counterexample. `software.json` passes all seven focused policy/tooling checks;
  the embedded suites include eight gate tests, four real PTY cases, sixteen
  PowerShell observation/startup cases, 68 SSH-boundary cases and 57 continuation
  checks. PTY evidence covers direct/tmux immediate output, cancellation and
  non-notification bypass. Gate tests cover original queued input/output bytes,
  missing/wrong checkpoints, repeated release, deadline and hangup.
- One zero-model original-HAP diagnostic ran from 16:54:18 to 16:57:09 (+08:00)
  on 2026-09-12, attempt `555f93b0073b4f69b6e8131ec4363afd`. Both direct and
  tmux had zero attention before release and exactly one immediate post-hide
  BEL, followed by the generic notification card and return. Both children
  exited normally and raw outer captures were deleted. This exercises the real
  startup/hide/assertion functions with a public producer; it is not native
  Pi/Qwen emission evidence. Its run-owned diagnostic replaces only the SSH
  prerequisite check, submits a short fixture function and makes no model call.
- `device/result.json` and owner cleanup passed. SHA-256:
  `d681cb6de115ef27c6332c37a166c6bf7f939f132e6c8219eedb91ef0ee7b697`.
  The read-only `closing-audit.json` at 16:59:32 independently confirms the exact
  fingerprint, listener, fixture processes/directory and reverse mapping are
  absent; original Tab 40 and active Tab 40 are restored. Original HAP and
  previous failed reports/frozen harness are unchanged. WSL lifecycle was not
  managed. Notification/screen-timeout restoration is confirmed by the owner.
- During development, a reversed path-check argument was corrected before
  successful software/device verification. The first read-only audit lacked
  the existing notification helper import; correcting that local audit allowed
  completion without another behavior run. The software wrapper redundantly
  invoked tests already covered by policy/tooling; future verification should
  use that registry once.

The gate's native Agent behavior remains pending formal acceptance. Freeze the
verified repair, refresh all attempted-run cleanup and candidate/platform/source
admission, then run new formal QH and the complete Agent/SSH suffix only if R2
reuse still qualifies. Do not reuse the diagnostic as QH or a native pass, and
do not repeat a matrix on another setup failure. Historical Qwen cause remains
unknown; C3, C4 and release delivery remain incomplete.

## PR186 formal stop at Pi tmux forwarding

On 2026-09-12, 17:26:27–17:43:11 (+08:00), the frozen PR186 harness ran one
formal R2 continuation against the unchanged retained `0db0f090…95e71` HAP.
Admission audited 15 historical attempts and preserved 16 independent stages.
New formal QH passed. Codex direct/tmux, OpenCode direct/tmux and Pi direct
passed; OpenCode tmux retains `not-emitted-by-agent`, not a notification pass.

Pi direct now proves the startup contract with the native Agent: both hidden
barriers had zero output/attention, then an outer OSC 777 arrived after hiding,
followed by a generic system notification and correct return. No synthetic BEL
was used for this formal result.

Pi tmux, check six, failed as `[unknown] Agent inner attention observed without
outer attention`. Its gate started only after the hidden checkpoint. The final
inner summary contains two OSC 777 frames and normal child exit; the complete
outer capture contains 41,703 bytes and no attention event. Search, Unicode and
large input, Shift+Enter, reconnect and tmux resume checks passed within that
mode, but do not override its failed notification verdict. Qwen direct/tmux and
the SSH matrix did not start. No new model request was made after stopping;
the new request budget was eight, actual accounting remains unavailable, and
automatic model retries were zero.

### Recovery and immutable evidence

Attempt `0342e7d1255348549ff585ceb4004419` remains `invalid/interrupted` with
cleanup failed: the selected-check failure prevented confirmation of the
run-owned known-host removal. The report already proved local SSH state and
restoration of the original Tab. Independent recovery removed only
`[127.0.0.1]:31813` through one product command, one input and one Enter.
The original report was not changed to passing.

At 17:45:35, independent audit confirmed no owned fingerprint, listener,
process, directory or mapping, restored workspace/notification/screen policy,
and unchanged HAP, frozen checkouts, historical reports and inherited hashes.
No user key or other host entry was deleted. This disposable trust record can
be regenerated by a later fixture. WSL lifecycle remained maintainer-owned.

Evidence root: `build/verification/agent-start-gate-20260912/`.

- `formal/release-report.json`: SHA-256
  `50a5bc8eb3b56e75f129f13b2150d792909de1bcab23e825405619d964644741`.
- `formal/stages/agent-compatibility/attempt-1/result.json`: SHA-256
  `492ff68bc74d6111438e868cf72a4f836402351fd45623db908341a5f3f9b502`.
- `formal-admission/`, `residual-cleanup.json`, `formal-closing-audit.json`,
  and the stage's content-free `captures/pi-*-notification*.json` preserve
  admission, independent restoration, inner/outer counts and gate state.

### Reframing and zero-model discrimination

The goal remains actual terminal compatibility, not forcing every upstream
protocol through every multiplexer. Startup ordering and forwarding are now
separate boundaries. Another timer, extra model request or LeanTTY notification
special case cannot restore bytes that never reach the terminal.

Installed Pi 0.84.4's official extension agrees with its
[tagged source](https://github.com/earendil-works/pi/blob/v0.84.4/packages/coding-agent/examples/extensions/notify.ts):
its OSC 777 output has no tmux DCS wrapper. The
[tmux FAQ](https://github.com/tmux/tmux/wiki/FAQ#what-is-the-passthrough-escape-sequence-and-how-do-i-use-it)
requires explicit DCS wrapping for unsupported sequences; `allow-passthrough`
permits that wrapper rather than adding it. The fixture already enables this
option and uses the installed tmux 3.6.

One WSL-only public-byte probe, planned in `tmux-boundary-plan.md`, produced:

| Route and payload | Exact outer OSC 777 | Frozen observer |
|---|---:|---|
| direct, bare OSC 777 | 1 | OSC 777 |
| tmux, bare OSC 777 | 0 | no attention |
| tmux, DCS-wrapped OSC 777 | 1 | OSC 777 |
| tmux, BEL control | 0 | BEL |

`probe-tmux-boundary.py` and `tmux-boundary.json` retain the executable and
counts. Each route used a unique socket, ready/done handshakes and bounded
cleanup; all four passed in one invocation. No Agent, authentication, model,
HDC or user tmux configuration was used. Public output remained in memory;
only counts and identities were retained. Exact-byte matching independently
agreed with the unchanged observer. This proves tmux's handling of the exact
bare frame shape and explains the formal inner/outer discrepancy; it does not
reconstruct deleted raw formal bytes or promote the failed physical result.

The earlier BEL startup probe therefore tested ordering but could not establish
OSC 777 forwarding. Future protocol preconditions must use the relevant frame
shape, without passing a synthetic frame off as a native Agent notification.

### Maintainer decision recorded on 2026-09-12

After reviewing this evidence, the maintainer confirmed the general principle:
proven third-party limitations outside LeanTTY's responsibility must not stop
our acceptance and do not prove a LeanTTY bug. Record the exact Pi/tmux case as
non-blocking `upstream-not-forwarded`, not a system-notification pass; retain
other applicable interactions, notification handling and cleanup requirements.
The governing rule is in [quality-strategy](../quality-strategy.md#third-party-limitations-and-acceptance-continuity).
Matching evidence-backed cases do not require repeated approval.

This decision supersedes the blanket Pi-tmux notification requirement, not the
historical failed report. No private Pi extension, stream rewrite, extra model
request or product workaround is required merely to compensate for this upstream
limitation. Unknown attribution and actual product failures remain blocking.

This follow-up only records the policy. The executable classifier is unchanged;
its next scoped repair must be tested, frozen and admitted under R1–R4 before
formal continuation. Historical Qwen cause remains unknown; C3, C4 and release
delivery remain incomplete.

### Evidence-bound classification implementation

The Agent notification assessment now records the approved Pi/tmux boundary as
`status=not-applicable`, `classification=upstream-not-forwarded` and
`systemNotification=not-exercised`. The enclosing mode passes only after its
other assertions pass; report summaries expose `nonBlockingLimitations` even
when later cleanup fails. No product, Agent extension or tmux behavior changes.

The exception requires the exact reviewed Pi 0.84.4 notify extension hash,
tmux 3.6, the owned fixture configuration hash, the original inner-only failure,
successful child exit and complete outer evidence with valid checkpoints and
zero attention. Missing, changed or contradictory evidence stays blocking.
The public extension and configuration identities are read without credentials
or a model call. Other upstream cases need their own evidence, not an Agent-name
exemption. The classifier and its caller remain the single applicability owner.

The new real-caller test fails twice against the frozen PR186 caller and passes
against the repair. Eight added selection cases cover continued execution,
version drift, product/privacy, search/input/reconnect and failed cleanup.
The focused policy/tooling suite passes, including 76 actual Agent boundary
cases, pure notification counterexamples, result round-trip and continuation
admission. The previous real Pi capture is classified correctly in a separate
zero-model diagnostic; original reports retain their hashes. This is software
and retained-evidence validation, not a new physical notification pass.

Candidate reuse remains R2 only after current state admission and new QH.
Only Agent-local policy/caller/tests and documentation changed. The SSH change
admits those exact paths; its runtime behavior, shared observation/cleanup and
all product/HAP bytes remain unchanged. Full Agent/SSH acceptance is still pending.

### Qwen focus readiness repair

PR187 (`93bd05b`) subsequently reached all eight Agent modes. The first seven
passed; Pi/tmux recorded its reviewed forwarding limitation without stopping
the remainder. Qwen/tmux completed its interaction and reconnect assertions but
emitted no native attention. Its formal result remains invalid/interrupted after
unconfirmed known-host cleanup; independent recovery and audit passed. Neither
that result nor its HAP was rewritten by the following diagnosis.

The notification fixture had an unmet focus precondition. Eight zero-model
checks execute the installed Qwen 0.23.0 public hook bodies with modeled React
hooks. Qwen begins focused; approval attention requires an unfocused waiting
state, and completion requires at least twenty seconds of responding while
unfocused. A later focus-out does not replay a completion handled while focused.
Enabling `terminalBell` is therefore not an unconditional emission contract.
These isolated hooks do not reconstruct the historical model/business state.

A stock tmux 3.6 experiment used real PTYs and its `client-focus-out` hook to
confirm the outer event. Hiding before the inner program enables DEC 1004
delivered zero inner focus events; enabling first then hiding delivered one
complete focus-out. Both controlled children exited 0 and their owned tmux
servers were removed. Thus the pre-exec hidden gate cannot establish the
late-starting Qwen's unfocused state. This is a harness precondition defect,
not evidence for an upstream exemption or a LeanTTY product change.

The repair starts Qwen visibly, waits for its native alternate screen and
unambiguous initial focus-reporting enable, then uses the existing minimize
action. Missing or ambiguous readiness fails before minimizing. Codex/Pi retain
their pre-exec gate. Native attention, hidden-window observation, generic card,
return, privacy, interaction and cleanup assertions are unchanged.

The caller's new regression failed on the old sequence. The repaired software
passed `test-regression.ps1 -Group policy,tooling`, including 28 actual-owner
attention cases, 76 SSH-boundary cases and six real PTY/dispatcher cases. The
dispatcher cases use controlled Agent stubs, not model calls.

One `-DiagnosticHap -FocusReadinessProbe -Agents qwen -Modes tmux` run on the
physical ARM64 PC then passed from 19:29:55 to 19:32:20 on 2026-09-12. It used
the unchanged signed HAP `0db0f090…95e71`, actual Qwen and stock tmux, with no
prompt/model request. Inner-PTY `(focus-in, focus-out)` counts were `(0,0)` before
minimize, `(0,1)` after hidden and `(1,1)` after restore. Raw mode, alternate-screen
return, one documented TUI exit and the separate SSH close passed. Three local
commands each used one input and one Enter, without mismatch. Original Tab,
notification setting and screen policy were restored; temporary resources were
removed. The 19:34:07 independent read-only audit confirmed absence and unchanged
historical report/HAP. Its first invocation stopped before resource checks due
to using an object field for the result's string target; correcting this audit
schema assumption required no physical or model rerun.

Post-run review added one software-only negative case: an unconfirmed app
restore must not be retried by the focus helper's `finally`. Its failure-path
change does not alter the physically exercised successful sequence.

This closes the focus-startup defect, not native notification acceptance. The
minimize-to-host-observed-hidden interval still needs a causal ordering review:
focus-triggered attention may precede the host's after-hidden byte checkpoint.
Do not weaken that gate, add a name-based exemption or run another formal matrix
to discover its timing. Review the device-state/publication and output boundaries
first, retaining negative, ambiguous and privacy cases. C3/C4 and SSH remain open.

Evidence root: `build/verification/agent-emission-contract-20260912/`.

| Evidence | SHA-256 |
|---|---|
| `qwen-public-hook-probe.json` | `0ec9b3d2401d961a560b698c05857f9a3f004e5af2a3bcc0d2b322fe2f78c899` |
| `tmux-focus-probe.json` | `767ba28aa7caa3cb7e8bc8e8e8a2f779e7d958bc7ac9fea56f6af9b921d38987` |
| `software-focus-probe.json` | `6e609b9f944e50fe9887e059d4056536bb97e9e94cecac950a8a39b5153314da` |
| `software-final.json` | `08f9e844605580294f3efa786c3f9a4ff1f8cf1252e55b9ee3ed95a5509997fd` |
| `device-focus-probe/result.json` | `64724e25035a2b2857fdd456b528cdf34597eb9a89f241ef5f8b4a1f37127a17` |

Primary version evidence is the installed public Qwen code: notification/UI
chunk SHA `cd4d239ebd1d210edb0329287105bc94644cde971683e1d12683d1fbe359dca5`
and focus-hook chunk SHA
`8289bddb00db4a1a5c7be2fac1452dab5325261ddd1fcf4a595610ec07d03f1a`.
The [upstream hook paths](https://github.com/QwenLM/qwen-code/tree/v0.23.0/packages/cli/src/ui/hooks)
were identified, but the web reader could not retrieve their bodies; the tests
use the installed public bytes. No exact matching upstream issue was found.
[Huawei lifecycle guidance](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/faqs-ability-94)
does not promise remote PTY focus replay. These source boundaries and the real
tmux contrast, rather than an inferred product defect, determine the repair.
