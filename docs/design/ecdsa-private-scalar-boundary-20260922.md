# ECDSA private scalar import boundary

Status: diagnosis confirmed; dependency remediation awaits the maintainer's
compatibility-maintenance decision. This record does not authorize a fork,
vendored dependency, application conversion path, or release exemption.

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
current packaged crate contains 120 files and occupies about 920 KiB; copying
it is a real maintenance cost even if the semantic patch is small.

Alternatives are waiting for an upstream release, or an application-level
normalization path. Waiting delays the candidate; normalization duplicates
private-key parsing and broadens the security-sensitive code. Neither a new
dependency copy nor a normalization branch has been implemented. The maintainer
has been asked to approve the narrow dependency remediation separately from
the already authorized routine PR workflow.

Independently, the verifier should distinguish an absent owned key from a
failed deletion, while continuing to delete and audit any present partial
import. That cleanup repair must not turn the import failure into a pass.
