#!/usr/bin/env bash
# Land one or more documents from the docs-wip worktree onto master.
#
# Why this exists (issue #410): documentation lands on master by direct push
# (see CLAUDE.md "Markdown changes"), and the naive recipe is wrong in ways
# that have already cost real time:
#
#   * `git rebase --autostash` stashes EVERY dirty file, not just the ones
#     being landed, and replays them over a moved master — so landing doc A
#     while doc B is half-written can conflict on B;
#   * the protected-ref warning prints on every SUCCESSFUL admin-bypass push,
#     so push output cannot be read as success or failure;
#   * a bare `git commit` after staging named paths records the whole index,
#     so an unrelated staged file rides along;
#   * pushing the docs-wip branch publishes every commit on it, so a landing
#     cannot exclude an unrelated document someone already committed there.
#
# This script commits ONLY the paths you name, built directly on top of
# origin/master so no unselected committed work can ride along; gates every
# path against docs/agent-workflow-contract.md §7 as published on
# origin/master (via tools/docs_land_paths.py beside this script); warns
# BEFORE doing anything when a dirty or untracked file — ignored included —
# that you are NOT landing also changed upstream; judges success by rev-list
# reachability, never by push output; and fast-forwards the primary checkout
# only when it is clean and no untracked or ignored file occupies a path the
# update would touch.
#
# Usage:
#   tools/docs_land.sh -m "Commit subject" docs/foo.md [docs/bar.md ...]
#   tools/docs_land.sh -n -m "..." docs/foo.md   # dry run: plan, no changes
#   tools/docs_land.sh -f -m "..." docs/foo.md   # ignore the risk warning
#   tools/docs_land.sh -l                        # inventory of landable docs
#
# Exit codes: 0 landed (or nothing to land); 1 environment failure; 2 usage;
# 3 predicted conflict without -f; 4 rebase stopped; 5 push not verified;
# 6 a named path was refused by validation or classification.
set -euo pipefail

DRY=0
FORCE=0
LIST=0
MSG=""
while getopts "m:nflh" opt; do
  case "$opt" in
    m) MSG="$OPTARG" ;;
    n) DRY=1 ;;
    f) FORCE=1 ;;
    l) LIST=1 ;;
    h) sed -n '2,36p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

if [ "$LIST" = 1 ]; then
  [ $# -eq 0 ] || { echo "error: -l takes no paths" >&2; exit 2; }
else
  [ $# -gt 0 ] || { echo "error: name at least one path to land, or use -l" >&2; exit 2; }
  [ -n "$MSG" ] || { echo "error: -m \"commit subject\" is required" >&2; exit 2; }
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/docs_land_paths.py"
[ -f "$GATE" ] || { echo "error: $GATE is missing" >&2; exit 1; }

# Resolve each worktree by BRANCH, never a hard-coded path, and fail before
# any mutation when either branch has no worktree (or, defensively, more than
# one — git itself forbids that, so two matches mean a corrupt listing).
resolve_worktree() {
  git worktree list --porcelain \
    | awk -v want="branch refs/heads/$1" '/^worktree /{p=substr($0,10)} $0==want{print p}'
}
require_one() {
  # $1: branch name, $2: resolved paths (newline-separated)
  if [ -z "$2" ]; then
    echo "error: no worktree is on branch $1. Create one with:" >&2
    echo "  git worktree add ../kanban-docs -b docs-wip origin/master" >&2
    exit 1
  fi
  case "$2" in
    *"
"*)
      echo "error: more than one worktree claims branch $1:" >&2
      printf '%s\n' "$2" | sed 's/^/  /' >&2
      exit 1
      ;;
  esac
}
DOCS_WT="$(resolve_worktree docs-wip)"
require_one docs-wip "$DOCS_WT"
PRIMARY="$(resolve_worktree master)"
require_one master "$PRIMARY"
cd "$DOCS_WT"

git fetch -q origin

if [ "$LIST" = 1 ]; then
  exec python3 "$GATE" --worktree "$DOCS_WT" --inventory
fi

# --- Gate: validation, alias canonicalization, §7 classification -----------
CANONICAL="$(python3 "$GATE" --worktree "$DOCS_WT" --gate -- "$@")" || exit 6
set --
while IFS= read -r p; do
  [ -n "$p" ] && set -- "$@" "$p"
done <<EOF
$CANONICAL
EOF
[ $# -gt 0 ] || { echo "error: the gate returned no paths" >&2; exit 6; }

BASE_TIP="$(git rev-parse origin/master)"
BASE="$(git merge-base HEAD origin/master)"

# Whether an untracked or ignored occupant stands where $1 (repo-relative)
# would be checked out in worktree $2 — at the leaf, or as a symlink at any
# ancestor component, which a checkout replaces just the same when it needs
# that component as a real directory. Prints the occupying path and returns
# zero when one is found. An untracked real directory ancestor is not an
# occupant: checkout creates files inside it without clobbering anything.
occupied_untracked() {
  _rest="$1"
  _prefix=""
  while [ -n "$_rest" ]; do
    case "$_rest" in
      */*) _seg="${_rest%%/*}"; _rest="${_rest#*/}" ;;
      *) _seg="$_rest"; _rest="" ;;
    esac
    if [ -z "$_prefix" ]; then _prefix="$_seg"; else _prefix="$_prefix/$_seg"; fi
    if [ -e "$2/$_prefix" ] || [ -L "$2/$_prefix" ]; then
      if ! GIT_LITERAL_PATHSPECS=1 git -C "$2" ls-files --error-unmatch -- "$_prefix" >/dev/null 2>&1; then
        if [ "$_prefix" = "$1" ] || [ -L "$2/$_prefix" ]; then
          printf '%s\n' "$_prefix"
          return 0
        fi
      fi
    else
      # Nothing on disk at this component, so nothing deeper exists either.
      return 1
    fi
  done
  return 1
}

# What landing each path would do to origin/master's tree.
path_action() {
  # $1: path. Prints add | modify | delete | unchanged.
  if [ -e "$1" ]; then
    if git cat-file -e "origin/master:$1" 2>/dev/null; then
      if [ "$(git hash-object -- "$1")" = "$(git rev-parse "origin/master:$1")" ]; then
        echo unchanged
      else
        echo modify
      fi
    else
      echo add
    fi
  else
    if git cat-file -e "origin/master:$1" 2>/dev/null; then
      echo delete
    else
      echo unchanged
    fi
  fi
}

# --- Pre-flight: predict a reconciliation conflict before touching anything -
# Files that are dirty or untracked here, NOT being landed, and ALSO changed
# on master since our merge base are exactly the ones the reconciliation
# rebase stumbles on: a tracked dirty file is autostashed and can conflict on
# replay, an untracked file that master newly adds is never stashed at all so
# the rebase's checkout refuses it outright, and an untracked file that is
# also IGNORED is worse — checkout silently overwrites it. All three are
# detected here, before anything is published, by walking the (small)
# upstream-changed set and asking about each path's local state — presence on
# disk without an index entry covers untracked and ignored alike, which an
# --exclude-standard listing would not. Written for bash 3.2 (macOS
# /bin/bash): no mapfile, no bare expansion of a possibly-empty array under
# `set -u`.
CHANGED_UPSTREAM="$(git diff --name-only "$BASE" origin/master)"
DIRTY="$( { git diff --name-only; git diff --cached --name-only; } | sort -u )"
RISK=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  landing=0
  for p in "$@"; do [ "$f" = "$p" ] && landing=1; done
  [ "$landing" = 1 ] && continue
  at_risk=0
  OCCUPANT="$f"
  if printf '%s\n' "$DIRTY" | grep -qxF -- "$f"; then
    at_risk=1
  elif OCCUPANT="$(occupied_untracked "$f" "$DOCS_WT")"; then
    # occupied_untracked rather than a bare -e test: a dangling symlink
    # fails -e yet still occupies its path, and an untracked or ignored
    # symlink at an ANCESTOR component is replaced just the same when the
    # checkout needs that component as a real directory.
    at_risk=1
  fi
  [ "$at_risk" = 1 ] || continue
  case "$RISK" in *"|$OCCUPANT|"*) ;; *) RISK="$RISK|$OCCUPANT|" ;; esac
done <<EOF
$CHANGED_UPSTREAM
EOF
if [ -n "$RISK" ]; then
  echo "WARNING: these files are dirty or untracked here AND changed on master:" >&2
  printf '%s\n' "$RISK" | tr '|' '\n' | grep -v '^$' | sed 's/^/  /' >&2
  echo "The reconciliation rebase would stash and replay the tracked ones, which" >&2
  echo "can conflict; an untracked one blocks its checkout outright, and an" >&2
  echo "ignored one would be silently overwritten." >&2
  echo "Land or commit them first, or accept the risk and re-run with -f." >&2
  [ "$FORCE" = 1 ] || [ "$DRY" = 1 ] || exit 3
fi

# A SELECTED path that also changed on master since the merge base would be
# overwritten wholesale by this landing, silently discarding the upstream
# edit. That is sometimes wanted (-f), never silent.
SELRISK=""
for p in "$@"; do
  if printf '%s\n' "$CHANGED_UPSTREAM" | grep -qxF -- "$p"; then
    [ "$(path_action "$p")" = unchanged ] && continue
    case "$SELRISK" in *"|$p|"*) ;; *) SELRISK="$SELRISK|$p|" ;; esac
  fi
done
if [ -n "$SELRISK" ]; then
  echo "WARNING: these named paths changed on master since this worktree's base:" >&2
  printf '%s\n' "$SELRISK" | tr '|' '\n' | grep -v '^$' | sed 's/^/  /' >&2
  echo "Landing would replace the upstream version with this worktree's content." >&2
  echo "Rebase the docs worktree first, or accept the overwrite and re-run with -f." >&2
  [ "$FORCE" = 1 ] || [ "$DRY" = 1 ] || exit 3
fi

# --- Dry run: report the full plan, change nothing -------------------------
if [ "$DRY" = 1 ]; then
  echo "plan: subject: $MSG"
  CHANGES=0
  for p in "$@"; do
    action="$(path_action "$p")"
    [ "$action" = unchanged ] || CHANGES=1
    echo "plan: land $p ($action)"
  done
  echo "plan: destination: origin/master at $(git rev-parse --short origin/master)"
  if [ "$CHANGES" = 0 ]; then
    echo "plan: nothing to land: the named paths already match origin/master"
  elif [ "$(git rev-parse HEAD)" = "$BASE_TIP" ]; then
    echo "plan: reconcile: fast-forward docs-wip to the landing commit"
  else
    echo "plan: reconcile: rebase docs-wip onto the landed master"
  fi
  echo "dry run: nothing was committed, pushed, or moved"
  exit 0
fi

# --- Build the landing commit directly on origin/master --------------------
# A temporary index seeded from origin/master takes the named paths' current
# worktree content (or their deletion) and nothing else, so neither the real
# index nor any commit already on docs-wip can leak an unselected change into
# what is pushed.
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/docs-land.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
TMP_INDEX="$TMP_DIR/index"
GIT_INDEX_FILE="$TMP_INDEX" git read-tree origin/master
for p in "$@"; do
  if [ -e "$p" ]; then
    BLOB="$(git hash-object -w -- "$p")"
    GIT_INDEX_FILE="$TMP_INDEX" git update-index --add --cacheinfo 100644 "$BLOB" "$p"
  else
    GIT_INDEX_FILE="$TMP_INDEX" git update-index --force-remove -- "$p"
  fi
done
TREE="$(GIT_INDEX_FILE="$TMP_INDEX" git write-tree)"

if [ "$TREE" = "$(git rev-parse "origin/master^{tree}")" ]; then
  # Not an early exit: a prior interrupted run may already have pushed this
  # content, and the reconciliation below still needs to finish that landing.
  echo "nothing to land: the named paths already match origin/master"
  LANDED="$BASE_TIP"
else
  LANDED="$(git commit-tree "$TREE" -p "$BASE_TIP" -m "$MSG")"
  # The protected-ref warning is expected on success and is NOT a failure;
  # equally, a zero exit is not proof. Reachability below is the verdict.
  git push origin "$LANDED:refs/heads/master" \
    || echo "push exited nonzero; verifying by rev-list anyway"

  # --- Verify by rev-list reachability, not by push output -----------------
  git fetch -q origin
  if [ "$(git rev-list --count "$LANDED" ^origin/master)" != 0 ]; then
    echo "error: the landing commit did not become reachable from origin/master; the push did not land" >&2
    exit 5
  fi
  echo "landed: origin/master now contains the landing commit"
fi

# --- Reconcile docs-wip with the landed master -----------------------------
if [ "$(git rev-parse HEAD)" = "$BASE_TIP" ]; then
  if [ "$LANDED" != "$BASE_TIP" ]; then
    # No local commits: move the branch to the landing commit and refresh the
    # index for exactly the landed paths. The worktree is untouched and every
    # unselected index entry keeps its staged/unstaged disposition.
    git update-ref refs/heads/docs-wip "$LANDED" "$BASE_TIP"
    GIT_LITERAL_PATHSPECS=1 git reset -q -- "$@"
    echo "docs-wip fast-forwarded to the landing commit"
  fi
else
  echo "docs-wip has local commits or an older base; rebasing onto the landed master"
  if ! git rebase --autostash origin/master; then
    echo "" >&2
    echo "Rebase stopped. The landing itself is complete and verified, and" >&2
    echo "this is contained to the docs worktree — it cannot wedge the PR" >&2
    echo "drainer. Resolve, 'git add' the files, then 'git rebase --continue'." >&2
    echo "If the autostash failed to reapply, your other edits are in" >&2
    echo "'git stash list'." >&2
    exit 4
  fi
fi
AHEAD="$(git rev-list --count origin/master..HEAD)"
if [ "$AHEAD" = 0 ]; then
  echo "docs-wip carries nothing unpushed beyond origin/master"
else
  echo "docs-wip still carries $AHEAD unpushed local commit(s), preserved for a later landing"
fi

# --- Fast-forward the primary checkout, but only if it is safe -------------
# `status --porcelain` alone is not enough: it omits ignored untracked
# files, and a fast-forward checkout silently overwrites an ignored file at
# a path the update touches — including one this very landing added. So the
# paths the fast-forward would change are probed for untracked or ignored
# occupants too, with the same presence test the pre-flight predictor uses.
if [ -n "$(git -C "$PRIMARY" status --porcelain)" ]; then
  echo "note: primary checkout is dirty; not fast-forwarding it"
else
  PRIMARY_OCCUPIED=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if OCCUPANT="$(occupied_untracked "$f" "$PRIMARY")"; then
      case "$PRIMARY_OCCUPIED" in *"|$OCCUPANT|"*) ;; *) PRIMARY_OCCUPIED="$PRIMARY_OCCUPIED|$OCCUPANT|" ;; esac
    fi
  done <<EOF
$(git -C "$PRIMARY" diff --name-only HEAD origin/master)
EOF
  if [ -n "$PRIMARY_OCCUPIED" ]; then
    echo "note: primary checkout has untracked or ignored files at paths the update touches; not fast-forwarding it:"
    printf '%s\n' "$PRIMARY_OCCUPIED" | tr '|' '\n' | grep -v '^$' | sed 's/^/  /'
  else
    git -C "$PRIMARY" merge --ff-only -q origin/master
    echo "primary checkout fast-forwarded"
  fi
fi
