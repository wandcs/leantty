# Development Environment

| Component | Version | Path |
|---|---|---|
| DevEco Studio | 2026Q2 | `C:\Program Files\Huawei\DevEco Studio` |
| HarmonyOS SDK | API 6.1.1(24) | `sdk/default/openharmony` |
| OHOS NDK Clang | 15.0.4 | `native/llvm/bin/clang.exe` |
| Hvigor | bundled with DevEco | `tools/hvigor/` |
| JBR (Java) | 21.0.x | `jbr/bin/java.exe` |
| WSL | 2 | Desktop-user default distribution |
| Rust | stable 1.96+ for Linux | WSL `rustup` managed |
| Node.js | 18.20.1 | bundled with DevEco |

## Build Targets

| Target | ABI | Notes |
|---|---|---|
| `aarch64-unknown-linux-ohos` | arm64-v8a | Current HarmonyOS PC target |

## Key Dependencies

| Crate | Version | Purpose |
|---|---|---|
| russh | 0.62.5 | SSH client/server (ring backend) |
| mosh-client | 0.0.0 / `e1346b3` | Pinned Git Mosh client dependency |
| tokio | 1.52 | Async runtime |
| napi-ohos | 1.2.0 | N-API bindings |
| xterm.js | 6.0.0 | Terminal emulator |
| hypium | 1.0.25 | Test framework |

## Environment Variables

Required for native build:
- `DEVECO_HOME` — DevEco Studio install dir
- `OHOS_NDK_HOME` — set by `build-native.ps1`
- `LEANTTY_WSL_DISTRO` — optional WSL distribution override; the default
  distribution is used when omitted

Required for HAP build:
- `DEVECO_SDK_HOME` — set by `build-all.ps1`
- `JAVA_HOME` — set by `build-all.ps1`
- `NODE_OPTIONS` — must be empty

## Build and verification workflow

All Rust formatting, tests and compilation run in WSL. `build-native.ps1`
translates repository and SDK paths, invokes WSL Cargo, and calls the Windows
OHOS Clang/LLVM archive executables only through the checked-in WSL wrappers.
Hvigor, signing and HDC remain Windows-side operations.

All repository build, verification, deployment and release-package entry
points share one lock across worktrees belonging to the same Git repository.
Starting another writer waits for the active task instead of cleaning or
rewriting Cargo, Hvigor or HAP outputs concurrently.

Routine feature iterations and bug fixes run only change-related checks plus the
smallest stable main-path smoke checks that finish quickly. Use `dev-pc.ps1`
only when the affected behavior needs a device build, and run only its affected
physical scenario. The complete software suite and physical matrix are not
routine commit gates.

Use the existing software gate with explicit focused groups instead of running
the full suite. For example:

```powershell
.\tools\test-regression.ps1 -Group policy,tooling
```

Available groups are documented in `quality-strategy.md`. When the mapped claim
requires a physical PC, run `.\tools\preflight-device.ps1` after local checks
and before deployment or scenario setup. It stops on Offline, ambiguous targets
or unusable UiTest/layout channels and never repairs or unlocks the device.

`tools/verify-pc.ps1` is reserved for formal release-package preparation. It
requires a clean committed tree and retains its signed test HAP only after the
full gate succeeds.
Candidates are stored outside build output directories under the current
user's local application data, keyed to the Git repository. Retention has one
rule: keep the five most recently verified unique HAPs. There is no age-based
cleanup policy.

For an acceptance-harness-only edit, run the focused non-product gate:

```powershell
.\tools\test-acceptance-harness.ps1
.\tools\verify-ssh-auth-pc.ps1 -Only password-success
```

The second command is diagnostic and never promotes the candidate. During
routine work, stop after the affected scenario and quick main path pass. Run
`verify-ssh-auth-pc.ps1` without `-Only` as part of the applicable formal release
matrix. A retained formal-release HAP may cross a later harness commit only when
the script proves that every intervening file is on its explicit harness/doc
allowlist; product-source or packaging changes require a new release candidate.

Immediately before a formal physical matrix, qualify and freeze the clean
harness against the explicit retained HAP:

```powershell
.\tools\qualify-acceptance-harness-pc.ps1 `
  -ReviewHapPath '<exact retained LeanTTY-test-signed.hap>'
```

This is a small readiness gate, not another product matrix. It reuses
`password-success` to prove ordinary and secret input, semantic layout,
structured logs, the controlled server and cleanup, while the focused software
gate proves release packages reject acceptance-only markers. Any HAP or harness
identity change invalidates its formal record.

Device scenarios publish `live-status.json` while running and final JSON with
candidate/harness identities, attempt lineage, selected stages, failure domain,
resource manifest and cleanup audits. Use those artifacts before rerunning a
failed full matrix.

`build-all.ps1` and `dev-build.ps1` inject acceptance-only ArkTS only around a
debug compilation and restore tracked production files byte-for-byte even when
the build fails. Release compilation skips injection and rejects any HAP that
still contains a registered acceptance marker or helper symbol.

### Dedicated test-PC unlock credential

The dedicated physical regression PC may use one current-user, machine-local
plaintext credential file so unattended acceptance can recover after system
lock:

```text
%LOCALAPPDATA%\LeanTTY\regression\device-unlock-password.txt
```

Store only the password bytes as UTF-8 text. The current keyboard injector
accepts 1-64 lowercase ASCII letters. This file is deliberately outside the
repository and MUST NOT be copied into source, evidence, logs or diagnostic
artifacts. `verify-key-passphrase-pc.ps1` reads it only after HarmonyOS returns
the explicit locked-screen launch error, converts it to numeric physical-key
events and clears the in-process variable after injection. It does not type when
the PC is already unlocked. `-UnlockPasswordPath` may override the location but
is rejected when it resolves inside the repository.

This plaintext exception is limited to the dedicated test PC. Do not configure
it for a personal, production or shared-user device.

After an uninstall, install and launch the latest retained candidate without
rebuilding:

```powershell
.\tools\dev-pc.ps1 -LatestCandidate
```

The candidate manifest records its SHA-256, Git commit/tree, checkout dirty
state, monotonic verification mode and attached local JSON evidence. The
current modes are `software`, `device-deployed` and `device-behavior`; install
and launch alone never claim behavior acceptance. Formal
AppGallery production artifacts remain governed by
[`release-process.md`](release-process.md) and are never added to this
developer candidate store.
