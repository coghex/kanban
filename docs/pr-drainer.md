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
- loads the job without starting it.

Rerun the installer after moving the repository checkout.

## Start and stop

Press `d` in Kanban to start or stop the drainer.

Only one managed drainer can run for the user at a time. A Kanban window for another repository reports that the drainer belongs to a different project and will not stop or replace it.

Installation never starts the drainer. Starting it can merge eligible pull requests immediately.

The controller refuses to start from a checkout with staged, unstaged, or
untracked changes. Kanban renders that condition in red and reports that the
changes must be committed, stashed, or discarded first. This keeps the
drainer's post-merge fast-forward from interfering with an in-progress hotfix.

It also requires the checkout to be on the repository's default branch. This
keeps its post-merge fast-forward from moving a feature branch.

After each successful merge, the drainer fast-forwards its managed default
branch to the current remote tip.

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
  which Kanban shows in the sidebar next to the drainer state;
- changes no label — in particular it never removes `reviewed:approve`, which
  the `review-approved` gate requires, and never applies `reviewed:changes`;
- keeps running and keeps draining every other approved pull request;
- records nothing new on later polls while that conflict persists, so one
  conflict means one incident.

Resolve the conflict on the pull request branch. Once GitHub reports the pull
request mergeable again — or the pull request is closed — the next poll
resolves that incident on its own. Incidents belonging to other pull requests,
and to a drainer crash, are left open. There is no manual dismissal step.

## Notifications

Crash and merge-conflict notifications are off by default. To use a private ntfy endpoint:

```console
python3 tools/install_drainer.py --ntfy-url https://your-server.example/topic
```

The endpoint is stored in a private configuration file and is not written into the LaunchAgent plist.

## Files and logs

- Installed links and private configuration: `~/Library/Application Support/kanban/pr-drainer/`
- Logs: `~/Library/Logs/kanban/pr-drainer/`
- LaunchAgent: `~/Library/LaunchAgents/com.coghex.drain-prs.plist`
- Repository queue state: `.git/drain_prs_state.json`

The controller records unexpected exits as incidents, and the drainer records a merge conflict as a per-pull-request incident. Expected pull-request failures remain in the queue and are retried without stopping the service. Stopping the drainer intentionally clears any open incidents for that repository; a conflict that is still unresolved is recorded again on the next poll after it restarts.

## Manual status

Normal control should happen through Kanban. For diagnosis, run:

```console
CONTROL="$HOME/Library/Application Support/kanban/pr-drainer/drain_prs_service.py"
python3 "$CONTROL" --path /path/to/project --json status
python3 "$CONTROL" --path /path/to/project --json logs --lines 120
```

Do not run `drain_prs.py` directly during normal operation.
