"""CLI-level tests for `drain_prs.py --pr`: the single-PR entry point.

Every test runs the real script as a subprocess against a real temporary Git
repository with a scriptable fake `gh` on PATH, so what is asserted is the
external contract a caller actually sees -- the one JSON document on stdout,
the process exit status, and what the run did or did not touch. No network, no
model calls.

The bare remote is created at `<tmp>/acme/widgets.git` on purpose: the plain
local path derives the `acme/widgets` slug through the very
kanban_config.parse_repository_name() the drainer uses, so the subprocess
resolves its own repository context without a GitHub URL or any rewriting.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
"""

import contextlib
import fcntl
import hashlib
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import drain_prs
import drain_prs_service
import fake_cli


TOOLS_DIR = Path(__file__).resolve().parent
SCRIPT = TOOLS_DIR / "drain_prs.py"
# Everything drain_prs.py imports, for the fixture that runs a copy of the
# script from inside the repository under test.
SCRIPT_MODULES = (
    "drain_prs.py",
    "drain_prs_service.py",
    "kanban_config.py",
    "service_manager.py",
)


def run_git(args, *, cwd):
    proc = subprocess.run(
        ["git", *args], cwd=str(cwd), text=True, capture_output=True
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"git {' '.join(args)} failed in {cwd}:\n{proc.stdout}\n{proc.stderr}"
        )
    return proc.stdout.strip()


def git_ref_exists(repo_dir, ref):
    return (
        subprocess.run(
            ["git", "show-ref", "--verify", "--quiet", ref],
            cwd=str(repo_dir),
            capture_output=True,
        ).returncode
        == 0
    )


def snapshot_tree(root):
    """Content-addressed snapshot of every path under `root`, `.git` included."""
    entries = {}
    for path in sorted(root.rglob("*")):
        key = str(path.relative_to(root))
        if path.is_symlink():
            entries[key] = ("symlink", os.readlink(path))
        elif path.is_dir():
            entries[key] = ("dir", "")
        else:
            entries[key] = (
                "file",
                hashlib.sha256(path.read_bytes()).hexdigest(),
            )
    return entries


class SinglePrCliFixture(unittest.TestCase):
    """A temporary repository, a scriptable fake `gh`, and one PR #42."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

        self.bare = self.root / "acme" / "widgets.git"
        self.main = self.root / "main"
        self.feature_wt = self.root / "wt-issue-99"
        self.upstream_sim = self.root / "upstream-sim"
        self.log_dir = self.root / "logs"
        # An absent path, so the subprocess loads pure defaults instead of the
        # developer's own ~/.config/kanban/config.toml.
        self.absent_config = self.root / "no-such-config.toml"
        self.state_path = self.main / ".git" / "drain_prs_state.json"
        self.lock_path = self.main / ".git" / "drain_prs.lock"
        # Redirects drain_prs_service's incident and notification storage into
        # the fixture, so a subprocess never writes to the developer's own
        # ~/Library/Application Support/kanban/pr-drainer.
        self.install_dir = self.root / "drainer-install"
        self.incident_dir = self.install_dir / "runtime" / "incidents"

        self.bare.parent.mkdir(parents=True, exist_ok=True)
        run_git(["init", "--bare", "-q", "-b", "master", str(self.bare)], cwd=self.root)
        run_git(["init", "-q", "-b", "master", str(self.main)], cwd=self.root)
        run_git(["config", "user.email", "test@example.com"], cwd=self.main)
        run_git(["config", "user.name", "Test"], cwd=self.main)
        # Keep automatic maintenance from writing into .git behind the tests
        # that assert a dry run changed nothing.
        run_git(["config", "gc.auto", "0"], cwd=self.main)
        (self.main / "README").write_text("hello\n", encoding="utf-8")
        run_git(["add", "README"], cwd=self.main)
        run_git(["commit", "-q", "-m", "initial commit"], cwd=self.main)
        run_git(["remote", "add", "origin", str(self.bare)], cwd=self.main)
        run_git(["push", "-q", "-u", "origin", "master"], cwd=self.main)

        run_git(
            [
                "worktree",
                "add",
                "-q",
                "-b",
                "issue-99-demo",
                str(self.feature_wt),
                "master",
            ],
            cwd=self.main,
        )
        (self.feature_wt / "feature.txt").write_text("new feature\n", encoding="utf-8")
        run_git(["add", "feature.txt"], cwd=self.feature_wt)
        run_git(["commit", "-q", "-m", "add feature"], cwd=self.feature_wt)
        self.head_sha = run_git(["rev-parse", "HEAD"], cwd=self.feature_wt)
        run_git(["push", "-q", "origin", "issue-99-demo"], cwd=self.feature_wt)

        # Simulate GitHub merging server-side, so the post-merge fast-forward
        # has somewhere real to move to.
        run_git(["clone", "-q", str(self.bare), str(self.upstream_sim)], cwd=self.root)
        run_git(["config", "user.email", "test@example.com"], cwd=self.upstream_sim)
        run_git(["config", "user.name", "Test"], cwd=self.upstream_sim)
        run_git(
            [
                "merge",
                "-q",
                "--no-ff",
                "origin/issue-99-demo",
                "-m",
                "Merge pull request #42",
            ],
            cwd=self.upstream_sim,
        )
        self.merge_commit_sha = run_git(["rev-parse", "HEAD"], cwd=self.upstream_sim)
        run_git(["push", "-q", "origin", "master"], cwd=self.upstream_sim)
        run_git(["remote", "set-head", "origin", "master"], cwd=self.main)

        self.fake = fake_cli.FakeCli(self.root / "fake-cli")
        self.fake.install("gh")

    # -- fixtures ---------------------------------------------------------

    def base_pr_json(self):
        return {
            "number": 42,
            "title": "Add feature",
            "url": "https://github.com/acme/widgets/pull/42",
            "state": "OPEN",
            "isDraft": False,
            "labels": [{"name": drain_prs.APPROVE_LABEL}],
            "mergeable": "MERGEABLE",
            "mergeStateStatus": "CLEAN",
            "headRefOid": self.head_sha,
            "headRefName": "issue-99-demo",
            "baseRefName": "master",
            "statusCheckRollup": [
                {
                    "name": drain_prs.DEFAULT_REQUIRED_CI_CHECK,
                    "status": "COMPLETED",
                    "conclusion": "SUCCESS",
                    "completedAt": "2026-07-18T00:00:00Z",
                },
                {
                    "name": drain_prs.DEFAULT_REQUIRED_REVIEW_CHECK,
                    "status": "COMPLETED",
                    "conclusion": "SUCCESS",
                    "completedAt": "2026-07-18T00:00:01Z",
                },
            ],
            "closingIssuesReferences": [
                {
                    "number": 99,
                    "repository": {"owner": {"login": "acme"}, "name": "widgets"},
                }
            ],
        }

    def script_pr_view(self, *overrides):
        """Queue one `gh pr view 42` response per override, consumed in order."""
        if not overrides:
            overrides = ({},)
        for override in overrides:
            payload = self.base_pr_json()
            payload.update(override)
            self.fake.script("gh", ["pr", "view", "42"], stdout=json.dumps(payload))

    def script_merge_and_cleanup(self):
        self.fake.script("gh", ["pr", "merge", "42"], stdout="")
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script("gh", ["issue", "close", "99"], stdout="")

    def dirty_the_checkout(self):
        """Staged, unstaged, and untracked changes, none of which the
        incoming commits touch."""
        (self.main / "staged.txt").write_text("staged\n", encoding="utf-8")
        run_git(["add", "staged.txt"], cwd=self.main)
        (self.main / "README").write_text("hello, edited\n", encoding="utf-8")
        (self.main / "scratch.txt").write_text("untracked\n", encoding="utf-8")

    def write_state(self, state):
        self.state_path.write_text(
            json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )

    def state_entry(self, head):
        return {
            "approved_head": head,
            "last_rereviewed_head": None,
            "consecutive_failures": 0,
            "retry_after_attempt": 0,
            "last_attempt": 0,
            "last_error": None,
            "cleanup": None,
        }

    # -- driving the CLI --------------------------------------------------

    def run_cli(self, *extra, script=None, log_dir=True):
        env = dict(os.environ)
        env.update(self.fake.environ_overrides())
        env["KANBAN_DRAINER_INSTALL_DIR"] = str(self.install_dir)
        for name in ("KANBAN_DRAINER_NTFY_URL", "DRAIN_PRS_MANAGED"):
            env.pop(name, None)
        args = [
            sys.executable,
            str(script or SCRIPT),
            "--path",
            str(self.main),
            "--config",
            str(self.absent_config),
        ]
        if log_dir:
            args += ["--log-dir", str(self.log_dir)]
        return subprocess.run(
            [*args, *extra], text=True, capture_output=True, env=env
        )

    def run_single(self, *extra, **kwargs):
        """Run `--pr 42` and return (parsed JSON result, completed process)."""
        proc = self.run_cli("--pr", "42", *extra, **kwargs)
        stdout = proc.stdout.strip()
        self.assertTrue(
            stdout, f"expected one JSON document on stdout; stderr was:\n{proc.stderr}"
        )
        # Exactly one document, and nothing else: human diagnostics belong on
        # stderr, so a caller can parse stdout whole.
        self.assertEqual(len(stdout.splitlines()), 1, stdout)
        return json.loads(stdout), proc

    def open_incidents(self):
        if not self.incident_dir.exists():
            return []
        found = [
            json.loads(path.read_text(encoding="utf-8"))
            for path in sorted(self.incident_dir.glob("incident-*.json"))
        ]
        return [item for item in found if item["status"] == "open"]

    def gh_calls(self, *prefix):
        return [
            call
            for call in self.fake.calls("gh")
            if call["args"][: len(prefix)] == list(prefix)
        ]

    def label_edits(self):
        """Every `gh pr edit` that would write a label. The drainer reads
        review verdicts and writes none, so this is empty on every path."""
        return [
            call
            for call in self.gh_calls("pr", "edit")
            if {"--add-label", "--remove-label"} & set(call["args"])
        ]

    def assert_result(self, result, *, outcome, reason, merged, would_merge, dry_run):
        self.assertEqual(
            result,
            {
                "schema": "drain-prs-single-pr",
                "version": 1,
                "pull_request": 42,
                "outcome": outcome,
                "merged": merged,
                "would_merge": would_merge,
                "reason": reason,
                "message": result["message"],
                "dry_run": dry_run,
            },
        )
        self.assertTrue(result["message"].strip())


class SinglePrOutcomeTests(SinglePrCliFixture):
    """The machine-readable result for each condition that can stop a merge,
    and for the merge itself."""

    def test_an_approved_green_pr_merges_and_reports_it(self):
        self.script_pr_view()
        self.script_merge_and_cleanup()

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_MERGED)
        self.assert_result(
            result,
            outcome="merged",
            reason="merged",
            merged=True,
            would_merge=True,
            dry_run=False,
        )
        self.assertEqual(len(self.gh_calls("pr", "merge", "42")), 1)
        self.assertIn("--match-head-commit", self.gh_calls("pr", "merge", "42")[0]["args"])
        # The queue's whole post-merge contract still runs.
        self.assertEqual(len(self.gh_calls("issue", "close", "99")), 1)
        self.assertFalse(self.feature_wt.exists())
        self.assertFalse(git_ref_exists(self.main, "refs/heads/issue-99-demo"))
        self.assertFalse(git_ref_exists(self.bare, "refs/heads/issue-99-demo"))
        self.assertEqual(
            run_git(["rev-parse", "master"], cwd=self.main), self.merge_commit_sha
        )
        # Human diagnostics went somewhere, just not to stdout.
        self.assertIn("PR #42", proc.stderr)

    def test_an_unapproved_pr_is_refused_without_merging(self):
        self.script_pr_view({"labels": []})

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
        self.assert_result(
            result,
            outcome="no_action",
            reason="not_approved",
            merged=False,
            would_merge=False,
            dry_run=False,
        )
        self.assertIn(drain_prs.APPROVE_LABEL, result["message"])
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])

    def test_changes_requested_outranks_a_missing_approval(self):
        # Both labels attached: the requested change is the more specific and
        # more actionable thing to tell the caller.
        self.script_pr_view(
            {
                "labels": [
                    {"name": drain_prs.APPROVE_LABEL},
                    {"name": drain_prs.CHANGES_LABEL},
                ]
            }
        )

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
        self.assertEqual(result["reason"], "changes_requested")
        self.assertIn(drain_prs.CHANGES_LABEL, result["message"])
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])

    def test_changes_requested_alone_is_not_reported_as_unapproved(self):
        self.script_pr_view({"labels": [{"name": drain_prs.CHANGES_LABEL}]})

        result, _ = self.run_single()

        self.assertEqual(result["reason"], "changes_requested")

    def test_a_pending_required_check_names_every_configured_check(self):
        rollup = self.base_pr_json()["statusCheckRollup"]
        rollup[0] = {**rollup[0], "status": "IN_PROGRESS", "conclusion": None}
        self.script_pr_view({"statusCheckRollup": rollup})

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
        self.assertEqual(result["reason"], "checks_pending")
        self.assertIn(f"{drain_prs.DEFAULT_REQUIRED_CI_CHECK}=pending", result["message"])
        self.assertIn(
            f"{drain_prs.DEFAULT_REQUIRED_REVIEW_CHECK}=success", result["message"]
        )
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])

    def test_a_required_check_that_never_reported_waits_and_keeps_saying_missing(self):
        rollup = [
            item
            for item in self.base_pr_json()["statusCheckRollup"]
            if item["name"] != drain_prs.DEFAULT_REQUIRED_CI_CHECK
        ]
        self.script_pr_view({"statusCheckRollup": rollup})

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
        self.assertEqual(result["reason"], "checks_pending")
        self.assertIn(f"{drain_prs.DEFAULT_REQUIRED_CI_CHECK}=missing", result["message"])

    def test_a_failed_required_check_is_reported_as_a_failure(self):
        rollup = self.base_pr_json()["statusCheckRollup"]
        rollup[0] = {**rollup[0], "conclusion": "FAILURE"}
        self.script_pr_view({"statusCheckRollup": rollup})

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
        self.assertEqual(result["reason"], "checks_failed")
        self.assertIn(drain_prs.DEFAULT_REQUIRED_CI_CHECK, result["message"])
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])

    def test_two_failing_checks_are_both_named_in_one_message(self):
        rollup = [
            {**item, "conclusion": "FAILURE"}
            for item in self.base_pr_json()["statusCheckRollup"]
        ]
        self.script_pr_view({"statusCheckRollup": rollup})

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
        self.assertEqual(result["reason"], "checks_failed")
        # CI is still named first, but the review gate's state travels with it.
        self.assertIn(f"{drain_prs.DEFAULT_REQUIRED_CI_CHECK}=failure", result["message"])
        self.assertIn(
            f"{drain_prs.DEFAULT_REQUIRED_REVIEW_CHECK}=failure", result["message"]
        )
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])

    def test_a_conflicted_pr_is_reported_and_left_alone(self):
        self.script_pr_view(
            {"mergeable": "CONFLICTING", "mergeStateStatus": "DIRTY"}
        )

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
        self.assertEqual(result["reason"], "merge_conflict")
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])
        # Same incident the queue raises, from the same code path.
        incidents = self.open_incidents()
        self.assertEqual([item["pull_request"] for item in incidents], [42])
        self.assertEqual(
            incidents[0]["kind"], drain_prs_service.CONFLICT_INCIDENT_KIND
        )

    def test_a_pr_behind_the_base_updates_its_branch_and_stops_for_this_run(self):
        moved_head = "c" * 40
        settled = {
            "headRefOid": moved_head,
            "statusCheckRollup": [
                *self.base_pr_json()["statusCheckRollup"],
                {
                    "name": drain_prs.STALE_APPROVAL_CHECK,
                    "status": "COMPLETED",
                    "conclusion": "SUCCESS",
                    "completedAt": "2026-07-18T00:00:02Z",
                },
            ],
        }
        self.script_pr_view(
            {"mergeStateStatus": "BEHIND"},
            {"mergeStateStatus": "BEHIND"},
            settled,
        )
        self.fake.script("gh", ["api", "-X", "PUT"], stdout="{}")

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
        self.assertEqual(result["reason"], "behind_base")
        self.assertEqual(len(self.gh_calls("api", "-X", "PUT")), 1)
        # One cycle does one thing: the update happened, the merge did not.
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])
        # The workflow kept the label, so approval carries on the workflow's
        # own verdict -- the drainer writes no label to reach that outcome.
        self.assertEqual(self.label_edits(), [])
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(state["prs"]["42"]["approved_head"], moved_head)

    def test_a_branch_update_that_lost_its_approval_is_left_unapproved(self):
        """Issue #230: a successful `dismiss-stale-approval` run says the
        invalidation policy finished, not that the new head was reviewed. When
        that run removed the label -- the decision that this push touched
        PR-owned files -- the drainer must not put it back, and must record no
        approved head for a commit no review covers."""
        moved_head = "c" * 40
        settled = {
            "headRefOid": moved_head,
            "labels": [],
            "statusCheckRollup": [
                *self.base_pr_json()["statusCheckRollup"],
                {
                    "name": drain_prs.STALE_APPROVAL_CHECK,
                    "status": "COMPLETED",
                    "conclusion": "SUCCESS",
                    "completedAt": "2026-07-18T00:00:02Z",
                },
            ],
        }
        self.script_pr_view(
            {"mergeStateStatus": "BEHIND"},
            {"mergeStateStatus": "BEHIND"},
            settled,
        )
        self.fake.script("gh", ["api", "-X", "PUT"], stdout="{}")

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
        self.assertEqual(result["reason"], "behind_base")
        self.assertEqual(len(self.gh_calls("api", "-X", "PUT")), 1)
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])
        self.assertEqual(self.label_edits(), [])
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertNotEqual(
            state["prs"].get("42", {}).get("approved_head"), moved_head
        )

    def test_a_head_pushed_during_the_branch_update_is_not_recorded_approved(self):
        """Issue #230: the policy verdict, the label that survived it, and the
        head recorded from them all have to be the same head. A push landing
        between the settled run and the state write gets its own review."""
        moved_head = "c" * 40
        newer_head = "d" * 40
        stale_approval_ok = [
            *self.base_pr_json()["statusCheckRollup"],
            {
                "name": drain_prs.STALE_APPROVAL_CHECK,
                "status": "COMPLETED",
                "conclusion": "SUCCESS",
                "completedAt": "2026-07-18T00:00:02Z",
            },
        ]
        self.script_pr_view(
            {"mergeStateStatus": "BEHIND"},
            {"mergeStateStatus": "BEHIND"},
            {"headRefOid": moved_head, "statusCheckRollup": stale_approval_ok},
            # The label is still attached and the earlier run is still the
            # latest non-skipped result, so nothing but the head says this
            # commit was never the one the policy decided about.
            {"headRefOid": newer_head, "statusCheckRollup": stale_approval_ok},
        )
        self.fake.script("gh", ["api", "-X", "PUT"], stdout="{}")

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
        self.assertEqual(result["reason"], "behind_base")
        self.assertEqual(self.label_edits(), [])
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        recorded = state["prs"].get("42", {}).get("approved_head")
        self.assertNotEqual(recorded, newer_head)
        self.assertNotEqual(recorded, moved_head)

    def test_mergeability_still_computing_waits(self):
        self.script_pr_view({"mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN"})

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
        self.assertEqual(result["reason"], "mergeability_computing")
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])

    def test_an_approval_still_attached_to_an_unapproved_head_is_refused(self):
        self.write_state(
            {
                "version": drain_prs.STATE_VERSION,
                "attempt_counter": 0,
                "prs": {"42": self.state_entry("d" * 40)},
            }
        )
        self.script_pr_view()

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
        self.assertEqual(result["reason"], "approved_head_changed")
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])
        # Refused before process_pr() even read the PR a second time.
        self.assertEqual(len(self.gh_calls("pr", "view", "42")), 1)

    def test_a_closed_pr_is_not_eligible(self):
        self.script_pr_view({"state": "CLOSED"})

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
        self.assertEqual(result["reason"], "not_eligible")
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])

    def test_a_pr_targeting_another_branch_is_not_eligible(self):
        self.script_pr_view({"baseRefName": "release"})

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
        self.assertEqual(result["reason"], "not_eligible")
        self.assertIn("release", result["message"])
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])

    def test_an_approved_draft_is_marked_ready_before_it_is_processed(self):
        # The draft-readiness safeguard lives in the queue loop, not in
        # process_pr(), so a single-PR run has to apply it too.
        self.script_pr_view({"isDraft": True}, {})
        self.fake.script("gh", ["pr", "ready", "42"], stdout="")
        self.script_merge_and_cleanup()

        result, proc = self.run_single()

        self.assertEqual(len(self.gh_calls("pr", "ready", "42")), 1)
        self.assertEqual(proc.returncode, drain_prs.EXIT_MERGED)
        self.assertEqual(result["reason"], "merged")


class SinglePrFinalGateTests(SinglePrCliFixture):
    """The gate re-check immediately before the admin merge, reported with the
    same precision as the first read."""

    def test_an_approval_withdrawn_before_the_merge_is_reported(self):
        self.script_pr_view({}, {}, {"labels": []})

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
        self.assertEqual(result["reason"], "not_approved")
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])

    def test_changes_requested_before_the_merge_is_reported_as_such(self):
        self.script_pr_view(
            {},
            {},
            {
                "labels": [
                    {"name": drain_prs.APPROVE_LABEL},
                    {"name": drain_prs.CHANGES_LABEL},
                ]
            },
        )

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
        self.assertEqual(result["reason"], "changes_requested")
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])

    def test_ci_regressing_before_the_merge_is_reported_as_a_failure(self):
        rollup = self.base_pr_json()["statusCheckRollup"]
        regressed = [{**rollup[0], "conclusion": "FAILURE"}, rollup[1]]
        self.script_pr_view({}, {}, {"statusCheckRollup": regressed})

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
        self.assertEqual(result["reason"], "checks_failed")
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])

    def test_the_review_gate_going_pending_before_the_merge_is_reported(self):
        rollup = self.base_pr_json()["statusCheckRollup"]
        regressed = [
            rollup[0],
            {**rollup[1], "status": "IN_PROGRESS", "conclusion": None},
        ]
        self.script_pr_view({}, {}, {"statusCheckRollup": regressed})

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
        self.assertEqual(result["reason"], "checks_pending")
        self.assertIn(drain_prs.DEFAULT_REQUIRED_REVIEW_CHECK, result["message"])
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])

    def test_a_head_that_moves_during_the_merge_is_reported_as_unapproved_head(self):
        self.fake.script(
            "gh", ["pr", "merge", "42"], stdout="", stderr="head mismatch", exit_code=1
        )
        # The queue-safeguard, penultimate and final reads all see the approved
        # head; only merge_pr()'s own re-read afterwards finds it moved.
        self.script_pr_view({}, {}, {}, {"headRefOid": "e" * 40})

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
        self.assertEqual(result["reason"], "approved_head_changed")
        self.assertFalse(result["merged"])


class SinglePrErrorTests(SinglePrCliFixture):
    """Errors: exit 1, and a merge that already landed is still reported."""

    def test_a_post_merge_audit_failure_reports_the_merge_it_cannot_vouch_for(self):
        self.fake.script("gh", ["pr", "merge", "42"], stdout="")
        # Queue safeguard, penultimate and final reads are green; the label is
        # gone only by the time the post-merge audit samples it.
        self.script_pr_view({}, {}, {}, {"labels": []})

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_ERROR)
        self.assert_result(
            result,
            outcome="error",
            reason="post_merge_audit_failed",
            merged=True,
            would_merge=False,
            dry_run=False,
        )
        self.assertEqual(len(self.gh_calls("pr", "merge", "42")), 1)

    def test_an_outstanding_post_merge_cleanup_is_an_error_that_still_reports_the_merge(
        self,
    ):
        # The queue would retry this next cycle. A single caller has no next
        # cycle, so it must be told the merge landed and what it still owes.
        self.script_pr_view()
        self.fake.script("gh", ["pr", "merge", "42"], stdout="")
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout="", stderr="gh: boom", exit_code=1
        )

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_ERROR)
        self.assert_result(
            result,
            outcome="error",
            reason="post_merge_cleanup_failed",
            merged=True,
            would_merge=False,
            dry_run=False,
        )
        self.assertIn("99", result["message"])
        self.assertEqual(len(self.gh_calls("pr", "merge", "42")), 1)
        # The debt is durably recorded for the drainer to retry, and the steps
        # that did succeed are not owed again.
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        pending = state["prs"]["42"]["cleanup"]["pending"]
        self.assertEqual([item["kind"] for item in pending], ["issue"])
        self.assertFalse(self.feature_wt.exists())

    def test_a_checkout_off_the_default_branch_is_a_precondition_failure(self):
        run_git(["checkout", "-q", "-b", "hotfix"], cwd=self.main)

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_ERROR)
        self.assertEqual(result["reason"], "repository_precondition_failed")
        self.assertIn("hotfix", result["message"])
        self.assertEqual(self.fake.calls("gh"), [])

    def test_a_dirty_checkout_merges_and_keeps_every_local_change(self):
        # Inverted from the removed blanket gate: merging is GitHub's, and the
        # post-merge fast-forward already stashes and restores whatever is in
        # the tree, so local work is no reason to refuse.
        self.dirty_the_checkout()
        self.script_pr_view()
        self.script_merge_and_cleanup()

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_MERGED)
        self.assertTrue(result["merged"])
        self.assertEqual(len(self.gh_calls("pr", "merge", "42")), 1)
        # The fast-forward still landed, with every local change intact on
        # the new tip.
        self.assertEqual(
            run_git(["rev-parse", "master"], cwd=self.main), self.merge_commit_sha
        )
        self.assertEqual(
            (self.main / "README").read_text(encoding="utf-8"), "hello, edited\n"
        )
        self.assertEqual(
            (self.main / "staged.txt").read_text(encoding="utf-8"), "staged\n"
        )
        self.assertIn(
            "staged.txt",
            run_git(["diff", "--cached", "--name-only"], cwd=self.main).splitlines(),
        )
        self.assertEqual(
            (self.main / "scratch.txt").read_text(encoding="utf-8"), "untracked\n"
        )
        self.assertIn(
            "?? scratch.txt",
            run_git(["status", "--porcelain=v1"], cwd=self.main).splitlines(),
        )

    def test_an_unfinished_git_operation_is_a_precondition_failure(self):
        # The one repository condition still worth refusing: the fast-forward
        # cannot succeed until a human resolves it, so every merge in the run
        # would fail the same avoidable way.
        run_git(["checkout", "-q", "-b", "side"], cwd=self.main)
        (self.main / "README").write_text("side\n", encoding="utf-8")
        run_git(["commit", "-q", "-am", "side edit"], cwd=self.main)
        run_git(["checkout", "-q", "master"], cwd=self.main)
        (self.main / "README").write_text("master\n", encoding="utf-8")
        run_git(["commit", "-q", "-am", "master edit"], cwd=self.main)
        subprocess.run(
            ["git", "merge", "side"], cwd=str(self.main), capture_output=True
        )
        conflicted = (self.main / "README").read_bytes()
        index_before = hashlib.sha256(
            (self.main / ".git" / "index").read_bytes()
        ).hexdigest()

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_ERROR)
        self.assertEqual(result["reason"], "repository_precondition_failed")
        self.assertIn("merge is in progress", result["message"])
        self.assertEqual(self.fake.calls("gh"), [])
        # Byte for byte intact: no `git reset --hard` ran, and nothing
        # refreshed the index behind the unresolved conflict.
        self.assertTrue((self.main / ".git" / "MERGE_HEAD").exists())
        self.assertEqual((self.main / "README").read_bytes(), conflicted)
        self.assertEqual(
            hashlib.sha256((self.main / ".git" / "index").read_bytes()).hexdigest(),
            index_before,
        )

    def test_an_unparseable_queue_state_is_reported_without_being_overwritten(self):
        # That file holds every other PR's cooldowns and unfinished post-merge
        # cleanups, so a run that cannot read it must not replace it.
        self.state_path.write_text("{not json", encoding="utf-8")
        before = self.state_path.read_bytes()
        self.script_pr_view()

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_ERROR)
        self.assertEqual(result["reason"], "operational_error")
        self.assertEqual(self.state_path.read_bytes(), before)
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])

    def test_an_unreadable_pull_request_is_an_operational_error(self):
        self.fake.script(
            "gh", ["pr", "view", "42"], stdout="", stderr="gh: boom", exit_code=1
        )

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_ERROR)
        self.assertEqual(result["reason"], "operational_error")
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])


class SinglePrRepositoryIdentityTests(SinglePrCliFixture):
    """`--repo` asserts which repository `--path` is a checkout of.

    A caller resolves the repository through its own configuration -- Kanban's
    `--repo OWNER/NAME`, or the remote a `--config` names -- so it can be
    showing a repository this checkout's remote does not name. A pull request
    number means nothing across that gap, and merging #42 here on the strength
    of #42 there is exactly what the assertion prevents.
    """

    def test_the_asserted_identity_matching_the_checkout_changes_nothing(self):
        self.script_pr_view()
        self.script_merge_and_cleanup()

        result, proc = self.run_single("--repo", "acme/widgets")

        self.assertEqual(proc.returncode, drain_prs.EXIT_MERGED)
        self.assertEqual(result["reason"], "merged")
        self.assertTrue(result["merged"])

    def test_a_case_different_spelling_names_the_same_repository(self):
        # GitHub owner and repository names are case-insensitive, so two
        # spellings that differ only in case name one repository and must not
        # be read as a mismatch.
        self.script_pr_view()
        self.script_merge_and_cleanup()

        result, proc = self.run_single("--repo", "ACME/Widgets")

        self.assertEqual(proc.returncode, drain_prs.EXIT_MERGED)
        self.assertTrue(result["merged"])

    def test_another_repository_is_refused_before_the_pull_request_is_read(self):
        self.script_pr_view()
        self.script_merge_and_cleanup()

        result, proc = self.run_single("--repo", "other/thing")

        self.assertEqual(proc.returncode, drain_prs.EXIT_ERROR)
        self.assert_result(
            result,
            outcome="error",
            reason="repository_precondition_failed",
            merged=False,
            would_merge=False,
            dry_run=False,
        )
        # Both identities, so the message says which side to change.
        self.assertIn("other/thing", result["message"])
        self.assertIn("acme/widgets", result["message"])
        # Nothing was read or merged: the refusal lands before the pull
        # request is fetched at all.
        self.assertEqual(self.gh_calls("pr", "view", "42"), [])
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])

    def test_a_value_that_names_no_repository_is_a_precondition_failure(self):
        self.script_pr_view()

        result, proc = self.run_single("--repo", "not-an-identity")

        self.assertEqual(proc.returncode, drain_prs.EXIT_ERROR)
        self.assertEqual(result["reason"], "repository_precondition_failed")
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])

    def test_the_polling_mode_is_held_to_the_same_assertion(self):
        # The check sits with the repository context rather than with `--pr`,
        # so a poll cycle cannot drain a repository the caller did not name.
        self.script_pr_view()
        self.script_merge_and_cleanup()

        proc = self.run_cli("--once", "--repo", "other/thing")

        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("other/thing", proc.stderr)
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])


class SinglePrRunLockTests(SinglePrCliFixture):
    """One lock covers both modes, and whichever starts second names the
    other rather than proceeding."""

    def hold(self, **kwargs):
        handle = drain_prs.acquire_lock(self.main, **kwargs)
        self.addCleanup(handle.close)
        return handle

    def test_a_single_pr_run_refuses_while_the_polling_drainer_holds_the_lock(self):
        self.hold(mode="polling")
        self.script_pr_view()

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_ERROR)
        self.assert_result(
            result,
            outcome="error",
            reason="run_locked",
            merged=False,
            would_merge=False,
            dry_run=False,
        )
        self.assertIn("polling drainer", result["message"])
        self.assertIn(str(os.getpid()), result["message"])
        # Refused before acting: no GitHub read, no state file.
        self.assertEqual(self.fake.calls("gh"), [])
        self.assertFalse(self.state_path.exists())

    def test_the_polling_drainer_refuses_while_a_single_pr_run_holds_the_lock(self):
        self.hold(mode="single-pr", pull_request=42)

        proc = self.run_cli("--once")

        self.assertEqual(proc.returncode, 1)
        self.assertIn("already running", proc.stderr)
        self.assertIn("single-PR run for PR #42", proc.stderr)
        self.assertEqual(self.fake.calls("gh"), [])

    def test_a_dry_run_holding_the_lock_still_excludes_a_real_run(self):
        # The exclusion cannot depend on a lock file existing: a dry run
        # creates none, and a repository the drainer has never run in has
        # none either.
        self.assertFalse(self.lock_path.exists())
        self.hold(dry_run=True)
        self.assertFalse(self.lock_path.exists())
        self.script_pr_view()

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_ERROR)
        self.assertEqual(result["reason"], "run_locked")
        # A dry run publishes no identity precisely because it writes nothing,
        # so it is named by that absence rather than left anonymous.
        self.assertIn("dry-run inspection", result["message"])
        self.assertEqual(self.fake.calls("gh"), [])
        self.assertFalse(self.state_path.exists())

    def test_a_real_run_that_has_not_published_yet_is_not_called_a_dry_run(self):
        # The pre-publication window: a real run holds the lock file but has
        # written no PID. Because a real run takes the file before the
        # directory, and a dry run never takes the file at all, holding the
        # file is already enough to tell them apart.
        fd = os.open(self.lock_path, os.O_RDWR | os.O_CREAT, 0o644)
        self.addCleanup(os.close, fd)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertEqual(self.lock_path.read_bytes(), b"")

        holder = drain_prs.describe_lock_holder(self.main)

        self.assertNotIn("dry-run", holder)
        self.assertIn("starting up", holder)

        # And the same through the CLI, which loses on that very file lock.
        self.script_pr_view()
        result, proc = self.run_single()
        self.assertEqual(proc.returncode, drain_prs.EXIT_ERROR)
        self.assertEqual(result["reason"], "run_locked")
        self.assertNotIn("dry-run", result["message"])
        self.assertEqual(self.fake.calls("gh"), [])

    def test_a_real_run_holds_the_lock_file_before_the_directory(self):
        # The ordering is what makes the identification atomic, so it is
        # asserted rather than left to the comment that explains it.
        self.hold(mode="polling")
        self.assertTrue(drain_prs.lock_file_is_held(self.main))

    def test_a_dry_run_holds_the_directory_alone(self):
        self.hold(dry_run=True)
        self.assertFalse(drain_prs.lock_file_is_held(self.main))
        self.assertIn(
            "dry-run inspection", drain_prs.describe_lock_holder(self.main)
        )

    def test_a_dry_run_holding_the_lock_is_named_over_a_dead_run_s_leftovers(self):
        # A stale PID file from a crashed run must not be mistaken for the
        # live holder, which is the dry run.
        self.lock_path.write_text("999999", encoding="utf-8")
        drain_prs.lock_owner_path_for(self.main).write_text(
            json.dumps({"pid": 999999, "mode": "polling", "pull_request": None}),
            encoding="utf-8",
        )
        self.hold(dry_run=True)
        self.script_pr_view()

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_ERROR)
        self.assertEqual(result["reason"], "run_locked")
        self.assertIn("dry-run inspection", result["message"])
        self.assertNotIn("polling drainer", result["message"])
        self.assertEqual(self.fake.calls("gh"), [])

    def test_a_dry_run_is_excluded_by_a_real_run_that_left_no_lock_file_yet(self):
        self.assertFalse(self.lock_path.exists())
        self.hold(mode="polling")
        self.script_pr_view()

        result, proc = self.run_single("--dry-run")

        self.assertEqual(proc.returncode, drain_prs.EXIT_ERROR)
        self.assertEqual(result["reason"], "run_locked")
        self.assertTrue(result["dry_run"])
        self.assertEqual(self.fake.calls("gh"), [])

    def test_the_lock_file_still_holds_exactly_the_bare_pid(self):
        # drain_prs_service.lock_pid() and
        # install_drainer.repository_drainer_running() both read it that way.
        self.hold(mode="single-pr", pull_request=42)

        self.assertEqual(
            self.lock_path.read_text(encoding="utf-8"), str(os.getpid())
        )
        self.assertEqual(drain_prs_service.lock_pid(self.main), os.getpid())

    def test_a_stale_owner_sidecar_is_not_believed(self):
        drain_prs.lock_owner_path_for(self.main).write_text(
            json.dumps({"pid": 999999, "mode": "single-pr", "pull_request": 7}),
            encoding="utf-8",
        )
        self.hold(mode="polling")
        # Rewritten by the acquisition above, so the holder is described
        # correctly rather than from the leftover record.
        self.assertIn("polling drainer", drain_prs.describe_lock_holder(self.main))


class SinglePrStartupAndInterruptTests(SinglePrCliFixture):
    """Nothing gets to end a `--pr` run without a result document: not an
    interrupt, and not a failure in the drainer's own startup."""

    def run_main(self, *argv_extra):
        """Drive main() in-process, so an interrupt can be placed exactly."""
        saved = (
            drain_prs.LOG_DIR,
            drain_prs.LOG_TO_STDERR,
            drain_prs.APPROVE_LABEL,
            drain_prs.CHANGES_LABEL,
        )

        def restore():
            (
                drain_prs.LOG_DIR,
                drain_prs.LOG_TO_STDERR,
                drain_prs.APPROVE_LABEL,
                drain_prs.CHANGES_LABEL,
            ) = saved

        self.addCleanup(restore)
        argv = [
            "drain_prs.py",
            "--path",
            str(self.main),
            "--config",
            str(self.absent_config),
            "--log-dir",
            str(self.log_dir),
            *argv_extra,
        ]
        env = {
            **self.fake.environ_overrides(),
            "KANBAN_DRAINER_INSTALL_DIR": str(self.install_dir),
        }
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.object(sys, "argv", argv), mock.patch.dict(
            os.environ, env
        ), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            with self.assertRaises(SystemExit) as raised:
                drain_prs.main()
        # Kept for the tests that assert *where* a diagnostic went, not only
        # that the result document survived.
        self.raw_stdout = stdout.getvalue()
        self.raw_stderr = stderr.getvalue()
        return json.loads(self.raw_stdout.strip()), raised.exception.code

    def test_an_interrupt_before_the_pull_request_is_read_still_reports(self):
        with mock.patch.object(drain_prs, "repo_root", side_effect=KeyboardInterrupt):
            result, code = self.run_main("--pr", "42")

        self.assertEqual(code, drain_prs.EXIT_ERROR)
        self.assertEqual(result["outcome"], "error")
        self.assertEqual(result["reason"], "operational_error")
        self.assertFalse(result["merged"])

    def test_an_interrupt_after_the_merge_landed_still_reports_it_as_merged(self):
        self.script_pr_view()
        self.fake.script("gh", ["pr", "merge", "42"], stdout="")
        # Interrupts the very first step after the merge call returns.
        with mock.patch.object(
            drain_prs, "plan_cleanup", side_effect=KeyboardInterrupt
        ):
            result, code = self.run_main("--pr", "42")

        self.assertEqual(code, drain_prs.EXIT_ERROR)
        self.assertEqual(result["outcome"], "error")
        self.assertEqual(result["reason"], "operational_error")
        self.assertTrue(result["merged"])
        self.assertEqual(len(self.gh_calls("pr", "merge", "42")), 1)

    def test_an_interrupt_during_the_post_merge_audit_still_reports_the_merge(self):
        # GitHub accepted the merge before the audit began, so the caller must
        # learn that even though the run never got to say so itself.
        self.script_pr_view()
        self.fake.script("gh", ["pr", "merge", "42"], stdout="")
        with mock.patch.object(
            drain_prs, "audit_merged_pr", side_effect=KeyboardInterrupt
        ):
            result, code = self.run_main("--pr", "42")

        self.assertEqual(code, drain_prs.EXIT_ERROR)
        self.assertEqual(result["outcome"], "error")
        self.assertTrue(result["merged"])
        self.assertEqual(len(self.gh_calls("pr", "merge", "42")), 1)

    def test_an_interrupt_while_persisting_after_a_merge_still_reports_it(self):
        self.script_pr_view()
        self.fake.script("gh", ["pr", "merge", "42"], stdout="")
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout=json.dumps({"state": "CLOSED"})
        )
        with mock.patch.object(
            drain_prs, "save_drain_state", side_effect=KeyboardInterrupt
        ):
            result, code = self.run_main("--pr", "42")

        self.assertEqual(code, drain_prs.EXIT_ERROR)
        self.assertEqual(result["outcome"], "error")
        self.assertTrue(result["merged"])

    def test_an_interrupt_escaping_the_run_entirely_still_reports_a_merge(self):
        # The report belongs to main(), so nothing that ends the run can throw
        # away the fact that GitHub already accepted the merge.
        def interrupt_after_merging(ctx, number, *, dry_run, gates, report):
            report["merged"] = True
            raise KeyboardInterrupt

        with mock.patch.object(
            drain_prs, "drain_one_pr", side_effect=interrupt_after_merging
        ):
            result, code = self.run_main("--pr", "42")

        self.assertEqual(code, drain_prs.EXIT_ERROR)
        self.assertEqual(result["outcome"], "error")
        self.assertTrue(result["merged"])

    def _state_owing_one_issue_close(self):
        """Queue state recording a merged PR #7 that still owes one issue
        close, as a merge whose cleanup did not finish leaves behind."""
        record = drain_prs.plan_cleanup(
            {
                "number": 7,
                "headRefName": "issue-7-departed",
                "headRefOid": "b" * 40,
                "closingIssuesReferences": [
                    {
                        "number": 7,
                        "repository": {"owner": {"login": "acme"}, "name": "widgets"},
                    }
                ],
            }
        )
        record["pending"] = [
            item for item in record["pending"] if item["kind"] == "issue"
        ]
        entry = self.state_entry("b" * 40)
        entry["cleanup"] = record
        self.write_state(
            {
                "version": drain_prs.STATE_VERSION,
                "attempt_counter": 0,
                "prs": {"7": entry},
            }
        )
        self.fake.script(
            "gh", ["issue", "view", "7"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script("gh", ["issue", "close", "7"], stdout="")

    def _assert_debt_discharged(self):
        self.assertEqual(len(self.gh_calls("issue", "close", "7")), 1)
        self.assertNotIn(
            "7", json.loads(self.state_path.read_text(encoding="utf-8"))["prs"]
        )

    def test_an_interrupt_inside_the_run_still_discharges_recorded_cleanup(self):
        # drain_one_pr() swallows the interrupt to keep this caller's one
        # result document, so main()'s own handler never sees it. The stop it
        # signals still owes the final pass, and the pass must still run.
        self._state_owing_one_issue_close()

        with mock.patch.object(
            drain_prs, "prepare_single_pr", side_effect=KeyboardInterrupt
        ):
            result, code = self.run_main("--pr", "42")

        self._assert_debt_discharged()
        self.assertEqual(code, drain_prs.EXIT_ERROR)
        self.assertEqual(result["reason"], "operational_error")
        # And stdout still carries exactly one document: the caller's result.
        self.assertEqual(len(self.raw_stdout.strip().splitlines()), 1)
        self.assertEqual(json.loads(self.raw_stdout.strip()), result)
        self.assertNotIn("cleanup", self.raw_stdout)
        self.assertIn("post-merge cleanup", self.raw_stderr)

    def test_an_interrupt_escaping_the_run_discharges_it_too(self):
        # The other half of the same shutdown boundary: an interrupt that
        # reaches main()'s handler instead, as one arriving outside
        # drain_one_pr()'s own try does.
        self._state_owing_one_issue_close()

        with mock.patch.object(
            drain_prs, "drain_one_pr", side_effect=KeyboardInterrupt
        ):
            result, code = self.run_main("--pr", "42")

        self._assert_debt_discharged()
        self.assertEqual(code, drain_prs.EXIT_ERROR)
        self.assertEqual(len(self.raw_stdout.strip().splitlines()), 1)
        self.assertEqual(json.loads(self.raw_stdout.strip()), result)

    def _assert_one_result_document(self, result, code):
        """Issue #281: whatever the final cleanup pass is interrupted doing,
        the caller still gets its one document -- not a traceback over an
        empty stdout, which is what an escape from the pass produced."""
        self.assertEqual(code, drain_prs.EXIT_ERROR)
        self.assertEqual(result["outcome"], "error")
        self.assertEqual(result["reason"], "operational_error")
        self.assertEqual(len(self.raw_stdout.strip().splitlines()), 1)
        self.assertEqual(json.loads(self.raw_stdout.strip()), result)
        self.assertNotIn("cleanup", self.raw_stdout)

    def test_a_repeated_interrupt_reading_the_state_still_reports(self):
        # Repeated for real, end to end: the first interrupt is the stop that
        # sends the run to the shutdown boundary, and the second lands inside
        # the pass that boundary runs -- here in its state read.
        self._state_owing_one_issue_close()

        with mock.patch.object(
            drain_prs, "load_drain_state", side_effect=KeyboardInterrupt
        ):
            result, code = self.run_main("--pr", "42")

        self._assert_one_result_document(result, code)

    def test_a_repeated_interrupt_working_the_cleanup_still_reports(self):
        self._state_owing_one_issue_close()

        with mock.patch.object(
            drain_prs, "prepare_single_pr", side_effect=KeyboardInterrupt
        ), mock.patch.object(
            drain_prs, "complete_pending_cleanup", side_effect=KeyboardInterrupt
        ):
            result, code = self.run_main("--pr", "42")

        self._assert_one_result_document(result, code)
        # Interrupted before it could discharge anything, so the debt is left
        # recorded for the next start.
        self.assertEqual(self.gh_calls("issue", "close", "7"), [])
        record = json.loads(self.state_path.read_text(encoding="utf-8"))["prs"]["7"]
        self.assertEqual(
            record["cleanup"]["pending"],
            [{"kind": "issue", "repo": "acme/widgets", "number": 7}],
        )
        self.assertIn("post-merge cleanup", self.raw_stderr)

    def test_a_repeated_interrupt_persisting_the_pass_still_reports(self):
        self._state_owing_one_issue_close()

        with mock.patch.object(
            drain_prs, "prepare_single_pr", side_effect=KeyboardInterrupt
        ), mock.patch.object(
            drain_prs, "save_drain_state", side_effect=KeyboardInterrupt
        ):
            result, code = self.run_main("--pr", "42")

        self._assert_one_result_document(result, code)
        # The obligation was worked before the write was interrupted; only the
        # record of it is lost, which the next start re-verifies.
        self.assertEqual(len(self.gh_calls("issue", "close", "7")), 1)

    def test_valid_json_that_is_not_a_valid_queue_state_is_reported(self):
        # These decode cleanly and used to blow up as AttributeError or
        # KeyError wherever the shape was first touched.
        shapes = {
            "top level is not an object": "[]",
            "entries are not objects": '{"version": 3, "prs": {"42": []}}',
            "entry has no approved head": '{"version": 3, "prs": {"42": {}}}',
            "attempt counter is not a number": (
                '{"version": 3, "attempt_counter": "x", "prs": {}}'
            ),
        }
        for label, text in shapes.items():
            with self.subTest(shape=label):
                self.setUp()
                self.state_path.write_text(text, encoding="utf-8")
                before = self.state_path.read_bytes()
                self.script_pr_view()

                result, proc = self.run_single()

                self.assertEqual(proc.returncode, drain_prs.EXIT_ERROR)
                self.assertNotIn("Traceback", proc.stderr)
                self.assertEqual(result["outcome"], "error")
                self.assertEqual(result["reason"], "operational_error")
                self.assertEqual(self.gh_calls("pr", "merge", "42"), [])
                self.assertEqual(self.state_path.read_bytes(), before)

    def test_an_unexpected_failure_still_produces_one_result_document(self):
        with mock.patch.object(
            drain_prs, "load_gate_config", side_effect=ValueError("boom")
        ):
            result, code = self.run_main("--pr", "42")

        self.assertEqual(code, drain_prs.EXIT_ERROR)
        self.assertEqual(result["outcome"], "error")
        self.assertEqual(result["reason"], "operational_error")
        self.assertIn("boom", result["message"])

    def test_an_unwritable_log_directory_is_reported_rather_than_raised(self):
        blocked = self.root / "not-a-directory"
        blocked.write_text("", encoding="utf-8")
        self.script_pr_view()

        proc = self.run_cli(
            "--pr", "42", "--log-dir", str(blocked), log_dir=False
        )

        self.assertEqual(proc.returncode, drain_prs.EXIT_ERROR)
        self.assertNotIn("Traceback", proc.stderr)
        result = json.loads(proc.stdout.strip())
        self.assertEqual(result["outcome"], "error")
        self.assertEqual(result["reason"], "operational_error")
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])


class SinglePrIsolationTests(SinglePrCliFixture):
    """A single-PR run touches only the PR it was given."""

    def test_no_other_pr_is_enumerated_recovered_or_given_a_turn(self):
        before = {
            "version": drain_prs.STATE_VERSION,
            "attempt_counter": 17,
            "prs": {
                "7": {
                    **self.state_entry("a" * 40),
                    "consecutive_failures": 3,
                    "retry_after_attempt": 40,
                    "last_attempt": 12,
                    "last_error": "boom",
                },
                "8": self.state_entry("b" * 40),
                "42": self.state_entry(self.head_sha),
            },
        }
        self.write_state(before)
        self.script_pr_view()
        self.script_merge_and_cleanup()

        result, proc = self.run_single()

        self.assertEqual(proc.returncode, drain_prs.EXIT_MERGED)
        self.assertEqual(result["reason"], "merged")
        after = json.loads(self.state_path.read_text(encoding="utf-8"))
        # The other PRs' cooldowns and the shared pass counter they are
        # denominated in are exactly as the polling service left them.
        self.assertEqual(after["attempt_counter"], 17)
        self.assertIsNone(after["active_pr"])
        self.assertEqual(after["prs"]["7"], before["prs"]["7"])
        self.assertEqual(after["prs"]["8"], before["prs"]["8"])
        # The queue's own listing and stale-approval sweep never ran.
        self.assertEqual(self.gh_calls("pr", "list"), [])
        self.assertEqual(self.gh_calls("pr", "view", "7"), [])
        self.assertEqual(self.gh_calls("pr", "view", "8"), [])

    def test_a_failed_attempt_applies_no_cooldown_to_the_selected_pr(self):
        self.write_state(
            {
                "version": drain_prs.STATE_VERSION,
                "attempt_counter": 5,
                "prs": {"42": self.state_entry(self.head_sha)},
            }
        )
        rollup = self.base_pr_json()["statusCheckRollup"]
        rollup[0] = {**rollup[0], "conclusion": "FAILURE"}
        self.script_pr_view({"statusCheckRollup": rollup})

        result, _ = self.run_single()

        self.assertEqual(result["reason"], "checks_failed")
        after = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(after["attempt_counter"], 5)
        self.assertEqual(after["prs"]["42"]["consecutive_failures"], 0)
        self.assertEqual(after["prs"]["42"]["retry_after_attempt"], 0)


class SinglePrDryRunPurityTests(SinglePrCliFixture):
    """A dry run reports the same outcome and changes nothing at all.

    The script is run from a copy committed *inside* the repository under
    test, which is how the drainer runs against its own checkout -- so the log
    directory, the bytecode cache and the lock file all land inside the tree
    being compared byte for byte.
    """

    def setUp(self):
        super().setUp()
        tools = self.main / "tools"
        tools.mkdir()
        for name in SCRIPT_MODULES:
            shutil.copy2(TOOLS_DIR / name, tools / name)
        (self.main / ".gitignore").write_text("__pycache__/\n", encoding="utf-8")
        run_git(["add", "tools", ".gitignore"], cwd=self.main)
        run_git(["commit", "-q", "-m", "vendor the drainer"], cwd=self.main)
        self.embedded_script = tools / "drain_prs.py"

    def settled_snapshot(self):
        # Deliberately leaves the index's stat cache stale: a plain `git
        # status` would refresh it and rewrite .git/index, so this is the
        # state in which a dry run's cleanliness check has to prove it reads
        # without writing. Settling it first would hide exactly that.
        readme = self.main / "README"
        stamp = readme.stat().st_mtime - 120
        os.utime(readme, (stamp, stamp))
        return snapshot_tree(self.main)

    def run_pure(self, *extra):
        before = self.settled_snapshot()
        result, proc = self.run_single(
            "--dry-run", *extra, script=self.embedded_script, log_dir=False
        )
        self.assertEqual(snapshot_tree(self.main), before)
        return result, proc

    def test_a_dry_run_that_would_merge_makes_no_mutation(self):
        self.script_pr_view()
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout=json.dumps({"state": "OPEN"})
        )

        result, proc = self.run_pure()

        self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
        self.assert_result(
            result,
            outcome="no_action",
            reason="would_merge",
            merged=False,
            would_merge=True,
            dry_run=True,
        )
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])
        self.assertEqual(self.gh_calls("issue", "close", "99"), [])
        self.assertTrue(self.feature_wt.exists())
        self.assertFalse(self.lock_path.exists())
        self.assertFalse(self.state_path.exists())

    def test_a_dry_run_against_a_dirty_checkout_makes_no_mutation(self):
        # The removed gate needed --no-optional-locks to keep its `git status`
        # probe from rewriting .git/index. Its replacement reads marker paths
        # and runs no status at all, so purity holds structurally -- and this
        # is the tree state in which that has to be proved.
        self.dirty_the_checkout()
        self.script_pr_view()
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout=json.dumps({"state": "OPEN"})
        )

        result, proc = self.run_pure()

        self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
        self.assertEqual(result["reason"], "would_merge")
        self.assertTrue(result["dry_run"])
        self.assertEqual(self.gh_calls("pr", "merge", "42"), [])
        self.assertFalse(self.lock_path.exists())

    def test_every_blocked_condition_dry_runs_without_mutating(self):
        rollup = self.base_pr_json()["statusCheckRollup"]
        scenarios = {
            "not_approved": {"labels": []},
            "changes_requested": {"labels": [{"name": drain_prs.CHANGES_LABEL}]},
            "checks_failed": {
                "statusCheckRollup": [{**rollup[0], "conclusion": "FAILURE"}, rollup[1]]
            },
            "checks_pending": {
                "statusCheckRollup": [
                    {**rollup[0], "status": "IN_PROGRESS", "conclusion": None},
                    rollup[1],
                ]
            },
            "merge_conflict": {"mergeable": "CONFLICTING", "mergeStateStatus": "DIRTY"},
            "behind_base": {"mergeStateStatus": "BEHIND"},
            "mergeability_computing": {
                "mergeable": "UNKNOWN",
                "mergeStateStatus": "UNKNOWN",
            },
            "not_eligible": {"state": "CLOSED"},
        }
        for reason, override in scenarios.items():
            with self.subTest(reason=reason):
                self.setUp()
                self.script_pr_view(override)

                result, proc = self.run_pure()

                self.assertEqual(result["reason"], reason)
                self.assertEqual(proc.returncode, drain_prs.EXIT_NO_ACTION)
                self.assertFalse(result["merged"])
                self.assertFalse(result["would_merge"])
                self.assertTrue(result["dry_run"])
                self.assertEqual(self.gh_calls("pr", "merge", "42"), [])
                self.assertEqual(self.open_incidents(), [])

    def test_a_polling_dry_run_is_just_as_pure(self):
        # Purity is a property of --dry-run, not of the single-PR mode.
        self.fake.script("gh", ["pr", "list"], stdout=json.dumps([]))
        before = self.settled_snapshot()

        proc = self.run_cli(
            "--once", "--dry-run", script=self.embedded_script, log_dir=False
        )

        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(snapshot_tree(self.main), before)
        self.assertFalse(self.lock_path.exists())

    def test_a_dry_run_still_refuses_while_another_run_holds_the_lock(self):
        handle = drain_prs.acquire_lock(self.main, mode="polling")
        self.addCleanup(handle.close)
        before = self.settled_snapshot()
        self.script_pr_view()

        result, proc = self.run_single(
            "--dry-run", script=self.embedded_script, log_dir=False
        )

        self.assertEqual(proc.returncode, drain_prs.EXIT_ERROR)
        self.assertEqual(result["reason"], "run_locked")
        self.assertTrue(result["dry_run"])
        self.assertEqual(self.fake.calls("gh"), [])
        # Taking the lock is the only thing it did, and that rewrote nothing.
        self.assertEqual(snapshot_tree(self.main), before)

class SinglePrRealInterruptTests(SinglePrCliFixture):
    """A real SIGINT delivered to the real script, mid-`gh` call.

    `stop_service` sends SIGINT straight to an unmanaged drainer, and the
    launchd runner forwards SIGINT to a managed one's process group, so this
    is the signal an intentional stop actually delivers -- arriving where the
    run happens to be rather than at a seam a test chose to raise from.
    """

    def _popen_cli(self, *extra):
        env = dict(os.environ)
        env.update(self.fake.environ_overrides())
        env["KANBAN_DRAINER_INSTALL_DIR"] = str(self.install_dir)
        for name in ("KANBAN_DRAINER_NTFY_URL", "DRAIN_PRS_MANAGED"):
            env.pop(name, None)
        return subprocess.Popen(
            [
                sys.executable,
                str(SCRIPT),
                "--path",
                str(self.main),
                "--config",
                str(self.absent_config),
                "--log-dir",
                str(self.log_dir),
                *extra,
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )

    def _await_gh_call(self, proc, *prefix, timeout=60):
        """Block until the run invokes a command, or say why it never will.

        A run that has already exited is reported with its own output rather
        than as a bare timeout: the interesting failure -- a lock it could not
        take, a checkout it refused -- is in there, and waiting out the
        deadline for it would hide it behind the clock.
        """
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.gh_calls(*prefix):
                return
            if proc.poll() is not None:
                stdout, stderr = proc.communicate()
                self.fail(
                    f"the run exited ({proc.returncode}) before `gh "
                    f"{' '.join(prefix)}`:\n{stdout}\n{stderr}"
                )
            time.sleep(0.05)
        self.fail(f"the run never reached `gh {' '.join(prefix)}`")

    def test_a_real_sigint_discharges_recorded_cleanup_and_still_reports(self):
        # A merge that did not finish its cleanup, exactly as the queue state
        # records it.
        record = drain_prs.plan_cleanup(
            {
                "number": 7,
                "headRefName": "issue-7-departed",
                "headRefOid": "b" * 40,
                "closingIssuesReferences": [
                    {
                        "number": 7,
                        "repository": {"owner": {"login": "acme"}, "name": "widgets"},
                    }
                ],
            }
        )
        record["pending"] = [
            item for item in record["pending"] if item["kind"] == "issue"
        ]
        entry = self.state_entry("b" * 40)
        entry["cleanup"] = record
        self.write_state(
            {
                "version": drain_prs.STATE_VERSION,
                "attempt_counter": 0,
                "prs": {"7": entry},
            }
        )
        # The run blocks here, so the signal lands inside a command it is
        # waiting on rather than between two of them.
        self.fake.script(
            "gh",
            ["pr", "view", "42"],
            stdout=json.dumps(self.base_pr_json()),
            sleep_seconds=60,
        )
        self.fake.script(
            "gh", ["issue", "view", "7"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script("gh", ["issue", "close", "7"], stdout="")

        proc = self._popen_cli("--pr", "42")
        try:
            self._await_gh_call(proc, "pr", "view", "42")
            proc.send_signal(signal.SIGINT)
            stdout, stderr = proc.communicate(timeout=120)
        except BaseException:
            proc.kill()
            raise

        # The recorded debt was discharged on the way out, from the record
        # alone -- no second read of any pull request.
        self.assertEqual(len(self.gh_calls("issue", "close", "7")), 1)
        self.assertNotIn(
            "7", json.loads(self.state_path.read_text(encoding="utf-8"))["prs"]
        )
        # And the caller still got exactly one JSON document on stdout.
        self.assertEqual(len(stdout.strip().splitlines()), 1, stdout)
        result = json.loads(stdout.strip())
        self.assertEqual(result["outcome"], "error")
        self.assertEqual(result["reason"], "operational_error")
        self.assertFalse(result["merged"])
        self.assertEqual(proc.returncode, drain_prs.EXIT_ERROR)
        self.assertNotIn("cleanup", stdout)
        self.assertIn("post-merge cleanup", stderr)


if __name__ == "__main__":
    unittest.main()
