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

import importlib.util
import json
import os
import subprocess
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
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# Design\n\nchanged\n", path="docs/design.md")
        detail = caught.exception.detail
        self.assertEqual(caught.exception.status, "not-eligible")
        self.assertIn("document_edit", detail)
        self.assertTrue(detail["document_edit"]["exists"])
        self.assertIn("local_publication_commit", detail)
        self.assertIsNone(detail["local_publication_commit"])
        self.assertIn("remote_contains_commit", detail)
        self.assertIsNone(detail["remote_contains_commit"])

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

    # -- eligibility ---------------------------------------------------------

    def test_a_pr_atomic_document_publishes_nothing(self):
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# Design\n\nchanged\n", path="docs/design.md")
        self.assertEqual(caught.exception.status, "not-eligible")

    def test_an_unmatched_document_publishes_nothing(self):
        (self.fx.docs / "docs" / "novel.md").write_text("# Novel\n")
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# Novel\n\nmore\n", path="docs/novel.md")
        self.assertEqual(caught.exception.status, "not-eligible")

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
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "not-eligible")

    def test_another_owner_publishes_nothing_even_when_kanban_is_declared(self):
        with tempfile.TemporaryDirectory() as other_dir:
            other = Fixture(Path(other_dir), origin_name="synarchy")
            with self.assertRaises(publisher.PublishError) as caught:
                other.publish("# UI\n\n- one\n- two\n", repo="coghex/kanban")
            self.assertEqual(caught.exception.status, "owner-mismatch")
            self.assertEqual(other.remote_content(), "# UI\n\n- one")

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
        publisher.acquire_lock(self.fx.docs, lock, tip)
        with self.assertRaises(publisher.PublishError) as caught:
            self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertEqual(caught.exception.status, "locked")
        self.assertEqual(self.fx.remote_content(), "# UI\n\n- one")
        publisher.release_lock(self.fx.docs, lock)

    def test_two_worktrees_of_one_repository_serialize(self):
        # The lock lives in the common Git directory, so a second worktree of
        # the same repository contends rather than taking its own lock: in a
        # linked worktree `.git` is a file, and a lock placed under it would
        # not be shared.
        second = Path(self._tmp.name) / "second-wip"
        run(["git", "worktree", "add", "-q", "-b", "second", str(second), "master"], self.fx.primary)
        lock = publisher.lock_ref("coghex/kanban", "docs/ui-bugs.md")
        tip = run(["git", "rev-parse", "origin/master"], self.fx.docs)
        publisher.acquire_lock(self.fx.docs, lock, tip)
        with self.assertRaises(publisher.PublishError) as caught:
            publisher.acquire_lock(second, lock, tip)
        self.assertEqual(caught.exception.status, "locked")
        publisher.release_lock(self.fx.docs, lock)

    def test_the_lock_is_released_on_success_and_on_failure(self):
        lock = publisher.lock_ref("coghex/kanban", "docs/ui-bugs.md")
        self.fx.publish("# UI\n\n- one\n- two\n")
        self.assertIsNone(publisher.read_lock_owner(self.fx.docs, lock))
        with self.assertRaises(publisher.PublishError):
            self.fx.publish("# Design\n", path="docs/design.md")
        self.assertIsNone(
            publisher.read_lock_owner(
                self.fx.docs, publisher.lock_ref("coghex/kanban", "docs/design.md")
            )
        )

    def test_clearing_a_lock_is_refused_while_its_owner_lives(self):
        lock = publisher.lock_ref("coghex/kanban", "docs/ui-bugs.md")
        tip = run(["git", "rev-parse", "origin/master"], self.fx.docs)
        publisher.acquire_lock(self.fx.docs, lock, tip)  # owned by this process
        with self.assertRaises(publisher.PublishError) as caught:
            publisher.clear_stale_lock(self.fx.docs, lock)
        self.assertEqual(caught.exception.status, "lock-owner-live")
        publisher.release_lock(self.fx.docs, lock)

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
        publisher.release_lock(self.fx.docs, lock)

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
