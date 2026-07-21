"""Structural and contract coverage for the tracked Codex plugin.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Guards the packaging promise of issue #76: a clean Codex installation can
add codex-plugin/ as a project-scoped marketplace and discover exactly the
four workflows Kanban invokes by name ($solve, $pr-review, $pr-rereview,
$pr-revise), none of which may set its own model/effort/sandbox/approval/
working-directory configuration, depend on an untracked personal path, or
drift from the invocation strings src/Kanban/Solve.hs and
src/Kanban/PullRequestFlow.hs actually spawn.
"""

from __future__ import annotations

import importlib.util
import json
import py_compile
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parent.parent
CODEX_PLUGIN_ROOT = REPO_ROOT / "codex-plugin"
MARKETPLACE_MANIFEST = CODEX_PLUGIN_ROOT / ".agents" / "plugins" / "marketplace.json"
PLUGIN_ROOT = CODEX_PLUGIN_ROOT / "plugins" / "kanban"
PLUGIN_MANIFEST = PLUGIN_ROOT / ".codex-plugin" / "plugin.json"
SKILLS_ROOT = PLUGIN_ROOT / "skills"
REVIEW_COORDINATOR = SKILLS_ROOT / "pr-review" / "scripts" / "review_pr.py"

SOLVE_HS = REPO_ROOT / "src" / "Kanban" / "Solve.hs"
PR_FLOW_HS = REPO_ROOT / "src" / "Kanban" / "PullRequestFlow.hs"
UI_HS = REPO_ROOT / "src" / "Kanban" / "UI.hs"
REVIEW_HS = REPO_ROOT / "src" / "Kanban" / "Review.hs"

EXPECTED_SKILL_NAMES = {"solve", "pr-review", "pr-rereview", "pr-revise"}

# Keys that would let a packaged manifest silently override the model,
# reasoning effort, sandbox/approval policy, or working directory Kanban's
# own CLI spawn already pins (docs/agent-workflow-contract.md §2.1-§2.2).
FORBIDDEN_MANIFEST_KEYS = {
    "model",
    "models",
    "reasoning_effort",
    "reasoningEffort",
    "sandbox",
    "approval",
    "approvalPolicy",
    "approval_policy",
    "cwd",
    "workingDirectory",
    "working_directory",
}

# Personal, non-namespaced path fragments that must never appear in a
# tracked packaged asset. Kanban's own home-relative convention (e.g.
# `Library/Application Support/kanban/...`) is namespaced and allowed; see
# docs/agent-workflow-contract.md §5.
FORBIDDEN_PATH_FRAGMENTS = (
    "/Users/",
    "$HOME/work/",
    "~/work/approve-issues",
    "/.codex/skills/",
)

SKILL_FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)
FRONTMATTER_FIELD_RE = re.compile(r"^name:\s*(\S+)\s*$", re.MULTILINE)


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def load_review_pr_module():
    """Import review_pr.py by file path (it lives under codex-plugin/, not
    tools/, so it is never on sys.path via `-s tools` discovery)."""
    spec = importlib.util.spec_from_file_location("kanban_codex_plugin_review_pr", REVIEW_COORDINATOR)
    module = importlib.util.module_from_spec(spec)
    # dataclass field resolution looks the module up in sys.modules by name
    # while exec_module is still running, so it must be registered first.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def iter_tracked_plugin_files():
    for path in CODEX_PLUGIN_ROOT.rglob("*"):
        if path.is_file():
            yield path


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


class MarketplaceAndPluginManifestTests(unittest.TestCase):
    def test_marketplace_manifest_points_at_the_tracked_plugin_directory(self):
        data = load_json(MARKETPLACE_MANIFEST)
        plugins = data.get("plugins")
        self.assertIsInstance(plugins, list)
        kanban_entries = [item for item in plugins if item.get("name") == "kanban"]
        self.assertEqual(len(kanban_entries), 1, "marketplace.json must declare exactly one kanban plugin entry")
        source = kanban_entries[0]["source"]
        self.assertEqual(source["source"], "local")
        marketplace_root = MARKETPLACE_MANIFEST.parent.parent.parent
        self.assertEqual(marketplace_root, CODEX_PLUGIN_ROOT)
        resolved = (marketplace_root / source["path"]).resolve()
        self.assertEqual(resolved, PLUGIN_ROOT)

    def test_marketplace_manifest_declares_the_documented_plugin_entry_fields(self):
        data = load_json(MARKETPLACE_MANIFEST)
        self.assertIn("interface", data)
        self.assertIn("displayName", data["interface"])
        kanban_entry = next(item for item in data["plugins"] if item.get("name") == "kanban")
        self.assertIn("policy", kanban_entry)
        self.assertIn("installation", kanban_entry["policy"])
        self.assertIn("authentication", kanban_entry["policy"])
        self.assertIn("category", kanban_entry)

    def test_plugin_manifest_is_valid_and_declares_no_forbidden_configuration(self):
        data = load_json(PLUGIN_MANIFEST)
        self.assertEqual(data.get("name"), "kanban")
        self.assertEqual(data.get("skills"), "./skills/")
        self.assertNotIn("mcpServers", data, "the packaged plugin must not declare an MCP server dependency")
        hits = find_forbidden_keys(data)
        self.assertEqual(hits, [], f"plugin.json must not set model/effort/sandbox/approval/cwd config: {hits}")

    def test_marketplace_manifest_declares_no_forbidden_configuration(self):
        data = load_json(MARKETPLACE_MANIFEST)
        hits = find_forbidden_keys(data)
        self.assertEqual(hits, [], f"marketplace.json must not set model/effort/sandbox/approval/cwd config: {hits}")


NESTED_REVIEWER_INVOCATION_RE = re.compile(
    r"def invoke_codex\(.*?(?=\ndef |\Z)|def invoke_claude\(.*?(?=\ndef |\Z)",
    re.DOTALL,
)

# Literal CLI flags that would pin model, reasoning effort, sandbox, or
# approval/permission policy for the reviewer this coordinator spawns —
# forbidden even inside the coordinator's own subprocess argument lists,
# not just in the plugin's JSON manifests. Kanban's own invoking code (and,
# for the nested reviewer identity, docs/design.md's pinned policy table)
# owns these; the coordinator must defer to that installation's own
# configuration rather than setting them itself.
FORBIDDEN_INVOCATION_FLAGS = (
    '"-m"',
    '"--model"',
    '"-c"',
    "model_reasoning_effort",
    '"--effort"',
    '"-s"',
    '"--sandbox"',
    "--dangerously-bypass-approvals-and-sandbox",
    '"--permission-mode"',
    '"--ignore-user-config"',
)


class PackagedCodeInvocationTests(unittest.TestCase):
    """Structural coverage over the coordinator's own code, not just its
    JSON manifests: the nested reviewer subprocess calls in invoke_codex/
    invoke_claude must not pin model/effort/sandbox/approval either."""

    def test_nested_reviewer_invocations_set_no_forbidden_cli_flags(self):
        source = REVIEW_COORDINATOR.read_text(encoding="utf-8")
        offenders = []
        for match in NESTED_REVIEWER_INVOCATION_RE.finditer(source):
            # Strip full-line and trailing comments so an explanatory
            # comment naming a flag that was deliberately removed (e.g.
            # "No -m/--model: ...") cannot itself trip this check; only the
            # actual argument-list code is scanned.
            code_only = "\n".join(
                line for line in match.group(0).splitlines() if not line.strip().startswith("#")
            )
            for flag in FORBIDDEN_INVOCATION_FLAGS:
                if flag in code_only:
                    offenders.append(f"{flag!r} appears in {match.group(0).splitlines()[0]}")
        self.assertEqual(offenders, [], "\n".join(offenders))

    def test_the_forbidden_flag_scan_actually_detects_a_planted_violation(self):
        # Guards against the regex/substring scan above silently matching
        # nothing due to a function-boundary or naming drift.
        planted = 'def invoke_codex(reviewer, prompt, cwd):\n    run(["codex", "exec", "-m", reviewer.model])\n'
        match = NESTED_REVIEWER_INVOCATION_RE.search(planted)
        self.assertIsNotNone(match)
        self.assertIn('"-m"', match.group(0))


class SkillDiscoveryTests(unittest.TestCase):
    def test_skills_directory_contains_exactly_the_four_packaged_workflows(self):
        found = {path.name for path in SKILLS_ROOT.iterdir() if path.is_dir()}
        self.assertEqual(found, EXPECTED_SKILL_NAMES)

    def test_each_skill_has_a_skill_md_whose_frontmatter_name_matches_its_directory(self):
        for name in EXPECTED_SKILL_NAMES:
            skill_md = SKILLS_ROOT / name / "SKILL.md"
            self.assertTrue(skill_md.is_file(), f"missing {skill_md}")
            text = skill_md.read_text(encoding="utf-8")
            match = SKILL_FRONTMATTER_RE.match(text)
            self.assertIsNotNone(match, f"{skill_md} must open with a --- frontmatter block")
            field = FRONTMATTER_FIELD_RE.search(match.group(1))
            self.assertIsNotNone(field, f"{skill_md} frontmatter must declare name:")
            self.assertEqual(field.group(1), name)


class WorkflowNameParityTests(unittest.TestCase):
    """Pins the packaged skill names to the exact tokens Kanban's Haskell
    invocation code spawns, so a rename on either side fails this test
    instead of failing silently at runtime."""

    def test_codex_workflow_tokens_match_packaged_skill_names(self):
        solve_source = SOLVE_HS.read_text(encoding="utf-8")
        solve_tokens = set(re.findall(r'workflowName \w+ CodexSolver = "\$([\w-]+)"', solve_source))
        self.assertEqual(solve_tokens, {"solve"}, "src/Kanban/Solve.hs workflowName Codex tokens changed")

        pr_flow_source = PR_FLOW_HS.read_text(encoding="utf-8")
        pr_flow_tokens = set(re.findall(r'commandName "([\w-]+)"', pr_flow_source))
        self.assertEqual(
            pr_flow_tokens,
            {"pr-review", "pr-rereview", "pr-revise"},
            "src/Kanban/PullRequestFlow.hs commandName tokens changed",
        )

        ui_source = UI_HS.read_text(encoding="utf-8")
        ui_tokens = set(re.findall(r'commandName "([\w-]+)"', ui_source))
        self.assertLessEqual(ui_tokens, pr_flow_tokens, "src/Kanban/UI.hs invokes a command PullRequestFlow.hs does not")

        all_tokens = solve_tokens | pr_flow_tokens
        self.assertEqual(all_tokens, EXPECTED_SKILL_NAMES)


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

    def test_no_agents_yaml_or_other_untracked_personal_skill_convention(self):
        stray = list(SKILLS_ROOT.rglob("agents"))
        self.assertEqual(stray, [], f"packaged skills must not carry personal agents/*.yaml interface files: {stray}")


class IssueReviewBackendResolutionTests(unittest.TestCase):
    """The coordinator's approver_path() must resolve the canonical
    issue-review backend the same way Kanban.Review.canonicalIssueReviewerPath
    does, never a personal ~/work/approve-issues.py default."""

    def test_review_pr_matches_the_haskell_canonical_resolution(self):
        review_hs_source = REVIEW_HS.read_text(encoding="utf-8")
        self.assertIn('lookupEnv "KANBAN_ISSUE_REVIEW_INSTALL_DIR"', review_hs_source)
        self.assertIn("Library/Application Support/kanban/issue-review/approve_issues.py", review_hs_source)

        coordinator_source = REVIEW_COORDINATOR.read_text(encoding="utf-8")
        self.assertIn('os.environ.get("KANBAN_ISSUE_REVIEW_INSTALL_DIR")', coordinator_source)
        for segment in ('"Library"', '"Application Support"', '"kanban"', '"issue-review"'):
            self.assertIn(segment, coordinator_source, f"approver_path() must build the canonical {segment} segment")
        self.assertIn("approve_issues.py", coordinator_source)
        self.assertNotIn('"work" / "approve-issues.py"', coordinator_source)
        self.assertIn("python3 tools/install_issue_review.py", coordinator_source)

    def test_solve_gate_check_matches_the_haskell_canonical_resolution(self):
        # solve can run against any repository Kanban is pointed at, so its
        # gate check must resolve the Kanban-managed install location
        # rather than assume the repository under review tracks
        # tools/approve_issues.py itself.
        solve_source = (SKILLS_ROOT / "solve" / "SKILL.md").read_text(encoding="utf-8")
        self.assertIn("KANBAN_ISSUE_REVIEW_INSTALL_DIR", solve_source)
        self.assertIn("Library/Application Support/kanban/issue-review/approve_issues.py", solve_source)
        self.assertIn("python3 tools/install_issue_review.py", solve_source)


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

    def test_set_and_clear_verdict_label_use_the_resolved_labels(self):
        module = load_review_pr_module()
        with mock.patch.object(module, "run") as run_mock:
            module.set_verdict_label(Path("/fake-repo"), 89, "APPROVE", "lgtm", "needs-work")
        run_mock.assert_called_once_with(
            ["gh", "pr", "edit", "89", "--add-label", "lgtm", "--remove-label", "needs-work"],
            cwd=Path("/fake-repo"),
        )
        with mock.patch.object(module, "run") as run_mock:
            module.clear_verdict_labels(Path("/fake-repo"), 89, "lgtm", "needs-work")
        run_mock.assert_called_once_with(
            ["gh", "pr", "edit", "89", "--remove-label", "lgtm", "--remove-label", "needs-work"],
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
            module.check_issue(Path("/fake-repo"), 34, "/tmp/custom-config.toml")
        called_args = run_mock.call_args.args[0]
        self.assertIn("--config", called_args)
        self.assertEqual(called_args[called_args.index("--config") + 1], "/tmp/custom-config.toml")

        with mock.patch.object(
            module, "approver_path", return_value=Path("/fake-approve-issues.py")
        ), mock.patch.object(module, "run", return_value=fake_result) as run_mock:
            module.check_issue(Path("/fake-repo"), 34)
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


class SolveGateEscalationTests(unittest.TestCase):
    """solve must escalate with the exact terminal line Kanban's own
    invocation prompt uses (src/Kanban/Solve.hs), not a paraphrase, so
    Kanban's KANBAN_NEEDS_INPUT handling recognizes it."""

    ESCALATION_TEXT = "KANBAN_NEEDS_INPUT: This issue needs canonical review; press r on the issue, then retry."

    def test_escalation_text_matches_solve_hs_verbatim(self):
        solve_hs_source = SOLVE_HS.read_text(encoding="utf-8")
        self.assertIn(self.ESCALATION_TEXT, solve_hs_source)

        solve_skill_source = (SKILLS_ROOT / "solve" / "SKILL.md").read_text(encoding="utf-8")
        self.assertIn(self.ESCALATION_TEXT, solve_skill_source)


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

    def test_review_pr_compiles(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfile = Path(tmp) / "review_pr.pyc"
            py_compile.compile(str(REVIEW_COORDINATOR), cfile=str(cfile), doraise=True)


class PostCommentPublicationRaceTests(unittest.TestCase):
    """Behavioral regression coverage for the round-1 fix: if the PR head
    or issue gate goes stale in the window between posting the review
    comment and labeling it, workflow() must clear any pre-existing
    reviewed:* label rather than leaving it in place next to a
    now-unlabeled comment. Drives the real workflow() function with its
    GitHub/model-invoking dependencies mocked, rather than only asserting
    the source text shape."""

    def _base_pr(self):
        return {
            "number": 89,
            "url": "https://github.com/coghex/kanban/pull/89",
            "state": "OPEN",
            "headRefOid": "a" * 40,
            "body": "<!-- pr-origin:claude -->",
            "isCrossRepository": False,
            "labels": [],
            "closingIssuesReferences": [],
        }

    def test_post_comment_gate_or_head_race_clears_stale_verdict_labels(self):
        module = load_review_pr_module()
        pr = self._base_pr()
        gate = {"approved": True, "allow_no_issue": False, "issues": [], "invalid_links": [], "checks": [], "key": "k1"}
        review_result = {
            "reviewer": "codex",
            "display_name": "Codex",
            "verdict": "APPROVE",
            "summary": "looks good",
            "blocking_concerns": [],
        }

        require_state_calls = {"count": 0}

        def require_state_side_effect(*args, **kwargs):
            require_state_calls["count"] += 1
            if require_state_calls["count"] == 2:
                # Simulate the exact race this test exists to cover: the
                # head or gate went stale in the window right after
                # post_comment() landed, before labeling.
                raise module.WorkflowError("PR head changed; no current-head verdict may be labeled")
            return gate

        with mock.patch.object(module, "repository_name", return_value="coghex/kanban"), mock.patch.object(
            module, "pr_view", return_value=pr
        ), mock.patch.object(module, "gate_status", return_value=gate), mock.patch.object(
            module, "pr_origin", return_value="claude"
        ), mock.patch.object(module, "collect_context", return_value={}), mock.patch.object(
            module, "extract_source", return_value=None
        ), mock.patch.object(
            module, "run_reviews", return_value=[review_result]
        ), mock.patch.object(
            module, "render_review", return_value=("APPROVE", "APPROVE\n\nlooks good\n")
        ), mock.patch.object(
            module, "require_current_review_state", side_effect=require_state_side_effect
        ), mock.patch.object(
            module, "post_comment", return_value="https://github.com/coghex/kanban/pull/89#issuecomment-1"
        ) as post_comment_mock, mock.patch.object(
            module, "set_verdict_label"
        ) as set_verdict_label_mock, mock.patch.object(
            module, "verify_publication"
        ) as verify_publication_mock, mock.patch.object(
            module, "clear_verdict_labels"
        ) as clear_verdict_labels_mock:
            with self.assertRaises(module.WorkflowError) as excinfo:
                module.workflow(Path("/fake-repo"), 89, rereview=False, dry_run=False, allow_no_issue=False)

        post_comment_mock.assert_called_once()
        clear_verdict_labels_mock.assert_called_once_with(
            Path("/fake-repo"), 89, "reviewed:approve", "reviewed:changes"
        )
        set_verdict_label_mock.assert_not_called()
        verify_publication_mock.assert_not_called()
        self.assertIn("both verdict labels were cleared", str(excinfo.exception))


class ReviewerSourceIsolationTests(unittest.TestCase):
    """Round-5 finding: invoke_codex/invoke_claude no longer restrict the
    nested reviewer's sandbox/tool access (round 3 removed those flags), so
    a dual review sharing one extracted-source directory would let either
    reviewer's process affect what the other sees mid-review. Each reviewer
    must get its own extraction, and that extraction must actually be
    immutable on disk, not just described as read-only in the prompt."""

    def test_make_tree_read_only_strips_write_permission_from_files_and_dirs(self):
        module = load_review_pr_module()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "extracted"
            nested = root / "sub"
            nested.mkdir(parents=True)
            target_file = nested / "file.txt"
            target_file.write_text("hello")

            module.make_tree_read_only(root)

            self.assertEqual(root.stat().st_mode & 0o222, 0)
            self.assertEqual(nested.stat().st_mode & 0o222, 0)
            self.assertEqual(target_file.stat().st_mode & 0o222, 0)
            with self.assertRaises(PermissionError):
                target_file.write_text("overwritten")

    def test_make_tree_writable_reverses_make_tree_read_only_for_cleanup(self):
        module = load_review_pr_module()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "extracted"
            nested = root / "sub"
            nested.mkdir(parents=True)
            target_file = nested / "file.txt"
            target_file.write_text("hello")

            module.make_tree_read_only(root)
            module.make_tree_writable(root)

            self.assertNotEqual(root.stat().st_mode & 0o200, 0)
            self.assertNotEqual(nested.stat().st_mode & 0o200, 0)
            self.assertNotEqual(target_file.stat().st_mode & 0o200, 0)
            target_file.write_text("overwritten")  # must not raise
            import shutil

            shutil.rmtree(root)  # must not raise either

    def test_run_reviews_serializes_reviewers_one_source_directory_at_a_time(self):
        # Cross-tree tampering regression test: even independently-rooted
        # per-reviewer directories are a tampering surface if both exist on
        # disk at once (an unrestricted reviewer can enumerate/glob for a
        # peer's prefix). Assert the actual invariant: run_reviews never
        # has more than one reviewer's source directory on disk at a time.
        module = load_review_pr_module()
        created_dirs = []
        invocation_log = []

        def fake_extract():
            created = Path(tempfile.mkdtemp(prefix="fake-review-source-"))
            created_dirs.append(created)
            return created

        def fake_invoke_reviewer(reviewer, prompt, cwd):
            still_on_disk = [d for d in created_dirs if d.exists()]
            invocation_log.append((reviewer.key, cwd, still_on_disk))
            return {
                "reviewer": reviewer.key,
                "display_name": reviewer.display_name,
                "verdict": "APPROVE",
                "summary": "ok",
                "blocking_concerns": [],
            }

        with mock.patch.object(module, "invoke_reviewer", side_effect=fake_invoke_reviewer):
            module.run_reviews(
                [module.CODEX_REVIEWER, module.CLAUDE_REVIEWER], {}, fake_extract, rereview=False
            )

        self.assertEqual(len(invocation_log), 2)
        codex_key, codex_cwd, codex_on_disk = invocation_log[0]
        claude_key, claude_cwd, claude_on_disk = invocation_log[1]
        self.assertEqual(codex_key, "codex")
        self.assertEqual(claude_key, "claude")
        self.assertNotEqual(codex_cwd, claude_cwd)
        self.assertEqual(codex_on_disk, [codex_cwd], "only codex's own source directory may exist while it runs")
        self.assertEqual(claude_on_disk, [claude_cwd], "codex's directory must already be gone before claude's is created")
        self.assertEqual(len(created_dirs), 2)
        for created in created_dirs:
            self.assertFalse(created.exists(), "run_reviews must tear each source down before returning")

    def test_extract_source_result_is_read_only(self):
        module = load_review_pr_module()
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=REPO_ROOT, capture_output=True, text=True, check=True
        ).stdout.strip()
        with tempfile.TemporaryDirectory() as temp:
            destination = Path(temp) / "extracted"
            destination.mkdir()
            module.extract_source(REPO_ROOT, 0, head, destination)
            readme = destination / "README.md"
            self.assertTrue(readme.is_file())
            with self.assertRaises(PermissionError):
                readme.write_text("overwritten")
            module.make_tree_writable(destination)  # so the TemporaryDirectory can clean up

    def test_workflow_serializes_dual_reviewers_with_no_predictable_naming(self):
        # End-to-end regression for the round-6/round-7 findings: dual
        # review must never have two reviewers' source trees on disk at
        # once, and directory names must not encode the reviewer brand.
        # Uses the real extract_source/tempfile.mkdtemp/run_reviews path
        # against this actual repo; only GitHub calls and the reviewer
        # subprocess spawn (invoke_reviewer) are mocked.
        module = load_review_pr_module()
        pr = {
            "number": 89,
            "url": "https://github.com/coghex/kanban/pull/89",
            "state": "OPEN",
            "headRefOid": "a" * 40,
            "body": "no origin marker here",  # forces the dual/unknown route
            "isCrossRepository": False,
            "labels": [],
            "closingIssuesReferences": [],
        }
        gate = {"approved": True, "allow_no_issue": False, "issues": [], "invalid_links": [], "checks": [], "key": "k1"}
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=REPO_ROOT, capture_output=True, text=True, check=True
        ).stdout.strip()
        pr["headRefOid"] = head

        invocation_log = []
        all_sources_seen = []

        def fake_invoke_reviewer(reviewer, prompt, cwd):
            # Captured at the moment THIS reviewer runs, not after the fact
            # (every directory is torn down by the time workflow() returns,
            # which would make a post-hoc check vacuously pass regardless
            # of whether serialization actually happened).
            other_still_on_disk = [other for other in all_sources_seen if other != cwd and other.exists()]
            invocation_log.append((reviewer.key, cwd, cwd.exists(), other_still_on_disk))
            all_sources_seen.append(cwd)
            return {"reviewer": reviewer.key, "display_name": reviewer.display_name, "verdict": "APPROVE", "summary": "ok", "blocking_concerns": []}

        with mock.patch.object(module, "repository_name", return_value="coghex/kanban"), mock.patch.object(
            module, "pr_view", return_value=pr
        ), mock.patch.object(module, "gate_status", return_value=gate), mock.patch.object(
            module, "collect_context", return_value={}
        ), mock.patch.object(
            module, "invoke_reviewer", side_effect=fake_invoke_reviewer
        ), mock.patch.object(
            module, "render_review", return_value=("APPROVE", "APPROVE\n\nok\n")
        ), mock.patch.object(
            module, "require_current_review_state", return_value=gate
        ), mock.patch.object(
            module, "post_comment", return_value="https://github.com/coghex/kanban/pull/89#issuecomment-1"
        ), mock.patch.object(module, "set_verdict_label"), mock.patch.object(
            module, "verify_publication", return_value={"comment_url": "url", "labels": ["reviewed:approve"]}
        ):
            module.workflow(REPO_ROOT, 89, rereview=False, dry_run=False, allow_no_issue=False)

        self.assertEqual(len(invocation_log), 2)
        for key, cwd, existed_while_running, other_still_on_disk in invocation_log:
            self.assertTrue(existed_while_running, f"{key}'s own source must exist while it is running")
            self.assertNotIn(cwd.name, {"codex", "claude"}, "source directory names must not encode the reviewer brand")
            self.assertEqual(other_still_on_disk, [], f"no other reviewer's source may exist while {key} is running")
        codex_cwd = next(cwd for key, cwd, _, _ in invocation_log if key == "codex")
        claude_cwd = next(cwd for key, cwd, _, _ in invocation_log if key == "claude")
        self.assertNotEqual(codex_cwd, claude_cwd)
        # workflow() must have torn both down on the way out.
        self.assertFalse(codex_cwd.exists())
        self.assertFalse(claude_cwd.exists())


class SelfReviewProtocolTests(unittest.TestCase):
    """Round-8 finding: for known-origin $pr-review/$pr-rereview, Kanban's
    own top-level invocation already spawned the correct canonical
    reviewer identity before this script ever ran, so review_pr.py must
    not spawn a further, unpinned nested reviewer for that case — only
    pr-revise's genuine cross-brand handoff needs that. workflow(...,
    self_review=True) must instead return review context for the calling
    (already-correct-identity) agent to use directly, then hand its
    verdict to publish_verdict() rather than a spawned subprocess."""

    def _base_pr(self, body="<!-- pr-origin:claude -->"):
        return {
            "number": 89,
            "url": "https://github.com/coghex/kanban/pull/89",
            "state": "OPEN",
            "headRefOid": "a" * 40,
            "body": body,
            "isCrossRepository": False,
            "labels": [],
            "closingIssuesReferences": [],
        }

    def _gate(self, key="k1"):
        return {"approved": True, "allow_no_issue": False, "issues": [], "invalid_links": [], "checks": [], "key": key}

    def test_self_review_known_origin_returns_context_without_spawning(self):
        module = load_review_pr_module()
        pr = self._base_pr()  # claude origin -> single reviewer, codex
        gate = self._gate()

        with mock.patch.object(module, "repository_name", return_value="coghex/kanban"), mock.patch.object(
            module, "pr_view", return_value=pr
        ), mock.patch.object(module, "gate_status", return_value=gate), mock.patch.object(
            module, "collect_context", return_value={"diff": "..."}
        ), mock.patch.object(module, "run_reviews") as run_reviews_mock, mock.patch.object(
            module, "invoke_reviewer"
        ) as invoke_reviewer_mock, mock.patch.object(
            module, "extract_source"
        ) as extract_source_mock:
            code, result = module.workflow(
                Path("/fake-repo"), 89, rereview=False, dry_run=False, allow_no_issue=False, self_review=True
            )

        self.assertEqual(code, 0)
        self.assertEqual(result["status"], "awaiting_self_review")
        self.assertEqual(result["reviewer_key"], "codex")  # claude origin -> opposite is codex
        self.assertEqual(result["expected_head"], pr["headRefOid"])
        self.assertEqual(result["gate_key"], gate["key"])
        self.assertIn("REVIEW_PAYLOAD", result["instructions"])
        self.assertIn("Codex", result["instructions"])
        run_reviews_mock.assert_not_called()
        invoke_reviewer_mock.assert_not_called()
        extract_source_mock.assert_not_called()

    def test_self_review_dual_origin_still_spawns_nested_reviewers(self):
        # Unknown/external origin cannot be self-reviewed by one calling
        # session as both brands; Kanban's own invocation never routes here
        # (it always tags a known origin), so falling back to the existing
        # nested-spawn-both behavior is an acceptable, low-value edge case.
        module = load_review_pr_module()
        pr = self._base_pr(body="no origin marker")
        gate = self._gate()
        fake_source = Path("/fake/source")

        with mock.patch.object(module, "repository_name", return_value="coghex/kanban"), mock.patch.object(
            module, "pr_view", return_value=pr
        ), mock.patch.object(module, "gate_status", return_value=gate), mock.patch.object(
            module, "collect_context", return_value={}
        ), mock.patch.object(
            module, "run_reviews", return_value=[{"reviewer": "codex"}, {"reviewer": "claude"}]
        ) as run_reviews_mock, mock.patch.object(
            module, "publish_results", return_value=(0, {"status": "reviewed"})
        ) as publish_results_mock:
            code, result = module.workflow(
                Path("/fake-repo"), 89, rereview=False, dry_run=False, allow_no_issue=False, self_review=True
            )

        run_reviews_mock.assert_called_once()
        publish_results_mock.assert_called_once()
        self.assertEqual(result["status"], "reviewed")

    def test_publish_verdict_publishes_a_precomputed_result(self):
        module = load_review_pr_module()
        pr = self._base_pr()
        gate = self._gate()

        with tempfile.TemporaryDirectory() as temp:
            result_path = Path(temp) / "result.json"
            result_path.write_text(json.dumps({"verdict": "APPROVE", "summary": "looks good", "blocking_concerns": []}))

            with mock.patch.object(module, "repository_name", return_value="coghex/kanban"), mock.patch.object(
                module, "pr_view", return_value=pr
            ), mock.patch.object(module, "gate_status", return_value=gate), mock.patch.object(
                module, "publish_results", return_value=(0, {"status": "reviewed", "verdict": "APPROVE"})
            ) as publish_results_mock, mock.patch.object(
                module, "invoke_reviewer"
            ) as invoke_reviewer_mock:
                code, result = module.publish_verdict(
                    Path("/fake-repo"), 89, pr["headRefOid"], gate["key"], result_path, allow_no_issue=False
                )

        self.assertEqual(code, 0)
        self.assertEqual(result["status"], "reviewed")
        invoke_reviewer_mock.assert_not_called()
        publish_results_mock.assert_called_once()
        published_results_arg = publish_results_mock.call_args.args[6]
        self.assertEqual(published_results_arg[0]["verdict"], "APPROVE")
        self.assertEqual(published_results_arg[0]["reviewer"], "codex")

    def test_publish_verdict_rejects_a_stale_head(self):
        module = load_review_pr_module()
        pr = self._base_pr()
        with tempfile.TemporaryDirectory() as temp:
            result_path = Path(temp) / "result.json"
            result_path.write_text(json.dumps({"verdict": "APPROVE", "summary": "ok", "blocking_concerns": []}))
            with mock.patch.object(module, "repository_name", return_value="coghex/kanban"), mock.patch.object(
                module, "pr_view", return_value=pr
            ):
                with self.assertRaises(module.WorkflowError) as excinfo:
                    module.publish_verdict(Path("/fake-repo"), 89, "b" * 40, "k1", result_path, allow_no_issue=False)
        self.assertIn("rerun $pr-review/$pr-rereview", str(excinfo.exception))

    def test_publish_verdict_rejects_a_stale_gate_key(self):
        module = load_review_pr_module()
        pr = self._base_pr()
        gate = self._gate(key="different-key")
        with tempfile.TemporaryDirectory() as temp:
            result_path = Path(temp) / "result.json"
            result_path.write_text(json.dumps({"verdict": "APPROVE", "summary": "ok", "blocking_concerns": []}))
            with mock.patch.object(module, "repository_name", return_value="coghex/kanban"), mock.patch.object(
                module, "pr_view", return_value=pr
            ), mock.patch.object(module, "gate_status", return_value=gate):
                with self.assertRaises(module.WorkflowError) as excinfo:
                    module.publish_verdict(Path("/fake-repo"), 89, pr["headRefOid"], "k1", result_path, allow_no_issue=False)
        self.assertIn("rerun $pr-review/$pr-rereview", str(excinfo.exception))


COORDINATOR_LOOKUP = (
    'find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" '
    "-path '*/kanban/*/skills/pr-review/scripts/review_pr.py'"
)


class SharedCoordinatorReferenceTests(unittest.TestCase):
    """All three PR-flow skills locate the installed coordinator by
    searching under $CODEX_HOME rather than a path relative to the current
    directory: Kanban spawns these workflows with the *reviewed* repository
    as the working directory, not this plugin's own install location, so a
    cwd- or skill-relative path cannot resolve. Confirm the exact lookup
    command each SKILL.md uses actually finds the coordinator against a
    simulated install layout, not just that some string is present."""

    def test_pr_review_family_locates_the_coordinator_via_codex_home(self):
        for name in ("pr-review", "pr-rereview", "pr-revise"):
            text = (SKILLS_ROOT / name / "SKILL.md").read_text(encoding="utf-8")
            self.assertIn(COORDINATOR_LOOKUP, text, f"{name}/SKILL.md must locate the coordinator under $CODEX_HOME")

    def test_the_codex_home_lookup_command_resolves_against_a_simulated_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake_codex_home = Path(tmp) / "fake-codex-home"
            installed = fake_codex_home / "plugins" / "cache" / "kanban" / "kanban" / "1.0.0" / "skills" / "pr-review" / "scripts" / "review_pr.py"
            installed.parent.mkdir(parents=True)
            installed.write_text("# stand-in for the installed coordinator\n", encoding="utf-8")
            proc = subprocess.run(
                [
                    "find",
                    str(fake_codex_home / "plugins" / "cache"),
                    "-path",
                    "*/kanban/*/skills/pr-review/scripts/review_pr.py",
                ],
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            found = [line for line in proc.stdout.splitlines() if line]
            self.assertEqual(found, [str(installed)])


if __name__ == "__main__":
    unittest.main()
