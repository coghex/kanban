#!/usr/bin/env python3

"""The one boundary the PR drainer reaches a service manager through.

`tools/drain_prs_service.py` owns the drainer's lifecycle — repository
identity, clone exclusion, preflights, discovery records, incidents, startup
stabilization, shutdown confirmation — and `tools/install_drainer.py` owns
installation safety. None of that is platform-specific, and none of it belongs
to launchd. What is launchd's lives here: the identifier a job is named and
targeted by, the definition it is written from, and the commands that load,
kick, and stop it.

So this module is the only one that constructs a `launchctl` argument vector,
reads `launchctl` output, serializes or parses a plist, or derives a launchd
domain or target. Its callers describe *what* has to run as a
`ServiceDefinition` and ask this backend to make it so; they never spell a
launchd artifact themselves. That containment is machine-checked against the
tracked tree by `tools/test_agent_workflow_contract.py`, which is what keeps a
later edit from quietly reintroducing one somewhere else.

launchd is deliberately the only backend `select_backend` can return: this
seam exists so a systemd backend can join it later without the lifecycle
above being rewritten, not so a second one lands unverified today.

The command runner is injected rather than imported. Both callers already
spawn through their own thin wrapper — `drain_prs_service.run_command` raises
`ServiceError`, `install_drainer.run` raises `InstallError` — and passing that
wrapper in is what keeps a failure crossing this boundary in the failure
vocabulary its own caller reports, instead of a third exception type neither
side handles.
"""

from __future__ import annotations

import os
import plistlib
import re
import subprocess
import tempfile
from abc import ABC, abstractmethod
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any


HOME = Path.home()

# This module writes the service definitions, so it also owns the identifiers
# they are named and targeted by. Nothing else may restate one:
# `tools/drain_prs_service.py` and `tools/install_drainer.py` both derive
# theirs through this module, and `src/Kanban/Drainer.hs` derives none at all —
# it reads an installed job's label and plist path out of the per-repository
# discovery record the controller writes.
#
# There is one label, and one of every mutable runtime path, per canonical
# GitHub repository: that partitioning is what lets several repositories be
# drained independently on one account. LABEL_PREFIX on its own is the
# machine-wide singleton those replace; it survives only as the legacy job
# `retire_legacy` unloads before a derived job for the same repository is
# allowed to start.
LABEL_PREFIX = "com.coghex.drain-prs"
LEGACY_LABEL = LABEL_PREFIX
LAUNCH_AGENTS_DIR = HOME / "Library" / "LaunchAgents"
LEGACY_PLIST_PATH = LAUNCH_AGENTS_DIR / f"{LEGACY_LABEL}.plist"
# Long enough for every GitHub owner/name pair spelled with ordinary
# characters, short enough that `<label>.plist` stays well inside the 255-byte
# filename limit even after escaping. See `drain_prs_service.repository_slug`,
# which asks `identifier_fits` rather than restating this number.
MAX_LABEL_LENGTH = 180
# The job is started on demand and never held up: no RunAtLoad, no KeepAlive,
# and a throttle that only bounds how fast a crashing job may be relaunched.
# `docs/pr-drainer.md` explains why there is deliberately no periodic trigger.
THROTTLE_SECONDS = 10
# What `launchctl print` says about a job that is not merely loaded but has a
# live process. Matched line-anchored against the whole output because that is
# the shape launchd prints, and either answer alone is sufficient.
RUNNING_STATE = re.compile(r"^\s*state = running\s*$", re.MULTILINE)
RUNNING_PID = re.compile(r"^\s*pid = [1-9][0-9]*\s*$", re.MULTILINE)


# One external command, spawned through the caller's own wrapper. `check=True`
# raises that caller's error type; `check=False` hands back the completed
# process so a nonzero exit can be read as an answer rather than a failure.
Runner = Callable[..., subprocess.CompletedProcess[str]]


@dataclass(frozen=True)
class ServiceDefinition:
    """One managed service, described in terms no service manager owns.

    Everything here is decided by the controller — which interpreter runs
    which installed script against which checkout, where its output goes, and
    what environment it needs — and nothing here is launchd's spelling of it.
    A backend renders this into whatever its own service manager reads.
    """

    identifier: str
    program_arguments: Sequence[str]
    working_directory: str
    environment: Mapping[str, str]
    stdout_path: str
    stderr_path: str


class ServiceManagerBackend(ABC):
    """Every service-manager interaction the drainer's lifecycle performs.

    Deliberately total: a caller that needed one more launchd verb than this
    exposes would have to build it itself, which is exactly the leak this
    boundary exists to prevent. Adding a capability means adding a method here
    and implementing it on every backend.
    """

    @abstractmethod
    def service_identifier(self, slug: str) -> str:
        """The identifier a job for `slug` is named and targeted by."""

    @abstractmethod
    def identifier_fits(self, slug: str) -> bool:
        """Whether `slug` yields an identifier this manager can carry.

        Asked before a slug is committed to, because the fallback for one that
        does not fit is a different slug — and the slug also names the runtime
        and log directories, which must not diverge from the identifier's.
        """

    @abstractmethod
    def legacy_identifier(self) -> str:
        """The machine-wide singleton's identifier, which predates
        per-repository jobs and is only ever retired."""

    @abstractmethod
    def definition_path(self, identifier: str) -> Path:
        """Where this manager reads that identifier's definition from."""

    @abstractmethod
    def legacy_definition_path(self) -> Path:
        """Where the singleton's own definition lives."""

    @abstractmethod
    def manager_target(self, identifier: str) -> str:
        """How this manager is addressed about that identifier."""

    @abstractmethod
    def render_definition(self, definition: ServiceDefinition) -> bytes:
        """The bytes this manager reads that definition as."""

    @abstractmethod
    def write_definition(self, definition: ServiceDefinition) -> Path:
        """Install or refresh the definition on disk, returning its path.

        Separate from `load_definition` because the discovery record is
        written between the two: the record describes where the job is, so it
        has to be true from the moment the definition exists and before the
        manager is asked to load it.
        """

    @abstractmethod
    def load_definition(self, identifier: str) -> None:
        """Make the written definition the manager's current one, replacing
        whatever it already holds for that identifier."""

    @abstractmethod
    def is_loaded(self, identifier: str) -> bool:
        """Whether the manager holds a definition for that identifier.

        Never raises for an absent job: not being loaded is a normal answer,
        and a controller that treated it as a failure could not report a
        stopped drainer at all.
        """

    @abstractmethod
    def is_running(self, identifier: str) -> bool:
        """Whether that identifier's service has a live process. Answers False
        for a job that is not loaded, on the same rule as `is_loaded`."""

    @abstractmethod
    def kick(self, identifier: str) -> None:
        """Start the loaded service now."""

    @abstractmethod
    def request_stop(self, identifier: str) -> None:
        """Ask the manager to stop the service the way it asks a service to
        exit cleanly, so the drainer runs its own shutdown."""

    @abstractmethod
    def legacy_definition_exists(self) -> bool:
        """Whether the singleton's definition is still installed."""

    @abstractmethod
    def legacy_service_repository(self) -> Path | None:
        """Which checkout the singleton's own definition names, if any.

        Read out of the definition rather than the discovery record, because
        the definition is what the manager would actually run.
        """

    @abstractmethod
    def retire_legacy(self) -> Path:
        """Unload the singleton and set its definition aside, returning where
        it was moved to. Never called before `legacy_service_repository` has
        been consulted: a singleton serving another repository is left alone.
        """


class LaunchdBackend(ServiceManagerBackend):
    """macOS launchd: per-user LaunchAgents driven by `launchctl`."""

    def __init__(self, run: Runner) -> None:
        self._run = run

    def service_identifier(self, slug: str) -> str:
        return f"{LABEL_PREFIX}.{slug}"

    def identifier_fits(self, slug: str) -> bool:
        return len(self.service_identifier(slug)) <= MAX_LABEL_LENGTH

    def legacy_identifier(self) -> str:
        return LEGACY_LABEL

    def definition_path(self, identifier: str) -> Path:
        return LAUNCH_AGENTS_DIR / f"{identifier}.plist"

    def legacy_definition_path(self) -> Path:
        return LEGACY_PLIST_PATH

    def manager_target(self, identifier: str) -> str:
        return launch_target_for(identifier)

    def render_definition(self, definition: ServiceDefinition) -> bytes:
        data: dict[str, Any] = {
            "Label": definition.identifier,
            "ProgramArguments": list(definition.program_arguments),
            "WorkingDirectory": definition.working_directory,
            "RunAtLoad": False,
            "KeepAlive": False,
            "ProcessType": "Background",
            "ThrottleInterval": THROTTLE_SECONDS,
            "StandardOutPath": definition.stdout_path,
            "StandardErrorPath": definition.stderr_path,
            "EnvironmentVariables": dict(definition.environment),
        }
        return plistlib.dumps(data, fmt=plistlib.FMT_XML, sort_keys=False)

    def write_definition(self, definition: ServiceDefinition) -> Path:
        path = self.definition_path(definition.identifier)
        payload = self.render_definition(definition)
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(prefix=path.name, dir=path.parent)
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(tmp_name, 0o644)
            os.replace(tmp_name, path)
        finally:
            if os.path.exists(tmp_name):
                os.unlink(tmp_name)
        return path

    def load_definition(self, identifier: str) -> None:
        # Booted out first: launchd refuses to bootstrap a label it already
        # holds, so a refresh that skipped this would leave the previous
        # definition running.
        if self.is_loaded(identifier):
            self._run(["launchctl", "bootout", launch_target_for(identifier)])
        self._run(
            ["launchctl", "bootstrap", launch_domain(), str(self.definition_path(identifier))]
        )

    def is_loaded(self, identifier: str) -> bool:
        return (
            self._run(
                ["launchctl", "print", launch_target_for(identifier)], check=False
            ).returncode
            == 0
        )

    def is_running(self, identifier: str) -> bool:
        proc = self._run(
            ["launchctl", "print", launch_target_for(identifier)], check=False
        )
        if proc.returncode != 0:
            return False
        output = proc.stdout + proc.stderr
        return bool(RUNNING_STATE.search(output) or RUNNING_PID.search(output))

    def kick(self, identifier: str) -> None:
        self._run(["launchctl", "kickstart", launch_target_for(identifier)])

    def request_stop(self, identifier: str) -> None:
        self._run(
            ["launchctl", "kill", "SIGTERM", launch_target_for(identifier)]
        )

    def legacy_definition_exists(self) -> bool:
        return LEGACY_PLIST_PATH.exists()

    def legacy_service_repository(self) -> Path | None:
        try:
            with LEGACY_PLIST_PATH.open("rb") as handle:
                document = plistlib.load(handle)
        except (FileNotFoundError, OSError, plistlib.InvalidFileException, ValueError):
            return None
        if not isinstance(document, dict):
            return None
        arguments = document.get("ProgramArguments")
        if isinstance(arguments, list):
            for index, argument in enumerate(arguments):
                if argument == "--path" and index + 1 < len(arguments):
                    candidate = arguments[index + 1]
                    if isinstance(candidate, str) and candidate:
                        return Path(candidate).expanduser()
        working_directory = document.get("WorkingDirectory")
        if isinstance(working_directory, str) and working_directory:
            return Path(working_directory).expanduser()
        return None

    def retire_legacy(self) -> Path:
        if self.is_loaded(LEGACY_LABEL):
            self._run(["launchctl", "bootout", launch_target_for(LEGACY_LABEL)])
        retired_path = LEGACY_PLIST_PATH.with_name(LEGACY_PLIST_PATH.name + ".retired")
        os.replace(LEGACY_PLIST_PATH, retired_path)
        return retired_path


def launch_domain() -> str:
    return f"gui/{os.getuid()}"


def launch_target_for(label: str) -> str:
    return f"{launch_domain()}/{label}"


def select_backend(run: Runner) -> ServiceManagerBackend:
    """The service manager this host's drainer is managed by.

    Unconditionally launchd. The controller has never gated on the platform —
    `tools/install_drainer.py` is where a non-macOS host is refused, before
    anything is written — so selecting here on `sys.platform` would refuse
    installed jobs this seam was only meant to reorganize. A systemd backend
    joins this function when it is written and verified, not before.
    """
    return LaunchdBackend(run)
