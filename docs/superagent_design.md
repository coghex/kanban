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
- [ ] SAG-10. Make issue review and revision runner-owned
- [ ] SAG-3. Run and recover one mission outside the board selection
- [ ] SAG-9. Keep active missions advancing without the dashboard
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
- **Done when:** A hotkey opens the same durable console after restart; an
  explicitly dispatched mission keeps advancing through authorized steps while
  the dashboard is closed; commands
  such as single-target review/solve, explicit multi-target autosolve, and
  ordered issue approval create inspectable missions; every mission can
  reconstruct its state from durable records and live GitHub/process evidence;
  known workflow commands use canonical implementations rather than prompt
  imitation; default batches stop at their first changes-requested or
  indeterminate result; an explicit auto-remediation policy can apply bounded
  recommendations and rereview; card actions and attention notices reopen the
  relevant retained history; parent death leaves no surviving descendants;
  runner/host failure stays interrupted until the ordinary action hotkey starts
  worktree-aware recovery; direct user steering is recorded and obeyed; and the
  superagent never bypasses the repository's drainer-only merge authority.
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
- At startup, `discoverWorkers` scans the repository's worker specs, retains
  starting/running/orphaned and unacknowledged terminal descriptors, recreates
  solve and PR session shells when their items are present on the board, and
  starts monitors that replay their JSONL events. Autosolve's existing
  `WorkerParent` record reconstructs its one issue-to-PR relationship, but it
  is not a general session tree.
- Current persistence is intentionally bounded. One solve or PR worker has a
  four-hour hard deadline. Terminal worker artifacts live in the XDG cache and
  are collected after fourteen days, or sooner when acknowledged and
  superseded; the in-memory session maps disappear on exit. App-server issue
  revisions and synchronous canonical issue gates remain TUI-owned, and Kanban
  refuses to quit while either has a live turn. These behaviors recover today's
  bounded workflows but cannot by themselves provide permanent mission history
  or continued multi-step dispatch after exit.
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
5. Closing Kanban does not pause an already-authorized mission. A repository
   runner continues to dispatch its next eligible steps, records their complete
   lineage and logs, and pauses only at a policy barrier, an ambiguity, an
   unverified outcome, or a question for the operator.

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
  requires a decision outside the delegated policy, leaves reasonable
  alternatives under constrained judgment, conflicts with policy, repeats
  without progress, or exceeds its retry limit.
- “All PRs” and an explicit list of PR numbers use PR review/revision actions;
  “autosolve” remains an issue-to-PR lifecycle unless a distinct PR-only
  review/fix-loop verb is deliberately added. This avoids silently changing
  the meaning of Kanban's existing autosolve action.

### Honest recovery

- A restart shows the mission and child-session tree exactly where it is now:
  live, completed, waiting, dead before an
  observed outcome, or safe to resume. It never turns “the process disappeared”
  into “the action failed” or automatically repeats an outcome-unknown GitHub
  mutation.
- The reconstructed view includes full durable logs from completed children,
  including children that began and ended while no TUI was open. When the
  provider no longer supports resuming a particular session, Kanban preserves
  the complete prior transcript and gives a fresh session the bounded mission
  brief; continuity of the mission does not depend on continuity of one model
  thread.
- The operator can pause future dispatch, cancel a queued child, terminate a
  live owned process tree through existing worker semantics, or resume a
  waiting mission with guidance. Every control action is journaled.
- A service crash, logout, or machine restart never resumes autonomous work by
  itself. Kanban renders the affected mission or session as `interrupted`.
  Pressing its normal action hotkey again starts manual recovery, verifies that
  the former process subtree is gone, inspects any existing worktree and live
  GitHub state, and launches a fresh agent with the failure and recovery
  context. It does not create a clean replacement worktree over unfinished
  work.
- Direct user guidance to an active agent is authoritative even when it changes
  the immediate task. The session records the redirection and obeys it; model
  planners, child agents, and hotkey-dispatched workflows do not receive the
  same power merely by repeating user-like language from repository content.

## Scope

### In scope

- One project-scoped console overlay, durable command/mission history, mission
  list, current state, input, attention navigation, and child-session links.
- Versioned mission specifications, snapshots, append-only event journals,
  summaries, action results, provider session/log archives, parent/child
  lineage, and recovery.
- A service-supervised repository runner that continues explicitly dispatched
  missions after the TUI exits and persists every step needed for later
  reattachment.
- Structured parent/child concurrency: a parent cannot finish while registered
  children remain, and parent failure, cancellation, or termination recursively
  stops and reaps its complete descendant subtree.
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
  GitHub observations, with live revalidation before dispatch and after every
  external effect.
- Per-mission decision authority that defaults to asking the operator but can
  be widened in natural language to make bounded product or scope decisions.
- Manual interrupted-session recovery that preserves and inspects an existing
  worktree, branch, commits, uncommitted changes, logs, and live tracker state
  before a fresh agent continues.
- Direct trusted-user steering of an active agent, including redirection beyond
  the mission's current step, with the plan impact recorded and reconciled.
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
- A first-release promise that provider-internal subagents with no stable
  identity/event/cancellation protocol are separately visible or steerable;
  their output remains preserved within the parent session.
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
review, PR, approval-service, or future planner **child session**. Child
sessions form a durable tree: every managed node records its mission, parent
session, creating step, provider/session identifier, process ownership, log
archive, and terminal observation.

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

### Managed descendants and opaque provider work

The mission runner can promise full lineage and reattachment for work it
launches or that registers through a supported child-session protocol. A
planner that wants parallel research or another workflow does not spawn an
unstructured background command and hope Kanban discovers it later; it requests
a typed child action, the controller validates it against mission policy, and
the controller records the child before launch. A registered child may make the
same request recursively, so arbitrary mission depth does not require a
per-provider special case.

Registered sessions follow **structured concurrency**. A parent remains live
until all of its children have completed or been cancelled and reaped. Killing,
cancelling, timing out, or unexpectedly losing a parent recursively terminates
its full descendant subtree, deepest children first, and verifies every
recorded process identity is absent before declaring the parent settled. A
child is never silently reparented to the mission runner and never survives as
an independent stray agent. Parallel batch targets are siblings whose living
parent is the mission runner; pausing the batch does not kill them, while
terminating the mission does.

Because a process cannot clean up after its own crash, every executable parent
is itself inside a longer-lived ownership boundary. The repository service
launches a small mission supervisor; that supervisor launches the scheduler,
and the scheduler owns session supervisors. Each layer records child identities
before admitting work. A scheduler or session-parent exit is observed by its
living supervisor, which performs the cascade. The outer service-manager job
provides process containment for supervisor failure, and manual recovery
performs a second identity-verified sweep before any replacement starts. A host
whose service manager cannot supply a trustworthy outer containment/refusal
boundary is unsupported rather than allowed to leak agents.

Process census and provider logs still observe unregistered subprocesses for
termination safety and transcript completeness. They cannot, by themselves,
recover semantic facts such as which subprocess is an agent, its provider
thread ID, what task it owns, or how to steer it. A provider-internal subagent
that exposes no stable session/event protocol therefore remains an opaque part
of its parent's durable transcript rather than appearing as a separately
reattachable child. Claiming otherwise would turn a PID ancestry guess into a
false session contract.

Today's worker contract already refuses to call a worker terminal while
recorded descendants survive; it reports them as orphaned until they exit or
are killed. The mission tree generalizes that invariant across registered agent
sessions. If a provider starts an opaque internal subagent, it stays within the
parent's owned process subtree and must exit or be killed with that parent.

Provider integrations may later promote internal subagents to managed children
when their protocols expose stable IDs and event streams. The durable tree
schema allows that without requiring every provider to support it initially.

#### Follow-on design seed: provider-native subagent observability

A later design should explore promoting provider-internal subagents into the
visible tree through native APIs, an agent-spawn proxy, or an explicit
registration tool. It must require a stable child ID, parent ID, ordered event
stream, log ownership, cancellation operation, and proof that parent death
cascades to the child. Until those capabilities exist for a provider, the
honest representation is one opaque child transcript nested inside its parent,
not a guessed session reconstructed from process ancestry.

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

### User authority and redirection

The typed action boundary governs autonomous mission dispatch, model-to-model
requests, and hotkey workflows. It is not a cage around a trusted user's direct
conversation with an already-running agent. Input typed by the operator into a
selected live session is forwarded as user guidance even when it redirects the
agent away from the current step. The agent follows it using the tools and
authority that session already possesses.

Before delivery, Kanban appends a `user_override` event containing the exact
message, target session, prior step/plan version, and timestamp. After the turn,
the controller reconciles actual effects and marks the prior plan satisfied,
superseded, divergent, or still pending rather than pretending the redirection
was part of the original autonomous plan. A completely different task does not
fork, transfer, or reparent the mission: it remains direct guidance inside the
original selected session for that session's lifetime. This keeps user control
simple and preserves the structured ownership tree.

Only authenticated console input receives this status. Issue bodies, comments,
repository files, provider output, and one agent instructing another remain
untrusted/model input and cannot manufacture a `user_override` or widen the
mission's decision policy. Direct user steering also does not silently grant an
executable, credential, or repository mutation the session did not already
possess. Repository-wide hard authorities, including the current rule that only
the PR drainer merges, remain in force unless the user deliberately changes
that authoritative contract rather than merely asking a workflow agent to
ignore it.

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

#### Future capability expansion

The registry is intentionally extensible. Later arcs may add managed actions
for test and playtest campaigns, test-result assessment, free-form repository
exploration, audits/findings capture, issue drafting, design-document sessions,
report processing, backlog work, release operations, or other Kanban-owned
project workflows. Each addition names its own authority, durable state,
completion evidence, mutation budget, interruption behavior, and child-session
contract rather than widening one permanent superagent prompt invisibly.

Those capabilities are not first-release requirements. Direct user steering of
a live agent remains broader than autonomous registry dispatch, so the narrow
registry does not prevent the operator from redirecting a session while the
formal capability surface grows over time.

### Durable mission record

Each mission should live under a private, repository-qualified durable XDG
state/application-data root, not solely under the collectable worker cache, and
contain conceptually:

- a versioned immutable specification: mission ID, repository identity,
  original request, normalized selector/target snapshot, policy, creation
  time, and initial plan;
- a replaceable atomic snapshot: lifecycle, current/next steps, pause state,
  attention item, planner summary, retry counters, and last reconciliation;
- an append-only JSONL event journal: commands, accepted plans, dispatch
  attempts, worker/service references, outcomes, questions, answers, policy
  changes, cancellation, and recovery decisions;
- a session tree with provider IDs, parent IDs, process ownership, and live log
  references; and
- mission-owned sealed archives of every child event stream and raw provider
  log needed to reconstruct its history after the worker cache is collected.

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

A live child may write to the provider's existing private log while the mission
records its path and consumes its events. Before that path becomes eligible for
worker-cache collection, the runner seals the complete stream into the durable
mission archive and records its digest and byte length. Mission history is not
removed by the worker cache's fourteen-day collection. It remains until an
explicit mission archive/deletion policy removes it; summaries may compact the
planner's context, but never substitute for or rewrite the retained raw log.

### Mission lifecycle and reconciliation

At minimum a mission distinguishes `planned`, `running`, `waiting_input`,
`waiting_barrier`, `paused`, `interrupted`, `recovering`, `completed`, `failed`,
and `cancelled`. A step
distinguishes `pending`, `dispatching`, `running`, `outcome_unknown`,
`interrupted`, `orphaned`, `recovering`, `succeeded`, `needs_changes`,
`needs_input`, `failed`, and `cancelled`.

On normal dashboard attachment, live-runner reconciliation, or an explicitly
initiated interrupted-work recovery pass, the controller:

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

The runner, rather than the dashboard, performs this reconciliation between
steps while the TUI is absent. A newly opened dashboard is a read/steer client:
it discovers the runner and mission records, acquires no competing advancement
lease, replays every unconsumed mission/session event, and subscribes to new
events. From the operator's perspective this is the same console continuing;
the reattachment does not restart the plan or create replacement children.

### Fixed membership, live facts, and external work

An `all` command takes one complete finite membership snapshot. That fixes
*which target identities* the mission owns, not the facts the mission may
assume about them. Before every dispatch, after every child result, and before
every GitHub mutation, the owning workflow rereads the live target and its
canonical state. The runner records both the observation the plan was based on
and the later observation that authorized or refused the effect.

External manual or agent-driven work is expected. Reconciliation follows these
principles:

- a current canonical outcome that already satisfies the step is recorded as
  `satisfied_externally` and is not repeated;
- changed labels are classified through the current workflow rules rather than
  restored to the mission's older snapshot;
- a changed issue body invalidates any plan or review tied to its older
  fingerprint and causes re-evaluation against the new specification;
- an existing compatible managed worker is attached to the mission when
  ownership and intent can be proven; a conflicting or opaque live action is
  waited on or handed to the operator rather than duplicated;
- an issue or PR that became terminal is classified from live state instead of
  reopened or mutated; a satisfied target becomes `satisfied_externally`, while
  a target made inapplicable for another authoritative reason becomes
  `skipped_external` and the batch continues unless that change invalidates a
  dependency, conflicts with the mission goal, or cannot be classified
  confidently; and
- every write based on a prior issue body, review record, branch head, or PR
  state uses that exact version as a precondition. A concurrent edit or push
  causes a fresh read and replan, never a blind overwrite.

The finite target set changes only through an explicit operator amendment,
which is another versioned mission event. Through the mission-level console the
operator may add or remove targets, change policy, pause dispatch, or redirect
the durable goal while work runs; the controller recomputes only
not-yet-committed steps and preserves the history of the superseded plan. This
explicit amendment is distinct from D-17's direct guidance inside one live
session, which never transfers the mission. Newly created repository items
never enter the mission merely because they match its original selector.

### Batch selection, ordering, and concurrency

An explicit target list becomes durable at command acceptance. Each target is
a child step with its own state and transcript link. The controller preserves
input order for presentation and stop policy even when it runs independent
children concurrently.

`all` snapshots the complete eligible target set when the command is accepted,
records those identities, and terminates when that set is processed. An
explicit `watch` form controls the existing live approval service and may
include newly opened issues. This prevents an apparently finite chat command
from silently becoming a daemon while still leaving live queue behavior
available by name.

The first concurrency policy is a configurable default of two simultaneously
running mutation-capable agent children per canonical repository, counted
across all missions. Two permits useful parallel autosolve without allowing one
broad command to create an unbounded number of providers, worktrees, CPU-heavy
processes, or likely-conflicting branches. It is a repository coordination
ceiling, not a claim that two is an intrinsic provider limit; host- or
provider-wide budgets may impose a separate lower ceiling.

Issue approval remains serialized by its canonical lock and ordered barrier.
Solve/autosolve children may use the two slots only when their worktrees and
logical dependencies are independent; filesystem isolation alone is not proof
of independence. Known dependencies, the same target, or an existing live
worker serialize. Provider-capacity or rate-limit observations pause dispatch
without failing already-running children. Configuration may lower the limit to
one or raise it deliberately as the host and workflow mature.

Default batch policy is fail-closed:

- changes requested stops the ordered batch at that target;
- needs input opens an attention item and stops later ordered work;
- an outcome-unknown, invalid, or failed child stops later work;
- `satisfied_externally` and confidently classified `skipped_external` consume
  their positions and advance the batch;
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

The default automatic issue policy authorizes edits that directly implement
review feedback but asks before making a product, scope, priority, or dependency
choice. A mission may carry broader delegated decision authority, as described
below. Neither the default nor delegated decision authority implicitly permits
closing the issue, changing its origin, starting solve, or treating approval as
permission for the next workflow; those are separate actions.

For a PR, the corresponding loop should reuse the existing canonical
review/`pr-revise`/rereview path and its round limit. It never pushes directly
through a general planner and never merges after approval.

Progress detection compares canonical verdict identity, target fingerprints,
and normalized recommendations across rounds. Repeated equivalent feedback,
no target change, conflicting feedback, a new unrelated recommendation after
the limit, or any indeterminate mutation stops the mission. “Plow through” is
therefore an explicit permission to apply bounded actionable recommendations,
not permission to invent answers or erase barriers.

### Decision delegation and thresholds

Decision authority is a versioned per-mission policy whose repository default
is **ask**. The operator can widen or narrow it when creating a mission or while
it runs. Natural language such as “make any obvious product/scope decisions;
if there are reasonable alternatives, stop and ask” is normalized into a
visible policy rather than left as an impression buried in chat history.

The initial policy vocabulary should distinguish at least:

- **Ask:** make no product or scope choice without operator input.
- **Constrained judgment:** decide within named categories only when one option
  is materially dominant under the mission goal and constraints; stop when two
  or more reasonable alternatives remain.
- **Delegated judgment:** choose among reasonable alternatives within the named
  categories and explicit bounds, while recording the alternatives and
  rationale.

“Obvious” should not be represented only by a model confidence percentage.
The planner must return a structured decision record containing the question,
categories affected, alternatives considered, evidence, materiality,
reversibility, recommendation, and why alternatives are or are not reasonable.
The controller compares that record with the mission's permitted categories
and bounds. Under constrained judgment it accepts a decision only when the
agent reports one reasonable option and the change remains within those bounds;
otherwise it creates a `needs_decision` attention item.

Every autonomous product or scope decision is appended to the durable history
before its dependent action starts and is visible when the operator reattaches.
A policy change affects future undecided steps, never retroactively rewrites
why an earlier decision was authorized. Hard workflow boundaries — canonical
approval, repository identity, target-version preconditions, no forced labels,
and no merge — remain non-delegable regardless of wording.

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

Mission execution is service-supervised. One installed runner per canonical
repository arbitrates that repository's runnable missions, using the existing
service-manager boundary and durable status/incident conventions. Explicitly
dispatching a mission starts or wakes the runner. The runner owns progression,
launches bounded planner/worker turns as needed, and continues until every
mission is terminal, paused, or waiting for input/policy. The model processes
remain episodic even though the controller persists.

The installed service process is the lightweight supervisor, not the scheduler
directly. It maintains the scheduler/descendant census and publishes
`interrupted` after a scheduler failure only after cascading termination is
verified. It then stays stopped or waiting for manual resume; it never replaces
the failed scheduler automatically.

The mission itself has no four-hour lifetime. Individual agent executions
remain bounded so one lost provider cannot own a target or mission forever. A
long operation checkpoints its result and yields another registered step or
continuation. Once that parent and its descendants have settled, the runner may
spawn the next sequential step under the still-live mission root; the next
bounded agent receives the durable mission brief and logs. The exact child
deadline may remain the current four hours or become a mission policy, but an
agent may not evade it by abandoning an unregistered background descendant.

The TUI never needs to stay alive for progress. On exit it disconnects only its
event reader; it does not stop the runner or active child processes. On the
next start it discovers the same repository runner and mission store, replays
history, and follows the live tail. A runner waiting exclusively for operator
input may remain cheaply idle or exit and be restarted by the answer, provided
both choices publish the same durable waiting state.

The installed job does not automatically resume interrupted missions after a
service crash, logout, machine restart, or login. Continuing across ordinary
TUI exit is settled because the runner never died; recovery after its death is
manual and follows the contract below.

### Interrupted recovery and worktree handoff

An unexpected runner exit, stale heartbeat with no matching runner identity,
logout, or reboot moves every nonterminal mission it owned to the derived
`interrupted` presentation. No provider or next step starts merely because the
service manager or TUI returned. The mission's normal action hotkey becomes
**resume interrupted work**; activating it starts one bounded recovery pass,
not a blind replay of the failed command.

Recovery first walks the durable session tree. Any descendant that should have
died with its parent is terminated through recorded process identities and the
result is verified. A surviving or unverifiable descendant leaves the mission
`interrupted · orphaned` and blocks resume rather than permitting a second
agent to overlap it.

Once the old tree is provably settled, recovery reconciles external effects and
builds a durable handoff containing at least:

- the original mission and current plan/policy versions;
- the failed runner, session, step, last activity, timestamp, and available
  provider/session identifiers;
- the complete prior log plus a bounded summary of progress, decisions,
  questions, and the failure boundary;
- live issue/PR state, canonical verdicts, labels, comments, and outcome-unknown
  checks relevant to the step; and
- for implementation work, the exact worktree path, branch, base and current
  heads, commits created, `git status`, tracked diff, untracked paths, and any
  recorded validation results.

The recovery agent is explicitly told that the worktree is existing work to
inspect and continue. It must not create a replacement, reset it, discard
uncommitted changes, or repeat a GitHub mutation whose outcome has not been
reconciled. If the prior provider thread can safely resume, that remains an
optimization; a fresh agent process must still receive the complete handoff so
recovery never depends on provider-side session retention.

The successful recovery pass records a new session node linked as the
interrupted session's continuation, starts the runner, and resumes progression.
The old node and failure remain immutable history. Pressing the hotkey again
while recovery is already running is refused rather than starting a duplicate.

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

### D-9. Explicit missions keep advancing after the TUI exits

A repository mission runner, not the dashboard, owns progression. Closing
Kanban leaves the runner and its children active, and reopening Kanban attaches
to their durable state instead of restarting them. Model agents remain bounded
processes; persistence belongs to the runner and mission records. This resolves
Q-1 for ordinary dashboard exit; D-15 separately governs crash/reboot recovery.

### D-10. `all` fixes membership while every target's facts stay live

An `all` command records one finite complete target snapshot and never absorbs
new matching items implicitly. The controller nevertheless revalidates every
target and precondition at each effect boundary, adapting to current labels,
specifications, PR heads, canonical verdicts, and compatible work performed by
people or other agents. This resolves Q-2. A separately named `watch` operation
owns live selector behavior.

### D-11. Decision authority defaults to ask and can be delegated per mission

Product and scope choices stop for the operator by default. A mission command
may grant constrained or broader judgment in named categories and bounds — for
example, choose only when one materially dominant option exists and ask when
reasonable alternatives remain. Every autonomous decision records its
alternatives, evidence, rationale, and authorizing policy. This resolves Q-3 at
the product-policy level; exact planner schemas belong to SAG-6 and SAG-7.

### D-12. Mission logs and lineage outlive the worker cache

Reattachment after a long absence includes the full durable mission history
and every managed child log, including sessions completed while Kanban was
closed. The mission archive is not subject to the current worker cache's
fourteen-day collection and is removed only through an explicit archive or
deletion policy. Provider session expiration may prevent literal thread resume
but never erases the transcript or mission continuity.

### D-13. Compatibility with external work is a first-class invariant

Manual actions and other agents may change any target while a mission runs.
The mission never restores its old snapshot blindly: it rereads live state,
recognizes already-satisfied work, invalidates stale assumptions, attaches to
compatible managed work when provable, and uses exact-version preconditions to
avoid overwriting concurrent edits.

### D-14. Session descendants use structured concurrency

Every registered child has one tracked parent. A parent joins its children
before normal completion, and parent failure, timeout, cancellation, or kill
recursively terminates and reaps the entire descendant subtree. No child is
reparented or allowed to become a stray agent. Provider-internal subagents may
remain opaque within the parent transcript for the first release, resolving
Q-7; a follow-on design will explore provider-native tracking when stable
identity, event, and cancellation protocols exist.

### D-15. Runner or host failure requires manual, contextual recovery

An ordinary TUI exit leaves the live runner alone, but runner crash, logout, or
machine restart marks its nonterminal missions interrupted and starts nothing
automatically. The normal action hotkey initiates recovery: settle the old
descendant tree, reconcile outcome-unknown effects, inspect and preserve any
existing worktree, and give a fresh process the failure and work-in-progress
handoff. This resolves Q-8.

### D-16. Initial autonomous dispatch is narrow but deliberately extensible

This epic registers review, revision, solve/autosolve, PR, and approval-service
actions. Testing, free-form code exploration, report/design drafting, and other
project capabilities are future registry extensions rather than first-release
requirements. This resolves Q-10 without narrowing the long-term product goal.

### D-17. Direct user steering outranks the current mission plan

An operator may redirect a live agent, including to work outside its current
step, and the agent obeys within the authority its session actually has. Kanban
records that trusted override and reconciles or supersedes the plan afterwards.
Model output and repository content cannot claim this authority, and direct
steering does not silently override repository-level hard authorities. Even a
completely unrelated redirection stays in the original selected session and
mission for that session's lifetime; Kanban does not transfer or reparent it.
This resolves Q-11.

### D-18. The first interface is hybrid rather than command-only

Known commands normalize deterministically, broader prose goes through the
bounded planner, and a selected live session accepts direct conversational
guidance. This resolves Q-4 and preserves useful operation when the planner is
unavailable.

### D-19. Two mutation-capable agent children may run per repository by default

The initial configurable admission ceiling is two simultaneously running
mutation-capable agent children across all missions for one canonical
repository. This provides real parallel autosolve while bounding worktree,
provider, host-resource, and conflict pressure. Dependencies and lower-level
authorities may serialize further; explicit configuration may lower or raise
the ceiling. This resolves Q-5. A future multi-repository deployment may also
need a host- or provider-wide budget above the repository controllers.

### D-20. Externally inapplicable batch targets are skipped when classification is certain

If current state proves a target already satisfies the requested outcome, the
mission records `satisfied_externally`. If outside work instead made it
inapplicable, the mission records `skipped_external` and continues. It stops
only when the change invalidates a dependency or mission goal, conflicts with
the requested outcome, or cannot be classified confidently. This resolves Q-9
and makes finite batches tolerant of the repository's moving state without
inventing success.

## Open questions

### Q-1. Must missions keep advancing after Kanban exits?

Resolved by D-9. Ordinary TUI exit never pauses an explicitly dispatched
mission. D-15 resolves recovery after service or machine restart as manual.

### Q-2. Is `all` a finite snapshot or a live selector?

Resolved by D-10. `all` has finite membership and live facts; `watch` is the
separately named live selector.

### Q-3. How much issue-specification authority does auto-remediation receive?

Resolved by D-11. The default asks; a mission may delegate bounded decision
authority and define when alternatives require a handoff.

### Q-4. How conversational is the first release?

Resolved by D-18. Commands are deterministic, broader requests are planned,
and live agents accept direct user guidance.

### Q-5. What is the first concurrency ceiling?

Resolved by D-19. Two mutation-capable agent children may run per repository by
default, with configuration and stricter dependency/authority/provider limits.

### Q-6. Which key and product name should the console use?

Choose after the pending approval-service UI lands and the complete key table
can be audited. “Superagent” is evocative; “Operator,” “Mission Control,” or
“Steward” may communicate bounded orchestration more accurately in the UI.

### Q-7. Which nested agents must be separately reattachable?

Resolved by D-14. Opaque provider-internal subagents are acceptable in the
parent transcript for now, but every registered child has a tracked parent and
dies with its parent. The follow-on design seed preserves the desire to expose
opaque children properly later.

### Q-8. What resumes automatically after a crash or machine restart?

Resolved by D-15. Nothing resumes automatically after runner or host failure;
the ordinary hotkey starts manual contextual recovery.

### Q-9. How should externally terminal targets affect an ordered batch?

Resolved by D-20. A proven satisfied target advances as
`satisfied_externally`; a confidently classified no-longer-applicable target
advances as `skipped_external`; dependency, goal, conflict, and ambiguity cases
stop.

### Q-10. May the superagent invent general project work outside the registry?

Resolved by D-16 and D-17. Autonomous first-release dispatch stays narrow and
future arcs add testing, exploration, and document workflows. A user may still
redirect an already-running agent beyond its current step.

### Q-11. Does a complete user redirection amend or fork the mission?

Resolved by D-17. It does neither: the instruction and resulting work remain in
the original selected session and mission until that session ends. The durable
history records the redirection without transferring ownership.

### Q-12. What exactly ends directly redirected session work?

Closing the overlay and closing Kanban already leave ordinary authorized work
running, so “until the user quits” needs one precise control. The proposed
distinction is that navigation away or TUI exit only detaches, while an explicit
terminate-session action ends the agent and its descendants. The mission then
reconciles what actually happened and stops for the operator if its original
outcome remains unmet.

### Q-13. Do new direct commands outrank queued autonomous batch work?

With two repository slots, a fresh operator command may otherwise sit behind a
large mission's queued children. The proposed rule is to prioritize newly
dispatched direct work over not-yet-started autonomous children without killing
or preempting anything already running.

### Q-14. Is durable mission history retained indefinitely by default?

The design requires history to outlive the fourteen-day worker cache but leaves
its archive/deletion default unsettled. Indefinite private retention with an
explicit archive/delete control best matches long-gap reattachment, while a
configurable retention policy would limit disk and sensitive-data growth.

## Verification strategy

- Pure tests cover command parsing, target typing, plan validation, lifecycle
  transitions, batch order, barriers, concurrency admission, loop bounds,
  progress detection, external-state classification, decision-policy gates,
  and recovery decisions.
- Temporary repositories and fake `gh`, `codex`, and `claude` executables cover
  each registered action without accounts or network access. Existing workflow
  suites remain the authority for child behavior; mission tests assert adapter
  invocation and observed results rather than duplicating their internals.
- Durable-state tests cover whole JSONL appends, partial trailing records,
  atomic snapshots, user-only permissions, schema evolution, competing mission
  leases, child lineage, sealed full-log archives, explicit deletion, corrupt
  records, and repository identity mismatch.
- Crash fixtures cover before-dispatch, after-dispatch/before-record,
  live-worker reattachment, dead worker with a landed GitHub result, dead worker
  with unknown outcome, runner restart, and TUI restart. A long-running fixture
  exits the TUI, lets the runner dispatch and complete later children, then
  reopens Kanban and proves the complete tree and logs replay without rerun.
- Structured-concurrency fixtures build multi-level registered process trees.
  Normal parent completion waits for children; parent kill, timeout, and crash
  terminate the whole subtree; an unverifiable survivor blocks settlement and
  recovery; no child is reparented or left running after verified parent death.
- Manual-recovery fixtures crash the runner with committed and uncommitted
  worktree state, prove no login/TUI restart launches work, activate recovery
  through the action boundary, and show the fresh agent receives the failure,
  log, branch, commits, status, diff, untracked paths, and live tracker state
  without resetting or duplicating the prior effect.
- UI event and golden tests cover hotkey entry, mission navigation, command
  input, attention handoff, child opening/return, small-terminal behavior,
  scroll/follow state, cancellation, and status colors.
- Security tests ensure untrusted tracker/provider text cannot create an
  unregistered action, alter repository identity, weaken policy, or cross an
  approval/merge boundary. Only real console input can create a `user_override`;
  identical text from an issue, file, model, or child session cannot.
- Interoperability fixtures mutate issue bodies, labels, issue state, PR heads,
  and canonical verdicts between plan, dispatch, and result. They prove current
  satisfaction is not repeated, stale writes do not land, a conflicting worker
  is not duplicated, externally inapplicable targets skip only after certain
  classification, dependency/conflict/ambiguity cases stop, and fixed `all`
  membership never absorbs a new item.
- Planner-policy fixtures distinguish ask, constrained judgment, and delegated
  judgment; record alternatives and rationale; and stop constrained judgment
  when more than one reasonable option remains.
- Steering fixtures forward a trusted redirection to the selected agent,
  preserve the old plan and exact user message, reconcile its actual effects,
  keep it in the original session without reparenting, and never misclassify the
  redirected turn as autonomous policy expansion.
- Scheduler fixtures enforce two mutation-capable agent children across
  concurrent missions in one repository, preserve lower serialized locks, and
  show that configured/provider limits pause only new admission.
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
  snapshot, and JSONL event schemas; parent/child lineage; decision policies;
  mission-owned sealed log archives; private/atomic persistence; leases;
  explicit archive/deletion; corruption and schema diagnostics; pure and
  filesystem tests.
- **Phase:** 1 — durable foundation.
- **Depends on:** `none`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-1`, `D-2`, `D-5`, `D-11`, `D-12`, `D-14`,
  `D-15`, `D-17`.
- **Acceptance signals:** A mission round-trips across process restart; partial
  journal writes are not consumed; two controllers cannot advance it; private
  modes and repository identity are verified; a child log survives worker-cache
  collection and remains linked to its parent.
- **Out of scope:** Workflow launch, providers, UI, batch progression, and
  natural-language planning.
- **Open questions:** `Q-14`; provider-native observability is a follow-on
  design rather than a blocker to the structured tree.

### SAG-2. Expose a typed workflow action registry

- **Outcome:** Board actions and future mission steps can resolve and invoke the
  same typed canonical capabilities without simulating keystrokes.
- **Scope:** Action/target/policy types; live target resolution; capability and
  preflight queries; adapters around the already persistent solve/autosolve and
  PR review/revise workers plus approval-service observation; the issue-action
  interface SAG-10 will implement; validated result vocabulary; fake-executable
  tests.
- **Phase:** 2 — authority boundary.
- **Depends on:** `SAG-1`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-3`, `D-7`, `D-8`, `D-13`, `D-16`, `D-17`.
- **Acceptance signals:** Each action reaches its existing authority with exact
  repository/config/target data; incompatible and historical targets refuse;
  no registry path forces approval or merges.
- **Out of scope:** Mission scheduling, console UI, broad selectors, and
  planner-generated actions.
- **Open questions:** `None`; general project actions are future extensions by
  D-16.

### SAG-10. Make issue review and revision runner-owned

- **Outcome:** Canonical issue review/rereview and interactive issue revision
  run through durable detached action workers that survive TUI exit, publish
  complete logs, and can be reattached like solve and PR workflows.
- **Scope:** Replace the TUI-owned canonical subprocess and app-server revision
  lifecycle with registry-backed durable workers; persist provider/protocol
  identifiers, questions, answers, log events, and terminal results; preserve
  canonical backend authority, approval-service locking/interlocks, process
  termination, and board-key behavior; recovery and fake-provider tests.
- **Phase:** 3 — complete the durable action set.
- **Depends on:** `SAG-1`, `SAG-2`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-2`, `D-3`, `D-4`, `D-7`, `D-9`, `D-12`, `D-13`,
  `D-14`, `D-15`.
- **Acceptance signals:** Kanban may exit during an issue gate or revision;
  work continues under the runner, a later TUI replays its complete transcript,
  a pending question remains answerable, and canonical comments/labels are
  still mutated only by `approve_issues.py`.
- **Out of scope:** Multi-target scheduling, natural-language planning, and
  automatic recommendation policy.
- **Open questions:** `None`; provider-internal subagents remain opaque and
  owned by the parent.

### SAG-3. Run and recover one mission outside the board selection

- **Outcome:** A controller can dispatch, observe, stop, resume, and recover one
  mission step using durable evidence and existing worker/service state.
- **Scope:** Mission runner; dispatch-before-effect journal boundary; worker and
  GitHub reconciliation; exact-version preconditions; attention, pause,
  cancellation, outcome-unknown, provider-session fallback, registered child
  requests, live fact changes, startup discovery, and crash fixtures. Exercise
  it as a foreground runner before installation.
- **Phase:** 4 — execution and recovery.
- **Depends on:** `SAG-1`, `SAG-2`, `SAG-10`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-2`, `D-3`, `D-7`, `D-8`, `D-12`, `D-13`,
  `D-14`, `D-15`, `D-17`, `D-20`.
- **Acceptance signals:** A live worker reattaches; a landed result reconciles;
  an indeterminate mutation stops instead of rerunning; guidance can resume
  with the prior provider session or a fresh bounded brief; concurrent target
  drift is reclassified rather than overwritten.
- **Out of scope:** Service installation and no-TUI progression, multi-target
  scheduling, and UI.
- **Open questions:** `Q-12`.

### SAG-9. Keep active missions advancing without the dashboard

- **Outcome:** An explicitly dispatched mission continues launching and
  observing its eligible registered children after Kanban exits, and a later
  dashboard replays the complete durable session tree and follows its live
  tail.
- **Scope:** Per-repository mission controller service; installer/discovery;
  service-manager integration and outer containment; lightweight supervisor and
  scheduler split; mission arbitration and leases; start/wake, idle/wait, stop,
  crash, and upgrade behavior; structured descendant ownership and cascading
  termination; interrupted/manual recovery; durable status/incidents;
  event-reader reattachment; session-log sealing; no-TUI and restart fixtures.
- **Phase:** 5 — persistent execution.
- **Depends on:** `SAG-1`, `SAG-2`, `SAG-3`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-2`, `D-9`, `D-12`, `D-13`, `D-14`, `D-15`.
- **Acceptance signals:** After the TUI exits, the service completes one child,
  dispatches the next authorized child, records both full logs, and exposes the
  same mission when Kanban reopens; two runners cannot advance one mission;
  waiting for input performs no hidden work; a runner crash kills or blocks on
  every descendant and waits for the explicit recovery hotkey; no verified
  parent death leaves a live child process.
- **Out of scope:** Multi-target scheduling policy, console rendering,
  automatic post-crash/reboot mission resume, and provider-native internal
  subagent presentation.
- **Open questions:** `Q-12`.

### SAG-4. Add the persistent console and mission navigation

- **Outcome:** A hotkey opens the durable project console and users can inspect,
  select, guide, pause, cancel, and navigate between missions and child
  sessions.
- **Scope:** Overlay layout, history summaries, input state, mission list,
  attention routing, child links/return, board-action reuse, help/key contract,
  responsive rendering, and golden/event tests.
- **Phase:** 6 — operator surface.
- **Depends on:** `SAG-9`; land after the pending approval-service control
  (#421) or re-audit the whole key/layout surface against it.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-1`, `D-4`, `D-9`, `D-12`, `D-15`, `D-17`,
  `D-18`.
- **Acceptance signals:** TUI restart restores the same missions and selected
  history; a card opens its mission-owned child; attention opens the exact
  question; `interrupted` is visible and its ordinary action hotkey starts one
  recovery; direct user steering is recorded; no duplicate worker launches.
- **Out of scope:** Broad selectors, natural-language planning, and automatic
  remediation.
- **Open questions:** `Q-6`, `Q-12`.

### SAG-5. Schedule explicit and selector-based batches

- **Outcome:** One mission can own an ordered explicit list or complete target
  selector and advance its children under bounded concurrency and stop policy.
- **Scope:** Deterministic command grammar; target-set inventory validation and
  persistence; explicit order; concurrency admission; stop/barrier behavior;
  approval batch/service integration; multi-autosolve dispatch; batch UI
  summaries and tests.
- **Phase:** 7 — batch orchestration.
- **Depends on:** `SAG-3`, `SAG-9`, `SAG-4`; consume rather than duplicate epic #318's
  canonical queue/service authority.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-3`, `D-5`, `D-6`, `D-7`, `D-8`, `D-10`,
  `D-13`, `D-19`, `D-20`.
- **Acceptance signals:** Explicit targets are never lost or reordered;
  stop-on-changes dispatches nothing past its barrier; parallel failure stops
  new work without killing live siblings; `all` follows the selected finite or
  finite-membership/live-facts contract; a changed target is reclassified
  against its current state before any effect.
- **Out of scope:** Planner-generated plans and automatic recommendation
  application.
- **Open questions:** `Q-13`.

### SAG-6. Add bounded natural-language planning

- **Outcome:** Conversational input can become a visible, validated mission
  plan composed only of registered actions, while recognized commands continue
  without a planner.
- **Scope:** Planner prompt/schema, bounded mission brief and summaries,
  plan validation, clarification/acceptance flow, policy display, model failure
  fallback, untrusted-input boundaries, and fixtures.
- **Phase:** 8 — superagent reasoning.
- **Depends on:** `SAG-2`, `SAG-4`, `SAG-5`.
- **Ordering:** `not on the critical path` for deterministic commands, required
  for the full epic experience.
- **Relevant decisions:** `D-1`, `D-2`, `D-3`, `D-5`, `D-11`, `D-13`,
  `D-16`, `D-17`, `D-18`.
- **Acceptance signals:** Prose creates only registered typed steps; ambiguous
  scope is shown or questioned before dispatch; injected tracker text cannot
  alter policy; planner outage leaves direct commands and history usable.
- **Out of scope:** Autonomous general project actions beyond the first
  registry; direct trusted-user steering remains allowed by D-17.
- **Open questions:** `None`.

### SAG-7. Add opt-in recommendation application and rereview loops

- **Outcome:** An explicitly authorized mission can apply actionable canonical
  review feedback to an issue or PR, verify progress, rereview, and either
  continue after approval or stop with a precise handoff.
- **Scope:** Remediation policy; structured issue revision outcomes; review
  record/fingerprint binding; PR `pr-revise` reuse; rereview; progress and
  repeated-feedback detection; round limits; decision-required boundaries;
  crash and end-to-end tests.
- **Phase:** 9 — bounded autonomy.
- **Depends on:** `SAG-3`, `SAG-5`, `SAG-6`.
- **Ordering:** `not on the critical path` for the safe stop-on-changes console.
- **Relevant decisions:** `D-3`, `D-6`, `D-7`, `D-8`, `D-11`, `D-13`.
- **Acceptance signals:** Actionable feedback can reach current approval;
  out-of-policy decisions and multiple reasonable alternatives under
  constrained judgment stop; no-progress and repeated feedback halt; an
  unknown edit is never repeated; no issue is solved and no PR is merged as an
  implicit consequence of approval.
- **Out of scope:** Inferring unrestricted product decisions or bypassing the
  canonical rereview.
- **Open questions:** `None` at the product-policy level; exact schema choices
  are part of this slice.

### SAG-8. Document authority, operation, and recovery

- **Outcome:** Operators and future implementations have one accurate contract
  for console commands, mission storage, runner lifetime, authority, recovery,
  safety, and troubleshooting.
- **Scope:** Authoritative design and workflow-contract updates; development,
  setup, storage/privacy, recovery, key/help, dependency, and package
  documentation; publication classification for this design record.
- **Phase:** 10 — operability and contract closure.
- **Depends on:** every implemented slice; documentation for a deferred slice
  remains in this design rather than claiming shipped behavior.
- **Ordering:** `critical path` for epic completion.
- **Relevant decisions:** `D-1` through `D-20`.
- **Acceptance signals:** Documented commands and paths match tested behavior;
  every executable and durable record has an authority/ownership entry; users
  can distinguish pause, barrier, failure, unknown outcome, and recovery.
- **Out of scope:** Tracker drafting and implementation of deferred choices.
- **Open questions:** `Q-14`; all questions affecting implemented behavior
  must be resolved or explicitly deferred before this slice completes.
