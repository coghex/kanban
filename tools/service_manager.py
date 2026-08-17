#!/usr/bin/env python3

"""The one boundary Kanban's managed services reach a service manager through.

`tools/drain_prs_service.py` owns the drainer's lifecycle — repository
identity, clone exclusion, preflights, discovery records, incidents, startup
stabilization, shutdown confirmation — and `tools/install_drainer.py` owns
installation safety. `tools/approve_issues_service.py` and
`tools/install_issue_approval.py` own the same two halves for the issue
approval service. None of that is platform-specific, and none of it belongs
to a service manager. What is one's lives here: the identifier a job is named
and targeted by, the definition it is written from, and the commands that
load, kick, stop, and remove it.

Two services now share that boundary, so a backend is constructed for one
`ServiceNamespace`: the prefix its identifiers are built from, the description
its definitions carry, and whether it has a machine-wide singleton predating
per-repository jobs. Only the drainer has one. The namespace is what keeps two
services' jobs, and the definitions they are written from, from ever colliding
without either service restating a single identifier of its own.

So this module is the only one that constructs a `launchctl` or `systemctl`
argument vector, reads either one's output, serializes or parses a plist or a
unit file, or derives a launchd domain or a systemd user target. Its callers
describe *what* has to run as a `ServiceDefinition` and ask the selected
backend to make it so; they never spell a launchd or systemd artifact
themselves. That containment is machine-checked against the tracked tree by
`tools/test_agent_workflow_contract.py`, which is what keeps a later edit from
quietly reintroducing one somewhere else.

Two backends live here now. `LaunchdBackend` is macOS's, unchanged in every
byte it writes and every verb it spawns; `SystemdBackend` is the Linux one
added by issue #329, driving user units under `~/.config/systemd/user`
through `systemctl --user`. `select_backend` resolves which of them this host
is managed by and refuses a host that has neither, rather than assuming one:
the platform refusal belongs to the question "what manages services here?",
not to any caller's own platform check.

The command runner is injected rather than imported. Both callers already
spawn through their own thin wrapper — `drain_prs_service.run_command` raises
`ServiceError`, `install_drainer.run` raises `InstallError` — and passing that
wrapper in is what keeps a failure crossing this boundary in the failure
vocabulary its own caller reports, instead of a third exception type neither
side handles. `ServiceManagerError` below is the one exception this module
raises on its own account, for the two faults no injected runner can express:
a host with no service manager at all, and a value that cannot be rendered
into a definition.
"""

from __future__ import annotations

import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from abc import ABC, abstractmethod
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any


HOME = Path.home()

# Identity marker for this tracked asset; installers that link it recognize
# their own managed copy by content rather than by path, exactly as
# `tools/install_issue_review.py` recognizes the backend's. See
# `tools/install_issue_approval.py`, which links this module beside the
# approval controller and must never remove a file that is not this one.
KANBAN_MANAGED_ASSET = "kanban-managed-asset:issue-approval/service_manager.py"


class ServiceManagerError(RuntimeError):
    """A fault of this boundary itself, rather than of a command it ran.

    Commands cross back as the caller's own error type because the caller
    injected the runner that raises it. These two do not: no runner ran, so
    there is no wrapper to raise through, and both callers translate this at
    the seam where they resolve the backend.
    """


class NoServiceManagerError(ServiceManagerError):
    """This host is managed by no service manager this module supports."""

# This module writes the service definitions, so it also owns the identifiers
# they are named and targeted by. Nothing else may restate one:
# `tools/drain_prs_service.py` and `tools/install_drainer.py` both derive
# theirs through this module, as do `tools/approve_issues_service.py` and
# `tools/install_issue_approval.py`, and `src/Kanban/Drainer.hs` derives none
# at all — it reads an installed job's label and plist path out of the
# per-repository discovery record the controller writes.
#
# There is one label, and one of every mutable runtime path, per canonical
# GitHub repository *per service*: that partitioning is what lets several
# repositories be drained independently on one account, and what lets the
# approval service install a job beside a drainer's for the same repository.
# LABEL_PREFIX on its own is the machine-wide singleton the drainer's
# per-repository jobs replace; it survives only as the legacy job
# `retire_legacy` unloads before a derived job for the same repository is
# allowed to start.
LABEL_PREFIX = "com.coghex.drain-prs"
LEGACY_LABEL = LABEL_PREFIX
# The issue approval service's own prefix. Distinct from the drainer's by
# construction, so neither service can name the other's job however similarly
# two repositories are spelled (`docs/issue_approval_queue_design.md` D-11).
# There has never been a machine-wide approval job, so this namespace has no
# singleton to retire; the untracked personal daemon that predates the service
# is a conflict the controller refuses beside, never a job this module manages.
ISSUE_APPROVAL_LABEL_PREFIX = "com.coghex.issue-approval"
LAUNCH_AGENTS_DIR = HOME / "Library" / "LaunchAgents"
LEGACY_PLIST_PATH = LAUNCH_AGENTS_DIR / f"{LEGACY_LABEL}.plist"
# Long enough for every GitHub owner/name pair spelled with ordinary
# characters, short enough that `<label>.plist` stays well inside the 255-byte
# filename limit even after escaping. See `drain_prs_service.repository_slug`,
# which asks `identifier_fits` rather than restating this number. The systemd
# backend holds its unit names to the same number for the same reason: one
# slug names the identifier and the runtime and log directories together, so a
# limit that differed per backend would let one host name a job the other
# could not.
MAX_LABEL_LENGTH = 180

# The two names a backend is known by — in the discovery record, which is a
# discriminated union keyed on exactly these, and in the wording every caller
# reports a manager-scoped condition with.
LAUNCHD = "launchd"
SYSTEMD = "systemd"

SYSTEMD_UNIT_SUFFIX = ".service"
LEGACY_UNIT_NAME = f"{LEGACY_LABEL}{SYSTEMD_UNIT_SUFFIX}"

# The discovery-record keys this boundary owns, per backend and in total.
#
# `RECORD_KEYS` is what a writer must clear from an entry before writing its
# own: a repository reinstalled under the other manager would otherwise keep
# the first manager's keys beside the second's, and that mixed shape is exactly
# what a reader must fail closed on. Clearing is scoped to these names alone,
# so `config_path` and anything else an installer persisted survives.
RECORD_BACKEND_KEY = "backend"
LAUNCHD_RECORD_KEYS = ("launchd_label", "plist_path")
SYSTEMD_RECORD_KEYS = ("systemd_unit", "unit_path")
RECORD_KEYS = frozenset(
    {RECORD_BACKEND_KEY, *LAUNCHD_RECORD_KEYS, *SYSTEMD_RECORD_KEYS}
)


def _systemd_user_dir() -> Path:
    """systemd's own user-unit directory, by systemd's own rule.

    `$XDG_CONFIG_HOME/systemd/user` when that variable names an absolute
    directory, and `~/.config/systemd/user` otherwise. Those are the two
    locations the user manager searches, and it searches exactly one of them:
    writing to the other would leave a unit file systemd never loads and a
    `start` that fails with "unit not found". Which of the two applies is
    systemd's question rather than this repository's path policy, which is why
    it is answered here and not deferred to the managed-paths arc.
    """
    configured = os.environ.get("XDG_CONFIG_HOME", "")
    root = Path(configured) if configured and os.path.isabs(configured) else HOME / ".config"
    return root / "systemd" / "user"


SYSTEMD_USER_DIR = _systemd_user_dir()
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
class UninstallOutcome:
    """What removing one repository's job actually had to do.

    Both halves are reported rather than a single boolean, because they fail
    independently and a caller that could not tell them apart could not
    describe a half-finished uninstall: a job the manager still holds with no
    definition left on disk is a different repair from a definition left
    behind by a manager that never knew about it.
    """

    unloaded: bool
    definition_removed: bool


@dataclass(frozen=True)
class ServiceNamespace:
    """One Kanban service's own identifier space.

    A backend is constructed for exactly one of these, so every identifier it
    derives, every definition it writes, and every legacy question it answers
    belong to that service alone. Nothing else about a backend varies: both
    services are non-resident jobs started on demand, and a namespace that
    could change that would be a second lifecycle rather than a second name.

    `legacy_prefix` is the machine-wide singleton this namespace's
    per-repository jobs replaced, or None for a namespace that never had one.
    None is not "no singleton installed" — it is "this service has no such
    concept", which is why asking for its identifier is an error rather than
    an answer.
    """

    name: str
    prefix: str
    description: str
    legacy_prefix: str | None


DRAINER_NAMESPACE = ServiceNamespace(
    name="pr-drainer",
    prefix=LABEL_PREFIX,
    description="Kanban PR drainer",
    legacy_prefix=LEGACY_LABEL,
)
ISSUE_APPROVAL_NAMESPACE = ServiceNamespace(
    name="issue-approval",
    prefix=ISSUE_APPROVAL_LABEL_PREFIX,
    description="Kanban issue approval",
    legacy_prefix=None,
)


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
    """Every service-manager interaction a managed service's lifecycle performs.

    Deliberately total: a caller that needed one more launchd verb than this
    exposes would have to build it itself, which is exactly the leak this
    boundary exists to prevent. Adding a capability means adding a method here
    and implementing it on every backend. That totality covers removal as much
    as installation — `uninstall_definition` is here for the same reason
    `load_definition` is, so no installer ever unloads a job or deletes a
    definition on its own account.
    """

    @abstractmethod
    def namespace(self) -> ServiceNamespace:
        """Which service's identifier space this backend was built for.

        Reported rather than assumed, so a caller holding a backend can say
        whose job it is about without restating either service's prefix.
        """

    @abstractmethod
    def backend_name(self) -> str:
        """Which service manager this is: `LAUNCHD` or `SYSTEMD`.

        One string with two jobs, deliberately. It is the discriminator the
        discovery record is written and read under, and it is the noun every
        caller reports a manager-scoped condition with — "a drainer outside
        launchd", "stop it before installing this checkout's systemd job" —
        so a host can never be told about the manager it is not running.
        """

    @abstractmethod
    def definition_label(self) -> str:
        """What this manager calls the file it reads a definition from.

        The key a result document reports that file's path under. `plist` on
        launchd, which is the key every existing consumer already reads, and
        `unit` on systemd, because reporting a unit as a plist is the same
        misidentification in machine-readable form.
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
        per-repository jobs and is only ever retired.

        An error rather than an answer for a namespace that never had one:
        inventing an identifier there would name a job no host has ever
        carried, and every caller reaches this only after
        `legacy_definition_exists` said there was something to retire.
        """

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
    def record_entry(self, identifier: str, definition_path: Path) -> dict[str, str]:
        """How this backend's job identifies itself in the discovery record.

        The record is a discriminated union: every entry this writes names its
        own backend, and each backend names its identifier and its definition
        under keys that are its own. An entry naming no backend at all is the
        one shape that predates this method, and is therefore launchd's —
        which is why the launchd backend keeps writing `launchd_label` and
        `plist_path` beside its discriminator rather than replacing them.
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
    def uninstall_definition(self, identifier: str) -> UninstallOutcome:
        """Unload that identifier's service and delete its definition.

        The ordinary per-repository counterpart of `write_definition` plus
        `load_definition`, and the only supported way to remove one job while
        leaving every other repository's alone. Never called for a service
        that is still running — the controller settles that first, because a
        manager asked to forget a live job leaves a drainer nothing can
        control — and total for a job that is partly or wholly absent, since
        repairing a half-finished uninstall is exactly when this is reached.
        """

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

    def __init__(
        self, run: Runner, namespace: ServiceNamespace = DRAINER_NAMESPACE
    ) -> None:
        self._run = run
        self._namespace = namespace

    def namespace(self) -> ServiceNamespace:
        return self._namespace

    def backend_name(self) -> str:
        return LAUNCHD

    def definition_label(self) -> str:
        return "plist"

    def service_identifier(self, slug: str) -> str:
        return f"{self._namespace.prefix}.{slug}"

    def identifier_fits(self, slug: str) -> bool:
        return len(self.service_identifier(slug)) <= MAX_LABEL_LENGTH

    def legacy_identifier(self) -> str:
        return require_legacy_prefix(self._namespace)

    def definition_path(self, identifier: str) -> Path:
        return LAUNCH_AGENTS_DIR / f"{identifier}.plist"

    def legacy_definition_path(self) -> Path:
        return LAUNCH_AGENTS_DIR / f"{self.legacy_identifier()}.plist"

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
        return write_definition_file(
            self.definition_path(definition.identifier), self.render_definition(definition)
        )

    def record_entry(self, identifier: str, definition_path: Path) -> dict[str, str]:
        # `launchd_label` and `plist_path` are the shape every installed macOS
        # drainer already carries and every released Kanban already reads, so
        # they stay exactly as they are; `backend` joins them so a reader
        # never has to infer launchd from the absence of anything.
        identifier_key, definition_key = LAUNCHD_RECORD_KEYS
        return {
            RECORD_BACKEND_KEY: LAUNCHD,
            identifier_key: identifier,
            definition_key: str(definition_path),
        }

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

    def uninstall_definition(self, identifier: str) -> UninstallOutcome:
        # Booted out before the plist is unlinked, never after: launchd
        # re-bootstraps what is still in `~/Library/LaunchAgents` at login, so
        # a removal that unlinked first would leave a job loaded in this
        # session that nothing on disk describes.
        unloaded = self.is_loaded(identifier)
        if unloaded:
            self._run(["launchctl", "bootout", launch_target_for(identifier)])
        return UninstallOutcome(
            unloaded=unloaded,
            definition_removed=remove_definition_file(self.definition_path(identifier)),
        )

    def legacy_definition_exists(self) -> bool:
        # False rather than an error for a namespace with no singleton: this is
        # the question every caller asks *before* reaching for one, so it has
        # to answer for a service that never had one too.
        if self._namespace.legacy_prefix is None:
            return False
        return self.legacy_definition_path().exists()

    def legacy_service_repository(self) -> Path | None:
        if self._namespace.legacy_prefix is None:
            return None
        try:
            with self.legacy_definition_path().open("rb") as handle:
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
        legacy_identifier = self.legacy_identifier()
        legacy_path = self.legacy_definition_path()
        if self.is_loaded(legacy_identifier):
            self._run(["launchctl", "bootout", launch_target_for(legacy_identifier)])
        retired_path = legacy_path.with_name(legacy_path.name + ".retired")
        os.replace(legacy_path, retired_path)
        return retired_path


class SystemdBackend(ServiceManagerBackend):
    """Linux systemd: per-user units under `~/.config/systemd/user`, driven by
    `systemctl --user`.

    Deliberately non-resident, the way the LaunchAgent it mirrors is. The unit
    carries no `[Install]` section, so nothing enables it and no login starts
    it; installation writes it and asks the user manager to read it, and only
    an explicit `kick` ever runs it.
    """

    def __init__(
        self, run: Runner, namespace: ServiceNamespace = DRAINER_NAMESPACE
    ) -> None:
        self._run = run
        self._namespace = namespace

    def namespace(self) -> ServiceNamespace:
        return self._namespace

    def backend_name(self) -> str:
        return SYSTEMD

    def definition_label(self) -> str:
        return "unit"

    def service_identifier(self, slug: str) -> str:
        # The same prefix and the same slug the launchd label is built from,
        # plus the suffix systemd requires to read the name as a service. The
        # slug's alphabet — `[A-Za-z0-9_-]` per segment, with the single `.`
        # separating them — is a subset of what systemd accepts in a unit
        # name, so no second escaping is needed or wanted: a name escaped
        # twice would no longer be the one `repository_slug` partitions the
        # runtime and log directories by.
        return f"{self._namespace.prefix}.{slug}{SYSTEMD_UNIT_SUFFIX}"

    def identifier_fits(self, slug: str) -> bool:
        return len(self.service_identifier(slug)) <= MAX_LABEL_LENGTH

    def legacy_identifier(self) -> str:
        return require_legacy_prefix(self._namespace) + SYSTEMD_UNIT_SUFFIX

    def definition_path(self, identifier: str) -> Path:
        return SYSTEMD_USER_DIR / identifier

    def legacy_definition_path(self) -> Path:
        return self.definition_path(self.legacy_identifier())

    def manager_target(self, identifier: str) -> str:
        return systemd_target_for(identifier)

    def render_definition(self, definition: ServiceDefinition) -> bytes:
        # Every directive here carries one `ServiceDefinition` promise across:
        #
        #   Type=exec        the runner is the service, and it is up once it
        #                    has been executed rather than once it forks.
        #   ExecStart        the exact argv, each word quoted, so systemd
        #                    passes it through without a shell ever seeing it.
        #   Restart=no       plus no `[Install]` section: started on demand
        #                    and never resident, which is launchd's
        #                    RunAtLoad=false/KeepAlive=false.
        #   KillMode=mixed   only the main process is signalled, so the runner
        #                    performs its own shutdown and forwards to its
        #                    child exactly as it does under launchd, instead
        #                    of systemd SIGTERMing the whole cgroup first.
        #
        # There is deliberately no start rate limit: launchd's ThrottleInterval
        # bounds relaunches of a crashing job, and a unit that neither restarts
        # nor lingers has no relaunch to bound. systemd's own default start
        # limit remains, and refusing a start is a worse failure than a fast
        # one. TimeoutStopSec is likewise left at systemd's default, which is
        # longer than the controller's own STOP_TIMEOUT_SECONDS patience, so
        # the drainer is never SIGKILLed out from under a stop still waiting
        # on it.
        lines = [
            "[Unit]",
            f"Description={_unit_value(self._namespace.description)} "
            f"({_unit_value(definition.identifier)})",
            "",
            "[Service]",
            "Type=exec",
            "ExecStart=" + " ".join(_unit_word(word) for word in definition.program_arguments),
            f"WorkingDirectory={_unit_value(definition.working_directory)}",
            f"StandardOutput=append:{_unit_value(definition.stdout_path)}",
            f"StandardError=append:{_unit_value(definition.stderr_path)}",
            "Restart=no",
            "KillSignal=SIGTERM",
            "KillMode=mixed",
        ]
        lines.extend(
            "Environment=" + _unit_word(f"{name}={value}")
            for name, value in definition.environment.items()
        )
        return ("\n".join(lines) + "\n").encode("utf-8")

    def write_definition(self, definition: ServiceDefinition) -> Path:
        return write_definition_file(
            self.definition_path(definition.identifier), self.render_definition(definition)
        )

    def record_entry(self, identifier: str, definition_path: Path) -> dict[str, str]:
        identifier_key, definition_key = SYSTEMD_RECORD_KEYS
        return {
            RECORD_BACKEND_KEY: SYSTEMD,
            identifier_key: identifier,
            definition_key: str(definition_path),
        }

    def load_definition(self, identifier: str) -> None:
        # `daemon-reload` is systemd's bootstrap: it is what makes a unit file
        # just written, or just rewritten, the definition the user manager
        # holds. `reset-failed` then clears a previous run's failure the way
        # launchd's bootout/bootstrap pair does, and runs unchecked because a
        # unit that has never failed — or has only just appeared — is not an
        # error to have nothing to reset.
        self._run(["systemctl", "--user", "daemon-reload"])
        self._run(["systemctl", "--user", "reset-failed", identifier], check=False)

    def is_loaded(self, identifier: str) -> bool:
        return self._property(identifier, "LoadState") == "loaded"

    def is_running(self, identifier: str) -> bool:
        # Either answer alone is sufficient, on the same rule the launchd
        # probe follows: an active unit and a live main PID are two ways of
        # saying the manager is running this job right now.
        if self._property(identifier, "ActiveState") in {"active", "activating", "reloading"}:
            return True
        main_pid = self._property(identifier, "MainPID")
        return main_pid.isdigit() and int(main_pid) > 0

    def kick(self, identifier: str) -> None:
        # Checked and blocking, unlike the stop below: `Type=exec` returns as
        # soon as the runner has been executed, and a unit that could not
        # start at all is a failure the caller must hear about rather than
        # discover as a start that never settles.
        self._run(["systemctl", "--user", "start", identifier])

    def request_stop(self, identifier: str) -> None:
        # `--no-block` because `launchctl kill` does not wait either, and the
        # caller's own STOP_TIMEOUT_SECONDS loop is what confirms the exit. A
        # blocking stop would wait out systemd's much longer patience inside a
        # call the controller intends to return from immediately.
        self._run(["systemctl", "--user", "--no-block", "stop", identifier])

    def uninstall_definition(self, identifier: str) -> UninstallOutcome:
        unloaded = self.is_loaded(identifier)
        removed = remove_definition_file(self.definition_path(identifier))
        # After the unlink rather than before: `daemon-reload` is what makes
        # the user manager forget a unit, and it can only forget one whose
        # file is already gone.
        self._run(["systemctl", "--user", "daemon-reload"])
        self._run(["systemctl", "--user", "reset-failed", identifier], check=False)
        return UninstallOutcome(unloaded=unloaded, definition_removed=removed)

    def legacy_definition_exists(self) -> bool:
        # There has never been a systemd install, so there is no systemd
        # singleton predating per-repository units — for either namespace.
        # Answering False is what keeps `retire_legacy_job` from reaching for a
        # launchd artifact on a host that has none.
        return False

    def legacy_service_repository(self) -> Path | None:
        return None

    def retire_legacy(self) -> Path:
        if self._namespace.legacy_prefix is None:
            raise ServiceManagerError(no_legacy_singleton_message(self._namespace))
        raise ServiceManagerError(
            "There is no systemd singleton to retire; the machine-wide job predates "
            "per-repository units and only ever existed under launchd."
        )

    def _property(self, identifier: str, name: str) -> str:
        """One `systemctl show` property, or the empty string.

        Unchecked, and total for a unit the manager has never heard of: that
        is the ordinary answer for a stopped or never-installed drainer, which
        `status` asks about every ten seconds. `show` prints `LoadState=
        not-found` and exits zero for such a unit, so an empty result here
        means the command itself could not run — which is also not a job.
        """
        proc = self._run(
            ["systemctl", "--user", "show", identifier, "--property", name, "--value"],
            check=False,
        )
        if proc.returncode != 0:
            return ""
        return (proc.stdout or "").strip()


def namespace_slug_limit(namespace: ServiceNamespace) -> int:
    """The longest slug every backend can carry an identifier for.

    Answered without selecting one, and deliberately as the *smallest* limit
    any backend imposes, because a slug names a repository's runtime and log
    directories as well as its identifier. A limit that varied by manager
    would let one checkout resolve one slug on macOS and another on Linux,
    partitioning one repository's state twice — and a caller that has no
    service manager at all, as a foreground run deliberately does not, still
    has to name those directories.

    Measured by asking each backend what identifier it builds from a probe
    slug, rather than by restating either shape here: a backend that changed
    how it spells an identifier changes this with it. The probe runner is
    never called — no backend spawns anything to name a job.
    """

    def unusable(*_arguments: Any, **_options: Any) -> Any:  # pragma: no cover
        raise ServiceManagerError("Naming an identifier runs no command.")

    probe = "s"
    overhead = max(
        len(backend(unusable, namespace).service_identifier(probe)) - len(probe)
        for backend in (LaunchdBackend, SystemdBackend)
    )
    return MAX_LABEL_LENGTH - overhead


def no_legacy_singleton_message(namespace: ServiceNamespace) -> str:
    return (
        f"The {namespace.name} service has no machine-wide singleton: its jobs "
        "have always been per-repository, so there is no legacy identifier to "
        "name and nothing to retire."
    )


def require_legacy_prefix(namespace: ServiceNamespace) -> str:
    """That namespace's singleton prefix, or a refusal naming why it has none.

    Shared by both backends because the answer is the namespace's rather than
    either manager's: a service that never had a machine-wide job has none
    under launchd and none under systemd.
    """
    if namespace.legacy_prefix is None:
        raise ServiceManagerError(no_legacy_singleton_message(namespace))
    return namespace.legacy_prefix


def launch_domain() -> str:
    return f"gui/{os.getuid()}"


def launch_target_for(label: str) -> str:
    return f"{launch_domain()}/{label}"


def systemd_target_for(unit: str) -> str:
    """How systemd is addressed about one of this user's units.

    The user manager instance that holds it, then the unit — the same shape
    launchd's `gui/<uid>/<label>` has, and for the same reason: a bare unit
    name says nothing about which manager was asked.
    """
    return f"user@{os.getuid()}.service/{unit}"


def write_definition_file(path: Path, payload: bytes) -> Path:
    """Install or refresh one definition atomically, at the mode its manager
    reads it with. Shared by both backends because the durability rule is the
    same for a plist and for a unit file: a reader must see the previous
    definition or the new one, never a partial write."""
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


def remove_definition_file(path: Path) -> bool:
    """Delete one definition, reporting whether there was one to delete.

    A definition already gone is not a failure: uninstalling is reached to
    repair a half-finished removal at least as often as to perform a whole
    one.
    """
    try:
        path.unlink()
    except FileNotFoundError:
        return False
    return True


def _unit_value(value: str) -> str:
    """One bare directive value, with systemd's specifier syntax escaped.

    `%` introduces a specifier systemd expands, so a path containing one would
    otherwise be rewritten into something else entirely. A newline would end
    the directive and turn the rest of the value into unit-file syntax, which
    is the one input that cannot be escaped into safety and is therefore
    refused.
    """
    if "\n" in value or "\r" in value:
        raise ServiceManagerError(
            f"A systemd unit value may not contain a line break: {value!r}"
        )
    return value.replace("%", "%%")


def _unit_word(word: str) -> str:
    """One quoted word of an `ExecStart` or `Environment` directive.

    Quoted rather than bare so that whitespace inside an argument stays inside
    it: systemd splits an unquoted value on whitespace, and the controller's
    argv carries a checkout path it has no say in. Inside the quotes, `\\` and
    `"` are the two characters that would otherwise end or reinterpret the
    word.
    """
    escaped = _unit_value(word).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


_UNPROBED = object()
_DETECTED: Any = _UNPROBED


def detect_service_manager(run: Runner) -> str | None:
    """Which service manager this host can actually be managed through.

    Ordered rather than exclusive, so an ambiguous host is still decided the
    same way every time: launchd answers for a macOS host that has
    `launchctl`, systemd answers for a host whose `systemctl --user` reaches a
    live user manager, and a host that is neither answers None. Availability
    is what is probed, not the platform name alone — a `systemctl` with no
    session bus behind it manages nothing, and installing against it would
    write a unit no manager will ever load.

    Memoized because it is a property of the host rather than of a call, and
    because `service_backend()` resolves the backend afresh on every use: a
    probe that spawned `systemctl` each time would put a subprocess inside the
    quarter-second polling loops that wait out a start or a stop.
    """
    global _DETECTED
    if _DETECTED is _UNPROBED:
        _DETECTED = _probe_service_manager(run)
    return _DETECTED


def reset_detection() -> None:
    """Forget the memoized probe above.

    Only a test needs this: a host does not acquire or lose a service manager
    while the drainer is running, which is the whole reason the answer is
    memoized in the first place.
    """
    global _DETECTED
    _DETECTED = _UNPROBED


def _probe_service_manager(run: Runner) -> str | None:
    if sys.platform == "darwin" and shutil.which("launchctl"):
        return LAUNCHD
    if shutil.which("systemctl") and _systemd_session_is_live(run):
        return SYSTEMD
    return None


def _systemd_session_is_live(run: Runner) -> bool:
    """Whether `systemctl --user` reaches this user's own systemd manager.

    A read of the manager's own version, which needs the session bus and
    nothing else. `systemctl` exits nonzero when it cannot connect — no
    `XDG_RUNTIME_DIR`, no user manager, a container without one — and that is
    exactly the host that must be refused before anything is written rather
    than after.
    """
    return (
        run(
            ["systemctl", "--user", "show", "--property", "Version", "--value"], check=False
        ).returncode
        == 0
    )


def backend_for(
    name: str, run: Runner, namespace: ServiceNamespace = DRAINER_NAMESPACE
) -> ServiceManagerBackend:
    """The backend one detected name selects, for one service's namespace. The
    single place either name is turned into an implementation, so
    `select_backend` and any caller that already knows the answer cannot
    disagree about which class that is."""
    if name == LAUNCHD:
        return LaunchdBackend(run, namespace)
    if name == SYSTEMD:
        return SystemdBackend(run, namespace)
    raise ServiceManagerError(f"Unknown service manager: {name!r}")


def select_backend(
    run: Runner, namespace: ServiceNamespace = DRAINER_NAMESPACE
) -> ServiceManagerBackend:
    """The service manager this host's managed jobs run under, or a refusal.

    The refusal is this function's rather than any caller's. `sys.platform` is
    the wrong question — a Linux host with no user session and a macOS host
    are both unmanageable for the same reason and neither is about the
    platform's name — so every caller asks here, and every one does so before
    writing anything.

    Which service the resulting backend is *for* is the caller's, and the only
    thing a namespace changes: the host question has one answer, and both
    services get their jobs from whichever manager it names.
    """
    detected = detect_service_manager(run)
    if detected is None:
        raise NoServiceManagerError(
            "No supported service manager found: a Kanban managed service needs "
            "either macOS launchd or a systemd user session reachable through "
            "`systemctl --user`."
        )
    return backend_for(detected, run, namespace)
