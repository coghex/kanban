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
bundle from the post-#239 tracked Codex skills, and issue #328 closed the rest:
/draft-report was transposed the same way and note-problem entered as a pair in
both bundles at once. The declared set is ten assets, all five workflow names
are cross-brand pairs, and §3.5's Codex-only set is empty while the section
stays as a closure record.

Issue #328 also split two dimensions this module had been treating as one. An
asset's STATUS classification (may it write a checked box?) and its PUBLICATION
classification (does it hand the document to publish_coordination_doc.py?) used
to coincide, so CAPTURE_ASSETS and DRAFTING_ASSETS were the same tuple.
note-problem is the first asset for which they differ: it applies no
disposition, but it appends to a report that already exists and may already be
classified `coordination`, so it publishes in the same run without ever
acquiring a tracker transaction.

Issue #458 added §10, the one part of this contract about what happens after an
arc ends. §3.1's state machine has a single transition and no third value, so a
closed arc leaves its processing apparatus in place; that is right for an arc
document, whose apparatus is its record, and wrong for a specification document
that merely hosted the apparatus. ArcApparatusRemovalTests pins each of §10's
substantive clauses on its own key and pins §10.4's completion-report clause on
the two process-design-doc assets, with the other eight declared assets as the
negative control.

Discovery, frontmatter, and no-personal-path coverage for the same assets lives
in tools/test_claude_plugin.py and tools/test_codex_plugin.py; their
external-command surface is reconciled against the §4 dependency manifest by
tools/test_agent_workflow_contract.py.
"""

from __future__ import annotations

import re
import subprocess
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
    # Requirement 5 of issue #328. Membership here, not only a §2 row, is what
    # makes a note-problem file appearing in a bundle without a declared row
    # fail the §7 completeness check: the scan compares discovered workflow
    # files against this set to decide whether a row was owed.
    "note-problem",
    "process-report",
}

EXPECTED_DECLARED_PATHS = {
    "claude-plugin/plugins/kanban/commands/design-epic.md",
    "claude-plugin/plugins/kanban/commands/process-design-doc.md",
    "claude-plugin/plugins/kanban/commands/draft-report.md",
    "claude-plugin/plugins/kanban/commands/note-problem.md",
    "claude-plugin/plugins/kanban/commands/process-report.md",
    "codex-plugin/plugins/kanban/skills/design-epic/SKILL.md",
    "codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md",
    "codex-plugin/plugins/kanban/skills/draft-report/SKILL.md",
    "codex-plugin/plugins/kanban/skills/note-problem/SKILL.md",
    "codex-plugin/plugins/kanban/skills/process-report/SKILL.md",
}

# Empty since issue #328 transposed /draft-report from the tracked Codex skill.
# §3.5 keeps its standing rule and closure record rather than being deleted, so
# this stays as the enforcement point: a name added back here would have to
# come with a pinned source that never got one.
CODEX_ONLY_WORKFLOWS = ()

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
# Note that this is the STATUS dimension. Since issue #328 it no longer
# coincides with the publication dimension below: both note-problem variants
# are capture assets that nonetheless publish, because what they capture into
# is a document that already exists.
CAPTURE_ASSETS = (
    "claude-plugin/plugins/kanban/commands/design-epic.md",
    "claude-plugin/plugins/kanban/commands/draft-report.md",
    "claude-plugin/plugins/kanban/commands/note-problem.md",
    "codex-plugin/plugins/kanban/skills/design-epic/SKILL.md",
    "codex-plugin/plugins/kanban/skills/draft-report/SKILL.md",
    "codex-plugin/plugins/kanban/skills/note-problem/SKILL.md",
)

# The five cross-brand pairs in this contract, and therefore the only places a
# report or design document started by one brand can stop being resumable by
# the other. Every declared workflow is one since issue #328 closed the
# Codex-only set.
CROSS_BRAND_PAIRS = {
    "design-epic": (
        "claude-plugin/plugins/kanban/commands/design-epic.md",
        "codex-plugin/plugins/kanban/skills/design-epic/SKILL.md",
    ),
    "process-design-doc": (
        "claude-plugin/plugins/kanban/commands/process-design-doc.md",
        "codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md",
    ),
    "draft-report": (
        "claude-plugin/plugins/kanban/commands/draft-report.md",
        "codex-plugin/plugins/kanban/skills/draft-report/SKILL.md",
    ),
    "note-problem": (
        "claude-plugin/plugins/kanban/commands/note-problem.md",
        "codex-plugin/plugins/kanban/skills/note-problem/SKILL.md",
    ),
    "process-report": (
        "claude-plugin/plugins/kanban/commands/process-report.md",
        "codex-plugin/plugins/kanban/skills/process-report/SKILL.md",
    ),
}

PROCESS_REPORT_ASSETS = CROSS_BRAND_PAIRS["process-report"]

# The closing report separates two counts rather than reporting one. Deferred
# work with an unmet precondition is distinguished from work the next run can
# select, while a cleared deferral remains actionable even before that next run
# removes its marker. The multiple-cleared-deferral example pins the
# one-at-a-time edge: processing the first must not make the second disappear
# behind a zero-actionable summary. The terminality rule is pinned with them,
# because changing the report must not loosen what authorizes apparatus removal
# (§10) or what a tracker transaction resolves against.
DEFERRED_COUNTING_RULES = (
    "the findings still actionable, then the findings still deferred",
    "recheck every remaining [deferred] precondition",
    "deferred finding whose precondition now holds as actionable",
    "two deferred findings' preconditions have both cleared",
    "[deferred] still stays - [ ] and still is not terminal",
)

# §5's boundaries, asserted against both process-report variants as well as the
# document. Lowercase: compared against canonical() output, because the same
# rule legitimately starts a sentence in one variant and appears mid-sentence
# in the other.
PROCESS_REPORT_SHARED_BOUNDARIES = (
    # Issue #327: the report pair's own no-transaction case. A linked issue with
    # no approved comment mutates no tracker, and an empty plan is refused, so
    # an asset that did not say this would direct a run into a refusal.
    "an existing issue with no approved comment",
    "there is no tracker mutation and no transaction",
    "process exactly one finding",
    "stop for explicit approval",
    "only after explicit approval",
    "stop after this one finding",
    "the one-at-a-time rule is what keeps each disposition individually approved",
    *DEFERRED_COUNTING_RULES,
)

# Boundaries and asymmetries the document itself must keep stating. Compared
# against normalized() output, so reflowing a paragraph or bolding a phrase
# does not fail CI.
CONTRACT_STATEMENTS = {
    "haskell-parity-exclusion": "user-invoked and never spawned by Kanban's CLI",
    # Issue #328 closed the last of §3.5's asymmetry. The section is now a
    # completed closure record, and what the document must state is history
    # plus the standing rule — not the section's deletion, which would leave
    # the rule governing the next proposed asset looking arbitrary.
    "codex-only-set-is-empty": "The Codex-only set is empty",
    "codex-only-closure-is-the-record": (
        "This section stays as the closure record and the standing rule"
    ),
    "codex-only-rule-still-stands": (
        "must not grow a counterpart under this contract until a reviewed, "
        "pinned source exists to transpose from"
    ),
    "codex-only-is-declared": "a declared gap rather than an oversight",
    "closure-record-names-each-clearing-source": (
        "Each workflow that left the Codex-only set, with the pinned source "
        "that cleared it"
    ),
    "closure-record-covers-draft-report": (
        "codex-plugin/plugins/kanban/skills/draft-report/SKILL.md, the reviewed "
        "tracked skill issue #239 strengthened"
    ),
    "note-problem-never-was-codex-only": (
        "note-problem never appeared in this set"
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
    # Issue #237's policy and issue #315's division of labour, in §9. What is
    # pinned here is the policy the assets must keep stating; the mechanism's
    # behavior is executed by tools/test_publish_coordination_doc.py rather
    # than asserted as prose, which is the whole point of the split.
    "publication-assets-are-the-processing-ones": (
        "The four processing assets — /process-report, $process-report, "
        "/process-design-doc, and $process-design-doc — publish the approved "
        "document mutation during the same invocation that applies it"
    ),
    # Issue #328: the write side's second half publishes too, because its
    # subject is a report that already exists. Pinned separately from the
    # clause above so reclassifying it into the drafting rule — the one
    # mistake that would leave an appended observation unpublished forever —
    # fails with this key named.
    "publication-note-problem-publishes-too": (
        "The two observation-capture assets — /note-problem and $note-problem — "
        "publish the same way and under the same §9.2 eligibility"
    ),
    "publication-note-problem-has-no-transaction": (
        "they mutate no tracker, so they acquire no §9.6 transaction"
    ),
    "publication-drafting-assets-stay-local": (
        "The four drafting assets — /design-epic, $design-epic, "
        "/draft-report, and $draft-report — publish nothing at all"
    ),
    "publication-unmatched-fails-closed": (
        "pr-atomic is the fail-closed default for an unmatched path"
    ),
    # Issue #370 split one classification root into two. §7 still authorizes
    # Kanban's own lane and nothing else — the half requirement 6 protects —
    # while every other owner's lane is that owner's own declaration, which is
    # what makes a consuming repository reachable at all.
    "publication-section-7-authorizes-kanban-only": (
        "it authorizes a coordination lane for coghex/kanban and for no other "
        "repository"
    ),
    "publication-other-owners-declare-their-own": (
        "Every other owner declares its own lane in "
        "workflow.direct_publication_paths"
    ),
    "publication-kanban-never-consults-configuration": (
        "Kanban's own eligibility is decided from §7 as the publication tip "
        "itself carries it and never from configuration"
    ),
    "publication-no-declaration-is-not-an-error": (
        "A repository that declares nothing has no lane, and that is an "
        "ordinary outcome rather than an error"
    ),
    "publication-undeclared-still-applies-the-mutation": (
        'the run reports "status": "not-published" with document_written true'
    ),
    "publication-nothing-is-vendored-into-consumers": (
        "nothing is vendored into it, and it tracks no copy of the mechanism"
    ),
    "publication-unreadable-configuration-fails-closed": (
        "it fails closed before anything is written or published"
    ),
    # The packaging half of §9.4, which is the defect itself: the assets
    # shipped and the module they invoke did not.
    "publication-mechanism-ships-with-the-assets": (
        "The mechanism ships with the assets that invoke it"
    ),
    "publication-bundle-is-the-lookup-root": (
        "every declared asset resolves the copy in its own bundle"
    ),
    "publication-doc-root-is-not-the-lookup-root": (
        "$DOC_ROOT remains the validated checkout of the owning repository — "
        "where the module writes — and is never where the module is found"
    ),
    "publication-mechanism-ships-whole": (
        "a bundle carrying one carries all three or none"
    ),
    "publication-carries-one-mutation": (
        "A publication carries the single approved mutation to the one eligible "
        "document and nothing else"
    ),
    "publication-is-never-batched": (
        "never batched or deferred merely to reduce commit or push frequency"
    ),
    "publication-mechanism-is-one-module": (
        "tools/publish_coordination_doc.py is the whole mechanism, and the "
        "declared assets invoke it rather than restating it"
    ),
    "publication-caller-does-not-write": (
        "The caller renders the approved document; the module writes it"
    ),
    "publication-write-root-is-not-the-branch": (
        "The write root is ordinarily not the publication branch"
    ),
    "publication-is-reported-on-reachability": (
        "the module reports it only when the intended commit is reachable from "
        "the remote publication branch"
    ),
    "publication-preserves-outside-work": (
        "Nothing an outside process wrote is destroyed to make a publication "
        "possible"
    ),
    "publication-failure-has-three-states": (
        "reported with all three states rather than collapsed into one"
    ),
    # Issue #327: §9.6's tracker transaction, and §9.5's extension. What is
    # pinned here is the contract the four processing assets are held to below;
    # the mechanism's behavior is executed by tools/test_tracker_transaction.py
    # against temporary repositories, for the same reason §9.4's is.
    "transaction-covers-every-mutating-branch": (
        "Every tracker-mutating branch of those four publishes this way, the "
        "design pair's EPIC path included"
    ),
    "transaction-epic-path-hands-the-document-over": (
        "that path renders the complete approved document and hands it to "
        "tools/publish_coordination_doc.py in the same run, and never writes or "
        "stages the document itself"
    ),
    "transaction-every-mutation-is-a-step": (
        "Every approved tracker mutation is a checkpointed step, and a "
        "disposition is not one operation"
    ),
    "transaction-identity-is-not-an-issue-number": (
        "what a step records is the identity appropriate to its own kind of "
        "mutation, never an assumed issue number"
    ),
    "transaction-no-mutation-acquires-nothing": (
        "A disposition that mutates no tracker acquires no transaction"
    ),
    "transaction-linking-alone-mutates-nothing": (
        "neither does an Existing issue linked through process-report with no "
        "approved comment"
    ),
    "transaction-acquisition-is-create-only": (
        "Acquisition is atomic and create-only"
    ),
    "transaction-record-is-repository-shared": (
        "The record is repository-shared, not worktree-local"
    ),
    "transaction-record-is-what-resumes": (
        "The record is what a fresh invocation resumes from"
    ),
    "transaction-states-are-durable": (
        "intent-only — the record and its ordered plan exist and no step is "
        "confirmed"
    ),
    "transaction-confirmation-needs-the-begin-token": (
        "Only the run that performed a mutation may confirm it"
    ),
    "transaction-identity-must-agree-with-itself": (
        "A confirmed identity is the one its own kind of mutation has, and it "
        "must agree with itself"
    ),
    "transaction-transitions-are-compare-and-swap": (
        "Every transition is a compare-and-swap, and confirmations are never "
        "erased"
    ),
    "transaction-preflight-report-survives-failure": (
        "The preflight's report survives the preflight's own failure"
    ),
    "transaction-preflight-reports-both": (
        "The pre-mutation preflight reports both records"
    ),
    "transaction-preflight-keeps-its-caller-contract": (
        "the same clear and pending status vocabulary, and the same "
        "publication-tip binding the assets extract from it"
    ),
    "transaction-resumption-re-approves": (
        "A resuming run re-presents and re-approves; it does not replay"
    ),
    "transaction-ambiguity-is-never-automatic": (
        "An interrupted mutation is ambiguous, and ambiguity is never resolved "
        "automatically"
    ),
    "transaction-local-resolution-checks-the-applied-record": (
        "the module records the exact content it wrote whenever it applies a "
        "disposition to a document it declined to publish"
    ),
    "transaction-local-resolution-is-derived": (
        "That the document is one of those is derived rather than taken from "
        "the caller"
    ),
    "transaction-clearing-needs-a-terminal-entry": (
        "the recorded entry key's own terminal index entry on the publication "
        "branch"
    ),
    "transaction-entry-lives-in-the-status-index": (
        "it is looked for only in the document's own at-a-glance index"
    ),
    "transaction-entry-is-the-one-section-4-defines": (
        "the entry is a top-level task-list line marked exactly - [x]"
    ),
    "transaction-entry-key-is-parsed-not-searched-for": (
        "parsed from the line rather than found in it, so DW-3 and DW-30 are "
        "different entries"
    ),
    "transaction-clearing-is-bound-to-the-entry": (
        "Clearing is bound to the published entry, not to reachability"
    ),
    "transaction-mechanism-is-one-module": (
        "tools/tracker_transaction.py owns acquisition, every transition, and "
        "the resolution check"
    ),
    "transaction-fails-closed": (
        "There is no path on which an unreadable transaction reads as no "
        "transaction"
    ),
    "transaction-failure-report-adds-tracker-state": (
        "Tracker state is reported beside those three, never instead of them"
    ),
    # Issue #458: §10's arc-apparatus lifecycle. Every substantive clause is
    # pinned on its own key rather than as one paragraph-sized fragment,
    # because a §10 that still discusses the apparatus somewhere proves
    # nothing about the clause that left — and the clause that leaves decides
    # whether a removal deletes an arc document's ledger or leaves a
    # specification document carrying finished scaffolding forever.
    "apparatus-trigger-has-two-conditions": (
        "becomes removable only once both of these hold: the arc's umbrella "
        "epic is closed, and every entry in the document's processing ledger "
        "is terminal"
    ),
    "apparatus-terminal-is-section-4s-vocabulary": (
        "an entry is terminal when it carries [#N] or [no-issue]"
    ),
    "apparatus-deferred-and-unmarked-are-not-terminal": (
        "A [deferred] entry and an unmarked entry are both non-terminal"
    ),
    "apparatus-neither-condition-implies-the-other": (
        "Neither condition implies the other, and neither alone authorizes the "
        "removal"
    ),
    "apparatus-arc-document-is-defined-by-role": (
        "An arc document is identified by role rather than by path"
    ),
    "apparatus-arc-document-keeps-its-apparatus": (
        "An arc document keeps its apparatus, permanently and in place"
    ),
    "apparatus-arc-ledger-is-never-deleted": (
        "Nothing in this section deletes, truncates, or archives an arc "
        "document's ledger"
    ),
    "apparatus-specification-host-loses-it": (
        "A specification document that merely hosted the apparatus loses it"
    ),
    "apparatus-outliving-content-is-relocated": (
        "Content that outlives the arc is relocated to the numbered section "
        "that owns it rather than deleted with its wrapper"
    ),
    "apparatus-historical-bookkeeping-is-dropped": (
        "Purely historical bookkeeping already held by CHANGELOG.md or the "
        "GitHub Release is dropped rather than relocated"
    ),
    "apparatus-stranded-references-are-repaired": (
        "Every reference the removal would strand — inside the host document "
        "and outside it — is repaired in the same change"
    ),
    "apparatus-removal-is-an-ordinary-issue": (
        "The removal is separate follow-up work, authorized by an ordinary "
        "issue and delivered through the host document's own publication lane"
    ),
    "apparatus-processing-assets-never-perform-it": (
        "Neither /process-design-doc nor $process-design-doc removes, "
        "rewrites, files, or publishes it during a one-artifact invocation"
    ),
    "apparatus-completion-report-is-conditional": (
        "processing completion is observed from the ledger alone and may "
        "precede the umbrella epic's closure, the report states the "
        "disposition conditionally and never asserts the removal is already "
        "owed"
    ),
}

# Issue #315: what each processing asset must state about publication. These
# are policy and delegation, not mechanism — the sequence lives in
# tools/publish_coordination_doc.py and is executed by its own tests.
PUBLICATION_CLAUSES = {
    "publishes-in-the-same-run": "publish the approved mutation in this same run",
    "is-never-batched": (
        "never batched or deferred merely to reduce commit or push frequency"
    ),
    "caller-does-not-write-the-document": (
        "render the complete approved document and hand it over — do not write it "
        "yourself"
    ),
    "helper-is-the-only-writer": (
        "tools/publish_coordination_doc.py is the only writer of the document"
    ),
    # Issue #370 turned this clause around. It used to name $DOC_ROOT as the
    # lookup root, which forbade the one resolution that works in a repository
    # tracking no copy of the helper — the plugin's own versioned code. What
    # stayed forbidden is what it was ever protecting against: the session's
    # checkout, a personal path, and an inline reimplementation.
    "resolved-from-the-plugin-bundle": (
        "resolve the helper from this plugin's own bundle — the versioned copy "
        "installed beside these instructions"
    ),
    "never-a-personal-or-session-path": (
        "never from the session's own checkout, a personal path, or an inline "
        "fallback"
    ),
    "doc-root-is-not-the-lookup-root": (
        "$doc_root stays exactly what it was: the validated local checkout of "
        "the owning repository, which is where the helper writes and never "
        "where the helper itself is found"
    ),
    "owning-root-lookup-is-the-defect": (
        "these plugins install into repositories that track no copy of it, so "
        "resolving the helper from the owning repository fails closed in every "
        "repository but kanban's own"
    ),
    "missing-helper-fails-closed": (
        "a helper that cannot be resolved in the bundle still fails closed"
    ),
    "does-not-reimplement-the-mechanism": (
        "do not reimplement, precede, or compensate for any part of it"
    ),
    # Issue #526 split the publisher's declaration from the drainer's. Pin the
    # fail-closed explanation in every publishing asset so the old key cannot
    # silently return as the reason a consuming repository has no lane.
    "undeclared-direct-publication-path-is-not-published": (
        "whose workflow.direct_publication_paths does not cover it"
    ),
    "checks-the-changed-line-summary": (
        "an unintended rewrite of the rest of it changes the same single path a "
        "correct publication does, and the summary is what makes the difference "
        "visible"
    ),
    "reports-three-states-on-failure": (
        "whether the edit exists locally and in which worktree and path, whether a "
        "local publication commit exists and its id, and whether the remote "
        "publication branch contains it"
    ),
    "never-publishes-by-hand": "never publish by hand instead",
    "binds-content-to-the-tip": (
        "always pass it: it is what binds this content to the document state it "
        "was rendered from"
    ),
    "a-moved-tip-means-re-render": (
        "a tip-moved result means re-reading the document and rendering the "
        "disposition again rather than publishing what you have"
    ),
    "the-helper-mints-the-scratch-path": (
        "never choose that path yourself"
    ),
    "a-shared-scratch-path-crosses-runs": (
        "a run reads the other's approved content and publishes it under its own "
        "document's name"
    ),
    # Issue #385. `document_written` reads identically for a novel document
    # with no baseline, for a document somebody edited by hand, and for this
    # module's own unlanded predecessor — and the third is the one a second
    # disposition has to be able to continue over. An asset that stated only
    # the bare boolean would direct a run into the dead end that issue was
    # filed for, so the four named outcomes and the record that separates them
    # are pinned rather than left to prose.
    "write-outcome-names-the-write": (
        "write_outcome names which of the four cases the write was, rather than "
        "leaving document_written to stand for all of them"
    ),
    "continues-over-its-own-write": (
        "a working copy byte-identical to what the helper last applied locally "
        "is its own unlanded write, and the approved mutation is applied on top "
        "of it"
    ),
    "never-overwrites-a-foreign-working-copy": (
        "a working copy the helper did not write is never overwritten, and "
        "nothing is applied over it"
    ),
    "only-a-recorded-write-licenses-continuation": (
        'only "recorded" — with applied_ref naming that reference — lets a later '
        "run continue over the working copy or a transaction resolve from it"
    ),
    # Requirement 5: an applied disposition sits in one write root, and a run
    # that presented that as a finished journey is exactly how the observed
    # wedge went unnoticed for a whole disposition.
    "applied-is-not-landed": (
        "an applied mutation is not durable until the document's owner lands it "
        "on the publication branch"
    ),
    "names-the-write-root-and-the-blob": (
        "name the write root, the document path, and the preserved approved_blob "
        "rather than describing the run as complete on the branch"
    ),
}

# The one command the assets carry. Anything more would be mechanism.
PUBLICATION_INVOCATION = (
    'python3 "$PUBLISH_DOC" \\ '
    '--repo "$DOC_REPO" --branch "$DOC_BRANCH" --root "$DOCS_WT" \\ '
    '--path "$DOC_RELATIVE_PATH" --content "$APPROVED" \\ '
    '--expected-tip "$PREFLIGHT_TIP"'
)

# The scratch path is minted by the helper, never named by the asset. An asset
# that spells its own path reintroduces a cross-run collision the lock cannot
# see, because the content is written before any lock is taken.
# The binding has to be *extracted*, not merely mentioned: a `--expected-tip`
# that expands to nothing disabled the guard entirely and survived a review
# round, because the pin below only proved the flag was written down.
# tools/test_publish_coordination_doc.py executes these lines for real.
PUBLICATION_TIP_EXTRACTION = (
    'PREFLIGHT_TIP="$(PREFLIGHT="$PREFLIGHT" python3 -c \\ '
    '\'import json, os; print(json.loads(os.environ["PREFLIGHT"])["publication_tip"])\')"'
)

PUBLICATION_SCRATCH_INVOCATION = (
    'APPROVED="$(python3 "$PUBLISH_DOC" \\ '
    '--repo "$DOC_REPO" --root "$DOCS_WT" --path "$DOC_RELATIVE_PATH" \\ '
    '--new-content-file)"'
)

# The mechanism the assets must never carry again. Each of these is a step
# issue #315 moved into the module, and a step that took a review round to get
# right when it lived here.
PUBLICATION_FORBIDDEN_COMMANDS = (
    "commit-tree",
    "read-tree",
    "update-index",
    "update-ref",
    "merge-base",
    "hash-object",
    "push origin",
)

# Issue #327: the tracker-transaction policy every processing asset states.
# Policy and delegation again, not mechanism — acquisition, the transitions and
# the resolution check live in tools/tracker_transaction.py and are executed by
# tools/test_tracker_transaction.py.
TRANSACTION_CLAUSES = {
    "acquires-before-the-first-mutation": (
        "it is acquired before the first one runs"
    ),
    "acquisition-is-create-only": (
        "acquisition is create-only and atomic, so two runs that both saw a "
        "clear preflight cannot both proceed"
    ),
    "record-is-shared-across-worktrees": (
        "the record is shared across every linked worktree of this repository"
    ),
    "mechanism-is-the-module": (
        "tools/tracker_transaction.py is the whole mechanism"
    ),
    "does-not-reimplement-the-transaction": (
        "do not reimplement any part of it, and never edit a transaction "
        "reference by hand"
    ),
    "transaction-fails-closed": (
        "an unreadable transaction is never read as no transaction"
    ),
    "no-tracker-mutation-acquires-nothing": (
        "a disposition that mutates no tracker acquires nothing"
    ),
    "linking-alone-is-not-a-tracker-mutation": (
        "linking an issue that already exists mutates nothing by itself"
    ),
    "steps-are-begun-then-confirmed": (
        "begin a step before its external mutation runs and confirm it with the "
        "exact identity that mutation returned before the next step starts"
    ),
    "only-the-run-that-began-a-step-confirms-it": (
        "only the run that began a step may confirm it, and that token is the "
        "only evidence of having been it"
    ),
    "a-fresh-session-must-reconcile-instead": (
        "a fresh session cannot produce one and must reconcile instead"
    ),
    "a-label-is-bound-to-its-approved-values": (
        "both of which must be the exact approved values the plan carries as "
        "approved_name and approved_metadata"
    ),
    "an-identity-is-bound-to-what-was-approved": (
        "every one of those is bound to what was approved rather than merely "
        "well-shaped"
    ),
    "an-identity-names-its-own-repository": (
        "the url is parsed as a canonical github url in $doc_repo, an edit names "
        "its approved target, and a literal marker names the artifact the "
        "disposition links, which the plan states as marker_target"
    ),
    "an-identity-must-agree-with-itself": (
        "an identity is the one its own kind of mutation actually has, and it "
        "must agree with itself"
    ),
    "only-a-created-issue-contributes-a-token": (
        "nothing but a created issue or epic contributes a token the document "
        "must name"
    ),
    "identity-is-not-always-an-issue-number": (
        "not every step returns an issue number and a url, and the record does "
        "not pretend otherwise"
    ),
    "resumption-never-repeats-a-confirmed-step": (
        "its confirmed steps are verified and never repeated"
    ),
    "resumption-re-approves-each-remaining-step": (
        "re-present each remaining step's exact recorded target and payload and "
        "stop for explicit approval before executing it"
    ),
    "resumption-rebinds-to-the-fresh-tip": (
        "the binding this run publishes with is the publication_tip this "
        "preflight just reported, never the recorded one"
    ),
    "ambiguity-is-never-resolved-automatically": (
        "never retry it, adopt a candidate for it, advance past it, publish, or "
        "clear the record"
    ),
    "ambiguity-needs-one-exact-artifact": (
        "absent, mismatched, conflicting, or more than one plausible candidate "
        "leaves the record unresolved and stops the run"
    ),
    "a-similar-title-is-not-evidence": (
        "a similarly titled artifact is never sufficient evidence"
    ),
    "clearing-needs-the-terminal-entry": (
        "the recorded entry key's own terminal - [x] entry in the document's "
        "at-a-glance index on $doc_branch"
    ),
    "clearing-looks-only-in-the-index": (
        "it looks in that index alone, because a checked task in a finding's "
        "body, in a fenced example, or nested beneath the real entry is not the "
        "cursor"
    ),
    "an-unmarked-or-contradicted-entry-is-refused": (
        "an entry still - [ ], an incidental mention in prose, and a terminal "
        "entry carrying [no-issue] or [deferred] beside the link are each refused"
    ),
    "clearing-is-not-reachability": (
        "reachability proves a commit reached the branch; it proves nothing "
        "about whether that commit carried this disposition"
    ),
    "not-published-resolves-against-the-local-document": (
        "run the same verification against the applied local document with "
        "--source local --branch \"$doc_branch\""
    ),
    "local-resolution-is-the-modules-decision": (
        "whether the working tree is admissible at all is the module's "
        "decision, not yours"
    ),
    "local-resolution-checks-what-was-applied": (
        "a document the module never wrote, or one changed since it did, "
        "resolves nothing"
    ),
    "an-unwritten-document-stays-outstanding": (
        "when document_written is false, nothing carries the disposition "
        "anywhere: the record stays outstanding"
    ),
    "recovery-state-lives-in-the-record": (
        "the durable transaction record is where that state lives"
    ),
    # Issue #385: an outstanding record whose document can never be written was
    # only ever reported, and the way out — landing that document through the
    # owner's own lane — was in nobody's instructions. Naming it is what keeps a
    # stranded transaction from being left to somebody editing a reference.
    "a-stranded-transaction-has-a-bounded-recovery": (
        "recover the approved_blob, land the terminal document through the "
        "owner's ordinary out-of-band or pull-request lane, and then resolve "
        "the record with --source branch"
    ),
    "recovery-repeats-no-confirmed-mutation": (
        "never repeat a confirmed tracker mutation and never clear a reference "
        "by hand while that recovery is pending"
    ),
    "failure-reports-tracker-state-too": (
        "whether acquisition succeeded, the transaction state, each planned step "
        "and whether it is planned, ambiguous, or confirmed, every confirmed "
        "tracker identity, and the one recovery action that is permitted next"
    ),
}

# Requirement 16 of issue #327, and the reason it is a map rather than one
# phrase per asset: proving that a file mentions checkpointing somewhere proves
# nothing about the branch that skipped it. Every tracker-mutating branch gets
# its own clause, so deleting any single branch's checkpoint fails with that
# branch named.
#
# These three branches exist in all four processing assets.
TRANSACTION_BRANCH_CLAUSES = {
    "child-issue-creation": (
        "begin it before that call and confirm it with the number and url it "
        "returned"
    ),
    "child-issue-linking": (
        "linking an issue that already exists mutates nothing by itself"
    ),
    "approved-comment": (
        "begin it before the comment is posted and confirm it with the comment "
        "id and url"
    ),
}

# And these four only in the design pair, which is the only pair with an epic to
# create, adopt, label, or keep a checklist in. `process-report` reaches an epic
# by handing the arc to the design workflows, which mutates no tracker of its
# own — so requiring these of it would pin a branch it does not have.
TRANSACTION_EPIC_BRANCH_CLAUSES = {
    "epic-label-creation": (
        "begin it before gh label create -r \"$doc_repo\" and confirm it with "
        "the exact label name and metadata it created"
    ),
    "epic-creation": (
        "begin it before gh issue create -r \"$doc_repo\" and confirm it with "
        "the epic number and url"
    ),
    "epic-adoption-edit": (
        "confirm it with the target issue identity and the verified post-edit "
        "fingerprint"
    ),
    "umbrella-epic-checklist-edit": (
        "updating the epic's child checklist with the actual #n is a "
        "checkpointed step"
    ),
}

DESIGN_PROCESSING_ASSETS = (
    "claude-plugin/plugins/kanban/commands/process-design-doc.md",
    "codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md",
)

# The transaction commands the assets carry. Anything beyond invoking the module
# would be mechanism, exactly as it would be for publication.
TRANSACTION_INVOCATIONS = (
    '--acquire --approved --publication-tip "$PREFLIGHT_TIP" --plan -',
    '--begin-step 0 --approved',
    '--confirm-step 0 --begin-token "$BEGIN_TOKEN" --identity -',
    '--publication-pending',
    '--resolve --source branch --branch "$DOC_BRANCH"',
)

TRANSACTION_MODULE_INVOCATION = (
    'python3 "$TRACKER_TX" \\ '
    '--repo "$DOC_REPO" --root "$DOCS_WT" --path "$DOC_RELATIVE_PATH" \\ '
)

# Requirement 14: both process-design-doc variants used to direct a partially
# failed run to write the confirmed issue number into the design document,
# which contradicts the publication module being that document's only writer.
# Pinned as forbidden prose so it cannot come back beside the record that
# replaced it.
FORBIDDEN_RECOVERY_PROSE = (
    "record the confirmed issue number in the design document",
    # The EPIC path's own direct write, which is why that path could never reach
    # a resolved transaction: a document the asset pre-edited is refused by the
    # publication module as no longer matching the tip.
    "update only the epic ledger line to checked [#n] with",
)

# Requirement 1 of issue #327 as its amendment states it: the EPIC path takes
# the same preflight, transaction, and publication as a child disposition, and
# hands the document over rather than writing it.
EPIC_PATH_CLAUSES = {
    "routes-through-the-shared-sections": (
        "apply this entry through section 6 and publish it through section 7"
    ),
    "takes-the-same-preflight-and-transaction": (
        "it takes the same preflight, the same tracker transaction, and the "
        "same publication"
    ),
    "never-writes-the-document-itself": (
        "it never writes or stages the document itself"
    ),
}

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

PROCESSING_ASSETS = DISPOSITION_APPLYING_ASSETS

# The PUBLICATION dimension, which issue #328 split apart from the status
# dimension above. Before it, every capture asset was also a drafting asset and
# the two partitions coincided; note-problem is the first asset for which they
# do not. It writes no checked box (a capture asset) but its subject is an
# existing report that may already be classified `coordination`, so it takes
# §8's ownership resolution and §9's same-run publication rather than §9.1's
# novel-document rule. Classifying it as a drafting asset would leave an
# appended observation on a tracked coordination report permanently
# unpublished — a cursor only one checkout could resume, which is the failure
# §9 exists to prevent.
NOTE_ASSETS = (
    "claude-plugin/plugins/kanban/commands/note-problem.md",
    "codex-plugin/plugins/kanban/skills/note-problem/SKILL.md",
)

# Everything that hands a document to tools/publish_coordination_doc.py. The
# transaction assertions stay scoped to PROCESSING_ASSETS: note-problem
# mutates no tracker, so a transaction in it would be a record nothing could
# resolve.
PUBLISHING_ASSETS = PROCESSING_ASSETS + NOTE_ASSETS

# Issue #328's round-1 review blocker, pinned so it cannot come back. The
# personal note-problem source carried a "Create a missing report" path, which
# cannot survive §9.4's only-writer rule: publish_coordination_doc.py leaves
# `applied` False when the document is absent from the publication tip, so it
# declines to WRITE the document as well as to publish it. An asset promising to
# create the report would therefore leave the user with no report at all and the
# approved observation reachable only as a preserved blob. The boundary reads as
# a mere omission once that reason is forgotten, which is exactly why it is
# asserted rather than left to prose.
NOTE_NO_CREATE_CLAUSES = {
    "appends-to-an-existing-report": (
        "this workflow appends to a report that already exists"
    ),
    "a-missing-path-stops": (
        "when the resolved path holds no report, stop and say so"
    ),
    "helper-declines-to-write-an-absent-document": (
        "a document absent from the publication tip is one it declines to write "
        "as well as to publish"
    ),
    "promising-creation-leaves-no-report": (
        "would therefore leave the user with no report at all"
    ),
    "confirms-existence-before-investigating": (
        "confirm the report exists at the resolved path before investigating"
    ),
}

# Issue #328's round-2 review blocker. Dropping the creation path left the
# handoff still announcing capture unconditionally, which is false on exactly
# the path round 1 exposed: when the document is absent from the publication tip
# the helper writes nothing, so the report is unchanged. A workflow whose own
# closing report says "captured" there leaves the user believing a report holds
# an observation it does not — the one failure this asset's output can cause on
# its own, and one no other test in this module would catch, since every
# publication clause is about what the helper does rather than what the asset
# then claims.
NOTE_HANDOFF_CLAUSES = {
    "outcome-decides-the-claim": "let that decide what you claim",
    "no-write-means-not-captured": (
        "the report is unchanged and the observation is not captured"
    ),
    "no-write-forbids-the-noted-claim": (
        "do not describe the run as having noted the problem"
    ),
    "states-why-a-false-claim-matters": (
        "reporting capture here would leave the user believing a report holds "
        "an observation it does not"
    ),
}

# The heading that path shipped under. Forbidden outright in the note assets:
# the clauses above could all be satisfied while a creation section sat beside
# them contradicting every one.
NOTE_FORBIDDEN_CREATE_PROSE = "create a missing report"

# The assets that create a novel document and therefore state §9.1's rule that
# it stays local until separately classified and published.
DRAFTING_ASSETS = (
    "claude-plugin/plugins/kanban/commands/design-epic.md",
    "claude-plugin/plugins/kanban/commands/draft-report.md",
    "codex-plugin/plugins/kanban/skills/design-epic/SKILL.md",
    "codex-plugin/plugins/kanban/skills/draft-report/SKILL.md",
)

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

# Issue #458, requirement 4 as the canonical review amended it. §10.4 makes the
# completion report carry the disposition the host document then owes. Four
# clauses, because dropping any one of them turns a correct report into a wrong
# one: without the first the rule is unnamed at the only moment it becomes
# relevant; without the second the report reads as licence to strip an arc
# document's own ledger; without the third it asserts a removal is owed when
# only the ledger — not the umbrella epic — has finished; and without the
# fourth a processing run looks entitled to perform the removal itself, against
# §5's one-artifact boundary.
#
# Compared against canonical() output, like every other cross-asset clause
# here: the same rule may start a sentence in one brand's text and sit
# mid-sentence in the other's.
APPARATUS_COMPLETION_CLAUSES = {
    "names-the-rule": (
        "name the disposition the host document then owes under "
        "docs/document-workflow-contract.md §10"
    ),
    "specification-host-owes-the-removal": (
        "a specification document that merely hosted this arc's processing "
        "apparatus owes that apparatus's removal"
    ),
    "arc-document-keeps-its-apparatus": (
        "an arc document keeps its apparatus as the record"
    ),
    "conditional-on-epic-closure": (
        "do not assert the removal is already owed unless that closure is "
        "verified"
    ),
    "removal-is-separate-follow-up-work": (
        "removal is separate follow-up work authorized by an ordinary issue"
    ),
    "this-run-does-not-perform-it": (
        "this run does not perform, file, or publish it"
    ),
}

# The negative control for the clause above. Derived from the declared set
# rather than listed, so an eleventh asset joins the control set by being
# declared: an assertion loose enough to match every declared asset, or a
# selection that silently matched none, fails here rather than passing while
# asserting nothing.
APPARATUS_NEGATIVE_CONTROL_ASSETS = tuple(
    sorted(EXPECTED_DECLARED_PATHS - set(DESIGN_PROCESSING_ASSETS))
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


# Issue #370. The mechanism the publishing assets delegate to now ships with
# them, so the mechanism's *packaging* is part of this contract: an asset that
# installs into a repository tracking no copy of the helper is inert there, and
# that was true of all six for as long as they resolved it from $DOC_ROOT.
#
# `tools/` stays the source. Each bundle carries a byte-identical copy, held
# identical below, and the three-file set is one unit: the two mechanism
# modules load each other from beside themselves and the publication module
# loads the configuration reader from beside itself, so a bundle carrying part
# of the set carries none of it.
MECHANISM_SOURCE_DIR = REPO_ROOT / "tools"
BUNDLE_ROOTS = {
    "claude": REPO_ROOT / "claude-plugin" / "plugins" / "kanban",
    "codex": REPO_ROOT / "codex-plugin" / "plugins" / "kanban",
}
BUNDLED_MECHANISM = {
    "claude": "scripts",
    "codex": "skills/process-report/scripts",
}
MECHANISM_MODULES = (
    "publish_coordination_doc.py",
    "tracker_transaction.py",
    "kanban_config.py",
)

# Issue #574's janitor census is not a member of the set above: it has no
# `tools/` source, so there is nothing for it to be identical *to*. What it
# does share is the configuration reader -- it loads `kanban_config.py` from
# beside itself exactly as `publish_coordination_doc.py` does -- and the Codex
# bundle has no shared scripts root, so that bundle carries a second copy of
# the reader inside the janitor skill. Wherever the census ships, the module
# beside it is held to `tools/kanban_config.py` here, by the same rule and with
# the same repair as the process-report copy.
CENSUS_SCRIPTS_DIRS = {
    "claude": "scripts",
    "codex": "skills/janitor/scripts",
}
CENSUS_MODULE = "census.py"
CENSUS_CONFIG_MODULE = "kanban_config.py"

# `Path(__file__).resolve().parent / "<name>"` — how each mechanism module
# names a sibling it loads at run time. Read out of the source rather than
# listed, so a module that grows a fourth sibling dependency has to ship it in
# every bundle rather than only in tools/.
SIBLING_LOAD_RE = re.compile(
    r'Path\(__file__\)\.resolve\(\)\.parent\s*/\s*"(?P<name>[\w.]+\.py)"'
)

# What an asset actually runs: `python3 "$SOME_VAR"`. Deliberately not the
# helper's own basename — the point of this gate is that no asset names a
# filesystem location for the helper except through a lookup below.
HELPER_INVOCATION_RE = re.compile(r'python3 "\$([A-Z][A-Z0-9_]*)"')

# The two brands' bundle-local lookups, each capturing the bundle-relative path
# it resolves. Claude Code substitutes ${CLAUDE_PLUGIN_ROOT} to the plugin's own
# install location; Codex has no such substitution, so its skills search the
# $CODEX_HOME cache the way the PR-flow skills already locate review_pr.py.
BUNDLE_LOOKUP_RES = {
    "claude": re.compile(
        r'^(?P<var>[A-Z][A-Z0-9_]*)="\$\{CLAUDE_PLUGIN_ROOT\}/(?P<relative>[^"]+)"$',
        re.MULTILINE,
    ),
    "codex": re.compile(
        r'^(?P<var>[A-Z][A-Z0-9_]*)="\$\(find "\$\{CODEX_HOME:-\$HOME/\.codex\}'
        r'/plugins/cache" -path \'\*/kanban/\*/(?P<relative>[^\']+)\' '
        r'2>/dev/null \| head -n1\)"$',
        re.MULTILINE,
    ),
}

# The lookup root issue #370 removed. Named as forbidden text so the fix cannot
# be undone one asset at a time.
FORBIDDEN_OWNING_ROOT_LOOKUP = "$DOC_ROOT/tools/"


def bundle_of(relative_path):
    return "codex" if relative_path.startswith("codex-plugin/") else "claude"



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


def missing_no_create_clauses(text):
    """The note-problem no-creation clauses `text` no longer states, by key."""
    asset = canonical(text)
    return sorted(
        key for key, clause in NOTE_NO_CREATE_CLAUSES.items() if clause not in asset
    )


def missing_handoff_clauses(text):
    """The note-problem conditional-handoff clauses `text` no longer states."""
    asset = canonical(text)
    return sorted(
        key for key, clause in NOTE_HANDOFF_CLAUSES.items() if clause not in asset
    )


def missing_bootstrap_clauses(text):
    """The §9.1 novel-document clauses `text` no longer states, by key."""
    asset = canonical(text)
    return sorted(
        key for key, clause in BOOTSTRAP_CLAUSES.items() if clause not in asset
    )


def missing_transaction_clauses(text):
    """The §9.6 tracker-transaction clauses `text` no longer states, by key."""
    asset = canonical(text)
    return sorted(
        key for key, clause in TRANSACTION_CLAUSES.items() if clause not in asset
    )


def expected_branch_clauses(path):
    """The tracker-mutating branches `path` actually has. The design pair adds
    the four epic branches; `process-report` reaches an epic by handing the arc
    to those workflows, which mutates no tracker of its own."""
    clauses = dict(TRANSACTION_BRANCH_CLAUSES)
    if path in DESIGN_PROCESSING_ASSETS:
        clauses.update(TRANSACTION_EPIC_BRANCH_CLAUSES)
    return clauses


def missing_branch_clauses(text, path):
    """The tracker-mutating branches of `path` that `text` no longer
    checkpoints, by branch."""
    asset = canonical(text)
    return sorted(
        key
        for key, clause in expected_branch_clauses(path).items()
        if clause not in asset
    )


def reintroduced_recovery_prose(text):
    """Partial-failure guidance that has come back into an asset. Requirement 14
    of issue #327 replaced it with the durable record precisely because the
    publication module is the document's only writer."""
    asset = canonical(text)
    return [prose for prose in FORBIDDEN_RECOVERY_PROSE if prose in asset]


def reintroduced_mechanism(text):
    """Publication plumbing that has come back into an asset. The mechanism is
    tools/publish_coordination_doc.py's; an asset carrying any of it again is
    the regression issue #315 exists to prevent."""
    body = normalized(text)
    return [command for command in PUBLICATION_FORBIDDEN_COMMANDS if command in body]


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


def missing_apparatus_completion_clauses(text):
    """The §10.4 completion-report clauses `text` no longer states, by key."""
    asset = canonical(text)
    return sorted(
        key
        for key, clause in APPARATUS_COMPLETION_CLAUSES.items()
        if clause not in asset
    )


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

    def test_declared_assets_are_exactly_the_ten_packaged_workflows(self):
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
        # Every (brand, workflow) combination is declared since issue #328
        # closed the Codex-only set, so the plant is no longer a counterpart
        # appearing for a workflow §3.5 reserved to one brand. What the rule
        # still protects is a bundled workflow file with no §2 row of its own,
        # which is requirement 5 of #328: discovery is driven by
        # DOCUMENT_WORKFLOW_NAMES, so note-problem's membership in that set is
        # what makes these two files findable at all. Declaring the rows
        # without the name would leave this scan blind to them.
        with tempfile.TemporaryDirectory() as temp_dir:
            repo_root = Path(temp_dir)
            commands = repo_root / "claude-plugin" / "plugins" / "kanban" / "commands"
            skills = repo_root / "codex-plugin" / "plugins" / "kanban" / "skills"
            commands.mkdir(parents=True)
            (skills / "note-problem").mkdir(parents=True)
            (commands / "note-problem.md").write_text("---\n---\n", encoding="utf-8")
            # A workflow from another contract, to prove the scan is selective
            # rather than returning whatever it walks over.
            (commands / "solve.md").write_text("---\n---\n", encoding="utf-8")
            (skills / "note-problem" / "SKILL.md").write_text("x\n", encoding="utf-8")
            found = discovered_document_assets(
                claude_commands_root=commands,
                codex_skills_root=skills,
                repo_root=repo_root,
            )
        self.assertEqual(sorted(found), sorted(NOTE_ASSETS))
        self.assertEqual(
            sorted(found - (EXPECTED_DECLARED_PATHS - set(NOTE_ASSETS))),
            sorted(NOTE_ASSETS),
        )

    def test_note_problem_is_in_the_workflow_name_set(self):
        # Requirement 5 of issue #328, asserted directly: the row list and the
        # name set are separate surfaces, and only the second one decides
        # whether a bundled file was owed a row.
        self.assertIn("note-problem", DOCUMENT_WORKFLOW_NAMES)
        self.assertEqual(
            {row["invocation"][1:] for row in self.declared.values()},
            DOCUMENT_WORKFLOW_NAMES,
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

    def test_the_codex_only_set_is_empty(self):
        # Requirement 4 of issue #328. Kept as a positive assertion rather than
        # deleted with the set: a name added back here must come with the
        # pinned source §3.5 still requires, and this is where that shows up.
        self.assertEqual(CODEX_ONLY_WORKFLOWS, ())
        single_brand = sorted(
            name
            for name, brands in self.brands_by_workflow().items()
            if len(brands) < 2
        )
        self.assertEqual(
            single_brand,
            [],
            "docs/document-workflow-contract.md §3.5 declares no Codex-only "
            f"workflow, but these are declared for one brand: {single_brand}",
        )

    def brands_by_workflow(self):
        by_workflow = {}
        for row in self.declared.values():
            by_workflow.setdefault(row["invocation"][1:], set()).add(row["brand"])
        return by_workflow

    def test_the_five_cross_brand_pairs_are_declared_for_both_brands(self):
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


class ArcApparatusRemovalTests(unittest.TestCase):
    """Issue #458: §3.1 gives the design state machine one transition and no
    third value, so every arc that ends leaves its processing apparatus exactly
    where it was. On an arc document that is correct -- there the apparatus IS
    the record. On a specification document that merely hosted it, it is
    finished scaffolding wrapped around a live behavior contract:
    docs/design.md carried epic #268's for five days after that epic closed,
    and issues #428 and #429 took it out by hand as two separately reasoned
    changes with no stated rule to follow.

    §10 states that rule. Pinned here: each of its substantive clauses on its
    own key, the completion-report clause §10.4 puts on the two
    process-design-doc assets, and the negative control that keeps the asset
    assertion from passing vacuously.
    """

    def asset_text(self, path):
        return (REPO_ROOT / path).read_text(encoding="utf-8")

    def apparatus_keys(self):
        return sorted(
            key for key in CONTRACT_STATEMENTS if key.startswith("apparatus-")
        )

    def test_the_contract_states_every_apparatus_clause(self):
        keys = self.apparatus_keys()
        self.assertNotEqual(
            keys,
            [],
            "no §10 clause is pinned at all; the rule could be deleted "
            "outright and this module would stay green",
        )
        document = normalized(contract_text())
        for key in keys:
            with self.subTest(clause=key):
                self.assertIn(
                    CONTRACT_STATEMENTS[key],
                    document,
                    f"docs/document-workflow-contract.md §10 no longer states "
                    f"{key}",
                )

    def test_removing_any_single_apparatus_clause_is_reported(self):
        # Per clause, not per section: a §10 that still discusses the
        # apparatus somewhere proves nothing about the clause that left, and
        # the clause that leaves is what decides whether a removal strips an
        # arc document's ledger or abandons a specification document to
        # finished scaffolding.
        document = normalized(contract_text())
        for key in self.apparatus_keys():
            with self.subTest(clause=key):
                mutated = document.replace(CONTRACT_STATEMENTS[key], "")
                self.assertEqual(missing_contract_statements(mutated), [key])

    def test_both_process_design_doc_assets_state_the_completion_clause(self):
        for path in DESIGN_PROCESSING_ASSETS:
            with self.subTest(path=path):
                missing = missing_apparatus_completion_clauses(self.asset_text(path))
                self.assertEqual(
                    missing,
                    [],
                    f"{path} no longer names the disposition its completion "
                    "report owes under docs/document-workflow-contract.md "
                    f"§10.4: {missing}",
                )

    def test_removing_a_completion_clause_from_an_asset_is_reported(self):
        for path in DESIGN_PROCESSING_ASSETS:
            asset = canonical(self.asset_text(path))
            for key, clause in APPARATUS_COMPLETION_CLAUSES.items():
                with self.subTest(path=path, clause=key):
                    mutated = asset.replace(clause, "")
                    self.assertEqual(
                        missing_apparatus_completion_clauses(mutated), [key]
                    )

    def test_no_other_declared_asset_states_the_completion_clause(self):
        # The negative control. §10.4 puts the completion report on the design
        # processing pair alone, so a clause the other eight declared assets
        # also carry is one matching something other than what it names --
        # and an assertion that matched every asset would pass while asserting
        # nothing about either process-design-doc file.
        self.assertNotEqual(APPARATUS_NEGATIVE_CONTROL_ASSETS, ())
        for path in APPARATUS_NEGATIVE_CONTROL_ASSETS:
            asset = canonical(self.asset_text(path))
            for key, clause in APPARATUS_COMPLETION_CLAUSES.items():
                with self.subTest(path=path, clause=key):
                    self.assertNotIn(
                        clause,
                        asset,
                        f"{path} states the §10.4 completion-report clause "
                        f"{key}, which belongs to /process-design-doc and "
                        "$process-design-doc alone; either the clause is too "
                        "loose to identify them or this asset took on a "
                        "report it does not make",
                    )

    def test_the_control_set_is_exactly_the_rest_of_the_declared_set(self):
        # Keeps the control honest in the other direction: it is derived from
        # §2's declared paths, so it cannot quietly shrink to a set the clause
        # was chosen to avoid.
        self.assertEqual(
            set(APPARATUS_NEGATIVE_CONTROL_ASSETS) | set(DESIGN_PROCESSING_ASSETS),
            EXPECTED_DECLARED_PATHS,
        )
        self.assertEqual(
            set(APPARATUS_NEGATIVE_CONTROL_ASSETS) & set(DESIGN_PROCESSING_ASSETS),
            set(),
        )
        self.assertEqual(set(parse_declared_assets()), EXPECTED_DECLARED_PATHS)

    def test_neither_design_capture_asset_takes_on_the_removal(self):
        # §10.4 gives the removal to an ordinary issue, not to any declared
        # asset. process-design-doc is covered by the clause above; this is the
        # other pair that edits a design document and could plausibly grow it.
        for path in DESIGN_EPIC_ASSETS:
            with self.subTest(path=path):
                self.assertNotIn(
                    "processing apparatus", canonical(self.asset_text(path)), path
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
        # and still pass. The design pair names two more than it did before
        # issue #327: its EPIC path states the epic-creation call where the
        # ordered steps are listed and again where that branch's checkpoint
        # is stated, and both spellings are owner-bound.
        recovered = {}
        for path in sorted(self.declared):
            recovered[path] = len(
                re.findall(r"gh issue [a-z]", self.asset_text(path))
            )
        self.assertEqual(
            recovered,
            {
                "claude-plugin/plugins/kanban/commands/design-epic.md": 0,
                "claude-plugin/plugins/kanban/commands/draft-report.md": 0,
                "claude-plugin/plugins/kanban/commands/note-problem.md": 0,
                "claude-plugin/plugins/kanban/commands/process-design-doc.md": 4,
                "claude-plugin/plugins/kanban/commands/process-report.md": 3,
                "codex-plugin/plugins/kanban/skills/design-epic/SKILL.md": 0,
                "codex-plugin/plugins/kanban/skills/draft-report/SKILL.md": 0,
                "codex-plugin/plugins/kanban/skills/note-problem/SKILL.md": 0,
                "codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md": 4,
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
    """Issue #315. The four processing assets delegate the publication
    mechanism to tools/publish_coordination_doc.py and keep only the policy
    §9 states; the three drafting assets publish nothing at all.

    What is asserted here is that division. The mechanism's behavior is not
    prose to be pinned — tools/test_publish_coordination_doc.py executes it
    against temporary repositories, which is precisely what asserting it as
    prose could not do.
    """

    def asset_text(self, path):
        return (REPO_ROOT / path).read_text(encoding="utf-8")

    def test_the_two_asset_groups_partition_the_declared_set(self):
        self.assertEqual(
            set(PUBLISHING_ASSETS) | set(DRAFTING_ASSETS), EXPECTED_DECLARED_PATHS
        )
        self.assertEqual(set(PUBLISHING_ASSETS) & set(DRAFTING_ASSETS), set())

    def test_the_publication_and_status_partitions_no_longer_coincide(self):
        # Issue #328's structural claim, asserted rather than left implicit:
        # note-problem is a capture asset on the status dimension and a
        # publishing asset on the publication dimension. An implementation that
        # collapsed the two dimensions back together — the natural mistake,
        # since they were the same tuple before — fails here rather than
        # silently reclassifying note-problem into the novel-document rule.
        self.assertEqual(set(NOTE_ASSETS) - set(CAPTURE_ASSETS), set())
        self.assertEqual(set(NOTE_ASSETS) & set(DRAFTING_ASSETS), set())
        self.assertLessEqual(set(NOTE_ASSETS), set(PUBLISHING_ASSETS))
        self.assertNotEqual(set(CAPTURE_ASSETS), set(DRAFTING_ASSETS))

    def test_every_publishing_asset_states_the_publication_policy(self):
        for path in PUBLISHING_ASSETS:
            with self.subTest(path=path):
                missing = missing_publication_clauses(self.asset_text(path))
                self.assertEqual(
                    missing,
                    [],
                    f"{path} no longer states the publication policy "
                    f"docs/document-workflow-contract.md §9 pins: {missing}",
                )

    def test_removing_a_publication_clause_from_an_asset_is_reported(self):
        for path in PUBLISHING_ASSETS:
            asset = canonical(self.asset_text(path))
            for key, clause in PUBLICATION_CLAUSES.items():
                with self.subTest(path=path, clause=key):
                    self.assertEqual(
                        missing_publication_clauses(asset.replace(clause, "")), [key]
                    )

    def test_every_publishing_asset_invokes_the_helper(self):
        for path in PUBLISHING_ASSETS:
            with self.subTest(path=path):
                self.assertIn(
                    PUBLICATION_INVOCATION,
                    normalized(self.asset_text(path)),
                    f"{path} must invoke the publication helper, resolved from the "
                    "owning repository's own write root",
                )

    def test_every_publishing_asset_lets_the_helper_mint_the_scratch_path(self):
        for path in PUBLISHING_ASSETS:
            with self.subTest(path=path):
                self.assertIn(
                    PUBLICATION_SCRATCH_INVOCATION,
                    normalized(self.asset_text(path)),
                    f"{path} must ask the helper for its content path rather than "
                    "naming one, which would collide across runs",
                )

    def test_every_publishing_asset_extracts_the_tip_binding(self):
        for path in PUBLISHING_ASSETS:
            with self.subTest(path=path):
                body = normalized(self.asset_text(path))
                self.assertIn(
                    PUBLICATION_TIP_EXTRACTION,
                    body,
                    f"{path} must extract publication_tip from the preflight; a "
                    "binding that expands to nothing publishes with the "
                    "moved-tip check switched off",
                )
                self.assertIn('[ -n "$PREFLIGHT_TIP" ]', body, path)

    def test_no_asset_carries_the_publication_mechanism(self):
        # The regression this issue exists to prevent: the sequence creeping
        # back into the assets one command at a time.
        for path in EXPECTED_DECLARED_PATHS:
            with self.subTest(path=path):
                reintroduced = reintroduced_mechanism(self.asset_text(path))
                self.assertEqual(
                    reintroduced,
                    [],
                    f"{path} carries publication plumbing that belongs to "
                    f"tools/publish_coordination_doc.py: {reintroduced}",
                )

    def test_reintroducing_a_mechanism_command_is_reported(self):
        for command in PUBLICATION_FORBIDDEN_COMMANDS:
            with self.subTest(command=command):
                self.assertEqual(
                    reintroduced_mechanism(f"some prose then git {command} more"),
                    [command],
                )

    def test_every_drafting_asset_states_the_novel_document_rule(self):
        for path in DRAFTING_ASSETS:
            with self.subTest(path=path):
                missing = missing_bootstrap_clauses(self.asset_text(path))
                self.assertEqual(
                    missing,
                    [],
                    f"{path} no longer states that its novel output remains local "
                    f"until separately classified and published: {missing}",
                )

    def test_removing_the_bootstrap_rule_from_an_asset_is_reported(self):
        for path in DRAFTING_ASSETS:
            asset = canonical(self.asset_text(path))
            for key, clause in BOOTSTRAP_CLAUSES.items():
                with self.subTest(path=path, clause=key):
                    self.assertEqual(
                        missing_bootstrap_clauses(asset.replace(clause, "")), [key]
                    )

    def test_neither_note_asset_promises_to_create_a_missing_report(self):
        for path in NOTE_ASSETS:
            with self.subTest(path=path):
                missing = missing_no_create_clauses(self.asset_text(path))
                self.assertEqual(
                    missing,
                    [],
                    f"{path} no longer states that a missing report is drafting's "
                    "to create, not its own; the publication helper declines to "
                    f"write an absent document, so the report would never exist: {missing}",
                )
                self.assertNotIn(
                    NOTE_FORBIDDEN_CREATE_PROSE,
                    canonical(self.asset_text(path)),
                    f"{path} reintroduces a create-the-report path that "
                    "tools/publish_coordination_doc.py cannot carry out",
                )

    def test_neither_note_asset_claims_capture_when_nothing_was_written(self):
        for path in NOTE_ASSETS:
            with self.subTest(path=path):
                missing = missing_handoff_clauses(self.asset_text(path))
                self.assertEqual(
                    missing,
                    [],
                    f"{path} no longer conditions its handoff on what the helper "
                    "actually wrote, so it would report a captured observation "
                    f"against an unchanged report: {missing}",
                )

    def test_removing_a_handoff_clause_from_a_note_asset_is_reported(self):
        for path in NOTE_ASSETS:
            asset = canonical(self.asset_text(path))
            for key, clause in NOTE_HANDOFF_CLAUSES.items():
                with self.subTest(path=path, clause=key):
                    self.assertEqual(
                        missing_handoff_clauses(asset.replace(clause, "")), [key]
                    )

    def test_removing_a_no_create_clause_from_a_note_asset_is_reported(self):
        for path in NOTE_ASSETS:
            asset = canonical(self.asset_text(path))
            for key, clause in NOTE_NO_CREATE_CLAUSES.items():
                with self.subTest(path=path, clause=key):
                    self.assertEqual(
                        missing_no_create_clauses(asset.replace(clause, "")), [key]
                    )

    def test_only_the_drafting_assets_create_a_document(self):
        # The other half: creation lives with the assets that publish nothing
        # and therefore write their own file. Without this, moving the create
        # path into a publishing asset would fail no test.
        for path in DRAFTING_ASSETS:
            with self.subTest(path=path):
                self.assertEqual(missing_bootstrap_clauses(self.asset_text(path)), [])

    def test_no_drafting_asset_invokes_the_helper(self):
        # Scoped to DRAFTING_ASSETS alone: note-problem is a capture asset that
        # does invoke it, which is exactly the distinction this issue drew.
        for path in DRAFTING_ASSETS:
            with self.subTest(path=path):
                self.assertNotIn(
                    "publish_coordination_doc.py", self.asset_text(path), path
                )

    def test_the_contract_states_the_publication_policy(self):
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

    def test_the_contract_names_the_module_that_owns_the_mechanism(self):
        # §9.4's division of labour is the load-bearing part: a contract that
        # described the sequence again would invite an asset to restate it.
        self.assertIn(
            "tools/publish_coordination_doc.py", contract_text()
        )
        self.assertIn(
            "tools/test_publish_coordination_doc.py", contract_text()
        )


class TrackerTransactionContractTests(unittest.TestCase):
    """Issue #327. The four processing assets checkpoint every tracker mutation
    of an approved disposition and delegate the mechanism to
    tools/tracker_transaction.py, exactly as issue #315 made them delegate the
    publication sequence.

    The per-branch map is the load-bearing part. A check that merely found one
    record-step phrase per file would pass an asset whose EPIC path mutated the
    tracker with no transaction at all — which is precisely the hole this issue
    was filed for.
    """

    def asset_text(self, path):
        return (REPO_ROOT / path).read_text(encoding="utf-8")

    def test_every_processing_asset_states_the_transaction_policy(self):
        for path in PROCESSING_ASSETS:
            with self.subTest(path=path):
                missing = missing_transaction_clauses(self.asset_text(path))
                self.assertEqual(
                    missing,
                    [],
                    f"{path} no longer states the tracker-transaction policy "
                    f"docs/document-workflow-contract.md §9.6 pins: {missing}",
                )

    def test_removing_a_transaction_clause_from_an_asset_is_reported(self):
        for path in PROCESSING_ASSETS:
            asset = canonical(self.asset_text(path))
            for key, clause in TRANSACTION_CLAUSES.items():
                with self.subTest(path=path, clause=key):
                    self.assertEqual(
                        missing_transaction_clauses(asset.replace(clause, "")), [key]
                    )

    def test_every_processing_asset_checkpoints_every_branch_it_has(self):
        for path in PROCESSING_ASSETS:
            with self.subTest(path=path):
                missing = missing_branch_clauses(self.asset_text(path), path)
                self.assertEqual(
                    missing,
                    [],
                    f"{path} performs these tracker-mutating branches without a "
                    f"checkpointed step: {missing}",
                )

    def test_removing_any_single_branchs_checkpoint_is_reported(self):
        # The delete-one-at-a-time pass: each branch is named by its own key, so
        # a regression says which mutation stopped being checkpointed rather
        # than that the file changed.
        for path in PROCESSING_ASSETS:
            asset = canonical(self.asset_text(path))
            for key, clause in expected_branch_clauses(path).items():
                with self.subTest(path=path, branch=key):
                    self.assertEqual(
                        missing_branch_clauses(asset.replace(clause, ""), path), [key]
                    )

    def test_the_epic_branches_belong_to_the_design_pair_alone(self):
        # The other half of the map: `process-report` must not be held to
        # branches it does not have, and the design pair must not quietly lose
        # them by being reclassified.
        self.assertEqual(set(DESIGN_PROCESSING_ASSETS) - set(PROCESSING_ASSETS), set())
        self.assertEqual(
            set(TRANSACTION_BRANCH_CLAUSES) & set(TRANSACTION_EPIC_BRANCH_CLAUSES),
            set(),
        )
        for path in set(PROCESSING_ASSETS) - set(DESIGN_PROCESSING_ASSETS):
            with self.subTest(path=path):
                self.assertEqual(
                    set(expected_branch_clauses(path)),
                    set(TRANSACTION_BRANCH_CLAUSES),
                    path,
                )

    def test_the_design_pairs_epic_path_takes_the_shared_apply_and_publish(self):
        # Requirement 1 and its amendment: the EPIC path mutates the tracker
        # before the child path's preflight was ever reached, so it needs the
        # same preflight, the same transaction, and the same publication — and
        # it cannot write the document itself and still reach a resolved record.
        for path in DESIGN_PROCESSING_ASSETS:
            asset = canonical(self.asset_text(path))
            for key, clause in EPIC_PATH_CLAUSES.items():
                with self.subTest(path=path, clause=key):
                    self.assertIn(clause, asset, f"{path}: {key}")

    def test_every_processing_asset_invokes_the_transaction_module(self):
        for path in PROCESSING_ASSETS:
            body = normalized(self.asset_text(path))
            with self.subTest(path=path):
                self.assertIn(
                    TRANSACTION_MODULE_INVOCATION,
                    body,
                    f"{path} must invoke tools/tracker_transaction.py, resolved "
                    "from the owning repository's own write root",
                )
            for invocation in TRANSACTION_INVOCATIONS:
                with self.subTest(path=path, invocation=invocation):
                    self.assertIn(invocation, body, path)

    def test_no_non_processing_asset_touches_the_transaction(self):
        # The counterpart of the publication split: the four drafting assets
        # create no tracker items, and neither do the two note-problem
        # variants, so a transaction in any of them would be a record nothing
        # could ever resolve. note-problem is covered here rather than by the
        # drafting rule because it publishes — it is the one asset that takes
        # §9's publication without §9.6's transaction.
        for path in DRAFTING_ASSETS + NOTE_ASSETS:
            with self.subTest(path=path):
                self.assertNotIn(
                    "tracker_transaction.py", self.asset_text(path), path
                )

    def test_no_asset_writes_recovery_state_into_the_document(self):
        for path in PROCESSING_ASSETS:
            with self.subTest(path=path):
                reintroduced = reintroduced_recovery_prose(self.asset_text(path))
                self.assertEqual(
                    reintroduced,
                    [],
                    f"{path} directs a partially failed run to write recovery "
                    "state into the document, which the publication module alone "
                    f"writes: {reintroduced}",
                )

    def test_reintroducing_the_document_recovery_prose_is_reported(self):
        for prose in FORBIDDEN_RECOVERY_PROSE:
            with self.subTest(prose=prose):
                self.assertEqual(
                    reintroduced_recovery_prose(f"then {prose} and stop"), [prose]
                )

    def test_the_contract_states_the_transaction_policy(self):
        document = normalized(contract_text())
        for key in sorted(
            key for key in CONTRACT_STATEMENTS if key.startswith("transaction-")
        ):
            with self.subTest(statement=key):
                self.assertIn(CONTRACT_STATEMENTS[key], document)
                self.assertEqual(
                    missing_contract_statements(
                        document.replace(CONTRACT_STATEMENTS[key], "")
                    ),
                    [key],
                )

    def test_the_contract_names_the_module_that_owns_the_transaction(self):
        self.assertIn("tools/tracker_transaction.py", contract_text())
        self.assertIn("tools/test_tracker_transaction.py", contract_text())


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

    def test_only_the_processing_pair_states_the_deferred_counting_rule(self):
        # The other half of DEFERRED_COUNTING_RULES, on the pattern the
        # checked-form control above follows. A capture asset creates or
        # appends to a document and applies no disposition, so it reports no
        # dispositions and owes no counts; the rule appearing there would mean
        # a capture asset had started claiming to process. Without this, a
        # rule that spread to every asset would still satisfy the assertion
        # above while asserting nothing about who owes it.
        for path in CAPTURE_ASSETS:
            asset = canonical((REPO_ROOT / path).read_text(encoding="utf-8"))
            for rule in DEFERRED_COUNTING_RULES:
                self.assertNotIn(
                    rule,
                    asset,
                    f"{path} creates a document rather than processing one; it "
                    "must not state how a processing run counts its findings",
                )

    def test_removing_any_single_deferred_counting_rule_is_reported(self):
        # Each pin is load-bearing on its own: deleting one from a variant
        # must fail, so a regression names the half that was lost rather than
        # reporting that the file changed.
        for path in PROCESS_REPORT_ASSETS:
            asset = canonical((REPO_ROOT / path).read_text(encoding="utf-8"))
            for rule in DEFERRED_COUNTING_RULES:
                with self.subTest(path=path, rule=rule):
                    without = asset.replace(rule, "")
                    self.assertEqual(
                        [r for r in DEFERRED_COUNTING_RULES if r not in without],
                        [rule],
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


class BundledMechanismTests(unittest.TestCase):
    """Issue #370. The publishing assets ship with the mechanism they require.

    Issue #229 made the assets tracked plugin assets so a pull request could
    change and verify them, and stopped one level short: the assets shipped and
    the modules they invoke did not, so every one of them failed closed in the
    only repositories they exist to serve. What is asserted here is the level
    below — that whatever carries the mechanism travels with the asset, whole,
    and that no asset can go back to resolving it from the repository it is
    operating on.
    """

    def asset_text(self, path):
        return (REPO_ROOT / path).read_text(encoding="utf-8")

    def bundled_dir(self, bundle):
        return BUNDLE_ROOTS[bundle] / BUNDLED_MECHANISM[bundle]

    def test_every_bundle_ships_the_whole_mechanism(self):
        for bundle in sorted(BUNDLE_ROOTS):
            for name in MECHANISM_MODULES:
                with self.subTest(bundle=bundle, module=name):
                    self.assertTrue(
                        (self.bundled_dir(bundle) / name).is_file(),
                        f"the {bundle} bundle does not ship {name}, so every "
                        "asset that invokes it is inert wherever the bundle "
                        "installs",
                    )

    def test_every_bundled_copy_is_identical_to_its_tracked_source(self):
        # Duplicated rather than shared because each bundle is a self-contained
        # plugin asset (docs/agent-workflow-contract.md §3), exactly as the two
        # review coordinators are. Byte equality is what keeps three copies one
        # mechanism; tools/test_coordinator_parity.py bounds the coordinators'
        # one reviewed divergence, and this pair has none at all.
        for bundle in sorted(BUNDLE_ROOTS):
            for name in MECHANISM_MODULES:
                with self.subTest(bundle=bundle, module=name):
                    self.assertEqual(
                        (self.bundled_dir(bundle) / name).read_bytes(),
                        (MECHANISM_SOURCE_DIR / name).read_bytes(),
                        f"{bundle}'s {name} has drifted from tools/{name}; the "
                        "bundled copies are the same mechanism, not a fork. "
                        f"Repair: cp tools/{name} "
                        f"{(self.bundled_dir(bundle) / name).relative_to(REPO_ROOT)}",
                    )

    def census_scripts_dir(self, bundle):
        return BUNDLE_ROOTS[bundle] / CENSUS_SCRIPTS_DIRS[bundle]

    def test_every_bundle_ships_the_census_with_its_configuration_module(self):
        for bundle in sorted(BUNDLE_ROOTS):
            for name in (CENSUS_MODULE, CENSUS_CONFIG_MODULE):
                with self.subTest(bundle=bundle, module=name):
                    self.assertTrue(
                        (self.census_scripts_dir(bundle) / name).is_file(),
                        f"the {bundle} bundle does not ship {name} beside its "
                        "janitor census, so the census resolves no drainer "
                        "wherever the bundle installs",
                    )

    def test_the_census_configuration_copy_is_identical_to_its_tracked_source(self):
        for bundle in sorted(BUNDLE_ROOTS):
            with self.subTest(bundle=bundle):
                copy = self.census_scripts_dir(bundle) / CENSUS_CONFIG_MODULE
                self.assertEqual(
                    copy.read_bytes(),
                    (MECHANISM_SOURCE_DIR / CENSUS_CONFIG_MODULE).read_bytes(),
                    f"{bundle}'s census-side {CENSUS_CONFIG_MODULE} has "
                    f"drifted from tools/{CENSUS_CONFIG_MODULE}; the bundled "
                    "copies are the same mechanism, not a fork. Repair: cp "
                    f"tools/{CENSUS_CONFIG_MODULE} "
                    f"{copy.relative_to(REPO_ROOT)}",
                )

    def sibling_closure(self):
        """Every module the mechanism reaches by loading a sibling, transitively.

        Transitive rather than one level, because one level is exactly the
        distance this issue's defect travelled: the assets shipped, the module
        they load did not. A fourth module added under any of these would
        otherwise ship only as far as whoever remembered it.
        """
        reached, queue, edges = set(MECHANISM_MODULES), list(MECHANISM_MODULES), []
        while queue:
            name = queue.pop()
            source = (MECHANISM_SOURCE_DIR / name).read_text(encoding="utf-8")
            for sibling in sorted(set(SIBLING_LOAD_RE.findall(source))):
                edges.append((name, sibling))
                if sibling not in reached:
                    reached.add(sibling)
                    queue.append(sibling)
        return reached, edges

    def test_every_sibling_a_module_loads_ships_beside_it_everywhere(self):
        reached, edges = self.sibling_closure()
        # Not vacuous: the mutual publication/transaction pair and the
        # configuration reader are three real sibling loads.
        self.assertGreaterEqual(len(edges), 3, edges)
        for name, sibling in edges:
            for bundle in sorted(BUNDLE_ROOTS):
                with self.subTest(module=name, sibling=sibling, bundle=bundle):
                    self.assertTrue(
                        (self.bundled_dir(bundle) / sibling).is_file(),
                        f"tools/{name} loads {sibling} from beside itself, so "
                        f"the {bundle} bundle must ship it too",
                    )
        # And the set this module holds byte-identical has to be that closure,
        # so a newly reached module is copied *and* pinned rather than merely
        # present.
        self.assertEqual(
            sorted(reached),
            sorted(MECHANISM_MODULES),
            "MECHANISM_MODULES must name every module the bundled mechanism "
            "reaches, so each one is held identical to its tracked source",
        )

    def test_every_publishing_asset_resolves_its_helpers_from_its_own_bundle(self):
        for path in PUBLISHING_ASSETS:
            with self.subTest(path=path):
                bundle = bundle_of(path)
                text = self.asset_text(path)
                defined = {
                    match.group("var"): match.group("relative")
                    for match in BUNDLE_LOOKUP_RES[bundle].finditer(text)
                }
                invoked = set(HELPER_INVOCATION_RE.findall(text))
                self.assertTrue(invoked, f"{path} invokes no resolved helper")
                self.assertEqual(
                    sorted(invoked - set(defined)),
                    [],
                    f"{path} runs a helper it never resolved from its bundle",
                )
                for variable in sorted(invoked):
                    resolved = BUNDLE_ROOTS[bundle] / defined[variable]
                    self.assertTrue(
                        resolved.is_file(),
                        f"{path} resolves ${variable} to {defined[variable]}, "
                        f"which the {bundle} bundle does not ship",
                    )

    def test_no_declared_asset_looks_the_helper_up_under_the_owning_checkout(self):
        # The regression this issue closes, stated as forbidden text: the
        # owning repository is where the helper *writes*, and was never a place
        # it could be found outside Kanban's own tree.
        for path in sorted(EXPECTED_DECLARED_PATHS):
            with self.subTest(path=path):
                self.assertNotIn(
                    FORBIDDEN_OWNING_ROOT_LOOKUP,
                    self.asset_text(path),
                    f"{path} resolves a helper from the repository it is "
                    "operating on, which tracks no copy of it",
                )

    def test_reintroducing_the_owning_root_lookup_is_reported(self):
        # The planted violation, so the check above cannot pass by finding
        # nothing to look at.
        for path in PUBLISHING_ASSETS:
            with self.subTest(path=path):
                self.assertIn(
                    FORBIDDEN_OWNING_ROOT_LOOKUP,
                    self.asset_text(path).replace(
                        '"$PUBLISH_DOC"',
                        '"$DOC_ROOT/tools/publish_coordination_doc.py"',
                    ),
                )

    def test_each_brands_lookup_resolves_against_a_simulated_install(self):
        # The lookups are shell that has to work, not text that has to be
        # present. Both are driven against a fake install tree here, the way
        # tools/test_codex_plugin.py drives the coordinator's.
        for path in PUBLISHING_ASSETS:
            bundle = bundle_of(path)
            text = self.asset_text(path)
            for match in BUNDLE_LOOKUP_RES[bundle].finditer(text):
                relative = match.group("relative")
                with self.subTest(path=path, relative=relative):
                    with tempfile.TemporaryDirectory() as temp:
                        installed = self.plant(Path(temp), bundle, relative)
                        self.assertEqual(
                            self.resolve(Path(temp), bundle, relative), [str(installed)]
                        )

    def plant(self, temp, bundle, relative):
        """The helper as a provider's own installer lays it down."""
        if bundle == "claude":
            installed = temp / "plugins" / "kanban" / relative
        else:
            installed = (
                temp / "plugins" / "cache" / "kanban" / "kanban" / "1.0.0" / relative
            )
        installed.parent.mkdir(parents=True, exist_ok=True)
        installed.write_text("# stand-in for the installed helper\n", encoding="utf-8")
        return installed

    def resolve(self, temp, bundle, relative):
        """What the asset's own lookup finds there."""
        if bundle == "claude":
            # ${CLAUDE_PLUGIN_ROOT} is a substitution, so resolution is the
            # join itself; what is under test is that the joined path is the
            # one the installer laid down.
            candidate = temp / "plugins" / "kanban" / relative
            return [str(candidate)] if candidate.is_file() else []
        proc = subprocess.run(
            [
                "find",
                str(temp / "plugins" / "cache"),
                "-path",
                f"*/kanban/*/{relative}",
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return [line for line in proc.stdout.splitlines() if line]



if __name__ == "__main__":
    unittest.main()
