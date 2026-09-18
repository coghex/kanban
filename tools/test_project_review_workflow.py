"""The vendored project-review workflow's own behavioral contract.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 tools/test_project_review_workflow.py

Issue #462, slice VEND-4 of `docs/designs/workflow_command_vendoring_design.md` — the
heaviest reconciliation in the arc. The two personal copies implemented
*opposite* terminal acts over 223 differing lines: the Claude copy drafted issue
bodies, stopped for approval, and filed them, while the Codex copy forbade
tracker writes outright and wrote a canonical findings report instead. Design
D-9 resolved that in favour of the Codex copy, so what both bundles now ship is
report-only. Three consequences follow, and each is asserted here rather than
left to review.

* **Report-only is a property of the document, not a promise about it.** A
  rendered body that said "never create an issue" while still carrying a
  tracker-creating call would read, to the agent executing it top to bottom, as
  permission. So the prohibition is checked as an absence — no `gh` call outside
  the declared ones, no issue creation, no origin-routing marker, and since
  issue #684 no committing or pushing instruction of any kind — and the terminal
  act is pinned as the one report write and the one helper-made checkpoint.
* **Every `gh` call names the repository.** Design D-5 requires it of all eight
  vendored commands. This one never mutates a tracker, so a wrong repository
  costs no data — it costs the whole run, which is spent reviewing code the user
  did not ask about and reported as if it were theirs. The calls are pinned
  exactly: six spellings over seven invocations, with `-R "$REPO"` on the five
  pull-request and issue reads and `$REPO`'s own owner and name on the inventory
  query. (`gh pr view` is the one taken twice: once for the reviewed pull
  request and once to verify a pull request claimed to have fixed an earlier
  finding.) The resolution that fills `$REPO` reads the remote with `git` and
  `sed`, so an initial `gh repo view` — a GitHub call made before the identity
  every other call depends on exists — is refused by name.
* **The four Codex-only capabilities reach both brands.** Requirement 4: direct
  commit mode with its cursor rules, the report-filename rules, and the
  `Captured note` / `Verification` / `Evidence` / `Handoff context` capture
  shape existed in one copy only, and each is downstream of writing a report
  rather than an issue body. They are pinned per brand, because a capability
  that survived for one provider and not the other is exactly what the shared
  source exists to prevent.

Issue #684, slice LEDGER-6 of `docs/designs/project_review_ledger_design.md`,
rebuilt the PR half of that workflow on the ledger #680–#683 delivered and the
session liveness adapter #687 delivered. The twelve-unit sweep is gone from PR
mode: a successful invocation reviews **exactly one** merged pull request,
chosen by `project_review_ledger.py` from a complete paginated inventory,
claimed under a lease whose liveness is the adapter's keeper, verified against a
detached worktree pinned to the fetched remote default-branch head, reported
into a name the helper allocates, and recorded as one checkpoint the helper
makes. Four properties shape what is asserted here, and each names a way the
rebuild could have gone wrong silently:

* **One review, and no path back to a second.** The old document ended in
  "Complete and continue", which reviewed the next batch on `continue` and
  entered direct-commit mode once PR history ran out. Both are now defects
  rather than features (design D-2 and D-16), and neither is provable by
  reading what the document says: an asset that promised one review while still
  carrying a continuation instruction reads, top to bottom, as permission for
  the second. So the repetition instructions are pinned as an **absence** over
  the whole rendered body, and the explicit-only rule is pinned as prose beside
  it.
* **The cursor survives, in one section only.** Direct-commit mode keeps
  `project_review_cursor.py` unchanged until LEDGER-8 retires it (D-19 as
  amended), so "the asset names the cursor" cannot distinguish the rebuilt
  document from the one it replaced. What distinguishes them is *where*: every
  cursor invocation and every cursor rule now lives below the direct-mode
  heading, and PR mode names the cursor nowhere. The section split is therefore
  the unit of assertion, and `test_pr_mode_names_no_cursor_invocation` is the
  negative control that keeps the ledger pins from passing vacuously on a
  document that still ran its PR sweep off the cursor.
* **Every exit cleans up, and a failed cleanup is not a clean one.** D-13's
  cleanup runs on a completed record, a refusal, a failed fetch, a takeover and
  a cancellation alike, and reports the path it retained rather than claiming
  removal. Both halves are pinned: an asset that listed the three steps without
  the retained-path rule would leave an orphan nobody knows to look for.
* **A flagged migration stops.** `migrate` writes nothing while a report is
  flagged, and the flag is a question only the operator can answer (D-9). An
  asset that continued past it would either mark unreviewed pull requests
  reviewed or re-review work somebody already did, and the ledger records
  neither recoverably.

The rest is D-2's preserved behavior (requirement 9): the newest-first order,
the issue-as-proposed-specification judgement, the nits-are-not-findings bar,
the fixed-later and already-tracked one-liner handling, and the clean-review
rule that writes no report but still records its attempt are vendored as they
read today, so each is pinned rather than merely rendered.

`project_review_cursor.py` still ships in both bundles and still owns the state
document and reconciliation for direct mode. The `Cursor*` cases below exercise
that module as real state transitions — clean and finding-bearing batches
preserve coverage without moving the boundary, explicit exclusions persist,
legacy prose boundaries migrate without losing exceptional reviewed PRs, and
direct mode retains its moving older-history frontier. Each transition carries
a negative control that varies the relevant coverage or boundary field, so the
assertions prove which part of the state actually governs selection. Its PR-mode
half is now exercised here alone — the workflow no longer calls it — and it is
kept because `project_review_ledger.py migrate` reads exactly those recorded PR
endpoints when it imports a consumer's legacy coverage.

`LedgerEndToEndTests` is the arc's end-to-end proof (issue #684, requirement
11). It drives the shipped ledger and liveness modules through the invocation
order both rendered assets spell, in temporary repositories with temporary docs
worktrees and a fake `gh` on a temporary `PATH`, and it asserts the claims the
design makes rather than the ones the helpers report about themselves: what a
checkpoint contains is read back out of Git, and what a lapsed lease permits is
read back out of the ledger. No test here reaches the network, spawns a model,
or touches a real repository.

The prose pins stay beside all of it and neither half stands in for the other:
the rendered asset is the program an agent executes, so what it says about the
ledger is a contract in its own right, while what the mechanism does with the
ledger is one a substring check cannot reach.

The negative control for the prose half is the brand boundary itself:
`BrandBoundaryTests` asserts that stripping the declared brand-specific
lines leaves two byte-identical bodies, so a rule that quietly matched
everything could not also pass there.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

import render_command_sources as renderer

REPO_ROOT = Path(__file__).resolve().parent.parent

SOURCE = "tools/command_sources/project-review.md"
CLAUDE_ASSET = "claude-plugin/plugins/kanban/commands/project-review.md"
CODEX_ASSET = "codex-plugin/plugins/kanban/skills/project-review/SKILL.md"
RENDERED_ASSETS = (CLAUDE_ASSET, CODEX_ASSET)

BUNDLE_ROOTS = ("claude-plugin", "codex-plugin")

# The three modules that ship beside the command, vendored the way the
# trusted-comment helper is: a copy in each bundle held byte-identical, and no
# tracked original under tools/ because nothing in this repository invokes
# them. The workflow runs in whatever repository it was pointed at, which
# tracks no copy of anything, so a helper has to travel with the command that
# calls it.
BUNDLED_HELPERS = {
    "ledger": {
        "claude": "claude-plugin/plugins/kanban/scripts/project_review_ledger.py",
        "codex": (
            "codex-plugin/plugins/kanban/skills/project-review/scripts/"
            "project_review_ledger.py"
        ),
    },
    "liveness": {
        "claude": "claude-plugin/plugins/kanban/scripts/project_review_liveness.py",
        "codex": (
            "codex-plugin/plugins/kanban/skills/project-review/scripts/"
            "project_review_liveness.py"
        ),
    },
    "cursor": {
        "claude": "claude-plugin/plugins/kanban/scripts/project_review_cursor.py",
        "codex": (
            "codex-plugin/plugins/kanban/skills/project-review/scripts/"
            "project_review_cursor.py"
        ),
    },
}

CLAUDE_CURSOR_HELPER = BUNDLED_HELPERS["cursor"]["claude"]
CODEX_CURSOR_HELPER = BUNDLED_HELPERS["cursor"]["codex"]
CURSOR_HELPERS = BUNDLED_HELPERS["cursor"]

# How each brand's rendered asset resolves them. Neither spelling is a path
# into the reviewed repository: the helpers ship with the bundle, so each is
# resolved against the bundle's own install location.
HELPER_LOOKUPS = {
    "claude": (
        'LEDGER="${CLAUDE_PLUGIN_ROOT}/scripts/project_review_ledger.py"',
        'LIVENESS="${CLAUDE_PLUGIN_ROOT}/scripts/project_review_liveness.py"',
        'CURSOR="${CLAUDE_PLUGIN_ROOT}/scripts/project_review_cursor.py"',
    ),
    "codex": (
        'BUNDLE="$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" -path '
        "'*/kanban/*/skills/project-review/scripts/project_review_ledger.py' "
        '2>/dev/null | head -n1)"',
        'LIVENESS="$(dirname "$BUNDLE")/project_review_liveness.py"',
        'CURSOR="$(dirname "$BUNDLE")/project_review_cursor.py"',
    ),
}

# A lookup that would resolve nothing wherever this command actually installs.
REFUSED_HELPER_LOOKUPS = (
    "$DOCS_WT/project_review_ledger.py",
    "$ROOT/tools/project_review_ledger.py",
    "$DOCS_WT/project_review_cursor.py",
    "$ROOT/tools/project_review_cursor.py",
)

# The ledger invocations PR mode makes, in the order it makes them. `read`
# comes first because the migration decision is taken from it; `claim` selects
# and claims under one lock, so there is no separate `select` call to make.
LEDGER_INVOCATIONS = (
    'python3 "$LEDGER" read --root "$DOCS_WT" --repo "$REPO"',
    'python3 "$LEDGER" migrate --root "$DOCS_WT" --repo "$REPO"',
    'python3 "$LEDGER" claim --root "$DOCS_WT" --repo "$REPO" --owner-pid "$KEEPER"',
    'python3 "$LEDGER" allocate-report --root "$DOCS_WT" --repo "$REPO" --pr "$PR" --token "$TOKEN"',
    'python3 "$LEDGER" record --root "$DOCS_WT" --repo "$REPO" --pr "$PR" --token "$TOKEN"',
    'python3 "$LEDGER" release --root "$DOCS_WT" --repo "$REPO" --pr "$PR" --token "$TOKEN"',
)

# The liveness invocations, which bracket the claim: the nonce and the
# registration before it, the completion after it.
LIVENESS_INVOCATIONS = (
    'python3 "$LIVENESS" nonce',
    'python3 "$LIVENESS" complete --root "$DOCS_WT" --attempt "$ATTEMPT"',
)

# Per brand, because `--runtime` is what binds the registration to the runtime
# whose hooks are firing, and a Codex asset telling its reader to register as
# `claude` would refuse with `runtime-mismatch` on every invocation.
REGISTRATION = {
    "claude": (
        'python3 "${CLAUDE_PLUGIN_ROOT}/scripts/project_review_liveness.py" register '
        '--runtime claude --root "$DOCS_WT" --repo "$REPO" --nonce '
    ),
    "codex": (
        'python3 "$(dirname "$BUNDLE")/project_review_liveness.py" register '
        '--runtime codex --root "$DOCS_WT" --repo "$REPO" --nonce '
    ),
}

# The wrapped launch, spelled the same way and for the same reason.
WRAPPED_LAUNCH = {
    "claude": (
        'python3 "${CLAUDE_PLUGIN_ROOT}/scripts/project_review_liveness.py" run '
        '--root "$DOCS_WT" --attempt "$ATTEMPT" --launch build -- <command>'
    ),
    "codex": (
        'python3 "$(dirname "$BUNDLE")/project_review_liveness.py" run '
        '--root "$DOCS_WT" --attempt "$ATTEMPT" --launch build -- <command>'
    ),
}

# The nonce reaches the hook through the registering tool call's own command
# text, so an unexpanded shell variable in that text names no registration at
# all. Pinned as prose and as the absence of the spelling that would fail.
LITERAL_NONCE_RULE = (
    "A shell variable will not do, for either half of that line. The adapter's "
    "lifecycle hook fires *before* this command runs and reads the text the "
    "tool call was given, so what it sees is the unexpanded source: it "
    "recognizes a registration by `project_review_liveness.py` followed by "
    "`register`, and takes the attempt's nonce from the digits beside "
    "`--nonce`."
)
LITERAL_PATH_RULE = (
    "That is why this one command spells the helper's path out where every "
    "other call below uses `$LIVENESS`."
)
REFUSED_NONCE_SUBSTITUTION = '--nonce "$NONCE"'
REFUSED_REGISTRATION_PATH = '"$LIVENESS" register'

# The three substitutes requirement 2 forbids, each of them a lifetime that is
# not this review invocation's.
REFUSED_LIVENESS_FALLBACKS = (
    "Never substitute this session's own application process for the keeper, "
    "never name some other long-lived pid as `--owner-pid`, and never fall back "
    "to a descriptor that closes when one tool call ends"
)

# The three invocations the direct-commit section makes, and nothing else makes
# them. Since #684 the PR path touches the cursor nowhere.
CURSOR_INVOCATIONS = (
    'python3 "$CURSOR" select --root "$DOCS_WT" --repo "$REPO" --mode direct',
    '--mode direct --count "${COUNT:-12}" --start "$RANGE_START" --end "$RANGE_END"',
    'python3 "$CURSOR" record --root "$DOCS_WT" --repo "$REPO" --mode direct',
    'python3 "$CURSOR" read --root "$DOCS_WT" --repo "$REPO"',
)

# The PR-mode cursor invocations the rebuild removed. Pinned by name, because
# an asset that kept one of them would be running its PR sweep off the cursor
# while every ledger assertion above still passed.
REFUSED_PR_CURSOR_INVOCATIONS = (
    '"$CURSOR" select --root "$DOCS_WT" --repo "$REPO" --mode pr',
    '"$CURSOR" record --root "$DOCS_WT" --repo "$REPO" --mode pr',
    "--mode pr",
)

# The direct-mode walk, which is the whole first-parent history rather than a
# slice beginning at the entry point. A sliced walk would leave the recorded
# endpoint outside the listing the helper positions within, and the helper
# would then refuse it as a foreign cursor on every later batch -- a fail-closed
# stop, but one produced by the caller rather than by any real disagreement.
DIRECT_WALK = 'git -C "$ROOT" log --first-parent --format=%H \\'
REFUSED_SLICED_DIRECT_WALK = "--format=%H <entry-point>"

# The heading the rendered body is split at. Everything above it is PR mode,
# everything from it down is the explicit-only direct section.
DIRECT_SECTION_HEADING = "## Direct-commit mode — explicit request only"

# A `gh` invocation as the assets actually spell them, in a fenced block or in
# inline code. The lookbehind keeps a `gh` that ends a longer word out, and the
# required lowercase subcommand keeps the prose mentions of a "`gh` call" out:
# what is left is only text an agent would run.
GH_INVOCATION_RE = re.compile(r"(?<![\w-])gh (?P<tail>[a-z][^\n`]*)")

# The six GitHub reads the workflow makes, by the leading words that identify
# each, in the order the document introduces them. Every one is a read: this
# workflow performs no tracker mutation at all, which is the whole of D-9.
#
# `api graphql` is issue #684's: the ledger's selection needs the *complete*
# merged-pull-request history as numbered pages ending in a short one (design
# D-11), and `gh pr list` offers no page after its first. It is the one read
# that cannot carry `-R`, so it names the same `$REPO` by its two halves
# instead, and `test_every_github_call_names_the_resolved_repository` reads it
# that way rather than exempting it.
#
# `gh issue view` is the linked-issue read, and it is load-bearing rather than
# decorative: the workflow's central judgement is the merged diff against what
# the issue should have required, and `gh pr view` returns the pull request's
# own description, never that specification. `gh issue list` appears twice
# because deduplication lists the open backlog once up front and then searches
# all states per finding.
GITHUB_READS = (
    'api graphql -F owner="${REPO%%/*}" -F name="${REPO##*/}"',
    'pr view -R "$REPO"',
    'issue view -R "$REPO"',
    'pr diff -R "$REPO"',
    'issue list -R "$REPO" --state open',
    'issue list -R "$REPO" --search',
)

# `gh pr view` is taken twice: once for the reviewed pull request's own
# description, and once more to verify that a pull request claimed to have
# fixed an earlier finding really merged before its fix link is recorded
# (requirement 4). They are deliberately two reads rather than one, because the
# second is about a different pull request.
REPEATED_GITHUB_READS = {'pr view -R "$REPO"': 2}
DECLARED_GITHUB_CALL_COUNT = sum(
    REPEATED_GITHUB_READS.get(read, 1) for read in GITHUB_READS
)

# The inventory, which is complete or it is nothing. A listing that stopped
# early is indistinguishable from a repository with fewer pull requests in it,
# and the helper refuses anything but a contiguous run of one-size pages ending
# in a short one -- so the asset has to say how to produce one, and what to do
# when a page does not arrive.
INVENTORY_RULES = {
    "one page per call, positioned by the previous page's cursor": (
        "Take one page per call. `$AFTER` is `null` for the first page and each "
        "earlier page's own `next` for every page after it"
    ),
    "repeat until a page comes back short": (
        "Repeat that call until a page comes back with fewer than 100 pull "
        "requests on it. That short page is the last one"
    ),
    "the sequence is what is read": (
        "The helper reads the sequence rather than the rows: page numbers must "
        "be contiguous from 1, one page size across the whole walk, nothing "
        "after the first short page."
    ),
    "never renumber around a skipped page": (
        "Those are what make a listing with an interior page dropped "
        "detectable, so never renumber around a page you skipped."
    ),
    "a failed page stops the run": (
        "**A page that fails stops the run.** Say which page failed and stop. "
        "This step writes nothing and starts nothing, so a stop here owes step "
        "9 nothing at all — which is the reason it comes first."
    ),
    "the partial listing is never handed over": (
        "Never hand the helper the pages that did arrive: a listing with a page "
        "missing from it records every pull request on that page as one this "
        "repository does not have."
    ),
    "a full last page is not an end": (
        "The last page is short because a page returned at its own limit may be "
        "a page of a longer history and nothing in the page itself can tell the "
        "two apart."
    ),
    "the empty page is the short one": (
        "When the history ends exactly on a page boundary, the next request "
        "comes back with no rows at all, and that empty page is the short one."
    ),
}

# Requirement 1: one review per successful invocation, and the three
# unsuccessful outcomes that complete zero and enter nothing.
ONE_REVIEW = {
    "one per invocation": (
        "**One pull request per invocation.** A successful run in the default "
        "PR mode completes exactly one review and never starts another."
    ),
    "the unsuccessful outcomes complete zero": (
        "An empty inventory, a pull request nobody can claim, a refusal, and a "
        "cancellation each complete zero reviews — and none of them falls "
        "through into the direct-commit mode below."
    ),
    "repetition belongs elsewhere": (
        "Repetition is {{cmd:auto-project-review}}'s, not this workflow's: "
        "there is no `continue` action here, and no invocation ever begins a "
        "second review."
    ),
    "no selectable row": (
        '**`"status": "no-selectable-row"`** — every merged pull request the '
        "listing named is excluded. Say so and stop."
    ),
    "all claimed": (
        '**`"status": "all-claimed"`** — somebody holds a live claim on every '
        "selectable pull request."
    ),
    "do not wait, do not take over a live claim": (
        "Say so and stop; do not wait, and do not take over an unexpired claim."
    ),
    "none of them enters direct mode": (
        "None of these enters direct mode. Direct-commit review is a separate "
        "explicit request, and an exhausted or unavailable PR queue is not one."
    ),
}

# The instructions the rebuild removed. Each is pinned as an absence over the
# whole rendered body rather than over PR mode alone, because the defect is a
# second review starting -- and a continuation instruction reads as permission
# wherever it sits.
REFUSED_REPETITION = (
    "## Complete and continue",
    "On `continue`, review the next uncovered batch",
    "enter direct mode only after an unbounded PR history is exhausted",
    "every later `continue`",
    "the next `continue` enters direct mode",
    "treat PR history as exhausted",
)

# Requirement 7: each direct-mode invocation needs its own explicit request,
# and nothing routes into it.
EXPLICIT_DIRECT_MODE = {
    "explicit request only": (
        "Reviewing the direct first-parent commits that predate the "
        "pull-request workflow is a **separate mode, entered only when the user "
        "explicitly asks for it in this turn**."
    ),
    "nothing enters it automatically": (
        "Nothing enters it automatically. An exhausted PR queue does not, a "
        "repository with no merged pull requests does not, a refusal does not, "
        "and a bare `continue` does not — there is no `continue` here at all."
    ),
    "one batch, then stop": (
        "Each direct-mode invocation needs its own explicit direct request, and "
        "it reviews one batch and stops; it never starts another."
    ),
    "the ledger does not schedule it": (
        "It does not read or write the ledger, and the ledger does not schedule "
        "it"
    ),
    "no transition back": (
        "Then stop: no next batch, and no transition back into PR mode."
    ),
}

# Requirement 1 and design D-13: the review is verified against a tree this
# invocation fetched and pinned, never against whatever the primary checkout
# happens to be sitting on.
PINNED_WORKTREE = {
    "fetch, resolve, detach": (
        "Fetch, resolve the remote default branch's head to a full SHA, and "
        "create a detached temporary worktree at it."
    ),
    "three checked calls, not one block": (
        "**Three tool calls, each checked before the next.** A shell runs "
        "every line of a block whatever the ones above it did, so a fetch that "
        "failed inside one would be followed by a resolution against whatever "
        "the local remote-tracking refs still hold — a stale tree, reviewed "
        "and recorded as though it were the remote's head, which is the one "
        "thing requirement 1's fetch-failure stop exists to prevent."
    ),
    "the fetch is its own call": (
        "The fetch is therefore its own call, and its status is read before "
        "anything else runs:"
    ),
    "a readable remote makes a stale pin plausible": (
        "Never substitute an older local ref — a review recorded against a SHA "
        "the remote never had says nothing about the code anybody else can "
        "see, and a `ls-remote` that answers while a fetch fails is exactly "
        "the shape that makes one look plausible."
    ),
    "an empty resolution stops too": (
        "An empty `$DEFAULT_BRANCH` is a remote that reported no HEAD symref "
        "at all, and an empty `$PIN` is a branch this fetch did not bring "
        "down: either stops the run, through step 9, rather than pinning "
        "something nobody named."
    ),
    "the default branch comes from the remote": (
        "**The default branch is read from the remote, not from "
        "`refs/remotes/origin/HEAD`.** That local symref is written once, by "
        "`clone` or by an explicit `remote set-head`, and a fetch does not "
        "refresh it"
    ),
    "a stale symref names the wrong branch": (
        "a repository whose remote moved from `master` to `main` keeps "
        "answering `master` for as long as the old branch still exists, and "
        "the review would then be recorded against a branch nobody's default "
        "is."
    ),
    "registration follows the inventory": (
        "Register it **before** claiming, so an invocation that could never "
        "renew claims nothing — and **after** the inventory, so a repository "
        "with nothing to review spawns no keeper and writes no record."
    ),
    "one directory, named for the attempt": (
        "**Everything this invocation creates goes in one directory named for "
        "that attempt**, under the Git common directory every worktree of "
        "`$ROOT` shares — beside the lease's own heartbeat records and the "
        "adapter's, and inside no working tree at all"
    ),
    "nothing it creates is anonymous": (
        "The listing step 1 assembled and the worktree step 4 pins both live "
        "there, and step 9 removes the one directory. Nothing this workflow "
        "creates is anonymous, and nothing of it is left where a `docs/` "
        "publication or an operator's own working tree could pick it up."
    ),
    "the listing reaches disk only at the claim": (
        "Write the listing step 1 assembled into this attempt's directory, "
        "which is the first thing this invocation puts on disk:"
    ),
    "the reclaim pass is a cancellation's only cleanup": (
        "**Then reclaim the directories earlier attempts left.** This is the "
        "only cleanup a cancellation can get — the runtime ends the keeper, "
        "but it cannot run step 9 — so it runs here, before anything new is "
        "made, and it is what makes that exit recoverable rather than merely "
        "harmless."
    ),
    "what makes an attempt over": (
        '**An attempt is over** when `status` reports `"status": "ended"`; when '
        'it reports `"status": "active"` but a `keeper_standing` other than '
        "`live`, which is what a keeper killed outright leaves behind — it "
        "writes no ended record, so reading `active` alone would strand that "
        "directory for good; or when the adapter refuses it as "
        "`attempt-unknown`, which is what an attempt pruned after seven days "
        "looks like."
    ),
    "a live attempt's directory is left alone": (
        "An `active` attempt with a live keeper belongs to an invocation "
        "running somewhere: leave it alone."
    ),
    "over is not reclaimable": (
        "**Over is not reclaimable, and every step from here fails closed.** "
        "Removing this directory deletes a checkout, so the question is never "
        '"is there a reason to keep it" but "can this invocation *establish* '
        'that nothing is using it". Two answers must both be positive, and '
        "anything else retains:"
    ),
    "the keeper must be positively gone": (
        "**The keeper is positively gone.** `keeper_standing` is `gone`, or "
        "the attempt reports `ended`. `unverifiable` is not gone — it is a "
        "keeper on another host, or a pid this process may not signal — and an "
        "`attempt-unknown` refusal is worse, because the adapter has no "
        "records left to answer either question from. Both retain."
    ),
    "the exemption is the wrong question for cleanup": (
        "**Nothing it launched is still running.** `status` answers that "
        "separately: `unfinished_launches` names every wrapped launch whose "
        "process is not known to be gone, whether or not its tool call "
        "finished — which is the question that matters here, because the "
        "command that outlives a cancelled attempt is a backgrounded one, and "
        "`exempt_launches` is built to skip exactly those. A non-empty list "
        "retains."
    ),
    "a retained directory is reported with its reason": (
        "A retained directory is reported by path with the reason — the "
        "standing that could not be verified, or the labels still running — "
        "and left for a later invocation, once the answer is positive, or for "
        "{{cmd:janitor}}, where an operator can decide what this workflow may "
        "not."
    ),
    "a deletion is the unrepairable outcome": (
        "Deleting a worktree out from under a live process is the one outcome "
        "nothing later can repair, and a directory left on disk costs only "
        "disk."
    ),
    "it never depends on the primary checkout": (
        "The review is verified against that exact tree and nothing else, so it "
        "never depends on the primary checkout staying where it is"
    ),
    "a failed fetch stops the run": (
        "**A failed fetch stops the run**, here, with nothing else attempted: "
        "release the claim through step 9 and say the fetch failed."
    ),
    "no runtime artifact publishes": (
        "No worktree, lock, or liveness record ever lives under "
        "`docs/project_review/`: that directory publishes, and a runtime "
        "artifact in it would publish with it."
    ),
    "the worktree goes in the attempt's directory": (
        "Only then create the worktree, inside the directory step 2 made for "
        "this attempt:"
    ),
    "the pin is the verification commit": (
        "`$PIN` is the full SHA recorded as the verification commit in step 8."
    ),
    "findings are read out of the pinned tree": (
        "Read the touched code **in `$REVIEW_WT`**, plus enough callers and "
        "consumers to verify that the behavior still holds in context. Every "
        "file read that decides a finding is a read of that pinned tree; a read "
        "of `$ROOT` is a read of whatever that checkout happens to be sitting "
        "on."
    ),
}
PINNED_WORKTREE_COMMANDS = (
    'git -C "$ROOT" fetch --quiet origin',
    'DEFAULT_BRANCH="$(git -C "$ROOT" ls-remote --symref origin HEAD',
    'PIN="$(git -C "$ROOT" rev-parse "refs/remotes/origin/$DEFAULT_BRANCH")"',
    'REVIEW_WT="$ATTEMPT_DIR/tree"',
    'git -C "$ROOT" worktree add --detach "$REVIEW_WT" "$PIN"',
)

# The read a fetch does not refresh. `git fetch` leaves
# `refs/remotes/origin/HEAD` exactly as `clone` or an explicit `remote set-head`
# wrote it, so an asset resolving the default branch through it pins whatever
# the remote's default was when the checkout was made -- and records the review
# against a branch that may no longer be anybody's default.
#
# Refused inside the bash fences alone, because the prose beside the correct
# command names the local symref in order to warn about it: an absence over the
# whole body would forbid the explanation as well as the mistake.
REFUSED_STALE_SYMREF_READS = ("refs/remotes/origin/HEAD", "origin/HEAD")

# Requirement 5: cleanup on every exit, in order, attempt-scoped, and honest
# about what it failed to remove.
CLEANUP = {
    "every exit runs it": (
        "Every exit runs this — a completed record, a refusal, a failed fetch, "
        "a takeover, and a cancellation alike."
    ),
    "owed from the moment the resource exists": (
        "**Each resource is owed its cleanup from the moment it exists**, not "
        "from the step that was meant to fill it: a registration that refused "
        "started no keeper, and a claim that was never taken leaves nothing to "
        "release."
    ),
    "each step is conditional on what this invocation created": (
        "So the steps are conditional, in this order, and each runs **only "
        "when this invocation created what it names**. A step whose resource "
        "was never created is not run, and not running it is not a failure."
    ),
    "stop the processes": (
        "**Stop every process this attempt started** — when step 2 registered "
        "one:"
    ),
    "a refused registration started nothing": (
        "A registration that refused started nothing."
    ),
    "release unless recorded": (
        "**Release the claim, unless `record` already did** — when step 3 "
        'reported `"status": "claimed"` and step 8 did not report `"status": '
        '"recorded"`:'
    ),
    "an unclaimed exit has nothing to release": (
        "`no-selectable-row`, `all-claimed`, and a claim refusal leave no "
        "`$PR` and no `$TOKEN`, so there is nothing to release and this step "
        "does not run."
    ),
    "remove the worktree": (
        "**Remove the temporary worktree** — whenever step 4 *attempted* to "
        "create one, whether or not it reported success:"
    ),
    "an attempt is the condition, not an outcome": (
        "Whether it succeeded is not what decides this. A `worktree add` that "
        "failed can have left a directory, an administrative record, or both, "
        "so an attempt is the condition and not an outcome."
    ),
    "nothing registered is this step done": (
        "`is not a working tree` is this step finding nothing registered, "
        "which is this step done — go on to step 4. Any other failure is a "
        "real one: retain and report."
    ),
    "the attempt directory is owed whenever it was made": (
        "**Remove this attempt's directory** — whenever step 2 made one, "
        "unless step 3 failed for some reason other than finding nothing to "
        "remove:"
    ),
    "one removal covers everything the run made": (
        "One removal, because everything this invocation created is in there: "
        "the listing step 3 wrote and the worktree step 4 pinned."
    ),
    "the condition is on the resource, not the step": (
        "`$ATTEMPT_DIR` exists from step 2, so an exit before either of them "
        "still owes this — which is the whole difference between a condition "
        "on the resource and a condition on the step that was meant to fill "
        "it."
    ),
    "why a failed removal keeps its directory": (
        "But it *contains* `$REVIEW_WT`, so removing it after a failed "
        "`worktree remove` would delete the very worktree the previous step "
        "just reported it had retained"
    ),
    "a partial removal ends either way": (
        "A partial removal can end either way, with the record dropped and the "
        "tree still on disk or both still there, so neither is assumed."
    ),
    "a failed removal reports the repair": (
        "When step 3 really failed, keep `$ATTEMPT_DIR`, report it by path, "
        'and say that `git -C "$ROOT" worktree prune` is what clears any '
        "record still naming it once the directory itself is dealt with."
    ),
    "never derive a removal target": (
        "**Never derive a removal target from another path**: `dirname` of a "
        "variable that was never set is `.`, and a recursive removal of the "
        "working directory is the one mistake this workflow could make that "
        "nothing later could repair."
    ),
    "a failed step reports its retained path": (
        "**A cleanup step that fails is reported with the path it retained, "
        "never as removed.** Name the directory still on disk, or the claim "
        "still held, so a human or a later run can finish it."
    ),
    "claiming removal is the defect": (
        "Claiming removal that did not happen is what leaves an orphan nobody "
        "knows to look for."
    ),
    "attempt-scoped ownership": (
        "**Cleanup and every ownership check are scoped to this attempt.**"
    ),
    "a superseded attempt touches nothing of its replacement's": (
        "its cleanup then stops its own processes and removes its own "
        "directory, and touches nothing the replacement owns. Never remove a "
        "directory, end an attempt, or release a claim that this invocation "
        "did not create."
    ),
    # Requirement 5's cancellation clause, answered mechanism by mechanism
    # rather than waived: the runtime stops the processes, the lapse and the
    # takeover release the claim, and step 1's reclaim pass removes the
    # directory. None of the three depends on a final tool call of the
    # cancelled invocation's.
    "a cancellation reaches all three": (
        "**A cancellation reaches all three of these without a tool call of "
        "this invocation's.** You do not have to reach step 9 for any of them:"
    ),
    "the runtime stops the processes": (
        "*Processes.* The keeper stops on turn completion, session "
        "termination, an interruption the runtime reports, and after a bounded "
        "silence window for a cancellation it does not report. That is #687's "
        "mechanism, and it needs nothing from the model."
    ),
    "a wrapped command bounds it instead": (
        "A command started through the wrapper is the exception in both "
        "directions: it holds its launch exempt from that window while it "
        "runs, and the runtime does not reliably kill it — on Claude Code "
        "2.1.276 an interrupted foreground command keeps going. So a "
        "cancellation with a wrapped command still running is bounded by that "
        "command, not by the window, and the reclaim pass is what refuses to "
        "remove its directory meanwhile."
    ),
    "the lease lapses and the row becomes claimable": (
        "*The claim.* Renewal stops with the keeper, so the lease runs out and "
        "the row becomes claimable again; the next invocation takes it over "
        "under the helper's lock and records the transition, which is the "
        "recovery the lease was designed around."
    ),
    "a cancelled attempt cannot write afterwards": (
        "The cancelled attempt cannot write to it afterwards: its token no "
        "longer owns the claim, so its `record`, its allocation and its "
        "release are all refused."
    ),
    "the reclaim pass owns the directory": (
        "*The directory.* Step 2's reclaim pass removes the directory of every "
        "attempt the adapter reports as over, which is exactly what a "
        "cancelled one is."
    ),
    "an orphan is identifiable and owned": (
        "That is why everything this invocation creates is named for the "
        "attempt and kept in one place: an orphan is identifiable, and the "
        "next invocation in this repository is its owner."
    ),
    "one invocation late rather than never": (
        "So the honest summary is that a cancellation completes cleanup one "
        "invocation late rather than never, and leaves nothing in a working "
        "tree or a publishable directory in the meantime."
    ),
}
CLEANUP_COMMANDS = (
    'python3 "$LIVENESS" complete --root "$DOCS_WT" --attempt "$ATTEMPT"',
    'python3 "$LEDGER" release --root "$DOCS_WT" --repo "$REPO" --pr "$PR" --token "$TOKEN"',
    'git -C "$ROOT" worktree remove --force "$REVIEW_WT"',
    'rm -rf "$ATTEMPT_DIR"',
)

# The spelling that made the retained-path rule unkeepable: the attempt's
# directory contains `$REVIEW_WT`, so one removal covering both it and the
# worktree deletes the tree `git worktree remove` had just failed to remove --
# and leaves Git's own record pointing at a directory that is gone.
REFUSED_COMBINED_REMOVAL = 'rm -rf "$REVIEW_ROOT" "$SCRATCH"'

# A removal target built out of another path. `dirname` of an unset variable is
# `.`, so a cleanup that derived its scratch parents this way would recursively
# remove the working directory on exactly the early exits -- a refused
# registration, an unavailable claim, a failed fetch -- that requirement 5 says
# must clean up. Refused by spelling, over the whole rendered body.
REFUSED_DERIVED_REMOVAL = 'rm -rf "$(dirname'

# Requirement 3: the migration runs once, and a flag is a stop rather than a
# judgement call.
MIGRATION = {
    "migrate a repository with coverage but no ledger": (
        "A repository whose docs worktree holds "
        "`docs/project_review_boundaries.md` or historical "
        "`docs/project_review_*.md` reports but no ledger is a repository whose "
        "coverage has to be imported before a selection means anything."
    ),
    "the migration runs once": (
        "It refuses outright over an existing ledger, so it runs exactly once "
        "however many invocations follow."
    ),
    "a fresh repository needs no stop": (
        "A repository with neither a cursor nor a report starts from an empty "
        "ledger and has no stop and nothing to confirm: the same call "
        "establishes that empty ledger, reports `\"status\": \"migrated\"` with "
        "no rows, and the run continues."
    ),
    "a flag stops for the operator": (
        "**A flagged migration stops for the operator.** Exit 3 with `\"status\": "
        '"flagged"` means the helper read a report whose opening paragraph it '
        "will not read as an enumeration, and it has written nothing."
    ),
    "present every flagged report with its candidates": (
        "Present every flagged report by path, with its `candidates` — the "
        "pull-request numbers its prose names — and its `reason`, and **stop "
        "for the operator's confirmation**."
    ),
    "neither guess is recoverable": (
        "importing coverage that was never real marks unreviewed pull requests "
        "reviewed, and discarding real coverage re-reviews work somebody "
        "already did. Neither is recoverable from the ledger afterwards."
    ),
    "a confirmation is passed back verbatim": (
        "When the operator confirms an enumeration, pass it back verbatim and "
        "migrate again"
    ),
}

# Requirement 3's legacy-handling section.
LEGACY_HANDLING = {
    "every migrated row is legacy": (
        "Every row the migration writes is `[legacy]`: the coverage is known, "
        "and nothing about when it was reviewed, what it was verified against, "
        "or whether it was clean is."
    ),
    "a legacy row is not a reviewed row": (
        "A `[legacy]` row is not a reviewed row."
    ),
    "how they are scheduled": (
        "Selection schedules it in its own queue — after every never-reviewed "
        "pull request, highest number first"
    ),
    "how they are converted": (
        "the completed `record` replaces the `[legacy]` status with `clean` or "
        "`findings`, its verification commit, and its UTC completion time. No "
        "separate conversion step exists, and nothing in this workflow edits a "
        "`[legacy]` row by hand."
    ),
}

# Requirement 4: what an earlier finding's return does to this review's report,
# and what a fix link costs before it may be recorded.
FINDING_HISTORY = {
    "the history is read under the claim": (
        "**Read the ledger again for that history, now that the claim is "
        "held:**"
    ),
    "the pre-claim read is not that history": (
        "The read before the migration step is not that history. It was taken "
        "before the inventory and before the claim, and between the two another "
        "invocation can have recorded a review of this very pull request and "
        "linked a report to it; on a repository that migrated in this run it "
        "held no rows at all."
    ),
    "a stale snapshot files somebody else's finding again": (
        "A finding compared against that snapshot is a finding compared "
        "against a row that has since moved, and the entry it then files is "
        "the second copy of somebody else's."
    ),
    "the claim is what makes the row stable": (
        "The claim is what makes this row stable — nobody else can record "
        "against it while this invocation holds it — so the read taken after "
        "it is the one that can be trusted, and `claim`'s own payload does not "
        "carry the row's history."
    ),
    "new": (
        "**New** — no earlier report for this pull request describes it. It may "
        "produce a new report entry."
    ),
    "repeated produces no entry": (
        "**Repeated** — an earlier report's `PRR-k` describes it and it is still "
        "unresolved. It produces **no new report entry**: pass "
        '`--repeat "<report>#PRR-k"` to `record` instead.'
    ),
    "why a repeat is not filed again": (
        "Filing it again splits one defect across two entries that "
        "{{cmd:process-report}} would then dispose of twice."
    ),
    "a recurrence may be filed": (
        "**Recurrence** — an earlier report's `PRR-k` described it, it was "
        "resolved, and it has returned. It may produce a new report entry, and "
        "that entry's handoff context must carry `Recurrence of: <report> "
        "PRR-k`."
    ),
    "an earlier report does not suppress a recurrence": (
        "The original finding appearing in an earlier report is not a reason to "
        "suppress the new entry: what returned is a new defect in current code "
        "with a history."
    ),
    "repeats alone are still findings": (
        "A repeated finding with no new or recurring finding beside it is still "
        "a findings-bearing review. It allocates no report, records its "
        "existing-finding links, advances the completion timestamp, and earns "
        "no clean mark. The absence of a report never means the pull request "
        "was clean."
    ),
    "a fix link is verified twice": (
        "Pass `--fixed \"<report>#PRR-k=<fix PR>\"` and "
        '`--fixed-merge "<report>#PRR-k=<merge commit>"` only after verifying '
        "both halves yourself: that the fix pull request merged in `$REPO`, "
        'with `gh pr view -R "$REPO" <fix PR> --json state,mergedAt,mergeCommit`, '
        "and that its correction is present in `$REVIEW_WT`."
    ),
    "a claim of a fix is not evidence": (
        "A merged pull request that claims a fix is not evidence that the tree "
        "carries one."
    ),
}

# The report, whose name the helper allocates rather than the reviewer choosing
# it: an existing filename is never reused, and a name nobody allocated is one
# `record` refuses (design D-14).
REPORT_ALLOCATION = {
    "only for new findings": (
        "Write a report when, and only when, at least one finding is new or a "
        "verified recurrence — an already-tracked one included, since step 6.3 "
        "gives that an entry too. A review whose findings are all unresolved "
        "repeats writes none, and a clean review writes none."
    ),
    "the helper allocates the name": (
        "The helper allocates the name, atomically, under the claim"
    ),
    "the two shapes": (
        "It returns `report` — `docs/project_review/<PR>.md` for the first "
        "report about this pull request and `docs/project_review/<PR>_<k>.md` "
        "for each later one."
    ),
    "never choose a name": (
        "**Never choose a report name yourself**: an existing name is never "
        "reused, and a name nobody allocated is one `record` will refuse."
    ),
    "preserve unrelated dirty files": (
        "Write the file at that path under `$DOCS_WT`, preserving unrelated "
        "dirty files in that worktree."
    ),
    "shape, never scope": (
        "Inspect a neighbouring `docs/project_review/*.md` report for its shape "
        "if one exists — never for its scope, which the ledger owns."
    ),
}

# Requirement 1 and design D-10: the record is the attempt's whole durable
# effect, and the checkpoint is the helper's rather than the workflow's.
RECORD_STEP = {
    "what record does": (
        "`record` writes the outcome into the row, publishes the ledger and the "
        "report as one path-scoped checkpoint on the docs worktree's branch, "
        "and releases the claim"
    ),
    "the two outcomes": (
        "`--outcome clean` for a review with no finding of any kind; "
        "`--outcome findings` for every other completed review."
    ),
    "every findings row has something to link": (
        "Every other one has something to link, which is what the helper "
        "requires of a `findings` row: a new or recurring finding has the "
        "report step 7 allocated, an unresolved repeat has its `--repeat`, and "
        "an already-tracked finding has the report entry step 6.3 gives it. "
        "`clean` is for the review that found nothing, and for nothing else."
    ),
    "the commit is the pinned tree": (
        "`--commit` is `$PIN`, the tree the review was actually verified "
        "against."
    ),
    "the report flag is omitted when none was written": (
        "`--report` is the allocated path and is omitted when step 7 wrote none."
    ),
    "the checkpoint is the only commit": (
        "The checkpoint is the helper's, and it is the only commit this workflow "
        "produces."
    ),
    "nothing else is landed": (
        "Do not stage, commit, publish, push, or land anything yourself — not "
        "the ledger, not the report, not the cursor."
    ),
    "a refusal leaves the claim held": (
        "A refusal here leaves the claim held and says so; report it as it came "
        "and let step 9 clean up."
    ),
}

# Requirement 6: what the one completion message has to name, so an operator
# reading it alone can tell what was reviewed, against what, and where the
# result went.
COMPLETION_MESSAGE = (
    "the pull request reviewed, and the queue `claim` took it from;",
    "the outcome — `clean`, or the findings and their count;",
    "the verification commit `$PIN`;",
    "the report path, or the existing-finding links a repeats-only review "
    "recorded;",
    "the checkpoint commit `record` published;",
)
COMPLETION_STOP = (
    "Then stop. There is no continuation prompt, no `continue` action, and no "
    "next batch."
)

# Why the linked-issue read cannot be folded into `gh pr view`.
LINKED_ISSUE_READ = (
    "Find its linked issue in that description's closing reference and read it "
    'with `gh issue view -R "$REPO" <m>`. Step 1\'s call returns the pull '
    "request's own description, never the specification it claims to satisfy, "
    "so this is a read of its own rather than a second look at the same text."
)

REPOSITORY_SCOPE = '-R "$REPO"'

# The one call that cannot carry `-R`, and how it names the repository instead.
GRAPHQL_REPOSITORY_SCOPE = '-F owner="${REPO%%/*}" -F name="${REPO##*/}"'

# How `$REPO` is filled: from the remote, with no GitHub call of its own.
REPOSITORY_RESOLUTION = 'REPO="$(git -C "$ROOT" remote get-url origin'

# `$REPO` names the tracker; `$ROOT` names the checkout. Most of this workflow
# never touches GitHub -- the ledger lives in the docs worktree, the review
# runs against a worktree of the reviewed repository, and direct mode walks
# first-parent history -- so a `$REPO` the session's own checkout is not a
# checkout of would audit one repository's pull requests against another's code
# and write its ledger into another's docs worktree. Neither is undone by moving
# a file afterwards, so the two are required to agree before the first call.
CHECKOUT_RESOLUTION = 'ROOT="$(git rev-parse --show-toplevel)"'
CHECKOUT_TARGET = {
    "both are resolved, and neither substitutes": (
        "`$REPO` is the `owner/name` every `gh` call names; `$ROOT` is the "
        "local checkout every other step runs in, and neither substitutes for "
        "the other."
    ),
    "the git steps run under the checkout": (
        'Run them all under `$ROOT` with `git -C "$ROOT"`, never in whatever '
        "directory the session happens to be sitting in."
    ),
    "a named repository does not adopt this checkout": (
        "When the user named a repository, `$ROOT` is a checkout **of that "
        "repository**, and the session's own is not it unless it proves to be."
    ),
    "the two must agree": (
        'run that same `git -C "$ROOT" remote get-url` and **require the two '
        "to agree**. They must name one `owner/name` between them."
    ),
    "a mismatch stops the run": (
        "A mismatch, or no available checkout of `$REPO`, stops the run before "
        "the first `gh` call"
    ),
    "the working directory is never the repair": (
        "Falling back to the working directory is never the repair."
    ),
}

# Every git invocation that reads or writes the repository under review, which
# is every one of them except the `rev-parse` that establishes `$ROOT` itself.
CHECKOUT_SCOPED_GIT = (
    'git -C "$ROOT" remote get-url origin',
    'git -C "$ROOT" worktree list --porcelain',
    'git -C "$ROOT" fetch --quiet origin',
    'git -C "$ROOT" ls-remote --symref origin HEAD',
    'git -C "$ROOT" rev-parse "refs/remotes/origin/$DEFAULT_BRANCH"',
    'git -C "$ROOT" worktree add --detach "$REVIEW_WT" "$PIN"',
    'git -C "$ROOT" worktree remove --force "$REVIEW_WT"',
    'git -C "$ROOT" log --first-parent',
    'git -C "$ROOT" show --stat --summary',
    'git -C "$ROOT" diff',
)

# How `$DOCS_WT` is filled: by branch, never by a hard-coded path. It is
# resolved once and is `--root` for every helper call.
DOCS_WORKTREE_RESOLUTION = 'DOCS_WT="$(git -C "$ROOT" worktree list --porcelain'

# The opening report, which is what catches a wrong resolution — and only if it
# lands before the first *read*. A run scoped against the wrong repository has
# already spent itself by the time anything is written.
OPENING_REPORT = (
    "name the resolved `$REPO` and the `$ROOT` it was matched against before "
    "the first `gh` call below."
)

# The pull request, which is not knowable until the claim returns, so it is
# announced after the claim rather than guessed before it.
SELECTION_REPORT = (
    "Announce the pull request, its queue, and the inventory's counts before "
    "reviewing anything."
)

# Requirement 3 of issue #462: the report-only contract, stated in the rendered
# body for both brands rather than only in the pull request that shipped it.
REPORT_ONLY = {
    "no tracker write": (
        "Do not modify the reviewed code, touch merged PRs, or create or edit "
        "tracker issues."
    ),
    "no commit, no push": (
        "This workflow makes no commit and pushes nothing: the ledger helper's "
        "`record` step publishes the one checkpoint, and nothing else in this "
        "document writes to a branch."
    ),
    "the report is the handoff": (
        "The findings report it may write is the durable handoff to"
    ),
    "no drafting, no filing": (
        "Do not draft tracker issue bodies, ask which findings to file, open an "
        "issue through `gh`, or append any origin-routing marker"
    ),
    "restated at the write": (
        "this workflow never creates or edits a tracker issue, and the user's "
        "invocation authorizes the report handoff rather than a filing"
    ),
}

# Two spellings that would each turn the report-only contract back into a
# filing workflow, and one that would route the filing. Absence is the
# assertion; issue #462's acceptance greps for exactly these.
FORBIDDEN_SPELLINGS = ("gh issue create", "issue-origin")

# Issue #684's acceptance greps for these two as an absence over each rendered
# asset: an executable committing or pushing instruction anywhere in the
# document contradicts the one checkpoint `record` makes.
FORBIDDEN_VCS_WRITE_RE = re.compile(r"git (commit|push)")

# Requirement 4, capability 1: direct-commit mode and its cursor rules, which
# existed only in the Codex copy, and which #684 confined to the direct
# section.
DIRECT_MODE = {
    "twelve-unit default": "Default to 12 review units.",
    "a merge is not implied": (
        "**A count is a batch size, not a position.**"
    ),
    "a commit may be abbreviated": (
        "A commit may be named at any length `git` itself accepts — four "
        "characters up, the seven a direct-mode report filename carries "
        "included. `select` and `record` resolve an abbreviated SHA against "
        "the walk, and refuse a prefix that names more than one commit rather "
        "than choosing between them, so length is never the refusal; ambiguity "
        "is."
    ),
    "the entry point is supplied on the first direct batch": (
        "**`$RANGE_START` carries the entry point on the first direct batch**, "
        "and is empty for every batch after it. Set it to the first-parent "
        "parent of the earliest pull-request-owned commit already reviewed, and "
        "leave it empty for a repository that has never used pull requests, "
        "which begins at HEAD."
    ),
    "an empty start is no start": (
        "An empty `--start` is no start at all, so this one invocation covers "
        "both — but leaving it empty on the *first* batch of a repository that "
        "does have PR history restarts the walk at HEAD and re-reviews PR-owned "
        "commits, because direct state is still empty at that moment and there "
        "is no endpoint to position it."
    ),
    "the direct walk is never sliced": (
        "**Walk the whole first-parent history, not a slice starting at the "
        "entry point.** The recorded endpoint has to be inside the listing the "
        "helper positions within, and a walk that began below it would refuse "
        "it as a cursor belonging to some other history."
    ),
    "inventory is not review": (
        "A broad blame or survivor inventory is triage, not a reviewed "
        "direct-commit batch."
    ),
    "the initial commit has no parent": (
        "Use an empty-tree diff for the initial commit, which has no first "
        "parent to diff against."
    ),
    "stop at the initial commit": (
        "Stop explicitly after reviewing the initial commit."
    ),
    "a report never covers a direct commit": (
        "**A report never establishes direct-commit coverage.** A first-parent "
        "commit inside a reviewed interval is either covered by the recorded "
        "endpoint or selected"
    ),
    "unverifiable state stops the run": (
        "**Unverifiable state stops the run.** A recorded SHA is validated "
        "against current first-parent ancestry, so a malformed, foreign, or "
        "ambiguous cursor refuses before review rather than guessing."
    ),
    "direct gaps are announced": (
        "Every uncovered commit above that frontier appears in `gaps` and must "
        "be announced; never let the direct walk silently discard it."
    ),
    "the cursor belongs to the reviewed repository": (
        "`$CURSOR` owns `docs/project_review_boundaries.md`, whose `direct` "
        "endpoint is a moving older-history frontier that advances to the "
        "oldest commit a completed batch reviewed."
    ),
    "both endpoints are carried": (
        "`$RANGE_START` and `$RANGE_END` carry a user-supplied range's two "
        "endpoints — its newer and its older — and are empty when the user "
        "supplied none; an empty `--start` or `--end` is no bound at all, so "
        "one invocation covers both cases."
    ),
    "a start alone is not a range": (
        "**A range needs both of its endpoints.** `$RANGE_START` alone is a "
        "starting point, not a range"
    ),
    "the end is a bound, not a target": (
        "`--end` is a bound rather than a target — the batch stops there "
        "whatever the count still had left, and reports `\"bounded\": true` "
        "rather than `truncated` or `exhausted`, because it was the request "
        "that ended and neither the page nor the history."
    ),
    "recorded last": (
        "**Record the cursor last.** Record coverage only after every selected "
        "unit has been reviewed and any required report has been written and "
        "validated, so a failed report or a failed cursor write is never "
        "reported as a completed batch"
    ),
    "an empty batch records nothing": (
        "A batch that selected nothing records nothing and is not a completed "
        "batch: the helper refuses an empty `--reviewed` with an empty "
        "`--exclude`."
    ),
    "merged, never replaced": (
        "`record` merges rather than replaces: an earlier exclusion survives a "
        "later batch, and the direct endpoint only ever moves older."
    ),
    "compaction recovery reads the record": (
        "If context was compacted, recover the cursor with "
        '`python3 "$CURSOR" read --root "$DOCS_WT" --repo "$REPO"` rather than '
        "from the last completed range or a report name"
    ),
    "the direct filename is the reviewer's": (
        "A direct batch with at least one confirmed current finding writes one "
        "report at `docs/project_review_direct_<newest7>-<oldest7>.md`, under "
        "`$DOCS_WT/`. Its name is the reviewer's here — no helper allocates "
        "it, because no ledger row owns this batch — and an explicit "
        "destination from the user wins over it."
    ),
    "the direct report shape substitutes two things": (
        "Its shape is the one step 7 sets out with two substitutions, and "
        "nothing else from step 7 applies: the title is `# Project Review "
        "Findings: direct commits <newest>–<oldest>`, and the opening "
        "paragraph states the batch's SHA range, the commit the findings were "
        "verified against, and any excluded commit — a pull-request number and "
        "`$PIN` have no meaning here."
    ),
    "the rest of the shape is unchanged": (
        "The legend line, the `## Status` checklist, one `PRR-*` key appearing "
        "once in that checklist and once in a finding heading, and the four "
        "capture sections are all exactly as they are there."
    ),
    "direct mode owes none of step 6": (
        "**This mode verifies against `$ROOT`, and owes none of step 6.** Step "
        "6 is PR mode's: it needs `$PIN`, `$REVIEW_WT`, a claimed row and that "
        "row's history, and none of those exists here — there is no claim, no "
        "ledger row, and no pinned worktree, and a direct batch that went "
        "looking for them would find nothing."
    ),
    "a direct finding is verified in the checkout": (
        "Confirm it still exists in `$ROOT`'s checkout as it stands — a later "
        "commit may already have fixed it. That checkout is the whole of what "
        "a direct finding is verified against, and the completion message "
        "names the commit it was on so a reader knows which tree that was."
    ),
    "direct capture takes the same four sections": (
        "Capture each current finding in the same four sections PR mode uses "
        "— `Captured note`, `Verification`, `Evidence`, `Handoff context` — "
        "with the verification and the evidence taken from `$ROOT` rather than "
        "from `$PIN`."
    ),
    "direct mode has no ledger links": (
        "There is no repeat, recurrence or fix link in this mode: those are "
        "ledger entries, and direct mode has no row to link them to. A finding "
        "an earlier direct report already carries is named in the completion "
        "message and given no second entry."
    ),
    "a clean direct batch writes no report": (
        "A clean batch writes no report unless the user explicitly asks for one."
    ),
    "direct mode publishes nothing": (
        "Do not publish or land either unless the user separately requests it "
        "— **direct mode writes to no branch at all**."
    ),
    "the one branch write is the pr-mode checkpoint": (
        "The one branch write this workflow ever makes is PR mode's, and it is "
        "the helper's: `record`'s path-scoped checkpoint commit, which touches "
        "the ledger and the report it allocated and nothing else. Direct mode "
        "calls `record` on the cursor module, which commits nothing."
    ),
}

# Correction 2 of issue #548's review: the `DOCS_WT="$ROOT"` fallback is gone
# rather than merely discouraged. It contradicted the rule it sat two lines
# above -- the primary checkout is the one place neither ledger nor report may
# be written.
DOCS_WORKTREE_FAIL_CLOSED = {
    "an empty resolution stops the run": (
        "**An empty `$DOCS_WT` stops the run, and `$ROOT` is not the "
        "fallback.**"
    ),
    "why the primary checkout is refused": (
        "The primary checkout is where the PR drainer's post-merge "
        "fast-forward autostashes whatever it finds, so a ledger or report "
        "written there is not durable state at all — it is the next merge's "
        "wedge."
    ),
}
REFUSED_DOCS_WORKTREE_FALLBACK = '|| DOCS_WT="$ROOT"'

# Requirement 4, capability 4: the capture shape that makes a report entry
# sufficient for a later process-report pass.
CAPTURE_SECTIONS = (
    "`Captured note`: the concise correction;",
    "`Verification`: what was proved and how, against `$PIN`;",
    "`Evidence`: `file:line` traces in the pinned tree and/or reproduction;",
    "`Handoff context`: current behavior, expected behavior, scope and",
)

# The canonical report structure a later process-report pass reads back. The
# legend's literal opening and the one-key-twice rule are what make the
# checklist a durable cursor rather than a summary.
REPORT_STRUCTURE = {
    "the legend is labelled": (
        "The legend line must begin literally `Status legend:`; an unlabeled "
        "list of marker meanings is not canonical."
    ),
    "the legend line itself": (
        "Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · "
        "`[no-issue]`"
    ),
    "the status checklist": "## Status",
    "a checklist entry": "- [ ] PRR-1. <Finding title>",
    "a finding heading": "### PRR-1. <Finding title>",
    "one key, twice, in order": (
        "Each stable `PRR-*` key appears exactly once in the checklist and once "
        "in a finding heading, in the same order and with the same title."
    ),
    "new findings start unmarked": "Keep every new finding unchecked and unmarked.",
    "the title names the pull request": (
        "# Project Review Findings: PR #<number>"
    ),
}

# Requirement 9: behavior vendored as it reads today, one phrase per rule.
PRESERVED_BEHAVIOR = {
    "review-only prohibition": "**Review only.**",
    "the issue is a proposed specification": (
        "Treat the issue as a proposed specification, not unquestioned authority."
    ),
    "a faithful bad spec is still a finding": (
        "A faithful implementation of a flawed specification is still a finding."
    ),
    "a justified deviation is not": (
        "A PR that deviated from a bad specification to do the right thing is not."
    ),
    "nits are not findings": (
        "Nits are not findings; a finding must require a real correction."
    ),
    "confirm it survives to the pinned tree": (
        "Confirm it still exists at `$PIN` — a later merge may already have "
        "fixed it."
    ),
    "never report a hunch": "Never report a hunch.",
    "fixed-later is a one-liner": (
        "Record fixed-later mistakes as completion-summary one-liners. Only "
        "current mistakes become unprocessed report entries."
    ),
    "an already-tracked finding still gets an entry": (
        "**An already-tracked finding is still a finding.** The tracker search "
        "decides what its entry's `Deduplication` line says, not whether it "
        "has one: write the entry, name the open issue that already holds it "
        "there, and name it in the completion message too."
    ),
    "the deduplication line is what stops a second filing": (
        "That line is what stops {{cmd:process-report}} filing a second issue "
        "for it — the report is the handoff, and filing is that workflow's "
        "decision to make with the deduplication in front of it, not one to "
        "make here by leaving the defect out."
    ),
    "and it is what makes the review recordable": (
        "It is also what makes the review recordable at all: a row is "
        "`findings` only with a report or an existing-finding link beside it, "
        "and a defect this review confirmed at `$PIN` cannot honestly be "
        "recorded `clean`."
    ),
    "do not stop the review": (
        "Keep reviewing the rest of the pull request. Do not stop to discuss or "
        "file one finding."
    ),
    "state boundaries, not an implementation": (
        "State observable requirements and validation boundaries, not an "
        "assumed implementation."
    ),
    "the backlog scan still runs": (
        "Run the installed backlog scan when available and require the new path "
        "under `valid_reports`."
    ),
}

# The clean-review rule is its own requirement-9 clause because it is the one
# path that ends with no report at all and still has to record a completed
# attempt.
CLEAN_REVIEW = (
    "`--outcome clean` for a review with no finding of any kind"
)

# The one sentence that differs per brand because the providers really do pass
# arguments differently (design D-2/D-7 keep this rather than flattening it).
CLAUDE_ONLY_LINES = (
    "`$ARGUMENTS` may override the count, or name a commit SHA or range.",
    *HELPER_LOOKUPS["claude"],
    '[ -f "$LEDGER" ] && [ -f "$LIVENESS" ] && [ -f "$CURSOR" ]',
    REGISTRATION["claude"] + "0123456789abcdef0123456789abcdef",
    WRAPPED_LAUNCH["claude"],
)

# The Codex argument convention, and the one caveat that names Codex's default
# read-only sandbox. Requirement 6: the caveat survives for Codex, and the
# Claude rendering gains no invented equivalent.
CODEX_ONLY_LINES = (
    "An explicit count, commit SHA, or range overrides the default.",
    *HELPER_LOOKUPS["codex"],
    'LEDGER="$BUNDLE"',
    '[ -n "$BUNDLE" ] && [ -f "$LIVENESS" ] && [ -f "$CURSOR" ]',
    REGISTRATION["codex"] + "0123456789abcdef0123456789abcdef",
    WRAPPED_LAUNCH["codex"],
    "   In a read-only sandbox, a complete static trace may be the verification; say so.",
)

CODEX_ONLY_CAVEAT = CODEX_ONLY_LINES[-1]


def read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def body_of(text: str) -> str:
    """`text` with its frontmatter block removed.

    The frontmatter is the one place the two renderings legitimately differ
    beyond the brand blocks — different keys, and the invocation sigils inside
    the description — so the brand-boundary comparison is made over the body.
    """
    match = re.match(r"\A---\n.*?\n---\n(?P<body>.*)\Z", text, re.DOTALL)
    assert match is not None, "a rendered asset always opens with frontmatter"
    return match.group("body")


def sections_of(text: str):
    """`text` split into its PR half and its explicit-only direct half.

    The split is the unit of assertion for issue #684's requirement 10: the
    cursor still ships and the direct section still calls it, so "the asset
    names the cursor" says nothing about whether the rebuild happened. Where it
    names it does.
    """
    body = body_of(text)
    index = body.index(DIRECT_SECTION_HEADING)
    return body[:index], body[index:]


# The workflows this source names through a `{{cmd:}}` token. Read from the
# source rather than restated, so the brand comparison below covers exactly the
# substitutions requirement 8 asks for and no more.
REFERENCED_WORKFLOWS = renderer.referenced_names(
    (REPO_ROOT / SOURCE).read_text(encoding="utf-8")
)


def neutralize(text: str, brand: str) -> str:
    """`text` with `brand`'s spelling of each declared `{{cmd:}}` target put
    back into the neutral token.

    Requirement 8 makes the invocation sigil a per-brand difference by design,
    so the boundary comparison is made over what the one source authored rather
    than over the substitution. Undoing it here loses nothing:
    `test_each_brand_reads_its_own_invocation_sigil` is what asserts the
    substitution actually happened, in each direction.
    """
    sigil = renderer.SIGILS[brand]
    for name in sorted(REFERENCED_WORKFLOWS, key=len, reverse=True):
        text = text.replace(f"{sigil}{name}", f"{{{{cmd:{name}}}}}")
    return text


def flat(text: str) -> str:
    """`text` with every run of whitespace collapsed to one space, so a phrase
    is found whether or not the source wrapped it across lines."""
    return re.sub(r"\s+", " ", text)


def rendered_phrase(phrase: str, brand: str) -> str:
    """`phrase` with its `{{cmd:}}` tokens rendered the way `brand` renders
    them, so one authored pin serves both assets."""
    sigil = renderer.SIGILS[brand]
    return re.sub(r"\{\{cmd:([a-z0-9-]+)\}\}", lambda m: sigil + m.group(1), phrase)


BRAND_OF_ASSET = {CLAUDE_ASSET: "claude", CODEX_ASSET: "codex"}


class RenderedAssetTests(unittest.TestCase):
    """What both bundles ship is the render of the one authored source."""

    def test_both_assets_are_the_render_of_the_one_authored_source(self):
        # Requirement 2: neither rendered file is hand-edited. The registry
        # gate in tools/test_render_command_sources.py enforces this across
        # every entry; restating it here keeps this module's own assertions
        # about a file whose provenance it has checked, rather than about
        # whatever happens to be on disk.
        entry = next(
            candidate
            for candidate in renderer.COMMAND_SOURCES
            if candidate.name == "project-review"
        )
        self.assertEqual(entry.source, SOURCE)
        rendered = renderer.render_entry(entry, REPO_ROOT)
        self.assertEqual(set(rendered), set(RENDERED_ASSETS))
        for relative_path, text in rendered.items():
            self.assertEqual(read(relative_path), text, relative_path)

    def test_no_bundle_ships_an_auxiliary_reference_directory(self):
        # Requirement 5 and design D-10: the boundary rule ships as prose, and
        # the file it describes does not ship at all — it is one consuming
        # repository's cursor, and bundling it would put that state in every
        # install. The renderer emits one file per brand and nothing else, so
        # this holds by construction; it is asserted because the construction
        # is what a later slice might be tempted to extend.
        for root in BUNDLE_ROOTS:
            for directory in (REPO_ROOT / root).rglob("references"):
                self.assertFalse(
                    directory.is_dir(),
                    f"{directory} ships an auxiliary asset directory",
                )


class RepositoryScopeTests(unittest.TestCase):
    """Requirement 7: no `gh` call reads a repository nobody named."""

    def test_the_github_calls_are_exactly_the_declared_ones(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            calls = GH_INVOCATION_RE.findall(content)
            with self.subTest(asset=relative_path):
                self.assertEqual(len(calls), DECLARED_GITHUB_CALL_COUNT, calls)
                self.assertNotIn("repo view", "".join(calls))

    def test_every_github_call_names_the_resolved_repository(self):
        # Five of the six carry `-R "$REPO"`. The sixth is the GraphQL
        # inventory, which has no `-R` to carry: it names the same identity by
        # splitting `$REPO` into the owner and name its query variables take,
        # and is read that way rather than exempted -- an exemption would also
        # pass for a query that named some other repository outright.
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            for match in GH_INVOCATION_RE.finditer(content):
                call = match.group(0)
                with self.subTest(asset=relative_path, call=call):
                    if call.startswith("gh api graphql"):
                        self.assertIn(GRAPHQL_REPOSITORY_SCOPE, call)
                    else:
                        self.assertIn(REPOSITORY_SCOPE, match.group("tail"))

    def test_each_declared_read_is_present_and_scoped(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            for read_spelling in GITHUB_READS:
                with self.subTest(asset=relative_path, read=read_spelling):
                    self.assertIn(f"gh {read_spelling}", content)

    def test_the_inventory_is_complete_or_the_run_stops(self):
        for relative_path in RENDERED_ASSETS:
            content = flat(read(relative_path))
            for name, phrase in INVENTORY_RULES.items():
                with self.subTest(asset=relative_path, rule=name):
                    self.assertIn(flat(phrase), content)

    def test_the_checkout_is_resolved_and_required_to_match_the_repository(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            flattened = flat(content)
            with self.subTest(asset=relative_path):
                self.assertIn(CHECKOUT_RESOLUTION, content)
                self.assertIn(REPOSITORY_RESOLUTION, content)
            for name, phrase in CHECKOUT_TARGET.items():
                with self.subTest(asset=relative_path, rule=name):
                    self.assertIn(flat(phrase), flattened)

    def test_every_repository_read_runs_under_the_resolved_checkout(self):
        # `git -C "$ROOT"` on every one, so no step reads or writes whatever
        # repository the session's working directory happens to be in.
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            for invocation in CHECKOUT_SCOPED_GIT:
                with self.subTest(asset=relative_path, invocation=invocation):
                    self.assertIn(invocation, content)
            for match in re.finditer(r"(?<![\w-])git (?P<tail>[a-z][^\n`]*)", content):
                tail = match.group("tail")
                if tail.startswith("rev-parse --show-toplevel"):
                    continue
                with self.subTest(asset=relative_path, call=match.group(0)):
                    self.assertTrue(
                        tail.startswith('-C "$ROOT"'),
                        f"unscoped git call: {match.group(0)}",
                    )

    def test_the_announcement_names_the_checkout_as_well(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertIn(flat(OPENING_REPORT), flat(read(relative_path)))

    def test_the_linked_issue_has_a_read_of_its_own(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertIn(flat(LINKED_ISSUE_READ), flat(read(relative_path)))

    def test_the_repository_is_resolved_without_a_github_call_of_its_own(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertNotIn("gh repo view", read(relative_path))

    def test_resolution_precedes_every_github_call(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            first_call = GH_INVOCATION_RE.search(content)
            with self.subTest(asset=relative_path):
                self.assertIsNotNone(first_call)
                self.assertLess(content.index(REPOSITORY_RESOLUTION), first_call.start())
                self.assertLess(content.index(CHECKOUT_RESOLUTION), first_call.start())

    def test_the_opening_report_precedes_every_github_call(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            flattened = flat(content)
            first_call = GH_INVOCATION_RE.search(content)
            with self.subTest(asset=relative_path):
                self.assertLess(
                    flattened.index(flat(OPENING_REPORT)),
                    flat(content[: first_call.start()]).__len__(),
                )

    def test_the_selected_pull_request_is_announced_before_the_review(self):
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            with self.subTest(asset=relative_path):
                self.assertIn(flat(SELECTION_REPORT), flattened)
                self.assertLess(
                    flattened.index(flat(SELECTION_REPORT)),
                    flattened.index("Read its description with"),
                )

    def test_the_docs_worktree_is_resolved_by_branch_before_the_helpers_use_it(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(DOCS_WORKTREE_RESOLUTION, content)
                self.assertLess(
                    content.index(DOCS_WORKTREE_RESOLUTION),
                    content.index(LEDGER_INVOCATIONS[0]),
                )

    def test_the_docs_worktree_resolution_has_no_primary_checkout_fallback(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            flattened = flat(content)
            with self.subTest(asset=relative_path):
                self.assertNotIn(REFUSED_DOCS_WORKTREE_FALLBACK, content)
            for name, phrase in DOCS_WORKTREE_FAIL_CLOSED.items():
                with self.subTest(asset=relative_path, rule=name):
                    self.assertIn(flat(phrase), flattened)


class ReportOnlyTests(unittest.TestCase):
    """Requirement 3: report-only, asserted as an absence as well as a rule."""

    def test_the_report_only_contract_is_stated_in_both_renderings(self):
        for relative_path in RENDERED_ASSETS:
            content = flat(read(relative_path))
            for name, phrase in REPORT_ONLY.items():
                with self.subTest(asset=relative_path, rule=name):
                    self.assertIn(flat(phrase), content)

    def test_neither_rendering_can_create_or_route_a_tracker_issue(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            for spelling in FORBIDDEN_SPELLINGS:
                with self.subTest(asset=relative_path, spelling=spelling):
                    self.assertNotIn(spelling, content)

    def test_neither_rendering_carries_a_commit_or_push_instruction(self):
        # Issue #684's acceptance, asserted rather than left to the grep: the
        # ledger helper's `record` makes the one checkpoint, and an asset
        # carrying any other committing or pushing text reads as permission to
        # land the report or the cursor by hand.
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIsNone(FORBIDDEN_VCS_WRITE_RE.search(content))

    def test_the_terminal_act_is_one_allocated_report_and_the_helper_checkpoint(self):
        for relative_path in RENDERED_ASSETS:
            content = flat(read(relative_path))
            for name, phrase in REPORT_ALLOCATION.items():
                with self.subTest(asset=relative_path, rule=name):
                    self.assertIn(flat(phrase), content)

    def test_the_handoff_names_the_disposition_workflow_for_its_own_brand(self):
        for relative_path, brand in BRAND_OF_ASSET.items():
            with self.subTest(asset=relative_path):
                self.assertIn(f"{renderer.SIGILS[brand]}process-report", read(relative_path))


class LedgerWorkflowTests(unittest.TestCase):
    """Issue #684: one ledger-recorded review per invocation, in both brands."""

    def test_both_assets_resolve_the_ledger_from_their_own_bundle(self):
        for relative_path, brand in BRAND_OF_ASSET.items():
            content = read(relative_path)
            with self.subTest(asset=relative_path):
                for lookup in HELPER_LOOKUPS[brand]:
                    self.assertIn(lookup, content)
                for refused in REFUSED_HELPER_LOOKUPS:
                    self.assertNotIn(refused, content)

    def test_an_unresolvable_helper_stops_before_the_first_read(self):
        phrase = (
            "**An unresolvable helper stops the run here, before the first "
            "read.** Do not substitute a copy tracked in the reviewed "
            "repository, a personal copy, or a path derived from the working "
            "directory"
        )
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertIn(flat(phrase), flat(read(relative_path)))

    def test_the_ledger_is_invoked_for_every_step_of_the_review(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            for invocation in LEDGER_INVOCATIONS:
                with self.subTest(asset=relative_path, invocation=invocation):
                    self.assertIn(invocation, content)

    def test_the_liveness_adapter_is_registered_before_the_claim(self):
        for relative_path, brand in BRAND_OF_ASSET.items():
            content = read(relative_path)
            with self.subTest(asset=relative_path):
                for invocation in LIVENESS_INVOCATIONS:
                    self.assertIn(invocation, content)
                self.assertIn(REGISTRATION[brand], content)
                self.assertNotIn(REGISTRATION["codex" if brand == "claude" else "claude"], content)
                self.assertLess(
                    content.index(REGISTRATION[brand]),
                    content.index(LEDGER_INVOCATIONS[2]),
                )
                # And after the inventory: a repository with nothing to review
                # must spawn no keeper and write no record.
                self.assertLess(
                    content.index("gh api graphql"), content.index(REGISTRATION[brand])
                )

    def test_the_registration_nonce_and_helper_path_are_spelled_literally(self):
        # Both halves, because the hook reads the *unexpanded* command text:
        # `project_review_liveness.py register` is how it recognizes a
        # registration at all, and the digits beside `--nonce` are how it binds
        # the attempt to this invocation. Either as a shell variable and the
        # hook writes no handshake, which registration then reports as
        # `hooks-not-observed` -- indistinguishable from hooks that are off.
        for relative_path, brand in BRAND_OF_ASSET.items():
            content = read(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(
                    REGISTRATION[brand] + "0123456789abcdef0123456789abcdef", content
                )
                self.assertIn(WRAPPED_LAUNCH[brand], content)
                self.assertNotIn(REFUSED_NONCE_SUBSTITUTION, content)
                self.assertNotIn(REFUSED_REGISTRATION_PATH, content)
                self.assertIn(flat(LITERAL_NONCE_RULE), flat(content))
                self.assertIn(flat(LITERAL_PATH_RULE), flat(content))

    def test_no_substitute_liveness_signal_is_offered(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertIn(flat(REFUSED_LIVENESS_FALLBACKS), flat(read(relative_path)))

    def test_one_review_per_invocation_and_no_fall_through(self):
        for relative_path, brand in BRAND_OF_ASSET.items():
            content = flat(read(relative_path))
            for name, phrase in ONE_REVIEW.items():
                with self.subTest(asset=relative_path, rule=name):
                    self.assertIn(flat(rendered_phrase(phrase, brand)), content)

    def test_no_rendering_instructs_a_repeat_or_an_automatic_transition(self):
        for relative_path in RENDERED_ASSETS:
            content = flat(read(relative_path))
            for spelling in REFUSED_REPETITION:
                with self.subTest(asset=relative_path, spelling=spelling):
                    self.assertNotIn(flat(spelling), content)

    def test_the_review_is_pinned_to_a_fetched_detached_worktree(self):
        for relative_path, brand in BRAND_OF_ASSET.items():
            content = read(relative_path)
            flattened = flat(content)
            for command in PINNED_WORKTREE_COMMANDS:
                with self.subTest(asset=relative_path, command=command):
                    self.assertIn(command, content)
            for name, phrase in PINNED_WORKTREE.items():
                with self.subTest(asset=relative_path, rule=name):
                    self.assertIn(flat(rendered_phrase(phrase, brand)), flattened)

    def test_the_default_branch_is_never_read_from_the_local_symref(self):
        # The round-1 blocker: `git fetch` does not refresh
        # `refs/remotes/origin/HEAD`, so an asset resolving the default branch
        # through it pins whatever the remote's default was when the checkout
        # was made. Asserted as an absence beside the live-remote read, because
        # the two spellings look alike and only one of them asks the remote.
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            executable = "\n".join(asset_fences(relative_path))
            with self.subTest(asset=relative_path):
                self.assertIn("ls-remote --symref origin HEAD", executable)
                for spelling in REFUSED_STALE_SYMREF_READS:
                    self.assertNotIn(spelling, executable, spelling)
                # And the prose says why, so the next author does not read the
                # local symref back in as a simplification.
                self.assertIn("refs/remotes/origin/HEAD", content)

    def test_the_dedup_history_is_read_after_the_claim(self):
        # Round 2's blocker: the read taken before the inventory is a snapshot
        # of a row anyone could still record against. The ordering is what is
        # pinned -- the second `read` sits after the claim and inside step 6 --
        # because both reads are the same command and a substring check cannot
        # tell them apart.
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            reads = [
                match.start()
                for match in re.finditer(re.escape(LEDGER_INVOCATIONS[0]), content)
            ]
            with self.subTest(asset=relative_path):
                self.assertEqual(len(reads), 2, reads)
                claim = content.index(LEDGER_INVOCATIONS[2])
                self.assertLess(reads[0], claim)
                self.assertGreater(reads[1], claim)
                self.assertGreater(
                    reads[1],
                    content.index(
                        "### 6. Verify each finding against the pinned tree"
                    ),
                )

    def test_a_failed_worktree_removal_keeps_the_directory_holding_it(self):
        # Round 2's blocker: the attempt's directory contains `$REVIEW_WT`, so
        # a removal that covered both would delete the worktree the step before
        # it had just reported retaining.
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            with self.subTest(asset=relative_path):
                self.assertNotIn(REFUSED_COMBINED_REMOVAL, content)
                self.assertLess(
                    content.index('git -C "$ROOT" worktree remove'),
                    content.index('rm -rf "$ATTEMPT_DIR"'),
                )

    def test_no_removal_target_is_derived_from_another_path(self):
        # The other half of the round-1 cleanup blocker: `dirname` of a
        # variable an early exit never set is `.`, so a derived scratch parent
        # turns cleanup into a recursive removal of the working directory.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertNotIn(REFUSED_DERIVED_REMOVAL, read(relative_path))

    def test_the_fetch_precedes_the_worktree_it_pins(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            with self.subTest(asset=relative_path):
                self.assertLess(
                    content.index('git -C "$ROOT" fetch --quiet origin'),
                    content.index('git -C "$ROOT" worktree add --detach'),
                )

    def test_cleanup_runs_on_every_exit_and_reports_what_it_retained(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            flattened = flat(content)
            for command in CLEANUP_COMMANDS:
                with self.subTest(asset=relative_path, command=command):
                    self.assertIn(command, content)
            for name, phrase in CLEANUP.items():
                with self.subTest(asset=relative_path, rule=name):
                    self.assertIn(flat(phrase), flattened)

    def test_the_migration_stops_on_a_flagged_report(self):
        for relative_path in RENDERED_ASSETS:
            content = flat(read(relative_path))
            for name, phrase in MIGRATION.items():
                with self.subTest(asset=relative_path, rule=name):
                    self.assertIn(flat(phrase), content)

    def test_the_legacy_handling_section_is_present(self):
        for relative_path in RENDERED_ASSETS:
            content = flat(read(relative_path))
            self.assertIn("### Legacy rows", read(relative_path))
            for name, phrase in LEGACY_HANDLING.items():
                with self.subTest(asset=relative_path, rule=name):
                    self.assertIn(flat(phrase), content)

    def test_finding_history_distinguishes_new_repeated_and_recurring(self):
        for relative_path, brand in BRAND_OF_ASSET.items():
            content = flat(read(relative_path))
            for name, phrase in FINDING_HISTORY.items():
                with self.subTest(asset=relative_path, rule=name):
                    self.assertIn(flat(rendered_phrase(phrase, brand)), content)

    def test_the_record_step_is_stated_and_is_the_only_commit(self):
        for relative_path in RENDERED_ASSETS:
            content = flat(read(relative_path))
            for name, phrase in RECORD_STEP.items():
                with self.subTest(asset=relative_path, rule=name):
                    self.assertIn(flat(phrase), content)

    def test_the_completion_message_names_the_whole_outcome(self):
        for relative_path, brand in BRAND_OF_ASSET.items():
            content = flat(read(relative_path))
            for line in COMPLETION_MESSAGE:
                with self.subTest(asset=relative_path, line=line):
                    self.assertIn(flat(line), content)
            with self.subTest(asset=relative_path):
                self.assertIn(flat(COMPLETION_STOP), content)
                self.assertIn(
                    f"{renderer.SIGILS[brand]}auto-project-review", read(relative_path)
                )

    def test_the_steps_are_ordered_the_way_the_review_runs(self):
        order = (
            "### 1. Take a complete inventory of merged pull requests",
            "### 2. Register the session liveness adapter, and reclaim what "
            "earlier attempts left",
            "### 3. Select and claim exactly one pull request",
            "### 4. Pin the review tree",
            "### 5. Review the pull request",
            "### 6. Verify each finding against the pinned tree and the row's history",
            "### 7. Write a report only for new findings",
            "### 8. Record the completed attempt",
            "### 9. Clean up, on every exit",
            "### 10. Report, and stop",
        )
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            positions = []
            for heading in order:
                with self.subTest(asset=relative_path, heading=heading):
                    self.assertIn(heading, content)
                positions.append(content.index(heading))
            with self.subTest(asset=relative_path):
                self.assertEqual(positions, sorted(positions))


class DirectModeTests(unittest.TestCase):
    """Requirement 7: the cursor survives, explicit-only, in one section."""

    def test_the_direct_section_is_explicit_only(self):
        for relative_path in RENDERED_ASSETS:
            _, direct = sections_of(read(relative_path))
            flattened = flat(direct)
            for name, phrase in EXPLICIT_DIRECT_MODE.items():
                with self.subTest(asset=relative_path, rule=name):
                    self.assertIn(flat(phrase), flattened)

    def test_every_cursor_invocation_lives_in_the_direct_section(self):
        for relative_path in RENDERED_ASSETS:
            pr_mode, direct = sections_of(read(relative_path))
            for invocation in CURSOR_INVOCATIONS:
                with self.subTest(asset=relative_path, invocation=invocation):
                    self.assertIn(invocation, direct)
                    self.assertNotIn(invocation, pr_mode)

    def test_pr_mode_names_no_cursor_invocation(self):
        # The negative control for every ledger pin above. The cursor still
        # ships and the direct section still calls it, so a document that had
        # gained the ledger steps while keeping its cursor-driven PR sweep
        # would pass all of them. It cannot pass this one: `$CURSOR` appears in
        # PR mode only where the three helpers are resolved together, and the
        # PR-mode subcommands are gone by name.
        for relative_path in RENDERED_ASSETS:
            pr_mode, _ = sections_of(read(relative_path))
            content = read(relative_path)
            with self.subTest(asset=relative_path):
                self.assertNotIn('python3 "$CURSOR"', pr_mode)
            for spelling in REFUSED_PR_CURSOR_INVOCATIONS:
                with self.subTest(asset=relative_path, spelling=spelling):
                    self.assertNotIn(spelling, content)

    def test_the_direct_mode_rules_reach_both_brands(self):
        for relative_path in RENDERED_ASSETS:
            _, direct = sections_of(read(relative_path))
            flattened = flat(direct)
            for name, phrase in DIRECT_MODE.items():
                with self.subTest(asset=relative_path, rule=name):
                    self.assertIn(flat(phrase), flattened)

    def test_the_direct_walk_is_the_whole_first_parent_history(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(DIRECT_WALK, content)
                self.assertNotIn(REFUSED_SLICED_DIRECT_WALK, content)


class ReportShapeTests(unittest.TestCase):
    """Requirement 4: the capture shape and the canonical report structure."""

    def test_the_capture_shape_reaches_both_brands(self):
        for relative_path in RENDERED_ASSETS:
            content = flat(read(relative_path))
            for section in CAPTURE_SECTIONS:
                with self.subTest(asset=relative_path, section=section):
                    self.assertIn(flat(section), content)

    def test_the_canonical_report_structure_reaches_both_brands(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            flattened = flat(content)
            for name, phrase in REPORT_STRUCTURE.items():
                with self.subTest(asset=relative_path, part=name):
                    self.assertIn(flat(phrase), flattened)


class PreservedBehaviorTests(unittest.TestCase):
    """Requirement 9: D-2's behavior, vendored as it reads today."""

    def test_every_preserved_rule_survives_in_both_renderings(self):
        for relative_path, brand in BRAND_OF_ASSET.items():
            content = flat(read(relative_path))
            for name, phrase in PRESERVED_BEHAVIOR.items():
                with self.subTest(asset=relative_path, rule=name):
                    self.assertIn(flat(rendered_phrase(phrase, brand)), content)
            with self.subTest(asset=relative_path, rule="clean review"):
                self.assertIn(flat(CLEAN_REVIEW), content)


class BrandBoundaryTests(unittest.TestCase):
    """Requirement 8, and the negative control for every pin above.

    Every rule in this module is an `assertIn` over both rendered bodies, so a
    phrase that appeared in neither because the render collapsed them would
    still pass each one. This class is what makes that impossible: the two
    bodies differ by exactly the declared per-brand lines and nothing else, so a
    body that lost a rule lost it in both and every pin above fails with it.
    """

    def setUp(self):
        self.bodies = {
            brand: body_of(read(path)) for path, brand in BRAND_OF_ASSET.items()
        }

    def test_the_bodies_differ_only_by_the_declared_brand_lines(self):
        stripped = {}
        for brand, body in self.bodies.items():
            lines = [
                line
                for line in body.splitlines()
                if line not in CLAUDE_ONLY_LINES and line not in CODEX_ONLY_LINES
            ]
            stripped[brand] = neutralize("\n".join(lines), brand)
        self.assertEqual(stripped["claude"], stripped["codex"])

    def test_the_declared_command_references_are_the_ones_the_source_names(self):
        self.assertTrue(REFERENCED_WORKFLOWS)
        for brand, body in self.bodies.items():
            sigil = renderer.SIGILS[brand]
            for name in REFERENCED_WORKFLOWS:
                with self.subTest(brand=brand, name=name):
                    self.assertIn(f"{sigil}{name}", body)

    def test_the_codex_sandbox_caveat_is_absent_from_the_claude_rendering(self):
        self.assertIn(CODEX_ONLY_CAVEAT, self.bodies["codex"])
        self.assertNotIn(CODEX_ONLY_CAVEAT.strip(), self.bodies["claude"])

    def test_the_argument_convention_is_per_brand(self):
        self.assertIn(CLAUDE_ONLY_LINES[0], self.bodies["claude"])
        self.assertNotIn(CLAUDE_ONLY_LINES[0], self.bodies["codex"])
        self.assertIn(CODEX_ONLY_LINES[0], self.bodies["codex"])
        self.assertNotIn(CODEX_ONLY_LINES[0], self.bodies["claude"])

    def test_each_brand_reads_its_own_invocation_sigil(self):
        # Measured with the renderer's own notion of where an invocation
        # token starts and ends, not with a bare substring: the Codex asset
        # resolves its helpers through the bundle path
        # `*/skills/project-review/scripts/...`, and a substring check would
        # read that path segment as a Claude invocation and fail on it. The
        # renderer already draws that line -- it is what refuses a literal
        # sigil in an authored source -- so the test reads the line from there
        # rather than drawing a second one that could disagree.
        for brand, relative_path in (("claude", CLAUDE_ASSET), ("codex", CODEX_ASSET)):
            content = read(relative_path)
            own = renderer.SIGILS[brand]
            other = renderer.SIGILS["codex" if brand == "claude" else "claude"]
            with self.subTest(asset=relative_path):
                self.assertIn(f"{own}project-review", content)
                self.assertIn(
                    "project-review",
                    renderer.LITERAL_INVOCATION_PATTERNS[own].findall(content),
                )
                self.assertNotIn(
                    "project-review",
                    renderer.LITERAL_INVOCATION_PATTERNS[other].findall(content),
                )


class BundledHelperTests(unittest.TestCase):
    """Each mechanism ships with the command that calls it, in both bundles."""

    def test_both_bundles_carry_each_helper_and_the_copies_are_identical(self):
        # Vendored the way trusted_issue_spec.py is: no tracked tools/ original,
        # because nothing in this repository invokes it -- the workflow runs in
        # whatever repository it was pointed at, and that repository tracks no
        # copy of anything this bundle ships. Two copies then have to be held
        # identical, or the two brands diverge exactly the way the 223 lines
        # this command was vendored to reconcile did.
        for name, copies in BUNDLED_HELPERS.items():
            claude = (REPO_ROOT / copies["claude"]).read_bytes()
            codex = (REPO_ROOT / copies["codex"]).read_bytes()
            with self.subTest(helper=name):
                self.assertTrue(claude, copies["claude"])
                self.assertEqual(claude, codex)

    def test_the_cursor_helper_spawns_no_external_command(self):
        # The reconciliation is arithmetic over listings the workflow already
        # took, so the helper needs no repository access of its own. Pinned as
        # an absence because a helper that shelled out would need declaring in
        # docs/agent-workflow-contract.md, and would also be reaching a
        # checkout the caller never told it about.
        source = (REPO_ROOT / CLAUDE_CURSOR_HELPER).read_text(encoding="utf-8")
        for forbidden in ("subprocess", "os.system", "os.popen"):
            with self.subTest(spelling=forbidden):
                self.assertNotIn(forbidden, source)


def load_cursor_helper(brand: str):
    """The bundled helper, imported from the copy `brand` actually ships.

    Loaded by path under a private name because it is a bundled asset rather
    than an importable package: `tools/` is not its home, and giving it one
    would make the tests pass against a module the workflow never reaches.
    """
    path = REPO_ROOT / CURSOR_HELPERS[brand]
    spec = importlib.util.spec_from_file_location(
        f"kanban_{brand}_plugin_project_review_cursor", path
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CURSOR_MODULES = {brand: load_cursor_helper(brand) for brand in CURSOR_HELPERS}
CURSOR = CURSOR_MODULES["claude"]

REPO = "coghex/kanban"

# A merged history whose number order is deliberately not its merge order:
# #471 merged before #468 and #470, exactly the way the real batch recorded in
# docs/project_review_466-399.md ran #466, #467, #465, #464, #406 … A cursor
# that kept "the smallest number reviewed" would describe a batch that never
# happened, and would then hand the next invocation a starting point above
# work it had already done.
PR_HISTORY = (
    (470, "2026-08-20T00:00:00Z"),
    (468, "2026-08-19T00:00:00Z"),
    (471, "2026-08-18T00:00:00Z"),
    (466, "2026-08-17T00:00:00Z"),
    (465, "2026-08-16T00:00:00Z"),
    (464, "2026-08-15T00:00:00Z"),
    (463, "2026-08-14T00:00:00Z"),
    (462, "2026-08-13T00:00:00Z"),
    (461, "2026-08-12T00:00:00Z"),
)

# `gh pr list` does not return merge order, so the listing handed to the helper
# is deliberately in some other order: sorting it is the helper's job, and a
# fixture that pre-sorted it would never exercise that.
PR_LISTING = [
    {"number": number, "mergedAt": merged_at}
    for number, merged_at in sorted(PR_HISTORY)
]

# A first-parent walk, newest-first, as `git log --first-parent --format=%H`
# prints it.
DIRECT_HISTORY = (
    "ed90877ac1",
    "6d54e98bb2",
    "3b3c54f0c3",
    "a920f7cd14",
    "b80f628e25",
    "e84f7320f6",
    "65001ff1a7",
    "331d70e2b8",
)


class CursorTransitionCase(unittest.TestCase):
    """A docs worktree, and the helper acting on it across invocations.

    Every assertion below goes through the shipped module's own serialization
    and reconciliation rather than through a selection oracle written here.
    That is the point: the defect this issue reports is invisible to a
    substring check, because the prose already claimed the cursor was
    preserved. What was missing was a mechanism, so what is tested is the
    mechanism.
    """

    def setUp(self):
        self.worktree = Path(tempfile.mkdtemp(prefix="project-review-cursor-"))
        self.addCleanup(shutil.rmtree, self.worktree, ignore_errors=True)
        (self.worktree / "docs").mkdir()
        self.module = CURSOR

    # -- the workflow's own two calls, made the way the asset makes them ----

    def state(self):
        """A fresh read, as a later invocation carrying no context would do."""
        return self.module.state_for(self.module.load_document(self.worktree), REPO)

    def page(self, rows):
        """The newest `rows` merged pull requests, as a bounded `gh` page.

        `gh pr list --limit N` returns a page of the newest N merges, so a
        bounded listing is a prefix of merge order -- and the older units the
        sweep is resuming towards are exactly what falls off it.
        """
        ordered = sorted(PR_HISTORY, key=lambda entry: entry[1], reverse=True)
        return [
            {"number": number, "mergedAt": merged_at}
            for number, merged_at in ordered[:rows]
        ]

    def select(self, mode="pr", count=3, state=None, candidates=None, **kwargs):
        listing = PR_LISTING if mode == "pr" else list(DIRECT_HISTORY)
        return self.module.select(
            self.state() if state is None else state,
            mode,
            self.module.normalize_candidates(
                mode, listing if candidates is None else candidates
            ),
            count,
            reports=self.module.report_coverage(self.worktree),
            **kwargs,
        )

    def record(self, selection, mode="pr", exclude=(), boundary=None):
        listing = PR_LISTING if mode == "pr" else list(DIRECT_HISTORY)
        updated = self.module.record(
            self.state(),
            mode,
            self.module.normalize_candidates(mode, listing),
            [self.units(selection)] if isinstance(selection, (int, str)) else self.units(selection),
            list(exclude),
            boundary=boundary,
        )
        document = self.module.load_document(self.worktree)
        document.setdefault("repositories", {})[REPO] = updated
        self.module.write_document(self.worktree, document)
        return updated

    def units(self, selection):
        if isinstance(selection, dict):
            selection = selection["selected"]
        if isinstance(selection, (int, str)):
            return selection
        return [
            entry["number"] if "number" in entry else entry["sha"] for entry in selection
        ]

    def write_report(self, name, body="# Project Review Findings\n"):
        (self.worktree / "docs" / name).write_text(body, encoding="utf-8")

    def run_cli(self, command, *arguments):
        """One invocation of the surface the rendered assets actually run.

        The library calls above are the same code, but the argument parsing,
        the unit lists, and the stdin/file candidate reading are only exercised
        here — and those are what an asset's fence is made of.
        """
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            self.module.main(
                [command, "--root", str(self.worktree), "--repo", REPO, *arguments]
            )
        return json.loads(captured.getvalue())

    def forget_the_cursor(self):
        """Delete the record, leaving the reports and the history untouched.

        The negative control every transition below owes: if an assertion still
        holds once the record is gone, durable state was not what produced it.
        """
        self.module.document_path(self.worktree).unlink()


class CursorSelectionTests(CursorTransitionCase):
    """Requirement 3 and requirement 9: the transitions, not the prose."""

    def test_a_clean_batch_records_and_the_next_invocation_starts_at_head(self):
        # The defect, end to end. A clean batch writes no report, so before
        # this mechanism it left nothing at all behind and the next invocation
        # re-selected the batch it had just finished.
        first = self.select(count=3)
        self.assertEqual(self.units(first), [470, 468, 471])
        self.assertEqual(first["origin"], "history-head")

        self.record(first)  # clean: no report written, cursor recorded anyway
        self.assertEqual(list((self.worktree / "docs").glob("project_review_*.md")),
                         [self.module.document_path(self.worktree)])

        second = self.select(count=3)
        self.assertEqual(self.units(second), [466, 465, 464])
        self.assertEqual(second["origin"], "history-head")

        # Remove the durable reviewed set and the second invocation repeats the first --
        # which is exactly what was observed twice while
        # docs/project_review_466-399.md was being produced.
        self.forget_the_cursor()
        self.assertEqual(self.units(self.select(count=3)), [470, 468, 471])

    def test_a_finding_bearing_batch_records_the_same_coverage_as_a_clean_one(self):
        # Requirement 1: the two batches differ only in whether a report was
        # also written, so the state they leave has to be identical.
        clean = self.record(self.select(count=3))
        reference = json.dumps(clean, sort_keys=True)

        # The second run differs only in that the batch produced a finding, so
        # a report is written between the selection and the record -- which is
        # the order the workflow uses, and the order that keeps the report from
        # reconciling against the batch that is producing it.
        self.setUp()
        selection = self.select(count=3)
        self.write_report("project_review_471-470.md")
        finding_bearing = self.record(selection)
        self.assertEqual(json.dumps(finding_bearing, sort_keys=True), reference)
        self.assertEqual(self.units(self.select(count=3)), [466, 465, 464])
        self.assertIsNone(finding_bearing["pr"]["endpoint"])
        self.assertEqual(finding_bearing["pr"]["reviewed"], [468, 470, 471])

    def test_the_boundary_is_exclusive_and_resolved_in_merge_order(self):
        self.record([], boundary=471)
        selection = self.select(count=6)
        self.assertEqual(self.units(selection), [470, 468])
        self.assertEqual(selection["origin"], "recorded-boundary")
        self.assertTrue(selection["boundary_reached"])

        numeric = self.module.empty_state()
        numeric["pr"]["endpoint"] = {
            "number": 468,
            "merged_at": "2026-08-19T00:00:00Z",
        }
        self.assertEqual(self.units(self.select(count=6, state=numeric)), [470])

    def test_a_boundary_at_merged_head_is_an_empty_completed_pr_sweep(self):
        self.record([], boundary=470)
        selection = self.select(count=3)
        self.assertEqual(self.units(selection), [])
        self.assertTrue(selection["short"])
        self.assertTrue(selection["boundary_reached"])
        self.assertFalse(selection["bounded"])
        self.assertFalse(selection["truncated"])
        self.assertFalse(selection["exhausted"])

    def test_a_report_whose_coverage_overlaps_the_naive_selection_is_skipped(self):
        # The second correction the real sweep had to make: the batch below
        # the cursor was already covered by a separate report, and nothing
        # noticed until a human read the directory.
        self.record(self.select(count=3))
        self.write_report("project_review_465-464.md")

        selection = self.select(count=3)
        self.assertEqual(self.units(selection), [466, 463, 462])
        self.assertEqual(
            [entry["unit"] for entry in selection["skipped"]],
            [470, 468, 471, 465, 464],
        )

        # Without the report the same invocation takes the two units back, so
        # the skip is the report's doing rather than an artifact of the count.
        self.module.document_path(self.worktree)  # unchanged
        (self.worktree / "docs" / "project_review_465-464.md").unlink()
        self.assertEqual(self.units(self.select(count=3)), [466, 465, 464])

    def test_a_report_does_not_cover_the_numbers_between_its_endpoints(self):
        # Third spec addition. docs/project_review_463-455.md reviewed #463,
        # #456 and #455 and nothing between them, so reading `463-455` as
        # fifteen reviewed pull requests would erase twelve unreviewed ones --
        # silently, and permanently.
        self.write_report("project_review_466-462.md")
        selection = self.select(count=5)
        self.assertEqual(self.units(selection), [470, 468, 471, 465, 464])
        self.assertNotIn(466, self.units(selection))
        self.assertNotIn(462, self.units(selection))

    def test_a_direct_commit_inside_a_reported_interval_is_still_selected(self):
        # Requirement 5. docs/project_review_463-455.md states that no direct
        # first-parent commits landed in its interval while eight did, so a
        # report's account of the commits it covered establishes nothing at
        # all: coverage in direct mode comes from the record or from nowhere.
        self.write_report("project_review_direct_ed90877-331d70e.md")
        self.write_report("project_review_466-461.md")
        selection = self.select(mode="direct", count=3)
        self.assertEqual(self.units(selection), list(DIRECT_HISTORY[:3]))
        self.assertEqual(selection["skipped"], [])

        recorded = self.record(selection, mode="direct")
        self.assertEqual(
            recorded["direct"]["endpoint"], {"sha": DIRECT_HISTORY[2]}
        )
        self.assertEqual(
            self.units(self.select(mode="direct", count=3)),
            list(DIRECT_HISTORY[3:6]),
        )
        self.forget_the_cursor()
        self.assertEqual(
            self.units(self.select(mode="direct", count=3)),
            list(DIRECT_HISTORY[:3]),
        )

    def test_direct_mode_reports_uncovered_units_above_its_resume_frontier(self):
        first = self.select(
            mode="direct", count=2, start=DIRECT_HISTORY[3]
        )
        self.record(first, mode="direct")

        later = self.select(mode="direct", count=5)
        self.assertEqual(later["gaps"], list(DIRECT_HISTORY[:3]))
        self.assertEqual(self.units(later), list(DIRECT_HISTORY[5:]))

    def test_an_explicitly_excluded_unit_is_never_selected_again(self):
        # Requirement 4 and the review's second spec addition: an exclusion is
        # persisted independently of the endpoint, because advancing the
        # endpoint past it would otherwise be indistinguishable from having
        # reviewed it.
        self.record(self.select(count=3), exclude=[466])
        self.assertEqual(self.units(self.select(count=3)), [465, 464, 463])

        self.record(self.select(count=2))
        self.assertEqual(self.units(self.select(count=3)), [463, 462, 461])
        self.assertEqual(self.state()["excluded"]["prs"], [466])

    def test_a_requested_range_is_not_filled_from_beyond_its_older_end(self):
        # Round 4's blocker. Coverage thins the middle of the request, and
        # without an older bound the count makes the number up from below it —
        # so the user who asked for #466–#461 gets units they did not ask for,
        # and the sweep advances past them.
        self.write_report("project_review_471-468.md")
        selection = self.select(count=6, start=470, end=464)
        self.assertEqual(self.units(selection), [470, 466, 465, 464])
        self.assertTrue(selection["short"])
        self.assertTrue(selection["bounded"])
        self.assertFalse(selection["exhausted"])
        self.assertFalse(selection["truncated"])

        # The negative control, and the defect itself: the same request without
        # the older bound makes the count up from below #464, so the user is
        # handed two units they did not ask for and the sweep advances past
        # them.
        unbounded = self.select(count=6, start=470)
        self.assertEqual(self.units(unbounded), [470, 466, 465, 464, 463, 462])
        self.assertFalse(unbounded["bounded"])

    def test_a_range_bound_stops_the_batch_before_the_count_is_met(self):
        # The bound is a bound, not a target: it wins over a count that still
        # had room, in both modes.
        pr = self.select(count=9, start=470, end=466)
        self.assertEqual(self.units(pr), [470, 468, 471, 466])
        direct = self.select(
            mode="direct", count=9, start=DIRECT_HISTORY[1], end=DIRECT_HISTORY[3]
        )
        self.assertEqual(self.units(direct), list(DIRECT_HISTORY[1:4]))

    def test_a_range_end_may_be_abbreviated_and_is_refused_when_absent(self):
        bounded = self.select(mode="direct", count=9, end=DIRECT_HISTORY[2][:5])
        self.assertEqual(self.units(bounded), list(DIRECT_HISTORY[:3]))
        with self.assertRaises(self.module.CursorError) as caught:
            self.select(count=3, end=9999)
        self.assertIn("the range ends at pull request #9999", str(caught.exception))

    def test_a_range_cannot_cross_the_boundary_without_an_override(self):
        self.record([], boundary=464)
        with self.assertRaises(self.module.CursorError) as caught:
            self.select(count=9, start=470, end=463)
        self.assertIn("beyond recorded boundary #464", str(caught.exception))

    def test_a_count_changes_the_batch_size_and_not_the_position(self):
        # Correction 1. Both selections begin at the same unit; only how many
        # follow it differs.
        self.record(self.select(count=3))
        small = self.select(count=1)
        large = self.select(count=5)
        self.assertEqual(self.units(small), [466])
        self.assertEqual(self.units(large)[0], 466)
        self.assertEqual(small["begin_index"], large["begin_index"])
        self.assertEqual(small["origin"], large["origin"])

    def test_only_an_explicit_start_or_override_moves_the_position(self):
        self.record(self.select(count=3))
        started = self.select(count=2, start=465)
        self.assertEqual(self.units(started), [465, 464])
        self.assertEqual(started["origin"], "explicit-start")

        # An override lifts the coverage the position was built from as well
        # as the position itself; otherwise it moves the sweep back to the
        # head and then skips everything it finds there.
        overridden = self.select(count=2, override_boundary=True)
        self.assertEqual(self.units(overridden), [470, 468])
        self.assertEqual(overridden["origin"], "boundary-override")

    def test_an_override_still_honors_an_explicit_exclusion(self):
        # Requirement 4 is unconditional about this: a boundary override says
        # the coverage is wrong, not that the user changed their mind about a
        # unit they removed from the sweep.
        self.record(self.select(count=3), exclude=[466])
        overridden = self.select(count=9, override_boundary=True)
        self.assertNotIn(466, self.units(overridden))
        self.assertEqual(self.units(overridden)[0], 470)

    def test_units_above_an_older_batch_are_selected_from_head_not_reported_as_gaps(self):
        self.record([], boundary=461)
        self.record(self.select(count=2, start=465))
        later = self.select(count=9)
        self.assertEqual(self.units(later), [470, 468, 471, 466, 463, 462])
        self.assertEqual(later["gaps"], [])
        self.assertTrue(later["boundary_reached"])
        self.assertFalse(later["exhausted"])

    def test_a_report_never_moves_the_resume_position(self):
        # The other half of "a report covers only what it identifies": if a
        # report set the position as well as the coverage, everything it
        # skipped inside its own interval would fall above the resume point
        # and never be selected again. Re-reviewing two announced units is the
        # cheaper of the two errors, and the only one that can be noticed.
        self.write_report("project_review_466-461.md")
        selection = self.select(count=9)
        self.assertEqual(selection["origin"], "history-head")
        self.assertEqual(selection["begin_index"], 0)
        self.assertEqual(self.units(selection), [470, 468, 471, 465, 464, 463, 462])

    def test_a_batch_shorter_than_the_count_is_the_tail_rather_than_an_error(self):
        selection = self.select(count=50)
        self.assertEqual(len(selection["selected"]), len(PR_HISTORY))
        self.assertTrue(selection["exhausted"])

    def test_an_absent_recorded_endpoint_stops_the_run(self):
        # Fourth spec addition: a recorded PR is validated against merged
        # history rather than assumed. A cursor naming a pull request this
        # repository never merged belongs to some other repository, and
        # sweeping past it would review history twice.
        foreign = self.module.empty_state()
        foreign["pr"]["endpoint"] = {"number": 9999, "merged_at": "2026-01-01T00:00:00Z"}
        with self.assertRaises(self.module.CursorError) as caught:
            self.select(count=3, state=foreign)
        self.assertIn("does not belong to this repository", str(caught.exception))

    def test_an_absent_recorded_sha_stops_the_run(self):
        foreign = self.module.empty_state()
        foreign["direct"]["endpoint"] = {"sha": "0123456"}
        with self.assertRaises(self.module.CursorError) as caught:
            self.select(mode="direct", count=3, state=foreign)
        self.assertIn("first-parent ancestry", str(caught.exception))

    def test_an_absent_supplied_start_is_an_invalid_request(self):
        with self.assertRaises(self.module.CursorError) as caught:
            self.select(count=3, start=9999)
        self.assertIn("not in this repository's merged history", str(caught.exception))

    def test_a_candidate_without_a_merge_timestamp_cannot_be_ordered(self):
        with self.assertRaises(self.module.CursorError):
            self.module.normalize_candidates("pr", [{"number": 470}])


class BoundedListingTests(CursorTransitionCase):
    """Round 1's blocker: a page is not a history, and the two must not read
    alike.

    `gh pr list --limit N` returns the newest N merges. A fixed boundary can
    fall beyond that page even when the selectable head rows are all present,
    so the page cannot prove that a short batch has reached the stop rather
    than merely running out of listed candidates. Reading truncation as either
    the boundary or repository tail can leave merged work unreviewed or enter
    direct mode prematurely.
    """

    def test_a_page_ending_at_the_boundary_stops_there(self):
        self.record([], boundary=471)
        boundary = self.state()["pr"]["endpoint"]["number"]

        # The page reaches the boundary and proves the exclusive stop.
        page = self.page(3)
        self.assertEqual(page[-1]["number"], boundary)
        selection = self.select(count=3, candidates=page, listing_limit=3)
        self.assertEqual(self.units(selection), [470, 468])
        self.assertTrue(selection["short"])
        self.assertTrue(selection["boundary_reached"])
        self.assertFalse(selection["bounded"])
        self.assertFalse(selection["truncated"])
        self.assertFalse(selection["exhausted"])

    def test_an_unbounded_short_page_at_its_limit_is_truncated(self):
        state = self.module.empty_state()
        state["pr"]["reviewed"] = [470, 468]
        selection = self.select(
            count=3, state=state, candidates=self.page(3), listing_limit=3
        )
        self.assertEqual(self.units(selection), [471])
        self.assertTrue(selection["short"])
        self.assertFalse(selection["bounded"])
        self.assertFalse(selection["boundary_reached"])
        self.assertTrue(selection["truncated"])
        self.assertFalse(selection["exhausted"])

    def test_a_page_under_its_limit_that_comes_up_short_is_the_tail(self):
        # The other half, and the reason the two answers cannot be collapsed
        # into one refusal: a genuine tail must still be reviewed and must
        # still let PR history exhaust so direct mode is reached.
        selection = self.select(count=50, candidates=PR_LISTING, listing_limit=200)
        self.assertEqual(len(selection["selected"]), len(PR_HISTORY))
        self.assertTrue(selection["short"])
        self.assertFalse(selection["truncated"])
        self.assertTrue(selection["exhausted"])

    def test_an_undeclared_limit_is_taken_as_a_complete_listing(self):
        # The unbounded caller is the real one: direct mode hands over a whole
        # `git log --first-parent` walk, so reporting that as possibly
        # truncated would send the workflow raising a limit it never set. PR
        # mode always declares one, which the asset pin above holds it to.
        selection = self.select(count=3, candidates=self.page(2))
        self.assertTrue(selection["short"])
        self.assertTrue(selection["exhausted"])
        self.assertFalse(selection["truncated"])

        walk = self.select(mode="direct", count=50)
        self.assertTrue(walk["exhausted"])
        self.assertFalse(walk["truncated"])

    def test_a_unit_absent_from_a_full_page_asks_for_a_wider_one(self):
        # The refusals split the same way. "Not in this repository's merged
        # history at all" is a claim a bounded page cannot support, and acting
        # on it stops a sweep that only needed a larger number.
        page = self.page(3)
        with self.assertRaises(self.module.CursorError) as caught:
            self.select(count=3, candidates=page, listing_limit=3, start=464)
        self.assertIn(self.module.RAISE_LIMIT_INSTRUCTION, str(caught.exception))
        self.assertNotIn(
            "is not in this repository's merged history", str(caught.exception)
        )

        with self.assertRaises(self.module.CursorError) as caught:
            self.select(count=3, candidates=page, listing_limit=99, start=464)
        self.assertIn(
            "is not in this repository's merged history", str(caught.exception)
        )
        self.assertNotIn(self.module.RAISE_LIMIT_INSTRUCTION, str(caught.exception))

    def test_an_endpoint_off_the_page_asks_for_a_wider_one(self):
        self.record([], boundary=464)
        page = self.page(3)
        with self.assertRaises(self.module.CursorError) as caught:
            self.select(count=3, candidates=page, listing_limit=3)
        self.assertIn(self.module.RAISE_LIMIT_INSTRUCTION, str(caught.exception))
        self.assertNotIn("does not belong to this repository", str(caught.exception))

    def test_a_merge_during_review_does_not_strand_a_completed_batch(self):
        # Round 1's second blocker. The recording listing is taken after the
        # batch was reviewed and its report written; merges landing in between
        # push older rows off a bounded page, so the limit that reached the
        # batch at selection time need not reach it now. Refusing that as a
        # wrong claim leaves an already-reviewed batch with no durable
        # endpoint -- the exact state this cursor exists to prevent.
        selection = self.select(count=3, candidates=self.page(4), listing_limit=4)
        reviewed = self.units(selection)
        self.assertEqual(reviewed, [470, 468, 471])

        # Two newer pull requests merge while the batch is being reviewed, so
        # the same limit now returns a page that stops above the batch.
        later = [
            {"number": 480, "mergedAt": "2026-08-22T00:00:00Z"},
            {"number": 481, "mergedAt": "2026-08-21T00:00:00Z"},
        ] + self.page(2)
        with self.assertRaises(self.module.CursorError) as caught:
            self.module.record(
                self.state(),
                "pr",
                self.module.normalize_candidates("pr", later),
                reviewed,
                listing_limit=4,
            )
        self.assertIn(self.module.RAISE_LIMIT_INSTRUCTION, str(caught.exception))

        # Raising the limit records the batch that was already reviewed.
        widened = self.module.normalize_candidates(
            "pr",
            [
                {"number": 480, "mergedAt": "2026-08-22T00:00:00Z"},
                {"number": 481, "mergedAt": "2026-08-21T00:00:00Z"},
            ]
            + PR_LISTING,
        )
        recorded = self.module.record(
            self.state(), "pr", widened, reviewed, listing_limit=40
        )
        self.assertIsNone(recorded["pr"]["endpoint"])
        self.assertEqual(recorded["pr"]["reviewed"], [468, 470, 471])

    def test_an_absent_unit_in_a_complete_listing_is_still_refused_outright(self):
        # The negative control for the rule above: the softer refusal must be
        # the bounded-page case alone, or a genuinely wrong claim would send
        # the workflow into an unbounded raise-and-retry loop.
        with self.assertRaises(self.module.CursorError) as caught:
            self.module.record(
                self.state(),
                "pr",
                self.module.normalize_candidates("pr", PR_LISTING),
                [9999],
                listing_limit=200,
            )
        self.assertIn("absent from the candidate history", str(caught.exception))
        self.assertNotIn(self.module.RAISE_LIMIT_INSTRUCTION, str(caught.exception))


class AbbreviatedShaTests(CursorTransitionCase):
    """Round 2's blocker: one commit, several spellings.

    `git log --format=%H` prints forty characters. A user naming a commit reads
    the seven a direct-mode report filename carries — `docs/project_review_
    direct_<newest7>-<oldest7>.md` is the shape this workflow writes — and an
    endpoint recorded by an earlier run may be in either. Exact equality
    refuses a correctly-spelled commit as absent, which is a stop the sweep
    cannot be argued out of.
    """

    def test_an_abbreviated_start_names_the_commit_it_identifies(self):
        selection = self.select(mode="direct", count=2, start=DIRECT_HISTORY[2][:7])
        self.assertEqual(
            self.units(selection), list(DIRECT_HISTORY[2:4])
        )
        self.assertEqual(selection["origin"], "explicit-start")
        # The full spelling is the same request, so the two agree.
        self.assertEqual(
            self.units(self.select(mode="direct", count=2, start=DIRECT_HISTORY[2])),
            self.units(selection),
        )

    def test_an_abbreviated_recorded_endpoint_still_positions_the_sweep(self):
        # A cursor written by an earlier run, or by a walk taken with
        # `--format=%h`, holds a short SHA. It has to keep working against a
        # `%H` walk, or the sweep stops on state it wrote itself.
        short = self.module.empty_state()
        short["direct"]["endpoint"] = {"sha": DIRECT_HISTORY[1][:7]}
        selection = self.select(mode="direct", count=2, state=short)
        self.assertEqual(self.units(selection), list(DIRECT_HISTORY[2:4]))
        self.assertEqual(selection["origin"], "recorded-endpoint")

    def test_an_abbreviated_coverage_or_exclusion_entry_still_matches(self):
        short = self.module.empty_state()
        short["direct"]["reviewed"] = [DIRECT_HISTORY[0][:7]]
        short["excluded"]["commits"] = [DIRECT_HISTORY[1][:8]]
        selection = self.select(mode="direct", count=2, state=short)
        self.assertEqual(self.units(selection), list(DIRECT_HISTORY[2:4]))
        self.assertEqual(
            sorted(entry["reason"] for entry in selection["skipped"]),
            ["covered", "excluded"],
        )

    def test_recording_an_abbreviated_unit_stores_the_history_spelling(self):
        # The state converges on one name per commit rather than accumulating
        # a second every time a walk is taken with a different abbreviation.
        recorded = self.module.record(
            self.state(),
            "direct",
            self.module.normalize_candidates("direct", list(DIRECT_HISTORY)),
            [DIRECT_HISTORY[0][:7], DIRECT_HISTORY[1][:7]],
            [DIRECT_HISTORY[2][:7]],
        )
        self.assertEqual(recorded["direct"]["endpoint"], {"sha": DIRECT_HISTORY[1]})
        self.assertEqual(
            recorded["direct"]["reviewed"], sorted(DIRECT_HISTORY[:2])
        )
        self.assertEqual(recorded["excluded"]["commits"], [DIRECT_HISTORY[2]])

    def test_an_ambiguous_prefix_is_refused_rather_than_chosen(self):
        # The other half, and why this is a resolution rather than a loosened
        # comparison: a prefix naming two commits names neither, and picking
        # one would sweep a range nobody asked for.
        history = ["abcdef01aa", "abcdef01bb", "9999999999"]
        with self.assertRaises(self.module.CursorError) as caught:
            self.select(
                mode="direct", count=1, candidates=history, start="abcdef0"
            )
        message = str(caught.exception)
        self.assertIn("names 2 commits", message)
        self.assertIn("abcdef01aa", message)
        self.assertIn("abcdef01bb", message)
        # Enough characters resolves it.
        self.assertEqual(
            self.units(
                self.select(
                    mode="direct", count=1, candidates=history, start="abcdef01a"
                )
            ),
            ["abcdef01aa"],
        )

    def test_a_prefix_shorter_than_seven_is_resolved_rather_than_refused(self):
        # Round 3's blocker. Git's own floor is four characters; a pattern that
        # refused five rejected an abbreviation git resolves, and it rejected
        # it before the ambiguity check that is what actually decides whether a
        # prefix names one commit. Length was doing the refusing, and length is
        # not the question.
        self.assertEqual(
            self.units(self.select(mode="direct", count=1, start="ed908")),
            [DIRECT_HISTORY[0]],
        )
        # Through the command line too, which is the surface the asset uses.
        walk = self.worktree / "walk.txt"
        walk.write_text("\n".join(DIRECT_HISTORY) + "\n", encoding="utf-8")
        selection = self.run_cli(
            "select",
            "--mode",
            "direct",
            "--count",
            "1",
            "--candidates",
            str(walk),
            "--start",
            "3b3c",
        )
        self.assertEqual(
            [entry["sha"] for entry in selection["selected"]], [DIRECT_HISTORY[2]]
        )

    def test_a_short_prefix_is_still_refused_when_it_names_two_commits(self):
        # The negative control for the floor: lowering it must not turn an
        # ambiguous prefix into an accepted one.
        with self.assertRaises(self.module.CursorError) as caught:
            self.select(
                mode="direct",
                count=1,
                candidates=["abcdef01aa", "abcdef01bb"],
                start="abcd",
            )
        self.assertIn("names 2 commits", str(caught.exception))

    def test_a_pull_request_number_takes_the_exact_path(self):
        # Non-vacuity for the prefix rule: it is a SHA rule, and #46 must never
        # resolve to #466 the way `ed90877` resolves to `ed90877ac1`.
        with self.assertRaises(self.module.CursorError) as caught:
            self.select(count=1, start=46)
        self.assertIn("is not in this repository's merged history", str(caught.exception))


class CursorDocumentTests(CursorTransitionCase):
    """Requirement 7 and the fail-closed rule: what the state file may say."""

    def test_a_missing_document_is_the_only_absence_that_is_not_a_refusal(self):
        # A repository that has never been swept has no cursor, and that is
        # what every first invocation looks like. Every other unreadable state
        # is a refusal, because "unreadable" and "absent" select different
        # ranges and merging them is how a sweep loses history.
        self.assertEqual(
            self.module.load_document(self.worktree), self.module.empty_document()
        )
        self.assertEqual(self.state(), self.module.empty_state())

    def test_the_document_round_trips_through_its_own_serialization(self):
        recorded = self.record(self.select(count=3), exclude=[466])
        reread = self.state()
        self.assertEqual(reread, recorded)
        text = self.module.document_path(self.worktree).read_text(encoding="utf-8")
        self.assertIn(self.module.CURSOR_MARKER, text)
        self.assertIn("# Project review sweep cursor", text)

    def test_the_original_stop_before_document_migrates_without_losing_exceptions(self):
        self.module.document_path(self.worktree).write_text(
            "# Project Review Boundaries\n\n"
            "Repository-specific exclusive endpoints.\n\n"
            "- `coghex/kanban` — stop before PR #466 in merge-date order. "
            "PR #471 merged later and was already reviewed, so skip it. "
            "Issue #999 records why.\n",
            encoding="utf-8",
        )
        state = self.state()
        self.assertEqual(state["pr"]["endpoint"]["number"], 466)
        self.assertEqual(state["pr"]["reviewed"], [466, 471])
        selection = self.select(count=9)
        self.assertEqual(self.units(selection), [470, 468])
        self.assertTrue(selection["boundary_reached"])

        self.record(selection)
        text = self.module.document_path(self.worktree).read_text(encoding="utf-8")
        self.assertIn(self.module.CURSOR_MARKER, text)
        self.assertEqual(self.state()["pr"]["endpoint"]["merged_at"],
                         "2026-08-17T00:00:00Z")

    def test_a_v1_resume_frontier_migrates_to_coverage_not_a_boundary(self):
        old = {
            "version": self.module.LEGACY_SCHEMA_VERSION,
            "repositories": {
                REPO: {
                    "pr": {
                        "endpoint": {
                            "number": 466,
                            "merged_at": "2026-08-17T00:00:00Z",
                        },
                        "reviewed": [468, 470, 471],
                    },
                    "direct": {"endpoint": None, "reviewed": []},
                    "excluded": {"prs": [], "commits": []},
                }
            },
        }
        self.module.document_path(self.worktree).write_text(
            "# Project review sweep cursor\n\n"
            f"{self.module.LEGACY_CURSOR_MARKER}\n\n"
            f"```json\n{json.dumps(old)}\n```\n",
            encoding="utf-8",
        )

        migrated = self.module.load_document(self.worktree)
        state = self.module.state_for(migrated, REPO)
        self.assertEqual(migrated["version"], self.module.SCHEMA_VERSION)
        self.assertIsNone(state["pr"]["endpoint"])
        self.assertEqual(state["pr"]["reviewed"], [466, 468, 470, 471])
        self.assertEqual(self.units(self.select(count=3)), [465, 464, 463])

        self.record(self.select(count=3))
        text = self.module.document_path(self.worktree).read_text(encoding="utf-8")
        self.assertIn(self.module.CURSOR_MARKER, text)
        self.assertNotIn(self.module.LEGACY_CURSOR_MARKER, text)

    def test_an_unparseable_document_stops_the_run(self):
        for spelling, body in (
            ("no marker", "# Project review sweep cursor\n\nnothing here.\n"),
            (
                "unreadable json",
                f"{self.module.CURSOR_MARKER}\n\n```json\n{{not json}}\n```\n",
            ),
            (
                "wrong schema version",
                f'{self.module.CURSOR_MARKER}\n\n```json\n{{"version": 99}}\n```\n',
            ),
            (
                "a reviewed entry that is not a pull request",
                f'{self.module.CURSOR_MARKER}\n\n```json\n'
                f'{{"version": {self.module.SCHEMA_VERSION}, "repositories": {{"o/r": {{"pr": '
                '{"reviewed": ["nope"]}}}}\n```\n',
            ),
        ):
            with self.subTest(spelling=spelling):
                self.module.document_path(self.worktree).write_text(body, encoding="utf-8")
                with self.assertRaises(self.module.CursorError):
                    self.module.load_document(self.worktree)

    def test_the_document_is_written_where_the_workflow_resolved_it(self):
        self.record(self.select(count=3))
        self.assertEqual(
            self.module.document_path(self.worktree),
            self.worktree / "docs" / "project_review_boundaries.md",
        )
        self.assertEqual(
            self.module.DOCUMENT_RELATIVE_PATH, "docs/project_review_boundaries.md"
        )


class CursorRecordTests(CursorTransitionCase):
    """The review's fifth spec addition: how a completed batch is folded in."""

    def test_the_pr_boundary_never_moves_without_an_explicit_request(self):
        self.record([], boundary=464)
        self.assertEqual(self.state()["pr"]["endpoint"]["number"], 464)
        self.record(self.select(count=2))
        self.assertEqual(self.state()["pr"]["endpoint"]["number"], 464)

        self.record([], boundary=461)
        self.assertEqual(self.state()["pr"]["endpoint"]["number"], 461)

    def test_recording_preserves_an_earlier_exclusion(self):
        self.record(self.select(count=2), exclude=[471])
        self.record(self.select(count=2), exclude=[464])
        self.assertEqual(self.state()["excluded"]["prs"], [464, 471])

    def test_a_reviewed_unit_absent_from_the_candidate_history_is_refused(self):
        with self.assertRaises(self.module.CursorError) as caught:
            self.module.record(
                self.state(),
                "pr",
                self.module.normalize_candidates("pr", PR_LISTING),
                [9999],
            )
        self.assertIn("absent from the candidate history", str(caught.exception))

    def test_a_completed_batch_records_at_least_one_unit(self):
        with self.assertRaises(self.module.CursorError):
            self.module.record(
                self.state(),
                "pr",
                self.module.normalize_candidates("pr", PR_LISTING),
                [],
            )


class CursorCommandLineTests(CursorTransitionCase):
    """The surface the rendered assets actually invoke."""

    def test_select_and_record_round_trip_through_the_command_line(self):
        listing = self.worktree / "listing.json"
        listing.write_text(json.dumps(PR_LISTING), encoding="utf-8")
        first = self.run_cli(
            "select", "--mode", "pr", "--count", "3", "--candidates", str(listing)
        )
        self.assertEqual([entry["number"] for entry in first["selected"]], [470, 468, 471])

        self.run_cli(
            "record",
            "--mode",
            "pr",
            "--candidates",
            str(listing),
            "--reviewed",
            "470,468,471",
        )
        second = self.run_cli(
            "select", "--mode", "pr", "--count", "3", "--candidates", str(listing)
        )
        self.assertEqual([entry["number"] for entry in second["selected"]], [466, 465, 464])
        state = self.run_cli("read")["state"]["pr"]
        self.assertIsNone(state["endpoint"])
        self.assertEqual(state["reviewed"], [468, 470, 471])

    def test_a_range_bound_holds_through_the_command_line(self):
        # The surface the asset invokes, since that is where `--end` is spelled
        # and where an empty one has to mean no bound at all.
        listing = self.worktree / "listing.json"
        listing.write_text(json.dumps(PR_LISTING), encoding="utf-8")
        bounded = self.run_cli(
            "select", "--mode", "pr", "--count", "9",
            "--candidates", str(listing), "--start", "470", "--end", "466",
        )
        self.assertEqual(
            [entry["number"] for entry in bounded["selected"]], [470, 468, 471, 466]
        )
        self.assertTrue(bounded["bounded"])

        # Empty flags are the ordinary case, and must not bound anything.
        unbounded = self.run_cli(
            "select", "--mode", "pr", "--count", "9",
            "--candidates", str(listing), "--start", "", "--end", "",
        )
        self.assertEqual(len(unbounded["selected"]), len(PR_HISTORY))
        self.assertFalse(unbounded["bounded"])

    def test_boundary_recording_round_trips_through_the_command_line(self):
        listing = self.worktree / "listing.json"
        listing.write_text(json.dumps(PR_LISTING), encoding="utf-8")

        self.run_cli(
            "record", "--mode", "pr", "--candidates", str(listing),
            "--boundary", "#466",
        )
        self.assertEqual(self.state()["pr"]["endpoint"]["number"], 466)

        # The asset omits this flag ordinarily, but a templated empty value is
        # still no request to replace the existing boundary.
        self.run_cli(
            "record", "--mode", "pr", "--candidates", str(listing),
            "--reviewed", "470", "--boundary", "",
        )
        self.assertEqual(self.state()["pr"]["endpoint"]["number"], 466)

        self.run_cli(
            "record", "--mode", "pr", "--candidates", str(listing),
            "--boundary", "464",
        )
        self.assertEqual(self.state()["pr"]["endpoint"]["number"], 464)

        with self.assertRaises(self.module.CursorError) as caught:
            self.run_cli(
                "record", "--mode", "pr", "--candidates", str(listing),
                "--boundary", "466,464",
            )
        self.assertIn("one exclusive older boundary", str(caught.exception))

    def test_a_direct_candidate_listing_may_be_the_plain_sha_walk(self):
        # `git log --first-parent --format=%H` prints one SHA per line, which
        # is what the asset pipes in, so the helper reads that shape without a
        # transformation step of its own.
        walk = self.worktree / "walk.txt"
        walk.write_text("\n".join(DIRECT_HISTORY) + "\n", encoding="utf-8")
        selection = self.run_cli(
            "select", "--mode", "direct", "--count", "2", "--candidates", str(walk)
        )
        self.assertEqual(
            [entry["sha"] for entry in selection["selected"]], list(DIRECT_HISTORY[:2])
        )

    def test_the_first_direct_batch_starts_at_the_supplied_entry_point(self):
        # Round 3's other blocker: the shown invocation had no `--start`, so
        # the first direct batch of a repository that did have PR history
        # began at index 0 and re-reviewed PR-owned commits. Direct state is
        # empty at that moment, so nothing else could position it.
        walk = self.worktree / "walk.txt"
        walk.write_text("\n".join(DIRECT_HISTORY) + "\n", encoding="utf-8")
        first = self.run_cli(
            "select",
            "--mode",
            "direct",
            "--count",
            "2",
            "--candidates",
            str(walk),
            "--start",
            DIRECT_HISTORY[3],
        )
        self.assertEqual(
            [entry["sha"] for entry in first["selected"]], list(DIRECT_HISTORY[3:5])
        )
        self.assertEqual(first["origin"], "explicit-start")

        # Recorded, the next batch positions itself and needs no entry point --
        # which is why the same invocation passes an empty one from then on.
        self.run_cli(
            "record",
            "--mode",
            "direct",
            "--candidates",
            str(walk),
            "--reviewed",
            ",".join(DIRECT_HISTORY[3:5]),
        )
        later = self.run_cli(
            "select",
            "--mode",
            "direct",
            "--count",
            "2",
            "--candidates",
            str(walk),
            "--start",
            "",
        )
        self.assertEqual(
            [entry["sha"] for entry in later["selected"]], list(DIRECT_HISTORY[5:7])
        )
        self.assertEqual(later["origin"], "recorded-endpoint")

        # An empty entry point on the *first* batch is the defect itself: with
        # no state to position it, the walk restarts at HEAD.
        self.forget_the_cursor()
        restarted = self.run_cli(
            "select",
            "--mode",
            "direct",
            "--count",
            "2",
            "--candidates",
            str(walk),
            "--start",
            "",
        )
        self.assertEqual(restarted["origin"], "history-head")
        self.assertEqual(
            [entry["sha"] for entry in restarted["selected"]], list(DIRECT_HISTORY[:2])
        )




# ---------------------------------------------------------------------------
# The arc's end-to-end proof (issue #684, requirement 11).
#
# Everything below drives the *shipped* modules through the order the rendered
# assets spell, in a temporary repository with a temporary docs worktree and a
# fake `gh` on a temporary `PATH`. Three rules keep it a proof rather than a
# restatement:
#
# * **The commands come out of the asset.** `WorkflowRun` extracts each
#   invocation from the rendered file's own bash fences and runs it through
#   `sh -c` with the variables the asset names bound in the environment. A flag
#   the asset stops spelling, or spells differently, stops working here — which
#   a hand-written invocation of the same helper would not notice.
# * **Both bundles are driven.** Every case runs once per brand against that
#   brand's own copy of the modules, installed the way that runtime installs
#   it, and against that brand's own rendered asset. "Both packaged workflows
#   behave consistently" is therefore the shape of the suite rather than one
#   assertion inside it.
# * **What is asserted is read back out of the mechanism.** A completed review
#   is read out of the ledger document on disk and out of Git, never out of the
#   result the helper printed about itself.
#
# No case here reaches the network, spawns a model, or touches a real
# repository: the only external processes are `git`, the fake `gh`, the fake
# runtime version probe, and the helpers themselves. The native counterpart —
# the same two entry paths driven by the real installed runtimes, with real
# cancellations — is `tools/project-review-liveness-evidence.md`, because a
# fixture cannot prove that Claude Code and codex-cli deliver the events this
# suite hands the hook.
# ---------------------------------------------------------------------------

# The Codex trust hashes come from the liveness suite rather than being copied:
# they are what codex-cli itself recorded for this bundle's hooks.json, and two
# copies of them would drift the first time hooks.json changed.
import test_project_review_liveness as _liveness_suite

E2E_REPO = "coghex/kanban"

# Sub-second lease timings, written into the ledger as this repository's
# defaults so the asset's own `claim` line -- which carries no `--renewal` or
# `--expiry` -- takes them. A test that passed its own flags would be proving
# something about an invocation the workflow never makes.
E2E_RENEWAL = 0.25
E2E_EXPIRY = 1.5
E2E_SILENCE = 1.5
E2E_SETTLE = 25.0

BRAND_BUNDLES = {
    "claude": {
        "asset": CLAUDE_ASSET,
        "bundle_root": "claude-plugin/plugins/kanban",
        "ledger": "scripts/project_review_ledger.py",
        "liveness": "scripts/project_review_liveness.py",
        "cursor": "scripts/project_review_cursor.py",
        "version": "2.1.274 (Claude Code)",
        "invocation_field": "prompt_id",
        "terminal_event": "Stop",
    },
    "codex": {
        "asset": CODEX_ASSET,
        "bundle_root": "codex-plugin/plugins/kanban",
        "ledger": "skills/project-review/scripts/project_review_ledger.py",
        "liveness": "skills/project-review/scripts/project_review_liveness.py",
        "cursor": "skills/project-review/scripts/project_review_cursor.py",
        "version": "codex-cli 0.154.0",
        "invocation_field": "turn_id",
        "terminal_event": "Stop",
    },
}

# The closing fence may be indented: these documents nest bash blocks
# inside numbered list items, and a pattern anchored to an unindented
# closer runs one fence into the next and loses whatever sat between them.
BASH_FENCE_RE = re.compile(r"```bash\n(.*?)\n[ \t]*```", re.DOTALL)
JQ_FLAG_RE = re.compile(r"--jq '(?P<program>.*?)'", re.DOTALL)

# The fake `gh`. It answers exactly one call -- the GraphQL merged-pull-request
# page the asset takes -- and refuses anything else, so a workflow that started
# reaching GitHub some other way fails here rather than passing quietly.
#
# It performs the projection `--jq` would rather than running jq, and refuses
# any `--jq` program but the one the asset spells: the program is extracted
# from the rendered file and handed over in the environment, so a change to it
# is a change here too. What a fixture cannot stand in for -- that gh's own
# embedded jq computes that projection -- is left to the real `gh`; the
# projection's *shape* is what the ledger's own parser then checks.
FAKE_GH = '''#!/usr/bin/env python3
import json, os, sys

argv = sys.argv[1:]
with open(os.environ["FAKE_GH_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps(argv) + "\\n")

if argv[:2] != ["api", "graphql"]:
    sys.stderr.write("fake gh: only the graphql inventory call is served: %r\\n" % (argv,))
    raise SystemExit(64)

fields, jq, query, index = {}, None, None, 0
while index < len(argv):
    token = argv[index]
    if token in ("-F", "-f"):
        name, _, value = argv[index + 1].partition("=")
        if token == "-F":
            fields[name] = value
        elif name == "query":
            query = value
        index += 2
    elif token == "--jq":
        jq = argv[index + 1]
        index += 2
    else:
        index += 1

owner, name = os.environ["FAKE_GH_REPO"].split("/")
if fields.get("owner") != owner or fields.get("name") != name:
    sys.stderr.write("fake gh: the call named %r, not the resolved repository\\n" % (fields,))
    raise SystemExit(65)
if jq != os.environ["FAKE_GH_JQ"]:
    sys.stderr.write("fake gh: unexpected --jq program: %r\\n" % (jq,))
    raise SystemExit(66)
if query is None or "states:MERGED" not in query:
    sys.stderr.write("fake gh: the query does not ask for merged pull requests\\n")
    raise SystemExit(67)

limit = int(fields["limit"])
cursor = fields.get("cursor", "null")
start = 0 if cursor in ("", "null") else int(cursor)
failing = os.environ.get("FAKE_GH_FAIL_AFTER")
if failing is not None and start >= int(failing):
    sys.stderr.write("fake gh: HTTP 502\\n")
    raise SystemExit(1)
rows = json.load(open(os.environ["FAKE_GH_PAGES"], encoding="utf-8"))
page = rows[start:start + limit]
print(json.dumps({"prs": page, "next": str(start + len(page))}))
'''


def asset_fences(relative_path: str):
    return [match.group(1) for match in BASH_FENCE_RE.finditer(read(relative_path))]


def asset_commands_starting(relative_path: str, prefix: str):
    """Every command in `relative_path`'s bash fences that starts with `prefix`.

    Continuation lines are joined, so a command the asset wraps across lines is
    returned as the one line `sh -c` would run.
    """
    found = []
    for fence in asset_fences(relative_path):
        for line in fence.replace("\\\n", " ").splitlines():
            stripped = line.strip()
            if stripped.startswith(prefix):
                found.append(re.sub(r"[ \t]+", " ", stripped))
    return found


def asset_command(relative_path: str, prefix: str) -> str:
    """The one command in `relative_path` that starts with `prefix`.

    Exactly one match is required: a prefix that stopped identifying one
    invocation is drift, not a detail.
    """
    found = asset_commands_starting(relative_path, prefix)
    # The same invocation may legitimately appear twice -- `read` is made once
    # before the migration decision and again under the claim -- so identical
    # matches are one command. Two *different* ones are drift.
    if len(set(found)) != 1:
        raise AssertionError(
            f"{relative_path} spells {len(set(found))} commands starting {prefix!r}: {found}"
        )
    return found[0]


def asset_jq_program(relative_path: str) -> str:
    match = JQ_FLAG_RE.search(read(relative_path))
    assert match is not None, f"{relative_path} takes no --jq inventory projection"
    return re.sub(r"\s+", " ", match.group("program"))


def e2e_git(cwd, *arguments):
    return subprocess.run(
        ["git", *arguments], cwd=str(cwd), capture_output=True, text=True, check=True
    ).stdout


def e2e_wait(predicate, message, timeout=E2E_SETTLE, interval=0.05):
    give_up = time.monotonic() + timeout
    while True:
        value = predicate()
        if value:
            return value
        if time.monotonic() >= give_up:
            raise AssertionError(message)
        time.sleep(interval)


_E2E_MODULES = {}


def e2e_module(kind: str, brand: str):
    """One bundled module, imported from `brand`'s own tracked copy."""
    key = (kind, brand)
    if key not in _E2E_MODULES:
        path = REPO_ROOT / BUNDLED_HELPERS[kind][brand]
        spec = importlib.util.spec_from_file_location(f"_e2e_{kind}_{brand}", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _E2E_MODULES[key] = module
    return _E2E_MODULES[key]


class WorkflowRun:
    """One reviewed repository, its docs worktree, and one installed bundle."""

    def __init__(self, case, brand):
        self.case = case
        self.brand = brand
        self.spec = BRAND_BUNDLES[brand]
        self.asset = self.spec["asset"]
        # `ignore_cleanup_errors` because the keeper and the renewer are real
        # processes writing into this tree: `stop_everything` below runs first
        # and waits for each of them, but a descendant neither of them reaped
        # can still unlink a file between `rmtree`'s scan and its unlink, and a
        # teardown that raised there would report a passing test as an error.
        self.base = Path(
            case.enterContext(
                tempfile.TemporaryDirectory(
                    prefix="project-review-e2e-", ignore_cleanup_errors=True
                )
            )
        ).resolve()
        base = self.base

        # The bundle as its own runtime installs it, never the checkout's copy:
        # the lookup each asset spells resolves an installed bundle, and a test
        # reading the tracked path would not exercise it.
        self.codex_home = base / "codex-home"
        if brand == "codex":
            self.bundle = self.codex_home / "plugins" / "cache" / "kanban" / "kanban" / "1.54.0"
        else:
            self.bundle = base / "claude-plugins" / "kanban" / "1.55.0"
        source_root = REPO_ROOT / self.spec["bundle_root"]
        for relative in (
            self.spec["ledger"],
            self.spec["liveness"],
            self.spec["cursor"],
            "hooks/hooks.json",
        ):
            target = self.bundle / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((source_root / relative).read_bytes())
        self.ledger_path = self.bundle / self.spec["ledger"]
        self.liveness_path = self.bundle / self.spec["liveness"]
        self.cursor_path = self.bundle / self.spec["cursor"]

        # A remote, a primary checkout, and a linked docs-wip worktree: the
        # three locations the asset resolves between.
        self.origin = base / "origin.git"
        e2e_git(base, "init", "--bare", "-q", "-b", "master", str(self.origin))
        self.root = base / "repo"
        e2e_git(base, "clone", "-q", str(self.origin), str(self.root))
        for key, value in (
            ("user.name", "Project Review E2E"),
            ("user.email", "e2e@example.invalid"),
            ("commit.gpgsign", "false"),
        ):
            e2e_git(self.root, "config", key, value)
        (self.root / "README.md").write_text("reviewed repository\n", encoding="utf-8")
        e2e_git(self.root, "add", "-A")
        e2e_git(self.root, "commit", "-qm", "initial")
        e2e_git(self.root, "push", "-q", "-u", "origin", "master")
        e2e_git(self.root, "remote", "set-head", "origin", "master")
        self.docs = base / "docs-wt"
        e2e_git(self.root, "worktree", "add", "-q", "-b", "docs-wip", str(self.docs))
        (self.docs / "docs").mkdir(parents=True, exist_ok=True)
        (self.docs / "docs" / "notes.md").write_text("operator notes\n", encoding="utf-8")
        e2e_git(self.docs, "add", "-A")
        e2e_git(self.docs, "commit", "-qm", "docs base")

        # `python3`, `gh` and the runtime version probe on a PATH of this run's
        # own, so the asset's command text runs verbatim against this
        # interpreter and these fakes.
        self.bin = base / "bin"
        self.bin.mkdir()
        self._install("python3", f'#!/bin/sh\nexec {sys.executable} "$@"\n')
        self._install("gh", FAKE_GH)
        self._install(
            brand,
            "#!/bin/sh\n"
            'if [ "$1" = "features" ]; then\n'
            '  echo "hooks                                    stable             true"\n'
            "  exit 0\n"
            "fi\n"
            f'echo "{self.spec["version"]}"\n',
        )
        self.codex_home.mkdir(parents=True, exist_ok=True)
        self._trust_codex_hooks()
        self.gh_log = base / "gh-calls.jsonl"
        self.pages_file = base / "merged.json"
        self.pages_file.write_text("[]", encoding="utf-8")
        self.scratch = base / "scratch"
        self.scratch.mkdir()
        self.env = dict(
            os.environ,
            PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            CLAUDE_PLUGIN_ROOT=str(self.bundle),
            CODEX_HOME=str(self.codex_home),
            FAKE_GH_LOG=str(self.gh_log),
            FAKE_GH_PAGES=str(self.pages_file),
            FAKE_GH_REPO=E2E_REPO,
            FAKE_GH_JQ=asset_jq_program(self.asset),
            # `$BUNDLE` is the Codex fence's own intermediate: its register
            # and `run` lines take the helper's directory from it, so it is
            # bound here exactly as that fence binds it.
            BUNDLE=str(self.ledger_path),
            LEDGER=str(self.ledger_path),
            LIVENESS=str(self.liveness_path),
            CURSOR=str(self.cursor_path),
            ROOT=str(self.root),
            REPO=E2E_REPO,
            DOCS_WT=str(self.docs),
        )
        self.pids = []
        case.addCleanup(self.stop_everything)

    # -- plumbing

    def _install(self, name, text):
        path = self.bin / name
        path.write_text(text, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    def _trust_codex_hooks(self):
        lines = []
        for key, value in _liveness_suite.CODEX_RECORDED_TRUST.items():
            lines.append(f'[hooks.state."{key}"]')
            lines.append(f"trusted_hash = {json.dumps(value)}")
        (self.codex_home / "config.toml").write_text("\n".join(lines) + "\n", encoding="utf-8")

    def stop_everything(self):
        """Every process this run started, killed and waited for.

        Waited for, because the temporary directory is removed straight after
        this: a renewer still writing its heartbeat record while `rmtree` walks
        the tree is a teardown error rather than a test result.
        """
        for pid in self.pids:
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.kill(pid, signal.SIGKILL)
        module = e2e_module("ledger", self.brand)
        host = module.socket.gethostname()
        give_up = time.monotonic() + 10
        for pid in self.pids:
            while time.monotonic() < give_up:
                if module.holder_standing({"host": host, "pid": pid}) != "live":
                    break
                time.sleep(0.05)

    def sh(self, command, stdin=None, check=True, **extra):
        completed = subprocess.run(
            ["sh", "-c", command],
            capture_output=True,
            text=True,
            cwd=str(self.root),
            env=dict(self.env, **extra),
            input=stdin,
            timeout=180,
        )
        if check:
            self.case.assertEqual(
                completed.returncode,
                0,
                f"{command}\n{completed.stdout}\n{completed.stderr}",
            )
        return completed

    def helper(self, prefix, suffix="", **kwargs):
        """Run the asset's own invocation that starts `prefix`."""
        return self.sh(asset_command(self.asset, prefix) + suffix, **kwargs)

    def json_helper(self, prefix, **kwargs):
        return json.loads(self.helper(prefix, **kwargs).stdout)

    def running(self, pid):
        module = e2e_module("ledger", self.brand)
        return module.holder_standing({"host": module.socket.gethostname(), "pid": pid}) == "live"

    # -- the reviewed repository's merged history

    def merged(self, numbers_and_times):
        self.pages_file.write_text(
            json.dumps(
                [
                    {"number": number, "title": f"PR {number}", "merged_at": merged_at}
                    for number, merged_at in numbers_and_times
                ]
            ),
            encoding="utf-8",
        )

    def inventory(self, page_size=100, fail_after=None):
        """Step 1: the complete listing, paged through the fake `gh`, in hand.

        The paging rule is the asset's: one call per page, positioned by the
        previous page's own `next`, until a page comes back short. What the
        asset states in prose -- assembling the pages into the one object the
        helper reads -- is done here, and the helper's own parser is then what
        decides whether the result is a complete listing.
        """
        command = asset_command(self.asset, "gh api graphql")
        pages = []
        after = "null"
        extra = {} if fail_after is None else {"FAKE_GH_FAIL_AFTER": str(fail_after)}
        while True:
            completed = self.sh(
                command.replace("-F limit=100", f"-F limit={page_size}"),
                check=False,
                AFTER=after,
                **extra,
            )
            if completed.returncode != 0:
                return None
            page = json.loads(completed.stdout)
            pages.append({"page": len(pages) + 1, "limit": page_size, "prs": page["prs"]})
            after = page["next"]
            if len(page["prs"]) < page_size:
                break
        return pages

    def place_inventory(self, pages, attempt):
        """Step 3's first act: the assembled listing, on disk at last.

        Step 1 leaves it in hand deliberately -- a run that stops there has
        written nothing and started nothing -- so this is where it reaches the
        attempt's own directory, at the path the asset names.
        """
        self.case.assertEqual(
            asset_command(self.asset, "INVENTORY="),
            'INVENTORY="$ATTEMPT_DIR/inventory.json"',
        )
        path = self.attempt_directory(attempt) / "inventory.json"
        path.write_text(json.dumps({"pages": pages}), encoding="utf-8")
        return path

    def registered_inventory(self, page_size=100, **kwargs):
        """Steps 1 through 3's first act, in the order the asset spells them."""
        pages = self.inventory(page_size=page_size)
        registration = self.register(**kwargs)
        return registration, self.place_inventory(pages, registration["attempt"])

    def advance_the_remote(self):
        """Move the remote's default branch on, so a fetch has work to do."""
        clone = self.base / f"pusher-{time.monotonic_ns()}"
        e2e_git(self.base, "clone", "-q", str(self.origin), str(clone))
        for key, value in (
            ("user.name", "Project Review E2E"),
            ("user.email", "e2e@example.invalid"),
            ("commit.gpgsign", "false"),
        ):
            e2e_git(clone, "config", key, value)
        (clone / "ADVANCED.md").write_text("moved on\n", encoding="utf-8")
        e2e_git(clone, "add", "-A")
        e2e_git(clone, "commit", "-qm", "advance the remote")
        e2e_git(clone, "push", "-q", "origin", "HEAD:master")
        return e2e_git(clone, "rev-parse", "HEAD").strip()

    def lock_remote_tracking_ref(self, branch="master"):
        """Make a fetch fail while leaving the remote perfectly readable.

        A stale `refs/remotes/origin/<branch>.lock` is what Git refuses to
        write past, so the fetch fails, `ls-remote` still answers, and the
        local remote-tracking ref stays where it was -- which is the exact
        shape that makes a stale pin look plausible.
        """
        common = Path(
            e2e_git(
                self.root, "rev-parse", "--path-format=absolute", "--git-common-dir"
            ).strip()
        )
        e2e_git(self.root, "pack-refs", "--all")
        lock = common / "refs" / "remotes" / "origin" / f"{branch}.lock"
        lock.parent.mkdir(parents=True, exist_ok=True)
        lock.write_text("", encoding="utf-8")
        return lock

    def move_the_remote_default_branch(self, name="main"):
        """Move the remote's HEAD to a new branch, leaving the local symref
        pointing at the old one -- which is what a fetch does not fix."""
        before = self.sh(
            'git -C "$ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD'
        ).stdout.strip()
        e2e_git(self.root, "branch", name, "master")
        (self.root / "MOVED.md").write_text("after the move\n", encoding="utf-8")
        e2e_git(self.root, "add", "-A")
        e2e_git(self.root, "commit", "-qm", "on the new default branch")
        e2e_git(self.root, "branch", "-f", name, "HEAD")
        e2e_git(self.root, "reset", "--hard", "-q", "HEAD~1")
        e2e_git(self.root, "push", "-q", "origin", f"{name}:{name}")
        e2e_git(self.origin, "symbolic-ref", "HEAD", f"refs/heads/{name}")
        head = e2e_git(self.origin, "rev-parse", f"refs/heads/{name}").strip()
        return before, name, head

    def gh_calls(self):
        if not self.gh_log.exists():
            return []
        return [
            json.loads(line)
            for line in self.gh_log.read_text(encoding="utf-8").splitlines()
        ]

    # -- the ledger and the lease

    def lease_defaults(self):
        """This repository's sub-second lease defaults, recorded in its ledger.

        `lease-defaults` writes into an existing entry, so the ledger has to
        exist -- which is the order the asset spells: `read`, then `migrate` on
        a repository whose ledger does not exist yet, then everything else.
        """
        if self.ledger_bytes() is None:
            self.migrate()
        subprocess.run(
            [
                sys.executable, str(self.ledger_path), "lease-defaults",
                "--root", str(self.docs), "--repo", E2E_REPO,
                "--renewal", str(E2E_RENEWAL), "--expiry", str(E2E_EXPIRY),
            ],
            capture_output=True, text=True, check=True, timeout=60,
        )

    def read_ledger(self):
        return self.json_helper('python3 "$LEDGER" read')["state"]

    def rows(self):
        return self.read_ledger()["rows"]

    def ledger_bytes(self):
        path = self.docs / e2e_module("ledger", self.brand).LEDGER_RELATIVE_PATH
        return path.read_bytes() if path.exists() else None

    def migrate(self, *confirmations, check=True):
        """The asset's migration call -- its plain one, or its `--confirm` one.

        Both are spelled in the document, and which one a run makes is exactly
        the difference between a repository that flagged nothing and one whose
        operator answered a flag, so both are taken from the asset rather than
        one being built from the other.
        """
        spelled = asset_commands_starting(self.asset, 'python3 "$LEDGER" migrate')
        plain = [command for command in spelled if "--confirm" not in command]
        confirming = [command for command in spelled if "--confirm" in command]
        self.case.assertEqual(len(plain), 1, spelled)
        self.case.assertEqual(len(confirming), 1, spelled)
        if not confirmations:
            return self.sh(plain[0], check=check)
        command = confirming[0].split(" --confirm ")[0]
        command += "".join(f' --confirm "{value}"' for value in confirmations)
        return self.sh(command, check=check)

    def write_cursor(self, reviewed):
        """A v2 cursor, written by the cursor module's own record and writer.

        Never hand-built: a cursor shape this migration cannot read has to be
        a cursor shape the mechanism cannot write, or the fixture is asserting
        against a document nothing produces.
        """
        module = e2e_module("cursor", self.brand)
        candidates = module.normalize_candidates(
            "pr",
            [
                {"number": row["number"], "mergedAt": row["merged_at"]}
                for row in json.loads(self.pages_file.read_text(encoding="utf-8"))
            ],
        )
        document = module.load_document(self.docs)
        state = module.record(
            module.state_for(document, E2E_REPO), "pr", candidates, sorted(reviewed), []
        )
        document.setdefault("repositories", {})[E2E_REPO] = state
        module.write_document(self.docs, document)

    # -- the liveness adapter

    def hook_payload(self, event, session, invocation, command=None, tool_use_id=None):
        body = {
            "hook_event_name": event,
            "session_id": session,
            "transcript_path": str(self.base / f"{session}.jsonl"),
            "cwd": str(self.root),
            "permission_mode": "bypassPermissions",
        }
        if event != "SessionEnd":
            body[self.spec["invocation_field"]] = invocation
        else:
            body["reason"] = "other"
        if event in ("PreToolUse", "PostToolUse", "PostToolUseFailure"):
            body.update(
                tool_name="Bash",
                tool_use_id=tool_use_id or f"tool-{time.monotonic_ns()}",
                tool_input={"command": command or "echo hi"},
            )
        return body

    def hook(self, event, session="session-a", invocation="invocation-1", **kwargs):
        completed = subprocess.run(
            [sys.executable, str(self.liveness_path), "hook", "--runtime", self.brand],
            input=json.dumps(self.hook_payload(event, session, invocation, **kwargs)),
            capture_output=True,
            text=True,
            cwd=str(self.root),
            env=self.env,
            timeout=60,
        )
        self.case.assertEqual(
            (completed.returncode, completed.stdout), (0, ""), completed.stderr
        )

    def registration_attempt(
        self, session="session-a", invocation="invocation-1",
        silence=E2E_SILENCE, handshake=True,
    ):
        """Register exactly as the asset says: a nonce, then a second call
        carrying that nonce's literal digits in its own command text.

        `handshake=False` withholds the hook event, which is what a disabled,
        untrusted or absent lifecycle hook looks like to the adapter.
        """
        nonce = self.helper('python3 "$LIVENESS" nonce').stdout.strip()
        self.case.assertRegex(nonce, r"\A[0-9a-f]{32}\Z")
        template = asset_command(self.asset, REGISTRATION[self.brand].split(" register ")[0] + " register")
        command = re.sub(r"--nonce [0-9a-f]{32}", f"--nonce {nonce}", template)
        self.case.assertIn(nonce, command)
        command += f" --silence {silence} --handshake-wait {'5' if handshake else '0.5'}"
        if handshake:
            self.hook("PreToolUse", session, invocation, command=command)
        return self.sh(command, check=False)

    def register(self, **kwargs):
        completed = self.registration_attempt(**kwargs)
        self.case.assertEqual(completed.returncode, 0, completed.stderr)
        registration = json.loads(completed.stdout)
        self.pids.append(registration["keeper_pid"])
        return registration

    def claim(self, inventory_path, keeper_pid, check=True):
        completed = self.helper(
            'python3 "$LEDGER" claim',
            check=check,
            KEEPER=str(keeper_pid),
            INVENTORY=str(inventory_path),
        )
        if completed.returncode != 0:
            return completed
        result = json.loads(completed.stdout)
        if result.get("claim"):
            self.pids.append(result["claim"]["renewer"]["pid"])
        return result

    def attempt_state(self, attempt):
        """What the asset's own `status` call reports about one attempt."""
        completed = self.sh(
            asset_command(self.asset, 'python3 "$LIVENESS" status'),
            check=False,
            SIBLING=attempt,
        )
        if completed.returncode != 0:
            # The adapter refuses an attempt it no longer knows -- a pruned
            # one -- and the asset reads that as an invocation that is over.
            return "unknown"
        return json.loads(completed.stdout)["status"]

    def attempt_status(self, attempt):
        """The asset's own `status` call, or `None` when it is refused."""
        completed = self.sh(
            asset_command(self.asset, 'python3 "$LIVENESS" status'),
            check=False,
            SIBLING=attempt,
        )
        if completed.returncode != 0:
            return None
        return json.loads(completed.stdout)

    def attempt_state(self, attempt):
        status = self.attempt_status(attempt)
        # The adapter refuses an attempt it no longer knows -- a pruned one --
        # and the asset reads that as an invocation that is over.
        return "unknown" if status is None else status["status"]

    def attempt_is_over(self, attempt):
        """The asset's rule for "this invocation is over".

        `active` is not enough on its own: a keeper killed outright writes no
        ended record, so its attempt still reads `active` while its standing
        says otherwise, and treating that as live would strand the directory.
        """
        status = self.attempt_status(attempt)
        if status is None:
            return True
        if status["status"] == "ended":
            return True
        return status["keeper_standing"] != "live"

    def reclaim_refusal(self, attempt):
        """Why this attempt's directory may not be removed, or `None`.

        Fails closed, as the asset does: removal needs a positive answer to
        both questions, and `unverifiable` or a refused `status` is an answer
        to neither.
        """
        status = self.attempt_status(attempt)
        if status is None:
            return "attempt-unknown"
        if status["status"] != "ended":
            if status["keeper_standing"] == "live":
                return "live"
            if status["keeper_standing"] != "gone":
                return f"keeper-{status['keeper_standing']}"
        if status["unfinished_launches"]:
            return "launches:" + ",".join(status["unfinished_launches"])
        return None

    def reclaim_orphans(self, keep=None):
        """Step 2's reclaim pass, driven through the asset's own `status` call.

        Two readings gate the removal, and both come out of that one call: is
        this attempt over, and is anything it started still running.
        """
        runtime = self.runtime_worktrees()
        reclaimed, retained = [], []
        if not runtime.is_dir():
            return reclaimed
        for sibling in sorted(runtime.iterdir()):
            if sibling.name == keep:
                continue
            refusal = self.reclaim_refusal(sibling.name)
            if refusal == "live":
                continue
            if refusal is not None:
                retained.append((sibling.name, refusal))
                continue
            self.cleanup_worktree(sibling / "tree")
            reclaimed.append(sibling.name)
        self.sh('git -C "$ROOT" worktree prune')
        self.retained_orphans = retained
        return reclaimed

    def first_parent_history(self, count):
        """`count` first-parent commits in `$ROOT`, newest first."""
        for index in range(count):
            (self.root / f"history-{index}.md").write_text(
                f"commit {index}\n", encoding="utf-8"
            )
            e2e_git(self.root, "add", "-A")
            e2e_git(self.root, "commit", "-qm", f"history {index}")
        walk = e2e_git(
            self.root, "log", "--first-parent", "--format=%H"
        ).split()
        return walk[:count]

    def direct_walk(self, subcommand):
        """The direct section's walk piped into `select` or `record`.

        Both are the same `git log --first-parent` line with a different
        helper on the other side of the pipe, so they are told apart by the
        subcommand rather than by the prefix they share -- and a `record` that
        stopped being handed the walk stops working here.
        """
        commands = [
            command
            for command in asset_commands_starting(
                self.asset, 'git -C "$ROOT" log --first-parent'
            )
            if f'"$CURSOR" {subcommand} ' in command
        ]
        self.case.assertEqual(len(commands), 1, commands)
        return commands[0]

    def direct_select(self, count):
        """The direct section's own `select`, run as it spells it."""
        completed = self.sh(
            self.direct_walk("select"), COUNT=str(count), RANGE_START="", RANGE_END=""
        )
        return json.loads(completed.stdout)

    def direct_record(self, shas):
        """The direct section's own `record`, run as it spells it."""
        completed = self.sh(
            self.direct_walk("record"), REVIEWED=",".join(shas), EXCLUDED=""
        )
        return json.loads(completed.stdout)

    def heartbeat_renewals(self, token):
        module = e2e_module("ledger", self.brand)
        record = module.read_heartbeat(module.git_common_directory(self.docs), token)
        return None if record is None else record["renewals"]

    # -- the pinned review tree

    def runtime_worktrees(self):
        """`$RUNTIME` -- where every attempt's own directory goes."""
        return Path(
            self.sh(
                asset_command(self.asset, 'RUNTIME="$(git -C "$ROOT" rev-parse')
                + ' && printf %s "$RUNTIME"'
            ).stdout.strip()
        )

    def attempt_directory(self, attempt):
        """This attempt's directory, made by the asset's own `mkdir` line."""
        directory = self.runtime_worktrees() / attempt
        self.sh(
            asset_command(self.asset, 'mkdir -p "$ATTEMPT_DIR"'),
            ATTEMPT_DIR=str(directory),
        )
        return directory

    def pin(self, attempt=None):
        """Fetch, resolve and detach -- through the asset's own commands.

        The default branch, the pinned SHA and the attempt-scoped worktree
        directory are all produced by running the lines the asset spells, so a
        resolution that stopped asking the remote, or a worktree that moved out
        of the Git common directory, stops working here.
        """
        attempt = attempt or f"{time.monotonic_ns():032x}"[:32]
        self.helper('git -C "$ROOT" fetch')
        default = self.sh(
            asset_command(self.asset, 'DEFAULT_BRANCH="$(git -C "$ROOT" ls-remote')
            + ' && printf %s "$DEFAULT_BRANCH"'
        ).stdout.strip()
        pin = self.sh(
            asset_command(self.asset, 'PIN="$(git -C "$ROOT" rev-parse')
            + ' && printf %s "$PIN"',
            DEFAULT_BRANCH=default,
        ).stdout.strip()
        attempt_dir = self.attempt_directory(attempt)
        review_wt = attempt_dir / "tree"
        self.case.assertEqual(
            asset_command(self.asset, 'ATTEMPT_DIR='), 'ATTEMPT_DIR="$RUNTIME/$ATTEMPT"'
        )
        self.case.assertEqual(
            asset_command(self.asset, 'REVIEW_WT='), 'REVIEW_WT="$ATTEMPT_DIR/tree"'
        )
        self.sh(
            asset_command(self.asset, 'git -C "$ROOT" worktree add'),
            REVIEW_WT=str(review_wt),
            PIN=pin,
        )
        self.case.assertTrue((review_wt / "README.md").is_file())
        return pin, review_wt

    def cleanup_worktree(self, review_wt, check=False):
        """The asset's steps 9.3 and 9.4, in the order and under the conditions
        it states them."""
        removal = self.sh(
            asset_command(self.asset, 'git -C "$ROOT" worktree remove'),
            check=check,
            REVIEW_WT=str(review_wt),
        )
        nothing_registered = "is not a working tree" in removal.stderr
        if removal.returncode == 0 or nothing_registered:
            self.sh(
                asset_command(self.asset, 'rm -rf "$ATTEMPT_DIR"'),
                ATTEMPT_DIR=str(Path(review_wt).parent),
            )
        return removal

    def remove_pin(self, review_wt):
        self.cleanup_worktree(review_wt, check=True)

    # -- completing an attempt

    def allocate(self, number, token, check=True):
        completed = self.helper(
            'python3 "$LEDGER" allocate-report', check=check, PR=str(number), TOKEN=token
        )
        return json.loads(completed.stdout)["report"] if check else completed

    def record(
        self, number, token, outcome, commit,
        report=None, repeats=(), recurrences=(), check=True,
    ):
        """`record`, built from the flag set the asset's own line spells.

        The asset's line carries placeholders -- `<PR>`, `<report>#PRR-k` --
        because those are the reviewer's to fill, so the flags are taken from
        it and the values are this test's. A flag the asset stops naming stops
        being exercised here, which is the drift this reads.
        """
        spelled = asset_command(self.asset, 'python3 "$LEDGER" record')
        for flag in (
            "--outcome", "--commit", "--report",
            "--repeat", "--recurrence", "--fixed", "--fixed-merge",
        ):
            self.case.assertIn(f"{flag} ", spelled, f"the asset's record line omits {flag}")
        command = spelled.split(" --outcome ")[0]
        command += f" --outcome {outcome} --commit {commit}"
        if report is not None:
            command += f' --report "{report}"'
        for value in repeats:
            command += f' --repeat "{value}"'
        for value in recurrences:
            command += f' --recurrence "{value}"'
        completed = self.sh(command, check=check, PR=str(number), TOKEN=token)
        return json.loads(completed.stdout) if check else completed

    def release(self, number, token, check=True):
        return self.helper(
            'python3 "$LEDGER" release', check=check, PR=str(number), TOKEN=token
        )

    def complete_attempt(self, attempt):
        return self.helper('python3 "$LIVENESS" complete', ATTEMPT=attempt)

    # -- a whole review, for the cases that need one to have happened

    def review_once(self, outcome="clean", findings=None, repeats=(), recurrences=()):
        registration, inventory = self.registered_inventory()
        claimed = self.claim(inventory, registration["keeper_pid"])
        self.case.assertEqual(claimed["status"], "claimed")
        number = claimed["selected"]["number"]
        token = claimed["claim"]["token"]
        pin, review_wt = self.pin(attempt=registration["attempt"])
        report = None
        if findings is not None:
            report = self.allocate(number, token)
            (self.docs / report).parent.mkdir(parents=True, exist_ok=True)
            (self.docs / report).write_text(findings, encoding="utf-8")
        recorded = self.record(
            number, token, outcome, pin,
            report=report, repeats=repeats, recurrences=recurrences,
        )
        self.remove_pin(review_wt)
        self.complete_attempt(registration["attempt"])
        return dict(
            recorded, selected=claimed["selected"], queue=claimed["queue"], pin=pin
        )


REPORT_FIXTURE = textwrap.dedent(
    """\
    # Project Review Findings: PR #612

    One finding, kept for the next review of this pull request to compare with.

    Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
    reviewed and deliberately never to be filed · `[deferred]` blocked on a
    concrete precondition

    ## Status

    - [ ] PRR-1. The refusal path leaves the lock held

    ## 1. Locking

    ### PRR-1. The refusal path leaves the lock held

    > **Captured note:** The early return skips the release.

    **Verification:** Traced in the pinned tree.

    **Evidence:**

    - `src/thing.py:12` — the early return.

    **Handoff context:**

    - **Current behavior:** The lock stays held.
    - **Expected behavior:** The lock is released.
    - **Scope and constraints:** PR #612.
    - **Verification target:** A refusal test.
    - **Deduplication:** Nothing open.
    - **Remaining uncertainty:** None.
    """
)


class WorkflowRunCase:
    """Shared fixtures; mixed into one TestCase per brand at the bottom."""

    BRAND = None

    def setUp(self):
        super().setUp()
        self.workflow = WorkflowRun(self, self.BRAND)
        self.module = e2e_module("ledger", self.BRAND)


class HelperResolution(WorkflowRunCase):
    def test_the_assets_own_lookup_finds_this_brands_installed_bundle(self):
        # The lookup is the one thing every later step depends on and the one
        # thing binding the variables by hand would skip. Run the asset's own
        # resolution fence, with none of them pre-set, and ask what it found.
        fence = next(
            fence
            for fence in asset_fences(self.workflow.asset)
            if "project_review_ledger.py" in fence and "read --root" not in fence
        )
        environment = dict(self.workflow.env)
        for name in ("LEDGER", "LIVENESS", "CURSOR"):
            environment.pop(name)
        completed = subprocess.run(
            ["sh", "-c", fence + '\nprintf "%s\\n%s\\n%s\\n" "$LEDGER" "$LIVENESS" "$CURSOR"'],
            capture_output=True, text=True, env=environment,
            cwd=str(self.workflow.root), timeout=120,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        resolved = [Path(line) for line in completed.stdout.split()]
        self.assertEqual(
            resolved,
            [
                self.workflow.ledger_path,
                self.workflow.liveness_path,
                self.workflow.cursor_path,
            ],
        )


class FreshRepository(WorkflowRunCase):
    def test_a_fresh_repository_starts_from_an_empty_ledger_and_needs_no_migration(self):
        # Requirement 11's first proof. No cursor and no report, so `read`
        # answers about a repository with no state, and the first claim takes
        # the newest merged pull request out of the never-reviewed queue.
        self.workflow.merged([(612, "2026-09-01T00:00:00Z"), (610, "2026-08-01T00:00:00Z")])
        self.assertEqual(self.workflow.rows(), {})
        # No cursor and no report, so the migration establishes an empty
        # ledger, flags nothing, and imports no coverage at all.
        migrated = json.loads(self.workflow.migrate().stdout)
        self.assertEqual(migrated["status"], "migrated")
        self.assertEqual(migrated["flags"], [])
        self.assertEqual(self.workflow.rows(), {})
        self.workflow.lease_defaults()

        pages = self.workflow.inventory()
        self.assertEqual([len(page["prs"]) for page in pages], [2])

        registration, inventory = self.workflow.registered_inventory()
        claimed = self.workflow.claim(inventory, registration["keeper_pid"])
        self.assertEqual(claimed["status"], "claimed")
        self.assertEqual(claimed["selected"]["number"], 612)
        self.assertEqual(claimed["queue"]["name"], self.module.QUEUE_NEVER_REVIEWED)
        self.assertEqual(claimed["selected"]["row_status"], "never-reviewed")
        # Both pull requests entered the ledger as rows the listing named: the
        # one nobody claimed is never-reviewed rather than absent.
        self.assertEqual(sorted(self.workflow.rows()), ["610", "612"])

    def test_the_inventory_is_taken_one_page_at_a_time_until_a_page_is_short(self):
        # Design D-11 through the fake: full pages and a short one, each
        # positioned by the previous page's own cursor, every call naming the
        # resolved repository, and the result accepted by the helper's parser
        # -- which refuses anything but a complete listing.
        self.workflow.merged(
            [(n, f"2026-09-0{1 + (700 - n)}T00:00:00Z") for n in range(700, 693, -1)]
        )
        pages = self.workflow.inventory(page_size=3)
        self.assertEqual([len(page["prs"]) for page in pages], [3, 3, 1])
        self.assertEqual([page["page"] for page in pages], [1, 2, 3])
        self.assertEqual({page["limit"] for page in pages}, {3})
        calls = self.workflow.gh_calls()
        self.assertEqual(len(calls), 3)
        self.assertIn("cursor=null", " ".join(calls[0]))
        self.assertIn("cursor=3", " ".join(calls[1]))
        parsed = self.module.parse_inventory(
            {"pages": pages}, "the end-to-end listing"
        )
        self.assertEqual(len(parsed["listed"]), 7)

    def test_a_history_ending_on_a_page_boundary_takes_one_more_empty_page(self):
        self.workflow.merged(
            [(n, "2026-09-01T00:00:00Z") for n in (620, 619, 618, 617)]
        )
        pages = self.workflow.inventory(page_size=2)
        self.assertEqual([len(page["prs"]) for page in pages], [2, 2, 0])

    def test_a_failed_page_stops_before_anything_is_claimed(self):
        self.workflow.merged(
            [(n, "2026-09-01T00:00:00Z") for n in (620, 619, 618, 617)]
        )
        pages = self.workflow.inventory(page_size=2, fail_after=2)
        self.assertIsNone(pages)
        # Nothing was claimed and nothing was written: no ledger exists yet,
        # no attempt directory was made, and the docs worktree is exactly its
        # commit. Step 1 writing nothing is what makes this stop owe nothing.
        self.assertFalse(self.workflow.runtime_worktrees().exists())
        self.assertIsNone(self.workflow.ledger_bytes())
        self.assertEqual(
            e2e_git(self.workflow.docs, "status", "--porcelain", "--untracked-files=all"),
            "",
        )


class PinnedTree(WorkflowRunCase):
    """Round 1's first blocker: the pin follows the remote, not a local symref."""

    def setUp(self):
        super().setUp()
        self.workflow.merged([(612, "2026-09-01T00:00:00Z")])

    def test_the_pin_follows_a_remote_that_changed_its_default_branch(self):
        # `git fetch` does not refresh `refs/remotes/origin/HEAD`: after the
        # remote moves from `master` to `main`, the local symref still answers
        # `master` and the old branch still exists, so a resolution through it
        # pins a branch that is nobody's default any more and records the
        # review against it. The asset's own commands are what run here, so a
        # resolution that stopped asking the remote fails this.
        stale, moved_to, remote_head = self.workflow.move_the_remote_default_branch()
        self.assertEqual(stale, "origin/master")
        pin, review_wt = self.workflow.pin()
        # The local symref is still stale afterwards, which is the whole point:
        # nothing here repaired it, the resolution simply never read it.
        self.assertEqual(
            self.workflow.sh(
                'git -C "$ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD'
            ).stdout.strip(),
            stale,
        )
        self.assertEqual(pin, remote_head)
        self.assertNotEqual(
            pin, e2e_git(self.workflow.root, "rev-parse", "refs/remotes/origin/master").strip()
        )
        # And the tree really is the new default branch's.
        self.assertTrue((review_wt / "MOVED.md").is_file())
        self.workflow.remove_pin(review_wt)


class FetchFailure(WorkflowRunCase):
    """Round 4's blocker: a failed fetch stops before anything is pinned."""

    def setUp(self):
        super().setUp()
        self.workflow.merged([(612, "2026-09-01T00:00:00Z")])
        self.workflow.lease_defaults()

    def test_a_failed_fetch_pins_nothing_and_its_claim_is_released(self):
        # The remote moves on, and the local remote-tracking ref is locked, so
        # the fetch fails while `ls-remote` still answers and the stale ref is
        # still readable. Under one block of commands that is exactly when a
        # stale tree gets reviewed; the asset makes the fetch its own checked
        # call, so nothing after it runs.
        registration, inventory = self.workflow.registered_inventory()
        attempt_dir = inventory.parent
        claimed = self.workflow.claim(inventory, registration["keeper_pid"])
        token = claimed["claim"]["token"]

        advanced = self.workflow.advance_the_remote()
        stale = e2e_git(
            self.workflow.root, "rev-parse", "refs/remotes/origin/master"
        ).strip()
        self.assertNotEqual(advanced, stale)
        self.workflow.lock_remote_tracking_ref()

        fetch = self.workflow.sh(
            asset_command(self.workflow.asset, 'git -C "$ROOT" fetch'), check=False
        )
        self.assertNotEqual(fetch.returncode, 0, fetch.stdout)
        # The remote is still perfectly readable, which is what makes the stale
        # local ref look like an answer.
        readable = self.workflow.sh(
            asset_command(self.workflow.asset, 'DEFAULT_BRANCH="$(git -C "$ROOT" ls-remote')
            + ' && printf %s "$DEFAULT_BRANCH"'
        )
        self.assertEqual(readable.stdout.strip(), "master")
        self.assertEqual(
            e2e_git(self.workflow.root, "rev-parse", "refs/remotes/origin/master").strip(),
            stale,
        )

        # The run stops here: no worktree was created, under this attempt's
        # directory or anywhere else.
        self.assertEqual(
            [path.name for path in sorted(attempt_dir.iterdir())], ["inventory.json"]
        )
        self.assertEqual(
            e2e_git(self.workflow.root, "worktree", "list", "--porcelain").count(
                "worktree "
            ),
            2,
        )
        # And step 9 releases the claim, which is all this exit owes besides
        # its own directory.
        self.workflow.release(claimed["selected"]["number"], token, check=True)
        self.assertIsNone(self.workflow.rows()["612"]["claim"])
        self.workflow.complete_attempt(registration["attempt"])


class EarlyExits(WorkflowRunCase):
    """Round 1's second blocker: cleanup on the exits that claim nothing."""

    def setUp(self):
        super().setUp()
        self.workflow.merged([(612, "2026-09-01T00:00:00Z")])
        # The ledger and this repository's sub-second lease defaults, committed,
        # so what an early exit leaves behind is this exit's and not the
        # fixture's.
        self.workflow.lease_defaults()
        e2e_git(self.workflow.docs, "add", "-A")
        e2e_git(self.workflow.docs, "commit", "-qm", "ledger and lease defaults")

    def test_a_registration_refusal_claims_nothing_and_writes_nothing(self):
        pages = self.workflow.inventory()
        self.assertTrue(pages)
        before = self.workflow.ledger_bytes()
        completed = self.workflow.registration_attempt(handshake=False)
        self.assertEqual(completed.returncode, 2, completed.stdout)
        self.assertEqual(completed.stdout, "")
        self.assertIn("hooks-not-observed", completed.stderr)
        # Nothing was claimed and nothing was written, so the only thing this
        # exit owes cleanup is the inventory's scratch directory -- which is
        # exactly the case the unconditional cleanup recipe could not express.
        self.assertEqual(self.workflow.ledger_bytes(), before)
        self.assertEqual(
            e2e_git(self.workflow.docs, "status", "--porcelain", "--untracked-files=all"),
            "",
        )
        # Step 1 ran and step 2 refused, so nothing of this run is on disk.
        self.assertFalse(self.workflow.runtime_worktrees().exists())

    def test_an_empty_inventory_selects_nothing_and_leaves_no_claim(self):
        self.workflow.merged([])
        self.assertEqual(
            self.workflow.inventory(), [{"page": 1, "limit": 100, "prs": []}]
        )
        registration, inventory = self.workflow.registered_inventory()
        result = self.workflow.claim(inventory, registration["keeper_pid"])
        self.assertEqual(result["status"], "no-selectable-row")
        self.assertIsNone(result["selected"])
        self.assertEqual(self.workflow.rows(), {})

    def test_the_scratch_removal_cannot_reach_the_working_directory(self):
        # The sharp edge of the round-1 blocker, run rather than described.
        # `$REVIEW_ROOT` is unset on every exit before step 4 -- a registration
        # refusal, an unavailable claim, a failed fetch -- and the cleanup line
        # is executed with it unset, from a working directory holding files.
        # Under the previous `rm -rf "$(dirname "$REVIEW_WT")"` spelling that
        # `dirname` produced `.` and this removed the working directory.
        scratch = self.workflow.base / "scratch-to-remove"
        scratch.mkdir()
        (scratch / "inventory.json").write_text("{}", encoding="utf-8")
        cwd = self.workflow.base / "working-directory"
        cwd.mkdir()
        (cwd / "keep.md").write_text("not this\n", encoding="utf-8")
        command = asset_command(self.workflow.asset, 'rm -rf "$ATTEMPT_DIR"')
        self.assertNotIn("dirname", command)
        for value in ("", str(scratch)):
            completed = subprocess.run(
                ["sh", "-c", command],
                cwd=str(cwd),
                env=dict(self.workflow.env, ATTEMPT_DIR=value),
                capture_output=True,
                text=True,
                timeout=60,
            )
            with self.subTest(attempt_dir=value or "<unset>"):
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertTrue((cwd / "keep.md").is_file())
        self.assertFalse(scratch.exists())


class CleanupFailure(WorkflowRunCase):
    """Round 2's blocker: a removal that failed retains what it could not remove."""

    def setUp(self):
        super().setUp()
        self.workflow.merged([(612, "2026-09-01T00:00:00Z")])

    def test_a_failed_worktree_removal_retains_the_directory_it_named(self):
        # The removal is made to fail for real -- the scratch parent loses its
        # write permission, so `git worktree remove` cannot unlink the tree --
        # and then the asset's own two removal lines are run in the order it
        # spells them. `$REVIEW_ROOT` survives, with the worktree and Git's
        # record of it both intact, and `$SCRATCH` goes anyway.
        pin, review_wt = self.workflow.pin()
        review_root = review_wt.parent
        # The inventory lives in the same directory, so a retained one retains
        # it too -- which is the point: one directory, reported by one path.
        (review_root / "inventory.json").write_text("{}", encoding="utf-8")
        mode = review_root.stat().st_mode
        os.chmod(review_root, 0o500)

        def restore():
            # Suppressed because the body below removes the directory on the
            # way out; this is the safety net for a failure before that.
            with contextlib.suppress(FileNotFoundError):
                os.chmod(review_root, mode)

        self.addCleanup(restore)

        removal = self.workflow.sh(
            asset_command(self.workflow.asset, 'git -C "$ROOT" worktree remove'),
            check=False,
            REVIEW_WT=str(review_wt),
        )
        self.assertNotEqual(removal.returncode, 0, removal.stdout)
        # Step 4 is conditional on that success, so it does not run and the
        # worktree is still on disk to be reported. Whether Git's own record
        # survived the partial removal is Git's business and varies -- here it
        # dropped the record first and then failed to unlink the tree -- which
        # is exactly why the asset assumes neither and names `worktree prune`
        # as the repair for a record that did survive.
        self.assertTrue(review_wt.is_dir())
        self.assertTrue((review_root / "inventory.json").is_file())

        # Tidying up after a deliberately broken removal is this test's own
        # business, not the workflow's: the record is already gone here, so
        # `worktree remove` would refuse a second time.
        os.chmod(review_root, mode)
        e2e_git(self.workflow.root, "worktree", "prune")
        shutil.rmtree(review_root)


class OrphanReclaim(WorkflowRunCase):
    """Round 3's blockers: the exits no cleanup step could reach."""

    def setUp(self):
        super().setUp()
        self.workflow.merged([(612, "2026-09-01T00:00:00Z")])
        self.workflow.lease_defaults()

    def test_a_failed_worktree_add_still_gives_up_its_scratch_root(self):
        # `$REVIEW_ROOT` exists from the moment step 4 names it, so an add that
        # fails outright leaks it unless the removal is conditioned on the
        # resource rather than on the step that was meant to fill it. The add
        # is made to fail for real, with a commit this repository does not
        # have.
        runtime = self.workflow.runtime_worktrees()
        attempt = "0" * 32
        review_root = runtime / attempt
        review_wt = review_root / "tree"
        failed = self.workflow.sh(
            asset_command(self.workflow.asset, 'git -C "$ROOT" worktree add'),
            check=False,
            REVIEW_WT=str(review_wt),
            PIN="f" * 40,
        )
        self.assertNotEqual(failed.returncode, 0, failed.stdout)
        review_root.mkdir(parents=True, exist_ok=True)

        # Step 3 runs on the *attempt*, finds nothing registered, and says so;
        # step 4 then follows and the scratch root goes.
        removal = self.workflow.cleanup_worktree(review_wt)
        self.assertNotEqual(removal.returncode, 0)
        self.assertIn("is not a working tree", removal.stderr)
        self.assertFalse(review_root.exists())

    def cancel_after(self, stage, terminate=True):
        """Register, claim, create `stage`'s resources, then end the session.

        No cleanup step of the cancelled invocation's runs -- which is the
        whole case: what has to happen afterwards has to happen without one.
        """
        registration, inventory = self.workflow.registered_inventory(
            session="session-a", invocation="invocation-1"
        )
        attempt_dir = inventory.parent
        claimed = self.workflow.claim(inventory, registration["keeper_pid"])
        self.assertEqual(claimed["status"], "claimed")
        review_wt = None
        if stage == "pinned":
            _, review_wt = self.workflow.pin(attempt=registration["attempt"])
        if terminate:
            self.workflow.hook(
                "SessionEnd", session="session-a", invocation="invocation-1"
            )
        return registration, claimed, attempt_dir, inventory, review_wt

    def assert_cancellation_completes_without_a_tool_call(self, registration, claimed):
        """Requirement 5's three things, each by the mechanism that does it."""
        token = claimed["claim"]["token"]
        # Processes: the runtime's own mechanism ends the keeper.
        e2e_wait(
            lambda: not self.workflow.running(registration["keeper_pid"]),
            "the keeper outlived the cancelled session",
        )
        self.assertEqual(
            self.workflow.attempt_state(registration["attempt"]), "ended"
        )
        # The claim: renewal stops with it, the lease runs out, and the row is
        # claimable again -- by anyone but the cancelled attempt, whose token
        # no longer owns it.
        e2e_wait(
            lambda: self.workflow.heartbeat_renewals(token) is None,
            "renewal outlived the cancelled session",
        )
        successor, inventory = self.workflow.registered_inventory(
            session="session-b", invocation="invocation-2"
        )
        retaken = self.workflow.claim(inventory, successor["keeper_pid"])
        self.assertEqual(retaken["status"], "claimed")
        self.assertEqual(retaken["takeover"]["previous_token"], token)
        for name, attempt in (
            ("record", lambda: self.workflow.record(
                claimed["selected"]["number"], token, "clean", "a" * 40, check=False
            )),
            ("allocate-report", lambda: self.workflow.allocate(
                claimed["selected"]["number"], token, check=False
            )),
            ("release", lambda: self.workflow.release(
                claimed["selected"]["number"], token, check=False
            )),
        ):
            with self.subTest(command=name):
                self.assertEqual(attempt().returncode, 2)
        return successor

    def test_a_cancellation_after_the_inventory_leaves_nothing_but_its_own_directory(self):
        # Cancellation before any worktree exists, with no invocation after it:
        # what the runtime's mechanism achieves on its own is asserted here,
        # and nothing is left anywhere an operator or a publication would see.
        registration, claimed, attempt_dir, inventory, _ = self.cancel_after("inventory")
        self.assertTrue(inventory.is_file())
        successor = self.assert_cancellation_completes_without_a_tool_call(
            registration, claimed
        )
        # The directory is the only thing left, and it is inside no working
        # tree: neither checkout has anything untracked from it.
        self.assertTrue(attempt_dir.is_dir())
        self.assertTrue(
            str(attempt_dir).startswith(str(self.workflow.runtime_worktrees()))
        )
        self.assertEqual(
            e2e_git(self.workflow.root, "status", "--porcelain", "--untracked-files=all"),
            "",
        )
        self.assertNotIn(
            "project_review/",
            "".join(
                line
                for line in e2e_git(
                    self.workflow.docs, "status", "--porcelain", "--untracked-files=all"
                ).splitlines(keepends=True)
                if "ledger.md" not in line
            ),
        )
        # And step 1's reclaim pass, on the next invocation, removes it.
        self.assertEqual(
            self.workflow.reclaim_orphans(keep=successor["attempt"]),
            [registration["attempt"]],
        )
        self.assertFalse(attempt_dir.exists())

    def test_a_cancellation_after_pinning_is_reclaimed_with_its_worktree(self):
        registration, claimed, attempt_dir, _, review_wt = self.cancel_after("pinned")
        self.assertTrue(review_wt.is_dir())
        successor = self.assert_cancellation_completes_without_a_tool_call(
            registration, claimed
        )
        self.assertTrue(review_wt.is_dir())
        self.assertEqual(
            e2e_git(self.workflow.root, "status", "--porcelain", "--untracked-files=all"),
            "",
        )
        # Step 1's reclaim pass removes the worktree and the directory holding
        # it, and leaves the live invocation's own alone.
        _, own_wt = self.workflow.pin(attempt=successor["attempt"])
        self.assertEqual(
            self.workflow.reclaim_orphans(keep=successor["attempt"]),
            [registration["attempt"]],
        )
        self.assertFalse(attempt_dir.exists())
        self.assertTrue(own_wt.is_dir())
        self.assertNotIn(
            str(review_wt),
            e2e_git(self.workflow.root, "worktree", "list", "--porcelain"),
        )
        self.workflow.remove_pin(own_wt)
        self.workflow.complete_attempt(successor["attempt"])

    def test_a_survivor_keeps_its_directory_until_it_exits(self):
        # Round 5's blocker, answered through the interface it asked for. A
        # wrapped command that outlives a cancelled attempt is the one thing
        # that must stop the reclaim pass: deleting the worktree it is working
        # in is what nothing later repairs. The command here is backgrounded --
        # its tool call finishes at once -- which is exactly the survivor
        # `exempt_launches` cannot name and `unfinished_launches` can.
        registration, claimed, attempt_dir, _, review_wt = self.cancel_after("pinned")
        command = (
            f'python3 {self.workflow.liveness_path} run --root {self.workflow.docs} '
            f'--attempt {registration["attempt"]} --launch build -- make test'
        )
        self.workflow.hook(
            "PreToolUse",
            session="session-a",
            invocation="invocation-1",
            command=command,
            tool_use_id="tool-bg",
        )
        child = subprocess.Popen(
            [
                sys.executable, str(self.workflow.liveness_path), "run",
                "--root", str(self.workflow.docs),
                "--attempt", registration["attempt"], "--launch", "build", "--",
                sys.executable, "-c", "import time; time.sleep(600)",
            ],
            env=self.workflow.env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.workflow.pids.append(child.pid)
        self.addCleanup(lambda: (child.poll() is None and child.kill(), child.wait()))
        self.workflow.hook(
            "PostToolUse",
            session="session-a",
            invocation="invocation-1",
            command=command,
            tool_use_id="tool-bg",
        )
        e2e_wait(
            lambda: self.workflow.attempt_status(registration["attempt"])[
                "unfinished_launches"
            ]
            == ["build"],
            "the survivor was never reported unfinished",
        )
        # The attempt is over and the exemption has lapsed, so every other
        # signal says reclaim it.
        self.assertTrue(self.workflow.attempt_is_over(registration["attempt"]))
        self.assertEqual(
            self.workflow.attempt_status(registration["attempt"])["exempt_launches"], []
        )

        successor = self.workflow.register(session="session-b", invocation="invocation-2")
        self.assertEqual(self.workflow.reclaim_orphans(keep=successor["attempt"]), [])
        self.assertEqual(
            self.workflow.retained_orphans, [(registration["attempt"], "launches:build")]
        )
        self.assertTrue(review_wt.is_dir())

        # Once the command exits, the same pass takes it.
        child.kill()
        child.wait(timeout=E2E_SETTLE)
        e2e_wait(
            lambda: self.workflow.attempt_status(registration["attempt"])[
                "unfinished_launches"
            ]
            == [],
            "the launch stayed unfinished after its process exited",
        )
        self.assertEqual(
            self.workflow.reclaim_orphans(keep=successor["attempt"]),
            [registration["attempt"]],
        )
        self.assertFalse(attempt_dir.exists())
        self.workflow.complete_attempt(successor["attempt"])

    def test_a_killed_keeper_leaves_an_attempt_that_still_reads_active(self):
        # The other half: a keeper killed outright writes no ended record, so
        # its attempt reads `active` forever. Reading that alone as "still
        # running" strands the directory, which is why the asset's rule looks
        # at the keeper's standing too.
        registration, claimed, attempt_dir, _, review_wt = self.cancel_after(
            "pinned", terminate=False
        )
        os.kill(registration["keeper_pid"], signal.SIGKILL)
        e2e_wait(
            lambda: not self.workflow.running(registration["keeper_pid"]),
            "the keeper survived a kill",
        )
        status = self.workflow.attempt_status(registration["attempt"])
        self.assertEqual(status["status"], "active")
        self.assertNotEqual(status["keeper_standing"], "live")
        self.assertTrue(self.workflow.attempt_is_over(registration["attempt"]))

        successor = self.workflow.register(session="session-b", invocation="invocation-2")
        self.assertEqual(
            self.workflow.reclaim_orphans(keep=successor["attempt"]),
            [registration["attempt"]],
        )
        self.assertFalse(attempt_dir.exists())
        self.workflow.complete_attempt(successor["attempt"])

    def test_an_already_tracked_finding_is_recordable_as_findings(self):
        # Round 3's other blocker: a review whose only finding is already in the
        # tracker had no honest outcome -- `clean` is false, and the helper
        # refuses `findings` with nothing linked. It gets a report entry whose
        # Deduplication names the issue, so `findings` has its evidence.
        report = REPORT_FIXTURE.replace(
            "- **Deduplication:** Nothing open.",
            "- **Deduplication:** Already tracked as coghex/kanban#4242.",
        )
        self.assertIn("Already tracked as", report)
        result = self.workflow.review_once(outcome="findings", findings=report)
        row = self.workflow.rows()[str(result["selected"]["number"])]
        self.assertEqual(row["status"], "findings")
        self.assertEqual(row["report"], result["report"])
        self.assertIn(
            "Already tracked as",
            (self.workflow.docs / row["report"]).read_text(encoding="utf-8"),
        )


class DirectMode(WorkflowRunCase):
    """Requirement 7, executed: a direct batch touches no ledger and no claim."""

    def setUp(self):
        super().setUp()
        self.workflow.merged([(612, "2026-09-01T00:00:00Z")])
        self.shas = self.workflow.first_parent_history(6)

    def test_a_direct_batch_records_on_the_cursor_and_leaves_the_ledger_alone(self):
        before = self.workflow.ledger_bytes()
        selected = self.workflow.direct_select(count=3)
        self.assertEqual(
            [entry["sha"] for entry in selected["selected"]], list(self.shas[:3])
        )
        # A direct report is named by the reviewer, not allocated, and it goes
        # beside the pre-ledger reports rather than under docs/project_review/.
        report = (
            f"docs/project_review_direct_{self.shas[0][:7]}-{self.shas[2][:7]}.md"
        )
        (self.workflow.docs / report).write_text(
            f"# Project Review Findings: direct commits {self.shas[0]}–{self.shas[2]}\n",
            encoding="utf-8",
        )
        recorded = self.workflow.direct_record(self.shas[:3])
        self.assertEqual(
            recorded["state"]["direct"]["endpoint"]["sha"], self.shas[2]
        )
        # No ledger row, no claim, no checkpoint: the ledger is byte-identical.
        self.assertEqual(self.workflow.ledger_bytes(), before)
        self.assertEqual(self.workflow.rows(), {})
        # And the next batch resumes below the recorded frontier.
        again = self.workflow.direct_select(count=2)
        self.assertEqual(
            [entry["sha"] for entry in again["selected"]], list(self.shas[3:5])
        )


class LegacyMigration(WorkflowRunCase):
    def test_legacy_coverage_imports_from_the_cursor_and_the_reports_it_names(self):
        # Requirement 11's second proof, and design D-9's rule: a report's
        # explicit enumeration is coverage and its filename interval is not.
        self.workflow.merged(
            [
                (612, "2026-09-06T00:00:00Z"),
                (610, "2026-09-05T00:00:00Z"),
                (608, "2026-09-04T00:00:00Z"),
                (606, "2026-09-03T00:00:00Z"),
                (604, "2026-09-02T00:00:00Z"),
            ]
        )
        self.workflow.write_cursor([612, 610])
        (self.workflow.docs / "docs" / "project_review_608-604.md").write_text(
            "# Project Review Findings: PRs #608–#604\n\n"
            # One of the nineteen tracked reports' own sentence templates:
            # anything else flags, which is the next case.
            "This review covered the 3 newest merged pull requests as of "
            "2026-09-04, ordered by merge time: #608, #606 and #604.\n",
            encoding="utf-8",
        )
        result = json.loads(self.workflow.migrate().stdout)
        self.assertEqual(result["status"], "migrated")
        rows = self.workflow.rows()
        self.assertEqual(sorted(int(key) for key in rows), [604, 606, 608, 610, 612])
        # #607 and #605 sit inside the report's filename interval and are not
        # in its enumeration, so they are not coverage.
        self.assertNotIn("607", rows)
        self.assertNotIn("605", rows)
        for key, row in rows.items():
            self.assertEqual(row["status"], "legacy", key)
            self.assertIsNone(row["completed_at"], key)
            self.assertTrue(row["evidence"], key)

    def test_a_flagged_report_stops_the_migration_until_it_is_confirmed(self):
        # Design D-9's recovery path: nothing is written while a flag stands,
        # and the operator's own enumeration is what clears it.
        self.workflow.merged([(612, "2026-09-06T00:00:00Z")])
        self.workflow.write_cursor([612])
        (self.workflow.docs / "docs" / "project_review_463-455.md").write_text(
            "# Project Review Findings: PRs #463–#455\n\n"
            "This review covered PR #463 (partially), #456 and #455.\n",
            encoding="utf-8",
        )
        completed = self.workflow.migrate(check=False)
        self.assertEqual(completed.returncode, 3, completed.stderr)
        flagged = json.loads(completed.stdout)
        self.assertEqual(flagged["status"], "flagged")
        self.assertEqual(
            [entry["report"] for entry in flagged["flags"]],
            ["docs/project_review_463-455.md"],
        )
        self.assertTrue(flagged["flags"][0]["candidates"])
        self.assertIsNone(flagged["document"])
        self.assertIsNone(self.workflow.ledger_bytes())

        confirmed = self.workflow.migrate(
            "docs/project_review_463-455.md=463,456,455", check=False
        )
        self.assertEqual(confirmed.returncode, 0, confirmed.stderr)
        self.assertEqual(
            sorted(int(key) for key in self.workflow.rows()), [455, 456, 463, 612]
        )


class QueueOrder(WorkflowRunCase):
    def test_the_three_queues_select_in_the_approved_order(self):
        # Requirement 11's third proof, and design D-8: never-reviewed newest
        # first, then legacy highest-number first, then the oldest completed
        # review. Each step is a whole real review, so what the next selection
        # sees is what the previous one actually recorded.
        self.workflow.merged(
            [
                (620, "2026-09-05T00:00:00Z"),
                (618, "2026-09-04T00:00:00Z"),
                (616, "2026-09-03T00:00:00Z"),
                (614, "2026-09-02T00:00:00Z"),
            ]
        )
        self.workflow.write_cursor([616, 614])
        self.workflow.migrate()
        self.workflow.lease_defaults()

        picked = []
        for index in range(4):
            if index:
                # A completed-review timestamp is recorded to the second, and
                # the refresh queue orders by it with ascending number as the
                # tie-break. Four reviews inside one second would therefore be
                # ordered by number rather than by age, and the fifth pick
                # below would be asserting the tie-break instead of D-4's rule.
                time.sleep(1.1)
            result = self.workflow.review_once()
            picked.append((result["selected"]["number"], result["queue"]["name"]))
        self.assertEqual(
            picked,
            [
                (620, self.module.QUEUE_NEVER_REVIEWED),
                (618, self.module.QUEUE_NEVER_REVIEWED),
                (616, self.module.QUEUE_LEGACY),
                (614, self.module.QUEUE_LEGACY),
            ],
        )
        # A fifth invocation has nothing never-reviewed and nothing legacy
        # left, so it refreshes the oldest completed review -- the first one.
        rows = self.workflow.rows()
        completed = sorted(
            (rows[str(number)]["completed_at"], number) for number, _ in picked
        )
        self.assertEqual(len({timestamp for timestamp, _ in completed}), 4, completed)
        fifth = self.workflow.review_once()
        self.assertEqual(
            (fifth["selected"]["number"], fifth["queue"]["name"]),
            (completed[0][1], self.module.QUEUE_REFRESH),
        )
        self.assertEqual(completed[0][1], 620)


class CompletedReviews(WorkflowRunCase):
    def setUp(self):
        super().setUp()
        self.workflow.merged(
            [(612, "2026-09-01T00:00:00Z"), (610, "2026-08-01T00:00:00Z")]
        )
        self.workflow.lease_defaults()

    def reports(self):
        directory = self.workflow.docs / "docs" / "project_review"
        return sorted(path.name for path in directory.iterdir())

    def test_a_clean_review_records_its_verification_commit_and_writes_no_report(self):
        result = self.workflow.review_once()
        row = self.workflow.rows()["612"]
        self.assertEqual(row["status"], "clean")
        self.assertEqual(row["commit"], result["pin"])
        self.assertIsNone(row["report"])
        self.assertIsNone(row["claim"])
        self.assertRegex(row["completed_at"], self.module.TIMESTAMP_RE)
        self.assertEqual(self.reports(), ["ledger.md"])

    def test_a_findings_review_records_its_report_in_the_same_checkpoint(self):
        result = self.workflow.review_once(outcome="findings", findings=REPORT_FIXTURE)
        row = self.workflow.rows()["612"]
        self.assertEqual(row["status"], "findings")
        self.assertEqual(row["report"], "docs/project_review/612.md")
        self.assertRegex(row["completed_at"], self.module.TIMESTAMP_RE)
        # Read back out of Git rather than out of the helper's own result: one
        # commit, on the docs worktree's branch, touching only the ledger and
        # the report it allocated.
        checkpoint = result["checkpoint"]["commit"]
        self.assertEqual(
            e2e_git(self.workflow.docs, "rev-parse", "HEAD").strip(), checkpoint
        )
        changed = sorted(
            e2e_git(
                self.workflow.docs, "diff-tree", "--no-commit-id", "-r", "--name-only",
                f"{checkpoint}^", checkpoint,
            ).split()
        )
        self.assertEqual(
            changed, ["docs/project_review/612.md", "docs/project_review/ledger.md"]
        )
        # The operator's own file is untouched by the checkpoint.
        self.assertEqual(
            (self.workflow.docs / "docs" / "notes.md").read_text(encoding="utf-8"),
            "operator notes\n",
        )

    def test_both_a_clean_and_a_findings_review_advance_the_completion_timestamp(self):
        first = self.workflow.review_once()
        second = self.workflow.review_once(outcome="findings", findings=REPORT_FIXTURE)
        rows = self.workflow.rows()
        self.assertEqual(
            {rows["612"]["status"], rows["610"]["status"]}, {"clean", "findings"}
        )
        for key in ("612", "610"):
            self.assertRegex(rows[key]["completed_at"], self.module.TIMESTAMP_RE)
        self.assertNotEqual(first["selected"]["number"], second["selected"]["number"])

    def test_the_row_history_a_dedup_needs_is_only_visible_after_the_claim(self):
        # Round 2's blocker. The read the workflow takes before the inventory
        # is a snapshot of a row anybody can still record against, so a finding
        # compared against it can be one somebody else has already reported.
        # Here another invocation records exactly that between the two reads.
        snapshot = self.workflow.rows()

        recorded = self.workflow.review_once(
            outcome="findings", findings=REPORT_FIXTURE
        )
        reviewed = recorded["selected"]["number"]
        report = recorded["report"]
        self.assertIsNotNone(report)

        registration, inventory = self.workflow.registered_inventory()
        claimed = self.workflow.claim(inventory, registration["keeper_pid"])
        self.assertEqual(claimed["status"], "claimed")
        # The claim's own payload carries the row's status but not its history,
        # so it cannot stand in for the read either.
        self.assertNotIn("history", claimed["selected"])

        after = self.workflow.rows()
        self.assertNotIn(str(reviewed), snapshot)
        allocations = [
            entry["report"]
            for entry in after[str(reviewed)]["history"]
            if entry.get("report")
        ]
        self.assertIn(report, allocations)
        self.workflow.complete_attempt(registration["attempt"])

    def test_a_repeats_only_review_allocates_no_report_and_is_not_clean(self):
        # The approving issue review's spec addition: a review whose only
        # findings are verified unresolved repeats writes no report, records
        # the existing-finding links, advances the timestamp, and gets no clean
        # mark. Report absence alone must never imply cleanliness.
        first = self.workflow.review_once(outcome="findings", findings=REPORT_FIXTURE)
        reviewed = first["selected"]["number"]
        # A completed-review timestamp is recorded to the second, and the
        # refresh queue orders by it with ascending number as the tie-break.
        # Two reviews inside one second would hand the third invocation the
        # lower number instead of the older review, and this case is about the
        # row the *first* review left findings on.
        time.sleep(1.1)
        self.workflow.review_once()  # the other row, so the next pick refreshes
        before = self.workflow.rows()
        self.assertLess(
            before[str(reviewed)]["completed_at"], before["610"]["completed_at"]
        )
        repeated = self.workflow.review_once(
            outcome="findings", repeats=[f"docs/project_review/{reviewed}.md#PRR-1"]
        )
        self.assertEqual(repeated["selected"]["number"], reviewed)
        # This attempt allocated nothing, and recorded the existing finding.
        self.assertIsNone(repeated["report"])
        self.assertEqual(
            repeated["repeats"],
            [{"report": f"docs/project_review/{reviewed}.md", "key": "PRR-1"}],
        )
        row = self.workflow.rows()[str(reviewed)]
        self.assertEqual(row["status"], "findings")
        self.assertRegex(row["completed_at"], self.module.TIMESTAMP_RE)
        self.assertGreater(row["completed_at"], first["completed_at"])
        self.assertEqual(reviewed, 612)
        # The row still links the report the finding is actually written in --
        # the first review's -- rather than gaining a second, empty one. That
        # is the whole shape of the rule: no new entry, no clean mark, and a
        # findings row whose evidence is where it has always been.
        self.assertEqual(row["report"], f"docs/project_review/{reviewed}.md")
        self.assertEqual(self.reports(), [f"{reviewed}.md", "ledger.md"])
        # The attempt history keeps both, so "no new report" is a property of
        # this attempt rather than something the row's own field could hide.
        attempts = [
            entry
            for entry in row["history"]
            if entry["kind"] == self.module.ATTEMPT_KIND
        ]
        self.assertEqual(
            [entry["report"] for entry in attempts],
            [f"docs/project_review/{reviewed}.md", None],
        )


class InterruptionAndTakeover(WorkflowRunCase):
    def setUp(self):
        super().setUp()
        self.workflow.merged([(612, "2026-09-01T00:00:00Z")])
        self.workflow.lease_defaults()

    def test_an_interrupted_review_leaves_no_completion_behind(self):
        registration, inventory = self.workflow.registered_inventory()
        self.workflow.claim(inventory, registration["keeper_pid"])
        self.workflow.hook("SessionEnd")
        e2e_wait(
            lambda: not self.workflow.running(registration["keeper_pid"]),
            "the keeper outlived the session",
        )
        row = self.workflow.rows()["612"]
        self.assertEqual(row["status"], "never-reviewed")
        self.assertIsNone(row["completed_at"])
        self.assertIsNone(row["commit"])

    def test_a_lapsed_claim_is_taken_over_and_its_former_owner_cannot_write(self):
        # Requirement 11's fifth proof. An interrupted review's keeper dies,
        # renewal stops, the lease lapses, a second invocation takes the claim
        # over -- and the first one's report allocation, record and release are
        # all refused. No false completion, and no stale-owner write.
        first, inventory = self.workflow.registered_inventory(
            session="session-a", invocation="invocation-1"
        )
        claimed = self.workflow.claim(inventory, first["keeper_pid"])
        stale_token = claimed["claim"]["token"]
        self.assertEqual(claimed["selected"]["number"], 612)

        self.workflow.hook("SessionEnd", session="session-a", invocation="invocation-1")
        e2e_wait(
            lambda: self.workflow.heartbeat_renewals(stale_token) is None,
            "the heartbeat was never retired after the session ended",
        )

        second, successor_inventory = self.workflow.registered_inventory(
            session="session-b", invocation="invocation-2"
        )
        retaken = self.workflow.claim(successor_inventory, second["keeper_pid"])
        self.assertEqual(retaken["status"], "claimed")
        self.assertEqual(retaken["selected"]["number"], 612)
        self.assertEqual(retaken["takeover"]["previous_token"], stale_token)
        fresh_token = retaken["claim"]["token"]
        self.assertNotEqual(fresh_token, stale_token)

        before = self.workflow.ledger_bytes()
        head = e2e_git(self.workflow.docs, "rev-parse", "HEAD").strip()
        for name, attempt in (
            ("allocate-report", lambda: self.workflow.allocate(612, stale_token, check=False)),
            ("record", lambda: self.workflow.record(612, stale_token, "clean", "a" * 40, check=False)),
            ("release", lambda: self.workflow.release(612, stale_token, check=False)),
        ):
            completed = attempt()
            with self.subTest(command=name):
                self.assertEqual(completed.returncode, 2, completed.stdout)
                self.assertEqual(completed.stdout, "")
        self.assertEqual(self.workflow.ledger_bytes(), before)
        self.assertEqual(e2e_git(self.workflow.docs, "rev-parse", "HEAD").strip(), head)

        # The replacement completes normally.
        recorded = self.workflow.record(612, fresh_token, "clean", "b" * 40)
        self.assertEqual(recorded["status"], "recorded")
        self.assertEqual(self.workflow.rows()["612"]["status"], "clean")


class AdapterIntegration(WorkflowRunCase):
    """Requirement 11: each packaged workflow through the real #687 adapter."""

    def setUp(self):
        super().setUp()
        self.workflow.merged([(612, "2026-09-01T00:00:00Z")])
        self.workflow.lease_defaults()
    def claimed(self, **kwargs):
        registration, inventory = self.workflow.registered_inventory(**kwargs)
        result = self.workflow.claim(inventory, registration["keeper_pid"])
        self.assertEqual(result["status"], "claimed")
        e2e_wait(
            lambda: (self.workflow.heartbeat_renewals(result["claim"]["token"]) or 0) >= 1,
            "no renewal ever arrived",
        )
        return registration, result["claim"]["token"]

    def assert_renewal_stops(self, token, message):
        e2e_wait(
            lambda: self.workflow.heartbeat_renewals(token) is None,
            message,
            timeout=2 * E2E_SILENCE + 8 * E2E_EXPIRY,
        )

    def test_session_termination_stops_renewal_within_the_lease_interval(self):
        _, token = self.claimed()
        self.workflow.hook("SessionEnd")
        self.assert_renewal_stops(token, "renewal outlived the session")

    def test_turn_completion_stops_renewal_within_the_lease_interval(self):
        _, token = self.claimed()
        self.workflow.hook(self.workflow.spec["terminal_event"])
        self.assert_renewal_stops(token, "renewal outlived the completed turn")

    def test_a_cancellation_between_tool_calls_stops_renewal_after_the_silence_window(self):
        # A cancellation neither runtime necessarily reports: no event arrives
        # at all, and the silence window is the bound. This is the case an
        # application-lifetime signal would never end.
        _, token = self.claimed()
        self.assert_renewal_stops(token, "renewal outlived the silence window")

    def test_a_long_running_child_preserves_renewal_while_the_invocation_is_active(self):
        # The wrapped-launch exemption: a command started through `run` keeps
        # the keeper alive past the silence window while its launching tool
        # call is still in flight, so a long build inside one review does not
        # lose the claim.
        registration, token = self.claimed()
        tool_use_id = "tool-wrapped"
        command = (
            f'python3 {self.workflow.liveness_path} run --root {self.workflow.docs} '
            f'--attempt {registration["attempt"]} --launch build -- make test'
        )
        self.workflow.hook("PreToolUse", command=command, tool_use_id=tool_use_id)
        child = subprocess.Popen(
            [
                sys.executable, str(self.workflow.liveness_path), "run",
                "--root", str(self.workflow.docs),
                "--attempt", registration["attempt"], "--launch", "build", "--",
                sys.executable, "-c", f"import time; time.sleep({6 * E2E_SILENCE})",
            ],
            env=self.workflow.env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.workflow.pids.append(child.pid)
        self.addCleanup(lambda: (child.poll() is None and child.kill(), child.wait()))
        deadline = time.monotonic() + 2.5 * E2E_SILENCE
        while time.monotonic() < deadline:
            self.assertIsNotNone(
                self.workflow.heartbeat_renewals(token),
                "renewal stopped while a wrapped command was in flight",
            )
            time.sleep(0.1)
        # The tool call finishes, the exemption ends, and the claim lapses.
        child.kill()
        child.wait(timeout=E2E_SETTLE)
        self.workflow.hook("PostToolUse", command=command, tool_use_id=tool_use_id)
        self.assert_renewal_stops(token, "renewal outlived the wrapped command")

    def test_a_superseded_attempt_cannot_write_or_clean_up_its_replacement(self):
        # Requirement 5's attempt scoping, through the adapter: a second
        # registration by the same session ends the first attempt at once, and
        # the superseded attempt's own `complete` neither ends nor disturbs its
        # replacement.
        first, first_token = self.claimed(session="session-a", invocation="invocation-1")
        second = self.workflow.register(session="session-a", invocation="invocation-2")
        self.assertNotEqual(first["attempt"], second["attempt"])
        # The replacement is a live invocation, so it keeps showing progress
        # while the superseded one is being watched; without that its own
        # silence window would end it and the assertion below would pass for
        # the wrong reason.
        e2e_wait(
            lambda: self.keep_alive(second) or self.workflow.heartbeat_renewals(first_token) is None,
            "the superseded attempt kept renewing",
            timeout=2 * E2E_SILENCE + 8 * E2E_EXPIRY,
        )
        # The superseded attempt completes only itself.
        self.workflow.complete_attempt(first["attempt"])
        self.keep_alive(second)
        self.assertEqual(self.attempt_status(first["attempt"])["status"], "ended")
        replacement = self.attempt_status(second["attempt"])
        self.assertEqual(replacement["status"], "active")
        self.assertEqual(replacement["keeper_standing"], "live")

    def keep_alive(self, registration):
        """One bound progress event for `registration`'s own invocation."""
        self.workflow.hook(
            "PreToolUse",
            session=registration["session_id"],
            invocation=registration["invocation_id"],
        )
        return False

    def attempt_status(self, attempt):
        status = self.workflow.attempt_status(attempt)
        self.assertIsNotNone(status, attempt)
        return status


class PackagedConsistencyTests(unittest.TestCase):
    """Requirement 11: both packaged workflows carry the helpers they call."""

    def test_each_bundle_ships_every_module_its_own_asset_resolves(self):
        for brand, spec in BRAND_BUNDLES.items():
            root = REPO_ROOT / spec["bundle_root"]
            with self.subTest(brand=brand):
                for key in ("ledger", "liveness", "cursor"):
                    self.assertTrue((root / spec[key]).is_file(), spec[key])
                self.assertTrue((root / "hooks" / "hooks.json").is_file())

    def test_each_asset_names_its_own_bundle_layout_for_every_module(self):
        for brand, spec in BRAND_BUNDLES.items():
            content = read(spec["asset"])
            with self.subTest(brand=brand):
                for key in ("ledger", "liveness", "cursor"):
                    self.assertIn(Path(spec[key]).name, content)


def _end_to_end_cases():
    for mixin in (
        HelperResolution,
        FreshRepository,
        PinnedTree,
        FetchFailure,
        EarlyExits,
        CleanupFailure,
        OrphanReclaim,
        DirectMode,
        LegacyMigration,
        QueueOrder,
        CompletedReviews,
        InterruptionAndTakeover,
        AdapterIntegration,
    ):
        for brand in BRAND_BUNDLES:
            name = f"{brand.capitalize()}{mixin.__name__}Tests"
            globals()[name] = type(name, (mixin, unittest.TestCase), {"BRAND": brand})


_end_to_end_cases()


if __name__ == "__main__":
    unittest.main()
