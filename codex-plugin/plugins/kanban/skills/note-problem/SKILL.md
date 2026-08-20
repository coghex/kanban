---
name: note-problem
description: Capture one user observation in a Markdown findings report, investigate and verify it against the current repository, and record concise evidence and handoff context while maintaining process-report-compatible status checklists, finding keys, and concern chapters. Use when the user invokes $note-problem, asks to note and investigate a bug, annoyance, UI problem, code smell, or improvement idea, or wants to build an evidence-backed findings list gradually without filing issues or changing implementation.
---

# Note Problem

Capture and investigate one observation. Leave issue disposition, drafting, and
creation to a later `process-report` run.

## Establish the owning repository

This workflow writes a durable document. That is irreversible in the wrong
repository, and moving a Markdown file afterward does not undo an observation
appended where it does not belong. So resolve the owner explicitly before
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
says where this document and its observations belong; whether the document
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

## Parse the invocation

Accept the natural invocation:

```text
$note-problem docs/ui-bugs.md "the observed problem"
```

Treat the first token ending in `.md` as the report path, and feed it to the
ownership resolution above as the explicit path input. Treat all remaining text
as one note. Quoting is optional. If either is missing, ask only for the missing
value. Confirm the report exists at the resolved path before
investigating; a path that holds no report is `$draft-report`'s to draft, not this
workflow's to create.

## Status vocabulary

The markers this workflow reads and writes are the interface between two runs,
two brands, and two sessions, so they are exact literals rather than a house
style:

- `[#N]` — linked to tracker item N; terminal.
- `[no-issue]` — reviewed and deliberately never to be filed; terminal.
- `[deferred]` — real work blocked on a concrete, checkable precondition;
  non-terminal.
- No marker — unprocessed.

This workflow applies none of them. Every checklist line it writes uses exactly
`- [ ]`, because an observation it just captured is unprocessed by definition
and only `process-report` may mark one terminal. A report this workflow
appends to is therefore resumable by either brand's `process-report` without
translation.

## Workflow

1. Read applicable repository instructions and the complete existing report.
2. Preserve the user's original wording. Treat it as a claim to verify, not as
   proof or a complete specification.
3. Search the report for an obviously equivalent finding:
   - If one exists, append the new wording as an additional captured observation
     and refresh that finding's evidence. Do not create another checklist entry.
   - If similarity is uncertain, create a new finding rather than merging
     distinct concerns.
4. Investigate only this observation:
   - State the apparent current behavior and the expected behavior implied by
     the note.
   - Locate the owning implementation with `rg`, then read the complete relevant
     functions and nearby contracts rather than relying on a matching string.
   - Inspect focused tests, fixtures, golden output, documentation, and history
     when they materially confirm or contradict the claim.
   - Reproduce safely when proportionate. Do not launch an interactive UI,
     contact external services, or mutate durable state merely to reproduce a
     finding when code and deterministic tests can settle it.
   - Classify the result as `Verified`, `Partially verified`, `Not reproduced`,
     or `Contradicted`. Explain uncertainty; never force a positive result.
   - Search only the report for duplicates. GitHub deduplication belongs to
     `process-report`.
5. Infer the existing item-key pattern and choose the next unused numeric suffix.
   For example, after `UI-3`, use `UI-4`. Never renumber earlier findings.
6. Write a short, neutral title consistent with the verification result.
7. Choose the closest existing concern chapter. Add a new numbered chapter only
   when none fits; never move existing findings merely to improve grouping.
8. Compose the complete appended observation, which:
   - appends `- [ ] <key>. <title>` to the report's `## Status` checklist;
   - appends `### <key>. <title>` under the chosen chapter; and
   - writes the finding in this shape:

     ```markdown
     > **Captured note:** <original wording>

     **Verification:** <classification> — <concise conclusion>.

     **Evidence:**

     - `<path>:<line>` — <what this establishes>.

     **Handoff context:**

     - **Current behavior:** <observable behavior>.
     - **Expected behavior:** <observable expectation implied by the note>.
     - **Scope and constraints:** <relevant boundaries, compatibility, or tests>.
     - **Remaining uncertainty:** <unknowns, or `None at capture time.`>.
     ```

   Preserve the note verbatim apart from removing surrounding quote delimiters.
   Use current line references, concrete symbols, and exact focused test paths.
   Keep the dossier concise enough for the next agent to re-verify quickly.
   Remove a chapter's `No findings yet.` placeholder when adding its first
   finding.
9. Verify the key occurs exactly once in the status checklist and once as a
   finding heading.

## Approval gate

Add exactly one observation per invocation, and only after explicit approval.

1. Present the resolved report path, the chosen key and chapter, the
   verification classification, and the complete proposed finding text in the
   final response. Do not summarize in place of the finding.
2. State explicitly that the report has not been modified yet, then ask the user
   to approve this observation or request changes.
3. Do not edit or create the report before explicit approval. The request to
   note a problem is authorization to investigate it, not approval of unseen
   text.
4. If the user requests changes, revise and present the complete updated
   observation again. Approval applies only to the latest version the user has
   seen.
5. Stop after this one observation. A broad instruction such as "note all of
   these" does not waive it; each observation is invoked, approved, and
   published on its own.

## A missing report is not this workflow's to create

This workflow appends to a report that already exists. When the resolved path
holds no report, stop and say so, and point the user at `$draft-report`, which
drafts a new report from their notes and creates it after explicit approval.
Then this workflow can capture observations into it.

That boundary follows from the publication contract below rather than from
preference. `tools/publish_coordination_doc.py` is this workflow's only writer,
and a document absent from the publication tip is one it declines to *write* as
well as to publish: it preserves the approved content in the object database and
reports that the document was not written. An invocation that promised to create
the report would therefore leave the user with no report at all and the
observation reachable only as a preserved blob. Writing the file directly
instead would contradict the only-writer rule, and the document it left behind
would be refused by the next publication as no longer matching the tip.

A report that `$draft-report` has created but that no pull request has enrolled yet
is in the same position: it exists locally but is absent from the publication
tip, so the helper declines both to publish it and to write into it. Report that
outcome plainly rather than describing the observation as captured.

## Publish the approved mutation

**Resolve this bundle's own mechanism first.** The helper ships with this
plugin rather than with the repository being worked, and Kanban spawns this
workflow with the *worked* repository as the working directory, so locate the
installed copy under `$CODEX_HOME` (default `~/.codex`) rather than against
`$DOC_ROOT` or a path relative to the current directory:

```bash
PUBLISH_DOC="$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" -path '*/kanban/*/skills/process-report/scripts/publish_coordination_doc.py' 2>/dev/null | head -n1)"
[ -n "$PUBLISH_DOC" ]
```

An unresolvable helper stops the run here rather than after the document has
been read. The lookup rule this follows is stated in full with the publication
step below.

**First, before writing anything, check for an outstanding publication.**

```bash
PREFLIGHT="$(python3 "$PUBLISH_DOC" \
  --repo "$DOC_REPO" --branch "$DOC_BRANCH" --root "$DOCS_WT" \
  --path "$DOC_RELATIVE_PATH" --check-pending)"
PREFLIGHT_TIP="$(PREFLIGHT="$PREFLIGHT" python3 -c \
  'import json, os; print(json.loads(os.environ["PREFLIGHT"])["publication_tip"])')"
[ -n "$PREFLIGHT_TIP" ]
```

`$PREFLIGHT_TIP` must be extracted, not assumed: publication refuses to run
without it, and an empty one is a failure rather than a publication with the
check quietly switched off. A `"pending"` result means an earlier approved
mutation of this document is outstanding. **Stop here** and report what the
record names; the helper will refuse to publish a different mutation while a
record stands. This workflow creates no tracker item, so it acquires no tracker
transaction — there is nothing here for one to record.

Publish the approved mutation in this same run. The document is a durable
cursor, and a cursor that only ever exists in one checkout is resumable only
from that checkout. Publication is one more step of the observation that was
already approved; it carries no second one, and it is never batched or deferred
merely to reduce commit or push frequency.

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
  --expected-tip "$PREFLIGHT_TIP"
```

`$PREFLIGHT_TIP` is the `publication_tip` the preflight reported. Always pass
it: it is what binds this content to the document state it was rendered from,
and a `tip-moved` result means re-reading the document and rendering the
disposition again rather than publishing what you have — here that disposition
is this one appended observation.

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
`workflow.coordination_paths` declaration, which is empty until the repository
sets it. Do not reimplement, precede, or compensate for any part of it. Act
on the one structured result it returns:

- **`"status": "published"`.** Say so, and quote the commit it reports together
  with its changed-line summary. Check that summary against the observation you
  appended: because the whole document is handed over, an unintended rewrite of
  the rest of it changes the same single path a correct publication does, and
  the summary is what makes the difference visible.
- **`"status": "not-published"`.** The document is not direct-publication
  eligible — it is `pr-atomic`, matched no §7 row, is not yet tracked, or
  belongs to a repository that declares no coordination path for it. The
  approved mutation is not lost: the helper reports `approved_blob`,
  recoverable with `git cat-file -p`, and `document_written` says whether it
  also applied it to the document. `write_outcome` names which of the four
  cases the write was, rather than leaving `document_written` to stand for all
  of them: `applied-over-baseline`, `applied-over-local-predecessor`,
  `no-baseline`, and
  `unrecognized-working-copy`. A working copy byte-identical to what the helper
  last applied locally is its own unlanded write, and the approved mutation is
  applied on top of it — so successive approved mutations to a document its
  owner lands out of band accumulate rather than wedging on the first one. A
  working copy the helper did not write is never overwritten, and nothing is
  applied over it. Say which outcome it was and why publication was declined.
  This is the ordinary outcome for a `pr-atomic` document, not a failure of
  this run.

  `applied_record` is the other half of that. The helper records what it wrote
  in its own reference, and only `"recorded"` — with `applied_ref` naming that
  reference — lets a later run continue over the working copy or a transaction
  resolve from it. `"unrecorded"` means the write happened and the record did
  not, so no later run may write over that document and no transaction may
  resolve from it. Report that rather than an ordinary applied mutation.

  **An applied mutation is not durable until the document's owner lands it on
  the publication branch.** It exists in one write root and nowhere else, so
  name the write root, the document path, and the preserved `approved_blob`
  rather than describing the run as complete on the branch.
- **Any other status.** The document was not published. Report the three states
  the helper returns — whether the edit exists locally and in which worktree and
  path, whether a local publication commit exists and its ID, and whether the
  remote publication branch contains it — and say plainly which one applies.
  Leave the document as the helper left it.

## Boundaries

- Add exactly one new observation per invocation.
- Keep unchecked boxes unchecked; only `process-report` applies dispositions.
- Preserve all existing markers, notes, prose, and unrelated user edits.
- Do not draft an issue, decide a disposition, prescribe an implementation, or
  continue into another finding.
- Do not create, link, label, or comment on any tracker item, modify
  implementation code, or mutate GitHub.

## Handoff

Report the key, verification classification, chapter, and resolved path, then
what the helper actually did — and let that decide what you claim. The three
outcomes are not interchangeable, because only two of them left an observation
in the report:

- **Published.** Report the commit and its changed-line summary, the report's
  outstanding checkbox count, and that the observation is captured unprocessed
  for `process-report` to dispose of, one finding per invocation.
- **Not published, but the document was written.** The observation is in the
  report in the write root and not on the publication branch — applied, and not
  yet durable. Say both halves and why publication was declined, name the write
  root and path, and say whether the helper recorded the write: an
  `"unrecorded"` one is a report no later run may write over.
- **Nothing was written.** The report is unchanged and the observation is **not
  captured** — this is the outcome for a document absent from the publication
  tip, an unenrolled report included, and for a working copy the helper did
  not write. Say exactly that, name the preserved `approved_blob` and that
  `git cat-file -p` recovers it, and do not describe
  the run as having noted the problem. Reporting capture here would leave the
  user believing a report holds an observation it does not, which is the one
  failure this workflow's own output can cause.

<!-- Vendored from the owner-maintained personal Codex `note-problem` skill,
     SHA-256 58d32a2f523b1f4b1b9e05ecc2e440a340396caf8a23bd3a7050f2dcbf005216.
     Its `agents/` sidecar is deliberately not vendored. Adaptations made for
     this tracked contract, and no others:
     (1) the §8 owning-repository resolution replaces the personal source's
         unscoped docs-worktree lookup, which resolved the write root from
         whichever checkout the session started in;
     (2) the §5 approval gate, which the personal source left implicit;
     (3) the §9 same-run publication step, which a personal file editing only
         its own checkout did not need;
     (4) the §4 status vocabulary stated as exact literals;
     (5) `apply_patch` is no longer named, since the caller renders the
         approved document and the publication helper is its only writer;
     (6) the personal source's missing-report creation path is dropped and
         handed to $draft-report. It cannot survive adaptation (3): a document
         absent from the publication tip is one
         tools/publish_coordination_doc.py declines to write as well as to
         publish, so the promised report would never exist. -->
