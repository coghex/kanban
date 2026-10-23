---
description: "Repair one GitHub pull request after its canonical review returns CHANGES_REQUESTED: read the current review, implement and validate the requested fixes in an isolated worktree, push safely, and invoke the canonical rereview. Use when the user invokes /pr-revise, asks to address a PR review that requested changes, or wants to turn a reviewed:changes PR into a new reviewable revision."
argument-hint: "[PR number]"
---

# Revise Pull Request

Repair one positive PR number in `$ARGUMENTS`. Treat the canonical review as the contract; do not manually change `reviewed:approve` or `reviewed:changes`, post substitute review comments, force-push, or merge the PR.

Run this in a **Class A** session (see the `model-classes` skill).

The bundled coordinator decides which reviewer the rereview goes to, from the pull request's origin marker and the roster; this workflow states no routing rule and pins neither a model nor a reasoning effort. Step 1 below stops this session before it changes anything unless the pull request belongs to this session's own brand, so the rereview never reaches the brand that authored the revision.

## 1. Require the pull request's origin to be this brand

This workflow is user-invoked: the user chose which brand's session runs it, and nothing has checked that the choice matches the pull request, so it checks first, before any mutation — before a worktree, a push, or the rereview step 2 may run on a moved head.

Fetch the pull request body (`gh pr view <pr> --json body`), read its `pr-origin` marker, and apply exactly the
rules `origin_from_body` applies in the bundled coordinator's `review_pr.py`:
the body must carry exactly ONE marker, of exactly one kind, as its final
non-whitespace content. Both markers present, the same marker twice, a marker with trailing
text after it, and no marker at all are each a refusal — not a default.

This is the Claude bundle, so the marker must be `<!-- pr-origin:claude -->`.
A `pr-origin:codex` pull request belongs to the Codex bundle's own revise
skill, not to this one.

**A missing, malformed, or opposite-brand marker stops the run with nothing
changed.** The coordinator routes the rereview from that same marker, so
revising a pull request whose origin names the OTHER brand would have this
session author a change and then hand it to its own brand to review. An
unknown-origin or external-origin pull request (a `grok`, `kimi` or `google`
marker, or none) stops here too: it has no declared brand to match, and guessing
one would invent the fact this check exists to read. Report what the marker said
and which bundle owns the pull request.

## 2. Establish the review contract

Read the PR title, body, head SHA, labels, merge state, checks, linked issues, and all comments. Identify the newest authenticated-user `pr-review:v2` (or legacy `pr-review:v1`) marker and its verdict.

Record whether the PR has closing-issue references. A reviewed PR with none is a standalone PR whose own evidence is the review contract; preserve that mode through rereview.

- If the PR is already merged or closed, report that and stop.
- If the current canonical verdict is `APPROVE`, report it and stop unless the user explicitly asks to change the code.
- If no canonical `CHANGES_REQUESTED` review exists, stop and direct the user to `/pr-review <pr>`.
- If the PR head changed after the changes-requested marker, explain that the feedback may be stale. Rerun `/pr-rereview <pr>` before editing when the newer head could have addressed or invalidated the concerns.
- Check that every linked issue is still approved. Do not work around a blocked issue gate.

Capture every blocker with its file/line, required behavior, and any prior-blocker verification request. Inspect the actual code and tests before choosing a fix. Ask the user about a material product or scope decision; otherwise make the smallest complete fix.

## 3. Use an isolated, current worktree

Never switch the repository's main checkout or reuse an unrelated dirty worktree.

1. Fetch the PR head and record its exact remote SHA and branch name.
2. Reuse a worktree only when it is on that exact PR branch and `git status --porcelain` is empty.
3. Otherwise create a temporary dedicated worktree on a new local revision branch based on the recorded remote head. Keep its path and branch distinct from `issue-<n>-*` worktrees.
4. Before editing, verify `HEAD` still equals the recorded PR SHA.

If the remote head moves at any point before push, stop: re-read the current PR and reconcile the new revision rather than overwriting it.

## 4. Implement and validate

Address every canonical blocker, including the previous review's requested regression coverage. Preserve the issue/PR scope; do not fold in unrelated cleanup.

Run the narrowest relevant tests while iterating, then the repository's required validation commands or their closest local equivalents. Review the complete diff, run `git diff --check`, and ensure the change does not leave generated files, credentials, or unrelated edits.

Commit the focused fix with a clear message. A fix to documentation that goes with the change is landed with `docs-push` and linked from the PR body as `Docs: <path> @ <commit>`, placed before the origin marker, instead of being committed to the branch — unless `docs-push` refuses the path as code, or this checkout's own `origin` is not the pull request's base repository (a fork checkout): `docs-push` publishes to `origin`, so in either case the documentation is committed to the branch like the code. Unless the spec names its path, a verdict or evidence write-up goes under `docs/archive/`, because it records finished work and repositories hide that directory from search; design notes and contracts are updated where they live. That decides only where the file goes, not how it lands. Before push, fetch the PR branch and verify its remote SHA still matches the recorded head. Push the new commit to that exact PR branch without force. If the verification fails, stop and report the competing update.

## 5. Rerun canonical review

Do not wait for, poll, or diagnose the pull request's checks: the rereview follows the push immediately. Local validation in step 4 is the evidence this workflow owes before it pushes; what the checks later report is the drainer's and the next review round's to act on.

Then invoke the coordinator exactly once. This plugin bundles its own copy of the coordinator at `${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py`, so it never depends on the Codex plugin being installed. Do not pass `--self-review` here: unlike `/pr-review`/`/pr-rereview`, this session cannot review as the opposite brand itself, so the coordinator must spawn that nested reviewer.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py" \
  --path "$(git rev-parse --show-toplevel)" \
  --rereview <pr> \
  --allow-no-issue \
  --json
```

The standalone allowance does not bypass linked-issue review: if the PR has any closing-issue references, the coordinator still validates every linked issue before invoking a reviewer.

Do not independently review, comment, label, retry a failed model, or compensate for the coordinator's result. A `CHANGES_REQUESTED` verdict starts a new revision cycle only after inspecting its new feedback; an approved verdict leaves merging to the repository's normal merge/drainer process.

## 6. Report and clean up

Return the PR number, starting head and pushed head, fixed review items, local validation results, a statement that the pull request's checks were not awaited, canonical rereview route/verdict, review-comment URL, and final labels. Remove only the temporary worktree created for this run after confirming it is clean; never remove a user-owned or `issue-<n>-*` worktree.
