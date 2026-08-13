# LeanTTY

LeanTTY is a keyboard-first, zero-configuration remote terminal for ARM64
HarmonyOS PC, inspired by [Ghostty](https://ghostty.org).

The project aims to be reliable, quiet and native to HarmonyOS PC. Ghostty is a
reference for product quality, not a feature-parity target. Scope and technical
decisions follow the [project principles](docs/project-principles.md).

## Status

Version 1.0.0 was rejected by Huawei AppGallery Connect because the former
application name contained an unauthorized trademark; it was never published.
[LeanTTY 1.0.1](https://github.com/wandcs/leantty/releases/tag/v1.0.1) passed
AppGallery review and became the first public release on 2026-07-28.
[LeanTTY 1.1.0](https://github.com/wandcs/leantty/releases/tag/v1.1.0) was
published on GitHub on 2026-08-05, then superseded before AppGallery submission
when its production Profile authorization needed correction.
[LeanTTY 1.1.1](https://github.com/wandcs/leantty/releases/tag/v1.1.1) was
published on GitHub on 2026-08-06 with the corrected production Profile, then
passed AppGallery review and was released to users on 2026-08-08.
[LeanTTY 1.2.0](https://github.com/wandcs/leantty/releases/tag/v1.2.0) was
published on GitHub on 2026-08-08 after its exact production and review builds
passed the formal software, signing and physical-PC gates. The matching
production APP passed AppGallery review and was released to users on 2026-08-13.

The `main` branch can contain behavior listed under `CHANGELOG.md` →
`Unreleased` or the selected version's `In development` section. Source-tree
documentation marks that applicability explicitly; do not assume development
behavior is present in the AppGallery version.

The immutable `v1.0.0`, `v1.0.1`, `v1.1.0`, `v1.1.1` and `v1.2.0` tags record
the rejected former identity, first AppGallery release, superseded GitHub
release, superseded AppGallery release and current AppGallery/GitHub release
respectively.
Exact submitted-source mapping, artifact hashes and signing verification remain
in the private release evidence archive. No signing credential or generated
application package is stored in Git.

## Features

- SSH password and private-key authentication
- OpenSSH `known_hosts` verification
- Multi-tab terminal with at most two panes per tab
- Keyboard-first focus, selection, copy and paste
- OpenSSH-compatible host configuration and key management
- Catppuccin Mocha and Latte themes
- Rust/russh transport through napi-ohos
- xterm.js rendering in ArkWeb

## Terminal interaction

- Hold `Ctrl` and left-click an HTTP(S) or OSC 8 link to open it in the system
  browser.
- When tmux or another TUI has enabled mouse reporting, use
  `Ctrl+Shift+Left Click` instead.
- With tmux mouse mode enabled, drag normally to use tmux selection; releasing
  the mouse copies through tmux's standard OSC 52 clipboard path.
- Hold `Shift` and drag to bypass TUI mouse reporting for local text selection,
  then press `Ctrl+C` to copy it.

## Product scope

LeanTTY currently targets only ARM64 HarmonyOS PC with keyboard and mouse. It
is an SSH terminal, not a local shell, Linux environment, file manager or
general remote-administration suite.

For installation, first connection, current commands, keyboard interaction,
data retention and recovery, see the [User Guide](docs/user-guide.md). LeanTTY's
local-data and network boundaries are documented in the
[Privacy Policy](PRIVACY.md) and [Security Policy](SECURITY.md).

## Requirements

- Windows and DevEco Studio with HarmonyOS SDK API 6.1.1 (24)
- Rust 1.96+ with the `aarch64-unknown-linux-ohos` target
- An ARM64 HarmonyOS PC for interaction and lifecycle verification

## Build and verify

```powershell
rustup target add aarch64-unknown-linux-ohos

# Build only
.\tools\build-all.ps1

# Formal release: complete software regression gate
.\tools\test-regression.ps1

# Routine change: build, test-sign, install and launch when relevant
.\tools\dev-pc.ps1

# Formal release: clean committed candidate and real-PC deployment
.\tools\verify-pc.ps1

# Run only a named scenario affected by a routine change; run all at release
.\tools\verify-key-passphrase-pc.ps1
```

After a feature iteration or bug fix, run only tests for the changed event
chain plus the smallest stable main-path smoke checks that finish quickly.
Complete software regression, a clean ARM64 candidate build and the full
physical-PC matrix are reserved for preparing a formal release package. See
[the regression test standard](docs/quality-strategy.md).

Device deployment requires a local signing configuration and certificate.
Those files are deliberately excluded from the repository. See
[the release process](docs/release-process.md) for the trust boundary.

## Architecture

```text
App Shell
  └─ Tab → Pane → Session
                 ├─ SSH Transport
                 ├─ Terminal Surface
                 └─ System Services
```

- ArkTS/ArkUI owns application state, windows, tabs, panes and system services.
- Rust/russh owns SSH transport, PTY and byte streams.
- ArkWeb/xterm.js owns terminal rendering, input, selection and resize.
- The bridge carries validated protocol messages; it does not contain business
  rules.

The current event chains, runtime ownership, terminal recovery and persistent
state model are documented in [the architecture baseline](docs/architecture.md).

## Contributing

Issues and pull requests are welcome under the bounded policy in
[CONTRIBUTING.md](CONTRIBUTING.md). Feature proposals are evaluated against the
project principles before implementation.

Community expectations, support boundaries and the security reporting channel
are documented in:

- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Support](SUPPORT.md)
- [Security Policy](SECURITY.md)
- [Privacy Policy](PRIVACY.md)
- [Trademark Policy](TRADEMARKS.md)

## License

LeanTTY is licensed under Apache-2.0. See [LICENSE](LICENSE).

Third-party components remain under their own licenses; see
[THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md).
