# Kanban Claude-on-Copilot plugin

This directory is a Copilot CLI marketplace, tracked in this repository, that
packages `/solve` and `/autosolve` for a Claude session hosted by the Copilot
CLI — the Copilot CLI running a Claude model, e.g.
`copilot --model claude-opus-5.5`. Such a session opens a pull request whose
body ends with `<!-- pr-origin:claude -->`. Dual-mode review of that origin is
Codex only — never Claude, and never both brands. Because this session is
itself Claude, `autosolve` revises in the same session and asks the bundled
coordinator to spawn Codex; it never spawns another Claude session.

A bundle's brand is the model the session runs, not the executable hosting it
(D-0 of `docs/coordination/external_workflow_authoring_design.md` in the Kanban
repository).
A Copilot session running a Claude model is therefore a canonical Claude
participant: it stamps `pr-origin:claude` on a pull request and
`issue-origin:claude` on any issue it newly authors, and it must not load the
Kimi or Google bundle, whose skills stamp a kimi or google origin. This bundle
is the one it loads instead. It is another host's packaging of the Claude
brand, not a sixth origin: `route_reviewers` already sends a claude origin to
Codex, and nothing about that routing changes here.

See [docs/agent-workflow-contract.md](../docs/agent-workflow-contract.md) for
the origin routing and the trusted-comment helper these workflows call.

Claude Code's own packaging is at [claude-plugin/](../claude-plugin/README.md),
Codex at [codex-plugin/](../codex-plugin/README.md), Grok at
[grok-plugin/](../grok-plugin/README.md), Kimi at
[kimi-plugin/](../kimi-plugin/README.md), and Google at
[google-plugin/](../google-plugin/README.md). This bundle does not package
`/pr-review` as a Claude self-review.

## One Copilot Kanban bundle per profile

Every Kanban bundle ships a plugin named `kanban` with skills named `solve` and
`autosolve`, and the Copilot CLI discovers same-named skills from project,
personal, and plugin locations with first-found-wins precedence, so whichever
is found first shadows the others. Renaming this bundle's skills cannot fix
that: Kanban and its users invoke the workflows by
those names. So the decision is that the operator enables exactly one Copilot
Kanban bundle at a time — this one, the Kimi one, or the Google one — in a
dedicated `COPILOT_HOME`, and the worked repository must not provide a
same-named project skill. What is named distinctly is the marketplace,
`kanban-claude`, because the CLI refuses a marketplace name collision rather
than merging it, and the plugin-root variable, `$CLAUDE_COPILOT_PLUGIN_ROOT`,
because Claude Code's own `$CLAUDE_PLUGIN_ROOT` names a different host's bundle.

If a profile holds more than one anyway, the wrong one is refused rather than
obeyed. Both skills read the session's model from
`$COPILOT_HOME/session-store.db` for `$COPILOT_AGENT_SESSION_ID` before they
claim anything, and refuse unless it is a Claude model, refusing just the same
when that record cannot be read. The Kimi and Google skills run the same check
against their own brand and name this bundle, `kanban-claude`, when a Claude
session reaches them.

## Install and launch

These instructions were verified with GitHub Copilot CLI 1.0.88. Copilot
skills do not substitute a `$ARGUMENTS` variable: put the issue number in the
invoking message, for example `/solve 652`, and the skill reads it there.

The direct way loads the tracked checkout live, with no install:

```console
COPILOT_HOME=$HOME/.copilot-claude \
  CLAUDE_COPILOT_PLUGIN_ROOT=$PWD/claude-copilot-plugin/plugins/kanban \
  copilot --model claude-opus-5.5 --plugin-dir claude-copilot-plugin/plugins/kanban
```

`CLAUDE_COPILOT_PLUGIN_ROOT` is what the skills' helper lookup reads first;
exporting it in the same launch line is what lets a `--plugin-dir` session find
the vendored coordinator and trusted-comment helper beside the skills it loaded.

The marketplace way registers and installs the bundle into that isolated
profile, by the absolute marketplace path:

```console
COPILOT_HOME=$HOME/.copilot-claude \
  copilot plugin marketplace add "$PWD/claude-copilot-plugin"
COPILOT_HOME=$HOME/.copilot-claude \
  copilot plugin install kanban@kanban-claude
COPILOT_HOME=$HOME/.copilot-claude copilot --model claude-opus-5.5
```

A local marketplace loads live from this directory — nothing is copied — and
the CLI records its root at
`extraKnownMarketplaces.kanban-claude.source.path` in
`$COPILOT_HOME/settings.json`, with the sibling `source` value `directory`.
The skills map that absolute root to `plugins/kanban/`.

While this bundle's manifest stays at
`claude-copilot-plugin/.github/plugin/marketplace.json`, a *remote* marketplace
registration of it is not available: `copilot plugin marketplace add` takes
only `owner/repo`, a URL, or a local path — no subdirectory form — and then
looks for a `marketplace.json` at the clone root, whether directly there or
under a `.plugin/`, `.github/plugin/`, or `.claude-plugin/` directory of it.
That root is one directory above where this bundle's manifest is tracked.

The one remote install that does work is the direct one, which the CLI warns is
deprecated in favour of `plugin@marketplace`:

```console
COPILOT_HOME=$HOME/.copilot-claude \
  copilot plugin install coghex/kanban:claude-copilot-plugin/plugins/kanban
```

That copies the bundle to
`$COPILOT_HOME/installed-plugins/_direct/coghex--kanban--claude-copilot-plugin-plugins-kanban/`,
naming the entry `<owner>--<repo>--<bundle path>` with the path's separators
flattened to single hyphens, and records that directory as `cache_path` in
`$COPILOT_HOME/config.json`.

When no local marketplace entry applies — none recorded, or one the CLI
recorded from a remote `github`, `git`, or `url` source, each of which must
carry the field that kind locates its marketplace by — the skills search the
two copied layouts the CLI creates, as one candidate set: the documented
marketplace layout `$COPILOT_HOME/installed-plugins/kanban-claude/kanban/`, and
a direct install
`$COPILOT_HOME/installed-plugins/_direct/<owner>--<repo>--claude-copilot-plugin-plugins-kanban/`.
Both are anchored to this bundle's own marketplace, plugin, and bundle path
rather than to any `kanban-*` directory, so a Kimi or Google install sitting
beside this one is never adopted for Claude, and neither is Claude Code's
bundle. Malformed applicable settings, an unsupported recorded source kind, a
missing helper, or zero or several candidate roots stop without a fallback.

Whichever way it was loaded, invoke the skills by name in a Claude session:
`/solve` takes one issue to a pull request, `/autosolve` runs `/solve` and
then the Codex review loop.

## What these skills spawn

`autosolve` calls this bundle's copy of `review_pr.py` **without**
`--self-review`. The coordinator spawns Codex. It must never spawn Claude.
A dry-run that reports any route other than `codex` is a stop.

A fork pull request is the one case that stops for Claude where it would not
for Kimi or Google. The bundled coordinator, like Claude Code's and Codex's,
keeps only a grok, kimi, or google marker when GitHub reports
`isCrossRepository`, so a claude marker on a fork pull request reads as an
unknown origin on the dual route. `autosolve` reads `isCrossRepository` beside
the body and stops there, before any review is requested.
