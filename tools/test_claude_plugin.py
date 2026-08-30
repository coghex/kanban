"""Structural and contract coverage for the tracked Claude plugin.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Guards the packaging promise of issue #77: a clean Claude Code installation
can add claude-plugin/ as a marketplace and discover exactly the five
workflows Kanban invokes by name (/solve, /pr-review, /pr-rereview,
/pr-revise, /repair), none of which may set its own model/effort/permission-mode/
working-directory configuration, depend on an untracked personal path, or
drift from the invocation strings src/Kanban/Solve.hs and
src/Kanban/PullRequestFlow.hs actually spawn. The bundled coordinator is a
tracked copy of the Codex plugin's coordinator (issue #76), tested here
standalone so the Claude bundle's own coverage never requires the Codex
plugin's assets to exist.

Issue #118 added four more packaged commands — the drafting and canonical
issue-review workflows /issue, /draft-issues, /autoissue, and /issue-review —
so discovery and Haskell name parity are now two separate concepts here, and
issue #229 added /process-report, then the one design/report document workflow
with a Claude counterpart, and issue #240 added /issue-rereview, the drafting
contract's repair loop for a changes-requested issue. Issue #241 added the
design pair /design-epic and /process-design-doc, transposed from the
post-#239 tracked Codex skills; issue #328 completed the report side with
/draft-report and /note-problem; and issues #393, #410, #427, #430, #462, and
#511 vendored the rendered /triage roadmap, its /retriage refresh, the
/push-docs documentation-landing workflow, the /backlog-review backlog audit,
the /project-review history audit, the /drain-prs drainer control surface, the
/fix approved-pull-request workflow, and — issue #544, the last of the eight —
the /finalize manual merge fallback.
EXPECTED_COMMAND_NAMES is what a Claude Code installation must find in the
commands directory (all twenty-three); HASKELL_PARITY_COMMAND_NAMES is the
strictly smaller set Kanban's own Haskell code spawns by name (the five
above). The drafting, document, roadmap, documentation-landing,
backlog-audit, history-audit, drainer-control, approved-pull-request, and
manual-finalization workflows
are user- or daemon-invoked and are deliberately excluded from that parity
pinning; see
docs/drafting-workflow-contract.md and docs/document-workflow-contract.md,
whose §3.5 records that its once-declared Codex-only document set is now
closed. They are still subject to every structural
policy this module enforces: frontmatter description, forbidden configuration
keys, and no personal paths.

Issue #235 added the two manifest gates at the end of this module, both built
on tools/plugin_bundle_gate.py: the bundle's declared version must increase in
any change unit that touches its tracked content, and the two manifest
descriptions that enumerate workflows must name exactly the commands the
bundle ships. The version gate is silent on an untouched tree by construction,
so PlantedBundleVersionGateTests drives it against a throwaway Git repository
rather than trusting it to fire.

Issue #125 packaged /repair ahead of the key that spawns it, so it briefly
formed a third, packaged-only category. Issue #127 gave Kanban's own `r` its
Done-column repair branch, so /repair is now spawned by name from
src/Kanban/PullRequestFlow.hs and belongs in HASKELL_PARITY_COMMAND_NAMES with
the rest; that third category is gone and discovery-minus-parity is the
user-invoked set again. See tools/test_repair_workflow_contract.py for
/repair's own behavioral contract.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

import fake_cli
import plugin_bundle_gate

REPO_ROOT = Path(__file__).resolve().parent.parent
CLAUDE_PLUGIN_ROOT = REPO_ROOT / "claude-plugin"
MARKETPLACE_MANIFEST = CLAUDE_PLUGIN_ROOT / ".claude-plugin" / "marketplace.json"
PLUGIN_ROOT = CLAUDE_PLUGIN_ROOT / "plugins" / "kanban"
PLUGIN_MANIFEST = PLUGIN_ROOT / ".claude-plugin" / "plugin.json"
COMMANDS_ROOT = PLUGIN_ROOT / "commands"
REVIEW_COORDINATOR = PLUGIN_ROOT / "scripts" / "review_pr.py"

# Repository-relative spellings the bundle gates work in: git reports paths
# this way, and the failure messages have to name something a reader can
# find from the repository root.
BUNDLE_PREFIX = "claude-plugin"
PLUGIN_MANIFEST_PATH = "claude-plugin/plugins/kanban/.claude-plugin/plugin.json"
MARKETPLACE_MANIFEST_PATH = "claude-plugin/.claude-plugin/marketplace.json"
COMMANDS_PREFIX = "claude-plugin/plugins/kanban/commands"

# The version both manifests declared from their introduction until issue
# #235, through every bundle change #229/#231/#232 landed.
ORIGINAL_BUNDLE_VERSION = "1.0.0"

# Claude commands are named with a leading slash wherever a manifest
# enumerates them.
COMMAND_SIGIL = "/"

SOLVE_HS = REPO_ROOT / "src" / "Kanban" / "Solve.hs"
PR_FLOW_HS = REPO_ROOT / "src" / "Kanban" / "PullRequestFlow.hs"
UI_HS = REPO_ROOT / "src" / "Kanban" / "UI.hs"
# Since MODEL-2 the canonical reviewer's model and effort are roster cells
# rather than literals in PullRequestFlow.hs, so the Haskell half of the
# parity gate below reads the tracked example roster -- which
# Spec.Config.Models holds byte-for-byte against the compiled defaults the
# spawn sites actually resolve.
MODELS_TOML_EXAMPLE = REPO_ROOT / "models.toml.example"
TRACKED_ROSTER_READER = REPO_ROOT / "tools" / "kanban_models.py"
BUNDLED_ROSTER_READER = PLUGIN_ROOT / "scripts" / "kanban_models.py"
CODEX_ROSTER_READER = (
    REPO_ROOT
    / "codex-plugin"
    / "plugins"
    / "kanban"
    / "skills"
    / "pr-review"
    / "scripts"
    / "kanban_models.py"
)
REVIEW_HS = REPO_ROOT / "src" / "Kanban" / "Review" / "Canonical.hs"
# Since issue #444 the record's own location is resolved for both managed
# installations by one module, and Review/Canonical.hs asks it rather than
# spelling a path -- so the location and the record's field are pinned against
# two files below rather than one.
MANAGED_PATHS_HS = REPO_ROOT / "src" / "Kanban" / "ManagedPaths.hs"

# The workflows Kanban's own Haskell code spawns by name. WorkflowNameParityTests
# pins this set — and only this set — against src/Kanban/Solve.hs and
# src/Kanban/PullRequestFlow.hs, so it must never grow to include a workflow
# Kanban does not spawn.
HASKELL_PARITY_COMMAND_NAMES = {"solve", "pr-review", "pr-rereview", "pr-revise", "repair"}

# The drafting and canonical issue-review workflows vendored by issue #118,
# plus the issue-rereview repair loop vendored by issue #240. User- or
# daemon-invoked, never spawned by Kanban's CLI, so they are packaged
# and policy-checked but excluded from Haskell name parity above.
DRAFTING_COMMAND_NAMES = {
    "issue",
    "draft-issues",
    "autoissue",
    "issue-review",
    "issue-rereview",
}

# The design and report document workflows vendored by issue #229, plus the
# design pair issue #241 transposed from the post-#239 tracked Codex skills and
# the report write side issue #328 completed: /draft-report transposed from the
# tracked Codex skill, and /note-problem authored as the brand transpose of the
# skill #328 vendored beside it. Also user-invoked and excluded from Haskell
# name parity. docs/document-workflow-contract.md §3.5's Codex-only set is now
# empty, so there is no document workflow the Claude plugin must not grow.
DOCUMENT_COMMAND_NAMES = {
    "design-epic",
    "process-design-doc",
    "draft-report",
    "note-problem",
    "process-report",
}
CODEX_ONLY_DOCUMENT_WORKFLOWS = ()

# The roadmap workflows vendored by issues #393 and #427, slices VEND-1 and
# VEND-2 of docs/workflow_command_vendoring_design.md. Unlike every set above
# neither is a hand-edited file: each is rendered from its own source under
# tools/command_sources/ by tools/render_command_sources.py, and
# tools/test_render_command_sources.py byte-compares the tracked outputs
# against those sources. /retriage refreshes a roadmap /triage produced and
# takes its whole rendering vocabulary from it by reference, so the two are one
# set rather than two. Both user-invoked and so excluded from Haskell name
# parity like the rest; /retriage's own behavioral assertions live in
# tools/test_reconcile_approvals.py beside /triage's.
ROADMAP_COMMAND_NAMES = {"triage", "retriage"}

# The documentation-landing workflow vendored by issue #410. Rendered from
# tools/command_sources/push-docs.md exactly the way the roadmap workflow
# above is, and like it user-invoked and excluded from Haskell name parity.
# Its behavioral assertions live in tools/test_docs_land.py beside the
# tools/docs_land.sh helper both brands' renderings invoke.
PUBLICATION_COMMAND_NAMES = {"push-docs"}

# The backlog audit vendored by issue #430, slice VEND-3. Rendered from
# tools/command_sources/backlog-review.md the way the two sets above are, and
# like them user-invoked and excluded from Haskell name parity. It is its own
# category rather than a third roadmap name because it is the first vendored
# workflow that mutates the tracker — it closes issues and rewrites their
# bodies, where /triage and /retriage only read and render. Its behavioral
# assertions live in tools/test_backlog_review_workflow.py.
BACKLOG_COMMAND_NAMES = {"backlog-review"}

# The history audit vendored by issue #462, slice VEND-4. Rendered from
# tools/command_sources/project-review.md the way the three sets above are,
# and like them user-invoked and excluded from Haskell name parity. It is its
# own category rather than a second backlog name because it audits landed
# history rather than the open backlog, and because design D-9 made it the one
# vendored workflow that is report-only: it never creates or edits a tracker
# issue, where /backlog-review closes them. Its behavioral assertions live in
# tools/test_project_review_workflow.py.
PROJECT_REVIEW_COMMAND_NAMES = {"project-review"}

# The drainer control surface vendored by issue #511, slice VEND-5. Rendered
# from tools/command_sources/drain-prs.md the way the four sets above are, and
# like them user-invoked and excluded from Haskell name parity. It is its own
# category rather than another audit name because it reaches no tracker at all:
# it makes no `gh` call, and its whole surface is the installed PR-drainer
# controller. Its behavioral assertions live in
# tools/test_drain_prs_workflow.py.
DRAINER_COMMAND_NAMES = {"drain-prs"}

# The approved-pull-request obstacle clearer. Rendered from
# tools/command_sources/fix.md the way the five sets above are, and like them
# user-invoked and excluded from Haskell name parity: Kanban's own CLI spawns
# repair for a Done-column card, never this. It is its own category rather
# than another repair name because it acts only on an already-approved pull
# request, and because it gates on an origin marker and a merge state no other
# workflow reads. It never reruns a check: tools/drain_prs.py owns that, and
# repair holds the same prohibition. Its behavioral assertions live in
# tools/test_fix_workflow_contract.py.
PULL_REQUEST_FIX_COMMAND_NAMES = {"fix"}

# The manual merge fallback vendored by issue #544, slice VEND-7. Rendered from
# tools/command_sources/finalize.md the way the six sets above are, and like
# them user-invoked and excluded from Haskell name parity. It is its own
# category rather than another pull-request name because it is the only
# packaged workflow that merges at all: every other one stops at the open pull
# request, and CLAUDE.md's merge prohibition holds for them unchanged. This one
# is the single explicitly-invoked exception, taken only when the drainer that
# owns merging cannot be used. Its behavioral assertions live in
# tools/test_finalize_workflow.py.
FINALIZE_COMMAND_NAMES = {"finalize"}

# What a Claude Code installation must actually discover in commands/.
EXPECTED_COMMAND_NAMES = (
    HASKELL_PARITY_COMMAND_NAMES
    | DRAFTING_COMMAND_NAMES
    | DOCUMENT_COMMAND_NAMES
    | ROADMAP_COMMAND_NAMES
    | PUBLICATION_COMMAND_NAMES
    | BACKLOG_COMMAND_NAMES
    | PROJECT_REVIEW_COMMAND_NAMES
    | DRAINER_COMMAND_NAMES
    | PULL_REQUEST_FIX_COMMAND_NAMES
    | FINALIZE_COMMAND_NAMES
)

# Keys that would let a packaged command's frontmatter or manifest silently
# override the model, reasoning effort, permission mode, or working
# directory Kanban's own CLI spawn already pins
# (docs/agent-workflow-contract.md §2.1-§2.2). Claude Code's own command
# frontmatter genuinely supports `model:` (see the personal
# ~/.claude/commands/pr-revise.md this issue replaces, which set
# `model: "claude-sonnet-5"` and `effort: "xhigh"`), so this is a real risk
# to guard, not just defense in depth.
FORBIDDEN_FRONTMATTER_KEYS = {
    "model",
    "effort",
    "reasoning_effort",
    "reasoningEffort",
    "sandbox",
    "approval",
    "approvalPolicy",
    "approval_policy",
    "permission-mode",
    "permissionMode",
    "cwd",
    "workingDirectory",
    "working_directory",
}

FORBIDDEN_MANIFEST_KEYS = FORBIDDEN_FRONTMATTER_KEYS

# Personal, non-namespaced path fragments that must never appear in a
# tracked packaged asset. Kanban's own home-relative convention (e.g.
# `Library/Application Support/kanban/...`) is namespaced and allowed; see
# docs/agent-workflow-contract.md §5.
FORBIDDEN_PATH_FRAGMENTS = (
    "/Users/",
    "$HOME/work/",
    "~/work/approve-issues",
    "/.codex/skills/",
    "/.claude/commands/",
)

FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)
FRONTMATTER_KEY_RE = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*):", re.MULTILINE)


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def kanban_plugin_entry() -> dict:
    """The marketplace's own entry for this plugin, which duplicates the
    plugin manifest's version and description and must agree with both."""
    data = load_json(MARKETPLACE_MANIFEST)
    return next(item for item in data["plugins"] if item.get("name") == "kanban")


def iter_tracked_plugin_files():
    # Queries git directly (not a filesystem walk): running the wider test
    # suite via `unittest discover` (no PYTHONDONTWRITEBYTECODE) imports
    # review_pr.py and writes a real __pycache__/*.pyc beside it as a side
    # effect of that very same test run. A directory walk would then flag
    # that freshly-written, never-committed cache file as a stray tracked
    # asset; only git's own view of what is actually committed can tell
    # the two apart.
    proc = subprocess.run(
        ["git", "ls-files", "--", "claude-plugin"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    for relative_path in proc.stdout.splitlines():
        if relative_path:
            yield REPO_ROOT / relative_path


def find_forbidden_keys(value: Any, path: str = "") -> list[str]:
    hits: list[str] = []
    if isinstance(value, dict):
        for key, nested in value.items():
            if key in FORBIDDEN_MANIFEST_KEYS:
                hits.append(f"{path}/{key}" if path else key)
            hits.extend(find_forbidden_keys(nested, f"{path}/{key}"))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            hits.extend(find_forbidden_keys(item, f"{path}[{index}]"))
    return hits


def frontmatter_keys(text: str) -> set[str]:
    match = FRONTMATTER_RE.match(text)
    if match is None:
        return set()
    return {key.lower() for key in FRONTMATTER_KEY_RE.findall(match.group(1))}


class MarketplaceAndPluginManifestTests(unittest.TestCase):
    def test_marketplace_manifest_points_at_the_tracked_plugin_directory(self):
        data = load_json(MARKETPLACE_MANIFEST)
        plugins = data.get("plugins")
        self.assertIsInstance(plugins, list)
        kanban_entries = [item for item in plugins if item.get("name") == "kanban"]
        self.assertEqual(len(kanban_entries), 1, "marketplace.json must declare exactly one kanban plugin entry")
        source = kanban_entries[0]["source"]
        self.assertIsInstance(source, str, "local plugin source must be a plain relative path string")
        marketplace_root = MARKETPLACE_MANIFEST.parent.parent
        self.assertEqual(marketplace_root, CLAUDE_PLUGIN_ROOT)
        resolved = (marketplace_root / source).resolve()
        self.assertEqual(resolved, PLUGIN_ROOT)

    def test_plugin_manifest_is_valid_and_declares_no_forbidden_configuration(self):
        data = load_json(PLUGIN_MANIFEST)
        self.assertEqual(data.get("name"), "kanban")
        self.assertEqual(data.get("commands"), "./commands/")
        self.assertNotIn("mcpServers", data, "the packaged plugin must not declare an MCP server dependency")
        self.assertNotIn("skills", data, "issue #77 packages workflows as commands, not skills")
        hits = find_forbidden_keys(data)
        self.assertEqual(hits, [], f"plugin.json must not set model/effort/sandbox/approval/cwd config: {hits}")

    def test_marketplace_manifest_declares_no_forbidden_configuration(self):
        data = load_json(MARKETPLACE_MANIFEST)
        hits = find_forbidden_keys(data)
        self.assertEqual(hits, [], f"marketplace.json must not set model/effort/sandbox/approval/cwd config: {hits}")


class CommandDiscoveryTests(unittest.TestCase):
    def test_commands_directory_contains_exactly_the_packaged_workflows(self):
        found = {path.stem for path in COMMANDS_ROOT.glob("*.md")}
        self.assertEqual(found, EXPECTED_COMMAND_NAMES)

    def test_discovery_is_a_strict_superset_of_the_haskell_parity_set(self):
        # The two concepts must stay distinct: discovery covers every packaged
        # workflow, while WorkflowNameParityTests pins only the ones Kanban's
        # Haskell code spawns. Collapsing them back into one constant would
        # either break parity or silently stop discovering the drafting,
        # document, and roadmap commands.
        self.assertTrue(HASKELL_PARITY_COMMAND_NAMES < EXPECTED_COMMAND_NAMES)
        self.assertEqual(
            EXPECTED_COMMAND_NAMES - HASKELL_PARITY_COMMAND_NAMES,
            DRAFTING_COMMAND_NAMES
            | DOCUMENT_COMMAND_NAMES
            | ROADMAP_COMMAND_NAMES
            | PUBLICATION_COMMAND_NAMES
            | BACKLOG_COMMAND_NAMES
            | PROJECT_REVIEW_COMMAND_NAMES
            | DRAINER_COMMAND_NAMES
            | PULL_REQUEST_FIX_COMMAND_NAMES
            | FINALIZE_COMMAND_NAMES,
        )
        self.assertEqual(DRAFTING_COMMAND_NAMES & DOCUMENT_COMMAND_NAMES, set())
        self.assertEqual(ROADMAP_COMMAND_NAMES & DRAFTING_COMMAND_NAMES, set())
        self.assertEqual(ROADMAP_COMMAND_NAMES & DOCUMENT_COMMAND_NAMES, set())
        self.assertEqual(
            PUBLICATION_COMMAND_NAMES
            & (DRAFTING_COMMAND_NAMES | DOCUMENT_COMMAND_NAMES | ROADMAP_COMMAND_NAMES),
            set(),
        )
        self.assertEqual(
            BACKLOG_COMMAND_NAMES
            & (
                DRAFTING_COMMAND_NAMES
                | DOCUMENT_COMMAND_NAMES
                | ROADMAP_COMMAND_NAMES
                | PUBLICATION_COMMAND_NAMES
            ),
            set(),
        )
        self.assertEqual(
            PROJECT_REVIEW_COMMAND_NAMES
            & (
                DRAFTING_COMMAND_NAMES
                | DOCUMENT_COMMAND_NAMES
                | ROADMAP_COMMAND_NAMES
                | PUBLICATION_COMMAND_NAMES
                | BACKLOG_COMMAND_NAMES
            ),
            set(),
        )
        self.assertEqual(
            DRAINER_COMMAND_NAMES
            & (
                DRAFTING_COMMAND_NAMES
                | DOCUMENT_COMMAND_NAMES
                | ROADMAP_COMMAND_NAMES
                | PUBLICATION_COMMAND_NAMES
                | BACKLOG_COMMAND_NAMES
                | PROJECT_REVIEW_COMMAND_NAMES
            ),
            set(),
        )
        self.assertEqual(
            FINALIZE_COMMAND_NAMES
            & (
                DRAFTING_COMMAND_NAMES
                | DOCUMENT_COMMAND_NAMES
                | ROADMAP_COMMAND_NAMES
                | PUBLICATION_COMMAND_NAMES
                | BACKLOG_COMMAND_NAMES
                | PROJECT_REVIEW_COMMAND_NAMES
                | DRAINER_COMMAND_NAMES
                | PULL_REQUEST_FIX_COMMAND_NAMES
            ),
            set(),
        )

    def test_the_remaining_codex_only_document_workflow_is_not_packaged_here(self):
        for name in CODEX_ONLY_DOCUMENT_WORKFLOWS:
            self.assertNotIn(name, EXPECTED_COMMAND_NAMES)
            self.assertFalse(
                (COMMANDS_ROOT / f"{name}.md").exists(),
                f"{name} is Codex-only "
                "(docs/document-workflow-contract.md §3.5); authoring a Claude "
                "counterpart is new behavior no pinned source defines",
            )

    def test_repair_is_a_spawned_workflow_and_not_a_drafting_one(self):
        # Kanban's `r` spawns /repair for a red Done card (issue #127), so it
        # is pinned by parity like the other spawned workflows — and it is
        # still not part of the declared drafting surface
        # docs/drafting-workflow-contract.md and
        # tools/test_drafting_workflow_contract.py pin at exactly nine assets.
        self.assertIn("repair", HASKELL_PARITY_COMMAND_NAMES)
        self.assertNotIn("repair", DRAFTING_COMMAND_NAMES)

    def test_each_command_declares_a_description_and_no_forbidden_frontmatter(self):
        for name in EXPECTED_COMMAND_NAMES:
            command_md = COMMANDS_ROOT / f"{name}.md"
            self.assertTrue(command_md.is_file(), f"missing {command_md}")
            text = command_md.read_text(encoding="utf-8")
            match = FRONTMATTER_RE.match(text)
            self.assertIsNotNone(match, f"{command_md} must open with a --- frontmatter block")
            keys = frontmatter_keys(text)
            self.assertIn("description", keys, f"{command_md} frontmatter must declare description:")
            forbidden_lower = {key.lower() for key in FORBIDDEN_FRONTMATTER_KEYS}
            hits = keys & forbidden_lower
            self.assertEqual(hits, set(), f"{command_md} frontmatter must not set: {hits}")


class WorkflowNameParityTests(unittest.TestCase):
    """Pins the Kanban-spawned command names to the exact `/`-prefixed tokens
    Kanban's Haskell invocation code spawns for the Claude brand, so a
    rename on either side fails this test instead of failing silently at
    runtime. Scoped to HASKELL_PARITY_COMMAND_NAMES, not the full discovery
    set: the drafting commands issue #118 packaged are user- or
    daemon-invoked, so Kanban's Haskell code must NOT spawn them."""

    def test_claude_workflow_tokens_match_packaged_command_names(self):
        solve_source = SOLVE_HS.read_text(encoding="utf-8")
        solve_tokens = set(re.findall(r'workflowName \w+ ClaudeSolver = "/([\w-]+)"', solve_source))
        self.assertEqual(solve_tokens, {"solve"}, "src/Kanban/Solve.hs workflowName Claude tokens changed")

        pr_flow_source = PR_FLOW_HS.read_text(encoding="utf-8")
        self.assertIn(
            'commandName name = if brand == CodexSolver then "$" <> name else "/" <> name',
            pr_flow_source,
            "src/Kanban/PullRequestFlow.hs commandName no longer prefixes the Claude brand with /",
        )
        pr_flow_tokens = set(re.findall(r'commandName "([\w-]+)"', pr_flow_source))
        self.assertEqual(
            pr_flow_tokens,
            {"pr-review", "pr-rereview", "pr-revise", "repair"},
            "src/Kanban/PullRequestFlow.hs commandName tokens changed",
        )

        ui_source = UI_HS.read_text(encoding="utf-8")
        ui_tokens = set(re.findall(r'commandName "([\w-]+)"', ui_source))
        self.assertLessEqual(ui_tokens, pr_flow_tokens, "src/Kanban/UI.hs invokes a command PullRequestFlow.hs does not")

        all_tokens = solve_tokens | pr_flow_tokens
        self.assertEqual(all_tokens, HASKELL_PARITY_COMMAND_NAMES)

    def test_no_drafting_command_is_spawned_by_kanbans_haskell_code(self):
        # The other half of the discovery/parity split: a workflow outside the
        # parity set appearing in Kanban's own invocation surface would mean
        # this module's parity set is wrong, not that the non-parity set
        # should grow.
        haskell_sources = "\n".join(
            path.read_text(encoding="utf-8") for path in (SOLVE_HS, PR_FLOW_HS, UI_HS)
        )
        spawned = set(re.findall(r'(?:workflowName \w+ \w+ = "|commandName ")[/$]?([\w-]+)"', haskell_sources))
        # Non-vacuous: the same scan must still recover every name Kanban does
        # spawn, so an extraction that silently matched nothing fails here.
        self.assertEqual(spawned & EXPECTED_COMMAND_NAMES, HASKELL_PARITY_COMMAND_NAMES)
        self.assertEqual(spawned & DRAFTING_COMMAND_NAMES, set())
        self.assertEqual(spawned & DOCUMENT_COMMAND_NAMES, set())


class NoPersonalPathTests(unittest.TestCase):
    def test_no_packaged_asset_references_a_personal_or_untracked_path(self):
        offenders = []
        for path in iter_tracked_plugin_files():
            if path.suffix in {".pyc"} or "__pycache__" in path.parts:
                offenders.append(f"{path}: compiled/cache artifact must not be tracked")
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            for fragment in FORBIDDEN_PATH_FRAGMENTS:
                if fragment in text:
                    offenders.append(f"{path}: contains forbidden path fragment {fragment!r}")
        self.assertEqual(offenders, [], "\n".join(offenders))


class IssueReviewBackendResolutionTests(unittest.TestCase):
    """The coordinator's approver_path() must resolve the canonical
    issue-review backend with the same precedence
    Kanban.Review.Canonical.resolveCanonicalIssueReviewer uses -- environment override,
    then the installer's discovery record, then the directory that record
    lives in -- and never a personal ~/work/approve-issues.py default."""

    def test_review_pr_matches_the_haskell_canonical_resolution(self):
        # Both sides read one document rather than each rebuilding a default,
        # so what has to match is the record's location and the field in it.
        review_hs_source = REVIEW_HS.read_text(encoding="utf-8")
        managed_paths_source = MANAGED_PATHS_HS.read_text(encoding="utf-8")
        self.assertIn('lookupEnv "KANBAN_ISSUE_REVIEW_INSTALL_DIR"', review_hs_source)
        self.assertIn(
            "Library/Application Support/kanban/issue-review/config.json",
            managed_paths_source,
        )
        self.assertIn('"backend_path"', review_hs_source)
        # The default install directory is Python's to own now; Haskell
        # derives it from the record's own path instead of respelling it.
        for source in (review_hs_source, managed_paths_source):
            self.assertNotIn(
                "Library/Application Support/kanban/issue-review/approve_issues.py",
                source,
            )
        self.assertIn(
            "/.local/share/kanban/issue-review/config.json", managed_paths_source
        )

        # Since issue #445 the coordinator probes both locations too, in the
        # same order Haskell does, so both spellings must be present in it.
        # Asserting only the macOS one would pass against a coordinator that
        # had lost half the probe, which is the half-blind gate that issue's
        # requirement 10 forbids.
        coordinator_source = REVIEW_COORDINATOR.read_text(encoding="utf-8")
        self.assertIn('os.environ.get("KANBAN_ISSUE_REVIEW_INSTALL_DIR")', coordinator_source)
        for token in (
            "Library/Application Support/kanban/issue-review/config.json",
            "/.local/share/kanban/issue-review/config.json",
        ):
            self.assertIn(token, coordinator_source)
        self.assertIn('os.environ.get("XDG_DATA_HOME")', coordinator_source)
        self.assertIn('"backend_path"', coordinator_source)
        self.assertIn("approve_issues.py", coordinator_source)
        self.assertNotIn('"work" / "approve-issues.py"', coordinator_source)
        self.assertIn("python3 tools/install_issue_review.py", coordinator_source)

    def test_solve_gate_check_matches_the_haskell_canonical_resolution(self):
        # solve can run against any repository Kanban is pointed at, so its
        # gate check must resolve the Kanban-managed install location
        # rather than assume the repository under review tracks
        # tools/approve_issues.py itself.
        solve_source = (COMMANDS_ROOT / "solve.md").read_text(encoding="utf-8")
        self.assertIn("KANBAN_ISSUE_REVIEW_INSTALL_DIR", solve_source)
        # Both record spellings, for the same reason the coordinator owes
        # both: the fence probes the XDG location and then the `~/Library`
        # one, and a pin on one of them alone cannot see the other reverted.
        for token in (
            "Library/Application Support/kanban/issue-review/config.json",
            "/.local/share/kanban/issue-review/config.json",
        ):
            self.assertIn(token, solve_source)
        self.assertIn("XDG_DATA_HOME", solve_source)
        self.assertIn("backend_path", solve_source)
        self.assertIn("python3 tools/install_issue_review.py", solve_source)


def load_review_pr_module():
    """Import review_pr.py by file path (it lives under claude-plugin/, not
    tools/, so it is never on sys.path via `-s tools` discovery)."""
    spec = importlib.util.spec_from_file_location("kanban_claude_plugin_review_pr", REVIEW_COORDINATOR)
    module = importlib.util.module_from_spec(spec)
    # dataclass field resolution looks the module up in sys.modules by name
    # while exec_module is still running, so it must be registered first.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ConfiguredWorkflowLabelTests(unittest.TestCase):
    """The coordinator reviews arbitrary target repositories, not necessarily
    a Kanban checkout, so it cannot import tools/kanban_config.py; it must
    still resolve the same global+repository-override approval/changes-
    requested labels from ~/.config/kanban/config.toml (or --config) that
    the dashboard and tools/approve_issues.py/drain_prs.py use."""

    def test_defaults_when_no_config_file_exists(self):
        module = load_review_pr_module()
        with tempfile.TemporaryDirectory() as tmp:
            missing = str(Path(tmp) / "does-not-exist.toml")
            self.assertEqual(
                module.resolve_workflow_labels(missing, "coghex/kanban"),
                ("reviewed:approve", "reviewed:changes"),
            )

    def test_global_and_repository_override_resolution(self):
        module = load_review_pr_module()
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.toml"
            config_path.write_text(
                "\n".join(
                    [
                        '[workflow]',
                        'approval_label = "lgtm"',
                        'changes_requested_label = "needs-work"',
                        '',
                        '[repositories."coghex/kanban".workflow]',
                        'approval_label = "ship-it"',
                        '',
                        '[repositories."other/repo".workflow]',
                        'approval_label = "should-not-apply"',
                    ]
                ),
                encoding="utf-8",
            )
            self.assertEqual(
                module.resolve_workflow_labels(str(config_path), "coghex/kanban"),
                ("ship-it", "needs-work"),
            )
            # An unrelated repository table has no effect.
            self.assertEqual(
                module.resolve_workflow_labels(str(config_path), "unrelated/repo"),
                ("lgtm", "needs-work"),
            )
            # Override keys are canonical lowercase, and the dashboard,
            # approve_issues.py, and drain_prs.py fold the resolved identity
            # before this lookup. A mixed-case clone must not leave this
            # coordinator writing and verifying the global verdict label
            # while they use the override's.
            for mixed_case in ("Coghex/Kanban", "COGHEX/KANBAN"):
                self.assertEqual(
                    module.resolve_workflow_labels(str(config_path), mixed_case),
                    ("ship-it", "needs-work"),
                )

    def test_set_and_clear_verdict_label_use_the_resolved_labels(self):
        module = load_review_pr_module()
        with mock.patch.object(module, "run") as run_mock:
            module.set_verdict_label(Path("/fake-repo"), "coghex/kanban", 89, "APPROVE", "lgtm", "needs-work")
        run_mock.assert_called_once_with(
            ["gh", "pr", "edit", "89", "-R", "coghex/kanban", "--add-label", "lgtm", "--remove-label", "needs-work"],
            cwd=Path("/fake-repo"),
        )
        with mock.patch.object(module, "run") as run_mock:
            module.clear_verdict_labels(Path("/fake-repo"), "coghex/kanban", 89, "lgtm", "needs-work")
        run_mock.assert_called_once_with(
            ["gh", "pr", "edit", "89", "-R", "coghex/kanban", "--remove-label", "lgtm", "--remove-label", "needs-work"],
            cwd=Path("/fake-repo"),
        )

    def test_accepts_a_config_cli_flag(self):
        coordinator_source = REVIEW_COORDINATOR.read_text(encoding="utf-8")
        self.assertIn('"--config"', coordinator_source)
        self.assertIn("resolve_workflow_labels", coordinator_source)

    def test_check_issue_forwards_config_path_to_the_approval_gate(self):
        # The gate check shells out to the installed approve_issues.py, which
        # independently resolves workflow config; without forwarding
        # --config, a dashboard-selected non-default config could approve a
        # PR under different labels than this coordinator just published.
        module = load_review_pr_module()
        response = json.dumps({"issue": 34, "approved": True})
        fake_result = subprocess.CompletedProcess(args=[], returncode=0, stdout=response, stderr="")
        with mock.patch.object(
            module, "approver_path", return_value=Path("/fake-approve-issues.py")
        ), mock.patch.object(module, "run", return_value=fake_result) as run_mock:
            module.check_issue(Path("/fake-repo"), "coghex/kanban", 34, "/tmp/custom-config.toml")
        called_args = run_mock.call_args.args[0]
        self.assertIn("--config", called_args)
        self.assertEqual(called_args[called_args.index("--config") + 1], "/tmp/custom-config.toml")
        self.assertIn("--repo", called_args)
        self.assertEqual(called_args[called_args.index("--repo") + 1], "coghex/kanban")

        with mock.patch.object(
            module, "approver_path", return_value=Path("/fake-approve-issues.py")
        ), mock.patch.object(module, "run", return_value=fake_result) as run_mock:
            module.check_issue(Path("/fake-repo"), "coghex/kanban", 34)
        self.assertNotIn("--config", run_mock.call_args.args[0])

    def test_verify_publication_forwards_config_path_to_its_gate_recheck(self):
        # verify_publication's final issue-gate recheck must use the same
        # config as the initial gate and the label mutation; otherwise a
        # non-default --config publishes under custom labels but then fails
        # this recheck (which would use approve_issues.py's own defaults)
        # and clears the just-set verdict label.
        module = load_review_pr_module()
        pr = {"number": 89, "headRefOid": "a" * 40, "labels": [{"name": "lgtm"}]}
        gate = {"approved": True, "key": "k1"}
        marker = mock.Mock()
        marker.group.side_effect = lambda name: {
            "head": "a" * 40,
            "verdict": "APPROVE",
            "models": "unspecified",
            "reviewers": "codex",
        }[name]
        with mock.patch.object(module, "pr_view", return_value=pr), mock.patch.object(
            module, "gate_status", return_value=gate
        ) as gate_status_mock, mock.patch.object(
            module, "viewer_login", return_value="kanban-bot"
        ), mock.patch.object(
            module, "pr_comments", return_value=[]
        ), mock.patch.object(
            module, "latest_owned_review_marker", return_value=(marker, "https://example.test/comment")
        ):
            module.verify_publication(
                Path("/fake-repo"),
                "coghex/kanban",
                89,
                [module.CODEX_REVIEWER],
                ["unspecified"],
                "a" * 40,
                "APPROVE",
                "k1",
                "lgtm",
                "needs-work",
                allow_no_issue=False,
                config_path="/tmp/custom-config.toml",
            )
        gate_status_mock.assert_called_once_with(
            Path("/fake-repo"), pr, "coghex/kanban", allow_no_issue=False, config_path="/tmp/custom-config.toml",
        )

    def test_resolve_remote_name_defaults_and_reads_a_configured_global_value(self):
        module = load_review_pr_module()
        with tempfile.TemporaryDirectory() as tmp:
            missing = str(Path(tmp) / "does-not-exist.toml")
            self.assertEqual(module.resolve_remote_name(missing), "origin")

            configured = Path(tmp) / "config.toml"
            configured.write_text('remote_name = "upstream"\n', encoding="utf-8")
            self.assertEqual(module.resolve_remote_name(str(configured)), "upstream")

    def test_ensure_commit_and_extract_source_fetch_from_the_configured_remote(self):
        # A dashboard configured with a non-origin remote_name (and no
        # "origin" remote at all) must still be able to fetch a missing PR
        # head for review extraction, when that remote already points at
        # the effective repo.
        module = load_review_pr_module()

        def fake_subprocess_run(args, **kwargs):
            if args[:3] == ["git", "cat-file", "-e"]:
                return mock.Mock(returncode=1)
            if args[:3] == ["git", "remote", "get-url"]:
                return mock.Mock(returncode=0, stdout="git@github.com:coghex/kanban.git\n")
            raise AssertionError(f"unexpected subprocess.run call: {args}")

        with mock.patch.object(module, "subprocess") as subprocess_mock, mock.patch.object(
            module, "run"
        ) as run_mock:
            subprocess_mock.run.side_effect = fake_subprocess_run
            module.ensure_commit(Path("/fake-repo"), "coghex/kanban", 89, "a" * 40, "upstream")
        fetch_call = run_mock.call_args_list[0]
        self.assertEqual(
            fetch_call.args[0], ["git", "fetch", "--no-tags", "upstream", "pull/89/head"]
        )

        with mock.patch.object(
            module, "ensure_commit"
        ) as ensure_commit_mock, mock.patch.object(
            module, "subprocess"
        ) as subprocess_mock, mock.patch.object(
            module, "make_tree_read_only"
        ):
            subprocess_mock.run.return_value = mock.Mock(returncode=0, stdout=b"")
            with mock.patch.object(module.tarfile, "open"):
                module.extract_source(Path("/fake-repo"), "coghex/kanban", 89, "a" * 40, Path("/fake-dest"), "upstream")
        ensure_commit_mock.assert_called_once_with(Path("/fake-repo"), "coghex/kanban", 89, "a" * 40, "upstream")

    def test_ensure_commit_fetches_directly_from_the_explicit_repo_when_the_remote_points_elsewhere(self):
        # A fork checkout reviewing an explicit --repo upstream/repo whose
        # local "origin" remote still points at the fork must fetch the PR
        # ref from upstream directly, not silently pull the fork's #89.
        module = load_review_pr_module()

        def fake_subprocess_run(args, **kwargs):
            if args[:3] == ["git", "cat-file", "-e"]:
                return mock.Mock(returncode=1)
            if args[:3] == ["git", "remote", "get-url"]:
                return mock.Mock(returncode=0, stdout="git@github.com:fork-owner/kanban.git\n")
            raise AssertionError(f"unexpected subprocess.run call: {args}")

        with mock.patch.object(module, "subprocess") as subprocess_mock, mock.patch.object(
            module, "run"
        ) as run_mock:
            subprocess_mock.run.side_effect = fake_subprocess_run
            module.ensure_commit(Path("/fake-repo"), "upstream-owner/kanban", 89, "a" * 40, "origin")
        fetch_call = run_mock.call_args_list[0]
        self.assertEqual(
            fetch_call.args[0],
            ["git", "fetch", "--no-tags", "https://github.com/upstream-owner/kanban.git", "pull/89/head"],
        )

    def test_parse_repository_name_handles_ssh_https_and_bare_forms(self):
        module = load_review_pr_module()
        self.assertEqual(module.parse_repository_name("git@github.com:coghex/kanban.git"), "coghex/kanban")
        self.assertEqual(module.parse_repository_name("https://github.com/coghex/kanban.git"), "coghex/kanban")
        self.assertEqual(module.parse_repository_name("https://github.com/coghex/kanban"), "coghex/kanban")
        self.assertEqual(module.parse_repository_name("coghex/kanban"), "coghex/kanban")
        self.assertIsNone(module.parse_repository_name("not-a-repo"))

    def test_resolve_repository_uses_the_configured_remote_not_ghs_own_inference(self):
        # A checkout whose "origin" points at a fork while remote_name=upstream
        # is configured must resolve the upstream owner/name — proving this
        # never falls back to gh's own (potentially different) inferred repo.
        module = load_review_pr_module()
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.toml"
            config_path.write_text('remote_name = "upstream"\n', encoding="utf-8")
            with mock.patch.object(module, "subprocess") as subprocess_mock:
                subprocess_mock.run.return_value = mock.Mock(
                    returncode=0, stdout="git@github.com:coghex/kanban.git\n", stderr=""
                )
                repo = module.resolve_repository(Path("/fake-repo"), str(config_path))
            self.assertEqual(repo, "coghex/kanban")
            subprocess_mock.run.assert_called_once_with(
                ["git", "remote", "get-url", "upstream"],
                cwd=Path("/fake-repo"),
                capture_output=True,
                text=True,
                check=False,
            )

    def test_resolve_repository_raises_when_the_configured_remote_is_missing(self):
        module = load_review_pr_module()
        with mock.patch.object(module, "subprocess") as subprocess_mock:
            subprocess_mock.run.return_value = mock.Mock(
                returncode=1, stdout="", stderr="No such remote 'upstream'"
            )
            with self.assertRaises(module.WorkflowError):
                module.resolve_repository(Path("/fake-repo"), None)

    def test_resolve_repository_lets_an_explicit_repo_override_win_without_touching_git(self):
        # Mirrors Kanban's own --repo option: a fork checkout must be able to
        # review upstream's PR explicitly, without resolve_repository ever
        # falling back to (or even consulting) the checkout's own remote.
        module = load_review_pr_module()
        with mock.patch.object(module, "subprocess") as subprocess_mock:
            repo = module.resolve_repository(Path("/fake-repo"), None, "upstream-owner/upstream-repo")
        self.assertEqual(repo, "upstream-owner/upstream-repo")
        subprocess_mock.run.assert_not_called()

    def test_resolve_repository_raises_on_an_unparseable_explicit_repo(self):
        module = load_review_pr_module()
        with self.assertRaises(module.WorkflowError):
            module.resolve_repository(Path("/fake-repo"), None, "not-a-repo")


class SolveGateEscalationTests(unittest.TestCase):
    """solve must escalate with the exact terminal line Kanban's own
    invocation prompt uses (src/Kanban/Solve.hs), not a paraphrase, so
    Kanban's KANBAN_NEEDS_INPUT handling recognizes it."""

    ESCALATION_TEXT = "KANBAN_NEEDS_INPUT: This issue needs canonical review; press r on the issue, then retry."

    def test_escalation_text_matches_solve_hs_verbatim(self):
        solve_hs_source = SOLVE_HS.read_text(encoding="utf-8")
        self.assertIn(self.ESCALATION_TEXT, solve_hs_source)

        solve_command_source = (COMMANDS_ROOT / "solve.md").read_text(encoding="utf-8")
        self.assertIn(self.ESCALATION_TEXT, solve_command_source)


class ReviewCoordinatorSelfTestTests(unittest.TestCase):
    def test_review_pr_self_test_passes_standalone(self):
        proc = subprocess.run(
            [sys.executable, "-B", str(REVIEW_COORDINATOR), "--self-test"],
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("self-test passed", proc.stdout)


def roster_cell(source: str, section: str) -> dict:
    """The model/effort/display of one [roles.<role>.<provider>] table.

    A deliberately small reader rather than a TOML parse: the assertion is
    that the pinned Python constants equal what that one table declares, and
    a table that is absent or missing a key must fail loudly here rather than
    resolve to None and compare equal to nothing.
    """

    lines = source.splitlines()
    header = "[" + section + "]"
    if header not in lines:
        raise AssertionError(f"models.toml.example declares no {header} table")
    cell = {}
    for line in lines[lines.index(header) + 1 :]:
        stripped = line.strip()
        if stripped.startswith("["):
            break
        if "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        cell[key.strip()] = value.strip().strip('"')
    missing = {"model", "effort"} - set(cell)
    if missing:
        raise AssertionError(f"{header} declares no {sorted(missing)}")
    return cell


class NestedReviewerModelPinningTests(unittest.TestCase):
    """Round-2 review finding: unlike the self-reviewed known-origin case
    (where Kanban's own top-level spawn pins the model outside this
    coordinator's visibility), invoke_codex/invoke_claude fully construct
    the nested-reviewer subprocess call for /pr-revise's cross-brand
    handoff and the dual-review fallback, so they can and must pin and
    verify the canonical reviewer model/effort rather than deferring to an
    arbitrary local default.

    Since MODEL-2 the Haskell half is the pr_review roster cell rather than a
    literal in src/Kanban/PullRequestFlow.hs: Kanban's own PR review and
    rereview spawns resolve roles.pr_review.<provider> from the roster, and
    Spec.Config.Models holds models.toml.example byte-for-byte against the
    compiled defaults, so reading the example here still pins exactly what
    those spawns use. Since MODEL-4 the Python half is roster-backed too: the
    coordinator resolves the same cells through its own bundled
    kanban_models.py, and its four constants are the compiled fallbacks that
    reader is handed for a host carrying no roster file at all. Holding those
    fallbacks against the example is therefore the same gate it always was --
    the two lanes cannot silently diverge -- with the mechanism moved off a
    pair of literals a spawn read directly. This is a deliberate, reviewed
    divergence from codex-plugin's otherwise-identical coordinator copy and
    from docs/agent-workflow-contract.md §2.2's general policy for this one
    nested-spawn path in this plugin only."""

    def test_nested_reviewer_models_match_the_haskell_canonical_review_models(self):
        roster_source = MODELS_TOML_EXAMPLE.read_text(encoding="utf-8")
        codex_cell = roster_cell(roster_source, "roles.pr_review.codex")
        claude_cell = roster_cell(roster_source, "roles.pr_review.claude")
        self.assertEqual(codex_cell["model"], "gpt-5.6-terra")
        self.assertEqual(codex_cell["effort"], "xhigh")
        self.assertEqual(claude_cell["model"], "claude-opus-5")
        self.assertEqual(claude_cell["effort"], "xhigh")

        # The literals must be gone from the Haskell source, or this gate
        # would keep passing against a stale second authority.
        pr_flow_source = PR_FLOW_HS.read_text(encoding="utf-8")
        for retired in ("codexModel", "codexEffort", "claudeModel", "claudeEffort"):
            self.assertNotIn(retired, pr_flow_source)

        # The coordinator's compiled fallbacks -- what its bundled reader is
        # handed for a host with no roster file, and therefore what a default
        # install spawns -- read out of the file rather than imported, so this
        # gate keeps working on a source-only check of the tracked bundle.
        coordinator = load_review_pr_module()
        with tempfile.TemporaryDirectory() as tmp:
            # A configuration root with no models.toml in it: the fallback is
            # only reachable on the absent-file path, and the host running this
            # suite must not be able to decide the answer.
            with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": tmp}):
                for provider, cell in (("codex", codex_cell), ("claude", claude_cell)):
                    with self.subTest(provider=provider):
                        fallback = coordinator.nested_review_assignment(provider)
                        self.assertEqual(fallback.model, cell["model"])
                        self.assertEqual(fallback.effort, cell["effort"])

        # And the constants those fallbacks are built from stay declared in the
        # coordinator itself, so a reader looking at that file still finds the
        # values it spawns on by default rather than only a call into a reader.
        coordinator_source = REVIEW_COORDINATOR.read_text(encoding="utf-8")
        self.assertIn(
            f'CODEX_NESTED_REVIEW_MODEL = "{codex_cell["model"]}"', coordinator_source
        )
        self.assertIn(
            f'CODEX_NESTED_REVIEW_EFFORT = "{codex_cell["effort"]}"', coordinator_source
        )
        self.assertIn(
            f'CLAUDE_NESTED_REVIEW_MODEL = "{claude_cell["model"]}"', coordinator_source
        )
        self.assertIn(
            f'CLAUDE_NESTED_REVIEW_EFFORT = "{claude_cell["effort"]}"', coordinator_source
        )

    def test_an_unusable_roster_refuses_the_nested_review(self):
        # D-3, on this side of the language boundary: a roster file that is
        # present and will not load must never leave the coordinator spawning
        # the compiled fallbacks and then publishing them as verified fact in
        # the pr-review:v2 marker.
        coordinator = load_review_pr_module()
        with tempfile.TemporaryDirectory() as tmp:
            roster = Path(tmp) / "kanban" / "models.toml"
            roster.parent.mkdir(parents=True)
            roster.write_text("schema_version = 1\nagents = 3\n", encoding="utf-8")
            with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": tmp}):
                for provider in ("codex", "claude"):
                    with self.subTest(provider=provider):
                        with self.assertRaises(coordinator.WorkflowError) as caught:
                            coordinator.nested_review_assignment(provider)
                        message = str(caught.exception)
                        self.assertIn(str(roster), message)
                        self.assertIn("agents", message)
                        self.assertIn("no nested review was performed", message)

    def test_a_roster_file_moves_the_model_the_coordinator_spawns(self):
        # The other half of the same claim: a roster the operator really did
        # edit is what the nested reviewer runs on, not the constants above.
        coordinator = load_review_pr_module()
        edited = MODELS_TOML_EXAMPLE.read_text(encoding="utf-8").replace(
            '[roles.pr_review.codex]\nmodel = "gpt-5.6-terra"\neffort = "xhigh"',
            '[roles.pr_review.codex]\nmodel = "gpt-5.5"\neffort = "medium"',
        )
        self.assertIn('model = "gpt-5.5"', edited)
        with tempfile.TemporaryDirectory() as tmp:
            roster = Path(tmp) / "kanban" / "models.toml"
            roster.parent.mkdir(parents=True)
            roster.write_text(edited, encoding="utf-8")
            with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": tmp}):
                assignment = coordinator.nested_review_assignment("codex")
        self.assertEqual((assignment.model, assignment.effort), ("gpt-5.5", "medium"))

    def test_the_coordinator_loads_the_reader_from_beside_itself(self):
        # An installed bundle has no tools/ sibling, so a plain import would
        # resolve the tracked original only when this file happens to run out
        # of a checkout -- and silently read a different copy's compiled
        # defaults there.
        source = REVIEW_COORDINATOR.read_text(encoding="utf-8")
        self.assertIn(
            'Path(__file__).resolve().parent / "kanban_models.py"', source
        )
        self.assertNotIn("import kanban_models", source)

    def test_invoke_codex_and_invoke_claude_pass_the_resolved_model_flags(self):
        coordinator_source = REVIEW_COORDINATOR.read_text(encoding="utf-8")
        codex_match = re.search(r"def invoke_codex\(.*?(?=\ndef |\Z)", coordinator_source, re.DOTALL)
        self.assertIsNotNone(codex_match)
        self.assertIn('nested_review_assignment("codex")', codex_match.group(0))
        self.assertIn('"--model",\n                model_assignment.model', codex_match.group(0))
        self.assertIn("model_reasoning_effort", codex_match.group(0))

        claude_match = re.search(r"def invoke_claude\(.*?(?=\ndef |\Z)", coordinator_source, re.DOTALL)
        self.assertIsNotNone(claude_match)
        self.assertIn('nested_review_assignment("claude")', claude_match.group(0))
        self.assertIn('"--model",\n            model_assignment.model', claude_match.group(0))
        self.assertIn('"--effort",\n            model_assignment.effort', claude_match.group(0))

    def test_self_test_covers_the_pinned_marker_binding(self):
        # Pins the coordinator's own --self-test (already run standalone by
        # ReviewCoordinatorSelfTestTests) to actually exercise the pinned
        # branch, not just the pre-existing unspecified-model assertions.
        coordinator_source = REVIEW_COORDINATOR.read_text(encoding="utf-8")
        self.assertIn("CODEX_NESTED_REVIEW_MODEL}@{CODEX_NESTED_REVIEW_EFFORT", coordinator_source)
        self.assertIn('"gpt-5.6-terra@xhigh"', coordinator_source)


class ClaudePluginRootReferenceTests(unittest.TestCase):
    """All three PR-flow commands locate the bundled coordinator via
    ${CLAUDE_PLUGIN_ROOT}, the portable path Claude Code substitutes to this
    plugin's own install location regardless of the invoking working
    directory (Kanban spawns these commands with the *reviewed* repository
    as the working directory, not this plugin's own install location)."""

    def test_pr_review_family_locates_the_coordinator_via_claude_plugin_root(self):
        for name in ("pr-review", "pr-rereview", "pr-revise"):
            text = (COMMANDS_ROOT / f"{name}.md").read_text(encoding="utf-8")
            self.assertIn(
                '"${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py"',
                text,
                f"{name}.md must locate the coordinator via ${{CLAUDE_PLUGIN_ROOT}}",
            )

    def test_every_rereview_handoff_preserves_standalone_pr_contracts(self):
        for name in ("pr-rereview", "pr-revise", "repair"):
            text = (COMMANDS_ROOT / f"{name}.md").read_text(encoding="utf-8")
            command_blocks = re.findall(r"```bash\n(.*?)```", text, re.DOTALL)
            expected_actions = ("--rereview", "--publish-verdict") if name == "pr-rereview" else ("--rereview",)
            for action in expected_actions:
                matching_blocks = [block for block in command_blocks if action in block]
                self.assertEqual(
                    len(matching_blocks),
                    1,
                    f"{name}.md must have exactly one {action} coordinator invocation",
                )
                self.assertIn(
                    "--allow-no-issue",
                    matching_blocks[0],
                    f"{name}.md {action} invocation must preserve the standalone PR gate mode",
                )

    def test_the_referenced_coordinator_path_exists_relative_to_the_plugin_root(self):
        # ${CLAUDE_PLUGIN_ROOT} resolves to PLUGIN_ROOT at runtime; confirm
        # the literal relative path every command references actually
        # exists there, so a rename of scripts/review_pr.py would fail
        # this test rather than only failing at runtime.
        resolved = PLUGIN_ROOT / "scripts" / "review_pr.py"
        self.assertEqual(resolved, REVIEW_COORDINATOR)
        self.assertTrue(resolved.is_file())


class ApproverPathResolutionTests(unittest.TestCase):
    """The coordinator's own resolution behaviour, not just its source text:
    the same override/record/fallback precedence Kanban.Review uses, so a
    custom installation cannot pass the dashboard's gate and fail this one
    (issue #155).

    These drive the `~/Library` record, which is one of the two locations
    issue #445 made this coordinator probe. Which of the two it selects, and
    what it reports when neither is occupied, is
    `tools/test_packaged_issue_review_probe.py`'s -- it asserts that against
    both coordinators and the markdown fences together, because all twelve
    owe the same answers."""

    def setUp(self):
        self.module = load_review_pr_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.record_path = (
            self.home / "Library" / "Application Support" / "kanban" / "issue-review" / "config.json"
        )
        self.record_path.parent.mkdir(parents=True)
        self.xdg_record_path = (
            self.home / ".local" / "share" / "kanban" / "issue-review" / "config.json"
        )
        # $HOME redirected so both record paths land inside this temporary
        # machine; the developer's own records are never read. $XDG_DATA_HOME
        # is dropped for the same reason: it would move the first candidate
        # out of this fixture and make the result depend on the host.
        patcher = mock.patch.dict(os.environ, {"HOME": str(self.home)})
        patcher.start()
        self.addCleanup(patcher.stop)
        os.environ.pop("KANBAN_ISSUE_REVIEW_INSTALL_DIR", None)
        os.environ.pop("XDG_DATA_HOME", None)

    def install_backend(self, directory):
        directory.mkdir(parents=True, exist_ok=True)
        backend = directory / "approve_issues.py"
        backend.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        return backend

    def write_record(self, document):
        self.record_path.write_text(document, encoding="utf-8")

    def test_resolves_the_backend_the_record_names(self):
        backend = self.install_backend(self.root / "opt" / "kanban-review")
        self.write_record(json.dumps({"backend_path": str(backend)}))
        self.assertEqual(self.module.approver_path(), backend)

    def test_falls_back_to_the_records_own_directory_when_no_record_exists(self):
        # With neither location occupied the XDG candidate is the record's own
        # directory, on every platform: issue #445's requirement 4 makes that
        # the answer no packaged asset has to pick a platform to reach.
        backend = self.install_backend(self.xdg_record_path.parent)
        self.assertEqual(self.module.approver_path(), backend)

    def test_falls_back_for_a_legacy_document_with_only_a_config_reference(self):
        backend = self.install_backend(self.record_path.parent)
        self.write_record(json.dumps({"config_path": "/Users/example/kanban.toml"}))
        self.assertEqual(self.module.approver_path(), backend)

    def test_the_environment_override_wins_over_the_record(self):
        self.install_backend(self.root / "recorded")
        selected = self.install_backend(self.root / "selected")
        self.write_record(
            json.dumps({"backend_path": str(self.root / "recorded" / "approve_issues.py")})
        )
        with mock.patch.dict(
            os.environ, {"KANBAN_ISSUE_REVIEW_INSTALL_DIR": str(self.root / "selected")}
        ):
            self.assertEqual(self.module.approver_path(), selected)

    def test_a_missing_override_does_not_fall_through_to_the_record(self):
        recorded = self.install_backend(self.root / "recorded")
        self.write_record(json.dumps({"backend_path": str(recorded)}))
        with mock.patch.dict(
            os.environ, {"KANBAN_ISSUE_REVIEW_INSTALL_DIR": str(self.root / "empty")}
        ):
            with self.assertRaises(self.module.WorkflowError) as raised:
                self.module.approver_path()
        self.assertIn("KANBAN_ISSUE_REVIEW_INSTALL_DIR selected", str(raised.exception))
        self.assertNotIn(str(recorded), str(raised.exception))

    def test_a_stale_record_names_the_record_it_came_from(self):
        self.install_backend(self.record_path.parent)
        self.write_record(
            json.dumps({"backend_path": str(self.root / "gone" / "approve_issues.py")})
        )
        with self.assertRaises(self.module.WorkflowError) as raised:
            self.module.approver_path()
        message = str(raised.exception)
        self.assertIn("was not found at", message)
        self.assertIn(str(self.record_path), message)

    def test_an_unreadable_record_is_not_treated_as_absent(self):
        self.install_backend(self.record_path.parent)
        self.write_record('{"backend_path": ')
        with self.assertRaises(self.module.WorkflowError) as raised:
            self.module.approver_path()
        self.assertIn("is unreadable", str(raised.exception))

    def test_a_recorded_path_that_is_not_an_absolute_string_is_rejected(self):
        # An install sits at the fallback directory in every case, so a
        # resolver that fell through would succeed here rather than fail.
        self.install_backend(self.record_path.parent)
        for document in (
            '["/opt/approve_issues.py"]',
            '{"backend_path": 42}',
            '{"backend_path": "opt/approve_issues.py"}',
            # An explicit null is a value the installer never writes, so it is
            # a record corrupted into naming nothing -- not the absent field
            # that means "installed before the record existed".
            '{"backend_path": null}',
        ):
            with self.subTest(document=document):
                self.write_record(document)
                with self.assertRaises(self.module.WorkflowError) as raised:
                    self.module.approver_path()
                self.assertIn("is unreadable", str(raised.exception))

    def test_a_record_link_whose_target_is_gone_is_unreadable_not_absent(self):
        # read_text reports a dangling link as FileNotFoundError, which is
        # indistinguishable from "never written" unless the link itself is
        # stat-ed. The installer refuses to write through a link at this
        # path, so a reader that ran the fallback would disagree with it.
        backend = self.install_backend(self.record_path.parent)
        self.record_path.symlink_to(self.root / "gone.json")
        with self.assertRaises(self.module.WorkflowError) as raised:
            self.module.approver_path()
        message = str(raised.exception)
        self.assertIn("is unreadable", message)
        self.assertIn(str(self.record_path), message)
        self.assertNotIn(str(backend), message)

    def test_a_record_path_occupied_by_a_directory_is_unreadable_not_absent(self):
        backend = self.install_backend(self.record_path.parent)
        self.record_path.mkdir()
        with self.assertRaises(self.module.WorkflowError) as raised:
            self.module.approver_path()
        message = str(raised.exception)
        self.assertIn("is unreadable", message)
        self.assertIn(str(self.record_path), message)
        self.assertNotIn(str(backend), message)


PR_RESOLVER_SENTINEL = (
    "SENTINEL-pr-view-failure: GraphQL: Could not resolve to a PullRequest "
    "with the number of 236."
)
ISSUE_LOOKUP_SENTINEL = "SENTINEL-issue-view-failure: gh: Not Found (HTTP 404)"

# Anything `gh` would accept as a write. The guard promises "Nothing was
# modified"; these are what would make that false.
MUTATING_GH_ARGS = frozenset(
    {
        "edit",
        "comment",
        "close",
        "reopen",
        "merge",
        "create",
        "delete",
        "review",
        "ready",
        "lock",
        "unlock",
        "transfer",
        "pin",
        "unpin",
        "--add-label",
        "--remove-label",
        "--add-assignee",
        "--remove-assignee",
        "--body",
        "--body-file",
        "-X",
        "--method",
        "-f",
        "--field",
        "-F",
        "--raw-field",
    }
)


class PullRequestUrlClassificationTests(unittest.TestCase):
    """`url_names_a_pull_request` reads the path SEGMENT before the number.

    A substring test would misread every issue in a repository literally named
    `pull`, which is the edge case the function's own docstring calls out and
    which already anchors the sibling predicate's asserts in
    tools/approve_issues.py.
    """

    def setUp(self):
        self.module = load_review_pr_module()

    def test_the_segment_before_the_number_decides(self):
        cases = [
            ("https://github.com/owner/repo/pull/1080", True),
            ("https://github.com/owner/repo/issues/1080", False),
            ("https://github.com/owner/repo/pull/1080/", True),
            # A repository named `pull`: `/pull/` appears in every URL it has,
            # so only the segment immediately before the number separates its
            # issues from its pull requests.
            ("https://github.com/owner/pull/issues/12", False),
            ("https://ghe.example/owner/pull/pull/12", True),
            # `pull` as a substring of another segment, and as an owner name.
            ("https://github.com/owner/pull-requests/issues/12", False),
            ("https://github.com/pull/repo/issues/12", False),
            # Unknown or short shapes are never a pull request.
            ("https://example.invalid/7", False),
            ("", False),
        ]
        for url, expected in cases:
            with self.subTest(url=url):
                self.assertEqual(self.module.url_names_a_pull_request(url), expected)


class NumberKindGuardTests(unittest.TestCase):
    """`pr_view` handed an issue number refuses it by name.

    GitHub shares one number space between issues and pull requests, and `gh
    pr view` answers an issue number with a GraphQL resolver error naming
    neither the number's real kind nor the mistake. Driven end to end against
    the Claude bundle's own copy over a fake `gh` on a temporary PATH: no
    network, no GitHub account.
    """

    def setUp(self):
        self.module = load_review_pr_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.checkout = self.root / "checkout"
        self.checkout.mkdir()
        self.fake = fake_cli.FakeCli(self.root / "fake")
        self.fake.install("gh")

    def pr_view(self, number: int):
        with mock.patch.dict(os.environ, self.fake.environ_overrides()):
            return self.module.pr_view(self.checkout, "coghex/kanban", number)

    def gh_calls(self) -> list[list[str]]:
        return [call["args"] for call in self.fake.calls("gh")]

    def test_an_open_pull_request_returns_without_any_classification(self):
        self.fake.script(
            "gh",
            ["pr", "view", "412"],
            stdout=json.dumps(
                {"number": 412, "state": "OPEN", "headRefOid": "a" * 40}
            ),
        )
        value = self.pr_view(412)
        self.assertEqual(value["number"], 412)
        # The classifier is on the failure path only: a healthy review pays
        # nothing for the guard.
        self.assertEqual([call[:2] for call in self.gh_calls()], [["pr", "view"]])

    def test_an_issue_number_is_refused_by_name(self):
        self.fake.script(
            "gh", ["pr", "view", "236"], exit_code=1, stderr=PR_RESOLVER_SENTINEL
        )
        self.fake.script(
            "gh",
            ["issue", "view", "236"],
            stdout=json.dumps({"url": "https://github.com/coghex/kanban/issues/236"}),
        )
        with self.assertRaises(self.module.WorkflowError) as raised:
            self.pr_view(236)
        message = str(raised.exception)
        self.assertIn("#236 is an ISSUE, not a pull request", message)
        self.assertIn("Nothing was modified", message)
        self.assertIn("issue-review workflow for #236", message)
        # The raw resolver error is replaced, not merely appended to.
        self.assertNotIn(PR_RESOLVER_SENTINEL, message)

    def test_refusing_an_issue_number_reads_twice_and_writes_nothing(self):
        self.fake.script(
            "gh", ["pr", "view", "236"], exit_code=1, stderr=PR_RESOLVER_SENTINEL
        )
        self.fake.script(
            "gh",
            ["issue", "view", "236"],
            stdout=json.dumps({"url": "https://github.com/coghex/kanban/issues/236"}),
        )
        with self.assertRaises(self.module.WorkflowError):
            self.pr_view(236)
        calls = self.gh_calls()
        self.assertEqual(
            [call[:2] for call in calls], [["pr", "view"], ["issue", "view"]]
        )
        # The classification read asks for `url` and nothing else.
        self.assertEqual(
            calls[1],
            ["issue", "view", "236", "-R", "coghex/kanban", "--json", "url"],
        )
        # "Nothing was modified" is a claim about observable behavior.
        for call in calls:
            for argument in call:
                self.assertNotIn(
                    argument,
                    MUTATING_GH_ARGS,
                    f"the number-kind guard ran a mutating gh command: {call}",
                )

    def test_an_unresolvable_number_keeps_the_original_pull_request_failure(self):
        self.fake.script(
            "gh", ["pr", "view", "999999"], exit_code=1, stderr=PR_RESOLVER_SENTINEL
        )
        self.fake.script(
            "gh", ["issue", "view", "999999"], exit_code=1, stderr=ISSUE_LOOKUP_SENTINEL
        )
        with self.assertRaises(self.module.WorkflowError) as raised:
            self.pr_view(999999)
        message = str(raised.exception)
        self.assertIn(PR_RESOLVER_SENTINEL, message)
        self.assertNotIn("is an ISSUE", message)
        # The classifier's own failure never displaces the real diagnosis.
        self.assertNotIn(ISSUE_LOOKUP_SENTINEL, message)

    def test_a_number_that_classifies_as_a_pull_request_keeps_the_original_failure(self):
        # A pull request that exists but whose `pr view` read failed (a closed
        # repository, a transient error): the guard must not relabel it an
        # issue, and must not swallow the real failure either.
        self.fake.script(
            "gh", ["pr", "view", "412"], exit_code=1, stderr=PR_RESOLVER_SENTINEL
        )
        self.fake.script(
            "gh",
            ["issue", "view", "412"],
            stdout=json.dumps({"url": "https://github.com/coghex/kanban/pull/412"}),
        )
        with self.assertRaises(self.module.WorkflowError) as raised:
            self.pr_view(412)
        message = str(raised.exception)
        self.assertIn(PR_RESOLVER_SENTINEL, message)
        self.assertNotIn("is an ISSUE", message)


class BundledRosterReaderTests(unittest.TestCase):
    """The reader ships in three homes, held identical the way
    kanban_config.py's copies are.

    Byte equality is what keeps three copies one reader: each coordinator
    reads the roster through the copy beside itself and every other Python
    consumer through the tracked original, and a copy whose compiled defaults
    or loaded-provider semantics had drifted would route -- and, for the
    Claude copy, spawn -- differently from the backend that gates the same
    pipeline. All three are compared here rather than only the two that
    existed before #572, and the diagnostic names the copy that drifted so a
    failure says which file to repair.
    """

    def bundled_copies(self):
        return (
            ("claude-plugin/plugins/kanban/scripts/kanban_models.py", BUNDLED_ROSTER_READER),
            (
                "codex-plugin/plugins/kanban/skills/pr-review/scripts/kanban_models.py",
                CODEX_ROSTER_READER,
            ),
        )

    def test_every_bundled_reader_is_identical_to_its_tracked_source(self):
        for relative_path, copy in self.bundled_copies():
            with self.subTest(copy=relative_path):
                self.assertEqual(
                    copy.read_bytes(),
                    TRACKED_ROSTER_READER.read_bytes(),
                    f"{relative_path} has drifted from tools/kanban_models.py; "
                    "the three copies are the same reader, not a fork. Repair: "
                    f"cp tools/kanban_models.py {relative_path}",
                )

    def test_the_bundled_reader_carries_the_managed_asset_marker(self):
        # The issue-review installer links the tracked original beside
        # approve_issues.py and both it and Kanban.Preflight recognize an
        # installed file by this marker rather than by path, so the identity
        # travels with the bytes into every copy.
        self.assertIn(
            "kanban-managed-asset:issue-review/kanban_models.py",
            TRACKED_ROSTER_READER.read_text(encoding="utf-8"),
        )


class BundleVersionGateTests(unittest.TestCase):
    """A change unit that touches this bundle's tracked content must raise
    its declared version, and the marketplace's duplicate declaration must
    follow it.

    Claude Code serves this marketplace live from the repository directory,
    so the version is not a cache key here the way it is for Codex; it is
    still the one field that records which bundle contents a given install
    was told about, and it is declared twice, so the two spellings agreeing
    is a real invariant rather than bookkeeping.
    """

    def test_the_manifest_declares_a_version_past_the_original(self):
        version = plugin_bundle_gate.declared_version(
            load_json(PLUGIN_MANIFEST), PLUGIN_MANIFEST_PATH
        )
        self.assertTrue(
            plugin_bundle_gate.version_increased(version, ORIGINAL_BUNDLE_VERSION),
            f"{PLUGIN_MANIFEST_PATH} still declares {version!r}, which does not "
            f"record the bundle contents added since {ORIGINAL_BUNDLE_VERSION}",
        )

    def test_the_marketplace_entry_declares_the_same_version(self):
        self.assertEqual(
            kanban_plugin_entry().get("version"),
            load_json(PLUGIN_MANIFEST).get("version"),
            "the marketplace plugin entry and plugin.json declare the same "
            "bundle; a reader that consults either must see the same version",
        )

    def test_the_marketplace_entry_repeats_the_plugin_description_verbatim(self):
        # Both descriptions are parity-checked below, so they cannot drift
        # from the shipped commands -- but they could still drift from each
        # other into two differently-worded correct listings.
        self.assertEqual(
            kanban_plugin_entry().get("description"),
            load_json(PLUGIN_MANIFEST).get("description"),
        )

    def test_the_tracked_tree_owes_no_version_bump(self):
        failures = plugin_bundle_gate.bundle_version_failures(
            REPO_ROOT, BUNDLE_PREFIX, BUNDLE_PREFIX, PLUGIN_MANIFEST_PATH
        )
        self.assertEqual(failures, [], "\n".join(failures))


class PlantedBundleVersionGateTests(unittest.TestCase):
    """The gate above is silent on an untouched default branch by
    construction -- no delta, no obligation -- so on master it proves
    nothing about whether the gate can fail at all.

    These drive the same `bundle_version_failures` entry point against a
    throwaway Git repository shaped like this bundle, planting each way the
    gate is supposed to fire and each way it is supposed to stay quiet.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "checkout"
        self.root.mkdir(parents=True)
        self.manifest = self.root / PLUGIN_MANIFEST_PATH
        self.command = self.root / COMMANDS_PREFIX / "solve.md"
        self.git("init", "-b", "master")
        self.git("config", "user.email", "bundle-gate@example.invalid")
        self.git("config", "user.name", "Bundle Gate Fixture")
        self.git("config", "commit.gpgsign", "false")
        # `__pycache__/` is ignored in this repository precisely because
        # running the suite writes one beside the packaged coordinator; the
        # fixture reproduces that so the ignored-file case is real.
        (self.root / ".gitignore").write_text("__pycache__/\n", encoding="utf-8")
        self.write_manifest(ORIGINAL_BUNDLE_VERSION)
        self.command.parent.mkdir(parents=True, exist_ok=True)
        self.command.write_text("---\ndescription: fixture\n---\n", encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-m", "baseline bundle")
        # Work happens on a branch, exactly as a change unit does: a commit
        # made on the default branch itself would move the baseline with it
        # and leave every delta empty.
        self.git("checkout", "-q", "-b", "work")

    def git(self, *args: str):
        subprocess.run(
            ["git", *args], cwd=self.root, capture_output=True, text=True, check=True
        )

    def write_manifest(self, version: str):
        self.manifest.parent.mkdir(parents=True, exist_ok=True)
        self.manifest.write_text(
            json.dumps({"name": "kanban", "version": version}) + "\n", encoding="utf-8"
        )

    def failures(self) -> list[str]:
        return plugin_bundle_gate.bundle_version_failures(
            self.root, BUNDLE_PREFIX, BUNDLE_PREFIX, PLUGIN_MANIFEST_PATH
        )

    def test_an_untouched_baseline_owes_nothing(self):
        self.assertEqual(self.failures(), [])

    def test_a_committed_content_change_without_a_bump_fails(self):
        self.command.write_text("---\ndescription: revised\n---\n", encoding="utf-8")
        self.git("commit", "-am", "revise the packaged command")
        failures = self.failures()
        self.assertEqual(len(failures), 1)
        self.assertIn(plugin_bundle_gate.VERSION_BUMP_INSTRUCTION, failures[0])
        self.assertIn(f"{COMMANDS_PREFIX}/solve.md", failures[0])

    def test_an_uncommitted_working_tree_edit_already_counts(self):
        # A pull request is judged on the tree it will land, so the gate must
        # fire before the author commits, not only afterwards.
        self.command.write_text("---\ndescription: revised\n---\n", encoding="utf-8")
        self.assertEqual(len(self.failures()), 1)

    def test_a_staged_addition_counts_as_content(self):
        added = self.root / COMMANDS_PREFIX / "repair.md"
        added.write_text("---\ndescription: new\n---\n", encoding="utf-8")
        self.git("add", str(added))
        failures = self.failures()
        self.assertEqual(len(failures), 1)
        self.assertIn(f"{COMMANDS_PREFIX}/repair.md", failures[0])

    def test_a_tracked_deletion_counts_as_content(self):
        self.git("rm", "-q", str(self.command))
        self.assertEqual(len(self.failures()), 1)

    def test_untracked_and_ignored_files_are_never_content(self):
        (self.root / COMMANDS_PREFIX / "scratch.md").write_text("draft", encoding="utf-8")
        cache = self.root / "claude-plugin" / "plugins" / "kanban" / "scripts" / "__pycache__"
        cache.mkdir(parents=True)
        (cache / "review_pr.cpython-312.pyc").write_bytes(b"\x00")
        self.assertEqual(self.failures(), [])

    def test_content_and_version_changing_together_pass(self):
        self.command.write_text("---\ndescription: revised\n---\n", encoding="utf-8")
        self.write_manifest("1.1.0")
        self.assertEqual(self.failures(), [])

    def test_a_lowered_version_is_not_a_bump(self):
        self.command.write_text("---\ndescription: revised\n---\n", encoding="utf-8")
        self.write_manifest("0.9.0")
        self.assertEqual(len(self.failures()), 1)

    def test_a_change_outside_the_bundle_owes_nothing(self):
        (self.root / "README.md").write_text("unrelated\n", encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-m", "unrelated change")
        self.assertEqual(self.failures(), [])

    def test_a_checkout_with_no_default_branch_fails_rather_than_skipping(self):
        # The failure mode this gate must not have: no baseline, no
        # complaint, every bundle change waved through.
        self.command.write_text("---\ndescription: revised\n---\n", encoding="utf-8")
        self.git("branch", "-D", "master")
        with self.assertRaises(plugin_bundle_gate.BundleGateError) as raised:
            self.failures()
        self.assertIn("fetch-depth: 0", str(raised.exception))


class ManifestListingParityTests(unittest.TestCase):
    """Both manifest descriptions enumerate the workflows this bundle ships,
    and both had stopped at the eight commands that existed before
    /process-report and /repair were packaged. The shipped set is derived
    from the tracked command files rather than restated as a constant, so
    vendoring a command without describing it fails here."""

    def shipped(self) -> set[str]:
        return plugin_bundle_gate.tracked_command_names(REPO_ROOT, COMMANDS_PREFIX)

    def enumerating_surfaces(self) -> dict[str, str]:
        return {
            f"{PLUGIN_MANIFEST_PATH} description": load_json(PLUGIN_MANIFEST)["description"],
            f"{MARKETPLACE_MANIFEST_PATH} plugin-entry description": kanban_plugin_entry()["description"],
        }

    def test_the_tracked_command_files_are_the_pinned_discovery_set(self):
        # Non-vacuity for every parity assertion below: they compare against
        # this derived set, so an extraction that silently found nothing
        # would make all of them pass.
        self.assertEqual(self.shipped(), EXPECTED_COMMAND_NAMES)

    def test_both_enumerating_descriptions_name_exactly_the_shipped_commands(self):
        shipped = self.shipped()
        failures = []
        for surface, text in self.enumerating_surfaces().items():
            failures.extend(
                plugin_bundle_gate.parity_failures(
                    surface,
                    plugin_bundle_gate.workflow_identifiers(text, COMMAND_SIGIL),
                    shipped,
                )
            )
        self.assertEqual(failures, [], "\n".join(failures))

    def test_the_marketplace_description_is_deliberately_non_enumerative(self):
        # The marketplace's own description is not one of the two checked
        # surfaces, so it must name no workflow at all rather than sit
        # beside them as a third, unchecked listing.
        self.assertEqual(
            plugin_bundle_gate.workflow_identifiers(
                load_json(MARKETPLACE_MANIFEST)["description"], COMMAND_SIGIL
            ),
            set(),
        )

    def test_the_parity_check_detects_a_planted_omission_and_a_planted_extra(self):
        shipped = self.shipped()
        for surface, text in self.enumerating_surfaces().items():
            with self.subTest(surface=surface):
                omitted = text.replace("/process-report", "")
                self.assertNotEqual(omitted, text, "the planted omission changed nothing")
                failures = plugin_bundle_gate.parity_failures(
                    surface,
                    plugin_bundle_gate.workflow_identifiers(omitted, COMMAND_SIGIL),
                    shipped,
                )
                self.assertEqual(len(failures), 1, failures)
                self.assertIn("omits shipped workflow(s): process-report", failures[0])

                spurious = f"{text} It also ships /retired-command."
                failures = plugin_bundle_gate.parity_failures(
                    surface,
                    plugin_bundle_gate.workflow_identifiers(spurious, COMMAND_SIGIL),
                    shipped,
                )
                self.assertEqual(len(failures), 1, failures)
                self.assertIn(
                    "names workflow(s) the bundle does not ship: retired-command",
                    failures[0],
                )

                both = f"{omitted} It also ships /retired-command."
                self.assertEqual(
                    len(
                        plugin_bundle_gate.parity_failures(
                            surface,
                            plugin_bundle_gate.workflow_identifiers(both, COMMAND_SIGIL),
                            shipped,
                        )
                    ),
                    2,
                )

    def test_identifier_extraction_is_boundary_safe(self):
        # Overlapping names are the whole risk here: a substring scan would
        # read /issue out of /issue-review and /pr-review out of
        # /pr-rereview, making an omission look like a mention.
        self.assertEqual(
            plugin_bundle_gate.workflow_identifiers("/issue-review", COMMAND_SIGIL),
            {"issue-review"},
        )
        self.assertEqual(
            plugin_bundle_gate.workflow_identifiers("/pr-rereview", COMMAND_SIGIL),
            {"pr-rereview"},
        )
        self.assertEqual(
            plugin_bundle_gate.workflow_identifiers("/issue, /issue-review.", COMMAND_SIGIL),
            {"issue", "issue-review"},
        )
        # A URL or relative path segment is not a workflow mention.
        self.assertEqual(
            plugin_bundle_gate.workflow_identifiers(
                "https://github.com/coghex/kanban", COMMAND_SIGIL
            ),
            set(),
        )
        self.assertEqual(
            plugin_bundle_gate.workflow_identifiers("./plugins/kanban", COMMAND_SIGIL),
            set(),
        )


class SelfReviewPreconditionDocumentTests(unittest.TestCase):
    """Issue #303: `--self-review` hands the review to the calling session, so
    it is correct only where that session is the opposite brand Kanban spawned.
    These documents used to assert that premise unconditionally, which made a
    solver session running the review workflow on its own pull request read as
    the intended case. They must now declare this bundle's own brand and route
    a refusal back to the nested spawn."""

    def _doc(self, name: str) -> str:
        return (COMMANDS_ROOT / f"{name}.md").read_text(encoding="utf-8")

    def test_every_self_review_invocation_declares_this_bundles_brand(self):
        for name in ("pr-review", "pr-rereview"):
            text = self._doc(name)
            for block in re.findall(r"```bash\n(.*?)```", text, re.DOTALL):
                if "--self-review" not in block:
                    continue
                self.assertIn(
                    "--self-review-as claude",
                    block,
                    f"{name}: a --self-review invocation must declare this session's brand",
                )

    def test_both_documents_route_a_refusal_back_to_the_nested_spawn(self):
        for name in ("pr-review", "pr-rereview"):
            text = self._doc(name)
            self.assertIn("self_review_refused", text, f"{name} must handle the refusal status")
            self.assertIn(
                "own origin brand",
                text,
                f"{name} must say a refusal means this session is the PR's own brand",
            )

    def test_neither_document_asserts_the_opposite_brand_premise_unconditionally(self):
        stale = "Kanban already spawned this session as the canonical opposite-brand reviewer"
        for name in ("pr-review", "pr-rereview"):
            self.assertNotIn(
                stale,
                self._doc(name),
                f"{name} must state the opposite-brand premise as a checked precondition",
            )


class SolveStopConditionScopeTests(unittest.TestCase):
    """Issue #303: solve's stop condition ended the *run* rather than the
    workflow, so a caller that delegated to it (an auto-solve loop owing a
    review) stopped at PR creation. The prohibition it carries is the reason
    that caller still has work to do, so scoping the handoff must not weaken
    it."""

    def test_the_review_prohibition_stays_absolute(self):
        text = (COMMANDS_ROOT / "solve.md").read_text(encoding="utf-8")
        self.assertIn("Do not review, label, merge, or finalize the PR.", text)
        self.assertIn("absolute", text)

    def test_the_terminal_line_is_scoped_to_the_workflow(self):
        text = (COMMANDS_ROOT / "solve.md").read_text(encoding="utf-8")
        self.assertIn("ends *this workflow*", text)
        self.assertIn("delegated", text)
        # The unscoped spelling is what a delegating caller misread.
        self.assertNotIn("End with exactly:", text)


if __name__ == "__main__":
    unittest.main()
