# Terminal web assets

This directory pins and regenerates the xterm.js assets vendored into
`entry/src/main/resources/rawfile`.

Run:

```powershell
npm ci
npm run build
```

Pinned packages:

- `@xterm/xterm@6.0.0`
- `@xterm/addon-fit@0.11.0`
- `@xterm/addon-search@0.16.0`
- `@xterm/addon-web-links@0.12.0`
- `@xterm/addon-serialize@0.14.0`
- `@xterm/addon-webgl@0.19.0`

The generated `assets-manifest.json` records the size and SHA-256 of each
vendored file. All six packages use the MIT license and are covered by
`docs/THIRD_PARTY_NOTICES.md`.

The build applies one version-locked LeanTTY patch to `addon-webgl.js`. xterm
6.0.0 packs background color and non-color attributes into the same render-model
integer, while `RectangleRenderer.updateBackgrounds` treats any non-zero value
as a cell background. The local patch masks that read to `Attributes.CM_MASK |
Attributes.RGB_MASK`, so dim, italic, underline, overline, OSC 8 hyperlink and
protected text on the default background do not allocate an opaque rectangle.
ANSI, 256-color and TrueColor backgrounds remain opaque, and inverse, selection
and decoration paths are unchanged.

The implementation lives only in
`patches/xterm-webgl-default-background.mjs`. It records the package version,
xterm release commit, readable TypeScript equivalent, full npm input SHA-256,
exact minified match and removal condition. `npm run build` fails closed if any
of those audited inputs drift; `npm test` covers the patch guard and the default
versus explicit background matrix.

When upgrading xterm:

1. inspect upstream `addons/addon-webgl/src/RectangleRenderer.ts` first;
2. remove the patch if upstream now decides background identity from color bits;
3. otherwise re-audit one equivalent read, update the pinned source identity and
   input hash, then run the semantic matrix and physical WebGL scenario; and
4. never carry the old minified replacement forward merely because it can be
   made to match.

## Input-order patch

`patches/xterm-input-order.mjs` applies a separate, hash-locked repair to xterm
6.0.0's CoreBrowserTerminal and CompositionHelper. Non-composing `insertText`
uses the input event instead of a held-key flag; it invalidates the helper's
pending textarea diff before emitting. Other non-composing input flushes an
existing legacy diff, preserving deletion before the next insertion. A helper
owns one pending callback, so queued callbacks cannot duplicate input or share
state across terminals. Composition and its pending final send keep ownership
of composed text; screen-reader mode retains the legacy path.

This is a generated-core patch, not an unmodified xterm asset. It adds no
runtime private-object replacement, event synthesis, text deduplication or
Bridge/native compensation. Its readable equivalent and exact audited sites
live in the patch module. Remove it when an upstream release passes the same
input-order cases; a dependency change must fail until explicitly re-audited.
The upstream report is [xterm #6045](https://github.com/xtermjs/xterm.js/issues/6045),
checked on 2026-09-06; its open related PR is not treated as a verified fix.

`npm test` includes generated-owner behavior and patch-guard tests. The bounded
browser check uses an existing local Playwright installation, not a product
dependency:

```powershell
node tools/web-terminal/verify-xterm-input-order.mjs <absolute-playwright-index.mjs> upstream <red-evidence-directory>
node tools/web-terminal/verify-xterm-input-order.mjs <absolute-playwright-index.mjs> packaged <green-evidence-directory>
```

Run these from the repository root. The upstream run deliberately fails correct
input assertions; the packaged run must pass them. Both use the same synthetic
event corpus, actual DOM listeners and real timers. Neither proves that the
historical intermittent UiTest loss had this cause, nor replaces HarmonyOS PC
input/IME validation.

## Development performance probe

`acceptance-performance.js` is injected by `performance-diagnostic-source.ps1`
only into debug/test terminal sources; it is absent from release packages.
It validates a bounded public fixture stream, sequence and CRLF, observes the
xterm public buffer, and reports its own observation cost. Its frame callback
is not a physical-display latency measurement.

`perfActiveActionsEnabled` defaults to `false`. Automatic public-vector input
and standard WebGL context-loss are for dedicated fixture packages only, never
ordinary debug use. A dedicated build must restore this source and the device's
ordinary package afterward. Remote output alone must not enable those actions.
`tools/test-performance-diagnostics.cjs` exercises the injected probe and its
default-off action boundary through the `arkts` regression group.
