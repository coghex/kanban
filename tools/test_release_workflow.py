"""Tests for `.github/workflows/release.yml`.

A release workflow's safety properties are all negative -- what it must refuse
to do -- and a negative property read off a YAML file is not evidence. So the
properties are executed here rather than inspected: each job's `run:` script is
extracted from the workflow and run under bash against a real temporary Git
repository with a scriptable fake `gh` on PATH, once per case it has to fail
closed on.

What that covers, in the order the workflow would meet it:

* a `v*` tag that does not name the version in `kanban.cabal` cannot reach
  publication, and the version it is compared against comes from the
  `version:` field rather than from `cabal-version:`;
* the dry-run path refuses an empty, production-style, misprefixed, or
  already-used tag input;
* the release notes are the first `CHANGELOG.md` release section alone;
* the production publisher refuses a tag the remote does not already carry, so
  it cannot stand in for the authorization that creates one; and
* the asset checks are re-run in the job that actually attaches the asset.

Two properties are structural rather than executable and are asserted against
the workflow text: no job that builds or tests may hold `contents: write`, and
each publication job gates on the complete build-and-test job.

The extractor is deliberately dependency-free -- CI runs this suite with the
runner's bare `python3` -- so it walks the workflow by indentation instead of
loading YAML.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
"""

import hashlib
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import fake_cli


REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "release.yml"

BUILD_JOB = "build-test"
GATE_STEP = "Derive the version and validate the tag and changelog"
SDIST_STEP = "Build and verify the source distribution"
PUBLISH_JOB = "publish-release"
PUBLISH_STEP = "Publish the release"
DRY_RUN_JOB = "publish-dry-run"
DRY_RUN_STEP = "Create the draft dry-run release"

# What makes a job a build-or-test job for the permission rule below.
BUILD_TEST_COMMANDS = (
    "cabal check",
    "cabal build all",
    "cabal test all",
    "unittest discover",
)

VERSION = "1.0.0.0"

CABAL_FILE = """cabal-version:      3.0
name:               kanban
version:            1.0.0.0
synopsis:           A terminal board for a GitHub repository
"""

CHANGELOG = """# Changelog

Releases appear newest first. Each release is a `##` heading whose text is
exactly that release's package version.

## 1.0.0.0

Kanban's first release.

### The board

- Four columns.

## 0.9.0.0

An older release whose notes must not be published with the newer one.
"""

# Exactly the first release section: no document title, no boundary-rule
# prose, nothing from the release below it, and no bracketing blank lines.
EXPECTED_NOTES = """Kanban's first release.

### The board

- Four columns.
"""


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


def job_field(name, field):
    """A scalar field declared directly on the job, or None."""
    for line in job_lines(name):
        if line.startswith(f"    {field}:") and not line.startswith(f"     {field}:"):
            return line.split(":", 1)[1].strip()
    return None


def job_permissions(name):
    """The job's `permissions:` grants as a dict, or None when it has none."""
    body = job_lines(name)
    for index, line in enumerate(body):
        if line.strip() != "permissions:":
            continue
        if not line.startswith("    ") or line.startswith("     "):
            continue
        grants = {}
        for entry in body[index + 1 :]:
            if entry.strip() and not entry.startswith("      "):
                break
            if entry.strip():
                scope, _, value = entry.strip().partition(":")
                grants[scope.strip()] = value.strip()
        return grants
    return None


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
        if (
            line.strip().startswith("- ")
            and len(line) - len(line.lstrip()) == indent
        ):
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


# -- the workflow's shape, before any of its shell runs -------------------


class ReleaseWorkflowShapeTests(unittest.TestCase):
    def test_the_workflow_defaults_to_read_only_permissions(self):
        self.assertIn("  contents: read", top_level_block("permissions"))

    def test_no_job_that_builds_or_tests_can_write_repository_contents(self):
        # The permission split is the whole reason the build and the
        # publication are separate jobs: whatever runs the repository's own
        # code must not be able to write to the repository while it runs.
        builders = []
        for name in job_names():
            body = "\n".join(job_lines(name))
            if not any(command in body for command in BUILD_TEST_COMMANDS):
                continue
            builders.append(name)
            grants = job_permissions(name)
            self.assertIsNotNone(grants, f"job {name} builds or tests without a permissions: block")
            self.assertEqual(
                grants.get("contents"),
                "read",
                f"job {name} builds or tests and must hold contents: read",
            )
        # A detector that matched nothing would pass the loop above vacuously.
        self.assertEqual(builders, [BUILD_JOB])

    def test_only_the_publication_jobs_may_write_and_they_run_no_build_or_test(self):
        writers = sorted(
            name
            for name in job_names()
            if (job_permissions(name) or {}).get("contents") == "write"
        )
        self.assertEqual(writers, sorted([DRY_RUN_JOB, PUBLISH_JOB]))
        for name in writers:
            body = "\n".join(job_lines(name))
            for command in BUILD_TEST_COMMANDS:
                self.assertNotIn(
                    command,
                    body,
                    f"writable job {name} runs {command!r}, which belongs in {BUILD_JOB}",
                )

    def test_each_publication_job_gates_on_the_complete_build_and_test_job(self):
        for name in (PUBLISH_JOB, DRY_RUN_JOB):
            self.assertEqual(
                job_field(name, "needs"),
                BUILD_JOB,
                f"job {name} must not run unless {BUILD_JOB} succeeded whole",
            )

    def test_the_publication_jobs_are_split_by_event(self):
        # Neither publisher may run on the other's event: the production path
        # is reachable only by a tag push, the draft path only by dispatch.
        self.assertEqual(job_field(PUBLISH_JOB, "if"), "github.event_name == 'push'")
        self.assertEqual(
            job_field(DRY_RUN_JOB, "if"), "github.event_name == 'workflow_dispatch'"
        )

    def test_only_v_tags_and_dispatch_can_start_the_workflow(self):
        triggers = "\n".join(top_level_block("on"))
        self.assertIn("push:", triggers)
        self.assertIn("tags:", triggers)
        self.assertIn('- "v*"', triggers)
        self.assertIn("workflow_dispatch:", triggers)
        self.assertIn("dry_run_tag:", triggers)
        self.assertIn("required: true", triggers)
        # A branch push must not reach a publisher.
        self.assertNotIn("branches:", triggers)

    def test_concurrency_serializes_publishers_without_cancelling_one_in_flight(self):
        block = top_level_block("concurrency")
        text = "\n".join(block)
        self.assertIn("cancel-in-progress: false", text)
        group = next(line for line in block if line.strip().startswith("group:"))
        # GitHub evaluates the group before any job runs, so a reference to a
        # job output or a step output would silently resolve to nothing.
        for context in ("needs.", "steps.", "jobs.", "env."):
            self.assertNotIn(context, group)
        self.assertIn("github.", group)

    def test_the_build_job_reuses_ci_s_toolchain_and_gates(self):
        # The versions themselves, and that this job installs, caches, and
        # verifies them exactly as ci.yml's Haskell job does, are held
        # between the two workflows by tools/test_toolchain_parity.py --
        # a comparison neither workflow read alone can make.
        body = "\n".join(job_lines(BUILD_JOB))
        for fragment in (
            "runs-on: ubuntu-latest",
            "fetch-depth: 0",
            "ghc-version: ${{ env.GHC_VERSION }}",
            "cabal-version: ${{ env.CABAL_VERSION }}",
            "run: cabal check",
            "run: cabal update",
            "run: cabal build all",
            "run: cabal test all --test-show-details=direct",
            "run: python3 -m unittest discover -s tools -p 'test_*.py'",
        ):
            self.assertIn(fragment, body)

    def test_the_production_publisher_never_creates_its_own_tag(self):
        # #268 REL-4 owns the act of tagging. `--verify-tag` is what makes gh
        # itself refuse, independent of the job's own remote check.
        self.assertIn("--verify-tag", step_run_script(PUBLISH_JOB, PUBLISH_STEP))

    def test_the_dry_run_publisher_can_only_draft(self):
        script = step_run_script(DRY_RUN_JOB, DRY_RUN_STEP)
        self.assertIn("--draft", script)
        self.assertIn("--latest=false", script)
        self.assertNotIn("--verify-tag", script)

    def test_github_is_the_only_distribution_channel(self):
        # Comments are stripped first: the header prose names the channels
        # this workflow deliberately does not publish to, and saying so must
        # not read as doing so.
        instructions = "\n".join(
            line
            for line in workflow_lines()
            if not line.strip().startswith("#")
        ).lower()
        for channel in ("hackage", "homebrew", "cabal upload", "pypi", "docker"):
            self.assertNotIn(channel, instructions)
        # The one publishing command, and no second one.
        self.assertEqual(instructions.count("gh release create"), 2)


# -- the extracted scripts, executed --------------------------------------


class ReleaseScriptTestCase(unittest.TestCase):
    """A temporary checkout with a real `origin` and a scriptable fake `gh`."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.remote = self.root / "remote.git"
        subprocess.run(
            ["git", "init", "-q", "--bare", "-b", "master", str(self.remote)],
            check=True,
            capture_output=True,
        )
        self.repo = self.root / "checkout"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "master")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")
        self.git("remote", "add", "origin", str(self.remote))
        self.write("kanban.cabal", CABAL_FILE)
        self.write("CHANGELOG.md", CHANGELOG)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "fixture")
        self.git("push", "-q", "origin", "master")
        self.commit = self.git("rev-parse", "HEAD")
        self.fake = fake_cli.FakeCli(self.root / "fake")
        self.fake.install("gh")
        self.output_file = self.root / "github-output"
        self.output_file.write_text("", encoding="utf-8")
        self.summary_file = self.root / "github-summary"
        self.summary_file.write_text("", encoding="utf-8")

    def git(self, *args):
        proc = subprocess.run(
            ["git", *args], cwd=str(self.repo), text=True, capture_output=True
        )
        if proc.returncode != 0:  # pragma: no cover - a broken fixture
            raise RuntimeError(f"git {args} failed:\n{proc.stdout}\n{proc.stderr}")
        return proc.stdout.strip()

    def write(self, name, contents):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
        return path

    def push_tag(self, tag):
        self.git("tag", tag)
        self.git("push", "-q", "origin", tag)

    def script_release_view(self, *, exists):
        self.fake.script(
            "gh", ["release", "view"], stdout="", exit_code=0 if exists else 1
        )

    def run_script(self, script, env, *, expect_exit):
        full = dict(os.environ)
        full.update(self.fake.environ_overrides())
        full.update(
            {
                "GH_TOKEN": "fake-token",
                "REPO": "acme/widgets",
                "GITHUB_OUTPUT": str(self.output_file),
                "GITHUB_STEP_SUMMARY": str(self.summary_file),
            }
        )
        full.update(env)
        proc = subprocess.run(
            ["bash", "-c", script],
            cwd=str(self.repo),
            env=full,
            text=True,
            capture_output=True,
            stdin=subprocess.DEVNULL,
        )
        self.assertEqual(
            proc.returncode,
            expect_exit,
            f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}",
        )
        return proc.stdout + proc.stderr

    def outputs(self):
        parsed = {}
        for line in self.output_file.read_text(encoding="utf-8").splitlines():
            if "=" in line:
                key, _, value = line.partition("=")
                parsed[key] = value
        return parsed

    def release_creations(self):
        return [
            call
            for call in self.fake.calls("gh")
            if call["args"][:2] == ["release", "create"]
        ]

    def record_digest(self, digest_file, archive, notes):
        """The digest the build job would have recorded for this payload."""
        lines = []
        for path, label in ((archive, "archive"), (notes, "notes")):
            digest = hashlib.sha256(Path(path).read_bytes()).hexdigest()
            lines.append(f"{digest}  {label}")
        Path(digest_file).write_text("\n".join(lines) + "\n", encoding="utf-8")

    def assert_nothing_was_created(self):
        self.assertEqual(
            self.release_creations(), [], "the script reached `gh release create`"
        )


class VersionDerivationTests(ReleaseScriptTestCase):
    """Requirement 4's version, taken from the field that declares it."""

    def gate(self, *, expect_exit=0, event="push", push_tag=f"v{VERSION}", dry_run_tag=""):
        return self.run_script(
            step_run_script(BUILD_JOB, GATE_STEP),
            {
                "EVENT_NAME": event,
                "PUSH_TAG": push_tag,
                "DRY_RUN_TAG": dry_run_tag,
                "NOTES_FILE": str(self.root / "payload" / "release-notes.md"),
            },
            expect_exit=expect_exit,
        )

    def test_a_tag_naming_the_package_version_passes(self):
        self.gate()
        self.assertEqual(self.outputs(), {"version": VERSION, "tag": f"v{VERSION}"})

    def test_the_version_is_not_read_from_the_cabal_version_field(self):
        # The trap this anchoring exists for: `cabal-version: 3.0` is also a
        # dotted numeric field, so a loose match would derive "3.0" and accept
        # a `v3.0` tag as naming the package version.
        output = self.gate(push_tag="v3.0", expect_exit=1)
        self.assertIn("expected 'v1.0.0.0'", output)

    def test_a_cabal_file_declaring_no_version_field_fails(self):
        self.write("kanban.cabal", "cabal-version:      3.0\nname:               kanban\n")
        output = self.gate(expect_exit=1)
        self.assertIn("exactly one line-anchored 'version:' field (found 0)", output)

    def test_a_cabal_file_declaring_two_version_fields_fails(self):
        self.write("kanban.cabal", CABAL_FILE + "version:            2.0.0.0\n")
        output = self.gate(expect_exit=1)
        self.assertIn("exactly one line-anchored 'version:' field (found 2)", output)

    def test_a_version_that_is_not_dotted_numeric_fails(self):
        self.write("kanban.cabal", CABAL_FILE.replace("1.0.0.0", "1.0.0.0-rc1"))
        output = self.gate(push_tag="v1.0.0.0-rc1", expect_exit=1)
        self.assertIn("not a dotted numeric package version", output)


class ProductionTagGateTests(ReleaseScriptTestCase):
    """Requirement 4's tag parity: what a `v*` push may and may not publish."""

    def gate(self, *, push_tag, expect_exit):
        return self.run_script(
            step_run_script(BUILD_JOB, GATE_STEP),
            {
                "EVENT_NAME": "push",
                "PUSH_TAG": push_tag,
                "DRY_RUN_TAG": "",
                "NOTES_FILE": str(self.root / "payload" / "release-notes.md"),
            },
            expect_exit=expect_exit,
        )

    def test_a_mismatched_tag_cannot_reach_publication(self):
        output = self.gate(push_tag="v0.9.0.0", expect_exit=1)
        self.assertIn("does not name the package version", output)
        self.assertEqual(self.outputs(), {})

    def test_a_tag_missing_a_version_component_cannot_reach_publication(self):
        self.gate(push_tag="v1.0.0", expect_exit=1)
        self.assertEqual(self.outputs(), {})

    def test_a_tag_with_a_suffix_cannot_reach_publication(self):
        self.gate(push_tag=f"v{VERSION}-hotfix", expect_exit=1)
        self.assertEqual(self.outputs(), {})

    def test_an_unversioned_tag_cannot_reach_publication(self):
        self.gate(push_tag="release", expect_exit=1)
        self.assertEqual(self.outputs(), {})

    def test_a_push_that_carries_no_tag_cannot_reach_publication(self):
        output = self.gate(push_tag="", expect_exit=1)
        self.assertIn("must come from a tag push", output)


class DryRunTagGateTests(ReleaseScriptTestCase):
    """Requirement 9: what may be dispatched as a rehearsal."""

    def gate(self, *, dry_run_tag, expect_exit, release_exists=False):
        self.script_release_view(exists=release_exists)
        return self.run_script(
            step_run_script(BUILD_JOB, GATE_STEP),
            {
                "EVENT_NAME": "workflow_dispatch",
                "PUSH_TAG": "",
                "DRY_RUN_TAG": dry_run_tag,
                "NOTES_FILE": str(self.root / "payload" / "release-notes.md"),
            },
            expect_exit=expect_exit,
        )

    def test_a_unique_dry_run_tag_passes(self):
        self.gate(dry_run_tag="release-dry-run-20260815", expect_exit=0)
        self.assertEqual(
            self.outputs(), {"version": VERSION, "tag": "release-dry-run-20260815"}
        )

    def test_an_empty_tag_input_is_rejected(self):
        output = self.gate(dry_run_tag="", expect_exit=1)
        self.assertIn("requires a dry_run_tag input", output)

    def test_the_production_release_tag_is_rejected(self):
        output = self.gate(dry_run_tag=f"v{VERSION}", expect_exit=1)
        self.assertIn("is a production release tag", output)

    def test_any_v_prefixed_tag_is_rejected(self):
        output = self.gate(dry_run_tag="v2.0.0.0", expect_exit=1)
        self.assertIn("is a production release tag", output)

    def test_a_tag_without_the_dry_run_prefix_is_rejected(self):
        output = self.gate(dry_run_tag="nightly-20260815", expect_exit=1)
        self.assertIn("must begin with 'release-dry-run-'", output)

    def test_the_bare_prefix_with_nothing_after_it_is_rejected(self):
        # Every dispatch has to name a distinct rehearsal, and the bare prefix
        # is the one string that would collide with itself on every run.
        output = self.gate(dry_run_tag="release-dry-run-", expect_exit=1)
        self.assertIn("must begin with 'release-dry-run-'", output)

    def test_a_tag_that_already_has_a_release_is_rejected(self):
        output = self.gate(
            dry_run_tag="release-dry-run-used", expect_exit=1, release_exists=True
        )
        self.assertIn("already has a release", output)

    def test_a_tag_that_already_exists_on_the_remote_is_rejected(self):
        self.push_tag("release-dry-run-old")
        output = self.gate(dry_run_tag="release-dry-run-old", expect_exit=1)
        self.assertIn("already exists on the remote", output)


class ReleaseNotesTests(ReleaseScriptTestCase):
    """Requirement 6: the notes are one changelog section and nothing else."""

    def setUp(self):
        super().setUp()
        self.notes = self.root / "payload" / "release-notes.md"

    def gate(self, *, expect_exit=0):
        return self.run_script(
            step_run_script(BUILD_JOB, GATE_STEP),
            {
                "EVENT_NAME": "push",
                "PUSH_TAG": f"v{VERSION}",
                "DRY_RUN_TAG": "",
                "NOTES_FILE": str(self.notes),
            },
            expect_exit=expect_exit,
        )

    def test_the_notes_are_exactly_the_first_release_section(self):
        self.gate()
        self.assertEqual(self.notes.read_text(encoding="utf-8"), EXPECTED_NOTES)

    def test_the_notes_exclude_the_title_and_the_policy_prose(self):
        self.gate()
        body = self.notes.read_text(encoding="utf-8")
        self.assertNotIn("# Changelog", body)
        self.assertNotIn("Releases appear newest first", body)

    def test_the_notes_stop_before_the_next_release_heading(self):
        self.gate()
        body = self.notes.read_text(encoding="utf-8")
        self.assertNotIn("0.9.0.0", body)
        self.assertNotIn("must not be published", body)

    def test_a_subsection_heading_does_not_end_the_section(self):
        # `### The board` is a heading inside the release, not the boundary.
        self.gate()
        self.assertIn("### The board", self.notes.read_text(encoding="utf-8"))

    def test_a_changelog_with_no_release_section_fails(self):
        self.write("CHANGELOG.md", "# Changelog\n\nNothing has been released.\n")
        output = self.gate(expect_exit=1)
        self.assertIn("no '## <version>' release section", output)

    def test_a_first_section_naming_another_version_fails(self):
        self.write("CHANGELOG.md", CHANGELOG.replace("## 1.0.0.0", "## 1.1.0.0", 1))
        output = self.gate(expect_exit=1)
        self.assertIn("names '1.1.0.0', not '1.0.0.0'", output)

    def test_a_dated_or_annotated_heading_fails_rather_than_being_trimmed(self):
        self.write(
            "CHANGELOG.md", CHANGELOG.replace("## 1.0.0.0", "## 1.0.0.0 (2026-08-13)", 1)
        )
        output = self.gate(expect_exit=1)
        self.assertIn("not '1.0.0.0'", output)

    def test_an_empty_release_section_fails(self):
        self.write("CHANGELOG.md", "# Changelog\n\n## 1.0.0.0\n\n## 0.9.0.0\n\nOld.\n")
        output = self.gate(expect_exit=1)
        self.assertIn("section is empty", output)


class SdistVerificationTests(ReleaseScriptTestCase):
    """Requirement 5, at the point the archive is built.

    `cabal sdist` is replaced by a fake that drops whatever archives the case
    describes, so the check is exercised against outputs a real run would only
    produce once something had gone wrong.
    """

    def setUp(self):
        super().setUp()
        self.payload = self.root / "payload"
        self.payload.mkdir(parents=True)
        self.notes = self.payload / "release-notes.md"
        self.notes.write_text(EXPECTED_NOTES, encoding="utf-8")
        self.digest_file = self.payload / "payload.sha256"

    def sdist(self, names, *, expect_exit):
        sdist_dir = self.payload / "sdist"
        stub = self.root / "fake" / "bin" / "cabal"
        drops = "\n".join(
            f'  printf archive > "$OUT/{name}"' for name in names
        )
        stub.write_text(
            "#!/bin/bash\n"
            'if [ "$1" = "sdist" ]; then\n'
            '  OUT="${!#}"\n'
            f"{drops}\n"
            "fi\n"
            "exit 0\n",
            encoding="utf-8",
        )
        stub.chmod(0o755)
        return self.run_script(
            step_run_script(BUILD_JOB, SDIST_STEP),
            {
                "VERSION": VERSION,
                "SDIST_DIR": str(sdist_dir),
                "NOTES_FILE": str(self.notes),
                "DIGEST_FILE": str(self.digest_file),
            },
            expect_exit=expect_exit,
        )

    def test_the_verified_payload_is_recorded_as_a_digest(self):
        # What the publishing job later compares against, so a file that
        # changed in transit cannot pass as the one that was verified.
        self.sdist([f"kanban-{VERSION}.tar.gz"], expect_exit=0)
        recorded = self.digest_file.read_text(encoding="utf-8").split()
        archive_digest = hashlib.sha256(b"archive").hexdigest()
        notes_digest = hashlib.sha256(EXPECTED_NOTES.encode()).hexdigest()
        self.assertEqual(
            recorded, [archive_digest, "archive", notes_digest, "notes"]
        )

    def test_the_expected_single_archive_passes(self):
        output = self.sdist([f"kanban-{VERSION}.tar.gz"], expect_exit=0)
        self.assertIn(f"verified release asset: kanban-{VERSION}.tar.gz", output)

    def test_no_archive_fails(self):
        output = self.sdist([], expect_exit=1)
        self.assertIn("expected exactly one sdist archive, found 0", output)

    def test_an_ambiguous_pair_of_archives_fails(self):
        output = self.sdist(
            [f"kanban-{VERSION}.tar.gz", "kanban-extra-0.1.0.0.tar.gz"], expect_exit=1
        )
        self.assertIn("expected exactly one sdist archive, found 2", output)

    def test_an_archive_naming_another_version_fails(self):
        output = self.sdist(["kanban-0.9.0.0.tar.gz"], expect_exit=1)
        self.assertIn("expected 'kanban-1.0.0.0.tar.gz'", output)


class ProductionPublisherTests(ReleaseScriptTestCase):
    """Requirement 7, in the job that holds `contents: write`."""

    def setUp(self):
        super().setUp()
        self.sdist_dir = self.root / "payload" / "sdist"
        self.sdist_dir.mkdir(parents=True)
        self.notes = self.root / "payload" / "release-notes.md"
        self.notes.write_text(EXPECTED_NOTES, encoding="utf-8")
        self.digest_file = self.root / "payload" / "payload.sha256"

    def drop_archive(self, name, contents="archive"):
        (self.sdist_dir / name).write_text(contents, encoding="utf-8")

    def record_payload_digest(self):
        """Stand in for the digest the build job recorded, as things are now."""
        archives = sorted(self.sdist_dir.glob("*.tar.gz"))
        if len(archives) == 1 and self.notes.exists():
            self.record_digest(self.digest_file, archives[0], self.notes)

    def publish(self, *, tag=f"v{VERSION}", expect_exit, release_exists=False, record=True):
        if record:
            self.record_payload_digest()
        self.script_release_view(exists=release_exists)
        self.fake.script("gh", ["release", "create"], stdout="", exit_code=0)
        return self.run_script(
            step_run_script(PUBLISH_JOB, PUBLISH_STEP),
            {
                "VERSION": VERSION,
                "TAG": tag,
                "COMMIT": self.commit,
                "SDIST_DIR": str(self.sdist_dir),
                "NOTES_FILE": str(self.notes),
                "DIGEST_FILE": str(self.digest_file),
            },
            expect_exit=expect_exit,
        )

    def test_a_tag_the_remote_does_not_carry_is_refused(self):
        # The property that keeps #268 REL-4 the sole tagging authority: with
        # no ref on the remote, the publisher stops instead of creating one.
        self.drop_archive(f"kanban-{VERSION}.tar.gz")
        output = self.publish(expect_exit=1)
        self.assertIn("is not on the remote", output)
        self.assert_nothing_was_created()

    def test_a_tag_the_remote_carries_is_published_with_the_verified_asset(self):
        self.push_tag(f"v{VERSION}")
        self.drop_archive(f"kanban-{VERSION}.tar.gz")
        self.publish(expect_exit=0)
        created = self.release_creations()
        self.assertEqual(len(created), 1)
        args = created[0]["args"]
        self.assertEqual(args[2], f"v{VERSION}")
        self.assertIn(str(self.sdist_dir / f"kanban-{VERSION}.tar.gz"), args)
        self.assertIn("--verify-tag", args)
        self.assertIn("--notes-file", args)
        self.assertIn(str(self.notes), args)
        self.assertIn("--target", args)
        self.assertIn(self.commit, args)
        self.assertNotIn("--draft", args)
        self.assertIn(VERSION, self.summary_file.read_text(encoding="utf-8"))

    def test_an_existing_release_is_never_overwritten_or_reused(self):
        self.push_tag(f"v{VERSION}")
        self.drop_archive(f"kanban-{VERSION}.tar.gz")
        output = self.publish(expect_exit=1, release_exists=True)
        self.assertIn("refusing to overwrite or reuse it", output)
        self.assert_nothing_was_created()

    def test_an_asset_lost_in_the_handoff_is_refused(self):
        self.push_tag(f"v{VERSION}")
        output = self.publish(expect_exit=1)
        self.assertIn("found 0", output)
        self.assert_nothing_was_created()

    def test_an_asset_renamed_in_the_handoff_is_refused(self):
        self.push_tag(f"v{VERSION}")
        self.drop_archive("kanban-0.9.0.0.tar.gz")
        output = self.publish(expect_exit=1)
        self.assertIn("payload carries 'kanban-0.9.0.0.tar.gz'", output)
        self.assert_nothing_was_created()

    def test_an_asset_duplicated_in_the_handoff_is_refused(self):
        self.push_tag(f"v{VERSION}")
        self.drop_archive(f"kanban-{VERSION}.tar.gz")
        self.drop_archive("kanban-extra.tar.gz")
        output = self.publish(expect_exit=1)
        self.assertIn("found 2", output)
        self.assert_nothing_was_created()

    def test_an_asset_emptied_in_the_handoff_is_refused(self):
        self.push_tag(f"v{VERSION}")
        self.drop_archive(f"kanban-{VERSION}.tar.gz", contents="")
        output = self.publish(expect_exit=1)
        self.assertIn("arrived empty", output)
        self.assert_nothing_was_created()

    def test_an_asset_truncated_but_still_non_empty_is_refused(self):
        # The count, name, and size checks all pass here: the archive is
        # present, correctly named, and not empty. Only the digest recorded
        # when it was verified can tell that these are not those bytes.
        self.push_tag(f"v{VERSION}")
        self.drop_archive(f"kanban-{VERSION}.tar.gz", contents="archive")
        self.record_payload_digest()
        self.drop_archive(f"kanban-{VERSION}.tar.gz", contents="archi")
        output = self.publish(expect_exit=1, record=False)
        self.assertIn("does not match the digest", output)
        self.assert_nothing_was_created()

    def test_an_asset_altered_in_the_handoff_is_refused(self):
        self.push_tag(f"v{VERSION}")
        self.drop_archive(f"kanban-{VERSION}.tar.gz", contents="archive")
        self.record_payload_digest()
        self.drop_archive(f"kanban-{VERSION}.tar.gz", contents="tampered!")
        output = self.publish(expect_exit=1, record=False)
        self.assertIn("does not match the digest", output)
        self.assert_nothing_was_created()

    def test_notes_altered_in_the_handoff_are_refused(self):
        self.push_tag(f"v{VERSION}")
        self.drop_archive(f"kanban-{VERSION}.tar.gz")
        self.record_payload_digest()
        self.notes.write_text("Substituted release notes.\n", encoding="utf-8")
        output = self.publish(expect_exit=1, record=False)
        self.assertIn("release notes do not match the digest", output)
        self.assert_nothing_was_created()

    def test_a_payload_carrying_no_digest_is_refused(self):
        self.push_tag(f"v{VERSION}")
        self.drop_archive(f"kanban-{VERSION}.tar.gz")
        output = self.publish(expect_exit=1, record=False)
        self.assertIn("no integrity digest", output)
        self.assert_nothing_was_created()

    def test_a_digest_missing_one_of_the_two_files_is_refused(self):
        self.push_tag(f"v{VERSION}")
        self.drop_archive(f"kanban-{VERSION}.tar.gz")
        digest = hashlib.sha256(b"archive").hexdigest()
        self.digest_file.write_text(f"{digest}  archive\n", encoding="utf-8")
        output = self.publish(expect_exit=1, record=False)
        self.assertIn("does not record both files", output)
        self.assert_nothing_was_created()

    def test_missing_notes_are_refused(self):
        self.push_tag(f"v{VERSION}")
        self.drop_archive(f"kanban-{VERSION}.tar.gz")
        self.notes.unlink()
        output = self.publish(expect_exit=1)
        self.assertIn("release notes are missing or empty", output)
        self.assert_nothing_was_created()

    def test_a_tag_that_stopped_naming_the_version_is_refused(self):
        self.push_tag("v0.9.0.0")
        self.drop_archive(f"kanban-{VERSION}.tar.gz")
        output = self.publish(tag="v0.9.0.0", expect_exit=1)
        self.assertIn("does not name package version", output)
        self.assert_nothing_was_created()


class DryRunPublisherTests(ReleaseScriptTestCase):
    """Requirement 9's draft, in the job that holds `contents: write`."""

    def setUp(self):
        super().setUp()
        self.sdist_dir = self.root / "payload" / "sdist"
        self.sdist_dir.mkdir(parents=True)
        (self.sdist_dir / f"kanban-{VERSION}.tar.gz").write_text(
            "archive", encoding="utf-8"
        )
        self.notes = self.root / "payload" / "release-notes.md"
        self.notes.write_text(EXPECTED_NOTES, encoding="utf-8")
        self.digest_file = self.root / "payload" / "payload.sha256"
        self.archive = self.sdist_dir / f"kanban-{VERSION}.tar.gz"

    def publish(
        self,
        *,
        tag="release-dry-run-20260815",
        expect_exit,
        release_exists=False,
        record=True,
    ):
        if record:
            self.record_digest(self.digest_file, self.archive, self.notes)
        self.script_release_view(exists=release_exists)
        self.fake.script("gh", ["release", "create"], stdout="", exit_code=0)
        return self.run_script(
            step_run_script(DRY_RUN_JOB, DRY_RUN_STEP),
            {
                "VERSION": VERSION,
                "TAG": tag,
                "COMMIT": self.commit,
                "SDIST_DIR": str(self.sdist_dir),
                "NOTES_FILE": str(self.notes),
                "DIGEST_FILE": str(self.digest_file),
            },
            expect_exit=expect_exit,
        )

    def test_an_asset_truncated_but_still_non_empty_is_refused(self):
        # The rehearsal has to fail on exactly what production fails on, or it
        # rehearses something else.
        self.record_digest(self.digest_file, self.archive, self.notes)
        self.archive.write_text("archi", encoding="utf-8")
        output = self.publish(expect_exit=1, record=False)
        self.assertIn("does not match the digest", output)
        self.assert_nothing_was_created()

    def test_a_payload_carrying_no_digest_is_refused(self):
        output = self.publish(expect_exit=1, record=False)
        self.assertIn("no integrity digest", output)
        self.assert_nothing_was_created()

    def test_the_draft_is_created_against_the_commit_and_never_published(self):
        self.publish(expect_exit=0)
        created = self.release_creations()
        self.assertEqual(len(created), 1)
        args = created[0]["args"]
        self.assertEqual(args[2], "release-dry-run-20260815")
        self.assertIn("--draft", args)
        self.assertIn("--latest=false", args)
        self.assertNotIn("--verify-tag", args)
        # A commit SHA, not a branch name: `gh release view --json
        # targetCommitish` echoes back whatever was passed, so `master` would
        # make the acceptance check unverifiable.
        self.assertIn("--target", args)
        self.assertIn(self.commit, args)
        self.assertNotIn("master", args)

    def test_a_production_style_tag_is_refused_even_here(self):
        output = self.publish(tag=f"v{VERSION}", expect_exit=1)
        self.assertIn("is a production release tag", output)
        self.assert_nothing_was_created()

    def test_a_misprefixed_tag_is_refused_even_here(self):
        output = self.publish(tag="nightly-1", expect_exit=1)
        self.assertIn("must begin with 'release-dry-run-'", output)
        self.assert_nothing_was_created()

    def test_a_tag_that_already_has_a_release_is_refused(self):
        output = self.publish(expect_exit=1, release_exists=True)
        self.assertIn("already has a release", output)
        self.assert_nothing_was_created()

    def test_the_summary_identifies_the_draft_and_its_cleanup(self):
        self.publish(expect_exit=0)
        summary = self.summary_file.read_text(encoding="utf-8")
        self.assertIn("release-dry-run-20260815", summary)
        self.assertIn(self.commit, summary)
        self.assertIn(str(self.notes), summary)
        self.assertIn(f"kanban-{VERSION}.tar.gz", summary)
        self.assertIn(
            'gh release delete "release-dry-run-20260815" --repo "acme/widgets" --yes',
            summary,
        )

    def test_the_documented_cleanup_command_does_not_use_cleanup_tag(self):
        # A draft release creates no `refs/tags/<tag>`, so `--cleanup-tag`
        # would delete the release and then fail on the missing ref. The
        # summary may explain that; it must not prescribe it.
        self.publish(expect_exit=0)
        summary = self.summary_file.read_text(encoding="utf-8")
        prescribed = [
            line
            for line in summary.splitlines()
            if re.match(r"\s*gh release delete\b", line)
        ]
        self.assertTrue(prescribed, "the summary prescribes no cleanup command")
        for line in prescribed:
            self.assertNotIn("--cleanup-tag", line)


if __name__ == "__main__":
    unittest.main()
