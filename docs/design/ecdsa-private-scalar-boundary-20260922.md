# ECDSA private scalar import boundary

Status: the maintainer approved a local dependency patch on 2026-09-22, with
minimal upgrade interference and low-cost removal after an upstream fix. No
upstream issue/PR is authorized. Physical regression is pending device charging.

## Observed failure

The R4 candidate from PR #225 (`36de654`, HAP `0e1b7878…eb9f5a`) stopped in
`host-identity-default-ecdsa` before any model workload. A newly generated
Windows OpenSSH key reached the application's import command, which returned
`parse private key failed: length invalid`. The verifier then waited for a
success message and attempted to delete a key that had not been created.
Its final result was `invalid/interrupted` because deletion also timed out.

The original random key was removed by the fixture's cleanup. Its exact scalar
encoding is no longer available; do not claim that its bytes were inspected.
The following controlled reproduction establishes a product defect consistent
with the observed error independently of that missing sample.

## Controlled evidence

Three public, deterministic test-only P-256 scalars were serialized as OpenSSH
private keys using the installed Python cryptography 46.0.5. They were kept in
an isolated Linux temporary directory; no user key was read. OpenSSH accepted
all three through `ssh-keygen -y` with public-key output discarded.

| Encoded positive scalar length | OpenSSH | LeanTTY's actual `inspect_private_key` |
| --- | --- | --- |
| 31 bytes | Accept | Reject: `length invalid` |
| 32 bytes | Accept | Accept |
| 33 bytes, including sign byte | Accept | Accept |

The initial probe added an extra trailing PEM newline and failed earlier at
the PEM boundary for every vector. Removing that diagnostic formatting error
gave the comparison above; it was not a product patch or a random-key retry.

The same 31-byte vector was imported on the physical ARM64 PC using the exact
candidate. Source and received-file SHA-256 matched; the application reproduced
`length invalid`. The named diagnostic key was absent before and after, the
temporary import source was removed, and cleanup passed. No SSH connection,
default-key replacement, or model workload was involved.

Local evidence: `build/verification/1.7-release-preparation/ecdsa-boundary/`.
The formal report remains unchanged under
`1.7.0-automatic-bell-20260922/` in the separate release evidence directory.

## Owner and governing contract

`keygen::inspect_private_key` delegates to locked `ssh-key 0.7.0-rc.11`.
`EcdsaPrivateKey::decode` rejects encoded private scalars shorter than 32 bytes.
The upstream file still has this restriction at
[374f764f](https://github.com/RustCrypto/SSH/blob/374f764f57d7e576b2ac348955a9413a8ba40f83/ssh-key/src/private/ecdsa.rs).
[RFC 4251 section 5](https://www.rfc-editor.org/rfc/rfc4251.html#section-5)
requires minimal integer encoding; the curve's nominal size does not require
every positive scalar to occupy that many encoded bytes.

This is bundled-library behavior on supported input, so the quality strategy's
third-party exemption does not apply. Regenerating keys until one passes would
hide the defect. The existing id_ed25519 was restored with private/public/config
comparisons; an independent follow-up found no temporary id_ecdsa/import file,
HDC mapping, fixture directory, WSL fixture account, or test listener.

## Remediation decision

Prefer a narrow dependency-level correction with valid and invalid encoding
tests, keeping the application's import path unchanged. There is no verified
released upstream correction to adopt. A local patch would need pinned source,
license/provenance, a removal condition when upstream fixes it, and targeted
import/authentication/cleanup regression followed by a new R4 candidate. The
published crate contains 119 files totaling about 560 KiB; copying
it is a real maintenance cost even if the semantic patch is small.

Alternatives were waiting for an upstream release, or an application-level
normalization path. Waiting delays the candidate; normalization duplicates
private-key parsing and broadens the security-sensitive code. The approved
implementation uses Cargo's native single-crate override with the complete
published package, one source-file diff, and provenance hashes. There is no
application normalization branch or build-time patch application.

Maintenance and exact removal steps are in
[the patch directory](../../third-party/ssh-key/README.md). Product-owned
encoding/lifecycle tests remain after removing the override. Source policy
checks all package bytes and the resolved lock entry; native builds validate
that provenance and include it in their incremental source identity.

A separate bounded ordinary `ssh-keygen -t ecdsa -b 256` experiment found a
31-byte scalar at generation 937 in 2.55 seconds. OpenSSH could read it while
the original product parser rejected it. No private key was retained. This
establishes a natural standard-generator case, not a frequency estimate and
not inspection of the original failed formal key.

Upstream PRs [351](https://github.com/RustCrypto/SSH/pull/351) and
[356](https://github.com/RustCrypto/SSH/pull/356) addressed undersized P-521 keys
and leading-zero placement, while retaining a 32-byte minimum. At investigation
time both russh 0.62.5 and 0.63.3 pinned ssh-key 0.7.0-rc.11, so upgrading russh
alone would not correct this boundary.

Independently, the verifier should distinguish an absent owned key from a
failed deletion, while continuing to delete and audit any present partial
import. That cleanup repair must not turn the import failure into a pass.

## Physical regression after the patch

On 2026-09-22 the connected ARM64 HarmonyOS PC passed the targeted diagnostic
with HAP SHA-256 `1a89b119d76ea069fe959c70fa3cfc397f13aeac9319c4fb5864276077f13b39`.
The host-identity verifier retained its actual import, OpenSSH server,
authentication, restart and cleanup checks; an ignored diagnostic copy replaced
only random key generation with the public P-256 scalar 2^246. Its serialized
scalar length was independently asserted to be 31 bytes and OpenSSH read it.
The original verifier, diagnostic copy and generator hashes are retained.

All 11 checks passed: import, exact authorized key, explicit binding, default
identity before/after restart, binding recovery and restoration of the existing
Ed25519 identity. Private-key digest, public fingerprint and Host configuration
matched after restoration. Temporary keys, import sources, account, trust and
mapping were removed, and the original Downloads permission was restored.

The existing `ecdsa-import-encrypted-and-restart` diagnostic also passed:
incorrect passphrase rejected, correct authentication before/after restart,
unchanged identity and Preferences, product deletion and independent absence
audits. Both diagnostic runs report successful cleanup; no model requests ran.

The first fixed-vector attempt stopped before import because Linux OpenSSH saw
the Windows-mounted temporary file as mode 0777. Its cleanup passed and its
failed report is preserved. The same fixture passed the offline OpenSSH check
in a Linux temporary directory with mode 0600 before the second device attempt.
This corrected only the disposable diagnostic generator, not product code or
the frozen formal harness. Evidence lives under
`build/verification/1.7-release-preparation/ecdsa-boundary/` in
`fixed31-device`, `fixed31-device-r2` and `encrypted-device`.

This closes the change-scoped regression, not formal release acceptance. The
old failed candidate/report remain unchanged; a new formal candidate is still
required under the existing release plan.
