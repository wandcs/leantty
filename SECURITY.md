# Security Policy

## Supported versions

| Version | Security support |
|---|---|
| 1.0.x | Supported |
| Older development snapshots | Not supported |

Security reports are handled on a best-effort basis. The project does not
promise a fixed response or remediation deadline.

## Reporting a vulnerability

Do not open a public issue, discussion or pull request for a suspected
vulnerability.

Use GitHub's private vulnerability-reporting form:

<https://github.com/wandcs/leantty/security/advisories/new>

Include the affected version or commit, impact, reproduction steps and any
suggested mitigation. Remove real credentials, private keys, device identifiers
and production host information from the report.

If the form is unavailable, contact the maintainer through the private contact
method shown on the GitHub profile rather than publishing the details.

## Security boundaries

- Verified private/public key pairs, OpenSSH configuration, trusted host keys
  and essential settings use encrypted persistent HarmonyOS Asset Store
  records. Application-private `.ssh` files are runtime projections, not the
  long-term authority.
- Passwords and passphrases are not intentionally persisted and sensitive Rust
  values are zeroized where supported.
- Host keys are checked against OpenSSH-compatible `known_hosts` data.
- The native terminal validates bounded commands and retains Session/input
  ownership across asynchronous callbacks. Remote terminal effects pass
  restricted clipboard, notification and link policies.
- Clipboard reads occur for paste. Writes occur for local copy or a bounded
  OSC 52 request; OSC 52 reads are rejected.
- Signing keys and production credentials are kept outside the source
  repository.

The detailed trust boundaries, protected assets and required evidence are in
[the security model](docs/security-model.md). Data retention, ordinary-uninstall
behavior and deletion limitations are disclosed in
[the privacy policy](PRIVACY.md).

## Known limitations

- Development builds use a local test-signing identity and are not official
  distribution artifacts.
- Native terminal parsing and rendering share the application process; native
  memory-safety defects remain a security risk.
- Ordinary uninstall is not complete erasure of persistent LeanTTY assets; the
  current source does not provide a one-step erase-all command.
- On-device diagnostic logs can contain host endpoints, remote-controlled
  titles, key paths/fingerprints and other operational metadata even though
  LeanTTY does not upload them.
- LeanTTY inherits security assumptions and update cadence from HarmonyOS,
  Ghostty VT, the local guide's ArkWeb view and other third-party dependencies.
- Terminal output and remote applications are untrusted input; bugs in parsing,
  rendering or native boundary validation may still exist.

Official release provenance and hashes are published separately from the source
tree. A package obtained from an unofficial fork should not be treated as an
official LeanTTY build.
