---
name: finalize
description: Legacy manual fallback for merging a reviewed pull request when the PR drainer cannot be used. Refuses any pull request whose current head does not carry a fresh opposite-brand approval, a passing check set, and a clean merge state. Runs only when the user invokes {{cmd:finalize}} for one specific pull request, or when drainer recovery has established that manual finalization is the appropriate fallback — never on an agent's own initiative.
argument-hint: "[PR number]"
---

# Finalize a reviewed pull request

This is the fallback, not the merge path. The service-managed PR drainer
controlled by {{cmd:drain-prs}} is what merges eligible approved pull requests
out of the Done column, and it does so with a retry scheduler, an incident
record, and a post-merge audit this command has none of. Reach for
{{cmd:finalize}} only when the drainer cannot be used — it is not installed on
this host, it is stopped and its cause is not yet repaired, or the user has
looked at the situation and asked for a manual merge of one named pull request.

**Never choose this path automatically.** A pull request being ready is not a
reason to run this command. A solve session, a review session, and an autonomous
loop each stop at the open pull request; none of them may finalize one, and this
command's own gate is not a licence for any of them to try. It runs when the
user asks for it in that turn, for the pull request they named.

Everything below merges, closes, removes, and deletes. Read the gate first: it
is the only thing standing between an unreviewed head and the default branch.

## 1. Resolve the repository, then the target

Set `REPO` once, before the first GitHub read, and use that one identity for
every `gh` call in this workflow. A `gh` call without `-R` targets whatever
repository the session's working directory happens to be in, and this workflow's
calls merge a pull request and delete a branch — neither is recoverable by
editing a file afterwards.

Resolution reads the checkout's own remote and needs no GitHub call of its own,
so there is no point in this workflow at which an unscoped `gh` invocation is
correct:

```bash
ROOT="$(git worktree list --porcelain | sed -n '1s#^worktree ##p')"
REPO="$(git -C "$ROOT" remote get-url origin | sed -E 's#\.git$##; s#.*(/|:)([^/:]+/[^/:]+)$#\2#')"
```

`git worktree list` names the repository's primary checkout first, so `$ROOT` is
that checkout even when this session was started inside a linked worktree. Step
5 needs it: the cleanup runs from the primary checkout, never from inside the
worktree it is about to remove.

**Announce, then act:** name the resolved `$REPO` and the pull request number
before the first `gh` call below. Reporting what was resolved is what catches a
wrong resolution, and it catches it only if it lands before anything has been
merged in the wrong repository.

Then the target:

<!-- brand:claude -->
```bash
PR="$ARGUMENTS"
```

`$ARGUMENTS` is what Claude Code substitutes before the session reads this file.
<!-- brand:codex -->
```bash
PR="<the pull request number the user named>"
```

Codex substitutes no argument placeholder, so take the number from the prompt.
<!-- /brand -->

If no number was supplied, infer it from the current worktree's branch and
confirm it with the user before proceeding. Never guess it from the Done column.

## 2. The gate (FAIL CLOSED)

Run this exactly as written. It refuses on stderr and leaves `$HEAD` empty
unless every condition below holds, and every later step is guarded on `$HEAD`.

```bash
VIEWER="$(gh api user --jq .login)"
PR_STATE="$(gh pr view "$PR" -R "$REPO" --json number,url,headRefOid,headRefName,baseRefName,labels,mergeable,mergeStateStatus,closingIssuesReferences)"
PR_COMMENTS="$(gh api --paginate --slurp "repos/$REPO/issues/$PR/comments?per_page=100")"
PR_CHECKS="$(gh pr checks "$PR" -R "$REPO" --json name,state,bucket)"
HEAD="$(python3 - "$VIEWER" "$PR_STATE" "$PR_COMMENTS" "$PR_CHECKS" <<'PY'
import json
import re
import sys

V1_RE = re.compile(
    r"<!--\s*pr-review:v1\s+reviewer=(?:claude|codex)\s+"
    r"head=(?P<head>[0-9a-f]{40})\s+"
    r"verdict=(?P<verdict>APPROVE|CHANGES_REQUESTED)\s*-->",
    re.IGNORECASE,
)
# The coordinator joins both lists with commas, so a dual-reviewer marker is
# the ordinary shape rather than an exception, and `models=` is one token.
V2_RE = re.compile(
    r"<!--\s*pr-review:v2\s+"
    r"reviewers=(?:claude|codex)(?:,(?:claude|codex))*\s+"
    r"models=\S+\s+"
    r"head=(?P<head>[0-9a-f]{40})\s+"
    r"verdict=(?P<verdict>APPROVE|CHANGES_REQUESTED)\s*-->",
    re.IGNORECASE,
)
MARKER_OPENING_RE = re.compile(r"<!--\s*pr-review:v")

viewer = sys.argv[1].strip()
try:
    state = json.loads(sys.argv[2])
    pages = json.loads(sys.argv[3])
except ValueError:
    state = None
    pages = None
checks_text = sys.argv[4].strip()
number = state.get("number") if isinstance(state, dict) else None
subject = "PR #" + str(number) if number is not None else "the named pull request"


def refuse(detail, approval):
    if approval:
        headline = (
            "Refusing to finalize — " + subject + " lacks a current "
            "opposite-brand approval. Run {{cmd:pr-review}} or "
            "{{cmd:pr-rereview}} first."
        )
    else:
        headline = (
            "Refusing to finalize — " + subject + " is not ready to merge."
        )
    sys.stderr.write(headline + "\n")
    sys.stderr.write("finalize: " + detail + "\n")
    raise SystemExit(1)


if not isinstance(state, dict) or not isinstance(pages, list):
    refuse("the pull request or its comment feed could not be read", True)
# Fail closed on the identity too: an unresolved login would make every
# ownership comparison below vacuously true.
if not viewer:
    refuse("the authenticated GitHub login could not be resolved", True)

labels = {
    str(item.get("name") or "").lower()
    for item in state.get("labels") or []
    if isinstance(item, dict)
}
if "reviewed:approve" not in labels:
    refuse("reviewed:approve is not attached", True)
if "reviewed:changes" in labels:
    refuse("reviewed:changes is attached", True)

head = str(state.get("headRefOid") or "").lower()
if re.match(r"\A[0-9a-f]{40}\Z", head) is None:
    refuse("the pull request's current head could not be read", True)

# The whole feed, oldest page first, flattened before it is ordered: a bounded
# view can leave the newest marker outside it, and an older marker would then
# speak for a head nobody reviewed.
comments = []
for page in pages:
    if not isinstance(page, list):
        refuse("the comment feed could not be read", True)
    comments.extend(item for item in page if isinstance(item, dict))
ordered = sorted(
    comments,
    key=lambda item: (str(item.get("created_at") or ""), int(item.get("id") or 0)),
    reverse=True,
)

chosen = None
for comment in ordered:
    author = comment.get("user") or {}
    login = str(author.get("login") or "") if isinstance(author, dict) else ""
    if login.lower() != viewer.lower():
        continue
    body = str(comment.get("body") or "")
    match = V2_RE.search(body) or V1_RE.search(body)
    if match is None:
        if MARKER_OPENING_RE.search(body) is not None:
            refuse("the newest review marker you published is malformed", True)
        continue
    chosen = match
    break

if chosen is None:
    refuse("no review marker published by " + viewer + " is in the feed", True)
verdict = chosen.group("verdict").upper()
marker_head = chosen.group("head").lower()
if verdict != "APPROVE":
    refuse("the newest marker you published reads verdict=" + verdict, True)
if marker_head != head:
    refuse(
        "the newest marker you published names head "
        + marker_head
        + ", not the current head "
        + head,
        True,
    )

mergeable = str(state.get("mergeable") or "").upper()
if mergeable != "MERGEABLE":
    refuse("GitHub reports mergeable=" + (mergeable or "unset"), False)

if not checks_text:
    refuse("GitHub reported no checks on this head", False)
try:
    checks = json.loads(checks_text)
except ValueError:
    checks = None
if not isinstance(checks, list) or not checks:
    refuse("GitHub reported no checks on this head", False)
unfinished = sorted(
    str(item.get("name") or "?")
    + ":"
    + str(item.get("bucket") or item.get("state") or "?")
    for item in checks
    if not isinstance(item, dict)
    or str(item.get("bucket") or "").lower() not in ("pass", "skipping")
)
if unfinished:
    refuse("these checks are not successful: " + ", ".join(unfinished), False)

sys.stdout.write(head + "\n")
PY
)"
```

What that gate requires, and why each part is what it is:

- **The authenticated login, resolved fail-closed.** Only a marker *you*
  published counts, so an unresolved login refuses rather than accepting every
  marker in the feed. Logins are compared case-insensitively; GitHub does not
  preserve case in a way that may decide this.
- **The complete comment feed.** A pull request's `comments` field returns a
  bounded window, so on a long pull request the newest marker can fall outside
  it and an older verdict wins. The paginated issue-comments endpoint is read
  whole and
  flattened, then ordered newest-first by `created_at` with the comment id
  breaking ties, so the marker chosen is the globally newest one and the choice
  does not depend on the order GitHub happened to return.
- **The marker the coordinator publishes today.** That is
  `<!-- pr-review:v2 reviewers=… models=… head=… verdict=… -->`, and both of
  its list fields are comma-joined, so `reviewers=claude,codex` is an ordinary
  dual-reviewer marker and not a malformed one. The older
  `<!-- pr-review:v1 reviewer=… head=… verdict=… -->` spelling is still honoured
  for pull requests reviewed before the change. A gate that read v1 alone would
  refuse every pull request reviewed today, which is what the personal copy this
  command was vendored from did.
- **`head=` equal to the pull request's current `headRefOid`.** An approval names
  a commit, not a branch. `.github/workflows/review-gate.yml`'s
  `dismiss-stale-approval` job already removes `reviewed:approve` when a push
  touches a file the pull request owns, but a marker whose head no longer matches
  is stale whatever the label says, so the head comparison decides and not the
  label alone.
- **A malformed marker refuses.** An owned comment that opens a `pr-review:v`
  marker this gate cannot parse stops the run rather than being skipped over in
  favour of an older one it can.
- **`mergeable` exactly `MERGEABLE`.** `CONFLICTING` is a real merge conflict and
  `UNKNOWN` means GitHub has not finished computing mergeability; neither is a
  clearance, and merging on either is how an unresolved conflict lands.
- **Every check successful.** Any check whose bucket is not `pass` or `skipping`
  refuses, and so does an empty or unreadable check set — "no checks reported"
  is what a conflicted pull request looks like, not what a green one does. This
  is deliberately wider than the drainer's single configured
  `required_ci_check`: a manual fallback merging outside the daemon's audit
  should be more careful than it, not less.

**A refusal is total.** Stop immediately and do nothing else: merge nothing,
close nothing, remove no worktree, delete no branch. Report the two lines the
gate printed. Do not remove `reviewed:changes`, do not add `reviewed:approve`,
and do not push anything to the branch to "refresh" it — a push that touches a
file the pull request owns strips the approval and puts you back on this path
with the review to run again.

## 3. Merge

Re-run the gate fence above immediately before merging, with nothing between the
two. Labels, the head, and the check set are all mutable, and the value this
step pins is the one the *second* run validated. Then:

```bash
gh pr merge "$PR" -R "$REPO" --admin --merge --match-head-commit "${HEAD:?the finalize gate refused; nothing is merged, closed, removed, or deleted}"
```

That is the same call `tools/drain_prs.py` makes, flag for flag, and each flag
is load-bearing:

- `--merge` creates a merge commit, so every commit of the pull request reaches
  the default branch alongside it. Never `--squash` and never `--rebase`: both
  discard that history, and the drainer's own merges would then disagree with
  this one about what the repository's history looks like.
- `--match-head-commit "$HEAD"` names the reviewed commit as an object. A branch
  that moved between the gate and this call aborts the merge instead of landing
  a head nobody reviewed.
- `--admin` merges as a repository administrator, using whatever bypass the
  repository's branch ruleset grants that role. It is not there to bypass a
  review: the gate above is the review, and it has already run twice.

If the gate refused, `$HEAD` is empty and the parameter expansion above stops
the shell before `gh` is reached. That is the intent — never substitute a head
read from somewhere else, and never drop `--match-head-commit` to get past it.

**Do not arm auto-merge.** Arming a merge on a head whose checks have not passed
is a mutation, and step 2 forbids every mutation until they have. A pull request
whose checks are still running is refused and re-finalized later, when they are
green and the gate can say so.

## 4. Confirm the merge before anything else moves

Nothing is cleaned up on the strength of the merge command's exit status. Read
the pull request back and require GitHub to report it merged:

```bash
MERGED="$(gh pr view "$PR" -R "$REPO" --json state,mergedAt --jq 'select(.state == "MERGED") | .mergedAt')"
: "${MERGED:?the merge is not confirmed; close nothing, remove nothing, delete nothing}"
```

A pull request left open, or closed without being merged, is not a merge. Report
that and stop with the worktree and the branch intact.

## 5. Clean up, from the primary checkout

Only after step 4 confirmed the merge. Resolve what to remove first, from the
pull request itself rather than from the session's own directory:

```bash
BRANCH="$(gh pr view "$PR" -R "$REPO" --json headRefName --jq .headRefName)"
BASE="$(gh pr view "$PR" -R "$REPO" --json baseRefName --jq .baseRefName)"
ISSUE="$(gh pr view "$PR" -R "$REPO" --json closingIssuesReferences --jq '.closingIssuesReferences[0].number // empty')"
WORKTREE="$(git -C "$ROOT" worktree list --porcelain | sed -n "/issue-$ISSUE-/s#^worktree ##p")"
```

`git worktree list` is the only source for the worktree path, so a legacy path
and a repository-scoped one are both found where they actually are. It is
scoped to this repository's own registrations: issue numbers are repository-local,
and another repository's worktrees are not this workflow's to touch. If it names
none, there is nothing to remove — skip the removal line below and say so.

```bash
git -C "$ROOT" worktree remove "$WORKTREE"
git -C "$ROOT" fetch origin
git -C "$ROOT" merge --ff-only "origin/$BASE"
git -C "$ROOT" branch -d "$BRANCH"
git -C "$ROOT" push origin --delete "$BRANCH"
```

That order is the order it is for two reasons. The worktree goes first because a
branch checked out in one cannot be deleted. The local base branch advances
before the branch is deleted so the deletion can be `-d` rather than `-D`: once
the merge is in `$ROOT`'s own base branch, an ordinary delete succeeds, and one
that still refuses is telling you the branch holds a commit the merge did not —
which is a fact to report rather than force past.

Every one of those is scoped to `$ROOT` and to this pull request's own branch.
Leave every other worktree and every other branch untouched. If the removal
refuses over leftover build artifacts, confirm that nothing uncommitted matters
and retry it with `--force` — never `rm -rf`, which would leave the worktree
registered and the repository's metadata wrong. The fast-forward is `--ff-only`
and never a force: a default branch that will not fast-forward is a fact to
report, not one to overwrite. It also assumes `$ROOT` is on that base branch,
which is the primary checkout's ordinary state; if it is not, say so and leave
the fast-forward undone rather than switching a checkout somebody is using.

The linked issue closes itself through the pull request's `Closes #<n>`
reference. Read it back, and run this only when it is somehow still open. A
pull request that closes no issue leaves `$ISSUE` empty and has nothing to
close here:

```bash
gh issue close "$ISSUE" -R "$REPO"
```

## 6. Report

End with one line naming the outcome: the resolved repository, the pull request
merged and at which head, the issue closed, the worktree removed, the branch
deleted, and the default branch fast-forwarded — or, on a refusal, which
condition failed and what the pull request needs before it can be finalized.
