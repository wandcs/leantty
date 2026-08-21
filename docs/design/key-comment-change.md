# SSH key comment change

> Status: implemented; routine physical validation pending on 2026-08-21
>
> Scope: LeanTTY 1.5 `ssh-keygen -c -f <identity>`

## User outcome and boundary

A user may correct the comment attached to an existing LeanTTY Identity without
generating a replacement key, changing its fingerprint, removing its
passphrase protection or leaving the private and public files with different
metadata.

This is one Identity maintenance action. It does not add key renaming, batch
labels, arbitrary metadata, ECDSA generation, certificate editing or another
key store.

## Standard and library evidence

OpenSSH [`ssh-keygen(1)`](https://github.com/openssh/openssh-portable/blob/master/ssh-keygen.1)
defines `-c` as changing the comment in both the private and public key files,
prompting for the private-key passphrase when needed and then for the new
comment. Its current
[`do_change_comment`](https://github.com/openssh/openssh-portable/blob/master/ssh-keygen.c)
loads the private key, rewrites it with the same passphrase, derives the public
key and saves the same new comment to `.pub`.

LeanTTY's locked `ssh-key` 0.7.0-rc.11 dependency exposes `PrivateKey::comment`,
`PrivateKey::set_comment`, OpenSSH encode/decode, decrypt/encrypt and fingerprint
operations. The current key owner already stores only verified OpenSSH-format
Ed25519/RSA pairs and has a passphrase-change path with a 0600 temporary file,
fsync, identity verification, atomic replacement and durable rollback.

The entry gate therefore passes. No new dependency, key model or storage
authority is required.

## Physical-automation research record

Research refreshed on 2026-08-21 for the question: can the existing HarmonyOS
PC harness safely reuse targeted UiTest text input for the visible comment and
masked passphrase stages, and which observation should decide success?

- Huawei's HarmonyOS V13 UiTest reference documents `Component.inputText` as
  text input for text components.
- The OpenHarmony arkXtest guide defines UiTest as component search and GUI
  operation support. Current upstream event-observer work also records that a
  component text-change event is not reliably emitted by `inputText` in its
  tested branch.

The verifier therefore reuses the established uniquely focused terminal
`inputText` path, injects Enter only once, and does not use a text-change event,
layout text or a fixed delay as the verdict. It requires the acceptance-only
non-content submit marker, then compares the sandbox `.pub` fingerprint/comment
and private-file mode, repeats the comparison after an application restart and
uses the controlled SSH server as the unchanged-passphrase authentication
oracle. The relevant platform sources are the
[HarmonyOS UiTest API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V13/js-apis-uitest-V13),
[OpenHarmony arkXtest guide](https://gitee.com/openharmony/docs/blob/master/en/application-dev/application-test/arkxtest-guidelines.md)
and [upstream event-observer change](https://gitee.com/openharmony/testfwk_arkxtest/pulls/1108).

## Contract

The command is:

```text
ssh-keygen -c -f <identity>
```

Encrypted keys first request the existing passphrase through the masked secret
input path. LeanTTY then shows the old comment and requests one visible new
comment. Empty input removes the comment; spaces and valid UTF-8 are retained.
Carriage returns, line feeds, other control characters and comments over 1023
UTF-8 bytes are rejected. The command does not accept a passphrase or private
key through command-line arguments.

Success must preserve all of these:

- SHA-256 fingerprint and public wire key;
- algorithm and encrypted/unencrypted state;
- the existing passphrase and private-file 0600 protection;
- one matching comment in the private container and `.pub` line;
- the existing key name, paths and durable Identity authority.

An unchanged comment is a successful no-op.

## Commit and recovery model

Rust owns the two-file projection transaction:

1. read and parse the original private and public files;
2. verify their fingerprints match and decrypt only when required;
3. set the comment, restore the same encrypted state, and build both outputs;
4. write 0600 private and public temporary files, flush, fsync and reopen them;
5. verify fingerprint, public wire key, passphrase state and exact comment;
6. replace the pair while retaining rollback copies until both destinations
   are committed; and
7. restore both originals and remove all temporary files on any projection
   failure.

ArkTS then captures the verified pair in the existing durable store. If that
commit fails, it asks the same native transaction to restore the old comment.
The previous durable generation remains authoritative and startup
materialization repairs the projection after an interrupted process. If either
projection rollback or durable recovery cannot be proven, the command reports
failure and does not claim the old/new comment is active.

## Verification scope

- Rust fixtures: Ed25519/RSA, encrypted/unencrypted, empty/space/Unicode
  comments, wrong passphrase, mismatched public key, first/second replacement
  failure, permissions, cleanup and reopen.
- ArkTS fixtures: parser exclusivity, visible comment input, masked passphrase,
  cancellation, no secret logging and durable-failure rollback.
- Physical ARM64 HarmonyOS PC: exact keyboard flow, fingerprint before/after,
  encrypted-key authentication with the unchanged passphrase, application
  restart/reopen and cleanup of the acceptance key pair.

This routine slice will not run the unrelated physical matrix or formal
release-package gate.
