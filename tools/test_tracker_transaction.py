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
import subprocess
import tempfile
import unittest
import unittest.mock
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def _load(name, filename):
    source = REPO_ROOT / "tools" / filename
    spec = importlib.util.spec_from_file_location(name, source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tracker = _load("_kanban_tracker_transaction_under_test", "tracker_transaction.py")
publisher = _load("_kanban_publish_helper_for_tracker", "publish_coordination_doc.py")


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
        "kind": "issue",
        "id": str(number),
        "url": f"https://github.com/coghex/kanban/issues/{number}",
        "document_token": f"[#{number}]",
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
    """A bare origin, a primary clone, and a `docs-wip` linked worktree."""

    def __init__(self, directory: Path):
        self.dir = directory
        self.origin = directory / "coghex" / "kanban.git"
        self.origin.parent.mkdir(parents=True, exist_ok=True)
        self.primary = directory / "primary"
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
        self.docs = directory / "docs-wip"
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

    def begin(self, index, *, root=None):
        record, observed = self.read(root=root)
        return tracker.action_begin(
            root or self.docs, self.ref(), record, observed, index
        )

    def confirm(self, index, identity, *, root=None):
        record, observed = self.read(root=root)
        return tracker.action_confirm(
            root or self.docs, self.ref(), record, observed, index, identity
        )

    def reconcile(self, index, identity, candidates=1, *, root=None):
        record, observed = self.read(root=root)
        return tracker.action_reconcile(
            root or self.docs, self.ref(), record, observed, index, identity,
            candidates,
        )

    def resolve(self, *, source="branch", branch="master", root=None):
        record, observed = self.read(root=root)
        return tracker.action_resolve(
            root or self.docs, self.ref(), record, observed, source, branch
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

    def publish_document(self, text):
        """Land `text` on the publication branch the way a real publication
        would, so resolution is checked against a branch rather than a fake."""
        blob = self.dir / "approved.md"
        blob.write_text(text, encoding="utf-8")
        try:
            return publisher.publish(
                repository="coghex/kanban", branch="master", root=self.docs,
                document="docs/ui-bugs.md", content=blob.read_bytes(),
                message="docs: approved mutation",
            )
        finally:
            blob.unlink(missing_ok=True)

    def plant_unreadable_record(self, document="docs/ui-bugs.md"):
        """Leave the reference standing over content no version of this module
        can interpret — the shape a partially written or hand-edited record
        takes."""
        blob = run(
            ["git", "hash-object", "-w", "-t", "blob", "--stdin"],
            self.docs, input="not json",
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


class TrackerTransactionTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.fx = Fixture(Path(self._tmp.name))
        self.addCleanup(self._tmp.cleanup)

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

        def stale_read(root, ref):
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

    def test_a_not_published_document_resolves_against_the_applied_local_file(self):
        # The `not-published` outcome is a successful return, not a failure: the
        # helper declines a pr-atomic or not-yet-tracked document and applies the
        # approved content locally. Without this the record would stay
        # outstanding forever and block every later disposition for it.
        self.confirmed_transaction()
        applied = DOCUMENT.replace(
            "- [ ] DW-3. Checkpoint tracker mutations",
            "- [x] DW-3. Checkpoint tracker mutations — [#311]",
        )
        (self.fx.docs / "docs" / "ui-bugs.md").write_text(applied, encoding="utf-8")
        outcome = self.fx.resolve(source="local")
        self.assertEqual(outcome["status"], "resolved")
        self.assertEqual(outcome["source"], "local")
        self.assertIsNone(self.fx.read()[0])

    def test_a_not_published_document_that_was_not_written_stays_outstanding(self):
        self.confirmed_transaction()
        (self.fx.docs / "docs" / "ui-bugs.md").unlink()
        with self.assertRaises(tracker.TransactionError) as caught:
            self.fx.resolve(source="local")
        self.assertEqual(caught.exception.status, "document-unreadable")
        self.assertEqual(self.fx.check()["status"], "outstanding")

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


class PreflightTests(unittest.TestCase):
    """Requirement 8: one pre-mutation preflight reports both records.

    What is pinned here is the caller contract the four assets already branch
    on — the `clear`/`pending` status strings and the `publication_tip` binding
    they extract — because reporting a new thing must not silently change what
    they were reading before.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.fx = Fixture(Path(self._tmp.name))
        self.addCleanup(self._tmp.cleanup)

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
