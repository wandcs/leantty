# LeanTTY coding guide

This guide describes the stable implementation boundaries and verification
rules for the current ARM64 HarmonyOS PC product. It also defines the coding
discipline for a repository maintained primarily by coding agents. The goal is
not code optimized for a particular model or prompt, but code whose behavior can
be reconstructed, changed and verified from repository evidence without hidden
project knowledge.

Read [`architecture.md`](architecture.md) for the current event chains and
persistence model, [`security-model.md`](security-model.md) for trust
boundaries, and [`quality-strategy.md`](quality-strategy.md) for the complete
evidence mapping. This guide remains the concise coding discipline.

## Start with ownership

The domain model is:

```text
App Shell
  └─ Tab → Pane → Session
                 ├─ SSH Transport
                 ├─ Terminal Surface
                 └─ System Services
```

- A tab owns one or two panes.
- Each pane owns one session through a stable identifier.
- A session owns connection lifecycle and terminal interaction.
- Mutable state has one authoritative owner.
- Array adjacency, selected indices, WebView instances and UI labels must not
  stand in for ownership.

The older `Page → ViewModel → Model → Common` direction is a useful dependency
hint, not a reason to obscure state ownership.

## Responsibility boundaries

- **App Shell** owns windows, tabs, panes, focus and global preferences.
- **Session** owns connect, authenticate, host-key, cancel, disconnect and
  reconnect state.
- **SSH Transport** owns russh, PTY and byte streams; it does not decide UI text.
- **Terminal Surface** owns xterm display, input, selection and resize; it does
  not own business state.
- **System Services** wrap HarmonyOS clipboard, preferences and window APIs.
- **Bridge** carries validated structured messages and no business rules.
- **UI** renders state and sends user intent without coordinating several lower
  layers directly.

Add a type or layer only when it owns a real lifecycle, encapsulates a testable
policy, isolates a platform/protocol boundary, or materially simplifies the
core state machine.

## Agent-maintainable code

Treat every change as if it will next be maintained by a capable contributor
who starts with no conversational context. The repository must let that
contributor determine the owner, entry point, invariant, failure path and
verification method without guessing.

### Keep behavior decidable

- Every mutable state has one authoritative owner. A cache or derived view must
  make its source, synchronization rule and invalidation condition explicit.
- Every business behavior has one implementation entry. Platform, UI, WebView
  and transport layers must not contain independent versions of the same rule.
- Make the complete event chain traceable: input, parsing or UI intent, state
  transition, boundary message, side effect, observable result, failure,
  cancellation and recovery.
- Represent protocols, lifecycle and business state with structured types and
  events. Do not infer them from UI text, log fragments, array position,
  call timing or combinations of unrelated booleans.
- Give domain concepts stable, searchable names across code, tests and logs.
  Generic names such as `Manager`, `Utils`, `handle` and `process` require a
  narrower domain qualifier when they would otherwise hide the affected rule.

### Size code by responsibility, not line count

There is no mechanical function or file length limit. A cohesive state
transition may be easier to understand in one local implementation than through
many one-use helpers. Split code when it mixes owners or boundaries, combines
business policy with transport or rendering, contains an independently testable
strategy, or makes one branch require understanding unrelated branches.

Do not add an interface, service, manager, factory or extension point merely to
shorten a file, wrap a single implementation or anticipate an unapproved future
need. Extraction must name a durable concept rather than move incidental code
to another file.

### Reuse rules, not incidental code shape

Centralize rules that must remain identical: security decisions, state
transitions, validation, protocol encoding and decoding, error classification
and other business invariants. Two small code sequences that only happen to
look alike may remain local when they have different owners or reasons to
change. Eliminating a few duplicated statements does not justify a generic
framework, parameter matrix or callback layer.

When one rule is found in multiple layers, first select its authoritative owner
and remove the competing implementations. Do not create another shared helper
that leaves the duplicate state or decision paths intact.

### Make contracts and failures explicit

At each real boundary, make inputs, outputs, validation, ownership transfer,
lifecycle, idempotency, cancellation and error behavior visible in types or in
a concise contract beside the boundary. Reject malformed or out-of-state
messages explicitly.

Failures must be observable and distinguishable. Do not swallow errors or map
timeout, cancellation, disconnect and ordinary failure to one ambiguous result.
Use stable event names and the minimum non-secret identifiers needed to trace a
Session or Pane. Logs, diagnostics and fixtures must not expose credentials,
private terminal content or unredacted host material.

### Write durable comments

Comments explain why a constraint exists, which platform or protocol behavior
requires it, what invariant would be broken by a tempting simplification, or
why a rejected alternative was unsafe. Do not restate the next line of code.
Update or remove a comment when its contract no longer holds; stale comments
must not become a second source of truth.

### Make verification part of the implementation

- Name tests after observable behavior and relevant conditions, not only the
  implementation unit or a sequence number.
- Test authoritative rules and meaningful negative, cancellation and recovery
  paths. Avoid tests that freeze private call order or accidental code shape.
- Keep the smallest applicable verification command discoverable through
  `quality-strategy.md` and the regression registry.
- A mock proves only the modeled contract. It cannot replace compiled-boundary
  evidence or a named physical scenario when the changed claim depends on the
  HarmonyOS PC.
- A task or design must state observable completion conditions and important
  non-goals. Code written, tests passing, build success, package installation
  and a visible window are evidence of different scopes, not interchangeable
  definitions of completion.

### Keep changes locally reviewable

Make the smallest coherent change that fixes the authoritative rule. Do not mix
unrelated cleanup, speculative compatibility, opportunistic abstraction or
format churn into the same patch. Remove superseded branches and abstractions
instead of preserving them without a current contract. Preserve unrelated
worktree changes and do not turn a test or a historical design into a new
product requirement.

Before considering an implementation reviewable, answer all five questions:

1. Who owns the affected state?
2. Where is the single entry for the behavior?
3. Is the rule implemented anywhere else?
4. How do failure, cancellation and recovery propagate?
5. Which evidence proves the changed claim at the required level?

If an answer requires guessing across unrelated files, improve the ownership,
naming, contract or verification path before adding explanatory process around
the ambiguity.

## Repository map

| Path | Purpose |
|---|---|
| `AppScope/` | Application-level HarmonyOS resources and configuration |
| `entry/src/main/ets/` | ArkUI application, state and platform integration |
| `entry/src/main/resources/` | HarmonyOS resources and ArkWeb terminal assets |
| `entry/src/test/` | Trusted ArkTS logic tests |
| `leantty_ssh/` | napi-ohos binding and SSH transport |
| `leantty_ssh/leantty-ssh-core/` | Host-testable pure Rust policies |
| `tools/web-terminal/` | xterm source assembly and policy tests |
| `tools/` | ARM64 build, deployment and verification scripts |
| `docs/` | Product governance, user contract, architecture, quality, current work and stable manuals |

Generated native libraries, HAP/APP packages, caches and signing material are
not source and must remain untracked.

## ArkTS and ArkWeb

- Follow the repository linter; do not bypass type restrictions with `any`,
  `unknown` or broad casts.
- Use structured events and explicit state instead of inferring state from UI
  text, output fragments or timing.
- Keep one implementation entry for each behavior; do not patch the same rule
  independently in ArkUI, WebView and Rust.
- Validate every bridge message's version, direction, channel, kind and payload
  before dispatch.
- Treat terminal output and remote-controlled titles as untrusted data.
- Preserve runtime-measured xterm dimensions; fitting must account for actual
  container padding and WebView size.

## Rust transport

- Keep transport concerns below the N-API boundary.
- Never log passwords, passphrases, private keys or unredacted host material.
- Preserve deterministic cancellation and disconnect behavior.
- Keep pure policy in `leantty-ssh-core` when it can be tested without
  HarmonyOS or N-API.
- Run formatting on the whole workspace and clippy/tests on the pure core.

## Verification

For every feature iteration or bug fix, select only the tests mapped to the
changed event chain and add the smallest stable main-path smoke that finishes
quickly. Use the device loop only when the affected behavior needs it:

```powershell
.\tools\dev-pc.ps1
```

Rust formatting, tests and compilation run in WSL. The maintainer scripts use
the Windows DevEco SDK only for the OHOS target linker, HAP packaging and
signing; they do not compile Rust with a native Windows toolchain.

Complete formal-release gates:

```powershell
.\tools\verify-pc.ps1
.\tools\verify-key-passphrase-pc.ps1
```

`verify-pc.ps1` runs the complete ungrouped software gate once before the clean
candidate build. Routine work instead selects affected local groups, for example
`.\tools\test-regression.ps1 -Group policy,tooling`, and runs
`.\tools\preflight-device.ps1` only when a named physical scenario is required.

For PowerShell, use semantic variable names and avoid case-insensitive collisions
with automatic/read-only variables such as `$PID`, `$HOME` and `$Error`. Long
fixture lifetimes must be derived from declared scenario budgets plus cleanup
margin; fixed sleeps may pace polling but cannot decide a test verdict.

Automated tests prove pure logic and protocol behavior. ARM64 builds prove
target integration. Install and launch prove only deployment. A named scenario
is required for a directly affected focus, keyboard, clipboard, window,
persistence, terminal-interaction or SSH-lifecycle claim. Run the complete
software/build/physical matrix only while preparing a formal release package.
Follow the mandatory scope rules in
[`quality-strategy.md`](quality-strategy.md).

## Change discipline

- Outstanding work belongs only in `docs/next-work.md`.
- Product, feature and refactoring decisions must pass
  `docs/project-principles.md`.
- Do not add unsupported device layouts, x86_64 emulator paths, local shells,
  plugin systems or speculative compatibility layers.
- Preserve unrelated worktree changes.
- Keep credentials, certificates, device identifiers and private environment
  data out of source, tests, screenshots and logs.
