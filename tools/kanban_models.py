"""Shared model-roster reader for approve_issues.py, drain_prs.py, and the
Claude plugin's review_pr.py.

Schema is documented in models.toml.example at the repo root and mirrors
src/Kanban/Models.hs, which is the authoritative implementation: the two sides
read the same `~/.config/kanban/models.toml` (or `$XDG_CONFIG_HOME`), carry the
same compiled defaults, and answer an unusable file with the same vocabulary.
See that module for the semantics replicated here.

Two layers, deliberately provider-generic. *Providers* declare what exists --
an ordered model list and an effort vocabulary per brand -- and *roles* name
the pipeline steps, assigning each (role, provider) pair a model, an effort,
and a display label. How a provider turns an assignment into argv stays with
the caller, so argv shape never enters this file's schema. Each role also
carries a compiled *applicability* -- which providers it can run on at all --
which is code structure rather than configuration and therefore lives beside
the role registry here, never in the file.

Failure semantics follow the design's D-3, and are the reason this reader
raises rather than returning a value a caller might use by accident. An absent
file silently *is* `DEFAULT_ROSTER` -- the fresh-install path -- while a present
file that is unreadable, unparseable, foreign-versioned, or invalid is a
`RosterError` naming the file and the defect. Nothing here falls back to the
defaults from such a file, because an operator who edited it to change a model
must never have an agent quietly run on the old one. A present file is likewise
a complete roster rather than a sparse patch over the defaults: every loaded
provider a role applies to must resolve from the file itself.

This module ships in two homes, held byte-identical the way `kanban_config.py`'s
copies are: `tools/kanban_models.py`, which the issue-review and drainer
installers link beside the scripts that import it, and
`claude-plugin/plugins/kanban/scripts/kanban_models.py`, because an installed
coordinator runs from its bundle with no `tools/` sibling and must load the
reader from beside itself. The Codex bundle deliberately carries no copy: its
coordinator is forbidden model and effort values, and the roster never reaches
it.
"""

from __future__ import annotations

import os
import stat
import tomllib
from dataclasses import dataclass
from pathlib import Path


# Identity marker for this tracked asset; see the same constant in
# approve_issues.py for why installed files are recognized by content rather
# than by path.
KANBAN_MANAGED_ASSET = "kanban-managed-asset:issue-review/kanban_models.py"

# The version encode/decode agree on and the only one this build reads. Unlike
# the settings file, a foreign version is an error rather than silent defaults:
# D-3 forbids an unusable roster from quietly running agents on values the
# operator believes they replaced.
SCHEMA_VERSION = 1

# The providers this build carries an adapter for, and the pipeline steps it
# knows. Both mirror Kanban.Models' compiled registries; a key outside either
# is a validation error, since an assignment can only ever run through a
# compiled adapter.
PROVIDERS = ("codex", "claude")
ROLES = (
    "solve",
    "pr_review",
    "pr_revise",
    "issue_review",
    "issue_revise",
    "issue_gate",
    "drain_rereview",
)

_TOP_LEVEL_KEYS = ("schema_version", "agents", "providers", "roles")
_CATALOG_KEYS = ("models", "efforts")
_ASSIGNMENT_KEYS = ("model", "effort", "display")


class KanbanModelsError(Exception):
    """Base class, so a caller can refuse on any roster failure at once."""


class RosterError(KanbanModelsError):
    """A present roster file that yielded no roster.

    Carries the file and the defect separately as well as in the rendered
    message, because a caller that reports a failure and a caller that raises
    an incident about it want different shapes of the same fact.
    """

    def __init__(self, path: Path | str, detail: str) -> None:
        super().__init__(f"model roster {path} {detail}")
        self.path = Path(path)
        self.detail = detail


class AssignmentUnavailable(KanbanModelsError):
    """A valid roster that does not cover the cell the caller asked for.

    Distinct from `RosterError` on purpose: that is a file the operator must
    repair, while this describes a *valid* roster that simply does not cover
    what this run's routing selected -- a Claude-only roster asked for a Codex
    cell, say. That is a refusal to report, not a file to fix.
    """

    def __init__(self, role: str, provider: str, detail: str) -> None:
        super().__init__(detail)
        self.role = role
        self.provider = provider


class _Defective(Exception):
    """Internal: a decode failure, before it is bound to a file."""

    def __init__(self, detail: str) -> None:
        super().__init__(detail)
        self.detail = detail


@dataclass(frozen=True)
class ProviderCatalog:
    """One provider's declarations: the model IDs the operator considers
    available and the effort vocabulary its CLI accepts. Both keep file order,
    which is the order the settings screen cycles them in."""

    models: tuple[str, ...]
    efforts: tuple[str, ...]


@dataclass(frozen=True)
class Assignment:
    """One (role, provider) cell: the wire model and effort, and the label
    every surface that names this assignment displays."""

    model: str
    effort: str
    display: str


@dataclass(frozen=True)
class ModelRoster:
    """A complete roster.

    `agents` is the loaded provider set -- and therefore the operating mode --
    kept in file order; validation enforces its set semantics by refusing a
    repeated entry. Only this list changes what is loaded: editing a provider
    table never does.
    """

    agents: tuple[str, ...]
    providers: dict[str, ProviderCatalog]
    assignments: dict[tuple[str, str], Assignment]

    def assignment_for(self, role: str, provider: str) -> Assignment:
        """The one accessor a spawn site resolves a cell through.

        Deliberately the only way out of `assignments`: a bare lookup at each
        call site would let one of them recover with the compiled default,
        which is exactly the silent-old-model path D-3 forbids. Both
        preconditions are checked here rather than assumed, because a validated
        roster guarantees a cell only for loaded providers a role applies to,
        and nothing constrains today's brand routing to select one.
        """
        if role not in ROLES:
            raise AssignmentUnavailable(
                role, provider, f"model roster has no {role!r} role"
            )
        if provider not in PROVIDERS:
            raise AssignmentUnavailable(
                role, provider, f"model roster has no {provider!r} provider"
            )
        if provider not in self.agents:
            raise AssignmentUnavailable(
                role,
                provider,
                f'model roster does not load provider "{provider}", which this '
                f'"{role}" step runs on',
            )
        if provider not in role_applicability(role):
            raise AssignmentUnavailable(
                role,
                provider,
                f'model roster role "{role}" cannot run on provider "{provider}"',
            )
        assignment = self.assignments.get((role, provider))
        if assignment is None:
            raise AssignmentUnavailable(
                role,
                provider,
                f'model roster has no "roles.{role}.{provider}" assignment',
            )
        return assignment


def role_applicability(role: str) -> tuple[str, ...]:
    """Which providers a role can run on at all.

    `issue_revise` names the authenticated-Claude revision tool -- a Codex-only
    install revises inside the review thread itself -- so it is Claude-only by
    construction; every other role applies to both brands. Validation demands
    an assignment only for loaded providers a role applies to, and refuses one
    for a provider outside this list.
    """
    if role == "issue_revise":
        return ("claude",)
    return PROVIDERS


# The compiled defaults: today's wire values, cell for cell, equal to the
# tracked models.toml.example (a test holds the two together, on both sides of
# the language boundary). Thirteen applicable cells, every one valued.
DEFAULT_ROSTER = ModelRoster(
    agents=("codex", "claude"),
    providers={
        "codex": ProviderCatalog(
            models=("gpt-5.4", "gpt-5.5", "gpt-5.6-terra", "gpt-5.6-sol"),
            efforts=("minimal", "low", "medium", "high", "xhigh"),
        ),
        "claude": ProviderCatalog(
            models=("claude-sonnet-5", "claude-opus-5", "claude-fable-5"),
            efforts=("low", "medium", "high", "xhigh"),
        ),
    },
    assignments={
        ("solve", "codex"): Assignment("gpt-5.4", "high", "gpt-5.4 high"),
        ("solve", "claude"): Assignment("claude-sonnet-5", "high", "Sonnet 5 high"),
        ("pr_review", "codex"): Assignment(
            "gpt-5.6-terra", "xhigh", "GPT-5.6-Terra xhigh"
        ),
        ("pr_review", "claude"): Assignment("claude-opus-5", "xhigh", "Opus 5 xhigh"),
        ("pr_revise", "codex"): Assignment("gpt-5.4", "high", "gpt-5.4 high"),
        ("pr_revise", "claude"): Assignment("claude-sonnet-5", "xhigh", "Sonnet 5 xhigh"),
        ("issue_review", "codex"): Assignment("gpt-5.4", "high", "gpt-5.4 high"),
        ("issue_review", "claude"): Assignment("claude-opus-5", "xhigh", "Opus 5 xhigh"),
        ("issue_revise", "claude"): Assignment("claude-sonnet-5", "high", "Sonnet 5 high"),
        ("issue_gate", "codex"): Assignment("gpt-5.6-sol", "xhigh", "GPT-5.6-Sol xhigh"),
        ("issue_gate", "claude"): Assignment("claude-opus-5", "xhigh", "Opus 5 xhigh"),
        ("drain_rereview", "codex"): Assignment(
            "gpt-5.6-terra", "medium", "GPT-5.6-Terra medium"
        ),
        ("drain_rereview", "claude"): Assignment(
            "claude-opus-5", "medium", "Opus 5 medium"
        ),
    },
)


def default_roster_path() -> Path:
    """`models.toml` under the XDG configuration root, beside `config.toml`.

    Matches Kanban.Models.rosterPath (getXdgDirectory XdgConfig) and
    kanban_config.default_config_path: honor `$XDG_CONFIG_HOME` when set, so
    the dashboard and these tools agree on the same file. Resolved per call
    rather than frozen at import, for the same reason that module's resolvers
    are: freezing it would bind whatever `$HOME` and `$XDG_CONFIG_HOME` held
    when this module first loaded.
    """
    xdg_config_home = os.environ.get("XDG_CONFIG_HOME")
    if xdg_config_home:
        return Path(xdg_config_home) / "kanban" / "models.toml"
    return Path.home() / ".config" / "kanban" / "models.toml"


def load_roster(explicit_path: str | Path | None = None) -> ModelRoster:
    """The user's roster, or the compiled defaults when no file exists."""
    roster, _ = _load_or_absent(explicit_path)
    return DEFAULT_ROSTER if roster is None else roster


def resolve_assignment(
    role: str,
    provider: str,
    *,
    fallback: Assignment | None = None,
    explicit_path: str | Path | None = None,
) -> Assignment:
    """One cell, resolved the way a spawn site needs it.

    `fallback` is for the one caller that cannot import this module's tracked
    original -- the Claude plugin's bundled coordinator, which declares its own
    compiled constants and hands them here so the parity gate has a value in
    that file to hold against `models.toml.example`. It stands in for the
    compiled defaults on the absent-file path *only*: a present file that will
    not load still raises, because a fallback is not a repair for a roster the
    operator broke.
    """
    roster, _ = _load_or_absent(explicit_path)
    if roster is None:
        if fallback is not None:
            return fallback
        roster = DEFAULT_ROSTER
    return roster.assignment_for(role, provider)


def _load_or_absent(
    explicit_path: str | Path | None,
) -> tuple[ModelRoster | None, Path]:
    """The decoded roster and its path, or `None` when the file is absent.

    Absence is judged by `os.lstat` rather than an existence probe, and only
    `ENOENT` counts as absent. `os.path.lexists` and `Path.is_file` both answer
    False for *every* `OSError` -- an unreadable parent directory reads exactly
    like a file that was never created -- so either would turn a permission
    refusal into the compiled defaults, which is the silent-old-model
    fall-through D-3 forbids. A dangling symbolic link or a directory at the
    path is likewise present but unusable, never absent.

    Once something is present, the resolved target must additionally be a
    regular file *before* any open, because opening is not a safe probe here:
    a FIFO would block the reader until a writer connects, hanging the caller
    rather than refusing. That resolution is `os.stat`, not `Path.is_file`, for
    the same swallowing reason -- and it is what makes a symbolic link to a
    regular file stay loadable while one to nothing refuses.

    This mirrors `Kanban.Models.loadModelRoster`, which draws exactly these
    distinctions with `getSymbolicLinkStatus`, `isDoesNotExistError`, and
    `getFileStatus`.
    """
    path = (
        Path(explicit_path).expanduser()
        if explicit_path is not None
        else default_roster_path()
    )
    try:
        os.lstat(path)
    except FileNotFoundError:
        return None, path
    except OSError as error:
        raise RosterError(path, f"could not be read: {error}") from error
    try:
        status = os.stat(path)
    except OSError as error:
        raise RosterError(path, f"could not be read: {error}") from error
    if not stat.S_ISREG(status.st_mode):
        raise RosterError(path, "could not be read: not a regular file")
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise RosterError(path, f"could not be read: {error}") from error
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise RosterError(path, f"is not parseable TOML: not UTF-8: {error}") from error
    return decode_roster(text, path), path


def decode_roster(text: str, path: str | Path) -> ModelRoster:
    """Decode and validate one file's text.

    `path` names the file every failure reports, so a caller decoding a string
    it built itself still produces the one message shape every refusal surface
    shares.
    """
    try:
        document = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        raise RosterError(path, f"is not parseable TOML: {error}") from error
    try:
        return _decode_document(document)
    except _Defective as defective:
        raise RosterError(path, defective.detail) from None


def _decode_document(document: dict) -> ModelRoster:
    """The version gates everything: a file that does not carry
    `schema_version = 1` is judged on that alone, because its payload is not
    ours to interpret."""
    if "schema_version" not in document:
        raise _Defective(_invalid([_missing_key("schema_version")]))
    version = document["schema_version"]
    if isinstance(version, bool) or not isinstance(version, int):
        raise _Defective(
            _invalid([_invalid_value("schema_version", "must be an integer")])
        )
    if version != SCHEMA_VERSION:
        raise _Defective(
            f"carries schema_version {version}; this build reads version "
            f"{SCHEMA_VERSION}"
        )

    defects = [
        _unknown_key(key)
        for key in sorted(document)
        if key not in _TOP_LEVEL_KEYS
    ]
    agent_defects, agents = _decode_agents(document.get("agents", _ABSENT))
    provider_defects, providers = _decode_providers(document.get("providers", _ABSENT))
    role_defects, assignments, present_cells = _decode_roles(
        document.get("roles", _ABSENT)
    )
    defects += agent_defects + provider_defects + role_defects
    defects += _validate(agents, providers, assignments, present_cells)
    if defects:
        raise _Defective(_invalid(defects))
    return ModelRoster(
        agents=_loaded_providers(agents),
        providers=providers,
        assignments=assignments,
    )


# A distinct absent marker, because `None` is a value TOML cannot produce but
# a caller building a document in process could.
_ABSENT = object()


def _decode_agents(value) -> tuple[list[str], tuple[str, ...] | None]:
    """The raw `agents` entries, or `None` when the key is absent -- which
    silently means every provider, the one absence in this schema that is a
    default rather than a defect."""
    if value is _ABSENT:
        return [], None
    requirement = "must be an array of provider-name strings"
    if not isinstance(value, list) or not all(
        isinstance(item, str) for item in value
    ):
        return [_invalid_value("agents", requirement)], ()
    return [
        _duplicate_entry("agents", name) for name in _duplicated(value)
    ], tuple(value)


def _loaded_providers(agents: tuple[str, ...] | None) -> tuple[str, ...]:
    """The effective loaded set: the declared order of `agents`, or every
    provider when the key is absent. Entries naming no known provider are
    already defects; this projection is only consulted once there are none."""
    if agents is None:
        return PROVIDERS
    return tuple(name for name in agents if name in PROVIDERS)


def _decode_providers(value) -> tuple[list[str], dict[str, ProviderCatalog]]:
    if value is _ABSENT:
        return [], {}
    if not isinstance(value, dict):
        return [
            _invalid_value("providers", "must be a table of provider declarations")
        ], {}
    defects: list[str] = []
    catalogs: dict[str, ProviderCatalog] = {}
    for key in sorted(value):
        path = f"providers.{key}"
        if key not in PROVIDERS:
            defects.append(_unknown_provider_key(path))
            continue
        # A defective declaration still lands in the map -- the table exists,
        # so the provider is declared, and treating it as absent would cascade
        # misleading undeclared-provider defects on top of the real one.
        catalog_defects, catalog = _decode_catalog(path, value[key])
        defects += catalog_defects
        catalogs[key] = catalog
    return defects, catalogs


def _decode_catalog(path: str, value) -> tuple[list[str], ProviderCatalog]:
    if not isinstance(value, dict):
        return [
            _invalid_value(path, "must be a table declaring models and efforts")
        ], ProviderCatalog((), ())
    defects = [
        _unknown_key(f"{path}.{key}")
        for key in sorted(value)
        if key not in _CATALOG_KEYS
    ]
    model_defects, models = _decode_name_list(
        f"{path}.models", "model IDs", value.get("models", _ABSENT)
    )
    effort_defects, efforts = _decode_name_list(
        f"{path}.efforts", "effort names", value.get("efforts", _ABSENT)
    )
    return defects + model_defects + effort_defects, ProviderCatalog(models, efforts)


def _decode_name_list(path: str, what: str, value) -> tuple[list[str], tuple[str, ...]]:
    """A required, non-empty, repeat-free array of strings, in file order."""
    if value is _ABSENT:
        return [_missing_key(path)], ()
    requirement = f"must be a non-empty array of {what}"
    if (
        not isinstance(value, list)
        or not value
        or not all(isinstance(item, str) for item in value)
    ):
        return [_invalid_value(path, requirement)], ()
    return [_duplicate_entry(path, name) for name in _duplicated(value)], tuple(value)


def _decode_roles(
    value,
) -> tuple[list[str], dict[tuple[str, str], Assignment], list[tuple[str, str]]]:
    """The `[roles.*.*]` grid: the complete assignments, plus every cell that
    is present at all -- including defective ones, which must not additionally
    read as missing."""
    if value is _ABSENT:
        return [], {}, []
    if not isinstance(value, dict):
        return [_invalid_value("roles", "must be a table of role assignments")], {}, []
    defects: list[str] = []
    assignments: dict[tuple[str, str], Assignment] = {}
    present: list[tuple[str, str]] = []
    for key in sorted(value):
        path = f"roles.{key}"
        if key not in ROLES:
            defects.append(_unknown_role_key(path))
            continue
        role_defects, role_assignments, role_present = _decode_role_table(
            key, path, value[key]
        )
        defects += role_defects
        assignments.update(role_assignments)
        present += role_present
    return defects, assignments, present


def _decode_role_table(
    role: str, path: str, value
) -> tuple[list[str], dict[tuple[str, str], Assignment], list[tuple[str, str]]]:
    if not isinstance(value, dict):
        return (
            [_invalid_value(path, "must be a table of per-provider assignments")],
            {},
            [],
        )
    defects: list[str] = []
    assignments: dict[tuple[str, str], Assignment] = {}
    present: list[tuple[str, str]] = []
    for key in sorted(value):
        cell_path = f"{path}.{key}"
        if key not in PROVIDERS:
            defects.append(_unknown_provider_key(cell_path))
            continue
        cell_defects, assignment = _decode_assignment(cell_path, value[key])
        defects += cell_defects
        if assignment is not None:
            assignments[(role, key)] = assignment
        present.append((role, key))
    return defects, assignments, present


def _decode_assignment(path: str, value) -> tuple[list[str], Assignment | None]:
    """One assignment table. A defective cell yields its defects and no
    `Assignment`: the membership checks need all three fields, and the cell's
    presence is what keeps it out of the missing-assignment sweep."""
    if not isinstance(value, dict):
        return [
            _invalid_value(path, "must be a table assigning model, effort, and display")
        ], None
    defects = [
        _unknown_key(f"{path}.{key}")
        for key in sorted(value)
        if key not in _ASSIGNMENT_KEYS
    ]
    fields = {}
    for key in _ASSIGNMENT_KEYS:
        field_defects, text = _required_text(f"{path}.{key}", value.get(key, _ABSENT))
        defects += field_defects
        fields[key] = text
    if any(text is None for text in fields.values()):
        return defects, None
    return defects, Assignment(fields["model"], fields["effort"], fields["display"])


def _required_text(path: str, value) -> tuple[list[str], str | None]:
    if value is _ABSENT:
        return [_missing_key(path)], None
    if not isinstance(value, str):
        return [_invalid_value(path, "must be a string")], None
    return [], value


def _validate(
    agents: tuple[str, ...] | None,
    providers: dict[str, ProviderCatalog],
    assignments: dict[tuple[str, str], Assignment],
    present_cells: list[tuple[str, str]],
) -> list[str]:
    """The cross-references a shape-valid file must still satisfy: every agent
    declared, every assignment applicable and inside its provider's declared
    catalog, and every loaded (role, provider) cell valued."""
    agent_names = PROVIDERS if agents is None else agents
    defects = [
        _undeclared_agent(name)
        for name in _unique_in_order(agent_names)
        if name not in providers
    ]
    for role, provider in present_cells:
        if provider not in role_applicability(role):
            defects.append(
                f"roles.{role}.{provider} assigns a provider this role cannot run on"
            )
        elif provider not in providers:
            defects.append(
                f"roles.{role}.{provider} assigns a provider the file never declares"
            )
    for (role, provider), assignment in sorted(assignments.items()):
        catalog = providers.get(provider)
        if catalog is None or provider not in role_applicability(role):
            continue
        if assignment.model not in catalog.models:
            defects.append(
                f'roles.{role}.{provider} names model "{assignment.model}", which '
                "is not in that provider's models list"
            )
        if assignment.effort not in catalog.efforts:
            defects.append(
                f'roles.{role}.{provider} names effort "{assignment.effort}", which '
                "is not in that provider's efforts list"
            )
    loaded = _loaded_providers(agents)
    for role in ROLES:
        for provider in role_applicability(role):
            if provider in loaded and (role, provider) not in present_cells:
                defects.append(
                    f"roles.{role}.{provider} is required for a loaded provider "
                    "this role applies to, and missing"
                )
    return defects


def _duplicated(names) -> list[str]:
    seen: set[str] = set()
    repeated: list[str] = []
    for name in names:
        if name in seen and name not in repeated:
            repeated.append(name)
        seen.add(name)
    return sorted(repeated)


def _unique_in_order(names) -> list[str]:
    seen: set[str] = set()
    unique = []
    for name in names:
        if name not in seen:
            seen.add(name)
            unique.append(name)
    return unique


# The defect vocabulary, one spelling each. Unknown keys are defects at every
# level rather than warnings: silently skipping a misspelled
# `[roles.pr_reveiw.codex]` is how an operator ships the old model believing
# they changed it.


def _invalid(defects: list[str]) -> str:
    return "is invalid: " + "; ".join(defects)


def _unknown_key(path: str) -> str:
    return f'"{path}" is not a key this schema knows'


def _missing_key(path: str) -> str:
    return f'"{path}" is required and missing'


def _invalid_value(path: str, requirement: str) -> str:
    return f'"{path}" {requirement}'


def _duplicate_entry(path: str, entry: str) -> str:
    return f'"{path}" lists "{entry}" more than once'


def _unknown_provider_key(path: str) -> str:
    return f'"{path}" does not name a known provider'


def _unknown_role_key(path: str) -> str:
    return f'"{path}" does not name a known role'


def _undeclared_agent(agent: str) -> str:
    return f'agents entry "{agent}" has no [providers.{agent}] declaration'
