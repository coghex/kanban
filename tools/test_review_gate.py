"""Tests for `.github/workflows/review-gate.yml`'s dismiss-stale-approval job.

Keeping `reviewed:approve` on a synchronize is this repository's only positive
content-safe signal, and `tools/drain_prs.py` carries approval across a branch
update on nothing else. So the predicate that decides it is executed here
rather than read: the job's shell script is extracted from the workflow and run
under bash against a real temporary Git repository with a scriptable fake `gh`
on PATH, once per case it has to fail closed on.

The extractor is deliberately dependency-free -- CI runs this suite with the
runner's bare `python3` -- so it walks the workflow by indentation instead of
loading YAML.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import fake_cli


REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "review-gate.yml"
ZERO_SHA = "0" * 40
APPROVE_LABEL = "reviewed:approve"


def setUpModule():
    # `tools/` ships whole in the source distribution and `.github/workflows/`
    # deliberately does not, so an unpacked release runs this module with
    # nothing to read. That is the packaged state, not a failure.
    if not WORKFLOW.is_file():
        raise unittest.SkipTest(f"{WORKFLOW} is absent (not a Git checkout)")


def job_lines(name):
    """The workflow lines belonging to one top-level job, header excluded."""
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    header = f"  {name}:"
    try:
        start = lines.index(header)
    except ValueError as error:  # pragma: no cover - a renamed job
        raise AssertionError(f"{WORKFLOW} has no job named {name}") from error
    body = []
    for line in lines[start + 1 :]:
        if line.strip() and not line.startswith("   "):
            break
        body.append(line)
    return body


def job_if(name):
    """The job's `if:` expression, or None when it is unconditional."""
    for line in job_lines(name):
        if line.startswith("    if:"):
            return line.split(":", 1)[1].strip()
    return None


def last_run_script(name):
    """The final `run: |` block in a job, dedented to a runnable script."""
    body = job_lines(name)
    starts = [index for index, line in enumerate(body) if line.strip() == "run: |"]
    if not starts:  # pragma: no cover - a rewritten job
        raise AssertionError(f"job {name} has no block `run:` step")
    start = starts[-1]
    indent = len(body[start]) - len(body[start].lstrip()) + 2
    script = []
    for line in body[start + 1 :]:
        if line.strip() and not line.startswith(" " * indent):
            break
        script.append(line[indent:] if line.strip() else "")
    return "\n".join(script) + "\n"


class DismissStaleApprovalJobTests(unittest.TestCase):
    """The job's own contract, before any of its shell runs."""

    def test_it_evaluates_every_synchronize_rather_than_approved_ones_only(self):
        # A run skipped because the payload had no label leaves an earlier
        # run's SUCCESS as the latest non-skipped result, and the drainer
        # would read that stale success as speaking for the newer head.
        self.assertEqual(
            job_if("dismiss-stale-approval"),
            "github.event.action == 'synchronize'",
        )

    def test_it_checks_out_full_history_at_the_pushed_head(self):
        # `before` is only reachable, and so only comparable, in a checkout
        # that has the branch's history rather than one commit of it.
        body = "\n".join(job_lines("dismiss-stale-approval"))
        self.assertIn("uses: actions/checkout@v6", body)
        self.assertIn("fetch-depth: 0", body)
        self.assertIn("ref: ${{ github.event.pull_request.head.sha }}", body)


class DismissStaleApprovalPredicateTests(unittest.TestCase):
    """The extracted shell script, executed once per decision it has to make.

    Each case builds the push it describes for real -- a base branch, a pull
    request branched from it, a `before` and an `after` -- and asserts on
    whether the script called `gh pr edit --remove-label`, which is the whole
    of its externally visible behavior. The pull request's own files are
    whatever that history makes them, the way GitHub would count them, so no
    case can hand the job a file list its own history contradicts.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.script = last_run_script("dismiss-stale-approval")
        self.fixtures = 0
        self.fresh_repository()

    def fresh_repository(self):
        """A new checkout and fake `gh`, for a case that builds several."""
        self.fixtures += 1
        self.root = Path(self.tmp.name) / f"fixture-{self.fixtures}"
        self.repo = self.root / "checkout"
        self.repo.mkdir(parents=True)
        self.git("init", "-q", "-b", "master")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")
        self.fake = fake_cli.FakeCli(self.root / "fake")
        self.fake.install("gh")

    # -- the repository the job runs in -----------------------------------

    def git(self, *args):
        proc = subprocess.run(
            ["git", *args], cwd=str(self.repo), text=True, capture_output=True
        )
        if proc.returncode != 0:  # pragma: no cover - a broken fixture
            raise RuntimeError(f"git {args} failed:\n{proc.stdout}\n{proc.stderr}")
        return proc.stdout.strip()

    def commit(self, message, files=None):
        """Commit `files` on the current branch; a None value deletes one."""
        for name, contents in (files or {}).items():
            path = self.repo / name
            if contents is None:
                path.unlink()
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents, encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def publish_base(self):
        """Record master's tip as the fetched base branch, as the job sees it."""
        self.git("update-ref", "refs/remotes/origin/master", "master")

    def open_pr(self, change, *, base=None):
        """Commit `base` on master, branch `pr` from it, and commit the pull
        request's own `change` there. Returns that commit: the usual `before`."""
        self.commit("base", base or {"src/app.py": "one\n", "docs/guide.md": "one\n"})
        self.publish_base()
        self.git("checkout", "-q", "-b", "pr")
        return self.commit("pr", change)

    def advance_base(self, files):
        """Move master on by one commit, leaving the pull request branch
        checked out."""
        self.git("checkout", "-q", "master")
        tip = self.commit("advance", files)
        self.publish_base()
        self.git("checkout", "-q", "pr")
        return tip

    def merge_base_forward(self):
        """What a branch update does: merge the base into the pull request."""
        self.git("merge", "-q", "--no-edit", "master")
        return self.git("rev-parse", "HEAD")

    def github_file_list(self, head, base_ref):
        """`gh pr diff --name-only` as GitHub would answer it for `head`:
        literal names, one per line, measured from where it meets the base.
        The job no longer asks, but a version of it that does is told the
        truth, so a case can only pass on the job's own reasoning."""
        base = f"refs/remotes/origin/{base_ref}"
        proc = subprocess.run(
            ["git", "merge-base", base, head],
            cwd=str(self.repo), text=True, capture_output=True,
        )
        if proc.returncode != 0 or not base_ref:
            return {"stdout": "", "exit_code": 1}
        names = subprocess.run(
            ["git", "diff", "--no-renames", "--name-only", "-z", proc.stdout.strip(), head],
            cwd=str(self.repo), capture_output=True, check=True,
        ).stdout.decode("utf-8").split("\0")
        return {"stdout": "".join(f"{name}\n" for name in names if name)}

    # -- running the job's step -------------------------------------------

    def run_step(
        self,
        *,
        before,
        after,
        base_ref="master",
        edit_ok=True,
        labels_after=(),
        labels_readable=True,
        expect_exit=0,
    ):
        """Run the extracted script for one push; report whether it stripped.

        `labels_after` is what `gh pr view` reports once the removal has been
        attempted, which is the only thing the job may conclude a strip from.
        """
        self.fake.script("gh", ["pr", "diff", "7"], **self.github_file_list(after, base_ref))
        self.fake.script("gh", ["pr", "edit", "7"], stdout="", exit_code=0 if edit_ok else 1)
        self.fake.script(
            "gh",
            ["pr", "view", "7"],
            stdout="".join(f"{name}\n" for name in labels_after),
            exit_code=0 if labels_readable else 1,
        )
        env = dict(os.environ)
        env.update(self.fake.environ_overrides())
        env.update(
            {
                "GH_TOKEN": "fake-token",
                "BEFORE": before,
                "AFTER": after,
                "BASE_REF": base_ref,
                "PR_NUMBER": "7",
                "REPO": "acme/widgets",
            }
        )
        proc = subprocess.run(
            ["bash", "-e", "-c", self.script],
            cwd=str(self.repo),
            env=env,
            text=True,
            capture_output=True,
            stdin=subprocess.DEVNULL,
        )
        self.assertEqual(
            proc.returncode, expect_exit, f"{proc.stdout}\n{proc.stderr}"
        )
        removals = [
            call
            for call in self.fake.calls("gh")
            if call["args"][:2] == ["pr", "edit"]
            and "--remove-label" in call["args"]
            and APPROVE_LABEL in call["args"]
        ]
        return bool(removals), proc.stdout

    def assert_stripped(self, **kwargs):
        stripped, output = self.run_step(**kwargs)
        self.assertTrue(stripped, f"expected the label stripped; job said:\n{output}")
        return output

    def assert_kept(self, **kwargs):
        stripped, output = self.run_step(**kwargs)
        self.assertFalse(stripped, f"expected the label kept; job said:\n{output}")
        return output

    # -- the one case that keeps approval ---------------------------------

    def test_a_push_touching_no_pr_owned_file_keeps_the_approval(self):
        # The base-branch update merged forward over divergent history: the
        # delta is real, and none of it is content this pull request owns.
        before = self.open_pr({"src/app.py": "two\n"})
        self.advance_base({"docs/guide.md": "two\n"})
        after = self.merge_base_forward()
        self.assert_kept(before=before, after=after)

    def test_a_base_that_advanced_again_after_the_update_keeps_the_approval(self):
        # The fetched base tip is newer than what `after` merged in. Measuring
        # `after` from where it meets the base, rather than from the tip,
        # keeps base-only changes from counting as the pull request's.
        before = self.open_pr({"src/app.py": "two\n"})
        self.advance_base({"docs/guide.md": "two\n"})
        after = self.merge_base_forward()
        self.advance_base({"docs/guide.md": "three\n", "docs/more.md": "new\n"})
        self.assert_kept(before=before, after=after)

    # -- everything it cannot prove content-free ---------------------------

    def test_a_push_touching_a_pr_owned_file_removes_the_approval(self):
        before = self.open_pr({"src/app.py": "two\n"})
        after = self.commit("edit", {"src/app.py": "three\n"})
        self.assert_stripped(before=before, after=after)

    def test_a_partial_overlap_removes_the_approval(self):
        # One reviewed file among untouched ones is still reviewed content
        # that changed.
        before = self.open_pr({"src/app.py": "two\n", "README.md": "new\n"})
        after = self.commit("edit", {"src/app.py": "three\n", "docs/guide.md": "two\n"})
        self.assert_stripped(before=before, after=after)

    def test_reverting_one_of_two_reviewed_files_removes_the_approval(self):
        # The reverted file leaves the pull request's post-push diff, so only
        # its pre-push file set still names it.
        before = self.open_pr({"src/app.py": "two\n", "tests/app_test.py": "new\n"})
        after = self.commit("revert", {"src/app.py": "one\n"})
        self.assert_stripped(before=before, after=after)

    def test_deleting_a_file_the_pr_added_removes_the_approval(self):
        before = self.open_pr({"src/app.py": "two\n", "src/helper.py": "new\n"})
        after = self.commit("drop", {"src/helper.py": None})
        self.assert_stripped(before=before, after=after)

    def test_adding_a_file_with_a_non_ascii_name_removes_the_approval(self):
        before = self.open_pr({"src/app.py": "two\n"})
        after = self.commit("add", {"café.txt": "new\n"})
        self.assert_stripped(before=before, after=after)

    def test_editing_a_reviewed_file_with_a_non_ascii_name_removes_the_approval(self):
        before = self.open_pr({"café.txt": "new\n"})
        after = self.commit("edit", {"café.txt": "newer\n"})
        self.assert_stripped(before=before, after=after)

    # Every character `git diff --name-only` quotes or escapes under its
    # defaults, including the ones no `core.quotePath` setting unquotes.
    UNUSUAL_NAMES = (
        "café.txt",
        'say "hi".txt',
        "back\\slash.txt",
        "tab\there.txt",
        "new\nline.txt",
    )

    def test_every_push_to_an_unusually_named_file_removes_the_approval(self):
        for name in self.UNUSUAL_NAMES:
            with self.subTest(name=name, push="add"):
                self.fresh_repository()
                before = self.open_pr({"src/app.py": "two\n"})
                after = self.commit("add", {name: "new\n"})
                self.assert_stripped(before=before, after=after)
            with self.subTest(name=name, push="edit"):
                self.fresh_repository()
                before = self.open_pr({name: "new\n"})
                after = self.commit("edit", {name: "newer\n"})
                self.assert_stripped(before=before, after=after)
            with self.subTest(name=name, push="revert"):
                self.fresh_repository()
                before = self.open_pr(
                    {name: "two\n"}, base={"src/app.py": "one\n", name: "one\n"}
                )
                before = self.commit("second", {"src/app.py": "two\n"})
                after = self.commit("revert", {name: "one\n"})
                self.assert_stripped(before=before, after=after)
            with self.subTest(name=name, push="delete"):
                self.fresh_repository()
                before = self.open_pr({name: "new\n", "src/app.py": "two\n"})
                after = self.commit("drop", {name: None})
                self.assert_stripped(before=before, after=after)

    def test_an_unusual_name_matches_only_itself(self):
        # The control for the cases above: the base adds a file literally
        # spelled the way Git quotes the pull request's own file. Only a
        # comparison that confuses a quoted name with a literal one sees an
        # overlap here, and there is none.
        before = self.open_pr({"tab\there.txt": "new\n"})
        self.advance_base({'"tab\\there.txt"': "new\n", "tab here.txt": "new\n"})
        after = self.merge_base_forward()
        output = self.assert_kept(before=before, after=after)
        self.assertIn("keeping", output)

    def test_renaming_a_reviewed_file_removes_the_approval(self):
        # With rename detection on, a diff reports only one of the two paths;
        # both must count, whichever one the pull request owns.
        before = self.open_pr({"src/café.py": "new\n"})
        self.git("mv", "src/café.py", "src/tab\tmoved.py")
        after = self.commit("rename")
        self.assert_stripped(before=before, after=after)

    def test_renaming_a_base_file_onto_a_reviewed_name_removes_the_approval(self):
        # Only the destination is the pull request's, before the push.
        before = self.open_pr({"src/new.py": "new\n"})
        self.git("rm", "-q", "src/new.py")
        self.git("mv", "docs/guide.md", "src/new.py")
        after = self.commit("rename")
        self.assert_stripped(before=before, after=after)

    def test_a_base_rename_merged_forward_keeps_the_approval(self):
        # Both ends of a base-only rename are base-owned: no overlap.
        before = self.open_pr({"src/app.py": "two\n"})
        self.git("checkout", "-q", "master")
        self.git("mv", "docs/guide.md", 'docs/"quoted"\tguide.md')
        self.commit("rename")
        self.publish_base()
        self.git("checkout", "-q", "pr")
        after = self.merge_base_forward()
        self.assert_kept(before=before, after=after)

    def test_an_empty_before_sha_removes_the_approval(self):
        after = self.open_pr({"src/app.py": "two\n"})
        self.assert_stripped(before="", after=after)

    def test_an_all_zero_before_sha_removes_the_approval(self):
        after = self.open_pr({"src/app.py": "two\n"})
        self.assert_stripped(before=ZERO_SHA, after=after)

    def test_an_unreachable_before_sha_removes_the_approval(self):
        # What a force-push looks like from here: the replaced commit is gone,
        # so nothing can prove the new head is content-free.
        after = self.open_pr({"src/app.py": "two\n"})
        self.assert_stripped(before="b" * 40, after=after)

    def test_an_empty_after_sha_removes_the_approval(self):
        before = self.open_pr({"src/app.py": "two\n"})
        self.assert_stripped(before=before, after="")

    def test_an_all_zero_after_sha_removes_the_approval(self):
        before = self.open_pr({"src/app.py": "two\n"})
        self.assert_stripped(before=before, after=ZERO_SHA)

    def test_an_unreachable_after_sha_removes_the_approval(self):
        before = self.open_pr({"src/app.py": "two\n"})
        self.assert_stripped(before=before, after="b" * 40)

    def test_a_push_with_no_file_delta_removes_the_approval(self):
        # Nothing to compare against the PR's files, so non-overlap would be
        # unobserved rather than proven.
        before = self.open_pr({"src/app.py": "two\n"})
        after = self.commit("empty")
        self.assert_stripped(before=before, after=after)

    def test_a_base_branch_missing_from_the_checkout_removes_the_approval(self):
        # Without the base, neither of the pull request's file sets can be
        # established.
        before = self.open_pr({"src/app.py": "two\n"})
        self.advance_base({"docs/guide.md": "two\n"})
        after = self.merge_base_forward()
        self.assert_stripped(before=before, after=after, base_ref="release")
        self.assert_stripped(before=before, after=after, base_ref="")

    def test_a_pre_push_file_set_that_cannot_be_established_removes_the_approval(self):
        # `before` is a real, reachable commit -- only its file set relative
        # to the base is unknowable, because it shares no history with it.
        self.commit("base", {"src/app.py": "one\n", "docs/guide.md": "one\n"})
        self.publish_base()
        self.git("checkout", "-q", "--orphan", "replaced")
        before = self.commit("unrelated", {"src/app.py": "two\n"})
        self.git("checkout", "-q", "-B", "pr", "master")
        after = self.commit("pr", {"docs/other.md": "new\n"})
        output = self.assert_stripped(before=before, after=after)
        self.assertIn("before the push", output)

    def test_a_post_push_file_set_that_cannot_be_established_removes_the_approval(self):
        before = self.open_pr({"src/app.py": "two\n"})
        self.git("checkout", "-q", "--orphan", "replacement")
        after = self.commit("unrelated", {"docs/other.md": "new\n"})
        output = self.assert_stripped(before=before, after=after)
        self.assertIn("after the push", output)

    def test_an_empty_pr_file_list_removes_the_approval(self):
        # The base landed the pull request's change on its own, so after the
        # update the pull request changes nothing. An empty set answers
        # nothing: non-overlap against it is never proof.
        before = self.open_pr({"src/app.py": "two\n"})
        self.advance_base({"src/app.py": "two\n", "docs/guide.md": "two\n"})
        after = self.merge_base_forward()
        output = self.assert_stripped(before=before, after=after)
        self.assertIn("no files of its own after the push", output)

    # -- a strip is only a strip once the label is gone --------------------

    def test_a_removal_that_left_the_label_attached_fails_the_job(self):
        # The whole defect in one shape: succeeding here with the label still
        # attached is exactly the pair the drainer reads as content-safe, so a
        # removal that did not take must not report a decision at all.
        before = self.open_pr({"src/app.py": "two\n"})
        after = self.commit("edit", {"src/app.py": "three\n"})
        self.run_step(
            before=before,
            after=after,
            edit_ok=False,
            labels_after=[APPROVE_LABEL, "bug"],
            expect_exit=1,
        )

    def test_a_removal_of_an_already_absent_label_succeeds(self):
        # Now that the job runs on unapproved synchronizes too, `gh pr edit`
        # refusing to remove a label that is not there is the ordinary case.
        # What decides is the state afterwards, not that one call's status.
        before = self.open_pr({"src/app.py": "two\n"})
        after = self.commit("edit", {"src/app.py": "three\n"})
        self.assert_stripped(
            before=before,
            after=after,
            edit_ok=False,
            labels_after=["bug"],
        )

    def test_labels_that_cannot_be_read_back_fail_the_job(self):
        before = self.open_pr({"src/app.py": "two\n"})
        after = self.commit("edit", {"src/app.py": "three\n"})
        self.run_step(
            before=before,
            after=after,
            labels_readable=False,
            expect_exit=1,
        )

    def test_a_lookalike_label_does_not_pass_for_the_approval(self):
        # `grep -qx`, not a substring match: `reviewed:approved` is a
        # different label and must not read as the one that had to go.
        before = self.open_pr({"src/app.py": "two\n"})
        after = self.commit("edit", {"src/app.py": "three\n"})
        self.assert_stripped(
            before=before,
            after=after,
            labels_after=["reviewed:approved", "not-reviewed:approve"],
        )


if __name__ == "__main__":
    unittest.main()
