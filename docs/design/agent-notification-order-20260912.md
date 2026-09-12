# Agent notification observation ordering — 2026-09-12

## Contract and cause

LeanTTY must handle native terminal attention while hidden, publish a generic
system notification and return to its source Pane. A host log-read timestamp is
not the window event's timestamp; unconditional Agent emission is not a product
contract.

The old assertion required a complete native frame after the host's
`after-hidden` output checkpoint. That checkpoint follows the minimize click,
HDC visibility-log query and WSL capture read. A valid notification can complete
inside this observation interval and be rejected. An actual-owner regression
reproduced that false rejection before the repair.

## Narrow repair

Clear the current app-log epoch before the pre-action output checkpoint.
Retain both byte checkpoints and complete native outer-PTY evidence; accept only
frames that start at or after `before-minimize`. This is an observation bound,
not proof of client receipt.

Require the current process's main-thread owner sequence:
EntryAbility hidden, AppViewModel attention, BackgroundBellNotification
successful publication. Bind attention/publication and the actual notification
return to one complete Pane ID. Reject incomplete, reversed, re-visible,
cancelled, cross-process/thread, wrong-owner and ambiguous multi-Pane episodes.
Handle the documented optional HiTrace prefix, not arbitrary text prefixes.
The real generic card and privacy assertions remain mandatory.

Only the Agent observer, assertion and tests change. Product code, dependencies,
shared SSH/cleanup helpers, signed HAP and upstream applicability rules do not.
Pi/tmux retains its evidence-bound forwarding limitation; no Qwen exemption is
introduced. There is no user-visible Changelog change.

## Evidence and limitations

`test-regression.ps1 -Group policy,tooling` covers the actual PowerShell owner,
negative episode/return cases, observer units and six real PTY/dispatcher cases.
The HiTrace sample also failed before its parser correction. Missing byte
checkpoints or window evidence, old/boundary-crossing frames, malformed prefixes
and wrong full Pane IDs cannot qualify.

Two zero-model diagnostics used the unchanged ARM64 test HAP
`0db0f090…95e71`. An ignored adapter reused the real SSH/notification helpers,
a public controlled producer and stock tmux. It waited for actual hidden state,
emitted one BEL and deliberately delayed the host checkpoint until the observer
saw that frame. This isolates host-observation ordering, not Agent emission.

- 20:18:42–20:21:04: device logs proved hidden, attention and publication in
  order. The new parser rejected the platform HiTrace prefix; card/return were
  not exercised. Original result is failed; cleanup and independent audit passed.
- 20:23:11–20:25:17: the actual repaired assertion observed the generic card and
  returned to the same Pane. Final capture had one complete interval frame,
  `afterMinimizeStartCount=1`, `afterHiddenCount=0` and child exit 0.
  The adapter then incorrectly required an empty capture directory, counting
  numeric `.outer-checkpoints` metadata as raw output. Its failure cleanup
  missed the already-ready shell state; original result remains
  `invalid/interrupted`, not an end-to-end pass.
- A separate guarded product command removed the remaining owned fingerprint
  at 20:27:57, with one input/Enter and no mismatch. The 20:28:49 independent
  audit proved resource absence and original Tab/settings restoration. HAP,
  PR188 freeze and historical formal reports were unchanged.

At the reframing checkpoint, the empty-directory requirement was removed from
the plan: it is not a content-retention contract. A unit test explicitly keeps
metadata while proving raw deletion. No third physical repeat, shared cleanup
rewrite or model request was justified. The completed notification subchain and
separate recovery support this narrow repair; neither failed report is rewritten
or eligible for formal evidence reuse.

Evidence root: `build/verification/agent-notification-order-20260912/`.

| Record | SHA-256 |
| --- | --- |
| `device-order-probe/result.json` | `a1f36379a90e13d180de81527b20df5dfb0d5f1f88a16585cfe63da9c07e100d` |
| `device-order-probe-hitrace/result.json` | `8b7a5c9b4bd5408b686a7b884f88ad5eb4ec8e7e250339fb9818b4da08074c7b` |

Next: freeze the verified harness, refresh R2 state admission and formal QH, then
continue the Agent/SSH suffix. The full native Agent matrix, C3 and C4 remain
open. No product build, Mosh/network/lifecycle repeat or formal matrix ran here.

## Primary-source research

The [OpenHarmony Window API](https://raw.githubusercontent.com/openharmony/docs/master/en/application-dev/reference/apis-arkui/arkts-apis-window-Window.md)
defines the visibility callback, not host sampling order.
[NotificationManager](https://raw.githubusercontent.com/openharmony/docs/master/en/application-dev/reference/apis-notification-kit/js-apis-notificationManager.md)
separates asynchronous publication from later UI observation.
The [HiTraceChain guide](https://raw.githubusercontent.com/openharmony/docs/master/en/application-dev/dfx/hitracechain-guidelines-ndk.md)
documents the optional three-field log prefix confirmed on this PC.

[Playwright's event-wait pattern](https://playwright.dev/docs/api/class-page#page-wait-for-response)
supports arming observation before action; it is not HarmonyOS evidence.
[tmux issue 4909](https://github.com/tmux/tmux/issues/4909) concerns 3.4 and multiple
panes, not this 3.6 single-pane case, so it was excluded as a cause. No matching
upstream issue establishes the old host-checkpoint requirement.
