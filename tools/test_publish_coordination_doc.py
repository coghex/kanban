"""Executable coverage for tools/publish_coordination_doc.py.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Issue #315. Every case below performs a real publication against temporary Git
repositories, and every one is a defect the twelve canonical review rounds on
PR #313 found in the same mechanism written as shell inside four Markdown
assets. A regression therefore reintroduces a known failure rather than an
imagined one.

The fixtures build a bare origin plus a clone, and — because the declared
assets write in the `docs-wip` linked worktree while publication targets the
default branch — a linked worktree on another branch is the *ordinary* write
root here, not an exotic case.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import shlex
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def _load():
    source = REPO_ROOT / "tools" / "publish_coordination_doc.py"
    spec = importlib.util.spec_from_file_location("_kanban_publish_helper", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


publisher = _load()


CLASSIFICATION = """# Contract

## 7. Document publication classification

```text
docs/ui-bugs.md | coordination | audit-report
docs/drainer-bugs.md | coordination | audit-report
docs/design.md | pr-atomic | test-parsed
codex-plugin/ | pr-atomic | test-parsed
```

## 8. Next section
"""


def run(args, cwd, **kw):
    proc = subprocess.run(args, cwd=str(cwd), capture_output=True, text=True, **kw)
    if proc.returncode != 0:
        raise AssertionError(f"{args} failed in {cwd}:\n{proc.stderr}")
    return proc.stdout.strip()


class Fixture:
    """A bare origin, a primary clone, and a `docs-wip` linked worktree."""

    def __init__(self, directory: Path, *, origin_name: str = "kanban"):
        self.dir = directory
        # The helper establishes the owner from the write root's own origin
        # URL, so the bare repository is placed where its *path* normalizes to
        # the slug under test. Rewriting the URL to a github.com address would
        # resolve the same way but break every fetch and push in the fixture.
        self.origin = directory / "coghex" / f"{origin_name}.git"
        self.origin.parent.mkdir(parents=True, exist_ok=True)
        self.primary = directory / "primary"
        run(["git", "init", "-q", "--bare", str(self.origin)], directory)
        run(["git", "clone", "-q", str(self.origin), str(self.primary)], directory)
        run(["git", "config", "user.email", "t@example.com"], self.primary)
        run(["git", "config", "user.name", "Test"], self.primary)
        (self.primary / "docs").mkdir()
        (self.primary / "docs" / "agent-workflow-contract.md").write_text(
            CLASSIFICATION, encoding="utf-8"
        )
        (self.primary / "docs" / "ui-bugs.md").write_text("# UI\n\n- one\n", encoding="utf-8")
        (self.primary / "docs" / "drainer-bugs.md").write_text("# Drainer\n", encoding="utf-8")
        (self.primary / "docs" / "design.md").write_text("# Design\n", encoding="utf-8")
        run(["git", "add", "-A"], self.primary)
        run(["git", "commit", "-qm", "init"], self.primary)
        run(["git", "branch", "-M", "master"], self.primary)
        run(["git", "push", "-q", "origin", "master:master"], self.primary)
        run(["git", "fetch", "-q", "origin", "master"], self.primary)
        # The ordinary write root: a linked worktree on its own branch.
        self.docs = directory / "docs-wip"
        run(
            ["git", "worktree", "add", "-q", "-b", "docs-wip", str(self.docs), "master"],
            self.primary,
        )

    def push_remote_url(self):
        return str(self.origin)

    def publish(self, content: str, *, root: Path | None = None, path="docs/ui-bugs.md",
                repo="coghex/kanban", branch="master"):
        blob = self.dir / "approved.md"
        blob.write_text(content, encoding="utf-8")
        try:
            return publisher.publish(
                repository=repo,
                branch=branch,
                root=root or self.docs,
                document=path,
                content=blob.read_bytes(),
                message="docs: approved mutation",
            )
        finally:
            blob.unlink(missing_ok=True)

    def remote_content(self, path="docs/ui-bugs.md"):
        return run(["git", "show", f"origin/master:{path}"], self.primary)

    def advance_remote(self, path="docs/ui-bugs.md", text="\n- somebody else\n"):
        """Another writer lands a change on the publication branch."""
        other = self.dir / "other"
        if not other.exists():
            run(["git", "clone", "-q", str(self.origin), str(other)], self.dir)
            run(["git", "config", "user.email", "o@example.com"], other)
            run(["git", "config", "user.name", "Other"], other)
        run(["git", "fetch", "-q", "origin", "master"], other)
        run(["git", "checkout", "-q", "-B", "master", "origin/master"], other)
        target = other / path
        target.write_text(target.read_text() + text, encoding="utf-8")
        run(["git", "add", "-A"], other)
        run(["git", "commit", "-qm", "theirs"], other)
        run(["git", "push", "-q", "origin", "HEAD:master"], other)


class PublishTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.fx = Fixture(Path(self._tmp.name))
        self.addCleanup(self._tmp.cleanup)

    # -- the ordinary success ------------------------------------------------

    def test_a_clean_publication_changes_exactly_one_path(self):
        result = self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(result["status"], "published")
        self.assertTrue(result["remote_contains_commit"])
        self.assertIn("- two", self.fx.remote_content())
        changed = run(
            ["git", "diff", "--name-only", f"{result['commit']}^", result["commit"]],
            self.fx.primary,
        )
        self.assertEqual(changed.splitlines(), ["docs/ui-bugs.md"])

    def test_unrelated_work_in_the_write_root_is_untouched(self):
        # Requirement 4: the helper owns only the document path. Staged and
        # unstaged work elsewhere is the caller's and must survive.
        (self.fx.docs / "docs" / "drainer-bugs.md").write_text("# Drainer\n- wip\n")
        run(["git", "add", "docs/drainer-bugs.md"], self.fx.docs)
        (self.fx.docs / "scratch.txt").write_text("untracked\n")
        self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertIn("- wip", (self.fx.docs / "docs" / "drainer-bugs.md").read_text())
        self.assertTrue((self.fx.docs / "scratch.txt").exists())
        staged = run(["git", "diff", "--cached", "--name-only"], self.fx.docs)
        self.assertEqual(staged.splitlines(), ["docs/drainer-bugs.md"])

    def test_the_write_roots_head_and_branch_are_untouched(self):
        # The write root is a linked worktree on `docs-wip`; publication targets
        # `master` and must never check out, reset, switch or advance anything.
        before_head = run(["git", "rev-parse", "HEAD"], self.fx.docs)
        before_branch = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], self.fx.docs)
        self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(run(["git", "rev-parse", "HEAD"], self.fx.docs), before_head)
        self.assertEqual(
            run(["git", "rev-parse", "--abbrev-ref", "HEAD"], self.fx.docs), before_branch
        )

    def test_the_document_path_is_left_unstaged(self):
        # Requirement 4's documented end state, which reconciliation compares
        # against: the working file carries the approved content and the index
        # entry is untouched.
        self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertIn("- two", (self.fx.docs / "docs" / "ui-bugs.md").read_text())
        staged = run(["git", "diff", "--cached", "--name-only"], self.fx.docs)
        self.assertNotIn("docs/ui-bugs.md", staged.splitlines())

    def test_the_result_reports_the_region_that_changed(self):
        # Whole-file content makes a collateral rewrite invisible to the
        # changed-path check, so the run reports what it published.
        result = self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(result["changes"]["added"], 1)
        self.assertEqual(result["changes"]["removed"], 0)
        self.assertTrue(result["changes"]["hunks"])
        self.assertEqual(
            result["published_blob"],
            run(["git", "rev-parse", f"{result['commit']}:docs/ui-bugs.md"], self.fx.primary),
        )

    def test_a_collateral_rewrite_is_visible_in_the_report(self):
        result = self.fx.publish("# UI\n")  # the list is gone
        self.assertEqual(result["status"], "published")
        self.assertGreater(result["changes"]["removed"], 0)

    # -- the result contract -------------------------------------------------

    def test_a_minted_content_path_is_unique_per_invocation(self):
        # Two runs must never share the scratch file: a fixed or
        # document-derived name lets one run read the other's approved content
        # and publish it under its own document's name.
        seen = {
            str(publisher.new_content_file(self.fx.docs, doc))
            for doc in ("docs/ui-bugs.md", "docs/ui-bugs.md", "docs/drainer-bugs.md")
        }
        self.assertEqual(len(seen), 3)
        for path in seen:
            self.assertTrue(Path(path).is_file())
            Path(path).unlink()

    def test_every_published_result_carries_a_change_summary(self):
        fresh = self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertIn("changes", fresh)
        # ...including a recovered one, which the assets tell the caller to
        # check against the disposition just as they do a fresh publication.
        original = publisher.is_ancestor
        publisher.is_ancestor = lambda root, commit, revision: False
        try:
            with self.assertRaises(publisher.PublishError):
                self.fx.publish("# UI\n\n- one\n- two\n- three\n")
        finally:
            publisher.is_ancestor = original
        recovered = self.fx.publish("# UI\n\n- one\n- two\n- three\n")
        self.assertEqual(recovered["resumed"], "already-landed")
        self.assertIn("changes", recovered)
        self.assertEqual(recovered["changes"]["added"], 1)

    def test_a_pre_write_failure_still_reports_all_three_states(self):
        # §9.5 is mandatory for every unpublished outcome, not only for the
        # ones that got far enough to build a commit: a caller told to report
        # three states cannot report them from a result that omits two.
        # An ineligible document returns rather than raises, and still
        # answers all three states.
        result = self.fx.publish("# Design\n\nchanged\n", path="docs/design.md")
        self.assertEqual(result["status"], "not-published")
        self.assertTrue(result["document_edit"]["exists"])
        self.assertIsNone(result["local_publication_commit"])
        self.assertFalse(result["remote_contains_commit"])

    def test_a_failed_push_reports_all_three_states(self):
        original = publisher.build_commit

        def advancing_build(root, tip, document, blob, message):
            commit = original(root, tip, document, blob, message)
            self.fx.advance_remote()
            return commit

        publisher.build_commit = advancing_build
        self.addCleanup(setattr, publisher, "build_commit", original)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        detail = caught.exception.detail
        self.assertTrue(detail["document_edit"]["exists"])
        self.assertIsNotNone(detail["local_publication_commit"])
        self.assertFalse(detail["remote_contains_commit"])

    def test_an_index_only_edit_to_the_document_is_refused(self):
        # `git apply --cached` leaves the working file untouched, so hashing it
        # alone passes. Publishing over that would carry unapproved staged work
        # forward and break the single unstaged end state.
        blob = run(
            ["git", "hash-object", "-w", "--stdin"], self.fx.docs,
            input="# UI\n\n- staged only\n",
        )
        run(
            ["git", "update-index", "--cacheinfo", f"100644,{blob},docs/ui-bugs.md"],
            self.fx.docs,
        )
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "document-staged")
        self.assertEqual(self.fx.remote_content(), "# UI\n\n- one")

    def test_a_pre_lock_failure_still_reports_all_three_states(self):
        # Owner verification, the fetch and lock contention all happen before
        # the sequence starts; a caller branching on any non-published result
        # must still be able to report §9.5's three states.
        lock = publisher.lock_ref("coghex/kanban", "docs/ui-bugs.md")
        tip = run(["git", "rev-parse", "origin/master"], self.fx.docs)
        held = publisher.acquire_lock(self.fx.docs, lock, tip)
        self.addCleanup(publisher.release_lock, self.fx.docs, lock, held)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        detail = caught.exception.detail
        self.assertEqual(caught.exception.status, "locked")
        self.assertIn("document_edit", detail)
        self.assertIn("local_publication_commit", detail)
        self.assertIn("remote_contains_commit", detail)

    def test_an_owner_mismatch_reports_all_three_states(self):
        with tempfile.TemporaryDirectory() as other_dir:
            other = Fixture(Path(other_dir), origin_name="synarchy")
            with self.assertRaises(publisher.PublishError) as caught:
                other.publish("# UI\n\n- one\n- two\n", repo="coghex/kanban")
            for key in ("document_edit", "local_publication_commit", "remote_contains_commit"):
                self.assertIn(key, caught.exception.detail)

    def test_an_edit_landing_after_the_final_check_is_preserved(self):
        # Injected between the last verification and the write — the window the
        # in-process read closes. Whatever was there is written to the object
        # database before the run refuses, so it is recoverable rather than
        # destroyed.
        original = publisher.verify_and_write
        target = self.fx.docs / "docs" / "ui-bugs.md"

        def racing_write(root, document, baseline, content):
            target.write_text(target.read_text() + "- foreign\n")
            return original(root, document, baseline, content)

        publisher.verify_and_write = racing_write
        self.addCleanup(setattr, publisher, "verify_and_write", original)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "document-changed-before-write")
        self.assertIn("- foreign", target.read_text())
        preserved = caught.exception.detail["preserved_blob"]
        self.assertIn(
            "- foreign", run(["git", "cat-file", "-p", preserved], self.fx.docs)
        )
        self.assertEqual(self.fx.remote_content(), "# UI\n\n- one")

    def test_a_landed_record_is_not_cleared_over_a_divergent_document(self):
        original = publisher.is_ancestor
        publisher.is_ancestor = lambda root, commit, revision: False
        try:
            with self.assertRaises(publisher.PublishError):
                self.fx.publish("# UI\n\n- one\n- two\n")
        finally:
            publisher.is_ancestor = original
        target = self.fx.docs / "docs" / "ui-bugs.md"
        target.write_text(target.read_text() + "- user work\n")
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "landed-but-divergent")
        # The publication is still reported as having reached the branch, the
        # record survives, and the user's work is untouched.
        self.assertTrue(caught.exception.detail["remote_contains_commit"])
        self.assertIn("- user work", target.read_text())
        pending = publisher.pending_ref("coghex/kanban", "docs/ui-bugs.md")
        self.assertNotEqual(
            run(["git", "rev-parse", "--verify", "--quiet", pending], self.fx.docs), ""
        )

    def test_a_landed_record_is_not_cleared_over_a_staged_document(self):
        original = publisher.is_ancestor
        publisher.is_ancestor = lambda root, commit, revision: False
        try:
            with self.assertRaises(publisher.PublishError):
                self.fx.publish("# UI\n\n- one\n- two\n")
        finally:
            publisher.is_ancestor = original
        blob = run(["git", "hash-object", "-w", "--stdin"], self.fx.docs, input="staged\n")
        run(
            ["git", "update-index", "--cacheinfo", f"100644,{blob},docs/ui-bugs.md"],
            self.fx.docs,
        )
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "landed-but-divergent")

    def test_an_edit_injected_after_the_read_is_detected_and_preserved(self):
        # The window the previous test did not reach: injected *after* the
        # bytes are read, so the baseline comparison passes on cached content
        # and only the last look before the replace can catch it.
        original = publisher.read_for_write
        target = self.fx.docs / "docs" / "ui-bugs.md"
        state = {"reads": 0}

        def racing_read(path):
            state["reads"] += 1
            result = original(path)
            if state["reads"] == 1:  # after the read, before the replace
                target.write_text(target.read_text() + "- foreign\n")
            return result

        publisher.read_for_write = racing_read
        self.addCleanup(setattr, publisher, "read_for_write", original)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "document-changed-before-write")
        self.assertIn("- foreign", target.read_text())
        self.assertIn(
            "- foreign",
            run(["git", "cat-file", "-p", caught.exception.detail["preserved_blob"]],
                self.fx.docs),
        )
        self.assertEqual(self.fx.remote_content(), "# UI\n\n- one")

    def test_an_unresolved_pending_record_blocks_a_fresh_publication(self):
        # A rejected push followed by reverting the document: the record is the
        # only pointer to that run's approved mutation, and publishing over it
        # would drop it silently.
        original = publisher.git

        def failing_push(args, *, cwd, check=True, input_bytes=None):
            if args[:2] == ["push", "origin"]:
                return subprocess.CompletedProcess(args, 1, b"", b"simulated failure")
            return original(args, cwd=cwd, check=check, input_bytes=input_bytes)

        publisher.git = failing_push
        try:
            with self.assertRaises(publisher.PublishError):
                self.fx.publish("# UI\n\n- one\n- two\n")
        finally:
            publisher.git = original
        pending = publisher.pending_ref("coghex/kanban", "docs/ui-bugs.md")
        recorded = run(["git", "rev-parse", pending], self.fx.docs)
        (self.fx.docs / "docs" / "ui-bugs.md").write_text("# UI\n\n- one\n")  # reverted
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- different\n")
        self.assertEqual(caught.exception.status, "pending-unresolved")
        self.assertEqual(run(["git", "rev-parse", pending], self.fx.docs), recorded)
        self.assertEqual(self.fx.remote_content(), "# UI\n\n- one")

    def test_an_unwritable_document_is_a_structured_result(self):
        original = publisher.read_for_write

        def failing_read(path):
            raise OSError(13, "Permission denied")

        publisher.read_for_write = failing_read
        self.addCleanup(setattr, publisher, "read_for_write", original)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "document-unwritable")
        for key in ("document_edit", "local_publication_commit", "remote_contains_commit"):
            self.assertIn(key, caught.exception.detail)

    def test_unreadable_approved_content_is_a_structured_result(self):
        missing = Path(self._tmp.name) / "gone.md"
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = publisher.main([
                "--repo", "coghex/kanban", "--branch", "master",
                "--root", str(self.fx.docs), "--path", "docs/ui-bugs.md",
                "--content", str(missing), "--expected-tip", "irrelevant",
            ])
        self.assertEqual(code, 1)
        payload = json.loads(buffer.getvalue())
        self.assertEqual(payload["status"], "content-unreadable")
        # Guaranteed at the CLI boundary too, not only inside publish().
        for key in ("document_edit", "local_publication_commit", "remote_contains_commit"):
            self.assertIn(key, payload)

    def test_an_in_place_edit_at_the_swap_is_put_back(self):
        # Injected after every check, in the instant before the swap. It cannot
        # be prevented, so the rename captures it intact and puts it back.
        original = publisher.rename_aside
        target = self.fx.docs / "docs" / "ui-bugs.md"

        def racing_rename(src, dst):
            with open(src, "r+") as handle:
                handle.seek(0)
                handle.write("# UI\n\n- foreign wins\n")
                handle.truncate()
            return original(src, dst)

        publisher.rename_aside = racing_rename
        self.addCleanup(setattr, publisher, "rename_aside", original)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "document-changed-before-write")
        self.assertIn("- foreign wins", target.read_text())
        self.assertIn(
            "- foreign wins",
            run(["git", "cat-file", "-p", caught.exception.detail["preserved_blob"]],
                self.fx.docs),
        )
        self.assertEqual(self.fx.remote_content(), "# UI\n\n- one")

    def test_an_atomic_replacement_at_the_swap_is_not_clobbered(self):
        # The other kind of writer: one that renames a new file over the
        # document rather than editing it in place. A pre-swap inode check
        # cannot see this land in the gap after it; capturing the path can.
        original = publisher.rename_aside
        target = self.fx.docs / "docs" / "ui-bugs.md"

        def replacing_rename(src, dst):
            other = src.with_name("foreign-replacement")
            other.write_text("# UI\n\n- replaced wholesale\n")
            os.replace(other, src)  # an atomic replacement of the document
            return original(src, dst)

        publisher.rename_aside = replacing_rename
        self.addCleanup(setattr, publisher, "rename_aside", original)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "document-changed-before-write")
        self.assertIn("- replaced wholesale", target.read_text())
        self.assertEqual(self.fx.remote_content(), "# UI\n\n- one")

    def test_a_file_created_during_the_recovery_is_left_alone(self):
        # The recovery window: the captured edit is being put back when yet
        # another writer creates the document. Putting back must not be the
        # step that destroys a write, so the newer file wins and the captured
        # edit stays recoverable from the object database.
        original_rename = publisher.rename_aside
        original_link = publisher.link_into_place
        target = self.fx.docs / "docs" / "ui-bugs.md"

        def racing_rename(src, dst):
            with open(src, "r+") as handle:
                handle.seek(0)
                handle.write("# UI\n\n- captured edit\n")
                handle.truncate()
            return original_rename(src, dst)

        def racing_link(scratch, dest):
            # Fires on the put-back: something has just recreated the document.
            if not dest.exists():
                dest.write_text("# UI\n\n- created during recovery\n")
            return original_link(scratch, dest)

        publisher.rename_aside = racing_rename
        publisher.link_into_place = racing_link
        self.addCleanup(setattr, publisher, "rename_aside", original_rename)
        self.addCleanup(setattr, publisher, "link_into_place", original_link)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        detail = caught.exception.detail
        self.assertEqual(caught.exception.status, "document-changed-before-write")
        self.assertFalse(detail["restored"])
        # The newer write survives untouched...
        self.assertIn("- created during recovery", target.read_text())
        # ...and the captured edit is not lost.
        self.assertIn(
            "- captured edit",
            run(["git", "cat-file", "-p", detail["preserved_blob"]], self.fx.docs),
        )
        self.assertEqual(self.fx.remote_content(), "# UI\n\n- one")

    def test_a_file_recreated_during_the_swap_is_left_alone(self):
        # The remaining gap: the document is briefly absent between the capture
        # and the link. A writer creating a file there wins, because `link`
        # refuses rather than overwrites.
        original = publisher.link_into_place
        target = self.fx.docs / "docs" / "ui-bugs.md"

        def racing_link(scratch, dest):
            dest.write_text("# UI\n\n- created in the gap\n")
            return original(scratch, dest)

        publisher.link_into_place = racing_link
        self.addCleanup(setattr, publisher, "link_into_place", original)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "document-changed-before-write")
        self.assertIn("- created in the gap", target.read_text())
        self.assertEqual(self.fx.remote_content(), "# UI\n\n- one")

    def test_an_unrelated_file_matching_the_scratch_name_survives(self):
        # A deterministic scratch name would truncate and delete this.
        stray = self.fx.docs / "docs" / ".ui-bugs.md.kanban-publish"
        stray.write_text("somebody else's untracked file\n")
        self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertTrue(stray.exists())
        self.assertEqual(stray.read_text(), "somebody else's untracked file\n")

    def test_the_published_document_keeps_its_permissions(self):
        # The swap replaces the file, so the mode travels with it: `mkstemp`
        # creates 0600, and publishing must not silently narrow a document
        # other people and processes read.
        target = self.fx.docs / "docs" / "ui-bugs.md"
        target.chmod(0o644)
        before = target.stat().st_mode & 0o7777
        self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(target.stat().st_mode & 0o7777, before)

    def test_the_write_leaves_no_temporary_behind(self):
        before = sorted(p.name for p in (self.fx.docs / "docs").iterdir())
        self.fx.publish("# UI\n\n- one\n- two\n")
        after = sorted(p.name for p in (self.fx.docs / "docs").iterdir())
        self.assertEqual(before, after)

    def test_a_failed_verification_still_names_the_candidate_commit(self):
        # The push may have landed; a report that cannot name the commit is
        # unrecoverable precisely when recovery matters.
        original = publisher.git

        def failing_fetch(args, *, cwd, check=True, input_bytes=None):
            if args[:2] == ["fetch", "origin"] and getattr(failing_fetch, "armed", False):
                raise publisher.PublishError("git-failed", "simulated fetch failure")
            return original(args, cwd=cwd, check=check, input_bytes=input_bytes)

        def arming_push(args, *, cwd, check=True, input_bytes=None):
            if args[:2] == ["push", "origin"]:
                failing_fetch.armed = True
            return failing_fetch(args, cwd=cwd, check=check, input_bytes=input_bytes)

        publisher.git = arming_push
        self.addCleanup(setattr, publisher, "git", original)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        detail = caught.exception.detail
        self.assertIsNotNone(detail["local_publication_commit"])
        self.assertIn("pending_ref", detail)

    def test_divergence_after_a_fresh_publication_keeps_the_record(self):
        # Reachability is settled, so the publication is a fact — but an
        # outside process can change the document before the record is
        # cleared, and dropping it then would leave that divergence with
        # nothing pointing at it.
        original = publisher.working_blob
        target = self.fx.docs / "docs" / "ui-bugs.md"
        state = {"calls": 0}

        def racing_blob(root, document):
            state["calls"] += 1
            if state["calls"] == 2:  # after the push, before the record clears
                target.write_text(target.read_text() + "- landed after\n")
            return original(root, document)

        publisher.working_blob = racing_blob
        self.addCleanup(setattr, publisher, "working_blob", original)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        detail = caught.exception.detail
        self.assertEqual(caught.exception.status, "landed-but-divergent")
        # The publication is still reported as having reached the branch...
        self.assertTrue(detail["remote_contains_commit"])
        self.assertIn("- two", self.fx.remote_content())
        # ...the outside edit survives, and the record still points at it.
        self.assertIn("- landed after", target.read_text())
        pending = publisher.pending_ref("coghex/kanban", "docs/ui-bugs.md")
        self.assertNotEqual(
            run(["git", "rev-parse", "--verify", "--quiet", pending], self.fx.docs), ""
        )

    def test_staging_after_a_fresh_publication_keeps_the_record(self):
        original = publisher.staged_blob
        state = {"calls": 0}

        def racing_staged(root, document):
            # The two require_unstaged checks come first; the third call is the
            # one made just before the record is cleared.
            state["calls"] += 1
            if state["calls"] >= 3:
                return "0" * 40
            return original(root, document)

        publisher.staged_blob = racing_staged
        self.addCleanup(setattr, publisher, "staged_blob", original)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "landed-but-divergent")
        pending = publisher.pending_ref("coghex/kanban", "docs/ui-bugs.md")
        self.assertNotEqual(
            run(["git", "rev-parse", "--verify", "--quiet", pending], self.fx.docs), ""
        )

    def test_the_preflight_reports_a_clear_document(self):
        outcome = publisher.check_pending(
            self.fx.docs, "coghex/kanban", "master", "docs/ui-bugs.md"
        )
        self.assertEqual(outcome["status"], "clear")

    def test_the_preflight_reports_an_outstanding_publication(self):
        # Asked before the caller mutates its tracker, which is the whole
        # point: learning this afterwards means a second issue already exists
        # for a disposition the document will never receive.
        original = publisher.git

        def failing_push(args, *, cwd, check=True, input_bytes=None):
            if args[:2] == ["push", "origin"]:
                return subprocess.CompletedProcess(args, 1, b"", b"simulated failure")
            return original(args, cwd=cwd, check=check, input_bytes=input_bytes)

        publisher.git = failing_push
        try:
            with self.assertRaises(publisher.PublishError):
                self.fx.publish("# UI\n\n- one\n- two\n")
        finally:
            publisher.git = original
        outcome = publisher.check_pending(
            self.fx.docs, "coghex/kanban", "master", "docs/ui-bugs.md"
        )
        self.assertEqual(outcome["status"], "pending")
        self.assertFalse(outcome["already_landed"])
        self.assertIn("retry", outcome["resolution"])

    def test_the_preflight_distinguishes_an_already_landed_record(self):
        original = publisher.is_ancestor
        publisher.is_ancestor = lambda root, commit, revision: False
        try:
            with self.assertRaises(publisher.PublishError):
                self.fx.publish("# UI\n\n- one\n- two\n")
        finally:
            publisher.is_ancestor = original
        outcome = publisher.check_pending(
            self.fx.docs, "coghex/kanban", "master", "docs/ui-bugs.md"
        )
        self.assertEqual(outcome["status"], "pending")
        self.assertTrue(outcome["already_landed"])

    def test_clearing_a_lock_that_changed_underneath_is_refused(self):
        # Two clearers can agree the same owner is dead. The slower one must
        # not delete whatever lock exists by then, which may be a live
        # publisher's.
        lock = publisher.lock_ref("coghex/kanban", "docs/ui-bugs.md")
        tip = run(["git", "rev-parse", "origin/master"], self.fx.docs)
        dead = subprocess.Popen(["true"])
        dead.wait()
        token = json.dumps(
            {"host": publisher.socket.gethostname(), "pid": dead.pid},
            sort_keys=True, separators=(",", ":"),
        )
        stale = run(["git", "commit-tree", f"{tip}^{{tree}}", "-m", token], self.fx.docs)
        run(["git", "update-ref", lock, stale], self.fx.docs)

        original = publisher.process_is_live

        def racing_liveness(pid):
            # Between the liveness check and the delete, the stale lock is
            # cleared by someone else and a live publisher takes a new one.
            run(["git", "update-ref", "-d", lock], self.fx.docs)
            held = publisher.acquire_lock(self.fx.docs, lock, tip)
            return original(pid)

        publisher.process_is_live = racing_liveness
        self.addCleanup(setattr, publisher, "process_is_live", original)
        with self.assertRaises(publisher.PublishError) as caught:
            publisher.clear_stale_lock(self.fx.docs, lock)
        self.assertEqual(caught.exception.status, "lock-changed")
        # The live publisher's lock survives.
        self.assertIsNotNone(publisher.read_lock_owner(self.fx.docs, lock))
        publisher.release_lock(
            self.fx.docs, lock, run(["git", "rev-parse", lock], self.fx.docs)
        )

    def test_an_io_failure_during_the_swap_does_not_delete_the_document(self):
        # Between the rename and the link the document does not exist and the
        # captured copy is the only one. An unanticipated failure there must
        # not leave the cursor deleted.
        original = publisher.link_into_place
        target = self.fx.docs / "docs" / "ui-bugs.md"
        before = target.read_text()

        def failing_link(scratch, dest):
            raise PermissionError(13, "Permission denied")

        publisher.link_into_place = failing_link
        self.addCleanup(setattr, publisher, "link_into_place", original)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "document-unwritable")
        self.assertTrue(target.is_file())
        self.assertEqual(target.read_text(), before)
        self.assertEqual(self.fx.remote_content(), "# UI\n\n- one")

    def test_a_failure_during_the_swap_leaves_no_temporaries(self):
        original = publisher.link_into_place
        publisher.link_into_place = lambda scratch, dest: (_ for _ in ()).throw(
            PermissionError(13, "Permission denied")
        )
        self.addCleanup(setattr, publisher, "link_into_place", original)
        before = sorted(p.name for p in (self.fx.docs / "docs").iterdir())
        with self.assertRaises(publisher.PublishError):
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(sorted(p.name for p in (self.fx.docs / "docs").iterdir()), before)

    def test_no_failure_in_the_swap_can_lose_the_document(self):
        # The invariant, driven at every step where the document has no home:
        # whatever fails and however, the document survives intact, the remote
        # is untouched, and the outcome is structured. Enumerated as a table
        # because the failure that matters is the one nobody anticipated, and a
        # table is cheap to extend when the next one is found.
        for attr, error in (
            ("rename_aside", OSError(5, "I/O error")),
            ("link_into_place", PermissionError(13, "Permission denied")),
            ("link_into_place", OSError(28, "No space left on device")),
            ("read_for_write", OSError(5, "I/O error")),
        ):
            with self.subTest(step=attr, error=error.errno):
                self._tmp.cleanup()
                self._tmp = tempfile.TemporaryDirectory()
                self.fx = Fixture(Path(self._tmp.name))
                target = self.fx.docs / "docs" / "ui-bugs.md"
                before = target.read_text()
                original = getattr(publisher, attr)

                def failing(*args, **kwargs):
                    raise error

                setattr(publisher, attr, failing)
                try:
                    with self.assertRaises(publisher.PublishError) as caught:
                        self.fx.publish("# UI\n\n- one\n- two\n")
                finally:
                    setattr(publisher, attr, original)
                self.assertEqual(caught.exception.status, "document-unwritable")
                self.assertTrue(target.is_file())
                self.assertEqual(target.read_text(), before)
                self.assertEqual(self.fx.remote_content(), "# UI\n\n- one")
                self.assertEqual(
                    [p.name for p in (self.fx.docs / "docs").iterdir()
                     if "kanban-publish" in p.name],
                    [],
                )

    def test_content_rendered_against_an_older_tip_is_refused(self):
        # Two runs both pass the preflight, both create a tracker item, and
        # both render from the same document. The first publishes; the second's
        # content is now a whole-file image of a document that no longer
        # exists, and publishing it would drop the first's disposition while
        # changing exactly the one path a correct publication changes.
        first_tip = publisher.check_pending(
            self.fx.docs, "coghex/kanban", "master", "docs/ui-bugs.md"
        )["publication_tip"]
        second_tip = first_tip  # the second run looked at the same moment

        self.fx.publish("# UI\n\n- one\n- first run\n")
        self.assertIn("- first run", self.fx.remote_content())

        blob = self.fx.dir / "second.md"
        blob.write_text("# UI\n\n- one\n- second run\n", encoding="utf-8")
        with self.assertRaises(publisher.PublishError) as caught:
            publisher.publish(
                repository="coghex/kanban", branch="master", root=self.fx.docs,
                document="docs/ui-bugs.md", content=blob.read_bytes(),
                message="docs: second", expected_tip=second_tip,
            )
        self.assertEqual(caught.exception.status, "tip-moved")
        # The first run's disposition is still on the branch.
        self.assertIn("- first run", self.fx.remote_content())
        self.assertNotIn("- second run", self.fx.remote_content())

    def test_a_current_tip_still_publishes(self):
        tip = publisher.check_pending(
            self.fx.docs, "coghex/kanban", "master", "docs/ui-bugs.md"
        )["publication_tip"]
        blob = self.fx.dir / "approved.md"
        blob.write_text("# UI\n\n- one\n- two\n", encoding="utf-8")
        result = publisher.publish(
            repository="coghex/kanban", branch="master", root=self.fx.docs,
            document="docs/ui-bugs.md", content=blob.read_bytes(),
            message="docs: ok", expected_tip=tip,
        )
        self.assertEqual(result["status"], "published")

    def test_restoration_refuses_an_occupied_target_when_link_is_unavailable(self):
        # The fallback must still refuse rather than overwrite: a rename here
        # would check and then clobber, which is the race this module declines
        # to run anywhere else.
        original = publisher.link_into_place
        publisher.link_into_place = lambda s, d: (_ for _ in ()).throw(
            PermissionError(13, "Permission denied")
        )
        self.addCleanup(setattr, publisher, "link_into_place", original)
        aside = self.fx.docs / "captured.md"
        aside.write_text("captured\n")
        occupied = self.fx.docs / "occupied.md"
        occupied.write_text("somebody else's newer file\n")
        self.assertFalse(
            publisher.put_back(aside, occupied, b"captured\n", 0o644)
        )
        self.assertEqual(occupied.read_text(), "somebody else's newer file\n")

    def test_restoration_recreates_when_the_target_is_free(self):
        original = publisher.link_into_place
        publisher.link_into_place = lambda s, d: (_ for _ in ()).throw(
            PermissionError(13, "Permission denied")
        )
        self.addCleanup(setattr, publisher, "link_into_place", original)
        aside = self.fx.docs / "captured.md"
        aside.write_text("captured\n")
        free = self.fx.docs / "free.md"
        self.assertTrue(publisher.put_back(aside, free, b"captured\n", 0o644))
        self.assertEqual(free.read_text(), "captured\n")
        self.assertEqual(free.stat().st_mode & 0o777, 0o644)

    def test_the_assets_preflight_shell_really_extracts_the_tip(self):
        # Not "the flag appears in the text" — that is what let a binding that
        # expanded to nothing survive a review round. This runs the assets' own
        # preflight lines against a real repository and asserts the variable
        # they define holds the tip the helper reported.
        helper = REPO_ROOT / "tools" / "publish_coordination_doc.py"
        script = "\n".join([
            'set -e',
            # The helper is resolved from the owning repository's checkout. The
            # fixture's synthetic repository has no tools/ tree, so this points
            # at the real one for resolution while the write root — what the
            # helper actually reads and verifies — stays the fixture's.
            f'DOC_ROOT={shlex.quote(str(REPO_ROOT))}',
            f'DOCS_WT={shlex.quote(str(self.fx.docs))}',
            'DOC_REPO=coghex/kanban',
            'DOC_BRANCH=master',
            'DOC_RELATIVE_PATH=docs/ui-bugs.md',
            'PREFLIGHT="$(python3 "$DOC_ROOT/tools/publish_coordination_doc.py" \\',
            '  --repo "$DOC_REPO" --branch "$DOC_BRANCH" --root "$DOCS_WT" \\',
            '  --path "$DOC_RELATIVE_PATH" --check-pending)"',
            'PREFLIGHT_TIP="$(PREFLIGHT="$PREFLIGHT" python3 -c \\',
            '  \'import json, os; print(json.loads(os.environ["PREFLIGHT"])["publication_tip"])\')"',
            '[ -n "$PREFLIGHT_TIP" ]',
            'printf %s "$PREFLIGHT_TIP"',
        ])
        for shell in ("/bin/bash", "/bin/zsh"):
            with self.subTest(shell=shell):
                proc = subprocess.run(
                    [shell, "-c", script], capture_output=True, text=True
                )
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(
                    proc.stdout.strip(),
                    run(["git", "rev-parse", "origin/master"], self.fx.docs),
                )
        self.assertTrue(helper.is_file())

    def test_publishing_without_a_tip_binding_is_refused(self):
        # The failure the empty expansion produced: an absent binding must be
        # an error, never a publication with the check switched off.
        blob = self.fx.dir / "approved.md"
        blob.write_text("# UI\n\n- one\n- two\n", encoding="utf-8")
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = publisher.main([
                "--repo", "coghex/kanban", "--branch", "master",
                "--root", str(self.fx.docs), "--path", "docs/ui-bugs.md",
                "--content", str(blob),
            ])
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(buffer.getvalue())["status"], "expected-tip-required")
        self.assertEqual(self.fx.remote_content(), "# UI\n\n- one")

    def test_an_empty_tip_binding_is_refused(self):
        blob = self.fx.dir / "approved.md"
        blob.write_text("# UI\n\n- one\n- two\n", encoding="utf-8")
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = publisher.main([
                "--repo", "coghex/kanban", "--branch", "master",
                "--root", str(self.fx.docs), "--path", "docs/ui-bugs.md",
                "--content", str(blob), "--expected-tip", "",
            ])
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(buffer.getvalue())["status"], "expected-tip-required")
        self.assertEqual(self.fx.remote_content(), "# UI\n\n- one")

    def test_a_file_at_the_old_index_path_survives(self):
        # The scratch index used to be named deterministically in the shared
        # common Git directory, where `read-tree` would rewrite whatever was
        # there and the cleanup would delete it.
        common = Path(run(["git", "rev-parse", "--path-format=absolute",
                           "--git-common-dir"], self.fx.docs))
        stray = common / "kanban-publish-index-docs-ui-bugs.md-deadbeef"
        stray.write_text("somebody else's file\n")
        self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertTrue(stray.exists())
        self.assertEqual(stray.read_text(), "somebody else's file\n")

    def test_the_publication_leaves_no_scratch_index_behind(self):
        common = Path(run(["git", "rev-parse", "--path-format=absolute",
                           "--git-common-dir"], self.fx.docs))
        before = sorted(p.name for p in common.iterdir())
        self.fx.publish("# UI\n\n- one\n- two\n")
        leftovers = [
            name for name in sorted(p.name for p in common.iterdir())
            if name not in before and "kanban-publish-index" in name
        ]
        self.assertEqual(leftovers, [])

    def test_a_record_that_cannot_be_cleared_is_reported(self):
        # A retained record stops the next preflight and therefore every later
        # disposition for this document, so a publication that could not clear
        # it must say so rather than report plain success.
        original = publisher.git

        def failing_delete(args, *, cwd, check=True, input_bytes=None):
            if (
                len(args) >= 3
                and args[0] == "update-ref"
                and args[1] == "-d"
                and "pending-publication" in args[2]
            ):
                return subprocess.CompletedProcess(args, 1, b"", b"simulated failure")
            return original(args, cwd=cwd, check=check, input_bytes=input_bytes)

        publisher.git = failing_delete
        self.addCleanup(setattr, publisher, "git", original)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "record-retained")
        # The publication itself did land, and is reported as having done so.
        self.assertTrue(caught.exception.detail["remote_contains_commit"])
        self.assertIn("- two", self.fx.remote_content())

    def test_a_lock_that_cannot_be_released_is_reported(self):
        # A lock still standing blocks every later run for this document, so a
        # publication that could not release its own must say so.
        original = publisher.git

        def failing_release(args, *, cwd, check=True, input_bytes=None):
            if (
                len(args) >= 3
                and args[0] == "update-ref"
                and args[1] == "-d"
                and "publish-lock" in args[2]
            ):
                return subprocess.CompletedProcess(args, 1, b"", b"simulated failure")
            return original(args, cwd=cwd, check=check, input_bytes=input_bytes)

        publisher.git = failing_release
        self.addCleanup(setattr, publisher, "git", original)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "lock-retained")
        # The publication itself landed and is reported as having done so.
        self.assertIn("- two", self.fx.remote_content())

    def test_a_preflight_that_cannot_refresh_fails_rather_than_binding(self):
        # The tip a preflight reports becomes the caller's binding. One minted
        # from a stale cached ref reads as current and licenses a publication
        # against a document that has already moved.
        original = publisher.git

        def failing_fetch(args, *, cwd, check=True, input_bytes=None):
            if args[:2] == ["fetch", "origin"]:
                raise publisher.PublishError("git-failed", "simulated fetch failure")
            return original(args, cwd=cwd, check=check, input_bytes=input_bytes)

        publisher.git = failing_fetch
        self.addCleanup(setattr, publisher, "git", original)
        with self.assertRaises(publisher.PublishError) as caught:
            publisher.check_pending(
                self.fx.docs, "coghex/kanban", "master", "docs/ui-bugs.md"
            )
        self.assertEqual(caught.exception.status, "git-failed")

    def test_a_landed_record_refuses_a_different_disposition(self):
        # Only the recorded mutation landed. Reporting this call as published
        # would tell a caller that has already created its tracker item that
        # its disposition reached the branch, when none of it did.
        original = publisher.is_ancestor
        publisher.is_ancestor = lambda root, commit, revision: False
        try:
            with self.assertRaises(publisher.PublishError):
                self.fx.publish("# UI\n\n- one\n- first\n")
        finally:
            publisher.is_ancestor = original
        self.assertIn("- first", self.fx.remote_content())
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- SECOND\n")
        self.assertEqual(caught.exception.status, "pending-differs-from-approved")
        self.assertTrue(caught.exception.detail["remote_contains_commit"])
        self.assertNotIn("- SECOND", self.fx.remote_content())
        # Supplying the recorded content still reconciles and clears it.
        result = self.fx.publish("# UI\n\n- one\n- first\n")
        self.assertEqual(result["resumed"], "already-landed")

    def test_a_failed_publication_reports_a_retained_lock_too(self):
        # Both failures at once: the publication is refused *and* the lock
        # cannot be released. The original failure keeps priority — it is what
        # the caller asked about — but the retained lock travels with it,
        # because every later run for this document is now blocked.
        original = publisher.git

        def failing(args, *, cwd, check=True, input_bytes=None):
            if (
                len(args) >= 3
                and args[0] == "update-ref"
                and args[1] == "-d"
                and "publish-lock" in args[2]
            ):
                return subprocess.CompletedProcess(args, 1, b"", b"simulated failure")
            if args[:2] == ["push", "origin"]:
                return subprocess.CompletedProcess(args, 1, b"", b"simulated failure")
            return original(args, cwd=cwd, check=check, input_bytes=input_bytes)

        publisher.git = failing
        self.addCleanup(setattr, publisher, "git", original)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        # The publication failure is what is reported...
        self.assertEqual(caught.exception.status, "unpublished")
        # ...and the retained lock is named alongside it.
        self.assertTrue(caught.exception.detail["lock_retained"])
        self.assertIn("publish-lock", caught.exception.detail["lock_ref"])
        self.assertEqual(self.fx.remote_content(), "# UI\n\n- one")

    def test_releasing_a_lock_without_its_value_is_refused(self):
        # The unbound delete the signature now makes unrepresentable: it would
        # remove whatever lock is there, not this run's.
        lock = publisher.lock_ref("coghex/kanban", "docs/ui-bugs.md")
        tip = run(["git", "rev-parse", "origin/master"], self.fx.docs)
        held = publisher.acquire_lock(self.fx.docs, lock, tip)
        with self.assertRaises(publisher.PublishError) as caught:
            publisher.release_lock(self.fx.docs, lock, "")
        self.assertEqual(caught.exception.status, "lock-release-unbound")
        self.assertIsNotNone(publisher.read_lock_owner(self.fx.docs, lock))
        publisher.release_lock(self.fx.docs, lock, held)

    def test_an_unrestorable_capture_names_where_it_was_kept(self):
        # A file kept somewhere nobody is told about is only marginally better
        # than one deleted.
        original_link = publisher.link_into_place
        original_open = publisher.os.open

        def no_link(scratch, dest):
            raise PermissionError(13, "denied")

        def no_open(path, flags, *rest):
            # Only the restoration's exclusive create of the document itself.
            # Failing every O_EXCL open would break `mkstemp` and the run would
            # never reach the swap.
            if flags & publisher.os.O_EXCL and str(path).endswith("docs/ui-bugs.md"):
                raise PermissionError(13, "denied")
            return original_open(path, flags, *rest)

        publisher.link_into_place = no_link
        publisher.os.open = no_open
        self.addCleanup(setattr, publisher, "link_into_place", original_link)
        self.addCleanup(setattr, publisher.os, "open", original_open)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        detail = caught.exception.detail
        self.assertIn("captured_file", detail)
        self.assertTrue(Path(detail["captured_file"]).is_file())
        self.assertIn(
            "- one",
            run(["git", "cat-file", "-p", detail["captured_blob"]], self.fx.docs),
        )

    def test_a_cleanup_failure_is_structured_and_releases_the_lock(self):
        # Cleanup runs after the document may already have been replaced, with
        # an exception possibly already propagating. A raise from there used to
        # escape the result contract and skip the lock release with it.
        original = publisher._quietly
        target = self.fx.docs / "docs" / "ui-bugs.md"

        def failing_cleanup(action, *args, **kwargs):
            raise OSError(5, "I/O error during cleanup")

        publisher._quietly = failing_cleanup
        self.addCleanup(setattr, publisher, "_quietly", original)
        buffer = io.StringIO()
        blob = self.fx.dir / "approved.md"
        blob.write_text("# UI\n\n- one\n- two\n", encoding="utf-8")
        tip = run(["git", "rev-parse", "origin/master"], self.fx.docs)
        with contextlib.redirect_stdout(buffer):
            code = publisher.main([
                "--repo", "coghex/kanban", "--branch", "master",
                "--root", str(self.fx.docs), "--path", "docs/ui-bugs.md",
                "--content", str(blob), "--expected-tip", tip,
            ])
        self.assertEqual(code, 1)
        payload = json.loads(buffer.getvalue())
        # Structured rather than a traceback, with all three states...
        for key in ("document_edit", "local_publication_commit", "remote_contains_commit"):
            self.assertIn(key, payload)
        # ...and the lock is not left standing.
        self.assertIsNone(
            publisher.read_lock_owner(
                self.fx.docs, publisher.lock_ref("coghex/kanban", "docs/ui-bugs.md")
            )
        )
        self.assertTrue(target.is_file())

    def test_an_unmodelled_error_is_still_a_structured_result(self):
        original = publisher.build_commit

        def surprising(*args, **kwargs):
            raise ValueError("something this module never modelled")

        publisher.build_commit = surprising
        self.addCleanup(setattr, publisher, "build_commit", original)
        blob = self.fx.dir / "approved.md"
        blob.write_text("# UI\n\n- one\n- two\n", encoding="utf-8")
        tip = run(["git", "rev-parse", "origin/master"], self.fx.docs)
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = publisher.main([
                "--repo", "coghex/kanban", "--branch", "master",
                "--root", str(self.fx.docs), "--path", "docs/ui-bugs.md",
                "--content", str(blob), "--expected-tip", tip,
            ])
        self.assertEqual(code, 1)
        payload = json.loads(buffer.getvalue())
        self.assertEqual(payload["status"], "internal-error")
        self.assertIn("ValueError", payload["message"])
        # The lock came off even for a failure the module never modelled.
        self.assertIsNone(
            publisher.read_lock_owner(
                self.fx.docs, publisher.lock_ref("coghex/kanban", "docs/ui-bugs.md")
            )
        )

    def test_ambiguous_document_paths_get_independent_refs(self):
        # `docs/a-b.md` and `docs/a/b.md` collided when the key was `/`
        # replaced by `-`: they shared a lock and a pending record, so one
        # failing to publish blocked the other and a record left by one could
        # be resolved against the other.
        pairs = [
            ("docs/a-b.md", "docs/a/b.md"),
            ("docs/x/y-z.md", "docs/x-y/z.md"),
            ("docs/ui-bugs.md", "docs/ui/bugs.md"),
        ]
        for first, second in pairs:
            with self.subTest(first=first, second=second):
                self.assertNotEqual(
                    publisher.lock_ref("coghex/kanban", first),
                    publisher.lock_ref("coghex/kanban", second),
                )
                self.assertNotEqual(
                    publisher.pending_ref("coghex/kanban", first),
                    publisher.pending_ref("coghex/kanban", second),
                )
        # And the repository is part of the pair, not just the path.
        self.assertNotEqual(
            publisher.lock_ref("coghex/kanban", "docs/ui-bugs.md"),
            publisher.lock_ref("coghex/other", "docs/ui-bugs.md"),
        )

    def test_a_lock_on_one_document_does_not_block_another(self):
        tip = run(["git", "rev-parse", "origin/master"], self.fx.docs)
        lock = publisher.lock_ref("coghex/kanban", "docs/a-b.md")
        held = publisher.acquire_lock(
            self.fx.docs, lock, tip, "coghex/kanban", "docs/a-b.md"
        )
        self.addCleanup(publisher.release_lock, self.fx.docs, lock, held)
        # A different document publishes normally while that lock is held.
        result = self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(result["status"], "published")

    def test_a_held_lock_names_the_document_it_holds(self):
        # The ref is a digest now, so the payload is where a stale-lock sweep
        # learns what it is looking at.
        tip = run(["git", "rev-parse", "origin/master"], self.fx.docs)
        lock = publisher.lock_ref("coghex/kanban", "docs/ui-bugs.md")
        held = publisher.acquire_lock(
            self.fx.docs, lock, tip, "coghex/kanban", "docs/ui-bugs.md"
        )
        self.addCleanup(publisher.release_lock, self.fx.docs, lock, held)
        owner = publisher.read_lock_owner(self.fx.docs, lock)
        self.assertEqual(owner["document"], "docs/ui-bugs.md")
        self.assertEqual(owner["repository"], "coghex/kanban")

    def test_a_deletion_before_the_rename_is_not_turned_into_a_blank_file(self):
        # Nothing was captured, so there is nothing to give back. Recreating
        # the document from the placeholder would turn somebody's deletion into
        # an unapproved empty file that looks like a document.
        original = publisher.rename_aside
        target = self.fx.docs / "docs" / "ui-bugs.md"

        def deleting_rename(src, dst):
            src.unlink()          # removed by another process
            return original(src, dst)  # ...so this fails

        publisher.rename_aside = deleting_rename
        self.addCleanup(setattr, publisher, "rename_aside", original)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "document-unwritable")
        # Absent, not resurrected empty.
        self.assertFalse(target.exists())
        self.assertEqual(self.fx.remote_content(), "# UI\n\n- one")

    def test_a_staged_ineligible_document_is_refused(self):
        # The unstaged end state is promised on every outcome, not only the
        # ones that could publish.
        blob = run(
            ["git", "hash-object", "-w", "--stdin"], self.fx.docs,
            input="# Design\n\nstaged\n",
        )
        run(
            ["git", "update-index", "--cacheinfo", f"100644,{blob},docs/design.md"],
            self.fx.docs,
        )
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# Design\n\nchanged\n", path="docs/design.md")
        self.assertEqual(caught.exception.status, "document-staged")

    def test_a_scratch_index_cleanup_failure_does_not_strand_the_document(self):
        # This cleanup runs after the document has been replaced but before the
        # candidate commit and its record exist, so a raise there would leave an
        # approved local document with nothing to resume from.
        original = publisher.os.unlink

        def failing_unlink(path, *args, **kwargs):
            if "kanban-publish-index" in str(path):
                raise OSError(5, "I/O error")
            return original(path, *args, **kwargs)

        publisher.os.unlink = failing_unlink
        self.addCleanup(setattr, publisher.os, "unlink", original)
        result = self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(result["status"], "published")
        self.assertIn("- two", self.fx.remote_content())

    def test_a_preserve_failure_after_capture_still_reports_the_capture(self):
        # Both fail at once: the content cannot be written to the object
        # database *and* the document cannot be restored. The original failure
        # must survive rather than be masked by the reporting itself.
        original_preserve = publisher._preserve
        original_link = publisher.link_into_place
        original_open = publisher.os.open
        # Targeted by content, not by call order: the approved content is
        # preserved before the swap, so counting calls fails the wrong one.
        captured_bytes = (self.fx.docs / "docs" / "ui-bugs.md").read_bytes()

        def failing_preserve(root, data):
            if data == captured_bytes:  # the capture's own preserve
                raise publisher.PublishError("git-failed", "object database down")
            return original_preserve(root, data)

        def no_link(scratch, dest):
            raise PermissionError(13, "denied")

        def no_open(path, flags, *rest):
            if flags & publisher.os.O_EXCL and str(path).endswith("docs/ui-bugs.md"):
                raise PermissionError(13, "denied")
            return original_open(path, flags, *rest)

        publisher._preserve = failing_preserve
        publisher.link_into_place = no_link
        publisher.os.open = no_open
        self.addCleanup(setattr, publisher, "_preserve", original_preserve)
        self.addCleanup(setattr, publisher, "link_into_place", original_link)
        self.addCleanup(setattr, publisher.os, "open", original_open)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        # The real failure, not an UnboundLocalError from the reporting.
        self.assertEqual(caught.exception.status, "git-failed")
        detail = caught.exception.detail
        self.assertIn("captured_file", detail)
        self.assertTrue(Path(detail["captured_file"]).is_file())
        self.assertEqual(self.fx.remote_content(), "# UI\n\n- one")

    def _make_pending(self, landed=False):
        """Leave a pending record behind, optionally one that reached the
        branch."""
        original = publisher.git

        def failing_push(args, *, cwd, check=True, input_bytes=None):
            if args[:2] == ["push", "origin"]:
                return subprocess.CompletedProcess(args, 1, b"", b"simulated failure")
            return original(args, cwd=cwd, check=check, input_bytes=input_bytes)

        publisher.git = failing_push
        try:
            with self.assertRaises(publisher.PublishError):
                self.fx.publish("# UI\n\n- one\n- approved\n")
        finally:
            publisher.git = original
        if landed:
            pending = publisher.pending_ref("coghex/kanban", "docs/ui-bugs.md")
            commit = run(["git", "rev-parse", pending], self.fx.docs)
            run(["git", "push", "-q", "origin", f"{commit}:refs/heads/master"], self.fx.docs)
            run(["git", "fetch", "-q", "origin", "master"], self.fx.docs)

    def test_every_entry_state_produces_a_defined_outcome(self):
        # Organised by the state the world is in when the module is called,
        # rather than by rule or by exit. What is asserted is that no
        # combination reaches a traceback and none publishes when it should
        # not: the outcome names differ, but every one of them is a decision.
        cases = [
            ("matches-tip", "absent", "published"),
            ("matches-tip", "unlanded", "pending-unresolved"),
            ("matches-tip", "landed", "published"),
            ("foreign", "absent", "document-not-baseline"),
            ("foreign", "unlanded", "document-not-baseline"),
            ("foreign", "landed", "landed-but-divergent"),
            ("absent", "absent", "document-not-baseline"),
            ("absent", "unlanded", "document-not-baseline"),
            ("absent", "landed", "landed-but-divergent"),
            ("staged", "absent", "document-staged"),
            ("staged", "unlanded", "document-staged"),
            ("staged", "landed", "landed-but-divergent"),
        ]
        for doc_state, record_state, expected in cases:
            with self.subTest(document=doc_state, record=record_state):
                self._tmp.cleanup()
                self._tmp = tempfile.TemporaryDirectory()
                self.fx = Fixture(Path(self._tmp.name))
                target = self.fx.docs / "docs" / "ui-bugs.md"
                if record_state != "absent":
                    self._make_pending(landed=(record_state == "landed"))
                if doc_state == "matches-tip":
                    run(["git", "fetch", "-q", "origin", "master"], self.fx.docs)
                    tip = run(["git", "rev-parse", "origin/master"], self.fx.docs)
                    target.write_text(
                        run(["git", "show", f"{tip}:docs/ui-bugs.md"], self.fx.docs) + "\n"
                    )
                elif doc_state == "foreign":
                    target.write_text("# UI\n\n- one\n- somebody else\n")
                elif doc_state == "absent":
                    target.unlink(missing_ok=True)
                elif doc_state == "staged":
                    blob = run(
                        ["git", "hash-object", "-w", "--stdin"], self.fx.docs,
                        input="staged\n",
                    )
                    run(
                        ["git", "update-index", "--cacheinfo",
                         f"100644,{blob},docs/ui-bugs.md"],
                        self.fx.docs,
                    )
                try:
                    outcome = self.fx.publish("# UI\n\n- one\n- approved\n")["status"]
                except publisher.PublishError as error:
                    outcome = error.status
                self.assertEqual(outcome, expected)

    def test_two_real_processes_publishing_at_once(self):
        # Every other concurrency case here simulates an interleaving by
        # patching. This one does not: two operating-system processes race for
        # the same document, which is the thing the lock is actually for.
        helper = REPO_ROOT / "tools" / "publish_coordination_doc.py"
        tip = run(["git", "rev-parse", "origin/master"], self.fx.docs)
        running = []
        for name in ("alpha", "beta"):
            blob = Path(self._tmp.name) / f"{name}.md"
            blob.write_text(f"# UI\n\n- one\n- {name}\n", encoding="utf-8")
            running.append((name, subprocess.Popen(
                [sys.executable, str(helper),
                 "--repo", "coghex/kanban", "--branch", "master",
                 "--root", str(self.fx.docs), "--path", "docs/ui-bugs.md",
                 "--content", str(blob), "--expected-tip", tip],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)))
        statuses = {}
        for name, proc in running:
            out, err = proc.communicate(timeout=120)
            self.assertTrue(out.strip(), f"{name} produced no result: {err}")
            statuses[name] = json.loads(out)["status"]
        # Exactly one publishes; the other is refused by the lock rather than
        # by luck, and never by a traceback.
        self.assertEqual(sorted(statuses.values()), ["locked", "published"])
        remote = self.fx.remote_content()
        winners = [n for n in ("alpha", "beta") if f"- {n}" in remote]
        self.assertEqual(len(winners), 1, remote)
        self.assertTrue((self.fx.docs / "docs" / "ui-bugs.md").read_text().strip())
        self.assertEqual(
            run(["git", "for-each-ref", "--format=%(refname)",
                 "refs/kanban/publish-lock"], self.fx.docs),
            "",
        )

    # -- eligibility ---------------------------------------------------------

    def test_a_pr_atomic_document_publishes_nothing_but_keeps_the_mutation(self):
        # Ineligible is an outcome, not a refusal to do anything: by now the
        # caller has very likely already mutated the tracker, so the approved
        # mutation has to survive being unpublishable.
        result = self.fx.publish("# Design\n\nchanged\n", path="docs/design.md")
        self.assertEqual(result["status"], "not-published")
        self.assertIn("pr-atomic", result["reason"])
        self.assertFalse(result["remote_contains_commit"])
        self.assertEqual(self.fx.remote_content("docs/design.md"), "# Design")
        # Applied locally and recoverable from the object database.
        self.assertTrue(result["document_written"])
        self.assertIn("changed", (self.fx.docs / "docs" / "design.md").read_text())
        self.assertIn(
            "changed",
            run(["git", "cat-file", "-p", result["approved_blob"]], self.fx.docs),
        )

    def test_an_unmatched_document_publishes_nothing(self):
        (self.fx.docs / "docs" / "novel.md").write_text("# Novel\n")
        result = self.fx.publish("# Novel\n\nmore\n", path="docs/novel.md")
        self.assertEqual(result["status"], "not-published")
        self.assertFalse(result["remote_contains_commit"])
        # A novel document has no baseline on the tip, so it is not written
        # over — but the approved content is still recoverable.
        self.assertFalse(result["document_written"])
        self.assertIn(
            "more", run(["git", "cat-file", "-p", result["approved_blob"]], self.fx.docs)
        )

    def test_a_directory_row_matches_by_component_not_prefix(self):
        rows = publisher.parse_classification(CLASSIFICATION)
        self.assertEqual(
            publisher.classify(rows, "codex-plugin/plugins/kanban/x.md")[0], "pr-atomic"
        )
        self.assertEqual(publisher.classify(rows, "codex-plugin-old/x.md")[0], None)

    def test_a_path_matching_two_rows_is_ineligible(self):
        rows = dict(publisher.parse_classification(CLASSIFICATION))
        rows["docs/"] = "coordination"
        klass, matched = publisher.classify(rows, "docs/ui-bugs.md")
        self.assertIsNone(klass)
        self.assertEqual(matched, ["docs/", "docs/ui-bugs.md"])

    def test_a_branch_without_the_contract_has_no_lane(self):
        run(["git", "rm", "-q", "docs/agent-workflow-contract.md"], self.fx.primary)
        run(["git", "commit", "-qm", "drop"], self.fx.primary)
        run(["git", "push", "-q", "origin", "master:master"], self.fx.primary)
        result = self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(result["status"], "not-published")
        self.assertIn("no coordination lane", result["reason"])
        self.assertEqual(self.fx.remote_content(), "# UI\n\n- one")

    def test_a_declared_owner_that_is_not_the_write_roots_is_refused(self):
        # A caller error rather than an outcome: the inputs disagree, so
        # nothing here can be trusted and nothing is written.
        with tempfile.TemporaryDirectory() as other_dir:
            other = Fixture(Path(other_dir), origin_name="synarchy")
            with self.assertRaises(publisher.PublishError) as caught:
                other.publish("# UI\n\n- one\n- two\n", repo="coghex/kanban")
            self.assertEqual(caught.exception.status, "owner-mismatch")
            self.assertEqual(other.remote_content(), "# UI\n\n- one")

    def test_a_non_kanban_repository_keeps_its_mutation_but_publishes_nothing(self):
        with tempfile.TemporaryDirectory() as other_dir:
            other = Fixture(Path(other_dir), origin_name="synarchy")
            result = other.publish("# UI\n\n- one\n- two\n", repo="coghex/synarchy")
            self.assertEqual(result["status"], "not-published")
            self.assertIn("no coordination lane", result["reason"])
            self.assertEqual(other.remote_content(), "# UI\n\n- one")
            # Its own document still receives the approved mutation.
            self.assertTrue(result["document_written"])
            self.assertIn("- two", (other.docs / "docs" / "ui-bugs.md").read_text())

    # -- isolation -----------------------------------------------------------

    def test_a_document_carrying_unrelated_work_publishes_nothing(self):
        target = self.fx.docs / "docs" / "ui-bugs.md"
        target.write_text(target.read_text() + "- somebody else's line\n")
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "document-not-baseline")
        self.assertIn("somebody else's line", target.read_text())
        self.assertEqual(self.fx.remote_content(), "# UI\n\n- one")

    def test_an_edit_landing_before_the_write_is_preserved(self):
        # The window between the baseline check and the write. Simulated by
        # re-entering the helper's own step order: the baseline is verified, an
        # outside edit lands, and the write must be refused.
        target = self.fx.docs / "docs" / "ui-bugs.md"
        original = publisher.working_blob
        state = {"calls": 0}

        def racing_blob(root, document):
            state["calls"] += 1
            result = original(root, document)
            if state["calls"] == 1:  # after the baseline check, before the write
                target.write_text(target.read_text() + "- foreign\n")
            return result

        publisher.working_blob = racing_blob
        self.addCleanup(setattr, publisher, "working_blob", original)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "document-changed-before-write")
        self.assertIn("- foreign", target.read_text())
        self.assertEqual(self.fx.remote_content(), "# UI\n\n- one")

    # -- concurrency on the branch -------------------------------------------

    def test_a_concurrent_advance_before_the_push_fails_closed(self):
        original = publisher.build_commit

        def advancing_build(root, tip, document, blob, message):
            commit = original(root, tip, document, blob, message)
            self.fx.advance_remote()  # lands between the build and the push
            return commit

        publisher.build_commit = advancing_build
        self.addCleanup(setattr, publisher, "build_commit", original)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "unpublished")
        self.assertFalse(caught.exception.detail["remote_contains_commit"])
        # The mutation is recoverable and the other writer's line survives.
        self.assertIn("- two", (self.fx.docs / "docs" / "ui-bugs.md").read_text())
        self.assertIn("somebody else", self.fx.remote_content())

    def test_a_failed_publication_moves_no_local_branch(self):
        # A commit stranded on the local default branch would wedge the PR
        # drainer's `merge --ff-only`.
        before = run(["git", "rev-parse", "master"], self.fx.primary)
        original = publisher.build_commit

        def advancing_build(root, tip, document, blob, message):
            commit = original(root, tip, document, blob, message)
            self.fx.advance_remote()
            return commit

        publisher.build_commit = advancing_build
        self.addCleanup(setattr, publisher, "build_commit", original)
        with self.assertRaises(publisher.PublishError):
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(run(["git", "rev-parse", "master"], self.fx.primary), before)

    def test_a_same_document_advance_after_the_push_is_still_published(self):
        original = publisher.is_ancestor

        def advancing_ancestor(root, commit, revision):
            if not hasattr(advancing_ancestor, "done"):
                advancing_ancestor.done = True
                self.fx.advance_remote()
                run(["git", "fetch", "-q", "origin", "master"], root)
            return original(root, commit, revision)

        publisher.is_ancestor = advancing_ancestor
        self.addCleanup(setattr, publisher, "is_ancestor", original)
        result = self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(result["status"], "published")
        self.assertTrue(result["branch_advanced_after_push"])
        # Both survive, and nothing was republished over the other writer.
        remote = self.fx.remote_content()
        self.assertIn("- two", remote)
        self.assertIn("somebody else", remote)

    # -- the lock ------------------------------------------------------------

    def test_a_second_run_cannot_publish_while_the_lock_is_held(self):
        lock = publisher.lock_ref("coghex/kanban", "docs/ui-bugs.md")
        tip = run(["git", "rev-parse", "origin/master"], self.fx.docs)
        held = publisher.acquire_lock(self.fx.docs, lock, tip)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "locked")
        self.assertEqual(self.fx.remote_content(), "# UI\n\n- one")
        publisher.release_lock(self.fx.docs, lock, held)

    def test_two_worktrees_of_one_repository_serialize(self):
        # The lock lives in the common Git directory, so a second worktree of
        # the same repository contends rather than taking its own lock: in a
        # linked worktree `.git` is a file, and a lock placed under it would
        # not be shared.
        second = Path(self._tmp.name) / "second-wip"
        run(["git", "worktree", "add", "-q", "-b", "second", str(second), "master"], self.fx.primary)
        lock = publisher.lock_ref("coghex/kanban", "docs/ui-bugs.md")
        tip = run(["git", "rev-parse", "origin/master"], self.fx.docs)
        held = publisher.acquire_lock(self.fx.docs, lock, tip)
        with self.assertRaises(publisher.PublishError) as caught:
            held = publisher.acquire_lock(second, lock, tip)
        self.assertEqual(caught.exception.status, "locked")
        publisher.release_lock(self.fx.docs, lock, held)

    def test_the_lock_is_released_on_success_and_on_failure(self):
        lock = publisher.lock_ref("coghex/kanban", "docs/ui-bugs.md")
        self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertIsNone(publisher.read_lock_owner(self.fx.docs, lock))
        self.fx.publish("# Design\n\nchanged\n", path="docs/design.md")
        self.assertIsNone(
            publisher.read_lock_owner(
                self.fx.docs, publisher.lock_ref("coghex/kanban", "docs/design.md")
            )
        )

    def test_clearing_a_lock_is_refused_while_its_owner_lives(self):
        lock = publisher.lock_ref("coghex/kanban", "docs/ui-bugs.md")
        tip = run(["git", "rev-parse", "origin/master"], self.fx.docs)
        held = publisher.acquire_lock(self.fx.docs, lock, tip)  # owned by this process
        with self.assertRaises(publisher.PublishError) as caught:
            publisher.clear_stale_lock(self.fx.docs, lock)
        self.assertEqual(caught.exception.status, "lock-owner-live")
        publisher.release_lock(self.fx.docs, lock, held)

    def test_clearing_a_foreign_lock_is_refused(self):
        lock = publisher.lock_ref("coghex/kanban", "docs/ui-bugs.md")
        tip = run(["git", "rev-parse", "origin/master"], self.fx.docs)
        token = json.dumps({"host": "some-other-host", "pid": 1}, sort_keys=True,
                           separators=(",", ":"))
        commit = run(["git", "commit-tree", f"{tip}^{{tree}}", "-m", token], self.fx.docs)
        run(["git", "update-ref", lock, commit], self.fx.docs)
        with self.assertRaises(publisher.PublishError) as caught:
            publisher.clear_stale_lock(self.fx.docs, lock)
        self.assertEqual(caught.exception.status, "lock-foreign-owner")
        publisher.release_lock(self.fx.docs, lock, commit)

    def test_a_dead_owners_lock_clears(self):
        lock = publisher.lock_ref("coghex/kanban", "docs/ui-bugs.md")
        tip = run(["git", "rev-parse", "origin/master"], self.fx.docs)
        dead = subprocess.Popen(["true"])
        dead.wait()
        token = json.dumps(
            {"host": publisher.socket.gethostname(), "pid": dead.pid},
            sort_keys=True, separators=(",", ":"),
        )
        commit = run(["git", "commit-tree", f"{tip}^{{tree}}", "-m", token], self.fx.docs)
        run(["git", "update-ref", lock, commit], self.fx.docs)
        self.assertEqual(
            publisher.clear_stale_lock(self.fx.docs, lock)["status"], "cleared"
        )
        self.assertIsNone(publisher.read_lock_owner(self.fx.docs, lock))

    # -- resumption ----------------------------------------------------------

    def _leave_pending(self):
        """A failed publication: the approved content is in the write root and
        a pending record identifies it."""
        original = publisher.build_commit

        def advancing_build(root, tip, document, blob, message):
            commit = original(root, tip, document, blob, message)
            self.fx.advance_remote()
            return commit

        publisher.build_commit = advancing_build
        try:
            with self.assertRaises(publisher.PublishError):
                self.fx.publish("# UI\n\n- one\n- two\n")
        finally:
            publisher.build_commit = original

    def test_a_resumption_publishes_the_recorded_mutation(self):
        # Fail with the branch unmoved, so the record stays retryable.
        original = publisher.git

        def failing_push(args, *, cwd, check=True, input_bytes=None):
            if args[:2] == ["push", "origin"]:
                return subprocess.CompletedProcess(args, 1, b"", b"simulated failure")
            return original(args, cwd=cwd, check=check, input_bytes=input_bytes)

        publisher.git = failing_push
        try:
            with self.assertRaises(publisher.PublishError) as caught:
                self.fx.publish("# UI\n\n- one\n- two\n")
            self.assertEqual(caught.exception.status, "unpublished")
        finally:
            publisher.git = original
        result = self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(result["status"], "published")
        self.assertEqual(result["resumed"], "retried")
        self.assertIn("- two", self.fx.remote_content())

    def test_a_second_disposition_cannot_publish_over_a_pending_one(self):
        # The lifecycle hazard: a later invocation renders a *different*
        # approved mutation. Publishing the recorded one instead would report
        # success while the new disposition never reached the document — and
        # the caller has already created its tracker item.
        original = publisher.git

        def failing_push(args, *, cwd, check=True, input_bytes=None):
            if args[:2] == ["push", "origin"]:
                return subprocess.CompletedProcess(args, 1, b"", b"simulated failure")
            return original(args, cwd=cwd, check=check, input_bytes=input_bytes)

        publisher.git = failing_push
        try:
            with self.assertRaises(publisher.PublishError):
                self.fx.publish("# UI\n\n- one\n- first disposition\n")
        finally:
            publisher.git = original

        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- SECOND disposition\n")
        self.assertEqual(caught.exception.status, "pending-differs-from-approved")
        self.assertEqual(self.fx.remote_content(), "# UI\n\n- one")
        # The record still names the first, and neither is lost.
        pending = publisher.pending_ref("coghex/kanban", "docs/ui-bugs.md")
        self.assertNotEqual(
            run(["git", "rev-parse", "--verify", "--quiet", pending], self.fx.docs), ""
        )
        # Supplying the recorded mutation again still resumes it.
        result = self.fx.publish("# UI\n\n- one\n- first disposition\n")
        self.assertEqual(result["status"], "published")
        self.assertIn("- first disposition", self.fx.remote_content())

    def test_a_foreign_edit_after_a_failed_publication_fails_closed(self):
        self._leave_pending()
        target = self.fx.docs / "docs" / "ui-bugs.md"
        target.write_text(target.read_text() + "- user work in progress\n")
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "document-not-baseline")
        self.assertIn("user work in progress", target.read_text())

    def test_a_stale_pending_record_fails_closed(self):
        self._leave_pending()  # the branch advanced under the record
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "pending-stale")
        self.assertIn("somebody else", self.fx.remote_content())

    def test_an_already_landed_record_reconciles_without_pushing_again(self):
        # Interrupted after a successful push but before verification.
        original = publisher.is_ancestor
        publisher.is_ancestor = lambda root, commit, revision: False
        try:
            with self.assertRaises(publisher.PublishError) as caught:
                self.fx.publish("# UI\n\n- one\n- two\n")
            self.assertEqual(caught.exception.status, "unpublished")
        finally:
            publisher.is_ancestor = original
        landed = run(["git", "rev-parse", "origin/master"], self.fx.primary)
        result = self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(result["status"], "published")
        self.assertEqual(result["resumed"], "already-landed")
        run(["git", "fetch", "-q", "origin", "master"], self.fx.primary)
        self.assertEqual(run(["git", "rev-parse", "origin/master"], self.fx.primary), landed)

    def test_a_missing_pending_record_fails_closed(self):
        target = self.fx.docs / "docs" / "ui-bugs.md"
        target.write_text("# UI\n\n- one\n- two\n")  # applied, never recorded
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "document-not-baseline")

    def test_identical_content_is_not_a_publication(self):
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n")
        self.assertEqual(caught.exception.status, "no-mutation")


if __name__ == "__main__":
    unittest.main()
