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
