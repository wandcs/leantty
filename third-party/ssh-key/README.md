# Temporary ssh-key correction

The maintainer approved this local patch on 2026-09-22. Do not open an upstream
issue or PR for it. This directory is a removable dependency override, not a
fork with a separate feature roadmap.

`ssh-key-0.7.0-rc.11/` is the complete published crate, including its MIT and
Apache-2.0 licenses and public upstream test vectors. `provenance.json` records
the registry archive URL/checksum, upstream Git commit and every original file
hash. Only `src/private/ecdsa.rs` differs; `positive-scalar.patch` records that
diff, and the manifest records its resulting hash. Preserve upstream bytes;
do not format, refactor or apply unrelated fixes inside this directory.

The decoder accepts nonzero positive integers shorter than the curve width,
left-pads their existing fixed-size storage, and rejects empty, zero, negative,
oversized and truncated encodings. Existing fixed-width encodings (including
leading zero padding produced by this library) remain accepted. Scalar range
and signing validation remain with the existing cryptographic implementation.
The application does not gain another parser or a conversion path.

Cargo's workspace-root `[patch.crates-io]` selects this one crate for all
transitive callers. No build-time download, source rewriting, global Cargo
cache modification, new crate version or russh fork is required. Normal Cargo
commands continue to work. Source policy checks every vendored byte and rejects
a lockfile that silently switches to another ssh-key source/version.

## Upgrade

1. Try the intended upstream version without the override in an isolated
   development branch. Let russh's actual constraints select a compatible
   version; upgrading russh alone does not imply a parser fix.
2. Run the retained product regression:
   `cargo test --locked --manifest-path leantty_ssh/Cargo.toml -p leantty-ssh-core`.
   In particular, `tests/ecdsa_scalar.rs` is independent of this directory.
3. If the upstream decoder passes the supported encoding and lifecycle cases,
   remove this patch as below. Otherwise replace the package from its official
   archive after checking the registry checksum, review the small diff against
   the new decoder, and regenerate original/patched hashes. Never blindly copy
   the old patched source over the new release. Confirm that only the intended
   file differs and the diff applies to the exact original archive.
4. Run `tools/check-public-source.ps1`, the affected Rust checks, and the named
   physical ECDSA import/authentication check. Update the version-specific
   public-example scanner exceptions only when replacing the verified package.

## Remove after an upstream fix

Delete the workspace's `ssh-key` patch entry, this entire directory,
`tools/check-ssh-key-patch.ps1`, `tools/test-ssh-key-patch.ps1` and its call in
`test-native-build-inputs.ps1`, the call and verified-example exception in
`check-public-source.ps1`, its build-time call/provenance hash input in
`build-native.ps1`, and the scoped entries in `.gitattributes` and
`.gitleaks.toml`. Update `Cargo.lock` to the fixed registry dependency.
Keep the product encoding/lifecycle regressions and changelog. No production
Rust or ArkTS call sites need to change. Run affected checks and the physical
ECDSA scenario against the resulting build before accepting the upgrade.

See [diagnosis](../../docs/design/ecdsa-private-scalar-boundary-20260922.md).
