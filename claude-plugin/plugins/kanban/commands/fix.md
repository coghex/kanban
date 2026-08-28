---
description: Clear an already-approved GitHub pull request's remaining obstacle so it can merge — resolve a merge conflict, rerun CI once when the failure never executed the pull request's code, or fix a genuine check failure and hand off to a canonical rereview. Refuses any pull request that is not approved. Runs only on an explicit request to fix, unblock, or clear an approved pull request: when the user invokes /fix or asks in that turn for one to be made mergeable. A question about WHY a pull request cannot merge is a diagnostic request, not this workflow.
argument-hint: "[PR number]"
---

# Fix an approved pull request

Clear the one thing standing between an approved pull request and the merge
queue, taking its number from the argument below. This workflow touches the
pull request's own code, so this session runs on the pull request's own origin
brand, the same way /pr-revise and /repair do.

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

Take the pull request number from `$ARGUMENTS`, which Claude Code substitutes
before the session reads this file.

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
gh pr view <pr> -R <owner/name> --json number,body,baseRefName,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository,mergeStateStatus,mergeable,labels,reviewDecision,statusCheckRollup,closingIssuesReferences,url
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

## 2b. Require the pull request's origin to be this brand

Kanban's own CLI resolves a pull request's origin and spawns the matching
brand's executable, which is why /repair and /pr-revise can take
their brand as given. This workflow is user-invoked: nothing upstream has made
that choice, so it makes it here, before any mutation.

Read the `pr-origin` marker out of the body fetched above and apply exactly the
rules `originFromBody` applies in `src/Kanban/PullRequestFlow.hs`: the body must
carry exactly ONE marker, of exactly one kind, as its final non-whitespace
content. Both markers present, the same marker twice, a marker with trailing
text after it, and no marker at all are each a refusal — not a default.

This is the Claude bundle, so the marker must be `<!-- pr-origin:claude -->`.
A `pr-origin:codex` pull request belongs to the Codex bundle's own fix
skill, not to this one.

**A missing, malformed, or opposite-brand marker stops the run with nothing
changed.** This is not bureaucracy: the coordinator routes the rereview from
that same marker, so editing a pull request whose origin names the OTHER brand
would have this session author a change and then hand it to its own brand to
review — the one thing the whole origin-marker mechanism exists to prevent. An
unknown-origin pull request stops here too; it has no declared brand to match,
and guessing one would be inventing the very fact this check exists to read.

Stop, having changed nothing, when the pull request is not approved under the
resolved mode, or when it carries a configured changes-requested or blocking
label. Report which condition held and what the pull request would need. An
unapproved pull request is somebody else's turn: a changes-requested pull
request belongs to /pr-revise, a blocked one to a human, and a pull
request that has never been reviewed to /pr-review. Never remove a
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
3. **A rollup you cannot trust** — before any branch below is allowed to
   clear or mutate the pull request, the check rollup must be COMPLETE and
   every entry in it classifiable. GitHub caps the contexts it returns, so a
   rollup can be truncated, and an entry can carry a shape this workflow does
   not understand. Kanban models both as `ChecksUnknown`
   (`src/Kanban/GitHub/Decode.hs` returns it when `totalCount` exceeds the
   nodes returned, and again when a context will not decode), and
   `src/Kanban/Workflow.hs` makes it neither ready nor pending — it is never a
   clearance. Establish completeness rather than assuming it:

   ```bash
   gh api graphql -f query='{repository(owner:"<owner>",name:"<name>"){pullRequest(number:<pr>){commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){totalCount}}}}}}}}' --jq '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.totalCount'
   ```

   Compare that `totalCount` against the number of entries the step-5 rollup
   command returned. They must be equal — the same comparison
   `src/Kanban/GitHub/Decode.hs` makes before it decodes a single context.

   **A truncated rollup, or any entry you cannot classify, fails closed:**
   report that the check state cannot be read completely and stop without
   pushing, rerunning, or invoking a rereview. An incomplete rollup can be
   hiding exactly the failed or pending entry the branches below test for, so
   treating it as absence would turn "I did not see one" into "there is none".
4. **A check still running** — no conflict, no failed check, a rollup you can
   trust, and a pending entry in it. This branch MUTATES NOTHING. Report which checks
   are still running and stop: do not update the branch, do not rerun, do not
   push, and do not invoke a rereview. `pullRequestStatus` ranks it this way
   too — `checksPending` is guarded BEFORE the merge-state test — and the
   reason is the same one that ranks it here: replacing the approved head
   while CI is still running discards the very run that would have told you
   whether there was anything to fix, and starts the whole thing again on a
   head nobody has reviewed.
5. **Behind its base** — no conflict, no failed check, no pending check, and
   the merge state is exactly `BEHIND`, which
   `src/Kanban/Workflow.hs`'s `pullRequestStatus` classifies as `merge
   pending` and `src/Kanban/UI/Details.hs` explains as "the base has advanced
   past this head; update the branch before merging". Green checks do not make
   such a pull request mergeable. Update it from the recorded `baseRefName`
   through step 4, exactly as the conflict branch does — incorporating a base
   tip is one operation, and a conflict is only its harder case.
6. **Any other merge state that is not ready** — `BLOCKED` and `UNSTABLE` are
   real states (`MergeBlocked`, `MergeUnstable`), and `pullRequestStatus`
   reports them as `merge pending` exactly as it does `BEHIND`. They are NOT
   the same problem: a branch update cannot clear a branch-protection
   requirement or an unstable required check, so applying `BEHIND`'s remedy to
   them would replace the reviewed head and leave the pull request just as
   unmergeable. This branch fails closed: report the exact merge state, say
   that this workflow has no remedy for it, and stop without pushing,
   rerunning, or invoking a rereview. Only `MergeClean` and `MergeProtected`
   are ready (`mergeStateReady`); everything else that is not `BEHIND` lands
   here.
7. **Nothing to fix** — no conflict, no failed check, no pending check, and a
   merge state that is ready. Report the pull request's merge state and check
   state and stop without pushing, without rerunning anything, and without
   invoking a rereview. `UNKNOWN` is not a clearance either — GitHub has not
   finished computing mergeability, so it lands in branch 6 and stops rather
   than being reported ready when it may yet come back `BEHIND` or `DIRTY`.

## 4. Work in the pull request's own worktree

This step applies only when step 3 or step 5 concluded that the head must
move — a merge conflict, a base the head is behind, or a real check failure. A
rerun changes no file and needs no worktree at all, and neither does a pending
check, which mutates nothing at all.

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
request's code reported a failure.** That sentence is the whole test, and the
examples below are subordinate to it: an example that turns out to have
executed the tree is a REAL failure, whatever it is called.

Every failure in such a run is a cancellation, a runner or registry error, or
an aggregator job reporting on a dependency that never ran — a job whose steps
did not compile, lint, or test the pull request's tree. Concurrency-group
eviction is the canonical case: a setup job is cancelled with no steps, the
jobs needing it are skipped, and a summary job fails asserting they succeeded,
having built nothing.

**A timeout is not automatically infrastructure**, and it is the one that will
tempt you. A job that checked out the tree and then hung — an infinite loop, a
deadlock, a performance regression that pushed a suite past its limit — timed
out BECAUSE of the pull request's code, and rerunning it just spends the
allowance to watch it hang again. Read the timing-out job's own steps before
classifying it: a timeout counts as infrastructure only where the evidence
shows no step had begun executing the tree — a runner that never picked the job
up, a queue or image-pull timeout, a setup job that timed out before checkout.
Anything past that point is a real failure and takes the fix path.

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

**The ceiling is read from GitHub, not from memory.** Before rerunning any run,
ask it how many attempts it has already had:

```bash
gh run view <run-id> -R <owner/name> --json attempt --jq .attempt
```

A first attempt reports `1`. **Anything greater than 1 means this run has
already been rerun** — by an earlier invocation of this workflow, by the PR
drainer, or by a person — so it is not rerun again: report its attempt count,
say the allowance for that run is spent, and stop. This is what makes "never a
second" hold across invocations rather than only within one, and it needs no
durable state of this workflow's own: the attempt counter is GitHub's, it
survives everything, and it counts every rerunner rather than just this one.

**Only when EVERY failed run is an infrastructure failure AND every one of them
is still on attempt 1**, rerun each of those runs exactly once — the WHOLE run,
with no `--failed`:

```bash
gh run rerun <run-id> -R <owner/name>
```

**Never `--failed` here.** That flag reruns "only failed jobs, including
dependencies", and a CANCELLED job is not a failed one — which is precisely the
signature 5b defines this branch by. A run whose bad jobs are all cancellations
offers `--failed` nothing to act on, so the retry silently accomplishes nothing
and the run stays red; the allowance is spent on a rerun that never happened.
The whole-run form has no such hole. It costs re-running the jobs that already
passed, which is the correct price for a retry that is always applicable.

**One rerun per run, then stop. There is never a second for the same run.**

### 5d. Re-evaluate the complete rollup afterwards

Wait for every rerun to finish, then RE-FETCH the pull request and run **step
3's whole diagnosis again** against what it says now — never the reruns' own
outcomes, and never the failed set alone. Clearing the failure is not the same
as clearing the obstacle: a pull request can carry a failed check AND an
unrelated pending one, where the failure correctly took priority and the
pending check still blocks the merge once it is gone. The reruns can also leave
the pull request `BEHIND` a base that moved while they ran.

Re-running the diagnosis answers all of that with the branches that already
exist, so this step adds no new judgement — only the discipline of asking
again:

* **Branch 7, nothing to fix** — the obstacle really is cleared and this
  workflow is done.
* **Branch 3, 4 or 6, a non-mutating stop** — report what it now says and stop,
  exactly as those branches specify.
* **Branch 1, 2 or 5, another head-moving obstacle** — report it and stop.
  Do NOT act on it in this invocation: the rerun already spent this run's
  allowance, and chaining a push onto it would make one invocation's blast
  radius unbounded. Say what the next invocation would do.

A failure that survives one rerun is evidence, and burying it under a third
attempt is exactly what this ceiling exists to prevent.

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

This plugin bundles its own copy of the coordinator at
`${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py`, so it never depends on the Codex
plugin being installed.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py" \
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
