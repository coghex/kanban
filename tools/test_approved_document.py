"""Executable coverage for tools/approved_document.py.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Issue #830, slice B of #775. The helper owns the document-write protocol that
tools/publish_coordination_doc.py used to own alongside its publication
mechanism, and hands the one named document to the owner's external `docs-push`.
Every case below drives the real helper against temporary Git repositories — a
bare origin, a primary clone, a linked worktree whose branch has commits of its
own (a pull request's) and one that has none (a scratch worktree) — with a
controlled `docs-push` first on `PATH`, `tools/fake_docs_push.py`. The real tool
and `~/.config/docs-push.json` are never touched, and the helper is asserted to
read neither.

What has to be proven is what the helper *refuses* and what it leaves behind:
an outside edit overwritten, a landing decided by the tool's words, a record
dropped to make progress, a fallback push, a tracker mutation repeated. The
fake claims nothing about the owner's git engine; that coverage stays with its
owner and is documented in docs/document-workflow-contract.md.
"""

from __future__ import annotations

import ast
import contextlib
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TOOLS = REPO_ROOT / "tools"

# `python3 -m unittest tools.test_approved_document` puts the repository root on
# sys.path rather than tools/, unlike `discover -s tools`; both have to reach
# the sibling fixture module.
sys.path.insert(0, str(TOOLS))

import git_fixture


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, TOOLS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


approved = _load("_kanban_approved_document_under_test", "approved_document.py")
tracker = _load("_kanban_tracker_for_approved_document", "tracker_transaction.py")
publisher = _load("_kanban_publisher_for_approved_document", "publish_coordination_doc.py")

REPOSITORY = "coghex/kanban"
DOC = "docs/notes.md"
OTHER = "docs/other.md"

NOTES = "# Notes\n\n" + "".join(f"- line {number}\n" for number in range(1, 11))
EDITED = NOTES.replace("- line 2\n", "- line 2, approved\n")
UPSTREAM_ELSEWHERE = NOTES.replace("- line 9\n", "- line 9, edited upstream\n")
UPSTREAM_SAME_LINE = NOTES.replace("- line 2\n", "- line 2, edited upstream\n")
MERGED = EDITED.replace("- line 9\n", "- line 9, edited upstream\n")

_CONFIG_ISOLATION = None


def setUpModule():
    # The helper reads no configuration, but the tracker module it coexists with
    # does for a repository outside Kanban; an empty directory is "none".
    global _CONFIG_ISOLATION
    _CONFIG_ISOLATION = tempfile.TemporaryDirectory()
    os.environ["XDG_CONFIG_HOME"] = _CONFIG_ISOLATION.name


def tearDownModule():
    os.environ.pop("XDG_CONFIG_HOME", None)
    _CONFIG_ISOLATION.cleanup()


def run(args, cwd, **kwargs):
    proc = subprocess.run(args, cwd=str(cwd), capture_output=True, text=True, **kwargs)
    if proc.returncode != 0:
        raise AssertionError(f"{args} failed in {cwd}:\n{proc.stderr}")
    return proc.stdout.strip()


def blob_of(text: str) -> str:
    return approved.git_blob_hash(text.encode())


class SimulatedCrash(BaseException):
    """A process dying between two steps: not an Exception, so nothing in the
    helper that catches Exception can mistake it for an outcome."""


class Fixture:
    """A bare origin, a primary clone, a pull-request-style worktree (its
    branch has a commit of its own) and a scratch worktree (it has none)."""

    def __init__(self, directory: Path):
        self.dir = directory
        self.origin = directory / "coghex" / "kanban.git"
        self.primary = directory / "primary"
        self.work = directory / "work"
        self.scratch = directory / "scratch"

    @classmethod
    def create(cls, directory: Path) -> "Fixture":
        fixture = cls(directory)
        fixture.build()
        return fixture

    def build(self) -> None:
        directory = self.dir
        self.origin.parent.mkdir(parents=True, exist_ok=True)
        run(["git", "init", "-q", "--bare", str(self.origin)], directory)
        run(["git", "clone", "-q", str(self.origin), str(self.primary)], directory)
        run(["git", "config", "user.email", "t@example.com"], self.primary)
        run(["git", "config", "user.name", "Test"], self.primary)
        (self.primary / "docs").mkdir()
        (self.primary / DOC).write_text(NOTES, encoding="utf-8")
        (self.primary / OTHER).write_text("# Other\n", encoding="utf-8")
        (self.primary / "code.txt").write_text("code\n", encoding="utf-8")
        run(["git", "add", "-A"], self.primary)
        run(["git", "commit", "-qm", "init"], self.primary)
        run(["git", "branch", "-M", "master"], self.primary)
        run(["git", "push", "-q", "-u", "origin", "master:master"], self.primary)
        run(["git", "remote", "set-head", "origin", "master"], self.primary)
        run(["git", "worktree", "add", "-q", "-b", "scratch", str(self.scratch), "master"],
            self.primary)
        run(["git", "worktree", "add", "-q", "-b", "issue-1", str(self.work), "master"],
            self.primary)
        (self.work / "feature.txt").write_text("a pull request's own work\n", encoding="utf-8")
        run(["git", "add", "-A"], self.work)
        run(["git", "commit", "-qm", "the pull request's own commit"], self.work)
        for tree in (self.primary, self.work, self.scratch):
            run(["git", "fetch", "-q", "origin", "master"], tree)

    # -- the repository, as origin and the trees carry it ---------------------

    def origin_blob(self, document=DOC):
        proc = subprocess.run(
            ["git", "rev-parse", "--verify", "--quiet", f"master:{document}"],
            cwd=str(self.origin), capture_output=True, text=True,
        )
        return proc.stdout.strip() or None

    def origin_tip(self):
        return run(["git", "rev-parse", "master"], self.origin)

    def origin_text(self, document=DOC):
        return run(["git", "show", f"master:{document}"], self.origin)

    def origin_log(self):
        return run(["git", "log", "--format=%H %s", "master"], self.origin).splitlines()

    def upstream_edit(self, text, document=DOC, message="someone else edits"):
        """Land `text` on origin from a different clone, as another agent would."""
        run(["git", "fetch", "-q", "origin", "master"], self.primary)
        run(["git", "checkout", "-q", "master"], self.primary)
        run(["git", "merge", "-q", "--ff-only", "origin/master"], self.primary)
        target = self.primary / document
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        run(["git", "add", document], self.primary)
        run(["git", "commit", "-qm", message], self.primary)
        run(["git", "push", "-q", "origin", "master:master"], self.primary)

    def write(self, root, text, document=DOC):
        target = Path(root) / document
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    def read(self, root, document=DOC):
        return (Path(root) / document).read_text(encoding="utf-8")

    def ref(self, name, root=None):
        proc = subprocess.run(
            ["git", "rev-parse", "--verify", "--quiet", name],
            cwd=str(root or self.work), capture_output=True, text=True,
        )
        return proc.stdout.strip() or None

    def pending(self, document=DOC):
        return self.ref(approved.pending_ref(REPOSITORY, document))

    def applied(self, document=DOC):
        return self.ref(approved.applied_ref(REPOSITORY, document))

    def status(self, root):
        """Porcelain lines, sorted, with the leading space of the first intact."""
        proc = subprocess.run(
            ["git", "status", "--porcelain", "--untracked-files=all"],
            cwd=str(root), capture_output=True, text=True, check=True,
        )
        return sorted(proc.stdout.splitlines())


class ApprovedFixture(git_fixture.GitTemplateMixin, unittest.TestCase):
    """Every case works on its own copy of one template built by `git`, with a
    controlled `docs-push` first on PATH."""

    @classmethod
    def build_git_template(cls, root, data):
        Fixture.create(root)

    def setUp(self):
        self.fx = Fixture(self.checkout_git_template())
        bin_dir = tempfile.TemporaryDirectory()
        self.addCleanup(bin_dir.cleanup)
        self.bin = Path(bin_dir.name)
        self.log_path = self.bin / "calls.jsonl"
        self.install_fake()
        patcher = unittest.mock.patch.dict(
            os.environ,
            {
                "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
                "FAKE_DOCS_PUSH_LOG": str(self.log_path),
                "FAKE_DOCS_PUSH_MODE": "land",
                # The real tool's configuration is never read: pointed nowhere,
                # and the fake does not read it either.
                "DOCS_PUSH_CONFIG": str(self.bin / "no-such-config.json"),
            },
        )
        patcher.start()
        self.addCleanup(patcher.stop)

    def install_fake(self):
        target = self.bin / "docs-push"
        source = (TOOLS / "fake_docs_push.py").read_text(encoding="utf-8")
        target.write_text(f"#!{sys.executable}\n" + source.split("\n", 1)[1], encoding="utf-8")
        target.chmod(0o755)

    def mode(self, name):
        os.environ["FAKE_DOCS_PUSH_MODE"] = name

    def calls(self):
        if not self.log_path.exists():
            return []
        entries = [json.loads(line) for line in self.log_path.read_text().splitlines()]
        return [entry for entry in entries if "argv" in entry]

    def remove_tool(self):
        """PATH holds git and nothing named docs-push."""
        bare = self.bin / "bare"
        bare.mkdir()
        (bare / "git").symlink_to(shutil.which("git"))
        os.environ["PATH"] = str(bare)

    # -- the helper, as the assets will invoke it ------------------------------

    def preflight(self, root=None, document=DOC):
        return approved.check_pending(root or self.fx.work, REPOSITORY, "master", document)

    def approve(self, text, *, root=None, document=DOC, baseline=None, **kwargs):
        root = root or self.fx.work
        if baseline is None:
            baseline = approved.working_blob(Path(root), document)
        kwargs.setdefault("expected_working_copy", baseline)
        return approved.apply_and_publish(
            repository=REPOSITORY, branch="master", root=root, document=document,
            content=text.encode(), **kwargs,
        )

    def resume(self, root=None, document=DOC):
        return approved.apply_and_publish(
            repository=REPOSITORY, branch="master", root=root or self.fx.work,
            document=document, content=None,
        )

    def failure(self, call, *args, **kwargs):
        with self.assertRaises(approved.DocumentError) as caught:
            call(*args, **kwargs)
        return caught.exception

    def cli(self, *args, root=None, document=DOC):
        buffer = io.StringIO()
        argv = ["--repo", REPOSITORY, "--root", str(root or self.fx.work), "--path", document, *args]
        with contextlib.redirect_stdout(buffer):
            code = approved.main(argv)
        return code, json.loads(buffer.getvalue())


class ApprovedTemplateIsolationTests(git_fixture.SharedTemplateIsolationTests, ApprovedFixture):
    """Issue #384: a copy still naming its template would write its records and
    its pushes into shared state."""

    def _mutate_the_copy(self):
        self.approve(EDITED)
        run(["git", "branch", "-f", "sideways", "master"], self.fx.work)


class PublishThroughTheToolTests(ApprovedFixture):
    def test_the_named_document_is_handed_to_the_tool_with_the_exact_arguments(self):
        outcome = self.approve(EDITED)
        self.assertEqual(outcome["status"], "published")
        (call,) = self.calls()
        self.assertEqual(call["paths"], [DOC])
        self.assertEqual(call["expect"], blob_of(EDITED))
        self.assertTrue(call["keep"])
        self.assertEqual(Path(call["cwd"]).resolve(), self.fx.work.resolve())
        self.assertEqual(
            call["argv"][:4], ["--expect", blob_of(EDITED), "--keep", "-m"],
        )
        self.assertEqual(call["argv"][-1], DOC)

    def test_the_commit_message_carries_a_marker_naming_the_attempt(self):
        outcome = self.approve(EDITED, message="docs: close finding F-1")
        (call,) = self.calls()
        self.assertTrue(call["message"].startswith("docs: close finding F-1\n\n"))
        marker = [
            line for line in call["message"].splitlines()
            if line.startswith(f"{approved.RECEIPT_TRAILER}: ")
        ]
        self.assertEqual(len(marker), 1)
        body = json.loads(marker[0].split(": ", 1)[1])
        self.assertEqual(body["blob"], blob_of(EDITED))
        self.assertEqual(body["document"], DOC)
        self.assertEqual(body["repository"], REPOSITORY)
        self.assertRegex(body["attempt"], r"^[0-9a-f]{32}$")
        self.assertEqual(outcome["landed_via"], "receipt")

    def test_a_clean_landing_publishes_clears_both_records_and_keeps_the_copy(self):
        tip = self.fx.origin_tip()
        outcome = self.approve(EDITED)
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(outcome["approved_blob"], blob_of(EDITED))
        self.assertEqual(outcome["published_blob"], blob_of(EDITED))
        self.assertFalse(outcome["merged"])
        self.assertEqual(self.fx.origin_text(), EDITED.rstrip("\n"))
        self.assertNotEqual(self.fx.origin_tip(), tip)
        # The receipt is a commit on the branch, not whatever the tool printed.
        self.assertIn(outcome["receipt_commit"], " ".join(self.fx.origin_log()))
        self.assertIsNone(self.fx.pending())
        self.assertIsNone(self.fx.applied())
        self.assertEqual(self.fx.read(self.fx.work), EDITED)
        self.assertEqual(self.preflight()["status"], "clear")

    def test_a_scratch_worktree_without_commits_of_its_own_fast_forwards(self):
        outcome = self.approve(EDITED, root=self.fx.scratch)
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(self.fx.read(self.fx.scratch), EDITED)
        self.assertIsNone(self.fx.pending())
        self.assertEqual(
            run(["git", "rev-parse", "HEAD"], self.fx.scratch),
            run(["git", "rev-parse", "origin/master"], self.fx.scratch),
        )

    def test_no_git_subcommand_that_pushes_or_merges_is_ever_spawned(self):
        # There is no fallback publisher: the module has no push, merge or
        # fetch-and-reset of its own to fall back to. Read out of the source so
        # a future edit that grew one fails here rather than in review.
        source = (TOOLS / "approved_document.py").read_text(encoding="utf-8")
        spawned = set(re.findall(r'\[\s*"git",\s*"([a-z-]+)"', source))
        spawned |= set(re.findall(r'git(?:_out)?\(\s*\[\s*"([a-z-]+)"', source))
        self.assertTrue({"fetch", "update-ref", "commit-tree"} <= spawned, spawned)
        self.assertEqual(
            spawned & {"push", "merge", "pull", "reset", "checkout", "rebase", "commit"},
            set(),
            spawned,
        )

    def test_the_module_reads_no_lane_declaration_and_loads_no_publisher(self):
        # What the module *does*, not what its prose says: every string constant
        # outside a docstring, and every import, read out of the syntax tree.
        tree = ast.parse((TOOLS / "approved_document.py").read_text(encoding="utf-8"))
        docstrings = {
            id(node.body[0].value)
            for node in ast.walk(tree)
            if isinstance(node, (ast.Module, ast.FunctionDef, ast.ClassDef))
            and node.body
            and isinstance(node.body[0], ast.Expr)
            and isinstance(node.body[0].value, ast.Constant)
        }
        strings = [
            node.value for node in ast.walk(tree)
            if isinstance(node, ast.Constant) and isinstance(node.value, str)
            and id(node) not in docstrings
        ]
        names = {node.id for node in ast.walk(tree) if isinstance(node, ast.Name)}
        names |= {node.attr for node in ast.walk(tree) if isinstance(node, ast.Attribute)}
        for forbidden in ("kanban_config", "load_raw_config", "resolve_config",
                          "direct_publication_paths", "coordination_paths",
                          "docs-push.json", "publish_coordination_doc.py"):
            self.assertEqual([s for s in strings if forbidden in s], [], forbidden)
            self.assertNotIn(forbidden, names)
        for name in ("CLASSIFICATION_PATH", "SECTION_7_HEADING", "eligibility",
                     "declared_publication_paths"):
            self.assertNotIn(name, names)

    def test_a_three_way_merge_reports_the_approved_and_the_published_blob_apart(self):
        self.fx.upstream_edit(UPSTREAM_ELSEWHERE)
        run(["git", "fetch", "-q", "origin", "master"], self.fx.work)
        outcome = self.approve(EDITED)
        self.assertEqual(outcome["status"], "published")
        self.assertTrue(outcome["merged"])
        self.assertEqual(outcome["approved_blob"], blob_of(EDITED))
        self.assertEqual(outcome["published_blob"], blob_of(MERGED))
        self.assertNotEqual(outcome["approved_blob"], outcome["published_blob"])
        self.assertEqual(self.fx.origin_blob(), blob_of(MERGED))
        # The merged copy `--keep` left is preserved, and the records are gone.
        self.assertEqual(self.fx.read(self.fx.work), MERGED)
        self.assertIsNone(self.fx.pending())
        self.assertIsNone(self.fx.applied())

    def test_a_conflict_publishes_nothing_and_keeps_the_approved_content(self):
        self.fx.upstream_edit(UPSTREAM_SAME_LINE)
        run(["git", "fetch", "-q", "origin", "master"], self.fx.work)
        tip = self.fx.origin_tip()
        outcome = self.approve(EDITED)
        self.assertEqual(outcome["status"], "incomplete-publication")
        self.assertEqual(outcome["reason"], "tool-refused")
        self.assertIn("conflicts with an upstream edit", outcome["message"])
        self.assertIn("docs-push --get", outcome["message"])
        self.assertEqual(self.fx.origin_tip(), tip)
        self.assertEqual(self.fx.read(self.fx.work), EDITED)
        self.assertEqual(self.fx.pending(), outcome["pending_commit"])
        self.assertEqual(self.fx.applied(), blob_of(EDITED))

    def test_a_novel_document_lands_over_the_copy_the_preflight_observed(self):
        novel = "docs/brand-new.md"
        self.fx.write(self.fx.work, "# New\n\n- draft\n", novel)
        before = self.preflight(document=novel)
        self.assertEqual(before["status"], "clear")
        self.assertIsNone(self.fx.origin_blob(novel))
        outcome = self.approve(
            "# New\n\n- draft\n- approved\n", document=novel,
            baseline=before["working_copy_blob"],
        )
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(self.fx.origin_text(novel), "# New\n\n- draft\n- approved")
        self.assertIsNone(self.fx.pending(novel))
        self.assertEqual(self.fx.read(self.fx.work, novel), "# New\n\n- draft\n- approved\n")

    def test_consecutive_dispositions_each_land_over_the_previous_copy(self):
        first = self.approve(EDITED)
        self.assertEqual(first["status"], "published")
        again = self.preflight()
        self.assertEqual(again["status"], "clear")
        self.assertEqual(again["working_copy_blob"], blob_of(EDITED))
        second_text = EDITED.replace("- line 5\n", "- line 5, second\n")
        second = self.approve(second_text, baseline=again["working_copy_blob"])
        self.assertEqual(second["status"], "published")
        self.assertEqual(self.fx.origin_text(), second_text.rstrip("\n"))
        self.assertEqual(len(self.calls()), 2)

    def test_the_branch_already_carrying_the_approved_blob_needs_no_tool(self):
        # The tool's "nothing to land": decided from the branch, not from words.
        self.fx.upstream_edit(EDITED)
        run(["git", "fetch", "-q", "origin", "master"], self.fx.work)
        outcome = self.approve(EDITED)
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(outcome["landed_via"], "already-present")
        self.assertIsNone(outcome["receipt_commit"])
        self.assertEqual(self.calls(), [])
        self.assertIsNone(self.fx.pending())
        self.assertIsNone(self.fx.applied())

    def test_a_primary_checkout_on_the_default_branch_fast_forwards_when_clean(self):
        outcome = self.approve(EDITED, root=self.fx.primary)
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(
            run(["git", "rev-parse", "HEAD"], self.fx.primary),
            run(["git", "rev-parse", "origin/master"], self.fx.primary),
        )
        self.assertEqual(self.fx.read(self.fx.primary), EDITED)

    def test_a_primary_with_commits_of_its_own_is_not_moved_and_keeps_the_landed_copy(self):
        run(["git", "checkout", "-q", "-b", "diverged"], self.fx.primary)
        self.fx.write(self.fx.primary, "own work\n", "own.txt")
        run(["git", "add", "own.txt"], self.fx.primary)
        run(["git", "commit", "-qm", "own"], self.fx.primary)
        head = run(["git", "rev-parse", "HEAD"], self.fx.primary)
        outcome = self.approve(EDITED, root=self.fx.primary)
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(run(["git", "rev-parse", "HEAD"], self.fx.primary), head)
        self.assertEqual(self.fx.read(self.fx.primary), EDITED)

    def test_a_dirty_primary_keeps_its_unrelated_work_through_a_landing(self):
        self.fx.write(self.fx.primary, "locally edited\n", "code.txt")
        outcome = self.approve(EDITED, root=self.fx.primary)
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(self.fx.read(self.fx.primary, "code.txt"), "locally edited\n")


class RefusalAndFailureTests(ApprovedFixture):
    """A missing or refusing tool is an outcome. Nothing is pushed by other
    means, nothing is retried by other means, and the content stays."""

    def assert_applied_and_recorded(self, outcome, text=EDITED):
        self.assertEqual(outcome["status"], "incomplete-publication")
        self.assertEqual(self.fx.read(self.fx.work), text)
        self.assertEqual(self.fx.pending(), outcome["pending_commit"])
        self.assertEqual(self.fx.applied(), blob_of(text))
        self.assertEqual(outcome["approved_blob"], blob_of(text))
        self.assertIsNone(outcome["published_blob"])
        self.assertEqual(outcome["document_edit"]["blob"], blob_of(text))

    def test_a_missing_tool_is_reported_and_leaves_the_content_and_records(self):
        self.remove_tool()
        tip = self.fx.origin_tip()
        outcome = self.approve(EDITED)
        self.assert_applied_and_recorded(outcome)
        self.assertEqual(outcome["reason"], "tool-missing")
        self.assertIn("docs-push was not found", outcome["message"])
        self.assertEqual(self.fx.origin_tip(), tip)

    def test_a_tool_without_expect_or_keep_is_reported_never_worked_around(self):
        for mode, flag in (("lacks-expect", "--expect"), ("lacks-keep", "--keep")):
            with self.subTest(mode=mode):
                self.setUp()
                self.mode(mode)
                tip = self.fx.origin_tip()
                outcome = self.approve(EDITED)
                self.assert_applied_and_recorded(outcome)
                self.assertEqual(outcome["reason"], "tool-lacks-capability")
                self.assertIn(flag, outcome["message"])
                self.assertEqual(self.fx.origin_tip(), tip)
                self.assertEqual(self.calls(), [])

    def test_a_refusal_carries_the_tools_exact_message(self):
        self.mode("refuse")
        tip = self.fx.origin_tip()
        outcome = self.approve(EDITED)
        self.assert_applied_and_recorded(outcome)
        self.assertEqual(outcome["reason"], "tool-refused")
        self.assertEqual(
            outcome["message"],
            f"docs-push: {DOC}: counts as code (docs/*.md: tests read it); "
            "use a pull request",
        )
        self.assertEqual(outcome["tool"]["returncode"], 2)
        self.assertEqual(self.fx.origin_tip(), tip)
        self.assertEqual(len(self.calls()), 1)

    def test_a_refusal_is_retried_through_the_tool_only(self):
        self.mode("refuse")
        self.approve(EDITED)
        self.mode("land")
        outcome = self.resume()
        self.assertEqual(outcome["status"], "published")
        self.assertTrue(outcome["resumed"].startswith("resumed"))
        self.assertEqual(len(self.calls()), 2)
        self.assertEqual(self.fx.origin_blob(), blob_of(EDITED))

    def test_a_file_changed_between_the_write_and_expect_is_never_overwritten(self):
        self.mode("racing-edit")
        tip = self.fx.origin_tip()
        outcome = self.approve(EDITED)
        self.assertEqual(outcome["status"], "incomplete-publication")
        self.assertIn("not the expected", outcome["message"])
        self.assertEqual(self.fx.origin_tip(), tip)
        raced = self.fx.read(self.fx.work)
        self.assertIn("an edit that raced the tool", raced)
        # The next run does not write over the outside edit; it reports it.
        self.mode("land")
        error = self.failure(self.resume)
        self.assertEqual(error.status, "document-not-baseline")
        self.assertEqual(self.fx.read(self.fx.work), raced)
        self.assertEqual(error.detail["preserved_blob"], blob_of(raced))
        self.assertIsNotNone(self.fx.pending())

    def test_misleading_success_output_never_decides_a_landing(self):
        self.mode("claims-success")
        tip = self.fx.origin_tip()
        outcome = self.approve(EDITED)
        self.assert_applied_and_recorded(outcome)
        self.assertEqual(outcome["reason"], "tool-reported-success-without-landing")
        self.assertIn("this checkout fast-forwarded", outcome["message"])
        self.assertEqual(outcome["tool"]["returncode"], 0)
        self.assertFalse(outcome["remote_contains_commit"])
        self.assertEqual(self.fx.origin_tip(), tip)

    def test_misleading_failure_output_does_not_hide_a_landing(self):
        self.mode("pushed-but-failed")
        outcome = self.approve(EDITED)
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(outcome["tool"]["returncode"], 2)
        self.assertIn("not acknowledged", outcome["tool"]["message"])
        self.assertEqual(self.fx.origin_blob(), blob_of(EDITED))
        self.assertIsNone(self.fx.pending())

    def test_a_missing_tool_does_not_repeat_a_confirmed_tracker_mutation(self):
        # The record the tracker holds is the same before and after: the helper
        # never touches it, and the preflight keeps reporting it.
        ref = tracker.transaction_ref(REPOSITORY, DOC)
        tracker.action_acquire(
            self.fx.work, ref, REPOSITORY, DOC, tracker_plan(), self.fx.origin_tip()
        )
        record, observed = tracker.read_record(self.fx.work, ref)
        self.remove_tool()
        outcome = self.approve(EDITED)
        self.assertEqual(outcome["status"], "incomplete-publication")
        self.assertEqual(self.fx.ref(ref), observed)
        error = self.failure(self.preflight)
        self.assertEqual(error.status, "publication-tool-unavailable")
        self.assertEqual(error.detail["pending_kinds"], ["publication", "tracker-transaction"])
        self.assertEqual(error.detail["tracker_transaction"]["status"], "outstanding")


def tracker_plan(entry_key="DW-3"):
    return {
        "entry_key": entry_key,
        "disposition": "new-issue",
        "steps": [
            {
                "kind": "issue-create",
                "target": "new issue in coghex/kanban",
                "payload_fingerprint": "sha256:body",
                "postcondition": "the issue exists with the approved body",
                "provides_marker": True,
            },
        ],
    }


class WriteProtocolTests(ApprovedFixture):
    """The capture-and-refuse protocol, preserved."""

    def test_an_outside_edit_after_the_preflight_is_refused_and_preserved(self):
        before = self.preflight()
        outside = NOTES + "\nan outside edit\n"
        self.fx.write(self.fx.work, outside)
        error = self.failure(
            self.approve, EDITED, baseline=before["working_copy_blob"]
        )
        self.assertEqual(error.status, "document-changed-before-write")
        self.assertEqual(self.fx.read(self.fx.work), outside)
        self.assertEqual(error.detail["preserved_blob"], blob_of(outside))
        self.assertIsNone(self.fx.pending())
        self.assertIsNone(self.fx.applied())
        self.assertEqual(self.calls(), [])

    def test_an_edit_racing_the_swap_is_put_back_never_overwritten(self):
        outside = NOTES + "\nan edit that raced the swap\n"
        real = approved.rename_aside

        def racing(target, aside):
            Path(target).write_text(outside, encoding="utf-8")
            real(target, aside)

        with unittest.mock.patch.object(approved, "rename_aside", racing):
            error = self.failure(self.approve, EDITED)
        self.assertEqual(error.status, "document-changed-before-write")
        self.assertTrue(error.detail["restored"])
        self.assertEqual(self.fx.read(self.fx.work), outside)
        self.assertEqual(error.detail["preserved_blob"], blob_of(outside))
        # Nothing was applied, so no obligation is left behind.
        self.assertIsNone(self.fx.pending())
        self.assertIsNone(self.fx.applied())

    def test_a_write_that_lost_a_race_leaves_the_winner_in_place(self):
        winner = "# the winner\n"
        real = approved.link_into_place

        def losing(scratch, target):
            Path(target).write_text(winner, encoding="utf-8")
            real(scratch, target)

        with unittest.mock.patch.object(approved, "link_into_place", losing):
            error = self.failure(self.approve, EDITED)
        self.assertEqual(error.status, "document-changed-before-write")
        self.assertEqual(self.fx.read(self.fx.work), winner)
        self.assertEqual(self.calls(), [])

    def test_a_staged_target_is_refused_before_anything_is_recorded(self):
        self.fx.write(self.fx.work, NOTES + "\nstaged\n")
        run(["git", "add", DOC], self.fx.work)
        error = self.failure(self.approve, EDITED)
        self.assertEqual(error.status, "document-staged")
        self.assertIsNone(self.fx.pending())
        self.assertEqual(self.calls(), [])
        self.assertIn("staged", self.fx.read(self.fx.work))

    def test_the_baseline_is_required(self):
        error = self.failure(
            approved.apply_and_publish, repository=REPOSITORY, branch="master",
            root=self.fx.work, document=DOC, content=EDITED.encode(),
        )
        self.assertEqual(error.status, "baseline-required")
        self.assertEqual(self.fx.read(self.fx.work), NOTES)

    def test_a_document_that_does_not_exist_is_never_created(self):
        error = self.failure(
            self.approve, "# made up\n", document="docs/never.md", baseline="0" * 40
        )
        self.assertEqual(error.status, "no-baseline")
        self.assertFalse((self.fx.work / "docs/never.md").exists())

    def test_content_identical_to_the_baseline_is_refused(self):
        error = self.failure(self.approve, NOTES)
        self.assertEqual(error.status, "no-mutation")

    def test_the_repository_is_verified_from_the_write_roots_own_origin(self):
        error = self.failure(
            approved.apply_and_publish, repository="someone/else", branch="master",
            root=self.fx.work, document=DOC, content=EDITED.encode(),
            expected_working_copy=blob_of(NOTES),
        )
        self.assertEqual(error.status, "owner-mismatch")
        self.assertEqual(self.fx.read(self.fx.work), NOTES)

    def test_a_held_lock_is_reported_and_a_stale_one_cleared_only_when_provably_dead(self):
        lock = approved.lock_ref(REPOSITORY, DOC)
        tip = self.fx.origin_tip()
        approved.acquire_lock(self.fx.work, lock, tip, REPOSITORY, DOC)
        error = self.failure(self.approve, EDITED)
        self.assertEqual(error.status, "locked")
        self.assertEqual(self.fx.read(self.fx.work), NOTES)
        # Held by this very (live) process: refused.
        self.assertEqual(
            self.failure(approved.clear_stale_lock, self.fx.work, lock).status,
            "lock-owner-live",
        )

    def test_unrelated_work_survives_success_and_failure(self):
        work = self.fx.work
        self.fx.write(work, "stash me\n", "stashed.txt")
        run(["git", "add", "stashed.txt"], work)
        run(["git", "stash", "push", "-q", "-m", "wip"], work)
        self.fx.write(work, "staged\n", "staged.txt")
        run(["git", "add", "staged.txt"], work)
        self.fx.write(work, "code, edited\n", "code.txt")
        self.fx.write(work, "untracked\n", "untracked.txt")
        head = run(["git", "rev-parse", "HEAD"], work)
        branches = run(["git", "branch", "--list"], work)
        stash = run(["git", "stash", "list"], work)
        index = run(["git", "ls-files", "--stage"], work)
        others = [line for line in self.fx.status(work)]

        def only_the_document_moved(extra):
            self.assertEqual(self.fx.status(work), sorted(others + extra))
            self.assertEqual(run(["git", "stash", "list"], work), stash)
            self.assertEqual(run(["git", "branch", "--list"], work), branches)
            self.assertEqual(run(["git", "rev-parse", "HEAD"], work), head)
            self.assertEqual(self.fx.read(work, "code.txt"), "code, edited\n")
            self.assertEqual(self.fx.read(work, "untracked.txt"), "untracked\n")

        self.mode("refuse")
        self.assertEqual(self.approve(EDITED)["status"], "incomplete-publication")
        only_the_document_moved([" M docs/notes.md"])
        self.assertEqual(run(["git", "ls-files", "--stage"], work), index)
        self.mode("land")
        self.assertEqual(self.resume()["status"], "published")
        # `--keep` leaves the landed copy in the pull request's worktree, so the
        # document still differs from the branch; nothing else does.
        only_the_document_moved([" M docs/notes.md"])
        self.assertEqual(run(["git", "ls-files", "--stage"], work), index)


class InterruptionTests(ApprovedFixture):
    """Requirement 5: a run that dies at any point leaves a record the next run
    resumes through the tool, or reconciles as already landed, without writing
    twice, pushing twice or repeating a tracker mutation."""

    def crash_at(self, name, *, times=1):
        """Make the named step raise SimulatedCrash the first `times` times."""
        real = getattr(approved, name)
        remaining = [times]

        def dying(*args, **kwargs):
            if remaining[0] > 0:
                remaining[0] -= 1
                raise SimulatedCrash(name)
            return real(*args, **kwargs)

        patcher = unittest.mock.patch.object(approved, name, dying)
        patcher.start()
        self.addCleanup(patcher.stop)

    def die(self, step, text=EDITED, **kwargs):
        self.crash_at(step)
        with self.assertRaises(SimulatedCrash):
            self.approve(text, **kwargs)
        unittest.mock.patch.stopall()
        self.setUpEnvironment()

    def setUpEnvironment(self):
        # stopall() also stops the PATH patch; put it back.
        patcher = unittest.mock.patch.dict(
            os.environ,
            {
                "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
                "FAKE_DOCS_PUSH_LOG": str(self.log_path),
                "FAKE_DOCS_PUSH_MODE": os.environ.get("FAKE_DOCS_PUSH_MODE", "land"),
                "DOCS_PUSH_CONFIG": str(self.bin / "no-such-config.json"),
            },
        )
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_dying_before_application_resumes_by_applying_then_publishing(self):
        self.die("verify_and_write")
        self.assertEqual(self.fx.read(self.fx.work), NOTES)
        self.assertIsNotNone(self.fx.pending())
        self.assertIsNone(self.fx.applied())
        preflight = self.preflight()
        self.assertEqual(preflight["status"], "pending")
        self.assertEqual(preflight["pending_kinds"], ["publication"])
        self.assertEqual(preflight["recorded_blob"], blob_of(EDITED))
        self.assertFalse(preflight["already_landed"])
        outcome = self.approve(EDITED)
        self.assertEqual(outcome["status"], "published")
        self.assertIn("applied-on-resume", outcome["resumed"])
        self.assertEqual(self.fx.origin_blob(), blob_of(EDITED))
        self.assertIsNone(self.fx.pending())
        self.assertEqual(len(self.calls()), 1)

    def test_resuming_needs_no_content_because_the_record_retains_it(self):
        self.die("verify_and_write")
        outcome = self.resume()
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(self.fx.origin_text(), EDITED.rstrip("\n"))

    def test_dying_between_the_swap_and_the_applied_record_is_recovered(self):
        self.die("record_applied_content")
        self.assertEqual(self.fx.read(self.fx.work), EDITED)
        self.assertIsNotNone(self.fx.pending())
        self.assertIsNone(self.fx.applied())
        outcome = self.approve(EDITED)
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(self.fx.origin_blob(), blob_of(EDITED))
        self.assertIsNone(self.fx.pending())
        self.assertIsNone(self.fx.applied())

    def test_dying_after_application_and_before_the_tool_resumes_through_the_tool(self):
        self.die("run_publication_tool")
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.fx.applied(), blob_of(EDITED))
        outcome = self.approve(EDITED)
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.fx.origin_blob(), blob_of(EDITED))

    def test_dying_after_publication_and_before_cleanup_reconciles_without_the_tool(self):
        self.die("settle_landed")
        tip = self.fx.origin_tip()
        self.assertEqual(self.fx.origin_blob(), blob_of(EDITED))
        self.assertIsNotNone(self.fx.pending())
        preflight = self.preflight()
        self.assertTrue(preflight["already_landed"])
        self.assertEqual(preflight["published_blob"], blob_of(EDITED))
        outcome = self.approve(EDITED)
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(outcome["resumed"], "already-landed")
        # The tool ran once, in the interrupted run, and nothing landed twice.
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.fx.origin_tip(), tip)
        self.assertIsNone(self.fx.pending())
        self.assertIsNone(self.fx.applied())

    def test_dying_after_a_three_way_merge_keeps_the_merged_copy_and_verifies_the_receipt(self):
        self.fx.upstream_edit(UPSTREAM_ELSEWHERE)
        run(["git", "fetch", "-q", "origin", "master"], self.fx.work)
        self.die("settle_landed")
        tip = self.fx.origin_tip()
        self.assertEqual(self.fx.origin_blob(), blob_of(MERGED))
        self.assertEqual(self.fx.read(self.fx.work), MERGED)
        # The local remote-tracking ref is stale by the time the next run
        # starts; the receipt has to be verified against a fresh fetch.
        run(["git", "update-ref", "refs/remotes/origin/master",
             run(["git", "rev-parse", "origin/master~1"], self.fx.work)], self.fx.work)
        outcome = self.approve(EDITED, baseline=blob_of(MERGED))
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(outcome["resumed"], "already-landed")
        self.assertEqual(outcome["landed_via"], "receipt")
        self.assertEqual(outcome["approved_blob"], blob_of(EDITED))
        self.assertEqual(outcome["published_blob"], blob_of(MERGED))
        self.assertTrue(outcome["merged"])
        self.assertEqual(self.fx.read(self.fx.work), MERGED)
        self.assertEqual(self.fx.origin_tip(), tip)
        self.assertEqual(len(self.calls()), 1)
        self.assertIsNone(self.fx.pending())

    def test_a_same_document_advance_after_the_push_is_still_published(self):
        self.die("settle_landed")
        receipt_blob = self.fx.origin_blob()
        self.fx.upstream_edit(EDITED.replace("- line 7\n", "- line 7, a later advance\n"))
        outcome = self.approve(EDITED)
        self.assertEqual(outcome["status"], "published")
        # Obtained from the receipt commit, not from the later tip.
        self.assertEqual(outcome["published_blob"], receipt_blob)
        self.assertNotEqual(self.fx.origin_blob(), receipt_blob)
        self.assertEqual(self.fx.read(self.fx.work), EDITED)
        self.assertIsNone(self.fx.pending())

    def test_landing_with_a_write_root_that_moved_on_keeps_the_record_and_says_so(self):
        self.die("settle_landed", )
        self.fx.upstream_edit(EDITED.replace("- line 7\n", "- line 7, a later advance\n"))
        self.fx.write(self.fx.work, EDITED + "\nlocal work after the landing\n")
        error = self.failure(self.resume)
        self.assertEqual(error.status, "landed-but-divergent")
        self.assertTrue(error.detail["remote_contains_commit"])
        self.assertEqual(error.detail["published_blob"], blob_of(EDITED))
        self.assertIsNotNone(self.fx.pending())
        self.assertIn("local work after", self.fx.read(self.fx.work))

    def failing_delete(self, ref):
        """`git update-ref -d <ref> <old>` fails, as a contended or read-only
        reference store would make it."""
        real = approved.git

        def git(args, **kwargs):
            if args[:2] == ["update-ref", "-d"] and args[2] == ref:
                return subprocess.CompletedProcess(args, 1, b"", b"fatal: cannot lock")
            return real(args, **kwargs)

        patcher = unittest.mock.patch.object(approved, "git", git)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_a_cleanup_that_fails_is_reported_and_the_next_run_finishes_it(self):
        for which, ref in (
            ("pending", approved.pending_ref(REPOSITORY, DOC)),
            ("applied", approved.applied_ref(REPOSITORY, DOC)),
        ):
            with self.subTest(record=which):
                self.setUp()
                self.failing_delete(ref)
                error = self.failure(self.approve, EDITED)
                self.assertEqual(error.status, "record-retained")
                self.assertTrue(error.detail["remote_contains_commit"])
                self.assertEqual(self.fx.origin_blob(), blob_of(EDITED))
                unittest.mock.patch.stopall()
                self.setUpEnvironment()
                # The landing is a fact; the retained record is reconciled, not
                # published a second time.
                outcome = self.resume() if which == "pending" else self.approve(EDITED)
                self.assertEqual(outcome["status"], "published")
                self.assertEqual(outcome["resumed"], "already-landed")
                self.assertEqual(len(self.calls()), 1)
                self.assertIsNone(self.fx.pending())
                self.assertIsNone(self.fx.applied())

    def test_clearing_is_bound_to_the_value_this_run_read(self):
        # A pending record replaced between the verification and the delete is
        # somebody else's; the compare-and-swap leaves it alone.
        self.die("settle_landed")
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        run(["git", "update-ref", record["ref"],
             self.helper_replacement()], self.fx.work)
        info = approved.landing(self.fx.work, "master", record)
        error = self.failure(
            approved.settle_landed, self.fx.work, REPOSITORY, "master", DOC, record, info
        )
        self.assertEqual(error.status, "record-retained")
        self.assertNotEqual(self.fx.pending(), record["commit"])

    def helper_replacement(self):
        return run(["git", "commit-tree", "HEAD^{tree}", "-m", "someone else's record"], self.fx.work)

    def test_a_different_disposition_cannot_be_approved_over_an_unresolved_record(self):
        self.die("run_publication_tool")
        other = EDITED.replace("- line 4\n", "- line 4, another disposition\n")
        error = self.failure(self.approve, other, baseline=blob_of(EDITED))
        self.assertEqual(error.status, "pending-differs-from-approved")
        self.assertEqual(error.detail["recorded_blob"], blob_of(EDITED))
        self.assertFalse(error.detail["remote_contains_commit"])
        self.assertEqual(self.fx.read(self.fx.work), EDITED)
        self.assertIsNotNone(self.fx.pending())
        self.assertEqual(self.calls(), [])

    def test_a_landed_record_still_blocks_a_different_disposition_until_reconciled(self):
        self.die("settle_landed")
        other = EDITED.replace("- line 4\n", "- line 4, another disposition\n")
        error = self.failure(self.approve, other, baseline=blob_of(EDITED))
        self.assertEqual(error.status, "pending-differs-from-approved")
        self.assertTrue(error.detail["remote_contains_commit"])
        self.assertEqual(self.resume()["status"], "published")
        self.assertEqual(
            self.approve(other, baseline=blob_of(EDITED))["status"], "published"
        )

    def test_a_record_with_no_pending_publication_cannot_be_resumed(self):
        error = self.failure(self.resume)
        self.assertEqual(error.status, "no-pending-publication")

    def test_an_interruption_between_the_tracker_checkpoint_and_resolution(self):
        # Requirement 5(d). A disposition's tracker mutations are confirmed and
        # checkpointed as publication-pending, the document is applied and
        # published, and the run dies before the tracker resolves. The next run
        # is stopped by the preflight rather than repeating anything, resumes
        # the publication through the tool, and resolves against the branch.
        ref = tracker.transaction_ref(REPOSITORY, DOC)
        tracker.action_acquire(
            self.fx.work, ref, REPOSITORY, DOC, tracker_plan(), self.fx.origin_tip()
        )
        record, observed = tracker.read_record(self.fx.work, ref)
        begun = tracker.action_begin(self.fx.work, ref, record, observed, 0)
        record, observed = tracker.read_record(self.fx.work, ref)
        identity = {
            "kind": "issue-create", "id": "311",
            "url": "https://github.com/coghex/kanban/issues/311",
            "document_token": "[#311]", "postcondition_verified": True,
        }
        tracker.action_confirm(
            self.fx.work, ref, record, observed, 0, identity, begun["begin_token"]
        )
        record, observed = tracker.read_record(self.fx.work, ref)
        tracker.action_publication_pending(self.fx.work, ref, record, observed)
        confirmed = tracker.read_record(self.fx.work, ref)[0]["steps"]

        text = NOTES.replace(
            "# Notes\n", "# Notes\n\n## Status\n\n- [x] DW-3. The finding — [#311]\n"
        )
        self.die("settle_landed", text=text)
        preflight = self.preflight()
        self.assertEqual(preflight["status"], "pending")
        self.assertEqual(preflight["pending_kinds"], ["publication", "tracker-transaction"])
        self.assertEqual(preflight["tracker_transaction"]["transaction_state"], "publication-pending")
        outcome = self.approve(text)
        self.assertEqual(outcome["status"], "published")
        resolved = tracker.action_resolve(
            self.fx.work, ref, *tracker.read_record(self.fx.work, ref), "branch", "master"
        )
        self.assertEqual(resolved["status"], "resolved")
        self.assertEqual(self.preflight()["status"], "clear")
        # Not one confirmed identity was dropped or repeated on the way.
        self.assertEqual(confirmed[0]["identity"]["id"], "311")
        self.assertEqual(len(self.calls()), 1)




class RecordSeedingMixin:
    """Plant the records a run could have left, by the same means the helper
    and the publisher use, so the cases below start from a state those tools
    really produce rather than from one a test invented."""

    def helper_record(self, *, document=DOC, text=EDITED, baseline=None, **overrides):
        """The helper's own pending record, as a run that died before
        replacing the document leaves it."""
        root = self.fx.work
        stored = approved._preserve(root, text.encode())
        fields = approved.new_pending_fields(
            REPOSITORY, document, stored,
            baseline or approved.working_blob(root, document),
            self.fx.origin_tip(), approved.default_message(document),
        )
        fields.update(overrides)
        commit = approved.build_pending_commit(root, document, fields)
        run(["git", "update-ref", approved.pending_ref(REPOSITORY, document), commit], root)
        return commit

    def raw_record(self, subject, body, *, document=DOC, text=EDITED):
        """A record under the helper's subject with a body of the test's choosing."""
        root = self.fx.work
        stored = approved._preserve(root, text.encode())
        tree = run(
            ["git", "mktree"], root,
            input=f"100644 blob {stored}\t{document.split('/')[-1]}\n",
        )
        if "/" in document:
            tree = run(
                ["git", "mktree"], root,
                input=f"040000 tree {tree}\t{document.split('/')[0]}\n",
            )
        commit = run(["git", "commit-tree", tree, "-m", f"{subject}\n\n{body}\n"], root)
        run(["git", "update-ref", approved.pending_ref(REPOSITORY, document), commit], root)
        return commit

    def publisher_record(self, text=EDITED, *, land=False, document=DOC):
        """The publisher's commit-shaped record, built the way it builds one: a
        child of the tip whose tree differs from the tip's by the one document."""
        root = self.fx.work
        tip = self.fx.origin_tip()
        stored = approved._preserve(root, text.encode())
        commit = publisher.build_commit(root, tip, document, stored, "docs: publisher commit")
        run(["git", "update-ref", publisher.pending_ref(REPOSITORY, document), commit], root)
        if land:
            run(["git", "push", "-q", "origin", f"{commit}:refs/heads/master"], root)
            run(["git", "fetch", "-q", "origin", "master"], root)
        return commit


class ReceiptBindingTests(RecordSeedingMixin, ApprovedFixture):
    """A landing is bound to the recorded document and attempt, never to bytes
    two documents can share."""

    def incomplete(self):
        self.mode("refuse")
        outcome = self.approve(EDITED)
        self.assertEqual(outcome["status"], "incomplete-publication")
        self.mode("land")
        return outcome

    def test_identical_approved_content_at_another_path_is_not_a_landing(self):
        self.incomplete()
        self.fx.upstream_edit(EDITED, OTHER, "the same bytes, another document")
        self.mode("refuse")
        outcome = self.resume()
        self.assertEqual(outcome["status"], "incomplete-publication")
        self.assertNotEqual(self.fx.origin_blob(DOC), blob_of(EDITED))
        self.assertEqual(self.fx.origin_blob(OTHER), blob_of(EDITED))
        self.assertIsNotNone(self.fx.pending())

    def test_a_commit_carrying_another_attempts_marker_is_not_this_landing(self):
        outcome = self.incomplete()
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        forged = dict(record, attempt="f" * 32)
        run(["git", "fetch", "-q", "origin", "master"], self.fx.primary)
        run(["git", "checkout", "-q", "master"], self.fx.primary)
        run(["git", "merge", "-q", "--ff-only", "origin/master"], self.fx.primary)
        self.fx.write(self.fx.primary, UPSTREAM_ELSEWHERE)
        run(["git", "add", DOC], self.fx.primary)
        run(["git", "commit", "-qm", f"docs: edit\n\n{approved.receipt_line(forged)}"], self.fx.primary)
        run(["git", "push", "-q", "origin", "master:master"], self.fx.primary)
        run(["git", "fetch", "-q", "origin", "master"], self.fx.work)
        info = approved.landing(self.fx.work, "master", record)
        self.assertFalse(info["landed"])
        self.assertEqual(outcome["pending_commit"], self.fx.pending())

    def test_a_marker_for_another_document_is_not_this_landing(self):
        self.incomplete()
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        other = dict(record, document=OTHER)
        run(["git", "fetch", "-q", "origin", "master"], self.fx.primary)
        run(["git", "checkout", "-q", "master"], self.fx.primary)
        run(["git", "merge", "-q", "--ff-only", "origin/master"], self.fx.primary)
        self.fx.write(self.fx.primary, EDITED)
        run(["git", "add", DOC], self.fx.primary)
        run(["git", "commit", "-qm", f"docs: edit\n\n{approved.receipt_line(other)}"], self.fx.primary)
        run(["git", "push", "-q", "origin", "master:master"], self.fx.primary)
        run(["git", "fetch", "-q", "origin", "master"], self.fx.work)
        # The bytes match the approved blob at the document's own path, so this
        # one lands by content ("nothing to land") and not by a receipt.
        info = approved.landing(self.fx.work, "master", record)
        self.assertTrue(info["landed"])
        self.assertEqual(info["via"], "already-present")

    def test_a_receipt_that_changes_other_paths_is_unverifiable(self):
        self.incomplete()
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        run(["git", "fetch", "-q", "origin", "master"], self.fx.primary)
        run(["git", "checkout", "-q", "master"], self.fx.primary)
        run(["git", "merge", "-q", "--ff-only", "origin/master"], self.fx.primary)
        self.fx.write(self.fx.primary, UPSTREAM_ELSEWHERE)
        self.fx.write(self.fx.primary, "# Other, too\n", OTHER)
        run(["git", "add", "-A"], self.fx.primary)
        run(["git", "commit", "-qm", f"docs: two\n\n{approved.receipt_line(record)}"], self.fx.primary)
        run(["git", "push", "-q", "origin", "master:master"], self.fx.primary)
        error = self.failure(self.resume)
        self.assertEqual(error.status, "receipt-unverifiable")
        self.assertEqual(error.detail["changed_paths"], sorted([DOC, OTHER]))
        self.assertIsNotNone(self.fx.pending())

    def test_a_tip_that_left_the_branch_history_cannot_verify_a_landing(self):
        orphan = run(["git", "commit-tree", "HEAD^{tree}", "-m", "orphan"], self.fx.work)
        self.helper_record(rendered_tip=orphan)
        error = self.failure(self.resume)
        self.assertEqual(error.status, "pending-stale")
        self.assertEqual(error.detail["rendered_tip"], orphan)
        self.assertIsNotNone(self.fx.pending())
        self.assertEqual(self.calls(), [])


class InvalidRecordTests(RecordSeedingMixin, ApprovedFixture):
    """A stale, changed, malformed or unverifiable record stops with a report.
    It is never ignored, and never deleted to make progress."""

    def assert_stops(self, status, *, expect_ref=True):
        before = self.fx.pending()
        self.assertIsNotNone(before)
        error = self.failure(self.approve, EDITED, baseline=blob_of(NOTES))
        self.assertEqual(error.status, status, error.message)
        self.assertEqual(self.fx.pending(), before)
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.fx.read(self.fx.work), NOTES)
        preflight_error = self.failure(self.preflight)
        # The preflight reports the record rather than reading it as absent.
        self.assertEqual(self.fx.pending(), before)
        return error, preflight_error

    def preflight_report(self):
        report = self.preflight()
        self.assertEqual(report["status"], "pending")
        self.assertIn("publication", report["pending_kinds"])
        return report

    def test_a_record_that_is_not_json_is_malformed(self):
        self.raw_record(approved.PENDING_SUBJECT, "this is not json")
        report = self.preflight_report()
        self.assertEqual(report["record_fault"]["status"], "pending-malformed")
        before = self.fx.pending()
        error = self.failure(self.approve, EDITED, baseline=blob_of(NOTES))
        self.assertEqual(error.status, "pending-malformed")
        self.assertEqual(self.fx.pending(), before)
        self.assertEqual(self.fx.read(self.fx.work), NOTES)

    def test_a_record_of_another_version_is_malformed(self):
        body = json.dumps({"version": 99})
        self.raw_record(approved.PENDING_SUBJECT, body)
        self.assertEqual(
            self.preflight_report()["record_fault"]["status"], "pending-malformed"
        )

    def test_a_record_whose_tree_does_not_hold_its_approved_blob_is_malformed(self):
        fields = approved.new_pending_fields(
            REPOSITORY, DOC, blob_of("something else\n"), blob_of(NOTES),
            self.fx.origin_tip(), "m",
        )
        self.raw_record(approved.PENDING_SUBJECT, json.dumps(fields))
        self.assertEqual(
            self.preflight_report()["record_fault"]["status"], "pending-malformed"
        )

    def test_a_record_keyed_under_another_document_is_malformed(self):
        fields = approved.new_pending_fields(
            REPOSITORY, OTHER, blob_of(EDITED), blob_of(NOTES), self.fx.origin_tip(), "m",
        )
        self.raw_record(approved.PENDING_SUBJECT, json.dumps(fields))
        report = self.preflight_report()
        self.assertEqual(report["record_fault"]["status"], "pending-malformed")
        self.assertIn(OTHER, report["record_fault"]["message"])

    def test_a_record_naming_a_tip_the_repository_lacks_is_unverifiable(self):
        self.helper_record(rendered_tip="a" * 40)
        report = self.preflight_report()
        self.assertEqual(report["record_fault"]["status"], "pending-unverifiable")
        before = self.fx.pending()
        error = self.failure(self.resume)
        self.assertEqual(error.status, "pending-unverifiable")
        self.assertEqual(self.fx.pending(), before)

    def test_a_reference_that_is_not_a_commit_is_malformed(self):
        stored = approved._preserve(self.fx.work, b"not a commit\n")
        run(["git", "update-ref", approved.pending_ref(REPOSITORY, DOC), stored], self.fx.work)
        report = self.preflight_report()
        self.assertEqual(report["record_fault"]["status"], "pending-malformed")

    def test_a_publisher_commit_that_does_not_carry_the_document_is_malformed(self):
        tip = self.fx.origin_tip()
        run(["git", "update-ref", approved.pending_ref(REPOSITORY, DOC), tip], self.fx.work)
        # The tip's tree carries the document, so plant a commit that does not.
        empty = run(["git", "mktree"], self.fx.work, input="")
        commit = run(["git", "commit-tree", empty, "-p", tip, "-m", "empty"], self.fx.work)
        run(["git", "update-ref", approved.pending_ref(REPOSITORY, DOC), commit], self.fx.work)
        report = self.preflight_report()
        self.assertEqual(report["record_fault"]["status"], "pending-malformed")

    def test_a_document_changed_beyond_the_baseline_and_the_approved_content_stops(self):
        self.helper_record()
        changed = NOTES + "\nsomeone's own edit\n"
        self.fx.write(self.fx.work, changed)
        before = self.fx.pending()
        error = self.failure(self.resume)
        self.assertEqual(error.status, "document-not-baseline")
        self.assertEqual(self.fx.pending(), before)
        self.assertEqual(self.fx.read(self.fx.work), changed)
        self.assertEqual(error.detail["working_blob"], blob_of(changed))
        self.assertEqual(self.calls(), [])

    def test_a_stale_tip_is_reported_by_the_preflight_without_raising(self):
        orphan = run(["git", "commit-tree", "HEAD^{tree}", "-m", "orphan"], self.fx.work)
        self.helper_record(rendered_tip=orphan)
        report = self.preflight_report()
        self.assertIsNone(report["already_landed"])
        self.assertEqual(report["record_fault"]["status"], "pending-stale")
        self.assertIn("by hand", report["resolution"])


class LegacyRecordTests(RecordSeedingMixin, ApprovedFixture):
    """Records the still-present publisher writes are read, resumed through the
    tool, or reconciled as landed, and none is silently lost or duplicated."""

    def test_an_unlanded_publisher_record_is_resumed_through_the_tool(self):
        commit = self.publisher_record()
        self.fx.write(self.fx.work, EDITED)
        report = self.preflight()
        self.assertEqual(report["status"], "pending")
        self.assertEqual(report["record_form"], approved.FORM_PUBLISHER)
        self.assertEqual(report["pending_commit"], commit)
        self.assertEqual(report["recorded_blob"], blob_of(EDITED))
        self.assertFalse(report["already_landed"])
        outcome = self.resume()
        self.assertEqual(outcome["status"], "published")
        self.assertIn("publisher record re-seated", outcome["resumed"])
        self.assertEqual(self.fx.origin_blob(), blob_of(EDITED))
        self.assertIsNone(self.fx.pending())
        self.assertEqual(len(self.calls()), 1)

    def test_a_publisher_record_whose_document_was_never_replaced_is_applied_then_published(self):
        self.publisher_record()
        outcome = self.approve(EDITED, baseline=blob_of(NOTES))
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(self.fx.origin_blob(), blob_of(EDITED))
        self.assertIsNone(self.fx.pending())

    def test_a_publisher_record_the_publisher_already_pushed_is_reconciled(self):
        commit = self.publisher_record(land=True)
        self.fx.write(self.fx.work, EDITED)
        tip = self.fx.origin_tip()
        report = self.preflight()
        self.assertTrue(report["already_landed"])
        outcome = self.resume()
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(outcome["resumed"], "already-landed")
        self.assertEqual(outcome["receipt_commit"], commit)
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.fx.origin_tip(), tip)
        self.assertIsNone(self.fx.pending())

    def test_a_publisher_record_over_a_foreign_document_stops(self):
        self.publisher_record()
        self.fx.write(self.fx.work, NOTES + "\nforeign\n")
        before = self.fx.pending()
        error = self.failure(self.resume)
        self.assertEqual(error.status, "document-not-baseline")
        self.assertEqual(self.fx.pending(), before)

    def test_the_publisher_does_not_publish_over_a_helper_record(self):
        # The helper's record is parentless on purpose: the publisher resuming
        # it would otherwise push the record's commit straight to the branch.
        # A coordination lane for the document, as §7 declares one, so the
        # publisher would otherwise publish rather than decline.
        self.fx.upstream_edit(
            "# Contract\n\n## 7. Document publication classification\n\n```text\n"
            f"{DOC} | coordination | audit-report\n```\n\n## 8. Next\n",
            "docs/agent-workflow-contract.md",
        )
        run(["git", "fetch", "-q", "origin", "master"], self.fx.work)
        self.mode("refuse")
        self.approve(EDITED)
        tip = self.fx.origin_tip()
        with self.assertRaises(publisher.PublishError):
            publisher.publish(
                repository=REPOSITORY, branch="master", root=self.fx.work,
                document=DOC, content=EDITED.encode(), message="legacy",
                expected_tip=tip,
            )
        self.assertEqual(self.fx.origin_tip(), tip)
        self.assertIsNotNone(self.fx.pending())

    def test_the_publishers_preflight_still_sees_a_helper_record(self):
        self.mode("refuse")
        self.approve(EDITED)
        report = publisher.check_pending(self.fx.work, REPOSITORY, "master", DOC)
        self.assertEqual(report["status"], "pending")
        self.assertIn("publication", report["pending_kinds"])
        self.assertEqual(report["recorded_blob"], blob_of(EDITED))

    def test_a_local_checkpoint_cannot_hide_the_helpers_outstanding_publication(self):
        # The tracker resolves against the locally applied document, and says
        # so; the publication obligation is still there for both preflights.
        self.mode("refuse")
        self.approve(EDITED)
        ref = tracker.transaction_ref(REPOSITORY, DOC)
        text = EDITED
        applied_text = text.replace(
            "# Notes\n", "# Notes\n\n## Status\n\n- [x] DW-3. The finding — [#311]\n"
        )
        # Apply the terminal entry the way a second disposition would: the
        # tracker's own steps, then the document the helper wrote.
        self.fx.write(self.fx.work, applied_text)
        tracker.action_acquire(
            self.fx.work, ref, REPOSITORY, DOC, tracker_plan(), self.fx.origin_tip()
        )
        record, observed = tracker.read_record(self.fx.work, ref)
        begun = tracker.action_begin(self.fx.work, ref, record, observed, 0)
        record, observed = tracker.read_record(self.fx.work, ref)
        tracker.action_confirm(
            self.fx.work, ref, record, observed, 0,
            {"kind": "issue-create", "id": "311",
             "url": "https://github.com/coghex/kanban/issues/311",
             "document_token": "[#311]", "postcondition_verified": True},
            begun["begin_token"],
        )
        # The document no longer holds the helper's applied content, so the
        # tracker refuses to treat it as locally applied.
        with self.assertRaises(tracker.TransactionError) as caught:
            tracker.action_resolve(
                self.fx.work, ref, *tracker.read_record(self.fx.work, ref), "local", "master"
            )
        self.assertEqual(caught.exception.status, "local-resolution-refused")
        self.assertIn("has been changed since", caught.exception.message)
        self.assertIsNotNone(self.fx.pending())


class LocalCheckpointTests(ApprovedFixture):
    """The tracker half resolves against what the helper applied and recorded,
    and says it is not published."""

    STATUS = NOTES.replace("# Notes\n", "# Notes\n\n## Status\n\n- [x] DW-3. The finding — [#311]\n")

    def confirmed_transaction(self):
        ref = tracker.transaction_ref(REPOSITORY, DOC)
        tracker.action_acquire(
            self.fx.work, ref, REPOSITORY, DOC, tracker_plan(), self.fx.origin_tip()
        )
        record, observed = tracker.read_record(self.fx.work, ref)
        begun = tracker.action_begin(self.fx.work, ref, record, observed, 0)
        record, observed = tracker.read_record(self.fx.work, ref)
        tracker.action_confirm(
            self.fx.work, ref, record, observed, 0,
            {"kind": "issue-create", "id": "311",
             "url": "https://github.com/coghex/kanban/issues/311",
             "document_token": "[#311]", "postcondition_verified": True},
            begun["begin_token"],
        )
        return ref

    def resolve_local(self, ref):
        return tracker.action_resolve(
            self.fx.work, ref, *tracker.read_record(self.fx.work, ref), "local", "master"
        )

    def test_an_applied_unlanded_document_resolves_locally_and_keeps_the_obligation(self):
        ref = self.confirmed_transaction()
        self.mode("refuse")
        outcome = self.approve(self.STATUS)
        self.assertEqual(outcome["status"], "incomplete-publication")
        resolved = self.resolve_local(ref)
        self.assertEqual(resolved["status"], "resolved")
        self.assertEqual(resolved["source"], "local")
        self.assertFalse(resolved["published"])
        self.assertEqual(resolved["publication_obligation"], "outstanding")
        self.assertEqual(resolved["pending_publication_commit"], outcome["pending_commit"])
        # The tracker is clear; the publication is not, for either preflight.
        report = self.preflight()
        self.assertEqual(report["status"], "pending")
        self.assertEqual(report["pending_kinds"], ["publication"])
        self.assertEqual(report["tracker_transaction"]["status"], "clear")
        self.assertEqual(
            publisher.check_pending(self.fx.work, REPOSITORY, "master", DOC)["pending_kinds"],
            ["publication"],
        )
        # Landing later clears the obligation without touching the tracker.
        self.mode("land")
        self.assertEqual(self.resume()["status"], "published")
        self.assertEqual(self.preflight()["status"], "clear")

    def test_a_missing_tool_leaves_the_content_and_the_record_and_no_mutation_repeats(self):
        ref = self.confirmed_transaction()
        self.remove_tool()
        outcome = self.approve(self.STATUS)
        self.assertEqual(outcome["reason"], "tool-missing")
        self.assertEqual(self.fx.applied(), blob_of(self.STATUS))
        resolved = self.resolve_local(ref)
        self.assertEqual(resolved["publication_obligation"], "outstanding")
        self.assertIsNone(tracker.read_record(self.fx.work, ref)[0])
        self.assertEqual(self.fx.pending(), outcome["pending_commit"])

    def test_a_hand_edit_permits_nothing(self):
        ref = self.confirmed_transaction()
        self.fx.write(self.fx.work, self.STATUS)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.resolve_local(ref)
        self.assertEqual(caught.exception.status, "local-resolution-refused")
        self.assertIn("never applied a disposition", caught.exception.message)

    def test_a_landed_document_resolves_on_the_branch_not_locally(self):
        ref = self.confirmed_transaction()
        self.assertEqual(self.approve(self.STATUS)["status"], "published")
        with self.assertRaises(tracker.TransactionError) as caught:
            self.resolve_local(ref)
        self.assertEqual(caught.exception.status, "local-resolution-refused")
        resolved = tracker.action_resolve(
            self.fx.work, ref, *tracker.read_record(self.fx.work, ref), "branch", "master"
        )
        self.assertEqual(resolved["status"], "resolved")
        self.assertNotIn("publication_obligation", resolved)

    def test_a_malformed_applied_record_licenses_nothing(self):
        ref = self.confirmed_transaction()
        self.fx.write(self.fx.work, self.STATUS)
        commit = run(["git", "rev-parse", "HEAD"], self.fx.work)
        run(["git", "update-ref", approved.applied_ref(REPOSITORY, DOC), commit], self.fx.work)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.resolve_local(ref)
        self.assertEqual(caught.exception.status, "local-resolution-refused")
        self.assertIn("not the blob", caught.exception.message)

    def test_the_tracker_loads_no_publisher_and_keys_its_references_like_the_helper(self):
        source = (TOOLS / "tracker_transaction.py").read_text(encoding="utf-8")
        self.assertNotIn("publish_coordination_doc", source)
        self.assertFalse(hasattr(tracker, "publication_module"))
        key = approved._key(REPOSITORY, DOC)
        self.assertEqual(key, tracker.record_key(REPOSITORY, DOC))
        self.assertEqual(key, publisher._key(REPOSITORY, DOC))
        self.assertEqual(
            tracker.applied_ref(REPOSITORY, DOC), approved.applied_ref(REPOSITORY, DOC)
        )
        self.assertEqual(
            tracker.pending_publication_ref(REPOSITORY, DOC),
            approved.pending_ref(REPOSITORY, DOC),
        )
        self.assertEqual(tracker.APPLIED_NAMESPACE, approved.APPLIED_NAMESPACE)
        self.assertEqual(
            tracker.PENDING_PUBLICATION_NAMESPACE, approved.PENDING_NAMESPACE
        )


class PreflightAndCommandLineTests(RecordSeedingMixin, ApprovedFixture):
    def test_a_clear_preflight_reports_the_binding_fields(self):
        report = self.preflight()
        self.assertEqual(report["status"], "clear")
        self.assertEqual(report["pending_kinds"], [])
        self.assertEqual(report["publication_tip"], self.fx.origin_tip())
        self.assertEqual(report["working_copy_blob"], blob_of(NOTES))
        self.assertEqual(report["pending_ref"], approved.pending_ref(REPOSITORY, DOC))
        self.assertEqual(report["tracker_transaction"]["status"], "clear")
        self.assertTrue(report["publication_tool"]["available"])

    def test_the_working_copy_blob_of_a_missing_document_is_null(self):
        self.assertIsNone(self.preflight(document="docs/absent.md")["working_copy_blob"])

    def test_the_tip_is_freshly_fetched_not_read_from_a_cached_ref(self):
        stale = self.fx.origin_tip()
        self.fx.upstream_edit(UPSTREAM_ELSEWHERE)
        # Every worktree shares the clone's remote-tracking refs, so wind the
        # cached one back to what a run that fetched long ago would hold.
        run(["git", "update-ref", "refs/remotes/origin/master", stale], self.fx.work)
        self.assertEqual(run(["git", "rev-parse", "origin/master"], self.fx.work), stale)
        self.assertEqual(self.preflight()["publication_tip"], self.fx.origin_tip())
        self.assertNotEqual(self.fx.origin_tip(), stale)

    def test_an_unreadable_tracker_record_is_pending_not_clear(self):
        ref = tracker.transaction_ref(REPOSITORY, DOC)
        blob = approved._preserve(self.fx.work, b"not json")
        tree = run(["git", "mktree"], self.fx.work, input=f"100644 blob {blob}\trecord.json\n")
        commit = run(["git", "commit-tree", tree, "-m", "broken"], self.fx.work)
        run(["git", "update-ref", ref, commit], self.fx.work)
        report = self.preflight()
        self.assertEqual(report["status"], "pending")
        self.assertEqual(report["pending_kinds"], ["tracker-transaction"])
        self.assertFalse(report["tracker_transaction"]["record_readable"])

    def test_a_tool_that_cannot_land_a_document_fails_the_preflight_closed(self):
        self.mode("lacks-keep")
        error = self.failure(self.preflight)
        self.assertEqual(error.status, "publication-tool-unavailable")
        self.assertEqual(error.detail["tool_reason"], "tool-lacks-capability")
        self.assertEqual(error.detail["publication_tip"], self.fx.origin_tip())
        self.remove_tool()
        self.assertEqual(self.failure(self.preflight).detail["tool_reason"], "tool-missing")

    def test_a_tracker_module_that_cannot_be_read_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            lone = Path(directory) / "approved_document.py"
            shutil.copy(TOOLS / "approved_document.py", lone)
            module = _load("_kanban_approved_alone", str(lone))
            with self.assertRaises(module.DocumentError) as caught:
                module.check_pending(self.fx.work, REPOSITORY, "master", DOC)
        self.assertEqual(caught.exception.status, "tracker-transaction-unavailable")

    def test_the_command_line_publishes_and_exits_zero(self):
        content = self.fx.dir / "content.md"
        content.write_text(EDITED, encoding="utf-8")
        code, outcome = self.cli(
            "--branch", "master", "--content", str(content),
            "--expected-working-copy", blob_of(NOTES),
            "--expected-tip", self.fx.origin_tip(), "--message", "docs: from the cli",
        )
        self.assertEqual(code, 0)
        self.assertEqual(outcome["status"], "published")
        self.assertIn("docs: from the cli", self.calls()[0]["message"])

    def test_an_incomplete_publication_exits_nonzero_with_the_tools_message(self):
        self.mode("refuse")
        content = self.fx.dir / "content.md"
        content.write_text(EDITED, encoding="utf-8")
        code, outcome = self.cli(
            "--branch", "master", "--content", str(content),
            "--expected-working-copy", blob_of(NOTES),
        )
        self.assertEqual(code, 1)
        self.assertEqual(outcome["status"], "incomplete-publication")
        self.assertIn("counts as code", outcome["message"])

    def test_the_command_line_resume_and_preflight(self):
        self.mode("refuse")
        content = self.fx.dir / "content.md"
        content.write_text(EDITED, encoding="utf-8")
        self.cli("--branch", "master", "--content", str(content),
                 "--expected-working-copy", blob_of(NOTES))
        code, report = self.cli("--branch", "master", "--check-pending")
        self.assertEqual(code, 1)
        self.assertEqual(report["status"], "pending")
        self.mode("land")
        code, outcome = self.cli("--branch", "master", "--resume")
        self.assertEqual((code, outcome["status"]), (0, "published"))
        code, report = self.cli("--branch", "master", "--check-pending")
        self.assertEqual((code, report["status"]), (0, "clear"))

    def test_the_command_line_reports_failures_in_the_envelope(self):
        code, outcome = self.cli("--branch", "master", "--resume")
        self.assertEqual(code, 1)
        self.assertEqual(outcome["status"], "no-pending-publication")
        self.assertIn("document_edit", outcome)
        self.assertIn("remote_contains_commit", outcome)

    def test_a_scratch_content_path_is_minted_inside_the_common_git_directory(self):
        code, _ = 0, None
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = approved.main(
                ["--repo", REPOSITORY, "--root", str(self.fx.work), "--path", DOC,
                 "--new-content-file"]
            )
        self.assertEqual(code, 0)
        minted = Path(buffer.getvalue().strip())
        self.addCleanup(minted.unlink, missing_ok=True)
        common = Path(run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], self.fx.work))
        self.assertEqual(minted.parent.resolve(), common.resolve())
        self.assertTrue(minted.is_file())

    def test_the_command_line_clears_a_stale_lock_only_when_its_owner_is_gone(self):
        lock = approved.lock_ref(REPOSITORY, DOC)
        dead = json.dumps(
            {"host": approved.socket.gethostname(), "pid": 2**22 + 12345,
             "repository": REPOSITORY, "document": DOC},
            sort_keys=True, separators=(",", ":"),
        )
        commit = run(["git", "commit-tree", "HEAD^{tree}", "-m", dead], self.fx.work)
        run(["git", "update-ref", lock, commit], self.fx.work)
        code, outcome = self.cli("--branch", "master", "--clear-stale-lock")
        self.assertEqual((code, outcome["status"]), (0, "cleared"))
        self.assertIsNone(self.fx.ref(lock))


if __name__ == "__main__":
    unittest.main()
