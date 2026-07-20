# Kanban

Kanban is a terminal board for GitHub projects on macOS. It sorts issues and pull requests into four columns: Issues, Active, Reviewing, and Done.

It can also show Codex and Claude usage, run reviews, start work on issues, and track those jobs without leaving the terminal.

## Requirements

- macOS
- [Git](https://git-scm.com/)
- [GitHub CLI](https://cli.github.com/) signed in with `gh auth login`
- GHC and Cabal to build from source
- Codex or Claude installed and signed in, only if you want the optional AI actions

Having Codex or Claude installed and signed in is necessary but not
sufficient for AI actions: canonical issue review (the `r` key) also needs
`tools/install_issue_review.py` run once to install its backend. The named
`solve`/`pr-review`/`pr-rereview`/`pr-revise` commands are Kanban-owned
workflow assets; for Codex, install them once per checkout from
[codex-plugin/](codex-plugin/README.md):

```console
codex plugin marketplace add ./codex-plugin
codex plugin add kanban@kanban
```

The equivalent Claude packaging is not implemented yet. See
[the agent-workflow contract](docs/agent-workflow-contract.md) for the full
dependency list and what each action requires.

## Build

```console
git clone https://github.com/coghex/kanban.git
cd kanban
cabal update
cabal build all
```

## Run

Open the board for the current repository:

```console
cabal run kanban
```

Open another local repository:

```console
cabal run kanban -- --path /path/to/project
```

Kanban reads the repository's GitHub remote and uses your existing GitHub CLI login.

## Basic controls

| Key | Action |
| --- | --- |
| `j` / `k` | Move between cards |
| `h` / `l` | Move between columns |
| `Enter` | Open card details |
| `u` | Refresh the board and usage information |
| `r` | Review or revise the selected item |
| `S` | Work on the selected issue |
| `A` | Work on, review, and revise the selected issue |
| `p` | Show running and completed jobs |
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
- [PR drainer](docs/pr-drainer.md)
- [Agent-workflow contract](docs/agent-workflow-contract.md)
- [Development](docs/development.md)
- [Documentation index](docs/README.md)
- [Design and implementation notes](docs/design.md)

## Tests

```console
cabal test all --test-show-details=direct
python3 -m unittest discover -s tools -p 'test_*.py'
```

## License

[MIT](LICENSE)
