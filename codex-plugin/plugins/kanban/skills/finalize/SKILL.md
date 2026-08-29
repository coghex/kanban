---
name: finalize
description: Legacy manual fallback for merging a reviewed pull request when the PR drainer cannot be used. Refuses any pull request whose current head does not carry a fresh opposite-brand approval, a passing check set, and a clean merge state. Runs only when the user invokes $finalize for one specific pull request, or when drainer recovery has established that manual finalization is the appropriate fallback — never on an agent's own initiative.
---

# Finalize a reviewed pull request

This is the fallback, not the merge path. The service-managed PR drainer
controlled by $drain-prs is what merges eligible approved pull requests
out of the Done column, and it does so with a retry scheduler, an incident
record, and a post-merge audit this command has none of. Reach for
$finalize only when the drainer cannot be used — it is not installed on
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

```bash
PR="<the pull request number the user named>"
```

Codex substitutes no argument placeholder, so take the number from the prompt.

If no number was supplied, infer it from the current worktree's branch and
confirm it with the user before proceeding. Never guess it from the Done column.

## 2. The gate (FAIL CLOSED)

Run this exactly as written. It refuses on stderr and leaves `$HEAD` empty
unless every condition below holds, and every later step is guarded on `$HEAD`.

```bash
VIEWER="$(gh api user --jq .login)"
PR_STATE="$(gh pr view "$PR" -R "$REPO" --json number,url,body,headRefOid,headRefName,baseRefName,labels,reviewDecision,mergeable,mergeStateStatus,closingIssuesReferences)"
PR_COMMENTS="$(gh api --paginate --slurp "repos/$REPO/issues/$PR/comments?per_page=100")"
PR_CHECKS="$(gh pr checks "$PR" -R "$REPO" --json name,state,bucket)"
HEAD="$(python3 - "$REPO" "$VIEWER" "$PR_STATE" "$PR_COMMENTS" "$PR_CHECKS" <<'PY'
import json
import os
import re
import sys
import tomllib
from pathlib import Path

V1_RE = re.compile(
    r"<!--\s*pr-review:v1\s+reviewer=(?P<reviewers>claude|codex)\s+"
    r"head=(?P<head>[0-9a-f]{40})\s+"
    r"verdict=(?P<verdict>APPROVE|CHANGES_REQUESTED)\s*-->",
    re.IGNORECASE,
)
# The coordinator joins both lists with commas, so a dual-reviewer marker is
# the ordinary shape rather than an exception, and `models=` is one token.
V2_RE = re.compile(
    r"<!--\s*pr-review:v2\s+"
    r"reviewers=(?P<reviewers>(?:claude|codex)(?:,(?:claude|codex))*)\s+"
    r"models=\S+\s+"
    r"head=(?P<head>[0-9a-f]{40})\s+"
    r"verdict=(?P<verdict>APPROVE|CHANGES_REQUESTED)\s*-->",
    re.IGNORECASE,
)
# Case-insensitive like the two parsers above, and for the same reason they
# are: a marker this gate cannot parse must be detected in every spelling it
# could be written in. A case-sensitive opening test would skip a malformed
# `<!-- PR-REVIEW:V2 ... -->` and let an older APPROVE win, which is the
# fail-open the malformed-marker rule exists to close.
MARKER_OPENING_RE = re.compile(r"<!--\s*pr-review:v", re.IGNORECASE)
# The two origin markers, character for character as `originFromBody` spells
# them in src/Kanban/PullRequestFlow.hs. A different spacing is not one of
# these markers there and is not one here.
ORIGIN_MARKERS = {
    "claude": "<!-- pr-origin:claude -->",
    "codex": "<!-- pr-origin:codex -->",
}

repo = sys.argv[1].strip()
viewer = sys.argv[2].strip()
try:
    state = json.loads(sys.argv[3])
    pages = json.loads(sys.argv[4])
except ValueError:
    state = None
    pages = None
checks_text = sys.argv[5].strip()
number = state.get("number") if isinstance(state, dict) else None
subject = "PR #" + str(number) if number is not None else "the named pull request"


def refuse(detail, approval):
    if approval:
        headline = (
            "Refusing to finalize — " + subject + " lacks a current "
            "opposite-brand approval. Run $pr-review or "
            "$pr-rereview first."
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

# Which labels decide this is configuration, never a fixed string: the global
# [workflow] table, overridden by [repositories."owner/name".workflow]. Exactly
# the resolution the bundled coordinator, the drainer and the board all make,
# so a repository that renamed its verdict labels is read the same way here as
# everywhere else. An unreadable or absent file keeps the documented defaults.
approval_label = "reviewed:approve"
changes_label = "reviewed:changes"
blocked_labels = {"blocked"}
approval_mode = "label"
xdg = os.environ.get("XDG_CONFIG_HOME")
config_path = (Path(xdg) if xdg else Path.home() / ".config") / "kanban" / "config.toml"
document = {}
if config_path.is_file():
    try:
        with config_path.open("rb") as handle:
            document = tomllib.load(handle)
    except (tomllib.TOMLDecodeError, OSError):
        document = {}


def apply_workflow(table):
    global approval_label, changes_label, blocked_labels, approval_mode
    if not isinstance(table, dict):
        return
    workflow = table.get("workflow")
    if not isinstance(workflow, dict):
        return
    if isinstance(workflow.get("approval_label"), str) and workflow["approval_label"]:
        approval_label = workflow["approval_label"]
    named = workflow.get("changes_requested_label")
    if isinstance(named, str) and named:
        changes_label = named
    blocking = workflow.get("blocked_labels")
    if isinstance(blocking, list) and all(isinstance(one, str) for one in blocking):
        blocked_labels = set(blocking)
    mode = workflow.get("approval_mode")
    if mode in ("label", "review", "either"):
        approval_mode = mode


apply_workflow(document)
repositories = document.get("repositories")
if isinstance(repositories, dict):
    # The override key is the canonical ASCII-lowercased owner/name, folded the
    # one way Kanban.Config folds it rather than with Unicode lowering.
    ascii_lower = str.maketrans(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz"
    )
    apply_workflow(repositories.get(repo.translate(ascii_lower)))

# hasLabel folds case on both sides, so the comparison here does too.
labels = {
    str(item.get("name") or "").casefold()
    for item in state.get("labels") or []
    if isinstance(item, dict)
}
by_label = approval_label.casefold() in labels
by_review = str(state.get("reviewDecision") or "").upper() == "APPROVED"
approved = {
    "label": by_label,
    "review": by_review,
    "either": by_label or by_review,
}[approval_mode]
if not approved:
    refuse(
        "this repository approves by " + approval_mode + " and the pull request "
        "is not approved that way",
        True,
    )
if changes_label.casefold() in labels:
    refuse(changes_label + " is attached", True)
# hasProblemLabel treats a blocking label exactly as it treats the
# changes-requested one, and a blocking label is a decision a human made.
blocking = sorted(one for one in blocked_labels if one.casefold() in labels)
if blocking:
    refuse("a blocking label is attached: " + ", ".join(blocking), True)

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

# Whose brand reviewed has to be read off the pull request, not assumed: an
# approval published by the same brand that wrote the code is a self-review,
# and the marker alone cannot tell you that. These are exactly the rules
# originFromBody applies in src/Kanban/PullRequestFlow.hs -- one marker, of one
# kind, as the final non-whitespace content of the body.
body_text = str(state.get("body") or "")
stripped = body_text.rstrip()
counts = {brand: body_text.count(marker) for brand, marker in ORIGIN_MARKERS.items()}
present = [brand for brand, count in counts.items() if count]
# Spelled without a greater-than comparison on purpose: one surrounded by
# spaces in a fenced block reads as a shell redirect into the working tree to
# the packaged-asset hygiene scan, which does not know this block is Python.
# There are exactly two brands, so "both present" is "two present", and "more
# than once" is "not zero or one".
if len(present) == 2:
    refuse("the pull request body carries both pr-origin markers", True)
if any(count not in (0, 1) for count in counts.values()):
    refuse("the pull request body carries a duplicate pr-origin marker", True)
origin = present[0] if present else None
if origin is not None and not stripped.endswith(ORIGIN_MARKERS[origin]):
    refuse("the pr-origin marker is not the body's final content", True)

reviewers = {
    part.strip().lower()
    for part in chosen.group("reviewers").split(",")
    if part.strip()
}
if origin is None:
    # No declared origin is the dual route the coordinator takes: with no
    # brand to be opposite of, only a review carrying BOTH brands is known to
    # be independent of whoever wrote the code.
    if reviewers != set(ORIGIN_MARKERS):
        refuse(
            "this pull request declares no origin, so only a dual-brand review "
            "is known to be independent; the newest marker names "
            + ",".join(sorted(reviewers)),
            True,
        )
elif origin in reviewers:
    refuse(
        "the newest marker names this pull request's own brand ("
        + origin
        + ") as a reviewer, which is a self-review",
        True,
    )

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

# mergeable answers "would this merge cleanly", never "should it merge now".
# parseMergeState in src/Kanban/GitHub/Decode.hs and mergeStateReady in
# src/Kanban/Workflow.hs are mirrored exactly: CLEAN is ready, and so is a
# BLOCKED state on a MERGEABLE pull request, which is the branch-protection
# requirement the MergeProtected state models and the one --admin is for.
# BEHIND, UNSTABLE, a BLOCKED state that is not MERGEABLE, and every other
# value are not ready. The mergeable test is repeated inside the condition
# rather than assumed from the refusal above, so the mirror stays readable
# against Decode.hs and survives a reordering here.
merge_state = str(state.get("mergeStateStatus") or "").upper()
ready = merge_state == "CLEAN" or (
    merge_state == "BLOCKED" and mergeable == "MERGEABLE"
)
if not ready:
    refuse(
        "GitHub reports mergeStateStatus=" + (merge_state or "unset"), False
    )

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
- **A reviewer set that does not exclude the pull request's own brand.** The
  approval this workflow acts on is an *opposite-brand* approval, and the marker
  alone cannot say whether it is one: it names who reviewed, not who wrote. So
  the origin is read off the pull request body by exactly the rules
  `originFromBody` applies in `src/Kanban/PullRequestFlow.hs` — one marker, of
  one kind, as the body's final non-whitespace content — and a marker whose
  `reviewers=` names that same brand is refused as a self-review. Both markers
  present, the same marker twice, and a marker with trailing text after it are
  each refusals rather than defaults. A body with **no** marker is the
  coordinator's unknown-origin route, which reviews with both brands; there
  being no declared brand to be opposite of, only a marker naming both is known
  to be independent of whoever wrote the code, and a single-brand marker on such
  a pull request refuses.
- **The repository's own verdict labels, under its own approval mode.** The
  approval label, the changes-requested label, the blocking labels and the
  approval mode are configuration — the global `[workflow]` table, overridden by
  `[repositories."<owner>/<name>".workflow]` — so the gate resolves them the way
  the bundled coordinator, the drainer and the board all do, and compares them
  with case folded on both sides as `hasLabel` does. A repository that renamed
  `reviewed:approve` would otherwise have every one of its approvals refused,
  and one configured for `review` approval would look unapproved with a
  perfectly good approval on it. A blocking label refuses for the same reason
  the changes-requested label does: `hasProblemLabel` treats the two alike, and
  a blocking label is a decision a human made.
- **`mergeable` exactly `MERGEABLE`.** `CONFLICTING` is a real merge conflict and
  `UNKNOWN` means GitHub has not finished computing mergeability; neither is a
  clearance, and merging on either is how an unresolved conflict lands.
- **A merge state that is actually ready.** `mergeable` answers whether the
  merge *would* be clean, never whether it *should* happen now: a pull request
  is routinely `MERGEABLE` while its `mergeStateStatus` is `BEHIND` — its head
  has not seen the base tip the reviewed code will land on — or `UNSTABLE`,
  where a check is failing. Merging either with `--admin` would push straight
  past the branch update and the fresh review the drainer would have required.
  So `parseMergeState` and `mergeStateReady` are mirrored exactly: `CLEAN` is
  ready, and a `BLOCKED` state on a `MERGEABLE` pull request is ready too —
  that is the branch-protection requirement the `MergeProtected` state models,
  and clearing it is precisely what `--admin` is for. Everything else refuses,
  `BEHIND` and `UNSTABLE` included. A `BEHIND` pull request is not finalized
  here: it is updated and rereviewed first, which is
  $fix's branch to take, not this one.
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
BASE="$(gh pr view "$PR" -R "$REPO" --json baseRefName --jq .baseRefName)"
BRANCH="$(gh pr view "$PR" -R "$REPO" --json isCrossRepository,headRefName --jq 'select(.isCrossRepository == false) | .headRefName')"
ISSUE="$(gh pr view "$PR" -R "$REPO" --json closingIssuesReferences --jq '.closingIssuesReferences[0].number // empty')"
WORKTREE="$(git -C "$ROOT" worktree list --porcelain | awk -v ref="refs/heads/$BRANCH" -v sha="$HEAD" '/^worktree /{path=substr($0,10); head=""} /^HEAD /{head=$2} /^branch /{if ($2==ref && head==sha) {print path; exit}}')"
BASE_CHECKOUT="$(git -C "$ROOT" symbolic-ref --quiet --short HEAD | grep -Fx "$BASE")"
OPEN_ISSUE="$(gh issue view "${ISSUE:-0}" -R "$REPO" --json number,state --jq 'select(.state == "OPEN") | .number')"
LOCAL_BRANCH="$(git -C "$ROOT" rev-parse --verify --quiet "refs/heads/$BRANCH")"
```

Two of those resolve to nothing on purpose, and the guards below turn each empty
value into a refusal rather than a wrong deletion:

- `$BRANCH` is the head branch **only when the head lives in this repository**.
  A cross-repository pull request's `headRefName` names a branch in the fork, not
  here, so deleting it on `origin` would delete whatever unrelated branch happens
  to share the name in the base repository. The `select` leaves `$BRANCH` empty
  for such a pull request, and the deletion refuses.
- `$BASE_CHECKOUT` is the base branch **only when `$ROOT` is actually on it**.
  Fast-forwarding is a local branch update, and `--ff-only` applies it to
  whatever branch the checkout has out — which for a pull request targeting a
  non-default base would advance the default branch to somewhere it should not
  go. A detached HEAD leaves it empty too.

`git worktree list` is the only source for the worktree path, so a legacy path
and a repository-scoped one are both found where they actually are — and it is
scoped to this repository's own registrations, since another repository's
worktrees are not this workflow's to touch.

**The worktree is identified, not pattern-matched.** A path is no more an
identity than a branch name is: an `issue-<n>-` substring matches a stale
worktree for a different pull request that happens to share the number style,
matches whatever a run with no linked issue leaves the pattern reduced to, and
says nothing about what the worktree actually has checked out. The `awk` above
reads the porcelain record properly and takes the path of the worktree whose
`branch` is exactly this pull request's `refs/heads/$BRANCH` **and** whose
`HEAD` is exactly the reviewed `$HEAD`. Git allows a branch to be checked out in
at most one worktree, so that names at most one path. Anything else — no match,
a worktree that has moved on to commits this run did not merge, a
cross-repository pull request with no local branch at all — leaves `$WORKTREE`
empty, and an empty `$WORKTREE` removes nothing. The linked issue number is not
part of this at all any more; it is only what the issue close below reads.

`$WORKTREE` and `$OPEN_ISSUE` are two more values that resolve to nothing rather
than to something wrong, but unlike the two above they are **skips, not
refusals**: a pull request that closes no issue, one whose issue already closed
itself through the `Closes #<n>` reference, and one whose worktree was removed
earlier are all ordinary, and none of them is a reason to leave a merged pull
request half cleaned up. `$LOCAL_BRANCH` is a third of the same kind. Each is
guarded by its own `[ -z ... ] ||` so the
command is not run at all rather than run against an empty argument — which
`git` and `gh` would each turn into an error this workflow would then step
straight past, having no `set -e` to stop it. That spelling rather than
`[ -n ... ] &&` because a skip is not a failure: the `&&` form would leave the
last step of a clean run reporting a non-zero status for having correctly done
nothing.

```bash
{ [ -z "$WORKTREE" ] || git -C "$ROOT" worktree remove "$WORKTREE"; } &&
git -C "$ROOT" fetch origin &&
: "${BASE_CHECKOUT:?the primary checkout is not on the base branch of this pull request; leave its branches alone}" &&
git -C "$ROOT" merge --ff-only "origin/$BASE" &&
: "${BRANCH:?the head of this pull request lives in another repository; delete no branch here}" &&
{ [ -z "$LOCAL_BRANCH" ] || git -C "$ROOT" update-ref -d "refs/heads/$BRANCH" "$HEAD"; } &&
git -C "$ROOT" push origin --force-with-lease="refs/heads/$BRANCH:$HEAD" --delete "$BRANCH"
```

**That is one `&&` chain, and it is one on purpose.** This workflow sets no
`set -e`, so written as separate commands a failed worktree removal, fetch, or
fast-forward would be stepped straight past into the two deletions — leaving a
still-checked-out or dirty worktree behind while its branch is deleted out from
under it. Chained, the first failure ends the cleanup and every later step is
simply not run. Keep any step you add inside the chain.

The order within it is the order it is for two reasons. The worktree goes first
because a branch checked out in one cannot be deleted. The local base branch
advances before either deletion so the merged commits are reachable from
`$ROOT`'s own base branch before the branch that carried them goes away.

**Both deletions are bound to the reviewed head, not to the branch name.**
A name is not an identity: between the merge and this cleanup another actor can
delete `$BRANCH` and push a new, unrelated branch under the same name, and a
deletion by name alone would then delete *that*. So the local ref is removed
with `git update-ref -d <ref> <old-value>`, which deletes only a ref that still
equals `$HEAD`, and the remote one with
`--force-with-lease="refs/heads/$BRANCH:$HEAD"`, which sends that same head as
the expected old value so the server performs a compare-and-swap and rejects the
delete with `stale info` if the branch has moved. `$HEAD` is the head the gate
validated and the merge landed, so both deletions can only ever remove the thing
this run actually merged. `$LOCAL_BRANCH` is empty when `$ROOT` never had a copy
of the branch — finalizing a pull request whose worktree was somebody else's —
and that is a skip rather than a failure.

Neither refusal message contains an apostrophe, and that is not style. A `'`
inside a `${VAR:?...}` word is read as an opening quote, and the shell then
swallows every line up to the next one — the `git merge` between these two
guards, when both messages carried one. Keep them apostrophe-free.

Either guard stops the run where it stands, with the steps above it done and the
steps below it undone. That is the intended shape: the merge has already
landed and is not undone by stopping here, and every step this leaves out is one
that would otherwise have written to the wrong branch. Report exactly what was
left undone.

Every one of those is scoped to `$ROOT` and to this pull request's own branch.
Leave every other worktree and every other branch untouched. If the removal
refuses over leftover build artifacts, confirm that nothing uncommitted matters
and retry it with `--force` — never `rm -rf`, which would leave the worktree
registered and the repository's metadata wrong — and a removal that still
refuses ends the chain, so nothing is deleted while it is unresolved. The
fast-forward is `--ff-only` and never a force: a default branch that will not
fast-forward is a fact to report, not one to overwrite.

The linked issue closes itself through the pull request's `Closes #<n>`
reference, so `$OPEN_ISSUE` above is empty in the ordinary case and this runs
only when the closure did not happen. Run it after the cleanup chain above has
reported success; a cleanup that ended early is a state to report, not one to
carry on from. It is empty for a pull request that closes
no issue too — the `${ISSUE:-0}` substitution keeps that read a well-formed
request for an issue number that will not resolve, rather than a `gh` invocation
with a missing argument:

```bash
[ -z "$OPEN_ISSUE" ] || gh issue close "$OPEN_ISSUE" -R "$REPO"
```

## 6. Report

End with one line naming the outcome: the resolved repository, the pull request
merged and at which head, the issue closed, the worktree removed, the branch
deleted, and the default branch fast-forwarded — or, on a refusal, which
condition failed and what the pull request needs before it can be finalized.
