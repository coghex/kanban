# Project review ledger design

Replace the bounded, twelve-PR historical sweep with a repository-local ledger
and a one-PR review operation, shared by Kanban's Codex and Claude workflows.
Hetoimasia is the primary new consumer and has no prior reviews according to
the owner; Kanban and Synarchy also need the same behavior and truthful legacy
coverage migration.

Design state: `exploring`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. Establish a repository-local rolling project-review ledger

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
  found no clearly overlapping arc. Repeat the overlap check at readiness.

The root repository instructions require workflow behavior changes to carry
regression tests and stay consistent with `docs/design.md` and the external
workflow contract. The existing implementation-state section was checked;
the mission runner is a separate implemented facility, not evidence that this
project-review ledger already exists.

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

## Proposal history

### P-1. Refresh undated legacy entries before dated reviews

Superseded by D-8. The owner accepted processing legacy entries after the
never-reviewed queue, but chose highest PR number first instead of the
proposed oldest-merge-first order. No synthetic historical timestamp is needed.

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

Q-4 is settled. Specify and obtain signoff on the hardened persistence
and recovery contract: readable row versus retained review history, interrupted
attempts and automation counting, concurrent invocation ownership, exact
verification-revision capture, complete merged-PR inventory, report linking
across repeat findings, optional fix provenance, and preservation of the old
direct-commit review capability. These are not implicitly approved by the
high-level scheduling decisions. No implementation or delivery decomposition
depends on unapproved choices yet.

## Delivery plan

No child slices defined yet. Capture the remaining behavioral choices before
decomposing implementation into reviewable PRs. This document is not ready for
issue processing, and no tracker artifacts have been created.

## Source notes

The owner's latest clarification: `[legacy]` is treated as already reviewed;
Hetoimasia has no prior reviews; the timestamp means "time of last review";
refresh order is oldest attempt rather than oldest approval. Once the
never-reviewed queue is exhausted, legacy PRs are converted to non-legacy
reviews with new timestamps from highest PR number to lowest.

Publication of this design does not publish new skills, migrate any consumer
ledger, or run any project review. It remains an exploring design until the
remaining choices and delivery plan are approved.
