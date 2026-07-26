---
description: "Repair one GitHub pull request that is blocked from merging: diagnose the highest-priority blocking cause — merge conflict, failed check, or blocking label — fix it in the pull request's own worktree, push safely, and hand off to exactly one canonical rereview. Use when the user invokes /repair or asks to make a blocked pull request mergeable."
argument-hint: "[PR number]"
---

# Repair Pull Request

Make one blocked pull request mergeable again, taking its number from `$ARGUMENTS`. Repair works on the pull request's own code, so this session runs on the pull request's own origin brand, the same way `/pr-revise` does.

Never merge the pull request, and never close an issue or pull request. Merging belongs to the repository's own merge or drainer process, never to this workflow.

Never add or remove a verdict label directly. The configured approval and changes-requested labels (default `reviewed:approve` / `reviewed:changes`) change only as a consequence of the canonical rereview this workflow hands off to, which necessarily switches them. That handoff is the only path by which they may change.

Whenever two reasonable resolutions would differ in behaviour, scope, or user-visible outcome, ask the user through the session's question mechanism rather than choosing.

## 1. Inputs

Require one positive pull request number. Accept the repository and configuration context the caller supplies alongside it, and resolve the repository identity from that context rather than from the local checkout directory name. When the caller supplies none, resolve it from the checkout's own configured remote.

Use that resolved repository for every GitHub read and write in this workflow: pass it to `gh` as `-R <owner/name>` rather than letting `gh` infer the repository from the local checkout, and fetch and push the pull request's head branch against that same repository. A fork checkout whose remote points at the fork would otherwise diagnose, or fail on, a same-numbered pull request in the wrong repository.

Forward the resolved repository and configuration to the canonical coordinator through the coordinator's own `--repo` and `--config` options, so a fork checkout or a non-default config path repairs and rereviews the same repository the board displays. Omit an option the caller did not supply.

## 2. Diagnose the blocking cause

Read the pull request's merge state, its complete status-check rollup, its labels, its linked issues, and its comments before deciding anything:

```bash
gh pr view <pr> -R <owner/name> --json number,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository,maintainerCanModify,mergeStateStatus,mergeable,labels,statusCheckRollup,closingIssuesReferences,url
```

Address the highest-priority blocking cause you find, in the same order and with the same breadth as `pullRequestStatus` in `src/Kanban/Workflow.hs`, so every state that can make a Done card red has a defined branch:

1. **Merge conflict** — resolve it, preserving the pull request's intent while incorporating the current base branch.
2. **Failed check** — any failed check in the pull request's status-check rollup, required or not, not only required checks. Fix the cause. A failure you judge to be pre-existing on the base branch or flaky rather than caused by this pull request must be reported to the user and stop the run, never papered over: no retry loops, no deleted or skipped tests, no weakened assertions.
3. **Blocking label** — with no conflict and no failed check, whatever the check state, passing, pending, or unknown. Never remove a blocking label: a blocking label is a human's decision. Report what is blocking, ask the user, and act only on their answer.

If none of the three is present, report what you found and stop without pushing.

## 3. Work in the pull request's own worktree

Resolve the pull request's head repository, head branch, and exact head SHA before editing anything, and record all three. `headRepositoryOwner` and `headRepository` identify the head repository; `isCrossRepository` reports whether it differs from the resolved repository the diagnosis above used.

A cross-repository pull request is fail-closed. When the head repository differs from the resolved repository, `headRefName` is not a branch of the resolved repository, so never fetch or push that name there: doing so would miss the recorded head, or overwrite an unrelated branch that merely shares its name. Fetch the head commit from the head repository itself, or read-only from the resolved repository's `pull/<pr>/head` ref, and push only to the head repository's own `headRefName`. When that head repository is not writable — `maintainerCanModify` is false, or the push is rejected — stop and report that the pull request's head cannot be safely written, without pushing anything.

Select the worktree by that branch, not by an issue number: reuse any worktree registered to this repository that is already on the pull request's exact head branch, and confirm it tracks the recorded head repository's `headRefName` rather than merely a local branch of the same name. A `solve` worktree named `issue-<n>-<slug>` matches naturally, by branch rather than by name, so this is well defined whether the pull request links zero, one, or several issues.

```bash
git worktree list
```

A dirty or interrupted reused worktree is recoverable work, not a collision: inspect `git status`, `git diff`, `git diff --cached`, and committed progress relative to the recorded head, then preserve and continue there. Never discard, reset, or overwrite unfinished changes, and never create a second worktree on the same branch merely because the first is dirty.

Only when no worktree is on that branch, create one keyed on the pull request number under the repository-scoped worktrees root `${WORKTREES_ROOT:-$HOME/worktrees}/<owner>/<repo>/pr-<n>-<slug>`, outside the source checkout. Never switch the repository's primary checkout.

Make the smallest change that clears the diagnosed cause, then run the checks the changed paths and that cause actually select. Before pushing, re-fetch the pull request branch from the recorded head repository and verify its remote head still equals the recorded SHA. Push to that exact branch, in that head repository, without force. If the remote head moved, stop and report the competing update rather than overwriting it.

## 4. Hand off exactly one canonical rereview

When you pushed a new head, finish by invoking exactly one canonical rereview; that handoff is what re-establishes the verdict on the new head. Do not assume the pull request is still approved after you push.

When you pushed nothing — the blocking-label branch, or a diagnosis that found nothing to repair — there is no new head, so invoke no rereview and simply report what you found.

This plugin bundles its own copy of the coordinator at `${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py`, so it never depends on the Codex plugin being installed. Do not pass `--self-review`: this session runs on the pull request's own origin brand and cannot review as the opposite brand itself, so the coordinator must spawn that nested reviewer.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py" \
  --path "$(git rev-parse --show-toplevel)" \
  --rereview <pr> \
  --json
```

Add `--repo <owner/name>` and `--config <path>` to that same call whenever the caller supplied them.

When a push happened but the rereview is unavailable — the coordinator rejects a rereview on a pull request with no prior canonical review marker, and its issue gate blocks a pull request with no linked issue unless explicitly allowed — stop and report that exact reason. A card can reach Done through GitHub's native `reviewDecision == APPROVED` with no canonical review at all, so this is a reachable state. Never compensate by setting a label yourself.

## 5. Report

Return the pull request number, the diagnosed blocking cause, the recorded and pushed head SHAs, which worktree was used and whether it was reused or created, exactly what changed and what was run, the state of the pushed head's checks, and the canonical rereview route, verdict, and comment URL — or the exact reason no rereview ran.
