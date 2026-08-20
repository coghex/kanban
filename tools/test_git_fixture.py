"""Executable coverage for tools/git_fixture.py.

Issue #384. The five heavy `tools/` test modules stopped rebuilding their Git
repository per test and now copy one immutable template instead, so the
guarantees that used to come free from building a fresh repository every time
have to be proved here: that a copy is reachable only from itself, that the
template cannot be written through one, and that a copy is the checkout the
template built rather than a tree Git considers dirty.

Every assertion about a path reads back what Git resolves rather than the
metadata text `git_fixture` rewrote, because a rewrite producing a well-formed
lie is exactly the failure being ruled out.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

# `python3 -m unittest tools.test_git_fixture` imports this module by package
# path, which puts the repository root on sys.path rather than tools/ --
# unlike `-m unittest discover -s tools`. Both invocations have to reach the
# sibling module, so name the directory outright.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import git_fixture


def run(args, cwd):
    proc = subprocess.run(args, cwd=str(cwd), text=True, capture_output=True)
    if proc.returncode != 0:
        raise AssertionError(f"{args} failed in {cwd}:\n{proc.stderr}")
    return proc.stdout.strip()


def build_demo_repository(root, data):
    """Every shape the real fixtures relocate, in one small repository.

    A bare remote, a clone of it, a linked worktree of that clone, and a
    symlink naming the tree by absolute path -- which is the only one of the
    four the real fixtures do not already have, and the one a hand-written
    list of metadata files would miss.
    """
    bare = root / "remote.git"
    main = root / "main"
    linked = root / "linked"

    run(["git", "init", "--bare", "-q", "-b", "master", str(bare)], root)
    run(["git", "init", "-q", "-b", "master", str(main)], root)
    run(["git", "config", "user.email", "t@example.com"], main)
    run(["git", "config", "user.name", "Test"], main)
    (main / "README").write_text("hello\n", encoding="utf-8")
    run(["git", "add", "README"], main)
    run(["git", "commit", "-qm", "initial"], main)
    run(["git", "remote", "add", "origin", str(bare)], main)
    run(["git", "push", "-q", "-u", "origin", "master"], main)
    run(["git", "worktree", "add", "-q", "-b", "side", str(linked), "master"], main)
    run(["git", "clone", "-q", str(bare), str(root / "clone")], root)
    (root / "pointer").symlink_to(main)
    data["head"] = run(["git", "rev-parse", "HEAD"], main)


class DemoFixture(git_fixture.GitTemplateMixin, unittest.TestCase):
    @classmethod
    def build_git_template(cls, root, data):
        build_demo_repository(root, data)

    def setUp(self):
        self.root = self.checkout_git_template()
        self.main = self.root / "main"
        self.linked = self.root / "linked"


class CopyIsolationTests(git_fixture.SharedTemplateIsolationTests, DemoFixture):
    """The shared guarantees, applied to a fixture holding every shape."""

    def _mutate_the_copy(self):
        (self.main / "README").write_text("rewritten\n", encoding="utf-8")
        run(["git", "commit", "-qam", "a test rewrote history"], self.main)
        run(["git", "push", "-q", "-f", "origin", "master"], self.main)
        run(["git", "worktree", "remove", "--force", str(self.linked)], self.main)


class RelocationTests(DemoFixture):
    """What a copy resolves, and what it must not."""

    def test_a_symlink_by_absolute_path_follows_its_copy(self):
        pointer = self.root / "pointer"
        self.assertTrue(pointer.is_symlink())
        self.assertEqual(os.path.realpath(pointer), os.path.realpath(self.main))

    def test_the_linked_worktree_resolves_into_its_own_copy(self):
        # Both halves of the linkage: the worktree's own `.git` file names the
        # main repository's administrative directory, and that directory's
        # `gitdir` names the worktree back.
        common = run(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            self.linked,
        )
        self.assertEqual(Path(common), Path(os.path.realpath(self.main / ".git")))
        listed = run(["git", "worktree", "list", "--porcelain"], self.main)
        registered = [
            line[len("worktree "):]
            for line in listed.splitlines()
            if line.startswith("worktree ")
        ]
        self.assertEqual(
            sorted(os.path.realpath(path) for path in registered),
            sorted(os.path.realpath(path) for path in (self.main, self.linked)),
        )

    def test_a_push_from_a_copy_reaches_only_its_own_remote(self):
        # The failure this rules out is silent in the direction that matters:
        # a copy whose `remote.origin.url` still named the template would push
        # into it and read back its own commit.
        (self.main / "README").write_text("from this copy\n", encoding="utf-8")
        run(["git", "commit", "-qam", "from this copy"], self.main)
        run(["git", "push", "-q", "origin", "master"], self.main)

        self.assertEqual(
            run(["git", "show", "master:README"], self.root / "remote.git"),
            "from this copy",
        )
        template_remote = self.git_template().root / "remote.git"
        self.assertEqual(
            run(["git", "show", "master:README"], template_remote), "hello"
        )

    def test_a_copy_is_a_clean_checkout_and_not_merely_a_clean_status(self):
        # A copied index still describes the template's inodes, so a checkout
        # handed over unrefreshed reads clean through `git status` -- which
        # falls back to comparing content -- while every plumbing command that
        # trusts stat alone calls each tracked file modified.
        for tree in (self.main, self.linked):
            self.assertEqual(run(["git", "status", "--porcelain"], tree), "")
            self.assertEqual(run(["git", "diff-files", "--name-only"], tree), "")
            # `run` fails the test on a non-zero exit, which is what an
            # unrefreshed index makes this command do; the empty result is
            # what "there is nothing here to stash" looks like.
            self.assertEqual(run(["git", "stash", "create", "probe"], tree), "")

    def test_no_file_in_a_copy_names_the_template(self):
        # The sweep `copy()` performs, asserted from outside it.
        template = self.git_template().root
        olds = [form.encode() for form in git_fixture.path_forms(template)]
        offenders = []
        for directory, _, names in os.walk(self.root):
            for name in names:
                path = Path(directory) / name
                if path.is_symlink():
                    blob = os.readlink(path).encode()
                else:
                    blob = path.read_bytes()
                if any(old in blob for old in olds):
                    offenders.append(str(path.relative_to(self.root)))
        self.assertEqual(offenders, [])


class TemplateImmutabilityTests(DemoFixture):
    """Requirement 3: nothing may write to the template after it is built."""

    def test_the_template_tree_is_not_writable(self):
        template = self.git_template().root
        for path in (template, template / "main", template / "main" / "README"):
            self.assertFalse(
                os.access(path, os.W_OK), f"{path} is writable in the template"
            )

    def test_a_commit_in_the_template_is_refused(self):
        template = self.git_template().root
        proc = subprocess.run(
            ["git", "commit", "-q", "--allow-empty", "-m", "should not land"],
            cwd=str(template / "main"),
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(proc.returncode, 0)


class IndependentCopyTests(DemoFixture):
    """Requirement 5, at the seam a case re-running its own `setUp()` uses."""

    def test_calling_the_checkout_again_hands_back_a_separate_copy(self):
        first = self.root
        (first / "main" / "README").write_text("first\n", encoding="utf-8")
        run(["git", "commit", "-qam", "first"], first / "main")

        second = self.checkout_git_template()

        self.assertNotEqual(first, second)
        self.assertEqual(
            (second / "main" / "README").read_text(encoding="utf-8"), "hello\n"
        )
        self.assertEqual(
            run(["git", "log", "--format=%s"], second / "main"), "initial"
        )

    def test_a_removed_worktree_is_back_in_the_next_copy(self):
        run(["git", "worktree", "remove", "--force", str(self.linked)], self.main)
        self.assertFalse(self.linked.exists())

        successor = self.checkout_git_template()

        self.assertTrue((successor / "linked").is_dir())
        git_fixture.assert_repositories_are_self_contained(self, successor)


class UnrelocatableStateTests(unittest.TestCase):
    """The refusal, which is the part that makes the rest safe to rely on."""

    def test_a_path_where_it_cannot_be_rewritten_is_reported_not_shipped(self):
        # Object storage is compressed and checksummed, so a template path
        # found there is a hole in what `git_fixture` understands rather than
        # something to patch over. Planting one is the only way to reach that
        # branch, and reaching it has to be loud.
        def build(root, data):
            build_demo_repository(root, data)
            planted = root / "main" / ".git" / "objects" / "info" / "planted"
            planted.parent.mkdir(parents=True, exist_ok=True)
            planted.write_bytes(str(root).encode())

        template = git_fixture.GitTemplate(build, label="unrelocatable")
        self.addCleanup(template.cleanup)

        with self.assertRaises(git_fixture.RelocationError) as caught:
            template.copy()

        self.assertIn("planted", str(caught.exception))


class TemplateSharingTests(unittest.TestCase):
    """Which classes share a template, and which get one of their own."""

    def test_a_subclass_inheriting_the_builder_shares_one_template(self):
        class Child(DemoFixture):
            pass

        self.assertIs(Child.git_template(), DemoFixture.git_template())

    def test_a_subclass_overriding_the_builder_gets_its_own(self):
        class Extended(DemoFixture):
            @classmethod
            def build_git_template(cls, root, data):
                super().build_git_template(root, data)
                (root / "main" / "EXTRA").write_text("extra\n", encoding="utf-8")
                run(["git", "add", "EXTRA"], root / "main")
                run(["git", "commit", "-qm", "extra"], root / "main")

        template = Extended.git_template()
        self.addCleanup(template.cleanup)

        self.assertIsNot(template, DemoFixture.git_template())
        self.assertTrue((template.root / "main" / "EXTRA").exists())
        self.assertFalse((DemoFixture.git_template().root / "main" / "EXTRA").exists())


class DiscoveryTests(unittest.TestCase):
    """What `repositories()` finds, since the checks above are only as
    complete as the set of repositories they are applied to."""

    def test_bare_remotes_clones_and_linked_worktrees_are_all_found(self):
        template = DemoFixture.git_template()
        copy = template.copy()
        self.addCleanup(shutil.rmtree, copy, True)

        found = {path.name for path in git_fixture.repositories(copy)}

        self.assertEqual(found, {"remote.git", "main", "linked", "clone"})
        self.assertEqual(
            {path.name for path in git_fixture.working_trees(copy)},
            {"main", "linked", "clone"},
        )
