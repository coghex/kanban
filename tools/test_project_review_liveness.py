"""The project-review session liveness adapter and its lifecycle hooks.

Run with: python3 -m unittest discover -s tools -p 'test_project_review_liveness.py'

Issue #687. The adapter ships in both bundles and nothing installed invokes it
for a review yet (#684 switches the workflow over), so these tests are its whole
contract. Every test is process-level: lifecycle events are delivered by running
the bundled hook exactly as `hooks/hooks.json` does, with payloads in the shape
each runtime was observed to send (Claude Code 2.1.274, codex-cli 0.154.0) --
never with an attempt id the runtimes do not send -- and the keeper, the wrapper,
the ledger's claim and its renewer are all real processes in a temporary Git
repository, with sub-second intervals.

Each behaviour runs once per adapter through that bundle's own copy of both
helpers, so a copy that drifted fails under its own brand's name.
"""

from __future__ import annotations

import contextlib
import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

BRANDS = {
    "claude": {
        "liveness": "claude-plugin/plugins/kanban/scripts/project_review_liveness.py",
        "ledger": "claude-plugin/plugins/kanban/scripts/project_review_ledger.py",
        "hooks": "claude-plugin/plugins/kanban/hooks/hooks.json",
        "bundle_root": "claude-plugin/plugins/kanban",
        "root_variable": "${CLAUDE_PLUGIN_ROOT}",
        "invocation_field": "prompt_id",
        "tool_events": ("PreToolUse", "PostToolUse", "PostToolUseFailure"),
        "terminal_events": ("Stop", "StopFailure", "SessionEnd"),
        "version": "2.1.274 (Claude Code)",
        "old_version": "2.1.273 (Claude Code)",
        "bundle_files": (
            "scripts/project_review_liveness.py",
            "scripts/project_review_ledger.py",
            "hooks/hooks.json",
        ),
    },
    "codex": {
        "liveness": "codex-plugin/plugins/kanban/skills/project-review/scripts/project_review_liveness.py",
        "ledger": "codex-plugin/plugins/kanban/skills/project-review/scripts/project_review_ledger.py",
        "hooks": "codex-plugin/plugins/kanban/hooks/hooks.json",
        "bundle_root": "codex-plugin/plugins/kanban",
        "root_variable": "$PLUGIN_ROOT",
        "invocation_field": "turn_id",
        "tool_events": ("PreToolUse", "PostToolUse"),
        "terminal_events": ("Stop", "Interrupt", "SessionEnd"),
        "version": "codex-cli 0.154.0",
        "old_version": "codex-cli 0.153.9",
        "bundle_files": (
            "skills/project-review/scripts/project_review_liveness.py",
            "skills/project-review/scripts/project_review_ledger.py",
            "hooks/hooks.json",
        ),
    },
}

REPO = "coghex/kanban"
SILENCE = 1.5
RENEWAL = 0.25
EXPIRY = 1.5
SETTLE = 15.0

# The trust hashes codex-cli 0.154.0 itself recorded for this bundle's
# hooks.json when its hooks were trusted during the smoke runs
# (tools/project-review-liveness-evidence.md). A hooks.json edit changes them,
# and must be trusted again by every Codex user; update these from a real
# `/hooks` trust, never from the adapter's own hash function.
CODEX_RECORDED_TRUST = {
    "kanban@kanban:hooks/hooks.json:pre_tool_use:0:0": "sha256:c09a9f901e7eb20ae2c00046a0fb4a5293658dd53ac29fc707df1d942e7eaa50",
    "kanban@kanban:hooks/hooks.json:post_tool_use:0:0": "sha256:d90f39d6b63b14c4f7270f7f97f89f05c845c3098707c6f5a102fbf9f145a09a",
    "kanban@kanban:hooks/hooks.json:stop:0:0": "sha256:546f5ba1b1d282cd7da83fba348cfdfdfb43bd5b8b13fe7d025f11c71d2948a6",
    "kanban@kanban:hooks/hooks.json:interrupt:0:0": "sha256:327a0fe09a52c33fa91de7585b50701785559d59efe8e3a18577204c3dea3d9c",
    "kanban@kanban:hooks/hooks.json:session_end:0:0": "sha256:dd818de264b9328c3677496b97cb709bec54b2047c4ab445d2efc72c59d7a454",
}


def load(relative: str, name: str):
    spec = importlib.util.spec_from_file_location(name, REPO_ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


LIVENESS = load(BRANDS["claude"]["liveness"], "_liveness_under_test")
LEDGER = load(BRANDS["claude"]["ledger"], "_ledger_under_liveness_test")


def git(cwd, *arguments):
    return subprocess.run(
        ["git", *arguments], cwd=str(cwd), capture_output=True, text=True, check=True
    ).stdout


def wait_until(predicate, message, timeout=SETTLE, interval=0.05):
    give_up = time.monotonic() + timeout
    while True:
        value = predicate()
        if value:
            return value
        if time.monotonic() >= give_up:
            raise AssertionError(message)
        time.sleep(interval)


def running(pid: int) -> bool:
    return LEDGER.holder_standing({"host": LEDGER.socket.gethostname(), "pid": pid}) == "live"


def listing(numbers):
    return {
        "pages": [
            {
                "page": 1,
                "limit": 100,
                "prs": [
                    {"number": n, "title": f"PR {n}", "merged_at": "2026-09-01T00:00:00Z"}
                    for n in numbers
                ],
            }
        ]
    }


class AdapterCase:
    """Shared fixtures; mixed into one TestCase per brand at the bottom."""

    BRAND = None

    # -- setup

    def setUp(self):
        self.spec = BRANDS[self.BRAND]
        self.directory = tempfile.TemporaryDirectory(prefix="project-review-liveness-")
        self.addCleanup(self.directory.cleanup)
        base = Path(self.directory.name).resolve()
        self.codex_home = base / "codex-home"
        # The bundle as each runtime installs it: Codex under its plugin cache,
        # Claude under a plugin root of its own.
        if self.BRAND == "codex":
            self.bundle = self.codex_home / "plugins" / "cache" / "kanban" / "kanban" / "1.52.0"
        else:
            self.bundle = base / "claude-plugins" / "kanban" / "1.53.0"
        for relative in self.spec["bundle_files"]:
            target = self.bundle / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((REPO_ROOT / self.spec["bundle_root"] / relative).read_bytes())
        self.liveness = self.bundle / Path(self.spec["liveness"]).relative_to(self.spec["bundle_root"])
        self.ledger = self.bundle / Path(self.spec["ledger"]).relative_to(self.spec["bundle_root"])
        self.root = base / "repo"
        self.root.mkdir()
        git(self.root, "init", "-q")
        git(self.root, "config", "user.email", "test@example.invalid")
        git(self.root, "config", "user.name", "test")
        document = LEDGER.empty_document()
        document["repositories"][REPO] = LEDGER.empty_repository()
        LEDGER.create_document(self.root, document)
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "ledger")
        self.bin = base / "bin"
        self.bin.mkdir()
        self.codex_home.mkdir(exist_ok=True)
        self.trust_codex_hooks()
        self.set_version(self.spec["version"])
        self.env = dict(os.environ, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}", CODEX_HOME=str(self.codex_home))
        self.pids = []
        self.addCleanup(self.kill_everything)
        self.addCleanup(self.assert_nothing_outside_the_common_directory)
        self.common = LIVENESS.git_common_directory(self.root)

    def set_version(self, text, codex_hooks_flag="true"):
        fake = {
            "claude": f'#!/bin/sh\necho "{text}"\n',
            "codex": (
                "#!/bin/sh\n"
                'if [ "$1" = "features" ]; then\n'
                f'  echo "hooks                                    stable             {codex_hooks_flag}"\n'
                "  exit 0\n"
                "fi\n"
                f'echo "{text}"\n'
            ),
        }[self.BRAND]
        path = self.bin / self.BRAND
        path.write_text(fake, encoding="utf-8")
        path.chmod(0o755)

    def trust_codex_hooks(self, overrides=None):
        """A Codex config.toml trusting every kanban hook, as `/hooks` records it."""
        states = {key: {"trusted_hash": value} for key, value in CODEX_RECORDED_TRUST.items()}
        for key, value in (overrides or {}).items():
            if value is None:
                states.pop(key, None)
            else:
                states[key] = value
        lines = []
        for key, state in states.items():
            lines.append(f'[hooks.state."{key}"]')
            for name, value in state.items():
                lines.append(f"{name} = {json.dumps(value)}")
        (self.codex_home / "config.toml").write_text("\n".join(lines) + "\n", encoding="utf-8")

    def kill_everything(self):
        for pid in self.pids:
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.kill(pid, signal.SIGKILL)

    def assert_nothing_outside_the_common_directory(self):
        # Runtime state is only ever inside the Git common directory: the
        # working tree, docs/ included, is exactly the commit.
        self.assertEqual(
            git(self.root, "status", "--porcelain", "--untracked-files=all", "--ignored"), ""
        )
        runtime = self.common / LIVENESS.RUNTIME_DIRECTORY
        if runtime.exists():
            self.assertTrue(str(runtime.resolve()).startswith(str(self.common.resolve())))

    # -- the runtime side

    def payload(self, event, session="session-a", invocation="invocation-1", tool_use_id=None, command=None, cwd=None):
        """One hook payload in the shape this runtime sends it."""
        body = {
            "hook_event_name": event,
            "session_id": session,
            "transcript_path": f"/tmp/{session}.jsonl",
            "cwd": str(self.root if cwd is None else cwd),
            "permission_mode": "bypassPermissions",
        }
        if self.BRAND == "codex":
            body["model"] = "gpt-6-astra"
        if event != "SessionEnd":
            body[self.spec["invocation_field"]] = invocation
        else:
            body["reason"] = "other" if self.BRAND == "codex" else "prompt_input_exit"
        if event in ("PreToolUse", "PostToolUse", "PostToolUseFailure"):
            body.update(
                tool_name="Bash",
                tool_use_id=tool_use_id or f"tool-{time.monotonic_ns()}",
                tool_input={"command": command or "echo hi"},
            )
            if event == "PostToolUse":
                body["tool_response"] = {"stdout": ""}
            if event == "PostToolUseFailure":
                body.update(error="exit 1", is_interrupt=False, duration_ms=5)
        if event in ("Stop", "Interrupt"):
            body["last_assistant_message"] = "done"
            if self.BRAND == "codex":
                body["stop_hook_active"] = False
        return body

    def hook(self, payload, liveness=None):
        completed = subprocess.run(
            [sys.executable, str(liveness or self.liveness), "hook", "--runtime", self.BRAND],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            cwd=payload.get("cwd"),
            env=self.env,
            timeout=60,
        )
        self.assertEqual((completed.returncode, completed.stdout), (0, ""), completed.stderr)

    def tool_call(self, session="session-a", invocation="invocation-1", command="echo hi"):
        tool_use_id = f"tool-{time.monotonic_ns()}"
        self.hook(self.payload("PreToolUse", session, invocation, tool_use_id, command))
        self.hook(self.payload("PostToolUse", session, invocation, tool_use_id, command))

    def helper(self, *arguments, script=None):
        return subprocess.run(
            [sys.executable, str(script or self.liveness), *arguments],
            capture_output=True,
            text=True,
            env=self.env,
            cwd=str(self.root),
            timeout=90,
        )

    def register(self, session="session-a", invocation="invocation-1", silence=SILENCE, renewal=RENEWAL, handshake=True, extra=()):
        nonce = self.helper("nonce").stdout.strip()
        arguments = [
            "register", "--runtime", self.BRAND, "--root", str(self.root), "--repo", REPO,
            "--nonce", nonce, "--silence", str(silence), "--handshake-wait", "0.3", *extra,
        ]
        if renewal is not None:
            arguments += ["--renewal", str(renewal)]
        if handshake:
            command = f"python3 {self.liveness} " + " ".join(arguments)
            self.hook(self.payload("PreToolUse", session, invocation, command=command))
        completed = self.helper(*arguments)
        if completed.returncode == 0:
            result = json.loads(completed.stdout)
            self.pids.append(result["keeper_pid"])
        return completed

    def registered(self, **kwargs):
        completed = self.register(**kwargs)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return json.loads(completed.stdout)

    def refused(self, completed, reason):
        self.assertEqual(completed.returncode, 2, completed.stdout)
        self.assertEqual(completed.stdout, "")
        self.assertIn(f"refused ({reason})", completed.stderr)

    def status(self, attempt):
        completed = self.helper("status", "--root", str(self.root), "--attempt", attempt)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return json.loads(completed.stdout)

    def ended(self, attempt):
        return LIVENESS.ended_record(self.common, attempt)

    def wait_keeper_gone(self, registration, message="the keeper outlived its attempt", timeout=SETTLE):
        wait_until(lambda: not running(registration["keeper_pid"]), message, timeout=timeout)

    def claim(self, keeper_pid, numbers=(612,)):
        completed = subprocess.run(
            [
                sys.executable, str(self.ledger), "claim", "--root", str(self.root), "--repo", REPO,
                "--owner-pid", str(keeper_pid), "--renewal", str(RENEWAL), "--expiry", str(EXPIRY),
            ],
            input=json.dumps(listing(numbers)),
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(completed.stdout)
        self.pids.append(result["claim"]["renewer"]["pid"])
        # The ledger's claim and its heartbeat records live in the common
        # directory too; the claim commits nothing, so commit its ledger write
        # to keep the working-tree assertion about this module's records.
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "claim")
        return result

    def renewals(self, token):
        record = LEDGER.read_heartbeat(LEDGER.git_common_directory(self.root), token)
        return None if record is None else record["renewals"]

    def tree_snapshot(self):
        snapshot = {}
        for path in sorted((self.common / LIVENESS.RUNTIME_DIRECTORY).rglob("*")):
            if path.is_file():
                snapshot[str(path)] = path.read_bytes()
        return snapshot

    def wrapper(self, attempt, label, seconds, new_session=True):
        # A session of its own by default, so the command it starts can be
        # reaped with it: killing the wrapper alone leaves that command
        # running, which since issue #684's amendment is a launch still
        # reported unfinished rather than a test that has tidied up.
        process = subprocess.Popen(
            [
                sys.executable, str(self.liveness), "run", "--root", str(self.root),
                "--attempt", attempt, "--launch", label, "--",
                sys.executable, "-c", f"import time; time.sleep({seconds})",
            ],
            env=self.env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=new_session,
        )
        self.pids.append(process.pid)
        self.addCleanup(self.reap, process)
        return process

    def kill_wrapped(self, process):
        """End a wrapper and the command it started, and wait for both.

        The group is named by the wrapper's own pid rather than looked up:
        `start_new_session` makes the wrapper its group's leader, and
        `getpgid` of a wrapper this process has already reaped raises, which
        would leave the command running and the launch correctly -- but
        confusingly -- still reported.
        """
        with contextlib.suppress(OSError):
            os.killpg(process.pid, signal.SIGKILL)
        self.reap(process)

    @staticmethod
    def reap(process):
        with contextlib.suppress(ProcessLookupError):
            process.kill()
        process.wait(timeout=SETTLE)

    def run_command_text(self, attempt, label):
        return f"python3 {self.liveness} run --root {self.root} --attempt {attempt} --launch {label} -- make test"


class RegistrationAndCompletion(AdapterCase):
    def test_registration_binds_the_invocation_and_turn_completion_ends_the_keeper(self):
        registration = self.registered()
        self.assertEqual(registration["invocation_field"], self.spec["invocation_field"])
        self.assertEqual((registration["session_id"], registration["invocation_id"]), ("session-a", "invocation-1"))
        self.assertTrue(running(registration["keeper_pid"]))
        records = Path(registration["records"])
        self.assertEqual(records.parent.parent, self.common / "kanban-project-review" / "liveness")
        started = time.monotonic()
        self.hook(self.payload("Stop"))
        self.wait_keeper_gone(registration)
        self.assertLess(time.monotonic() - started, SILENCE)
        self.assertEqual(self.ended(registration["attempt"])["reason"], "Stop")

    def test_explicit_completion_ends_the_keeper(self):
        registration = self.registered()
        completed = self.helper("complete", "--root", str(self.root), "--attempt", registration["attempt"])
        self.assertEqual(json.loads(completed.stdout)["status"], "completed")
        self.wait_keeper_gone(registration)
        again = self.helper("complete", "--root", str(self.root), "--attempt", registration["attempt"])
        self.assertEqual(json.loads(again.stdout)["status"], "already-ended")

    def test_renewal_continues_across_tool_calls_and_stops_when_the_turn_ends(self):
        registration = self.registered()
        claimed = self.claim(registration["keeper_pid"])
        token = claimed["claim"]["token"]
        end = time.monotonic() + 2.5 * SILENCE
        while time.monotonic() < end:
            self.tool_call()
            self.assertTrue(running(registration["keeper_pid"]))
            time.sleep(SILENCE / 3)
        self.assertGreaterEqual(self.renewals(token), 4)
        self.hook(self.payload("Stop"))
        self.wait_keeper_gone(registration)
        renewer = claimed["claim"]["renewer"]["pid"]
        wait_until(lambda: not running(renewer), "the renewer outlived its lapsed lease")

    def test_a_failed_tool_is_progress_too(self):
        if "PostToolUseFailure" not in self.spec["tool_events"]:
            self.skipTest("this runtime reports a failed tool through PostToolUse")
        registration = self.registered()
        end = time.monotonic() + 2 * SILENCE
        while time.monotonic() < end:
            self.hook(self.payload("PostToolUseFailure"))
            time.sleep(SILENCE / 3)
        self.assertTrue(running(registration["keeper_pid"]))


class WrappedCommands(AdapterCase):
    def test_a_wrapped_long_command_keeps_renewal_alive_past_the_silence_window(self):
        registration = self.registered()
        attempt = registration["attempt"]
        claimed = self.claim(registration["keeper_pid"])
        tool_use_id = "tool-build"
        command = self.run_command_text(attempt, "build")
        self.hook(self.payload("PreToolUse", tool_use_id=tool_use_id, command=command))
        wrapped = self.wrapper(attempt, "build", 3 * SILENCE)
        time.sleep(2.2 * SILENCE)
        self.assertTrue(running(registration["keeper_pid"]), "the wrapped command's exemption did not hold")
        before = self.renewals(claimed["claim"]["token"])
        time.sleep(4 * RENEWAL)
        self.assertGreater(self.renewals(claimed["claim"]["token"]), before)
        self.assertEqual(wrapped.wait(timeout=SETTLE), 0)
        self.hook(self.payload("PostToolUse", tool_use_id=tool_use_id, command=command))
        self.wait_keeper_gone(registration, timeout=SILENCE + SETTLE)
        self.assertEqual(self.ended(attempt)["reason"], "silence")

    def test_a_killed_foreground_wrapper_ends_its_exemption(self):
        # The foreground interrupt: the runtime kills the tool's processes and
        # sends no tool-finish event.
        registration = self.registered()
        attempt = registration["attempt"]
        self.hook(self.payload("PreToolUse", tool_use_id="tool-kill", command=self.run_command_text(attempt, "suite")))
        wrapped = self.wrapper(attempt, "suite", 600, new_session=True)
        wait_until(lambda: self.status(attempt)["exempt_launches"] == ["suite"], "the launch never became exempt")
        killed_at = time.monotonic()
        os.killpg(wrapped.pid, signal.SIGKILL)
        wrapped.wait(timeout=SETTLE)
        self.wait_keeper_gone(registration, timeout=SILENCE + SETTLE)
        self.assertLess(time.monotonic() - killed_at, SILENCE + 2 * LIVENESS.KEEPER_POLL_SECONDS + 1)
        self.assertEqual(self.ended(attempt)["reason"], "silence")

    def test_a_command_that_outlives_its_tool_call_gets_no_exemption(self):
        # A runtime-backgrounded launch: the tool call returns at once while the
        # wrapper keeps running, and the process survives any interruption.
        registration = self.registered()
        attempt = registration["attempt"]
        command = self.run_command_text(attempt, "background")
        self.hook(self.payload("PreToolUse", tool_use_id="tool-bg", command=command))
        wrapped = self.wrapper(attempt, "background", 600)
        self.hook(self.payload("PostToolUse", tool_use_id="tool-bg", command=command))
        self.wait_keeper_gone(registration, timeout=SILENCE + SETTLE)
        self.assertIsNone(wrapped.poll(), "the surviving command should still be running")
        self.assertEqual(self.ended(attempt)["reason"], "silence")

    def test_a_survivor_the_exemption_cannot_name_is_still_reported_unfinished(self):
        # Issue #684. `exempt_launches` answers "what keeps the keeper alive"
        # and therefore skips a launch whose tool call has finished -- which is
        # precisely the runtime-backgrounded command that outlives a cancelled
        # attempt, and on Claude Code its finish event arrives about 80 ms after
        # it starts. A caller about to delete the attempt's working directory
        # needs the other question answered, so `unfinished_launches` ignores
        # the finish record and reports the process.
        registration = self.registered()
        attempt = registration["attempt"]
        command = self.run_command_text(attempt, "background")
        self.hook(self.payload("PreToolUse", tool_use_id="tool-bg", command=command))
        wrapped = self.wrapper(attempt, "background", 600)
        self.hook(self.payload("PostToolUse", tool_use_id="tool-bg", command=command))
        wait_until(
            lambda: self.status(attempt)["unfinished_launches"] == ["background"],
            "the surviving launch was never reported unfinished",
        )
        self.assertEqual(self.status(attempt)["exempt_launches"], [])
        # It stays reported after the attempt ends, which is when a reclaim
        # pass asks: an ended attempt whose command is still running is exactly
        # the one whose directory must not be removed.
        self.wait_keeper_gone(registration, timeout=SILENCE + SETTLE)
        ended = self.status(attempt)
        self.assertEqual(ended["status"], "ended")
        self.assertEqual(ended["unfinished_launches"], ["background"])
        self.assertIsNone(wrapped.poll(), "the surviving command should still be running")
        # Killing the *wrapper* is not the command ending: it runs no handler
        # on SIGKILL, so the command it started outlives it and the launch is
        # still reported. This is the round-11 blocker, as a regression.
        wrapped.kill()
        wrapped.wait(timeout=SETTLE)
        self.assertEqual(self.status(attempt)["unfinished_launches"], ["background"])
        # Once the command itself is gone, so is the report -- the directory
        # is then free to reclaim.
        self.kill_wrapped(wrapped)
        wait_until(
            lambda: self.status(attempt)["unfinished_launches"] == [],
            "the launch stayed unfinished after its process exited",
        )

    def test_an_unreadable_or_foreign_launch_record_fails_closed(self):
        # The exemption fails open on a record it cannot place, because a
        # launch it cannot verify must not hold the silence window open.
        # Cleanup needs the opposite: "not known to be gone" keeps the
        # directory, because deleting a worktree a live process is working in
        # is the one outcome nothing later can repair.
        registration = self.registered()
        attempt = registration["attempt"]
        directory = Path(registration["records"]) / "launches"
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "unreadable.wrapper.json").write_text("{not json", encoding="utf-8")
        (directory / "foreign.wrapper.json").write_text(
            json.dumps({
                "host": "another-host.invalid", "pid": 1,
                "command_pid": 1, "at": time.time(),
            }),
            encoding="utf-8",
        )
        here = LEDGER.socket.gethostname()
        # A wrapper that is gone AND recorded its command, which is also gone.
        (directory / "gone.wrapper.json").write_text(
            json.dumps({
                "host": here, "pid": self.exited_pid(),
                "command_pid": self.exited_pid(), "at": time.time(),
            }),
            encoding="utf-8",
        )
        # A wrapper that is gone and said so: the end it waited out is the
        # other positive the reader accepts.
        (directory / "ended.wrapper.json").write_text(
            json.dumps({
                "host": here, "pid": self.exited_pid(),
                "command_pid": self.exited_pid(),
                "ended_at": time.time(), "at": time.time(),
            }),
            encoding="utf-8",
        )
        # A wrapper that is gone with neither: killed before it spawned, or a
        # moment after, and nothing here tells those apart. Fails closed.
        (directory / "spawnless.wrapper.json").write_text(
            json.dumps({"host": here, "pid": self.exited_pid(), "at": time.time()}),
            encoding="utf-8",
        )
        # A command still running under a wrapper that is gone: the round-11
        # blocker's own shape, and the one the wrapper's pid answered wrongly.
        survivor = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(600)"])
        self.pids.append(survivor.pid)
        self.addCleanup(self.reap, survivor)
        (directory / "orphaned.wrapper.json").write_text(
            json.dumps({
                "host": here, "pid": self.exited_pid(),
                "command_pid": survivor.pid, "at": time.time(),
            }),
            encoding="utf-8",
        )
        self.assertEqual(
            self.status(attempt)["unfinished_launches"],
            ["foreign", "orphaned", "spawnless", "unreadable"],
        )
        self.assertEqual(self.status(attempt)["exempt_launches"], [])

    def exited_pid(self):
        process = subprocess.Popen([sys.executable, "-c", "raise SystemExit(0)"])
        process.wait(timeout=SETTLE)
        return process.pid

    def test_a_reused_label_stays_visible_to_cleanup(self):
        # Issue #684. A reused `--launch` label loses the exclusive wrapper
        # record -- the first launch holds it -- and `run` starts the child
        # anyway. If nothing else recorded that second wrapper, cleanup would
        # see the first one exit, read "nothing running", and delete the
        # working directory out from under a live process.
        registration = self.registered()
        attempt = registration["attempt"]
        command = self.run_command_text(attempt, "build")
        self.hook(self.payload("PreToolUse", tool_use_id="tool-1", command=command))
        first = self.wrapper(attempt, "build", 600)
        wait_until(
            lambda: self.status(attempt)["unfinished_launches"] == ["build"],
            "the first launch was never reported",
        )
        second = self.wrapper(attempt, "build", 600)
        wait_until(
            lambda: len(
                list((Path(registration["records"]) / "launches").glob("build*.wrapper.json"))
            )
            == 2,
            "the reused launch recorded no wrapper of its own",
        )
        # The exemption is the first launch's alone, and stays so.
        self.assertEqual(self.status(attempt)["exempt_launches"], ["build"])
        # The first wrapper goes, with the command it started; the second is
        # still running, and still reported under the same label.
        self.kill_wrapped(first)
        wait_until(
            lambda: self.status(attempt)["exempt_launches"] == [],
            "the exemption outlived the wrapper holding it",
        )
        self.assertEqual(self.status(attempt)["unfinished_launches"], ["build"])
        self.assertIsNone(second.poll(), "the second wrapper should still be running")
        self.kill_wrapped(second)
        wait_until(
            lambda: self.status(attempt)["unfinished_launches"] == [],
            "a launch stayed unfinished after both wrappers and their commands exited",
        )

    def test_an_unconnected_or_reused_launch_gets_no_exemption(self):
        registration = self.registered()
        attempt = registration["attempt"]
        # No tool-start event names this launch at all.
        self.wrapper(attempt, "unconnected", 600)
        # And a label launched by two tool calls names neither.
        command = self.run_command_text(attempt, "twice")
        self.hook(self.payload("PreToolUse", tool_use_id="tool-1", command=command))
        self.hook(self.payload("PreToolUse", tool_use_id="tool-2", command=command))
        self.wrapper(attempt, "twice", 600)
        self.wait_keeper_gone(registration, timeout=SILENCE + SETTLE)
        self.assertEqual(self.ended(attempt)["reason"], "silence")

    def test_the_wrapper_exits_as_its_command_does(self):
        registration = self.registered()
        completed = self.helper(
            "run", "--root", str(self.root), "--attempt", registration["attempt"], "--launch", "exit",
            "--", sys.executable, "-c", "raise SystemExit(7)",
        )
        self.assertEqual(completed.returncode, 7)


class SilenceAndTakeover(AdapterCase):
    def test_silence_ends_the_keeper_and_the_claim_lapses_and_is_taken_over(self):
        first = self.registered()
        claimed = self.claim(first["keeper_pid"])
        self.wait_keeper_gone(first, timeout=SILENCE + SETTLE)
        self.assertEqual(self.ended(first["attempt"])["reason"], "silence")
        wait_until(lambda: not running(claimed["claim"]["renewer"]["pid"]), "the renewer did not stop")
        second = self.registered(session="session-b", invocation="invocation-9")
        taken = self.claim(second["keeper_pid"])
        self.assertEqual(taken["takeover"], {"previous_token": claimed["claim"]["token"]})

    def test_old_owner_events_after_expiry_and_takeover_affect_nothing(self):
        first = self.registered()
        claimed = self.claim(first["keeper_pid"])
        self.wait_keeper_gone(first, timeout=SILENCE + SETTLE)
        wait_until(lambda: not running(claimed["claim"]["renewer"]["pid"]), "the renewer did not stop")
        second = self.registered(session="session-b", invocation="invocation-9")
        taken = self.claim(second["keeper_pid"])
        token = taken["claim"]["token"]
        second_progress = (Path(second["records"]) / "progress.json")
        before = second_progress.read_bytes() if second_progress.exists() else None
        for event in (*self.spec["tool_events"], *self.spec["terminal_events"]):
            self.hook(self.payload(event))
        self.tool_call(session="session-b", invocation="invocation-9")
        self.assertTrue(running(second["keeper_pid"]))
        self.assertIsNone(self.ended(second["attempt"]))
        self.assertNotEqual(before, second_progress.read_bytes())
        renewed = self.renewals(token)
        time.sleep(4 * RENEWAL)
        self.assertGreater(self.renewals(token), renewed)
        discarded = (Path(first["records"]) / "discarded.jsonl").read_text().splitlines()
        self.assertEqual(len(discarded), len(self.spec["tool_events"]) + len(self.spec["terminal_events"]))


class TerminalEvents(AdapterCase):
    def test_session_end_ends_every_attempt_the_session_registered(self):
        registration = self.registered()
        self.hook(self.payload("SessionEnd"))
        self.wait_keeper_gone(registration, timeout=3)
        self.assertEqual(self.ended(registration["attempt"])["reason"], "SessionEnd")

    def test_interrupt_ends_the_keeper_at_once_where_the_runtime_reports_it(self):
        registration = self.registered()
        self.hook(self.payload("Interrupt"))
        if self.BRAND == "codex":
            self.wait_keeper_gone(registration, timeout=3)
            self.assertEqual(self.ended(registration["attempt"])["reason"], "Interrupt")
        else:
            # Claude Code has no such event; a payload naming one changes nothing.
            time.sleep(SILENCE / 2)
            self.assertIsNone(self.ended(registration["attempt"]))

    def test_unreadable_bookkeeping_ends_the_keeper(self):
        registration = self.registered()
        (Path(registration["records"]) / "attempt.json").write_text("{not json", encoding="utf-8")
        self.wait_keeper_gone(registration, timeout=3)
        self.assertTrue(self.ended(registration["attempt"])["reason"].startswith("unreadable"))

    def test_a_keeper_killed_outright_is_a_lost_signal_to_the_renewer(self):
        registration = self.registered()
        claimed = self.claim(registration["keeper_pid"])
        os.kill(registration["keeper_pid"], signal.SIGKILL)
        wait_until(lambda: not running(claimed["claim"]["renewer"]["pid"]), "the renewer outlived its owner")


class EventBinding(AdapterCase):
    def test_duplicate_delayed_and_out_of_order_events(self):
        registration = self.registered()
        attempt = registration["attempt"]
        records = Path(registration["records"])
        # A tool-finish for a tool call nobody started records no launch.
        self.hook(self.payload("PostToolUse", tool_use_id="never-started"))
        self.assertFalse((records / "launches").exists())
        terminal = "Stop"
        self.hook(self.payload(terminal))
        self.hook(self.payload(terminal))
        self.wait_keeper_gone(registration, timeout=3)
        self.assertEqual(self.ended(attempt)["reason"], terminal)
        progress = (records / "progress.json").read_bytes()
        self.tool_call()
        self.assertEqual((records / "progress.json").read_bytes(), progress)
        self.assertEqual(len((records / "discarded.jsonl").read_text().splitlines()), 3)

    def test_replay_with_unrelated_work_and_a_newer_attempt(self):
        first = self.registered(invocation="turn-a")
        first_records = Path(first["records"])
        if self.BRAND == "codex":
            self.hook(self.payload("Interrupt", invocation="turn-a"))
        # Unrelated work in the same session, in its own invocations.
        snapshot = self.tree_snapshot()
        self.tool_call(invocation="turn-unrelated")
        self.hook(self.payload("Stop", invocation="turn-unrelated"))
        self.assertEqual(self.tree_snapshot(), snapshot, "unrelated work touched the attempt's records")
        second = self.registered(invocation="turn-b")
        self.wait_keeper_gone(first, timeout=SILENCE + SETTLE)
        self.assertIn(self.ended(first["attempt"])["reason"], ("Interrupt", "superseded"))
        second_before = self.tree_snapshot()
        second_before = {k: v for k, v in second_before.items() if second["attempt"] in k}
        # The first attempt's delayed events arrive now.
        self.hook(self.payload("PostToolUse", invocation="turn-a", tool_use_id="late-tool"))
        self.hook(self.payload("Stop", invocation="turn-a"))
        after = {k: v for k, v in self.tree_snapshot().items() if second["attempt"] in k}
        self.assertEqual(after, second_before)
        self.assertTrue(running(second["keeper_pid"]))
        self.assertIsNone(self.ended(second["attempt"]))
        self.assertGreaterEqual(len((first_records / "discarded.jsonl").read_text().splitlines()), 2)

    def test_concurrent_sessions_and_repositories_stay_isolated(self):
        first = self.registered(session="session-a", invocation="i-a")
        second = self.registered(session="session-b", invocation="i-b")
        other = Path(self.directory.name).resolve() / "other"
        other.mkdir()
        git(other, "init", "-q")
        self.hook(self.payload("Stop", session="session-a", invocation="i-a", cwd=other))
        self.assertFalse((other / ".git" / LIVENESS.RUNTIME_DIRECTORY).exists())
        self.assertTrue(running(first["keeper_pid"]))
        self.hook(self.payload("Stop", session="session-a", invocation="i-a"))
        self.wait_keeper_gone(first, timeout=3)
        self.assertTrue(running(second["keeper_pid"]))
        self.assertIsNone(self.ended(second["attempt"]))

    def test_unregistered_sessions_write_nothing(self):
        every = (*self.spec["tool_events"], *self.spec["terminal_events"])
        for event in every:
            self.hook(self.payload(event, session="stranger"))
        self.assertFalse((self.common / LIVENESS.RUNTIME_DIRECTORY).exists())
        registration = self.registered()
        snapshot = self.tree_snapshot()
        for event in every:
            self.hook(self.payload(event, session="stranger"))
        self.assertEqual(self.tree_snapshot(), snapshot)
        self.assertTrue(running(registration["keeper_pid"]))

    def test_a_linked_worktree_session_shares_the_common_directory(self):
        worktree = Path(self.directory.name).resolve() / "linked"
        git(self.root, "worktree", "add", "-q", str(worktree))
        self.addCleanup(git, self.root, "worktree", "remove", "--force", str(worktree))
        self.assertEqual(LIVENESS.git_common_directory(worktree), self.common)
        self.assertEqual(
            Path(git(worktree, "rev-parse", "--path-format=absolute", "--git-common-dir").strip()).resolve(),
            self.common,
        )
        registration = self.registered()
        self.hook(self.payload("Stop", cwd=worktree))
        self.wait_keeper_gone(registration, timeout=3)


class RefusalsBeforeClaim(AdapterCase):
    def assert_nothing_registered(self):
        self.assertEqual(LIVENESS._attempt_ids(self.common), [])

    def test_hooks_that_are_not_running_refuse_before_any_attempt(self):
        completed = self.register(handshake=False)
        self.refused(completed, "hooks-not-observed")
        self.assert_nothing_registered()
        if self.BRAND == "codex":
            self.assertIn("`[features] hooks` flag is true", completed.stderr)
            self.assertIn("trust hash", completed.stderr)

    def test_a_disabled_codex_hooks_flag_is_named(self):
        if self.BRAND != "codex":
            self.skipTest("the feature flag is Codex's")
        self.set_version(self.spec["version"], codex_hooks_flag="false")
        (self.codex_home / "config.toml").write_text(
            '[hooks.state."kanban@kanban:hooks/hooks.json:stop:0:0"]\nenabled = false\n',
            encoding="utf-8",
        )
        completed = self.register(handshake=False)
        self.refused(completed, "hooks-not-observed")
        self.assertIn("`[features] hooks` flag is false", completed.stderr)
        self.assertIn("1 are disabled", completed.stderr)

    def test_an_old_unparseable_or_missing_runtime_refuses(self):
        for text, reason in (
            (self.spec["old_version"], "runtime-unsupported"),
            ("something else entirely", "runtime-unsupported"),
        ):
            with self.subTest(version=text):
                self.set_version(text)
                self.refused(self.register(), reason)
        (self.bin / self.BRAND).unlink()
        self.env["PATH"] = str(self.bin)
        completed = subprocess.run(
            [sys.executable, str(self.liveness), "register", "--runtime", self.BRAND, "--root", str(self.root),
             "--repo", REPO, "--nonce", "0" * 32],
            capture_output=True, text=True, env=self.env, timeout=60,
        )
        self.refused(completed, "runtime-unavailable")
        self.assert_nothing_registered()

    def test_a_newer_runtime_is_accepted(self):
        newer = {"claude": "2.2.0 (Claude Code)", "codex": "codex-cli 0.200.1"}[self.BRAND]
        self.set_version(newer)
        self.registered()

    def test_a_silence_window_shorter_than_the_renewal_interval_refuses(self):
        completed = self.register(silence=0.5, renewal=1.0)
        self.refused(completed, "silence-too-short")
        self.assertIn("0.5", completed.stderr)
        self.assert_nothing_registered()
        # The interval compared is the one the claim would record: the ledger's
        # default when no override is given.
        self.refused(self.register(silence=30, renewal=None), "silence-too-short")

    def test_a_hook_from_another_installed_bundle_refuses(self):
        other = BRANDS["codex" if self.BRAND == "claude" else "claude"]["liveness"]
        nonce = self.helper("nonce").stdout.strip()
        arguments = ["register", "--runtime", self.BRAND, "--root", str(self.root), "--repo", REPO,
                     "--nonce", nonce, "--silence", str(SILENCE), "--renewal", str(RENEWAL), "--handshake-wait", "0.3"]
        command = f"python3 {self.liveness} " + " ".join(arguments)
        self.hook(self.payload("PreToolUse", command=command), liveness=REPO_ROOT / other)
        self.refused(self.helper(*arguments), "bundle-mismatch")
        self.assert_nothing_registered()


class CompleteHookSet(AdapterCase):
    def test_every_required_hook_must_be_declared(self):
        hooks_path = self.bundle / "hooks" / "hooks.json"
        document = json.loads(hooks_path.read_text(encoding="utf-8"))
        del document["hooks"]["Stop"]
        hooks_path.write_text(json.dumps(document), encoding="utf-8")
        completed = self.register()
        self.refused(completed, "hooks-incomplete")
        self.assertIn("Stop", completed.stderr)
        self.assertEqual(LIVENESS._attempt_ids(self.common), [])

    def test_a_second_responding_bundle_copy_refuses(self):
        other = REPO_ROOT / BRANDS["codex" if self.BRAND == "claude" else "claude"]["liveness"]
        nonce = self.helper("nonce").stdout.strip()
        arguments = ["register", "--runtime", self.BRAND, "--root", str(self.root), "--repo", REPO,
                     "--nonce", nonce, "--silence", str(SILENCE), "--renewal", str(RENEWAL), "--handshake-wait", "0.3"]
        command = f"python3 {self.liveness} " + " ".join(arguments)
        # Both copies receive the same PreToolUse, in either order.
        self.hook(self.payload("PreToolUse", command=command))
        self.hook(self.payload("PreToolUse", command=command), liveness=other)
        completed = self.helper(*arguments)
        self.refused(completed, "bundle-ambiguous")
        self.assertIn(str(other), completed.stderr)
        self.assertIn(str(self.liveness), completed.stderr)
        self.assertEqual(LIVENESS._attempt_ids(self.common), [])

    def test_codex_partial_trust_or_enablement_refuses(self):
        if self.BRAND != "codex":
            self.skipTest("Claude Code loads a plugin's hooks as a unit, with no per-hook trust")
        prefix = "kanban@kanban:hooks/hooks.json:"
        cases = (
            ({prefix + "stop:0:0": None}, "hooks-untrusted", "Stop not trusted"),
            ({prefix + "session_end:0:0": {"trusted_hash": "sha256:" + "0" * 64}}, "hooks-untrusted", "SessionEnd changed since trusted"),
            ({prefix + "interrupt:0:0": {"trusted_hash": CODEX_RECORDED_TRUST[prefix + "interrupt:0:0"], "enabled": False}}, "hooks-disabled", "Interrupt is disabled"),
        )
        for overrides, reason, text in cases:
            with self.subTest(reason=reason, text=text):
                self.trust_codex_hooks(overrides)
                completed = self.register()
                self.refused(completed, reason)
                self.assertIn(text, completed.stderr)
                self.assertEqual(LIVENESS._attempt_ids(self.common), [])
        self.trust_codex_hooks()
        self.set_version(self.spec["version"], codex_hooks_flag="false")
        completed = self.register()
        self.refused(completed, "hooks-disabled")
        self.assertIn("flag as false", completed.stderr)
        self.set_version(self.spec["version"])
        self.registered()


class Packaging(unittest.TestCase):
    def test_the_codex_trust_hash_matches_what_codex_recorded(self):
        spec = BRANDS["codex"]
        hooks = json.loads((REPO_ROOT / spec["hooks"]).read_text(encoding="utf-8"))["hooks"]
        computed = {}
        for event, groups in hooks.items():
            for group_index, group in enumerate(groups):
                for handler_index, handler in enumerate(group["hooks"]):
                    key = f"kanban@kanban:hooks/hooks.json:{LIVENESS.CODEX_EVENT_LABELS[event]}:{group_index}:{handler_index}"
                    computed[key] = LIVENESS.codex_hook_hash(event, group, handler)
        self.assertEqual(computed, CODEX_RECORDED_TRUST)

    def test_the_hooks_files_run_the_command_the_adapter_expects(self):
        for brand, spec in BRANDS.items():
            with self.subTest(brand=brand):
                hooks = json.loads((REPO_ROOT / spec["hooks"]).read_text(encoding="utf-8"))["hooks"]
                self.assertEqual(set(hooks), set(LIVENESS.required_events(brand)))
                for groups in hooks.values():
                    for group in groups:
                        for handler in group["hooks"]:
                            self.assertEqual(handler["command"], LIVENESS.RUNTIMES[brand]["hook_command"])

    def test_both_bundles_ship_the_same_adapter(self):
        self.assertEqual(
            (REPO_ROOT / BRANDS["claude"]["liveness"]).read_bytes(),
            (REPO_ROOT / BRANDS["codex"]["liveness"]).read_bytes(),
        )

    def test_the_records_share_the_ledger_runtime_directory(self):
        self.assertEqual(LIVENESS.RUNTIME_DIRECTORY, LEDGER.RUNTIME_DIRECTORY)
        self.assertNotEqual(LIVENESS.LIVENESS_DIRECTORY, "leases")
        self.assertNotEqual(LIVENESS.LIVENESS_DIRECTORY, "checkpoints")

    def test_each_hooks_file_runs_its_own_bundled_adapter_for_exactly_its_events(self):
        for brand, spec in BRANDS.items():
            with self.subTest(brand=brand):
                hooks = json.loads((REPO_ROOT / spec["hooks"]).read_text(encoding="utf-8"))["hooks"]
                expected = set(spec["tool_events"]) | set(spec["terminal_events"])
                self.assertEqual(set(hooks), expected)
                relative = Path(spec["liveness"]).relative_to(spec["bundle_root"])
                for event, groups in hooks.items():
                    for group in groups:
                        for handler in group["hooks"]:
                            self.assertEqual(
                                handler["command"],
                                f'python3 "{spec["root_variable"]}/{relative}" hook --runtime {brand}',
                            )
                            if brand == "codex" and event in ("SessionEnd", "Interrupt"):
                                self.assertLessEqual(handler["timeout"], 3)

    def test_the_hook_never_speaks_or_fails_on_input_it_cannot_read(self):
        for brand, spec in BRANDS.items():
            for text in ("", "not json", "[]", json.dumps({"hook_event_name": "Stop"})):
                with self.subTest(brand=brand, text=text):
                    completed = subprocess.run(
                        [sys.executable, str(REPO_ROOT / spec["liveness"]), "hook", "--runtime", brand],
                        input=text, capture_output=True, text=True, timeout=60,
                    )
                    self.assertEqual((completed.returncode, completed.stdout), (0, ""))

    def test_the_installed_project_review_workflow_registers_before_it_claims(self):
        # #684 performed the switch-over: the installed workflow's PR mode
        # registers an attempt through this adapter and hands its keeper to the
        # ledger's `claim`, so this module is no longer a mechanism nothing
        # calls. The cursor survives in the explicit-only direct section until
        # LEDGER-8 retires it, which is why its presence is asserted too.
        #
        # What each asset *says* about the adapter is
        # tools/test_project_review_workflow.py's contract; what is pinned here
        # is the coupling itself -- that the caller names this module and the
        # flag its keeper is passed through.
        for asset in (
            "claude-plugin/plugins/kanban/commands/project-review.md",
            "codex-plugin/plugins/kanban/skills/project-review/SKILL.md",
            "tools/command_sources/project-review.md",
        ):
            with self.subTest(asset=asset):
                text = (REPO_ROOT / asset).read_text(encoding="utf-8")
                self.assertIn("project_review_ledger.py", text)
                self.assertIn("project_review_liveness.py", text)
                self.assertIn("--owner-pid", text)
                self.assertNotIn("--liveness-fd", text)


def _brand_cases():
    for mixin in (RegistrationAndCompletion, WrappedCommands, SilenceAndTakeover, TerminalEvents, EventBinding, RefusalsBeforeClaim, CompleteHookSet):
        for brand in BRANDS:
            name = f"{brand.capitalize()}{mixin.__name__}Tests"
            globals()[name] = type(name, (mixin, unittest.TestCase), {"BRAND": brand})


_brand_cases()


if __name__ == "__main__":
    unittest.main()
