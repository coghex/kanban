# Kanban PR drainer findings

A running collection of observations about the PR drainer, with focused
repository evidence captured for later disposition through `process-report`.

Status legend: `[ ]` unprocessed · `[#N]` filed · `[no-issue]` closed without an issue · `[deferred]` blocked on a concrete precondition

## Status

- [x] DR-1. Queue-wide branch updates fan out CI after a merge — [#204]

---

## Chapter 1 — Queue scheduling and branch updates

### [#204] DR-1. Queue-wide branch updates fan out CI after a merge

> **Captured note:** when the pr drainer merges a pr, it fast forwards and triggers ci on every single open pr. this isnt right, it should only fast forward a pr when it is about to attemp the merge, when i have a dozen or so prs in the queue, it puts a heavy load on the remote docker ci, it should naturally only be doing a single pr at a time

**Verification:** Verified with a scope correction — advancing the default branch
makes the remaining approved queue report `BEHIND`; the drainer then updates
those remote PR heads one per polling cycle, and each update triggers PR CI.
This affects approved eligible PRs rather than literally every open PR.

**Evidence:**

- `tools/drain_prs.py:440` — `get_open_approved_prs` lists all open PRs but
  retains only those carrying `reviewed:approve` without `reviewed:changes`;
  this is the queue exposed to scheduling.
- `tools/drain_prs.py:625` — `choose_next_pr` selects the eligible PR with the
  oldest `last_attempt`, deliberately rotating to another ready PR after each
  attempt rather than keeping one candidate active through update, CI, and
  merge.
- `tools/drain_prs.py:2428` — `process_pr` handles `BEHIND` before evaluating
  the configured CI and review checks, calls `update_branch`, and ends that
  attempt without merging.
- `tools/drain_prs.py:1001` — `update_branch` invokes GitHub's
  `PUT /pulls/{number}/update-branch`, waits for the resulting synchronize
  policy, and updates the recorded approved head.
- `.github/workflows/ci.yml:3` — CI runs on every `pull_request` event, which
  includes the synchronize event produced by each branch update.
- `.github/workflows/review-gate.yml:3` — the review workflow explicitly runs
  on `synchronize` as well, adding another workflow run for every updated PR.
- `tools/test_pure_logic.py:204` and
  `tools/test_single_pr_drain.py:457` — focused tests pin both halves of the
  behavior: fair selection moves to the least-recently attempted PR, and a
  behind PR is updated as the whole action for one cycle rather than merged.

**Handoff context:**

- **Current behavior:** A successful merge advances the base. On later polls,
  fair rotation selects each approved PR now marked behind, updates that PR's
  remote head, waits for the update policy, and then moves to another
  least-recently attempted PR. A queue of a dozen approved PRs can therefore
  launch CI across the queue before the first updated candidate is revisited.
- **Expected behavior:** Keep work serialized around one merge candidate:
  update only the PR currently being advanced toward a merge, wait for its new
  head and gates, and avoid proactively synchronizing the rest of the queue.
- **Scope and constraints:** Preserve per-PR conflict isolation, failure
  backoff, the stale-approval decision after a head update, and the rule that a
  branch update and merge are separate irreversible actions. The `--pr` path
  already provides strict isolation and is documented at
  `docs/pr-drainer.md:181`; the polling service is the fan-out path.
- **Remaining uncertainty:** The repository does not state when a serialized
  candidate should be released so another PR may proceed—for example, while CI
  is pending, after CI fails, or immediately on a merge conflict. That queue
  policy needs to be specified without allowing one unhealthy PR to stall all
  others indefinitely.
