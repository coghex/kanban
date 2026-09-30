"""Claude Code's argument substitution must not rewrite a command's shell code.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 tools/test_claude_argument_substitution.py

Issue #760. Before a session reads a command body, Claude Code substitutes the
invocation's arguments into it: `$ARGUMENTS` becomes the whole argument string,
and `$ARGUMENTS[N]` and the shorthand `$N` become the N-th argument, counting
from zero. An `awk` field reference such as `substr($0,10)` is `$N` text, so a
command invoked with arguments delivered `substr(Target,10)` or
`substr(2,10)`, and its `docs-wip`, `PRIMARY`, `ISSUE`, or `WORKTREE` lookup
silently found nothing.

The commands spell a field reference `$(N)` instead, which `awk` reads the same
way and which the substitution never matches. A backslash escape (`\\$0`) is
not a fix: Claude Code strips the backslash only when it substitutes at all, so
a body it passes through verbatim would hand `awk` the backslash.

Two things are under test, against every command in the Claude bundle, rendered
or hand-authored alike:

* **No substitutable text.** `SubstitutableTextTests` fails on any `$N` or
  `$ARGUMENTS[N]` text. None of these commands takes a positional placeholder;
  each reads its arguments through `$ARGUMENTS`, so every match is text that
  was never meant to be replaced.
* **The delivered lookups work.** `DeliveredLookupTests` applies the
  substitution to each command under representative invocations, including
  none at all, asserts each argument-sensitive lookup line arrives unchanged,
  and runs the `awk` program it delivers against fixture input, so a spelling
  that survives substitution as invalid `awk` still fails.

`claude_substitute` transcribes Claude Code 2.1.285's implementation rather
than its documentation, including the escape handling and the pass-through for
an invocation with no argument value. It omits named arguments, which only a
frontmatter `arguments` declaration introduces and no command here makes;
`test_no_command_declares_named_arguments` holds that premise.
"""

from __future__ import annotations

import re
import shlex
import subprocess
import unittest
from pathlib import Path

import render_command_sources as renderer

REPO_ROOT = Path(__file__).resolve().parent.parent
COMMANDS_DIR = REPO_ROOT / "claude-plugin/plugins/kanban/commands"

# Private-use sentinels, as Claude Code uses them: one stands for a `$` that
# must survive, the other brackets an inserted value so its own text is never
# substituted again. Both are stripped or restored at the end.
_DOLLAR = "￿"
_BRACKET = "￾"


def split_arguments(arguments: str) -> list[str]:
    """Claude Code's positional split: shell-style, falling back to whitespace."""
    if not arguments.strip():
        return []
    try:
        values = shlex.split(arguments)
    except ValueError:
        values = []
    return values or arguments.split()


def claude_substitute(body: str, arguments: str | None) -> str:
    """The command body a Claude Code session receives for `arguments`.

    `None` is an invocation with no argument value, which Claude Code returns
    untouched; an empty string still runs the escape handling.
    """
    if arguments is None:
        return body
    body = body.replace(_DOLLAR, "�").replace(_BRACKET, "�")

    def inserted(value: str) -> str:
        value = value.replace(_DOLLAR, "�").replace(_BRACKET, "�")
        return _BRACKET + value.replace("$", _DOLLAR) + _BRACKET

    values = split_arguments(arguments)
    substituted = False
    # One backslash keeps the placeholder literal, and is consumed doing so.
    body = re.sub(r"(?<!\\)\\\$(?=\d|ARGUMENTS)", _DOLLAR, body)

    def indexed(match: re.Match) -> str:
        nonlocal substituted
        index = int(match.group(1))
        if index >= len(values):
            return _DOLLAR + match.group(0)[1:]
        substituted = True
        return inserted(values[index])

    body = re.sub(r"\$ARGUMENTS\[(\d+)\]", indexed, body)

    def shorthand(match: re.Match) -> str:
        nonlocal substituted
        index = int(match.group(1))
        if index >= len(values):
            return match.group(0)
        substituted = True
        return inserted(values[index])

    body = re.sub(r"\$(\d+)(?!\w)", shorthand, body)
    if "$ARGUMENTS" in body:
        substituted = True
        body = body.replace("$ARGUMENTS", inserted(arguments))
    if not substituted and arguments:
        body += "\n\nARGUMENTS: " + inserted(arguments)
    return body.replace(_DOLLAR, "$").replace(_BRACKET, "")


# The text `claude_substitute` would replace given enough arguments. The
# `$N` alternative matches inside a backslash escape too, deliberately: that
# escape is unsafe for the reason the module docstring gives.
SUBSTITUTABLE = re.compile(r"\$ARGUMENTS\[\d+\]|\$\d+(?!\w)")


def substitutable_text(text: str) -> list[str]:
    return [
        f"line {text.count(chr(10), 0, match.start()) + 1}: {match.group(0)}"
        for match in SUBSTITUTABLE.finditer(text)
    ]


def claude_commands() -> dict[str, str]:
    return {
        path.stem: path.read_text(encoding="utf-8")
        for path in sorted(COMMANDS_DIR.glob("*.md"))
    }


def rendered_claude_commands() -> set[str]:
    return {
        entry.name
        for entry in renderer.COMMAND_SOURCES
        if "claude" in entry.outputs
        and Path(entry.outputs["claude"]) == COMMANDS_DIR.relative_to(REPO_ROOT)
    }


# Representative invocations: none at all, an empty one, a single numeric
# argument (`/finalize 2`), three arguments, which reach `$1` and `$2`, and a
# multi-word string like the one that broke `/issue` on 2026-09-29.
INVOCATIONS = (
    None,
    "",
    "2",
    "42 --repo coghex/kanban",
    "Target tracker: split the drainer's lock into three slices",
)

DOCS_WT = "/tmp/worktrees/docs-wip"
PRIMARY = "/tmp/checkout"
FINALIZE_WORKTREE = "/tmp/worktrees/coghex/kanban/issue-7-example"
FINALIZE_HEAD = "1a2b3c4d5e6f70819293a4b5c6d7e8f900112233"

# `git worktree list --porcelain` for a checkout carrying all three worktrees
# the lookups below search for, each preceded by a decoy they must pass over.
WORKTREE_LISTING = (
    f"worktree {PRIMARY}\n"
    "HEAD 0000000000000000000000000000000000000001\n"
    "branch refs/heads/master\n"
    "\n"
    "worktree /tmp/worktrees/stale-copy\n"
    "HEAD 99887766554433221100ffeeddccbbaa99887766\n"
    "branch refs/heads/issue-7-example\n"
    "\n"
    f"worktree {FINALIZE_WORKTREE}\n"
    f"HEAD {FINALIZE_HEAD}\n"
    "branch refs/heads/issue-7-example\n"
    "\n"
    f"worktree {DOCS_WT}\n"
    "HEAD 0000000000000000000000000000000000000002\n"
    "branch refs/heads/docs-wip\n"
)


class Lookup:
    """One argument-sensitive lookup line, and what its `awk` must return."""

    def __init__(self, name, marker, commands, variables, stdin, expected):
        self.name = name
        self.marker = marker
        self.commands = commands
        self.variables = variables
        self.stdin = stdin
        self.expected = expected


# The `docs-wip` worktree resolution the document workflows open with.
DOCS_WT_COMMANDS = frozenset(
    {
        "backlog-review",
        "design-epic",
        "draft-issues",
        "draft-report",
        "issue",
        "note-problem",
        "process-design-doc",
        "process-report",
        "project-review",
        "retriage",
    }
)

LOOKUPS = (
    Lookup(
        "docs-wip",
        r"/^branch refs\/heads\/docs-wip$/",
        DOCS_WT_COMMANDS,
        {},
        WORKTREE_LISTING,
        DOCS_WT,
    ),
    Lookup(
        "janitor PRIMARY",
        'awk -v want="branch refs/heads/$DEFAULT"',
        frozenset({"janitor"}),
        {"want": "branch refs/heads/master"},
        WORKTREE_LISTING,
        PRIMARY,
    ),
    Lookup(
        "finalize ISSUE",
        'ISSUE="$(gh pr view',
        frozenset({"finalize"}),
        {"want": "coghex/kanban"},
        "other/fork 9\nCoghex/Kanban 7\ncoghex/kanban 8\n",
        "7",
    ),
    Lookup(
        "finalize WORKTREE",
        'WORKTREE="$(git -C "$ROOT" worktree list --porcelain',
        frozenset({"finalize"}),
        {"ref": "refs/heads/issue-7-example", "sha": FINALIZE_HEAD},
        WORKTREE_LISTING,
        FINALIZE_WORKTREE,
    ),
)

AWK_PROGRAM = re.compile(r"""\bawk\b(?:\s+-v\s+(?:\S*"[^"]*"|\S+))*\s+'([^']*)'""")


def lookup_lines(text: str, marker: str) -> list[str]:
    return [line for line in text.splitlines() if marker in line]


def run_awk(line: str, lookup: Lookup) -> str:
    match = AWK_PROGRAM.search(line)
    if match is None:
        raise AssertionError(f"no awk program in {line!r}")
    argv = ["awk"]
    for name, value in lookup.variables.items():
        argv += ["-v", f"{name}={value}"]
    argv.append(match.group(1))
    completed = subprocess.run(
        argv, input=lookup.stdin, capture_output=True, text=True, check=False
    )
    if completed.returncode != 0:
        raise AssertionError(f"awk failed for {line!r}: {completed.stderr}")
    return completed.stdout.strip()


class SubstitutionModelTests(unittest.TestCase):
    """The transcription agrees with the documented rules it stands in for."""

    def test_positional_references_count_from_zero(self):
        self.assertEqual(claude_substitute("$0 then $1", "first second"), "first then second")
        self.assertEqual(
            claude_substitute("$ARGUMENTS[1]", "first second"), "second"
        )

    def test_an_index_past_the_arguments_is_left_unchanged(self):
        delivered = claude_substitute("$2 $ARGUMENTS[2]", "only")
        self.assertEqual(delivered, "$2 $ARGUMENTS[2]\n\nARGUMENTS: only")

    def test_a_backslash_is_consumed_only_when_substitution_runs(self):
        self.assertEqual(claude_substitute(r"\$0 $ARGUMENTS", "x"), "$0 x")
        self.assertEqual(claude_substitute(r"\$0", None), r"\$0")

    def test_the_documented_breakage_reproduces(self):
        line = "awk '/^worktree /{p=substr($0,10)}'"
        self.assertIn("substr(Target,10)", claude_substitute(line, "Target tracker: x y"))
        self.assertIn("substr(2,10)", claude_substitute(line, "2"))

    def test_an_inserted_value_is_never_substituted_again(self):
        self.assertEqual(claude_substitute("$ARGUMENTS", "$1 costs"), "$1 costs")

    def test_field_references_in_parentheses_are_never_matched(self):
        line = "awk '{print $(0), $(1), $(2), $NF}'"
        self.assertEqual(claude_substitute(line, "a b c"), line + "\n\nARGUMENTS: a b c")


class SubstitutableTextTests(unittest.TestCase):
    """Requirement 3: no Claude command carries text the substitution rewrites."""

    def test_the_scan_covers_rendered_and_hand_authored_commands(self):
        names = set(claude_commands())
        rendered = rendered_claude_commands()
        self.assertTrue(rendered, "no rendered Claude command found")
        self.assertLessEqual(rendered, names)
        self.assertTrue(names - rendered, "no hand-authored Claude command found")

    def test_no_command_carries_substitutable_text(self):
        for name, text in claude_commands().items():
            with self.subTest(command=name):
                self.assertEqual(
                    substitutable_text(text),
                    [],
                    f"{name}.md carries text Claude Code substitutes; spell an "
                    "awk field reference $(N), and read arguments through "
                    "$ARGUMENTS (docs/development.md)",
                )

    def test_no_command_declares_named_arguments(self):
        for name, text in claude_commands().items():
            with self.subTest(command=name):
                frontmatter = text.split("\n---", 1)[0] if text.startswith("---") else ""
                self.assertNotRegex(frontmatter, r"(?m)^arguments\s*:")

    def test_the_scan_flags_each_substitutable_spelling(self):
        # Negative control: the scan above must be able to fail.
        for text in (
            "awk '/^worktree /{p=substr($0,10)}'",
            "awk '{print $2}'",
            r"awk '{print \$1}'",
            "echo $ARGUMENTS[0]",
        ):
            with self.subTest(text=text):
                self.assertNotEqual(substitutable_text(text), [])

    def test_the_scan_passes_the_safe_spellings(self):
        for text in (
            "awk '/^worktree /{p=substr($(0),10)}'",
            "awk '{print $NF}'",
            'echo "$ARGUMENTS"',
            "costs $5x",
        ):
            with self.subTest(text=text):
                self.assertEqual(substitutable_text(text), [])


class DeliveredLookupTests(unittest.TestCase):
    """Requirement 4: each lookup arrives unchanged and still finds its target."""

    def test_each_lookup_is_found_in_exactly_its_commands(self):
        # The lookups below iterate these sets, so a command that lost or
        # gained a lookup would otherwise shrink or dodge what is tested.
        commands = claude_commands()
        for lookup in LOOKUPS:
            with self.subTest(lookup=lookup.name):
                carriers = {
                    name for name, text in commands.items() if lookup_lines(text, lookup.marker)
                }
                self.assertEqual(carriers, set(lookup.commands))

    def test_the_stored_lookups_find_their_targets(self):
        commands = claude_commands()
        for lookup in LOOKUPS:
            for name in sorted(lookup.commands):
                with self.subTest(lookup=lookup.name, command=name):
                    (line,) = lookup_lines(commands[name], lookup.marker)
                    self.assertEqual(run_awk(line, lookup), lookup.expected)

    def test_substitution_leaves_every_lookup_unchanged_and_working(self):
        commands = claude_commands()
        for lookup in LOOKUPS:
            for name in sorted(lookup.commands):
                (stored,) = lookup_lines(commands[name], lookup.marker)
                for arguments in INVOCATIONS:
                    with self.subTest(lookup=lookup.name, command=name, arguments=arguments):
                        delivered = claude_substitute(commands[name], arguments)
                        (line,) = lookup_lines(delivered, lookup.marker)
                        self.assertEqual(line, stored)
                        self.assertEqual(run_awk(line, lookup), lookup.expected)


if __name__ == "__main__":
    unittest.main()
