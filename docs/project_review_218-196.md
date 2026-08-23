# Project Review Findings: PRs #218–#196

This review continued below the completed #219 cursor and covered the next
twelve merged pull requests by merge time: #218, #215, #214, #213, #212,
#211, #210, #209, #208, #207, #197, and #196. It also reviewed the direct
first-parent commits `0bf2a34`, `eeb981e`, `4525a35`, `ed07883`, `b46658f`,
`4b2ce37`, `0ae444d`, `dfb5c23`, and `ffa6e00` interleaved between #219 and
#196. The batch was frozen and verified at `master@2e2003e` on 2026-08-22.
Origin advanced by two documentation-only landings to
`docs/project_review_456-446.md` while validation was running; those newer
commits were excluded rather than moving the boundary, and they do not touch
the finding below.

Each pull request was checked against its linked issue where one existed,
pull-request body, commits, landed diff, canonical review history, current
implementation, callers, and current tests. The direct commits were checked
against their patches and the current contract, design, and findings-ledger
state. Later descendants were read only to establish whether a mistake still
exists. This report preserves the one newly confirmed current mistake that
still needs one-at-a-time disposition. The native-sub-issue partial-response
loss found during PR #215's review, the autostash deletion race found during
PR #212's review, and PR #218's successive clipping defects were all repaired
before merge. The direct issue/pull-request number guards now have focused
tests in both plugin bundles, and the interleaved PH, DR, and UI findings have
all reached terminal dispositions, so none is duplicated here.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [x] PRR-1. An in-flight CI rerun can be requested repeatedly and exhausted from one stale failure — [#474]

## 1. Automatic CI rerun lifecycle

### [#474] PRR-1. An in-flight CI rerun can be requested repeatedly and exhausted from one stale failure

> **Captured note:** Make the durable `ci_rerun_active` state authoritative on
> the next polling pass: do not request or consume another retry until the
> previously requested rerun has observably finished.

**Verification:** Direct commit `dfb5c23` added a three-attempt automatic CI
rerun policy, and PR #214 subsequently made a requested rerun an active-lane
barrier. The state records `ci_rerun_active = True` after `gh run rerun`
returns, and the polling loop uses that flag to select the short 60-second
cadence. The next call to `rerun_failed_ci`, however, never reads the flag. If
GitHub's next pull-request snapshot still exposes the same completed failure,
the function increments the attempt count and calls `gh run rerun --failed`
on the same run id again.

A focused reproduction seeded one failed `build-test` check and passed the
same unchanged snapshot through `rerun_failed_ci` four times. The decisions
were `[True, True, True, False]`: three `gh run rerun` calls were made for run
`12345`, then the fourth observation marked the approved head exhausted. The
second call began with `ci_rerun_active = True`; that state made no difference.
Thus one completed failure can consume the entire three-attempt allowance
without three completed reruns. If GitHub refuses a duplicate request because
the first rerun is still running, the `gh` exception instead becomes an
operational failure; the resulting cooldown can release the active lane on a
later pass while that rerun is still in flight.

This contradicts the current queue contract inherited from issue #204 and PR
#214: a failed check is skippable only when no rerun is already in flight, and
a requested rerun owns the active lane while pending. The bug is timing-
dependent because GitHub may replace the failed rollup before the next poll,
but the durable flag exists precisely to carry knowledge of the request across
polls and restarts. Ignoring it makes correctness depend on that remote update
becoming visible within the polling interval.

The focused Python sweep passed 860 tests and the full Haskell suite passed
1,554 examples. Existing coverage proves that the first request takes the
lane, that the lane uses the shorter cadence, and that a state manually set to
the retry cap is skipped. It never runs a second pass with
`ci_rerun_active = True` and the old failed rollup still visible, so the
repeated-request path remains green.

**Evidence:**

- `tools/drain_prs.py:1079-1097` — the retry function resets state for a new
  head and checks only the numeric attempt cap; it does not branch on
  `ci_rerun_active` before reusing the latest failed check's run id.
- `tools/drain_prs.py:1099-1125` — every below-cap call increments the count,
  invokes `gh run rerun --failed`, and only afterward records the same head as
  active. A later call can therefore repeat the same transition unchanged.
- `tools/drain_prs.py:4222-4242` — every failed CI snapshot enters
  `rerun_failed_ci`; there is no separate in-flight path before another
  request or the terminal `checks_failed` refusal.
- `tools/drain_prs.py:4849-4858` — the polling loop does recognize
  `ci_rerun_active` to shorten its sleep, proving the flag is durable lane
  state rather than an unused migration field; the decision reached after
  that sleep is where it is ignored.
- `tools/test_pure_logic.py:105-167` — the unit coverage asserts one initial
  request and then jumps the counter directly to the cap. It never calls the
  function again in the active below-cap state.
- `tools/test_integration.py:3944-3989` — integration coverage ends immediately
  after the first request and asserts the lane and cadence. There is no next
  polling pass over the still-failed snapshot.
- `docs/pr-drainer.md:646-661` and `:859-869` — the documented contract calls
  a just-started automatic rerun a waiting barrier and releases the lane only
  after its reruns are actually exhausted.

**Handoff context:**

- **Current behavior:** A failed rollup below the numeric cap always requests
  another rerun, even when durable state says a prior request for that head is
  active. Repeated visibility of the same failure can duplicate the command,
  consume multiple attempts, falsely quarantine the head, or turn a normal
  in-flight wait into an operational-failure cooldown.
- **Expected behavior:** Once a rerun is requested, the candidate remains a
  `checks_pending` barrier without another mutation until the system can
  distinguish a completed retry result from the failure that triggered it.
  The cap counts distinct rerun attempts that actually completed and failed,
  not repeated observations of one triggering check. That state must survive
  a drainer restart.
- **Scope and constraints:** Keep the three-attempt cap, short cadence,
  oldest-first lane ownership, fail-closed unknown-mutation handling, and
  `--pr` result schema. Do not infer completion merely from elapsed time. The
  shared helper also serves repeated `--pr` invocations, so they must not issue
  a duplicate request for the same active attempt either.
- **Verification target:** Add a two-pass integration case in which the first
  pass requests a rerun and the next still receives the old failed rollup; it
  must make no second `gh run rerun` call, retain `active_pr`, preserve the
  attempt count, and remain a barrier. Cover the same state after reloading the
  queue file, then prove that a separately identified completed failed retry
  consumes exactly one further attempt and that only three distinct requested
  rerun attempts which later completed as failures exhaust the head.
- **Deduplication:** Searches across all tracker states and every findings
  report found no item owning repeated automatic-rerun requests or exhaustion
  from an in-flight snapshot. Closed issue #204 is the governing queue contract
  and expressly requires an already-in-flight rerun to remain a barrier; it
  does not record this implementation gap. Closed issue #4 concerns Haskell
  board-side rollup deduplication of queued reruns with null timestamps, not
  the Python drainer's mutation and durable retry state.
- **Remaining uncertainty:** The best completion identity is not established
  by this review. The fix may need the Actions run's attempt/status metadata or
  another durable observation key; whichever representation is chosen must
  prove that the failure belongs to a later completed attempt before spending
  the next allowance.
