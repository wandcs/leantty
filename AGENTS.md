# LeanTTY contributor-agent instructions

## Foundational rules

- Read and follow `docs/project-principles.md` before product, architecture,
  feature or refactoring work.
- Follow `docs/coding-guide.md` for ownership, responsibility boundaries and
  agent-maintainable implementation discipline.
- Use `docs/next-work.md` as the only source of outstanding project work.
- Follow `docs/versioning.md` and `docs/release-process.md` for branch scope,
  changelog entries, version preparation, AppGallery review, tags and releases.
- Files under `docs/archive/` are historical and do not authorize new work.
- Do not add concepts, dependencies or abstraction layers without passing the
  decision rules in the project principles.
- Preserve unrelated worktree changes.

## Platform scope

LeanTTY targets only a physical ARM64 HarmonyOS PC. Do not add or validate an
x86_64 emulator target unless the product scope is explicitly changed.

## PowerShell

Use `pwsh.exe -NoProfile` when PowerShell 7 is available. Otherwise use
`powershell.exe -NoProfile`. Run repository scripts with the per-process
`-ExecutionPolicy Bypass` option when required; do not change machine-wide
execution policy.

## Development and verification

```powershell
# Routine local checks: select only groups mapped by docs/quality-strategy.md
.\tools\test-regression.ps1 -Group policy,tooling

# Routine device work, only when the affected behavior requires a physical PC
.\tools\preflight-device.ps1
.\tools\dev-pc.ps1

# Formal release-package preparation only; includes the complete software gate
.\tools\verify-pc.ps1
```

`dev-pc.ps1` is the normal build, test-sign, install and launch loop.
For each feature iteration or bug fix, run only the checks directly related to
the changed event chain and the smallest stable main-path smoke checks that
finish quickly. Do not run unrelated suites or the complete physical matrix.

`test-regression.ps1 -Group ...` uses the same check registry for focused local
evidence and cannot be promoted to release acceptance. Ungrouped
`test-regression.ps1` is a full gate and is invoked once by `verify-pc.ps1` while
preparing a formal release package. The latter also runs Rust formatting, a
clean ARM64 native/debug HAP build and real-PC deployment.

`preflight-device.ps1` only proves that the ready HDC command and serialized
UiTest layout channels are usable. It does not install, launch, unlock or repair
the PC, and it does not prove product behavior. After it passes, run only the
named physical scenario mapped to the changed claim.

During formal release verification, use `-SkipDevice` only when device-visible
validation is not required and no device is available. A physical PC remains
required for any focus, keyboard, clipboard, window, persistence,
terminal-interaction or SSH-lifecycle claim directly affected by a routine
change.

Signing certificates, keystores and passwords are local-only and must never be
added to the repository.

## GitHub

Use the authenticated GitHub CLI for repository, issue, pull request, release
and account operations. Confirm the active account before a write operation.
Develop changes on focused short-lived branches and merge them through pull
requests. Record pending user-visible changes under `CHANGELOG.md` →
`Unreleased` or the selected version's `In development` section as defined by
the versioning policy. Create the immutable signed version tag only after
production verification, then publish the matching GitHub Release before
submitting that version to AppGallery. GitHub Release is the canonical version
identity. Never move or reuse a pushed tag or published release. If AppGallery
review fails for any reason, advance the version and repeat the release process
instead of resubmitting under the failed version.

## Editing and filesystem safety

- Keep generated files inside the repository's ignored directories or the
  system temporary directory.
- Use literal paths for data-derived filesystem operations.
- Never discard or overwrite unrelated user changes.
- Run the relevant tests and `git diff --check` for edited text.
