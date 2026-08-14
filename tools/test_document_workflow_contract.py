"""Parity check for docs/document-workflow-contract.md.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Guards the packaging promise of issue #229, the design/report counterpart of
what issue #118 did for drafting: the design-document and findings-report
contracts are tracked plugin assets rather than owner-local personal files, so
a repository pull request can change and verify them.

Reconciles the responsibility matrix in docs/document-workflow-contract.md
against the tracked Claude and Codex plugin trees, so a declared asset cannot
vanish, an undeclared design or report workflow cannot appear, the document
cannot silently drop the remaining Codex-only asymmetry or the design-pipeline
epic-planner boundary, the decision-authority clauses of §5.1 cannot regress out
of any tracked design workflow (issue #239), and the status vocabulary the
cross-brand variants must share cannot drift. Paired variants are
deliberately not
reconciled into one text (requirement 3 of issue #229): what is pinned here is
the surface a document started by one brand and resumed by the other depends on,
not their wording.

Issue #241 transposed /design-epic and /process-design-doc into the Claude
bundle from the post-#239 tracked Codex skills, so §3.5's asymmetry is now
partial: $draft-report is the sole remaining Codex-only workflow, the declared
set is seven assets, and three of the four workflow names are cross-brand pairs.

Discovery, frontmatter, and no-personal-path coverage for the same assets lives
in tools/test_claude_plugin.py and tools/test_codex_plugin.py; their
external-command surface is reconciled against the §4 dependency manifest by
tools/test_agent_workflow_contract.py.
"""

from __future__ import annotations

import re
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CONTRACT_PATH = REPO_ROOT / "docs" / "document-workflow-contract.md"

CLAUDE_COMMANDS_ROOT = REPO_ROOT / "claude-plugin" / "plugins" / "kanban" / "commands"
CODEX_SKILLS_ROOT = REPO_ROOT / "codex-plugin" / "plugins" / "kanban" / "skills"

# Workflow names that belong to the design/report document lifecycle rather
# than to the solve/PR-flow workflows Kanban's own CLI spawns or the drafting
# set docs/drafting-workflow-contract.md §2 declares. Any asset under either
# plugin whose workflow name is in this set must be declared in §2 of this
# contract.
DOCUMENT_WORKFLOW_NAMES = {
    "design-epic",
    "process-design-doc",
    "draft-report",
    "process-report",
}

EXPECTED_DECLARED_PATHS = {
    "claude-plugin/plugins/kanban/commands/design-epic.md",
    "claude-plugin/plugins/kanban/commands/process-design-doc.md",
    "claude-plugin/plugins/kanban/commands/process-report.md",
    "codex-plugin/plugins/kanban/skills/design-epic/SKILL.md",
    "codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md",
    "codex-plugin/plugins/kanban/skills/draft-report/SKILL.md",
    "codex-plugin/plugins/kanban/skills/process-report/SKILL.md",
}

# The one workflow §3.5 still declares Codex-only after issue #241 closed the
# design half of the asymmetry. The Claude plugin must not grow a counterpart
# under this contract: authoring one would be new behavior no pinned source
# defines.
CODEX_ONLY_WORKFLOWS = ("draft-report",)

# The marker vocabulary every declared asset states, as raw literals: these are
# the interface between two runs, two brands, and two sessions, so an
# HTML-entity-escaped or reworded transcription is drift, not formatting.
STATUS_MARKER_LITERALS = ("[#N]", "[no-issue]", "[deferred]")

# The status-checklist form. Both are required of every asset that applies a
# disposition; the design-capture pair and $draft-report never write a terminal
# marker, so they carry only the unchecked form (§4).
CHECKED_FORM = "- [x]"
UNCHECKED_FORM = "- [ ]"

DISPOSITION_APPLYING_ASSETS = (
    "claude-plugin/plugins/kanban/commands/process-design-doc.md",
    "claude-plugin/plugins/kanban/commands/process-report.md",
    "codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md",
    "codex-plugin/plugins/kanban/skills/process-report/SKILL.md",
)

# The capture assets, which select no disposition and therefore may never write
# a checked box (§4). The counterpart to DISPOSITION_APPLYING_ASSETS above.
CAPTURE_ASSETS = (
    "claude-plugin/plugins/kanban/commands/design-epic.md",
    "codex-plugin/plugins/kanban/skills/design-epic/SKILL.md",
    "codex-plugin/plugins/kanban/skills/draft-report/SKILL.md",
)

# The three cross-brand pairs in this contract, and therefore the only places a
# report or design document started by one brand can stop being resumable by
# the other.
CROSS_BRAND_PAIRS = {
    "design-epic": (
        "claude-plugin/plugins/kanban/commands/design-epic.md",
        "codex-plugin/plugins/kanban/skills/design-epic/SKILL.md",
    ),
    "process-design-doc": (
        "claude-plugin/plugins/kanban/commands/process-design-doc.md",
        "codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md",
    ),
    "process-report": (
        "claude-plugin/plugins/kanban/commands/process-report.md",
        "codex-plugin/plugins/kanban/skills/process-report/SKILL.md",
    ),
}

PROCESS_REPORT_ASSETS = CROSS_BRAND_PAIRS["process-report"]

# §5's boundaries, asserted against both process-report variants as well as the
# document. Lowercase: compared against canonical() output, because the same
# rule legitimately starts a sentence in one variant and appears mid-sentence
# in the other.
PROCESS_REPORT_SHARED_BOUNDARIES = (
    "process exactly one finding",
    "stop for explicit approval",
    "only after explicit approval",
    "stop after this one finding",
    "the one-at-a-time rule is what keeps each disposition individually approved",
)

# Boundaries and asymmetries the document itself must keep stating. Compared
# against normalized() output, so reflowing a paragraph or bolding a phrase
# does not fail CI.
CONTRACT_STATEMENTS = {
    "haskell-parity-exclusion": "user-invoked and never spawned by Kanban's CLI",
    # Issue #241 closed the design half of §3.5's asymmetry. What the document
    # must still state is the residue — one Codex-only workflow, still
    # declared rather than accidental — plus the closure record that says why
    # the other two stopped being one.
    "codex-only-asymmetry": (
        "$draft-report is the sole remaining Codex-only workflow"
    ),
    "codex-only-has-no-counterpart": (
        "No Claude counterpart to $draft-report exists"
    ),
    "codex-only-is-declared": "a declared gap rather than an oversight",
    "design-pair-closure-is-recorded": (
        "$design-epic and $process-design-doc were Codex-only under the same "
        "rule until issue #239 landed their decision-authority guardrails in "
        "the tracked Codex skills"
    ),
    "design-pair-closure-names-its-source": (
        "is the pinned source /design-epic and /process-design-doc were "
        "transposed from"
    ),
    "design-epic-creates-nothing": (
        "/design-epic and $design-epic produce a durable design document and "
        "create no tracker items"
    ),
    "epic-stays-unpackaged": "remains unpackaged in both plugins",
    "one-artifact-per-invocation": "One artifact per invocation",
    "stop-for-explicit-approval": "Stop for explicit approval",
    "design-decision-authority": "the user owns every design decision",
    "design-authority-proposals": "Proposals and never Decisions",
    "design-authority-ambiguity-stops": (
        "stops for user input rather than being classified as minor"
    ),
    # Issue #278: §8's ownership contract. The resolution order, the
    # fail-closed rule, and the routing/lane separation are the parts a later
    # rewrite could drop while every asset still looked like it resolved
    # something.
    "ownership-resolution-order": "Two tiers, and the first tier that matches wins",
    "ownership-explicit-inputs-agree": (
        "both must validate and resolve to the same repository"
    ),
    "ownership-section-7-tier": "coverage by exactly one row of",
    "ownership-fails-closed": (
        "creates no file, edits no document, and issues no gh mutation"
    ),
    "ownership-branch-fails-closed": (
        "A failed or ambiguous default-branch resolution fails closed identically"
    ),
    "routing-is-not-the-lane": "Routing is not the publication lane",
    "section-7-classifies-kanban-only": (
        "it describes this repository and nothing else"
    ),
    # Issue #237: §9's publication contract. Every entry below is a rule a
    # text-only change could quietly drop while the assets still looked like
    # they published something.
    "publication-assets-are-the-processing-ones": (
        "The four processing assets — /process-report, $process-report, "
        "/process-design-doc, and $process-design-doc — publish the approved "
        "document mutation during the same invocation that applies it"
    ),
    "publication-drafting-assets-stay-local": (
        "The three drafting assets — /design-epic, $design-epic, and "
        "$draft-report — publish nothing at all"
    ),
    "publication-section-7-is-authoritative": (
        "is the authoritative classification for Kanban paths"
    ),
    "publication-unmatched-fails-closed": (
        "pr-atomic is the fail-closed default for an unmatched path"
    ),
    "publication-needs-a-resolved-owner": (
        "must already be established before eligibility is even consulted"
    ),
    "publication-owner-must-be-kanban": (
        "coghex/kanban is the only repository with a coordination lane through "
        "these workflows"
    ),
    "publication-classification-comes-from-the-tip": (
        "§7 is therefore read out of the fetched publication tip"
    ),
    "publication-one-pinned-tip": (
        "One pinned tip answers every question, and it is pinned before the edit"
    ),
    "publication-repinning-is-a-lost-update": (
        "Re-pinning after the edit is a lost update, not a refresh"
    ),
    "publication-classification-is-parsed": (
        "The classification is parsed and gated on, not merely displayed"
    ),
    "publication-document-is-locked": (
        "The document is locked from before the edit until after the "
        "publication"
    ),
    "publication-lock-precedes-validation": (
        "It is acquired before the baseline is validated, not after"
    ),
    "publication-lock-cannot-exclude-outsiders": (
        "What a lock cannot exclude is an edit made outside the protocol"
    ),
    "publication-same-file-difference-excluded-early": (
        "A same-file difference is the case the one-path check cannot see, so it "
        "is excluded before the edit rather than after it"
    ),
    "publication-reachability-is-the-verdict": (
        "Reachability of that commit is the whole verdict, and whether the local "
        "file still equals the branch may form no part of it"
    ),
    "publication-reconciliation-is-one-directional": (
        "the local document moves to the branch, never the branch to the local "
        "document"
    ),
    "publication-branchless-contract-has-no-lane": (
        "A publication branch that carries no such contract at all has no "
        "coordination lane"
    ),
    "publication-checks-are-gates": (
        "Every check in the publication sequence is a control-flow gate, never a "
        "standalone command whose result nothing consumes"
    ),
    "publication-nothing-escapes-before-the-push": (
        "Nothing before the push leaves the object store"
    ),
    "publication-convergence-is-gated": (
        "That reconciliation is gated on the verification, not merely sequenced "
        "after it"
    ),
    "publication-matching-content-is-not-enough": (
        "Matching content still does not authorize a retry"
    ),
    "publication-marker-alone-is-insufficient": (
        "A terminal marker alone is not sufficient evidence to resume"
    ),
    "publication-resume-scan-precedes-selection": (
        "The scan for that state runs before entry selection, and is exempt from "
        "it"
    ),
    "publication-resume-through-selection-is-unreachable": (
        "A resumption check reached only through normal selection is therefore "
        "unreachable by construction"
    ),
    "publication-isolation-is-verified-on-the-commit": (
        "That isolation is verified on the publication commit itself before it "
        "is pushed, rather than inferred from how the commit was constructed"
    ),
    "publication-carries-one-mutation": (
        "A publication carries the single approved mutation to the one eligible "
        "document and nothing else"
    ),
    "publication-isolation-fails-closed": (
        "If the approved mutation cannot be isolated from other changes, "
        "publication fails closed without discarding any work"
    ),
    "publication-is-fast-forward-only": (
        "Publication is a normal fast-forward update of the remote publication "
        "branch and nothing more"
    ),
    "publication-never-force-pushes": (
        "It never force-pushes, never resets, never overwrites a concurrent "
        "advance of $DOC_BRANCH"
    ),
    "publication-leaves-the-default-branch-undiverged": (
        "A failed publication must not leave the checkout's local default branch "
        "diverged from its remote"
    ),
    "publication-is-verified-on-the-remote": (
        "may describe a document as published only after verifying that the "
        "intended publication commit is present on the remote publication branch"
    ),
    "publication-failure-has-three-states": (
        "A failure report distinguishes all three states rather than collapsing "
        "them"
    ),
    "publication-post-success-local-state": (
        "sees the published content rather than a divergent local-only copy"
    ),
    "publication-resumption-is-bounded": (
        "The evidence is only what the document and the tracker already carry"
    ),
    "publication-is-never-batched": (
        "Publication happens after each individually approved disposition and is "
        "never batched or deferred merely to reduce commit or push frequency"
    ),
}

# Issue #237: the publication step every processing asset states, as the
# load-bearing prose fragments. Compared against canonical() output for the same
# reason OWNERSHIP_CLAUSES is: each asset is its own brand's text. §9 of the
# contract summarizes the same rules; pinning them there alone would let the
# assets regress while the document kept describing them.
PUBLICATION_CLAUSES = {
    "publishes-in-the-same-run": (
        "publish the approved mutation in this same run"
    ),
    "is-never-batched": (
        "never batched or deferred merely to reduce commit or push frequency"
    ),
    "eligibility-is-section-7": (
        "it exits zero only when the pinned tip's own §7 carries a "
        "coordination row for exactly this path"
    ),
    "a-path-alone-is-not-eligibility": (
        "a repository-relative path is not by itself an eligibility signal — the "
        "same path exists in other repositories, and in other states of this one"
    ),
    "owner-must-be-kanban": (
        "coghex/kanban is the only repository with a coordination lane through "
        "this workflow"
    ),
    "a-fork-is-not-eligible": (
        "a consuming repository is never published to here, and neither is a "
        "fork, even when it tracks a contract of its own carrying a matching row"
    ),
    "classification-comes-from-the-tip": (
        "§7 is read out of $pub_tip — the exact state being published onto"
    ),
    "the-tip-is-pinned-once": (
        "one pin, established before the edit and never refreshed"
    ),
    "never-refetch-in-the-publication-step": (
        "do not fetch again here, and do not re-pin"
    ),
    "a-refreshed-pin-erases-a-concurrent-edit": (
        "building it onto the newer tip produces a one-path change that passes "
        "every gate below while erasing the concurrent edit"
    ),
    "the-old-pin-turns-it-into-a-rejection": (
        "keeping the original pin turns that case into a plain "
        "non-fast-forward rejection instead"
    ),
    "everything-names-the-pin": (
        "everything below therefore names $pub_tip, never origin/$doc_branch, "
        "until the verification step deliberately refetches"
    ),
    "verification-never-reassigns-the-pin": (
        "that step reads the refreshed remote without ever reassigning the pin"
    ),
    "the-gate-is-the-test-not-a-display": (
        "that pipeline is the eligibility test, not a display of §7 for a human "
        "to read"
    ),
    "lock-spans-edit-and-publication": (
        "lock the document, then scan it against the publication tip, before "
        "choosing an entry"
    ),
    "lock-precedes-validation": (
        "the lock is acquired before the baseline is validated, not after"
    ),
    "validating-first-leaves-a-gap": (
        "validating first and locking second leaves exactly that gap"
    ),
    "reconciliation-rechecks-the-blob": (
        "the reconciliation is itself gated on the document still being the "
        "approved blob"
    ),
    "skipped-reconciliation-preserves-the-edit": (
        "the foreign edit is left exactly where it is, and the report says the "
        "local copy was not reconciled and why"
    ),
    "unserialized-runs-batch-dispositions": (
        "this run then hashes and publishes the foreign hunk together with its "
        "own approved disposition"
    ),
    "the-empty-old-value-is-what-excludes": (
        "the empty third argument is what makes acquisition exclusive"
    ),
    "lock-is-released-on-every-path": (
        "release it once publication has succeeded or failed, on every path out"
    ),
    "a-stale-lock-is-clearable": (
        "a lock a dead run left behind is inspectable with git for-each-ref "
        "refs/kanban/ and cleared with the same -d"
    ),
    "blob-recheck-backs-up-the-lock": (
        "a file that no longer hashes to it changed after the disposition was "
        "applied"
    ),
    "clean-before-editing": (
        "the document must match the pinned tip before this run edits it"
    ),
    "same-file-difference-is-invisible": (
        "because that difference sits in the same file, the one-path check below "
        "cannot see it"
    ),
    "unrelated-same-file-work-blocks-publication": (
        "publication is impossible for this run"
    ),
    "ancestry-alone-is-the-verdict": (
        "ancestry alone is the verdict, and comparing the local file to the "
        "branch must play no part in it"
    ),
    "concurrent-advance-is-not-a-failure": (
        "folding that comparison into the verdict would report a successful "
        "publication as failed"
    ),
    "reconciliation-moves-local-to-the-branch": (
        "it moves the local document to the branch rather than the other way "
        "round"
    ),
    "a-stale-checkout-is-not-the-authority": (
        "a dirty, stale, or unmerged $doc_root can classify a path coordination "
        "when the publication branch does not"
    ),
    "branchless-contract-is-ineligible": (
        "a publication branch carrying no such contract at all"
    ),
    "isolation-is-verified-on-the-artifact": (
        "verify the isolation on the artifact rather than trusting the "
        "construction that produced it"
    ),
    "scratch-index-is-per-path-and-content": (
        "the scratch index is named for the document's path as well as its "
        "content, so no two concurrent publications in one docs worktree share it"
    ),
    "the-check-gates-the-push": (
        "the push is gated on the one-path check, not merely preceded by it"
    ),
    "never-push-unconditionally": (
        "never run the push as an unconditional next line"
    ),
    "checks-are-control-flow-gates": (
        "every check in this section is a control-flow gate, never a standalone "
        "command whose result nothing consumes"
    ),
    "a-bare-predicate-falls-through": (
        "a predicate written on its own line fails silently into the next line, "
        "and the next line here pushes, checks out, or fast-forwards"
    ),
    "nothing-escapes-before-the-push": (
        "nothing above the push leaves the object store"
    ),
    "verified-flag-is-the-verdict": (
        "say the document is published only when pub_published is yes, and "
        "treat every other outcome as an unpublished failure"
    ),
    "reconciliation-is-gated-on-verification": (
        "it runs only when the publication is confirmed"
    ),
    "pr-atomic-is-never-published": (
        "a pr-atomic path, and a path no §7 row matches all leave it nonzero"
    ),
    "unmatched-fails-closed": (
        "pr-atomic is the fail-closed default for an unmatched path"
    ),
    "ineligible-stays-recoverable": (
        "leave the edit in place and recoverable, say plainly that it was not "
        "published and why"
    ),
    "needs-a-resolved-owner": (
        "an owner or publication branch that could not be verified fails closed "
        "and the document stays unpublished"
    ),
    "carries-one-mutation": (
        "a publication carries the single approved mutation to the one eligible "
        "document and nothing else"
    ),
    "sweeps-in-nothing-else": (
        "no unrelated dirty paths, no earlier docs-wip commits, no unrelated "
        "changes already present in the same document, and no second disposition"
    ),
    "isolation-fails-closed": (
        "if the approved mutation cannot be isolated from other changes, "
        "publication fails closed: publish nothing, discard nothing"
    ),
    "never-force-pushes": (
        "never force-push, never reset, and never overwrite a concurrent advance "
        "of $doc_branch or resolve a conflict by guessing"
    ),
    "rejection-is-an-unpublished-failure": (
        "a non-fast-forward rejection, a conflict, or a branch that moved under "
        "the run leaves the mutation recoverable and is reported as an "
        "unpublished failure"
    ),
    "leaves-the-default-branch-undiverged": (
        "recoverable never means a commit left on the local default branch of a "
        "checkout the pr drainer fast-forwards"
    ),
    "verified-on-the-remote": (
        "the publication landed if and only if the intended commit is "
        "reachable from the remote publication branch"
    ),
    "post-success-local-state": (
        "it also restores the invariant the next run depends on — the document "
        "equals the publication tip"
    ),
    "convergence-is-scoped-to-the-fallback": (
        "the fast-forward applies only when $docs_wt fell back to the checkout "
        "sitting on $doc_branch"
    ),
    "failure-has-three-states": (
        "whether the document edit exists locally and in which worktree and at "
        "which path; whether a local publication commit exists and, if so, its "
        "commit id; and whether the remote publication branch contains that "
        "commit"
    ),
    "scan-precedes-selection": (
        "order matters here as much as the checks do"
    ),
    "scan-decides-what-the-run-may-do": (
        "that comparison then decides what this run may do at all"
    ),
    "clean-scan-permits-publication": (
        "this run's own edit is then the only difference, which is exactly what "
        "lets its publication carry the approved mutation and nothing else"
    ),
    "unrelated-work-blocks-this-run": (
        "the document carries something other than exactly that approved "
        "mutation"
    ),
    "never-discard-to-publish": (
        "never publish anyway, and never discard the other work to make "
        "publication possible"
    ),
    "resumes-only-the-publication-step": (
        "re-attempt the publication step below against it, never repeat the "
        "tracker mutation, and select no new entry this run"
    ),
    "pending-state-decides-the-retry": (
        "matching content is still not enough to retry, because the recorded "
        "commit was built on the tip of its own run"
    ),
    "a-landed-pending-commit-publishes-nothing": (
        "the earlier push reached the branch after all and only the report was "
        "lost. publish nothing"
    ),
    "a-stale-pending-commit-fails-closed": (
        "rebuilding that recorded blob on the newer tip would push the "
        "pre-advance content as a one-path change"
    ),
    "resume-needs-an-exact-match": (
        "only an exact match with a recorded pending publication may be resumed"
    ),
    "marker-alone-is-insufficient": (
        "a terminal marker is not sufficient evidence on its own"
    ),
    "failure-records-what-it-approved": (
        "an unpublished mutation records what it approved, so a later run can "
        "identify it"
    ),
    "pending-record-is-cleared-on-success": (
        "set to this run's publication commit on failure and deleted on "
        "success"
    ),
    "scan-is-exempt-from-selection": (
        "this scan is the one deliberate exception to the selection rule below, "
        "which never selects a terminal-marked entry"
    ),
    "selection-would-skip-it-forever": (
        "normal selection would skip it forever and the failed publication would "
        "never be retried"
    ),
    "selection-rule-names-the-exception": (
        "the unfinished-publication scan above is the one deliberate exception to "
        "this rule: it re-attempts publication for an entry that is already "
        "terminally marked, and selects no new work"
    ),
    "resumption-evidence-is-bounded": (
        "that marker and an existing local publication commit are the only "
        "evidence used here"
    ),
}

# The executable half. The commit is built from the fetched remote tip with one
# blob replaced and pushed without --force, which is what makes requirements 4
# and 5 structural rather than aspirational: `commit-tree` moves no local
# branch, so a rejected push cannot strand a commit on the default branch the
# drainer fast-forwards, and a tree built from `origin/$DOC_BRANCH` cannot carry
# a second path. Compared against normalized() because case is load-bearing in a
# shell command.
PUBLICATION_SHELL_BINDINGS = (
    # Only Kanban's own documents take this lane, and the classification is
    # read from the branch being published to rather than from a checkout that
    # may be dirty, stale, or unmerged relative to it.
    # The tip is pinned once and every later question names the pin.
    'PUB_TIP="$(git -C "$DOCS_WT" rev-parse "origin/$DOC_BRANCH")"',
    # The classification is parsed out of that pin and gates the owner test,
    # rather than being printed for a human to read.
    '[ "$DOC_REPO" = "coghex/kanban" ] \\ '
    '&& git -C "$DOCS_WT" show "${PUB_TIP}:docs/agent-workflow-contract.md" \\ '
    '| awk -v want="$DOC_RELATIVE_PATH" \' '
    '/^## 7\\. Document publication classification$/{sec = 1; next} '
    '(sec) && /^## /{exit} '
    '(sec) && $1 == want && $2 == "|" && $3 == "coordination"{ok = 1; exit} '
    'END{exit !ok}\'',
    # The precondition that makes a same-file difference impossible to publish
    # accidentally: the document equals the pinned tip before the run edits it.
    'git -C "$DOCS_WT" diff --quiet "$PUB_TIP" -- "$DOC_RELATIVE_PATH"',
    # Atomic per-document mutual exclusion: update-ref with an empty old
    # value requires the ref to be absent, so exactly one run creates it.
    'PUB_LOCK="refs/kanban/publish-lock/$PUB_KEY"',
    'git -C "$DOCS_WT" update-ref "$PUB_LOCK" "$PUB_TIP" ""',
    'git -C "$DOCS_WT" update-ref -d "$PUB_LOCK"',
    # The pending-publication record: a failed run stores the commit whose
    # tree holds the exact approved blob, and resumption demands a byte-for-
    # byte match against it rather than trusting the terminal marker.
    'PUB_PENDING="refs/kanban/pending-publication/$PUB_KEY"',
    # Content identity is necessary but not sufficient: the recorded commit
    # must also still be parented on the pinned tip, or already landed.
    'git -C "$DOCS_WT" merge-base --is-ancestor "$PUB_PENDING" "origin/$DOC_BRANCH" \\ '
    '&& PUB_PENDING_STATE=landed',
    '[ "$PUB_PENDING_STATE" = stale ] \\ '
    '&& [ "$(git -C "$DOCS_WT" rev-parse "${PUB_PENDING}^")" = "$PUB_TIP" ] \\ '
    '&& PUB_PENDING_STATE=retryable',
    'git -C "$DOCS_WT" rev-parse --verify --quiet "$PUB_PENDING" \\ '
    '&& [ "$(git -C "$DOCS_WT" hash-object -- "$DOCS_WT/$DOC_RELATIVE_PATH")" \\ '
    '= "$(git -C "$DOCS_WT" rev-parse "${PUB_PENDING}:${DOC_RELATIVE_PATH}")" ]',
    '[ "$PUB_PUBLISHED" = yes ] && git -C "$DOCS_WT" update-ref -d "$PUB_PENDING"',
    '[ "$PUB_PUBLISHED" = no ] \\ '
    '&& git -C "$DOCS_WT" update-ref "$PUB_PENDING" "$PUB_COMMIT"',
    # The pre-selection scan, against the same pin: a document differing from
    # the publication tip is either an earlier run's unpublished mutation or
    # work this run must not publish, and both are decided before selection.
    'git -C "$DOCS_WT" diff --name-only "$PUB_TIP" -- "$DOC_RELATIVE_PATH"',
    # Keyed by path as well as content, so two documents that hash alike cannot
    # share one scratch index and interleave into a two-path tree.
    'PUB_KEY="${DOC_RELATIVE_PATH//\\//-}"',
    'PUB_INDEX="$(git -C "$DOCS_WT" rev-parse --git-path '
    '"kanban-publish-index-$PUB_KEY-$PUB_BLOB")"',
    # The isolation guarantee, checked on the finished commit rather than
    # assumed from how it was built — and consumed as the push's own condition,
    # since a verification nothing reads would let a mixed tree through.
    # The push gate in full: owner, the approved blob (the lock's backstop
    # against a change made outside the protocol), and the one-path check.
    '&& [ "$(git -C "$DOCS_WT" hash-object -- "$DOCS_WT/$DOC_RELATIVE_PATH")" \\ '
    '= "$PUB_BLOB" ] \\ '
    '&& [ "$(git -C "$DOCS_WT" diff --name-only "$PUB_TIP" "$PUB_COMMIT")" \\ '
    '= "$DOC_RELATIVE_PATH" ] \\ '
    '&& git -C "$DOCS_WT" push origin "${PUB_COMMIT}:refs/heads/${DOC_BRANCH}"',
    # Reachability alone decides published/unpublished. Adding the local-file
    # comparison here would report a concurrent same-file advance as a failed
    # publication, and the next scan would republish over it.
    'git -C "$DOCS_WT" merge-base --is-ancestor "$PUB_COMMIT" "origin/$DOC_BRANCH" \\ '
    '&& PUB_PUBLISHED=yes',
    '[ "$PUB_PUBLISHED" = yes ] \\ '
    '&& [ "$(git -C "$DOCS_WT" hash-object -- "$DOCS_WT/$DOC_RELATIVE_PATH")" \\ '
    '= "$PUB_BLOB" ] \\ '
    '&& git -C "$DOCS_WT" checkout "origin/$DOC_BRANCH" -- "$DOC_RELATIVE_PATH" \\ '
    '&& PUB_RECONCILED=yes',
    'GIT_INDEX_FILE="$PUB_INDEX" git -C "$DOCS_WT" read-tree "$PUB_TIP"',
    'git -C "$DOCS_WT" commit-tree "$PUB_TREE"',
    # Guarded by the branch test rather than run unconditionally: a docs-wip
    # worktree is on its own branch, and fast-forwarding it to the publication
    # branch would be a different operation entirely. The path-scoped checkout
    # is part of the same guarded chain because git refuses to fast-forward
    # over a locally modified file even when the file's content is exactly what
    # the fast-forward would install.
    '[ "$PUB_RECONCILED" = yes ] \\ '
    '&& [ "$(git -C "$DOCS_WT" rev-parse --abbrev-ref HEAD)" = "$DOC_BRANCH" ] \\ '
    '&& git -C "$DOCS_WT" merge --ff-only "origin/$DOC_BRANCH"',
)

# The blanket prohibition §9 replaced in the processing assets. It stated the
# opposite of the publication step, so an asset that reintroduces it has
# un-published its mutation no matter what its new section still says. The
# drafting assets never carried it: they publish nothing and say so.
PUBLICATION_FORBIDDEN_PROSE = (
    "do not commit, push, or open a pr unless separately requested",
    "do not commit, push, open a pr, or modify implementation code unless "
    "separately requested",
)

# Issue #237 requirement 3: what a drafting asset must say about a document it
# just created. The classifier derives its inventory from `git ls-files`, so a
# novel document matches no row and is pr-atomic — there is no moment at which
# it is directly publishable.
BOOTSTRAP_CLAUSES = {
    "novel-document-is-local": (
        "a document this workflow newly creates is local and unpublished, and "
        "this workflow never publishes one"
    ),
    "unmatched-is-pr-atomic": (
        "an unmatched path is pr-atomic by the fail-closed default"
    ),
    "never-directly-publishable": (
        "there is no moment at which a novel document is directly publishable"
    ),
    "first-publication-needs-a-pull-request": (
        "its first publication requires a separate pull request that adds both "
        "the document and its coordination classification"
    ),
    "only-then-may-processing-publish": (
        "only after that pull request lands may a later processing run publish "
        "direct-to-master mutations to it"
    ),
    "enrollment-is-out-of-scope": (
        "creating that enrollment pull request is not this workflow's job either"
    ),
}

# §9.1's two halves, as this module's own lists. The publication clauses are
# asserted against the first and the bootstrap clauses against the second, and
# the partition assertion below keeps a later asset from escaping both.
PROCESSING_ASSETS = DISPOSITION_APPLYING_ASSETS
DRAFTING_ASSETS = CAPTURE_ASSETS

# Issue #278: the ownership-resolution step every declared asset states, as the
# load-bearing prose fragments. Compared against canonical() output for the
# same reason DESIGN_AUTHORITY_CLAUSES is: the five assets are each brand's own
# text, so reflowing a paragraph or bolding a term must not fail CI. §8 of the
# contract summarizes the same rules; pinning them there alone would let the
# assets regress while the document kept describing them.
OWNERSHIP_CLAUSES = {
    "resolves-owner-slug": (
        "$doc_repo — the owning repository as an explicit owner/repo slug"
    ),
    "resolves-publication-branch": (
        "$doc_branch — that repository's default branch, which is the "
        "publication target. it is never assumed to be the current checkout's "
        "branch"
    ),
    "resolves-local-write-root": (
        "$doc_root — a validated local checkout of $doc_repo"
    ),
    "resolves-before-any-write": (
        "before the first durable write and before the first tracker mutation"
    ),
    "two-tiers-first-match-wins": (
        "resolution has two tiers, and the first tier that matches wins"
    ),
    "explicit-inputs-must-agree": (
        "conflicting explicit inputs are unresolved, not a preference to rank"
    ),
    "section-7-tier": (
        "coverage by exactly one row of docs/agent-workflow-contract.md §7 "
        "declares the document kanban-owned"
    ),
    "section-7-is-kanban-only": "classifies kanban paths only",
    "new-document-is-expected": (
        "a new document that no row covers is the expected case rather than an "
        "error"
    ),
    "unresolved-fails-closed": (
        "stops the run before it creates a file, edits a document, or issues "
        "any gh mutation"
    ),
    "branch-failure-fails-closed": (
        "an unresolved owner, an unresolved or ambiguous default branch"
    ),
    "no-fallback-is-the-repair": (
        "falling back to the active checkout, to the current branch, to a "
        "hardcoded path, or to a bare docs/ prefix is never the repair"
    ),
    "reports-owner-and-branch": (
        "report the resolved $doc_repo and $doc_branch to the user before the "
        "first write"
    ),
    "evidence-is-not-ownership": (
        "reading code, tests, or history from another repository as evidence "
        "stays allowed and is never an ownership signal"
    ),
    "routing-is-not-the-lane": (
        "repository routing and the publication lane are separate decisions"
    ),
}

# The executable half of the same step. Compared against normalized() rather
# than canonical() output because case is load-bearing here: `git -C` and
# `git -c` are different flags, and $DOC_ROOT is a variable name rather than
# prose.
OWNERSHIP_SHELL_BINDINGS = (
    'DOC_ROOT="$(git -C "$CANDIDATE" rev-parse --show-toplevel)"',
    'DOC_REMOTE="$(git -C "$DOC_ROOT" remote get-url origin)"',
    'DOC_REPO="$(gh repo view "$DOC_REMOTE" --json nameWithOwner',
    'DOC_BRANCH="$(gh repo view "$DOC_REMOTE" --json defaultBranchRef',
    'git -C "$DOC_ROOT" ls-files --error-unmatch',
    'DOCS_WT="$(git -C "$DOC_ROOT" worktree list --porcelain',
    '[ -n "$DOCS_WT" ] || DOCS_WT="$DOC_ROOT"',
)

# The unscoped forms §8 replaced. These are what the five assets used to run,
# and the exact shape of the verified wrong-repository failure: both resolve
# the write root from whichever checkout the session started in, so an asset
# that reintroduces either has un-bound its writes from $DOC_ROOT no matter
# what its prose still claims.
OWNERSHIP_FORBIDDEN_SHELL = (
    'DOCS_WT="$(git worktree list --porcelain',
    '[ -n "$DOCS_WT" ] || DOCS_WT="$(git rev-parse --show-toplevel)"',
)

# Requirement 4 of issue #278. An invocation is owner-bound by naming
# $DOC_REPO, or — for the two calls that resolve the slug in the first place —
# by naming the remote of the already-resolved $DOC_ROOT positionally. Nothing
# is bound by the process working directory, which is the failure this closes.
# Any other spelling, including an unquoted -R $DOC_REPO or a scope naming some
# other variable, is reported: this check fails closed, so a
# bound-but-unrecognized form is a rewrite of this list rather than a silent
# pass.
OWNER_BOUND_FORMS = (
    '-R "$DOC_REPO"',
    '--repo "$DOC_REPO"',
    'repo view "$DOC_REMOTE"',
)

# \b before `gh` keeps "through the next heading" out of the scan while still
# matching a real invocation at a line start or after a `$(`.
GH_INVOCATION_RE = re.compile(r"\bgh\s+(?P<command>[a-z][^\n`]*)")

# Issue #239: the design pair's decision-authority section, as the load-bearing
# fragments both assets must state. §5's approval stop governs the external
# mutation; these govern the choice that mutation encodes, which is settled
# earlier in the conversation and has no artifact to withhold. Compared against
# canonical() output, so reflowing a paragraph, bolding a term, or starting a
# sentence with a clause that appears mid-sentence in the other file does not
# fail CI. §5.1 of the contract summarizes the same boundary; that summary is
# pinned in CONTRACT_STATEMENTS above, and pinning it there alone would let the
# assets regress while the document kept describing them.
DESIGN_AUTHORITY_CLAUSES = {
    "human-led": "this is a human-led",
    "proposals-never-decisions": (
        "agent-authored directions are proposals, never decisions"
    ),
    "decision-entry-needs-approval": "a d-n entry only on explicit user approval",
    "serious-decision-checkpoint": (
        "a serious decision needs its own explicit signoff checkpoint"
    ),
    "enumerated-signoff-only": (
        "signoff may cover a clearly enumerated set of decisions, but never an "
        "unstated or inferred one"
    ),
    "silence-is-not-signoff": (
        "silence, continued conversation, approval of a document edit, or a "
        "request for revisions is not signoff"
    ),
    "ambiguity-is-never-minor": "do not classify an ambiguity as minor",
    "three-question-batching": "ask at most three focused questions at a time",
}

DESIGN_AUTHORITY_ASSETS = (
    "claude-plugin/plugins/kanban/commands/design-epic.md",
    "claude-plugin/plugins/kanban/commands/process-design-doc.md",
    "codex-plugin/plugins/kanban/skills/design-epic/SKILL.md",
    "codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md",
)

# Requirement 2 of issue #239: $design-epic's step 7 used to close with "Leave
# lesser uncertainty in the document instead of blocking useful progress",
# which states the opposite of the ambiguity clause above. Pinned as forbidden
# prose so the permissive instruction cannot return beside the section that
# replaced it — in either brand's capture workflow, since issue #241 transposed
# the Claude one from this same text and a later edit could reintroduce it
# there alone.
DESIGN_EPIC_FORBIDDEN_PROSE = (
    "leave lesser uncertainty in the document",
    "instead of blocking useful progress",
)

DESIGN_EPIC_ASSETS = (
    "claude-plugin/plugins/kanban/commands/design-epic.md",
    "codex-plugin/plugins/kanban/skills/design-epic/SKILL.md",
)

DECLARED_ASSET_ROW_RE = re.compile(
    r"^(?P<brand>claude|codex)\s*\|\s*(?P<invocation>[/$][\w-]+)\s*\|\s*(?P<path>\S+)$"
)

SECTION_2_FENCE_RE = re.compile(
    r"^##\s*2\.\s*Declared assets\s*$.*?```text\n(?P<body>.*?)\n```",
    re.DOTALL | re.MULTILINE,
)


def contract_text() -> str:
    return CONTRACT_PATH.read_text(encoding="utf-8")


def normalized(text: str) -> str:
    """Collapse whitespace and drop markdown emphasis so an assertion on a
    documented boundary survives reflowing a paragraph or bolding a word."""
    return re.sub(r"\s+", " ", text.replace("*", "").replace("`", ""))


def canonical(text: str) -> str:
    """normalized() plus case folding, for prose asserted across files where
    the same rule legitimately starts a sentence in one and appears
    mid-sentence in another."""
    return normalized(text).lower()


def parse_declared_assets(text=None):
    """Rows from the §2 machine-readable fence, keyed by repository-relative
    path. Anchored to the §2 heading so an unrelated ```text fence elsewhere in
    the document can never be parsed as the declared-asset list."""
    fence_match = SECTION_2_FENCE_RE.search(contract_text() if text is None else text)
    if fence_match is None:
        raise AssertionError(
            "docs/document-workflow-contract.md has no ```text declared-asset "
            "fence under its '## 2. Declared assets' heading"
        )
    rows = {}
    for line in fence_match.group("body").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = DECLARED_ASSET_ROW_RE.match(line)
        if match is None:
            raise AssertionError(f"unparseable declared-asset row: {line!r}")
        row = match.groupdict()
        if row["path"] in rows:
            raise AssertionError(f"duplicate declared-asset row for {row['path']!r}")
        rows[row["path"]] = row
    return rows


def discovered_document_assets(
    claude_commands_root=CLAUDE_COMMANDS_ROOT,
    codex_skills_root=CODEX_SKILLS_ROOT,
    repo_root=REPO_ROOT,
):
    """Every design or report document workflow actually present under either
    plugin, as repository-relative paths. Parameterized by root so the
    load-bearing tests below can drive it against a planted tree rather than
    only against the tree that already passes."""
    found = set()
    if claude_commands_root.is_dir():
        for command_md in sorted(claude_commands_root.glob("*.md")):
            if command_md.stem in DOCUMENT_WORKFLOW_NAMES:
                found.add(command_md.relative_to(repo_root).as_posix())
    if codex_skills_root.is_dir():
        for skill_dir in sorted(codex_skills_root.iterdir()):
            if skill_dir.is_dir() and skill_dir.name in DOCUMENT_WORKFLOW_NAMES:
                found.add((skill_dir / "SKILL.md").relative_to(repo_root).as_posix())
    return found


def missing_declared_assets(declared, repo_root=REPO_ROOT):
    return sorted(path for path in declared if not (repo_root / path).is_file())


def missing_contract_statements(text):
    """The §-level boundaries `text` no longer states, by key."""
    document = normalized(text)
    return sorted(
        key
        for key, statement in CONTRACT_STATEMENTS.items()
        if statement not in document
    )


def missing_design_authority_clauses(text):
    """The decision-authority clauses `text` no longer states, by key."""
    asset = canonical(text)
    return sorted(
        key
        for key, clause in DESIGN_AUTHORITY_CLAUSES.items()
        if clause not in asset
    )


def missing_ownership_clauses(text):
    """The §8 ownership-resolution clauses `text` no longer states, by key."""
    asset = canonical(text)
    return sorted(
        key for key, clause in OWNERSHIP_CLAUSES.items() if clause not in asset
    )


def missing_ownership_bindings(text):
    """The §8 shell bindings `text` no longer performs."""
    asset = normalized(text)
    return [binding for binding in OWNERSHIP_SHELL_BINDINGS if binding not in asset]


def reintroduced_unscoped_roots(text):
    """The pre-§8 active-checkout resolutions `text` has brought back."""
    asset = normalized(text)
    return [form for form in OWNERSHIP_FORBIDDEN_SHELL if form in asset]


def missing_publication_clauses(text):
    """The §9 publication clauses `text` no longer states, by key."""
    asset = canonical(text)
    return sorted(
        key for key, clause in PUBLICATION_CLAUSES.items() if clause not in asset
    )


def missing_publication_bindings(text):
    """The §9 publication commands `text` no longer runs."""
    asset = normalized(text)
    return [
        binding for binding in PUBLICATION_SHELL_BINDINGS if binding not in asset
    ]


def reintroduced_publication_prohibitions(text):
    """The blanket never-commit prohibition §9 replaced, if it is back."""
    asset = canonical(text)
    return [form for form in PUBLICATION_FORBIDDEN_PROSE if form in asset]


def missing_bootstrap_clauses(text):
    """The §9.1 novel-document clauses `text` no longer states, by key."""
    asset = canonical(text)
    return sorted(
        key for key, clause in BOOTSTRAP_CLAUSES.items() if clause not in asset
    )


def unbound_gh_invocations(text):
    """Every `gh` invocation in `text` that binds to neither $DOC_REPO nor the
    resolved $DOC_ROOT, and therefore to the shell's current directory."""
    unbound = []
    for match in GH_INVOCATION_RE.finditer(text):
        invocation = match.group(0).strip()
        if any(form in invocation for form in OWNER_BOUND_FORMS):
            continue
        unbound.append(invocation)
    return unbound


def missing_marker_literals(text):
    """The exact §4 status literals `text` no longer states."""
    return [
        literal
        for literal in (*STATUS_MARKER_LITERALS, CHECKED_FORM, UNCHECKED_FORM)
        if literal not in text
    ]


class DeclaredAssetTests(unittest.TestCase):
    def setUp(self):
        self.declared = parse_declared_assets()

    def test_declared_assets_are_exactly_the_seven_packaged_workflows(self):
        self.assertEqual(set(self.declared), EXPECTED_DECLARED_PATHS)

    def test_every_declared_asset_exists_in_the_tracked_tree(self):
        missing = missing_declared_assets(self.declared)
        self.assertEqual(
            missing,
            [],
            f"declared in docs/document-workflow-contract.md §2 but absent: {missing}",
        )

    def test_a_deleted_declared_asset_is_reported(self):
        # The absence check is load-bearing rather than decorative: point it at
        # a tree where a declared asset is gone and it names that asset.
        with tempfile.TemporaryDirectory() as temp_dir:
            repo_root = Path(temp_dir)
            for path in EXPECTED_DECLARED_PATHS - {
                "codex-plugin/plugins/kanban/skills/draft-report/SKILL.md"
            }:
                target = repo_root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("---\nname: x\n---\n", encoding="utf-8")
            self.assertEqual(
                missing_declared_assets(self.declared, repo_root=repo_root),
                ["codex-plugin/plugins/kanban/skills/draft-report/SKILL.md"],
            )

    def test_no_undeclared_document_workflow_asset_exists(self):
        undeclared = sorted(discovered_document_assets() - set(self.declared))
        self.assertEqual(
            undeclared,
            [],
            "design/report document workflows exist under a plugin without a §2 "
            f"row in docs/document-workflow-contract.md: {undeclared}",
        )

    def test_an_undeclared_asset_added_to_either_plugin_is_reported(self):
        # The realistic regression this guards is a Claude counterpart to the
        # one workflow §3.5 still declares Codex-only appearing without that
        # section being revisited. /design-epic used to be the planted asset
        # here; issue #241 declared it, so the plant moved to /draft-report,
        # which is the remaining case the rule protects.
        with tempfile.TemporaryDirectory() as temp_dir:
            repo_root = Path(temp_dir)
            commands = repo_root / "claude-plugin" / "plugins" / "kanban" / "commands"
            skills = repo_root / "codex-plugin" / "plugins" / "kanban" / "skills"
            commands.mkdir(parents=True)
            (skills / "draft-report").mkdir(parents=True)
            (commands / "draft-report.md").write_text("---\n---\n", encoding="utf-8")
            (commands / "solve.md").write_text("---\n---\n", encoding="utf-8")
            (skills / "draft-report" / "SKILL.md").write_text("x\n", encoding="utf-8")
            found = discovered_document_assets(
                claude_commands_root=commands,
                codex_skills_root=skills,
                repo_root=repo_root,
            )
        self.assertEqual(
            sorted(found - EXPECTED_DECLARED_PATHS),
            ["claude-plugin/plugins/kanban/commands/draft-report.md"],
        )

    def test_declared_brand_and_invocation_match_the_assets_own_plugin_and_name(self):
        for path, row in sorted(self.declared.items()):
            expected_prefix = (
                "claude-plugin/" if row["brand"] == "claude" else "codex-plugin/"
            )
            self.assertTrue(
                path.startswith(expected_prefix),
                f"{path} is declared brand {row['brand']!r} but lives under the other plugin",
            )
            expected_sigil = "/" if row["brand"] == "claude" else "$"
            self.assertTrue(
                row["invocation"].startswith(expected_sigil),
                f"{path}: {row['brand']} invocation must start with {expected_sigil!r}",
            )
            workflow_name = row["invocation"][1:]
            self.assertIn(workflow_name, DOCUMENT_WORKFLOW_NAMES, path)
            stem = (
                Path(path).parent.name
                if path.endswith("/SKILL.md")
                else Path(path).stem
            )
            self.assertEqual(
                stem,
                workflow_name,
                f"{path} does not implement its declared invocation {row['invocation']!r}",
            )

    def test_the_remaining_codex_only_workflow_is_declared_for_codex_alone(self):
        for name in CODEX_ONLY_WORKFLOWS:
            rows = [
                row
                for row in self.declared.values()
                if row["invocation"][1:] == name
            ]
            self.assertEqual(len(rows), 1, name)
            self.assertEqual(rows[0]["brand"], "codex", name)
            self.assertFalse(
                (CLAUDE_COMMANDS_ROOT / f"{name}.md").exists(),
                f"{name} is Codex-only (docs/document-workflow-contract.md §3.5); "
                "the Claude plugin must not package a counterpart",
            )

    def test_the_three_cross_brand_pairs_are_declared_for_both_brands(self):
        by_workflow = {}
        for row in self.declared.values():
            by_workflow.setdefault(row["invocation"][1:], set()).add(row["brand"])
        for name in CROSS_BRAND_PAIRS:
            self.assertEqual(by_workflow[name], {"claude", "codex"}, name)
        self.assertEqual(
            sorted(name for name, brands in by_workflow.items() if len(brands) > 1),
            sorted(CROSS_BRAND_PAIRS),
        )

    def test_each_cross_brand_pair_declares_its_two_actual_files(self):
        # The set comparison above proves two brands claim each name; this
        # proves the declared rows are the files CROSS_BRAND_PAIRS drives every
        # per-pair assertion in this module against.
        for name, paths in sorted(CROSS_BRAND_PAIRS.items()):
            with self.subTest(workflow=name):
                declared_for_name = sorted(
                    path
                    for path, row in self.declared.items()
                    if row["invocation"][1:] == name
                )
                self.assertEqual(declared_for_name, sorted(paths))

    def test_claude_epic_disposition_routes_to_packaged_claude_workflows(self):
        # Inverted by issue #241. While §3.5 declared the design pair
        # Codex-only, /process-report had to hand an Epic disposition to
        # Codex's $design-epic; now that the Claude commands exist, naming the
        # Codex sigil would route a Claude session out of its own bundle.
        path = "claude-plugin/plugins/kanban/commands/process-report.md"
        text = (REPO_ROOT / path).read_text(encoding="utf-8")
        for workflow in ("design-epic", "process-design-doc"):
            self.assertIn(
                f"/{workflow}",
                text,
                f"{path}: Epic dispositions must hand off to the packaged "
                f"Claude /{workflow} command",
            )
            self.assertNotIn(
                f"${workflow}",
                text,
                f"{path}: /{workflow} is packaged for Claude; do not route an "
                "Epic disposition to the Codex sigil",
            )


class DocumentedBoundaryTests(unittest.TestCase):
    """§3.5's declared Codex-only asymmetry, §3.6's design-pipeline
    epic-planner boundary, §1's Haskell invocation-parity exclusion, and §5's
    two processing boundaries are load-bearing: they are the reason the Claude
    plugin's declared set here is one asset rather than five, the reason an
    epic asset is still packaged in neither plugin, and the reason Kanban's
    CLI never spawns any of these."""

    def test_document_states_every_declared_boundary(self):
        self.assertEqual(missing_contract_statements(contract_text()), [])

    def test_removing_a_boundary_statement_is_reported(self):
        # Each statement is checked, not just present somewhere: mutate one at
        # a time and confirm exactly that key is reported.
        text = contract_text()
        for key, statement in CONTRACT_STATEMENTS.items():
            with self.subTest(statement=key):
                mutated = normalized(text).replace(statement, "")
                self.assertEqual(missing_contract_statements(mutated), [key])

    def test_document_distinguishes_capture_from_processing(self):
        document = normalized(contract_text())
        self.assertIn("One artifact per invocation", document)
        self.assertIn("the durable cursor", document)


class DesignDecisionAuthorityTests(unittest.TestCase):
    """Issue #239: retiring the owner-maintained personal copies must not
    silently swap the stricter design-signoff policy they carried for the
    permissive one the tracked Codex lineage grew up with. The clauses are
    asserted in the packaged assets themselves, not only in the contract prose
    describing them, because the assets are what an agent actually reads."""

    def asset_text(self, path):
        return (REPO_ROOT / path).read_text(encoding="utf-8")

    def test_both_design_workflows_state_every_authority_clause(self):
        for path in DESIGN_AUTHORITY_ASSETS:
            with self.subTest(path=path):
                missing = missing_design_authority_clauses(self.asset_text(path))
                self.assertEqual(
                    missing,
                    [],
                    f"{path} no longer states the decision-authority clauses "
                    f"docs/document-workflow-contract.md §5.1 pins: {missing}",
                )

    def test_removing_a_clause_from_a_design_workflow_is_reported(self):
        # The check above is load-bearing rather than decorative: delete one
        # clause at a time from each asset and confirm exactly that key is
        # reported. canonical() is idempotent, so mutating its output is the
        # same planted-violation shape the boundary tests above use.
        for path in DESIGN_AUTHORITY_ASSETS:
            asset = canonical(self.asset_text(path))
            for key, clause in DESIGN_AUTHORITY_CLAUSES.items():
                with self.subTest(path=path, clause=key):
                    mutated = asset.replace(clause, "")
                    self.assertEqual(missing_design_authority_clauses(mutated), [key])

    def test_no_design_epic_variant_defers_lesser_uncertainty(self):
        for path in DESIGN_EPIC_ASSETS:
            text = canonical(self.asset_text(path))
            for phrase in DESIGN_EPIC_FORBIDDEN_PROSE:
                with self.subTest(path=path, phrase=phrase):
                    self.assertNotIn(
                        phrase,
                        text,
                        f"{path} must not instruct leaving an ambiguity in the "
                        "document in place of asking; it contradicts the "
                        f"ambiguity-is-never-minor clause (§5.1): {phrase!r}",
                    )


class OwningRepositoryTests(unittest.TestCase):
    """Issue #278: these workflows write documents and file issues, and neither
    is reversible in the wrong repository — `docs/document_workflow_findings.md`
    was created under a different repository solely because that was the active
    checkout. Every declared asset must therefore resolve an explicit
    `owner/repo` slug, a publication branch, and a local write root before its
    first durable write and before its first tracker mutation.

    Driven off the §2 declared-asset table rather than a second hardcoded list,
    so an asset added to the contract later is covered here the moment its row
    lands instead of only when someone remembers to extend this module.
    """

    def setUp(self):
        self.declared = parse_declared_assets()

    def asset_text(self, path):
        return (REPO_ROOT / path).read_text(encoding="utf-8")

    def test_every_declared_asset_states_the_ownership_step(self):
        for path in sorted(self.declared):
            with self.subTest(path=path):
                missing = missing_ownership_clauses(self.asset_text(path))
                self.assertEqual(
                    missing,
                    [],
                    f"{path} no longer states the ownership-resolution clauses "
                    f"docs/document-workflow-contract.md §8 pins: {missing}",
                )

    def test_removing_an_ownership_clause_from_an_asset_is_reported(self):
        # The check above is load-bearing rather than decorative: delete one
        # clause at a time from each asset and confirm exactly that key is
        # reported. canonical() is idempotent, so mutating its output is the
        # same planted-violation shape the boundary tests above use.
        for path in sorted(self.declared):
            asset = canonical(self.asset_text(path))
            for key, clause in OWNERSHIP_CLAUSES.items():
                with self.subTest(path=path, clause=key):
                    self.assertEqual(
                        missing_ownership_clauses(asset.replace(clause, "")), [key]
                    )

    def test_every_declared_asset_binds_its_write_root_to_the_resolved_owner(self):
        for path in sorted(self.declared):
            with self.subTest(path=path):
                missing = missing_ownership_bindings(self.asset_text(path))
                self.assertEqual(
                    missing,
                    [],
                    f"{path} states the ownership step but no longer performs it: "
                    f"{missing}",
                )

    def test_removing_an_ownership_binding_from_an_asset_is_reported(self):
        for path in sorted(self.declared):
            asset = normalized(self.asset_text(path))
            for binding in OWNERSHIP_SHELL_BINDINGS:
                with self.subTest(path=path, binding=binding):
                    self.assertEqual(
                        missing_ownership_bindings(asset.replace(binding, "")),
                        [binding],
                    )

    def test_no_declared_asset_falls_back_to_the_active_checkout(self):
        # The prose and the bindings above can both be present while the old
        # `DOCS_WT="$(git rev-parse --show-toplevel)"` fallback sits underneath
        # them, which is exactly the wrong-repository failure this issue
        # closes: an unrelated active checkout would still win at run time.
        for path in sorted(self.declared):
            with self.subTest(path=path):
                reintroduced = reintroduced_unscoped_roots(self.asset_text(path))
                self.assertEqual(
                    reintroduced,
                    [],
                    f"{path} resolves a write root from the active checkout "
                    f"rather than from $DOC_ROOT: {reintroduced}",
                )

    def test_reintroducing_the_active_checkout_fallback_is_reported(self):
        for path in sorted(self.declared):
            asset = normalized(self.asset_text(path))
            for form in OWNERSHIP_FORBIDDEN_SHELL:
                with self.subTest(path=path, form=form):
                    self.assertEqual(
                        reintroduced_unscoped_roots(f"{asset} {form}"), [form]
                    )

    def test_every_gh_invocation_binds_to_the_resolved_owner(self):
        # Requirement 4: the four processing assets carry the ten tracker
        # operations this issue scopes; the three capture assets carry only the
        # ownership block's own `gh repo view` calls, bound by $DOC_ROOT's own
        # remote. Both shapes are checked the same way, so a tracker mutation
        # added to a capture asset later cannot arrive unscoped.
        for path in sorted(self.declared):
            with self.subTest(path=path):
                unbound = unbound_gh_invocations(self.asset_text(path))
                self.assertEqual(
                    unbound,
                    [],
                    f"{path} runs a gh command bound to the shell's current "
                    f"directory rather than to $DOC_REPO: {unbound}",
                )

    def test_the_ten_scoped_tracker_operations_are_all_present(self):
        # Pins what the scan above actually recovers. Without this, deleting
        # every `gh issue` command would leave the check with nothing to find
        # and still pass.
        recovered = {}
        for path in sorted(self.declared):
            recovered[path] = len(
                re.findall(r"gh issue [a-z]", self.asset_text(path))
            )
        self.assertEqual(
            recovered,
            {
                "claude-plugin/plugins/kanban/commands/design-epic.md": 0,
                "claude-plugin/plugins/kanban/commands/process-design-doc.md": 2,
                "claude-plugin/plugins/kanban/commands/process-report.md": 3,
                "codex-plugin/plugins/kanban/skills/design-epic/SKILL.md": 0,
                "codex-plugin/plugins/kanban/skills/draft-report/SKILL.md": 0,
                "codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md": 2,
                "codex-plugin/plugins/kanban/skills/process-report/SKILL.md": 3,
            },
        )

    def test_reverting_a_tracker_command_to_an_unscoped_form_is_reported(self):
        # The negative case issue #278's acceptance names: drop the -R from one
        # tracker operation and the scan names that operation.
        for path in DISPOSITION_APPLYING_ASSETS:
            with self.subTest(path=path):
                reverted = self.asset_text(path).replace(
                    'gh issue create -R "$DOC_REPO" --body-file',
                    "gh issue create --body-file",
                    1,
                )
                self.assertEqual(
                    unbound_gh_invocations(reverted),
                    ["gh issue create --body-file"],
                )

    def test_an_unrelated_repo_scope_does_not_count_as_owner_bound(self):
        # $DOC_REPO specifically, not any -R: routing every mutation to a slug
        # resolved some other way is the failure this issue closes, not a
        # different spelling of the fix.
        self.assertEqual(
            unbound_gh_invocations('gh issue create -R "$REPO" --body-file x'),
            ['gh issue create -R "$REPO" --body-file x'],
        )
        self.assertEqual(
            unbound_gh_invocations('gh issue create -R "$DOC_REPO" --body-file x'),
            [],
        )

    def test_the_contract_states_the_order_the_assets_implement(self):
        # §8's own statements are pinned in CONTRACT_STATEMENTS above, which
        # the DocumentedBoundaryTests mutation test already drives one at a
        # time. This asserts the other direction the acceptance names: the
        # document cannot keep the resolution order while losing the
        # fail-closed rule that makes it safe.
        document = normalized(contract_text())
        for key in (
            "ownership-resolution-order",
            "ownership-fails-closed",
            "ownership-branch-fails-closed",
            "routing-is-not-the-lane",
            "section-7-classifies-kanban-only",
        ):
            with self.subTest(statement=key):
                self.assertIn(CONTRACT_STATEMENTS[key], document)
                self.assertEqual(
                    missing_contract_statements(
                        document.replace(CONTRACT_STATEMENTS[key], "")
                    ),
                    [key],
                )


class PublicationTests(unittest.TestCase):
    """Issue #237: a coordination document's persistence boundary was the local
    checkout, so an approved mutation survived only where the session ran. §9
    makes the processing assets publish the mutation in the same run, and keeps
    the drafting assets from publishing a document no §7 row classifies yet.

    Every rule is asserted in the packaged assets as well as in the contract
    prose describing them, because the assets are what an agent actually reads.
    """

    def asset_text(self, path):
        return (REPO_ROOT / path).read_text(encoding="utf-8")

    def test_the_two_asset_groups_partition_the_declared_set(self):
        # §9.1 splits the seven declared assets into the four that publish and
        # the three that never do. Without this, an asset added to neither
        # would be held to neither rule.
        self.assertEqual(
            set(PROCESSING_ASSETS) | set(DRAFTING_ASSETS), EXPECTED_DECLARED_PATHS
        )
        self.assertEqual(set(PROCESSING_ASSETS) & set(DRAFTING_ASSETS), set())

    def test_every_processing_asset_states_the_publication_step(self):
        for path in PROCESSING_ASSETS:
            with self.subTest(path=path):
                missing = missing_publication_clauses(self.asset_text(path))
                self.assertEqual(
                    missing,
                    [],
                    f"{path} no longer states the publication clauses "
                    f"docs/document-workflow-contract.md §9 pins: {missing}",
                )

    def test_removing_a_publication_clause_from_an_asset_is_reported(self):
        # The negative case issue #237's acceptance names: delete one clause at
        # a time from each processing asset and confirm exactly that key is
        # reported. canonical() is idempotent, so mutating its output is the
        # same planted-violation shape the other checks in this module use.
        for path in PROCESSING_ASSETS:
            asset = canonical(self.asset_text(path))
            for key, clause in PUBLICATION_CLAUSES.items():
                with self.subTest(path=path, clause=key):
                    self.assertEqual(
                        missing_publication_clauses(asset.replace(clause, "")), [key]
                    )

    def test_every_processing_asset_performs_the_publication(self):
        for path in PROCESSING_ASSETS:
            with self.subTest(path=path):
                missing = missing_publication_bindings(self.asset_text(path))
                self.assertEqual(
                    missing,
                    [],
                    f"{path} states the publication step but no longer performs "
                    f"it: {missing}",
                )

    def test_removing_a_publication_command_from_an_asset_is_reported(self):
        for path in PROCESSING_ASSETS:
            asset = normalized(self.asset_text(path))
            for binding in PUBLICATION_SHELL_BINDINGS:
                with self.subTest(path=path, binding=binding):
                    self.assertEqual(
                        missing_publication_bindings(asset.replace(binding, "")),
                        [binding],
                    )

    def test_no_processing_asset_still_forbids_publishing_outright(self):
        # The prose and the commands above can both be present while the
        # blanket "do not commit, push, or open a PR" bullet the publication
        # step replaced sits in the same file, which would tell an agent the
        # opposite of §9 in the boundaries section it reads last.
        for path in PROCESSING_ASSETS:
            with self.subTest(path=path):
                reintroduced = reintroduced_publication_prohibitions(
                    self.asset_text(path)
                )
                self.assertEqual(
                    reintroduced,
                    [],
                    f"{path} forbids the publication step §9 requires: "
                    f"{reintroduced}",
                )

    def test_reintroducing_the_blanket_prohibition_is_reported(self):
        for path in PROCESSING_ASSETS:
            asset = canonical(self.asset_text(path))
            for form in PUBLICATION_FORBIDDEN_PROSE:
                with self.subTest(path=path, form=form):
                    self.assertEqual(
                        reintroduced_publication_prohibitions(f"{asset} {form}"),
                        [form],
                    )

    def test_every_drafting_asset_states_the_novel_document_rule(self):
        for path in DRAFTING_ASSETS:
            with self.subTest(path=path):
                missing = missing_bootstrap_clauses(self.asset_text(path))
                self.assertEqual(
                    missing,
                    [],
                    f"{path} no longer states that its novel output remains "
                    "local until separately classified and published: "
                    f"{missing}",
                )

    def test_removing_the_bootstrap_rule_from_an_asset_is_reported(self):
        for path in DRAFTING_ASSETS:
            asset = canonical(self.asset_text(path))
            for key, clause in BOOTSTRAP_CLAUSES.items():
                with self.subTest(path=path, clause=key):
                    self.assertEqual(
                        missing_bootstrap_clauses(asset.replace(clause, "")), [key]
                    )

    def test_no_drafting_asset_performs_a_publication(self):
        # The other half of §9.1: the drafting assets say they never publish,
        # so none of them may carry the push that would.
        for path in DRAFTING_ASSETS:
            with self.subTest(path=path):
                self.assertNotIn(
                    "push origin", normalized(self.asset_text(path)), path
                )

    def test_the_contract_states_the_publication_rules_the_assets_implement(self):
        # The document half, asserted the way §8's is: the contract cannot keep
        # the eligibility rule while losing the safety rules that make direct
        # publication survivable.
        document = normalized(contract_text())
        for key in sorted(
            key for key in CONTRACT_STATEMENTS if key.startswith("publication-")
        ):
            with self.subTest(statement=key):
                self.assertIn(CONTRACT_STATEMENTS[key], document)
                self.assertEqual(
                    missing_contract_statements(
                        document.replace(CONTRACT_STATEMENTS[key], "")
                    ),
                    [key],
                )


class SharedStatusVocabularyTests(unittest.TestCase):
    """Requirement 5 of issue #229: the marker vocabulary is the compatibility
    surface between two runs, two brands, and two sessions, so it is asserted
    as raw, unescaped literals in the document and in the packaged assets
    themselves — not only in the prose describing them."""

    def test_the_document_states_every_exact_literal(self):
        self.assertEqual(missing_marker_literals(contract_text()), [])

    def test_dropping_a_literal_from_the_document_is_reported(self):
        text = contract_text()
        for literal in (*STATUS_MARKER_LITERALS, CHECKED_FORM, UNCHECKED_FORM):
            with self.subTest(literal=literal):
                mutated = text.replace(literal, "<removed>")
                self.assertEqual(missing_marker_literals(mutated), [literal])

    def test_every_declared_asset_states_the_marker_vocabulary(self):
        missing = []
        for path in sorted(EXPECTED_DECLARED_PATHS):
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            for literal in STATUS_MARKER_LITERALS:
                if literal not in text:
                    missing.append(f"{path}: missing exact status literal {literal!r}")
            if UNCHECKED_FORM not in text:
                missing.append(f"{path}: missing exact checklist form {UNCHECKED_FORM!r}")
        self.assertEqual(missing, [], "\n".join(missing))

    def test_every_disposition_applying_asset_states_the_checked_form(self):
        for path in DISPOSITION_APPLYING_ASSETS:
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            self.assertIn(
                CHECKED_FORM,
                text,
                f"{path} applies terminal dispositions and must state the exact "
                f"checklist form {CHECKED_FORM!r}",
            )

    def test_the_capture_workflows_never_write_a_checked_box(self):
        # §4: the design-capture pair and $draft-report apply no disposition,
        # so a checked box in a document they just produced would be a bug.
        # This is the other half of the assertion above, not decoration:
        # without it, the checked form could quietly spread to the workflows
        # that must not write one.
        for path in CAPTURE_ASSETS:
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            self.assertNotIn(
                CHECKED_FORM,
                text,
                f"{path} creates a document rather than processing one; it must "
                "not write a terminal checklist entry",
            )

    def test_every_declared_asset_is_a_capture_or_disposition_asset(self):
        # The two lists above partition the declared set. Without this, an
        # asset added to neither would be checked by neither rule.
        self.assertEqual(
            set(CAPTURE_ASSETS) | set(DISPOSITION_APPLYING_ASSETS),
            EXPECTED_DECLARED_PATHS,
        )
        self.assertEqual(
            set(CAPTURE_ASSETS) & set(DISPOSITION_APPLYING_ASSETS), set()
        )

    def test_both_process_report_variants_state_the_same_shared_surface(self):
        variants = {
            path: (REPO_ROOT / path).read_text(encoding="utf-8")
            for path in PROCESS_REPORT_ASSETS
        }
        differences = []
        for path, text in sorted(variants.items()):
            for literal in (*STATUS_MARKER_LITERALS, CHECKED_FORM, UNCHECKED_FORM):
                if literal not in text:
                    differences.append(f"{path}: missing shared literal {literal!r}")
            canonical_text = canonical(text)
            for boundary in PROCESS_REPORT_SHARED_BOUNDARIES:
                if boundary not in canonical_text:
                    differences.append(f"{path}: missing shared boundary {boundary!r}")
        self.assertEqual(
            differences,
            [],
            "the two process-report variants may differ in wording, but not on "
            "the surface docs/document-workflow-contract.md §4-§5 pins:\n"
            + "\n".join(differences),
        )

    def test_every_cross_brand_pair_states_the_same_marker_vocabulary(self):
        # §4 after issue #241: the portability surface is per pair, not per
        # workflow name, so the design pair is held to it exactly as
        # process-report already was.
        differences = []
        for name, paths in sorted(CROSS_BRAND_PAIRS.items()):
            for path in paths:
                text = (REPO_ROOT / path).read_text(encoding="utf-8")
                for literal in STATUS_MARKER_LITERALS:
                    if literal not in text:
                        differences.append(
                            f"{name}: {path} missing shared literal {literal!r}"
                        )
                if UNCHECKED_FORM not in text:
                    differences.append(
                        f"{name}: {path} missing shared form {UNCHECKED_FORM!r}"
                    )
        self.assertEqual(differences, [], "\n".join(differences))


if __name__ == "__main__":
    unittest.main()
