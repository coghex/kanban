"""Completeness check for docs/agent-workflow-contract.md.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Reconciles the manifest in docs/agent-workflow-contract.md against the
solve, PR-flow, and canonical issue-review invocation surface, and against
the tracked Codex and Claude plugins' own packaged-workflow bash surfaces,
so a new external command or home-relative path cannot land undocumented.
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CONTRACT_PATH = REPO_ROOT / "docs" / "agent-workflow-contract.md"

# The solve, PR-flow, and canonical issue-review invocation surface, plus
# the shared provider/process helpers they call into. This list is
# exhaustive for src/: nothing else under src/ matches
# findExecutable/proc/readProcessWithExitCode/readCreateProcessWithExitCode/
# getHomeDirectory.
SURFACE_FILES = [
    "src/Kanban/Solve.hs",
    "src/Kanban/PullRequestFlow.hs",
    "src/Kanban/Review.hs",
    "src/Kanban/Codex.hs",
    "src/Kanban/Claude.hs",
    "src/Kanban/GitHub.hs",
    "src/Kanban/Repository.hs",
    "src/Kanban/Drainer.hs",
    "src/Kanban/Process.hs",
]

# The tracked Codex plugin's own packaged workflows (issue #76): a separate,
# non-Haskell invocation surface reconciled against the same manifest. The
# bundled coordinator (.py) is scanned with a different extractor than the
# SKILL.md files (bash fences) since it invokes commands as Python list
# literals, not shell text.
PLUGIN_SURFACE_FILES = [
    "codex-plugin/plugins/kanban/skills/solve/SKILL.md",
    "codex-plugin/plugins/kanban/skills/pr-review/SKILL.md",
    "codex-plugin/plugins/kanban/skills/pr-rereview/SKILL.md",
    "codex-plugin/plugins/kanban/skills/pr-revise/SKILL.md",
    "codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py",
]

# The tracked Claude plugin's own packaged workflows (issue #77): the same
# kind of separate, non-Haskell invocation surface as PLUGIN_SURFACE_FILES
# above, reconciled against the same manifest. Claude Code plugin commands
# resolve their own bundled files via ${CLAUDE_PLUGIN_ROOT}, so this plugin
# needs no find/head-based coordinator search the way the Codex plugin does.
CLAUDE_PLUGIN_SURFACE_FILES = [
    "claude-plugin/plugins/kanban/commands/solve.md",
    "claude-plugin/plugins/kanban/commands/pr-review.md",
    "claude-plugin/plugins/kanban/commands/pr-rereview.md",
    "claude-plugin/plugins/kanban/commands/pr-revise.md",
    "claude-plugin/plugins/kanban/scripts/review_pr.py",
]

MANIFEST_ROW_RE = re.compile(
    r"^(?P<id>[\w-]+)\s*\|\s*(?P<kind>[\w-]+)\s*\|\s*(?P<token>[^|]+?)\s*\|"
    r"\s*(?P<files>[^|]*?)\s*\|\s*(?P<owner>[\w-]+)\s*\|\s*(?P<status>[\w-]+)\s*\|"
    r"\s*(?P<mandatory>yes|no)\s*$"
)

# proc "name" [...] / findExecutable "name" / readProcessWithExitCode "name"
# / runProcess <timeoutSeconds> "name" [...] (Kanban.Drainer's timed helper).
EXECUTABLE_CALL_RE = re.compile(
    r'(?:proc|findExecutable|readProcessWithExitCode)\s*\(?\s*"([^"]+)"'
)
TIMED_PROCESS_CALL_RE = re.compile(r'runProcess\s+\d+\s+"([^"]+)"')

# findExecutable <var> resolves an executable name bound elsewhere as a
# string literal (Solve.hs and PullRequestFlow.hs both do this rather than
# passing a literal directly), so the two known binding idioms are matched
# separately and their literals are treated as discovered invocations too.
INDIRECT_VAR_RE = re.compile(r'findExecutable\s+([A-Za-z_][A-Za-z0-9_\']*)\b')

# A `home` value built with <> or </> segments, e.g.
# `home <> "/work/approve-issues.py"` or
# `home </> "Library" </> "LaunchAgents" </> "com.coghex.drain-prs.plist"`.
HOME_PATH_EXPR_RE = re.compile(r'\bhome(?:\s*(?:<>|</>)\s*"[^"]*")+')
QUOTED_RE = re.compile(r'"([^"]*)"')


def parse_manifest():
    text = CONTRACT_PATH.read_text(encoding="utf-8")
    fence_match = re.search(r"```text\n(.*?)\n```", text, re.DOTALL)
    if fence_match is None:
        raise AssertionError(
            "docs/agent-workflow-contract.md has no ```text manifest fence"
        )
    rows = []
    for line in fence_match.group(1).splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = MANIFEST_ROW_RE.match(line)
        if match is None:
            raise AssertionError(f"unparseable manifest row: {line!r}")
        row = match.groupdict()
        row["files"] = [name for name in row["files"].split(";") if name]
        rows.append(row)
    return rows


def indirect_executable_names(content):
    """Literals bound to a variable that findExecutable resolves indirectly.

    Covers the two idioms Solve.hs and PullRequestFlow.hs use:
      executableName = case brand of
        CodexSolver -> "codex"
        ClaudeSolver -> "claude"
    and
      executableName = if brand == CodexSolver then "codex" else "claude"
    """
    names = set()
    for var_match in INDIRECT_VAR_RE.finditer(content):
        var_name = re.escape(var_match.group(1))
        case_re = re.compile(
            var_name + r'\s*=\s*case\s+\w+\s+of'
            r'((?:\n[ \t]+\S.*?->\s*"[^"]*")+)'
        )
        for case_match in case_re.finditer(content):
            names |= {quoted.group(1) for quoted in QUOTED_RE.finditer(case_match.group(1))}
        if_re = re.compile(
            var_name + r'\s*=\s*if\b[^\n]*?then\s*"([^"]*)"\s*else\s*"([^"]*)"'
        )
        for if_match in if_re.finditer(content):
            names.add(if_match.group(1))
            names.add(if_match.group(2))
    return names


def discovered_executables(content):
    names = {match.group(1) for match in EXECUTABLE_CALL_RE.finditer(content)}
    names |= {match.group(1) for match in TIMED_PROCESS_CALL_RE.finditer(content)}
    names |= indirect_executable_names(content)
    return names


def home_relative_segments(content):
    segments = set()
    for expr_match in HOME_PATH_EXPR_RE.finditer(content):
        for quoted in QUOTED_RE.finditer(expr_match.group(0)):
            segments.add(quoted.group(1))
    return segments


# A fenced ```bash ... ``` block in a packaged SKILL.md. The closing fence
# may be indented (these skills nest bash blocks inside numbered list
# items), so the leading whitespace before both fences is not anchored.
BASH_FENCE_RE = re.compile(r"```bash\n(.*?)\n[ \t]*```", re.DOTALL)
# A command invoked inside a subshell/command-substitution or after a pipe,
# e.g. `$(find ...)` or `| head -n1`.
SUBSHELL_OR_PIPE_COMMAND_RE = re.compile(r'(?:\$\(|\|)\s*([A-Za-z][A-Za-z0-9_.-]*)')
# The leading word of a non-continuation, non-assignment line, e.g.
# `python3 "$COORDINATOR" \` or `gh issue list ...`.
LEADING_COMMAND_RE = re.compile(r'^([A-Za-z][A-Za-z0-9_.-]*)(?=[ \t]|$)')
ASSIGNMENT_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')


def discovered_plugin_commands(content):
    """Every external command a packaged SKILL.md's bash blocks invoke,
    whether as the leading word of a line or inside `$( ... )`/after `|`."""
    names = set()
    for fence in BASH_FENCE_RE.finditer(content):
        body = fence.group(1)
        names |= {match.group(1) for match in SUBSHELL_OR_PIPE_COMMAND_RE.finditer(body)}
        for line in body.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or ASSIGNMENT_RE.match(stripped):
                continue
            leading = LEADING_COMMAND_RE.match(stripped)
            if leading:
                names.add(leading.group(1))
    return names


# run(["gh", ...]) / subprocess.run(["git", ...]) / run(\n    [\n        "codex", —
# the coordinator's own external-command invocation surface. `\s` matches
# newlines without needing re.DOTALL, so this covers both the single-line
# and the multi-line list-literal call styles review_pr.py uses.
PYTHON_COMMAND_CALL_RE = re.compile(r'(?:subprocess\.)?run\(\s*\[\s*"([^"]+)"')


def discovered_python_commands(content):
    """Every external command a packaged coordinator's own Python source
    invokes as the first element of a `run`/`subprocess.run` argument
    list. Deliberately does not match a dynamically-resolved first
    argument like `sys.executable` (no leading string literal there) —
    that path is python3, already covered via the SKILL.md bash surface
    that invokes this script with `python3 ...`."""
    return {match.group(1) for match in PYTHON_COMMAND_CALL_RE.finditer(content)}


def discovered_commands_for_plugin_file(relative_path, content):
    if relative_path.endswith(".py"):
        return discovered_python_commands(content)
    return discovered_plugin_commands(content)


def looks_like_path_segment(segment):
    return (
        "/" in segment
        or segment.startswith(".")
        or segment.endswith(".plist")
        or segment.endswith(".py")
    )


class AgentWorkflowContractTests(unittest.TestCase):
    def setUp(self):
        self.manifest = parse_manifest()

    def test_manifest_is_non_empty_and_well_formed(self):
        self.assertTrue(self.manifest, "manifest must declare at least one dependency")
        for row in self.manifest:
            self.assertIn(row["kind"], {"executable", "personal-path"}, row["id"])
            self.assertIn(row["owner"], {"kanban", "external"}, row["id"])
            self.assertIn(row["status"], {"supported", "migration-target"}, row["id"])
            self.assertIn(row["mandatory"], {"yes", "no"}, row["id"])

    def test_manifest_entries_are_grounded_in_their_declared_files(self):
        for row in self.manifest:
            for relative_path in row["files"]:
                file_path = REPO_ROOT / relative_path
                self.assertTrue(
                    file_path.is_file(), f"{row['id']}: {relative_path} does not exist"
                )
                content = file_path.read_text(encoding="utf-8")
                self.assertIn(
                    row["token"],
                    content,
                    f"{row['id']}: token {row['token']!r} no longer appears in "
                    f"{relative_path}; update docs/agent-workflow-contract.md",
                )

    def test_every_literal_executable_invocation_is_documented(self):
        executable_tokens = {
            row["token"] for row in self.manifest if row["kind"] == "executable"
        }
        for relative_path in SURFACE_FILES:
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            for name in discovered_executables(content):
                self.assertIn(
                    name,
                    executable_tokens,
                    f"{relative_path} invokes undocumented external command "
                    f"{name!r}; add it to the manifest in "
                    "docs/agent-workflow-contract.md",
                )

    def test_every_plugin_bash_command_is_documented(self):
        executable_tokens = {
            row["token"] for row in self.manifest if row["kind"] == "executable"
        }
        for relative_path in PLUGIN_SURFACE_FILES:
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            for name in discovered_commands_for_plugin_file(relative_path, content):
                self.assertIn(
                    name,
                    executable_tokens,
                    f"{relative_path} invokes undocumented external command "
                    f"{name!r}; add it to the manifest in "
                    "docs/agent-workflow-contract.md",
                )

    def test_review_pr_coordinator_command_invocations_are_documented(self):
        # The coordinator scan uses a different extractor (Python list
        # literals, not bash) than the SKILL.md files; pin it directly
        # against the actual coordinator so a regression in either the
        # extractor or the coordinator's own invocations is caught here,
        # not just via the generic loop above.
        content = (REPO_ROOT / "codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py").read_text(encoding="utf-8")
        found = discovered_python_commands(content)
        self.assertEqual(found, {"gh", "git", "codex", "claude"})

    def test_every_claude_plugin_bash_command_is_documented(self):
        executable_tokens = {
            row["token"] for row in self.manifest if row["kind"] == "executable"
        }
        for relative_path in CLAUDE_PLUGIN_SURFACE_FILES:
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            for name in discovered_commands_for_plugin_file(relative_path, content):
                self.assertIn(
                    name,
                    executable_tokens,
                    f"{relative_path} invokes undocumented external command "
                    f"{name!r}; add it to the manifest in "
                    "docs/agent-workflow-contract.md",
                )

    def test_claude_review_pr_coordinator_command_invocations_are_documented(self):
        # The Claude plugin bundles its own copy of the coordinator
        # (issue #77) so it never depends on the Codex plugin being
        # installed; pin its command surface directly, the same way the
        # Codex copy is pinned above.
        content = (REPO_ROOT / "claude-plugin/plugins/kanban/scripts/review_pr.py").read_text(encoding="utf-8")
        found = discovered_python_commands(content)
        self.assertEqual(found, {"gh", "git", "codex", "claude"})

    def test_plugin_bash_command_discovery_finds_find_and_head(self):
        # Pins the extractor against the actual pr-review skill rather than
        # a synthetic snippet, so a change to its coordinator-lookup command
        # that silently drops find/head fails this test instead of the
        # completeness check simply having nothing left to discover.
        content = (REPO_ROOT / "codex-plugin/plugins/kanban/skills/pr-review/SKILL.md").read_text(encoding="utf-8")
        found = discovered_plugin_commands(content)
        self.assertIn("find", found)
        self.assertIn("head", found)
        self.assertIn("python3", found)
        self.assertIn("git", found)

    def test_plugin_bash_command_discovery_skips_variable_assignments(self):
        snippet = (
            "```bash\n"
            'COORDINATOR="$(find "$HOME/.codex" -path \'*/review_pr.py\' | head -n1)"\n'
            'python3 "$COORDINATOR" --review <pr>\n'
            "```\n"
        )
        self.assertEqual(discovered_plugin_commands(snippet), {"find", "head", "python3"})

    def test_indirect_solver_brand_mappings_are_discovered(self):
        # Solve.hs and PullRequestFlow.hs resolve codex/claude through a
        # variable (`findExecutable executableName`) rather than a literal,
        # so this pins that discovered_executables still recovers both
        # brand names from each file's actual binding instead of silently
        # covering zero invocations in these two surface files.
        solve_content = (REPO_ROOT / "src/Kanban/Solve.hs").read_text(encoding="utf-8")
        pull_request_flow_content = (
            REPO_ROOT / "src/Kanban/PullRequestFlow.hs"
        ).read_text(encoding="utf-8")
        self.assertEqual(
            discovered_executables(solve_content) & {"codex", "claude"},
            {"codex", "claude"},
        )
        self.assertEqual(
            discovered_executables(pull_request_flow_content) & {"codex", "claude"},
            {"codex", "claude"},
        )

    def test_indirect_executable_extraction_handles_case_and_if_bindings(self):
        case_snippet = "\n".join(
            [
                "runThing brand = do",
                "  executable <- findExecutable executableName",
                "  where",
                "    executableName = case brand of",
                '      CodexSolver -> "codex"',
                '      ClaudeSolver -> "claude"',
            ]
        )
        self.assertEqual(indirect_executable_names(case_snippet), {"codex", "claude"})

        if_snippet = (
            "runThing brand = do\n"
            "  executable <- findExecutable executableName\n"
            '  let executableName = if brand == CodexSolver then "codex" else "claude"\n'
        )
        self.assertEqual(indirect_executable_names(if_snippet), {"codex", "claude"})

    def test_every_home_relative_path_segment_is_documented(self):
        personal_tokens = [
            row["token"]
            for row in self.manifest
            if row["kind"] == "personal-path"
        ]
        for relative_path in SURFACE_FILES:
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            for segment in home_relative_segments(content):
                if not looks_like_path_segment(segment):
                    continue
                self.assertTrue(
                    any(segment in token or token in segment for token in personal_tokens),
                    f"{relative_path} builds an undocumented home-relative path "
                    f"segment {segment!r}; declare it in the manifest",
                )

    def test_issue_review_backend_is_kanban_owned_and_supported(self):
        by_id = {row["id"]: row for row in self.manifest}
        self.assertIn(
            "approve-issues-backend",
            by_id,
            "manifest is missing required entry 'approve-issues-backend'",
        )
        entry = by_id["approve-issues-backend"]
        self.assertEqual(entry["owner"], "kanban")
        self.assertEqual(entry["status"], "supported")
        self.assertEqual(entry["mandatory"], "no")
        self.assertNotIn(
            "codex-approve-issues-skill",
            by_id,
            "codex-approve-issues-skill is no longer a dependency of any "
            "Kanban-supported command; remove it instead of re-adding it",
        )

    def test_drainer_launchagent_path_is_not_flagged_as_personal(self):
        by_id = {row["id"]: row for row in self.manifest}
        self.assertIn("drainer-launchagent-plist", by_id)
        entry = by_id["drainer-launchagent-plist"]
        self.assertEqual(entry["kind"], "personal-path")
        self.assertEqual(entry["owner"], "kanban")
        self.assertEqual(entry["status"], "supported")


if __name__ == "__main__":
    unittest.main()
