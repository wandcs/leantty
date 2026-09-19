# Offline user guide tools

The native terminal no longer packages xterm or uses npm dependencies here.
This directory retains the standalone HTML guide preview and checks:

```powershell
node tools/web-terminal/test-user-guide.mjs
node tools/web-terminal/test-user-guide-preview.mjs
node tools/web-terminal/preview-user-guide.mjs
```

The guide asset remains `entry/src/main/resources/rawfile/LeanTTY-User-Guide.html`.

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
