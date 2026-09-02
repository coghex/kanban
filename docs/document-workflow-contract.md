# Kanban design and report document workflow contract

## 1. Purpose and scope

This document is the canonical responsibility matrix for the packaged
design-document and findings-report workflows the Kanban plugins ship. Before
these assets were tracked, they existed only in an owner-maintained personal
command/skill collection, so a repository pull request could neither change nor
verify them — the same gap issue #118 closed for the drafting and issue-review
contracts. Vendoring them here makes each contract reviewable, testable, and
portable to any project that installs a Kanban plugin.

Scope boundaries:

- These workflows are **user-invoked and never spawned by Kanban's CLI**.
  Kanban's Haskell code spawns exactly five workflows per brand (`solve`,
  `pr-review`, `pr-rereview`, `pr-revise`, and `repair`), so every asset
  declared in §2 is deliberately excluded from the Haskell invocation-parity
  pinning in `tools/test_claude_plugin.py` and `tools/test_codex_plugin.py`,
  exactly as the drafting assets are. See
  [agent-workflow-contract.md](agent-workflow-contract.md) for the workflows
  Kanban does invoke by name.
- This document covers the design-document and findings-report lifecycle only.
  The issue-drafting and canonical issue-review workflows keep their own matrix
  in [drafting-workflow-contract.md](drafting-workflow-contract.md); nothing
  here redeclares them.
- Each brand's asset is vendored as that brand's own text. Brand-specific
  wording may differ, and the five cross-brand pairs are deliberately not
  reconciled into one file each. What may not differ is the shared status
  vocabulary in §4 and the processing boundaries in §5.

## 2. Declared assets

Machine-readable; parsed verbatim by
`tools/test_document_workflow_contract.py`. Columns:
`brand | invocation | path`.

```text
claude | /design-epic | claude-plugin/plugins/kanban/commands/design-epic.md
claude | /process-design-doc | claude-plugin/plugins/kanban/commands/process-design-doc.md
claude | /draft-report | claude-plugin/plugins/kanban/commands/draft-report.md
claude | /note-problem | claude-plugin/plugins/kanban/commands/note-problem.md
claude | /process-report | claude-plugin/plugins/kanban/commands/process-report.md
codex | $design-epic | codex-plugin/plugins/kanban/skills/design-epic/SKILL.md
codex | $process-design-doc | codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md
codex | $draft-report | codex-plugin/plugins/kanban/skills/draft-report/SKILL.md
codex | $note-problem | codex-plugin/plugins/kanban/skills/note-problem/SKILL.md
codex | $process-report | codex-plugin/plugins/kanban/skills/process-report/SKILL.md
```

The list above is exhaustive. A design or report document workflow that exists
in either plugin without a row here fails the completeness check in §7, and so
does a row whose path is missing from the tracked tree.

## 3. Responsibility matrix

| Workflow | Brands | Produces | Creates tracker items? | Durable cursor |
| --- | --- | --- | --- | --- |
| `/design-epic`, `$design-epic` | Claude and Codex | One `*_design.md` document | No — never | The document's `Design state` and processing ledger |
| `/process-design-doc`, `$process-design-doc` | Claude and Codex | One approved epic or child disposition per run | Yes, after per-artifact signoff | The design document's `## Processing status` ledger |
| `/draft-report`, `$draft-report` | Claude and Codex | One `*_findings.md` report | No — never | The report it creates, with every box unchecked |
| `/note-problem`, `$note-problem` | Claude and Codex | One verified observation appended to an existing report | No — never | The report it appends to, with the new box unchecked |
| `/process-report`, `$process-report` | Claude and Codex | One approved finding disposition per run | Yes, after per-finding signoff | The report's status checklist and heading markers |

### 3.1 Design capture: `/design-epic` and `$design-epic`

`/design-epic` and `$design-epic` maintain one Markdown document as the source
of truth for an
epic-sized design: verified current state, decisions with stable `D-N`
identifiers, open questions with stable `Q-N` identifiers, and
dependency-ordered delivery slices. Each modifies only that document. Neither
creates GitHub issues, labels, or comments, and neither drafts a final issue
body — tracker work belongs to `/process-design-doc` and `$process-design-doc`.

The document is only handed on once the user explicitly says so and the
readiness conditions hold, at which point its state becomes exactly
`Design state: ready for issue processing`.

### 3.2 Design processing: `/process-design-doc` and `$process-design-doc`

`/process-design-doc` and `$process-design-doc` turn a ready design document
into tracker artifacts, one
per invocation, using the document as the durable cursor: the epic first, then
one dependency-ready child. Each requires the ready state, and returns a
document whose ledger and delivery plan disagree to its own brand's
design-capture workflow rather than guessing which representation wins.

### 3.3 Report drafting: `/draft-report` and `$draft-report`

`/draft-report` and `$draft-report` turn free-form notes or an audit request
into one
evidence-backed findings report, present the complete draft, and create the
file only after explicit approval. Neither files an issue or chooses a
disposition; every status box either writes is unchecked.

Together with `/note-problem` and `$note-problem` in §3.7 these are the report
**write side**: one starts a report, the other grows an existing one. Both are
cross-brand pairs, so §4's status vocabulary is a hard compatibility surface
across the whole write side: a report produced or extended by either brand's
write-side asset is processable by the other brand's `process-report` without
translation.

### 3.4 Report processing: `/process-report` and `$process-report`

`/process-report` and `$process-report` process exactly one finding per
invocation from an existing report, treating that report as the durable cursor
so a fresh session resumes at the correct place without conversation history.
Each verifies the finding against the current repository, deduplicates it
against the tracker, recommends exactly one disposition, and applies it only
after explicit approval.

These two are one of the five cross-brand pairs in this contract, so §4's
status vocabulary is a hard compatibility surface between them: a report started
by one brand must be resumable by the other without translation.

An Epic disposition reached through `/process-report` hands the user to the
Claude `/design-epic` and `/process-design-doc` commands, and one reached
through `$process-report` to Codex's `$design-epic` and `$process-design-doc`.
Neither variant may name a nonexistent counterpart in the other brand's sigil or
depend on owner-maintained personal copies.

### 3.5 Declared Codex-only asymmetry, now closed

**The Codex-only set is empty.** Every workflow this contract declares is a
cross-brand pair. This section stays as the closure record and the standing
rule, because the rule is what governs the next asset somebody proposes, and
deleting the history would leave that rule looking arbitrary.

**The standing rule.** A Claude counterpart is not authored from scratch. Doing
so would be new behavior that no pinned source defines, which is precisely what
the SHA-pinned vendoring model of issue #118 refused to do. So a workflow
existing in one brand alone is a declared gap rather than an oversight, and the
other brand's plugin must not grow a counterpart under this contract until a
reviewed, pinned source exists to transpose from. That clearing condition is
what each entry below records as satisfied.

**The closure record.** Each workflow that left the Codex-only set, with the
pinned source that cleared it:

| Workflow | Left the set | Pinned source that satisfied the clearing condition |
| --- | --- | --- |
| `design-epic` | Issue #241 | `codex-plugin/plugins/kanban/skills/design-epic/SKILL.md`, after issue #239 landed its decision-authority guardrails in the tracked text |
| `process-design-doc` | Issue #241 | `codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md`, cleared by #239 the same way |
| `draft-report` | Issue #328 | `codex-plugin/plugins/kanban/skills/draft-report/SKILL.md`, the reviewed tracked skill issue #239 strengthened |

In each case the Claude command is that source's text under Claude command
frontmatter, `$ARGUMENTS` plumbing, Claude tool names, and Claude origin
markers; nothing else about any of them is new behavior.

`note-problem` never appeared in this set. It entered the contract in issue #328
as a pair in both bundles at once, vendored from a reviewed personal source
under the same pinning rule rather than transposed out of an existing tracked
asset.

The asymmetry that remains in the packaged workflows is the Claude-only
`/draft-issues` boundary in
[drafting-workflow-contract.md §3.2](drafting-workflow-contract.md#32-claude-only-breadth-draft-issues),
which is that contract's to record and runs opposite to the ones closed here.

### 3.6 The epic planner: the design pair with the processing pair

`/design-epic` and `$design-epic` produce a durable design document and create
no tracker items;
`/process-design-doc` and `$process-design-doc` — not the capture pair — are
what later turn an approved
slice into an issue. Together they are the arc-decomposition pipeline: an
`epic` asset that would decompose a user-supplied arc into issues directly
remains unpackaged in both plugins per
[drafting-workflow-contract.md §3.5](drafting-workflow-contract.md#35-not-a-candidate-hunting-workflow-arc-decomposition),
and the personal `/epic` command that once did so was retired 2026-08-11 in
this pipeline's favor. The design workflow settles behavior, scope, decisions,
and slice boundaries without touching the tracker.

### 3.7 Observation capture: `/note-problem` and `$note-problem`

`/note-problem` and `$note-problem` append exactly one verified observation to
an existing findings report: they preserve the user's wording as a claim,
investigate only that claim against the current repository, classify the result,
and record concise evidence and handoff context under the report's existing
key pattern and concern chapters. Each stops for explicit approval before
touching the report, and each stops after one observation.

They are the write side's second half (§3.3) and the fifth cross-brand pair, so
§4's status vocabulary binds them as hard as it binds `process-report`: an
observation either brand appends is processable by the other brand's
`process-report` without translation. Every checklist line they write is
unchecked, because an observation just captured is unprocessed by definition.

Two things separate them from the drafting assets they sit beside, and both
follow from their subject being a document that already exists:

- **They publish.** A report they append to may already be classified
  `coordination`, and an appended observation left in one checkout is a cursor
  only that checkout can resume. So they take §8's ownership resolution and §9's
  same-run publication exactly as the processing assets do, rather than §9.1's
  novel-document rule.
- **They create no report.** A path holding no report is `draft-report`'s to
  draft and create; `note-problem` stops and says so. That boundary is forced by
  §9.4's only-writer rule rather than chosen: a document absent from the
  working copy is one the module declines to *create* as well as to publish,
  so an asset that promised to create the report would leave the user with none
  and the approved observation reachable only as a preserved blob. Writing it
  directly instead would contradict the only-writer rule and leave a document
  the next publication refuses as not matching the tip. A report `draft-report`
  created but no pull request has enrolled is in the same position, and these
  assets report that outcome rather than describing the observation as captured.
- **They acquire no tracker transaction.** They create, link, label, and comment
  on nothing, so §9.6's rule that a disposition mutating no tracker acquires no
  transaction covers them outright. A record acquired here would be one nothing
  could ever resolve.

They apply no disposition. `[#N]`, `[no-issue]`, and `[deferred]` remain
`process-report`'s alone, and an observation these workflows capture is
unprocessed work the report still owes.

## 4. Shared status vocabulary

Every declared asset states the same marker vocabulary, given here as exact
literals because the markers are the interface between two runs, two brands,
and two sessions:

- `[#N]` — linked to tracker item N, newly created or already existing;
  terminal.
- `[no-issue]` — reviewed and deliberately never to be filed; terminal.
- `[deferred]` — real work blocked on a concrete, checkable precondition;
  non-terminal.
- No marker — unprocessed.

The at-a-glance index is a Markdown task list, one line per entry, using
exactly `- [x]` for a terminal disposition and `- [ ]` for anything still
outstanding. `[deferred]` and unmarked entries stay `- [ ]`, so the count of
unchecked boxes is the count of entries a document still owes. `/design-epic`,
`$design-epic`, `/draft-report`, `$draft-report`, `/note-problem`, and
`$note-problem` write only the unchecked form: none of them
applies a disposition, so a checked box in a document they just produced would
be a bug.

`[no-issue]` and `[deferred]` are not interchangeable: the first closes an
entry, the second keeps it open behind a stated precondition. "Needs more
thought", "low priority", and "revisit later" are not preconditions.

Every cross-brand pair must state these literals identically — `/process-report`
with `$process-report`, `/design-epic` with `$design-epic`,
`/process-design-doc` with `$process-design-doc`, `/draft-report` with
`$draft-report`, and `/note-problem` with `$note-problem`. That is what makes a
report or
a design document portable between the brands, and it is the part of each pair's
otherwise-permitted textual divergence that this contract does not allow.

## 5. One artifact per invocation, and the approval stop

Two boundaries are common to every declared asset:

- **One artifact per invocation.** A processing run selects, drafts, and
  applies exactly one tracker artifact or disposition, then stops; the next
  entry advances only on a later explicit invocation. A broad instruction such
  as "process the whole report" does not waive it.
- **Stop for explicit approval.** No run creates a file, an issue, a label, or
  a comment, or marks a document, before the user approves that exact artifact.
  Revising a draft does not carry an earlier approval forward: the complete
  revised artifact is presented again and the run stops again.

Both are the reason these workflows are user-invoked (§1): each one has a
mandatory human stop in the middle, so nothing here is safe for Kanban's CLI to
spawn unattended.

### 5.1 Decision authority in the design workflows

`/design-epic`, `$design-epic`, `/process-design-doc`, and
`$process-design-doc` carry a third boundary the report
workflows do not, because a design conversation settles behavior long before
there is an artifact to approve: the user owns every design decision. All four
assets state that the session is human-led, that agent-authored directions are
Proposals and never Decisions, that a `D-N` decision entry changes only on
explicit user approval of that exact choice, that a serious decision gets its
own signoff checkpoint covering only clearly enumerated decisions, and that
silence, continued conversation, an approved document edit, or a request for
revisions is never that signoff. Ambiguity about intent or about a serious
design dimension — behavior, scope, ownership, compatibility, migration,
persistence, determinism, delivery order, issue boundaries, or verification —
stops for user input rather than being classified as minor to keep moving.
Questions are batched at most three at a time, which paces the asking without
licensing a guess.

This is the design-conversation half of the boundary above: §5 governs the
external mutation, §5.1 governs the choice that mutation encodes. The report
workflows are unaffected — both `draft-report` variants, both `note-problem`
variants, and both `process-report` variants keep exactly the two boundaries of
§5.

## 6. Project-scoped locations

The declared assets in §2 live inside each plugin's own tracked tree, exactly
as the drafting assets do:

- Claude commands: `claude-plugin/plugins/kanban/commands/`, discovered through
  the `"commands": "./commands/"` declaration in
  `claude-plugin/plugins/kanban/.claude-plugin/plugin.json`.
- Codex skills: `codex-plugin/plugins/kanban/skills/<name>/SKILL.md`,
  discovered per-directory through the `"skills": "./skills/"` declaration in
  `codex-plugin/plugins/kanban/.codex-plugin/plugin.json`.

Both are picked up by file placement alone — adding a workflow needs no
manifest schema change.

## 7. Completeness check

`tools/test_document_workflow_contract.py` (discovered by
`python3 -m unittest discover -s tools -p 'test_*.py'`, which CI already runs)
parses §2 and fails if:

- a declared asset path is absent from the tracked tree;
- a design or report document workflow exists under either plugin that §2 does
  not declare — which requires `note-problem` to be a member of the
  document-workflow **name** set and not only of the row list above, since a
  workflow file present in a bundle is compared against that name set to decide
  whether a declared row was owed for it;
- a declared row's brand, invocation sigil, or workflow name disagrees with the
  plugin and file the row points at;
- a cross-brand pair declares fewer than its two actual files;
- the Codex-only set of §3.5 becomes non-empty, or this document stops stating
  that section's standing rule and closure record, the design-pipeline
  epic-planner boundary (§3.6), the observation-capture boundary (§3.7), or the
  Haskell invocation-parity exclusion (§1);
- this document or a declared asset drops one of the exact `[#N]`,
  `[no-issue]`, or `[deferred]` literals of §4, or an asset that applies a
  disposition drops a checklist form — which is how the surface the two brands
  must keep identical is held identical;
- this document drops the one-artifact-per-invocation or
  stop-for-explicit-approval boundary of §5, or either `process-report` variant
  stops stating both;
- this document stops stating the design-workflow decision-authority boundary
  (§5.1), or any of the four design assets — `/design-epic`, `$design-epic`,
  `/process-design-doc`, `$process-design-doc` — drops one of the authority
  clauses that boundary summarizes, or `/design-epic` or `$design-epic`
  reintroduces the permissive leave-lesser-uncertainty instruction issue #239
  removed; this is the design pair's counterpart to the §5
  check above, and the reason §5.1's semantics cannot regress in the assets
  while the document still describes them;
- a declared asset drops one of the ownership-resolution clauses of §8, or
  reintroduces the unscoped docs-worktree fallback §8 replaced;
- this document drops §8's resolution order, its fail-closed rule, its
  separation of repository routing from the publication lane, or its statement
  that `docs/agent-workflow-contract.md` §7 classifies Kanban paths only;
- a `gh` invocation in any declared asset stops binding to the resolved owner —
  the check that keeps the ten tracker operations in `/process-report`,
  `$process-report`, `/process-design-doc`, and `$process-design-doc` from
  reverting to the unscoped form that binds them to the shell's current
  directory;
- a publishing asset — the four processing assets or either `note-problem`
  variant — loses its §9 publication step, or stops resolving
  `tools/publish_coordination_doc.py` from the owning repository's own write
  root;
- a publishing asset carries any part of the publication sequence itself rather
  than invoking that module, or writes the document instead of handing over its
  approved content;
- a drafting asset stops stating that a novel document remains local until it is
  separately classified and published, or either `note-problem` variant is
  reclassified into that rule instead of the same-run publication rule its
  existing-document subject requires;
- this document drops §9's `pr-atomic` fail-closed rule, its one-artifact
  boundary, or its rule that publication is reported only on reachability;
- a publishing asset drops §9.5's reporting rule — the silence on the ordinary
  outcome, the exact conjunction that silence covers, the full report every
  other outcome keeps, or the fact that silence ends the report rather than the
  run — or a processing asset lets that silence reach §9.6's local resolution
  and strand the record it was supposed to clear. The four drafting assets are
  the negative control for the first, and they and the two `note-problem`
  variants together are the control for the second, so a check broad enough to
  match every asset fails rather than passing while asserting nothing;
- a processing asset drops the §9.6 tracker-transaction clause for any one of
  its tracker-mutating branches — `EPIC` label creation, epic creation, epic
  adoption edit, child issue creation, child issue linking, an approved
  comment, or an umbrella-epic checklist edit — since a single record-step
  phrase somewhere in a file proves nothing about the branch that skipped it;
- a processing asset carries any part of the transaction mechanism itself
  rather than invoking `tools/tracker_transaction.py`, or a drafting asset or
  `note-problem` variant invokes it at all;
- either `process-design-doc` variant reintroduces the instruction to write
  partial-failure recovery information into the document, which contradicts the
  publication module being that document's only writer;
- this document drops §9.6's create-only acquisition, its repository-wide
  visibility, its state machine, its per-step checkpoints, its rule that
  clearing is bound to the published entry rather than to reachability, its
  manual ambiguity reconciliation, its no-transaction rule for dispositions that
  mutate nothing, or its fail-closed rule; or §9.5 stops requiring tracker state
  beside its three document states;
- this document drops one of §10's substantive clauses — the two-part trigger,
  §4's definition of terminal that trigger rests on, the arc document's
  retention of its apparatus, the arc document's definition by role rather than
  by path, the specification host's loss of it, the relocation of content that
  outlives the arc, the repair of every stranded reference inside and outside
  the host document, the deletion of historical bookkeeping a released artifact
  already holds, or the ordinary-issue ownership of the removal — each pinned
  on its own, since a section that still mentions the apparatus somewhere
  proves nothing about the clause that left; or
- either `process-design-doc` variant drops the completion-report clause §10.4
  requires: naming the rule, giving the specification host and the arc document
  their opposite outcomes, stating the disposition conditionally on the
  umbrella epic's closure, and leaving the removal to separate follow-up work
  it does not perform. The other eight
  declared assets are the negative control for that clause, so a check broad
  enough to match every asset — or narrow enough to match none — fails rather
  than passing while asserting nothing.

The mechanism's own behavior is not this module's subject:
`tools/test_publish_coordination_doc.py` executes it against temporary
repositories, and `tools/test_document_classification.py` owns §7's rows and the
`coghex/kanban` drainer-only `workflow.coordination_paths` example that
independently mirrors them for base-advance coverage.

Discovery, frontmatter, and no-personal-path coverage for these assets lives
with the rest of each plugin's structural coverage in
`tools/test_claude_plugin.py` and `tools/test_codex_plugin.py`, and their
external-command surface is reconciled against the §4 dependency manifest of
[agent-workflow-contract.md](agent-workflow-contract.md#4-dependency-manifest)
by `tools/test_agent_workflow_contract.py`.

## 8. Owning repository and publication target

Every declared asset writes a durable document and, for the four processing
assets, mutates a tracker. Neither action is reversible in the wrong
repository: moving a Markdown file afterward does not undo an issue already
filed somewhere it does not belong. So each asset resolves an explicit owner
before its first durable write and before its first tracker mutation, rather
than inheriting whichever checkout the session happened to start in.

This is not hypothetical. `docs/document_workflow_findings.md` — an audit of
Kanban's own workflow system — was first created under a different repository
solely because that was the active checkout, and at that moment the Kanban
checkout was on a feature branch, so naming the right repository still would
not have identified a safe publication target.

### 8.1 What gets resolved

Three values, all required together:

- `$DOC_REPO` — the owning repository as an explicit `owner/repo` slug. It
  scopes every `gh` command the workflow runs.
- `$DOC_BRANCH` — that repository's default branch, which is the publication
  target. It is never assumed to be the current checkout's branch.
- `$DOC_ROOT` — a validated local checkout of `$DOC_REPO`, under which every
  document read and write resolves, including the `$DOCS_WT` docs-worktree
  lookup. A slug alone names no place to write, so binding the first two
  without the third would leave the wrong-repository failure in place.

### 8.2 Resolution order

Two tiers, and the first tier that matches wins:

a. **Explicit input** — a repository or a document path the user supplied,
   after validation. First-match-wins applies between tiers, not between
   explicit inputs: when the user names both a repository and a path, both must
   validate and resolve to the same repository. Conflicting explicit inputs are
   unresolved, not a preference to rank.
b. **A §7 row** — for a document path that is Git-tracked in the checkout
   holding it, coverage by exactly one row of
   [agent-workflow-contract.md §7](agent-workflow-contract.md#7-document-publication-classification)
   declares the document Kanban-owned. Coverage means the tracked path matches
   exactly one row, whether an exact file row or a component-aware directory
   row; no row, more than one row, or an untracked path resolves nothing.

Anything else leaves the owner unresolved.

### 8.3 The fail-closed rule

An unresolved owner creates no file, edits no document, and issues no `gh`
mutation. The workflow reports which of the three values it could not determine
and asks the user for the owning repository, and for a local path as well when
no checkout of it is available. A failed or ambiguous default-branch resolution
fails closed identically — falling back to the current branch would contradict
§8.1 exactly as falling back to the active checkout would.

A new document that no §7 row covers is the expected case for tier (b), not an
error condition: it resolves nothing, and the workflow asks.

Reading code, tests, or history from another repository as evidence stays
allowed, and is never an ownership signal.

### 8.4 Routing is not the publication lane

Resolving `$DOC_REPO` and `$DOC_BRANCH` answers *where* a document and its
tracker items belong. Whether that document then publishes as `coordination` or
`pr-atomic` is the separate question
[agent-workflow-contract.md §7](agent-workflow-contract.md#7-document-publication-classification)
answers about an already-routed document. The two decisions share a source
table but are not the same decision, and the lane is never a substitute for
resolving the owner.

That §7 table is Kanban's own: it describes this repository and nothing else,
so it can identify Kanban as an owner and can never identify a consuming
repository's. A consuming repository resolves its documents through tier (a).

## 9. Publishing an approved coordination mutation

§8 answers *where* a document belongs. This section answers what happens to an
approved mutation once it has been applied there. These workflows present their
Markdown files as durable cursors a fresh session can resume, but a cursor that
only ever exists in one checkout is resumable only from that checkout. So a
document whose resolved path takes the `coordination` lane is published in the
same run that mutates it, rather than left for a later manual commit.

### 9.1 Which assets publish, and which do not

- The four **processing** assets — `/process-report`, `$process-report`,
  `/process-design-doc`, and `$process-design-doc` — publish the approved
  document mutation during the same invocation that applies it, whenever the
  document is eligible under §9.2. These are the assets that publish, and no
  other asset does. **Every tracker-mutating branch of those four publishes
  this way, the design pair's `EPIC` path included**: that path renders the
  complete approved document and hands it to
  `tools/publish_coordination_doc.py` in the same run, and never writes or
  stages the document itself. A path that edited the document directly would
  contradict §9.4's rule that the module is the document's only writer, and the
  document it left behind would be refused as no longer matching the
  publication tip.
- The two **observation-capture** assets — `/note-problem` and `$note-problem` —
  publish the same way and under the same §9.2 eligibility, because their
  subject is a report that already exists and may already be classified
  `coordination`. They differ from the four above in one respect only: they
  mutate no tracker, so they acquire no §9.6 transaction and have no tracker
  identities to carry into publication. Everything else in this section applies
  to them unchanged, the rule that the module is the document's only writer
  included.
- The four **drafting** assets — `/design-epic`, `$design-epic`,
  `/draft-report`, and `$draft-report` — publish nothing at all. A document one
  of them newly creates is local and unpublished. Its first publication requires
  a separate pull request that adds both the document and its `coordination`
  classification; only after that pull request lands may a later processing run
  publish direct-to-`master` mutations to it. Automating that enrollment pull
  request is outside this contract.

The split follows from §7 rather than from convenience: the classifier's subject
inventory is `git ls-files '*.md'`, so a document a drafting asset just created
is not yet tracked, matches no row, and is therefore `pr-atomic`. There is no
moment at which a novel document is directly publishable.

`note-problem` sits on the publishing side because its subject is the opposite
case: a report that already exists and may already be classified
`coordination`. Classifying it as a drafting asset would leave an appended
observation on such a report permanently unpublished, which is the exact
one-checkout-cursor failure this section exists to prevent. The same split is
why it creates nothing: the module never creates an absent document — it
writes a document that is not on the tip only over the working copy the run's
own preflight observed (§9.4) — so creating one stays entirely with the
drafting assets, which write their own file precisely because they publish
nothing.

### 9.2 Eligibility, and the fail-closed default

Eligibility means exactly one thing: the resolved document's
repository-relative path is declared a coordination path by the authority for
its owner —
[agent-workflow-contract.md §7](agent-workflow-contract.md#7-document-publication-classification)
for `coghex/kanban`, and that repository's own `workflow.direct_publication_paths`
for every other owner, as the rest of this section sets out. **A path its own
authority does not declare is never published directly** — `pr-atomic` is the
fail-closed default for an unmatched path, so an unrecognized document is left
unpublished rather than guessed into the direct lane.

§8's ownership resolution is a prerequisite, not a parallel check: a document
whose owning repository or publication branch could not be verified fails closed
and stays unpublished.

§7 is Kanban's own statement about Kanban, so it authorizes a `coordination`
lane for `coghex/kanban` and for no other repository — a fork included. Every
other owner declares its own lane in `workflow.direct_publication_paths`:
case-sensitive,
repository-relative declarations — an exact file path, or a directory ending
in `/` covering every descendant by whole path component, so `docs/notes/`
declares `docs/notes/plan.md` and never a similarly prefixed sibling such as
`docs/notes-old/plan.md` — read through the same resolved
configuration layer as the drainer's separate `workflow.coordination_paths`,
with the same global-then-repository merge, the same array replacement, and
the same coverage predicate. Publication reads only
`direct_publication_paths`; `tools/drain_prs.py` reads only
`coordination_paths`, and neither declaration grants the other's permission.
The two roots never mix in either direction. Kanban's own eligibility is
decided from §7 as the publication tip
itself carries it and never from configuration, so it holds whether or not an
operator ever copied `config.toml.example`; every other repository's is decided
from its own declaration alone, so nothing here infers a lane from a file
extension or from a directory nothing declared — coverage exists only where a
declaration names it, exactly or through a declared directory's descendants. A
declaration whose directory prefix is empty — a bare `/`, which would cover
every path — is invalid configuration rather than a broad lane: it fails
closed before anything is written or published, like configuration that cannot
be read.

**A repository that declares nothing has no lane, and that is an ordinary
outcome rather than an error.** The approved mutation is preserved in the object
database and applied to the document itself whenever the working tree carries
something the module may write over — the publication tip's own content, or
the unlanded mutation the module itself last applied — and the run reports
`"status": "not-published"` with `document_written` true, exactly what a
`pr-atomic` document of Kanban's own reports and for the same reason. Because
that lane is a repository's ordinary state rather than an exception, one
document takes disposition after disposition before any of them lands, which is
what §9.4's write outcomes are for. Such a repository lands the document
through the pull-request lane it already has; nothing is vendored into it, and
it tracks no copy of the mechanism. Configuration that exists but cannot be read
or is invalid is not an absent declaration: it fails closed before anything is
written or published, because a lane silently read as absent would leave a
document its owner really did declare publishable sitting in one checkout.

**An ordinary outcome is reported as one.** Because a repository without a lane
is the common case rather than the exception, §9.5 has the declared assets close
on it without narrating it: the approved mutation is applied and recorded, the
run reports its own disposition or capture, and the absent lane, the write root
and the preserved blob are not recited to the user on every pass. What is
ordinary here is the configuration, so what the run says about it is nothing.

### 9.3 What a publication may contain

A publication carries the single approved mutation to the one eligible document
and nothing else. It must not carry unrelated dirty paths, earlier `docs-wip`
commits, unrelated changes already present in the same document, or a second
disposition or document mutation. Publication happens after each individually
approved disposition and is never batched or deferred merely to reduce commit or
push frequency, so §5's one-artifact boundary is untouched: an approved
publication is the same artifact's last step, never a licence to sweep in a
second.

### 9.4 The mechanism lives in one tested module

`tools/publish_coordination_doc.py` is the whole mechanism, and the declared
assets invoke it rather than restating it. That division is deliberate and is
the subject of issue #315: the mechanism was first written as shell inside the
four processing assets, where twelve review rounds found twenty defects — lost
updates, checks that gated nothing, a variable used before it was assigned — and
nothing in the tree could execute the sequence to find them. Two properties
follow from it being a module:

- the sequence is one process holding one lock, rather than a chain a reader can
  reorder or half-apply; and
- every safety property below is a test in
  `tools/test_publish_coordination_doc.py` that performs a real publication
  against a temporary repository, so a regression fails `build-test` rather than
  waiting for a reviewer to notice.

The assets keep the policy this document states — eligibility is required,
approval precedes publication, one artifact per invocation, and what to report
on each outcome — and hold no part of the sequence. This contract states the
same division: what follows is the module's contract, not a transcript of its
steps.

**The mechanism ships with the assets that invoke it.** `tools/` holds the
source, and a byte-identical copy of it ships inside each tracked plugin bundle,
so every declared asset resolves the copy in its own bundle:
`${CLAUDE_PLUGIN_ROOT}/scripts/` for the Claude commands, and the `$CODEX_HOME`
plugin cache for the Codex skills, which have no such substitution and locate
their bundle's copy the way the PR-flow skills locate `review_pr.py`. That is
the level issue #229 stopped one short of and issue #370 closed: these plugins
exist to operate on other repositories, and an asset that resolved the module
from the repository it was operating on was inert in every repository but this
one. `$DOC_ROOT` remains the validated checkout of the owning repository — where
the module *writes* — and is never where the module is found. What stays
forbidden is what that rule was always protecting against: the session's own
checkout, a personal path, and an inline reimplementation. So does shipping part
of the set, because the publication and transaction modules load each other from
beside themselves and the publication module loads the configuration reader from
beside itself — a bundle carrying one carries all three or none.
`tools/test_document_workflow_contract.py` holds the copies byte-identical to
their source, holds every asset's lookup to a bundled one, and drives each
brand's lookup against a simulated install, while
`tools/test_consuming_repository_documents.py` runs all six assets' own lookups
and the helpers they return against a repository that tracks neither `tools/`
nor §7 — which is the only place the defect was ever observable, since the
mechanism and the assets were each correct on their own.

**The caller renders the approved document; the module writes it.** A processing
asset composes the complete approved content and hands it over, and never edits
or stages the document itself. That is what makes an edit somebody else makes
beside the run unpublishable rather than merely unlikely: the published bytes
come from what the caller passed, never from the working tree. The module also
mints the scratch path that content is handed over in, because a path the
callers name is shared state written before any lock is taken: two runs would
overwrite one another's approved content, and one document would publish the
other's. A document with a staged change is refused for the same reason — the
end state the module promises is that the document path is left unstaged, and
an index-only edit is invisible to a check that hashes the file alone. That
refusal applies to every outcome, including those where no publication was
possible: the state the module promises does not depend on whether it could
publish.

**The write root is ordinarily not the publication branch.** The assets write in
the `docs-wip` linked worktree while publication targets the default branch, so
eligibility, the baseline, and resumption are all decided against the publication
tip's own blob for the path, and the module never checks out, resets, switches,
or advances any branch or HEAD in the write root.

**A publication is guaranteed, not hoped for.** The module holds a per-document
lock across the whole sequence — per document meaning exactly that, since a
reference name two documents can share is a lock one of them takes from the
other and a pending record either might resolve; because that name is a digest,
the lock carries in its own payload the repository and document it holds, so a
stale-lock sweep can still see what it is looking at. It releases and clears
only by the exact value it means to remove — two clearers can agree one owner is dead, and an
unconditional delete would let the slower of them remove a live publisher's
lock instead. Every reference it removes follows that rule, the pending record
as much as the lock, and every removal is checked rather than assumed: a record
still standing stops the next run's preflight and a lock still standing blocks
every later run, so a publication that could not remove either reports it
instead of claiming plain success — and reports it on a failed publication as
well, where the original failure keeps priority but the retained lock travels
with it, since a run that was already going to be retried must not be blocked
by a lock nobody was told about. A preflight that cannot refresh the remote
fails rather than issuing a binding from a stale cached ref, which would read as
current while licensing a publication against a document that had already
moved. Every scratch path is minted rather than named, in the
shared Git directory as much as the working tree, because a predictable path is
somebody else's file waiting to be rewritten and deleted. It refuses when the
document does not match the
publication tip before it writes, checking that with the read and the write
adjacent so no subprocess sits in the gap; refuses a commit that changes any
path but the one; never force-pushes and never overwrites a concurrent advance;
treats reachability from the remote branch as the sole definition of published;
and records an unfinished publication so a later run resumes exactly it, or
fails closed when the document or the branch has moved underneath it.

**Nothing an outside process wrote is destroyed to make a publication
possible.** There is no compare-and-swap for file content, and a check followed
by a write can always be raced, so the module does not check and then write. It
captures: the document is moved aside atomically, so whatever occupied that
path — an in-place edit, a wholesale replacement — is carried out of the way
intact rather than clobbered, and is examined only afterwards. Anything that is
not the baseline is preserved in the object database, put back, and the run
fails closed. The new content is then put in place with a primitive that
refuses rather than overwrites, so a file created while the path was briefly
empty wins and is left alone — and putting a captured document *back* follows
the same rule, because a recovery that overwrites is still a write destroyed,
whichever step performs it. The document is absent for that instant; a reader
seeing no file is the price of never destroying somebody else's write.

**A document that publishes nowhere still takes more than one disposition.**
Writing only over the publication tip's own baseline is correct exactly once.
The second approved mutation to a document whose owner lands it out of band
arrives to find the first one unlanded in the working copy, and a decline there
strands the run's tracker transaction where no later run can get past it — the
defect issue #385 was filed for, observed end to end. So the module says which
of five things a write outcome was rather than leaving one boolean to stand for
all of them: the working copy still carried the publication tip's content and
the mutation was applied to it; the working copy was byte-identical to what this
module last applied locally, making it this module's own unlanded write, and the
mutation was applied on top of it; the document is absent from the publication
tip but the working copy still held exactly the bytes the run's own preflight
observed, and the mutation was applied over them; the document is absent from
the tip and the working copy is not that — it moved since the preflight, no
binding was passed, or there is no file at all, which the module never creates —
so nothing was written; or the working copy is none of those, in which case it
is somebody else's and is never overwritten.

The third is issue #605, and for an owner that lands out of band it is the
ordinary case rather than the exotic one: every report is processed before its
first batch landing, so the first disposition of every report arrives at a
document that has never been on the branch. There is no tip blob to guard that
write with, so the guard is the run's own preflight — `--check-pending` reports
the working copy's blob as `working_copy_blob`, the asset passes it back as
`--expected-working-copy`, and the write goes over exactly those bytes or not at
all. That binding guards every write to a document absent from the tip, the
continuation over the module's own recorded predecessor included: a copy that is
both the preflight's blob and the recorded predecessor continues as
`applied-over-local-predecessor`, one that is the preflight's blob alone is
`applied-over-preflight-copy`, and one the run's preflight did not observe is
refused even when the record names it. The record says what the module last
wrote, not what this run decided over; consulted ahead of the binding it would
let a run prepared over an older copy overwrite a newer disposition another run
recorded in between. A novel document is still never published from here
(#237's enrollment-by-pull-request rule stands); only its local write is
licensed.
Which predecessor it is changes nothing else: the replacement is guarded against
the exact bytes the decision was made from, a staged document is still refused,
and a write that lands in between still wins.

**The module's own record is what tells its predecessor from a hand edit.** A
working tree is what a hand edit produces too, so the reference the module
writes — naming the exact content it wrote — is the only thing that separates
them, and it is written only once the write itself succeeded. Only a reference
that reads back naming that exact content counts as recorded: a write the
module could not record is reported as unrecorded, and authorizes neither a
later continuation nor a local transaction resolution, because a record that
does not name the bytes cannot prove them. What it proves is bounded in the
other direction too. It says these bytes are what this module last wrote, and
nothing at all about whether that mutation was ever landed anywhere.

**An applied mutation is not yet a durable one.** It exists in one write root
and on no branch, and what makes it durable is its owner landing the resulting
document on the publication branch, by whatever lane that owner has. That is an
instruction to the run rather than a line of its report: it is why no run
publishes by hand to compensate for a declined lane, why a run never describes
an applied mutation as complete on the branch, and why §9.6's unresolved record
is reported rather than cleared. Where the write root, the document path and the
preserved blob are named — the outcomes §9.5 keeps loud — they are named
because the mutation is not where the next run will look for it.

**Nothing the module does can leave the document deleted.** For the length of
that instant the captured copy is the only one, so its content reaches the
object database before anything else can fail, and every way out of the swap —
including failures the code did not anticipate — puts the document back before
dropping that copy. A restoration never raises and never overwrites: it must
not replace the error that caused it, and it must not become the write that
destroys another — including in its own fallbacks, which recreate the document
exclusively rather than renaming over whatever is there. Where it cannot restore, the captured file is kept rather
than removed, and its path travels with the failure: a file kept somewhere
nobody is told about is only marginally better than one deleted. Content it declines to publish is written to the object database first,
so an edit made outside this protocol is recoverable rather than lost. A
recorded publication that already reached the branch is not cleared while the
write root has diverged from it — checked at the moment of clearing rather than
earlier, and identically however the publication got there, freshly or by
resumption — and a record that has not landed is not overwritten by a fresh
publication. An unresolved record is outstanding work, and it is the only
pointer to the mutation it names — so a run that supplies a *different*
approved mutation while one is outstanding is refused rather than served the
recorded one, which would report success while the disposition just approved
never reached the document. That holds whether or not the record has since
landed: a recorded publication reaching the branch says nothing about a
different mutation supplied afterwards.

**That refusal is askable before the tracker is touched, and the assets ask.**
A processing run mutates the tracker before it publishes, so discovering an
outstanding record at publication time is discovering it after a second issue
already exists for a disposition the document will never receive. The check is
read-only, takes no lock, and is the first step of applying a disposition
rather than the last.

**Approved content is bound to the document state it was rendered from.** That
check cannot hold a lock across the user's approval, so two runs can pass it at
the same moment, each create a tracker item, and each render a whole-file image
of the same document. Whichever publishes second would then overwrite the
first's disposition — invisibly, because it changes exactly the one path a
correct publication changes. So the publication tip the run was rendered
against travels with the content.

**What that binding guards is the document, not the branch.** Publication is
refused when the document's own blob differs between the tip the content was
rendered against and the current one, and the refusal names that document and
asks for the disposition to be rendered again. A document present at one of the
two tips and absent at the other differs, and is refused. An advance that left
the document untouched drops nothing — the rendered image is still a faithful
whole-file image of the current document — so it publishes against the current
tip rather than sending the caller round to produce byte-identical content.
Refusing those would cost exactly the concurrency these workflows encourage: a
busy publication branch advances under every run, and the run that advanced it
was usually working a different document entirely.

**Deciding that requires reading both tips, and a lookup that failed is not an
absence.** A tip that cannot be resolved to a commit, or a tree that cannot be
read, refuses the publication in its own right rather than answering "no blob"
— two failed lookups would otherwise compare equal and read as "the document did
not change", which is the one conclusion this guard exists to prevent. The
refusal reports both tips and the document's blob, or its proven absence, at
each, so the operator sees which document moved without deriving it by hand.

**A binding that is absent is a failure, not a waived check.** Publication
requires it, and an empty one is refused rather than treated as "no tip to
compare" — otherwise a caller that never managed to extract it would publish
with the guard silently switched off, which is indistinguishable from having no
guard at all. The assets are held to extracting it for real rather than to
mentioning the flag, because a binding that expanded to nothing is exactly the
defect this rule exists to have caught.

### 9.5 What "published" means, and the three-state failure report

A run may describe a document as published only when the module reports it, and
the module reports it only when the intended commit is reachable from the remote
publication branch. A push that appeared to succeed is not that verification.

**Every** other outcome is an unpublished failure, reported with all three
states rather than collapsed into one — including the ones the module never
modelled. One result is not among them: a `not-published` whose `write_outcome`
is one of the three applied ones and whose `applied_record` reads `"recorded"` is
§9.2's empty lane working exactly as designed, so it is neither a failure nor
owed the three-state report. A caller branches on the result, so a traceback
where a result belongs leaves it with nothing to report and no way to learn
what became of its document — and being structured is not enough on its own: an
unmodelled failure can happen after the document already holds the approved
bytes, so the states are collected against the resolved write root and say
where that edit is, rather than reporting it as unknown. Every failure that has
a candidate commit names it in the same field, whichever step produced it; and
cleanup, which runs on the way out with a failure often already propagating,
may never raise at all — nor may the reporting that accompanies
it, whose own inputs must be defined on every path that can reach it, since an
exception from either would replace the real error and skip the lock release on
its way past. The states:

- whether the document edit exists locally, and in which worktree and at which
  path;
- whether a local publication commit exists and, if so, its commit ID; and
- whether the remote publication branch contains that commit.

**Tracker state is reported beside those three, never instead of them.** A
document state says what became of the cursor; it says nothing about the issues,
labels, comments, and epic edits the run had already made by then, and those are
the part nobody can undo. So every unpublished failure of a run that acquired a
transaction under §9.6 also reports whether acquisition succeeded, the
transaction state, each planned tracker step and whether it is planned,
ambiguous, or confirmed, every confirmed tracker identity, and the one recovery
action that is permitted next.

**The scope of that report is failure, not the absence of a publication.** The
ordinary recorded `not-published` result is not a failure — it is §9.2's empty
lane working as designed — and §9.6 resolves its transaction from the applied
local document, so nothing is left outstanding and that run closes quietly. What
decides between the two is the resolution rather than the publication: a
transaction that could not resolve is an unpublished failure by this rule
however ordinary the helper's result was, and reports every one of the states
above.

A failed publication leaves the mutation recoverable and never diverges the
checkout's default branch from its remote — the PR drainer fast-forwards that
branch after every merge, and an unpushed local commit on it would wedge every
later pass.

Because the caller hands over the whole document, a successful publication also
reports what it changed: an unintended rewrite of the rest of the document
changes the same single path a correct publication does, so the changed-line
summary, not the changed-path check, is what makes it visible to the run that
caused it.

**The ordinary outcome is reported by saying nothing about it.** A settled
mechanism working as designed is not news, and a run that recited the declined
lane, the write root and the preserved blob after every disposition made a
healthy workflow read like a recurring problem — one session processing three
entries of one design document emitted the whole apparatus three times. So on a
`not-published` with an applied `write_outcome` and a `"recorded"`
`applied_record`, a declared asset closes with its own workflow-specific report
— the processing pair's disposition, document line and counts, the note pair's
captured observation and its handoff fields — and says nothing about
publication, eligibility, lanes, worktrees, write roots, blobs, or what still
has to happen for the edit to land. None of that is a decision the user has to
make.

**Every other outcome keeps its full report, each for its own reason.** A
`write_outcome` of `no-baseline` or `unrecognized-working-copy`, or an
`applied_record` of `"unrecorded"`, is reported in full because the mutation is
not where the next run will look for it. A published one is reported because it
is verified success carrying the changed-line summary above, which the run has
to check. An unmodelled status is reported because its three states are the only
account of where the document went. The silence covers one conjunction and is
never widened to a status, a write outcome, or a record on its own.

**That silence is a rule about the report, not about the work.** The helper is
still invoked, its result still inspected, and §9.6's transaction still resolved
before the run closes. Silence is what a run says at the end, never a step it
skips.

### 9.6 The tracker transaction

§9.5 makes the document half of a disposition recoverable. This section is the
other half, and it is the subject of issue #327. A processing run mutates the
tracker before it publishes, so a run that dies in between leaves an unchanged
document, a clear publication preflight, and one or more tracker mutations that
already happened. The next invocation reads that as unprocessed work and does
them again — and unlike a document edit, an issue already filed cannot be taken
back.

**Every approved tracker mutation is a checkpointed step, and a disposition is
not one operation.** A design `EPIC` disposition can create a label, then create
an epic or edit an adopted one; a child disposition can create or link an issue,
post an approved comment, and edit the umbrella epic's checklist. These return
different things — a label name, an issue number and URL, a comment ID and URL,
a target issue plus a verified post-edit fingerprint — so what a step records is
the identity appropriate to its own kind of mutation, never an assumed issue
number.

**A disposition that mutates no tracker acquires no transaction.** The two
`note-problem` variants mutate no tracker at all and so never acquire one;
`[no-issue]`
and `[deferred]` mutate nothing; neither does an `Existing issue` linked through
`process-report` with no approved comment, which is a document change and not a
tracker one; and neither does `process-report`'s `Epic` disposition: that arc is handed to the design pair, and its epic is created
later inside the design document's own transaction. Acquiring a record for one
of these would leave it outstanding across a separate human-led workflow and
block every other entry in the document.

**Acquisition is atomic and create-only.** The transaction is acquired before
the first tracker mutation of an approved disposition, and acquisition fails
when a record already exists. The read-only preflight cannot hold anything
across the user's approval, so two runs can both observe it clear; what makes
that safe is that only one of them can create the record, and the loser stops
rather than mutating GitHub beside the winner.

**The record is repository-shared, not worktree-local.** `$DOCS_WT` may differ
between invocations, so the record lives where every linked worktree of the
clone sees it, exactly as the pending-publication record of §9.4 does. It is
shared across linked worktrees of one clone rather than across two independent
clones, which is what the guarantee is worth and all it claims.

**The record is what a fresh invocation resumes from.** It carries the owning
repository, the document path, the selected finding, delivery-slice, or `EPIC`
key, the approved disposition kind, the publication tip the disposition was
prepared against, an ordered plan of every approved tracker-side step, and for
each step its exact approved target, payload fingerprint, and observable
postcondition. A session with no conversation history has that and nothing else,
so a field it could omit is a field a resumption could not check.

**The states are durable and explicit.** `intent-only` — the record and its
ordered plan exist and no step is confirmed. `tracker-pending` — at least one
step is confirmed and later planned steps remain. `mutation-confirmed` — every
approved step is confirmed. `publication-pending` — the disposition and its
identities are ready or already handed to publication, which is not yet
verified. `resolved` — the recorded disposition and its exact identities are
verified on the publication branch, and the record is cleared. Each step is
`planned`, `intent`, or `confirmed`: it enters `intent` before its external
mutation begins and records its exact confirmed identity and postcondition
before the next step starts.

**Only the run that performed a mutation may confirm it.** Beginning a step and
confirming it are separate invocations — the mutation happens between them — so
nothing about the process can tell the run that just created an issue from a
fresh session looking at an interrupted one. Beginning a step therefore returns
a token once, to that caller alone, which is not readable from the record;
confirming requires it back. A resuming session has no conversation history and
so cannot produce one, which keeps the ordinary confirmation cheap while forcing
adoption of an interrupted step onto the reconciliation path below, where an
exact artifact must be approved and matched. Losing the token costs a
reconciliation, which is the safe direction to fail.

**A confirmed identity is the one its own kind of mutation has, and it must
agree with itself.** A created issue or epic records its number, its canonical GitHub
URL naming that number *in the owning repository*, and the `[#N]` token the
entry will carry; a label records its name
and the metadata it was created with, both checked against the exact approved
values the plan carries, since a name in prose is nothing a confirmation can be
held to; a comment records its comment ID and a URL naming that comment on the
approved target in the owning repository;
an edit to an existing artifact records that artifact's identity — the
approved target, not merely some artifact — and the verified post-edit
fingerprint. A literal marker, which only a disposition that links an artifact
somebody else made may supply, is bound to that artifact by the plan naming it
outright rather than by inferring it from a step — a linked child issue's only
tracker mutation is often the umbrella epic's checklist edit, which targets the
epic, so there is no step to infer it from. Those agreements are checked rather than
assumed: clearing verifies the document's token, so an identity free to record
one artifact beside another artifact's token would let a record clear against a
document naming something the tracker never got. Nothing but a created issue or
epic contributes a token the document must name.

**Every transition is a compare-and-swap, and confirmations are never erased.**
A failed or interrupted transition leaves the earlier durable value exactly as
it was, and no transition may drop or rewrite a confirmed step's identity or
otherwise authorize repeating a mutation GitHub has already accepted.

**The preflight's report survives the preflight's own failure.** The records are
read before the remote is contacted, and they are what the run has to report: an
unreachable remote that failed without them would tell a caller holding an
outstanding transaction nothing about it, at the one moment it most needs to
know it may not mutate anything.

**The pre-mutation preflight reports both records.** The read-only check of §9.4
answers for the outstanding publication and the outstanding tracker transaction
together, and a run stops before its first irreversible action when either
exists, reporting the document, the selected key, the disposition, the
transaction state, the completed steps, the ambiguous step if there is one, and
the steps that remain. It keeps the caller contract it already had: the same
`clear` and `pending` status vocabulary, and the same publication-tip binding
the assets extract from it.

**A resuming run re-presents and re-approves; it does not replay.** Confirmed
steps are verified and never repeated. Remaining steps resume in their recorded
order, and each one's exact target and payload is presented again and stopped on
for explicit approval before it executes — §5's approval stop has no exception
for a run that found its work in a record rather than in a conversation, and the
recorded payload fingerprint bounds what may be approved rather than substituting
for the approval. A `mutation-confirmed` or `publication-pending` record offers
only the completion of that disposition's document mutation and publication. A
missing, mismatched, or conflicting recorded artifact stops the run instead of
adopting a similarly titled one. And the recorded publication tip is preparation
evidence and mismatch reporting only: a resuming run re-runs the read-only
preflight, re-renders the recorded disposition and recorded identities against
the tip that reports, and binds to that one — passing the recorded tip would
bind the publication to a rendering nobody made against it, and is refused
outright wherever the document itself changed in between.

**An interrupted mutation is ambiguous, and ambiguity is never resolved
automatically.** A step that began and was never confirmed may have landed or
not, and server-side idempotency is out of scope, so nothing may retry, adopt a
candidate, advance, publish, or clear on its own. After read-only verification,
explicit user approval may bind that step to one exact artifact whose
repository, target, immutable identity or URL, approved payload, and observable
postcondition match what was recorded; or may authorize a retry, but only where
authoritative read-only evidence shows the exact intended postcondition is
absent. A missing identity, a payload mismatch, a conflicting state, or more
than one plausible candidate leaves the record unresolved and stops the run. A
similarly titled artifact is never sufficient evidence.

**Clearing is bound to the published entry, not to reachability.** A record
resolves only once the recorded entry key's own **terminal index entry** on the
publication branch carries the recorded disposition and every exact tracker
identity that disposition requires the document to name. A commit reaching the
branch proves a commit landed, not that it carried this disposition. The entry
is the one §4 defines, and it is looked for only in the document's own
at-a-glance index — the design pair's `## Processing status` ledger, the report
pair's `## Status` checklist — because that index is the status source of truth
and a checked task anywhere else is not the cursor: a checklist inside a
finding's body, an example in a fenced block, a nested list beneath the real
entry. Within it the entry is a top-level task-list line marked exactly `- [x]` whose
own key is the recorded one — parsed from the line rather than found in it, so
`DW-3` and `DW-30` are different entries. That is what distinguishes the three
states a search for the key and the number cannot tell apart: an entry still `- [ ]`, which the interrupted run never
marked; an incidental mention in prose, a `Related` pointer, or a code fence;
and a terminal entry carrying `[no-issue]` or `[deferred]` beside the link,
which is a different disposition from the one the record holds. Every
transaction's disposition is a linked one, since the two that mutate no tracker
acquire no transaction. Where the module reports `not-published` with
the approved content applied locally — the ordinary outcome for a `pr-atomic`,
unmatched, or not-yet-tracked document under §9.1 and §9.2 — the same
verification runs against the applied local document, which is the only evidence
there is and a legitimate terminal state for such a document. §9.5's silence
does not reach this step: the local resolution still runs on that outcome, and
only a resolution that succeeds licenses a quiet close. A record this run could
not resolve keeps its full failure and recovery report however ordinary the
publication result was — that report is the one thing the ordinary outcome never
suppresses, because a stranded record is precisely what the next run needs
told. That the document is one of those is *derived* rather than taken from the
caller, and derivation takes two things: the same classification the publication
module itself applies,
and that module's own record of what it applied. Classification says only that
it *would* decline to publish; a document somebody edited by hand looks
identical from there. So the module records the exact content it wrote whenever
it applies a disposition to a document it declined to publish, and a local
resolution verifies the document against that record. A document it never wrote,
or one changed since, resolves nothing. Otherwise: a document that does
have a coordination lane belongs on the branch, and clearing it from a locally
edited cursor would leave the next preflight clear while the entry never landed.
Where the module reports `not-published` without having written the document —
or having written it without being able to record that it did — the record
stays outstanding and the run reports it. That is bounded rather than
terminal, and the bound is named so no state needs a hand-edited reference to
leave: the approved content is recovered from the object database, the
terminal document is reconciled and landed through the owner's ordinary lane,
out of band or by pull request, and the existing record is then resolved from
the branch. No confirmed tracker mutation is repeated and no reference is
cleared by hand while that recovery is pending — the record already carries
every identity the recovered document must name.
Explicitly approved abandonment may clear an
`intent-only` or `tracker-pending` record without publication, but only against
authoritative read-only evidence that none of its unconfirmed mutations landed,
and the run reports every mutation that was already confirmed. Otherwise the
record stays until the document is reconciled and published.

**The mechanism is one tested module, and the assets hold none of it.**
`tools/tracker_transaction.py` owns acquisition, every transition, and the
resolution check, for the same reason `tools/publish_coordination_doc.py` owns
the publication sequence: a sequence written as shell inside a Markdown asset is
a chain a reader can reorder or half-apply, and nothing in the tree can execute
it to find the next defect. `tools/test_tracker_transaction.py` drives it
against temporary Git repositories. The assets keep the policy this section
states — when to acquire, what needs approval, what to report — and invoke the
module.

**It fails closed.** A record that cannot be created, read, or updated stops the
run before its first irreversible action. There is no path on which an
unreadable transaction reads as no transaction.

## 10. The end of an arc: removing the processing apparatus

An arc's **processing apparatus** is the machinery §3.1 and §3.2 add to a
document so the arc can be captured and then processed: the `Design state:`
line and its status legend, `## Processing status`, `## Epic contract`, the
arc's scope section, `## Current state and evidence`, `## Open questions`,
`## Verification strategy`, and `## Delivery plan`.

§3.1 gives the design state machine one transition and no third value, and §5
stops each processing run after one artifact, so no declared asset ever takes
that apparatus back out. This section states what becomes of it once the arc it
served is over, which document kinds that outcome differs between, and who
performs it.

### 10.1 The trigger

The apparatus becomes removable only once both of these hold: the arc's
umbrella epic is closed, and every entry in the document's processing ledger is
terminal.

Terminal is exactly §4's vocabulary — an entry is terminal when it carries
`[#N]` or `[no-issue]`. A `[deferred]` entry and an unmarked entry are both
non-terminal, so a ledger holding either is not all-terminal however close to
finished it looks.

Both conditions are load-bearing because they are observed from different
places. A ledger with no outstanding entry is *processing* completion, readable
from the document alone, and it may precede the umbrella epic's closure by any
amount of time; the epic's closure is readable only from the tracker. Neither
condition implies the other, and neither alone authorizes the removal.

### 10.2 Two document kinds, opposite outcomes

The removal applies to one kind of document and never to the other.

An **arc document** is one whose whole subject is the arc: the document
`/design-epic` or `$design-epic` created and `/process-design-doc` or
`$process-design-doc` processed. An arc document is identified by role rather
than by path. `docs/<subject>_design.md` is its ordinary location, but the
design pair also creates `<subject>_design.md` at the repository root when no
`docs/` directory exists and accepts an explicit Markdown host named in its
arguments, so the path is evidence of the role and never the definition of it.

**An arc document keeps its apparatus**, permanently and in place. There the
apparatus *is* the record: the ledger, the decisions, and the delivery plan are
what the document exists to hold, and a closed arc's document is the durable
account of how that arc was decomposed. Nothing in this section deletes,
truncates, or archives an arc document's ledger, and no reading of it that ends
in an emptied `*_design.md` is the rule this section states.

A **specification document** is one that describes the current state of a
system and merely hosted an arc's apparatus for the arc's duration — it existed
before the arc and outlives it, and its readers consult it for behavior rather
than for history. **A specification document that merely hosted the apparatus
loses it** once §10.1's trigger is satisfied, because from that moment the
apparatus describes finished work to every reader who opens the document for
its actual subject. `docs/design.md` is the case that occurred: epic #268
closed 2026-08-16 and its scaffolding still opened and closed the behavior
contract until issues #428 and #429 removed it by hand five days later.

### 10.3 What is preserved, what is dropped, and what is repaired

**Content that outlives the arc is relocated to the numbered section that owns
it rather than deleted with its wrapper.** The apparatus is a wrapper, not a
container of exclusively disposable text, so removal is a relocation pass first
and a deletion second. Issue #428 moved `docs/design.md`'s implementation-state
paragraph to §19's `### Implementation state`, the 2026-08-12 measurement audit
to §21, and two still-true statements to §18. Issue #429 retained
`## Decisions` as a `### Decisions` subsection of §21, demoted to `####`,
because §21's records cite those decisions 47 times and §14 cites D-2; deleting
it would have orphaned every citation.

**Purely historical bookkeeping already held by `CHANGELOG.md` or the GitHub
Release is dropped rather than relocated.** A second copy of what a released
artifact already records is the part of the apparatus that has no owning
section, and preserving it inside a specification document is how a behavior
contract silently becomes a changelog.

**Every reference the removal would strand — inside the host document and
outside it — is repaired in the same change.** Inside means a cross-reference,
citation, or anchor pointing at a heading that is leaving; outside means any
tracked file that pointed into the apparatus. Issue #428 also repointed
`CLAUDE.md`'s "opening status paragraph" at §19. A removal that leaves a
dangling reference anywhere in the tree is incomplete, not merely untidy.

### 10.4 Who performs the removal

**The removal is separate follow-up work, authorized by an ordinary issue and
delivered through the host document's own publication lane.** In this
repository that lane is the one
[agent-workflow-contract.md §7](agent-workflow-contract.md#7-document-publication-classification)
assigns the host document; in a consuming repository it is that owner's
declared lane under §9.2. The removal is a judged editorial pass over a
document the arc did not own, so it takes the same review a change to that
document ordinarily takes.

**Neither `/process-design-doc` nor `$process-design-doc` removes, rewrites,
files, or publishes it during a one-artifact invocation.** §5's boundary is one
tracker artifact per run, and this removal is neither a tracker artifact nor a
disposition; performing it inside a processing run would rewrite a document the
run never selected.

What those two assets do owe is the *statement*: when either reports an arc's
processing complete, it names this rule so the disposition the host document
then owes is stated at the moment it becomes owed. Because **processing
completion is observed from the ledger alone and may precede the umbrella
epic's closure, the report states the disposition conditionally and never
asserts the removal is already owed** unless that closure has been verified.
