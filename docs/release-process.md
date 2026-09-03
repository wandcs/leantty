# Release Process

This file describes the release procedure, not current task status. Outstanding
release work is tracked only in [`next-work.md`](next-work.md).

## Source Authority and Workspaces

Every release is built from source already pushed to
[`wandcs/leantty`](https://github.com/wandcs/leantty). Local-only commits,
uncommitted files and development build outputs are never release inputs.

Use two independent Git clones, plus an optional third clone when AppGallery
review evidence requires a directly installable HAP. Choose local paths
appropriate for the maintainer machine:

| Workspace | Example variable | Allowed work |
|---|---|---|
| Development | `$devCheckout` | Edit, test, test-sign, deploy and push verified commits |
| Release | `$releaseCheckout` | Fetch GitHub, check out an exact commit, clean-build, production-sign and archive |
| Review | `$reviewCheckout` | Check out the same exact commit, test-sign, install and capture screenshots/video |

Do not use `git worktree` for the release checkout. Do not edit product source
or create repair commits in the release checkout. If a release build requires a
source change, return to the development checkout, verify the change, push it,
and select the new GitHub commit.

Production certificates, keystores, profiles and passwords remain outside both
repositories. The release checkout may contain an ignored
`signing.local.json5` that references those external materials. Never copy the
development test-signing identity into the production release workflow.

The optional review checkout uses a different ignored `signing.local.json5`
and a test Profile trusted by the target PC. Its HAP is only for device
acceptance and review media. It is not an AppGallery upload artifact. Production
and review builds must have the same commit, tree, version, ABI and native
library hash.

The generated `entry/libs/arm64-v8a/libleantty_ssh.so` is ignored and must
never be tracked. A clean clone rebuilds it from the locked Rust source before
packaging; generated native output must not make the release checkout dirty.

## Select the Release Commit

In the development checkout, finish verification and push the exact source:

```powershell
git status --short
git push origin main
git rev-parse HEAD
```

Record the resulting commit SHA. In the release checkout, fetch GitHub and
detach at that exact SHA:

```powershell
git fetch --prune origin
git checkout --detach <release-commit-sha>
git rev-parse HEAD
git status --short
```

The two `git rev-parse HEAD` values must match and `git status --short` must be
empty. Do not build from an implicitly advancing branch, and do not use
`git pull` as the release identity.

For the first setup only:

```powershell
$releaseCheckout = Join-Path (Split-Path (Get-Location) -Parent) 'leantty-release'
git clone https://github.com/wandcs/leantty.git $releaseCheckout
```

## Release Gate

Before building a release:

- From the clean development checkout, use the thin registered checkpoint entry
  to run `verify-pc.ps1`, qualify the harness and invoke the current named
  scenarios against one unchanged retained HAP:

  ```powershell
  .\tools\verify-release-pc.ps1 `
    -Target '<physical-PC-target>' `
    -EvidenceDirectory 'C:\path\outside\the\repository\release-verification'
  ```

  Its `release-report.json` and `maintainer-summary.md` do not replace the
  referenced stage evidence. The report currently records
  `completeApplicablePhysicalMatrixClaimed=false` because the 1.6 Mosh network
  and lifecycle matrix still needs formal retained-candidate evidence. Do not
  advance to C4 while that flag is false.
- Before the first formal behavior matrix, qualify the clean harness against
  that exact retained review-test HAP. The entry runs this command; the
  lower-level form remains available for diagnosis:

  ```powershell
  .\tools\qualify-acceptance-harness-pc.ps1 `
    -ReviewHapPath '<exact retained LeanTTY-test-signed.hap>'
  ```

  Continue only when `harness-qualification.json` records `runMode=formal`,
  `result=passed` and `releaseEligible=true`. Record that file with the physical
  report. A diagnostic qualification or a record whose candidate HAP or harness
  identity changed cannot authorize the matrix.
- Confirm the trusted ArkTS suite and Rust `fmt --check` pass.
- Use the clean ARM64 cross-build as the native integration gate. Rust
  formatting, tests and compilation run in WSL; Windows supplies the DevEco
  packaging tools and OHOS target linker, not the Rust host toolchain.
- Confirm the release checkout is detached at the recorded GitHub commit and
  has no tracked modifications.
- Update CHANGELOG with the release date.
- Regenerate the packaged `LeanTTY-User-Guide.html` from the finalized target
  version section in `CHANGELOG.md` and the current user-visible contract. The
  Chinese default and complete English version must describe exactly the
  behavior entering this release: add newly delivered workflows, revise changed
  interactions and remove or clearly exclude anything not shipped. Do not turn
  the Changelog into release notes inside the guide; use it as the mandatory
  delta checklist for rebuilding the task-oriented guide.
- After regeneration, perform a separate natural-Chinese editorial pass as
  defined by `design/offline-user-guide.md`. Review the Chinese opening,
  task steps, recovery guidance and every changed feature section in the
  browser; do not treat bilingual fact parity or automated HTML checks as a
  substitute for this pass. Copy the reviewed source to the packaged resource
  only after the pass is complete, then verify both files are byte-identical.
- Update every version source defined by [`versioning.md`](versioning.md).

User Guide regeneration is release-source work. Complete and review it in the
development checkout on the `release/X.Y.Z` branch, commit it with the other
release-document changes, merge and push it before selecting the release
commit. The detached production and review checkouts consume the identical HTML
from that commit and must not regenerate or edit it locally. Any later
user-visible Changelog change or User Guide byte change invalidates the retained
candidate and requires a new pushed release commit and clean formal build. The
guide-specific content, offline and bilingual checks are defined in
[`design/offline-user-guide.md`](design/offline-user-guide.md).

LeanTTY publishes stable versions directly. Any code, dependency, resource,
version or packaging change requires a new pushed commit and a new clean build
from the release checkout.

Prepare the version metadata on a `release/X.Y.Z` branch and merge it to `main`
through a pull request. The exact pushed `main` commit after that merge is the
release commit. Do not merge work for the next higher version until that commit
has passed production verification, been tagged and been submitted. After that,
`main` may advance; the immutable tag is the recovery anchor described by
[`versioning.md`](versioning.md).

## Build

The recommended formal path is one command from the detached production
release checkout:

```powershell
.\tools\prepare-appgallery-release.ps1 `
  -ReleaseId 'X.Y.Z' `
  -ExpectedCommit '<release-commit-sha>' `
  -ReleaseRoot 'C:\path\to\LeanTTY-release' `
  -ReviewCheckout 'C:\path\to\LeanTTY-review' `
  -AppGalleryCopyPath '.\docs\release\X.Y.Z-appgallery.md'
```

The command performs both release preflights before compiling, builds and
verifies both checkouts, compares their source/native identity, and archives
the production upload APP separately from the review-test HAP. Before any tag
is created it also prepares the license ZIP, GitHub Release notes, reviewed
AppGallery copy, handoff checklist and attachment hashes. These files are
reversible outputs; their presence does not authorize tagging or publishing. Omit
`-ReviewCheckout` only when no device/media build is required. `-SkipBuild`
may archive existing outputs after the same manifest and hash checks; it does
not weaken validation. If only one build needs recovery, use
`-SkipProductionBuild` or `-SkipReviewBuild` so the already successful build
is verified and reused instead of rebuilt.

The lower-level production build remains available from the release checkout:

```powershell
$releaseId = 'X.Y.Z'
.\tools\build-all.ps1 -Clean -BuildMode release -Metadata -ReleaseId $releaseId
```

Before a formal build starts, `build-all.ps1` now requires:

- a clean detached checkout whose commit is contained by a fetched `origin`
  ref;
- exact agreement between `-ReleaseId` and every semantic version source;
- an ignored signing configuration with all required fields;
- absolute certificate, Profile and keystore paths outside the checkout;
- encrypted key and keystore password values, without printing them.

Use `-PreflightOnly` with `-Metadata -BuildMode release` to run these cheap
checks without compiling.

This generates named ARM64 release artifacts:

- `build/outputs/release/LeanTTY-X.Y.Z-arm64-v8a-unsigned.hap`
- `build/outputs/release/LeanTTY-X.Y.Z-arm64-v8a-signed.hap` when production
  signing is configured
- `build/outputs/release/LeanTTY-X.Y.Z-arm64-v8a-unsigned.app`
- `build/outputs/release/LeanTTY-X.Y.Z-arm64-v8a-signed.app` when production
  signing is configured; this is the AppGallery upload artifact
- `build/outputs/release/licenses/` with the project license, third-party
  notice, complete Rust dependency inventory, OFL text, and package-specific
  Rust license files plus their generated index
- `build/outputs/metadata/build-manifest.json`

The build fails if the HAP contains an ABI other than `arm64-v8a`.

The formal archive records the roles explicitly:

| Artifact | Role |
|---|---|
| `LeanTTY-X.Y.Z-arm64-v8a-signed.app` | The only application package uploaded to AppGallery |
| Production `LeanTTY-X.Y.Z-arm64-v8a-signed.hap` | Signature and package-identity evidence; not an HDC install target |
| `LeanTTY-X.Y.Z-review-test-signed.hap` | Physical-PC acceptance, screenshots and self-test video only; never upload |

## Verify Manifest

Check `build-manifest.json` contains:

- stable release identifier
- the exact GitHub commit hash
- ARM64 `.so` SHA-256
- build mode and ARM64 ABI
- unsigned and signed HAP paths and SHA-256 values
- unsigned and signed APP paths and SHA-256 values
- successful HAP and APP digest/signature verification records
- `dirty=false`
- timestamp

After the build, confirm the checkout is still unchanged:

```powershell
git diff --exit-code
git status --short
```

## Signing

1. Keep signing certificates, keystores and passwords outside the repositories;
   do not add `signingConfigs` secrets to `build-profile.json5`.
2. Put the single production `signingConfigs` entry in the ignored
   `signing.local.json5` in the release checkout. The build script injects it
   only for the Hvigor process and restores the tracked profile byte-for-byte.
   Let DevEco Studio generate the encrypted `keyPassword` and `storePassword`
   values. Plain-text passwords are not accepted by the formal preflight.
3. Build the ARM64 release product with the stable release identifier.
4. Verify the HAP signing block with DevEco's signing tool:

   ```powershell
   java -jar "<DevEco SDK>\default\openharmony\toolchains\lib\hap-sign-tool.jar" `
     verify-app `
     -inFile "build\outputs\release\LeanTTY-X.Y.Z-arm64-v8a-signed.hap" `
     -outCertChain "build\outputs\metadata\signing-cert-chain.cer" `
     -outProfile "build\outputs\metadata\signing-profile.p7b"
   ```

   Success requires both `Digest verify result: true` and
   `verify-app success`. `keytool -printcert -jarfile` is not a valid HAP
   signature check.

## Known Failure Boundaries

| Symptom | Cause | Required response |
|---|---|---|
| HDC error `9568322`, signature verification failed, untrusted app source | The production AppGallery Profile is not trusted for direct test-PC installation | Keep the production APP/HAP unchanged; build the same commit in the review checkout with the trusted test Profile |
| Hvigor rejects the key or keystore password | Plain text or incompatible encrypted password material was placed in `signing.local.json5` | Regenerate the encrypted fields with DevEco Studio; never copy or print the clear-text password |
| Build starts and later reveals a wrong version or dirty source | Release identity was not checked before expensive compilation | Run the formal command or `build-all.ps1 ... -PreflightOnly`; do not bypass the preflight |
| Production and review HAPs cannot be confidently compared | They were built from different commits, trees, versions, ABIs or native outputs | Discard the review evidence and rebuild both through the formal command |
| It is unclear which HAP/APP to submit or install | Artifact roles were carried only in operator notes | Read the archived `artifact-roles.txt`; upload only the production signed APP |
| A formal physical matrix has no passing harness qualification, or the HAP/harness identity changed after qualification | Control and observation validity was assumed instead of frozen | Stop before the next C3 stage and rerun `qualify-acceptance-harness-pc.ps1` against the exact retained review-test HAP; never promote a diagnostic record |
| GPG tag creation succeeds but verification cannot find the key or uses a different backend | Creation and verification resolved different `gpg.exe` programs/keyrings | Use `sign-release-tag.ps1`; it resolves Git's effective OpenPGP executable once and pins that same executable for both operations. Do not create another key or change the Git/global GPG configuration as a workaround |
| A production HAP reaches an HDC install command | A generic candidate/HAP parameter hid the production/review artifact role | Stop before device setup and select the matching `review-test` or retained verified test HAP; the production release-Profile HAP remains identity evidence only |

## Publish the GitHub Release and Prepare the AppGallery Handoff

AppGallery submission is a maintainer-only operation. Codex and other project
automation must not open the Huawei developer or AppGallery website, sign in to
the maintainer account, upload artifacts, edit the store listing, or submit a
version for review. Their responsibility ends after producing and verifying the
exact upload artifact, checksums, store materials and handoff checklist. The
maintainer performs the website submission personally and reports the resulting
state back to the project for recording.

Only after the exact release artifact passes the final real-PC smoke test:

1. Confirm the previous AppGallery review is no longer in progress. Normally
   it is `Released`; if it was rejected and this APP supersedes it, record the
   rejection and replacement relationship.
2. Confirm the release commit and signed APP/HAP hashes match
   `build-manifest.json`.
3. Create and locally verify an immutable signed tag on the verified commit,
   supplying the existing local passphrase file outside the repository:

   ```powershell
   .\tools\sign-release-tag.ps1 `
     -Tag 'vX.Y.Z' `
     -Commit '<release-commit-sha>' `
     -PassphrasePath '<local PGP passphrase file>'
   ```

   The helper does not create keys, alter Git/GPG configuration or push. It
   resolves Git's effective OpenPGP program once and pins the same executable
   for creation and verification so both operations use the same keyring.
4. Reconfirm the locally verified tag resolves to the commit recorded by
   `build-manifest.json`, then push it: `git push origin vX.Y.Z`.
5. Publish the non-draft GitHub Release on that tag. Attach
   `build-manifest.json`, the prepared license ZIP and the SHA-256 checksum file;
   use the prepared Release notes. Then verify
   the release points to the expected tag and commit and exposes the archived
   assets. The GitHub Release is the canonical version identity and consumes
   the version number.
6. Only after the GitHub Release is complete, hand the maintainer the
   same-version production signed APP, its SHA-256 value, the store materials
   and the submission checklist. Do not attempt to install its release-Profile
   HAP with HDC. Use only the separately test-signed review HAP from the same
   commit/tree/native build for direct installation, final device acceptance,
   screenshots and self-test video.
7. The maintainer personally verifies the APP filename and SHA-256 value,
   uploads the production signed APP and store materials on AppGallery, and
   submits the version for review.
8. After the maintainer reports the result, record the submitted version,
   GitHub Release, tag, exact commit, build manifest, artifact hashes and
   AppGallery submission state. Do not infer submission success from prepared
   local materials or an open browser page.

After both the GitHub Release and maintainer handoff facts exist, generate one
post-release record with `prepare-release-status-update.ps1`. Commit that
record and all matching current-status documentation in one status pull
request. Do not open a GitHub-only status PR followed by a second adjacent PR
for the handoff state.

If AppGallery review fails for any reason, including store listing text,
screenshots, qualifications or metadata outside the APP, the published GitHub
version is still consumed. Keep its release, tag and evidence immutable. Return
to the development checkout, advance to the next PATCH version, increase
`versionCode`, apply the smallest required correction, and repeat the entire
release process with a new pushed commit, clean build, signed tag and GitHub
Release before submitting the new version. Never replace or resubmit artifacts
under the failed version.

An unpublished development target does not consume a version. Publication of
the GitHub Release is the boundary: after `1.1.0` is published, any failed
AppGallery review is followed by `1.1.1`.

## Record an Approved AppGallery Release

Only after the maintainer confirms that AppGallery reports the submitted
version as `Released`:

1. Confirm the approved APP hash, existing signed tag and recorded release
   commit.
2. Confirm the already-published GitHub Release still points to that tag and
   commit; do not replace its assets.
3. Record the AppGallery `Released` state and approval mapping in the release
   archive, then update current-status documentation in the same status pull
   request when that state is part of the original maintainer handoff; otherwise
   use one later approval-status pull request because the fact did not yet exist.

Never move or reuse a pushed version tag or published GitHub Release, including
one whose AppGallery submission was rejected.

## Checksum Verification

```powershell
Get-FileHash -Algorithm SHA256 `
  build\outputs\release\LeanTTY-X.Y.Z-arm64-v8a-signed.app,
  build\outputs\release\LeanTTY-X.Y.Z-arm64-v8a-signed.hap,
  entry\libs\arm64-v8a\libleantty_ssh.so,
  build\outputs\metadata\build-manifest.json
```
