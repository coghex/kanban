---
name: fix
description: Clear an already-approved GitHub pull request's remaining obstacle so it can merge — resolve a merge conflict, update a branch that is behind its base, or fix a failed check and hand off to a canonical rereview. Never retries a check: the PR drainer owns that. Refuses any pull request that is not approved. Runs only on an explicit request to fix, unblock, or clear an approved pull request: when the user invokes {{cmd:fix}} or asks in that turn for one to be made mergeable. A question about WHY a pull request cannot merge is a diagnostic request, not this workflow.
argument-hint: "[PR number]"
---

# Fix an approved pull request

Clear the one thing standing between an approved pull request and the merge
queue, taking its number from the argument below. This workflow touches the
pull request's own code, so this session runs on the pull request's own origin
brand, the same way {{cmd:pr-revise}} and {{cmd:repair}} do.

**A diagnosis is not authorisation.** This workflow commits, pushes, and hands
off a rereview, so it runs only when the user asked in that
turn for the pull request to be fixed, unblocked, or made mergeable. "Why can't
this merge?" and "what is blocking this?" ask for none of that: answer them by
running step 2 and step 3, reporting the obstacle you found, and stopping there
— no worktree, no push. Then say what this workflow would do about it
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

<!-- brand:claude -->
Take the pull request number from `$ARGUMENTS`, which Claude Code substitutes
before the session reads this file.
<!-- brand:codex -->
Take the pull request number the user supplied in the prompt; Codex substitutes
no argument placeholder.
<!-- /brand -->

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

This workflow acts only on an approved pull request. It is what makes the
workflow's remit narrow enough to be safe: a reviewer has already accepted this
code, so the only thing left to clear is whatever stands between that accepted
work and the merge queue. Read the pull request once and settle approval before
diagnosing anything:

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
brand's executable, which is why {{cmd:repair}} and {{cmd:pr-revise}} can take
their brand as given. This workflow is user-invoked: nothing upstream has made
that choice, so it makes it here, before any mutation.

Read the `pr-origin` marker out of the body fetched above and apply exactly the
rules `originFromBody` applies in `src/Kanban/PullRequestFlow.hs`: the body must
carry exactly ONE marker, of exactly one kind, as its final non-whitespace
content. Both markers present, the same marker twice, a marker with trailing
text after it, and no marker at all are each a refusal — not a default.

<!-- brand:claude -->
This is the Claude bundle, so the marker must be `<!-- pr-origin:claude -->`.
A `pr-origin:codex` pull request belongs to the Codex bundle's own fix
skill, not to this one.
<!-- brand:codex -->
This is the Codex bundle, so the marker must be `<!-- pr-origin:codex -->`.
A `pr-origin:claude` pull request belongs to the Claude bundle's own fix
command, not to this one.
<!-- /brand -->

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
request belongs to {{cmd:pr-revise}}, a blocked one to a human, and a pull
request that has never been reviewed to {{cmd:pr-review}}. Never remove a
blocking label to proceed: a blocking label is a human's decision.

## 3. Diagnose the remaining obstacle

Read the whole check rollup first — the obstacle is the SET of entries, never
the first one you looked at. Fetch it with the SAME query and fields
`src/Kanban/GitHub/Fetch.hs` uses, because the identity and recency fields are
what make the next paragraph possible and `gh pr view --json statusCheckRollup`
omits them:

```bash
ROLLUP="$(mktemp -t kanban-rollup)"
gh api graphql -f query='{repository(owner:"<owner>",name:"<name>"){pullRequest(number:<pr>){commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){totalCount nodes{__typename ... on CheckRun{name status conclusion startedAt completedAt checkSuite{app{slug}}} ... on StatusContext{context state createdAt creator{login}}}}}}}}}}' > "$ROLLUP"
# ... read $ROLLUP for every branch below, then:
rm -f "$ROLLUP"
```

`mktemp` puts that file OUTSIDE the checkout, and the `rm` is not optional.
Nothing this workflow does may leave a file in the working tree: CLAUDE.md's
hygiene rule is explicit about scratch files, `tools/drain_prs.py` has to
relocate any untracked file it finds before a fast-forward, and step 4 tells
you to PRESERVE untracked content in a reused worktree — so a stray artifact
here is one an obstacle-fixing run could fold into its own focused commit.

**A rollup entry is not the same thing as a CHECK.** GitHub returns every
context on the commit, including ones a later run superseded, so the same check
can appear twice — an old failure beside the passing rerun that replaced it.
Kanban never judges the raw list: `src/Kanban/GitHub/Decode.hs` keys each
context (`check:<app-slug>:<name>` for a `CheckRun`,
`status:<creator-login>:<context>` for a `StatusContext`), keeps only the most
recent context per key (`startedAt` falling back to `completedAt` for a check
run, `createdAt` for a status), and reads the verdict off THAT set alone. Do
the same before applying any branch below. Skipping it means treating a
superseded failure as current — and since the PR drainer reruns required checks
on its own schedule, a superseded failure is a state this repository actually
produces, not a hypothetical.

**If any entry lacks the fields that rule needs** — no `__typename` you
recognise, no key, or no timestamp on a context that shares a key with another
— the rollup falls to branch 2 and the run stops. Deduplicating on a guess is
how an "already green" pull request gets edited and rereviewed for nothing.

With approval established, address the highest-priority obstacle you find, in
this order:

1. **Merge conflict** — resolve it against the recorded `baseRefName`,
   preserving the pull request's intent while incorporating that base branch's
   current tip. This branch reads no check state, which is why it precedes the
   rollup test below.
2. **A rollup you cannot trust** — before any branch below draws a conclusion
   from the rollup, that rollup must be COMPLETE. GitHub caps the contexts it
   returns, so it can be truncated, and an entry can carry a shape this
   workflow does not understand. Kanban models both as `ChecksUnknown`
   (`src/Kanban/GitHub/Decode.hs` returns it when `totalCount` exceeds the
   nodes returned, and again when a context will not decode), and
   `src/Kanban/Workflow.hs` makes it neither ready nor pending — it is never a
   clearance. Establish completeness rather than assuming it:

   Compare the `totalCount` the query above returned against the number of
   nodes it returned beside it. They must be equal — the same comparison
   `src/Kanban/GitHub/Decode.hs` makes before it decodes a single context.
   This is why the rollup is fetched once, with `totalCount` alongside the
   nodes, rather than read from a convenience view that reports neither.

   **A truncated rollup, or any entry you cannot classify, fails closed:**
   report that the check state cannot be read completely and stop without
   pushing or invoking a rereview. An incomplete rollup can be hiding exactly
   the failed or pending entry the branches below test for, so treating it as
   absence would turn "I did not see one" into "there is none".
3. **Failed check** — EVERY failed check in the DEDUPLICATED set above,
   required or not, not only required checks, and not only the first one you
   notice. Fix the causes
   in the worktree of step 4, push, and hand off the rereview of step 6. Never
   delete or skip a test, never weaken an assertion, and never retry a failure
   instead of fixing it — see step 5, which forbids that outright. A failure
   you judge to be pre-existing on the recorded base branch is reported to the
   user and stops the run rather than being papered over.
4. **A check still running** — no conflict, a rollup you can trust, no failed
   check, and a pending one in that same deduplicated set. This branch MUTATES NOTHING. Report which checks
   are still running and stop: do not update the branch, do not push, and do
   not invoke a rereview. `pullRequestStatus` ranks it this way too —
   `checksPending` is guarded BEFORE the merge-state test — and the reason is
   the same one that ranks it here: replacing the approved head while CI is
   still running discards the very run that would have told you whether there
   was anything to fix, and starts the whole thing again on a head nobody has
   reviewed.
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
   that this workflow has no remedy for it, and stop without pushing or
   invoking a rereview. Only `MergeClean` and `MergeProtected` are ready
   (`mergeStateReady`); everything else that is not `BEHIND` lands here.
7. **Nothing to fix** — no conflict, no failed check, no pending check, and a
   merge state that is ready. Report the pull request's merge state and check
   state and stop without pushing and without invoking a rereview. `UNKNOWN`
   is not a clearance either — GitHub has not finished computing
   mergeability, so it lands in branch 6 and stops rather than being reported
   ready when it may yet come back `BEHIND` or `DIRTY`.

## 4. Work in the pull request's own worktree

This step applies only when step 3 concluded that the head must move — a merge
conflict, a base the head is behind, or a check failure to fix. Every other
branch of step 3 mutates nothing and needs no worktree at all.

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
inspect `git status`, `git diff`, and `git diff --cached`, then preserve and
continue there. Never discard, reset, or overwrite unfinished changes, and never
create a second worktree on the same branch merely because the first is dirty.

**But a reused worktree whose HEAD is not the recorded head stops the run.**
Uncommitted work is safe to keep — it reaches the remote only if you commit it,
and the focused commit stages only what you changed. COMMITTED work is not:

```bash
git -C <worktree> rev-parse HEAD
```

If that is not the SHA recorded at the start of this step, the worktree carries
commits the pull request's head does not. A push from there is an ordinary
fast-forward that publishes every one of them alongside your fix — no force, no
warning, and no way for the "at most one focused commit" limit to hold. Those
commits are somebody's interrupted work, they have never been reviewed, and
deciding to publish them is not this workflow's call. Report the worktree, the
recorded head, and the commits between them, and stop. The same applies when
HEAD has diverged rather than merely advanced.

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

## 5. Never rerun a check

This workflow does not retry a red check, ever. A failed check is fixed or it
is reported; there is no third option and no circumstance — however plainly
infrastructural the failure looks — under which this workflow reruns one.

That is a deliberate boundary, not an oversight. `tools/drain_prs.py` already
reruns a failed required check on an approved pull request, keyed to the
approved head, with a duplicate-request barrier and a quarantine once its
`MAX_CI_RERUN_ATTEMPTS` allowance is spent. Retrying is that daemon's job, it
does it more carefully than a one-shot invocation can, and a second rerunner
with its own ceiling would mean two components disagreeing about the same
pull request. {{cmd:repair}} holds the same prohibition for the same reason.

So: no `gh run rerun`, no "just once to see", and no retry loop. A failure you
believe is flaky is still a failure this workflow reports rather than retries —
report it, say the drainer retries required checks on its own schedule, and
let the human decide whether that is what they want to wait for.

## 6. Hand off exactly one canonical rereview

When you pushed a new head, finish by invoking exactly one canonical rereview;
that handoff is what re-establishes the verdict on the new head. Do not assume
the pull request is still approved after you push — it is not, because the
approval named the SHA you replaced.

When you pushed nothing — any of step 3's non-mutating branches, or a stop in
step 2 or 2b — there is no new head, so invoke no rereview and simply report
what you found.

<!-- brand:claude -->
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
<!-- brand:codex -->
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
<!-- /brand -->

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
configured mode, the origin marker that admitted it, and the diagnosed
obstacle. For a non-mutating branch, that plus what it reported is the whole
report. For a fix or a branch update: the recorded and pushed head SHAs, which
worktree was used and whether it was reused or created, exactly what changed
and what was run, the state of the pushed head's checks, and the canonical
rereview route, verdict, and comment URL — or the exact reason no rereview ran.
