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
