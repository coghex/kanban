---
description: Land documentation from the docs worktree straight onto master through the tracked tools/docs_land.sh helper — named paths land exactly, an explicit all-docs request lands every eligible candidate, and a request with no selection produces an inventory to choose from. Use when the user invokes /push-docs or asks to land, publish, or batch documentation from the docs-wip worktree.
argument-hint: "[docs/<file>.md ... | all docs] — repository-relative Markdown paths, an explicit broad selection, or empty for the inventory"
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

A supplied path list arrives in `$ARGUMENTS`, which Claude Code substitutes
before the session reads this file: whitespace-separated, repository-relative
Markdown paths. When it is non-empty, that list is the approved selection;
when it is empty, use the inventory mode below.

Before choosing a mode, distinguish an absent selection from an explicit broad
one. Phrases such as **all docs**, **every pending document**, **land the docs
worktree**, and **batch everything in docs-wip** are an approved selection of
all eligible documentation candidates found by the inventory procedure below.
Do not ask for a second approval after resolving that scope to exact paths. A
bare invocation with no named paths and no such scope is inventory-only and
still requires the selection stop below.

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

## Inventory

1. Inspect the helper's `-h` output before using `-l`; do not discover option
   support by deliberately invoking an unknown flag. If the help advertises
   `-l` as an inventory/list option, produce the authoritative inventory with:

   ```bash
   "$ROOT/tools/docs_land.sh" -l
   ```

2. If the helper does not advertise `-l`, use a read-only Git inventory rather
   than treating the older helper as broken. Resolve the worktree whose branch
   is `refs/heads/docs-wip`, then take the union of:

   ```bash
   git -C "$DOCS_WT" diff --name-only -z origin/master --
   git -C "$DOCS_WT" ls-files --others --exclude-standard -z --
   ```

   Parse those outputs as NUL-delimited path records. Retain only
   repository-recognized documentation paths (normally Markdown under
   `docs/` plus root instruction documents); exclude implementation, test,
   configuration, generated binary, and asset paths. The named-path dry run
   remains the authority for whether the older helper can land each retained
   path.
3. Present the inventory readably. When `-l` supplied classification data,
   include each path's tracked status, modification state, whether it differs
   from `origin/master`, its §7 row and lane, and any refusal reason. With the
   Git fallback, identify it as a compatibility inventory and show the exact
   candidate paths. In either mode, highlight the paths that actually differ.
4. Resolve the selection:
   - If the user explicitly requested all docs, every pending document, the
     whole docs batch, or an equivalent broad scope, select every eligible
     candidate and continue immediately through the named-path steps. **All
     docs is an approved selection**; do not ask for a second approval.
   - If the user supplied no selection, obtain explicit approval of the exact
     path list. Treat an empty, ambiguous, or declined response as landing
     nothing.
5. Land only the resulting paths through the named-path steps above. If a
   broad selection contains no eligible candidate, report that there is
   nothing to land.

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
- Landing requires either explicit approval of exact named paths or an
  explicit broad scope such as all pending docs. A bare invocation is not a
  broad scope and must stop for selection after inventory; an explicit broad
  scope must not stop for redundant path-by-path approval.
- If the helper exits nonzero while showing help, producing an advertised
  inventory, dry-running, or landing, report its output verbatim and stop
  rather than retrying with different flags. The Git compatibility inventory
  is used only when help establishes that `-l` is unsupported; it never
  replaces or bypasses the helper for a dry run or landing.
