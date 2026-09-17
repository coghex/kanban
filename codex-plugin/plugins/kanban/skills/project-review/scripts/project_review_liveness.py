#!/usr/bin/env python3
"""Session liveness for the project-review lease, supplied by runtime hooks.

    project_review_liveness.py nonce
    project_review_liveness.py register --runtime {claude,codex} --root <path>
        --repo <owner/name> --nonce <hex> [--silence <seconds>] [--renewal <seconds>]
    project_review_liveness.py run --root <path> --attempt <id> --launch <label> -- <command...>
    project_review_liveness.py complete --root <path> --attempt <id>
    project_review_liveness.py status --root <path> --attempt <id>
    project_review_liveness.py hook --runtime {claude,codex}      (lifecycle hooks only)

Issue #687, the prerequisite design D-17's 2026-09-17 amendment names. The
lease `project_review_ledger.py claim` takes renews only while a liveness
signal is held, and `--owner-pid` is one such signal. This module supplies the
process behind that pid -- the *keeper* -- and keeps it alive exactly while the
review invocation that registered it is making progress. It never touches the
lease itself: the claim, its renewer, its timing, its fencing and its takeover
are the ledger helper's, and the keeper's exit is the whole of what this module
tells it.

Why a keeper and not the application. Claude Code documents no hook event for
a user interrupt and none fires (probed on 2.1.274): an interrupt during a
foreground tool kills that tool's processes, and an interrupt between tool
calls leaves the application and every background process running. Codex
documents an `Interrupt` event. So neither the application's lifetime nor a
process the review started is a signal that ends when the invocation does, and
the keeper is instead a process whose own rules decide:

* **Progress keeps it alive.** A tool-start, tool-finish or tool-failure event
  from the invocation that registered the attempt, arriving within the silence
  window, is progress. So is a command started through `run` while its wrapper
  process is alive *and* the tool call that launched it is still in flight --
  its tool-start event arrived and its tool-finish or tool-failure has not. A
  command the runtime backgrounded returns from its tool call at once, so it
  gets no exemption however long its process lives.
* **Terminal events end it at once.** Turn completion (`Stop`, and Claude's
  `StopFailure`), Codex's `Interrupt`, session termination (`SessionEnd`), an
  explicit `complete`, a newer registration by the same session, and runtime
  bookkeeping the keeper can no longer read.
* **Silence ends it.** With no bound event inside the silence window and no
  exempt wrapped command, the keeper ends. That is the bound on a cancellation
  the runtime does not report: the silence window, plus at most one renewer
  poll, plus the lease's expiry.

Events are bound to an invocation, not just a session. Registration records the
runtime session id and the invocation id -- Claude's `prompt_id`, Codex's
`turn_id` -- from the registering tool call's own `PreToolUse` payload, which
the hook writes as a *handshake* keyed by the nonce in that tool call's command
text. Registration refuses when no handshake arrives, which is exactly what a
missing, disabled or untrusted hook looks like, so no claim is ever backed by
hooks that are not firing. `SessionEnd` carries no invocation id on either
runtime and ends every attempt its session registered. An event whose session
and invocation match no current attempt writes nothing; one matching an ended
attempt is discarded and appended to that attempt's log.

Everything lives in `<git common dir>/kanban-project-review/liveness/`, beside
the ledger helper's lock and heartbeat records and in a subdirectory of its own,
so no record here can be mistaken for a lease record and nothing is ever written
to a working tree or `docs/`. The hook resolves that directory from the
payload's `cwd` by reading Git's own `.git` and `commondir` files rather than by
running `git`, because it runs on every tool call of every session the plugin
is enabled in and must cost nothing where no attempt is registered.

It spawns three things: the runtime's own executable (`claude` or `codex`) to
read its version -- and, for a Codex refusal, its hooks feature state -- the keeper -- this same file through `sys.executable` -- and,
for `run`, the command the caller hands it. `hook` spawns nothing and always
exits 0 with nothing on standard output, because both runtimes read a hook's
output and exit status as instructions.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib.util
import json
import os
import re
import secrets
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path
from select import select as wait_readable

# The ledger helper's runtime directory in the Git common directory; this
# module's records are one subdirectory below it (a test holds the two names
# equal).
RUNTIME_DIRECTORY = "kanban-project-review"
LIVENESS_DIRECTORY = "liveness"

HELPER_PATH = Path(__file__).resolve()
LEDGER_FILENAME = "project_review_ledger.py"

# The minimum verified version of each runtime is the version the smoke-test
# evidence (tools/project-review-liveness-evidence.md) was collected on; an
# older or unparseable version refuses, a newer one is accepted.
RUNTIMES = {
    "claude": {
        "executable": "claude",
        "version_re": re.compile(r"\A\s*(\d+)\.(\d+)\.(\d+)\b.*Claude Code"),
        "minimum": (2, 1, 274),
        "invocation_field": "prompt_id",
        "progress_events": ("PreToolUse", "PostToolUse", "PostToolUseFailure"),
        "invocation_terminal_events": ("Stop", "StopFailure"),
        # scripts/project_review_liveness.py below the bundle root
        "bundle_depth": 1,
        "hook_command": 'python3 "${CLAUDE_PLUGIN_ROOT}/scripts/project_review_liveness.py" hook --runtime claude',
    },
    "codex": {
        "executable": "codex",
        "version_re": re.compile(r"\A\s*codex-cli (\d+)\.(\d+)\.(\d+)\b"),
        "minimum": (0, 154, 0),
        "invocation_field": "turn_id",
        "progress_events": ("PreToolUse", "PostToolUse"),
        "invocation_terminal_events": ("Stop", "Interrupt"),
        # skills/project-review/scripts/project_review_liveness.py below the bundle root
        "bundle_depth": 3,
        "hook_command": 'python3 "$PLUGIN_ROOT/skills/project-review/scripts/project_review_liveness.py" hook --runtime codex',
    },
}
SESSION_TERMINAL_EVENTS = ("SessionEnd",)

DEFAULT_SILENCE_SECONDS = 600.0
DEFAULT_RENEWAL_SECONDS = 60.0

# The keeper looks at its records at least this often, so a terminal event
# ends it within a second.
KEEPER_POLL_SECONDS = 1.0
KEEPER_READY_SECONDS = 30.0
KEEPER_READY_BYTE = b"K"

# How long registration waits for its own tool call's handshake, and how old a
# handshake may be before it no longer describes the tool call that is running.
HANDSHAKE_WAIT_SECONDS = 5.0
HANDSHAKE_MAX_AGE_SECONDS = 120.0

VERSION_TIMEOUT_SECONDS = 30.0

# Ended attempts are kept so a late event can be recognized and logged rather
# than silently dropped; registration prunes the ones older than this.
ENDED_RETENTION_SECONDS = 7 * 24 * 3600.0

TOKEN_RE = re.compile(r"\A[0-9a-f]{32}\Z")
LABEL_RE = re.compile(r"\A[A-Za-z0-9._-]{1,64}\Z")
REPO_RE = re.compile(r"\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")

# What the hook looks for in a tool call's command text. The helper's filename
# then the subcommand, and the flags spelled `--flag value` or `--flag=value`.
REGISTER_RE = re.compile(r"project_review_liveness\.py\S*\s+register\b")
RUN_RE = re.compile(r"project_review_liveness\.py\S*\s+run\b")
NONCE_FLAG_RE = re.compile(r"--nonce[ =]['\"]?([0-9a-f]{32})\b")
ATTEMPT_FLAG_RE = re.compile(r"--attempt[ =]['\"]?([0-9a-f]{32})\b")
LAUNCH_FLAG_RE = re.compile(r"--launch[ =]['\"]?([A-Za-z0-9._-]{1,64})(?=['\"]?(?:\s|$))")


class LivenessError(Exception):
    """A refusal: `reason` is one word a caller can branch on."""

    def __init__(self, reason: str, message: str):
        super().__init__(f"refused ({reason}): {message}")
        self.reason = reason


# ---- Where the records live


def git_common_directory(start) -> Path | None:
    """The Git common directory of the repository containing `start`, or None.

    Read from Git's own files, the way `git rev-parse --git-common-dir`
    resolves it: the nearest `.git` directory, or a `.git` file's `gitdir:`,
    and that directory's `commondir` when it has one (a linked worktree).
    """
    try:
        current = Path(start).resolve()
    except (OSError, RuntimeError):
        return None
    for candidate in (current, *current.parents):
        dot_git = candidate / ".git"
        try:
            if dot_git.is_dir():
                git_dir = dot_git
            elif dot_git.is_file():
                text = dot_git.read_text(encoding="utf-8").strip()
                if not text.startswith("gitdir:"):
                    return None
                git_dir = (candidate / text[len("gitdir:"):].strip()).resolve()
            else:
                continue
            commondir = git_dir / "commondir"
            if commondir.is_file():
                return (git_dir / commondir.read_text(encoding="utf-8").strip()).resolve()
            return git_dir.resolve()
        except (OSError, UnicodeDecodeError):
            return None
    return None


def liveness_directory(common: Path) -> Path:
    return Path(common) / RUNTIME_DIRECTORY / LIVENESS_DIRECTORY


def attempts_directory(common: Path) -> Path:
    return liveness_directory(common) / "attempts"


def handshakes_directory(common: Path) -> Path:
    return liveness_directory(common) / "handshakes"


def attempt_directory(common: Path, attempt: str) -> Path:
    return attempts_directory(common) / attempt


def common_for_root(root) -> Path:
    common = git_common_directory(root)
    if common is None:
        raise LivenessError(
            "not-a-repository",
            f"{root} is not inside a Git repository; the liveness records live "
            "in its Git common directory beside the lease's.",
        )
    return common


# ---- Small durable-record primitives


def _write_json_atomically(path: Path, value: dict) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}")
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, path)


def _create_json_exclusively(path: Path, value: dict) -> bool:
    """Write `path` only if nothing holds the name yet; True when this call did."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}")
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True)
        handle.write("\n")
    try:
        os.link(temporary, path)
        return True
    except FileExistsError:
        return False
    finally:
        with contextlib.suppress(OSError):
            os.unlink(temporary)


def _read_json(path: Path):
    """The object at `path`, None when absent; unreadable raises ValueError."""
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except (OSError, UnicodeDecodeError) as error:
        raise ValueError(f"{path} cannot be read ({error})") from error
    try:
        value = json.loads(text)
    except json.JSONDecodeError as error:
        raise ValueError(f"{path} is not JSON ({error})") from error
    if not isinstance(value, dict):
        raise ValueError(f"{path} is not an object")
    return value


def _append_line(path: Path, value: dict) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    line = (json.dumps(value, sort_keys=True) + "\n").encode("utf-8")
    descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        # One write(2): a record appended in pieces could interleave with a
        # concurrent hook's.
        os.write(descriptor, line)
    finally:
        os.close(descriptor)


# ---- Attempts


ATTEMPT_KEYS = (
    "attempt",
    "runtime",
    "runtime_version",
    "session_id",
    "invocation_id",
    "repo",
    "silence_seconds",
    "registered_at",
    "keeper",
)


def read_attempt(common: Path, attempt: str) -> dict:
    record = _read_json(attempt_directory(common, attempt) / "attempt.json")
    if record is None:
        raise ValueError(f"attempt {attempt} has no record")
    missing = [key for key in ATTEMPT_KEYS if key not in record]
    if missing or record["attempt"] != attempt:
        raise ValueError(f"attempt {attempt}'s record is malformed")
    return record


def ended_record(common: Path, attempt: str):
    return _read_json(attempt_directory(common, attempt) / "ended.json")


def end_attempt(common: Path, attempt: str, reason: str) -> bool:
    """Record why an attempt ended; the first reason recorded is the one kept."""
    return _create_json_exclusively(
        attempt_directory(common, attempt) / "ended.json",
        {"at": time.time(), "reason": reason},
    )


def _attempt_ids(common: Path):
    try:
        names = os.listdir(attempts_directory(common))
    except (FileNotFoundError, NotADirectoryError):
        return []
    return sorted(name for name in names if TOKEN_RE.match(name))


def session_attempts(common: Path, runtime: str, session_id: str):
    """Every attempt this runtime session registered, with whether it ended.

    An attempt whose record cannot be read is skipped here: it belongs to no
    session this event can be matched to, and its own keeper ends on it.
    """
    found = []
    for attempt in _attempt_ids(common):
        try:
            record = read_attempt(common, attempt)
            ended = ended_record(common, attempt)
        except ValueError:
            continue
        if record["runtime"] == runtime and record["session_id"] == session_id:
            found.append((record, ended))
    return found


# ---- The hook


def handle_hook(runtime: str, payload: dict) -> None:
    """One lifecycle event. Writes nothing for a session with no attempt."""
    spec = RUNTIMES[runtime]
    event = payload.get("hook_event_name")
    session_id = payload.get("session_id")
    cwd = payload.get("cwd")
    if not isinstance(event, str) or not isinstance(session_id, str) or not session_id:
        return
    if not isinstance(cwd, str) or not cwd:
        return
    invocation_id = payload.get(spec["invocation_field"])
    if not isinstance(invocation_id, str) or not invocation_id:
        invocation_id = None
    command = _tool_command(payload)
    common = git_common_directory(cwd)
    if common is None:
        return

    if (
        event == "PreToolUse"
        and command is not None
        and invocation_id is not None
        and REGISTER_RE.search(command)
    ):
        nonce = NONCE_FLAG_RE.search(command)
        if nonce is not None:
            # One record per responding bundle copy, so a second enabled copy
            # is seen rather than losing a race to the first.
            _create_json_exclusively(
                handshakes_directory(common) / nonce.group(1) / f"{_script_key(HELPER_PATH)}.json",
                {
                    "nonce": nonce.group(1),
                    "runtime": runtime,
                    "session_id": session_id,
                    "invocation_id": invocation_id,
                    "tool_use_id": payload.get("tool_use_id"),
                    "hook_script": str(HELPER_PATH),
                    "at": time.time(),
                },
            )
        return

    if not attempts_directory(common).is_dir():
        return
    attempts = session_attempts(common, runtime, session_id)
    if not attempts:
        return

    if event in SESSION_TERMINAL_EVENTS:
        for record, ended in attempts:
            if ended is None:
                end_attempt(common, record["attempt"], event)
            else:
                _discard(common, record["attempt"], event, payload)
        return

    if event not in spec["progress_events"] and event not in spec["invocation_terminal_events"]:
        return
    if invocation_id is None:
        return
    bound = [(record, ended) for record, ended in attempts if record["invocation_id"] == invocation_id]
    current = [record for record, ended in bound if ended is None]
    if not current:
        for record, _ in bound:
            _discard(common, record["attempt"], event, payload)
        return

    for record in current:
        attempt = record["attempt"]
        if event in spec["invocation_terminal_events"]:
            end_attempt(common, attempt, event)
            continue
        _write_json_atomically(
            attempt_directory(common, attempt) / "progress.json",
            {"at": time.time(), "event": event},
        )
        tool_use_id = payload.get("tool_use_id")
        if not isinstance(tool_use_id, str) or not tool_use_id:
            continue
        if event == "PreToolUse" and command is not None and RUN_RE.search(command):
            named = ATTEMPT_FLAG_RE.search(command)
            label = LAUNCH_FLAG_RE.search(command)
            if named is not None and named.group(1) == attempt and label is not None:
                _record_launch_start(common, attempt, label.group(1), tool_use_id)
        elif event != "PreToolUse":
            _record_launch_finish(common, attempt, tool_use_id, event)


def _script_key(path: Path) -> str:
    return hashlib.sha256(str(path).encode("utf-8")).hexdigest()[:32]


def _tool_command(payload: dict):
    tool_input = payload.get("tool_input")
    if isinstance(tool_input, dict) and isinstance(tool_input.get("command"), str):
        return tool_input["command"]
    return None


def _launches_directory(common: Path, attempt: str) -> Path:
    return attempt_directory(common, attempt) / "launches"


def _record_launch_start(common: Path, attempt: str, label: str, tool_use_id: str) -> None:
    directory = _launches_directory(common, attempt)
    start = {"label": label, "tool_use_id": tool_use_id, "at": time.time()}
    if not _create_json_exclusively(directory / f"{label}.start.json", start):
        # A label launched twice names no one tool call; neither launch is exempt.
        _create_json_exclusively(directory / f"{label}.conflict.json", start)


def _record_launch_finish(common: Path, attempt: str, tool_use_id: str, event: str) -> None:
    directory = _launches_directory(common, attempt)
    try:
        names = os.listdir(directory)
    except (FileNotFoundError, NotADirectoryError):
        return
    for name in names:
        if not name.endswith(".start.json"):
            continue
        with contextlib.suppress(ValueError):
            start = _read_json(directory / name)
            if start is not None and start.get("tool_use_id") == tool_use_id:
                label = name[: -len(".start.json")]
                _create_json_exclusively(
                    directory / f"{label}.finish.json",
                    {"tool_use_id": tool_use_id, "event": event, "at": time.time()},
                )


def _discard(common: Path, attempt: str, event: str, payload: dict) -> None:
    _append_line(
        attempt_directory(common, attempt) / "discarded.jsonl",
        {
            "at": time.time(),
            "event": event,
            "tool_use_id": payload.get("tool_use_id"),
        },
    )


def run_hook(runtime: str, stream) -> int:
    """Never fails the runtime's tool call and never speaks to it."""
    with contextlib.suppress(Exception):
        payload = json.loads(stream.read())
        if isinstance(payload, dict):
            handle_hook(runtime, payload)
    return 0


# ---- The keeper


def _ledger_module():
    """`project_review_ledger.py`, loaded from beside this file.

    For its process-standing test: a wrapper is observed exactly the way the
    ledger observes an owner pid, a zombie included.
    """
    source = HELPER_PATH.parent / LEDGER_FILENAME
    name = "_project_review_ledger_for_liveness"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, source)
    if spec is None or spec.loader is None:
        raise LivenessError("ledger-missing", f"{source} cannot be loaded.")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except Exception:
        del sys.modules[name]
        raise
    return module


def exempt_launches(common: Path, attempt: str, standing) -> list:
    """Labels of wrapped commands that currently keep the keeper alive."""
    directory = _launches_directory(common, attempt)
    try:
        names = os.listdir(directory)
    except (FileNotFoundError, NotADirectoryError):
        return []
    exempt = []
    for name in sorted(names):
        if not name.endswith(".start.json"):
            continue
        label = name[: -len(".start.json")]
        if (directory / f"{label}.finish.json").exists():
            continue
        if (directory / f"{label}.conflict.json").exists():
            continue
        wrapper = _read_json(directory / f"{label}.wrapper.json")
        if wrapper is None:
            continue
        if not isinstance(wrapper.get("pid"), int) or not isinstance(wrapper.get("host"), str):
            continue
        if standing({"host": wrapper["host"], "pid": wrapper["pid"]}) == "live":
            exempt.append(label)
    return exempt


def run_keeper(common: Path, attempt: str, ready_fd=None) -> str:
    """Stay alive while the attempt shows progress; return why it ended."""
    ledger = _ledger_module()
    if ready_fd is not None:
        with contextlib.suppress(OSError):
            os.write(ready_fd, KEEPER_READY_BYTE)
        with contextlib.suppress(OSError):
            os.close(ready_fd)
    while True:
        try:
            if ended_record(common, attempt) is not None:
                return "ended"
            record = read_attempt(common, attempt)
            progress = _read_json(attempt_directory(common, attempt) / "progress.json")
            silence = float(record["silence_seconds"])
            last = float(progress["at"]) if progress is not None else float(record["registered_at"])
            if time.time() - last > silence and not exempt_launches(
                common, attempt, ledger.holder_standing
            ):
                end_attempt(common, attempt, "silence")
                return "silence"
        except (ValueError, KeyError, TypeError) as error:
            with contextlib.suppress(OSError):
                end_attempt(common, attempt, f"unreadable: {error}")
            return "unreadable"
        time.sleep(min(KEEPER_POLL_SECONDS, silence / 4))


def _start_keeper(common: Path, attempt: str):
    ready_read, ready_write = os.pipe()
    try:
        keeper = subprocess.Popen(
            [
                sys.executable,
                str(HELPER_PATH),
                "keeper",
                "--common",
                str(common),
                "--attempt",
                attempt,
                "--ready-fd",
                str(ready_write),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            pass_fds=(ready_write,),
            close_fds=True,
            start_new_session=True,
            cwd="/",
        )
    except OSError as error:
        os.close(ready_read)
        raise LivenessError("keeper-not-started", f"the keeper could not be started ({error}).")
    finally:
        with contextlib.suppress(OSError):
            os.close(ready_write)
    try:
        ready = _await_ready(ready_read)
    finally:
        os.close(ready_read)
    if not ready:
        with contextlib.suppress(OSError):
            keeper.kill()
        with contextlib.suppress(OSError, subprocess.TimeoutExpired):
            keeper.wait(timeout=30)
        raise LivenessError(
            "keeper-not-ready",
            f"the keeper (pid {keeper.pid}) exited or stalled before it was ready; "
            "no attempt was registered.",
        )
    return keeper


def _await_ready(descriptor: int) -> bool:
    end = time.monotonic() + KEEPER_READY_SECONDS
    while True:
        remaining = end - time.monotonic()
        if remaining <= 0:
            return False
        try:
            ready, _, _ = wait_readable([descriptor], [], [], remaining)
            if not ready:
                return False
            return os.read(descriptor, 1) == KEEPER_READY_BYTE
        except InterruptedError:
            continue
        except OSError:
            return False


# ---- Registration


def _version_output(runtime: str):
    """`claude --version` or `codex --version`, spelled literally for the
    workflow contract's command extractor."""
    options = dict(
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=VERSION_TIMEOUT_SECONDS,
    )
    if runtime == "claude":
        return subprocess.run(["claude", "--version"], **options)
    return subprocess.run(["codex", "--version"], **options)


def runtime_version(runtime: str) -> tuple:
    """The installed runtime's version, or a refusal naming what was observed."""
    spec = RUNTIMES[runtime]
    required = ".".join(str(part) for part in spec["minimum"])
    try:
        completed = _version_output(runtime)
    except (OSError, subprocess.SubprocessError) as error:
        raise LivenessError(
            "runtime-unavailable",
            f"`{spec['executable']} --version` could not be run ({error}); "
            f"{runtime} {required} or newer is required.",
        )
    output = (completed.stdout or "").strip()
    match = spec["version_re"].match(output) if completed.returncode == 0 else None
    if match is None:
        raise LivenessError(
            "runtime-unsupported",
            f"`{spec['executable']} --version` reported {output[:120]!r}, which is "
            f"not a version this adapter can read; {runtime} {required} or newer is required.",
        )
    version = tuple(int(part) for part in match.groups())
    if version < spec["minimum"]:
        raise LivenessError(
            "runtime-unsupported",
            f"{runtime} {'.'.join(map(str, version))} is older than {required}, the "
            "minimum version this adapter's lifecycle evidence was collected on.",
        )
    return version


def effective_renewal(root, repo: str, renewal) -> float:
    """The renewal interval a claim taken now would record."""
    ledger = _ledger_module()
    try:
        state = ledger.state_for(ledger.load_document(root), repo)
        return float(ledger.effective_lease_settings(state, renewal, None)["renewal_seconds"])
    except ledger.LedgerError as error:
        raise LivenessError("lease-settings-unreadable", str(error))


def hooks_diagnostic(runtime: str) -> str:
    """What can be said about why no handshake arrived; never decisive."""
    if runtime == "claude":
        return (
            "check that the kanban plugin is installed and enabled (`claude plugin "
            "list`), that `disableAllHooks` is not set in any settings file, and "
            "that the session's working directory is inside the repository."
        )
    parts = []
    flag = _codex_hooks_flag()
    parts.append(f"the `[features] hooks` flag is {flag}")
    # Trust is recorded in `$CODEX_HOME/config.toml` (default `~/.codex`) as
    # `[hooks.state."kanban@<marketplace>:hooks/hooks.json:<event>:..."]`.
    home = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
    trusted, disabled = 0, 0
    try:
        import tomllib

        with open(home / "config.toml", "rb") as handle:
            config = tomllib.load(handle)
        states = config.get("hooks", {}).get("state", {})
        for key, state in states.items():
            if key.startswith("kanban@") and ":hooks/hooks.json:" in key and isinstance(state, dict):
                trusted += 1 if state.get("trusted_hash") else 0
                disabled += 1 if state.get("enabled") is False else 0
        parts.append(
            f"{trusted} kanban hook definition(s) carry a recorded trust hash and "
            f"{disabled} are disabled in {home / 'config.toml'}"
        )
    except FileNotFoundError:
        parts.append(
            f"no kanban hook definition carries a recorded trust hash, because "
            f"{home / 'config.toml'} does not exist"
        )
    except (OSError, ValueError, ImportError, AttributeError) as error:
        parts.append(
            f"whether any kanban hook definition carries a recorded trust hash is "
            f"unknown: {home / 'config.toml'} could not be read ({error})"
        )
    return (
        "; ".join(parts)
        + ". A definition changed since it was trusted shows as modified in "
        "`/hooks` and does not run until it is trusted again."
    )


# The events whose hooks the keeper's contract depends on, per runtime. One
# PreToolUse handshake proves hooks run; it does not prove these do.
def required_events(runtime: str) -> tuple:
    spec = RUNTIMES[runtime]
    return (*spec["progress_events"], *spec["invocation_terminal_events"], *SESSION_TERMINAL_EVENTS)


def bundle_root(runtime: str) -> Path:
    return HELPER_PATH.parents[RUNTIMES[runtime]["bundle_depth"]]


def require_complete_hooks(runtime: str) -> None:
    """Refuse unless every required event's hook is declared, enabled and trusted.

    Declared: the bundle's own `hooks/hooks.json` runs this adapter on every
    required event. Claude Code loads a plugin's hooks file as a unit and has
    no per-hook enablement or trust, so for it that is the whole check. Codex
    enables and trusts each hook separately, so for it every required hook must
    also be enabled and carry a recorded trust hash equal to the hash Codex
    computes for its current definition.
    """
    spec = RUNTIMES[runtime]
    path = bundle_root(runtime) / "hooks" / "hooks.json"
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
        hooks = document["hooks"]
        if not isinstance(hooks, dict):
            raise ValueError("`hooks` is not an object")
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise LivenessError("hooks-incomplete", f"{path} cannot be read ({error}).")
    handlers = {}
    for event in required_events(runtime):
        for group_index, group in enumerate(hooks.get(event) or []):
            for handler_index, handler in enumerate((group or {}).get("hooks") or []):
                if (
                    isinstance(handler, dict)
                    and handler.get("type") == "command"
                    and handler.get("command") == spec["hook_command"]
                ):
                    handlers.setdefault(event, (group_index, group, handler_index, handler))
    missing = [event for event in required_events(runtime) if event not in handlers]
    if missing:
        raise LivenessError(
            "hooks-incomplete",
            f"{path} does not run this adapter on {', '.join(missing)}; every one of "
            f"{', '.join(required_events(runtime))} is required.",
        )
    if runtime == "codex":
        _require_codex_hooks_trusted(handlers)


CODEX_EVENT_LABELS = {
    "PreToolUse": "pre_tool_use",
    "PostToolUse": "post_tool_use",
    "Stop": "stop",
    "Interrupt": "interrupt",
    "SessionEnd": "session_end",
}
# Events whose `additionalContextLimit` Codex keeps, and its default, which it
# drops from the hashed definition.
CODEX_CONTEXT_EVENTS = ("PreToolUse", "PostToolUse", "SessionStart", "UserPromptSubmit", "SubagentStart")
CODEX_DEFAULT_CONTEXT_LIMIT = 2500


def codex_hook_hash(event: str, group: dict, handler: dict) -> str:
    """The trust hash codex-cli records for one command hook.

    codex-rs `hooks/src/engine/discovery.rs::hook_hash` at rust-v0.154.0: the
    event's key label, the group's matcher, and the normalized handler --
    timeout defaulted and clamped per event, `async` explicit, unset options
    omitted -- serialized as key-sorted compact JSON and hashed with SHA-256
    (`config/src/fingerprint.rs::version_for_toml`).
    """
    timeout = handler.get("timeout")
    if event in ("SessionEnd", "Interrupt"):
        timeout = min(max(1 if timeout is None else int(timeout), 1), 3)
    else:
        timeout = max(600 if timeout is None else int(timeout), 1)
    normalized = {
        "type": "command",
        "command": handler["command"],
        "timeout": timeout,
        "async": bool(handler.get("async", False)),
    }
    if handler.get("statusMessage") is not None:
        normalized["statusMessage"] = handler["statusMessage"]
    limit = handler.get("additionalContextLimit")
    if event in CODEX_CONTEXT_EVENTS and limit is not None and limit != CODEX_DEFAULT_CONTEXT_LIMIT:
        normalized["additionalContextLimit"] = limit
    identity = {"event_name": CODEX_EVENT_LABELS[event], "hooks": [normalized]}
    if group.get("matcher") is not None:
        identity["matcher"] = group["matcher"]
    encoded = json.dumps(identity, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return "sha256:" + hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def _codex_hooks_flag() -> str:
    try:
        completed = subprocess.run(
            ["codex", "features", "list"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=VERSION_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError):
        return "unreadable"
    return next(
        (line.split()[-1] for line in completed.stdout.splitlines() if line.split()[:1] == ["hooks"]),
        "unreported",
    )


def _require_codex_hooks_trusted(handlers: dict) -> None:
    flag = _codex_hooks_flag()
    if flag != "true":
        raise LivenessError(
            "hooks-disabled",
            f"`codex features list` reports the `[features] hooks` flag as {flag}; "
            "every required hook needs it on.",
        )
    root = bundle_root("codex")
    # An installed plugin lives at plugins/cache/<marketplace>/<plugin>/<version>.
    if root.parent.parent.parent.name != "cache":
        raise LivenessError(
            "plugin-unresolved",
            f"{root} is not an installed Codex plugin under a plugins/cache "
            "directory, so the hooks' trust records cannot be named.",
        )
    plugin_id = f"{root.parent.name}@{root.parent.parent.name}"
    # Trust is recorded in `$CODEX_HOME/config.toml` (default `~/.codex`).
    config_path = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex") / "config.toml"
    try:
        import tomllib

        with open(config_path, "rb") as handle:
            states = tomllib.load(handle).get("hooks", {}).get("state", {})
    except FileNotFoundError:
        states = {}
    except (OSError, ValueError, ImportError) as error:
        raise LivenessError("hooks-untrusted", f"{config_path} cannot be read ({error}).")
    disabled, untrusted, modified = [], [], []
    for event, (group_index, group, handler_index, handler) in handlers.items():
        key = f"{plugin_id}:hooks/hooks.json:{CODEX_EVENT_LABELS[event]}:{group_index}:{handler_index}"
        state = states.get(key) if isinstance(states, dict) else None
        state = state if isinstance(state, dict) else {}
        if state.get("enabled") is False:
            disabled.append(event)
        recorded = state.get("trusted_hash")
        if recorded is None:
            untrusted.append(event)
        elif recorded != codex_hook_hash(event, group, handler):
            modified.append(event)
    if disabled:
        raise LivenessError(
            "hooks-disabled",
            f"{', '.join(disabled)} {'is' if len(disabled) == 1 else 'are'} disabled for "
            f"{plugin_id} in {config_path}; enable every required hook in `/hooks`.",
        )
    if untrusted or modified:
        parts = []
        if untrusted:
            parts.append(f"{', '.join(untrusted)} not trusted")
        if modified:
            parts.append(f"{', '.join(modified)} changed since trusted")
        raise LivenessError(
            "hooks-untrusted",
            f"{'; '.join(parts)} for {plugin_id} in {config_path}; trust every "
            "required hook in `/hooks`.",
        )


def register(
    runtime: str,
    root,
    repo: str,
    nonce: str,
    silence=None,
    renewal=None,
    handshake_wait: float = HANDSHAKE_WAIT_SECONDS,
) -> dict:
    """Bind this tool call's invocation to a new attempt and start its keeper.

    Every refusal happens before a keeper exists, so nothing is left for a
    claim to be taken against.
    """
    if not TOKEN_RE.match(nonce or ""):
        raise LivenessError("nonce-invalid", "--nonce is 32 lowercase hex digits from `nonce`.")
    if not REPO_RE.match(repo or ""):
        raise LivenessError("repo-invalid", f"{repo!r} is not an owner/name repository.")
    silence = DEFAULT_SILENCE_SECONDS if silence is None else float(silence)
    if not silence > 0:
        raise LivenessError("silence-invalid", "--silence is a positive number of seconds.")
    version = runtime_version(runtime)
    interval = effective_renewal(root, repo, renewal)
    if silence < interval:
        raise LivenessError(
            "silence-too-short",
            f"the silence window is {silence:g} seconds and the claim would renew "
            f"every {interval:g}; the window may not be shorter than the renewal interval.",
        )
    common = common_for_root(root)
    handshake_directory = handshakes_directory(common) / nonce
    give_up = time.monotonic() + handshake_wait
    handshakes = []
    while True:
        try:
            names = sorted(os.listdir(handshake_directory))
        except (FileNotFoundError, NotADirectoryError):
            names = []
        if names or time.monotonic() >= give_up:
            break
        time.sleep(0.05)
    if not names:
        raise LivenessError(
            "hooks-not-observed",
            f"no {runtime} PreToolUse hook recorded this registration's nonce under "
            f"{handshakes_directory(common)}, so the lifecycle hooks this attempt "
            f"depends on are not running: {hooks_diagnostic(runtime)}",
        )
    # Every PreToolUse hook a runtime runs for a tool call has finished before
    # the command starts, so the directory now holds every responding copy.
    for name in names:
        try:
            handshake = _read_json(handshake_directory / name)
        except ValueError as error:
            raise LivenessError("handshake-unreadable", str(error))
        if handshake is not None:
            handshakes.append(handshake)
    with contextlib.suppress(OSError):
        _remove_tree(handshake_directory)
    scripts = sorted({str(handshake.get("hook_script")) for handshake in handshakes})
    if len(handshakes) != 1:
        raise LivenessError(
            "bundle-ambiguous",
            f"{len(handshakes)} installed kanban bundle copies responded to this "
            f"registration ({', '.join(scripts)}); exactly one may be enabled, or "
            "an event could reach an attempt through a copy that is not this one.",
        )
    handshake = handshakes[0]
    if handshake.get("runtime") != runtime:
        raise LivenessError(
            "runtime-mismatch",
            f"the handshake came from a {handshake.get('runtime')!r} hook, not {runtime}.",
        )
    if handshake.get("hook_script") != str(HELPER_PATH):
        raise LivenessError(
            "bundle-mismatch",
            f"the hook that fired is {handshake.get('hook_script')!r} and this "
            f"registration is {HELPER_PATH}; exactly one installed bundle must "
            "serve both, so resolve which kanban bundle is enabled.",
        )
    at = handshake.get("at")
    if not isinstance(at, (int, float)) or time.time() - at > HANDSHAKE_MAX_AGE_SECONDS:
        raise LivenessError("handshake-stale", "the handshake predates this tool call.")
    session_id, invocation_id = handshake.get("session_id"), handshake.get("invocation_id")
    if not (isinstance(session_id, str) and session_id and isinstance(invocation_id, str) and invocation_id):
        raise LivenessError(
            "binding-unavailable",
            f"the {runtime} hook payload carried no session id and "
            f"{RUNTIMES[runtime]['invocation_field']}; an attempt cannot be bound "
            "to its invocation.",
        )

    require_complete_hooks(runtime)

    _prune(common)
    for record, ended in session_attempts(common, runtime, session_id):
        if ended is None:
            end_attempt(common, record["attempt"], "superseded")

    attempt = secrets.token_hex(16)
    now = time.time()
    record = {
        "attempt": attempt,
        "runtime": runtime,
        "runtime_version": ".".join(map(str, version)),
        "session_id": session_id,
        "invocation_id": invocation_id,
        "repo": repo,
        "silence_seconds": silence,
        "registered_at": now,
        "keeper": None,
    }
    directory = attempt_directory(common, attempt)
    directory.mkdir(mode=0o700, parents=True)
    _write_json_atomically(directory / "attempt.json", record)
    try:
        keeper = _start_keeper(common, attempt)
    except LivenessError:
        end_attempt(common, attempt, "keeper-not-ready")
        raise
    record["keeper"] = {"host": socket.gethostname(), "pid": keeper.pid}
    _write_json_atomically(directory / "attempt.json", record)
    return {
        "status": "registered",
        "attempt": attempt,
        "keeper_pid": keeper.pid,
        "runtime": runtime,
        "runtime_version": record["runtime_version"],
        "session_id": session_id,
        "invocation_id": invocation_id,
        "invocation_field": RUNTIMES[runtime]["invocation_field"],
        "silence_seconds": silence,
        "renewal_seconds": interval,
        "records": str(directory),
    }


def _prune(common: Path) -> None:
    now = time.time()
    for attempt in _attempt_ids(common):
        with contextlib.suppress(ValueError, OSError, KeyError, TypeError):
            ended = ended_record(common, attempt)
            if ended is not None and now - float(ended["at"]) > ENDED_RETENTION_SECONDS:
                _remove_tree(attempt_directory(common, attempt))
    with contextlib.suppress(OSError):
        for name in os.listdir(handshakes_directory(common)):
            path = handshakes_directory(common) / name
            with contextlib.suppress(OSError):
                if now - path.stat().st_mtime > HANDSHAKE_MAX_AGE_SECONDS:
                    _remove_tree(path) if path.is_dir() else path.unlink()


def _remove_tree(path: Path) -> None:
    for child in sorted(path.rglob("*"), key=lambda item: len(item.parts), reverse=True):
        if child.is_dir() and not child.is_symlink():
            child.rmdir()
        else:
            child.unlink()
    path.rmdir()


# ---- The wrapper, completion and status


def run_wrapped(root, attempt: str, label: str, command) -> int:
    """Run `command` as a wrapped launch; its exit status is this call's."""
    if not TOKEN_RE.match(attempt or ""):
        raise LivenessError("attempt-invalid", "--attempt is the id `register` printed.")
    if not LABEL_RE.match(label or ""):
        raise LivenessError("launch-invalid", "--launch is 1-64 of A-Z a-z 0-9 . _ -.")
    if not command:
        raise LivenessError("command-missing", "name the command to run after `--`.")
    common = common_for_root(root)
    exempt = False
    if (attempt_directory(common, attempt) / "attempt.json").exists():
        exempt = _create_json_exclusively(
            _launches_directory(common, attempt) / f"{label}.wrapper.json",
            {"host": socket.gethostname(), "pid": os.getpid(), "at": time.time()},
        )
    if not exempt:
        print(
            f"project-review liveness: launch {label} of attempt {attempt} is not "
            "exempt from the silence window (unknown attempt or reused label).",
            file=sys.stderr,
        )
    child = subprocess.Popen(list(command))

    def forward(signum, frame):
        with contextlib.suppress(OSError):
            child.send_signal(signum)

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, forward)
    status = child.wait()
    return status if status >= 0 else 128 - status


def complete(root, attempt: str) -> dict:
    if not TOKEN_RE.match(attempt or ""):
        raise LivenessError("attempt-invalid", "--attempt is the id `register` printed.")
    common = common_for_root(root)
    try:
        read_attempt(common, attempt)
    except ValueError as error:
        raise LivenessError("attempt-unknown", str(error))
    recorded = end_attempt(common, attempt, "completed")
    return {"status": "completed" if recorded else "already-ended", "attempt": attempt, "ended": ended_record(common, attempt)}


def status(root, attempt: str) -> dict:
    if not TOKEN_RE.match(attempt or ""):
        raise LivenessError("attempt-invalid", "--attempt is the id `register` printed.")
    common = common_for_root(root)
    try:
        record = read_attempt(common, attempt)
        ended = ended_record(common, attempt)
        progress = _read_json(attempt_directory(common, attempt) / "progress.json")
    except ValueError as error:
        raise LivenessError("attempt-unknown", str(error))
    ledger = _ledger_module()
    keeper = record["keeper"]
    return {
        "status": "ended" if ended is not None else "active",
        "attempt": attempt,
        "record": record,
        "ended": ended,
        "last_progress": progress,
        "keeper_standing": None if keeper is None else ledger.holder_standing(keeper),
        "exempt_launches": exempt_launches(common, attempt, ledger.holder_standing),
    }


# ---- Command line


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("nonce", help="print a fresh registration nonce")

    registrar = subparsers.add_parser(
        "register", help="bind this tool call's invocation to an attempt and start its keeper"
    )
    registrar.add_argument("--runtime", required=True, choices=sorted(RUNTIMES))
    registrar.add_argument("--root", required=True)
    registrar.add_argument("--repo", required=True)
    registrar.add_argument("--nonce", required=True)
    registrar.add_argument("--silence", type=float, help="seconds without progress that end the keeper")
    registrar.add_argument("--renewal", type=float, help="the --renewal the claim will be given, if any")
    registrar.add_argument("--handshake-wait", type=float, default=HANDSHAKE_WAIT_SECONDS, help=argparse.SUPPRESS)

    runner = subparsers.add_parser("run", help="run a long command as a wrapped launch")
    runner.add_argument("--root", required=True)
    runner.add_argument("--attempt", required=True)
    runner.add_argument("--launch", required=True)
    runner.add_argument("argv", nargs=argparse.REMAINDER)

    for name, text in (("complete", "end an attempt explicitly"), ("status", "report an attempt's state")):
        command = subparsers.add_parser(name, help=text)
        command.add_argument("--root", required=True)
        command.add_argument("--attempt", required=True)

    hook = subparsers.add_parser("hook", help="handle one lifecycle event on standard input")
    hook.add_argument("--runtime", required=True, choices=sorted(RUNTIMES))

    keeper = subparsers.add_parser("keeper", help=argparse.SUPPRESS)
    keeper.add_argument("--common", required=True)
    keeper.add_argument("--attempt", required=True)
    keeper.add_argument("--ready-fd", type=int)
    return parser


def _emit(payload: dict) -> int:
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def main(argv=None) -> int:
    """0 done; 2 refused, with the reason on standard error; `run` exits as its command."""
    args = build_parser().parse_args(argv)
    if args.command == "hook":
        return run_hook(args.runtime, sys.stdin)
    if args.command == "nonce":
        print(secrets.token_hex(16))
        return 0
    if args.command == "register":
        return _emit(
            register(
                args.runtime,
                args.root,
                args.repo,
                args.nonce,
                silence=args.silence,
                renewal=args.renewal,
                handshake_wait=args.handshake_wait,
            )
        )
    if args.command == "run":
        argv = list(args.argv)
        if argv[:1] == ["--"]:
            argv = argv[1:]
        return run_wrapped(args.root, args.attempt, args.launch, argv)
    if args.command == "complete":
        return _emit(complete(args.root, args.attempt))
    if args.command == "status":
        return _emit(status(args.root, args.attempt))
    run_keeper(Path(args.common), args.attempt, args.ready_fd)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except LivenessError as error:
        print(f"project-review liveness: {error}", file=sys.stderr)
        raise SystemExit(2)
