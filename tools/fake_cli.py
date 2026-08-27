"""Scriptable stand-in for the gh/codex/claude executables drain_prs.py shells
out to. Reused across drain_prs.py test scenarios: each scenario installs the
binaries it needs on a temporary PATH, scripts canned responses, and inspects
recorded invocations afterward.

Not a test module itself (no test_*.py prefix), so `unittest discover` never
collects it directly; test modules import it as a plain library.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import sys
import tempfile
import time
from pathlib import Path


SHIM_TEMPLATE = """#!/usr/bin/env python3
import sys
sys.path.insert(0, {fake_cli_dir!r})
import fake_cli
sys.exit(fake_cli.run_as({binary!r}, sys.argv[1:]))
"""


def _responses_path(state_dir: Path, binary: str) -> Path:
    return state_dir / f"{binary}.responses.jsonl"


def _calls_path(state_dir: Path, binary: str) -> Path:
    return state_dir / f"{binary}.calls.jsonl"


def _match_counts_path(state_dir: Path, binary: str) -> Path:
    return state_dir / f"{binary}.match_counts.json"


def perform_side_effect(effect: dict) -> None:
    """Apply one filesystem consequence a scripted command stands in for.

    Some provider commands are only meaningful through what they leave on
    disk -- `codex plugin remove` drops its cached bundle and `codex plugin
    add` copies a fresh one back -- so a scenario checking what the caller
    does *after* such a command has to be able to model that, rather than
    scripting a command that claims success and changes nothing.
    """
    if "remove_tree" in effect:
        shutil.rmtree(effect["remove_tree"], ignore_errors=True)
    elif "copy_tree" in effect:
        source, destination = effect["copy_tree"]
        shutil.copytree(source, destination, dirs_exist_ok=True)
    else:
        raise ValueError(f"fake_cli: unsupported side effect {effect!r}")


def run_as(binary: str, argv: list[str]) -> int:
    """Entry point executed by the installed shim scripts."""
    state_dir = Path(os.environ["FAKE_CLI_STATE_DIR"])
    stdin_text = "" if sys.stdin.isatty() else sys.stdin.read()
    # The working directory is recorded alongside the arguments because for a
    # provider command it is part of the request: `claude`/`codex` resolve
    # project configuration from where they are run, so a caller that ran one
    # in the wrong directory asked a different question with the same words.
    with _calls_path(state_dir, binary).open("a", encoding="utf-8") as handle:
        handle.write(
            json.dumps({"args": argv, "stdin": stdin_text, "cwd": os.getcwd()}) + "\n"
        )

    responses_file = _responses_path(state_dir, binary)
    entries = []
    if responses_file.exists():
        for line in responses_file.read_text(encoding="utf-8").splitlines():
            if line.strip():
                entries.append(json.loads(line))

    matching = [entry for entry in entries if argv[: len(entry["match"])] == entry["match"]]
    if not matching:
        sys.stderr.write(f"fake_cli: no scripted response for {binary} {argv}\n")
        return 99

    # Entries scripted with the exact same match are a queue: the Nth call
    # for that match returns the Nth scripted entry, so a scenario can give
    # different snapshots to repeated calls of the same command (e.g. three
    # `gh pr view 42` responses for the penultimate, final, and post-merge
    # reads). Once exhausted, later calls repeat the last entry, so a test
    # that scripts a single response for a repeated command keeps working
    # unmodified.
    counts_path = _match_counts_path(state_dir, binary)
    counts = json.loads(counts_path.read_text(encoding="utf-8")) if counts_path.exists() else {}
    match = matching[0]["match"]
    key = json.dumps(match)
    same_match = [entry for entry in entries if entry["match"] == match]
    index = min(counts.get(key, 0), len(same_match) - 1)
    entry = same_match[index]
    counts[key] = index + 1
    counts_path.write_text(json.dumps(counts), encoding="utf-8")

    # Before any output, so a caller that times this command out sees exactly
    # what it would see from a wedged real one: nothing, and no exit.
    sleep_seconds = entry.get("sleep_seconds", 0)
    if sleep_seconds:
        time.sleep(sleep_seconds)
    for effect in entry.get("side_effects", []):
        perform_side_effect(effect)
    sys.stdout.write(entry.get("stdout", ""))
    sys.stderr.write(entry.get("stderr", ""))
    return entry.get("exit_code", 0)


class FakeCli:
    """Installs scriptable gh/codex/claude shims on a temporary PATH.

    Usage:
        fake = FakeCli(tmp_path)
        fake.install("gh")
        fake.script("gh", ["pr", "view", "42"], stdout=json.dumps({...}))
        with mock.patch.dict(os.environ, fake.environ_overrides()):
            drain_prs.process_pr(...)
        fake.calls("gh")  # -> recorded invocations for assertions

    Calling script() more than once with the same `match` queues additional
    responses: the Nth call to a matching command returns the Nth scripted
    entry, repeating the last one once the queue is exhausted.
    """

    def __init__(self, root: Path):
        self.bin_dir = root / "bin"
        self.state_dir = root / "state"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self.state_dir.mkdir(parents=True, exist_ok=True)

    def install(self, binary: str) -> None:
        shim = self.bin_dir / binary
        shim.write_text(
            SHIM_TEMPLATE.format(
                fake_cli_dir=str(Path(__file__).resolve().parent),
                binary=binary,
            ),
            encoding="utf-8",
        )
        shim.chmod(shim.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    def script(
        self,
        binary: str,
        match: list[str],
        *,
        stdout: str = "",
        stderr: str = "",
        exit_code: int = 0,
        sleep_seconds: float = 0,
        side_effects: list[dict] | None = None,
    ) -> None:
        """Queue one response. `sleep_seconds` stalls before answering, which
        is how a scenario stands in for a command that has wedged: long enough
        that only a caller bounding the command can get past it.
        `side_effects` gives the command the filesystem consequence the real
        one has -- `{"remove_tree": path}` or `{"copy_tree": [source,
        destination]}` -- for scenarios that check what the caller does with
        the state the command left behind."""
        entry = {
            "match": match,
            "stdout": stdout,
            "stderr": stderr,
            "exit_code": exit_code,
            "sleep_seconds": sleep_seconds,
            "side_effects": list(side_effects or []),
        }
        with _responses_path(self.state_dir, binary).open(
            "a", encoding="utf-8"
        ) as handle:
            handle.write(json.dumps(entry) + "\n")

    def calls(self, binary: str) -> list[dict]:
        path = _calls_path(self.state_dir, binary)
        if not path.exists():
            return []
        return [
            json.loads(line)
            for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]

    def environ_overrides(self) -> dict[str, str]:
        path = f"{self.bin_dir}{os.pathsep}{os.environ.get('PATH', '')}"
        return {"PATH": path, "FAKE_CLI_STATE_DIR": str(self.state_dir)}


def main() -> None:
    sys.exit(run_as(sys.argv[1], sys.argv[2:]))


if __name__ == "__main__":
    main()
