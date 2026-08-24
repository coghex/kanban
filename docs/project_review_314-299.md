# Project Review Findings: PRs #314–#299

This review continued below the completed #317 cursor and covered the next
twelve merged pull requests by merge time: #314, #312, #311, #310, #309,
#308, #307, #306, #304, #302, #300, and #299. It also reviewed the direct
first-parent documentation commit `cd76bf2` interleaved between #317 and #299.
The batch was frozen at `master@d0b6be2` on 2026-08-22. Master advanced through
#467 while verification was running; that newer landing was excluded rather
than moving the boundary, and both findings below were rechecked at current
`master@3cbe5d7`.

Each pull request was checked against its linked issue, pull-request body,
commits, landed diff, canonical review history, current implementation,
callers, and current tests. The direct commit was checked against its patch and
the current state of both design-document ledgers. Later descendants were read
only to establish whether a mistake still exists. This report preserves the
two confirmed current mistakes that still need one-at-a-time disposition.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [x] PRR-1. The durable GitHub process-group record has no cross-process transaction boundary — [#499]
- [x] PRR-2. Drainer status misclassifies the legacy stash name the drainer itself produced — [#508]

## 1. GitHub process-group ownership across dashboard processes

### [#499] PRR-1. The durable GitHub process-group record has no cross-process transaction boundary

> **Captured note:** Give the repository's durable `gh` process-group record a
> real cross-process check/register/update authority, or explicitly prevent a
> second dashboard from acquiring that repository. The current `MVar` protects
> only jobs created by one dashboard process.

**Verification:** Every dashboard creates a fresh `GhRecordLock`, whose mutex
is an in-process `MVar`. The record itself is global under the XDG cache root
and keyed only by repository identity. Two dashboard processes for the same
repository therefore use the same JSON file while holding unrelated locks.

There are two unsafe windows. First, each process can independently read an
absent record in `reclaimRecordedGhGroups` and then both proceed to spawn
`gh`; the absence check and registration of the new group are not one
cross-process acquisition. Second, every registration and removal rewrites a
whole list derived from a prior read, so independent processes can both read
the same list and let the later rename discard the other process's group.
That lost entry is exactly the possibly-live `gh` the durable record exists to
make a later fetch reclaim or refuse.

The whole-file loss was reproduced under an isolated `XDG_CACHE_HOME`: two
independent stale reads both returned `GhGroupRecordAbsent`; writing group 100
from the first view and group 200 from the second both returned `Right ()`,
while the final load contained group 200 alone. Atomic rename keeps the JSON
well formed, but it cannot serialize the transaction that composed it. The
current design's statement that the durable record and restart-time refusal
cover the cross-process boundary is therefore not true for two processes that
start or update concurrently.

**Evidence:**

- `src/Kanban/UI/Refresh.hs:227-228` — construction of a dashboard coordinator
  creates a new record lock for that process rather than acquiring a shared
  repository lease.
- `src/Kanban/GitHub/Guard.hs:62-94` — `GhRecordLock` is an `MVar` plus an
  `IORef`; both exist only in the current address space even though the comment
  describes the record as repository-scoped and durable.
- `src/Kanban/GitHub/Guard.hs:299-309` — `recordGhGroup` and `dropGhGroup` read
  the whole current list and replace it under that process-local mutex.
- `src/Kanban/GitHub/Guard.hs:327-366` — reclaim reads the shared record before
  acquiring any cross-process authority and later clears it under only the
  same local mutex.
- `src/Kanban/Cache.hs:205-229` — all processes for one owner/name identity
  resolve the same record path, while the writer accepts and replaces a
  caller-composed whole group list.
- `docs/design.md:1953-1962` — the contract promises no lost record entry and
  says the durable record plus reclaim refusal cover what the one-process
  coordinator does not schedule across processes.

**Handoff context:**

- **Current behavior:** Two dashboards opened against the same repository can
  both pass an absent-record check, run overlapping `gh` processes, and lose
  one live or unverified group from the shared record even though every
  in-process coordinator transition remains serialized.
- **Expected behavior:** Repository acquisition, prior-record reclamation,
  process-group registration, and every whole-record mutation are serialized
  across dashboard processes. A second process either waits, refuses safely,
  or proves the prior owner and its groups gone before spawning `gh`.
- **Scope and constraints:** Preserve the existing in-process scheduling,
  identity-pinned reclaim rules, atomic file replacement, unreadable-record
  refusal, cleanup budgets, and repository-identity keying. Locking only the
  write is insufficient because the absent-check-to-spawn window would remain;
  the cross-process authority must cover ownership acquisition as well as
  read-modify-write.
- **Verification target:** A barrier-controlled test starts two independent
  processes against one isolated cache root, pauses both after observing the
  same initial state, and proves that at most one can acquire permission to
  spawn while every live or unverified group remains durably represented.
  Include owner crash/restart, record removal, and different-repository cases
  so the authority neither leaks nor globally serializes unrelated boards.
- **Deduplication:** Searches of all tracker states for `gh` group records,
  cross-process refreshes, multiple dashboards, durable-record lost updates,
  and simultaneous GitHub work found closed issues #132 and #301. They own
  verified cleanup and the one-dashboard coordinator but no cross-process
  transaction. The card-filter design recorded the pre-coordinator
  same-process race that #301 fixed; no tracker item or findings report records
  this remaining independent-process race.
- **Remaining uncertainty:** Whether the intended product rule is a shared
  repository lease or an explicit one-dashboard-per-repository refusal is a
  design choice. The current unguarded check/write behavior is not safe under
  either interpretation.

## 2. Legacy drainer-stash recognition

### [#508] PRR-2. Drainer status misclassifies the legacy stash name the drainer itself produced

> **Captured note:** Recognize the exact legacy
> `drain-prs-autostash-<epoch>` payload in the read-only status inventory. It
> was emitted by previously installed drainer code and should not be
> classified as a merely similar user stash after an upgrade.

**Verification:** Before commit `7fb2c25`, the drainer's failed-preparation
path used `git stash push -m drain-prs-autostash-<epoch>`. PR #302's own
description identified a concrete 2026-07-18 entry in that form and warned that
its implementation left the very snapshot named in issue #247's Background
invisible. The canonical amendment had accidentally narrowed classification to
the two payloads the then-current implementation produced, and the PR followed
that wording despite the upgrade artifact already present in the checkout.

Current code still has only the epoch-plus-PID and recovery-message patterns.
Calling `drainer_stash_message` with both the raw legacy payload and Git's
`On master: ` wrapper returns `None`; the epoch-plus-PID form is recognized.
The regression suite now explicitly lists the exact epoch-only payload among
user-created near misses. This is not an ambiguous prefix proposal: the old
form has a complete digits-only grammar and was a reserved message generated
by the project itself. As with both current forms, a manually forged exact
payload is inherently indistinguishable because Git records no creator.

**Evidence:**

- Historical `tools/drain_prs.py` at `b9b427c:1188-1197` — the drainer created
  `drain-prs-autostash-<epoch>` with `git stash push -m`.
- `tools/drain_prs_service.py:53-70` — the status classifier declares only the
  current epoch-plus-PID and recovery forms as drainer messages.
- `tools/drain_prs_service.py:1624-1634` — after stripping Git's branch
  wrapper, an entry is reported only when it full-matches those two patterns.
- `tools/test_drain_prs_service.py:3667-3684` — the exact historical
  `drain-prs-autostash-1700000000` payload is asserted to be a user entry.
- `docs/pr-drainer.md:419-427` — current user documentation says status names
  every entry the drainer stored but enumerates only the two newer forms.
- PR #302, `One thing to flag` — the implementing agent documented the old
  producer, the live legacy entry, and the resulting omission before merge.

**Handoff context:**

- **Current behavior:** An upgraded installation can retain a possibly-sole
  stash entry made by the older drainer while `status` reports no drainer stash
  for it and the tests insist that its reserved payload belongs to a user.
- **Expected behavior:** The read-only inventory recognizes every exact stash
  payload a supported prior drainer emitted, including the epoch-only legacy
  form, while continuing to exclude prefixes, suffixes, malformed digits, and
  ordinary user messages.
- **Scope and constraints:** Add compatibility recognition only; do not reap,
  reorder, rewrite, or retire the legacy entry. Preserve independent tri-state
  inventory failures, strict parsing, Git wrapper handling, and the existing
  caveat that a user-forged exact reserved message cannot be distinguished.
  Document the legacy form as such rather than implying current code still
  creates it.
- **Verification target:** Real temporary-Git fixtures create raw and wrapped
  epoch-only entries, prove both appear with selector and date, and sweep
  adjacent malformed and merely similar names to prove they remain excluded.
  Pin the recognized legacy set independently from the current writer set so a
  future format migration cannot silently forget old recovery artifacts again.
- **Deduplication:** Closed issue #247 and PR #302 are the originating status
  work, but neither tracks this knowingly omitted compatibility case. The
  terminal `[no-issue]` disposition for PROD-17 in
  `docs/product_readiness_findings.md` records that this checkout's five stale
  snapshots were manually cleared; it does not repair or own the classifier
  used by upgraded installations. Searches of all tracker states and all
  findings reports found no issue or separate compatibility finding.
- **Remaining uncertainty:** None.
