"""Focused tests for tools/drain_prs.py.

Covers the round-10 fix delegating parse_repo_slug to
kanban_config.parse_repository_name, so the drainer accepts the same
broader remote forms (ssh://, http://, git://, bare owner/name) the
dashboard's own parseRepositoryName does, not only
git@github.com:/https://github.com/; the round-13 fix making the spawned
agent prompts pass an explicit --repo to every gh command, instead of
relying on gh's own default-repository inference (which can target the
wrong repository in a checkout with more than one remote, even though
ctx.repo_slug itself was already resolved from the configured
remote_name); issue #123's removal of the automated merge-conflict
repair path; and issue #230's rule that a branch update carries
`reviewed:approve` forward only on a positive content-safe verdict.
"""

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import drain_prs
import drain_prs_service
import kanban_models


REPO_ROOT = Path(__file__).resolve().parent.parent
MODELS_TOML_EXAMPLE = REPO_ROOT / "models.toml.example"


class ParseRepoSlugTests(unittest.TestCase):
    def test_accepts_the_broader_remote_forms(self):
        self.assertEqual(
            drain_prs.parse_repo_slug("ssh://git@github.com/coghex/kanban.git"),
            "coghex/kanban",
        )
        self.assertEqual(drain_prs.parse_repo_slug("coghex/kanban"), "coghex/kanban")

    def test_raises_drain_error_on_an_unparseable_value(self):
        with self.assertRaises(drain_prs.DrainError):
            drain_prs.parse_repo_slug("not-a-repo")


def make_ctx(repo_slug="upstream-owner/kanban", remote_name="upstream"):
    return drain_prs.RepoContext(
        path=Path("/fake-repo"),
        repo_slug=repo_slug,
        repo_name="kanban",
        default_branch="main",
        remote_name=remote_name,
    )


class AgentPromptRepoScopingTests(unittest.TestCase):
    """A checkout configured with a non-default remote_name (e.g.
    remote_name=upstream selecting an upstream repo while "origin" still
    points at a fork) must not let gh's own default-repository inference
    silently target the fork inside these spawned-agent prompts."""

    def test_drain_rereview_prompt_requires_repo_on_every_gh_command(self):
        prompt = drain_prs.drain_rereview_prompt(
            make_ctx(),
            89,
            "a" * 40,
            provider="codex",
            assignment=kanban_models.DEFAULT_ROSTER.assignment_for(
                "drain_rereview", "codex"
            ),
        )
        self.assertIn("--repo upstream-owner/kanban", prompt)
        self.assertIn("gh pr comment 89 --repo upstream-owner/kanban", prompt)
        self.assertIn("gh pr edit 89 --repo upstream-owner/kanban", prompt)


class ConflictRepairRemovalTests(unittest.TestCase):
    """Issue #123: the automated Codex/Claude conflict repair is gone rather
    than parked behind a flag, so nothing can re-enable a path that removed
    the approval label the review gate requires."""

    def test_the_conflict_repair_flag_is_rejected(self):
        argv = ["drain_prs.py", "--path", ".", "--no-conflict-repair"]
        with mock.patch.object(sys, "argv", argv):
            with contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    drain_prs.parse_args()

    def test_the_repair_entry_points_no_longer_exist(self):
        for name in (
            "repair_conflict_with_codex",
            "run_codex_conflict_agent",
            "run_claude_conflict_reviewer",
            "claude_conflict_review_prompt",
            "codex_conflict_prompt",
            "codex_conflict_fix_prompt",
            "verify_codex_conflict_push",
            "inspect_conflict_files",
            "remove_approval_label",
            "remove_approval_label_if_present",
            "mark_changes_requested",
        ):
            with self.subTest(name=name):
                self.assertFalse(hasattr(drain_prs, name))


OLD_HEAD = "a" * 40
MOVED_HEAD = "c" * 40
NEWER_HEAD = "d" * 40


def stale_check(conclusion, *, status="COMPLETED", started="2026-08-01T00:00:00Z"):
    return {
        "name": drain_prs.STALE_APPROVAL_CHECK,
        "status": status,
        "conclusion": conclusion,
        "startedAt": started,
    }


def pr_json(head, *, approved=True, checks=()):
    return {
        "number": 7,
        "headRefOid": head,
        "labels": [{"name": drain_prs.APPROVE_LABEL}] if approved else [],
        "statusCheckRollup": list(checks),
    }


class BranchUpdateCarriedApprovalTests(unittest.TestCase):
    """Issue #230: `dismiss-stale-approval` completing is not a verdict. Only
    the conjunction recover_stale_approval already trusts -- the run succeeded
    AND the label survived it -- says the update was content-safe, and every
    conjunct has to describe the same head."""

    def test_a_successful_run_that_kept_the_label_carries_approval(self):
        settled = pr_json(MOVED_HEAD, checks=[stale_check("SUCCESS")])
        self.assertTrue(
            drain_prs.branch_update_carried_approval(settled, MOVED_HEAD)
        )

    def test_a_successful_run_that_removed_the_label_carries_nothing(self):
        # The removal IS the negative decision: the push touched files this
        # pull request owns, so the reviewed content really did change.
        settled = pr_json(MOVED_HEAD, approved=False, checks=[stale_check("SUCCESS")])
        self.assertFalse(
            drain_prs.branch_update_carried_approval(settled, MOVED_HEAD)
        )

    def test_a_head_that_moved_again_cannot_inherit_the_earlier_verdict(self):
        # The label is attached and the earlier run is still the latest
        # non-skipped result, so only the head comparison separates the
        # commit that was decided about from the one that was pushed after.
        settled = pr_json(NEWER_HEAD, checks=[stale_check("SUCCESS")])
        self.assertFalse(
            drain_prs.branch_update_carried_approval(settled, MOVED_HEAD)
        )

    def test_no_check_and_an_unfinished_or_failed_one_carry_nothing(self):
        for label, checks in (
            ("missing", []),
            ("skipped only", [stale_check("SKIPPED")]),
            ("pending", [stale_check(None, status="IN_PROGRESS")]),
            ("failed", [stale_check("FAILURE")]),
        ):
            with self.subTest(check=label):
                settled = pr_json(MOVED_HEAD, checks=checks)
                self.assertFalse(
                    drain_prs.branch_update_carried_approval(settled, MOVED_HEAD)
                )


class NoAgentStaleHeadIncidentTests(unittest.TestCase):
    """Issue #572, requirements 25 through 27: a pull request that needs a
    stale-head rereview no loaded provider can run is recorded and left
    unmerged, while the drainer goes on working.

    The incident directory is redirected to a temporary runtime root, because
    the real one belongs to whoever is running the suite, and notification is
    disabled for the same reason `NTFY_URL` is unset by default.
    """

    HEAD = "b" * 40
    APPROVED_HEAD = "a" * 40

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.incident_root = self.root / "runtime"
        self.incident_root.mkdir()
        for name, value in (
            ("RUNTIME_ROOT", self.incident_root),
            ("LOG_ROOT", self.root / "logs"),
            ("NTFY_URL", None),
        ):
            patched = mock.patch.object(drain_prs_service, name, value)
            patched.start()
            self.addCleanup(patched.stop)
        # No provider loaded, resolved once and cached for the whole case the
        # way a drain cycle caches it.
        for name, value in (
            ("FINALIZE_ASSIGNMENT", None),
            ("FINALIZE_PROVIDER", None),
            ("FINALIZE_LOADED_PROVIDERS", ()),
        ):
            patched = mock.patch.object(drain_prs, name, value)
            patched.start()
            self.addCleanup(patched.stop)
        refresh = mock.patch.object(
            drain_prs, "refresh_finalize_assignment", return_value=None
        )
        refresh.start()
        self.addCleanup(refresh.stop)
        (self.root / ".git").mkdir()
        self.ctx = drain_prs.RepoContext(
            path=self.root,
            repo_slug="coghex/kanban",
            repo_name="kanban",
            default_branch="master",
        )

    def state(self, **entry):
        return {
            "version": drain_prs.STATE_VERSION,
            "attempt_counter": 0,
            "active_pr": None,
            "prs": {
                "42": {
                    "approved_head": self.APPROVED_HEAD,
                    "last_rereviewed_head": None,
                    "consecutive_failures": 0,
                    "retry_after_attempt": 0,
                    "last_attempt": 0,
                    "last_error": None,
                    "cleanup": None,
                    **entry,
                }
            },
        }

    def pr(self, **overrides):
        value = {
            "number": 42,
            "state": "OPEN",
            "headRefOid": self.HEAD,
            "headRefName": "issue-42-topic",
            "labels": [],
            "statusCheckRollup": [],
        }
        value.update(overrides)
        return value

    def open_incidents(self):
        return drain_prs_service.open_no_agent_incidents(self.root)

    def recover(self, pr, state):
        with mock.patch.object(drain_prs, "get_pr", return_value=pr):
            with mock.patch.object(drain_prs, "rereview_pr_with_model") as spawn:
                recovered = drain_prs.recover_stale_approval(
                    self.ctx, state, dry_run=False
                )
        spawn.assert_not_called()
        return recovered

    def test_a_stale_head_records_one_incident_and_reports_no_recovery_work(self):
        # Reporting recovery work would skip run_drain_pass for the entire
        # cycle, stalling every other eligible pull request behind a merge
        # nobody can unblock -- the opposite of "never refuse to start, keep
        # merging".
        state = self.state()
        self.assertFalse(self.recover(self.pr(), state))
        incidents = self.open_incidents()
        self.assertEqual(len(incidents), 1)
        self.assertEqual(incidents[0]["kind"], drain_prs_service.NO_AGENT_INCIDENT_KIND)
        self.assertEqual(incidents[0]["pull_request"], 42)
        self.assertEqual(incidents[0]["head"], self.HEAD)
        # Nothing recorded this head as rereviewed, so the real rereview still
        # runs the moment a provider is added back.
        self.assertIsNone(state["prs"]["42"]["last_rereviewed_head"])

    def test_repeated_passes_do_not_accumulate_duplicates(self):
        state = self.state()
        for _ in range(3):
            self.assertFalse(self.recover(self.pr(), state))
        self.assertEqual(len(self.open_incidents()), 1)

    def test_the_incident_kind_fits_the_incidents_panel_budget(self):
        # The board's incidents panel has a fixed interior width, and a row
        # wider than the widest it already draws is invisible rather than an
        # error, so a new kind may not exceed the longest existing one.
        self.assertLessEqual(
            len(drain_prs_service.NO_AGENT_INCIDENT_KIND),
            len(drain_prs_service.CLEANUP_INCIDENT_KIND),
        )

    def test_the_pass_starts_and_keeps_merging_every_other_eligible_pr(self):
        # Requirement 25, at the loop that used to die before any queue
        # decision. `refresh_finalize_assignment()` runs first and no longer
        # raises, so the pass goes on to read the queue and hand the eligible
        # pull requests to `run_drain_pass` -- including while PR #42 sits
        # unmergeable behind its own incident.
        other = self.pr(number=99, headRefOid="c" * 40, headRefName="issue-99-topic")
        # The loop reads its own state from disk, so PR #42's stale entry has
        # to be there for the sweep to reach it at all.
        drain_prs.save_drain_state(self.ctx, self.state(), dry_run=False)
        with mock.patch.object(drain_prs, "get_pr", return_value=self.pr()):
            with mock.patch.object(
                drain_prs, "get_open_approved_prs", return_value=[other]
            ):
                with mock.patch.object(drain_prs, "run_drain_pass") as pass_:
                    drain_prs.loop(
                        self.ctx,
                        interval=1,
                        once=True,
                        dry_run=False,
                        gates=drain_prs.GateConfig(
                            required_ci_check=None, required_review_check=None
                        ),
                    )
        pass_.assert_called_once()
        self.assertEqual(
            [item["number"] for item in pass_.call_args.args[1]], [99]
        )
        self.assertEqual(len(self.open_incidents()), 1)

    def test_a_dry_run_records_nothing(self):
        state = self.state()
        with mock.patch.object(drain_prs, "get_pr", return_value=self.pr()):
            drain_prs.recover_stale_approval(self.ctx, state, dry_run=True)
        self.assertEqual(self.open_incidents(), [])

    def reconcile(self, pr, state, *, details=None):
        with mock.patch.object(drain_prs, "get_pr", return_value=pr):
            with mock.patch.object(
                drain_prs, "latest_review_details", return_value=details
            ):
                drain_prs.reconcile_no_agent_incidents(self.ctx, state, dry_run=False)

    def test_every_terminal_condition_resolves_the_incident(self):
        approve = ("codex", self.HEAD.lower(), "APPROVE")
        cases = {
            "closed": (self.pr(state="CLOSED"), self.state(), None),
            "merged": (self.pr(state="MERGED"), self.state(), None),
            "head no longer stale": (
                self.pr(headRefOid=self.APPROVED_HEAD),
                self.state(),
                None,
            ),
            "left the queue": (self.pr(), {"prs": {}}, None),
            "changes requested": (
                self.pr(labels=[{"name": drain_prs.CHANGES_LABEL}]),
                self.state(),
                None,
            ),
            "current-head approval": (self.pr(), self.state(), approve),
        }
        for name, (pr, state, details) in cases.items():
            with self.subTest(condition=name):
                self.recover(self.pr(), self.state())
                self.assertEqual(len(self.open_incidents()), 1)
                self.reconcile(pr, state, details=details)
                self.assertEqual(self.open_incidents(), [], name)

    def test_a_wrong_brand_marker_cannot_clear_the_incident_after_a_mode_change(self):
        # The transition an operator makes to repair a no-agent install: one
        # provider is loaded, so the incident's own premise is gone -- but the
        # pull request may still owe a rereview, because the current-head
        # marker it carries was published by the brand that is NOT loaded.
        # `recover_stale_approval` already refuses that marker, so resolving
        # the incident on it here would clear the only standing signal that
        # this pull request is waiting. The two paths ask one question through
        # one predicate.
        self.recover(self.pr(), self.state())
        self.assertEqual(len(self.open_incidents()), 1)
        with mock.patch.object(drain_prs, "FINALIZE_LOADED_PROVIDERS", ("claude",)):
            self.reconcile(
                self.pr(),
                self.state(),
                details=("codex", self.HEAD.lower(), "APPROVE"),
            )
            self.assertEqual(
                len(self.open_incidents()),
                1,
                "a marker from the unloaded brand resolved the incident",
            )
            # The loaded brand's own current-head approval does clear it, so
            # the check above is a provider test rather than a blanket refusal.
            self.reconcile(
                self.pr(),
                self.state(),
                details=("claude", self.HEAD.lower(), "APPROVE"),
            )
        self.assertEqual(self.open_incidents(), [])

    def test_a_pull_request_that_still_needs_a_rereview_keeps_its_incident(self):
        self.recover(self.pr(), self.state())
        # Still open, still stale-headed, no verdict label, and the newest
        # marker is for the OLD head.
        self.reconcile(
            self.pr(),
            self.state(),
            details=("codex", self.APPROVED_HEAD.lower(), "APPROVE"),
        )
        self.assertEqual(len(self.open_incidents()), 1)

    def test_an_unreadable_pull_request_keeps_its_incident(self):
        # Fail-closed the way the conflict reconciler is: only a confirmed
        # reading closes one.
        self.recover(self.pr(), self.state())
        with mock.patch.object(
            drain_prs, "get_pr", side_effect=drain_prs.DrainError("gh is down")
        ):
            drain_prs.reconcile_no_agent_incidents(
                self.ctx, self.state(), dry_run=False
            )
        self.assertEqual(len(self.open_incidents()), 1)

    def test_a_successful_rereview_resolves_the_incident_at_once(self):
        # Requirement 27's last clause: the incident does not wait for the
        # next pass's reconciliation once a model-backed rereview publishes.
        self.recover(self.pr(), self.state())
        self.assertEqual(len(self.open_incidents()), 1)
        approved = self.pr(labels=[{"name": drain_prs.APPROVE_LABEL}])
        with mock.patch.object(drain_prs, "FINALIZE_PROVIDER", "claude"):
            with mock.patch.object(
                drain_prs,
                "FINALIZE_ASSIGNMENT",
                kanban_models.DEFAULT_ROSTER.assignment_for("drain_rereview", "claude"),
            ):
                with mock.patch.object(drain_prs, "prepare_review_worktree", return_value=self.root):
                    with mock.patch.object(drain_prs, "get_pr", return_value=approved):
                        with mock.patch.object(
                            drain_prs,
                            "latest_review_details",
                            return_value=("claude", self.HEAD.lower(), "APPROVE"),
                        ):
                            with mock.patch.object(
                                drain_prs, "remove_worktree"
                            ):
                                with mock.patch.object(
                                    drain_prs,
                                    "run",
                                    side_effect=self._clean_worktree_runner(),
                                ):
                                    drain_prs.rereview_pr_with_model(
                                        self.ctx, approved, dry_run=False
                                    )
        self.assertEqual(self.open_incidents(), [])

    def test_a_wrong_provider_marker_fails_the_post_spawn_verification(self):
        # Requirement 31 at the spawn's own verification: the reviewer the
        # roster selected has to be the one that published, or an older
        # canonical review sitting at this head would stand in for the
        # rereview that was just run.
        approved = self.pr(labels=[{"name": drain_prs.APPROVE_LABEL}])
        with mock.patch.object(drain_prs, "FINALIZE_PROVIDER", "claude"):
            with mock.patch.object(
                drain_prs,
                "FINALIZE_ASSIGNMENT",
                kanban_models.DEFAULT_ROSTER.assignment_for("drain_rereview", "claude"),
            ):
                with mock.patch.object(drain_prs, "prepare_review_worktree", return_value=self.root):
                    with mock.patch.object(drain_prs, "get_pr", return_value=approved):
                        with mock.patch.object(
                            drain_prs,
                            "latest_review_details",
                            return_value=("codex", self.HEAD.lower(), "APPROVE"),
                        ):
                            with mock.patch.object(drain_prs, "remove_worktree"):
                                with mock.patch.object(
                                    drain_prs,
                                    "run",
                                    side_effect=self._clean_worktree_runner(),
                                ):
                                    with self.assertRaises(drain_prs.DrainError) as caught:
                                        drain_prs.rereview_pr_with_model(
                                            self.ctx, approved, dry_run=False
                                        )
        self.assertIn("claude pr-review marker", str(caught.exception))

    def _clean_worktree_runner(self):
        """Answer the git probes around the spawn, and the spawn itself."""

        def fake_run(args, **kwargs):
            stdout = self.HEAD if "rev-parse" in args else ""
            return subprocess.CompletedProcess(args, 0, stdout=stdout, stderr="")

        return fake_run


class WaitForBranchUpdatePolicyTests(unittest.TestCase):
    """What the wait hands back to update_branch, per settled observation."""

    def wait(self, *reads, timeout_seconds=0):
        ctx = make_ctx()
        with mock.patch.object(drain_prs, "get_pr", side_effect=list(reads)):
            with contextlib.redirect_stderr(io.StringIO()):
                return drain_prs.wait_for_branch_update_policy(
                    ctx,
                    7,
                    OLD_HEAD,
                    timeout_seconds=timeout_seconds,
                    poll_seconds=0,
                )

    def test_a_retained_label_returns_the_payload_that_kept_it(self):
        settled = pr_json(MOVED_HEAD, checks=[stale_check("SUCCESS")])
        self.assertEqual(
            self.wait(pr_json(MOVED_HEAD, checks=[stale_check("SUCCESS")]), settled),
            settled,
        )

    def test_a_removed_label_settles_the_wait_with_nothing_to_carry(self):
        self.assertIsNone(
            self.wait(
                pr_json(MOVED_HEAD, checks=[stale_check("SUCCESS")]),
                pr_json(MOVED_HEAD, approved=False, checks=[stale_check("SUCCESS")]),
            )
        )

    def test_a_head_pushed_between_the_two_reads_carries_nothing(self):
        self.assertIsNone(
            self.wait(
                pr_json(MOVED_HEAD, checks=[stale_check("SUCCESS")]),
                pr_json(NEWER_HEAD, checks=[stale_check("SUCCESS")]),
            )
        )

    def test_a_skipped_later_run_cannot_mask_an_earlier_success(self):
        # The masked sequence: the update-branch merge fired a synchronize the
        # job ran on, a second push fired one it skipped, and the skip leaves
        # the first run as the latest non-skipped result. That success speaks
        # for the merge commit, never for the push that followed it.
        masked = [
            stale_check("SUCCESS", started="2026-08-01T00:00:00Z"),
            stale_check("SKIPPED", started="2026-08-01T00:05:00Z"),
        ]
        self.assertIsNone(
            self.wait(
                pr_json(MOVED_HEAD, approved=False, checks=masked),
                pr_json(NEWER_HEAD, approved=False, checks=masked),
            )
        )

    def test_a_failed_policy_run_is_an_error_rather_than_a_carry(self):
        with self.assertRaises(drain_prs.DrainError):
            self.wait(pr_json(MOVED_HEAD, checks=[stale_check("FAILURE")]))

    def test_an_unsettled_policy_times_out_rather_than_carrying(self):
        for label, checks in (
            ("missing", []),
            ("skipped only", [stale_check("SKIPPED")]),
            ("pending", [stale_check(None, status="IN_PROGRESS")]),
        ):
            with self.subTest(check=label):
                with self.assertRaises(drain_prs.DrainError):
                    self.wait(pr_json(MOVED_HEAD, approved=False, checks=checks))


MERGE_BASE = "b" * 40
TIP = "e" * 40


class ComparedPathsTests(unittest.TestCase):
    """Issue #409 rests on compared_paths reporting every endpoint: the
    directory-aware membership check below can only be complete if a rename or
    copy in the advance contributes both of its paths."""

    def compare(self, payload):
        with mock.patch.object(drain_prs, "run_json", return_value=payload):
            return drain_prs.compared_paths(make_ctx(), OLD_HEAD, TIP)

    def test_a_rename_contributes_both_of_its_endpoints(self):
        result = self.compare(
            {
                "merge_base_commit": {"sha": MERGE_BASE},
                "files": [
                    {
                        "filename": "docs/coordination/renamed.md",
                        "previous_filename": "docs/old-place.md",
                    },
                    {"filename": "docs/coordination/notes.md"},
                ],
            }
        )
        self.assertEqual(
            result,
            (
                MERGE_BASE,
                frozenset(
                    {
                        "docs/coordination/renamed.md",
                        "docs/old-place.md",
                        "docs/coordination/notes.md",
                    }
                ),
            ),
        )

    def test_a_file_list_at_the_cap_cannot_be_proven_complete(self):
        payload = {
            "merge_base_commit": {"sha": MERGE_BASE},
            "files": [
                {"filename": f"docs/coordination/{index}.md"}
                for index in range(drain_prs.COMPARE_FILE_LIMIT)
            ],
        }
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertIsNone(self.compare(payload))


class CoordinationBaseAdvanceTests(unittest.TestCase):
    """Issue #409: configured coordination declarations cover directories by
    whole path component at the drainer's runtime base-advance decision, and
    every uncertain or invalid configuration still requests the ordinary
    branch update."""

    def decide(self, configured, advanced, own=frozenset({"src/Kanban/UI.hs"})):
        ctx = make_ctx()
        pr = {"number": 7, "headRefOid": OLD_HEAD}
        comparisons = [(MERGE_BASE, frozenset(advanced)), (MERGE_BASE, frozenset(own))]
        with mock.patch.object(
            drain_prs, "COORDINATION_PATHS", frozenset(configured)
        ), mock.patch.object(
            drain_prs, "default_branch_tip", return_value=TIP
        ), mock.patch.object(
            drain_prs, "compared_paths", side_effect=comparisons
        ), contextlib.redirect_stdout(io.StringIO()) as logged:
            approval = drain_prs.coordination_only_base_advance(ctx, pr)
        return approval, logged.getvalue()

    def test_a_descendant_of_a_configured_directory_is_covered(self):
        approval, _ = self.decide(
            {"docs/coordination/"},
            {"docs/coordination/notes.md", "docs/coordination/deep/plan.md"},
        )
        self.assertIsNotNone(approval)
        self.assertEqual(approval.tip, TIP)
        self.assertEqual(approval.head, OLD_HEAD)

    def test_a_similarly_prefixed_sibling_requests_the_ordinary_update(self):
        approval, logged = self.decide(
            {"docs/coordination/"}, {"docs/coordination-old/notes.md"}
        )
        self.assertIsNone(approval)
        self.assertIn("docs/coordination-old/notes.md", logged)
        self.assertIn("outside the configured coordination paths", logged)

    def test_an_exact_file_entry_still_covers_exactly_itself(self):
        approval, _ = self.decide({"docs/status.md"}, {"docs/status.md"})
        self.assertIsNotNone(approval)
        approval, _ = self.decide({"docs/status.md"}, {"docs/status2.md"})
        self.assertIsNone(approval)

    def test_an_uncovered_rename_endpoint_requests_the_ordinary_update(self):
        # compared_paths reports both endpoints, so a rename out of (or into)
        # the covered directory leaves one endpoint outside the declarations.
        approval, logged = self.decide(
            {"docs/coordination/"},
            {"docs/coordination/renamed.md", "docs/old-place.md"},
        )
        self.assertIsNone(approval)
        self.assertIn("docs/old-place.md", logged)

    def test_an_empty_prefix_declaration_is_reported_and_grants_nothing(self):
        # `/` would cover every path; honouring it would merge past arbitrary
        # advances, and dropping it silently would hide the misconfiguration.
        approval, logged = self.decide(
            {"/", "docs/coordination/"}, {"docs/coordination/notes.md"}
        )
        self.assertIsNone(approval)
        self.assertIn("empty component prefix", logged)
        self.assertIn("/", logged)

    def test_an_overlap_with_the_pull_requests_own_files_still_refuses(self):
        approval, logged = self.decide(
            {"docs/coordination/"},
            {"docs/coordination/notes.md"},
            own={"docs/coordination/notes.md"},
        )
        self.assertIsNone(approval)
        self.assertIn("both change", logged)

    def test_direct_publication_paths_alone_grant_no_base_advance_exception(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.toml"
            path.write_text(
                '[workflow]\ndirect_publication_paths = ["docs/status.md"]\n',
                encoding="utf-8",
            )
            raw, warnings = drain_prs.kanban_config.load_raw_config(str(path))
        resolved = drain_prs.kanban_config.resolve_config(
            "upstream-owner/kanban", raw
        )
        self.assertEqual(warnings, [])
        self.assertEqual(
            resolved.workflow.direct_publication_paths,
            frozenset({"docs/status.md"}),
        )
        self.assertEqual(resolved.workflow.coordination_paths, frozenset())
        approval, logged = self.decide(
            resolved.workflow.coordination_paths, {"docs/status.md"}
        )
        self.assertIsNone(approval)
        self.assertEqual(logged, "")


class ApprovalIsNeverAddedTests(unittest.TestCase):
    """Issue #230: the drainer reads approval verdicts and never writes one.
    No path applies `reviewed:approve`, so no repository can have one restored
    to a head its own review gate declined to keep it on."""

    def test_the_approval_label_adder_no_longer_exists(self):
        self.assertFalse(hasattr(drain_prs, "add_approval_label"))

    def test_no_source_line_adds_the_approval_label(self):
        source = Path(drain_prs.__file__).read_text(encoding="utf-8")
        self.assertNotIn("--add-label", source)


if __name__ == "__main__":
    unittest.main()


# A stand-in `codex`: records its argument vector and writes the rereview
# transcript its caller then reads.
FAKE_CODEX = """#!{interpreter}
import json, sys
from pathlib import Path

argv = sys.argv[1:]
Path({log!r}).write_text(json.dumps(argv), encoding="utf-8")
sys.stdin.read()
if "-o" in argv:
    Path(argv[argv.index("-o") + 1]).write_text("done\\n", encoding="utf-8")
"""


class RosterBackedDrainRereviewTests(unittest.TestCase):
    """Issue #483: the stale-head rereview's model and effort come from the
    roster's `drain_rereview.codex` cell, re-read per drain cycle.

    Every case resolves through a configuration root it controls, because the
    real one belongs to whoever is running the suite.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config_home = self.root / "config"
        self.config_home.mkdir()
        # The module-level cache is process-wide, so a case that left one
        # behind would decide the next one's answer.
        cached = mock.patch.object(drain_prs, "FINALIZE_ASSIGNMENT", None)
        cached.start()
        self.addCleanup(cached.stop)

    @contextlib.contextmanager
    def rooted(self):
        with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": str(self.config_home)}):
            yield

    def write_roster(self, text: str) -> Path:
        path = self.config_home / "kanban" / "models.toml"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def edited_example(self, model: str, effort: str) -> str:
        text = MODELS_TOML_EXAMPLE.read_text(encoding="utf-8")
        old = '[roles.drain_rereview.codex]\nmodel = "gpt-5.6-terra"\neffort = "medium"'
        assert old in text
        return text.replace(
            old, f'[roles.drain_rereview.codex]\nmodel = "{model}"\neffort = "{effort}"'
        )

    def test_no_roster_file_preserves_todays_values_exactly(self):
        with self.rooted():
            assignment = drain_prs.refresh_finalize_assignment()
        self.assertEqual((assignment.model, assignment.effort), ("gpt-5.6-terra", "medium"))

    def test_a_roster_file_moves_the_model_the_fake_cli_is_given(self):
        self.write_roster(self.edited_example("gpt-5.5", "low"))
        log = self.root / "codex.argv.json"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        script = bin_dir / "codex"
        # This interpreter by absolute path: PATH is replaced below with the
        # directory holding only this stand-in.
        script.write_text(
            FAKE_CODEX.format(interpreter=sys.executable, log=str(log)),
            encoding="utf-8",
        )
        script.chmod(0o755)

        worktree = self.root / "review"
        worktree.mkdir()
        pr = {"number": 7, "headRefOid": "a" * 40, "headRefName": "topic"}
        with self.rooted():
            drain_prs.refresh_finalize_assignment()
            with mock.patch.object(drain_prs, "prepare_review_worktree", return_value=worktree):
                with mock.patch.object(drain_prs, "drain_rereview_prompt", return_value="prompt"):
                    with mock.patch.object(drain_prs, "get_pr", return_value=pr):
                        with mock.patch.object(
                            drain_prs,
                            "run",
                            side_effect=self._run_recording(worktree, log, bin_dir),
                        ):
                            # What is under test ends at the spawn: the
                            # verdict bookkeeping after it reads GitHub, which
                            # this fixture answers with nothing. The argv log
                            # below is what proves the model call really ran.
                            with contextlib.suppress(drain_prs.DrainError):
                                drain_prs.rereview_pr_with_model(
                                    make_ctx(), pr, dry_run=False
                                )
        argv = json.loads(log.read_text(encoding="utf-8"))
        self.assertEqual(argv[argv.index("-m") + 1], "gpt-5.5")
        self.assertIn('model_reasoning_effort="low"', argv)

    def _run_recording(self, worktree, log, bin_dir):
        """Answer the git probes the rereview makes, and really spawn `codex`.

        Only the model call is a subprocess here: the surrounding git reads are
        about a worktree this test has no reason to build, and what is being
        asserted is the argument vector the roster produced.
        """

        def fake_run(args, **kwargs):
            if args[0] != "codex":
                # Everything around the model call is answered rather than
                # run: a clean worktree sitting on exactly the head under
                # review, and no GitHub state. What is asserted here is the
                # argument vector the roster produced, not the surrounding
                # bookkeeping other suites already cover.
                stdout = "a" * 40 if "rev-parse" in args else ""
                return subprocess.CompletedProcess(args, 0, stdout=stdout, stderr="")
            with mock.patch.dict(os.environ, {"PATH": str(bin_dir)}):
                return subprocess.run(
                    args,
                    cwd=str(worktree),
                    text=True,
                    capture_output=True,
                    input=kwargs.get("input_text"),
                )

        return fake_run

    def test_an_unusable_roster_stops_the_drainer_naming_the_file(self):
        roster = self.write_roster("schema_version = 1\nagents = 7\n")
        with self.rooted():
            with self.assertRaises(drain_prs.ModelUnavailableError) as caught:
                drain_prs.refresh_finalize_assignment()
        message = str(caught.exception)
        self.assertIn(str(roster), message)
        self.assertIn("agents", message)
        self.assertIn("no stale-head rereview was attempted", message)
        # Nothing fell back to the compiled defaults, and the failure is the
        # one class the pass loop and the candidate loop both re-raise rather
        # than absorbing into a per-PR cooldown.
        self.assertIsNone(drain_prs.FINALIZE_ASSIGNMENT)
        self.assertIsInstance(caught.exception, drain_prs.DrainError)

    def test_an_unusable_roster_refuses_the_rereview_before_any_worktree(self):
        self.write_roster("schema_version = 1\nagents = 7\n")
        pr = {"number": 7, "headRefOid": "a" * 40, "headRefName": "topic"}
        with self.rooted():
            with mock.patch.object(drain_prs, "prepare_review_worktree") as prepare:
                with self.assertRaises(drain_prs.ModelUnavailableError):
                    drain_prs.rereview_pr_with_model(make_ctx(), pr, dry_run=False)
        prepare.assert_not_called()

    def test_the_assignment_is_re_read_rather_than_frozen(self):
        # A roster edit takes effect on the next pass without restarting the
        # managed service, which is what the per-cycle refresh is for.
        self.write_roster(self.edited_example("gpt-5.5", "low"))
        with self.rooted():
            first = drain_prs.refresh_finalize_assignment()
            self.assertEqual(first.model, "gpt-5.5")
            self.write_roster(self.edited_example("gpt-5.4", "high"))
            second = drain_prs.refresh_finalize_assignment()
        self.assertEqual((second.model, second.effort), ("gpt-5.4", "high"))

    def test_the_drain_loop_refreshes_before_any_queue_work(self):
        source = (REPO_ROOT / "tools" / "drain_prs.py").read_text(encoding="utf-8")
        loop_body = source[source.index("def loop("):]
        refresh = loop_body.index("refresh_finalize_assignment()")
        for later in ("recover_stale_approval(", "get_open_approved_prs(", "run_drain_pass("):
            with self.subTest(step=later):
                self.assertLess(refresh, loop_body.index(later))


# A stand-in `claude`: the same recorder as FAKE_CODEX, for a CLI that writes
# its transcript to stdout instead of to a `-o` path.
FAKE_CLAUDE = """#!{interpreter}
import json, sys
from pathlib import Path

argv = sys.argv[1:]
Path({log!r}).write_text(json.dumps(argv), encoding="utf-8")
sys.stdin.read()
sys.stdout.write("done\\n")
"""


class LoadedProviderDrainRereviewTests(RosterBackedDrainRereviewTests):
    """Issue #572: which provider the stale-head rereview runs on comes from
    the roster's operating mode, and a roster that loads none is a state the
    drainer keeps working in rather than a failure that stops it.

    Inherits the roster harness above, including its per-case reset of the
    module-level cache: that cache is process-wide, and a case that left one
    behind would decide the next one's answer.
    """

    def setUp(self):
        super().setUp()
        for name in ("FINALIZE_PROVIDER", "FINALIZE_LOADED_PROVIDERS"):
            patched = mock.patch.object(drain_prs, name, None)
            patched.start()
            self.addCleanup(patched.stop)

    def roster_with(self, agents: str) -> None:
        self.write_roster(
            MODELS_TOML_EXAMPLE.read_text(encoding="utf-8").replace(
                'agents = ["codex", "claude"]', f"agents = {agents}"
            )
        )

    def test_dual_mode_still_selects_codex_exactly_as_before(self):
        # Requirement 36's floor for this consumer: a host with no roster file
        # resolves the same cell it always did.
        with self.rooted():
            assignment = drain_prs.refresh_finalize_assignment()
            self.assertEqual(drain_prs.finalize_reviewer_provider(), "codex")
        self.assertEqual(
            (assignment.model, assignment.effort), ("gpt-5.6-terra", "medium")
        )

    def test_single_agent_selects_the_sole_loaded_providers_cell(self):
        for agents, provider, expected in (
            ('["claude"]', "claude", ("claude-opus-5", "medium")),
            ('["codex"]', "codex", ("gpt-5.6-terra", "medium")),
        ):
            with self.subTest(agents=agents):
                drain_prs.FINALIZE_ASSIGNMENT = None
                self.roster_with(agents)
                with self.rooted():
                    assignment = drain_prs.refresh_finalize_assignment()
                    self.assertEqual(drain_prs.finalize_reviewer_provider(), provider)
                self.assertEqual((assignment.model, assignment.effort), expected)

    def test_a_no_agent_roster_resolves_to_nothing_without_raising(self):
        # Requirement 25. The per-cycle resolution is what a no-agent install
        # used to die on, ahead of every queue decision; it must now simply
        # report that there is no assignment.
        self.roster_with("[]")
        with self.rooted():
            self.assertIsNone(drain_prs.refresh_finalize_assignment())
            self.assertIsNone(drain_prs.finalize_reviewer_provider())
            self.assertEqual(drain_prs.FINALIZE_LOADED_PROVIDERS, ())

    def test_a_claude_only_roster_spawns_claude_with_that_cells_values(self):
        # Requirement 30, end to end at the spawn boundary: the executable,
        # the model and the effort all come from `drain_rereview.claude`.
        self.roster_with('["claude"]')
        log = self.root / "claude.argv.json"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        script = bin_dir / "claude"
        script.write_text(
            FAKE_CLAUDE.format(interpreter=sys.executable, log=str(log)),
            encoding="utf-8",
        )
        script.chmod(0o755)

        worktree = self.root / "review"
        worktree.mkdir()
        pr = {"number": 7, "headRefOid": "a" * 40, "headRefName": "topic"}
        with self.rooted():
            drain_prs.refresh_finalize_assignment()
            with mock.patch.object(drain_prs, "prepare_review_worktree", return_value=worktree):
                with mock.patch.object(drain_prs, "get_pr", return_value=pr):
                    with mock.patch.object(
                        drain_prs,
                        "run",
                        side_effect=self._claude_recording(worktree, log, bin_dir),
                    ):
                        with contextlib.suppress(drain_prs.DrainError):
                            drain_prs.rereview_pr_with_model(
                                make_ctx(), pr, dry_run=False
                            )
        argv = json.loads(log.read_text(encoding="utf-8"))
        self.assertEqual(argv[0], "-p")
        self.assertEqual(argv[argv.index("--model") + 1], "claude-opus-5")
        self.assertEqual(argv[argv.index("--effort") + 1], "medium")
        self.assertIn("bypassPermissions", argv)
        # No Codex flag leaked into the other brand's vector.
        self.assertNotIn("-m", argv)
        self.assertNotIn("exec", argv)

    def _claude_recording(self, worktree, log, bin_dir):
        def fake_run(args, **kwargs):
            if args[0] != "claude":
                stdout = "a" * 40 if "rev-parse" in args else ""
                return subprocess.CompletedProcess(args, 0, stdout=stdout, stderr="")
            with mock.patch.dict(os.environ, {"PATH": str(bin_dir)}):
                return subprocess.run(
                    args,
                    cwd=str(worktree),
                    text=True,
                    capture_output=True,
                    input=kwargs.get("input_text"),
                )

        return fake_run

    def test_the_prompt_and_marker_name_the_selected_provider(self):
        # Requirement 30's other half. The identity the prompt claims and the
        # marker token it is told to publish both come from the resolved
        # assignment, so the reviewer that runs, the reviewer the prompt says
        # it is, and the reviewer the marker names cannot disagree.
        for agents, provider, display in (
            ('["claude"]', "claude", "Opus 5 medium"),
            ('["codex"]', "codex", "GPT-5.6-Terra medium"),
        ):
            with self.subTest(agents=agents):
                drain_prs.FINALIZE_ASSIGNMENT = None
                self.roster_with(agents)
                with self.rooted():
                    assignment = drain_prs.refresh_finalize_assignment()
                prompt = drain_prs.drain_rereview_prompt(
                    make_ctx(), 7, "a" * 40, provider=provider, assignment=assignment
                )
                self.assertIn(f"You are {display},", prompt)
                self.assertIn(f"pr-review:v1 reviewer={provider} head=", prompt)
                other = "codex" if provider == "claude" else "claude"
                self.assertNotIn(f"reviewer={other}", prompt)

    def test_a_no_agent_rereview_refuses_at_the_spawn_boundary_too(self):
        # Unreachable from the recovery sweep, which records an incident
        # instead, but stated at the spawn as well: the single-PR entry point
        # reaches this function directly, and argv built out of None is not a
        # failure mode worth having.
        self.roster_with("[]")
        pr = {"number": 7, "headRefOid": "a" * 40, "headRefName": "topic"}
        with self.rooted():
            with mock.patch.object(drain_prs, "prepare_review_worktree") as prepare:
                with self.assertRaises(drain_prs.ModelUnavailableError) as caught:
                    drain_prs.rereview_pr_with_model(make_ctx(), pr, dry_run=False)
        prepare.assert_not_called()
        self.assertIn("no-agent", str(caught.exception))

    def test_a_marker_from_an_unloaded_provider_cannot_recover_an_approval(self):
        # Requirement 31. In dual mode both brands are reviewers this
        # installation performs, so both markers count -- which is what keeps
        # a host with no roster file byte-identical to master. In single-agent
        # mode the other brand's marker comes from a reviewer that was removed
        # from the pipeline and cannot satisfy the selected cell.
        cases = (
            ('["codex", "claude"]', {"codex": True, "claude": True}),
            ('["claude"]', {"codex": False, "claude": True}),
            ('["codex"]', {"codex": True, "claude": False}),
            # No provider is loaded, so this installation judges no marker's
            # provenance: D-11 confines the no-agent fail-closed to the pull
            # requests that actually reach a rereview.
            ("[]", {"codex": True, "claude": True}),
        )
        for agents, expected in cases:
            for marker_provider, accepted in expected.items():
                with self.subTest(agents=agents, marker=marker_provider):
                    drain_prs.FINALIZE_ASSIGNMENT = None
                    drain_prs.FINALIZE_LOADED_PROVIDERS = None
                    self.roster_with(agents)
                    with self.rooted():
                        self.assertEqual(
                            drain_prs.marker_provider_accepted(marker_provider),
                            accepted,
                        )
