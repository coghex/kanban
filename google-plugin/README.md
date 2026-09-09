# Kanban Google plugin

This directory is a Copilot CLI marketplace, tracked in this repository, that
packages the Google-side `/solve` and `/autosolve` skills. A Google session — the
Copilot CLI running a Gemini model, e.g. `copilot --model gemini-3.8-flash` — opens a
pull request whose body ends with `<!-- pr-origin:google -->`. Dual-mode review
of that origin is Codex only — never Claude, and never both brands. Google is
not a Kanban-spawned provider: the board refuses revision and repair of a
google-origin pull request, so `autosolve` revises in the same Google session and
asks the bundled coordinator to spawn Codex.

See [docs/agent-workflow-contract.md](../docs/agent-workflow-contract.md) for
the origin routing and the trusted-comment helper these workflows call.

Claude packaging is at [claude-plugin/](../claude-plugin/README.md), Codex at
[codex-plugin/](../codex-plugin/README.md), Grok at
[grok-plugin/](../grok-plugin/README.md), Kimi at
[kimi-plugin/](../kimi-plugin/README.md). This bundle does not package
`/pr-review` as a Google self-review.

## Install and launch

These instructions were verified with GitHub Copilot CLI 1.0.83. Copilot
skills do not substitute a `$ARGUMENTS` variable: put the issue number in the
invoking message, for example `/solve 652`, and the skill reads it there.

Copilot discovers same-named skills from project, personal, and plugin
locations and applies first-found-wins precedence. A project or personal
`solve`, or an earlier-loaded provider bundle, can therefore shadow this
bundle's `/solve` or `/autosolve`. The tested launches below use a dedicated
`COPILOT_HOME` containing no Claude, Codex, Grok, or Kimi Kanban bundle, and the
worked repository must not provide a same-named project skill. A Copilot
session using a Claude model is a canonical Claude participant and must not
load this Google bundle.

The direct way loads the tracked checkout live, with no install:

```console
COPILOT_HOME=$HOME/.copilot-google \
  GOOGLE_PLUGIN_ROOT=$PWD/google-plugin/plugins/kanban \
  copilot --model gemini-3.8-flash --plugin-dir google-plugin/plugins/kanban
```

`GOOGLE_PLUGIN_ROOT` is what the skills' helper lookup reads first; exporting it
in the same launch line is what lets a `--plugin-dir` session find the
vendored coordinator and trusted-comment helper beside the skills it loaded.

The marketplace way registers and installs the bundle into that isolated
profile. Copilot CLI 1.0.83 requires the tested absolute marketplace path:

```console
COPILOT_HOME=$HOME/.copilot-google \
  copilot plugin marketplace add "$PWD/google-plugin"
COPILOT_HOME=$HOME/.copilot-google \
  copilot plugin install kanban@kanban-google
COPILOT_HOME=$HOME/.copilot-google copilot --model gemini-3.8-flash
```

A local marketplace loads live from this directory — nothing is copied — and
the CLI records its root at
`extraKnownMarketplaces.kanban-google.source.path` in
`$COPILOT_HOME/settings.json`, with the sibling `source` value `directory`.
The skills map that absolute root to `plugins/kanban/`. When no local
marketplace entry exists, they search exactly one copied git-source install
under `$COPILOT_HOME/installed-plugins/kanban-*/`; malformed applicable
settings, a missing helper, or zero or multiple copied matches stop without a
fallback. A marketplace name collision is refused by the CLI rather than
merged, which is why this marketplace is named `kanban-google` while the plugin
inside keeps the shared name `kanban`.

Whichever way it was loaded, invoke the skills by name in a Google session:
`/solve` takes one issue to a pull request, `/autosolve` runs `/solve` and
then the Codex review loop.

## What these skills spawn

`autosolve` calls this bundle's copy of `review_pr.py` **without**
`--self-review`. The coordinator spawns Codex. It must never spawn Claude.
A dry-run that reports any route other than `codex` is a stop.
