# Issue approval queue control design

Kanban has a canonical one-issue review action and a canonical Python backend,
but it has no explicit dashboard action for walking the open issue backlog in
order. This design defines a bounded operator-started queue that reuses that
authority, stops at the first issue needing human repair, and makes the stop
visible beside the existing PR drainer control.

Design state: `exploring`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. Add an operator-controlled canonical issue approval queue
- [ ] IAQ-1. Add a bounded review-queue mode to the canonical backend
- [ ] IAQ-2. Integrate the queue process and result contract with Kanban
- [ ] IAQ-3. Add the issue approval queue sidebar control

## Epic contract

- **Goal:** Let an operator start one canonical pass over open GitHub issues
  from the Kanban sidebar, reviewing eligible issues in ascending issue-number
  order and stopping visibly at the first issue that requests changes.
- **Done when:** The queue uses the installed canonical `approve_issues.py`
  backend, never bypasses an earlier blocking issue, publishes the same v2
  review state as the existing one-issue action, stops safely on
  changes-requested or failure outcomes, and exposes its lifecycle through a
  keyboard-accessible button immediately above `drain_prs.py`.
- **Users and operators:** A Kanban operator preparing issues for autonomous
  solving, plus maintainers of the canonical review backend and TUI.
- **Arc label:** `agent-workflows` proposed.

## Current state and evidence

### Verified current state

- `tools/approve_issues.py` is already Kanban's canonical issue-review backend.
  It owns reviewer routing, review worktrees, `issue-review:v2` comments,
  verdict-label transitions, the per-checkout `approve_issues.lock`, and
  `--review`, `--rereview`, and `--check` one-issue modes.
- Its existing no-action queue path calls `get_open_issues`, whose results are
  sorted by `(createdAt, number)`, and `select_candidate` chooses one stale or
  unreviewed issue per pass. It deliberately skips any issue whose latest
  canonical marker says `CHANGES_REQUESTED`, then continues to later issues.
  That is background-daemon behavior and does not satisfy the requested
  ordered barrier.
- `src/Kanban/Review/Canonical.hs` resolves the installed backend through
  `KANBAN_ISSUE_REVIEW_INSTALL_DIR` or the installer-written discovery record,
  invokes it as a bounded process, captures its process group, and parses the
  one-issue JSON result. The board's `r` action already uses this path.
- `src/Kanban/UI/Board.hs` renders `drain_prs.py` as the bottom control in the
  28-cell usage sidebar. `DrainerButton`, `ToggleDrainer`, and the event
  handlers in `UI.Types`, `UI.Keys`, and `UI.Events` provide the corresponding
  mouse and keyboard path.
- The current review contract says direct review never starts an approval
  daemon. Workflow setup installs the canonical backend but deliberately does
  not install or start an approval service.
- A tracker search on 2026-08-11 found no open or closed issue that already
  owns this queue-control arc. Closed portability work such as #75 and #155
  owns backend installation and discovery, not an ordered sidebar-triggered
  pass.
- Under `docs/agent-workflow-contract.md` section 7, a new design document is
  `pr-atomic` until that authoritative classification explicitly admits it to
  the coordination lane. This draft therefore remains in the `docs-wip`
  worktree and must not be published directly under the current contract.

## Desired experience

1. The operator presses the queue key or clicks an `approve_issues.py` control
   immediately above the `drain_prs.py` control.
2. Kanban launches exactly one foreground queue process against the repository
   identity and configuration already resolved by the dashboard. The button
   becomes amber and reports that the queue is running.
3. The canonical backend considers open issues in ascending numeric order.
   Issues with a current approval for their current specification do not cause
   another model call. Each issue that needs an initial review is reviewed by
   the same canonical v2 path used by the one-issue action.
4. After an approval, the backend advances to the next number. It never reviews
   a later issue after encountering an earlier changes-requested barrier.
5. If a reviewed issue returns `CHANGES_REQUESTED`, the process stops normally.
   Kanban leaves the control amber with a durable session-state warning such as
   `stopped · issue #254 requests changes`, and refreshes the board so the
   label change is visible.
6. If no issue needs attention, the pass completes and the control reports a
   successful terminal state. A backend, model, GitHub, lock, malformed-state,
   or outcome-unknown failure stops the pass and is shown as an error rather
   than allowing later issues to run.

The initial release does not automatically revise an issue or bypass the
barrier. The operator uses the existing issue `r` workflow to revise/rereview
the named issue, then starts a new queue pass.

## Scope

### In scope

- An explicit finite queue mode in the existing canonical backend.
- Ascending numeric ordering over the backend's live open-issue inventory.
- Reuse of current provenance routing, spec fingerprints, configured labels,
  incidents, worktree cleanup, and locking.
- A versioned machine-readable terminal result that distinguishes completed,
  changes-requested, and failed/outcome-unknown runs.
- A non-overlapping Kanban process lifecycle for the queue.
- A mouse-clickable and keyboard-accessible sidebar control immediately above
  `drain_prs.py`, including idle, running, complete, warning, and error states.
- Board refresh after any pass that may have published comments or labels.
- Pure, fixture, process, event, and golden-frame coverage following the
  repository's existing test patterns.
- Contract updates required by the behavior change in the implementation PRs.

### Out of scope

- A second reviewer implementation or a second copy of `approve_issues.py`.
- Automatic specification revision, automatic rereview after revision, issue
  editing, issue closing, issue solving, PR review, or merging.
- A polling daemon, LaunchAgent, background service installer, notification
  service, or queue work that survives Kanban exiting unless Q-2 changes the
  lifecycle.
- Parallel issue reviews or continuing past a changes-requested barrier.
- Replacing the existing selected-card `r` workflow.
- Persisting historical queue runs across dashboard restarts.

## Design

### Authority and command boundary

The queue is a new finite mode of `tools/approve_issues.py`, not a new script.
The Python backend remains the only component that enumerates live issues,
interprets canonical review records, chooses reviewers, and mutates GitHub.
The Haskell dashboard resolves and invokes the installed backend; it does not
derive a queue from the cached board, whose issue set may be truncated and
whose records do not contain the review comments needed to validate a v2
fingerprint.

The proposed command shape is:

```console
python3 <installed>/approve_issues.py \
  --path <repository-root> \
  --repo OWNER/NAME \
  --review-queue \
  --legacy-policy dual \
  --json \
  [--config <absolute-config-path>]
```

`--review-queue` is mutually exclusive with `--check`, `--review`, and
`--rereview`. It is finite: it exits when the eligible queue is exhausted, at
the first ordered barrier, or on the first failure. The existing per-checkout
approval lock is held for the whole pass so an interactive review, a second
dashboard, and the legacy daemon cannot interleave canonical publications.

### Queue classification and ordering

The backend fetches the live open-issue inventory once per selection pass and
sorts it by integer issue number. Pull requests remain excluded. For each issue
in that order it classifies the current effective specification and canonical
record before taking any action:

- a current `APPROVE` record is already complete and is skipped;
- an issue needing initial review is reviewed synchronously and then
  reclassified from live GitHub state;
- a current `CHANGES_REQUESTED` handoff is an ordered barrier, with the exact
  treatment of a barrier present before the run governed by Q-1;
- an invalid marker, blocking pipeline incident, inconsistent verdict state,
  or inability to establish current state stops as an error;
- an unmarked legacy issue uses the existing `dual` policy passed by Kanban.

The pass never snapshots a list of candidates and blindly runs it: each
publication can change labels/comments, and the current backend already
rechecks the issue specification after model work before publishing. A
candidate whose specification changes during review must not be counted as
approved or permit the pass to claim that it crossed that number.

### Result contract

Stdout stays reserved for one bounded JSON document; diagnostics and the
existing dated log stay off stdout. A proposed v1 result contains:

- `version`;
- `outcome`: `complete` or `changes_requested` for observed terminal states;
- `reviewed_count` and `approved_count` for this invocation;
- `issue`: the changes-requested barrier number, otherwise absent;
- `message`: sanitized caller-displayable text.

Both observed outcomes exit successfully and are distinguished by JSON. A
failure uses a non-zero exit and the bounded diagnostic path. This mirrors the
existing one-issue Haskell boundary: a legitimate `CHANGES_REQUESTED` verdict
is not a process failure. The schema must reject unknown versions,
contradictory counts/outcomes, or a missing issue number for
`changes_requested`.

This first pass proposes no live per-issue event protocol. While the subprocess
runs, the sidebar reports `running…`; detailed issue/model progress remains in
the canonical backend log. Q-3 decides whether that is sufficient or whether
the initial feature needs a separate bounded progress channel.

### Dashboard lifecycle and concurrency

A focused module should own queue status, command arguments, result decoding,
and rendering vocabulary rather than extending `Kanban.Drainer`: the two
controls share placement, not authority or lifecycle. `AppState` holds one
optional managed queue process and one status value. App events announce
process start and terminal result.

Kanban performs the same preflight and installed-backend resolution used by
selected-card canonical review. It refuses a second click while a run is in
flight. The Python lock remains the cross-process authority; the UI's busy
flag is only immediate local feedback. Because selected-card review and the
queue use the same backend lock, a race fails closed with a diagnostic rather
than publishing overlapping results.

Any queue completion triggers a board refresh because even an errored or
outcome-unknown run may have published a comment or label before the dashboard
lost observability. The queue's terminal status is not overwritten by the
ordinary refresh result. A later explicit queue run replaces it.

### Sidebar and interaction

The bottom of the usage sidebar becomes a two-control stack:

```text
╭─────────────────╮
│ approve_issues.py │
╰─────────────────╯
stopped · issue #254
requests changes

╭─────────────╮
│ drain_prs.py │
╰─────────────╯
off
```

The queue control uses neutral styling before a run, amber while running,
green after a complete pass, amber after `changes_requested`, and red for an
error or outcome-unknown result. The warning persists in dashboard state and
names the issue number; it is not only a transient notice that `Esc` can erase.
The proposed board shortcut is lowercase `a`, paired with click, while
uppercase `A` remains autosolve. The authoritative key table, help text,
footer, mouse routing, and golden layouts change together.

## Decisions

### D-1. Extend the canonical backend instead of adding a second script

The requested `approve_issues.py` behavior belongs in the already tracked and
installed `tools/approve_issues.py`. Kanban invokes that installation and no
other reviewer owns comments or verdict labels.

### D-2. Numeric issue order is the queue order

The queue considers open issues by ascending integer issue number, not
`createdAt`, board column, update time, or cached display order.

### D-3. Changes requested is a stop barrier

Once an issue in the ordered pass produces `CHANGES_REQUESTED`, no greater
issue number is reviewed in that invocation.

### D-4. The stopped issue is a persistent amber sidebar warning

The button's terminal warning includes the issue number and survives ordinary
board refreshes until another queue run replaces it.

### D-5. Queue review reuses canonical v2 semantics

Reviewer routing, models, legacy policy, spec fingerprints, worktrees,
comments, labels, incidents, configuration, repository identity, and the
approval lock remain owned by the existing backend rather than reimplemented
in Haskell.

## Proposals

### P-1. Make the queue an explicit foreground, finite action

An operator click starts one pass; Kanban owns its process, blocks dashboard
quit while it is live, and does not install a service. This matches the
existing direct-review lifecycle and the current no-daemon product contract.

### P-2. Use lowercase `a` as the keyboard equivalent

Every mouse action needs a keyboard path. Lowercase `a` reads as “approve
queue” and remains distinct from uppercase `A` autosolve.

### P-3. Keep stdout to one final JSON result

The initial UI shows a running state without per-issue progress. This keeps
the process boundary bounded and lets the existing capture discipline be
reused instead of introducing a streaming protocol solely for the sidebar.

## Open questions

### Q-1. Does a pre-existing changes-requested issue stop the pass immediately?

The strongest reading of numeric order says yes: if issue #120 already has a
canonical changes-requested handoff, the queue reports #120 and reviews
nothing numbered above it. The alternative is to stop only when this run
newly produces that verdict, which preserves the old daemon's ability to work
around unresolved issues but weakens the requested one-by-one barrier. This
changes the queue's safety and usefulness and must be decided before IAQ-1.

### Q-2. Is the queue foreground and cancelable, or a persistent service?

P-1 proposes a foreground process owned by the dashboard, with a repeat click
disabled and quit blocked until the operator cancels or the current canonical
review ends. A persistent service would require installation, discovery,
status, incident, and shutdown contracts comparable to the PR drainer and
would materially enlarge the arc. The desired lifetime must be decided before
IAQ-2.

### Q-3. Must the button show the current issue while the queue is running?

P-3 shows only `running…` until a final result and preserves detailed progress
in logs. Showing `reviewing issue #N` live would require a trustworthy bounded
progress protocol or status document in addition to the final JSON result.
This affects IAQ-1 and IAQ-2 but not the stop warning.

## Verification strategy

- Python pure/fixture tests prove numeric ordering, current-approval skips,
  current and newly produced changes-requested barriers, incident and invalid
  stops, legacy dual routing, lock exclusion, no later model invocation after
  a barrier, and exact result/exit semantics.
- Python CLI tests use fake `gh`, `codex`, and `claude` executables and
  temporary Git repositories; no real account, network, or terminal is needed.
- Haskell pure tests prove command construction, discovery/config forwarding,
  result decoding, schema contradictions, state/color mapping, repeated-click
  refusal, and outcome-unknown wording.
- Haskell process fixtures cover start, completion, changes requested, malformed
  stdout, non-zero exit, timeout, process-group cancellation, and lock-holder
  diagnostics with a fake installed backend.
- UI event tests cover click and keyboard parity, process-start races, refresh
  after every terminal result, preservation of terminal status across refresh,
  and interaction with selected-card canonical review.
- Golden frames cover the expanded sidebar in normal, narrow, running,
  complete, warning, and error states under supported border/color policies.
- Contract tests keep `docs/design.md`'s key and lifecycle tables,
  `docs/agent-workflow-contract.md`'s authority/dependency descriptions, and
  the implementation synchronized. The new design document's publication
  lane must be resolved before it is tracked or published.

## Delivery plan

### IAQ-1. Add a bounded review-queue mode to the canonical backend

- **Outcome:** The installed canonical Python backend can run one finite,
  numerically ordered pass and return a validated terminal result without
  continuing past a changes-requested barrier.
- **Scope:** Add `--review-queue`; refactor queue classification away from the
  daemon-only skip behavior; hold the existing lock for the pass; define the
  v1 JSON result and exit semantics; add Python tests and backend contract
  documentation.
- **Phase:** 1 — backend contract.
- **Depends on:** `none`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-1`, `D-2`, `D-3`, `D-5`.
- **Acceptance signals:** Fake-executable tests show ascending numeric calls,
  no calls above the barrier, canonical comments/labels unchanged in shape,
  one bounded result on stdout, and failure on concurrent lock ownership.
- **Out of scope:** Haskell integration, sidebar rendering, service
  installation, and issue revision.
- **Open questions:** `Q-1`, `Q-3`; stop for those decisions before drafting
  the issue because they alter the command contract.

### IAQ-2. Integrate the queue process and result contract with Kanban

- **Outcome:** Kanban can resolve, launch, observe, stop if authorized, and
  safely classify one queue pass independently of selected-card review.
- **Scope:** Add the focused Haskell queue domain/invocation module, argument
  and JSON schema validation, managed-process lifecycle, app state/events,
  preflight, concurrency notices, completion refresh, and process fixtures.
- **Phase:** 2 — application lifecycle.
- **Depends on:** `IAQ-1`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-1`, `D-4`, `D-5`.
- **Acceptance signals:** Hermetic tests observe every terminal outcome,
  process-group cleanup, no duplicate local start, safe conflict with the
  backend lock, board refresh after possible mutation, and no false claim of
  completion after malformed or incomplete output.
- **Out of scope:** Final sidebar rendering and a persistent launchd service.
- **Open questions:** `Q-2`, `Q-3`; the chosen lifetime and progress surface
  must be settled before this slice is drafted.

### IAQ-3. Add the issue approval queue sidebar control

- **Outcome:** Operators can start and understand the queue from a new control
  immediately above `drain_prs.py`, with keyboard parity and a numbered amber
  stop warning.
- **Scope:** Render the control stack; add clickable name and board action;
  connect the selected shortcut and notices; map idle/running/complete/warning/
  error states to theme attributes; update help/footer and authoritative docs;
  add interaction and golden-frame tests.
- **Phase:** 3 — operator experience.
- **Depends on:** `IAQ-2`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-4`.
- **Acceptance signals:** Click and keyboard start the identical action;
  a changes result leaves an amber detail naming `#N`; complete is green;
  failure/outcome unknown is red; the control remains above the drainer in
  supported widths and border policies; all key-table and golden tests pass.
- **Out of scope:** Automatic navigation into issue repair, persistent run
  history, and service management.
- **Open questions:** `Q-2` if cancel interaction changes the button behavior;
  otherwise `None`.
