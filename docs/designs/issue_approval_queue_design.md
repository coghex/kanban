# Persistent issue approval service design

Kanban has a canonical one-issue review action and a canonical Python backend,
but it has no persistent operator-controlled service for walking the open issue
backlog in order. This design adds that service, makes the oldest unresolved
issue an ordering barrier, and presents its lifecycle directly above the
existing PR drainer control.

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Add a persistent canonical issue approval service — [#318]
- [x] IAQ-1. Add an ordered barrier-aware queue mode to the canonical backend — [#320]
- [x] IAQ-2. Build the persistent issue approval controller and runtime — [#349]
- [x] IAQ-3. Install per-repository issue approval LaunchAgents — [#351]
- [x] IAQ-4. Expose issue approval service status and control to Kanban — [#352]
- [x] IAQ-5. Add the approve_issues.py sidebar control — [#421]
- [x] IAQ-6. Document local installation, operation, and recovery — [#425]

## Epic contract

- **Goal:** Let an operator turn on a persistent canonical issue approval
  service from Kanban that considers open issues in ascending issue-number
  order and halts visibly at the first issue requesting changes.
- **Done when:** The service uses the installed canonical `approve_issues.py`
  backend, outlives the dashboard after an explicit start like the PR drainer,
  never auto-starts merely because it was installed or the user logged in, never
  bypasses a lower-numbered changes-requested issue, publishes the same v2
  review state as the existing one-issue action, records actionable status and
  incidents, and is controlled by an `approve_issues.py` button immediately
  above `drain_prs.py` using the drainer's established presentation vocabulary.
- **Users and operators:** A Kanban operator preparing issues for autonomous
  solving on the current macOS host, plus maintainers of the canonical review
  backend and local services.
- **Arc label:** `agent-workflows` proposed.

## Current state and evidence

### Verified current state

- `tools/approve_issues.py` is already Kanban's canonical issue-review backend.
  It owns reviewer routing, temporary review worktrees, `issue-review:v2`
  comments, verdict-label transitions, the per-checkout
  `approve_issues.lock`, and `--review`, `--rereview`, and `--check` one-issue
  modes.
- Its existing no-action queue path sorts `get_open_issues` by
  `(createdAt, number)`. `select_candidate` deliberately skips an issue whose
  latest canonical marker is `CHANGES_REQUESTED` and continues to later
  issues. That behavior conflicts with the requested numeric barrier.
- No tracked issue-approval service or installer exists. Workflow setup
  installs the canonical backend but explicitly does not start or configure an
  approval daemon.
- The PR drainer already has the analogous persistent-service seams:
  `tools/drain_prs_service.py`, `tools/install_drainer.py`, versioned status and
  incident files, dated logs, a per-repository discovery record and LaunchAgent,
  and status/control code in `src/Kanban/Drainer.hs`.
- The drainer's persistence is operator-started rather than resident:
  `RunAtLoad` and `KeepAlive` are false and there is no `StartInterval`.
  Installation loads a stopped job; `start` creates a polling run that
  outlives Kanban until an explicit stop or unexpected exit. Its exact healthy
  and warning text is `on` and `on · unresolved incident · <summary>`.
- `src/Kanban/Review/Canonical.hs` resolves the installed issue-review backend
  through `KANBAN_ISSUE_REVIEW_INSTALL_DIR` or its installer record, invokes it
  as a bounded process, and parses the one-issue JSON result. The board's `r`
  action already uses this path.
- `src/Kanban/UI/Board.hs` renders `drain_prs.py` as the bottom control in the
  28-cell usage sidebar. `DrainerButton`, `ToggleDrainer`, and the handlers in
  `UI.Types`, `UI.Keys`, and `UI.Events` supply mouse and keyboard control.
- The readiness tracker search on 2026-08-11 found no existing issue or epic
  that owns this persistent ordered approval-service arc. Closed portability
  issues such as #75 and #155 own backend installation and discovery, not this
  service; current workflow issues returned by the broad search likewise own
  packaged review or drainer behavior rather than this queue.
- The current `docs/agent-workflow-contract.md` section 7 already lists this
  path among the `coordination` documents, so this design's status ledger is
  eligible for the repository's direct-document publication lane.
  The draft still lives and changes only in the `docs-wip` worktree.

## Desired experience

1. The operator presses the service key or clicks an `approve_issues.py`
   control immediately above the `drain_prs.py` control.
2. Kanban starts the installed per-repository LaunchAgent. The control follows
   the drainer's format and text: `starting…`, then green `on` while the service
   is healthy and running.
3. The service considers live open issues in ascending numeric order. A current
   approval for the issue's current specification needs no model call. An issue
   needing initial review goes through the same canonical v2 path used by the
   selected-card action.
4. A lower-numbered issue already carrying a current `CHANGES_REQUESTED`
   verdict is an immediate barrier. The service does not review any higher
   number.
5. When review newly produces `CHANGES_REQUESTED`, the service stops review
   processing but stays enabled and records a yellow, self-clearing incident.
   Its exact detail follows the drainer: `on · unresolved incident · Issue #254
   requests changes`. No higher issue runs.
6. The operator uses the existing issue `r` workflow to revise and canonically
   rereview the named issue. The controller polls only that barrier's read-only
   gate while blocked, clears the incident when the issue has a current
   approval, and resumes with the next numeric issue.
7. Turning the service off uses the drainer's `stopping…`, then `off`, text and
   transition behavior. Its status persists independently of the dashboard.
8. Backend, model, GitHub, lock, malformed-state, or outcome-unknown failures
   stop processing and surface as red errors rather than allowing later issues
   to run. Ordinary contention for the canonical approval lock is not one of
   those lock failures: the backend reports it as the normal `busy` outcome and
   the controller backs off while the control stays green, as D-16 requires.

Detailed live progress such as `reviewing issue #N` is deliberately deferred.
After this epic is done, a separate extension design document will explore a
trustworthy progress protocol and richer in-flight presentation.

## Scope

### In scope

- Ascending numeric queue ordering and a strict pre-existing or newly produced
  changes-requested barrier in the existing canonical backend.
- A persistent, operator-started, per-repository, launchd-managed approval
  service following the PR drainer's controller, installer, discovery, status,
  incident, log, and start/stop conventions where their semantics match.
- Reuse of canonical provenance routing, spec fingerprints, configured labels,
  incidents, review worktrees, repository identity, and locking.
- Versioned machine-readable status and incident documents with atomic writes.
- Kanban discovery, monitoring, and lifecycle control for the service.
- A mouse-clickable and keyboard-accessible `approve_issues.py` control
  immediately above `drain_prs.py`, using the same frame and state text.
- Green healthy-running state, yellow changes-requested warning naming `#N`,
  and red failures.
- Pure, fixture, service, installer, process, event, and golden-frame tests.
- Required updates to the authoritative design, workflow contract, setup guide,
  development guide, package inventory, and dependency manifest.
- A dedicated `tools/install_issue_approval.py` installer and
  `tools/approve_issues_service.py` controller, using a separate
  `issue-approval` install/runtime namespace while resolving the existing
  canonical backend from `issue-review`.

### Out of scope

- A second reviewer implementation or second copy of `approve_issues.py`.
- Automatic specification revision, automatic issue editing, closing, solving,
  PR review, or merging.
- Parallel issue reviews or continuing past a changes-requested barrier.
- Replacing the existing selected-card `r` workflow.
- Live current-issue/model progress in the button; this is reserved for the
  follow-on progress-extension design.
- Cross-platform service management beyond a clear unsupported diagnostic on
  non-macOS hosts.
- A generalized `setup_workflows.py` component, public deployment workflow,
  system-wide daemon, multi-user host policy, or automatic login start. The
  first service only needs a safe manual installer for the operator's current
  macOS machine.

## Design

### Authority and process boundaries

The queue behavior remains a mode of `tools/approve_issues.py`; no second
reviewer script is introduced. The backend is the only component that
enumerates live issues, reads canonical review comments, validates
fingerprints, chooses reviewers, and mutates GitHub.

A focused approval-service controller owns persistence, polling, status,
incidents, logs, and child-process supervision. The LaunchAgent invokes the
controller, not the backend directly. Kanban talks only to the controller and
its durable documents; it never derives the queue from its cached board,
because that data may be truncated and lacks the comments needed for a v2
fingerprint.

The service invokes a finite backend pass using an explicit mode such as:

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
`--rereview`. One invocation scans in numeric order but advances at most one
issue: it returns immediately after confirming the queue is idle, finding the
first barrier, publishing and rechecking one review, or encountering a
failure. The controller starts another invocation immediately after a verified
advance and applies the idle/barrier polling policy otherwise. This releases
the canonical lock between issues instead of letting one child own it for the
whole backlog.

### Queue classification and ordering

The backend fetches the live open-issue inventory and sorts it by integer issue
number. Pull requests remain excluded. For each issue in order:

- a current `APPROVE` record is complete and skipped;
- an issue needing initial review is reviewed synchronously, then re-read from
  GitHub and classified again;
- a current `CHANGES_REQUESTED` verdict is an immediate ordered barrier whether
  it predates this pass or was just published;
- an invalid marker, blocking incident, inconsistent verdict state, or
  inability to establish current state stops as an error;
- an unmarked legacy issue uses the existing `dual` policy passed by Kanban.

The pass never snapshots candidates and blindly reviews them. Each publication
can change comments and labels, and a specification can change during model
work. A stale result cannot count as crossing that issue number.

### Backend pass result

Stdout stays reserved for one bounded JSON document; diagnostics and dated logs
stay off stdout, and `--review-queue` requires `--json` so no code path can let
anything else share it. The result contains a schema version, an outcome
(`idle`, `advanced`, `changes_requested`, `retry`, or `busy`), the positive
issue number for the `advanced`, `changes_requested`, and `retry` outcomes,
whether this invocation made a model call, and caller-displayable text. All
five observed outcomes are normal backend completions. A specification that
changes during review cannot return `advanced`; it returns `retry`, and the
controller applies bounded backoff before re-reading live state. A pass that
cannot take the canonical approval lock returns `busy` before selecting any
issue, and the controller backs off the same way. Failures are non-zero and
must not be mistaken for an idle, busy, retryable, or advanced queue.

The result schema rejects unknown versions, an issue number on `idle` or
`busy`, a missing or non-positive issue number on `advanced`,
`changes_requested`, or `retry`, an `advanced` outcome without a current
approval, or any contradictory model-call claim, including a `busy` result
claiming a model call. There is no per-issue streaming protocol in this epic.

### Persistent service topology

The approval service mirrors the PR drainer's supported local topology:

- one LaunchAgent per canonical GitHub repository;
- one discovery record keyed by normalized `owner/name`;
- one runtime directory per repository for atomic status and incident files;
- one dated log directory per repository;
- one installer-managed approval-service directory containing stable links to
  the controller and its companion assets, while the controller resolves the
  already-installed canonical backend through the issue-review discovery
  record rather than installing a competing backend;
- explicit repository path, canonical identity, remote/config selections, and
  an identity check before any GitHub mutation;
- serialized discovery-record writes so concurrent installs for different
  repositories cannot lose entries;
- refusal to replace ordinary user files or silently fall through from a
  selected but missing install.

The first implementation names the new tracked assets
`tools/approve_issues_service.py` and `tools/install_issue_approval.py`. The
installer uses the Kanban-owned `issue-approval` namespace under Application
Support and Logs, with a discovery record separate from the global
`issue-review/config.json`. It validates and resolves the canonical backend
through that existing issue-review record; if the backend is absent, it refuses
with the existing `tools/install_issue_review.py` remediation rather than
creating another backend installation.

This is deliberately a local macOS contract. The source and pure tests remain
CI-portable, and Kanban reports service control as unsupported elsewhere, but
the arc does not design another service manager or a provider-neutral daemon
abstraction.

The approval and PR-drainer services remain distinct jobs with distinct locks,
runtime roots, discovery records, and status types. Similarity is deliberate,
but their incidents mean different things and neither controller owns the
other's process.

Before starting or installing a supported run, the controller checks the
canonical backend lock. A legacy personal approval daemon holding it is not
adopted, killed, or treated as this service. Installation/start refuses with a
diagnostic naming the conflicting owner so the operator can stop it manually;
otherwise that daemon's skip-past-changes behavior could violate this service's
numeric barrier while both appeared enabled.

### Status, incidents, and restart behavior

Installation loads but does not start the job. The plist follows the drainer's
non-resident contract: `RunAtLoad=false`, `KeepAlive=false`, and no periodic
launchd trigger. Once explicitly started, the controller runs its own bounded
poll loop and outlives Kanban until explicitly stopped or until it exits
unexpectedly.

The controller publishes a versioned status document sufficient to distinguish
at least checking/starting, healthy running, intentional stop, ordered barrier,
child failure, controller failure, and unknown/unreadable state. It records the
current repository identity and process ownership needed to reject a foreign
or stale observation.

A changes-requested barrier is durable, issue-scoped, and self-clearing. It
names the positive issue number and the summary `Issue #N requests changes`.
It is warning severity, not a reviewer or process failure. While it is open,
the controller does no model work and checks only that issue's read-only gate
at the ordinary idle interval. A current canonical approval resolves the
incident and resumes the numeric queue. Stopping the service does not resolve
the barrier, just as stopping the drainer does not resolve a merge-conflict
incident; the next start rechecks it. A manual acknowledgement may dismiss the
record for bookkeeping but cannot let the queue cross an issue that still has
current changes-requested state. Error incidents cover unexpected exits,
malformed backend results, model/GitHub failures, and outcome-unknown runs.

### Dashboard lifecycle and concurrency

Kanban discovers the approval controller at startup, polls it on the same
event-driven cadence as the PR drainer, and stores its last observation
separately. Click/key actions use controller start/stop operations and show
optimistic transition states until an authoritative observation returns.

The backend approval lock remains the cross-process authority between the
service, selected-card `r`, another dashboard, and legacy invocations. The
service must not turn ordinary lock contention into a red pipeline incident:
it waits/retries with bounded backoff and status text that remains truthful.
At a changes-requested barrier the selected-card `r` workflow remains
available: its revision stage performs no canonical backend review, and its
eventual rereview can acquire the lock because the service is only performing
read-only gate checks. For any other issue while the service owns a live
canonical review, Kanban refuses a competing canonical stage with a notice to
wait or stop the service. The service holds the approval lock for at most one
issue review, releasing it between issues and before every idle/barrier wait,
so explicit work never waits behind an entire backlog.

Any service result that may have changed GitHub requests a board refresh. A
refresh never overwrites the service's durable warning/error state.

### Sidebar presentation and interaction

The bottom of the usage sidebar becomes a two-control stack. The approval
control is immediately above the drainer and deliberately reuses the same
button frame, padding, border policy, and status vocabulary:

```text
╭─────────────────╮
│ approve_issues.py │
╰─────────────────╯
on · unresolved
incident · Issue #254
requests changes

╭─────────────╮
│ drain_prs.py │
╰─────────────╯
off
```

The ordinary states use the drainer's text exactly: `checking…`, `starting…`,
green `on`, `stopping…`, and `off`. The issue barrier uses the drainer's exact
`on · unresolved incident · <summary>` composition and is yellow. Clicking or
pressing the key while yellow stops the enabled service, exactly as the drainer
button does; the durable barrier remains and a stopped service therefore uses
the drainer's red `stopped · unresolved incident · <summary>` composition.
Red also covers genuine error and unknown states. Lowercase `a` toggles the
approval service, while uppercase `A` remains the selected-issue autosolve
action.

## Decisions

### D-1. Extend the canonical backend instead of adding a second script

The requested behavior belongs in the tracked and installed
`tools/approve_issues.py`. No other reviewer owns canonical comments or labels.

### D-2. Numeric issue order is the queue order

The service considers open issues by ascending integer issue number, not
creation timestamp, update time, board position, or cached display order.

### D-3. Any current changes-requested issue is an ordered barrier

An earlier issue already in canonical `CHANGES_REQUESTED` state stops the pass
immediately. No greater issue number is reviewed until the barrier clears.

### D-4. The service is persistent

This is a per-repository managed service, not a foreground pass owned by one
dashboard. It follows the PR drainer's install/discovery/controller/status/log
conventions and survives Kanban exit.

### D-5. The button follows the drainer's presentation conventions

The approval control uses the same frame, placement style, transition words,
and green `on`/neutral `off` presentation as `drain_prs.py`. A
changes-requested state is yellow and names the issue number.

### D-6. Rich live progress is a follow-on design

This epic does not add `reviewing issue #N` or reviewer/model progress. After
the persistent service is complete, create a separate extension design
document for a progress protocol and richer in-flight UI.

### D-7. Queue review reuses canonical v2 semantics

Reviewer routing, models, legacy policy, spec fingerprints, worktrees,
comments, labels, incidents, configuration, identity, and the approval lock
remain owned by the existing backend rather than reimplemented in Haskell.

### D-8. A barrier pauses work without disabling the service

The approval service remains on and yellow, with exact detail
`on · unresolved incident · Issue #N requests changes`. It performs no model
work, checks only the barrier's read-only gate, clears the incident and resumes
automatically after canonical approval, and retains the barrier across an
intentional stop or restart.

### D-9. Persistence matches the drainer's non-resident lifecycle

Installation loads a stopped LaunchAgent and never starts work at install or
login. An explicit start creates a polling run that outlives Kanban until an
explicit stop or unexpected exit.

### D-10. Explicit barrier repair remains available while the service is on

The selected barrier issue's `r` workflow may revise and rereview it while the
service is paused on read-only checks. Competing canonical review of another
issue is refused while the service has a review in flight. The service releases
the backend lock between individual issues rather than owning it for its whole
lifetime.

### D-11. The service has a separate installer and namespace

Use `tools/install_issue_approval.py` for the per-repository service and
`tools/approve_issues_service.py` for its controller. Store its discovery,
runtime, incidents, and logs under a distinct `issue-approval` namespace. The
installer resolves the one global canonical backend through the existing
`issue-review` record and never makes another reviewer installation. Combining
service installation with `install_issue_review.py` was rejected because that
global backend is required by ordinary review workflows whose installation
must not create a repository LaunchAgent.

### D-12. The first runtime target is the operator's current macOS machine

Implement and document the launchd path needed locally. Keep pure code and
fixtures CI-portable and fail clearly on unsupported hosts, but do not add a
cross-platform service abstraction, generalized workflow-setup component, or
automatic login start in this epic.

### D-13. A legacy approval daemon is a conflict, not a migration source

The supported installer/controller never adopts or terminates an untracked
personal daemon. If one owns the canonical backend lock, install/start refuses
with a diagnostic so the operator can stop it manually before enabling the new
ordered service.

### D-14. Lowercase a toggles approval; uppercase A remains autosolve

Lowercase `a` starts or stops the persistent approval service from board scope,
with click invoking the identical action. Uppercase `A` retains its existing
selected-issue autosolve meaning, so the two workflows remain distinct in the
key table, footer, help overlay, and event routing.

### D-15. One backend invocation advances at most one issue

`--review-queue` scans from the lowest open number on every invocation, but it
performs model work for no more than the first issue that needs it. It then
returns `advanced`, `changes_requested`, `retry`, `busy`, or `idle` to the
controller. The controller owns repetition. This preserves the ordered barrier
while releasing the canonical lock between issues, as D-10 requires.

### D-16. Lock contention is a fifth normal outcome and the queue mode requires --json

Ordinary contention for the canonical approval lock is an expected condition
rather than a failure, so `--review-queue` reports it as a fifth normal outcome
`busy`. A `busy` pass exits zero, carries no issue number, performs no GitHub
mutation, records `model_called` as false, and names the current lock owner
in its caller-displayable text. It carries no issue number because contention
happens at lock acquisition, before the pass has selected an issue, so the
positive-issue-number rule that binds `advanced`, `changes_requested`, and
`retry` cannot apply to it. Result validation therefore rejects a `busy` result
that carries an issue number or claims a model call. Reporting contention
distinguishably is what lets the controller apply the bounded backoff that
"Dashboard lifecycle and concurrency" requires; that section, not D-10, is the
source of the rule that ordinary contention must never become a red pipeline
incident, while D-10 governs concurrent barrier repair and releasing the lock
between issues.

`--review-queue` additionally requires `--json`. Invoking it without `--json`
is a usage error rather than a human-readable pass, so no code path lets a log
line or diagnostic share stdout with the single result document the controller
parses.

## Open questions

### Q-1. Does a pre-existing changes-requested issue stop immediately?

Resolved by D-3.

### Q-2. Is the queue foreground or persistent?

Resolved by D-4.

### Q-3. Must the first release show the current issue while running?

Resolved by D-6. Preserve this as the seed for a follow-on progress-extension
design after the current epic is complete.

### Q-4. How does a persistent service recover from the ordered barrier?

Resolved by D-8.

### Q-5. What happens when the operator presses `r` while the service is on?

Resolved by D-10.

### Q-6. Should the service installer be separate from install_issue_review.py?

Resolved by D-11.

### Q-7. Which keyboard shortcut controls the approval service?

Resolved by D-14.

## Verification strategy

- Python backend tests prove numeric ordering, current-approval skips,
  pre-existing and newly produced barriers, no higher model invocation,
  incidents/invalid stops, legacy dual routing, lock exclusion, and exact
  result/exit semantics.
- Service/controller fixtures use fake `gh`, `codex`, and `claude`, temporary
  Git repositories, fake backend results, and temporary runtime/log roots to
  exercise idle polling, barriers, recovery, crashes, malformed results,
  signals, and status atomicity without a real account or network.
- Installer tests cover per-repository labels/plists, discovery-record locking,
  upgrades, custom install/config paths, identity collisions, ordinary-file
  refusal, idempotent reinstall, and uninstall behavior.
- Haskell pure/process tests cover discovery, status decoding, controller
  start/stop, timeout/process-group cleanup, transition races, warning/error
  mapping, configured identity, and unsupported platforms.
- UI event tests cover click/key parity, repeat-click refusal, monitor refresh,
  barrier persistence, board refresh after mutations, and selected-card review
  interaction.
- Golden frames cover approval off/on/starting/stopping/warning/error states
  above the drainer under supported sizes, borders, and color policies.
- Contract and packaging tests keep authoritative docs, dependency manifest,
  release inventory, installed assets, and both service boundaries in sync.

## Delivery plan

### IAQ-1. Add an ordered barrier-aware queue mode to the canonical backend

- **Outcome:** `approve_issues.py` runs one finite numeric pass and returns a
  validated result without continuing past any current changes-requested issue.
- **Scope:** Add `--review-queue`; separate ordered queue classification from
  legacy daemon selection; define the JSON result/exit contract; preserve the
  canonical lock, routing, publications, and cleanup; add Python tests.
- **Phase:** 1 — backend contract.
- **Depends on:** `none`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-1`, `D-2`, `D-3`, `D-7`, `D-15`, `D-16`.
- **Acceptance signals:** Fake-executable tests show ascending numeric calls,
  at most one model-reviewed issue per invocation, no call above a barrier,
  unchanged v2 publications, validated `idle`, `advanced`, `changes_requested`,
  `retry`, and `busy` results, and safe handling of concurrent lock ownership.
- **Out of scope:** Persistent supervision, Haskell, sidebar UI, and revision.
- **Open questions:** `None`.

### IAQ-2. Build the persistent issue approval controller and runtime

- **Outcome:** A foreground controller run can supervise repeated bounded
  backend passes with durable per-repository status, incidents, and logs.
- **Scope:** Add the controller/service loop, repository identity and runtime
  roots, atomic status/incident schemas, child process-group supervision,
  intentional-stop handling, barrier self-resolution, polling/backoff, and
  hermetic Python tests. Expose controller `run` and read-only `status`
  commands without installing a LaunchAgent yet.
- **Phase:** 2 — service runtime.
- **Depends on:** `IAQ-1`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-3`, `D-4`, `D-7`, `D-8`, `D-9`, `D-10`, `D-15`,
  `D-16`.
- **Acceptance signals:** Fixture runs remain alive across idle polls, review at
  most one issue under each backend lock, pause without model work at the
  barrier, auto-resolve only after a current approval, preserve the barrier on
  intentional stop, record unexpected exits, and write every runtime document
  atomically.
- **Out of scope:** LaunchAgent installation/discovery, Haskell, sidebar UI,
  live progress, and automatic specification repair.
- **Open questions:** `None`.

### IAQ-3. Install per-repository issue approval LaunchAgents

- **Outcome:** Each canonical repository can load one stopped approval-service
  job and explicitly start/stop it through an installed controller.
- **Scope:** Add the dedicated installer and controller install/start/stop/
  uninstall operations; stable managed links; one normalized job label, plist,
  runtime/log root, and discovery-record entry per repository; serialized
  discovery updates; identity and same-repository/multiple-checkout guards;
  dry-run, upgrade, refusal, and installer fixtures.
- **Phase:** 3 — installation and lifecycle control.
- **Depends on:** `IAQ-2`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-4`, `D-7`, `D-8`, `D-9`, `D-11`, `D-12`, `D-13`.
- **Acceptance signals:** Two repository installs coexist; a second checkout of
  one identity is refused while its job runs; install and login start nothing;
  explicit start outlives its caller; stop is intentional; reinstallation
  converges; ordinary files are preserved; custom config and install paths are
  rediscoverable without inherited environment.
- **Out of scope:** Haskell, sidebar UI, workflow-setup integration, and live
  progress.
- **Open questions:** `None`.

### IAQ-4. Expose issue approval service status and control to Kanban

- **Outcome:** Kanban can discover, monitor, start, and stop the correct
  repository's approval service and truthfully classify every service state.
- **Scope:** Add a focused Haskell service domain, discovery/status decoding,
  launchctl control, app state/events, monitor lifecycle, identity validation,
  concurrency notices, selected-card review policy, board refresh after
  possible mutation, and process fixtures.
- **Phase:** 4 — application lifecycle.
- **Depends on:** `IAQ-3`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-4`, `D-5`, `D-7`, `D-8`, `D-9`, `D-10`, `D-12`.
- **Acceptance signals:** Hermetic tests cover every state and malformed record,
  transition race, wrong-repository refusal, controller timeout/process-group
  cleanup, unsupported host, barrier repair with `r`, and refusal of competing
  canonical work while one service review is live.
- **Out of scope:** Sidebar drawing and live per-issue progress.
- **Open questions:** `None`.

### IAQ-5. Add the approve_issues.py sidebar control

- **Outcome:** Operators control and understand the persistent service from a
  new button immediately above `drain_prs.py`.
- **Scope:** Render the matching control; add clickable name, keyboard action,
  event routing, transition/refusal notices, theme mapping, help/footer text,
  authoritative key-contract updates, and golden/UI tests.
- **Phase:** 5 — operator experience.
- **Depends on:** `IAQ-4`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-5`, `D-6`, `D-8`, `D-9`, `D-14`.
- **Acceptance signals:** Click/key parity; exact `checking…`, `starting…`, green
  `on`, `stopping…`, and `off`; exact yellow
  `on · unresolved incident · Issue #N requests changes`; red stopped/error
  states; and stable stacking above the drainer at supported sizes.
- **Out of scope:** Progress-extension UI and automatic navigation to repair.
- **Open questions:** `None`.

### IAQ-6. Document local installation, operation, and recovery

- **Outcome:** Operators can install, diagnose, stop, recover, upgrade, and
  remove the approval service without relying on implementation knowledge.
- **Scope:** Finalize the local installer/status commands, service guide,
  agent-workflow authority and durable-state contract, development/release
  inventories, manual legacy-daemon conflict remedy, failure recovery, and the
  handoff to a future progress-extension design. Mention the service in
  workflow setup without adding it as a generalized setup component.
- **Phase:** 6 — operability and contract closure.
- **Depends on:** `IAQ-3`, `IAQ-4`, `IAQ-5`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-4`, `D-5`, `D-6`, `D-8`, `D-9`, `D-10`, `D-11`, `D-12`, `D-13`.
- **Acceptance signals:** Source-distribution tests contain every supported
  asset; the manual installer loads but starts no service; documentation names
  every local runtime path, command, and barrier-recovery rule; unsupported
  hosts get a clear diagnostic; the legacy launcher/daemon is not mistaken for
  the supported service.
- **Out of scope:** Implementing the progress extension itself.
- **Open questions:** `None`.
