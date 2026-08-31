# Mission runner service design

Mission Control (`docs/superagent_design.md`, epic #591) gives Kanban durable
missions, a typed action registry, durable issue workers, and a controller that
can advance one mission step and recover it. What it cannot do is keep going
once the operator closes the dashboard. This design adds the per-repository
service that owns that progression: a supervisor and scheduler that outlive the
TUI, install and discover themselves the way Kanban's two existing services do,
own their descendant processes strictly enough that no verified parent death
leaves a live agent, and share the repository's capacity fairly across missions
while surviving provider limits and their own upgrades.

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Run missions without the dashboard through a per-repository service — [#597]
- [ ] RUN-1. Add the mission runner service and its supervisor/scheduler runtime
- [ ] RUN-2. Install per-repository mission runner jobs with a dedicated installer and discovery record
- [ ] RUN-3. Discover, monitor, and control the mission runner from Kanban
- [ ] RUN-4. Own and reap the descendant tree across crash, timeout, and termination
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
  work; no verified parent death and no timeout leaves a live descendant; a
  runner crash leaves its missions `interrupted` and starts nothing
  automatically; one opt-in generic notification is emitted per new attention
  identity; runnable missions rotate without preemption or idle capacity;
  proven capacity limits release their slot and retry while authentication and
  configuration failures stop; a normal upgrade transfers the runner lease only
  after drain; and the operator has one accurate document for installing,
  operating, and recovering it.
- **Users and operators:** A maintainer running Kanban as the control surface
  for long-running agent work on one repository, who wants that work to
  continue when the terminal is closed.
- **Arc label:** `agent-workflows` (existing).

## Relationship to the Mission Control arc

This arc exists because `SAG-9` in `docs/superagent_design.md` outgrew one
reviewable pull request. That document's `SAG-9` entry stays in its ledger and
links to **this** arc's umbrella epic rather than to a child issue, so epic
#591 keeps its "keeps advancing while the dashboard is closed" done-condition
and stays open until this arc completes. `SAG-9`'s outcome and acceptance
signals are the contract this arc must meet; the evidence for the split is
recorded in that document under "Why the runner became its own arc".

This arc as a whole is blocked by the Mission Control arc's `SAG-1` (#592),
`SAG-2` (#593), `SAG-10` (#594), and `SAG-3` (#595): it has no records to
advance, no actions to invoke, and no controller to supervise until those land.
Two Mission Control slices depend back into this one — `SAG-4` on `RUN-1`,
`RUN-3`, and `RUN-4`, and `SAG-5` on `RUN-1` — deliberately naming slices
rather than the whole arc, so the console is not serialized behind scheduling
policy, capacity waiting, upgrade drain, or notifications.

## Current state and evidence

### Verified current state

Measured against master `8983a33`.

- **Kanban has built this shape twice.** The PR drainer
  (`src/Kanban/Drainer.hs`, 1,394 lines; `tools/drain_prs.py`, 5,875;
  `tools/install_drainer.py`, 4,491) and the persistent issue-approval service
  (`src/Kanban/ApprovalService.hs`, 1,250; `tools/install_issue_approval.py`,
  973) both run as service-manager jobs with an installer, a discovery record,
  durable status and incidents, and a dashboard control. This arc is the third,
  and should consume their machinery rather than build a parallel one.
- **The service-manager boundary already exists and is already portable.**
  `tools/service_manager.py` (1,089 lines) defines `ServiceManagerBackend` as
  an abstract base with exactly two implementations, `LaunchdBackend` and
  `SystemdBackend`, plus `ServiceNamespace`, `ServiceDefinition`,
  `UninstallOutcome`, and the definition-file writers. A third managed job adds
  a namespace, not a backend.
- **The Haskell side of a service transition is also shared.**
  `Kanban.ServiceProcess` (264 lines) exposes `runGroupedProcess`,
  `serviceTransitionCommand`, `InvocationFailure`, and its diagnostic
  vocabulary, which both existing controls use.
- **Discovery records have one resolution point per language.**
  `Kanban.ManagedPaths` answers where a managed component's record is —
  the XDG location first and the `~/Library` location second on both platforms,
  taking the first that is occupied, and this platform's own write default when
  neither is — and it is the Haskell counterpart of `tools/kanban_config.py`.
  `ManagedComponent` currently has exactly two constructors,
  `IssueReviewComponent` and `DrainerComponent`.
- **The path convention is settled by precedent.** `docs/design.md` §17 places
  the drainer's discovery record under `~/Library/Application Support/kanban/pr-drainer`
  on macOS and `$XDG_DATA_HOME/kanban/pr-drainer` elsewhere, and its
  per-repository logs under `~/Library/Logs/kanban/pr-drainer` and
  `$XDG_STATE_HOME/kanban/pr-drainer`. The mission store this arc drives is
  under `$XDG_STATE_HOME/kanban/missions/<owner>-<repo>/` by #592.
- **The runner's entry point is #595's, not a new one.** That slice adds a
  foreground launch mode that runs the controller against one repository,
  acquires the mission lease, and deliberately does not acquire the
  one-board-per-repository lease (`acquiresRepositoryLease` is
  `(== DashboardMode) . launchMode`, `src/Kanban/CLI.hs:143`). This arc
  installs that same entry point as a service rather than inventing a second.
- **Per-execution deadline enforcement already exists at the worker.**
  `watchdogLoop` (`src/Kanban/Worker.hs:1219`) terminates the provider group and
  every recorded process on expiry, and #595 makes the duration configurable.
  What this arc adds is enforcing it across a runner-launched *descendant tree*
  without leaking children.
- **The worker layer already refuses to declare a parent terminal while
  recorded descendants survive**, reporting them orphaned until they exit or are
  killed. The mission session tree generalizes that invariant; it does not
  invent it.
- A repository-scoped tracker search on 2026-08-31 found no open or closed
  issue or epic covering a mission runner service. #318 and #122 are the two
  service arcs whose machinery this one reuses, and neither is a duplicate.

### Not yet established

- Whether the runner's discovery record should be a third `ManagedComponent`
  or something the mission store itself carries is an implementation question
  for `RUN-2`, not a product decision.
- The exact incident vocabulary. `RUN-1` should follow `ApprovalService`'s
  `ApprovalIncident`/`ApprovalSeverity` shape rather than invent one, but the
  specific incident kinds fall out of implementation.

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
   has opted in — one desktop notification says a target needs attention, and
   nothing more.
5. When the runner or the host dies, its missions are `interrupted`. Nothing
   resumes on its own. The ordinary action hotkey starts one contextual
   recovery that settles the old descendant tree before any fresh agent starts.
6. When a provider's quota is exhausted, the mission releases its slot, waits,
   and retries. When authentication or configuration is wrong instead, it stops
   and says so.
7. When Kanban is upgraded, the old runner drains its live children, seals
   their state, and hands the lease over exactly once.

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
- Structured descendant ownership: every registered child recorded before
  launch, a parent never terminal while a registered child survives, cascading
  termination deepest-first, and identity-verified reaping.
- Deadline enforcement across a runner-launched descendant tree, and
  interrupted/manual recovery after runner or host failure.
- Session-log sealing into the mission archive before the worker cache may
  collect the source.
- Work-conserving round-robin admission across equal-priority autonomous
  missions, foreground priority for direct operator commands, and the
  repository concurrency ceiling.
- Durable provider-capacity waits that release the slot and retry.
- Drain-before-handoff on a normal upgrade.
- An opt-in, privacy-minimal desktop notification adapter.
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
- Automatic resume after a runner crash, logout, or machine restart. Recovery
  stays manual and operator-initiated.
- Merging pull requests, under any circumstances. The PR drainer remains the
  only component that merges.
- Cross-repository scheduling or a host-wide budget above the per-repository
  runners.
- Provider-native internal subagent presentation.

## Design

### Ownership layers

Because a process cannot clean up after its own crash, every executable parent
sits inside a longer-lived ownership boundary. The service manager's job
provides outer containment; that job launches a small mission supervisor; the
supervisor launches the scheduler; the scheduler owns session supervisors; and
session supervisors own agent processes and their descendants. Each layer
records its children's identities *before* admitting work, and a layer's exit
is observed by the layer above it, which performs the cascade.

A host whose service manager cannot supply a trustworthy outer containment and
refusal boundary is unsupported rather than allowed to leak agents.

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

Runner crash, logout, or machine restart marks nonterminal missions
`interrupted` and starts nothing. Recovery is operator-initiated and performs a
second identity-verified sweep of the old descendant tree before any
replacement process starts. This is deliberately asymmetric with ordinary TUI
exit, which stops nothing.

## Decisions

Each decision below was signed off in `docs/superagent_design.md` and is
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

### D-3. Runner or host failure requires manual, contextual recovery

From superagent `D-15`. Ordinary TUI exit leaves the live runner alone, but
runner crash, logout, or machine restart marks its nonterminal missions
`interrupted` and starts nothing automatically. The normal action hotkey
initiates recovery: settle the old descendant tree, reconcile outcome-unknown
effects, inspect and preserve any existing worktree, and give a fresh process
the failure and work-in-progress handoff.

### D-4. Two mutation-capable agent children may run per repository by default

From superagent `D-19`. The initial configurable admission ceiling is two
simultaneously running mutation-capable agent children across all missions for
one canonical repository. Dependencies and lower-level authorities may
serialize further; explicit configuration may lower or raise the ceiling.

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
managed job adds a namespace and a component, not a second mechanism.

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

## Verification strategy

- No-TUI fixtures are the arc's signature test: dispatch a mission, exit the
  dashboard, let the runner complete one child and dispatch the next, then
  reopen and prove the complete tree and logs replay without rerun.
- Two-process fixtures prove arbitration: a second runner cannot advance a
  mission the first holds, and a dashboard's presence never grants it an
  advancement lease.
- Structured-concurrency fixtures build multi-level registered process trees.
  Normal parent completion waits for children; parent kill, timeout, and crash
  terminate the whole subtree; an unverifiable survivor blocks settlement; no
  child is reparented or left running after verified parent death.
- Manual-recovery fixtures crash the runner with committed and uncommitted
  worktree state, prove no login or TUI restart launches work, activate
  recovery through the action boundary, and show the fresh agent receives the
  failure, log, branch, commits, status, diff, untracked paths, and live
  tracker state without resetting or duplicating the prior effect.
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
- Deadline fixtures exercise the configured deadline through an injected clock
  across a descendant tree, and prove a timeout leaks no descendant.
- Notification fixtures use a fake desktop adapter, prove one generic notice per
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
- **Relevant decisions:** `D-13`.
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

- **Outcome:** No verified parent death, timeout, or explicit termination
  leaves a live descendant, and a runner crash leaves its missions
  `interrupted` with an operator-initiated recovery path.
- **Scope:** Registered-child recording before launch; cascading termination
  deepest-first with identity verification; parent-not-terminal-while-children-
  survive; deadline enforcement across a descendant tree; interrupted marking
  and manual contextual recovery; session-log sealing into the mission archive.
- **Phase:** 4 — ownership and death.
- **Depends on:** `RUN-1`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-2`, `D-3`, `D-7`, `D-11`.
- **Acceptance signals:** A multi-level tree is reaped deepest-first with every
  recorded identity verified absent; an unverifiable survivor blocks settlement;
  a timeout leaks no descendant; a runner crash marks missions `interrupted`
  and starts nothing; recovery settles the old tree before any replacement
  starts; a sealed log verifies after its source is collected.
- **Out of scope:** Scheduling fairness, capacity waiting, and upgrade drain.
- **Open questions:** `None`.

### RUN-5. Schedule missions fairly and survive capacity limits and upgrades

- **Outcome:** Concurrent missions share the repository's capacity by durable
  round-robin, direct operator commands take the next slot without preempting,
  proven provider limits release the slot and retry, and a normal upgrade
  transfers the runner lease only after drain.
- **Scope:** The repository admission ceiling and its configuration;
  work-conserving round-robin with a durable cursor; foreground priority for
  direct commands; capacity classification, slot release, reset/backoff, and
  retry; drain state, queued commands during drain, and single lease handoff.
- **Phase:** 5 — scheduling policy.
- **Depends on:** `RUN-1`, `RUN-4`.
- **Ordering:** `critical path` for the epic; `not on the critical path` for
  Mission Control's console, which does not depend on it.
- **Relevant decisions:** `D-4`, `D-5`, `D-8`, `D-9`, `D-10`.
- **Acceptance signals:** The ceiling holds across concurrent missions and does
  not weaken lower serialized locks; a new direct command gets the next
  compatible slot without preempting; the round-robin cursor survives restart,
  skips blocked missions, and reuses idle capacity; a rate limit releases its
  slot and retries at reset while an authentication failure stops; a drain
  settles children, seals state, and hands the lease over exactly once; a forced
  handoff becomes interrupted rather than two schedulers.
- **Out of scope:** Cross-repository or host-wide budgets, and batch membership
  and ordering, which are Mission Control's `SAG-5`.
- **Open questions:** `None`; `D-14` settles per-repository installation.

### RUN-6. Document installing, operating, and recovering the mission runner

- **Outcome:** Operators have one accurate document for installing, starting,
  stopping, inspecting, troubleshooting, and recovering the mission runner, and
  the repository's steering documents agree with what shipped.
- **Scope:** The operating guide; `docs/design.md` and
  `docs/agent-workflow-contract.md` updates for the new managed component, its
  authority, and its durable state; dependency and packaging inventory entries;
  recovery and troubleshooting procedures.
- **Phase:** 6 — operability.
- **Depends on:** every implemented slice; documentation for a deferred slice
  stays in this design rather than claiming shipped behavior.
- **Ordering:** `critical path` for epic completion.
- **Relevant decisions:** `D-1` through `D-13`.
- **Acceptance signals:** Documented commands and paths match tested behavior;
  every executable and durable record this arc adds has an authority and
  ownership entry; an operator can distinguish stopped, idle, waiting,
  interrupted, and failed.
- **Out of scope:** Tracker drafting and implementation of deferred choices.
- **Open questions:** `None`.
