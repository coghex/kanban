---
description: Process a Markdown findings or code-health report one concern at a time, resuming from a durable status checklist and issue/no-issue/deferred annotations, and stopping for approval before any disposition.
argument-hint: "<path-to-report.md>"
---

Process exactly one finding from the report named by `$ARGUMENTS`. Treat the
report file as the durable cursor so a fresh Claude context resumes at the
correct place without conversation history.

If `$ARGUMENTS` is empty, ask for the Markdown report path and stop.

Establish the owning repository (see "Establish the owning repository" below)
before anything else, then resolve that path under `$DOCS_WT` before reading or
editing it — a repo-relative report path names the copy in the resolved owner's
docs worktree, not the one in whatever checkout you happen to be sitting in.

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
marker is used. Never treat incidental issue numbers in prose, examples, or
Related sections as processed markers.

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

**Scan the document against the publication tip before choosing an entry.**
Resolve the document path first, in the numbered steps below, then pin the tip
and compare:

```bash
git -C "$DOCS_WT" fetch origin "$DOC_BRANCH"
PUB_TIP="$(git -C "$DOCS_WT" rev-parse "origin/$DOC_BRANCH")"
git -C "$DOCS_WT" diff --name-only "$PUB_TIP" -- "$DOC_RELATIVE_PATH"
```

That one comparison decides what this run may do at all:

- **Empty.** The document equals the publication tip. Select normally; this
  run's own edit is then the only difference, which is exactly what lets its
  publication carry the approved mutation and nothing else.
- **Prints the document, and the entries it already changed carry their `[#N]`,
  `[no-issue]`, or `[deferred]` markers.** An earlier run applied and marked its
  disposition but failed to publish it: the tracker and the document are already
  correct and publication alone is outstanding. Re-attempt the publication step
  below against that existing edit, never repeat the tracker mutation, and
  select no new entry this run.
- **Prints the document otherwise.** It carries work this run did not make, so
  **publication is impossible this run**: the publication commit is built from
  the document's whole blob and would carry that work too — invisibly to the
  one-path check, which sees a single changed path either way. Say so before
  applying anything, name what the document already carries, and let the user
  decide whether to proceed with a disposition that will not be published or to
  reconcile first. Never publish anyway, and never discard the other work to
  make publication possible.

**This scan is the one deliberate exception to the selection rule below, which
never selects a terminal-marked entry.** The entry being resumed is already
marked — that is what an applied disposition looks like — so normal selection
would skip it forever and the failed publication would never be retried. That
marker and an existing local publication commit are the only evidence used here;
a durable journal or cross-system reconciliation is deliberately not part of
this workflow.

1. Resolve `$ARGUMENTS` under `$DOCS_WT`, never relative to the working
   directory. Stop with a concise error if it does not exist or is not a
   Markdown file.
2. Read the repository's applicable `CLAUDE.md`, `AGENTS.md`, or equivalent
   instructions before investigating.
3. Read the report header, status legend, and status checklist, then list finding
   headings with:

   ```bash
   rg -n '^#{2,6} ' "$ARGUMENTS"
   ```

4. Infer the finding-heading level and item-key pattern from neighboring
   entries; for example, a report may use level-three `CH-N` headings rather than
   plain numbers.
5. Choose exactly one finding, by this precedence. `[#N]` and `[no-issue]`
   findings are never selected. The unfinished-publication scan above is the one deliberate exception to this rule: it re-attempts publication for an entry that is already terminally marked, and selects no new work.

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

6. Read from that heading through the next finding heading. Read other findings
   only when needed to resolve an explicit cross-reference. Do not evaluate
   runners-up or batch later entries.
7. Stop without editing when nothing is selectable:

   - Every finding is `[#N]` or `[no-issue]` — report completion.
   - Only `[deferred]` findings remain and none of their preconditions are met —
     report that the report is blocked rather than finished, listing each finding
     with the precondition still outstanding and what would clear it. Do not call
     this completion; the difference matters to whoever reads the result.

## 2. Verify the concern

Treat the report as a lead, not proof.

- Inspect the current code, tests, documentation, history, and configuration
  needed to confirm or reject the claim.
- Search every relevant source and test tree, including secondary suites the
  report may have omitted.
- For a bug, reproduce it when safe and proportionate, or trace the concrete
  failure path with file-and-line evidence.
- For code health or documentation, confirm the stale/dead/duplicated surface
  still exists and identify the authoritative replacement or contract.
- Respect repository testing tiers and safety rules. Never open a graphical
  application merely to evaluate a finding.
- Do not modify implementation code during this workflow.

Correct minor factual errors in the finding when presenting evidence. A count
correction does not invalidate the concern unless it changes the conclusion.

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

3. Read plausible matches and all open epics whose bodies may own the work. A
   planned epic child counts as a duplicate.
4. Respect prior `wontfix`, `invalid`, or decision records unless materially
   new evidence changes the premise.

## 4. Recommend exactly one disposition

### No issue

Use when the claim is false, already fixed, too harmless to justify tracker and
PR overhead, or deliberately out of scope. Do not use it for a real concern you
are merely unsure how to scope — that is `Deferred`. Present:

- the recommendation and evidence;
- the exact proposed `[no-issue]` note; and
- the consequence of leaving the code unchanged.

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

Present its number, why it covers the finding, and any proposed comment
containing genuinely new evidence. Do not comment or mark the report without
approval.

### One new issue

Use when the work fits one reviewable PR. Present the complete draft exactly as
it would be posted:

- imperative title;
- existing labels only;
- `## Background` with verification evidence;
- numbered, observable `## Requirements`;
- exact, proportionate commands in `## Acceptance`;
- explicit `## Out of scope`;
- `## Related`; and
- `<!-- issue-origin:claude -->` as the final line.

Specify observable outcomes rather than implementation method. Preserve
repository constraints such as compatibility, determinism, persistence,
performance, and required steering-document updates. Below the draft, include
short Evidence and Dedup notes and state that no later finding was examined.

Stop for explicit approval. Never create an issue while merely presenting or
revising its draft.

### Epic

Use only when the concern requires multiple dependency-ordered PRs or an
unresolved product/design decision. Explain why one issue is insufficient and
propose the decomposition boundary. Stop for agreement, then hand the arc to
the `/design-epic` command; its slices are filed later through
`/process-design-doc`. Do not compress epic-sized work into one issue.

## 5. Apply the approved disposition

Only after explicit approval:

- **New issue:** write the approved body to a temporary file, create it with
  `gh issue create -R "$DOC_REPO" --body-file`, apply only approved existing labels, and
  confirm the returned issue number.
- **Existing issue:** optionally post only an explicitly approved comment, then
  confirm the target issue still exists.
- **Epic:** hand the approved arc to `/design-epic` for capture
  in a design document, then process its `EPIC` entry through
  `/process-design-doc` and record the created tracker number.
- **No issue:** make no external mutation.
- **Deferred:** make no external mutation.

Then edit only the selected report finding:

- Prefix its heading with `[#N]` for a confirmed issue or epic.
- Prefix it with `[no-issue]` and insert the approved Disposition note when no
  tracker item will be created.
- Prefix it with `[deferred]` and insert the approved Deferred note when the
  concern is real but blocked. When promoting a previously deferred finding,
  remove both its `[deferred]` marker and its Deferred note before applying the
  new marker, so no stale precondition survives beside a filed issue.
- Update that finding's status-checklist line in the same edit: set its marker,
  check the box for a terminal disposition, and add or clear the deferred
  precondition. A run that marks a heading and leaves the checklist stale has
  produced two contradictory answers to the same question.
- Preserve the finding body and all unrelated changes.
- Never mark the finding when issue creation or lookup failed.
- Do not commit, push, or open a PR beyond the publication step in
  section 6 below unless separately requested.

Verify heading and checklist agree, and that the run changed exactly one finding:

```bash
rg -n '<item-key>' "$ARGUMENTS"
git diff --stat -- "$ARGUMENTS"
```

For a created or linked issue, also verify its title, state, labels, and URL.

## 6. Publish the approved mutation

Publish the approved mutation in this same run. The document is a durable
cursor, and a cursor that only ever exists in one checkout is resumable only
from that checkout. Publication is one more step of the disposition that was
already approved; it carries no second one, and it is never batched or deferred
merely to reduce commit or push frequency.

**Pin the publication tip once.** Every question below — is this document
eligible, is the mutation isolated, did the publication land — has to be
answered against one state of the publication branch. Fetching again between the
answers reopens the very window each check exists to close, so fetch once and
pin the tip:

```bash
git -C "$DOCS_WT" fetch origin "$DOC_BRANCH"
PUB_TIP="$(git -C "$DOCS_WT" rev-parse "origin/$DOC_BRANCH")"
```

Everything below names `$PUB_TIP`, never `origin/$DOC_BRANCH`, until the
verification step deliberately refetches to learn whether the push landed. A
check answered against one tip and acted on against another is not a check.

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
PUB_KEY="${DOC_RELATIVE_PATH//\//-}"
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
  && [ "$(git -C "$DOCS_WT" diff --name-only "$PUB_TIP" "$PUB_COMMIT")" \
    = "$DOC_RELATIVE_PATH" ] \
  && git -C "$DOCS_WT" push origin "${PUB_COMMIT}:refs/heads/${DOC_BRANCH}"
```

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

[ "$PUB_PUBLISHED" = yes ] \
  && git -C "$DOCS_WT" checkout "origin/$DOC_BRANCH" -- "$DOC_RELATIVE_PATH"
[ "$PUB_PUBLISHED" = yes ] \
  && [ "$(git -C "$DOCS_WT" rev-parse --abbrev-ref HEAD)" = "$DOC_BRANCH" ] \
  && git -C "$DOCS_WT" merge --ff-only "origin/$DOC_BRANCH"
```

**Ancestry alone is the verdict, and comparing the local file to the branch must
play no part in it.** Someone else can advance `$DOC_BRANCH` with their own edit
to this same document between the push and the check. The commit still landed —
it is an ancestor — but the local copy no longer equals the branch. Folding that
comparison into the verdict would report a successful publication as failed, and
the next run's scan would then read the local copy as a pending mutation and
republish it *over* the concurrent edit. That is why `PUB_PUBLISHED` is set by
`merge-base --is-ancestor` and by nothing else.

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

Report, in this order: the disposition and its tracker link if any; the report
line as it now reads; whether the mutation was published, with the commit ID
when it was and the three states above when it was not; and the number of
findings still unchecked, so the next run starts from a known position.

Stop after this one finding. Advance only when the user explicitly asks or runs
`/process-report` again. Never batch a second finding into the same run, even
when the next one looks trivial or obviously related — the one-at-a-time rule is
what keeps each disposition individually approved.
