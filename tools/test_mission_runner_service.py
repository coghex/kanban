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
#
# Two optional seams, both read from the environment so a fixture can reach a
# controller it runs as a separate process. `FIXTURE_SETTLE_SECONDS` shortens
# how long settling a recorded pass waits before it kills and before it gives
# up, so a stubborn survivor costs seconds rather than the service's own
# bounds. `FIXTURE_DRAIN_GRACE_SECONDS` and `FIXTURE_STOP_GRACE_SECONDS` do the
# same for how long a stop lets a pass finish its step and how long an
# escalation waits before it kills. `FIXTURE_DIE_AT` names a `Controller`
# method that kills the controller outright instead of running -- the death no
# cleanup runs after. `FIXTURE_STOP_AT` names one that the controller's own
# stop signal is delivered on entry to, before it does anything: a stop landing
# at exactly that step.
CONTROLLER_WRAPPER = '''#!/usr/bin/env python3
import os
import signal
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
account = Path(sys.argv[2])
del sys.argv[1:3]

import mission_runner_service as service

service.account_home = lambda: account
settle = os.environ.get("FIXTURE_SETTLE_SECONDS")
if settle:
    service.SETTLE_GRACE_SECONDS = float(settle)
    service.SETTLE_KILL_SECONDS = float(settle)
drain = os.environ.get("FIXTURE_DRAIN_GRACE_SECONDS")
if drain:
    service.DRAIN_GRACE_SECONDS = float(drain)
stop = os.environ.get("FIXTURE_STOP_GRACE_SECONDS")
if stop:
    service.STOP_GRACE_SECONDS = float(stop)
die_at = os.environ.get("FIXTURE_DIE_AT")
if die_at:
    def die(*_arguments, **_keywords):
        os.kill(os.getpid(), signal.SIGKILL)
    setattr(service.Controller, die_at, die)
stop_at = os.environ.get("FIXTURE_STOP_AT")
if stop_at:
    original = getattr(service.Controller, stop_at)
    def stop_then(self, *arguments, **keywords):
        os.kill(os.getpid(), signal.SIGTERM)
        return original(self, *arguments, **keywords)
    setattr(service.Controller, stop_at, stop_then)
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

# A `kanban --mission` child part-way through its step: it reports itself,
# works until the fixture releases it, and records that it finished. The
# default SIGTERM disposition is left alone, so a stop that cuts the step off
# ends it without a finish -- which is what leaves a real mission interrupted.
STEP = (
    "import os, sys, time\\n"
    "open(sys.argv[1], 'w').write(str(os.getpid()))\\n"
    "while not os.path.exists(sys.argv[2]):\\n"
    "    time.sleep(0.02)\\n"
    "open(sys.argv[3], 'w').write('finished')\\n"
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


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def main():
    plan = read_json(PLAN, {})
    index = len(recorded())
    # The dashboard's commands, consumed as a controller iteration consumes
    # them: whatever is queued when the pass begins, and nothing after.
    consumed = []
    requests = plan.get("requests_dir")
    if requests and os.path.isdir(requests):
        for name in sorted(os.listdir(requests)):
            os.unlink(os.path.join(requests, name))
            consumed.append(name)
    record(
        {
            "consumed": consumed,
            "argv": sys.argv[1:],
            "cwd": os.getcwd(),
            "stdin_is_a_terminal": sys.stdin.isatty(),
            "xdg_data_home": os.environ.get("XDG_DATA_HOME"),
            "xdg_state_home": os.environ.get("XDG_STATE_HOME"),
            "path": os.environ.get("PATH"),
            # Which of the processes a test named are still alive at the
            # moment this pass starts -- how a test proves a predecessor was
            # settled *before* the next pass, rather than at some point.
            "alive": [pid for pid in plan.get("report_alive") or [] if alive(pid)],
        }
    )
    worker_marker = plan.get("detached_worker")
    if worker_marker:
        # What a mission child hands agent work to: a process leading a
        # session of its own, which no settlement of the runner's chain may
        # reach. It writes to logs of its own rather than to the pass's
        # streams, so it holds none of them open behind the pass.
        subprocess.Popen(
            [sys.executable, "-c", STUBBORN, worker_marker],
            start_new_session=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        while not os.path.exists(worker_marker):
            time.sleep(0.01)
    child_marker = plan.get("mission_child")
    if child_marker:
        # A mission child in this pass's own process group, which is what the
        # controller's stop has to reach.
        subprocess.Popen([sys.executable, "-c", STUBBORN, child_marker])
        while not os.path.exists(child_marker):
            time.sleep(0.01)
    step = plan.get("step_child")
    if step:
        # Waited for, as a real pass waits for every mission child it starts.
        subprocess.Popen(
            [sys.executable, "-c", STEP, step["marker"], step["release"], step["done"]]
        ).wait()
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


def haskell_string_value(literal):
    """The string a Haskell string literal denotes.

    Read rather than compared as written: `"/\\\\\\NUL"` in the source is the
    three characters `/`, `\\` and NUL, and a test that compared the escapes
    would be pinning how the literal is spelled rather than what it says.
    """
    value = []
    index = 0
    while index < len(literal):
        if literal[index] != "\\":
            value.append(literal[index])
            index += 1
            continue
        if literal.startswith("\\NUL", index):
            value.append("\0")
            index += 4
        else:
            value.append(literal[index + 1])
            index += 2
    return "".join(value)


def haskell_string_characters(literal):
    """The set of characters a Haskell string literal denotes.

    One decoder, so a literal read for its characters and one read for its
    value cannot disagree about what an escape means.
    """
    return set(haskell_string_value(literal))


def wait_until(predicate, *, timeout=25.0, message="condition"):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.01)
    raise AssertionError(f"timed out waiting for {message}")


def force_stop(child):
    """Stop a controller twice, which is a forced stop: the first drains, and
    the second -- sent once the first has been published -- escalates."""
    os.killpg(child.pid, signal.SIGTERM)
    # Apart, so the two are not coalesced into one pending signal.
    time.sleep(0.5)
    os.killpg(child.pid, signal.SIGTERM)


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
    agents="counted",
    detail="nothing to do",
    exit_code=None,
):
    """One well-formed pass report, in the shape the scheduler writes.

    A pass that got as far as counting reports the count; a refused one
    looked at nothing and reports none.
    """
    if agents == "counted":
        agents = None if termination == "refused" else {"live": 0, "ceiling": 2}
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
        "agents": agents,
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


def unresolved_attention_entry(mission="mission-a"):
    """The shape the writer really emits when it could not read a mission's
    specification: no targets, because there was nothing to resolve them from,
    and a reason, because that is the only account of what went wrong."""
    return {
        **attention_entry(mission=mission, state="unresolved"),
        "targets": [],
        "detail": "its specification will not decode",
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

    def test_the_unresolved_repository_marker_matches(self):
        # Read as the characters it denotes rather than as the escape it is
        # written with: the Haskell source spells the NUL `\NUL`, and a copy
        # that compared those four characters would pass while the two sides
        # meant different strings.
        self.assertEqual(
            service.PASS_UNRESOLVED_REPOSITORY,
            haskell_string_value(self.declared("missionPassUnresolvedRepository")),
        )
        # The property the marker is for, asserted rather than assumed: a
        # repository identity cannot carry a NUL, so nothing real collides
        # with it.
        self.assertIn("\0", service.PASS_UNRESOLVED_REPOSITORY)

    def test_a_setup_failure_reports_a_failed_pass(self):
        # The termination a pass that ended before it began carries, held
        # against the constructor that builds it rather than against prose.
        # `refused` would be read by this controller as a precondition saying
        # no, which is a different thing from a pass that could not start.
        body = re.search(
            r"^missionPassSetupFailure repository now detail =\n((?:  .*\n)+)",
            self.source,
            re.MULTILINE,
        )
        self.assertIsNotNone(body, "missionPassSetupFailure is not declared")
        self.assertIn("missionPassTermination = MissionPassFailed", body.group(1))
        self.assertIn("missionPassAdmitted = []", body.group(1))
        self.assertIn("missionPassAttention = []", body.group(1))

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

    def test_the_agent_count_fields_match(self):
        # The count is a nested object the report's own encoder spells in its
        # `where` clause, so it is read from there rather than from the
        # top-level field list.
        encoder = re.search(
            r"^    agents count =\n((?:      .*\n)+)", self.source, re.MULTILINE
        )
        self.assertIsNotNone(encoder, "the agent count encoder is not declared")
        fields = {match.group(1) for match in re.finditer(r'"([a-z_]+)" \.=', encoder.group(1))}
        self.assertEqual(service.PASS_AGENT_FIELDS, fields)

    def test_no_per_pass_mission_limit_is_declared(self):
        # Issue #746 retired the compiled two-missions-per-pass limit, and with
        # it the mirror this controller held reports to. A limit reintroduced
        # in the scheduler would have to come back here as well, with a test.
        scheduler = (
            REPO_ROOT / "src" / "Kanban" / "Mission" / "Scheduler.hs"
        ).read_text(encoding="utf-8")
        self.assertNotRegex(scheduler, r"^missionAdmissionCeiling ", )
        self.assertFalse(hasattr(service, "PASS_ADMISSION_CEILING"))

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


class PassProgressTests(unittest.TestCase):
    """Which passes count as having moved something.

    `--interval` is documented as the wait after a pass that advanced nothing,
    so the split matters: a pass that admitted two missions and was refused the
    lease for both advanced nothing at all, and treating admission as progress
    would poll flat out for as long as the contention lasted.
    """

    def document(self, *dispositions, attention=()):
        return pass_document(
            admitted=[
                admitted_entry(mission=f"mission-{index}", disposition=disposition)
                for index, disposition in enumerate(dispositions)
            ],
            attention=list(attention),
        )

    def test_a_child_that_ran_is_progress(self):
        for disposition in ("advanced", "settled", "blocked"):
            with self.subTest(disposition=disposition):
                self.assertTrue(service.pass_advanced(self.document(disposition)))

    def test_a_child_that_declined_is_not(self):
        for disposition in ("lease_refused", "refused"):
            with self.subTest(disposition=disposition):
                self.assertFalse(service.pass_advanced(self.document(disposition)))

    def test_one_advancing_mission_beside_a_refusal_is_progress(self):
        self.assertTrue(service.pass_advanced(self.document("lease_refused", "advanced")))

    def test_an_empty_pass_is_not_progress(self):
        self.assertFalse(service.pass_advanced(self.document()))

    def test_a_contended_pass_reads_idle_rather_than_running(self):
        # The state follows the same split: whatever holds that lease is the
        # thing making progress, not this pass.
        self.assertEqual(service.pass_state(self.document("lease_refused")), service.STATE_IDLE)
        self.assertEqual(service.pass_state(self.document("advanced")), service.STATE_RUNNING)

    def test_the_progress_and_failing_vocabularies_partition_the_rest(self):
        # Every disposition is accounted for: three are progress, two fail the
        # pass, and exactly three are neither — losing a race for an
        # advancement lease, which is two correct processes meeting; watching
        # a live worker; and being held back by the agent ceiling. A
        # disposition added to the scheduler and to nothing here would show up
        # as unclassified.
        self.assertEqual(
            service.PASS_DISPOSITIONS
            - service.PASS_PROGRESS_DISPOSITIONS
            - service.PASS_FAILING_DISPOSITIONS,
            {"lease_refused", "awaiting", "deferred"},
        )

    def test_a_pass_of_only_slot_deferrals_is_not_progress(self):
        # Issue #746: a pass whose every mission was held back by the agent
        # ceiling moved nothing, so it waits out the interval rather than
        # polling flat out while the agents holding every slot run -- and it
        # is a completed pass, which opens no incident.
        document = self.document("deferred", "deferred", "awaiting")
        self.assertEqual(service.parse_pass_report(json.dumps(document), 0), document)
        self.assertFalse(service.pass_advanced(document))
        self.assertEqual(service.pass_state(document), service.STATE_IDLE)
        self.assertEqual(document["termination"], service.PASS_COMPLETED)

    def test_a_deferral_beside_an_advance_is_progress(self):
        self.assertTrue(service.pass_advanced(self.document("deferred", "advanced")))


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
            "unknown version": (json.dumps({**pass_document(), "version": 3}), 0),
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
            # The agent count is two plain integers, or null.
            "an agent count that is not an object": (
                json.dumps(pass_document(agents=[1, 2])),
                0,
            ),
            "an agent count with the wrong fields": (
                json.dumps(pass_document(agents={"live": 1})),
                0,
            ),
            "a negative live agent count": (
                json.dumps(pass_document(agents={"live": -1, "ceiling": 2})),
                0,
            ),
            "a Boolean live agent count": (
                json.dumps(pass_document(agents={"live": True, "ceiling": 2})),
                0,
            ),
            "a zero agent ceiling": (
                json.dumps(pass_document(agents={"live": 0, "ceiling": 0})),
                0,
            ),
            # The scheduler always counts on a completed pass, and fails one it
            # could not count; a completed report without a count is missing
            # the number the ceiling is judged by.
            "a completed pass with no agent count": (
                json.dumps(pass_document(agents=None)),
                0,
            ),
            "a refused pass that counted agents": (
                json.dumps(
                    pass_document(termination="refused", agents={"live": 0, "ceiling": 2})
                ),
                2,
            ),
            # `unresolved` means the writer could not say which items an
            # episode is about, which it treats as indeterminate state and
            # terminates `failed` for. A completed pass carrying one is two
            # halves of a report contradicting each other.
            "unresolved attention under a completed pass": (
                json.dumps(pass_document(attention=[unresolved_attention_entry()])),
                0,
            ),
            "unresolved attention under a refused pass": (
                json.dumps(pass_document(termination="refused", attention=[unresolved_attention_entry()])),
                2,
            ),
            # `unresolved` means there was nothing to resolve targets from, so
            # naming some describes a resolution that cannot have happened.
            "unresolved attention carrying targets": (
                json.dumps(
                    pass_document(
                        termination="failed",
                        attention=[{**unresolved_attention_entry(), "targets": [{"kind": "issue", "number": 844}]}],
                    )
                ),
                1,
            ),
            "unresolved attention giving no reason": (
                json.dumps(
                    pass_document(
                        termination="failed",
                        attention=[{**unresolved_attention_entry(), "detail": None}],
                    )
                ),
                1,
            ),
            "unresolved attention whose reason is blank": (
                json.dumps(
                    pass_document(
                        termination="failed",
                        attention=[{**unresolved_attention_entry(), "detail": "   "}],
                    )
                ),
                1,
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
            attention=[unresolved_attention_entry()],
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

    def test_a_pass_advancing_more_than_two_missions_is_accepted(self):
        # Issue #746 retired the per-pass mission limit: every runnable
        # mission is advanced by one transition, so a report naming more than
        # two of them is the scheduler working, not a scheduler this
        # controller cannot supervise.
        document = pass_document(
            admitted=[
                admitted_entry(mission=f"mission-{name}")
                for name in ("a", "b", "c", "d", "e")
            ],
            agents={"live": 2, "ceiling": 2},
        )
        self.assertEqual(service.parse_pass_report(json.dumps(document), 0), document)

    def test_a_live_count_above_a_lowered_ceiling_is_accepted(self):
        # Lowering the ceiling stops new agents; it does not end running ones,
        # so a pass may honestly see more live agents than it now allows.
        document = pass_document(agents={"live": 3, "ceiling": 1})
        self.assertEqual(service.parse_pass_report(json.dumps(document), 0), document)


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

    def test_a_mixed_case_remote_keeps_both_spellings(self):
        # GitHub names are case-insensitive, so this service's own locking and
        # runtime state fold the identity — two clones spelled differently are
        # one repository. Kanban does not fold: a mission store path is built
        # from the spelling segment by segment, and its records are compared by
        # equality. Handing a pass the folded name would open a different store
        # on a case-sensitive filesystem and have the real records refused as
        # another repository's on a case-insensitive one.
        mixed = self.root / "mixed"
        mixed.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=mixed, check=True)
        subprocess.run(
            ["git", "remote", "add", "origin", "git@github.com:Acme/Widgets.git"],
            cwd=mixed,
            check=True,
        )
        job = service.resolve_job(mixed)
        self.assertEqual(job.identity, "acme/widgets")
        self.assertEqual(job.spelling, "Acme/Widgets")
        # The partitioned state follows the folded name, so two spellings of
        # one repository still contend.
        self.assertEqual(job.slug, service.repository_slug("acme/widgets"))
        self.assertEqual(job.lock_path, self.job().lock_path)

    def test_a_mixed_case_remote_launches_the_pass_with_kanbans_spelling(self):
        mixed = self.root / "mixed-run"
        mixed.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=mixed, check=True)
        subprocess.run(
            ["git", "remote", "add", "origin", "git@github.com:Acme/Widgets.git"],
            cwd=mixed,
            check=True,
        )
        self.write_plan(
            {"report": {"document": pass_document(repository="Acme/Widgets")}}
        )
        child = subprocess.Popen(
            [
                sys.executable,
                str(self.wrapper),
                str(CONTROLLER.parent),
                str(self.account),
                "run",
                "--path",
                str(mixed),
                "--kanban",
                str(self.scheduler),
                "--interval",
                "0.05",
                "--passes",
                "1",
            ],
            env=self.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        self.processes.append(child)
        _stdout, stderr = child.communicate(timeout=40)
        self.assertEqual(child.returncode, 0, stderr)
        argv = self.recorded()[0]["argv"]
        self.assertEqual(argv[argv.index("--repo") + 1], "Acme/Widgets")

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
        force_stop(first)
        first.wait(timeout=30)

    def test_a_stop_ends_the_run_without_recording_a_failure(self):
        # One stop drains: the pass holding its report is let finish, and the
        # run ends on purpose with nothing to report.
        self.write_plan({"report": {"document": pass_document(), "hold_seconds": 3}})
        child = self.start_controller()
        wait_until(lambda: self.recorded(), message="a pass to start")
        os.killpg(child.pid, signal.SIGTERM)
        child.wait(timeout=30)
        self.assertEqual(child.returncode, 0)
        snapshot = self.status()
        self.assertEqual(snapshot["state"], service.STATE_STOPPED)
        self.assertEqual(snapshot["open_incidents"], [])

    def test_a_forced_stop_during_a_partial_report_records_no_pass_failure(self):
        # A report is written in one call, but the pipe need not carry it in
        # one piece and its attention list is unbounded — so a stop can land
        # after a nonempty prefix. Emptiness was the old test for "interrupted",
        # which turned an operator's own stop into a failure incident. Only a
        # stop that cut the pass off can do that, so this one is forced; the
        # escalation is what it reports instead.
        document = pass_document(attention=[attention_entry()])
        prefix = json.dumps(document)[: len(json.dumps(document)) // 2]
        self.write_plan({"report": {"raw": prefix, "status": 0, "hold_seconds": 30}})
        child = self.start_controller()
        wait_until(lambda: self.recorded(), message="a pass to start")
        force_stop(child)
        child.wait(timeout=30)
        self.assertEqual(child.returncode, 0)
        snapshot = self.status()
        self.assertEqual(snapshot["state"], service.STATE_STOPPED)
        self.assertEqual(
            [incident["kind"] for incident in snapshot["open_incidents"]],
            [service.DRAIN_ESCALATION_INCIDENT_KIND],
        )

    def test_a_forced_stop_leaves_no_mission_child_of_the_active_pass_running(self):
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
        force_stop(child)
        child.wait(timeout=40)
        wait_until(
            lambda: process_gone(mission_pid),
            message="the mission child to be ended by the stop",
        )


# ---------------------------------------------------------------------------
# Draining on stop
# ---------------------------------------------------------------------------


class DrainTests(MissionRunnerFixture):
    """RUN-8: a stop lets the pass in flight finish its step (design D-15),
    for at most the drain grace (D-19), and a second stop or the grace running
    out escalates as a forced stop does."""

    def setUp(self):
        super().setUp()
        self.step_marker = self.root / "step.pid"
        self.release = self.root / "release"
        self.done = self.root / "step.done"

    def step_plan(self, **extra):
        plan = {
            "step_child": {
                "marker": str(self.step_marker),
                "release": str(self.release),
                "done": str(self.done),
            },
            "report": {"document": pass_document()},
        }
        plan.update(extra)
        self.write_plan(plan)

    def ensure_gone(self, pid):
        def kill():
            if not process_gone(pid):
                with contextlib_suppress():
                    os.kill(pid, signal.SIGKILL)
        self.addCleanup(kill)

    def start_mid_step(self, *arguments, environment=None):
        """A controller whose pass has a mission child part-way through its
        step, and that child's identifier."""
        child = self.start_controller(*arguments, environment=environment)
        wait_until(self.step_marker.exists, message="the mission child to begin its step")
        step = int(wait_until(lambda: self.step_marker.read_text(encoding="utf-8")))
        self.ensure_gone(step)
        return child, step

    def stop(self, child):
        # The wrapper alone, as a service manager's stop reaches it: the pass
        # leads a session of its own, which only the wrapper may signal.
        os.kill(child.pid, signal.SIGTERM)

    def wait_for_state(self, state):
        return wait_until(
            lambda: (snapshot := self.status())["state"] == state and snapshot,
            message=f"the status document to report {state}",
        )

    def incident_kinds(self):
        return [incident["kind"] for incident in self.status()["open_incidents"]]

    def test_a_drain_lets_the_mission_child_finish_its_step(self):
        self.step_plan()
        child, step = self.start_mid_step()
        self.stop(child)
        draining = self.wait_for_state(service.STATE_DRAINING)
        self.assertIsNotNone(draining["pass_pid"])
        self.assertIsNone(draining["reason"])
        # Nothing is signalled: the step goes on, and so does the drain.
        time.sleep(1.5)
        self.assertFalse(process_gone(step))
        self.assertFalse(self.done.exists())
        self.assertIsNone(child.poll())
        self.assertEqual(self.status()["state"], service.STATE_DRAINING)
        self.release.touch()
        child.wait(timeout=30)
        self.assertEqual(child.returncode, 0)
        self.assertTrue(self.done.exists(), "the step was cut off")
        snapshot = self.status()
        self.assertEqual(snapshot["state"], service.STATE_STOPPED)
        self.assertIn("finished its step", snapshot["message"])
        self.assertEqual(snapshot["open_incidents"], [])
        # No further pass: the one in flight was the last.
        self.assertEqual(len(self.recorded()), 1)
        self.assertFalse(self.job().pass_record_path.exists())

    def test_the_grace_escalates_as_a_forced_stop(self):
        # A stubborn mission child beside the step, so what is proved is that
        # the escalation kills rather than only asks.
        stubborn = self.root / "stubborn.pid"
        self.step_plan(mission_child=str(stubborn))
        child, step = self.start_mid_step(
            environment=self.environment(
                FIXTURE_DRAIN_GRACE_SECONDS="2", FIXTURE_STOP_GRACE_SECONDS="1"
            )
        )
        stubborn_pid = int(stubborn.read_text(encoding="utf-8"))
        self.ensure_gone(stubborn_pid)
        self.stop(child)
        self.wait_for_state(service.STATE_DRAINING)
        child.wait(timeout=40)
        self.assertEqual(child.returncode, 0)
        wait_until(lambda: process_gone(step), message="the step to be cut off")
        wait_until(lambda: process_gone(stubborn_pid), message="the stubborn child to be killed")
        self.assertFalse(self.done.exists())
        snapshot = self.status()
        self.assertEqual(snapshot["state"], service.STATE_STOPPED)
        # The escalation survives the final write, in the message and as an
        # open incident, which is what tells it apart from a clean drain.
        self.assertIn("escalating the drain", snapshot["message"])
        self.assertIn("grace", snapshot["message"])
        self.assertEqual(self.incident_kinds(), [service.DRAIN_ESCALATION_INCIDENT_KIND])
        self.assertIn("interrupted", snapshot["open_incidents"][0]["detail"])
        self.assertEqual(len(self.recorded()), 1)

    def test_a_second_stop_escalates_at_once(self):
        stubborn = self.root / "stubborn.pid"
        self.step_plan(mission_child=str(stubborn))
        # The service's own five-minute grace: only the second stop can end
        # this inside the test's patience.
        child, step = self.start_mid_step(
            environment=self.environment(FIXTURE_STOP_GRACE_SECONDS="1")
        )
        stubborn_pid = int(stubborn.read_text(encoding="utf-8"))
        self.ensure_gone(stubborn_pid)
        self.stop(child)
        self.wait_for_state(service.STATE_DRAINING)
        self.stop(child)
        child.wait(timeout=30)
        self.assertEqual(child.returncode, 0)
        wait_until(lambda: process_gone(step), message="the step to be cut off")
        wait_until(lambda: process_gone(stubborn_pid), message="the stubborn child to be killed")
        self.assertFalse(self.done.exists())
        snapshot = self.status()
        self.assertEqual(snapshot["state"], service.STATE_STOPPED)
        self.assertIn("second stop", snapshot["message"])
        self.assertEqual(self.incident_kinds(), [service.DRAIN_ESCALATION_INCIDENT_KIND])

    def test_a_stop_just_before_the_gate_opens_runs_no_pass(self):
        # After the pass's identity is recorded and its running status
        # written, and before its gate is opened: a stop landing there is
        # decided by the handler, not by a check it could land just after.
        status, _stdout, stderr = self.run_controller(
            environment=self.environment(FIXTURE_STOP_AT="release_pass")
        )
        self.assertEqual(status, 0, stderr)
        self.assertEqual(self.recorded(), [], "a pass ran after the stop")
        snapshot = self.status()
        self.assertEqual(snapshot["state"], service.STATE_STOPPED)
        self.assertEqual(snapshot["message"], "Stopped intentionally.")
        self.assertEqual(snapshot["open_incidents"], [])
        self.assertFalse(self.job().pass_record_path.exists())

    def test_an_escalation_reaches_a_mission_child_its_scheduler_left(self):
        # The scheduler reports and exits, and a mission child that ignores
        # SIGTERM keeps its streams open, so the pass is still in flight with
        # no leader alive. Both escalations have to reach that child.
        for how in ("grace", "second stop"):
            with self.subTest(how=how):
                self.setUp()
                stubborn = self.root / "stubborn.pid"
                self.write_plan(
                    {"mission_child": str(stubborn), "report": {"document": pass_document()}}
                )
                grace = "1" if how == "grace" else "300"
                child = self.start_controller(
                    environment=self.environment(
                        FIXTURE_DRAIN_GRACE_SECONDS=grace, FIXTURE_STOP_GRACE_SECONDS="1"
                    )
                )
                wait_until(stubborn.exists, message="the mission child to register itself")
                stubborn_pid = int(wait_until(lambda: stubborn.read_text(encoding="utf-8")))
                self.ensure_gone(stubborn_pid)
                wait_until(lambda: self.recorded(), message="the scheduler to run")
                time.sleep(1.5)
                self.stop(child)
                self.wait_for_state(service.STATE_DRAINING)
                if how == "second stop":
                    self.stop(child)
                child.wait(timeout=30)
                self.assertEqual(child.returncode, 0)
                wait_until(
                    lambda: process_gone(stubborn_pid), message="the mission child to be killed"
                )
                snapshot = self.status()
                self.assertEqual(snapshot["state"], service.STATE_STOPPED)
                self.assertIn(how, snapshot["message"])
                self.assertEqual(
                    self.incident_kinds(), [service.DRAIN_ESCALATION_INCIDENT_KIND]
                )

    def test_a_pass_its_scheduler_finished_keeps_its_own_verdict_through_an_escalation(self):
        # The scheduler writes its report and exits on its own, and a mission
        # child it left holds the pass's streams until the grace escalates.
        # What the scheduler wrote is its verdict, not the stop's doing: a
        # failed report still fails the run, and so does one that will not
        # parse -- and the terminal status still reports the escalation.
        failed = pass_document(termination="failed", detail="the pass failed by itself")
        for name, report, expected in (
            ("failed report", {"document": failed, "status": 1}, "the pass failed by itself"),
            ("malformed report", {"raw": json.dumps(failed)[:20], "status": 0}, "report"),
        ):
            with self.subTest(name):
                self.setUp()
                stubborn = self.root / "stubborn.pid"
                self.write_plan({"mission_child": str(stubborn), "report": report})
                child = self.start_controller(
                    environment=self.environment(
                        FIXTURE_DRAIN_GRACE_SECONDS="1", FIXTURE_STOP_GRACE_SECONDS="1"
                    )
                )
                wait_until(stubborn.exists, message="the mission child to register itself")
                stubborn_pid = int(wait_until(lambda: stubborn.read_text(encoding="utf-8")))
                self.ensure_gone(stubborn_pid)
                wait_until(lambda: self.recorded(), message="the scheduler to run")
                time.sleep(1.5)
                self.stop(child)
                child.wait(timeout=30)
                self.assertEqual(child.returncode, 1)
                wait_until(
                    lambda: process_gone(stubborn_pid), message="the mission child to be killed"
                )
                snapshot = self.status()
                self.assertEqual(snapshot["state"], service.STATE_FAILED)
                self.assertIn("escalated", snapshot["message"])
                self.assertIn("grace", snapshot["message"])
                self.assertEqual(
                    sorted(self.incident_kinds()),
                    sorted([service.PASS_INCIDENT_KIND, service.DRAIN_ESCALATION_INCIDENT_KIND]),
                )
                failure = [
                    incident
                    for incident in snapshot["open_incidents"]
                    if incident["kind"] == service.PASS_INCIDENT_KIND
                ][0]
                self.assertIn(expected, failure["summary"])

    def test_a_stop_between_passes_exits_without_waiting(self):
        child = self.start_controller("--interval", "60")
        wait_until(
            lambda: self.recorded() and self.status()["state"] == service.STATE_IDLE,
            message="the first pass to finish",
        )
        started = time.monotonic()
        self.stop(child)
        child.wait(timeout=30)
        self.assertLess(time.monotonic() - started, 5)
        self.assertEqual(child.returncode, 0)
        snapshot = self.status()
        self.assertEqual(snapshot["state"], service.STATE_STOPPED)
        self.assertEqual(snapshot["message"], "Stopped intentionally.")
        self.assertEqual(len(self.recorded()), 1)

    def test_a_request_queued_during_the_drain_is_left_for_the_next_runner(self):
        requests = self.root / "store" / "control" / "requests"
        requests.mkdir(parents=True)
        self.step_plan(requests_dir=str(requests))
        child, _step = self.start_mid_step()
        self.stop(child)
        self.wait_for_state(service.STATE_DRAINING)
        queued = requests / "request-1.json"
        queued.write_text("{}", encoding="utf-8")
        self.release.touch()
        child.wait(timeout=30)
        self.assertEqual(child.returncode, 0)
        self.assertTrue(queued.exists(), "the drain consumed or discarded a queued command")
        self.write_plan({"requests_dir": str(requests), "report": {"document": pass_document()}})
        status, _stdout, stderr = self.run_controller("--passes", "1")
        self.assertEqual(status, 0, stderr)
        self.assertFalse(queued.exists())
        self.assertEqual(self.recorded()[-1]["consumed"], ["request-1.json"])

    def test_a_detached_worker_is_not_waited_for_and_outlives_the_drain(self):
        worker_marker = self.root / "worker.pid"
        self.step_plan(detached_worker=str(worker_marker))
        child, _step = self.start_mid_step()
        worker = int(worker_marker.read_text(encoding="utf-8"))
        self.ensure_gone(worker)
        self.stop(child)
        self.wait_for_state(service.STATE_DRAINING)
        self.release.touch()
        child.wait(timeout=30)
        self.assertEqual(child.returncode, 0)
        self.assertFalse(process_gone(worker))
        # The next runner neither settles it nor finds it gone: its pass sees
        # the worker still live, which is what it reconciles against rather
        # than dispatching the step again.
        self.write_plan({"report_alive": [worker], "report": {"document": pass_document()}})
        status, _stdout, stderr = self.run_controller("--passes", "1")
        self.assertEqual(status, 0, stderr)
        self.assertFalse(process_gone(worker))
        self.assertEqual(self.recorded()[-1]["alive"], [worker])

    def test_the_run_lock_is_handed_over_once_the_drain_ends(self):
        self.step_plan()
        child, _step = self.start_mid_step()
        self.stop(child)
        self.wait_for_state(service.STATE_DRAINING)
        status, _stdout, stderr = self.run_controller("--passes", "1", timeout=30)
        self.assertEqual(status, 1)
        self.assertIn("already running", stderr)
        with self.assertRaises(service.ServiceError):
            with service.exclusive_of_runs(self.job(), "installing it"):
                pass
        self.assertEqual(len(self.recorded()), 1)
        self.release.touch()
        child.wait(timeout=30)
        with service.exclusive_of_runs(self.job(), "installing it"):
            pass
        self.write_plan({"report": {"document": pass_document()}})
        status, _stdout, stderr = self.run_controller("--passes", "1")
        self.assertEqual(status, 0, stderr)
        self.assertEqual(len(self.recorded()), 2)

    def test_a_pass_that_fails_on_its_own_during_a_drain_still_fails(self):
        # A drain signals nothing, so what the pass it waited for wrote is the
        # pass's own verdict: an unreadable report is a failure, not a stop.
        prefix = json.dumps(pass_document())[:20]
        self.step_plan(report={"raw": prefix, "status": 0})
        child, _step = self.start_mid_step()
        self.stop(child)
        self.wait_for_state(service.STATE_DRAINING)
        self.release.touch()
        child.wait(timeout=30)
        self.assertEqual(child.returncode, 1)
        self.assertEqual(self.status()["state"], service.STATE_FAILED)
        self.assertEqual(self.incident_kinds(), [service.PASS_INCIDENT_KIND])

    def test_a_completed_pass_during_a_drain_leaves_draining_until_the_stop(self):
        # The pass's own verdict is kept as the last pass, but never written as
        # the run's state: nothing is running or idle once a drain has begun.
        self.step_plan(report={"document": pass_document(admitted=[admitted_entry()])})
        child, _step = self.start_mid_step()
        self.stop(child)
        self.wait_for_state(service.STATE_DRAINING)
        self.release.touch()
        seen = set()
        while child.poll() is None:
            seen.add(self.status()["state"])
            time.sleep(0.01)
        self.assertEqual(child.returncode, 0)
        self.assertLessEqual(seen, {service.STATE_DRAINING, service.STATE_STOPPED})
        snapshot = self.status()
        self.assertEqual(snapshot["state"], service.STATE_STOPPED)
        self.assertEqual(snapshot["passes"], 1)
        self.assertEqual(snapshot["last_pass"]["admitted"], [admitted_entry()])


class DrainClockTests(unittest.TestCase):
    """The grace, read against an injected clock rather than waited out."""

    def controller(self, root):
        patched = mock.patch.object(service, "account_home", lambda: Path(root))
        patched.start()
        self.addCleanup(patched.stop)
        job = service.job_for_identity(Path(root), "acme/widgets")
        return service.Controller(job, kanban=Path("/nonexistent/kanban"), interval=60)

    def test_the_grace_is_measured_from_the_first_stop_and_never_reset(self):
        with tempfile.TemporaryDirectory() as root:
            controller = self.controller(root)
            with mock.patch.object(service.time, "monotonic", return_value=1000.0):
                controller.handle_stop(signal.SIGTERM, None)
            self.assertEqual(controller._drain_deadline, 1000.0 + service.DRAIN_GRACE_SECONDS)
            with mock.patch.object(service.time, "monotonic", return_value=1100.0):
                controller.handle_stop(signal.SIGTERM, None)
            self.assertEqual(controller._drain_deadline, 1000.0 + service.DRAIN_GRACE_SECONDS)

    def test_a_first_stop_signals_nothing(self):
        with tempfile.TemporaryDirectory() as root:
            controller = self.controller(root)
            fake_child = mock.Mock()
            fake_child.poll.return_value = None
            controller._child = fake_child
            controller._released = True
            with mock.patch.object(service.os, "killpg") as killpg:
                controller.handle_stop(signal.SIGTERM, None)
                killpg.assert_not_called()
                self.assertIsNone(controller._escalation)
                controller.handle_stop(signal.SIGTERM, None)
                killpg.assert_called_once_with(fake_child.pid, signal.SIGTERM)
                self.assertIn("second stop", controller._escalation)
                controller.handle_stop(signal.SIGTERM, None)
                killpg.assert_called_with(fake_child.pid, signal.SIGKILL)

    def test_a_first_stop_ends_a_pass_still_behind_its_gate(self):
        with tempfile.TemporaryDirectory() as root:
            controller = self.controller(root)
            fake_child = mock.Mock()
            fake_child.poll.return_value = None
            fake_child.stdin = mock.Mock()
            controller._child = fake_child
            with mock.patch.object(service.os, "killpg") as killpg:
                controller.handle_stop(signal.SIGTERM, None)
                killpg.assert_called_once_with(fake_child.pid, signal.SIGTERM)
            self.assertTrue(controller._ended_at_gate)
            self.assertIsNone(controller._escalation)
            # The release that follows opens nothing.
            gate = fake_child.stdin
            controller.release_pass(fake_child)
            gate.write.assert_not_called()

    def with_stop_handler(self, controller):
        previous = signal.signal(signal.SIGTERM, controller.handle_stop)
        self.addCleanup(signal.signal, signal.SIGTERM, previous)

    def test_a_stop_during_the_gate_write_is_handled_once_the_pass_is_released(self):
        # The window between deciding to release and writing the word: a stop
        # arriving there is held until the write is done, then drains the
        # pass it finds released. Unblocked, the handler would run inside the
        # write, after the decision and before the word -- the stop recorded
        # and a new pass started anyway.
        with tempfile.TemporaryDirectory() as root:
            controller = self.controller(root)
            self.with_stop_handler(controller)
            fake_child = mock.Mock()
            fake_child.poll.return_value = None
            gate = fake_child.stdin
            seen = []

            def write(_word):
                os.kill(os.getpid(), signal.SIGTERM)
                seen.append(controller._stop_requested)

            gate.write.side_effect = write
            controller._child = fake_child
            with mock.patch.object(service.os, "killpg") as killpg:
                controller.release_pass(fake_child)
                killpg.assert_not_called()
            self.assertEqual(seen, [False], "the stop was handled inside the release")
            gate.write.assert_called_once_with(service.PASS_GATE_WORD + "\n")
            self.assertTrue(controller._stop_requested)
            self.assertTrue(controller._released)
            self.assertFalse(controller._ended_at_gate)
            self.assertEqual(
                signal.pthread_sigmask(signal.SIG_BLOCK, set()) & service.STOP_SIGNALS,
                set(),
                "the stop signals were left blocked",
            )

    def test_a_stop_already_caught_when_the_release_begins_opens_nothing(self):
        with tempfile.TemporaryDirectory() as root:
            controller = self.controller(root)
            fake_child = mock.Mock()
            fake_child.poll.return_value = None
            gate = fake_child.stdin
            controller._child = fake_child
            # Recorded, but with the gate not yet ended -- the state a stop
            # handled before the child was registered leaves.
            controller._stop_requested = True
            with mock.patch.object(service.os, "killpg") as killpg:
                controller.release_pass(fake_child)
                killpg.assert_called_once_with(fake_child.pid, signal.SIGTERM)
            gate.write.assert_not_called()
            self.assertFalse(controller._released)
            self.assertTrue(controller._ended_at_gate)

    def test_only_an_escalation_that_reached_the_scheduler_excuses_its_report(self):
        with tempfile.TemporaryDirectory() as root:
            for alive, returncode, excused in (
                (True, -signal.SIGTERM, True),
                (True, 1, True),
                (True, 0, False),
                (False, -signal.SIGKILL, False),
                (False, 1, False),
            ):
                with self.subTest(alive=alive, returncode=returncode):
                    controller = self.controller(root)
                    fake_child = mock.Mock()
                    fake_child.poll.return_value = None if alive else 1
                    controller._child = fake_child
                    controller._released = True
                    self.assertFalse(controller.cut_off_by_escalation(returncode))
                    with mock.patch.object(service.os, "killpg"):
                        controller.escalate("the grace ran out")
                    self.assertEqual(controller.cut_off_by_escalation(returncode), excused)

    def test_an_escalation_reaches_a_group_whose_leader_has_exited(self):
        with tempfile.TemporaryDirectory() as root:
            controller = self.controller(root)
            fake_child = mock.Mock()
            fake_child.poll.return_value = 0
            controller._child = fake_child
            controller._released = True
            with mock.patch.object(service.os, "killpg") as killpg:
                controller.escalate("the grace ran out")
                killpg.assert_called_once_with(fake_child.pid, signal.SIGTERM)
            self.assertEqual(controller._escalation, "the grace ran out")

    def test_the_drain_grace_is_five_minutes_and_the_unit_outlasts_it(self):
        # D-19: a five-minute grace, and a systemd stop timeout that covers it,
        # the escalation's polite stop and kill, and the settlement after.
        self.assertEqual(service.DRAIN_GRACE_SECONDS, 300.0)
        timeout = service.service_manager.MISSION_RUNNER_NAMESPACE.stop_timeout_seconds
        self.assertIsNotNone(timeout)
        self.assertGreater(
            timeout,
            service.DRAIN_GRACE_SECONDS
            + service.STOP_GRACE_SECONDS
            + service.SETTLE_KILL_SECONDS
            + 60,
        )


# ---------------------------------------------------------------------------
# Settling what a previous run left
# ---------------------------------------------------------------------------

# A stand-in pass that has already exited: it starts a mission child in its
# own process group that ignores SIGTERM and reports its identifier, and then
# leaves -- which is the one shape a surviving mission child whose scheduler
# is gone can have.
#
# It lingers until told to go, so a fixture can observe its identity after its
# start second has ended -- the only observation a pass record accepts.
LEADERLESS = (
    "import os, subprocess, sys, time\n"
    "subprocess.Popen([sys.executable, '-c', sys.argv[2], sys.argv[1]])\n"
    "while not os.path.exists(sys.argv[1]):\n"
    "    time.sleep(0.01)\n"
    "sys.stdin.read()\n"
)
STUBBORN_CHILD = (
    "import os, signal, sys, time\n"
    "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
    "open(sys.argv[1], 'w').write(str(os.getpid()))\n"
    "time.sleep(300)\n"
)


class SettlementClassificationTests(unittest.TestCase):
    """The three readings of a recorded pass, from a crafted process table."""

    identity = "Mon Sep 28 07:00:00 2026"

    def test_a_verified_leader_vouches_for_its_whole_group(self):
        table = {100: (100, self.identity), 101: (100, "later"), 200: (200, "other")}
        self.assertEqual(
            service.classify_pass_group(table, 100, self.identity, set()),
            (True, [100, 101], []),
        )

    def test_a_reused_leader_identifier_vouches_for_nothing_in_its_group(self):
        table = {100: (100, "a stranger"), 101: (100, "the stranger's child")}
        self.assertEqual(
            service.classify_pass_group(table, 100, self.identity, set()),
            (False, [], []),
        )

    def test_a_leaderless_group_is_verified_by_recorded_identity_alone(self):
        table = {101: (100, "recorded"), 102: (100, "never recorded")}
        self.assertEqual(
            service.classify_pass_group(table, 100, self.identity, {(101, "recorded")}),
            (False, [101], [102]),
        )

    # A recorded member seen in another group since has left the pass's -- a
    # mission child's descendant caught before its `setsid` and now a detached
    # worker. It is not the pass's to signal, or to wait for.
    def test_a_recorded_member_that_left_the_group_is_not_the_passs(self):
        table = {101: (101, "recorded"), 102: (100, "still here")}
        members = {(101, "recorded"), (102, "still here")}
        self.assertEqual(
            service.classify_pass_group(table, 100, self.identity, members),
            (False, [102], []),
        )
        leader_live = {100: (100, self.identity), **table}
        self.assertEqual(
            service.classify_pass_group(leader_live, 100, self.identity, members),
            (True, [100, 102], []),
        )

    def test_a_legacy_record_verifies_nothing_and_rules_nothing_out(self):
        table = {100: (100, "whoever"), 101: (100, "whoever's child")}
        self.assertEqual(
            service.classify_pass_group(table, 100, None, set()),
            (False, [], [100, 101]),
        )

    def test_a_record_without_a_start_time_is_refused_unless_it_is_legacy(self):
        job = service.job_for_identity(Path("/tmp/x"), "acme/widgets")
        document = {
            "schema": service.PASS_RECORD_SCHEMA,
            "version": service.PASS_RECORD_VERSION,
            "repository": "acme/widgets",
            "pass_pid": 100,
            "pass_identity": None,
            "members": [],
        }
        self.assertIn("no start time", service.pass_record_problem(document, job))
        self.assertIsNone(service.pass_record_problem({**document, "legacy": True}, job))
        self.assertIn(
            "group members",
            service.pass_record_problem({**document, "legacy": True, "members": [{"pid": True}]}, job),
        )

    # `lstart` has one-second resolution, so an identity observed inside its
    # own start second could equally be a process that took over the
    # identifier within that second. Only one observed after it is accepted.
    def test_an_identity_observed_inside_its_start_second_is_not_accepted(self):
        job = service.job_for_identity(Path("/tmp/x"), "acme/widgets")
        started = self.identity
        epoch = service.started_epoch(started)
        self.assertIsNotNone(epoch)
        self.assertFalse(service.identity_confirmed(started, epoch + 0.5))
        self.assertTrue(service.identity_confirmed(started, epoch + 1))
        self.assertFalse(service.identity_confirmed("not a start time", epoch + 5))
        document = {
            "schema": service.PASS_RECORD_SCHEMA,
            "version": service.PASS_RECORD_VERSION,
            "repository": "acme/widgets",
            "pass_pid": 100,
            "pass_identity": started,
            "pass_confirmed_at": epoch + 0.5,
            "members": [],
        }
        self.assertIn("same second", service.pass_record_problem(document, job))
        self.assertIsNone(service.pass_record_problem({**document, "pass_confirmed_at": epoch + 1}, job))
        unconfirmed_member = {"pid": 101, "identity": started, "confirmed_at": epoch + 0.2}
        self.assertIn(
            "group members",
            service.pass_record_problem(
                {**document, "pass_confirmed_at": epoch + 1, "members": [unconfirmed_member]}, job
            ),
        )


class SettlementTests(MissionRunnerFixture):
    """A controller that died leaves a pass; the next one settles it first."""

    def settling_environment(self, **extra):
        return self.environment(FIXTURE_SETTLE_SECONDS="1", **extra)

    def pass_record(self):
        return json.loads(self.job().pass_record_path.read_text(encoding="utf-8"))

    def confirmed_identity(self, pid):
        """A live process's start time, observed after its start second ended,
        and the moment it was observed -- what a controller records."""
        identity = wait_until(
            lambda: (service.process_group_identity(pid) or (None, None))[1],
            message="the process's start time",
        )
        epoch = service.started_epoch(identity)
        wait_until(lambda: time.time() >= epoch + 1, message="its start second to end")
        confirmed_at = time.time()
        self.assertEqual(service.process_group_identity(pid)[1], identity)
        return identity, confirmed_at

    def write_pass_record(self, **fields):
        document = {
            "schema": service.PASS_RECORD_SCHEMA,
            "version": service.PASS_RECORD_VERSION,
            "repository": self.identity,
            "pass_pid": None,
            "pass_identity": None,
            "members": [],
            **fields,
        }
        path = self.job().pass_record_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(document), encoding="utf-8")
        return document

    def ensure_gone(self, pid):
        def kill():
            if not process_gone(pid):
                with contextlib_suppress():
                    os.kill(pid, signal.SIGKILL)
        self.addCleanup(kill)

    def stranger(self):
        """A live process of nobody's, leading its own session and group."""
        child = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(300)"], start_new_session=True
        )
        self.processes.append(child)
        return child

    def leaderless_child(self):
        """A mission child whose pass has exited: the pass's identifier and
        confirmed start time, and the child's identifier and confirmed member
        entry."""
        marker = self.root / "leaderless.pid"
        leader = subprocess.Popen(
            [sys.executable, "-c", LEADERLESS, str(marker), STUBBORN_CHILD],
            start_new_session=True,
            stdin=subprocess.PIPE,
        )
        wait_until(marker.exists, message="the mission child to report itself")
        child = int(marker.read_text(encoding="utf-8"))
        self.ensure_gone(child)
        leader_identity, leader_confirmed = self.confirmed_identity(leader.pid)
        child_identity, child_confirmed = self.confirmed_identity(child)
        leader.communicate(timeout=10)
        return (
            leader.pid,
            {"pass_identity": leader_identity, "pass_confirmed_at": leader_confirmed},
            child,
            {"pid": child, "identity": child_identity, "confirmed_at": child_confirmed},
        )

    def settlement_incidents(self):
        return [
            document
            for _path, document in service.incident_documents(self.job(), open_only=True)
            if document["kind"] == service.SETTLEMENT_INCIDENT_KIND
        ]

    # RUN-4's acceptance, end to end: a wrapper killed outright leaves its pass
    # and that pass's mission child running, and the next wrapper ends both
    # before its own pass starts. The mission child ignores SIGTERM, so what
    # is proved is the escalation rather than its cooperation.
    def test_a_killed_wrappers_pass_and_mission_child_are_settled_before_the_next_pass(self):
        marker = self.root / "mission-child.pid"
        worker_marker = self.root / "worker.pid"
        self.write_plan(
            {
                "mission_child": str(marker),
                "detached_worker": str(worker_marker),
                "report": {"document": pass_document(), "hold_seconds": 60},
            }
        )
        first = self.start_controller(environment=self.settling_environment())
        wait_until(marker.exists, message="the mission child to register itself")
        wait_until(worker_marker.exists, message="the detached worker to register itself")
        mission_pid = int(marker.read_text(encoding="utf-8"))
        worker_pid = int(worker_marker.read_text(encoding="utf-8"))
        self.ensure_gone(mission_pid)
        self.ensure_gone(worker_pid)
        record = self.pass_record()
        pass_pid = record["pass_pid"]
        self.ensure_gone(pass_pid)
        self.assertEqual(record["pass_identity"], service.process_group_identity(pass_pid)[1])
        os.kill(first.pid, signal.SIGKILL)
        first.wait(timeout=10)
        # The premise: nothing ran after the wrapper, and both survive it.
        self.assertFalse(process_gone(pass_pid))
        self.assertFalse(process_gone(mission_pid))
        self.write_plan(
            {"report_alive": [pass_pid, mission_pid], "report": {"document": pass_document()}}
        )
        status, _stdout, stderr = self.run_controller(
            "--passes", "1", environment=self.settling_environment()
        )
        self.assertEqual(status, 0, stderr)
        calls = self.recorded()
        self.assertEqual(len(calls), 2)
        # Verified gone before the next pass started, not merely afterwards --
        # which is what leaves no moment for two passes to advance one mission.
        self.assertEqual(calls[1]["alive"], [])
        self.assertTrue(process_gone(pass_pid))
        self.assertTrue(process_gone(mission_pid))
        # The detached worker is not the runner's, and settlement never reaches
        # it: the next pass reattaches to it instead.
        self.assertFalse(process_gone(worker_pid))
        self.assertFalse(self.job().pass_record_path.exists())
        self.assertEqual(self.settlement_incidents(), [])

    # The gate's two windows. A controller killed after starting its pass and
    # before recording it leaves a pass that can only ever have been waiting
    # on its gate; one killed after recording it and before opening the gate
    # leaves the same pass, recorded. Neither may run the scheduler.
    def test_a_controller_killed_before_it_released_its_pass_ran_nothing(self):
        for die_at, recorded_pid in (("publish_pass", False), ("release_pass", True)):
            with self.subTest(die_at=die_at):
                self.calls.unlink(missing_ok=True)
                status, _stdout, _stderr = self.run_controller(
                    "--passes", "1", environment=self.settling_environment(FIXTURE_DIE_AT=die_at)
                )
                self.assertEqual(status, -signal.SIGKILL)
                record = self.pass_record()
                self.assertEqual(record["pass_pid"] is not None, recorded_pid)
                if recorded_pid:
                    wait_until(
                        lambda: process_gone(record["pass_pid"]),
                        message="the ungated pass to see its controller gone",
                    )
                self.assertEqual(self.recorded(), [])
                status, _stdout, stderr = self.run_controller(
                    "--passes", "1", environment=self.settling_environment()
                )
                self.assertEqual(status, 0, stderr)
                self.assertEqual(len(self.recorded()), 1)
                self.assertFalse(self.job().pass_record_path.exists())

    # A scheduler that exited and left its mission child: the controller that
    # saw that child while the pass was alive recorded it, so the next one can
    # recognize it with no leader to vouch for it.
    def test_a_recorded_mission_child_whose_pass_is_gone_is_settled(self):
        leader, leader_fields, child, child_member = self.leaderless_child()
        self.write_pass_record(pass_pid=leader, members=[child_member], **leader_fields)
        status, _stdout, stderr = self.run_controller(
            "--passes", "1", environment=self.settling_environment()
        )
        self.assertEqual(status, 0, stderr)
        self.assertTrue(process_gone(child))
        self.assertEqual(len(self.recorded()), 1)
        self.assertFalse(self.job().pass_record_path.exists())

    # The same child, never recorded. Nothing proves it is the pass's, so it is
    # neither signalled nor assumed gone: it blocks, and the record that says
    # so survives every restart until the child is gone.
    def test_an_unverifiable_survivor_blocks_every_start_and_is_left_alone(self):
        leader, leader_fields, child, _member = self.leaderless_child()
        written = self.write_pass_record(pass_pid=leader, **leader_fields)
        for _attempt in range(2):
            status, _stdout, _stderr = self.run_controller(
                "--passes", "1", environment=self.settling_environment()
            )
            self.assertEqual(status, 1)
            self.assertFalse(process_gone(child))
            self.assertEqual(self.recorded(), [])
            self.assertEqual(self.pass_record(), written)
        snapshot = self.status()
        self.assertEqual(snapshot["state"], service.STATE_FAILED)
        self.assertIn("not verifiably its own", snapshot["message"])
        incidents = self.settlement_incidents()
        self.assertEqual(len(incidents), 2)
        self.assertIn(str(child), incidents[0]["summary"])
        self.assertIn(str(self.job().pass_record_path), incidents[0]["detail"])
        os.kill(child, signal.SIGKILL)
        wait_until(lambda: process_gone(child), message="the survivor to be reaped")
        status, _stdout, stderr = self.run_controller(
            "--passes", "1", environment=self.settling_environment()
        )
        self.assertEqual(status, 0, stderr)
        self.assertEqual(len(self.recorded()), 1)

    def test_a_recorded_member_that_became_a_detached_worker_is_left_alone(self):
        worker = self.stranger()
        worker_identity, worker_confirmed = self.confirmed_identity(worker.pid)
        leader, leader_fields, child, child_member = self.leaderless_child()
        self.write_pass_record(
            pass_pid=leader,
            members=[
                child_member,
                {"pid": worker.pid, "identity": worker_identity, "confirmed_at": worker_confirmed},
            ],
            **leader_fields,
        )
        status, _stdout, stderr = self.run_controller(
            "--passes", "1", environment=self.settling_environment()
        )
        self.assertEqual(status, 0, stderr)
        self.assertTrue(process_gone(child))
        self.assertIsNone(worker.poll())
        self.assertEqual(len(self.recorded()), 1)

    def test_a_recorded_identifier_reused_by_another_process_is_not_signalled(self):
        stranger = self.stranger()
        long_ago = "Thu Jan  1 00:00:00 1970"
        self.write_pass_record(
            pass_pid=stranger.pid,
            pass_identity=long_ago,
            pass_confirmed_at=service.started_epoch(long_ago) + 60,
        )
        status, _stdout, stderr = self.run_controller(
            "--passes", "1", environment=self.settling_environment()
        )
        self.assertEqual(status, 0, stderr)
        self.assertIsNone(stranger.poll())
        self.assertEqual(len(self.recorded()), 1)
        self.assertFalse(self.job().pass_record_path.exists())

    # A start time is rendered in the reader's time zone, and a controller may
    # be restarted under a different one than the controller that recorded the
    # pass. The same live process has to read as itself either way, or its
    # record would be retired as a stranger's and a second pass started beside
    # it.
    def test_a_pass_recorded_under_another_time_zone_is_still_recognized(self):
        leader = self.stranger()
        # Reaped as soon as it ends, the way a pass whose controller is gone is
        # reaped by init, so its settlement is not held up by this test's own
        # unreaped child.
        threading.Thread(target=leader.wait, daemon=True).start()
        environment = {**os.environ, "TZ": "America/Los_Angeles"}
        with mock.patch.dict(os.environ, environment):
            identity, confirmed_at = self.confirmed_identity(leader.pid)
        self.write_pass_record(
            pass_pid=leader.pid, pass_identity=identity, pass_confirmed_at=confirmed_at
        )
        status, _stdout, stderr = self.run_controller(
            "--passes", "1", environment=self.settling_environment(TZ="UTC")
        )
        self.assertEqual(status, 0, stderr)
        self.assertIsNotNone(leader.poll())
        self.assertEqual(len(self.recorded()), 1)
        self.assertFalse(self.job().pass_record_path.exists())

    # The same-second case the start time alone cannot rule out: a record whose
    # identity matches a live process exactly, but was observed inside that
    # process's own start second, could describe a pass that exited and a
    # stranger that took its identifier within that second. It authorizes no
    # signal; it blocks, and the stranger is left alone.
    def test_an_identity_recorded_inside_its_start_second_blocks_rather_than_signals(self):
        stranger = self.stranger()
        identity, _confirmed = self.confirmed_identity(stranger.pid)
        written = self.write_pass_record(
            pass_pid=stranger.pid,
            pass_identity=identity,
            pass_confirmed_at=service.started_epoch(identity) + 0.5,
        )
        status, _stdout, _stderr = self.run_controller(
            "--passes", "1", environment=self.settling_environment()
        )
        self.assertEqual(status, 1)
        self.assertIsNone(stranger.poll())
        self.assertEqual(self.recorded(), [])
        self.assertEqual(self.pass_record(), written)
        self.assertIn("same second", self.settlement_incidents()[0]["summary"])

    # A release before the pass record left only a process identifier in its
    # status document. That never authorizes a signal: a live process under it
    # blocks, the evidence is kept as a record, and the block lifts once the
    # process is gone.
    def test_a_pass_an_earlier_release_recorded_by_identifier_alone_blocks_until_it_is_gone(self):
        stranger = self.stranger()
        job = self.job()
        job.status_path.parent.mkdir(parents=True, exist_ok=True)
        job.status_path.write_text(
            json.dumps(
                {
                    "schema": service.STATUS_SCHEMA,
                    "version": service.STATUS_VERSION,
                    "state": service.STATE_RUNNING,
                    "repository": self.identity,
                    "runner_pid": 999999,
                    "runner_identity": "Thu Jan  1 00:00:00 1970",
                    "pass_pid": stranger.pid,
                }
            ),
            encoding="utf-8",
        )
        status, _stdout, _stderr = self.run_controller(
            "--passes", "1", environment=self.settling_environment()
        )
        self.assertEqual(status, 1)
        self.assertIsNone(stranger.poll())
        self.assertEqual(self.recorded(), [])
        record = self.pass_record()
        self.assertEqual((record["pass_pid"], record["legacy"]), (stranger.pid, True))
        self.assertEqual(len(self.settlement_incidents()), 1)
        stranger.kill()
        stranger.wait(timeout=10)
        status, _stdout, stderr = self.run_controller(
            "--passes", "1", environment=self.settling_environment()
        )
        self.assertEqual(status, 0, stderr)
        self.assertEqual(len(self.recorded()), 1)
        self.assertFalse(job.pass_record_path.exists())

    def test_an_unreadable_pass_record_blocks_rather_than_reading_as_absent(self):
        path = self.job().pass_record_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("{", encoding="utf-8")
        status, _stdout, _stderr = self.run_controller("--passes", "1")
        self.assertEqual(status, 1)
        self.assertEqual(self.recorded(), [])
        self.assertEqual(path.read_text(encoding="utf-8"), "{")
        self.assertEqual(len(self.settlement_incidents()), 1)

    def test_an_ordinary_pass_leaves_no_record_and_says_where_one_would_be(self):
        status, _stdout, stderr = self.run_controller("--passes", "1")
        self.assertEqual(status, 0, stderr)
        self.assertFalse(self.job().pass_record_path.exists())
        stored = json.loads(self.job().status_path.read_text(encoding="utf-8"))
        self.assertEqual(stored["pass_record"], str(self.job().pass_record_path))


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

    def test_a_whole_report_is_still_acted_on_however_the_run_ended(self):
        # The other half of the interruption rule, and the reason that check
        # sits after the parse rather than before it: work that really happened
        # must not be reported as work that did not. A pass that failed and
        # said so completely still opens its incident.
        self.write_plan(
            {
                "report": {
                    "document": pass_document(
                        termination="failed", detail="the pass failed before the stop"
                    ),
                    "status": 1,
                }
            }
        )
        status, _stdout, _stderr = self.run_controller()
        self.assertEqual(status, 1)
        incident = self.assert_incident(service.PASS_INCIDENT_KIND)
        self.assertIn("failed before the stop", incident["summary"])

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

    def test_a_pass_that_established_no_repository_says_so(self):
        # A setup failure reaches this controller as a document like any
        # other, and the whole point of the marker is that it does not read as
        # somebody else's repository. Both refusals open an incident; what is
        # asserted is that the operator is told which one happened, because
        # "the scheduler read another repository's store" and "the scheduler
        # never got far enough to read anything" call for different repairs.
        self.write_plan(
            {
                "report": {
                    "document": pass_document(
                        repository=service.PASS_UNRESOLVED_REPOSITORY,
                        termination="failed",
                        detail="the configuration could not be read",
                    ),
                    "status": 1,
                }
            }
        )
        status, _stdout, _stderr = self.run_controller()
        self.assertEqual(status, 1)
        incident = self.assert_incident(service.PASS_INCIDENT_KIND)
        self.assertIn("could not establish which repository", incident["summary"])
        self.assertIn("the configuration could not be read", incident["summary"])
        self.assertNotIn("describes", incident["summary"])

    def test_acknowledging_leaves_the_status_document_alone(self):
        # `ack` is bookkeeping and nothing else: it resolves one incident and
        # is powerless over the service, so what the failed run recorded stays
        # exactly as it was.
        self.write_plan({"report": {"raw": "", "status": 0}})
        self.run_controller()
        incident = self.assert_incident(service.PASS_INCIDENT_KIND)
        before = self.job().status_path.read_text(encoding="utf-8")
        service.acknowledge_incident(self.job(), incident["incident_id"], "seen")
        self.assertEqual(self.job().status_path.read_text(encoding="utf-8"), before)

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

    def test_a_recycled_pid_does_not_authenticate_a_stale_live_state(self):
        # The hazard the start identity closes: a wrapper that crashed leaves a
        # document whose PID the kernel may since have handed to something
        # else, and `os.kill(pid, 0)` would confirm that stranger is alive.
        # This process is alive and is not the runner, which is exactly the
        # shape a recycled identifier takes.
        job = self.job()
        job.status_path.parent.mkdir(parents=True, exist_ok=True)
        job.status_path.write_text(
            json.dumps(
                {
                    "schema": service.STATUS_SCHEMA,
                    "version": service.STATUS_VERSION,
                    "state": service.STATE_RUNNING,
                    "repository": self.identity,
                    "repo": str(self.repo),
                    "runner_pid": os.getpid(),
                    "runner_identity": "Thu Jan  1 00:00:00 1970",
                }
            ),
            encoding="utf-8",
        )
        snapshot = service.status_snapshot(job)
        self.assertEqual(snapshot["state"], service.STATE_UNKNOWN)
        self.assertIn("different process", snapshot["reason"])

    def test_a_stale_draining_document_is_not_believed(self):
        # Draining is live, so it is held to the runner's identity like the
        # others: a wrapper that died mid-drain leaves no draining runner, and
        # its document must not read as one -- nor as a stopped job.
        job = self.job()
        job.status_path.parent.mkdir(parents=True, exist_ok=True)
        gone = subprocess.Popen([sys.executable, "-c", "pass"])
        gone.wait(timeout=30)
        for runner_pid, identity, reason in (
            (gone.pid, "Thu Jan  1 00:00:00 1970", "not running"),
            (os.getpid(), "Thu Jan  1 00:00:00 1970", "different process"),
        ):
            with self.subTest(reason=reason):
                job.status_path.write_text(
                    json.dumps(
                        {
                            "schema": service.STATUS_SCHEMA,
                            "version": service.STATUS_VERSION,
                            "state": service.STATE_DRAINING,
                            "repository": self.identity,
                            "repo": str(self.repo),
                            "runner_pid": runner_pid,
                            "runner_identity": identity,
                            "pass_pid": runner_pid,
                        }
                    ),
                    encoding="utf-8",
                )
                snapshot = service.status_snapshot(job)
                self.assertEqual(snapshot["state"], service.STATE_UNKNOWN)
                self.assertIn(reason, snapshot["reason"])
                self.assertIsNone(snapshot["runner_pid"])

    def test_a_live_state_with_no_runner_identity_is_not_believed(self):
        # A document that records no identity cannot have its process
        # confirmed, and this boundary fails closed rather than falling back to
        # the bare liveness check it replaced.
        job = self.job()
        job.status_path.parent.mkdir(parents=True, exist_ok=True)
        job.status_path.write_text(
            json.dumps(
                {
                    "schema": service.STATUS_SCHEMA,
                    "version": service.STATUS_VERSION,
                    "state": service.STATE_RUNNING,
                    "repository": self.identity,
                    "repo": str(self.repo),
                    "runner_pid": os.getpid(),
                }
            ),
            encoding="utf-8",
        )
        snapshot = service.status_snapshot(job)
        self.assertEqual(snapshot["state"], service.STATE_UNKNOWN)
        self.assertIn("cannot be confirmed", snapshot["reason"])

    def test_a_start_identity_is_stable_for_one_process(self):
        # The control: the value has to be the same on two reads, or it would
        # reject every live runner rather than only a recycled identifier.
        first = service.process_start_identity(os.getpid())
        self.assertTrue(first)
        self.assertEqual(first, service.process_start_identity(os.getpid()))

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
                    "runner_identity": service.process_start_identity(os.getpid()),
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
