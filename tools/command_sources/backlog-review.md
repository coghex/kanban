---
name: backlog-review
description: Audit the open issue backlog oldest-first — re-verify each issue's premise against the current code, propose per-issue dispositions (valid / update / obsolete / duplicate / needs-decision), and apply only what the user approves. Trigger when asked to run {{cmd:backlog-review}} or to audit/groom/re-verify the open issues.
argument-hint: "[optional: batch size (default 15), or a label/area to focus on]"
---

# Backlog Review

You are the senior reviewer auditing the open backlog of a pipeline where
issues are mass-produced by lesser models. Specs rot: the code moves on, a
merged PR fixes something incidentally, a newer decision invalidates a premise.
And the solve workflow picks the OLDEST unassigned issue first — so the stalest
spec is exactly what the next agent will grab. Audit oldest-first for the same
reason. Review only — never modify code; the only writes you ever make are
tracker writes (edit/close/label/comment), and only after explicit approval.

**Resolve the repository:** Set `REPO` once, before the first GitHub read
below, and use that one identity for every `gh` call in this workflow. This is
the workflow that closes issues and rewrites their bodies, and a `gh` call
without `-R` targets whatever repository the session's working directory
happens to be in — closing someone else's issue is not recoverable by editing a
file afterwards.

When the user named a repository in their request, that identity is the target.
Otherwise resolve it from the session's own checkout. Resolution reads the
remote and needs no GitHub call of its own, so there is no point in this
workflow at which an unscoped `gh` invocation is correct:

```bash
REPO="$(git remote get-url origin | sed -E 's#\.git$##; s#.*(/|:)([^/:]+/[^/:]+)$#\2#')"
```

Either path leaves `$REPO` holding one `owner/name` before the first `gh` call.
Pass `-R "$REPO"` on every one of them, the four apply-step mutations included.

**Announce, then read:** name the resolved `$REPO` and the batch you are about
to take before the first `gh` call below. Default is the 15 oldest;
<!-- brand:claude -->
`$ARGUMENTS` may override the count or narrow to a label/area.
<!-- brand:codex -->
if the user gave you a count or a label/area, use that instead.
<!-- /brand -->
Reporting what was resolved is what catches a wrong resolution, and it catches
it only if it lands before anything has been read from the wrong tracker.

**Scope the batch:** list the open issues and sort them oldest-first:

```bash
gh issue list -R "$REPO" --state open --limit "$ISSUE_LIMIT" --json number,title,labels,assignees,body,createdAt,url
```

The batch is the *oldest* issues in the tracker, and a capped listing drops
exactly those, so the open set is read whole before it is narrowed. Set and
verify `$ISSUE_LIMIT` as **Complete Snapshots** below specifies, then apply any
label or area restriction the user asked for, sort what remains by `createdAt`
oldest-first, and take the count off the front of that.

Skip issues that are in-flight (assignee, `wip` label, or an open PR closing
them) — changing a spec under an active agent yanks the rug; list them as
skipped. Restate the batch as the concrete issue number range it spans — the
issues actually selected, after the restriction, the sort, and the count, not the
range of the complete listing they were drawn from — before starting the
verification below.

**Verify each issue's premise against HEAD:**
- Bug: does the described defect still exist? Trace the named code path in the current code; re-run the repro if it's cheap.
<!-- brand:codex -->
  (In a read-only sandbox, tracing the code path is the verification — say so in the evidence note.)
<!-- /brand -->
- Feature / tech-debt: does the thing already exist now, fully or partially — perhaps landed incidentally by another PR? Search merged work (`gh pr list -R "$REPO" --state merged --search "<words>"`, `git log --oneline --grep "<words>"`).
- References: do the files, functions, tests, and probes the body names still exist? Are the acceptance commands still runnable as written?
- Consistency: does the spec contradict a constraint or decision that landed after it was written (check the repo's agent instructions and recent merges)?
- Epics get a lighter check: all children closed → propose close; the body's plan no longer matching reality → propose update.

**Disposition — exactly one per issue:**
- **Valid** — premise holds and the body is still hand-off quality. No action.
- **Update** — premise holds but the body drifted (stale paths, dead acceptance commands, a missing new constraint): draft the corrected body, preserving the original intent.
- **Obsolete** — already done or premise gone: propose close, with a comment citing the evidence (the PR/commit that resolved it, or the trace showing the premise no longer holds).
- **Duplicate** — propose close pointing at the surviving issue.
- **Needs decision** — the premise is contested or a design conflict emerged: propose the `needs-decision` label plus a comment framing exactly what the user must decide.

Never dispose on a hunch — every non-Valid disposition needs the same evidence
bar as drafting a new issue: a `file:line` trace, a repro, or the resolving
PR/commit.

**Report — STOP:** Group by disposition; one line of evidence per issue; show
the full drafted body or comment for anything that would change the tracker.
Then STOP and ask which to apply — accept "all", a list, or none. Do NOT edit,
close, label, or comment until told.

**Apply:** For approved items only: updates via a temp file and `gh issue edit -R "$REPO" <n> --body-file <file>`; closes via `gh issue close -R "$REPO" <n> --comment "<evidence>"` with the right `--reason` ("completed" when the work actually landed, "not planned" for duplicates and dead premises); decisions via `gh issue edit -R "$REPO" <n> --add-label needs-decision` plus `gh issue comment -R "$REPO" <n> --body-file <file>`. Report what changed.
<!-- brand:codex -->
(Only possible if the current Codex session has write/network access — the default read-only sandbox can't; if sandboxed, hand the user the exact commands instead.)
<!-- /brand -->

**Clean batch:** If everything came back Valid, say so — name the issue range
you cleared — and ask whether to continue with the next batch (the next `<n>`
issues in age order).

## Complete Snapshots

`gh` documents `--limit` as the maximum number of rows to fetch, and it returns
the newest first. A fixed number therefore drops the *oldest* rows, and it drops
them silently: a truncated listing is indistinguishable from a shorter tracker.
Every completeness claim this workflow makes is a claim about the listing it
read, so each listing has to be the whole collection — or the run has to say it
was not.

**A listing limit is never a constant.** Each snapshot listing above — the ones
a completeness claim rests on, not a bounded keyword search for one named issue
or pull request — carries its own limit variable, raised independently of any
other: `$ISSUE_LIMIT` for the open-issue listing, and `$PR_LIMIT` for an
open-pull-request listing where the workflow takes one. Start each at 500, which
reaches most trackers in one round trip, then check what came back against the
limit it was taken with:

- **Fewer rows than the limit** — that listing is the complete collection.
  `--limit` paginates for you, so a short listing is `gh` running out of rows,
  not out of budget.
- **Exactly the limit** — the listing may have been cut off at the cap. Double
  that variable, capped at 10000, and take the listing again.

Repeat until a listing comes back short.

**A completeness check succeeds before the snapshot it covers is used** — for
classification, batch selection, approval reconciliation, or any tracker
mutation. Whichever of those this workflow performs, none of them may read a
snapshot that has not passed, and a partial snapshot is never presented as
complete.

**Fail visibly.** If a listing errors, or still comes back full once its limit
variable has reached 10000, that collection was not read and this run cannot
make the completeness claim it owes. Stop, and name in the diagnostic the
repository `$REPO`, which collection is incomplete — the **open issues** or the
**open pull requests** — and the limit the last listing used. Do not fall back
to the partial snapshot, do not classify or select from what was read, and do
not present a roadmap or a batch as covering anything. This is a stop, not a
warning.

## Where files go

This workflow files and edits through `gh` and drafts in chat, and it writes
nothing into any repository. Its only filesystem writes are the Apply phase's
two transient `--body-file` payloads — the rewritten issue body and the
needs-decision comment. Put each under the system temporary directory, outside
every repository worktree: never in the `docs-wip` worktree, and never in the
primary checkout. Remove each one as soon as the `gh` call that consumes it
returns, whether it succeeded or failed, and clean up whatever is left behind on
an ordinary interruption or cancellation, so a finished or abandoned Apply
leaves none behind.

If a step ever does need a file inside the repository, and that repository keeps
a `docs-wip` worktree, write it there rather than the primary checkout — the PR
drainer fast-forwards the primary after every merge and autostashes whatever it
finds there, and a restore that conflicts wedges post-merge cleanup until a
human clears it. Resolve it by branch, never a hard-coded path:

```bash
DOCS_WT="$(git worktree list --porcelain \
  | awk '/^worktree /{p=substr($0,10)} /^branch refs\/heads\/docs-wip$/{print p; exit}')"
[ -n "$DOCS_WT" ] || DOCS_WT="$(git rev-parse --show-toplevel)"
```

A repository with no `docs-wip` worktree does not use this convention — the
fallback returns its own primary checkout and you proceed normally.
