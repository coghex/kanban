# Workflow setup and preflight

Kanban's board is fully usable with nothing installed beyond `git` and a
signed-in `gh`. Its optional AI actions — canonical issue review and
revision (`r`), solve (`S`), auto-solve (`A`), and the PR review, rereview,
revise, and repair flows (`r` on a pull request) — additionally need workflow
assets this repository tracks but does not install for you. Each is its own
preflight action with its own dependency set, so `--doctor` reports repair
separately, per pull-request origin.

Two commands cover that whole surface:

- `python3 tools/setup_workflows.py` installs the components you select.
- `cabal run kanban -- --doctor` reports, read-only, why an action is not
  ready yet.

This is not a macOS-only procedure. Every location named below under
`~/Library` gives its Linux counterpart beside it, and the commands are the
same on both. What has not been done is a live Linux run: no end-to-end
installation followed by an AI action on a Linux host is recorded anywhere, so
the Linux paths here are documented rather than exercised.

## Fresh clone

From a fresh clone, inspect the plan first — this is the default, and it
writes nothing at all:

```console
git clone https://github.com/coghex/kanban.git
cd kanban
cabal build all
python3 tools/setup_workflows.py --all --scope user
```

The output names each component, its current state, and the exact command
setup would run. When it looks right, perform that same plan:

```console
python3 tools/setup_workflows.py --all --scope user --apply
```

Then confirm what the board can actually do:

```console
cabal run kanban -- --doctor
```

Nothing above copies a personal skill, command, or script by hand, and
nothing starts the PR drainer, the issue approval service, an approval daemon,
or an agent session.

## Components

Select components explicitly with `--component` (repeatable) or take all
four with `--all`.

| Component | What it installs | Needed for |
| --- | --- | --- |
| `issue-review` | A Kanban-managed link to the tracked `tools/approve_issues.py` backend (and its `kanban_config.py` and `kanban_models.py` companions) under `~/Library/Application Support/kanban/issue-review/` on macOS or `$XDG_DATA_HOME/kanban/issue-review/` — `~/.local/share/kanban/issue-review/` when that variable is unset — on Linux, plus the discovery record naming that link | Every AI action except issue revision: canonical issue review/rereview (`r`), the readiness gate a solve session checks before claiming an issue, and the gate the PR coordinator checks before publishing a verdict |
| `codex-plugin` | `kanban@kanban` from `codex-plugin/`, through `codex plugin marketplace add` and `codex plugin add` | `$solve`, `$pr-review`, `$pr-rereview`, `$pr-revise`, `$repair` |
| `claude-plugin` | `kanban@kanban` from `claude-plugin/`, through `claude plugin marketplace add` and `claude plugin install` | `/solve`, `/pr-review`, `/pr-rereview`, `/pr-revise`, `/repair` |
| `legacy-launcher` | A symlink at `~/work/approve-issues.py` pointing at the installed backend | Nothing in Kanban. Purely a compatibility shim for pre-migration automation that still invokes that path directly — see [agent-workflow-contract §3](agent-workflow-contract.md#3-migration-boundary) |

There is deliberately no component here for the optional issue approval
service, which reviews a repository's open issues in ascending order as a
managed background job. It has its own installer and its own per-repository
job — `python3 tools/install_issue_approval.py`, described in
[the issue approval guide](issue-approval.md) — and it *resolves* the
`issue-review` backend below rather than installing one, so setup remains the
command that installs shared components and starts no service.

A plugin component alone is not enough for the PR flows: they call the
`issue-review` backend too, so install it as well (`--all` covers this).
`legacy-launcher` depends on it outright — it is a symlink *to* that
installed backend, so setup refuses it until the backend is present or
selected in the same run.

`issue-review` and `legacy-launcher` install into a per-user location by
design, and there is no project-scoped alternative. Both follow the same
never-replace-an-ordinary-file policy as the PR-drainer installer.

Nothing that consults the backend reconstructs that location. Installing
writes the linked backend's absolute path into
`~/Library/Application Support/kanban/issue-review/config.json` on macOS, or
`$XDG_DATA_HOME/kanban/issue-review/config.json` —
`~/.local/share/kanban/issue-review/config.json` when that variable is unset —
on Linux; an installation that already exists under either convention keeps
its own record rather than moving. That document's own path `--install-dir`
cannot move, and
`src/Kanban/Review/Canonical.hs`, `src/Kanban/Preflight.hs`, both packaged
`review_pr.py` coordinators, and the packaged `issue-review` and `solve`
workflows all read it, with the same precedence: a non-empty
`KANBAN_ISSUE_REVIEW_INSTALL_DIR` first, then the
recorded path, then — only when the record carries no `backend_path`, which
is how an installation predating the record reads — the directory the record
lives in. So an install made with `--install-dir` is found by a dashboard
launched with no special environment, an older installation keeps working
until you next re-run setup, and the environment override still wins for
anyone already relying on it. Re-running setup or
`tools/install_issue_review.py` repairs a missing or stale record in place,
with no uninstall first; a dry run reports what it would record and writes
nothing. See
[agent-workflow-contract §5](agent-workflow-contract.md#5-portable-install-policy),
which documents the PR drainer's identical record.

## Scopes

`--scope` controls where a *provider* registration is declared. Project
scope is the default; a user-global registration is never chosen for you.

- **`--scope project`** (default) declares the Claude Code plugin in the
  target repository's own `.claude/settings.json`, so it is available to
  sessions started from that repository. Use `--target /path/to/repo` when
  that repository is not the Kanban checkout itself; it defaults to
  `--repo` while `--repo` is a main checkout, and there is no default at all
  when it is not — see [Asset root and target](#asset-root-and-target) below.
- **`--scope user`** declares the registration once for every session.

Codex has no project-scoped install: `codex plugin` registers marketplaces
and plugins in your own `$CODEX_HOME/config.toml`. Setup therefore refuses
`--component codex-plugin` under the default project scope and tells you to
re-run with `--scope user`, so a user-global change is always an explicit
choice.

## Asset root and target

`--repo` and `--target` name two different trees, and after a release they are
usually two different trees.

- **`--repo`** is where the tracked assets are read from: the backend modules
  the issue-review component links, and the provider bundles the marketplace
  entries point at. It is validated by the files the components you selected
  are installed *from*, never by Git metadata, so the unpacked release archive
  — which carries none — works exactly as a checkout does. Nothing is ever
  registered or written inside it.
- **`--target`** is the repository a project-scoped registration is declared
  in. It is required to be that repository's own main checkout with a
  supported GitHub remote, and a `--target` that is neither is refused before
  any provider is probed.

`--target` defaults to `--repo` when `--repo` is itself a main checkout, which
is every source-checkout run and keeps those unchanged. From an unpacked
archive there is no such default, and a project-scoped provider component
refuses and names `--target`, rather than declaring project state inside a
directory a later upgrade tells you to delete. `--scope user` needs no target
at all.

Provider commands run in the target when there is one, and in the asset root
otherwise. Both providers follow that one rule, so what a plan probed and what
an `--apply` performs are read from the same place.

## Dry run, convergence, and refusal

- **Dry run is the default.** Without `--apply`, every component is
  inspected and its planned action printed, and no filesystem, provider
  configuration, LaunchAgent, daemon, or network-side change is made.
  `--dry-run` states that explicitly; it cannot be combined with `--apply`.
- **Re-running converges.** A component that is already correct reports
  `unchanged` and runs no command. "Correct" means content, not merely
  registration — see the stale Codex bundle below.
- **Nothing is silently replaced.** A conflicting state is reported as
  `refused`, left exactly as it was, and paired with the recovery step you
  would take. `setup_workflows.py` exits non-zero whenever any component
  needs your attention. An ordinary fresh-install plan is not "attention":
  it exits 0, and so does a `repair` that `--apply` converged in the same
  run.

### An installed Codex bundle that has fallen behind

Codex installs `kanban@kanban` by *copying* the tracked bundle into its own
cache under
`$CODEX_HOME/plugins/cache/kanban/kanban/<version>` (`~/.codex` when
`CODEX_HOME` is unset), and its CLI has no plugin update command for a
local-source marketplace — `codex plugin` offers `add`, `list`,
`marketplace`, and `remove`, and `codex plugin marketplace upgrade` refreshes
Git snapshots, which this marketplace is not. So a checkout that moves ahead
of that copy leaves every Codex session running the bundle as it was when it
was last added: skills vendored since then simply do not exist there, and
`$pr-review`, `$pr-rereview`, `$pr-revise`, and `$repair` execute whatever
shared coordinator that copy holds, because the tracked skills resolve it by
searching that same cache.

Setup therefore compares the installed bundle against the tracked one rather
than stopping at "registered and enabled":

- The tracked bundle is its **Git-tracked** content under
  `codex-plugin/plugins/kanban`. A file the checkout carries but Git does not
  track was never part of what the provider was asked to install, so it can
  never make an installation look stale — and `__pycache__/` is ignored on
  *both* sides, since running the packaged coordinator leaves one in the
  checkout and in the cache alike.
- A divergence is reported as `repair`, naming the differing bundle-relative
  paths grouped as **missing**, **different**, and **extra**, and exits
  non-zero. Nothing outside Kanban's own installed bundle is read or
  reported. An enabled plugin whose cache is absent entirely is the same
  repairable state.
- An **extra** path may be a directory as well as a file: a skill directory
  left behind or emptied still offers Codex something the tracked bundle does
  not define, so it is named with a trailing slash rather than passed over
  for holding no file.
- `--apply` converges it with the provider's own commands, in the only order
  that refreshes a local-source bundle — `codex plugin remove kanban@kanban`
  then `codex plugin add kanban@kanban` — and never writes into the cache
  itself. It then re-compares: a refresh whose commands succeeded but whose
  result still diverges is reported as `failed`, not as a repair.
- A cache that cannot be read at all — a path that is not a directory, or one
  the current user cannot traverse — is `unavailable`, and no command runs.
  The same is true when the tracked manifest declares no version, since
  nothing then names the cache to compare against.
- A marketplace registered from another checkout, and an installed-but-
  disabled bundle, still refuse first and still run nothing.

The `claude-plugin` component has no equivalent state: its marketplace serves
the tracked bundle live from the repository directory, so there is no cached
copy to fall behind.

## Preflight and in-app diagnostics

`cabal run kanban -- --doctor` prints readiness per dependency and per AI
action, and exits non-zero if any action is blocked. It distinguishes:

- an executable that is absent, or older than the release the tracked
  bundles were verified against;
- a provider that is not authenticated;
- a Kanban workflow bundle that is absent, or installed but disabled;
- a canonical review backend that is not installed;
- a GitHub CLI that is unavailable or not signed in;
- a conflicting local installation that needs you to act — for example an
  ordinary file, a directory, or a link to something that is not Kanban's
  own backend already occupying an install path. Only a symlink resolving
  to a file that carries that asset's identity marker counts as installed,
  because that is the one shape setup creates and the one it will converge
  on a re-run.

Coverage is per action, not per provider, and follows what each action
actually spawns:

- **Canonical review/rereview** needs the backend (all three of its installed
  files — `approve_issues.py` imports `kanban_config.py` and
  `kanban_models.py`), `gh`, and the
  provider the backend itself invokes: the opposite brand from the issue's
  origin marker, or both for an unmarked issue under the dual policy Kanban
  passes. No packaged bundle: the backend runs `codex exec` / `claude -p`
  directly.
- **Revision** runs Kanban's own prompts through `codex app-server`, so it
  needs Codex and `gh` but no bundle. A Claude-origin issue also authors
  its amendment through the Claude CLI, so that revision needs Claude
  installed and signed in too.
- **Solve** needs its own brand's CLI and bundle, `gh`, and the backend for
  its read-only readiness gate. **Auto-solve** reviews its own pull request
  with the opposite brand, so it needs both brands.
- **PR review and rereview** run on the opposite brand from the PR's origin
  marker and are themselves the canonical reviewer, so they need that
  brand's CLI and bundle. **PR revise** and **repair** run on the PR's *own*
  brand — each needs that brand's CLI, sign-in, and bundle — and then hand
  off to exactly one canonical rereview by spawning the opposite brand from
  inside that session, so each also needs that brand's CLI and
  sign-in — but not its bundle, since the nested call is a direct
  `codex exec` / `claude -p`. All four additionally need the
  `issue-review` backend: the bundled coordinator runs its read-only
  `--check` gate against the PR's linked issue before publishing any
  verdict.

Every action above also needs `gh`, signed in — the board's GitHub data and
every write action go through it.

The doctor path is read-only and non-interactive. It resolves executables,
reads `--version`, and asks each provider its own status-only questions
(`codex login status`, `claude auth status`, `gh auth status`, and each
provider's `plugin list --json`). It never starts an agent session,
triggers a login flow, consumes model quota, or writes anything. The PR
drainer is deliberately outside its scope and keeps its dedicated
[install and status flow](pr-drainer.md).

The board runs the same preflight for the specific action you press, so a
missing component is reported as `cannot start` with the command that
installs it, rather than as an opaque agent failure minutes later. A probe
that cannot reach a definite conclusion never blocks an action: a
diagnostic that guessed wrong would break a working setup.

The tracked bundles are the supported source of the `solve`/`pr-review`/
`pr-rereview`/`pr-revise`/`repair` workflows. If you previously relied on your own
unpackaged copies of those commands, preflight will report the bundle as
absent — install it once with `setup_workflows.py`, which neither removes
nor overrides anything else you have.

## Security and authority

Setup uses each provider's own documented installation mechanism and
nothing else. It does not:

- sign you in, read, store, or provision any credential;
- change your model, reasoning-effort, sandbox, or approval defaults, or
  disable any provider safety control;
- copy opaque files into an undocumented global directory;
- install, start, or configure the PR drainer, the issue approval service, an
  approval daemon, or any agent session.

The authority the *actions* need is unchanged and still yours: your
existing `gh auth login` for every GitHub write, and your own provider
sign-in for every model call. See
[agent-workflow-contract §5](agent-workflow-contract.md#5-portable-install-policy)
for the policy this implements.

## Conflicts and recovery

| Reported state | What happened | What to do |
| --- | --- | --- |
| `issue-review: refused` | An ordinary file, or a symlink resolving to a real file that is not Kanban's own tracked backend, occupies an install path | Move or remove it yourself, then re-run. Setup never replaces it. It re-points only a link resolving to this same tracked asset, or one left broken by a checkout that moved or went away — refusal protects content, and a broken link holds none. |
| `legacy-launcher: refused` | An ordinary pre-Kanban file, or a symlink resolving to a real file that is not Kanban's tracked backend, exists at `~/work/approve-issues.py` | For an ordinary file, re-run with `--migrate-legacy-launcher` to back it up as `approve-issues.py.pre-kanban-backup` and replace it with a symlink. A symlink to someone else's file is refused outright even with that flag — there is no content to back up — so remove it yourself if you want the launcher here. Either way, nothing in Kanban resolves this path. |
| `codex-plugin`/`claude-plugin: refused`, marketplace mismatch | A marketplace named `kanban` is already registered from another checkout — including a previous release archive, which carries no marker anything could recognize it by | Remove it (`codex plugin marketplace remove kanban` / `claude plugin marketplace remove kanban`) and re-run, or point `--repo` at that checkout. |
| `claude-plugin: refused`, no project target | `--repo` is not a main checkout, so a project-scoped registration has nowhere to be declared | Pass `--target /path/to/repo`, or choose `--scope user` explicitly. |
| `codex-plugin`/`claude-plugin: refused`, bundle disabled | `kanban@kanban` is installed but disabled | Re-enable it (`claude plugin enable kanban@kanban`), or remove it (`codex plugin remove kanban@kanban` / `claude plugin uninstall kanban@kanban`) and re-run. |
| `codex-plugin: repair` | `kanban@kanban` is installed and enabled, but the bundle Codex cached no longer matches this checkout's tracked one (or is not cached at all) | Re-run with `--apply`: it runs `codex plugin remove kanban@kanban` then `codex plugin add kanban@kanban` and verifies the result. Nothing else is touched. |
| `codex-plugin: failed`, after a refresh | Both provider commands succeeded, but the cached bundle still diverges | The reported paths say how. Check that `--repo` names the checkout the `kanban` marketplace is registered from, then re-run. |
| `codex-plugin`/`claude-plugin: unavailable` | The provider CLI is absent, its plugin listing could not be read, or (Codex) its cached bundle is present but unreadable | Install or update the provider CLI. An unreadable listing is never treated as "nothing installed", and an unreadable cache is never treated as stale — neither guess can trigger a reinstall. |

## Removal

Each component is removed with the provider's own command, or by deleting
the Kanban-namespaced path:

```console
codex plugin remove kanban@kanban
codex plugin marketplace remove kanban
claude plugin uninstall kanban@kanban
claude plugin marketplace remove kanban
rm -rf ~/Library/Application\ Support/kanban/issue-review   # macOS
rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}"/kanban/issue-review   # Linux
rm ~/work/approve-issues.py                       # only if it is a symlink
mv ~/work/approve-issues.py.pre-kanban-backup ~/work/approve-issues.py
```

Delete the backend's log directory the same way if you want it gone too:
`~/Library/Logs/kanban/issue-review` on macOS,
`"${XDG_STATE_HOME:-$HOME/.local/state}"/kanban/issue-review` on Linux.
Removing an installation never deletes the other platform's location, and
nothing migrates one to the other.

Removing the PR drainer is separate and unchanged; see
[the PR drainer guide](pr-drainer.md). Removing the issue approval service is
separate too — `python3 tools/install_issue_approval.py --uninstall`, per
repository; see [the issue approval guide](issue-approval.md). Removing the
`issue-review` backend above while an approval job is still installed leaves
that job with no reviewer to run, so uninstall the service first.

## Verification

Setup and preflight are covered by hermetic fresh-machine tests that run
under the commands CI already runs — temporary homes, temporary checkouts,
and scriptable fake provider executables on a temporary PATH, with no
credentials, network access, or model call:

```console
cabal test all --test-show-details=direct
python3 -m unittest discover -s tools -p 'test_*.py'
```

`tools/test_setup_workflows.py` covers a clean machine, an
already-configured machine, absent executables, an unreadable listing, a
marketplace registered from another checkout, an ordinary legacy launcher,
an occupied install path, and the no-write guarantee of a dry run. Its
`CodexBundleStalenessTests` group covers the installed-but-stale state
end to end against a temporary `CODEX_HOME` and a real copied cache: each
divergence class, an absent cache, untracked and ignored checkout files
counting as neither, the exact remove-then-add refresh and the convergence
re-check afterwards, a refresh that did not converge, an unreadable or
non-directory cache, and both refusal states keeping precedence over any
repair.
`test/Spec/Agent/Preflight.hs`'s `workflow preflight` group covers the probe
classifications and the same fresh-machine states end to end, including
that the doctor path only ever runs status-only probes and changes nothing.
