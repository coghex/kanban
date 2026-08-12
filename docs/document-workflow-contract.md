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
  wording may differ, and the two `process-report` variants are deliberately
  not reconciled into one file. What may not differ is the shared status
  vocabulary in §4 and the processing boundaries in §5.

## 2. Declared assets

Machine-readable; parsed verbatim by
`tools/test_document_workflow_contract.py`. Columns:
`brand | invocation | path`.

```text
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
| `$design-epic` | **Codex only** | One `*_design.md` document | No — never | The document's `Design state` and processing ledger |
| `$process-design-doc` | **Codex only** | One approved epic or child disposition per run | Yes, after per-artifact signoff | The design document's `## Processing status` ledger |
| `$draft-report` | **Codex only** | One `*_findings.md` report | No — never | The report it creates, with every box unchecked |
| `/process-report`, `$process-report` | Claude and Codex | One approved finding disposition per run | Yes, after per-finding signoff | The report's status checklist and heading markers |

### 3.1 Design capture: `$design-epic`

`$design-epic` maintains one Markdown document as the source of truth for an
epic-sized design: verified current state, decisions with stable `D-N`
identifiers, open questions with stable `Q-N` identifiers, and
dependency-ordered delivery slices. It modifies only that document. It creates
no GitHub issues, labels, or comments, and it drafts no final issue bodies —
tracker work belongs to `$process-design-doc`.

The document is only handed on once the user explicitly says so and the
readiness conditions hold, at which point its state becomes exactly
`Design state: ready for issue processing`.

### 3.2 Design processing: `$process-design-doc`

`$process-design-doc` turns a ready design document into tracker artifacts, one
per invocation, using the document as the durable cursor: the epic first, then
one dependency-ready child. It requires the ready state, and returns a document
whose ledger and delivery plan disagree to `$design-epic` rather than guessing
which representation wins.

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

These two are the only cross-brand pair in this contract, so §4's status
vocabulary is a hard compatibility surface between them: a report started by
one brand must be resumable by the other without translation.

While the Codex-only asymmetry in §3.5 remains, an Epic disposition reached
through `/process-report` hands the user to Codex's `$design-epic` and
`$process-design-doc` workflows. The tracked Claude command must not name
nonexistent Claude counterparts or depend on owner-maintained personal copies.

### 3.5 Declared Codex-only asymmetry

`$design-epic`, `$process-design-doc`, and `$draft-report` are Codex-only. No
Claude counterpart exists, and that is a declared gap rather than an oversight:
authoring one would be new behavior that no pinned source defines, which is
precisely what the SHA-pinned vendoring model of issue #118 refused to do. The
Claude plugin must not grow one under this contract until a pinned source
exists to vendor.

The asymmetry runs opposite to the Claude-only `/draft-issues` boundary in
[drafting-workflow-contract.md §3.2](drafting-workflow-contract.md#32-claude-only-breadth-draft-issues),
and is recorded the same way rather than closed.

### 3.6 The epic planner: `$design-epic` with `$process-design-doc`

`$design-epic` produces a durable design document and creates no tracker items;
`$process-design-doc` — not `$design-epic` — is what later turns an approved
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
unchecked boxes is the count of entries a document still owes. `$design-epic`
and `$draft-report` write only the unchecked form: neither applies a
disposition, so a checked box in a document they just produced would be a bug.

`[no-issue]` and `[deferred]` are not interchangeable: the first closes an
entry, the second keeps it open behind a stated precondition. "Needs more
thought", "low priority", and "revisit later" are not preconditions.

`/process-report` and `$process-report` must state these literals identically.
That is what makes a report portable between the brands, and it is the part of
the two variants' otherwise-permitted textual divergence that this contract
does not allow.

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

`$design-epic` and `$process-design-doc` carry a third boundary the report
workflows do not, because a design conversation settles behavior long before
there is an artifact to approve: the user owns every design decision. Both
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
- this document stops stating the Codex-only asymmetry (§3.5), the
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
  (§5.1), or `$design-epic` or `$process-design-doc` drops one of the authority
  clauses that boundary summarizes — the design pair's counterpart to the §5
  check above, and the reason §5.1's semantics cannot regress in the assets
  while the document still describes them.

Discovery, frontmatter, and no-personal-path coverage for these assets lives
with the rest of each plugin's structural coverage in
`tools/test_claude_plugin.py` and `tools/test_codex_plugin.py`, and their
external-command surface is reconciled against the §4 dependency manifest of
[agent-workflow-contract.md](agent-workflow-contract.md#4-dependency-manifest)
by `tools/test_agent_workflow_contract.py`.
