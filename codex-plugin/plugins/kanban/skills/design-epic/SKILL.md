---
name: design-epic
description: Capture and refine a feature arc in a durable Markdown design document before any epic or child issues are drafted. Use when the user invokes $design-epic, starts describing an epic-sized feature or refactor, wants to continue designing an existing *_design.md document, or wants a design-first replacement for drafting an epic directly in chat. Preserve decisions, open questions, repository evidence, dependency-ordered delivery slices, and a process-design-doc-compatible status ledger without creating tracker items.
---

# Design Epic

Maintain one Markdown document as the source of truth for an epic-sized design.
Optimize for a good design conversation, not issue-shaped prose. Leave tracker
drafting, deduplication, approval, and creation to later `process-design-doc`
runs.

## Human interaction and decision authority

This is a human-led design conversation, not an autonomous specification pass.
Repository evidence can establish current facts, but only the user can choose
the intended behavior or approve a serious design decision.

- Agent-authored directions are **Proposals**, never **Decisions**. Record or
  change a `D-N` entry only on explicit user approval of that exact choice.
- A serious decision needs its own explicit signoff checkpoint. Present the
  choice, its rationale, its consequences, and the affected slices, then stop.
  Signoff may cover a clearly enumerated set of decisions, but never an
  unstated or inferred one.
- Silence, continued conversation, approval of a document edit, or a request
  for revisions is not signoff. A revised choice is re-presented and signed off
  on its own.
- Any ambiguity about the user's intent, supplied notes, or desired outcome
  requires user input before design work advances. That includes ambiguity
  about behavior, scope, ownership, compatibility, migration, persistence,
  determinism, delivery order, issue boundaries, verification, or an important
  non-goal. Do not classify an ambiguity as minor, and do not pick the most
  likely interpretation to keep moving — state the competing readings and their
  consequences, and ask.
- When clarification is required, ask at most three focused questions at a time
  and stop. Continue after the user answers; ask another batch if further
  ambiguities remain.
- Record established facts and the user's own material before asking, but do
  not continue into dependent design, slice decomposition, or readiness until
  every blocking ambiguity and serious decision has been answered and signed
  off.

## Establish the owning repository

This workflow writes a document and mutates a tracker. Both are irreversible in
the wrong repository, and moving a Markdown file afterward does not undo an
issue filed where it does not belong. So resolve the owner explicitly before
the first durable write and before the first tracker mutation — never from
whichever checkout the session happens to be sitting in.

Resolve three values together, and treat every one of them as required:

- `$DOC_REPO` — the owning repository as an explicit `owner/repo` slug. It
  scopes every `gh` command in this workflow.
- `$DOC_BRANCH` — that repository's default branch, which is the publication
  target. It is never assumed to be the current checkout's branch.
- `$DOC_ROOT` — a validated local checkout of `$DOC_REPO`, under which every
  document read and write resolves. A slug alone names no place to write.

Resolution has two tiers, and the first tier that matches wins:

**(a) Explicit input.** A repository or a document path the user supplied.
Validate each one, and require them to agree: when the user names both, the
path's own checkout must resolve to that same repository. Conflicting explicit
inputs are unresolved, not a preference to rank.

**(b) A §7 row.** For a document path that is Git-tracked in the checkout
holding it, coverage by exactly one row of `docs/agent-workflow-contract.md` §7
declares the document Kanban-owned. That table is Kanban's own and classifies
Kanban paths only, so it can identify Kanban as the owner and can never
identify a consuming repository. A path covered by no row, covered by more than
one row, or not tracked at all resolves nothing here — and a new document that
no row covers is the expected case rather than an error.

Anything else leaves the owner unresolved.

```bash
# $CANDIDATE is the checkout an explicit path or repository named — never the
# working directory by default. Nothing below reads the process working
# directory, which is the point: every command names its own repository.
DOC_ROOT="$(git -C "$CANDIDATE" rev-parse --show-toplevel)"
DOC_REMOTE="$(git -C "$DOC_ROOT" remote get-url origin)"
DOC_REPO="$(gh repo view "$DOC_REMOTE" --json nameWithOwner --jq .nameWithOwner)"
DOC_BRANCH="$(gh repo view "$DOC_REMOTE" --json defaultBranchRef --jq .defaultBranchRef.name)"

# Tier (b) additionally requires the document to be tracked where it sits.
git -C "$DOC_ROOT" ls-files --error-unmatch -- "$DOC_RELATIVE_PATH"
```

**Fail closed.** An unresolved owner, an unresolved or ambiguous default
branch, or a `$DOC_ROOT` that is not a checkout of `$DOC_REPO` stops the run
before it creates a file, edits a document, or issues any `gh` mutation. Say
exactly which of the three could not be determined, and ask the user for the
owning repository — and for a local path as well when no checkout of it is
available. Falling back to the active checkout, to the current branch, to a
hardcoded path, or to a bare `docs/` prefix is never the repair.

Report the resolved `$DOC_REPO` and `$DOC_BRANCH` to the user before the first
write.

Reading code, tests, or history from another repository as evidence stays
allowed and is never an ownership signal: where you read something does not
make that repository the owner.

Repository routing and the publication lane are separate decisions. `$DOC_REPO`
says where this document and its tracker items belong; whether the document
then publishes as `coordination` or `pr-atomic` is a later question §7 answers
about an already-resolved owner, never a substitute for resolving one.

## Where files go

Never leave uncommitted files in the repository's PRIMARY checkout. The PR
drainer fast-forwards it after every merge and autostashes whatever it finds
there; a restore that conflicts leaves unmerged index entries and wedges
post-merge cleanup until a human clears them. Long-lived uncommitted report
edits are the exact shape that keeps causing it.

Resolve the docs worktree by BRANCH — never a hard-coded path — inside the
already-resolved `$DOC_ROOT`, and do every file write there:

```bash
DOCS_WT="$(git -C "$DOC_ROOT" worktree list --porcelain \
  | awk '/^worktree /{p=substr($0,10)} /^branch refs\/heads\/docs-wip$/{print p; exit}')"
[ -n "$DOCS_WT" ] || DOCS_WT="$DOC_ROOT"
```

Every report or document path in this workflow resolves under `$DOCS_WT`,
whatever the current directory is. Read code from wherever you already are;
write only there. If `$DOC_REPO` has no `docs-wip` worktree the fallback
returns that repository's own primary checkout, which means it does not use
this convention — proceed normally. What the fallback never returns is the
checkout you happen to be sitting in.

## Resolve the document

Accept invocations such as:

```text
$design-epic docs/asset_streaming_design.md I want textures to load lazily...
```

```text
$design-epic Design a mod-loading arc with me.
```

Treat an explicit `.md` token as the document path, and feed it to the ownership
resolution above as the explicit path input. Otherwise infer a concise subject
and use `$DOCS_WT/docs/<subject>_design.md` when `$DOCS_WT/docs/` exists, or
`$DOCS_WT/<subject>_design.md`; a bare `docs/` prefix names nothing until
`$DOC_ROOT` is resolved, and a document whose owner stays unresolved is asked
about rather than created. Before creating a new file, search `$DOCS_WT` for a
clearly matching `*_design.md`; resume it when the subject and arc match. Tell
the user the resolved path, `$DOC_REPO`, and `$DOC_BRANCH` before substantial
investigation so they can redirect any of the three without pausing the work.

Never overwrite or repurpose an unrelated document. If neither an idea nor an
existing path was supplied, ask only what they want to design.

## Work from the user's thinking

Treat everything after the invocation as source material, even when it is a
brain dump, correction, preference, or answer to an earlier question.

1. Read applicable repository instructions and the existing design document.
2. Merge new input into the document immediately; do not make the user restate
   earlier decisions or organize their notes first.
3. Ground claims in the current repository. Read the owning code, tests,
   documentation, and configuration needed to distinguish current behavior from
   a proposal. On later design turns, investigate only the surfaces affected by
   the new input rather than reloading the whole arc. Check the tracker for a
   clearly overlapping arc on first creation and again at readiness, but do not
   perform final per-child deduplication here.
4. Separate four kinds of information explicitly:
   - **Verified current state** — supported by repository or tracker evidence.
   - **Decisions** — choices the user has made, with stable `D-N` identifiers.
   - **Proposals** — plausible directions that are not decisions yet.
   - **Open questions** — choices whose answers could alter behavior or scope,
     with stable `Q-N` identifiers.
5. Preserve important rejected alternatives and why they lost. Do not silently
   turn an implementation suggestion into a requirement.
6. When an open question is answered, create or update the corresponding
   decision and preserve the question ID as `Resolved by D-N` rather than
   leaving a dangling reference or erasing useful history.
7. Ask at most three high-leverage questions at a time, after recording
   everything already known. Prefer questions that distinguish user-visible
   behavior, ownership, compatibility, scope, or delivery order. Batching paces
   the asking; it does not license settling the rest. Carry any remaining
   ambiguity forward as an open question and ask the next batch rather than
   deciding it under the authority rules above.

Use `apply_patch` for every document edit. Preserve unrelated user edits and
stable identifiers across revisions.

## Document contract

Create or normalize the document toward this structure. Adapt section names to
the subject, but preserve `Design state`, `Processing status`, the `EPIC` entry,
and stable slice identifiers because `process-design-doc` relies on them.

```markdown
# <Arc name> design

<Why this design exists and who or what benefits.>

Design state: `exploring`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. <Umbrella tracker title>
- [ ] <ARC>-1. <First delivery-slice title>
- [ ] <ARC>-2. <Second delivery-slice title>

## Epic contract

- **Goal:** <observable arc-level outcome>
- **Done when:** <conditions that complete the whole arc>
- **Users and operators:** <who experiences or maintains the result>
- **Arc label:** <existing or proposed label, or `None proposed`>

## Current state and evidence

<Relevant behavior and concise path/issue evidence.>

## Desired experience

<User flows, system behavior, and operational experience.>

## Scope

### In scope

### Out of scope

## Design

<Behavior, ownership boundaries, data flow, lifecycle, and failure handling at
the level needed to settle the product and system design.>

## Decisions

### D-1. <Decision>

<Choice, rationale, and consequences.>

## Open questions

### Q-1. <Question>

<Why it matters, options known so far, and what resolves it.>

## Verification strategy

<Arc-level observable signals, compatibility concerns, and relevant test or
probe families. Exact issue acceptance commands are added during processing.>

## Delivery plan

### <ARC>-1. <Imperative child title>

- **Outcome:** <one-PR result>
- **Scope:** <included behavior>
- **Phase:** <number or name>
- **Depends on:** `none` or stable slice IDs
- **Ordering:** `critical path`, `independent`, `can land first`, or `not on the
  critical path`
- **Relevant decisions:** stable `D-N` IDs
- **Acceptance signals:** <observable evidence of completion>
- **Out of scope:** <adjacent work excluded from this slice>
- **Open questions:** `None` or stable `Q-N` IDs; identify deliberately open
  questions explicitly

## Source notes

<Optional quotations or condensed notes whose original wording matters.>
```

Keep `Processing status` in the same order as `Delivery plan`. Put slices in
dependency-valid work order. Each slice must plausibly fit one issue, one
worktree, and one reviewable PR. Split independently reviewable outcomes; keep
inseparable behavior together. Record dependency IDs rather than future GitHub
number placeholders.

Do not pad empty sections. Omit `Source notes` when it adds no value. Never put
full issue bodies, labels beyond the arc-level proposal, or `#TBD` issue-number
references in the design document.

If a material design edit is made after the document was ready, reset it to
`exploring` until the changed behavior, scope, and slice boundaries receive
fresh readiness signoff. Tracker numbers and processing notes alone are not
material design edits.

## Readiness

Keep `Design state: exploring` while material behavior, scope, or ordering is
still being designed. Change it to exactly:

```markdown
Design state: `ready for issue processing`
```

only when the user explicitly says the design is ready and all of these hold:

- the epic goal and arc-level done condition are observable;
- scope and important non-goals are explicit;
- material choices are decided, or deliberately open with the affected slice
  and stop/ask behavior identified;
- delivery slices are one-PR sized, dependency-ordered, and mirrored exactly in
  the processing ledger;
- compatibility, migration, persistence, determinism, documentation, and test
  constraints relevant to the repository are recorded; and
- no existing tracker epic makes the new umbrella a silent duplicate.

If readiness fails, leave the document in `exploring`, record the gaps as open
questions or proposals, and report the smallest set of decisions still needed.
Do not call an unfinished design ready merely so processing can begin.

## Boundaries and handoff

- Modify only the design document. Do not change implementation code, create or
  edit GitHub issues or labels, or draft final issue bodies.
- Do not require the entire design to be completed in one conversation. A thin
  first pass is useful when it faithfully captures what is known and what is
  open.
- Do not reopen settled decisions without new evidence or an explicit request.

Report the document path, current design state, decisions added or changed,
open questions, and delivery-slice count. When ready, end by stating that
`process-design-doc` will process the epic first and then exactly one child per
invocation, with separate approval for every tracker artifact.
