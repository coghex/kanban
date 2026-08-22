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
gh issue list -R "$REPO" --state open --limit 500 --json number,title,labels,assignees,body,createdAt,url
```

Skip issues that are in-flight (assignee, `wip` label, or an open PR closing
them) — changing a spec under an active agent yanks the rug; list them as
skipped. Restate the batch as the concrete issue number range the list yields
before starting the verification below.

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
