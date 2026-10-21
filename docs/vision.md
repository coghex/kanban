# Kanban vision

Accepted by the owner on 2026-10-01. It changes only when the owner settles a
material choice; each change records its date and source beside it.

**Changed 2026-10-20 (owner, through request `kan-strip-20261020`).** Kanban
was reduced to two things: the board, with its usage panel, and the tracker of
the owner's skills and scripts. The application's agent control, missions,
in-app workers and model roster were removed, so the third thing this document
named is gone, V-5, V-9, V-10 and V-13 are retired below, and V-2, V-3, V-7,
V-8, V-12 and the state of the direction were edited to stop naming what was
removed. Nothing else was reworded.

Kanban is a terminal-native board for one GitHub repository, beside which the
repository tracks the owner's workflow skills and scripts. It is two things that
share one model of the work:

1. **A board.** A fast, quiet, keyboard-driven view of a repository's issues and
   pull requests, sorted into workflow columns derived from GitHub, with the
   Codex and Claude usage panel beside it. This is what Kanban mainly is.
2. **A tracker of the owner's skills and scripts.** The tracked, versioned skill
   and command bundles (`claude-plugin/`, `codex-plugin/` and the
   external-origin bundles) that agents execute to draft, solve, review, repair
   and land work, and the scripts under `tools/` (the PR drainer, the issue
   approval service and the installers) that move approved work along. The
   application neither runs nor drives either: they are installed and started
   by their own scripts.

Its first user is the owner, who runs several active repositories through this
pipeline. Its second audience is anyone who installs a public release; nothing
in it may depend on the owner's repositories or the owner's setup.

**Pace (owner, 2026-10-01).** The board is feature complete. Kanban is not
actively developed the way the owner's other projects are: it is where spare
compute goes when a usage window is about to reset. Most current work is the
agent add-ons. The long-term features already designed under `docs/designs/` are
wanted, and are meant to arrive slowly. Nothing here is urgent, so a slower
change that keeps the board stable beats a faster one that risks it.

Authority, in order: explicit owner decisions (dated, here or linked), then
[`docs/design.md`](design.md) (the behavior contract) and
[`docs/agent-workflow-contract.md`](agent-workflow-contract.md) (external
executables, authority and durable state), then the accepted designs under
`docs/designs/`.

## The board

### V-1. GitHub is the bus; keep no second board

Workflow state is derived from GitHub (issue and PR state, the `reviewed:*`
labels, origin markers, checklists and sub-issues) and never stored in a
parallel board database. Every agent and every human reads and writes the same
record, which is what lets hand-driven and agent-driven work interleave.

- Rationale: a second source of truth would have to be reconciled against the
  first by every actor, including ones Kanban never sees.
- Authority: design.md §2 ("Derive workflow state from GitHub"), §8, §12.

### V-2. Contact external services only when the user asked

Kanban makes no request to GitHub or an AI provider that the user did not ask
for: no automatic polling, no background refresh, no speculative fetches. The
network is touched only at startup, on an explicit update, and on a
rate-limited terminal-focus update. A service the owner started polls only at
its own bounded interval, and only while the owner keeps it running. While
nothing changes, the board does no work. There are
no performance targets beyond that: the constraint is how much Kanban asks of
external servers, not how fast it runs.

- Authority: owner, 2026-10-01 ("we dont ping the external servers too much,
  only if we must on user request"); design.md §1, §3 (no automatic polling),
  §15.

### V-3. The board stands alone and is protected

The board is fully usable with only Git and an authenticated `gh`. AI
providers, the workflow bundles and every background service are optional
add-ons, and a missing or failing one degrades only its own feature. One failing
source never hides valid data from another, and the last good snapshot survives
a failed refresh. The board is feature complete, so work on the skills and
scripts must not regress its behavior, responsiveness or quietness.

- Authority: owner, 2026-10-01 (the board is the product and is complete);
  README "Before you start"; agent-workflow-contract.md §1; design.md §2.

### V-4. Project-agnostic

Kanban serves an arbitrary GitHub repository with no repository-specific code.
The owner's repositories are test targets, never special cases.

- Authority: design.md §2; owner, 2026-07-26 (see V-8).

## The skills and scripts

### V-5. Retired 2026-10-20: every mutation is explicit and has one owner

Retired by the owner's removal of the application's agent control (request
`kan-strip-20261020`): the authorities it named — `PullRequestFlow`,
`Preflight`, `Worker`, `ProviderAdapter` and the action registry — no longer
exist. What survives of it is stated elsewhere: the board is read-only
(design.md §1, §3), and merging belongs to the drainer (V-6).

### V-6. Agents never merge

No agent merges on its own initiative. Solve, review and autonomous workflows
stop at the open PR. The PR drainer merges eligible approved work. Manual
`finalize` is the owner's to invoke, and only for one named PR. Agents never
force an approval, skip a changes-requested barrier, or invent success after an
unknown outcome.

- This holds until the owner decides otherwise; no feature may assume it will
  change.
- Authority: owner, 2026-10-01 ("permanent for now"); CLAUDE.md "Pipeline
  conventions"; agent-workflow-contract.md §2.10.

### V-7. Review comes from another provider when one is available

Every agent-authored issue and pull request carries an origin marker. With two
providers configured, its canonical review comes from the provider that did not
write it. Unknown or legacy origins are reviewed by both. External-origin
bundles (Grok, Kimi, Google, Copilot-Claude) are reviewed by Codex and are never
revised by a spawned provider. With one provider, review routes to that provider
behind gates that know the mode. With none, the review scripts do nothing and Kanban
is a board.

- Rationale: a model reviewing work from its own provider shares its blind
  spots. The rule serves the user and never blocks a setup the user chose (V-13).
- Authority: CLAUDE.md "Pipeline conventions"; agent-workflow-contract.md §2.3
  (dual, single-agent and no-agent modes); model_settings_design.md.

### V-8. Hand-driven work always takes precedence

A human editing the same checkout, on `master`, with uncommitted work, is the
normal case, never an error. No service or action may assume it owns the
working tree, the branch or the merge queue, or refuse to work because a human
moved something. The drainer and every coordinator work around the human; the
human never has to work around them.

- Rationale: this is the property the owner values most. It is what made Kanban
  usable in production while every other feature was optional.
- Authority: owner, 2026-07-26 (compatibility with manual work is "an absolute
  requirement"); owner, 2026-10-01 (it always takes precedence, and the
  automation must work around the owner).

### V-9. Retired 2026-10-20: agent work is durable, recoverable and fails closed

Retired by the same removal (request `kan-strip-20261020`): the detached
workers, journals, leases and runner it described are gone with the application's
agent control. The drainer's and the approval service's own durable state and
fail-closed behavior are `docs/pr-drainer.md`'s and `docs/issue-approval.md`'s.

### V-10. Retired 2026-10-20: autonomy is bounded and capacity is respected

Retired by the same removal (request `kan-strip-20261020`): the ceiling, the
per-pass transition limit and the provider-limit wait it described belonged to
the removed runner. The usage panel still shows provider usage, so the owner can
spend spare capacity deliberately before a window resets (design.md §14).

## Workflow bundles and setup

### V-11. Workflows are tracked, tested programs with one source

A workflow command or skill is a program an agent executes. Each one lives in a
tracked plugin bundle and is generated from one authored source where several
providers share it. It changes only with a regression assertion and the bundle
version bump that lets installed caches notice. Personal, untracked copies are
retired, not maintained alongside.

- Rationale: the 2026-08 workflow audit found that distribution (six drifting
  copies of each workflow) was the pipeline's systemic weakness, not its design.
- Authority: CLAUDE.md "Quality gates"; workflow_command_vendoring_design.md;
  external_workflow_authoring_design.md; agent-workflow-contract.md §3–§6.

### V-12. The user wins over the conventions

The pipeline's conventions (labels, origin markers, review routing, round
budgets, default models) are defaults, not law. When what the user wants
conflicts with a convention, the user wins. Kanban adapts through configuration
instead of requiring the user to adopt the owner's workflow. An explicit instruction from the user in the moment overrides a
workflow's default behavior, within the hard limits of V-6 and V-8.

- Authority: owner, 2026-10-01 ("the user always wins, and conventions must be
  superseded by what the user wants").

### V-13. Retired 2026-10-20: arbitrary provider setups, configured in settings

Retired by the same removal (request `kan-strip-20261020`): the settings roster
and screen it relied on, and the dual, single-agent and no-agent operating modes
in the application, are gone. The skills' and scripts' own reading of
`models.toml` is `docs/designs/model_settings_design.md`'s surviving slice.

## Engineering and platform

### V-14. Contracts are authoritative, warning-clean and tested

`docs/design.md` and the agent-workflow contract describe the behavior, and a
behavior change updates them in the same pull request. Where a contract can be
checked mechanically (a key table, a classification, a dependency manifest), a
test holds the code to it. Builds are warning-clean under `-Werror`. Tests need
no terminal, network or GitHub account: they are pure tests, golden Brick
frames, temporary Git repositories, and fake `gh`, `codex` and `claude` on a
temporary `PATH`.

- Authority: CLAUDE.md "The contract" and "Quality gates"; design.md §18; the
  owner's global delivery rule (code and its documentation ship in one PR).

### V-15. macOS and Linux are both first-class

Both platforms are supported, with one service-manager boundary driving launchd
on macOS and systemd user units on Linux. A platform difference lives behind a
seam, not in scattered conditionals.

- Authority: linux_portability_design.md; `tools/service_manager.py`; CLAUDE.md
  source layout.

## State of the direction

**Qualified implementation** (built and proven): the board, trackers and usage
panel, and, tracked beside them, the PR drainer, the issue approval service and
the workflow bundles. design.md §19 "Implementation state" is the detailed
record.

**Planned mechanisms** (accepted, slow-paced, and not a defect for not existing
yet):

- Multi-repository boards, one session with a tab per repository
  (multi_repo_boards_design.md). Overturning the single-repo non-goal was
  approved there as D-4, but design.md §3 and §20 still state the old position
  until MRB-3 amends them.
- The remaining arcs under `docs/designs/` marked `ready for issue processing`.

**Deliberate deferrals and non-goals:**

- No web UI, GUI or webhook server, and no automatic polling (V-2).
- No drag-and-drop or direct board editing. Label and assignment changes from
  the board are deferred (design.md §20).
- Non-GitHub forges are deferred.
- Agents merging (V-6).

## Continuing after a context reset

Read this file, then `docs/guide/CURSOR.md` (the last guide fix, once guide has
run), then CLAUDE.md. The cursor names open findings and pending proposals; the
reports beside it are the record. Principle IDs are permanent: retire a
principle by marking it retired, and never renumber.
