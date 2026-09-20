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

These instructions were verified with GitHub Copilot CLI 1.0.85. Copilot
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
profile. Copilot CLI 1.0.85 requires the tested absolute marketplace path:

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
It writes no `installed-plugins` entry and no `config.json`. The skills map
that absolute root to `plugins/kanban/`. A marketplace name collision is
refused by the CLI rather than merged, which is why this marketplace is named
`kanban-google` while the plugin inside keeps the shared name `kanban`.

While this bundle's manifest stays at
`google-plugin/.github/plugin/marketplace.json`, a *remote* marketplace
registration of it is not available: `copilot plugin marketplace add` takes
only `owner/repo`, a URL, or a local path — no subdirectory form — and then
looks for a `marketplace.json` at the clone root, whether directly there or
under a `.plugin/`, `.github/plugin/`, or `.claude-plugin/` directory of it.
That root is one directory above where this bundle's manifest is tracked.

The one remote install that does work is the direct one, which the CLI warns is
deprecated in favour of `plugin@marketplace`:

```console
COPILOT_HOME=$HOME/.copilot-google \
  copilot plugin install coghex/kanban:google-plugin/plugins/kanban
```

That copies the bundle to
`$COPILOT_HOME/installed-plugins/_direct/coghex--kanban--google-plugin-plugins-kanban/`,
naming the entry `<owner>--<repo>--<bundle path>` with the path's separators
flattened to single hyphens. It records that directory as `cache_path`, beside
a `github` source naming the repository and `google-plugin/plugins/kanban`, in
`$COPILOT_HOME/config.json`, and leaves `settings.json` holding only
`enabledPlugins`.

When no local marketplace entry applies — none recorded, or one the CLI
recorded from a remote `github`, `git`, or `url` source, each of which must
carry the field that kind locates its marketplace by — the skills search the
two copied
layouts the CLI creates, as one candidate set: the documented marketplace
layout `$COPILOT_HOME/installed-plugins/kanban-google/kanban/`, and a direct
install
`$COPILOT_HOME/installed-plugins/_direct/<owner>--<repo>--google-plugin-plugins-kanban/`.
Both are anchored to this bundle's own marketplace, plugin, and bundle path
rather than to any `kanban-*` directory, so a Kimi install sitting beside
a Google one is never adopted for Google. Malformed applicable settings, an
unsupported recorded source kind, a missing helper, or zero or several
candidate roots stop without a fallback.

Whichever way it was loaded, invoke the skills by name in a Google session:
`/solve` takes one issue to a pull request, `/autosolve` runs `/solve` and
then the Codex review loop.

## What these skills spawn

`autosolve` calls this bundle's copy of `review_pr.py` **without**
`--self-review`. The coordinator spawns Codex. It must never spawn Claude.
A dry-run that reports any route other than `codex` is a stop.
