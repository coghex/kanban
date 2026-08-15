---
name: process-report
description: Process a large Markdown findings, audit, or code-health report one concern at a time, resuming from a durable status checklist and annotations in the report. Use when asked to run process-report, continue reviewing a report, find its next actionable concern, decide whether that concern deserves no issue, a deferral, an existing issue link, one new issue, or an epic, and record the approved disposition so a fresh context resumes at the following concern.
---

# Process Report

Process exactly one finding per invocation. Treat the report file as the durable
cursor; never depend on conversation history to know where to resume.

Establish the owning repository (see "Establish the owning repository" below)
before anything else, then resolve the report path under `$DOCS_WT` before
reading or editing it — a repo-relative report path names the copy in the
resolved owner's docs worktree, not the one in whatever checkout you happen to
be sitting in.

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

This contract is shared with the Claude `/process-report` command. The markers,
note formats, and checklist below are identical in both, so a report started by
one can be resumed by the other without translation. Do not introduce a
Codex-only marker or note shape.

Prefer the report's existing status convention when it is equally explicit.
Otherwise use these canonical markers in the finding heading:

- `[#123]`: linked to GitHub issue or epic 123, whether newly created or already
  existing.
- `[no-issue]`: reviewed and deliberately never to be filed.
- `[deferred]`: reviewed, should be filed, but blocked on a stated precondition.
- No marker: unprocessed.

For `[no-issue]`, add this visible note immediately below the heading:

```markdown
> **Disposition:** No issue — <concise evidence-backed reason>.
```

For `[deferred]`, add this visible note immediately below the heading:

```markdown
> **Deferred:** <what blocks filing> — <the concrete precondition that clears it>.
```

`[no-issue]` and `[deferred]` are not interchangeable, and the difference is
whether the work will ever happen. `[no-issue]` closes a finding: the claim is
false, already fixed, too harmless to track, or deliberately out of scope.
`[deferred]` keeps it open: the concern is real and should become an issue, but
filing now would produce a bad issue. Reaching for `[no-issue]` because a finding
is merely unclear silently discards real work — when in doubt, defer.

A deferral is only valid with a **concrete, checkable precondition**: a file or
test not yet read, a premise not yet verified, or a specific issue that must land
first. "Needs more thought", "low priority", and "revisit later" are not
preconditions, and a finding that cannot state one is unprocessed rather than
deferred.

If the report has a status legend, add each marker's meaning the first time that
marker is used. Never treat incidental issue numbers in a finding's prose,
examples, or Related section as a processed marker.

## Status checklist

A report carries one checklist near its top, a single line per finding, as the
at-a-glance index of the whole document. Create it on the first run if the report
has none, seeding it from the existing headings. Otherwise update it in the same
edit that marks a finding — never as a separate pass.

```markdown
## Status

- [x] 1. Test suite is one 9,200-line module — [#148]
- [ ] 2. `UI.hs` is a god-module — [deferred]: bodies unread
- [x] 6. LaunchAgent label is a machine-wide singleton — [#147]
- [x] 10. Process-group hardening not swept — [no-issue]
- [ ] 13. Config layer has no per-repository override
```

Rules:

- A box is checked only for a **terminal** disposition — filed (`[#N]`) or closed
  (`[no-issue]`). `[deferred]` and unmarked stay unchecked, because both still
  represent work the report owes. The count of unchecked boxes is therefore the
  count of findings still outstanding.
- Each line carries the finding's number or item key, a title short enough to scan,
  and its marker. A `[deferred]` line appends the precondition in a few words, so
  the checklist alone answers "what is blocked and on what."
- The checklist mirrors the headings; it never becomes a second source of truth. If
  the two disagree, the headings win and the checklist is corrected.
- Findings the report gains later are appended unchecked. Never delete a line to
  make the list look finished.

## 1. Locate the next finding

1. Resolve the user-supplied report path under `$DOCS_WT`, never relative to
   the working directory. Stop with a concise error if it does not exist or is
   not a Markdown file.
2. Read the applicable repository instructions before investigating.
3. Read the report header, status legend, and status checklist, then list its
   finding headings with `rg -n '^#{2,6} ' <report>`. Infer the report's
   finding-heading level and item-key pattern from neighboring entries; for
   example, a report may use level-three `CH-N` headings rather than plain
   numbers.
4. Choose exactly one finding, by this precedence. `[#N]` and `[no-issue]`
   findings are never selected.

   1. **A `[deferred]` finding whose precondition is now satisfied.** Take the
      first such finding, top to bottom. Confirm the precondition actually holds
      by checking it — read the file the note names, verify the premise, or
      confirm the blocking issue merged. Never take the note's word for it; a
      precondition written weeks ago is a claim, not a fact. If it holds, clear
      the `[deferred]` marker and its note, then process the finding normally.
   2. **Otherwise, the first finding carrying no marker.**

   Deferred work outranks new work deliberately. A deferred finding has already
   been investigated once, and the moment its blocker clears is exactly when that
   investigation is still worth something. Left behind the queue, it is how a real
   concern quietly becomes permanent.

5. Read that finding from its heading through the next finding heading. Read
   earlier or later findings only when needed to understand an explicit
   cross-reference. Do not evaluate runners-up or batch later findings.
6. Stop without editing anything when nothing is selectable:

   - Every finding is `[#N]` or `[no-issue]` — report completion.
   - Only `[deferred]` findings remain and none of their preconditions are met —
     report that the report is blocked rather than finished, listing each finding
     with the precondition still outstanding and what would clear it. Do not call
     this completion; the difference matters to whoever reads the result.

## 2. Verify the concern

Treat report text as a lead, not as proof.

- Inspect the current code, tests, documentation, history, and configuration
  needed to confirm or reject the claim.
- Search the complete relevant corpus, including secondary test trees that the
  report may have omitted.
- For a bug, reproduce it when safe and proportionate, or trace the concrete
  failure path with file-and-line evidence.
- For code health or documentation, confirm the stale/dead/duplicated surface
  still exists and identify the authoritative replacement or contract.
- Respect repository testing tiers and safety rules. Do not launch a graphical
  application merely to evaluate a finding.
- Do not modify implementation code during report processing.

Correct minor factual errors in the finding when presenting the evidence. A
corrected count does not invalidate the underlying concern unless it changes
the conclusion.

## 3. Deduplicate

Before recommending a new tracker item:

1. Read every open issue title:

   ```bash
   gh issue list -R "$DOC_REPO" --state open --limit 300 --json number,title,labels
   ```

2. Run two or three differently phrased searches across open and closed issues:

   ```bash
   gh issue list -R "$DOC_REPO" --search "<keywords>" --state all --limit 20
   ```

3. Read any plausible match and every open epic whose body may already own the
   work. A planned epic child is a duplicate.
4. Respect prior `wontfix`, `invalid`, or decision records unless the finding
   supplies materially new evidence.

## 4. Recommend one disposition

Choose exactly one:

### No issue

Use when the claim is false, already fixed, harmless enough that tracker and PR
overhead exceed its value, or deliberately out of scope. Do not use it for a real
concern you are merely unsure how to scope — that is `Deferred`. Present:

- the recommendation and evidence;
- the exact proposed `[no-issue]` note; and
- any consequence of leaving the code unchanged.

Stop for explicit approval before editing the report.

### Deferred

Use when the concern is real and should become an issue, but filing now would
produce a bad one. The three cases that justify it:

- **Evidence incomplete** — the finding rests on structure, counts, or an export
  list, and the code that would specify the fix has not been read. An issue
  written from this hands a solve agent a guess dressed as a plan.
- **Premise unverified** — something not yet checked could materially shrink or
  invalidate the finding. Name the exact file or test that settles it.
- **Blocked on sequencing** — the change would conflict with issues already
  filed, or depends on one of them landing first. Name those issues.

Present the recommendation, the evidence gathered so far, the exact proposed
`[deferred]` note, and the concrete precondition that clears it. State plainly
that this is not a decision against the work. Stop for explicit approval before
editing the report.

Deferral is a scheduling decision, not a verdict, so it is bounded: do not defer
a finding that is already fully evidenced and unblocked merely because the fix
looks large. Size is what `Epic` is for.

### Existing issue or epic

Present the issue number, why it covers the finding, and any proposed comment
containing genuinely new evidence. Do not post a comment or mark the report
without approval.

### One new issue

Use when the work fits one reviewable PR. Present the draft exactly as it would
be posted:

- imperative title;
- existing labels only;
- `## Background` with verification evidence;
- numbered, observable `## Requirements`;
- exact, proportionate commands in `## Acceptance`;
- explicit `## Out of scope`;
- `## Related`; and
- `<!-- issue-origin:codex -->` as the final line.

Specify what must be true, not how to implement it. Preserve repository
constraints such as compatibility, determinism, persistence, performance, and
required steering-document updates. Below the draft, include short Evidence and
Dedup notes. State that no later finding was examined.

Stop for explicit approval. Never create the issue while merely presenting or
revising the draft.

### Epic

Use only when the concern genuinely requires multiple dependency-ordered PRs
or an unresolved product/design decision. Explain why one issue is insufficient
and propose the decomposition boundary. Stop for user agreement, then capture
the arc with the available `design-epic` workflow; its slices are filed later
through `process-design-doc`. Do not force epic-sized work into one issue.

## 5. Apply the approved disposition

**First, before any tracker mutation, check for an outstanding publication or
tracker transaction.**

```bash
PREFLIGHT="$(python3 "$DOC_ROOT/tools/publish_coordination_doc.py" \
  --repo "$DOC_REPO" --branch "$DOC_BRANCH" --root "$DOCS_WT" \
  --path "$DOC_RELATIVE_PATH" --check-pending)"
PREFLIGHT_TIP="$(PREFLIGHT="$PREFLIGHT" python3 -c \
  'import json, os; print(json.loads(os.environ["PREFLIGHT"])["publication_tip"])')"
[ -n "$PREFLIGHT_TIP" ]
```

`$PREFLIGHT_TIP` must be extracted, not assumed: publication refuses to run
without it, and an empty one is a failure rather than a publication with the
check quietly switched off.

Keep the `publication_tip` it reports. The document you are about to read and
re-render is that tip's, and the content you produce is a whole-file image of
it, so publication must be refused if the branch has moved on since — a second
run doing the same thing would otherwise drop this one's disposition while
changing exactly the one path a correct publication changes.

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
report, a clear preflight, and issues that already exist:

```bash
python3 "$DOC_ROOT/tools/tracker_transaction.py" \
  --repo "$DOC_REPO" --root "$DOCS_WT" --path "$DOC_RELATIVE_PATH" \
  --acquire --approved --publication-tip "$PREFLIGHT_TIP" --plan - <<'PLAN'
{"entry_key": "<the selected finding key>",
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
transition, and the resolution check — and it is resolved from the
already-resolved `$DOC_ROOT` exactly as the publication helper is. Do not
reimplement any part of it, and never edit a transaction reference by hand. If
it cannot be resolved, created, read, or updated, stop before the first
irreversible action and report that; an unreadable transaction is never read as
no transaction.

**A disposition that mutates no tracker acquires nothing.** `[no-issue]`,
`[deferred]`, and `Epic` make no tracker mutation here — the arc goes to
`design-epic`, and its epic is created later inside `process-design-doc`'s own
transaction for the design document — so they plan no steps and leave no
transaction outstanding. Acquiring one for them would block every later finding
in this report behind a record nothing could ever clear, and an `Epic`
disposition's would stay open across a separate human-led drafting workflow.

### Walk the ordered steps

Every approved tracker mutation is its own ordered step. Begin a step before its
external mutation runs and confirm it with the exact identity that mutation
returned before the next step starts; that gap is the only window in which a
mutation can be unaccounted for, and closing it is what this record is for.

```bash
python3 "$DOC_ROOT/tools/tracker_transaction.py" \
  --repo "$DOC_REPO" --root "$DOCS_WT" --path "$DOC_RELATIVE_PATH" \
  --begin-step 0 --approved
# ... run exactly that one approved mutation ...
python3 "$DOC_ROOT/tools/tracker_transaction.py" \
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
records its name and the metadata it was created with; a comment records its
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
pretend otherwise: an issue records its number and URL, a comment its comment ID
and URL, and an edit to an existing issue that issue's identity plus the
verified post-edit fingerprint.

Then, only after explicit approval and a `"clear"` preflight:

- **Child issue creation.** Creating the approved body with `gh issue create -R "$DOC_REPO" --body-file`,
  using a temporary file and approved existing labels, is a checkpointed step:
  begin it before that call and confirm it with the number and URL it returned
  before editing the report.
- **Child issue linking.** Linking an issue that already exists mutates nothing
  by itself, so the transaction plans only the mutations it really performs and
  records the `[#N]` marker the checklist line will carry; confirm the target
  issue still exists.
- **Approved comment.** Posting an explicitly approved comment on that issue is
  a checkpointed step: begin it before the comment is posted and confirm it with
  the comment ID and URL.
- **Epic:** capture the approved arc in a design document with the
  `design-epic` workflow, then process its `EPIC` entry through
  `process-design-doc` and obtain the created tracker number. No tracker
  mutation happens here, so no transaction is acquired.
- **No issue:** make no external mutation.
- **Deferred:** make no external mutation.

Then update only the selected finding:

- Prefix its heading with `[#N]` for a confirmed issue or epic.
- Prefix it with `[no-issue]` and insert the approved Disposition note for a
  no-issue decision.
- Prefix it with `[deferred]` and insert the approved Deferred note when the
  concern is real but blocked. When promoting a previously deferred finding,
  remove both its `[deferred]` marker and its Deferred note before applying the
  new marker, so no stale precondition survives beside a filed issue.
- Update that finding's status-checklist line in the same edit: set its marker,
  check the box for a terminal disposition, and add or clear the deferred
  precondition. A run that marks a heading and leaves the checklist stale has
  produced two contradictory answers to the same question.
- Preserve the finding body and unrelated user changes.
- Compose the complete updated report as text; do not write it to the file and
  do not stage it. The publication step below hands that text to the helper,
  which is the only writer of the document.
- Do not mark a finding if issue creation or lookup failed.
- Beyond the publication step below, do not commit, push, or open a PR unless
  separately requested.

Verify heading and checklist agree, and that the run changed exactly one finding,
with `rg -n '<item-key>' <report>` and `git diff --stat -- <report>`. For a
created or linked issue, also verify its title, state, labels, and URL.

If a tracker mutation succeeds but a later step or the document mutation fails,
do not create anything else. The durable transaction record is where that state
lives — never the report, which this workflow does not write and the publication
helper alone owns. Report the tracker states beside the three document states
section 6 requires: whether acquisition succeeded, the transaction state, each
planned step and whether it is planned, ambiguous, or confirmed, every confirmed
tracker identity, and the one recovery action that is permitted next. Reconcile
it before the next finding.

## 6. Publish the approved mutation

Publish the approved mutation in this same run. The document is a durable
cursor, and a cursor that only ever exists in one checkout is resumable only
from that checkout. Publication is one more step of the disposition that was
already approved; it carries no second one, and it is never batched or deferred
merely to reduce commit or push frequency.

When a tracker transaction is open, record that it is being handed to
publication before you hand it over, so an interruption inside publication is
distinguishable from one before it:

```bash
python3 "$DOC_ROOT/tools/tracker_transaction.py" \
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
APPROVED="$(python3 "$DOC_ROOT/tools/publish_coordination_doc.py" \
  --repo "$DOC_REPO" --root "$DOCS_WT" --path "$DOC_RELATIVE_PATH" \
  --new-content-file)"
python3 "$DOC_ROOT/tools/publish_coordination_doc.py" \
  --repo "$DOC_REPO" --branch "$DOC_BRANCH" --root "$DOCS_WT" \
  --path "$DOC_RELATIVE_PATH" --content "$APPROVED" \
  --expected-tip "$PREFLIGHT_TIP"
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

Resolve the helper from the already-resolved `$DOC_ROOT` — the local checkout of
the owning repository — and never from the session's own checkout, a personal
path, or an inline fallback. These plugins install into repositories that do not
track it, so a helper that cannot be resolved there fails closed: report that
publication was not attempted and why, and never publish by hand instead.

The helper owns the entire mechanism — eligibility against §7 as the publication
branch itself carries it, the per-document lock, the baseline, isolation, the
push, verification by reachability, and the resumption of an unfinished earlier
publication. Do not reimplement, precede, or compensate for any part of it. Act
on the one structured result it returns:

- **`"status": "published"`.** Say so, and quote the commit it reports together
  with its changed-line summary. Check that summary against the disposition you
  applied: because the whole document is handed over, an unintended rewrite of
  the rest of it changes the same single path a correct publication does, and
  the summary is what makes the difference visible.
- **`"status": "not-published"`.** The document is not direct-publication
  eligible — it is `pr-atomic`, matched no §7 row, or belongs to a repository
  with no coordination lane. The approved mutation is not lost: the helper
  reports `approved_blob`, recoverable with `git cat-file -p`, and
  `document_written` says whether it also applied it to the document. Say which
  it did and why publication was declined. This is the ordinary outcome for a
  `pr-atomic` document, not a failure of this run.
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
python3 "$DOC_ROOT/tools/tracker_transaction.py" \
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
result with `document_written` true — the ordinary outcome for a `pr-atomic`,
unmatched, or not-yet-tracked document — run the same verification against the
applied local document with `--source local`, which is the only evidence there
is and a legitimate terminal state for such a document. When `document_written`
is false, nothing carries the disposition anywhere: the record stays
outstanding, and this run reports it.

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

Publication ends this finding. Do not select another.

Report, in this order: the disposition and its tracker link if any; the report
line as it now reads; and the number of findings still unchecked, so the next run
starts from a known position.

Stop after this one finding. Advance to the next only when the user explicitly
asks or invokes `process-report` again. Never batch a second finding into the
same run, even when the next one looks trivial or obviously related — the
one-at-a-time rule is what keeps each disposition individually approved.
