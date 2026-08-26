"""The document workflows, executed from each bundle against a repository that
tracks none of Kanban's tools.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Issue #370. The five other modules that cover these workflows all run against
this repository: `tools/test_publish_coordination_doc.py` and
`tools/test_tracker_transaction.py` load the mechanism from `tools/`, and
`tools/test_document_workflow_contract.py` reads the assets as text. None of
them could observe the defect, because the defect was not in the mechanism or in
the assets — it was in the distance between them. Six shipped assets resolved
`tools/publish_coordination_doc.py` and `tools/tracker_transaction.py` from the
repository being operated on, which is a repository that installed the plugin
and therefore tracks neither file. Every one of them failed closed before doing
any work, in exactly the repositories these plugins exist to serve.

So what runs here is the other half:

- the fixture repository has **no `tools/` directory and no
  `docs/agent-workflow-contract.md`**, asserted rather than assumed, and its
  owner is not `coghex/kanban`;
- each helper is resolved by executing the asset's *own* lookup fence in
  `bash`, against a simulated provider install of that asset's own tracked
  bundle — `${CLAUDE_PLUGIN_ROOT}` for the Claude commands, the `$CODEX_HOME`
  plugin cache for the Codex skills; and
- the helper is then run as a subprocess at the path that lookup returned,
  which is what the asset does with it.

All six declared assets are driven, because requirement 2 is about the two
whose absence a single `process-report` demonstration would not have noticed.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# The owner is deliberately not this repository: §7 classifies coghex/kanban and
# nothing else, so a fixture that reused the slug would take the one branch this
# module exists to leave.
CONSUMING_REPOSITORY = "otherorg/product"
DOCUMENT = "docs/findings.md"
BRANCH = "master"

# A report-shaped document: an at-a-glance index whose entry keys are the
# finding IDs, which is the cursor `process-report` treats as durable and the
# only thing `--resolve` will clear a transaction against.
REPORT = """# Product findings

## Status

- [ ] CR-1. The first finding
- [ ] CR-2. The second finding

### CR-1 — The first finding

Body.

### CR-2 — The second finding

Body.
"""

RESOLVED_REPORT = REPORT.replace(
    "- [ ] CR-1. The first finding",
    "- [x] CR-1. The first finding — [#7]",
)

# The declared assets, with the bundle each one installs from and whether it
# reaches the tracker. The two note-problem variants publish without acquiring
# a transaction, so they carry no $TRACKER_TX to resolve.
ASSETS = (
    ("claude-plugin/plugins/kanban/commands/process-report.md", "claude", True),
    ("claude-plugin/plugins/kanban/commands/process-design-doc.md", "claude", True),
    ("claude-plugin/plugins/kanban/commands/note-problem.md", "claude", False),
    ("codex-plugin/plugins/kanban/skills/process-report/SKILL.md", "codex", True),
    ("codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md", "codex", True),
    ("codex-plugin/plugins/kanban/skills/note-problem/SKILL.md", "codex", False),
)

BUNDLE_SOURCES = {
    "claude": REPO_ROOT / "claude-plugin" / "plugins" / "kanban",
    "codex": REPO_ROOT / "codex-plugin" / "plugins" / "kanban",
}

BASH_FENCE_RE = re.compile(r"```bash\n(?P<body>.*?)```", re.DOTALL)


def run(args, cwd=None, **kwargs):
    proc = subprocess.run(
        args, cwd=None if cwd is None else str(cwd), capture_output=True, text=True,
        **kwargs,
    )
    if proc.returncode != 0:
        raise AssertionError(f"{args} failed:\n{proc.stdout}\n{proc.stderr}")
    return proc.stdout.strip()


def lookup_fence(text):
    """The asset's own helper-resolution block, as shell."""
    for match in BASH_FENCE_RE.finditer(text):
        body = match.group("body")
        if body.lstrip().startswith("PUBLISH_DOC="):
            return body
    raise AssertionError("the asset carries no PUBLISH_DOC resolution fence")


class ConsumingRepositoryFixture:
    """A repository that installed the plugin: a bare origin, a clone, and the
    `docs-wip` linked worktree the assets write in. It carries a report and
    nothing else — no Kanban tooling, and no §7 to classify it."""

    def __init__(self, directory: Path):
        self.dir = directory
        owner, name = CONSUMING_REPOSITORY.split("/")
        self.origin = directory / owner / f"{name}.git"
        self.origin.parent.mkdir(parents=True, exist_ok=True)
        self.primary = directory / "primary"
        run(["git", "init", "-q", "--bare", str(self.origin)], directory)
        run(["git", "clone", "-q", str(self.origin), str(self.primary)], directory)
        run(["git", "config", "user.email", "t@example.com"], self.primary)
        run(["git", "config", "user.name", "Test"], self.primary)
        (self.primary / "docs").mkdir()
        (self.primary / DOCUMENT).write_text(REPORT, encoding="utf-8")
        (self.primary / "README.md").write_text("# Product\n", encoding="utf-8")
        run(["git", "add", "-A"], self.primary)
        run(["git", "commit", "-qm", "init"], self.primary)
        run(["git", "branch", "-M", BRANCH], self.primary)
        run(["git", "push", "-q", "origin", f"{BRANCH}:{BRANCH}"], self.primary)
        run(["git", "fetch", "-q", "origin", BRANCH], self.primary)
        self.docs = directory / "docs-wip"
        run(
            ["git", "worktree", "add", "-q", "-b", "docs-wip", str(self.docs), BRANCH],
            self.primary,
        )

    def remote_content(self, path=DOCUMENT):
        return run(["git", "show", f"origin/{BRANCH}:{path}"], self.primary)


class ConsumingRepositoryTests(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        # A machine with no Kanban configuration is the starting state, which
        # is also the "declares nothing" case requirement 5 is about.
        self.config_home = self.root / "config"
        self.config_home.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()

    # -- the environment the asset's lookup runs in --------------------------

    def install(self, brand):
        """The bundle as its provider lays it down, at the location that
        brand's lookup searches."""
        target = self.root / f"{brand}-install"
        if brand == "claude":
            plugin_root = target / "plugins" / "kanban"
        else:
            plugin_root = (
                target / "plugins" / "cache" / "kanban" / "kanban" / "1.4.1"
            )
        if not plugin_root.exists():
            shutil.copytree(BUNDLE_SOURCES[brand], plugin_root)
        return target, plugin_root

    def resolve_helpers(self, relative_path, brand):
        """What the asset's own lookup fence returns, executed as shell.

        The fence ends in an existence check, so an unresolvable helper fails
        here exactly as it would in a session — which is the whole behaviour
        under test, not a detail of the harness.
        """
        install_root, plugin_root = self.install(brand)
        fence = lookup_fence((REPO_ROOT / relative_path).read_text(encoding="utf-8"))
        script = fence + '\nprintf "%s\\n%s\\n" "$PUBLISH_DOC" "${TRACKER_TX-}"\n'
        environment = dict(os.environ, HOME=str(self.home))
        if brand == "claude":
            environment["CLAUDE_PLUGIN_ROOT"] = str(plugin_root)
        else:
            environment["CODEX_HOME"] = str(install_root)
            environment.pop("CLAUDE_PLUGIN_ROOT", None)
        proc = subprocess.run(
            ["bash", "-c", script], capture_output=True, text=True, env=environment,
            timeout=60,
        )
        self.assertEqual(
            proc.returncode, 0,
            f"{relative_path}'s own lookup failed: {proc.stderr}",
        )
        publish, tracker = (proc.stdout.splitlines() + ["", ""])[:2]
        self.assertTrue(publish, relative_path)
        # Resolved out of the simulated install, never out of this checkout.
        self.assertTrue(Path(publish).is_file(), publish)
        self.assertTrue(str(Path(publish)).startswith(str(install_root)), publish)
        return publish, (tracker or None)

    def helper(self, script, *args, stdin=None, expect=0):
        """One helper invocation, exactly as the asset runs it."""
        proc = subprocess.run(
            ["python3", script, "--repo", CONSUMING_REPOSITORY,
             "--root", str(self.fixture.docs), "--path", DOCUMENT, *args],
            capture_output=True, text=True, input=stdin,
            env=dict(
                os.environ, HOME=str(self.home),
                XDG_CONFIG_HOME=str(self.config_home),
            ),
            timeout=180,
        )
        self.assertEqual(
            proc.returncode, expect, f"{args}\n{proc.stdout}\n{proc.stderr}"
        )
        return json.loads(proc.stdout) if proc.stdout.strip() else {}

    def declare(self, *paths):
        """The consuming repository's own direct-publication lane.

        `direct_publication_paths`, never `coordination_paths`: the second is
        the drainer's merge exception and grants no publication lane.
        """
        target = self.config_home / "kanban" / "config.toml"
        target.parent.mkdir(parents=True, exist_ok=True)
        rendered = ", ".join(json.dumps(path) for path in paths)
        target.write_text(
            f'[repositories."{CONSUMING_REPOSITORY}".workflow]\n'
            f"direct_publication_paths = [{rendered}]\n",
            encoding="utf-8",
        )

    def build_repository(self):
        """A fresh consuming repository, and a machine that declares nothing.

        One per case rather than one per test: the subTest loops below each
        drive six assets, and a fixture or a configuration file carried between
        them would let one asset's publication decide the next one's outcome.
        """
        self._built = getattr(self, "_built", 0) + 1
        shutil.rmtree(self.config_home, ignore_errors=True)
        self.config_home.mkdir()
        self.fixture = ConsumingRepositoryFixture(
            self.root / f"repository-{self._built}"
        )
        # The premise, asserted rather than assumed: this is a repository that
        # installed the plugin, so it tracks none of the mechanism and has no
        # §7 to be classified by.
        self.assertFalse((self.fixture.primary / "tools").exists())
        self.assertFalse(
            (self.fixture.primary / "docs" / "agent-workflow-contract.md").exists()
        )
        return self.fixture

    # -- the run itself ------------------------------------------------------

    def preflight(self, publish):
        outcome = self.helper(publish, "--branch", BRANCH, "--check-pending")
        self.assertEqual(outcome["status"], "clear", outcome)
        self.assertTrue(outcome["publication_tip"], outcome)
        return outcome["publication_tip"]

    def publish(self, publish, content, tip):
        approved = subprocess.run(
            ["python3", publish, "--repo", CONSUMING_REPOSITORY,
             "--root", str(self.fixture.docs), "--path", DOCUMENT,
             "--new-content-file"],
            capture_output=True, text=True,
            env=dict(
                os.environ, HOME=str(self.home),
                XDG_CONFIG_HOME=str(self.config_home),
            ),
            timeout=60,
        )
        self.assertEqual(approved.returncode, 0, approved.stderr)
        scratch = Path(approved.stdout.strip())
        scratch.write_text(content, encoding="utf-8")
        return self.helper(
            publish, "--branch", BRANCH, "--content", str(scratch),
            "--expected-tip", tip,
        )

    def transaction(self, tracker_script, *args, stdin=None, expect=0):
        proc = subprocess.run(
            ["python3", tracker_script, "--repo", CONSUMING_REPOSITORY,
             "--root", str(self.fixture.docs), "--path", DOCUMENT, *args],
            capture_output=True, text=True, input=stdin,
            env=dict(
                os.environ, HOME=str(self.home),
                XDG_CONFIG_HOME=str(self.config_home),
            ),
            timeout=180,
        )
        self.assertEqual(
            proc.returncode, expect, f"{args}\n{proc.stdout}\n{proc.stderr}"
        )
        return json.loads(proc.stdout)

    PLAN = json.dumps(
        {
            "entry_key": "CR-1",
            "disposition": "new-issue",
            "steps": [
                {
                    "kind": "issue-create",
                    "target": f"new issue in {CONSUMING_REPOSITORY}",
                    "payload_fingerprint": "sha256:body",
                    "postcondition": "the issue exists with the approved body",
                    "provides_marker": True,
                }
            ],
        }
    )

    IDENTITY = json.dumps(
        {
            "kind": "issue-create",
            "id": "7",
            "url": f"https://github.com/{CONSUMING_REPOSITORY}/issues/7",
            "document_token": "[#7]",
            "postcondition_verified": True,
        }
    )

    # -- requirement 1, 2 and 3 ---------------------------------------------

    def test_every_asset_reaches_a_clear_preflight(self):
        for relative_path, brand, _uses_tracker in ASSETS:
            with self.subTest(asset=relative_path):
                self.build_repository()
                publish, _tracker = self.resolve_helpers(relative_path, brand)
                self.assertTrue(self.preflight(publish))

    def test_every_processing_asset_checkpoints_and_recovers_its_transaction(self):
        for relative_path, brand, uses_tracker in ASSETS:
            if not uses_tracker:
                continue
            with self.subTest(asset=relative_path):
                self.build_repository()
                publish, tracker_script = self.resolve_helpers(relative_path, brand)
                self.assertIsNotNone(tracker_script, relative_path)
                tip = self.preflight(publish)

                acquired = self.transaction(
                    tracker_script, "--acquire", "--approved",
                    "--publication-tip", tip, "--plan", "-", stdin=self.PLAN,
                )
                self.assertTrue(acquired["acquired"], acquired)

                # Recovery: a second, independent invocation sees the record
                # through the same preflight the assets ask before mutating
                # anything. This is the state a consuming repository used to
                # be unable to reach at all, so its runs had no record to find.
                pending = self.helper(
                    publish, "--branch", BRANCH, "--check-pending", expect=1
                )
                self.assertEqual(pending["status"], "pending", pending)
                self.assertIn("tracker-transaction", pending["pending_kinds"])
                self.assertEqual(
                    pending["tracker_transaction"]["entry_key"], "CR-1", pending
                )

                begun = self.transaction(
                    tracker_script, "--begin-step", "0", "--approved"
                )
                self.transaction(
                    tracker_script, "--confirm-step", "0",
                    "--begin-token", begun["begin_token"], "--identity", "-",
                    stdin=self.IDENTITY,
                )
                self.transaction(tracker_script, "--publication-pending")

                self.declare(DOCUMENT)
                published = self.publish(publish, RESOLVED_REPORT, tip)
                self.assertEqual(published["status"], "published", published)

                resolved = self.transaction(
                    tracker_script, "--resolve", "--source", "branch",
                    "--branch", BRANCH,
                )
                self.assertEqual(resolved["status"], "resolved", resolved)
                self.assertEqual(
                    self.helper(publish, "--branch", BRANCH, "--check-pending")["status"],
                    "clear",
                )

    # -- requirement 4 -------------------------------------------------------

    def test_every_asset_publishes_a_path_the_repository_declares(self):
        for relative_path, brand, _uses_tracker in ASSETS:
            with self.subTest(asset=relative_path):
                self.build_repository()
                publish, _tracker = self.resolve_helpers(relative_path, brand)
                tip = self.preflight(publish)
                self.declare(DOCUMENT)
                outcome = self.publish(publish, RESOLVED_REPORT, tip)
                self.assertEqual(outcome["status"], "published", outcome)
                self.assertTrue(outcome["remote_contains_commit"], outcome)
                self.assertIn("[#7]", self.fixture.remote_content())

    # -- requirement 5 -------------------------------------------------------

    def test_every_asset_reports_not_published_when_nothing_is_declared(self):
        for relative_path, brand, _uses_tracker in ASSETS:
            with self.subTest(asset=relative_path):
                self.build_repository()
                publish, _tracker = self.resolve_helpers(relative_path, brand)
                tip = self.preflight(publish)
                outcome = self.publish(publish, RESOLVED_REPORT, tip)
                self.assertEqual(outcome["status"], "not-published", outcome)
                # The ordinary outcome, not an error: the approved mutation
                # reached the document, and the repository lands it through the
                # pull-request lane it already has.
                self.assertTrue(outcome["document_written"], outcome)
                self.assertIn(
                    "[#7]", (self.fixture.docs / DOCUMENT).read_text(encoding="utf-8")
                )
                self.assertNotIn("[#7]", self.fixture.remote_content())

    def test_a_declared_lane_for_another_document_publishes_nothing_here(self):
        # The declaration is exact and per path, so a repository with a lane is
        # not a repository whose every document publishes.
        relative_path, brand, _uses_tracker = ASSETS[0]
        self.build_repository()
        publish, _tracker = self.resolve_helpers(relative_path, brand)
        tip = self.preflight(publish)
        self.declare("docs/other.md")
        outcome = self.publish(publish, RESOLVED_REPORT, tip)
        self.assertEqual(outcome["status"], "not-published", outcome)
        self.assertTrue(outcome["document_written"], outcome)

    # -- the premise itself --------------------------------------------------

    def test_the_helpers_run_from_the_bundle_with_no_tools_directory_present(self):
        # The defect stated as a test: resolving these helpers from the
        # repository being operated on finds nothing there. If this ever
        # succeeds, the fixture has stopped being a consuming repository and
        # every result above is about Kanban's own tree instead.
        self.build_repository()
        for name in ("publish_coordination_doc.py", "tracker_transaction.py"):
            with self.subTest(module=name):
                self.assertFalse((self.fixture.primary / "tools" / name).exists())
                self.assertFalse((self.fixture.docs / "tools" / name).exists())


if __name__ == "__main__":
    unittest.main()
