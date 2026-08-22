# Project Review Findings: PRs #297–#272

This review continued below the completed #299 cursor and covered the next
twelve merged pull requests by merge time: #297, #296, #295, #294, #293,
#292, #285, #286, #284, #279, #274, and #272. It also reviewed the direct
first-parent documentation commits `d0ca188`, `459b9b1`, and `f212bb7`
interleaved between #299 and #272. The batch was frozen at `master@3cbe5d7` on
2026-08-22. Master advanced through #466 while verification was running; that
newer landing was excluded rather than moving the boundary, and the finding
below was rechecked at current `master@39ca2e3`.

Each pull request was checked against its linked issue where one existed,
pull-request body, commits, landed diff, canonical review history, current
implementation, callers, and current tests. The direct commits were checked
against their patches and the current contract and ledger state. Later
descendants were read only to establish whether a mistake still exists. This
report preserves the one confirmed current mistake that still needs
one-at-a-time disposition.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [ ] PRR-1. A successful no-op ready command can roll back another actor's transition

## 1. Ready-transition ownership after a successful no-op

### PRR-1. A successful no-op ready command can roll back another actor's transition

> **Captured note:** Do not treat a successful `gh pr ready` return as proof
> that the review coordinator created the ready transition. Another actor can
> win the interval after the draft snapshot, making the command a successful
> no-op whose state the coordinator does not own.

**Verification:** PR #296 repaired the failed-command half of issue #276's
race by making `made_ready` depend on `mark_ready_for_review` returning. Its
canonical issue review explicitly excluded the mirror success path: another
actor can mark the PR ready after the initial verification, `gh pr ready` can
then succeed without changing it, and the coordinator sets `made_ready` anyway.
The implementation records that case as an accepted residual and still rolls
the transition back if the following publication verification fails.

The race was reproduced against both packaged coordinators with the existing
draft-transition test harness. The first publication verification observed a
draft; the ready-command mock then staged an external ready transition and
returned successfully, representing a successful no-op; the second
verification raised `WorkflowError("PR head changed after publication")`.
Both the Codex and Claude copies called `restore_draft` exactly once and
reported that draft state was restored. The external actor's ready transition
was therefore undone even though the coordinator had no evidence it created
it.

**Evidence:**

- `codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py:1204-1207`
  — a previously observed draft causes the ready command, and any normal return
  sets `made_ready` before the second verification.
- `codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py:1228-1244`
  — the comment names the successful-no-op race explicitly, after which
  `made_ready` unconditionally authorizes `restore_draft`.
- `claude-plugin/plugins/kanban/scripts/review_pr.py:1231-1234` and
  `:1256-1272` — the Claude coordinator carries the same behavior and explicit
  residual.
- `tools/test_pr_review_draft_transition.py:189-216` — confirmed-transition
  rollback coverage treats command success as ownership without staging the
  success-path interleaving.
- `tools/test_pr_review_draft_transition.py:218-268` — the concurrent-actor
  regression covers only a command that raises, which leaves `made_ready`
  false; there is no successful-no-op counterpart.
- Issue #276's canonical review, **Spec additions / clarifications** — the
  reviewer declared the success-path variant out of that issue's scope and
  described the same externally created ready state being returned to draft.

**Handoff context:**

- **Current behavior:** If another actor marks a draft PR ready after the
  coordinator's snapshot, a successful no-op `gh pr ready` makes the
  coordinator claim ownership. Any subsequent publication failure clears the
  verdict labels and returns that externally transitioned PR to draft.
- **Expected behavior:** A normal command return that may represent a no-op is
  not sufficient ownership evidence. Publication must never restore draft
  state unless it can establish that this invocation created the transition;
  alternatively, the flow can remove the need for a failure-prone step after
  the ready mutation so no ambiguous rollback is attempted.
- **Scope and constraints:** Preserve the linked-issue/head freshness checks,
  approval and changes-requested semantics, verdict-label cleanup, the
  confirmed-transition failure handling where ownership is actually known,
  and byte-equivalent behavior across both coordinators. Do not restore the
  failed-command state inference removed by #296; that has the same ownership
  flaw on a different return path.
- **Verification target:** Add a deterministic test beside the failed-command
  concurrency case for both brands: verification sees draft, another actor
  makes the PR ready, the coordinator's ready operation returns success as a
  no-op, and a later publication check fails. Assert that the external ready
  state remains and no failure message claims it was restored. Retain coverage
  for an unambiguously coordinator-owned transition and for parity between the
  two copies.
- **Deduplication:** Searches of all tracker states for concurrent ready
  transitions, successful no-op ready commands, `made_ready`, and draft
  rollback found only closed issue #276. Its approved spec deliberately
  excluded this success-path variant, and PR #296 repeats that exclusion. No
  separate issue or findings report owns the remaining race.
- **Remaining uncertainty:** GitHub exposes no creator identity for the ready
  state, and the same credentials may be used by both actors. The repair may
  therefore need to change transaction ordering rather than infer ownership
  from another state read.
