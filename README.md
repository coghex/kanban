# Kanban

Kanban is a terminal board for GitHub projects. It sorts issues and pull requests into four columns: Issues, Active, Reviewing, and Done.

It can also show Codex and Claude usage, run reviews, start work on issues, and track those jobs without leaving the terminal.

## Requirements

- [Git](https://git-scm.com/)
- [GitHub CLI](https://cli.github.com/) signed in with `gh auth login`
- GHC and Cabal to build from source
- Codex or Claude installed and signed in, only if you want the optional AI actions

Having Codex or Claude installed and signed in is necessary but not
sufficient for AI actions: the canonical issue-review backend and the
Kanban-owned `solve`/`pr-review`/`pr-rereview`/`pr-revise`/`repair` workflow
bundles have to be installed once as well. One opt-in command covers all of them,
and reports exactly what it would do before changing anything:

```console
python3 tools/setup_workflows.py --all --scope user
python3 tools/setup_workflows.py --all --scope user --apply
```

To see whether an AI action is ready, and what to run if it is not:

```console
cabal run kanban -- --doctor
```

See [workflow setup and preflight](docs/workflow-setup.md) for the
components, scopes, recovery steps, and removal, and
[the agent-workflow contract](docs/agent-workflow-contract.md) for the full
dependency list and what each action requires.

## Build

```console
git clone https://github.com/coghex/kanban.git
cd kanban
cabal update
cabal build all
```

## Install

From a source checkout, install the executable into Cabal's user binary
directory:

```console
cabal install exe:kanban
kanban --version
```

If `kanban` is not found after installation, add Cabal's user binary directory
(normally `~/.local/bin`, or the path named in Cabal's installation warning) to
your `PATH`.

The executable runs the board on its own. Keep the source checkout if you use
the optional AI workflows or PR drainer: their setup commands install the
tracked scripts and plugin bundles from that checkout.

## Run

Open the board for the current repository:

```console
cabal run kanban
```

After installing the executable, the equivalent command is:

```console
kanban
```

Open another local repository:

```console
cabal run kanban -- --path /path/to/project
```

With the installed executable:

```console
kanban --path /path/to/project
```

Kanban reads the repository's GitHub remote and uses your existing GitHub CLI login.

## Basic controls

| Key | Action |
| --- | --- |
| `j` / `k` | Move between cards |
| `h` / `l` | Move between columns |
| `Enter` | Open card details |
| `u` | Refresh the board and usage information |
| `r` | Review or revise the selected item, or repair a pull request in Done that has a problem |
| `S` | Work on the selected issue |
| `A` | Work on, review, and revise the selected issue |
| `p` | Show running and completed jobs |
| `i` | Show everything needing attention, and go to it |
| `m` | Merge the selected approved pull request in Done |
| `?` | Show all controls |
| `q` | Quit |

Mouse selection, scrolling, and details are also supported.

## Optional PR drainer

The PR drainer merges approved pull requests after their required checks pass. Preview the installation before enabling it:

```console
python3 tools/install_drainer.py --dry-run --json
python3 tools/install_drainer.py
```

Installation does not start the drainer. Press `d` in Kanban when you are ready to run it.

## Documentation

- [User guide](docs/user-guide.md)
- [Workflow setup and preflight](docs/workflow-setup.md)
- [PR drainer](docs/pr-drainer.md)
- [Agent-workflow contract](docs/agent-workflow-contract.md)
- [Development](docs/development.md)
- [Documentation index](docs/README.md)
- [Design and implementation notes](docs/design.md)
- [Claude Code session instructions](CLAUDE.md)

## Tests

```console
cabal test all --test-show-details=direct
python3 -m unittest discover -s tools -p 'test_*.py'
```

## License

[MIT](LICENSE)
