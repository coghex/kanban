"""The vendored drain-prs workflow's own behavioral contract.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 tools/test_drain_prs_workflow.py

Issue #511, slice VEND-5 of `docs/workflow_command_vendoring_design.md`. Unlike
the four slices before it, the reconciliation here was mostly against this
repository rather than against the other brand: both personal copies described a
drainer that no longer exists, and both tracked two of the owner's private
identifiers. So the assertions below fall into three kinds, and each fails for a
different reason.

* **What the drainer actually does now.** The removed conflict cross-review
  loop, its five-round cap, "only Claude may restore `reviewed:approve`", and
  `DRAIN_PRS_CLAUDE_REVIEW_MODEL` are pinned as absences, and what replaced each
  is pinned as text: one open per-PR incident that touches no label and creates
  no worktree, and one agent spawn per drain cycle resolved from the
  `drain_rereview` cell the roster's operating mode selects -- the codex cell in
  dual mode, the sole loaded provider's cell in single-agent mode, and no spawn
  at all in no-agent mode, where the drainer keeps merging and records a
  `no-agent-mode` incident for the one pull request it cannot rereview (issue
  #572). An asset is the program an agent executes top to bottom, so a stale
  claim left in it is a stale instruction, not a stale comment.

  `RETIRED_CLAIMS` keeps pinning the literal display name `Claude Opus 5` as an
  ABSENCE even though the roster's `drain_rereview.claude` cell now resolves to
  that model in a Claude-only install. The retired claim was a *standing* Claude
  reviewer this drainer does not have; the roster-selected one is named by its
  cell rather than by a model literal, which is why the rendered text describes
  the provider and the cell and never spells a Claude model out.
* **The portable controller resolution.** Requirement 3, and the one rule here
  that a string comparison would under-test: both copies hardcoded a macOS path,
  which ignores `KANBAN_DRAINER_INSTALL_DIR`, ignores an `--install-dir`
  install, and finds nothing on a host whose managed job lives under the XDG
  data root. `ControllerResolutionTests` runs the rendered block under `sh` in
  five environments and asserts where each lands, so the assertion is the
  behavior rather than the spelling.
* **No GitHub call, and both scoping flags on every controller invocation.**
  Requirements 8 and 9. This is the one vendored workflow whose whole reach is
  the installed controller, so `gh`'s absence is asserted directly, and the
  scoping obligation lands on `python3 "$CONTROL"` instead: every executable
  invocation line carries `--path "$ROOT"` for the checkout and `--repo "$REPO"`
  for the `owner/name`. The path variable is deliberately not named `REPO` --
  both personal copies did that, and the controller now has a real `--repo` flag
  that means something else.

The rest is D-2's preserved behavior (requirement 15): the per-repository
control model, the incident-belongs-to-its-own-repository caution, the
zero-token idle claim, the do-not-create-a-second-watcher prohibition, the
seven-step recovery procedure, the incident policy, and the
one-incident-is-one-recovery-unit rule are vendored as they read today, so each
is pinned rather than merely rendered.

The negative control is the brand boundary itself: `BrandBoundaryTests` asserts
that stripping the four declared brand-specific lines from each rendering leaves
two byte-identical bodies, so a rule that quietly matched everything could not
also pass there.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import render_command_sources as renderer

REPO_ROOT = Path(__file__).resolve().parent.parent

SOURCE = "tools/command_sources/drain-prs.md"
CLAUDE_ASSET = "claude-plugin/plugins/kanban/commands/drain-prs.md"
CODEX_ASSET = "codex-plugin/plugins/kanban/skills/drain-prs/SKILL.md"
RENDERED_ASSETS = (CLAUDE_ASSET, CODEX_ASSET)

CODEX_SKILL_DIR = "codex-plugin/plugins/kanban/skills/drain-prs"

# The nine control operations design D-7 resolved in the richer Claude copy's
# favour, in the order the rendered body introduces them. The Codex copy
# documented six, missing `install`, `incident` and `ack`; the reconciliation
# gives both brands all nine.
OPERATIONS = (
    "status",
    "install",
    "start",
    "stop",
    "restart",
    "logs [N]",
    "incident [id]",
    "ack [id] [note]",
    "recover",
)

# Controller subcommands that exist but are deliberately not lifecycle
# operations: two the controller suppresses or reserves for the service itself,
# and one whose distinction from a `tools/install_drainer.py` rerun is guidance
# neither personal copy carried.
WITHHELD_SUBCOMMANDS = ("run", "notify-test", "uninstall")

# Requirement 5's retired claims. Every one described a drainer this repository
# had before the conflict repair path was removed and the rereview's model moved
# into the roster, and every one would still read as an instruction.
RETIRED_CLAIMS = {
    "the removed model override": "DRAIN_PRS_CLAUDE_REVIEW_MODEL",
    "the removed cross-review loop": "cross-review",
    "the removed five-round cap": "five review rounds",
    "the false approval-authority claim": "Only Claude may restore",
    # Still an absence, and deliberately so: see the module docstring. The
    # roster-selected Claude rereviewer is named by its `drain_rereview` cell,
    # never by this display literal, so the two cannot be confused in the
    # rendered text.
    "the removed Claude reviewer": "Claude Opus 5",
}

# Requirement 6, against `docs/agent-workflow-contract.md`'s rule that no
# credential, personal model preference, private endpoint, or machine-specific
# path may be tracked as a required asset. `ntfy.sh` is refused as a host rather
# than as the owner's topic, because any hardcoded endpoint is the same defect;
# the tracked mechanism is the `KANBAN_DRAINER_NTFY_URL` override.
PRIVATE_IDENTIFIERS = {
    "a hardcoded notification endpoint": "ntfy.sh",
    "the owner's notification topic": "ntfy.sh/coghex",
    "a path that does not exist": "$HOME/work/",
    "the owner's personal name": "Vincent",
    "the owner-scoped job label": "com.coghex",
}

# Requirement 4. `tools/service_manager.py` drives systemd user units on Linux
# and launchd on macOS behind one boundary, so neither manager is asserted as
# *the* manager anywhere in the rendered text or in either bundle's description
# of this workflow.
SERVICE_MANAGER_NAMES = ("launchd", "systemd", "launchctl", "systemctl")

# The `$XDG_DATA_HOME` substitution `docs/pr-drainer.md` names as the wrong one:
# it honours a relative value, where the installer honours the variable only
# when it is absolute.
REFUSED_XDG_SUBSTITUTION = "${XDG_DATA_HOME:-$HOME/.local/share}"

# The hardcoded controller path both personal copies spelled.
REFUSED_HARDCODED_CONTROL = (
    '"$HOME/Library/Application Support/kanban/pr-drainer/drain_prs_service.py"'
)

# Requirement 8's two scoping flags, and the miswiring it forbids: `--path`
# takes the checkout, never the `owner/name`.
PATH_FLAG = '--path "$ROOT"'
REPO_FLAG = '--repo "$REPO"'
REFUSED_PATH_FLAG = '--path "$REPO"'

# The executable invocation lines the scoping rule is measured over. Counted as
# well as checked: a rule over "every line that invokes the controller" passes
# vacuously if the rendering ever stops invoking it.
CONTROLLER_INVOCATION = 'python3 "$CONTROL"'
CONTROLLER_INVOCATION_COUNT = 11

# A `gh` invocation as an asset would spell one, in a fenced block or inline.
# The lookbehind keeps a `gh` ending a longer word out, and the required
# lowercase subcommand keeps an English sentence about GitHub out.
GH_INVOCATION_RE = re.compile(r"(?<![\w-])gh (?P<tail>[a-z][^\n`]*)")

CLAUDE_ONLY_LINES = (
    "It controls the same managed job Codex controls through `$kanban:drain-prs` —",
    "Parse the first word of `$ARGUMENTS`; default to `status` when it is empty.",
    "- That notification may direct the user to Codex's `$kanban:drain-prs`;",
    "  Claude.",
)

CODEX_ONLY_LINES = (
    "It controls the same managed job Claude controls through `/kanban:drain-prs` —",
    "Take the operation from the user's prompt; default to `status` when none is given.",
    "- That notification may direct the user to Claude's `/kanban:drain-prs`;",
    "  Codex.",
)


def read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def body_of(text: str) -> str:
    """`text` with its frontmatter block removed.

    The frontmatter is the one place the two renderings legitimately differ
    beyond the brand blocks — different keys, and the invocation sigil inside
    the description — so the brand-boundary comparison is made over the body.
    """
    match = re.match(r"\A---\n.*?\n---\n(?P<body>.*)\Z", text, re.DOTALL)
    assert match is not None, "a rendered asset always opens with frontmatter"
    return match.group("body")


# The workflows this source names through a `{{cmd:}}` token. Read from the
# source rather than restated, so the brand comparison below covers exactly the
# substitutions the renderer performs and no more.
REFERENCED_WORKFLOWS = renderer.referenced_names(read(SOURCE))


def neutralize(text: str, brand: str) -> str:
    """`text` with `brand`'s spelling of each declared `{{cmd:}}` target put
    back into the neutral token, so the boundary comparison is made over what
    the one source authored rather than over the substitution."""
    sigil = renderer.SIGILS[brand]
    for name in sorted(REFERENCED_WORKFLOWS, key=len, reverse=True):
        text = text.replace(f"{sigil}{name}", f"{{{{cmd:{name}}}}}")
    return text


def flat(text: str) -> str:
    """`text` with every run of whitespace collapsed to one space, so a phrase
    is found whether or not the source wrapped it across lines."""
    return re.sub(r"\s+", " ", text)


BASH_FENCE_RE = re.compile(r"```bash\n(?P<body>.*?)\n[ \t]*```", re.DOTALL)


def bash_fences(text: str) -> list[str]:
    return [match.group("body") for match in BASH_FENCE_RE.finditer(text)]


def fence_containing(text: str, needle: str) -> str:
    """The one fenced bash block that contains `needle`.

    Exactly one, deliberately: a resolution split across two blocks, or
    duplicated into a second, is a rendering an executing agent could run half
    of.
    """
    matching = [fence for fence in bash_fences(text) if needle in fence]
    assert len(matching) == 1, f"expected one fence containing {needle!r}, got {len(matching)}"
    return matching[0]


def controller_invocation_lines(text: str) -> list[str]:
    """Every line that executes the controller — fenced or inline in prose.

    Requirement 3 necessarily creates a `CONTROL="$DRAINER/drain_prs_service.py"`
    line that carries no flags at all, so the scoping rule is measured over the
    lines that actually run it rather than over every mention of `$CONTROL`.
    """
    return [line for line in text.splitlines() if CONTROLLER_INVOCATION in line]


class RegistrationTests(unittest.TestCase):
    """Requirements 1 and 2: one authored source, two rendered outputs, and
    neither hand-edited."""

    def entry(self) -> renderer.CommandSource:
        matching = [
            entry for entry in renderer.COMMAND_SOURCES if entry.name == "drain-prs"
        ]
        self.assertEqual(len(matching), 1, "drain-prs is registered exactly once")
        return matching[0]

    def test_the_source_renders_into_both_bundle_directories(self):
        entry = self.entry()
        self.assertEqual(entry.source, SOURCE)
        self.assertEqual(
            renderer.output_paths(entry),
            {"claude": CLAUDE_ASSET, "codex": CODEX_ASSET},
        )

    def test_each_rendered_file_is_byte_identical_to_a_fresh_render(self):
        rendered = renderer.render_entry(self.entry(), REPO_ROOT)
        for relative_path, text in rendered.items():
            self.assertEqual(text, read(relative_path), relative_path)

    def test_no_auxiliary_asset_ships_beside_either_rendering(self):
        # Design D-10: this slice ships prose, not a second file. The Codex
        # copy's own `agents/openai.yaml` is preserved in the bundle manifest's
        # interface block instead, and its directory holds the skill alone.
        found = sorted(
            path.name for path in (REPO_ROOT / CODEX_SKILL_DIR).iterdir()
        )
        self.assertEqual(found, ["SKILL.md"])


class ControllerResolutionTests(unittest.TestCase):
    """Requirement 3, asserted as behavior rather than as spelling.

    Both personal copies hardcoded one macOS path. The rendered block is run
    here under `sh` in five environments — the override, an XDG install, an XDG
    root with no install, a relative `$XDG_DATA_HOME`, and nothing set — and
    each is asserted to land where `docs/pr-drainer.md` says it should.
    """

    def resolve(self, fence: str, home: Path, cwd: Path | None = None, **environment: str) -> str:
        script = fence + '\nprintf "%s\\n" "$CONTROL"\n'
        env = {
            "PATH": os.environ.get("PATH", ""),
            "HOME": str(home),
            "KANBAN_DRAINER_INSTALL_DIR": "",
            "XDG_DATA_HOME": "",
        }
        env.update(environment)
        completed = subprocess.run(
            ["sh", "-c", script],
            env=env,
            cwd=None if cwd is None else str(cwd),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=True,
        )
        return completed.stdout.strip()

    def test_each_asset_resolves_the_controller_the_documented_way(self):
        for relative_path in RENDERED_ASSETS:
            fence = fence_containing(read(relative_path), "CONTROL=")
            with tempfile.TemporaryDirectory() as directory:
                home = Path(directory) / "home"
                xdg = Path(directory) / "xdg"
                installed = xdg / "kanban" / "pr-drainer"
                installed.mkdir(parents=True)
                (installed / "config.json").write_text("{}", encoding="utf-8")
                library = home / "Library" / "Application Support" / "kanban"
                library.mkdir(parents=True)
                bare = Path(directory) / "bare"
                bare.mkdir()

                with self.subTest(relative_path=relative_path, case="override"):
                    self.assertEqual(
                        self.resolve(
                            fence,
                            home,
                            KANBAN_DRAINER_INSTALL_DIR=str(bare),
                            XDG_DATA_HOME=str(xdg),
                        ),
                        f"{bare}/drain_prs_service.py",
                        "the environment override wins outright, unprobed",
                    )
                with self.subTest(relative_path=relative_path, case="xdg install"):
                    self.assertEqual(
                        self.resolve(fence, home, XDG_DATA_HOME=str(xdg)),
                        f"{installed}/drain_prs_service.py",
                        "an XDG install is found through its own record",
                    )
                with self.subTest(relative_path=relative_path, case="xdg empty"):
                    self.assertEqual(
                        self.resolve(fence, home, XDG_DATA_HOME=str(bare)),
                        f"{library}/pr-drainer/drain_prs_service.py",
                        "an XDG root holding no record falls through",
                    )
                with self.subTest(relative_path=relative_path, case="xdg relative"):
                    self.assertEqual(
                        self.resolve(fence, home, XDG_DATA_HOME="relative/share"),
                        f"{library}/pr-drainer/drain_prs_service.py",
                        "a relative $XDG_DATA_HOME is not honoured",
                    )
                with self.subTest(relative_path=relative_path, case="nothing set"):
                    self.assertEqual(
                        self.resolve(fence, home),
                        f"{library}/pr-drainer/drain_prs_service.py",
                        "the ~/Library location is the last candidate",
                    )

    def test_a_relative_xdg_root_is_refused_even_when_it_holds_an_install(self):
        # The teeth of the absolute-only rule, and the case a rule spelled
        # `[ -z "$XDG_DATA_HOME" ]` would walk straight through. The relative
        # value here really does name an install directory relative to the
        # working directory, so a block that honoured it would resolve there
        # and this comparison would fail; the `~/Library` answer is the only
        # one the documented rule can give.
        for relative_path in RENDERED_ASSETS:
            fence = fence_containing(read(relative_path), "CONTROL=")
            with tempfile.TemporaryDirectory() as directory:
                working = Path(directory) / "working"
                home = Path(directory) / "home"
                planted = working / "relative" / "share" / "kanban" / "pr-drainer"
                planted.mkdir(parents=True)
                (planted / "config.json").write_text("{}", encoding="utf-8")
                library = (
                    home / "Library" / "Application Support" / "kanban" / "pr-drainer"
                )
                self.assertEqual(
                    self.resolve(
                        fence,
                        home,
                        cwd=working,
                        XDG_DATA_HOME="relative/share",
                    ),
                    f"{library}/drain_prs_service.py",
                    f"{relative_path}: a relative $XDG_DATA_HOME was honoured",
                )
                # The other half of the pair: the same tree named absolutely
                # *is* honoured, so the refusal above is about the value's
                # shape rather than about the variable being ignored.
                self.assertEqual(
                    self.resolve(
                        fence,
                        home,
                        cwd=working,
                        XDG_DATA_HOME=str(working / "relative" / "share"),
                    ),
                    f"{planted}/drain_prs_service.py",
                    f"{relative_path}: an absolute $XDG_DATA_HOME was ignored",
                )

    def test_neither_asset_spells_the_refused_substitution_or_a_hardcoded_path(self):
        for relative_path in RENDERED_ASSETS:
            text = read(relative_path)
            self.assertNotIn(REFUSED_XDG_SUBSTITUTION, text, relative_path)
            self.assertNotIn(REFUSED_HARDCODED_CONTROL, text, relative_path)
            self.assertIn('CONTROL="$DRAINER/drain_prs_service.py"', text)
            # Both platform spellings of the install directory are named, which
            # is what puts these two assets on the `drainer-install-dir` and
            # `drainer-install-dir-xdg` rows of the dependency manifest.
            self.assertIn("~/.local/share/kanban/pr-drainer", text, relative_path)
            self.assertIn(
                "~/Library/Application Support/kanban/pr-drainer",
                text,
                relative_path,
            )


class RepositoryResolutionTests(unittest.TestCase):
    """Requirement 8's first half: one resolution, through the remote the
    controller itself resolves a drainer's identity through, announced before
    anything is mutated, and with no GitHub call to obtain it.

    The remote is the part a hardcoded `origin` gets wrong. A drainer's
    identity comes from the shared Kanban configuration's `remote_name`, so on
    a fork checkout whose board is pointed at upstream the two remotes name two
    different canonical repositories and `--repo` built from `origin` is
    refused by the controller on every invocation — correctly, and unusably.
    The fixtures below run the rendered fences and assert which identity comes
    out, so the rule is the behavior rather than the spelling.
    """

    def resolve(
        self,
        relative_path: str,
        remotes: dict,
        config: str | None = None,
        install_module: bool = True,
    ) -> tuple[str, str, str]:
        """`($ROOT, $REMOTE, $REPO)` from running the three rendered fences.

        Run in order and in one shell, because that is how the asset reads:
        the repository identity depends on `$DRAINER`, which the controller
        fence resolves, which is why this composes all three rather than the
        last one alone.
        """
        text = read(relative_path)
        script = "\n".join(
            [
                fence_containing(text, "ROOT="),
                fence_containing(text, "CONTROL="),
                fence_containing(text, "REPO="),
                'printf "%s\\n%s\\n%s\\n" "$ROOT" "$REMOTE" "$REPO"',
            ]
        )
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            checkout = base / "checkout"
            checkout.mkdir()
            install = base / "install"
            install.mkdir()
            # The module the installer links beside the controller, which is
            # where the asset reads the configured remote from. Omitted by one
            # fixture below, because an installation whose links predate the
            # module is a real state and must not strand the command.
            if install_module:
                shutil.copy(
                    REPO_ROOT / "tools" / "kanban_config.py",
                    install / "kanban_config.py",
                )
            config_home = base / "config" / "kanban"
            config_home.mkdir(parents=True)
            if config is not None:
                (config_home / "config.toml").write_text(config, encoding="utf-8")
            self.git(checkout, "init", "--quiet", "-b", "main")
            for name, url in remotes.items():
                self.git(checkout, "remote", "add", name, url)
            completed = subprocess.run(
                ["sh", "-c", script],
                cwd=str(checkout),
                env={
                    "PATH": os.environ.get("PATH", ""),
                    "HOME": str(base / "home"),
                    "XDG_CONFIG_HOME": str(base / "config"),
                    "XDG_DATA_HOME": "",
                    "KANBAN_DRAINER_INSTALL_DIR": str(install),
                },
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                check=True,
            )
        root, remote, repo = completed.stdout.strip().splitlines()
        return root, remote, repo

    def git(self, cwd: Path, *arguments: str) -> None:
        subprocess.run(
            ["git", *arguments],
            cwd=str(cwd),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=True,
        )

    def test_every_remote_spelling_yields_one_owner_name(self):
        for relative_path in RENDERED_ASSETS:
            for url in (
                "https://github.com/example/demo.git",
                "https://github.com/example/demo",
                "git@github.com:example/demo.git",
            ):
                with self.subTest(relative_path=relative_path, url=url):
                    root, remote, repo = self.resolve(
                        relative_path, {"origin": url}
                    )
                    self.assertEqual(repo, "example/demo")
                    self.assertEqual(remote, "origin")
                    self.assertTrue(root.endswith("checkout"), root)

    def test_a_fork_checkout_asserts_the_configured_remote_s_identity(self):
        # The regression fixture: two remotes naming two different canonical
        # repositories, and a shared configuration that points the board — and
        # therefore the drainer's identity — at the second. `origin` here is
        # the wrong answer, and it is the answer a hardcoded remote gives.
        remotes = {
            "origin": "https://github.com/fork-owner/demo.git",
            "upstream": "https://github.com/example/demo.git",
        }
        for relative_path in RENDERED_ASSETS:
            with self.subTest(relative_path=relative_path):
                _, remote, repo = self.resolve(
                    relative_path, remotes, config='remote_name = "upstream"\n'
                )
                self.assertEqual(remote, "upstream")
                self.assertEqual(
                    repo,
                    "example/demo",
                    "the asserted identity must come from the configured "
                    "remote, not from origin",
                )
                # The same checkout with the default configuration is the
                # other identity, so the fixture is really discriminating
                # between two live answers rather than reporting a constant.
                _, default_remote, default_repo = self.resolve(
                    relative_path, remotes
                )
                self.assertEqual(default_remote, "origin")
                self.assertEqual(default_repo, "fork-owner/demo")

    def test_an_explicit_origin_configuration_is_honoured_too(self):
        remotes = {
            "origin": "https://github.com/fork-owner/demo.git",
            "upstream": "https://github.com/example/demo.git",
        }
        for relative_path in RENDERED_ASSETS:
            with self.subTest(relative_path=relative_path):
                _, remote, repo = self.resolve(
                    relative_path, remotes, config='remote_name = "origin"\n'
                )
                self.assertEqual(remote, "origin")
                self.assertEqual(repo, "fork-owner/demo")

    def test_an_unreadable_configuration_falls_back_to_origin(self):
        # The same fail-open the controller's own `configured_remote_name`
        # has: a configuration that cannot be parsed must not leave `$REMOTE`
        # empty, which would make `git remote get-url` fail and strand the
        # whole command.
        remotes = {"origin": "https://github.com/example/demo.git"}
        for relative_path in RENDERED_ASSETS:
            with self.subTest(relative_path=relative_path):
                _, remote, repo = self.resolve(
                    relative_path, remotes, config="this is not toml [\n"
                )
                self.assertEqual(remote, "origin")
                self.assertEqual(repo, "example/demo")

    def test_a_missing_configuration_module_falls_back_to_origin(self):
        # An install directory whose links predate `kanban_config.py` -- the
        # state this very machine's live install is in, since the module was
        # linked later than the controller. The import has to fail open, or
        # the block raises, `$REMOTE` is empty, and `git remote get-url` fails
        # for every operation.
        remotes = {
            "origin": "https://github.com/fork-owner/demo.git",
            "upstream": "https://github.com/example/demo.git",
        }
        for relative_path in RENDERED_ASSETS:
            with self.subTest(relative_path=relative_path):
                _, remote, repo = self.resolve(
                    relative_path,
                    remotes,
                    config='remote_name = "upstream"\n',
                    install_module=False,
                )
                self.assertEqual(remote, "origin")
                self.assertEqual(repo, "fork-owner/demo")

    def test_the_resolution_makes_no_github_call_of_its_own(self):
        # `sed` over the remote URL rather than `gh repo view`, which would be
        # a GitHub call made before the identity every invocation depends on
        # exists — and this workflow makes none at all.
        for relative_path in RENDERED_ASSETS:
            fence = fence_containing(read(relative_path), "REPO=")
            self.assertIn("git -C \"$ROOT\" remote get-url \"$REMOTE\"", fence)
            self.assertIn("sed -E", fence)
            self.assertNotIn("gh ", fence)

    def test_the_two_renderings_resolve_identically(self):
        for needle in ("ROOT=", "CONTROL=", "REPO="):
            self.assertEqual(
                fence_containing(read(CLAUDE_ASSET), needle),
                fence_containing(read(CODEX_ASSET), needle),
                needle,
            )

    def test_the_announcement_precedes_every_controller_invocation(self):
        for relative_path in RENDERED_ASSETS:
            text = read(relative_path)
            self.assertIn(
                "**Announce, then act:** name the resolved `$REPO` and the "
                "`$ROOT` it was matched against before the first invocation, "
                "and say which remote it came from when that remote is not "
                "`origin`.",
                flat(text),
                relative_path,
            )
            self.assertLess(
                text.index("Announce, then act"),
                text.index(CONTROLLER_INVOCATION),
                f"{relative_path}: the announcement must land before the "
                "first controller invocation",
            )


class ScopingTests(unittest.TestCase):
    """Requirement 8's second half, and the review's amendment to its probe:
    only the lines that execute the controller are held to the two flags."""

    def test_every_controller_invocation_carries_both_scoping_flags(self):
        for relative_path in RENDERED_ASSETS:
            lines = controller_invocation_lines(read(relative_path))
            self.assertEqual(
                len(lines), CONTROLLER_INVOCATION_COUNT, relative_path
            )
            for line in lines:
                self.assertIn(PATH_FLAG, line, f"{relative_path}: {line}")
                self.assertIn(REPO_FLAG, line, f"{relative_path}: {line}")

    def test_the_path_variable_is_not_the_repository_identity(self):
        # Both personal copies named the checkout `REPO`, which the
        # controller's own `--repo` flag now contradicts.
        for relative_path in RENDERED_ASSETS:
            text = read(relative_path)
            self.assertNotIn(REFUSED_PATH_FLAG, text, relative_path)
            self.assertIn(
                "`$ROOT` is a path and `$REPO` is an `owner/name`; neither "
                "substitutes for the other, and the path variable is not "
                "called `REPO`.",
                flat(text),
                relative_path,
            )

    def test_the_declared_invocation_count_is_the_one_the_assets_carry(self):
        # Non-vacuity for the rule above: with no invocation lines it would
        # pass over an empty list, so the nine operations' own invocations are
        # counted here and each named subcommand is pinned to one.
        for relative_path in RENDERED_ASSETS:
            fence = fence_containing(read(relative_path), "--json status")
            invoked = [
                line.split("--json ", 1)[1].split()[0]
                for line in fence.splitlines()
                if CONTROLLER_INVOCATION in line
            ]
            self.assertEqual(
                invoked,
                ["status", "install", "start", "stop", "logs", "incident", "ack"],
                relative_path,
            )

    def test_the_controller_refusal_is_stated_as_the_reason_for_the_repo_flag(self):
        for relative_path in RENDERED_ASSETS:
            self.assertIn(
                "the controller refuses the pair when the checkout's remote "
                "says otherwise",
                flat(read(relative_path)),
                relative_path,
            )


class NoGitHubCallTests(unittest.TestCase):
    """Requirement 9. This command's whole reach is the controller, so it makes
    no GitHub call and gains no `gh-cli` consumer row."""

    def test_neither_rendered_asset_invokes_gh(self):
        for relative_path in RENDERED_ASSETS:
            found = [
                match.group(0)
                for match in GH_INVOCATION_RE.finditer(read(relative_path))
            ]
            self.assertEqual(found, [], relative_path)

    def test_the_gh_detector_finds_a_planted_invocation(self):
        # The absence above is only worth something while the detector works.
        planted = read(CLAUDE_ASSET) + '\ngh pr list -R "$REPO" --state open\n'
        self.assertTrue(GH_INVOCATION_RE.search(planted))


class OperationSurfaceTests(unittest.TestCase):
    """Requirement 7: nine operations for both brands, `restart` composed, and
    the three withheld subcommands not exposed."""

    def documented_operations(self, text: str) -> list[str]:
        return re.findall(r"^- `([^`]+)`:", body_of(text), re.MULTILINE)

    def test_both_renderings_document_the_same_nine_operations_in_order(self):
        for relative_path in RENDERED_ASSETS:
            self.assertEqual(
                self.documented_operations(read(relative_path)),
                list(OPERATIONS),
                relative_path,
            )

    def test_restart_is_composed_because_the_controller_has_no_such_subcommand(self):
        for relative_path in RENDERED_ASSETS:
            self.assertIn(
                "`restart`: run `stop`, then `start`, then `status`, and "
                "succeed only when the status is `running`. The controller has "
                "no `restart` subcommand; this operation is composed from those "
                "three.",
                flat(read(relative_path)),
                relative_path,
            )

    def test_the_withheld_subcommands_are_named_and_not_offered(self):
        for relative_path in RENDERED_ASSETS:
            text = read(relative_path)
            self.assertIn(
                "Do not expose the controller's `run`, `notify-test`, or "
                "`uninstall` subcommands as ordinary lifecycle operations.",
                flat(text),
                relative_path,
            )
            for name in WITHHELD_SUBCOMMANDS:
                self.assertNotIn(name, self.documented_operations(text))

    def test_start_runs_only_on_an_explicit_request(self):
        for relative_path in RENDERED_ASSETS:
            self.assertIn(
                "Run this only when the user explicitly supplied `start` or "
                "asked to start or resume the drainer in this turn.",
                flat(read(relative_path)),
                relative_path,
            )

    def test_ack_runs_only_after_the_cause_is_resolved(self):
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            self.assertIn(
                "`ack [id] [note]`: mark an incident resolved, and only after "
                "its underlying cause is actually resolved.",
                flattened,
                relative_path,
            )
            # The optional positional id is documented rather than fenced, so
            # every line inside a bash block runs exactly as written.
            self.assertIn(
                "`incident` and `ack` take an optional incident ID as a "
                "positional argument before their flags; without one, each "
                "acts on the latest open incident.",
                flattened,
                relative_path,
            )

    def test_an_intentional_stop_raises_nothing(self):
        for relative_path in RENDERED_ASSETS:
            self.assertIn(
                "`stop`: an intentional stop. It must raise no incident and "
                "send no notification.",
                flat(read(relative_path)),
                relative_path,
            )

    def test_the_whole_command_runs_only_when_asked(self):
        # Requirement 11: the retired Codex copy's
        # `policy: allow_implicit_invocation: false` has no field in the
        # bundle manifest's interface block, so it is preserved as prose.
        for relative_path in RENDERED_ASSETS:
            self.assertIn(
                "This command runs only when the user asks for it in that "
                "turn: it is never invoked implicitly, and it never starts, "
                "stops, or acknowledges anything on its own initiative.",
                flat(read(relative_path)),
                relative_path,
            )

    def test_the_claude_argument_hint_lists_every_operation(self):
        hint = re.search(r"^argument-hint: \"(?P<hint>[^\"]+)\"$", read(CLAUDE_ASSET), re.MULTILINE)
        self.assertIsNotNone(hint)
        self.assertEqual(
            hint.group("hint").strip("[]").split("|"), list(OPERATIONS)
        )


class DrainerDescriptionTests(unittest.TestCase):
    """Requirement 5: the rendered body describes `tools/drain_prs.py` as it
    stands, and none of the four retired claims survives."""

    def test_no_retired_claim_survives_in_either_rendering(self):
        for relative_path in RENDERED_ASSETS:
            text = read(relative_path)
            for description, needle in RETIRED_CLAIMS.items():
                self.assertNotIn(needle, text, f"{relative_path}: {description}")

    def test_a_merge_conflict_raises_one_incident_and_merges_nothing(self):
        for relative_path in RENDERED_ASSETS:
            self.assertIn(
                "An eligible merge conflict is not repaired. The drainer "
                "records one open per-PR incident naming the conflicting files "
                "and stops merging that pull request — it touches no label, "
                "merges nothing, and creates no worktree. That incident clears "
                "by itself once the pull request is no longer conflicted, or "
                "through `ack`.",
                flat(read(relative_path)),
                relative_path,
            )

    def test_the_one_agent_spawn_is_the_roster_resolved_stale_head_rereview(self):
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            self.assertIn(
                "Its one agent spawn is the stale-approved-head rereview.",
                flattened,
                relative_path,
            )
            self.assertIn(
                "the drainer rereviews that exact head in a throwaway detached "
                "worktree, at the provider, model and effort the roster's "
                "`drain_rereview` cell names for this installation's operating "
                "mode: the codex cell — GPT-5.6-Terra at medium by default — "
                "when both providers are loaded, and the sole loaded provider's "
                "own cell when one is.",
                flattened,
                relative_path,
            )
            self.assertIn(
                "That cell is re-read on each drain cycle, so a roster edit "
                "takes effect on the next pass without restarting the managed "
                "service.",
                flattened,
                relative_path,
            )

    def test_an_unreadable_roster_or_model_stops_the_drainer_outright(self):
        for relative_path in RENDERED_ASSETS:
            self.assertIn(
                "If the roster file is present and cannot be read, or the "
                "selected model cannot be run, the drainer stops where it "
                "stands with no retry and no fallback; the managed service then "
                "opens an incident and notifies.",
                flat(read(relative_path)),
                relative_path,
            )

    def test_a_no_agent_roster_keeps_merging_and_records_one_incident(self):
        # The other half of the same paragraph, and the distinction the
        # drainer's own code draws: an unreadable roster is a file to repair
        # and stops the pass, while a roster that loads nothing is a
        # deliberate state the drainer goes on working in. An asset that
        # carried only the first sentence would have an operator restart a
        # service that is running correctly.
        for relative_path in RENDERED_ASSETS:
            self.assertIn(
                "A roster that loads no provider at all is a different thing "
                "and never stops the drainer. It starts, and it keeps merging "
                "every eligible pull request; only a pull request that actually "
                "reaches a stale-head rereview is left unmerged, with one open "
                "`no-agent-mode` per-PR incident recording it. That incident "
                "clears by itself once that pull request no longer needs a "
                "rereview, or through `ack`.",
                flat(read(relative_path)),
                relative_path,
            )

    def test_idle_operation_costs_no_model_tokens(self):
        for relative_path in RENDERED_ASSETS:
            self.assertIn(
                "The drainer and the managed job that supervises it consume no "
                "model tokens while idle.",
                flat(read(relative_path)),
                relative_path,
            )


class PrivateIdentifierTests(unittest.TestCase):
    """Requirement 6, and requirement 4's neutral naming of the manager."""

    def test_no_private_endpoint_or_machine_specific_path_is_tracked(self):
        for relative_path in RENDERED_ASSETS:
            text = read(relative_path)
            for description, needle in PRIVATE_IDENTIFIERS.items():
                self.assertNotIn(needle, text, f"{relative_path}: {description}")

    def test_the_notification_endpoint_is_the_configured_override(self):
        for relative_path in RENDERED_ASSETS:
            self.assertIn(
                "send one urgent notification to the endpoint "
                "`KANBAN_DRAINER_NTFY_URL` configures, when one is configured.",
                flat(read(relative_path)),
                relative_path,
            )

    def test_the_direct_invocation_prohibition_names_the_installed_drainer(self):
        for relative_path in RENDERED_ASSETS:
            self.assertIn(
                "Do not invoke the installed drainer at "
                "`$DRAINER/drain_prs.py` directly for normal operation.",
                flat(read(relative_path)),
                relative_path,
            )

    def test_neither_service_manager_is_asserted_as_the_manager(self):
        surfaces = [read(path) for path in RENDERED_ASSETS]
        surfaces.append(read("claude-plugin/README.md").split("| `commands/drain-prs.md` |")[1].split("\n")[0])
        surfaces.append(read("codex-plugin/README.md").split("| `skills/drain-prs/` |")[1].split("\n")[0])
        for index, text in enumerate(surfaces):
            for name in SERVICE_MANAGER_NAMES:
                self.assertNotIn(name, text, f"surface {index}: {name}")


class PreservedBehaviorTests(unittest.TestCase):
    """Requirement 15: what neither the reconciliation nor the repairs touch."""

    def test_the_per_repository_control_model_survives(self):
        for relative_path in RENDERED_ASSETS:
            self.assertIn(
                "The drainer is per repository, so every invocation names the "
                "checkout it controls **and** the `owner/name` this session "
                "believes that checkout is.",
                flat(read(relative_path)),
                relative_path,
            )

    def test_the_second_watcher_prohibition_survives(self):
        for relative_path in RENDERED_ASSETS:
            self.assertIn(
                "Do not create a second watcher, scheduled task, recurring "
                "goal, or persistent agent process.",
                flat(read(relative_path)),
                relative_path,
            )

    def test_an_incident_belongs_to_its_own_repository(self):
        for relative_path in RENDERED_ASSETS:
            self.assertIn(
                "An incident belongs to the repository whose drainer raised it "
                "— not to whichever repository surfaced it.",
                flat(read(relative_path)),
                relative_path,
            )
            self.assertIn(
                "when the reported `--path` shows no matching incident, check "
                "the other repositories' drainers before concluding there is "
                "nothing wrong.",
                flat(read(relative_path)),
                relative_path,
            )

    def test_the_recovery_procedure_is_seven_ordered_steps(self):
        for relative_path in RENDERED_ASSETS:
            section = read(relative_path).split("## Recover an incident\n", 1)[1]
            section = section.split("\n## ", 1)[0]
            steps = re.findall(r"^(\d+)\. ", section, re.MULTILINE)
            self.assertEqual(steps, [str(number) for number in range(1, 8)], relative_path)
            self.assertIn(
                "If the cause cannot be repaired autonomously, leave the "
                "drainer stopped, leave the incident open, and state exactly "
                "what decision or external change is required.",
                flat(section),
                relative_path,
            )

    def test_recovery_validates_before_touching_the_production_daemon(self):
        for relative_path in RENDERED_ASSETS:
            self.assertIn(
                "Validate changed Python with `python3 -m py_compile`.",
                flat(read(relative_path)),
                relative_path,
            )
            self.assertIn(
                "Never use the production daemon as the first test of a "
                "speculative fix.",
                flat(read(relative_path)),
                relative_path,
            )

    def test_the_incident_policy_survives_intact(self):
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            self.assertIn(
                "Expected per-pull-request failures remain inside the fair "
                "retry and backoff scheduler and raise no incident.",
                flattened,
                relative_path,
            )
            self.assertIn(
                "One incident is one recovery unit. Never acknowledge it until "
                "the repaired drainer is running.",
                flattened,
                relative_path,
            )

    def test_the_hand_editing_prohibitions_survive(self):
        for relative_path in RENDERED_ASSETS:
            self.assertIn(
                "Do not edit its lock, runtime status, scheduler state, or "
                "incident JSON by hand.",
                flat(read(relative_path)),
                relative_path,
            )


class BrandBoundaryTests(unittest.TestCase):
    """Requirement 10, and the negative control for every rule above.

    Four lines differ between the two renderings' bodies and no others. A rule
    asserted here that matched everything would also have to match the stripped
    bodies, and this comparison would fail.
    """

    def stripped(self, relative_path: str, brand: str, drop) -> list[str]:
        lines = neutralize(body_of(read(relative_path)), brand).splitlines()
        for line in drop:
            self.assertIn(line, lines, f"{relative_path}: {line!r}")
        return [line for line in lines if line not in drop]

    def test_the_bodies_differ_only_by_the_four_declared_brand_lines(self):
        claude = self.stripped(CLAUDE_ASSET, "claude", CLAUDE_ONLY_LINES)
        codex = self.stripped(CODEX_ASSET, "codex", CODEX_ONLY_LINES)
        self.assertEqual(claude, codex)

    def test_the_declared_command_references_are_the_ones_the_source_names(self):
        # Non-vacuity for the neutralization above: an empty referenced set
        # would make it a no-op, and the comparison would then fail on the
        # sigils rather than quietly passing — but it would also stop covering
        # the substitution at all, so the set is pinned.
        self.assertEqual(REFERENCED_WORKFLOWS, {"drain-prs"})

    def test_the_argument_convention_is_per_brand(self):
        claude = read(CLAUDE_ASSET)
        codex = read(CODEX_ASSET)
        self.assertIn("$ARGUMENTS", claude)
        self.assertNotIn("$ARGUMENTS", codex)
        self.assertIn("argument-hint:", claude)
        self.assertNotIn("argument-hint:", codex)
        self.assertIn(CODEX_ONLY_LINES[1], codex)
        self.assertNotIn(CODEX_ONLY_LINES[1], claude)

    def test_each_brand_reads_its_own_invocation_sigil(self):
        self.assertIn("/drain-prs", read(CLAUDE_ASSET))
        self.assertIn("$drain-prs", read(CODEX_ASSET))
        self.assertNotIn("$drain-prs ", read(CLAUDE_ASSET))
        self.assertNotIn("/drain-prs ", read(CODEX_ASSET))

    def test_each_brand_names_the_other_brand_s_own_invocation(self):
        # The one cross-brand reference the neutral token cannot express: the
        # point of the sentence is that one managed job has two control
        # surfaces, so each rendering names the *other* provider's namespaced
        # invocation rather than its own.
        self.assertIn("`$kanban:drain-prs`", read(CLAUDE_ASSET))
        self.assertNotIn("`/kanban:drain-prs`", read(CLAUDE_ASSET))
        self.assertIn("`/kanban:drain-prs`", read(CODEX_ASSET))
        self.assertNotIn("`$kanban:drain-prs`", read(CODEX_ASSET))
        for relative_path in RENDERED_ASSETS:
            self.assertIn(
                "one drainer per repository, two control surfaces, never a "
                "second daemon.",
                flat(read(relative_path)),
                relative_path,
            )


if __name__ == "__main__":
    unittest.main()
