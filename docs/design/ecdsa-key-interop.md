# ECDSA key interoperability

> Status: Verified; LeanTTY 1.5 imported-identity slice closed
>
> Scope: LeanTTY 1.5 import and use of existing OpenSSH ECDSA identities

## User outcome and boundary

A user migrating an existing OpenSSH environment should not have to generate a
replacement identity only because the selected private key is a standard ECDSA
key. If the entry gate passes, LeanTTY will import and use that key through the
same single durable Identity, host verification, authentication, cancellation
and recovery paths as Ed25519 and RSA.

This candidate does not add ECDSA generation, security-key/FIDO identities,
PKCS#11, certificates, CA management, algorithm downgrade controls or another
key store. Ed25519 remains the preferred new-key default. A partial parser-only
or list-only result is not an interoperable Identity.

## Entry gate

The implementation may proceed only when all of these are demonstrated with
the currently locked dependencies and no new cryptographic provider:

1. OpenSSH-generated `ecdsa-sha2-nistp256`, `ecdsa-sha2-nistp384` and
   `ecdsa-sha2-nistp521` private/public pairs parse with and without a
   passphrase, retain their exact public identity and expose a stable SHA-256
   fingerprint.
2. `ssh-key` and russh can decrypt, re-encode and authenticate those keys using
   the existing `PrivateKey` and `authenticate_publickey` paths on the host test
   boundary.
3. The ARM64 OHOS native build retains the same algorithm support without a new
   dependency, unsafe fallback or platform-specific key representation.
4. Supporting an imported ECDSA Identity can reuse the existing durable asset,
   masked passphrase, rollback and cleanup owners rather than creating a second
   algorithm-specific lifecycle.

If any standard curve cannot be represented honestly, encrypted OpenSSH keys
cannot round-trip safely, target authentication is unstable, or support needs a
new long-lived crypto/platform abstraction, the candidate is cut from 1.5.

## Conditional implementation contract

If the gate passes, an imported ECDSA Identity must participate in the existing
applicable lifecycle:

- `key import/list/export/rm` and durable restart/reopen;
- `ssh-keygen -y/-l/-p/-c` without changing the public key or weakening private
  key protection;
- `ssh-copy-id` and the common direct/ProxyJump public-key authentication path;
- SSH-backed `put/get`, which reuses the same authentication owner; and
- rejection, cancellation, wrong-passphrase, rollback and independent cleanup
  behavior already required of Ed25519/RSA.

Generation remains limited to Ed25519/RSA. Help and user guidance must name
ECDSA as an imported identity type, not as a newly generated key option.

## Verification boundary

- L0/L1: public-source policy; OpenSSH fixtures for three curves; Rust key
  inspection, fingerprint, passphrase/comment and authentication tests; ArkTS
  parser, asset and durable-state tests.
- L2: N-API integration, controlled SSH fixture and clean signed ARM64 debug
  HAP build.
- L3: one named physical ARM64 HarmonyOS PC scenario covering encrypted ECDSA
  import, wrong/correct passphrase, controlled-server authentication,
  restart/reopen and product-owned deletion with an independent absence audit.

The routine slice does not run the unrelated physical matrix or formal
release-package gate.

## Entry-gate result

The bounded gate passed on 2026-08-22 without changing the locked dependency
graph:

- OpenSSH generated unencrypted and encrypted P-256, P-384 and P-521 fixtures;
  locked `ssh-key`/russh parsed, decrypted and re-encoded all six while retaining
  the public wire identity and SHA-256 fingerprint.
- A repository-only russh server accepted a generated key from each curve
  through the same `authenticate_publickey` call used by LeanTTY.
- The locked `ssh-key 0.7.0-rc.11` feature tree already enables `ecdsa`, `p256`,
  `p384` and `p521` through russh; no provider, dependency or fallback was added.
- The owner audit found one algorithm whitelist at private-key inspection and
  one ArkTS display/mapping boundary. Import, projection, durable capture,
  passphrase/comment transactions, direct/ProxyJump authentication,
  `ssh-copy-id`, `put/get`, export and deletion already converge on the common
  `KeyPairInfo` and private-key path.

Implementation therefore expands only the exact inspection/mapping whitelist
and reuses the current lifecycle. The ARM64 build and named physical scenario
passed without reopening the product boundary.

## Physical-harness research record

Before changing the device harness, the OpenHarmony HDC guide was checked for
the bundle-scoped `hdc file send -b <bundle> <local> <sandbox-path>` boundary,
and the HarmonyOS user-directory sample was checked for application access to
the Downloads directory. The named scenario uses bundle-scoped HDC transfer to
place one runtime-generated encrypted fixture inside LeanTTY's own sandbox,
then drives the public `key import` command through the normal terminal input
path. It does not add a test-only product import API or bypass the product-owned
copy, protection, durable capture and deletion paths.

On the test PC, bundle-scoped transfer requires the complete application alias
`/data/storage/el2/base/haps/entry/files/<name>`. HDC can print `[Fail]` while
returning process exit code zero, so the harness also requires the explicit
`FileTransfer finish` response and a non-empty `stat` result before submitting
the product command. This prevents a missing fixture from being misclassified
as an ECDSA parser failure.

Sources checked on 2026-08-22:

- OpenHarmony HDC guide:
  <https://api.gitee.com/openharmony/docs/blob/master/zh-cn/device-dev/subsystems/subsys-toolchain-hdc-guide.md>
- OpenHarmony basic HDC guide:
  <https://gitee.com/openharmony/docs/blob/4f4570e7b3581c71e5f1a40367b1c2bde9a3616b/zh-cn/application-dev/dfx/hdc.md>
- HarmonyOS user-directory sample:
  <https://gitee.com/harmonyos_samples/GeneratingUserDirectoryEnvironmentFile/blob/master/README.en.md>

## Verification result

The completed slice passed:

- Rust formatting plus two three-curve inspection/passphrase/comment tests and
  one three-curve controlled-server authentication test;
- the mapped policy/tooling/ArkTS group, including 153 ArkTS tests;
- a signed ARM64 debug HAP build containing the locked P-256/P-384/P-521 stack;
  and
- `ecdsa-import-encrypted-and-restart` on the physical ARM64 HAD-W32 PC.

The physical diagnostic imported an encrypted P-256 OpenSSH key, rejected a
wrong passphrase, authenticated to the controlled server before and after an
application restart, retained the same SHA-256 fingerprint and 0600 private
mode, then passed product deletion plus independent key/source absence audits.
Its HAP SHA-256 was
`44ec1c8d6a1bfce0b536fd5776eece398c435f29d3501e8bd30d8a34b0eaecb1`.
This is development diagnostic evidence, not a retained formal release
candidate or AppGallery delivery claim.
