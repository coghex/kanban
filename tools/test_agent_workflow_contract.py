"""Completeness check for docs/agent-workflow-contract.md.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Reconciles the manifest in docs/agent-workflow-contract.md against the
solve, PR-flow, and canonical issue-review invocation surface so a new
external command or home-relative path cannot land undocumented.
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


def discovered_executables(content):
    names = {match.group(1) for match in EXECUTABLE_CALL_RE.finditer(content)}
    names |= {match.group(1) for match in TIMED_PROCESS_CALL_RE.finditer(content)}
    return names


def home_relative_segments(content):
    segments = set()
    for expr_match in HOME_PATH_EXPR_RE.finditer(content):
        for quoted in QUOTED_RE.finditer(expr_match.group(0)):
            segments.add(quoted.group(1))
    return segments


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

    def test_migration_targets_are_flagged(self):
        by_id = {row["id"]: row for row in self.manifest}
        for expected_id in ("approve-issues-backend", "codex-approve-issues-skill"):
            self.assertIn(
                expected_id, by_id, f"manifest is missing required entry {expected_id!r}"
            )
            self.assertEqual(by_id[expected_id]["status"], "migration-target")
            self.assertEqual(by_id[expected_id]["mandatory"], "no")

    def test_drainer_launchagent_path_is_not_flagged_as_personal(self):
        by_id = {row["id"]: row for row in self.manifest}
        self.assertIn("drainer-launchagent-plist", by_id)
        entry = by_id["drainer-launchagent-plist"]
        self.assertEqual(entry["kind"], "personal-path")
        self.assertEqual(entry["owner"], "kanban")
        self.assertEqual(entry["status"], "supported")


if __name__ == "__main__":
    unittest.main()
