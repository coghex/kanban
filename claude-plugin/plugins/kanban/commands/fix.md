---
description: Clear an already-approved GitHub pull request's remaining obstacle so it can merge — resolve a merge conflict, update a branch that is behind its base, or fix a failed check and hand off to a canonical rereview. Never retries a check: the PR drainer owns that. Refuses any pull request that is not approved. Runs only on an explicit request to fix, unblock, or clear an approved pull request: when the user invokes /fix or asks in that turn for one to be made mergeable. A question about WHY a pull request cannot merge is a diagnostic request, not this workflow.
argument-hint: "[PR number]"
---

# Fix an approved pull request

Clear the one thing standing between an approved pull request and the merge
queue, taking its number from the argument below. This workflow touches the
pull request's own code, so this session runs on the pull request's own origin
brand, the same way /pr-revise does.

Run this in a **Class A** session (see the `model-classes` skill).

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

Keep the three inputs in shell variables, because the approval fences below run
as written and read them: `PR` is the positive pull request number, `REPO` is
the resolved `<owner>/<name>`, and `CONFIG` is the explicit configuration path
the caller supplied, empty when it supplied none.

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
`src/Kanban/Workflow.hs`. Honour the configured mode: `label` reads the
configured approval label, `review` reads GitHub's own `reviewDecision ==
APPROVED`, and `either` reads both. A repository configured for `review` would
otherwise look unapproved with a perfectly good approval on it.

**None of those signals is approval on its own.** Each is necessary and none is
sufficient: a label and a `reviewDecision` are mutable metadata that name no
commit, so neither can say which head a reviewer accepted. Step 2c binds the
mode's signal to the current head, and only a signal that survives that binding
is the approval this workflow acts on.

Record the `headRefOid` that read returned as `RECORDED_HEAD`. It is the head
this run diagnoses and edits, step 4 records the same value, and every approval
below must have been evaluated at exactly it.

Also resolve the configured `changes_requested_label` (default
`reviewed:changes`) and `blocked_labels` (default `blocked`) from that same
configuration, matched case-insensitively as `hasProblemLabel` does. Record
`baseRefName` too: merge-conflict repair must incorporate that exact branch, and
calling a failure pre-existing means reproducing it there rather than on a
guessed default branch.

## 2b. Require the pull request's origin to be this brand

This workflow is user-invoked: the user chose which brand's session runs it,
and nothing upstream has checked that the choice matches the pull request, so it
checks here, before any mutation.

Read the `pr-origin` marker out of the body fetched above and apply exactly the
rules `origin_from_body` applies in the bundled coordinator's `review_pr.py`:
the body must carry exactly ONE marker, of exactly one kind, as its final
non-whitespace content. Both markers present, the same marker twice, a marker with trailing
text after it, and no marker at all are each a refusal — not a default. The
approval helper of step 2c applies these same rules to the same body, at the
initial check and again before the push, and refuses with the reason; this step
states what it requires so the brand it must name is explicit here.

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

Stop, having changed nothing, when the pull request carries a configured
changes-requested or blocking label — that stop needs no further evidence,
since the label itself is a human's decision to reverse. Report which one: a
changes-requested pull request belongs to /pr-revise, a blocked one to
a human. Never remove a blocking label to proceed.

A pull request that simply lacks the resolved mode's raw approval signal — no
configured label attached, no `reviewDecision == APPROVED` — is not a stop
here. Whether the right remedy is /pr-review or /pr-rereview
turns on review history the raw signal alone cannot carry: a label a
legitimate stale-approval dismissal just stripped, and a pull request nobody
has ever reviewed, look identical if judged by the label's absence alone.
Continue to 2c, which reads the same evidence that binds an approval to the
current head and settles that question from it.

## 2c. Bind that approval to the current head

An approval names a commit. The signals step 2 read do not: a configured label
and a `reviewDecision` are mutable pull-request metadata that outlive a push,
so a third party can add a commit while every one of them still reads green
over code nobody reviewed. Left there, this workflow would take that unreviewed
head as its authority to create a worktree, edit it, and push another commit on
top of it.

**An approval that cannot be bound to the current `headRefOid` is not an
approval here.** Establish the binding before step 3 diagnoses anything. A pull
request whose current head does not carry head-bound approval gets no worktree,
no repair, no commit, no push, and no rereview handoff: the run stops having
changed nothing, exactly as it does for a pull request that was never approved.

This is the rule the rest of this repository already applies.
`tools/drain_prs.py` records the approved head with no default — inventing one
would let an unreviewed head through — and refuses with `approved_head_changed`
when the approval label is attached to a head that is not the approved one.
Carrying the approval forward instead is not available here: the drainer's
content-safe carry answers for a branch update the drainer itself performed and
observed, while this workflow faces an arbitrary third-party push whose
contents it can establish nothing about.

Run the bundled approval helper under its `fix` policy. It reads the
authenticated publisher, the pull request, and the evidence itself, and it
changes nothing:

```bash
APPROVAL_HELPER="${CLAUDE_PLUGIN_ROOT}/scripts/pr_head_approval.py"
APPROVED_HEAD=""
APPROVAL="$(python3 "$APPROVAL_HELPER" --policy fix --brand claude --repo "$REPO" --pr "$PR" --config "${CONFIG:-}")"
APPROVAL_STATUS=$?
APPROVED_HEAD="$(python3 - "$APPROVAL_STATUS" "$APPROVAL" "${RECORDED_HEAD:-}" <<'PY'
import json
import sys

status, text, recorded = sys.argv[1:4]
try:
    result = json.loads(text)
except ValueError:
    result = None
if (
    status == "0"
    and isinstance(result, dict)
    and result.get("approved") is True
    and recorded
    and result.get("head") == recorded
):
    sys.stdout.write(recorded)
else:
    reason = result.get("reason") if isinstance(result, dict) else None
    sys.stderr.write(
        "fix: no head-bound approval at the recorded head: "
        + str(reason or "the approval result was unusable or named another head")
        + "\n"
    )
PY
)"
```

**The success test is all three of these, and nothing weaker.** The helper must
exit 0, its `approved` must be exactly `true`, and its `head` must equal
`RECORDED_HEAD`. Nonempty output, a refusal object, missing or malformed
output, a nonzero status, and an approval evaluated at any other head are each
a refusal: this fence then leaves `APPROVED_HEAD` empty, and every later step is
guarded on it. A `head` or `approval_head` in a refusal is a diagnostic and
never authority.

The helper's contract, in brief; the module docstring of
`tools/pr_head_approval.py`, which this workflow bundles, is the full one.

- **Inputs.** `--policy fix`, this bundle's brand, the resolved repository, one
  pull request number, and the explicit configuration path when there is one.
  Every read is scoped to that repository, so a fork checkout cannot redirect a
  read to a same-numbered pull request elsewhere.
- **Result.** One JSON object on approval and on every refusal: `approved`,
  `head` (the current head it evaluated), `approval_head` (the head the evidence
  names, null when it names none), `mode`, `origin`, `reason`, `marker_history`,
  and the `paths` outcomes, `label` and `review`, each with its own `met`,
  `evidence` and `detail`.
- **Exit status.** 0 only when `approved` is true; 1 for a refusal; 2 for a
  usage error. Under `either`, a read or parse failure confined to one evidence
  path is that path's unmet outcome and does not veto the other, so the helper
  still approves when the other path holds. A failure of an input every path
  needs — the authenticated publisher, the pull request metadata, a readable
  current head, or the origin check — always refuses.
- **The publisher, resolved first and fail-closed.** The helper resolves the
  authenticated login before it reads any evidence and refuses when it cannot: an
  unresolved login makes every ownership test vacuously true.
- **What it weighs.** The two kinds of evidence independently, whichever mode is
  configured: `label` requires the canonical-marker evidence, `review` requires
  the native-approval evidence, and `either` is met by whichever of the two holds
  — one path failing never vetoes valid evidence from the other. The configured
  changes-requested and blocking labels remain unconditional refusals under
  every mode and are weighed against neither path. The origin marker must name
  THIS bundle's brand under the rules of step 2b.
- **The canonical marker binds the `label` path.** The canonical coordinator
  writes the reviewed SHA into the marker it publishes,
  `<!-- pr-review:v2 reviewers=... models=... head=<40 hex> verdict=APPROVE -->`,
  and refuses to publish a verdict once the head has moved. The configured
  approval label stays necessary and stops being sufficient: the path is met
  only when that label is attached AND the newest marker the authenticated
  publisher wrote, chosen from the COMPLETE paginated feed by creation time with
  the comment id breaking ties, reads `verdict=APPROVE` at the current head and
  its `reviewers=` list does not name the origin brand. The helper reads the
  complete feed because a bounded view can leave the newest marker outside it,
  and an older verdict would then speak for a head nobody reviewed; it selects
  the newest comment BEFORE it tests what that comment says, and it accepts the
  established v2 shape and the legacy v1 shape. Missing evidence, an
  unreadable feed, and a malformed or multiply-markered newest comment each
  leave the path unmet rather than falling back to an older approval, and so
  does a newer non-approval over an older approval.
- **A native approval binds the `review` path.** `reviewDecision == APPROVED`
  stays necessary and stops being sufficient: it is an aggregate over the pull
  request, not a statement about a commit. The path is met only when one author's
  newest opinionated review (`APPROVED` or `CHANGES_REQUESTED`, by `submitted_at`
  with the review id breaking ties) is an `APPROVED` whose `commit_id` equals the
  current head. A dismissed, superseded, stale or unattributed approval is
  insufficient.

An approval that is not bound to the current head gets no worktree, no repair, no
commit, no push, and no rereview handoff: the run stops having changed nothing.

### The refusal, and who clears it

Report the helper's `reason` concretely and stop: the `head` it evaluated, the
`approval_head` the evidence names — or, when that is null, that the evidence is
missing or unreadable rather than naming any head at all — the `mode` that was
in force, and which `paths` went unmet. Say so too when the helper approved a
head other than `RECORDED_HEAD`: the pull request moved after it was read, and
the run starts over from step 2.

Then name the remedy without performing it. A `label` path left unmet is
cleared by a fresh canonical review of the current head. This workflow chooses
the command, not the helper: name /pr-rereview when `marker_history` is
`true` — the authenticated publisher has published a canonical `pr-review`
marker on this pull request at all, regardless of which head it named, whether a
later marker superseded it, or whether the configured label is currently
attached — and name /pr-review only when it is `false`. A label a
legitimate stale-approval dismissal just stripped, and a marker bound to a head
this pull request has since moved past, both mean it HAS been reviewed before;
only a feed with no marker at all means it has not. When `marker_history` is
`null` the feed was not read or could not be read: report that and name neither.
A `review` path left unmet is NOT cleared that way: the canonical coordinator
publishes a comment and switches verdict labels, and publishes no native GitHub
approval at all, so that path is cleared only by a reviewer approving the
current head on GitHub itself.

**This workflow manufactures neither.** It synthesizes no verdict label, and it
invokes no review of its own to produce the approval it is missing. Verdict
labels change only as a consequence of the one canonical rereview step 6 hands
off to after a real push, which a run stopping here never reaches.

## 3. Diagnose the remaining obstacle

Read the whole check rollup first — the obstacle is the SET of entries, never
the first one you looked at. Fetch it with the SAME query and fields
`src/Kanban/GitHub/Fetch.hs` uses, because `gh pr view --json statusCheckRollup`
omits the identity and recency fields the next paragraph needs:

```bash
ROLLUP="$(mktemp)"
gh api graphql -f query='{repository(owner:"<owner>",name:"<name>"){pullRequest(number:<pr>){commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){totalCount nodes{__typename ... on CheckRun{name status conclusion startedAt completedAt checkSuite{app{slug}}} ... on StatusContext{context state createdAt creator{login}}}}}}}}}}}' > "$ROLLUP"
# ... read $ROLLUP for every branch below, then:
rm -f "$ROLLUP"
```

Argument-free `mktemp` puts that file OUTSIDE the checkout, and the `rm` is not
optional. Nothing this workflow does may leave a file in the working tree.

**A rollup entry is not the same thing as a CHECK.** GitHub returns every
context on the commit, including ones a later run superseded. As
`src/Kanban/GitHub/Decode.hs` does, key each context (`check:<app-slug>:<name>`
for a `CheckRun`, `status:<creator-login>:<context>` for a `StatusContext`),
keep only the most recent per key (`startedAt` falling back to `completedAt` for
a check run, `createdAt` for a status), and read the verdict off THAT set alone
before applying any branch below.

**If any entry lacks the fields that rule needs** — no `__typename` you
recognise, no key, or no timestamp on a context that shares a key with another
— the rollup falls to branch 2 and the run stops. Never deduplicate on a guess.

With approval established, address the highest-priority obstacle you find, in
this order:

1. **Merge conflict** — resolve it against the recorded `baseRefName`,
   preserving the pull request's intent while incorporating that base branch's
   current tip. This branch reads no check state, which is why it precedes the
   rollup test below.
2. **A rollup you cannot trust** — before any branch below draws a conclusion
   from the rollup, that rollup must be COMPLETE. GitHub caps the contexts it
   returns, and an entry can carry a shape this workflow does not understand;
   Kanban models both as `ChecksUnknown` (`src/Kanban/GitHub/Decode.hs`), which
   is never a clearance. Establish completeness:

   When `statusCheckRollup` itself is `null` or absent, treat it as `ChecksNone`,
   exactly as `parseChecks` does in `src/Kanban/GitHub/Decode.hs`: GitHub is
   reporting NO checks, so continue through the later branches with no failed or
   pending checks. A PRESENT, non-null rollup whose `contexts`, `totalCount`, or
   nodes cannot be read still fails closed.

   Compare the `totalCount` the query above returned against the number of
   nodes it returned beside it. They must be equal.

   **A truncated rollup, or any entry you cannot classify, fails closed:**
   report that the check state cannot be read completely and stop without
   pushing or invoking a rereview.
3. **Failed check** — EVERY failed check in the DEDUPLICATED set above,
   required or not, not only the first one you notice. Fix the causes in the
   worktree of step 4, push, and hand off the rereview of step 6. Never delete
   or skip a test, never weaken an assertion, and never retry a failure instead
   of fixing it — see step 5. A failure you judge to be pre-existing on the
   recorded base branch is reported to the user and stops the run.
4. **A check still running** — no conflict, a rollup you can trust, no failed
   check, and a pending one in that same deduplicated set. This branch MUTATES
   NOTHING. Report which checks are still running and stop: do not update the
   branch, do not push, and do not invoke a rereview. `pullRequestStatus` guards
   `checksPending` BEFORE the merge-state test.
5. **Behind its base** — no conflict, no failed check, no pending check, and
   the merge state is exactly `BEHIND`.
   Green checks do not make it mergeable. Update it from the recorded
   `baseRefName` through step 4, exactly as the conflict branch does.
6. **Any other merge state that is not ready** — `BLOCKED` and `UNSTABLE`
   (`MergeBlocked`, `MergeUnstable`) are not `BEHIND`'s problem:
   a branch update cannot clear a branch-protection requirement or an unstable
   required check, and would replace the reviewed head for nothing. This branch
   fails closed: report the exact merge state, say that this workflow has no
   remedy for it, and stop without pushing or invoking a rereview. Only
   `MergeClean` and `MergeProtected` are ready (`mergeStateReady`); everything
   else that is not `BEHIND` lands here, `UNKNOWN` included.
7. **Nothing to fix** — no conflict, no failed check, no pending check, and a
   merge state that is ready. Report the pull request's merge state and check
   state and stop without pushing and without invoking a rereview.

## 4. Work in the pull request's own worktree

This step applies only when step 3 concluded that the head must move — a merge
conflict, a base the head is behind, or a check failure to fix. Every other
branch of step 3 mutates nothing and needs no worktree at all.

Resolve the pull request's head repository, head branch, and exact head SHA
before editing anything, and record all three — the SHA is the `RECORDED_HEAD`
of step 2, and it must be that same value, because the diagnosis worked on it
and the approval of step 2c was evaluated at it. Name the head repository's
remote `HEAD_REMOTE` and its branch `HEAD_BRANCH`, and the worktree you work in
`WORKTREE`. `headRepositoryOwner` and `headRepository` identify the head
repository; `isCrossRepository` reports whether it differs from the resolved
repository the diagnosis above used.

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
A fix to documentation that goes with the change is landed with `docs-push` and
linked from the PR body as `Docs: <path> @ <commit>`, placed before the origin
marker, instead of being committed to the branch — unless `docs-push` refuses
the path as code, or this checkout's own `origin` is not the pull request's base
repository (a fork checkout): `docs-push` publishes to `origin`, so in either
case the documentation is committed to the branch like the code.
Unless the spec names its path, a verdict or evidence write-up goes under
`docs/archive/`, because it records finished work and repositories hide that
directory from search; design notes and contracts are updated where they live.
That decides only where the file goes, not how it lands.

Before pushing, re-fetch the pull request branch from the recorded head
repository and verify its remote head still equals the recorded SHA. If the
remote head moved, stop and report the competing update rather than
overwriting it.

After that head check and IMMEDIATELY before the push, run the approval helper
again. It re-reads the pull request, the authenticated publisher, and the
evidence itself, so nothing cached from step 2c can answer for this moment: a
canonical verdict can be superseded and a native approval dismissed while the
head never moves, so an earlier reading would carry an authority that has since
been withdrawn straight into the push. The guard is step 2c's, applied to fresh
evidence and bound to `RECORDED_HEAD`, and it can run only behind the initial
guard:

```bash
: "${APPROVED_HEAD:?the initial approval guard did not pass; nothing may follow it}"
APPROVAL_HELPER="${CLAUDE_PLUGIN_ROOT}/scripts/pr_head_approval.py"
PUSH_APPROVED_HEAD=""
APPROVAL="$(python3 "$APPROVAL_HELPER" --policy fix --brand claude --repo "$REPO" --pr "$PR" --config "${CONFIG:-}")"
APPROVAL_STATUS=$?
PUSH_APPROVED_HEAD="$(python3 - "$APPROVAL_STATUS" "$APPROVAL" "${RECORDED_HEAD:-}" <<'PY'
import json
import sys

status, text, recorded = sys.argv[1:4]
try:
    result = json.loads(text)
except ValueError:
    result = None
if (
    status == "0"
    and isinstance(result, dict)
    and result.get("approved") is True
    and recorded
    and result.get("head") == recorded
):
    sys.stdout.write(recorded)
else:
    reason = result.get("reason") if isinstance(result, dict) else None
    sys.stderr.write(
        "fix: authority to push was lost: "
        + str(reason or "the approval result was unusable or named another head")
        + "\n"
    )
PY
)"
```

Exit 0, `approved` exactly `true`, and a `head` equal to `RECORDED_HEAD` are
required here exactly as in step 2c. The helper repeats every check of step 2b
and step 2c against what it reads now: the configured approval decision, the
changes-requested and blocking labels, the complete origin-marker parse
including that it still names THIS bundle's active brand, and the selected
mode's head-bound evidence, so a fresh `headRefOid` that is not the recorded SHA
refuses too.

If approval was withdrawn, the selected mode's head-bound evidence no longer
holds, any configured problem label appeared, the origin became missing,
malformed, or a different brand, or the head no longer matches, STOP with no
push and no rereview, and leave `PUSH_APPROVED_HEAD` empty. Leave the worktree's
existing work exactly as it is: a stop here is a loss of authority to publish,
not a reason to discard what was built. Do not perform other work between this
fresh guard and the push.

The remote-ref comparison does not replace this revalidation. A pull request's
body, labels, `reviewDecision`, canonical marker, and native reviews can all
change without moving its head SHA; the workflow's authority can therefore
disappear while the branch itself still looks unchanged.

Only after BOTH pre-push checks pass, push to that exact branch in the recorded
head repository, without force. The push is reachable only through the fresh
guard above:

```bash
: "${PUSH_APPROVED_HEAD:?the pre-push approval guard did not pass; push nothing}"
git -C "${WORKTREE:?}" push "${HEAD_REMOTE:?}" "HEAD:refs/heads/${HEAD_BRANCH:?}"
```

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
pull request.

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
step 2, 2b, or 2c — there is no new head, so invoke no rereview and simply
report what you found.

This plugin bundles its own copy of the coordinator at
`${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py`, so it never depends on the Codex
plugin being installed.

```bash
: "${PUSH_APPROVED_HEAD:?the pre-push approval guard did not pass; invoke no rereview}"
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py" \
  --path "$(git rev-parse --show-toplevel)" \
  --rereview "$PR" \
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
configured mode, which head-bound evidence bound it to the current head, the
origin marker that admitted it, and the diagnosed obstacle. For a non-mutating branch, that plus what it reported is the whole
report. For a fix or a branch update: the recorded and pushed head SHAs, which
worktree was used and whether it was reused or created, exactly what changed
and what was run, the state of the pushed head's checks, and the canonical
rereview route, verdict, and comment URL — or the exact reason no rereview ran.
