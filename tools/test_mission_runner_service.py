"""Unit and fixture tests for the mission runner controller.

Hermetic throughout. The account root every runtime document hangs off is
redirected into a temporary directory, the scheduler is a fake script that
writes whatever report a test asks for, and the repositories are temporary `git
init` checkouts whose remotes name repositories nothing here ever contacts. No
test reaches the network, a GitHub account, a model, or a service manager.

The lifecycle runs are real: a real controller process supervises a real
scheduler child in its own session, and the containment assertions are made
against what those processes actually did. The process-containment case in
particular stages a mission child that *ignores* `SIGTERM`, so what it proves
is the controller's escalation to `SIGKILL` rather than a child's cooperation.

The mirror checks read `src/Kanban/Mission/Pass.hs` and hold every constant
this module copies equal to the Haskell declaration it copies. That is the only
thing standing between the two halves of a pass contract that cannot import
each other.
"""

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

import mission_runner_service as service


CONTROLLER = Path(__file__).resolve().parent / "mission_runner_service.py"
REPO_ROOT = Path(__file__).resolve().parents[1]
PASS_MODULE = REPO_ROOT / "src" / "Kanban" / "Mission" / "Pass.hs"

# Runs the tracked controller with its account root redirected, so a fixture's
# subprocess writes where the fixture can see it. Only `account_home` is
# replaced: every lock, every signal, and every real scheduler child below it
# is the tracked module's own.
CONTROLLER_WRAPPER = '''#!/usr/bin/env python3
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
account = Path(sys.argv[2])
del sys.argv[1:3]

import mission_runner_service as service

service.account_home = lambda: account
raise SystemExit(service.main())
'''

# Stands in for `kanban --mission-scheduler`. It records every invocation --
# argv, working directory, and the parts of the environment a pass depends on
# -- then writes whatever report the plan file names and exits with the status
# that report implies. A test asserts nothing about this script itself; it
# exists so the controller can be asserted against a scheduler that schedules
# nothing.
FAKE_SCHEDULER = '''#!/usr/bin/env python3
import json
import os
import signal
import subprocess
import sys
import time

CALLS = os.environ["FAKE_SCHEDULER_CALLS"]
PLAN = os.environ["FAKE_SCHEDULER_PLAN"]

# A mission child that refuses to stop politely. Its whole purpose is to make
# the controller's escalation the thing under test.
STUBBORN = (
    "import os, signal, sys, time\\n"
    "signal.signal(signal.SIGINT, signal.SIG_IGN)\\n"
    "signal.signal(signal.SIGTERM, signal.SIG_IGN)\\n"
    "open(sys.argv[1], 'w').write(str(os.getpid()))\\n"
    "time.sleep(300)\\n"
)


def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (FileNotFoundError, ValueError):
        return default


def record(entry):
    with open(CALLS, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, sort_keys=True) + "\\n")


def recorded():
    try:
        with open(CALLS, encoding="utf-8") as handle:
            return [json.loads(line) for line in handle if line.strip()]
    except FileNotFoundError:
        return []


def main():
    plan = read_json(PLAN, {})
    index = len(recorded())
    record(
        {
            "argv": sys.argv[1:],
            "cwd": os.getcwd(),
            "stdin_is_a_terminal": sys.stdin.isatty(),
            "xdg_data_home": os.environ.get("XDG_DATA_HOME"),
            "xdg_state_home": os.environ.get("XDG_STATE_HOME"),
            "path": os.environ.get("PATH"),
        }
    )
    child_marker = plan.get("mission_child")
    if child_marker:
        # A mission child in this pass's own process group, which is what the
        # controller's stop has to reach.
        subprocess.Popen([sys.executable, "-c", STUBBORN, child_marker])
        while not os.path.exists(child_marker):
            time.sleep(0.01)
    reports = plan.get("reports") or []
    report = reports[index] if index < len(reports) else plan.get("report")
    if report is None:
        report = {"kind": "idle"}
    if report.get("stderr"):
        print(report["stderr"], file=sys.stderr)
    hold = report.get("hold_seconds")
    if hold:
        time.sleep(hold)
    if report.get("raw") is not None:
        sys.stdout.write(report["raw"])
        sys.stdout.flush()
        return report.get("status", 0)
    sys.stdout.write(json.dumps(report["document"]))
    sys.stdout.flush()
    return report.get("status", 0)


if __name__ == "__main__":
    raise SystemExit(main())
'''


def haskell_string_characters(literal):
    """The characters a Haskell string literal denotes.

    Read rather than compared as written: `"/\\\\\\NUL"` in the source is the
    three characters `/`, `\\` and NUL, and a test that compared the escapes
    would be pinning how the literal is spelled rather than what it says.
    """
    characters = set()
    index = 0
    while index < len(literal):
        if literal[index] != "\\":
            characters.add(literal[index])
            index += 1
            continue
        if literal.startswith("\\NUL", index):
            characters.add("\0")
            index += 4
        else:
            characters.add(literal[index + 1])
            index += 2
    return characters


def wait_until(predicate, *, timeout=25.0, message="condition"):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.01)
    raise AssertionError(f"timed out waiting for {message}")


def process_gone(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def pass_document(
    *,
    repository="acme/widgets",
    termination="completed",
    admitted=(),
    attention=(),
    detail="nothing to do",
    exit_code=None,
):
    """One well-formed pass report, in the shape the scheduler writes."""
    return {
        "schema": service.PASS_SCHEMA,
        "version": service.PASS_VERSION,
        "repository": repository,
        "started_at": "2026-09-11T00:00:00Z",
        "finished_at": "2026-09-11T00:00:01Z",
        "termination": termination,
        "exit_code": service.PASS_EXIT_CODES[termination] if exit_code is None else exit_code,
        "admitted": list(admitted),
        "attention": list(attention),
        "detail": detail,
    }


def admitted_entry(mission="mission-a", disposition="advanced", detail="advanced"):
    return {"mission": mission, "disposition": disposition, "detail": detail}


def attention_entry(mission="mission-a", state="disabled"):
    return {
        "mission": mission,
        "attention_id": f"acme/widgets#{mission}@2026-09-11T00:00:00Z",
        "targets": [{"kind": "issue", "number": 844}],
        "notification": state,
        "detail": None,
    }


# ---------------------------------------------------------------------------
# The mirrored contract
# ---------------------------------------------------------------------------


class MirroredPassContractTests(unittest.TestCase):
    """Every constant this controller copies, against the Haskell that owns it.

    The controller cannot import `Kanban.Mission.Pass`, so the schema name, the
    version, the three vocabularies and the exit-status mapping are copied. A
    copy nothing holds to its original is a copy that drifts, and the way it
    drifts is silent: the controller goes on refusing reports the scheduler has
    started writing, or accepting a field that no longer means what it did.
    """

    @classmethod
    def setUpClass(cls):
        cls.source = PASS_MODULE.read_text(encoding="utf-8")

    def declared(self, name):
        """The string literal a nullary Haskell binding is defined as."""
        match = re.search(rf'^{name} = "([^"]*)"$', self.source, re.MULTILINE)
        self.assertIsNotNone(match, f"{name} is not declared in {PASS_MODULE.name}")
        return match.group(1)

    def declared_int(self, name):
        match = re.search(rf"^{name} = (\d+)$", self.source, re.MULTILINE)
        self.assertIsNotNone(match, f"{name} is not declared in {PASS_MODULE.name}")
        return int(match.group(1))

    def tags(self, function):
        """Every wire tag one total case expression spells."""
        body = re.search(
            rf"^{function} \w+ = case \w+ of\n((?:  .*\n)+)", self.source, re.MULTILINE
        )
        self.assertIsNotNone(body, f"{function} is not a total case in {PASS_MODULE.name}")
        return {
            match.group(1)
            for match in re.finditer(r'-> "([^"]*)"', body.group(1))
        }

    def test_the_schema_and_version_match(self):
        self.assertEqual(service.PASS_SCHEMA, self.declared("missionPassSchema"))
        self.assertEqual(service.PASS_VERSION, self.declared_int("missionPassVersion"))

    def test_the_vocabularies_match(self):
        self.assertEqual(service.PASS_TERMINATIONS, self.tags("missionPassTerminationTag"))
        self.assertEqual(service.PASS_DISPOSITIONS, self.tags("missionDispositionTag"))
        self.assertEqual(
            service.PASS_NOTIFICATION_STATES, self.tags("missionNotificationStateTag")
        )

    def test_the_exit_statuses_match(self):
        body = re.search(
            r"^missionPassExitCode \w+ = case \w+ of\n((?:  .*\n)+)",
            self.source,
            re.MULTILINE,
        )
        self.assertIsNotNone(body)
        declared = {
            match.group(1): int(match.group(2))
            for match in re.finditer(r"MissionPass(\w+) -> (\d+)", body.group(1))
        }
        self.assertEqual(
            {name.lower(): code for name, code in declared.items()},
            service.PASS_EXIT_CODES,
        )

    def test_the_failing_disposition_matches(self):
        body = re.search(
            r"^missionDispositionIsFailure \w+ = case \w+ of\n((?:  .*\n)+)",
            self.source,
            re.MULTILINE,
        )
        self.assertIsNotNone(body)
        failing = {
            match.group(1)
            for match in re.finditer(r"MissionDisposition(\w+) -> True", body.group(1))
        }
        self.assertEqual({name.lower() for name in failing}, service.PASS_FAILING_DISPOSITIONS)

    def test_the_mission_identifier_constraints_match(self):
        # Mirrored from `Kanban.Mission.Paths.safeMissionComponent`, which is
        # the one place a mission identifier is decided to be addressable.
        paths = (REPO_ROOT / "src" / "Kanban" / "Mission" / "Paths.hs").read_text(
            encoding="utf-8"
        )
        body = re.search(
            r"^safeMissionComponent name =\n((?:  .*\n)+)", paths, re.MULTILINE
        )
        self.assertIsNotNone(body, "safeMissionComponent is not declared")
        reserved = re.search(r'notElem`? \[(.*?)\]', body.group(1))
        self.assertIsNotNone(reserved)
        self.assertEqual(
            service.PASS_RESERVED_MISSION_NAMES,
            {name.strip().strip('"') for name in reserved.group(1).split(",")},
        )
        # The forbidden characters are one Haskell string literal, read as the
        # characters it denotes rather than as the escapes it is written with.
        forbidden = re.search(r'`elem` \("(.*?)" :: String\)', body.group(1))
        self.assertIsNotNone(forbidden)
        self.assertEqual(
            haskell_string_characters(forbidden.group(1)),
            service.PASS_UNSAFE_MISSION_CHARACTERS,
        )

    def test_the_admission_ceiling_matches(self):
        # Mirrored like everything else the controller copies: a ceiling raised
        # in the scheduler and not here would have the controller rejecting
        # every pass its own scheduler produced.
        scheduler = (
            REPO_ROOT / "src" / "Kanban" / "Mission" / "Scheduler.hs"
        ).read_text(encoding="utf-8")
        match = re.search(r"^missionAdmissionCeiling = (\d+)$", scheduler, re.MULTILINE)
        self.assertIsNotNone(match, "missionAdmissionCeiling is not declared")
        self.assertEqual(service.PASS_ADMISSION_CEILING, int(match.group(1)))

    def test_the_timestamp_form_matches_the_writer(self):
        # The writer renders both instants with `iso8601Show`, so the shape the
        # controller parses has to be the shape that function emits. Pinned
        # against the encoder rather than assumed, because a change to how the
        # report spells a time would otherwise make every pass unreadable.
        self.assertIn("iso8601Show", self.source)
        encoder = re.search(
            r"^encodeMissionPassReport report =\n((?:.*\n)+?)^  where", self.source, re.MULTILINE
        )
        self.assertIsNotNone(encoder)
        for field in ("started_at", "finished_at"):
            self.assertRegex(encoder.group(1), rf'"{field}" \.= stamp ')
        self.assertRegex(self.source, r"stamp = Text\.pack \. iso8601Show")

    def test_the_report_fields_match(self):
        encoder = re.search(
            r"^encodeMissionPassReport report =\n((?:.*\n)+?)^  where", self.source, re.MULTILINE
        )
        self.assertIsNotNone(encoder)
        fields = {match.group(1) for match in re.finditer(r'"([a-z_]+)" \.=', encoder.group(1))}
        self.assertEqual(service.PASS_FIELDS, fields)


# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------


class PollIntervalTests(unittest.TestCase):
    """The wait between passes, as a real positive number of seconds."""

    def test_a_positive_interval_is_taken(self):
        self.assertEqual(service.poll_interval("0.5"), 0.5)

    def test_a_non_finite_interval_is_refused(self):
        # `float()` accepts these and no range check is true of a NaN, so
        # `nan <= 0` is False and it passes. What it produces is not a long
        # wait but none at all: `Controller.sleep` computes `max(0.0, nan)`,
        # which is `0.0`, so an idle service would run passes back to back.
        for value in ("nan", "NaN", "inf", "-inf", "Infinity"):
            with self.subTest(interval=value):
                with self.assertRaises(argparse.ArgumentTypeError):
                    service.poll_interval(value)

    def test_a_nan_interval_would_not_have_waited(self):
        # The consequence, stated rather than assumed: this is why NaN is
        # refused at the boundary instead of being clamped later.
        self.assertEqual(max(0.0, float("nan")), 0.0)

    def test_zero_and_negative_and_unparseable_are_refused(self):
        for value in ("0", "-1", "soon"):
            with self.subTest(interval=value):
                with self.assertRaises(argparse.ArgumentTypeError):
                    service.poll_interval(value)


class LocationTests(unittest.TestCase):
    """Where this service's runtime lives, on each platform's terms."""

    def test_the_macos_root_is_the_application_support_tree(self):
        with mock.patch.object(service, "account_home", lambda: Path("/accounts/me")):
            with mock.patch.object(service.kanban_config, "is_macos", lambda: True):
                self.assertEqual(
                    service.service_root(),
                    Path("/accounts/me/Library/Application Support/kanban/mission-runner"),
                )
                self.assertEqual(
                    service.runtime_root(),
                    Path(
                        "/accounts/me/Library/Application Support/kanban/mission-runner/runtime"
                    ),
                )

    def test_an_absolute_xdg_data_home_selects_the_xdg_root(self):
        with mock.patch.object(service, "account_home", lambda: Path("/accounts/me")):
            with mock.patch.object(service.kanban_config, "is_macos", lambda: False):
                with mock.patch.dict(os.environ, {"XDG_DATA_HOME": "/data"}):
                    self.assertEqual(
                        service.service_root(), Path("/data/kanban/mission-runner")
                    )

    def test_an_unset_empty_or_relative_xdg_data_home_selects_the_home_spelling(self):
        # The drainer's absolute-only rule rather than issue-review's, so a
        # systemd unit and the paths that locate it read the environment the
        # same way.
        expected = Path("/accounts/me/.local/share/kanban/mission-runner")
        with mock.patch.object(service, "account_home", lambda: Path("/accounts/me")):
            with mock.patch.object(service.kanban_config, "is_macos", lambda: False):
                for value in (None, "", "relative/data"):
                    with self.subTest(xdg_data_home=value):
                        environment = dict(os.environ)
                        environment.pop("XDG_DATA_HOME", None)
                        if value is not None:
                            environment["XDG_DATA_HOME"] = value
                        with mock.patch.dict(os.environ, environment, clear=True):
                            self.assertEqual(service.service_root(), expected)

    def test_the_lock_is_named_by_the_identity_rather_than_the_checkout(self):
        with mock.patch.object(service, "account_home", lambda: Path("/accounts/me")):
            with mock.patch.object(service.kanban_config, "is_macos", lambda: True):
                first = service.job_for_identity(Path("/one"), "acme/widgets")
                second = service.job_for_identity(Path("/two"), "acme/widgets")
                self.assertEqual(first.lock_path, second.lock_path)
                self.assertEqual(first.runtime_dir, second.runtime_dir)
                other = service.job_for_identity(Path("/one"), "acme/other")
                self.assertNotEqual(first.lock_path, other.lock_path)

    def test_the_slug_is_injective_over_separator_heavy_identities(self):
        identities = ["a-b/c.d", "a/b-c.d", "a.b/c-d", "a--b/c"]
        slugs = [service.repository_slug(identity) for identity in identities]
        self.assertEqual(len(set(slugs)), len(identities))
        for slug in slugs:
            self.assertRegex(slug, r"\A[A-Za-z0-9_.-]+\Z")


# ---------------------------------------------------------------------------
# The report decoder
# ---------------------------------------------------------------------------


class PassReportTests(unittest.TestCase):
    """What a pass has to say before this controller will act on it.

    Requirement 9 in one table. Each case below is a document a supervisor
    might otherwise read as a healthy quiet repository, and none of them may
    become one.
    """

    def test_a_well_formed_idle_pass_is_accepted(self):
        document = pass_document()
        self.assertEqual(service.parse_pass_report(json.dumps(document), 0), document)
        self.assertEqual(service.pass_state(document), service.STATE_IDLE)

    def test_an_advancing_pass_reads_as_running(self):
        document = pass_document(admitted=[admitted_entry()])
        self.assertEqual(service.pass_state(document), service.STATE_RUNNING)

    def test_a_waiting_mission_wins_over_an_idle_pass(self):
        document = pass_document(attention=[attention_entry()])
        self.assertEqual(service.pass_state(document), service.STATE_WAITING)

    def test_every_unusable_report_is_refused(self):
        cases = {
            "absent": ("", 0),
            "blank": ("   \n", 0),
            "truncated": ('{"schema":"kanban-mission', 0),
            "not an object": ("[]", 0),
            "unknown schema": (
                json.dumps({**pass_document(), "schema": "something-else"}),
                0,
            ),
            "unknown version": (json.dumps({**pass_document(), "version": 2}), 0),
            "string version": (json.dumps({**pass_document(), "version": "1"}), 0),
            "missing field": (
                json.dumps({k: v for k, v in pass_document().items() if k != "detail"}),
                0,
            ),
            "extra field": (json.dumps({**pass_document(), "surprise": 1}), 0),
            "no repository": (json.dumps({**pass_document(), "repository": ""}), 0),
            "unknown termination": (
                json.dumps({**pass_document(), "termination": "nearly"}),
                0,
            ),
            "self-contradicting exit code": (
                json.dumps(pass_document(exit_code=7)),
                0,
            ),
            "contradicting the child's status": (json.dumps(pass_document()), 1),
            "unknown disposition": (
                json.dumps(
                    pass_document(admitted=[admitted_entry(disposition="nearly")])
                ),
                0,
            ),
            "failed mission under a completed pass": (
                json.dumps(pass_document(admitted=[admitted_entry(disposition="failed")])),
                0,
            ),
            "refused pass naming admitted missions": (
                json.dumps(pass_document(termination="refused", admitted=[admitted_entry()])),
                2,
            ),
            "admitted entry with the wrong fields": (
                json.dumps(pass_document(admitted=[{"mission": "mission-a"}])),
                0,
            ),
            "unknown notification state": (
                json.dumps(pass_document(attention=[attention_entry(state="nearly")])),
                0,
            ),
            "attention entry with the wrong fields": (
                json.dumps(pass_document(attention=[{"mission": "mission-a"}])),
                0,
            ),
            "attention naming no identity": (
                json.dumps(
                    pass_document(attention=[{**attention_entry(), "attention_id": ""}])
                ),
                0,
            ),
            # A Boolean is an `int` in Python and `True == 1`, so an exit status
            # checked with `==` alone agrees with two of the three terminations.
            "boolean exit code": (
                json.dumps({**pass_document(termination="completed"), "exit_code": False}),
                0,
            ),
            "boolean exit code on a failed pass": (
                json.dumps(
                    {
                        **pass_document(
                            termination="failed",
                            admitted=[admitted_entry(disposition="failed")],
                        ),
                        "exit_code": True,
                    }
                ),
                1,
            ),
            "admitted detail that is not text": (
                json.dumps(pass_document(admitted=[{**admitted_entry(), "detail": 7}])),
                0,
            ),
            "attention detail that is neither absent nor text": (
                json.dumps(pass_document(attention=[{**attention_entry(), "detail": 7}])),
                0,
            ),
            # The target is reproduced into the status document a dashboard
            # renders, so every way it can be malformed is refused here rather
            # than passed through.
            "target that is not an object": (
                json.dumps(pass_document(attention=[{**attention_entry(), "targets": "issue#844"}])),
                0,
            ),
            "target with the wrong fields": (
                json.dumps(
                    pass_document(
                        attention=[{**attention_entry(), "targets": [{"kind": "issue"}]}]
                    )
                ),
                0,
            ),
            "target with an extra field": (
                json.dumps(
                    pass_document(
                        attention=[
                            {
                                **attention_entry(),
                                "targets": [{"kind": "issue", "number": 844, "title": "no"}],
                            }
                        ]
                    )
                ),
                0,
            ),
            "unknown target kind": (
                json.dumps(
                    pass_document(
                        attention=[
                            {**attention_entry(), "targets": [{"kind": "discussion", "number": 844}]}
                        ]
                    )
                ),
                0,
            ),
            "target number that is text": (
                json.dumps(
                    pass_document(
                        attention=[
                            {**attention_entry(), "targets": [{"kind": "issue", "number": "844"}]}
                        ]
                    )
                ),
                0,
            ),
            "target number that is a Boolean": (
                json.dumps(
                    pass_document(
                        attention=[
                            {**attention_entry(), "targets": [{"kind": "issue", "number": True}]}
                        ]
                    )
                ),
                0,
            ),
            # The ceiling is a contract about what a pass may do. Three
            # otherwise valid admitted missions describe a scheduler this
            # controller was not built to supervise.
            "more admitted missions than one pass may admit": (
                json.dumps(
                    pass_document(
                        admitted=[
                            admitted_entry(mission="mission-a"),
                            admitted_entry(mission="mission-b"),
                            admitted_entry(mission="mission-c"),
                        ]
                    )
                ),
                0,
            ),
            # `unresolved` means the writer could not say which items an
            # episode is about, which it treats as indeterminate state and
            # terminates `failed` for. A completed pass carrying one is two
            # halves of a report contradicting each other.
            "unresolved attention under a completed pass": (
                json.dumps(pass_document(attention=[attention_entry(state="unresolved")])),
                0,
            ),
            "unresolved attention under a refused pass": (
                json.dumps(pass_document(termination="refused", attention=[attention_entry(state="unresolved")])),
                2,
            ),
            "a mission admitted twice": (
                json.dumps(
                    pass_document(
                        admitted=[admitted_entry(mission="mission-a"), admitted_entry(mission="mission-a")]
                    )
                ),
                0,
            ),
            "an episode named twice": (
                json.dumps(pass_document(attention=[attention_entry(), attention_entry()])),
                0,
            ),
            "attention qualified for another repository": (
                json.dumps(
                    pass_document(
                        attention=[
                            {
                                **attention_entry(),
                                "attention_id": "someone/else#mission-a@2026-09-11T00:00:00Z",
                            }
                        ]
                    )
                ),
                0,
            ),
            "attention qualified for another mission": (
                json.dumps(
                    pass_document(
                        attention=[
                            {
                                **attention_entry(),
                                "attention_id": "acme/widgets#mission-elsewhere@2026-09-11T00:00:00Z",
                            }
                        ]
                    )
                ),
                0,
            ),
            "a started_at that is not a time": (
                json.dumps({**pass_document(), "started_at": "not-a-time"}),
                0,
            ),
            "a finished_at that is not a time": (
                json.dumps({**pass_document(), "finished_at": ""}),
                0,
            ),
            "a timestamp with no zone": (
                json.dumps({**pass_document(), "started_at": "2026-09-11T00:00:00"}),
                0,
            ),
            # Python's `\d` matches every Unicode decimal digit, and `int()`
            # converts them, so a shape check written with it accepts an
            # instant no Haskell writer can emit.
            # A JSON array or object is unhashable, so a membership test asked
            # of one raises TypeError rather than answering — which escapes
            # PassFailure and is recorded as an unexpected controller failure
            # instead of a malformed report.
            "a termination that is a list": (
                json.dumps({**pass_document(), "termination": []}),
                0,
            ),
            "a termination that is an object": (
                json.dumps({**pass_document(), "termination": {}}),
                0,
            ),
            "a disposition that is a list": (
                json.dumps(pass_document(admitted=[{**admitted_entry(), "disposition": []}])),
                0,
            ),
            "a notification state that is an object": (
                json.dumps(pass_document(attention=[{**attention_entry(), "notification": {}}])),
                0,
            ),
            "a target kind that is a list": (
                json.dumps(
                    pass_document(
                        attention=[
                            {**attention_entry(), "targets": [{"kind": [], "number": 844}]}
                        ]
                    )
                ),
                0,
            ),
            # `iso8601Show` strips trailing zeros and renders at most
            # picosecond precision, so neither of these is a spelling it can
            # produce — and an attention identity ends in one, so two
            # spellings of one moment would be two episodes.
            "a fraction with a trailing zero": (
                json.dumps({**pass_document(), "started_at": "2026-09-11T00:00:00.10Z"}),
                0,
            ),
            "a fraction of only zeros": (
                json.dumps({**pass_document(), "started_at": "2026-09-11T00:00:00.0Z"}),
                0,
            ),
            "a fraction beyond picosecond precision": (
                json.dumps({**pass_document(), "started_at": "2026-09-11T00:00:00.1234567890123Z"}),
                0,
            ),
            "an empty fraction": (
                json.dumps({**pass_document(), "started_at": "2026-09-11T00:00:00.Z"}),
                0,
            ),
            # The refusal returns before the inventory is read, so a refused
            # pass cannot have observed anything.
            # A mission identifier is a single plain path component in the
            # store, so a scheduler cannot name one this rejects — every path
            # it derives goes through that same check.
            "an admitted mission that is not a plain component": (
                json.dumps(pass_document(admitted=[admitted_entry(mission="../x")])),
                0,
            ),
            "an admitted mission that is a separator": (
                json.dumps(pass_document(admitted=[admitted_entry(mission="a/b")])),
                0,
            ),
            "an admitted mission that is the current directory": (
                json.dumps(pass_document(admitted=[admitted_entry(mission=".")])),
                0,
            ),
            "an admitted mission carrying a NUL": (
                json.dumps(pass_document(admitted=[admitted_entry(mission="a\u0000b")])),
                0,
            ),
            "an attention mission that is not a plain component": (
                json.dumps(
                    pass_document(
                        attention=[
                            {
                                **attention_entry(),
                                "mission": "../x",
                                "attention_id": "acme/widgets#../x@2026-09-11T00:00:00Z",
                            }
                        ]
                    )
                ),
                0,
            ),
            "a refused pass naming attention": (
                json.dumps(pass_document(termination="refused", attention=[attention_entry()])),
                2,
            ),
            "a timestamp in non-ASCII digits": (
                json.dumps({**pass_document(), "started_at": "\u0662\u0660\u0662\u0666-\u0660\u0669-\u0661\u0661T\u0660\u0660:\u0660\u0660:\u0660\u0660Z"}),
                0,
            ),
            "an attention raised-at in non-ASCII digits": (
                json.dumps(
                    pass_document(
                        attention=[
                            {
                                **attention_entry(),
                                "attention_id": "acme/widgets#mission-a@\u0662\u0660\u0662\u0666-\u0660\u0669-\u0661\u0661T\u0660\u0660:\u0660\u0660:\u0660\u0660Z",
                            }
                        ]
                    )
                ),
                0,
            ),
            "a timestamp that names no real instant": (
                json.dumps({**pass_document(), "started_at": "2026-13-45T99:99:99Z"}),
                0,
            ),
            # The tail of an attention identity is the moment the episode
            # began, and it is what makes two visits to `waiting_input` two
            # episodes rather than one.
            "attention with an empty raised-at": (
                json.dumps(
                    pass_document(
                        attention=[{**attention_entry(), "attention_id": "acme/widgets#mission-a@"}]
                    )
                ),
                0,
            ),
            "attention with a malformed raised-at": (
                json.dumps(
                    pass_document(
                        attention=[
                            {**attention_entry(), "attention_id": "acme/widgets#mission-a@whenever"}
                        ]
                    )
                ),
                0,
            ),
            "target number that is not positive": (
                json.dumps(
                    pass_document(
                        attention=[
                            {**attention_entry(), "targets": [{"kind": "issue", "number": 0}]}
                        ]
                    )
                ),
                0,
            ),
        }
        for label, (stdout, returncode) in cases.items():
            with self.subTest(report=label):
                with self.assertRaises(service.PassFailure):
                    service.parse_pass_report(stdout, returncode)

    def test_a_failed_pass_is_accepted_and_then_acted_on_by_the_controller(self):
        # The decoder's job ends at "this is a well-formed failed pass"; what
        # the controller then does with it is the fixture's.
        document = pass_document(
            termination="failed",
            admitted=[admitted_entry(disposition="failed", detail="the child died")],
            detail="1 failed",
        )
        self.assertEqual(service.parse_pass_report(json.dumps(document), 1), document)

    def test_no_targets_one_target_and_several_are_all_accepted(self):
        # The negative control for the target cases above: refusing everything
        # would pass that table while accepting no real report at all. The
        # several-target case is the ordinary one for a mission whose selector
        # matched more than one item.
        for targets in (
            [],
            [{"kind": "issue", "number": 844}],
            [{"kind": "pull_request", "number": 12}],
            [{"kind": "issue", "number": 844}, {"kind": "issue", "number": 845}],
        ):
            with self.subTest(targets=targets):
                document = pass_document(
                    attention=[{**attention_entry(), "targets": targets}]
                )
                self.assertEqual(service.parse_pass_report(json.dumps(document), 0), document)

    def test_no_malformed_json_value_escapes_as_a_raw_exception(self):
        # The property behind the cases above, over every field this decoder
        # looks up in a closed vocabulary: whatever a document puts there, the
        # answer is a PassFailure the controller classifies, never an exception
        # it reports as its own failure.
        for field, replacement in (
            ("termination", [1]),
            ("exit_code", {}),
            ("admitted", {}),
            ("attention", "not a list"),
            ("repository", []),
            ("detail", []),
            ("started_at", {}),
        ):
            with self.subTest(field=field):
                document = {**pass_document(), field: replacement}
                with self.assertRaises(service.PassFailure):
                    service.parse_pass_report(json.dumps(document), 0)

    def test_the_producers_timestamp_forms_are_accepted(self):
        # The control for the temporal cases above: `iso8601Show` emits a
        # fractional part only when there is one, so both shapes have to
        # decode or the controller would refuse its own scheduler's reports.
        for stamp in (
            "2026-09-11T00:00:00Z",
            "2026-09-11T00:00:00.1Z",
            "2026-09-11T08:24:02.123456Z",
            "2026-09-11T00:00:00.000000000001Z",
            "2026-09-11T00:00:00.123456789012Z",
        ):
            with self.subTest(stamp=stamp):
                document = pass_document(
                    attention=[
                        {
                            **attention_entry(),
                            "attention_id": f"acme/widgets#mission-a@{stamp}",
                        }
                    ]
                )
                document["started_at"] = stamp
                document["finished_at"] = stamp
                self.assertEqual(service.parse_pass_report(json.dumps(document), 0), document)

    def test_two_distinct_missions_and_episodes_are_accepted(self):
        # The negative control for the duplicate cases above: rejecting every
        # report with two entries would pass them while accepting no real
        # two-mission pass.
        document = pass_document(
            admitted=[admitted_entry(mission="mission-a"), admitted_entry(mission="mission-b")],
            attention=[attention_entry(mission="mission-a"), attention_entry(mission="mission-b")],
        )
        self.assertEqual(service.parse_pass_report(json.dumps(document), 0), document)

    def test_the_admission_ceiling_is_accepted_up_to_its_limit(self):
        # The negative control for the over-capacity case: rejecting every
        # multi-mission report would pass that entry while accepting no real
        # advancing pass at all.
        document = pass_document(
            admitted=[admitted_entry(mission="mission-a"), admitted_entry(mission="mission-b")]
        )
        self.assertEqual(service.parse_pass_report(json.dumps(document), 0), document)

    def test_unresolved_attention_is_accepted_under_a_failed_pass(self):
        # And the control for the unresolved cases: the shape the writer really
        # produces has to decode.
        document = pass_document(
            termination="failed",
            attention=[attention_entry(state="unresolved")],
            detail="1 waiting on a person; its specification will not decode",
        )
        self.assertEqual(service.parse_pass_report(json.dumps(document), 1), document)

    def test_a_pass_level_failure_with_nothing_admitted_is_accepted(self):
        # The exact shape `runMissionSchedulerMode` writes when it cannot even
        # prepare its scratch directory: the pass failed, and no mission is to
        # blame. A controller that required a failed mission beside a failed
        # pass would call its own writer malformed and drop the one report that
        # said what went wrong.
        document = pass_document(
            termination="failed",
            detail="this pass could not prepare its scratch directory: ...",
        )
        self.assertEqual(service.parse_pass_report(json.dumps(document), 1), document)

    def test_a_refused_pass_is_accepted_with_nothing_admitted(self):
        document = pass_document(termination="refused", detail="nothing to run")
        self.assertEqual(service.parse_pass_report(json.dumps(document), 2), document)


# ---------------------------------------------------------------------------
# The fixture
# ---------------------------------------------------------------------------


class MissionRunnerFixture(unittest.TestCase):
    """A temporary account root, a temporary checkout, and a fake scheduler."""

    identity = "acme/widgets"
    remote_url = "git@github.com:acme/widgets.git"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        # What `account_home` answers for every test in this fixture. Distinct
        # from the redirected `$HOME` below so that a path which quietly went
        # back to reading the environment would land somewhere visible rather
        # than somewhere indistinguishable.
        self.account = self.root / "account"
        self.account.mkdir()
        patched = mock.patch.object(service, "account_home", lambda: self.account)
        patched.start()
        self.addCleanup(patched.stop)
        self.wrapper = self.root / "run_controller.py"
        self.wrapper.write_text(CONTROLLER_WRAPPER, encoding="utf-8")
        # A checkout whose name carries a space, so every path this fixture
        # hands the controller exercises requirement 5's "without shell
        # reinterpretation".
        self.repo = self.root / "a checkout"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        subprocess.run(
            ["git", "remote", "add", "origin", self.remote_url], cwd=self.repo, check=True
        )
        self.scheduler = self.root / "fake kanban"
        self.scheduler.write_text(FAKE_SCHEDULER, encoding="utf-8")
        self.scheduler.chmod(0o700)
        self.calls = self.root / "calls.jsonl"
        self.plan = self.root / "plan.json"
        self.write_plan({"report": {"document": pass_document()}})
        self.processes = []
        self.addCleanup(self.reap)

    def reap(self):
        for child in self.processes:
            if child.poll() is None:
                with contextlib_suppress():
                    os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=10)

    def write_plan(self, plan):
        self.plan.write_text(json.dumps(plan), encoding="utf-8")

    def recorded(self):
        if not self.calls.exists():
            return []
        return [
            json.loads(line)
            for line in self.calls.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]

    def job(self, *, config_path=None):
        return service.job_for_identity(self.repo, self.identity, config_path=config_path)

    def environment(self, **extra):
        """The environment a managed run would be handed.

        Deliberately not this process's: a service manager starts a job with
        almost nothing, and the XDG roots that decide where a mission store
        lives have to reach the pass from whatever this controller resolved
        rather than from an inherited shell.
        """
        environment = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(self.home),
            "FAKE_SCHEDULER_CALLS": str(self.calls),
            "FAKE_SCHEDULER_PLAN": str(self.plan),
        }
        environment.update(extra)
        return environment

    def start_controller(self, *arguments, environment=None):
        child = subprocess.Popen(
            [
                sys.executable,
                str(self.wrapper),
                str(CONTROLLER.parent),
                str(self.account),
                "run",
                "--path",
                str(self.repo),
                "--kanban",
                str(self.scheduler),
                "--interval",
                "0.05",
                *arguments,
            ],
            env=environment or self.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        self.processes.append(child)
        return child

    def run_controller(self, *arguments, environment=None, timeout=40):
        child = self.start_controller(*arguments, environment=environment)
        stdout, stderr = child.communicate(timeout=timeout)
        return child.returncode, stdout, stderr

    def status(self):
        return service.status_snapshot(self.job())


class contextlib_suppress:
    """`contextlib.suppress(OSError)` without the import, for cleanup."""

    def __enter__(self):
        return self

    def __exit__(self, kind, value, trace):
        return isinstance(value, OSError)


# ---------------------------------------------------------------------------
# Identity and refusals
# ---------------------------------------------------------------------------


class IdentityTests(MissionRunnerFixture):
    def test_the_identity_comes_from_the_configured_remote(self):
        job = service.resolve_job(self.repo)
        self.assertEqual(job.identity, self.identity)
        self.assertEqual(job.runtime_dir, service.runtime_root() / job.slug)

    def test_a_checkout_with_no_github_remote_is_refused(self):
        other = self.root / "not-a-clone"
        other.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=other, check=True)
        with self.assertRaises(service.ServiceError) as raised:
            service.resolve_job(other)
        self.assertIn(str(other), str(raised.exception))

    def test_another_repository_is_refused_by_name(self):
        job = self.job()
        service.require_requested_identity(job, "acme/widgets")
        with self.assertRaises(service.ServiceError) as raised:
            service.require_requested_identity(job, "acme/other")
        self.assertIn("acme/other", str(raised.exception))

    def test_an_absent_executable_is_a_named_refusal(self):
        with mock.patch.dict(os.environ, {"PATH": str(self.root / "empty")}):
            with self.assertRaises(service.ServiceError) as raised:
                service.resolve_kanban(None)
        self.assertIn("kanban", str(raised.exception))

    def test_a_non_executable_path_is_a_named_refusal(self):
        plain = self.root / "not-executable"
        plain.write_text("", encoding="utf-8")
        with self.assertRaises(service.ServiceError) as raised:
            service.resolve_kanban(str(plain))
        self.assertIn(str(plain), str(raised.exception))

    def test_an_explicit_executable_is_taken(self):
        # Compared against the resolved path: what is stored is absolute and
        # symlink-free, because the checkout a pass runs from is not the
        # directory the controller was started in.
        self.assertEqual(service.resolve_kanban(str(self.scheduler)), self.scheduler.resolve())

    def test_a_relative_executable_is_resolved_before_it_is_stored(self):
        # A pass runs with the *checkout* as its working directory, so a
        # relative path is checked against one directory and launched from
        # another. Storing the relative spelling would pass every check at
        # startup and then fail every pass.
        previous = os.getcwd()
        os.chdir(self.root)
        try:
            resolved = service.resolve_kanban("./fake kanban")
        finally:
            os.chdir(previous)
        self.assertTrue(resolved.is_absolute())
        self.assertEqual(resolved, self.scheduler.resolve())

    def test_a_relative_executable_from_path_is_resolved_too(self):
        # `shutil.which` returns a relative path for a relative PATH entry, so
        # the same hazard reaches a controller that named no executable at all.
        previous = os.getcwd()
        os.chdir(self.root)
        try:
            with mock.patch.object(service.shutil, "which", lambda _: "./fake kanban"):
                resolved = service.resolve_kanban(None)
        finally:
            os.chdir(previous)
        self.assertTrue(resolved.is_absolute())
        self.assertEqual(resolved, self.scheduler.resolve())


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------


class LifecycleTests(MissionRunnerFixture):
    def test_a_pass_runs_in_the_checkout_with_the_repository_and_no_terminal(self):
        # Requirement 8's identity inputs and requirement 5's child contract,
        # observed from what the scheduler was actually handed.
        status, _stdout, stderr = self.run_controller("--passes", "1")
        self.assertEqual(status, 0, stderr)
        calls = self.recorded()
        self.assertEqual(len(calls), 1)
        call = calls[0]
        self.assertEqual(call["argv"][0], service.SCHEDULER_FLAG)
        self.assertIn("--repo", call["argv"])
        self.assertEqual(call["argv"][call["argv"].index("--repo") + 1], self.identity)
        self.assertEqual(Path(call["cwd"]).resolve(), self.repo.resolve())
        self.assertFalse(call["stdin_is_a_terminal"])

    def test_a_relative_executable_still_runs_from_a_different_checkout(self):
        # The end of the same thread: the controller is started from a
        # directory that is not the checkout and names its executable
        # relatively, and the pass still runs.
        child = subprocess.Popen(
            [
                sys.executable,
                str(self.wrapper),
                str(CONTROLLER.parent),
                str(self.account),
                "run",
                "--path",
                str(self.repo),
                "--kanban",
                "./fake kanban",
                "--interval",
                "0.05",
                "--passes",
                "1",
            ],
            cwd=str(self.root),
            env=self.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        self.processes.append(child)
        _stdout, stderr = child.communicate(timeout=40)
        self.assertEqual(child.returncode, 0, stderr)
        self.assertEqual(len(self.recorded()), 1)

    def test_a_configured_path_reaches_every_pass_absolutely(self):
        configuration = self.root / "a config.toml"
        configuration.write_text("cache = true\n", encoding="utf-8")
        status, _stdout, stderr = self.run_controller(
            "--passes", "1", "--config", str(configuration)
        )
        self.assertEqual(status, 0, stderr)
        argv = self.recorded()[0]["argv"]
        self.assertIn("--config", argv)
        recorded = argv[argv.index("--config") + 1]
        self.assertTrue(Path(recorded).is_absolute())
        self.assertEqual(Path(recorded), configuration.resolve())

    def test_the_usable_xdg_context_reaches_a_pass_from_an_empty_manager_environment(self):
        # The scheduler resolves the mission store from the XDG roots, so a
        # manager that starts this controller with almost nothing must not
        # leave the pass resolving a different store than the runtime describes.
        data_home = self.root / "data"
        state_home = self.root / "state"
        environment = self.environment(
            XDG_DATA_HOME=str(data_home), XDG_STATE_HOME=str(state_home)
        )
        status, _stdout, stderr = self.run_controller("--passes", "1", environment=environment)
        self.assertEqual(status, 0, stderr)
        call = self.recorded()[0]
        self.assertEqual(call["xdg_data_home"], str(data_home))
        self.assertEqual(call["xdg_state_home"], str(state_home))

    def test_an_idle_pass_leaves_an_idle_status(self):
        status, _stdout, stderr = self.run_controller("--passes", "1")
        self.assertEqual(status, 0, stderr)
        snapshot = self.status()
        self.assertEqual(snapshot["state"], service.STATE_STOPPED)
        self.assertEqual(snapshot["passes"], 1)
        self.assertEqual(snapshot["last_pass"]["termination"], "completed")

    def test_a_waiting_mission_is_reported_through_the_status_document(self):
        self.write_plan(
            {
                "reports": [
                    {"document": pass_document(attention=[attention_entry()])},
                ]
            }
        )
        status, _stdout, stderr = self.run_controller("--passes", "1")
        self.assertEqual(status, 0, stderr)
        snapshot = self.status()
        self.assertEqual(len(snapshot["attention"]), 1)
        self.assertEqual(snapshot["attention"][0]["mission"], "mission-a")

    def test_a_second_wrapper_refuses_and_starts_no_scheduler(self):
        # Requirement 11. The first run is held open by a pass that will not
        # finish, so the second one meets a live holder rather than a race.
        self.write_plan({"report": {"document": pass_document(), "hold_seconds": 30}})
        first = self.start_controller()
        wait_until(lambda: self.recorded(), message="the first pass to start")
        before = len(self.recorded())
        status, _stdout, stderr = self.run_controller(timeout=30)
        self.assertEqual(status, 1)
        self.assertIn("already running", stderr)
        self.assertEqual(len(self.recorded()), before)
        os.killpg(first.pid, signal.SIGTERM)
        first.wait(timeout=30)

    def test_a_stop_ends_the_run_without_recording_a_failure(self):
        self.write_plan({"report": {"document": pass_document(), "hold_seconds": 30}})
        child = self.start_controller()
        wait_until(lambda: self.recorded(), message="a pass to start")
        os.killpg(child.pid, signal.SIGTERM)
        child.wait(timeout=30)
        self.assertEqual(child.returncode, 0)
        snapshot = self.status()
        self.assertEqual(snapshot["state"], service.STATE_STOPPED)
        self.assertEqual(snapshot["open_incidents"], [])

    def test_stopping_leaves_no_mission_child_of_the_active_pass_running(self):
        # Requirement 11's containment, staged against a mission child that
        # ignores SIGTERM: what this proves is the controller's escalation
        # rather than the child's cooperation.
        marker = self.root / "mission-child.pid"
        self.write_plan(
            {
                "mission_child": str(marker),
                "report": {"document": pass_document(), "hold_seconds": 60},
            }
        )
        child = self.start_controller()
        wait_until(marker.exists, message="the mission child to register itself")
        mission_pid = int(marker.read_text(encoding="utf-8"))
        self.addCleanup(lambda: process_gone(mission_pid) or os.kill(mission_pid, signal.SIGKILL))
        os.killpg(child.pid, signal.SIGTERM)
        child.wait(timeout=40)
        wait_until(
            lambda: process_gone(mission_pid),
            message="the mission child to be ended by the stop",
        )


# ---------------------------------------------------------------------------
# Failures
# ---------------------------------------------------------------------------


class FailureTests(MissionRunnerFixture):
    def assert_incident(self, kind):
        snapshot = self.status()
        self.assertEqual(snapshot["state"], service.STATE_FAILED)
        self.assertEqual(len(snapshot["open_incidents"]), 1)
        self.assertEqual(snapshot["open_incidents"][0]["kind"], kind)
        return snapshot["open_incidents"][0]

    def test_a_failed_pass_opens_an_incident_and_ends_the_run(self):
        self.write_plan(
            {
                "report": {
                    "document": pass_document(
                        termination="failed",
                        admitted=[admitted_entry(disposition="failed", detail="the child died")],
                        detail="1 failed",
                    ),
                    "status": 1,
                    "stderr": "the scheduler said this",
                }
            }
        )
        status, _stdout, _stderr = self.run_controller()
        self.assertEqual(status, 1)
        incident = self.assert_incident(service.PASS_INCIDENT_KIND)
        self.assertIn("1 failed", incident["summary"])
        self.assertIn("the scheduler said this", incident["detail"])

    def test_a_refused_pass_opens_an_incident_rather_than_looking_quiet(self):
        self.write_plan(
            {
                "report": {
                    "document": pass_document(
                        termination="refused", detail="nothing to run"
                    ),
                    "status": 2,
                }
            }
        )
        status, _stdout, _stderr = self.run_controller()
        self.assertEqual(status, 1)
        incident = self.assert_incident(service.PASS_INCIDENT_KIND)
        self.assertIn("nothing to run", incident["summary"])

    def test_a_pass_level_failure_is_retained_and_opens_an_incident(self):
        # The end of the same thread as the decoder's unit case: the scheduler
        # can fail before it admits anything, and the wrapper has to keep that
        # report rather than reject it as malformed. `last_pass` is what proves
        # it was kept, since an incident is opened for a rejected report too.
        self.write_plan(
            {
                "report": {
                    "document": pass_document(
                        termination="failed",
                        detail="this pass could not prepare its scratch directory: denied",
                    ),
                    "status": 1,
                }
            }
        )
        status, _stdout, _stderr = self.run_controller()
        self.assertEqual(status, 1)
        incident = self.assert_incident(service.PASS_INCIDENT_KIND)
        self.assertIn("scratch directory", incident["summary"])
        snapshot = self.status()
        self.assertIsNotNone(snapshot["last_pass"])
        self.assertEqual(snapshot["last_pass"]["termination"], "failed")
        self.assertEqual(snapshot["last_pass"]["admitted"], [])

    def test_an_unreadable_report_is_a_failure_rather_than_an_idle_pass(self):
        for label, report in (
            ("no output", {"raw": "", "status": 0}),
            ("truncated", {"raw": '{"schema":"kanban-mission', "status": 0}),
            (
                "another repository",
                {"document": pass_document(repository="acme/other"), "status": 0},
            ),
            (
                "contradicting the exit status",
                {"document": pass_document(), "status": 1},
            ),
        ):
            with self.subTest(report=label):
                self.calls.unlink(missing_ok=True)
                for path in sorted(self.job().incident_dir.glob("*.json")):
                    path.unlink()
                self.write_plan({"report": report})
                status, _stdout, _stderr = self.run_controller()
                self.assertEqual(status, 1)
                self.assert_incident(service.PASS_INCIDENT_KIND)

    def test_an_incident_can_be_acknowledged_without_changing_the_service(self):
        self.write_plan({"report": {"raw": "", "status": 0}})
        self.run_controller()
        incident = self.assert_incident(service.PASS_INCIDENT_KIND)
        resolved = service.acknowledge_incident(self.job(), incident["incident_id"], "seen")
        self.assertEqual(resolved["status"], "resolved")
        self.assertEqual(self.status()["open_incidents"], [])
        # And the state it left behind is still the failure it was.
        self.assertEqual(self.status()["state"], service.STATE_FAILED)

    def test_acknowledging_a_missing_incident_is_refused(self):
        with self.assertRaises(service.ServiceError):
            service.acknowledge_incident(self.job(), "incident-20260911T000000Z-1", None)


# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------


class StatusTests(MissionRunnerFixture):
    def test_an_absent_document_reads_as_unknown_rather_than_stopped(self):
        snapshot = self.status()
        self.assertEqual(snapshot["state"], service.STATE_UNKNOWN)
        self.assertIn("no status document", snapshot["reason"])

    def test_an_unhashable_state_reads_as_unknown_rather_than_crashing(self):
        # `state in STATUS_STATES` raises on a list or an object rather than
        # answering, and this is the read-only diagnostic somebody reaches for
        # when the runtime is already in a bad state: it has to report rather
        # than crash.
        job = self.job()
        for spelling in ("[]", "{}", "7", "null"):
            with self.subTest(state=spelling):
                job.status_path.parent.mkdir(parents=True, exist_ok=True)
                job.status_path.write_text(
                    '{"schema": "%s", "version": %d, "repository": "%s", "state": %s, "runner_pid": %d}'
                    % (service.STATUS_SCHEMA, service.STATUS_VERSION, self.identity, spelling, os.getpid()),
                    encoding="utf-8",
                )
                snapshot = service.status_snapshot(job)
                self.assertEqual(snapshot["state"], service.STATE_UNKNOWN)
                self.assertIn("unknown state", snapshot["reason"])

    def test_every_unbelievable_document_reads_as_unknown_with_a_reason(self):
        job = self.job()
        base = {
            "schema": service.STATUS_SCHEMA,
            "version": service.STATUS_VERSION,
            "state": service.STATE_IDLE,
            "repository": self.identity,
            "runner_pid": os.getpid(),
        }
        cases = {
            "unreadable": "{",
            "another schema": json.dumps({**base, "schema": "something-else"}),
            "another version": json.dumps({**base, "version": 2}),
            "another repository": json.dumps({**base, "repository": "acme/other"}),
            "an unknown state": json.dumps({**base, "state": "nearly"}),
            "a dead runner": json.dumps({**base, "runner_pid": 2 ** 31 - 1}),
        }
        for label, contents in cases.items():
            with self.subTest(document=label):
                job.status_path.parent.mkdir(parents=True, exist_ok=True)
                job.status_path.write_text(contents, encoding="utf-8")
                snapshot = service.status_snapshot(job)
                self.assertEqual(snapshot["state"], service.STATE_UNKNOWN)
                self.assertTrue(snapshot["reason"])

    def test_status_repairs_nothing_it_reads(self):
        job = self.job()
        self.assertFalse(job.runtime_dir.exists())
        service.status_snapshot(job)
        self.assertFalse(job.runtime_dir.exists())

    def test_the_status_operation_reports_read_only(self):
        status = service.main(["status", "--path", str(self.repo), "--json"])
        self.assertEqual(status, 0)

    def test_a_live_state_under_a_running_runner_is_believed(self):
        job = self.job()
        job.status_path.parent.mkdir(parents=True, exist_ok=True)
        job.status_path.write_text(
            json.dumps(
                {
                    "schema": service.STATUS_SCHEMA,
                    "version": service.STATUS_VERSION,
                    "state": service.STATE_WAITING,
                    "repository": self.identity,
                    "repo": str(self.repo),
                    "runner_pid": os.getpid(),
                }
            ),
            encoding="utf-8",
        )
        snapshot = service.status_snapshot(job)
        self.assertEqual(snapshot["state"], service.STATE_WAITING)
        self.assertIsNone(snapshot["reason"])
        self.assertEqual(snapshot["runner_pid"], os.getpid())


# ---------------------------------------------------------------------------
# Concurrency
# ---------------------------------------------------------------------------


class ExclusionTests(MissionRunnerFixture):
    def test_only_one_run_lock_holder_wins_in_this_process(self):
        job = self.job()
        held = threading.Event()
        release = threading.Event()
        outcome = {}

        def hold():
            with service.run_lock(job):
                held.set()
                release.wait(20)

        holder = threading.Thread(target=hold)
        holder.start()
        self.addCleanup(holder.join)
        self.addCleanup(release.set)
        held.wait(20)
        # A second acquisition from another *process*, because `flock` is
        # per-open-file-description and two threads of one process would not
        # contend the way two runs do.
        contender = subprocess.run(
            [
                sys.executable,
                "-c",
                "import sys;"
                f"sys.path.insert(0, {str(CONTROLLER.parent)!r});"
                "import mission_runner_service as service;"
                "from pathlib import Path;"
                f"service.account_home = lambda: Path({str(self.account)!r});"
                f"job = service.job_for_identity(Path({str(self.repo)!r}), {self.identity!r});"
                "import contextlib\n"
                "try:\n"
                "    with service.run_lock(job):\n"
                "        print('acquired')\n"
                "except service.ServiceError as exc:\n"
                "    print('refused')\n",
            ],
            text=True,
            capture_output=True,
        )
        outcome["stdout"] = contender.stdout
        release.set()
        self.assertIn("refused", outcome["stdout"])


if __name__ == "__main__":
    unittest.main()
