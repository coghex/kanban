"""The interruption and fault matrix of docs/designs/approved_document_recovery_design.md.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Each `T-NN` row of the design's matrix is a named regression below. The helper
runs in a child process with one named fault injected by
tools/approved_document_fault_harness.py — `os._exit(86)` immediately after (or
before) a named operation, so no `finally` block runs and nothing the helper
would do next happens — or an operation that fails, or that takes effect and
then reports failure. The parent asserts the seam receipt and the exit code
before recovery starts, then runs a fresh preflight and a resume in a new
process, and asserts the retained bytes, refs, capture paths, remote graph and
tool-call count. No sleep, signal or timing selects a crash point.

T-28 (tracker checkpoints) is covered where the tracker is: the interruption
between a checkpoint and its resolution is
`InterruptionTests.test_an_interruption_between_the_tracker_checkpoint_and_resolution`
in tools/test_approved_document.py, and the transitions themselves in
tools/test_tracker_transaction.py.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import unittest
import unittest.mock
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))

import test_approved_document as base  # noqa: E402

approved, tracker, run = base.approved, base.tracker, base.run
DOC, OTHER, REPOSITORY = base.DOC, base.OTHER, base.REPOSITORY
NOTES, EDITED = base.NOTES, base.EDITED
blob_of = base.blob_of
HARNESS = TOOLS / "approved_document_fault_harness.py"
HELPER = TOOLS / "approved_document.py"
FOREIGN = b"# a foreign edit made by the fault harness\n"


class FaultFixture(base.RecordSeedingMixin, base.ApprovedFixture):
    def child(self, faults, *args, document=DOC, root=None):
        """Run the helper in a child with `faults`; (code, json, seam)."""
        reader, writer = os.pipe()
        root = root or self.fx.work
        environment = dict(
            os.environ,
            KANBAN_TEST_FAULTS=json.dumps(faults),
            KANBAN_TEST_SEAM_FD=str(writer),
            KANBAN_TEST_DOCUMENT=str(Path(root) / document),
        )
        try:
            proc = subprocess.run(
                [sys.executable, str(HARNESS), str(HELPER), "--repo", REPOSITORY,
                 "--root", str(root), "--path", document, *args],
                capture_output=True, text=True, env=environment, pass_fds=(writer,),
                timeout=240,
            )
        finally:
            os.close(writer)
        seam = os.read(reader, 4096).decode()
        os.close(reader)
        os.environ.get("KANBAN_TEST_DEBUG") and print(proc.stderr)
        try:
            payload = json.loads(proc.stdout) if proc.stdout.strip() else None
        except ValueError:
            payload = None
        return proc.returncode, payload, seam

    def start(self, faults, text=EDITED, *, baseline=None, document=DOC, tip=None, extra=()):
        content = self.fx.dir / "content.md"
        content.write_text(text, encoding="utf-8")
        baseline = baseline or approved.working_blob(self.fx.work, document)
        args = ["--branch", "master", "--content", str(content),
                "--expected-working-copy", baseline, *extra]
        if tip:
            args += ["--expected-tip", tip]
        return self.child(faults, *args, document=document)

    def resume_child(self, faults=(), *extra, clear_lock=True):
        # A process that died holds its lock for good; a new one clears it, as
        # an operator would, once its owner is provably gone.
        if clear_lock and self.fx.ref(approved.lock_ref(REPOSITORY, DOC)):
            code, cleared, _ = self.child([], "--branch", "master", "--clear-stale-lock")
            self.assertEqual(cleared["status"], "cleared", cleared)
        return self.child(list(faults), "--branch", "master", "--resume", *extra)

    def check_child(self, faults=()):
        return self.child(list(faults), "--branch", "master", "--check-pending")

    def crash(self, faults, *args, **kwargs):
        """Run to a crash seam and assert the process really died there."""
        code, payload, seam = self.start(faults, *args, **kwargs)
        self.assertEqual(code, 86, payload)
        self.assertEqual(seam, faults[-1]["id"])
        return payload

    def fault(self, seam, ident, mode="exit", nth=1):
        return {"seam": seam, "id": ident, "mode": mode, "nth": nth}

    def facts(self):
        work = self.fx.work
        document = work / DOC
        return {
            "pending": self.fx.pending(), "applied": self.fx.applied(),
            "document": document.read_bytes() if document.exists() else None,
            "origin": self.fx.origin_tip(), "calls": len(self.calls()),
            "leftovers": sorted(
                str(path.relative_to(work))
                for path in (work / "docs").glob(".kanban-attempt-*/*")
            ),
            "reservations": sorted(p.name for p in (work / "docs").glob(".kanban-attempt-*")),
        }

    def recover(self, *extra, expect="published"):
        """A fresh preflight, then a resume in a new process."""
        code, report, _ = self.check_child()
        self.assertIn(report["status"], ("pending", "clear"))
        code, outcome, _ = self.resume_child((), *extra)
        if expect is not None:
            self.assertEqual(outcome["status"], expect, outcome)
        return report, outcome

    def settled(self, text=EDITED):
        self.assertIsNone(self.fx.pending())
        self.assertIsNone(self.fx.applied())
        self.assertEqual(self.fx.origin_text(), text.rstrip("\n"))
        self.assertEqual(self.facts()["leftovers"], [])
        self.assertEqual(self.facts()["reservations"], [])


class PreparationFaults(FaultFixture):
    def test_T01_a_failed_fetch_changes_nothing_and_reports_known_records(self):
        self.helper_record()
        before = self.facts()
        code, report, _ = self.check_child([self.fault("fresh_tip.before", "T-01.fetch", "fail")])
        self.assertEqual(code, 1)
        self.assertEqual(report["status"], "git-failed")
        self.assertEqual(report["pending_kinds"], ["publication"])
        self.assertIsNone(report["already_landed"])
        self.assertEqual(self.facts(), before)
        code, applied, _ = self.start([self.fault("fresh_tip.before", "T-01.fetch", "fail")])
        self.assertEqual(code, 1)
        self.assertEqual(self.facts(), before)

    def test_T02_a_crash_after_taking_the_lock_leaves_it_to_be_cleared(self):
        code, payload, seam = self.start(
            [self.fault("locked_sequence.before", "T-02.locked")]
        )
        self.assertEqual((code, seam), (86, "T-02.locked"))
        self.assertEqual(self.fx.read(self.fx.work), NOTES)
        self.assertIsNone(self.fx.pending())
        code, blocked, _ = self.start([])
        self.assertEqual(blocked["status"], "locked")
        code, cleared, _ = self.child([], "--branch", "master", "--clear-stale-lock")
        self.assertEqual(cleared["status"], "cleared")
        code, outcome, _ = self.start([])
        self.assertEqual(outcome["status"], "published")
        self.settled()

    def test_T03_a_failure_before_the_intent_leaves_input_and_target_alone(self):
        content = self.fx.dir / "content.md"
        before = self.facts()
        code, payload, _ = self.start([self.fault("build_pending_commit.before", "T-03.build", "fail")])
        self.assertEqual(code, 1)
        self.assertEqual(payload["status"], "git-failed")
        self.assertEqual(content.read_text(), EDITED)
        self.assertEqual(self.facts(), before)
        self.assertIsNone(self.fx.pending())

    def test_T04_the_initial_intent_write_is_read_back_not_assumed(self):
        # Took effect, then reported failure: the next run finds it, valid.
        code, payload, _ = self.start([self.fault("create_pending.after", "T-04.write", "fail-after")])
        self.assertEqual(code, 1)
        self.assertIsNotNone(self.fx.pending())
        self.assertEqual(self.fx.read(self.fx.work), NOTES)
        self.recover()
        self.settled()

    def test_T04_a_crash_just_after_the_intent_is_resumed_from_prepared(self):
        self.crash([self.fault("create_pending.after", "T-04.after")])
        self.assertIsNotNone(self.fx.pending())
        self.assertEqual(self.fx.read(self.fx.work), NOTES)
        report, _ = self.recover()
        self.assertEqual(report["status"], "pending")
        self.assertEqual(report["recorded_blob"], blob_of(EDITED))
        self.settled()

    def test_T05_a_scratch_failure_keeps_the_intent_and_the_target(self):
        code, payload, _ = self.start([self.fault("write_scratch.before", "T-05.scratch", "fail")])
        self.assertEqual((code, payload["status"]), (1, "document-unwritable"))
        facts = self.facts()
        self.assertEqual(facts["document"], NOTES.encode())
        self.assertIsNotNone(facts["pending"])
        self.assertEqual(facts["leftovers"], [])
        self.recover()
        self.settled()

    def test_T06_the_descriptor_is_persisted_before_the_target_can_move(self):
        # Reservation made, no descriptor: harmless, and nothing was taken.
        self.crash([self.fault("reserve_directory.after", "T-06.reserved")])
        self.assertEqual(self.fx.read(self.fx.work), NOTES)
        self.assertEqual(len(self.facts()["reservations"]), 1)
        self.recover()
        self.settled()

    def test_T06_a_failed_descriptor_write_forbids_the_rename(self):
        code, payload, _ = self.start([self.fault("persist_capture.before", "T-06.descriptor", "fail")])
        self.assertEqual(code, 1)
        self.assertEqual(self.facts()["document"], NOTES.encode())
        self.assertIsNotNone(self.fx.pending())
        self.recover()
        self.settled()


class CaptureFaults(FaultFixture):
    def test_T07_a_crash_before_the_rename_takes_nothing(self):
        self.crash([self.fault("rename_aside.before", "T-07.before")])
        self.assertEqual(self.fx.read(self.fx.work), NOTES)
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        self.assertIsNotNone(record["capture"])
        self.recover()
        self.settled()

    def test_T07_a_crash_after_the_rename_is_found_from_the_descriptor(self):
        self.crash([self.fault("rename_aside.after", "T-07.after")])
        # Custody began at the rename: the document is not at its path, and the
        # preflight says so rather than reporting a clear tree.
        self.assertFalse((self.fx.work / DOC).exists())
        report = self.check_child()[1]
        self.assertEqual(report["status"], "pending")
        self.assertEqual(report["capture"]["states"]["aside"], "file")
        self.assertEqual(report["capture"]["states"]["target"], "absent")
        asides = sorted((self.fx.work / "docs").glob(".kanban-attempt-*/aside"))
        self.assertEqual([a.read_text() for a in asides], [NOTES])
        self.recover()
        self.settled()
        self.assertEqual(self.fx.read(self.fx.work), EDITED)

    def test_T08_an_unreadable_capture_is_kept_and_never_treated_as_empty(self):
        # Round 8: the read fails after the rename succeeded.
        code, payload, _ = self.start([self.fault("read_captured.before", "T-08.read", "fail")])
        self.assertEqual((code, payload["status"]), (1, "capture-unreadable"))
        facts = self.facts()
        self.assertEqual(facts["document"], NOTES.encode())
        self.assertEqual(len(facts["leftovers"]), 2)
        asides = sorted((self.fx.work / "docs").glob(".kanban-attempt-*/aside"))
        self.assertEqual([a.read_text() for a in asides], [NOTES])
        self.recover()
        self.settled()

    def test_T08_the_only_copy_of_an_untracked_original_survives(self):
        novel = "docs/untracked.md"
        self.fx.write(self.fx.work, "only untracked baseline copy\n", novel)
        baseline = approved.working_blob(self.fx.work, novel)
        code, payload, _ = self.start(
            [self.fault("read_captured.before", "T-08.untracked", "fail")],
            "only untracked baseline copy\n\n- approved\n", baseline=baseline, document=novel,
        )
        self.assertEqual((code, payload["status"]), (1, "capture-unreadable"))
        self.assertEqual(
            (self.fx.work / novel).read_text(), "only untracked baseline copy\n"
        )
        record = approved.read_pending(self.fx.work, REPOSITORY, novel)
        run(["git", "cat-file", "-e", record["payloads"]["baseline"]], self.fx.work)

    def test_T08_an_empty_original_is_not_an_absent_one(self):
        empty = "docs/empty.md"
        self.fx.write(self.fx.work, "", empty)
        baseline = approved.working_blob(self.fx.work, empty)
        self.assertEqual(baseline, blob_of(""))
        code, payload, _ = self.start([], "# filled\n", baseline=baseline, document=empty)
        self.assertEqual((code, payload["status"]), (0, "published"))

    def test_T09_a_failed_preservation_of_the_capture_is_not_a_preservation(self):
        code, payload, _ = self.start([self.fault("preserve_captured.before", "T-09.preserve", "fail")])
        self.assertEqual((code, payload["status"]), (1, "capture-unreadable"))
        self.assertEqual(self.facts()["document"], NOTES.encode())
        self.assertEqual(len(self.facts()["leftovers"]), 2)
        self.recover()
        self.settled()

    def test_T10_a_foreign_edit_captured_in_the_swap_is_rooted_and_put_back(self):
        code, payload, _ = self.start([self.fault("rename_aside.before", "T-10.foreign", "edit")])
        self.assertEqual((code, payload["status"]), (1, "document-changed-before-write"))
        self.assertEqual((self.fx.work / DOC).read_bytes(), FOREIGN)
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        self.assertEqual(record["payloads"]["captured"], approved.git_blob_hash(FOREIGN))
        self.assertEqual(self.facts()["leftovers"], [])
        code, stop, _ = self.resume_child()
        self.assertEqual(stop["status"], "document-not-baseline")
        self.assertEqual(self.calls(), [])

    def test_T11_a_winner_in_the_gap_is_left_and_the_original_is_kept(self):
        code, payload, _ = self.start([self.fault("rename_aside.after", "T-11.recreate", "create")])
        self.assertEqual((code, payload["status"]), (1, "document-changed-before-write"))
        self.assertEqual((self.fx.work / DOC).read_bytes(), FOREIGN)
        asides = sorted((self.fx.work / "docs").glob(".kanban-attempt-*/aside"))
        self.assertEqual([a.read_text() for a in asides], [NOTES])
        code, stop, _ = self.resume_child()
        self.assertEqual(stop["status"], "capture-conflict")
        self.assertEqual((self.fx.work / DOC).read_bytes(), FOREIGN)
        self.assertEqual(self.calls(), [])

    def test_T12_a_failed_install_puts_the_original_back(self):
        code, payload, _ = self.start([self.fault("link_into_place.before", "T-12.install", "fail")])
        self.assertEqual((code, payload["status"]), (1, "document-unwritable"))
        self.assertTrue(payload["restored"])
        self.assertEqual(self.facts()["document"], NOTES.encode())
        self.assertEqual(self.facts()["leftovers"], [])

    def test_T12_a_failed_restoration_keeps_the_aside_and_reports_its_path(self):
        code, payload, _ = self.start([
            self.fault("link_into_place.before", "T-12.install", "fail"),
            self.fault("restore_exclusive.before", "T-12.restore", "fail"),
        ])
        self.assertEqual((code, payload["status"]), (1, "document-unwritable"))
        self.assertFalse(payload["restored"])
        self.assertIn("aside", payload["aside"])
        self.assertFalse((self.fx.work / DOC).exists())
        self.assertEqual(Path(payload["aside"]).read_text(), NOTES)
        self.recover()
        self.settled()

    def test_T13_a_crash_after_the_install_completes_the_cleanup_only(self):
        self.crash([self.fault("finish_capture.before", "T-13.installed")])
        self.assertEqual((self.fx.work / DOC).read_text(), EDITED)
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        self.assertIsNotNone(record["capture"])
        self.recover()
        self.settled()
        self.assertEqual(len(self.calls()), 1)

    def test_T24_a_leftover_that_cannot_be_removed_keeps_the_intent_naming_it(self):
        code, payload, _ = self.start([self.fault("remove_file.before", "T-24.remove", "fail")])
        self.assertEqual((code, payload["status"]), (1, "capture-cleanup-incomplete"))
        self.assertTrue(payload["leftovers"])
        self.assertIsNotNone(self.fx.pending())
        self.assertEqual(self.calls(), [])
        self.recover()
        self.settled()


class OrphanCaptures(FaultFixture):
    def test_an_aside_no_intent_names_is_reported_and_never_adopted_or_deleted(self):
        orphan = self.fx.work / "docs" / (".kanban-attempt-" + "a" * 32)
        orphan.mkdir()
        (orphan / "aside").write_text("somebody's old original\n")
        report = self.check_child()[1]
        self.assertEqual(report["status"], "pending")
        self.assertEqual(report["pending_kinds"], ["capture"])
        self.assertEqual(report["orphan_captures"], [str(orphan.resolve())])
        # A new approval does not claim it, and it survives.
        self.assertEqual(self.approve(EDITED)["status"], "published")
        self.assertEqual((orphan / "aside").read_text(), "somebody's old original\n")

    def test_an_empty_reservation_is_harmless_and_not_reported(self):
        (self.fx.work / "docs" / (".kanban-attempt-" + "b" * 32)).mkdir()
        self.assertEqual(self.check_child()[1]["status"], "clear")


class LocalRecordFaults(FaultFixture):
    def test_T14_a_crash_before_the_applied_record_is_recovered_from_the_intent(self):
        self.crash([self.fault("record_applied_content.before", "T-14.before")])
        self.assertIsNone(self.fx.applied())
        self.assertEqual((self.fx.work / DOC).read_text(), EDITED)
        self.recover()
        self.settled()

    def test_T14_a_crash_after_the_applied_record_is_recovered_too(self):
        self.crash([self.fault("record_applied_content.after", "T-14.after")])
        self.assertEqual(self.fx.applied(), blob_of(EDITED))
        self.recover()
        self.settled()

    def test_T14_a_conflicting_applied_record_stops_and_is_kept(self):
        self.crash([self.fault("record_applied_content.before", "T-14.conflict")])
        other = approved._preserve(self.fx.work, b"somebody else's applied content\n")
        run(["git", "update-ref", approved.applied_ref(REPOSITORY, DOC), other], self.fx.work)
        pending = self.fx.pending()
        code, stop, _ = self.resume_child()
        self.assertEqual(stop["status"], "applied-conflict")
        self.assertEqual((self.fx.applied(), self.fx.pending()), (other, pending))
        self.assertEqual(self.calls(), [])

    def test_T14_an_unrecorded_application_does_not_license_local_resolution(self):
        self.crash([self.fault("record_applied_content.before", "T-14.unrecorded")])
        permitted, why = tracker.local_resolution_permitted(
            self.fx.work, {"repository": REPOSITORY, "document": DOC}, "master"
        )
        self.assertFalse(permitted)
        self.assertIn("never applied a disposition", why)


class EvidenceFaults(FaultFixture):
    def test_T15_a_failed_history_read_never_becomes_a_negative(self):
        code, payload, _ = self.start([self.fault("interval_commits.before", "T-15.history", "fail")])
        self.assertEqual(code, 1)
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.fx.read(self.fx.work), EDITED)
        self.recover()
        self.settled()

    def test_T15_a_shallow_history_cannot_prove_a_negative(self):
        self.mode("refuse")
        self.start([])
        calls = len(self.calls())
        with unittest.mock.patch.object(approved, "is_shallow", lambda root: True):
            with self.assertRaises(approved.DocumentError) as caught:
                self.resume()
        self.assertEqual(caught.exception.status, "landing-unverifiable")
        self.assertIn("shallow", caught.exception.message)
        self.assertEqual(len(self.calls()), calls)

    def test_T16_a_missing_tool_is_not_a_handoff(self):
        self.remove_tool()
        code, payload, _ = self.start([])
        self.assertEqual((code, payload["reason"]), (1, "tool-missing"))
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        self.assertIsNone(record["handoff"])
        os.environ["PATH"] = f"{self.bin}{os.pathsep}{os.environ['PATH']}"
        self.recover()
        self.assertEqual(self.gh_calls(), [])
        self.settled()

    def test_T19_a_crash_after_the_tool_reconciles_without_asking_again(self):
        self.crash([self.fault("run_publication_tool.after", "T-19.after-tool")])
        self.assertEqual(self.fx.origin_blob(), blob_of(EDITED))
        self.assertIsNotNone(self.fx.pending())
        self.recover()
        self.settled()
        self.assertEqual(len(self.calls()), 1)

    def test_T19_a_tool_that_died_before_keep_is_landed_but_divergent_never_reapplied(self):
        self.fx.upstream_edit(base.UPSTREAM_ELSEWHERE)
        run(["git", "fetch", "-q", "origin", "master"], self.fx.work)
        self.mode("dies-before-keep")
        code, payload, _ = self.start([])
        self.assertEqual((code, payload["status"]), (1, "landed-but-divergent"))
        self.assertEqual(self.fx.read(self.fx.work), EDITED)
        merged = self.fx.origin_text()
        self.mode("land")
        code, stop, _ = self.resume_child()
        self.assertEqual(stop["status"], "landed-but-divergent")
        self.assertEqual(len(self.calls()), 1)
        self.fx.write(self.fx.work, merged + "\n")
        code, outcome, _ = self.resume_child()
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(len(self.calls()), 1)

    def test_T20_a_crash_before_the_landing_lookup_still_never_republishes(self):
        # Round 5/6: somebody else publishes the approved bytes while the tool
        # runs; the run dies before it looks; the document then moves on.
        real_tool, real_confirm, seen = approved.run_publication_tool, approved.confirm_landing, [0]

        def concurrent(*args, **kwargs):
            self.fx.upstream_edit(EDITED, message="a concurrent publication")
            return real_tool(*args, **kwargs)

        def dying(*args, **kwargs):
            seen[0] += 1
            if seen[0] == 2:
                raise base.SimulatedCrash("before the landing lookup")
            return real_confirm(*args, **kwargs)

        with unittest.mock.patch.object(approved, "run_publication_tool", concurrent):
            with unittest.mock.patch.object(approved, "confirm_landing", dying):
                with self.assertRaises(base.SimulatedCrash):
                    self.approve(EDITED)
        self.assertIsNone(approved.read_pending(self.fx.work, REPOSITORY, DOC)["landing_evidence"])
        self.revert_document()
        tip = self.fx.origin_tip()
        outcome = self.resume()
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(outcome["landed_via"], "already-present")
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.fx.origin_tip(), tip)

    def test_T20_a_post_tool_fetch_failure_says_the_outcome_is_unknown(self):
        self.mode("claims-success")
        code, payload, _ = self.start([self.fault("fresh_tip.before", "T-20.fetch", "fail", nth=3)])
        self.assertEqual(code, 1)
        self.assertEqual(payload["reason"], "landing-unverifiable")
        self.assertIn("publication outcome unknown", payload["message"])
        self.assertNotIn("nothing was published", payload["message"])
        self.assertIsNone(payload["remote_contains_commit"])
        self.mode("land")
        self.recover()
        self.settled()

    def test_T21_a_crash_just_after_the_evidence_write_resumes_from_saved_evidence(self):
        self.crash([self.fault("persist_landing.after", "T-21.after")])
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        self.assertEqual(record["landing_evidence"]["via"], "receipt")
        self.revert_document()
        self.recover()
        self.assertEqual(len(self.calls()), 1)
        self.assertIsNone(self.fx.pending())

    def test_T21_a_failed_evidence_write_keeps_the_intent_and_rediscovers(self):
        code, payload, _ = self.start([self.fault("persist_landing.before", "T-21.write", "fail")])
        self.assertEqual(code, 1)
        self.assertIsNone(approved.read_pending(self.fx.work, REPOSITORY, DOC)["landing_evidence"])
        self.revert_document()
        self.recover()
        self.assertEqual(len(self.calls()), 1)

    def revert_document(self):
        self.fx.upstream_edit(EDITED.replace("- line 8\n", "- line 8, edited later\n"))

    def test_T23_an_unreadable_working_copy_is_unknown_not_clean(self):
        self.crash([self.fault("settle_landed.before", "T-23.settle")])
        path = self.fx.work / DOC
        os.chmod(path, 0)
        try:
            code, stop, _ = self.resume_child()
        finally:
            os.chmod(path, 0o644)
        self.assertEqual(code, 1)
        self.assertEqual(stop["status"], "file-unreadable")
        self.assertIsNotNone(self.fx.pending())
        self.recover()
        self.settled()

    def test_T23_a_staged_change_after_the_landing_is_divergent(self):
        self.crash([self.fault("settle_landed.before", "T-23.staged")])
        self.fx.write(self.fx.work, EDITED + "\nstaged\n")
        run(["git", "add", DOC], self.fx.work)
        self.fx.write(self.fx.work, EDITED)
        code, stop, _ = self.resume_child()
        self.assertEqual(stop["status"], "landed-but-divergent")
        self.assertIsNotNone(self.fx.pending())

    def test_T25_the_applied_record_goes_first_and_a_crash_between_is_harmless(self):
        self.crash([self.fault("delete_ref.after", "T-25.applied-gone", nth=1)])
        self.assertIsNone(self.fx.applied())
        self.assertIsNotNone(self.fx.pending())
        self.recover()
        self.settled()
        self.assertEqual(len(self.calls()), 1)

    def test_T25_a_failed_applied_delete_retains_both_records(self):
        code, payload, _ = self.start([self.fault("delete_ref.before", "T-25.delete", "fail", nth=1)])
        self.assertEqual(code, 1)
        self.assertIsNotNone(self.fx.pending())
        self.recover()
        self.settled()

    def test_T26_a_crash_after_the_pending_delete_leaves_no_attempt_to_replay(self):
        self.crash([self.fault("delete_ref.after", "T-26.pending-gone", nth=2)])
        self.assertIsNone(self.fx.pending())
        code, outcome, _ = self.resume_child()
        self.assertEqual(outcome["status"], "no-pending-publication")
        self.assertEqual(self.check_child()[1]["status"], "clear")
        self.assertEqual(len(self.calls()), 1)

    def test_T26_a_pending_record_that_changed_is_never_deleted_over(self):
        real = approved.delete_ref

        def racing(root, ref, expected):
            if ref == approved.pending_ref(REPOSITORY, DOC):
                run(["git", "update-ref", ref,
                     run(["git", "commit-tree", "HEAD^{tree}", "-m", "somebody else's"], root)], root)
            return real(root, ref, expected)

        with unittest.mock.patch.object(approved, "delete_ref", racing):
            with self.assertRaises(approved.DocumentError) as caught:
                self.approve(EDITED)
        self.assertEqual(caught.exception.status, "record-retained")
        self.assertIsNotNone(self.fx.pending())

    def test_T27_a_crash_before_the_lock_release_leaves_a_clearable_lock(self):
        self.crash([self.fault("release_lock.before", "T-27.release")])
        self.settled()
        code, blocked, _ = self.start([], "# another\n", baseline=blob_of(EDITED))
        self.assertEqual(blocked["status"], "locked")
        code, cleared, _ = self.child([], "--branch", "master", "--clear-stale-lock")
        self.assertEqual(cleared["status"], "cleared")
        self.settled()

    def test_T29_a_failed_migration_leaves_the_legacy_record_and_the_file_alone(self):
        commit = self.publisher_record()
        self.fx.write(self.fx.work, EDITED)
        before = self.facts()
        code, payload, _ = self.resume_child(
            [self.fault("rewrite_pending.before", "T-29.migrate", "fail")]
        )
        self.assertEqual(code, 1)
        self.assertEqual(self.facts()["pending"], commit)
        self.assertEqual(self.facts()["document"], before["document"])
        self.recover()
        self.settled()

    def test_T29_a_crash_after_migration_keeps_the_original_rooted(self):
        self.publisher_record()
        self.fx.write(self.fx.work, EDITED)
        code, _, seam = self.resume_child([self.fault("rewrite_pending.after", "T-29.after")])
        self.assertEqual((code, seam), (86, "T-29.after"))
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        self.assertEqual(record["version"], 2)
        self.assertIn("predecessor-record", record["payloads"])
        self.recover()
        self.settled()

    def test_T29_a_version_1_record_is_migrated_and_resumed(self):
        self.v1_record()
        code, outcome, _ = self.resume_child()
        self.assertEqual(outcome["status"], "published")
        self.settled()


class HandoffFaults(FaultFixture):
    def refuse_then(self, faults):
        self.mode("refuse")
        return faults

    def test_T17_a_failed_marker_write_forbids_the_spawn(self):
        code, payload, _ = self.start([self.fault("persist_handoff.before", "T-17.marker", "fail")])
        self.assertEqual(code, 1)
        self.assertEqual(self.calls(), [])
        self.assertIsNone(approved.read_pending(self.fx.work, REPOSITORY, DOC)["handoff"])

    def clear_lock(self, *extra):
        return self.child([], "--branch", "master", "--clear-stale-lock", *extra)[1]

    def test_T17_a_crash_after_the_marker_blocks_the_lock_and_the_retry_until_quiescence(self):
        self.crash([self.fault("persist_handoff.after", "T-17.marker-written", nth=1)])
        self.assertEqual(self.calls(), [])
        # A dead helper does not prove its child stopped: the lock stays.
        self.assertEqual(self.clear_lock()["status"], "lock-child-not-quiescent")
        self.assertEqual(self.clear_lock("--operator-quiescent")["status"], "cleared")
        code, blocked, _ = self.resume_child(clear_lock=False)
        self.assertEqual(blocked["reason"], "tool-child-not-quiescent")
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.gh_calls(), [])
        code, outcome, _ = self.resume_child((), "--operator-quiescent", clear_lock=False)
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(len(self.calls()), 1)
        self.assertTrue(self.gh_calls())

    def test_T17_a_crash_between_the_spawn_and_the_child_record_is_unknown(self):
        self.mode("refuse")
        self.crash([self.fault("process_identity.before", "T-17.spawned")])
        deadline = time.monotonic() + 30
        while not self.calls() and time.monotonic() < deadline:
            time.sleep(0.05)  # only to reap the orphaned child, not to pick a crash point
        self.assertEqual(len(self.calls()), 1)
        self.mode("land")
        self.assertEqual(self.clear_lock()["status"], "lock-child-not-quiescent")
        self.assertEqual(self.clear_lock("--operator-quiescent")["status"], "cleared")
        code, blocked, _ = self.resume_child(clear_lock=False)
        self.assertEqual(blocked["reason"], "tool-child-not-quiescent")
        self.assertEqual(len(self.calls()), 1)
        code, outcome, _ = self.resume_child((), "--operator-quiescent", clear_lock=False)
        self.assertEqual(outcome["status"], "published")

    def test_T17_a_recorded_child_is_classified_by_pid_start_time_and_argv(self):
        child = {"pid": 4242, "start": "Fri Oct 23 10:00:00 2026", "argv": ["docs-push", "x"]}
        running = {"state": "running", "host": "h", "argv": child["argv"], "child": child, "result": None}
        cases = (
            ("the same live process", {"start": child["start"], "args": "docs-push x"}, "live"),
            ("a reused pid, new start time", {"start": "Fri Oct 23 11:00:00 2026", "args": "other"}, "gone"),
            ("the same process with a changed argv", {"start": child["start"], "args": "docs-push y"}, "unknown"),
            ("no such process", None, "gone"),
        )
        for name, identity, expected in cases:
            with self.subTest(case=name):
                with unittest.mock.patch.object(approved, "process_identity", lambda pid, i=identity: i):
                    self.assertEqual(approved.child_state(running), expected)
        def unreadable(pid):
            raise approved.DocumentError("process-inspection-failed", "no ps")
        with unittest.mock.patch.object(approved, "process_identity", unreadable):
            self.assertEqual(approved.child_state(running), "unknown")
        self.assertEqual(approved.child_state(dict(running, state="finished")), "gone")
        self.assertEqual(approved.child_state(dict(running, state="marker", child=None)), "unknown")
        self.assertEqual(approved.child_state(None), "none")

    def test_T17_a_live_child_blocks_a_retry_and_the_lock_clear(self):
        self.mode("refuse")
        self.start([])
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        live = dict(record["handoff"], state="running", child={
            "pid": os.getpid(), "start": "Fri Oct 23 10:00:00 2026", "argv": ["docs-push"],
        })
        self.reseed(record, handoff=live)
        identity = {"start": "Fri Oct 23 10:00:00 2026", "args": "docs-push"}
        with unittest.mock.patch.object(approved, "process_identity", lambda pid: identity):
            with self.assertRaises(approved.DocumentError) as caught:
                approved.clear_stale_lock_checked(self.fx.work, REPOSITORY, DOC)
            self.assertEqual(caught.exception.status, "lock-child-not-quiescent")
            outcome = self.resume()
        self.assertEqual(outcome["reason"], "tool-child-not-quiescent")
        self.assertEqual(len(self.calls()), 1)

    def test_T18_a_tool_that_times_out_is_stopped_and_reported(self):
        self.mode("hang")
        with unittest.mock.patch.object(approved, "TOOL_TIMEOUT_SECONDS", 2):
            outcome = self.approve(EDITED)
        self.assertEqual(outcome["status"], "incomplete-publication")
        self.assertEqual(outcome["reason"], "tool-failed")
        self.assertIn("did not finish", outcome["message"])
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        self.assertEqual(record["handoff"]["state"], "finished")
        self.assertIsNone(record["handoff"]["result"]["returncode"])

    def test_T18_every_failed_tool_outcome_decides_by_fresh_evidence(self):
        for mode, expected in (
            ("refuse", "tool-refused"),
            ("claims-success", "tool-reported-success-without-landing"),
        ):
            with self.subTest(mode=mode):
                self.setUp()
                self.mode(mode)
                outcome = self.approve(EDITED)
                self.assertEqual(outcome["reason"], expected)
                self.assertFalse(outcome["remote_contains_commit"])
                self.assertIn("next_action", outcome)


class RetryGateFaults(FaultFixture):
    def refused_once(self):
        self.mode("refuse")
        self.assertEqual(self.approve(EDITED)["reason"], "tool-refused")
        self.mode("land")

    def gate_mode(self, name):
        os.environ["FAKE_GH_MODE"] = name

    def test_T30_an_affirmative_rule_permits_the_retry_with_the_exact_request(self):
        self.refused_once()
        outcome = self.resume()
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(
            self.gh_calls(),
            [["api", "--paginate", "repos/coghex/kanban/rules/branches/master"]],
        )

    def test_T30_a_rule_found_only_on_a_later_page_is_found(self):
        # The default fake prints the rule on the second of two pages.
        self.refused_once()
        self.assertEqual(self.resume()["status"], "published")

    def test_T30_a_missing_rule_or_a_read_failure_stops_with_the_records_kept(self):
        for mode in ("no-rule", "error", "classic-open"):
            with self.subTest(mode=mode):
                self.setUp()
                self.refused_once()
                self.gate_mode(mode)
                before = self.facts()
                outcome = self.resume()
                self.assertEqual(outcome["reason"], "retry-gate-unsatisfied")
                self.assertEqual(self.facts(), before)
                self.assertEqual(len(self.calls()), 1)

    def test_T30_readable_classic_protection_without_force_pushes_is_an_alternative(self):
        self.refused_once()
        self.gate_mode("classic-ok")
        self.assertEqual(self.resume()["status"], "published")
        paths = [call[-1] for call in self.gh_calls()]
        self.assertEqual(paths, [
            "repos/coghex/kanban/rules/branches/master",
            "repos/coghex/kanban/branches/master/protection",
        ])

    def test_T30_an_earlier_positive_answer_is_never_reused(self):
        self.refused_once()
        self.mode("refuse")
        self.assertEqual(self.resume()["reason"], "tool-refused")
        self.gate_mode("no-rule")
        self.mode("land")
        self.assertEqual(self.resume()["reason"], "retry-gate-unsatisfied")
        self.assertEqual(len(self.calls()), 2)

    def test_T30_the_branch_is_url_encoded(self):
        self.assertTrue(approved.retry_gate(REPOSITORY, "release/1.0")["ok"])
        self.assertEqual(
            self.gh_calls()[0][-1], "repos/coghex/kanban/rules/branches/release%2F1.0"
        )

    def test_T30_positive_landing_needs_no_gate(self):
        self.crash_after_tool()
        self.gate_mode("error")
        code, outcome, _ = self.resume_child()
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(self.gh_calls(), [])
        self.assertEqual(len(self.calls()), 1)

    def crash_after_tool(self):
        code, _, seam = self.start([self.fault("settle_landed.before", "T-30.landed")])
        self.assertEqual((code, seam), (86, "T-30.landed"))

    def test_T30_no_first_attempt_is_gated_and_no_bypass_actor_is_read(self):
        self.assertEqual(self.approve(EDITED)["status"], "published")
        self.assertEqual(self.gh_calls(), [])


class ReviewRegressions(FaultFixture):
    """Reproduced by the first rereview of the reworked branch (PR #836)."""

    def test_a_symlinked_ancestor_confines_nothing_outside_the_write_root(self):
        outside = self.fx.dir / "outside"
        outside.mkdir()
        (outside / "note.md").write_text("an external file\n")
        (self.fx.work / "linked").symlink_to(outside)
        before = self.facts()
        code, payload, _ = self.start(
            [], "an external file\n\n- approved\n", document="linked/note.md",
            baseline=blob_of("an external file\n"),
        )
        self.assertEqual((code, payload["status"]), (1, "document-path-unsafe"))
        self.assertEqual((outside / "note.md").read_text(), "an external file\n")
        self.assertEqual(sorted(p.name for p in outside.iterdir()), ["note.md"])
        self.assertEqual(self.calls(), [])
        self.assertIsNone(self.fx.pending("linked/note.md"))
        report = self.child([], "--branch", "master", "--check-pending", document="linked/note.md")[1]
        self.assertEqual(report["status"], "document-path-unsafe")
        self.assertEqual(self.facts()["origin"], before["origin"])

    def test_an_unreadable_document_is_pending_not_clear(self):
        path = self.fx.work / DOC
        os.chmod(path, 0)
        try:
            code, report, _ = self.check_child()
        finally:
            os.chmod(path, 0o644)
        self.assertEqual(code, 1)
        self.assertEqual(report["status"], "pending")
        self.assertIn("publication", report["pending_kinds"])
        self.assertEqual(report["record_fault"]["status"], "file-unreadable")
        self.assertIsNone(report["working_copy_blob"])

    def test_two_abandoned_intents_are_both_retained(self):
        first = self.helper_record(text=EDITED)
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        first_blob = record["approved_blob"]
        code, one, _ = self.child([], "--branch", "master", "--abandon-intent")
        self.assertEqual(one["status"], "abandoned")
        other_text = EDITED.replace("- line 6\n", "- line 6, a second attempt\n")
        self.helper_record(text=other_text)
        second_blob = approved.read_pending(self.fx.work, REPOSITORY, DOC)["approved_blob"]
        code, two, _ = self.child([], "--branch", "master", "--abandon-intent")
        self.assertEqual(two["status"], "abandoned")
        self.assertNotEqual(one["abandoned_ref"], two["abandoned_ref"])
        run(["git", "reflog", "expire", "--expire=now", "--all"], self.fx.work)
        run(["git", "gc", "-q", "--prune=now"], self.fx.work)
        for blob in (first_blob, second_blob):
            run(["git", "cat-file", "-e", blob], self.fx.work)
        self.assertEqual(self.fx.ref(one["abandoned_ref"]), first)

    def test_a_contradicting_applied_record_stops_the_settlement(self):
        self.crash([self.fault("settle_landed.before", "T-26.contradiction")])
        other = approved._preserve(self.fx.work, b"unrelated but valid applied content\n")
        run(["git", "update-ref", approved.applied_ref(REPOSITORY, DOC), other], self.fx.work)
        pending = self.fx.pending()
        code, stop, _ = self.resume_child()
        self.assertEqual(stop["status"], "applied-conflict")
        self.assertEqual((self.fx.pending(), self.fx.applied()), (pending, other))
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.check_child()[1]["status"], "pending")

    def test_a_legacy_commit_that_changes_more_than_the_document_is_malformed(self):
        for name in ("a second path", "a merge commit"):
            with self.subTest(case=name):
                self.setUp()
                root, tip = self.fx.work, self.fx.origin_tip()
                stored = approved._preserve(root, EDITED.encode())
                if name == "a second path":
                    commit = base.publisher.build_commit(root, tip, DOC, stored, "legacy")
                    other = approved._preserve(root, b"# Other, quietly changed\n")
                    index = root / "scratch-index"
                    env = dict(os.environ, GIT_INDEX_FILE=str(index))
                    subprocess.run(["git", "read-tree", commit], cwd=root, env=env, check=True)
                    subprocess.run(["git", "update-index", "--cacheinfo", f"100644,{other},{OTHER}"],
                                   cwd=root, env=env, check=True)
                    tree = subprocess.run(["git", "write-tree"], cwd=root, env=env, check=True,
                                          capture_output=True, text=True).stdout.strip()
                    index.unlink()
                    commit = run(["git", "commit-tree", tree, "-p", tip, "-m", "legacy"], root)
                else:
                    first = base.publisher.build_commit(root, tip, DOC, stored, "legacy")
                    commit = run(["git", "commit-tree", f"{first}^{{tree}}", "-p", tip, "-p", first,
                                  "-m", "legacy merge"], root)
                run(["git", "update-ref", base.publisher.pending_ref(REPOSITORY, DOC), commit], root)
                self.fx.write(root, EDITED)
                report = self.check_child()[1]
                self.assertEqual(report["record_fault"]["status"], "pending-malformed")
                code, stop, _ = self.resume_child()
                self.assertEqual(stop["status"], "pending-malformed")
                self.assertEqual(self.fx.pending(), commit)
                self.assertEqual(self.calls(), [])


class ReworkRoundTwo(FaultFixture):
    """Reproduced by the second rereview of the reworked branch (PR #836)."""

    def test_every_alias_spelling_of_a_document_is_refused_not_keyed_apart(self):
        self.mode("refuse")
        self.assertEqual(self.approve(EDITED)["status"], "incomplete-publication")
        for alias in ("./docs/notes.md", "docs//notes.md", "docs/./notes.md", "docs/notes.md/", "docs/../docs/notes.md"):
            with self.subTest(alias=alias):
                code, report, _ = self.child([], "--branch", "master", "--check-pending", document=alias)
                self.assertEqual((code, report["status"]), (1, "document-name-unsupported"))
                with self.assertRaises(approved.DocumentError):
                    approved._key(REPOSITORY, alias)
                with self.assertRaises(tracker.TransactionError):
                    tracker.record_key(REPOSITORY, alias)
                code, started, _ = self.start([], document=alias, baseline=blob_of(NOTES))
                self.assertEqual(started["status"], "document-name-unsupported")
        # The canonical spelling still sees the outstanding publication.
        self.assertEqual(self.check_child()[1]["status"], "pending")

    def test_a_failed_ref_read_is_not_a_clear_preflight(self):
        self.helper_record()
        real = approved.git

        def broken(args, **kwargs):
            if args[:3] == ["rev-parse", "--verify", "--quiet"] and args[3].startswith(
                "refs/kanban/pending-publication/"
            ):
                return subprocess.CompletedProcess(args, 128, b"", b"fatal: unable to read: I/O error")
            return real(args, **kwargs)

        with unittest.mock.patch.object(approved, "git", broken):
            with self.assertRaises(approved.DocumentError) as caught:
                approved.check_pending(self.fx.work, REPOSITORY, "master", DOC)
        self.assertEqual(caught.exception.status, "ref-unreadable")
        self.assertIsNotNone(self.fx.pending())

    def test_a_failed_tracker_ref_read_is_outstanding_not_absent(self):
        ref = tracker.transaction_ref(REPOSITORY, DOC)
        tracker.action_acquire(self.fx.work, ref, REPOSITORY, DOC, base.tracker_plan(), self.fx.origin_tip())
        real = tracker.git

        def broken(args, **kwargs):
            if args[:3] == ["rev-parse", "--verify", "--quiet"] and args[3] == ref:
                return subprocess.CompletedProcess(args, 128, b"", b"fatal: I/O error")
            return real(args, **kwargs)

        with unittest.mock.patch.object(tracker, "git", broken):
            report = tracker.check(self.fx.work, REPOSITORY, DOC)
        self.assertEqual(report["status"], "outstanding")
        self.assertFalse(report["record_readable"])

    def test_operator_quiescence_settles_a_publication_that_already_landed(self):
        # The tool was spawned and its identity never recorded, and it then
        # published and exited: the landing is a fact, and the operator's
        # confirmation lets the record settle.
        self.crash([self.fault("process_identity.before", "T-17.spawned")])
        deadline = time.monotonic() + 30
        while not self.calls() and time.monotonic() < deadline:
            time.sleep(0.05)  # only to reap the orphaned child
        while self.fx.origin_blob() != blob_of(EDITED) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertEqual(self.check_child()[1]["already_landed"], True)
        self.assertEqual(self.clear_lock("--operator-quiescent")["status"], "cleared")
        code, blocked, _ = self.resume_child(clear_lock=False)
        self.assertEqual(blocked["status"], "tool-child-not-quiescent")
        code, outcome, _ = self.resume_child((), "--operator-quiescent", clear_lock=False)
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(len(self.calls()), 1)
        self.assertIsNone(self.fx.pending())

    def clear_lock(self, *extra):
        return self.child([], "--branch", "master", "--clear-stale-lock", *extra)[1]

    def test_a_known_live_child_is_never_overridden_by_the_operator(self):
        self.crash([self.fault("settle_landed.before", "T-17.live")])
        approved.clear_stale_lock(self.fx.work, approved.lock_ref(REPOSITORY, DOC))
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        live = dict(record["handoff"], state="running", child={
            "pid": os.getpid(), "start": "Fri Oct 23 10:00:00 2026", "argv": ["docs-push"],
        })
        self.reseed(record, handoff=live)
        identity = {"start": "Fri Oct 23 10:00:00 2026", "args": "docs-push"}
        with unittest.mock.patch.object(approved, "process_identity", lambda pid: identity):
            with self.assertRaises(approved.DocumentError) as caught:
                self.resume(operator_quiescent=True)
        self.assertEqual(caught.exception.status, "tool-child-not-quiescent")
        self.assertIsNotNone(self.fx.pending())

    def resume(self, root=None, document=DOC, operator_quiescent=False):
        return approved.apply_and_publish(
            repository=REPOSITORY, branch="master", root=root or self.fx.work,
            document=document, content=None, operator_quiescent=operator_quiescent,
        )

    def test_a_held_lock_is_reported_not_ignored(self):
        approved.acquire_lock(
            self.fx.work, approved.lock_ref(REPOSITORY, DOC), self.fx.origin_tip(), REPOSITORY, DOC
        )
        report = approved.check_pending(self.fx.work, REPOSITORY, "master", DOC)
        self.assertEqual(report["status"], "pending")
        self.assertIn("lock", report["pending_kinds"])
        self.assertEqual(report["lock"]["owner"]["pid"], os.getpid())

    def test_a_preflight_that_raced_a_publication_does_not_say_clear(self):
        real = approved.fresh_tip
        raced = []

        def racing(root, branch):
            if not raced:
                raced.append(1)
                self.helper_record()
            return real(root, branch)

        with unittest.mock.patch.object(approved, "fresh_tip", racing):
            report = approved.check_pending(self.fx.work, REPOSITORY, "master", DOC)
        self.assertEqual(report["status"], "pending")
        self.assertIn("publication", report["pending_kinds"])

    def test_a_snapshot_that_never_settles_is_a_refusal(self):
        real = approved.fresh_tip
        flips = [0]

        def churning(root, branch):
            flips[0] += 1
            run(["git", "update-ref", approved.applied_ref(REPOSITORY, DOC),
                 approved._preserve(root, f"churn {flips[0]}\n".encode())], root)
            return real(root, branch)

        with unittest.mock.patch.object(approved, "fresh_tip", churning):
            with self.assertRaises(approved.DocumentError) as caught:
                approved.check_pending(self.fx.work, REPOSITORY, "master", DOC)
        self.assertEqual(caught.exception.status, "preflight-changed")

    def stage_mode(self, mode):
        """Stage a mode-only change: the index keeps HEAD's blob. (A plain
        `update-index --chmod` would also restage the working file's content.)"""
        run(["git", "update-index", "--cacheinfo", f"{mode},{blob_of(NOTES)},{DOC}"], self.fx.work)

    def test_a_mode_only_staged_change_refuses_application_resume_and_settlement(self):
        self.stage_mode("100755")
        error = self.failure(self.approve, EDITED)
        self.assertEqual(error.status, "document-staged")
        self.assertIsNone(self.fx.pending())
        self.stage_mode("100644")
        self.mode("refuse")
        self.assertEqual(self.approve(EDITED)["status"], "incomplete-publication")
        self.mode("land")
        self.stage_mode("100755")
        calls = len(self.calls())
        self.assertEqual(self.failure(self.resume).status, "document-staged")
        self.assertEqual(len(self.calls()), calls)
        self.stage_mode("100644")
        self.assertEqual(self.resume()["status"], "published")

    def test_a_mode_only_staged_change_after_the_landing_is_divergent(self):
        self.crash([self.fault("settle_landed.before", "T-23.mode")])
        self.stage_mode("100755")
        code, stop, _ = self.resume_child()
        self.assertEqual(stop["status"], "landed-but-divergent")
        self.assertIsNotNone(self.fx.pending())


class ReworkRoundThree(FaultFixture):
    """Reproduced by the third rereview of the reworked branch (PR #836)."""

    def test_a_filesystem_alias_of_an_existing_spelling_is_refused(self):
        self.mode("refuse")
        self.assertEqual(self.approve(EDITED)["status"], "incomplete-publication")
        for alias in ("Docs/notes.md", "docs/NOTES.md", "DOCS/Notes.MD"):
            with self.subTest(alias=alias):
                code, report, _ = self.child([], "--branch", "master", "--check-pending", document=alias)
                self.assertEqual((code, report["status"]), (1, "document-name-unsupported"))
                self.assertIn("one file must have one spelling", report["message"])
                code, started, _ = self.start([], document=alias, baseline=blob_of(NOTES))
                self.assertEqual(started["status"], "document-name-unsupported")
        self.assertEqual(self.check_child()[1]["status"], "pending")

    def test_the_retry_checks_landing_again_after_quiescence_and_the_gate(self):
        # The earlier child may publish between the negative check and the
        # gate; a retry authorized by the first negative would reinstate a
        # mutation that landed and was reverted.
        self.mode("refuse")
        self.assertEqual(self.approve(EDITED)["reason"], "tool-refused")
        self.mode("land")
        real = approved.retry_gate

        def late(repository, branch):
            result = real(repository, branch)
            self.fx.upstream_edit(EDITED, message="the earlier child publishes")
            self.fx.upstream_edit(EDITED.replace("- line 8\n", "- line 8, reverted later\n"))
            return result

        with unittest.mock.patch.object(approved, "retry_gate", late):
            outcome = self.resume()
        self.assertEqual(outcome["status"], "published")
        self.assertEqual(outcome["landed_via"], "already-present")
        self.assertEqual(len(self.calls()), 1)

    def drop_object(self, oid):
        """Delete one loose object, as a damaged repository would lose it."""
        common = Path(run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], self.fx.work))
        path = common / "objects" / oid[:2] / oid[2:]
        self.assertTrue(path.exists(), f"{oid} is not a loose object here")
        os.chmod(path.parent, 0o755)
        os.chmod(path, 0o644)
        path.unlink()

    def test_a_missing_tree_object_is_unknown_not_an_absent_document(self):
        self.mode("refuse")
        self.assertEqual(self.approve(EDITED)["reason"], "tool-refused")
        self.fx.upstream_edit(EDITED, message="a concurrent publication")
        landing_commit = self.fx.origin_tip()
        self.fx.upstream_edit(EDITED.replace("- line 8\n", "- line 8, reverted later\n"))
        run(["git", "fetch", "-q", "origin", "master"], self.fx.work)
        self.drop_object(run(["git", "rev-parse", f"{landing_commit}:docs"], self.fx.work))
        calls = len(self.calls())
        report = self.check_child()[1]
        self.assertIsNone(report["already_landed"])
        self.assertEqual(report["record_fault"]["status"], "landing-unverifiable")
        self.mode("land")
        code, stop, _ = self.resume_child()
        self.assertEqual(stop["status"], "landing-unverifiable")
        self.assertEqual(len(self.calls()), calls)
        self.assertIsNotNone(self.fx.pending())

    def test_an_absent_document_in_an_old_commit_is_still_a_proved_absence(self):
        # The path walk reads the parent tree and finds no entry: that is a
        # negative, not an error, and a document created later is unaffected.
        novel = "docs/created-later.md"
        self.fx.write(self.fx.work, "# later\n", novel)
        baseline = approved.working_blob(self.fx.work, novel)
        code, outcome, _ = self.start([], "# later\n\n- approved\n", baseline=baseline, document=novel)
        self.assertEqual((code, outcome["status"]), (0, "published"))

    def test_an_ancestry_command_error_is_unknown_never_a_negative(self):
        real = approved.git

        def broken(args, **kwargs):
            if args[:2] == ["merge-base", "--is-ancestor"]:
                return subprocess.CompletedProcess(args, 128, b"", b"fatal: bad object")
            return real(args, **kwargs)

        with unittest.mock.patch.object(approved, "git", broken):
            with self.assertRaises(approved.DocumentError) as caught:
                approved.is_ancestor(self.fx.work, self.fx.origin_tip(), self.fx.origin_tip())
        self.assertEqual(caught.exception.status, "ancestry-unreadable")
        # ...so older saved evidence is not accepted when the check breaks.
        self.fx.upstream_edit(EDITED)
        older = self.fx.origin_tip()
        self.fx.upstream_edit(EDITED.replace("- line 8\n", "- line 8, later\n"))
        run(["git", "fetch", "-q", "origin", "master"], self.fx.work)
        self.mode("refuse")
        self.approve(EDITED, baseline=approved.working_blob(self.fx.work, DOC))
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        commit = self.reseed(record, landing={
            "via": "already-present", "published_blob": record["approved_blob"],
            "receipt_commit": None, "evidence_commit": older,
        })

        def breaking(args, **kwargs):
            if args[:2] == ["merge-base", "--is-ancestor"] and args[2] == older and args[3] == record["rendered_tip"]:
                return subprocess.CompletedProcess(args, 128, b"", b"fatal: bad object")
            return real(args, **kwargs)

        self.mode("land")
        calls = len(self.calls())
        with unittest.mock.patch.object(approved, "git", breaking):
            with self.assertRaises(approved.DocumentError) as caught:
                self.resume()
        self.assertEqual(caught.exception.status, "ancestry-unreadable")
        self.assertEqual((self.fx.pending(), len(self.calls())), (commit, calls))


class ReworkRoundFour(FaultFixture):
    """Reproduced by the fourth rereview of the reworked branch (PR #836)."""

    def test_the_tracker_refuses_a_filesystem_alias_at_every_entry_point(self):
        ref = tracker.transaction_ref(REPOSITORY, DOC)
        tracker.action_acquire(
            self.fx.work, ref, REPOSITORY, DOC, base.tracker_plan(), self.fx.origin_tip()
        )
        self.assertEqual(tracker.check(self.fx.work, REPOSITORY, DOC)["status"], "outstanding")
        for alias in ("Docs/notes.md", "docs/NOTES.md"):
            with self.subTest(alias=alias):
                with self.assertRaises(tracker.TransactionError) as caught:
                    tracker.check(self.fx.work, REPOSITORY, alias)
                self.assertEqual(caught.exception.status, "document-name-unsupported")
                with self.assertRaises(tracker.TransactionError) as caught:
                    tracker.action_acquire(
                        self.fx.work, tracker.transaction_ref(REPOSITORY, alias), REPOSITORY,
                        alias, base.tracker_plan(), self.fx.origin_tip(),
                    )
                self.assertEqual(caught.exception.status, "document-name-unsupported")
                buffer = __import__("io").StringIO()
                with __import__("contextlib").redirect_stdout(buffer):
                    code = tracker.main(["--repo", REPOSITORY, "--root", str(self.fx.work),
                                         "--path", alias, "--check"])
                self.assertEqual(code, 1)
                self.assertEqual(json.loads(buffer.getvalue())["status"], "document-name-unsupported")

    def legacy_applied_only(self):
        outcome = base.publisher.publish(
            repository=REPOSITORY, branch="master", root=self.fx.work, document=DOC,
            content=EDITED.encode(), message="legacy",
            expected_working_copy=blob_of(NOTES),
        )
        self.assertEqual(outcome["status"], "not-published")
        self.assertEqual(self.fx.applied(), blob_of(EDITED))

    def test_a_standalone_applied_record_that_the_document_has_outgrown_stops(self):
        self.legacy_applied_only()
        grown = EDITED + "\n- written by hand after the disposition\n"
        self.fx.write(self.fx.work, grown)
        report = self.check_child()[1]
        self.assertEqual(report["status"], "pending")
        self.assertEqual(report["record_fault"]["status"], "applied-diverged")
        code, stop, _ = self.start([], "# anything\n", baseline=blob_of(grown))
        self.assertEqual(stop["status"], "applied-diverged")
        self.assertEqual(self.fx.applied(), blob_of(EDITED))
        self.assertIsNone(self.fx.pending())
        self.assertEqual(self.fx.read(self.fx.work), grown)
        run(["git", "gc", "-q", "--prune=now"], self.fx.work)
        run(["git", "cat-file", "-e", blob_of(EDITED)], self.fx.work)

    def test_a_standalone_applied_record_matching_the_document_is_a_predecessor(self):
        self.legacy_applied_only()
        self.assertEqual(self.check_child()[1]["status"], "clear")
        second = EDITED.replace("- line 5\n", "- line 5, second\n")
        code, outcome, _ = self.start([], second, baseline=blob_of(EDITED))
        self.assertEqual((code, outcome["status"]), (0, "published"))

    def test_the_document_is_rechecked_after_the_gate_and_the_fresh_history_read(self):
        self.mode("refuse")
        self.assertEqual(self.approve(EDITED)["reason"], "tool-refused")
        self.mode("land")
        real = approved.retry_gate

        def staging(repository, branch):
            result = real(repository, branch)
            run(["git", "update-index", "--cacheinfo", f"100755,{blob_of(NOTES)},{DOC}"], self.fx.work)
            return result

        calls = len(self.calls())
        with unittest.mock.patch.object(approved, "retry_gate", staging):
            error = self.failure(self.resume)
        self.assertEqual(error.status, "document-staged")
        self.assertEqual(len(self.calls()), calls)
        self.assertIsNotNone(self.fx.pending())

    def test_the_operator_never_overrides_a_live_child_on_any_lock_path(self):
        self.mode("refuse")
        self.start([])
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        live = dict(record["handoff"], state="running", child={
            "pid": os.getpid(), "start": "Fri Oct 23 10:00:00 2026", "argv": ["docs-push"],
        })
        self.reseed(record, handoff=live)
        lock = approved.lock_ref(REPOSITORY, DOC)
        dead = json.dumps({"host": approved.socket.gethostname(), "pid": 2**22 + 99,
                           "repository": REPOSITORY, "document": DOC},
                          sort_keys=True, separators=(",", ":"))
        run(["git", "update-ref", lock, run(["git", "commit-tree", "HEAD^{tree}", "-m", dead], self.fx.work)], self.fx.work)
        identity = {"start": "Fri Oct 23 10:00:00 2026", "args": "docs-push"}
        with unittest.mock.patch.object(approved, "process_identity", lambda pid: identity):
            for flag in ((), ("--operator-quiescent",)):
                with self.subTest(flags=flag):
                    buffer = __import__("io").StringIO()
                    with __import__("contextlib").redirect_stdout(buffer):
                        code = approved.main(["--repo", REPOSITORY, "--root", str(self.fx.work),
                                              "--path", DOC, "--branch", "master",
                                              "--clear-stale-lock", *flag])
                    self.assertEqual(code, 1)
                    self.assertEqual(json.loads(buffer.getvalue())["status"], "lock-child-not-quiescent")
                    self.assertIsNotNone(self.fx.ref(lock))

    def test_an_unreadable_intent_does_not_clear_a_lock(self):
        self.helper_record()
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        self.reseed(record, handoff={"state": "nonsense"})
        lock = approved.lock_ref(REPOSITORY, DOC)
        dead = json.dumps({"host": approved.socket.gethostname(), "pid": 2**22 + 98,
                           "repository": REPOSITORY, "document": DOC},
                          sort_keys=True, separators=(",", ":"))
        run(["git", "update-ref", lock, run(["git", "commit-tree", "HEAD^{tree}", "-m", dead], self.fx.work)], self.fx.work)
        for flag in ((), ("--operator-quiescent",)):
            with self.subTest(flags=flag):
                code, stop, _ = self.child([], "--branch", "master", "--clear-stale-lock", *flag)
                self.assertEqual((code, stop["status"]), (1, "pending-malformed"))
                self.assertIsNotNone(self.fx.ref(lock))


class ReworkRoundFive(FaultFixture):
    """Reproduced by the fifth rereview of the reworked branch (PR #836)."""

    def child_pid_file(self):
        path = self.fx.dir / "child.pid"
        os.environ["FAKE_DOCS_PUSH_CHILD_PID"] = str(path)
        self.addCleanup(os.environ.pop, "FAKE_DOCS_PUSH_CHILD_PID", None)

        def stop():
            try:
                os.kill(int(path.read_text()), 9)
            except (OSError, ValueError):
                pass

        self.addCleanup(stop)
        return path

    def hung(self, mode):
        self.mode(mode)
        pid_file = self.child_pid_file()
        with unittest.mock.patch.object(approved, "TOOL_TIMEOUT_SECONDS", 2), \
                unittest.mock.patch.object(approved, "DESCENDANT_GRACE_SECONDS", 1):
            outcome = self.approve(EDITED)
        return outcome, pid_file

    def test_a_timed_out_tool_takes_its_whole_process_group_with_it(self):
        outcome, pid_file = self.hung("hang-with-child")
        self.assertEqual(outcome["reason"], "tool-failed")
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        self.assertEqual(record["handoff"]["state"], "finished")
        with self.assertRaises(OSError):
            os.kill(int(pid_file.read_text()), 0)

    def test_a_descendant_that_outlives_a_timed_out_tool_keeps_the_handoff_open(self):
        outcome, pid_file = self.hung("hang-with-escapee")
        self.assertEqual(outcome["reason"], "tool-not-quiescent")
        os.kill(int(pid_file.read_text()), 0)  # still running: nothing killed it
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        self.assertNotEqual(record["handoff"]["state"], "finished")
        self.assertEqual(approved.child_state(record["handoff"]), "unknown")
        calls = len(self.calls())
        self.mode("land")
        again = self.resume()
        self.assertEqual(again["reason"], "tool-child-not-quiescent")
        self.assertEqual(len(self.calls()), calls)
        self.assertIsNotNone(self.fx.pending())
        # Only the operator's statement of quiescence reopens it.
        final = approved.apply_and_publish(
            repository=REPOSITORY, branch="master", root=self.fx.work, document=DOC,
            content=None, operator_quiescent=True,
        )
        self.assertEqual(final["status"], "published")
        self.assertEqual(len(self.calls()), calls + 1)

    def stage_after(self, name, count=None):
        """Wrap approved.<name> so a mode-only staged change lands right after it."""
        real = getattr(approved, name)
        seen = [0]

        def wrapped(*args, **kwargs):
            result = real(*args, **kwargs)
            seen[0] += 1
            if count is None or seen[0] == count:
                run(["git", "update-index", "--cacheinfo",
                     f"100755,{blob_of(EDITED)},{DOC}"], self.fx.work)
            return result

        return unittest.mock.patch.object(approved, name, wrapped)

    def test_a_change_staged_during_the_capability_probe_is_caught_before_the_spawn(self):
        with self.stage_after("publication_tool"):
            error = self.failure(self.approve, EDITED)
        self.assertEqual(error.status, "document-staged")
        self.assertEqual(self.calls(), [])
        self.assertIsNone(approved.read_pending(self.fx.work, REPOSITORY, DOC)["handoff"])

    def test_a_change_staged_while_the_handoff_is_recorded_is_caught_before_the_spawn(self):
        with self.stage_after("persist_handoff", count=1):
            error = self.failure(self.approve, EDITED)
        self.assertEqual(error.status, "document-staged")
        self.assertEqual(self.calls(), [])
        # The marker was taken back: no tool was started, so no child is owed.
        self.assertIsNone(approved.read_pending(self.fx.work, REPOSITORY, DOC)["handoff"])

    def test_a_descendant_left_by_an_exited_tool_blocks_recovery_after_a_crash(self):
        self.mode("leaves-child")
        pid_file = self.child_pid_file()
        self.crash([self.fault("group_alive.before", "R6.group")])
        os.kill(int(pid_file.read_text()), 0)
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        self.assertEqual(record["handoff"]["state"], "running")
        self.assertEqual(approved.child_state(record["handoff"]), "unknown")
        calls = len(self.calls())
        self.mode("land")
        # The lock its dead owner left stays while the group is not empty.
        code, stop, _ = self.child([], "--branch", "master", "--clear-stale-lock")
        self.assertEqual(stop["status"], "lock-child-not-quiescent")
        self.assertIsNotNone(self.fx.ref(approved.lock_ref(REPOSITORY, DOC)))
        self.assertEqual((len(self.calls()), self.fx.pending() is not None), (calls, True))
        # Only the operator's confirmation reopens it.
        code, cleared, _ = self.child([], "--branch", "master", "--clear-stale-lock",
                                      "--operator-quiescent")
        self.assertEqual(cleared["status"], "cleared")
        code, final, _ = self.child([], "--branch", "master", "--resume", "--operator-quiescent")
        self.assertEqual(final["status"], "published", final)
        self.assertEqual(len(self.calls()), calls + 1)

    def test_an_exited_tool_with_an_empty_group_is_gone(self):
        self.mode("refuse")
        self.assertEqual(self.approve(EDITED)["reason"], "tool-refused")
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        running = dict(record["handoff"], state="running", child={
            "pid": 2**22 + 77, "start": "Fri Oct 23 10:00:00 2026", "argv": ["docs-push"],
        })
        with unittest.mock.patch.object(approved, "process_identity", lambda pid: None):
            self.assertEqual(approved.child_state(running), "gone")

    def narrowed(self):
        """A clone whose configured refspec no longer maps the default branch."""
        run(["git", "config", "remote.origin.fetch",
             "+refs/heads/elsewhere:refs/remotes/origin/elsewhere"], self.fx.work)

    def test_a_narrowed_refspec_does_not_hide_the_fetched_tip(self):
        self.narrowed()
        stale = run(["git", "rev-parse", "origin/master"], self.fx.work)
        self.fx.upstream_edit("# upstream moved on\n", message="upstream moved")
        tip = self.fx.origin_tip()
        self.assertNotEqual(stale, tip)
        self.assertEqual(approved.fresh_tip(self.fx.work, "master"), tip)
        self.assertEqual(tracker.fetched_tip(self.fx.work, "master"), tip)

    def test_a_landing_is_found_when_the_refspec_does_not_map_the_branch(self):
        self.mode("refuse")
        self.assertEqual(self.approve(EDITED)["reason"], "tool-refused")
        self.narrowed()
        self.fx.upstream_edit(EDITED, message="the approved content lands")
        report = self.preflight()
        self.assertTrue(report["already_landed"])
        record = {"repository": REPOSITORY, "document": DOC}
        permitted, why = tracker.local_resolution_permitted(self.fx.work, record, "master")
        self.assertFalse(permitted)
        self.assertIn("landed", why)

    def test_a_lock_without_a_usable_owner_pid_is_never_cleared(self):
        lock = approved.lock_ref(REPOSITORY, DOC)
        host = approved.socket.gethostname()
        for label, payload in (
            ("missing", {"host": host, "repository": REPOSITORY, "document": DOC}),
            ("string", {"host": host, "pid": "4242", "repository": REPOSITORY, "document": DOC}),
            ("boolean", {"host": host, "pid": True, "repository": REPOSITORY, "document": DOC}),
            ("zero", {"host": host, "pid": 0, "repository": REPOSITORY, "document": DOC}),
            ("not-an-object", [host, 4242]),
        ):
            with self.subTest(owner=label):
                subject = json.dumps(payload, sort_keys=True, separators=(",", ":"))
                commit = run(["git", "commit-tree", "HEAD^{tree}", "-m", subject], self.fx.work)
                run(["git", "update-ref", lock, commit], self.fx.work)
                code, stop, _ = self.child([], "--branch", "master", "--clear-stale-lock")
                self.assertEqual(code, 1)
                self.assertIn(stop["status"], ("lock-owner-unusable", "lock-foreign-owner"))
                self.assertEqual(self.fx.ref(lock), commit)
                run(["git", "update-ref", "-d", lock], self.fx.work)

    def test_the_tracker_reads_the_branch_after_the_child_is_known_to_be_gone(self):
        self.mode("refuse")
        self.assertEqual(self.approve(EDITED)["reason"], "tool-refused")
        helper = tracker.approved_document_module()
        real = helper.child_state

        def landing_while_it_exits(handoff):
            # The child lands and exits after the caller began, and the
            # branch is edited again before the child is known to be gone.
            self.fx.upstream_edit(EDITED, message="the child publishes")
            self.fx.upstream_edit(NOTES, message="then it is reverted upstream")
            return real(handoff)

        record = {"repository": REPOSITORY, "document": DOC}
        helper.child_state = landing_while_it_exits
        with unittest.mock.patch.object(tracker, "approved_document_module", lambda: helper):
            permitted, why = tracker.local_resolution_permitted(self.fx.work, record, "master")
        self.assertFalse(permitted)
        self.assertIn("landed", why)

    def test_the_tracker_refuses_a_local_resolution_for_another_branch(self):
        self.crash([self.fault("record_applied_content.after", "R5.applied")])
        run(["git", "push", "-q", "origin", "master:refs/heads/other"], self.fx.work)
        record = {"repository": REPOSITORY, "document": DOC}
        permitted, _ = tracker.local_resolution_permitted(self.fx.work, record, "master")
        self.assertTrue(permitted)
        permitted, why = tracker.local_resolution_permitted(self.fx.work, record, "other")
        self.assertFalse(permitted)
        self.assertIn("for master", why)

    def test_a_conflicting_applied_record_stops_a_capture_recovery_before_it_mutates(self):
        self.crash([self.fault("rename_aside.after", "R5.capture")])
        other = approved._preserve(self.fx.work, b"somebody else's applied content\n")
        run(["git", "update-ref", approved.applied_ref(REPOSITORY, DOC), other], self.fx.work)
        before = self.facts()
        code, stop, _ = self.resume_child()
        self.assertEqual(stop["status"], "applied-conflict")
        self.assertEqual(self.facts(), before)
        self.assertFalse((self.fx.work / DOC).exists())

    def test_a_conflicting_applied_record_stops_a_v1_migration_before_it_rewrites(self):
        self.v1_record()
        other = approved._preserve(self.fx.work, b"somebody else's applied content\n")
        run(["git", "update-ref", approved.applied_ref(REPOSITORY, DOC), other], self.fx.work)
        pending = self.fx.pending()
        error = self.failure(self.resume)
        self.assertEqual(error.status, "applied-conflict")
        self.assertEqual(self.fx.pending(), pending)


class NegativeControls(FaultFixture):
    """Each guard must fail its test when removed: the tests have teeth."""

    def test_removing_the_interval_check_makes_older_evidence_trusted(self):
        self.fx.upstream_edit(EDITED)
        older = self.fx.origin_tip()
        self.fx.upstream_edit(EDITED.replace("- line 8\n", "- line 8, later\n"))
        run(["git", "fetch", "-q", "origin", "master"], self.fx.work)
        self.mode("refuse")
        self.approve(EDITED, baseline=approved.working_blob(self.fx.work, DOC))
        record = approved.read_pending(self.fx.work, REPOSITORY, DOC)
        self.reseed(record, landing={
            "via": "already-present", "published_blob": record["approved_blob"],
            "receipt_commit": None, "evidence_commit": older,
        })
        self.mode("land")
        real = approved.is_ancestor
        # Intact: the older occurrence is refused.
        with self.assertRaises(approved.DocumentError):
            self.resume()
        # Interval check removed: it is accepted and the mutation is declared landed.
        original = approved.validate_evidence

        def weak(root, fresh, pending, evidence):
            return {"landed": True, "via": evidence["via"],
                    "published_blob": evidence["published_blob"], "receipt_commit": None,
                    "evidence_commit": evidence["evidence_commit"], "fresh_tip": fresh}

        with unittest.mock.patch.object(approved, "validate_evidence", weak):
            self.assertEqual(self.resume()["status"], "published")
        self.assertIs(original, approved.validate_evidence)
        self.assertIs(real, approved.is_ancestor)

    def test_reading_a_failure_as_absence_would_hide_an_unreadable_document(self):
        path = self.fx.work / DOC
        os.chmod(path, 0)
        try:
            with self.assertRaises(approved.DocumentError):
                approved.file_state(path)
            real = approved.file_state

            def lenient(target):
                try:
                    return real(target)
                except approved.DocumentError:
                    return "absent", None

            self.assertEqual(lenient(path), ("absent", None))
        finally:
            os.chmod(path, 0o644)

    def test_deleting_the_aside_on_a_failed_read_would_lose_the_only_copy(self):
        # The original defect, reintroduced as a restoration that unlinks.
        def destructive(aside, target):
            Path(aside).unlink()

        def failing_read(aside):
            raise OSError(5, "injected")

        with unittest.mock.patch.object(approved, "read_captured", failing_read):
            with unittest.mock.patch.object(approved, "restore_exclusive", destructive):
                with self.assertRaises(approved.DocumentError):
                    self.approve(EDITED)
        self.assertFalse((self.fx.work / DOC).exists())
        self.assertEqual(sorted((self.fx.work / "docs").glob(".kanban-attempt-*/aside")), [])
        # ...which is exactly the state test_T08 asserts never occurs.


if __name__ == "__main__":
    unittest.main()
