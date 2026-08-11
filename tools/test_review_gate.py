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

    Each case builds the push it describes for real -- commits, a `before`, an
    `after` -- and asserts on whether the script called `gh pr edit
    --remove-label`, which is the whole of its externally visible behavior.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "checkout"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "master")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")
        self.fake = fake_cli.FakeCli(self.root / "fake")
        self.fake.install("gh")
        self.script = last_run_script("dismiss-stale-approval")

    # -- the repository the job runs in -----------------------------------

    def git(self, *args):
        proc = subprocess.run(
            ["git", *args], cwd=str(self.repo), text=True, capture_output=True
        )
        if proc.returncode != 0:  # pragma: no cover - a broken fixture
            raise RuntimeError(f"git {args} failed:\n{proc.stdout}\n{proc.stderr}")
        return proc.stdout.strip()

    def commit(self, message, **files):
        for name, contents in files.items():
            path = self.repo / name.replace("__", "/")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents, encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    # -- running the job's step -------------------------------------------

    def run_step(self, *, before, after, pr_files="README.md\n", pr_files_ok=True):
        """Run the extracted script for one push; report whether it stripped."""
        self.fake.script(
            "gh",
            ["pr", "diff", "7"],
            stdout=pr_files,
            exit_code=0 if pr_files_ok else 1,
        )
        self.fake.script("gh", ["pr", "edit", "7"], stdout="")
        env = dict(os.environ)
        env.update(self.fake.environ_overrides())
        env.update(
            {
                "GH_TOKEN": "fake-token",
                "BEFORE": before,
                "AFTER": after,
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
        self.assertEqual(proc.returncode, 0, proc.stderr)
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

    def assert_kept(self, **kwargs):
        stripped, output = self.run_step(**kwargs)
        self.assertFalse(stripped, f"expected the label kept; job said:\n{output}")

    # -- the one case that keeps approval ---------------------------------

    def test_a_push_touching_no_pr_owned_file_keeps_the_approval(self):
        # The base-branch update merged forward: the delta is real, and none
        # of it is content this pull request owns.
        before = self.commit("base", **{"docs__guide.md": "one\n"})
        after = self.commit("advance", **{"docs__guide.md": "two\n"})
        self.assert_kept(before=before, after=after, pr_files="src/app.py\n")

    # -- everything it cannot prove content-free ---------------------------

    def test_a_push_touching_a_pr_owned_file_removes_the_approval(self):
        before = self.commit("base", **{"src__app.py": "one\n"})
        after = self.commit("edit", **{"src__app.py": "two\n"})
        self.assert_stripped(before=before, after=after, pr_files="src/app.py\n")

    def test_a_partial_overlap_removes_the_approval(self):
        # One reviewed file among untouched ones is still reviewed content
        # that changed.
        before = self.commit(
            "base", **{"src__app.py": "one\n", "docs__guide.md": "one\n"}
        )
        after = self.commit(
            "edit", **{"src__app.py": "two\n", "docs__guide.md": "two\n"}
        )
        self.assert_stripped(
            before=before, after=after, pr_files="src/app.py\nREADME.md\n"
        )

    def test_an_empty_before_sha_removes_the_approval(self):
        after = self.commit("only", **{"docs__guide.md": "one\n"})
        self.assert_stripped(before="", after=after, pr_files="src/app.py\n")

    def test_an_all_zero_before_sha_removes_the_approval(self):
        after = self.commit("only", **{"docs__guide.md": "one\n"})
        self.assert_stripped(before=ZERO_SHA, after=after, pr_files="src/app.py\n")

    def test_an_unreachable_before_sha_removes_the_approval(self):
        # What a force-push looks like from here: the replaced commit is gone,
        # so nothing can prove the new head is content-free.
        after = self.commit("only", **{"docs__guide.md": "one\n"})
        self.assert_stripped(before="b" * 40, after=after, pr_files="src/app.py\n")

    def test_an_empty_after_sha_removes_the_approval(self):
        before = self.commit("base", **{"docs__guide.md": "one\n"})
        self.assert_stripped(before=before, after="", pr_files="src/app.py\n")

    def test_an_all_zero_after_sha_removes_the_approval(self):
        before = self.commit("base", **{"docs__guide.md": "one\n"})
        self.assert_stripped(before=before, after=ZERO_SHA, pr_files="src/app.py\n")

    def test_an_unreachable_after_sha_removes_the_approval(self):
        before = self.commit("base", **{"docs__guide.md": "one\n"})
        self.assert_stripped(before=before, after="b" * 40, pr_files="src/app.py\n")

    def test_a_push_with_no_file_delta_removes_the_approval(self):
        # Nothing to compare against the PR's files, so non-overlap would be
        # unobserved rather than proven.
        before = self.commit("base", **{"docs__guide.md": "one\n"})
        after = self.commit("empty")
        self.assert_stripped(before=before, after=after, pr_files="src/app.py\n")

    def test_an_unreadable_pr_file_list_removes_the_approval(self):
        before = self.commit("base", **{"docs__guide.md": "one\n"})
        after = self.commit("advance", **{"docs__guide.md": "two\n"})
        self.assert_stripped(before=before, after=after, pr_files="", pr_files_ok=False)

    def test_an_empty_pr_file_list_removes_the_approval(self):
        # A readable list of no files answers nothing: `comm` reports no
        # overlap against an empty set no matter what the push contained.
        before = self.commit("base", **{"docs__guide.md": "one\n"})
        after = self.commit("advance", **{"docs__guide.md": "two\n"})
        self.assert_stripped(before=before, after=after, pr_files="")

    def test_a_gh_failure_during_the_strip_does_not_fail_the_job(self):
        # A job that dies mid-strip reports failure, and a failed check is one
        # more thing the drainer must not read as a verdict. Now that the job
        # runs on unapproved synchronizes too, removing a label that is
        # already off is the ordinary case rather than the odd one.
        before = self.commit("base", **{"src__app.py": "one\n"})
        after = self.commit("edit", **{"src__app.py": "two\n"})
        self.fake.script("gh", ["pr", "diff", "7"], stdout="src/app.py\n")
        self.fake.script("gh", ["pr", "edit", "7"], stdout="", exit_code=1)
        env = dict(os.environ)
        env.update(self.fake.environ_overrides())
        env.update(
            {
                "GH_TOKEN": "fake-token",
                "BEFORE": before,
                "AFTER": after,
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
        self.assertEqual(proc.returncode, 0, proc.stderr)


if __name__ == "__main__":
    unittest.main()
