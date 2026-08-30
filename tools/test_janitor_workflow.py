"""The vendored janitor workflow's own behavioral contract.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 tools/test_janitor_workflow.py

Issue #575, slice VEND-9 of `docs/workflow_command_vendoring_design.md`, and
the seventh of the eight commands the arc vendors. It is the only one split
across two pull requests: issue #574 shipped `scripts/census.py` into both
bundles with nothing invokable, and this slice ships the body that reasons over
the `janitor-census/v1` snapshot that program emits.

Its reconciliation is the widest in the arc after `project-review`'s -- 143
differing lines between a 23-line Claude copy and a 134-line Codex copy -- and
design D-12 resolved it in the Codex copy's favour, so almost nothing here is
carried over on the strength of a personal file having said it. The assertions
fall into five kinds.

* **The helper, resolved rather than described.** Each brand resolves the
  census from its own install location, and the body says an unresolvable
  helper stops the run *before the first read*. `HelperResolutionTests` runs
  each brand's resolution fence under `sh` against a planted install, and again
  against a missing one, and asserts from the recorded command log that the
  missing case reaches no census invocation at all -- the ordering claim, not
  the wording of it. The Codex search is additionally driven against a census
  planted under a *different* skill, because a `find` that matched any
  `census.py` under the plugin cache would resolve another command's helper.
* **The invocation, argument for argument.** Requirement 3 says the census is
  passed everything it needs and nothing it does not accept.
  `CensusInvocationTests` records the argv of both census runs -- the first
  pass and the pre-apply refresh -- and compares each against the option set
  the shipped program's own `--help` prints, so "nothing it does not accept" is
  measured against the program rather than against this module's memory of it.
* **What a report does not do.** The workflow's whole promise is that it
  mutates nothing before approval. `MutationBoundaryTests` concatenates every
  executable fence from the helper resolution through the last verification
  read -- everything an agent runs before the report-and-stop -- and asserts
  against the recorded log that none of the nine mutating commands ran. The
  control runs the apply fences too and asserts every one of them appears, so
  those absences are observable rather than vacuous.
* **Repository scoping.** Both personal copies made bare `gh` calls, which
  target whatever repository the session's directory happens to be in -- and
  this workflow's calls release a claim and drive branch deletions.
  `RepositoryScopeTests` pins the calls the assets make, one spelling each, and
  requires every one to carry `-R "$REPO"` or to embed `repos/$REPO/`; a
  planted unscoped call is the control.
* **The gates, enumerated with their near-misses.** `all-safe` is bulk
  approval, so what it covers is the one piece of prose in this asset that
  decides whether work is destroyed without a second look.
  `PreservationGateTests` enumerates all five gates, every condition of each,
  and the near-miss each gate names -- the case that reads as a pass and is not
  -- against both renderings, with a control per gate that plants its deletion.

Every rule is measured over BOTH rendered assets, and each class carries a
control that plants the failure it is meant to catch: a rule matching
everything would otherwise pass while asserting nothing.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import fake_cli
import render_command_sources as renderer

REPO_ROOT = Path(__file__).resolve().parent.parent

SOURCE = "tools/command_sources/janitor.md"
CLAUDE_ASSET = "claude-plugin/plugins/kanban/commands/janitor.md"
CODEX_ASSET = "codex-plugin/plugins/kanban/skills/janitor/SKILL.md"
RENDERED_ASSETS = (CLAUDE_ASSET, CODEX_ASSET)
BRAND_OF = {CLAUDE_ASSET: "claude", CODEX_ASSET: "codex"}

# Both shipped copies of the program this body reasons over. The Claude bundle
# has one shared scripts root; the Codex bundle has none, so its copy sits in
# this skill's own directory -- which is why the two resolution blocks differ
# at all.
CENSUS_PROGRAMS = {
    "claude": "claude-plugin/plugins/kanban/scripts/census.py",
    "codex": "codex-plugin/plugins/kanban/skills/janitor/scripts/census.py",
}

BASH_FENCE_RE = re.compile(r"```bash\n(?P<body>.*?)\n[ \t]*```", re.DOTALL)

# A `gh` invocation as the assets actually spell one, in a fenced block or in
# inline code. The lookbehind keeps the `gh` ending a longer word out, and the
# required lowercase subcommand keeps a prose mention of a "`gh` call" out.
GH_INVOCATION_RE = re.compile(r"(?<![\w-])gh (?P<tail>[a-z][^\n`]*)")

REPOSITORY_SCOPE = '-R "$REPO"'

# How `$REPO` is filled: from the remote, with no GitHub call of its own. At
# the point of resolution `$REPO` does not exist yet, so a `gh` call there
# could not carry `-R` and the rule below would have to make an exception for
# the very call that decides which repository everything else is scoped to.
REPOSITORY_RESOLUTION = 'REPO="$(git -C "$ROOT" remote get-url origin'

# Every `gh` call the workflow makes, by its exact spelling. Counted as well as
# listed: a rule over "every `gh` call" passes vacuously if the assets ever
# stop making any.
REPOSITORY_SCOPED_CALLS = (
    'gh issue view "$ISSUE" -R "$REPO" --json '
    "number,state,assignees,labels,updatedAt",
    'gh pr list -R "$REPO" --state all --head "$BRANCH" --json '
    "number,state,mergedAt,labels",
    'gh pr view "$PR" -R "$REPO" --json headRefOid,labels,commits',
    'gh pr checks "$PR" -R "$REPO" --json name,state,bucket',
    # Two commands, not one: a claim is an assignee OR a `wip` label, so a
    # combined call passes an empty assignee on a label-only claim and fails
    # before it reaches the label.
    'gh issue edit "$ISSUE" -R "$REPO" --remove-assignee "$ASSIGNEE"',
    'gh issue edit "$ISSUE" -R "$REPO" --remove-label wip',
)
# The one call whose repository binding is in its path rather than in a flag,
# because `gh api` takes no `-R`. It is an enumerated exception, not a pattern:
# a second such call added later fails the count below rather than inheriting
# this allowance.
PATH_SCOPED_CALLS = (
    'gh api --paginate --slurp "repos/$REPO/issues/$PR/comments?per_page=100"',
)
DECLARED_GH_CALL_COUNT = len(REPOSITORY_SCOPED_CALLS) + len(PATH_SCOPED_CALLS)

# The fenced blocks each rendering carries, in order, identified by a line only
# that fence has. Pinned as a total too: a fence added without a name here is
# an executable block no assertion below runs.
FENCE_MARKERS = (
    ("helper", "CENSUS="),
    ("resolution", "remote get-url origin"),
    ("census-first", 'python3 "$CENSUS" --repo "$ROOT" --fetch'),
    ("claims", "gh issue view"),
    ("worktrees", "worktree prune --dry-run"),
    ("branches", "ls-remote --heads origin"),
    ("pull-requests", "gh api --paginate"),
    ("checks", "gh pr checks"),
    ("recovery", "stash show -p"),
    ("census-refresh", 'python3 "$CENSUS" --repo "$ROOT" --fetch'),
    ("deletions", 'worktree remove "$WORKTREE"'),
    ("metadata-prune", "worktree prune --expire now"),
    ("claim-release", "gh issue edit"),
    ("fast-forward", "merge --ff-only"),
)
FENCE_COUNT = len(FENCE_MARKERS)
# Everything an agent runs before the report-and-stop. The two census fences
# are byte-identical, so they are addressed by index rather than by content.
PRE_APPROVAL_FENCES = tuple(range(0, 9))
APPLY_FENCES = (9, 10, 11, 12, 13)

# The scenario every run below is scripted against.
REPO_SLUG = "coghex/kanban"
CHECKOUT_ROOT = "/tmp/janitor-checkout"
DEFAULT_BRANCH = "master"
PRIMARY_WORKTREE = "/tmp/janitor-primary"
ISSUE = "7"
PULL_REQUEST = "42"
BRANCH = "issue-7-example"
STASH = "stash@{0}"
STASH_SHA = "ccddeeff00112233445566778899aabbccddeeff"
WORKTREE = "/tmp/worktrees/coghex/kanban/issue-7-example"
REF = "refs/drain-prs/autostash/abc"
REF_SHA = "8877665544332211009988776655443322110099"
TRACKING_REF = "refs/remotes/origin/issue-3-gone"
TRACKING_SHA = "aabbccddeeff00112233445566778899aabbccdd"
SHA = "1a2b3c4d5e6f70819293a4b5c6d7e8f900112233"
ASSIGNEE = "coghex"

# What `git worktree prune --dry-run --expire now --verbose` prints, in the
# format git actually uses, for two prunable records. The workflow subtracts the
# approved names from this listing, so the fixture is the listing rather than
# the names -- and it is scripted on STDERR, which is where git writes it. A
# fixture on stdout would let a gate that reads stdout alone pass here while
# pruning every record in a real repository, which is exactly the failure
# RealGitApplyTests drives against git itself.
PRUNE_DRY_RUN = (
    "Removing worktrees/issue-3-gone: gitdir file points to non-existent location\n"
    "Removing worktrees/issue-9-other: gitdir file points to non-existent location\n"
)
PRUNABLE_RECORDS = ("issue-3-gone", "issue-9-other")

WORKTREE_LISTING = (
    f"worktree {PRIMARY_WORKTREE}\nHEAD {SHA}\nbranch refs/heads/{DEFAULT_BRANCH}\n"
    f"\nworktree {WORKTREE}\nHEAD {SHA}\nbranch refs/heads/{BRANCH}\n"
)

# One census document, in the shape the shipped program emits. Nothing in the
# shell parses it -- the agent does -- so it stands in for the read rather than
# being asserted against.
CENSUS_DOCUMENT = json.dumps(
    {
        "schema": "janitor-census/v1",
        "repo_root": CHECKOUT_ROOT,
        "default_branch": DEFAULT_BRANCH,
        "worktrees": [],
        "retain_ledger": {"items": None},
        "counts": {"worktrees": 2, "retained_items": None},
        "warnings": [],
    }
)

# The mutations this workflow can make, by the contiguous run of arguments that
# identifies each. `worktree prune --expire` is deliberately contiguous: the
# verification step's `worktree prune --dry-run --expire now --verbose` carries
# the same words with `--dry-run` between them, and a subsequence match that
# ignored the gap would report the read as a mutation.
GIT_MUTATIONS = {
    "prune worktree metadata": ["worktree", "prune", "--expire"],
    "remove a worktree": ["worktree", "remove"],
    "delete a local branch": ["branch", "-d"],
    "delete a remote branch": ["push", "origin"],
    "drop a stash": ["stash", "drop"],
    "delete a ref": ["update-ref", "-d"],
    "fast-forward the default branch": ["merge", "--ff-only"],
}
GH_MUTATIONS = {"release a claim": ["issue", "edit"]}

# The bulk operations this workflow does NOT perform, because each reaches
# every eligible target rather than the approved one. `fetch --prune` removes
# every stale tracking ref, including refs this run never reported, and a bare
# `--delete` push deletes whatever the branch points at now rather than the
# commit the report proved. Both are named in the body's prose, saying why they
# are not used, so the absence is asserted over the fences alone.
FORBIDDEN_IN_FENCES = {
    "a bulk tracking-ref prune": "fetch --prune",
    "an unleased remote deletion": "push origin --delete",
}


def read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def body_of(text: str) -> str:
    """`text` with its frontmatter block removed.

    The frontmatter is the one place the two renderings legitimately differ
    beyond the brand blocks -- different keys, and the invocation sigil inside
    the description -- so the brand comparison is made over the body.
    """
    match = re.match(r"\A---\n.*?\n---\n(?P<body>.*)\Z", text, re.DOTALL)
    assert match is not None, "a rendered asset always opens with frontmatter"
    return match.group("body")


# The workflows this source names through a `{{cmd:}}` token, read from the
# source rather than restated, so the brand comparison covers exactly the
# substitutions the renderer performs and no more.
REFERENCED_WORKFLOWS = renderer.referenced_names(read(SOURCE))


def neutralize(text: str, brand: str) -> str:
    """`text` with `brand`'s spelling of each declared `{{cmd:}}` target put
    back into the neutral token.

    Matched through the renderer's own invocation pattern rather than by plain
    substring replacement, because this body contains both spellings as
    ordinary text: `refs/drain-prs/autostash/<sha>` is a ref namespace and
    `skills/janitor/scripts/census.py` is a path. A substring rewrite would
    turn the first into a token in the Claude rendering and leave it alone in
    the Codex one, and report the two renderings as disagreeing about text
    neither of them substituted.
    """
    pattern = renderer.LITERAL_INVOCATION_PATTERNS[renderer.SIGILS[brand]]

    def substitute(match: re.Match) -> str:
        name = match.group(1)
        if name not in REFERENCED_WORKFLOWS:
            return match.group(0)
        return f"{{{{cmd:{name}}}}}"

    return pattern.sub(substitute, text)


# The acceptance command's own regex, character for character: no reference to
# a workflow may be written with a literal sigil.
ACCEPTANCE_SIGIL_RE = re.compile(
    r"(^|[^A-Za-z0-9`])[/$](drain-prs|pr-revise|pr-rereview|janitor)\b",
    re.MULTILINE,
)


def flat(text: str) -> str:
    """`text` with every run of whitespace collapsed to one space, so a phrase
    is found whether or not the source wrapped it across lines."""
    return re.sub(r"\s+", " ", text)


def missing(text: str, phrases) -> list[str]:
    """The phrases `text` does not carry, matched over flattened text."""
    flattened = flat(text)
    return [phrase for phrase in phrases if flat(phrase) not in flattened]


def bash_fences(text: str) -> list[str]:
    return [match.group("body") for match in BASH_FENCE_RE.finditer(text)]


def named_fences(text: str) -> dict[str, str]:
    """The asset's fenced blocks, keyed by the names FENCE_MARKERS gives them.

    Positional rather than by content, because the first census run and the
    pre-apply refresh are byte-identical by design -- the whole point of the
    refresh is that it asks the same question again.
    """
    fences = bash_fences(text)
    assert len(fences) == FENCE_COUNT, (
        f"expected {FENCE_COUNT} fenced blocks, got {len(fences)}"
    )
    named = {}
    for (name, marker), fence in zip(FENCE_MARKERS, fences):
        assert marker in fence, f"fence for {name!r} does not contain {marker!r}"
        named[name] = fence
    return named


def gh_invocations(text: str) -> list[str]:
    """Every `gh` call in `text`, with a command substitution's own closing
    `)"` trimmed off."""
    calls = []
    for match in GH_INVOCATION_RE.finditer(text):
        call = match.group(0)
        calls.append(call[:-2] if call.endswith(')"') else call)
    return calls


def contains_run(arguments: list[str], needle: list[str]) -> bool:
    """Whether `needle` appears in `arguments` as a contiguous run."""
    width = len(needle)
    return any(
        arguments[index : index + width] == needle
        for index in range(len(arguments) - width + 1)
    )


def isolated_git_env(root: Path) -> dict[str, str]:
    """An environment in which `git` reads none of this developer's config.

    A real-Git test that inherited `~/.gitconfig` would pass or fail on
    whatever the host happens to configure -- `stash.showPatch`, a default
    branch name, a commit template -- rather than on the asset.
    """
    (root / "home").mkdir(parents=True, exist_ok=True)
    return {
        "PATH": os.environ.get("PATH", ""),
        "HOME": str(root / "home"),
        "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "GIT_CONFIG_GLOBAL": str(root / "gitconfig"),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "janitor test",
        "GIT_AUTHOR_EMAIL": "janitor@example.invalid",
        "GIT_COMMITTER_NAME": "janitor test",
        "GIT_COMMITTER_EMAIL": "janitor@example.invalid",
    }


def census_option_names(brand: str) -> set[str]:
    """The long options the shipped census program actually accepts.

    Read from the program's own `--help` rather than restated here, so
    "nothing it does not accept" is measured against the thing being invoked.
    """
    program = REPO_ROOT / CENSUS_PROGRAMS[brand]
    result = subprocess.run(
        [sys.executable, str(program), "--help"],
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
    )
    assert result.returncode == 0, result.stderr
    return set(re.findall(r"(--[a-z][a-z0-9-]*)", result.stdout))


class Harness:
    """One scripted `gh`/`git`/`python3` trio plus the fences to run against
    them.

    `python3` is recorded by a shim of this module's own rather than through
    `fake_cli`, because `fake_cli`'s shims are themselves `python3` scripts: a
    scripted `python3` on the same PATH would answer their shebang and the
    first `gh` call would re-enter the fake forever. The `gh` and `git` shims
    are repointed at this interpreter for the same reason.
    """

    def __init__(self, root: Path, brand: str, *, install_helper: bool = True,
                 decoy_helper: bool = False, approved_records=PRUNABLE_RECORDS,
                 prune_dry_run: str = PRUNE_DRY_RUN, stash_head: str = STASH_SHA):
        self.root = root
        self.brand = brand
        self.approved_records = tuple(approved_records)
        self.prune_dry_run = prune_dry_run
        self.stash_head = stash_head
        self.fake = fake_cli.FakeCli(root)
        for binary in ("gh", "git"):
            self.fake.install(binary)
            shim = self.fake.bin_dir / binary
            shim.write_text(
                shim.read_text(encoding="utf-8").replace(
                    "#!/usr/bin/env python3", "#!" + sys.executable, 1
                ),
                encoding="utf-8",
            )
        self.python_log = root / "python3.calls.jsonl"
        recorder = self.fake.bin_dir / "python3"
        recorder.write_text(
            "#!" + sys.executable + "\n"
            "import json, os, sys\n"
            "with open(os.environ['JANITOR_PYTHON_LOG'], 'a') as handle:\n"
            "    handle.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "sys.stdout.write(os.environ.get('JANITOR_CENSUS_STDOUT', ''))\n",
            encoding="utf-8",
        )
        recorder.chmod(recorder.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        self.plugin_root = root / "claude-plugin-root"
        self.codex_home = root / "codex-home"
        installed = self.plugin_root / "scripts" / "census.py"
        cached = (
            self.codex_home
            / "plugins"
            / "cache"
            / "kanban"
            / "kanban"
            / "1.0.0"
            / "skills"
            / "janitor"
            / "scripts"
            / "census.py"
        )
        # A census belonging to a DIFFERENT skill, so a search that matched any
        # census.py under the plugin cache would resolve the wrong helper.
        decoy = cached.parent.parent.parent / "project-review" / "scripts" / "census.py"
        for path, present in (
            (installed, install_helper),
            (cached, install_helper),
            (decoy, install_helper or decoy_helper),
        ):
            if present:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("# stand-in for the shipped census\n", encoding="utf-8")
        self.installed_census = installed
        self.cached_census = cached
        self.decoy_census = decoy

    def script_commands(self) -> None:
        self.fake.script("git", ["rev-parse", "--show-toplevel"],
                         stdout=CHECKOUT_ROOT + "\n")
        self.fake.script(
            "git",
            ["-C", CHECKOUT_ROOT, "remote", "get-url", "origin"],
            stdout=f"https://github.com/{REPO_SLUG}.git\n",
        )
        self.fake.script(
            "git",
            ["-C", CHECKOUT_ROOT, "worktree", "list", "--porcelain"],
            stdout=WORKTREE_LISTING,
        )
        self.fake.script(
            "git",
            ["-C", CHECKOUT_ROOT, "worktree", "prune", "--dry-run"],
            stderr=self.prune_dry_run,
        )
        self.fake.script(
            "git",
            ["-C", CHECKOUT_ROOT, "ls-remote", "--heads", "origin"],
            stdout=f"{SHA}\trefs/heads/{DEFAULT_BRANCH}\n",
        )
        self.fake.script(
            "git", ["-C", CHECKOUT_ROOT, "stash", "show", "-p"], stdout="diff --git\n"
        )
        self.fake.script(
            "git",
            ["-C", CHECKOUT_ROOT, "rev-parse", "--verify", "--quiet"],
            stdout=self.stash_head + "\n",
        )
        for tail in (
            ["worktree", "prune", "--expire"],
            ["worktree", "remove"],
            ["branch", "-d"],
            ["push", "origin"],
            ["stash", "drop"],
            ["update-ref", "-d"],
        ):
            self.fake.script("git", ["-C", CHECKOUT_ROOT, *tail], stdout="")
        self.fake.script(
            "git", ["-C", PRIMARY_WORKTREE, "merge", "--ff-only"], stdout=""
        )
        # Inserted last: fake_cli takes the first scripted entry whose match is
        # a prefix of the call, so a catch-all placed earlier would answer the
        # specific reads above as well.
        self.fake.script("git", ["-C"], stdout="")

        self.fake.script("gh", ["issue", "view", ISSUE], stdout="{}\n")
        self.fake.script("gh", ["pr", "list"], stdout="[]\n")
        self.fake.script("gh", ["pr", "view", PULL_REQUEST], stdout="{}\n")
        self.fake.script("gh", ["api", "--paginate", "--slurp"], stdout="[]\n")
        self.fake.script("gh", ["pr", "checks", PULL_REQUEST], stdout="[]\n")
        self.fake.script("gh", ["issue", "edit", ISSUE], stdout="")
        self.fake.script("gh", ["issue", "edit", ISSUE], stdout="")

    def environment(self) -> dict[str, str]:
        env = {
            "PATH": "",
            "HOME": str(self.root / "home"),
            "JANITOR_PYTHON_LOG": str(self.python_log),
            "JANITOR_CENSUS_STDOUT": CENSUS_DOCUMENT,
            "ISSUE": ISSUE,
            "PR": PULL_REQUEST,
            "BRANCH": BRANCH,
            "STASH": STASH,
            "STASH_SHA": STASH_SHA,
            "WORKTREE": WORKTREE,
            "REF": REF,
            "REF_SHA": REF_SHA,
            "TRACKING_REF": TRACKING_REF,
            "TRACKING_SHA": TRACKING_SHA,
            "SHA": SHA,
            "ASSIGNEE": ASSIGNEE,
            "DEFAULT": DEFAULT_BRANCH,
            "APPROVED_RECORDS": "\n".join(self.approved_records),
        }
        if self.brand == "claude":
            env["CLAUDE_PLUGIN_ROOT"] = str(self.plugin_root)
        else:
            env["CODEX_HOME"] = str(self.codex_home)
        env.update(self.fake.environ_overrides())
        return env

    def run(self, script: str) -> subprocess.CompletedProcess:
        # `set -e` is what turns the asset's `[ -f "$CENSUS" ]` and
        # `[ -n "$CENSUS" ]` lines into the stop the body says they are: an
        # agent that read on past a failed resolution would be doing what
        # those lines exist to forbid.
        return subprocess.run(
            ["sh", "-c", "set -e\n" + script],
            env=self.environment(),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
        )

    def python_calls(self) -> list[list[str]]:
        if not self.python_log.exists():
            return []
        return [
            json.loads(line)
            for line in self.python_log.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]

    def gh_calls(self) -> list[list[str]]:
        return [call["args"] for call in self.fake.calls("gh")]

    def git_calls(self) -> list[list[str]]:
        return [call["args"] for call in self.fake.calls("git")]


class HarnessCase(unittest.TestCase):
    def harness(self, brand: str, **kwargs) -> Harness:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        harness = Harness(Path(directory.name), brand, **kwargs)
        harness.script_commands()
        return harness

    def temporary_directory(self) -> Path:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        return Path(directory.name)

    def fences(self, relative_path: str) -> dict[str, str]:
        return named_fences(read(relative_path))

    def script(self, relative_path: str, indices) -> str:
        blocks = bash_fences(read(relative_path))
        return "\n".join(blocks[index] for index in indices)


class RenderParityTests(unittest.TestCase):
    """One source, two renderings that differ only where a brand block says
    they may."""

    def test_the_two_renderings_agree_outside_their_brand_blocks(self):
        claude = neutralize(body_of(read(CLAUDE_ASSET)), "claude")
        codex = neutralize(body_of(read(CODEX_ASSET)), "codex")
        # The helper-resolution fence is the declared difference, and the only
        # one: everything before and after it must be identical.
        claude_rest = claude.replace(named_fences(read(CLAUDE_ASSET))["helper"], "")
        codex_rest = codex.replace(named_fences(read(CODEX_ASSET))["helper"], "")
        self.assertEqual(claude_rest, codex_rest)

    def test_the_renderings_are_current_against_the_source(self):
        self.assertEqual(renderer.check_all(REPO_ROOT), [])

    def test_every_fence_is_named(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                named = named_fences(read(relative_path))
                self.assertEqual(len(named), FENCE_COUNT)

    def test_no_literal_sigil_survives_the_token_rule(self):
        # The acceptance command, run as an assertion, alongside the renderer's
        # own refusal. Two spellings of one rule on purpose: the grep is what
        # the issue asks for, and the renderer's is what actually blocks a
        # render, so a divergence between them is worth failing on.
        source = read(SOURCE)
        self.assertEqual(
            [match.group(0) for match in ACCEPTANCE_SIGIL_RE.finditer(source)], []
        )
        self.assertEqual(
            renderer.literal_invocation_failures(
                source,
                renderer.workflow_vocabulary(REPO_ROOT) | REFERENCED_WORKFLOWS,
                origin=SOURCE,
            ),
            [],
        )
        self.assertIn("{{cmd:drain-prs}}", source)
        self.assertIn("{{cmd:pr-revise}}", source)
        self.assertIn("{{cmd:pr-rereview}}", source)

    def test_the_acceptance_regex_catches_a_planted_literal_sigil(self):
        # The control: a rule that matched nothing would pass over a body full
        # of literal sigils just as quietly.
        for planted in ("route it to /drain-prs recover", "resume $pr-revise"):
            with self.subTest(planted=planted):
                self.assertTrue(ACCEPTANCE_SIGIL_RE.search(planted))


class HelperResolutionTests(HarnessCase):
    """Each brand resolves this bundle's own census, and a run that cannot
    stops before it reads anything."""

    def test_each_brand_resolves_its_own_installed_helper(self):
        for relative_path in RENDERED_ASSETS:
            brand = BRAND_OF[relative_path]
            with self.subTest(asset=relative_path):
                harness = self.harness(brand)
                script = self.script(relative_path, (0,)) + '\nprintf "%s" "$CENSUS"\n'
                result = harness.run(script)
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = (
                    harness.installed_census
                    if brand == "claude"
                    else harness.cached_census
                )
                self.assertEqual(result.stdout, str(expected))

    def test_a_missing_helper_stops_before_the_census_is_read(self):
        # The ordering claim, asserted from the log rather than from the
        # prose: the run reaches no census invocation, and no GitHub call.
        for relative_path in RENDERED_ASSETS:
            brand = BRAND_OF[relative_path]
            with self.subTest(asset=relative_path):
                harness = self.harness(brand, install_helper=False)
                script = self.script(relative_path, (0, 1, 2))
                result = harness.run(script)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(harness.python_calls(), [])
                self.assertEqual(harness.gh_calls(), [])

    def test_the_control_reaches_the_census_when_the_helper_is_there(self):
        # Non-vacuity for the absence above: the same three fences against an
        # installed helper really do run the census.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                harness = self.harness(BRAND_OF[relative_path])
                result = harness.run(self.script(relative_path, (0, 1, 2)))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(harness.python_calls()), 1)

    def test_the_codex_search_is_scoped_to_this_skill(self):
        # A `find` matching any census.py under the plugin cache would resolve
        # another command's helper. Only the decoy is installed here, so a
        # search that resolved anything at all resolved the wrong thing.
        harness = self.harness("codex", install_helper=False, decoy_helper=True)
        result = harness.run(
            self.script(CODEX_ASSET, (0,)) + '\nprintf "%s" "$CENSUS"\n'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("project-review", result.stdout)


class CensusInvocationTests(HarnessCase):
    """The first pass and the pre-apply refresh ask the same question, with
    exactly the arguments the program accepts."""

    def expected_argv(self, harness: Harness) -> list[str]:
        census = (
            harness.installed_census
            if harness.brand == "claude"
            else harness.cached_census
        )
        return [str(census), "--repo", CHECKOUT_ROOT, "--fetch"]

    def test_the_first_pass_passes_the_checkout_and_a_fetch(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                harness = self.harness(BRAND_OF[relative_path])
                result = harness.run(self.script(relative_path, (0, 1, 2)))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    harness.python_calls(), [self.expected_argv(harness)]
                )

    def test_the_pre_apply_refresh_repeats_it_exactly(self):
        # Requirement 3 asks for `--fetch` on the first pass and before
        # applying, and §5's whole point is that the gates are rechecked
        # against current state: a refresh that asked a narrower question
        # would recheck them against a different repository view.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                harness = self.harness(BRAND_OF[relative_path])
                result = harness.run(self.script(relative_path, (0, 1, 9)))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    harness.python_calls(), [self.expected_argv(harness)]
                )
                fences = self.fences(relative_path)
                self.assertEqual(fences["census-first"], fences["census-refresh"])

    def test_every_option_passed_is_one_the_program_accepts(self):
        # "and nothing it does not accept", measured against the shipped
        # program's own --help rather than against a list restated here.
        for relative_path in RENDERED_ASSETS:
            brand = BRAND_OF[relative_path]
            with self.subTest(asset=relative_path):
                accepted = census_option_names(brand)
                self.assertIn("--repo", accepted)
                self.assertIn("--fetch", accepted)
                fences = self.fences(relative_path)
                for name in ("census-first", "census-refresh"):
                    passed = set(re.findall(r"(--[a-z][a-z0-9-]*)", fences[name]))
                    self.assertEqual(passed, {"--repo", "--fetch"})
                    self.assertEqual(passed - accepted, set())

    def test_the_control_would_notice_an_unaccepted_option(self):
        # Non-vacuity: the program really does refuse an option the body could
        # have grown, so the equality above is a constraint rather than a
        # coincidence.
        for brand, program in sorted(CENSUS_PROGRAMS.items()):
            with self.subTest(brand=brand):
                self.assertNotIn("--prune", census_option_names(brand))
                result = subprocess.run(
                    [sys.executable, str(REPO_ROOT / program), "--prune"],
                    capture_output=True,
                    text=True,
                    stdin=subprocess.DEVNULL,
                )
                self.assertNotEqual(result.returncode, 0)


class MutationBoundaryTests(HarnessCase):
    """Nothing is mutated before the report-and-stop."""

    def test_the_report_pass_makes_no_mutation(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                harness = self.harness(BRAND_OF[relative_path])
                result = harness.run(self.script(relative_path, PRE_APPROVAL_FENCES))
                self.assertEqual(result.returncode, 0, result.stderr)
                git_calls = harness.git_calls()
                self.assertTrue(git_calls, "the report pass read nothing at all")
                for label, needle in sorted(GIT_MUTATIONS.items()):
                    self.assertFalse(
                        any(contains_run(call, needle) for call in git_calls),
                        f"the report pass ran `git` to {label}",
                    )
                for label, needle in sorted(GH_MUTATIONS.items()):
                    self.assertFalse(
                        any(contains_run(call, needle) for call in harness.gh_calls()),
                        f"the report pass ran `gh` to {label}",
                    )

    def test_the_control_reaches_every_mutation_once_approved(self):
        # Non-vacuity for the absences above: run the apply fences too, and
        # each of the nine appears. An absence nothing can produce is not an
        # assertion.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                harness = self.harness(BRAND_OF[relative_path])
                result = harness.run(
                    self.script(relative_path, PRE_APPROVAL_FENCES + APPLY_FENCES)
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                git_calls = harness.git_calls()
                for label, needle in sorted(GIT_MUTATIONS.items()):
                    self.assertTrue(
                        any(contains_run(call, needle) for call in git_calls),
                        f"the apply pass never ran `git` to {label}",
                    )
                for label, needle in sorted(GH_MUTATIONS.items()):
                    self.assertTrue(
                        any(contains_run(call, needle) for call in harness.gh_calls()),
                        f"the apply pass never ran `gh` to {label}",
                    )

    def test_the_verification_prune_is_a_dry_run(self):
        # The one read that shares its words with a mutation. It has to reach
        # `git` as a dry run, or the report pass above would be mutating while
        # the contiguity rule reported it clean.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                harness = self.harness(BRAND_OF[relative_path])
                harness.run(self.script(relative_path, PRE_APPROVAL_FENCES))
                self.assertTrue(
                    any(
                        contains_run(call, ["worktree", "prune", "--dry-run"])
                        for call in harness.git_calls()
                    )
                )

    def test_the_fast_forward_runs_where_the_default_branch_is_checked_out(self):
        # Resolved from the porcelain listing, never assumed to be `$ROOT`: a
        # `--ff-only` merge run in the wrong worktree moves the wrong branch.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                harness = self.harness(BRAND_OF[relative_path])
                result = harness.run(
                    self.script(relative_path, (0, 1, 13))
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                merges = [
                    call
                    for call in harness.git_calls()
                    if contains_run(call, ["merge", "--ff-only"])
                ]
                self.assertEqual(len(merges), 1)
                self.assertEqual(merges[0][:2], ["-C", PRIMARY_WORKTREE])
                self.assertNotEqual(PRIMARY_WORKTREE, CHECKOUT_ROOT)


class PerItemApprovalTests(HarnessCase):
    """Every apply-path command reaches the approved item and nothing else.

    A partial approval is the ordinary result of §4 -- the user takes one group
    or three ids out of a longer report -- so a command that also reaches an
    unapproved item destroys state nobody agreed to lose, while the run reports
    success.
    """

    def test_the_metadata_prune_refuses_an_unapproved_record(self):
        # `git worktree prune` has no per-record form, so the body gates it on
        # every record the dry run names being approved. Here the dry run names
        # two and only one is approved.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                harness = self.harness(
                    BRAND_OF[relative_path], approved_records=(PRUNABLE_RECORDS[0],)
                )
                result = harness.run(self.script(relative_path, (0, 1, 11)))
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(
                    any(
                        contains_run(call, ["worktree", "prune", "--expire"])
                        for call in harness.git_calls()
                    ),
                    "the prune ran even though it would remove an unapproved record",
                )

    def test_the_metadata_prune_runs_when_every_record_is_approved(self):
        # The control: the same fence, the same listing, the whole set
        # approved. Without it the refusal above would pass over a gate that
        # refuses everything.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                harness = self.harness(BRAND_OF[relative_path])
                result = harness.run(self.script(relative_path, (0, 1, 11)))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(
                    any(
                        contains_run(call, ["worktree", "prune", "--expire"])
                        for call in harness.git_calls()
                    )
                )

    def test_an_empty_approval_refuses_the_prune(self):
        # Nothing approved is not everything approved. `grep -vxF ""` matches
        # every non-empty line, so the subtraction leaves the whole listing.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                harness = self.harness(BRAND_OF[relative_path], approved_records=())
                result = harness.run(self.script(relative_path, (0, 1, 11)))
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(
                    any(
                        contains_run(call, ["worktree", "prune", "--expire"])
                        for call in harness.git_calls()
                    )
                )

    def test_a_stale_tracking_ref_is_deleted_one_ref_at_a_time(self):
        # `git fetch --prune origin` would remove every stale tracking ref,
        # including refs this run never reported. The body deletes the reported
        # one by name, with the value the report recorded.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                harness = self.harness(BRAND_OF[relative_path])
                result = harness.run(self.script(relative_path, (0, 1, 10)))
                self.assertEqual(result.returncode, 0, result.stderr)
                deletions = [
                    call
                    for call in harness.git_calls()
                    if contains_run(call, ["update-ref", "-d"])
                ]
                self.assertEqual(len(deletions), 2)
                self.assertIn(
                    ["-C", CHECKOUT_ROOT, "update-ref", "-d", TRACKING_REF, TRACKING_SHA],
                    deletions,
                )
                self.assertIn(
                    ["-C", CHECKOUT_ROOT, "update-ref", "-d", REF, REF_SHA],
                    deletions,
                )

    def test_no_fence_reaches_for_a_bulk_operation(self):
        # Asserted over the fences rather than the whole file, because the
        # prose names both of these deliberately, to say why they are not used.
        for relative_path in RENDERED_ASSETS:
            fences = "\n".join(bash_fences(read(relative_path)))
            for label, spelling in sorted(FORBIDDEN_IN_FENCES.items()):
                with self.subTest(asset=relative_path, forbidden=label):
                    self.assertNotIn(spelling, fences)
            with self.subTest(asset=relative_path, prose="the reason is given"):
                self.assertEqual(
                    missing(
                        read(relative_path),
                        (
                            "`git fetch --prune origin` would additionally remove "
                            "every other ref that happens to be stale",
                            "never with a bare `--delete`",
                        ),
                    ),
                    [],
                )

    def test_a_claim_release_is_two_independent_commands(self):
        # A `wip`-only claim has no assignee to remove. Run the label command
        # alone and prove it is a complete release on its own.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                fence = self.fences(relative_path)["claim-release"]
                label_line = [
                    line for line in fence.splitlines() if "--remove-label" in line
                ]
                self.assertEqual(len(label_line), 1)
                harness = self.harness(BRAND_OF[relative_path])
                result = harness.run(
                    self.script(relative_path, (0, 1)) + "\n" + label_line[0]
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = harness.gh_calls()
                self.assertEqual(len(calls), 1)
                self.assertIn("--remove-label", calls[0])
                self.assertNotIn("--remove-assignee", calls[0])

    def test_no_single_call_assumes_an_assignee_and_a_label(self):
        # The defect the split closes: one call carrying both flags fails on a
        # label-only claim before it reaches the label, leaving the claim in
        # place while the run reports it released.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                for call in gh_invocations(read(relative_path)):
                    if "issue edit" not in call:
                        continue
                    with self.subTest(call=call):
                        self.assertFalse(
                            "--remove-assignee" in call and "--remove-label" in call,
                            "one call cannot serve a label-only claim and an "
                            "assigned one",
                        )
                self.assertEqual(
                    missing(
                        read(relative_path),
                        (
                            "Run the first once per assignee the census recorded, "
                            "and the second only when the issue actually carries "
                            "`wip`.",
                            "A claim with several assignees needs one removal each",
                        ),
                    ),
                    [],
                )


class RemoteDeletionLeaseTests(HarnessCase):
    """The remote deletion is driven against a real Git remote.

    `ls-remote` proving the branch exists at a SHA is a read, and a read is
    stale the instant it returns. The only thing that makes the proof and the
    deletion describe one commit is the lease on the push, so it is asserted by
    moving the branch between the two and watching the push refuse.
    """

    def push_line(self, relative_path: str) -> str:
        fence = self.fences(relative_path)["deletions"]
        lines = [line for line in fence.splitlines() if " push origin " in line]
        self.assertEqual(len(lines), 1, "expected exactly one remote deletion")
        return lines[0]

    def build(self, root: Path) -> tuple[Path, str]:
        """A remote with `master` and `feature`, and `feature`'s recorded tip."""
        remote = root / "remote.git"
        work = root / "work"
        env = isolated_git_env(root)
        self.git_env = env

        def git(*args, cwd=None):
            result = subprocess.run(
                ["git", *args],
                cwd=str(cwd) if cwd else None,
                env=env,
                capture_output=True,
                text=True,
                stdin=subprocess.DEVNULL,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout

        git("init", "-q", "--bare", "-b", DEFAULT_BRANCH, str(remote))
        git("init", "-q", "-b", DEFAULT_BRANCH, str(work))
        (work / "a").write_text("a\n", encoding="utf-8")
        git("add", "a", cwd=work)
        git("commit", "-qm", "one", cwd=work)
        git("remote", "add", "origin", str(remote), cwd=work)
        git("push", "-q", "-u", "origin", DEFAULT_BRANCH, cwd=work)
        git("checkout", "-qb", BRANCH, cwd=work)
        (work / "b").write_text("b\n", encoding="utf-8")
        git("add", "b", cwd=work)
        git("commit", "-qm", "two", cwd=work)
        git("push", "-q", "-u", "origin", BRANCH, cwd=work)
        recorded = git("rev-parse", BRANCH, cwd=work).strip()
        return work, recorded

    def remote_heads(self, work: Path) -> str:
        return subprocess.run(
            ["git", "ls-remote", "--heads", "origin"],
            cwd=str(work),
            env=self.git_env,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
        ).stdout

    def push(self, relative_path: str, work: Path, sha: str):
        script = "set -e\n" + self.push_line(relative_path)
        env = dict(self.git_env)
        env.update({"ROOT": str(work), "BRANCH": BRANCH, "SHA": sha})
        return subprocess.run(
            ["sh", "-c", script],
            env=env,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
        )

    def test_a_branch_that_moved_after_the_proof_is_not_deleted(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                root = self.temporary_directory()
                work, recorded = self.build(root)
                # Someone pushes to the branch between the `ls-remote` proof
                # and the apply. The recorded SHA is now stale.
                (work / "c").write_text("c\n", encoding="utf-8")
                subprocess.run(
                    ["git", "add", "c"], cwd=str(work), env=self.git_env, check=True
                )
                subprocess.run(
                    ["git", "commit", "-qm", "three"],
                    cwd=str(work),
                    env=self.git_env,
                    check=True,
                )
                subprocess.run(
                    ["git", "push", "-q", "origin", BRANCH],
                    cwd=str(work),
                    env=self.git_env,
                    check=True,
                )
                moved = subprocess.run(
                    ["git", "rev-parse", BRANCH],
                    cwd=str(work),
                    env=self.git_env,
                    capture_output=True,
                    text=True,
                ).stdout.strip()
                self.assertNotEqual(moved, recorded)

                result = self.push(relative_path, work, recorded)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"refs/heads/{BRANCH}", self.remote_heads(work))

    def test_a_branch_still_at_the_recorded_tip_is_deleted(self):
        # The control: the same line, the same repository, nothing moved.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                root = self.temporary_directory()
                work, recorded = self.build(root)
                result = self.push(relative_path, work, recorded)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn(f"refs/heads/{BRANCH}", self.remote_heads(work))


class RealGitApplyTests(HarnessCase):
    """The two apply-path gates, driven against Git itself.

    Both exist because a scripted `git` can only answer the question the
    scenario already believes: the metadata-prune gate reads a diagnostic Git
    writes to *stderr*, and the stash drop names a reflog position that shifts
    under any other writer. A fixture that put the listing on stdout, or that
    never pushed a competing stash, would let both gates pass here while
    destroying unapproved state in a real repository. These run in a plain
    `sh -c` with no `set -e`, which is the shell an agent actually has.
    """

    def git(self, *args, cwd=None, env=None, check=True):
        result = subprocess.run(
            ["git", *args],
            cwd=str(cwd) if cwd else None,
            env=env or self.git_env,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
        )
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def repository(self) -> Path:
        root = self.temporary_directory()
        self.git_env = isolated_git_env(root)
        work = root / "work"
        self.git("init", "-q", "-b", DEFAULT_BRANCH, str(work))
        (work / "a").write_text("a\n", encoding="utf-8")
        self.git("add", "a", cwd=work)
        self.git("commit", "-qm", "one", cwd=work)
        return work

    def run_fence(self, fence: str, work: Path, **variables):
        """`fence` under a plain `sh -c`, with no errexit."""
        env = dict(self.git_env)
        env["ROOT"] = str(work)
        env.update(variables)
        return subprocess.run(
            ["sh", "-c", fence],
            env=env,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
        )

    def prunable_repository(self) -> tuple[Path, list[str]]:
        """A repository with two registered worktree records whose
        directories are gone, so the dry run names both."""
        work = self.repository()
        names = ["record-one", "record-two"]
        for name in names:
            self.git("worktree", "add", "-q", str(work.parent / name), "-b", name,
                     cwd=work)
        for name in names:
            shutil.rmtree(work.parent / name)
        listing = self.git(
            "worktree", "prune", "--dry-run", "--expire", "now", "--verbose", cwd=work
        )
        # The premise of the whole gate, asserted rather than assumed: Git puts
        # these lines on stderr, and a gate reading stdout sees nothing.
        self.assertEqual(listing.stdout, "")
        for name in names:
            self.assertIn(f"Removing worktrees/{name}", listing.stderr)
        return work, names

    def registered_records(self, work: Path) -> set[str]:
        porcelain = self.git("worktree", "list", "--porcelain", cwd=work).stdout
        return {
            Path(line[len("worktree ") :]).name
            for line in porcelain.splitlines()
            if line.startswith("worktree ")
        }

    def test_a_prune_that_would_reach_an_unapproved_record_is_refused(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                work, names = self.prunable_repository()
                before = self.registered_records(work)
                result = self.run_fence(
                    self.fences(relative_path)["metadata-prune"],
                    work,
                    APPROVED_RECORDS=names[0],
                )
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.registered_records(work), before)

    def test_a_prune_whose_records_are_all_approved_runs(self):
        # The control. Without it the refusal above would pass over a gate
        # that reads an empty listing and refuses everything, which is the
        # other way to be wrong about stderr.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                work, names = self.prunable_repository()
                result = self.run_fence(
                    self.fences(relative_path)["metadata-prune"],
                    work,
                    APPROVED_RECORDS="\n".join(names),
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.registered_records(work), {work.name})

    def stash_drop_lines(self, relative_path: str) -> str:
        """The guarded stash drop, both of its lines."""
        fence = self.fences(relative_path)["deletions"].splitlines()
        index = [
            position
            for position, line in enumerate(fence)
            if "rev-parse --verify --quiet" in line
        ]
        self.assertEqual(len(index), 1)
        guard = index[0]
        self.assertIn("stash drop", fence[guard + 1])
        return "\n".join(fence[guard : guard + 2])

    def stash_entries(self, work: Path) -> list[str]:
        listing = self.git("stash", "list", "--format=%H", cwd=work).stdout
        return [line for line in listing.splitlines() if line.strip()]

    def push_stash(self, work: Path, name: str) -> str:
        (work / name).write_text(name + "\n", encoding="utf-8")
        self.git("add", name, cwd=work)
        self.git("stash", "push", "-q", "-m", name, cwd=work)
        return self.git("rev-parse", "stash@{0}", cwd=work).stdout.strip()

    def test_a_stash_pushed_after_the_report_is_not_dropped(self):
        # The selector the report recorded now names somebody else's stash.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                work = self.repository()
                approved = self.push_stash(work, "approved")
                # Another writer -- a person, or the drainer's autostash --
                # pushes between the report and the apply, shifting every
                # selector down by one.
                intruder = self.push_stash(work, "intruder")
                self.assertNotEqual(approved, intruder)
                self.assertEqual(self.stash_entries(work), [intruder, approved])

                result = self.run_fence(
                    self.stash_drop_lines(relative_path),
                    work,
                    STASH="stash@{0}",
                    STASH_SHA=approved,
                )
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.stash_entries(work), [intruder, approved])

    def test_a_stash_still_at_its_recorded_object_is_dropped(self):
        # The control: nothing moved, and the approved stash goes.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                work = self.repository()
                approved = self.push_stash(work, "approved")
                result = self.run_fence(
                    self.stash_drop_lines(relative_path),
                    work,
                    STASH="stash@{0}",
                    STASH_SHA=approved,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.stash_entries(work), [])


class RepositoryScopeTests(unittest.TestCase):
    """Every `gh` call names the repository this run resolved."""

    def test_the_assets_make_exactly_the_declared_calls(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                calls = gh_invocations(read(relative_path))
                self.assertEqual(len(calls), DECLARED_GH_CALL_COUNT)
                self.assertEqual(
                    sorted(calls),
                    sorted(REPOSITORY_SCOPED_CALLS + PATH_SCOPED_CALLS),
                )

    def test_every_call_is_bound_to_the_resolved_repository(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                text = read(relative_path)
                self.assertIn(REPOSITORY_RESOLUTION, text)
                for call in gh_invocations(text):
                    with self.subTest(call=call):
                        self.assertTrue(
                            REPOSITORY_SCOPE in call or "repos/$REPO/" in call,
                            f"{call} names no repository",
                        )

    def test_a_planted_unscoped_call_is_caught(self):
        # The control. A rule over "every `gh` call" would pass over an asset
        # that made none, and would pass over one whose calls all happened to
        # be scoped; this proves the scan sees an unscoped call as one.
        planted = 'Run:\n\n```bash\ngh pr list --state open --json number\n```\n'
        calls = gh_invocations(planted)
        self.assertEqual(len(calls), 1)
        self.assertNotIn(REPOSITORY_SCOPE, calls[0])
        self.assertNotIn("repos/$REPO/", calls[0])

    def test_the_repository_is_resolved_once_and_announced(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                text = read(relative_path)
                self.assertEqual(text.count(REPOSITORY_RESOLUTION), 1)
                self.assertEqual(
                    missing(
                        text,
                        (
                            "Name the resolved `$REPO` and `$ROOT` before the "
                            "first census run, and never re-resolve either "
                            "afterwards.",
                        ),
                    ),
                    [],
                )


# The five `all-safe` gates, each with every condition it requires and the
# near-miss it names. Enumerated rather than summarized: `all-safe` is bulk
# approval, so a gate that lost a condition would widen what gets destroyed
# without a second look, and a summary assertion would not notice.
ALL_SAFE_GATES = {
    "worktree removal": {
        "conditions": (
            "the exact registered path from the porcelain listing",
            "not a repository-declared permanent worktree",
            "no operation in progress",
            "an empty status *including untracked files*",
            "a terminal target",
            "a HEAD merged into the remote default branch",
        ),
        "near_miss": (
            "*Near-miss:* a worktree whose only dirt is untracked files has a "
            "non-empty status and stays item-level."
        ),
    },
    "branch deletion": {
        "conditions": (
            "no worktree and no open PR",
            "the full SHA recorded",
            "the tip merged into the remote default branch",
            "`ls-remote` additionally proves the branch still exists at that SHA",
            "the deletion carries that SHA as a `--force-with-lease` so the proof "
            "and the push describe one commit",
            "remote deletions go **one push per branch**",
        ),
        "near_miss": (
            "*Near-miss:* a tip merged into the local default branch but not "
            "into the remote one is unmerged for this gate"
        ),
    },
    "review metadata prune": {
        "conditions": (
            "the directory is already missing *and* the `--expire now` dry run "
            "names it",
        ),
        "near_miss": (
            "*Near-miss:* an entry the dry run does not name is still "
            "registered, whatever the filesystem suggests."
        ),
    },
    "tracking-ref prune": {
        "conditions": ("`ls-remote` proves the origin head absent",),
        "near_miss": (
            "*Near-miss:* a `refs/remotes/` entry with no local branch proves "
            "nothing on its own"
        ),
    },
    "default fast-forward": {
        "conditions": (
            "a clean default worktree",
            "no operation in progress",
            "the local branch not ahead",
            "the drainer reporting no active operation",
        ),
        "near_miss": (
            "*Near-miss:* a default branch that is ahead or diverged needs "
            "diagnosis"
        ),
    },
}

# What bulk approval never covers, one phrase per excluded class.
ALL_SAFE_EXCLUSIONS = (
    "Dirty or unmerged work",
    "limbo worktrees",
    "permanent-worktree content",
    "every recovery object",
    "coordinated-test worktrees",
    "unknown branches and unknown review targets",
    "any ambiguous disposition",
    "**excluded from `all-safe`**",
    "always require item-level approval",
    '"Keep; no remediation" is a valid result.',
)


class PreservationGateTests(unittest.TestCase):
    """Every gate, every condition, and the near-miss each one names."""

    def test_every_gate_states_all_of_its_conditions(self):
        for relative_path in RENDERED_ASSETS:
            text = read(relative_path)
            for gate, contract in sorted(ALL_SAFE_GATES.items()):
                with self.subTest(asset=relative_path, gate=gate):
                    self.assertEqual(missing(text, contract["conditions"]), [])

    def test_every_gate_names_its_near_miss(self):
        for relative_path in RENDERED_ASSETS:
            text = read(relative_path)
            for gate, contract in sorted(ALL_SAFE_GATES.items()):
                with self.subTest(asset=relative_path, gate=gate):
                    self.assertEqual(missing(text, (contract["near_miss"],)), [])

    def test_deleting_a_condition_or_near_miss_is_detected(self):
        # The control, per gate and per condition rather than once: a rule that
        # only noticed a wholly missing section would pass an asset that had
        # quietly dropped one condition, which is exactly how bulk approval
        # widens. Every occurrence is removed, because two gates legitimately
        # share a condition -- neither a worktree nor the default branch is
        # touched while an operation is in progress -- and a planted deletion
        # of one of them is not a deletion of the rule.
        text = read(CLAUDE_ASSET)
        for gate, contract in sorted(ALL_SAFE_GATES.items()):
            for phrase in (*contract["conditions"], contract["near_miss"]):
                with self.subTest(gate=gate, phrase=phrase):
                    self.assertEqual(missing(text, (phrase,)), [])
                    planted = flat(text).replace(flat(phrase), "")
                    self.assertNotEqual(missing(planted, (phrase,)), [])

    def test_bulk_approval_states_what_it_excludes(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertEqual(missing(read(relative_path), ALL_SAFE_EXCLUSIONS), [])

    def test_one_unproved_fact_disqualifies_rather_than_warning(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertEqual(
                    missing(
                        read(relative_path),
                        (
                            "One unproved fact disqualifies the item and moves "
                            "it to item-level approval; it never downgrades to "
                            "a warning.",
                        ),
                    ),
                    [],
                )


# The retention ledger's contract, from design D-14. It is machine-local state
# nothing reviews, so the rules that bound it are the only thing standing
# between a "keep this" note and an exemption from every gate above.
RETENTION_LEDGER_CONTRACT = (
    "The retention ledger is a reminder, not an exemption",
    "Revalidate each recorded target and its `review_when` condition on every run.",
    "Report a stale or contradicted entry as a decision",
    "never silently discard the entry or the state it retains",
    "add one concise item with a stable id, target, disposition, reason, and "
    "review condition",
    "Update or remove an item only with approval, or after its recorded "
    "condition is proved.",
    "**No ledger mutation happens before explicit approval**",
    "`janitor-retain.json` from the Git common directory",
)


class RetentionLedgerTests(unittest.TestCase):
    def test_the_ledger_contract_survives_in_both_renderings(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertEqual(
                    missing(read(relative_path), RETENTION_LEDGER_CONTRACT), []
                )

    def test_the_control_catches_a_dropped_clause(self):
        text = read(CODEX_ASSET)
        for phrase in RETENTION_LEDGER_CONTRACT:
            with self.subTest(phrase=phrase):
                planted = flat(text).replace(flat(phrase), "")
                self.assertNotEqual(missing(planted, (phrase,)), [])

    def test_the_ledger_location_is_the_one_the_program_reads(self):
        # D-14 puts the ledger in the Git common directory, and the shipped
        # census is what reads it. One spelling, read from the program.
        for brand, program in sorted(CENSUS_PROGRAMS.items()):
            with self.subTest(brand=brand):
                self.assertIn(
                    'RETAIN_LEDGER = "janitor-retain.json"',
                    read(program),
                )


# The `null`-is-not-empty rule, which is the whole reason the census reports a
# failed inspection as `null` rather than as an empty collection.
NULL_RULE = (
    "**A `null` or unavailable collection is an anomaly, never a clean result.**",
    "An unreadable worktree is not a clean one, and an unreadable retain "
    "ledger is not an empty one.",
    "Report the failure as its own item; never let it collapse into "
    '"nothing to clean".',
)


class NullIsNotEmptyTests(unittest.TestCase):
    def test_the_rule_survives_in_both_renderings(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertEqual(missing(read(relative_path), NULL_RULE), [])

    def test_the_control_catches_a_dropped_clause(self):
        text = read(CLAUDE_ASSET)
        for phrase in NULL_RULE:
            with self.subTest(phrase=phrase):
                planted = flat(text).replace(flat(phrase), "")
                self.assertNotEqual(missing(planted, (phrase,)), [])

    def test_the_body_names_the_schema_the_program_emits(self):
        # The rule is about a shape the shipped program really produces, not
        # an invented one: the census names its document `janitor-census/v1`
        # and reports a failed inspection as `null`.
        for brand, program in sorted(CENSUS_PROGRAMS.items()):
            with self.subTest(brand=brand):
                self.assertIn('"schema": "janitor-census/v1"', read(program))
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertIn("`janitor-census/v1`", read(relative_path))


# The Claude copy's judgement, which requirement 6 keeps rather than discards,
# and the recovery rule that stands in for the two `references/` files D-13
# leaves unshipped.
FOLDED_JUDGEMENT = {
    "a stash is judged by its own delta": (
        "Judge a stash by its own delta and never by diffing its files "
        "against the current branch"
    ),
    "why an old stash looks huge": (
        "a months-old stash shows thousands of changed lines merely because "
        "the branch moved on, which says nothing about whether its work is lost"
    ),
    "the comparison is normalized": (
        "with list numbering, emphasis, and whitespace normalized"
    ),
    "rewrapped prose is not lost content": (
        "prose that was rewrapped, or a list item renumbered from `5.` to "
        "`6.`, is the same content"
    ),
    "an unlanded line may be superseded": (
        "A line that genuinely never landed may still be superseded rather "
        "than missing"
    ),
    "why that matters": (
        "reinstating a superseded sentence puts a false statement back into "
        "the documentation"
    ),
    "the surviving classification": (
        "Classify each object as `fully landed`, `unlanded content` (quote "
        "the lines), or `contradicted by current behavior` (cite what "
        "supersedes it)"
    ),
    "one push per branch, and why": (
        "one already-gone branch name aborts an entire multi-branch "
        "`git push origin --delete` client-side"
    ),
    "every recovery object is a possible last copy": (
        "**Recovery objects — every one is a possible last copy of work.** "
        "Age is evidence of neglect, never evidence that content is "
        "expendable."
    ),
    "the autostash anchor may be the only copy": (
        "a kept autostash anchor under `refs/drain-prs/autostash/<sha>` may "
        "be the only named copy when no stash points at the same commit"
    ),
    "a holding directory is reconciled file by file": (
        "a `.git/autostash-*` holding directory is reconciled file by file, "
        "never removed as a unit"
    ),
    "no seed or write mode during an audit": (
        "**Run no seed, write, install, or repair mode of any producer during "
        "an audit**"
    ),
    "a permanent worktree is still audited": (
        "A permanent worktree is exempt from removal, not from content "
        "auditing"
    ),
    "state does not become source to quiet git status": (
        "Locks, leases, caches, and recovery artifacts do not become source "
        "merely to silence `git status`"
    ),
}

# What the recovery rule replaces, and what it does not. D-13 drops the two
# `references/` files rather than vendoring them, so neither bundle may grow a
# `references/` directory.
REFERENCES_DIRECTORIES = (
    "claude-plugin/plugins/kanban/commands/references",
    "codex-plugin/plugins/kanban/skills/janitor/references",
)


class FoldedJudgementTests(unittest.TestCase):
    def test_the_surviving_judgement_is_in_both_renderings(self):
        for relative_path in RENDERED_ASSETS:
            text = read(relative_path)
            for label, phrase in sorted(FOLDED_JUDGEMENT.items()):
                with self.subTest(asset=relative_path, rule=label):
                    self.assertEqual(missing(text, (phrase,)), [])

    def test_the_control_catches_a_dropped_rule(self):
        text = read(CLAUDE_ASSET)
        for label, phrase in sorted(FOLDED_JUDGEMENT.items()):
            with self.subTest(rule=label):
                planted = flat(text).replace(flat(phrase), "")
                self.assertNotEqual(missing(planted, (phrase,)), [])

    def test_neither_bundle_gains_a_references_directory(self):
        for relative in REFERENCES_DIRECTORIES:
            with self.subTest(directory=relative):
                self.assertFalse((REPO_ROOT / relative).exists())

    def test_the_assets_link_no_auxiliary_file(self):
        # The two `references/` files the Codex copy linked do not ship, so a
        # surviving link would point an executing agent at nothing.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                text = read(relative_path)
                self.assertNotIn("references/", text)
                self.assertNotIn("recovery-state.md", text)
                self.assertNotIn("worktree-content.md", text)


# The compact-census discipline: what a first pass must not do. Kept because it
# is the difference between an audit and a rate-limit incident, and it lives
# only in the Codex copy.
COMPACT_CENSUS_RULES = (
    "**Keep the first pass small.**",
    "Do not fetch PR bodies, issue titles, comments, checks, logs, full "
    "diffs, or stash patches in bulk.",
    "Do not enumerate ignored files globally, scan shared worktree roots, or "
    "crawl `.git`",
    "Target only the candidates the census named, one targeted read each.",
)


class CompactCensusTests(unittest.TestCase):
    def test_the_discipline_survives_in_both_renderings(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertEqual(
                    missing(read(relative_path), COMPACT_CENSUS_RULES), []
                )

    def test_the_control_catches_a_dropped_rule(self):
        text = read(CODEX_ASSET)
        for phrase in COMPACT_CENSUS_RULES:
            with self.subTest(phrase=phrase):
                planted = flat(text).replace(flat(phrase), "")
                self.assertNotEqual(missing(planted, (phrase,)), [])

    def test_the_report_stops_for_approval(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertEqual(
                    missing(
                        read(relative_path),
                        (
                            "State explicitly what `all-safe` excludes, then "
                            "**stop for approval and touch nothing**.",
                            "Group them as `retain/decision`, `safe cleanup`, "
                            "and `pipeline attention`",
                            "report applied, skipped, failed, and remaining "
                            "items",
                        ),
                    ),
                    [],
                )


class ShellPortabilityTests(unittest.TestCase):
    """Every fence parses in every shell installed here.

    `sh` is a different program per platform -- bash 3.2 on macOS, dash on most
    Linux -- and an asset is the program an agent executes, so a fence that
    only parses under one of them is a rendering that fails on the other host.
    """

    SHELLS = tuple(
        name for name in ("sh", "bash", "dash", "zsh") if shutil.which(name)
    )

    def test_shells_are_available(self):
        self.assertTrue(self.SHELLS)

    def test_every_fence_parses(self):
        for relative_path in RENDERED_ASSETS:
            for name, fence in sorted(named_fences(read(relative_path)).items()):
                for shell in self.SHELLS:
                    with self.subTest(asset=relative_path, fence=name, shell=shell):
                        result = subprocess.run(
                            [shell, "-n"],
                            input=fence,
                            capture_output=True,
                            text=True,
                        )
                        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
