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
# BEFORE doing anything when an unselected file collides with an upstream
# change — untracked, ignored, or dirty and unequal; judges success by rev-list
# reachability, never by push output; and fast-forwards the primary checkout
# only when it is clean and no untracked or ignored file occupies a path the
# update would touch.
#
# RECONCILE FIRST (issue: stale docs worktree). The landing commit is built
# from this worktree's bytes on top of origin/master, so landing from a
# worktree that is BEHIND master overwrites every upstream edit to a selected
# path with a stale copy. The pre-flight refuses that (exit 3), which is
# correct but leaves the operator stuck whenever the branch has drifted --
# the common state, since docs-wip only advances when something lands.
#
# So the worktree is reconciled with the publication tip BEFORE anything is
# computed or published: stash the dirty documents, fast-forward (or rebase,
# when there are real local commits), then re-apply the stash as a three-way
# merge. An edit already published upstream collapses to a no-op instead of a
# conflict, an untouched-upstream edit replays cleanly, and only a genuine
# same-region divergence stops -- with nothing yet published, so stopping is
# free. -a resolves such a divergence by favouring this worktree's side per
# hunk while keeping upstream's non-conflicting hunks. -R skips the whole
# stage and lands from the worktree exactly as it stands.
#
# Usage:
#   tools/docs_land.sh -m "Commit subject" docs/foo.md [docs/bar.md ...]
#   tools/docs_land.sh -n -m "..." docs/foo.md   # dry run: plan, no changes
#   tools/docs_land.sh -f -m "..." docs/foo.md   # ignore the risk warning
#   tools/docs_land.sh -a -m "..." docs/foo.md   # auto-resolve reconcile conflicts
#   tools/docs_land.sh -R -m "..." docs/foo.md   # do not reconcile first
#   tools/docs_land.sh -l                        # inventory of landable docs
#
# Exit codes: 0 landed (or nothing to land); 1 environment failure; 2 usage;
# 3 predicted conflict without -f; 4 rebase or reconcile stopped; 5 push not
# verified; 6 a named path was refused by validation or classification.
set -euo pipefail

DRY=0
FORCE=0
LIST=0
RECONCILE=1
AUTO=0
MSG=""
while getopts "m:nflaRh" opt; do
  case "$opt" in
    m) MSG="$OPTARG" ;;
    n) DRY=1 ;;
    f) FORCE=1 ;;
    l) LIST=1 ;;
    a) AUTO=1 ;;
    R) RECONCILE=0 ;;
    h) sed -n '2,40p' "$0"; exit 0 ;;
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
# A stopped rebase detaches HEAD, so the branch record disappears from the
# listing while rebase-merge/head-name (or rebase-apply/head-name) still
# names the branch being rebased. Prints the worktree in that state, if any.
rebasing_worktree() {
  git worktree list --porcelain \
    | awk '/^worktree /{print substr($0,10)}' \
    | while IFS= read -r _wt; do
        for _state in rebase-merge rebase-apply; do
          _head_file="$(git -C "$_wt" rev-parse --git-path "$_state/head-name" 2>/dev/null)" || continue
          if [ -f "$_head_file" ]; then
            IFS= read -r _rebased < "$_head_file" || continue
            if [ "$_rebased" = "refs/heads/$1" ]; then
              printf '%s\n' "$_wt"
              return 0
            fi
          fi
        done
      done
}
require_one() {
  # $1: branch name, $2: resolved paths (newline-separated)
  if [ -z "$2" ]; then
    _mid="$(rebasing_worktree "$1")"
    if [ -n "$_mid" ]; then
      echo "error: the worktree at $_mid has a rebase in progress on branch $1;" >&2
      echo "finish it with 'git rebase --continue' or abort it before landing" >&2
      exit 1
    fi
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

# Path lists and scratch files live in NUL-delimited temp files, never in
# shell variables: newline-delimited `git diff --name-only` C-quotes filenames
# containing quotes or non-ASCII bytes, so a `cafe.md` in such a list would
# never match its own on-disk path -- and a shell variable cannot hold a NUL
# byte. Created this early because the unmerged-path resolver below needs
# scratch space too, and one directory means one cleanup trap.
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/docs-land.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

# Resolve every unmerged path in favour of THIS worktree's side, hunk by
# hunk, keeping the other side's non-conflicting hunks -- what -a means.
#
# Deliberately indifferent to who created the conflict. A conflict this run
# produced (a stash re-apply during the reconcile) and one it merely found
# (a half-finished resolution from an earlier run) need the same treatment,
# and making -a work on both is what lets the operator recover by re-running
# instead of unpicking an index by hand. Stage 2 is the side already in the
# branch, stage 3 the side being applied onto it; -a is defined as favouring
# stage 3, which in the reconcile is the operator's own edit.
resolve_unmerged_favouring_theirs() {
  git diff --name-only --diff-filter=U -z > "$TMP_DIR/conflicted"
  [ -s "$TMP_DIR/conflicted" ] || return 0
  while IFS= read -r -d '' c; do
    [ -n "$c" ] || continue
    # Stage 1 is absent for an add/add conflict; an empty base makes
    # merge-file treat both sides as pure additions, which is the right
    # reading of "neither side had this text before".
    git show ":1:$c" > "$TMP_DIR/base" 2>/dev/null || : > "$TMP_DIR/base"
    git show ":2:$c" > "$TMP_DIR/ours"
    git show ":3:$c" > "$TMP_DIR/theirs"
    # -p writes the merge to stdout, straight over the conflicted file:
    # every byte it needs is already in stages 1-3, so truncating the
    # working copy first costs nothing and saves an intermediate write.
    # merge-file exits with the conflict COUNT, not a failure code, and
    # --theirs leaves none anyway.
    git merge-file --theirs -q -p \
      "$TMP_DIR/ours" "$TMP_DIR/base" "$TMP_DIR/theirs" > "$c" || true
    GIT_LITERAL_PATHSPECS=1 git add -- "$c"
  done < "$TMP_DIR/conflicted"
  echo "resolved in favour of this worktree:"
  tr '\0' '\n' < "$TMP_DIR/conflicted" | sed 's/^/  /'
}

# --- Refuse a docs worktree stopped mid-operation --------------------------
# A stopped rebase, merge, or conflicted stash application leaves worktree
# files half-replayed — possibly holding conflict markers — and a landing
# would hash exactly those bytes onto master. Nothing is read or landed
# until the operation is finished or aborted.
for _marker in rebase-merge rebase-apply; do
  if [ -d "$(git rev-parse --git-path "$_marker")" ]; then
    echo "error: the docs worktree has a rebase in progress; finish it with" >&2
    echo "'git rebase --continue' or abort it before landing" >&2
    exit 1
  fi
done
if [ -f "$(git rev-parse --git-path MERGE_HEAD)" ]; then
  echo "error: the docs worktree has a merge in progress; conclude or abort it before landing" >&2
  exit 1
fi
if [ -n "$(git ls-files -u)" ]; then
  if [ "$AUTO" = 1 ] && [ "$DRY" = 0 ]; then
    # -a is a standing instruction, not a per-conflict prompt: a worktree
    # left unmerged by an earlier run is exactly the state -a exists to
    # clear, and refusing it here would make the flag unusable as a retry.
    echo "note: -a given and the docs worktree has unmerged paths; resolving them first"
    resolve_unmerged_favouring_theirs
  else
    echo "error: the docs worktree has unmerged paths; resolve them before landing" >&2
    [ "$AUTO" = 1 ] || echo "Re-run with -a to resolve them in favour of this worktree." >&2
    exit 1
  fi
fi

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

# --no-renames: with rename detection, an upstream rename reports only its
# NEW name, so the old path — deleted upstream, perhaps edited and selected
# here — would vanish from this list and the risk checks below would let a
# landing silently reintroduce it. Every path list wants the plain
# delete-plus-add reading.
git diff --name-only -z --no-renames "$BASE" origin/master > "$TMP_DIR/changed-upstream"
{ git diff --name-only -z --no-renames
  git diff --cached --name-only -z --no-renames
} > "$TMP_DIR/dirty"

# Whether path $1 appears in the NUL-delimited list file $2.
in_nul_list() {
  while IFS= read -r -d '' _entry; do
    [ "$_entry" = "$1" ] && return 0
  done < "$2"
  return 1
}

_TAB="$(printf '\t')"
# Whether worktree $2's index holds an entry at EXACTLY path $1 — not merely
# beneath it, which is all a bare ls-files pathspec probe can say. The
# distinction is what separates a tracked file an upstream transition may
# replace from a tracked directory replaced on disk by something else.
tracked_exactly() {
  GIT_LITERAL_PATHSPECS=1 git -C "$2" ls-files -s -z -- "$1" > "$TMP_DIR/entry-probe"
  while IFS= read -r -d '' _entry; do
    case "$_entry" in
      *"$_TAB$1") return 0 ;;
    esac
  done < "$TMP_DIR/entry-probe"
  return 1
}

# Whether an occupant stands where $1 (repo-relative) would be checked out
# in worktree $2 ($3 is a NUL-delimited dirty list, /dev/null when the
# worktree is already known clean) — an untracked or ignored file or symlink
# at the leaf, or a non-directory at an ancestor component that git's own
# tracked transitions cannot account for. Prints the occupying path and
# returns zero when one is found.
#
# The ancestor rule: a checkout needs each ancestor as a real directory. A
# non-directory standing there is safe only when the index holds an entry at
# EXACTLY that path and the entry is clean — that is a tracked file (or
# symlink) an upstream file-to-directory transition replaces as ordinary
# tracked history. Anything else — untracked or ignored files and symlinks,
# a dirty tracked entry, or a tracked DIRECTORY replaced on disk (whose
# descendants still prefix-match the index while the exact path has no
# entry) — is replaced or refused by the checkout, so it is an occupant. An
# untracked real directory ancestor is not: checkout creates files inside it
# without clobbering anything.
occupied_untracked() {
  _rest="$1"
  _prefix=""
  while [ -n "$_rest" ]; do
    case "$_rest" in
      */*) _seg="${_rest%%/*}"; _rest="${_rest#*/}" ;;
      *) _seg="$_rest"; _rest="" ;;
    esac
    if [ -z "$_prefix" ]; then _prefix="$_seg"; else _prefix="$_prefix/$_seg"; fi
    if [ "$_prefix" != "$1" ]; then
      if [ -L "$2/$_prefix" ] \
          || { [ -e "$2/$_prefix" ] && [ ! -d "$2/$_prefix" ]; }; then
        if ! tracked_exactly "$_prefix" "$2" || in_nul_list "$_prefix" "$3"; then
          printf '%s\n' "$_prefix"
          return 0
        fi
        # A clean, exactly-tracked non-directory ancestor is git's own
        # transition to perform, and nothing exists beneath it locally.
        return 1
      fi
      # Absent means nothing deeper exists; a real directory means descend.
      [ -d "$2/$_prefix" ] || return 1
    else
      if [ -d "$2/$_prefix" ] && [ ! -L "$2/$_prefix" ]; then
        # Upstream wants a FILE at this path but a directory stands on
        # disk. Git replaces a directory only when nothing untracked lives
        # inside it, so any untracked or ignored child — --others without
        # --exclude-standard includes the ignored ones — is the occupant
        # the reconciliation would abort on or lose, after publication.
        # Tracked children are their own upstream-change entries and are
        # handled as ordinary tracked transitions.
        _child=""
        while IFS= read -r -d '' _c; do _child="$_c"; break; done \
          < <(GIT_LITERAL_PATHSPECS=1 git -C "$2" ls-files --others -z -- "$_prefix")
        if [ -n "$_child" ]; then
          printf '%s\n' "$_child"
          return 0
        fi
        return 1
      fi
      if { [ -e "$2/$_prefix" ] || [ -L "$2/$_prefix" ]; } \
          && ! GIT_LITERAL_PATHSPECS=1 git -C "$2" ls-files --error-unmatch -- "$_prefix" >/dev/null 2>&1; then
        printf '%s\n' "$_prefix"
        return 0
      fi
      return 1
    fi
  done
  return 1
}

# The Git mode a selected path lands with, and the mode it has upstream.
# Only regular files reach these — the gate refuses symlinks — so the whole
# mode question is the executable bit.
path_mode() {
  if [ -x "$1" ]; then echo 100755; else echo 100644; fi
}
upstream_mode() {
  git ls-tree origin/master -- "$1" | { IFS=' ' read -r _mode _rest; echo "$_mode"; }
}

# What landing each path would do to origin/master's tree.
path_action() {
  # $1: path. Prints add | modify | mode | delete | unchanged. `mode` is an
  # executable-bit-only change: same content, different Git mode — a real
  # difference the landing must carry rather than report as unchanged.
  if [ -e "$1" ]; then
    if git cat-file -e "origin/master:$1" 2>/dev/null; then
      if [ "$(git hash-object -- "$1")" != "$(git rev-parse "origin/master:$1")" ]; then
        echo modify
      elif [ "$(path_mode "$1")" != "$(upstream_mode "$1")" ]; then
        echo mode
      else
        echo unchanged
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

# The Git mode recorded at EXACTLY path $1 by the NUL-delimited `ls-tree`
# or `ls-files -s` listing in file $2 — both put the mode first — or
# nothing when the listing holds no entry there.
#
# Exact-path matching for the same reason tracked_exactly needs it: a bare
# pathspec probe also matches entries BENEATH a directory. upstream_mode
# above is the loose sibling and stays that way; it only ever sees a
# SELECTED path the gate already validated, while this one is asked about
# arbitrary upstream-changed paths whose names may carry glob metacharacters.
entry_mode() {
  while IFS= read -r -d '' _rec; do
    case "$_rec" in
      *"$_TAB$1") printf '%s\n' "${_rec%% *}"; return 0 ;;
    esac
  done < "$2"
  return 1
}

# Whether the dirty tracked path $1 already holds exactly what the
# reconciliation would check out, so the replay can neither conflict on it
# nor lose an edit.
#
# `git rebase --autostash` stashes the dirty state and pops it WITHOUT
# --index, so only the WORKING-TREE side of the stash survives. When that
# side already equals origin/master's entry, both sides of the replay merge
# carry the same thing and the merge resolves to it either way.
#
# "Equals" is blob AND MODE, for all three of upstream, the working tree,
# and any staged entry. Content alone is not enough: an index entry can
# hold upstream's blob under a different mode — `git update-index --chmod`
# does exactly that without touching the file — and the pop, having no
# --index, collapses that staged executable bit away silently. Requiring
# all three modes to agree makes the merge result unambiguous and leaves
# the index entry equal to it, so nothing is discarded. A staged entry that
# differs in either respect keeps the path at risk however the working tree
# looks.
#
# Fail-closed everywhere else, because a match has to be against a real
# upstream file: an upstream deletion leaves nothing to equal, and locally
# only a regular file has the bytes a checkout would compare — git
# hash-object FOLLOWS a symlink, so a link onto a copy of upstream's content
# hashes equal while what git tracks there is a target string that does not.
# The `cat-file -t` type check is deliberately explicit rather than left to
# the sha comparison: it says outright that a file-to-directory transition
# offers no blob to match, instead of relying on a tree's object name never
# colliding with a blob's.
#
# --no-filters: raw working-tree bytes, never a filtered hash. A clean
# filter or an end-of-line conversion would report a file differing only in
# trailing whitespace or CRLF/LF as a match, which it is not.
matches_upstream_blob() {
  _upstream="$(git rev-parse --verify --quiet "origin/master:$1")" || return 1
  [ "$(git cat-file -t "$_upstream" 2>/dev/null)" = blob ] || return 1
  GIT_LITERAL_PATHSPECS=1 git ls-tree -z origin/master -- "$1" \
    > "$TMP_DIR/upstream-entry"
  _upstream_mode="$(entry_mode "$1" "$TMP_DIR/upstream-entry")" || return 1
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  [ "$(git hash-object --no-filters -- "$1" 2>/dev/null)" = "$_upstream" ] || return 1
  [ "$(path_mode "$1")" = "$_upstream_mode" ] || return 1
  if ! GIT_LITERAL_PATHSPECS=1 git diff --cached --quiet --no-renames -- "$1"; then
    _staged="$(git rev-parse --verify --quiet ":0:$1")" || return 1
    [ "$_staged" = "$_upstream" ] || return 1
    GIT_LITERAL_PATHSPECS=1 git ls-files -s -z -- "$1" > "$TMP_DIR/index-entry"
    _staged_mode="$(entry_mode "$1" "$TMP_DIR/index-entry")" || return 1
    [ "$_staged_mode" = "$_upstream_mode" ] || return 1
  fi
  return 0
}

# --- Pre-flight: predict a reconciliation conflict before touching anything -
# Files that are dirty or untracked here, NOT being landed, and ALSO changed
# on master since our merge base are the ones the reconciliation rebase
# stumbles on: a tracked dirty file is autostashed and can conflict on
# replay, an untracked file that master newly adds is never stashed at all so
# the rebase's checkout refuses it outright, and an untracked file that is
# also IGNORED is worse — checkout silently overwrites it.
#
# The bare intersection overstates the TRACKED hazard, though: a dirty
# tracked file that already holds origin/master's exact blob and mode is
# what the replay produces anyway, and blocking on it refuses a landing
# over a file holding nothing. matches_upstream_blob narrows that arm to a
# content-and-mode comparison and lets those through. The untracked and ignored arms are
# unnarrowed on purpose — checkout refuses an untracked occupant and
# silently overwrites an ignored one without ever comparing content, so
# byte-equality buys them nothing.
#
# It is all detected here, before anything is published, by walking the
# (small) upstream-changed set and asking about each path's local state —
# presence on disk without an index entry covers untracked and ignored
# alike, which an --exclude-standard listing would not. Written for bash 3.2
# (macOS /bin/bash): no mapfile, no bare expansion of a possibly-empty array
# under `set -u`.
: > "$TMP_DIR/risk"
while IFS= read -r -d '' f; do
  [ -n "$f" ] || continue
  landing=0
  for p in "$@"; do [ "$f" = "$p" ] && landing=1; done
  [ "$landing" = 1 ] && continue
  at_risk=0
  OCCUPANT="$f"
  if in_nul_list "$f" "$TMP_DIR/dirty" && ! matches_upstream_blob "$f"; then
    at_risk=1
  elif OCCUPANT="$(occupied_untracked "$f" "$DOCS_WT" "$TMP_DIR/dirty")"; then
    # occupied_untracked rather than a bare -e test: a dangling symlink
    # fails -e yet still occupies its path, and an untracked or ignored
    # symlink at an ANCESTOR component is replaced just the same when the
    # checkout needs that component as a real directory.
    at_risk=1
  fi
  [ "$at_risk" = 1 ] || continue
  if ! in_nul_list "$OCCUPANT" "$TMP_DIR/risk"; then
    printf '%s\0' "$OCCUPANT" >> "$TMP_DIR/risk"
  fi
done < "$TMP_DIR/changed-upstream"
if [ -s "$TMP_DIR/risk" ]; then
  echo "WARNING: these files are dirty or untracked here AND changed on master:" >&2
  tr '\0' '\n' < "$TMP_DIR/risk" | sed 's/^/  /' >&2
  echo "The reconciliation rebase would stash and replay the tracked ones, which" >&2
  echo "can conflict; an untracked one blocks its checkout outright, and an" >&2
  echo "ignored one would be silently overwritten." >&2
  echo "Land or commit them first, or accept the risk and re-run with -f." >&2
  [ "$FORCE" = 1 ] || [ "$DRY" = 1 ] || exit 3
fi

# Selected paths that existed at the pre-reconcile base and are GONE from the
# publication tip: upstream deleted them, a rename's delete half included.
# Recorded HERE, before the reconcile, because afterwards the two states are
# indistinguishable from an ordinary new document -- and the difference
# matters: re-adding one is resurrecting what upstream removed.
: > "$TMP_DIR/upstream-deleted"
for p in "$@"; do
  if git cat-file -e "$BASE:$p" 2>/dev/null \
     && ! git cat-file -e "origin/master:$p" 2>/dev/null; then
    printf '%s\0' "$p" >> "$TMP_DIR/upstream-deleted"
  fi
done

RECONCILED=0
# --- Reconcile the docs worktree with the publication tip ------------------
# Runs BEFORE the gate, the risk pre-flight and the landing commit, because
# every one of those reads the worktree's bytes and would otherwise be
# reasoning about a stale copy. See the RECONCILE FIRST note in the header.
#
# Untracked files are deliberately NOT stashed (`git stash push` without -u):
# a scratch or ignored file beside the documents is not part of the landing
# and must not be swept into a stash the operator then has to remember to
# recover. The pre-flight below still reports one that collides with an
# upstream change.
#
# Scope: docs-wip PURELY BEHIND the tip -- an ancestor of origin/master, so
# it carries no unpushed local commits. That is the state this stage exists
# for, and it is the overwhelmingly common one, because docs-wip only ever
# advances when a landing pushes it. A branch that does carry local commits
# is left to the post-landing rebase below, unchanged: replaying real commits
# is a different operation from replaying uncommitted edits, and folding the
# two into one stage would mean stashing documents that a rebase then has to
# reapply over each replayed commit in turn.
if [ "$RECONCILE" = 1 ] \
   && ! git merge-base --is-ancestor origin/master HEAD \
   && git merge-base --is-ancestor HEAD origin/master; then
  BEHIND="$(git rev-list --count HEAD..origin/master)"
  DIRTY=0
  git diff --quiet || DIRTY=1
  git diff --cached --quiet || DIRTY=1

  if [ "$DRY" = 1 ]; then
    echo "plan: reconcile: docs-wip is $BEHIND commit(s) behind origin/master"
    echo "plan: reconcile: would fast-forward docs-wip to origin/master"
    if [ "$DIRTY" = 1 ]; then
      echo "plan: reconcile: would re-apply the dirty documents as a three-way merge"
      echo "plan: note: the warnings below are computed BEFORE that reconcile, so they overstate the risk"
    fi
  else
    echo "reconciling: docs-wip is $BEHIND commit(s) behind origin/master"
    STASH_REF=""
    if [ "$DIRTY" = 1 ]; then
      git stash push -q -m "docs_land.sh reconcile" \
        || { echo "error: could not stash the dirty documents" >&2; exit 4; }
      STASH_REF="$(git rev-parse --verify refs/stash)"
    fi
    git merge --ff-only -q origin/master
    if [ -n "$STASH_REF" ]; then
      # --index so a staged entry stays staged. One attempt only: a failed
      # apply has already written its conflict into the worktree, so a second
      # apply would be replaying onto that half-merged state. Which failure
      # it was is read from the index -- unmerged entries mean a content
      # conflict to resolve, anything else is a real error.
      if ! git stash apply --index -q "$STASH_REF" 2>"$TMP_DIR/stash-err"; then
        if [ -z "$(git ls-files -u)" ]; then
          echo "error: could not re-apply the stashed documents:" >&2
          sed 's/^/  /' < "$TMP_DIR/stash-err" >&2
          echo "Nothing was published. Your edits are in 'git stash list'." >&2
          exit 4
        fi
        if [ "$AUTO" = 1 ]; then
          resolve_unmerged_favouring_theirs
        else
          # The markers STAY in the worktree. That is what makes a manual
          # resolution possible, and the up-front guard above lets a re-run
          # with -a clear them instead -- so both routes forward work from
          # exactly this state, and neither needs the operator to unpick an
          # index by hand first.
          git diff --name-only --diff-filter=U -z > "$TMP_DIR/conflicted"
          echo "" >&2
          echo "Reconcile conflict in:" >&2
          tr '\0' '\n' < "$TMP_DIR/conflicted" | sed 's/^/  /' >&2
          echo "" >&2
          echo "NOTHING has been published. docs-wip has been fast-forwarded" >&2
          echo "to origin/master and the conflict is in the worktree." >&2
          echo "" >&2
          echo "Either resolve the markers and 'git add' them, then re-run," >&2
          echo "or re-run with -a to resolve every conflicting hunk in favour" >&2
          echo "of your side while keeping upstream's other hunks." >&2
          exit 4
        fi
      fi
      if [ "$(git rev-parse --verify --quiet refs/stash || true)" = "$STASH_REF" ]; then
        git stash drop -q
      fi
    fi
    RECONCILED=1
    echo "reconciled: docs-wip is at origin/master with its documents re-applied"
  fi
fi

# --- Recompute every upstream-relative fact against the reconciled state ---
# BASE, BASE_TIP and both path lists were read before the reconcile, when the
# worktree still sat on an older base. The selected-path overwrite check and
# the landing commit below must reason about where the worktree is NOW, or
# the reconcile would be invisible to exactly the check it exists to satisfy.
if [ "$DRY" = 0 ] && [ "$RECONCILED" = 1 ]; then
  BASE_TIP="$(git rev-parse origin/master)"
  BASE="$(git merge-base HEAD origin/master)"
  git diff --name-only -z --no-renames "$BASE" origin/master > "$TMP_DIR/changed-upstream"
  { git diff --name-only -z --no-renames
    git diff --cached --name-only -z --no-renames
  } > "$TMP_DIR/dirty"
fi

# A SELECTED path upstream DELETED that the reconcile has just replayed back
# onto disk. The landing would re-add it, silently undoing an upstream
# removal or the delete half of an upstream rename -- and unlike the
# overwrite case below, nothing in the resulting diff would show that a
# deletion was reverted rather than a document created.
if [ "$RECONCILED" = 1 ] && [ -s "$TMP_DIR/upstream-deleted" ]; then
  : > "$TMP_DIR/resurrect"
  : > "$TMP_DIR/vanished"
  while IFS= read -r -d '' p; do
    if [ -e "$p" ]; then
      printf '%s\0' "$p" >> "$TMP_DIR/resurrect"
    else
      printf '%s\0' "$p" >> "$TMP_DIR/vanished"
    fi
  done < "$TMP_DIR/upstream-deleted"
  # Selected, deleted upstream, and gone from the worktree after the
  # reconcile: there is nothing left to land under that name, and saying
  # only "nothing to land" would leave the operator thinking their edit
  # evaporated. It did not -- `git stash apply` follows renames, so an edit
  # to a path upstream RENAMED is sitting on the new name, still dirty and
  # still landable once it is named. Reported rather than refused, because
  # the reconcile did the right thing and there is nothing to decide.
  if [ -s "$TMP_DIR/vanished" ]; then
    echo "note: upstream deleted or renamed these selected paths, so they no longer exist here:"
    tr '\0' '\n' < "$TMP_DIR/vanished" | sed 's/^/  /'
    echo "note: an edit to a RENAMED path followed the rename and is still dirty under its new name;"
    echo "note: check 'git status' in the docs worktree and name that path instead."
  fi
  if [ -s "$TMP_DIR/resurrect" ]; then
    echo "WARNING: upstream deleted these selected paths, and the reconcile replayed them back:" >&2
    tr '\0' '\n' < "$TMP_DIR/resurrect" | sed 's/^/  /' >&2
    echo "Landing would re-add them, reverting the upstream deletion (or the" >&2
    echo "delete half of an upstream rename). Drop them from the selection, or" >&2
    echo "accept the resurrection and re-run with -f." >&2
    [ "$FORCE" = 1 ] || [ "$DRY" = 1 ] || exit 3
  fi
fi

# A SELECTED path that also changed on master since the merge base would be
# overwritten wholesale by this landing, silently discarding the upstream
# edit. That is sometimes wanted (-f), never silent.
SELRISK=""
for p in "$@"; do
  if in_nul_list "$p" "$TMP_DIR/changed-upstream"; then
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
TMP_INDEX="$TMP_DIR/index"
GIT_INDEX_FILE="$TMP_INDEX" git read-tree origin/master
for p in "$@"; do
  if [ -e "$p" ]; then
    BLOB="$(git hash-object -w -- "$p")"
    GIT_INDEX_FILE="$TMP_INDEX" git update-index --add --cacheinfo "$(path_mode "$p")" "$BLOB" "$p"
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
elif [ "$(git -C "$PRIMARY" rev-parse HEAD)" = "$(git -C "$PRIMARY" rev-parse origin/master)" ]; then
  echo "primary checkout already at origin/master"
elif ! git -C "$PRIMARY" merge-base --is-ancestor HEAD origin/master; then
  # A clean checkout with local commits is not fast-forwardable, and letting
  # merge --ff-only fail here would report the whole run — publication
  # included — as a failure it was not.
  echo "note: primary checkout has local commits not on origin/master; not fast-forwarding it"
else
  git -C "$PRIMARY" diff --name-only -z --no-renames HEAD origin/master > "$TMP_DIR/primary-changed"
  : > "$TMP_DIR/primary-occupied"
  while IFS= read -r -d '' f; do
    [ -n "$f" ] || continue
    if OCCUPANT="$(occupied_untracked "$f" "$PRIMARY" /dev/null)"; then
      if ! in_nul_list "$OCCUPANT" "$TMP_DIR/primary-occupied"; then
        printf '%s\0' "$OCCUPANT" >> "$TMP_DIR/primary-occupied"
      fi
    fi
  done < "$TMP_DIR/primary-changed"
  if [ -s "$TMP_DIR/primary-occupied" ]; then
    echo "note: primary checkout has untracked or ignored files at paths the update touches; not fast-forwarding it:"
    tr '\0' '\n' < "$TMP_DIR/primary-occupied" | sed 's/^/  /'
  else
    git -C "$PRIMARY" merge --ff-only -q origin/master
    echo "primary checkout fast-forwarded"
  fi
fi
