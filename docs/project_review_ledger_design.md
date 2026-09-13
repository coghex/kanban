# Project review ledger design

Replace the bounded, twelve-PR historical sweep with a repository-local ledger
and a one-PR review operation, shared by Kanban's Codex and Claude workflows.
Hetoimasia is the primary new consumer and has no prior reviews according to
the owner; Kanban and Synarchy also need the same behavior and truthful legacy
coverage migration.

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. Establish a repository-local rolling project-review ledger
- [ ] LEDGER-1. Enroll the design document in §7 and its sibling registries
- [ ] LEDGER-2. Add the ledger document, its rendering, and its migration
- [ ] LEDGER-3. Select one PR from a complete inventory
- [ ] LEDGER-4. Take, renew, release, and take over a session-bound lease
- [ ] LEDGER-5. Record a completed attempt, allocate reports, link fixes, checkpoint
- [ ] LEDGER-6. Rebuild the project-review workflow on the ledger
- [ ] LEDGER-7. Add auto-project-review

## Epic contract

- **Goal:** Operators can see every merged PR's review status and last review
  evidence, while repeated invocations first cover never-reviewed PRs, then
  convert legacy reviews highest-PR-number first, and finally refresh the
  least recently reviewed work.
- **Done when:** Both packaged workflows select and durably record exactly one
  merged PR per invocation; their serial automation obeys a requested count or
  continues without a count; ledger rows distinguish clean, findings-bearing,
  never-reviewed, and legacy-reviewed work without inventing evidence.
- **Users and operators:** All projects consuming the Kanban workflows,
  explicitly including Kanban, Synarchy, and Hetoimasia.
- **Arc label:** None proposed.

## Current state and evidence

Verified in `/Users/vincentcoghlan/work/kanban`:

- `tools/command_sources/project-review.md` is the authored workflow source.
  It currently defaults to twelve units and uses an exclusive older boundary.
- `tools/render_command_sources.py` renders that source into
  `claude-plugin/plugins/kanban/commands/project-review.md` and
  `codex-plugin/plugins/kanban/skills/project-review/SKILL.md`.
- The packaged `project_review_cursor.py` helpers store per-repository
  reviewed-number sets, exclusions, and endpoints in
  `docs/project_review_boundaries.md`. The boundary's `merged_at` value is a
  PR merge timestamp, not a review timestamp.
- `report_coverage` recovers only filename endpoints from historical reports.
  It does not import the explicitly enumerated interior PRs in their prose.
  Synarchy's `project_review_1455-1424.md`, for example, explicitly lists
  eleven reviewed interior PRs that the selector still treats as uncovered.
- `tools/test_project_review_workflow.py` covers the current selection,
  persistence, packaging, and rendered instructions.
- Pre-merge `pr-review` is a separate workflow and is not the target here.
- An initial all-state Kanban tracker search for project-review ledger work
  found no clearly overlapping arc. Repeated at readiness on 2026-09-12:
  open-issue searches for `project-review`, `review ledger`, `sweep
  cursor`, and `auto-project-review` return only epics on other subjects;
  the nine open epics are #290, #354, #373, #412, #512, #534, #591, #597,
  and #642. Epic #373 vendored the existing workflow as a tracked asset
  (its VEND-4, #462, is done) and #548 shipped the v2 cursor, both closed;
  neither changes the workflow's operating model, so this umbrella
  duplicates nothing.

Verified on 2026-09-12 for the persistence and recovery questions:

- The cursor is `docs/project_review_boundaries.md` in the reviewed
  repository's `docs-wip` worktree: a Markdown header, a
  `<!-- project-review:cursor:v2 -->` marker, and one fenced JSON payload
  parsed strictly by `project_review_cursor.py`. Per repository it holds
  `pr.endpoint`, `pr.reviewed`, `direct.endpoint`, `direct.reviewed`, and
  `excluded`. The helper migrates the original hand-authored `stop before PR
  #N` document and the version-1 machine cursor on read, and rewrites the
  canonical form only on the next successful `record`. Writes are atomic
  (`os.replace`). An unreadable or foreign cursor raises `CursorError`
  before selection; only a missing document is treated as "never swept".
- The workflow leaves the cursor and every report uncommitted in the docs
  worktree by design ("the cursor is durable because it is on disk, not
  because it was landed"). Kanban's cursor is committed on `docs-wip` but has
  never landed on `master`, and neither it nor this design document has a row
  in `docs/agent-workflow-contract.md` §7. Each historical
  `docs/project_review_*.md` report is classified individually as
  `coordination` / `audit-report` there.
- `record` is written last, after the report is validated, so a failed report
  or a failed write is never a completed batch. `record` merges rather than
  replaces, refuses an empty `--reviewed` with an empty `--exclude`, and
  refuses a unit absent from a `gh pr list` page that came back at its own
  `--listing-limit`. Nothing is written at selection time, so an interrupted
  batch leaves no trace and no claim.
- Direct mode (first-parent commits that predate the PR workflow) shares the
  document with its own moving older-history frontier and `reviewed` SHAs.
  Kanban's direct state is empty; no `project_review_direct_*` report exists
  in Kanban.
- The helper is bundled twice — `claude-plugin/plugins/kanban/scripts/` and
  `codex-plugin/plugins/kanban/skills/project-review/scripts/` — and the
  workflow resolves its own copy from the plugin install location, never from
  the reviewed repository. `auto-project-review` exists nowhere yet; this
  design is its only mention.
- Coverage arithmetic for Kanban, the repository with the most history:

  | Merged PRs | In `pr.reviewed` | Report filename endpoints | Union |
  |-----------:|-----------------:|--------------------------:|------:|
  | 342 | 39 | 38 | 71 |

  Every report's opening paragraph enumerates the exact PRs its batch
  reviewed (`docs/project_review_602-562.md` names all twelve), and twenty
  such reports exist. Under D-2 with no boundary, the roughly 270 merged PRs
  outside that union become the never-reviewed queue unless the migration
  imports prose-enumerated interior PRs as `[legacy]` — the choice Q-6 asks.
  The cursor module's own docstring records that a report's prose about
  direct commits inside its interval has been wrong; it records no case of
  a report's PR enumeration being wrong.
- A report's enumeration is not bounded by its filename interval. Synarchy's
  `docs/project_review_432-412.md` opens by naming #432, #442, #444, #431,
  #430, #425, #420, #419, #417, #416, #413, and #412 in merge order; #442 and
  #444 lie above the interval because number order and merge order differ.
  Any parser that refuses an out-of-interval PR would drop real coverage.
- The workflow source (`tools/command_sources/project-review.md`, the
  "Destination and validation" section) currently says "Do not commit,
  publish, or push the report or the cursor unless the user separately
  requests publication". D-10's checkpoint commit changes that sentence.

The root repository instructions require workflow behavior changes to carry
regression tests and stay consistent with `docs/design.md` and the external
workflow contract. The existing implementation-state section was checked;
the mission runner is a separate implemented facility, not evidence that this
project-review ledger already exists.

## Scope

### In scope

- The `project-review` workflow in both bundles, rendered from its one
  source, rebuilt as a one-PR review over the ledger.
- A new `auto-project-review` workflow in both bundles.
- The bundled helper: ledger schema, migration from every prior cursor form
  and from report prose, complete-inventory selection, the session-bound
  lease, token-fenced record and report allocation, per-finding fix links,
  and the path-scoped checkpoint commit.
- The external workflow contract's description of the workflow, and the
  §7 and consumer-side classification that lets the workflow's documents
  publish.
- Regression tests for every behavior above, in the Python suite's
  established shapes.

### Out of scope

- The pre-merge `pr-review` gate and its drainer integration.
- Running any review, migrating any consumer's ledger, or starting an
  indefinite automation run as part of delivery.
- History archival, and any change to how the existing thirty-one reports
  are classified or named.
- Direct-commit review behavior beyond preserving it and making it
  explicit-only.
- Kanban's TUI: nothing in the board reads the ledger.

## Design

The scheduling model is decided (D-2, D-4, D-8), and so is the persistence
and recovery core (D-9 through D-12): one ledger document per repository
with a readable table, validated machine data, and compact history; a
migration that imports explicit legacy coverage; a complete inventory before
every selection; a checkpoint commit after every completed review; and an
expiring owner-token claim taken before review effort is spent.

### Ledger document

`docs/project_review_ledger.md` in the reviewed repository's `docs-wip`
worktree supersedes `docs/project_review_boundaries.md`. It keeps the proven
shape — a Markdown body, a versioned marker, and one strictly parsed fenced
JSON payload the helper owns — and adds a rendered per-repository table
above the payload: one row per merged PR with number, title, status
(`✓`, findings, never reviewed, or `[legacy]`), the verification commit, the
completed-review timestamp, the report link where one exists, and any
verified fix link. Behind the current row the payload keeps a compact
history of completed attempts (timestamp, verification commit, outcome,
report link), so a refresh never erases the previous clean verification's
date and hash (D-10). Migration reads the hand-authored boundary document,
the v1 cursor, and the v2 cursor, and the prose enumerations of the sibling
reports (D-9); the old cursor is preserved until the migrated ledger is
written successfully, and the exclusive boundary survives only as migration
provenance. `excluded` survives unchanged.

### One review, end to end

A single invocation runs in this order. Every step names the decision that
governs it.

1. **Inventory.** Page the complete merged-PR history; stop on failure or
   an incomplete listing (D-11).
2. **Select.** Apply D-8's order to the ledger and inventory; take an
   expiring owner-token claim on the chosen PR under the helper's lock
   (D-12); start the session-bound heartbeat (D-17).
3. **Pin.** Fetch, resolve the remote default-branch head to a full SHA,
   and create a detached temporary worktree at it; stop if the fetch fails
   (D-13).
4. **Review** the PR's diff against that exact tree; for a PR with earlier
   reports, compare each finding with their PRR entries (D-14).
5. **Report** only genuinely new findings, in a report whose per-PR sequence
   number the helper allocates atomically (D-14).
6. **Record** the completed attempt — outcome, verification SHA, UTC
   timestamp, report link, repeated-finding links, recurrences, and any
   verified per-finding fix links (D-5, D-14, D-15) — presenting the claim's
   owner token; a token that no longer owns the claim is refused (D-12).
7. **Checkpoint** the ledger and report changes as one path-scoped local
   commit on the docs worktree's branch (D-10).
8. **Clean up.** Stop any process the review started, release the claim,
   remove the temporary worktree; if removal fails, report the retained
   path (D-13).

Direct-commit mode is a separate explicit invocation with its own frontier
and never a step of this sequence (D-16).

### Lease lifecycle (D-12, D-17)

The claim is a lease renewed by a regular heartbeat independent of review
phases, because a long build or test outlives any phase-boundary renewal.
`claim` starts a renewer that rewrites the lease's expiry every `renewal`
seconds while the review session's liveness signal is held; cancellation,
session termination, or loss of that signal stops renewal, and the lease
lapses after `expiry`. Both intervals default to 60 seconds and 15 minutes,
may be given per-repository defaults in the ledger, are overridden by
invocation flags, and are written into the claim so a later change to a
default never alters an existing claim.

Takeover of an expired claim is one compare-and-swap under the helper's
lock: the taker verifies the expiry has passed, replaces the owner token,
and appends a `takeover` entry to the row's history naming both tokens and
the time. Thereafter the former owner cannot publish: its `renew`, `record`,
checkpoint commit, and report allocation all present the old token and are
refused, while its cleanup — stopping its own processes and removing its
own worktree — still runs and touches nothing the replacement owns.

History is never truncated. The visible table shows only each PR's current
row; the payload keeps every attempt, takeover, repeated-finding link, and
recurrence as self-contained entries. The first delivery does not archive;
if a repository's payload ever needs it, archival must preserve every
report link and evidence reference, which the self-contained entry format
makes mechanical.

### Proposals (not decisions)

None live. Every open question is resolved and the delivery slices are
approved (D-19).

## Decisions

### D-1. Shared implementation, separate repository records

The owner explicitly approved implementing this behavior in `coghex/kanban`
for both Codex and Claude, for use by all consuming projects. A project's
ledger belongs to that project, not to the installed plugin or another
consumer. Hetoimasia requires a clean first-use path with no legacy history.

### D-2. One merged PR per project-review invocation

`project-review` performs one review, not a batch of twelve. It first selects
never-reviewed merged PRs, newest-first in merge order. Once that queue is
empty, it converts legacy entries according to D-8. Once both queues are empty,
it selects the least recently reviewed PR. The old stopping boundary is not
the new scheduler's operating model. The existing pre-merge
`pr-review` gate remains distinct and unchanged by this request.

### D-3. Recognize truthful legacy coverage

Every PR known for a fact to have been reviewed receives a `[legacy]` label.
The skill has an explicit legacy-handling section and treats these as reviewed
for first-pass scheduling, not as never-reviewed work. Do not infer that every
PR numerically between a report filename's endpoints was reviewed. Do not
invent missing dates, commit hashes, or clean approvals. Preserve available
review evidence and findings links. The owner explicitly corrected the earlier
proposal that would have treated all legacy entries as requiring initial
verification.

### D-4. Last review means last completed attempt, not last approval

The scheduling timestamp is the time of the last completed review whether its
outcome is clean or has findings. Findings-bearing work therefore moves behind
older completed attempts instead of monopolizing the queue. With a stable
multi-PR inventory and completed serial reviews, a PR cannot immediately
repeat; a one-PR repository necessarily repeats that PR in refresh mode.

### D-5. A checkmark records a clean verification against a specific commit

Each merged PR has one visible ledger row. A clean review displays a checkmark,
the exact Git commit against which it was verified, and a date and time. A
review with problems has no checkmark and links the Markdown report containing
the problems. Its completed-review timestamp still participates in scheduling.
The reviewed commit and the PR's own merge commit are distinct concepts.

### D-6. Serial automation owns repetition

`auto-project-review N` runs the one-review workflow N times in sequence.
Without an integer argument it continues indefinitely until stopped. The
single-review workflow itself does not start another review. This request does
not authorize starting an indefinite review run while implementing the skills.

### D-7. Fix provenance is not automatic approval

The owner wants merged fix PRs linked where practical. A fix link is evidence,
not a replacement for fresh verification of the original finding. A merged
fix alone does not turn a findings-bearing row into a clean checkmark. The
maintenance mechanism for these optional links is not yet chosen.

### D-8. Convert legacy reviews highest PR number first

The owner explicitly approved the following priority order:

1. Never-reviewed merged PRs, newest-first in merge order (D-2).
2. Remaining `[legacy]` PR entries, highest PR number to lowest PR number.
3. Non-legacy entries, oldest completed-review timestamp first (D-4).

Process one legacy PR per invocation. Its fresh completed review converts the
current row to a non-legacy clean or findings-bearing review, with a new actual
last-review timestamp and verification commit. This conversion does not
require a clean outcome: a findings-bearing completed review also leaves the
legacy queue. Merely selecting or starting a PR is not a completed conversion.

Priority is reevaluated on each invocation: a newly merged never-reviewed PR
takes priority over legacy conversion and ordinary refresh. Legacy ordering
uses PR numbers explicitly, not merge dates; the owner chose this distinction.

### D-9. Legacy migration imports explicit reviewed-PR lists

Approved 2026-09-12. The migration imports the cursor's recorded set and
every PR a report's prose explicitly identifies as reviewed — the scope
enumeration in its opening paragraph — as `[legacy]` rows, preserving the
source report as the row's evidence. It does not import arbitrary PR
mentions from findings or deduplication sections. There is no
filename-interval restriction: Synarchy's `project_review_432-412.md`
reviewed #442 and #444 above its interval because number order and merge
order differ, and a parser that refused them would drop real coverage.
Ambiguous prose is flagged for the operator's confirmation, never silently
accepted or discarded. This is what D-3 meant by "known for a fact"; D-3
never intended filename endpoints only.

Consequences: the migration needs a parser for the scope enumeration with
an explicit "ambiguous" outcome and a confirmation step; most of Kanban's
history becomes `[legacy]` rather than never-reviewed; the migration's
result is verifiable by comparing each row's evidence report to its prose.

### D-10. One readable ledger per repository, checkpointed after every review

Approved 2026-09-12. Each repository owns one
`docs/project_review_ledger.md` with a readable table and strictly validated
machine data, updated atomically, with the old cursor preserved until the
migration succeeds. Compact review-history records are retained behind the
current-row table so a refresh never erases the previous clean
verification's date and hash. After each completed review the workflow makes
a local checkpoint commit on the docs worktree's branch containing only that
review's ledger and report changes; it never pushes. This gives stronger
recovery than leaving everything uncommitted.

Consequences: the checkpoint commit replaces the workflow's current "do not
commit the report or the cursor" rule and must leave unrelated dirty
docs-worktree files untouched (path-scoped `git add` and `git commit`); the
history records are never truncated (D-17); each consumer still decides
whether and how its ledger publishes, and Kanban's ledger has no §7 row yet
(Q-15, LEDGER-6).

### D-11. Complete paginated inventory before every selection

Approved 2026-09-12. Selection is preceded by a complete paginated listing
of the repository's merged PRs. If the listing fails or is incomplete, the
run stops without claiming that all PRs are covered. An incremental scan
keyed on the highest known PR number is rejected: an older-numbered PR can
merge later.

Consequences: the helper pages until a page comes back short and refuses on
any page returned at its limit without exhaustion; the payload records the
known universe so a shrunken listing is detectable; Synarchy pays roughly
fifteen pages of a hundred per invocation.

### D-12. An expiring claim is taken before review effort is spent

Approved 2026-09-12. Selection writes a claim with an owner token and an
expiry, and the owner renews it while the review runs. The guarantees the
owner named are the contract:

- two agents cannot actively claim the same PR;
- a crashed agent's claim can be recovered;
- an expired or replaced owner cannot later overwrite the replacement's
  result;
- claiming a PR does not change its last-review timestamp;
- only a successfully recorded, completed review counts toward `N`;
- a completed review with findings counts, an interrupted review does not;
- automation stops and reports progress on an unrecoverable refusal.

Comparing timestamps after two agents finish was rejected as weaker and as
wasting an entire review.

Consequences: claim and record become compare-and-swap writes on the ledger
under a lock the helper owns, since two atomic replaces can still lose each
other's claim; the claim carries the owner token that `record` must present;
the expiry length, renewal cadence, and recovery path are settled by D-17.
The owner confirmed on 2026-09-12 that the checkpoint commits and
helper-owned locking are what they want.

### D-13. The review is pinned to a detached temporary worktree

Approved 2026-09-12. The workflow fetches, resolves the remote
default-branch head to a full SHA, creates a detached temporary worktree at
that SHA, performs the review against that exact tree, and records that
full SHA as the verification commit. It never depends on the primary
checkout remaining unchanged. If the fetch fails the run stops; an older
local ref is never silently substituted. The owned worktree is cleaned up
after completion or failure, after stopping any process the review
started. If cleanup fails, the run reports the retained path for recovery
rather than claiming removal.

Consequences: the worktree lives outside the primary checkout and the docs
worktree; every failure path — refusal, crash, takeover — runs the same
cleanup; the row stores the verification SHA beside the PR's merge commit.

### D-14. Finding identity is reused; new reports take per-PR sequence numbers

Approved 2026-09-12. A repeated finding links to its existing report and
finding key rather than being filed again. A new report contains only
genuinely new findings and is named with a per-PR sequence number the
ledger helper allocates atomically; an existing filename is never reused.
Review records keep real UTC timestamps, but filename uniqueness never
depends on them. Existing reports and their processing checklists are never
overwritten. A finding that was resolved and whose defect later returns is
recorded explicitly as a recurrence linked to the original, not as an
unresolved duplicate. Finding references must be reliably navigable: a
Markdown heading is not assumed to create an anchor matching its `PRR-k`
key.

Consequences: the first report for PR `N` is
`docs/project_review/<N>.md` and later ones `docs/project_review/<N>_<k>.md`
with `k` from the ledger (directory per D-18);
a reference is a report path plus a key that the helper verifies against
the report's `### PRR-k.` heading at record time, and the rendered table
links the file rather than a fragment; a recurrence carries a
`Recurrence of: <report> PRR-k` line in its handoff context and a
`recurrence` entry in the row's history.

### D-15. Optional per-finding fix links ship in the first delivery

Approved 2026-09-12. `record --fixed <report>#PRR-k=<PR>` attaches a fix
link to one finding, recorded only when the reviewer verified that the fix
PR merged in the correct repository and that its correction is present in
the pinned review revision. Missing fix attribution never blocks an
otherwise completed review. Fix links are provenance: they grant no
checkmark and never imply that every finding on the original PR is
resolved (D-7).

Consequences: the helper validates the report path, the key, and that the
named PR is merged in `$REPO` before accepting the link; the row displays
per-finding links only.

### D-16. Direct-commit mode is explicit-only and kept separate

Approved 2026-09-12. There is no automatic transition from PR review into
direct-commit review. Existing direct-review progress (frontier and
reviewed SHAs) is preserved separately through migration, never discarded,
and direct commits are never mixed into the PR table.

Consequences: `direct` remains its own key in the payload with its current
semantics; the scheduler's queues are PR-only; a direct review is its own
invocation and gets no ledger row.

### D-17. Session-bound heartbeat lease, automatic recorded takeover, no truncation

Approved 2026-09-12 with a lifecycle correction. The lease renews every 60
seconds and expires after 15 minutes by default. The ledger may carry
per-repository defaults; invocation flags override them and take
precedence; the claim records its effective settings, and changing a
default never silently changes an existing claim. Takeover is automatic on
the next selection once a claim has expired, performed atomically under
the helper's lock, recorded as an ownership transition, and needs no manual
intervention for ordinary crash recovery. There is no archival in the first
delivery: all history is preserved as self-contained entries behind a
compact current-state table, and nothing is silently truncated.

The correction: a detached renewer does not die because the agent stopped,
and an orphaned renewer would extend a dead claim forever. Renewal is
therefore tied to the actual review session's lifetime — not merely to the
long-lived Codex or Claude application process. Cancellation, session
termination, or loss of the owner-liveness signal stops renewal, while a
long-running build or test keeps receiving renewals as long as its owning
review session is alive. This is an explicit, tested requirement.

Verified guarantees, each owed a behavioral test:

- an expired or replaced token cannot renew, record, allocate a report, or
  publish a checkpoint;
- token validation and the protected mutation cannot race with takeover;
- the former owner's cleanup touches only its own resources, never the
  replacement owner's worktree, reports, or claim;
- crash recovery, cancellation, takeover, and late completion by the former
  owner are each covered.

Consequences: the renewer needs an owner-liveness signal it can lose — a
session-scoped handle the workflow holds open, whose closure the renewer
observes — rather than a parent pid it inherits from the application; every
protected mutation is one validate-and-mutate step inside the lock; cleanup
resolves its targets from the attempt's own record, never from the row's
current owner. The settings block, the takeover entry, and the liveness
mechanism belong to LEDGER-4.

### D-18. Ledger-era documents live under one publishable directory

Approved 2026-09-12. The ledger and every new ledger-era report live under
`docs/project_review/`, classified by one directory-level publication
row. Existing reports stay where they are with their links preserved, and
their verified coverage is imported without moving them. Temporary
worktrees, process-control files, locks, and every other runtime artifact
stay outside that publishable directory. The workflow must work in a new
repository such as Hetoimasia without a registry edit per report.

Consequences: the ledger is `docs/project_review/ledger.md`, a PR's
reports `docs/project_review/<N>.md` and `docs/project_review/<N>_<k>.md`;
Kanban's §7 row, `EXCLUDED_TRACKED_PATHS` entry, and `config.toml.example`
entry name the directory once, with a tracked seed so the directory exists
before the workflow writes to it; a consumer enrolls the directory through
one `direct_publication_paths` entry; the lock and the liveness handle live
under the helper's managed runtime root, never in `docs/`.

### D-19. Seven slices, explicit dependencies, and no partial switch-over

Approved 2026-09-12. The seven delivery slices and their ordering stand.
LEDGER-2 establishes the ledger; LEDGER-3 and LEDGER-4 depend on
LEDGER-2; LEDGER-5 depends on the selection and lease contracts from
LEDGER-3 and LEDGER-4; LEDGER-6 integrates the completed backend and
publication support; LEDGER-7 adds repetition only after the single-review
workflow works end to end; LEDGER-1 can land independently first. The
existing `project-review` workflow stays operational until LEDGER-6
switches it over: an earlier slice never partially migrates a live
consumer record and never leaves the installed command dependent on an
unfinished piece.

The arc carries an end-to-end acceptance test proving that a fresh
repository starts correctly; legacy coverage imports truthfully; the three
queues select in the approved order; both clean and findings-bearing
reviews advance the timestamp; interruption and takeover cannot produce a
false completion or a stale-owner write; automation counts completed
records and stops correctly; and both packaged workflows include the
required helpers and behave consistently.

Consequences: the new helper module is added beside the cursor and is
exercised only by tests until LEDGER-6 wires the workflow to it, so the
installed command keeps reading the v2 cursor through LEDGER-5; migration
of a live ledger happens on the first post-LEDGER-6 invocation, never
during delivery; the end-to-end test lands with LEDGER-6 for every proof
but the automation count, which LEDGER-7 adds.

## Proposal history

### P-1. Refresh undated legacy entries before dated reviews

Superseded by D-8. The owner accepted processing legacy entries after the
never-reviewed queue, but chose highest PR number first instead of the
proposed oldest-merge-first order. No synthetic historical timestamp is needed.

### P-2. One ledger document replaces the cursor document

Absorbed into D-10 with two changes: the payload keeps compact history
records rather than the current row only, and a checkpoint commit follows
every completed review instead of the file staying uncommitted. Its
migration rule was narrowed by D-9 to import prose enumerations too.

### P-3. The inventory is the complete merged-PR history, every invocation

Absorbed into D-11 unchanged; the incremental alternative was rejected
because an older-numbered PR can merge later.

### P-5. No claim at selection; the record resolves a race

Rejected by D-12: comparing completed timestamps wastes an entire review
and is weaker than a claim. Its lost-update refusal survives as the
"expired or replaced owner cannot overwrite the replacement" guarantee.

### P-6. Automation counts completed records and stops on the first refusal

Absorbed into D-12's last three guarantees.

### P-4. The verification commit is the remote default-branch head

Revised after the owner's correction that a captured SHA means nothing
unless the reviewer read exactly that tree, then absorbed into D-13 as a
detached temporary worktree with fetch-failure stop and reported-on-failure
cleanup.

### P-7. Repeat findings link existing entries; new reports never collide

Absorbed into D-14. The timestamp-suffix option lost to a per-PR sequence
the helper allocates atomically; the recurrence rule and the navigable
reference rule were added by the owner.

### P-8. Direct mode is explicit-only

Absorbed into D-16 unchanged, with the added requirement that migration
preserves existing direct progress.

### P-9. A fix link names the particular finding it closes

Absorbed into D-15, with the owner's verification rule (merged in the
correct repository, correction present in the pinned revision) and the
first-delivery placement.

### P-10. Heartbeat lease with atomic recorded takeover

Absorbed into D-17 with one correction: a detached renewer is not enough,
because an orphan would extend a dead claim forever; renewal is tied to the
review session's own lifetime and its loss of the owner-liveness signal.

## Open questions

### Q-1. Ownership and command identity

Resolved by D-1 and D-2: Kanban owns both packaged merged-history workflows;
the separate pre-merge approval gate is not renamed or replaced.

### Q-2. Existing review history

Resolved by D-3: positively identified historical reviews receive `[legacy]`
and count as reviewed. Unknown metadata is not fabricated.

### Q-3. Meaning of oldest verification

Resolved by D-4: oldest completed review attempt, including findings outcomes.

### Q-4. Legacy refresh order

Resolved by D-8: after never-reviewed PRs, convert legacy entries one at a time
from highest PR number to lowest, recording fresh non-legacy reviews.

### Q-5. Durable storage, recovery, and remaining workflow boundaries

Resolved by D-9 through D-18, through its 2026-09-12 split into Q-6
through Q-15, each signed off on its own.

### Q-6. Does a report's own PR enumeration count as "known for a fact"?

Resolved by D-9: explicit reviewed-PR lists are imported with their source
report as evidence, without a filename-interval restriction, and ambiguous
prose is flagged for confirmation.

### Q-7. Ledger location, format, and landing

Resolved by D-10: one readable ledger per repository with validated machine
data and compact history, atomically updated, checkpoint-committed locally
after each completed review, never pushed. Publication of a consumer's
ledger stays that consumer's question; Kanban's ledger still needs a §7
row before it can publish directly.

### Q-8. Complete inventory every invocation, or incremental?

Resolved by D-11: complete paginated inventory before selection; an
incomplete listing stops the run; the incremental scan is rejected.

### Q-9. Which commit does a checkmark name?

Resolved by D-13: the full SHA of the freshly fetched remote default-branch
head, reviewed in a detached temporary worktree; a failed fetch stops the
run.

### Q-10. Concurrency, interruption, and what the automation counts

Resolved by D-12: an expiring, renewed owner-token claim at selection, with
the seven guarantees listed there; only recorded completed reviews count
toward `N`.

### Q-11. How repeat findings on the same PR are filed

Resolved by D-14: existing finding identities are reused, new reports take
helper-allocated per-PR sequence numbers, recurrences are explicit, and
references are verified rather than assumed anchors.

### Q-12. Direct-commit mode

Resolved by D-16: explicit-only, progress preserved separately, no rows.

### Q-13. Fix-provenance mechanism

Resolved by D-15: optional per-finding `--fixed` links in the first
delivery, recorded only after verification, never blocking a completed
review.

### Q-14. Lease heartbeat, atomic takeover, and history preservation

Resolved by D-17: 60-second renewal and 15-minute expiry as defaults,
ledger defaults overridden by invocation flags, effective settings recorded
in the claim, automatic atomic recorded takeover, no archival, and renewal
bound to the review session's own lifetime.

### Q-15. Where ledger-era documents live and how they are classified

Resolved by D-18: `docs/project_review/` under one directory-level
classification, existing reports untouched, runtime artifacts kept outside
the publishable directory. The flat-file alternative, which needed three
registry entries per report, was rejected.

## Verification strategy

Arc-level signals: a fresh repository with no history produces an empty
ledger and reviews its newest merged PR on the first invocation
(Hetoimasia's path); Kanban's existing cursor and thirty-one reports migrate
into rows whose `[legacy]` evidence names the report that proves each one,
with every ambiguous enumeration surfaced rather than decided; repeated
invocations walk D-8's three queues in order and never re-select a PR while
another completed attempt is newer; a killed review session leaves a claim
that lapses and is taken over on the next selection with the transition in
the row's history; the former owner's late `record` is refused.

The arc's end-to-end acceptance test (D-19) proves seven things over
temporary repositories, temporary docs worktrees, and a fake `gh`: a fresh
repository starts correctly; legacy coverage imports truthfully; the three
queues select in the approved order; both clean and findings-bearing
reviews advance the timestamp; interruption and takeover cannot produce a
false completion or a stale-owner write; automation counts completed
records and stops correctly; and both packaged workflows include the
required helpers and behave consistently. It lands with LEDGER-6, and
LEDGER-7 adds the automation proof.

Test families, all in `tools/` and none needing a terminal, network, or
GitHub account: pure helper tests over temporary docs worktrees and
temporary Git repositories; fake `gh` executables on a temporary `PATH`
that serve paginated merged-PR listings, including a page returned at its
limit; process-level lease tests that start a real renewer, sever its
liveness signal, and observe the lapse; rendered-asset assertions over both
bundles in the `WriteLocationTests` shape, with a negative control; and the
bundle version gate for every edited plugin file.

Compatibility and migration: v1, v2, and the hand-authored boundary document
all migrate; direct-mode state survives untouched; the old cursor file is
preserved until the new ledger is written. Persistence: every completed
review is one path-scoped checkpoint commit on the docs worktree's branch,
never pushed. Determinism: selection is a pure function of the ledger and
the inventory; report sequence numbers come from the ledger, never from
time. Documentation: `docs/agent-workflow-contract.md` describes the
workflow and holds the §7 rows; `docs/design.md` does not mention
`project-review` today and needs no change unless a slice adds a board
surface, which none does.

## Delivery plan

Approved 2026-09-12 (D-19). Slices are in dependency-valid order; the
installed workflow stays on the v2 cursor until LEDGER-6 switches it over.

### LEDGER-1. Enroll the design document in §7 and its sibling registries

- **Outcome:** `docs/project_review_ledger_design.md` has a `coordination` /
  `audit-report` row, an `EXCLUDED_TRACKED_PATHS` entry, and a
  `config.toml.example` entry, with §7's prose lists audited, so
  `/process-design-doc` can publish edits to this document directly.
- **Scope:** the three registries and the prose that counts or lists them.
- **Phase:** 0
- **Depends on:** `none`
- **Ordering:** `can land first`
- **Relevant decisions:** D-1
- **Acceptance signals:** `tools/test_document_classification.py` and
  `tools/test_source_distribution.py` pass with the new row; the publish
  helper accepts the document's path.
- **Out of scope:** the ledger and report classification (LEDGER-6).
- **Open questions:** `None`

### LEDGER-2. Add the ledger document, its rendering, and its migration

- **Outcome:** a new bundled helper module beside the cursor reads, renders,
  and writes `ledger.md`: a versioned marker, a strictly validated payload
  of per-PR rows with self-contained history entries, `direct` and
  `excluded` carried over, and a rendered current-state table; it migrates
  the hand-authored boundary document, the v1 and v2 cursors, and the scope
  enumeration of every sibling report into `[legacy]` rows with their
  evidence, flags ambiguous prose for confirmation, writes atomically, and
  preserves the old cursor until the ledger is written.
- **Scope:** schema, parser, renderer, migration, `read` and `migrate`
  subcommands, both bundle copies, and the registry entries a new bundled
  script needs.
- **Phase:** 1
- **Depends on:** `none`
- **Ordering:** `critical path`
- **Relevant decisions:** D-1, D-3, D-5, D-9, D-10, D-16, D-17
- **Acceptance signals:** Kanban's real cursor and reports migrate in a
  test fixture to rows whose evidence is checkable; Synarchy's out-of-
  interval enumeration is imported; an ambiguous enumeration produces a
  flag, not a row; a migrated document round-trips; the old cursor file
  still exists after migration.
- **Out of scope:** selection, claims, record, and any workflow change. The
  installed command keeps reading the v2 cursor; no live consumer record is
  migrated by this slice (D-19).
- **Open questions:** `None`

### LEDGER-3. Select one PR from a complete inventory

- **Outcome:** `select` takes a complete paginated merged-PR listing,
  refuses a listing that ended at its limit or failed, records the known
  universe in the ledger, and returns exactly one PR by D-8's order:
  never-reviewed newest-first by merge time, then `[legacy]` highest number
  first, then oldest completed-review timestamp.
- **Scope:** the inventory contract, the three queues, the never-repeat
  rule for a stable inventory, and the one-PR-repository refresh case.
- **Phase:** 1
- **Depends on:** LEDGER-2
- **Ordering:** `critical path`
- **Relevant decisions:** D-2, D-4, D-8, D-11
- **Acceptance signals:** ordering tests over fixtures for each queue and
  each transition between queues; a page at its limit refuses; a lost PR
  reappears as never-reviewed; an excluded PR is never selected.
- **Out of scope:** claiming the selected PR (LEDGER-4).
- **Open questions:** `None`

### LEDGER-4. Take, renew, release, and take over a session-bound lease

- **Outcome:** `claim`, `renew`, `release`, and takeover-on-select exist,
  under one helper-owned lock: a claim carries an owner token, its
  effective renewal and expiry (ledger defaults, invocation overrides), and
  its start; a renewer runs only while the review session's liveness
  signal is held and stops on cancellation, termination, or its loss; an
  expired claim is taken over atomically and recorded as a transition; a
  token-fencing check exists for later mutations; an expired or replaced
  token cannot renew.
- **Scope:** the lease record, the lock, the renewer and its liveness
  signal, takeover, and the fencing primitive.
- **Phase:** 2
- **Depends on:** LEDGER-2
- **Ordering:** `critical path`
- **Relevant decisions:** D-12, D-17
- **Acceptance signals:** behavioral tests for crash recovery (renewer
  loses its signal, claim lapses, next select takes over), cancellation
  (renewal stops at once), takeover atomicity under two concurrent
  selectors, and a replaced token's refused renewal; a long-running child
  keeps receiving renewals while the session is alive; changing a ledger
  default leaves an existing claim's settings unchanged.
- **Out of scope:** `record`, reports, and the checkpoint commit.
- **Open questions:** `None`

### LEDGER-5. Record a completed attempt, allocate reports, link fixes, checkpoint

- **Outcome:** `record` writes one completed attempt — outcome,
  verification SHA, UTC timestamp, report link, repeated-finding links,
  recurrences, and verified `--fixed <report>#PRR-k=<PR>` links — into the
  row and its history, converts a `[legacy]` row, releases the claim, and
  makes a path-scoped checkpoint commit on the docs worktree's branch;
  `allocate-report` returns the next per-PR sequence filename atomically;
  every reference is verified against the report's heading; each of these
  presents the owner token and is refused for an expired or replaced one.
- **Scope:** record, report allocation, reference verification, fix-link
  validation (merged in `$REPO`), the checkpoint commit, and the
  late-completion refusal.
- **Phase:** 2
- **Depends on:** LEDGER-3, LEDGER-4
- **Ordering:** `critical path`
- **Relevant decisions:** D-4, D-5, D-7, D-10, D-14, D-15, D-17, D-18
- **Acceptance signals:** a findings record and a clean record each
  produce the right row, history entry, and a commit touching only the
  ledger and report paths beside an unrelated dirty file left alone; a
  second report for the same PR gets the next sequence and never an
  existing name; a reference to a missing heading is refused; a fix link
  for an unmerged PR is refused while the review still records; a late
  `record` by the former owner is refused and its cleanup touches only its
  own paths.
- **Out of scope:** the workflow text that calls these.
- **Open questions:** `None`

### LEDGER-6. Rebuild the project-review workflow on the ledger

- **Outcome:** `tools/command_sources/project-review.md` and both rendered
  assets run one review end to end — inventory, select and claim, pin a
  detached temporary worktree at the fetched remote head, review, report
  only new findings, record, checkpoint, clean up and report a retained
  path on failure — with an explicit legacy-handling section, explicit-only
  direct mode, no self-continuation, and the workflow's documents
  classified so it can maintain them: the `docs/project_review/` directory
  row and its seed in Kanban's three registries, and the consumer-side
  `direct_publication_paths` guidance in the contract. Runtime artifacts
  (worktrees, locks, liveness handles) live outside that directory. This
  is the switch-over: the installed command reads the ledger from here on
  and migrates a live consumer record on its first invocation.
- **Scope:** the workflow source and both renderings, the external
  workflow contract's description, the publication classification, the
  rendered-asset regression assertions, the bundle version bumps, and the
  arc's end-to-end acceptance test.
- **Phase:** 3
- **Depends on:** LEDGER-3, LEDGER-5
- **Ordering:** `critical path`
- **Relevant decisions:** D-2, D-3, D-6, D-13, D-16, D-18, D-19
- **Acceptance signals:** rendered-asset assertions hold both bundles to
  the resolved-helper, no-commit-outside-checkpoint, pin-worktree,
  fetch-failure-stop, cleanup-report, and no-self-continuation rules with a
  negative control; the classification tests pass with the directory row;
  the bundle gate passes; and the end-to-end test proves, over temporary
  repositories and a fake `gh`, that a fresh repository starts correctly,
  legacy coverage imports truthfully, the three queues select in the
  approved order, clean and findings-bearing reviews both advance the
  timestamp, interruption and takeover cannot produce a false completion
  or a stale-owner write, and both packaged workflows carry the required
  helpers and behave consistently.
- **Out of scope:** serial automation.
- **Open questions:** `None`

### LEDGER-7. Add auto-project-review

- **Outcome:** a new command source rendered into both bundles runs the
  one-review workflow `N` times, or until stopped without `N`, counting
  only successfully recorded completed reviews and stopping with a
  progress report on the first unrecoverable refusal; delivery starts no
  run.
- **Scope:** the source, both renderings, plugin manifest descriptions, and
  the rendered-asset assertions.
- **Phase:** 3
- **Depends on:** LEDGER-6
- **Ordering:** `critical path`
- **Relevant decisions:** D-6, D-12
- **Acceptance signals:** assertions that the automation asset counts
  records and never skips; that the single-review asset starts no second
  review; the bundle gate passes; and the end-to-end test gains its last
  proof, that automation counts completed records and stops correctly on
  `N` and on the first unrecoverable refusal.
- **Out of scope:** any scheduler or service integration.
- **Open questions:** `None`

## Source notes

The owner's latest clarification: `[legacy]` is treated as already reviewed;
Hetoimasia has no prior reviews; the timestamp means "time of last review";
refresh order is oldest attempt rather than oldest approval. Once the
never-reviewed queue is exhausted, legacy PRs are converted to non-legacy
reviews with new timestamps from highest PR number to lowest.

The owner's 2026-09-12 answers, condensed: import the recorded set and PRs
explicitly identified as reviewed in report prose, preserving the source
report as evidence; do not import arbitrary mentions from findings or
deduplication sections; reject the filename-interval restriction (Synarchy's
`project_review_432-412.md` reviewed #442 and #444); flag ambiguous prose for
confirmation. One ledger per repository with a readable table and strictly
validated machine data; atomic updates preserving the old cursor until
migration succeeds; a local docs-worktree checkpoint commit after each
completed review containing only its ledger and report changes, no automatic
push; compact review-history records behind the current-row table. Complete
paginated inventory before selection; stop without claiming coverage when it
fails or is incomplete; an incremental scan on the highest number is unsafe
because an older-numbered PR can merge later. An expiring claim at selection
with an owner token and renewal; the seven guarantees under D-12; comparing
timestamps after both agents finish is weaker and wastes a review.

Corrections to the remaining proposals: pin the review to an immutable
checkout and record that SHA; link existing findings instead of duplicating
actionable entries, with collision-safe report names because day-only
suffixes collide; keep direct mode explicitly selectable rather than an
automatic fallback; fix links must identify the particular finding fixed.

The owner's second 2026-09-12 batch, condensed: checkpoint commits and
helper-owned locking confirmed. Detached temporary worktree at the freshly
fetched remote default-branch SHA; stop on fetch failure; clean up after
stopping started processes and report a retained path when cleanup fails.
Reuse finding identities; per-PR sequence numbers allocated atomically,
never reusing a filename; real UTC timestamps in records but never for
uniqueness; never overwrite existing reports or checklists; a returned
defect is a recurrence linked to the original; references must be
navigable without assuming heading anchors. Per-finding fix links in the
first delivery, recorded only after verifying the fix merged in the right
repository and is present in the pinned revision; missing attribution never
blocks; links are provenance only. Explicit-only direct mode with progress
preserved separately. For the lease: a regular heartbeat with configurable
renewal and expiry independent of phases; atomic recorded takeover; the
former owner cannot publish; history preserved without silent truncation;
visible ledger compact; archival, if ever, preserves links and evidence.
The scheduling order is unchanged: never-reviewed first, then `[legacy]`
highest number first, then oldest completed-review timestamp.

The owner's third 2026-09-12 batch, condensed: 60-second renewal and
15-minute lease, per-repository ledger defaults with invocation overrides
taking precedence, effective settings recorded in the claim, defaults never
silently changing an existing claim; automatic atomic recorded takeover on
the next selection with no manual step for ordinary crash recovery; no
archival, all history preserved, nothing silently truncated; renewal tied
to the review session's lifetime, not the application process, stopping on
cancellation, termination, or loss of the liveness signal while long
builds keep receiving renewals — an explicit, tested requirement; the four
verified guarantees under D-17. Then `docs/project_review/` for the ledger
and all new reports with one directory-level classification, existing
reports left in place, runtime artifacts outside the publishable
directory, and no registry edit per report in a new repository. The seven
slices and their ordering approved with explicit dependencies; the existing
workflow stays operational until LEDGER-6; the seven-proof end-to-end
acceptance test; and the instruction not to reopen settled decisions
unless concrete implementation evidence exposes a conflict.

Publication of this design does not publish new skills, migrate any consumer
ledger, or run any project review. It remains an exploring design until the
remaining choices and delivery plan are approved.
