# PR drainer

The PR drainer watches one repository and merges open pull requests that are approved and have passed the required checks. It also updates branches that are behind. It never resolves a merge conflict: a conflicted pull request is reported and left alone.

The drainer is optional. Kanban works without it.

## Install

The installer is for macOS and does not require `sudo`.

Preview the changes:

```console
python3 tools/install_drainer.py --dry-run --json
```

Install the stopped LaunchAgent:

```console
python3 tools/install_drainer.py
```

The installer:

- refuses to run while a drainer is active;
- refuses to overwrite ordinary files;
- creates stable links under `~/Library/Application Support/kanban/pr-drainer/`;
- installs `~/Library/LaunchAgents/com.coghex.drain-prs.plist`;
- records that job's label, plist path, and repository in
  `~/Library/Application Support/kanban/pr-drainer/config.json`, which is how
  Kanban finds it;
- loads the job without starting it.

Rerun the installer after moving the repository checkout. Rerun it as well if
Kanban reports that the drainer is not installed or that its install record is
unreadable — an installation predating the record is repaired in place, with no
uninstall first and no change to the LaunchAgent's identity.

## Start and stop

Press `d` in Kanban to start or stop the drainer.

Only one managed drainer can run for the user at a time. A Kanban window for another repository reports that the drainer belongs to a different project and will not stop or replace it.

Installation never starts the drainer. Starting it can merge eligible pull requests immediately.

The drainer coexists with uncommitted local work. It starts, runs, and merges
from a checkout holding staged, unstaged, or untracked changes; nothing has to
be committed, stashed, or discarded first. Merging itself is GitHub's and never
reads the checkout, and the post-merge fast-forward sets local changes aside
and puts them back.

It refuses to start only when the checkout is stopped part-way through a git
operation — an unfinished merge, rebase, `am`, cherry-pick, revert, or bisect —
because the fast-forward cannot succeed until a human finishes or aborts it, so
every merge in the run would fail the same avoidable way. Kanban renders that
condition in red and names the operation to finish. The check reads the markers
git writes into the git directory and changes nothing: an unresolved conflict is
left exactly as it stands.

It also requires the checkout to be on the repository's default branch. This
keeps its post-merge fast-forward from moving a feature branch. The
operation-state check runs first, because a rebase or a bisect commonly leaves
a detached HEAD and the message should name the operation rather than the
branch.

After each successful merge, the drainer fast-forwards its managed default
branch to the current remote tip.

### Recovering local changes after a failed fast-forward

If local changes stand in the way of the fast-forward, the drainer sets them
aside for the retry and restores them in a `finally`, so the ordinary outcome is
that they reappear on the new tip. Tracked edits are snapshotted with `git stash
create`, which writes no entry into the shared `git stash list`, and untracked
files are moved into a holding directory under the git directory rather than
recorded in git at all. When a restore does fail, the message says exactly where
what it was holding ended up, and the two kinds recover differently.

- **Tracked changes.** The drainer first tries to expose the snapshot commit
  through `git stash list`; if that succeeds the message says so, and the entry
  is resolved from there like any other stash. If it fails, the snapshot stays
  anchored at `refs/drain-prs/autostash/<sha>` and the message names that ref —
  restore it with `git stash apply --index <sha>`. Only if both fail is the
  commit unreferenced, and the message says so in as many words. Expect to
  resolve a conflict either way: a restore only fails because reapplying the
  snapshot onto the new tip conflicted.
- **Untracked files.** These never enter any ref, so they are never in
  `git stash list`. Files that could not be put back stay in the holding
  directory (`.git/autostash-*`), which the message names along with each file
  and why it was left. The usual reason is a genuine collision: the
  fast-forward now tracks a file at that path, and overwriting it would destroy
  the incoming content, so the local copy waits in the holding directory for
  manual reconciliation instead.

## Merging one pull request

Besides the polling service, the drainer can process exactly one named pull
request and exit:

```console
python3 tools/drain_prs.py --path /path/to/project --pr 42
```

This applies the same gates, guards, ordering and post-merge audit as a poll
cycle — it runs the queue's own per-pull-request code, not a second copy of it
— so it merges nothing the queue would refuse. It reads and touches only the
named pull request: no other pull request is listed, recovered, or moved
through the queue's fair rotation, and no failure cooldown is advanced.

`--pr` and `--once` are mutually exclusive.

### Output

Exactly one JSON document is written to stdout, and nothing else; every human
log line goes to stderr and the log file. A caller can present `message`
verbatim.

```json
{
  "schema": "drain-prs-single-pr",
  "version": 1,
  "pull_request": 42,
  "outcome": "no_action",
  "merged": false,
  "would_merge": false,
  "reason": "checks_pending",
  "message": "PR #42 is waiting on its required checks (build-test=pending, review-approved=success, mergeStateStatus=BLOCKED).",
  "dry_run": false
}
```

`outcome` is `merged`, `no_action`, or `error`. `reason` is one of a fixed
vocabulary:

| `reason` | Meaning |
| --- | --- |
| `merged` | The pull request was merged. |
| `would_merge` | Dry run only: every gate passed, so a real run would merge it. |
| `not_approved` | The approval label is missing. |
| `changes_requested` | The changes-requested label is attached. It takes precedence when both labels are. |
| `checks_pending` | A required check has not reported a result yet. The message names each configured check and its state, including `missing` for one that has not run at all. |
| `checks_failed` | A required check failed. |
| `merge_conflict` | The pull request conflicts with the default branch. It was recorded as an incident and left alone. |
| `behind_base` | The branch was behind the default branch. The update was requested; merging waits for a later run. |
| `mergeability_computing` | GitHub has not finished computing mergeability. |
| `approved_head_changed` | The approval belongs to an older head. The pull request needs a fresh review. |
| `not_eligible` | The pull request is closed, still a draft, or targets another branch. |
| `run_locked` | Another drainer run holds the repository. The message names it. |
| `repository_precondition_failed` | The checkout, remote, or drainer configuration is unusable — including the unfinished-operation refusal and the default-branch requirement above. |
| `post_merge_audit_failed` | The merge landed but the post-merge audit found a gate violation. `merged` is `true`. |
| `post_merge_cleanup_failed` | The merge landed but its post-merge cleanup is still outstanding. The message names the remaining steps, the drainer keeps retrying them, and `merged` is `true`. |
| `operational_error` | Anything else went wrong. |

### Exit status

| Status | Meaning |
| --- | --- |
| `0` | A merge completed. |
| `2` | No merge happened. A non-dry run may still have updated a branch behind its base or recorded a conflict incident. |
| `1` | An error. `merged` may still be `true` if the merge landed before the failure. |

A usage error exits `2` with nothing on stdout, so treat empty stdout as a
startup failure rather than as a no-merge result.

### Dry run

`--dry-run` reports the same outcome and makes no GitHub, filesystem, or git
mutation — no merge, no branch update, no incident, no queue-state write, no
log file, no lock file, and no bytecode cache. A dry run that passes every gate
reports `would_merge` and exits `2`, because no merge completed.

That purity covers the whole process in either mode: a polling dry run
(`--once --dry-run`) writes no log file and creates no lock file either.

### One run at a time

A single-PR run and the polling service share one exclusive lock per
repository, so they can never act on the same repository at once. Whichever
starts second fails immediately without acting, naming the holder — the
polling drainer, or the single-PR run and its pull request number.

A real run locks `.git/drain_prs.lock` and then the repository's `.git`
directory. A dry run locks the directory alone, because creating or writing
the lock file is exactly what it must not do. The directory is what always
exists to be locked, so a dry run is still excluded by a concurrent run and
still excludes one, even in a repository where no lock file has ever been
written.

That order is also how the second run names the first, so it is part of the
contract rather than an implementation detail. A real run holds the lock file
from before it holds the directory until after it releases it, so holding the
directory *without* the file means a dry run, at every instant — including
while a real run is still starting up and has not yet recorded its PID and
mode. Those are read from the lock file and its `.owner.json` sidecar only to
add detail: which mode, and which pull request.

One consequence is deliberate: a dry run no longer collides with a drainer
still running from an older version of this script, which locks only the file.
That exclusion protected nothing, because a dry run mutates nothing — the
worst a concurrent old run can do is make its report a moment stale.

## Approval and checks

A pull request must have the `reviewed:approve` label and must not have `reviewed:changes`.

The default required checks are:

- `build-test`
- `review-approved`

A repository can change or disable those check names with `.drain-prs.json`:

```json
{
  "required_ci_check": "project-ci",
  "required_review_check": null
}
```

A value of `null` disables that status-check requirement. It does not remove the approval-label requirement.

## Merge conflicts

A merge conflict is the one thing in this pipeline no reviewer has seen: the
verdict covered the pre-merge diff, and the drainer merges with an admin merge
that bypasses branch protection. So the drainer stops merging that pull request
and asks instead of guessing.

When a conflict is detected, the drainer:

- records an open incident naming the pull request and its conflicting files,
  which Kanban shows in the sidebar next to the drainer state. The files are
  read from the pull request's exact head commit, so a fork's head is named
  correctly; a head that cannot be fetched at all is still reported, without
  the file list;
- changes no label — in particular it never removes `reviewed:approve`, which
  the `review-approved` gate requires, and never applies `reviewed:changes`;
- keeps running and keeps draining every other approved pull request;
- records nothing new on later polls while that conflict persists, so one
  conflict means one incident.

Resolve the conflict on the pull request branch. Once GitHub reports the pull
request mergeable again — or the pull request is closed — the next poll
resolves that incident on its own. Incidents belonging to other pull requests,
and to a drainer crash, are left open. There is no manual dismissal step.

## Post-merge cleanup

A merge is durable on GitHub the moment it returns, but the work it implies is
not: closing the linked issues, removing the matching worktree, deleting the
local and remote head branches, and fast-forwarding the local default branch.
So the drainer records those obligations in its queue state *before* attempting
any of them, and drops the record only once every one of them is done.

- Each obligation is retried independently until it succeeds or is verified
  already done. An issue that is already closed, a branch that is already gone,
  and an absent worktree all count as done.
- One obligation failing never skips the ones after it in the same pass.
- A linked issue is recorded as `owner/name#number`, so a pull request that
  closes an issue in another repository is retried against that repository.
- Obligations still outstanding after three passes are recorded as an open
  incident, which Kanban shows in the sidebar. The drainer keeps retrying them
  and keeps draining every other approved pull request; the incident resolves
  itself once the last obligation succeeds.
- If the drainer is restarted or the pull request merges without its cleanup
  being recorded, the next poll reads the merged pull request and finishes the
  outstanding work. A pull request closed *without* merging owes nothing: it is
  forgotten without closing any issue or deleting any branch.

## Notifications

Crash, merge-conflict, and cleanup notifications are off by default. To use a private ntfy endpoint:

```console
python3 tools/install_drainer.py --ntfy-url https://your-server.example/topic
```

The endpoint is stored in a private configuration file and is not written into the LaunchAgent plist.

## Files and logs

- Installed links and private configuration: `~/Library/Application Support/kanban/pr-drainer/`
- Install record Kanban resolves the LaunchAgent through: `~/Library/Application Support/kanban/pr-drainer/config.json`
- Logs: `~/Library/Logs/kanban/pr-drainer/`
- LaunchAgent: `~/Library/LaunchAgents/com.coghex.drain-prs.plist`
- Repository queue state: `.git/drain_prs_state.json`
- Repository run lock: the `.git` directory, plus `.git/drain_prs.lock` holding
  the holder's PID, beside `.git/drain_prs.lock.owner.json`, which records
  whether that PID is the polling service or a single-PR run

The controller records unexpected exits as incidents, and the drainer records a merge conflict and an unfinished post-merge cleanup as per-pull-request incidents. Expected pull-request failures remain in the queue and are retried without stopping the service. Stopping the drainer intentionally clears any open incidents for that repository; a conflict or cleanup that is still unresolved is recorded again on the next poll after it restarts.

## Manual status

Normal control should happen through Kanban. For diagnosis, run:

```console
CONTROL="$HOME/Library/Application Support/kanban/pr-drainer/drain_prs_service.py"
python3 "$CONTROL" --path /path/to/project --json status
python3 "$CONTROL" --path /path/to/project --json logs --lines 120
```

Do not run `drain_prs.py` directly during normal operation, apart from the
single-pull-request mode above, which is meant to be invoked on request.
