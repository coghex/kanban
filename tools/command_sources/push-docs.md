---
name: push-docs
description: Land documentation from the docs worktree straight onto master through the tracked tools/docs_land.sh helper — named paths land exactly, and no arguments produces an inventory to choose from. Use when the user invokes {{cmd:push-docs}} or asks to land, publish, or batch documentation from the docs-wip worktree.
argument-hint: "[docs/<file>.md ...] — repository-relative Markdown paths; empty for the inventory"
---

# Push Docs

## Goal

Land one or more documentation files from the `docs-wip` worktree straight
onto `master` through the repository's tracked landing helper,
`tools/docs_land.sh`. The helper — not this workflow — owns the git
mechanics: it resolves both worktrees by branch, gates every path against
`docs/agent-workflow-contract.md` §7 as published on `origin/master`, builds
a landing commit carrying only the named paths, judges push success by
rev-list reachability rather than push output, and fast-forwards the primary
checkout only when it is clean and unobstructed. This workflow's job is to
choose the paths,
write the commit subject, and relay the helper's answers faithfully.

This lane is user-directed publication. Never run a landing the user did not
ask for, and never use it to publish your own work unprompted.

## Preconditions

Resolve the repository root once:

```bash
ROOT="$(git rev-parse --show-toplevel)"
```

If `$ROOT/tools/docs_land.sh` does not exist, stop and report that this
repository does not vendor the landing helper. Do not improvise a landing
with raw git commands.

## Named paths

<!-- brand:claude -->
A supplied path list arrives in `$ARGUMENTS`, which Claude Code substitutes
before the session reads this file: whitespace-separated, repository-relative
Markdown paths. When it is non-empty, that list is the approved selection;
when it is empty, use the inventory mode below.
<!-- brand:codex -->
A supplied path list arrives in the prompt; Codex substitutes no argument
placeholder. When the user named paths, that list is the approved selection;
when they named none, use the inventory mode below.
<!-- /brand -->

1. Compose a concise commit subject describing the documents being landed,
   for example `docs: land the model settings design update`.
2. Dry-run first and show the reported plan — subject, per-path action,
   destination, and reconcile decision:

   ```bash
   "$ROOT/tools/docs_land.sh" -n -m "<subject>" docs/<file>.md ...
   ```

3. If the dry run reports a plan with no refusal and no warning, land:

   ```bash
   "$ROOT/tools/docs_land.sh" -m "<subject>" docs/<file>.md ...
   ```

4. Relay the helper's closing report: whether the landing verified, whether
   `docs-wip` still carries unpushed local commits, and whether the primary
   checkout fast-forwarded or was skipped as dirty.

## No arguments: inventory and selection

1. Produce the inventory of landable documents:

   ```bash
   "$ROOT/tools/docs_land.sh" -l
   ```

2. Present it readably: each path with its tracked status, modification
   state, whether it differs from `origin/master`, its §7 row and lane, and
   its refusal reason when it has one. Highlight the paths that actually
   differ — they are the landing candidates.
3. Obtain the user's explicit approval of the exact path list to land. Never
   land the whole worktree unprompted, and treat an empty, ambiguous, or
   declined selection as landing nothing.
4. Land only the approved paths through the named-path steps above.

## Rules

- The helper refuses a path a test parses or an implementation is coupled
  to, naming the reason and the gate that would break; those documents land
  through a pull request with what gates them. The root instruction documents
  `CLAUDE.md` and its `AGENTS.md` alias are the sole exceptions, and a
  selection of `AGENTS.md` is canonicalized to `CLAUDE.md` — report that
  canonicalization when the helper notes it. Never work around a refusal: no
  raw `git push` to master, no editing the classification to unlock a path,
  no landing from another checkout.
- A warning that dirty files also changed upstream, or that a named path
  changed upstream, is a stop: report it and let the user decide. Never pass
  `-f` unless the user explicitly directs it after seeing that warning.
- Landing requires the explicit approval of the exact path list — either the
  paths the user named when invoking this workflow, or the selection they
  approved from the inventory. Nothing else may land.
- If the helper exits nonzero at any step, report its output verbatim and
  stop rather than retrying with different flags.
