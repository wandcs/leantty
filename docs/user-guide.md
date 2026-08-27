# LeanTTY User Guide

> Status: current-source user contract
>
> Last updated: 2026-08-25
>
> Applies to: the 1.5.0 release source. Version 1.4.0 is the preceding
> AppGallery baseline; check the matching GitHub Release and AppGallery entry
> before relying on 1.5.0 behavior in an installed build.

LeanTTY is a keyboard-first SSH terminal for a physical ARM64 HarmonyOS PC. It
provides the TTY entry point; the shell, tmux, editor and Agent TUI continue to
run in the selected execution environment.

## Product model

- The application starts at a lowercase `ltty>` prompt in the theme's green.
- A tab owns one or two panes.
- Each pane owns one independent SSH session and terminal surface.
- Closing a connected pane disconnects its SSH session.
- Closing the application with active sessions asks for confirmation and then
  disconnects those sessions.
- LeanTTY does not provide a local shell, Linux distribution, package manager,
  file manager, background session service or account/cloud workspace.

The only supported application target is a physical ARM64 HarmonyOS PC used
with a keyboard and mouse. Other device classes and an x86_64 emulator are not
part of the product contract.

## First connection

At `ltty>`, connect directly with a username and host:

```text
ssh user@example.com
ssh -p 2222 user@example.com
ssh -i id_work user@example.com
```

IPv6 literals can be written in brackets. A non-default port can use `-p`; the
`user@[address]:port` form is also accepted by the current parser.

On the first connection to an endpoint, LeanTTY displays the received host-key
fingerprint and waits for the explicit trust decision. Verify the fingerprint
through a channel you already trust before accepting it. A later host-key
change stops the connection and shows the exact cleanup command; LeanTTY does
not automatically delete or replace the old trust record.

Current source authentication supports direct password, unencrypted and
encrypted private keys, SSH `keyboard-interactive`, authentication banners and
multi-method authentication. Check the matching release before relying on a
development capability in an installed build.

## Working with Agent TUIs

Keep the durable job on the server. Connect, enter a named tmux session, then
start one Agent in that session:

```text
ssh work
tmux new -As agent
codex                 # or: opencode, pi, qwen
```

Detach with tmux's `Ctrl+B`, then `D`. Reconnect to the server and run
`tmux attach -t agent` to resume. LeanTTY preserves the TTY while it is running;
tmux or screen—not a LeanTTY tab or notification—owns survival across an app
exit, system sleep or network break.

Notification behavior was checked on 2026-08-24 with Codex CLI 0.149.0,
OpenCode 1.18.22, Pi Agent 0.84.2 and Qwen Code 0.22.0:

- Codex can use its `tui.notification_method = "bel"` setting; native BEL
  attention worked in direct SSH and tmux.
- For Qwen Code, enable `general.terminalBell` and set
  `general.notificationMode` to `all`. When Qwen runs inside tmux, add
  `set -g focus-events on` to the remote tmux configuration so Qwen receives
  terminal focus changes. The tested tmux path completed the notification and
  return flow.
- Pi's packaged `notify.ts` extension emits OSC 777, which LeanTTY recognizes,
  but a completion arriving after HarmonyOS has suspended the hidden app may
  not produce a system notification.
- OpenCode direct SSH passed with its native OSC 99 completion notification,
  generic system notification and return flow. OpenCode 1.18.22 remained usable
  inside tmux, including detach and reattach, but did not emit a complete
  notification frame there even with tmux passthrough; treat that as an upstream
  tmux notification limit. LeanTTY accepts only complete title/body frames and
  discards their identifiers and content; richer OSC 99 operations are ignored.

Accepted BEL, OSC 9, restricted OSC 99 and OSC 777 attention always uses LeanTTY's fixed generic
notification text; remote titles, Agent replies and task content are discarded.
Each continuous hidden-window episode gets at most one attempt. System
notification is best effort: keep important work in tmux or screen and return
to LeanTTY to inspect the real terminal state.

## Saved hosts and OpenSSH configuration

Create a short Host name with:

```text
host add work user@example.com
host add lab user@example.com:2222
host add private deploy@target.example.com -i id_private -J jump
host set work user@new.example.com:2222 -i id_work --connect-timeout 9
host set work user@new.example.com:2222 -i none
host list
host rm work
```

Then connect with:

```text
ssh work
```

`host rm` removes only Host entries created inside LeanTTY's managed section.
It does not silently rewrite unrelated OpenSSH configuration.

`host add` and `host set` accept `-i <identity>` to save one key shown by
`key list` as that Host's `IdentityFile`. The key is then reused by `ssh`,
`put` and `get`; a command-local `-i` still overrides only that command. Use
`-i none` to remove the saved binding and return to the normal default-key
selection. Updating another Host field without `-i` preserves the existing
binding.

The current documented `ssh_config` subset is:

| Directive | Current behavior |
| --- | --- |
| `Host` | Literal names plus `*`, `?` and `!` pattern matching |
| `HostName` | Resolves the network destination |
| `User` | Required when connecting by Host name |
| `Port` | Defaults to 22 |
| `IdentityFile` | Selects a verified LeanTTY key by supported reference |
| `ProxyJump` | Uses one saved Host or one `[user@]host[:port]` jump |
| `ConnectTimeout` | Uses 1–300 whole seconds; defaults to 15 seconds |
| `ServerAliveInterval` | Uses 0–3600 whole seconds; `0` disables probes |
| `ServerAliveCountMax` | Uses 1–100 unanswered probes |

OpenSSH first-value behavior is preserved for these fields. An unknown or
unsupported directive in a matching Host block causes `ssh` and `ssh -G` to
fail with the directive and line number before a connection starts. Because
LeanTTY does not yet evaluate `Match` conditions, any `Match` block is rejected
instead of being silently ignored. Unsupported directives in unrelated Host
blocks do not block the selected Host, and LeanTTY preserves their source text
when it edits its own managed Host section.

To migrate one existing config file, first place it in Downloads, then run:

```text
config import workstation.conf
```

Import is available only while the current config has no existing non-LeanTTY
text. If such text already exists, export it first and explicitly run
`config import workstation.conf --replace`; LeanTTY replaces that unmanaged
body instead of inventing merge precedence. Existing LeanTTY-managed Hosts
remain first. `Include`, `Match`, token or
environment expansion and quoted supported values are rejected because LeanTTY
cannot reproduce their effective authority safely. Comments, whitespace,
line endings, repeated Host patterns, wildcards and unknown directives are
retained exactly. An unknown directive in a matching block still stops that
connection explicitly; it is not silently treated as supported.

Export the active config without overwriting an existing Downloads file:

```text
config export
config export workstation-backup.conf
```

The default file name is `leantty-ssh-config`. Import/export accepts one
Downloads basename, not a path, directory, profile, background watcher or
alternate `ssh -F` config.

`ConnectTimeout` limits TCP setup and the initial SSH handshake/key exchange. It
uses the target Host value for direct SSH, the target layer, reconnect and
`put/get`; a named jump Host uses its own value. It does not count time spent waiting for you to
confirm a host key or enter a password, key passphrase or OTP. A timeout reports
whether the jump or target layer failed so you can correct the Host or retry.
Use `--connect-timeout default` with `host set` to remove the explicit line and
restore LeanTTY's 15-second default.

Inspect the effective supported fields without connecting:

```text
ssh -G work
```

When a connection fails before the remote prompt appears, rerun that one
attempt with bounded diagnostics:

```text
ssh -v work
```

LeanTTY reports fixed, redacted jump/target stages for name resolution, TCP,
SSH version and key exchange. It does not enable raw transport logs or expose
hosts, identities, paths, fingerprints, prompts, credentials or terminal
content. Normal `ssh` and reconnect remain non-verbose.

For a target that is reachable only through one standard SSH jump host, save
both hosts in the same configuration or use a one-time `-J` override:

```text
host add jump gateway@jump.example.com
host add private deploy@target.example.com -J jump
ssh private
ssh -J jump deploy@target.example.com
```

LeanTTY verifies and authenticates the jump host and target separately. The
terminal opens only after the target PTY is ready. `-J none` bypasses a saved
`ProxyJump` for one command or disables it when used with `host set`. The first
version supports one jump only; `ProxyCommand` and comma-separated chains fail
explicitly.

## Connected SSH escapes

At the start of a connected Session or immediately after Enter, use these
OpenSSH-style escapes:

| Escape | Result |
| --- | --- |
| `~.` | Disconnect only the current Pane's SSH Session |
| `~?` | Show the escapes LeanTTY currently supports |
| `~I` | Show the sanitized target, optional jump route and connected state |
| `~~` | Send one literal `~` to the remote PTY |

The escape must begin at line start. A tilde elsewhere in a shell command,
editor, tmux or Agent TUI is sent normally, and an unknown line-start sequence
such as `~x` is also sent unchanged. Connection information never includes a
password, authentication response or private-key path. Each Pane recognizes
escapes independently; only `~.` ends the Session.

## Key management

Generate a key pair:

```text
ssh-keygen -t ed25519 -f id_work -C work
ssh-keygen -t rsa -f id_rsa_work -C work
```

The generation command creates Ed25519 or RSA-4096 keys and refuses to overwrite
an existing private or public file. It does not currently ask for a new key
passphrase. Existing OpenSSH Ed25519, RSA and ECDSA P-256/P-384/P-521 private
keys can be imported; an encrypted key requests its passphrase when used. ECDSA
generation is not provided.

Change, add or remove the passphrase of a verified private key:

```text
ssh-keygen -p -f id_work
```

LeanTTY asks for the old passphrase, the new passphrase and confirmation through
non-echoing terminal input. Leave the old passphrase empty for an unencrypted
key, or leave the new passphrase empty to remove encryption. `Ctrl+C`, a wrong
old passphrase, a confirmation mismatch or a commit failure leaves the existing
key active. Passphrases are not accepted through command options.

Change or remove the comment on an existing verified key pair:

```text
ssh-keygen -c -f id_work
```

For an encrypted key, LeanTTY first asks for the current passphrase through
non-echoing input. It then shows the current comment and accepts one visible
replacement; leave the replacement empty to remove the comment. Spaces and
UTF-8 text are retained. Control characters and comments over 1023 UTF-8 bytes
are rejected. Success keeps the same fingerprint, key algorithm, encryption
state and passphrase, and updates both the private key and `.pub` line. `Ctrl+C`,
an incorrect passphrase or a commit failure leaves the previous pair active.

Inspect and manage verified keys:

```text
key list
ssh-keygen -y -f id_work
ssh-keygen -l -f id_work
key import <accessible-path> id_imported
key export id_work
key export id_work id_work_copy
key rm id_work
```

Important behavior:

- Import accepts a private-key file path available to the application, derives
  and verifies the matching public key, and rejects an incomplete, invalid or
  unsupported key. Supported imported identities are OpenSSH Ed25519, RSA and
  ECDSA P-256/P-384/P-521 keys.
- Export requests access to the HarmonyOS Downloads directory and writes both
  the private key and `<name>.pub`.
- Export never overwrites either destination. Choose another basename when one
  already exists.
- Exported private keys are sensitive user-owned files. Move or delete them as
  soon as the intended transfer is complete.
- Deleting a key requires confirmation and removes both its persistent record
  and application-private projection. LeanTTY reports success only after both
  are absent. If deletion fails, restart LeanTTY, check `key list` and try again;
  do not assume the private key was removed.

Install a public key on a server through the existing SSH path:

```text
ssh-copy-id -i id_work user@example.com
ssh-copy-id -i id_work -p 2222 user@example.com
```

The command installs one public-key line and does not duplicate an identical
existing line. It does not change any saved Host. When the installed key is not
a default Identity, bind it explicitly with `host add ... -i <identity>` or
`host set ... -i <identity>`. The command is a bounded helper, not a general
remote file editor.

## Single-file transfer

At an idle `ltty>` prompt, transfer one file between the authorized HarmonyOS
Downloads tree and an SFTP server:

```text
put report.pdf user@example.com:/incoming/
put -p 2222 -i id_work builds/app.bin work:/incoming/app.bin
get user@example.com:/reports/latest.csv
get work:/reports/latest.csv reports/
```

`put` and `get` reuse the same Host, port, Identity, host-key and authentication
rules as `ssh`. A command-local `-p` or `-i` applies only to that transfer. The
remote endpoint must provide SFTP; LeanTTY does not expose an interactive SFTP
shell.

Local paths are relative to Downloads. Existing subdirectories are allowed,
but LeanTTY does not create directories, recurse, expand wildcards or transfer
multiple sources. A trailing `/` means an existing directory and keeps the
source basename. `get` may omit its local target and then also uses the remote
basename.

LeanTTY never overwrites an existing file. An explicitly named destination
fails on conflict. When LeanTTY chose a download basename because the target
was omitted or was a directory, it keeps both files by committing to the first
available `name (n).ext` and reports the actual name after completion. Uploads
fail if their final remote name already exists.

Transfers run in the current pane. Progress stays on one terminal line and
shows percentage, transferred size, live speed and ETA; completion reports the
size and elapsed time. With no terminal selection, `Ctrl+C` cancels the active
transfer and cleans its owned partial file. With a selection, `Ctrl+C` keeps
the normal copy behavior. Closing the pane or application uses the same bounded
cancellation path. Forced termination may leave an identifiable `.part` file;
LeanTTY never claims or removes partial files from an earlier process.

Passwords, key passphrases and non-echoing keyboard-interactive responses are
masked and removed from the WebView input helper after the key event is
consumed. They are not command options and are not written to command history.

## Host-key maintenance

Find every matching algorithm record for one exact endpoint without changing
the trust store:

```text
ssh-keygen -F example.com
ssh-keygen -F [example.com]:2222
```

Remove every matching algorithm record for one exact endpoint:

```text
ssh-keygen -R example.com
ssh-keygen -R [example.com]:2222
```

Default port 22 uses the plain host target. Non-default ports must use the
OpenSSH `[host]:port` form. After removal, reconnect and verify the new
fingerprint before accepting it.

## Current local command reference

At the top-level `ltty>` prompt, `help`, `?`, `？`, `-h` and `--help` keep the
complete terminal help and append one link to the full offline guide. LeanTTY
creates or refreshes that file only after the command is entered, at:

```text
Downloads/com.leantty.app/LeanTTY-User-Guide.html
```

Hold `Ctrl` and left-click the displayed `LeanTTY-User-Guide.html` file name to
open it in the system browser. Its OSC 8 link retains the complete platform URI
without displaying the long path in terminal help.

An identical current file is reused without rewriting; an older LeanTTY-owned
copy is replaced, while a same-name file without LeanTTY's ownership marker is
left untouched. Topic help such as `help ssh` remains short and does not create
the file.

| Command | Purpose |
| --- | --- |
| `help`, `?`, `？`, `-h`, `--help` | Show full local help and prepare the offline guide |
| `help <command>`, `<command> --help` | Show short command help |
| `ssh [-p port] [-i identity] user@host` | Connect directly |
| `ssh [-p port] [-i identity] host-name` | Connect through saved configuration |
| `ssh -G host-name` | Show the supported effective configuration |
| `ssh-keygen -t ...`, `-y`, `-l`, `-p`, `-c`, `-F`, `-R` | Generate, inspect or maintain SSH assets |
| `ssh-copy-id -i ...` | Install one public key |
| `put [-p port] [-i identity] local-file host:remote-path` | Upload one Downloads file through SFTP |
| `get [-p port] [-i identity] host:remote-file [local-path]` | Download one SFTP file into Downloads |
| `key list/import/export/rm` | Manage LeanTTY key pairs |
| `config import/export` | Migrate or back up the single OpenSSH config through Downloads |
| `host add/set/list/rm` | Manage LeanTTY Host entries |
| `exit` | Close the current idle pane or tab path |

## Keyboard and mouse interaction

| Action | Current interaction |
| --- | --- |
| New tab | `Ctrl+Shift+T` |
| Next/previous tab | `Ctrl+Tab`, `Ctrl+Shift+Tab` |
| Split the current tab | `Ctrl+Shift+D` |
| Focus the left/right pane | `Ctrl+Alt+Left`, `Ctrl+Alt+Right` |
| Close the active pane | `Ctrl+Shift+W` |
| Search the current terminal surface | Four-dot menu or `Ctrl+Alt+F`; Enter/Shift+Enter move next/previous, Escape closes |
| Increase/decrease/reset font size | Four-dot menu `−`/`+`, or `Ctrl+=`, `Ctrl+-`, `Ctrl+0` |
| Copy a local selection | `Ctrl+C`; without a selection it remains terminal `Ctrl+C` |
| Paste | `Ctrl+V` or secondary click when no selection exists |
| Secondary-click with a selection | Copy the selection |
| Open an HTTP(S) or OSC 8 link | Hold `Ctrl` and left-click |
| Open a link while a TUI owns the mouse | `Ctrl+Shift+Left Click` |
| Force local selection while a TUI owns the mouse | Hold `Shift` and drag |

With tmux mouse mode enabled, an ordinary drag belongs to tmux. Releasing its
selection can copy through the standard OSC 52 system-clipboard path. LeanTTY
does not support OSC 52 clipboard reads.

The split divider can be dragged. When it has keyboard focus, Left/Right adjust
the ratio and Enter resets the split to equal widths.

After a floating main-window resize, LeanTTY aligns the final content size to
whole terminal cells. A small final adjustment is expected; dragging the left
or top edge keeps the opposite edge fixed.

Search belongs only to the current pane and its in-memory terminal surface. It
does not search another pane, tab, remote file, command history or a destroyed
session. Closing search restores terminal focus without sending the query to
the remote session. An empty query and an unsuccessful query are both shown
compactly as `0/0`, while accessibility distinguishes “Type to search” from
“No results”.

The terminal content and top Chrome use coordinated, restrained translucent
surfaces with one fixed HarmonyOS Regular background material at the window
root. Open the four-dot menu and use the minus and plus buttons
beside **Transparency** to step through Off, Low, Medium, High and Extreme.
Medium is the default; the range does not wrap, its boundary button is disabled,
and the menu stays open for direct comparison. Left and Right adjust the selected
row from the keyboard. **Font Size** uses the same `− current +` interaction;
`Ctrl+0` remains the reset shortcut. The selected transparency level is restored
after a normal application restart but is not part of the uninstall-surviving asset
set. Off and platforms that cannot enable window transparency fall back to an
opaque surface without material. Explicit terminal and TUI background colors
remain authoritative. A BEL briefly emphasizes its source tab. If the source is
not active, the tab's
leading status dot remains amber until that pane is entered; a non-focused pane
in the current split also shows a small marker beside the divider. BEL never
draws a warning frame around the terminal content.

When the entire LeanTTY window is hidden, minimized or otherwise not visible,
the first new unattended BEL or accepted OSC 9/99/777 attention in that continuous background episode
may also publish one removable local system notification. Its text is generic:
it does not include the host, user, command, terminal output, title or Agent
response. Later BELs in the same background episode keep only their existing
in-app tab/pane attention and do not refresh, replace or chase the notification.
Making the window visible is the only reset for another notification attempt.
Remote OSC title/body fields and identifiers are discarded. OSC 99 capability
queries receive only the minimal title/body support response; incomplete chunks,
actions and lifecycle operations are not accepted,
and output that arrives after HarmonyOS suspends the hidden app cannot be relied
on to publish immediately.

Clicking the notification returns only to the existing pane that originally
earned the attempt and still owns attention. If that pane was handled, closed,
or lost with an application restart, the click only opens LeanTTY; it does not
recreate a pane or SSH session or focus a different terminal. The card is
automatically removed after 24 hours. Disabling or rejecting notification
permission leaves terminal I/O and in-app attention unchanged; after the first
missed background BEL, LeanTTY may ask once on a later foreground return and
does not repeatedly request permission after that attempt.

## Data retention and uninstall

LeanTTY keeps OpenSSH config, trusted host keys, verified key pairs, terminal
font size and the main-window rectangle in encrypted persistent HarmonyOS Asset
Store records. They are configured to survive a normal uninstall and be
rematerialized for the same application identity after reinstall; the complete
asset/signature/lifecycle matrix remains a physical-device release gate.

Passwords, passphrases, authentication answers, command history, tabs, panes,
sessions and terminal screen/scrollback are not intentionally persisted across
application termination or reinstall. A terminal snapshot used to rebuild an
ArkWeb surface exists only in the running process.

Ordinary uninstall is not a complete data-erasure command. Before uninstall,
use `key rm`, `host rm` and `ssh-keygen -R` for assets you can identify. The
current source has no single supported command that removes every retained
record. See [the privacy policy](../PRIVACY.md) for the exact boundary.

## Recovery and troubleshooting

- **Connection appears stuck:** press `Ctrl+C`. Connecting and authentication
  prompts have an explicit cancellation path and return to `ltty>`.
- **Host key changed:** do not bypass the warning. Verify the change, run the
  exact `ssh-keygen -R` command shown by LeanTTY, reconnect and inspect the new
  fingerprint.
- **Password keeps being requested:** confirm that the Host resolves a `User`
  and that `IdentityFile` names a key shown by `key list`.
- **Key export failed:** grant Downloads access and make sure neither the
  private basename nor its `.pub` partner already exists.
- **Renderer was rebuilt:** the in-process terminal framebuffer and output
  received while detached are restored before new interaction. This is not a
  persistent shell session; use remote tmux or screen for durable work.
- **SSH disconnected after sleep or network change:** use the visible reconnect
  path. LeanTTY does not claim transparent SSH session roaming.
- **A remote shell ended:** `Connection closed` and the restored `ltty>` prompt
  appear directly after the last visible terminal content. Existing scrollback
  remains available; the first local key is accepted only after the prompt is
  restored.

For a reproducible product defect, follow [SUPPORT.md](../SUPPORT.md). Remove
private data from screenshots and logs. Security vulnerabilities must use the
private process in [SECURITY.md](../SECURITY.md).
