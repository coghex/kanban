#!/usr/bin/env python3
"""Behavioral coverage for the vendored janitor census (issue #574).

The census is the janitor workflow's whole read side, and until this issue it
was an untracked personal script: nothing in a pull request could change it and
nothing could verify it. The two shipped copies are what this module drives.

Three properties get the weight here, because each is a place where a wrong
answer reads as a *clean* one and the workflow's next step is a deletion:

- The drainer controller is resolved through `kanban_config.drainer_install_dir()`
  rather than spelled. The retired spelling found nothing on a Linux host and
  ignored both `KANBAN_DRAINER_INSTALL_DIR` and an `--install-dir` install, so a
  relocated drainer looked like no drainer.
- The retain ledger is read from the repository's *common* directory, so every
  linked worktree reads the one ledger, and an unreadable ledger reports `null`
  rather than an empty list. Reporting it empty would tell the janitor that
  nothing is retained.
- The optional test-coordinator probe stays fail-soft: a host with no
  coordinator is the ordinary case, not an error.

Only the Claude copy is imported for behavior; `tools/test_document_workflow_contract.py`
and the byte-equality check below are what make one execution cover both.
"""

from __future__ import annotations

import contextlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parent.parent
CENSUS_COPIES = (
    REPO_ROOT / "claude-plugin" / "plugins" / "kanban" / "scripts" / "census.py",
    REPO_ROOT
    / "codex-plugin"
    / "plugins"
    / "kanban"
    / "skills"
    / "janitor"
    / "scripts"
    / "census.py",
)
CENSUS_PATH = CENSUS_COPIES[0]
CONTROLLER_NAME = "drain_prs_service.py"
SUBPROCESS_TIMEOUT_SECONDS = 120

# What a repository census always reports. Pinned as an exact set rather than a
# handful of `assertIn`s: a collection that silently stopped being produced is
# the failure this document shape exists to prevent, and the janitor reads the
# absence of a signal as the absence of the problem it names.
CENSUS_KEYS = {
    "schema",
    "repo_root",
    "default_branch",
    "default_head",
    "remote_default_head",
    "default_divergence",
    "worktrees",
    "local_branches",
    "remote_heads",
    "stale_tracking_refs",
    "stashes",
    "configured_remotes",
    "tracking_refs_for_missing_remotes",
    "other_remote_tracking_refs",
    "retain_ledger",
    "drainer",
    "drainer_untracked_holdings",
    "test_coordinator",
    "github",
    "signals",
    "warnings",
    "counts",
}

# A controller that answers `--json status` with a document shaped like the
# real one's, tagged so a test can tell which install answered.
FAKE_CONTROLLER = """\
import json
print(json.dumps({
    "state": %(tag)r, "launchd_loaded": True, "operation": None,
    "last_activity": None, "open_incidents": [], "cleanup_obligations": [],
    "kept_autostash_anchors": [], "drainer_stashes": [],
}))
"""

FAKE_COORDINATOR = """\
import json, sys
if "proposal-list" in sys.argv:
    print(json.dumps({"proposals": [
        {"proposal_id": "p1", "test_id": "t1", "status": "open",
         "created_at": "2026-01-01T00:00:00Z"}]}))
else:
    print(json.dumps({"paths": {"base_worktree": "/nowhere"}, "runs": [
        {"run_id": "r1", "test_id": "t1", "status": "running",
         "heartbeat_at": "2026-01-01T00:00:00Z", "worktree_path": "/nowhere"}]}))
"""

LEDGER_ITEM = {
    "id": "keep-docs-wip",
    "target": "branch docs-wip",
    "disposition": "retain",
    "reason": "durable authoring worktree",
    "review_when": "the docs arc completes",
}


def load_census():
    """The shipped Claude copy, imported by path.

    It lives under `claude-plugin/`, never on `sys.path`, and it loads
    `kanban_config.py` from beside itself -- so importing the tracked bundle
    file is what proves the bundle is self-contained.
    """
    name = "_kanban_janitor_census_under_test"
    spec = importlib.util.spec_from_file_location(name, CENSUS_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


census = load_census()


def git(cwd: Path, *args: str) -> str:
    done = subprocess.run(
        ["git", *args],
        cwd=cwd,
        text=True,
        capture_output=True,
        timeout=SUBPROCESS_TIMEOUT_SECONDS,
    )
    if done.returncode != 0:
        raise AssertionError(f"git {' '.join(args)}: {done.stderr or done.stdout}")
    return done.stdout


class CensusFixture(unittest.TestCase):
    """A real repository with an `origin`, because the census reads both."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        origin = self.root / "origin.git"
        git(self.root, "init", "--bare", "--initial-branch=master", str(origin))
        self.repo = self.root / "work"
        git(self.root, "clone", str(origin), str(self.repo))
        git(self.repo, "config", "user.email", "census@example.invalid")
        git(self.repo, "config", "user.name", "Census Fixture")
        (self.repo / "README.md").write_text("fixture\n", encoding="utf-8")
        git(self.repo, "add", "README.md")
        git(self.repo, "commit", "-m", "initial")
        git(self.repo, "push", "-u", "origin", "master")
        self.common_dir = Path(
            git(
                self.repo, "rev-parse", "--path-format=absolute", "--git-common-dir"
            ).strip()
        )

    @contextlib.contextmanager
    def pinned_environment(self, **overrides):
        """Every input the census's resolvers read, pinned for one block.

        `HOME` is redirected so nothing can reach the developer's own install,
        and `KANBAN_DRAINER_INSTALL_DIR` is removed unless a test names it, so
        a test that does not set an override is testing the unset case rather
        than whatever the ambient environment happened to hold.
        `mock.patch.dict` restores the whole mapping on exit, the removal
        included.
        """
        environment = {
            "HOME": str(self.home),
            "XDG_DATA_HOME": str(self.root / "unoccupied-xdg"),
            "CODEX_HOME": str(self.root / "absent-codex"),
        }
        environment.update(overrides)
        with mock.patch.dict(os.environ, environment):
            if "KANBAN_DRAINER_INSTALL_DIR" not in overrides:
                os.environ.pop("KANBAN_DRAINER_INSTALL_DIR", None)
            yield

    def run_census(self, cwd=None, **overrides):
        with self.pinned_environment(**overrides):
            return census.census(cwd or self.repo, fetch=False, local_only=True)

    def install_controller(self, directory: Path, tag: str, *, record: bool = True):
        directory.mkdir(parents=True, exist_ok=True)
        (directory / CONTROLLER_NAME).write_text(
            FAKE_CONTROLLER % {"tag": tag}, encoding="utf-8"
        )
        if record:
            (directory / "config.json").write_text("{}\n", encoding="utf-8")
        return directory

    def write_ledger(self, document):
        path = self.common_dir / census.RETAIN_LEDGER
        if isinstance(document, str):
            path.write_text(document, encoding="utf-8")
        else:
            path.write_text(json.dumps(document), encoding="utf-8")
        self.addCleanup(path.unlink, missing_ok=True)
        return path


class ShippedCopyTests(unittest.TestCase):
    def test_both_shipped_copies_are_byte_identical(self):
        claude, codex = (path.read_bytes() for path in CENSUS_COPIES)
        self.assertEqual(
            claude,
            codex,
            "the two bundled censuses have diverged; they are one program, "
            f"not a fork. Repair: cp {CENSUS_COPIES[0].relative_to(REPO_ROOT)} "
            f"{CENSUS_COPIES[1].relative_to(REPO_ROOT)}",
        )

    def test_the_self_test_passes_from_both_shipped_locations(self):
        # Run from each bundle rather than once from a chosen one: the
        # self-test resolves `kanban_config.py` from beside itself, so passing
        # is also the assertion that each bundle shipped that sibling.
        for path in CENSUS_COPIES:
            with self.subTest(copy=str(path.relative_to(REPO_ROOT))):
                done = subprocess.run(
                    [sys.executable, str(path), "--self-test"],
                    text=True,
                    capture_output=True,
                    timeout=SUBPROCESS_TIMEOUT_SECONDS,
                )
                self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
                self.assertIn("census self-test: PASS", done.stdout)


class CensusDocumentTests(CensusFixture):
    def test_the_document_is_a_janitor_census_v1_with_every_collection(self):
        document = self.run_census()
        self.assertEqual(document["schema"], "janitor-census/v1")
        self.assertEqual(set(document), CENSUS_KEYS)
        self.assertEqual(document["repo_root"], str(self.repo.resolve()))
        self.assertEqual(document["default_branch"], "master")
        self.assertEqual(document["warnings"], [])
        self.assertEqual([row["path"] for row in document["worktrees"]],
                         [str(self.repo.resolve())])
        self.assertEqual([row["name"] for row in document["local_branches"]],
                         ["master"])
        self.assertEqual(document["stashes"], [])
        self.assertEqual(document["configured_remotes"], ["origin"])
        self.assertEqual(document["counts"]["worktrees"], 1)
        self.assertEqual(document["counts"]["stashes"], 0)

    def test_the_collections_track_what_git_independently_reports(self):
        # The demonstration the issue asks for, as an assertion: each
        # collection is compared against the plumbing that owns it, so a
        # collection that silently stopped being read fails here.
        (self.repo / "scratch.txt").write_text("dirty\n", encoding="utf-8")
        git(self.repo, "stash", "push", "--include-untracked", "-m", "fixture")
        git(self.repo, "branch", "issue-1-example")
        document = self.run_census()
        self.assertEqual(
            {row["path"] for row in document["worktrees"]},
            {line.split()[0] for line in git(self.repo, "worktree", "list").splitlines()},
        )
        self.assertEqual(
            {row["name"] for row in document["local_branches"]},
            set(git(self.repo, "branch", "--format=%(refname:short)").split()),
        )
        self.assertEqual(
            len(document["stashes"]), len(git(self.repo, "stash", "list").splitlines())
        )
        self.assertEqual(document["counts"]["stashes"], 1)


class DrainerResolutionTests(CensusFixture):
    def test_an_override_at_an_absent_install_reports_no_drainer(self):
        document = self.run_census(
            KANBAN_DRAINER_INSTALL_DIR=str(self.root / "absent-drainer")
        )
        self.assertEqual(document["drainer"], {"available": False})

    def test_an_override_at_a_relocated_install_reports_that_install(self):
        install = self.install_controller(self.root / "relocated", "relocated")
        document = self.run_census(KANBAN_DRAINER_INSTALL_DIR=str(install))
        self.assertEqual(document["drainer"]["available"], True)
        self.assertEqual(document["drainer"].get("state"), "relocated")
        self.assertEqual(document["drainer"]["open_incidents"], [])

    def test_an_xdg_install_is_found_on_a_host_with_no_library_tree(self):
        # The Linux shape the retired hardcoded path could not reach at all.
        xdg = self.root / "xdg"
        self.install_controller(xdg / "kanban" / "pr-drainer", "xdg")
        document = self.run_census(XDG_DATA_HOME=str(xdg))
        self.assertEqual(document["drainer"].get("state"), "xdg")

    def test_the_resolver_wins_over_the_retired_hardcoded_macos_path(self):
        # The discriminating case: BOTH locations hold an installation, and
        # `installed_drainer_dir()` prefers the XDG one. A census that still
        # spelled `~/Library/Application Support/kanban/pr-drainer` would
        # report the other install, so this fails against the retired code and
        # passes against the resolver.
        xdg = self.root / "xdg"
        self.install_controller(xdg / "kanban" / "pr-drainer", "xdg")
        self.install_controller(
            self.home / "Library" / "Application Support" / "kanban" / "pr-drainer",
            "macos",
        )
        document = self.run_census(XDG_DATA_HOME=str(xdg))
        self.assertEqual(document["drainer"].get("state"), "xdg")

    def test_an_unloadable_configuration_module_is_reported_not_raised(self):
        # The bundle-incomplete case. A census is a read, so it reports what it
        # could not resolve instead of exiting; the `error` key is what keeps
        # that distinguishable from "this host has no drainer", which is the
        # collapse a janitor would act on.
        def unloadable():
            raise census.CensusError("the configuration module ... vanished")

        with mock.patch.object(census, "kanban_config_module", unloadable):
            document = self.run_census()
        self.assertEqual(document["drainer"]["available"], False)
        self.assertIn("configuration module", document["drainer"]["error"])

    def test_the_controller_is_whatever_kanban_config_resolves(self):
        # Bound to the call site rather than restating the precedence: the one
        # spelling of "where is the drainer" is that function, and this is what
        # keeps the census from growing a second one.
        configuration = census.kanban_config_module()
        install = self.install_controller(self.root / "relocated", "relocated")
        for label, overrides in (
            ("override", {"KANBAN_DRAINER_INSTALL_DIR": str(install)}),
            ("no override", {}),
        ):
            with self.subTest(shape=label):
                with self.pinned_environment(**overrides):
                    self.assertEqual(
                        census.drainer_controller(),
                        configuration.drainer_install_dir() / CONTROLLER_NAME,
                    )


class TestCoordinatorProbeTests(CensusFixture):
    def test_an_absent_coordinator_is_reported_rather_than_raised(self):
        document = self.run_census(CODEX_HOME=str(self.root / "no-such-codex"))
        self.assertEqual(document["test_coordinator"], {"available": False})
        self.assertEqual(document["warnings"], [])

    def test_a_present_coordinator_is_actually_consulted(self):
        # The control the absent case cannot be: `available: False` would also
        # be what a deleted probe reported.
        codex_home = self.root / "codex"
        scripts = codex_home / "skills" / "test" / "scripts"
        scripts.mkdir(parents=True)
        (scripts / "test_coordinator.py").write_text(FAKE_COORDINATOR, encoding="utf-8")
        registry = self.common_dir / "codex-test" / "registry.json"
        registry.parent.mkdir(parents=True, exist_ok=True)
        registry.write_text("{}\n", encoding="utf-8")
        self.addCleanup(registry.unlink, missing_ok=True)

        document = self.run_census(CODEX_HOME=str(codex_home))
        state = document["test_coordinator"]
        self.assertEqual(state["available"], True)
        self.assertEqual(state["initialized"], True)
        self.assertEqual([run["run_id"] for run in state["active_runs"]], ["r1"])
        self.assertEqual(
            [row["proposal_id"] for row in state["active_proposals"]], ["p1"]
        )


class RetainLedgerTests(CensusFixture):
    def test_a_repository_with_no_ledger_reports_an_empty_list(self):
        document = self.run_census()
        self.assertEqual(document["retain_ledger"], {"present": False, "items": []})
        self.assertEqual(document["counts"]["retained_items"], 0)

    def test_a_valid_ledger_with_no_entries_reports_an_empty_list(self):
        self.write_ledger({"schema": "janitor-retain/v1", "items": []})
        document = self.run_census()
        self.assertEqual(document["retain_ledger"]["present"], True)
        self.assertEqual(document["retain_ledger"]["items"], [])
        self.assertEqual(document["counts"]["retained_items"], 0)
        self.assertEqual(document["warnings"], [])

    def test_an_unreadable_ledger_reports_null_rather_than_empty(self):
        # The regression that matters: a ledger the census could not read is
        # not a ledger with nothing in it. Reported as empty, the janitor would
        # propose deleting everything the ledger was protecting.
        self.write_ledger("this is not JSON")
        document = self.run_census()
        self.assertIsNone(document["retain_ledger"]["items"])
        self.assertIsNone(document["counts"]["retained_items"])
        self.assertIn("error", document["retain_ledger"])
        self.assertEqual(len(document["warnings"]), 1)
        self.assertIn("retain ledger unreadable", document["warnings"][0])

    def test_a_ledger_failing_validation_is_unreadable_too(self):
        # Not only malformed JSON: a well-formed document that is not a
        # `janitor-retain/v1` ledger is equally undetermined.
        self.write_ledger({"schema": "janitor-retain/v2", "items": []})
        document = self.run_census()
        self.assertIsNone(document["retain_ledger"]["items"])
        self.assertIsNone(document["counts"]["retained_items"])

    def test_a_ledger_symlink_is_unreadable_rather_than_absent(self):
        # `Path.exists()` follows the link, so a dangling `janitor-retain.json`
        # answered "absent" -- `items: []` -- for an entry the operator can see
        # in the directory listing. Presence is a question about the directory
        # entry, and an entry that cannot be followed is the unreadable case.
        # The resolvable link is here too, because the rule this file has
        # always applied is that a ledger must be a regular, non-symlink file:
        # both spellings must land on `None`, and the second is what proves the
        # first is not passing merely because the target was missing.
        ledger = self.common_dir / census.RETAIN_LEDGER
        target = self.root / "elsewhere.json"
        target.write_text(
            json.dumps({"schema": "janitor-retain/v1", "items": [LEDGER_ITEM]}),
            encoding="utf-8",
        )
        for label, destination in (
            ("dangling", self.root / "no-such-ledger.json"),
            ("resolvable", target),
        ):
            with self.subTest(link=label):
                ledger.symlink_to(destination)
                self.addCleanup(ledger.unlink, missing_ok=True)
                try:
                    document = self.run_census()
                finally:
                    ledger.unlink()
                self.assertEqual(document["retain_ledger"]["present"], True)
                self.assertIsNone(document["retain_ledger"]["items"])
                self.assertIsNone(document["counts"]["retained_items"])
                self.assertEqual(len(document["warnings"]), 1)
                self.assertIn("retain ledger unreadable", document["warnings"][0])

    def test_the_ledger_is_read_from_the_common_directory(self):
        # Written once, read from a *different* linked worktree of the same
        # repository. A `--git-dir` read would find nothing there.
        path = self.write_ledger(
            {"schema": "janitor-retain/v1", "items": [LEDGER_ITEM]}
        )
        linked = self.root / "linked"
        git(self.repo, "worktree", "add", "-b", "issue-9-linked", str(linked))
        self.addCleanup(
            git, self.repo, "worktree", "remove", "--force", str(linked)
        )
        self.assertNotEqual(
            Path(git(linked, "rev-parse", "--path-format=absolute", "--git-dir").strip()),
            self.common_dir,
            "the fixture's linked worktree shares the primary git directory, "
            "so this proves nothing",
        )

        document = self.run_census(cwd=linked)
        self.assertEqual(document["retain_ledger"].get("path"), str(path))
        self.assertEqual(document["retain_ledger"]["items"], [LEDGER_ITEM])
        self.assertEqual(document["counts"]["retained_items"], 1)


class FetchDoesNotPruneTests(CensusFixture):
    """`--fetch` refreshes `origin` and removes nothing.

    The janitor workflow this program feeds treats a stale origin-tracking ref
    as an anomaly the user approves individually, and deletes it one ref at a
    time with the value the report recorded. A refresh that pruned would delete
    every one of them during the read-only pass, before any was reported --
    which `fetch.prune=true` is enough to cause, since it is an ordinary
    configuration and not an exotic one. The program therefore passes
    `--no-prune` rather than leaving the behavior to the host.
    """

    def stale_tracking_refs(self):
        listing = git(self.repo, "for-each-ref", "--format=%(refname)", "refs/remotes")
        return sorted(line for line in listing.splitlines() if line.strip())

    def make_a_stale_tracking_ref(self) -> str:
        """A `refs/remotes/origin/*` ref whose branch is gone from origin.

        The branch is removed in the origin repository rather than through a
        `push --delete` from this clone, because that is how a tracking ref
        actually goes stale: somebody else deleted the branch, and this clone
        still carries the ref. Deleting it through this clone's own push would
        remove the tracking ref along with it and leave nothing to test.
        """
        git(self.repo, "checkout", "-q", "-b", "issue-4-gone")
        git(self.repo, "push", "-q", "-u", "origin", "issue-4-gone")
        git(self.repo, "checkout", "-q", "master")
        git(self.root / "origin.git", "branch", "-D", "issue-4-gone")
        ref = "refs/remotes/origin/issue-4-gone"
        self.assertIn(ref, self.stale_tracking_refs())
        return ref

    def fetch(self, **config):
        for key, value in config.items():
            git(self.repo, "config", key, value)
        with self.pinned_environment():
            return census.census(self.repo, fetch=True, local_only=True)

    def test_a_pruning_configuration_does_not_delete_a_stale_ref(self):
        ref = self.make_a_stale_tracking_ref()
        document = self.fetch(**{"fetch.prune": "true"})
        self.assertIn(ref, self.stale_tracking_refs())
        # And it is still reported, which is the point: the workflow's
        # per-item deletion gate has something to approve.
        self.assertIn(
            ref, [row["ref"] for row in document["stale_tracking_refs"]]
        )

    def test_the_control_shows_git_would_have_pruned_it(self):
        # Non-vacuity: without `--no-prune`, this exact configuration removes
        # the ref. Driven through git rather than through a second census, so
        # the control measures the tool's behavior and not this module's.
        ref = self.make_a_stale_tracking_ref()
        git(self.repo, "config", "fetch.prune", "true")
        git(self.repo, "fetch", "origin")
        self.assertNotIn(ref, self.stale_tracking_refs())

    def test_the_fetch_is_spelled_with_no_prune_in_both_shipped_copies(self):
        for path in CENSUS_COPIES:
            with self.subTest(copy=str(path)):
                source = path.read_text(encoding="utf-8")
                self.assertIn('"fetch", "--no-prune", "origin"', source)
                self.assertNotIn('"fetch", "origin"', source)


if __name__ == "__main__":
    unittest.main()
