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
- a processing asset loses its §9 publication step, or stops resolving
  `tools/publish_coordination_doc.py` from the owning repository's own write
  root;
- a processing asset carries any part of the publication sequence itself rather
  than invoking that module, or writes the document instead of handing over its
  approved content;
- a drafting asset stops stating that a novel document remains local until it is
  separately classified and published;
- this document drops §9's `pr-atomic` fail-closed rule, its one-artifact
  boundary, or its rule that publication is reported only on reachability.

The mechanism's own behavior is not this module's subject:
`tools/test_publish_coordination_doc.py` executes it against temporary
repositories, and `tools/test_document_classification.py` owns §7's rows and the
`coghex/kanban` `workflow.coordination_paths` example that mirrors them.

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
  other asset does.
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
is the authoritative classification, and eligibility means exactly one thing:
the resolved document's repository-relative path is classified `coordination`
there. **A `pr-atomic` path, and a path no row matches, is never published
directly** — `pr-atomic` is the fail-closed default for an unmatched path, so an
unrecognized document is left unpublished rather than guessed into the direct
lane.

§8's ownership resolution is a prerequisite, not a parallel check: a document
whose owning repository or publication branch could not be verified fails closed
and stays unpublished. §7 is Kanban's own statement about Kanban, so
`coghex/kanban` is the only repository with a `coordination` lane here; a
consuming repository that installed these plugins has none, and neither does a
fork.

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
an index-only edit is invisible to a check that hashes the file alone.

**The write root is ordinarily not the publication branch.** The assets write in
the `docs-wip` linked worktree while publication targets the default branch, so
eligibility, the baseline, and resumption are all decided against the publication
tip's own blob for the path, and the module never checks out, resets, switches,
or advances any branch or HEAD in the write root.

**A publication is guaranteed, not hoped for.** The module holds a per-document
lock across the whole sequence, releasing and clearing it only by the exact
value it means to remove — two clearers can agree one owner is dead, and an
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

**Nothing the module does can leave the document deleted.** For the length of
that instant the captured copy is the only one, so its content reaches the
object database before anything else can fail, and every way out of the swap —
including failures the code did not anticipate — puts the document back before
dropping that copy. A restoration never raises and never overwrites: it must
not replace the error that caused it, and it must not become the write that
destroys another — including in its own fallbacks, which recreate the document
exclusively rather than renaming over whatever is there. Where it cannot restore, the captured file is kept rather
than removed. Content it declines to publish is written to the object database first,
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
against travels with the content, and a branch that has moved since refuses the
publication and asks for the disposition to be rendered again.

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

Every other outcome is an unpublished failure, reported with all three states
rather than collapsed into one:

- whether the document edit exists locally, and in which worktree and at which
  path;
- whether a local publication commit exists and, if so, its commit ID; and
- whether the remote publication branch contains that commit.

A failed publication leaves the mutation recoverable and never diverges the
checkout's default branch from its remote — the PR drainer fast-forwards that
branch after every merge, and an unpushed local commit on it would wedge every
later pass.

Because the caller hands over the whole document, a successful publication also
reports what it changed: an unintended rewrite of the rest of the document
changes the same single path a correct publication does, so the changed-line
summary, not the changed-path check, is what makes it visible to the run that
caused it.
