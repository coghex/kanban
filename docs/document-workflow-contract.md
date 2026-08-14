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
  wording may differ, and the three cross-brand pairs are deliberately not
  reconciled into one file each. What may not differ is the shared status
  vocabulary in §4 and the processing boundaries in §5.

## 2. Declared assets

Machine-readable; parsed verbatim by
`tools/test_document_workflow_contract.py`. Columns:
`brand | invocation | path`.

```text
claude | /design-epic | claude-plugin/plugins/kanban/commands/design-epic.md
claude | /process-design-doc | claude-plugin/plugins/kanban/commands/process-design-doc.md
claude | /process-report | claude-plugin/plugins/kanban/commands/process-report.md
codex | $design-epic | codex-plugin/plugins/kanban/skills/design-epic/SKILL.md
codex | $process-design-doc | codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md
codex | $draft-report | codex-plugin/plugins/kanban/skills/draft-report/SKILL.md
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
| `$draft-report` | **Codex only** | One `*_findings.md` report | No — never | The report it creates, with every box unchecked |
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

### 3.3 Report drafting: `$draft-report`

`$draft-report` turns free-form notes or an audit request into one
evidence-backed findings report, presents the complete draft, and creates the
file only after explicit approval. It files no issues and chooses no
dispositions; every status box it writes is unchecked.

### 3.4 Report processing: `/process-report` and `$process-report`

`/process-report` and `$process-report` process exactly one finding per
invocation from an existing report, treating that report as the durable cursor
so a fresh session resumes at the correct place without conversation history.
Each verifies the finding against the current repository, deduplicates it
against the tracker, recommends exactly one disposition, and applies it only
after explicit approval.

These two are one of the three cross-brand pairs in this contract, so §4's
status vocabulary is a hard compatibility surface between them: a report started
by one brand must be resumable by the other without translation.

An Epic disposition reached through `/process-report` hands the user to the
Claude `/design-epic` and `/process-design-doc` commands, and one reached
through `$process-report` to Codex's `$design-epic` and `$process-design-doc`.
Neither variant may name a nonexistent counterpart in the other brand's sigil or
depend on owner-maintained personal copies.

### 3.5 Declared Codex-only asymmetry, partially closed

`$draft-report` is the sole remaining Codex-only workflow. No Claude
counterpart to `$draft-report` exists, and that is a declared gap rather than an
oversight: authoring one would be new behavior that no pinned source defines,
which is precisely what the SHA-pinned vendoring model of issue #118 refused to
do. The Claude plugin must not grow one under this contract until a pinned
source exists to vendor.

`$design-epic` and `$process-design-doc` were Codex-only under the same rule
until issue #239 landed their decision-authority guardrails in the tracked Codex
skills. That reviewed, tracked text — `design-epic/SKILL.md` and
`process-design-doc/SKILL.md` under `codex-plugin/plugins/kanban/skills/` — is
the pinned source `/design-epic` and `/process-design-doc` were transposed
from, so the clearing condition this section states was satisfied for the design
pair and for it alone. The Claude commands are that source's text under Claude
command frontmatter, `$ARGUMENTS` plumbing, Claude tool names, and Claude
origin markers; nothing else about them is new behavior.

The remaining asymmetry runs opposite to the Claude-only `/draft-issues`
boundary in
[drafting-workflow-contract.md §3.2](drafting-workflow-contract.md#32-claude-only-breadth-draft-issues),
and is recorded the same way rather than closed.

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
`$design-epic`, and `$draft-report` write only the unchecked form: none of them
applies a disposition, so a checked box in a document they just produced would
be a bug.

`[no-issue]` and `[deferred]` are not interchangeable: the first closes an
entry, the second keeps it open behind a stated precondition. "Needs more
thought", "low priority", and "revisit later" are not preconditions.

Every cross-brand pair must state these literals identically — `/process-report`
with `$process-report`, `/design-epic` with `$design-epic`, and
`/process-design-doc` with `$process-design-doc`. That is what makes a report or
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
workflows are unaffected — `$draft-report` and both `process-report` variants
keep exactly the two boundaries of §5.

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
  not declare;
- a declared row's brand, invocation sigil, or workflow name disagrees with the
  plugin and file the row points at;
- this document stops stating the remaining Codex-only asymmetry (§3.5), the
  design-pipeline epic-planner boundary (§3.6), or the Haskell
  invocation-parity exclusion (§1);
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
- a processing asset loses its §9 publication contract, or a drafting asset
  stops stating that a novel document remains local until it is separately
  classified and published;
- this document drops §9's `pr-atomic` fail-closed rule for an unmatched path;
- a processing asset or this document drops one of the safety rules §9.3-§9.6
  introduce — the single-approved-mutation isolation rule, the never-force-push
  and never-overwrite-a-concurrent-advance rule, or the rule that a commit is
  verified present on the remote publication branch before anything is called
  published;
- publication weakens the one-artifact boundary of §5, or stops following the
  explicit approval that §5 already requires.

The `coordination`/`pr-atomic` classification itself is not this module's
subject: `tools/test_document_classification.py` owns §7's rows, and the
`coghex/kanban` `workflow.coordination_paths` example that mirrors them is
reconciled there, beside the §7 parser that already exists rather than behind a
second one.

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
approved mutation once it has been applied there. The document workflows present
their Markdown files as durable cursors a fresh session can resume, but a cursor
that only ever exists in one checkout is resumable only from that checkout. So a
document whose resolved path takes the `coordination` lane is published in the
same run that mutates it, rather than left for a later manual commit.

### 9.1 Which assets publish, and which do not

- The four **processing** assets — `/process-report`, `$process-report`,
  `/process-design-doc`, and `$process-design-doc` — publish the approved
  document mutation during the same invocation that applies it, whenever the
  resolved path is eligible under §9.2. These are the assets that publish an
  eligible mutation, and no other asset does.
- The three **drafting** assets — `/design-epic`, `$design-epic`, and
  `$draft-report` — publish nothing at all. A document one of them newly
  creates is local and unpublished. Its first publication requires a separate
  pull request that adds both the document and its `coordination`
  classification; only after that pull request lands may a later processing run
  publish direct-to-`master` mutations to it. Automating that enrollment pull
  request is outside this contract.

The split follows from §7 rather than from convenience: the classifier's subject
inventory is `git ls-files '*.md'`, so a document a drafting asset just created
is not yet tracked, matches no row, and is therefore `pr-atomic`. There is no
moment at which a novel document is directly publishable.

### 9.2 Eligibility, and the fail-closed default

[agent-workflow-contract.md §7](agent-workflow-contract.md#7-document-publication-classification)
is the authoritative classification for Kanban paths, and eligibility means
exactly one thing: the resolved document's repository-relative path is
classified `coordination` there. **A `pr-atomic` path, and a path no row
matches, is never published directly** — `pr-atomic` is the fail-closed default
for an unmatched path, so an unrecognized document is left unpublished rather
than guessed into the direct lane. When a mutation is not direct-publication
eligible, the run leaves the edit in place and recoverable and says why.

A resolved owner is a prerequisite, not a parallel check. §8's `$DOC_REPO`,
`$DOC_BRANCH`, and `$DOC_ROOT` must already be established before eligibility is
even consulted: a document whose owning repository or publication branch could
not be verified fails closed and stays unpublished, exactly as §8.3 requires.

A repository-relative path is not by itself an eligibility signal, because the
same path exists in other repositories and in other states of this one:
`docs/ui-bugs.md` names a `coordination` document here and names whatever a
consuming repository decides it names. Two further conditions therefore hold
before anything is built or pushed.

**The owner must be Kanban itself.** §7 is Kanban's own statement about Kanban,
so `coghex/kanban` is the only repository with a `coordination` lane through
these workflows. A resolved `$DOC_REPO` that is anything else is ineligible, and
that includes a fork and a consuming repository tracking a contract of its own
with a matching row: those documents are somebody else's to publish. This is the
same boundary §8.4 draws for routing, applied to the lane.

**The classification must come from the branch being published to.** The local
checkout is not the authority on it. A dirty, stale, or unmerged `$DOC_ROOT` can
classify a path `coordination` while the publication branch does not, and since
the publication commit is built on that branch rather than on the checkout, a
run trusting the local copy could authorize a direct push the published state
never sanctioned. §7 is therefore read out of the fetched publication tip —
exactly the state being published onto. **A publication branch that carries no
such contract at all has no `coordination` lane**, so nothing is published
there.

### 9.3 What a publication may contain

A publication carries the single approved mutation to the one eligible document
and nothing else. It must not carry unrelated dirty paths, earlier `docs-wip`
commits, unrelated changes already present in the same document, or a second
disposition or document mutation. If the approved mutation cannot be isolated
from other changes, publication fails closed without discarding any work.

That isolation is verified on the publication commit itself before it is
pushed, rather than inferred from how the commit was constructed. Construction
can be raced — two runs in one docs worktree share that worktree's Git
directory, so any scratch path they both write is a collision waiting to happen,
and naming it for the document alone still collides when two documents hash
alike. Scratch state is therefore keyed by both the document's path and its
content, and a check on the finished artifact holds regardless of whether that
keying was sufficient.

**Every check in the publication sequence is a control-flow gate, never a
standalone command whose result nothing consumes.** This is the general rule the
isolation check is one instance of, and it is load-bearing because of what
follows each check: the next step pushes, checks out, or fast-forwards. A
predicate written as its own step fails silently into that next step, so the
eligibility test gates the classification read, the isolation check gates the
push, and the remote-ancestry check gates the convergence in §9.5. The commit
must change exactly the one eligible document against the remote publication
branch, and the push is conditional on that comparison as well as on the owner,
so a second path from any source leaves the publication unattempted.

Nothing before the push leaves the object store — building a candidate commit
writes unreferenced objects and moves no branch — so the push is the single
external effect, and it is the one step every gate converges on.

### 9.4 How a publication is made

Publication is a normal fast-forward update of the remote publication branch and
nothing more. It never force-pushes, never resets, never overwrites a concurrent
advance of `$DOC_BRANCH`, and never resolves a conflict by guessing. A
non-fast-forward rejection, a conflict, or a detected branch movement leaves the
mutation recoverable and is reported as an unpublished failure.

Recoverable does not mean parked anywhere convenient. A failed publication must
not leave the checkout's local default branch diverged from its remote: the PR
drainer fast-forwards that branch with `git merge --ff-only` after every merge,
and an unpushed local commit on it wedges every later pass until a human
intervenes. Retaining the mutation as an uncommitted edit in the docs worktree,
or under a ref that is not the default branch, both satisfy this; committing it
onto the local default branch does not. The §9.5 failure report names where the
mutation was retained.

### 9.5 What "published" means, and the three-state failure report

A run may describe a document as published only after verifying that the
intended publication commit is present on the remote publication branch. A push
that appeared to succeed is not that verification.

A failure report distinguishes all three states rather than collapsing them:

- whether the document edit exists locally, and in which worktree and at which
  path;
- whether a local publication commit exists and, if so, its commit ID; and
- whether the remote publication branch contains that commit.

After a verified publication the local state must agree with it: a later run
resolving the document under `$DOCS_WT` sees the published content rather than a
divergent local-only copy, and the published mutation is not left queued for
republication. Advancing the docs worktree's branch and reconciling the file
against the published commit both satisfy this; what may not survive is a local
copy a later run cannot tell apart from a still-pending mutation.

**That reconciliation is gated on the verification, not merely sequenced after
it.** Reconciling a document against the publication branch replaces the local
copy with what that branch holds — which, after a rejected push, is the state
without the approved mutation. Run ungated, the step that converges a successful
publication is the step that destroys an unsuccessful one, and §9.4's
recoverability guarantee would hold only when it was not needed.

### 9.6 Resuming an unfinished publication

A later run recognizes an already-applied tracker or document mutation and
resumes the unfinished publication step without repeating the tracker mutation.
The evidence is only what the document and the tracker already carry — a ledger
entry already bearing its `[#N]`, `[no-issue]`, or `[deferred]` marker, or an
existing local publication commit — and the response is only to re-attempt the
publication step itself. A durable journal, cross-system reconciliation, or
identity verification of a similarly titled artifact is deliberately not part of
this contract.

**The scan for that state runs before entry selection, and is exempt from it.**
An applied disposition is exactly what a terminal marker records, so the entry
whose publication failed is already marked — and §5's selection never selects a
terminal-marked entry. A resumption check reached only through normal selection
is therefore unreachable by construction: the run would pick up new work and
leave the unpublished mutation behind every time. The scan looks for an eligible
document that differs from its publication branch before any entry is chosen,
and a run that finds one re-attempts that publication and selects nothing new,
which is also why resuming does not spend the invocation's one artifact.

### 9.7 What publishing does not change

Publication happens after each individually approved disposition and is never
batched or deferred merely to reduce commit or push frequency. The §5
boundaries are untouched: one artifact per invocation still bounds the run, and
explicit approval still precedes every mutation — including the publication of
one, which inherits the approval of the mutation it carries and grants no
license to sweep in a second.
