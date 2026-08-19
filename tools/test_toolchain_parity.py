"""The GHC installation cache, and the toolchain parity it depends on.

Two workflows build this package -- `.github/workflows/ci.yml`'s `haskell` job
and `.github/workflows/release.yml`'s `build-test` job -- and both used to
reinstall the pinned compiler from scratch, about two minutes of every run.
Both now restore it from a cache instead, and that only works if the two
resolve the toolchain the same way: the same setup action, into the same
installation base, cached at the same path under the same key schema, at the
same pins. A release built by a different compiler than CI verified is the
failure this file exists to prevent, and it is invisible in either workflow
read on its own.

So the pins are compared between the two workflows rather than against a
literal here: bumping one alone fails, which is the property that outlives any
particular version. `tools/test_ci_workflow.py` and
`tools/test_release_workflow.py` stay bound to one workflow each and are
deliberately not extended to reach across; this module is the one whose whole
subject is the pair, and it carries its own reader for that reason, parameterized
by path where theirs are not.

What is asserted here is structural. The scripts those steps run are executed
against fakes in `tools/test_ci_workflow.py`; because the parity assertions
below prove the two workflows carry the same script, executing one covers both.

The reader is dependency-free -- CI runs this suite with the runner's bare
`python3`, which has no YAML library -- so it walks each workflow by
indentation.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 -m unittest tools.test_toolchain_parity
"""

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
CI_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "ci.yml"
RELEASE_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "release.yml"

CI_JOB = "haskell"
RELEASE_JOB = "build-test"

SETUP_ACTION = "haskell-actions/setup"
PREFIX_STEP = "Establish a runner-owned compiler installation prefix"
COMPILER_CACHE_STEP = "Restore the pinned compiler"
VERIFY_STEP = "Verify the pinned toolchain"
PRUNE_STEP = "Drop the installer's scratch directories"

# What the compiler cache key has to partition by: a restored tree is valid
# only for one compiler, one Cabal, one runner, and one installation layout.
KEY_PARTITIONS = (
    "runner.os",
    "runner.arch",
    "env.GHC_VERSION",
    "env.CABAL_VERSION",
)

# What it must not partition by. The compiler does not change when a module is
# added, and a key that moved with the package description would miss on
# nearly every pull request -- which is the current behavior this replaces.
KEY_NON_PARTITIONS = ("kanban.cabal", "cabal.project", "hashFiles")


def setUpModule():
    # `tools/` ships whole in the source distribution and `.github/workflows/`
    # deliberately does not, so an unpacked release runs this module with
    # nothing to read. That is the packaged state, not a failure.
    for workflow in (CI_WORKFLOW, RELEASE_WORKFLOW):
        if not workflow.is_file():
            raise unittest.SkipTest(f"{workflow} is absent (not a Git checkout)")


# -- reading one workflow --------------------------------------------------


class Workflow:
    """One workflow file, read by indentation."""

    def __init__(self, path, job):
        self.path = path
        self.job = job

    def __str__(self):  # pragma: no cover - test failure messages
        return f"{self.path.name} job {self.job}"

    @property
    def lines(self):
        # Read on use rather than at construction: `tools/` ships in the
        # source distribution and `.github/` does not, and a module that read
        # a workflow while being imported would raise there instead of
        # reaching setUpModule's skip.
        return self.path.read_text(encoding="utf-8").splitlines()

    def job_lines(self):
        header = f"  {self.job}:"
        try:
            start = self.lines.index(header)
        except ValueError as error:  # pragma: no cover - a renamed job
            raise AssertionError(f"{self.path} has no job named {self.job}") from error
        body = []
        for line in self.lines[start + 1 :]:
            if line.strip() and not line.startswith("   "):
                break
            body.append(line)
        return body

    def job_env(self):
        """The job's own `env:` mapping."""
        body = self.job_lines()
        try:
            start = body.index("    env:")
        except ValueError as error:  # pragma: no cover - a moved block
            raise AssertionError(f"{self} declares no job-level env:") from error
        env = {}
        for line in body[start + 1 :]:
            if not line.strip():
                continue
            if not line.startswith("      ") or line.startswith("       "):
                break
            if line.strip().startswith("#"):
                continue
            name, _, value = line.strip().partition(":")
            env[name] = value.strip().strip('"')
        return env

    def steps(self):
        """Each step of the job, as its own list of lines.

        A comment between two steps lands with the step above it; every
        comparison below reads directives, so that placement does not matter.
        """
        body = self.job_lines()
        try:
            start = body.index("    steps:")
        except ValueError as error:  # pragma: no cover - a renamed job
            raise AssertionError(f"{self} has no steps:") from error
        collected = []
        current = None
        for line in body[start + 1 :]:
            if line.strip() and not line.startswith("     "):
                break
            if line.startswith("      - "):
                current = []
                collected.append(current)
            if current is not None:
                current.append(line)
        return collected

    def step_index(self, predicate):
        """Where the first step satisfying `predicate` sits in the job."""
        for index, step in enumerate(self.steps()):
            if predicate(step):
                return index
        return None

    def named_step(self, name):
        index = self.step_index(lambda step: step_name(step) == name)
        if index is None:  # pragma: no cover - a renamed step
            raise AssertionError(f"{self} has no step named {name!r}")
        return self.steps()[index]

    def resolve(self, expression):
        """An expression with its `env.` references substituted."""
        env = self.job_env()
        return re.sub(
            r"\$\{\{\s*env\.([A-Za-z_][A-Za-z0-9_]*)\s*\}\}",
            lambda match: env.get(match.group(1), match.group(0)),
            expression,
        )


def directives(step):
    """A step's lines with its comments dropped."""
    return [line for line in step if not line.strip().startswith("#")]


def _own_keys(step):
    """A step's own `key: value` lines, excluding anything nested under them.

    `release.yml` gives an `upload-artifact` step a `name:` input, so a reader
    that took the first `name:` anywhere in a step would report that as the
    step's name.
    """
    body = directives(step)
    if not body:  # pragma: no cover - an empty step
        return []
    base = len(body[0]) - len(body[0].lstrip())
    own = []
    for line in body:
        indent = len(line) - len(line.lstrip())
        stripped = line.strip()
        if stripped.startswith("- "):
            indent, stripped = indent + 2, stripped[2:]
        if indent == base + 2 and ":" in stripped:
            own.append(stripped)
    return own


def _scalar(step, field):
    for entry in _own_keys(step):
        if entry.startswith(f"{field}:"):
            return entry.split(":", 1)[1].strip()
    return None


def step_name(step):
    return _scalar(step, "name")


def step_uses(step):
    return _scalar(step, "uses")


def with_lines(step):
    """The lines of a step's `with:` block, its header excluded."""
    body = directives(step)
    try:
        start = next(index for index, line in enumerate(body) if line.strip() == "with:")
    except StopIteration:  # pragma: no cover - a step without inputs
        return []
    indent = len(body[start]) - len(body[start].lstrip())
    collected = []
    for line in body[start + 1 :]:
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            break
        collected.append(line)
    return collected


def step_with(step, field):
    """One scalar `with:` input of a step."""
    for line in with_lines(step):
        if line.strip().startswith(f"{field}:"):
            return line.strip().split(":", 1)[1].strip()
    return None


def step_has_with(step, field):
    return any(line.strip().startswith(f"{field}:") for line in with_lines(step))


def step_run(step):
    """A step's `run:` script, block or inline, dedented."""
    body = directives(step)
    for index, line in enumerate(body):
        stripped = line.strip()
        if stripped == "run: |":
            indent = len(line) - len(line.lstrip()) + 2
            script = []
            for entry in body[index + 1 :]:
                if entry.strip() and not entry.startswith(" " * indent):
                    break
                script.append(entry[indent:] if entry.strip() else "")
            return "\n".join(script) + "\n"
        if stripped.startswith("run:"):
            return stripped.split(":", 1)[1].strip() + "\n"
    return None


def is_setup_step(step):
    uses = step_uses(step)
    return uses is not None and uses.startswith(f"{SETUP_ACTION}@")


def is_build_step(step):
    run = step_run(step)
    return run is not None and re.search(r"^\s*cabal\s", run, re.MULTILINE) is not None


CI = Workflow(CI_WORKFLOW, CI_JOB)
RELEASE = Workflow(RELEASE_WORKFLOW, RELEASE_JOB)
BOTH = (CI, RELEASE)


# -- the two workflows against each other ----------------------------------


class ToolchainParityTests(unittest.TestCase):
    """Compared to each other, so a bump of one alone cannot land."""

    def assertSameAcross(self, label, read):
        """One reading of both workflows, required to agree and to exist.

        Two workflows that have both stopped declaring something agree about
        it, so equality alone would pass on the change it is here to catch.
        """
        values = {str(flow): read(flow) for flow in BOTH}
        for flow, value in values.items():
            self.assertIsNotNone(value, f"{flow} declares no {label}")
        self.assertEqual(
            len(set(values.values())),
            1,
            f"the two workflows disagree about {label}: {values}",
        )
        return next(iter(values.values()))

    def test_both_pin_the_same_compiler_and_cabal(self):
        ci_env, release_env = CI.job_env(), RELEASE.job_env()
        for name in ("GHC_VERSION", "CABAL_VERSION"):
            self.assertIn(name, ci_env, f"{CI} names no {name}")
            self.assertIn(name, release_env, f"{RELEASE} names no {name}")
            self.assertEqual(
                ci_env[name],
                release_env[name],
                f"{name} differs between the workflows, so they build with different toolchains",
            )

    def test_both_install_with_the_same_setup_action(self):
        # Identical versions installed by different actions is not identical
        # resolution: the action decides where the compiler lands and what
        # goes on PATH.
        self.assertSameAcross("setup action", lambda flow: step_uses(_setup(flow)))

    def test_both_establish_the_same_installation_base(self):
        script = self.assertSameAcross(
            "installation base", lambda flow: step_run(flow.named_step(PREFIX_STEP))
        )
        self.assertIn("GHCUP_INSTALL_BASE_PREFIX", script)
        self.assertIn("GITHUB_ENV", script)

    def test_both_cache_the_compiler_at_the_same_path_under_the_same_key(self):
        self.assertSameAcross("compiler cache path", lambda flow: step_with(_cache(flow), "path"))
        self.assertSameAcross("compiler cache key", lambda flow: step_with(_cache(flow), "key"))

    def test_both_verify_the_toolchain_with_the_same_script(self):
        # The parity that lets tools/test_ci_workflow.py execute one script and
        # cover both.
        self.assertSameAcross(
            "toolchain verification", lambda flow: step_run(flow.named_step(VERIFY_STEP))
        )

    def test_both_drop_the_installer_scratch_with_the_same_script(self):
        self.assertSameAcross(
            "scratch cleanup", lambda flow: step_run(flow.named_step(PRUNE_STEP))
        )


# -- what each workflow has to do with those pins --------------------------


class CompilerCacheTests(unittest.TestCase):
    """Run against each workflow, so neither can drift from the contract."""

    def test_the_setup_step_installs_the_pinned_versions(self):
        # Read from the job env rather than written out again, so the versions
        # installed, cached, and verified cannot disagree inside one workflow.
        for flow in BOTH:
            with self.subTest(workflow=str(flow)):
                setup = _setup(flow)
                self.assertEqual(step_with(setup, "ghc-version"), "${{ env.GHC_VERSION }}")
                self.assertEqual(
                    step_with(setup, "cabal-version"), "${{ env.CABAL_VERSION }}"
                )

    def test_the_compiler_restore_precedes_the_setup_that_would_install(self):
        for flow in BOTH:
            with self.subTest(workflow=str(flow)):
                restore = flow.step_index(
                    lambda step: step_name(step) == COMPILER_CACHE_STEP
                )
                setup = flow.step_index(is_setup_step)
                self.assertIsNotNone(restore)
                self.assertIsNotNone(setup)
                self.assertLess(
                    restore,
                    setup,
                    "the compiler is restored after the step that would install it",
                )

    def test_the_installation_base_is_established_before_it_is_restored(self):
        # The prefix step replaces whatever `~/.ghcup` the runner image left,
        # so it cannot run after the restore that fills it.
        for flow in BOTH:
            with self.subTest(workflow=str(flow)):
                prefix = flow.step_index(lambda step: step_name(step) == PREFIX_STEP)
                restore = flow.step_index(
                    lambda step: step_name(step) == COMPILER_CACHE_STEP
                )
                self.assertLess(prefix, restore)

    def test_the_compiler_cache_key_partitions_by_what_the_tree_is_valid_for(self):
        for flow in BOTH:
            with self.subTest(workflow=str(flow)):
                key = step_with(_cache(flow), "key")
                for partition in KEY_PARTITIONS:
                    self.assertIn(partition, key, f"the key does not partition by {partition}")

    def test_the_compiler_cache_key_names_the_pinned_compiler(self):
        for flow in BOTH:
            with self.subTest(workflow=str(flow)):
                resolved = flow.resolve(step_with(_cache(flow), "key"))
                self.assertIn(flow.job_env()["GHC_VERSION"], resolved, resolved)

    def test_the_compiler_cache_key_carries_a_layout_discriminator(self):
        # The prefix and what is kept under it are this workflow's choices,
        # not the compiler's, so changing them has to be able to invalidate
        # every entry without touching a pin.
        for flow in BOTH:
            with self.subTest(workflow=str(flow)):
                key = step_with(_cache(flow), "key")
                literal = re.sub(r"\$\{\{[^}]*\}\}", "", key)
                self.assertRegex(
                    literal,
                    r"(^|[^A-Za-z0-9])v[0-9]+([^A-Za-z0-9]|$)",
                    f"the key carries no layout version: {key}",
                )

    def test_the_compiler_cache_key_moves_with_no_source_file(self):
        for flow in BOTH:
            with self.subTest(workflow=str(flow)):
                key = step_with(_cache(flow), "key")
                for fragment in KEY_NON_PARTITIONS:
                    self.assertNotIn(fragment, key)

    def test_the_compiler_cache_has_no_fallback_key(self):
        # A prefix match is by definition a tree built for another pin or
        # another layout. Half a compiler is not worth having; a miss
        # reinstalls, which is slower and still correct.
        for flow in BOTH:
            with self.subTest(workflow=str(flow)):
                self.assertFalse(
                    step_has_with(_cache(flow), "restore-keys"),
                    "the compiler cache accepts a fallback key",
                )

    def test_the_compiler_cache_covers_the_installation_base(self):
        for flow in BOTH:
            with self.subTest(workflow=str(flow)):
                self.assertEqual(step_with(_cache(flow), "path"), "~/.ghcup")
                self.assertIn('"$HOME/.ghcup"', step_run(flow.named_step(PREFIX_STEP)))

    def test_the_toolchain_is_verified_before_anything_builds_with_it(self):
        for flow in BOTH:
            with self.subTest(workflow=str(flow)):
                verify = flow.step_index(lambda step: step_name(step) == VERIFY_STEP)
                build = flow.step_index(is_build_step)
                self.assertIsNotNone(build, "the job runs no cabal step")
                self.assertLess(
                    verify, build, "the build runs before the toolchain is verified"
                )

    def test_the_package_cache_keys_on_the_same_pin(self):
        # The package store is built by the compiler above it. Left naming its
        # own literal, it would keep restoring a store built by the old one
        # through a bump of the pin.
        for flow in BOTH:
            with self.subTest(workflow=str(flow)):
                key = step_with(_package_cache(flow), "key")
                self.assertIn("env.GHC_VERSION", key)
                self.assertNotIn(flow.job_env()["GHC_VERSION"], key)


def _setup(flow):
    index = flow.step_index(is_setup_step)
    if index is None:  # pragma: no cover - a replaced action
        raise AssertionError(f"{flow} does not use {SETUP_ACTION}")
    return flow.steps()[index]


def _cache(flow):
    return flow.named_step(COMPILER_CACHE_STEP)


def _package_cache(flow):
    """The step caching the package store, found by what it caches."""
    index = flow.step_index(
        lambda step: any("~/.cabal/store" in line for line in with_lines(step))
    )
    if index is None:  # pragma: no cover - a removed cache
        raise AssertionError(f"{flow} caches no package store")
    return flow.steps()[index]


if __name__ == "__main__":  # pragma: no cover - convenience
    unittest.main()
