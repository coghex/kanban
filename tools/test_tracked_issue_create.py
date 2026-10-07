"""Executable coverage for tools/tracked_issue_create.py.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Every case drives the real tracker transaction record in temporary Git
repositories (tools/test_tracker_transaction.py's fixture) and a fake `gh`
executable whose issues live in a temporary JSON file, so no case reaches
GitHub. The windows under test are the ones a separately scripted
begin/create/confirm chain left open: creating after a failed begin, losing the
created issue's identity, and creating again after an interruption.
"""

from __future__ import annotations

import concurrent.futures
import contextlib
import datetime
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
import unittest.mock
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))

import git_fixture
from test_tracker_transaction import PREPARED_TIP, Fixture, run


def _load(name, filename):
    source = REPO_ROOT / "tools" / filename
    spec = importlib.util.spec_from_file_location(name, source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tool = _load("_kanban_tracked_issue_create_under_test", "tracked_issue_create.py")
# The tracker instance the tool itself loaded, so exception classes and
# patches are the ones the code under test actually uses.
tracker = tool.tracker

REPOSITORY = "coghex/kanban"
DOCUMENT = "docs/ui-bugs.md"

REQUEST = {
    "title": "Carry several named capture buffers per frame",
    "body": "## Background\n\nBody.\n\n<!-- issue-origin:claude -->\n",
    "labels": ["enhancement"],
}

FAKE_GH = '''#!{python}
import fcntl, json, os, sys, time, datetime

state_path = os.environ["FAKE_GH_STATE"]
args = sys.argv[1:]


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def issue_json(repo, issue):
    kind = "pull" if issue.get("pull") else "issues"
    entry = {{
        "number": issue["number"],
        "html_url": issue.get("html_url")
        or f"https://github.com/{{repo}}/{{kind}}/{{issue['number']}}",
        "title": issue["title"],
        "body": issue["body"],
        "labels": [{{"name": name}} for name in issue.get("labels", [])],
        "created_at": issue["created_at"],
        "updated_at": issue.get("updated_at", issue["created_at"]),
        "state": "open",
    }}
    if issue.get("pull"):
        entry["pull_request"] = {{"html_url": entry["html_url"]}}
    return entry


REQUEST_TITLE_SHOUTED = {title!r}


def duplicate_number_key(text):
    return text.replace('"number": ', '"number": 1, "number": ', 1)


ENTRY_DAMAGE = {{
    "missing-created-at": lambda e: e.pop("created_at"),
    "null-created-at": lambda e: e.update(created_at=None),
    "invalid-created-at": lambda e: e.update(created_at="yesterday"),
    "missing-number": lambda e: e.pop("number"),
    "invalid-identity": lambda e: e.update(
        html_url=e["html_url"].replace("https://github.com/", "https://example.test/")
    ),
    "missing-title": lambda e: e.pop("title"),
    "missing-body": lambda e: e.pop("body"),
    "missing-labels": lambda e: e.pop("labels"),
    "malformed-labels": lambda e: e.update(labels="enhancement"),
}}


with open(state_path + ".lock", "w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    with open(state_path) as handle:
        state = json.load(handle)
    state.setdefault("calls", []).append(args)

    def save():
        with open(state_path, "w") as handle:
            json.dump(state, handle)

    if args[:3] == ["api", "--method", "POST"]:
        repo = args[3][len("repos/"):-len("/issues")]
        request = json.loads(sys.stdin.read())
        mode = state.get("create_mode", "ok")
        if mode == "fail-before":
            save()
            sys.stderr.write("HTTP 502: Bad Gateway\\n")
            sys.exit(1)
        if mode == "slow":
            fcntl.flock(lock, fcntl.LOCK_UN)
            time.sleep(state.get("sleep", 0.5))
            fcntl.flock(lock, fcntl.LOCK_EX)
            with open(state_path) as handle:
                state = json.load(handle)
        number = max([i["number"] for i in state["issues"]] + [100]) + 1
        issue = {{
            "number": number, "title": request["title"], "body": request["body"],
            "labels": request.get("labels", []), "created_at": now(),
        }}
        if mode == "mismatch":
            issue["body"] = request["body"] + "tampered\\n"
        if mode == "other-repo":
            issue["html_url"] = f"https://github.com/someone/else/issues/{{number}}"
        state["issues"].append(issue)
        state["creates"] = state.get("creates", 0) + 1
        save()
        if mode == "fail-after":
            sys.stderr.write("error connecting to api.github.com: timeout\\n")
            sys.exit(1)
        if mode == "garbage-after":
            print("<html>not json</html>")
            sys.exit(0)
        text = json.dumps(issue_json(repo, issue))
        if mode == "duplicate-keys":
            text = duplicate_number_key(text)
        print(text)
        sys.exit(0)

    save()
    if args[:3] == ["api", "--method", "GET"]:
        path, _, query = args[3].partition("?")
        repo = path[len("repos/"):-len("/issues")]
        params = dict(part.split("=", 1) for part in query.split("&"))
        assert (params["state"], params["sort"], params["direction"]) == (
            "all", "created", "asc"
        ), params
        size, page = int(params["per_page"]), int(params["page"])
        mode = state.get("listing_mode", "ok")
        if page == 1:
            state["listing_passes"] = state.get("listing_passes", 0) + 1
            save()
        rows = sorted(
            (i for i in state["issues"]
             if i.get("updated_at", i["created_at"]) >= params["since"]),
            key=lambda i: (i["created_at"], i["number"]),
        )
        found = [issue_json(repo, issue) for issue in rows]
        # A successful `gh` whose evidence is incomplete or malformed.
        if mode == "unstable" and state["listing_passes"] % 2 == 0:
            found = found[:-1]
        # Content that changed between the two reads of one recovery: the
        # first read is a stale copy that alone would look like absence.
        if mode.startswith("drift-") and state["listing_passes"] % 2 == 1:
            for entry in found:
                if mode == "drift-title-body":
                    entry.update(title="Unrelated", body="unrelated\\n")
                elif mode == "drift-title":
                    entry["title"] = REQUEST_TITLE_SHOUTED
                elif mode == "drift-labels":
                    entry["labels"] = []
                elif mode == "drift-created-at":
                    entry["created_at"] = "2001-01-01T00:00:00Z"
                elif mode == "drift-pull-request":
                    entry["html_url"] = entry["html_url"].replace(
                        "/issues/", "/pull/"
                    )
                    entry["pull_request"] = {{"html_url": entry["html_url"]}}
        if mode == "non-object-entry":
            found.append("an issue")
        if mode == "pr-stub":
            found.append({{"pull_request": {{}}}})
        for entry in found:
            if mode in ENTRY_DAMAGE and isinstance(entry, dict):
                ENTRY_DAMAGE[mode](entry)
        if mode == "page-fails" and page > 1:
            sys.stderr.write("HTTP 502: Bad Gateway\\n")
            sys.exit(1)
        if mode == "endless":
            chunk = [
                issue_json(repo, {{
                    "number": 1000 * page + k, "title": f"other {{page}} {{k}}",
                    "body": "other\\n", "created_at": now(),
                }})
                for k in range(size)
            ]
        elif mode == "repeat-page" and page > 1:
            chunk = found[(page - 2) * size:(page - 1) * size]
        elif mode == "oversized-page":
            # More rows than requested, each distinct: a page that is not the
            # page asked for, whatever else it holds.
            chunk = found[(page - 1) * size:page * size]
            if page == 1:
                chunk = chunk + [issue_json(repo, {{
                    "number": 2000, "title": "other", "body": "other\\n",
                    "created_at": now(),
                }})]
        else:
            chunk = found[(page - 1) * size:page * size]
        text = json.dumps(chunk)
        if mode == "empty-output":
            text = ""
        elif mode == "not-an-array":
            text = json.dumps({{"message": "Server Error"}})
        elif mode == "truncated-page":
            text = text[:-1]
        elif mode == "trailing-data":
            text = text + "\\n" + text
        elif mode == "duplicate-keys":
            text = duplicate_number_key(text)
        print(text)
        sys.exit(0)
    if len(args) == 2 and args[0] == "api" and "/issues/" in args[1]:
        repo, _, number = args[1][len("repos/"):].partition("/issues/")
        for issue in state["issues"]:
            if str(issue["number"]) == number:
                entry = issue_json(repo, issue)
                read_mode = state.get("read_mode", "ok")
                if read_mode in ENTRY_DAMAGE:
                    ENTRY_DAMAGE[read_mode](entry)
                text = json.dumps(entry)
                if read_mode == "duplicate-keys":
                    text = duplicate_number_key(text)
                print(text)
                sys.exit(0)
        sys.stderr.write("gh: Not Found (HTTP 404)\\n")
        sys.exit(1)
    sys.stderr.write(f"fake gh: unsupported {{args}}\\n")
    sys.exit(2)
'''


def utc(delta_seconds=0):
    moment = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(
        seconds=delta_seconds
    )
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def plan_for(request=REQUEST, **overrides):
    body = {
        "entry_key": "MAT-1",
        "disposition": "new-issue",
        "steps": [
            {
                "kind": "issue-create",
                "target": "new issue in coghex/kanban",
                "payload_fingerprint": tool.payload_fingerprint(
                    tool.normalize_request(request)
                ),
                "postcondition": "the issue exists with the approved body",
                "provides_marker": True,
            },
            {
                "kind": "epic-checklist-edit",
                "target": "coghex/kanban#63",
                "payload_fingerprint": "sha256:checklist",
                "postcondition": "the epic checklist names the new child",
            },
        ],
    }
    body.update(overrides)
    return body


class Interrupted(BaseException):
    """A process killed mid-operation: not an Exception, so nothing catches it."""


class TrackedIssueFixture(git_fixture.GitTemplateMixin, unittest.TestCase):

    @classmethod
    def build_git_template(cls, root, data):
        Fixture.create(root)

    def setUp(self):
        self.fx = Fixture(self.checkout_git_template())
        self.state_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.state_dir.cleanup)
        bin_dir = Path(self.state_dir.name) / "bin"
        bin_dir.mkdir()
        self.gh_path = bin_dir / "gh"
        self.gh_path.write_text(FAKE_GH.format(
            python=sys.executable, title=REQUEST["title"].upper()
        ))
        self.gh_path.chmod(0o755)
        self.state_path = Path(self.state_dir.name) / "gh-state.json"
        self.write_state({"issues": []})
        patcher = unittest.mock.patch.dict(
            os.environ,
            {
                "FAKE_GH_STATE": str(self.state_path),
                "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
            },
        )
        patcher.start()
        self.addCleanup(patcher.stop)
        self.gh = tool.GhCli(str(self.gh_path))

    # -- fake GitHub state -----------------------------------------------------

    def write_state(self, state):
        self.state_path.write_text(json.dumps(state))

    def state(self):
        return json.loads(self.state_path.read_text())

    def set_state(self, **values):
        state = self.state()
        state.update(values)
        self.write_state(state)

    def posts(self):
        return [c for c in self.state().get("calls", []) if "POST" in c]

    def set_mode(self, mode, **extra):
        state = self.state()
        state["create_mode"] = mode
        state.update(extra)
        self.write_state(state)

    def seed(self, title, body, *, labels=("enhancement",), created_at=None,
             pull=False):
        state = self.state()
        number = max([i["number"] for i in state["issues"]] + [50]) + 1
        state["issues"].append({
            "number": number, "title": title, "body": body,
            "labels": list(labels), "created_at": created_at or utc(), "pull": pull,
        })
        self.write_state(state)
        return number

    def creates(self):
        return self.state().get("creates", 0)

    # -- the operation -----------------------------------------------------------

    def acquire(self, body=None):
        return self.fx.acquire(plan_for() if body is None else body)

    def create(self, step=0, request=REQUEST, *, approved=True, github=None,
               root=None, repository=REPOSITORY):
        return tool.create(
            root or self.fx.docs, repository, DOCUMENT, step, request,
            approved=approved, github=github or self.gh,
        )

    def inspect(self, step=0, request=REQUEST):
        return tool.inspect(
            self.fx.docs, REPOSITORY, DOCUMENT, step, request, github=self.gh
        )

    def reconcile(self, number, step=0, *, approved=True):
        return tool.reconcile(
            self.fx.docs, REPOSITORY, DOCUMENT, step, REQUEST, number,
            approved=approved, github=self.gh,
        )

    def authorize_retry(self, step=0, *, approved=True):
        return tool.authorize_retry(
            self.fx.docs, REPOSITORY, DOCUMENT, step, REQUEST,
            approved=approved, github=self.gh,
        )

    def step_state(self, index=0):
        record, _ = self.fx.read()
        return record["steps"][index]

    def assert_refused_without_mutation(self, outcome, status):
        self.assertFalse(outcome["ok"], outcome)
        self.assertEqual(outcome["status"], status, outcome)
        self.assertEqual(outcome["github_mutation"], "none", outcome)
        self.assertEqual(self.creates(), 0, outcome)

    def lock_ref(self):
        """Make every update of the transaction reference fail, the way a
        concurrent writer's lock or an unwritable repository does."""
        common = Path(run(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            self.fx.docs,
        ))
        lock = common / (self.fx.ref() + ".lock")
        lock.parent.mkdir(parents=True, exist_ok=True)
        lock.write_text("held\n")
        self.addCleanup(lock.unlink, missing_ok=True)
        return lock


class RequestTests(unittest.TestCase):

    def test_the_fingerprint_is_canonical_over_label_order_and_line_endings(self):
        one = tool.normalize_request(REQUEST | {"labels": ["b", "a", "a"]})
        two = tool.normalize_request(
            REQUEST | {"labels": ["a", "b"], "body": REQUEST["body"].replace("\n", "\r\n")}
        )
        self.assertEqual(tool.payload_fingerprint(one), tool.payload_fingerprint(two))
        self.assertTrue(tool.payload_fingerprint(one).startswith("issue-v1:sha256:"))

    def test_any_change_to_the_payload_changes_the_fingerprint(self):
        base = tool.payload_fingerprint(tool.normalize_request(REQUEST))
        for change in (
            {"title": REQUEST["title"] + "!"},
            {"body": REQUEST["body"] + "x"},
            {"labels": ["enhancement", "bug"]},
        ):
            with self.subTest(change=change):
                self.assertNotEqual(
                    base, tool.payload_fingerprint(tool.normalize_request(REQUEST | change))
                )

    def test_malformed_requests_are_refused(self):
        for bad in (
            [],
            REQUEST | {"assignees": ["x"]},
            REQUEST | {"title": "  "},
            REQUEST | {"title": "two\nlines"},
            REQUEST | {"title": "x" * 257},
            REQUEST | {"body": ""},
            REQUEST | {"body": "x" * 65537},
            REQUEST | {"labels": "enhancement"},
            REQUEST | {"labels": [""]},
        ):
            with self.subTest(bad=str(bad)[:60]):
                with self.assertRaises(tool.OperationError) as caught:
                    tool.normalize_request(bad)
                self.assertEqual(caught.exception.status, "request-invalid")


class CreateTests(TrackedIssueFixture):

    def test_creates_confirms_and_reports_the_returned_identity(self):
        self.acquire()
        outcome = self.create()
        self.assertTrue(outcome["ok"], outcome)
        self.assertEqual(outcome["status"], "created")
        self.assertEqual(outcome["github_mutation"], "performed")
        number = outcome["issue"]["number"]
        self.assertEqual(
            outcome["issue"]["url"], f"https://github.com/coghex/kanban/issues/{number}"
        )
        self.assertEqual(outcome["correlation"]["step"], 0)
        self.assertEqual(outcome["correlation"]["transaction_ref"], self.fx.ref())
        self.assertEqual(
            outcome["correlation"]["payload_fingerprint"],
            plan_for()["steps"][0]["payload_fingerprint"],
        )
        step = self.step_state()
        self.assertEqual(step["state"], "confirmed")
        self.assertEqual(step["identity"]["id"], str(number))
        self.assertEqual(step["identity"]["document_token"], f"[#{number}]")
        self.assertEqual(outcome["transaction"]["transaction_state"], "tracker-pending")
        self.assertEqual(self.creates(), 1)
        # Exactly the approved payload was sent, through the REST API.
        post = [c for c in self.state()["calls"] if c[:3] == ["api", "--method", "POST"]]
        self.assertEqual(post, [["api", "--method", "POST",
                                 "repos/coghex/kanban/issues", "--input", "-"]])
        created = self.state()["issues"][0]
        self.assertEqual(
            {k: created[k] for k in ("title", "body", "labels")},
            tool.normalize_request(REQUEST),
        )

    def test_intent_is_durable_before_github_is_called(self):
        self.acquire()
        seen = {}

        class Watching(tool.GhCli):
            def create_issue(inner, repository, request):
                seen["state"] = self.step_state()["state"]
                return super().create_issue(repository, request)

        outcome = self.create(github=Watching(str(self.gh_path)))
        self.assertEqual(outcome["status"], "created", outcome)
        self.assertEqual(seen["state"], "intent")

    def test_an_epic_creation_step_is_created_the_same_way(self):
        label_plan = plan_for()
        label_plan.update(disposition="epic-create", steps=[
            {
                "kind": "label-create", "target": "label arc in coghex/kanban",
                "payload_fingerprint": "sha256:label", "postcondition": "exists",
                "approved_name": "arc", "approved_metadata": {"color": "ededed"},
            },
            plan_for()["steps"][0] | {"kind": "epic-create"},
        ])
        self.acquire(label_plan)
        self.fx.begin(0)
        self.fx.confirm(0, {
            "kind": "label-create", "id": "arc", "metadata": {"color": "ededed"},
            "postcondition_verified": True,
        })
        outcome = self.create(step=1)
        self.assertEqual(outcome["status"], "created", outcome)
        self.assertEqual(outcome["transaction"]["transaction_state"], "mutation-confirmed")

    def test_a_repeated_create_after_success_creates_nothing(self):
        self.acquire()
        first = self.create()
        again = self.create()
        self.assertTrue(again["ok"], again)
        self.assertEqual(again["status"], "already-created")
        self.assertEqual(again["github_mutation"], "none")
        self.assertEqual(again["issue"], first["issue"])
        self.assertTrue(again["content_matches"])
        self.assertEqual(self.creates(), 1)

    def test_a_confirmed_issue_that_is_gone_is_reported_and_never_recreated(self):
        self.acquire()
        self.create()
        state = self.state()
        state["issues"] = []
        self.write_state(state)
        outcome = self.create()
        self.assertFalse(outcome["ok"])
        self.assertEqual(outcome["status"], "confirmed-artifact-missing")
        self.assertEqual(self.creates(), 1)


class RefusalBeforeMutationTests(TrackedIssueFixture):

    def test_a_failed_begin_refuses_creation(self):
        # The incident: begin failed, and the caller created the issue anyway.
        self.acquire()
        self.lock_ref()
        outcome = self.create()
        self.assert_refused_without_mutation(outcome, "begin-failed")
        self.assertEqual(outcome["cause"], "record-changed")
        self.assertEqual(self.step_state()["state"], "planned")
        self.assertEqual(outcome["transaction"]["transaction_state"], "intent-only")

    def test_any_begin_error_refuses_creation(self):
        self.acquire()
        with unittest.mock.patch.object(
            tracker, "write_record",
            side_effect=tracker.TransactionError("record-changed", "lost the race"),
        ):
            outcome = self.create()
        self.assert_refused_without_mutation(outcome, "begin-failed")
        self.assertEqual(outcome["cause"], "record-changed")

    def test_no_transaction_refuses(self):
        self.assert_refused_without_mutation(self.create(), "no-transaction")

    def test_an_unreadable_transaction_refuses(self):
        self.fx.plant_unreadable_record()
        outcome = self.create()
        self.assert_refused_without_mutation(outcome, "record-unreadable")
        self.assertEqual(outcome["transaction"]["transaction_ref"], self.fx.ref())

    def test_a_request_that_is_not_the_approved_payload_refuses(self):
        self.acquire()
        outcome = self.create(request=REQUEST | {"title": "Something else"})
        self.assert_refused_without_mutation(outcome, "payload-mismatch")
        self.assertEqual(self.step_state()["state"], "planned")

    def test_a_step_that_creates_no_issue_refuses(self):
        self.acquire()
        self.assert_refused_without_mutation(
            self.create(step=1), "step-not-issue-creation"
        )
        self.assert_refused_without_mutation(self.create(step=7), "step-out-of-range")

    def test_a_step_whose_predecessor_is_unconfirmed_refuses(self):
        later = plan_for()
        later["steps"] = [
            later["steps"][1] | {"target": "coghex/kanban#63"},
            later["steps"][0],
        ]
        self.acquire(later)
        outcome = self.create(step=1)
        self.assert_refused_without_mutation(outcome, "begin-failed")
        self.assertEqual(outcome["cause"], "steps-out-of-order")

    def test_an_unapproved_creation_refuses(self):
        self.acquire()
        self.assert_refused_without_mutation(
            self.create(approved=False), "approval-required"
        )
        self.assertEqual(self.step_state()["state"], "planned")

    def test_a_missing_gh_refuses_before_intent_is_recorded(self):
        self.acquire()
        self.assert_refused_without_mutation(
            self.create(github=tool.GhCli("")), "gh-unavailable"
        )
        self.assertEqual(self.step_state()["state"], "planned")

    def assert_target_refused(self, target, status, kind="issue-create"):
        body = plan_for()
        body["steps"][0] = body["steps"][0] | {"target": target, "kind": kind}
        self.acquire(body)
        _, before = self.fx.read()
        outcome = self.create()
        self.assert_refused_without_mutation(outcome, status)
        # Not one gh call, and the record never left planned.
        self.assertEqual(self.state().get("calls", []), [])
        self.assertEqual(self.fx.read()[1], before)
        self.assertEqual(self.step_state()["state"], "planned")
        self.assertEqual(self.inspect()["status"], status)
        self.assertEqual(self.authorize_retry()["status"], status)
        self.assertEqual(self.reconcile(101)["status"], status)
        self.assertEqual(self.creates(), 0)

    def test_a_plan_targeting_another_repository_creates_nothing(self):
        self.assert_target_refused("new issue in someone/else", "target-mismatch")

    def test_an_epic_targeting_another_repository_creates_nothing(self):
        self.assert_target_refused(
            "new epic in someone/else", "target-mismatch", kind="epic-create"
        )

    def test_a_target_naming_a_similar_repository_creates_nothing(self):
        self.assert_target_refused("new issue in coghex/kanban-fork", "target-mismatch")

    def test_a_target_naming_a_repository_url_elsewhere_creates_nothing(self):
        self.assert_target_refused(
            "new issue in https://github.com/someone/else", "target-mismatch"
        )

    def test_a_target_naming_no_repository_creates_nothing(self):
        self.assert_target_refused("a new issue", "target-unverifiable")

    def test_a_target_naming_several_repositories_creates_nothing(self):
        self.assert_target_refused(
            "new issue in coghex/kanban mirroring someone/else#3",
            "target-unverifiable",
        )

    def test_a_target_naming_the_repository_in_another_case_creates(self):
        body = plan_for()
        body["steps"][0]["target"] = "new issue in Coghex/Kanban under epic #63"
        self.acquire(body)
        self.assertEqual(self.create()["status"], "created")
        self.assertEqual(self.creates(), 1)

    def test_a_write_root_of_another_repository_refuses(self):
        self.acquire()
        self.assert_refused_without_mutation(
            self.create(repository="someone/else"), "owner-mismatch"
        )


class UncertainOutcomeTests(TrackedIssueFixture):

    def assert_ambiguous(self, outcome, status, mutation):
        self.assertFalse(outcome["ok"], outcome)
        self.assertEqual(outcome["status"], status, outcome)
        self.assertEqual(outcome["github_mutation"], mutation, outcome)
        self.assertEqual(self.step_state()["state"], "intent")
        self.assertEqual(outcome["transaction"]["ambiguous_step"]["index"], 0)
        self.assertIn("--inspect", outcome["next_action"])

    def test_a_failure_github_never_accepted_recovers_through_an_approved_retry(self):
        self.acquire()
        self.set_mode("fail-before")
        self.assert_ambiguous(self.create(), "outcome-uncertain", "unknown")
        # Never created again automatically.
        self.set_mode("ok")
        refused = self.create()
        self.assertEqual(refused["status"], "step-ambiguous")
        self.assertEqual(refused["github_mutation"], "none")
        self.assertEqual(self.creates(), 0)
        found = self.inspect()
        self.assertEqual(found["candidates"]["evidence"], "absent", found)
        self.assertEqual(self.authorize_retry(approved=False)["status"], "approval-required")
        self.assertEqual(self.step_state()["state"], "intent")
        retried = self.authorize_retry()
        self.assertEqual(retried["status"], "retry-authorized", retried)
        self.assertEqual(self.creates(), 0)
        self.assertEqual(self.create()["status"], "created")
        self.assertEqual(self.creates(), 1)

    def test_a_failure_after_github_accepted_binds_the_created_issue(self):
        self.acquire()
        self.set_mode("fail-after")
        self.assert_ambiguous(self.create(), "outcome-uncertain", "unknown")
        number = self.state()["issues"][0]["number"]
        found = self.inspect()
        self.assertEqual(found["candidates"]["evidence"], "unique-exact")
        self.assertEqual([c["number"] for c in found["candidates"]["exact"]], [number])
        self.assertEqual(self.authorize_retry()["status"], "retry-refused")
        self.assertEqual(self.reconcile(number + 1)["status"], "candidates-not-unique")
        self.assertEqual(self.reconcile(number, approved=False)["status"], "approval-required")
        self.assertEqual(self.step_state()["state"], "intent")
        bound = self.reconcile(number)
        self.assertEqual(bound["status"], "reconciled", bound)
        self.assertEqual(self.step_state()["identity"]["id"], str(number))
        self.set_mode("ok")
        again = self.create()
        self.assertEqual(again["status"], "already-created")
        self.assertEqual(self.creates(), 1)

    def test_an_unusable_success_response_stays_ambiguous(self):
        self.acquire()
        self.set_mode("garbage-after")
        outcome = self.create()
        self.assert_ambiguous(outcome, "outcome-uncertain", "unknown")
        self.assertIn("not json", outcome["response"])
        self.assertEqual(self.reconcile(self.state()["issues"][0]["number"])["status"],
                         "reconciled")

    def test_a_response_naming_another_repository_is_not_confirmed(self):
        self.acquire()
        self.set_mode("other-repo")
        self.assert_ambiguous(self.create(), "outcome-uncertain", "unknown")

    def test_a_created_issue_that_is_not_the_approved_one_is_never_bound(self):
        self.acquire()
        self.set_mode("mismatch")
        outcome = self.create()
        self.assert_ambiguous(outcome, "created-mismatch", "performed")
        number = outcome["issue"]["number"]
        found = self.inspect()
        self.assertEqual(found["candidates"]["evidence"], "ambiguous")
        self.assertEqual(self.reconcile(number)["status"], "candidates-not-unique")
        self.assertEqual(self.authorize_retry()["status"], "retry-refused")
        self.assertEqual(self.step_state()["state"], "intent")

    def test_a_failed_confirmation_keeps_the_created_identity_for_reconciliation(self):
        self.acquire()
        with unittest.mock.patch.object(
            tracker, "action_confirm",
            side_effect=tracker.TransactionError("git-failed", "disk full"),
        ):
            outcome = self.create()
        self.assert_ambiguous(outcome, "created-unconfirmed", "performed")
        number = outcome["issue"]["number"]
        self.assertEqual(self.reconcile(number)["status"], "reconciled")
        self.assertEqual(self.create()["status"], "already-created")
        self.assertEqual(self.creates(), 1)

    def test_an_interruption_before_the_request_needs_an_approved_retry(self):
        self.acquire()

        class Killed(tool.GhCli):
            def create_issue(inner, repository, request):
                raise Interrupted()

        with self.assertRaises(Interrupted):
            self.create(github=Killed(str(self.gh_path)))
        self.assertEqual(self.step_state()["state"], "intent")
        self.assertEqual(self.create()["status"], "step-ambiguous")
        self.assertEqual(self.inspect()["candidates"]["evidence"], "absent")
        self.assertEqual(self.authorize_retry()["status"], "retry-authorized")
        self.assertEqual(self.create()["status"], "created")
        self.assertEqual(self.creates(), 1)

    def test_an_interruption_after_github_accepted_is_never_created_twice(self):
        self.acquire()

        class KilledAfter(tool.GhCli):
            def create_issue(inner, repository, request):
                super().create_issue(repository, request)
                raise Interrupted()

        with self.assertRaises(Interrupted):
            self.create(github=KilledAfter(str(self.gh_path)))
        self.assertEqual(self.create()["status"], "step-ambiguous")
        self.assertEqual(self.authorize_retry()["status"], "retry-refused")
        number = self.state()["issues"][0]["number"]
        self.assertEqual(self.reconcile(number)["status"], "reconciled")
        self.assertEqual(self.creates(), 1)

    def test_duplicate_exact_candidates_permit_neither_binding_nor_retry(self):
        self.acquire()
        self.set_mode("fail-after")
        self.create()
        duplicate = self.seed(REQUEST["title"], REQUEST["body"])
        self.assertEqual(self.inspect()["candidates"]["evidence"], "ambiguous")
        self.assertEqual(self.reconcile(duplicate)["status"], "candidates-not-unique")
        self.assertEqual(self.authorize_retry()["status"], "retry-refused")

    def test_a_similarly_titled_issue_is_never_evidence(self):
        self.acquire()
        self.set_mode("fail-before")
        self.create()
        similar = self.seed(REQUEST["title"], "a different body\n")
        found = self.inspect()
        self.assertEqual(found["candidates"]["evidence"], "ambiguous")
        self.assertEqual([c["number"] for c in found["candidates"]["similar"]], [similar])
        self.assertEqual(self.reconcile(similar)["status"], "candidates-not-unique")
        self.assertEqual(self.authorize_retry()["status"], "retry-refused")
        self.assertEqual(self.step_state()["state"], "intent")

    def test_issues_from_before_the_step_began_are_not_candidates(self):
        self.seed(REQUEST["title"], REQUEST["body"], created_at=utc(-2 * 86400))
        self.acquire()
        self.set_mode("fail-before")
        self.create()
        found = self.inspect()
        self.assertEqual(found["candidates"]["evidence"], "absent", found)

    def test_recovery_actions_refuse_a_step_that_is_not_ambiguous(self):
        self.acquire()
        self.assertEqual(self.inspect()["status"], "step-not-ambiguous")
        self.assertEqual(self.reconcile(1)["status"], "step-not-ambiguous")
        self.assertEqual(self.authorize_retry()["status"], "step-not-ambiguous")

    def test_an_ambiguous_step_is_seen_from_another_linked_worktree(self):
        self.acquire()
        self.set_mode("fail-after")
        self.create()
        self.set_mode("ok")
        elsewhere = self.fx.linked()
        outcome = self.create(root=elsewhere)
        self.assertEqual(outcome["status"], "step-ambiguous")
        self.assertEqual(self.creates(), 1)


# Every way a successful `gh` can return evidence that is incomplete,
# malformed, or not a consistent view. Each runs at a page size of one, so a
# one-issue listing spans a full page and a conclusive empty one.
MALFORMED_LISTINGS = (
    "empty-output", "not-an-array", "non-object-entry", "pr-stub",
    "missing-created-at", "null-created-at", "invalid-created-at",
    "missing-number", "invalid-identity", "missing-title", "missing-body",
    "missing-labels", "malformed-labels", "duplicate-keys", "truncated-page",
    "trailing-data", "page-fails", "repeat-page", "oversized-page", "endless",
    "unstable",
)


class IncompleteEvidenceTests(TrackedIssueFixture):
    """Recovery decides only on complete evidence. Each case leaves an issue
    GitHub really created behind an uncertain outcome, then has the listing
    succeed with evidence that is incomplete or malformed; were any of these
    read as absence, an approved retry would create the issue a second time."""

    def setUp(self):
        super().setUp()
        for name, value in (("LISTING_PAGE_SIZE", 1), ("LISTING_PAGE_LIMIT", 3)):
            patcher = unittest.mock.patch.object(tool, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def assert_retains_intent(self, outcome):
        self.assertFalse(outcome["ok"], outcome)
        self.assertEqual(outcome["status"], "evidence-incomplete", outcome)
        self.assertEqual(outcome["github_mutation"], "none", outcome)
        self.assertNotIn("candidates", outcome)
        self.assertEqual(outcome["transaction"]["ambiguous_step"]["index"], 0)
        self.assertEqual(self.step_state()["state"], "intent")

    def assert_creation_blocked(self, creates):
        """Another --create is refused without even attempting a request."""
        attempts = len(self.posts())
        again = self.create()
        self.assertEqual(again["status"], "step-ambiguous", again)
        self.assertEqual(again["github_mutation"], "none")
        self.assertEqual(len(self.posts()), attempts)
        self.assertEqual(self.creates(), creates)

    def uncertain_creation(self):
        self.acquire()
        self.set_mode("fail-after")
        uncertain = self.create()
        self.assertEqual(uncertain["github_mutation"], "unknown")
        self.set_state(create_mode="ok")
        return self.state()["issues"][0]["number"]

    def test_malformed_evidence_never_permits_retry_or_a_duplicate(self):
        for mode in MALFORMED_LISTINGS:
            with self.subTest(listing=mode):
                self.write_state({"issues": []})
                self.fx = Fixture(self.checkout_git_template())
                number = self.uncertain_creation()
                self.set_state(listing_mode=mode)

                self.assert_retains_intent(self.inspect())
                self.assert_retains_intent(self.authorize_retry())
                self.assert_retains_intent(self.reconcile(number))
                self.assert_creation_blocked(1)

                # Complete evidence then finds the one issue it already made.
                self.set_state(listing_mode="ok")
                self.assertEqual(self.authorize_retry()["status"], "retry-refused")
                self.assertEqual(self.reconcile(number)["status"], "reconciled")
                self.assertEqual(self.create()["status"], "already-created")
                self.assertEqual(self.creates(), 1)

    def test_content_that_changes_between_reads_is_not_evidence(self):
        # Same numbers in both reads, different content. The stale read alone
        # says absent for title-body, created-at and pull-request drift (and
        # similar or not exact for the others), so judging it would authorize
        # a retry that creates the issue again.
        for mode in ("drift-title-body", "drift-title", "drift-labels",
                     "drift-created-at", "drift-pull-request"):
            with self.subTest(listing=mode):
                self.write_state({"issues": []})
                self.fx = Fixture(self.checkout_git_template())
                number = self.uncertain_creation()
                self.set_state(listing_mode=mode)

                self.assert_retains_intent(self.inspect())
                self.assert_retains_intent(self.authorize_retry())
                self.assert_retains_intent(self.reconcile(number))
                self.assert_creation_blocked(1)

                self.set_state(listing_mode="ok")
                self.assertEqual(self.authorize_retry()["status"], "retry-refused")
                self.assertEqual(self.reconcile(number)["status"], "reconciled")
                self.assertEqual(self.create()["status"], "already-created")
                self.assertEqual(self.creates(), 1)

    def test_an_edited_title_with_an_omitted_body_is_not_absence(self):
        number = self.uncertain_creation()
        state = self.state()
        state["issues"][0]["title"] = "Renamed by a person"
        self.write_state(state)
        self.set_state(listing_mode="missing-body")
        self.assert_retains_intent(self.inspect())
        self.assert_retains_intent(self.authorize_retry())
        self.assert_creation_blocked(1)
        # Whole, the same issue is similar by body: still never retried, and
        # not an exact match to bind either, so the step stays unresolved.
        self.set_state(listing_mode="ok")
        found = self.inspect()
        self.assertEqual(found["candidates"]["evidence"], "ambiguous", found)
        self.assertEqual(
            [c["number"] for c in found["candidates"]["similar"]], [number]
        )
        self.assertEqual(self.authorize_retry()["status"], "retry-refused")
        self.assertEqual(self.reconcile(number)["status"], "candidates-not-unique")
        self.assertEqual(self.step_state()["state"], "intent")
        self.assert_creation_blocked(1)

    def test_a_legitimately_null_body_is_evidence_not_damage(self):
        self.acquire()
        self.set_mode("fail-before")
        self.create()
        similar = self.seed(REQUEST["title"], None)
        found = self.inspect()
        self.assertEqual(found["status"], "inspected", found)
        self.assertEqual(
            [c["number"] for c in found["candidates"]["similar"]], [similar]
        )
        self.assertEqual(self.authorize_retry()["status"], "retry-refused")
        self.assert_creation_blocked(0)

    def test_pull_request_rows_are_validated_before_they_are_excluded(self):
        self.acquire()
        self.set_mode("fail-before")
        self.create()
        self.seed(REQUEST["title"], REQUEST["body"], pull=True)
        # Whole, a pull request is never a candidate.
        self.assertEqual(self.inspect()["candidates"]["evidence"], "absent")
        for mode in ("pr-stub", "missing-created-at", "missing-body",
                     "invalid-identity", "missing-number"):
            with self.subTest(listing=mode):
                self.set_state(listing_mode=mode)
                self.assert_retains_intent(self.inspect())
                self.assert_retains_intent(self.authorize_retry())
                self.assert_creation_blocked(0)
        self.set_state(listing_mode="ok")
        self.assertEqual(self.authorize_retry()["status"], "retry-authorized")

    def test_a_listing_of_exactly_full_pages_ends_on_a_conclusive_empty_page(self):
        number = self.uncertain_creation()
        found = self.inspect()
        self.assertEqual(found["candidates"]["evidence"], "unique-exact", found)
        pages = [
            call[3].rsplit("page=", 1)[1] for call in self.state()["calls"]
            if call[:3] == ["api", "--method", "GET"]
        ]
        # Two passes, each a full page then the empty page that ends it.
        self.assertEqual(pages, ["1", "2", "1", "2"])
        self.assertEqual(self.reconcile(number)["status"], "reconciled")

    def test_a_complete_empty_listing_permits_only_an_approved_retry(self):
        self.acquire()
        self.set_mode("fail-before")
        self.create()
        self.assertEqual(self.inspect()["candidates"]["evidence"], "absent")
        refused = self.authorize_retry(approved=False)
        self.assertEqual(refused["status"], "approval-required")
        self.assert_creation_blocked(0)
        self.assertEqual(self.authorize_retry()["status"], "retry-authorized")
        self.set_mode("ok")
        self.assertEqual(self.create()["status"], "created")
        self.assertEqual(self.creates(), 1)

    def test_empty_output_is_not_an_empty_listing(self):
        # Nothing was created, but empty output still proves nothing.
        self.acquire()
        self.set_mode("fail-before")
        self.create()
        self.set_state(listing_mode="empty-output")
        self.assert_retains_intent(self.authorize_retry())
        self.assert_creation_blocked(0)

    def test_a_malformed_create_response_is_never_confirmed(self):
        for mode, damage in (("duplicate-keys", None), ("ok", "title"),
                             ("ok", "body"), ("ok", "created_at")):
            with self.subTest(response=mode, omitted=damage):
                self.write_state({"issues": []})
                self.fx = Fixture(self.checkout_git_template())
                self.acquire()
                self.set_mode(mode)

                class Damaged(tool.GhCli):
                    def create_issue(inner, repository, request):
                        proc = super().create_issue(repository, request)
                        if damage is None:
                            return proc
                        created = json.loads(proc.stdout)
                        del created[damage]
                        return subprocess.CompletedProcess(
                            proc.args, 0, json.dumps(created), ""
                        )

                outcome = self.create(github=Damaged(str(self.gh_path)))
                self.assertEqual(outcome["status"], "outcome-uncertain", outcome)
                self.assertEqual(outcome["github_mutation"], "unknown")
                self.assertEqual(self.step_state()["state"], "intent")
                self.set_mode("ok")
                self.assert_creation_blocked(1)

    def test_a_malformed_read_back_of_a_confirmed_issue_is_not_absence(self):
        self.acquire()
        self.create()
        for mode in ("missing-title", "missing-body", "duplicate-keys",
                     "invalid-identity"):
            with self.subTest(read=mode):
                self.set_state(read_mode=mode)
                outcome = self.create()
                self.assertEqual(outcome["status"], "verification-failed", outcome)
                self.assertEqual(outcome["github_mutation"], "none")
                self.assertEqual(self.creates(), 1)


class ConcurrencyTests(TrackedIssueFixture):

    def test_concurrent_creations_of_one_step_create_exactly_one_issue(self):
        self.acquire()
        self.set_mode("slow", sleep=0.3)
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            outcomes = list(pool.map(lambda _: self.create(), range(6)))
        created = [o for o in outcomes if o["status"] == "created"]
        self.assertEqual(len(created), 1, [o["status"] for o in outcomes])
        for other in outcomes:
            if other is created[0]:
                continue
            self.assertEqual(other["github_mutation"], "none", other)
            self.assertIn(
                other["status"], ("begin-failed", "step-ambiguous", "already-created")
            )
        self.assertEqual(self.creates(), 1)
        self.assertEqual(self.step_state()["state"], "confirmed")

    def test_concurrent_processes_create_exactly_one_issue(self):
        self.acquire()
        self.set_mode("slow", sleep=0.3)
        request = Path(self.state_dir.name) / "request.json"
        request.write_text(json.dumps(REQUEST))
        command = [
            sys.executable, str(REPO_ROOT / "tools" / "tracked_issue_create.py"),
            "--repo", REPOSITORY, "--root", str(self.fx.docs), "--path", DOCUMENT,
            "--step", "0", "--request", str(request), "--create", "--approved",
        ]
        processes = [
            subprocess.Popen(command, stdout=subprocess.PIPE, text=True)
            for _ in range(4)
        ]
        outcomes = [json.loads(p.communicate()[0]) for p in processes]
        self.assertEqual(
            sum(o["status"] == "created" for o in outcomes), 1,
            [o["status"] for o in outcomes],
        )
        self.assertEqual(self.creates(), 1)


class CommandLineTests(TrackedIssueFixture):

    def cli(self, *args, request=REQUEST):
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            with unittest.mock.patch("sys.stdin", io.StringIO(json.dumps(request))):
                code = tool.main([*args, "--request", "-"])
        return code, json.loads(buffer.getvalue())

    def common(self):
        return ("--repo", REPOSITORY, "--root", str(self.fx.docs),
                "--path", DOCUMENT, "--step", "0")

    def test_fingerprint_prints_what_the_plan_records(self):
        code, outcome = self.cli("--fingerprint")
        self.assertEqual(code, 0)
        self.assertEqual(
            outcome["payload_fingerprint"], plan_for()["steps"][0]["payload_fingerprint"]
        )

    def test_create_through_gh_on_path_returns_one_structured_result(self):
        self.acquire()
        code, outcome = self.cli(*self.common(), "--create", "--approved")
        self.assertEqual(code, 0, outcome)
        self.assertEqual(outcome["status"], "created")
        self.assertEqual(self.creates(), 1)

    def test_a_refusal_exits_nonzero_with_a_structured_result(self):
        code, outcome = self.cli(*self.common(), "--create", "--approved")
        self.assertEqual(code, 1)
        self.assertEqual(outcome["status"], "no-transaction")
        self.assertEqual(outcome["github_mutation"], "none")

    def test_an_uncertain_outcome_exits_nonzero_and_says_so(self):
        self.acquire()
        self.set_mode("fail-after")
        code, outcome = self.cli(*self.common(), "--create", "--approved")
        self.assertEqual(code, 1)
        self.assertEqual(outcome["github_mutation"], "unknown")
        code, outcome = self.cli(*self.common(), "--inspect")
        self.assertEqual(code, 0)
        number = outcome["candidates"]["exact"][0]["number"]
        code, outcome = self.cli(
            *self.common(), "--reconcile", "--issue", str(number), "--approved"
        )
        self.assertEqual((code, outcome["status"]), (0, "reconciled"))

    def test_actions_require_their_arguments(self):
        for args in (("--create",), (*self.common(), "--reconcile", "--approved")):
            with self.subTest(args=args):
                with contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as caught:
                        self.cli(*args)
                self.assertEqual(caught.exception.code, 2)

    def test_an_unreadable_request_is_refused(self):
        self.acquire()
        duplicated = json.dumps(REQUEST).replace(
            '"title": ', '"title": "Something else", "title": ', 1
        )
        for text in ("not json", "", duplicated, json.dumps(REQUEST) + " {}"):
            with self.subTest(request=text[:40]):
                buffer = io.StringIO()
                with contextlib.redirect_stdout(buffer):
                    with unittest.mock.patch("sys.stdin", io.StringIO(text)):
                        code = tool.main(
                            [*self.common(), "--create", "--approved", "--request", "-"]
                        )
                self.assertEqual(code, 1)
                outcome = json.loads(buffer.getvalue())
                self.assertEqual(outcome["status"], "request-unreadable", outcome)
                self.assertEqual(outcome["github_mutation"], "none")
        self.assertEqual(self.creates(), 0)
        self.assertEqual(self.step_state()["state"], "planned")


if __name__ == "__main__":
    unittest.main()
