---
name: fixture-command
description: Rendering fixture for the shared command source mechanism. It is not a workflow; {{cmd:fixture-command}} names nothing either provider ships.
argument-hint: "[issue number]"
---

# Fixture Command

This file is not a workflow. It is the authored source
`tools/render_command_sources.py` renders into both plugin bundle layouts, so
that mechanism has something to prove itself against without vendoring a
command — issue #375, slice VEND-0 of
`docs/workflow_command_vendoring_design.md`.

Its two rendered outputs deliberately land under `tools/`, outside
`claude-plugin/plugins/kanban/commands/` and
`codex-plugin/plugins/kanban/skills/`, because `tools/plugin_bundle_gate.py`
takes shippedness from location. Nothing here is invokable, and the shipped
sets are unchanged.

## Invocation references

Every workflow reference is written once, as a `cmd` directive naming the
workflow, and picks up its brand's sigil at render time. The names below are
the cross-command references decision D-4 lists, so the rendered pair
exercises the real vocabulary rather than a lone self-reference:

- {{cmd:fixture-command}} is this file's own name, and it appears in the
  frontmatter description above as well as here in the body.
- {{cmd:autosolve}} drives {{cmd:solve}}, {{cmd:pr-review}},
  {{cmd:pr-rereview}}, {{cmd:finalize}} and {{cmd:issue}}.
- {{cmd:retriage}} preserves the sections {{cmd:triage}} rendered.
- {{cmd:janitor}} and {{cmd:finalize}} both invoke {{cmd:drain-prs}}.

## Counterexamples

None of the following is an invocation, and every one of them must survive
rendering byte-for-byte identically in both files:

- A URL: <https://github.com/coghex/kanban/issues/375>.
- Repository-relative paths: `docs/design.md`, and the two bundle directories
  named above.
- Absolute paths: `/tmp/kanban-scratch` and `/dev/null`.
- Shell variables: `$REPO`, `$WORKTREES_ROOT`, `$HOME`.
- Ordinary prose punctuation: a solve and/or review pass, 3/4 of the tree.

```console
python3 tools/render_command_sources.py --check < /dev/null
```

## Brand adaptations

Deliberate per-brand body text stays authored here, in one source, rather than
diverging across two files. Both variants below are drawn from the shipped
`solve` pair, whose argument convention and installed-helper resolution really
do differ by provider — the adaptations
`docs/workflow_command_vendoring_design.md` D-2 and D-7 require to survive
reconciliation.

<!-- brand:claude -->
1. Take the issue number from `$ARGUMENTS`, which Claude Code substitutes
   before the session reads this file.
2. Resolve this bundle's vendored helper through `${CLAUDE_PLUGIN_ROOT}`, which
   Claude Code expands to the plugin's own install location whatever the
   working directory is.
<!-- brand:codex -->
1. Take the issue number the user supplied in the prompt; Codex substitutes no
   argument placeholder.
2. Resolve this bundle's vendored helper by searching under `$CODEX_HOME`
   (default `~/.codex`), because Codex spawns the skill with the worked
   repository as the working directory rather than the bundle's own.
<!-- /brand -->

<!-- brand:claude -->
A block naming one brand renders as nothing at all for the other, which is how
a paragraph only one provider's copy carries stays authored in the shared
source. This one is Claude's.
<!-- /brand -->

## Stop condition

Nothing. Rendering this file is the whole of its behavior.
