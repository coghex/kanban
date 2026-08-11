---
name: process-design-doc
description: Turn a ready design-epic Markdown document into one approved GitHub tracker artifact at a time, using the document as a durable cursor. Use when the user invokes $process-design-doc, asks to process or continue a *_design.md file into an epic and child issues, wants the next design slice drafted or filed, or wants resumable one-by-one signoff without loading the whole arc into one conversation. Process the epic first, then one dependency-ready child per invocation; never batch approvals or creations.
---

# Process Design Doc

Process exactly one entry from a ready design document per invocation. The
document is the durable cursor: a fresh conversation must be able to select and
draft the next tracker artifact without relying on chat history.

The first entry is the umbrella epic. Every later entry is one child issue or
one explicit disposition. Never draft, approve, or create a second entry in the
same run.

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

## Status contract

Read the `## Processing status` ledger near the top of the document. The first
line must be `EPIC`; later lines use stable delivery-slice IDs and mirror the
delivery-plan order.

Canonical ledger forms are:

```markdown
- [ ] EPIC. Asset streaming
- [x] EPIC. Asset streaming — [#210]
- [ ] STREAM-1. Define observable loading behavior
- [x] STREAM-1. Define observable loading behavior — [#211]
- [x] STREAM-2. Retire an unnecessary slice — [no-issue]: folded into #211
- [ ] STREAM-3. Migrate texture callers — [deferred]: #211 must merge first
```

Markers mean:

- `[#N]` — linked to a confirmed new or existing tracker item; terminal.
- `[no-issue]` — reviewed and deliberately not tracked separately; terminal.
- `[deferred]` — real planned work blocked on a concrete, checkable
  precondition; non-terminal.
- no marker — unprocessed.

Check a box only for a terminal marker. The ledger is the status source of
truth. A processed slice may also receive a short blockquote directly below its
delivery-plan heading to preserve the tracker link or disposition rationale,
but that note never overrides the ledger.

Never renumber a stable slice ID during processing. Never mark an entry before
the corresponding approved external action succeeds.

## 1. Select one entry

1. Resolve an explicit or conversation-linked path relative to the working
   directory. If none was supplied, search `docs/` and the repository root for
   `*_design.md`; use the sole ready candidate when exactly one exists, and ask
   for the path when multiple candidates remain plausible. Require a Markdown
   file, announce the resolved path, and read applicable repository
   instructions.
2. Read the document title, `Design state`, status legend, processing ledger,
   epic contract, decisions index, open-question index, and delivery headings.
   Do not read every delivery body merely because it exists.
3. Require exactly `Design state: ready for issue processing`. If it is still
   exploring or the mechanical contract is missing, stop without editing and
   use `design-epic` to finish or normalize it.
   Also verify that `EPIC` is first, every stable slice ID appears exactly once
   in the ledger and once in the delivery plan, ledger order matches delivery
   order, every dependency ID exists, and the dependency graph is acyclic. A
   mismatch returns to `design-epic`; do not guess which representation wins.
4. Select the unprocessed `EPIC` entry first. After the epic is linked, scan
   child entries from top to bottom and select the first non-terminal entry when
   its dependencies are terminal and, for `[deferred]`, its stated precondition
   is now verified. This ledger order is also issue creation order; do not let a
   newly unblocked later item jump ahead of earlier critical-path work.
5. Treat a dependency linked as `[#N]` or deliberately closed as `[no-issue]`
   as terminal, but re-check that a no-issue dependency did not remove behavior
   the selected slice assumes. A deferred or unprocessed dependency is not
   terminal.
6. If the earliest non-terminal entry is blocked, a later ready entry may be
   selected only when its delivery section explicitly labels it `independent`,
   `can land first`, or `not on the critical path`. Otherwise stop on the
   blocker; silently skipping it would change the designed work order.
7. If no entry is selectable, report either completion or the concrete blockers
   on remaining deferred/dependency-blocked entries. Do not call a blocked arc
   complete.

Before drafting a new item, reconcile the ledger's linked children with the
epic checklist. If an earlier approved update partially failed, report the
drift and obtain approval to repair it before selecting new work.

## 2. Load only the selected context

For the epic, read the epic contract, arc-level scope, verification strategy,
ledger titles, phases, and dependency summaries. Do not load every child body.

For a child, read:

- the epic contract and arc-level constraints;
- the selected delivery section;
- only the full decisions and open questions referenced by that section;
- the ledger entries and tracker bodies for its actual prerequisites; and
- later slices only when their titles or boundaries are needed for `Out of
  scope`.

Then inspect the current repository surface needed to verify the selected
premise and discover exact, proportionate acceptance commands. Treat the design
as intent, not evidence. Do not modify implementation code.

## 3. Deduplicate the selected artifact

Before recommending creation:

1. Read every open issue title:

   ```bash
   gh issue list --state open --limit 300 --json number,title,labels
   ```

2. Run two or three differently phrased searches across open and closed issues.
3. Read plausible matches and overlapping open epics. A planned child in an
   existing epic is a duplicate.
4. Read the current umbrella epic before drafting a child. Use actual tracker
   numbers from the ledger, never `#TBD` placeholders.
5. Respect prior `wontfix`, `invalid`, and decision records unless the design
   contains materially new evidence.

## 4. Process the epic entry

Use this section only when `EPIC` is selected.

Confirm the arc genuinely needs multiple dependency-ordered PRs. If it has
collapsed to one issue or still contains a material unresolved design decision,
recommend returning to `design-epic`; do not manufacture an umbrella.

Otherwise present one self-contained epic draft:

- an outcome-oriented title;
- labels `epic` plus the existing or proposed arc label;
- the verified background and goal;
- a phase-ordered child checklist using stable design IDs and proposed titles;
- dependency structure in prose using the repository's triage vocabulary;
- arc-level `Done when` conditions;
- a `Related` section, including the design-document path only as a supporting
  pointer rather than required context; and
- `<!-- issue-origin:codex -->` as the final line.

If a new arc label is useful, include its exact proposed name, description, and
color in the same signoff. The epic body must stand alone even if the local
design document has not been committed.

If an existing epic already covers the arc, present the evidence and any exact
body edits needed to adopt it. Do not create a duplicate.

Present the full draft or adoption edit verbatim and **stop for explicit
approval**. Do not create a label, create an epic, edit an existing epic, or
update the document while presenting or revising the proposal.

After approval:

1. Create any approved new label, then create the epic with a temporary body
   file; or apply the approved adoption edit.
2. Confirm the epic number, title, body, labels, state, and URL.
3. Update only the `EPIC` ledger line to checked `[#N]` with `apply_patch`.
4. Verify the ledger edit and stop. Do not draft the first child.

## 5. Process one child entry

Use this section only when a delivery slice is selected. Choose exactly one
disposition.

### Existing issue

Use when an issue already covers the complete selected outcome. Present the
number, exact coverage evidence, any genuinely useful proposed comment, and the
exact epic-checklist change. Stop for approval before commenting, editing the
epic, or marking the document.

### One new issue

Use when the selected work fits one reviewable PR. Present exactly what will be
posted:

- an imperative title following the tracker's arc-title convention;
- existing labels only;
- `## Background` with current verification evidence;
- numbered, observable `## Requirements` that state what, not how;
- exact, proportionate `## Acceptance` commands and expected outcomes;
- explicit `## Out of scope` fencing adjacent slices;
- `## Related` naming the epic and actual prerequisite issue numbers; and
- `<!-- issue-origin:codex -->` as the final line.

Write dependency ordering into the body in vocabulary the repository triage
workflow parses: `depends on #N`, `blocked by #N`, `Phase 1`, `Phase 2`,
`critical path`, `not on the critical path`, `can land first`, or `independent`
as applicable. Preserve real repository constraints such as compatibility,
determinism, persistence, performance, and steering-document updates. A
deliberately open design question gets its own section naming the exact point at
which the solver must stop and ask; never silently decide it.

Below the verbatim draft, show concise Evidence and Dedup notes plus the exact
epic-checklist replacement. State that no later slice was evaluated. Stop for
explicit approval.

### No separate issue

Use when the slice is false, already fully included in another approved child,
or deliberately removed from scope. Present the evidence, exact
`[no-issue]` rationale, and exact epic-checklist removal or replacement. Stop
for approval. Do not use this disposition for work that is merely unclear or
blocked.

### Deferred

Use when the slice is real but a good issue cannot yet be written because a
specific premise is unverified, a named decision is unresolved, or a concrete
prerequisite must land first. Present the evidence, exact `[deferred]` note, and
the checkable precondition. Stop for approval. `Needs more thought`, low
priority, and issue size are not valid preconditions.

If the selected slice no longer fits one PR, stop and return it to
`design-epic` for an approved split. Do not expand one processing run into
multiple drafts.

## 6. Apply one approved child disposition

Only after explicit approval:

- **New issue:** create the approved body with `gh issue create --body-file` and
  confirm its number and URL.
- **Existing issue:** post only an explicitly approved comment, if any, and
  confirm the target still exists.
- **No separate issue / Deferred:** make no issue mutation.

For a linked or newly created issue, update the umbrella epic's child checklist
with the actual `#N`. For `[no-issue]`, apply the approved removal or folding
note. A deferral does not change the epic checklist. Never make an unshown epic
edit.

Then update exactly the selected ledger line in the design document:

- `[#N]`: check the box and append the confirmed tracker number;
- `[no-issue]`: check the box, append the approved concise reason, and add a
  visible disposition note under the delivery heading;
- `[deferred]`: leave the box unchecked, append the concrete precondition, and
  add a visible deferred note under the delivery heading.

Use one `apply_patch` edit, preserve all unrelated design content, and remove a
stale deferred note when the item later advances. Verify the selected key,
ledger checkbox/marker, unchecked count, epic checklist, and tracker metadata.

If issue creation succeeds but epic or document synchronization fails, do not
create anything else. Record the confirmed issue number in the design document
with a concise processing note when possible, report the partial state, and
reconcile it before the next item.

Report the disposition and tracker URL, the ledger line as it now reads, and
the remaining unchecked count. Stop after this one entry. Advance only on a
later explicit invocation of `process-design-doc`.

## Approval and mutation boundaries

- Approval is per epic or per child, never for the remaining batch. A broad
  statement such as "make the whole epic" does not waive one-at-a-time signoff
  unless the user explicitly changes this workflow.
- Revisions do not imply approval. Re-present the complete artifact and exact
  side effects, then stop again.
- Do not create or edit tracker items, labels, or comments before approval.
- Do not commit, push, open a PR, or modify implementation code unless
  separately requested.
