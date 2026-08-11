---
name: design-epic
description: Capture and refine a feature arc in a durable Markdown design document before any epic or child issues are drafted. Use when the user invokes $design-epic, starts describing an epic-sized feature or refactor, wants to continue designing an existing *_design.md document, or wants a design-first replacement for drafting an epic directly in chat. Preserve decisions, open questions, repository evidence, dependency-ordered delivery slices, and a process-design-doc-compatible status ledger without creating tracker items.
---

# Design Epic

Maintain one Markdown document as the source of truth for an epic-sized design.
Optimize for a good design conversation, not issue-shaped prose. Leave tracker
drafting, deduplication, approval, and creation to later `process-design-doc`
runs.

## Where files go

Never leave uncommitted files in the repository's PRIMARY checkout. The PR
drainer fast-forwards it after every merge and autostashes whatever it finds
there; a restore that conflicts leaves unmerged index entries and wedges
post-merge cleanup until a human clears them. Long-lived uncommitted report
edits are the exact shape that keeps causing it.

Resolve the docs worktree by BRANCH — never a hard-coded path — and do every
file write there:

```bash
DOCS_WT="$(git worktree list --porcelain \
  | awk '/^worktree /{p=substr($0,10)} /^branch refs\/heads\/docs-wip$/{print p; exit}')"
[ -n "$DOCS_WT" ] || DOCS_WT="$(git rev-parse --show-toplevel)"
```

Every report or document path in this workflow resolves under `$DOCS_WT`,
whatever the current directory is. Read code from wherever you already are;
write only there. If the repository has no `docs-wip` worktree the fallback
returns the primary checkout, which means that repository does not use this
convention — proceed normally.

## Resolve the document

Accept invocations such as:

```text
$design-epic docs/asset_streaming_design.md I want textures to load lazily...
```

```text
$design-epic Design a mod-loading arc with me.
```

Treat an explicit `.md` token as the document path. Otherwise infer a concise
subject and use `docs/<subject>_design.md` when `docs/` exists, or
`<subject>_design.md` at the repository root. Before creating a new file, search
for a clearly matching `*_design.md`; resume it when the subject and arc match.
Tell the user the resolved path before substantial investigation so they can
redirect it without pausing the work.

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
7. Ask at most three high-leverage questions after recording everything already
   known. Prefer questions that distinguish user-visible behavior, ownership,
   compatibility, scope, or delivery order. Leave lesser uncertainty in the
   document instead of blocking useful progress.

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
