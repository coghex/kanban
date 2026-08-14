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

## Human interaction and decision authority

This is a human-led tracker-design workflow, not an autonomous issue generator.
Read-only investigation can establish facts, but the user owns every
interpretation, design choice, issue boundary, disposition, and external
mutation.

- Agent-authored directions are **Proposals**, never **Decisions**, and this
  workflow changes a `D-N` entry only on explicit user approval — never as a
  side effect of drafting. If repository or tracker evidence exposes an
  unresolved choice or contradicts a signed-off decision, stop and return the
  document to `$design-epic` instead of quietly repairing the design inside an
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

**Lock the document, then scan it against the publication tip, before choosing
an entry.** Order matters here as much as the checks do. Resolve the document
path first, in the numbered steps below, then:

```bash
git -C "$DOCS_WT" fetch origin "$DOC_BRANCH"
PUB_TIP="$(git -C "$DOCS_WT" rev-parse "origin/$DOC_BRANCH")"
PUB_KEY="${DOC_RELATIVE_PATH//\//-}"
PUB_LOCK="refs/kanban/publish-lock/$PUB_KEY"
PUB_PENDING="refs/kanban/pending-publication/$PUB_KEY"
git -C "$DOCS_WT" update-ref "$PUB_LOCK" "$PUB_TIP" ""
git -C "$DOCS_WT" diff --name-only "$PUB_TIP" -- "$DOC_RELATIVE_PATH"
```

**The lock is acquired before the baseline is validated, not after.** A "the
document is clean" answer is a statement about one instant, and it is only
still true later if nothing could have written in between. Validating first and
locking second leaves exactly that gap: a person or another tool edits the
document after the comparison and before the lock, and this run then hashes and
publishes the foreign hunk together with its own approved disposition — the
re-hash matches, because it was taken after the edit, and the one-path check
matches, because both changes are in one file. Locking first makes the clean
answer durable for as long as the run needs it.

The empty third argument is what makes acquisition exclusive: `update-ref`
requires the ref to be absent, and creating it is atomic, so exactly one run
wins. A failure means another run is mid-publication on this same document — do
not edit it, do not publish, and say which document is locked. Release it once
publication has succeeded or failed, on every path out, including every path
below that stops early:

```bash
git -C "$DOCS_WT" update-ref -d "$PUB_LOCK"
```

The lock holds a commit ID rather than being empty, so a lock a dead run left
behind is inspectable with `git for-each-ref refs/kanban/` and cleared with the
same `-d` once the user confirms no run is active. It is a ref in the docs
worktree's own repository, so it never touches the tracked tree and no
publication can carry it. What it cannot do is exclude an edit made outside this
protocol entirely; that is what the re-hash before the push, and the one before
the reconciliation, are for.

That comparison then decides what this run may do at all:

- **Empty.** The document equals the publication tip. Select normally; this
  run's own edit is then the only difference, which is exactly what lets its
  publication carry the approved mutation and nothing else.
- **Prints the document.** Something is already there, and only an exact match
  with a recorded pending publication may be resumed:

  ```bash
  git -C "$DOCS_WT" rev-parse --verify --quiet "$PUB_PENDING" \
    && [ "$(git -C "$DOCS_WT" hash-object -- "$DOCS_WT/$DOC_RELATIVE_PATH")" \
      = "$(git -C "$DOCS_WT" rev-parse "${PUB_PENDING}:${DOC_RELATIVE_PATH}")" ]
  ```

  When that succeeds, an earlier run applied and marked its disposition and
  failed only at publication, and the document is byte-for-byte the content that
  run approved. Re-attempt the publication step below against it, never repeat
  the tracker mutation, and select no new entry this run.

  When it fails — no pending record at all, or a document that no longer matches
  the one recorded — the document carries something other than exactly that
  approved mutation, so **publication is impossible this run**: the commit is
  built from the whole blob and would carry the extra work too, invisibly to the
  one-path check, which sees a single changed path either way. **A terminal
  marker is not sufficient evidence on its own**, because it records that some
  disposition was applied and says nothing about what has been written since;
  only the recorded blob identifies the pending mutation. Say so before applying
  anything, name what the document carries beyond the recorded mutation, release
  the lock, and let the user decide whether to reconcile first. Never publish
  anyway, and never discard the other work to make publication possible.

**This scan is the one deliberate exception to the selection rule below, which
never selects a terminal-marked entry.** The entry being resumed is already
marked — that is what an applied disposition looks like — so normal selection
would skip it forever and the failed publication would never be retried. That
marker and an existing local publication commit are the only evidence used here;
a durable journal or cross-system reconciliation is deliberately not part of
this workflow.

1. Resolve an explicit or conversation-linked path under `$DOCS_WT`, never
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
   use `design-epic` to finish or normalize it.
   Also verify that `EPIC` is first, every stable slice ID appears exactly once
   in the ledger and once in the delivery plan, ledger order matches delivery
   order, every dependency ID exists, and the dependency graph is acyclic. A
   mismatch returns to `design-epic`; do not guess which representation wins.
4. Select the unprocessed `EPIC` entry first. After the epic is linked, scan
   child entries from top to bottom and select the first non-terminal entry when
   its dependencies are terminal and, for `[deferred]`, its stated precondition
   is now verified. This ledger order is also issue creation order; do not let a
   newly unblocked later item jump ahead of earlier critical-path work. The unfinished-publication scan above is the one deliberate exception to this rule: it re-attempts publication for an entry that is already terminally marked, and selects no new work.
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
4. Verify the ledger edit, publish it through section 7, and stop. Do not
   draft the first child.

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

- **New issue:** create the approved body with `gh issue create -R "$DOC_REPO" --body-file` and
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

## 7. Publish the approved mutation

Publish the approved mutation in this same run. The document is a durable
cursor, and a cursor that only ever exists in one checkout is resumable only
from that checkout. Publication is one more step of the disposition that was
already approved; it carries no second one, and it is never batched or deferred
merely to reduce commit or push frequency.

**One pin, established before the edit and never refreshed.** `$PUB_TIP` was
pinned by the scan in step 1, and the document was validated equal to it there,
before the disposition was applied. That pairing is the entire basis for
publishing: the local blob is *that* tip's content plus this run's approved
mutation, so it is a safe publication onto that tip and onto no other.

**Do not fetch again here, and do not re-pin.** A refreshed pin silently changes
what the blob means. If the remote advanced this same document between the scan
and now, the local blob is the *old* content plus the approved edit; building it
onto the newer tip produces a one-path change that passes every gate below while
erasing the concurrent edit — a lost update no check downstream can see, because
the commit looks exactly like a correct publication. Keeping the original pin
turns that case into a plain non-fast-forward rejection instead: `$PUB_COMMIT`'s
parent is no longer the branch tip, so the push fails closed and the mutation
stays recoverable.

Everything below therefore names `$PUB_TIP`, never `origin/$DOC_BRANCH`, until
the verification step deliberately refetches to learn whether the push landed —
and that step reads the refreshed remote without ever reassigning the pin.

**Eligibility.** Publishing at all requires the `$DOC_REPO`, `$DOC_BRANCH`, and
`$DOC_ROOT` the ownership step resolved; an owner or publication branch that
could not be verified fails closed and the document stays unpublished. Two
further conditions hold, because a repository-relative path is not by itself an
eligibility signal — the same path exists in other repositories, and in other
states of this one:

1. **The owner is Kanban itself.** §7 is Kanban's own statement about Kanban, so
   `coghex/kanban` is the only repository with a `coordination` lane through
   this workflow. A consuming repository is never published to here, and neither
   is a fork, even when it tracks a contract of its own carrying a matching row;
   those documents are somebody else's to publish.
2. **The classification comes from the branch being published to.** The local
   checkout is not the authority on it: a dirty, stale, or unmerged `$DOC_ROOT`
   can classify a path `coordination` when the publication branch does not, and
   the publication commit is built on that branch rather than on the checkout.
   §7 is read out of `$PUB_TIP` — the exact state being published onto.

```bash
[ "$DOC_REPO" = "coghex/kanban" ] \
  && git -C "$DOCS_WT" show "${PUB_TIP}:docs/agent-workflow-contract.md" \
    | awk -v want="$DOC_RELATIVE_PATH" '
        /^## 7\. Document publication classification$/{sec = 1; next}
        (sec) && /^## /{exit}
        (sec) && $1 == want && $2 == "|" && $3 == "coordination"{ok = 1; exit}
        END{exit !ok}'
```

That pipeline **is** the eligibility test, not a display of §7 for a human to
read. It exits zero only when the pinned tip's own §7 carries a `coordination`
row for exactly this path, and it is anchored to the §7 heading so no other
table in that document can satisfy it. An owner that is not `coghex/kanban`, a
publication branch carrying no such contract at all, a `pr-atomic` path, and a
path no §7 row matches all leave it nonzero: `pr-atomic` is the fail-closed
default for an unmatched path. When the document is not direct-publication
eligible, leave the edit in place and recoverable, say plainly that it was not
published and why, and stop there.

**Every check in this section is a control-flow gate, never a standalone
command whose result nothing consumes.** A predicate written on its own line
fails silently into the next line, and the next line here pushes, checks out, or
fast-forwards. So each one is chained: the owner test gates the classification
read above, both gate the push below, and the remote-ancestry check gates the
reconciliation after it. Run them as written rather than as a list of steps to
work through in order.

**A publication carries the single approved mutation to the one eligible
document and nothing else** — no unrelated dirty paths, no earlier `docs-wip`
commits, no unrelated changes already present in the same document, and no
second disposition. If the approved mutation cannot be isolated from other
changes, publication fails closed: publish nothing, discard nothing, and report
what else the document carries. Two separate mechanisms enforce that, because
they catch failures neither can see alone — the precondition below excludes a
difference already present in the same file, and the one-path check on the built
commit excludes a second path.

**The document must match the pinned tip before this run edits it.** This is
what makes the published commit provably the approved mutation and nothing else,
and it is checked in step 1 before the disposition is applied — not here, where
it would be too late:

```bash
git -C "$DOCS_WT" diff --quiet "$PUB_TIP" -- "$DOC_RELATIVE_PATH"
```

The publication commit is built from the document's whole blob, so any
difference the document already carried is published along with the approved
one — and because that difference sits in the same file, the one-path check
below cannot see it. Three outcomes:

- **Clean.** The document equals the pinned tip. Apply the disposition; the only
  difference afterwards is this run's approved mutation, so publishing the blob
  publishes exactly that.
- **Differs, and the entries it changed already carry their `[#N]`,
  `[no-issue]`, or `[deferred]` markers.** An earlier run applied and marked its
  disposition but failed to publish it. Resume that publication, as step 1
  describes, and select no new entry.
- **Differs otherwise.** The document carries work this run did not make.
  **Publication is impossible for this run** and fails closed: build no commit
  and push nothing. Say so before applying anything, name what the document
  already carries, and let the user decide whether to proceed with an
  unpublished disposition or reconcile first. Never publish anyway, and never
  discard the other work to make publication possible.

**Publish with a fast-forward and nothing else.** Build the publication commit
from the pinned tip with exactly that one blob replaced, so no local branch
moves and no other path can be swept in, then push it plainly:

```bash
PUB_BLOB="$(git -C "$DOCS_WT" hash-object -w -- "$DOCS_WT/$DOC_RELATIVE_PATH")"
PUB_INDEX="$(git -C "$DOCS_WT" rev-parse --git-path "kanban-publish-index-$PUB_KEY-$PUB_BLOB")"
GIT_INDEX_FILE="$PUB_INDEX" git -C "$DOCS_WT" read-tree "$PUB_TIP"
GIT_INDEX_FILE="$PUB_INDEX" git -C "$DOCS_WT" update-index --add \
  --cacheinfo "100644,$PUB_BLOB,$DOC_RELATIVE_PATH"
PUB_TREE="$(GIT_INDEX_FILE="$PUB_INDEX" git -C "$DOCS_WT" write-tree)"
PUB_COMMIT="$(git -C "$DOCS_WT" commit-tree "$PUB_TREE" \
  -p "$PUB_TIP" -m "docs: <the approved mutation, one line>")"
[ "$DOC_REPO" = "coghex/kanban" ] \
  && git -C "$DOCS_WT" show "${PUB_TIP}:docs/agent-workflow-contract.md" \
    | awk -v want="$DOC_RELATIVE_PATH" '
        /^## 7\. Document publication classification$/{sec = 1; next}
        (sec) && /^## /{exit}
        (sec) && $1 == want && $2 == "|" && $3 == "coordination"{ok = 1; exit}
        END{exit !ok}' \
  && [ "$(git -C "$DOCS_WT" hash-object -- "$DOCS_WT/$DOC_RELATIVE_PATH")" \
    = "$PUB_BLOB" ] \
  && [ "$(git -C "$DOCS_WT" diff --name-only "$PUB_TIP" "$PUB_COMMIT")" \
    = "$DOC_RELATIVE_PATH" ] \
  && git -C "$DOCS_WT" push origin "${PUB_COMMIT}:refs/heads/${DOC_BRANCH}"
```

The re-hash in that chain is the lock's backstop: `$PUB_BLOB` is the content
this run approved and built its commit from, so a file that no longer hashes to
it changed after the disposition was applied. Inside the lock that can only be
something outside this protocol — a person editing the document, another tool —
and publishing it would carry a change nobody approved. It costs one hash and
turns "the lock should have prevented this" into a check.

Nothing above the push leaves the object store: `hash-object`, `write-tree`, and
`commit-tree` write unreferenced objects and move no branch, so building a
commit for an ineligible document changes nothing anywhere. The push is the
single external effect, and it re-tests the owner **and** the classification
against the same pinned tip the commit was built from, so neither an ineligible
owner nor a `pr-atomic` document can reach it even if the eligibility gate above
was somehow skipped.

The scratch index is named for the document's path as well as its content, so
no two concurrent publications in one docs worktree share it: two different
documents differ by path even when their contents hash identically, and two runs
that agree on both path and content would build the same tree anyway. That
removes the interleaving; it does not license trusting it. **The push is gated
on the one-path check, not merely preceded by it** — `diff --name-only` must
print exactly `$DOC_RELATIVE_PATH`, and a second path from any source leaves the
`&&` unsatisfied so nothing is pushed. Verify the isolation on the artifact
rather than trusting the construction that produced it, and never run the push
as an unconditional next line.

Never force-push, never reset, and never overwrite a concurrent advance of
`$DOC_BRANCH` or resolve a conflict by guessing. A non-fast-forward rejection, a
conflict, or a branch that moved under the run leaves the mutation recoverable
and is reported as an unpublished failure. Recoverable never means a commit left
on the local default branch of a checkout the PR drainer fast-forwards; the
commands above cannot produce one, because `commit-tree` moves no branch and a
rejected push leaves the mutation exactly where it already was.

**Verify before calling it published.** The publication landed if and only if
the intended commit is reachable from the remote publication branch:

```bash
PUB_PUBLISHED=no
git -C "$DOCS_WT" fetch origin "$DOC_BRANCH"
git -C "$DOCS_WT" merge-base --is-ancestor "$PUB_COMMIT" "origin/$DOC_BRANCH" \
  && PUB_PUBLISHED=yes

[ "$PUB_PUBLISHED" = yes ] && git -C "$DOCS_WT" update-ref -d "$PUB_PENDING"
[ "$PUB_PUBLISHED" = no ] \
  && git -C "$DOCS_WT" update-ref "$PUB_PENDING" "$PUB_COMMIT"

PUB_RECONCILED=no
[ "$PUB_PUBLISHED" = yes ] \
  && [ "$(git -C "$DOCS_WT" hash-object -- "$DOCS_WT/$DOC_RELATIVE_PATH")" \
    = "$PUB_BLOB" ] \
  && git -C "$DOCS_WT" checkout "origin/$DOC_BRANCH" -- "$DOC_RELATIVE_PATH" \
  && PUB_RECONCILED=yes
[ "$PUB_RECONCILED" = yes ] \
  && [ "$(git -C "$DOCS_WT" rev-parse --abbrev-ref HEAD)" = "$DOC_BRANCH" ] \
  && git -C "$DOCS_WT" merge --ff-only "origin/$DOC_BRANCH"
```

**An unpublished mutation records what it approved, so a later run can identify
it.** `$PUB_PENDING` is set to this run's publication commit on failure and
deleted on success, and the deletion is idempotent, so a run that never failed
clears nothing. The commit is a durable statement of the exact content this run
approved — a later run reads the blob back out of it with
`git rev-parse "${PUB_PENDING}:${DOC_RELATIVE_PATH}"` and resumes only on an
exact match. Without it, resumption would rest on the terminal marker alone,
which cannot distinguish the approved mutation from anything written into the
same file afterwards.

**Ancestry alone is the verdict, and comparing the local file to the branch must
play no part in it.** Someone else can advance `$DOC_BRANCH` with their own edit
to this same document between the push and the check. The commit still landed —
it is an ancestor — but the local copy no longer equals the branch. Folding that
comparison into the verdict would report a successful publication as failed, and
the next run's scan would then read the local copy as a pending mutation and
republish it *over* the concurrent edit. That is why `PUB_PUBLISHED` is set by
`merge-base --is-ancestor` and by nothing else.

**The reconciliation is itself gated on the document still being the approved
blob.** `checkout` overwrites the working copy and the index for that path, so
running it unconditionally discards whatever the file holds — and after the push
gate that can be an edit somebody made outside this protocol, which was never
approved and never published. The lock deliberately cannot exclude those, so the
reconciliation re-checks the hash and simply does not run when it fails: the
publication is still reported as succeeded, the foreign edit is left exactly
where it is, and the report says the local copy was not reconciled and why.
`PUB_RECONCILED` also gates the fast-forward, so a skipped reconciliation cannot
be followed by a branch move that assumes it happened.

The reconciliation that follows is the other half of the same reasoning. It runs
only when the publication is confirmed, and it moves the local document **to**
the branch rather than the other way round: `checkout` takes whatever
`$DOC_BRANCH` now holds, which already contains this run's landed mutation and
any concurrent edit on top of it. Nothing is lost and nothing stale is replayed.
It also restores the invariant the next run depends on — the document equals the
publication tip — so a later scan correctly reads "nothing pending". The
path-scoped `checkout` touches only `$DOC_RELATIVE_PATH`, so unrelated work in
that checkout survives, and the fast-forward applies only when `$DOCS_WT` fell
back to the checkout sitting on `$DOC_BRANCH`, where the published edit would
otherwise keep the branch behind its remote; a `docs-wip` worktree is on its own
branch and the chain simply stops at the branch test, which is a normal success,
not a failure. Never force either one, and never `reset`.

Say the document is published only when `PUB_PUBLISHED` is `yes`, and treat
every other outcome as an unpublished failure. **Report all three states on any
failure**, rather than collapsing them: whether the document edit exists locally
and in which worktree and at which path; whether a local publication commit
exists and, if so, its commit ID; and whether the remote publication branch
contains that commit. Name where the mutation was retained.

Report the disposition and tracker URL, the ledger line as it now reads,
whether the mutation was published — with the commit ID when it was and the
three states above when it was not — and the remaining unchecked count. Stop after this one entry. Advance only on a
later explicit invocation of `process-design-doc`.

## Approval and mutation boundaries

- Approval is per epic or per child, never for the remaining batch. A broad
  statement such as "make the whole epic" does not waive one-at-a-time signoff
  unless the user explicitly changes this workflow.
- Revisions do not imply approval. Re-present the complete artifact and exact
  side effects, then stop again.
- Do not create or edit tracker items, labels, or comments before approval.
- Do not commit, push, open a PR, or modify implementation code beyond the
  publication step in section 7 unless separately requested.
