# Durable superagent console design

Kanban already launches and recovers individual solve and pull-request workers,
retains interactive transcripts while it is open, and has canonical review
backends. This design explores a project-scoped console that feels like one
long-lived agent while using durable missions, short-lived planner turns, and
the existing workflow authorities underneath. The operator can give it one
target, an explicit batch, or a broad instruction, leave, return later, and see
what ran, what stopped, and what needs a decision.

Design state: `exploring`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. Add a durable project superagent console
- [ ] SAG-1. Define the durable mission model and store
- [ ] SAG-2. Expose a typed workflow action registry
- [ ] SAG-3. Run and recover one mission outside the board selection
- [ ] SAG-4. Add the persistent console and mission navigation
- [ ] SAG-5. Schedule explicit and selector-based batches
- [ ] SAG-6. Add bounded natural-language planning
- [ ] SAG-7. Add opt-in recommendation application and rereview loops
- [ ] SAG-8. Document authority, operation, and recovery

## Epic contract

- **Goal:** Give an operator one project-scoped agent console that can accept
  durable workflow instructions, execute them through Kanban's existing
  authorities, survive dashboard restarts, and return visibly to the exact
  mission or child workflow that needs attention.
- **Done when:** A hotkey opens the same durable console after restart; commands
  such as single-target review/solve, explicit multi-target autosolve, and
  ordered issue approval create inspectable missions; every mission can
  reconstruct its state from durable records and live GitHub/process evidence;
  known workflow commands use canonical implementations rather than prompt
  imitation; default batches stop at their first changes-requested or
  indeterminate result; an explicit auto-remediation policy can apply bounded
  recommendations and rereview; card actions and attention notices reopen the
  relevant retained history; and no path merges a pull request.
- **Users and operators:** A maintainer using Kanban as the control surface for
  long-running, agent-assisted work on one repository.
- **Arc label:** `agent-workflows` proposed.

## Current state and evidence

### Verified current state

- `Kanban.Worker` already launches detached per-item supervisors for issue
  solve/autosolve and pull-request actions. A worker has private, durable
  `.spec.json`, `.state.json`, `.events.jsonl`, lease, acknowledgement, and
  termination records under the repository's XDG cache namespace. Startup
  discovery can reattach the TUI to a live worker and recover its session ID,
  log path, parent autosolve state, process identities, and terminal result.
- `Kanban.UI.Types.AgentSession` supplies a shared transcript/input/lifecycle
  model for solve, PR, and issue-review sessions. The visible transcript is
  bounded to 50,000 characters, while provider JSONL logs are written outside
  the repository. The session maps themselves are application state and the
  latest completed sessions are retained only until replacement or TUI exit.
- `p` already opens a process/session inspector, and Enter opens the existing
  interactive overlay for a retained row. This is a useful low-level
  diagnostic surface, not yet a project-level mission history.
- Current autosolve is one selected **issue** at a time. It runs solve, discovers
  the newly linked PR, invokes the opposite-brand PR reviewer, returns
  `reviewed:changes` to the original solver through `pr-revise`, and stops at
  approval or after five review rounds. It never merges.
- Issue initial review and rereview are owned by the installed canonical
  `approve_issues.py` backend. Issue specification revision is a separate
  interactive coordinator session. PR review/revise/rereview likewise has
  canonical workflow ownership. A new console must dispatch these authorities,
  not ask a general agent to reproduce their effects.
- `approve_issues.py --review <issue>...` already processes an explicit ordered
  list under one approval lock and stops at the first `CHANGES_REQUESTED` or
  indeterminate outcome. Its `--review-queue` mode and the persistent approval
  controller consider the live open backlog in ascending issue number, advance
  at most one issue per backend pass, and hold a current changes-requested issue
  as a barrier.
- The persistent issue-approval arc is partly landed: issues #320, #349, #351,
  and #352 are closed and their backend, controller, installer, and Haskell
  lifecycle surfaces are on the current branch. Its sidebar control (#421) and
  operating documentation (#425) remain open as of 2026-08-21. The superagent
  console should consume that authority rather than create a competing
  approve-all implementation.
- A tracker search on 2026-08-21 found no existing issue or epic whose scope is
  a durable general agent console or mission orchestrator. Epic #318 overlaps
  only the ordered issue-approval command and is a dependency/integration
  point, not a duplicate of this arc.
- `docs/superagent_design.md` is not currently named by the publication table in
  `docs/agent-workflow-contract.md` section 7. Until a later contract change
  classifies it, the repository's fail-closed rule treats it as pr-atomic even
  though it is being authored in `docs-wip` like the other design records.

## Desired experience

### Return to one durable console

1. The operator presses a dedicated hotkey from anywhere on the board.
2. Kanban opens the project console with its prior conversation, active
   mission, queued missions, latest completed work, and attention items.
3. The operator can type a recognized command directly or describe a broader
   objective conversationally. Recognized commands normalize immediately;
   prose is turned into a visible plan made only from registered actions.
4. Closing the overlay, refreshing the board, or restarting Kanban does not
   erase the mission. Reopening the console reconstructs it from its durable
   record and current process/GitHub state.

### Single-target commands and navigation

- `approve 123` resolves whether #123 is an issue or pull request, then runs
  the appropriate canonical gate. “Approve” means “seek a canonical approval,”
  never “force the approval label or ignore the reviewer.”
- `review 123`, `solve 123`, and related verbs use the same state-dependent
  action selection as the board. Invalid target/action pairs are refused before
  an agent starts.
- If the operator later presses the board action on that issue or PR, Kanban
  opens the running child workflow and its transcript instead of creating a
  duplicate session. Returning from the child returns to the parent mission.
- When a mission needs input, the ordinary attention surface names the mission
  and target. Activating it opens the exact question and relevant history.

### Batch commands

- `autosolve 12 18 27` creates one parent mission with three child issue
  autosolve workflows. It does not paste three targets into one unconstrained
  agent prompt.
- Explicit lists preserve the user's order in the journal even when independent
  children are allowed to run concurrently. A configured concurrency ceiling
  keeps provider limits and host load bounded.
- `approve all issues` drives an ordered issue batch. By default it stops at
  the first changes-requested verdict, failure, ambiguous result, or user
  decision and hands that exact child back to the operator.
- An explicitly more autonomous form, illustrated as
  `approve all issues --apply-recommendations`, may revise the affected issue
  from the canonical recommendation, rereview it, and continue only after a
  current approval. It remains bounded and stops when the recommendation
  requires a product decision, conflicts with policy, repeats without
  progress, or exceeds its retry limit.
- “All PRs” and an explicit list of PR numbers use PR review/revision actions;
  “autosolve” remains an issue-to-PR lifecycle unless a distinct PR-only
  review/fix-loop verb is deliberately added. This avoids silently changing
  the meaning of Kanban's existing autosolve action.

### Honest recovery

- A restart shows whether a child is live, completed, waiting, dead before an
  observed outcome, or safe to resume. It never turns “the process disappeared”
  into “the action failed” or automatically repeats an outcome-unknown GitHub
  mutation.
- The operator can pause future dispatch, cancel a queued child, terminate a
  live owned process tree through existing worker semantics, or resume a
  waiting mission with guidance. Every control action is journaled.

## Scope

### In scope

- One project-scoped console overlay, durable command/mission history, mission
  list, current state, input, attention navigation, and child-session links.
- Versioned mission specifications, snapshots, append-only event journals,
  summaries, action results, provider session/log references, and recovery.
- A closed registry of typed workflow actions backed by Kanban's canonical
  issue review/revision, solve/autosolve, PR review/revise/rereview, and
  approval-service capabilities.
- Direct command parsing for stable verbs plus bounded natural-language
  planning that can propose only registered actions.
- Single targets, explicit ordered lists, target selectors such as `all
  issues`, bounded concurrency, stop/barrier policies, cancellation, and
  attention handoff.
- Optional automatic application of canonical issue or PR review
  recommendations followed by canonical rereview, with explicit authority,
  progress detection, and loop bounds.
- Restart recovery from durable local state plus authoritative process and
  GitHub observations.
- Repository identity, locking, private file modes, schema migration, tests,
  documentation, and preflight integration.

### Out of scope

- A permanently alive model process or an unbounded provider conversation as
  the source of truth.
- Reimplementing review, solve, autosolve, issue approval, PR revision, or
  service logic inside a general-purpose prompt.
- Letting model prose directly invoke shell commands or GitHub mutations
  without a validated registered action.
- Forced approval, skipping a changes-requested barrier without repairing it,
  inventing a success after an unknown outcome, or merging a pull request.
- Arbitrary source-code work unrelated to a tracked/registered Kanban workflow
  in the first arc.
- Cross-repository missions before the multi-repository board contract is
  implemented. Durable mission identity is nevertheless repository-qualified
  so that later support does not require a migration.
- Treating the existing `p` process inspector as durable mission history or
  removing it; it remains the low-level process/debug view.

## Design

### Product model: console, missions, steps, and child sessions

The user-facing object is one **console** per canonical repository. The console
is a durable chronology and an input surface, not one provider thread. Each
imperative creates a **mission**. A mission owns the original request, its
normalized policy, a plan, ordered steps, summaries, and a lifecycle. Each
step invokes one registered **action** and may link to an existing solve,
review, PR, approval-service, or future planner **child session**.

This split lets the experience remain continuous while context stays bounded:

- the console history answers “what have I asked this project agent to do?”;
- the mission record answers “what is the plan and where did it stop?”;
- the child transcript answers “what did this particular reviewer or solver
  say?”; and
- GitHub, worker leases, canonical comments/labels, and service status answer
  “what actually happened?”

The console should present child output inline as concise, linked summaries.
Opening a link shows the existing full transcript. It should not copy every
provider event into one ever-growing prompt or one enormous render buffer.

### The controller, not the model, owns progression

A deterministic mission controller owns the state machine. Planner agents may
translate prose into a typed plan, summarize evidence, or recommend the next
registered action. They do not decide that an action succeeded, manufacture a
label, bypass a lock, or mutate a mission record directly.

The controller accepts only a versioned action request containing at least an
action kind, canonical repository identity, typed target, policy, preconditions,
and stable mission/step identifiers. It resolves live state again at dispatch,
uses the owning workflow adapter, records the invocation before launch, and
records/reconciles the outcome afterwards. A planner-proposed action outside
the registry is rejected and returned to the console as a planning error.

Known commands do not need a planner turn. Their parser builds the same typed
plan directly, making `solve 123` fast and deterministic even when no planning
model is available. Natural-language requests use a planner constrained to the
registry and display the normalized plan before any ambiguity expands scope.

### Workflow action registry

The registry should expose capabilities rather than UI keystrokes. Initial
action kinds are expected to include:

| Action | Target | Owning authority | Normal terminal observations |
| --- | --- | --- | --- |
| Review issue | open issue | canonical `approve_issues.py` | approved, changes requested |
| Revise issue | changes-requested issue | existing issue revision coordinator | revised, needs decision, failed |
| Solve issue | approved open issue | persistent solve worker | PR opened, needs input, failed |
| Autosolve issue | approved open issue | existing solve/PR loop | PR approved, needs input, stopped |
| Review or rereview PR | open PR | canonical PR workflow | approved, changes requested |
| Revise PR | changes-requested PR | canonical `pr-revise` workflow | rereviewed, needs input, failed |
| Observe approval queue | repository | issue-approval controller | idle, reviewing, barrier, failed |

The implementation should extract or wrap the current UI launch boundaries so
both a board key and a mission step call one action API. The registry must not
simulate key presses or infer completion from rendered text.

Target resolution is type-aware. GitHub issue and PR numbers share one number
space, so an unqualified `123` can be resolved authoritatively. A target that
does not exist, belongs to another repository, is historical/read-only, or is
incompatible with the verb is rejected before dispatch. Explicit `issue 123`
and `pr 123` forms remain useful both for clarity and for stale-cache recovery.

### Durable mission record

Each mission should live under a private, repository-qualified XDG state or
cache root and contain conceptually:

- a versioned immutable specification: mission ID, repository identity,
  original request, normalized selector/target snapshot, policy, creation
  time, and initial plan;
- a replaceable atomic snapshot: lifecycle, current/next steps, pause state,
  attention item, planner summary, retry counters, and last reconciliation;
- an append-only JSONL event journal: commands, accepted plans, dispatch
  attempts, worker/service references, outcomes, questions, answers, policy
  changes, cancellation, and recovery decisions; and
- links to provider session IDs and log paths rather than duplicated raw
  transcripts.

Files use user-only permissions and schema-tolerant readers, following the
worker layer's existing private JSON/journal discipline. Appends must be whole
records; snapshots must be atomic. A mission-level lease prevents two Kanban
instances or a background runner from advancing the same mission
simultaneously. Per-target worker leases and the canonical approval lock remain
the lower-level authorities and are never replaced by the mission lease.

Provider session resumption is an optimization. When a usable session ID is
available, a follow-up may resume it. Otherwise a fresh agent receives a
bounded mission brief containing the original request, settled decisions,
relevant recent events, child result references, and the immediate task. The
mission remains resumable when a provider expires a session or Kanban changes
the configured model.

### Mission lifecycle and reconciliation

At minimum a mission distinguishes `planned`, `running`, `waiting_input`,
`waiting_barrier`, `paused`, `completed`, `failed`, and `cancelled`. A step
distinguishes `pending`, `dispatching`, `running`, `outcome_unknown`,
`succeeded`, `needs_changes`, `needs_input`, `failed`, and `cancelled`.

On startup or runner recovery, the controller:

1. validates repository identity and the mission schemas;
2. claims the mission lease;
3. discovers any referenced Kanban worker and verifies its recorded process
   identities;
4. rereads the relevant GitHub issue/PR, canonical marker/labels, or service
   status;
5. reconciles the durable step with those authoritative observations; and
6. advances only if the next effect is still permitted and idempotent.

A recorded dispatch without an observed result becomes `outcome_unknown`.
Recovery first asks the owning authority whether the effect landed. It never
blindly reruns a review publication, issue edit, PR revision, or other mutation.
If current evidence cannot decide, the mission stops for the operator.

### Batch selection, ordering, and concurrency

An explicit target list becomes durable at command acceptance. Each target is
a child step with its own state and transcript link. The controller preserves
input order for presentation and stop policy even when it runs independent
children concurrently.

Selectors need an explicit finiteness contract. The recommended default is
that `all` snapshots the complete eligible target set when the command is
accepted, records those numbers, and terminates when that set is processed.
An explicit `watch` form should control the existing live approval service and
may include newly opened issues. This prevents an apparently finite chat
command from silently becoming a daemon.

The first concurrency policy should be conservative and configurable. Issue
approval remains serialized by its canonical lock and ordered barrier. Several
solve/autosolve children may run in isolated worktrees up to a small ceiling,
but a planner may not assume they are logically independent merely because the
filesystem permits parallel work. Known dependencies, the same target, or an
existing live worker serialize. Provider-capacity or rate-limit observations
pause dispatch without failing already-running children.

Default batch policy is fail-closed:

- changes requested stops the ordered batch at that target;
- needs input opens an attention item and stops later ordered work;
- an outcome-unknown, invalid, or failed child stops later work;
- approval or another explicitly successful terminal state advances; and
- cancellation never counts as success.

For a deliberately parallel group, a stop prevents new dispatch but does not
kill already-running siblings. Their eventual outcomes remain in the mission
history. This avoids turning a barrier into destructive cancellation.

### Applying review recommendations

Automatic remediation is a policy on a mission, not a phrase handed to a
single omnipotent agent. The policy must name which mutations it authorizes.

For an issue, the loop is:

1. run the canonical review and retain the exact versioned review record;
2. if changes are requested, invoke the issue revision authority with the
   current issue fingerprint and that review as its bounded input;
3. require a structured revision outcome such as `revised`, `no_progress`,
   `needs_decision`, or `failed`;
4. reread the issue and verify the authorized change and new fingerprint;
5. run canonical rereview; and
6. continue only on current approval, or repeat within a fixed round limit
   when the next recommendation is actionable and materially different.

The automatic issue policy should initially authorize edits to the issue
specification that directly implement the review feedback. It should not
silently change priority, dependencies, origin, broad feature scope, close the
issue, start solving it, or treat a product choice as copyediting. A reviewer
request that cannot be satisfied without such a decision returns
`needs_decision` and opens the console at that issue.

For a PR, the corresponding loop should reuse the existing canonical
review/`pr-revise`/rereview path and its round limit. It never pushes directly
through a general planner and never merges after approval.

Progress detection compares canonical verdict identity, target fingerprints,
and normalized recommendations across rounds. Repeated equivalent feedback,
no target change, conflicting feedback, a new unrelated recommendation after
the limit, or any indeterminate mutation stops the mission. “Plow through” is
therefore an explicit permission to apply bounded actionable recommendations,
not permission to invent answers or erase barriers.

### Console and child-session UI

The overlay should have three stable regions at supported terminal sizes:

- mission navigation and compact statuses;
- the selected mission's durable conversation/event summary with links to
  child transcripts; and
- one input line that clearly says whether it is sending guidance, accepting a
  plan, or starting a new command.

The exact hotkey is deliberately unsettled until the key table and the pending
approval-service control have landed. The help overlay and authoritative key
contract must be updated with whichever key is chosen.

The console is the high-level surface. Existing solve/review/PR overlays remain
the detailed child surfaces, and `p` remains the cross-process inspector. A
child header should show its parent mission, and a return action should restore
the console selection. Card badges may identify a mission-owned session, but
the mission controller must use IDs rather than badge presence as authority.

### Runner lifetime

The durable model supports two implementable lifetimes, which require a user
decision:

- **Dashboard-supervised:** detached child workers survive Kanban exit, but no
  new step is dispatched until a dashboard reopens and reconciles the mission.
  This reuses the current worker topology and is the smaller first release.
- **Service-supervised:** a per-repository mission runner advances plans while
  Kanban is closed, using the existing service-manager boundary and durable
  status conventions. The model still is not permanently alive; the service
  starts bounded planner/worker turns as needed.

Neither form should start new autonomous work merely because the user logged
in or the machine rebooted. A recovered service may observe already-authorized
work, but surprise post-reboot mutation needs a separately explicit policy.

### Failure, security, and upgrade boundaries

- Repository content, issue bodies, comments, review text, and provider output
  are untrusted input to the orchestrator. Only a validated typed action can
  cross from model output to a workflow authority.
- Durable records identify the canonical repository and selected config. A
  checkout or remote mismatch stops before mutation.
- Mission records and transcript/log references may contain private repository
  content and use user-only permissions.
- Unknown schema versions fail visibly. Older additive schemas decode with
  defaults where that is safe; a migration never rewrites the only copy before
  validation and backup/recovery evidence.
- Planner/model unavailability does not disable deterministic commands or
  observation of existing missions.
- Preflight runs at the action's real spawn boundary. A successful plan-time
  probe is not permission to ignore a later missing executable, auth change,
  service conflict, or provider setting change.
- Kanban shutdown, runner termination, and mission cancellation use existing
  verified process-tree semantics and never kill an unverified PID.

## Decisions

### D-1. Present one durable project console behind a hotkey

The requested user experience is one reopening console with durable history,
not a collection of unrelated transient action popups. Individual workflow
transcripts remain reachable as child sessions.

### D-2. Persist missions, not a permanently alive agent

The continuous identity comes from a durable mission journal, summaries,
instructions, and provider/session references. Planner and executor processes
may be fresh on every step. Model conversation state is never the sole source
of truth.

### D-3. Dispatch existing canonical workflow authorities

The console orchestrates review, revision, solve, autosolve, PR workflows, and
the approval service through typed adapters. It does not reproduce their
prompts or mutations in a general superagent thread.

### D-4. A board action reopens mission-owned work

When an issue or PR already has a matching live or retained child owned by a
mission, its board action opens that session and history rather than launching
a duplicate.

### D-5. Support single targets, explicit batches, and broad selectors

The interface must support commands equivalent to one target, a user-ordered
list, and “all issues.” Multi-target work is represented as parent and child
steps, not one opaque provider invocation.

### D-6. Stop-on-changes is the default; automatic remediation is explicit

An ordinary approval batch stops and hands the changes-requested target back to
the operator. A distinct policy may apply recommendations and rereview within
bounds; the two modes are visibly different in the command and mission header.

### D-7. Approval is an outcome sought through a gate, never forced

The `approve` verb invokes the appropriate canonical review. It cannot add an
approval label directly, suppress a changes-requested result, or call an
indeterminate result successful.

### D-8. The superagent never merges

Approval, solve, autosolve, and remediation all stop before merge. The existing
PR drainer remains the only component that merges eligible pull requests.

## Open questions

### Q-1. Must missions keep advancing after Kanban exits?

Dashboard-supervised progression is substantially smaller and already fits the
detached worker substrate; service-supervised progression is the fuller
long-term-operator experience but adds another installed controller and
cross-process ownership. Decide whether the first release only preserves and
reattaches work, or also dispatches new steps while no TUI is open.

### Q-2. Is `all` a finite snapshot or a live selector?

The proposal is finite-by-default: record the complete current target list,
finish it, and reserve a visibly different `watch` form for the live
issue-approval service. A live-by-default interpretation would include issues
created after the command and might never complete.

### Q-3. How much issue-specification authority does auto-remediation receive?

The narrow proposal authorizes edits that directly satisfy actionable review
feedback but stops for product, scope, priority, dependency, or ambiguous
choices. A more aggressive mode could explicitly authorize those decisions,
but would need a clear policy for what the agent may infer instead of asking.
This choice determines whether SAG-7 fits this epic or deserves its own design.

### Q-4. How conversational is the first release?

The proposed hybrid parses known commands deterministically and uses a planner
only for prose or multi-step goals. A command-only first release would reduce
risk but would be a durable workflow console rather than the intended
superagent experience.

### Q-5. What is the first concurrency ceiling?

The scheduler needs a conservative default for independent solve/autosolve
children and a way to pause on provider limits. Issue approval remains
serialized regardless. This can be configuration rather than a product-level
blocker once the intended host budget is known.

### Q-6. Which key and product name should the console use?

Choose after the pending approval-service UI lands and the complete key table
can be audited. “Superagent” is evocative; “Operator,” “Mission Control,” or
“Steward” may communicate bounded orchestration more accurately in the UI.

## Verification strategy

- Pure tests cover command parsing, target typing, plan validation, lifecycle
  transitions, batch order, barriers, concurrency admission, loop bounds,
  progress detection, and recovery decisions.
- Temporary repositories and fake `gh`, `codex`, and `claude` executables cover
  each registered action without accounts or network access. Existing workflow
  suites remain the authority for child behavior; mission tests assert adapter
  invocation and observed results rather than duplicating their internals.
- Durable-state tests cover whole JSONL appends, partial trailing records,
  atomic snapshots, user-only permissions, schema evolution, competing mission
  leases, corrupt records, and repository identity mismatch.
- Crash fixtures cover before-dispatch, after-dispatch/before-record,
  live-worker reattachment, dead worker with a landed GitHub result, dead worker
  with unknown outcome, runner restart, and TUI restart.
- UI event and golden tests cover hotkey entry, mission navigation, command
  input, attention handoff, child opening/return, small-terminal behavior,
  scroll/follow state, cancellation, and status colors.
- Security tests ensure untrusted tracker/provider text cannot create an
  unregistered action, alter repository identity, weaken policy, or cross an
  approval/merge boundary.
- End-to-end fixtures cover one issue approval, one solve, an explicit
  multi-autosolve batch, stop-on-changes, opt-in issue remediation/rereview,
  repeated-feedback halt, and no merge invocation.
- The authoritative design, key table, agent-workflow contract, development
  guide, dependency manifest, and packaging inventory are updated in the
  implementation slice that couples to each surface.

## Delivery plan

### SAG-1. Define the durable mission model and store

- **Outcome:** Kanban can create, read, append to, reconcile, and enumerate a
  private repository-qualified mission without launching an agent.
- **Scope:** Mission/step/action identifiers and lifecycles; versioned spec,
  snapshot, and JSONL event schemas; private/atomic persistence; leases;
  corruption and schema diagnostics; pure and filesystem tests.
- **Phase:** 1 — durable foundation.
- **Depends on:** `none`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-1`, `D-2`, `D-5`.
- **Acceptance signals:** A mission round-trips across process restart; partial
  journal writes are not consumed; two controllers cannot advance it; private
  modes and repository identity are verified.
- **Out of scope:** Workflow launch, providers, UI, batch progression, and
  natural-language planning.
- **Open questions:** `Q-1` affects the eventual owner but not the schema.

### SAG-2. Expose a typed workflow action registry

- **Outcome:** Board actions and future mission steps can resolve and invoke the
  same typed canonical capabilities without simulating keystrokes.
- **Scope:** Action/target/policy types; live target resolution; capability and
  preflight queries; adapters around issue review/revision, solve/autosolve, PR
  review/revise, and approval-service observation; validated result vocabulary;
  fake-executable tests.
- **Phase:** 2 — authority boundary.
- **Depends on:** `SAG-1`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-3`, `D-7`, `D-8`.
- **Acceptance signals:** Each action reaches its existing authority with exact
  repository/config/target data; incompatible and historical targets refuse;
  no registry path forces approval or merges.
- **Out of scope:** Mission scheduling, console UI, broad selectors, and
  planner-generated actions.
- **Open questions:** `None`.

### SAG-3. Run and recover one mission outside the board selection

- **Outcome:** A controller can dispatch, observe, stop, resume, and recover one
  mission step using durable evidence and existing worker/service state.
- **Scope:** Mission runner; dispatch-before-effect journal boundary; worker and
  GitHub reconciliation; attention, pause, cancellation, outcome-unknown, and
  provider-session fallback; startup discovery; crash fixtures.
- **Phase:** 3 — execution and recovery.
- **Depends on:** `SAG-1`, `SAG-2`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-2`, `D-3`, `D-7`, `D-8`.
- **Acceptance signals:** A live worker reattaches; a landed result reconciles;
  an indeterminate mutation stops instead of rerunning; guidance can resume
  with the prior provider session or a fresh bounded brief.
- **Out of scope:** Background progression while the TUI is closed unless Q-1
  selects it, multi-target scheduling, and UI.
- **Open questions:** `Q-1`.

### SAG-4. Add the persistent console and mission navigation

- **Outcome:** A hotkey opens the durable project console and users can inspect,
  select, guide, pause, cancel, and navigate between missions and child
  sessions.
- **Scope:** Overlay layout, history summaries, input state, mission list,
  attention routing, child links/return, board-action reuse, help/key contract,
  responsive rendering, and golden/event tests.
- **Phase:** 4 — operator surface.
- **Depends on:** `SAG-3`; land after the pending approval-service control
  (#421) or re-audit the whole key/layout surface against it.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-1`, `D-4`.
- **Acceptance signals:** TUI restart restores the same missions and selected
  history; a card opens its mission-owned child; attention opens the exact
  question; no duplicate worker launches.
- **Out of scope:** Broad selectors, natural-language planning, and automatic
  remediation.
- **Open questions:** `Q-6`.

### SAG-5. Schedule explicit and selector-based batches

- **Outcome:** One mission can own an ordered explicit list or complete target
  selector and advance its children under bounded concurrency and stop policy.
- **Scope:** Deterministic command grammar; target-set inventory validation and
  persistence; explicit order; concurrency admission; stop/barrier behavior;
  approval batch/service integration; multi-autosolve dispatch; batch UI
  summaries and tests.
- **Phase:** 5 — batch orchestration.
- **Depends on:** `SAG-3`, `SAG-4`; consume rather than duplicate epic #318's
  canonical queue/service authority.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-3`, `D-5`, `D-6`, `D-7`, `D-8`.
- **Acceptance signals:** Explicit targets are never lost or reordered;
  stop-on-changes dispatches nothing past its barrier; parallel failure stops
  new work without killing live siblings; `all` follows the selected finite or
  live contract.
- **Out of scope:** Planner-generated plans and automatic recommendation
  application.
- **Open questions:** `Q-2`, `Q-5`.

### SAG-6. Add bounded natural-language planning

- **Outcome:** Conversational input can become a visible, validated mission
  plan composed only of registered actions, while recognized commands continue
  without a planner.
- **Scope:** Planner prompt/schema, bounded mission brief and summaries,
  plan validation, clarification/acceptance flow, policy display, model failure
  fallback, untrusted-input boundaries, and fixtures.
- **Phase:** 6 — superagent reasoning.
- **Depends on:** `SAG-2`, `SAG-4`, `SAG-5`.
- **Ordering:** `not on the critical path` for deterministic commands, required
  for the full epic experience.
- **Relevant decisions:** `D-1`, `D-2`, `D-3`, `D-5`.
- **Acceptance signals:** Prose creates only registered typed steps; ambiguous
  scope is shown or questioned before dispatch; injected tracker text cannot
  alter policy; planner outage leaves direct commands and history usable.
- **Out of scope:** Arbitrary shell access or unregistered project work.
- **Open questions:** `Q-4`.

### SAG-7. Add opt-in recommendation application and rereview loops

- **Outcome:** An explicitly authorized mission can apply actionable canonical
  review feedback to an issue or PR, verify progress, rereview, and either
  continue after approval or stop with a precise handoff.
- **Scope:** Remediation policy; structured issue revision outcomes; review
  record/fingerprint binding; PR `pr-revise` reuse; rereview; progress and
  repeated-feedback detection; round limits; decision-required boundaries;
  crash and end-to-end tests.
- **Phase:** 7 — bounded autonomy.
- **Depends on:** `SAG-3`, `SAG-5`; issue auto-remediation may become a
  follow-on epic depending on Q-3.
- **Ordering:** `not on the critical path` for the safe stop-on-changes console.
- **Relevant decisions:** `D-3`, `D-6`, `D-7`, `D-8`.
- **Acceptance signals:** Actionable feedback can reach current approval;
  ambiguous/product feedback stops; no-progress and repeated feedback halt;
  an unknown edit is never repeated; no issue is solved and no PR is merged as
  an implicit consequence of approval.
- **Out of scope:** Inferring unrestricted product decisions or bypassing the
  canonical rereview.
- **Open questions:** `Q-3`.

### SAG-8. Document authority, operation, and recovery

- **Outcome:** Operators and future implementations have one accurate contract
  for console commands, mission storage, runner lifetime, authority, recovery,
  safety, and troubleshooting.
- **Scope:** Authoritative design and workflow-contract updates; development,
  setup, storage/privacy, recovery, key/help, dependency, and package
  documentation; publication classification for this design record.
- **Phase:** 8 — operability and contract closure.
- **Depends on:** every implemented slice; documentation for a deferred slice
  remains in this design rather than claiming shipped behavior.
- **Ordering:** `critical path` for epic completion.
- **Relevant decisions:** `D-1` through `D-8`.
- **Acceptance signals:** Documented commands and paths match tested behavior;
  every executable and durable record has an authority/ownership entry; users
  can distinguish pause, barrier, failure, unknown outcome, and recovery.
- **Out of scope:** Tracker drafting and implementation of deferred choices.
- **Open questions:** All questions affecting implemented behavior must be
  resolved or explicitly deferred before this slice completes.
