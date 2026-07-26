---
name: repair
description: "Repair one GitHub pull request that is blocked from merging: diagnose the highest-priority blocking cause — merge conflict, failed check, or blocking label — fix it in the pull request's own worktree, push safely, and hand off to exactly one canonical rereview. Use when the user invokes $repair or asks to make a blocked pull request mergeable."
---

# Repair Pull Request

Make one blocked pull request mergeable again. Repair works on the pull request's own code, so this session runs on the pull request's own origin brand, the same way `$pr-revise` does.

Never merge the pull request, and never close an issue or pull request. Merging belongs to the repository's own merge or drainer process, never to this workflow.

Never add or remove a verdict label directly. The configured approval and changes-requested labels (default `reviewed:approve` / `reviewed:changes`) change only as a consequence of the canonical rereview this workflow hands off to, which necessarily switches them. That handoff is the only path by which they may change.

Whenever two reasonable resolutions would differ in behaviour, scope, or user-visible outcome, ask the user through the session's question mechanism rather than choosing.

## 1. Inputs

Require one positive pull request number. Accept the repository and configuration context the caller supplies alongside it, and resolve the repository identity from that context rather than from the local checkout directory name. When the caller supplies none, resolve it from the checkout's own configured remote.

Use that resolved repository for the pull request's own GitHub metadata and for the coordinator handoff: pass it to `gh` as `-R <owner/name>` rather than letting `gh` infer the repository from the local checkout. A fork checkout whose remote points at the fork would otherwise diagnose, or fail on, a same-numbered pull request in the wrong repository.

The resolved repository is where the pull request lives, not necessarily where its head lives. Every fetch and push of the head branch goes to the head repository recorded in step 3 instead, which for a cross-repository pull request is a different repository.

Forward the resolved repository and configuration to the canonical coordinator through the coordinator's own `--repo` and `--config` options, so a fork checkout or a non-default config path repairs and rereviews the same repository the board displays. Omit an option the caller did not supply.

## 2. Diagnose the blocking cause

Read the pull request's merge state, its complete status-check rollup, its labels, its linked issues, and its comments before deciding anything:

```bash
gh pr view <pr> -R <owner/name> --json number,baseRefName,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository,mergeStateStatus,mergeable,labels,statusCheckRollup,closingIssuesReferences,url
```

Resolve two things from the caller's configuration before judging any of that. A blocking label is whatever the effective configuration says it is, never a fixed string: take the configured `changes_requested_label` (default `reviewed:changes`) and `blocked_labels` (default `blocked`) from the same configuration the caller supplied — the global `[workflow]` table, overridden per repository by `[repositories."<owner>/<name>".workflow]` — and match them case-insensitively, exactly as `hasProblemLabel` does in `src/Kanban/Workflow.hs`. A repository configured with non-default labels would otherwise look like it has nothing to repair. Record `baseRefName` too: merge-conflict repair must incorporate that exact branch, and calling a failure pre-existing means reproducing it there rather than on a guessed default branch.

Address the highest-priority blocking cause you find, in the same order and with the same breadth as `pullRequestStatus` in `src/Kanban/Workflow.hs`, so every state that can make a Done card red has a defined branch:

1. **Merge conflict** — resolve it against the recorded `baseRefName`, preserving the pull request's intent while incorporating that base branch's current tip.
2. **Failed check** — any failed check in the pull request's status-check rollup, required or not, not only required checks. Fix the cause. A failure you judge to be pre-existing on the recorded base branch or flaky rather than caused by this pull request must be reported to the user and stop the run, never papered over: no retry loops, no deleted or skipped tests, no weakened assertions.
3. **Blocking label** — one of the configured blocking labels resolved above, with no conflict and no failed check, whatever the check state, passing, pending, or unknown. Never remove a blocking label: a blocking label is a human's decision. Report what is blocking, ask the user, and act only on their answer.

If none of the three is present, report what you found and stop without pushing.

## 3. Work in the pull request's own worktree

Resolve the pull request's head repository, head branch, and exact head SHA before editing anything, and record all three. `headRepositoryOwner` and `headRepository` identify the head repository; `isCrossRepository` reports whether it differs from the resolved repository the diagnosis above used.

A cross-repository pull request is fail-closed. When the head repository differs from the resolved repository, `headRefName` is not a branch of the resolved repository, so never fetch or push that name there: doing so would miss the recorded head, or overwrite an unrelated branch that merely shares its name. Fetch the head commit from the head repository itself, or read-only from the resolved repository's `pull/<pr>/head` ref, and push only to the head repository's own `headRefName`.

Decide whether that push is possible from the head repository itself, never from `maintainerCanModify`: that field reports whether the *base* repository's maintainers may modify the branch, which is neither necessary nor sufficient for the account running this workflow — a fork owner repairing their own pull request routinely has it false and can still push. Attempt the ordinary non-force push to the head repository and let its outcome answer the question. When it is rejected for lack of write access, stop and report that the pull request's head cannot be safely written, having changed nothing on the remote, and never fall back to pushing anywhere else.

Select the worktree by that branch, not by an issue number: reuse any worktree registered to this repository that is already on the pull request's exact head branch, and confirm it tracks the recorded head repository's `headRefName` rather than merely a local branch of the same name. A `solve` worktree named `issue-<n>-<slug>` matches naturally, by branch rather than by name, so this is well defined whether the pull request links zero, one, or several issues.

```bash
git worktree list
```

A dirty or interrupted reused worktree is recoverable work, not a collision: inspect `git status`, `git diff`, `git diff --cached`, and committed progress relative to the recorded head, then preserve and continue there. Never discard, reset, or overwrite unfinished changes, and never create a second worktree on the same branch merely because the first is dirty.

Only when no worktree is on that branch, create one keyed on the pull request number under the repository-scoped worktrees root `${WORKTREES_ROOT:-$HOME/worktrees}/<owner>/<repo>/pr-<n>-<slug>`, outside the source checkout. Never switch the repository's primary checkout.

Make the smallest change that clears the diagnosed cause, then run the checks the changed paths and that cause actually select. Commit that repair as a focused commit before pushing — an uncommitted working tree pushes nothing — and leave any recovered work from a reused worktree intact rather than reverting it or folding it into the repair.

Before pushing, re-fetch the pull request branch from the recorded head repository and verify its remote head still equals the recorded SHA. Push to that exact branch, in that head repository, without force. If the remote head moved, stop and report the competing update rather than overwriting it.

After pushing, verify the head repository's `headRefName` now resolves to a SHA different from the one recorded at the start. That verified new SHA is what "pushed a new head" means in step 4; a push that left the head unchanged transferred no repair, so treat it as having pushed nothing, invoke no rereview, and report it.

## 4. Hand off exactly one canonical rereview

When you pushed a new head, finish by invoking exactly one canonical rereview; that handoff is what re-establishes the verdict on the new head. Do not assume the pull request is still approved after you push.

When you pushed nothing — the blocking-label branch, or a diagnosis that found nothing to repair — there is no new head, so invoke no rereview and simply report what you found.

Kanban resumes this session with the *repaired* repository as the working directory, not this plugin's own install location, so locate the installed coordinator by searching under `$CODEX_HOME` (default `~/.codex`) rather than a path relative to the current directory. Do not pass `--self-review`: this session runs on the pull request's own origin brand and cannot review as the opposite brand itself, so the coordinator must spawn that nested reviewer.

```bash
COORDINATOR="$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" -path '*/kanban/*/skills/pr-review/scripts/review_pr.py' 2>/dev/null | head -n1)"
python3 "$COORDINATOR" \
  --path "$(git rev-parse --show-toplevel)" \
  --rereview <pr> \
  --json
```

Add `--repo <owner/name>` and `--config <path>` to that same call whenever the caller supplied them.

When a push happened but the rereview is unavailable — the coordinator rejects a rereview on a pull request with no prior canonical review marker, and its issue gate blocks a pull request with no linked issue unless explicitly allowed — stop and report that exact reason. A card can reach Done through GitHub's native `reviewDecision == APPROVED` with no canonical review at all, so this is a reachable state. Never compensate by setting a label yourself.

## 5. Report

Return the pull request number, the diagnosed blocking cause, the recorded and pushed head SHAs, which worktree was used and whether it was reused or created, exactly what changed and what was run, the state of the pushed head's checks, and the canonical rereview route, verdict, and comment URL — or the exact reason no rereview ran.
