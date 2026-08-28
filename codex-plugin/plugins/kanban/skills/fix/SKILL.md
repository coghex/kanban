---
name: fix
description: Clear an already-approved GitHub pull request's remaining obstacle so it can merge — resolve a merge conflict, rerun CI once when the failure never executed the pull request's code, or fix a genuine check failure and hand off to a canonical rereview. Refuses any pull request that is not approved. Runs only on an explicit request to fix, unblock, or clear an approved pull request: when the user invokes $fix or asks in that turn for one to be made mergeable. A question about WHY a pull request cannot merge is a diagnostic request, not this workflow.
---

# Fix an approved pull request

Clear the one thing standing between an approved pull request and the merge
queue, taking its number from the argument below. This workflow touches the
pull request's own code, so this session runs on the pull request's own origin
brand, the same way $pr-revise and $repair do.

**A diagnosis is not authorisation.** This workflow reruns checks, commits,
pushes, and hands off a rereview, so it runs only when the user asked in that
turn for the pull request to be fixed, unblocked, or made mergeable. "Why can't
this merge?" and "what is blocking this?" ask for none of that: answer them by
running step 2 and step 3, reporting the obstacle you found, and stopping there
— no rerun, no worktree, no push. Then say what this workflow would do about it
and let the user ask for it. When a request could be read either way, treat it
as diagnostic and ask, because the diagnostic reading is the one whose mistake
costs nothing.

Never merge the pull request, and never close an issue or pull request. Merging
belongs to the repository's own merge or drainer process, never to this
workflow.

Never add or remove a verdict label directly. The configured approval and
changes-requested labels (default `reviewed:approve` / `reviewed:changes`)
change only as a consequence of the canonical rereview this workflow hands off
to, which necessarily switches them. That handoff is the only path by which
they may change.

Whenever two reasonable resolutions would differ in behaviour, scope, or
user-visible outcome, ask the user through the session's question mechanism
rather than choosing.

## 1. Inputs

Take the pull request number the user supplied in the prompt; Codex substitutes
no argument placeholder.

Require one positive pull request number. Accept the repository and
configuration context the caller supplies alongside it, and resolve the
repository identity from that context rather than from the local checkout
directory name. When the caller supplies none, resolve it from the checkout's
own configured remote.

Use that resolved repository for the pull request's own GitHub metadata and for
the coordinator handoff: pass it to `gh` as `-R <owner/name>` rather than
letting `gh` infer the repository from the local checkout. A fork checkout whose
remote points at the fork would otherwise diagnose, or fail on, a same-numbered
pull request in the wrong repository.

The resolved repository is where the pull request lives, not necessarily where
its head lives. Every fetch and push of the head branch goes to the head
repository recorded in step 4 instead, which for a cross-repository pull request
is a different repository.

Forward the resolved repository and configuration to the canonical coordinator
through the coordinator's own `--repo` and `--config` options, so a fork
checkout or a non-default config path fixes and rereviews the same repository
the board displays. Omit an option the caller did not supply.

## 2. Require approval before anything else

This workflow acts only on an approved pull request. Approval is the whole
reason its rerun branch in step 5 is safe: on work a reviewer has already
accepted, a red check is far more likely to be infrastructure than a defect the
review missed. Read the pull request once and settle approval before diagnosing
anything:

```bash
gh pr view <pr> -R <owner/name> --json number,baseRefName,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository,mergeStateStatus,mergeable,labels,reviewDecision,statusCheckRollup,closingIssuesReferences,url
```

Approval is whatever the effective configuration says it is, never a fixed
string and never the label alone: take the configured `approval_label` (default
`reviewed:approve`) and `approval_mode` (default `label`) from the same
configuration the caller supplied — the global `[workflow]` table, overridden
per repository by `[repositories."<owner>/<name>".workflow]` — and match the
label case-insensitively, exactly as `approvedPullRequest` does in
`src/Kanban/Workflow.hs`. Honour the configured mode: `label` accepts the
configured approval label, `review` accepts GitHub's own `reviewDecision ==
APPROVED`, and `either` accepts one or both. A repository configured for
`review` would otherwise look unapproved with a perfectly good approval on it.

Also resolve the configured `changes_requested_label` (default
`reviewed:changes`) and `blocked_labels` (default `blocked`) from that same
configuration, matched case-insensitively as `hasProblemLabel` does. Record
`baseRefName` too: merge-conflict repair must incorporate that exact branch, and
calling a failure pre-existing means reproducing it there rather than on a
guessed default branch.

Stop, having changed nothing, when the pull request is not approved under the
resolved mode, or when it carries a configured changes-requested or blocking
label. Report which condition held and what the pull request would need. An
unapproved pull request is somebody else's turn: a changes-requested pull
request belongs to $pr-revise, a blocked one to a human, and a pull
request that has never been reviewed to $pr-review. Never remove a
blocking label to proceed: a blocking label is a human's decision.

## 3. Diagnose the remaining obstacle

With approval established, address the highest-priority obstacle you find, in
this order:

1. **Merge conflict** — resolve it against the recorded `baseRefName`,
   preserving the pull request's intent while incorporating that base branch's
   current tip.
2. **Failed check** — EVERY failed entry in the pull request's status-check
   rollup, required or not, not only required checks, and not only the first
   one you notice. Triage them through step 5 before changing a single file.
3. **Nothing to fix** — no conflict and no failed check. Report the pull
   request's merge state and check state and stop without pushing, without
   rerunning anything, and without invoking a rereview. A pending check is not
   an obstacle: say it is still running and stop.

## 4. Work in the pull request's own worktree

This step applies only when step 3 or step 5 concluded that a file must change.
A rerun changes no file and needs no worktree at all.

Resolve the pull request's head repository, head branch, and exact head SHA
before editing anything, and record all three. `headRepositoryOwner` and
`headRepository` identify the head repository; `isCrossRepository` reports
whether it differs from the resolved repository the diagnosis above used.

A cross-repository pull request is fail-closed. When the head repository differs
from the resolved repository, `headRefName` is not a branch of the resolved
repository, so never fetch or push that name there: doing so would miss the
recorded head, or overwrite an unrelated branch that merely shares its name.
Fetch the head commit from the head repository itself, or read-only from the
resolved repository's `pull/<pr>/head` ref, and push only to the head
repository's own `headRefName`.

Decide whether that push is possible from the head repository itself, never from
`maintainerCanModify`: that field reports whether the *base* repository's
maintainers may modify the branch, which is neither necessary nor sufficient for
the account running this workflow — a fork owner fixing their own pull request
routinely has it false and can still push. Attempt the ordinary non-force push
to the head repository and let its outcome answer the question. When it is
rejected for lack of write access, stop and report that the pull request's head
cannot be safely written, having changed nothing on the remote, and never fall
back to pushing anywhere else.

Select the worktree by that branch, not by an issue number: reuse any worktree
registered to this repository that is already on the pull request's exact head
branch, and confirm it tracks the recorded head repository's `headRefName`
rather than merely a local branch of the same name.

```bash
git worktree list
```

A dirty or interrupted reused worktree is recoverable work, not a collision:
inspect `git status`, `git diff`, `git diff --cached`, and committed progress
relative to the recorded head, then preserve and continue there. Never discard,
reset, or overwrite unfinished changes, and never create a second worktree on
the same branch merely because the first is dirty.

Only when no worktree is on that branch, create one keyed on the pull request
number under the repository-scoped worktrees root
`${WORKTREES_ROOT:-$HOME/worktrees}/<owner>/<repo>/pr-<n>-<slug>`, outside the
source checkout. Never switch the repository's primary checkout.

Make the smallest change that clears the diagnosed obstacle, then run the checks
the changed paths and that obstacle actually select. Commit that fix as a
focused commit before pushing — an uncommitted working tree pushes nothing — and
leave any recovered work from a reused worktree intact rather than reverting it
or folding it into the fix.

Before pushing, re-fetch the pull request branch from the recorded head
repository and verify its remote head still equals the recorded SHA. Push to
that exact branch, in that head repository, without force. If the remote head
moved, stop and report the competing update rather than overwriting it.

After pushing, verify the head repository's `headRefName` now resolves to a SHA
different from the one recorded at the start. That verified new SHA is what
"pushed a new head" means in step 6; a push that left the head unchanged
transferred no fix, so treat it as having pushed nothing, invoke no rereview,
and report it.

## 5. Triage every failed check before fixing or rerunning anything

A failed check is one of two different things, and confusing them is how a real
defect gets retried until it passes. Enumerate the whole rollup first — the
obstacle is the SET of failed entries, never the first one you looked at:

```bash
gh pr view <pr> -R <owner/name> --json statusCheckRollup --jq '.statusCheckRollup[] | [.__typename, .name // .context, .conclusion // .state, .detailsUrl] | @tsv'
```

### 5a. Not every rollup entry is a workflow run

`statusCheckRollup` mixes two kinds of entry, and only one of them can be
classified or rerun by the commands below:

* A **`CheckRun` whose `detailsUrl` names this repository's own
  `/actions/runs/<run-id>`** is a GitHub Actions job. Recover `<run-id>` from
  that URL; several failed entries commonly share ONE run id, and the run — not
  the entry — is the unit everything below acts on.
* **Anything else** — a `StatusContext` posted by an external service, or a
  `CheckRun` from a non-Actions app whose `detailsUrl` names no Actions run —
  has no run to read jobs from and no run to rerun. Never issue `gh run view` or
  `gh run rerun` against it, and never guess a run id for it.

**A failed entry of the second kind fails closed.** Report it by name, say that
this workflow cannot classify or rerun an external check, and stop — without
rerunning the Actions runs beside it and without editing a file. Someone who can
read that service's own result has to decide what it means.

### 5b. Classify each distinct failed run

For every distinct run id among the failed Actions entries, read that run's own
jobs. Decide by what executed, never by the check's name and never by how the
failure feels:

```bash
gh run view <run-id> -R <owner/name> --json jobs --jq '.jobs[] | "\(.conclusion) \(.name)"'
gh run view <run-id> -R <owner/name> --log-failed
```

**An infrastructure failure is one where no job that executed the pull
request's code reported a failure.** Every failure in the run is a
cancellation, a timeout, a runner or registry error, or an aggregator job
reporting on a dependency that never ran — a job whose steps did not compile,
lint, or test the pull request's tree. Concurrency-group eviction is the
canonical case: a setup job is cancelled with no steps, the jobs needing it are
skipped, and a summary job fails asserting they succeeded, having built nothing.

**Everything else is a real failure**, including a test that failed on this
pull request's own code, a compile or lint error, and a check that failed
because the pull request is genuinely incompatible with its base. A failure you
believe is flaky is a real failure for this workflow's purposes: it executed the
code and it reported a result.

### 5c. Route on the whole set, not on one run

**If ANY failed run is a real failure**, take the fix path for all of them: fix
the causes in the worktree of step 4, push, and hand off the rereview of step 6.
Rerun nothing — a rerun that ran beside a real failure would clear one red check
and leave the pull request just as unmergeable, having spent the allowance.
Never delete or skip a test, never weaken an assertion, and never rerun a real
failure to see whether it passes the second time. A failure you judge to be
pre-existing on the recorded base branch must be reported to the user and stop
the run rather than papered over.

**Only when EVERY failed run is an infrastructure failure**, rerun each of those
runs exactly once:

```bash
gh run rerun <run-id> -R <owner/name> --failed
```

**One rerun per run, then stop. There is never a second for the same run.**

### 5d. Re-evaluate the complete rollup afterwards

Wait for every rerun to finish, then RE-FETCH the whole rollup with the command
in step 5 and judge the pull request on what it says now — never on the reruns'
own outcomes alone. A rollup that was green for the reruns can still carry a
failed entry that was not part of them, including one that only appeared while
they ran.

* **No failed entry remains** — the obstacle is cleared and this workflow is
  done.
* **A failed entry remains** — stop and report it, whatever its kind and
  whatever it looks like. Do not rerun a run this invocation already reran, do
  not start a fix, and do not invoke a rereview. A failure that survives one
  rerun is evidence, and burying it under a third attempt is exactly what this
  ceiling exists to prevent.

Rerunning changes no file and pushes no commit, so the head SHA the approval was
granted against is unchanged and that approval still stands. A rerun therefore
never invokes a rereview and never touches a label.

This ceiling is deliberately tighter than the PR drainer's. `tools/drain_prs.py`
retries a failed required check up to its own `MAX_CI_RERUN_ATTEMPTS`, keyed to
the approved head and quarantining that head once the allowance is spent — the
right shape for an unattended daemon that nobody is watching, and that needs an
attempt-identity barrier because it re-reads the same rollup on every poll. This
workflow is the opposite situation: a person invoked it and is waiting for the
answer, so a second failure is worth more to them than a third attempt. Neither
ceiling is the other's bug. Do not raise this one to match the drainer's, and do
not lower the drainer's to match this one.

## 6. Hand off exactly one canonical rereview

When you pushed a new head, finish by invoking exactly one canonical rereview;
that handoff is what re-establishes the verdict on the new head. Do not assume
the pull request is still approved after you push — it is not, because the
approval named the SHA you replaced.

When you pushed nothing — the rerun branch, the nothing-to-fix branch, or a stop
in step 2 or step 5 — there is no new head, so invoke no rereview and simply
report what you found.

Kanban resumes this session with the *fixed* repository as the working
directory, not this plugin's own install location, so locate the installed
coordinator by searching under `$CODEX_HOME` (default `~/.codex`) rather than a
path relative to the current directory.

```bash
COORDINATOR="$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" -path '*/kanban/*/skills/pr-review/scripts/review_pr.py' 2>/dev/null | head -n1)"
python3 "$COORDINATOR" \
  --path "$(git rev-parse --show-toplevel)" \
  --rereview <pr> \
  --allow-no-issue \
  --json
```

Do not pass `--self-review`: this session runs on the pull request's own origin
brand and cannot review as the opposite brand itself, so the coordinator must
spawn that nested reviewer. Add `--repo <owner/name>` and `--config <path>` to
that same call whenever the caller supplied them.

The standalone allowance preserves a prior no-issue review contract and still
validates every linked issue when closing-issue references exist. When a push
happened but the rereview is unavailable — for example, the coordinator rejects
a pull request with no prior canonical review marker or blocks an invalid or
unapproved linked issue — stop and report that exact reason. Never compensate by
setting a label yourself.

## 7. Report

Return the pull request number, how approval was established and under which
configured mode, the diagnosed obstacle, and then whichever of these applies:
for a rerun, the run id, that it was rerun exactly once, and the second
attempt's outcome; for a fix, the recorded and pushed head SHAs, which worktree
was used and whether it was reused or created, exactly what changed and what was
run, the state of the pushed head's checks, and the canonical rereview route,
verdict, and comment URL — or the exact reason no rereview ran.
