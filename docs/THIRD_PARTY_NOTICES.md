# Third-Party Notices

Audit date: 2026-08-30.

LeanTTY includes or depends on the software listed below. The authoritative
inputs for this audit are the checked-in Cargo/OHPM lockfiles and pinned native dependency manifests and the
resources actually packaged in the ARM64 release HAP.

## Native Terminal Development Integration (2026-09-17)

The 1.7 development branch builds `libleantty_terminal.so` from the official
Ghostty VT commit `82938b633ba646db38591d969c3c526332bd7e65`, using Zig
`0.16.0`. Archive SHA-256 values and Zig package hashes are recorded in
`tools/native-terminal/dependencies.json`; research build directories are not
inputs. The pinned build overlays select static installation, SDK runtime linkage,
the upstream C allocator and the Unicode runtime's optimization setting; they do
not patch VT parsing semantics. Both debug and release use this native renderer.

| Component | Notice |
| --- | --- |
| Ghostty VT | MIT; Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors |
| uucode | MIT; Copyright (c) 2026 Jacob Sandlund; includes the upstream Hoehrmann and Unicode notices |
| zlib | zlib; Copyright (C) 1995-2022 Jean-loup Gailly and Mark Adler |
| Zig runtime support | MIT; the locked Zig archive supplies its full notice |
| Packaged HarmonyOS SDK `libc++_shared.so` | SDK LLVM NOTICE, including Apache-2.0 with LLVM exceptions |

`tools/build-terminal-native.ps1` retains the complete upstream notices in
`.cache/native-terminal/licenses`, regenerated on every native build and removed
by LeanTTY's `-Clean`, outside Hvigor's `build/` cleanup. It extracts uucode's additional notices from
the digest-verified archive because Zig's package projection omits them.
Release artifact preparation copies these seven files into
`licenses/terminal-native` and includes their digests in the artifact manifest.
The existing bundled font notices below also cover native text rendering.

## Packaged Fonts

| Packaged resource | Embedded version metadata | Upstream release | License | SHA-256 |
|---|---|---|---|---|
| `JetBrainsMonoNerdFontMono-Regular.ttf` | JetBrains Mono `2.304`; Nerd Fonts `3.3.0` | https://github.com/ryanoasis/nerd-fonts/releases/tag/v3.3.0 | OFL-1.1 | `9E4DAD8C34FB31045D53790A936A0AFC3AAE3FB830E874FAADF3670662B04853` |
| `JetBrainsMonoNerdFontMono-Bold.ttf` | JetBrains Mono `2.304`; Nerd Fonts `3.3.0` | https://github.com/ryanoasis/nerd-fonts/releases/tag/v3.3.0 | OFL-1.1 | `174B245DB4097E08B372D8800EBFE4FD324FB81B2C9223DA7B9EC16EEB7DB901` |

Both font files embed the JetBrains Mono copyright notice and identify SIL Open
Font License 1.1. The full OFL text and the Nerd Fonts attribution note are in
`docs/OFL-1.1.txt`.

## Rust Dependencies (Cargo)

`leantty_ssh/Cargo.lock` resolves 178 registry packages and the external Git
package `mosh-client 0.1.2`, plus the local patched `ssh-key`, for
`aarch64-unknown-linux-ohos`; all report a
license expression or license file through Cargo metadata. The complete
versioned inventory is in `docs/RUST_DEPENDENCIES.md`.

The license families present are:

- Apache-2.0;
- MIT;
- MIT OR Apache-2.0;
- BSD-3-Clause;
- ISC;
- Apache-2.0 AND ISC (`ring`);
- Unlicense OR MIT;
- (MIT OR Apache-2.0) AND Unicode-3.0 (`unicode-ident`);
- 0BSD OR MIT OR Apache-2.0 (`adler2`);
- MIT OR Zlib OR Apache-2.0 (`miniz_oxide`).

Rechecked on 2026-09-25: `mosh-client` uses `MIT OR Apache-2.0`.
Cargo.toml selects exact version `=0.1.2` and release tag `v0.1.2` from
`https://github.com/wandcs/mosh-client-rs.git`; Cargo.lock fixes its source to
`177d2a11f8829df5582da4c1495ed9c9885461c3`, not a moving main branch.

The repository `LICENSE` contains the Apache-2.0 text. Release builds copy each
available package-specific license, copyright, copying, notice, or unlicense
file from the locked registry Cargo source into `licenses/rust/<package>-<version>/`.
`licenses/rust/packages.json` maps every locked registry package to those files and
records package metadata. For packages whose published crate archive
does not contain a license file, the index points to the shared MIT and/or
Apache-2.0 text included at the top level.

## vt100 source retained inside mosh-client

Mosh client 0.1.2 contains a private copy of vt100 0.16.2, originally by Jesse
Luehrs, with a U+FFFD handling patch. The registry vt100 package is therefore no
longer a separate dependency. Its complete MIT notice is reproduced here so it
remains included in the existing release notice bundle. The locked library's
`src/vt100/PATCH.md` documents source provenance and the patch removal condition.

The MIT License (MIT)

Copyright (c) 2016 Jesse Luehrs

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## ArkTS Dependencies (OHPM)

The root `oh-package-lock.json5` contains two development-only dependencies;
neither is included in the release HAP:

| Package | Version | Role | License |
|---|---|---|---|
| `@ohos/hypium` | `1.0.25` | Test framework | Apache-2.0 |
| `@ohos/hamock` | `1.0.0` | Mock framework | Apache-2.0 |

`entry/oh-package-lock.json5` also records the local LeanTTY native package at
version `1.0.0`; it is project code under Apache-2.0, not a third-party package.

## Distribution

The source distribution keeps this notice, `docs/RUST_DEPENDENCIES.md`,
`docs/OFL-1.1.txt`, and the project `LICENSE`. Release builds copy those four
files plus the locked Rust packages' license files and generated package index
into `build/outputs/release/licenses/`; that directory must accompany the HAP
or be attached to the public release page.
