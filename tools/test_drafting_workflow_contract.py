"""Parity check for docs/drafting-workflow-contract.md.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Guards the packaging promise of issue #118: the issue-drafting and canonical
issue-review contracts are tracked plugin assets rather than owner-local
personal files, so a repository pull request can change and verify them.

Reconciles the responsibility matrix in docs/drafting-workflow-contract.md
against the tracked Claude and Codex plugin trees, so a declared asset cannot
vanish, an undeclared drafting or issue-review asset cannot appear, an
origin-marker literal cannot drift from what tools/approve_issues.py parses,
and the document cannot silently drop the Claude-only /draft-issues boundary
or the non-hunting, unpackaged arc-decomposition boundary.

Issue #240 added the eighth and ninth assets: the issue-rereview repair loop
both bundles now package. Its own contract (§3.6) is guarded here too — gate
state established through the canonical backend, the timeline read only through
that bundle's vendored trusted-comment helper, revision only after explicit
user signoff, resubmission that refuses an unchanged spec, and verdict
publication and label mutation left entirely to the backend — along with the
brand-specific routing each issue-review asset now owes it.

Issue #493 added the art policy PR #251 landed in the Claude assets alone: both
brands' issue-drafting assets must state that missing art is tracked work with
its own issue, PR, and user signoff, recorded as an explicit blocker rather than
resolved in the draft. Its solve-asset half lives in
tools/test_agent_workflow_contract.py.

Also guards issue #116's scope gate: the canonical document and the five
assets that perform or drive discretionary candidate discovery must state the
same gate and exemption rules, every gate instruction must be conditional on
a gate being present, and the gate must stay out of the issue-review
workflows.

Discovery, frontmatter, and no-personal-path coverage for the same assets
lives in tools/test_claude_plugin.py and tools/test_codex_plugin.py; their
external-command and user-scoped-path surface is reconciled against the §4
dependency manifest by tools/test_agent_workflow_contract.py.
"""

from __future__ import annotations

import re
import tempfile
import tomllib
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CONTRACT_PATH = REPO_ROOT / "docs" / "drafting-workflow-contract.md"

CLAUDE_COMMANDS_ROOT = REPO_ROOT / "claude-plugin" / "plugins" / "kanban" / "commands"
CODEX_SKILLS_ROOT = REPO_ROOT / "codex-plugin" / "plugins" / "kanban" / "skills"

# Workflow names that are drafting or issue-review workflows rather than the
# solve/PR-flow workflows Kanban's own CLI spawns. Any asset under either
# plugin whose workflow name is in this set must be declared in §2.
DRAFTING_WORKFLOW_NAMES = {
    "issue",
    "draft-issues",
    "autoissue",
    "issue-review",
    "issue-rereview",
}

EXPECTED_DECLARED_PATHS = {
    "claude-plugin/plugins/kanban/commands/issue.md",
    "claude-plugin/plugins/kanban/commands/draft-issues.md",
    "claude-plugin/plugins/kanban/commands/autoissue.md",
    "claude-plugin/plugins/kanban/commands/issue-review.md",
    "claude-plugin/plugins/kanban/commands/issue-rereview.md",
    "codex-plugin/plugins/kanban/skills/issue/SKILL.md",
    "codex-plugin/plugins/kanban/skills/autoissue/SKILL.md",
    "codex-plugin/plugins/kanban/skills/issue-review/SKILL.md",
    "codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md",
}

# The exact literals tools/approve_issues.py's ORIGIN_RE parses and the issue
# reviewers' instructions tell them to find. Raw and unescaped: an
# HTML-entity-escaped transcription would not match the parser.
CLAUDE_ORIGIN_MARKER = "<!-- issue-origin:claude -->"
CODEX_ORIGIN_MARKER = "<!-- issue-origin:codex -->"

ORIGIN_MARKER_BY_BRAND = {"claude": CLAUDE_ORIGIN_MARKER, "codex": CODEX_ORIGIN_MARKER}

# The drafting assets that actually create issues, and therefore must carry
# their brand's origin marker. The issue-review and issue-rereview workflows
# never create an issue, so they are deliberately exempt: issue-rereview edits
# an existing body and preserves whatever marker it already carries (§5), which
# requiring one of its own would rewrite rather than record.
ISSUE_CREATING_ASSETS = {
    "claude-plugin/plugins/kanban/commands/issue.md": "claude",
    "claude-plugin/plugins/kanban/commands/draft-issues.md": "claude",
    "claude-plugin/plugins/kanban/commands/autoissue.md": "claude",
    "codex-plugin/plugins/kanban/skills/issue/SKILL.md": "codex",
    "codex-plugin/plugins/kanban/skills/autoissue/SKILL.md": "codex",
}

# Issue-creating drafting assets that must state where a file may be written.
# These workflows file through `gh` and draft in chat, so their only filesystem
# write is the `--body-file` temp file; the rules below keep that write out of a
# checkout, and route a genuine in-repository write to the `docs-wip` worktree
# the PR drainer does not fast-forward and autostash.
#
# Both brands' issue-drafting assets are covered. The Codex `issue` skill writes
# a `--body-file` exactly as its Claude twin does, and
# docs/drafting-workflow-contract.md §2 declares the two as paired assets, so a
# rule stated in only one of them is the cross-brand drift
# tools/test_coordinator_parity.py exists to prevent for review_pr.py.
# Claude-only `/draft-issues` has no Codex counterpart to pair with.
#
# `autoissue` is exempt by delegation rather than by omission: §1 of both its
# assets runs `/issue` and states that it "does not replace either contract",
# so it inherits these rules instead of restating them. A restated copy there
# could drift from the one it delegates to.
# The negative control for WRITE_LOCATION_RULES: both brands' autoissue assets
# delegate to their /issue and must never restate these rules.
DELEGATING_ASSETS = (
    "claude-plugin/plugins/kanban/commands/autoissue.md",
    "codex-plugin/plugins/kanban/skills/autoissue/SKILL.md",
)

WRITE_LOCATION_ASSETS = (
    "claude-plugin/plugins/kanban/commands/issue.md",
    "claude-plugin/plugins/kanban/commands/draft-issues.md",
    "codex-plugin/plugins/kanban/skills/issue/SKILL.md",
)

# Lowercase: compared against canonical() output, so reflowing the paragraph or
# bolding a phrase does not fail CI. Each rule is operational rather than
# decorative -- dropping any one of them puts a file somewhere a drainer
# autostash or an unreachable publication lane can lose it.
WRITE_LOCATION_RULES = (
    # The only write these workflows make, and where it goes.
    "its one filesystem write is the --body-file temp file",
    "put that under the system temp directory, never inside a checkout",
    # Where a genuine in-repository write goes instead.
    "write it there rather than the primary checkout",
    # By branch, because a hard-coded path is wrong in every other checkout.
    "resolve it by branch, never a hard-coded path",
    # And the repositories that do not use the convention at all.
    "a repository with no docs-wip worktree does not use this convention",
)

# The issue-drafting assets that owe issue #493's art policy: the paired
# /issue and $issue surfaces §2 declares, and, since issue #840, Claude-only
# /draft-issues, which drafts to the same hand-off bar. PR #251 made missing art an explicit
# tracked blocker with a user-owned supply-or-generate decision and landed it in
# the Claude asset alone, adding no regression assertion, so nothing held the
# Codex twin to it and the two brands drifted apart on a product decision.
#
# Claude-only /draft-issues was left out until issue #840: §3.2 declares it the
# breadth workflow with no Codex counterpart, so it has no cross-brand split to
# close, but it files issues to the same hand-off bar and had silently dropped
# this policy, so a survey could file a texture-dependent issue with no blocker.
# #840 made it inherit the rule from /issue, and it is a member from there on.
#
# autoissue is exempt by delegation exactly as it is for WRITE_LOCATION_RULES,
# and is this tuple's negative control through DELEGATING_ASSETS.
ART_POLICY_ISSUE_ASSETS = (
    "claude-plugin/plugins/kanban/commands/issue.md",
    "claude-plugin/plugins/kanban/commands/draft-issues.md",
    "codex-plugin/plugins/kanban/skills/issue/SKILL.md",
)

# Lowercase: compared against canonical() output. Every fragment lies inside a
# single sentence of the rule, because canonical() collapses whitespace and
# drops `*` and backticks but keeps list markers and em dashes -- Claude states
# the rule as numbered item 7 and Codex as a `-` bullet, and §4 of issue #493
# preserves both, so a fragment spanning an item boundary could never match both
# brands at once.
#
# The fragments are distinctive to the art policy rather than bare anchor words.
# `texture` also appears in an unrelated example invocation in design-epic, and
# `placeholder` in note-problem, process-design-doc, and triage, in
# both brands; a tuple keyed on either single word would make the negative
# control below fail against assets that owe this policy nothing.
ART_POLICY_ISSUE_RULES = (
    # Art is tracked work rather than something the draft quietly resolves.
    "art is tracked work, not an implementation detail",
    # What counts as art, and naming each gap explicitly.
    "if the change needs a texture, icon, sprite, or animation that does not exist",
    "name each missing asset and what it is for",
    # Where the gap is recorded, and where it is not resolved.
    "record it as an explicit blocker in the issue body",
    "rather than resolving it in the draft",
    # Art's own tracked lane, signoff scoped per texture rather than once for
    # the arc, and whose decision the supply-or-generate method is.
    "art gets its own issue, its own pr, and the user's signoff on every texture",
    "they decide whether they supply the file or have it generated",
    # What the draft must instruct, and the condition that governs it: the
    # instruction is owed only where the user has not already chosen, so the
    # condition is asserted with it rather than separately.
    "unless they have already said which, the issue must tell the solver to stop and ask",
    # And the three non-resolutions.
    "never assume a placeholder, a reused asset, or a narrowed scope resolves the gap",
)

AUTOISSUE_ASSETS = {
    "claude-plugin/plugins/kanban/commands/autoissue.md": "/",
    "codex-plugin/plugins/kanban/skills/autoissue/SKILL.md": "$",
}

ISSUE_REVIEW_BACKEND_ASSETS = (
    "claude-plugin/plugins/kanban/commands/issue-review.md",
    "codex-plugin/plugins/kanban/skills/issue-review/SKILL.md",
)

# Issue #240's repair loop, keyed by the sigil its own brand invokes it with.
ISSUE_REREVIEW_ASSETS = {
    "claude-plugin/plugins/kanban/commands/issue-rereview.md": "/",
    "codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md": "$",
}

# Every packaged asset that resolves the canonical backend directly. The
# rereview assets do it twice — --check for gate state, --rereview to
# resubmit — so they are held to exactly the §6 resolution the gate is.
BACKEND_RESOLVING_ASSETS = ISSUE_REVIEW_BACKEND_ASSETS + tuple(
    sorted(ISSUE_REREVIEW_ASSETS)
)

# §3.6's four responsibilities, as prose both packaged rereview assets state.
# Lowercase: compared against canonical() output, so the same rule may start a
# sentence in one asset and sit mid-sentence in the other.
REREVIEW_PROTOCOL_RULES = (
    # Specification-only: this workflow is not a solver.
    "edit the issue specification only; do not solve the issue or change "
    "repository code",
    # Gate state comes from the backend, not from the label.
    "--check <issue>",
    # The repaired spec goes back through the backend's own rereview route.
    "--rereview <issue>",
    # Revision only after explicit signoff.
    "then stop and wait for explicit user approval. do not edit github on "
    "inferred or partial approval",
    "after explicit signoff, update only the approved title/body/labels",
    # An unchanged spec is never resubmitted.
    "do not rerun unchanged text; the backend refuses an unchanged spec "
    "fingerprint",
    # Publication and labels belong to the backend alone.
    "never independently post a review, manually add/remove reviewed:approve "
    "or reviewed:changes, or override a model verdict",
    "only the canonical backend manages verdict comments and labels",
    # Reviewer selection is the backend's (§6).
    "do not pin a reviewer model, reasoning effort, or display name for this "
    "run",
)

# The marker sentence §5 requires of a workflow that repairs rather than
# creates: preserve what is there, including nothing.
REREVIEW_MARKER_PRESERVATION = (
    "preserve the issue's existing <!-- issue-origin:claude --> or "
    "<!-- issue-origin:codex --> marker exactly. do not add, remove, or change "
    "provenance; an unmarked legacy issue stays unmarked"
)

# The exact helper lookup each rereview asset uses, matching the solve
# workflows issue #238 vendored these copies for. Asserted raw rather than
# canonicalized: ${CLAUDE_PLUGIN_ROOT} is a literal Claude Code substitutes,
# and case-folding it would let a lowercase misspelling pass.
CODEX_HELPER_LOOKUP = (
    'find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" '
    "-path '*/kanban/*/skills/solve/scripts/trusted_issue_spec.py' 2>/dev/null | head -n1"
)
CLAUDE_HELPER_REFERENCE = '"${CLAUDE_PLUGIN_ROOT}/scripts/trusted_issue_spec.py"'
REREVIEW_HELPER_REFERENCES = {
    "claude-plugin/plugins/kanban/commands/issue-rereview.md": CLAUDE_HELPER_REFERENCE,
    "codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md": CODEX_HELPER_LOOKUP,
}

# The unfiltered sources a rereview asset must forbid, so the helper is the
# only view of the timeline it has.
FORBIDDEN_COMMENT_SOURCES = (
    "never fall back to another comment source",
    "gh issue view",
    "the graphql api",
    "every other unfiltered source are forbidden here",
)

# Issue #116: the assets that perform or drive discretionary candidate
# discovery, and therefore carry the §4 scope gate. The autoissue assets are
# included because they drive discovery through their delegate.
SCOPE_GATE_ASSETS = (
    "claude-plugin/plugins/kanban/commands/issue.md",
    "claude-plugin/plugins/kanban/commands/draft-issues.md",
    "claude-plugin/plugins/kanban/commands/autoissue.md",
    "codex-plugin/plugins/kanban/skills/issue/SKILL.md",
    "codex-plugin/plugins/kanban/skills/autoissue/SKILL.md",
)

# The issue-review and issue-rereview workflows judge or repair an
# already-filed issue rather than hunting candidates, so the gate must not
# reach them (§4).
SCOPE_GATE_FREE_ASSETS = BACKEND_RESOLVING_ASSETS

# One rule per requirement of issue #116, asserted against every scope-gate
# asset AND the document, so the two can never state different gate or
# exemption rules. Lowercase: compared against canonical() output.
SCOPE_GATE_RULES = (
    # R1: what is and is not a gate.
    "only an explicit, current, normative scope or priority instruction",
    "descriptive roadmap or project-status prose is not a gate",
    # R2: absent-gate behavior is unchanged.
    "if no such instruction is present, there is no gate",
    "candidate selection, hunting sources, and reporting stay exactly as",
    # R3: the exemptions a gate never overrides.
    "crashes, regressions, data loss or corruption, broken ci gates, "
    "and security issues remain eligible",
    # R4: deferrals are reported, recognizable, attributed, and overridable.
    "report it rather than dropping it",
    "name the gate that defers it",
    "may override the deferral at signoff",
    # R4, all-deferred case: the override surface must still appear when the
    # gate leaves nothing to draft, or a one-candidate workflow would stop at
    # "nothing worth opening" and the user would never see the deferral.
    "is not a nothing-worth-opening result",
    "lift a deferral or confirm the stop",
    # R5: the gate changes selection, not drafting quality.
    "the gate changes selection only",
)

# The one-candidate hunters reach signoff only by producing a draft, so they
# are the assets where an all-deferred run could otherwise stop at "nothing
# worth opening" and strand the deferral. Both must condition that phrase.
ONE_CANDIDATE_ASSETS = (
    "claude-plugin/plugins/kanban/commands/issue.md",
    "codex-plugin/plugins/kanban/skills/issue/SKILL.md",
)

NOTHING_WORTH_OPENING_CONDITION = (
    "if a scope gate deferred candidates, present those at signoff "
    "instead of reporting nothing worth opening"
)

# The absent-gate guard, and the instructions that only make sense once a
# gate exists. Requirement 2 says every gate instruction must be conditional
# on a gate being present; stating the guard ahead of both is the mechanical
# form of that review criterion.
SCOPE_GATE_GUARD = "if no such instruction is present, there is no gate"
GATE_CONDITIONED_INSTRUCTIONS = (
    "a gate constrains discretionary new work only",
    "when a gate defers a discretionary candidate",
)

# The Kanban-managed install path every packaged issue-review surface must
# resolve (docs/agent-workflow-contract.md §3), and the pre-migration
# compatibility launcher none of them may reference.
BACKEND_ENV_OVERRIDE = "KANBAN_ISSUE_REVIEW_INSTALL_DIR"
BACKEND_DEFAULT_PATH = "Library/Application Support/kanban/issue-review"
# The installer-written discovery record every packaged issue-review surface
# resolves the backend through (issue #155), and the field it reads out of it.
# Naming the record is what lets a workflow find an install made with
# --install-dir; reconstructing the default could not.
BACKEND_RECORD_PATH = BACKEND_DEFAULT_PATH + "/config.json"
BACKEND_XDG_RECORD_PATH = ".local/share/kanban/issue-review/config.json"
BACKEND_RECORD_FIELD = "backend_path"
# Since issue #841 no asset embeds that resolution: each calls one bundled
# script, whose tools/ source holds the record paths and the precedence.
BACKEND_RESOLVER_NAME = "resolve_issue_review_backend.py"
BACKEND_RESOLVER_SOURCE = "tools/" + BACKEND_RESOLVER_NAME
DRAFTING_CONTRACT = "docs/drafting-workflow-contract.md"
FORBIDDEN_BACKEND_PATHS = ("~/work/approve-issues", "$HOME/work/")

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
    """normalized() plus case folding, for prose asserted across six files
    where the same rule legitimately starts a sentence in one and appears
    mid-sentence in another."""
    return normalized(text).lower()


def art_policy_findings(assets, rules):
    """Every (asset, rule) pair whose canonicalized text omits the rule.

    Factored out so the planted-removal check can drive the same predicate the
    presence check drives. A mutation test that only re-greps its own mutated
    string proves that str.replace removed a string, not that the enforced
    assertion notices the edit.
    """
    findings = []
    for path, text in assets.items():
        for rule in rules:
            if rule not in text:
                findings.append(f"{path}: missing art-policy rule {rule!r}")
    return findings


def parse_declared_assets():
    """Rows from the §2 machine-readable fence, keyed by repository-relative
    path. Anchored to the §2 heading so an unrelated ```text fence elsewhere
    in the document can never be parsed as the declared-asset list."""
    fence_match = SECTION_2_FENCE_RE.search(contract_text())
    if fence_match is None:
        raise AssertionError(
            "docs/drafting-workflow-contract.md has no ```text declared-asset "
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


def discovered_drafting_assets(
    claude_commands_root=CLAUDE_COMMANDS_ROOT,
    codex_skills_root=CODEX_SKILLS_ROOT,
    repo_root=REPO_ROOT,
):
    """Every drafting, issue-review, or issue-rereview asset actually present
    under either plugin, as repository-relative paths. Parameterized by root so
    the completeness tests below can be driven against a planted tree rather
    than only against the tree that already passes."""
    found = set()
    if claude_commands_root.is_dir():
        for command_md in sorted(claude_commands_root.glob("*.md")):
            if command_md.stem in DRAFTING_WORKFLOW_NAMES:
                found.add(command_md.relative_to(repo_root).as_posix())
    if codex_skills_root.is_dir():
        for skill_dir in sorted(codex_skills_root.iterdir()):
            if skill_dir.is_dir() and skill_dir.name in DRAFTING_WORKFLOW_NAMES:
                found.add((skill_dir / "SKILL.md").relative_to(repo_root).as_posix())
    return found


def missing_declared_assets(declared, repo_root=REPO_ROOT):
    """Declared paths absent from `repo_root`. Parameterized for the same
    reason: an absence check that only ever runs against a complete tree
    proves nothing about what it would report."""
    return sorted(path for path in declared if not (repo_root / path).is_file())


class DeclaredAssetTests(unittest.TestCase):
    def setUp(self):
        self.declared = parse_declared_assets()

    def test_declared_assets_are_exactly_the_nine_packaged_workflows(self):
        self.assertEqual(set(self.declared), EXPECTED_DECLARED_PATHS)

    def test_every_declared_asset_exists_in_the_tracked_tree(self):
        missing = missing_declared_assets(self.declared)
        self.assertEqual(
            missing,
            [],
            f"declared in docs/drafting-workflow-contract.md §2 but absent: {missing}",
        )

    def test_a_deleted_declared_asset_is_reported(self):
        # The absence check is load-bearing rather than decorative: point it at
        # a tree where one declared asset is gone and it names that asset. The
        # planted one is issue #240's Codex rereview skill, the newest row and
        # so the one a bundle-trimming edit would drop first.
        planted = "codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md"
        with tempfile.TemporaryDirectory() as temp_dir:
            repo_root = Path(temp_dir)
            for path in EXPECTED_DECLARED_PATHS - {planted}:
                target = repo_root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("---\nname: x\n---\n", encoding="utf-8")
            self.assertEqual(
                missing_declared_assets(self.declared, repo_root=repo_root), [planted]
            )

    def test_no_undeclared_drafting_or_issue_review_asset_exists(self):
        undeclared = sorted(discovered_drafting_assets() - set(self.declared))
        self.assertEqual(
            undeclared,
            [],
            "drafting/issue-review assets exist under a plugin without a §2 row "
            f"in docs/drafting-workflow-contract.md: {undeclared}",
        )

    def test_an_undeclared_asset_added_to_either_plugin_is_reported(self):
        # The realistic regression: a Codex $draft-issues appearing beside the
        # Claude-only breadth workflow (§3.2), or a rereview asset landing in
        # one bundle without a §2 row. A workflow outside this contract's
        # names — solve — must still not be reported, or the check would drag
        # every packaged asset into §2.
        with tempfile.TemporaryDirectory() as temp_dir:
            repo_root = Path(temp_dir)
            commands = repo_root / "claude-plugin" / "plugins" / "kanban" / "commands"
            skills = repo_root / "codex-plugin" / "plugins" / "kanban" / "skills"
            commands.mkdir(parents=True)
            (skills / "draft-issues").mkdir(parents=True)
            (skills / "issue-rereview").mkdir(parents=True)
            (commands / "issue-rereview.md").write_text("---\n---\n", encoding="utf-8")
            (commands / "solve.md").write_text("---\n---\n", encoding="utf-8")
            (skills / "draft-issues" / "SKILL.md").write_text("x\n", encoding="utf-8")
            (skills / "issue-rereview" / "SKILL.md").write_text("x\n", encoding="utf-8")
            found = discovered_drafting_assets(
                claude_commands_root=commands,
                codex_skills_root=skills,
                repo_root=repo_root,
            )
        self.assertEqual(
            sorted(found - EXPECTED_DECLARED_PATHS),
            ["codex-plugin/plugins/kanban/skills/draft-issues/SKILL.md"],
        )
        # Non-vacuity for the planted pair: the two declared rereview assets
        # were discovered, they simply have §2 rows.
        self.assertLessEqual(set(ISSUE_REREVIEW_ASSETS), found)

    def test_declared_brand_and_invocation_match_the_assets_own_plugin_and_name(self):
        for path, row in sorted(self.declared.items()):
            expected_prefix = "claude-plugin/" if row["brand"] == "claude" else "codex-plugin/"
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
            self.assertIn(workflow_name, DRAFTING_WORKFLOW_NAMES, path)
            stem = Path(path).parent.name if path.endswith("/SKILL.md") else Path(path).stem
            self.assertEqual(
                stem,
                workflow_name,
                f"{path} does not implement its declared invocation {row['invocation']!r}",
            )

    def test_draft_issues_is_declared_for_claude_only(self):
        draft_issues_rows = [
            row for row in self.declared.values() if row["invocation"].endswith("draft-issues")
        ]
        self.assertEqual(len(draft_issues_rows), 1)
        self.assertEqual(draft_issues_rows[0]["brand"], "claude")
        self.assertFalse(
            (CODEX_SKILLS_ROOT / "draft-issues").exists(),
            "draft-issues is a Claude-only breadth workflow; the Codex plugin must not package it",
        )

    def test_epic_is_packaged_in_neither_plugin(self):
        self.assertFalse(
            (CLAUDE_COMMANDS_ROOT / "epic.md").exists(),
            "arc decomposition belongs to the design pipeline; no epic command is packaged",
        )
        self.assertFalse(
            (CODEX_SKILLS_ROOT / "epic").exists(),
            "arc decomposition belongs to the design pipeline; no epic skill is packaged",
        )


class OriginMarkerTests(unittest.TestCase):
    """The origin markers are the one drafting behavior with a repo-side
    parser: tools/approve_issues.py's ORIGIN_RE consumes them to route an
    issue to the opposite agent, and the issue reviewers' instructions tell
    them to find them. They are asserted as raw, unescaped literals so an
    HTML-entity-escaped transcription fails CI."""

    def test_approve_issues_still_parses_the_asserted_literals(self):
        origin_re_source = (REPO_ROOT / "tools" / "approve_issues.py").read_text(encoding="utf-8")
        match = re.search(r"^ORIGIN_RE = re\.compile\((.*)\)$", origin_re_source, re.MULTILINE)
        self.assertIsNotNone(match, "tools/approve_issues.py no longer defines ORIGIN_RE")
        origin_re = re.compile(r"<!--\s*issue-origin:(claude|codex)\s*-->", re.IGNORECASE)
        self.assertIsNotNone(origin_re.search(CLAUDE_ORIGIN_MARKER))
        self.assertIsNotNone(origin_re.search(CODEX_ORIGIN_MARKER))

    def test_the_document_states_both_exact_marker_literals(self):
        text = contract_text()
        for marker in (CLAUDE_ORIGIN_MARKER, CODEX_ORIGIN_MARKER):
            self.assertIn(
                marker,
                text,
                f"docs/drafting-workflow-contract.md must state the exact literal {marker}",
            )

    def test_every_issue_creating_asset_carries_its_brands_marker(self):
        for path, brand in sorted(ISSUE_CREATING_ASSETS.items()):
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            self.assertIn(
                ORIGIN_MARKER_BY_BRAND[brand],
                text,
                f"{path} must instruct emitting the exact literal {ORIGIN_MARKER_BY_BRAND[brand]}",
            )

    def test_no_asset_carries_the_opposite_brands_marker(self):
        other = {"claude": CODEX_ORIGIN_MARKER, "codex": CLAUDE_ORIGIN_MARKER}
        for path, brand in sorted(ISSUE_CREATING_ASSETS.items()):
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            self.assertNotIn(
                other[brand],
                text,
                f"{path} is a {brand} asset but references the opposite brand's origin marker",
            )


class DocumentedBoundaryTests(unittest.TestCase):
    """§3.2's Claude-only /draft-issues boundary and §3.5's non-hunting,
    unpackaged arc-decomposition boundary are load-bearing: they are the
    reason the Codex plugin's declared set is smaller than the Claude
    plugin's, and the reason an epic asset is absent from both. Asserted
    against whitespace-normalized, emphasis-stripped text so reflowing a
    paragraph does not fail CI."""

    def setUp(self):
        self.text = normalized(contract_text())

    def test_document_states_the_claude_only_draft_issues_boundary(self):
        self.assertIn("packaged for the Claude brand only", self.text)
        self.assertIn("there is deliberately no $draft-issues Codex skill", self.text)

    def test_document_states_the_non_hunting_unpackaged_epic_boundary(self):
        self.assertIn("Arc decomposition plans a user-specified feature arc", self.text)
        self.assertIn("It is not a discretionary candidate-hunting workflow", self.text)
        self.assertIn("not packaged in either plugin", self.text)

    def test_document_distinguishes_one_candidate_drafting_from_breadth(self):
        self.assertIn("exactly one issue per run", self.text)
        self.assertIn("breadth counterpart", self.text)

    def test_document_states_the_autoissue_sequence_and_no_second_confirmation(self):
        self.assertIn("draft -> signoff -> create -> canonical review", self.text.replace("→", "->"))
        self.assertIn("not ask for a second confirmation", self.text)
        self.assertIn("Stops without review", self.text)

    def test_document_states_the_issue_review_readiness_gate_role(self):
        self.assertIn("direct canonical readiness-gate workflows", self.text)

    def test_document_states_the_haskell_parity_exclusion(self):
        self.assertIn("user- or daemon-invoked, never spawned by Kanban's own CLI", self.text)


class WriteLocationTests(unittest.TestCase):
    """Where an issue-drafting workflow is allowed to put a file.

    These workflows create issues through `gh` and present drafts in chat, so
    the only file they write is the `--body-file` temp file. Nothing said so,
    and nothing said where a file belonged if a step ever did need one, which
    is how a findings report reached a checkout no publication mechanism could
    read and how uncommitted work reached the primary checkout the PR drainer
    fast-forwards and autostashes after every merge.

    There is no behavioral prompt-testing harness here, so the reviewable
    property is the asset text itself, exactly as ScopeGateTests treats issue
    #116's gate rules.
    """

    def setUp(self):
        self.assets = {
            path: canonical((REPO_ROOT / path).read_text(encoding="utf-8"))
            for path in WRITE_LOCATION_ASSETS
        }

    def test_every_write_location_asset_states_every_rule(self):
        missing = []
        for path in WRITE_LOCATION_ASSETS:
            for rule in WRITE_LOCATION_RULES:
                if rule not in self.assets[path]:
                    missing.append(f"{path}: missing write-location rule {rule!r}")
        self.assertEqual(missing, [], "\n".join(missing))

    def test_dropping_a_rule_from_an_asset_is_reported(self):
        # The property under test is that removal fails, not merely that the
        # text happens to be present today. Each rule is deleted in turn from a
        # copy of each asset and the same check must catch it, so a future edit
        # cannot quietly drop one and stay green.
        for path in WRITE_LOCATION_ASSETS:
            for rule in WRITE_LOCATION_RULES:
                mutated = self.assets[path].replace(rule, "")
                self.assertNotIn(
                    rule,
                    mutated,
                    f"{path}: {rule!r} survived its own removal, so this check "
                    "would not notice the edit",
                )

    def test_the_rules_are_not_vacuous(self):
        # A rule that matched every asset in the tree would pass the check above
        # while asserting nothing. Both autoissue assets delegate to their
        # brand's /issue and must not restate these rules, so they are the
        # negative control that keeps the tuple meaningful.
        #
        # The failure is reported as a plain list rather than through assertIn:
        # these assets canonicalize to thousands of characters, and a membership
        # assertion dumps the whole text into the report, burying the one line
        # that says what to do about it.
        offenders = []
        for path in DELEGATING_ASSETS:
            text = canonical((REPO_ROOT / path).read_text(encoding="utf-8"))
            for rule in WRITE_LOCATION_RULES:
                if rule in text:
                    offenders.append(
                        f"{path} now states {rule!r}; add it to "
                        "WRITE_LOCATION_ASSETS so the rule is enforced there "
                        "rather than silently exempt"
                    )
        self.assertEqual(offenders, [], "\n".join(offenders))


class ArtPolicyTests(unittest.TestCase):
    """Issue #493's art policy across both brands' issue-drafting assets.

    PR #251 made a missing texture, icon, sprite, or animation an explicit
    tracked blocker with a user-owned supply-or-generate decision, and landed it
    in claude-plugin's /issue and /solve only. It added no regression assertion,
    so the Codex twins drifted silently: the same missing-art observation
    produced a tracked blocker and a stop-for-the-user through one brand, and
    could produce a silently omitted blocker, a placeholder, a reused asset, or
    a narrowed scope through the other.

    These assets are the program an agent executes and there is no behavioral
    prompt-testing harness here, so the reviewable property is the asset text
    itself, exactly as WriteLocationTests and ScopeGateTests treat their own
    contracts. The solve half of the same policy is guarded the same way by
    tools/test_agent_workflow_contract.py.
    """

    def setUp(self):
        self.assets = {
            path: canonical((REPO_ROOT / path).read_text(encoding="utf-8"))
            for path in ART_POLICY_ISSUE_ASSETS
        }

    def test_every_issue_asset_states_every_art_rule(self):
        findings = art_policy_findings(self.assets, ART_POLICY_ISSUE_RULES)
        self.assertEqual(findings, [], "\n".join(findings))

    def test_removing_a_rule_from_either_brand_is_reported(self):
        # The property under test is that a removal FAILS the enforced check,
        # for each rule and each brand in turn, not merely that the text happens
        # to be present today.
        for path in ART_POLICY_ISSUE_ASSETS:
            for rule in ART_POLICY_ISSUE_RULES:
                with self.subTest(asset=path, rule=rule):
                    mutated = dict(self.assets)
                    mutated[path] = mutated[path].replace(rule, "")
                    self.assertIn(
                        f"{path}: missing art-policy rule {rule!r}",
                        art_policy_findings(mutated, ART_POLICY_ISSUE_RULES),
                        f"deleting {rule!r} from {path} left the art-policy "
                        "check green, so it would not notice the edit",
                    )

    def test_the_art_rules_are_not_vacuous(self):
        # A rule broad enough to match every packaged asset would pass the check
        # above while asserting nothing. Both autoissue assets delegate to their
        # brand's /issue and must not restate the policy, so they are the same
        # negative control WriteLocationTests uses.
        #
        # Reported as a plain list rather than through assertIn for the same
        # reason: these assets canonicalize to thousands of characters, and a
        # membership assertion buries the one line that says what to do.
        offenders = []
        for path in DELEGATING_ASSETS:
            text = canonical((REPO_ROOT / path).read_text(encoding="utf-8"))
            for rule in ART_POLICY_ISSUE_RULES:
                if rule in text:
                    offenders.append(
                        f"{path} now states {rule!r}; add it to "
                        "ART_POLICY_ISSUE_ASSETS so the rule is enforced there "
                        "rather than silently exempt"
                    )
        self.assertEqual(offenders, [], "\n".join(offenders))


# Issue #840: what each drafting and issue-review description says about when it
# applies. The description is all a session matches a request against, so a
# neighbour's redirect and the "use only when" trigger boundary are behavior.
# Lowercase: compared against canonical() output of the description.
#
# `redirects` are fragments each description owes (every brand, because the
# redirect is guidance for whoever reads the description). The Codex `issue`
# redirect names the Claude-only survey command in prose and never a
# sigil-prefixed Codex skill, since §3.2 forbids a Codex $draft-issues.
DESCRIPTION_REDIRECTS = {
    "claude-plugin/plugins/kanban/commands/issue.md": ("not a survey of many (/draft-issues surveys)",),
    "codex-plugin/plugins/kanban/skills/issue/SKILL.md": (
        "not a survey of many (the claude-only draft-issues command surveys; codex has no survey skill)",
    ),
    "claude-plugin/plugins/kanban/commands/draft-issues.md": ("not one candidate (use /issue)",),
    "claude-plugin/plugins/kanban/commands/autoissue.md": (
        "not drafting alone (use /issue)",
        "not review of an existing issue (use /issue-review)",
    ),
    "codex-plugin/plugins/kanban/skills/autoissue/SKILL.md": (
        "not drafting alone (use $issue)",
        "not review of an existing issue (use $issue-review)",
    ),
    "claude-plugin/plugins/kanban/commands/issue-review.md": ("not drafting (use /issue)",),
    "codex-plugin/plugins/kanban/skills/issue-review/SKILL.md": ("does not draft or create issues (use $issue)",),
    "claude-plugin/plugins/kanban/commands/issue-rereview.md": ("not drafting (use /issue)",),
    "codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md": ("does not draft or create issues (use $issue)",),
}

# A client may truncate a long description, so a redirect that sits past this
# many characters is not placed to survive.
DESCRIPTION_REDIRECT_BUDGET = 330

# The Claude descriptions that owe the narrow trigger, and the Codex wording
# each is matched to. The Codex trigger is asserted only to be unchanged: this
# issue does not narrow Codex.
CLAUDE_USE_ONLY_TRIGGERS = {
    "claude-plugin/plugins/kanban/commands/autoissue.md": (
        "use only when the user invokes /autoissue or explicitly asks for "
        "this combined draft-create-review workflow"
    ),
    "claude-plugin/plugins/kanban/commands/issue-review.md": (
        "use only when the user invokes /issue-review or explicitly asks to "
        "review, approve, fact-check, or readiness-gate an issue before solving it"
    ),
    "claude-plugin/plugins/kanban/commands/issue-rereview.md": (
        "use only when the user invokes /issue-rereview or explicitly asks to "
        "address issue-review feedback"
    ),
}
CODEX_TRIGGERS = {
    "codex-plugin/plugins/kanban/skills/autoissue/SKILL.md": (
        "use only when the user invokes $autoissue or explicitly asks for "
        "this combined draft-create-review workflow"
    ),
    "codex-plugin/plugins/kanban/skills/issue-review/SKILL.md": (
        "use when the user invokes $issue-review or asks to review, approve, "
        "fact-check, or readiness-gate an issue before solving it"
    ),
    "codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md": (
        "use when the user invokes $issue-rereview, asks to address issue-review feedback"
    ),
    "codex-plugin/plugins/kanban/skills/issue/SKILL.md": (
        "trigger when asked to find, scout, or draft an issue"
    ),
}

# Issue #840: /draft-issues shows every chosen candidate's complete body and
# waits for approval of those bodies before it creates anything, and inherits
# the hand-off rules /issue applies. Lowercase, compared against canonical().
DRAFT_ISSUES_PATH = "claude-plugin/plugins/kanban/commands/draft-issues.md"

DRAFT_ISSUES_SUBAGENT_RULES = (
    "audit the repository in your own session; do not spawn subagents",
    "if the user asked for subagents for this task, you may use them, and only on sonnet",
)

DRAFT_ISSUES_HANDOFF_RULES = (
    # issue.md rule 3: a stale steering document is a requirement to update it.
    "if the change invalidates a statement in the repo's agent instructions",
    "updating that doc is a requirement — name the file",
    # rule 6: a design question is never resolved silently.
    "never silently resolve a design question",
    'put it in a "deliberately open" section with instructions to stop and ask',
    # Scope to one PR, split at signoff.
    "a candidate that is genuinely larger than one pull request is split at signoff",
)

# The art rule is ART_POLICY_ISSUE_RULES, enforced for this asset through
# ART_POLICY_ISSUE_ASSETS. These are the extra #840 clarifications: a missing
# asset is a dependency, never a readiness failure or a placeholder.
DRAFT_ISSUES_ART_RULES = (
    "a missing asset is an execution dependency, not a readiness failure",
    "purpose, visual constraints, dependencies, and the criteria the user will apply to approve the finished image",
    "keep a supply method the user has already chosen",
    "leave the choice of method and the authorization to generate until the solver needs the asset",
    "never substitute a placeholder or drop the requirement",
)

DRAFT_ISSUES_APPROVAL_RULES = (
    "choosing candidates from the list is not signoff of their bodies",
    "present every drafted issue exactly as it will be posted: title, proposed labels",
    "the complete body verbatim, including each piece of a split candidate",
    "wait for the user's explicit approval of those bodies",
    "present the complete revised draft again",
    "do not run gh issue create until the user has explicitly approved the drafts",
    "create only the drafts they approved",
)

# Where the approval stop and the creation step start. The first is the
# signoff heading; the second is the one instruction that actually creates.
DRAFT_ISSUES_SIGNOFF_ANCHOR = "signoff on the bodies — stop"
DRAFT_ISSUES_CREATE_ANCHOR = "create it with gh issue create --title"


def description_of(text):
    """The frontmatter `description:` value of an asset's text."""
    match = re.search(r"^description: (?P<value>.+)$", text, re.MULTILINE)
    if match is None:
        raise AssertionError("asset has no frontmatter description")
    return match.group("value")


def draft_issues_findings(text):
    """Everything wrong with a /draft-issues text, as a list of messages.

    Factored out so the planted-mutation checks drive the predicate the
    presence check drives. The ordering test is the load-bearing one: a text
    can carry every approval sentence and still create before it shows bodies,
    so the creation instruction must come after the signoff stop.
    """
    body = canonical(text)
    findings = []
    if "fan out" in body:
        findings.append("instructs fanning out")
    for rule in (
        DRAFT_ISSUES_SUBAGENT_RULES
        + DRAFT_ISSUES_HANDOFF_RULES
        + DRAFT_ISSUES_ART_RULES
        + DRAFT_ISSUES_APPROVAL_RULES
    ):
        if rule not in body:
            findings.append(f"missing rule {rule!r}")
    signoff = body.find(DRAFT_ISSUES_SIGNOFF_ANCHOR)
    create = body.find(DRAFT_ISSUES_CREATE_ANCHOR)
    if signoff < 0:
        findings.append("has no body signoff stop")
    if create < 0:
        findings.append("has no creation step")
    if signoff >= 0 and create >= 0 and create < signoff:
        findings.append("creates before it shows the bodies")
    return findings


class DescriptionBoundaryTests(unittest.TestCase):
    """Issue #840: the descriptions redirect to their neighbour near the front
    and the three Claude review/automation commands trigger only on request."""

    def setUp(self):
        self.descriptions = {
            path: canonical(description_of((REPO_ROOT / path).read_text(encoding="utf-8")))
            for path in (
                set(DESCRIPTION_REDIRECTS) | set(CLAUDE_USE_ONLY_TRIGGERS) | set(CODEX_TRIGGERS)
            )
        }

    def test_every_description_redirects_to_its_neighbour_within_the_budget(self):
        findings = []
        for path, fragments in DESCRIPTION_REDIRECTS.items():
            for fragment in fragments:
                at = self.descriptions[path].find(fragment)
                if at < 0:
                    findings.append(f"{path}: description lacks redirect {fragment!r}")
                elif at + len(fragment) > DESCRIPTION_REDIRECT_BUDGET:
                    findings.append(f"{path}: redirect {fragment!r} ends past {DESCRIPTION_REDIRECT_BUDGET} characters")
        self.assertEqual(findings, [], "\n".join(findings))

    def test_the_claude_commands_trigger_only_on_request(self):
        findings = [
            f"{path}: description lacks {trigger!r}"
            for path, trigger in CLAUDE_USE_ONLY_TRIGGERS.items()
            if trigger not in self.descriptions[path]
        ]
        self.assertEqual(findings, [], "\n".join(findings))

    def test_the_codex_triggers_are_not_narrowed(self):
        findings = [
            f"{path}: description lacks its existing trigger {trigger!r}"
            for path, trigger in CODEX_TRIGGERS.items()
            if trigger not in self.descriptions[path]
        ]
        self.assertEqual(findings, [], "\n".join(findings))

    def test_the_codex_issue_description_names_no_codex_survey_skill(self):
        # §3.2 forbids a Codex $draft-issues, so the redirect names the Claude-only
        # command in prose and must not read as an invocation.
        description = self.descriptions["codex-plugin/plugins/kanban/skills/issue/SKILL.md"]
        self.assertIn("claude-only draft-issues", description)
        self.assertNotIn("$draft-issues", description)
        self.assertNotIn("/draft-issues", description)

    def test_the_neighbour_redirects_are_not_vacuous(self):
        # Negative control: issue-review and issue-rereview legitimately share
        # "not drafting", so the control is the assets that owe no redirect at
        # all. A fragment that matched them would pass the presence check above
        # while asserting nothing.
        controls = {
            name: canonical(
                description_of((CLAUDE_COMMANDS_ROOT / f"{name}.md").read_text(encoding="utf-8"))
            )
            for name in ("solve", "pr-review", "triage", "finalize", "design-epic")
        }
        offenders = [
            f"{name} carries {path}'s redirect {fragment!r}"
            for path, fragments in DESCRIPTION_REDIRECTS.items()
            for fragment in fragments
            for name, text in controls.items()
            if fragment in text
        ]
        self.assertEqual(offenders, [], "\n".join(offenders))

    def test_a_removed_redirect_or_trigger_is_reported(self):
        for path, fragments in DESCRIPTION_REDIRECTS.items():
            for fragment in fragments:
                mutated = self.descriptions[path].replace(fragment, "")
                self.assertNotIn(fragment, mutated, f"{path}: {fragment!r} survived its own removal")
        for path, trigger in CLAUDE_USE_ONLY_TRIGGERS.items():
            self.assertNotIn(trigger, self.descriptions[path].replace(trigger, ""))


class DraftIssuesBodyApprovalTests(unittest.TestCase):
    """Issue #840: /draft-issues shows complete bodies and waits before any
    `gh issue create`, spawns no subagent unprompted, and inherits /issue's
    hand-off rules. No behavioral prompt harness exists, so the asset text is
    the reviewable property, exactly as for WriteLocationTests."""

    def setUp(self):
        self.text = (REPO_ROOT / DRAFT_ISSUES_PATH).read_text(encoding="utf-8")

    def test_the_asset_satisfies_every_rule(self):
        findings = draft_issues_findings(self.text)
        self.assertEqual(findings, [], "\n".join(findings))

    def test_the_signoff_stop_comes_before_the_creation_instruction(self):
        body = canonical(self.text)
        self.assertLess(
            body.index(DRAFT_ISSUES_SIGNOFF_ANCHOR),
            body.index(DRAFT_ISSUES_CREATE_ANCHOR),
        )

    def test_removing_any_rule_is_reported(self):
        for rule in (
            DRAFT_ISSUES_SUBAGENT_RULES
            + DRAFT_ISSUES_HANDOFF_RULES
            + DRAFT_ISSUES_ART_RULES
            + DRAFT_ISSUES_APPROVAL_RULES
        ):
            with self.subTest(rule=rule):
                mutated = canonical(self.text).replace(rule, "")
                self.assertIn(f"missing rule {rule!r}", draft_issues_findings(mutated))

    def test_removing_the_body_approval_stop_is_reported(self):
        body = canonical(self.text)
        start = body.index(DRAFT_ISSUES_SIGNOFF_ANCHOR)
        end = body.index("create: only after that approval")
        mutated = body[:start] + body[end:]
        self.assertIn("has no body signoff stop", draft_issues_findings(mutated))

    def test_creating_ahead_of_the_body_approval_is_reported(self):
        body = canonical(self.text)
        start = body.index(DRAFT_ISSUES_SIGNOFF_ANCHOR)
        end = body.index("create: only after that approval")
        mutated = body[end:] + " " + body[start:end]
        self.assertIn("creates before it shows the bodies", draft_issues_findings(mutated))

    def test_a_reinstated_fan_out_instruction_is_reported(self):
        mutated = canonical(self.text) + " for a large repo, fan out parallel subagents to audit modules."
        self.assertIn("instructs fanning out", draft_issues_findings(mutated))

    def test_the_acceptance_grep_finds_no_unsolicited_spawn_instruction(self):
        # The acceptance check is `git grep -niE 'fan out|subagent'`, read for an
        # instruction to spawn. The explicit-request Sonnet exception names the
        # word, so the word alone is not the failure; "fan out" must be absent.
        self.assertNotIn("fan out", self.text.lower())

    def test_the_approval_rules_are_not_vacuous(self):
        # Negative control: the assets that delegate to /issue (autoissue) or
        # draft exactly one candidate already had a signoff stop of their own
        # and must not restate /draft-issues' list-selection distinction.
        offenders = []
        for path in DELEGATING_ASSETS:
            text = canonical((REPO_ROOT / path).read_text(encoding="utf-8"))
            for rule in DRAFT_ISSUES_APPROVAL_RULES + DRAFT_ISSUES_SUBAGENT_RULES:
                if rule in text:
                    offenders.append(f"{path} now states {rule!r}; enforce it there")
        self.assertEqual(offenders, [], "\n".join(offenders))


class DraftIssuesContractTests(unittest.TestCase):
    """§3.2 and the responsibility-matrix row state the body-approval behavior."""

    def setUp(self):
        self.text = normalized(contract_text())

    def test_the_matrix_row_separates_selection_from_body_approval(self):
        self.assertIn(
            "Only the drafts whose complete bodies the user approves; selecting "
            "candidates from the list is not that approval",
            self.text,
        )

    def test_section_3_2_states_the_body_approval_and_subagent_rules(self):
        for fragment in (
            "creates nothing until the user has approved the drafts",
            "Choosing candidates from the list is selection, not signoff",
            "with its title, labels, and complete body",
            "each piece of a split candidate",
            "presented again as a complete revised draft",
            "spawns no subagent unless the user asked for subagents for that task",
            "run on Sonnet",
            "a candidate larger than one pull request is split at signoff",
            "A placeholder never substitutes for it and the requirement is never dropped",
        ):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, self.text)


class ScopeGateTests(unittest.TestCase):
    """Issue #116's scope gate. There is no behavioral prompt-testing harness
    here, so the reviewable property is the contract text itself: the document
    and all five discretionary-discovery assets must state the same gate and
    exemption rules, every gate instruction must be conditional on a gate
    being present, and the gate must not leak into the issue-review workflows
    that judge filed issues rather than hunting candidates."""

    def setUp(self):
        self.document = canonical(contract_text())
        self.assets = {
            path: canonical((REPO_ROOT / path).read_text(encoding="utf-8"))
            for path in SCOPE_GATE_ASSETS
        }

    def test_document_states_every_scope_gate_rule(self):
        for rule in SCOPE_GATE_RULES:
            self.assertIn(
                rule,
                self.document,
                f"docs/drafting-workflow-contract.md §4 no longer states: {rule!r}",
            )

    def test_every_discretionary_asset_states_every_scope_gate_rule(self):
        missing = []
        for path in SCOPE_GATE_ASSETS:
            for rule in SCOPE_GATE_RULES:
                if rule not in self.assets[path]:
                    missing.append(f"{path}: missing scope-gate rule {rule!r}")
        self.assertEqual(missing, [], "\n".join(missing))

    def test_every_gate_instruction_is_conditioned_on_a_gate_being_present(self):
        # The document and each asset must state the absent-gate guard before
        # any instruction that constrains or defers, so no reader reaches a
        # gate instruction without having been told it applies only when a
        # gate exists.
        sources = dict(self.assets)
        sources["docs/drafting-workflow-contract.md"] = self.document
        offenders = []
        for path, text in sorted(sources.items()):
            guard_at = text.find(SCOPE_GATE_GUARD)
            if guard_at == -1:
                offenders.append(f"{path}: states no absent-gate guard")
                continue
            for instruction in GATE_CONDITIONED_INSTRUCTIONS:
                at = text.find(instruction)
                if at == -1:
                    offenders.append(f"{path}: missing gate instruction {instruction!r}")
                elif at < guard_at:
                    offenders.append(
                        f"{path}: states {instruction!r} before the absent-gate guard, "
                        "so the instruction reads as unconditional"
                    )
        self.assertEqual(offenders, [], "\n".join(offenders))

    def test_document_refuses_to_promise_identical_candidate_output(self):
        # Requirement 2 preserves policy, sources, and reporting behavior —
        # not an identical candidate list, which nondeterministic agent runs
        # cannot deliver and this contract must not claim.
        self.assertIn("agent runs are nondeterministic", self.document)
        self.assertIn("never an identical candidate list across runs", self.document)

    def test_an_all_deferred_run_still_reaches_signoff(self):
        # The one-candidate hunters otherwise reach signoff only by producing
        # a draft. If a gate defers every candidate, "nothing worth opening"
        # would end the run before the override surface ever appeared, and
        # requirement 4 would be unsatisfiable.
        for path in ONE_CANDIDATE_ASSETS:
            self.assertIn(
                NOTHING_WORTH_OPENING_CONDITION,
                self.assets[path],
                f"{path}: 'nothing worth opening' is not conditioned on the gate, so an "
                "all-deferred run can stop without offering the user an override",
            )

    def test_document_reserves_nothing_worth_opening_for_non_gate_stops(self):
        self.assertIn(
            "only a run whose candidates were killed by verification or deduplication "
            "- not by a gate - may report nothing worth opening",
            self.document.replace("—", "-"),
        )

    def test_scope_gate_does_not_reach_the_issue_review_workflows(self):
        for path in SCOPE_GATE_FREE_ASSETS:
            text = canonical((REPO_ROOT / path).read_text(encoding="utf-8"))
            self.assertNotIn(
                "scope gate",
                text,
                f"{path} judges a filed issue rather than hunting candidates; "
                "the scope gate must not reach it",
            )

    def test_document_scopes_the_gate_to_discovery_and_excludes_epic(self):
        self.assertIn("candidate selection is ungated by default", self.document)
        self.assertIn(
            "nothing in this repository defines any project's gate", self.document
        )
        # Arc decomposition is excluded on the same behavioral rationale as
        # §3.5.
        self.assertIn(
            "decomposes a user-supplied arc rather than independently selecting",
            self.document,
        )


class AutoissueSequenceTests(unittest.TestCase):
    """Both packaged autoissue assets must preserve the delegate-draft,
    stop-before-review, create-after-signoff, review-immediately sequence the
    pinned sources define — not just the document describing it."""

    def setUp(self):
        self.sources = {
            path: normalized((REPO_ROOT / path).read_text(encoding="utf-8"))
            for path in AUTOISSUE_ASSETS
        }

    def test_autoissue_delegates_drafting_to_its_own_brands_issue_workflow(self):
        for path, sigil in sorted(AUTOISSUE_ASSETS.items()):
            text = self.sources[path]
            self.assertIn(f"Run {sigil}issue for exactly one candidate", text, path)

    def test_autoissue_stops_without_review_when_drafting_stops_before_creation(self):
        for path, sigil in sorted(AUTOISSUE_ASSETS.items()):
            text = self.sources[path]
            self.assertIn("otherwise stops before creation, stop this workflow too", text, path)
            self.assertIn("Do not run a review.", text, path)

    def test_autoissue_creates_then_immediately_reviews_without_a_second_confirmation(self):
        for path, sigil in sorted(AUTOISSUE_ASSETS.items()):
            text = self.sources[path]
            self.assertIn(f"Immediately run {sigil}issue-review", text, path)
            self.assertIn("do not ask for a second confirmation", text, path)
            self.assertIn("explicit approval of the issue draft authorizes its creation", text, path)

    def test_autoissue_preserves_its_delegates_origin_marker(self):
        for path, brand in (
            ("claude-plugin/plugins/kanban/commands/autoissue.md", "claude"),
            ("codex-plugin/plugins/kanban/skills/autoissue/SKILL.md", "codex"),
        ):
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            self.assertIn(ORIGIN_MARKER_BY_BRAND[brand], text, path)


class PortableBackendTests(unittest.TestCase):
    """Requirement 6 of issue #118: the packaged issue-review workflows,
    including autoissue's immediate review handoff, must resolve the
    Kanban-managed install path rather than the pre-migration personal
    launcher. Issue #240 puts the two issue-rereview assets under the same
    rule — they reach the same backend for gate state and resubmission, so a
    second resolution convention there would be a second contract."""

    def test_issue_review_assets_resolve_through_the_bundled_script(self):
        # Claude commands call the plugin's scripts/ through the substituted
        # root; Codex skills locate their own skill's installed copy under
        # $CODEX_HOME. Neither may name a path inside the repository being
        # worked, which is what the "unrelated directory" tests in
        # test_packaged_issue_review_probe.py execute.
        for path in BACKEND_RESOLVING_ASSETS:
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            self.assertIn(BACKEND_ENV_OVERRIDE, text, path)
            self.assertIn("`tools/install_issue_review.py`", text, path)
            if path.startswith("claude-plugin/"):
                self.assertIn(
                    f'python3 "${{CLAUDE_PLUGIN_ROOT}}/scripts/{BACKEND_RESOLVER_NAME}"',
                    text,
                    path,
                )
            else:
                skill = Path(path).parent.name
                self.assertIn(
                    f"-path '*/kanban/*/skills/{skill}/scripts/{BACKEND_RESOLVER_NAME}'",
                    text,
                    path,
                )
                self.assertIn(
                    f'python3 "${{RESOLVER:?{BACKEND_RESOLVER_NAME} was not found under the installed Kanban plugin}}"',
                    text,
                    path,
                )

    def test_issue_review_assets_embed_no_probe(self):
        for path in BACKEND_RESOLVING_ASSETS:
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            for fragment in (
                "XDG_RECORD",
                BACKEND_RECORD_PATH,
                BACKEND_XDG_RECORD_PATH,
                "does not name an absolute backend_path",
            ):
                self.assertNotIn(fragment, text, f"{path}: {fragment}")

    def test_the_bundled_script_resolves_through_the_installer_record(self):
        # The record paths, the field and the repair the assets used to carry
        # inline, now held once by the script every asset calls.
        text = (REPO_ROOT / BACKEND_RESOLVER_SOURCE).read_text(encoding="utf-8")
        self.assertIn(BACKEND_ENV_OVERRIDE, text)
        self.assertIn("/" + BACKEND_DEFAULT_PATH, text)
        self.assertIn(BACKEND_RECORD_PATH, text)
        self.assertIn(BACKEND_XDG_RECORD_PATH, text)
        self.assertIn(BACKEND_RECORD_FIELD, text)
        self.assertIn("approve_issues.py", text)
        self.assertIn("python3 tools/install_issue_review.py", text)
        self.assertLess(
            text.index(BACKEND_XDG_RECORD_PATH), text.index(BACKEND_RECORD_PATH)
        )

    def test_section_six_describes_the_script_and_the_xdg_first_probe(self):
        document = (REPO_ROOT / DRAFTING_CONTRACT).read_text(encoding="utf-8")
        start = document.index("## 6. Portable canonical backend")
        section = document[start : document.index("\n## 7.", start)]
        self.assertIn(BACKEND_RESOLVER_SOURCE, section)
        self.assertIn(BACKEND_ENV_OVERRIDE, section)
        self.assertIn("kanban/issue-review/config.json", section)
        self.assertIn("~/Library/Application Support/kanban/issue-review/config.json", section)
        self.assertLess(
            section.index("$XDG_DATA_HOME/kanban/issue-review/config.json"),
            section.index("~/Library/Application Support/kanban/issue-review/config.json"),
        )
        # The single-record Library-only probe this section used to show.
        self.assertNotIn('RECORD="$HOME/Library', section)
        self.assertNotIn("<<'PY'", section)
        # The section's claims about the assets hold the assets' own wording.
        for path in BACKEND_RESOLVING_ASSETS:
            asset = (REPO_ROOT / path).read_text(encoding="utf-8")
            self.assertIn(BACKEND_RESOLVER_NAME, asset, path)
        self.assertIn(BACKEND_RESOLVER_NAME, section)

    def test_autoissue_assets_defer_to_the_documented_backend_contract(self):
        for path in AUTOISSUE_ASSETS:
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            self.assertIn(BACKEND_ENV_OVERRIDE, text, path)
            self.assertIn("approve_issues.py", text, path)

    def test_no_declared_asset_references_the_compatibility_launcher(self):
        offenders = []
        for path in sorted(EXPECTED_DECLARED_PATHS):
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            for fragment in FORBIDDEN_BACKEND_PATHS:
                if fragment in text:
                    offenders.append(f"{path}: references {fragment!r}")
        self.assertEqual(offenders, [], "\n".join(offenders))

    def test_no_declared_asset_pins_a_reviewer_model_or_effort(self):
        # The pinned sources set APPROVE_ISSUES_CLAUDE_MODEL /
        # APPROVE_ISSUES_CLAUDE_DISPLAY_NAME to scope the reviewer model for
        # the owner's own machine. Requirement 5 of issue #118 drops that
        # personal configuration when vendoring: reviewer selection belongs
        # to tools/approve_issues.py, whose own default already selects the
        # same reviewer.
        offenders = []
        for path in sorted(EXPECTED_DECLARED_PATHS):
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            for fragment in ("APPROVE_ISSUES_CLAUDE_MODEL", "APPROVE_ISSUES_CLAUDE_DISPLAY_NAME"):
                if fragment in text:
                    offenders.append(f"{path}: pins reviewer configuration via {fragment}")
        self.assertEqual(offenders, [], "\n".join(offenders))

    def test_approve_issues_default_reviewer_makes_the_dropped_pin_a_no_op(self):
        # Pins the claim above: dropping the personal env vars preserves
        # behavior only because the backend's own default is the same model.
        #
        # Since issue #483 that default is the model roster's
        # `roles.issue_gate.claude` cell rather than a literal in the backend,
        # so the same claim is held in two halves: the backend resolves that
        # cell with APPROVE_ISSUES_CLAUDE_MODEL as the override the vendored
        # assets no longer set, and the tracked roster's cell still names the
        # reviewer those assets used to pin. Read out of the backend rather
        # than imported, because what a vendoring drop is safe against is what
        # the tracked file says, not what this suite's host resolved.
        #
        # Issue #572 moved that resolution off `resolve_assignment` and onto
        # the loaded roster itself, so only the LOADED providers' cells are
        # resolved -- a Claude-only host must review with Claude rather than
        # refuse for want of a Codex cell. The claim held here is unchanged:
        # the cell is still where the default comes from.
        source = (REPO_ROOT / "tools" / "approve_issues.py").read_text(encoding="utf-8")
        self.assertIn(
            '_MODEL_ROSTER.assignment_for("issue_gate", provider)', source
        )
        self.assertIn("for provider in LOADED_PROVIDERS", source)
        self.assertIn(
            'PRIMARY_CLAUDE_MODEL = gate_model("claude", "APPROVE_ISSUES_CLAUDE_MODEL")',
            source,
        )
        # The persona comes from the same cell (#827), not from a literal.
        self.assertIn(
            'gate_display("claude", "APPROVE_ISSUES_CLAUDE_DISPLAY_NAME")', source
        )
        roster = tomllib.loads(
            (REPO_ROOT / "models.toml.example").read_text(encoding="utf-8")
        )
        self.assertEqual(
            roster["roles"]["issue_gate"]["claude"]["model"], "claude-opus-5-5"
        )


class IssueRereviewProtocolTests(unittest.TestCase):
    """§3.6's repair loop. Like the scope gate above, there is no behavioral
    prompt-testing harness here, so the reviewable property is the contract
    text: both packaged assets must state the same four responsibilities, read
    the timeline only through their own bundle's vendored helper, and leave
    every verdict and label to the backend."""

    def setUp(self):
        self.raw = {
            path: (REPO_ROOT / path).read_text(encoding="utf-8")
            for path in ISSUE_REREVIEW_ASSETS
        }
        self.assets = {path: canonical(text) for path, text in self.raw.items()}

    def test_both_bundles_package_a_rereview_asset(self):
        for path in sorted(ISSUE_REREVIEW_ASSETS):
            self.assertTrue((REPO_ROOT / path).is_file(), path)
        self.assertLessEqual(set(ISSUE_REREVIEW_ASSETS), EXPECTED_DECLARED_PATHS)

    def test_every_rereview_asset_states_every_protocol_rule(self):
        missing = []
        for path in sorted(ISSUE_REREVIEW_ASSETS):
            for rule in REREVIEW_PROTOCOL_RULES:
                if rule not in self.assets[path]:
                    missing.append(f"{path}: missing §3.6 rule {rule!r}")
        self.assertEqual(missing, [], "\n".join(missing))

    def test_the_document_states_every_protocol_rule_it_can(self):
        # The document owes the responsibilities, not the assets' exact
        # wording; these four are the ones §3.6 states verbatim, so the
        # contract and its assets cannot describe different loops.
        document = canonical(contract_text())
        for statement in (
            "they never solve the issue, change repository code, hunt for or "
            "create issues",
            "revises the specification only with explicit user signoff",
            "an unchanged spec is never resubmitted",
            "publishes no verdict of its own",
        ):
            self.assertIn(statement, document, statement)

    def test_each_rereview_asset_reads_the_timeline_through_its_own_helper(self):
        for path, reference in sorted(REREVIEW_HELPER_REFERENCES.items()):
            self.assertIn(
                reference,
                self.raw[path],
                f"{path} must resolve its own bundle's vendored "
                "trusted_issue_spec.py, not a personal or checkout-relative copy",
            )
            self.assertIn("trusted_issue_spec.py", self.raw[path], path)

    def test_no_rereview_asset_reaches_the_opposite_bundles_helper(self):
        other = {
            "claude-plugin/plugins/kanban/commands/issue-rereview.md": CODEX_HELPER_LOOKUP,
            "codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md": CLAUDE_HELPER_REFERENCE,
        }
        for path, reference in sorted(other.items()):
            self.assertNotIn(reference, self.raw[path], path)

    def test_every_rereview_asset_forbids_an_unfiltered_comment_source(self):
        missing = []
        for path in sorted(ISSUE_REREVIEW_ASSETS):
            for phrase in FORBIDDEN_COMMENT_SOURCES:
                if phrase not in self.assets[path]:
                    missing.append(f"{path}: does not forbid {phrase!r}")
        self.assertEqual(missing, [], "\n".join(missing))

    def test_every_rereview_asset_preserves_rather_than_emits_an_origin_marker(self):
        for path in sorted(ISSUE_REREVIEW_ASSETS):
            self.assertIn(REREVIEW_MARKER_PRESERVATION, self.assets[path], path)
            # Preservation means naming both literals; a single-brand mention
            # would read as "stamp this one".
            for marker in (CLAUDE_ORIGIN_MARKER, CODEX_ORIGIN_MARKER):
                self.assertIn(marker, self.raw[path], f"{path}: {marker}")

    def test_the_rereview_assets_are_exempt_from_the_issue_creating_marker_rule(self):
        # The exemption is the point of the preservation rule above: a
        # workflow that only edits an existing body must not be held to
        # emitting a marker, or repairing a Codex-origin issue from the Claude
        # command would rewrite its provenance.
        for path in ISSUE_REREVIEW_ASSETS:
            self.assertNotIn(path, ISSUE_CREATING_ASSETS, path)

    def test_each_issue_review_asset_routes_to_its_own_brands_rereview(self):
        # §3.4: the gate reports CHANGES_REQUESTED and hands off. Before issue
        # #240 both assets named a bare, unpackaged `issue-rereview`; each must
        # now name the invocation its own brand actually ships.
        for path, sigil in (
            ("claude-plugin/plugins/kanban/commands/issue-review.md", "/"),
            ("codex-plugin/plugins/kanban/skills/issue-review/SKILL.md", "$"),
        ):
            text = normalized((REPO_ROOT / path).read_text(encoding="utf-8"))
            self.assertIn(f"{sigil}issue-rereview <issue>", text, path)
            self.assertNotIn(
                "deliberately outside this bundle's packaged set",
                text,
                f"{path} still calls the rereview workflow unpackaged",
            )

    def test_no_issue_review_asset_routes_to_the_opposite_brands_rereview(self):
        for path, wrong in (
            ("claude-plugin/plugins/kanban/commands/issue-review.md", "$issue-rereview"),
            ("codex-plugin/plugins/kanban/skills/issue-review/SKILL.md", "/issue-rereview"),
        ):
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            self.assertNotIn(wrong, text, path)


if __name__ == "__main__":
    unittest.main()
