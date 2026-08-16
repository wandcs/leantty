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

The build applies one version-locked LeanTTY patch to `addon-webgl.js`:
explicit ANSI and true-color cell backgrounds use the opacity supplied by the
terminal theme instead of xterm's hard-coded opaque alpha. The build fails if
the exact audited xterm 6.0.0 render site changes, so dependency updates must
review the patch rather than silently carrying it forward.
