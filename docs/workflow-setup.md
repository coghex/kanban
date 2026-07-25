# Workflow setup and preflight

Kanban's board is fully usable with nothing installed beyond `git` and a
signed-in `gh`. Its optional AI actions — canonical issue review and
revision (`r`), solve (`S`), auto-solve (`A`), and the PR review/revise
flows (`r` on a pull request) — additionally need workflow assets this
repository tracks but does not install for you.

Two commands cover that whole surface:

- `python3 tools/setup_workflows.py` installs the components you select.
- `cabal run kanban -- --doctor` reports, read-only, why an action is not
  ready yet.

macOS is Kanban's supported platform, and remains so here: this document
describes a macOS setup path, not a cross-platform port.

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
nothing starts the PR drainer, an approval daemon, or an agent session.

## Components

Select components explicitly with `--component` (repeatable) or take all
four with `--all`.

| Component | What it installs | Needed for |
| --- | --- | --- |
| `issue-review` | A Kanban-managed link to the tracked `tools/approve_issues.py` backend under `~/Library/Application Support/kanban/issue-review/` | Canonical issue review/rereview (`r`), and the read-only readiness gate a solve session checks before claiming an issue |
| `codex-plugin` | `kanban@kanban` from `codex-plugin/`, through `codex plugin marketplace add` and `codex plugin add` | `$solve`, `$pr-review`, `$pr-rereview`, `$pr-revise` |
| `claude-plugin` | `kanban@kanban` from `claude-plugin/`, through `claude plugin marketplace add` and `claude plugin install` | `/solve`, `/pr-review`, `/pr-rereview`, `/pr-revise` |
| `legacy-launcher` | A symlink at `~/work/approve-issues.py` pointing at the installed backend | Nothing in Kanban. Purely a compatibility shim for pre-migration automation that still invokes that path directly — see [agent-workflow-contract §3](agent-workflow-contract.md#3-migration-boundary) |

`issue-review` and `legacy-launcher` install into a per-user location by
design: `src/Kanban/Review.hs` resolves exactly that path, and there is no
project-scoped alternative. Both follow the same never-replace-an-ordinary-file
policy as the PR-drainer installer.

## Scopes

`--scope` controls where a *provider* registration is declared. Project
scope is the default; a user-global registration is never chosen for you.

- **`--scope project`** (default) declares the Claude Code plugin in the
  target repository's own `.claude/settings.json`, so it is available to
  sessions started from that repository. Use `--target /path/to/repo` when
  that repository is not the Kanban checkout itself; it defaults to
  `--repo`.
- **`--scope user`** declares the registration once for every session.

Codex has no project-scoped install: `codex plugin` registers marketplaces
and plugins in your own `$CODEX_HOME/config.toml`. Setup therefore refuses
`--component codex-plugin` under the default project scope and tells you to
re-run with `--scope user`, so a user-global change is always an explicit
choice.

## Dry run, convergence, and refusal

- **Dry run is the default.** Without `--apply`, every component is
  inspected and its planned action printed, and no filesystem, provider
  configuration, LaunchAgent, daemon, or network-side change is made.
  `--dry-run` states that explicitly; it cannot be combined with `--apply`.
- **Re-running converges.** A component that is already correct reports
  `unchanged` and runs no command.
- **Nothing is silently replaced.** A conflicting state is reported as
  `refused`, left exactly as it was, and paired with the recovery step you
  would take. `setup_workflows.py` exits non-zero whenever any component
  needs your attention.

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

- **Canonical review/rereview** needs the backend (both its installed
  files — `approve_issues.py` imports `kanban_config.py`), `gh`, and the
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
`pr-rereview`/`pr-revise` workflows. If you previously relied on your own
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
- install, start, or configure the PR drainer, an approval daemon, or any
  agent session.

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
| `codex-plugin`/`claude-plugin: refused`, marketplace mismatch | A marketplace named `kanban` is already registered from another checkout | Remove it (`codex plugin marketplace remove kanban` / `claude plugin marketplace remove kanban`) and re-run, or point `--repo` at that checkout. |
| `codex-plugin`/`claude-plugin: refused`, bundle disabled | `kanban@kanban` is installed but disabled | Re-enable it (`claude plugin enable kanban@kanban`), or remove it (`codex plugin remove kanban@kanban` / `claude plugin uninstall kanban@kanban`) and re-run. |
| `codex-plugin`/`claude-plugin: unavailable` | The provider CLI is absent, or its plugin listing could not be read | Install or update the provider CLI. An unreadable listing is never treated as "nothing installed". |

## Removal

Each component is removed with the provider's own command, or by deleting
the Kanban-namespaced path:

```console
codex plugin remove kanban@kanban
codex plugin marketplace remove kanban
claude plugin uninstall kanban@kanban
claude plugin marketplace remove kanban
rm -rf ~/Library/Application\ Support/kanban/issue-review
rm ~/work/approve-issues.py                       # only if it is a symlink
mv ~/work/approve-issues.py.pre-kanban-backup ~/work/approve-issues.py
```

Removing the PR drainer is separate and unchanged; see
[the PR drainer guide](pr-drainer.md).

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
an occupied install path, and the no-write guarantee of a dry run.
`test/Spec.hs`'s `workflow preflight` group covers the probe
classifications and the same fresh-machine states end to end, including
that the doctor path only ever runs status-only probes and changes nothing.
