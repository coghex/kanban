"""Completeness check for docs/agent-workflow-contract.md.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Reconciles the manifest in docs/agent-workflow-contract.md against the
solve, PR-flow, and canonical issue-review invocation surface, against
the tracked Codex and Claude plugins' own packaged-workflow bash surfaces,
and against every non-test Python module under tools/, so a new external
command or home-relative path cannot land undocumented.

Home-relative paths are reconciled over two surfaces with two extractors, since
the same managed location is spelled differently in each. The Haskell modules
build one as a single literal hung off `home`; the three issue-approval modules
of docs/agent-workflow-contract.md §2.8 (issue #425) compose one from `pathlib`
segments, often across a bound name or a nullary helper, so they are scanned
separately for that shape — the way the bundled coordinator is scanned
separately from the `.md` surfaces — by resolving the parsed module rather than
by matching text. What the extractor recovers from each of the three is pinned,
and fixture regressions prove that an undeclared segment is reported, that a
tail hung off a binding or a helper is recovered whole rather than only to its
prefix, and that a module which cannot be parsed fails rather than reporting
nothing.

Since issue #118 that plugin surface also covers the vendored drafting and
canonical issue-review assets (docs/drafting-workflow-contract.md §2) — nine of
them since issue #240 added the issue-rereview repair loop — including a
markdown counterpart of the Haskell home-relative-path check so the user-scoped
paths those assets name are reconciled against the same `personal-path`
manifest rows.

Issue #229 added the design and report document workflows
(docs/document-workflow-contract.md §2) on the same terms, and issue #241 grew
that declared set to seven by transposing /design-epic and /process-design-doc
into the Claude bundle. The plugin surfaces
here are enumerated lists rather than globs, so an asset reaches the scan only
by being listed; the document assets are therefore reconciled against their own
contract's declared set, and what the extractor recovers from each of them is
pinned, so neither list can drift away from the other and neither can shrink to
covering nothing.
"""

import ast
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

# The issue approval service's own owning sources
# (docs/agent-workflow-contract.md §2.8), scanned for the home-relative paths
# they build rather than for the external commands they spawn — those are
# already covered by the discovered tools/ surface below. They need an
# extractor of their own because they are Python: none of them spells a managed
# location as one literal the way the Haskell surface does, and none of them is
# markdown, so neither existing extractor recovers anything from them.
# `tools/service_manager.py` is here because it is where both definition
# directories are built, so scanning only the controller and the installer
# would leave service-written paths outside the gate. An enumerated list rather
# than every module under tools/: extending the home-path gate to another
# module is a deliberate edit, exactly as adding a packaged asset to a plugin
# surface list is.
APPROVAL_SERVICE_SURFACE_FILES = [
    "tools/approve_issues_service.py",
    "tools/install_issue_approval.py",
    "tools/service_manager.py",
]

# What the Python extractor actually recovers from each of the three, pinned
# the way the plugin surfaces' command sets are: the completeness loop below
# reports no undeclared segment for a module the extractor recovers nothing
# from, for the same reason it reports none for a module it never opened. The
# installer's empty set is a pin rather than an omission — it expands whatever
# `--install-dir` or `--config` it is given and builds no managed location of
# its own — so a future edit that made it construct one would have to declare
# it here as well as in the manifest.
APPROVAL_SERVICE_EXPECTED_HOME_SEGMENTS = {
    "tools/approve_issues_service.py": {
        # The service root, and each tree the controller composes from it
        # through a nullary helper: `runtime_root()`, `discovery_record_path()`
        # and the two lock paths are all `service_root() / ...`, so recovering
        # them is what makes those four manifest rows load-bearing rather than
        # decorative.
        "/Library/Application Support/kanban/issue-approval",
        "/Library/Application Support/kanban/issue-approval/config.json",
        "/Library/Application Support/kanban/issue-approval/locks",
        "/Library/Application Support/kanban/issue-approval/runtime",
        "/Library/Logs/kanban/issue-approval",
        # The one home-relative entry of the fixed PATH an installed job runs
        # with.
        "/.local/bin",
    },
    "tools/install_issue_approval.py": set(),
    "tools/service_manager.py": {
        "/Library/LaunchAgents",
        # Both halves of the systemd unit directory: the `~/.config` its local
        # `root` binding reaches when `$XDG_CONFIG_HOME` names no absolute
        # directory, and the whole location that binding is then extended into.
        # The second is the one a declared row has to be held to — an
        # undeclared tail is contained in neither token, which the regression
        # below drives.
        "/.config",
        "/.config/systemd/user",
    },
}

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
    "codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md",
    "codex-plugin/plugins/kanban/skills/repair/SKILL.md",
    "codex-plugin/plugins/kanban/skills/design-epic/SKILL.md",
    "codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md",
    "codex-plugin/plugins/kanban/skills/draft-report/SKILL.md",
    "codex-plugin/plugins/kanban/skills/note-problem/SKILL.md",
    "codex-plugin/plugins/kanban/skills/process-report/SKILL.md",
    "codex-plugin/plugins/kanban/skills/triage/SKILL.md",
    "codex-plugin/plugins/kanban/skills/push-docs/SKILL.md",
    "codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py",
    "codex-plugin/plugins/kanban/skills/solve/scripts/trusted_issue_spec.py",
    "codex-plugin/plugins/kanban/skills/process-report/scripts/publish_coordination_doc.py",
    "codex-plugin/plugins/kanban/skills/process-report/scripts/tracker_transaction.py",
    "codex-plugin/plugins/kanban/skills/process-report/scripts/kanban_config.py",
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
    "claude-plugin/plugins/kanban/commands/issue-rereview.md",
    "claude-plugin/plugins/kanban/commands/repair.md",
    "claude-plugin/plugins/kanban/commands/design-epic.md",
    "claude-plugin/plugins/kanban/commands/process-design-doc.md",
    "claude-plugin/plugins/kanban/commands/draft-report.md",
    "claude-plugin/plugins/kanban/commands/note-problem.md",
    "claude-plugin/plugins/kanban/commands/process-report.md",
    "claude-plugin/plugins/kanban/commands/triage.md",
    "claude-plugin/plugins/kanban/commands/push-docs.md",
    "claude-plugin/plugins/kanban/scripts/review_pr.py",
    "claude-plugin/plugins/kanban/scripts/trusted_issue_spec.py",
    "claude-plugin/plugins/kanban/scripts/publish_coordination_doc.py",
    "claude-plugin/plugins/kanban/scripts/tracker_transaction.py",
    "claude-plugin/plugins/kanban/scripts/kanban_config.py",
]

# Both bundles' vendored trusted-comment issue-spec helper (issue #238). Each is
# a member of its brand's surface list above, so its external commands are
# already reconciled against the manifest; these two are named here so the
# non-vacuity pin below drives the real assets, and so dropping one from a
# surface list fails a test rather than silently un-scanning a vendored asset.
TRUSTED_SPEC_SURFACE_FILES = {
    "codex-plugin/plugins/kanban/skills/solve/scripts/trusted_issue_spec.py": {"gh"},
    "claude-plugin/plugins/kanban/scripts/trusted_issue_spec.py": {"gh"},
}

# Issue #370's vendored document mechanism, covered exactly the way the
# trusted-comment helper above is. Each bundle carries a byte-identical copy of
# the three tools/ modules the document workflows invoke, so each copy's own
# external commands are reconciled against the manifest rather than inheriting
# the tracked original's row. The configuration reader spawns nothing at all,
# which is a pin rather than an omission: a future edit that made it shell out
# would have to declare that here.
DOCUMENT_MECHANISM_SURFACE_FILES = {
    "codex-plugin/plugins/kanban/skills/process-report/scripts/publish_coordination_doc.py": {"git"},
    "codex-plugin/plugins/kanban/skills/process-report/scripts/tracker_transaction.py": {"git"},
    "codex-plugin/plugins/kanban/skills/process-report/scripts/kanban_config.py": set(),
    "claude-plugin/plugins/kanban/scripts/publish_coordination_doc.py": {"git"},
    "claude-plugin/plugins/kanban/scripts/tracker_transaction.py": {"git"},
    "claude-plugin/plugins/kanban/scripts/kanban_config.py": set(),
}

# The seven drafting and canonical issue-review assets vendored by issue #118,
# plus the two issue-rereview repair assets vendored by issue #240. All nine
# are scanned for external commands via the lists above — the bash
# fence extractor simply returns an empty set for an asset with no ```bash
# fence, so a prose-only contract is covered rather than exempted — and all
# nine are scanned here for user-scoped paths. Scoped to these assets
# deliberately: the pre-existing packaged workflows build home-relative paths
# (worktrees roots) that predate this check and are not part of this contract's
# surface. $issue-rereview's own $CODEX_HOME lookup does not get that
# grandfathering: it is a declared asset, so its cache root is declared too.
DRAFTING_SURFACE_FILES = [
    "claude-plugin/plugins/kanban/commands/issue.md",
    "claude-plugin/plugins/kanban/commands/draft-issues.md",
    "claude-plugin/plugins/kanban/commands/autoissue.md",
    "claude-plugin/plugins/kanban/commands/issue-review.md",
    "claude-plugin/plugins/kanban/commands/issue-rereview.md",
    "codex-plugin/plugins/kanban/skills/issue/SKILL.md",
    "codex-plugin/plugins/kanban/skills/autoissue/SKILL.md",
    "codex-plugin/plugins/kanban/skills/issue-review/SKILL.md",
    "codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md",
]

# What the two issue-rereview assets' bash fences actually invoke, pinned the
# way DOCUMENT_SURFACE_EXPECTED_COMMANDS pins the document workflows': the
# completeness loop below passes trivially against an asset the extractor
# recovers nothing from. Both resolve the backend and the repository root; the
# Codex skill additionally locates its bundle's vendored trusted-comment helper
# with find/head, which the Claude command reaches through
# ${CLAUDE_PLUGIN_ROOT}.
REREVIEW_SURFACE_EXPECTED_COMMANDS = {
    "claude-plugin/plugins/kanban/commands/issue-rereview.md": {"python3", "git"},
    "codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md": {
        "python3",
        "git",
        "find",
        "head",
    },
}

# Issue #410's documentation-landing pair, pinned the same way. Both brands'
# fences resolve the repository root with `git` and then invoke the worked
# repository's own tools/docs_land.sh by path — a repository tool rather than
# an external command, which is why nothing further is discovered. The Codex
# skill needs no find/head lookup because the helper ships with the
# repository being worked, not with the bundle.
PUSH_DOCS_SURFACE_EXPECTED_COMMANDS = {
    "claude-plugin/plugins/kanban/commands/push-docs.md": {"git"},
    "codex-plugin/plugins/kanban/skills/push-docs/SKILL.md": {"git"},
}

# The ten design and report document-workflow assets declared in
# docs/document-workflow-contract.md §2 — the five vendored by issue #229, the
# Claude design pair issue #241 transposed from the tracked Codex skills, and
# the report write side issue #328 completed with /draft-report and both
# note-problem variants — covered exactly the way the drafting
# assets above are: all ten are members of the two plugin surface lists, so
# their bash fences are already scanned for external commands, and all ten are
# scanned here for user-scoped paths. They name none today — which is why the
# assertion below pins what the extractor actually recovers from them, rather
# than only asserting that nothing undeclared was found.
DOCUMENT_SURFACE_FILES = [
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
]

# What each document-workflow asset's bash fences actually invoke. Since issue
# #278 every one of the seven resolves its owning repository with `git` and `gh`
# before any write, and resolves the docs worktree beneath it with
# `git -C "$DOC_ROOT" worktree list | awk ...`; the processing workflows
# additionally list and search issues with `gh`, and the Claude process-report
# lists finding headings with `rg` inside a fence rather than in prose. `gh`
# is therefore on all seven, where before the ownership step it was on the
# processing assets alone. The Claude design pair inherits exactly the Codex
# sources' fences, so it inherits their command sets too. Pinned so a rewrite
# that stops invoking anything cannot leave the completeness check with nothing
# to discover.
# The four processing assets invoke `python3` and the four drafting assets do
# not: issue #315 moved the publication mechanism into
# tools/publish_coordination_doc.py, which the processing assets call and the
# drafting assets have no reason to, since they publish nothing. Issue #328
# added a third shape: both note-problem variants invoke `python3` without ever
# reaching tools/tracker_transaction.py, because they publish an appended
# observation to an existing report while mutating no tracker.
# Issue #370 added `find` and `head` to all three Codex document skills. Their
# helpers ship with the bundle rather than with the repository being worked, and
# Codex has no ${CLAUDE_PLUGIN_ROOT} substitution, so each skill locates its
# bundle's installed copy under $CODEX_HOME exactly as the PR-flow skills locate
# review_pr.py. The Claude commands reach the same copies through the
# substitution and so still invoke neither.
DOCUMENT_SURFACE_EXPECTED_COMMANDS = {
    "claude-plugin/plugins/kanban/commands/design-epic.md": {"git", "awk", "gh"},
    "claude-plugin/plugins/kanban/commands/process-design-doc.md": {
        "git", "awk", "gh", "python3",
    },
    "claude-plugin/plugins/kanban/commands/draft-report.md": {"git", "awk", "gh"},
    "claude-plugin/plugins/kanban/commands/note-problem.md": {
        "git", "awk", "gh", "python3",
    },
    "claude-plugin/plugins/kanban/commands/process-report.md": {
        "git", "awk", "gh", "rg", "python3",
    },
    "codex-plugin/plugins/kanban/skills/design-epic/SKILL.md": {"git", "awk", "gh"},
    "codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md": {
        "git", "awk", "gh", "python3", "find", "head",
    },
    "codex-plugin/plugins/kanban/skills/draft-report/SKILL.md": {"git", "awk", "gh"},
    "codex-plugin/plugins/kanban/skills/note-problem/SKILL.md": {
        "git", "awk", "gh", "python3", "find", "head",
    },
    "codex-plugin/plugins/kanban/skills/process-report/SKILL.md": {
        "git", "awk", "gh", "python3", "find", "head",
    },
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

# The repository's shell helpers (issue #410): tools/ modules that are shell
# scripts rather than Python, so the discovered .py walk above never scans
# them. Enumerated like the plugin surfaces, with what the extractor recovers
# from each pinned below so the scan cannot silently shrink to nothing.
TOOL_SHELL_SURFACE_FILES = [
    "tools/docs_land.sh",
]

TOOL_SHELL_SURFACE_EXPECTED_COMMANDS = {
    "tools/docs_land.sh": {
        "awk", "dirname", "git", "grep", "mktemp", "python3", "sed", "tr",
    },
}

# Shell reserved words and builtins are not external dependencies; every
# other recovered name must carry an `executable` manifest row.
SHELL_RESERVED_AND_BUILTINS = {
    "if", "then", "else", "elif", "fi", "case", "esac", "for", "while",
    "until", "do", "done", "in", "break", "continue", "return", "exit",
    "shift", "trap", "set", "cd", "echo", "printf", "read", "local", "exec",
    "eval", "true", "false", "wait", "export", "unset",
}

# A shell function defined in the script itself, whose invocations are not
# external commands.
SHELL_FUNCTION_DEF_RE = re.compile(
    r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{", re.MULTILINE
)

# Heredoc bodies in a raw script are input, not commands — including the
# unquoted-delimiter form the markdown extractor deliberately ignores,
# because packaged assets never use it while this script does.
SHELL_HEREDOC_BODY_RE = re.compile(
    r"(<<-?\s*(?P<quote>['\"]?)(?P<tag>[A-Za-z_][A-Za-z0-9_]*)(?P=quote)[^\n]*\n)"
    r".*?^[ \t]*(?P=tag)[ \t]*$\n?",
    re.DOTALL | re.MULTILINE,
)

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


# A home-anchored path a Python module builds — the counterpart of
# HOME_PATH_EXPR_RE above for the surface that composes one from `pathlib`
# segments instead of spelling it as a single literal.
#
# Resolved from the parsed module rather than by regex, because the shape that
# has to be recovered is not local to one expression. `tools/service_manager.py`
# writes the systemd unit directory as `root / "systemd" / "user"`, where `root`
# is bound a line earlier and only that binding reaches a home root; a pattern
# that could see only the binding would recover `~/.config` and let an
# undeclared tail past, which is precisely the hole a declared row exists to
# close. `tools/approve_issues_service.py` composes the same way through
# nullary helpers — `runtime_root()` is `service_root() / "runtime"` — so the
# resolution has to follow a name to whatever it was bound to, an assignment or
# a function's own return, before any of these locations is recovered at all.
#
# Working from the syntax tree also settles a family of spellings by
# construction rather than one alternative at a time: quote style, line
# wrapping, and the parentheses around `Path(os.environ["HOME"])` are simply
# not distinctions the tree makes.

# What denotes this account's home directory. `account_home()` is the approval
# controller's passwd-anchored root; `Path.home()`, a `HOME` name, and an
# `os.environ` read of one are the same statement written differently, and a
# gate a second spelling walks through is not a gate.
PYTHON_HOME_ROOT_FUNCTIONS = frozenset({"account_home"})
PYTHON_HOME_NAMES = frozenset({"HOME"})
PYTHON_HOME_ENVIRONMENT_KEYS = frozenset({"HOME"})
# Calls that pass a path through unchanged, so the receiver decides.
PYTHON_PATH_PASSTHROUGH_ATTRIBUTES = frozenset(
    {"expanduser", "resolve", "absolute"}
)
# How a whole home-relative path is written as one literal, for a module that
# hands it to `expanduser` or to a shell instead of composing it.
PYTHON_HOME_LITERAL_PREFIXES = ("~", "$HOME")
# A bound name resolving through others cannot recurse forever, but a module
# may legitimately bind one name from another; this bounds the walk rather
# than describing any real depth.
PYTHON_RESOLUTION_DEPTH = 12


class _PythonHomePaths:
    """Every home-relative location one parsed module builds.

    Two passes over one tree: collect what each module-level or local name and
    each nullary function is bound to, then resolve every `/`-chain against
    those bindings. A name is kept as a list of candidate values rather than
    one, because a rebound name whose *later* binding is the home-rooted one
    must still resolve — missing a location is the failure direction that
    matters here, and a spurious extra one only ever asks for a row.
    """

    def __init__(self, tree):
        self.bindings = {}
        self.returns = {}
        self._resolving = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Assign):
                for target in node.targets:
                    if isinstance(target, ast.Name):
                        self.bindings.setdefault(target.id, []).append(node.value)
            elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
                if node.value is not None:
                    self.bindings.setdefault(node.target.id, []).append(node.value)
            elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                for statement in ast.walk(node):
                    if isinstance(statement, ast.Return) and statement.value is not None:
                        self.returns.setdefault(node.name, []).append(statement.value)

    # -- resolution --------------------------------------------------------

    def resolve(self, node, depth=0):
        """The home-relative prefix `node` denotes, or None.

        `""` is the home directory itself and is deliberately distinct from
        None: it is what makes `account_home() / "Library"` resolve while
        `some_path / "Library"` does not.
        """
        if depth > PYTHON_RESOLUTION_DEPTH:
            return None
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
            left = self.resolve(node.left, depth + 1)
            if left is None:
                return None
            if isinstance(node.right, ast.Constant) and isinstance(node.right.value, str):
                part = node.right.value.strip("/")
                return f"{left}/{part}" if part else left
            # A computed segment ends the literal chain: what follows is not a
            # location this manifest could name.
            return None
        if isinstance(node, ast.Call):
            return self._resolve_call(node, depth)
        if isinstance(node, ast.Subscript):
            if self._is_environment(node.value) and self._is_home_key(node.slice):
                return ""
            return None
        if isinstance(node, ast.Name):
            return self._resolve_name(node.id, depth)
        if isinstance(node, ast.IfExp):
            # Either branch may be the home-rooted one; `service_manager`'s
            # unit directory is the `else` of an `$XDG_CONFIG_HOME` test.
            for branch in (node.body, node.orelse):
                resolved = self.resolve(branch, depth + 1)
                if resolved is not None:
                    return resolved
            return None
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return self._resolve_literal(node.value)
        return None

    def _resolve_call(self, node, depth):
        function = node.func
        if isinstance(function, ast.Name):
            if function.id in PYTHON_HOME_ROOT_FUNCTIONS:
                return ""
            if function.id == "Path" and node.args:
                return self.resolve(node.args[0], depth + 1)
            return self._resolve_returns(function.id, depth)
        if isinstance(function, ast.Attribute):
            if function.attr == "home" and isinstance(function.value, ast.Name):
                if function.value.id == "Path":
                    return ""
                return None
            if function.attr in PYTHON_PATH_PASSTHROUGH_ATTRIBUTES:
                return self.resolve(function.value, depth + 1)
            if (
                function.attr == "get"
                and self._is_environment(function.value)
                and node.args
                and self._is_home_key(node.args[0])
            ):
                return ""
        return None

    def _resolve_name(self, name, depth):
        if name in PYTHON_HOME_NAMES:
            # A bound `HOME` resolves through its binding; an unbound one is
            # read as the home directory anyway, since that is the only thing
            # a name spelled this way means on this surface.
            return self._resolve_bindings(name, depth) or ""
        return self._resolve_bindings(name, depth)

    def _resolve_bindings(self, name, depth):
        return self._resolve_candidates(("binding", name), self.bindings.get(name), depth)

    def _resolve_returns(self, name, depth):
        return self._resolve_candidates(("return", name), self.returns.get(name), depth)

    def _resolve_candidates(self, key, candidates, depth):
        if not candidates or key in self._resolving:
            return None
        self._resolving.add(key)
        try:
            for candidate in candidates:
                resolved = self.resolve(candidate, depth + 1)
                if resolved is not None:
                    return resolved
        finally:
            self._resolving.discard(key)
        return None

    @staticmethod
    def _resolve_literal(text):
        for prefix in PYTHON_HOME_LITERAL_PREFIXES:
            if text.startswith(prefix + "/"):
                return text[len(prefix) :].rstrip("/")
        return None

    @staticmethod
    def _is_environment(node):
        return (
            isinstance(node, ast.Attribute)
            and node.attr == "environ"
            and isinstance(node.value, ast.Name)
            and node.value.id == "os"
        )

    @staticmethod
    def _is_home_key(node):
        return (
            isinstance(node, ast.Constant)
            and isinstance(node.value, str)
            and node.value in PYTHON_HOME_ENVIRONMENT_KEYS
        )

    # -- collection --------------------------------------------------------

    def collect(self, node, found):
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
            resolved = self.resolve(node)
            if resolved:
                found.add(resolved)
                # Not the left spine: that is this chain's own prefix, and
                # recording it would report every intermediate directory as a
                # location of its own. Anything nested on the right is still
                # reached.
                self.collect(node.right, found)
                return
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            literal = self._resolve_literal(node.value)
            if literal:
                found.add(literal)
            return
        for child in ast.iter_child_nodes(node):
            self.collect(child, found)


def python_home_relative_segments(content):
    """Every home-relative path a tools/ module builds.

    Returned in the same slash-prefixed form the Haskell and markdown
    extractors produce, so all three reconcile against one `personal-path`
    token set rather than against three spellings of it.

    Raises `SyntaxError` for a module that will not parse. That is deliberate:
    answering "nothing here" for a file this check could not read is exactly
    how a completeness gate stops checking, so the caller turns it into a
    failure naming the file rather than an empty result.
    """
    tree = ast.parse(content)
    paths = _PythonHomePaths(tree)
    found = set()
    paths.collect(tree, found)
    return found


def home_relative_segments_for_surface_file(relative_path, content):
    """The home-relative paths one surface file builds, by its own extractor.

    Dispatched on extension the way `discovered_commands_for_plugin_file`
    dispatches the command extractors: the two surfaces spell a managed
    location differently, and one reconciliation covers both.
    """
    if relative_path.endswith(".py"):
        return python_home_relative_segments(content)
    return home_relative_segments(content)


def segment_is_declared(segment, personal_tokens, *, resolved_surface):
    """Whether one `personal-path` row covers this discovered segment.

    Two rules, because the two extractors recover different things.

    A literal one — the Haskell and markdown surfaces — is whatever the source
    happened to write down, which is routinely a file *inside* a declared
    directory (`~/Library/Application Support/kanban/issue-review/config.json`
    against the install-directory row). So containment holds in both
    directions there, and has since that check existed.

    A resolved one is a maximal chain: the extractor already walked to the end
    of every `/`-application, so each segment it yields is a location in its
    own right rather than something inside one. Absorbing it into an ancestor's
    row would make every row below a declared directory decorative — renaming
    `runtime/` to anything at all would still be covered by the service root.
    So an exact row is required, with one direction of containment kept: a
    segment a *longer* declared location is built through — the `~/.config`
    half of the systemd unit directory — is covered by that location's row,
    since the complete location still has to match on its own.
    """
    if segment in personal_tokens:
        return True
    if resolved_surface:
        return any(
            token.startswith(segment + "/") for token in personal_tokens
        )
    return any(
        segment in token or token in segment for token in personal_tokens
    )


def undeclared_home_segments(relative_path, content, personal_tokens):
    """Every home-relative path `content` builds that no manifest row declares.

    The one reconciliation both the tracked-tree check and its fixture
    regressions drive, so what the regressions prove is what the tree is held
    to rather than a second implementation of it.

    A file that cannot be read at all is reported rather than passed over: an
    extractor that answers "no undeclared paths" for a module it never parsed
    is a gate that has silently stopped gating.
    """
    try:
        segments = home_relative_segments_for_surface_file(relative_path, content)
    except SyntaxError as error:
        raise AssertionError(
            f"{relative_path} could not be parsed, so the home-relative paths "
            f"it builds could not be checked: {error}"
        ) from error
    resolved_surface = relative_path.endswith(".py")
    return sorted(
        segment
        for segment in segments
        if looks_like_path_segment(segment)
        and not segment_is_declared(
            segment, personal_tokens, resolved_surface=resolved_surface
        )
    )


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


# run(["gh", ...]) / subprocess.run(["git", ...]) / run_json(["gh", ...]) /
# run(\n    [\n        "codex", — a vendored Python asset's own
# external-command invocation surface. `\s` matches newlines without needing
# re.DOTALL, so this covers both the single-line and the multi-line
# list-literal call styles review_pr.py uses.
#
# The callee is matched as a family, exactly the way TOOL_COMMAND_CALL_RE below
# matches the tools/ surface, rather than as the two literal spellings
# review_pr.py happens to use: trusted_issue_spec.py spawns `gh` through its own
# run_json wrapper, and a check that only recognized `run(`/`subprocess.run(`
# would have discovered nothing there and passed vacuously. Both quote styles are
# accepted for the same reason — a gate a single-quoted literal walks through is
# not a gate.
PYTHON_COMMAND_CALL_RE = re.compile(
    r'\b(?:[A-Za-z_][A-Za-z0-9_]*\.)?'
    r'(?:[a-z_]*run[a-z_0-9]*|Popen|check_call|check_output|call)'
    r'\(\s*\[\s*(?P<quote>["\'])(?P<name>[^"\']+)(?P=quote)'
)


def discovered_python_commands(content):
    """Every external command a packaged Python asset's own source invokes as
    the first element of a literal `run`-family argument list. Deliberately does
    not match a dynamically-resolved first argument like `sys.executable` (no
    leading string literal there) — that path is python3, already covered via
    the SKILL.md bash surface that invokes this script with `python3 ...`."""
    return {match.group("name") for match in PYTHON_COMMAND_CALL_RE.finditer(content)}


def discovered_commands_for_plugin_file(relative_path, content):
    if relative_path.endswith(".py"):
        return discovered_python_commands(content)
    return discovered_plugin_commands(content)


# run(["git", ...]) / subprocess.run(["gh", ...]) / run_command(["launchctl",
# ...]) / run_json(["gh", ...]) / subprocess.Popen(["...", ...]) — the
# repository tools' own external-command surface. These modules spawn through
# their own thin wrappers at least as often as through subprocess directly,
# and each module names its wrappers differently: every launchctl call in
# tools/service_manager.py goes through the runner its caller injected, while
# approve_issues.py and drain_prs.py add run_json on top of run. So the callee is matched as a
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


# The one module allowed to speak a service manager, and every way of speaking
# one that must therefore appear nowhere else on the tools/ surface. Issue #291
# pulled this boundary out of the controller and the installer so a second
# service manager could be added without rewriting either, and issue #329 added
# that second one; a `launchctl` or `systemctl` call, a plist or unit file read
# or written, or a hand-built target that drifted back outside it would make
# that boundary a comment rather than a fact.
#
# Every artifact is checked, not just the command names: `plistlib.dumps`, an
# f-string starting `gui/`, or a `[Service]` section rendered outside the
# backend is service-manager knowledge in exactly the same way, and a check
# that only caught the two command tokens would pass over all of them. Each
# manager's target is what every address is built from — `gui/<uid>` then
# `<domain>/<label>`, and `user@<uid>.service` then `<manager>/<unit>` — so
# forbidding the address literals forbids the targets built on them too.
LAUNCHD_BACKEND_PATH = "tools/service_manager.py"
SERVICE_MANAGER_BACKEND_PATH = LAUNCHD_BACKEND_PATH
LAUNCHD_ARTIFACTS = (
    ("a launchctl invocation", re.compile(r"\blaunchctl\b")),
    ("a plist read or written", re.compile(r"\bplistlib\b")),
    ("a launchd domain", re.compile(r"""["']gui/""")),
)
SYSTEMD_ARTIFACTS = (
    ("a systemctl invocation", re.compile(r"\bsystemctl\b")),
    ("a systemd unit section", re.compile(r"""["']\[(?:Unit|Service|Install)\]""")),
    ("a systemd user-manager target", re.compile(r"""["']user@""")),
)
SERVICE_MANAGER_ARTIFACTS = LAUNCHD_ARTIFACTS + SYSTEMD_ARTIFACTS


def discovered_shell_script_commands(content):
    """Every external command a raw tools/ shell script invokes, recognized
    with the same leading-word and subshell/pipe machinery as the packaged
    workflows' bash fences, after dropping comment lines, heredoc bodies,
    reserved words and builtins, and the script's own function names."""
    body = SHELL_HEREDOC_BODY_RE.sub(lambda match: match.group(1), content)
    lines = [
        line for line in body.splitlines()
        if not line.lstrip().startswith("#")
    ]
    scannable = "\n".join(lines)
    names = {
        match.group(1)
        for match in SUBSHELL_OR_PIPE_COMMAND_RE.finditer(scannable)
    }
    for line in lines:
        stripped = line.strip()
        if not stripped or ASSIGNMENT_RE.match(stripped):
            continue
        leading = LEADING_COMMAND_RE.match(stripped)
        if leading:
            names.add(leading.group(1))
    return (
        names
        - SHELL_RESERVED_AND_BUILTINS
        - set(SHELL_FUNCTION_DEF_RE.findall(content))
    )


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

    def test_both_trusted_issue_spec_helpers_are_scanned_and_declared(self):
        # Issue #238's review requirement: the two vendored helpers must reach a
        # surface list (an unlisted vendored asset is never scanned at all), and
        # what the extractor recovers from each is pinned so a helper whose `gh`
        # call the regex stops matching fails here rather than passing with an
        # empty discovered set.
        executable_tokens = {
            row["token"] for row in self.manifest if row["kind"] == "executable"
        }
        for relative_path, expected in sorted(TRUSTED_SPEC_SURFACE_FILES.items()):
            self.assertTrue(
                relative_path in PLUGIN_SURFACE_FILES
                or relative_path in CLAUDE_PLUGIN_SURFACE_FILES,
                f"{relative_path} is not scanned by either plugin surface list",
            )
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            found = discovered_commands_for_plugin_file(relative_path, content)
            self.assertEqual(found, expected, relative_path)
            for name in found:
                self.assertIn(
                    name,
                    executable_tokens,
                    undocumented_command_message(relative_path, name),
                )

    def test_the_vendored_document_mechanism_is_scanned_and_declared(self):
        # Issue #370's counterpart of the trusted-spec pin above. Each bundle's
        # copy of the mechanism is a member of its brand's surface list, so its
        # commands are already reconciled; what this adds is that dropping one
        # from a list fails a test rather than silently un-scanning a vendored
        # asset, and that the extractor really recovers something from the two
        # modules that spawn anything.
        executable_tokens = {
            row["token"] for row in self.manifest if row["kind"] == "executable"
        }
        for relative_path, expected in sorted(DOCUMENT_MECHANISM_SURFACE_FILES.items()):
            self.assertTrue(
                relative_path in PLUGIN_SURFACE_FILES
                or relative_path in CLAUDE_PLUGIN_SURFACE_FILES,
                f"{relative_path} is not scanned by either plugin surface list",
            )
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            found = discovered_commands_for_plugin_file(relative_path, content)
            self.assertEqual(found, expected, relative_path)
            for name in found:
                self.assertIn(
                    name,
                    executable_tokens,
                    undocumented_command_message(relative_path, name),
                )

    def test_python_command_discovery_matches_a_wrapper_named_call_site(self):
        # The extractor must recognize a run-family wrapper, not only the two
        # spellings review_pr.py uses: the trusted-comment helper spawns gh
        # through run_json, and the pre-#238 regex found nothing in it.
        snippet = (
            'def run_json(args):\n'
            '    return subprocess.run(args, text=True)\n'
            'run_json(["gh", "api", "repos/o/r/issues/1/comments"])\n'
            "subprocess.run(['git', 'status'])\n"
        )
        self.assertEqual(discovered_python_commands(snippet), {"gh", "git"})

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
        # Two surfaces, one reconciliation. The Haskell modules spell a managed
        # location as one literal and the three approval-service modules
        # compose one from path segments, so each gets its own extractor and
        # both answer to the same `personal-path` rows.
        personal_tokens = [
            row["token"]
            for row in self.manifest
            if row["kind"] == "personal-path"
        ]
        for relative_path in SURFACE_FILES + APPROVAL_SERVICE_SURFACE_FILES:
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            undeclared = undeclared_home_segments(
                relative_path, content, personal_tokens
            )
            self.assertEqual(
                [],
                undeclared,
                f"{relative_path} builds undocumented home-relative path "
                f"segment(s) {undeclared}; declare each one in the manifest "
                "in docs/agent-workflow-contract.md",
            )

    def test_approval_service_home_path_discovery_is_not_vacuous(self):
        # The three modules reach the loop above by being listed, and a loop
        # over a module the extractor recovers nothing from reports no
        # undeclared segment for the same reason a loop over nothing does. Pin
        # what each one actually builds so a refactor that stops matching —
        # or a surface list that loses a member — fails here.
        for relative_path in APPROVAL_SERVICE_SURFACE_FILES:
            with self.subTest(surface=relative_path):
                content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
                self.assertEqual(
                    home_relative_segments_for_surface_file(relative_path, content),
                    APPROVAL_SERVICE_EXPECTED_HOME_SEGMENTS[relative_path],
                )
        self.assertEqual(
            sorted(APPROVAL_SERVICE_EXPECTED_HOME_SEGMENTS),
            sorted(APPROVAL_SERVICE_SURFACE_FILES),
            "every scanned approval-service module needs a pinned expectation",
        )

    def test_an_undeclared_python_home_path_is_reported(self):
        # The negative control the pin above cannot be: it proves the scan
        # *fails* on a segment no row declares. Every way of reaching a home
        # root the extractor claims to cover is exercised, because a gate a
        # second spelling walks through is not a gate.
        personal_tokens = [
            row["token"]
            for row in self.manifest
            if row["kind"] == "personal-path"
        ]
        for label, snippet, expected in (
            (
                "segment chain",
                'def root():\n'
                '    return account_home() / "Library" / "Application Support" '
                '/ "kanban" / "undeclared-service"\n',
                ["/Library/Application Support/kanban/undeclared-service"],
            ),
            (
                "single quotes",
                "ROOT = Path.home() / 'Library' / 'Undeclared Place'\n",
                ["/Library/Undeclared Place"],
            ),
            (
                "environment root",
                'ROOT = Path(os.environ["HOME"]) / "Library" / "Undeclared Place"\n',
                ["/Library/Undeclared Place"],
            ),
            (
                "environment get",
                'ROOT = Path(os.environ.get("HOME")) / "Library" / "Undeclared Place"\n',
                ["/Library/Undeclared Place"],
            ),
            (
                "expanded literal",
                'ROOT = Path("~/Library/Undeclared Place").expanduser()\n',
                ["/Library/Undeclared Place"],
            ),
            (
                "wrapped across lines",
                'ROOT = (\n'
                '    account_home()\n'
                '    / "Library"\n'
                '    / "Undeclared Place"\n'
                ')\n',
                ["/Library/Undeclared Place"],
            ),
            # The two shapes Codex's round-1 review named: a tail hung off a
            # name bound elsewhere, and one hung off a nullary helper. Both are
            # how the tracked modules actually spell the locations these rows
            # declare — `tools/service_manager.py`'s unit directory and
            # `tools/approve_issues_service.py`'s runtime tree — so an
            # extractor that stopped at the binding would leave the tail
            # undeclarable and the row decorative.
            (
                "tail on a bound name",
                'HOME = Path.home()\n'
                'root = HOME / ".config"\n'
                'UNIT_DIR = root / "systemd" / "undeclared"\n',
                ["/.config/systemd/undeclared"],
            ),
            (
                "tail through the conditional binding service_manager uses",
                'HOME = Path.home()\n'
                'def _unit_dir():\n'
                '    configured = os.environ.get("XDG_CONFIG_HOME", "")\n'
                '    root = Path(configured) if configured else HOME / ".config"\n'
                '    return root / "systemd" / "undeclared"\n',
                ["/.config/systemd/undeclared"],
            ),
            (
                "tail on a nullary helper",
                'def service_root():\n'
                '    return account_home() / "Library" / "Undeclared Root"\n'
                'def runtime_root():\n'
                '    return service_root() / "runtime"\n',
                [
                    "/Library/Undeclared Root",
                    "/Library/Undeclared Root/runtime",
                ],
            ),
        ):
            with self.subTest(shape=label):
                self.assertEqual(
                    undeclared_home_segments(
                        "tools/approve_issues_service.py", snippet, personal_tokens
                    ),
                    expected,
                )
        # ...and that a declared one is not reported, so the check above is
        # discriminating rather than merely noisy.
        self.assertEqual(
            undeclared_home_segments(
                "tools/approve_issues_service.py",
                'def service_root():\n'
                '    return account_home() / "Library" / "Application Support" '
                '/ "kanban" / "issue-approval"\n'
                'def runtime_root():\n'
                '    return service_root() / "runtime"\n',
                personal_tokens,
            ),
            [],
        )

    def test_a_location_beneath_a_declared_root_is_not_absorbed_by_it(self):
        # What makes the four rows *under* the service root load-bearing
        # rather than decorative. Every one of those locations is composed
        # through its own nullary helper, so the extractor yields it whole;
        # if an ancestor's row covered it, renaming `runtime/` to anything at
        # all would still pass while the row went on naming a directory that
        # no longer exists.
        personal_tokens = [
            row["token"]
            for row in self.manifest
            if row["kind"] == "personal-path"
        ]
        declared_root = "/Library/Application Support/kanban/issue-approval"
        self.assertIn(declared_root, personal_tokens)
        for renamed in ("undeclared-runtime", "undeclared-locks", "other.json"):
            with self.subTest(renamed=renamed):
                self.assertEqual(
                    undeclared_home_segments(
                        "tools/approve_issues_service.py",
                        'def service_root():\n'
                        '    return account_home() / "Library" '
                        '/ "Application Support" / "kanban" / "issue-approval"\n'
                        'def moved():\n'
                        f'    return service_root() / "{renamed}"\n',
                        personal_tokens,
                    ),
                    [f"{declared_root}/{renamed}"],
                )
        # The literal surfaces keep the older, looser rule, which is
        # load-bearing there for the opposite reason: what those extractors
        # recover is whatever the source wrote, routinely a file inside a
        # declared directory.
        self.assertTrue(
            segment_is_declared(
                f"{declared_root}/anything", personal_tokens, resolved_surface=False
            )
        )
        self.assertFalse(
            segment_is_declared(
                f"{declared_root}/anything", personal_tokens, resolved_surface=True
            )
        )

    def test_an_unparseable_scanned_module_is_reported(self):
        # The other way a completeness check stops checking: answering
        # "nothing undeclared here" for a file it could not read at all. The
        # extractor raises and the reconciliation turns that into a failure
        # naming the file, rather than an empty result.
        with self.assertRaises(AssertionError) as raised:
            undeclared_home_segments(
                "tools/approve_issues_service.py", "def broken(:\n", []
            )
        self.assertIn("could not be parsed", str(raised.exception))
        self.assertIn("tools/approve_issues_service.py", str(raised.exception))

    def test_every_drafting_asset_bash_command_is_documented(self):
        # Requirement 8 of issue #118, extended by issue #240: the check must
        # scan all nine vendored drafting, issue-review, and issue-rereview
        # assets. They are already members of the two plugin surface lists
        # above; this pins the nine explicitly so a future edit to those lists
        # cannot silently drop one.
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

    def test_rereview_asset_command_discovery_is_not_vacuous(self):
        # Issue #240's assets reach the completeness loops above by being
        # listed, and a loop over an asset the extractor recovers nothing from
        # reports no undocumented command for the same reason a loop over
        # nothing does. Pin what each one actually invokes so a rewrite that
        # drops the backend call or the helper lookup fails here.
        executable_tokens = {
            row["token"] for row in self.manifest if row["kind"] == "executable"
        }
        for relative_path, expected in sorted(REREVIEW_SURFACE_EXPECTED_COMMANDS.items()):
            self.assertIn(relative_path, DRAFTING_SURFACE_FILES)
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            found = discovered_commands_for_plugin_file(relative_path, content)
            self.assertEqual(found, expected, relative_path)
            for name in found:
                self.assertIn(
                    name,
                    executable_tokens,
                    undocumented_command_message(relative_path, name),
                )

    def test_every_tool_shell_script_command_is_documented(self):
        # The tools/ walk above scans Python modules only, so a shell helper
        # reaches the reconciliation solely by being enumerated — and what
        # the extractor recovers from each is pinned, so the scan cannot
        # pass by discovering nothing.
        executable_tokens = {
            row["token"] for row in self.manifest if row["kind"] == "executable"
        }
        for relative_path in TOOL_SHELL_SURFACE_FILES:
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            found = discovered_shell_script_commands(content)
            self.assertEqual(
                found,
                TOOL_SHELL_SURFACE_EXPECTED_COMMANDS[relative_path],
                relative_path,
            )
            for name in sorted(found):
                self.assertIn(
                    name,
                    executable_tokens,
                    undocumented_command_message(relative_path, name),
                )

    def test_push_docs_asset_command_discovery_is_not_vacuous(self):
        # The two documentation-landing assets reach the completeness loops
        # above by being listed, and a loop over an asset the extractor
        # recovers nothing from reports no undocumented command for the same
        # reason a loop over nothing does. Pin what each actually invokes so
        # a rewrite that stops resolving the repository root fails here.
        executable_tokens = {
            row["token"] for row in self.manifest if row["kind"] == "executable"
        }
        for relative_path, expected in sorted(
            PUSH_DOCS_SURFACE_EXPECTED_COMMANDS.items()
        ):
            self.assertTrue(
                relative_path in PLUGIN_SURFACE_FILES
                or relative_path in CLAUDE_PLUGIN_SURFACE_FILES,
                f"{relative_path} is not scanned by either plugin surface list",
            )
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            found = discovered_commands_for_plugin_file(relative_path, content)
            self.assertEqual(found, expected, relative_path)
            for name in found:
                self.assertIn(
                    name,
                    executable_tokens,
                    undocumented_command_message(relative_path, name),
                )

    def test_the_codex_plugin_cache_root_is_declared_for_the_rereview_skill(self):
        # The Codex rereview skill is the first declared drafting asset to
        # resolve anything under $CODEX_HOME, so its cache root needs a
        # personal-path row rather than the grandfathering the pre-existing
        # packaged workflows get by being outside DRAFTING_SURFACE_FILES.
        by_id = {row["id"]: row for row in self.manifest}
        self.assertIn("codex-plugin-cache-root", by_id)
        entry = by_id["codex-plugin-cache-root"]
        self.assertEqual(entry["kind"], "personal-path")
        # Codex owns $CODEX_HOME; Kanban consumes it and never creates it.
        self.assertEqual(entry["owner"], "external")
        self.assertEqual(entry["mandatory"], "no")
        self.assertIn(
            "codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md",
            entry["files"],
        )
        # Load-bearing rather than decorative: without the row, the skill's own
        # segment is undeclared.
        skill = (
            REPO_ROOT / "codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md"
        ).read_text(encoding="utf-8")
        self.assertIn(entry["token"], markdown_home_relative_segments(skill))

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
            "claude-plugin/plugins/kanban/commands/issue-rereview.md",
            "codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md",
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
        self.assertIn("service_manager.py", paths)
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
        # Pins the extractor against the modules that actually spawn these
        # commands rather than a synthetic snippet. tools/service_manager.py is
        # now the only launchctl and systemctl invoker, and it reaches both
        # through the injected `self._run` wrapper — a run-family callee rather
        # than `run(`/`subprocess.run(`, so an extractor keyed to those two
        # spellings finds zero commands here and the completeness check
        # silently has nothing to discover. Its two callers keep git, which is
        # what proves this pin is reading real modules and not a fixture.
        self.assertEqual(
            discovered_tool_commands(
                (REPO_ROOT / SERVICE_MANAGER_BACKEND_PATH).read_text(encoding="utf-8")
            ),
            {"launchctl", "systemctl"},
            SERVICE_MANAGER_BACKEND_PATH,
        )
        for relative_path in ("tools/drain_prs_service.py", "tools/install_drainer.py"):
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            self.assertEqual(discovered_tool_commands(content), {"git"}, relative_path)
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
        # six, and only launchctl was missing before issue #149 — systemctl
        # joined it with the systemd backend in issue #329.
        found = set()
        for path in tool_surface_files():
            found |= discovered_tool_commands(path.read_text(encoding="utf-8"))
        self.assertEqual(
            found, {"gh", "git", "codex", "claude", "launchctl", "systemctl"}
        )

    def test_each_service_manager_cli_is_declared_and_load_bearing(self):
        by_id = {row["id"]: row for row in self.manifest}
        for row_id, token in (("launchctl-cli", "launchctl"), ("systemctl-cli", "systemctl")):
            with self.subTest(token=token):
                self.assertIn(row_id, by_id)
                entry = by_id[row_id]
                self.assertEqual(entry["kind"], "executable")
                self.assertEqual(entry["token"], token)
                self.assertEqual(entry["files"], [SERVICE_MANAGER_BACKEND_PATH])
                # mandatory: no, matching §2.6 — the drainer is an optional
                # component, and each manager is needed only on its own host.
                self.assertEqual(entry["mandatory"], "no")
                # And each row is load-bearing rather than decorative: drop it
                # while the invocations remain and the invoking module is
                # reported.
                without = {
                    row["token"]
                    for row in self.manifest
                    if row["kind"] == "executable" and row["token"] != token
                }
                self.assertEqual(
                    tool_surface_findings(without),
                    [(SERVICE_MANAGER_BACKEND_PATH, token)],
                )

    def test_service_manager_artifacts_are_confined_to_the_backend(self):
        # Grounded against the tracked tree rather than a fixture, and in both
        # directions: the backend must still contain every artifact, so
        # deleting either implementation cannot make this pass vacuously, and
        # no other module on the scanned surface may contain any of them. The
        # scan is the same discovered surface the manifest check walks, so a
        # tools/ module added later is covered the moment it lands. Both
        # managers are held to one rule — the seam issue #291 drew is only
        # real if the backend issue #329 added lives inside it too.
        backend = (REPO_ROOT / SERVICE_MANAGER_BACKEND_PATH).read_text(encoding="utf-8")
        for description, pattern in SERVICE_MANAGER_ARTIFACTS:
            self.assertRegex(
                backend,
                pattern,
                f"{SERVICE_MANAGER_BACKEND_PATH} no longer contains {description}; "
                "the service-manager backend is where it belongs",
            )
        offenders = []
        for path in tool_surface_files():
            relative_path = path.relative_to(TOOLS_DIR.parent).as_posix()
            if relative_path == SERVICE_MANAGER_BACKEND_PATH:
                continue
            content = path.read_text(encoding="utf-8")
            for description, pattern in SERVICE_MANAGER_ARTIFACTS:
                if pattern.search(content):
                    offenders.append((relative_path, description))
        self.assertEqual(
            offenders,
            [],
            "; ".join(
                f"{relative_path} contains {description}; reach the service "
                f"manager through {SERVICE_MANAGER_BACKEND_PATH} instead"
                for relative_path, description in offenders
            ),
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
        self.assertEqual(entry["files"], [LAUNCHD_BACKEND_PATH])
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
        # The record is the whole cross-language coupling: the Python side
        # writes it, Kanban reads it, and neither can see the other's
        # constants. So the manifest has to name both sides, and the path has
        # to appear literally in each rather than only in whichever one a
        # single-file row happened to declare. The writer is
        # `tools/kanban_config.py` rather than the controller: that is the one
        # module installed beside the controller, so it is the only one both
        # the installer and the installed copy can import, and therefore the
        # only place the location is written down.
        by_id = {row["id"]: row for row in self.manifest}
        self.assertIn("drainer-discovery-record", by_id)
        entry = by_id["drainer-discovery-record"]
        self.assertEqual(entry["kind"], "personal-path")
        self.assertEqual(entry["owner"], "kanban")
        self.assertEqual(entry["status"], "supported")
        self.assertEqual(
            entry["files"], ["tools/kanban_config.py", "src/Kanban/Drainer.hs"]
        )
        for relative_path in entry["files"]:
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            self.assertIn(entry["token"], content, relative_path)

    def test_every_managed_drainer_location_declares_both_platforms(self):
        # Issue #358: three locations times two platform conventions. A
        # location whose macOS row exists without its XDG sibling — or the
        # reverse — leaves one platform's literal undeclared and therefore
        # unpoliced, which is the hole the pairing rule exists to close. The
        # log root is included because it had no row at all before this.
        by_id = {row["id"]: row for row in self.manifest}
        for macos_id, xdg_id in (
            ("drainer-install-dir", "drainer-install-dir-xdg"),
            ("drainer-discovery-record", "drainer-discovery-record-xdg"),
            ("drainer-log-dir", "drainer-log-dir-xdg"),
        ):
            for row_id in (macos_id, xdg_id):
                with self.subTest(row=row_id):
                    self.assertIn(row_id, by_id)
                    row = by_id[row_id]
                    self.assertEqual(row["kind"], "personal-path")
                    self.assertEqual(row["owner"], "kanban")
                    self.assertEqual(row["status"], "supported")
                    # Every one of the six is grounded in the module that
                    # writes it down, whichever other readers it also has.
                    self.assertIn("tools/kanban_config.py", row["files"])
            self.assertTrue(by_id[macos_id]["token"].startswith("/Library/"))
            self.assertTrue(by_id[xdg_id]["token"].startswith("/.local/"))


    def test_issue_review_discovery_record_grounds_every_reader(self):
        # Same coupling as the drainer's record, for the canonical reviewer:
        # tools/install_issue_review.py writes it and seven consumers across
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
                "codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md",
                "claude-plugin/plugins/kanban/commands/issue-rereview.md",
                "codex-plugin/plugins/kanban/skills/triage/SKILL.md",
                "claude-plugin/plugins/kanban/commands/triage.md",
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

    def test_every_managed_issue_review_location_is_declared_for_both_platforms(self):
        # Issue #357: two managed locations, each with a macOS spelling and an
        # XDG one, and a row's token is one exact literal — so a location with
        # two spellings needs two rows, and a pair with only one row leaves the
        # other platform's spelling undeclared. Pinned as pairs rather than as
        # four independent rows for exactly that reason; the generic grounding
        # test above then proves each token still appears in the module that
        # spells it.
        by_id = {row["id"]: row for row in self.manifest}
        for macos_id, xdg_id, macos_token, xdg_token in (
            (
                "approve-issues-backend",
                "approve-issues-backend-xdg",
                "/Library/Application Support/kanban/issue-review",
                "/.local/share/kanban/issue-review",
            ),
            (
                "issue-review-log-dir",
                "issue-review-log-dir-xdg",
                "/Library/Logs/kanban/issue-review",
                "/.local/state/kanban/issue-review",
            ),
        ):
            for row_id, token in ((macos_id, macos_token), (xdg_id, xdg_token)):
                with self.subTest(row=row_id):
                    self.assertIn(row_id, by_id)
                    entry = by_id[row_id]
                    self.assertEqual(entry["kind"], "personal-path")
                    self.assertEqual(entry["token"], token)
                    self.assertEqual(entry["owner"], "kanban")
                    self.assertEqual(entry["status"], "supported")
                    self.assertEqual(entry["mandatory"], "no")
                    # One declared file each: the resolver is the only place
                    # any of these is spelled, which is what
                    # tools/test_install_issue_review.py's
                    # SingleSourceInstallPathTests holds the tree to.
                    self.assertEqual(entry["files"], ["tools/kanban_config.py"])


if __name__ == "__main__":
    unittest.main()
