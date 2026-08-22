# Project Review Findings: PRs #456–#446

This review covered the twelve newest merged pull requests at the frozen review
boundary `7550744` on 2026-08-21, ordered by merge time: #456, #455, #454,
#453, #452, #451, #450, #449, #443, #448, #447, and #446. It also reviewed
the direct first-parent documentation commits `7550744` and `173f1e0` that
landed after #456 inside that boundary. For every pull request, the review read
the linked issue contract, pull-request description, commits and landed diff,
then traced affected behavior through the current descendants. Direct
first-parent landings newer than the frozen boundary were excluded rather than
moving the batch while it was in progress. This report preserves only confirmed
current mistakes that still need one-at-a-time disposition.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [ ] PRR-1. Wrong-removal recovery can silently lose an identical stash entry
- [ ] PRR-2. Backlog review routes transient tracker bodies into repository worktrees
- [ ] PRR-3. The issue-approval dashboard path is outside the manifest's Haskell scan

## 1. Recovery stash retirement

### PRR-1. Wrong-removal recovery can silently lose an identical stash entry

> **Captured note:** Make PR #447's wrong-removal recovery prove that the
> pre-existing stash-entry multiset was restored, including two entries with
> the same object ID and the same message. Its current membership check can
> report success after one of those indistinguishable entries is lost.

**Verification:** A temporary repository built with the existing
`FastForwardStashTests` fixture was given two user stash entries with the same
`(commit, message)` pair around one drainer recovery entry. The retirement
call's `git stash drop` was redirected to the older duplicate, reproducing the
selector-shift race the recovery path is intended to survive. Before retirement
the stash held both identical user entries; afterwards it held only one, while
the log nevertheless said `Restored stash entry`. The reason is observable in
the current implementation: `git stash store` does nothing when the surviving
identical commit is already the stash tip, and `_restore_stash_entry` proves
only that one matching pair exists rather than that its prior multiplicity was
restored. The defect remains at current `master` (`a920f7c`).

**Evidence:**

- `tools/drain_prs.py:2915` — `_missing_entries` correctly treats stash entries
  as a multiset because duplicate `(commit, message)` pairs are valid.
- `tools/drain_prs.py:2932` — `_restore_stash_entry` is the recovery operation
  used after the wrong entry was removed.
- `tools/drain_prs.py:2941` — its own comment records that `git stash store` is
  a no-op when `refs/stash` already names the commit.
- `tools/drain_prs.py:2957` — the post-store proof reads the new stash but tests
  only whether a matching pair is present; it never compares counts against
  the pre-removal multiset.
- `tools/test_fast_forward_stash.py:1485` — the closest regression covers the
  same commit with a *different* message, which cannot exercise the
  indistinguishable-duplicate failure.

**Handoff context:**

- **Current behavior:** If a concurrent selector shift removes one of two
  identical user entries, recovery can leave only one copy while logging that
  the removed entry was restored.
- **Expected behavior:** A successful retirement preserves every non-target
  stash entry with its original multiplicity; if Git cannot restore an
  identical duplicate, the operation reports failure and recovery instructions
  instead of success.
- **Scope and constraints:** This is the wrong-removal rollback boundary from
  PR #447 / closed issue #431. Preserve the intended target retirement,
  verbatim messages, object reachability, and the rule that no unrelated stash
  entry may be removed or rewritten.
- **Verification target:** Add a fixture with two identical `(commit, message)`
  user entries, force the drop to remove one of them instead of the target, and
  assert either the full pre-existing multiset is restored or the operation
  emits the documented failure path without claiming success. The focused
  fast-forward stash suite remains green.
- **Deduplication:** Searches of open and closed issues for stash duplication,
  stash-store recovery, and restoration found the originating #431 and adjacent
  stash issues #22, #145, #200, #202, #223, and #247, but no issue tracking this
  identical-entry loss.
- **Remaining uncertainty:** None.

## 2. Backlog-review workflow hygiene

### PRR-2. Backlog review routes transient tracker bodies into repository worktrees

> **Captured note:** Correct PR #451's backlog-review workflow so the temporary
> body files required by its approved tracker mutations are created outside all
> repository worktrees and cleaned up. The rendered workflow currently
> contradicts both its own no-repository-write rule and the repository hygiene
> contract.

**Verification:** Static tracing of the canonical source and its pinned
regression shows a reachable contradiction. The Apply phase requires a body
file for `gh issue edit` and another for `gh issue comment`. The file-location
section then says the workflow should never write in the repository but directs
any needed file to `docs-wip`; if that branch is absent, its resolver explicitly
falls back to the primary checkout. Therefore every implementation of the
documented Apply phase either ignores the stated write-root rule or places a
transient tracker body in a repository worktree. The two rendered plugin assets
inherit this source verbatim, and `tools/render_command_sources.py --check`
confirms that this is the current shipped behavior.

**Evidence:**

- `tools/command_sources/backlog-review.md:83` — approved Updates and
  Needs-decision comments require `--body-file <file>`.
- `tools/command_sources/backlog-review.md:94` — the workflow says it should
  not write into the repository at all, then sends any needed file to the
  `docs-wip` worktree.
- `tools/command_sources/backlog-review.md:100` — the branch resolver falls
  back to the primary checkout when no `docs-wip` worktree exists.
- `tools/test_backlog_review_workflow.py:89` — the preservation assertions pin
  both the no-repository-write sentence and `docs-wip` as the write root, so the
  contract test currently enforces the contradiction.
- `CLAUDE.md:164` — repository hygiene requires scratch files to remain outside
  the tree.

**Handoff context:**

- **Current behavior:** Applying an approved body or comment can dirty
  `docs-wip`, or the primary checkout when that worktree is unavailable, with a
  transient file whose cleanup is not specified.
- **Expected behavior:** Transient tracker payloads live in a system temporary
  location outside every worktree, are passed safely to `gh`, and are removed
  after use; the workflow's file-location prose and regression assertions state
  that rule consistently.
- **Scope and constraints:** Correct the canonical source from PR #451 / closed
  issue #430, re-render both plugin assets, and update the behavior assertions.
  Preserve the mandatory approval stop, exact tracker mutation set, repository
  scoping, and prohibition on code changes.
- **Verification target:** Contract tests require an outside-the-repository
  temporary location and cleanup, reject both `docs-wip` and primary-checkout
  fallback for transient bodies, and the render check proves both bundles match
  the corrected source.
- **Deduplication:** Searches of all tracker states for `backlog-review`,
  `body-file`, temporary files, and `docs-wip` found the originating #430 and
  related workflow-vendoring issues, but no issue tracking this file-location
  contradiction.
- **Remaining uncertainty:** None.

## 3. Issue-approval manifest coverage

### PRR-3. The issue-approval dashboard path is outside the manifest's Haskell scan

> **Captured note:** Extend PR #443's load-bearing issue-approval discovery-path
> contract to the Haskell dashboard consumer. `ApprovalService.hs` constructs
> the fixed record path but is absent from the enumerated Haskell home-path
> surface and from the manifest row's owning files.

**Verification:** The current Haskell extractor recovers
`Library/Application Support/kanban/issue-approval/config.json` from
`src/Kanban/ApprovalService.hs`, and an in-memory mutation to an undeclared
`issue-approval-unmanifested/config.json` is correctly reported by
`undeclared_home_segments`. However, `ApprovalService.hs` is not a member of
`SURFACE_FILES`, so `test_every_home_relative_path_segment_is_documented` never
opens it and the same undeclared change would pass the tracked-tree completeness
loop. The non-vacuity control pins only the three Python modules. This also
falsifies the contract's explanation that no tracked source contains a composed
literal on which the manifest row could be grounded. The gap remains at current
`master` (`a920f7c`).

**Evidence:**

- `src/Kanban/ApprovalService.hs:248` — `approvalRecordPath` obtains the account
  home and appends the full fixed issue-approval discovery-record path.
- `tools/test_agent_workflow_contract.py:68` — the Haskell `SURFACE_FILES`
  enumeration omits `src/Kanban/ApprovalService.hs`.
- `tools/test_agent_workflow_contract.py:128` — the separate approval-service
  enumeration contains only the three Python owning modules.
- `tools/test_agent_workflow_contract.py:1402` — the completeness loop scans
  only those two enumerations, leaving the Haskell consumer unreachable.
- `tools/test_agent_workflow_contract.py:1425` — the approval-service
  non-vacuity check pins only the Python surface.
- `docs/agent-workflow-contract.md:1369` — the discovery-record manifest row
  names only `docs/issue-approval.md`, unlike adjacent managed-record rows that
  name their Haskell consumers.
- `docs/agent-workflow-contract.md:1495` — the manifest explanation says no
  tracked source carries a composed literal, although `ApprovalService.hs`
  does.

**Handoff context:**

- **Current behavior:** A future edit can move the dashboard to an undeclared
  home-relative issue-approval record path while the completeness and
  non-vacuity tests remain green, allowing the controller and dashboard to
  silently disagree.
- **Expected behavior:** Every tracked consumer that constructs this managed
  record location participates in the home-relative reconciliation, and the
  manifest/prose name the Haskell consumer accurately.
- **Scope and constraints:** This closes a specification and gate-coverage gap
  left by PR #443 / closed issue #425. Preserve the existing fixed-path behavior
  until a separately authorized platform migration; this finding is about
  declaring and policing the current path, not changing it.
- **Verification target:** A negative control proves that changing only
  `ApprovalService.hs` to an undeclared home-relative record path fails the
  tracked-tree completeness gate, while the manifest's files column and prose
  stay reconciled with every current builder/consumer.
- **Deduplication:** Searches of open and closed issues for `ApprovalService`,
  issue-approval manifest coverage, discovery records, and home-relative paths
  found the originating #425 and adjacent platform issues #357, #444, and #445,
  but no issue tracking this omitted Haskell surface.
- **Remaining uncertainty:** None.
