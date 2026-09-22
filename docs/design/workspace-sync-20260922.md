# Local and remote source reconciliation — 2026-09-22

This is a point-in-time inventory, not another work list. Outstanding actions
remain in [Next Work](../next-work.md). The maintainer requested comparison of
both sides and gradual PR delivery of useful local work.

## Starting state

- After fetching GitHub, local `main` and `origin/main` both pointed to
  `4fe927daeda267d558af64a5bd19bea02aa006fb`, with identical trees and zero
  ahead/behind commits. The primary worktree was clean.
- All 13 same-named local/remote branch pairs matched exactly. There was no
  unpushed commit on any of those pairs.
- Of 60 local branch heads, 59 were already represented by main ancestry,
  merged PR heads, an ancestor of a merged PR head, or an identical merged
  tree. The remaining head was the already-pushed ECDSA patch, PR #227.
- The two runtime-reclaim surface branch heads have the same tree
  `c7fb8bddaad5833913e0b8deae99066eac4f0149`; PR #155 delivered it. Different
  commit IDs here are not missing changes and do not justify another merge.

## Useful local work and disposition

| Content | Evidence and disposition |
| --- | --- |
| ECDSA scalar correction | [PR #227](https://github.com/wandcs/leantty/pull/227), already pushed; software/CI and signed build passed. Remains draft pending the agreed physical import/authentication/restart/cleanup checks. |
| PUT/GET mapping preflight | Recovered the existing AT16-07 three-file code patch onto current main as [PR #228](https://github.com/wandcs/leantty/pull/228). Nine offline cases, device-helper tests and source policy pass. Remains draft pending actual HDC mapping/transfer/cleanup evidence. |
| Old command-completion working draft | Nine modified files in the old input-completion checkout are an earlier PR #209 draft. Five code files match that delivered version exactly; one differs only in line endings, and two were strengthened during delivery (preserving thrown-error identity and recording unsuccessful return). The remaining file is the old work-list snapshot. Current main contains the delivered work and subsequent native migration; do not overwrite it with this draft. |
| Old maintenance notes | Retain the original diagnostic narrative and snapshots locally. Current main already records the reviewed conclusions and remaining AT16-07 work, including the PR #208/#213 reconciliation. Raw local evidence and private environment details are not new public source. |

The two dirty maintenance checkouts were not reset or edited. All 14 changed
files were copied and SHA-256 compared; working-tree and index patches were
saved separately. The new PUT/GET branch copies only the reviewed code change,
its existing test and a concise status entry, not the old mixed document state.

## Remote-only branch names

These branches were fetched locally as remote-tracking refs. Absence of a
same-named local development branch does not mean their content is unavailable.

| PR | Status |
| --- | --- |
| [#129: data-encoding 2.11.1](https://github.com/wandcs/leantty/pull/129) | Open dependency update; not adopted merely for source synchronization. |
| [#216: russh 0.63.3](https://github.com/wandcs/leantty/pull/216) | Open dependency update; does not itself fix the ECDSA decoder. |
| [#217: russh-sftp 3.0.0](https://github.com/wandcs/leantty/pull/217) | Open major dependency update; requires its own impact review and evidence. |
| [#67: old 1.3 release source](https://github.com/wandcs/leantty/pull/67) | Closed; its recorded disposition is sequential feature PRs beginning at #68. |
| [#131: old russh update](https://github.com/wandcs/leantty/pull/131) | Closed and explicitly superseded by #216. |

## Preserved local state

The worktree audit covered 16 registered worktrees. Two hold the drafts above;
four retired temporary formal-build directories show deleted source files and
only leftover build caches. Those deletions are not product changes to commit.
The remaining worktrees are clean. No branch, worktree, source snapshot, signing
material or build evidence was deleted to make the inventory look clean.

The three independent release checkouts remain clean and fixed at `36de654`,
the source identity of the existing failed candidate. They are evidence-bound
checkouts, not development branches to fast-forward implicitly. Their old
reports and candidate identities remain unchanged.

Detailed branch/PR mapping, worktree statuses, file hashes, backups and offline
results are retained under ignored `build/verification/workspace-sync-20260922/`.
After this documentation PR merges, the primary checkout returns to main and
verifies commit/tree equality with `origin/main`; pending draft branches remain
fully pushed. Physical evidence is still required before adopting #227/#228.

Follow-up on 2026-09-22: PR #227's fixed 31-byte ECDSA and encrypted-key physical
diagnostics now pass, including restart, authentication, preservation and
cleanup. See [the regression record](ecdsa-private-scalar-boundary-20260922.md).
This closes that PR's device gap; PR #228 still requires its transfer check.
