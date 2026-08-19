"""Tests for `.github/workflows/ci.yml`.

`ci.yml` runs its Haskell work and its `tools/` work as independent jobs so
they overlap, and keeps one job named `build-test` as the aggregate that other
systems require: `master`'s branch protection, `tools/drain_prs.py`'s single
`required_ci_check`, and the release gate in `docs/design.md` all name exactly
that context and none of them can take a second one.

That makes two properties load-bearing, and neither is readable off the YAML:

* the aggregate has to *fail* -- not skip, which no reader treats as a refusal
  -- for every dependency result that is not `success`; and
* a job added to this workflow later has to be gated by it, which a list of
  job names written into a test could not enforce, since the next job is added
  without editing the list.

So the first is executed rather than inspected -- the aggregate's own `run:`
script is extracted and run against synthesized `needs` contexts, once per
result it must refuse -- and the second is computed from the parsed workflow.
The same treatment covers the packaging gate: `tools/test_source_distribution.py`
skips when `cabal` is absent, so the Haskell job's step wraps it in a guard
that turns a skip back into a failure, and that guard is run here against a
scripted `python3` rather than read.

`tools/test_release_workflow.py` does the same for `release.yml` and carries
its own copy of this indentation walker. The two stay separate deliberately:
each is bound to the layout and the questions of one workflow, and a shared
parser would make a change to either file's tests a change to both workflows'
contracts.

The extractor is dependency-free -- CI runs this suite with the runner's bare
`python3`, which has no YAML library -- so it walks the workflow by
indentation.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 -m unittest tools.test_ci_workflow
"""

import json
import os
import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "ci.yml"

AGGREGATE_JOB = "build-test"
AGGREGATE_STEP = "Require every other job to have succeeded"
HASKELL_JOB = "haskell"
PYTHON_JOB = "python"
SYSTEMD_JOB = "systemd-drainer-lifecycle"
SDIST_STEP = "Source distribution"

# Every dependency result GitHub can report that is not a success. The
# aggregate has to refuse each one; `skipped` is the case that matters most,
# because it is what a dependency failure actually produces.
REFUSED_RESULTS = ("failure", "cancelled", "skipped")

# What makes a step a build or test step, for the rule that the aggregate runs
# none of its own.
BUILD_TEST_COMMANDS = ("cabal", "unittest", "docker")

# What the toolchain-free job must not acquire.
HASKELL_TOOLING = (
    "cabal",
    "haskell-actions/setup",
    "ghc",
    "~/.cabal/store",
    "dist-newstyle",
)


def setUpModule():
    # `tools/` ships whole in the source distribution and `.github/workflows/`
    # deliberately does not, so an unpacked release runs this module with
    # nothing to read. That is the packaged state, not a failure.
    if not WORKFLOW.is_file():
        raise unittest.SkipTest(f"{WORKFLOW} is absent (not a Git checkout)")


# -- reading the workflow -------------------------------------------------


def workflow_lines():
    return WORKFLOW.read_text(encoding="utf-8").splitlines()


def top_level_block(name):
    """The lines of a top-level mapping, header excluded."""
    lines = workflow_lines()
    try:
        start = lines.index(f"{name}:")
    except ValueError as error:  # pragma: no cover - a renamed key
        raise AssertionError(f"{WORKFLOW} has no top-level {name}:") from error
    body = []
    for line in lines[start + 1 :]:
        if line.strip() and not line.startswith(" "):
            break
        body.append(line)
    return body


def job_names():
    """Every job key, skipping the comments between them."""
    names = []
    for line in top_level_block("jobs"):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if line.startswith("  ") and not line.startswith("   ") and stripped.endswith(":"):
            names.append(stripped[:-1])
    return names


def job_lines(name):
    """The workflow lines belonging to one top-level job, header excluded."""
    lines = workflow_lines()
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


def job_directives(name):
    """One job's lines with its comments dropped, as a single string.

    Comment prose legitimately names what a job does *not* do, so the rules
    about what a job may contain are read against its directives alone.
    """
    return "\n".join(
        line for line in job_lines(name) if not line.strip().startswith("#")
    )


def job_field(name, field):
    """A scalar field declared directly on the job, or None."""
    for line in job_lines(name):
        if line.startswith(f"    {field}:") and not line.startswith(f"     {field}:"):
            return line.split(":", 1)[1].strip()
    return None


def job_needs(name):
    """The jobs one job declares as dependencies, inline or block style."""
    body = job_lines(name)
    for index, line in enumerate(body):
        if not line.startswith("    needs:"):
            continue
        value = line.split(":", 1)[1].strip()
        if value.startswith("["):
            if not value.endswith("]"):  # pragma: no cover - a wrapped list
                raise AssertionError(f"job {name} has an unreadable needs: {value!r}")
            return [entry.strip() for entry in value[1:-1].split(",") if entry.strip()]
        if value:
            return [value]
        collected = []
        for entry in body[index + 1 :]:
            if not entry.strip():
                continue
            if not entry.startswith("      - "):
                break
            collected.append(entry.strip()[2:].strip())
        return collected
    return []


def step_lines(job, step_name):
    """The workflow lines belonging to one named step of a job."""
    body = job_lines(job)
    marker = f"- name: {step_name}"
    start = None
    for index, line in enumerate(body):
        if line.strip() == marker:
            start = index
            break
    if start is None:  # pragma: no cover - a renamed step
        raise AssertionError(f"job {job} has no step named {step_name!r}")
    indent = len(body[start]) - len(body[start].lstrip())
    collected = [body[start]]
    for line in body[start + 1 :]:
        if line.strip().startswith("- ") and len(line) - len(line.lstrip()) == indent:
            break
        collected.append(line)
    return collected


def step_run_script(job, step_name):
    """A named step's `run: |` block, dedented to a runnable script."""
    lines = step_lines(job, step_name)
    starts = [index for index, line in enumerate(lines) if line.strip() == "run: |"]
    if not starts:  # pragma: no cover - a rewritten step
        raise AssertionError(f"step {step_name!r} has no block `run:`")
    start = starts[-1]
    indent = len(lines[start]) - len(lines[start].lstrip()) + 2
    script = []
    for line in lines[start + 1 :]:
        if line.strip() and not line.startswith(" " * indent):
            break
        script.append(line[indent:] if line.strip() else "")
    return "\n".join(script) + "\n"


def run_script(script, env, *, extra_path=None):
    """Run an extracted step script the way the runner would."""
    full = dict(os.environ)
    full.update(env)
    if extra_path is not None:
        full["PATH"] = f"{extra_path}{os.pathsep}{full['PATH']}"
    return subprocess.run(
        ["bash", "-e", "-c", script],
        env=full,
        text=True,
        capture_output=True,
        stdin=subprocess.DEVNULL,
    )


# -- the shape of the split ------------------------------------------------


class CiWorkflowShapeTests(unittest.TestCase):
    def test_the_two_suites_run_as_jobs_that_do_not_wait_on_each_other(self):
        # The whole point of the split: neither suite may sit behind the
        # other, so only the aggregate is allowed to depend on anything.
        for name in job_names():
            if name == AGGREGATE_JOB:
                continue
            self.assertEqual(
                job_needs(name),
                [],
                f"job {name} waits on another job, so nothing overlaps",
            )

    def test_the_aggregate_gates_every_other_job_in_the_workflow(self):
        # Computed from the workflow, not compared against a fixed list: a job
        # added later is added without editing this test, and has to be named
        # in `needs` or fail here.
        others = [name for name in job_names() if name != AGGREGATE_JOB]
        self.assertIn(AGGREGATE_JOB, job_names())
        self.assertEqual(sorted(job_needs(AGGREGATE_JOB)), sorted(others))
        # A workflow of one job would satisfy the equality above vacuously.
        self.assertIn(SYSTEMD_JOB, others)
        self.assertIn(HASKELL_JOB, others)
        self.assertIn(PYTHON_JOB, others)

    def test_the_aggregate_runs_whatever_its_dependencies_did(self):
        self.assertEqual(job_field(AGGREGATE_JOB, "if"), "always()")

    def test_the_aggregate_runs_no_build_or_test_step_of_its_own(self):
        directives = job_directives(AGGREGATE_JOB)
        for command in BUILD_TEST_COMMANDS:
            self.assertNotIn(
                command,
                directives,
                f"the aggregate runs {command!r}, which belongs in a gated job",
            )

    def test_the_aggregate_reads_its_dependencies_rather_than_listing_them(self):
        # A job name written into the guard would be a second list to keep in
        # step with `needs:`, and the guard would still pass with it stale.
        script = step_run_script(AGGREGATE_JOB, AGGREGATE_STEP)
        for name in job_needs(AGGREGATE_JOB):
            # A word boundary, so a job named `python` is not read out of the
            # guard's own `python3`.
            self.assertIsNone(
                re.search(rf"\b{re.escape(name)}\b", script),
                f"the guard names {name} instead of iterating its dependencies",
            )
        self.assertIn("toJSON(needs)", "\n".join(step_lines(AGGREGATE_JOB, AGGREGATE_STEP)))

    def test_the_python_job_installs_no_haskell_toolchain(self):
        directives = job_directives(PYTHON_JOB)
        for fragment in HASKELL_TOOLING:
            self.assertNotIn(
                fragment,
                directives,
                f"job {PYTHON_JOB} acquires {fragment!r}, which it does not use",
            )

    def test_the_python_job_runs_the_whole_tools_suite(self):
        self.assertIn(
            "python3 -m unittest discover -s tools -p 'test_*.py'",
            job_directives(PYTHON_JOB),
        )

    def test_the_python_job_checks_out_the_history_the_bundle_gate_needs(self):
        # tools/plugin_bundle_gate.py resolves a default-branch baseline and
        # fails rather than skipping without one.
        self.assertIn("fetch-depth: 0", job_directives(PYTHON_JOB))

    def test_the_packaging_gate_runs_where_cabal_is_installed(self):
        # tools/test_source_distribution.py runs `cabal sdist all`. Scanning
        # the toolchain-free job for the word `cabal` would not see it: it
        # reaches Cabal through a subprocess, from a module the whole-suite
        # discovery collects by name.
        directives = job_directives(HASKELL_JOB)
        self.assertIn("tools.test_source_distribution", directives)
        self.assertIn("haskell-actions/setup", directives)
        self.assertIn('cabal-version: "3.16.1.0"', directives)


# -- the aggregate's own decision, executed --------------------------------


class AggregateGuardTests(unittest.TestCase):
    """The guard script run against synthesized `needs` contexts."""

    def guard(self, results, *, expect_exit):
        script = step_run_script(AGGREGATE_JOB, AGGREGATE_STEP)
        needs = {job: {"result": result} for job, result in results.items()}
        proc = run_script(script, {"NEEDS": json.dumps(needs)})
        self.assertEqual(
            proc.returncode,
            expect_exit,
            f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}",
        )
        return proc.stdout + proc.stderr

    def all_succeeding(self):
        return {job: "success" for job in job_needs(AGGREGATE_JOB)}

    def test_every_dependency_succeeding_is_the_only_way_through(self):
        output = self.guard(self.all_succeeding(), expect_exit=0)
        self.assertIn("Every job in this workflow succeeded", output)

    def test_any_dependency_result_that_is_not_success_refuses(self):
        for job in job_needs(AGGREGATE_JOB):
            for result in REFUSED_RESULTS:
                with self.subTest(job=job, result=result):
                    results = self.all_succeeding()
                    results[job] = result
                    output = self.guard(results, expect_exit=1)
                    self.assertIn(f"{job} reported {result}", output)

    def test_the_systemd_lifecycle_job_is_gated_like_the_rest(self):
        # It predates the split and depends on nothing, so it is exactly the
        # job an aggregate built only around the two suites would miss.
        self.assertIn(SYSTEMD_JOB, job_needs(AGGREGATE_JOB))
        for result in REFUSED_RESULTS:
            with self.subTest(result=result):
                results = self.all_succeeding()
                results[SYSTEMD_JOB] = result
                self.guard(results, expect_exit=1)

    def test_several_failures_are_all_reported(self):
        results = self.all_succeeding()
        results[HASKELL_JOB] = "failure"
        results[PYTHON_JOB] = "cancelled"
        output = self.guard(results, expect_exit=1)
        self.assertIn(f"{HASKELL_JOB} reported failure", output)
        self.assertIn(f"{PYTHON_JOB} reported cancelled", output)

    def test_a_missing_result_is_refused_rather_than_read_as_success(self):
        script = step_run_script(AGGREGATE_JOB, AGGREGATE_STEP)
        needs = {job: {} for job in job_needs(AGGREGATE_JOB)}
        proc = run_script(script, {"NEEDS": json.dumps(needs)})
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)

    def test_depending_on_nothing_refuses_instead_of_passing_vacuously(self):
        output = self.guard({}, expect_exit=1)
        self.assertIn("gates nothing", output)


# -- the packaging gate's skip guard, executed -----------------------------


class PackagingGateStepTests(unittest.TestCase):
    """The Haskell job's source-distribution step, against a scripted python3."""

    def sdist_step(self, *, stdout, exit_code, expect_exit):
        root = tempfile.TemporaryDirectory(prefix="kanban-ci-step-")
        self.addCleanup(root.cleanup)
        bindir = Path(root.name) / "bin"
        bindir.mkdir()
        stub = bindir / "python3"
        stub.write_text(
            "#!/bin/bash\n"
            f"cat <<'REPORT'\n{stdout}\nREPORT\n"
            f"exit {exit_code}\n",
            encoding="utf-8",
        )
        stub.chmod(stub.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        proc = run_script(
            step_run_script(HASKELL_JOB, SDIST_STEP), {}, extra_path=str(bindir)
        )
        self.assertEqual(
            proc.returncode,
            expect_exit,
            f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}",
        )
        return proc.stdout + proc.stderr

    def test_a_clean_run_passes(self):
        output = self.sdist_step(
            stdout="Ran 12 tests in 30.000s\n\nOK", exit_code=0, expect_exit=0
        )
        self.assertIn("Ran 12 tests", output)

    def test_a_skipped_run_fails_rather_than_reporting_a_pass(self):
        # This is the whole reason the step is more than the command: unittest
        # exits 0 for a skip, and without the toolchain the packaging gate
        # skips.
        output = self.sdist_step(
            stdout="Ran 12 tests in 0.100s\n\nOK (skipped=12)",
            exit_code=0,
            expect_exit=1,
        )
        self.assertIn("skipped", output)

    def test_collecting_nothing_fails(self):
        self.sdist_step(
            stdout="Ran 0 tests in 0.000s\n\nOK", exit_code=0, expect_exit=1
        )

    def test_a_failing_run_still_fails(self):
        output = self.sdist_step(
            stdout="Ran 12 tests in 30.000s\n\nFAILED (failures=1)",
            exit_code=1,
            expect_exit=1,
        )
        self.assertIn("FAILED (failures=1)", output)


if __name__ == "__main__":  # pragma: no cover - convenience
    unittest.main()
