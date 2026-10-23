"""The bundled head-bound approval helper's own behavioral contract.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 tools/test_pr_head_approval.py

Issue #842. `fix` and `finalize` both refuse to act on an approval that cannot
be bound to a pull request's CURRENT head, and each used to carry its own
derivation of that: finalize inline Python, fix prose. `tools/pr_head_approval.py`
owns it now, for both callers' DIFFERENT policies, and these tests run it rather
than read it. Every case executes the helper as a program against a scripted
`gh` on a temporary `PATH`, so the exit status and the JSON object a caller
parses are what is asserted, and a refusal is proved by what the recorded `gh`
log does and does not contain.

* **The old refusal cases, carried.** `FinalizeCaseTests` is every approval
  refusal and negative control `tools/test_finalize_workflow.py`'s
  `GateDecisionTests` ran against finalize's inline gate, as a table of one
  scenario and the reason it must produce. The readiness checks (mergeability,
  merge state, checks, default branch) are not the helper's and stay there.
* **The fix policy, run.** Fix's derivation was prose that no test could
  execute. `FixCaseTests` runs it: the label, review and either modes, the
  origin rule, the native-review selection and the either-mode independence.
* **The two policies are different.** `CrossPolicyTests` puts the same scenario
  to both and asserts that they decide it differently where they must: native
  evidence alone satisfies fix's review path and can never satisfy finalize, and
  an absent or external origin is finalize's alone.
* **The contract.** `ContractTests` holds the JSON and exit-status shape, the
  refusal-versus-failure distinctions, and the properties of the program itself:
  read-only, every read scoped to the resolved repository, no feed on argv, and no
  workflow command name in anything it prints.
* **The copies.** The owning source and its three bundled copies are one program,
  held byte-identical, and the full table runs against the owning source while a
  compact approve-and-refuse sweep runs against each bundled copy.
"""

from __future__ import annotations

import ast
import importlib.util
import inspect
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import fake_cli

REPO_ROOT = Path(__file__).resolve().parent.parent

OWNING_SOURCE = "tools/pr_head_approval.py"
BUNDLED_COPIES = (
    "claude-plugin/plugins/kanban/scripts/pr_head_approval.py",
    "codex-plugin/plugins/kanban/skills/fix/scripts/pr_head_approval.py",
    "codex-plugin/plugins/kanban/skills/finalize/scripts/pr_head_approval.py",
)
STANDARD_COORDINATORS = {
    "claude": REPO_ROOT / "claude-plugin/plugins/kanban/scripts/review_pr.py",
    "codex": REPO_ROOT
    / "codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py",
}

PR = "42"
REPO = "coghex/kanban"
HEAD = "1a2b3c4d5e6f70819293a4b5c6d7e8f900112233"
STALE = "99887766554433221100ffeeddccbbaa99887766"
OTHER = "0f0e0d0c0b0a09080706050403020100ffeeddcc"
VIEWER = "coghex"

# The fields the helper reads the pull request with, restated so the harness is
# scripted against the exact list: a field dropped from the helper would leave it
# deciding without it, and one dropped here would leave the harness answering a
# question the helper never asked.
PR_FIELDS = "number,body,headRefOid,labels,reviewDecision"
COMMENTS_PATH = f"repos/{REPO}/issues/{PR}/comments?per_page=100"
REVIEWS_PATH = f"repos/{REPO}/pulls/{PR}/reviews?per_page=100"

ORIGIN_MARKERS = {
    "claude": "<!-- pr-origin:claude -->",
    "codex": "<!-- pr-origin:codex -->",
    "grok": "<!-- pr-origin:grok -->",
    "kimi": "<!-- pr-origin:kimi -->",
    "google": "<!-- pr-origin:google -->",
}


def read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def load_coordinator(brand: str):
    spec = importlib.util.spec_from_file_location(
        f"kanban_helper_{brand}_review_pr", STANDARD_COORDINATORS[brand]
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def coordinator_marker(
    head: str, verdict: str, reviewers: list[str], brand: str = "claude"
) -> str:
    """A marker built by the publisher's own `review_marker`, so the accepted
    shape is the one the bundled coordinators actually emit rather than one this
    module invented."""
    module = load_coordinator(brand)
    lookup = {"codex": module.CODEX_REVIEWER, "claude": module.CLAUDE_REVIEWER}
    selected = [lookup[key] for key in reviewers]
    models = [f"model-{key}@xhigh" for key in reviewers]
    # The Codex copy fills `models=` itself and takes no list (the §2.2
    # exception tools/test_coordinator_parity.py records); the marker's own
    # shape is identical either way.
    if len(inspect.signature(module.review_marker).parameters) == 3:
        return module.review_marker(selected, head, verdict)
    return module.review_marker(selected, models, head, verdict)


def legacy_marker(head: str, verdict: str, reviewer: str = "codex") -> str:
    return f"<!-- pr-review:v1 reviewer={reviewer} head={head} verdict={verdict} -->"


def comment(identifier: int, created_at: str, body: str, login: str = VIEWER) -> dict:
    return {
        "id": identifier,
        "created_at": created_at,
        "user": {"login": login},
        "body": body,
    }


def review(
    identifier: int,
    submitted_at: str,
    state: str,
    commit_id: str | None,
    login: str = "someone",
) -> dict:
    item = {
        "id": identifier,
        "submitted_at": submitted_at,
        "state": state,
        "user": {"login": login},
    }
    if commit_id is not None:
        item["commit_id"] = commit_id
    return item


def origin_body(origin: str | None = "claude") -> str:
    if origin is None:
        return "Closes #7\n"
    return "Closes #7\n\n" + ORIGIN_MARKERS[origin] + "\n"


def state_of(
    *,
    head: str = HEAD,
    labels: tuple[str, ...] = ("reviewed:approve",),
    body: str | None = None,
    review_decision: str = "",
) -> dict:
    return {
        "number": int(PR),
        "body": origin_body("claude") if body is None else body,
        "headRefOid": head,
        "labels": [{"name": name} for name in labels],
        "reviewDecision": review_decision,
    }


def approve_pages(reviewers=("codex",), head: str = HEAD) -> list:
    return [
        [
            comment(
                1,
                "2026-08-01T00:00:00Z",
                coordinator_marker(head, "APPROVE", list(reviewers)),
            )
        ]
    ]


class Run:
    """One helper invocation against a scripted `gh`, with everything it did."""

    def __init__(self, completed, result, calls):
        self.completed = completed
        self.result = result
        self.calls = calls

    @property
    def approved(self) -> bool:
        return self.result["approved"] is True

    @property
    def reason(self) -> str:
        return self.result["reason"] or ""


UNSET = object()


def run_helper(
    relative_path: str,
    policy: str,
    *,
    brand: str | None = None,
    state=UNSET,
    pages=UNSET,
    reviews=UNSET,
    viewer: str | None = VIEWER,
    config: str | None = None,
    config_argument: str | None = None,
    pr: str = PR,
    repo: str = REPO,
    extra: list[str] | None = None,
    environ: dict | None = None,
) -> Run:
    """Run the helper at `relative_path` as a program, with `gh` scripted.

    `UNSET` means "the ordinary answer"; `None` means "the read fails": `gh`
    exits nonzero for that call, which is how a missing feed, an unreadable pull
    request and an unauthenticated session look to the helper.
    """
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        fake = fake_cli.FakeCli(root)
        fake.install("gh")
        config_home = root / "config"
        (config_home / "kanban").mkdir(parents=True)
        if config is not None:
            # An explicit path is written under the run's root and handed over
            # absolute; without one the file sits at the well-known XDG path.
            if config_argument is not None:
                target = root / config_argument
                config_argument = str(target)
            else:
                target = config_home / "kanban" / "config.toml"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(config, encoding="utf-8")

        def script(match, value, *, default):
            payload = default if value is UNSET else value
            if payload is None:
                fake.script("gh", match, stderr="gh: scripted failure\n", exit_code=1)
            elif isinstance(payload, str):
                fake.script("gh", match, stdout=payload)
            else:
                fake.script("gh", match, stdout=json.dumps(payload))

        if viewer is None:
            fake.script("gh", ["api", "user", "--jq", ".login"], stderr="no\n", exit_code=1)
        else:
            fake.script("gh", ["api", "user", "--jq", ".login"], stdout=viewer + "\n")
        script(
            ["pr", "view", pr, "-R", repo, "--json", PR_FIELDS],
            state,
            default=state_of(),
        )
        script(
            ["api", "--paginate", "--slurp", f"repos/{repo}/issues/{pr}/comments?per_page=100"],
            pages,
            default=approve_pages(),
        )
        script(
            ["api", "--paginate", "--slurp", f"repos/{repo}/pulls/{pr}/reviews?per_page=100"],
            reviews,
            default=[[]],
        )
        arguments = [
            sys.executable,
            str(REPO_ROOT / relative_path),
            "--policy",
            policy,
            "--repo",
            repo,
            "--pr",
            pr,
        ]
        if brand is not None:
            arguments += ["--brand", brand]
        if config_argument is not None:
            arguments += ["--config", config_argument]
        arguments += extra or []
        env = {
            "PATH": os.environ.get("PATH", ""),
            "HOME": str(root / "home"),
            "XDG_CONFIG_HOME": str(config_home),
        }
        env.update(fake.environ_overrides())
        env.update(environ or {})
        completed = subprocess.run(
            arguments,
            env=env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
        )
        try:
            result = json.loads(completed.stdout)
        except ValueError:
            result = None
        return Run(completed, result, [call["args"] for call in fake.calls("gh")])


class HelperCase(unittest.TestCase):
    """Shared assertions over a `Run`."""

    source = OWNING_SOURCE

    def fix(self, **scenario) -> Run:
        scenario.setdefault("brand", "claude")
        return run_helper(self.source, "fix", **scenario)

    def finalize(self, **scenario) -> Run:
        return run_helper(self.source, "finalize", **scenario)

    def assertApproved(self, run: Run, message: str = ""):
        self.assertEqual(run.completed.returncode, 0, run.completed.stderr or run.completed.stdout)
        self.assertIsNotNone(run.result, run.completed.stdout)
        self.assertIs(run.result["approved"], True, message)
        self.assertEqual(run.result["head"], HEAD, message)
        self.assertIsNone(run.result["reason"], message)

    def assertRefused(self, run: Run, detail: str):
        self.assertNotEqual(run.completed.returncode, 0, run.completed.stdout)
        self.assertIsNotNone(run.result, run.completed.stdout)
        self.assertIs(run.result["approved"], False)
        self.assertIn(detail, run.reason)


# --------------------------------------------------------------------------
# The old finalize gate's approval cases, carried.
# --------------------------------------------------------------------------


def pages_of(*comments: dict) -> list:
    return [list(comments)]


def marker_comment(marker: str, identifier: int = 1, created_at: str = "2026-08-01T00:00:00Z", login: str = VIEWER) -> dict:
    return comment(identifier, created_at, marker, login=login)


def approve(reviewers=("codex",), brand: str = "claude") -> str:
    return coordinator_marker(HEAD, "APPROVE", list(reviewers), brand)


# (name of the old GateDecisionTests case it carries, scenario, expected reason
# or None for an approval)
FINALIZE_CASES = (
    (
        "test_a_coordinator_published_v2_marker_passes",
        {},
        None,
    ),
    (
        "test_a_coordinator_published_dual_reviewer_v2_marker_passes",
        {
            "state": state_of(body=origin_body(None)),
            "pages": pages_of(marker_comment(approve(("codex", "claude")))),
        },
        None,
    ),
    (
        "test_an_approval_by_the_pull_requests_own_brand_is_a_self_review",
        {"pages": pages_of(marker_comment(approve(("claude",))))},
        "names this pull request's own brand (claude)",
    ),
    (
        "test_a_dual_marker_naming_the_origin_brand_is_still_a_self_review",
        {"pages": pages_of(marker_comment(approve(("codex", "claude"))))},
        "names this pull request's own brand (claude)",
    ),
    (
        "test_a_codex_origin_pull_request_refuses_a_codex_approval",
        {
            "state": state_of(body=origin_body("codex")),
            "pages": pages_of(marker_comment(approve(("codex",)))),
        },
        "names this pull request's own brand (codex)",
    ),
    (
        "test_a_grok_origin_pull_request_accepts_a_codex_approval",
        {
            "state": state_of(body=origin_body("grok")),
            "pages": pages_of(marker_comment(approve(("codex",)))),
        },
        None,
    ),
    (
        "test_a_grok_origin_pull_request_refuses_a_claude_approval",
        {
            "state": state_of(body=origin_body("grok")),
            "pages": pages_of(marker_comment(approve(("claude",)))),
        },
        "a grok-origin pull request is reviewed by Codex only",
    ),
    (
        "test_a_grok_origin_pull_request_refuses_a_dual_approval",
        {
            "state": state_of(body=origin_body("grok")),
            "pages": pages_of(marker_comment(approve(("codex", "claude")))),
        },
        "a grok-origin pull request is reviewed by Codex only",
    ),
    (
        "test_a_kimi_origin_pull_request_accepts_a_codex_approval",
        {
            "state": state_of(body=origin_body("kimi")),
            "pages": pages_of(marker_comment(approve(("codex",)))),
        },
        None,
    ),
    (
        "test_a_kimi_origin_pull_request_refuses_a_claude_approval",
        {
            "state": state_of(body=origin_body("kimi")),
            "pages": pages_of(marker_comment(approve(("claude",)))),
        },
        "a kimi-origin pull request is reviewed by Codex only",
    ),
    (
        "test_a_kimi_origin_pull_request_refuses_a_dual_approval",
        {
            "state": state_of(body=origin_body("kimi")),
            "pages": pages_of(marker_comment(approve(("codex", "claude")))),
        },
        "a kimi-origin pull request is reviewed by Codex only",
    ),
    (
        "test_a_google_origin_pull_request_accepts_a_codex_approval",
        {
            "state": state_of(body=origin_body("google")),
            "pages": pages_of(marker_comment(approve(("codex",)))),
        },
        None,
    ),
    (
        "test_a_google_origin_pull_request_refuses_a_claude_approval",
        {
            "state": state_of(body=origin_body("google")),
            "pages": pages_of(marker_comment(approve(("claude",)))),
        },
        "a google-origin pull request is reviewed by Codex only",
    ),
    (
        "test_a_google_origin_pull_request_refuses_a_dual_approval",
        {
            "state": state_of(body=origin_body("google")),
            "pages": pages_of(marker_comment(approve(("codex", "claude")))),
        },
        "a google-origin pull request is reviewed by Codex only",
    ),
    (
        "test_a_single_brand_marker_on_an_unknown_origin_pull_request_refuses",
        {
            "state": state_of(body=origin_body(None)),
            "pages": pages_of(marker_comment(approve(("codex",)))),
        },
        "declares no origin, so only a dual-brand review is known to be independent",
    ),
    (
        "test_two_origin_markers_refuse_rather_than_picking_one",
        {
            "state": state_of(
                body="Closes #7\n\n"
                + ORIGIN_MARKERS["claude"]
                + "\n"
                + ORIGIN_MARKERS["codex"]
                + "\n"
            )
        },
        "carries both pr-origin markers",
    ),
    (
        "test_a_duplicated_origin_marker_refuses",
        {
            "state": state_of(
                body="Closes #7\n\n"
                + ORIGIN_MARKERS["claude"]
                + "\n"
                + ORIGIN_MARKERS["claude"]
                + "\n"
            )
        },
        "carries a duplicate pr-origin marker",
    ),
    (
        "test_an_origin_marker_with_trailing_text_refuses",
        {"state": state_of(body="Closes #7\n\n" + ORIGIN_MARKERS["claude"] + "\nthanks\n")},
        "is not the body's final content",
    ),
    (
        "test_a_legacy_v1_marker_still_passes",
        {"pages": pages_of(marker_comment(legacy_marker(HEAD, "APPROVE")))},
        None,
    ),
    (
        "test_the_newest_marker_wins_across_pages",
        {
            "pages": [
                [marker_comment(approve(), 1, "2026-08-01T00:00:00Z")],
                [
                    marker_comment(
                        coordinator_marker(HEAD, "CHANGES_REQUESTED", ["codex"]),
                        2,
                        "2026-08-05T00:00:00Z",
                    )
                ],
            ]
        },
        "verdict=CHANGES_REQUESTED",
    ),
    (
        "test_an_out_of_order_page_does_not_change_the_choice",
        {
            "pages": [
                [
                    marker_comment(
                        coordinator_marker(HEAD, "CHANGES_REQUESTED", ["codex"]),
                        2,
                        "2026-08-05T00:00:00Z",
                    )
                ],
                [marker_comment(approve(), 1, "2026-08-01T00:00:00Z")],
            ]
        },
        "verdict=CHANGES_REQUESTED",
    ),
    (
        "test_a_marker_published_by_anyone_else_is_not_a_marker",
        {"pages": pages_of(marker_comment(approve(), login="someone-else"))},
        "no review marker published by",
    ),
    (
        "test_the_author_comparison_is_case_insensitive",
        {"viewer": "CogHex"},
        None,
    ),
    (
        "test_an_unresolved_login_refuses_rather_than_accepting_every_marker",
        {"viewer": ""},
        "the authenticated GitHub login could not be resolved",
    ),
    (
        "test_a_failed_login_lookup_refuses_too",
        {"viewer": None},
        "the authenticated GitHub login could not be resolved",
    ),
    (
        "test_a_marker_naming_another_head_is_stale",
        {
            "pages": pages_of(
                marker_comment(coordinator_marker(STALE, "APPROVE", ["codex"]))
            )
        },
        "not the current head",
    ),
    (
        "test_a_malformed_owned_marker_refuses_rather_than_being_skipped",
        {
            "pages": [
                [marker_comment(approve(), 1, "2026-08-01T00:00:00Z")],
                [marker_comment("<!-- pr-review:v2 verdict=APPROVE -->", 2, "2026-08-05T00:00:00Z")],
            ]
        },
        "is malformed",
    ),
    (
        "test_a_malformed_marker_refuses_in_any_case_spelling",
        {
            "pages": [
                [marker_comment(approve(), 1, "2026-08-01T00:00:00Z")],
                [marker_comment("<!-- PR-REVIEW:V2 verdict=APPROVE -->", 2, "2026-08-05T00:00:00Z")],
            ]
        },
        "is malformed",
    ),
    (
        "test_a_well_formed_marker_in_another_case_still_passes",
        {"pages": pages_of(marker_comment(approve().upper()))},
        None,
    ),
    (
        "test_an_approval_followed_by_a_later_marker_refuses",
        {
            "pages": pages_of(
                marker_comment(approve(), 1, "2026-08-01T00:00:00Z"),
                marker_comment(
                    coordinator_marker(HEAD, "CHANGES_REQUESTED", ["codex"]),
                    2,
                    "2026-08-02T00:00:00Z",
                ),
            )
        },
        "verdict=CHANGES_REQUESTED",
    ),
    (
        "test_an_approval_followed_by_a_malformed_marker_refuses",
        {
            "pages": pages_of(
                marker_comment(approve() + "\n<!-- pr-review:v2 verdict=APPROVE -->", 1),
            )
        },
        "is malformed",
    ),
    (
        "test_a_marker_repeated_verbatim_refuses",
        {"pages": pages_of(marker_comment(approve() + "\n" + approve()))},
        "carries 2 review markers",
    ),
    (
        "test_a_comment_with_no_marker_is_passed_over_not_refused",
        {
            "pages": pages_of(
                marker_comment(approve(), 1, "2026-08-01T00:00:00Z"),
                comment(2, "2026-08-02T00:00:00Z", "thanks, looks good"),
            )
        },
        None,
    ),
    (
        "test_a_missing_approval_label_refuses",
        {"state": state_of(labels=())},
        "approves by label and the pull request is not approved that way",
    ),
    (
        "test_a_present_changes_label_refuses",
        {"state": state_of(labels=("reviewed:approve", "reviewed:changes"))},
        "reviewed:changes is attached",
    ),
    (
        "test_a_blocking_label_refuses",
        {"state": state_of(labels=("reviewed:approve", "blocked"))},
        "a blocking label is attached: blocked",
    ),
    (
        "test_the_label_comparison_folds_case_on_both_sides",
        {"state": state_of(labels=("Reviewed:Approve",))},
        None,
    ),
    (
        "test_a_repository_that_renamed_its_approval_label_is_read_correctly",
        {
            "config": '[workflow]\napproval_label = "ready:to-land"\n',
            "state": state_of(labels=("ready:to-land",)),
        },
        None,
    ),
    (
        "test_a_repository_that_renamed_its_label_refuses_the_default_one",
        {
            "config": '[workflow]\napproval_label = "ready:to-land"\n',
            "state": state_of(labels=("reviewed:approve",)),
        },
        "approves by label and the pull request is not approved that way",
    ),
    (
        "test_a_repository_override_wins_over_the_global_table",
        {
            "config": (
                '[workflow]\napproval_label = "global:ok"\n'
                '[repositories."coghex/kanban".workflow]\napproval_label = "repo:ok"\n'
            ),
            "state": state_of(labels=("repo:ok",)),
        },
        None,
    ),
    (
        "test_a_renamed_changes_requested_label_still_refuses",
        {
            "config": '[workflow]\nchanges_requested_label = "needs:work"\n',
            "state": state_of(labels=("reviewed:approve", "needs:work")),
        },
        "needs:work is attached",
    ),
    (
        "test_a_review_mode_repository_accepts_githubs_own_approval",
        {
            "config": '[workflow]\napproval_mode = "review"\n',
            "state": state_of(labels=(), review_decision="APPROVED"),
        },
        None,
    ),
    (
        "test_a_review_mode_repository_refuses_a_missing_review_decision",
        {
            "config": '[workflow]\napproval_mode = "review"\n',
            "state": state_of(labels=("reviewed:approve",), review_decision=""),
        },
        "approves by review and the pull request is not approved that way",
    ),
    (
        "test_either_mode_accepts_the_label_alone",
        {"config": '[workflow]\napproval_mode = "either"\n'},
        None,
    ),
    (
        "test_either_mode_accepts_the_review_alone",
        {
            "config": '[workflow]\napproval_mode = "either"\n',
            "state": state_of(labels=(), review_decision="APPROVED"),
        },
        None,
    ),
    (
        "test_an_unreadable_configuration_keeps_the_documented_defaults",
        {"config": "this is [not toml"},
        None,
    ),
    (
        "test_a_feed_with_no_marker_at_all_refuses",
        {"pages": pages_of(comment(1, "2026-08-01T00:00:00Z", "looks good to me"))},
        "no review marker published by",
    ),
    (
        "an_unreadable_comment_feed_refuses",
        {"pages": None},
        "the pull request or its comment feed could not be read",
    ),
    (
        "a_comment_feed_that_is_not_pages_refuses",
        {"pages": "not json"},
        "the pull request or its comment feed could not be read",
    ),
    (
        "an_unreadable_pull_request_refuses",
        {"state": None},
        "the pull request could not be read",
    ),
    (
        "a_pull_request_with_no_readable_head_refuses",
        {"state": state_of(head="not-a-sha")},
        "the pull request's current head could not be read",
    ),
)


class FinalizeCaseTests(HelperCase):
    """`GateDecisionTests`' approval cases, run through the helper under the
    `finalize` policy."""

    def test_every_carried_case_decides_as_the_inline_gate_did(self):
        for name, scenario, expected in FINALIZE_CASES:
            with self.subTest(case=name):
                run = self.finalize(**scenario)
                if expected is None:
                    self.assertApproved(run)
                else:
                    self.assertRefused(run, expected)

    def test_finalize_reports_the_marker_history_for_the_workflow_to_word(self):
        # The same fact fix reports: whether the publisher ever published a
        # marker, whatever the refusal that followed.
        none = self.finalize(pages=pages_of(comment(1, "2026-08-01T00:00:00Z", "hi")))
        self.assertIs(none.result["marker_history"], False)
        stale = self.finalize(
            pages=pages_of(marker_comment(coordinator_marker(STALE, "APPROVE", ["codex"])))
        )
        self.assertIs(stale.result["marker_history"], True)

    def test_either_standard_coordinators_codex_marker_finalizes_a_grok_origin(self):
        # A grok-origin pull request reaches this policy from either brand's
        # coordinator (issue #696): Kanban dispatches the packaged review and
        # whichever bundle serves it publishes the marker.
        for brand in sorted(STANDARD_COORDINATORS):
            with self.subTest(coordinator=brand):
                marker = coordinator_marker(HEAD, "APPROVE", ["codex"], brand)
                self.assertApproved(
                    self.finalize(
                        state=state_of(body=origin_body("grok")),
                        pages=pages_of(marker_comment(marker)),
                    )
                )

    def test_a_feed_far_larger_than_the_argument_limit_still_decides(self):
        # The feed is the one unbounded input, and an argument long enough to
        # carry it exceeds the system limit on exactly the long pull requests
        # the pagination exists to read. The helper reads it in its own process,
        # so the size is irrelevant to it; the padding is comment BODIES, the
        # shape a real long feed has.
        limit = int(
            subprocess.run(
                ["getconf", "ARG_MAX"], capture_output=True, text=True, check=True
            ).stdout.strip()
        )
        padding = "x" * 4096
        bulk = [
            comment(index + 10, "2026-07-%02dT00:00:00Z" % (index % 28 + 1), padding)
            for index in range(limit // 4096 + 16)
        ]
        pages = [bulk, [marker_comment(approve())]]
        self.assertGreater(len(json.dumps(pages)), limit)
        # The control, so this is a regression test rather than a large fixture
        # that happens to pass: handing THIS payload to a process as an argument
        # really does fail on this platform.
        with self.assertRaises(OSError):
            subprocess.run(
                ["true", json.dumps(pages)],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                check=False,
            )
        self.assertApproved(self.finalize(pages=pages))
        self.assertApproved(self.fix(pages=pages))


# --------------------------------------------------------------------------
# The fix policy.
# --------------------------------------------------------------------------


class FixCaseTests(HelperCase):
    """Fix's derivation, which was prose, run as a program."""

    def test_the_label_mode_approves_a_current_head_marker_with_the_label(self):
        run = self.fix()
        self.assertApproved(run)
        self.assertEqual(run.result["mode"], "label")
        self.assertEqual(run.result["policy"], "fix")
        self.assertEqual(run.result["origin"], "claude")
        self.assertEqual(run.result["approval_head"], HEAD)
        self.assertTrue(run.result["paths"]["label"]["met"])

    def test_the_label_alone_is_not_approval(self):
        # A label names no commit: a third party can add one while it still
        # reads green over code nobody reviewed.
        run = self.fix(pages=pages_of(marker_comment(coordinator_marker(STALE, "APPROVE", ["codex"]))))
        self.assertRefused(run, "the newest marker you published names head " + STALE)
        self.assertEqual(run.result["approval_head"], STALE)
        self.assertEqual(run.result["head"], HEAD)

    def test_the_marker_alone_is_not_approval_without_the_label(self):
        run = self.fix(state=state_of(labels=()))
        self.assertRefused(run, "the configured approval label reviewed:approve is not attached")
        self.assertEqual(run.result["paths"]["label"]["evidence"], "approve")
        # The remedy turns on the marker, not on the surviving label.
        self.assertIs(run.result["marker_history"], True)

    def test_a_marker_naming_the_origin_brand_is_a_self_review(self):
        run = self.fix(pages=pages_of(marker_comment(approve(("claude",)))))
        self.assertRefused(run, "names this bundle's own brand (claude)")
        self.assertEqual(run.result["paths"]["label"]["evidence"], "self-review")

    def test_a_dual_marker_naming_the_origin_brand_is_a_self_review(self):
        run = self.fix(pages=pages_of(marker_comment(approve(("codex", "claude")))))
        self.assertRefused(run, "names this bundle's own brand (claude)")

    def test_each_brand_fixes_only_its_own_origin(self):
        codex_marker = pages_of(marker_comment(approve(("claude",))))
        self.assertApproved(
            self.fix(
                brand="codex",
                state=state_of(body=origin_body("codex")),
                pages=codex_marker,
            )
        )
        self.assertRefused(
            self.fix(brand="codex"), "this bundle fixes only codex-origin pull requests"
        )
        self.assertRefused(
            self.fix(
                brand="claude", state=state_of(body=origin_body("codex")), pages=codex_marker
            ),
            "this bundle fixes only claude-origin pull requests",
        )

    def test_every_origin_defect_is_a_refusal_not_a_default(self):
        cases = {
            "no marker": (origin_body(None), "carries no pr-origin marker"),
            "both markers": (
                "x\n" + ORIGIN_MARKERS["claude"] + "\n" + ORIGIN_MARKERS["codex"] + "\n",
                "carries both pr-origin markers",
            ),
            "the same marker twice": (
                "x\n" + ORIGIN_MARKERS["claude"] + "\n" + ORIGIN_MARKERS["claude"] + "\n",
                "carries a duplicate pr-origin marker",
            ),
            "trailing text": (
                "x\n" + ORIGIN_MARKERS["claude"] + "\nmore\n",
                "is not the body's final content",
            ),
            "a grok origin": (origin_body("grok"), "grok-origin"),
            "a kimi origin": (origin_body("kimi"), "kimi-origin"),
            "a google origin": (origin_body("google"), "google-origin"),
        }
        for label, (body, detail) in cases.items():
            with self.subTest(case=label):
                self.assertRefused(self.fix(state=state_of(body=body)), detail)

    def test_the_problem_labels_refuse_under_every_mode(self):
        for mode in ("label", "review", "either"):
            for labels, detail in (
                (("reviewed:approve", "reviewed:changes"), "reviewed:changes is attached"),
                (("reviewed:approve", "blocked"), "a blocking label is attached: blocked"),
            ):
                with self.subTest(mode=mode, labels=labels):
                    run = self.fix(
                        config=f'[workflow]\napproval_mode = "{mode}"\n',
                        state=state_of(labels=labels, review_decision="APPROVED"),
                        reviews=[[review(1, "2026-08-01T00:00:00Z", "APPROVED", HEAD)]],
                    )
                    self.assertRefused(run, detail)

    def test_the_review_mode_needs_a_native_approval_naming_the_current_head(self):
        config = '[workflow]\napproval_mode = "review"\n'
        approved = [[review(1, "2026-08-01T00:00:00Z", "APPROVED", HEAD)]]
        self.assertApproved(
            self.fix(
                config=config,
                state=state_of(labels=(), review_decision="APPROVED"),
                reviews=approved,
            )
        )
        # The aggregate decision alone names no commit.
        run = self.fix(
            config=config,
            state=state_of(labels=(), review_decision="APPROVED"),
            reviews=[[]],
        )
        self.assertRefused(run, "no author's newest opinionated review is an approval")
        self.assertIsNone(run.result["approval_head"])
        # A native approval without the aggregate decision is not enough either.
        run = self.fix(
            config=config, state=state_of(labels=(), review_decision=""), reviews=approved
        )
        self.assertRefused(run, "reviewDecision is not APPROVED")

    def test_a_native_approval_of_another_head_is_stale(self):
        run = self.fix(
            config='[workflow]\napproval_mode = "review"\n',
            state=state_of(labels=(), review_decision="APPROVED"),
            reviews=[[review(1, "2026-08-01T00:00:00Z", "APPROVED", STALE)]],
        )
        self.assertRefused(run, "not the current head " + HEAD)
        self.assertEqual(run.result["approval_head"], STALE)
        self.assertEqual(run.result["paths"]["review"]["evidence"], "stale")

    def test_native_reviews_are_reduced_to_each_authors_newest_opinion(self):
        config = '[workflow]\napproval_mode = "review"\n'
        state = state_of(labels=(), review_decision="APPROVED")
        superseded = [
            [
                review(1, "2026-08-01T00:00:00Z", "APPROVED", HEAD, login="alice"),
                review(2, "2026-08-02T00:00:00Z", "CHANGES_REQUESTED", HEAD, login="alice"),
            ]
        ]
        self.assertRefused(
            self.fix(config=config, state=state, reviews=superseded),
            "no author's newest opinionated review is an approval",
        )
        # The same author approving again afterwards is the newest opinion.
        reapproved = [
            [
                review(1, "2026-08-01T00:00:00Z", "CHANGES_REQUESTED", HEAD, login="alice"),
                review(2, "2026-08-02T00:00:00Z", "APPROVED", HEAD, login="alice"),
            ]
        ]
        self.assertApproved(self.fix(config=config, state=state, reviews=reapproved))
        # The review id breaks a timestamp tie.
        tied = [
            [
                review(5, "2026-08-02T00:00:00Z", "APPROVED", HEAD, login="alice"),
                review(4, "2026-08-02T00:00:00Z", "CHANGES_REQUESTED", HEAD, login="alice"),
            ]
        ]
        self.assertApproved(self.fix(config=config, state=state, reviews=tied))
        # Authors are compared case-insensitively.
        cased = [
            [
                review(1, "2026-08-01T00:00:00Z", "APPROVED", HEAD, login="Alice"),
                review(2, "2026-08-02T00:00:00Z", "CHANGES_REQUESTED", HEAD, login="alice"),
            ]
        ]
        self.assertRefused(
            self.fix(config=config, state=state, reviews=cased),
            "no author's newest opinionated review is an approval",
        )

    def test_a_dismissed_review_does_not_supersede_an_authors_approval(self):
        # A dismissed review is not evidence, and it is no opinion either: it
        # neither approves nor takes back the author's earlier approval.
        run = self.fix(
            config='[workflow]\napproval_mode = "review"\n',
            state=state_of(labels=(), review_decision="APPROVED"),
            reviews=[
                [
                    review(1, "2026-08-01T00:00:00Z", "APPROVED", HEAD, login="alice"),
                    review(2, "2026-08-02T00:00:00Z", "DISMISSED", HEAD, login="alice"),
                ]
            ],
        )
        self.assertApproved(run)

    def test_a_dismissed_or_unattributed_native_approval_is_not_evidence(self):
        config = '[workflow]\napproval_mode = "review"\n'
        state = state_of(labels=(), review_decision="APPROVED")
        dismissed = [[review(1, "2026-08-01T00:00:00Z", "DISMISSED", HEAD)]]
        self.assertRefused(
            self.fix(config=config, state=state, reviews=dismissed),
            "no author's newest opinionated review is an approval",
        )
        unattributed = [
            [
                {
                    "id": 1,
                    "submitted_at": "2026-08-01T00:00:00Z",
                    "state": "APPROVED",
                    "commit_id": HEAD,
                }
            ]
        ]
        self.assertRefused(
            self.fix(config=config, state=state, reviews=unattributed),
            "no author's newest opinionated review is an approval",
        )
        no_commit = [[review(1, "2026-08-01T00:00:00Z", "APPROVED", None)]]
        run = self.fix(config=config, state=state, reviews=no_commit)
        self.assertRefused(run, "no approving review names a commit")
        self.assertEqual(run.result["paths"]["review"]["evidence"], "unattributed")

    def test_either_mode_is_met_by_the_label_path_alone(self):
        run = self.fix(
            config='[workflow]\napproval_mode = "either"\n',
            reviews=[[review(1, "2026-08-01T00:00:00Z", "CHANGES_REQUESTED", HEAD)]],
        )
        self.assertApproved(run)
        self.assertTrue(run.result["paths"]["label"]["met"])
        self.assertFalse(run.result["paths"]["review"]["met"])

    def test_either_mode_is_met_by_the_review_path_alone(self):
        # Neither the label nor a marker, and the pull request is still
        # approved by the native review: one path failing never vetoes the other.
        run = self.fix(
            config='[workflow]\napproval_mode = "either"\n',
            state=state_of(labels=(), review_decision="APPROVED"),
            pages=pages_of(marker_comment(approve(("codex", "claude")))),
            reviews=[[review(1, "2026-08-01T00:00:00Z", "APPROVED", HEAD)]],
        )
        self.assertApproved(run)
        self.assertFalse(run.result["paths"]["label"]["met"])
        self.assertTrue(run.result["paths"]["review"]["met"])

    def test_either_mode_refuses_when_neither_path_holds_and_reports_both(self):
        run = self.fix(
            config='[workflow]\napproval_mode = "either"\n',
            state=state_of(labels=(), review_decision=""),
            pages=pages_of(marker_comment(coordinator_marker(STALE, "APPROVE", ["codex"]))),
            reviews=[[review(1, "2026-08-01T00:00:00Z", "APPROVED", OTHER)]],
        )
        self.assertRefused(run, "either mode: the label path is unmet")
        self.assertIn("the review path is unmet", run.reason)
        self.assertFalse(run.result["paths"]["label"]["met"])
        self.assertFalse(run.result["paths"]["review"]["met"])

    def test_a_failure_confined_to_one_path_does_not_veto_the_other(self):
        either = '[workflow]\napproval_mode = "either"\n'
        native = [[review(1, "2026-08-01T00:00:00Z", "APPROVED", HEAD)]]
        # An unreadable canonical feed leaves the label path unmet and approves
        # on the native path, with exit 0.
        for label, pages in (
            ("a failed feed read", None),
            ("a feed that is not pages", "garbage"),
            ("a malformed newest marker", pages_of(marker_comment("<!-- pr-review:v2 verdict=APPROVE -->"))),
            ("no marker at all", pages_of(comment(1, "2026-08-01T00:00:00Z", "hi"))),
        ):
            with self.subTest(failure=label):
                run = self.fix(
                    config=either,
                    state=state_of(review_decision="APPROVED"),
                    pages=pages,
                    reviews=native,
                )
                self.assertApproved(run)
                self.assertFalse(run.result["paths"]["label"]["met"])
        # And the reverse: a failed native read does not veto a valid label path.
        for label, reviews in (("a failed review read", None), ("reviews that are not pages", "garbage")):
            with self.subTest(failure=label):
                run = self.fix(config=either, reviews=reviews)
                self.assertApproved(run)
                self.assertFalse(run.result["paths"]["review"]["met"])
                self.assertEqual(run.result["paths"]["review"]["evidence"], "unreadable")

    def test_a_failure_that_leaves_the_decision_unapproved_still_exits_nonzero(self):
        # Under the single-path modes the same failure IS the decision.
        self.assertRefused(self.fix(pages=None), "the comment feed could not be read")
        run = self.fix(
            config='[workflow]\napproval_mode = "review"\n',
            state=state_of(labels=(), review_decision="APPROVED"),
            reviews=None,
        )
        self.assertRefused(run, "the reviews could not be read")

    def test_an_input_every_path_needs_refuses_even_when_a_path_would_approve(self):
        either = '[workflow]\napproval_mode = "either"\n'
        native = [[review(1, "2026-08-01T00:00:00Z", "APPROVED", HEAD)]]
        ordinary = {"config": either, "state": state_of(review_decision="APPROVED"), "reviews": native}
        self.assertApproved(self.fix(**ordinary))
        refusals = {
            "an unresolved publisher": ({"viewer": ""}, "the authenticated GitHub login could not be resolved"),
            "a failed publisher lookup": ({"viewer": None}, "the authenticated GitHub login could not be resolved"),
            "an unreadable pull request": ({"state": None}, "the pull request could not be read"),
            "an unreadable head": ({"state": state_of(head="", review_decision="APPROVED")}, "current head could not be read"),
            "a missing origin": ({"state": state_of(body=origin_body(None), review_decision="APPROVED")}, "carries no pr-origin marker"),
            "another brand's origin": ({"state": state_of(body=origin_body("codex"), review_decision="APPROVED")}, "fixes only claude-origin"),
        }
        for label, (override, detail) in refusals.items():
            with self.subTest(failure=label):
                self.assertRefused(self.fix(**{**ordinary, **override}), detail)

    def test_the_marker_history_tells_a_first_review_from_a_stale_one(self):
        # The remedy is the workflow's to word, and it turns on this fact alone:
        # whether the publisher has ever published a marker, whatever head it
        # named and whether or not the label is attached.
        stale = self.fix(
            state=state_of(labels=()),
            pages=pages_of(marker_comment(coordinator_marker(STALE, "APPROVE", ["codex"]))),
        )
        self.assertIs(stale.result["marker_history"], True)
        never = self.fix(state=state_of(labels=()), pages=pages_of(comment(1, "2026-08-01T00:00:00Z", "hi")))
        self.assertRefused(never, "no review marker published by")
        self.assertIs(never.result["marker_history"], False)
        foreign = self.fix(
            pages=pages_of(marker_comment(approve(), login="someone-else"))
        )
        self.assertIs(foreign.result["marker_history"], False)
        unreadable = self.fix(pages=None)
        self.assertIsNone(unreadable.result["marker_history"])
        review_only = self.fix(
            config='[workflow]\napproval_mode = "review"\n',
            state=state_of(labels=(), review_decision=""),
        )
        self.assertIsNone(review_only.result["marker_history"])

    def test_the_selection_rules_are_the_canonical_ones(self):
        # The same marker selection finalize uses: newest by time with the id
        # breaking ties, selected before it is validated, never falling back.
        stale_after = pages_of(
            marker_comment(approve(), 1, "2026-08-01T00:00:00Z"),
            marker_comment(
                coordinator_marker(HEAD, "CHANGES_REQUESTED", ["codex"]),
                2,
                "2026-08-01T00:00:00Z",
            ),
        )
        self.assertRefused(self.fix(pages=stale_after), "verdict=CHANGES_REQUESTED")
        multiple = pages_of(marker_comment(approve() + "\n" + approve()))
        self.assertRefused(self.fix(pages=multiple), "carries 2 review markers")
        malformed_after = pages_of(
            marker_comment(approve(), 1, "2026-08-01T00:00:00Z"),
            marker_comment("<!-- pr-review:v2 nonsense -->", 2, "2026-08-02T00:00:00Z"),
        )
        self.assertRefused(self.fix(pages=malformed_after), "is malformed")
        self.assertApproved(self.fix(pages=pages_of(marker_comment(legacy_marker(HEAD, "APPROVE")))))

    def test_the_configuration_is_resolved_like_the_other_readers(self):
        config = (
            '[workflow]\napproval_label = "global:ok"\n'
            '[repositories."coghex/kanban".workflow]\napproval_label = "repo:ok"\n'
        )
        self.assertApproved(self.fix(config=config, state=state_of(labels=("repo:ok",))))
        self.assertRefused(
            self.fix(config=config, state=state_of(labels=("global:ok",))),
            "the configured approval label repo:ok is not attached",
        )

    def test_an_explicit_configuration_path_is_read_and_reported(self):
        # Preserve fix's forwarding of an explicit config path: the file the
        # caller names is the one read, and the result says which.
        run = self.fix(
            config='[workflow]\napproval_label = "explicit:ok"\n',
            config_argument="elsewhere/custom.toml",
            state=state_of(labels=("explicit:ok",)),
        )
        self.assertApproved(run)
        self.assertEqual(run.result["config"]["status"], "read")
        self.assertTrue(run.result["config"]["path"].endswith("elsewhere/custom.toml"))

    def test_the_configuration_outcome_is_reported(self):
        self.assertEqual(self.fix().result["config"]["status"], "absent")
        self.assertEqual(self.fix(config="[workflow").result["config"]["status"], "unreadable")
        self.assertEqual(
            self.fix(config='[workflow]\napproval_mode = "label"\n').result["config"]["status"],
            "read",
        )

    def test_an_empty_config_argument_means_none_was_supplied(self):
        run = self.fix(
            config='[workflow]\napproval_label = "xdg:ok"\n',
            state=state_of(labels=("xdg:ok",)),
            extra=["--config", ""],
        )
        self.assertApproved(run)
        self.assertTrue(run.result["config"]["path"].endswith("kanban/config.toml"))


# --------------------------------------------------------------------------
# The two policies decide differently, on purpose.
# --------------------------------------------------------------------------


class CrossPolicyTests(HelperCase):
    def test_native_evidence_alone_satisfies_fixs_review_path_and_never_finalize(self):
        # A repository approving by `review`, a native approval at the current
        # head, and NO canonical marker at all.
        scenario = {
            "config": '[workflow]\napproval_mode = "review"\n',
            "state": state_of(labels=(), review_decision="APPROVED"),
            "pages": pages_of(comment(1, "2026-08-01T00:00:00Z", "hi")),
            "reviews": [[review(1, "2026-08-01T00:00:00Z", "APPROVED", HEAD)]],
        }
        self.assertApproved(self.fix(**scenario))
        refused = self.finalize(**scenario)
        self.assertRefused(refused, "no review marker published by")
        # Finalize fetched no native reviews to begin with.
        self.assertFalse(
            [call for call in refused.calls if call[-1] == REVIEWS_PATH],
            refused.calls,
        )

    def test_native_evidence_never_substitutes_under_either_mode_for_finalize(self):
        scenario = {
            "config": '[workflow]\napproval_mode = "either"\n',
            "state": state_of(labels=(), review_decision="APPROVED"),
            "pages": pages_of(comment(1, "2026-08-01T00:00:00Z", "hi")),
            "reviews": [[review(1, "2026-08-01T00:00:00Z", "APPROVED", HEAD)]],
        }
        self.assertApproved(self.fix(**scenario))
        self.assertRefused(self.finalize(**scenario), "no review marker published by")

    def test_finalize_needs_the_marker_even_where_the_label_is_the_signal(self):
        scenario = {"pages": pages_of(comment(1, "2026-08-01T00:00:00Z", "hi"))}
        self.assertRefused(self.finalize(**scenario), "no review marker published by")
        self.assertRefused(self.fix(**scenario), "no review marker published by")

    def test_each_policy_applies_its_own_origin_rules(self):
        dual = pages_of(marker_comment(approve(("codex", "claude"))))
        codex_only = pages_of(marker_comment(approve(("codex",))))
        # No declared origin: finalize accepts a dual-brand approval, fix has no
        # brand to match and refuses.
        no_origin = state_of(body=origin_body(None))
        self.assertApproved(self.finalize(state=no_origin, pages=dual))
        self.assertRefused(self.fix(state=no_origin, pages=dual), "carries no pr-origin marker")
        # An external origin: finalize accepts a Codex-only approval, fix never
        # works on a pull request that is not its own brand's.
        for origin in ("grok", "kimi", "google"):
            with self.subTest(origin=origin):
                external = state_of(body=origin_body(origin))
                self.assertApproved(self.finalize(state=external, pages=codex_only))
                self.assertRefused(self.fix(state=external, pages=codex_only), origin + "-origin")
        # The dual-brand approval fix refuses as a self-review is finalize's own
        # refusal on a claude-origin pull request too, but for the origin rule.
        both = pages_of(marker_comment(approve(("codex", "claude"))))
        self.assertRefused(self.finalize(pages=both), "names this pull request's own brand (claude)")
        self.assertRefused(self.fix(pages=both), "names this bundle's own brand (claude)")

    def test_finalize_takes_no_bundle_brand(self):
        run = run_helper(self.source, "finalize", brand="claude")
        self.assertEqual(run.completed.returncode, 2)
        self.assertTrue(run.result["usage"])

    def test_the_same_scenario_is_decided_by_policy_not_by_mode_alone(self):
        # The case that keeps the policies from being unified: a codex-origin
        # pull request fixed by the Codex bundle on a claude approval is fix's
        # approval and finalize's too, but a claude-origin one approved by claude
        # is neither's.
        claude_approval = pages_of(marker_comment(approve(("claude",))))
        self.assertApproved(
            self.fix(brand="codex", state=state_of(body=origin_body("codex")), pages=claude_approval)
        )
        self.assertApproved(
            self.finalize(state=state_of(body=origin_body("codex")), pages=claude_approval)
        )
        self.assertRefused(self.fix(pages=claude_approval), "self-review")
        self.assertRefused(self.finalize(pages=claude_approval), "self-review")


# --------------------------------------------------------------------------
# The result and exit-status contract, and the program's own properties.
# --------------------------------------------------------------------------

RESULT_KEYS = {
    "approved",
    "policy",
    "mode",
    "head",
    "approval_head",
    "origin",
    "publisher",
    "reason",
    "marker_history",
    "config",
    "paths",
}


class ContractTests(HelperCase):
    def test_an_approval_exits_zero_with_exactly_true_and_the_head(self):
        for policy, run in (("fix", self.fix()), ("finalize", self.finalize())):
            with self.subTest(policy=policy):
                self.assertEqual(run.completed.returncode, 0)
                self.assertEqual(set(run.result), RESULT_KEYS)
                self.assertIs(run.result["approved"], True)
                self.assertEqual(run.result["head"], HEAD)
                self.assertEqual(run.result["policy"], policy)
                self.assertEqual(run.result["publisher"], VIEWER)
                self.assertIsNone(run.result["reason"])
                self.assertEqual(run.completed.stdout.count("\n"), 1)

    def test_a_refusal_exits_nonzero_with_a_json_object_and_a_reason(self):
        for policy, run in (
            ("fix", self.fix(state=state_of(labels=()))),
            ("finalize", self.finalize(state=state_of(labels=()))),
        ):
            with self.subTest(policy=policy):
                self.assertEqual(run.completed.returncode, 1)
                self.assertEqual(set(run.result), RESULT_KEYS)
                self.assertIs(run.result["approved"], False)
                self.assertTrue(run.result["reason"])
                # A diagnostic, and not authority: the refusal still names the
                # head it looked at.
                self.assertEqual(run.result["head"], HEAD)
                self.assertEqual(run.completed.stdout.count("\n"), 1)

    def test_an_unreadable_head_is_reported_as_null(self):
        run = self.finalize(state=state_of(head=""))
        self.assertIsNone(run.result["head"])
        self.assertIs(run.result["approved"], False)

    def test_the_effective_mode_is_reported(self):
        for mode in ("label", "review", "either"):
            with self.subTest(mode=mode):
                run = self.fix(
                    config=f'[workflow]\napproval_mode = "{mode}"\n',
                    state=state_of(review_decision="APPROVED"),
                    reviews=[[review(1, "2026-08-01T00:00:00Z", "APPROVED", HEAD)]],
                )
                self.assertEqual(run.result["mode"], mode)

    def test_a_usage_error_exits_two_and_still_prints_an_object(self):
        cases = {
            "fix without a brand": ("fix", {"brand": None}),
            "a branch name for the pull request": ("fix", {"brand": "claude", "pr": "some-branch"}),
            "zero": ("finalize", {"pr": "0"}),
            "a negative number": ("finalize", {"pr": "-4"}),
            "an empty number": ("finalize", {"pr": ""}),
            "two tokens": ("finalize", {"pr": "4 5"}),
            "a URL": ("finalize", {"pr": "https://github.com/coghex/kanban/pull/42"}),
            "a repository that is not owner/name": ("finalize", {"repo": "kanban"}),
            "an unknown flag": ("finalize", {"extra": ["--force"]}),
        }
        for label, (policy, scenario) in cases.items():
            with self.subTest(case=label):
                run = run_helper(self.source, policy, **scenario)
                self.assertEqual(run.completed.returncode, 2, run.completed.stderr)
                self.assertIs(run.result["approved"], False)
                self.assertTrue(run.result["usage"])
                # Nothing was read: a rejected invocation makes no GitHub call.
                self.assertEqual(run.calls, [])

    def test_an_unknown_policy_is_a_usage_error(self):
        completed = subprocess.run(
            [sys.executable, str(REPO_ROOT / self.source), "--policy", "drain", "--repo", REPO, "--pr", PR],
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIs(json.loads(completed.stdout)["approved"], False)

    def test_no_failure_to_start_gh_can_be_mistaken_for_an_approval(self):
        run = run_helper(self.source, "finalize", environ={"PATH": "/nonexistent"})
        self.assertNotEqual(run.completed.returncode, 0)
        self.assertIs(run.result["approved"], False)

    def test_a_crash_inside_the_evaluation_is_a_refusal(self):
        # A label list that is not a list reaches an iteration the helper did not
        # plan for; the surprise must read as a refusal and never as a traceback
        # with no result.
        run = self.fix(
            state={
                "number": 42,
                "body": origin_body("claude"),
                "headRefOid": HEAD,
                "labels": 3,
            }
        )
        self.assertNotEqual(run.completed.returncode, 0)
        self.assertIs(run.result["approved"], False)
        self.assertIn("could not be evaluated", run.reason)

    def test_the_helper_is_read_only(self):
        # The only commands it may run are reads, and none carries a method or a
        # field that would write.
        for run in (self.fix(), self.finalize(), self.fix(state=state_of(labels=()))):
            for call in run.calls:
                self.assertIn(call[0], ("api", "pr"), call)
                if call[0] == "pr":
                    self.assertEqual(call[1], "view", call)
                else:
                    self.assertTrue(
                        call[1] == "user" or call[1:3] == ["--paginate", "--slurp"], call
                    )
                self.assertFalse(
                    set(call) & {"--method", "-X", "--field", "-f", "-F", "--input"}, call
                )
        source = read(OWNING_SOURCE)
        self.assertEqual(source.count("subprocess.run("), 1)
        self.assertIn('["gh", *arguments]', source)
        tree = ast.parse(source)
        imported = {
            name.name
            for node in ast.walk(tree)
            if isinstance(node, ast.Import)
            for name in node.names
        }
        self.assertNotIn("shutil", imported)
        self.assertNotIn("socket", imported)

    def test_every_repository_addressed_read_names_the_resolved_repository(self):
        for policy in ("fix", "finalize"):
            with self.subTest(policy=policy):
                run = (
                    self.fix(config='[workflow]\napproval_mode = "either"\n')
                    if policy == "fix"
                    else self.finalize()
                )
                self.assertTrue(run.calls)
                for call in run.calls:
                    if call[:3] == ["api", "user", "--jq"]:
                        # The one call that names no repository, because the
                        # endpoint has none.
                        continue
                    if call[0] == "pr":
                        self.assertEqual(call[3:5], ["-R", REPO], call)
                    else:
                        self.assertIn(f"repos/{REPO}/", call[-1], call)

    def test_the_publisher_is_resolved_before_any_evidence_is_read(self):
        run = self.finalize()
        self.assertEqual(run.calls[0], ["api", "user", "--jq", ".login"])
        failed = self.finalize(viewer=None)
        self.assertEqual(failed.calls, [["api", "user", "--jq", ".login"]])

    def test_finalize_never_reads_native_reviews(self):
        for config in (None, '[workflow]\napproval_mode = "review"\n', '[workflow]\napproval_mode = "either"\n'):
            with self.subTest(config=config):
                run = self.finalize(
                    config=config, state=state_of(review_decision="APPROVED")
                )
                self.assertFalse([c for c in run.calls if c[-1] == REVIEWS_PATH], run.calls)

    def test_fix_reads_only_the_evidence_its_mode_uses(self):
        label = self.fix()
        self.assertTrue([c for c in label.calls if c[-1] == COMMENTS_PATH])
        self.assertFalse([c for c in label.calls if c[-1] == REVIEWS_PATH])
        review_mode = self.fix(
            config='[workflow]\napproval_mode = "review"\n',
            state=state_of(labels=(), review_decision="APPROVED"),
        )
        self.assertFalse([c for c in review_mode.calls if c[-1] == COMMENTS_PATH])
        self.assertTrue([c for c in review_mode.calls if c[-1] == REVIEWS_PATH])
        either = self.fix(config='[workflow]\napproval_mode = "either"\n')
        self.assertTrue([c for c in either.calls if c[-1] == COMMENTS_PATH])
        self.assertTrue([c for c in either.calls if c[-1] == REVIEWS_PATH])

    def test_the_helper_reads_the_fields_this_module_scripts(self):
        spec = importlib.util.spec_from_file_location(
            "pr_head_approval_under_test", REPO_ROOT / OWNING_SOURCE
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(module.PR_FIELDS, PR_FIELDS)

    def test_the_feed_never_travels_on_an_argument(self):
        # The feed is read from the child's standard output, and no argument
        # list in the program is built from one.
        source = read(OWNING_SOURCE)
        self.assertIn("capture_output=True", source)
        self.assertNotIn("sys.argv[", source)
        self.assertNotIn("mktemp", source)
        self.assertNotIn("NamedTemporaryFile", source)

    def test_nothing_it_prints_names_a_workflow_command_or_a_brand_remedy(self):
        # The workflows render these per brand, so a byte-identical helper must
        # carry none: no sigil token and no spelling of a workflow invocation.
        source = read(OWNING_SOURCE)
        self.assertNotIn("{{cmd:", source)
        for name in ("pr-review", "pr-rereview", "finalize", "fix"):
            for sigil in ("/", "$"):
                pattern = re.compile(
                    r"(?<![\w/.$-])" + re.escape(sigil + name) + r"(?![\w/-])"
                )
                self.assertIsNone(
                    pattern.search(source),
                    f"the helper spells the workflow invocation {sigil}{name}",
                )
        for run in (
            self.fix(state=state_of(labels=())),
            self.finalize(state=state_of(labels=())),
            self.fix(pages=None),
        ):
            printed = run.completed.stdout + run.completed.stderr
            self.assertNotRegex(printed, r"(?<![\w/])[/$]pr-(re)?review")
            self.assertNotIn("Run ", printed)

    def test_the_result_carries_no_secret_or_environment(self):
        run = self.fix(environ={"GH_TOKEN": "ghp_supersecrettoken"})
        self.assertNotIn("ghp_supersecrettoken", run.completed.stdout + run.completed.stderr)


# --------------------------------------------------------------------------
# The copies.
# --------------------------------------------------------------------------


class BundledCopyTests(unittest.TestCase):
    def test_every_bundled_copy_is_byte_identical_to_the_owning_source(self):
        owner = (REPO_ROOT / OWNING_SOURCE).read_bytes()
        self.assertGreater(len(owner), 0)
        for copy in BUNDLED_COPIES:
            with self.subTest(copy=copy):
                self.assertEqual(
                    (REPO_ROOT / copy).read_bytes(),
                    owner,
                    f"{copy} drifted from {OWNING_SOURCE}; copy it over rather than editing it",
                )

    def test_the_three_copies_sit_where_their_callers_look_for_them(self):
        # The Claude commands read `${CLAUDE_PLUGIN_ROOT}/scripts/`, and each
        # Codex skill searches for the copy under its own skill directory,
        # because that bundle has no shared scripts root.
        self.assertEqual(
            sorted(BUNDLED_COPIES),
            sorted(
                [
                    "claude-plugin/plugins/kanban/scripts/pr_head_approval.py",
                    "codex-plugin/plugins/kanban/skills/fix/scripts/pr_head_approval.py",
                    "codex-plugin/plugins/kanban/skills/finalize/scripts/pr_head_approval.py",
                ]
            ),
        )
        for copy in BUNDLED_COPIES:
            self.assertTrue((REPO_ROOT / copy).is_file(), copy)

    def test_the_helper_is_a_single_module_with_no_sibling_to_load(self):
        # A bundle carrying the helper must carry all it needs: the Codex copies
        # sit in directories with nothing else to load from beside them.
        source = read(OWNING_SOURCE)
        self.assertNotIn("__file__", source)
        tree = ast.parse(source)
        local = {
            alias.name
            for node in ast.walk(tree)
            if isinstance(node, ast.Import)
            for alias in node.names
        } | {
            node.module
            for node in ast.walk(tree)
            if isinstance(node, ast.ImportFrom) and node.module
        }
        for name in local:
            self.assertIn(
                name.split(".")[0],
                sys.stdlib_module_names,
                f"{name} is not the standard library, so the copies could not load it",
            )


class EveryBundledCopyTests(HelperCase):
    """The same program, run from each place it ships, so a copy that was
    truncated, mislaid or left unexecutable is caught as behavior and not only
    as a byte difference."""

    def test_each_copy_approves_and_refuses_under_both_policies(self):
        for copy in BUNDLED_COPIES:
            for policy, extra in (("fix", {"brand": "claude"}), ("finalize", {})):
                with self.subTest(copy=copy, policy=policy):
                    approved = run_helper(copy, policy, **extra)
                    self.assertApproved(approved)
                    refused = run_helper(copy, policy, state=state_of(labels=()), **extra)
                    self.assertNotEqual(refused.completed.returncode, 0)
                    self.assertIs(refused.result["approved"], False)
                    stale = run_helper(
                        copy,
                        policy,
                        pages=pages_of(
                            marker_comment(coordinator_marker(STALE, "APPROVE", ["codex"]))
                        ),
                        **extra,
                    )
                    self.assertIs(stale.result["approved"], False)
                    self.assertIn("not the current head", stale.reason)

    def test_each_copy_applies_the_policy_difference(self):
        native = {
            "config": '[workflow]\napproval_mode = "review"\n',
            "state": state_of(labels=(), review_decision="APPROVED"),
            "pages": pages_of(comment(1, "2026-08-01T00:00:00Z", "hi")),
            "reviews": [[review(1, "2026-08-01T00:00:00Z", "APPROVED", HEAD)]],
        }
        for copy in BUNDLED_COPIES:
            with self.subTest(copy=copy):
                self.assertApproved(run_helper(copy, "fix", brand="claude", **native))
                self.assertIs(run_helper(copy, "finalize", **native).result["approved"], False)


if __name__ == "__main__":
    unittest.main()
