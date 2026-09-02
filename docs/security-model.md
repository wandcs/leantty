# LeanTTY Security Model

> Status: current security architecture baseline
>
> Last updated: 2026-09-02
>
> Public reporting policy: [`../SECURITY.md`](../SECURITY.md)
>
> Privacy and retention: [`../PRIVACY.md`](../PRIVACY.md)

This document explains the security properties intended and implemented by the
current source tree. It does not claim that the application or its dependencies
are free of vulnerabilities. Feature-specific security decisions remain in the
corresponding technical design.

## Security objectives

LeanTTY must preserve, in order:

1. user control over hosts, credentials, terminal content and system effects;
2. authentic SSH server identity and confidential/integrity-protected transport;
3. isolation between Tab/Pane/Session owners;
4. non-persistence and non-disclosure of authentication secrets;
5. bounded handling of remote-controlled terminal and Bridge input; and
6. reproducible, signed release identity.

Convenience must not bypass host verification, broaden data export, turn a
remote terminal sequence into an unrestricted system action, or make failure
look like success.

## Protected assets

| Asset | Required property |
| --- | --- |
| Private keys | Confidential, integrity-checked, export only on explicit request, deletion updates durable and runtime copies |
| Passwords, passphrases and authentication answers | Short-lived, Session-scoped, never deliberately persisted or logged |
| Host-key trust | Exact endpoint semantics, explicit first trust, changed keys fail closed |
| OpenSSH configuration | One authoritative model, bounded supported semantics, atomic durable commit |
| Terminal input/output and screen | Session isolation, no unexpected network destination or persistent recovery |
| Clipboard | Read only for paste; bounded write paths; no OSC 52 read |
| Release package | Exact source commit, ARM64-only payload, expected signature and immutable tag |

## Threat and trust boundaries

### Network and SSH server

The network and the SSH server are not trusted before host-key verification.
SSH encryption does not prove that the key belongs to the intended server; the
user must compare a new fingerprint through an already trusted channel.

A trusted host key authenticates an endpoint, not the safety of software on
that endpoint. Remote shell output, titles, escape sequences, prompts and files
remain untrusted input.

### HarmonyOS and application identity

LeanTTY relies on HarmonyOS for application isolation, encrypted Asset Store
records, pasteboard access, Downloads permissions, window lifecycle, ArkWeb and
package signature enforcement. A compromised OS, unlocked account with local
access or incorrectly isolated platform asset service is outside what the
application can fully defend against.

Persistent assets are created with encrypted attributes, persistent lifetime
and first-unlock accessibility. They are intended to be available only to the
owning application identity. Different-signature isolation and the full
uninstall/reinstall matrix remain physical-device release evidence, not a fact
that can be proven by source inspection alone.

### ArkWeb terminal

ArkWeb/xterm.js runs packaged application resources but processes
remote-controlled terminal content. File access, online images, DOM storage,
mixed content and zoom are disabled. The CSP restricts resources to the package
and fonts/data needed by the terminal, but the current bundle still requires
`unsafe-inline` and `unsafe-eval`; this is a known residual risk.

The H2 Bridge accepts only known direction/channel/kind combinations. Binary
terminal packets and control messages use separate paths. URL and snapshot
payloads are bounded, snapshot request IDs are validated, and output flow uses
acknowledgements and backpressure.

### Source, build and release

GitHub source and CI are not signing authorities. Official distribution
requires the clean-checkout, manifest, signature, hash, tag and AppGallery
process in [`release-process.md`](release-process.md). Production signing
material is never stored in the repository. An unofficial fork or test-signed
HAP must not be presented as an official LeanTTY release.

## Authentication-secret lifecycle

Passwords and key passphrases are accumulated only in the active
`SessionViewModel` input mode and submitted to its `SshClient`. They must be
cleared on submission, cancellation, disconnect, Pane close and error. Rust
uses the value for the current authentication attempt and zeroizes it after use
where supported.

Secrets must not enter:

- the local command history or terminal PTY byte stream;
- Preferences or persistent Asset Store metadata;
- terminal snapshots or renderer replay;
- logs, error snapshots, screenshots or test fixtures; or
- another Session's event or answer channel.

The 1.1 structured keyboard-interactive design adds a generation/round owner
because the current string-event path is not sufficient for multi-round or
multi-method authentication. Until that version is delivered, those methods
are unsupported rather than inferred from prompt text.

## Host-key trust

- `known_hosts` is the single authority for SSH host trust.
- New keys require an explicit user decision and are committed durably before
  the accepted connection proceeds.
- Changed keys stop the connection and show old/new fingerprints plus the exact
  OpenSSH removal target.
- `ssh-keygen -F` queries all matching algorithm records for exactly one
  endpoint without changing the durable trust store or its runtime projection.
- `ssh-keygen -R` removes all matching algorithm records for exactly one
  default or non-default-port endpoint and preserves unrelated plain, hashed or
  comma-separated host fields.
- No option may silently disable checking, auto-accept a changed key or replace
  the trust store with a second model.
- Unknown, `Match` or unsupported directives that could alter the selected
  connection fail before connection or managed Host mutation; their values are
  preserved as source text but never treated as applied configuration.

## Key and configuration custody

Imported/generated key pairs are verified as a pair before they become valid
assets. Private-key names are restricted, SSH control filenames and traversal
are rejected, runtime private files are protected, and generation/import/export
refuse overwrite. A durable commit failure removes a newly generated or
imported runtime pair instead of reporting success.

The Asset Store contains integrity-checked generations. The application-private
`.ssh` directory is materialized from that authority at startup. Host/config,
known-host and key deletion update the durable record and runtime projection so
an explicitly deleted asset does not reappear on a later reinstall.

`key rm` removes and confirms the private/public projection before deleting the
durable key-pair authority. If projection or Asset Store deletion fails, LeanTTY
does not report success: it restores the retained pair where possible, reapplies
private-key protection and tells the user to restart, inspect `key list` and try
again. A rollback failure remains an explicit recovery condition; the user must
not assume the private key was erased.

There is currently no one-step complete erasure command for every persistent
asset. This is a documented lifecycle limitation in the privacy policy and
must not be hidden behind ordinary uninstall wording.

## Terminal-controlled system effects

| Effect | Boundary |
| --- | --- |
| Local copy | Requires a local selection/action; writes to the local-device clipboard |
| Paste | Reads the clipboard for a user paste action and submits through normal terminal input |
| OSC 52 | Accepts only empty/default or `c` target, rejects reads, invalid Base64/UTF-8 and content over 1 MiB |
| URL open | Requires user activation; only normalized credential-free HTTP(S) is handed to the system browser |
| Bell/OSC attention | BEL plus bounded OSC 9, well-formed `OSC 777;notify;title;body`, and complete receive-only OSC 99 title/body frames become the same empty-payload UI attention. OSC 99 notification frames permit only `i/p/e/d` metadata and do not retain IDs or chunks. A bounded `i=<id>:p=?;` query receives only `p=title,body` with the same validated ID through normal TTY input; the ID is not logged or persisted. Activation, close, alive and other capability operations are never answered. OSC content is rejected or discarded inside the Web boundary; only a hidden whole window can attempt one generic system notification per background episode, containing a fixed source marker and internal Pane ID, never remote title, command, output, host data or Agent response. All other notification operations and protocols have no local system effect |
| Terminal checkpoint | Serializes framebuffer state but excludes title, clipboard and bell side effects |

## Unexpected-exit recovery record

The app-private recovery record contains only a schema version, run generation,
clean/running marker, Tab and Pane counts, active positions and split ratio. It
contains no Host, remote title, terminal bytes, command or input history,
credential, secret, attention flag or Session state. Restored Panes receive new
generation-scoped identities and start offline at local `ltty>`.

## Downloads and file-transfer boundary

`put/get` runs only after an explicit local command at an idle `ltty>` prompt.
Local paths are resolved beneath the system-authorized Downloads root; LeanTTY
does not expose arbitrary local paths, recursive traversal, wildcards or a file
manager. Tab completion is bounded and does not request permission merely to
enumerate an unauthorized root.

Local sources are opened without following symlinks and are revalidated by
their native descriptor. File bytes stream directly between that descriptor
and the Rust SFTP client; ArkTS, ArkWeb, terminal output, command history and
logs do not carry file contents. Remote paths, names and server errors remain
untrusted input and are normalized into bounded terminal-safe results.

Final files are never overwritten. Downloads commits use an exclusive
task-owned temporary object and a no-replace final commit; uploads use an
exclusive random temporary name followed by standard SFTP rename only when the
server can preserve the same guarantee. Observed failure and cancellation clean
only the current task's temporary object. Forced process termination can leave
an identifiable `.part` file, but LeanTTY does not claim it as complete or
delete a partial file owned by an earlier process.

## Logging boundary

Current logs are on-device and are not uploaded by LeanTTY. They intentionally
avoid authentication secrets and terminal byte streams, but can include host
endpoints, aliases, remote-controlled titles, application-private key paths,
fingerprints, state transitions, session IDs, geometry, sizes, timings and
errors. Therefore raw logs are sensitive operational data.

Any test, issue or review evidence must redact those fields. New logging must
prefer event kind, count and bounded state over payload content. A feature is
not complete if its failure path can place a secret or terminal content in
`hilog`.

## Dependency and protocol risk

LeanTTY inherits risk from HarmonyOS, ArkWeb, xterm.js, russh, cryptographic
libraries and build dependencies. Lockfiles, Dependabot, pinned GitHub Actions,
license inventory and public CI reduce but do not eliminate that risk.

Dependency updates are classified by their effect on LeanTTY. Security fixes
may enter a patch release, but they must retain terminal correctness, SSH
interoperability, ARM64 integration and release provenance. Replacing a
dependency is not itself evidence that an affected behavior is secure.

## Required security evidence

Security-sensitive changes require evidence at every applicable layer:

- pure tests for parser, validation, state-machine and file/record policies;
- malformed, oversized, cancelled, stale and cross-Session negative cases;
- clean ARM64 build for N-API/platform integration;
- physical-PC checks for permissions, clipboard, lifecycle, Asset Store and
  different-signature behavior; and
- exact signed candidate identity before release.

The stable mapping of change type to evidence is defined in
[`quality-strategy.md`](quality-strategy.md). Current failures or missing release
evidence belong only in [`next-work.md`](next-work.md).

## Known limitations

- The current ArkWeb CSP requires `unsafe-inline` and `unsafe-eval`.
- The current authentication event model does not safely express standard
  keyboard-interactive and multi-method authentication.
- Diagnostic logs can contain sensitive operational metadata even though they
  are not uploaded by LeanTTY.
- Ordinary uninstall is not complete persistent-data erasure.
- Platform isolation and lifecycle claims still require verification on the
  physical ARM64 HarmonyOS PC used for the release candidate.
