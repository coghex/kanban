# Kanban

Kanban is a terminal board for GitHub projects. It reads a local checkout's
GitHub remote and sorts that repository's issues and pull requests into four
columns — Issues, Active, Reviewing, and Done — so the state of the work is one
keystroke away instead of one browser tab away.

It is for people who already live in a terminal and want the board there too:
it starts fast, stays idle when you are not using it, makes no network request
you did not ask for, and uses the GitHub CLI login you already have. Beyond the
board, it can optionally show Codex and Claude usage, start work on an issue,
run a review, and track those jobs without leaving the terminal.

![The Kanban board filling a terminal: a usage sidebar showing Codex and Claude limits beside the Issues, Active, Reviewing, and Done columns, which hold issue and pull-request cards with labels, review state, and CI status, one card selected](docs/media/board-wide.png)

## Quickstart

### Before you start

The board itself needs three things:

- [Git](https://git-scm.com/)
- [GitHub CLI](https://cli.github.com/), signed in with `gh auth login`
- GHC and Cabal, used to install the executable

That is the whole list. Codex, Claude, Kanban's workflow bundles, and the PR
drainer are needed only for the optional features described further down; the
board works without any of them.

Kanban is built and tested against **GHC 9.12.2 and Cabal 3.16.1.0** — the
versions the required CI job pins, and the ones an install is verified with.
[ghcup](https://www.haskell.org/ghcup/) installs both.

### Install from a release archive

Kanban releases are tagged `v<version>` and carry the `cabal sdist` source
archive `kanban-<version>.tar.gz` as their asset.

From an empty directory:

```console
gh release download --repo coghex/kanban --pattern 'kanban-*.tar.gz'
tar -xzf kanban-*.tar.gz
cd kanban-*/
cabal update
cabal install exe:kanban
```

No clone of this repository is required. Omitting the tag downloads the latest
release, so the commands do not need editing when the version changes.

If `kanban` is not found afterwards, add Cabal's user binary directory
(normally `~/.local/bin`, or the path named in Cabal's installation warning) to
your `PATH`.

The archive carries `cabal.project`, which turns warnings into errors for the
`kanban` package — the gate contributors build under. On a toolchain other than
the verified one, a new warning can therefore stop an otherwise fine install.
If that happens, relax the gate for your local build and re-run the install:

```console
printf 'package kanban\n  ghc-options: -Wwarn\n' > cabal.project.local
```

**Keep the extracted directory.** The executable runs the board on its own, but
the optional setup tools, workflow bundles, and PR drainer are installed from
the tracked files inside that directory, and their setup commands are run from
it. None of them asks the archive for Git metadata, which it deliberately does
not carry. The two that install a *service* do need to be told which repository
that service is for, because an archive is not one: pass `--repo` to
`tools/install_drainer.py` and `tools/install_issue_approval.py`, as the
examples below do. Workflow setup needs `--target` for the same reason when it
declares a project-scoped provider registration; the `--scope user` form below
needs nothing.

A later release is unpacked beside this directory rather than over it, and this
one is removed only at the end of
[Upgrade to a new release](#upgrade-to-a-new-release).

### First run

```console
kanban --version
kanban --path /path/to/project
```

Run inside a local GitHub checkout, `kanban` on its own opens that repository.
Kanban reads the repository's GitHub remote and uses your existing GitHub CLI
login.

The keys that matter first:

| Key | Action |
| --- | --- |
| `j` / `k` | Move between cards |
| `h` / `l` | Move between columns |
| `Enter` | Open card details |
| `s` | Search a column by number and title |
| `F` | Filter which cards the board shows, including closed history |
| `u` | Refresh the board and usage information |
| `p` | Show running and completed jobs |
| `i` | Show everything needing attention, and go to it |
| `?` | Show all controls |
| `q` / `Ctrl-C` | Quit |

Mouse selection, scrolling, and details are also supported. The
[user guide](docs/user-guide.md) documents every key, including the ones that
start the optional AI actions.

### Install from a source checkout

Contributors, and anyone who wants the latest source rather than a released
archive, install from a clone instead:

```console
git clone https://github.com/coghex/kanban.git
cd kanban
cabal update
cabal build all
cabal install exe:kanban
```

Inside a checkout, `cabal run kanban` and `cabal run kanban -- --path
/path/to/project` are the equivalents of the installed commands, and run the
code on the current branch.

## Platform and component support

Kanban does not declare one supported platform. Support is recorded per
component in the table below, and each row's note names the verification its
verdicts rest on, so a cell can be checked rather than taken on trust.

The macOS column rests on use rather than automation: there is no macOS CI job,
and a `Supported` verdict there records that the component is run on the
maintainer's own macOS host. The Linux column carries two kinds of evidence and
each row names which of them it has: what CI exercises — the `ubuntu-latest`
build and test jobs, and a job that boots real systemd in a container — and
what is written down but has never been run. No Linux hardware is committed to
this project, so nothing in this section claims verification on a Linux host.

| Component | macOS | Linux | Notes |
| --- | --- | --- | --- |
| Core board | Supported | Built and tested in CI, not a supported user path | The required `build-test` check aggregates the `haskell` and `python` jobs, both on `ubuntu-latest`: `haskell` runs the warning-clean build — `cabal.project` applies `-Werror` — and the whole Haskell suite, the golden Brick frames included, while `python` runs the tool suite. No interactive board session on a Linux host has been manually verified. |
| Optional AI actions | Supported | Setup documented, not verified end to end | [Workflow setup and preflight](docs/workflow-setup.md) documents the setup path for both platforms: the components, the discovery record, removal, and the logs each name their Linux location beside their macOS one. What is not recorded anywhere is a live Linux run — no end-to-end installation followed by an AI action on Linux has been performed. |
| Codex / Claude usage sidebar | Supported | Not verified | Kanban spawns the provider's own CLI and applies no platform check of its own. The Claude probe composes the util-linux `script` form on every non-darwin host, and the suite asserts the composed operands for both that dialect and the BSD one. No live usage refresh on Linux has been recorded. |
| PR drainer | Supported | Supported on a host with a systemd user session | The drainer is managed by whichever service manager the host has — launchd on macOS, a systemd user unit on Linux — and refuses only where neither is reachable. A dedicated CI job runs the whole install, start, status, stop, and uninstall lifecycle against a real systemd user session. Its install record, runtime state, and logs take each platform's own convention: `~/Library` on macOS, and `$XDG_DATA_HOME` and `$XDG_STATE_HOME` (`~/.local/share` and `~/.local/state` by default) on Linux, where an installation predating that is relocated once by the next default installer run. The board resolves that record the same way the Python side does — `src/Kanban/ManagedPaths.hs` probes the XDG location and then `~/Library` on both platforms — so an XDG-installed drainer is discovered from the board too. |
| Issue approval service | Supported | Supported on a host with a systemd user session | Managed through the same service-manager boundary as the drainer, so installing and controlling it needs launchd or a reachable `systemctl --user`, and refuses only where neither is. Its unit location is XDG-aware, but — unlike the drainer's — its record, runtime state, and logs stay under macOS-shaped `~/Library` paths on both platforms. Interactive operation on Linux has not been manually verified. |

Only the core board row is needed to use Kanban. Every other row is an optional
feature you can leave uninstalled.

### Component lifecycle

Every row above has a named place for each of the four things you can do to it.
The optional-AI-actions row is four separately installed components, so it is
listed here as four.

Two rows install nothing of their own. The core board *is* the executable, and
the usage sidebar is part of that same executable — it has no installer, no
registration, and no removal step, and it appears once the provider CLI it
reads is installed and signed in. Both are installed, upgraded, and removed
through the executable's own lifecycle.

| Component | Install | Upgrade or repair | Verify | Remove |
| --- | --- | --- | --- | --- |
| Core board | [Install from a release archive](#install-from-a-release-archive) | [Step 2](#2-install-the-new-executable) | [Step 7](#7-verify-every-component) — `kanban --version`, then open a repository | [Removing the executable](#removing-the-executable) |
| Codex / Claude usage sidebar | Part of the executable | With the executable, [step 2](#2-install-the-new-executable) | [Step 7](#7-verify-every-component) — `kanban --usage --fresh` | With the executable |
| Optional AI actions: `issue-review` | [Optional AI actions](#optional-ai-actions) | [Step 6](#6-re-run-each-installed-components-setup-from-the-new-archive) | [Step 7](#7-verify-every-component) — `kanban --doctor` | [Workflow-setup removal](docs/workflow-setup.md#removal) |
| Optional AI actions: `legacy-launcher` | [Components](docs/workflow-setup.md#components) | [Step 6](#6-re-run-each-installed-components-setup-from-the-new-archive) | [Step 9](#9-confirm-nothing-still-resolves-through-the-old-archive) — nothing in Kanban resolves it, so no readiness check reports it | [Workflow-setup removal](docs/workflow-setup.md#removal) |
| Optional AI actions: `codex-plugin` | [Optional AI actions](#optional-ai-actions) | [Step 5](#5-move-a-provider-registration-off-the-old-archive) then [step 6](#6-re-run-each-installed-components-setup-from-the-new-archive) | [Step 7](#7-verify-every-component) — `kanban --doctor` | [Workflow-setup removal](docs/workflow-setup.md#removal) |
| Optional AI actions: `claude-plugin` | [Optional AI actions](#optional-ai-actions) | [Step 5](#5-move-a-provider-registration-off-the-old-archive) then [step 6](#6-re-run-each-installed-components-setup-from-the-new-archive) | [Step 7](#7-verify-every-component) — `kanban --doctor` | [Workflow-setup removal](docs/workflow-setup.md#removal) |
| PR drainer | [Optional PR drainer](#optional-pr-drainer) | [Step 6](#6-re-run-each-installed-components-setup-from-the-new-archive) | [Step 7](#7-verify-every-component) — its controller's `status` | [Removing the drainer](docs/pr-drainer.md#removing-the-drainer) |
| Issue approval service | [Optional issue approval service](#optional-issue-approval-service) | [Step 6](#6-re-run-each-installed-components-setup-from-the-new-archive) | [Step 7](#7-verify-every-component) — its controller's `status` | [Uninstalling](docs/issue-approval.md#uninstalling) |

## Optional AI actions

Kanban can start a solve, a review, or a revision on the selected card. Having
Codex or Claude installed and signed in is necessary but not sufficient: the
canonical issue-review backend and the Kanban-owned
`solve`/`pr-review`/`pr-rereview`/`pr-revise`/`repair` workflow bundles have to
be installed once as well.

One opt-in command covers all of them, and reports exactly what it would do
before changing anything. Run it from the extracted release directory or a
source checkout:

```console
python3 tools/setup_workflows.py --all --scope user
python3 tools/setup_workflows.py --all --scope user --apply
```

To see whether an AI action is ready, and what to run if it is not:

```console
kanban --doctor
```

`--doctor` is a read-only report on AI-action readiness: it installs nothing,
starts nothing, and changes nothing. It exits nonzero when an action is
blocked, which is a statement about that optional action only — the board runs
either way.

See [workflow setup and preflight](docs/workflow-setup.md) for the components,
scopes, recovery steps, and removal, and
[the agent-workflow contract](docs/agent-workflow-contract.md) for the full
dependency list and what each action requires.

## Optional PR drainer

The PR drainer merges approved pull requests after their required checks pass.
It installs as a launchd job on macOS and as a systemd user unit on Linux, and
refuses only on a host managed by neither. Preview the installation before
enabling it:

```console
python3 tools/install_drainer.py --repo /path/to/project --dry-run --json
python3 tools/install_drainer.py --repo /path/to/project
```

`--repo` names the checkout to drain. It defaults to the directory the script
lives in, which is right in a source checkout and impossible in an unpacked
release — an archive is not a repository — so the archive form names it and the
installer refuses rather than guessing. The tracked modules it links still come
from the archive, through `--asset-root`, which already defaults to it.

Installation does not start the drainer. Press `d` in Kanban when you are ready
to run it.

## Optional issue approval service

The issue approval service reviews one repository's open issues in ascending
number order, and stops at the first issue whose review requested changes. It
installs the same way, through its own installer and its own job:

```console
python3 tools/install_issue_approval.py --repo /path/to/project --dry-run --json
python3 tools/install_issue_approval.py --repo /path/to/project
```

`--repo` and `--asset-root` mean here exactly what they mean for the PR drainer
above, and for the same reason.

Installation starts nothing. Press `a` in Kanban when you are ready to run it —
and mean it: a running service publishes real review verdicts and moves real
labels. It needs the canonical issue-review backend from
[optional AI actions](#optional-ai-actions) above, which it resolves rather than
installs. See [the issue approval guide](docs/issue-approval.md).

## Upgrade to a new release

An installed Kanban is two things: the executable, and whichever optional
components you installed *from the extracted release directory*. Upgrading the
first is one command. The second is what this section is for — every optional
component is installed as links and provider registrations pointing into the
directory you unpacked, so a new release is not actually in use until each one
has been re-pointed at the new directory.

The order below is not a preference. Each step sits where it does because a
later one refuses, or silently keeps running the old code, when it is taken out
of turn; [why the order is required](#why-the-order-is-required) says which.

Nothing here happens by itself. Kanban does not update itself, does not stop or
start a service for you, does not move a provider registration on your behalf,
and does not delete the old archive. Skip any step for a component you never
installed: this procedure repairs what you already have, and installs nothing
new.

### 1. Unpack the new archive beside the old one

From a *new* empty directory — not the one holding the release you are running
now, which stays exactly where it is until step 10:

```console
gh release download --repo coghex/kanban --pattern 'kanban-*.tar.gz'
tar -xzf kanban-*.tar.gz
cd kanban-*/
```

Every command from here on is run from this new directory unless it says
otherwise. Note its absolute path and the old one; the two are told apart by
path alone throughout.

### 2. Install the new executable

```console
cabal update
cabal install exe:kanban
```

`cabal install` writes `kanban` into Cabal's user binary directory — normally
`~/.local/bin` — which is where the first install put it too, so the new build
takes the old one's place at that same path. If Cabal declines because
something is already there, re-run it as
`cabal install exe:kanban --overwrite-policy=always`: replacing that binary is
exactly what this step is for.

Confirm that the `kanban` your shell resolves is the one you just built, not
another copy earlier on `PATH`:

```console
command -v kanban
kanban --version
```

The `-Werror` note under [Install from a release
archive](#install-from-a-release-archive) applies to this build too.

### 3. Inventory what is installed

Do this **before** stopping anything. After step 4 you can no longer tell which
jobs were running, and step 8 restores exactly that.

For the AI-action components, start with the `issue-review` install directory,
which steps 6 and 9 both need. This resolves it exactly as everything that
consults the backend does — a non-empty `KANBAN_ISSUE_REVIEW_INSTALL_DIR`
first, then the record's `backend_path`, then the record's own directory when
it carries none — and the record's own path is fixed, which is what makes an
installation made anywhere findable:

```console
INSTALL="$(python3 - <<'LOCATE'
import json, os
from pathlib import Path

override = os.environ.get("KANBAN_ISSUE_REVIEW_INSTALL_DIR", "").strip()
if override:
    print(Path(override).expanduser())
else:
    data = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
    for record in (
        Path(data) / "kanban" / "issue-review" / "config.json",
        Path.home() / "Library" / "Application Support" / "kanban" / "issue-review" / "config.json",
    ):
        if record.exists():
            recorded = json.loads(record.read_text()).get("backend_path")
            print(Path(recorded).parent if recorded else record.parent)
            break
LOCATE
)"
echo "$INSTALL"
```

An empty answer means you have no `issue-review` backend, and steps 6 and 9
skip it. Otherwise list it, along with the launcher and both providers:

```console
ls -l "$INSTALL"
ls -l ~/work/approve-issues.py
codex plugin marketplace list
codex plugin list
claude plugin marketplace list
claude plugin list
```

This is only about which components you have; step 9 is where the links are
followed to what they finally resolve to.

What decides whether you *had* a provider component is the `plugin list`, not
the `marketplace list`. Removing a plugin leaves its marketplace registered —
that is why step 5 is two commands — so a `kanban` marketplace with no
`kanban@kanban` beside it is a leftover, and selecting that component in step 6
would install one you never had. The marketplace listing answers the other
question: which asset root the registration names, and so whether step 5 has to
move it at all.

Record each provider's **scope** as well as its presence. Codex has only
user scope. A Claude registration made with the default `--scope project` lives
in one repository's own `.claude/settings.json` and is visible only from that
repository, so run the two `claude` commands from there — and note which
repository it was, because step 6 needs it as `--target`. See [asset root and
target](docs/workflow-setup.md#asset-root-and-target).

For the two services, the discovery record is the only place that enumerates
every repository they are installed for: both controllers are single-repository
commands taking `--path`, and neither installer offers a listing mode. Read the
PR drainer's from [Files and logs](docs/pr-drainer.md#files-and-logs) and the
issue approval service's from [Files and
logs](docs/issue-approval.md#files-and-logs); each record's `repositories`
table holds one entry per installed job, carrying that job's identifier, its
service definition, the checkout it drains or reviews, and any `config.toml` it
was given. Those are the values step 6 has to supply again.

One value is not in there. The issue approval service records the install
directory its links went to, so a rerun finds it; the PR drainer's record does
not, and its installer takes a custom destination from `--install-dir` alone —
never from `KANBAN_DRAINER_INSTALL_DIR`, which tells an already-installed
component where it lives rather than where to write. A drainer installed with
`--install-dir` is therefore one you have to remember and name again in step 6.

Then ask each installed job whether it is running, through the *installed*
controller rather than the archive's copy. [Manual
status](docs/pr-drainer.md#manual-status) and [From the
controller](docs/issue-approval.md#from-the-controller) resolve that controller
the same way the installation itself does.

The two services have two different controllers, and both of those snippets
leave their answer in the same `$CONTROL`. Run one snippet, copy its result
into a name of its own, and only then run the other — otherwise the second
silently replaces the first and every later command drives the wrong service.
Take only the lines for services you have:

```console
DRAINER_CONTROL="$CONTROL"    # right after the PR drainer's snippet
python3 "$DRAINER_CONTROL" --path /path/to/project --json status

APPROVAL_CONTROL="$CONTROL"   # right after the issue approval service's snippet
python3 "$APPROVAL_CONTROL" --path /path/to/project --json status
```

Steps 4, 7, and 8 use those two names, and step 7 resolves both again because
step 6 can move an installation as well as re-point it.

Write down which jobs report a live state. That list is the whole of what step
8 restarts.

### 4. Stop every running service job

Stop every PR-drainer and issue-approval job that step 3 found running — every
repository's, not only the one you are upgrading from. Both installers refuse
while their job is live, and the PR drainer additionally refuses to relocate
its shared links while *any* recorded repository's drainer is running.

Press `d` and `a` in Kanban for the repository each job is for, or drive that
service's own controller directly — one line per job you are stopping:

```console
python3 "$DRAINER_CONTROL" --path /path/to/project --json stop
python3 "$APPROVAL_CONTROL" --path /path/to/project --json stop
```

A job that step 3 found already stopped is left alone. Stopping has its own
documented effects — a drainer stop clears that repository's crash incidents,
while a merge-conflict or cleanup incident stays open for `ack` — and those are
normal, not upgrade damage.

### 5. Move a provider registration off the old archive

Only for a provider whose `kanban` marketplace step 3 showed registered from
the old archive. Setup refuses a marketplace registered from any source other
than the asset root it was given, and an unpacked archive carries no marker
that would let one release be recognized as the successor of another — so the
old registration has to go before the new one can be added.

Remove the plugin first and the marketplace second, which is the order
[Removal](docs/workflow-setup.md#removal) documents:

```console
codex plugin remove kanban@kanban
codex plugin marketplace remove kanban
claude plugin uninstall kanban@kanban
claude plugin marketplace remove kanban
```

Run the `claude` pair from the repository the registration was declared in when
it was project-scoped. Do only the provider you actually had: removing a plugin
you never installed is not part of this upgrade.

### 6. Re-run each installed component's setup from the new archive

From the new directory, and only for the components step 3 found. Each rerun is
convergent: it re-points what the old archive left and reports `unchanged` for
anything already correct. Preview first — a run without `--apply`, or with
`--dry-run`, writes nothing at all.

The AI-action components, named individually so nothing you did not have gets
installed:

```console
python3 tools/setup_workflows.py --component issue-review --install-dir "$INSTALL"
python3 tools/setup_workflows.py --component issue-review --install-dir "$INSTALL" --apply
```

`$INSTALL` is step 3's value. Naming it is right either way — for a default
install it is the default, and for an `--install-dir` install nothing else
recovers it, since the record's own location does not move with the links.

Add `--component legacy-launcher` to that same run when you had one: setup
refuses the launcher unless the backend is present or selected beside it.

Each provider component takes its own run, because `--scope` is one option for
the whole invocation and each registration has to stay in the scope step 3
found it in. Codex has only user scope:

```console
python3 tools/setup_workflows.py --component codex-plugin --scope user --apply
```

Claude has both, and they are two different commands. Take the one matching
what step 3 recorded, and spell `--scope` out either way — letting it default
here means project scope, which would migrate a user-scoped registration rather
than repair it:

```console
# step 3 found it in project scope
python3 tools/setup_workflows.py --component claude-plugin --scope project --target /path/to/repo --apply
# step 3 found it in user scope
python3 tools/setup_workflows.py --component claude-plugin --scope user --apply
```

Do not reach for `--all` in this step. It selects all four components whatever
you have, so it installs the ones you do not, and one run cannot carry two
scopes anyway. Naming each component step 3 found is what keeps this a repair.

From an archive there is no default target, so a project-scoped run without
`--target` refuses rather than declaring project state inside a directory step
10 tells you to delete. [Upgrading to a new release
archive](docs/workflow-setup.md#upgrading-to-a-new-release-archive) walks the
four components one at a time.

`--repo` needs no value in any of these: it defaults to the tree the script
lives in, which is the new archive, and it is validated by the files the
selected components are installed from rather than by Git metadata.

Then the services you have, once per repository that service's record named,
passing back that entry's checkout and any custom install directory or
`config.toml`. Run only the pair for a service you actually installed:

```console
python3 tools/install_drainer.py --repo /path/to/project --dry-run --json
python3 tools/install_drainer.py --repo /path/to/project
python3 tools/install_issue_approval.py --repo /path/to/project --dry-run --json
python3 tools/install_issue_approval.py --repo /path/to/project
```

The issue approval service's links go back where its record says they were, so
add `--install-dir` only to move them; the PR drainer's do not, so name it
again there when step 3 said you had one.

`--repo` is the checkout the service acts on; `--asset-root` is where its links
are read from and already defaults to the new archive. They are two different
trees after a release, which is why the archive form names the first — see [the
two roots](docs/pr-drainer.md#the-two-roots). Neither installer starts anything.

Both re-point the links a previous archive left, including while that archive
is still on disk: each link is recognized as Kanban's own by the identity
marker the tracked file at the end of it carries. A link to anything else, and
an ordinary file in the way, are left untouched and reported instead.

### 7. Verify every component

**Resolve both controllers again first.** A default PR-drainer reinstall on a
Linux host whose installation predates the XDG locations relocates it there and
removes the old one, so the controller path step 3 captured can be gone — and a
controller still pointing at a moved installation refuses rather than answers.
Re-run [Manual status](docs/pr-drainer.md#manual-status) and [From the
controller](docs/issue-approval.md#from-the-controller), copying each result
into `DRAINER_CONTROL` and `APPROVAL_CONTROL` as step 3 did.

Verify each row of [the support table](#platform-and-component-support)
with the check that can actually observe it. `kanban --doctor` is **not** that
check for most of them: it is a read-only report on AI-action readiness alone,
and says nothing about the board, the usage sidebar, the PR drainer, or the
issue approval service.

| Component | Check | What it proves |
| --- | --- | --- |
| Core board | `kanban --version`, then `kanban --path /path/to/project` | The executable on `PATH` is the new build, and it opens the selected repository. |
| Optional AI actions | `python3 tools/setup_workflows.py` from the new directory with step 6's selection and scope and no `--apply`, then `kanban --doctor` | Setup has converged against the new archive — every component you have reports `unchanged` — and readiness is reported per AI action. |
| Codex / Claude usage sidebar | `kanban --usage --fresh` | Every provider you have answered *now* — one that is not installed reports itself as unavailable rather than being left out, and the command succeeds as long as one answered. A plain `kanban --usage` prints whatever is already cached and only asks a provider that has nothing cached, so it can report a window the previous executable stored. Add `--json` for the machine-readable form. |
| PR drainer | `python3 "$DRAINER_CONTROL" --path /path/to/project --json status` | That repository's job is installed and in the state you expect — the one step 3 recorded, until step 8. |
| Issue approval service | `python3 "$APPROVAL_CONTROL" --path /path/to/project --json status` | The same, for that repository's approval job. |

Run the two `status` checks for every repository the records named, not only
the one you happened to be in.

### 8. Restart only what was running

Start again exactly the jobs step 3 found live, and no others. Press `d` or `a`
in Kanban for each, or use the controllers step 7 resolved — the drainer's for a
drainer, the approval service's for an approval job, one line per job you are
restarting:

```console
python3 "$DRAINER_CONTROL" --path /path/to/project --json start
python3 "$APPROVAL_CONTROL" --path /path/to/project --json start
```

Installation is deliberately non-starting, so a job you did not restart is
still stopped — confirm that with `status` rather than assuming it. A job that
was stopped before the upgrade must still be stopped after it; starting the
issue approval service begins publishing real review verdicts and moving real
labels.

### 9. Confirm nothing still resolves through the old archive

This is a question about where an installed link *finally* resolves, and no
`status` command answers it: the drainer's reports the installed link's path,
never that link's target.

Read the whole chain rather than one hop of it. Several of these paths name a
stable installed location on purpose and go on doing so after a correct
upgrade: the `issue-review` record's `backend_path` names the link setup
installed rather than any archive, and `~/work/approve-issues.py` points at
that same link rather than at an archive. A link landing on another
Kanban-installed link is healthy — what has to be inside the new directory is
where the chain *ends*.

There are one or more install directories to feed it, and they are the ones
step 3 already located:

- The `issue-review` install directory, which step 3 put in `INSTALL`. It holds
  `approve_issues.py`, `kanban_config.py`, and `kanban_models.py`.
- Each service's own install directory —
  [the drainer's](docs/pr-drainer.md#files-and-logs) and [the approval
  service's](docs/issue-approval.md#files-and-logs) file inventories resolve
  it — holding that service's script links. Read each record's entry for every
  repository while you are there.

`INSTALL` is always one of those directories, never a file path. Run this once
with the value step 3 set, then again with `INSTALL` reset to each service
install directory in turn:

```console
python3 - "$INSTALL"/*.py <<'RESOLVE'
import os, sys

for path in sys.argv[1:]:
    print(f"{path} -> {os.path.realpath(path)}")
RESOLVE
```

**Only if step 3 found a `legacy-launcher`**, add `~/work/approve-issues.py` as
one more argument to any of those runs. Without one that path does not exist,
and naming it reports a target outside the new directory that means nothing.

Every resolved target must be inside the new extracted directory. The paths you
started from are expected to be unchanged; that they do not move is the point
of them.

The provider marketplaces are the one observable that names an archive
directly:

```console
codex plugin marketplace list
claude plugin marketplace list
```

Run the `claude` one from the repository a project-scoped registration was
declared in. What each answer means depends on whether step 3 found a plugin
behind that marketplace:

- **Plugin installed.** The registered source has to be the new directory. One
  still naming the old archive means step 5 or step 6 was skipped for that
  provider; go back and do it.
- **No `kanban` marketplace listed at all**, including because the provider CLI
  is not installed and the command fails. You did not have that provider and
  step 6 did not add one; there is nothing to check.
- **Marketplace with no `kanban@kanban` behind it.** This is the leftover step 3
  identified, and it will still name the old archive. Reinstalling the plugin is
  not the fix — you never had it. Remove the registration instead, which is the
  half of the removal that was never done:

  ```console
  codex plugin marketplace remove kanban
  claude plugin marketplace remove kanban
  ```

  Take only the line for a provider that actually has one. Nothing Kanban runs
  resolves a marketplace with no plugin behind it, so removing it changes no
  behavior — but a later setup run *would* refuse against it as a source
  mismatch, and step 10 would otherwise leave it naming a directory that no
  longer exists.

Codex additionally keeps its own *copy* of the bundle rather than a link. When
step 3 found that plugin, re-run
`python3 tools/setup_workflows.py --component codex-plugin --scope user` from
the new directory: a cached copy that has fallen behind reports `repair`, and
`unchanged` is the answer that clears this step.

If a chain still ends in the old directory, go back to step 6 for that
component; it is not fixed by deleting the archive it points at.

### 10. Remove the old archive

Only once every check above has passed. Then it is an ordinary directory
removal.

The new extracted directory inherits the obligation the old one had: **keep
it.** It is where every optional component you just re-pointed now reads its
tracked assets from, and the next upgrade is what releases it — not the end of
this one.

### Why the order is required

- **The old archive is removed last** because the installed components resolve
  *into* it. Deleting it first breaks every script link that has not been
  re-pointed yet and every marketplace still registered from it, which turns a
  convergent rerun into a repair of two problems.
- **Inventory precedes stopping** because a stopped job does not record that it
  used to be running. Step 3's list is the only source step 8 has.
- **Services stop before their installers run** because both installers refuse
  while their job is live: a service manager asked to replace a definition
  under a running job leaves a controller nothing can see or stop. The PR
  drainer widens that to any recorded repository's drainer when the shared
  links have to move.
- **Provider registrations move before setup runs** because setup refuses a
  `kanban` marketplace registered from a source other than the asset root it
  was given, and it never silently replaces one. The old archive is exactly
  such a source.
- **Component repair precedes verification** because until it has run, the
  links and the Codex cached bundle still resolve to the old release: the
  executable is new and everything it starts is old, which is the failure this
  procedure exists to prevent.
- **Verification precedes removal** because those checks are what license the
  removal. A component still pointing into the old directory is repairable
  while that directory exists and stranded once it does not.

### What survives the upgrade

Supported configuration and durable state are preserved. That is not the same
as nothing being touched: the installers deliberately rewrite the artifacts
that name where things live, and that is repair, not loss.

**Kept, and not rewritten:**

- Kanban's own configuration and display settings, its board and usage caches,
  its agent logs, and its background job records — the files
  [Local files](docs/user-guide.md#local-files) lists.
- Each service's durable state, according to that service's existing contract:
  the PR drainer's and issue approval service's runtime state, logs, open
  incidents, repository identities, and per-repository `config.toml`
  selections. Both keep runtime state, logs, and incidents even across a
  deliberate *uninstall*, so an upgrade certainly does not clear them. A custom
  install location survives on each service's own terms: the issue approval
  service records the directory and a rerun goes back to it, while the PR
  drainer's has to be named again, which is what step 3 has you write down.
- Your provider credentials and supported provider configuration. Setup signs
  you in to nothing, reads and stores no credential, and changes no model,
  reasoning-effort, sandbox, or approval default — see [security and
  authority](docs/workflow-setup.md#security-and-authority).

**Rewritten on purpose, and expected:**

- The shared script links, re-pointed from the old archive to the new one.
- Each service definition, rewritten and reloaded against the new links.
- Each discovery-record entry, re-recording the backend that wrote it and the
  paths it named.
- Codex's cached copy of the `kanban` bundle, which is replaced rather than
  updated in place because its CLI has no update command for a local-source
  marketplace.

**Also expected:** the documented effects of deliberately stopping a service in
step 4 — a drainer stop clearing that repository's crash incidents, for one.

This procedure deletes no private state and promises no migration of files
outside the supported set above. Anything you put in the old extracted
directory yourself is yours to move before step 10.

## Removal

Each optional component is removed by its own documented path, and none of them
removes another:

- **Optional AI actions** — [Removal](docs/workflow-setup.md#removal) covers all
  four components: the provider commands for the two bundles, and the
  Kanban-namespaced directories for `issue-review` and `legacy-launcher`.
  Uninstall the issue approval service first if you have one, since removing
  the `issue-review` backend leaves it with no reviewer to run.
- **PR drainer** — [Removing the drainer](docs/pr-drainer.md#removing-the-drainer),
  per repository.
- **Issue approval service** —
  [Uninstalling](docs/issue-approval.md#uninstalling), per repository.

### Removing the executable

The board and the usage sidebar are the same executable, so removing it removes
both. There is no uninstaller: delete the binary `cabal install` wrote — `command
-v kanban` prints its path — and, if you want the state gone too, the files
[Local files](docs/user-guide.md#local-files) lists. Remove the optional
components above first; each keeps its own state under its own namespace, and
none of it is reached by deleting the executable.

Then remove the extracted release directory, which nothing needs once no
component points into it.

## Documentation

Start here:

- [User guide](docs/user-guide.md) — board layout, every control, reviews, and
  background jobs.
- [Workflow setup and preflight](docs/workflow-setup.md) — installing the
  optional AI-action components, and diagnosing why one is not ready.
- [PR drainer](docs/pr-drainer.md) — installation, configuration, operation,
  and logs.
- [Issue approval service](docs/issue-approval.md) — installing, operating, and
  recovering the persistent per-repository issue reviewer.
- [Support](SUPPORT.md) — what is supported, what to expect, and which of the
  three reporting routes a bug, a vulnerability, and a conduct concern take.
- [Code of conduct](CODE_OF_CONDUCT.md) — the standard for behavior in this
  project's spaces, and how a concern is reported privately.

For contributors:

- [Development](docs/development.md) — source layout, build commands, and tests.
- [Design and implementation notes](docs/design.md) — the behavior contract and
  the engineering decisions behind it.
- [Agent-workflow contract](docs/agent-workflow-contract.md) — every external
  workflow Kanban's AI actions depend on, and who owns each one.
- [Claude Code session instructions](CLAUDE.md) — the session contract for
  agents working in this repository.
- [Documentation index](docs/README.md) — everything else.

## Tests

From a source checkout or the extracted release directory:

```console
cabal build all
cabal test all --test-show-details=direct
python3 -m unittest discover -s tools -p 'test_*.py'
```

`cabal.project` applies the mandatory `-Werror` gate to those runs.

## License

[MIT](LICENSE)
