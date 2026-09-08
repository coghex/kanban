# Kanban Kimi plugin

This directory is a Copilot CLI marketplace, tracked in this repository, that
packages the Kimi-side `/solve` and `/autosolve` skills. A Kimi session — the
Copilot CLI running a Kimi model, e.g. `copilot --model kimi-k3` — opens a
pull request whose body ends with `<!-- pr-origin:kimi -->`. Dual-mode review
of that origin is Codex only — never Claude, and never both brands. Kimi is
not a Kanban-spawned provider: the board refuses revision and repair of a
kimi-origin pull request, so `autosolve` revises in the same Kimi session and
asks the bundled coordinator to spawn Codex.

See [docs/agent-workflow-contract.md](../docs/agent-workflow-contract.md) for
the origin routing and the trusted-comment helper these workflows call.

Claude packaging is at [claude-plugin/](../claude-plugin/README.md), Codex at
[codex-plugin/](../codex-plugin/README.md), Grok at
[grok-plugin/](../grok-plugin/README.md). This bundle does not package
`/pr-review` as a Kimi self-review.

## Install and launch

Two ways to load it, both keeping the bundle out of non-Kimi sessions — which
is the point: a Copilot session on a Claude model is a canonical Claude
participant and must follow the Claude bundle's workflows instead, so this
bundle is never installed globally without intent.

The direct way loads the tracked checkout live, no install:

```console
KIMI_PLUGIN_ROOT=$PWD/kimi-plugin/plugins/kanban \
  copilot --model kimi-k3 --plugin-dir kimi-plugin/plugins/kanban
```

`KIMI_PLUGIN_ROOT` is what the skills' helper lookup reads first; exporting it
in the same launch line is what lets a `--plugin-dir` session find the
vendored coordinator and trusted-comment helper beside the skills it loaded.

The marketplace way registers and installs the bundle:

```console
copilot plugin marketplace add ./kimi-plugin
copilot plugin install kanban@kanban-kimi
```

A local marketplace loads live from this directory — nothing is copied — and
the CLI records its path under `extraKnownMarketplaces` in
`$COPILOT_HOME/settings.json`, which the skills' helper lookup reads when
`KIMI_PLUGIN_ROOT` is not set. Only a marketplace installed from a git remote
copies into `$COPILOT_HOME/installed-plugins/` (default `~/.copilot`), the
layout the lookup searches last. A marketplace name collision is refused by
the CLI rather than merged, which is why this marketplace is named
`kanban-kimi` while the plugin inside keeps the shared name `kanban`.

Whichever way it was loaded, invoke the skills by name in a Kimi session:
`/solve` takes one issue to a pull request, `/autosolve` runs `/solve` and
then the Codex review loop.

## What these skills spawn

`autosolve` calls this bundle's copy of `review_pr.py` **without**
`--self-review`. The coordinator spawns Codex. It must never spawn Claude.
A dry-run that reports any route other than `codex` is a stop.
