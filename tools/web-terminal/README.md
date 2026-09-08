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

## Offline user-guide review

Run these commands from the repository root with Node.js 24. No dependency
install, product build or physical PC is needed for this editing workflow.

```powershell
node tools/web-terminal/preview-user-guide.mjs
```

Open the printed URL. The server binds only `127.0.0.1` on a free port and serves
an immutable snapshot of `docs/design/LeanTTY-User-Guide.html`. Restart after
editing; Ctrl+C stops it. To preview the packaged resource instead, use
`node tools/web-terminal/preview-user-guide.mjs 0 packaged`. Only that guide is
served: no repository directory listing, arbitrary file paths, CORS or writes.
Do not expose the service through a proxy or change it to a LAN listener.

For automated browser checks, use an existing local Playwright Node module and
installed Chrome. Pass the module's absolute `index.mjs` path; this tool neither
downloads a browser nor adds Playwright to product dependencies.

```powershell
node tools/web-terminal/review-user-guide.mjs <absolute-playwright-index.mjs> build/verification/guide-review-<new-run-id>
```

The runner owns its loopback server and isolated headless browser, then closes
both. It checks Chinese/English entry and switching, ten TOC links per language,
recovery disclosures, key command text, browser back/reload and 1280/800-pixel
layouts. It uses the standard reduced-motion preference and the guide's existing
CSS branch; this checks navigation and layout, not smooth-scroll animation.
It also checks Mosh cross-links and captures Mosh, data-retention and layout-only
recovery sections in both languages at both widths. It saves viewport/section
screenshots and incremental `result.json` with guide
and runner hashes, browser version, per-check timing, errors and cleanup status.
Use a new evidence directory for each run; earlier results are never overwritten.
Non-guide page requests are blocked and fail the check. History checks preserve
language and URL without assuming a particular browser-restored scroll position;
explicit TOC clicks must put the chapter heading in view.

A passing run is an editing aid, not content approval. Inspect the screenshots
and review both languages against the intended version's delivered behavior.
Previewing an edited source before copying it is allowed; the report records
whether source and packaged bytes match. `test-user-guide.mjs` still requires
that parity before packaging. These desktop checks do not replace HarmonyOS
`help`, permission, file export or system-browser acceptance.

`test-user-guide-preview.mjs` exercises the real HTTP boundary and port cleanup;
it is included in `npm test` and the `web`/`tooling` regression groups. Browser
review remains a separate editorial step, not an automatic full software gate.

### 1.6 guide revision 9 editorial record — 2026-09-07

Both languages were checked against current command help, parser, Mosh page and
recovery owners. The revision documents UDP/SSH port separation, IPv4/direct-only
limits, prediction, interruption, local close, layout-only recovery and system-owned
window geometry. No product code or guide-export path changed.

The maintainer approved this guide on 2026-09-07. Its source and packaged-copy
bytes remain unchanged after that approval.

`build/verification/docs-1.6-closure-20260907/guide-review-final/result.json`
records 63 passing browser checks, 20 screenshots and complete browser/server
cleanup. All 20 screenshots received a separate visual review; both widths and
languages were readable without clipping. The source and rawfile copy are 97,952
bytes with SHA-256 `a6c680b669b3be2459de74f61343bb92cd4a89ce4917d0dc1b27c22938cb8ac4`.
The focused `policy,web` gate passed. This is host-side editorial evidence, not a
new HAP or device acceptance; extract and compare the guide from the exact formal
candidate when that package is built. The detailed local review is `editorial-review.md`
in the same evidence root.

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
