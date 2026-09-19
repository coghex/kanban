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
  commit mode with its frontier rules, the report-filename rules, and the
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
* **Direct mode is one section, and it is the ledger's too.** Issue #686
  retired the sweep cursor and moved direct-commit progress onto the ledger's
  `direct` key, so both modes now call one module and "the asset names the
  ledger" cannot distinguish them. What distinguishes them is *which
  subcommands, and where*: every `direct-select`, `direct-record` and
  positioning rule lives below the direct-mode heading, and PR mode's
  `claim`/`allocate-report`/`record` live above it and nowhere else. The
  section split is therefore the unit of assertion, and
  `test_pr_mode_names_no_direct_invocation` is the negative control that keeps
  the direct pins from passing vacuously on a document whose PR sweep had
  drifted into them.
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

`project_review_cursor.py` ships in neither bundle since issue #686. Its
direct-mode state transitions moved to `tools/test_project_review_ledger.py`,
where they run against `project_review_ledger.py`'s own `direct-select` and
`direct-record` over temporary repositories with real first-parent history; its
PR-mode half was already superseded by the ledger in issue #684, and the
document it wrote survives only as a migration input that module's own parsers
read.

Nothing here loads it. It is still spelled below, in four places and each one
an assertion that it is gone: `REFUSED_HELPER_LOOKUPS`, which refuses an asset
that resolved it again; `test_no_asset_names_the_retired_cursor_module` and
`test_the_retired_cursor_module_ships_in_neither_bundle`, which are that
absence over the assets and over the bundles; and `V2_CURSOR_HEADER`, which
reproduces the document's own prose because that is what a consumer who has
not migrated actually holds. Requirement 7 asks that nothing *depends* on the
module, and naming it to prove it is absent is how that is kept rather than a
way around it.

`LedgerEndToEndTests` is the arc's end-to-end proof (issue #684, requirement
11). It drives the shipped ledger and liveness modules through the invocation
order both rendered assets spell, in temporary repositories with temporary docs
worktrees and a fake `gh` on a temporary `PATH`, and it asserts the claims the
design makes rather than the ones the helpers report about themselves: what a
checkpoint contains is read back out of Git, and what a lapsed lease permits is
read back out of the ledger. No test here reaches the network, spawns a model,
or touches a real repository.

`SerialAutomation` is the last case that proof was waiting on (issue #685,
LEDGER-7): the automation asset performs no step of its own, so what it adds is
a counting rule over what the delegate reports, and those cases drive that rule
over whole delegated invocations made through the same asset-extracted helper
lines. The automation's own prose is pinned in
`tools/test_auto_project_review_workflow.py`, beside this half rather than
inside it.

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
}

CLAUDE_LEDGER_HELPER = BUNDLED_HELPERS["ledger"]["claude"]

# How each brand's rendered asset locates the directory the two share.
# Neither spelling is a path into the reviewed repository -- the helpers ship
# with the bundle -- and neither goes through one of the modules: which of them
# an invocation needs is the mode's answer, so a locator naming one would make
# every mode depend on that one being installed.
HELPER_LOOKUPS = {
    "claude": ('SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"',),
    "codex": (
        'SCRIPTS="$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" -type d '
        "-path '*/kanban/*/skills/project-review/scripts' "
        '2>/dev/null | head -n1)"',
    ),
}

# The locator's own guard, per brand: the Codex one has a found-nothing case
# that `${CLAUDE_PLUGIN_ROOT}` cannot have.
HELPER_LOCATOR_GUARDS = {
    "claude": '[ -d "$SCRIPTS" ]',
    "codex": '[ -n "$SCRIPTS" ] && [ -d "$SCRIPTS" ]',
}

# And the resolution below it, one fence per mode and neither brand's own:
# only the directory above differs per brand. Round 8's blocker -- a single
# fence resolving and checking every module left each mode dependent on one it
# never calls. Since issue #686 both modes call the ledger; direct mode takes
# no claim, so it still must not require the liveness adapter, and that is the
# whole of what separates the two fences now.
MODE_HELPERS = {
    "pr": (
        'LEDGER="$SCRIPTS/project_review_ledger.py"',
        'LIVENESS="$SCRIPTS/project_review_liveness.py"',
        '[ -f "$LEDGER" ] && [ -f "$LIVENESS" ]',
    ),
    "direct": (
        'LEDGER="$SCRIPTS/project_review_ledger.py"',
        '[ -f "$LEDGER" ]',
    ),
}

# A lookup that would resolve nothing wherever this command actually installs,
# and -- the last two -- the mode-blind resolution round 8 refused: a locator
# that goes looking for the ledger module, and one fence requiring the adapter
# for both modes.
REFUSED_HELPER_LOOKUPS = (
    "$DOCS_WT/project_review_ledger.py",
    "$ROOT/tools/project_review_ledger.py",
    "scripts/project_review_ledger.py' 2>/dev/null",
    # The module issue #686 retired. Named here rather than merely absent from
    # the lists above, so an asset that resolved it again fails this module
    # rather than only the bundle manifests.
    "project_review_cursor.py",
)

# What the direct-mode fence must not require. Direct mode takes no claim and
# starts no keeper, so a bundle whose liveness adapter is missing has to serve
# a direct batch -- and a fence that checked for it would refuse one.
REFUSED_DIRECT_HELPERS = ("$LIVENESS", "project_review_liveness.py")

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
        'python3 "$SCRIPTS/project_review_liveness.py" register '
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
        'python3 "$SCRIPTS/project_review_liveness.py" run '
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

# The invocations the direct-commit section makes, and nothing else makes
# them. Both modes call one module since issue #686, so what separates them is
# the subcommand: these two exist nowhere above the direct heading.
DIRECT_INVOCATIONS = (
    'python3 "$LEDGER" direct-select --root "$DOCS_WT" --repo "$REPO"',
    '--count "${COUNT:-12}" --start "$RANGE_START" --end "$RANGE_END" --entry "$ENTRY"',
    'python3 "$LEDGER" direct-record --root "$DOCS_WT" --repo "$REPO"',
    '--reviewed "$REVIEWED" --exclude "$EXCLUDED" --report "$REPORT"',
)

# PR mode's own subcommands, which the direct section must not make: a direct
# batch that claimed a row, allocated a report name against one, or recorded an
# attempt on one would be writing PR state for commits that have no row.
REFUSED_DIRECT_INVOCATIONS = (
    '"$LEDGER" claim',
    '"$LEDGER" allocate-report',
    '"$LEDGER" record --root',
    '"$LEDGER" release',
)

# The direct-mode walk, which is the whole first-parent history rather than a
# slice beginning at the entry point. A sliced walk would leave the recorded
# frontier outside the walk the helper positions within, and the helper would
# then refuse it as foreign progress on every later batch -- a fail-closed
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

# The eight GitHub reads the workflow makes, by the leading words that identify
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
    # Direct mode's two, and only on a repository's first batch: the oldest
    # merged pull request's merge commit, and -- when that commit turns out
    # not to be a merge -- how many commits the pull request owns, which is
    # what places a rebase-merged series above the entry rather than inside
    # the batch. Both are reads of one pull request the caller already knows
    # the number of, and neither selects, claims, or records anything.
    'pr view "$OLDEST_PR" -R "$REPO" --json mergeCommit',
    'pr view "$OLDEST_PR" -R "$REPO" --json commits',
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
# Requirement 7 and round 7's blocker: a direct request must not travel the
# PR-only prelude. The inventory, the registration and the claim are PR mode's
# alone, and a direct batch that took them would start a keeper and claim a
# row for commits that have none.
MODE_DISPATCH = {
    "the mode is decided first": (
        "**Decide the mode here, and take only that mode's path.** PR mode is "
        "the default. Direct-commit mode happens only when the user asked for "
        "it explicitly in this turn, and when they did, **none of the PR-mode "
        "steps run at all** — not the ledger read, not the migration, not the "
        "inventory, and not the liveness registration."
    ),
    "why that is correctness": (
        "That is a correctness rule, not tidiness. Direct mode shares the "
        "ledger document with PR mode and shares nothing else: it takes no "
        "claim, starts no keeper, and writes no row, so a bundle whose "
        "liveness adapter could not be resolved must not be blocked from it, "
        "and a repository whose PR queue is exhausted must not fall into it."
    ),
    "a direct request skips every numbered step": (
        "**An explicit direct request:** resolve the scripts directory and "
        "`$LEDGER` below — direct mode's own fence, and not PR mode's — then "
        'the docs worktree, then go straight to "Direct-commit mode — '
        'explicit request only" and do everything there. Skip every numbered '
        "step."
    ),
    "the locator never goes through one of the modules": (
        "**Locate the directory the two share, never one of the modules.** "
        "Which of them this invocation needs is the mode's answer, and the "
        "mode was decided above; a locator that goes looking for one "
        "particular module makes every mode depend on that module being "
        "installed:"
    ),
    "each mode resolves only its own modules": (
        "Then resolve and check **only the modules this invocation's mode "
        "uses**, in that mode's own fence, and run the other mode's fence not "
        "at all."
    ),
    "each mode needs only its own helpers": (
        "**An unresolvable helper stops the run here, before the first read** "
        "— and a module this mode never calls being absent is not one. That "
        "is what the two fences above are for: only one of them runs, so a "
        "bundle missing its liveness adapter refuses a review and still serves "
        "a direct batch."
    ),
    "the migration is pr mode's alone": (
        "**PR mode only.** A direct request reached the direct section above "
        "and never arrives here. Direct mode reads the same ledger, and it "
        "refuses a repository that has none rather than establishing one: a "
        "direct batch that wrote the first ledger would resume from an empty "
        "frontier and re-review every commit the previous record covered."
    ),
    "an empty inventory stops before registering": (
        "**A listing with no pull requests in it at all stops the run here**, "
        "before step 2. A repository that has merged nothing has nothing for "
        "this workflow to review, and registering an attempt for it would "
        "start a keeper, write the adapter's records, and make a directory, "
        "all to discover that in step 3."
    ),
    "that exit owes nothing either": (
        "Say the repository has no merged pull requests and stop; like a "
        "failed page, this exit owes step 9 nothing, because nothing was "
        "created."
    ),
}

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
        "The ledger does not *schedule* it: the three queues are PR-only, "
        "direct commits never become rows, and no claim, lease or keeper is "
        "taken for a batch here"
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
        "separately: `unfinished_launches` names every wrapped launch that "
        "cannot be established to have ended, whether or not its tool call "
        "finished — which is the question that matters here, because the "
        "command that outlives a cancelled attempt is a backgrounded one, and "
        "`exempt_launches` is built to skip exactly those."
    ),
    "the command decides, not the wrapper around it": (
        "It answers on the *command*, not on the wrapper around it: a wrapper "
        "killed with `SIGKILL` runs no handler and so dies leaving its "
        "command running, which is why \"the wrapper is gone\" establishes "
        "nothing. A launch is gone only when the command it recorded is gone, "
        "or when the wrapper recorded having waited that command out; a "
        "launch with neither is unfinished, because a wrapper killed before "
        "it spawned looks exactly like one killed a moment after."
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
        "and report any record still naming it as an unresolved record for "
    ),
    "prune is never this workflow's to run": (
        "**Never run Git's `worktree prune` here, or anywhere else in this "
        "workflow.** It is repository-wide: it clears the administrative "
        "record of every worktree of this repository whose directory is "
        "missing, including ones belonging to a person or to another agent "
        "that this invocation knows nothing about"
    ),
    "never derive a removal target": (
        "**Never derive a removal target from another path**: the parent "
        "directory of a variable an early exit never set is the working "
        "directory, and a recursive removal of that is the one mistake this "
        "workflow could make that nothing later could repair."
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
        "runs, and which commands the runtime ends on an interruption is the "
        "runtime's own answer rather than a general rule."
    ),
    "claude 2.1.274's interrupt, as measured": (
        "**Claude Code 2.1.274:** an interrupt killed a foreground tool's "
        "processes, while a command the runtime had backgrounded survived it."
    ),
    "claude 2.1.276's interrupt, as measured": (
        "**Claude Code 2.1.276:** an interrupted foreground command keeps "
        "going, measured still running ninety seconds after the Escape."
    ),
    "codex 0.154.0's interrupt, as measured": (
        "**codex-cli 0.154.0:** an interrupted foreground command is moved to "
        "a background terminal and keeps running, its tool-finish event "
        "arriving under the old turn id only when it ends."
    ),
    "a version is what it was measured on": (
        "A version is what each of those was measured on, not a guarantee "
        "that a newer runtime still behaves that way; re-probe before quoting "
        "one."
    ),
    "every launch takes a label of its own": (
        "**Give every launch a label no earlier launch of this attempt has "
        "used.** `build` above is an example, not a name to reuse. The "
        "exemption belongs to the first wrapper that claims a label, so a "
        "second `run --launch build` starts its command and earns no "
        "exemption at all"
    ),
    "the un-exempt line is a refusal": (
        "**That line is a refusal, not a warning to read past.**"
    ),
    "the discipline is the caller's on purpose": (
        "The adapter reports the reuse rather than refusing it, and that is "
        "deliberate: refusing a label before the spawn, or giving a second "
        "wrapper an exemption of its own, would change the adapter's own "
        "execution model, which belongs to #687 and not here."
    ),
    "its finish refreshes the window rather than ending it": (
        "When that command finally exits, its tool-finish event is itself a "
        "progress event, so it **refreshes** the silence window rather than "
        "ending it: the keeper then waits that window out afresh, plus a poll, "
        "before the lease starts running down."
    ),
    "the whole bound, named": (
        "The bound is the command's remaining run time, plus a silence window, "
        "plus a keeper poll, plus one renewal interval, plus the expiry — or "
        "the end of the session, whichever comes first."
    ),
    "why the renewal interval is a phase of its own": (
        "The renewal interval is in there because the renewer follows the "
        "keeper rather than dying with it: it looks at that signal at least "
        "once per renewal interval, so it can write one more renewal after "
        "the keeper is gone, and the expiry that runs down is the one *that* "
        "renewal stamped."
    ),
    "the lease lapses and the row becomes claimable": (
        "*The claim.* Renewal stops with the keeper — within one renewal "
        "interval of it, by the rule above — so the lease runs out and the "
        "row becomes claimable again; the next invocation takes it over under "
        "the helper's lock and records the transition, which is the recovery "
        "the lease was designed around."
    ),
    "a cancelled attempt cannot write afterwards": (
        "The cancelled attempt cannot write to it afterwards: its token no "
        "longer owns the claim, so its `record`, its allocation and its "
        "release are all refused."
    ),
    "the reclaim pass takes it only when it is safe": (
        "*The directory.* Step 2's reclaim pass takes the directory of a "
        "cancelled attempt **once it can establish that taking it is safe** — "
        "the keeper positively gone, and no unfinished launch — and retains "
        "it, by name and with the reason, until then."
    ),
    "an orphan is identifiable and owned": (
        "That is why everything this invocation creates is named for the "
        "attempt and kept in one place: an orphan is identifiable, and the "
        "next invocation in this repository is its owner where it can be, and "
        "{{cmd:janitor}} where it cannot."
    ),
    "the summary names what janitor is left": (
        "its directory is taken by the next invocation that can prove nothing "
        "is using it — which is the invocation after it in the ordinary case, "
        "and an operator's `janitor` pass where the adapter can no longer "
        "answer: an `attempt-unknown` refusal, a keeper standing that is "
        "`unverifiable`, an unreadable launch record, or a launch still "
        "running."
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
        "A repository with neither an old record nor a report starts from an empty "
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
        "the ledger and not the report."
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
        "included. `direct-select` and `direct-record` resolve an abbreviated "
        "SHA against the walk, and refuse a prefix that names more than one "
        "commit rather than choosing between them, so length is never the "
        "refusal; ambiguity is."
    ),
    "the first batch is positioned below the oldest PR's own commits": (
        "The **first** batch a repository ever takes has no frontier, so it "
        "has to be positioned — and the position is below the oldest merged "
        "pull request's own commits, because those belong to PR mode and "
        "reviewing them here would audit the same work twice under a mode that "
        "cannot record it."
    ),
    "the inventory is established without selecting or claiming": (
        "Fetch it exactly as step 1 does — the same `gh` query, the same page "
        "size, the same completeness rules — and read it yourself rather than "
        "handing it to the helper: this is a positioning question, and **no "
        "row is created, no pull request is selected, and nothing is claimed** "
        "by answering it."
    ),
    "only a confirmed-empty listing permits the head of the walk": (
        "**The listing was absent, failed, or came back incomplete:** stop and "
        "say so. An unanswered question is not an empty repository, and "
        "`--entry-none` over one restarts the walk at HEAD and re-reviews every "
        "pull request's own commits as direct history. Passing neither flag is "
        "refused by the helper for the same reason."
    ),
    "a merge commit owns only itself": (
        "**Exit 0 — a merge commit.** It owns exactly itself on the "
        "first-parent walk, whatever it merged, so `$ENTRY` is `$MERGE` and "
        "the batch begins at its first parent."
    ),
    "the entry-none spelling is named exactly": (
        "For a repository whose complete listing named no merged pull request, "
        "replace `--entry \"$ENTRY\"` with `--entry-none` in that line; an empty "
        "`--entry` is no entry at all, which is what every batch after the "
        "first passes, and it is not a declaration that the repository has "
        "none."
    ),
    "the oldest pull request's number is set, not assumed": (
        "`$OLDEST_PR` is that pull request's number, read out of the listing "
        "above and set here — the two calls below are the only reads this "
        "positioning makes, and both name it"
    ),
    "the helper checks the half it can see": (
        "The helper checks the half of that answer it can see for itself: a "
        "ledger that already holds rows was built from merged pull requests, "
        "so `--entry-none` over one is refused outright however the listing "
        "came back."
    ),
    "a rebased pull request owns more than its merge commit": (
        "A squash puts one commit on the branch; a rebase puts the pull "
        "request's whole series on it as first-parent commits, so `$MERGE` is "
        "only the newest of them and beginning at its parent would select the "
        "rest of the series as direct commits — which this mode must never do."
    ),
    "over-stepping is reported rather than lost": (
        "In the rebase case that lands exactly on the series' oldest commit. "
        "In the squash case it may reach further back than necessary, and the "
        "commits it stepped over are reported as `gaps` rather than lost."
    ),
    "a gap above an entry is not an instruction": (
        "**A gap above a first batch's entry is not an instruction to review "
        "it.** The helper reports every uncovered commit above the resume "
        "position, and it cannot tell the two kinds apart: a commit the oldest "
        "pull request owns is PR mode's and is never reviewed here, while a "
        "commit a squash's step-back went past is direct history and is "
        "reclaimed with an explicit `--start`."
    ),
    "the direct walk is never sliced": (
        "**Walk the whole first-parent history, not a slice starting at the "
        "entry point.** The recorded frontier has to be inside the walk the "
        "helper positions within, and a walk that began below it would refuse "
        "it as progress belonging to some other history."
    ),
    "the interim handoff happens once and is announced": (
        "**The first invocation after this repository's cutover hands the old "
        "record over, and says so.** A consumer migrated before direct mode "
        "moved onto the ledger kept recording its direct batches against "
        "`docs/project_review_boundaries.md` in the interim, so the helper "
        "folds that document's reviewed commits and commit exclusions in and "
        "keeps the older of the two frontiers, once, on the first "
        "`direct-select` or `direct-record` it sees."
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
        "against current first-parent ancestry, so malformed, foreign, or "
        "ambiguous direct progress refuses before review rather than guessing."
    ),
    "direct gaps are announced": (
        "Every uncovered commit above the resume position appears in `gaps` "
        "and must be announced; never let the direct walk silently discard it."
    ),
    "the direct key belongs to the reviewed repository": (
        "The `direct` key of `docs/project_review/ledger.md` holds a moving "
        "older-history frontier that advances to the oldest commit a completed "
        "batch reviewed, the commits those batches read, and the reports they "
        "wrote."
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
        "rather than `exhausted`, because it was the request that ended and "
        "not the history."
    ),
    "recorded last": (
        "**Record last.** Record coverage only after every selected commit has "
        "been reviewed and any required report has been written and validated, "
        "so a failed report or a failed write is never reported as a completed "
        "batch"
    ),
    "an empty batch records nothing": (
        "A batch that reviewed nothing and excluded nothing records nothing "
        "and is not a completed batch: the helper refuses an empty "
        "`--reviewed` with an empty `--exclude`, and refuses a report for it "
        "too."
    ),
    "merged, never replaced": (
        "Recording merges rather than replaces: an earlier exclusion survives "
        "a later batch, and the frontier only ever moves older."
    ),
    "compaction recovery reads the record": (
        "If context was compacted, recover the progress with "
        '`python3 "$LEDGER" read --root "$DOCS_WT" --repo "$REPO"` rather than '
        "from the last completed range or a report name"
    ),
    "the direct filename is the helper's": (
        "A direct batch with at least one confirmed current finding writes one "
        "report at `docs/project_review/direct_<newest7>-<oldest7>.md`, under "
        "`$DOCS_WT/`. That name is the helper's: `direct-select` returns it as "
        "`report`, derived from the batch's newest and oldest commit, and "
        "refuses the batch outright when something already holds it on disk."
    ),
    "a name is taken by the disk or by the ledger": (
        "`direct-record` derives it again from the commits the batch actually "
        "reviewed, refuses a `--report` that names any other range, and refuses "
        "one this ledger already records — so a name is taken by the document "
        "on disk or by the ledger's own list of earlier batches, and neither is "
        "overwritten."
    ),
    "the direct checkpoint is path-scoped and never pushed": (
        "`direct-record` makes the same path-scoped checkpoint commit PR mode's "
        "`record` makes, on the docs worktree's own branch, carrying the ledger "
        "and this batch's report and nothing else — not an unrelated dirty "
        "file, and not an unrelated staged one."
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
    "the direct checkpoint is never pushed": (
        "Like PR mode's, it is **never pushed**: the merge and the publication "
        "are the user's, and this workflow writes to no remote at all."
    ),
    "direct mode publishes nothing on its own": (
        "Do not publish or land the checkpoint unless the user separately "
        "requests it."
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
    # The guard is stripped line-wise, so it counts as Claude's own even
    # though the Codex locator's longer guard contains it as a substring.
    HELPER_LOCATOR_GUARDS["claude"],
    REGISTRATION["claude"] + "0123456789abcdef0123456789abcdef",
    WRAPPED_LAUNCH["claude"],
)

# The Codex argument convention, and the one caveat that names Codex's default
# read-only sandbox. Requirement 6: the caveat survives for Codex, and the
# Claude rendering gains no invented equivalent.
CODEX_ONLY_LINES = (
    "An explicit count, commit SHA, or range overrides the default.",
    *HELPER_LOOKUPS["codex"],
    HELPER_LOCATOR_GUARDS["codex"],
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
                self.assertIn(HELPER_LOCATOR_GUARDS[brand], content)
                for refused in REFUSED_HELPER_LOOKUPS:
                    self.assertNotIn(refused, content)

    def test_each_mode_resolves_and_checks_only_the_modules_it_calls(self):
        # Round 8's blocker, as a pin: the locator above finds the directory,
        # and each mode's own fence names its own modules. A fence naming a
        # module the other mode never calls is what made a missing adapter
        # refuse a direct batch. Both fences bind `$LEDGER` since issue #686,
        # so the adapter is the whole of what separates them -- and there must
        # be exactly one fence of each shape, or this is choosing between two
        # and saying nothing about either.
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            with self.subTest(asset=relative_path):
                for mode, lines in MODE_HELPERS.items():
                    for line in lines:
                        self.assertIn(line, content, mode)
                binding = [
                    fence
                    for fence in asset_fences(relative_path)
                    if 'LEDGER="$SCRIPTS' in fence
                ]
                pr_fences = [fence for fence in binding if 'LIVENESS="$SCRIPTS' in fence]
                direct_fences = [
                    fence for fence in binding if 'LIVENESS="$SCRIPTS' not in fence
                ]
                self.assertEqual(len(pr_fences), 1, binding)
                self.assertEqual(len(direct_fences), 1, binding)
                self.assertNotIn("LIVENESS", direct_fences[0])

    def test_an_unresolvable_helper_stops_before_the_first_read(self):
        phrase = (
            "Do not substitute a copy tracked in the reviewed "
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

    def test_a_direct_request_skips_the_pr_only_prelude(self):
        # Round 7's blocker: the ledger read and migration sat unconditionally
        # ahead of the direct section, so an explicit direct request in a
        # repository with no ledger would create one, and an unresolvable
        # ledger module would block a mode that never uses it.
        for relative_path, brand in BRAND_OF_ASSET.items():
            content = flat(read(relative_path))
            for name, phrase in MODE_DISPATCH.items():
                with self.subTest(asset=relative_path, rule=name):
                    self.assertIn(flat(rendered_phrase(phrase, brand)), content)
            with self.subTest(asset=relative_path, rule="dispatch comes first"):
                body = read(relative_path)
                self.assertLess(
                    body.index("## Which mode this invocation is"),
                    body.index(LEDGER_INVOCATIONS[0]),
                )

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
            # PR mode's half of the document only: direct mode names the same
            # `read` once more, as its own compaction-recovery instruction,
            # and counting that one here would make the ordering below depend
            # on a section neither read is in.
            content, _ = sections_of(read(relative_path))
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
        for relative_path, brand in BRAND_OF_ASSET.items():
            content = read(relative_path)
            flattened = flat(content)
            for command in CLEANUP_COMMANDS:
                with self.subTest(asset=relative_path, command=command):
                    self.assertIn(command, content)
            for name, phrase in CLEANUP.items():
                with self.subTest(asset=relative_path, rule=name):
                    self.assertIn(flat(rendered_phrase(phrase, brand)), flattened)

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
    """Requirement 7 (#684) and requirement 6 (#686): one explicit-only section."""

    def test_the_direct_section_is_explicit_only(self):
        for relative_path in RENDERED_ASSETS:
            _, direct = sections_of(read(relative_path))
            flattened = flat(direct)
            for name, phrase in EXPLICIT_DIRECT_MODE.items():
                with self.subTest(asset=relative_path, rule=name):
                    self.assertIn(flat(phrase), flattened)

    def test_every_direct_invocation_lives_in_the_direct_section(self):
        for relative_path in RENDERED_ASSETS:
            pr_mode, direct = sections_of(read(relative_path))
            for invocation in DIRECT_INVOCATIONS:
                with self.subTest(asset=relative_path, invocation=invocation):
                    self.assertIn(invocation, direct)
                    self.assertNotIn(invocation, pr_mode)

    def test_pr_mode_names_no_direct_invocation(self):
        # The negative control for every direct pin above. Both modes now call
        # `$LEDGER`, so a document whose PR sweep had drifted into
        # `direct-select` would still name the ledger everywhere the pins look.
        # It cannot pass this one: the two direct subcommands appear below the
        # heading and nowhere above it, which the test above asserts, and PR
        # mode's own four appear above it and nowhere below.
        for relative_path in RENDERED_ASSETS:
            pr_mode, direct = sections_of(read(relative_path))
            for spelling in REFUSED_DIRECT_INVOCATIONS:
                with self.subTest(asset=relative_path, spelling=spelling):
                    self.assertIn(spelling, pr_mode)
                    self.assertNotIn(spelling, direct)

    def test_the_direct_section_names_no_liveness_adapter(self):
        # Direct mode takes no claim, so it starts no keeper and calls the
        # adapter nowhere. Its own resolution fence sits above this section
        # with PR mode's, where
        # `test_each_mode_resolves_and_checks_only_the_modules_it_calls` pins
        # that it binds `$LEDGER` and not `$LIVENESS`; what this pins is the
        # other half -- that nothing below the heading reaches for the adapter
        # either, which is what makes the fence's omission true of the mode
        # rather than only of the fence.
        for relative_path in RENDERED_ASSETS:
            _, direct = sections_of(read(relative_path))
            with self.subTest(asset=relative_path):
                self.assertIn('python3 "$LEDGER" direct-select', direct)
            for spelling in REFUSED_DIRECT_HELPERS:
                with self.subTest(asset=relative_path, spelling=spelling):
                    self.assertNotIn(spelling, direct)

    def test_no_asset_names_the_retired_cursor_module(self):
        # Issue #686 requirement 7 as an absence over the whole body, not only
        # over the direct section: the module is gone from both bundles, so an
        # asset still resolving it would resolve nothing and stop the mode it
        # was resolved for.
        for relative_path in (*RENDERED_ASSETS, SOURCE):
            with self.subTest(asset=relative_path):
                self.assertNotIn("project_review_cursor", read(relative_path))

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

    def test_the_retired_cursor_module_ships_in_neither_bundle(self):
        # Issue #686 requirement 7. The module is not merely unreferenced: it
        # is gone, so a bundle that still carried it would install a second
        # answer to what a repository's direct progress is.
        for bundle in BUNDLED_HELPERS["ledger"].values():
            retired = (REPO_ROOT / bundle).parent / "project_review_cursor.py"
            with self.subTest(bundle=bundle):
                self.assertFalse(retired.exists(), retired)

    def test_the_ledger_helper_spawns_only_git(self):
        # Its whole repository reach: the common directory, the lock
        # reference, and the checkpoint commit. Pinned here as the one
        # executable it names, because a helper that reached for `gh` would be
        # making a network call the caller never told it about, and one that
        # reached for anything else would need declaring in
        # docs/agent-workflow-contract.md.
        source = (REPO_ROOT / CLAUDE_LEDGER_HELPER).read_text(encoding="utf-8")
        self.assertIn("subprocess", source)
        for forbidden in ("os.system", "os.popen", '"gh"', "'gh'"):
            with self.subTest(spelling=forbidden):
                self.assertNotIn(forbidden, source)


REPO = "coghex/kanban"

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
# A silence window no observation in this module can outrun. The fixture's
# ordinary window is a second and a half, which is shorter than registering a
# successor takes on a loaded runner: a test whose subject is an attempt that
# is still *active* has to register with this instead, or the attempt ends on
# silence and is reclaimed for a reason the test was not written about.
E2E_LONG_SILENCE = 600.0
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
        "version": "2.1.274 (Claude Code)",
        "invocation_field": "prompt_id",
        "terminal_event": "Stop",
    },
    "codex": {
        "asset": CODEX_ASSET,
        "bundle_root": "codex-plugin/plugins/kanban",
        "ledger": "skills/project-review/scripts/project_review_ledger.py",
        "liveness": "skills/project-review/scripts/project_review_liveness.py",
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


# The header the retired `project_review_cursor.py` wrote above its payload.
# Reproduced verbatim rather than paraphrased: the parser anchors on the marker
# and not on this, so a fixture whose prose drifted would still parse -- and a
# fixture that parsed for the wrong reason proves nothing about the documents
# real consumers hold.
V2_CURSOR_HEADER = """# Project review sweep cursor

Machine-owned state for the `project-review` workflow: each repository's
exclusive older PR boundary, the units completed batches reviewed, the direct
history endpoint, and the units a user explicitly excluded. PR selection always
starts at the latest merge and stops before its boundary; a clean batch records
reviewed coverage exactly as a finding-bearing batch does.

Written by `project_review_cursor.py`. Edit it through that helper rather than
by hand: the payload below is parsed strictly, and an edit it cannot read stops
the next sweep instead of being ignored.
"""


def v2_cursor_state(reviewed=(), direct_reviewed=(), direct_frontier=None) -> dict:
    return {
        "pr": {"endpoint": None, "reviewed": sorted(set(reviewed))},
        "direct": {
            "endpoint": None if direct_frontier is None else {"sha": direct_frontier},
            "reviewed": sorted(set(direct_reviewed)),
        },
        "excluded": {"prs": [], "commits": []},
    }


def render_v2_cursor(module, repo, **state) -> str:
    """One repository's v2 cursor document, as its retired writer rendered it.

    The writer is gone, so this is the only way to produce one -- and it is a
    fixture that owes a proof, which
    `CursorFixtureTests.test_the_fixture_round_trips_through_the_surviving_parser`
    supplies against the parser the ledger module carries.
    """
    payload = json.dumps(
        {"version": 2, "repositories": {repo: v2_cursor_state(**state)}},
        indent=2,
        sort_keys=True,
    )
    return f"{V2_CURSOR_HEADER}\n{module.CURSOR_MARKER}\n\n```json\n{payload}\n```\n"


class CursorFixtureTests(unittest.TestCase):
    """The retired document's fixture, checked against what still reads it."""

    def test_the_fixture_round_trips_through_the_surviving_parser(self):
        module = e2e_module("ledger", "claude")
        rendered = render_v2_cursor(
            module,
            E2E_REPO,
            reviewed=(612, 610),
            direct_reviewed=("ed90877ac1", "6d54e98bb2"),
            direct_frontier="6d54e98bb2",
        )
        parsed = module.cursor_state_for(
            module.parse_cursor_document(rendered, "fixture"), E2E_REPO
        )
        self.assertEqual(
            parsed,
            v2_cursor_state(
                reviewed=(612, 610),
                direct_reviewed=("ed90877ac1", "6d54e98bb2"),
                direct_frontier="6d54e98bb2",
            ),
        )

    def test_a_document_without_the_marker_is_not_read_as_an_absent_one(self):
        # The negative control: the round trip above would pass just as well
        # against a parser that accepted anything, and a cursor read as absent
        # is a consumer's coverage silently discarded.
        module = e2e_module("ledger", "claude")
        rendered = render_v2_cursor(module, E2E_REPO, reviewed=(612,))
        with self.assertRaises(module.LedgerError):
            module.parse_cursor_document(
                rendered.replace(module.CURSOR_MARKER, "<!-- not-a-cursor -->"),
                "fixture",
            )


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
            self.bundle = self.codex_home / "plugins" / "cache" / "kanban" / "kanban" / "1.56.0"
        else:
            self.bundle = base / "claude-plugins" / "kanban" / "1.57.0"
        source_root = REPO_ROOT / self.spec["bundle_root"]
        for relative in (
            self.spec["ledger"],
            self.spec["liveness"],
            "hooks/hooks.json",
        ):
            target = self.bundle / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((source_root / relative).read_bytes())
        self.ledger_path = self.bundle / self.spec["ledger"]
        self.liveness_path = self.bundle / self.spec["liveness"]

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
            # `$SCRIPTS` is what both locator fences bind: the directory the
            # two modules share, which each mode's own fence resolves its
            # own modules against.
            SCRIPTS=str(self.ledger_path.parent),
            LEDGER=str(self.ledger_path),
            LIVENESS=str(self.liveness_path),
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

    def write_cursor(self, reviewed, direct_reviewed=(), direct_frontier=None):
        """The v2 cursor a consumer holds, in the retired writer's own shape.

        Rendered here because the module that wrote it left both bundles in
        issue #686 and nothing produces one any more. The half of the
        mechanism that survives is the parser the ledger carries, and
        `test_the_cursor_fixture_is_what_the_surviving_parser_reads` proves
        this rendering round-trips through it -- so the fixture is still
        checked against a mechanism rather than against itself.
        """
        module = e2e_module("ledger", self.brand)
        path = Path(self.docs) / module.CURSOR_RELATIVE_PATH
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            render_v2_cursor(
                module,
                E2E_REPO,
                reviewed=reviewed,
                direct_reviewed=direct_reviewed,
                direct_frontier=direct_frontier,
            ),
            encoding="utf-8",
        )

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
        # No `worktree prune`: it is repository-wide, and `worktree remove`
        # above already cleared the record of each worktree it removed. The
        # asset refuses the global form for the same reason this driver does.
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
        """The direct section's walk piped into `direct-select` or `direct-record`.

        Both are the same `git log --first-parent` line with a different
        subcommand on the other side of the pipe, so they are told apart by
        that -- and a record that stopped being handed the walk stops working
        here.
        """
        commands = [
            command
            for command in asset_commands_starting(
                self.asset, 'git -C "$ROOT" log --first-parent'
            )
            if f'"$LEDGER" {subcommand} ' in command
        ]
        self.case.assertEqual(len(commands), 1, commands)
        return commands[0]

    def direct_select(self, count, entry="", start="", end="", check=True):
        """The direct section's own selection, run as it spells it.

        An empty `$ENTRY` is no entry commit, which is what every batch after
        the first passes; the first batch of a repository with no merged pull
        requests reaches the helper's `--entry-none` path instead, which the
        asset spells in its own prose rather than in this fence.
        """
        completed = self.sh(
            self.direct_walk("direct-select"),
            check=check,
            COUNT=str(count),
            RANGE_START=start,
            RANGE_END=end,
            ENTRY=entry,
        )
        return json.loads(completed.stdout) if check else completed

    def direct_record(self, shas, report="", excluded=""):
        """The direct section's own recording, run as it spells it."""
        completed = self.sh(
            self.direct_walk("direct-record"),
            REVIEWED=",".join(shas),
            EXCLUDED=excluded,
            REPORT=report,
        )
        return json.loads(completed.stdout)

    def last_progress_at(self, attempt):
        """The `at` the adapter's own progress record carries."""
        record = json.loads(
            (
                self.common_directory()
                / "kanban-project-review"
                / "liveness"
                / "attempts"
                / attempt
                / "progress.json"
            ).read_text(encoding="utf-8")
        )
        return float(record["at"])

    def heartbeat_renewals(self, token):
        module = e2e_module("ledger", self.brand)
        record = module.read_heartbeat(module.git_common_directory(self.docs), token)
        return None if record is None else record["renewals"]

    # -- the pinned review tree

    def common_directory(self):
        return Path(
            e2e_git(
                self.root, "rev-parse", "--path-format=absolute", "--git-common-dir"
            ).strip()
        )

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
    """The asset's own resolution fences, run with nothing pre-bound."""

    def resolve(self, fences, report, missing=(), unset=("SCRIPTS", "LEDGER", "LIVENESS")):
        """Run `fences` as one script and report the named variables.

        `unset` is what makes this a test of the asset rather than of the
        fixture: every variable the fences are meant to bind is removed from
        the environment first, so a fence that stopped binding one fails here
        instead of reading the value the harness left behind.
        """
        for name in missing:
            (self.workflow.bundle / BRAND_BUNDLES[self.BRAND][name]).unlink()
        environment = dict(self.workflow.env)
        for name in unset:
            environment.pop(name, None)
        # The fences' own last status is captured before the report runs and
        # restored after it. `set -e` cannot do this: a failing left-hand side
        # of an `&&` list is exempt from it, which is precisely the shape
        # every one of these checks has, and a trailing report would otherwise
        # turn a refusal into a pass.
        script = "\n".join(
            list(fences) + ["__status=$?", report, 'exit "$__status"']
        )
        return subprocess.run(
            ["sh", "-c", script],
            capture_output=True, text=True, env=environment,
            cwd=str(self.workflow.root), timeout=120,
        )

    def locator(self):
        """The fence that finds the directory the two modules share."""
        return next(
            fence
            for fence in asset_fences(self.workflow.asset)
            if 'SCRIPTS=' in fence
        )

    def mode_fence(self, mode):
        """One mode's own resolution fence.

        Both fences bind `$LEDGER` since issue #686, so the adapter is what
        tells them apart: PR mode resolves it and direct mode must not, which
        is the whole of the separation that survives. Exactly one fence of
        each shape has to exist, or the selection below would be choosing
        between two and saying nothing about either.
        """
        fences = [
            fence
            for fence in asset_fences(self.workflow.asset)
            if 'LEDGER="$SCRIPTS' in fence
            and (('LIVENESS="$SCRIPTS' in fence) == (mode == "pr"))
        ]
        self.assertEqual(len(fences), 1, fences)
        return fences[0]

    def test_the_assets_own_lookup_finds_this_brands_installed_bundle(self):
        # The locator plus PR mode's own fence: the two a review runs, and the
        # only two, so what they bind is what a review has.
        completed = self.resolve(
            [self.locator(), self.mode_fence("pr")],
            'printf "%s\\n%s\\n" "$LEDGER" "$LIVENESS"',
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(
            [Path(line) for line in completed.stdout.split()],
            [self.workflow.ledger_path, self.workflow.liveness_path],
        )

    def test_the_direct_fence_resolves_the_ledger_with_the_adapter_deleted(self):
        # Round 8's blocker, carried across issue #686. Direct mode takes no
        # claim, so it starts no keeper and calls the adapter nowhere -- and a
        # bundle whose adapter is missing has to serve a direct batch. The
        # adapter is removed from the installed bundle first, and then direct
        # mode's own resolution is run unbound.
        completed = self.resolve(
            [self.locator(), self.mode_fence("direct")],
            'printf "%s\\n" "$LEDGER"',
            missing=("liveness",),
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(
            Path(completed.stdout.strip()), self.workflow.ledger_path
        )

    def test_each_mode_fence_refuses_when_the_ledger_module_is_missing(self):
        # Non-vacuity for the two above: the fences do fail, and both fail on
        # the module both modes genuinely need. A fence that simply checked
        # nothing would pass every case above and this one too. The module is
        # removed once and both fences are then run against the same bundle,
        # so neither result depends on the order the subtests ran in.
        (self.workflow.bundle / BRAND_BUNDLES[self.BRAND]["ledger"]).unlink()
        for mode in ("pr", "direct"):
            with self.subTest(mode=mode):
                completed = self.resolve(
                    [self.locator(), self.mode_fence(mode)], "true"
                )
                self.assertNotEqual(completed.returncode, 0, completed.stdout)

    def test_the_pr_fence_refuses_when_only_the_adapter_is_missing(self):
        # The separation from the other side: the same deletion that leaves
        # direct mode working stops a review, so the direct case above is a
        # property of that fence rather than of a bundle that was complete.
        completed = self.resolve(
            [self.locator(), self.mode_fence("pr")],
            "true",
            missing=("liveness",),
        )
        self.assertNotEqual(completed.returncode, 0, completed.stdout)


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

    def test_an_empty_inventory_stops_before_anything_is_registered(self):
        # Round 7's blocker. The asset stops at step 1 for a repository that
        # has merged nothing, so the route this drives registers nothing and
        # claims nothing -- and what is asserted is that no keeper, no adapter
        # record and no directory came into being.
        self.workflow.merged([])
        self.assertEqual(
            self.workflow.inventory(), [{"page": 1, "limit": 100, "prs": []}]
        )
        self.assertFalse(self.workflow.runtime_worktrees().exists())
        liveness = (
            self.workflow.common_directory() / "kanban-project-review" / "liveness"
        )
        self.assertFalse((liveness / "attempts").exists())
        self.assertEqual(self.workflow.rows(), {})

    def test_an_empty_listing_would_select_nothing_if_it_reached_the_claim(self):
        # The helper's own answer to the listing the step above refuses to
        # carry further, so the stop is a shortcut rather than the only thing
        # standing between an empty repository and a claim.
        self.workflow.merged([])
        parsed = self.module.parse_inventory(
            {"pages": self.workflow.inventory()}, "an empty listing"
        )
        self.assertEqual(parsed["listed"], [])
        registration, inventory = self.workflow.registered_inventory()
        result = self.workflow.claim(inventory, registration["keeper_pid"])
        self.assertEqual(result["status"], "no-selectable-row")
        self.assertIsNone(result["selected"])
        self.assertEqual(self.workflow.rows(), {})
        self.workflow.complete_attempt(registration["attempt"])

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
        # is exactly why the asset assumes neither, and reports a record that
        # did survive as the janitor's rather than clearing it with a
        # repository-wide prune.
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

    def cancel_after(self, stage, terminate=True, silence=E2E_SILENCE):
        """Register, claim, create `stage`'s resources, then end the session.

        No cleanup step of the cancelled invocation's runs -- which is the
        whole case: what has to happen afterwards has to happen without one.

        `silence` is the registered attempt's own window: a case that ends the
        session takes the short one, and a case whose subject is an attempt
        still active takes `E2E_LONG_SILENCE`, so nothing ends it but the test.
        """
        registration, inventory = self.workflow.registered_inventory(
            session="session-a", invocation="invocation-1", silence=silence
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

    def kill_wrapped(self, process):
        """End a wrapper and the command it started, and wait for both.

        The group is named by the wrapper's own pid, which `start_new_session`
        makes its leader: `getpgid` of a wrapper already reaped raises, and a
        wrapper killed on its own leaves its command running -- which is a
        launch still reported unfinished, correctly, and not a test that has
        cleaned up after itself.
        """
        with contextlib.suppress(OSError):
            os.killpg(process.pid, signal.SIGKILL)
        if process.poll() is None:
            with contextlib.suppress(OSError):
                process.kill()
        process.wait(timeout=E2E_SETTLE)

    def start_survivor(self, registration, label="build", tool_use_id="tool-bg"):
        """A wrapped command of `registration`'s attempt that outlives it.

        Backgrounded, in the sense that matters here: its tool call is
        reported finished at once, which is the survivor `exempt_launches`
        cannot name and `unfinished_launches` can.
        """
        command = (
            f'python3 {self.workflow.liveness_path} run --root {self.workflow.docs} '
            f'--attempt {registration["attempt"]} --launch {label} -- make test'
        )
        self.workflow.hook(
            "PreToolUse",
            session="session-a",
            invocation="invocation-1",
            command=command,
            tool_use_id=tool_use_id,
        )
        child = subprocess.Popen(
            [
                sys.executable, str(self.workflow.liveness_path), "run",
                "--root", str(self.workflow.docs),
                "--attempt", registration["attempt"], "--launch", label, "--",
                sys.executable, "-c", "import time; time.sleep(600)",
            ],
            env=self.workflow.env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        self.workflow.pids.append(child.pid)
        self.addCleanup(lambda: self.kill_wrapped(child))
        self.workflow.hook(
            "PostToolUse",
            session="session-a",
            invocation="invocation-1",
            command=command,
            tool_use_id=tool_use_id,
        )
        e2e_wait(
            lambda: label
            in (self.workflow.attempt_status(registration["attempt"]) or {}).get(
                "unfinished_launches", []
            ),
            "the survivor was never reported unfinished",
        )
        return child

    def start_wrapped(self, registration, label, tool_use_id):
        """One wrapped launch, announced to the hook and left running.

        Returns the process and the path its standard error was written to.
        A file rather than a pipe: the wrapper's own child inherits the
        descriptor and outlives a `kill` of the wrapper, so a pipe never
        reaches end of file and reading one would hang.
        """
        command = (
            f'python3 {self.workflow.liveness_path} run --root {self.workflow.docs} '
            f'--attempt {registration["attempt"]} --launch {label} -- make test'
        )
        self.workflow.hook(
            "PreToolUse",
            session="session-a",
            invocation="invocation-1",
            command=command,
            tool_use_id=tool_use_id,
        )
        errors = self.workflow.scratch / f"wrapper-{label}-{tool_use_id}.err"
        handle = errors.open("wb")
        self.addCleanup(handle.close)
        child = subprocess.Popen(
            [
                sys.executable, str(self.workflow.liveness_path), "run",
                "--root", str(self.workflow.docs),
                "--attempt", registration["attempt"], "--launch", label, "--",
                sys.executable, "-c", "import time; time.sleep(600)",
            ],
            env=self.workflow.env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=handle,
            start_new_session=True,
        )
        self.workflow.pids.append(child.pid)
        self.addCleanup(lambda: self.kill_wrapped(child))
        return child, errors

    def test_a_reused_launch_label_earns_no_exemption_and_a_fresh_one_does(self):
        # Round 9's blocker, as the workflow answers it. The adapter gives the
        # exemption to the first wrapper that claims a label and reports the
        # second rather than refusing it, so a review that reused `build` for
        # its second long command would run that command with nothing holding
        # the keeper alive. The asset's rule is that every launch takes a
        # label of its own; this is what that rule is worth, sequentially, and
        # what happens without it.
        registration, _, attempt_dir, _, review_wt = self.cancel_after(
            "pinned", terminate=False, silence=E2E_LONG_SILENCE
        )
        attempt = registration["attempt"]
        first, _ = self.start_wrapped(registration, "build", "tool-1")
        e2e_wait(
            lambda: self.workflow.attempt_status(attempt)["exempt_launches"]
            == ["build"],
            "the first wrapped launch was never exempt",
        )

        # The same label again: the command runs, the exemption does not, and
        # the adapter says so on standard error.
        second, reported = self.start_wrapped(registration, "build", "tool-2")
        e2e_wait(
            lambda: self.workflow.attempt_status(attempt)["exempt_launches"] == [],
            "a reused label kept the first launch's exemption",
        )
        self.assertIsNone(second.poll())
        e2e_wait(
            lambda: "is not exempt from the silence window"
            in reported.read_text(encoding="utf-8"),
            "the adapter never reported the reused label",
        )
        self.assertIn("reused label", reported.read_text(encoding="utf-8"))
        self.kill_wrapped(second)
        # Cleanup still sees it, which is the half that keeps the directory
        # safe: both wrappers report under the launch's own label.
        self.assertEqual(
            self.workflow.attempt_status(attempt)["unfinished_launches"], ["build"]
        )

        # A label nothing has used -- what the asset requires -- is exempt.
        third, _ = self.start_wrapped(registration, "test-suite", "tool-3")
        e2e_wait(
            lambda: self.workflow.attempt_status(attempt)["exempt_launches"]
            == ["test-suite"],
            "a fresh label earned no exemption either",
        )
        self.assertIsNone(third.poll())
        self.kill_wrapped(first)
        self.kill_wrapped(third)

    def registered_worktrees(self):
        """Every worktree path Git has an administrative record for."""
        listing = e2e_git(self.workflow.root, "worktree", "list", "--porcelain")
        return [
            line.split(" ", 1)[1]
            for line in listing.splitlines()
            if line.startswith("worktree ")
        ]

    def test_reclamation_leaves_an_unrelated_stale_worktree_record_alone(self):
        # Round 10's blocker. The pass used to end with a repository-wide
        # `worktree prune`, which clears the record of every worktree of this
        # repository whose directory is missing -- a person's interrupted
        # checkout, another agent's, anything this invocation knows nothing
        # about. Cleanup is attempt-scoped, so a record this pass did not
        # create has to be exactly where it was afterwards.
        stranger = self.workflow.base / "someone-elses-worktree"
        e2e_git(
            self.workflow.root, "worktree", "add", "--detach", "-q", str(stranger)
        )
        shutil.rmtree(stranger)
        stale = [
            path
            for path in self.registered_worktrees()
            if path.endswith("someone-elses-worktree")
        ]
        self.assertEqual(len(stale), 1, self.registered_worktrees())
        self.assertFalse(Path(stale[0]).exists(), "the record is not stale")

        registration, claimed, attempt_dir, _, review_wt = self.cancel_after("pinned")
        successor = self.assert_cancellation_completes_without_a_tool_call(
            registration, claimed
        )
        self.assertEqual(
            self.workflow.reclaim_orphans(keep=successor["attempt"]),
            [registration["attempt"]],
        )
        # The attempt's own record went with the worktree `remove` took, which
        # is the only record-clearing this pass does.
        self.assertFalse(attempt_dir.exists())
        after = self.registered_worktrees()
        self.assertNotIn(str(review_wt), after)
        self.assertIn(stale[0], after)
        self.workflow.complete_attempt(successor["attempt"])

    def test_an_unreadable_launch_record_retains_the_directory(self):
        # Requirement 5's fail-closed rule, through the record rather than the
        # process. A wrapper record this process cannot parse is a launch it
        # cannot place, which is not the same as one that has ended -- so the
        # pass may not delete the worktree on the strength of it.
        registration, _, attempt_dir, _, review_wt = self.cancel_after("pinned")
        e2e_wait(
            lambda: not self.workflow.running(registration["keeper_pid"]),
            "the keeper outlived the session",
        )
        launches = (
            self.workflow.common_directory()
            / "kanban-project-review"
            / "liveness"
            / "attempts"
            / registration["attempt"]
            / "launches"
        )
        launches.mkdir(parents=True, exist_ok=True)
        (launches / "build.wrapper.json").write_text("{ not json", encoding="utf-8")
        self.assertEqual(
            self.workflow.attempt_status(registration["attempt"])[
                "unfinished_launches"
            ],
            ["build"],
        )
        # Every other signal says take it: the attempt is over and the keeper
        # is gone. The unreadable record alone is what retains it.
        self.assertTrue(self.workflow.attempt_is_over(registration["attempt"]))
        successor = self.workflow.register(session="session-b", invocation="invocation-2")
        self.assertEqual(self.workflow.reclaim_orphans(keep=successor["attempt"]), [])
        self.assertEqual(
            self.workflow.retained_orphans,
            [(registration["attempt"], "launches:build")],
        )
        self.assertTrue(review_wt.is_dir())
        self.assertTrue(attempt_dir.is_dir())
        self.workflow.complete_attempt(successor["attempt"])

    def test_a_survivor_whose_attempt_records_were_pruned_retains_the_directory(self):
        # The two fail-closed reasons at once, which is the combination that
        # matters most: the command is still running *and* the adapter can no
        # longer be asked about it, because a pruned attempt takes its launch
        # records with it. Reclaiming on `attempt-unknown` alone would delete
        # the worktree this process is working in.
        registration, _, attempt_dir, _, review_wt = self.cancel_after("pinned")
        child = self.start_survivor(registration)
        e2e_wait(
            lambda: not self.workflow.running(registration["keeper_pid"]),
            "the keeper outlived the session",
        )
        records = (
            self.workflow.common_directory()
            / "kanban-project-review"
            / "liveness"
            / "attempts"
            / registration["attempt"]
        )
        shutil.rmtree(records)
        self.assertIsNone(self.workflow.attempt_status(registration["attempt"]))
        self.assertEqual(
            self.workflow.reclaim_refusal(registration["attempt"]), "attempt-unknown"
        )
        successor = self.workflow.register(session="session-b", invocation="invocation-2")
        self.assertEqual(self.workflow.reclaim_orphans(keep=successor["attempt"]), [])
        self.assertEqual(
            self.workflow.retained_orphans,
            [(registration["attempt"], "attempt-unknown")],
        )
        # Retained by path, with its worktree, while the command that made it
        # unsafe is still running in it.
        self.assertTrue(review_wt.is_dir())
        self.assertTrue(attempt_dir.is_dir())
        self.assertIsNone(child.poll())
        self.workflow.complete_attempt(successor["attempt"])

    def test_a_survivor_keeps_its_directory_until_it_exits(self):
        # Round 5's blocker, answered through the interface it asked for. A
        # wrapped command that outlives a cancelled attempt is the one thing
        # that must stop the reclaim pass: deleting the worktree it is working
        # in is what nothing later repairs. The command here is backgrounded --
        # its tool call finishes at once -- which is exactly the survivor
        # `exempt_launches` cannot name and `unfinished_launches` can.
        registration, claimed, attempt_dir, _, review_wt = self.cancel_after("pinned")
        child = self.start_survivor(registration)
        self.assertEqual(
            self.workflow.attempt_status(registration["attempt"])[
                "unfinished_launches"
            ],
            ["build"],
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

        # Killing the *wrapper* is not the command ending: SIGKILL runs no
        # forwarding handler, so the command outlives it and the launch is
        # still reported. Round 11's blocker, as a regression.
        child.kill()
        child.wait(timeout=E2E_SETTLE)
        self.assertEqual(
            self.workflow.attempt_status(registration["attempt"])[
                "unfinished_launches"
            ],
            ["build"],
        )
        self.assertEqual(self.workflow.reclaim_orphans(keep=successor["attempt"]), [])
        self.assertTrue(review_wt.is_dir())

        # Once the command itself exits, the same pass takes it.
        self.kill_wrapped(child)
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

    def test_an_unverifiable_keeper_retains_the_directory(self):
        # Round 7's fail-closed case. A wrapper or keeper this process cannot
        # look up -- another host, or a pid it may not signal -- is
        # `unverifiable`, which is not `gone`. Reclaiming on it would delete a
        # checkout on the strength of not being able to see its owner.
        registration, _, attempt_dir, _, review_wt = self.cancel_after(
            "pinned", terminate=False, silence=E2E_LONG_SILENCE
        )
        # Rewrite the keeper's host so this process cannot resolve its standing.
        attempt_json = (
            self.workflow.common_directory()
            / "kanban-project-review"
            / "liveness"
            / "attempts"
            / registration["attempt"]
            / "attempt.json"
        )
        record = json.loads(attempt_json.read_text(encoding="utf-8"))
        record["keeper"]["host"] = "another-host.invalid"
        attempt_json.write_text(json.dumps(record), encoding="utf-8")

        status = self.workflow.attempt_status(registration["attempt"])
        self.assertEqual(status["status"], "active")
        self.assertEqual(status["keeper_standing"], "unverifiable")
        self.assertEqual(
            self.workflow.reclaim_refusal(registration["attempt"]),
            "keeper-unverifiable",
        )
        successor = self.workflow.register(session="session-b", invocation="invocation-2")
        self.assertEqual(self.workflow.reclaim_orphans(keep=successor["attempt"]), [])
        self.assertEqual(
            self.workflow.retained_orphans,
            [(registration["attempt"], "keeper-unverifiable")],
        )
        self.assertTrue(review_wt.is_dir())
        self.workflow.complete_attempt(successor["attempt"])

    def test_an_attempt_the_adapter_no_longer_knows_retains_its_directory(self):
        # The pruned-record case: registration removes an ended attempt's
        # liveness records after seven days, and the directory outlives them.
        # `status` then refuses, so nothing can establish that the attempt's
        # commands exited -- and the pass must not guess.
        registration, _, attempt_dir, _, review_wt = self.cancel_after("pinned")
        e2e_wait(
            lambda: not self.workflow.running(registration["keeper_pid"]),
            "the keeper outlived the session",
        )
        records = (
            self.workflow.common_directory()
            / "kanban-project-review"
            / "liveness"
            / "attempts"
            / registration["attempt"]
        )
        shutil.rmtree(records)
        self.assertIsNone(self.workflow.attempt_status(registration["attempt"]))
        self.assertEqual(
            self.workflow.reclaim_refusal(registration["attempt"]), "attempt-unknown"
        )
        successor = self.workflow.register(session="session-b", invocation="invocation-2")
        self.assertEqual(self.workflow.reclaim_orphans(keep=successor["attempt"]), [])
        self.assertEqual(
            self.workflow.retained_orphans,
            [(registration["attempt"], "attempt-unknown")],
        )
        self.assertTrue(review_wt.is_dir())
        self.workflow.complete_attempt(successor["attempt"])

    def test_a_killed_keeper_leaves_an_attempt_that_still_reads_active(self):
        # The other half: a keeper killed outright writes no ended record, so
        # its attempt reads `active` forever. Reading that alone as "still
        # running" strands the directory, which is why the asset's rule looks
        # at the keeper's standing too.
        registration, claimed, attempt_dir, _, review_wt = self.cancel_after(
            "pinned", terminate=False, silence=E2E_LONG_SILENCE
        )
        # The long window again: this attempt has to still be active when the
        # kill lands, or it ends on silence, writes an ended record, and stops
        # being the case this test is about.
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
    """Requirement 7 (#684) and #686: a direct batch takes no claim and no row."""

    def setUp(self):
        super().setUp()
        self.workflow.merged([(612, "2026-09-01T00:00:00Z")])
        history = self.workflow.first_parent_history(7)
        # The one merged pull request's own commit sits at the head of the
        # walk and its direct history sits below it, which is how a repository
        # whose pull-request era began partway through actually looks. `$ENTRY`
        # is that commit -- what the workflow derives from the inventory -- and
        # the batch begins at the commit below it.
        self.entry = history[0]
        self.shas = history[1:]

    def migrated(self):
        """The empty ledger every direct batch resumes from.

        Direct mode reads the ledger and refuses to establish one, so the
        migration runs first here exactly as the asset says it does -- in PR
        mode, once. What it writes for this repository is an empty ledger with
        an empty frontier, which is the state a first direct batch positions
        itself in.
        """
        self.workflow.migrate()

    def report_for(self, shas):
        """Write the report the helper named, and return its path."""
        selected = self.workflow.direct_select(count=len(shas), entry=self.entry)
        report = selected["batch"]["report"]
        self.assertEqual(
            report,
            f"docs/project_review/direct_{shas[0][:7]}-{shas[-1][:7]}.md",
        )
        target = self.workflow.docs / report
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(
            f"# Project Review Findings: direct commits {shas[0]}\u2013{shas[-1]}\n",
            encoding="utf-8",
        )
        return report

    def test_a_direct_request_needs_no_liveness_adapter_and_starts_no_keeper(self):
        # Round 7's blocker carried across issue #686. Direct mode now shares
        # the ledger, so the adapter is what it must still not need: it is
        # removed from the installed bundle entirely, and the whole direct
        # route then runs against a repository whose ledger holds no row.
        self.migrated()
        (self.workflow.bundle / BRAND_BUNDLES[self.BRAND]["liveness"]).unlink()

        selected = self.workflow.direct_select(count=2, entry=self.entry)
        self.assertEqual(selected["batch"]["origin"], "inventory-entry")
        self.assertEqual(selected["batch"]["selected"], list(self.shas[:2]))
        report = self.report_for(self.shas[:2])
        recorded = self.workflow.direct_record(self.shas[:2], report=report)
        self.assertEqual(recorded["frontier"]["sha"], self.shas[1])

        # No attempt was registered, no keeper started, and no row or claim
        # exists -- which is the property a direct batch depends on.
        self.assertEqual(self.workflow.rows(), {})
        self.assertFalse(self.workflow.runtime_worktrees().exists())
        self.assertFalse(
            (
                self.workflow.common_directory()
                / "kanban-project-review"
                / "liveness"
            ).exists()
        )

    def test_a_direct_batch_checkpoints_the_ledger_and_creates_no_row(self):
        self.migrated()
        report = self.report_for(self.shas[:3])
        # An unrelated staged file, to prove the checkpoint is path-scoped
        # rather than a commit of whatever the worktree happened to hold.
        (self.workflow.docs / "unrelated.md").write_text("scratch\n", encoding="utf-8")
        e2e_git(self.workflow.docs, "add", "unrelated.md")

        recorded = self.workflow.direct_record(self.shas[:3], report=report)
        self.assertEqual(recorded["frontier"]["sha"], self.shas[2])
        self.assertEqual(
            recorded["checkpoint"]["paths"],
            sorted(["docs/project_review/ledger.md", report]),
        )
        committed = e2e_git(
            self.workflow.docs,
            "show",
            "--name-only",
            "--format=",
            recorded["checkpoint"]["commit"],
        ).split()
        self.assertEqual(sorted(committed), sorted(["docs/project_review/ledger.md", report]))
        self.assertEqual(self.workflow.rows(), {})

        # And the next batch resumes below the recorded frontier, with no
        # entry commit: `$ENTRY` is empty for every batch after the first.
        again = self.workflow.direct_select(count=2, entry="")
        self.assertEqual(again["batch"]["origin"], "recorded-frontier")
        self.assertEqual(again["batch"]["selected"], list(self.shas[3:5]))

    def test_a_direct_batch_refuses_a_repository_that_has_no_ledger(self):
        # The reason the migration above is not a formality: a direct batch
        # that established the first ledger would resume from an empty
        # frontier and re-review whatever the previous record covered.
        self.assertIsNone(self.workflow.ledger_bytes())
        refused = self.workflow.direct_select(count=2, entry=self.entry, check=False)
        self.assertEqual(refused.returncode, 2, refused.stdout)
        self.assertIn("Migrate", refused.stderr)
        self.assertEqual(refused.stdout, "")
        self.assertIsNone(self.workflow.ledger_bytes())


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
        # The tool call finishes -- and that finish is itself a progress event,
        # so it *refreshes* the silence window rather than ending it. Round 7's
        # blocker: the bound after a wrapped command is the command, then a
        # fresh window, then a poll, then the expiry. Asserted as a timing, not
        # just an eventual stop, because an eventual stop cannot tell the two
        # readings apart.
        child.kill()
        child.wait(timeout=E2E_SETTLE)
        self.workflow.hook("PostToolUse", command=command, tool_use_id=tool_use_id)
        # Measured from the timestamp the hook itself wrote, not from wall clock
        # after it: the window runs from that record, and the hook's own runtime
        # sits between the two.
        refreshed_at = self.workflow.last_progress_at(registration["attempt"])
        held = time.time() + 0.6 * E2E_SILENCE
        while time.time() < held:
            self.assertIsNotNone(
                self.workflow.heartbeat_renewals(token),
                "the finish event ended the window instead of refreshing it",
            )
            time.sleep(0.1)
        self.assert_renewal_stops(token, "renewal outlived the refreshed window")
        self.assertGreaterEqual(time.time() - refreshed_at, E2E_SILENCE)
        # Round 8's blocker: the bound runs past renewal's cessation. The
        # renewer follows the keeper rather than dying with it, so what makes
        # the row claimable again is the expiry of the last renewal it wrote,
        # and the proof of the whole chain is that a second invocation takes
        # the claim over -- not merely that the heartbeat went away.
        self.assertIsNone(self.workflow.heartbeat_renewals(token))
        successor, successor_inventory = self.workflow.registered_inventory(
            session="session-successor", invocation="invocation-successor"
        )
        def retake():
            # `claim` returns the parsed result once it succeeds and the
            # refused invocation itself until then, so the dict is the signal.
            result = self.workflow.claim(
                successor_inventory, successor["keeper_pid"], check=False
            )
            return result if isinstance(result, dict) else None

        taken = e2e_wait(
            retake,
            "the lapsed claim was never takeable",
            timeout=2 * E2E_SILENCE + 8 * E2E_EXPIRY,
            interval=0.2,
        )
        self.assertEqual(taken["status"], "claimed")
        self.assertEqual(taken["takeover"]["previous_token"], token)
        self.assertNotEqual(taken["claim"]["token"], token)

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


# ---------------------------------------------------------------------------
# Issue #685's automation proof (requirement 9), and the last of the end-to-end
# acceptance design D-19 lists: "automation counts completed records and stops
# correctly".
#
# The automation asset performs no step of its own -- design D-6 leaves the
# inventory, the registration, the claim, the pinned worktree, the report and
# the checkpoint in the single-review workflow -- so there is no helper of its
# own to drive here. What LEDGER-7 adds is a counting rule over what the
# delegate reports, and that is what `automate` below is: the loop the asset
# spells, run over whole delegated invocations made through the same
# asset-extracted helper lines every case above uses.
#
# Two things keep it a proof rather than a restatement. The counted outcome is
# the delegate's own `record` result, never a flag this driver sets -- so a
# `record` that stopped reporting `"status": "recorded"` breaks the count. And
# every case plans one more iteration than it expects to run, as a tripwire
# that raises if the loop reaches it: "stops after exactly N" and "never begins
# another after a refusal" are otherwise assertions about a number rather than
# about the loop.
#
# One ending gets a case of its own beyond requirement 9's four: the delegate
# checkpoints in step 8 and cleans up in step 9, so a removal that fails leaves
# a completed row behind an iteration that did not count. That is the second
# issue review's spec addition, and the case drives it the way `CleanupFailure`
# above drives the delegate's own half -- by making the removal fail for real.
# ---------------------------------------------------------------------------

AUTOMATION_ASSETS = {
    "claude": "claude-plugin/plugins/kanban/commands/auto-project-review.md",
    "codex": "codex-plugin/plugins/kanban/skills/auto-project-review/SKILL.md",
}

# What `automate` reports as the reason a run ended, in the automation asset's
# own terms. `count-reached` and `no-selectable-row` are its two ordinary ends;
# everything else is step 3's "did not record a review".
COUNT_REACHED = "count-reached"
NOTHING_SELECTABLE = "no-selectable-row"


class SerialAutomation(WorkflowRunCase):
    """The automation's counting rule, over real delegated invocations."""

    def setUp(self):
        super().setUp()
        self.workflow.merged(
            [
                (620, "2026-09-05T00:00:00Z"),
                (618, "2026-09-04T00:00:00Z"),
                (616, "2026-09-03T00:00:00Z"),
                (614, "2026-09-02T00:00:00Z"),
            ]
        )
        self.workflow.lease_defaults()
        self.sessions = 0

    # -- the loop

    def automate(self, count, plan):
        """`plan`'s iterations, counted the way the automation asset says.

        `count` is `None` for an open-ended run. The returned record is the
        progress report's own material: what was recorded, against what
        target, and why the run ended.
        """
        recorded, reason, index, result = [], None, 0, None
        while count is None or len(recorded) < count:
            self.assertLess(
                index, len(plan), "the loop asked for an iteration nobody planned"
            )
            result = plan[index]()
            index += 1
            # The one reading that decides the count, and it is the delegate's
            # own word for it rather than anything this driver knows.
            if result["status"] != "recorded":
                reason = result["status"]
                break
            recorded.append(result)
        else:
            reason = COUNT_REACHED
        return {
            "recorded": recorded,
            "reason": reason,
            "target": "open-ended" if count is None else count,
            "iterations": index,
            # The ending's own payload, kept because one of them -- a cleanup
            # that failed after `record` -- carries a completed review the
            # report has to disclose even though it never counted.
            "stopped_on": None if reason == COUNT_REACHED else result,
        }

    def tripwire(self):
        def fire():
            raise AssertionError("the loop began an iteration it should not have")

        return fire

    # -- the iterations

    def session(self):
        """A session and invocation id of this iteration's own.

        Registering twice under one session id ends the earlier keeper, which
        is the adapter's rule for a superseded registration and not what any
        case here is about.
        """
        self.sessions += 1
        return {
            "session": f"automation-session-{self.sessions}",
            "invocation": f"automation-invocation-{self.sessions}",
        }

    def recorded(self, outcome="clean", findings=None):
        """One delegated invocation that completes, reported as the
        automation reads it: entirely out of the delegate's `record` result."""
        def run():
            result = self.workflow.review_once(outcome=outcome, findings=findings)
            return {
                "status": result["status"],
                "pr": result["pr"],
                "outcome": result["outcome"],
                "commit": result["commit"],
                "report": result["report"],
                "repeats": result["repeats"],
            }

        return run

    def refused_by_a_failed_fetch(self):
        """One invocation that claims and then stops on step 4's fetch.

        A real refusal of the delegate's rather than a simulated one: the
        remote moves, its local tracking ref is locked, and the fetch the
        asset makes its own checked call fails. Step 9 then releases the
        claim, exactly as it does for any other early exit.
        """
        def run():
            registration, inventory = self.workflow.registered_inventory(
                **self.session()
            )
            claimed = self.workflow.claim(inventory, registration["keeper_pid"])
            self.assertEqual(claimed["status"], "claimed")
            self.workflow.advance_the_remote()
            self.workflow.lock_remote_tracking_ref()
            fetch = self.workflow.sh(
                asset_command(self.workflow.asset, 'git -C "$ROOT" fetch'), check=False
            )
            self.assertNotEqual(fetch.returncode, 0, fetch.stdout)
            # Step 9, in the order the asset states it: stop the keeper,
            # release the claim `record` never took, then the worktree that
            # was never created and the directory that was.
            self.workflow.complete_attempt(registration["attempt"])
            self.workflow.release(claimed["selected"]["number"], claimed["claim"]["token"])
            self.workflow.cleanup_worktree(inventory.parent / "tree")
            return {"status": "fetch-failed", "pr": claimed["selected"]["number"]}

        return run

    def interrupted(self):
        """One invocation whose session ends after the claim and before the
        record -- the ending requirement 9 names as uncounted."""
        def run():
            identity = self.session()
            registration, inventory = self.workflow.registered_inventory(**identity)
            claimed = self.workflow.claim(inventory, registration["keeper_pid"])
            self.assertEqual(claimed["status"], "claimed")
            self.workflow.hook("SessionEnd", **identity)
            e2e_wait(
                lambda: not self.workflow.running(registration["keeper_pid"]),
                "the keeper outlived the interrupted iteration",
            )
            return {"status": "interrupted", "pr": claimed["selected"]["number"]}

        return run

    def recorded_then_failed_cleanup(self):
        """One invocation that records a review and then cannot clean up.

        The only ending that leaves a real, published review behind an
        uncounted iteration: the delegate checkpoints in step 8 and removes
        what it made in step 9, so a removal that fails for real -- the
        attempt directory loses its write permission, exactly as
        `CleanupFailure` above arranges it -- produces a completed row and a
        retained path at once.
        """
        def run():
            registration, inventory = self.workflow.registered_inventory(
                **self.session()
            )
            claimed = self.workflow.claim(inventory, registration["keeper_pid"])
            self.assertEqual(claimed["status"], "claimed")
            pin, review_wt = self.workflow.pin(attempt=registration["attempt"])
            recorded = self.workflow.record(
                claimed["selected"]["number"], claimed["claim"]["token"], "clean", pin
            )
            self.assertEqual(recorded["status"], "recorded")
            attempt_dir = review_wt.parent
            mode = attempt_dir.stat().st_mode
            os.chmod(attempt_dir, 0o500)
            self.addCleanup(self._restore, attempt_dir, mode)
            removal = self.workflow.sh(
                asset_command(self.workflow.asset, 'git -C "$ROOT" worktree remove'),
                check=False,
                REVIEW_WT=str(review_wt),
            )
            self.assertNotEqual(removal.returncode, 0, removal.stdout)
            self.assertTrue(review_wt.is_dir())
            self.workflow.complete_attempt(registration["attempt"])
            # What the automation reads back: an ending that is not
            # `recorded`, carrying the review that nonetheless was.
            return {
                "status": "cleanup-failed",
                "already_recorded": {
                    "pr": recorded["pr"],
                    "outcome": recorded["outcome"],
                    "commit": recorded["commit"],
                    "report": recorded["report"],
                    "repeats": recorded["repeats"],
                },
                "retained": str(attempt_dir),
            }

        return run

    def _restore(self, directory, mode):
        with contextlib.suppress(FileNotFoundError):
            os.chmod(directory, mode)
            shutil.rmtree(directory, ignore_errors=True)

    def exhausted(self):
        """One invocation over a repository whose listing names nothing.

        The delegate's step 1 stops an empty listing before it registers
        anything, so this is that stop -- and the status the automation asset
        names for it is checked against the helper itself below rather than
        assumed from the prose.
        """
        def run():
            self.workflow.merged([])
            pages = self.workflow.inventory()
            self.assertEqual([row for page in pages for row in page["prs"]], [])
            return {"status": NOTHING_SELECTABLE}

        return run

    # -- what the run produced, read back out of the ledger

    def completed_rows(self):
        return {
            number: row
            for number, row in self.workflow.rows().items()
            if row["completed_at"] is not None
        }

    def progress_report(self, run):
        """The report requirement 5 describes, assembled from `run` alone.

        Built here rather than asserted field by field, because the claim
        being made is that everything the report names is available from what
        the delegate reported -- a line that had to reach into the ledger for
        one of its parts would fail to build rather than read differently.
        """
        lines = [f"{len(run['recorded'])} of {run['target']}"]
        for entry in run["recorded"]:
            links = entry["report"] or ",".join(entry["repeats"]) or "none"
            lines.append(f"#{entry['pr']} {entry['outcome']} {entry['commit']} {links}")
        stopped = run.get("stopped_on") or {}
        already = stopped.get("already_recorded")
        if already:
            lines.append(
                f"uncounted, already recorded: #{already['pr']} "
                f"{already['outcome']} {already['commit']} "
                f"retained {stopped['retained']}"
            )
        else:
            lines.append("uncounted, already recorded: none")
        lines.append(str(run["reason"]))
        return lines

    # -- the cases

    def test_a_counted_run_records_exactly_the_count_and_reports(self):
        run = self.automate(3, [self.recorded(), self.recorded(), self.recorded(), self.tripwire()])
        self.assertEqual(run["reason"], COUNT_REACHED)
        self.assertEqual(len(run["recorded"]), 3)
        self.assertEqual(run["iterations"], 3)
        # Three different pull requests, each recorded once: a loop that
        # re-reviewed one would reach the count without covering three.
        self.assertEqual(
            [entry["pr"] for entry in run["recorded"]], [620, 618, 616]
        )
        self.assertEqual(sorted(self.completed_rows()), ["616", "618", "620"])
        report = self.progress_report(run)
        self.assertEqual(report[0], "3 of 3")
        self.assertEqual(report[-1], COUNT_REACHED)
        for entry, line in zip(run["recorded"], report[1:]):
            self.assertIn(str(entry["pr"]), line)
            self.assertIn(entry["commit"], line)
            self.assertEqual(
                entry["commit"],
                e2e_git(self.workflow.root, "rev-parse", "refs/remotes/origin/master").strip(),
            )

    def test_a_refused_second_iteration_stops_with_one_recorded(self):
        run = self.automate(
            3, [self.recorded(), self.refused_by_a_failed_fetch(), self.tripwire()]
        )
        self.assertEqual(run["reason"], "fetch-failed")
        self.assertEqual(len(run["recorded"]), 1)
        self.assertEqual(run["iterations"], 2)
        # The refusal is named in the report, and the count is what actually
        # completed rather than what was attempted.
        report = self.progress_report(run)
        self.assertEqual(report[0], "1 of 3")
        self.assertEqual(report[-1], "fetch-failed")
        # And the refused iteration left no completion behind: one row is
        # recorded, the one it claimed is claimable again.
        self.assertEqual(sorted(self.completed_rows()), ["620"])
        self.assertIsNone(self.workflow.rows()["618"]["completed_at"])
        self.assertIsNone(self.workflow.rows()["618"]["claim"])

    def test_a_findings_bearing_iteration_counts_like_a_clean_one(self):
        run = self.automate(
            2,
            [
                self.recorded(outcome="findings", findings=REPORT_FIXTURE),
                self.recorded(),
                self.tripwire(),
            ],
        )
        self.assertEqual(run["reason"], COUNT_REACHED)
        self.assertEqual(
            [entry["outcome"] for entry in run["recorded"]], ["findings", "clean"]
        )
        # The findings iteration counted, and it counted with its report: the
        # progress report names the path the delegate allocated.
        self.assertEqual(run["recorded"][0]["report"], "docs/project_review/620.md")
        self.assertIn(
            "docs/project_review/620.md", self.progress_report(run)[1]
        )
        self.assertEqual(sorted(self.completed_rows()), ["618", "620"])

    def test_an_interrupted_iteration_is_not_counted_and_ends_the_run(self):
        run = self.automate(
            3, [self.recorded(), self.interrupted(), self.tripwire()]
        )
        self.assertEqual(run["reason"], "interrupted")
        self.assertEqual(len(run["recorded"]), 1)
        self.assertEqual(run["iterations"], 2)
        self.assertEqual(self.progress_report(run)[0], "1 of 3")
        self.assertEqual(sorted(self.completed_rows()), ["620"])
        # The interrupted pull request is still never-reviewed: an iteration
        # that reviewed and did not record is exactly as uncounted in the
        # ledger as it is in the run.
        self.assertEqual(self.workflow.rows()["618"]["status"], "never-reviewed")
        self.assertIsNone(self.workflow.rows()["618"]["commit"])

    def test_an_open_ended_run_stops_when_nothing_is_selectable(self):
        run = self.automate(
            None, [self.recorded(), self.recorded(), self.exhausted(), self.tripwire()]
        )
        self.assertEqual(run["reason"], NOTHING_SELECTABLE)
        self.assertEqual(run["target"], "open-ended")
        self.assertEqual(len(run["recorded"]), 2)
        self.assertEqual(self.progress_report(run)[0], "2 of open-ended")
        self.assertEqual(sorted(self.completed_rows()), ["618", "620"])

    def test_the_exhaustion_status_is_the_one_the_helper_reports(self):
        # The automation asset names `"status": "no-selectable-row"` as the
        # stop without error. Read it out of the shipped helper rather than
        # out of the prose: a listing nothing in it can be reviewed is a
        # successful selection, and a loop that read it as a refusal would
        # report the ordinary end of the queue as a failure.
        self.workflow.merged([])
        registration, inventory = self.workflow.registered_inventory(**self.session())
        result = self.workflow.claim(inventory, registration["keeper_pid"])
        self.assertEqual(result["status"], NOTHING_SELECTABLE)
        self.assertIsNone(result["selected"])
        self.workflow.complete_attempt(registration["attempt"])
        self.assertIn(
            '`"status": "no-selectable-row"`',
            flat(read(AUTOMATION_ASSETS[self.BRAND])),
        )

    def test_a_count_of_zero_delegates_nothing_at_all(self):
        run = self.automate(0, [self.tripwire()])
        self.assertEqual(run["reason"], COUNT_REACHED)
        self.assertEqual(run["recorded"], [])
        self.assertEqual(run["iterations"], 0)
        self.assertEqual(
            self.progress_report(run),
            ["0 of 0", "uncounted, already recorded: none", COUNT_REACHED],
        )
        # Nothing was claimed, nothing was recorded, and no attempt directory
        # was made: a count of zero is a run that touched the repository not
        # at all.
        self.assertEqual(self.completed_rows(), {})
        self.assertFalse(self.workflow.runtime_worktrees().exists())

    def test_a_cleanup_failure_leaves_a_recorded_review_the_report_must_name(self):
        # The second issue review's spec addition, end to end. The second
        # iteration records its review and then fails to remove what it made:
        # it does not count, it ends the run, and the review it recorded is a
        # real completed row that the progress report has to disclose along
        # with the path still on disk.
        run = self.automate(
            3, [self.recorded(), self.recorded_then_failed_cleanup(), self.tripwire()]
        )
        self.assertEqual(run["reason"], "cleanup-failed")
        self.assertEqual(len(run["recorded"]), 1)
        self.assertEqual(run["iterations"], 2)

        stopped = run["stopped_on"]
        self.assertEqual(stopped["already_recorded"]["outcome"], "clean")
        self.assertTrue(Path(stopped["retained"]).is_dir(), stopped["retained"])

        # The count is what completed cleanly; the ledger, though, carries
        # BOTH rows -- which is exactly why the report owes the second one.
        self.assertEqual(self.progress_report(run)[0], "1 of 3")
        self.assertEqual(sorted(self.completed_rows()), ["618", "620"])
        self.assertEqual(
            self.workflow.rows()[str(stopped["already_recorded"]["pr"])]["status"],
            "clean",
        )
        # And the report names it and the retained path, told apart from the
        # counted reviews.
        disclosure = self.progress_report(run)[-2]
        self.assertIn(str(stopped["already_recorded"]["pr"]), disclosure)
        self.assertIn(stopped["already_recorded"]["commit"], disclosure)
        self.assertIn(stopped["retained"], disclosure)

    def test_the_tripwire_really_fires(self):
        # Non-vacuity for every case above: "the loop stopped here" rests
        # entirely on the planned iteration after it never running, so the
        # thing that would report it must actually raise.
        with self.assertRaises(AssertionError):
            self.automate(2, [self.recorded(), self.tripwire()])


class PackagedConsistencyTests(unittest.TestCase):
    """Requirement 11: both packaged workflows carry the helpers they call."""

    def test_each_bundle_ships_every_module_its_own_asset_resolves(self):
        for brand, spec in BRAND_BUNDLES.items():
            root = REPO_ROOT / spec["bundle_root"]
            with self.subTest(brand=brand):
                for key in ("ledger", "liveness"):
                    self.assertTrue((root / spec[key]).is_file(), spec[key])
                self.assertTrue((root / "hooks" / "hooks.json").is_file())

    def test_each_asset_names_its_own_bundle_layout_for_every_module(self):
        for brand, spec in BRAND_BUNDLES.items():
            content = read(spec["asset"])
            with self.subTest(brand=brand):
                for key in ("ledger", "liveness"):
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
        SerialAutomation,
    ):
        for brand in BRAND_BUNDLES:
            name = f"{brand.capitalize()}{mixin.__name__}Tests"
            globals()[name] = type(name, (mixin, unittest.TestCase), {"BRAND": brand})


_end_to_end_cases()


if __name__ == "__main__":
    unittest.main()
