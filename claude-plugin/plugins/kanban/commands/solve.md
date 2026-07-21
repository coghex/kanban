---
description: Claim a GitHub issue, implement its minimal verified fix in an isolated worktree, and open a PR. Use only when the user invokes /solve or explicitly asks to take an issue through PR creation.
argument-hint: "[issue number]"
---

# Solve Issue

Take one issue through a tested pull request. Stop after opening the PR; review and merge are separate workflows.

## Select And Claim

1. If an issue number was supplied in `$ARGUMENTS`, take that one. Otherwise select the oldest open, unassigned implementation issue carrying the approval label:

   ```bash
   gh issue list --state open --search "sort:created-asc no:assignee label:reviewed:approve -label:epic -label:needs-decision -label:wip -label:blocked -label:reviewed:changes"
   ```

2. Before claiming, require the canonical cross-agent gate. Kanban can solve issues in any repository it is pointed at, so this backend is not necessarily tracked inside the repository under review; resolve the Kanban-managed install location the same way `Kanban.Review.canonicalIssueReviewerPath` does (`KANBAN_ISSUE_REVIEW_INSTALL_DIR` when set, otherwise `~/Library/Application Support/kanban/issue-review/approve_issues.py`) rather than a path relative to the repository being solved or any other personal path:

   ```bash
   BACKEND="${KANBAN_ISSUE_REVIEW_INSTALL_DIR:-$HOME/Library/Application Support/kanban/issue-review}/approve_issues.py"
   python3 "$BACKEND" --path "$(git rev-parse --show-toplevel)" --check <issue> --legacy-policy dual --json
   ```

   If `$BACKEND` does not exist, stop and report: "Canonical issue reviewer was not found at $BACKEND. Run `python3 tools/install_issue_review.py` from the Kanban checkout to install it."

   Continue only on exit 0 with `"approved": true`. A green label alone is insufficient: this check also binds the current title/body/labels/comments to a versioned opposite-agent review marker and rejects stale or manually applied approval. On any other result, do not claim and stop with exactly one line: `KANBAN_NEEDS_INPUT: This issue needs canonical review; press r on the issue, then retry.` Do not run `--review` or `--rereview` against this backend from a solve session; that publishing action belongs to Kanban's own `r` workflow.
3. Claim it before doing any work:

   ```bash
   gh issue edit <issue> --add-assignee @me
   ```

4. Immediately check both collision signals. From this repository's primary checkout, use `git worktree list` to find any `issue-<issue>-` worktree registered to THIS repository, and `gh pr list --state open --search "<issue> in:body"` to ensure no open PR is already closing it. Never scan a shared parent directory or another repository's worktrees: issue numbers are repository-local.
5. An open PR is a real collision: release the claim with `gh issue edit <issue> --remove-assignee @me`. Choose another issue only when the user did not name one; otherwise stop and report the PR.
6. An existing same-issue worktree is interrupted work, not a collision. Do not release the claim or create another worktree. Enter the existing worktree; identify its upstream/default base; inspect `git status`, committed progress relative to that base, `git diff --cached`, and `git diff`. Preserve and validate useful work, then continue the solve there. Never discard, reset, or overwrite unfinished changes merely to start clean.

## Work In Isolation

1. Resolve the repository root and default branch. Fetch `origin`. Resolve the canonical GitHub repository identity with `gh repo view --json nameWithOwner --jq .nameWithOwner`; do not derive identity from the local checkout directory name.
2. Keep newly created worktrees outside the source-checkout directory. Set `WORKTREES_ROOT=${WORKTREES_ROOT:-"$HOME/worktrees"}` and use the repository-scoped directory `$WORKTREES_ROOT/<owner>/<repo>/issue-<issue>-<slug>`. Create its parent if needed. If no same-issue recovery worktree was found above, create that worktree from the latest `origin/<default-branch>`; otherwise continue in the recovered worktree. `git worktree list` remains the sole collision/recovery source and therefore continues to recognize legacy worktrees at their existing paths. Never move, rename, or bulk-clean legacy worktrees as part of solving. Use absolute paths for every later command because tool working directories are not persistent.
3. Read the issue body and the COMPLETE comment timeline before editing. Use the paginated REST comments endpoint when necessary so every comment and its `author_association` is included. Build an explicit effective-spec checklist:
   - The body is the initial contract.
   - Later comments by the issue author or an `OWNER`, `MEMBER`, or `COLLABORATOR` are authoritative amendments. This includes structured `<!-- issue-review:v1 ... -->` and `<!-- issue-review:v2 ... -->` comments: their **Corrections** and **Spec additions / clarifications** amend the contract, **Supporting context** is non-normative, **Open decisions** remain unresolved, and a **Recommended disposition** is a signal to re-verify viability before proceeding.
   - Read and account for every other comment as evidence, risk, or discussion, but do not treat it as a new requirement unless an authoritative participant confirms it.
   - Later authoritative guidance supersedes earlier text when it explicitly conflicts. If comments leave a conflict, open decision, obsolete premise, unclear scope, or a supported recommendation not to implement the issue, release the claim and stop with the evidence instead of guessing.
4. Read the affected code and verify that the effective spec is still real. Implement the smallest solution satisfying its requirements, acceptance criteria, and out-of-scope boundaries. Do not bundle unrelated cleanup.
5. Add or extend a focused test when feasible. Read the repository's agent instructions, CI configuration, and test tooling, then select checks from the changed paths and the issue's acceptance criteria: run targeted unit/describe tests and only the relevant probes, audits, or worldgen checks. Do not run a whole suite, a full CI mirror, or unrelated probes merely because they exist. Run a full local gate only when the user explicitly requests it; remote CI remains the full-suite authority. If a selected check fails, fix it or prove it also fails on the base branch before treating it as unrelated.

## Ship

1. Review `git status` and the diff in the worktree. Do not include unrelated user changes.
2. Commit the implementation, splitting only genuinely separate concerns into separate commits.
3. Push the branch with `-u` and open a PR. Its body must include `Closes #<issue>`, a short approach summary, the exact checks run, and `<!-- pr-origin:claude -->` as the final line for opposite-brand review routing. If authoritative comments amended or clarified the body, include a concise spec note identifying what comment-derived requirements were implemented.
4. If the work is abandoned before opening the PR, release the issue claim.

## Stop Condition

Do not review, label, merge, or finalize the PR. End with exactly:

```text
PR #<number> - <one-sentence summary>
```
