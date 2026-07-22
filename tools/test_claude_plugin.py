"""Structural and contract coverage for the tracked Claude plugin.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Guards the packaging promise of issue #77: a clean Claude Code installation
can add claude-plugin/ as a marketplace and discover exactly the four
workflows Kanban invokes by name (/solve, /pr-review, /pr-rereview,
/pr-revise), none of which may set its own model/effort/permission-mode/
working-directory configuration, depend on an untracked personal path, or
drift from the invocation strings src/Kanban/Solve.hs and
src/Kanban/PullRequestFlow.hs actually spawn. The bundled coordinator is a
tracked copy of the Codex plugin's coordinator (issue #76), tested here
standalone so the Claude bundle's own coverage never requires the Codex
plugin's assets to exist.
"""

from __future__ import annotations

import importlib.util
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parent.parent
CLAUDE_PLUGIN_ROOT = REPO_ROOT / "claude-plugin"
MARKETPLACE_MANIFEST = CLAUDE_PLUGIN_ROOT / ".claude-plugin" / "marketplace.json"
PLUGIN_ROOT = CLAUDE_PLUGIN_ROOT / "plugins" / "kanban"
PLUGIN_MANIFEST = PLUGIN_ROOT / ".claude-plugin" / "plugin.json"
COMMANDS_ROOT = PLUGIN_ROOT / "commands"
REVIEW_COORDINATOR = PLUGIN_ROOT / "scripts" / "review_pr.py"

SOLVE_HS = REPO_ROOT / "src" / "Kanban" / "Solve.hs"
PR_FLOW_HS = REPO_ROOT / "src" / "Kanban" / "PullRequestFlow.hs"
UI_HS = REPO_ROOT / "src" / "Kanban" / "UI.hs"
REVIEW_HS = REPO_ROOT / "src" / "Kanban" / "Review.hs"

EXPECTED_COMMAND_NAMES = {"solve", "pr-review", "pr-rereview", "pr-revise"}

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


def iter_tracked_plugin_files():
    for path in CLAUDE_PLUGIN_ROOT.rglob("*"):
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
    def test_commands_directory_contains_exactly_the_four_packaged_workflows(self):
        found = {path.stem for path in COMMANDS_ROOT.glob("*.md")}
        self.assertEqual(found, EXPECTED_COMMAND_NAMES)

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
    """Pins the packaged command names to the exact `/`-prefixed tokens
    Kanban's Haskell invocation code spawns for the Claude brand, so a
    rename on either side fails this test instead of failing silently at
    runtime."""

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
            {"pr-review", "pr-rereview", "pr-revise"},
            "src/Kanban/PullRequestFlow.hs commandName tokens changed",
        )

        ui_source = UI_HS.read_text(encoding="utf-8")
        ui_tokens = set(re.findall(r'commandName "([\w-]+)"', ui_source))
        self.assertLessEqual(ui_tokens, pr_flow_tokens, "src/Kanban/UI.hs invokes a command PullRequestFlow.hs does not")

        all_tokens = solve_tokens | pr_flow_tokens
        self.assertEqual(all_tokens, EXPECTED_COMMAND_NAMES)


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
        solve_source = (COMMANDS_ROOT / "solve.md").read_text(encoding="utf-8")
        self.assertIn("KANBAN_ISSUE_REVIEW_INSTALL_DIR", solve_source)
        self.assertIn("Library/Application Support/kanban/issue-review/approve_issues.py", solve_source)
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


class NestedReviewerModelPinningTests(unittest.TestCase):
    """Round-2 review finding: unlike the self-reviewed known-origin case
    (where Kanban's own top-level spawn pins the model outside this
    coordinator's visibility), invoke_codex/invoke_claude fully construct
    the nested-reviewer subprocess call for /pr-revise's cross-brand
    handoff and the dual-review fallback, so they can and must pin and
    verify the canonical reviewer model/effort rather than deferring to an
    arbitrary local default. Pinned against the exact values
    src/Kanban/PullRequestFlow.hs's codexModel/claudeModel/codexEffort/
    claudeEffort already use for PullRequestReview/PullRequestRereview, so
    the two cannot silently drift apart. This is a deliberate, reviewed
    divergence from codex-plugin's otherwise-identical coordinator copy and
    from docs/agent-workflow-contract.md §2.2's general policy for this one
    nested-spawn path in this plugin only."""

    def test_nested_reviewer_models_match_the_haskell_canonical_review_models(self):
        pr_flow_source = PR_FLOW_HS.read_text(encoding="utf-8")
        self.assertIn('codexModel _ = "gpt-5.6-terra"', pr_flow_source)
        self.assertIn('codexEffort _ = "xhigh"', pr_flow_source)
        self.assertIn('claudeModel _ = "claude-opus-4-8"', pr_flow_source)
        self.assertIn('claudeEffort _ = "xhigh"', pr_flow_source)

        coordinator_source = REVIEW_COORDINATOR.read_text(encoding="utf-8")
        self.assertIn('CODEX_NESTED_REVIEW_MODEL = "gpt-5.6-terra"', coordinator_source)
        self.assertIn('CODEX_NESTED_REVIEW_EFFORT = "xhigh"', coordinator_source)
        self.assertIn('CLAUDE_NESTED_REVIEW_MODEL = "claude-opus-4-8"', coordinator_source)
        self.assertIn('CLAUDE_NESTED_REVIEW_EFFORT = "xhigh"', coordinator_source)

    def test_invoke_codex_and_invoke_claude_pass_the_pinned_model_flags(self):
        coordinator_source = REVIEW_COORDINATOR.read_text(encoding="utf-8")
        codex_match = re.search(r"def invoke_codex\(.*?(?=\ndef |\Z)", coordinator_source, re.DOTALL)
        self.assertIsNotNone(codex_match)
        self.assertIn('"--model",\n                CODEX_NESTED_REVIEW_MODEL', codex_match.group(0))
        self.assertIn("model_reasoning_effort", codex_match.group(0))

        claude_match = re.search(r"def invoke_claude\(.*?(?=\ndef |\Z)", coordinator_source, re.DOTALL)
        self.assertIsNotNone(claude_match)
        self.assertIn('"--model",\n            CLAUDE_NESTED_REVIEW_MODEL', claude_match.group(0))
        self.assertIn('"--effort",\n            CLAUDE_NESTED_REVIEW_EFFORT', claude_match.group(0))

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

    def test_the_referenced_coordinator_path_exists_relative_to_the_plugin_root(self):
        # ${CLAUDE_PLUGIN_ROOT} resolves to PLUGIN_ROOT at runtime; confirm
        # the literal relative path every command references actually
        # exists there, so a rename of scripts/review_pr.py would fail
        # this test rather than only failing at runtime.
        resolved = PLUGIN_ROOT / "scripts" / "review_pr.py"
        self.assertEqual(resolved, REVIEW_COORDINATOR)
        self.assertTrue(resolved.is_file())


if __name__ == "__main__":
    unittest.main()
