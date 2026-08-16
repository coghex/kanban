"""Unit and fixture tests for the persistent issue approval controller.

Hermetic throughout. Every root the controller writes under is redirected into
a temporary directory, the canonical backend is a fake script on a temporary
`KANBAN_ISSUE_REVIEW_INSTALL_DIR`, and the repositories are temporary `git
init` checkouts whose remotes name repositories nothing here ever contacts. No
test reaches the network, a GitHub account, a reviewer model, or a service
manager.

The fixture runs are real: a real controller process supervises a real backend
child in its own process group, and the lifecycle assertions are made against
what those processes actually did rather than against a mocked loop. The fake
backend takes the same `.git/approve_issues.lock` the real one takes, so a
controller that overlapped two passes would be caught by contention rather than
by inspection.
"""

import ast
import contextlib
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import approve_issues
import approve_issues_service as service


CONTROLLER = Path(__file__).resolve().parent / "approve_issues_service.py"

# Written into every fixture's install directory as `approve_issues.py`. It
# answers the two invocations the controller makes -- `--review-queue` and
# `--check` -- from a plan file the test writes, records every call, and takes
# the canonical approval lock for exactly the passes the real backend takes it
# for. A test asserts nothing about this script's own behaviour; it exists so
# the controller's behaviour can be asserted against a backend that cannot
# review anything.
FAKE_BACKEND = '''#!/usr/bin/env python3
import argparse
import fcntl
import json
import os
import signal
import subprocess
import sys
import time

CALLS = os.environ["FAKE_BACKEND_CALLS"]
PLAN = os.environ["FAKE_BACKEND_PLAN"]
GATE = os.environ["FAKE_BACKEND_GATE"]

ORPHAN = (
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
    parser = argparse.ArgumentParser()
    parser.add_argument("--path", required=True)
    parser.add_argument("--repo")
    parser.add_argument("--legacy-policy")
    parser.add_argument("--log-dir")
    parser.add_argument("--config")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--review-queue", action="store_true")
    parser.add_argument("--check", type=int)
    args = parser.parse_args()

    entry = {
        "mode": "check" if args.check is not None else "queue",
        "issue": args.check,
        "argv": sys.argv[1:],
        "pid": os.getpid(),
        "pgid": os.getpgid(0),
        "ppid": os.getppid(),
        "repo": args.repo,
        "log_dir": args.log_dir,
        "at": time.time(),
        # This process's own signal mask, read without changing it. A
        # controller that held signals across the spawn would show up here as
        # a backend that cannot be interrupted.
        "blocked": sorted(signal.pthread_sigmask(signal.SIG_BLOCK, [])),
    }

    if args.check is not None:
        answer = read_json(GATE, {}).get(str(args.check), False)
        entry["gate"] = answer
        record(entry)
        if answer == "error":
            sys.stderr.write("approve-issues.py error: gh reported a failure\\n")
            return 1
        if answer == "malformed":
            sys.stdout.write("usage: approve-issues.py [-h]\\n")
            return 2
        approved = bool(answer)
        sys.stdout.write(
            json.dumps({"approved": approved, "issue": args.check, "reasons": []}) + "\\n"
        )
        return 0 if approved else 2

    index = len([call for call in recorded() if call["mode"] == "queue"])
    steps = read_json(PLAN, [])
    step = steps[index] if index < len(steps) else {"outcome": "idle"}
    entry["step"] = step

    handle = open(
        os.path.join(args.path, ".git", "approve_issues.lock"), "a+", encoding="utf-8"
    )
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        entry["contention"] = True
        record(entry)
        sys.stderr.write("the canonical approval lock was already held\\n")
        return 1
    handle.seek(0)
    handle.truncate()
    handle.write(json.dumps({"pid": os.getpid(), "mode": "queue"}))
    handle.flush()
    record(entry)

    if step.get("ignore_sigint"):
        signal.signal(signal.SIGINT, signal.SIG_IGN)
    if step.get("spawn_orphan"):
        subprocess.Popen([sys.executable, "-c", ORPHAN, step["spawn_orphan"]])
    if step.get("signal_parent"):
        os.kill(os.getppid(), signal.SIGTERM)
    if step.get("sleep"):
        time.sleep(step["sleep"])
    if step.get("stderr"):
        sys.stderr.write(step["stderr"] + "\\n")
    if "raw" in step:
        sys.stdout.write(step["raw"])
        return step.get("exit", 0)
    if "exit" in step:
        return step["exit"]
    outcome = step.get("outcome", "idle")
    sys.stdout.write(
        json.dumps(
            {
                "schema": "approve-issues-review-queue",
                "version": 1,
                "outcome": outcome,
                "issue": step.get("issue"),
                "model_called": step.get("model_called", False),
                "message": step.get("message", f"fixture {outcome}"),
            },
            sort_keys=True,
        )
        + "\\n"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'''


def wait_until(predicate, *, timeout=20.0, message="condition"):
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


def result_document(outcome, *, issue=None, model_called=False, message="ok"):
    return {
        "schema": service.BACKEND_RESULT_SCHEMA,
        "version": service.BACKEND_RESULT_VERSION,
        "outcome": outcome,
        "issue": issue,
        "model_called": model_called,
        "message": message,
    }


class ApprovalFixture(unittest.TestCase):
    """A temporary HOME, a temporary checkout, and a fake installed backend.

    Every path the controller resolves hangs off `$HOME` or
    `KANBAN_ISSUE_REVIEW_INSTALL_DIR`, both of which are redirected here, so an
    in-process test and a subprocess test see the same redirected world.
    """

    identity = "acme/widgets"
    remote_url = "git@github.com:acme/widgets.git"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.backend_dir = self.root / "backend"
        self.backend_dir.mkdir()
        self.backend = self.backend_dir / "approve_issues.py"
        self.backend.write_text(FAKE_BACKEND, encoding="utf-8")
        self.backend.chmod(0o700)
        self.plan_path = self.root / "plan.json"
        self.calls_path = self.root / "calls.jsonl"
        self.gate_path = self.root / "gate.json"
        self.write_plan([])
        self.write_gate({})
        self.git_config = self.root / "gitconfig"
        self.git_config.write_text("", encoding="utf-8")
        self.repo = self.checkout("widgets", self.remote_url)

        self.env = {
            **os.environ,
            "HOME": str(self.home),
            "KANBAN_ISSUE_REVIEW_INSTALL_DIR": str(self.backend_dir),
            "FAKE_BACKEND_CALLS": str(self.calls_path),
            "FAKE_BACKEND_PLAN": str(self.plan_path),
            "FAKE_BACKEND_GATE": str(self.gate_path),
            "GIT_CONFIG_GLOBAL": str(self.git_config),
            "GIT_CONFIG_NOSYSTEM": "1",
            "PYTHONUNBUFFERED": "1",
        }
        self.env.pop("XDG_CONFIG_HOME", None)
        patched = mock.patch.dict(os.environ, self.env, clear=True)
        patched.start()
        self.addCleanup(patched.stop)
        self.processes = []
        self.addCleanup(self.stop_everything)

    # -- fixture construction ---------------------------------------------

    def checkout(self, name, remote_url):
        path = self.root / name
        path.mkdir()
        environment = {
            **os.environ,
            "GIT_CONFIG_GLOBAL": str(self.root / "gitconfig"),
            "GIT_CONFIG_NOSYSTEM": "1",
        }
        subprocess.run(
            ["git", "init", "-q", str(path)],
            check=True,
            capture_output=True,
            env=environment,
        )
        subprocess.run(
            ["git", "-C", str(path), "remote", "add", "origin", remote_url],
            check=True,
            capture_output=True,
            env=environment,
        )
        return path

    def worktree(self, name="linked"):
        """A linked worktree of this fixture's checkout, committed to first
        because `git worktree add` needs a HEAD."""
        environment = {
            **os.environ,
            "GIT_CONFIG_GLOBAL": str(self.git_config),
            "GIT_CONFIG_NOSYSTEM": "1",
        }

        def git(*arguments, check=True):
            return subprocess.run(
                ["git", "-C", str(self.repo), *arguments],
                check=check,
                capture_output=True,
                env=environment,
            )

        if git("rev-parse", "--verify", "HEAD", check=False).returncode != 0:
            git("config", "user.email", "fixture@example.com")
            git("config", "user.name", "Fixture")
            (self.repo / "README").write_text("fixture\n", encoding="utf-8")
            git("add", "README")
            git("commit", "-q", "-m", "fixture")
        path = self.root / name
        git("worktree", "add", "-q", "-b", name, str(path))
        return path

    def write_plan(self, steps):
        self.plan_path.write_text(json.dumps(steps), encoding="utf-8")

    def write_gate(self, gate):
        self.gate_path.write_text(json.dumps(gate), encoding="utf-8")

    def job(self, repo=None, identity=None):
        return service.job_for_identity(repo or self.repo, identity or self.identity)

    # -- calls -------------------------------------------------------------

    def calls(self):
        if not self.calls_path.exists():
            return []
        return [
            json.loads(line)
            for line in self.calls_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]

    def queue_calls(self):
        return [call for call in self.calls() if call["mode"] == "queue"]

    def check_calls(self):
        return [call for call in self.calls() if call["mode"] == "check"]

    # -- running the controller -------------------------------------------

    def controller_argv(self, *arguments):
        return [sys.executable, str(CONTROLLER), "--path", str(self.repo), *arguments]

    def run_controller(self, *arguments, timeout=60):
        return subprocess.run(
            self.controller_argv(*arguments),
            capture_output=True,
            text=True,
            timeout=timeout,
            env=dict(os.environ),
        )

    def start_controller(self, *arguments, interval="0.02"):
        proc = subprocess.Popen(
            self.controller_argv("run", "--interval", interval, *arguments),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=dict(os.environ),
        )
        self.processes.append(proc)
        return proc

    def finish(self, proc, timeout=60):
        stdout, stderr = proc.communicate(timeout=timeout)
        return proc.returncode, stdout, stderr

    def stop_everything(self):
        for proc in self.processes:
            if proc.poll() is None:
                with contextlib.suppress(Exception):
                    proc.kill()
            with contextlib.suppress(Exception):
                proc.communicate(timeout=10)

    # -- durable state -----------------------------------------------------

    def status(self, job=None):
        return service.status_snapshot(job or self.job())

    def stored_status(self, job=None):
        return service.read_json((job or self.job()).status_path)

    def incidents(self, job=None, **kwargs):
        return [
            document
            for _path, document in service.incident_documents(job or self.job(), **kwargs)
        ]


# ---------------------------------------------------------------------------
# Mirrored contracts
# ---------------------------------------------------------------------------


class MirroredBackendContractTests(unittest.TestCase):
    """The controller reads the backend's result document without importing the
    backend, so the constants it reads it by are copies. These hold the copies
    equal to the originals -- a backend that changes its contract has to change
    this controller in the same commit."""

    def test_the_result_schema_and_version_match_the_backend(self):
        self.assertEqual(service.BACKEND_RESULT_SCHEMA, approve_issues.REVIEW_QUEUE_SCHEMA)
        self.assertEqual(
            service.BACKEND_RESULT_VERSION, approve_issues.REVIEW_QUEUE_SCHEMA_VERSION
        )

    def test_the_result_fields_and_outcomes_match_the_backend(self):
        self.assertEqual(
            service.BACKEND_RESULT_FIELDS, approve_issues.REVIEW_QUEUE_RESULT_FIELDS
        )
        self.assertEqual(service.BACKEND_OUTCOMES, approve_issues.REVIEW_QUEUE_OUTCOMES)
        self.assertEqual(
            service.BACKEND_ISSUE_OUTCOMES, approve_issues.REVIEW_QUEUE_ISSUE_OUTCOMES
        )

    def test_the_lock_file_name_matches_the_backends(self):
        self.assertEqual(service.APPROVAL_LOCK_NAME, approve_issues.APPROVAL_LOCK_NAME)

    def test_the_daemon_owner_mode_matches_what_the_backend_records(self):
        # The refusal keys on this exact mode string, which the backend writes
        # when the untracked background daemon takes the lock.
        self.assertIn(
            'acquire_lock(ctx, mode="daemon")',
            Path(approve_issues.__file__).read_text(encoding="utf-8"),
        )
        self.assertTrue(service.is_legacy_daemon({"mode": "daemon"}))


class MirroredLockResolutionTests(unittest.TestCase):
    """The controller and the backend must resolve one file.

    Compared by running both functions against real checkouts rather than by
    matching source text: the backend resolves a linked worktree's lock through
    the shared Git directory, and a controller that resolved anything else
    would inspect a file nobody ever takes -- silently retiring the start-time
    refusal exactly where solve and review agents actually work.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        # Resolved, because git answers with the real path and the temporary
        # root reaches it through a symlink on macOS. Nothing here is about
        # that difference.
        self.root = Path(self.tmp.name).resolve()
        self.environment = {
            **os.environ,
            "GIT_CONFIG_GLOBAL": str(self.root / "gitconfig"),
            "GIT_CONFIG_NOSYSTEM": "1",
        }
        (self.root / "gitconfig").write_text("", encoding="utf-8")
        self.primary = self.root / "primary"
        self.git("init", "-q", str(self.primary))
        self.git("-C", str(self.primary), "config", "user.email", "fixture@example.com")
        self.git("-C", str(self.primary), "config", "user.name", "Fixture")
        (self.primary / "README").write_text("fixture\n", encoding="utf-8")
        self.git("-C", str(self.primary), "add", "README")
        self.git("-C", str(self.primary), "commit", "-q", "-m", "fixture")
        self.linked = self.root / "linked"
        self.git(
            "-C", str(self.primary), "worktree", "add", "-q", "-b", "side", str(self.linked)
        )

    def git(self, *arguments):
        return subprocess.run(
            ["git", *arguments], check=True, capture_output=True, env=self.environment
        )

    def backend_answer(self, path):
        # `approve_issues.approval_lock_path` reads only `ctx.path`.
        return approve_issues.approval_lock_path(SimpleNamespace(path=path))

    def test_an_ordinary_checkout_resolves_the_same_lock(self):
        self.assertEqual(
            service.approval_lock_path(self.primary), self.backend_answer(self.primary)
        )
        self.assertEqual(
            service.approval_lock_path(self.primary),
            self.primary / ".git" / approve_issues.APPROVAL_LOCK_NAME,
        )

    def test_a_linked_worktree_resolves_the_primary_checkouts_lock(self):
        # `.git` here is a regular file, and the private
        # `.git/worktrees/<name>` the other resolution would answer is not a
        # lock any other checkout can see.
        self.assertFalse((self.linked / ".git").is_dir())
        answer = service.approval_lock_path(self.linked)
        self.assertEqual(answer, self.backend_answer(self.linked))
        self.assertEqual(answer, self.primary / ".git" / approve_issues.APPROVAL_LOCK_NAME)
        self.assertEqual(answer, service.approval_lock_path(self.primary))

    def test_a_linked_worktree_shares_the_primary_checkouts_run_lock(self):
        # The checkout lock exists to catch one checkout started twice. A
        # linked worktree is that same checkout, and solve and review agents
        # work in linked worktrees, so it has to resolve the same file.
        self.assertEqual(
            service.checkout_lock_path(self.linked),
            service.checkout_lock_path(self.primary),
        )
        self.assertEqual(
            service.checkout_lock_path(self.linked),
            self.primary / ".git" / service.RUN_LOCK_NAME,
        )

    def test_a_checkout_with_no_resolvable_shared_directory_fails_closed(self):
        broken = self.root / "broken"
        broken.mkdir()
        (broken / ".git").write_text("gitdir: /nowhere/at/all\n", encoding="utf-8")
        with self.assertRaises(service.ServiceError) as raised:
            service.approval_lock_path(broken)
        self.assertIn("shared Git directory", str(raised.exception))

    def test_a_daemon_holding_the_primary_lock_is_seen_from_the_linked_worktree(self):
        holder = LockHolder(self.linked, "daemon")
        self.addCleanup(holder.close)
        self.assertEqual(holder.path.parent, self.primary / ".git")
        owner = service.approval_lock_owner(self.primary)
        self.assertTrue(service.is_legacy_daemon(owner))
        with self.assertRaises(service.ServiceError):
            service.require_no_legacy_daemon(self.linked)
        with self.assertRaises(service.ServiceError):
            service.require_no_legacy_daemon(self.primary)


# ---------------------------------------------------------------------------
# Identity and partitioning
# ---------------------------------------------------------------------------


class RepositoryIdentityTests(unittest.TestCase):
    def test_case_only_spellings_name_one_runtime(self):
        identities = {
            service.normalize_identity(value)
            for value in (
                "acme/widgets",
                "ACME/Widgets",
                "git@github.com:Acme/WIDGETS.git",
                "https://github.com/acme/widgets",
            )
        }
        self.assertEqual(identities, {"acme/widgets"})
        self.assertEqual(len({service.repository_slug(i) for i in identities}), 1)

    def test_unsupported_remotes_have_no_identity(self):
        for value in ("git@gitlab.com:acme/widgets.git", "/tmp/acme/widgets.git", ""):
            with self.subTest(value=value):
                with self.assertRaises(service.ServiceError):
                    service.normalize_identity(value)

    def test_slugs_are_injective_and_filename_safe(self):
        identities = [
            "acme/widgets",
            "acme/wid-gets",
            "acme/wid.gets",
            "acme/wid--gets",
            "acme/wid-dgets",
            "ac-me/widgets",
            "ac.me/widgets",
            "o" * 39 + "/" + "n" * 100,
            "o" * 200 + "/" + "-" * 200,
            "o" * 200 + "/" + "." * 200,
        ]
        slugs = {}
        for identity in identities:
            slug = service.repository_slug(identity)
            self.assertTrue(slug)
            self.assertRegex(slug, r"\A[A-Za-z0-9._-]+\Z")
            self.assertLess(len(slug) + len("status.json") + 1, 255)
            self.assertNotIn(slug, slugs, identity)
            slugs[slug] = identity
        self.assertEqual(len(slugs), len(identities))


class PerIdentityPartitioningTests(ApprovalFixture):
    def test_two_repositories_share_no_runtime_path(self):
        first = self.job(identity="acme/widgets")
        second = self.job(identity="acme/gadgets")
        for attribute in (
            "runtime_dir",
            "incident_dir",
            "status_path",
            "barrier_path",
            "lock_path",
            "log_dir",
            "service_log_path",
        ):
            with self.subTest(attribute=attribute):
                self.assertNotEqual(
                    getattr(first, attribute), getattr(second, attribute)
                )

    def test_no_configuration_can_move_the_run_lock(self):
        # The lock is what makes one identity run one controller. A root a
        # caller could move is a root that lets two runs both start, each
        # taking its own lock, so this root answers to `$HOME` and to nothing
        # else. Every variable below is one a caller controls; none of them is
        # a knob this service has.
        expected = service.run_lock_path(service.repository_slug(self.identity))
        with mock.patch.dict(
            os.environ,
            {
                "KANBAN_ISSUE_APPROVAL_INSTALL_DIR": str(self.root / "elsewhere"),
                "KANBAN_DRAINER_INSTALL_DIR": str(self.root / "elsewhere"),
                "KANBAN_ISSUE_REVIEW_INSTALL_DIR": str(self.root / "elsewhere"),
            },
        ):
            self.assertEqual(self.job().lock_path, expected)
            self.assertEqual(service.service_root(), expected.parent.parent)

    def test_the_checkout_lock_cannot_be_moved_by_the_environment_at_all(self):
        # The identity lock is under `$HOME`, which a process chooses. The
        # checkout lock is in the repository, which it does not.
        expected = service.checkout_lock_path(self.repo)
        self.assertEqual(expected, self.repo / ".git" / service.RUN_LOCK_NAME)
        # Beside the backend's lock but never the same file: the two are held
        # for different things.
        self.assertNotEqual(expected, service.approval_lock_path(self.repo))
        with mock.patch.dict(
            os.environ,
            {
                "HOME": str(self.root / "another-home"),
                "KANBAN_ISSUE_APPROVAL_INSTALL_DIR": str(self.root / "elsewhere"),
            },
        ):
            self.assertEqual(service.checkout_lock_path(self.repo), expected)
            # ... while the identity lock really did move, which is why the
            # checkout lock has to exist.
            self.assertNotEqual(self.job().lock_path, expected)

    def test_the_run_lock_does_not_follow_a_relocated_runtime(self):
        # IAQ-3 owns installation and may relocate the runtime. If the lock
        # moved with it, two installations of one repository would both run.
        expected = self.job().lock_path
        with mock.patch.object(
            service, "runtime_root", return_value=self.root / "another-runtime"
        ):
            relocated = self.job()
        self.assertEqual(relocated.lock_path, expected)
        self.assertNotEqual(relocated.runtime_dir, self.job().runtime_dir)

    def test_the_run_lock_is_named_by_identity_rather_than_by_checkout(self):
        # Two clones of one GitHub repository are one canonical identity, so
        # they must contend rather than each taking a lock of their own.
        other_clone = self.root / "second-clone"
        other_clone.mkdir()
        first = service.job_for_identity(self.repo, self.identity)
        second = service.job_for_identity(other_clone, self.identity)
        self.assertEqual(first.lock_path, second.lock_path)
        self.assertNotEqual(
            first.lock_path, self.job(identity="acme/gadgets").lock_path
        )

    def test_the_namespace_is_not_the_pr_drainers(self):
        job = self.job()
        self.assertIn("issue-approval", str(job.runtime_dir))
        self.assertIn("issue-approval", str(job.log_dir))
        for path in (job.runtime_dir, job.log_dir, job.status_path):
            self.assertNotIn("pr-drainer", str(path))

    def test_one_repositorys_incidents_are_invisible_to_the_other(self):
        first = self.job(identity="acme/widgets")
        second = self.job(identity="acme/gadgets")
        service.record_error_incident(first, summary="first broke", detail=None)
        self.assertEqual(len(self.incidents(first)), 1)
        self.assertEqual(self.incidents(second), [])
        self.assertEqual(self.status(second)["open_incidents"], [])

    def test_an_incident_recorded_for_another_identity_is_not_adopted(self):
        # Same directory, foreign document: attribution is on the recorded
        # canonical identity, not on where the file happens to sit.
        job = self.job()
        job.incident_dir.mkdir(parents=True, exist_ok=True)
        service.atomic_write_json(
            job.incident_dir / "incident-20260101T000000Z-1.json",
            {
                "schema": service.INCIDENT_SCHEMA,
                "version": service.INCIDENT_VERSION,
                "status": "open",
                "repository": "acme/gadgets",
                "kind": service.ERROR_INCIDENT_KIND,
                "summary": "not this repository's",
            },
        )
        self.assertEqual(self.incidents(job), [])

    def test_a_requested_identity_that_is_not_this_checkouts_is_refused(self):
        job = service.resolve_job(self.repo)
        self.assertEqual(job.identity, self.identity)
        service.require_requested_identity(job, "ACME/Widgets")
        with self.assertRaises(service.ServiceError) as raised:
            service.require_requested_identity(job, "acme/gadgets")
        self.assertIn("acme/gadgets", str(raised.exception))


# ---------------------------------------------------------------------------
# Backend resolution
# ---------------------------------------------------------------------------


class BackendResolutionTests(ApprovalFixture):
    """The canonical resolution contract of docs/agent-workflow-contract.md
    sections 2.3 and 3, and its fail-closed behaviour."""

    def record_path(self):
        path = self.home / "Library" / "Application Support" / "kanban" / "issue-review" / "config.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        return path

    def test_the_environment_override_wins(self):
        record = self.record_path()
        other = self.root / "other"
        other.mkdir()
        (other / "approve_issues.py").write_text("", encoding="utf-8")
        service.atomic_write_json(record, {"backend_path": str(other / "approve_issues.py")})
        self.assertEqual(service.resolve_backend(), self.backend)

    def test_a_recorded_absolute_backend_path_is_used(self):
        record = self.record_path()
        service.atomic_write_json(record, {"backend_path": str(self.backend)})
        with mock.patch.dict(os.environ, {kanban_env(): ""}):
            self.assertEqual(service.resolve_backend(), self.backend)

    def test_a_record_naming_no_backend_falls_back_to_its_own_directory(self):
        record = self.record_path()
        service.atomic_write_json(record, {"config_path": "/somewhere/config.toml"})
        installed = record.parent / "approve_issues.py"
        installed.write_text("", encoding="utf-8")
        with mock.patch.dict(os.environ, {kanban_env(): ""}):
            self.assertEqual(service.resolve_backend(), installed)

    def test_a_selected_backend_that_is_missing_fails_rather_than_falling_through(self):
        record = self.record_path()
        installed = record.parent / "approve_issues.py"
        installed.write_text("", encoding="utf-8")
        service.atomic_write_json(record, {"backend_path": str(self.root / "gone.py")})
        with mock.patch.dict(os.environ, {kanban_env(): ""}):
            with self.assertRaises(service.ServiceError) as raised:
                service.resolve_backend()
        self.assertIn("gone.py", str(raised.exception))
        self.assertIn("install_issue_review.py", str(raised.exception))

    def test_a_relative_recorded_backend_is_refused(self):
        record = self.record_path()
        service.atomic_write_json(record, {"backend_path": "tools/approve_issues.py"})
        with mock.patch.dict(os.environ, {kanban_env(): ""}):
            with self.assertRaises(service.ServiceError) as raised:
                service.resolve_backend()
        self.assertIn("absolute backend_path", str(raised.exception))

    def test_a_wrong_typed_recorded_backend_is_refused(self):
        record = self.record_path()
        service.atomic_write_json(record, {"backend_path": 17})
        with mock.patch.dict(os.environ, {kanban_env(): ""}):
            with self.assertRaises(service.ServiceError):
                service.resolve_backend()

    def test_an_unreadable_record_is_refused(self):
        record = self.record_path()
        record.write_text("{not json", encoding="utf-8")
        with mock.patch.dict(os.environ, {kanban_env(): ""}):
            with self.assertRaises(service.ServiceError) as raised:
                service.resolve_backend()
        self.assertIn("unreadable", str(raised.exception))

    def test_a_record_that_is_not_an_object_is_refused(self):
        record = self.record_path()
        record.write_text("[1, 2, 3]", encoding="utf-8")
        with mock.patch.dict(os.environ, {kanban_env(): ""}):
            with self.assertRaises(service.ServiceError) as raised:
                service.resolve_backend()
        self.assertIn("not a JSON object", str(raised.exception))

    def test_no_record_and_no_installation_names_the_repair(self):
        with mock.patch.dict(os.environ, {kanban_env(): ""}):
            with self.assertRaises(service.ServiceError) as raised:
                service.resolve_backend()
        self.assertIn("Canonical issue reviewer was not found", str(raised.exception))

    def test_a_run_fails_closed_before_it_writes_anything(self):
        # Resolution precedes the run lock, the status document, and any child.
        with mock.patch.dict(os.environ, {kanban_env(): str(self.root / "absent")}):
            result = self.run_controller("run", "--interval", "0.01")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Canonical issue reviewer was not found", result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertFalse(self.job().status_path.exists())


def kanban_env():
    return service.kanban_config.ISSUE_REVIEW_INSTALL_DIR_ENV


# ---------------------------------------------------------------------------
# Result documents
# ---------------------------------------------------------------------------


class BackendResultParsingTests(unittest.TestCase):
    def test_every_ordinary_outcome_is_read(self):
        for outcome, issue in (
            ("idle", None),
            ("busy", None),
            ("advanced", 7),
            ("changes_requested", 7),
            ("retry", 7),
        ):
            with self.subTest(outcome=outcome):
                document = result_document(outcome, issue=issue)
                self.assertEqual(
                    service.parse_backend_result(json.dumps(document)), document
                )

    def test_an_absent_document_is_refused(self):
        with self.assertRaises(service.BackendFailure) as raised:
            service.parse_backend_result("   \n")
        self.assertIn("no result document", str(raised.exception))

    def test_text_that_is_not_json_is_refused(self):
        with self.assertRaises(service.BackendFailure):
            service.parse_backend_result("approve-issues.py error: boom")

    def test_a_document_that_is_not_an_object_is_refused(self):
        with self.assertRaises(service.BackendFailure):
            service.parse_backend_result("[1, 2, 3]")

    def test_an_unknown_schema_is_refused(self):
        document = result_document("idle")
        document["schema"] = "some-other-result"
        with self.assertRaises(service.BackendFailure) as raised:
            service.parse_backend_result(json.dumps(document))
        self.assertIn("unknown schema", str(raised.exception))

    def test_an_unknown_version_is_refused(self):
        for version in (2, 0, "1", 1.0, True, None):
            with self.subTest(version=version):
                document = result_document("idle")
                document["version"] = version
                with self.assertRaises(service.BackendFailure) as raised:
                    service.parse_backend_result(json.dumps(document))
                self.assertIn("unknown schema version", str(raised.exception))

    def test_a_missing_or_additional_field_is_refused(self):
        document = result_document("idle")
        del document["message"]
        with self.assertRaises(service.BackendFailure):
            service.parse_backend_result(json.dumps(document))
        document = result_document("idle")
        document["extra"] = True
        with self.assertRaises(service.BackendFailure):
            service.parse_backend_result(json.dumps(document))

    def test_an_unknown_outcome_is_refused(self):
        with self.assertRaises(service.BackendFailure) as raised:
            service.parse_backend_result(json.dumps(result_document("finished")))
        self.assertIn("unknown outcome", str(raised.exception))

    def test_an_issue_outcome_requires_a_positive_number(self):
        for issue in (None, 0, -1, True, "7", 7.0):
            with self.subTest(issue=issue):
                document = result_document("changes_requested", issue=issue)
                with self.assertRaises(service.BackendFailure):
                    service.parse_backend_result(json.dumps(document))

    def test_a_queue_outcome_carries_no_number(self):
        for outcome in ("idle", "busy"):
            with self.subTest(outcome=outcome):
                document = result_document(outcome, issue=4)
                with self.assertRaises(service.BackendFailure):
                    service.parse_backend_result(json.dumps(document))

    def test_a_non_boolean_model_claim_is_refused(self):
        document = result_document("idle")
        document["model_called"] = "no"
        with self.assertRaises(service.BackendFailure):
            service.parse_backend_result(json.dumps(document))

    def test_an_empty_message_is_refused(self):
        document = result_document("idle", message="  ")
        with self.assertRaises(service.BackendFailure):
            service.parse_backend_result(json.dumps(document))


class GateResultParsingTests(unittest.TestCase):
    def test_the_two_ordinary_exits_are_read(self):
        approved = json.dumps({"approved": True, "issue": 5})
        refused = json.dumps({"approved": False, "issue": 5})
        self.assertTrue(service.parse_gate_result(approved, 5, 0))
        self.assertFalse(service.parse_gate_result(refused, 5, 2))

    def test_a_document_disagreeing_with_the_exit_is_refused(self):
        with self.assertRaises(service.BackendFailure):
            service.parse_gate_result(json.dumps({"approved": False, "issue": 5}), 5, 0)
        with self.assertRaises(service.BackendFailure):
            service.parse_gate_result(json.dumps({"approved": True, "issue": 5}), 5, 2)

    def test_an_answer_about_another_issue_is_refused(self):
        with self.assertRaises(service.BackendFailure) as raised:
            service.parse_gate_result(json.dumps({"approved": True, "issue": 6}), 5, 0)
        self.assertIn("#6", str(raised.exception))

    def test_an_absent_or_unreadable_answer_is_refused(self):
        # A usage error exits 2 with nothing on stdout, which must never read
        # as "not approved yet".
        for stdout in ("", "usage: approve-issues.py [-h]", "null"):
            with self.subTest(stdout=stdout):
                with self.assertRaises(service.BackendFailure):
                    service.parse_gate_result(stdout, 5, 2)

    def test_a_non_boolean_approval_is_refused(self):
        with self.assertRaises(service.BackendFailure):
            service.parse_gate_result(json.dumps({"approved": "yes", "issue": 5}), 5, 0)


class ExitClassificationTests(unittest.TestCase):
    def test_a_signal_and_a_code_are_worded_apart(self):
        self.assertIn("signal 9", service.classify_exit(-9))
        self.assertIn("code 3", service.classify_exit(3))


class BackoffTests(unittest.TestCase):
    def test_the_wait_doubles_and_then_stops_doubling(self):
        controller = service.Controller.__new__(service.Controller)
        controller.interval = 2.0
        controller._backoff_steps = 0
        waits = []
        for _ in range(8):
            waits.append(controller.backoff_seconds())
            controller._backoff_steps += 1
        self.assertEqual(waits[:4], [2.0, 4.0, 8.0, 16.0])
        self.assertEqual(
            max(waits), 2.0 * service.BACKOFF_CEILING_MULTIPLIER
        )
        self.assertTrue(all(later >= earlier for earlier, later in zip(waits, waits[1:])))


# ---------------------------------------------------------------------------
# Host support
# ---------------------------------------------------------------------------


class HostSupportTests(unittest.TestCase):
    def test_a_posix_host_is_supported(self):
        service.require_supported_host()

    def test_a_host_without_flock_is_refused_with_a_diagnostic(self):
        with mock.patch.object(service, "fcntl", None):
            with self.assertRaises(service.ServiceError) as raised:
                service.require_supported_host()
        self.assertIn("only on POSIX hosts", str(raised.exception))
        self.assertIn("fcntl.flock", str(raised.exception))

    def test_a_non_posix_host_is_refused_with_a_diagnostic(self):
        with mock.patch.object(service.os, "name", "nt"):
            with self.assertRaises(service.ServiceError) as raised:
                service.require_supported_host()
        self.assertIn("POSIX", str(raised.exception))


# ---------------------------------------------------------------------------
# Atomic runtime documents
# ---------------------------------------------------------------------------


class AtomicWriteTests(ApprovalFixture):
    def test_a_reader_interleaved_with_writes_never_sees_a_partial_document(self):
        path = self.root / "runtime" / "status.json"
        service.atomic_write_json(path, {"state": "starting"})
        failures = []
        stop = threading.Event()

        def read_forever():
            while not stop.is_set():
                try:
                    json.loads(path.read_text(encoding="utf-8"))
                except FileNotFoundError:
                    failures.append("the document vanished mid-write")
                except (json.JSONDecodeError, UnicodeDecodeError) as exc:
                    failures.append(f"partial document observed: {exc}")

        reader = threading.Thread(target=read_forever)
        reader.start()
        try:
            for index in range(200):
                service.atomic_write_json(
                    path,
                    {
                        "state": "running",
                        "index": index,
                        # Long enough that a non-atomic write would be observed
                        # part-way through rather than by luck.
                        "padding": "x" * (index * 200),
                    },
                )
        finally:
            stop.set()
            reader.join(timeout=10)
        self.assertEqual(failures, [])

    def test_every_runtime_document_is_written_through_the_atomic_writer(self):
        job = self.job()
        written = []
        real = service.atomic_write_json

        def recorder(path, value):
            written.append(Path(path))
            real(path, value)

        controller = service.Controller(
            job, backend=self.backend, interval=0.0, legacy_policy="dual"
        )
        with mock.patch.object(service, "atomic_write_json", recorder):
            controller.write_status(service.STATE_RUNNING, message="ok")
            service.write_barrier(job, 5)
            incident = service.ensure_barrier_incident(job, 5, "detail")
            error = service.record_error_incident(job, summary="broke", detail=None)
        self.assertIn(job.status_path, written)
        self.assertIn(job.barrier_path, written)
        self.assertIn(Path(incident["path"]), written)
        self.assertIn(Path(error["path"]), written)


# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------


class StatusClassificationTests(ApprovalFixture):
    def write_status(self, **overrides):
        job = self.job()
        document = {
            "schema": service.STATUS_SCHEMA,
            "version": service.STATUS_VERSION,
            "state": service.STATE_RUNNING,
            "repository": self.identity,
            "repo": str(self.repo),
            "runner_pid": os.getpid(),
            "message": "healthy",
        }
        document.update(overrides)
        service.atomic_write_json(job.status_path, document)
        return job

    def test_a_healthy_document_is_believed(self):
        job = self.write_status()
        snapshot = service.status_snapshot(job)
        self.assertEqual(snapshot["state"], service.STATE_RUNNING)
        self.assertIsNone(snapshot["reason"])
        self.assertEqual(snapshot["repository"], self.identity)
        self.assertEqual(snapshot["schema"], service.STATUS_SCHEMA)
        self.assertEqual(snapshot["version"], service.STATUS_VERSION)

    def test_an_absent_document_is_unknown(self):
        snapshot = self.status()
        self.assertEqual(snapshot["state"], service.STATE_UNKNOWN)
        self.assertIn("no status document", snapshot["reason"])

    def test_an_unreadable_document_is_unknown(self):
        job = self.job()
        job.runtime_dir.mkdir(parents=True, exist_ok=True)
        job.status_path.write_text("{ not json", encoding="utf-8")
        snapshot = service.status_snapshot(job)
        self.assertEqual(snapshot["state"], service.STATE_UNKNOWN)
        self.assertIn("could not be read", snapshot["reason"])

    def test_another_schema_or_version_is_unknown(self):
        job = self.write_status(schema="kanban-pr-drainer-status")
        self.assertEqual(service.status_snapshot(job)["state"], service.STATE_UNKNOWN)
        for version in (2, "1", 1.0, True):
            with self.subTest(version=version):
                job = self.write_status(version=version)
                snapshot = service.status_snapshot(job)
                self.assertEqual(snapshot["state"], service.STATE_UNKNOWN)
                self.assertIn("version", snapshot["reason"])

    def test_a_foreign_repositorys_document_is_unknown(self):
        job = self.write_status(repository="acme/gadgets")
        snapshot = service.status_snapshot(job)
        self.assertEqual(snapshot["state"], service.STATE_UNKNOWN)
        self.assertIn("acme/gadgets", snapshot["reason"])

    def test_a_live_state_under_a_dead_runner_is_unknown(self):
        for state in sorted(service.LIVE_STATES):
            with self.subTest(state=state):
                job = self.write_status(state=state, runner_pid=_dead_pid())
                snapshot = service.status_snapshot(job)
                self.assertEqual(snapshot["state"], service.STATE_UNKNOWN)
                self.assertIn("not running", snapshot["reason"])
                self.assertIsNone(snapshot["runner_pid"])

    def test_a_terminal_state_survives_the_process_that_wrote_it(self):
        for state in sorted(service.TERMINAL_STATES):
            with self.subTest(state=state):
                job = self.write_status(state=state, runner_pid=_dead_pid())
                self.assertEqual(service.status_snapshot(job)["state"], state)

    def test_a_state_this_reader_does_not_know_is_unknown(self):
        job = self.write_status(state="draining")
        self.assertEqual(service.status_snapshot(job)["state"], service.STATE_UNKNOWN)

    def test_an_unreadable_barrier_record_is_never_reported_as_no_barrier(self):
        job = self.write_status(state=service.STATE_STOPPED)
        job.barrier_path.write_text("{ not json", encoding="utf-8")
        snapshot = service.status_snapshot(job)
        self.assertIsNone(snapshot["barrier_issue"])
        self.assertIsNotNone(snapshot["barrier_unreadable"])
        self.assertEqual(snapshot["state"], service.STATE_UNKNOWN)

    def test_a_stopped_service_still_reports_its_durable_barrier(self):
        job = self.write_status(state=service.STATE_STOPPED, runner_pid=_dead_pid())
        service.write_barrier(job, 12)
        service.ensure_barrier_incident(job, 12, "detail")
        snapshot = service.status_snapshot(job)
        self.assertEqual(snapshot["state"], service.STATE_STOPPED)
        self.assertEqual(snapshot["barrier_issue"], 12)
        self.assertEqual(snapshot["open_incident"]["summary"], "Issue #12 requests changes")

    def test_status_repairs_nothing(self):
        before = _tree(self.home)
        result = self.run_controller("--json", "status")
        self.assertEqual(result.returncode, 0, result.stderr)
        snapshot = json.loads(result.stdout)
        self.assertEqual(snapshot["state"], service.STATE_UNKNOWN)
        self.assertEqual(snapshot["repository"], self.identity)
        # Not one directory, status document, or incident was created by
        # asking what the state is.
        self.assertEqual(_tree(self.home), before)

    def test_status_leaves_an_unreadable_document_exactly_as_it_found_it(self):
        job = self.job()
        job.runtime_dir.mkdir(parents=True, exist_ok=True)
        job.status_path.write_text("{ not json", encoding="utf-8")
        before = _tree(self.home)
        result = self.run_controller("--json", "status")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(job.status_path.read_text(encoding="utf-8"), "{ not json")
        self.assertEqual(_tree(self.home), before)


_REAPED_PID = None


def _dead_pid():
    """A PID that is certainly not running: one this process reaped itself.

    Resolved once and reused: a reaped child's PID stays free for as long as
    this suite runs, and spawning a process per assertion would cost more than
    the assertion.
    """
    global _REAPED_PID
    if _REAPED_PID is None:
        proc = subprocess.Popen([sys.executable, "-c", "pass"])
        proc.wait()
        _REAPED_PID = proc.pid
    return _REAPED_PID


def _tree(root):
    return {
        str(path.relative_to(root)): (path.is_dir() or path.stat().st_size)
        for path in sorted(root.rglob("*"))
    }


# ---------------------------------------------------------------------------
# The barrier record and its warning
# ---------------------------------------------------------------------------


class BarrierRecordTests(ApprovalFixture):
    def test_an_absent_record_means_no_barrier(self):
        self.assertIsNone(service.read_barrier(self.job()))

    def test_a_written_record_round_trips(self):
        job = self.job()
        service.write_barrier(job, 42)
        self.assertEqual(service.read_barrier(job), 42)
        service.clear_barrier(job)
        self.assertIsNone(service.read_barrier(job))

    def test_an_unusable_record_refuses_rather_than_reading_as_absent(self):
        job = self.job()
        job.runtime_dir.mkdir(parents=True, exist_ok=True)
        for content in (
            "{ not json",
            json.dumps({"schema": "other", "version": 1, "repository": self.identity, "issue": 5}),
            json.dumps({"schema": service.BARRIER_SCHEMA, "version": 2, "repository": self.identity, "issue": 5}),
            json.dumps({"schema": service.BARRIER_SCHEMA, "version": True, "repository": self.identity, "issue": 5}),
            json.dumps({"schema": service.BARRIER_SCHEMA, "version": 1, "repository": "acme/gadgets", "issue": 5}),
            json.dumps({"schema": service.BARRIER_SCHEMA, "version": 1, "repository": self.identity, "issue": 0}),
            json.dumps({"schema": service.BARRIER_SCHEMA, "version": 1, "repository": self.identity, "issue": "5"}),
        ):
            with self.subTest(content=content[:40]):
                job.barrier_path.write_text(content, encoding="utf-8")
                with self.assertRaises(service.ServiceError):
                    service.read_barrier(job)


class BarrierIncidentTests(ApprovalFixture):
    def test_repeated_polls_keep_one_open_warning(self):
        job = self.job()
        first = service.ensure_barrier_incident(job, 5, "detail")
        for _ in range(5):
            again = service.ensure_barrier_incident(job, 5, "detail")
            self.assertEqual(again["incident_id"], first["incident_id"])
        self.assertEqual(len(self.incidents(job, open_only=True)), 1)

    def test_the_warning_names_the_issue_at_warning_severity(self):
        incident = service.ensure_barrier_incident(self.job(), 254, "detail")
        self.assertEqual(incident["summary"], "Issue #254 requests changes")
        self.assertEqual(incident["severity"], service.SEVERITY_WARNING)
        self.assertEqual(incident["issue"], 254)
        self.assertEqual(incident["kind"], service.BARRIER_INCIDENT_KIND)
        self.assertEqual(incident["schema"], service.INCIDENT_SCHEMA)
        self.assertEqual(incident["version"], service.INCIDENT_VERSION)
        self.assertEqual(incident["repository"], self.identity)

    def test_an_acknowledged_warning_is_reopened_rather_than_duplicated(self):
        job = self.job()
        first = service.ensure_barrier_incident(job, 5, "detail")
        service.acknowledge_incident(job, first["incident_id"], "seen")
        self.assertEqual(self.incidents(job, open_only=True), [])
        second = service.ensure_barrier_incident(job, 5, "detail")
        self.assertNotEqual(second["incident_id"], first["incident_id"])
        self.assertEqual(len(self.incidents(job, open_only=True)), 1)

    def test_acknowledging_does_not_touch_the_barrier_record(self):
        job = self.job()
        service.write_barrier(job, 5)
        incident = service.ensure_barrier_incident(job, 5, "detail")
        service.acknowledge_incident(job, incident["incident_id"], None)
        self.assertEqual(service.read_barrier(job), 5)

    def test_resolving_clears_only_the_named_issues_warning(self):
        job = self.job()
        service.ensure_barrier_incident(job, 5, "detail")
        service.ensure_barrier_incident(job, 9, "detail")
        service.resolve_barrier_incidents(job, 5, "approved")
        open_issues = {
            document["issue"] for document in self.incidents(job, open_only=True)
        }
        self.assertEqual(open_issues, {9})

    def test_an_unknown_incident_id_is_refused(self):
        job = self.job()
        with self.assertRaises(service.ServiceError):
            service.acknowledge_incident(job, "../../etc/passwd", None)
        with self.assertRaises(service.ServiceError):
            service.acknowledge_incident(job, "incident-20260101T000000Z-1", None)
        with self.assertRaises(service.ServiceError):
            service.acknowledge_incident(job, None, None)


# ---------------------------------------------------------------------------
# The canonical approval lock at start time
# ---------------------------------------------------------------------------


class LockHolder:
    """Another process holding the canonical approval lock, as the backend and
    the untracked legacy daemon both hold it.

    Resolved through the same function the controller uses, so a holder started
    against a linked worktree really takes the primary checkout's lock rather
    than a private file beside it.
    """

    def __init__(self, repo, mode):
        path = service.approval_lock_path(repo)
        ready = path.with_name(f"holder-{mode}-ready")
        source = (
            "import fcntl, json, os, sys, time\n"
            "handle = open(sys.argv[1], 'a+', encoding='utf-8')\n"
            "fcntl.flock(handle.fileno(), fcntl.LOCK_EX)\n"
            "handle.seek(0); handle.truncate()\n"
            "handle.write(json.dumps({'pid': os.getpid(), 'mode': sys.argv[3]}))\n"
            "handle.flush()\n"
            "open(sys.argv[2], 'w').write('ready')\n"
            "time.sleep(300)\n"
        )
        self.proc = subprocess.Popen(
            [sys.executable, "-c", source, str(path), str(ready), mode]
        )
        wait_until(ready.exists, message="the lock holder to take the lock")
        self.path = path

    def alive(self):
        return self.proc.poll() is None

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait(timeout=10)


class ApprovalLockInspectionTests(ApprovalFixture):
    def test_a_free_lock_has_no_owner_and_is_not_created_by_asking(self):
        self.assertIsNone(service.approval_lock_owner(self.repo))
        self.assertFalse((self.repo / ".git" / "approve_issues.lock").exists())

    def test_a_checkout_with_no_resolvable_shared_directory_refuses_to_answer(self):
        # Reporting an unresolvable lock as "nobody holds it" would silently
        # retire the start-time refusal.
        broken = self.root / "broken"
        broken.mkdir()
        (broken / ".git").write_text("gitdir: /elsewhere\n", encoding="utf-8")
        with self.assertRaises(service.ServiceError) as raised:
            service.approval_lock_owner(broken)
        self.assertIn("shared Git directory", str(raised.exception))

    def test_the_legacy_daemon_is_recognised_and_refused(self):
        holder = LockHolder(self.repo, "daemon")
        self.addCleanup(holder.close)
        owner = service.approval_lock_owner(self.repo)
        self.assertTrue(service.is_legacy_daemon(owner))
        self.assertIn("background approval daemon", service.describe_lock_owner(owner))
        with self.assertRaises(service.ServiceError) as raised:
            service.require_no_legacy_daemon(self.repo)
        self.assertIn("background approval daemon", str(raised.exception))
        self.assertIn("never adopts or terminates it", str(raised.exception))

    def test_the_refusal_neither_adopts_nor_signals_the_daemon(self):
        holder = LockHolder(self.repo, "daemon")
        self.addCleanup(holder.close)
        recorded = holder.path.read_text(encoding="utf-8")
        with self.assertRaises(service.ServiceError):
            service.require_no_legacy_daemon(self.repo)
        # Still running, still holding, and its own metadata untouched: the
        # refusal is a diagnostic, not a takeover.
        self.assertTrue(holder.alive())
        self.assertEqual(holder.path.read_text(encoding="utf-8"), recorded)
        self.assertTrue(service.is_legacy_daemon(service.approval_lock_owner(self.repo)))

    def test_ordinary_contention_is_not_a_start_time_refusal(self):
        # An interactive review or another queue pass holding the lock is the
        # normal `busy` outcome the poll loop backs off on, not a conflict.
        for mode in ("single", "queue", "rereview", "batch"):
            with self.subTest(mode=mode):
                holder = LockHolder(self.repo, mode)
                try:
                    service.require_no_legacy_daemon(self.repo)
                finally:
                    holder.close()

    def test_a_legacy_daemon_stops_run_before_it_writes_or_spawns(self):
        holder = LockHolder(self.repo, "daemon")
        self.addCleanup(holder.close)
        result = self.run_controller("run", "--interval", "0.01")
        self.assertEqual(result.returncode, 1)
        self.assertIn("background approval daemon", result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertFalse(self.job().status_path.exists())
        self.assertEqual(self.incidents(), [])
        self.assertTrue(holder.alive())


# ---------------------------------------------------------------------------
# One run per identity
# ---------------------------------------------------------------------------


class SingleRunTests(ApprovalFixture):
    def test_a_second_run_is_refused_without_touching_the_first(self):
        self.write_plan([{"outcome": "idle"}])
        first = self.start_controller()
        wait_until(lambda: len(self.queue_calls()) >= 2, message="the first run to poll")

        second = subprocess.Popen(
            self.controller_argv("run", "--interval", "0.01"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=dict(os.environ),
        )
        self.processes.append(second)
        _out, err = second.communicate(timeout=60)
        self.assertEqual(second.returncode, 1)
        self.assertIn("already running", err)
        self.assertIn(self.identity, err)

        # It spawned no backend of its own -- every recorded call names the
        # first run as its parent -- and it opened no incident. The status
        # document still records the first run's ownership, which is the thing
        # a second writer would have taken over.
        self.assertNotIn(second.pid, {call["ppid"] for call in self.calls()})
        self.assertEqual(self.incidents(), [])
        stored = wait_until(
            lambda: self.stored_status(), message="the first run's status document"
        )
        self.assertEqual(stored["runner_pid"], first.pid)
        self.assertIn(stored["state"], service.LIVE_STATES)

        first.send_signal(signal.SIGTERM)
        code, _out, _err = self.finish(first)
        self.assertEqual(code, 0)

    def test_a_second_run_under_a_different_home_is_refused_too(self):
        # `$HOME` is a process's to choose, so an identity lock anchored to it
        # is not by itself proof of a single run: two invocations for one
        # checkout would take two locks, both start, and alternate passes as
        # each released the canonical approval lock between issues. The
        # checkout lock lives in the repository instead, which no environment
        # can move.
        self.write_plan([{"outcome": "idle"}])
        first = self.start_controller()
        wait_until(lambda: len(self.queue_calls()) >= 1, message="the first run to poll")

        elsewhere = self.root / "another-home"
        elsewhere.mkdir()
        second = subprocess.Popen(
            self.controller_argv("run", "--interval", "0.01"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env={**os.environ, "HOME": str(elsewhere)},
        )
        self.processes.append(second)
        _out, err = second.communicate(timeout=60)
        self.assertEqual(second.returncode, 1)
        self.assertIn("already running for the checkout at", err)
        self.assertIn(str(self.repo), err)
        # It really did resolve a different root, and still could not start.
        self.assertFalse((elsewhere / "Library").exists())
        self.assertNotIn(second.pid, {call["ppid"] for call in self.calls()})
        self.assertEqual(self.incidents(), [])

        first.send_signal(signal.SIGTERM)
        self.assertEqual(self.finish(first)[0], 0)

    def test_a_second_run_from_a_linked_worktree_is_refused_too(self):
        # A linked worktree is the same checkout by every measure that
        # matters: it shares the Git directory the checkout lock lives in.
        self.write_plan([{"outcome": "idle"}])
        first = self.start_controller()
        wait_until(lambda: len(self.queue_calls()) >= 1, message="the first run to poll")

        second = subprocess.Popen(
            [
                sys.executable,
                str(CONTROLLER),
                "--path",
                str(self.worktree()),
                "run",
                "--interval",
                "0.01",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=dict(os.environ),
        )
        self.processes.append(second)
        _out, err = second.communicate(timeout=60)
        self.assertEqual(second.returncode, 1)
        self.assertIn("already running for the checkout at", err)
        self.assertNotIn(second.pid, {call["ppid"] for call in self.calls()})

        first.send_signal(signal.SIGTERM)
        self.assertEqual(self.finish(first)[0], 0)

    def test_a_second_clone_of_one_repository_is_refused_too(self):
        # The canonical approval lock cannot catch this: two clones have two
        # shared Git directories, and the pass releases that lock between
        # issues anyway. One identity is one controller, wherever it is run
        # from and whatever runtime it would have written.
        other_clone = self.checkout("widgets-again", self.remote_url)
        self.write_plan([{"outcome": "idle"}])
        first = self.start_controller()
        wait_until(lambda: len(self.queue_calls()) >= 1, message="the first run to poll")

        second = subprocess.Popen(
            [
                sys.executable,
                str(CONTROLLER),
                "--path",
                str(other_clone),
                "run",
                "--interval",
                "0.01",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=dict(os.environ),
        )
        self.processes.append(second)
        _out, err = second.communicate(timeout=60)
        self.assertEqual(second.returncode, 1)
        self.assertIn("already running", err)
        self.assertNotIn(second.pid, {call["ppid"] for call in self.calls()})
        self.assertEqual(self.incidents(), [])

        first.send_signal(signal.SIGTERM)
        self.assertEqual(self.finish(first)[0], 0)

    def test_the_lock_is_released_so_the_next_run_starts(self):
        self.write_plan([{"outcome": "idle", "signal_parent": True}])
        first = self.start_controller()
        self.assertEqual(self.finish(first)[0], 0)
        second = self.start_controller()
        wait_until(lambda: len(self.queue_calls()) >= 2, message="the second run to poll")
        second.send_signal(signal.SIGTERM)
        self.assertEqual(self.finish(second)[0], 0)

    def test_two_repositories_run_at_once(self):
        other = self.checkout("gadgets", "git@github.com:acme/gadgets.git")
        self.write_plan([{"outcome": "idle"}])
        first = self.start_controller()
        second = subprocess.Popen(
            [
                sys.executable,
                str(CONTROLLER),
                "--path",
                str(other),
                "run",
                "--interval",
                "0.02",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=dict(os.environ),
        )
        self.processes.append(second)
        wait_until(
            lambda: len([c for c in self.queue_calls() if c["repo"] == "acme/gadgets"]) >= 1,
            message="the second repository to poll",
        )
        wait_until(
            lambda: len([c for c in self.queue_calls() if c["repo"] == self.identity]) >= 1,
            message="the first repository to poll",
        )
        for proc in (first, second):
            proc.send_signal(signal.SIGTERM)
            self.assertEqual(self.finish(proc)[0], 0)
        widgets = self.job()
        gadgets = service.job_for_identity(other, "acme/gadgets")
        self.assertEqual(service.status_snapshot(widgets)["state"], service.STATE_STOPPED)
        self.assertEqual(service.status_snapshot(gadgets)["state"], service.STATE_STOPPED)
        self.assertNotEqual(widgets.status_path, gadgets.status_path)


# ---------------------------------------------------------------------------
# The poll loop
# ---------------------------------------------------------------------------


class PollLoopTests(ApprovalFixture):
    def test_a_run_stays_alive_across_repeated_idle_polls(self):
        self.write_plan(
            [
                {"outcome": "idle"},
                {"outcome": "idle"},
                {"outcome": "idle"},
                {"outcome": "idle", "signal_parent": True},
            ]
        )
        proc = self.start_controller()
        code, _out, err = self.finish(proc)
        self.assertEqual(code, 0, err)
        # One pass per invocation and a controller that kept asking: exiting
        # after the first idle pass is exactly the failure this rules out.
        self.assertGreaterEqual(len(self.queue_calls()), 4)
        self.assertEqual(self.incidents(), [])
        self.assertEqual(self.status()["state"], service.STATE_STOPPED)

    def test_each_pass_is_its_own_process_that_took_and_released_the_lock(self):
        self.write_plan(
            [
                {"outcome": "advanced", "issue": 1, "model_called": True},
                {"outcome": "advanced", "issue": 2, "model_called": True},
                {"outcome": "advanced", "issue": 3, "model_called": True},
                {"outcome": "idle", "signal_parent": True},
            ]
        )
        proc = self.start_controller()
        self.assertEqual(self.finish(proc)[0], 0)
        calls = self.queue_calls()
        self.assertGreaterEqual(len(calls), 4)
        # The fake backend takes the same non-blocking flock the real one
        # takes, so an overlapped pass would have recorded contention rather
        # than a clean acquisition.
        self.assertEqual([call for call in calls if call.get("contention")], [])
        self.assertEqual(len({call["pid"] for call in calls}), len(calls))
        advanced = [call["step"]["issue"] for call in calls if call["step"].get("issue")]
        self.assertEqual(advanced, [1, 2, 3])

    def test_the_backend_is_told_which_repository_and_where_to_log(self):
        self.write_plan([{"outcome": "idle", "signal_parent": True}])
        proc = self.start_controller()
        self.assertEqual(self.finish(proc)[0], 0)
        call = self.queue_calls()[0]
        self.assertEqual(call["repo"], self.identity)
        self.assertEqual(call["log_dir"], str(self.job().log_dir))
        self.assertIn("--review-queue", call["argv"])
        self.assertIn("--json", call["argv"])
        self.assertIn("--legacy-policy", call["argv"])

    def test_busy_backs_off_rather_than_recording_an_error(self):
        self.write_plan(
            [
                {"outcome": "busy", "message": "Approval queue lock is held by the issue review queue at #4; this pass did no work."},
                {"outcome": "busy", "message": "Approval queue lock is held by single-issue review #7; this pass did no work."},
                {"outcome": "busy", "message": "Approval queue lock is held by another approval process; this pass did no work."},
                {"outcome": "idle", "signal_parent": True},
            ]
        )
        proc = self.start_controller()
        self.assertEqual(self.finish(proc)[0], 0)
        self.assertEqual(self.incidents(), [])
        self.assertGreaterEqual(len(self.queue_calls()), 4)
        # Truthful text while it waits: contention is named as the normal
        # condition it is, and the service never left the healthy state.
        log = self.job().service_log_path.read_text(encoding="utf-8")
        self.assertIn("Approval queue lock is held by", log)
        self.assertIn("returned busy", log)

    def test_retry_backs_off_rather_than_recording_an_error(self):
        # The review's correction: a specification that changed during review
        # is a retryable completion, not an incident.
        self.write_plan(
            [
                {"outcome": "retry", "issue": 4, "model_called": True, "message": "Issue #4 changed while it was being reviewed"},
                {"outcome": "retry", "issue": 4, "model_called": True, "message": "Issue #4 changed while it was being reviewed"},
                {"outcome": "idle", "signal_parent": True},
            ]
        )
        proc = self.start_controller()
        code, _out, err = self.finish(proc)
        self.assertEqual(code, 0, err)
        self.assertEqual(self.incidents(), [])
        self.assertEqual(self.status()["state"], service.STATE_STOPPED)
        self.assertIn("returned retry", self.job().service_log_path.read_text(encoding="utf-8"))


class OutcomeDispatchTests(ApprovalFixture):
    """Requirement 4 as four distinguishable waits, pinned without timing.

    What each outcome earns is asserted from the wait the loop asks for rather
    than from how long a fixture took, so the distinction stays legible on a
    loaded machine.
    """

    def setUp(self):
        super().setUp()
        self.job_ = self.job()
        service.ensure_dirs(self.job_)
        self.controller = service.Controller(
            self.job_, backend=self.backend, interval=30.0, legacy_policy="dual"
        )
        self.waits = []
        patched = mock.patch.object(
            self.controller, "sleep", side_effect=self.waits.append
        )
        patched.start()
        self.addCleanup(patched.stop)

    def dispatch(self, outcome, **kwargs):
        self.controller.dispatch(result_document(outcome, **kwargs))

    def test_idle_waits_the_ordinary_interval(self):
        self.dispatch("idle")
        self.assertEqual(self.waits, [30.0])
        self.assertEqual(self.stored_status()["state"], service.STATE_RUNNING)

    def test_advanced_proceeds_promptly(self):
        self.dispatch("advanced", issue=3, model_called=True)
        self.assertEqual(self.waits, [service.ADVANCE_DELAY_SECONDS])
        self.assertLess(service.ADVANCE_DELAY_SECONDS, 30.0)

    def test_busy_waits_with_bounded_backoff_and_stays_healthy(self):
        for _ in range(6):
            self.dispatch("busy", message="Approval queue lock is held by X")
        self.assertEqual(self.waits[:3], [30.0, 60.0, 120.0])
        self.assertEqual(max(self.waits), 30.0 * service.BACKOFF_CEILING_MULTIPLIER)
        stored = self.stored_status()
        self.assertEqual(stored["state"], service.STATE_RUNNING)
        self.assertIn("Approval queue lock is held by", stored["message"])
        self.assertEqual(self.incidents(), [])

    def test_retry_waits_with_the_same_backoff_and_records_nothing(self):
        for _ in range(3):
            self.dispatch("retry", issue=8, model_called=True)
        self.assertEqual(self.waits, [30.0, 60.0, 120.0])
        self.assertEqual(self.incidents(), [])
        self.assertEqual(self.stored_status()["state"], service.STATE_RUNNING)

    def test_a_settled_outcome_resets_the_backoff(self):
        self.dispatch("busy")
        self.dispatch("busy")
        self.dispatch("idle")
        self.dispatch("busy")
        self.assertEqual(self.waits, [30.0, 60.0, 30.0, 30.0])

    def test_changes_requested_opens_the_barrier_without_waiting(self):
        self.dispatch("changes_requested", issue=5, model_called=True)
        self.assertEqual(self.waits, [])
        self.assertEqual(service.read_barrier(self.job_), 5)
        stored = self.stored_status()
        self.assertEqual(stored["state"], service.STATE_BARRIER)
        self.assertEqual(stored["barrier_issue"], 5)
        self.assertEqual(stored["message"], "Issue #5 requests changes")
        warnings = self.incidents(open_only=True, kind=service.BARRIER_INCIDENT_KIND)
        self.assertEqual(len(warnings), 1)
        self.assertEqual(warnings[0]["severity"], service.SEVERITY_WARNING)


class FailedPassTests(ApprovalFixture):
    def assert_failed(self, expected):
        proc = self.start_controller()
        code, _out, _err = self.finish(proc)
        self.assertEqual(code, 1)
        incidents = self.incidents(open_only=True)
        self.assertEqual(len(incidents), 1)
        incident = incidents[0]
        self.assertEqual(incident["severity"], service.SEVERITY_ERROR)
        self.assertEqual(incident["kind"], service.ERROR_INCIDENT_KIND)
        self.assertEqual(incident["schema"], service.INCIDENT_SCHEMA)
        self.assertEqual(incident["version"], service.INCIDENT_VERSION)
        self.assertEqual(incident["repository"], self.identity)
        self.assertIn(expected, incident["summary"])
        return incident

    def test_an_unexpected_child_exit_is_recorded_with_its_reason(self):
        self.write_plan([{"exit": 3, "stderr": "approve-issues.py error: gh failed"}])
        incident = self.assert_failed("exited unexpectedly with code 3")
        self.assertIn("gh failed", incident["detail"])
        self.assertEqual(self.status()["state"], service.STATE_CHILD_FAILURE)

    def test_an_absent_result_document_is_recorded(self):
        self.write_plan([{"raw": "", "exit": 0}])
        self.assert_failed("no result document")

    def test_a_malformed_result_document_is_recorded(self):
        self.write_plan([{"raw": "advanced\n", "exit": 0}])
        self.assert_failed("no readable result document")

    def test_a_result_of_another_schema_is_refused_rather_than_guessed_at(self):
        self.write_plan(
            [
                {
                    "raw": json.dumps(
                        {
                            "schema": "approve-issues-review-queue-v2",
                            "version": 1,
                            "outcome": "advanced",
                            "issue": 4,
                            "model_called": True,
                            "message": "moved on",
                        }
                    ),
                    "exit": 0,
                }
            ]
        )
        self.assert_failed("unknown schema")

    def test_a_result_of_another_version_is_refused_rather_than_guessed_at(self):
        document = result_document("advanced", issue=4, model_called=True)
        document["version"] = 2
        self.write_plan([{"raw": json.dumps(document), "exit": 0}])
        self.assert_failed("unknown schema version")

    def test_a_failed_run_does_not_end_without_a_durable_trace(self):
        self.write_plan([{"exit": 9}])
        self.assert_failed("exited unexpectedly with code 9")
        snapshot = self.status()
        self.assertEqual(snapshot["state"], service.STATE_CHILD_FAILURE)
        self.assertIsNotNone(snapshot["open_incident"])
        self.assertTrue(self.job().service_log_path.exists())


# ---------------------------------------------------------------------------
# The ordered barrier, end to end
# ---------------------------------------------------------------------------


class BarrierLifecycleTests(ApprovalFixture):
    def barrier_plan(self):
        return [{"outcome": "changes_requested", "issue": 5, "model_called": True,
                 "message": "Issue #5 requests changes; the queue stops at that barrier."}]

    def run_to_barrier(self, *, checks=2):
        self.write_plan(self.barrier_plan())
        self.write_gate({"5": False})
        proc = self.start_controller()
        wait_until(
            lambda: len(self.check_calls()) >= checks,
            message="the barrier to be polled",
        )
        return proc

    def test_the_barrier_pauses_without_model_work_and_reviews_nothing_higher(self):
        proc = self.run_to_barrier(checks=3)
        proc.send_signal(signal.SIGTERM)
        self.assertEqual(self.finish(proc)[0], 0)
        queue_calls = self.queue_calls()
        # Exactly one queue pass: the one that published the verdict. Nothing
        # after it, so no model can have run and no higher-numbered issue can
        # have been reached.
        self.assertEqual(len(queue_calls), 1)
        checks = self.check_calls()
        self.assertGreaterEqual(len(checks), 3)
        self.assertEqual({call["issue"] for call in checks}, {5})
        for call in checks:
            self.assertIn("--check", call["argv"])
            self.assertNotIn("--review-queue", call["argv"])
        self.assertEqual(service.read_barrier(self.job()), 5)

    def test_the_barrier_opens_one_warning_naming_the_issue(self):
        proc = self.run_to_barrier()
        proc.send_signal(signal.SIGTERM)
        self.finish(proc)
        incidents = self.incidents(open_only=True)
        self.assertEqual(len(incidents), 1)
        self.assertEqual(incidents[0]["summary"], "Issue #5 requests changes")
        self.assertEqual(incidents[0]["severity"], service.SEVERITY_WARNING)
        self.assertEqual(incidents[0]["issue"], 5)

    def test_repeated_polls_do_not_accumulate_warnings(self):
        proc = self.run_to_barrier(checks=6)
        proc.send_signal(signal.SIGTERM)
        self.finish(proc)
        self.assertEqual(len(self.incidents(open_only=True)), 1)

    def test_the_barrier_resumes_only_after_a_current_approval(self):
        proc = self.run_to_barrier(checks=3)
        self.assertEqual(len(self.queue_calls()), 1)
        # The repair lands: the barrier issue now holds a current approval, and
        # the plan's next step lets the queue go idle.
        self.write_plan(self.barrier_plan() + [{"outcome": "idle", "signal_parent": True}])
        self.write_gate({"5": True})
        code, _out, err = self.finish(proc)
        self.assertEqual(code, 0, err)
        self.assertGreaterEqual(len(self.queue_calls()), 2)
        self.assertIsNone(service.read_barrier(self.job()))
        self.assertEqual(self.incidents(open_only=True), [])
        resolved = self.incidents(kind=service.BARRIER_INCIDENT_KIND)
        self.assertEqual(resolved[0]["status"], "resolved")
        self.assertIn("current canonical approval", resolved[0]["resolution"])

    def test_the_barrier_survives_an_intentional_stop_and_a_restart(self):
        proc = self.run_to_barrier()
        proc.send_signal(signal.SIGTERM)
        self.assertEqual(self.finish(proc)[0], 0)
        self.assertEqual(service.read_barrier(self.job()), 5)
        self.assertEqual(len(self.incidents(open_only=True)), 1)
        snapshot = self.status()
        self.assertEqual(snapshot["state"], service.STATE_STOPPED)
        self.assertEqual(snapshot["barrier_issue"], 5)

        # The restart rechecks the barrier rather than resuming past it, and
        # the plan is still positioned so any queue pass would advance.
        before = len(self.queue_calls())
        again = self.start_controller()
        wait_until(
            lambda: len(self.check_calls()) >= 4, message="the restart to recheck"
        )
        again.send_signal(signal.SIGTERM)
        self.assertEqual(self.finish(again)[0], 0)
        self.assertEqual(len(self.queue_calls()), before)
        self.assertEqual(service.read_barrier(self.job()), 5)

    def test_an_acknowledged_barrier_still_stops_the_queue_and_regains_its_warning(self):
        proc = self.run_to_barrier(checks=2)
        incident = self.incidents(open_only=True)[0]
        acked = self.run_controller("--json", "ack", incident["incident_id"], "--note", "seen")
        self.assertEqual(acked.returncode, 0, acked.stderr)
        self.assertEqual(json.loads(acked.stdout)["status"], "resolved")

        # The warning comes back on the next poll, because the barrier record
        # rather than the warning is what stops the queue.
        recreated = wait_until(
            lambda: next(
                (
                    document
                    for document in self.incidents(open_only=True, kind=service.BARRIER_INCIDENT_KIND)
                    if document["incident_id"] != incident["incident_id"]
                ),
                None,
            ),
            message="the warning to be recreated",
        )
        self.assertEqual(recreated["summary"], "Issue #5 requests changes")
        proc.send_signal(signal.SIGTERM)
        self.assertEqual(self.finish(proc)[0], 0)
        self.assertEqual(len(self.queue_calls()), 1)
        self.assertEqual(service.read_barrier(self.job()), 5)

    def test_an_acknowledged_barrier_survives_a_restart(self):
        proc = self.run_to_barrier(checks=2)
        proc.send_signal(signal.SIGTERM)
        self.assertEqual(self.finish(proc)[0], 0)
        for document in self.incidents(open_only=True):
            service.acknowledge_incident(self.job(), document["incident_id"], "seen")
        self.assertEqual(self.incidents(open_only=True), [])

        before = len(self.queue_calls())
        again = self.start_controller()
        wait_until(
            lambda: self.incidents(open_only=True, kind=service.BARRIER_INCIDENT_KIND),
            message="the restart to recreate the warning",
        )
        again.send_signal(signal.SIGTERM)
        self.assertEqual(self.finish(again)[0], 0)
        # Acknowledged twice over, and the queue still has not crossed #5.
        self.assertEqual(len(self.queue_calls()), before)
        self.assertEqual(service.read_barrier(self.job()), 5)

    def test_a_gate_check_that_fails_is_recorded_rather_than_treated_as_gated(self):
        self.write_plan(self.barrier_plan())
        self.write_gate({"5": "error"})
        proc = self.start_controller()
        code, _out, _err = self.finish(proc)
        self.assertEqual(code, 1)
        incidents = self.incidents(open_only=True, kind=service.ERROR_INCIDENT_KIND)
        self.assertEqual(len(incidents), 1)
        self.assertIn("#5", incidents[0]["summary"])
        self.assertEqual(service.read_barrier(self.job()), 5)

    def test_a_gate_check_with_no_document_is_never_read_as_still_gated(self):
        # A usage error exits 2 with nothing on stdout, which is the same exit
        # a genuinely gated issue uses. Waiting forever on it would be a
        # barrier that can never clear.
        self.write_plan(self.barrier_plan())
        self.write_gate({"5": "malformed"})
        proc = self.start_controller()
        code, _out, _err = self.finish(proc)
        self.assertEqual(code, 1)
        incidents = self.incidents(open_only=True, kind=service.ERROR_INCIDENT_KIND)
        self.assertEqual(len(incidents), 1)
        self.assertIn("#5", incidents[0]["summary"])


# ---------------------------------------------------------------------------
# Stopping
# ---------------------------------------------------------------------------


class IntentionalStopTests(ApprovalFixture):
    def test_a_stop_is_recorded_as_a_stop_rather_than_a_failure(self):
        self.write_plan([{"outcome": "idle"}])
        proc = self.start_controller()
        wait_until(lambda: len(self.queue_calls()) >= 1, message="the first pass")
        proc.send_signal(signal.SIGTERM)
        code, _out, err = self.finish(proc)
        self.assertEqual(code, 0, err)
        self.assertEqual(self.incidents(), [])
        snapshot = self.status()
        self.assertEqual(snapshot["state"], service.STATE_STOPPED)
        self.assertIn("Stopped intentionally", snapshot["message"])

    def test_a_stop_during_a_pass_claims_no_work_past_it(self):
        # The child is killed mid-pass, so its exit status describes the stop.
        # Recording that as an unexpected exit is exactly the false claim
        # requirement 11 rules out.
        self.write_plan([{"outcome": "idle", "sleep": 30}])
        proc = self.start_controller()
        wait_until(lambda: len(self.queue_calls()) >= 1, message="the pass to start")
        proc.send_signal(signal.SIGTERM)
        code, _out, err = self.finish(proc)
        self.assertEqual(code, 0, err)
        self.assertEqual(self.incidents(), [])
        self.assertEqual(self.status()["state"], service.STATE_STOPPED)

    def test_a_stop_terminates_the_backends_process_group_leaving_no_orphan(self):
        orphan_path = self.root / "orphan.pid"
        self.write_plan([{"outcome": "idle", "sleep": 30, "spawn_orphan": str(orphan_path)}])
        proc = self.start_controller()
        wait_until(orphan_path.exists, message="the orphan to announce itself")
        orphan_pid = int(orphan_path.read_text(encoding="utf-8"))
        self.addCleanup(_kill_quietly, orphan_pid)
        backend_call = wait_until(
            lambda: self.queue_calls()[0] if self.queue_calls() else None,
            message="the backend to record its call",
        )
        # The orphan really is in the backend's own group, and that group is
        # not the controller's.
        self.assertEqual(os.getpgid(orphan_pid), backend_call["pgid"])
        self.assertNotEqual(backend_call["pgid"], os.getpgid(proc.pid))

        proc.send_signal(signal.SIGTERM)
        code, _out, err = self.finish(proc)
        self.assertEqual(code, 0, err)
        # The orphan ignores SIGINT and SIGTERM, so only a signal to the whole
        # group can have removed it.
        wait_until(lambda: process_gone(orphan_pid), message="the orphan to be gone")
        self.assertEqual(self.status()["state"], service.STATE_STOPPED)

    def test_a_second_signal_escalates(self):
        self.write_plan([{"outcome": "idle", "sleep": 30, "ignore_sigint": True}])
        proc = self.start_controller()
        wait_until(lambda: len(self.queue_calls()) >= 1, message="the pass to start")
        backend_pid = self.queue_calls()[0]["pid"]
        self.addCleanup(_kill_quietly, backend_pid)
        proc.send_signal(signal.SIGTERM)
        # Far longer than delivery and handling need, so the second signal is
        # genuinely a second one rather than one the first coalesced with --
        # which is what makes this about the escalation rather than about the
        # grace period expiring.
        time.sleep(0.5)
        proc.send_signal(signal.SIGTERM)
        code, _out, err = self.finish(proc, timeout=30)
        self.assertEqual(code, 0, err)
        wait_until(lambda: process_gone(backend_pid), message="the backend to be gone")


class StopRacingASpawnTests(ApprovalFixture):
    """The transition between deciding to start a pass and having one running.

    A stop landing in that window must not leave a live `--review-queue` pass
    -- model calls and GitHub mutations included -- running behind a controller
    that has already recorded an intentional stop.
    """

    def test_a_stop_while_waiting_starts_no_further_pass(self):
        # A long interval leaves the controller asleep between passes, which is
        # where an operator's stop most often lands.
        self.write_plan([{"outcome": "idle"}])
        proc = self.start_controller(interval="30")
        wait_until(lambda: len(self.queue_calls()) >= 1, message="the first pass")
        # Comfortably inside the 30s wait, so the stop cannot be mistaken for
        # the interval elapsing.
        time.sleep(0.5)
        proc.send_signal(signal.SIGTERM)
        code, _out, err = self.finish(proc, timeout=30)
        self.assertEqual(code, 0, err)
        self.assertEqual(len(self.queue_calls()), 1)
        self.assertEqual(self.incidents(), [])
        self.assertEqual(self.status()["state"], service.STATE_STOPPED)

    def test_a_stop_landing_inside_the_spawn_still_reaches_the_child(self):
        # The window between `Popen` returning and the child being registered:
        # a handler running there finds no child to signal. This reproduces it
        # exactly by flipping the flag from inside Popen, and asserts the child
        # is signalled and reaped rather than left running.
        job = self.job()
        service.ensure_dirs(job)
        controller = service.Controller(
            job, backend=self.backend, interval=0.0, legacy_policy="dual"
        )
        real_popen = subprocess.Popen
        spawned = []

        def racing_popen(*args, **kwargs):
            child = real_popen(*args, **kwargs)
            spawned.append(child)
            controller._stop_requested = True
            return child

        with mock.patch.object(service.subprocess, "Popen", racing_popen):
            child = controller.start_child(
                [
                    sys.executable,
                    "-c",
                    "import time; time.sleep(60)",
                ]
            )
        self.assertIsNotNone(child)
        self.assertEqual(spawned, [child])
        self.addCleanup(_kill_quietly, child.pid)
        # Signalled where it stands, then collected: the group is gone and
        # nothing of the pass is left running.
        child.wait(timeout=30)
        self.assertEqual(child.returncode, -signal.SIGINT)
        wait_until(lambda: process_gone(child.pid), message="the child to be reaped")
        self.assertIn(
            "raced this pass's start",
            job.service_log_path.read_text(encoding="utf-8"),
        )

    def test_the_backend_can_still_be_interrupted(self):
        # The hazard in closing the spawn race by masking signals: the mask is
        # inherited across fork and survives exec, so every pass would run with
        # the very signals its process group is stopped with blocked, and only
        # the grace period's SIGKILL could ever end one.
        self.write_plan([{"outcome": "idle", "signal_parent": True}])
        proc = self.start_controller()
        self.assertEqual(self.finish(proc)[0], 0)
        blocked = self.queue_calls()[0]["blocked"]
        self.assertNotIn(int(signal.SIGINT), blocked)
        self.assertNotIn(int(signal.SIGTERM), blocked)

    def test_a_pending_stop_spawns_nothing_at_all(self):
        job = self.job()
        service.ensure_dirs(job)
        controller = service.Controller(
            job, backend=self.backend, interval=0.0, legacy_policy="dual"
        )
        controller._stop_requested = True
        with mock.patch.object(service.subprocess, "Popen") as popen:
            self.assertIsNone(controller.start_child(["true"]))
            self.assertIsNone(
                controller.spawn(["true"], state=service.STATE_RUNNING, message="x")
            )
        popen.assert_not_called()

    def test_a_pass_that_finished_before_the_stop_is_still_recorded(self):
        # The other half of the same truthfulness rule: a stop must not claim
        # nothing happened when the backend had already published a verdict.
        # The fake ignores SIGINT, signals this controller, and then completes
        # normally, so the result really is a completed pass's.
        self.write_plan(
            [
                {
                    "outcome": "changes_requested",
                    "issue": 5,
                    "model_called": True,
                    "message": "Issue #5 requests changes",
                    "ignore_sigint": True,
                    "signal_parent": True,
                }
            ]
        )
        self.write_gate({"5": False})
        proc = self.start_controller()
        code, _out, err = self.finish(proc, timeout=60)
        self.assertEqual(code, 0, err)
        self.assertEqual(len(self.queue_calls()), 1)
        # The barrier the completed pass established survived the stop.
        self.assertEqual(service.read_barrier(self.job()), 5)
        warnings = self.incidents(open_only=True, kind=service.BARRIER_INCIDENT_KIND)
        self.assertEqual(len(warnings), 1)
        self.assertEqual(warnings[0]["summary"], "Issue #5 requests changes")
        snapshot = self.status()
        self.assertEqual(snapshot["state"], service.STATE_STOPPED)
        self.assertEqual(snapshot["barrier_issue"], 5)

    def test_an_interrupted_pass_is_recorded_as_no_verdict_rather_than_a_failure(self):
        self.write_plan([{"outcome": "idle", "sleep": 30}])
        proc = self.start_controller()
        wait_until(lambda: len(self.queue_calls()) >= 1, message="the pass to start")
        proc.send_signal(signal.SIGTERM)
        code, _out, err = self.finish(proc, timeout=30)
        self.assertEqual(code, 0, err)
        self.assertEqual(self.incidents(), [])
        self.assertIn(
            "interrupted by the stop",
            self.job().service_log_path.read_text(encoding="utf-8"),
        )


class FailureAfterSpawnTests(ApprovalFixture):
    """A pass that cannot be supervised to completion must not outlive the run.

    The run is about to record a controller failure and release the
    per-identity run lock. A backend left alive past that point keeps making
    model calls and GitHub mutations unwatched, and the next controller the
    released lock admits would overlap it.
    """

    def setUp(self):
        super().setUp()
        self.orphan_path = self.root / "orphan.pid"
        # Long enough that the backend is unmistakably still running, and it
        # spawns a grandchild of its own so the assertion is about the whole
        # process group rather than the one process the controller holds.
        self.write_plan(
            [{"outcome": "idle", "sleep": 120, "spawn_orphan": str(self.orphan_path)}]
        )
        self.job_ = self.job()
        service.ensure_dirs(self.job_)
        self.controller = service.Controller(
            self.job_, backend=self.backend, interval=0.0, legacy_policy="dual"
        )

    def fail_once_the_backend_is_up(self, error):
        """A side effect that waits for the pass to be genuinely running --
        grandchild and all -- and only then fails it."""

        def side_effect(*_args, **_kwargs):
            wait_until(self.orphan_path.exists, message="the backend to spawn its child")
            raise error

        return side_effect

    def assert_group_is_gone(self):
        orphan_pid = int(self.orphan_path.read_text(encoding="utf-8"))
        self.addCleanup(_kill_quietly, orphan_pid)
        backend_pid = self.queue_calls()[0]["pid"]
        self.addCleanup(_kill_quietly, backend_pid)
        wait_until(lambda: process_gone(backend_pid), message="the backend to be gone")
        # The grandchild ignores SIGINT and SIGTERM, so only a signal to the
        # whole group can have removed it.
        wait_until(lambda: process_gone(orphan_pid), message="the orphan to be gone")

    def test_a_status_write_that_fails_after_the_spawn_ends_the_group(self):
        with mock.patch.object(
            self.controller,
            "write_status",
            side_effect=self.fail_once_the_backend_is_up(OSError("no space left")),
        ):
            with self.assertRaises(OSError):
                self.controller.spawn(
                    self.controller.backend_argv("--review-queue"),
                    state=service.STATE_RUNNING,
                    message="Advancing the approval queue.",
                )
        self.assert_group_is_gone()

    def test_a_wait_that_fails_after_the_spawn_ends_the_group(self):
        with mock.patch.object(
            self.controller,
            "wait_for",
            side_effect=self.fail_once_the_backend_is_up(RuntimeError("collection failed")),
        ):
            with self.assertRaises(RuntimeError):
                self.controller.spawn(
                    self.controller.backend_argv("--review-queue"),
                    state=service.STATE_RUNNING,
                    message="Advancing the approval queue.",
                )
        self.assert_group_is_gone()

    def test_a_registration_step_that_fails_ends_the_group_too(self):
        # `start_child`'s own post-spawn work can fail as well -- writing the
        # service log, for one -- and the child is already running by then.
        real_popen = subprocess.Popen

        def racing_popen(*args, **kwargs):
            child = real_popen(*args, **kwargs)
            self.controller._stop_requested = True
            return child

        with (
            mock.patch.object(service.subprocess, "Popen", racing_popen),
            mock.patch.object(
                self.controller,
                "log",
                side_effect=self.fail_once_the_backend_is_up(OSError("log is unwritable")),
            ),
        ):
            with self.assertRaises(OSError):
                self.controller.start_child(
                    self.controller.backend_argv("--review-queue")
                )
        self.assert_group_is_gone()

    def test_the_whole_run_records_the_failure_with_nothing_left_running(self):
        # End to end, through a genuine write failure rather than a patched
        # method: the run has to record its controller failure and release the
        # run lock with the backend already gone, since the next controller
        # that lock admits would otherwise overlap it.
        real_write = service.atomic_write_json
        failed = []

        def failing_write(path, value):
            if (
                not failed
                and Path(path) == self.job_.status_path
                and value.get("state") == service.STATE_RUNNING
            ):
                wait_until(
                    self.orphan_path.exists, message="the backend to spawn its child"
                )
                failed.append(path)
                raise OSError("no space left on device")
            return real_write(path, value)

        with mock.patch.object(service, "atomic_write_json", failing_write):
            code = service.run_service(self.job_, interval=0.0, legacy_policy="dual")
        self.assertEqual(code, 1)
        self.assert_group_is_gone()
        incidents = self.incidents(open_only=True, kind=service.ERROR_INCIDENT_KIND)
        self.assertEqual(len(incidents), 1)
        self.assertEqual(
            service.status_snapshot(self.job_)["state"], service.STATE_CONTROLLER_FAILURE
        )
        # Released: the failed run holds nothing that would refuse the next one.
        with service.run_lock(self.job_):
            pass


class GraceEscalationTests(ApprovalFixture):
    def test_a_child_that_ignores_the_stop_is_killed_after_the_grace_period(self):
        job = self.job()
        service.ensure_dirs(job)
        controller = service.Controller(
            job, backend=self.backend, interval=0.0, legacy_policy="dual"
        )
        child = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import signal, sys, time\n"
                "signal.signal(signal.SIGINT, signal.SIG_IGN)\n"
                "sys.stderr.write('up\\n'); sys.stderr.flush()\n"
                "time.sleep(60)\n",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        self.addCleanup(_kill_quietly, child.pid)
        controller._child = child
        controller._stop_requested = True
        with (
            mock.patch.object(service, "SLEEP_SLICE_SECONDS", 0.005),
            mock.patch.object(service, "STOP_GRACE_SECONDS", 0.1),
        ):
            controller.wait_for(child)
        self.assertEqual(child.returncode, -signal.SIGKILL)


def _kill_quietly(pid):
    try:
        os.kill(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


# ---------------------------------------------------------------------------
# Command-line surface
# ---------------------------------------------------------------------------


class CommandLineTests(ApprovalFixture):
    def test_a_requested_repository_that_is_not_the_checkouts_is_refused(self):
        result = self.run_controller("--repo", "acme/gadgets", "status")
        self.assertEqual(result.returncode, 1)
        self.assertIn("acme/gadgets", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_a_path_that_is_no_checkout_is_refused(self):
        plain = self.root / "plain"
        plain.mkdir()
        result = subprocess.run(
            [sys.executable, str(CONTROLLER), "--path", str(plain), "status"],
            capture_output=True,
            text=True,
            env=dict(os.environ),
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("no .git entry", result.stderr)

    def test_a_negative_interval_is_refused(self):
        result = self.run_controller("run", "--interval", "-1")
        self.assertEqual(result.returncode, 2)
        self.assertIn("must not be negative", result.stderr)

    def test_status_is_machine_readable(self):
        result = self.run_controller("--json", "status")
        self.assertEqual(result.returncode, 0, result.stderr)
        snapshot = json.loads(result.stdout)
        self.assertEqual(snapshot["schema"], service.STATUS_SCHEMA)
        self.assertEqual(snapshot["version"], service.STATUS_VERSION)

    def test_run_and_status_are_the_commands_this_slice_exposes(self):
        for command in ("run", "status", "ack"):
            with self.subTest(command=command):
                self.assertEqual(service.parse_args([command]).command, command)


class ControllerBoundaryTests(unittest.TestCase):
    """This slice installs nothing and shares nothing.

    Asserted against what the module imports and what it names, rather than
    against its prose: the docstrings deliberately discuss both boundaries, and
    a check that could not tell a mention from a dependency would have to be
    deleted the first time either was explained.
    """

    def setUp(self):
        self.tree = ast.parse(CONTROLLER.read_text(encoding="utf-8"))

    def imported(self):
        names = set()
        for node in ast.walk(self.tree):
            if isinstance(node, ast.Import):
                names.update(alias.name for alias in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                names.add(node.module)
        return names

    def literals(self):
        return [
            node.value
            for node in ast.walk(self.tree)
            if isinstance(node, ast.Constant) and isinstance(node.value, str)
        ]

    def code_literals(self):
        """Every string constant that is not a docstring."""
        docstrings = set()
        for node in ast.walk(self.tree):
            if isinstance(
                node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)
            ):
                doc = ast.get_docstring(node, clean=False)
                if doc is not None:
                    docstrings.add(doc)
        return [value for value in self.literals() if value not in docstrings]

    def test_the_controller_depends_on_no_service_manager(self):
        self.assertNotIn("service_manager", self.imported())
        for value in self.code_literals():
            for token in ("launchctl", "launchd", "systemctl", "plist", "LaunchAgent"):
                self.assertNotIn(token, value)

    def test_the_controller_neither_imports_nor_names_the_pr_drainers_state(self):
        self.assertNotIn("drain_prs", self.imported())
        self.assertNotIn("drain_prs_service", self.imported())
        for value in self.code_literals():
            for token in ("drain_prs", "pr-drainer"):
                self.assertNotIn(token, value)

    def test_the_only_tracked_module_it_imports_is_the_shared_configuration(self):
        # The backend is invoked, never imported: it is installed elsewhere and
        # its result contract is mirrored rather than shared.
        self.assertNotIn("approve_issues", self.imported())
        self.assertIn("kanban_config", self.imported())


if __name__ == "__main__":
    unittest.main()
