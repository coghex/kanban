# Mission runner service design

Mission Control (`docs/designs/superagent_design.md`, epic #591) gives Kanban durable
missions, a typed action registry, durable issue workers, and a controller that
can advance one mission step and recover it. What it cannot do is keep going
once the operator closes the dashboard. This design adds the per-repository
service that owns that progression: a supervisor and scheduler that outlive the
TUI, install and discover themselves the way Kanban's two existing services do,
leave no stray process of their own behind while the detached workers they
dispatch keep owning their agents, and share the repository's capacity fairly
across missions while surviving provider limits and their own upgrades.

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Run missions without the dashboard through a per-repository service — [#597]
- [x] RUN-1. Add the mission runner service and its supervisor/scheduler runtime — [#666]
- [x] RUN-2. Install per-repository mission runner jobs with a dedicated installer and discovery record — [#667]
- [x] RUN-3. Discover, monitor, and control the mission runner from Kanban — [#668]
- [x] RUN-4. Own and reap the descendant tree across crash, timeout, and termination — [#744]
- [ ] RUN-5. Schedule missions fairly and survive capacity limits and upgrades
- [ ] RUN-6. Document installing, operating, and recovering the mission runner

## Epic contract

- **Goal:** An explicitly dispatched mission keeps launching and observing its
  eligible registered children after Kanban exits, and a later dashboard
  replays the complete durable session tree and follows its live tail.
- **Done when:** A per-repository service runs missions with no dashboard
  present; it installs, discovers, starts, stops, and reports status through
  the same machinery Kanban's drainer and issue-approval services already use;
  two runners cannot advance one mission; waiting for input performs no hidden
  work; no part of the runner's own chain outlives its parent, and each worker
  still owns and reaps its agent's processes; a step cut off mid-flight leaves
  its mission `interrupted` for the operator, and nothing retries it
  automatically; one opt-in generic notification is emitted per new attention
  identity; at most two mission-dispatched agents run at once per repository;
  runnable missions rotate without preemption or idle capacity;
  proven capacity limits release their slot and retry while authentication and
  configuration failures stop; a normal upgrade transfers the runner lease only
  after drain; and the operator has one accurate document for installing,
  operating, and recovering it.
- **Users and operators:** A maintainer running Kanban as the control surface
  for long-running agent work on one repository, who wants that work to
  continue when the terminal is closed.
- **Arc label:** `agent-workflows` (existing).

## Relationship to the Mission Control arc

This arc exists because `SAG-9` in `docs/designs/superagent_design.md` outgrew one
reviewable pull request. That document's `SAG-9` entry stays in its ledger and
links to **this** arc's umbrella epic rather than to a child issue, so epic
#591 keeps its "keeps advancing while the dashboard is closed" done-condition
and stays open until this arc completes. `SAG-9`'s outcome and acceptance
signals are the contract this arc must meet; the evidence for the split is
recorded in that document under "Why the runner became its own arc".

This arc as a whole was blocked by the Mission Control arc's `SAG-1` (#592),
`SAG-2` (#593), `SAG-10` (#594), and `SAG-3` (#595): it had no records to
advance, no actions to invoke, and no controller to supervise until those
landed. All four have landed.
Two Mission Control slices depend back into this one — `SAG-4` on `RUN-1`,
`RUN-3`, and `RUN-4`, and `SAG-5` on `RUN-1` — deliberately naming slices
rather than the whole arc, so the console is not serialized behind scheduling
policy, capacity waiting, upgrade drain, or notifications.

## Current state and evidence

### Verified current state

Re-measured against master `5cbcf1ad` on 2026-09-28, after RUN-1 (#666),
RUN-2 (#667), and RUN-3 (#668) merged. The original survey was taken at
`8983a33` on 2026-08-31.

- **The runner is now the third instance of the service shape.** The PR
  drainer (`src/Kanban/Drainer.hs`, 1,710 lines; `tools/drain_prs.py`, 7,133;
  `tools/install_drainer.py`, 4,511), the persistent issue-approval service
  (`src/Kanban/ApprovalService.hs`, 1,250; `tools/install_issue_approval.py`,
  973), and now the mission runner (`tools/mission_runner_service.py`, 4,010;
  `tools/install_mission_runner.py`, 1,137; `src/Kanban/MissionRunnerService.hs`,
  1,538) all run as service-manager jobs with an installer, a discovery record,
  and durable status and incidents.
- **What RUN-1 shipped.** The service job runs `tools/mission_runner_service.py`,
  a Python wrapper that holds a per-repository advisory lock, publishes status
  and incident documents, and repeats one-shot `kanban --mission-scheduler`
  passes. Each pass runs in a new session whose process group the wrapper
  signals on stop, admits at most two runnable missions (a compiled value,
  #666 requirements 2–3), advances each through its own `kanban --mission <id>`
  child, waits for those children, and writes one JSON pass report. Attention
  notifications go through an opt-in, operator-configured command, at most once
  per attention identity.
- **Agent work runs in detached persistent workers, not in the runner's tree.**
  A `--mission` step hands its work to a worker started by
  `spawnDetachedSupervisor` (`src/Kanban/Worker.hs`, `new_session = True`), and
  the handoff returns as soon as the worker's durable handle exists
  (`Kanban.Action.Dispatch`). Each worker owns its item's lease, its agent's
  process tree, and its deadline: `watchdogLoop` (`src/Kanban/Worker.hs:1689`)
  terminates the provider group and every recorded process when the
  configurable `worker_deadline_seconds` (four hours by default) expires, and
  the worker refuses to call itself terminal while recorded descendants survive,
  reporting them orphaned until they exit or are killed.
- **The service-manager boundary is shared.** `tools/service_manager.py`
  (1,108 lines) defines `ServiceManagerBackend` with exactly two
  implementations, `LaunchdBackend` and `SystemdBackend`, and three namespaces:
  `DRAINER_NAMESPACE`, `ISSUE_APPROVAL_NAMESPACE`, and
  `MISSION_RUNNER_NAMESPACE`. `Kanban.ServiceProcess` (264 lines) carries the
  Haskell side of a service transition for all three controls.
- **Discovery records have one resolution point per language.**
  `Kanban.ManagedPaths` resolves a managed component's record, XDG location
  first and `~/Library` second on both platforms, and is the Haskell
  counterpart of `tools/kanban_config.py`. `ManagedComponent` has three
  constructors: `IssueReviewComponent`, `DrainerComponent`, and
  `MissionRunnerComponent`.
- **The mission store** lives under
  `$XDG_STATE_HOME/kanban/missions/<owner>-<repo>/` (#592). It already provides
  an archive and a seal for session logs — `sealMissionLog` with its digest —
  but nothing in production calls it yet.
- **The recovery vocabulary exists but one state is never produced.** A
  `--mission` process journals a step's intent before attempting it, and on the
  next pass reconciliation answers live registered work first: a step whose
  worker is still alive is observed, not redone, and a recorded invocation with
  no conclusion becomes `outcome_unknown`, which stops the mission for the
  operator (`Kanban.Mission.Reconcile`). `MissionStepInterrupted` and the
  `interrupted` mission lifecycle exist and are honoured when present, but no
  code sets a step interrupted. The `--mission` console's `override <step>`
  resolves an unknown outcome and replans the step, and `terminate <session>`
  ends a registered mission-session subtree (#595).
- **The runner's entry point is #595's.** `kanban --mission` acquires the
  mission lease and deliberately not the one-board-per-repository lease
  (`acquiresRepositoryLease` is `(== DashboardMode) . launchMode`,
  `src/Kanban/CLI.hs:239`).
- A repository-scoped tracker search on 2026-08-31 found no open or closed
  issue or epic covering a mission runner service. #318 and #122 are the two
  service arcs whose machinery this one reuses, and neither is a duplicate.

### Settled since the first survey

- The runner's discovery-record schema and path spelling were settled by RUN-2
  (#667): a third managed component resolved through `ManagedPaths` and
  `tools/kanban_config.py`.
- The incident vocabulary was settled by RUN-1 (#666), following the existing
  services' status and incident documents.

## Desired experience

1. The operator turns the mission runner on for a repository the same way they
   turn on the PR drainer and the issue-approval service: one control, one
   installed job, one visible status.
2. They dispatch a mission and close Kanban. The runner completes the current
   child, dispatches the next authorized one, and records both full logs.
3. They reopen Kanban later. The same mission is there, its complete session
   tree replays, and the display follows the live tail without restarting the
   plan or creating replacement children.
4. When a mission needs a decision, the runner stops and — if this repository
   has opted in — its configured notification command is told once that a
   target needs attention, and nothing more.
5. When the runner or the host dies, agents already working keep working under
   their own workers, and missions resume on the next pass once the service is
   back. Only a mission whose step was cut off mid-flight is `interrupted`: it
   waits for the operator, nothing retries it, and the operator recovers it
   with `override`, which replans the step.
6. When a provider's quota is exhausted, the mission releases its slot, waits,
   and retries. When authentication or configuration is wrong instead, it stops
   and says so.
7. When Kanban is upgraded, the old runner drains, seals what it owns, and
   hands the lease over exactly once. What the drain waits for is Q-2.

## Scope

### In scope

- A per-repository mission runner service: a small supervisor that owns a
  scheduler, both outliving the dashboard, with the service manager providing
  outer containment for supervisor failure.
- Mission arbitration: one runner advancing one mission at a time, over #592's
  mission lease, without replacing the per-target worker lease or the canonical
  approval lock.
- Start, wake, idle/wait, and stop behavior, including performing no hidden
  work while a mission waits for operator input.
- Durable status and incidents readable by the dashboard, following the
  existing services' shape.
- Installation, uninstallation, and a discovery record, through
  `tools/service_manager.py`'s existing backend boundary.
- Kanban-side discovery, status decoding, start/stop control, and event-reader
  reattachment to a running runner's mission events.
- Structured ownership of the runner's own chain — wrapper, scheduler pass,
  and `--mission` children — with identity-verified settlement of anything a
  crashed layer left behind (D-2). Detached workers keep owning their agents'
  process trees and deadlines.
- Marking a step cut off mid-flight `interrupted`, and manual recovery of it
  (D-3).
- Session-log sealing into the mission archive before the worker cache may
  collect the source.
- Work-conserving round-robin admission across equal-priority autonomous
  missions, foreground priority for direct operator commands, and the
  repository's ceiling of two running agents (D-4).
- Durable provider-capacity waits that release the slot and retry.
- Drain-before-handoff on a normal upgrade.
- An opt-in, privacy-minimal attention notification through an
  operator-configured command.
- Operating documentation for installation, control, troubleshooting, and
  recovery.

### Out of scope

- The console, its hotkeys, mission navigation, and rendering — Mission
  Control's `SAG-4`.
- Batch membership, ordering, and stop policy — Mission Control's `SAG-5`.
- Natural-language planning and recommendation application — `SAG-6`, `SAG-7`.
- The durable mission records themselves (#592), the action registry (#593),
  the durable issue workers (#594), and the controller's own reconciliation and
  recovery logic (#595). This arc supervises that controller; it does not
  reimplement it.
- Automatically retrying a step cut off mid-flight. Its recovery stays manual
  and operator-initiated (D-3).
- The workers' own process-tree reaping and deadlines, which #594 and #595
  already ship.
- Merging pull requests, under any circumstances. The PR drainer remains the
  only component that merges.
- Cross-repository scheduling or a host-wide budget above the per-repository
  runners.
- Provider-native internal subagent presentation.

## Design

### Ownership layers

Because a process cannot clean up after its own crash, every executable parent
sits inside a longer-lived ownership boundary. What shipped has two ownership
domains rather than one tree (D-2, as amended).

The runner's own chain: the service manager's job provides outer containment
and runs `tools/mission_runner_service.py`; that wrapper runs one-shot
`kanban --mission-scheduler` passes, each in its own process group; and a pass
runs one `kanban --mission` child per admitted mission and waits for them. Each
layer records its children's identities before launching them, and a layer's
exit is observed by the layer above it, which settles what it left.

The workers: a `--mission` step hands agent work to a detached persistent
worker and returns once the worker's durable handle exists. The worker, not
the runner, owns that agent's process tree, its lease, and its deadline, and
outlives the process that dispatched it. The runner stopping or dying never
terminates a worker; the next pass reconciles against it.

A host whose service manager cannot supply a trustworthy outer containment and
refusal boundary is unsupported rather than allowed to leak runner processes.

### What the runner does not decide

The runner supervises #595's controller; it does not duplicate it. Dispatch
decisions, reconciliation against live GitHub and worker state, version
preconditions, `outcome_unknown` classification, and the advance-or-stop
judgment all remain the controller's. This arc owns *when the controller gets
to run*, *what it is allowed to run concurrently*, and *what happens to
processes when something dies*.

### Status, incidents, and the dashboard

The runner writes durable status the dashboard reads rather than pushing state
into it, exactly as the drainer and approval service do. A dashboard is a
read-and-steer client: it discovers the runner, acquires no competing
advancement lease, replays unconsumed mission and session events, and
subscribes to new ones.

### Recovery boundary

A runner crash, logout, or machine restart interrupts only a mission whose
step was cut off mid-flight: its intent journaled by a `--mission` process that
died before any worker handle or conclusion was recorded. That step is marked
`interrupted`, the mission stops for the operator, and nothing retries it; the
operator recovers it with `override`, which replans the step. Every other
mission resumes on the next pass once the service is back, reconciling against
live workers first so no step is dispatched twice (D-3, as amended). Ordinary
TUI exit stops nothing.

## Decisions

Each decision below was signed off in `docs/designs/superagent_design.md` and is
restated here, with its source, so this document is readable on its own. The
source document keeps its own numbering unchanged.

### D-1. Explicit missions keep advancing after the TUI exits

From superagent `D-9`. A repository mission runner, not the dashboard, owns
progression. Closing Kanban leaves the runner and its children active, and
reopening attaches to their durable state instead of restarting them.
Persistence belongs to the runner and the mission records; model agents remain
bounded processes.

### D-2. Session descendants use structured concurrency

From superagent `D-14`. Every registered child has one tracked parent. A parent
joins its children before normal completion, and parent failure, timeout,
cancellation, or kill recursively terminates and reaps the entire descendant
subtree. No child is reparented or allowed to become a stray agent.

**Amended, 2026-09-28.** What shipped does not form one tree. The service job
runs `tools/mission_runner_service.py`, which runs one-shot
`kanban --mission-scheduler` passes in their own process group. Those run
`kanban --mission` children, which hand agent work to detached persistent
workers (`spawnDetachedSupervisor`, in their own session). Handing work off
returns once the worker's durable handle exists (#594, `Kanban.Action.Dispatch`).
Structured concurrency therefore applies at two levels rather than one. The
runner owns its own chain — wrapper, pass, and `--mission` children — and
nothing in it outlives the layer above. Each worker owns its agent's process
tree, with its own lease, its `worker_deadline_seconds` watchdog, and its orphan
handling. A worker is not the runner's child, and the runner stopping or dying
never terminates one. The explicit, recursive `terminate` command for a
registered mission session stays as #595 built it.

**Amendment signed off:** by the user, 2026-09-28.

### D-3. Runner or host failure requires manual, contextual recovery

From superagent `D-15`. Ordinary TUI exit leaves the live runner alone, but
runner crash, logout, or machine restart marks its nonterminal missions
`interrupted` and starts nothing automatically. The normal action hotkey
initiates recovery: settle the old descendant tree, reconcile outcome-unknown
effects, inspect and preserve any existing worktree, and give a fresh process
the failure and work-in-progress handoff.

**Amended, 2026-09-28.** A runner crash, logout, or restart no longer marks
every unfinished mission interrupted. Only a mission whose step was cut off
mid-flight becomes `interrupted`: its intent was journaled by a `--mission`
process that died before any worker handle or conclusion was recorded. That
step is marked interrupted rather than `outcome_unknown`, the mission stops for
the operator, and nothing retries it automatically. A step whose worker is
still alive, and a mission whose next step never started, resume on the next
pass, including when the service comes back after a crash. Recovery stays
manual for an interrupted mission: the operator resolves the step with the
existing `override` command (#595), which replans it. Reaching that from the
dashboard's action hotkey is Mission Control's SAG-4. An `outcome_unknown` that
doesn't come from a dead process, such as a worker that ended with no
conclusive evidence, keeps its current meaning.

**Amendment signed off:** by the user, 2026-09-28.

### D-4. Two mutation-capable agent children may run per repository by default

From superagent `D-19`. The initial configurable admission ceiling is two
simultaneously running mutation-capable agent children across all missions for
one canonical repository. Dependencies and lower-level authorities may
serialize further; explicit configuration may lower or raise the ceiling.

**Amended, 2026-09-28.** The ceiling counts running agents, not missions. At
most two mission-dispatched workers running a provider agent (a solve, a
pull-request task, or one issue-review host child) may be live at once for one
canonical repository, across all missions and across passes. A pass starts no
step that would make a third. The limit stays configurable, as originally
decided, with two as the default. RUN-1 shipped a fixed limit of two missions
per pass (#666, requirements 2–3). Because workers are detached and a pass
doesn't wait for them, successive passes can leave more than two agents
running, so that limit does not implement this decision. Work launched from
the board outside a mission does not count.

**Amendment signed off:** by the user, 2026-09-28.

### D-5. New operator commands outrank queued autonomous children

From superagent `D-22`. A newly dispatched direct command receives the next
compatible repository slot before autonomous batch work that has not started.
Running work is never preempted, and priority never bypasses dependencies or
lower-level authority locks.

### D-6. Desktop attention notifications are opt-in and privacy-minimal

From superagent `D-24`. Each repository may opt into one desktop notification
when a new operator-required attention ID is created. The text contains only
repository, typed target, and "needs attention" — never titles,
recommendations, source content, or paths.

### D-7. Agent executions default to four hours while missions remain indefinite

From superagent `D-25`. Every agent process has a configurable finite deadline
with four hours as its default and a documented finite maximum. A hard timeout
kills and reaps the process tree and stops for the operator unless a verified
idempotent continuation was already published. The durable mission has no
corresponding lifetime limit.

### D-8. Equal-priority autonomous missions use work-conserving round-robin

From superagent `D-26`. The scheduler durably rotates admissions across
runnable autonomous missions, one admission per mission per pass, preserving
each mission's internal ordering and barriers. Blocked missions are skipped,
and one mission may reuse otherwise idle capacity when no peer can run.

### D-9. Transient provider capacity retries without occupying a slot

From superagent `D-27`. A positively identified rate limit or exhausted quota
records `waiting_capacity`, releases the repository slot, and retries at the
provider's reset time or through bounded exponential backoff. This survives
ordinary TUI absence but not a runner failure. Authentication, executable,
provider-selection, and configuration failures stop for the operator.

### D-10. Normal runner upgrades drain before handoff

From superagent `D-28`. The old runner enters a durable drain state, admits no
new work, lets its current bounded children settle, seals their logs and state,
and releases the runner lease before the new binary validates and takes
ownership. Commands accepted during drain stay queued. A forced or incompatible
upgrade becomes interrupted work requiring manual recovery.

### D-11. Mission logs and lineage outlive the worker cache

From superagent `D-12`. Reattachment after a long absence includes the full
durable mission history and every managed child log, including sessions
completed while Kanban was closed. Before a live child's provider log becomes
eligible for worker-cache collection, the runner seals the complete stream into
the mission archive and records its digest and byte length.

### D-12. Mission Control never merges

From superagent `D-8`. Nothing in this arc merges a pull request. The PR
drainer remains the only component that merges eligible pull requests, and the
runner's authority does not change that.

### D-13. The runner reuses Kanban's existing service machinery

New to this document, and the reason the arc is six slices rather than a
rewrite. The runner installs through `tools/service_manager.py`'s existing
`ServiceManagerBackend` boundary, resolves its discovery record through the one
per-language resolution point, transitions through `Kanban.ServiceProcess`, and
follows the drainer's and approval service's status/incident shape. A third
managed job adds a namespace and a `ManagedComponent`, not a second mechanism.

### D-14. The runner installs per repository, and the host-wide budget is a later arc's

The runner is installed and discovered once per repository, matching the PR
drainer and the issue-approval service and matching the fact that mission
records are repository-qualified. Its admission ceiling (`D-4`) is therefore a
per-repository ceiling, and two repositories' runners do not coordinate.

A host- or provider-wide budget sitting above the per-repository runners is a
real future need — superagent `D-19` records it — but it is out of scope here
and belongs with the multi-repository board work (#354), which is where a
second repository first exists to contend with. Nothing in this arc's durable
records or configuration prevents adding one later: a host-wide limiter would
gate admission above these runners rather than replace their ceilings.

## Open questions

### Q-1. Does the runner install per repository or once per host?

Resolved by D-14. Per repository, matching both existing services; a host-wide
admission budget is deferred to the multi-repository arc.

### Q-2. What does an upgrade drain wait for, now that workers are detached?

D-10 assumed the runner owned its running children. (a) The old runner stops
starting passes, lets its current pass and `--mission` children finish, and
hands over without waiting for detached workers, which finish under the binary
that launched them. (b) It also waits for every mission-dispatched worker to
finish first.

**Proposal:** (a). Deliberately open: RUN-5 stops and asks here before its
drain requirement is written. RUN-4 does not depend on the answer.

## Verification strategy

- No-TUI fixtures are the arc's signature test: dispatch a mission, exit the
  dashboard, let the runner complete one child and dispatch the next, then
  reopen and prove the complete tree and logs replay without rerun.
- Two-process fixtures prove arbitration: a second runner cannot advance a
  mission the first holds, and a dashboard's presence never grants it an
  advancement lease.
- Runner-chain fixtures kill the wrapper, a pass, and a `--mission` child in
  turn, and prove the layer above settles what was left, with identity checks,
  before anything new starts; an unverifiable survivor blocks settlement. A
  detached worker survives every one of those deaths and is reconciled, not
  redone.
- Interrupted-step fixtures kill a `--mission` process between journaling a
  step and recording its worker, and prove the mission becomes `interrupted`,
  is never retried by a later pass or a service restart, and is recovered by
  `override`; a mission whose worker is healthy through the same crash resumes
  with no duplicate dispatch.
- Installer fixtures follow the existing services' suites: install, reinstall,
  relocate, repair a missing or stale discovery record, and uninstall, on both
  service-manager backends.
- Scheduler fixtures enforce the repository ceiling across concurrent missions,
  preserve lower serialized locks, show configured and provider limits pause
  only new admission, give a new direct command the next compatible slot
  without preempting running work, and preserve a durable round-robin cursor
  across restart.
- Capacity fixtures distinguish explicit rate-limit and reset evidence from
  authentication and configuration failures, release the slot, persist a known
  reset or bounded backoff, and retry while the TUI is absent without spinning.
- Upgrade fixtures put the old runner into drain, queue a concurrent command,
  settle and seal live children, transfer the lease exactly once, and prove a
  forced or incompatible handoff becomes interrupted.
- Deadline enforcement is the worker's and is already covered by its own
  suite (`worker_deadline_seconds`); this arc's fixtures only prove the runner
  never shortens or bypasses it.
- Notification fixtures use a fake notification command, prove one generic notice per
  attention ID, and reject sensitive content fields.
- Documentation is verified by following it: the operating guide's commands and
  paths are the ones the tests exercise.

## Delivery plan

### RUN-1. Add the mission runner service and its supervisor/scheduler runtime

- **Outcome:** A mission runner process supervises #595's controller, advances
  one repository's missions with no dashboard present, arbitrates over the
  mission lease, and publishes durable status and incidents.
- **Scope:** The supervisor and scheduler split; outer-containment contract;
  start, wake, idle/wait, and stop behavior; mission arbitration over the
  mission lease; durable status and incident records; the opt-in desktop
  notification adapter; the no-TUI progression fixture.
- **Phase:** 1 — the service itself.
- **Depends on:** `none` within this arc; blocked by the Mission Control arc's
  `SAG-3` (#595), which provides the controller and its foreground entry point.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-1`, `D-3`, `D-6`, `D-12`, `D-13`.
- **Acceptance signals:** After the TUI exits, the runner completes one child,
  dispatches the next authorized child, and records both full logs; two runners
  cannot advance one mission; waiting for input performs no hidden work; status
  and incidents are readable from durable records; one generic notification is
  emitted per new attention identity only when the repository opted in.
- **Out of scope:** Installation and discovery, the dashboard side, descendant
  reaping policy, scheduling fairness, capacity, and upgrade drain.
- **Open questions:** `None`.

### RUN-2. Install per-repository mission runner jobs with a dedicated installer and discovery record

- **Outcome:** The runner installs, reinstalls, relocates, repairs, and
  uninstalls as a managed job on both supported service managers, and writes a
  discovery record the one per-language resolution point can find.
- **Scope:** The installer; the discovery record and its path convention;
  `tools/service_manager.py` namespace and definition; per-repository log
  directories; the `ManagedPaths`/`kanban_config.py` component addition;
  installer test suite on both backends.
- **Phase:** 2 — installation.
- **Depends on:** `RUN-1`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-13`, `D-14`.
- **Acceptance signals:** Install, reinstall, relocate, stale-record repair, and
  uninstall all succeed on launchd and on systemd user units; the record is
  found where an existing installation already sits, XDG spelling probed first;
  a fresh install writes this platform's own default.
- **Out of scope:** The dashboard control, and any change to the two existing
  installed components.
- **Open questions:** `None`; `D-14` settles per-repository installation.

### RUN-3. Discover, monitor, and control the mission runner from Kanban

- **Outcome:** Kanban discovers an installed runner, decodes its status and
  incidents, starts and stops it, and reattaches its event reader to a running
  runner's mission events.
- **Scope:** Discovery through the resolved record; status and incident
  decoding; the start/stop seam through `Kanban.ServiceProcess`; event-reader
  reattachment and live-tail following; unavailable-state vocabulary.
- **Phase:** 3 — dashboard integration.
- **Depends on:** `RUN-2`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-1`, `D-11`, `D-13`.
- **Acceptance signals:** A reopened dashboard finds the runner, replays every
  unconsumed mission and session event, and follows the live tail; it acquires
  no advancement lease; an uninstalled, unreadable, or stopped runner reports a
  distinct state rather than an error.
- **Out of scope:** Console rendering and hotkeys, which are Mission Control's
  `SAG-4`. This slice provides what that slice reads.
- **Open questions:** `None`.

### RUN-4. Own and reap the descendant tree across crash, timeout, and termination

> Filed as [#744], depending on [#666]. The killed-wrapper premise was verified
> from the code at filing: only the stop handler signals the pass, the pass
> leads its own session, and a new wrapper never checks the recorded
> `pass_pid`. Filing also found the worker-cache collector can remove a mission
> worker's logs before they are sealed, so #744 keeps unsealed mission logs.
> Epic #597 was edited in the same step for amended D-2, D-3, and D-4.

- **Outcome:** The runner's own chain never leaves a stray process. A step cut
  off mid-flight marks its mission `interrupted` and waits for the operator.
  Every mission session's log is sealed into the mission archive.
- **Scope:** Settle a scheduler pass and its `--mission` children that a
  crashed wrapper left behind, with identity checks, before the next wrapper
  starts a pass — whether a killed wrapper really leaves its pass running is to
  be verified at filing time, since the pass leads its own session and
  plausibly survives. Mark a cut-off step `interrupted` and recover it through
  `override` (D-3). Call the existing but unused `sealMissionLog`, so a
  session's complete log and digest are archived before the worker cache may
  remove the original (D-11).
- **Phase:** 4 — ownership and death.
- **Depends on:** `RUN-1`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-2`, `D-3`, `D-11`.
- **Acceptance signals:** A killed wrapper's leftover pass is settled before
  the next one starts, and no mission advances twice; a `--mission` killed
  between journaling a step and recording its worker leaves the mission
  `interrupted`, never retried, and `override` recovers it; a mission whose
  worker is healthy through a runner crash resumes with no duplicate dispatch;
  a sealed log verifies after its source is removed.
- **Out of scope:** The workers' own process-tree cleanup and deadlines, which
  already ship (D-2, D-7); scheduling fairness, capacity waiting, and upgrade
  drain (RUN-5); reaching recovery from the dashboard's action hotkey
  (Mission Control's `SAG-4`).
- **Open questions:** `None`.

### RUN-5. Schedule missions fairly and survive capacity limits and upgrades

- **Outcome:** Concurrent missions share the repository's capacity by durable
  round-robin, direct operator commands take the next slot without preempting,
  proven provider limits release the slot and retry, and a normal upgrade
  transfers the runner lease only after drain.
- **Scope:** The repository's ceiling of two running mission-dispatched agents
  and its configuration (D-4, as amended), replacing RUN-1's compiled
  two-missions-per-pass limit as the capacity rule;
  work-conserving round-robin with a durable cursor; foreground priority for
  direct commands; capacity classification, slot release, reset/backoff, and
  retry; drain state, queued commands during drain, and single lease handoff.
- **Phase:** 5 — scheduling policy.
- **Depends on:** `RUN-1`, `RUN-4`.
- **Ordering:** `critical path` for the epic; `not on the critical path` for
  Mission Control's console, which does not depend on it.
- **Relevant decisions:** `D-4`, `D-5`, `D-8`, `D-9`, `D-10`.
- **Acceptance signals:** No more than two mission-dispatched agents run at
  once across missions and across passes, and the ceiling does not weaken
  lower serialized locks; a new direct command gets the next
  compatible slot without preempting; the round-robin cursor survives restart,
  skips blocked missions, and reuses idle capacity; a rate limit releases its
  slot and retries at reset while an authentication failure stops; a drain
  settles children, seals state, and hands the lease over exactly once; a forced
  handoff becomes interrupted rather than two schedulers.
- **Out of scope:** Cross-repository or host-wide budgets, and batch membership
  and ordering, which are Mission Control's `SAG-5`.
- **Open questions:** `Q-2`, deliberately open: before the drain requirement
  is written, stop and ask what a drain waits for. `D-14` settles
  per-repository installation.

### RUN-6. Document installing, operating, and recovering the mission runner

- **Outcome:** Operators have one accurate document for installing, starting,
  stopping, inspecting, troubleshooting, and recovering the mission runner, and
  the repository's steering documents agree with what shipped.
- **Scope:** The operating guide, with recovery and troubleshooting
  procedures. RUN-1 through RUN-3 already added their own contract and
  inventory entries to `docs/design.md` and `docs/agent-workflow-contract.md`;
  this slice adds the entries RUN-4 and RUN-5 introduce and reconciles the
  rest with what shipped.
- **Phase:** 6 — operability.
- **Depends on:** every implemented slice; documentation for a deferred slice
  stays in this design rather than claiming shipped behavior.
- **Ordering:** `critical path` for epic completion.
- **Relevant decisions:** `D-1` through `D-14`.
- **Acceptance signals:** Documented commands and paths match tested behavior;
  every executable and durable record this arc adds has an authority and
  ownership entry; an operator can distinguish stopped, idle, waiting,
  interrupted, and failed.
- **Out of scope:** Tracker drafting and implementation of deferred choices.
- **Open questions:** `None`.
