#!/usr/bin/env python3
"""Run the canonical, issue-gated pull-request review workflow."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util  # loads the model-roster reader beside this file
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import urllib.parse
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable


REVIEW_TIMEOUT_SECONDS = 7200
GATE_TEXT = "Issue has not been approved."
VALID_ORIGIN_RE = re.compile(r"<!-- pr-origin:(claude|codex) -->")
REVIEW_MARKER_RE = re.compile(
    r"<!-- pr-review:v2 reviewers=(?P<reviewers>\S+) models=(?P<models>\S+) "
    r"head=(?P<head>[0-9a-f]{40}) verdict=(?P<verdict>APPROVE|CHANGES_REQUESTED) -->"
)
# The marker's `models=` field is kept for pr-review:v2 format compatibility
# with existing tooling (tools/drain_prs.py's PR_REVIEW_V2_RE expects a
# non-whitespace token there), but this coordinator does not pin or verify a
# specific model for the reviewer it spawns, so it publishes this literal
# token rather than an unverifiable model@effort claim. `reviewers=` (which
# executable actually ran) remains the one identity claim this coordinator
# controls and can back.
UNVERIFIED_MODEL_TOKEN = "unspecified"

# Canonical nested-reviewer model/effort (issue #77 round-2 review). Unlike
# the self-reviewed known-origin case, invoke_codex/invoke_claude below
# fully construct the subprocess they spawn, so — for this plugin's
# bundled coordinator only — they pin it and can therefore verify and
# publish it, matching the exact gpt-5.6-terra/claude-opus-5 at xhigh
# values the roles.pr_review.codex and roles.pr_review.claude cells of
# models.toml.example declare -- the cells Kanban's own
# PullRequestReview/PullRequestRereview spawns resolve from the model
# roster. This is a deliberate, reviewed divergence from
# codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py's
# otherwise-identical copy and from docs/agent-workflow-contract.md §2.2's
# general "brand only, no pinned model" policy for this nested-spawn path;
# the self-reviewed path is unaffected and still cannot verify a model,
# since Kanban's own top-level spawn — outside this coordinator's
# visibility — is what pins that one.
CODEX_NESTED_REVIEW_MODEL = "gpt-5.6-terra"
CODEX_NESTED_REVIEW_EFFORT = "xhigh"
CLAUDE_NESTED_REVIEW_MODEL = "claude-opus-5"
CLAUDE_NESTED_REVIEW_EFFORT = "xhigh"

_KANBAN_MODELS_MODULE = None


def kanban_models():
    """The model-roster reader, loaded from beside this coordinator.

    From beside itself and never from `tools/`: an installed bundle has no
    `tools/` sibling, and a plain `import` would resolve one only when this
    file happens to run out of a checkout -- silently reading a different
    copy's compiled defaults there and failing everywhere else. Loaded once and
    memoized, the way the document mechanism loads its own siblings, and
    registered in `sys.modules` before execution because that module declares
    dataclasses, which resolve their own class's `__module__` through
    `sys.modules` while the class body is still being processed.
    """
    global _KANBAN_MODELS_MODULE
    if _KANBAN_MODELS_MODULE is not None:
        return _KANBAN_MODELS_MODULE
    source = Path(__file__).resolve().parent / "kanban_models.py"
    name = "_kanban_models_for_review_coordinator"
    try:
        spec = importlib.util.spec_from_file_location(name, source)
        if spec is None or spec.loader is None:
            raise ImportError(f"no loader for {source}")
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        try:
            spec.loader.exec_module(module)
        except BaseException:
            sys.modules.pop(name, None)
            raise
    except Exception as error:  # noqa: BLE001 - reported, never raised bare
        raise WorkflowError(
            f"This bundle's model-roster reader at {source} could not be "
            f"loaded, so no nested review was performed: {error}"
        ) from error
    _KANBAN_MODELS_MODULE = module
    return module


def nested_review_assignment(provider: str):
    """The `roles.pr_review.<provider>` cell this coordinator spawns on.

    The four constants above are what the reader falls back to when the host
    carries no roster file at all -- equal, cell for cell, to that reader's own
    compiled defaults, which `tools/test_claude_plugin.py` holds against the
    tracked `models.toml.example`. A roster file that is present and will not
    load refuses the nested review instead: an operator who edited it to change
    a reviewer model must never have this coordinator quietly spawn the old one
    and then publish that model as verified fact in the `pr-review:v2` marker.
    """
    models = kanban_models()
    fallbacks = {
        "codex": models.Assignment(
            CODEX_NESTED_REVIEW_MODEL, CODEX_NESTED_REVIEW_EFFORT, "pr_review codex"
        ),
        "claude": models.Assignment(
            CLAUDE_NESTED_REVIEW_MODEL, CLAUDE_NESTED_REVIEW_EFFORT, "pr_review claude"
        ),
    }
    try:
        return models.resolve_assignment(
            "pr_review", provider, fallback=fallbacks[provider]
        )
    except models.KanbanModelsError as error:
        raise WorkflowError(f"{error}; no nested review was performed") from error

MAX_REVIEW_SUMMARY_CHARS = 4000
MAX_REVIEW_BLOCKER_BODY_CHARS = 2000
MAX_REVIEW_BLOCKING_CONCERNS = 30


REVIEW_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "verdict": {"type": "string", "enum": ["APPROVE", "CHANGES_REQUESTED"]},
        "summary": {
            "type": "string",
            "minLength": 1,
            "maxLength": MAX_REVIEW_SUMMARY_CHARS,
        },
        "blocking_concerns": {
            "type": "array",
            "maxItems": MAX_REVIEW_BLOCKING_CONCERNS,
            "items": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "line": {"type": "string"},
                    "body": {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": MAX_REVIEW_BLOCKER_BODY_CHARS,
                    },
                },
                "required": ["path", "line", "body"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["verdict", "summary", "blocking_concerns"],
    "additionalProperties": False,
}


class WorkflowError(RuntimeError):
    pass


@dataclass(frozen=True)
class Reviewer:
    key: str
    display_name: str


# Brand identity only, per docs/agent-workflow-contract.md §2.2's
# "Cross-brand handoff model policy". These identify a REVIEWER ROLE, not a
# pinned model: for the normal self-reviewed path (see workflow()'s
# self_review parameter), the reviewer IS the already-correctly-pinned
# calling session, so no model claim is made at all beyond the brand. Only
# the nested spawn used by pr-revise's cross-brand handoff and the rare
# dual-review fallback (invoke_codex/invoke_claude) cannot verify which
# specific model actually ran; which executable runs — codex or claude — is
# the one thing that path does control and publish as fact.
CODEX_REVIEWER = Reviewer("codex", "Codex")
CLAUDE_REVIEWER = Reviewer("claude", "Claude")


def run(
    args: list[str],
    *,
    cwd: Path,
    input_text: str | None = None,
    timeout: int = 120,
    ok_codes: tuple[int, ...] = (0,),
) -> subprocess.CompletedProcess[str]:
    try:
        proc = subprocess.run(
            args,
            cwd=cwd,
            input=input_text,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise WorkflowError(f"{' '.join(args[:4])} timed out after {timeout}s") from exc
    except OSError as exc:
        raise WorkflowError(f"could not run {args[0]}: {exc}") from exc
    if proc.returncode not in ok_codes:
        detail = (proc.stderr or proc.stdout).strip()[-4000:]
        raise WorkflowError(f"{' '.join(args[:4])} failed ({proc.returncode}): {detail}")
    return proc


def load_json(text: str, context: str) -> Any:
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise WorkflowError(f"{context} returned invalid JSON: {text[-2000:]}") from exc


def gh_json(root: Path, args: list[str]) -> Any:
    proc = run(["gh", *args], cwd=root)
    return load_json(proc.stdout, f"gh {' '.join(args[:3])}")


def paginated_api(root: Path, endpoint: str) -> list[dict[str, Any]]:
    pages = gh_json(root, ["api", "--paginate", "--slurp", endpoint])
    if not isinstance(pages, list):
        raise WorkflowError(f"unexpected paginated response for {endpoint}")
    flattened: list[dict[str, Any]] = []
    for page in pages:
        if not isinstance(page, list):
            raise WorkflowError(f"unexpected page response for {endpoint}")
        flattened.extend(item for item in page if isinstance(item, dict))
    return flattened


def parse_repository_name(raw_value: str) -> str | None:
    """Mirrors Kanban.Repository.parseRepositoryName: derives OWNER/NAME
    from a git remote URL (SSH, HTTPS, or already-bare OWNER/NAME)."""
    stripped = raw_value.strip()
    for prefix in ("https://", "http://", "ssh://", "git://"):
        if stripped.startswith(prefix):
            stripped = stripped[len(prefix) :]
            break
    normalized = stripped.replace("git@github.com", "github.com").replace(":", "/").rstrip("/")
    segments = [segment for segment in normalized.split("/") if segment]
    if len(segments) < 2:
        return None
    owner, name = segments[-2], segments[-1]
    if name.endswith(".git"):
        name = name[: -len(".git")]
    if not owner or not name:
        return None
    return f"{owner}/{name}"


def resolve_repository(root: Path, config_path: str | None, explicit_repo: str | None = None) -> str:
    """Resolves OWNER/NAME. An explicit --repo (matching Kanban's own
    --repo option) always wins and is never re-derived from the checkout's
    remote — this is how a fork checkout launched with, say, --repo
    upstream/repo reviews upstream's PR rather than gh's own default-repo
    inference (or even the configured remote) silently targeting the fork.
    Otherwise resolves from the dashboard-configured remote (mirrors
    Kanban.Repository.resolveRepository), not gh's own default-repo
    inference."""
    if explicit_repo:
        parsed = parse_repository_name(explicit_repo)
        if parsed is None:
            raise WorkflowError(f"cannot derive OWNER/NAME from --repo: {explicit_repo}")
        return parsed
    remote_name = resolve_remote_name(config_path)
    proc = subprocess.run(
        ["git", "remote", "get-url", remote_name],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise WorkflowError(
            f"could not resolve git remote {remote_name!r}: {proc.stderr.strip()}"
        )
    parsed = parse_repository_name(proc.stdout)
    if parsed is None:
        raise WorkflowError(
            f"cannot derive OWNER/NAME from remote {remote_name!r}: {proc.stdout.strip()}"
        )
    return parsed


def default_kanban_config_path() -> Path:
    # Mirrors Kanban.Config.defaultConfigPath / tools/kanban_config.py's
    # default_config_path(): this coordinator reviews arbitrary target
    # repositories (not necessarily a Kanban checkout), so it cannot import
    # tools/kanban_config.py and instead resolves the same well-known path
    # directly.
    xdg_config_home = os.environ.get("XDG_CONFIG_HOME")
    base = Path(xdg_config_home) if xdg_config_home else Path.home() / ".config"
    return base / "kanban" / "config.toml"


# Kanban.Config.asciiLowercase. str.lower() would apply Unicode mappings the
# Haskell side does not, so a non-ASCII identity must fall through to the
# global labels here too.
_ASCII_LOWERCASE = str.maketrans(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz"
)


def resolve_workflow_labels(config_path: str | None, repo: str) -> tuple[str, str]:
    """Minimal mirror of Kanban.Config's workflow.approval_label /
    changes_requested_label resolution (global value, then a matching
    [repositories."owner/name"] override). This coordinator only mutates and
    verifies those two labels, so it does not need the rest of the schema
    kanban_config.py loads for the dashboard and the canonical Python tools;
    a missing or unreadable file silently keeps the documented defaults."""
    approval_label, changes_requested_label = "reviewed:approve", "reviewed:changes"
    path = Path(config_path).expanduser() if config_path else default_kanban_config_path()
    if not path.is_file():
        return approval_label, changes_requested_label
    try:
        with path.open("rb") as handle:
            data = tomllib.load(handle)
    except (tomllib.TOMLDecodeError, OSError):
        return approval_label, changes_requested_label

    def apply(table: Any) -> None:
        nonlocal approval_label, changes_requested_label
        if not isinstance(table, dict):
            return
        workflow = table.get("workflow")
        if not isinstance(workflow, dict):
            return
        if isinstance(workflow.get("approval_label"), str) and workflow["approval_label"]:
            approval_label = workflow["approval_label"]
        if (
            isinstance(workflow.get("changes_requested_label"), str)
            and workflow["changes_requested_label"]
        ):
            changes_requested_label = workflow["changes_requested_label"]

    apply(data)
    repositories = data.get("repositories")
    if isinstance(repositories, dict):
        # Override keys are canonical lowercase owner/name, and the dashboard,
        # approve_issues.py, and drain_prs.py all fold the resolved identity
        # the same ASCII-only way before this lookup. Without it a mixed-case
        # clone would make this coordinator write and verify the *global*
        # verdict label while they use the override's.
        apply(repositories.get(repo.translate(_ASCII_LOWERCASE)))
    return approval_label, changes_requested_label


def resolve_remote_name(config_path: str | None) -> str:
    """Minimal mirror of Kanban.Config's global-only remote_name resolution
    (see resolve_workflow_labels for why this doesn't import
    tools/kanban_config.py)."""
    path = Path(config_path).expanduser() if config_path else default_kanban_config_path()
    if not path.is_file():
        return "origin"
    try:
        with path.open("rb") as handle:
            data = tomllib.load(handle)
    except (tomllib.TOMLDecodeError, OSError):
        return "origin"
    remote_name = data.get("remote_name")
    return remote_name if isinstance(remote_name, str) and remote_name else "origin"


def url_names_a_pull_request(url: str) -> bool:
    """Whether a GitHub web URL points at a pull request rather than an issue.

    Issues render under `/issues/<n>`, pull requests under `/pull/<n>`. Compare
    the path SEGMENT before the number, never a substring -- a repository
    literally named `pull` puts `/pull/` in the URL of every one of its issues.

    Deliberately duplicated from `tools/approve_issues.py` rather than shared:
    this script is a vendored, self-contained plugin asset (see
    `docs/agent-workflow-contract.md` §3) and must not import from `tools/`.
    """
    segments = [part for part in urllib.parse.urlsplit(url).path.split("/") if part]
    return len(segments) >= 2 and segments[-2] == "pull"


def github_number_kind(root: Path, repo: str, number: int) -> str | None:
    """"issue", "pull", or None when the number resolves to neither.

    Asks through `gh issue view`, which -- unlike `gh pr view` -- resolves BOTH
    kinds, so one call classifies any number. Never asks `gh pr view --json
    number`: that form returns exit 0 for an issue number without consulting
    the pull-request resolver, so it cannot tell the two apart.
    """
    try:
        value = gh_json(root, ["issue", "view", str(number), "-R", repo, "--json", "url"])
    except WorkflowError:
        return None
    if not isinstance(value, dict) or not isinstance(value.get("url"), str):
        return None
    return "pull" if url_names_a_pull_request(value["url"]) else "issue"


def pr_view(root: Path, repo: str, number: int) -> dict[str, Any]:
    fields = ",".join(
        [
            "number",
            "title",
            "body",
            "state",
            "url",
            "author",
            "baseRefName",
            "headRefName",
            "headRefOid",
            "mergeable",
            "labels",
            "files",
            "commits",
            "reviews",
            "statusCheckRollup",
            "closingIssuesReferences",
            "isCrossRepository",
            "isDraft",
        ]
    )
    try:
        value = gh_json(root, ["pr", "view", str(number), "-R", repo, "--json", fields])
    except WorkflowError:
        # `gh pr view` fails on an issue number, but only with a GraphQL
        # resolver error naming neither the number's real kind nor the
        # mistake. Re-query authoritatively rather than pattern-matching that
        # message, which varies by gh version -- and only on the failure path,
        # so a healthy review pays nothing for it.
        kind = github_number_kind(root, repo, number)
        if kind == "issue":
            raise WorkflowError(
                f"#{number} is an ISSUE, not a pull request. This workflow "
                "reviews pull requests only; GitHub shares one number space "
                "between them. Nothing was modified. Use the issue-review "
                f"workflow for #{number} instead."
            ) from None
        raise
    if not isinstance(value, dict):
        raise WorkflowError(f"PR #{number} returned an unexpected response")
    if value.get("state") != "OPEN":
        raise WorkflowError(f"PR #{number} is not open")
    head = value.get("headRefOid")
    if not isinstance(head, str) or not re.fullmatch(r"[0-9a-f]{40}", head):
        raise WorkflowError(f"PR #{number} has no valid head SHA")
    return value


def origin_from_body(body: str) -> str | None:
    matches = list(VALID_ORIGIN_RE.finditer(body))
    if len(matches) != 1 or body.count("pr-origin:") != 1:
        return None
    if body.rstrip() != body[: matches[0].end()].rstrip():
        return None
    return matches[0].group(1)


def reviewer_for_key(key: str) -> Reviewer:
    if key == CODEX_REVIEWER.key:
        return CODEX_REVIEWER
    if key == CLAUDE_REVIEWER.key:
        return CLAUDE_REVIEWER
    raise WorkflowError(f"Unknown reviewer brand {key!r}")


def model_roster():
    """This host's roster, read through the reader beside this coordinator.

    A roster file that is present and will not load refuses the whole workflow
    rather than routing on the compiled defaults: an operator who edited it
    must never have this coordinator review with a provider they removed. That
    refusal is deliberately distinct from the no-agent operating mode below --
    one is a file to repair, the other is a deliberate board-only install.
    """
    models = kanban_models()
    try:
        return models.load_roster()
    except models.KanbanModelsError as error:
        raise WorkflowError(f"{error}; no review was performed") from error


def operating_mode() -> tuple[str, tuple[str, ...]]:
    """This host's operating mode and its loaded provider set, together.

    Returned as a pair because every caller needs both and reading them from
    two loads could straddle an edit of the file between them.
    """
    roster = model_roster()
    return kanban_models().operating_mode_for(roster), roster.agents


def route_reviewers(
    origin: str | None,
    *,
    mode: str | None = None,
    loaded: tuple[str, ...] | None = None,
) -> list[Reviewer]:
    """Which reviewers this pull request's origin routes it to.

    Dual mode is the cross-brand routing this workflow has always done, with
    an unknown or external origin falling through to both. Single-agent
    collapses every origin -- known, unknown, and external alike -- to the one
    loaded provider, because that provider is the only reviewer this
    installation can spawn; the opposite-brand promise is a property of a
    two-provider roster, not of the workflow. No-agent routes to nobody, and
    the callers refuse before they can act on the empty list.

    `mode` and `loaded` default to this host's own and are parameters only so
    --self-test can ask about all three modes wherever it runs.
    """
    if mode is None or loaded is None:
        mode, loaded = operating_mode()
    models = kanban_models()
    if mode == models.NO_AGENT_MODE:
        return []
    if mode == models.SINGLE_AGENT_MODE:
        return [reviewer_for_key(loaded[0])]
    if origin == "claude":
        return [CODEX_REVIEWER]
    if origin == "codex":
        return [CLAUDE_REVIEWER]
    return [CODEX_REVIEWER, CLAUDE_REVIEWER]


# The status a no-agent refusal reports. Its own status rather than a generic
# error, so a caller can tell "this installation deliberately spawns nothing"
# from a workflow that failed.
NO_AGENT_STATUS = "no_agent_mode"


def no_agent_refusal(number: int) -> tuple[int, dict[str, Any]]:
    """Refuse the whole workflow because no provider is loaded.

    Taken before the pull request is read, so nothing is published, no label is
    switched, and no reviewer is spawned. Non-zero, because the caller asked
    for a review and did not get one.
    """
    return 1, {
        "pr": number,
        "status": NO_AGENT_STATUS,
        "route": "",
        "error": (
            "The model roster loads no agent "
            f"({kanban_models().NO_AGENT_MODE} operating mode), so this "
            "coordinator has no reviewer to route to. Nothing was published "
            "and no label was changed. Add a provider to the roster's "
            "`agents` list to restore pull-request review."
        ),
    }


def pr_origin(pr: dict[str, Any]) -> str | None:
    if pr.get("isCrossRepository"):
        return None
    return origin_from_body(str(pr.get("body") or ""))


def linked_issue_numbers(pr: dict[str, Any], repo: str) -> tuple[list[int], list[str]]:
    numbers: list[int] = []
    invalid: list[str] = []
    for ref in pr.get("closingIssuesReferences") or []:
        if not isinstance(ref, dict):
            invalid.append("malformed")
            continue
        number = ref.get("number")
        repository = ref.get("repository") or {}
        owner = repository.get("owner") or {}
        linked_repo = f"{owner.get('login')}/{repository.get('name')}"
        if not isinstance(number, int) or number < 1 or linked_repo.lower() != repo.lower():
            invalid.append(str(ref.get("url") or "external"))
            continue
        numbers.append(number)
    return sorted(set(numbers)), invalid


def issue_review_record_candidates() -> tuple[Path, Path]:
    """Both fixed documents `tools/install_issue_review.py` may have recorded
    the installed backend in, in probe order: the XDG data directory's first
    and the `~/Library` one second, on every platform and with no platform
    branch. That is the order tools/kanban_config.py's
    `installed_issue_review_dir` probes in, so a macOS host that installed
    under XDG and a Linux host that inherited a `~/Library` install each keep
    the installation they have.

    Deliberately not derived from KANBAN_ISSUE_REVIEW_INSTALL_DIR: an install
    made with --install-dir still has to be discoverable by a coordinator that
    never saw that option, so the record's own path is the one thing that
    cannot move. $XDG_DATA_HOME does move the first candidate, because that is
    what the variable means and what `_xdg_issue_review_dir` honors; it is read
    the same way, as "set and non-empty" rather than "absolute".

    Each literal is spelled whole rather than composed, for the reason
    tools/kanban_config.py gives for its own: both are `personal-path` tokens
    in docs/agent-workflow-contract.md §4 declaring this file, and that
    reconciliation matches a literal, not an expression. This bundle vendors a
    copy of kanban_config.py beside this module and still does not import it:
    the Codex bundle vendors per skill and has none beside its own copy of this
    coordinator, and one probe implemented two ways is the drift both bundles
    exist to avoid."""
    xdg_base = os.environ.get("XDG_DATA_HOME")
    if xdg_base:
        xdg_record = Path(xdg_base) / "kanban" / "issue-review" / "config.json"
    else:
        xdg_record = Path(f"{Path.home()}/.local/share/kanban/issue-review/config.json")
    return (
        xdg_record,
        Path(f"{Path.home()}/Library/Application Support/kanban/issue-review/config.json"),
    )


def installed_backend(path: Path, repair: str) -> Path:
    if not path.is_file():
        raise WorkflowError(f"Canonical issue reviewer was not found at {path}. {repair}")
    return path


def unreadable_record(record: Path, detail: str) -> WorkflowError:
    return WorkflowError(
        f"The canonical issue reviewer's install record at {record} is unreadable "
        f"({detail}). Rewrite it by running `python3 tools/install_issue_review.py` from "
        "the Kanban checkout, adding --install-dir if the backend lives elsewhere."
    )


def approver_path() -> Path:
    """Resolve Kanban's canonical issue-review backend with the same
    precedence `Kanban.Review.resolveCanonicalIssueReviewer` uses: a non-empty
    KANBAN_ISSUE_REVIEW_INSTALL_DIR, then the backend the installer recorded,
    then -- only when the record names none -- the directory the record itself
    lives in, which is where an install predating the record put it. A
    selected override or recorded backend that is missing fails there rather
    than falling through, so this gate never silently runs an installation the
    user did not choose. The record itself is looked for in the two locations
    `issue_review_record_candidates` names, probed in that one order on every
    platform. This coordinator never hard-codes the pre-migration
    compatibility launcher path; see docs/agent-workflow-contract.md §3."""
    override = os.environ.get("KANBAN_ISSUE_REVIEW_INSTALL_DIR")
    if override and override.strip():
        return installed_backend(
            Path(override).expanduser() / "approve_issues.py",
            f"KANBAN_ISSUE_REVIEW_INSTALL_DIR selected {override}; install it there with "
            f"`python3 tools/install_issue_review.py --install-dir {override}`, or unset "
            "that variable to use the recorded installation.",
        )
    candidates = issue_review_record_candidates()
    # Absence is decided by whether anything occupies the path, not by
    # whether something readable does: `os.path.lexists` sees a symbolic link
    # whose target is gone, which `read_text` reports as FileNotFoundError
    # and which falling back would treat as "never installed". The installer
    # refuses to write through a link here for the same reason. That is also
    # what stops an occupied-but-invalid higher-precedence candidate from
    # falling through to the lower-precedence one: a dangling link or a
    # directory where the XDG record belongs still selects that installation,
    # and the reader below then reports what is wrong with it.
    occupied = [candidate for candidate in candidates if os.path.lexists(candidate)]
    # Neither occupied is not a platform question. The XDG candidate answers
    # it on every host, and what the diagnostic names is both locations, so no
    # consumer of this coordinator has to decide which platform it is on.
    record = occupied[0] if occupied else candidates[0]
    consulted = (
        str(record)
        if occupied
        else " and ".join(str(candidate) for candidate in candidates)
    )
    if not occupied:
        document = {}
    else:
        try:
            document = json.loads(record.read_text(encoding="utf-8"))
        except OSError as error:
            raise unreadable_record(record, "it could not be read") from error
        except json.JSONDecodeError as error:
            raise unreadable_record(record, str(error)) from error
    if not isinstance(document, dict):
        raise unreadable_record(record, "it is not a JSON object")
    if "backend_path" not in document:
        # A well-formed document with no discovery field is an installation
        # made before the record existed -- the installer has always written
        # config.json for --config -- so it upgrades in place rather than
        # failing. Membership, not `.get(...) is None`: an explicit null is a
        # value this installer never writes, so it is a record corrupted into
        # naming nothing and must fail closed like any other unusable value.
        return installed_backend(
            record.parent / "approve_issues.py",
            f"No install directory is recorded at {consulted}, so this default was used. "
            "Run `python3 tools/install_issue_review.py` from the Kanban checkout to "
            "install and record it.",
        )
    recorded = document["backend_path"]
    if not isinstance(recorded, str) or not Path(recorded).is_absolute():
        raise unreadable_record(
            record, f"it does not name an absolute backend path: {recorded!r}"
        )
    return installed_backend(
        Path(recorded),
        f"The install record at {record} still names it, so the installation moved or was "
        "removed; re-run `python3 tools/install_issue_review.py` from the Kanban checkout "
        "with the --install-dir you want, which also refreshes that record.",
    )


def check_issue(root: Path, repo: str, number: int, config_path: str | None = None) -> dict[str, Any]:
    proc = run(
        [
            sys.executable,
            str(approver_path()),
            "--path",
            str(root),
            "--repo",
            repo,
            "--check",
            str(number),
            "--legacy-policy",
            "dual",
            "--json",
        ]
        + (["--config", config_path] if config_path else []),
        cwd=root,
        timeout=180,
        ok_codes=(0, 2),
    )
    value = load_json(proc.stdout, f"issue approval check for #{number}")
    if not isinstance(value, dict) or value.get("issue") != number or not isinstance(value.get("approved"), bool):
        raise WorkflowError(f"issue approval check for #{number} returned an unexpected response")
    if value["approved"] != (proc.returncode == 0):
        raise WorkflowError(f"issue approval check for #{number} returned inconsistent status")
    return value


def gate_key(
    repo: str,
    numbers: list[int],
    invalid: list[str],
    *,
    allow_no_issue: bool = False,
) -> str:
    values: list[Any] = [repo.lower(), numbers, sorted(invalid)]
    if allow_no_issue:
        values.append("allow-no-issue")
    payload = json.dumps(values, separators=(",", ":"))
    return hashlib.sha256(payload.encode()).hexdigest()[:16]


def gate_marker(
    repo: str,
    numbers: list[int],
    invalid: list[str],
    *,
    allow_no_issue: bool = False,
) -> str:
    issue_text = ",".join(map(str, numbers)) if numbers else "none"
    return (
        "<!-- pr-review-gate:v1 status=ISSUE_NOT_APPROVED "
        f"key={gate_key(repo, numbers, invalid, allow_no_issue=allow_no_issue)} "
        f"issues={issue_text} -->"
    )


def gate_approved(
    numbers: list[int],
    invalid: list[str],
    checks: list[dict[str, Any]],
    *,
    allow_no_issue: bool,
) -> bool:
    has_allowed_scope = bool(numbers) or allow_no_issue
    return (
        has_allowed_scope
        and len(checks) == len(numbers)
        and not invalid
        and all(item["approved"] for item in checks)
    )


def gate_status(
    root: Path,
    pr: dict[str, Any],
    repo: str,
    *,
    allow_no_issue: bool = False,
    config_path: str | None = None,
) -> dict[str, Any]:
    numbers, invalid = linked_issue_numbers(pr, repo)
    checks = [check_issue(root, repo, number, config_path) for number in numbers]
    approved = gate_approved(numbers, invalid, checks, allow_no_issue=allow_no_issue)
    return {
        "approved": approved,
        "allow_no_issue": allow_no_issue,
        "issues": numbers,
        "invalid_links": invalid,
        "checks": checks,
        "key": gate_key(repo, numbers, invalid, allow_no_issue=allow_no_issue),
    }


def viewer_login(root: Path) -> str:
    value = gh_json(root, ["api", "user"])
    login = value.get("login") if isinstance(value, dict) else None
    if not isinstance(login, str) or not login:
        raise WorkflowError("could not resolve authenticated GitHub user")
    return login


def pr_comments(root: Path, repo: str, number: int) -> list[dict[str, Any]]:
    return paginated_api(root, f"repos/{repo}/issues/{number}/comments?per_page=100")


def has_owned_gate_comment(comments: list[dict[str, Any]], login: str, body: str) -> str | None:
    for comment in reversed(comments):
        user = comment.get("user") or {}
        if str(user.get("login", "")).lower() != login.lower():
            continue
        if str(comment.get("body") or "").strip() == body.strip():
            url = comment.get("html_url")
            return str(url) if url else "existing"
    return None


def post_comment(root: Path, repo: str, number: int, body: str) -> str:
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", prefix="pr-review-", suffix=".md") as handle:
        handle.write(body)
        handle.flush()
        proc = run(["gh", "pr", "comment", str(number), "-R", repo, "--body-file", handle.name], cwd=root)
    return proc.stdout.strip()


def publish_gate_comment(
    root: Path,
    repo: str,
    pr: dict[str, Any],
    gate: dict[str, Any],
    *,
    allow_no_issue: bool,
    config_path: str | None = None,
) -> tuple[str, str]:
    marker = gate_marker(
        repo,
        gate["issues"],
        gate["invalid_links"],
        allow_no_issue=allow_no_issue,
    )
    body = f"{GATE_TEXT}\n\n{marker}\n"
    refreshed = pr_view(root, repo, pr["number"])
    refreshed_gate = gate_status(root, refreshed, repo, allow_no_issue=allow_no_issue, config_path=config_path)
    if refreshed_gate["key"] != gate["key"] or refreshed_gate["approved"]:
        raise WorkflowError("issue gate changed before publication; rerun the review")
    login = viewer_login(root)
    existing = has_owned_gate_comment(pr_comments(root, repo, pr["number"]), login, body)
    if existing:
        return "existing", existing
    refreshed = pr_view(root, repo, pr["number"])
    refreshed_gate = gate_status(root, refreshed, repo, allow_no_issue=allow_no_issue, config_path=config_path)
    if refreshed_gate["key"] != gate["key"] or refreshed_gate["approved"]:
        raise WorkflowError("issue gate changed before publication; rerun the review")
    url = post_comment(root, repo, pr["number"], body)
    return "posted", url


def issue_context(root: Path, repo: str, number: int) -> dict[str, Any]:
    issue = gh_json(
        root,
        ["issue", "view", str(number), "-R", repo, "--json", "number,title,body,state,url,author,labels"],
    )
    comments = paginated_api(root, f"repos/{repo}/issues/{number}/comments?per_page=100")
    return {"issue": issue, "comments": comments}


def collect_context(root: Path, repo: str, pr: dict[str, Any], issue_numbers: list[int]) -> dict[str, Any]:
    diff = run(["gh", "pr", "diff", str(pr["number"]), "-R", repo], cwd=root).stdout
    review_comments = paginated_api(root, f"repos/{repo}/pulls/{pr['number']}/comments?per_page=100")
    ordinary_comments = pr_comments(root, repo, pr["number"])
    issues = [issue_context(root, repo, number) for number in issue_numbers]
    return {
        "pull_request": pr,
        "linked_issues": issues,
        "prior_pr_comments": ordinary_comments,
        "inline_review_comments": review_comments,
        "diff": diff,
    }


def resolve_fetch_source(root: Path, remote_name: str, repo: str) -> str:
    """A git fetch source (a registered remote name, or a direct HTTPS URL)
    that actually points at repo. If the configured/default remote resolves
    to a different repository than the effective repo (e.g. --repo selected
    upstream/repo from a fork checkout whose remote still points at the
    fork), fetching by that remote's name would silently pull the wrong
    repository's ref; fetch directly from repo's URL instead."""
    proc = subprocess.run(
        ["git", "remote", "get-url", remote_name],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode == 0 and parse_repository_name(proc.stdout) == repo:
        return remote_name
    return f"https://github.com/{repo}.git"


def ensure_commit(root: Path, repo: str, number: int, head: str, remote_name: str = "origin") -> None:
    present = subprocess.run(
        ["git", "cat-file", "-e", f"{head}^{{commit}}"],
        cwd=root,
        capture_output=True,
        check=False,
    ).returncode == 0
    if not present:
        fetch_source = resolve_fetch_source(root, remote_name, repo)
        run(["git", "fetch", "--no-tags", fetch_source, f"pull/{number}/head"], cwd=root, timeout=600)
    run(["git", "cat-file", "-e", f"{head}^{{commit}}"], cwd=root)


def make_tree_read_only(path: Path) -> None:
    """Strip write permission from every entry under path, then path itself.
    The review prompt promises reviewers "a read-only extraction of the
    exact PR head"; without this, a reviewer whose sandbox/permission
    defaults are not restricted (invoke_codex/invoke_claude no longer pin
    them) could otherwise write into it."""
    for dirpath, dirnames, filenames in os.walk(path):
        for name in dirnames + filenames:
            entry = Path(dirpath) / name
            entry.chmod(entry.stat().st_mode & ~0o222)
    path.chmod(path.stat().st_mode & ~0o222)


def make_tree_writable(path: Path) -> None:
    """Inverse of make_tree_read_only, restoring owner write permission so a
    caller's own temp-directory cleanup (which needs write access on
    directories to unlink entries) does not depend on a particular Python
    version's shutil.rmtree gracefully recovering from PermissionError."""
    if not path.exists():
        return
    path.chmod(path.stat().st_mode | 0o200)
    for dirpath, dirnames, filenames in os.walk(path):
        for name in dirnames + filenames:
            entry = Path(dirpath) / name
            entry.chmod(entry.stat().st_mode | 0o200)


def extract_source(root: Path, repo: str, number: int, head: str, destination: Path, remote_name: str = "origin") -> None:
    ensure_commit(root, repo, number, head, remote_name)
    proc = subprocess.run(
        ["git", "archive", "--format=tar", head],
        cwd=root,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        raise WorkflowError(f"git archive failed: {proc.stderr.decode(errors='replace')[-2000:]}")
    with tarfile.open(fileobj=io.BytesIO(proc.stdout), mode="r:") as archive:
        archive.extractall(destination, filter="data")
    make_tree_read_only(destination)


def review_prompt(context: dict[str, Any], reviewer: Reviewer, rereview: bool) -> str:
    mode = "rereview" if rereview else "review"
    return f"""Independently {mode} the pull request represented below as {reviewer.display_name}.

The current working directory is a read-only extraction of the exact PR head. Inspect relevant source and tests there. The JSON payload is authoritative for any linked approved issue specifications, the full patch, commits, prior reviews/comments, and CI. When linked_issues is empty, evaluate the PR directly from its title, body, patch, repository context, and tests. For a rereview, explicitly verify prior blocking concerns as well as finding regressions or new blockers.

Review only. Do not edit files, access GitHub, publish, label, commit, push, or merge. Evaluate correctness, regressions, missing required tests, scope, and satisfaction of the effective review contract. Use CHANGES_REQUESTED only for concrete human-action blockers; do not block on optional style preferences. Use APPROVE only when there are no blocking concerns.

Return only the requested structured result. The summary must contain non-whitespace text and be no more than {MAX_REVIEW_SUMMARY_CHARS} characters. Include no more than {MAX_REVIEW_BLOCKING_CONCERNS} blockers. Each blocker must have an actionable repository-relative path, line (or an empty string if no single line applies), and a non-blank explanation no more than {MAX_REVIEW_BLOCKER_BODY_CHARS} characters long.

REVIEW_PAYLOAD:
{json.dumps(context, indent=2, sort_keys=True)}
"""


def self_review_prompt(context: dict[str, Any], reviewer: Reviewer, rereview: bool, number: int) -> str:
    # Used only when the calling agent IS the canonical reviewer Kanban
    # already spawned as (known-origin $pr-review/$pr-rereview): no nested
    # model call is spawned for this case, so unlike review_prompt above,
    # this session's own working directory is not a read-only extraction of
    # the PR head and it must fetch that itself if it needs more than the
    # diff already in REVIEW_PAYLOAD.
    mode = "rereview" if rereview else "review"
    return f"""Independently {mode} the pull request represented below as {reviewer.display_name}. You are that canonical reviewer already — Kanban selected and spawned you for this exact role, so this is your own review, not something to delegate to a nested subprocess call.

The JSON payload is authoritative for any linked approved issue specifications, the full patch (`diff`), commits, prior reviews/comments, and CI. Review from the diff directly; if you need broader repository context than the patch shows, fetch the PR head read-only (e.g. `git fetch --no-tags origin pull/{number}/head` then inspect files with `git show FETCH_HEAD:<path>`) without checking it out over your own working directory or branch. When linked_issues is empty, evaluate the PR directly from its title, body, patch, repository context, and tests. For a rereview, explicitly verify prior blocking concerns as well as finding regressions or new blockers.

Review only. Do not edit files, publish a comment or label yourself, commit, push, or merge — write your verdict to a file and hand it to the coordinator's `--publish-verdict` mode, which performs the actual publication safely. Evaluate correctness, regressions, missing required tests, scope, and satisfaction of the effective review contract. Use CHANGES_REQUESTED only for concrete human-action blockers; do not block on optional style preferences. Use APPROVE only when there are no blocking concerns.

Write a JSON file matching exactly this schema:
{json.dumps(REVIEW_SCHEMA, indent=2)}

The summary must contain non-whitespace text and be no more than {MAX_REVIEW_SUMMARY_CHARS} characters. Include no more than {MAX_REVIEW_BLOCKING_CONCERNS} blockers. Each blocker must have an actionable repository-relative path, line (or an empty string if no single line applies), and a non-blank explanation no more than {MAX_REVIEW_BLOCKER_BODY_CHARS} characters long.

REVIEW_PAYLOAD:
{json.dumps(context, indent=2, sort_keys=True)}
"""


def validate_review(value: Any, reviewer: Reviewer, model: str = UNVERIFIED_MODEL_TOKEN) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise WorkflowError(f"{reviewer.display_name} returned a non-object result")
    verdict = value.get("verdict")
    summary = value.get("summary")
    concerns = value.get("blocking_concerns")
    if verdict not in {"APPROVE", "CHANGES_REQUESTED"}:
        raise WorkflowError(f"{reviewer.display_name} returned an invalid verdict")
    if not isinstance(summary, str):
        raise WorkflowError(f"{reviewer.display_name} returned a non-string summary")
    if not summary.strip():
        raise WorkflowError(f"{reviewer.display_name} returned a blank summary")
    if len(summary) > MAX_REVIEW_SUMMARY_CHARS:
        raise WorkflowError(
            f"{reviewer.display_name} returned a {len(summary)}-character summary; "
            f"the limit is {MAX_REVIEW_SUMMARY_CHARS}"
        )
    if not isinstance(concerns, list):
        raise WorkflowError(f"{reviewer.display_name} returned non-list blocking concerns")
    if len(concerns) > MAX_REVIEW_BLOCKING_CONCERNS:
        raise WorkflowError(
            f"{reviewer.display_name} returned {len(concerns)} blocking concerns; "
            f"the limit is {MAX_REVIEW_BLOCKING_CONCERNS}"
        )
    for concern in concerns:
        if not isinstance(concern, dict) or set(concern) != {"path", "line", "body"}:
            raise WorkflowError(f"{reviewer.display_name} returned a malformed blocker")
        if not all(isinstance(concern[key], str) for key in ("path", "line", "body")):
            raise WorkflowError(f"{reviewer.display_name} returned a malformed blocker")
        if not concern["body"].strip():
            raise WorkflowError(f"{reviewer.display_name} returned a blank blocker body")
        if len(concern["body"]) > MAX_REVIEW_BLOCKER_BODY_CHARS:
            raise WorkflowError(
                f"{reviewer.display_name} returned a {len(concern['body'])}-character "
                f"blocker body; the limit is {MAX_REVIEW_BLOCKER_BODY_CHARS}"
            )
    if verdict == "APPROVE" and concerns:
        raise WorkflowError(f"{reviewer.display_name} approved with blocking concerns")
    if verdict == "CHANGES_REQUESTED" and not concerns:
        raise WorkflowError(f"{reviewer.display_name} requested changes without a blocker")
    return {
        "reviewer": reviewer.key,
        "display_name": reviewer.display_name,
        "verdict": verdict,
        "summary": summary.strip(),
        "blocking_concerns": concerns,
        "model": model,
    }


def invoke_codex(reviewer: Reviewer, prompt: str, cwd: Path) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="pr-review-codex-") as temp:
        schema_path = Path(temp) / "schema.json"
        output_path = Path(temp) / "result.json"
        schema_path.write_text(json.dumps(REVIEW_SCHEMA), encoding="utf-8")
        # -m/-c model_reasoning_effort pin the canonical nested-reviewer
        # model (see nested_review_assignment above); no
        # -s/--dangerously-bypass-approvals-and-sandbox: sandbox/approval
        # policy is still left to this installation's own default. `codex
        # exec` without -s/-a runs a read-only inspection task to
        # completion under its own non-interactive defaults.
        model_assignment = nested_review_assignment("codex")
        run(
            [
                "codex",
                "exec",
                "--ephemeral",
                "--skip-git-repo-check",
                "-C",
                str(cwd),
                "--model",
                model_assignment.model,
                "--config",
                f'model_reasoning_effort="{model_assignment.effort}"',
                "--output-schema",
                str(schema_path),
                "-o",
                str(output_path),
                "--color",
                "never",
                "-",
            ],
            cwd=cwd,
            input_text=prompt,
            timeout=REVIEW_TIMEOUT_SECONDS,
        )
        try:
            value = json.loads(output_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise WorkflowError(f"{reviewer.display_name} did not return structured JSON") from exc
    return validate_review(
        value, reviewer, f"{model_assignment.model}@{model_assignment.effort}"
    )


def parse_claude_output(stdout: str) -> Any:
    outer = load_json(stdout, "Claude reviewer")
    if isinstance(outer, dict) and outer.get("is_error"):
        raise WorkflowError(f"Claude reviewer failed: {outer.get('result')}")
    value = outer.get("structured_output") if isinstance(outer, dict) else None
    if value is not None:
        return value
    value = outer.get("result") if isinstance(outer, dict) else outer
    if isinstance(value, str):
        return load_json(value, "Claude structured result")
    return value


def invoke_claude(reviewer: Reviewer, prompt: str, cwd: Path) -> dict[str, Any]:
    # --model/--effort pin the canonical nested-reviewer model (see
    # nested_review_assignment above); no --permission-mode/--tools:
    # permission policy is still left to this installation's own default.
    # `claude -p` without --permission-mode runs a read-only inspection
    # task to completion under its own non-interactive defaults.
    model_assignment = nested_review_assignment("claude")
    proc = run(
        [
            "claude",
            "-p",
            "--model",
            model_assignment.model,
            "--effort",
            model_assignment.effort,
            "--no-session-persistence",
            "--output-format",
            "json",
            "--json-schema",
            json.dumps(REVIEW_SCHEMA, separators=(",", ":")),
        ],
        cwd=cwd,
        input_text=prompt,
        timeout=REVIEW_TIMEOUT_SECONDS,
    )
    return validate_review(
        parse_claude_output(proc.stdout),
        reviewer,
        f"{model_assignment.model}@{model_assignment.effort}",
    )


def invoke_reviewer(reviewer: Reviewer, prompt: str, cwd: Path) -> dict[str, Any]:
    if reviewer.key == "codex":
        return invoke_codex(reviewer, prompt, cwd)
    return invoke_claude(reviewer, prompt, cwd)


def run_reviews(
    reviewers: list[Reviewer],
    context: dict[str, Any],
    extract: Callable[[], Path],
    rereview: bool,
) -> list[dict[str, Any]]:
    # Reviewers run strictly one at a time, each with a freshly extracted
    # source that is torn down before the next reviewer's extraction
    # begins: invoke_codex/invoke_claude no longer restrict a nested
    # reviewer's own sandbox/tool access, so concurrent dual review — even
    # with each reviewer in its own directory — would leave two same-user
    # source trees on disk simultaneously, one of which an unrestricted
    # reviewer could enumerate and tamper with via its predictable prefix.
    # Serial execution means at most one reviewer's source ever exists.
    prompts = {item.key: review_prompt(context, item, rereview) for item in reviewers}
    results: dict[str, dict[str, Any]] = {}
    for item in reviewers:
        source = extract()
        try:
            results[item.key] = invoke_reviewer(item, prompts[item.key], source)
        except Exception as exc:
            raise WorkflowError(f"{item.display_name} review failed: {exc}") from exc
        finally:
            make_tree_writable(source)
            shutil.rmtree(source, ignore_errors=True)
    return [results[item.key] for item in reviewers]


def aggregate_verdict(results: list[dict[str, Any]]) -> str:
    return "CHANGES_REQUESTED" if any(item["verdict"] == "CHANGES_REQUESTED" for item in results) else "APPROVE"


def review_marker(reviewers: list[Reviewer], models: list[str], head: str, verdict: str) -> str:
    reviewer_keys = ",".join(item.key for item in reviewers)
    models_field = ",".join(models)
    return (
        f"<!-- pr-review:v2 reviewers={reviewer_keys} models={models_field} "
        f"head={head} verdict={verdict} -->"
    )


def result_models(results: list[dict[str, Any]]) -> list[str]:
    return [result.get("model", UNVERIFIED_MODEL_TOKEN) for result in results]


def render_review(results: list[dict[str, Any]], reviewers: list[Reviewer], head: str) -> tuple[str, str]:
    verdict = aggregate_verdict(results)
    lines = [verdict, ""]
    for result in results:
        lines.extend([f"### {result['display_name']}", "", result["summary"], ""])
        for concern in result["blocking_concerns"]:
            location = concern["path"]
            if concern["line"]:
                location += f":{concern['line']}"
            label = f"`{location}`" if location else "General"
            lines.append(f"- {label}: {concern['body'].strip()}")
        if result["blocking_concerns"]:
            lines.append("")
    lines.append(review_marker(reviewers, result_models(results), head, verdict))
    body = "\n".join(lines).rstrip() + "\n"
    if len(body.encode()) > 60000:
        raise WorkflowError("consolidated review comment is too large to publish safely")
    return verdict, body


def require_current_review_state(
    root: Path,
    repo: str,
    number: int,
    expected_head: str,
    expected_gate_key: str,
    *,
    allow_no_issue: bool,
    config_path: str | None = None,
) -> dict[str, Any]:
    pr = pr_view(root, repo, number)
    if pr["headRefOid"] != expected_head:
        raise WorkflowError("PR head changed; no current-head verdict may be labeled")
    gate = gate_status(root, pr, repo, allow_no_issue=allow_no_issue, config_path=config_path)
    if gate["key"] != expected_gate_key:
        raise WorkflowError("linked issues changed; no verdict was published")
    if not gate["approved"]:
        raise WorkflowError("issue approval became stale; no current verdict may be labeled")
    return gate


def set_verdict_label(
    root: Path, repo: str, number: int, verdict: str, approval_label: str, changes_requested_label: str
) -> None:
    add = approval_label if verdict == "APPROVE" else changes_requested_label
    remove = changes_requested_label if verdict == "APPROVE" else approval_label
    run(["gh", "pr", "edit", str(number), "-R", repo, "--add-label", add, "--remove-label", remove], cwd=root)


def clear_verdict_labels(
    root: Path, repo: str, number: int, approval_label: str, changes_requested_label: str
) -> None:
    run(
        [
            "gh",
            "pr",
            "edit",
            str(number),
            "-R",
            repo,
            "--remove-label",
            approval_label,
            "--remove-label",
            changes_requested_label,
        ],
        cwd=root,
    )


def mark_ready_for_review(root: Path, repo: str, number: int) -> None:
    run(["gh", "pr", "ready", str(number), "-R", repo], cwd=root)


def restore_draft(root: Path, repo: str, number: int) -> None:
    # No publication path calls this: publish_results' failure handler below
    # records why a ready transition is never rolled back. It remains the
    # coordinator's draft-restoring command surface, and the draft-transition
    # suite asserts against it that no failure path invokes it.
    run(["gh", "pr", "ready", str(number), "-R", repo, "--undo"], cwd=root)


def latest_owned_review_marker(
    comments: list[dict[str, Any]], login: str
) -> tuple[re.Match[str], str] | None:
    for comment in reversed(comments):
        user = comment.get("user") or {}
        if str(user.get("login", "")).lower() != login.lower():
            continue
        matches = list(REVIEW_MARKER_RE.finditer(str(comment.get("body") or "")))
        if matches:
            return matches[-1], str(comment.get("html_url") or "")
    return None


def verify_publication(
    root: Path,
    repo: str,
    number: int,
    reviewers: list[Reviewer],
    models: list[str],
    head: str,
    verdict: str,
    gate_key_value: str,
    approval_label: str,
    changes_requested_label: str,
    *,
    allow_no_issue: bool,
    config_path: str | None = None,
) -> dict[str, Any]:
    pr = pr_view(root, repo, number)
    if pr["headRefOid"] != head:
        raise WorkflowError("PR head changed after publication")
    labels = [item.get("name") for item in pr.get("labels") or [] if isinstance(item, dict)]
    expected = approval_label if verdict == "APPROVE" else changes_requested_label
    verdict_labels = [item for item in labels if item in {approval_label, changes_requested_label}]
    if verdict_labels != [expected]:
        raise WorkflowError(f"publication label verification failed: {verdict_labels}")
    gate = gate_status(root, pr, repo, allow_no_issue=allow_no_issue, config_path=config_path)
    if gate["key"] != gate_key_value or not gate["approved"]:
        raise WorkflowError("publication issue-gate verification failed")
    login = viewer_login(root)
    latest = latest_owned_review_marker(pr_comments(root, repo, number), login)
    if latest is None:
        raise WorkflowError("published review marker was not found")
    marker, url = latest
    expected_models = ",".join(models)
    expected_reviewers = ",".join(item.key for item in reviewers)
    if (
        marker.group("head") != head
        or marker.group("verdict") != verdict
        or marker.group("models") != expected_models
        or marker.group("reviewers") != expected_reviewers
    ):
        raise WorkflowError("newest review marker does not match the published verdict")
    return {
        "comment_url": url,
        "labels": verdict_labels,
        "ready_for_review": not bool(pr.get("isDraft")),
    }


def require_prior_review(root: Path, repo: str, number: int) -> None:
    login = viewer_login(root)
    comments = pr_comments(root, repo, number)
    has_v2 = latest_owned_review_marker(comments, login) is not None
    has_v1 = any(
        str((item.get("user") or {}).get("login", "")).lower() == login.lower()
        and "<!-- pr-review:v1 " in str(item.get("body") or "")
        for item in comments
    )
    if not (has_v2 or has_v1):
        raise WorkflowError(f"PR #{number} has no prior canonical review to rereview")


def publish_results(
    root: Path,
    repo: str,
    number: int,
    pr: dict[str, Any],
    gate: dict[str, Any],
    reviewers: list[Reviewer],
    results: list[dict[str, Any]],
    base: dict[str, Any],
    *,
    allow_no_issue: bool,
    config_path: str | None = None,
) -> tuple[int, dict[str, Any]]:
    """Safely publish an already-computed set of review results: re-verify
    nothing went stale since `gate`/`pr` were captured, post the
    consolidated comment, then label. An approved draft is also marked ready
    for review, which is what moves it into Kanban's Done column even while CI
    is pending. If anything changes during publication, clear both verdict
    labels and leave draft state exactly as it stands: nothing readable
    separates a ready transition this call made from one another actor made,
    so it is never rolled back. Shared by workflow()'s own nested-reviewer
    path and publish_verdict()'s self-reviewed path, so both go through
    identical race handling."""
    approval_label, changes_requested_label = resolve_workflow_labels(config_path, repo)
    refreshed_pr = pr_view(root, repo, number)
    refreshed_gate = gate_status(root, refreshed_pr, repo, allow_no_issue=allow_no_issue, config_path=config_path)
    if refreshed_pr["headRefOid"] != pr["headRefOid"]:
        raise WorkflowError("PR head changed during review; no verdict was published")
    if refreshed_gate["key"] != gate["key"]:
        raise WorkflowError("linked issues changed during review; no verdict was published")
    if not refreshed_gate["approved"]:
        status, url = publish_gate_comment(
            root,
            repo,
            refreshed_pr,
            refreshed_gate,
            allow_no_issue=allow_no_issue,
            config_path=config_path,
        )
        return 2, {
            **base,
            "issue_gate": refreshed_gate,
            "status": "blocked",
            "comment_status": status,
            "comment_url": url,
        }

    verdict, body = render_review(results, reviewers, pr["headRefOid"])
    require_current_review_state(
        root,
        repo,
        number,
        pr["headRefOid"],
        gate["key"],
        allow_no_issue=allow_no_issue,
        config_path=config_path,
    )
    post_comment(root, repo, number, body)
    try:
        require_current_review_state(
            root,
            repo,
            number,
            pr["headRefOid"],
            gate["key"],
            allow_no_issue=allow_no_issue,
            config_path=config_path,
        )
        set_verdict_label(root, repo, number, verdict, approval_label, changes_requested_label)
        verified = verify_publication(
            root,
            repo,
            number,
            reviewers,
            result_models(results),
            pr["headRefOid"],
            verdict,
            gate["key"],
            approval_label,
            changes_requested_label,
            allow_no_issue=allow_no_issue,
            config_path=config_path,
        )
        if verdict == "APPROVE" and not verified["ready_for_review"]:
            mark_ready_for_review(root, repo, number)
            verified = verify_publication(
                root,
                repo,
                number,
                reviewers,
                result_models(results),
                pr["headRefOid"],
                verdict,
                gate["key"],
                approval_label,
                changes_requested_label,
                allow_no_issue=allow_no_issue,
                config_path=config_path,
            )
            if not verified["ready_for_review"]:
                raise WorkflowError("approved PR remained a draft after marking it ready for review")
    except WorkflowError as exc:
        cleanup_errors: list[str] = []
        try:
            clear_verdict_labels(root, repo, number, approval_label, changes_requested_label)
        except WorkflowError as cleanup_exc:
            cleanup_errors.append(f"verdict-label cleanup failed ({cleanup_exc})")
        # Publication never returns the PR to draft. Doing so would need
        # positive evidence that this invocation created the ready
        # transition, and the coordinator has none to read. The ready
        # command's own draft check and its mutation are not atomic, so a
        # normal return -- warning that the PR was already ready, or silent --
        # is equally consistent with another actor having won the race, and
        # both actors go through the same credentials. A post-failure isDraft
        # read is that same inference by a different door, and is likewise
        # absent. Accepted residual, in exchange: when the transition really
        # was this invocation's, the PR is left ready for review with both
        # verdict labels cleared -- which the board classifies Reviewing and
        # the drainer, merging only approval-labelled PRs, leaves alone. Do
        # not reintroduce a rollback to "fix" that; it cannot tell the two
        # cases apart, so it can only undo a transition that was never ours.
        if cleanup_errors:
            raise WorkflowError(
                f"publication failed ({exc}); {'; '.join(cleanup_errors)}"
            ) from exc
        raise WorkflowError(
            f"publication failed ({exc}); both verdict labels were cleared"
        ) from exc
    return 0, {
        **base,
        "status": "reviewed",
        "verdict": verdict,
        "review_results": results,
        "comment_status": "posted",
        **verified,
    }


def workflow(
    root: Path,
    number: int,
    *,
    rereview: bool,
    dry_run: bool,
    allow_no_issue: bool,
    self_review: bool = False,
    self_review_as: str | None = None,
    config_path: str | None = None,
    explicit_repo: str | None = None,
) -> tuple[int, dict[str, Any]]:
    # The mode question first, ahead of every GitHub read: an installation that
    # loads no provider cannot review this pull request whatever it says, and
    # refusing here is what makes "publishes nothing, changes no label"
    # structural rather than a promise about later branches.
    mode, loaded = operating_mode()
    if mode == kanban_models().NO_AGENT_MODE:
        return no_agent_refusal(number)
    repo = resolve_repository(root, config_path, explicit_repo)
    pr = pr_view(root, repo, number)
    gate = gate_status(root, pr, repo, allow_no_issue=allow_no_issue, config_path=config_path)
    origin = pr_origin(pr)
    reviewers = route_reviewers(origin, mode=mode, loaded=loaded)
    base = {
        "pr": number,
        "url": pr["url"],
        "head": pr["headRefOid"],
        "origin": origin or "unknown",
        "route": "+".join(item.key for item in reviewers),
        "review_mode": "standalone" if allow_no_issue else "issue-gated",
        "issue_gate": gate,
    }
    if self_review and len(reviewers) == 1:
        # The self-review path below hands the review to the calling session
        # to perform itself, which is correct only when that session IS the
        # brand this route names. This coordinator cannot observe who invoked
        # it, so the caller declares its own brand and the declaration is
        # checked HERE: ahead of the blocked-gate comment, the dry-run
        # response, collect_context, and every reviewer spawn, so a refusal
        # publishes nothing, collects nothing, and switches no label.
        #
        # An absent declaration is refused exactly like a mismatched one. The
        # session this guard exists to stop -- a solver running /pr-review on
        # the pull request it just opened -- is precisely the one that would
        # otherwise inherit the old unchecked default and self-review its own
        # work under the opposite brand's name (issue #303).
        #
        # An unknown or external origin routes to both brands, where
        # --self-review stays non-operative as it always has: one session
        # cannot review as both, so it falls through to the nested dual spawn
        # rather than being refused here.
        reviewer = reviewers[0]
        if self_review_as != reviewer.key:
            problem = (
                "--self-review requires --self-review-as <brand> declaring the calling "
                "session's own brand"
                if self_review_as is None
                else f"--self-review-as {self_review_as} is not the {reviewer.key} reviewer "
                "this pull request routes to"
            )
            # The remedy has to describe the reviewer this route actually
            # names. In single-agent mode omitting the flag spawns the SAME
            # brand -- that is the whole point of a one-provider roster -- so
            # the dual-mode wording would be telling the caller something this
            # installation cannot do. The refusal itself is unchanged either
            # way: a mismatched or absent declaration is still refused, which
            # is what stops a solver self-reviewing under another brand's name.
            if mode == kanban_models().SINGLE_AGENT_MODE:
                remedy = (
                    f"This installation loads only {reviewer.key}, so every pull "
                    f"request routes to it whatever its origin; omit --self-review "
                    f"so this coordinator spawns the {reviewer.key} reviewer, or "
                    f"pass --self-review-as {reviewer.key} if this session is that "
                    "reviewer."
                )
            else:
                remedy = (
                    f"A pr-origin:{origin} pull request is reviewed by "
                    f"{reviewer.key}; omit --self-review so this coordinator spawns "
                    f"the {reviewer.key} reviewer instead of publishing a same-brand "
                    "review."
                )
            return 1, {
                **base,
                "status": "self_review_refused",
                "error": f"{problem}. {remedy}",
            }
    if not gate["approved"]:
        if dry_run:
            return 2, {**base, "status": "blocked", "comment_status": "dry-run"}
        status, url = publish_gate_comment(
            root,
            repo,
            pr,
            gate,
            allow_no_issue=allow_no_issue,
            config_path=config_path,
        )
        return 2, {**base, "status": "blocked", "comment_status": status, "comment_url": url}
    if rereview:
        require_prior_review(root, repo, number)
    if dry_run:
        return 0, {**base, "status": "ready", "comment_status": "dry-run"}

    context = collect_context(root, repo, pr, gate["issues"])

    if self_review and len(reviewers) == 1:
        # Known-origin $pr-review/$pr-rereview: the calling agent IS the
        # canonical reviewer Kanban already spawned as (it pinned that
        # session's model at the CLI before this script ever ran), so
        # spawning a further nested, unpinned reviewer here would both
        # waste that guarantee and be unable to verify it published under
        # the right identity. Return the review context for the caller to
        # review with directly; it re-invokes this coordinator's
        # --publish-verdict mode with the result. (Dual/unknown-origin
        # review still needs a nested opposite-brand spawn
        # below — a single calling session cannot self-review as both
        # brands — and Kanban's own invocation never routes there anyway.)
        reviewer = reviewers[0]
        return 0, {
            **base,
            "status": "awaiting_self_review",
            "reviewer_key": reviewer.key,
            "expected_head": pr["headRefOid"],
            "gate_key": gate["key"],
            "instructions": self_review_prompt(context, reviewer, rereview, number),
        }

    remote_name = resolve_remote_name(config_path)

    def extract_for_next_reviewer() -> Path:
        # An independently-rooted temp directory with no reviewer-identifying
        # prefix (tempfile.mkdtemp, not a subdirectory of one shared parent
        # and not named after the reviewer brand). run_reviews extracts,
        # reviews, and tears this down before starting the next reviewer, so
        # at most one such directory ever exists on disk at a time.
        source = Path(tempfile.mkdtemp(prefix=f"pr-{number}-review-source-"))
        extract_source(root, repo, number, pr["headRefOid"], source, remote_name)
        return source

    results = run_reviews(reviewers, context, extract_for_next_reviewer, rereview)
    return publish_results(
        root, repo, number, pr, gate, reviewers, results, base,
        allow_no_issue=allow_no_issue, config_path=config_path,
    )


def publish_verdict(
    root: Path,
    number: int,
    expected_head: str,
    expected_gate_key: str,
    result_path: Path,
    *,
    allow_no_issue: bool,
    config_path: str | None = None,
    explicit_repo: str | None = None,
) -> tuple[int, dict[str, Any]]:
    """Publish a verdict the calling agent already computed itself (the
    self-review path from workflow()'s awaiting_self_review response).
    Re-verifies the PR is still exactly the state that context was
    generated from before accepting it — this is not a rubber stamp of
    whatever the caller provides, it is the same safe-publish machinery
    the nested-reviewer path uses, just fed an externally-supplied result
    instead of one from a spawned subprocess."""
    mode, loaded = operating_mode()
    if mode == kanban_models().NO_AGENT_MODE:
        return no_agent_refusal(number)
    repo = resolve_repository(root, config_path, explicit_repo)
    pr = pr_view(root, repo, number)
    if pr["headRefOid"] != expected_head:
        raise WorkflowError(
            "PR head changed since the self-review context was generated; "
            "rerun $pr-review/$pr-rereview to get a fresh context before publishing"
        )
    gate = gate_status(root, pr, repo, allow_no_issue=allow_no_issue, config_path=config_path)
    if gate["key"] != expected_gate_key:
        raise WorkflowError(
            "linked issues changed since the self-review context was generated; "
            "rerun $pr-review/$pr-rereview to get a fresh context before publishing"
        )
    origin = pr_origin(pr)
    reviewers = route_reviewers(origin, mode=mode, loaded=loaded)
    if len(reviewers) != 1:
        raise WorkflowError(
            "PR origin is no longer a single known brand; rerun $pr-review/$pr-rereview "
            "instead of publishing a self-review verdict"
        )
    base = {
        "pr": number,
        "url": pr["url"],
        "head": pr["headRefOid"],
        "origin": origin or "unknown",
        "route": "+".join(item.key for item in reviewers),
        "review_mode": "standalone" if allow_no_issue else "issue-gated",
        "issue_gate": gate,
    }
    if not gate["approved"]:
        status, url = publish_gate_comment(
            root, repo, pr, gate, allow_no_issue=allow_no_issue, config_path=config_path,
        )
        return 2, {**base, "status": "blocked", "comment_status": status, "comment_url": url}
    result_data = load_json(Path(result_path).read_text(encoding="utf-8"), "self-review result file")
    result = validate_review(result_data, reviewers[0])
    return publish_results(
        root, repo, number, pr, gate, reviewers, [result], base,
        allow_no_issue=allow_no_issue, config_path=config_path,
    )


def self_test() -> None:
    assert CODEX_REVIEWER.key == "codex"
    assert CODEX_REVIEWER.display_name == "Codex"
    assert CLAUDE_REVIEWER.key == "claude"
    assert CLAUDE_REVIEWER.display_name == "Claude"
    assert origin_from_body("body\n\n<!-- pr-origin:claude -->") == "claude"
    assert origin_from_body("body\n\n<!-- pr-origin:codex -->") == "codex"
    assert origin_from_body("external contribution") is None
    assert origin_from_body("<!-- pr-origin:codex -->\ntext") is None
    assert origin_from_body("<!-- pr-origin:codex -->\n<!-- pr-origin:codex -->") is None
    assert origin_from_body("<!-- pr-origin:unknown -->") is None
    # Routing is asked of all three modes explicitly rather than of this
    # host's own, so --self-test answers the same questions on a dual, a
    # single-agent and a no-agent installation alike.
    dual = {"mode": "dual", "loaded": ("codex", "claude")}
    assert [item.key for item in route_reviewers(None, **dual)] == ["codex", "claude"]
    assert [item.key for item in route_reviewers("claude", **dual)] == ["codex"]
    assert [item.key for item in route_reviewers("codex", **dual)] == ["claude"]
    for brand in ("codex", "claude"):
        single = {"mode": "single-agent", "loaded": (brand,)}
        for origin in (None, "codex", "claude"):
            assert [item.key for item in route_reviewers(origin, **single)] == [brand]
    none_loaded = {"mode": "no-agent", "loaded": ()}
    for origin in (None, "codex", "claude"):
        assert route_reviewers(origin, **none_loaded) == []
    refusal_code, refusal = no_agent_refusal(7)
    assert refusal_code == 1 and refusal["status"] == NO_AGENT_STATUS
    assert "no-agent" in refusal["error"]
    assert pr_origin({"isCrossRepository": True, "body": "<!-- pr-origin:claude -->"}) is None
    assert pr_origin({"isCrossRepository": False, "body": "<!-- pr-origin:claude -->"}) == "claude"
    assert aggregate_verdict([{"verdict": "APPROVE"}, {"verdict": "APPROVE"}]) == "APPROVE"
    assert aggregate_verdict([{"verdict": "APPROVE"}, {"verdict": "CHANGES_REQUESTED"}]) == "CHANGES_REQUESTED"
    marker = gate_marker("Owner/Repo", [34], [])
    assert "status=ISSUE_NOT_APPROVED" in marker and "issues=34" in marker
    assert GATE_TEXT == "Issue has not been approved."
    gate_body = f"{GATE_TEXT}\n\n{marker}\n"
    owned = [{"user": {"login": "owner"}, "body": gate_body, "html_url": "url"}]
    assert has_owned_gate_comment(owned, "OWNER", gate_body) == "url"
    assert has_owned_gate_comment(owned, "owner", f"Different text\n\n{marker}") is None
    assert not gate_approved([], [], [], allow_no_issue=False)
    assert gate_approved([], [], [], allow_no_issue=True)
    assert not gate_approved([], ["external#1"], [], allow_no_issue=True)
    assert gate_approved([34], [], [{"approved": True}], allow_no_issue=True)
    assert not gate_approved([34], [], [], allow_no_issue=True)
    assert not gate_approved([34], [], [{"approved": False}], allow_no_issue=True)
    assert gate_key("coghex/kanban", [], []) == "acc8ca6f35ab53bb"
    assert gate_key("coghex/kanban", [], [], allow_no_issue=True) != gate_key(
        "coghex/kanban", [], []
    )
    review = review_marker(
        [CODEX_REVIEWER, CLAUDE_REVIEWER], [UNVERIFIED_MODEL_TOKEN, UNVERIFIED_MODEL_TOKEN], "a" * 40, "APPROVE"
    )
    match = REVIEW_MARKER_RE.fullmatch(review)
    assert match and match.group("reviewers") == "codex,claude"
    assert match.group("models") == f"{UNVERIFIED_MODEL_TOKEN},{UNVERIFIED_MODEL_TOKEN}"
    assert result_models([{"model": "x@y"}, {"verdict": "APPROVE"}]) == ["x@y", UNVERIFIED_MODEL_TOKEN]
    pinned = review_marker(
        [CODEX_REVIEWER],
        [f"{CODEX_NESTED_REVIEW_MODEL}@{CODEX_NESTED_REVIEW_EFFORT}"],
        "b" * 40,
        "CHANGES_REQUESTED",
    )
    pinned_match = REVIEW_MARKER_RE.fullmatch(pinned)
    assert pinned_match and pinned_match.group("models") == "gpt-5.6-terra@xhigh"
    print("self-test passed")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--path", type=Path, default=Path.cwd(), help="Repository checkout path")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--review", type=int, metavar="PR", help="Review one pull request")
    mode.add_argument("--rereview", type=int, metavar="PR", help="Rereview one changed pull request")
    mode.add_argument(
        "--publish-verdict",
        type=int,
        metavar="PR",
        help="Publish a verdict the calling agent already computed itself (see --self-review)",
    )
    parser.add_argument("--dry-run", action="store_true", help="Check gate and route without writes or model calls")
    parser.add_argument(
        "--self-review",
        action="store_true",
        help=(
            "For a single known-brand reviewer, return review context for the calling agent to "
            "review with directly instead of spawning a nested, unpinned reviewer. Use only when "
            "this session is itself the canonical reviewer Kanban already spawned as, and declare "
            "that with --self-review-as; without a matching declaration the request is refused."
        ),
    )
    parser.add_argument(
        "--self-review-as",
        choices=("codex", "claude"),
        metavar="BRAND",
        help=(
            "The calling session's own brand, required by --self-review. This coordinator cannot "
            "observe who invoked it, so a single-reviewer route accepts --self-review only when "
            "this brand is the one that route names; anything else is refused unpublished."
        ),
    )
    parser.add_argument(
        "--expected-head", metavar="SHA", help="With --publish-verdict: the head SHA the review was performed against"
    )
    parser.add_argument(
        "--gate-key", metavar="KEY", help="With --publish-verdict: the gate_key from the awaiting_self_review response"
    )
    parser.add_argument(
        "--result", type=Path, metavar="FILE", help="With --publish-verdict: path to the verdict JSON file"
    )
    parser.add_argument(
        "--allow-no-issue",
        action="store_true",
        help="Allow a PR with no linked issue; linked issues still require canonical approval",
    )
    parser.add_argument("--json", action="store_true", help="Print structured output")
    parser.add_argument("--self-test", action="store_true", help="Run pure unit checks")
    parser.add_argument(
        "--config",
        metavar="FILE",
        help="Path to kanban's config.toml (default: ~/.config/kanban/config.toml)",
    )
    parser.add_argument(
        "--repo",
        metavar="OWNER/NAME",
        help=(
            "Explicit repository identity, overriding the one derived from "
            "the configured git remote (matches Kanban's own --repo option, "
            "so a fork checkout reviews the same repository the dashboard "
            "displays)."
        ),
    )
    args = parser.parse_args()
    if not args.self_test and args.review is None and args.rereview is None and args.publish_verdict is None:
        parser.error("one of --review, --rereview, --publish-verdict, or --self-test is required")
    if args.publish_verdict is not None and (args.expected_head is None or args.gate_key is None or args.result is None):
        parser.error("--publish-verdict requires --expected-head, --gate-key, and --result")
    number = args.review if args.review is not None else (args.rereview if args.rereview is not None else args.publish_verdict)
    if number is not None and number < 1:
        parser.error("PR number must be positive")
    return args


def main() -> None:
    args = parse_args()
    if args.self_test:
        self_test()
        return
    number = args.review if args.review is not None else (args.rereview if args.rereview is not None else args.publish_verdict)
    try:
        root = Path(
            run(["git", "rev-parse", "--show-toplevel"], cwd=args.path.resolve()).stdout.strip()
        ).resolve()
        if args.publish_verdict is not None:
            code, result = publish_verdict(
                root,
                number,
                args.expected_head,
                args.gate_key,
                args.result,
                allow_no_issue=args.allow_no_issue,
                config_path=args.config,
                explicit_repo=args.repo,
            )
        else:
            code, result = workflow(
                root,
                number,
                rereview=args.rereview is not None,
                dry_run=args.dry_run,
                allow_no_issue=args.allow_no_issue,
                self_review=args.self_review,
                self_review_as=args.self_review_as,
                config_path=args.config,
                explicit_repo=args.repo,
            )
    except WorkflowError as exc:
        result = {"pr": number, "status": "error", "error": str(exc)}
        code = 1
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print(result.get("status", "error"))
        if result.get("error"):
            print(result["error"], file=sys.stderr)
    raise SystemExit(code)


if __name__ == "__main__":
    main()
