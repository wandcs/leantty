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

## Follow-up: preserve the notification log source

The PR190 formal attempt exposed a separate observation defect: OpenCode's
terminal ACK traffic displaced the hidden event from the mixed 500-line app
tail. Attention and publication remained, so the strict episode assertion
correctly rejected incomplete evidence. This did not establish a product bug.

The Agent notification assertion now queries the current PID and the three
owner tags at the device, before the tail limit. Shared log readers and all
ordering, main-thread, Pane, card, privacy and return assertions are unchanged.
Query errors propagate; a full 500-line owner snapshot fails as incomplete
harness evidence. This does not guarantee retention beyond HiLog's bounded
device buffers.

The actual-owner high-traffic regression failed with the old reader and passed
with the new reader. Focused `policy,tooling` passed, including rejected
saturation and query-failure cases. One zero-model physical diagnostic on
OpenHarmony 6.1.1.135 / UiTest 6.0.2.3 ran at 21:27:35–21:30:13 (+08:00):

- mixed query: 500 lines, all terminal ACKs, hidden event absent;
- owner query before BEL: one line, hidden event retained;
- one controlled BEL: strict episode, generic card/privacy and same-Pane
  return passed; final capture completed with child exit 0;
- all five local/connected commands had one input, one Enter and no mismatch;
- stage cleanup and the 21:32:27 independent resource audit passed. The original
  HAP, prior formal report and frozen PR190 checkout were unchanged.

Evidence root: `build/verification/agent-notification-source-20260912/`.
`device-source-probe/result.json` SHA-256:
`55c83c489b5a8ef4ef9c4cfae0e43587911720ac0d36a5a1fe54c44e221a37be`.
This controlled producer qualifies only the reader repair, not native Agent
behavior or formal C3 acceptance. Fresh R2 admission, QH and the complete
Agent/SSH suffix remain required after freezing this harness.

[OpenHarmony HiLog documentation](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/dfx/hilog.md)
and [Huawei's PC logging instructions](https://consumer.huawei.com/cn/support/content/zh-cn16083991/)
document tag/PID selection and the bounded tail. No matching upstream issue was
established; the real-device comparison above supplies the missing evidence.

## Follow-up: keep checkout line endings out of the public identity query

The PR191 formal attempt passed its first five Agent checks, then stopped at
Pi/tmux's public identity query. The tracked PowerShell checkout uses CRLF;
its multiline Bash argument carried those CR bytes into WSL. The original
query failed, while the same query with CR removed returned the installed
public identities. This was a harness failure, not a LeanTTY transport defect.

Use one line for this fixed Bash query. Keep query exit/output validation,
exact Pi/tmux versions, extension/config hashes and the existing forwarding
limitation unchanged. Do not change repository line-ending policy, product
code, shared helpers, fixture configuration or the retained HAP.

The actual owner now has 24 LF/CRLF cases covering valid identities, query
errors, missing/extra output, malformed hashes, unknown/missing versions and
changed/missing public files. Before the repair, eight CRLF cases failed;
afterward all 100 owner checks passed. Focused `policy,tooling` passed under
the desktop user. An earlier sandbox run stopped at WSL access denial; that
failed evidence is preserved separately.

At 22:08:43 (+08:00), a zero-model WSL check ran the real owner in both source
line-ending forms. Both read Pi 0.84.4, tmux 3.6 and the approved public-file
hashes. The classifier used synthetic outer-capture metadata, so this proves
the query boundary only, not native Agent behavior or formal acceptance.
The generated public config was removed; WSL lifecycle was not changed.

Evidence root: `build/verification/agent-public-identity-20260912/`.
`public-identity.json` SHA-256:
`e80423493740451c53502f4581bf9ff43cb67b0fc16efe7770d17fc56a1d53e2`.
Fresh frozen-harness admission, QH and the complete Agent/SSH suffix remain
required. The original failed formal reports retain their verdicts.

[Git's `eol` documentation](https://git-scm.com/docs/gitattributes#_eol)
explains checkout normalization; the
[WSL command reference](https://learn.microsoft.com/en-us/windows/wsl/basic-commands)
defines the host invocation. Neither proves this query's bytes: the actual
CRLF/LF comparison above does. The historical
[WSL CR error report](https://github.com/microsoft/WSL/issues/2939)
is supporting context, not a current-platform diagnosis.

## Follow-up: observe Agent input focus without a redundant click

PR192's formal continuation passed QH and both Codex modes. OpenCode direct
passed notification, same-Pane return and search, then the pre-input guard
rejected its current focused-field count. The saved large-input layout had one
focused terminal. The Agent helper still clicked and returned its pre-click
layout; its catch discarded the shared guard's safe failure metadata. The old
report cannot distinguish zero focus, multiple fields or a transient view.

The Agent-local repair returns an already-focused node/layout pair without a
click. A necessary click now requires one fresh focused field belonging to the
same native Web owner. Failure stops before text. The normal Agent check keeps
the existing `LeanTTYTextInputFailure` metadata: phase, counts and whitelisted
comparisons, not contents or raw identifiers. Shared input guards, one-Enter
rules, cleanup, product code, xterm, dependencies and the HAP are unchanged.
The fixed 200 ms wait is removed; no timer, polling or retry replaces it.

Ten new actual-owner cases cover focused/unfocused preparation, lost/replaced
owners, ambiguous fields and pre/post input failure propagation. Against the
old frozen source, eight fail; the repair passes all 110 checks. An initial
test incorrectly restored a real log-clearing side effect while loading shared
comparison helpers; it failed before the injected input error. After restoring
that external-effect stub, both red and green runs reached the intended owner.
Focused `policy,tooling` also passed. This is software evidence, not a physical
reproduction of the previous focus loss.

### Bounded physical contrast and cleanup

The unchanged HAP `0db0f090…95e71` ran OpenCode 1.18.30 direct in zero-model
interaction mode on the physical ARM64 PC. An ignored adapter reused the real
SSH, focus, input, TUI-exit and finalization owners; no notification/search
workload, model prompt, Shift+Enter or resize was added.

- 22:52:35–22:54:38 (+08:00): the adapter's Windows `ReadAllBytes` could not
  open the live WSL capture. It stopped before either contrast vector. The
  original result remains invalid/interrupted. One guarded product command
  removed its residual temporary fingerprint at 22:56:11; the 22:57:24 audit
  confirmed cleanup and restoration.
- A local held-writer test reproduced the sharing failure and verified bounded
  read-only `FileShare.ReadWrite` snapshots. Only the ignored adapter changed.
- 22:57:43–23:00:21: the single corrected contrast passed. Old and new helpers
  each started from one focused terminal and delivered one `English中文` marker
  and one contiguous 4096-character marker to the inner PTY. Each phase had two
  Ctrl+C events and no Enter. Byte totals also include terminal protocol input;
  they are not a content-equality or performance comparison.
- Native `/exit` returned from alternate screen and proved shell-ready before
  SSH close. Three local and two connected setup/cleanup commands each used one
  input/Enter with no mismatch. Stage cleanup and the 23:01:07 independent audit
  passed: owned fingerprint, listener, processes, directory and reverse mapping
  absent; original Tab, notification setting and timeout restored. Raw captures
  were deleted. The original HAP, formal report and PR192 freeze stayed unchanged.

Evidence root: `build/verification/agent-focus-input-20260912/`.

| Record | SHA-256 |
| --- | --- |
| `device-focus-contrast/result.json` | `ae0fdfd097140ecbdbb87e37b23767c4e3fb5abba72f29ddb5d318f422ca30b7` |
| `device-focus-contrast-shared-read/result.json` | `70f477807a8e58c237833976fc4439e90e7943123dc5246ab558c6a5c1cd899f` |
| `device-focus-contrast-shared-read-audit.json` | `e0fb73f27baeabe00add8f2669a0986f050b190363bd687b0cd99ca0c6e7bfd3` |

### Reframing and next boundary

Both variants passed, so the extra click is not a proven cause of the prior
incident. This sample also lacks its notification/search history. Stop causal
sampling here: no product/platform attribution, new exemption or further
diagnostic round is justified. Retain the repair for the independently proven
stale-context and discarded-evidence defects, with this physical main-path
check. Do not claim that historical focus loss is fixed.

After merge/freeze, reassess R2 identities and resources, then run fresh QH and
the complete Agent/SSH suffix as acceptance, not as a reproduction experiment.
Use the fixed budget and stop on the first failure; preserve the new metadata
before choosing any next diagnostic. Neither routine report replaces formal
evidence. C3/C4 remain open; no formal matrix or product build ran in this round.

The [OpenHarmony UiTest guide](https://github.com/openharmony/docs/blob/master/en/application-dev/application-test/uitest-guidelines.md)
describes coordinate input's own focus action, while the
[UiTest command reference](https://github.com/openharmony/testfwk_arkxtest/blob/master/README_zh.md)
separates click and layout observation. Current upstream source is not the exact
installed UiTest binary. [Playwright actionability](https://playwright.dev/docs/actionability)
is a comparison, not platform evidence; no matching upstream issue established
this incident's cause. [.NET FileShare](https://learn.microsoft.com/en-us/dotnet/api/system.io.fileshare)
documents the independent diagnostic reader's sharing contract.
