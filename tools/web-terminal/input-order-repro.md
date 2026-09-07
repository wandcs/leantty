# Single-character xterm input-order reproducer

This reproduces a **candidate mechanism**, not the unexplained HarmonyOS input
loss. It uses the pinned, unchanged npm xterm 6.0.0 bundle, real DOM events and real
browser timers. Events are synthetic (`isTrusted=false`); no IME, LeanTTY runtime,
Bridge, server or network is involved. The only text is the public character `a`.

## Run

Open `tools/web-terminal/input-order-repro.html` from the checkout in Chrome and
click **Run fixed cases**. The page loads the installed npm `xterm.js` and the
packaged `xterm.css`; it needs no server. Restore the pinned dependencies with
`npm ci` in `tools/web-terminal` if `node_modules` is absent.

For ten fresh-page checks and a screenshot, use an existing Node/Playwright
installation and installed Chrome:

```text
node tools/web-terminal/verify-input-order-repro.mjs --help
node tools/web-terminal/verify-input-order-repro.mjs --playwright-module <absolute-path-to-playwright/index.mjs>
```

If `playwright` is already resolvable by Node, omit `--playwright-module`. Results
default to an ignored `build/verification/input-order-minimal-<timestamp>/`
directory. `--output <directory>` selects another evidence directory. The runner
checks the exact upstream npm xterm SHA-256;
an upgrade requires re-auditing the expected behavior.

## Smallest demonstrated failing sequence

1. Start a fresh xterm and its empty textarea.
2. Dispatch `keydown` with `keyCode=229`.
3. Let the zero-delay textarea-diff callback finish before insertion.
4. Insert `a` into the textarea and dispatch composed `input(insertText, "a")`.
5. Dispatch `keyup`.

The textarea contains `a`, but `Terminal.onData` emits nothing. The ordinary
input handler rejects composed input while `_keyDownSeen` remains true, and the
earlier diff already completed against an unchanged value. No private handler
or timer is replaced by this page.

| Controlled change | DOM value | Output |
| --- | --- | --- |
| Insert before the diff runs | `a` | `a` |
| Insert after the diff, before keyup | `a` | empty |
| Move keyup before insertion | `a` | `a` |
| Omit keydown | `a` | `a` |
| Use a plain textarea with the delayed sequence | `a` | `a` in textarea |

This is minimal in nonempty payload length, not a claim that every possible
event sequence has been minimized. Ten deterministic runs do not estimate the
frequency of a natural device fault. To attribute LeanTTY's intermittent loss,
capture a real failing DOM/input/diff/onData trace and compare its boundaries;
the four successful physical samples in §8.19 did not show this ordering.

## Research checked 2026-09-05

- The installed xterm 6.0.0 `CoreBrowserTerminal._inputEvent` and
  `CompositionHelper._handleAnyTextareaChanges` agree with this mechanism.
  Upstream [#5887](https://github.com/xtermjs/xterm.js/issues/5887) and
  [#6045](https://github.com/xtermjs/xterm.js/issues/6045) describe related IME
  failures, but their macOS traces put input before keydown. That is not evidence
  that HarmonyOS delivered this page's keydown-first sequence.
- [OpenHarmony UiTest documentation](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/application-test/uitest-guidelines.md)
  and [UiDriver source](https://github.com/openharmony/testfwk_arkxtest/blob/master/uitest/core/ui_driver.cpp)
  distinguish coordinate text input, physical key events and clipboard injection.
  Current public master cannot establish the behavior of the device's UiTest
  6.0.2.3 binary. Huawei official/community search found no matching confirmed
  HAD-W32 missing-character diagnosis; absence of a report is not a guarantee.
- [Playwright input guidance](https://playwright.dev/docs/input) distinguishes
  filling text from sequential key events. Neither API proves HarmonyOS IME
  timing. This page explicitly controls synthetic event order instead.

On 2026-09-06 the maintainer separately authorized a build-time repair of this
controlled mechanism. The original reproducer now loads the pristine npm asset
so it remains a defective baseline after the packaged asset changes. Historical
HTML/runner hashes still describe their original runs. See `README.md` for the
separate correctness corpus, `docs/next-work.md` for active work and
`docs/test-release-efficiency.md` §8.21 for the original measurement.
