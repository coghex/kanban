---
description: Turn a ready design-epic Markdown document into one approved GitHub tracker artifact at a time, using the document as a durable cursor. Use when the user invokes /process-design-doc, asks to process or continue a *_design.md file into an epic and child issues, wants the next design slice drafted or filed, or wants resumable one-by-one signoff without loading the whole arc into one conversation. Process the epic first, then one dependency-ready child per invocation; never batch approvals or creations.
argument-hint: "[optional: path to a ready *_design.md document]"
---

# Process Design Doc

Process exactly one entry from a ready design document per invocation. The
document is the durable cursor: a fresh conversation must be able to select and
draft the next tracker artifact without relying on chat history.

The first entry is the umbrella epic. Every later entry is one child issue or
one explicit disposition. Never draft, approve, or create a second entry in the
same run.

## Human interaction and decision authority

This is a human-led tracker-design workflow, not an autonomous issue generator.
Read-only investigation can establish facts, but the user owns every
interpretation, design choice, issue boundary, disposition, and external
mutation.

- Agent-authored directions are **Proposals**, never **Decisions**, and this
  workflow changes a `D-N` entry only on explicit user approval — never as a
  side effect of drafting. If repository or tracker evidence exposes an
  unresolved choice or contradicts a signed-off decision, stop and return the
  document to `/design-epic` instead of quietly repairing the design inside an
  issue.
- A serious decision needs its own explicit signoff checkpoint: present the
  complete verbatim artifact, its side effects, and the exact choice at stake,
  then stop. Signoff may cover a clearly enumerated set of decisions, but never
  an unstated or inferred one.
- Silence, continued conversation, approval of a document edit, or a request
  for revisions is not signoff. Neither is approval of the underlying design or
  a broad instruction such as "process the epic". A revised artifact is
  re-presented in full and signed off on its own.
- Any ambiguity about the user's intent, the design contract, artifact
  selection, or a proposed action requires user input before drafting or
  mutating anything. That includes ambiguity about behavior, scope, ownership,
  compatibility, migration, persistence, determinism, dependencies, ordering,
  labels, acceptance, issue boundaries, disposition, or tracker edits. Do not
  classify an ambiguity as minor, and do not pick the most likely
  interpretation to keep moving — state the competing readings and their
  consequences, and ask.
- When clarification is required, ask at most three focused questions at a time
  and stop. Continue after the user answers; ask another batch if further
  ambiguities remain.

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

1. Resolve the path in `$ARGUMENTS`, or a conversation-linked path, under
   `$DOCS_WT`, never
   relative to the working directory. If none was supplied, search
   `$DOCS_WT/docs/` and `$DOCS_WT` itself for `*_design.md`; use the sole ready
   candidate when exactly one exists, and ask for the path when multiple
   candidates remain plausible. Require a Markdown file, announce the resolved
   path together with `$DOC_REPO` and `$DOC_BRANCH`, and read applicable
   repository instructions.
2. Read the document title, `Design state`, status legend, processing ledger,
   epic contract, decisions index, open-question index, and delivery headings.
   Do not read every delivery body merely because it exists.
3. Require exactly `Design state: ready for issue processing`. If it is still
   exploring or the mechanical contract is missing, stop without editing and
   use `/design-epic` to finish or normalize it.
   Also verify that `EPIC` is first, every stable slice ID appears exactly once
   in the ledger and once in the delivery plan, ledger order matches delivery
   order, every dependency ID exists, and the dependency graph is acyclic. A
   mismatch returns to `/design-epic`; do not guess which representation wins.
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
   complete. When you report completion, name the disposition the host document
   then owes under `docs/document-workflow-contract.md` §10: once the arc's
   umbrella epic is also closed, a specification document that merely hosted
   this arc's processing apparatus owes that apparatus's removal, while an arc
   document keeps its apparatus as the record. State it conditionally — a
   ledger with no outstanding entry may precede the epic's closure, so do not
   assert the removal is already owed unless that closure is verified. Removal
   is separate follow-up work authorized by an ordinary issue and delivered
   through the host document's own publication lane; this run does not perform,
   file, or publish it.

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
   gh issue list -R "$DOC_REPO" --state open --limit 300 --json number,title,labels
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
recommend returning to `/design-epic`; do not manufacture an umbrella.

Otherwise present one self-contained epic draft:

- an outcome-oriented title;
- labels `epic` plus the existing or proposed arc label;
- the verified background and goal;
- a phase-ordered child checklist using stable design IDs and proposed titles;
- dependency structure in prose using the repository's triage vocabulary;
- arc-level `Done when` conditions;
- a `Related` section, including the design-document path only as a supporting
  pointer rather than required context; and
- `<!-- issue-origin:claude -->` as the final line.

If a new arc label is useful, include its exact proposed name, description, and
color in the same signoff. The epic body must stand alone even if the local
design document has not been committed.

If an existing epic already covers the arc, present the evidence and any exact
body edits needed to adopt it. Do not create a duplicate.

Present the full draft or adoption edit verbatim and **stop for explicit
approval**. Do not create a label, create an epic, edit an existing epic, or
update the document while presenting or revising the proposal.

After approval, apply this entry through section 6 and publish it through
section 7, exactly as a child disposition is applied and published. The `EPIC`
entry is not a shortcut past them: it mutates the tracker and it moves the
document's cursor, so it takes the same preflight, the same tracker
transaction, and the same publication. In particular it never writes or stages
the document itself — a pre-edited document is refused as no longer matching
the publication tip, and the publication helper is the document's only writer.

Its ordered tracker steps are these, in this order, and only the ones that were
approved:

1. **EPIC label creation.** Creating the approved new arc label is its own
   checkpointed step: begin it before `gh label create -R "$DOC_REPO"` runs,
   and confirm it with the exact label name and metadata that call created.
2. **Epic creation.** Creating the umbrella epic is its own checkpointed step:
   begin it before `gh issue create -R "$DOC_REPO"` runs, and confirm it with
   the epic number and URL, which is also the `[#N]` marker the `EPIC` ledger
   line will carry.
3. **Epic adoption edit.** Adopting an existing epic instead is its own
   checkpointed step: begin it before the approved body edit, and confirm it
   with the target issue identity and the verified post-edit fingerprint.
   Adoption replaces creation; never plan both.

Then update only the `EPIC` ledger line to checked `[#N]`, compose the complete
updated document as text, and hand it to section 7. Verify the ledger edit
against what section 7 published and stop. Do not draft the first child.

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
- `<!-- issue-origin:claude -->` as the final line.

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
`/design-epic` for an approved split. Do not expand one processing run into
multiple drafts.

## 6. Apply one approved disposition

Use this section for the approved `EPIC` entry and for an approved child
disposition alike. Both mutate the tracker, so both take every step below.

**Resolve this bundle's own mechanism first.** Both helpers ship with this
plugin rather than with the repository being worked, so they are resolved
against this plugin's install location and never against `$DOC_ROOT`:

```bash
PUBLISH_DOC="${CLAUDE_PLUGIN_ROOT}/scripts/publish_coordination_doc.py"
TRACKER_TX="${CLAUDE_PLUGIN_ROOT}/scripts/tracker_transaction.py"
[ -f "$PUBLISH_DOC" ] && [ -f "$TRACKER_TX" ]
```

Claude Code substitutes `${CLAUDE_PLUGIN_ROOT}` to this plugin's own install
location regardless of the invoking working directory, which is what lets this
workflow run in a repository that tracks neither file. The two resolve as one
unit — each loads the other from beside itself — so a bundle carrying one
without the other carries neither, and an unresolvable helper stops the run
here rather than after the first mutation. The lookup rule this follows is
stated in full with the publication step below.

**First, before any tracker mutation, check for an outstanding publication or
tracker transaction.**

```bash
PREFLIGHT="$(python3 "$PUBLISH_DOC" \
  --repo "$DOC_REPO" --branch "$DOC_BRANCH" --root "$DOCS_WT" \
  --path "$DOC_RELATIVE_PATH" --check-pending)"
PREFLIGHT_TIP="$(PREFLIGHT="$PREFLIGHT" python3 -c \
  'import json, os; print(json.loads(os.environ["PREFLIGHT"])["publication_tip"])')"
[ -n "$PREFLIGHT_TIP" ]
PREFLIGHT_COPY="$(PREFLIGHT="$PREFLIGHT" python3 -c \
  'import json, os; print(json.loads(os.environ["PREFLIGHT"])["working_copy_blob"] or "")')"
[ -n "$PREFLIGHT_COPY" ]
```

`$PREFLIGHT_COPY` is the `working_copy_blob` the same preflight reported: the
exact bytes the document holds in the working copy at this moment. It is what
lets a document that has never been on the branch take its disposition — the
ordinary case for an owner whose documents accumulate in the docs worktree
until a batch landing — because for such a document there is no publication
tip blob to guard the write with, and the helper applies the mutation over the
working copy only while it still holds exactly those bytes. Extract it beside
the tip, and pass it back unchanged.

`$PREFLIGHT_TIP` must be extracted, not assumed: publication refuses to run
without it, and an empty one is a failure rather than a publication with the
check quietly switched off.

Keep the `publication_tip` it reports. The document you are about to read and
re-render is that tip's, and the content you produce is a whole-file image of
it, so publication must be refused if *this document* changed on the branch
since — a second run doing the same thing would otherwise drop this one's
disposition while changing exactly the one path a correct publication changes.
An advance that left this document alone drops nothing and still publishes, so
do not pre-empt the check by re-rendering against a fresher tip because the
branch moved; the helper compares the document's own blob at the two tips and
names the document when it refuses.

A `"pending"` result means an earlier approved mutation of this document is
outstanding — its publication, its tracker mutations, or both, and
`pending_kinds` says which. **Stop here.** Do not create or link a tracker item
and do not apply this disposition: the helper will refuse to publish a different
mutation while a publication record stands, and by then the new issue would
already exist for a disposition the document never receives. Report what the
record names and the resolution the helper suggests, and let the user decide.
This check is read-only and takes no lock — it is asked here, before the first
irreversible step, precisely because asking afterwards is too late.

When `pending_kinds` names `tracker-transaction`, the preflight's
`tracker_transaction` block is the whole report: the document, the selected
key, the disposition, the transaction state, the completed steps, the ambiguous
step if there is one, and the steps that remain. Resume that recorded
disposition rather than selecting new work. Its confirmed steps are verified
and never repeated; a `mutation-confirmed` or `publication-pending` record
offers only the completion of that disposition's document mutation and
publication; and a missing, mismatched, or conflicting recorded artifact stops
the run rather than adopting a similarly titled one. Re-present each remaining
step's exact recorded target and payload and stop for explicit approval before
executing it — a resuming invocation has no conversation history and no
in-session approval, and the recorded payload fingerprint bounds what may be
approved rather than standing in for the approval. Use `prepared_publication_tip`
only to report how far the branch has moved: the binding this run publishes with
is the `publication_tip` this preflight just reported, never the recorded one.

An `ambiguous_step` is a mutation that began and was never confirmed. It may
have landed. Never retry it, adopt a candidate for it, advance past it,
publish, or clear the record. Verify read-only whether its exact recorded
postcondition holds, present what you found, and let the user bind it to one
exact artifact or authorize a retry — one whose repository, target, immutable
identity or URL, approved payload, and observable postcondition all match what
was recorded. Absent, mismatched, conflicting, or more than one plausible
candidate leaves the record unresolved and stops the run. A similarly titled
artifact is never sufficient evidence.

### Acquire the tracker transaction before the first mutation

Only after explicit approval, and a `"clear"` preflight, acquire the record that
makes this disposition's tracker mutations recoverable. It is acquired **before
the first one runs**, because a run that dies afterwards leaves an unchanged
document, a clear preflight, and issues that already exist:

```bash
python3 "$TRACKER_TX" \
  --repo "$DOC_REPO" --root "$DOCS_WT" --path "$DOC_RELATIVE_PATH" \
  --acquire --approved --publication-tip "$PREFLIGHT_TIP" --plan - <<'PLAN'
{"entry_key": "<EPIC or the stable slice ID>",
 "disposition": "<the approved disposition kind>",
 "steps": [{"kind": "issue-create",
            "target": "<the exact approved target>",
            "payload_fingerprint": "<digest of the approved body>",
            "postcondition": "<what is observably true once it lands>",
            "provides_marker": true}]}
PLAN
```

Acquisition is create-only and atomic, so two runs that both saw a clear
preflight cannot both proceed; the loser stops rather than mutating GitHub
beside the winner. The record is shared across every linked worktree of this
repository, so a later invocation resolving a different `$DOCS_WT` still sees
it. `tools/tracker_transaction.py` is the whole mechanism — acquisition, every
transition, and the resolution check — and it is resolved from this plugin's
own bundle exactly as the publication helper is. Do not reimplement any part of
it, and never edit a transaction reference by hand. If
it cannot be resolved, created, read, or updated, stop before the first
irreversible action and report that; an unreadable transaction is never read as
no transaction.

**A disposition that mutates no tracker acquires nothing.** `[no-issue]` and
`[deferred]` make no tracker mutation, so they plan no steps and leave no
transaction outstanding. Acquiring one for them would block every later entry in
this document behind a record nothing could ever clear.

### Walk the ordered steps

Every approved tracker mutation is its own ordered step. Begin a step before its
external mutation runs and confirm it with the exact identity that mutation
returned before the next step starts; that gap is the only window in which a
mutation can be unaccounted for, and closing it is what this record is for.

```bash
python3 "$TRACKER_TX" \
  --repo "$DOC_REPO" --root "$DOCS_WT" --path "$DOC_RELATIVE_PATH" \
  --begin-step 0 --approved
# ... run exactly that one approved mutation ...
python3 "$TRACKER_TX" \
  --repo "$DOC_REPO" --root "$DOCS_WT" --path "$DOC_RELATIVE_PATH" \
  --confirm-step 0 --begin-token "$BEGIN_TOKEN" --identity - <<'IDENTITY'
{"kind": "issue-create", "id": "<number>", "url": "<url>",
 "document_token": "[#<number>]", "postcondition_verified": true}
IDENTITY
```

`$BEGIN_TOKEN` is the `begin_token` the `--begin-step` result returned. Keep it
for exactly this confirmation and pass it back. Only the run that began a step
may confirm it, and that token is the only evidence of having been it: it is
returned once and is not readable from the record, so a fresh session cannot
produce one and must reconcile instead. That is what stops an interrupted
mutation being adopted through the ordinary confirmation path, which asks for no
approval and matches no artifact. Losing the token costs a reconciliation, which
is the safe direction to fail.

An identity is the one its own kind of mutation actually has, and it must agree
with itself: a created issue or epic records its number, a URL naming that
number in `$DOC_REPO`, and the `[#N]` token the entry will carry; a label
records its name and the metadata it was created with, both of which must be the
exact approved values the plan carries as `approved_name` and
`approved_metadata`; a comment records its
comment ID and a URL naming that comment on the approved target in `$DOC_REPO`;
an edit to an existing artifact records that artifact's identity and the
verified post-edit fingerprint. Every one of those is bound to what was
approved rather than merely well-shaped: the URL is parsed as a canonical GitHub
URL in `$DOC_REPO`, an edit names its approved target, and a literal marker
names the artifact the disposition links, which the plan states as
`marker_target`: a linked child issue often has no approved comment, so its one
tracker mutation is the umbrella epic's checklist edit and there is no step from
which the link could be inferred. The document carries only `[#N]`, so
an identity free to name another repository's issue, another epic, or another
number would let a transaction clear against an artifact this run never
touched. Nothing but a created issue or epic contributes a token
the document must name.

Not every step returns an issue number and a URL, and the record does not
pretend otherwise: a label records its name and metadata, an issue its number
and URL, a comment its comment ID and URL, and an edit to an existing issue that
issue's identity plus the verified post-edit fingerprint. Each branch below is a
step of its own:

- **EPIC label creation.** The approved new arc label is a checkpointed step:
  begin it before `gh label create -R "$DOC_REPO"` and confirm it with the
  exact label name and metadata it created.
- **Epic creation.** Creating the umbrella epic is a checkpointed step:
  begin it before `gh issue create -R "$DOC_REPO"` and confirm it with the
  epic number and URL, which is the marker the `EPIC` ledger line carries.
- **Epic adoption edit.** Adopting an existing epic is a checkpointed step:
  begin it before the approved body edit and confirm it with the target issue
  identity and the verified post-edit fingerprint.
- **Child issue creation.** Creating the approved body with `gh issue create -R "$DOC_REPO" --body-file`
  is a checkpointed step: begin it before that call and confirm it with the
  number and URL it returned.
- **Child issue linking.** Linking an issue that already exists mutates nothing
  by itself, but this workflow always updates the umbrella epic's checklist for
  a linked child, so there is always at least that one step. The transaction
  plans only the mutations it really performs, and `marker_target` names the
  issue being linked — which is not any step's target, since the checklist edit
  targets the epic.
- **Approved comment.** Posting an explicitly approved comment is a checkpointed
  step: begin it before the comment is posted and confirm it with the comment ID
  and URL, then confirm the target still exists.
- **Umbrella epic checklist edit.** Updating the epic's child checklist with the
  actual `#N` is a checkpointed step: begin it before the edit and confirm it
  with the epic's identity and the verified post-edit fingerprint.

For `[no-issue]`, apply the approved removal or folding note. A deferral does not
change the epic checklist. Never make an unshown epic edit.

Then update exactly the selected ledger line in the design document:

- `[#N]`: check the box and append the confirmed tracker number;
- `[no-issue]`: check the box, append the approved concise reason, and add a
  visible disposition note under the delivery heading;
- `[deferred]`: leave the box unchecked, append the concrete precondition, and
  add a visible deferred note under the delivery heading.

Compose the complete updated design document as text, preserving all unrelated
design content and removing a stale deferred note when the item later advances;
do not write it to the file and do not stage it, since the publication step below
hands that text to the helper, which is the only writer of the document. Verify the selected key,
ledger checkbox/marker, unchecked count, epic checklist, and tracker metadata.

If a tracker mutation succeeds but a later step or the document mutation fails,
do not create anything else. The durable transaction record is where that state
lives — never the document, which this workflow does not write and the
publication helper alone owns. Report the tracker states beside the three
document states section 7 requires: whether acquisition succeeded, the
transaction state, each planned step and whether it is planned, ambiguous, or
confirmed, every confirmed tracker identity, and the one recovery action that is
permitted next. Reconcile it before the next entry.

## 7. Record the approved mutation

Hand the approved mutation to the publication helper in this same run. The
document is a durable cursor, and a cursor that only ever exists in one checkout
is resumable only from that checkout. This step is one more part of the
disposition that was already approved; it carries no second one, and it is never
batched or deferred merely to reduce commit or push frequency.

**This step is not a push.** It is how the document gets written at all — the
helper is the document's only writer. Whether that write ALSO lands on
`$DOC_BRANCH` is the helper's decision and not yours, and for most repositories
the answer is no: the mutation is applied to the docs worktree and left sitting
there, and the owner lands the accumulated edits in one batch later. That is the
designed outcome rather than a shortfall, so run this step even when you already
know publication will be declined. Skipping it leaves the entry unmarked and the
tracker transaction stranded, which is strictly worse than the thing you were
trying to avoid.

When a tracker transaction is open, record that it is being handed to
publication before you hand it over, so an interruption inside publication is
distinguishable from one before it:

```bash
python3 "$TRACKER_TX" \
  --repo "$DOC_REPO" --root "$DOCS_WT" --path "$DOC_RELATIVE_PATH" \
  --publication-pending
```

**Render the complete approved document and hand it over — do not write it
yourself.** `tools/publish_coordination_doc.py` is the only writer of the
document, and that is what keeps an edit somebody else makes beside this run out
of the published commit: the published bytes come from what you pass, never from
the working tree. Ask the helper for a scratch path, write the rendered
document there, and hand it back:

```bash
APPROVED="$(python3 "$PUBLISH_DOC" \
  --repo "$DOC_REPO" --root "$DOCS_WT" --path "$DOC_RELATIVE_PATH" \
  --new-content-file)"
python3 "$PUBLISH_DOC" \
  --repo "$DOC_REPO" --branch "$DOC_BRANCH" --root "$DOCS_WT" \
  --path "$DOC_RELATIVE_PATH" --content "$APPROVED" \
  --expected-tip "$PREFLIGHT_TIP" --expected-working-copy "$PREFLIGHT_COPY"
```

`$PREFLIGHT_TIP` is the `publication_tip` the preflight reported. Always pass
it: it is what binds this content to the document state it was rendered from,
and a `tip-moved` result means re-reading the document and rendering the
disposition again rather than publishing what you have.

**Never choose that path yourself.** A fixed name collides between any two
runs, and a name derived from the document collides between two runs of the
same one; either way a run reads the other's approved content and publishes it
under its own document's name. The helper mints a path unique to this
invocation, which is the property no naming convention here can promise.

Resolve the helper from this plugin's own bundle — the versioned copy installed
beside these instructions — and never from the session's own checkout,
a personal path, or an inline fallback. `$DOC_ROOT` stays exactly what it was:
the validated local checkout of the owning repository, which is where the helper
writes and never where the helper itself is found. These plugins install into
repositories that track no copy of it, so resolving the helper from the owning
repository fails closed in every repository but Kanban's own — which is the
defect that older wording mandated. A helper that cannot be resolved in the
bundle still fails closed: report that publication was not attempted and why,
and never publish by hand instead.

The helper owns the entire mechanism — eligibility, the per-document lock, the
baseline, isolation, the push, verification by reachability, and the resumption
of an unfinished earlier publication. Eligibility is the one part that is not
the same question in every repository, and the helper answers it rather than
you: for `coghex/kanban` it is §7 as the publication branch itself carries it,
and for every other owner it is that repository's own
`workflow.direct_publication_paths` declaration, which is empty until the
repository sets it — and NOT `workflow.coordination_paths`, which is the PR
drainer's merge exception and grants no publication lane. An empty lane is the
ordinary, intended configuration: it yields `not-published`, the approved
mutation is applied to the working copy and recorded, and the edits accumulate
in the docs worktree for a human to land in one batch. Do not treat that as a
failure of the run, never publish by hand to compensate for it, and do not
narrate it to the user. Do not reimplement, precede, or compensate for any part
of it. Act on the one structured result it returns:

- **`"status": "published"`.** Say so, and quote the commit it reports together
  with its changed-line summary. Check that summary against the disposition you
  applied: because the whole document is handed over, an unintended rewrite of
  the rest of it changes the same single path a correct publication does, and
  the summary is what makes the difference visible.
- **`"status": "not-published"`.** The document is not direct-publication
  eligible — it is `pr-atomic`, matched no §7 row, or belongs to a repository
  whose `workflow.direct_publication_paths` does not cover it. The approved
  mutation is not lost: the helper reports `approved_blob`, recoverable with
  `git cat-file -p`, and `document_written` says whether it also applied it to
  the document. `write_outcome` names which of the five cases the write was,
  rather than leaving `document_written` to stand for all of them:
  `applied-over-baseline`, `applied-over-local-predecessor`,
  `applied-over-preflight-copy`, `no-baseline`, and `unrecognized-working-copy`.
  A working copy byte-identical to what the helper last applied locally is its
  own unlanded write, and the approved mutation is applied on top of it — so
  successive approved mutations to a document its owner lands out of band
  accumulate rather than wedging on the first one. A document absent from the
  publication tip is applied over the working copy the preflight observed,
  provided it is still byte-identical to it — that is what `$PREFLIGHT_COPY`
  binds, and it is how a report processed before its owner's first batch landing
  takes its disposition like any other. A working copy that is none of those —
  neither the publication tip's content, the helper's own last write, nor, for a
  document absent from the tip, the copy the preflight observed — is never
  overwritten, and nothing is applied over it.

  `applied_record` is the other half of that. The helper records what it wrote
  in its own reference, and only `"recorded"` — with `applied_ref` naming that
  reference — lets a later run continue over the working copy or a transaction
  resolve from it. `"unrecorded"` means the write happened and the record did
  not, so no later run may write over that document and no transaction may
  resolve from it.

  **The ordinary outcome is reported by saying nothing about it.**
  `not-published`, with a `write_outcome` of `applied-over-baseline`,
  `applied-over-local-predecessor` or `applied-over-preflight-copy` and an
  `applied_record` of `"recorded"`, is the expected and healthy result: the
  approved mutation is in the working copy, recorded, and waiting for its owner
  to batch it, which is exactly where that owner wants it. So say nothing about
  publication, eligibility, lanes, worktrees, write roots, blobs, or what still
  has to happen for the edit to land — none of it is a decision the user has to
  make, and narrating a settled mechanism on every run makes a working workflow
  read like a recurring problem.

  **That silence is a rule about the report, not about the work.** Every step of
  this section still runs on that outcome — the helper is still invoked and its
  result is still inspected — and so does every step this workflow takes after
  it. Silence is what the run says at the end, never a step it skips.

  **Silence waits for the transaction.** An ordinary helper result does not end
  the run: the tracker transaction below is still resolved with `--resolve
  --source local`, and only a resolution that succeeds licenses the quiet
  report. A transaction this run could not resolve keeps its full failure and
  recovery report, however ordinary the publication result was.

  **An applied mutation is not durable until the document's owner lands it on
  the publication branch.** That fact governs what this workflow may do, not
  what it tells the user: it is why publishing by hand to compensate is
  forbidden and why every outcome named below is reported out loud. On the
  ordinary outcome it is not part of the report.

  **Every other outcome keeps its full report.** A `write_outcome` of
  `no-baseline` or `unrecognized-working-copy` means nothing was applied and the
  approved mutation survives only as `approved_blob`; an `applied_record` of
  `"unrecorded"` means the write cannot be proven and no later run may build on
  it. `no-baseline` on a document that exists means the working copy moved after
  the preflight observed it, or the binding was not passed: re-read the
  document, render the disposition again, and hand it over with a fresh
  preflight's binding. Each of those needs the write root, the document path,
  and the preserved `approved_blob` named plainly, because the mutation is not
  where the next run will look for it. A `"published"` status and any other
  status keep the reports described beside them for their own reasons — a
  publication is verified success with a changed-line summary the run has to
  check, and an unmodelled status is a failure whose three states are the only
  account of where the document went.
- **Any other status.** The document was not published. Report the three states
  the helper returns — whether the edit exists locally and in which worktree and
  path, whether a local publication commit exists and its ID, and whether the
  remote publication branch contains it — and say plainly which one applies.
  Leave the document as the helper left it.

### Resolve the tracker transaction

A tracker transaction is cleared by the published entry itself, never by the
fact that a commit landed. Reachability proves a commit reached the branch; it
proves nothing about whether that commit carried this disposition:

```bash
python3 "$TRACKER_TX" \
  --repo "$DOC_REPO" --root "$DOCS_WT" --path "$DOC_RELATIVE_PATH" \
  --resolve --source branch --branch "$DOC_BRANCH"
```

The module verifies that the recorded entry key's own terminal `- [x]` entry in
the document's at-a-glance index on `$DOC_BRANCH` carries the recorded
disposition and every exact tracker identity that disposition requires the
document to name, and clears the record only then. It looks in that index alone,
because a checked task in a finding's body, in a fenced example, or nested
beneath the real entry is not the cursor. An entry still `- [ ]`, an incidental mention in prose, and a
terminal entry carrying `[no-issue]` or `[deferred]` beside the link are each
refused: the first is the interrupted run's own signature, the second is not the
cursor at all, and the third is a different disposition from the recorded one. On a `not-published`
result whose `applied_record` is `"recorded"` — the ordinary outcome for a
`pr-atomic`, unmatched, or not-yet-tracked document — run the same verification
against the applied local document with `--source local --branch
"$DOC_BRANCH"`, which is the only evidence there is and a legitimate terminal
state for such a document.
Whether the working tree is admissible at all is the module's decision, not
yours. It classifies the document itself and refuses a local resolution for one
that publishes to the branch, because clearing such a record from a locally
edited cursor would leave the next preflight clear while the entry never landed.
It also checks the document against the publication module's own record of what
that module applied, since classification says only that publication *would* be
declined — a file somebody edited by hand looks the same from there. A document
the module never wrote, or one changed since it did, resolves nothing — and a
write the module could not record is one it can no longer prove it wrote,
however plainly this run watched itself make it. When `document_written`
is false, nothing carries the disposition anywhere: the record stays
outstanding, and this run reports it; an `applied_record` of `"unrecorded"`
leaves it exactly as outstanding.

**A stranded transaction has a bounded recovery.** Reporting it is not the end
of the line, and hand-editing a reference is never how it ends. Recover the
`approved_blob`, land the terminal document through the owner's ordinary
out-of-band or pull-request lane, and then resolve the record with `--source
branch`. Never repeat a confirmed tracker mutation and never clear a reference
by hand while that recovery is pending: the record already carries every
identity the recovered document must name, and a repeated mutation files a
second artifact nobody can take back.

A record this run could not resolve stops the next one, which is what it is for.
Report it rather than clearing it, and never clear a transaction reference by
hand. Where nothing landed at all, the user may explicitly approve abandoning an
`intent-only` or `tracker-pending` transaction against authoritative read-only
evidence that none of its unconfirmed mutations reached GitHub — and this run
still names every mutation that was already confirmed, because those exist and
the document never recorded them.

**A recorded publication is resolved before any new disposition.** When the
helper reports `pending-unresolved` or `pending-differs-from-approved`, an
earlier approved mutation of this document has not reached the branch. Do not
apply a second disposition over it and do not create tracker items for one:
resolve that record first, or the run you just approved will be reported
published while its mutation is absent from the document.

Recording the mutation ends this entry. Do not select another.

On the ordinary outcome the closing report is the disposition and the counts
below and nothing else: where the document was written, whether it reached the
branch, and what still has to happen to it are the recording step's business,
and on its ordinary outcome that step reports itself by saying nothing.

Report the disposition and tracker URL, the ledger line as it now reads, and
the remaining unchecked count. Stop after this one entry. Advance only on a
later explicit invocation of `/process-design-doc`.

## Approval and mutation boundaries

- Approval is per epic or per child, never for the remaining batch. A broad
  statement such as "make the whole epic" does not waive one-at-a-time signoff
  unless the user explicitly changes this workflow.
- Revisions do not imply approval. Re-present the complete artifact and exact
  side effects, then stop again.
- Do not create or edit tracker items, labels, or comments before approval.
- Beyond the recording step in section 7, do not commit, push, open a PR, or
  modify implementation code unless separately requested.
