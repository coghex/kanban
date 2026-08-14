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
    # Issue #237's policy and issue #315's division of labour, in §9. What is
    # pinned here is the policy the assets must keep stating; the mechanism's
    # behavior is executed by tools/test_publish_coordination_doc.py rather
    # than asserted as prose, which is the whole point of the split.
    "publication-assets-are-the-processing-ones": (
        "The four processing assets — /process-report, $process-report, "
        "/process-design-doc, and $process-design-doc — publish the approved "
        "document mutation during the same invocation that applies it"
    ),
    "publication-drafting-assets-stay-local": (
        "The three drafting assets — /design-epic, $design-epic, and "
        "$draft-report — publish nothing at all"
    ),
    "publication-unmatched-fails-closed": (
        "pr-atomic is the fail-closed default for an unmatched path"
    ),
    "publication-is-kanban-only": (
        "coghex/kanban is the only repository with a coordination lane here"
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
    "publication-failure-has-three-states": (
        "reported with all three states rather than collapsed into one"
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
    "resolved-from-the-owning-write-root": (
        "resolve the helper from the already-resolved $doc_root — the local "
        "checkout of the owning repository"
    ),
    "never-a-personal-or-session-path": (
        "never from the session's own checkout, a personal path, or an inline "
        "fallback"
    ),
    "missing-helper-fails-closed": (
        "a helper that cannot be resolved there fails closed"
    ),
    "does-not-reimplement-the-mechanism": (
        "do not reimplement, precede, or compensate for any part of it"
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
    "the-helper-mints-the-scratch-path": (
        "never choose that path yourself"
    ),
    "a-shared-scratch-path-crosses-runs": (
        "a run reads the other's approved content and publishes it under its own "
        "document's name"
    ),
}

# The one command the assets carry. Anything more would be mechanism.
PUBLICATION_INVOCATION = (
    'python3 "$DOC_ROOT/tools/publish_coordination_doc.py" \\ '
    '--repo "$DOC_REPO" --branch "$DOC_BRANCH" --root "$DOCS_WT" \\ '
    '--path "$DOC_RELATIVE_PATH" --content "$APPROVED"'
)

# The scratch path is minted by the helper, never named by the asset. An asset
# that spells its own path reintroduces a cross-run collision the lock cannot
# see, because the content is written before any lock is taken.
PUBLICATION_SCRATCH_INVOCATION = (
    'APPROVED="$(python3 "$DOC_ROOT/tools/publish_coordination_doc.py" \\ '
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


def missing_bootstrap_clauses(text):
    """The §9.1 novel-document clauses `text` no longer states, by key."""
    asset = canonical(text)
    return sorted(
        key for key, clause in BOOTSTRAP_CLAUSES.items() if clause not in asset
    )


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
            set(PROCESSING_ASSETS) | set(DRAFTING_ASSETS), EXPECTED_DECLARED_PATHS
        )
        self.assertEqual(set(PROCESSING_ASSETS) & set(DRAFTING_ASSETS), set())

    def test_every_processing_asset_states_the_publication_policy(self):
        for path in PROCESSING_ASSETS:
            with self.subTest(path=path):
                missing = missing_publication_clauses(self.asset_text(path))
                self.assertEqual(
                    missing,
                    [],
                    f"{path} no longer states the publication policy "
                    f"docs/document-workflow-contract.md §9 pins: {missing}",
                )

    def test_removing_a_publication_clause_from_an_asset_is_reported(self):
        for path in PROCESSING_ASSETS:
            asset = canonical(self.asset_text(path))
            for key, clause in PUBLICATION_CLAUSES.items():
                with self.subTest(path=path, clause=key):
                    self.assertEqual(
                        missing_publication_clauses(asset.replace(clause, "")), [key]
                    )

    def test_every_processing_asset_invokes_the_helper(self):
        for path in PROCESSING_ASSETS:
            with self.subTest(path=path):
                self.assertIn(
                    PUBLICATION_INVOCATION,
                    normalized(self.asset_text(path)),
                    f"{path} must invoke the publication helper, resolved from the "
                    "owning repository's own write root",
                )

    def test_every_processing_asset_lets_the_helper_mint_the_scratch_path(self):
        for path in PROCESSING_ASSETS:
            with self.subTest(path=path):
                self.assertIn(
                    PUBLICATION_SCRATCH_INVOCATION,
                    normalized(self.asset_text(path)),
                    f"{path} must ask the helper for its content path rather than "
                    "naming one, which would collide across runs",
                )

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

    def test_no_drafting_asset_invokes_the_helper(self):
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
