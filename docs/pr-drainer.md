# PR drainer

The PR drainer watches one repository and merges open pull requests that are approved and have passed the required checks. It also updates branches that are behind. It never resolves a merge conflict: a conflicted pull request is reported and left alone.

The drainer is optional. Kanban works without it.

Each canonical GitHub repository gets its own drainer. Install as many as you
like on one account: they have separate LaunchAgents, runtime state, logs, and
incidents, and starting or stopping one does not touch another. What a drainer
is *named* by is the checkout's canonical GitHub `owner/name`, compared without
regard to case — so `Acme/Widgets` and `acme/widgets` are one drainer, and two
clones of one repository cannot drain it at the same time. A checkout whose
remote is not a supported github.com URL cannot have a drainer at all.

That name comes from the remote the **shared** Kanban configuration
(`~/.config/kanban/config.toml`, or `$XDG_CONFIG_HOME/kanban/config.toml`)
names — the same remote Kanban itself resolves the board's repository through.
A dashboard that resolves a *different* repository, because it was started with
`kanban --repo OWNER/NAME` or with a `--config` naming another remote, is
talking about another canonical repository: it reports the drainer as not
installed for that repository, and the controller refuses its requests rather
than acting on this checkout's job behind its back. Point both at one
repository by setting `remote_name` in the shared configuration, which moves
the dashboard and the drainer together.

### Changing `remote_name` after installing

An installed job is pinned to the repository it was installed for: its plist
records that identity, and its LaunchAgent refuses to drain anything if the
checkout stops resolving to it. So changing `remote_name` in the shared
configuration does not silently re-point an existing drainer at whatever
repository the new remote names — it stops that drainer instead, with a line in
its own service log saying so.

Re-run the installer to pick the change up:

```console
python3 tools/install_drainer.py
```

That installs a job for the repository now configured. The superseded job stays
loaded but inert; remove it when convenient with

```console
launchctl bootout gui/$(id -u)/com.coghex.drain-prs.<old-slug>
rm ~/Library/LaunchAgents/com.coghex.drain-prs.<old-slug>.plist
```

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

- refuses to run while this repository's drainer is active;
- refuses to overwrite ordinary files;
- creates stable links under `~/Library/Application Support/kanban/pr-drainer/`,
  shared by every repository;
- installs `~/Library/LaunchAgents/com.coghex.drain-prs.<owner>.<name>.plist`,
  named for this repository's normalized identity;
- records that job's label, plist path, and checkout under this repository's
  entry in `~/Library/Application Support/kanban/pr-drainer/config.json`, which
  is how Kanban finds it;
- loads the job without starting it.

Run it once per repository, from that repository's own main checkout. Installing
a second repository adds its entry beside the first; it never replaces it.

Rerun the installer after moving the repository checkout. Rerun it as well if
Kanban reports that the drainer is not installed for this repository or that its
install record is unreadable — an installation predating the record is repaired
in place, with no uninstall first and no change to the LaunchAgent's identity.

### Migrating from the single machine-wide drainer

Before per-repository jobs there was one drainer for the whole account, labelled
`com.coghex.drain-prs`. To migrate, stop it and rerun the installer from each
repository you want drained:

```console
python3 tools/install_drainer.py
```

The first install for a repository the old job served unloads that job and
renames its plist to `com.coghex.drain-prs.plist.retired`, so the old and new
jobs can never run together. A legacy job installed for a *different*
repository is left alone until you migrate that repository the same way.

Two things do not migrate themselves:

- `--config`. It is now stored per repository, so pass it again for each
  repository that needs one: `python3 tools/install_drainer.py --config
  /path/to/config.toml`. A repository without one uses the normal shared
  Kanban configuration. `--ntfy-url` is global and is *not* re-entered.

  Note that a `remote_name` set in that file selects the remote the drainer
  *works against* — its default-branch check and its merges — but not which
  repository the job is for. The drainer's identity always comes from the
  remote the shared Kanban configuration names, which is the remote Kanban
  itself resolves the board's repository through. To drain a fork's upstream
  under that upstream's name, set `remote_name` in the shared configuration.
- The old job's logs and runtime state under
  `~/Library/Logs/kanban/pr-drainer/` and the install directory's `runtime/`.
  New jobs write into per-repository subdirectories beside them; the old files
  can be deleted once you no longer want them.

## Start and stop

Press `d` in Kanban to start or stop this repository's drainer.

Drainers for different repositories run independently, and each Kanban window
reports only its own repository's. Two checkouts of *the same* repository share
one drainer, because they are one repository: whichever starts second is refused,
and the message names the checkout already running it.

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

A conflicted restore also leaves the conflict itself in the checkout: git writes
the partial merge it computed into the working tree and unmerged entries into
the index. The drainer leaves both exactly as they stand — that partial merge is
usually most of the resolution work — and every later fast-forward refuses while
they do, naming the unmerged index and the paths, because no snapshot of local
changes can be taken over one. Only that step refuses: the drainer keeps
running, keeps merging every other approved pull request, and keeps discharging
their other post-merge obligations, so the fast-forwards accumulate as
outstanding debts on the records that own them.

Resolve the named paths and `git add` them. That is the whole recovery — the
next ordinary pass discharges the outstanding fast-forward on its own, with no
restart, no acknowledgement, and no manual drainer command. Recovering the
snapshot itself is independent of all of this and unchanged: it stays reachable
through `git stash list` and `refs/drain-prs/autostash/<sha>` whether or not the
index is resolved first.

#### An edit that arrives after the snapshot

Setting tracked changes aside is not instantaneous. `git stash create` records
the index and working tree as they stood when it ran, and `git reset --hard
HEAD` — which discards whatever is in the working tree when it runs — comes
afterwards. An edit written into that window is in neither the snapshot nor, once
the reset has run, the working tree. Untracked files never had this exposure:
`reset --hard` leaves them alone, and their holding directory is taken before the
snapshot.

The drainer therefore ends the window with a **final pre-reset protection
boundary** — the last operation before the reset that reads tracked index and
working-tree state in order to decide whether the reset is safe. It re-reads that
state and compares it, by content, against the snapshot the reset is about to
rely on. What that read sees is what is protected.

- **They match.** Nothing landed in the window, the snapshot is a faithful copy,
  and the pass continues into the reset, the retry, and the restore exactly as
  described above.
- **They differ.** The newer content is in the working tree and not in the
  snapshot, so the drainer runs neither the reset nor the retrying
  `git merge --ff-only`. HEAD, the index, and the tracked working tree are left
  exactly as they stand, with the newer content still in place; any relocated
  untracked files are put back under the contract above; and the snapshot already
  taken is preserved and named the same way a failed restore names it, so it
  costs nothing. The fast-forward is simply left owed, and the next ordinary pass
  discharges it.
- **The boundary cannot be read.** Treated as the differing case. A tracked state
  that cannot be read or verified is never grounds for a destructive reset.

This bounds the exposure to the moment between that read and the reset rather
than the whole snapshot-to-reset window; it does not eliminate it. A writer that
changes a path *after* the boundary has read that path still wins, and closing
that last interval needs the drainer and everything else writing to the checkout
to coordinate — a lock, an atomic writer protocol, or an isolated checkout —
which is deliberately outside this contract.

#### The lifecycle of an autostash anchor

The anchor at `refs/drain-prs/autostash/<sha>` exists so the snapshot commit is
never reachable from no ref at all, and it is created before the reset that
makes it the only copy. Its whole life:

- **Created** ahead of the `reset --hard`, from the commit `git stash create`
  produced.
- **Released** by the same pass, as soon as `git stash apply --index` puts the
  changes back — at that point the anchor has nothing left to protect.
- **Kept** when that restore conflicts. The same pass also stores the snapshot
  into `git stash list`, so two copies are deliberately left behind rather than
  one, and neither is removed while the restore is unresolved.
- **Reaped** by a later run, never the one that created it. Each drainer
  process sweeps the namespace once at startup, before it can merge or
  fast-forward anything, and deletes an anchor only when its exact commit is
  one of the entries `git stash list` reports — including entries below
  `stash@{0}`. The stash is yours to drop or clear at any moment, so that
  reading is confirmed again *after* the ref is gone: if the snapshot is not
  still an entry then, or the stash cannot be read to say, the anchor goes
  straight back. Nothing else about the stash is read, written, or reordered,
  and a `--dry-run` sweep reports without deleting.
- **Listed** in the log for as long as it is not provably redundant, naming the
  ref, its commit, that commit's date, and the command that restores it. An
  anchor that outlives one startup and is still reported holds work that is in
  no stash entry.

Enumerate them yourself with:

```console
git for-each-ref refs/drain-prs/autostash
```

Every failure of the sweep — enumerating, reading the stash, or deleting a ref
— is logged and stepped over. Merging never depends on it.

## Merging one pull request

Besides the polling service, the drainer can process exactly one named pull
request and exit:

```console
python3 tools/drain_prs.py --path /path/to/project --pr 42
```

This applies the same gates, guards, ordering and post-merge audit as a poll
cycle — it runs the queue's own per-pull-request code, not a second copy of it
— so it merges nothing the queue would refuse. It reads and touches only the
named pull request: no other pull request is listed or recovered, no pass
counter moves, and neither the [queue order](#queue-order) nor its active
candidate is consulted or changed.

`--pr` and `--once` are mutually exclusive.

Kanban's `m` key drives exactly this entry point for the selected Done card;
see [the user guide](user-guide.md). It refuses while *any* open incident
stands, whatever its kind and whichever pull request it names. A merge-conflict
or cleanup incident now survives an intentional stop, so it refuses `m` where
being cleared by the stop used to allow the merge. Finish the work the incident
names, or dismiss it with `ack`, before `m` will run.

### Naming the repository

`--repo OWNER/NAME` asserts which repository `--path` is a checkout of, and the
run is refused before any pull request is read if the checkout's remote names
another one. A caller can resolve its repository through configuration Kanban's
`--repo` or `--config` overrode, and a pull-request number means nothing across
that gap — #42 there and #42 here would be different pull requests. The
assertion applies in both modes, and omitting it leaves the identity to the
remote as before. Case is not significant: GitHub owner and repository names
are case-insensitive, so two spellings that differ only in case name one
repository.

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

## Queue order

Each polling pass walks the approved queue in ascending pull-request number and
advances **at most one** candidate. Nothing about a pull request's history
reorders that: an earlier scheduler picked the least recently attempted
candidate, which let a higher number overtake a lower one and — because every
branch update starts CI — spread a queue's worth of workflow runs across pull
requests that were nowhere near merging.

A candidate's turn ends in one of three ways.

- **A skip continues the pass.** The next-lowest candidate gets its turn in the
  same pass. A candidate is skipped when nothing the drainer can do would
  advance it and that says nothing about the pull requests behind it: it is
  closed, a draft, targets another branch, lost its approval or gained
  `reviewed:changes`, conflicts with the default branch (recorded as an
  incident, as below), has a required check that failed with no automatic rerun
  left to start, has moved to a head no review has cleared, or is still cooling
  down after a failed attempt.
- **A barrier ends the pass with nothing else touched.** A candidate whose
  required CI or review check is missing, queued, pending, or in progress —
  including the replacement checks a branch update or an automatic CI rerun
  just started — is waiting, not blocked. No later pull request is updated,
  rerun, or merged while it waits; the pass ends and the next ordinary poll
  looks at that candidate again.
- **An advance ends the pass too.** Updating a branch that is behind,
  requesting an automatic CI rerun, and merging are each the whole of one pass.

`--once` is exactly one such pass: it skips the blocked candidates, stops at
the first advance or barrier, and exits.

### Merging past a coordination-only base advance

A branch update is how a candidate that is behind the default branch normally
advances, and it costs a full rebuild of a pull request the new base commit
could not have broken. The drainer skips that update for exactly one shape of
advance, and only when the repository has said which paths that shape is made
of, in `workflow.coordination_paths` (`config.toml.example`):

```toml
[workflow]
coordination_paths = ["docs/status.md", "ROADMAP.md"]
```

Each entry is one exact, case-sensitive, repository-relative path. Globs,
directory prefixes, and extension matching are not implied, and a rename counts
both its source and its destination, so every path you mean has to be listed.
The key defaults to empty; a repository that sets nothing requests a branch
update for every advance, exactly as the drainer always has. Never list a
document a test parses — in this repository `docs/agent-workflow-contract.md`
and `docs/drafting-workflow-contract.md` are parsed by
`tools/test_agent_workflow_contract.py` and
`tools/test_drafting_workflow_contract.py`, so a change to either really can
fail `build-test`, and that is a rebuild worth paying for.

The drainer merges past an advance only when all of this holds:

- The candidate's `mergeStateStatus` is `BEHIND`.
- `coordination_paths` is non-empty.
- Every file the default branch gained between this pull request's merge base
  and the current default-branch tip is one of those exact paths.
- None of those files is a file the pull request itself changes.
- Both file sets were established completely, pinned to the pull request head,
  merge base, and default-tip object IDs, and both comparisons agreed on the
  merge base.
- The default branch still points at that same inspected tip immediately before
  the merge.

Reaching that point grants the candidate nothing. It merges only if the
required CI check and the required review gate pass exactly as they must for
any other pull request, re-checked immediately before the merge as always.

Everything else requests the branch update as before: a file outside the
configured set, an overlap with the pull request's own files, an unset or empty
set, a comparison GitHub truncated or answered malformed, an unreadable tip, an
indeterminate merge base, a default branch that moved before the merge, and any
other failure to establish either file set. Uncertainty requests the update.

If the merge is attempted and GitHub refuses it while the pull request is still
open at the head just attempted, the pass requests the branch update instead
and reports the refusal alongside it. The candidate is never reported as merged
and never left stranded. A head that moved during the merge still defers for a
fresh review, as it does on the ordinary path, and a refusal against a pull
request that cannot be read, or is no longer open, fails the pass rather than
claiming either outcome.

Either way this is one advance and one pass: the merge completes and releases
the active lane, or the branch update is requested and holds it.

### The active candidate

A candidate that reaches a barrier or takes an advance owns the queue's *active
lane*, recorded in the queue state so it survives both polling iterations and a
drainer restart. That candidate is examined first on later passes, so a pull
request that becomes eligible while it waits cannot preempt it however much
lower its number.

The lane is released when the pull request merges or closes, loses its
approval, gains `reviewed:changes`, develops a merge conflict, exhausts its
automatic CI reruns, leaves the eligible queue for any other reason, or reaches
any of the skips above. Selection then restarts at the lowest number — within
the same pass, and no candidate is examined twice in one pass.

An operational failure is none of those things. A `gh` call whose effect the
drainer cannot establish ends the pass where it stands rather than moving on to
another pull request, and leaves the lane as it found it.

### When everything is blocked

A pass in which every candidate is skipped merges nothing, updates nothing,
reruns nothing, and returns to the normal polling wait. It does not probe a
cooling candidate merely because it has nothing else to do. Failure cooldowns
are denominated in passes rather than in attempts, so they expire on their own:
an all-blocked queue does not have to advance some unrelated pull request first.

Recording a merge-conflict incident is not an advance, so one pass can record
more than one — it skips each conflicting candidate in turn. Marking an
approved draft ready for review is likewise not an advance and still applies to
every approved draft in the queue.

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
and to a drainer crash, are left open. Stopping the drainer does not clear it
either: a stop makes no pull request mergeable, so the incident waits for the
poll that finds the conflict gone. The one manual dismissal is `ack`, which
resolves an open incident of any kind.

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
  itself once the last obligation succeeds — including when the obligation that
  finishes it is discharged by the final pass of a stop. Stopping the drainer
  never clears an incident whose debt survives the stop: that one stands until
  a later pass discharges it, or until it is dismissed with `ack`.
- A merge attempts its own obligations immediately, including a single
  pull-request run; what it leaves outstanding is retried by the polling loop's
  sweep and by one final pass on the way out of an intentional stop.
- That final pass is what keeps a stop from walking away from recorded debt.
  The drainer holds the repository run lock for its whole lifetime, so nothing
  else can work these obligations while it is alive, and nothing works them at
  all once it exits — the next start may be days away. So the stop spends a
  bounded slice of its own shutdown on them:
  - Only already-recorded obligations. The pass starts no new per-pull-request
    work: no branch update, no merge, no rereview, and no pull-request read. A
    queue entry with no recorded cleanup is left entirely alone.
  - Eight seconds, and no obligation starts after them — not the next pull
    request's, and not the next step of the one in flight. Every command inside
    the pass is bounded by the same deadline, so an obligation that wedges is
    left outstanding rather than holding the stop open. A fast-forward stopped
    that way keeps the recovery contract above: tracked changes stay
    recoverable from the autostash anchor or `git stash list`, untracked files
    stay in their holding directory, and the fast-forward stays owed.
  - A step the budget left unattempted is not a failed pass. It has resisted
    nothing, so it moves no failed-pass counter and escalates no incident; it
    is simply still owed.
  - Whatever the pass does not discharge stays outstanding and visible —
    recorded in the queue state, reported by `status`, and under whatever
    incident it had raised. Nothing on the stop path clears it.
  - `stop` reports `cleanup_discharged` and `cleanup_outstanding`, both read
    off the persisted state either side of the stop, and both `null` when that
    state could not be read. A stop that could not discharge everything still
    succeeds: outstanding debt is a debt to retry, not a failed stop.
  - A stop with nothing recorded runs no command and writes no state, so it
    costs exactly what it did before.
- Outstanding obligations are visible in `status` before any of that: its
  `cleanup_obligations` field names every pull request that still owes, its
  remaining steps, how many passes have failed, and the last error — whether or
  not an incident has been raised, and whether or not the drainer is running.
  Kanban's sidebar summarises the same field as a count beside the drainer
  state. The field is `null` when the queue state could not be read at all,
  which is not the same answer as the empty list a drainer owing nothing
  reports. Reading it takes no lock and changes nothing.
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

Below, `<slug>` is the repository's normalized `owner/name` encoded for a
filename — `coghex/kanban` becomes `coghex.kanban`. It is the same slug the
LaunchAgent label ends with, so the log directory, the runtime directory, and
the plist of one repository all carry the same name.

- Installed links, shared by every repository: `~/Library/Application Support/kanban/pr-drainer/`
- Install record Kanban resolves each LaunchAgent through, and the global
  private configuration (`ntfy_url`) that shares it:
  `~/Library/Application Support/kanban/pr-drainer/config.json` — this path is
  fixed, and `--install-dir` does not move it. Its `repositories` table holds
  one entry per installed repository, carrying that job's label, plist path,
  checkout, and `config_path`.
- Runtime status and incidents: `~/Library/Application Support/kanban/pr-drainer/runtime/<slug>/`
- Logs: `~/Library/Logs/kanban/pr-drainer/<slug>/`
- LaunchAgent: `~/Library/LaunchAgents/com.coghex.drain-prs.<slug>.plist`
- Repository queue state: `.git/drain_prs_state.json`
- Repository run lock: the `.git` directory, plus `.git/drain_prs.lock` holding
  the holder's PID, beside `.git/drain_prs.lock.owner.json`, which records
  whether that PID is the polling service or a single-PR run. This lock is per
  *checkout*, and remains a secondary guard: two clones of one repository are
  excluded from running concurrently by their shared canonical identity, which
  the lock cannot see.

The controller records unexpected exits as incidents, and the drainer records a merge conflict and an unfinished post-merge cleanup as per-pull-request incidents. Expected pull-request failures remain in the queue and are retried without stopping the service. Incidents are attributed to the canonical repository rather than to the checkout that raised them, so any clone of that repository can list, acknowledge, and clear them. Stopping the drainer intentionally clears that repository's crash incidents, and no other repository's — a stop ends the supervisor, which is exactly what a crash incident is about. It resolves nothing else: a conflict or cleanup incident stays open across the stop, still naming a debt that is still owed, and clears through its own path once that pull request is mergeable or closed or its last obligation succeeds. Starting the drainer is not gated on an open incident of any kind, and an incident already open when it starts is never mistaken for a startup failure.

## Manual status

Normal control should happen through Kanban. For diagnosis, run:

```console
CONTROL="$HOME/Library/Application Support/kanban/pr-drainer/drain_prs_service.py"
python3 "$CONTROL" --path /path/to/project --json status
python3 "$CONTROL" --path /path/to/project --json logs --lines 120
python3 "$CONTROL" --path /path/to/project --json ack --note "conflict resolved by hand"
```

Every command selects the repository `--path` is a checkout of, including
`logs`, which shows that repository's own dated log. Add
`--repo OWNER/NAME` to assert which repository you expect; the controller
refuses it when the checkout's remote says otherwise.

`ack` is the manual dismissal named above. With no incident ID it resolves the
newest open incident for that repository, of any kind; with one, that incident.

Do not run `drain_prs.py` directly during normal operation, apart from the
single-pull-request mode above, which is meant to be invoked on request.
