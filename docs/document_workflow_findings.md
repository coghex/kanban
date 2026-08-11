# Direct-master coordination document workflow findings

## Purpose

This report audits the workflow for creating Markdown design and findings documents, processing them into GitHub tracker artifacts one item at a time, and publishing their durable status directly to `master` without disrupting the pull-request drainer.

The desired workflow is:

1. Draft or refine a durable Markdown document.
2. Publish coordination documents directly to `master`.
3. Process one epic, issue, or report concern at a time.
4. Record each approved disposition in the document before moving on.
5. Allow the PR drainer to continue merging and fast-forwarding `master` without manual stash recovery, repeated branch updates, or lost document state.

## Methodology

The audit inspected:

- The owner-local `design-epic`, `process-design-doc`, `draft-report`, and
  `process-report` skill contracts.
- Kanban's PR drainer, queue scheduler, run lock, fast-forward/autostash tests,
  plugin inventories, workflow contracts, and GitHub Actions configuration.
- Kanban's current branch-protection settings and the already-documented issue
  204 queue-serialization change; no broad GitHub duplicate search was run.
- Synarchy as a consuming repository: its GitHub Actions and review gate,
  current document status, branches, history, and drainer-created stashes.
- Machine-audited documentation contracts in both repositories.

GitHub duplicate searches were deliberately not performed. Duplicate detection and final issue disposition belong to `process-report`.

Transient queue state was not treated as a finding. During the initial Synarchy
audit the drainer was running, local `master` matched `origin/master`, and no
active drainer incident was present. Unrelated worktree, stale-ref, and
merged-branch housekeeping was also left outside this report.

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition. A cross-repository issue qualifies the marker as
`[#N, owner/repo]`.

## Status

### Durability and transaction boundaries

- [x] DW-1. Coordination-document mutations stop at the local worktree — [#237]
- [x] DW-2. Document editing and drainer fast-forwarding share an uncoordinated checkout — [#223]
- [ ] DW-3. Tracker mutations and ledger publication are not one recoverable transaction — [deferred]: precondition met by #229, ready to process

### Cursor integrity and ownership

- [x] DW-4. Recovery stashes contain stranded report cursor updates — [#1195, coghex/synarchy]
- [x] DW-5. Processors and implementation PRs both own the same report state — [#1196, coghex/synarchy]

### Pull-request and CI coupling

- [x] DW-6. Coordination-only base commits interrupt the active merge lane — [#224]
- [x] DW-7. Coordination-only master pushes trigger the full build and test workflow — [no-issue]

### Policy and migration

- [x] DW-8. The direct-master policy does not distinguish coordination documents from code contracts — [#225]
- [x] DW-9. Synarchy document artifacts are stranded outside canonical master state — [#1197, coghex/synarchy]

### Workflow ownership and routing

- [ ] DW-10. Coordination-document workflows infer ownership from the current checkout — [deferred]: precondition met by #229, ready to process
- [x] DW-11. The design and report workflows remain untracked personal assets — [#229]

### Review safety

- [x] DW-12. Branch-update completion is mistaken for approval to restore a stale review — [#230]

---

## Chapter 1: Durability and transaction boundaries

### [#237] DW-1. Coordination-document mutations stop at the local worktree

#### Observation

The new design workflow establishes Markdown documents as durable cursors, but its persistence boundary is the local checkout rather than published `master`.

`design-epic` directs the model to use `apply_patch` for document edits. `process-design-doc` similarly updates the local status ledger after an approved tracker action. Both skills prohibit committing or pushing unless the user separately requests it.

This makes the workflow resumable only while the same local file state remains intact. A fresh session, another machine, a drainer reset, or another process reading `origin/master` may see an older cursor.

#### Evidence

- `/Users/vincentcoghlan/.codex/skills/design-epic/SKILL.md:65` requires `apply_patch` for document edits.
- The same skill’s operating boundaries allow changes to the design document but provide no publication step.
- `/Users/vincentcoghlan/.codex/skills/process-design-doc/SKILL.md:225-246` updates the epic and then applies the approved disposition to the local design document.
- `/Users/vincentcoghlan/.codex/skills/process-design-doc/SKILL.md:265-266` says not to commit or push unless separately requested.
- `draft-report` and `process-report` use the same local-document pattern; `process-report` also forbids an automatic commit or push.

#### Impact

The document is described as the durable source of truth, but approved decisions can remain private, dirty worktree state. Subsequent processing can repeat work, overlook already-created issues, or resume from a stale checklist.

The user must also remember an additional publication command after every approved step, undermining the intended seamless one-at-a-time workflow.

#### Expected direction

An approved coordination-document mutation should reach canonical `master` as part of the document workflow, without requiring a separate remembered instruction.

Draft refinement may still involve multiple local edits, but any checkpoint presented as durable or resumable must define when it becomes published state.

#### Constraints and handoff context

- Preserve one-item-at-a-time approval.
- Do not batch issue creation merely to reduce publication frequency.
- Publication failures must remain visible and recoverable.
- The workflow must not silently claim durability when only a dirty local file exists.

### [#223] DW-2. Document editing and drainer fast-forwarding share an uncoordinated checkout

#### Observation

Document skills edit the primary checkout directly while the drainer also
mutates that checkout to fast-forward `master`.

The drainer can relocate untracked files, snapshot tracked changes, hard-reset the checkout, fast-forward it, and then restore the prior local state. The document skills do not participate in a shared coordination mechanism around that sequence.

The drainer has an exclusive lifetime lock that correctly excludes other
drainer runs. Ordinary document edits do not acquire or observe that lock, so
its recovery logic still treats document work as incidental dirty state rather
than as another authorized writer to `master`.

#### Evidence

- `tools/drain_prs.py:1846-1873` relocates untracked files into a private
  `.git/autostash-*` holding directory.
- `tools/drain_prs.py:1891-1921` refuses to overwrite an untracked path if the
  fast-forward introduced a file at the same location.
- `tools/drain_prs.py:2212-2268` fetches and attempts `git merge --ff-only`; on
  failure it snapshots tracked changes, anchors the snapshot, runs a hard
  reset, retries the fast-forward, and restores local changes.
- `tools/drain_prs.py:3245-3296` takes `.git/drain_prs.lock` and a flock on
  `.git` for a drainer's lifetime, but that protocol only covers callers of
  `acquire_lock`.
- `docs/pr-drainer.md:334-351` documents the lock as exclusion between polling,
  single-PR, and dry-run drainer modes.
- `tools/test_fast_forward_stash.py:175-212` verifies staged, unstaged, and
  untracked restoration.
- The document skills edit files directly with `apply_patch` and contain no corresponding drainer coordination protocol.

#### Impact

A document edit can occur while the drainer is snapshotting or restoring the checkout. Even when data remains recoverable, the visible file can be temporarily displaced, restored into a conflict, or left in a holding area rather than at its canonical path.

This creates a race between two individually reasonable workflows.

#### Expected direction

Document publication and drainer checkout mutation must be isolated or serialized so that neither process mistakes the other’s in-progress work for incidental dirt.

The resulting contract should define which component owns the checkout at each mutation boundary and what the other component observes while publication is underway.

#### Remaining uncertainty

The appropriate mechanism—such as a shared short-lived lock, an isolated worktree, or publication that avoids the drainer checkout—requires design work. The finding establishes the missing coordination contract rather than selecting that implementation.

### [deferred] DW-3. Tracker mutations and ledger publication are not one recoverable transaction

> **Deferred:** The reconciliation step belongs to `process-design-doc`, which
> existed only at `~/.codex/skills/process-design-doc/SKILL.md`, and unlike DW-2
> this finding had no kanban-owned counterpart in the tracked tree — so no
> reviewable PR could carry it. Clears on the same precondition as DW-1: the
> four document workflows tracked as plugin assets.
>
> **Precondition met.** #229 (PR #231) landed them as rows in
> `docs/document-workflow-contract.md` §2 — a dedicated contract, not
> `docs/drafting-workflow-contract.md` §2 as this note originally predicted —
> with files present under `codex-plugin/plugins/kanban/skills/` and
> `claude-plugin/plugins/kanban/commands/`. Verify those rows and files, then
> process this finding normally.

#### Observation

`process-design-doc` performs externally visible GitHub mutations before updating the local design ledger.

If tracker creation or epic editing succeeds but the subsequent document update or publication fails, the GitHub artifact exists while the durable cursor still says it has not been created. The partial-failure guidance records the issue number locally “if possible,” but the workflow has no published journal or deterministic reconciliation step.

#### Evidence

- `/Users/vincentcoghlan/.codex/skills/process-design-doc/SKILL.md:225-246` performs the approved GitHub disposition and then updates the local ledger.
- `/Users/vincentcoghlan/.codex/skills/process-design-doc/SKILL.md:248-251` handles partial failure by attempting to record the created issue number locally.
- The same skill does not publish that recovery record to `master`.
- Its normal duplicate check occurs before creation, but the document can still remain stale after a successful external mutation.

#### Impact

Retrying from the stale document can propose or create a duplicate epic or child issue. Avoiding duplication then depends on reconstructing prior conversation state or manually searching for the artifact created during the failed invocation.

The risk is highest precisely where the workflow is meant to help: resumptions in a fresh, smaller context.

#### Expected direction

A fresh invocation must be able to recognize and reconcile “tracker mutation succeeded, document checkpoint failed” without relying on the prior chat.

The approved tracker number and its relationship to the design slice must become a recoverable, idempotent checkpoint before processing advances.

#### Constraints and handoff context

- GitHub and Git cannot provide a literal cross-system atomic transaction.
- The workflow therefore needs explicit partial-state detection and reconciliation.
- Recovery must not guess that a similarly titled issue is the intended artifact without verifying identity and scope.

---

## Chapter 2: Cursor integrity and ownership

### [#1195, coghex/synarchy] DW-4. Recovery stashes contain stranded report cursor updates

#### Observation

The Synarchy repository contains concrete evidence that direct
report-processing state was stranded by drainer restoration conflicts.

Three recovery stashes contain only `docs/code_health_findings.md`. The newest stashed version records dispositions through CH-134, while the current tracked report has regressed to an older checklist state for many of those concerns.

A prior reconciliation commit explicitly says report edits had been stranded when a drainer autostash restore conflicted.

#### Evidence

`git -C ../synarchy stash list` reports three drainer autostash entries:

- 2026-08-06: `drain-prs-autostash-1786060782-92383` (`66fca8b6...`)
- 2026-08-05: `drain-prs-autostash-1785946819-94556` (`b5448266...`)
- 2026-08-03: `drain-prs-autostash-1785777692-49478` (`3279dac4...`)

`git -C ../synarchy stash show --name-status` shows that all three entries
affect only:

- `docs/code_health_findings.md`

Comparing the latest stashed file with the current tracked file shows:

- The stashed checklist contains dispositions through CH-134.
- CH-133 is linked to issue 1161 in the stashed version.
- CH-134 is marked as requiring no issue in the stashed version.
- The current tracked checklist leaves much of the later sequence unchecked.

Commit `6153963e` records CH dispositions and states that the edits were stranded when the drainer autostash restore conflicted on the report.

The current Kanban implementation makes this state recoverable but still
manual: `tools/drain_prs.py:2129-2165` stores a failed tracked restore in the
stash list and raises, while `tools/test_fast_forward_stash.py:320-343`
verifies that a conflicting restore leaves both a recovery stash and a private
anchor.

#### Impact

The report’s cursor is no longer trustworthy as the sole record of which findings have been processed. Some work exists only in recovery stashes, while implementation commits have independently updated selected report sections.

Continuing from the current checklist risks reprocessing completed findings or losing prior disposition reasoning.

#### Expected direction

The existing report and recovery stashes need a deliberate reconciliation that establishes one verified canonical state.

The reconciliation should prove, concern by concern, that no approved disposition, issue link, or explanatory annotation was lost or duplicated.

#### Constraints and handoff context

- The latest stash must not be applied wholesale without comparison; later implementation commits have also changed the report.
- Recovery stashes should remain intact until reconciliation is verified.
- This is both a one-time data repair and evidence for the systemic publication findings above.

### [#1196, coghex/synarchy] DW-5. Processors and implementation PRs both own the same report state

#### Observation

The findings report is mutated through two independent lanes:

1. `process-report` updates checklist entries, headings, and disposition annotations.
2. Solver implementation PRs update the same report when resolving findings.

This gives both the direct-master processor and ordinary PR branches ownership of overlapping Markdown regions.

#### Evidence

Recent implementation commits that modified `docs/code_health_findings.md` include:

- `82607204`, which updated the CH-126 resolution while implementing Unicode-safe display wrapping.
- `89b015d3`, which updated CH-73.
- `29748160` and other implementation commits that also changed report content.

At the same time, the recovery stashes contain processor-side checklist and heading updates to the same file.

`../synarchy/.github/workflows/review-gate.yml` treats a base update that
overlaps PR-owned files differently from an unrelated base update, so these
overlapping edits are operationally significant rather than merely textual.

#### Impact

Even with safe direct-master publication, an implementation PR based on an older report can overwrite, conflict with, or invalidate newer processor cursor state.

The same concern may consequently have a current narrative but stale checklist, or a current checklist but overwritten disposition annotation.

#### Expected direction

Coordination-document fields need an explicit ownership contract.

Processor-owned cursor and disposition state must not be silently replaced by implementation PRs. If implementation PRs continue to update resolution narratives, those updates must compose safely with the processor-owned ledger.

#### Remaining uncertainty

The report format may need to distinguish machine-like workflow state from implementation-maintained narrative, but the exact representation should be decided during issue design.

---

## Chapter 3: Pull-request and CI coupling

### [#224] DW-6. Coordination-only base commits interrupt the active merge lane

#### Observation

Every direct coordination-document push to `master` advances the base commit
of the pull request currently occupying the drainer's active merge lane.

Kanban now serializes the polling queue around one active candidate, so the
older queue-wide update fan-out described by issue 204 is fixed. The narrower
coupling remains: strict branch protection makes the active candidate
`BEHIND`; the drainer updates that branch, holds the lane, and waits for its
replacement checks before it can merge.

This happens even when the new base commit changes only a coordination document
that is unrelated to the pull request.

#### Evidence

- Current Kanban branch protection has strict up-to-date checks enabled and
  requires `build-test` and `review-approved`.
- `tools/drain_prs.py:2922-2944` requests GitHub's branch update whenever the
  active PR reports `mergeStateStatus == "BEHIND"`; that update is the entire
  action for the pass and merging waits.
- `tools/drain_prs.py:3355-3415` gives a branch update or pending checks the
  active lane and prevents later candidates from advancing until it releases
  the lane.
- `tools/test_integration.py:2777-2827` verifies that a branch update holds the
  lane through later passes and that a newly eligible lower-numbered PR cannot
  preempt it.
- Kanban issue 204, closed by PR 214, replaced fair queue rotation with this
  serialized active-lane behavior; the current code no longer supports the
  original queue-wide fan-out claim.

#### Impact

Publishing a small checklist change can still turn the candidate closest to
merge into a branch-update-and-CI cycle. Repeated one-at-a-time publication can
repeatedly move the base between that candidate's review, checks, and merge.

The active-lane fix bounds the immediate effect to one candidate, but it does
not make coordination-only checkpoints invisible to the merge pipeline.

#### Expected direction

Coordination-only base advances should not restart an otherwise ready active
candidate when the base change cannot affect that candidate's result.

Any path-aware behavior must conservatively handle overlap and must not weaken required review or build guarantees for code and machine-enforced contract changes.

#### Constraints and handoff context

- The desired one-item-at-a-time workflow may produce frequent small checkpoints.
- Simply batching all findings into one commit would undermine the durable-cursor goal.
- Preserve issue 204's active-lane serialization; do not reintroduce queue-wide
  branch updates.
- Administrative bypass exists, but relying on broad bypass for routine automation would need a narrowly defined safety contract.

#### Remaining uncertainty

GitHub's strict up-to-date requirement is repository-wide rather than
path-aware. The audit establishes the remaining coupling but does not select
whether publication cadence, merge policy, or a narrower validation mechanism
should absorb it.

### [no-issue] DW-7. Coordination-only master pushes trigger the full build and test workflow

> **Disposition:** No issue — the trigger is as described (`.github/workflows/ci.yml:3-7`
> has no path filter), but the cost is negligible and a docs-only exception would be
> harmful here. Both repositories are public, so Actions minutes are unmetered; master
> runs take ~9-10 minutes and `concurrency.cancel-in-progress` collapses rapid
> checkpoints. `tools/test_source_distribution.py:84-104` requires every tracked file,
> documents included, to be declared as a release asset or a deliberate exclusion, so
> adding or renaming any document is a contract change — a `paths-ignore: docs/**`
> filter would have suppressed the genuine `build-test` failure this verification found
> on master at 282ceeb.

#### Observation

Kanban's primary CI workflow runs on every push to `master` without a
coordination-document-only exception.

A direct checklist or design-document checkpoint therefore invokes the same top-level workflow as a source change.

#### Evidence

- `.github/workflows/ci.yml:3-7` triggers on every push to `master`, every pull
  request, and manual dispatch; it has no path filter.
- `.github/workflows/ci.yml:17-50` runs package checks, Cabal update, the full
  build, all Haskell tests, and every Python drainer test for that push.
- `.github/workflows/ci.yml:12-14` cancels an in-progress run for the same ref,
  which limits duplicate master runs but can replace one checkpoint's run with
  the next when document commits arrive quickly.

#### Impact

Frequent processing checkpoints consume CI capacity and can obscure the validation signal of nearby implementation merges.

The cost discourages publishing after every approved disposition, pushing users back toward dirty local state or large batches.

#### Expected direction

Coordination-document-only master commits should receive validation proportionate to their risk, while documentation that participates in executable contracts must retain its required audits and code-adjacent validation.

#### Remaining uncertainty

The audit did not quantify runner cost or organization-wide queue contention. The unnecessary trigger is structurally present even if current runner capacity makes its immediate impact tolerable.

---

## Chapter 4: Policy and migration

### [#225] DW-8. The direct-master policy does not distinguish coordination documents from code contracts

> **Source note:** “I think all docs should be straight to master.”

#### Observation

The desired direct-master policy is appropriate for workflow coordination documents such as designs, findings reports, and their status ledgers. It is unsafe as a blanket rule for every file under `docs/`.

Kanban itself contains documentation that is both authoritative behavior
contract and machine-parsed workflow inventory. Synarchy has additional
machine-audited documentation contracts. Updating either class independently
of corresponding implementation changes would create invalid intermediate
states or weaken review atomicity.

#### Evidence

Kanban examples include:

- `CLAUDE.md:22-27` requires behavior changes to stay consistent with
  `docs/design.md` in the same PR and declares
  `docs/agent-workflow-contract.md` authoritative for workflow dependencies and
  durable state.
- `docs/drafting-workflow-contract.md:29-47` contains a machine-readable,
  exhaustive asset inventory parsed by
  `tools/test_drafting_workflow_contract.py`.
- `docs/agent-workflow-contract.md:553-601` contains the machine-readable
  dependency manifest reconciled by `tools/test_agent_workflow_contract.py`.

Synarchy consumer examples include:

- `../synarchy/docs/persistence_state_inventory.md`, guarded by
  `../synarchy/tools/persistence_inventory_audit.py`.
- `../synarchy/docs/engineenv_capability_inventory.md`, guarded by
  `../synarchy/tools/engine_env_capability_audit.py`.
- `../synarchy/docs/save_compat/manifest.json`, guarded by
  `../synarchy/tools/save_compat_audit.py`.

#### Impact

Without a documented classification, an automated direct-master publisher cannot tell whether a Markdown change is:

- Workflow state that should bypass the PR lane.
- A code contract that must land atomically with implementation.
- General documentation whose ownership depends on the change.

A broad “all docs” rule could make master temporarily inconsistent or allow contract changes to bypass code review.

#### Expected direction

Define an explicit, reviewable ownership policy for document families.

At minimum, the policy should distinguish:

- Coordination documents and durable workflow ledgers eligible for direct-master publication.
- Machine-enforced or implementation-coupled contracts that remain PR-atomic with code.
- Documents requiring an explicit decision because they do not fit either category.

#### Constraints and handoff context

- Classification should be based on responsibility, not merely file extension or the `docs/` directory.
- An allowlist or equally auditable policy is safer than assuming every Markdown file is coordination-only.
- The publishing workflow must fail closed for unknown document classes.

### [#1197, coghex/synarchy] DW-9. Synarchy document artifacts are stranded outside canonical master state

#### Observation

Several Synarchy document artifacts do not currently satisfy the desired
direct-master policy.

Two findings documents are untracked in the primary checkout. A substantial portable-loot-container design exists on a dedicated remote branch that is not merged into `master` and has no pull request.

These artifacts are not discoverable as canonical documents from a clean checkout of `master`.

#### Evidence

`git -C ../synarchy status --short -- docs` reports:

- `docs/bugs.md`
- `docs/save_load_findings.md`

as untracked files.

Synarchy branch `agent/portable-loot-container-design` exists locally and
remotely. Its single commit, `5f15da0c` (`Document portable loot container
design`), adds approximately 778 lines in:

- `docs/portable_loot_containers.md`

The branch is not merged into `master` and has no pull request.

#### Impact

A new session or collaborator working from `master` cannot reliably discover or continue these documents. Work may be duplicated, forgotten, or processed from an obsolete copy.

The stranded design branch also demonstrates that the intended direct-master convention is not yet encoded in the workflow.

#### Expected direction

Review each stranded artifact and either publish it into the canonical coordination-document location, migrate it into the new format, or deliberately retire it.

No unreviewed document should be deleted merely because it is untracked or stranded on a branch.

#### Constraints and handoff context

- Inspect content and current relevance before publication.
- Reconcile against any newer design or findings documents.
- Preserve authorship and useful history where practical.
- This may resolve as migration work rather than a standalone product issue, subject to `process-report` disposition.

---

## Chapter 5: Workflow ownership and routing

### [deferred] DW-10. Coordination-document workflows infer ownership from the current checkout

> **Deferred:** The four workflows were untracked personal files, so no
> reviewable PR could add an ownership-resolution step. Clears when DW-11's
> vendoring lands: `design-epic`, `process-design-doc`, `draft-report`, and
> `process-report` tracked as plugin assets.
>
> **Precondition met.** #229 (PR #231) landed them as rows in
> `docs/document-workflow-contract.md` §2 — a dedicated contract, not
> `docs/drafting-workflow-contract.md` §2 as this note originally predicted —
> with files present under `codex-plugin/plugins/kanban/skills/` and
> `claude-plugin/plugins/kanban/commands/`. Verify those rows and files, then
> process this finding normally.
>
> One consideration survives into that run rather than blocking it: the durable
> source for the ownership declaration is still unchosen (see this finding's
> Remaining uncertainty). §7 of `docs/agent-workflow-contract.md`, the
> machine-checked document classification #225 landed, is now a candidate it
> did not have at audit time.

#### Observation

The document workflows resolve an omitted path inside the checkout where the
session happens to be running. The processing workflows likewise resolve the
document relative to the current working directory and use unscoped `gh issue`
commands against that repository. None establishes which branch will receive a
future publication.

That heuristic is reasonable for a product-specific design or findings report,
but it cannot distinguish those documents from workflow-system audits that the
user owns in Kanban. This report demonstrated the gap: its first approved copy
was created under Synarchy solely because that was the active checkout, and had
to be moved after the user noticed the ownership error.

#### Evidence

- `/Users/vincentcoghlan/.codex/skills/draft-report/SKILL.md:27-33` defaults an
  omitted path to `docs/<subject>_findings.md` in the current repository; it has
  no owning-repository classification.
- `/Users/vincentcoghlan/.codex/skills/design-epic/SKILL.md:25-30` applies the
  same current-repository rule to `*_design.md` documents.
- `/Users/vincentcoghlan/.codex/skills/process-report/SKILL.md:89-93` resolves
  the report relative to the working directory, while its tracker searches and
  creation commands use `gh issue` without an explicit repository.
- `/Users/vincentcoghlan/.codex/skills/process-design-doc/SKILL.md:51-56`
  resolves designs relative to the working directory and later uses the same
  repository for tracker mutations.
- `tools/drain_prs.py:430-490` shows the stronger repository-identity pattern
  Kanban already uses for irreversible workflow actions: resolve the checkout's
  repository and default branch, and refuse a conflicting explicit identity.
- During this audit, `docs/document_workflow_findings.md` was moved from
  `../synarchy` to Kanban after the inferred target proved wrong.
- At that point the Kanban checkout was on
  `agent/preserve-standalone-pr-rereviews`, not `master`; the correct repository
  path alone therefore still did not identify a safe direct-master publication
  target.

#### Impact

A workflow report can land in a consuming product repository and later file
its issues in that product's tracker even when the workflow implementation and
drainer belong to Kanban. The inverse is also possible: a product design run
from Kanban could create its durable cursor and tracker artifacts in the
workflow repository.

Moving the Markdown file afterward does not repair tracker mutations that were
already sent to the wrong repository. Committing from the right repository but
the wrong current branch would strand the cursor on a feature branch or mix it
into an unrelated pull request.

#### Expected direction

Document creation and processing should establish an explicit owning
repository and publication branch before the first durable write or tracker
mutation. Product designs and product findings should remain with their
product; audits and contracts for the shared workflow system should resolve to
Kanban.

#### Constraints and handoff context

- An explicit user-supplied path or repository remains authoritative after
  validation.
- Repository routing and direct-master-versus-PR classification are separate
  decisions: selecting the right repository does not establish the right
  publication lane.
- Tracker commands must bind to the resolved owner rather than relying on the
  shell's current directory.
- Direct-master publication must not switch, reset, or commit through an
  unrelated feature worktree merely because that checkout supplied the path.
- Cross-repository evidence is valid and must not be mistaken for ownership.

#### Remaining uncertainty

The audit does not establish whether ownership should be declared in document
frontmatter, skill configuration, a Kanban registry, or another durable source.

### [#229] DW-11. The design and report workflows remain untracked personal assets

#### Observation

Kanban's existing workflow contract explains why user-invoked drafting assets
were vendored from personal files into the repository: tracked assets are
reviewable, testable, portable, and installable. The new design/report workflow
does not receive that treatment.

`design-epic`, `process-design-doc`, `draft-report`, and `process-report` live
only under the owner's personal Codex skills directory. They are absent from
Kanban's Codex and Claude plugin inventories, and Kanban's current contract
explicitly treats the older `/epic` workflow as unpackaged.

#### Evidence

- `docs/drafting-workflow-contract.md:5-11` states that owner-local workflow
  contracts could not be changed or verified by repository pull requests and
  that vendoring makes them reviewable, testable, and portable.
- `docs/drafting-workflow-contract.md:29-47` declares the packaged drafting
  assets exhaustively; none of the four design/report workflows is listed.
- `docs/drafting-workflow-contract.md:117-125` explicitly says the existing
  `/epic` workflow is deliberately not packaged.
- `tools/test_drafting_workflow_contract.py:34-53` limits the machine-enforced
  drafting inventory to `issue`, `draft-issues`, `autoissue`, and
  `issue-review` assets.
- The tracked Codex plugin contains no `design-epic`, `process-design-doc`,
  `draft-report`, or `process-report` skill directory, and the tracked Claude
  plugin contains no corresponding commands.
- The live implementations used by this report are under
  `/Users/vincentcoghlan/.codex/skills/`, outside Kanban's Git history and
  plugin installation path.

#### Impact

The workflow that is supposed to create durable, portable project state is
itself neither durable nor portable through Kanban. A personal edit can change
publication semantics without review, another machine can install an older or
missing workflow, and the Codex and Claude variants can drift without a parity
gate.

This also prevents the direct-master publisher, repository routing, and partial
transaction recovery from being tested alongside the drainer they must
coordinate with.

#### Expected direction

Kanban should own the design/report workflow contracts and their installable
assets, with a machine-checked inventory and focused tests covering shared
status markers, repository routing, publication, and recovery boundaries.

#### Constraints and handoff context

- Preserve the one-artifact-per-invocation and explicit-signoff contracts.
- Preserve interoperability between Codex and Claude report status formats.
- Installation must not silently overwrite newer owner edits without a
  declared migration path.
- If any workflow remains intentionally external, Kanban's dependency contract
  should name that ownership explicitly rather than leaving a personal path as
  the implicit source of truth.

#### Remaining uncertainty

The desired Claude-side names and whether all four workflows ship in both
brands need an explicit product decision. The current shared marker contract
suggests parity for processing even if drafting experiences differ.

---

## Chapter 6: Review safety

### [#230] DW-12. Branch-update completion is mistaken for approval to restore a stale review

#### Observation

Kanban's branch-update path waits for the `dismiss-stale-approval` job to
complete successfully, then re-adds `reviewed:approve` whenever the workflow
removed it.

A successful workflow run means only that the invalidation policy finished. It
does not mean the new PR head was approved. In Kanban's own review workflow,
every synchronize event removes the approval label; in Synarchy's path-aware
workflow, removal is the negative decision when the base update overlaps
PR-owned files. The drainer currently undoes either decision.

#### Evidence

- `.github/workflows/review-gate.yml:26-39` runs on a synchronized approved PR
  and unconditionally removes `reviewed:approve`; it emits no positive
  content-safe verdict.
- `tools/drain_prs.py:1096-1128` treats successful completion of
  `dismiss-stale-approval` as the point when the branch-update policy has
  settled and returns the refreshed PR.
- `tools/drain_prs.py:1131-1163` re-adds `reviewed:approve` whenever that
  refreshed PR no longer has the label.
- `tools/drain_prs.py:1673-1705` applies a stricter rule during stale-head
  recovery: it trusts the workflow only when the check succeeded and the label
  remained attached, explicitly describing that conjunction as the
  content-safe case.
- `tools/test_single_pr_drain.py:459-490` and
  `tools/test_integration.py:2777-2810` cover branch-update completion with an
  approved label still present; no focused test covers a successful policy run
  that deliberately removed the label.
- A non-mutating audit probe replaced the settled policy response with a PR
  carrying no approval label; `update_branch` emitted the
  `gh pr edit --add-label reviewed:approve` command, confirming the static
  control-flow reading.
- `../synarchy/.github/workflows/review-gate.yml` distinguishes safe base-only
  updates from updates overlapping PR-owned files, so its removed-label result
  carries information that the generic drainer must preserve.

#### Impact

A branch-forward update that changes the reviewed composition of a pull
request can regain `reviewed:approve` without a fresh canonical review. The
drainer then records the new head as approved and may merge it once the build
checks pass.

This weakens the review gate precisely at the direct-master integration point
the document workflow will exercise frequently.

#### Expected direction

The drainer must preserve a settled negative invalidation decision. It may
carry approval to a new branch-forward head only when the repository's policy
positively identifies that update as content-safe for the reviewed pull
request.

#### Constraints and handoff context

- Do not infer content safety from workflow success alone.
- Preserve approval for genuinely base-only, non-overlapping updates so the
  active lane does not require unnecessary rereviews.
- Keep the approved head, label, review marker, and policy-check result bound to
  the same final head across races.
- Repository review workflows differ; a generic drainer must fail closed when
  the repository exposes no positive content-safe signal.

#### Remaining uncertainty

No unsafe merge was reproduced during this audit. The defect is established by
the current control flow and the missing removed-label test case.
