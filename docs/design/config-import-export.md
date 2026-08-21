# Controlled OpenSSH config import/export

> Status: implementation and physical-device acceptance in progress
>
> Scope: LeanTTY 1.5 controlled migration into the single `~/.ssh/config`

## User outcome and boundary

A user may bring one existing OpenSSH config into LeanTTY from the already
authorized Downloads boundary, keep its original text intact while LeanTTY
later manages its own Host section, and export the resulting canonical config
without overwriting another Downloads file.

This does not add `ssh -F`, a second Host database, a generic file manager,
directory watching, background synchronization or cloud storage. Import is a
one-time migration into the existing config owner, not a way to switch active
profiles.

## OpenSSH semantics and sample classification

The baseline is the upstream OpenSSH [`ssh_config(5)`](https://github.com/openssh/openssh-portable/blob/master/ssh_config.5):
configuration is evaluated in source order, the first obtained value normally
wins, `Host` patterns may repeat and use wildcards/negation, and `Include`,
`Match` and token expansion can change which configuration is effective.

Executable fixtures live in
`entry/src/test/fixtures/ssh-config/SshConfigFixtures.ets` and cover LF/CRLF,
comments, whitespace, repeated concrete Host patterns, wildcards, negation,
non-default ports, `ProxyJump`, every supported directive, an unknown
directive, `Include`, `Match` and `%h` expansion.

| Class | Input | Contract |
| --- | --- | --- |
| Connection-critical and supported | `Host`, `HostName`, `User`, `Port`, `IdentityFile`, `ProxyJump`, `ConnectTimeout`, `ServerAliveInterval`, `ServerAliveCountMax` | Parse with current first-value behavior; malformed values fail before a connection |
| Preserve exactly | Comments, blank lines, indentation, line endings, repeated Host patterns, wildcards and unknown directives | Import/export and later managed `host add|set|rm` retain the source bytes; a matching unknown directive still blocks connection with its name and line number |
| Reject at import | `Include`, `Match`, supported-value token/environment expansion, quoted supported values, control characters and LeanTTY managed markers | Do not accept source whose effective authority or value cannot be reproduced locally |

LeanTTY intentionally does not claim a complete OpenSSH parser. In particular,
preserving an unknown directive is not the same as implementing it.

## File authorization decision

The only commands are:

```text
config import <Downloads-file-name> [--replace]
config export [<Downloads-file-name>]
```

The default export name is `leantty-ssh-config`. A basename is required; paths,
symbolic links, directories and files larger than 1 MiB are rejected. Import
uses one regular UTF-8 Downloads file after the existing foreground permission
request. Export writes a same-directory temporary file, flushes and closes it,
then uses the already device-qualified no-replace move; an existing destination
is never overwritten.

The existing physical-PC study proved both alternatives: `DocumentViewPicker`
can grant one-file URI access, while the current Downloads permission exposes
only the public Download root and does not spread to Images. The command path
selects Downloads because it is already the single keyboard-first local-file
boundary for `put/get` and key export. Adding a Picker would introduce a second
interaction and lifecycle path without improving this bounded migration.

Current research was refreshed on 2026-08-21. OpenHarmony's
[application file API guide](https://gitee.com/openharmony/docs/blob/39467f023bec8cfca8ec2f97b99039b1dbd141e5/en/application-dev/file-management/app-file-access.md)
confirms the `fileIo` open/read/write/close model. The official
[DocumentViewPicker save guide](https://gitee.com/openharmony/docs/blob/f71f4e0666cad9707f0aff890465534a5802c142/zh-cn/application-dev/file-management/save-user-file.md)
confirms URI-scoped Picker save as the alternative. Neither source proves
cross-store transactionality; that remains a LeanTTY policy plus physical-PC
reopen test.

## Import, commit and recovery contract

Import without an option is allowed only when the current config has no
non-LeanTTY text. Existing LeanTTY-managed Hosts remain first, so a migration
cannot silently replace an already managed destination. When non-LeanTTY text
already exists, the user must export it first and explicitly use `--replace`;
LeanTTY replaces that one unmanaged body instead of inventing merge precedence.

The event chain is:

```text
explicit config command
→ Downloads permission and bounded regular-file read
→ parse and validate all import-wide stop conditions
→ compose existing managed region plus unchanged imported bytes, with explicit replacement when required
→ atomically replace the runtime projection
→ atomically advance the durable generation pointer
→ reopen the canonical text in SshConfig
```

No durable mutation occurs before file and semantic validation. If the durable
commit fails after projection replacement, `SshConfigCommitPolicy` restores the
previous projection (or removes the first projection). The previous durable
generation remains authoritative. Unit fault injection covers both rollback
paths. The durable store and projection are not two user configuration sources:
the store is retained state and `.ssh/config` is its runtime materialization.

## Verification scope

- L0: public-source policy, help/user-guide consistency and `git diff --check`.
- L1: parser, rejection, byte-preserving round-trip, managed add/set/rm, reopen
  and commit rollback fixtures.
- L2: signed ARM64 debug HAP integration.
- L3: named physical scenario for permission, successful import, effective
  config, export no-replace, application restart/reopen and exact cleanup.

The routine slice does not run the ungrouped software gate, formal
`verify-pc.ps1`, release signing or the unrelated SSH/terminal physical matrix.
