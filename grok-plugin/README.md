# Kanban Grok plugin

This directory is a Grok marketplace, tracked in this repository, that
packages the Grok-side `/solve` and `/autosolve` workflows. A Grok session
opens a pull request whose body ends with `<!-- pr-origin:grok -->`. Dual-mode
review of that origin is Codex only — never Claude, and never both brands.
Grok is not a Kanban-spawned provider: the board refuses revision and repair
of a grok-origin pull request, so `/autosolve` revises in the same Grok
session and asks the bundled coordinator to spawn Codex.

See [docs/agent-workflow-contract.md](../docs/agent-workflow-contract.md) for
the origin routing and the trusted-comment helper these workflows call.

Claude packaging is at [claude-plugin/](../claude-plugin/README.md). Codex
packaging is at [codex-plugin/](../codex-plugin/README.md). This bundle does
not package `/pr-review` as a Grok self-review.

## Install

From a checkout of this repository:

```console
grok plugin marketplace add ./grok-plugin
grok plugin install kanban --trust
```

Grok also scans Claude skill and command directories by default. A Claude
`/solve` loaded in a Grok session would stamp a Claude origin marker and, on
changes-requested, send board revision to Claude. Turn that scan off for Grok
sessions in `~/.grok/config.toml`:

```toml
[compat.claude]
skills = false
```

Then start a new Grok session. `/solve` and `/autosolve` should be this
bundle's skills. If the slash menu still shows a Claude copy, invoke the
qualified form `/kanban:solve` / `/kanban:autosolve`.

## What these skills spawn

`/autosolve` calls this bundle's copy of `review_pr.py` **without**
`--self-review`. The coordinator spawns Codex. It must never spawn Claude.
A dry-run that reports any route other than `codex` is a stop.
