---
description: "Repair one GitHub pull request after its canonical review returns CHANGES_REQUESTED: read the current review, implement and validate the requested fixes in an isolated worktree, push safely, and invoke the canonical rereview. Use when the user invokes /pr-revise, asks to address a PR review that requested changes, or wants to turn a reviewed:changes PR into a new reviewable revision."
argument-hint: "[PR number]"
---

# Revise Pull Request

Repair one positive PR number in `$ARGUMENTS`. Treat the canonical review as the contract; do not manually change `reviewed:approve` or `reviewed:changes`, post substitute review comments, force-push, or merge the PR.

The canonical rereview route is fixed by brand: a Claude-origin PR uses the Codex reviewer; a Codex-origin PR uses the Claude reviewer; unknown or external origin uses both independently. Neither a specific model nor reasoning effort is pinned or verified; only the brand is selected, deferring to that installation's own configured default. This session runs on the PR's own origin brand (Kanban only ever resumes the original solver to revise); the rereview below therefore always hands off to the opposite brand's canonical reviewer identity, never to this session's own model.

## 1. Establish the review contract

Read the PR title, body, head SHA, labels, merge state, checks, linked issues, and all comments. Identify the newest authenticated-user `pr-review:v2` (or legacy `pr-review:v1`) marker and its verdict.

- If the PR is already merged or closed, report that and stop.
- If the current canonical verdict is `APPROVE`, report it and stop unless the user explicitly asks to change the code.
- If no canonical `CHANGES_REQUESTED` review exists, stop and direct the user to `/pr-review <pr>`.
- If the PR head changed after the changes-requested marker, explain that the feedback may be stale. Rerun `/pr-rereview <pr>` before editing when the newer head could have addressed or invalidated the concerns.
- Check that every linked issue is still approved. Do not work around a blocked issue gate.

Capture every blocker with its file/line, required behavior, and any prior-blocker verification request. Inspect the actual code and tests before choosing a fix. Ask the user about a material product or scope decision; otherwise make the smallest complete fix.

## 2. Use an isolated, current worktree

Never switch the repository's main checkout or reuse an unrelated dirty worktree.

1. Fetch the PR head and record its exact remote SHA and branch name.
2. Reuse a worktree only when it is on that exact PR branch and `git status --porcelain` is empty.
3. Otherwise create a temporary dedicated worktree on a new local revision branch based on the recorded remote head. Keep its path and branch distinct from `issue-<n>-*` worktrees.
4. Before editing, verify `HEAD` still equals the recorded PR SHA.

If the remote head moves at any point before push, stop: re-read the current PR and reconcile the new revision rather than overwriting it.

## 3. Implement and validate

Address every canonical blocker, including the previous review's requested regression coverage. Preserve the issue/PR scope; do not fold in unrelated cleanup.

Run the narrowest relevant tests while iterating, then the repository's required validation commands or their closest local equivalents. Review the complete diff, run `git diff --check`, and ensure the change does not leave generated files, credentials, or unrelated edits.

Commit the focused fix with a clear message. Before push, fetch the PR branch and verify its remote SHA still matches the recorded head. Push the new commit to that exact PR branch without force. If the verification fails, stop and report the competing update.

## 4. Wait for CI and rerun canonical review

Wait for the PR's required checks for the pushed head to complete successfully. If CI fails, diagnose and fix only when the failure is attributable to this revision; otherwise report the external failure and stop.

Then invoke the coordinator exactly once. This plugin bundles its own copy of the coordinator at `${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py`, so it never depends on the Codex plugin being installed. Do not pass `--self-review` here: unlike `/pr-review`/`/pr-rereview`, this session cannot review as the opposite brand itself, so the coordinator must spawn that nested reviewer.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py" \
  --path "$(git rev-parse --show-toplevel)" \
  --rereview <pr> \
  --json
```

Do not independently review, comment, label, retry a failed model, or compensate for the coordinator's result. A `CHANGES_REQUESTED` verdict starts a new revision cycle only after inspecting its new feedback; an approved verdict leaves merging to the repository's normal merge/drainer process.

## 5. Report and clean up

Return the PR number, starting head and pushed head, fixed review items, validation and CI results, canonical rereview route/verdict, review-comment URL, and final labels. Remove only the temporary worktree created for this run after confirming it is clean; never remove a user-owned or `issue-<n>-*` worktree.
