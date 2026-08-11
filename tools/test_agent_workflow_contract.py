"""Completeness check for docs/agent-workflow-contract.md.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Reconciles the manifest in docs/agent-workflow-contract.md against the
solve, PR-flow, and canonical issue-review invocation surface, against
the tracked Codex and Claude plugins' own packaged-workflow bash surfaces,
and against every non-test Python module under tools/, so a new external
command or home-relative path cannot land undocumented.

Since issue #118 that plugin surface also covers the seven vendored drafting
and canonical issue-review assets (docs/drafting-workflow-contract.md §2),
including a markdown counterpart of the Haskell home-relative-path check so
the user-scoped install path those assets name is reconciled against the same
`personal-path` manifest rows.

Issue #229 added the five design and report document workflows
(docs/document-workflow-contract.md §2) on the same terms. The plugin surfaces
here are enumerated lists rather than globs, so an asset reaches the scan only
by being listed; the document assets are therefore reconciled against their own
contract's declared set, and what the extractor recovers from each of them is
pinned, so neither list can drift away from the other and neither can shrink to
covering nothing.
"""

import re
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CONTRACT_PATH = REPO_ROOT / "docs" / "agent-workflow-contract.md"

# The solve, PR-flow, and canonical issue-review invocation surface, plus
# the shared provider/process helpers they call into. This list is
# exhaustive for src/: nothing else under src/ matches
# findExecutable/proc/readProcessWithExitCode/readCreateProcessWithExitCode/
# getHomeDirectory. The review surface is spread over three modules since
# issue #164 split Kanban.Review: the app-server spawn stayed in Review.hs,
# the gh/claude tool runners moved to Review/Tools.hs, and the canonical
# backend's python3 invocation and discovery record moved to
# Review/Canonical.hs.
SURFACE_FILES = [
    "src/Kanban/Solve.hs",
    "src/Kanban/PullRequestFlow.hs",
    "src/Kanban/Preflight/Environment.hs",
    "src/Kanban/Review.hs",
    "src/Kanban/Review/Canonical.hs",
    "src/Kanban/Review/Tools.hs",
    "src/Kanban/Codex.hs",
    "src/Kanban/Claude.hs",
    "src/Kanban/GitHub/Run.hs",
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
    "codex-plugin/plugins/kanban/skills/issue/SKILL.md",
    "codex-plugin/plugins/kanban/skills/autoissue/SKILL.md",
    "codex-plugin/plugins/kanban/skills/issue-review/SKILL.md",
    "codex-plugin/plugins/kanban/skills/repair/SKILL.md",
    "codex-plugin/plugins/kanban/skills/design-epic/SKILL.md",
    "codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md",
    "codex-plugin/plugins/kanban/skills/draft-report/SKILL.md",
    "codex-plugin/plugins/kanban/skills/process-report/SKILL.md",
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
    "claude-plugin/plugins/kanban/commands/issue.md",
    "claude-plugin/plugins/kanban/commands/draft-issues.md",
    "claude-plugin/plugins/kanban/commands/autoissue.md",
    "claude-plugin/plugins/kanban/commands/issue-review.md",
    "claude-plugin/plugins/kanban/commands/repair.md",
    "claude-plugin/plugins/kanban/commands/process-report.md",
    "claude-plugin/plugins/kanban/scripts/review_pr.py",
]

# The seven drafting and canonical issue-review assets vendored by issue #118.
# All seven are scanned for external commands via the lists above — the bash
# fence extractor simply returns an empty set for an asset with no ```bash
# fence, so a prose-only contract is covered rather than exempted — and all
# seven are scanned here for user-scoped paths. Scoped to these assets
# deliberately: the pre-existing packaged workflows build home-relative paths
# (worktrees roots, $CODEX_HOME coordinator lookups) that predate this check
# and are not part of this contract's surface.
DRAFTING_SURFACE_FILES = [
    "claude-plugin/plugins/kanban/commands/issue.md",
    "claude-plugin/plugins/kanban/commands/draft-issues.md",
    "claude-plugin/plugins/kanban/commands/autoissue.md",
    "claude-plugin/plugins/kanban/commands/issue-review.md",
    "codex-plugin/plugins/kanban/skills/issue/SKILL.md",
    "codex-plugin/plugins/kanban/skills/autoissue/SKILL.md",
    "codex-plugin/plugins/kanban/skills/issue-review/SKILL.md",
]

# The five design and report document-workflow assets vendored by issue #229
# (docs/document-workflow-contract.md §2), covered exactly the way the drafting
# assets above are: all five are members of the two plugin surface lists, so
# their bash fences are already scanned for external commands, and all five are
# scanned here for user-scoped paths. They name none today — which is why the
# assertion below pins what the extractor actually recovers from them, rather
# than only asserting that nothing undeclared was found.
DOCUMENT_SURFACE_FILES = [
    "claude-plugin/plugins/kanban/commands/process-report.md",
    "codex-plugin/plugins/kanban/skills/design-epic/SKILL.md",
    "codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md",
    "codex-plugin/plugins/kanban/skills/draft-report/SKILL.md",
    "codex-plugin/plugins/kanban/skills/process-report/SKILL.md",
]

# What each document-workflow asset's bash fences actually invoke. Every one
# resolves the docs worktree with `git worktree list | awk ...`; the processing
# workflows additionally list and search issues with `gh`, and the Claude
# process-report lists finding headings with `rg` inside a fence rather than in
# prose. Pinned so a rewrite that stops invoking anything cannot leave the
# completeness check with nothing to discover.
DOCUMENT_SURFACE_EXPECTED_COMMANDS = {
    "claude-plugin/plugins/kanban/commands/process-report.md": {"git", "awk", "gh", "rg"},
    "codex-plugin/plugins/kanban/skills/design-epic/SKILL.md": {"git", "awk"},
    "codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md": {"git", "awk", "gh"},
    "codex-plugin/plugins/kanban/skills/draft-report/SKILL.md": {"git", "awk"},
    "codex-plugin/plugins/kanban/skills/process-report/SKILL.md": {"git", "awk", "gh"},
}

# The repository's own tools (issue #149): the drainer, its installer and
# controller, the canonical issue-review backend, and the workflow installers.
# Unlike the lists above this surface is discovered rather than
# enumerated, so a tool module added later is scanned as soon as it lands
# instead of bypassing the check until someone remembers to list it. Test
# modules are excluded because they build fake executables on a temporary PATH
# rather than depend on real ones, and tools/fake_cli.py is excluded for the
# same reason despite its non-test name: it is the library those fakes run.
# That one is excluded by its path relative to tools/, not by basename — an
# exclusion keyed to the name alone would silently exempt a future
# tools/<subpackage>/fake_cli.py that is an ordinary module.
TOOLS_DIR = REPO_ROOT / "tools"
TOOL_SURFACE_EXCLUDED_PATHS = {"fake_cli.py"}

MANIFEST_ROW_RE = re.compile(
    r"^(?P<id>[\w-]+)\s*\|\s*(?P<kind>[\w-]+)\s*\|\s*(?P<token>[^|]+?)\s*\|"
    r"\s*(?P<files>[^|]*?)\s*\|\s*(?P<owner>[\w-]+)\s*\|\s*(?P<status>[\w-]+)\s*\|"
    r"\s*(?P<mandatory>yes|no)\s*$"
)

# Anchored to the §4 heading rather than taking the document's first ```text
# fence. Issue #225 added a second machine-readable fence to the same contract
# (§7's document publication classification), so "the first unqualified text
# fence" stopped being a definition of this manifest and became an accident of
# section order. Each parser now owns its heading; see
# tools/test_document_classification.py for §7's counterpart.
SECTION_4_FENCE_RE = re.compile(
    r"^##\s*4\.\s*Dependency manifest\s*$.*?```text\n(?P<body>.*?)\n```",
    re.DOTALL | re.MULTILINE,
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
# `home <> "/Library/Application Support/kanban/pr-drainer/config.json"`.
HOME_PATH_EXPR_RE = re.compile(r'\bhome(?:\s*(?:<>|</>)\s*"[^"]*")+')
QUOTED_RE = re.compile(r'"([^"]*)"')


DOCUMENT_CONTRACT_PATH = REPO_ROOT / "docs" / "document-workflow-contract.md"
DOCUMENT_CONTRACT_FENCE_RE = re.compile(
    r"^##\s*2\.\s*Declared assets\s*$.*?```text\n(?P<body>.*?)\n```",
    re.DOTALL | re.MULTILINE,
)
DOCUMENT_CONTRACT_ROW_RE = re.compile(
    r"^(?:claude|codex)\s*\|\s*[/$][\w-]+\s*\|\s*(?P<path>\S+)$"
)


def declared_document_assets():
    """The asset paths docs/document-workflow-contract.md §2 declares, read
    from the document rather than restated here, so this module's scan surface
    is reconciled against the contract instead of against a copy of it."""
    text = DOCUMENT_CONTRACT_PATH.read_text(encoding="utf-8")
    fence_match = DOCUMENT_CONTRACT_FENCE_RE.search(text)
    if fence_match is None:
        raise AssertionError(
            "docs/document-workflow-contract.md has no ```text declared-asset "
            "fence under its '## 2. Declared assets' heading"
        )
    paths = set()
    for line in fence_match.group("body").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        row_match = DOCUMENT_CONTRACT_ROW_RE.match(line)
        if row_match is None:
            raise AssertionError(f"unparseable declared-asset row: {line!r}")
        paths.add(row_match.group("path"))
    return paths


def parse_manifest(text=None):
    """Rows from the §4 machine-readable fence. Anchored to the '## 4.
    Dependency manifest' heading so another ```text fence in this document —
    §7's classification table, or anything added later — can never be parsed
    as the dependency manifest. Parameterized by text so the regression test
    below can drive it against a fixture rather than only against the document
    that already passes."""
    if text is None:
        text = CONTRACT_PATH.read_text(encoding="utf-8")
    fence_match = SECTION_4_FENCE_RE.search(text)
    if fence_match is None:
        raise AssertionError(
            "docs/agent-workflow-contract.md has no ```text manifest fence "
            "under its '## 4. Dependency manifest' heading"
        )
    rows = []
    for line in fence_match.group("body").splitlines():
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
# e.g. `$(find ...)` or `| head -n1`. The trailing lookahead requires the word
# to end where a command name ends: not mid-token, and not at an `=`. Without
# it the second `|` of a `||` reads as a pipe, so the shell assignment in
# `[ -n "$X" ] || X="$(git ...)"` — the docs-worktree fallback every
# DOCUMENT_SURFACE_FILES asset opens with — would be reported as an
# undocumented external command named `X`. Line-leading assignments are already
# skipped via ASSIGNMENT_RE below; this is the same exclusion for the one
# position that regex cannot see. A real invocation is never followed by `=`,
# so nothing is lost.
SUBSHELL_OR_PIPE_COMMAND_RE = re.compile(
    r'(?:\$\(|\|)\s*([A-Za-z][A-Za-z0-9_.-]*)(?![A-Za-z0-9_.=-])'
)
# The leading word of a non-continuation, non-assignment line, e.g.
# `python3 "$COORDINATOR" \` or `gh issue list ...`.
LEADING_COMMAND_RE = re.compile(r'^([A-Za-z][A-Za-z0-9_.-]*)(?=[ \t]|$)')
ASSIGNMENT_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')
# A heredoc: its body is the *input* to the command on the opening line, not
# a sequence of commands. The issue-review workflows feed a Python program in
# this way, and every one of its lines would otherwise read as an
# undocumented external command. The opening line is kept — that is where the
# real invocation (`python3 - "$RECORD" <<'PY'`) lives — and the body and its
# terminator are dropped. Only the quoted form is matched, since an unquoted
# delimiter permits expansion and is not the shape any packaged asset uses.
HEREDOC_BODY_RE = re.compile(
    r"(<<-?\s*(['\"])(?P<tag>[A-Za-z_][A-Za-z0-9_]*)\2[^\n]*\n)"
    r".*?^[ \t]*(?P=tag)[ \t]*$\n?",
    re.DOTALL | re.MULTILINE,
)


def without_heredoc_bodies(body):
    """`body` with every heredoc's content replaced by its opening line, so
    data fed to a command is never mistaken for commands."""
    return HEREDOC_BODY_RE.sub(lambda match: match.group(1), body)


def discovered_plugin_commands(content):
    """Every external command a packaged SKILL.md's bash blocks invoke,
    whether as the leading word of a line or inside `$( ... )`/after `|`."""
    names = set()
    for fence in BASH_FENCE_RE.finditer(content):
        body = without_heredoc_bodies(fence.group(1))
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


# run(["git", ...]) / subprocess.run(["gh", ...]) / run_command(["launchctl",
# ...]) / run_json(["gh", ...]) / subprocess.Popen(["...", ...]) — the
# repository tools' own external-command surface. These modules spawn through
# their own thin wrappers at least as often as through subprocess directly,
# and each module names its wrappers differently: every launchctl call in
# tools/drain_prs_service.py goes through run_command, while approve_issues.py
# and drain_prs.py add run_json on top of run. So the callee is matched as a
# family — anything spelled `run`, plus the subprocess entry points — rather
# than as a fixed list of wrapper names that the next wrapper would slip past.
# The net is deliberately generous: a false positive fails loudly and is
# corrected by declaring or renaming, whereas a miss is a dependency that
# lands undocumented, which is the failure this whole file exists to prevent.
# `\s` matches newlines without re.DOTALL, so a list literal split across
# lines is covered too, and either Python quote style is accepted: every tool
# here happens to use double quotes, but a check whose gate a single-quoted
# literal walks through is not a gate.
TOOL_COMMAND_CALL_RE = re.compile(
    r'\b(?:[A-Za-z_][A-Za-z0-9_]*\.)?'
    r'(?:[a-z_]*run[a-z_0-9]*|Popen|check_call|check_output|call)'
    r'\(\s*\[\s*(?P<quote>["\'])(?P<name>[^"\']+)(?P=quote)'
)


def discovered_tool_commands(content):
    """Every external command a tools/ module invokes as the first element of
    a literal argument list. A dynamically-built command list is deliberately
    not matched, the same way the coordinator extractor above skips
    `sys.executable`: this reads source, and nothing here runs a tool to find
    out what it spawns."""
    return {match.group("name") for match in TOOL_COMMAND_CALL_RE.finditer(content)}


def tool_surface_files(tools_dir=TOOLS_DIR):
    """Every eligible module of the tools/ surface, discovered by walking it."""
    return sorted(
        path
        for path in tools_dir.rglob("*.py")
        if not path.name.startswith("test_")
        and path.relative_to(tools_dir).as_posix() not in TOOL_SURFACE_EXCLUDED_PATHS
    )


def undocumented_command_message(relative_path, name):
    return (
        f"{relative_path} invokes undocumented external command "
        f"{name!r}; add it to the manifest in "
        "docs/agent-workflow-contract.md"
    )


def tool_surface_findings(executable_tokens, tools_dir=TOOLS_DIR):
    """`(path, command)` for every literal invocation in an eligible tools/
    module whose command has no `executable` manifest row."""
    findings = []
    for path in tool_surface_files(tools_dir):
        relative_path = path.relative_to(tools_dir.parent).as_posix()
        content = path.read_text(encoding="utf-8")
        for name in sorted(discovered_tool_commands(content)):
            if name not in executable_tokens:
                findings.append((relative_path, name))
    return findings


# A `$HOME/`- or `~/`-prefixed path in a packaged markdown workflow, the
# non-Haskell counterpart of HOME_PATH_EXPR_RE above. A path component may
# contain spaces (Kanban's own install root is `Library/Application
# Support/kanban/...`), so a component is one-or-more space-separated words
# and the match ends at the characters that close a path inside shell
# expansion, a quoted string, or markdown inline code — e.g. the `}` closing
# `${KANBAN_ISSUE_REVIEW_INSTALL_DIR:-$HOME/Library/Application Support/kanban/issue-review}`.
# Allowing spaces means an undelimited path in running prose over-captures
# trailing words rather than truncating; for a completeness gate that fails
# loudly, which is the safe direction. The captured segment keeps its leading
# slash so it compares against a `personal-path` manifest token exactly the
# way the Haskell segments do.
_MARKDOWN_PATH_WORD = r'[^\s"\'`}$)\\<>/]+'
MARKDOWN_HOME_PATH_RE = re.compile(
    r'(?:\$HOME|~)((?:/' + _MARKDOWN_PATH_WORD + r'(?: ' + _MARKDOWN_PATH_WORD + r')*)+)'
)


def markdown_home_relative_segments(content):
    """Every user-scoped path a packaged markdown workflow names, whether in a
    fenced bash block or in the surrounding prose that documents it."""
    segments = set()
    for match in MARKDOWN_HOME_PATH_RE.finditer(content):
        segment = match.group(1).rstrip("/.,;:")
        if segment and segment != "/":
            segments.add(segment)
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

    def test_the_manifest_parser_is_anchored_to_its_own_section(self):
        # Issue #225 added §7's classification fence to this same document, so
        # the manifest parser can no longer be defined as "the first ```text
        # fence". Drive it against a fixture whose classification fence comes
        # first: an unanchored parser returns the classification rows (or
        # raises on them as unparseable manifest rows), and this one does not.
        fixture = (
            "# Contract\n\n"
            "## 7. Document publication classification\n\n"
            "```text\n"
            "docs/ui-bugs.md | coordination | audit-report\n"
            "```\n\n"
            "## 4. Dependency manifest\n\n"
            "```text\n"
            "fixture-cli | executable | fixture | src/Fixture.hs | kanban | supported | no\n"
            "```\n"
        )
        rows = parse_manifest(fixture)
        self.assertEqual([row["id"] for row in rows], ["fixture-cli"])
        self.assertEqual(rows[0]["files"], ["src/Fixture.hs"])

    def test_the_real_contract_yields_only_dependency_rows(self):
        # The same regression against the tracked document rather than a
        # fixture. A classification row's first column is a path, which no
        # dependency id is; the §7 half of this pair — that its parser
        # recovers no dependency row — lives in
        # tools/test_document_classification.py.
        self.assertIn("gh-cli", {row["id"] for row in self.manifest})
        self.assertEqual(
            [],
            [row["id"] for row in self.manifest if "/" in row["id"] or "." in row["id"]],
            "the §4 parser captured rows from the §7 classification fence",
        )

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

    def test_every_drafting_asset_bash_command_is_documented(self):
        # Requirement 8 of issue #118: the check must scan all seven vendored
        # drafting/issue-review assets. They are already members of the two
        # plugin surface lists above; this pins the seven explicitly so a
        # future edit to those lists cannot silently drop one.
        executable_tokens = {
            row["token"] for row in self.manifest if row["kind"] == "executable"
        }
        for relative_path in DRAFTING_SURFACE_FILES:
            self.assertTrue(
                relative_path in PLUGIN_SURFACE_FILES
                or relative_path in CLAUDE_PLUGIN_SURFACE_FILES,
                f"{relative_path} is not scanned by either plugin surface list",
            )
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            for name in discovered_commands_for_plugin_file(relative_path, content):
                self.assertIn(
                    name,
                    executable_tokens,
                    f"{relative_path} invokes undocumented external command "
                    f"{name!r}; add it to the manifest in "
                    "docs/agent-workflow-contract.md",
                )

    def test_every_drafting_asset_home_relative_path_is_documented(self):
        personal_tokens = [
            row["token"] for row in self.manifest if row["kind"] == "personal-path"
        ]
        for relative_path in DRAFTING_SURFACE_FILES:
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            for segment in markdown_home_relative_segments(content):
                self.assertTrue(
                    any(segment in token or token in segment for token in personal_tokens),
                    f"{relative_path} names an undocumented user-scoped path "
                    f"segment {segment!r}; declare it in the manifest",
                )

    def test_every_declared_document_asset_is_scanned_for_external_commands(self):
        # Requirement 6 of issue #229 and its review correction: the two plugin
        # surfaces above are enumerated lists, not globs, so a vendored asset
        # that is not listed is simply never scanned. Driven by the contract
        # document itself, so declaring a sixth asset without adding it to a
        # scan list fails here rather than silently exempting it.
        declared = declared_document_assets()
        self.assertEqual(
            declared,
            set(DOCUMENT_SURFACE_FILES),
            "docs/document-workflow-contract.md §2 and DOCUMENT_SURFACE_FILES "
            "disagree about which assets exist",
        )
        for relative_path in sorted(declared):
            self.assertTrue(
                relative_path in PLUGIN_SURFACE_FILES
                or relative_path in CLAUDE_PLUGIN_SURFACE_FILES,
                f"{relative_path} is not scanned by either plugin surface list",
            )

    def test_every_document_asset_bash_command_is_documented(self):
        executable_tokens = {
            row["token"] for row in self.manifest if row["kind"] == "executable"
        }
        for relative_path in DOCUMENT_SURFACE_FILES:
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            for name in discovered_commands_for_plugin_file(relative_path, content):
                self.assertIn(
                    name,
                    executable_tokens,
                    f"{relative_path} invokes undocumented external command "
                    f"{name!r}; add it to the manifest in "
                    "docs/agent-workflow-contract.md",
                )

    def test_document_asset_command_discovery_is_not_vacuous(self):
        # The bullet above passes trivially against an asset the extractor
        # recovers nothing from, so pin what each one actually invokes. These
        # are the commands docs/agent-workflow-contract.md §4 declares for
        # them; a rewrite that drops or adds one fails here rather than
        # quietly shrinking the surface being reconciled.
        for relative_path, expected in sorted(DOCUMENT_SURFACE_EXPECTED_COMMANDS.items()):
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            self.assertEqual(
                discovered_commands_for_plugin_file(relative_path, content),
                expected,
                relative_path,
            )

    def test_every_document_asset_home_relative_path_is_documented(self):
        personal_tokens = [
            row["token"] for row in self.manifest if row["kind"] == "personal-path"
        ]
        for relative_path in DOCUMENT_SURFACE_FILES:
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            for segment in markdown_home_relative_segments(content):
                self.assertTrue(
                    any(segment in token or token in segment for token in personal_tokens),
                    f"{relative_path} names an undocumented user-scoped path "
                    f"segment {segment!r}; declare it in the manifest",
                )

    def test_plugin_bash_command_discovery_skips_an_assignment_after_a_logical_or(self):
        # The docs-worktree fallback every document-workflow asset opens with.
        # Its `||` is a logical OR, not a pipe, and what follows is a shell
        # assignment; only the two `git` calls and the `awk` filter are
        # commands.
        snippet = (
            "```bash\n"
            'DOCS_WT="$(git worktree list --porcelain \\\n'
            "  | awk '/^worktree /{p=substr($0,10)} "
            "/^branch refs\\/heads\\/docs-wip$/{print p; exit}')\"\n"
            '[ -n "$DOCS_WT" ] || DOCS_WT="$(git rev-parse --show-toplevel)"\n'
            "```\n"
        )
        self.assertEqual(discovered_plugin_commands(snippet), {"git", "awk"})

    def test_the_assignment_exclusion_does_not_hide_a_command_after_a_logical_or(self):
        # The exclusion above must stay an assignment exclusion. A real command
        # in the same position is still an invocation, and a `--flag=value`
        # argument must not shorten the command name that precedes it.
        snippet = (
            "```bash\n"
            "[ -f config ] || cp config.example config\n"
            "git log | grep --max-count=1 origin\n"
            "```\n"
        )
        self.assertEqual(discovered_plugin_commands(snippet), {"cp", "git", "grep"})

    def test_markdown_home_path_extraction_finds_the_backend_install_path(self):
        # Pins the extractor against the actual packaged issue-review assets
        # rather than a synthetic snippet, so a rewrite that stops naming the
        # Kanban-managed install path fails here instead of leaving the
        # completeness check with nothing to discover. The discovery record is
        # the only user-scoped path these assets name now: the backend itself
        # is read out of that record rather than composed from a default, so
        # there is no `$HOME`-anchored approve_issues.py left to find.
        for relative_path in (
            "claude-plugin/plugins/kanban/commands/issue-review.md",
            "codex-plugin/plugins/kanban/skills/issue-review/SKILL.md",
            "claude-plugin/plugins/kanban/commands/solve.md",
            "codex-plugin/plugins/kanban/skills/solve/SKILL.md",
        ):
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            found = markdown_home_relative_segments(content)
            self.assertIn(
                "/Library/Application Support/kanban/issue-review/config.json",
                found,
                relative_path,
            )

    def test_heredoc_bodies_are_read_as_data_rather_than_commands(self):
        # The issue-review workflows feed a Python resolver to `python3 -` as
        # a heredoc. Its lines are input, not invocations; only the command on
        # the opening line is one. Without this the extractor reports every
        # Python statement as an undocumented external command.
        snippet = (
            "```bash\n"
            'BACKEND="$(python3 - "$RECORD" <<\'PY\'\n'
            "import json, os, sys\n"
            "record = Path(sys.argv[1])\n"
            "print(record)\n"
            "PY\n"
            ')"\n'
            "gh issue view 1\n"
            "```\n"
        )
        self.assertEqual(discovered_plugin_commands(snippet), {"python3", "gh"})

    def test_heredoc_stripping_leaves_ordinary_bash_blocks_alone(self):
        snippet = "```bash\ngit status\nfind . | head -n1\n```\n"
        self.assertEqual(discovered_plugin_commands(snippet), {"git", "find", "head"})

    def test_markdown_home_path_extraction_handles_shell_expansion_and_prose(self):
        snippet = (
            "resolve it the same way, otherwise `~/Library/Application Support/kanban/x.py`:\n\n"
            "```bash\n"
            'BACKEND="${KANBAN_ISSUE_REVIEW_INSTALL_DIR:-$HOME/Library/Application Support/kanban}/x.py"\n'
            "```\n"
        )
        self.assertEqual(
            markdown_home_relative_segments(snippet),
            {
                "/Library/Application Support/kanban/x.py",
                "/Library/Application Support/kanban",
            },
        )

    def test_every_tool_module_command_invocation_is_documented(self):
        executable_tokens = {
            row["token"] for row in self.manifest if row["kind"] == "executable"
        }
        findings = tool_surface_findings(executable_tokens)
        self.assertEqual(
            findings,
            [],
            "; ".join(
                undocumented_command_message(relative_path, name)
                for relative_path, name in findings
            ),
        )

    def test_tool_surface_covers_every_non_test_module_and_excludes_fakes(self):
        paths = {
            path.relative_to(TOOLS_DIR).as_posix() for path in tool_surface_files()
        }
        self.assertIn("drain_prs_service.py", paths)
        self.assertIn("install_drainer.py", paths)
        self.assertIn("drain_prs.py", paths)
        self.assertNotIn(
            "fake_cli.py",
            paths,
            "tools/fake_cli.py builds the fake executables the tests install "
            "on a temporary PATH; scanning it would declare fixtures as real "
            "dependencies",
        )
        self.assertEqual(
            sorted(path for path in paths if Path(path).name.startswith("test_")), []
        )

    def test_tool_command_discovery_covers_the_run_command_wrapper(self):
        # Pins the extractor against the two modules that actually spawn
        # launchctl rather than a synthetic snippet. drain_prs_service.py
        # reaches launchctl only through its own run_command wrapper, so an
        # extractor keyed to `run(`/`subprocess.run(` finds zero commands
        # here and the completeness check silently has nothing to discover.
        for relative_path in ("tools/drain_prs_service.py", "tools/install_drainer.py"):
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            self.assertEqual(
                discovered_tool_commands(content), {"git", "launchctl"}, relative_path
            )
        # Either Python quote style, so a tool written with single quotes is
        # held to the same standard as the ones already here.
        self.assertEqual(
            discovered_tool_commands("run_command(['launchctl', 'print'])"),
            {"launchctl"},
        )
        # And any wrapper of the same family, not a fixed list of names:
        # approve_issues.py and drain_prs.py both reach gh through run_json,
        # which is neither `run` nor `run_command`.
        for relative_path in ("tools/approve_issues.py", "tools/drain_prs.py"):
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            self.assertIn("gh", discovered_tool_commands(content), relative_path)
        self.assertEqual(
            discovered_tool_commands('run_json(\n    ["gh", "repo", "view"],\n)'),
            {"gh"},
        )

    def test_tool_surface_reconciles_against_the_existing_executable_rows(self):
        # Adding this surface must not require re-declaring commands that
        # already have rows: the whole eligible surface spawns exactly these
        # five, and only launchctl was missing before issue #149.
        found = set()
        for path in tool_surface_files():
            found |= discovered_tool_commands(path.read_text(encoding="utf-8"))
        self.assertEqual(found, {"gh", "git", "codex", "claude", "launchctl"})

    def test_launchctl_is_declared_and_its_removal_fails_the_check(self):
        by_id = {row["id"]: row for row in self.manifest}
        self.assertIn("launchctl-cli", by_id)
        entry = by_id["launchctl-cli"]
        self.assertEqual(entry["kind"], "executable")
        self.assertEqual(entry["token"], "launchctl")
        self.assertEqual(
            entry["files"], ["tools/drain_prs_service.py", "tools/install_drainer.py"]
        )
        # mandatory: no, matching §2.6 — the drainer is an optional component.
        self.assertEqual(entry["mandatory"], "no")
        # And the row is load-bearing rather than decorative: drop it while
        # the invocations remain and both invoking modules are reported.
        without_launchctl = {
            row["token"]
            for row in self.manifest
            if row["kind"] == "executable" and row["token"] != "launchctl"
        }
        self.assertEqual(
            tool_surface_findings(without_launchctl),
            [
                ("tools/drain_prs_service.py", "launchctl"),
                ("tools/install_drainer.py", "launchctl"),
            ],
        )

    def test_undeclared_tool_command_fails_the_tool_surface_check(self):
        # A temporary tools/ tree stands in for a future edit: an undeclared
        # command reaches the report whether it is spawned directly or through
        # any wrapper of the run family, and in either Python quote style — a
        # gate a single-quoted literal walks through is not a gate. Neither a
        # test module nor a fake-builder contributes one.
        executable_tokens = {
            row["token"] for row in self.manifest if row["kind"] == "executable"
        }
        with tempfile.TemporaryDirectory() as temp_dir:
            tools_dir = Path(temp_dir) / "tools"
            tools_dir.mkdir()
            (tools_dir / "direct_tool.py").write_text(
                'subprocess.run(["undeclared-direct", "status"])\n', encoding="utf-8"
            )
            (tools_dir / "quoted_tool.py").write_text(
                "subprocess.run(['undeclared-single-quoted', 'status'])\n",
                encoding="utf-8",
            )
            (tools_dir / "wrapper_tool.py").write_text(
                'run_command(["undeclared-wrapped", "print", target])\n',
                encoding="utf-8",
            )
            (tools_dir / "json_tool.py").write_text(
                'data = run_json(\n    ["undeclared-json-wrapped", "list"],\n    cwd=root,\n)\n',
                encoding="utf-8",
            )
            (tools_dir / "test_wrapper_tool.py").write_text(
                'run_command(["fixture-only", "print"])\n', encoding="utf-8"
            )
            (tools_dir / "fake_cli.py").write_text(
                'subprocess.run(["fake-only", "print"])\n', encoding="utf-8"
            )
            findings = tool_surface_findings(executable_tokens, tools_dir=tools_dir)
        self.assertEqual(
            findings,
            [
                ("tools/direct_tool.py", "undeclared-direct"),
                ("tools/json_tool.py", "undeclared-json-wrapped"),
                ("tools/quoted_tool.py", "undeclared-single-quoted"),
                ("tools/wrapper_tool.py", "undeclared-wrapped"),
            ],
        )

    def test_only_the_root_fake_cli_is_exempt_from_the_tool_surface(self):
        # The exemption is tools/fake_cli.py, the library the fakes run — not
        # the basename. A nested module that merely shares that name is an
        # ordinary tool and must be scanned, or the exclusion becomes a way to
        # smuggle an undeclared dependency into the surface.
        executable_tokens = {
            row["token"] for row in self.manifest if row["kind"] == "executable"
        }
        with tempfile.TemporaryDirectory() as temp_dir:
            tools_dir = Path(temp_dir) / "tools"
            (tools_dir / "subpackage").mkdir(parents=True)
            (tools_dir / "fake_cli.py").write_text(
                'subprocess.run(["fake-only", "print"])\n', encoding="utf-8"
            )
            (tools_dir / "subpackage" / "fake_cli.py").write_text(
                'subprocess.run(["undeclared-nested", "print"])\n', encoding="utf-8"
            )
            findings = tool_surface_findings(executable_tokens, tools_dir=tools_dir)
        self.assertEqual(
            findings, [("tools/subpackage/fake_cli.py", "undeclared-nested")]
        )
        for relative_path, name in findings:
            message = undocumented_command_message(relative_path, name)
            self.assertIn(name, message)
            self.assertIn("docs/agent-workflow-contract.md", message)

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

    def test_drainer_launchagent_label_is_not_flagged_as_personal(self):
        by_id = {row["id"]: row for row in self.manifest}
        self.assertIn("drainer-launchagent-label", by_id)
        entry = by_id["drainer-launchagent-label"]
        self.assertEqual(entry["kind"], "personal-path")
        self.assertEqual(entry["owner"], "kanban")
        self.assertEqual(entry["status"], "supported")

    def test_drainer_launchagent_label_has_one_owning_component(self):
        # The component that writes the plist owns the label. Haskell cannot
        # import a Python constant, so a second definition anywhere could only
        # drift — and drift here presents as "drainer not found" with every
        # side looking correct in isolation. The generic grounding test above
        # only proves the token still appears in its declared file; this one
        # proves nothing else restates it.
        entry = {row["id"]: row for row in self.manifest}["drainer-launchagent-label"]
        self.assertEqual(entry["files"], ["tools/drain_prs_service.py"])
        label = entry["token"]
        sources = [
            *REPO_ROOT.glob("src/**/*.hs"),
            *REPO_ROOT.glob("app/**/*.hs"),
            *REPO_ROOT.glob("tools/*.py"),
        ]
        restated = sorted(
            str(path.relative_to(REPO_ROOT))
            for path in sources
            if not path.name.startswith("test_")
            and str(path.relative_to(REPO_ROOT)) not in entry["files"]
            and label in path.read_text(encoding="utf-8")
        )
        self.assertEqual(
            restated,
            [],
            f"{label!r} is restated outside {entry['files'][0]}: {restated}; "
            "read it from the component that writes the plist instead",
        )

    def test_drainer_discovery_record_grounds_its_writer_and_its_reader(self):
        # The record is the whole cross-language coupling: the controller
        # writes it, Kanban reads it, and neither can see the other's
        # constants. So the manifest has to name both sides, and the path has
        # to appear literally in each rather than only in whichever one a
        # single-file row happened to declare.
        by_id = {row["id"]: row for row in self.manifest}
        self.assertIn("drainer-discovery-record", by_id)
        entry = by_id["drainer-discovery-record"]
        self.assertEqual(entry["kind"], "personal-path")
        self.assertEqual(entry["owner"], "kanban")
        self.assertEqual(entry["status"], "supported")
        self.assertEqual(
            entry["files"], ["tools/drain_prs_service.py", "src/Kanban/Drainer.hs"]
        )
        for relative_path in entry["files"]:
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            self.assertIn(entry["token"], content, relative_path)


    def test_issue_review_discovery_record_grounds_every_reader(self):
        # Same coupling as the drainer's record, for the canonical reviewer:
        # tools/install_issue_review.py writes it and five consumers across
        # three languages read it, none of which can see each other's
        # constants. The manifest names every side that spells the path, and
        # the writer is absent on purpose -- it imports the location from
        # tools/kanban_config.py instead of restating it.
        by_id = {row["id"]: row for row in self.manifest}
        self.assertIn("issue-review-discovery-record", by_id)
        entry = by_id["issue-review-discovery-record"]
        self.assertEqual(entry["kind"], "personal-path")
        self.assertEqual(entry["owner"], "kanban")
        self.assertEqual(entry["status"], "supported")
        self.assertEqual(
            entry["files"],
            [
                "src/Kanban/Review/Canonical.hs",
                "codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py",
                "claude-plugin/plugins/kanban/scripts/review_pr.py",
                "codex-plugin/plugins/kanban/skills/issue-review/SKILL.md",
                "claude-plugin/plugins/kanban/commands/issue-review.md",
                "codex-plugin/plugins/kanban/skills/solve/SKILL.md",
                "claude-plugin/plugins/kanban/commands/solve.md",
            ],
        )
        for relative_path in entry["files"]:
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            self.assertIn(entry["token"], content, relative_path)
        # The single tracked spelling of the install directory the record's
        # own path is derived from, and the only executable allowed to hold
        # it (issue #155's single-source acceptance).
        install_dir = by_id["approve-issues-backend"]
        self.assertEqual(install_dir["files"], ["tools/kanban_config.py"])
        self.assertTrue(entry["token"].startswith(install_dir["token"] + "/"))


if __name__ == "__main__":
    unittest.main()
