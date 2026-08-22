# Contributing to LeanTTY

Thank you for helping improve LeanTTY. The project accepts issues and pull
requests, but keeps a deliberately narrow product scope.

## Before starting

Read [the project principles](docs/project-principles.md). Reliability comes
first, simplicity is the default, and usability work stays focused on the core
remote-terminal path. Code changes must also follow the ownership, boundary and
agent-maintainability rules in [the coding guide](docs/coding-guide.md).

- For a bug or documentation problem, open an issue with reproducible evidence.
- For a feature or architectural change, open an issue before implementation.
- Security vulnerabilities must use the private process in
  [SECURITY.md](SECURITY.md), never a public issue.
- Support requests belong under the boundaries in [SUPPORT.md](SUPPORT.md).

Maintainers may close proposals that add permanent concepts, dependencies or
maintenance cost without clear evidence from the core product path.

## Development environment

Windows with DevEco Studio is the supported application build environment.
LeanTTY currently targets ARM64 HarmonyOS PC only.

Required tools:

- DevEco Studio and HarmonyOS SDK API 6.1.1 (24)
- WSL 2 with Rust 1.96+ and the `aarch64-unknown-linux-ohos` target
- Node.js for the Web terminal policy tests
- PowerShell

Useful commands:

```powershell
# Routine device loop when relevant to the change
.\tools\dev-pc.ps1

# Formal release: complete software regression and clean ARM64 candidate
.\tools\test-regression.ps1
.\tools\verify-pc.ps1

# Formal release: feature-owned behavior matrix for the retained candidate
.\tools\verify-key-passphrase-pc.ps1
```

LeanTTY runs Rust formatting, tests and compilation in WSL. The maintainer
scripts invoke WSL automatically; the Windows DevEco SDK supplies only the
OHOS target linker and archive tools. To run a Rust check manually, open WSL at
the mounted checkout:

```bash
cargo test --locked --manifest-path ./leantty_ssh/Cargo.toml -p leantty-ssh-core
```

Public CI checks source policy, Rust core behavior and Web terminal policy.
DevEco compilation, signed HAP deployment and device-visible interaction remain
maintainer gates because they require the HarmonyOS SDK, local signing material
and a physical PC.

All changes must follow the scope and evidence classification in
[`docs/quality-strategy.md`](docs/quality-strategy.md). After an iteration or
bug fix, run only checks for the changed event chain plus the smallest stable
main-path smoke that finishes quickly. Complete regression and the full
physical matrix are reserved for formal release-package preparation.
Installation and launch alone do not prove changed device behavior.

## Change rules

- Keep each change focused and explain the user-visible problem it solves.
- Preserve the ownership model `App Shell → Tab → Pane → Session`.
- Follow the current boundaries in [`docs/architecture.md`](docs/architecture.md)
  and the evidence mapping in
  [`docs/quality-strategy.md`](docs/quality-strategy.md).
- Do not add x86_64 emulator support, mobile layouts, plugins or speculative
  abstraction layers.
- Add or update tests for state machines, protocols and pure logic.
- Record user-visible fixes and capabilities in the pending changelog section
  defined by [the versioning policy](docs/versioning.md); maintainers classify
  and assign the final target version.
- Focus, keyboard, clipboard, window, persistence, terminal interaction and SSH
  lifecycle changes need real-PC evidence.
- Do not commit generated output, SDK files, packages, credentials, private
  keys, device identifiers, host addresses or unredacted logs.

ArkTS changes must follow the restrictions enforced by the project linter.
Rust changes must pass `cargo fmt`; clippy warnings in the pure core should be
fixed rather than suppressed without explanation.

## Pull requests

A pull request should include:

1. The problem and its fit with the project principles.
2. The implementation boundary and any new long-lived state or dependency.
3. Automated test results.
4. Real-PC evidence when the behavior is device-visible.
5. Screenshots only when they materially help review, with personal data
   redacted.

For application changes, include the retained candidate SHA-256, its
verification mode and the local evidence file names. Do not paste private
device identifiers, host details or raw logs.

Small, reviewable pull requests are preferred. There is no mechanical line
limit, but unrelated refactoring should be split out.

Release branches, version metadata, AppGallery submissions and stable tags are
maintainer-controlled and follow
[the release process](docs/release-process.md).

By submitting a contribution, you agree that it is licensed under the
repository's Apache-2.0 license. The project does not currently require a
separate Contributor License Agreement.
