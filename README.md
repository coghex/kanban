# kanban

`kanban` is an event-driven Haskell terminal dashboard for GitHub work and
on-demand Codex and Claude usage limits. It is designed for macOS terminals,
tmux, and SSH. GitHub and usage providers never poll in the background; the
local launchd status of the PR drainer is checked every ten seconds.

The current implementation resolves the local Git repository, renders its last
cached snapshot immediately, and starts one asynchronous GitHub refresh. Later
refreshes happen only when `r` is pressed; there is no polling. It renders
standalone and tracker-grouped issues plus open pull requests across the four
workflow columns, preserves the last good board after refresh failures, and
supports keyboard navigation plus details/help overlays. Press `u` to refresh
Codex through the local app-server and Claude through the official client's
interactive `/usage` screen. Each provider refreshes and fails independently.
GitHub pagination limits and nested connection caps are surfaced with `+`/`+N`
markers and amber warnings rather than silently dropping data.
Malformed epic checklists retain every valid child, leave unparsed children
standalone, and show line-specific amber diagnostics.

The bottom of the sidebar contains an ASCII `drain_prs.py` button backed by the
installed `com.coghex.drain-prs` LaunchAgent. White means stopped, green means
running, yellow means a transition or warning, and red means an error. Click it
or press `d` to start or stop the managed drainer. Status checks are local and
make no network request.

Epics are purple and collapsed by default. Focus a collapsed epic with `j`/`k`
and press `x` to expand or collapse it.

```console
cabal run kanban
cabal run kanban -- --path ~/work/synarchy
cabal run kanban -- --border open # optional borderless column gutters
cabal run kanban -- --glyph-test  # compare line glyphs in this terminal/font
```

Board refresh uses the authenticated GitHub CLI. Run `gh auth login` first if
`gh` is not already authenticated. Cache files live under
`~/.cache/kanban/repos/`; the global usage snapshot lives at
`~/.cache/kanban/usage.json`. Both are written with user-only permissions;
pass `--no-cache` to disable both reads and writes.

See [DESIGN.md](DESIGN.md) for the complete design and implementation roadmap.
