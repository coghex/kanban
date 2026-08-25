"""Executable coverage for tools/tracker_transaction.py.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Issue #327. Every case below drives the real record against temporary Git
repositories, in the same shape tools/test_publish_coordination_doc.py drives
the publication mechanism: a bare origin, a primary clone, and — because the
declared assets write in the `docs-wip` linked worktree — a linked worktree on
another branch as the ordinary write root.

The ambiguity windows are the point. A tracker mutation is irreversible and has
no server-side idempotency key, so what has to be proven executable is the set
of things this module *refuses*: repeating a confirmed mutation, adopting a
similarly titled artifact, clearing a record whose disposition never reached the
document, and letting two runs that both saw a clear preflight both proceed.
"""

from __future__ import annotations

import concurrent.futures
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# `python3 -m unittest tools.test_tracker_transaction` imports this module by
# package path, which puts the repository root on sys.path rather than tools/
# -- unlike `-m unittest discover -s tools`. Both invocations have to reach
# the sibling module, so name the directory outright.
sys.path.insert(0, str(REPO_ROOT / "tools"))

import git_fixture


def _load(name, filename):
    source = REPO_ROOT / "tools" / filename
    spec = importlib.util.spec_from_file_location(name, source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tracker = _load("_kanban_tracker_transaction_under_test", "tracker_transaction.py")
publisher = _load("_kanban_publish_helper_for_tracker", "publish_coordination_doc.py")


# Issue #370 made eligibility for an owner outside §7 a question about the
# machine's Kanban configuration, so every case below has to answer it from a
# known one rather than from whatever the developer running the suite happens
# to have. An empty directory is "no configuration", which is the documented
# default and the state a consuming repository that declares nothing is in.
_CONFIG_ISOLATION = None


def setUpModule():
    global _CONFIG_ISOLATION
    _CONFIG_ISOLATION = tempfile.TemporaryDirectory()
    os.environ["XDG_CONFIG_HOME"] = _CONFIG_ISOLATION.name


def tearDownModule():
    os.environ.pop("XDG_CONFIG_HOME", None)
    _CONFIG_ISOLATION.cleanup()


CLASSIFICATION = """# Contract

## 7. Document publication classification

```text
docs/ui-bugs.md | coordination | audit-report
docs/design.md | pr-atomic | test-parsed
```

## 8. Next section
"""

# A report-shaped document: a status checklist whose entry keys are the finding
# IDs, exactly the cursor `process-report` treats as durable.
DOCUMENT = """# Findings

## Status

- [ ] DW-3. Checkpoint tracker mutations
- [ ] DW-4. Something else

### DW-3 — Checkpoint tracker mutations

Body.

### DW-4 — Something else

Body.
"""


def run(args, cwd, **kw):
    proc = subprocess.run(args, cwd=str(cwd), capture_output=True, text=True, **kw)
    if proc.returncode != 0:
        raise AssertionError(f"{args} failed in {cwd}:\n{proc.stderr}")
    return proc.stdout.strip()


# The tip a disposition was prepared against, bound on the command line so the
# plan itself can travel through a quoted heredoc.
PREPARED_TIP = "0" * 40


def plan(**overrides):
    """The ordinary two-step child disposition: create the issue, then edit the
    umbrella epic's checklist. Two steps because one is the case that never
    exposed the bug — a disposition that dies between its mutations is what
    issue #327 is about."""
    body = {
        "entry_key": "DW-3",
        "disposition": "new-issue",
        "steps": [
            {
                "kind": "issue-create",
                "target": "new issue in coghex/kanban",
                "payload_fingerprint": "sha256:body",
                "postcondition": "the issue exists with the approved body",
                "provides_marker": True,
            },
            {
                "kind": "epic-checklist-edit",
                "target": "coghex/kanban#300",
                "payload_fingerprint": "sha256:checklist",
                "postcondition": "the epic checklist names the new child",
            },
        ],
    }
    body.update(overrides)
    return body


def issue_identity(number=311, **overrides):
    body = {
        "kind": "issue-create",
        "id": str(number),
        "url": f"https://github.com/coghex/kanban/issues/{number}",
        "document_token": f"[#{number}]",
        "postcondition_verified": True,
    }
    body.update(overrides)
    return body


def record_json(*, step_overrides=None, **overrides):
    """A persisted record that is valid except for what `overrides` breaks, so
    each case below isolates exactly one fault."""
    step = {
        "kind": "issue-create",
        "target": "new issue in coghex/kanban",
        "payload_fingerprint": "sha256:body",
        "postcondition": "the issue exists with the approved body",
        "provides_marker": True,
        "state": "planned",
        "identity": None,
    }
    step.update(step_overrides or {})
    body = {
        "version": 1,
        "repository": "coghex/kanban",
        "document": "docs/ui-bugs.md",
        "entry_key": "DW-3",
        "disposition": "new-issue",
        "marker": None,
        "marker_target": None,
        "publication_tip": PREPARED_TIP,
        "state": "intent-only",
        "steps": [step],
    }
    body.update(overrides)
    return json.dumps(body)


def label_plan(**overrides):
    """The EPIC path as it really runs: a label, then the epic whose number
    becomes the marker. A label's identity is a name and the metadata it was
    created with rather than a number and a URL."""
    body = plan(
        disposition="epic-create",
        steps=[
            {
                "kind": "label-create",
                "target": "label agent-workflows in coghex/kanban",
                "payload_fingerprint": "sha256:label",
                "postcondition": "the label exists with the approved color",
                "approved_name": "agent-workflows",
                "approved_metadata": {"color": "ededed", "description": "x"},
            },
            {
                "kind": "epic-create",
                "target": "new epic in coghex/kanban",
                "payload_fingerprint": "sha256:epic",
                "postcondition": "the epic exists with the approved body",
                "provides_marker": True,
            },
        ],
    )
    body.update(overrides)
    return body


def comment_plan(**overrides):
    body = plan(
        disposition="existing-issue",
        marker="[#288]",
        marker_target="coghex/kanban#288",
        steps=[
            {
                "kind": "issue-comment",
                "target": "coghex/kanban#288",
                "payload_fingerprint": "sha256:comment",
                "postcondition": "the approved comment exists on #288",
            }
        ],
    )
    body.update(overrides)
    return body


def label_identity(**overrides):
    body = {
        "kind": "label-create",
        "id": "agent-workflows",
        "metadata": {"color": "ededed", "description": "x"},
        "postcondition_verified": True,
    }
    body.update(overrides)
    return body


def comment_identity(**overrides):
    body = {
        "kind": "issue-comment",
        "id": "5303396262",
        "url": "https://github.com/coghex/kanban/issues/288#issuecomment-5303396262",
        "postcondition_verified": True,
    }
    body.update(overrides)
    return body


def edit_identity(**overrides):
    body = {
        "kind": "epic-checklist-edit",
        "id": "coghex/kanban#300",
        "fingerprint": "sha256:post-edit",
        "postcondition_verified": True,
    }
    body.update(overrides)
    return body


class Fixture:
    """A bare origin, a primary clone, and a `docs-wip` linked worktree.

    Constructing one only names the paths; `create()` is what runs `git`.
    The split is what lets a test attach to a copy of an already-built
    template (see `tools/git_fixture.py`) instead of building its own, while
    the mutable per-test state below -- the begin tokens especially -- still
    starts empty for every case.
    """

    def __init__(self, directory: Path):
        self.dir = directory
        self.origin = directory / "coghex" / "kanban.git"
        self.primary = directory / "primary"
        self.tokens = {}
        self.docs = directory / "docs-wip"

    @classmethod
    def create(cls, directory: Path) -> "Fixture":
        """Build the repository with real `git`, then attach to it."""
        fixture = cls(directory)
        fixture.build()
        return fixture

    def build(self) -> None:
        directory = self.dir
        self.origin.parent.mkdir(parents=True, exist_ok=True)
        run(["git", "init", "-q", "--bare", str(self.origin)], directory)
        run(["git", "clone", "-q", str(self.origin), str(self.primary)], directory)
        run(["git", "config", "user.email", "t@example.com"], self.primary)
        run(["git", "config", "user.name", "Test"], self.primary)
        (self.primary / "docs").mkdir()
        (self.primary / "docs" / "agent-workflow-contract.md").write_text(
            CLASSIFICATION, encoding="utf-8"
        )
        (self.primary / "docs" / "ui-bugs.md").write_text(DOCUMENT, encoding="utf-8")
        (self.primary / "docs" / "design.md").write_text("# Design\n", encoding="utf-8")
        run(["git", "add", "-A"], self.primary)
        run(["git", "commit", "-qm", "init"], self.primary)
        run(["git", "branch", "-M", "master"], self.primary)
        run(["git", "push", "-q", "origin", "master:master"], self.primary)
        run(["git", "fetch", "-q", "origin", "master"], self.primary)
        run(
            ["git", "worktree", "add", "-q", "-b", "docs-wip", str(self.docs), "master"],
            self.primary,
        )

    # -- the module's own API, always through the resolved write root ---------

    def ref(self, document="docs/ui-bugs.md"):
        return tracker.transaction_ref("coghex/kanban", document)

    def acquire(self, body=None, *, root=None, document="docs/ui-bugs.md",
                tip=PREPARED_TIP):
        return tracker.action_acquire(
            root or self.docs, self.ref(document), "coghex/kanban", document,
            plan() if body is None else body, tip,
        )

    def read(self, *, root=None, document="docs/ui-bugs.md"):
        return tracker.read_record(root or self.docs, self.ref(document))

    def check(self, *, root=None, document="docs/ui-bugs.md"):
        return tracker.check(root or self.docs, "coghex/kanban", document)

    def begin(self, index, *, root=None, document="docs/ui-bugs.md"):
        record, observed = self.read(root=root, document=document)
        outcome = tracker.action_begin(
            root or self.docs, self.ref(document), record, observed, index
        )
        # The token exists only in this result, which is exactly what the run
        # that performed the mutation is holding when it comes to confirm.
        self.tokens[index] = outcome["begin_token"]
        return outcome

    def confirm(self, index, identity, *, root=None, token=None,
                document="docs/ui-bugs.md"):
        record, observed = self.read(root=root, document=document)
        return tracker.action_confirm(
            root or self.docs, self.ref(document), record, observed, index,
            identity, self.tokens.get(index) if token is None else token,
        )

    def reconcile(self, index, identity, candidates=1, *, root=None):
        record, observed = self.read(root=root)
        return tracker.action_reconcile(
            root or self.docs, self.ref(), record, observed, index, identity,
            candidates,
        )

    def resolve(self, *, source="branch", branch="master", root=None,
                document="docs/ui-bugs.md"):
        record, observed = self.read(root=root, document=document)
        return tracker.action_resolve(
            root or self.docs, self.ref(document), record, observed, source, branch
        )

    def cli(self, *args, stdin=""):
        """The command line the assets actually invoke, with its exit code."""
        buffer = io.StringIO()
        argv = [
            "--repo", "coghex/kanban", "--root", str(self.docs),
            "--path", "docs/ui-bugs.md", *args,
        ]
        with contextlib.redirect_stdout(buffer):
            with unittest.mock.patch("sys.stdin", io.StringIO(stdin)):
                code = tracker.main(argv)
        return code, json.loads(buffer.getvalue())

    # -- the document, as the publication branch carries it -------------------

    def publish_document(self, text, path="docs/ui-bugs.md"):
        """Land `text` on the publication branch the way a real publication
        would, so resolution is checked against a branch rather than a fake."""
        blob = self.dir / "approved.md"
        blob.write_text(text, encoding="utf-8")
        try:
            return publisher.publish(
                repository="coghex/kanban", branch="master", root=self.docs,
                document=path, content=blob.read_bytes(),
                message="docs: approved mutation",
            )
        finally:
            blob.unlink(missing_ok=True)

    def plant_unreadable_record(self, document="docs/ui-bugs.md", content="not json"):
        """Leave the reference standing over content no version of this module
        can interpret — the shape a partially written or hand-edited record
        takes."""
        blob = run(
            ["git", "hash-object", "-w", "-t", "blob", "--stdin"],
            self.docs, input=content,
        )
        tree = run(
            ["git", "mktree"], self.docs, input=f"100644 blob {blob}\trecord.json\n"
        )
        commit = run(["git", "commit-tree", tree, "-m", "broken"], self.docs)
        run(["git", "update-ref", self.ref(document), commit], self.docs)

    def linked(self, name="second"):
        """Another linked worktree of the same clone: a later invocation may
        resolve a different write root for the same repository."""
        path = self.dir / name
        run(
            ["git", "worktree", "add", "-q", "-b", name, str(path), "master"],
            self.primary,
        )
        return path


class TrackerFixture(git_fixture.GitTemplateMixin, unittest.TestCase):
    """Every case below works on its own copy of one template built by `git`."""

    @classmethod
    def build_git_template(cls, root, data):
        Fixture.create(root)

    def setUp(self):
        self.fresh_fixture()

    def fresh_fixture(self):
        """Attach to a copy no transaction has been recorded in yet."""
        self.fx = Fixture(self.checkout_git_template())
        return self.fx


class TrackerTemplateIsolationTests(
    git_fixture.SharedTemplateIsolationTests, TrackerFixture
):
    """Issue #384: this family's copies must be reachable only from themselves.

    A tracker record is a Git reference and a publication is a push, so a copy
    still naming the template would write both into shared state.
    """

    def _mutate_the_copy(self):
        self.fx.acquire()
        self.fx.publish_document(DOCUMENT + "\n- a test published this\n")
        run(["git", "branch", "-f", "sideways", "master"], self.fx.docs)


class TrackerTransactionTests(TrackerFixture):

    # -- acquisition ---------------------------------------------------------

    def test_acquiring_records_the_ordered_plan_as_intent_only(self):
        outcome = self.fx.acquire()
        self.assertEqual(outcome["status"], "acquired")
        self.assertEqual(outcome["transaction_state"], "intent-only")
        self.assertEqual([step["state"] for step in outcome["steps"]],
                         ["planned", "planned"])
        self.assertEqual(outcome["entry_key"], "DW-3")
        self.assertEqual(outcome["prepared_publication_tip"], PREPARED_TIP)
        self.assertEqual(outcome["confirmed_identities"], [])

    def test_the_record_carries_every_field_a_fresh_session_resumes_from(self):
        # Requirement 4: a resuming invocation has no conversation history, so
        # everything it needs to re-present a step is in the record or nowhere.
        record, _ = (self.fx.acquire(), self.fx.read())[1]
        self.assertEqual(record["repository"], "coghex/kanban")
        self.assertEqual(record["document"], "docs/ui-bugs.md")
        self.assertEqual(record["entry_key"], "DW-3")
        self.assertEqual(record["disposition"], "new-issue")
        self.assertEqual(record["publication_tip"], PREPARED_TIP)
        for step in record["steps"]:
            for field in ("kind", "target", "payload_fingerprint", "postcondition"):
                self.assertTrue(step[field], field)

    def test_a_second_acquisition_for_the_same_document_is_refused(self):
        self.fx.acquire()
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.acquire()
        self.assertEqual(caught.exception.status, "transaction-outstanding")

    def test_exactly_one_of_many_concurrent_acquisitions_wins(self):
        # Requirement 2 and the first acceptance bullet: two runs can both pass
        # a read-only preflight, so the acquisition itself is what has to be
        # create-only and atomic rather than the check before it.
        def attempt(_):
            try:
                self.fx.acquire()
                return True
            except tracker.TransactionError as error:
                assert error.status == "transaction-outstanding", error.status
                return False

        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(attempt, range(8)))
        self.assertEqual(sum(results), 1, results)

    def test_two_documents_never_share_a_record(self):
        self.fx.acquire()
        other = self.fx.acquire(
            plan(entry_key="D-1"), document="docs/design.md"
        )
        self.assertEqual(other["status"], "acquired")
        self.assertNotEqual(self.fx.ref(), self.fx.ref("docs/design.md"))

    def test_a_record_acquired_in_one_worktree_is_visible_from_another(self):
        # Requirement 3: `$DOCS_WT` may differ between invocations, so a
        # worktree-local record would be invisible to the very run that needs it.
        self.fx.acquire()
        elsewhere = self.fx.linked()
        outcome = self.fx.check(root=elsewhere)
        self.assertEqual(outcome["status"], "outstanding")
        self.assertEqual(outcome["entry_key"], "DW-3")

    def test_the_two_modules_key_a_document_identically(self):
        # The four identity helpers are duplicated rather than imported, to keep
        # two command-line tools from depending on each other. This is what
        # stops the copies drifting: both must name the same (repository,
        # document) pair the same way.
        self.assertEqual(
            tracker.record_key("coghex/kanban", "docs/ui-bugs.md"),
            publisher._key("coghex/kanban", "docs/ui-bugs.md"),
        )

    # -- plans that could never be resolved ----------------------------------

    def test_a_plan_with_no_steps_is_refused(self):
        # Requirement 12: a disposition with no tracker mutation acquires no
        # transaction, so an empty plan is a record that could only ever be left
        # outstanding.
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.acquire(plan(steps=[]))
        self.assertEqual(caught.exception.status, "plan-invalid")

    def test_a_plan_missing_a_payload_fingerprint_is_refused(self):
        broken = plan()
        broken["steps"][0]["payload_fingerprint"] = ""
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.acquire(broken)
        self.assertEqual(caught.exception.status, "plan-invalid")

    def test_a_plan_with_no_marker_and_no_marker_step_is_refused(self):
        broken = plan()
        broken["steps"][0]["provides_marker"] = False
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.acquire(broken)
        self.assertEqual(caught.exception.status, "plan-invalid")

    def test_an_unknown_step_kind_is_refused(self):
        broken = plan()
        broken["steps"][0]["kind"] = "delete-the-repository"
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.acquire(broken)
        self.assertEqual(caught.exception.status, "plan-invalid")

    def test_an_existing_issue_disposition_records_its_literal_marker(self):
        # The comment is the only mutation, and it carries no document token, so
        # the marker the entry must end up with comes from the plan itself.
        outcome = self.fx.acquire(
            plan(
                disposition="existing-issue",
                marker="[#288]",
                marker_target="coghex/kanban#288",
                steps=[
                    {
                        "kind": "issue-comment",
                        "target": "coghex/kanban#288",
                        "payload_fingerprint": "sha256:comment",
                        "postcondition": "the approved comment exists on #288",
                    }
                ],
            )
        )
        self.assertEqual(outcome["marker"], "[#288]")

    # -- the ordered walk ----------------------------------------------------

    def test_a_step_is_intent_before_its_mutation_and_confirmed_after_it(self):
        self.fx.acquire()
        begun = self.fx.begin(0)
        self.assertEqual(begun["steps"][0]["state"], "intent")
        self.assertEqual(begun["ambiguous_step"]["index"], 0)
        confirmed = self.fx.confirm(0, issue_identity())
        self.assertEqual(confirmed["steps"][0]["state"], "confirmed")
        self.assertEqual(confirmed["transaction_state"], "tracker-pending")
        self.assertIsNone(confirmed["ambiguous_step"])

    def test_all_steps_confirmed_reaches_mutation_confirmed(self):
        self.fx.acquire()
        self.fx.begin(0)
        self.fx.confirm(0, issue_identity())
        self.fx.begin(1)
        outcome = self.fx.confirm(1, edit_identity())
        self.assertEqual(outcome["transaction_state"], "mutation-confirmed")
        self.assertEqual(len(outcome["confirmed_identities"]), 2)

    def test_a_later_step_may_not_begin_before_an_earlier_one_is_confirmed(self):
        self.fx.acquire()
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.begin(1)
        self.assertEqual(caught.exception.status, "steps-out-of-order")

    def test_a_second_step_may_not_begin_while_one_is_ambiguous(self):
        self.fx.acquire()
        self.fx.begin(0)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.begin(1)
        self.assertEqual(caught.exception.status, "step-ambiguous")

    def test_an_identity_without_a_verified_postcondition_is_refused(self):
        self.fx.acquire()
        self.fx.begin(0)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.confirm(0, issue_identity(postcondition_verified=False))
        self.assertEqual(caught.exception.status, "identity-invalid")

    def test_a_marker_step_must_record_the_document_token(self):
        self.fx.acquire()
        self.fx.begin(0)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.confirm(0, issue_identity(document_token=""))
        self.assertEqual(caught.exception.status, "identity-invalid")

    def test_a_non_issue_step_records_its_own_kind_of_identity(self):
        # Requirement 5: the contract must not assume every step returns an
        # issue number and URL. An epic-checklist edit identifies its target and
        # its verified post-edit fingerprint, and that is a complete checkpoint.
        self.fx.acquire()
        self.fx.begin(0)
        self.fx.confirm(0, issue_identity())
        self.fx.begin(1)
        outcome = self.fx.confirm(1, edit_identity())
        identity = outcome["steps"][1]["identity"]
        self.assertEqual(identity["id"], "coghex/kanban#300")
        self.assertEqual(identity["fingerprint"], "sha256:post-edit")
        self.assertIsNone(identity["document_token"])

    # -- interruption --------------------------------------------------------

    def test_an_interrupted_step_stays_ambiguous_for_a_fresh_invocation(self):
        # The acceptance bullet: interruption after the request begins but
        # before its identity checkpoint. A fresh session sees the ambiguity and
        # is told not to retry, adopt, advance, publish or clear.
        self.fx.acquire()
        self.fx.begin(0)
        outcome = self.fx.check()
        self.assertEqual(outcome["status"], "outstanding")
        self.assertEqual(outcome["transaction_state"], "intent-only")
        self.assertEqual(outcome["ambiguous_step"]["index"], 0)
        for forbidden in ("retry", "adopt", "advance", "publish", "clear"):
            self.assertIn(forbidden, outcome["next_action"])

    def test_an_ambiguous_step_blocks_resolution(self):
        self.fx.acquire()
        self.fx.begin(0)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.resolve()
        self.assertEqual(caught.exception.status, "state-invalid")
        self.assertIsNotNone(self.fx.read()[0])

    def test_an_ambiguous_step_blocks_handing_over_to_publication(self):
        self.fx.acquire()
        self.fx.begin(0)
        record, observed = self.fx.read()
        with self.assertRaises(tracker.TransactionError) as caught:
            tracker.action_publication_pending(
                self.fx.docs, self.fx.ref(), record, observed
            )
        self.assertEqual(caught.exception.status, "state-invalid")

    def test_a_confirmed_step_is_never_begun_again(self):
        # The acceptance bullet about a confirmed child issue that is not
        # recreated when the umbrella edit was interrupted: the record's answer
        # to "do step 0" is that it already happened, and names what it created.
        self.fx.acquire()
        self.fx.begin(0)
        self.fx.confirm(0, issue_identity())
        self.fx.begin(1)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.begin(0)
        self.assertEqual(caught.exception.status, "step-already-confirmed")
        self.assertIn("311", caught.exception.message)

    def test_a_resumption_offers_only_the_remaining_ordered_steps(self):
        self.fx.acquire()
        self.fx.begin(0)
        self.fx.confirm(0, issue_identity())
        outcome = self.fx.check()
        self.assertEqual(outcome["transaction_state"], "tracker-pending")
        self.assertEqual([step["index"] for step in outcome["completed_steps"]], [0])
        self.assertEqual([step["index"] for step in outcome["remaining_steps"]], [1])
        self.assertEqual(outcome["confirmed_identities"][0]["id"], "311")

    # -- only the run that began a step may confirm it ------------------------

    def test_a_run_without_the_begin_token_cannot_confirm_an_ambiguous_step(self):
        # The bypass this closes: a fresh session finds an interrupted step,
        # calls --confirm-step with an artifact it found, and advances the
        # transaction without ever going through the approved exact-artifact
        # reconciliation the fail-closed contract requires.
        self.fx.acquire()
        self.fx.begin(0)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.confirm(0, issue_identity(), token="")
        self.assertEqual(caught.exception.status, "begin-token-mismatch")
        self.assertEqual(self.fx.read()[0]["steps"][0]["state"], "intent")
        self.assertIn("reconcile", caught.exception.message)

    def test_a_wrong_begin_token_is_refused(self):
        self.fx.acquire()
        self.fx.begin(0)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.confirm(0, issue_identity(), token="0" * 32)
        self.assertEqual(caught.exception.status, "begin-token-mismatch")
        self.assertEqual(self.fx.read()[0]["steps"][0]["state"], "intent")

    def test_the_token_is_never_readable_from_the_record(self):
        # Holding it has to mean "I ran the mutation", not "I read the record" —
        # otherwise a resuming session recovers it and the boundary is gone.
        self.fx.acquire()
        outcome = self.fx.begin(0)
        token = outcome["begin_token"]
        record, _ = self.fx.read()
        self.assertNotIn(token, json.dumps(record))
        self.assertNotIn(token, json.dumps(self.fx.check()))

    def test_the_command_line_confirm_needs_the_token_it_was_given(self):
        self.fx.acquire()
        code, begun = self.fx.cli("--begin-step", "0", "--approved")
        self.assertEqual(code, 0)
        identity = json.dumps(issue_identity())
        code, payload = self.fx.cli(
            "--confirm-step", "0", "--identity", "-", stdin=identity
        )
        self.assertEqual(code, 1)
        self.assertEqual(payload["status"], "begin-token-mismatch")
        code, payload = self.fx.cli(
            "--confirm-step", "0", "--begin-token", begun["begin_token"],
            "--identity", "-", stdin=identity,
        )
        self.assertEqual(code, 0)
        self.assertEqual(payload["steps"][0]["state"], "confirmed")

    def test_an_authorized_retry_invalidates_the_abandoned_token(self):
        self.fx.acquire()
        stale = self.fx.begin(0)["begin_token"]
        record, observed = self.fx.read()
        tracker.action_authorize_retry(
            self.fx.docs, self.fx.ref(), record, observed, 0
        )
        self.fx.begin(0)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.confirm(0, issue_identity(), token=stale)
        self.assertEqual(caught.exception.status, "begin-token-mismatch")

    def test_reconciliation_is_the_path_a_fresh_run_actually_has(self):
        # And it still works without a token, because it pays for that with an
        # approved, uniquely matched, exactly fingerprinted artifact.
        self.fx.acquire()
        self.fx.begin(0)
        self.fx.tokens.clear()
        outcome = self.fx.reconcile(
            0,
            issue_identity(
                matched_target="new issue in coghex/kanban",
                matched_payload_fingerprint="sha256:body",
            ),
        )
        self.assertEqual(outcome["status"], "step-reconciled")

    # -- an identity is the one its own kind of mutation has ------------------

    def test_an_identity_of_the_wrong_kind_is_refused(self):
        self.fx.acquire()
        self.fx.begin(0)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.confirm(0, issue_identity(kind="issue-comment"))
        self.assertEqual(caught.exception.status, "identity-invalid")
        self.assertIn("approved step is a", caught.exception.message)

    def test_an_issue_identity_must_agree_with_its_own_document_token(self):
        # The hole this closes: resolution checks the token, so an identity free
        # to record #311 beside [#999] could clear a record whose documented
        # artifact is not the one the tracker actually got.
        self.fx.acquire()
        self.fx.begin(0)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.confirm(0, issue_identity(document_token="[#999]"))
        self.assertEqual(caught.exception.status, "identity-invalid")
        self.assertIn("actually created", caught.exception.message)

    def test_an_issue_identity_must_agree_with_its_own_url(self):
        self.fx.acquire()
        self.fx.begin(0)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.confirm(
                0,
                issue_identity(url="https://github.com/coghex/kanban/issues/999"),
            )
        self.assertEqual(caught.exception.status, "identity-invalid")
        self.assertIn("is not the GitHub url of issue", caught.exception.message)

    def test_an_issue_identity_needs_a_number_and_a_url(self):
        # A refused confirmation leaves the step exactly as it was, so both
        # rejections can be driven against the one ambiguous step.
        self.fx.acquire()
        self.fx.begin(0)
        for broken in (issue_identity(id="the-issue"), issue_identity(url="")):
            with self.subTest(identity=broken):
                with self.assertRaises(tracker.TransactionError) as caught:
                    self.fx.confirm(0, broken)
                self.assertEqual(caught.exception.status, "identity-invalid")
                self.assertEqual(self.fx.read()[0]["steps"][0]["state"], "intent")

    def test_a_label_records_and_keeps_its_metadata(self):
        # Requirement 5's "a label name and metadata": discarding the metadata
        # leaves a checkpoint that cannot describe what it created.
        self.fx.acquire(label_plan())
        self.fx.begin(0)
        outcome = self.fx.confirm(0, label_identity())
        identity = outcome["steps"][0]["identity"]
        self.assertEqual(identity["id"], "agent-workflows")
        self.assertEqual(identity["metadata"], {"color": "ededed", "description": "x"})
        self.assertIsNone(identity["document_token"])
        # And it survives a re-read, rather than living only in this result.
        self.assertEqual(
            self.fx.read()[0]["steps"][0]["identity"]["metadata"],
            {"color": "ededed", "description": "x"},
        )

    def test_a_label_must_be_the_approved_one(self):
        # A plan for one label could confirm another, and the epic would then
        # publish with the approved label never created.
        self.fx.acquire(label_plan())
        self.fx.begin(0)
        for identity, expected in (
            (label_identity(id="something-else"), "but the approved one is"),
            (label_identity(metadata={"color": "ff0000", "description": "x"}),
             "is not the approved"),
            (label_identity(metadata={"color": "ededed"}), "is not the approved"),
        ):
            with self.subTest(identity=identity):
                with self.assertRaises(tracker.TransactionError) as caught:
                    self.fx.confirm(0, identity)
                self.assertEqual(caught.exception.status, "identity-invalid")
                self.assertIn(expected, caught.exception.message)
        self.assertEqual(self.fx.read()[0]["steps"][0]["state"], "intent")

    def test_a_label_step_must_carry_its_approved_name_and_metadata(self):
        for missing in ("approved_name", "approved_metadata"):
            with self.subTest(missing=missing):
                broken = label_plan()
                broken["steps"][0][missing] = "" if missing == "approved_name" else {}
                with self.assertRaises(tracker.TransactionError) as caught:
                    self.fx.acquire(broken)
                self.assertEqual(caught.exception.status, "plan-invalid")
                self.assertIn(missing, caught.exception.message)

    def test_a_numbered_step_may_not_carry_an_approved_name(self):
        # The fields belong to artifacts identified by name; on a step whose
        # artifact has a number they would be a second, unchecked identity.
        broken = plan()
        broken["steps"][0]["approved_name"] = "agent-workflows"
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.acquire(broken)
        self.assertEqual(caught.exception.status, "plan-invalid")
        self.assertIn("identified by number", caught.exception.message)

    def test_a_persisted_mismatched_label_identity_is_unreadable(self):
        self.fx.acquire(label_plan())
        self.fx.begin(0)
        self.fx.confirm(0, label_identity())
        record, _ = self.fx.read()
        record["steps"][0]["identity"]["id"] = "something-else"
        self.fx.plant_unreadable_record(content=json.dumps(record))
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.read()
        self.assertEqual(caught.exception.status, "record-unreadable")
        self.assertIn("confirmed identity is unusable", caught.exception.message)

    def test_a_label_without_metadata_is_refused(self):
        self.fx.acquire(label_plan())
        self.fx.begin(0)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.confirm(0, label_identity(metadata=None))
        self.assertEqual(caught.exception.status, "identity-invalid")

    def test_a_comment_records_its_id_and_url(self):
        self.fx.acquire(comment_plan())
        self.fx.begin(0)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.confirm(0, comment_identity(url=""))
        self.assertEqual(caught.exception.status, "identity-invalid")
        outcome = self.fx.confirm(0, comment_identity())
        self.assertEqual(outcome["steps"][0]["identity"]["id"], "5303396262")

    def test_an_edit_records_its_verified_post_edit_fingerprint(self):
        self.fx.acquire()
        self.fx.begin(0)
        self.fx.confirm(0, issue_identity())
        self.fx.begin(1)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.confirm(1, edit_identity(fingerprint=""))
        self.assertEqual(caught.exception.status, "identity-invalid")

    def test_only_a_created_issue_contributes_a_document_token(self):
        self.fx.acquire()
        self.fx.begin(0)
        self.fx.confirm(0, issue_identity())
        self.fx.begin(1)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.confirm(1, edit_identity(document_token="[#300]"))
        self.assertEqual(caught.exception.status, "identity-invalid")
        self.assertIn("never appears in the document", caught.exception.message)

    def test_a_non_issue_step_may_not_claim_to_provide_the_marker(self):
        broken = plan(
            disposition="epic-create",
            steps=[
                {
                    "kind": "label-create",
                    "target": "label agent-workflows in coghex/kanban",
                    "payload_fingerprint": "sha256:label",
                    "postcondition": "the label exists",
                    "provides_marker": True,
                    "approved_name": "agent-workflows",
                    "approved_metadata": {"color": "ededed", "description": "x"},
                }
            ],
        )
        self.fx.acquire(broken)
        self.fx.begin(0)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.confirm(0, label_identity())
        self.assertEqual(caught.exception.status, "identity-invalid")
        self.assertIn("produces no marker", caught.exception.message)

    def test_an_issue_url_in_another_repository_is_refused(self):
        # Resolution sees only `[#311]` in the document, so an identity free to
        # name another repository's #311 would let a transaction clear against
        # an issue this repository never got.
        self.fx.acquire()
        self.fx.begin(0)
        for url in (
            "https://github.com/other/repo/issues/311",
            "https://github.com/coghex/other/issues/311",
            "https://example.com/issues/311",
        ):
            with self.subTest(url=url):
                with self.assertRaises(tracker.TransactionError) as caught:
                    self.fx.confirm(0, issue_identity(url=url))
                self.assertEqual(caught.exception.status, "identity-invalid")
                self.assertIn(
                    "is not the GitHub url of issue", caught.exception.message
                )

    def test_reconciliation_cannot_bind_a_foreign_issue_either(self):
        # The path that actually reaches this: a human approving a candidate for
        # an ambiguous step. The target and payload match; only the repository
        # in the url does not.
        self.fx.acquire()
        self.fx.begin(0)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.reconcile(
                0,
                issue_identity(
                    url="https://github.com/other/repo/issues/311",
                    matched_target="new issue in coghex/kanban",
                    matched_payload_fingerprint="sha256:body",
                ),
            )
        self.assertEqual(caught.exception.status, "identity-invalid")
        self.assertEqual(self.fx.read()[0]["steps"][0]["state"], "intent")

    def test_a_persisted_foreign_issue_url_makes_the_record_unreadable(self):
        confirmed = json.loads(record_json())
        confirmed["state"] = "mutation-confirmed"
        confirmed["steps"][0]["state"] = "confirmed"
        confirmed["steps"][0]["identity"] = issue_identity(
            url="https://github.com/other/repo/issues/311"
        )
        self.fx.plant_unreadable_record(content=json.dumps(confirmed))
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.read()
        self.assertEqual(caught.exception.status, "record-unreadable")
        self.assertFalse(self.fx.check()["record_readable"])

    def test_a_comment_url_must_be_this_repository_and_the_approved_target(self):
        self.fx.acquire(comment_plan())
        self.fx.begin(0)
        for url, expected in (
            ("https://github.com/other/repo/issues/288#issuecomment-5303396262",
             "is not the GitHub url of comment"),
            ("https://github.com/coghex/kanban/issues/288#issuecomment-999",
             "is not the GitHub url of comment"),
            ("https://github.com/coghex/kanban/issues/999#issuecomment-5303396262",
             "not on the approved target"),
        ):
            with self.subTest(url=url):
                with self.assertRaises(tracker.TransactionError) as caught:
                    self.fx.confirm(0, comment_identity(url=url))
                self.assertEqual(caught.exception.status, "identity-invalid")
                self.assertIn(expected, caught.exception.message)

    def test_a_lookalike_host_or_path_is_not_a_github_artifact(self):
        # The substring test this replaced accepted every one of these as issue
        # 311 of coghex/kanban, and the document — which carries only `[#311]` —
        # cannot tell them apart.
        self.fx.acquire()
        self.fx.begin(0)
        for url in (
            "https://example.test/coghex/kanban/issues/311",
            "http://github.com/coghex/kanban/issues/311",
            "https://github.com.evil.test/coghex/kanban/issues/311",
            "https://github.com/coghex/kanban/pull/311",
            "https://github.com/coghex/kanban/issues/311/timeline",
            "https://github.com/coghex/kanban/issues/311#issuecomment-5",
            "see https://github.com/coghex/kanban/issues/311",
        ):
            with self.subTest(url=url):
                with self.assertRaises(tracker.TransactionError) as caught:
                    self.fx.confirm(0, issue_identity(url=url))
                self.assertEqual(caught.exception.status, "identity-invalid")
                self.assertIn(
                    "is not the GitHub url of issue", caught.exception.message
                )

    def test_the_canonical_github_url_is_accepted(self):
        # And the shape `gh issue create` actually returns still passes, so the
        # parse is a binding rather than a refusal of everything.
        self.fx.acquire()
        self.fx.begin(0)
        outcome = self.fx.confirm(
            0, issue_identity(url="https://GitHub.com/CogHex/Kanban/issues/311")
        )
        self.assertEqual(outcome["steps"][0]["state"], "confirmed")

    def test_an_edit_must_name_the_approved_target(self):
        # A plan targeting the umbrella epic #300 could confirm an edit to #999,
        # publish the child marker, and clear — while the epic it named was
        # never touched.
        self.fx.acquire()
        self.fx.begin(0)
        self.fx.confirm(0, issue_identity())
        self.fx.begin(1)
        for identity, expected in (
            (edit_identity(id="coghex/kanban#999"), "approved target"),
            (edit_identity(id="other/repo#300"), "is not in coghex/kanban"),
            (edit_identity(id="the epic"), "approved target"),
        ):
            with self.subTest(identity=identity):
                with self.assertRaises(tracker.TransactionError) as caught:
                    self.fx.confirm(1, identity)
                self.assertEqual(caught.exception.status, "identity-invalid")
                self.assertIn(expected, caught.exception.message)
        self.assertEqual(self.fx.read()[0]["steps"][1]["state"], "intent")

    def linked_child_plan(self, **overrides):
        """An existing child issue with no approved comment: its one tracker
        mutation is the umbrella epic's checklist, which targets the epic rather
        than the child. `process-design-doc` treats the comment as optional and
        the checklist change as not, so this is an ordinary disposition."""
        body = plan(
            disposition="existing-issue",
            marker="[#288]",
            marker_target="coghex/kanban#288",
            steps=[
                {
                    "kind": "epic-checklist-edit",
                    "target": "coghex/kanban#300",
                    "payload_fingerprint": "sha256:checklist",
                    "postcondition": "the epic checklist links the existing child",
                }
            ],
        )
        body.update(overrides)
        return body

    def test_a_linked_child_with_no_comment_is_an_ordinary_disposition(self):
        outcome = self.fx.acquire(self.linked_child_plan())
        self.assertEqual(outcome["status"], "acquired")
        self.assertEqual(outcome["marker"], "[#288]")
        self.fx.begin(0)
        self.fx.confirm(0, edit_identity())
        self.fx.publish_document(
            DOCUMENT.replace(
                "- [ ] DW-3. Checkpoint tracker mutations",
                "- [x] DW-3. Checkpoint tracker mutations — [#288]",
            )
        )
        self.assertEqual(self.fx.resolve()["status"], "resolved")

    def test_a_linked_marker_must_name_its_own_marker_target(self):
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.acquire(self.linked_child_plan(marker="[#999]"))
        self.assertEqual(caught.exception.status, "plan-invalid")
        self.assertIn("does not name its marker_target", caught.exception.message)

    def test_a_linked_marker_needs_a_marker_target_at_all(self):
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.acquire(self.linked_child_plan(marker_target=""))
        self.assertEqual(caught.exception.status, "plan-invalid")
        self.assertIn("names no marker_target", caught.exception.message)

    def test_a_marker_target_in_another_repository_is_refused(self):
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.acquire(self.linked_child_plan(marker_target="other/repo#288"))
        self.assertEqual(caught.exception.status, "plan-invalid")
        self.assertIn("is not in coghex/kanban", caught.exception.message)

    def test_a_comment_must_be_on_the_issue_being_linked(self):
        # The round-8 hole, kept closed by the target rather than by inferring
        # the link from the step: a comment posted somewhere other than the
        # artifact the entry will name is a different mutation.
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.acquire(comment_plan(marker_target="coghex/kanban#288",
                                         steps=[dict(comment_plan()["steps"][0],
                                                     target="coghex/kanban#999")]))
        self.assertEqual(caught.exception.status, "plan-invalid")
        self.assertIn("pointing somewhere other than", caught.exception.message)

    def test_an_adoption_records_the_edit_it_applies(self):
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.acquire(self.linked_child_plan(disposition="epic-adopt"))
        self.assertEqual(caught.exception.status, "plan-invalid")
        self.assertIn("records the adoption edit", caught.exception.message)

    def test_a_marker_target_without_a_marker_is_refused(self):
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.acquire(plan(marker_target="coghex/kanban#288"))
        self.assertEqual(caught.exception.status, "plan-invalid")
        self.assertIn("without a marker", caught.exception.message)

    def test_a_literal_marker_must_name_the_artifact_it_links(self):
        # The comment confirms against #288 while the ledger entry the record
        # would clear against is #999 — two different artifacts, one record.
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.acquire(comment_plan(marker="[#999]"))
        self.assertEqual(caught.exception.status, "plan-invalid")
        self.assertIn("does not name its marker_target", caught.exception.message)
        self.assertEqual(self.fx.check()["status"], "clear")

    def test_a_creating_disposition_may_not_supply_a_literal_marker(self):
        # It takes the marker from what it created, which is the only thing that
        # ties the entry to the artifact.
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.acquire(
                plan(marker="[#288]", steps=[dict(plan()["steps"][0],
                                                  provides_marker=False)])
            )
        self.assertEqual(caught.exception.status, "plan-invalid")
        self.assertIn("not from a literal one", caught.exception.message)

    def test_a_persisted_marker_naming_nothing_is_unreadable(self):
        # The same rule on read-back, since a record is only ever as good as
        # what a later run can check about it.
        broken = json.loads(record_json())
        broken["marker"] = "[#999]"
        broken["disposition"] = "existing-issue"
        broken["steps"] = [{
            "kind": "issue-comment", "target": "coghex/kanban#288",
            "payload_fingerprint": "sha256:comment",
            "postcondition": "the approved comment exists",
            "provides_marker": False, "state": "planned", "identity": None,
        }]
        self.fx.plant_unreadable_record(content=json.dumps(broken))
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.read()
        self.assertEqual(caught.exception.status, "record-unreadable")
        self.assertFalse(self.fx.check()["record_readable"])

    # -- reconciliation ------------------------------------------------------

    def test_reconciliation_binds_an_ambiguous_step_to_one_exact_artifact(self):
        self.fx.acquire()
        self.fx.begin(0)
        outcome = self.fx.reconcile(
            0,
            issue_identity(
                matched_target="new issue in coghex/kanban",
                matched_payload_fingerprint="sha256:body",
            ),
        )
        self.assertEqual(outcome["status"], "step-reconciled")
        self.assertEqual(outcome["steps"][0]["state"], "confirmed")

    def test_reconciliation_refuses_more_than_one_candidate(self):
        self.fx.acquire()
        self.fx.begin(0)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.reconcile(
                0,
                issue_identity(
                    matched_target="new issue in coghex/kanban",
                    matched_payload_fingerprint="sha256:body",
                ),
                candidates=2,
            )
        self.assertEqual(caught.exception.status, "candidates-not-unique")
        self.assertEqual(self.fx.read()[0]["steps"][0]["state"], "intent")

    def test_reconciliation_refuses_a_candidate_with_no_match_at_all(self):
        self.fx.acquire()
        self.fx.begin(0)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.reconcile(0, issue_identity(), candidates=0)
        self.assertEqual(caught.exception.status, "candidates-not-unique")
        self.assertEqual(self.fx.read()[0]["steps"][0]["state"], "intent")

    def test_reconciliation_refuses_a_similarly_titled_artifact(self):
        # The rule the acceptance list states outright: a payload that is not
        # the approved one leaves the record unresolved, however plausible the
        # artifact looks.
        self.fx.acquire()
        self.fx.begin(0)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.reconcile(
                0,
                issue_identity(
                    matched_target="new issue in coghex/kanban",
                    matched_payload_fingerprint="sha256:something-else",
                ),
            )
        self.assertEqual(caught.exception.status, "identity-mismatch")
        self.assertEqual(self.fx.read()[0]["steps"][0]["state"], "intent")

    def test_reconciliation_refuses_a_different_target(self):
        self.fx.acquire()
        self.fx.begin(0)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.reconcile(
                0,
                issue_identity(
                    matched_target="new issue in someone/else",
                    matched_payload_fingerprint="sha256:body",
                ),
            )
        self.assertEqual(caught.exception.status, "identity-mismatch")

    def test_an_authorized_retry_returns_the_step_to_planned(self):
        self.fx.acquire()
        self.fx.begin(0)
        record, observed = self.fx.read()
        outcome = tracker.action_authorize_retry(
            self.fx.docs, self.fx.ref(), record, observed, 0
        )
        self.assertEqual(outcome["status"], "retry-authorized")
        self.assertEqual(outcome["steps"][0]["state"], "planned")

    # -- durability ----------------------------------------------------------

    def test_a_losing_transition_preserves_the_earlier_durable_value(self):
        # Requirement 7. Two runs read the same record; the slower one's
        # compare-and-swap fails rather than overwriting what the first wrote.
        self.fx.acquire()
        stale_record, stale_value = self.fx.read()
        self.fx.begin(0)
        self.fx.confirm(0, issue_identity())
        winner, _ = self.fx.read()
        stale_record["steps"][0]["state"] = "intent"
        with self.assertRaises(tracker.TransactionError) as caught:
            tracker.write_record(
                self.fx.docs, self.fx.ref(), stale_record, stale_value
            )
        self.assertEqual(caught.exception.status, "record-changed")
        self.assertEqual(self.fx.read()[0], winner)

    def test_a_losing_acquisition_reports_the_record_it_lost_to(self):
        # The losing run is the one that most needs the report: another run owns
        # the transaction, and this one has to say what is outstanding rather
        # than that a reference refused it. Empty tracker fields here would read
        # as "no transaction" on the one path where there certainly is one.
        self.fx.acquire()
        self.fx.begin(0)
        self.fx.confirm(0, issue_identity())
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.acquire()
        detail = caught.exception.detail
        self.assertEqual(caught.exception.status, "transaction-outstanding")
        self.assertTrue(detail["acquired"])
        self.assertTrue(detail["record_readable"])
        self.assertEqual(detail["transaction_state"], "tracker-pending")
        self.assertEqual(detail["entry_key"], "DW-3")
        self.assertEqual([step["index"] for step in detail["completed_steps"]], [0])
        self.assertEqual(detail["confirmed_identities"][0]["id"], "311")
        self.assertEqual([step["index"] for step in detail["remaining_steps"]], [1])

    def test_a_losing_acquisition_reports_an_unreadable_record_as_unreadable(self):
        # And when it cannot be read, it says so. Reporting it as absent would
        # let the losing run conclude it may proceed.
        self.fx.acquire()
        self.fx.plant_unreadable_record()
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.acquire()
        detail = caught.exception.detail
        self.assertEqual(caught.exception.status, "transaction-outstanding")
        self.assertIsNone(detail["acquired"])
        self.assertFalse(detail["record_readable"])
        self.assertIn("could not be read", detail["next_action"])
        self.assertIn("resolved by hand", detail["next_action"])

    def test_a_losing_transition_reports_the_record_that_won(self):
        self.fx.acquire()
        _, stale_value = self.fx.read()
        self.fx.begin(0)
        self.fx.confirm(0, issue_identity())
        stale_record, _ = self.fx.read()
        with self.assertRaises(tracker.TransactionError) as caught:
            tracker.write_record(
                self.fx.docs, self.fx.ref(), stale_record, stale_value
            )
        detail = caught.exception.detail
        self.assertEqual(caught.exception.status, "record-changed")
        self.assertEqual(detail["expected_commit"], stale_value)
        self.assertEqual(detail["transaction_state"], "tracker-pending")
        self.assertEqual(detail["confirmed_identities"][0]["id"], "311")

    def test_the_command_line_reports_the_winner_when_its_transition_loses(self):
        # The same race through the command line the assets actually run, with
        # this invocation reading the record a moment before another run
        # advanced it.
        self.fx.acquire()
        _, stale_value = self.fx.read()
        self.fx.begin(0)
        self.fx.confirm(0, issue_identity())
        current, _ = self.fx.read()

        def stale_read(root, ref, **kwargs):
            return json.loads(json.dumps(current)), stale_value

        with unittest.mock.patch.object(tracker, "read_record", stale_read):
            code, payload = self.fx.cli("--begin-step", "1", "--approved")
        self.assertEqual(code, 1)
        self.assertEqual(payload["status"], "record-changed")
        self.assertTrue(payload["acquired"])
        self.assertEqual(payload["transaction_state"], "tracker-pending")
        self.assertEqual([step["index"] for step in payload["completed_steps"]], [0])
        self.assertEqual(payload["confirmed_identities"][0]["id"], "311")
        self.assertEqual([step["index"] for step in payload["remaining_steps"]], [1])
        # And the winner's record is untouched by the losing invocation.
        self.assertEqual(self.fx.read()[0], current)

    def test_a_record_that_could_not_be_cleared_reports_what_is_still_there(self):
        self.fx.acquire()
        _, stale_value = self.fx.read()
        self.fx.begin(0)
        self.fx.confirm(0, issue_identity())
        self.fx.begin(1)
        self.fx.confirm(1, edit_identity())
        _, observed = self.fx.read()
        with self.assertRaises(tracker.TransactionError) as caught:
            tracker.clear_record(self.fx.docs, self.fx.ref(), stale_value)
        detail = caught.exception.detail
        self.assertEqual(caught.exception.status, "record-retained")
        self.assertEqual(detail["transaction_state"], "mutation-confirmed")
        self.assertEqual(len(detail["confirmed_identities"]), 2)
        self.assertEqual(self.fx.read()[1], observed)

    def test_clearing_refuses_the_null_object_name_as_well_as_the_empty_one(self):
        # Both spellings of an unbound delete. `git update-ref -d <ref> <zeros>`
        # removes the reference unconditionally, so accepting the null name
        # would be exactly the unconditional delete this signature exists to
        # make unrepresentable.
        self.fx.acquire()
        for unbound in ("", "0" * 40, "0" * 64):
            with self.subTest(old_value=unbound):
                with self.assertRaises(tracker.TransactionError) as caught:
                    tracker.clear_record(self.fx.docs, self.fx.ref(), unbound)
                self.assertEqual(caught.exception.status, "clear-unbound")
                self.assertIsNotNone(self.fx.read()[0])

    def test_a_transition_that_would_erase_a_confirmation_is_refused(self):
        self.fx.acquire()
        self.fx.begin(0)
        self.fx.confirm(0, issue_identity())
        before, _ = self.fx.read()
        after = json.loads(json.dumps(before))
        after["steps"][0] = dict(after["steps"][0], state="planned", identity=None)
        with self.assertRaises(tracker.TransactionError) as caught:
            tracker.require_preserved_confirmations(before, after)
        self.assertEqual(caught.exception.status, "confirmation-erased")

    def test_an_unreadable_record_fails_closed_rather_than_reading_clear(self):
        self.fx.acquire()
        self.fx.plant_unreadable_record()
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.read()
        self.assertEqual(caught.exception.status, "record-unreadable")

    def test_valid_json_that_is_not_a_record_is_unreadable(self):
        # Parsing is not the same as being a record. A half-written or
        # hand-edited document that still parses would otherwise reach the
        # readers, which index these fields directly, and fail there as a
        # KeyError — escaping the structured refusal entirely.
        malformed = (
            ('{"version": 1}', "missing"),
            (record_json(publication_tip=""), "publication_tip"),
            (record_json(steps=[]), "non-empty list"),
            (record_json(steps=[{"kind": "issue-create"}]), "is missing"),
            (record_json(state="wat"), "not a known transaction state"),
            (record_json(disposition="wat"), "not a known one"),
            (record_json(marker="311"), "form [#N]"),
            (record_json(step_overrides={"target": ""}), "has no target"),
            (record_json(step_overrides={"payload_fingerprint": "  "}),
             "has no payload_fingerprint"),
            (record_json(step_overrides={"postcondition": ""}),
             "has no postcondition"),
            (record_json(step_overrides={"kind": "delete-everything"}),
             "unknown kind"),
            (record_json(step_overrides={"state": "wat"}), "unknown state"),
            (record_json(step_overrides={"state": "confirmed", "identity": None}),
             "records no identity"),
            (record_json(step_overrides={"identity": {"id": "1"}}),
             "records an identity"),
            (record_json(step_overrides={"provides_marker": False}),
             "no single source for the marker"),
        )
        for content, expected in malformed:
            with self.subTest(content=content[:48]):
                self.fx.plant_unreadable_record(content=content)
                with self.assertRaises(tracker.TransactionError) as caught:
                    self.fx.read()
                self.assertEqual(caught.exception.status, "record-unreadable")
                self.assertIn(expected, caught.exception.message)
                # And it reaches the preflight as an answer, not an exception.
                outcome = self.fx.check()
                self.assertEqual(outcome["status"], "outstanding")
                self.assertFalse(outcome["record_readable"])

    def test_a_record_naming_another_document_is_not_this_document_s(self):
        # The reference name is a digest of the (repository, document) pair, so
        # a record naming a different one is corrupt however it got there —
        # and it must not be reported as this document's outstanding work.
        for content in (
            record_json(repository="someone/else"),
            record_json(document="docs/design.md"),
        ):
            with self.subTest(content=content[:56]):
                self.fx.plant_unreadable_record(content=content)
                outcome = self.fx.check()
                self.assertEqual(outcome["status"], "outstanding")
                self.assertFalse(outcome["record_readable"])
                code, payload = self.fx.cli("--check")
                self.assertEqual(code, 1)
                self.assertFalse(payload["record_readable"])

    def test_a_confirmed_identity_that_is_merely_a_dict_is_unreadable(self):
        # `{}` used to read as a confirmed step. required_document_tokens then
        # returned nothing, and "every required token is on the line" is
        # vacuously true of any line — so a checked entry carrying the key alone
        # cleared the transaction.
        confirmed = json.loads(record_json())
        confirmed["state"] = "mutation-confirmed"
        confirmed["steps"][0]["state"] = "confirmed"
        for identity, expected in (
            ({}, "names no id"),
            ({"id": "311", "postcondition_verified": True}, "records no url"),
            (issue_identity(document_token="[#999]"), "actually created"),
            (issue_identity(kind="issue-comment"), "approved step is a"),
        ):
            with self.subTest(identity=identity):
                confirmed["steps"][0]["identity"] = identity
                self.fx.plant_unreadable_record(content=json.dumps(confirmed))
                with self.assertRaises(tracker.TransactionError) as caught:
                    self.fx.read()
                self.assertEqual(caught.exception.status, "record-unreadable")
                self.assertIn("confirmed identity is unusable", caught.exception.message)
                self.assertIn(expected, caught.exception.message)
                self.assertFalse(self.fx.check()["record_readable"])

    def test_a_malformed_record_reaches_both_command_lines_as_tracker_state(self):
        self.fx.plant_unreadable_record(content='{"version": 1}')
        code, payload = self.fx.cli("--check")
        self.assertEqual(code, 1)
        self.assertEqual(payload["status"], "outstanding")
        self.assertFalse(payload["record_readable"])
        self.assertIn("resolved by hand", payload["next_action"])

        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = publisher.main([
                "--repo", "coghex/kanban", "--branch", "master",
                "--root", str(self.fx.docs), "--path", "docs/ui-bugs.md",
                "--check-pending",
            ])
        preflight = json.loads(buffer.getvalue())
        self.assertEqual(code, 1)
        self.assertEqual(preflight["status"], "pending")
        self.assertEqual(preflight["pending_kinds"], ["tracker-transaction"])
        self.assertNotIn("internal-error", json.dumps(preflight))
        self.assertFalse(preflight["tracker_transaction"]["record_readable"])

    def test_the_report_never_raises_even_if_building_it_fails(self):
        # observed_report promises never to raise, and every caller relies on
        # that: it runs with a failure already on its way out, and one thrown
        # from here would replace the refusal it was describing. Building the
        # report used to sit outside its own guard.
        self.fx.acquire()
        original = tracker.transaction_report

        def broken(*args, **kwargs):
            raise KeyError("steps")

        tracker.transaction_report = broken
        self.addCleanup(setattr, tracker, "transaction_report", original)
        report = tracker.observed_report(self.fx.docs, self.fx.ref())
        self.assertFalse(report["record_readable"])
        self.assertIsNone(report["acquired"])
        self.assertIn("resolved by hand", report["next_action"])

    def test_the_check_reports_an_unreadable_record_rather_than_raising(self):
        # The preflight's result is what a caller acts on by deciding whether it
        # may mutate GitHub, so an uninterpretable record has to arrive as a
        # tracker answer. Raised past the report it becomes a generic failure
        # with no reference, no unreadable status and no recovery action.
        self.fx.acquire()
        self.fx.plant_unreadable_record()
        outcome = self.fx.check()
        self.assertEqual(outcome["status"], "outstanding")
        self.assertIsNone(outcome["acquired"])
        self.assertFalse(outcome["record_readable"])
        self.assertEqual(outcome["transaction_ref"], self.fx.ref())
        self.assertIn("resolved by hand", outcome["next_action"])

    def test_the_check_command_line_exits_nonzero_on_an_unreadable_record(self):
        self.fx.acquire()
        self.fx.plant_unreadable_record()
        code, payload = self.fx.cli("--check")
        self.assertEqual(code, 1)
        self.assertEqual(payload["status"], "outstanding")
        self.assertFalse(payload["record_readable"])

    def test_a_readable_absent_record_is_still_clear(self):
        # The other side of the same predicate: absent and readable is the only
        # state that licenses proceeding, and it must not be lost to the change
        # that stopped unreadable from raising.
        outcome = self.fx.check()
        self.assertEqual(outcome["status"], "clear")
        self.assertFalse(outcome["acquired"])
        self.assertTrue(outcome["record_readable"])

    # -- resolution ----------------------------------------------------------

    def confirmed_transaction(self):
        self.fx.acquire()
        self.fx.begin(0)
        self.fx.confirm(0, issue_identity())
        self.fx.begin(1)
        self.fx.confirm(1, edit_identity())

    def test_resolution_clears_the_record_once_the_entry_carries_the_identity(self):
        self.confirmed_transaction()
        self.fx.publish_document(
            DOCUMENT.replace(
                "- [ ] DW-3. Checkpoint tracker mutations",
                "- [x] DW-3. Checkpoint tracker mutations — [#311]",
            )
        )
        outcome = self.fx.resolve()
        self.assertEqual(outcome["status"], "resolved")
        self.assertEqual(outcome["required_tokens"], ["[#311]"])
        self.assertIsNone(self.fx.read()[0])
        self.assertEqual(self.fx.check()["status"], "clear")

    def resolution_refused(self, published, expected):
        """Publish `published` and assert the transaction stays outstanding."""
        self.fx.publish_document(published)
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.resolve()
        self.assertEqual(caught.exception.status, "resolution-unverified")
        self.assertIn(expected, caught.exception.message)
        self.assertEqual(self.fx.check()["status"], "outstanding")

    def test_an_unreadable_lane_declaration_stops_a_local_resolution(self):
        # Issue #370: outside §7 a document's lane comes from its owner's own
        # configuration, which can be present and unreadable. An unknown lane
        # may not clear a record — resolving against the working tree is
        # admissible only for a document that provably has none — so the
        # failure arrives as a named tracker status rather than as a lane read
        # as absent.
        config = Path(os.environ["XDG_CONFIG_HOME"]) / "kanban" / "config.toml"
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(
            '[repositories."otherorg/product".workflow\n', encoding="utf-8"
        )
        self.addCleanup(config.unlink, missing_ok=True)
        with self.assertRaises(tracker.TransactionError) as caught:
            tracker.local_resolution_permitted(
                self.fx.docs,
                {"repository": "otherorg/product", "document": "docs/ui-bugs.md"},
                "master",
            )
        self.assertEqual(
            caught.exception.status, "publication-classification-unavailable"
        )
        self.assertIn("could not be decided", caught.exception.message)

    def test_a_declared_lane_outside_section_7_refuses_a_local_resolution(self):
        # The other side of the same branch, so the status above is a real
        # failure rather than the only outcome this path has: a repository that
        # does declare the document publishes it to the branch, and a record for
        # such a document is never resolvable from the working tree.
        config = Path(os.environ["XDG_CONFIG_HOME"]) / "kanban" / "config.toml"
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(
            '[repositories."otherorg/product".workflow]\n'
            'direct_publication_paths = ["docs/ui-bugs.md"]\n',
            encoding="utf-8",
        )
        self.addCleanup(config.unlink, missing_ok=True)
        permitted, why_not = tracker.local_resolution_permitted(
            self.fx.docs,
            {"repository": "otherorg/product", "document": "docs/ui-bugs.md"},
            "master",
        )
        self.assertFalse(permitted)
        self.assertIn("publishes directly to master", why_not)

    def test_an_unchecked_entry_carrying_the_link_does_not_resolve(self):
        # The interrupted run's own signature: the issue exists and the number
        # reached the line, but the box was never checked, so the disposition
        # was not applied and the document still owes this entry.
        self.confirmed_transaction()
        self.resolution_refused(
            DOCUMENT.replace(
                "- [ ] DW-3. Checkpoint tracker mutations",
                "- [ ] DW-3. Checkpoint tracker mutations — [#311]",
            ),
            "no terminal '- [x]' index entry has the key",
        )

    def test_incidental_prose_naming_the_key_and_the_link_does_not_resolve(self):
        # A Related pointer, a sentence, a code fence — anything that is not the
        # cursor entry itself. Under a plain substring search every one of these
        # cleared the record.
        self.confirmed_transaction()
        self.resolution_refused(
            DOCUMENT + "\nSee DW-3, which became [#311] last week.\n",
            "no terminal '- [x]' index entry has the key",
        )

    def test_a_terminal_entry_with_a_contradictory_marker_does_not_resolve(self):
        # `[no-issue]` and `[deferred]` mutate no tracker and acquire no
        # transaction, so either one beside the link is a different disposition
        # from the one this record holds.
        for marker in ("[no-issue]", "[deferred]"):
            with self.subTest(marker=marker):
                self.setUp()
                self.confirmed_transaction()
                self.resolution_refused(
                    DOCUMENT.replace(
                        "- [ ] DW-3. Checkpoint tracker mutations",
                        f"- [x] DW-3. Checkpoint tracker mutations — [#311] {marker}",
                    ),
                    "a different disposition",
                )

    def test_an_entry_the_document_never_names_does_not_resolve(self):
        self.confirmed_transaction()
        self.resolution_refused(
            DOCUMENT.replace("DW-3", "DW-9"), "no index entry has the key"
        )

    def test_the_terminal_forms_the_documents_actually_use_are_accepted(self):
        # `- [X]` and `* [x]` are the same terminal entry to every Markdown
        # renderer, so a predicate that only knew `- [x]` would refuse a
        # correctly published document.
        for bullet, box in (("-", "X"), ("*", "x")):
            with self.subTest(bullet=bullet, box=box):
                self.setUp()
                self.confirmed_transaction()
                self.fx.publish_document(
                    DOCUMENT.replace(
                        "- [ ] DW-3. Checkpoint tracker mutations",
                        f"{bullet} [{box}] DW-3. Checkpoint tracker mutations — [#311]",
                    )
                )
                self.assertEqual(self.fx.resolve()["status"], "resolved")

    def test_a_terminal_entry_elsewhere_does_not_resolve_this_one(self):
        # Two entries, one terminal: the transaction resolves against its own
        # key's entry and nothing else.
        self.confirmed_transaction()
        self.resolution_refused(
            DOCUMENT.replace(
                "- [ ] DW-4. Something else",
                "- [x] DW-4. Something else — [#311]",
            ),
            "no terminal '- [x]' index entry has the key",
        )

    def test_a_checked_task_outside_the_index_does_not_resolve(self):
        # The cursor is the document's one at-a-glance index. A checked task
        # anywhere else — inside a finding's body, under another heading — can
        # name the key and the number while the real entry is still unchecked,
        # which is exactly what an interrupted run leaves behind.
        self.confirmed_transaction()
        self.resolution_refused(
            DOCUMENT.replace(
                "### DW-3 — Checkpoint tracker mutations\n\nBody.",
                "### DW-3 — Checkpoint tracker mutations\n\n"
                "- [x] DW-3. Checkpoint tracker mutations — [#311]\n",
            ),
            # The index still names DW-3, unchecked; the checked task below is
            # simply not part of the cursor and is never consulted.
            "no terminal '- [x]' index entry has the key",
        )

    def test_a_checked_task_in_a_fenced_block_inside_the_index_does_not_resolve(self):
        # An example of the finished form, quoted in the index's own section.
        self.confirmed_transaction()
        self.resolution_refused(
            DOCUMENT.replace(
                "- [ ] DW-4. Something else",
                "- [ ] DW-4. Something else\n\n```markdown\n"
                "- [x] DW-3. Checkpoint tracker mutations — [#311]\n```\n",
            ),
            "no terminal '- [x]' index entry has the key",
        )

    def test_a_nested_checked_task_in_the_index_does_not_resolve(self):
        # One flat line per entry, so an indented task is a sub-list somebody
        # wrote beneath the real entry rather than the entry itself.
        self.confirmed_transaction()
        self.resolution_refused(
            DOCUMENT.replace(
                "- [ ] DW-3. Checkpoint tracker mutations",
                "- [ ] DW-3. Checkpoint tracker mutations\n"
                "  - [x] DW-3. Checkpoint tracker mutations — [#311]",
            ),
            "no terminal '- [x]' index entry has the key",
        )

    def test_a_document_with_no_index_does_not_resolve(self):
        self.confirmed_transaction()
        self.resolution_refused(
            "# Findings\n\n- [x] DW-3. Checkpoint tracker mutations — [#311]\n",
            "has no '## Status' or '## Processing status' index",
        )

    def test_the_design_pairs_processing_status_ledger_resolves(self):
        # The other of the two index headings §4 defines, so the design pair's
        # ledger is not left unresolvable by a rule written for reports.
        self.confirmed_transaction()
        self.fx.publish_document(
            "# Design\n\n## Processing status\n\n"
            "- [x] DW-3. Checkpoint tracker mutations — [#311]\n"
            "- [ ] DW-4. Something else\n"
        )
        self.assertEqual(self.fx.resolve()["status"], "resolved")

    def test_a_key_that_merely_starts_with_this_one_does_not_resolve(self):
        # DW-3 and DW-30 are different entries. Under a substring test they are
        # not, so a terminal DW-30 line carrying the same number would clear a
        # DW-3 transaction while DW-3's own entry stayed unchecked — and the
        # next run would repeat the mutation.
        self.confirmed_transaction()
        self.resolution_refused(
            DOCUMENT.replace(
                "- [ ] DW-4. Something else",
                "- [x] DW-30. A later finding — [#311]",
            ),
            "no terminal '- [x]' index entry has the key",
        )

    def test_the_key_is_parsed_from_each_documented_entry_form(self):
        # The forms §4 and the assets actually write, so the parse is pinned
        # against real ledger lines rather than one fixture's shape.
        for line, expected in (
            ("- [x] EPIC. Asset streaming — [#210]", ("x", "EPIC")),
            ("- [ ] STREAM-1. Define loading — [#211]", (" ", "STREAM-1")),
            ("- [x] 1. Test suite is one module — [#148]", ("x", "1")),
            ("- [x] DW-3 — Checkpoint mutations — [#311]", ("x", "DW-3")),
            ("* [X] DW-3. Checkpoint — [#311]", ("X", "DW-3")),
            ("  - [x] DW-3. Nested — [#311]", None),
            ("Some prose about DW-3 and [#311].", None),
            ("- [x]", None),
        ):
            with self.subTest(line=line):
                parsed = tracker.index_entry(line)
                if expected is None:
                    self.assertIsNone(parsed)
                else:
                    self.assertEqual(parsed[:2], expected)

    def test_reachability_alone_does_not_clear_the_record(self):
        # Requirement 11 and its acceptance bullet: the publication landed, and
        # the entry it carried is not this disposition. A commit reaching the
        # branch says a commit landed, nothing more.
        self.confirmed_transaction()
        published = self.fx.publish_document(
            DOCUMENT.replace(
                "- [ ] DW-4. Something else",
                "- [x] DW-4. Something else — [#999]",
            )
        )
        self.assertEqual(published["status"], "published")
        self.assertTrue(published["remote_contains_commit"])
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.resolve()
        self.assertEqual(caught.exception.status, "resolution-unverified")
        self.assertIsNotNone(self.fx.read()[0])

    def test_the_entry_key_must_carry_the_exact_identity_not_merely_a_marker(self):
        self.confirmed_transaction()
        self.fx.publish_document(
            DOCUMENT.replace(
                "- [ ] DW-3. Checkpoint tracker mutations",
                "- [x] DW-3. Checkpoint tracker mutations — [#312]",
            )
        )
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.resolve()
        self.assertEqual(caught.exception.status, "resolution-unverified")
        self.assertEqual(caught.exception.detail["required_tokens"], ["[#311]"])

    def test_a_failed_publication_retains_the_transaction(self):
        # The acceptance bullet: nothing reached the branch, so the recorded
        # disposition is not on it, so the record stays and stops the next run.
        self.confirmed_transaction()
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.resolve()
        self.assertEqual(caught.exception.status, "resolution-unverified")
        self.assertEqual(self.fx.check()["status"], "outstanding")

    def test_publication_pending_survives_and_still_requires_verification(self):
        self.confirmed_transaction()
        record, observed = self.fx.read()
        handed = tracker.action_publication_pending(
            self.fx.docs, self.fx.ref(), record, observed
        )
        self.assertEqual(handed["transaction_state"], "publication-pending")
        self.assertEqual(self.fx.check()["transaction_state"], "publication-pending")
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.resolve()
        self.assertEqual(caught.exception.status, "resolution-unverified")

    def confirmed_pr_atomic_transaction(self, document="docs/design.md"):
        """A transaction on a document §7 classifies `pr-atomic`, which the
        publication helper declines to publish and applies locally instead."""
        self.fx.acquire(document=document)
        self.fx.begin(0, document=document)
        self.fx.confirm(0, issue_identity(), document=document)
        self.fx.begin(1, document=document)
        self.fx.confirm(1, edit_identity(), document=document)

    APPLIED = DOCUMENT.replace(
        "- [ ] DW-3. Checkpoint tracker mutations",
        "- [x] DW-3. Checkpoint tracker mutations — [#311]",
    )

    def apply_through_the_helper(self, document="docs/design.md", content=None):
        """Hand the approved content to the publication module and let it
        decline. That is the only way the local document ever legitimately
        carries a disposition, so it is how these tests produce one."""
        (self.fx.docs / document).write_text(DOCUMENT, encoding="utf-8")
        run(["git", "add", "-A"], self.fx.docs)
        run(["git", "commit", "-qm", "baseline"], self.fx.docs)
        run(["git", "push", "-q", "origin", "HEAD:master"], self.fx.docs)
        run(["git", "fetch", "-q", "origin", "master"], self.fx.primary)
        outcome = self.fx.publish_document(
            self.APPLIED if content is None else content, path=document
        )
        self.assertEqual(outcome["status"], "not-published")
        self.assertTrue(outcome["document_written"])
        return outcome

    def test_a_not_published_document_resolves_against_the_applied_local_file(self):
        # The `not-published` outcome is a successful return, not a failure: the
        # helper declines a pr-atomic or not-yet-tracked document and applies the
        # approved content locally. Without this the record would stay
        # outstanding forever and block every later disposition for it.
        self.apply_through_the_helper()
        self.confirmed_pr_atomic_transaction()
        outcome = self.fx.resolve(source="local", document="docs/design.md")
        self.assertEqual(outcome["status"], "resolved")
        self.assertEqual(outcome["source"], "local")
        self.assertIsNone(self.fx.read(document="docs/design.md")[0])

    SECOND_APPLIED = APPLIED.replace(
        "- [ ] DW-4. Something else",
        "- [x] DW-4. Something else — [#312]",
    )

    def test_successive_local_dispositions_each_resolve(self):
        # Issue #385, end to end and in the order it was observed. The second
        # disposition of a document its owner lands out of band used to arrive
        # at a working copy the publication module would not write, so its
        # record could never be resolved and every later run stopped at the
        # preflight. Each disposition resolving in turn is what says the wedge
        # is gone; asserting the module's own result would not.
        self.apply_through_the_helper()
        self.confirmed_pr_atomic_transaction()
        self.assertEqual(
            self.fx.resolve(source="local", document="docs/design.md")["status"],
            "resolved",
        )

        second = self.fx.publish_document(self.SECOND_APPLIED, path="docs/design.md")
        self.assertEqual(second["status"], "not-published")
        self.assertEqual(second["write_outcome"], "applied-over-local-predecessor")
        self.assertTrue(second["document_written"])

        self.fx.acquire(plan(entry_key="DW-4"), document="docs/design.md")
        self.fx.begin(0, document="docs/design.md")
        self.fx.confirm(0, issue_identity(number=312), document="docs/design.md")
        self.fx.begin(1, document="docs/design.md")
        self.fx.confirm(1, edit_identity(), document="docs/design.md")
        outcome = self.fx.resolve(source="local", document="docs/design.md")
        self.assertEqual(outcome["status"], "resolved")
        self.assertIsNone(self.fx.read(document="docs/design.md")[0])

        # Both dispositions accumulated in the one local document, which is the
        # state the old decline could never reach.
        applied = (self.fx.docs / "docs" / "design.md").read_text()
        self.assertIn("- [x] DW-3. Checkpoint tracker mutations — [#311]", applied)
        self.assertIn("- [x] DW-4. Something else — [#312]", applied)

    def test_a_hand_edited_document_does_not_resolve_locally(self):
        # The hole this closes: classification says the module *would* decline
        # to publish, which is not the same as the module having applied
        # anything. A file somebody edited looks identical from here, so what
        # tells them apart is the reference the module writes when its own write
        # succeeded.
        self.confirmed_pr_atomic_transaction()
        (self.fx.docs / "docs" / "design.md").write_text(
            self.APPLIED, encoding="utf-8"
        )
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.resolve(source="local", document="docs/design.md")
        self.assertEqual(caught.exception.status, "local-resolution-refused")
        self.assertIn("never applied a disposition", caught.exception.message)
        self.assertEqual(
            self.fx.check(document="docs/design.md")["status"], "outstanding"
        )

    def test_a_document_changed_after_the_module_applied_it_does_not_resolve(self):
        self.apply_through_the_helper()
        self.confirmed_pr_atomic_transaction()
        target = self.fx.docs / "docs" / "design.md"
        target.write_text(target.read_text() + "\n- [x] DW-9. Extra — [#1]\n")
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.resolve(source="local", document="docs/design.md")
        self.assertEqual(caught.exception.status, "local-resolution-refused")
        self.assertIn("has been changed since", caught.exception.message)

    def test_a_not_published_document_that_was_not_written_stays_outstanding(self):
        self.apply_through_the_helper()
        self.confirmed_pr_atomic_transaction()
        (self.fx.docs / "docs" / "design.md").unlink()
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.resolve(source="local", document="docs/design.md")
        self.assertEqual(caught.exception.status, "local-resolution-refused")
        self.assertEqual(
            self.fx.check(document="docs/design.md")["status"], "outstanding"
        )

    def test_a_publishable_document_may_not_be_resolved_from_the_working_tree(self):
        # The hole this closes: `--source local` was a caller's assertion with
        # nothing behind it, so a coordination document could be cleared from a
        # locally edited cursor before its disposition ever reached the branch —
        # leaving the next preflight clear and the tracker work repeatable.
        self.confirmed_transaction()
        (self.fx.docs / "docs" / "ui-bugs.md").write_text(
            DOCUMENT.replace(
                "- [ ] DW-3. Checkpoint tracker mutations",
                "- [x] DW-3. Checkpoint tracker mutations — [#311]",
            ),
            encoding="utf-8",
        )
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.resolve(source="local")
        self.assertEqual(caught.exception.status, "local-resolution-refused")
        self.assertIn("publishes directly to master", caught.exception.message)
        self.assertEqual(self.fx.check()["status"], "outstanding")
        # And the branch remains the way it does resolve. (Restore the baseline
        # first: the helper is the document's only writer, and it refuses a
        # working tree somebody else edited — which is what the test just did.)
        (self.fx.docs / "docs" / "ui-bugs.md").write_text(DOCUMENT, encoding="utf-8")
        self.fx.publish_document(
            DOCUMENT.replace(
                "- [ ] DW-3. Checkpoint tracker mutations",
                "- [x] DW-3. Checkpoint tracker mutations — [#311]",
            )
        )
        self.assertEqual(self.fx.resolve()["status"], "resolved")

    def test_a_document_absent_from_the_tip_does_not_resolve_locally(self):
        # A novel document is legitimately local — but the publication module
        # applies content only over an existing baseline, so it never wrote this
        # one and the disposition reached nothing. Being local makes the record
        # outstanding, not resolvable; it clears when a pull request adds the
        # document and a later run publishes to it.
        for novel in ("docs/new_design.md", "docs/ui-bugs-new.md"):
            with self.subTest(document=novel):
                self.fx.acquire(document=novel)
                self.fx.begin(0, document=novel)
                self.fx.confirm(0, issue_identity(), document=novel)
                self.fx.begin(1, document=novel)
                self.fx.confirm(1, edit_identity(), document=novel)
                (self.fx.docs / novel).write_text(
                    DOCUMENT.replace(
                        "- [ ] DW-3. Checkpoint tracker mutations",
                        "- [x] DW-3. Checkpoint tracker mutations — [#311]",
                    ),
                    encoding="utf-8",
                )
                with self.assertRaises(tracker.TransactionError) as caught:
                    self.fx.resolve(source="local", document=novel)
                self.assertEqual(caught.exception.status, "local-resolution-refused")
                self.assertIn("never applied this disposition",
                              caught.exception.message)
                self.assertEqual(
                    self.fx.check(document=novel)["status"], "outstanding"
                )

    def test_a_coordination_document_absent_from_the_tip_does_not_resolve_either(self):
        # Classified for the direct lane but not yet on the branch: the helper
        # reports not-published with document_written false, so a locally edited
        # terminal entry is not evidence of anything.
        classified = "docs/drainer-bugs.md"
        run(["git", "checkout", "-q", "master"], self.fx.primary)
        (self.fx.primary / "docs" / "agent-workflow-contract.md").write_text(
            CLASSIFICATION.replace(
                "docs/design.md | pr-atomic | test-parsed",
                "docs/design.md | pr-atomic | test-parsed\n"
                "docs/drainer-bugs.md | coordination | audit-report",
            ),
            encoding="utf-8",
        )
        run(["git", "commit", "-qam", "classify"], self.fx.primary)
        run(["git", "push", "-q", "origin", "master:master"], self.fx.primary)
        self.fx.acquire(document=classified)
        self.fx.begin(0, document=classified)
        self.fx.confirm(0, issue_identity(), document=classified)
        self.fx.begin(1, document=classified)
        self.fx.confirm(1, edit_identity(), document=classified)
        (self.fx.docs / classified).write_text(
            DOCUMENT.replace(
                "- [ ] DW-3. Checkpoint tracker mutations",
                "- [x] DW-3. Checkpoint tracker mutations — [#311]",
            ),
            encoding="utf-8",
        )
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.resolve(source="local", document=classified)
        self.assertEqual(caught.exception.status, "local-resolution-refused")
        self.assertEqual(
            self.fx.check(document=classified)["status"], "outstanding"
        )

    # -- abandonment ---------------------------------------------------------

    def test_abandonment_clears_an_unfinished_transaction_and_reports_what_landed(self):
        self.fx.acquire()
        self.fx.begin(0)
        self.fx.confirm(0, issue_identity())
        record, observed = self.fx.read()
        outcome = tracker.action_abandon(
            self.fx.docs, self.fx.ref(), record, observed
        )
        self.assertEqual(outcome["status"], "abandoned")
        self.assertEqual(outcome["confirmed_identities"][0]["id"], "311")
        self.assertIn("already exist", outcome["next_action"])
        self.assertIsNone(self.fx.read()[0])

    def test_a_fully_confirmed_transaction_is_published_rather_than_abandoned(self):
        self.confirmed_transaction()
        record, observed = self.fx.read()
        with self.assertRaises(tracker.TransactionError) as caught:
            tracker.action_abandon(self.fx.docs, self.fx.ref(), record, observed)
        self.assertEqual(caught.exception.status, "state-invalid")
        self.assertIsNotNone(self.fx.read()[0])

    # -- the command line the assets invoke ----------------------------------

    def test_acquiring_from_the_command_line_requires_explicit_approval(self):
        code, payload = self.fx.cli(
            "--acquire", "--publication-tip", PREPARED_TIP, "--plan", "-",
            stdin=json.dumps(plan()),
        )
        self.assertEqual(code, 1)
        self.assertEqual(payload["status"], "approval-required")
        self.assertEqual(self.fx.check()["status"], "clear")

    def test_the_command_line_acquires_and_then_reports_outstanding(self):
        code, payload = self.fx.cli(
            "--acquire", "--approved", "--publication-tip", PREPARED_TIP,
            "--plan", "-", stdin=json.dumps(plan()),
        )
        self.assertEqual(code, 0)
        self.assertEqual(payload["status"], "acquired")
        code, payload = self.fx.cli("--check")
        self.assertEqual(code, 1)
        self.assertEqual(payload["status"], "outstanding")

    def test_beginning_a_step_from_the_command_line_requires_approval(self):
        self.fx.acquire()
        code, payload = self.fx.cli("--begin-step", "0")
        self.assertEqual(code, 1)
        self.assertEqual(payload["status"], "approval-required")
        self.assertEqual(self.fx.read()[0]["steps"][0]["state"], "planned")

    def test_a_retry_without_absence_evidence_is_refused(self):
        self.fx.acquire()
        self.fx.begin(0)
        code, payload = self.fx.cli("--authorize-retry", "0", "--approved")
        self.assertEqual(code, 1)
        self.assertEqual(payload["status"], "evidence-required")
        self.assertEqual(self.fx.read()[0]["steps"][0]["state"], "intent")

    def test_abandonment_without_evidence_is_refused(self):
        self.fx.acquire()
        code, payload = self.fx.cli("--abandon", "--approved")
        self.assertEqual(code, 1)
        self.assertEqual(payload["status"], "evidence-required")
        self.assertIsNotNone(self.fx.read()[0])

    def test_every_command_line_action_needs_an_existing_transaction(self):
        code, payload = self.fx.cli("--begin-step", "0", "--approved")
        self.assertEqual(code, 1)
        self.assertEqual(payload["status"], "no-transaction")

    def test_a_failure_payload_carries_the_tracker_states_to_report(self):
        # Requirement 13: the run that has to report tracker state is often the
        # run that failed, so every refusal carries it rather than only the
        # successful paths.
        self.fx.acquire()
        self.fx.begin(0)
        code, payload = self.fx.cli("--begin-step", "1", "--approved")
        self.assertEqual(code, 1)
        self.assertEqual(payload["status"], "step-ambiguous")
        self.assertTrue(payload["acquired"])
        self.assertEqual(payload["transaction_state"], "intent-only")
        self.assertEqual(payload["ambiguous_step"]["index"], 0)
        self.assertEqual([step["index"] for step in payload["remaining_steps"]], [1])
        self.assertIn("next_action", payload)

    def test_an_owner_mismatch_is_refused_before_anything_is_recorded(self):
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = tracker.main([
                "--repo", "someone/else", "--root", str(self.fx.docs),
                "--path", "docs/ui-bugs.md", "--check",
            ])
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(buffer.getvalue())["status"], "owner-mismatch")


class PreflightTests(TrackerFixture):
    """Requirement 8: one pre-mutation preflight reports both records.

    What is pinned here is the caller contract the four assets already branch
    on — the `clear`/`pending` status strings and the `publication_tip` binding
    they extract — because reporting a new thing must not silently change what
    they were reading before.
    """

    def preflight(self):
        return publisher.check_pending(
            self.fx.docs, "coghex/kanban", "master", "docs/ui-bugs.md"
        )

    def test_a_clean_document_preflights_clear_with_its_tip(self):
        outcome = self.preflight()
        self.assertEqual(outcome["status"], "clear")
        self.assertEqual(outcome["pending_kinds"], [])
        self.assertEqual(
            outcome["publication_tip"],
            run(["git", "rev-parse", "origin/master"], self.fx.primary),
        )
        self.assertEqual(outcome["tracker_transaction"]["status"], "clear")

    def test_an_outstanding_tracker_transaction_makes_the_preflight_pending(self):
        self.fx.acquire()
        outcome = self.preflight()
        self.assertEqual(outcome["status"], "pending")
        self.assertEqual(outcome["pending_kinds"], ["tracker-transaction"])
        self.assertEqual(outcome["tracker_transaction"]["entry_key"], "DW-3")
        # The binding the assets extract is still there, and still the tip.
        self.assertTrue(outcome["publication_tip"])

    def test_the_preflight_names_both_records_when_both_are_outstanding(self):
        self.fx.acquire()
        run(
            ["git", "update-ref", publisher.pending_ref(
                "coghex/kanban", "docs/ui-bugs.md"
            ), run(["git", "rev-parse", "origin/master"], self.fx.docs)],
            self.fx.docs,
        )
        outcome = self.preflight()
        self.assertEqual(outcome["status"], "pending")
        self.assertEqual(
            outcome["pending_kinds"], ["publication", "tracker-transaction"]
        )
        self.assertIn("pending_commit", outcome)

    def test_a_disposition_with_no_tracker_mutation_leaves_nothing_outstanding(self):
        # Requirement 12: `[no-issue]` and `[deferred]` acquire no transaction at
        # all, so a successful publication leaves the preflight clear for the
        # next finding rather than blocking it behind a record nothing can clear.
        self.fx.publish_document(
            DOCUMENT.replace(
                "- [ ] DW-3. Checkpoint tracker mutations",
                "- [x] DW-3. Checkpoint tracker mutations — [no-issue]: folded in",
            )
        )
        outcome = self.preflight()
        self.assertEqual(outcome["status"], "clear")
        self.assertEqual(outcome["pending_kinds"], [])

    def test_the_preflight_exit_code_still_distinguishes_clear_from_pending(self):
        buffer = io.StringIO()
        argv = [
            "--repo", "coghex/kanban", "--branch", "master",
            "--root", str(self.fx.docs), "--path", "docs/ui-bugs.md",
            "--check-pending",
        ]
        with contextlib.redirect_stdout(buffer):
            self.assertEqual(publisher.main(argv), 0)
        self.fx.acquire()
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            self.assertEqual(publisher.main(argv), 1)
        self.assertEqual(json.loads(buffer.getvalue())["status"], "pending")

    def test_an_unreadable_record_makes_the_preflight_pending_and_says_why(self):
        # Through --check-pending, which is the call the four assets actually
        # make. The document states are not the answer here: what the run needs
        # is the reference, the unreadable status and the permitted next action.
        self.fx.acquire()
        self.fx.plant_unreadable_record()
        outcome = self.preflight()
        self.assertEqual(outcome["status"], "pending")
        self.assertEqual(outcome["pending_kinds"], ["tracker-transaction"])
        tracked = outcome["tracker_transaction"]
        self.assertFalse(tracked["record_readable"])
        self.assertEqual(tracked["transaction_ref"], self.fx.ref())
        self.assertIn("resolved by hand", tracked["next_action"])
        # And the binding the assets extract survives the failure.
        self.assertTrue(outcome["publication_tip"])

    def test_the_check_pending_command_line_reports_the_unreadable_record(self):
        self.fx.acquire()
        self.fx.plant_unreadable_record()
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = publisher.main([
                "--repo", "coghex/kanban", "--branch", "master",
                "--root", str(self.fx.docs), "--path", "docs/ui-bugs.md",
                "--check-pending",
            ])
        payload = json.loads(buffer.getvalue())
        self.assertEqual(code, 1)
        self.assertEqual(payload["status"], "pending")
        self.assertNotIn("internal-error", json.dumps(payload))
        self.assertFalse(payload["tracker_transaction"]["record_readable"])
        self.assertIn(
            "resolved by hand", payload["tracker_transaction"]["next_action"]
        )

    def test_a_raising_tracker_check_is_reported_as_tracker_state(self):
        # Belt and braces for the same contract: even a failure the tracker
        # module never modelled arrives as an outstanding, unreadable
        # transaction rather than as a generic internal error carrying only
        # document fields.
        module = publisher.tracker_transaction_module()
        original = module.check

        def broken(*args, **kwargs):
            raise RuntimeError("planted")

        module.check = broken
        self.addCleanup(setattr, module, "check", original)
        self.addCleanup(
            setattr, publisher, "tracker_transaction_module",
            publisher.tracker_transaction_module,
        )
        publisher.tracker_transaction_module = lambda: module
        outcome = self.preflight()
        self.assertEqual(outcome["status"], "pending")
        self.assertEqual(outcome["pending_kinds"], ["tracker-transaction"])
        self.assertEqual(outcome["tracker_transaction"]["message"], "planted")
        self.assertIn("next_action", outcome["tracker_transaction"])

    def test_an_unreachable_remote_still_reports_the_outstanding_transaction(self):
        # The records are read before the fetch, and they are what the run has
        # to report. Failing here without them tells a caller holding an
        # outstanding transaction nothing about it, at the one moment it most
        # needs to know it may not mutate anything.
        self.fx.acquire()
        self.fx.origin.rename(self.fx.origin.with_suffix(".gone"))
        with self.assertRaises(publisher.PublishError) as caught:
            self.preflight()
        detail = caught.exception.detail
        self.assertEqual(detail["pending_kinds"], ["tracker-transaction"])
        self.assertEqual(detail["tracker_transaction"]["entry_key"], "DW-3")
        self.assertTrue(detail["tracker_transaction"]["acquired"])

    def test_the_check_pending_command_line_reports_it_too(self):
        self.fx.acquire()
        self.fx.origin.rename(self.fx.origin.with_suffix(".gone"))
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = publisher.main([
                "--repo", "coghex/kanban", "--branch", "master",
                "--root", str(self.fx.docs), "--path", "docs/ui-bugs.md",
                "--check-pending",
            ])
        payload = json.loads(buffer.getvalue())
        self.assertEqual(code, 1)
        self.assertEqual(payload["pending_kinds"], ["tracker-transaction"])
        self.assertEqual(payload["tracker_transaction"]["entry_key"], "DW-3")
        self.assertIn("next_action", payload["tracker_transaction"])

    def test_an_unloadable_tracker_module_fails_the_preflight_closed(self):
        original = publisher.tracker_transaction_module

        def broken():
            raise publisher.PublishError(
                "tracker-transaction-unavailable", "planted"
            )

        publisher.tracker_transaction_module = broken
        self.addCleanup(setattr, publisher, "tracker_transaction_module", original)
        with self.assertRaises(publisher.PublishError) as caught:
            self.preflight()
        self.assertEqual(caught.exception.status, "tracker-transaction-unavailable")


if __name__ == "__main__":
    unittest.main()
