"""Shared TOML configuration loader for approve_issues.py and drain_prs.py.

Schema is documented in config.toml.example at the repo root and mirrors
src/Kanban/Config.hs field-for-field (Haskell CamelCase -> Python snake_case).
Both sides must agree on the same file; see that module for the semantics
this loader replicates (default path, missing-file defaults, malformed/
invalid-value errors, unknown-key warnings, global-only keys, canonical
lowercase repository keys and the ASCII-folded lookup that selects them,
repository override merge/array-replacement rules).

This module is also the one place the issue-review backend's own install
location is written down. It is the only tracked module installed alongside
`approve_issues.py`, so it is the only one that both the installer and the
installed backend can import -- which is what keeps that location from being
restated once per component. See issue_review_record_path() below.
"""

from __future__ import annotations

import os
import re
import tomllib
from dataclasses import dataclass, field, replace
from pathlib import Path


# Identity marker for this tracked asset; see the same constant in
# approve_issues.py for why installed files are recognized by content
# rather than by path.
KANBAN_MANAGED_ASSET = "kanban-managed-asset:issue-review/kanban_config.py"


class KanbanConfigError(Exception):
    pass


# The Kanban-managed install location for the canonical issue-review backend
# (docs/agent-workflow-contract.md §5), spelled here once. `approve_issues.py`,
# `install_issue_review.py` and `setup_workflows.py` all import it rather than
# rebuilding it, so `--install-dir` cannot move one component's idea of the
# default without moving every component's.
ISSUE_REVIEW_INSTALL_DIR_ENV = "KANBAN_ISSUE_REVIEW_INSTALL_DIR"


def default_issue_review_install_dir() -> Path:
    # Resolved per call rather than frozen at import, exactly as
    # default_config_path() below is: freezing it would bind whatever $HOME
    # held when the module first loaded, which a test that redirects $HOME --
    # or any process that changes it -- would then silently escape.
    return Path(f"{Path.home()}/Library/Application Support/kanban/issue-review")


def issue_review_record_path() -> Path:
    """Where the installer records which backend it actually installed, so
    Kanban discovers an `--install-dir` installation it never saw the option
    for. Fixed rather than install-dir-relative on purpose: a dashboard that
    inherits no environment still has to find it, so the record's own path is
    the one thing that cannot move. Read by src/Kanban/Review.hs and by both
    packaged PR coordinators; written only by
    tools/install_issue_review.py."""
    return default_issue_review_install_dir() / "config.json"


def issue_review_install_dir() -> Path:
    """The install directory an issue-review component should treat as its
    own. The environment override wins, exactly as it does for every consumer
    that resolves the backend; the default is the directory the discovery
    record lives in."""
    override = os.environ.get(ISSUE_REVIEW_INSTALL_DIR_ENV)
    if override and override.strip():
        return Path(override).expanduser()
    return default_issue_review_install_dir()


APPROVAL_MODES = {"label", "review", "either"}
BLOCKING_SEVERITIES = {"red", "amber"}


@dataclass(frozen=True)
class WorkflowConfig:
    approval_label: str = "reviewed:approve"
    changes_requested_label: str = "reviewed:changes"
    blocked_labels: frozenset[str] = frozenset({"blocked"})
    tracker_labels: frozenset[str] = frozenset({"epic"})
    additional_tracker_section_headings: tuple[str, ...] = ()
    approval_mode: str = "label"
    blocking_severity: str = "red"
    # Display-only: which label names the dashboard tints as problems and as
    # UI concerns in its label chips. Python workers carry them so the shared
    # schema stays one schema — a documented key must not warn as unknown —
    # but nothing here reads their styling meaning.
    problem_style_labels: frozenset[str] = frozenset()
    ui_style_labels: frozenset[str] = frozenset()


@dataclass(frozen=True)
class LimitsConfig:
    max_open_issues: int = 250
    max_open_pull_requests: int = 100
    excerpt_lines: int = 3


@dataclass(frozen=True)
class TimeoutsConfig:
    github_seconds: int = 30
    codex_seconds: int = 10
    claude_seconds: int = 45


@dataclass(frozen=True)
class UsageCommandConfig:
    argv: tuple[str, ...]


@dataclass(frozen=True)
class UsageConfig:
    codex_command: UsageCommandConfig | None = None
    claude_command: UsageCommandConfig | None = None


# Per-field overrides for [workflow]/[limits]/[timeouts], decoded identically
# at the global and per-repository level. A field left None inherits the
# base value; a repository array field replaces the global array in full.
@dataclass(frozen=True)
class WorkflowOverride:
    approval_label: str | None = None
    changes_requested_label: str | None = None
    blocked_labels: frozenset[str] | None = None
    tracker_labels: frozenset[str] | None = None
    additional_tracker_section_headings: tuple[str, ...] | None = None
    approval_mode: str | None = None
    blocking_severity: str | None = None
    problem_style_labels: frozenset[str] | None = None
    ui_style_labels: frozenset[str] | None = None


@dataclass(frozen=True)
class LimitsOverride:
    max_open_issues: int | None = None
    max_open_pull_requests: int | None = None
    excerpt_lines: int | None = None


@dataclass(frozen=True)
class TimeoutsOverride:
    github_seconds: int | None = None
    codex_seconds: int | None = None
    claude_seconds: int | None = None


@dataclass(frozen=True)
class RepositoryOverride:
    workflow: WorkflowOverride = field(default_factory=WorkflowOverride)
    limits: LimitsOverride = field(default_factory=LimitsOverride)
    timeouts: TimeoutsOverride = field(default_factory=TimeoutsOverride)


@dataclass(frozen=True)
class RawConfig:
    cache: bool = True
    remote_name: str = "origin"
    workflow: WorkflowConfig = field(default_factory=WorkflowConfig)
    limits: LimitsConfig = field(default_factory=LimitsConfig)
    timeouts: TimeoutsConfig = field(default_factory=TimeoutsConfig)
    usage: UsageConfig = field(default_factory=UsageConfig)
    repositories: dict[str, RepositoryOverride] = field(default_factory=dict)


@dataclass(frozen=True)
class ResolvedConfig:
    cache: bool
    remote_name: str
    workflow: WorkflowConfig
    limits: LimitsConfig
    timeouts: TimeoutsConfig
    usage: UsageConfig


def default_config_path() -> Path:
    # Matches Kanban.Config.defaultConfigPath (getXdgDirectory XdgConfig):
    # honor $XDG_CONFIG_HOME when set, so the dashboard and these tools agree
    # on the same file.
    xdg_config_home = os.environ.get("XDG_CONFIG_HOME")
    if xdg_config_home:
        return Path(xdg_config_home) / "kanban" / "config.toml"
    return Path.home() / ".config" / "kanban" / "config.toml"


def parse_repository_name(raw_value: str) -> str:
    """Derives a display OWNER/NAME slug from a git remote URL.

    Deliberately permissive, and *not* the same accept set as
    Kanban.Repository.parseRepositoryName: it keeps the last two nonempty
    segments of anything, so a plain local path remote such as
    `/tmp/acme/widgets.git` still names `acme/widgets`. That is what lets
    approve_issues.py and drain_prs.py address a fixture repository that has
    no GitHub URL at all, and it is why this value is only ever used to build
    `gh` arguments and log lines.

    Anything that has to *name a canonical GitHub repository* — the drainer's
    per-repository job identity above all — must use parse_github_repository
    below instead, which mirrors the Haskell parser's accept set exactly.
    """
    stripped = raw_value.strip()
    for prefix in ("https://", "http://", "ssh://", "git://"):
        if stripped.startswith(prefix):
            stripped = stripped[len(prefix) :]
            break
    normalized = stripped.replace("git@github.com", "github.com").replace(":", "/").rstrip("/")
    segments = [segment for segment in normalized.split("/") if segment]
    if len(segments) < 2:
        raise KanbanConfigError(f"cannot derive OWNER/NAME from repository value: {raw_value}")
    owner, name = segments[-2], segments[-1]
    if name.endswith(".git"):
        name = name[: -len(".git")]
    if not owner or not name:
        raise KanbanConfigError(f"cannot derive OWNER/NAME from repository value: {raw_value}")
    return f"{owner}/{name}"


# The canonical-identity parser. Every rule below is a transcription of
# src/Kanban/Repository.hs, function for function, because the two sides have
# to agree on which checkouts name a GitHub repository at all: Kanban selects
# the drainer's job record by the identity it resolved, and this module derives
# the job's launchd label from the identity the checkout's remote resolved to.
# A value one side accepts and the other rejects would present as a drainer
# that is installed and simultaneously not installed.
_GITHUB_URL_SCHEMES = ("https://", "ssh://", "git://")
_GITHUB_HOSTS = ("github.com", "www.github.com")
# Kanban.Repository.isIdentityCharacter, and Data.Char.isDigit, which are both
# ASCII-only — str.isdigit() is not, and would accept a non-ASCII port.
_GITHUB_IDENTITY = re.compile(r"\A[A-Za-z0-9._-]+\Z")
_GITHUB_PORT = re.compile(r"\A[0-9]+\Z")


def _github_host_of(authority: str) -> str:
    """Kanban.Repository.hostOf: drops optional userinfo, which may itself
    contain '@'."""
    return authority.rsplit("@", 1)[-1]


def _is_github_host(host: str) -> bool:
    return host.lower() in _GITHUB_HOSTS


def _is_github_authority(authority: str) -> bool:
    host, separator, port = _github_host_of(authority).partition(":")
    if not _is_github_host(host):
        return False
    return not separator or bool(_GITHUB_PORT.fullmatch(port))


def _github_owner_name(path: str) -> str | None:
    """Exactly OWNER/NAME[.git], with leading and trailing slashes ignored. An
    extra path segment is ambiguous rather than ignorable, so it fails."""
    segments = [segment for segment in path.split("/") if segment]
    if len(segments) != 2:
        return None
    owner, name = segments
    if name.endswith(".git"):
        name = name[: -len(".git")]
    if not _GITHUB_IDENTITY.fullmatch(owner) or not _GITHUB_IDENTITY.fullmatch(name):
        return None
    return f"{owner}/{name}"


def _github_url_identity(after_scheme: str) -> str | None:
    authority, _, path = after_scheme.partition("/")
    if not _is_github_authority(authority):
        return None
    return _github_owner_name(path)


def _github_scp_identity(value: str) -> str | None:
    """SCP-style [user@]host:path. The colon starts the path rather than a
    port, so git@github.com:22/owner/name is a three-segment path and fails. A
    slash before the colon means git reads the value as a local path."""
    authority, separator, path = value.partition(":")
    if not separator or "/" in authority or "@" not in authority:
        return None
    if not _is_github_host(_github_host_of(authority)):
        return None
    return _github_owner_name(path)


def _github_remote_identity(value: str) -> str | None:
    lowered = value.lower()
    for scheme in _GITHUB_URL_SCHEMES:
        if lowered.startswith(scheme):
            return _github_url_identity(value[len(scheme) :])
    return _github_scp_identity(value)


def parse_github_repository(raw_value: str) -> str:
    """Derives OWNER/NAME for a value that must name a repository on
    github.com, accepting exactly what Kanban.Repository.parseRepositoryName
    accepts: the bare OWNER/NAME form, and https://, ssh://, or git:// URLs
    and git@github.com: SCP shorthand pointing at github.com. Foreign hosts,
    http://, extra path segments, local paths, and identity segments carrying
    anything outside [A-Za-z0-9._-] all fail closed."""
    stripped = raw_value.strip()
    identity = None
    # Kanban.Repository.bareIdentity: URL authority punctuation means this is
    # not a bare OWNER/NAME, so a remote URL cannot slip through as one.
    if ":" not in stripped and "@" not in stripped:
        identity = _github_owner_name(stripped)
    if identity is None:
        identity = _github_remote_identity(stripped)
    if identity is None:
        raise KanbanConfigError(
            "cannot derive a github.com OWNER/NAME from repository value: "
            f"{raw_value}"
        )
    return identity


def normalize_github_repository(raw_value: str) -> str:
    """The canonical identity, case-folded. GitHub owner and repository names
    are case-insensitive, so two spellings that differ only in case name one
    repository and must resolve to one drainer — otherwise two clones of the
    same repository could drain it concurrently."""
    return parse_github_repository(raw_value).lower()


def _join(path: str, key: str) -> str:
    return f"{path}.{key}" if path else key


def _collect_unknown(table: dict, path: str, warnings: list[str]) -> None:
    for key in table:
        warnings.append(f"unknown configuration key: {_join(path, key)}")


def _pop_bool(table: dict, key: str, path: str, default: bool) -> bool:
    if key not in table:
        return default
    value = table.pop(key)
    if not isinstance(value, bool):
        raise KanbanConfigError(f"{_join(path, key)} must be a boolean")
    return value


def _pop_nonempty_str(table: dict, key: str, path: str, default: str | None = None) -> str | None:
    if key not in table:
        return default
    value = table.pop(key)
    full = _join(path, key)
    if not isinstance(value, str):
        raise KanbanConfigError(f"{full} must be a string")
    if not value:
        raise KanbanConfigError(f"{full} must be a non-empty string")
    return value


def _pop_str_list(table: dict, key: str, path: str) -> list[str] | None:
    if key not in table:
        return None
    value = table.pop(key)
    full = _join(path, key)
    if not isinstance(value, list):
        raise KanbanConfigError(f"{full} must be an array of strings")
    result: list[str] = []
    for index, item in enumerate(value):
        if not isinstance(item, str) or not item:
            raise KanbanConfigError(f"{full}[{index}] must be a non-empty string")
        result.append(item)
    return result


# A 64-bit Int's range. Python's arbitrary-precision ints don't overflow
# themselves, but the Haskell dashboard decodes every one of these fields as
# a bounded `Int`, so this loader rejects the same out-of-range values to
# keep both sides' validation semantics identical.
_MAX_INT64 = 2**63 - 1
_MICROSECONDS_PER_SECOND = 1_000_000
_MAX_TIMEOUT_SECONDS = _MAX_INT64 // _MICROSECONDS_PER_SECOND


def _pop_positive_int(table: dict, key: str, path: str) -> int | None:
    if key not in table:
        return None
    value = table.pop(key)
    full = _join(path, key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise KanbanConfigError(f"{full} must be an integer")
    if value <= 0:
        raise KanbanConfigError(f"{full} must be a positive integer")
    if value > _MAX_INT64:
        raise KanbanConfigError(f"{full} must not exceed {_MAX_INT64}")
    return value


def _pop_positive_timeout_seconds(table: dict, key: str, path: str) -> int | None:
    value = _pop_positive_int(table, key, path)
    if value is not None and value > _MAX_TIMEOUT_SECONDS:
        raise KanbanConfigError(
            f"{_join(path, key)} must not be large enough to overflow when converted to microseconds"
        )
    return value


def _pop_enum(table: dict, key: str, path: str, choices: set[str]) -> str | None:
    if key not in table:
        return None
    value = table.pop(key)
    full = _join(path, key)
    if value not in choices:
        raise KanbanConfigError(
            f"{full} must be one of {sorted(choices)}; got {value!r}"
        )
    return value


def _pop_table(table: dict, key: str, path: str) -> tuple[dict, str] | None:
    if key not in table:
        return None
    value = table.pop(key)
    child_path = _join(path, key)
    if not isinstance(value, dict):
        raise KanbanConfigError(f"{child_path} must be a table")
    return dict(value), child_path


def _merge(base, override):
    updates = {name: value for name, value in vars(override).items() if value is not None}
    return replace(base, **updates) if updates else base


def _parse_workflow_override(value: dict, path: str, warnings: list[str]) -> WorkflowOverride:
    table = dict(value)
    approval_label = _pop_nonempty_str(table, "approval_label", path)
    changes_requested_label = _pop_nonempty_str(table, "changes_requested_label", path)
    blocked_labels = _pop_str_list(table, "blocked_labels", path)
    tracker_labels = _pop_str_list(table, "tracker_labels", path)
    headings = _pop_str_list(table, "additional_tracker_section_headings", path)
    approval_mode = _pop_enum(table, "approval_mode", path, APPROVAL_MODES)
    blocking_severity = _pop_enum(table, "blocking_severity", path, BLOCKING_SEVERITIES)
    problem_style_labels = _pop_str_list(table, "problem_style_labels", path)
    ui_style_labels = _pop_str_list(table, "ui_style_labels", path)
    _collect_unknown(table, path, warnings)
    return WorkflowOverride(
        approval_label=approval_label,
        changes_requested_label=changes_requested_label,
        blocked_labels=frozenset(blocked_labels) if blocked_labels is not None else None,
        tracker_labels=frozenset(tracker_labels) if tracker_labels is not None else None,
        additional_tracker_section_headings=(
            tuple(headings) if headings is not None else None
        ),
        approval_mode=approval_mode,
        blocking_severity=blocking_severity,
        problem_style_labels=(
            frozenset(problem_style_labels) if problem_style_labels is not None else None
        ),
        ui_style_labels=frozenset(ui_style_labels) if ui_style_labels is not None else None,
    )


def _parse_limits_override(value: dict, path: str, warnings: list[str]) -> LimitsOverride:
    table = dict(value)
    max_open_issues = _pop_positive_int(table, "max_open_issues", path)
    max_open_pull_requests = _pop_positive_int(table, "max_open_pull_requests", path)
    excerpt_lines = _pop_positive_int(table, "excerpt_lines", path)
    _collect_unknown(table, path, warnings)
    return LimitsOverride(
        max_open_issues=max_open_issues,
        max_open_pull_requests=max_open_pull_requests,
        excerpt_lines=excerpt_lines,
    )


def _parse_timeouts_override(value: dict, path: str, warnings: list[str]) -> TimeoutsOverride:
    table = dict(value)
    github_seconds = _pop_positive_timeout_seconds(table, "github_seconds", path)
    codex_seconds = _pop_positive_timeout_seconds(table, "codex_seconds", path)
    claude_seconds = _pop_positive_timeout_seconds(table, "claude_seconds", path)
    _collect_unknown(table, path, warnings)
    return TimeoutsOverride(
        github_seconds=github_seconds,
        codex_seconds=codex_seconds,
        claude_seconds=claude_seconds,
    )


def _parse_command_argv(value, path: str) -> UsageCommandConfig:
    if not isinstance(value, list):
        raise KanbanConfigError(f"{path} must be an array")
    if not value:
        raise KanbanConfigError(f"{path} must be a non-empty array")
    for item in value:
        if not isinstance(item, str):
            raise KanbanConfigError(f"{path} entries must be strings")
    if not value[0]:
        raise KanbanConfigError(f"{path} executable must be a non-empty string")
    return UsageCommandConfig(argv=tuple(value))


def _parse_usage_provider(table: dict, key: str, path: str, warnings: list[str]):
    popped = _pop_table(table, key, path)
    if popped is None:
        return None
    provider_table, child_path = popped
    command = provider_table.pop("command", None)
    result = _parse_command_argv(command, _join(child_path, "command")) if command is not None else None
    _collect_unknown(provider_table, child_path, warnings)
    return result


def _parse_usage_table(value: dict, path: str, warnings: list[str]) -> UsageConfig:
    table = dict(value)
    codex_command = _parse_usage_provider(table, "codex", path, warnings)
    claude_command = _parse_usage_provider(table, "claude", path, warnings)
    _collect_unknown(table, path, warnings)
    return UsageConfig(codex_command=codex_command, claude_command=claude_command)


# Kanban.Config.isCanonicalKeyCharacter. A repository override key is a
# configuration identifier, not another spelling of --repo input: exactly one
# canonical lowercase GitHub owner/name pair. That rejects uppercase,
# surrounding whitespace, URL and SCP remote syntax, repeated or extra
# slashes, and a missing segment by character and shape alone; a .git suffix
# needs its own rejection because every character in it is otherwise legal.
_CANONICAL_REPOSITORY_SEGMENT = re.compile(r"[a-z0-9._-]+")

# Kanban.Config.asciiLowercase. str.lower() would apply Unicode mappings the
# Haskell side does not; under this mapping a non-ASCII identity simply
# matches no canonical key, which is the correct outcome on both sides.
_ASCII_LOWERCASE = str.maketrans(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz"
)


def _is_canonical_repository_key(key: str) -> bool:
    segments = key.split("/")
    if len(segments) != 2:
        return False
    owner, name = segments
    if not _CANONICAL_REPOSITORY_SEGMENT.fullmatch(owner):
        return False
    return bool(_CANONICAL_REPOSITORY_SEGMENT.fullmatch(name)) and not name.endswith(".git")


def _parse_repositories_table(
    value: dict, path: str, warnings: list[str]
) -> dict[str, RepositoryOverride]:
    repos: dict[str, RepositoryOverride] = {}
    for repo_key, repo_value in value.items():
        child_path = f'{path}."{repo_key}"'
        if not _is_canonical_repository_key(repo_key):
            raise KanbanConfigError(
                f"{child_path} is not a canonical repository key; "
                'expected lowercase OWNER/NAME such as "coghex/kanban"'
            )
        if not isinstance(repo_value, dict):
            raise KanbanConfigError(f"{child_path} must be a table")
        repo_table = dict(repo_value)
        for forbidden in ("cache", "remote_name", "usage"):
            if forbidden in repo_table:
                raise KanbanConfigError(
                    f"{child_path}.{forbidden} is not valid in a repository override; "
                    "it is global-only"
                )
        workflow_override = WorkflowOverride()
        popped = _pop_table(repo_table, "workflow", child_path)
        if popped is not None:
            sub_value, sub_path = popped
            workflow_override = _parse_workflow_override(sub_value, sub_path, warnings)
        limits_override = LimitsOverride()
        popped = _pop_table(repo_table, "limits", child_path)
        if popped is not None:
            sub_value, sub_path = popped
            limits_override = _parse_limits_override(sub_value, sub_path, warnings)
        timeouts_override = TimeoutsOverride()
        popped = _pop_table(repo_table, "timeouts", child_path)
        if popped is not None:
            sub_value, sub_path = popped
            timeouts_override = _parse_timeouts_override(sub_value, sub_path, warnings)
        _collect_unknown(repo_table, child_path, warnings)
        repos[repo_key] = RepositoryOverride(
            workflow=workflow_override,
            limits=limits_override,
            timeouts=timeouts_override,
        )
    return repos


def _decode(data: dict) -> tuple[RawConfig, list[str]]:
    warnings: list[str] = []
    table = dict(data)

    cache = _pop_bool(table, "cache", "", True)
    remote_name = _pop_nonempty_str(table, "remote_name", "", "origin")

    workflow_override = WorkflowOverride()
    popped = _pop_table(table, "workflow", "")
    if popped is not None:
        value, child_path = popped
        workflow_override = _parse_workflow_override(value, child_path, warnings)

    limits_override = LimitsOverride()
    popped = _pop_table(table, "limits", "")
    if popped is not None:
        value, child_path = popped
        limits_override = _parse_limits_override(value, child_path, warnings)

    timeouts_override = TimeoutsOverride()
    popped = _pop_table(table, "timeouts", "")
    if popped is not None:
        value, child_path = popped
        timeouts_override = _parse_timeouts_override(value, child_path, warnings)

    usage = UsageConfig()
    popped = _pop_table(table, "usage", "")
    if popped is not None:
        value, child_path = popped
        usage = _parse_usage_table(value, child_path, warnings)

    repositories: dict[str, RepositoryOverride] = {}
    popped = _pop_table(table, "repositories", "")
    if popped is not None:
        value, child_path = popped
        repositories = _parse_repositories_table(value, child_path, warnings)

    _collect_unknown(table, "", warnings)

    raw = RawConfig(
        cache=cache,
        remote_name=remote_name,
        workflow=_merge(WorkflowConfig(), workflow_override),
        limits=_merge(LimitsConfig(), limits_override),
        timeouts=_merge(TimeoutsConfig(), timeouts_override),
        usage=usage,
        repositories=repositories,
    )
    _validate_raw_config(raw)
    return raw, warnings


def _validate_workflow_label_distinctness(context: str, workflow: WorkflowConfig) -> None:
    # The resolved approval and changes-requested labels must be distinct
    # from each other and from the fixed "reviewed:revised" protocol label,
    # for every selectable repository, not merely the global table: a
    # repository override that only sets one of the two labels can still
    # collide once merged with the global value of the other.
    approval = workflow.approval_label.casefold()
    changes = workflow.changes_requested_label.casefold()
    if approval == changes:
        raise KanbanConfigError(
            f"{context}.approval_label and {context}.changes_requested_label must not "
            f"resolve to the same label ({workflow.approval_label})"
        )
    if approval == "reviewed:revised":
        raise KanbanConfigError(
            f"{context}.approval_label must not resolve to the reserved reviewed:revised label"
        )
    if changes == "reviewed:revised":
        raise KanbanConfigError(
            f"{context}.changes_requested_label must not resolve to the reserved reviewed:revised label"
        )


def _validate_raw_config(raw: RawConfig) -> None:
    _validate_workflow_label_distinctness("workflow", raw.workflow)
    for name, override in raw.repositories.items():
        _validate_workflow_label_distinctness(
            f'repositories."{name}".workflow', _merge(raw.workflow, override.workflow)
        )


def load_raw_config(explicit_path: str | None) -> tuple[RawConfig, list[str]]:
    path = Path(explicit_path).expanduser() if explicit_path else default_config_path()
    if not path.exists():
        return RawConfig(), []
    try:
        with path.open("rb") as handle:
            data = tomllib.load(handle)
    except tomllib.TOMLDecodeError as exc:
        raise KanbanConfigError(f"configuration file {path} is invalid: {exc}") from exc
    except OSError as exc:
        raise KanbanConfigError(f"could not read configuration file {path}: {exc}") from exc
    try:
        raw, warnings = _decode(data)
    except KanbanConfigError as exc:
        raise KanbanConfigError(f"configuration file {path} is invalid: {exc}") from exc
    return raw, [f"configuration file {path}: {message}" for message in warnings]


def resolve_config(owner_slash_name: str, raw: RawConfig) -> ResolvedConfig:
    # Override keys are canonical lowercase, so the lookup is the one place
    # the identity is folded, exactly as in Kanban.Config.resolveConfig.
    # Callers keep passing their own repo slug, which still names the
    # repository for `gh`, REST paths, and remote comparison.
    override = raw.repositories.get(
        owner_slash_name.translate(_ASCII_LOWERCASE), RepositoryOverride()
    )
    return ResolvedConfig(
        cache=raw.cache,
        remote_name=raw.remote_name,
        workflow=_merge(raw.workflow, override.workflow),
        limits=_merge(raw.limits, override.limits),
        timeouts=_merge(raw.timeouts, override.timeouts),
        usage=raw.usage,
    )
