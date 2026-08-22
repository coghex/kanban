---
name: project-review
description: Senior-model audit of merged PRs and the direct first-parent commits that predate an issue/PR workflow — judge each against its linked issue, its commits, and the current code, then preserve every confirmed current mistake in a canonical findings report in the docs worktree for later {{cmd:process-report}} disposition. Never creates or edits a tracker issue. Trigger when asked to run or continue {{cmd:project-review}}, audit or review merged PRs, or keep reviewing older direct-to-master history.
argument-hint: "[optional: how many units to review (default 12), or a PR number, commit SHA, or range to review]"
---

# Project review

You are the senior reviewer in a pipeline where issues and PRs are mass-produced
by lesser autonomous models. Re-examine merged work with fresh, skeptical eyes
and catch what the assembly line missed.

**Review only.** Do not modify code, push, touch merged PRs, or create or edit
tracker issues. This workflow's only default write is one canonical Markdown
findings report in the branch-resolved `docs-wip` worktree, written when a
completed batch has at least one confirmed current finding. That report is the
durable handoff to {{cmd:process-report}}, which turns one finding at a time
into an approved tracker artifact — so filing is not lost here, only deferred
one step, and it passes through the readiness gate on the way.

**Resolve the target — a repository *and* a checkout of it.** Set both `REPO`
and `ROOT` once, before the first GitHub read below. `$REPO` is the
`owner/name` every `gh` call names; `$ROOT` is the local checkout every other
step runs in, and neither substitutes for the other. A `gh` call without `-R`
reads whatever repository the session's working directory happens to be in, and
a batch scoped against the wrong tracker spends the whole run producing a report
about code nobody asked you to review.

`$REPO` alone is not the target, because most of this workflow never touches
GitHub: direct mode walks first-parent history, the surviving-behavior trace
reads the code at HEAD, and the docs worktree holds both the sweep cursor and
the finished report. Every one of those reads a checkout. Run them all under
`$ROOT` with `git -C "$ROOT"`, never in whatever directory the session happens
to be sitting in.

When the user named a repository, `$ROOT` is a checkout **of that repository**,
and the session's own is not it unless it proves to be. Otherwise both come from
the session's checkout. Resolution reads the remote and needs no GitHub call of
its own, so there is no point in this workflow at which an unscoped `gh`
invocation is correct:

```bash
ROOT="$(git rev-parse --show-toplevel)"
REPO="$(git -C "$ROOT" remote get-url origin | sed -E 's#\.git$##; s#.*(/|:)([^/:]+/[^/:]+)$#\2#')"
```

When the user named a repository, set `REPO` to the name they gave and `ROOT`
to a checkout of it, then run that same `git -C "$ROOT" remote get-url` and
**require the two to agree**. They must name one `owner/name` between them. A
mismatch, or no available checkout of `$REPO`, stops the run before the first
`gh` call: auditing one repository's pull requests against another's code, or
writing its report and cursor into another's docs worktree, is exactly the
failure this check exists to prevent, and neither is undone by moving a file
afterwards. Say which of the two could not be established and ask for a local
path. Falling back to the working directory is never the repair.

Either path leaves `$REPO` holding one `owner/name` and `$ROOT` a checkout of
it, before the first `gh` call. Pass `-R "$REPO"` on every one of them.

**Announce, then read:** name the resolved `$REPO`, the `$ROOT` it was matched
against, and the batch you are about to take before the first `gh` call below. Reporting what was resolved is what
catches a wrong resolution, and it catches it only if it lands before anything
has been read from the wrong repository.

## Scope and cursor

Default to 12 review units.
<!-- brand:claude -->
`$ARGUMENTS` may override the count, or name a PR number, commit SHA, or range.
<!-- brand:codex -->
An explicit count, PR number, commit SHA, or range overrides the default.
<!-- /brand -->

Resolve the reviewed repository's docs worktree once, by branch and never by a
hard-coded path. It is both where the sweep cursor is read and where a finished
report is written:

```bash
DOCS_WT="$(git -C "$ROOT" worktree list --porcelain \
  | awk '/^worktree /{p=substr($0,10)} /^branch refs\/heads\/docs-wip$/{print p; exit}')"
[ -n "$DOCS_WT" ] || DOCS_WT="$ROOT"
```

**The boundary rule.** Before selecting a range, read
`$DOCS_WT/docs/project_review_boundaries.md` when it exists. That file is the
sweep cursor for the repository under review, and it lives in that repository
rather than travelling with this command: it is one consumer's state, so
shipping it would put every consumer's cursor in every install. If it holds an
entry for `$REPO`, treat the recorded PR as an **exclusive older endpoint** for
a new newest-to-oldest sweep: stop before re-reviewing that PR unless the user
explicitly overrides the boundary. Update the entry only when the user asks to
preserve a new endpoint.

### PR mode

While an older merged PR remains at the cursor, take the next 12 merged PRs
newest-first — or the requested count, at-and-below a supplied starting PR.
Over-fetch and sort by `mergedAt` yourself, because `gh`'s own ordering is not
merge order:

```bash
gh pr list -R "$REPO" --state merged --limit "$LIMIT" --json number,title,mergedAt,body,url
```

**`$LIMIT` is not a constant.** Start it at the requested count plus a margin
for the over-fetch — 40 covers the 12-unit default — and then verify the
listing actually reaches the batch you asked for, before selecting anything
from it. Three conditions, all of them:

- the requested count fits inside the listing;
- a supplied starting PR appears in it;
- a boundary endpoint from the cursor is at or above its oldest entry.

Raise `$LIMIT` and list again until each one holds, or until the listing is
**exhausted** — a listing that came back with fewer rows than `$LIMIT` is the
whole of the repository's merged history, and raising the limit again changes
nothing. `--limit` paginates for you, so a larger number is the only remedy a
short listing needs. A batch selected from a listing that stopped short of its
own boundary is silently truncated to whatever happened to fit, and every later
`continue` inherits the gap.

What an exhausted listing that still fails a condition means depends on which
condition, and the three do not share an answer:

- **A supplied starting PR that is absent** is an invalid request: that PR is
  not in this repository's merged history at all. Say so and stop; do not
  review the nearest number that exists.
- **A boundary endpoint that is absent** is a cursor that does not belong to
  this repository. Say so and stop rather than sweeping past it.
- **A count larger than what remains is not an error at all.** It is the tail
  of the sweep. Review every PR that does remain, say the batch was short and
  why, and treat PR history as exhausted so the next `continue` enters direct
  mode. A repository with fewer merged PRs than the batch size meets this on
  its first batch, and is reviewed the same way — including one whose listing
  comes back empty, which reviews no PR and enters direct mode straight away.

Check `git -C "$ROOT" log --first-parent` for direct-to-default-branch commits
inside that landing interval and review them as bare commits. Do not mislabel a
rebased PR's individual commits as direct when GitHub associates them with the
PR.

### Direct mode

After PR history is exhausted, the entry point depends on whether there was any.

- **PR history existed.** Continue from the first-parent parent of the earliest
  PR-owned commit already reviewed.
- **There was none.** A repository whose merged-PR listing came back empty has
  no earliest PR-owned commit to walk back from, so start at the default
  branch's own HEAD and take the first-parent commits from there. This is the
  only case in which direct mode begins at HEAD, and a repository that has never
  used pull requests is otherwise never audited at all.

Either way, take exactly the next 12 older first-parent commits, newest-first,
unless the user supplied another count. A direct merge counts as one commit.
Every later `continue` resumes at the parent of the oldest completed direct
commit; never restart from HEAD once a batch has been reviewed.

A broad blame or survivor inventory is triage, not a reviewed direct-commit
batch. Advance the cursor past a direct commit only after checking its patch,
message, and current descendants individually.

If context was compacted, recover the cursor from the last completed range or
an unambiguous report name. Ask if multiple cursors remain possible rather than
creating a gap or duplicate review.

Announce PR mode by PR-number range. Announce direct mode by short/full SHA
range, count, and dates. Restate that concrete range beside the resolved `$REPO`
once the listing returns, before reviewing anything in it. Stop explicitly after
reviewing the initial commit.

## Review PRs newest-first

For each PR:

1. Read its description with `gh pr view -R "$REPO" <n>`.
2. Find its linked issue in that description's closing reference and read it
   with `gh issue view -R "$REPO" <m>`. Step 1's call returns the pull
   request's own description, never the specification it claims to satisfy, so
   this is a read of its own rather than a second look at the same text. Treat
   the issue as a proposed specification, not unquestioned authority.
3. Read the merged diff with `gh pr diff -R "$REPO" <n>` and judge it against
   what the issue should have required, not merely what the PR claims.
4. Read the touched code at HEAD plus enough callers and consumers to verify
   that the behavior still holds in context.
5. Check the commits and messages against what actually landed.

Judge whether the issue's requirements were correct, complete, consistent with
repository constraints, and backed by acceptance capable of failing a wrong
implementation. A faithful implementation of a flawed specification is still
a finding. A PR that deviated from a bad specification to do the right thing is
not.

Hunt especially for unmet requirements, vacuous or mock-only tests, unhandled
edge cases, repository-contract violations, stale comments/docs, unreviewed
scope creep, and semantic conflicts between merges in the same batch. Nits are
not findings; a finding must require a real correction.

## Review direct commits newest-first

Read each first-parent patch and metadata:

```bash
git -C "$ROOT" show --stat --summary <sha>
git -C "$ROOT" diff <sha>^1 <sha>
```

Use an empty-tree diff for the initial commit, which has no first parent to
diff against. Read adjacent commits when the change is a partial step. Treat the
message, historical repository instructions, tests, and subsystem contracts as
evidence, not necessarily a complete specification. Trace surviving behavior to
HEAD just as in PR mode.

Record fixed-later mistakes as completion-summary one-liners. Only current
mistakes become unprocessed report entries.

## Verify and capture findings

For every suspected finding:

1. Confirm it still exists at HEAD — a later merge may already have fixed it.
2. Trace the failure path in current code and cite `file:line`, or capture a
   reproduction command and result. Never report a hunch.
<!-- brand:codex -->
   In a read-only sandbox, a complete static trace may be the verification; say so.
<!-- /brand -->
3. Search open and closed tracker issues for context and deduplication — once
   up front, then a keyword search or two per finding:

   ```bash
   gh issue list -R "$REPO" --state open --limit 300 --json number,title,labels
   gh issue list -R "$REPO" --search "<words>" --state all --limit 20
   ```

   An already-tracked finding is not a new unprocessed report entry; list it
   briefly in the completion summary.
4. Capture each new current finding in the established project-review format:
   - `Captured note`: the concise correction;
   - `Verification`: what was proved and how;
   - `Evidence`: current `file:line` traces and/or reproduction;
   - `Handoff context`: current behavior, expected behavior, scope and
     constraints, verification target, deduplication, and uncertainty.
5. Keep reviewing the rest of the batch. Do not stop to discuss or file one
   finding.

State observable requirements and validation boundaries, not an assumed
implementation. Preserve enough context for a later autonomous
{{cmd:process-report}} pass to decide and draft one tracker artifact at a time.

## Write the report

After completing the batch, directly write one report when there is at least
one new current finding. Do not draft tracker issue bodies, ask which findings
to file, open an issue through `gh`, or append any origin-routing marker: this
workflow never creates or edits a tracker issue, and the user's invocation
authorizes the report handoff rather than a filing.

Inspect nearby `docs/project_review_*.md` reports before writing and use this
canonical shape:

```markdown
# Project Review Findings: PRs #<newest>–#<oldest>

<Purpose, actual batch scope, reviewed direct commits in the interval, and any
explicitly excluded concern.>

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [ ] PRR-1. <Finding title>

## 1. <Concern chapter>

### PRR-1. <Finding title>

> **Captured note:** <Concise correction and offending PR/commit.>

**Verification:** <Verified result.>

**Evidence:**

- `<file>:<line>` — <failure-path evidence>.

**Handoff context:**

- **Current behavior:** <Observed behavior.>
- **Expected behavior:** <Required behavior.>
- **Scope and constraints:** <Boundaries and related PR/issue.>
- **Verification target:** <Exact checks that should prove the correction.>
- **Deduplication:** <Tracker-search result.>
- **Remaining uncertainty:** <Unknowns, or none.>
```

Keep every new finding unchecked and unmarked. Each stable `PRR-*` key appears
exactly once in the checklist and once in a finding heading, in the same order
and with the same title. The legend line must begin literally `Status legend:`;
an unlabeled list of marker meanings is not canonical.

### Report filenames

Choose the filename in this order:

1. An explicit destination from the user wins.
2. If the user explicitly requests a report keyed to one number `N`, use
   `docs/project_review_N.md` even when the title records a wider reviewed
   batch. Example: `docs/project_review_1296.md`.
3. If the user explicitly requests a report keyed to range `A–B`, use
   `docs/project_review_A-B.md`.
4. Otherwise, a PR batch uses
   `docs/project_review_<newest>-<oldest>.md`.
5. Direct mode uses
   `docs/project_review_direct_<newest7>-<oldest7>.md` and the title
   `# Project Review Findings: direct commits <newest>–<oldest>`.

The title and opening paragraph always state the actual reviewed scope. A
single-number filename is a durable lookup key, not permission to obscure the
range.

### Destination and validation

Write the report under `$DOCS_WT/docs/`, using the docs worktree resolved in
"Scope and cursor" above — never the primary checkout, where uncommitted files
are autostashed by the PR drainer's post-merge fast-forward and wedge it when
the restore conflicts. Preserve unrelated dirty docs-worktree files. Run the
installed backlog scan when available and require the new path under
`valid_reports`. Run the repository's focused findings-report audit when
applicable. Do not commit, publish, or push the report unless the user
separately requests publication.

## Complete and continue

In the completion message, link the report, state its unprocessed finding
count, list fixed-later and already-tracked findings briefly, and preserve the
oldest reviewed landing as the cursor.

If a batch is clean, do not create an empty report unless explicitly requested.
Say the range was clean and preserve its cursor. On `continue`, review the next
older batch; after PR history, switch to direct mode. At the initial commit,
report that history is exhausted rather than restarting or widening the batch.
