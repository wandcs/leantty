# Versioning Policy

LeanTTY uses `MAJOR.MINOR.PATCH`, with
[Semantic Versioning 2.0.0](https://semver.org/) as the baseline. Version
levels describe compatibility and user-visible impact, not implementation
effort or the number of changed files.

## Format

```
MAJOR.MINOR.PATCH
```

| Level | When to bump | Example |
|---|---|---|
| MAJOR | Backward-incompatible user contract change, or an explicitly declared new product generation | `1.6.3` → `2.0.0` |
| MINOR | Backward-compatible capability or significant product improvement | `1.0.7` → `1.1.0` |
| PATCH | Backward-compatible bug, security, performance, compatibility or dependency fix | `1.0.0` → `1.0.1` |

When MAJOR increases, MINOR and PATCH reset to zero. When MINOR increases,
PATCH resets to zero. For example, the feature release after `1.0.7` is
`1.1.0`, not `1.1.7`.

If a release contains changes from more than one level, the highest applicable
level wins:

- breaking change + feature + fixes: MAJOR;
- feature + fixes: MINOR;
- fixes only: PATCH.

A release does not need a minimum number of changes. One important
backward-compatible feature can justify a MINOR release, and one urgent fix can
justify a PATCH release.

## Compatibility Contract

For LeanTTY, compatibility is evaluated against the user-facing and published
contract:

- supported product and platform scope;
- persisted settings and user data, including automatic migration;
- documented commands, shortcuts and core terminal interactions;
- documented SSH, configuration and terminal behavior;
- any external interface or data format explicitly published as supported.

Removing or changing an established command, dropping a supported environment,
or requiring users to discard configuration or data is normally a MAJOR
change. Deprecating a capability while keeping it working is a MINOR change;
removing it later is a MAJOR change.

Private ArkTS, Rust, N-API and WebView bridge boundaries, code organization and
other internal implementation details are not part of the compatibility
contract unless they are explicitly published as supported interfaces. A
renderer replacement or architecture rewrite is therefore not automatically a
MAJOR release:

- if user data, behavior and compatibility remain intact, it is normally a
  MINOR release when the improvement merits its own release;
- if it removes important behavior, breaks compatibility or defines a
  deliberately new product generation, it is a MAJOR release;
- a refactor with no independently releasable user impact does not determine
  the version level by itself.

## Change Classification

### MAJOR

Use MAJOR for backward-incompatible changes to the compatibility contract. The
release notes must identify what changed, who is affected and whether migration
is possible. A deliberately declared new product generation may also use
MAJOR, but internal change alone is insufficient.

### MINOR

Use MINOR for backward-compatible features and significant product
improvements. A MINOR release may also contain PATCH-level fixes. Marking an
existing capability as deprecated also requires at least a MINOR release.

### PATCH

Use PATCH when the release contains only backward-compatible fixes. This
includes reliability, security, performance and compatibility corrections, as
well as dependency updates made solely to correct such problems. A security
fix that breaks the compatibility contract still requires a MAJOR release.

Dependency upgrades are classified by their effect on LeanTTY, not by the
dependency's own version number. A major xterm or russh upgrade does not by
itself require a LeanTTY MAJOR release.

## Pre-release Identifiers

When a release needs public or controlled preview builds, append a SemVer
pre-release identifier:

| Version | Meaning |
|---|---|
| `1.1.0-alpha.1` | Early incomplete preview |
| `1.1.0-beta.1` | Feature-complete preview under validation |
| `1.1.0-rc.1` | Release candidate |
| `1.1.0` | Stable release |

Pre-release versions have lower precedence than the matching stable version.
Build metadata such as `1.1.0-rc.1+sha.abcdef0` may identify a build, but it
does not change version precedence.

The former product identity submitted `1.0.0` directly to AppGallery without a public
release-candidate version. The submission was rejected and never published to
users. This does not prevent later releases from using pre-release identifiers
when they are useful.

## Historical Development Versions

Before 1.0.0, development releases used `0.x.y` and could include breaking
changes.

| Version | Meaning |
|---|---|
| `0.1.0` | Initial development |
| `0.2.0` | SSH password auth + basic terminal |
| `0.3.0` | Key auth, key management, config |
| `0.4.0` | Tab system, themes, UI components |
| `0.5.0` | Split pane, Toolbar, interaction stabilization |
| `0.9.0` | Feature complete, stabilization |
| `1.0.0` | First stable AppGallery submission; rejected and not published |

Because `1.0.0` was never distributed, `1.0.1` may replace the application
identity once without preserving the rejected Bundle, preferences or SSH file
markers. This exception does not establish a general right to break
compatibility after LeanTTY is published.

## Release Rules

- A release package must be built from an exact commit already pushed to
  `wandcs/leantty`; local-only source is never a release input.
- Any code, dependency, resource, version or packaging change requires a new
  pushed commit and a new clean build from the isolated release checkout.
- Once a version is released, its source and artifacts must not be replaced.
  Any modification requires a new version.
- A published GitHub Release is the canonical version identity. AppGallery
  submission and review status are recorded against that version but do not
  redefine or roll it back.
- Reliability fixes after `1.0.0` use patch versions such as `1.0.1`.
- Backward-compatible product capabilities use a minor version such as
  `1.1.0`.

## Development and Branch Workflow

LeanTTY uses a protected-main, short-lived-branch workflow. `main` is the
single integration branch for the next planned stable release and should remain
tested and releasable.

- Code, dependency, resource and release-document changes are developed on
  focused topic branches and merged through pull requests.
- Every merged change intended for users is recorded under `Unreleased` or the
  selected target version's `In development` section, following the changelog
  workflow below.
- An AppGallery review in progress does not by itself require a long-lived
  release branch. The submitted package is frozen by its exact pushed commit,
  manifest, artifact hashes and immutable signed tag.
- While `main` contains only backward-compatible fixes after a stable release,
  it is the integration line for the next PATCH release. A higher-version
  feature must not be merged into that line before the PATCH release is frozen.
- A `release/X.Y.Z` branch is created only for release preparation. It accepts
  version metadata and release-blocking fixes only, never new product scope.
- After the verified tag is pushed and the matching GitHub Release is
  published, the release branch may be deleted. The immutable release, tag,
  commit and archived build evidence remain the submission identity.

The default is to publish and submit the current release before merging work
for the next higher version. After its GitHub Release is published and the same
version is submitted to AppGallery, `main` may advance. If review later fails,
create the next PATCH release from the appropriate published tag or current
compatible `main`, apply and verify the required changes, and forward-port them
wherever needed.

## Changelog Workflow

`CHANGELOG.md` describes released and pending user-visible changes:

1. Before a target version is selected, add entries below `Unreleased`.
2. Once the next target version is selected and its version sources are
   advanced, move its pending entries to `[X.Y.Z] - In development` and keep a
   new empty `Unreleased` section above it.
3. Add later changes intended for that same target to its `In development`
   section. Reserve `Unreleased` for work not yet assigned to that version.
4. At release preparation, replace `In development` with `YYYY-MM-DD`.
5. Do not mix changes for a higher MINOR or MAJOR release into a pending PATCH
   section.
6. If a change is dropped before release, remove its pending entry rather than
   documenting behavior that was never published.
7. Once the GitHub Release is published, retain its dated version section even
   if AppGallery later rejects the submission. Record the store result as
   `GitHub Release published; AppGallery review rejected` where release status
   is tracked; do not describe the version as unpublished.
8. Release notes for the next version summarize user-visible changes since the
   preceding GitHub Release. Changes required by an AppGallery rejection are
   recorded under the new version that will replace it in the store.

## Store Review and Release Identity

For an update release, complete development and validation while the previous
version is under review, but do not submit its successor until that review
reaches a terminal result. Normally the previous version is `Released`. If the
review fails for any reason, the next PATCH version replaces it in AppGallery.

The release lifecycle is:

1. Prepare the target version on a release branch and merge it to `main`
   through a reviewed pull request.
2. Push and record the exact release commit.
3. Build, production-sign and verify that commit from the isolated clean
   release checkout described in [`release-process.md`](release-process.md).
4. Create and push the immutable signed `vX.Y.Z` tag on the verified commit.
   Confirm that it matches the commit and artifacts recorded by the build
   manifest.
5. Publish the non-draft GitHub Release on that tag and verify its commit and
   archived release assets. Publication consumes the version number.
6. Only after the GitHub Release is complete, submit the same-version signed APP
   and record the AppGallery submission against the release, tag, commit,
   manifest and artifact hashes.
7. If review succeeds, record the AppGallery state as `Released`; the existing
   GitHub Release remains unchanged.
8. If review fails for any reason, including store listing, screenshot,
   qualification or other external metadata, keep the failed version's release,
   tag and artifacts immutable. Advance to the next PATCH version, increase
   `versionCode`, and repeat the full lifecycle with a new commit, build, tag,
   GitHub Release and AppGallery submission.

A previously selected but unpublished development version does not consume a
version number. Once its GitHub Release is published, that version is consumed
regardless of its later AppGallery result. For example, if published `1.1.0`
fails review, the replacement is `1.1.1`, even when only store metadata must
change.

A published GitHub Release identifies one exact version and its submission
package whether AppGallery review succeeds or fails. It is the primary public
version identity and must exist before the matching AppGallery submission. Its
tag, artifacts and version number are never moved, replaced or reused.

## Version Sources

| Component | Config File | Current |
|---|---|---|
| App (HAP) | `AppScope/app.json5` | `1.4.0` |
| Native crate | `leantty_ssh/Cargo.toml` | `1.4.0` |
| Core crate | `leantty_ssh/leantty-ssh-core/Cargo.toml` | `1.4.0` |
| OHPM | `entry/oh-package.json5` | `1.4.0` |
| Native OHPM | `entry/src/main/cpp/types/libleantty_ssh/oh-package.json5` | `1.4.0` |
| Root OHPM | `oh-package.json5` | `1.4.0` |
| Release artifact name | `tools/build-all.ps1` | Derived from `AppScope/app.json5` unless explicitly supplied |

All semantic version sources must stay aligned. The build script does not own
another version value: formal release builds supply `-ReleaseId`, then fail
before compiling if it differs from any version source.

`AppScope/app.json5` uses:

- `versionName` for the user-visible semantic version;
- numeric `versionCode` as the app-store delivery identifier.

`versionCode` is independent of compatibility classification and must increase
monotonically whenever a newer package supersedes an earlier package. It must
not be used to infer MAJOR, MINOR or PATCH compatibility. The submitted `1.0.0`
package uses `versionCode` `1000000`; the released `1.1.1`, `1.2.0` and `1.3.0`
packages use `1001001`, `1002000` and `1003000`; the current `1.4.0` release
candidate uses `1004000`.
