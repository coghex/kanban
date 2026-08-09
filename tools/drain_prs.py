#!/usr/bin/env python3

from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any, NoReturn

if "--dry-run" in sys.argv[1:]:
    # A dry run must leave the filesystem byte-for-byte as it found it, and
    # the sibling imports below would otherwise write a __pycache__ directory
    # beside this script -- which, when the drainer drains its own checkout,
    # is inside the repository under test. Decided from argv because the
    # imports happen long before parse_args() could tell us.
    sys.dont_write_bytecode = True

import drain_prs_service
import kanban_config


APPROVE_LABEL = "reviewed:approve"
CHANGES_LABEL = "reviewed:changes"
DEFAULT_REQUIRED_CI_CHECK = "build-test"
DEFAULT_REQUIRED_REVIEW_CHECK = "review-approved"
CONFIG_FILENAME = ".drain-prs.json"
STALE_APPROVAL_CHECK = "dismiss-stale-approval"
DEFAULT_INTERVAL_SECONDS = 300
CI_RERUN_INTERVAL_SECONDS = 60
MAX_CI_RERUN_ATTEMPTS = 3
UPDATE_BRANCH_WAIT_SECONDS = 180
UPDATE_BRANCH_POLL_SECONDS = 3
MODEL_TIMEOUT_SECONDS = 60 * 60
STATE_VERSION = 4
FAILURES_BEFORE_BACKOFF = 2
CLEANUP_PASSES_BEFORE_INCIDENT = 3
# What an intentional stop gives the final post-merge cleanup pass. The service
# allows a stop `STOP_TIMEOUT_SECONDS` (20) to signal, let this process
# discharge what it can, and confirm the exit, and Kanban gives the whole
# controller invocation 30. Under half the inner budget leaves the rest for the
# in-flight command the floor below still allows, process teardown, and the
# controller's confirmation polling.
SHUTDOWN_CLEANUP_BUDGET_SECONDS = 8.0
# No obligation *starts* once the budget is spent, but one already in flight
# still needs a bound of its own. The floor is what keeps that bound usable:
# the restoration a timed-out fast-forward runs on its way out is a path back
# to a user's local changes, and handing it a zero-length timeout would fail it
# by construction.
SHUTDOWN_MIN_COMMAND_TIMEOUT_SECONDS = 1.0
MAX_BACKOFF_ATTEMPTS = 16
MAX_CONSECUTIVE_GLOBAL_FAILURES = 3
FINALIZE_MODEL = "gpt-5.6-terra"
FINALIZE_EFFORT = "medium"
NTFY_URL = os.environ.get("KANBAN_DRAINER_NTFY_URL")
PR_REVIEW_V1_RE = re.compile(
    r"<!--\s*pr-review:v1\s+reviewer=(claude|codex)\s+"
    r"head=([0-9a-fA-F]{40})\s+"
    r"verdict=(APPROVE|CHANGES_REQUESTED)\s*-->",
    re.IGNORECASE,
)
PR_REVIEW_V2_RE = re.compile(
    r"<!--\s*pr-review:v2\s+reviewers=(claude|codex)\s+"
    r"models=[^\s]+\s+head=([0-9a-fA-F]{40})\s+"
    r"verdict=(APPROVE|CHANGES_REQUESTED)\s*-->",
    re.IGNORECASE,
)
LEGACY_CODEX_REVIEW_RE = re.compile(
    r"<!--\s*codex-review\s+head=([0-9a-fA-F]{40})\s+"
    r"verdict=(APPROVE|CHANGES_REQUESTED)\s*-->",
    re.IGNORECASE,
)
LOG_DIR: Path | None = None
# Single-PR runs own stdout for their one JSON result, so the human log lines
# go to stderr instead. Never true for the polling service.
LOG_TO_STDERR = False
# When set, the `time.monotonic()` reading past which no command may still be
# running. Only the shutdown pass sets it, through command_deadline(): every
# other caller of run() is under the polling loop's own cadence and must keep
# waiting as long as it takes.
COMMAND_DEADLINE: float | None = None

SINGLE_PR_SCHEMA = "drain-prs-single-pr"
SINGLE_PR_SCHEMA_VERSION = 1
EXIT_MERGED = 0
EXIT_ERROR = 1
EXIT_NO_ACTION = 2
# Every reason a single-PR run can report. The vocabulary is the caller's
# contract: a value is added here rather than invented at a call site, and an
# existing one never changes meaning.
NO_ACTION_REASONS = frozenset(
    {
        "not_approved",
        "changes_requested",
        "checks_pending",
        "checks_failed",
        "merge_conflict",
        "behind_base",
        "mergeability_computing",
        "approved_head_changed",
        "not_eligible",
        "would_merge",
    }
)
ERROR_REASONS = frozenset(
    {
        "run_locked",
        "repository_precondition_failed",
        "post_merge_audit_failed",
        "post_merge_cleanup_failed",
        "operational_error",
    }
)

# What one candidate's turn did to the polling pass around it. The queue
# advances one candidate at a time in ascending pull-request order, so every
# turn has to say whether the pass may keep walking the queue.
PASS_ADVANCE_HOLD = "advance_hold"
PASS_ADVANCE_DONE = "advance_done"
PASS_BARRIER = "barrier"
PASS_SKIP = "skip"
PASS_FAILURE = "pass_failure"
# Every outcome process_pr() can record, classified exactly once. A reason
# missing from this table -- a new one, or one recorded by something other than
# the return it describes -- ends the pass rather than falling through to
# another pull request, because a pass that cannot name what just happened
# cannot know it is safe to mutate the next candidate.
PASS_OUTCOMES: dict[str, str] = {
    # Skips: nothing the drainer can do advances this candidate right now, and
    # none of them says anything about the pull requests behind it.
    "not_eligible": PASS_SKIP,
    "not_approved": PASS_SKIP,
    "changes_requested": PASS_SKIP,
    "merge_conflict": PASS_SKIP,
    "checks_failed": PASS_SKIP,
    # Only a fresh review clears this one, so holding the lane for it would
    # stall the queue on a pull request nothing the drainer does can help. It
    # can follow a `gh pr merge` that GitHub refused on --match-head-commit;
    # that attempt landed nothing, so it is not the pass's one merge.
    "approved_head_changed": PASS_SKIP,
    # Advances that keep the lane: the candidate now has work in flight on
    # GitHub, and the pass is over until it settles.
    "behind_base": PASS_ADVANCE_HOLD,
    # Barriers: this candidate is mid-flight and every later one waits. A
    # requested CI rerun reports checks_pending too, and wants the same thing.
    "checks_pending": PASS_BARRIER,
    "mergeability_computing": PASS_BARRIER,
    # Advances that end the lane: the candidate left the queue.
    "merged": PASS_ADVANCE_DONE,
    "would_merge": PASS_ADVANCE_DONE,
    "post_merge_cleanup_failed": PASS_ADVANCE_DONE,
}


class DrainError(RuntimeError):
    pass


class ModelUnavailableError(DrainError):
    pass


class PostMergeAuditError(DrainError):
    pass


class RunLockedError(DrainError):
    pass


@dataclass
class RepoContext:
    path: Path
    repo_slug: str
    repo_name: str
    default_branch: str
    remote_name: str = "origin"


@dataclass(frozen=True)
class GateConfig:
    required_ci_check: str | None
    required_review_check: str | None


def active_log_path() -> Path | None:
    if LOG_DIR is None:
        return None
    day = time.strftime("%Y-%m-%d")
    return LOG_DIR / f"{day}.log"


def append_log_line(line: str) -> None:
    log_path = active_log_path()
    if log_path is None:
        return
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(line)
        handle.write("\n")


def log(message: str) -> None:
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{stamp}] {message}"
    print(line, file=sys.stderr if LOG_TO_STDERR else sys.stdout, flush=True)
    append_log_line(line)


def notify_model_failure(
    ctx: RepoContext,
    number: int,
    action: str,
    error: BaseException,
    *,
    model: str = FINALIZE_MODEL,
    effort: str = FINALIZE_EFFORT,
) -> None:
    if os.environ.get("DRAIN_PRS_MANAGED") == "1":
        # The service runner sends the one failure notice after this process
        # exits. Avoid sending the same event twice.
        return
    if not NTFY_URL:
        log("ntfy delivery skipped; KANBAN_DRAINER_NTFY_URL is not configured")
        return
    message = (
        f"PR drainer stopped: selected model {model}@{effort} "
        f"failed during {action} for PR #{number}. No retry or fallback was attempted.\n"
        f"{error}\n"
        f"https://github.com/{ctx.repo_slug}/pull/{number}"
    )
    request = urllib.request.Request(
        NTFY_URL,
        data=message.encode("utf-8"),
        method="POST",
        headers={
            "Title": "PR drainer model unavailable",
            "Priority": "urgent",
            "Tags": "warning,robot_face",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=15):
            pass
    except (urllib.error.URLError, TimeoutError) as exc:
        log(f"ntfy delivery failed for PR #{number}: {exc}")


def fail(message: str) -> "NoReturn":
    print(message, file=sys.stderr, flush=True)
    try:
        append_log_line(message)
    except OSError:
        # Reporting a failure must never fail: an unwritable log directory is
        # often the very thing being reported.
        pass
    raise SystemExit(1)


@contextlib.contextmanager
def command_deadline(deadline: float) -> Iterator[None]:
    """Bound every command run inside the block by one `time.monotonic()` mark.

    A deadline rather than a per-command timeout because the caller's promise
    is about total elapsed time, not about any single command: an obligation
    that runs six commands must not get six times the budget. Restored on the
    way out so nothing outside the block inherits a bound it never asked for.
    """
    global COMMAND_DEADLINE
    previous = COMMAND_DEADLINE
    COMMAND_DEADLINE = deadline
    try:
        yield
    finally:
        COMMAND_DEADLINE = previous


def command_deadline_expired() -> bool:
    """Whether an active deadline has passed.

    False whenever none is set, so only a caller that asked to be bounded ever
    declines work for want of time.
    """
    return COMMAND_DEADLINE is not None and time.monotonic() >= COMMAND_DEADLINE


def effective_timeout(timeout: float | None) -> float | None:
    """The bound one command actually gets, narrowed by any active deadline.

    Never below SHUTDOWN_MIN_COMMAND_TIMEOUT_SECONDS even when the deadline is
    already spent: a command reached after it is one an in-flight obligation
    still has to run, and the overrun that floor allows is bounded by the few
    commands one obligation has left, while a zero-length timeout would fail
    them all -- including the ones that restore a user's local changes.
    """
    if COMMAND_DEADLINE is None:
        return timeout
    remaining = max(
        SHUTDOWN_MIN_COMMAND_TIMEOUT_SECONDS, COMMAND_DEADLINE - time.monotonic()
    )
    return remaining if timeout is None else min(timeout, remaining)


def run(
    args: list[str],
    *,
    cwd: Path,
    check: bool = True,
    capture_output: bool = True,
    input_text: str | None = None,
    timeout: float | None = None,
) -> subprocess.CompletedProcess[str]:
    timeout = effective_timeout(timeout)
    try:
        proc = subprocess.run(
            args,
            cwd=str(cwd),
            text=True,
            capture_output=capture_output,
            input=input_text,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        cmd = " ".join(args)
        raise DrainError(
            f"Command timed out after {timeout} seconds: {cmd}"
        ) from exc
    if check and proc.returncode != 0:
        cmd = " ".join(args)
        stderr = (proc.stderr or "").strip()
        stdout = (proc.stdout or "").strip()
        detail = stderr or stdout or f"exit code {proc.returncode}"
        raise DrainError(f"Command failed: {cmd}\n{detail}")
    return proc


def run_json(args: list[str], *, cwd: Path) -> Any:
    proc = run(args, cwd=cwd)
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise DrainError(
            f"Failed to parse JSON from {' '.join(args)}:\n{proc.stdout}"
        ) from exc


def repo_root(path: Path) -> Path:
    root = run(["git", "rev-parse", "--show-toplevel"], cwd=path).stdout.strip()
    return Path(root)


def git_dir(path: Path) -> Path:
    # Not path / ".git": for a linked worktree that's a gitdir *file*
    # (a pointer to .git/worktrees/<name>), not a directory, so mkdtemp()
    # under it would fail outright. This resolves the real one either way.
    proc = run(["git", "rev-parse", "--absolute-git-dir"], cwd=path, check=False)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or f"exit code {proc.returncode}").strip()
        raise DrainError(f"Could not resolve the git directory for {path}:\n{detail}")
    return Path((proc.stdout or "").strip())


def in_progress_operation(git_directory: Path) -> str | None:
    """Names the operation this checkout is stopped part-way through, if any.

    Reads the markers git itself writes into the git directory rather than
    asking whether `git status` is non-empty. Ordinary uncommitted work is no
    reason to refuse — `fast_forward_default_branch` sets it aside and
    restores it — but an unfinished operation blocks that fast-forward until
    a human resolves it, so every merge in the run would fail the same
    avoidable way.
    """
    if (git_directory / "rebase-merge").exists():
        return "rebase"
    if (git_directory / "rebase-apply").exists():
        # git shares this directory between `rebase --apply` and `am`, which
        # are finished and aborted by different commands, so the message must
        # not guess which one the user has to run.
        applying = git_directory / "rebase-apply" / "applying"
        return "am" if applying.exists() else "rebase"
    for marker, operation in (
        ("MERGE_HEAD", "merge"),
        ("CHERRY_PICK_HEAD", "cherry-pick"),
        ("REVERT_HEAD", "revert"),
        ("BISECT_LOG", "bisect"),
    ):
        if (git_directory / marker).exists():
            return operation
    return None


def require_no_operation_in_progress(root: Path) -> None:
    # Reading marker paths never refreshes the index's stat cache the way
    # `git status` does, so this leaves .git/index byte for byte as it found
    # it — in a dry run and a real one alike.
    operation = in_progress_operation(git_dir(root))
    if operation is not None:
        raise DrainError(
            f"Refusing to start PR drainer: a {operation} is in progress in {root}. "
            "Finish or abort it first."
        )


def parse_repo_slug(remote_url: str) -> str:
    try:
        return kanban_config.parse_repository_name(remote_url)
    except kanban_config.KanbanConfigError as exc:
        raise DrainError(f"Unsupported remote URL: {remote_url}") from exc


def get_repo_context(path: Path, remote_name: str = "origin") -> RepoContext:
    root = repo_root(path)
    # Ahead of the default-branch check below: a rebase or a bisect commonly
    # leaves a detached HEAD, so checking the branch first would report the
    # symptom instead of naming the operation the user has to finish.
    require_no_operation_in_progress(root)
    remote_url = run(["git", "remote", "get-url", remote_name], cwd=root).stdout.strip()
    repo_slug = parse_repo_slug(remote_url)
    repo_name = repo_slug.split("/", 1)[1]
    try:
        ref = run(
            ["git", "symbolic-ref", "--short", f"refs/remotes/{remote_name}/HEAD"],
            cwd=root,
        ).stdout.strip()
        default_branch = ref.split("/", 1)[1]
    except DrainError:
        data = run_json(
            ["gh", "repo", "view", repo_slug, "--json", "defaultBranchRef"],
            cwd=root,
        )
        default_branch = data["defaultBranchRef"]["name"]

    current_branch = run(
        ["git", "branch", "--show-current"],
        cwd=root,
    ).stdout.strip()
    if current_branch != default_branch:
        raise DrainError(
            f"Repo path {root} is on branch {current_branch!r}, "
            f"not default branch {default_branch!r}."
        )

    return RepoContext(
        path=root,
        repo_slug=repo_slug,
        repo_name=repo_name,
        default_branch=default_branch,
        remote_name=remote_name,
    )


def require_requested_identity(ctx: RepoContext, requested: str | None) -> None:
    """Refuse a caller whose repository is not the one this checkout is of.

    Kanban resolves the board's repository through its own configuration --
    `--repo OWNER/NAME` outright, or the remote a `--config` names -- and can
    therefore be showing a repository this checkout's remote does not name. A
    pull request number means nothing across that gap: #42 on the dashboard
    and #42 here would be different pull requests, and merging the second on
    the strength of the first is exactly what this refuses.

    So the two sides have to agree rather than accommodate each other, which
    is the same containment `drain_prs_service.py` applies to controlling a
    job. Nothing is checked when no identity is asserted, so an ordinary
    command line keeps working unchanged.
    """
    if requested is None:
        return
    try:
        wanted = kanban_config.normalize_github_repository(requested)
        actual = kanban_config.normalize_github_repository(ctx.repo_slug)
    except kanban_config.KanbanConfigError as exc:
        raise DrainError(str(exc)) from exc
    if wanted != actual:
        raise DrainError(
            f"--repo {requested} names {wanted}, but {ctx.path} is a checkout of "
            f"{actual}; refusing to act on another repository's pull requests. "
            "Point --path at a checkout of the repository you named, or restore "
            "remote_name in the shared Kanban configuration so both sides resolve "
            "the same one."
        )


def load_gate_config(ctx: RepoContext) -> GateConfig:
    path = ctx.path / CONFIG_FILENAME
    if not path.exists():
        return GateConfig(
            required_ci_check=DEFAULT_REQUIRED_CI_CHECK,
            required_review_check=DEFAULT_REQUIRED_REVIEW_CHECK,
        )
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise DrainError(f"Failed to read drainer config from {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise DrainError(f"Drainer config in {path} must be a JSON object.")

    allowed = {"required_ci_check", "required_review_check"}
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise DrainError(
            f"Unsupported drainer config key(s) in {path}: {', '.join(unknown)}"
        )

    def check_name(key: str, default: str) -> str | None:
        configured = value.get(key, default)
        if configured is None:
            return None
        if not isinstance(configured, str) or not configured.strip():
            raise DrainError(
                f"Drainer config {key!r} in {path} must be a non-empty string or null."
            )
        return configured.strip()

    return GateConfig(
        required_ci_check=check_name(
            "required_ci_check", DEFAULT_REQUIRED_CI_CHECK
        ),
        required_review_check=check_name(
            "required_review_check", DEFAULT_REQUIRED_REVIEW_CHECK
        ),
    )


def has_label(pr: dict[str, Any], label: str) -> bool:
    return any(item["name"] == label for item in pr.get("labels", []))


def get_open_approved_prs(
    ctx: RepoContext,
    *,
    dry_run: bool,
) -> list[dict[str, Any]]:
    prs = run_json(
        [
            "gh",
            "pr",
            "list",
            "--repo",
            ctx.repo_slug,
            "--state",
            "open",
            "--limit",
            "200",
            "--json",
            "number,labels,isDraft,headRefOid",
        ],
        cwd=ctx.path,
    )
    approved: list[dict[str, Any]] = []
    for pr in prs:
        labels = {item["name"] for item in pr.get("labels", [])}
        if APPROVE_LABEL not in labels or CHANGES_LABEL in labels:
            continue
        if pr.get("isDraft"):
            number = pr["number"]
            if dry_run:
                log(
                    f"PR #{number}: approved but still a draft; "
                    "would mark it ready for review"
                )
            else:
                log(
                    f"PR #{number}: approved but still a draft; "
                    "marking it ready for review"
                )
                run(
                    [
                        "gh",
                        "pr",
                        "ready",
                        str(number),
                        "--repo",
                        ctx.repo_slug,
                    ],
                    cwd=ctx.path,
                )
        approved.append(pr)
    return sorted(approved, key=lambda pr: pr["number"])


def drain_state_path(ctx: RepoContext) -> Path:
    return ctx.path / ".git" / "drain_prs_state.json"


def migrate_drain_state(state: Any, *, source: str) -> dict[str, Any]:
    # Every shape check below guards a field this module later indexes without
    # one. Valid JSON is not a valid drain state, and a file that decodes but
    # is structurally wrong must be reported as one rather than escaping as an
    # AttributeError or KeyError from wherever it is first touched.
    if not isinstance(state, dict) or not isinstance(state.get("prs"), dict):
        raise DrainError(f"Unsupported drain state in {source}; inspect or remove it.")
    version = state.get("version")
    if version == 1:
        state["attempt_counter"] = 0
        version = 2
    if version == 2:
        # Version 2 recorded no post-merge cleanup obligations, so an entry it
        # left behind can be a PR that merged before the upgrade and never
        # finished cleaning up. Nothing is invented for it here: recovery reads
        # the merged pull request itself and plans the obligations from it.
        version = 3
    if version == 3:
        # Version 3 selected by fair rotation and so recorded no active
        # candidate. A file it wrote migrates forward owning no lane, and the
        # first pass after the upgrade selects from the lowest PR number.
        state["active_pr"] = None
        version = 4
    if version != STATE_VERSION:
        raise DrainError(f"Unsupported drain state in {source}; inspect or remove it.")
    state["version"] = STATE_VERSION
    state.setdefault("attempt_counter", 0)
    if not isinstance(state["attempt_counter"], int) or isinstance(
        state["attempt_counter"], bool
    ):
        raise DrainError(f"Unsupported drain state in {source}; inspect or remove it.")
    state.setdefault("active_pr", None)
    active = state["active_pr"]
    if active is not None and (
        not isinstance(active, int) or isinstance(active, bool) or active <= 0
    ):
        raise DrainError(f"Unsupported drain state in {source}; inspect or remove it.")
    for key, entry in state["prs"].items():
        # `approved_head` has no default: it is the commit a review cleared,
        # and inventing one would let an unreviewed head through.
        if not isinstance(entry, dict) or not isinstance(
            entry.get("approved_head"), str
        ):
            raise DrainError(
                f"Unsupported drain state for PR {key} in {source}; "
                "inspect or remove it."
            )
        entry.setdefault("consecutive_failures", 0)
        entry.setdefault("retry_after_attempt", 0)
        entry.setdefault("last_attempt", 0)
        entry.setdefault("last_error", None)
        entry.setdefault("cleanup", None)
    return state


def load_drain_state(ctx: RepoContext) -> dict[str, Any]:
    path = drain_state_path(ctx)
    if not path.exists():
        return {
            "version": STATE_VERSION,
            "attempt_counter": 0,
            "active_pr": None,
            "prs": {},
        }
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise DrainError(f"Failed to read drain state from {path}: {exc}") from exc
    return migrate_drain_state(state, source=str(path))


def save_drain_state(ctx: RepoContext, state: dict[str, Any], *, dry_run: bool) -> None:
    if dry_run:
        return
    path = drain_state_path(ctx)
    fd, tmp_name = tempfile.mkstemp(prefix="drain_prs_state.", dir=path.parent)
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(state, handle, indent=2, sort_keys=True)
            handle.write("\n")
        tmp_path.replace(path)
    except BaseException:
        tmp_path.unlink(missing_ok=True)
        raise


def remember_approved_head(
    state: dict[str, Any],
    number: int,
    head_sha: str,
) -> None:
    previous = state["prs"].get(str(number), {})
    state["prs"][str(number)] = {
        "approved_head": head_sha,
        "last_rereviewed_head": None,
        "consecutive_failures": 0,
        "retry_after_attempt": 0,
        "last_attempt": previous.get("last_attempt", 0),
        "last_error": None,
        "ci_rerun_head": None,
        "ci_rerun_attempts": 0,
        "ci_rerun_active": False,
        "ci_rerun_exhausted_head": None,
        # Approval bookkeeping is reset here; a recorded cleanup obligation is
        # not. It belongs to a merge that already landed, and only completing
        # it -- never a new approval -- may discharge it.
        "cleanup": previous.get("cleanup"),
    }


def forget_pr(state: dict[str, Any], number: int) -> None:
    state["prs"].pop(str(number), None)


def failure_backoff_attempts(consecutive_failures: int) -> int:
    if consecutive_failures < FAILURES_BEFORE_BACKOFF:
        return 0
    exponent = consecutive_failures - FAILURES_BEFORE_BACKOFF
    return min(2**exponent, MAX_BACKOFF_ATTEMPTS)


def begin_drain_pass(state: dict[str, Any]) -> int:
    """Open one polling pass and return its number.

    The counter is denominated in passes rather than in per-PR attempts, which
    is what makes a failure cooldown expire on its own. A pass that skips every
    candidate attempts nothing, so a counter only the processing of some *other*
    pull request advanced would freeze every cooldown in an all-blocked queue.
    """
    state["attempt_counter"] += 1
    return state["attempt_counter"]


def begin_pr_attempt(state: dict[str, Any], number: int) -> int:
    attempt = state["attempt_counter"]
    state["prs"][str(number)]["last_attempt"] = attempt
    return attempt


def record_pr_success(state: dict[str, Any], number: int) -> None:
    entry = state["prs"].get(str(number))
    if entry is None:
        return
    entry["consecutive_failures"] = 0
    entry["retry_after_attempt"] = 0
    entry["last_error"] = None


def record_pr_failure(state: dict[str, Any], number: int, error: str) -> int:
    entry = state["prs"][str(number)]
    failures = int(entry.get("consecutive_failures", 0)) + 1
    cooldown = failure_backoff_attempts(failures)
    entry["consecutive_failures"] = failures
    # The first pass allowed to look at this PR again, so a cooldown of N skips
    # exactly N passes: the pass recording the failure is the current counter,
    # and the next one is already counter + 1.
    entry["retry_after_attempt"] = state["attempt_counter"] + cooldown + 1
    entry["last_error"] = error
    return cooldown


def pass_candidate_order(
    eligible: list[dict[str, Any]],
    active: int | None,
) -> list[int]:
    """The order one polling pass examines its candidates in.

    Lowest pull-request number first. Nothing about a pull request's history
    enters this: an earlier scheduler ordered by `last_attempt`, which let a
    higher-numbered pull request overtake a lower-numbered one and spread
    branch updates -- and the CI they start -- across the whole queue.

    The one exception is the candidate that already owns the active lane. It is
    examined first so a pull request that becomes eligible while it waits on
    its checks cannot preempt it, however much lower its number.
    """
    numbers = sorted({pr["number"] for pr in eligible})
    if active is None or active not in numbers:
        return numbers
    return [active] + [number for number in numbers if number != active]


def candidate_block_reason(
    pr: dict[str, Any],
    state: dict[str, Any],
) -> str | None:
    """Why this pass must skip a candidate without reading it from GitHub.

    Both blocks are durable and specific to one candidate, so the pass moves
    on to the next-lowest number rather than ending. Both are keyed to the head
    they were recorded against: a new reviewed head is a new candidate.
    """
    entry = state["prs"].get(str(pr["number"]))
    if entry is None:
        return None
    exhausted_head = entry.get("ci_rerun_exhausted_head")
    if exhausted_head and exhausted_head == pr.get("headRefOid"):
        return "ci_rerun_exhausted"
    if int(entry.get("retry_after_attempt") or 0) > int(state["attempt_counter"]):
        return "cooling_down"
    return None


def classify_pass_outcome(reason: str, *, raised: bool) -> str:
    """What a finished candidate turn allows the pass around it to do next.

    Fails closed twice over. An unclassified reason ends the pass, and so does
    any DrainError other than the refusals process_pr() classifies on its way
    out -- a failed `gh` call inside a branch update or a merge leaves the
    reason at whatever preceded it, and its effect on GitHub is exactly what
    this run could not establish.
    """
    outcome = PASS_OUTCOMES.get(reason)
    if outcome is None:
        return PASS_FAILURE
    if raised and outcome != PASS_SKIP:
        return PASS_FAILURE
    return outcome


def get_pr(ctx: RepoContext, number: int) -> dict[str, Any]:
    fields = ",".join(
        [
            "number",
            "title",
            "url",
            "state",
            "isDraft",
            "labels",
            "mergeable",
            "mergeStateStatus",
            "headRefOid",
            "headRefName",
            "baseRefName",
            "statusCheckRollup",
            "closingIssuesReferences",
        ]
    )
    return run_json(
        [
            "gh",
            "pr",
            "view",
            str(number),
            "--repo",
            ctx.repo_slug,
            "--json",
            fields,
        ],
        cwd=ctx.path,
    )


def parse_review_marker_details(body: str) -> tuple[str, str, str] | None:
    match = PR_REVIEW_V1_RE.search(body)
    if match:
        return (
            match.group(1).lower(),
            match.group(2).lower(),
            match.group(3).upper(),
        )
    match = PR_REVIEW_V2_RE.search(body)
    if match:
        return (
            match.group(1).lower(),
            match.group(2).lower(),
            match.group(3).upper(),
        )
    match = LEGACY_CODEX_REVIEW_RE.search(body)
    if match:
        return "codex", match.group(1).lower(), match.group(2).upper()
    return None


def parse_review_marker(body: str) -> tuple[str, str] | None:
    details = parse_review_marker_details(body)
    if details is None:
        return None
    _, head, verdict = details
    return head, verdict


def latest_review_details(
    ctx: RepoContext, number: int
) -> tuple[str, str, str] | None:
    # `gh pr view --json comments` returns a bounded window, so on a long PR
    # the newest marker can fall outside it -- verification then fails, or an
    # older marker wins and a stale verdict is treated as current. Page the
    # whole feed in so the marker chosen is the globally newest one.
    pages = run_json(
        [
            "gh",
            "api",
            "--paginate",
            "--slurp",
            f"repos/{ctx.repo_slug}/issues/{number}/comments?per_page=100",
        ],
        cwd=ctx.path,
    )
    if not isinstance(pages, list):
        raise DrainError(f"Unexpected comments response for PR #{number}")
    all_comments: list[dict[str, Any]] = []
    for page in pages:
        if not isinstance(page, list):
            raise DrainError(f"Unexpected comments page for PR #{number}")
        all_comments.extend(page)
    comments = sorted(
        all_comments,
        key=lambda comment: (comment.get("created_at") or "", comment.get("id") or 0),
        reverse=True,
    )
    for comment in comments:
        details = parse_review_marker_details(comment.get("body") or "")
        if details is not None:
            return details
    return None


def latest_review_marker(ctx: RepoContext, number: int) -> tuple[str, str] | None:
    details = latest_review_details(ctx, number)
    if details is None:
        return None
    _, head, verdict = details
    return head, verdict


def add_approval_label(ctx: RepoContext, number: int) -> None:
    log(f"PR #{number}: re-adding {APPROVE_LABEL}")
    run(
        [
            "gh",
            "pr",
            "edit",
            str(number),
            "--repo",
            ctx.repo_slug,
            "--add-label",
            APPROVE_LABEL,
        ],
        cwd=ctx.path,
    )


def parse_check_name(item: dict[str, Any]) -> str | None:
    return item.get("name") or item.get("context")


def parse_check_sort_key(item: dict[str, Any]) -> str:
    return (
        item.get("startedAt")
        or item.get("completedAt")
        or item.get("createdAt")
        or ""
    )


def latest_check(pr: dict[str, Any], name: str) -> dict[str, Any] | None:
    matches = [
        item
        for item in pr.get("statusCheckRollup", [])
        if parse_check_name(item) == name
    ]
    if not matches:
        return None
    return max(matches, key=parse_check_sort_key)


def latest_non_skipped_check(
    pr: dict[str, Any], name: str
) -> dict[str, Any] | None:
    matches = [
        item
        for item in pr.get("statusCheckRollup", [])
        if parse_check_name(item) == name
        and not (
            item.get("status") == "COMPLETED"
            and item.get("conclusion") == "SKIPPED"
        )
    ]
    if not matches:
        return None
    return max(matches, key=parse_check_sort_key)


def action_run_id(check: dict[str, Any] | None) -> str | None:
    """Extract the GitHub Actions run id from a check's details URL."""
    if check is None:
        return None
    details_url = check.get("detailsUrl") or check.get("details_url") or ""
    match = re.search(r"/actions/runs/(\d+)(?:/|$)", details_url)
    return match.group(1) if match else None


def rerun_failed_ci(
    ctx: RepoContext,
    pr: dict[str, Any],
    *,
    state: dict[str, Any],
    check_name: str,
    dry_run: bool,
) -> bool:
    """Request one bounded retry of a failed GitHub Actions run.

    The retry is keyed to the approved head. A persistent source failure is
    therefore retried at most MAX_CI_RERUN_ATTEMPTS times and then quarantined
    until a new reviewed head arrives. The polling loop gives an active retry
    a short cadence without changing the normal queue interval.
    """
    number = pr["number"]
    head = pr["headRefOid"]
    entry = state["prs"][str(number)]
    if entry.get("ci_rerun_head") != head:
        entry["ci_rerun_head"] = head
        entry["ci_rerun_attempts"] = 0
        entry["ci_rerun_active"] = False
        entry["ci_rerun_exhausted_head"] = None

    attempts = int(entry.get("ci_rerun_attempts", 0))
    if attempts >= MAX_CI_RERUN_ATTEMPTS:
        entry["ci_rerun_active"] = False
        entry["ci_rerun_exhausted_head"] = head
        log(
            f"PR #{number}: {check_name} remained failed after "
            f"{attempts} automatic rerun(s); leaving it for human action"
        )
        return False

    run_id = action_run_id(latest_check(pr, check_name))
    if run_id is None:
        return False

    attempts += 1
    if dry_run:
        log(
            f"PR #{number}: would rerun failed Actions run {run_id} "
            f"({attempts}/{MAX_CI_RERUN_ATTEMPTS})"
        )
    else:
        log(
            f"PR #{number}: rerunning failed Actions run {run_id} "
            f"({attempts}/{MAX_CI_RERUN_ATTEMPTS})"
        )
        run(
            [
                "gh",
                "run",
                "rerun",
                run_id,
                "--failed",
                "--repo",
                ctx.repo_slug,
            ],
            cwd=ctx.path,
        )
    entry["ci_rerun_head"] = head
    entry["ci_rerun_attempts"] = attempts
    entry["ci_rerun_active"] = True
    return True


def clear_ci_rerun(state: dict[str, Any], number: int) -> None:
    entry = state["prs"].get(str(number))
    if entry is None:
        return
    entry["ci_rerun_head"] = None
    entry["ci_rerun_attempts"] = 0
    entry["ci_rerun_active"] = False
    entry["ci_rerun_exhausted_head"] = None


def classify_check(item: dict[str, Any] | None) -> str:
    if item is None:
        return "missing"
    if item.get("status") != "COMPLETED":
        return "pending"
    conclusion = item.get("conclusion")
    if conclusion == "SUCCESS":
        return "success"
    return "failure"


def configured_check_state(pr: dict[str, Any], name: str | None) -> str:
    if name is None:
        return "disabled"
    return classify_check(latest_check(pr, name))


def check_gate_satisfied(state: str) -> bool:
    return state in {"success", "disabled"}


def render_check_gate(kind: str, name: str | None, state: str) -> str:
    if name is None:
        return f"{kind}=disabled"
    return f"{name}={state}"


def wait_for_branch_update_policy(
    ctx: RepoContext,
    number: int,
    previous_head: str,
    *,
    timeout_seconds: int,
    poll_seconds: int,
) -> dict[str, Any]:
    deadline = time.time() + timeout_seconds
    last_state = "missing"
    while True:
        pr = get_pr(ctx, number)
        if pr["headRefOid"] != previous_head:
            # Label/unlabel events start later copies of this job which are
            # intentionally skipped. Read the synchronize decision instead of
            # allowing a newer skipped copy to mask it.
            last_state = classify_check(
                latest_non_skipped_check(pr, STALE_APPROVAL_CHECK)
            )
            if last_state == "success":
                # The workflow's gh label edit completes before the job does.
                # Fetch once more so the caller observes that final label state.
                return get_pr(ctx, number)
            if last_state == "failure":
                raise DrainError(
                    f"PR #{number}: {STALE_APPROVAL_CHECK} failed after branch update."
                )
        if time.time() >= deadline:
            raise DrainError(
                f"Timed out waiting for PR #{number} branch update policy "
                f"({STALE_APPROVAL_CHECK}={last_state})."
            )
        time.sleep(poll_seconds)


def update_branch(ctx: RepoContext, pr: dict[str, Any], *, dry_run: bool) -> None:
    number = pr["number"]
    head_sha = pr["headRefOid"]
    log(f"PR #{number}: branch is behind {ctx.default_branch}; updating via GitHub")
    if dry_run:
        return
    run(
        [
            "gh",
            "api",
            "-X",
            "PUT",
            f"repos/{ctx.repo_slug}/pulls/{number}/update-branch",
            "-f",
            f"expected_head_sha={head_sha}",
        ],
        cwd=ctx.path,
    )
    log(f"PR #{number}: waiting for stale-approval workflow decision")
    refreshed = wait_for_branch_update_policy(
        ctx,
        number,
        head_sha,
        timeout_seconds=UPDATE_BRANCH_WAIT_SECONDS,
        poll_seconds=UPDATE_BRANCH_POLL_SECONDS,
    )
    if has_label(refreshed, APPROVE_LABEL):
        log(
            f"PR #{number}: branch update touched no PR-owned files; "
            f"{APPROVE_LABEL} was retained"
        )
    else:
        add_approval_label(ctx, number)


def audit_merged_pr(
    ctx: RepoContext,
    number: int,
    expected_head: str,
    gates: GateConfig,
) -> None:
    # Samples state exactly once, immediately after the merge call returns.
    # It mitigates the residual read-to-merge race (see the comment above
    # the final gate re-check in process_pr()) by turning a slipped-through
    # mutation into a loud incident instead of a silent merge -- it cannot
    # eliminate the race, and it can still miss a mutation that lands and is
    # reversed between this single sample and the merge itself.
    try:
        audited = get_pr(ctx, number)
    except DrainError as exc:
        raise PostMergeAuditError(
            f"PR #{number}: post-merge audit read failed after merging "
            f"{expected_head}: {exc}"
        ) from exc

    audited_head = audited.get("headRefOid")
    labels = sorted(item["name"] for item in audited.get("labels", []))
    check_names = {
        "ci": gates.required_ci_check,
        "review": gates.required_review_check,
    }
    check_evidence: dict[str, tuple[str | None, str | None, str | None]] = {}
    problems: list[str] = []

    if audited_head != expected_head:
        problems.append(
            f"audited head {audited_head} does not match merged head {expected_head}"
        )
    if not has_label(audited, APPROVE_LABEL):
        problems.append(f"{APPROVE_LABEL!r} label missing")
    if has_label(audited, CHANGES_LABEL):
        problems.append(f"{CHANGES_LABEL!r} label present")
    for kind, name in check_names.items():
        state = configured_check_state(audited, name)
        item = latest_check(audited, name) if name is not None else None
        check_evidence[kind] = (
            name,
            item.get("status") if item else None,
            item.get("conclusion") if item else None,
        )
        if not check_gate_satisfied(state):
            problems.append(f"{kind} check {name!r} was {state}")

    if not problems:
        return

    evidence = (
        f"expected_head={expected_head} audited_head={audited_head} "
        f"labels={labels} "
        + " ".join(
            f"{kind}_check={name} {kind}_status={status} {kind}_conclusion={conclusion}"
            for kind, (name, status, conclusion) in check_evidence.items()
        )
    )
    raise PostMergeAuditError(
        f"PR #{number}: post-merge audit found a gate violation after "
        f"merging {expected_head} ({'; '.join(problems)}); {evidence}"
    )


def merge_pr(
    ctx: RepoContext,
    pr: dict[str, Any],
    *,
    dry_run: bool,
    gates: GateConfig,
    report: dict[str, Any] | None = None,
) -> bool:
    number = pr["number"]
    head_sha = pr["headRefOid"]
    log(f"PR #{number}: merging with admin merge commit")
    if dry_run:
        return True
    proc = run(
        [
            "gh",
            "pr",
            "merge",
            str(number),
            "--repo",
            ctx.repo_slug,
            "--admin",
            "--merge",
            "--match-head-commit",
            head_sha,
        ],
        cwd=ctx.path,
        check=False,
    )
    if proc.returncode == 0:
        # GitHub has accepted the merge and it is durable from this line on.
        # Recorded before the audit, not after it: an audit that fails -- or
        # an interrupt that lands during it -- must still report the merge.
        set_outcome(
            report,
            "merged",
            f"PR #{number} merged {head_sha[:12]} into {ctx.default_branch}.",
            merged=True,
        )
        audit_merged_pr(ctx, number, head_sha, gates)
        return True

    refreshed = get_pr(ctx, number)
    if refreshed["headRefOid"] != head_sha:
        log(
            f"PR #{number}: head changed from {head_sha[:12]} to "
            f"{refreshed['headRefOid'][:12]} during merge; deferring for rereview"
        )
        return False

    detail = (proc.stderr or proc.stdout or f"exit code {proc.returncode}").strip()
    raise DrainError(f"Failed to merge PR #{number}: {detail}")


def close_linked_issue(
    ctx: RepoContext,
    repo_slug: str,
    number: int,
    *,
    dry_run: bool,
) -> None:
    """Close one issue a merged PR closes, idempotently.

    An issue that is already closed -- by an earlier pass, by GitHub's own
    closing keyword, or by hand -- is a satisfied obligation, not a failure.
    """
    state = run_json(
        [
            "gh",
            "issue",
            "view",
            str(number),
            "--repo",
            repo_slug,
            "--json",
            "state",
        ],
        cwd=ctx.path,
    )["state"]
    if state == "CLOSED":
        return
    log(f"Closing linked issue {repo_slug}#{number}")
    if dry_run:
        return
    run(
        [
            "gh",
            "issue",
            "close",
            str(number),
            "--repo",
            repo_slug,
        ],
        cwd=ctx.path,
    )


def parse_worktree_porcelain(output: str) -> list[dict[str, str]]:
    entries: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for line in output.splitlines():
        if not line.strip():
            if current:
                entries.append(current)
                current = {}
            continue
        key, _, value = line.partition(" ")
        current[key] = value
    if current:
        entries.append(current)
    return entries


def parse_worktrees(ctx: RepoContext) -> list[dict[str, str]]:
    proc = run(
        ["git", "worktree", "list", "--porcelain"],
        cwd=ctx.path,
    )
    return parse_worktree_porcelain(proc.stdout)


def extract_issue_numbers(pr: dict[str, Any]) -> list[int]:
    numbers = {issue["number"] for issue in pr.get("closingIssuesReferences", [])}
    branch = pr.get("headRefName", "")
    for match in re.finditer(r"issue-(\d+)", branch):
        numbers.add(int(match.group(1)))
    return sorted(numbers)


def select_matching_worktree(
    entries: list[dict[str, str]],
    *,
    main_path: Path,
    repo_name: str,
    branch_name: str,
    issue_numbers: list[int],
    pr_number: int,
    pr_head_oid: str | None,
) -> Path | None:
    # Positive identification is the only thing allowed to select a worktree
    # for deletion or sandbox-bypassed reuse: an exact branch match, or (for
    # detached worktrees, independent of directory naming) an exact HEAD-SHA
    # match against the PR head. Directory-basename scoring alone is used
    # only to surface a candidate for branch-checked-out worktrees whose
    # branch doesn't match -- it can never itself select a match, and a lone
    # surviving candidate is logged and left in place rather than returned.
    detached_matches: list[Path] = []
    fuzzy_candidates: list[tuple[int, Path]] = []

    for entry in entries:
        path = Path(entry["worktree"]).resolve()
        if path == main_path:
            continue
        branch_ref = entry.get("branch")
        if branch_ref == f"refs/heads/{branch_name}":
            return path

        if branch_ref is None:
            # Only the explicit porcelain "detached" marker positively
            # establishes detached state; an entry missing both "branch"
            # and "detached" is malformed/undetermined and must not be
            # eligible for the exact-HEAD match either.
            is_detached = "detached" in entry
            head_sha = entry.get("HEAD") if is_detached else None
            if is_detached and pr_head_oid and head_sha and head_sha == pr_head_oid:
                detached_matches.append(path)
            else:
                log(
                    f"possible worktree for PR #{pr_number} at {path} — not "
                    "verified, leaving in place"
                )
            continue

        base = path.name.lower()
        score = 0
        for number in issue_numbers:
            if f"issue-{number}" in base:
                score = max(score, 80)
            if base == f"{repo_name}-{number}":
                score = max(score, 70)
            if base.endswith(f"-{number}"):
                score = max(score, 40)
        if score:
            fuzzy_candidates.append((score, path))

    # The fuzzy name-score tie check runs before any positive-identification
    # / verification step -- including the detached exact-HEAD match below --
    # so a tied fuzzy candidate set always raises, never gets shadowed by an
    # unrelated detached match elsewhere in the same worktree list.
    best_fuzzy_paths: list[Path] = []
    if fuzzy_candidates:
        fuzzy_candidates.sort(key=lambda item: (-item[0], str(item[1])))
        best_score = fuzzy_candidates[0][0]
        best_fuzzy_paths = [
            path for score, path in fuzzy_candidates if score == best_score
        ]
        if len(best_fuzzy_paths) > 1:
            joined = ", ".join(str(path) for path in best_fuzzy_paths)
            raise DrainError(f"Multiple worktrees match PR #{pr_number}: {joined}")

    if len(detached_matches) > 1:
        joined = ", ".join(str(path) for path in sorted(detached_matches, key=str))
        raise DrainError(f"Multiple worktrees match PR #{pr_number}: {joined}")
    if detached_matches:
        return detached_matches[0]

    if not best_fuzzy_paths:
        return None

    candidate = best_fuzzy_paths[0]
    log(
        f"possible worktree for PR #{pr_number} at {candidate} — not verified, "
        "leaving in place"
    )
    return None


def commit_exists_locally(ctx: RepoContext, sha: str) -> bool:
    proc = run(
        ["git", "cat-file", "-e", f"{sha}^{{commit}}"],
        cwd=ctx.path,
        check=False,
    )
    return proc.returncode == 0


def find_matching_worktree(ctx: RepoContext, pr: dict[str, Any]) -> Path | None:
    pr_head_oid = pr.get("headRefOid")
    if pr_head_oid and not commit_exists_locally(ctx, pr_head_oid):
        # The PR head commit object isn't available in the local repo, so an
        # exact-HEAD string match can't be trusted as positive identification.
        pr_head_oid = None
    return select_matching_worktree(
        parse_worktrees(ctx),
        main_path=ctx.path.resolve(),
        repo_name=ctx.repo_name,
        branch_name=pr["headRefName"],
        issue_numbers=extract_issue_numbers(pr),
        pr_number=pr["number"],
        pr_head_oid=pr_head_oid,
    )


def prepare_review_worktree(
    ctx: RepoContext,
    pr: dict[str, Any],
) -> Path:
    # Always a throwaway detached worktree, never a matched live one. The
    # stale-head rereviewer runs Codex with approvals and the sandbox
    # bypassed, so pointing it at a solve worktree would let it read a HEAD
    # behind the head under review and write over uncommitted work.
    tmpdir = Path(
        tempfile.mkdtemp(prefix=f"drain-prs-rereview-{pr['number']}-")
    )
    run(["git", "fetch", "--quiet", ctx.remote_name, pr["headRefName"]], cwd=ctx.path)
    run(
        [
            "git",
            "worktree",
            "add",
            "--detach",
            str(tmpdir),
            f"{ctx.remote_name}/{pr['headRefName']}",
        ],
        cwd=ctx.path,
    )
    return tmpdir


def drain_rereview_prompt(ctx: RepoContext, number: int, expected_head: str) -> str:
    return f"""You are GPT-5.6-Terra, the final drain-queue reviewer for PR #{number} in {ctx.repo_slug}.

The queue detected an unexpected push after approval. Review only: do not edit files, commit, push, merge, close issues, or remove worktrees.

Pass `--repo {ctx.repo_slug}` to every `gh` command below. Never rely on gh's own default-repository inference, which can target a different repository than {ctx.repo_slug} in a checkout with more than one remote.

1. Fetch `headRefOid` and require it to equal {expected_head}; otherwise report a stale request and do not comment or label.
2. Read the linked issue and authoritative comments, PR body, checks, latest prior `<!-- pr-review:v1 ... -->` comment (or legacy `<!-- codex-review ... -->` comment), new commits, and full merge-base diff.
3. For every prior blocking concern, state Resolved, Partially resolved, or Unresolved with file/line evidence. Review the complete current diff for regressions and unmet issue requirements. Nits never block.
4. Re-fetch the head before publishing. If it changed, do not comment or label.
5. Post APPROVE or CHANGES REQUESTED as a PR comment (`gh pr comment {number} --repo {ctx.repo_slug}`) ending with exactly `<!-- pr-review:v1 reviewer=codex head=<reviewed_head> verdict=APPROVE -->` or `<!-- pr-review:v1 reviewer=codex head=<reviewed_head> verdict=CHANGES_REQUESTED -->`.
6. Re-fetch the head, then switch `{APPROVE_LABEL}` / `{CHANGES_LABEL}` to match the verdict using `gh pr edit {number} --repo {ctx.repo_slug}`. Re-fetch once more; if the head moved, remove the label you added and report the stale result.

Report the verdict, concern statuses, new findings, reviewed head, and comment/label status.
"""


def rereview_pr_with_codex(
    ctx: RepoContext,
    pr: dict[str, Any],
    *,
    dry_run: bool,
) -> dict[str, Any]:
    number = pr["number"]
    expected_head = pr["headRefOid"]
    log(
        f"PR #{number}: unexpected push changed the approved head; "
        f"running Codex rereview of {expected_head[:12]}"
    )
    if dry_run:
        return pr

    review_path = prepare_review_worktree(ctx, pr)
    output_file = Path(tempfile.gettempdir()) / f"drain-prs-rereview-{number}.out"
    prompt = drain_rereview_prompt(ctx, number, expected_head)

    try:
        # The same pre-launch guards the conflict reviewer applies. The
        # worktree was just created detached at the remote branch tip, which
        # is not pinned to headRefOid: a push landing between the PR read and
        # this fetch would leave it on a different commit, so verify against
        # the head actually under review before Codex starts.
        local_status = run(
            ["git", "status", "--porcelain", "--untracked-files=all"],
            cwd=review_path,
        ).stdout.strip()
        if local_status:
            raise DrainError(
                f"PR #{number}: rereview worktree {review_path} was dirty "
                f"before Codex launched:\n{local_status}"
            )
        local_head = run(["git", "rev-parse", "HEAD"], cwd=review_path).stdout.strip()
        if local_head != expected_head:
            raise DrainError(
                f"PR #{number}: rereview worktree head {local_head[:12]} did "
                f"not match expected PR head {expected_head[:12]}."
            )
        try:
            run(
                [
                    "codex",
                    "exec",
                    "--ignore-user-config",
                    "--dangerously-bypass-approvals-and-sandbox",
                    "--ephemeral",
                    "-m",
                    FINALIZE_MODEL,
                    "-c",
                    f'model_reasoning_effort="{FINALIZE_EFFORT}"',
                    "-C",
                    str(review_path),
                    "-o",
                    str(output_file),
                    "-",
                ],
                cwd=review_path,
                input_text=prompt,
            )
        except DrainError as exc:
            notify_model_failure(ctx, number, "stale-head rereview", exc)
            raise ModelUnavailableError(
                f"{FINALIZE_MODEL}@{FINALIZE_EFFORT} failed during stale-head "
                f"rereview for PR #{number}; no retry or fallback was attempted"
            ) from exc

        refreshed = get_pr(ctx, number)
        if refreshed["headRefOid"] != expected_head:
            log(
                f"PR #{number}: head changed again during rereview "
                f"({expected_head[:12]} -> {refreshed['headRefOid'][:12]}); "
                "leaving it for another cycle"
            )
            return refreshed

        marker = latest_review_marker(ctx, number)
        if has_label(refreshed, APPROVE_LABEL) and not has_label(
            refreshed, CHANGES_LABEL
        ):
            if marker != (expected_head.lower(), "APPROVE"):
                raise DrainError(
                    f"PR #{number}: Codex rereview applied {APPROVE_LABEL!r} "
                    "without a matching current-head pr-review marker."
                )
            log(f"PR #{number}: Codex rereview approved {expected_head[:12]}")
        elif has_label(refreshed, CHANGES_LABEL) and not has_label(
            refreshed, APPROVE_LABEL
        ):
            if marker != (expected_head.lower(), "CHANGES_REQUESTED"):
                raise DrainError(
                    f"PR #{number}: Codex rereview applied {CHANGES_LABEL!r} "
                    "without a matching current-head pr-review marker."
                )
            log(f"PR #{number}: Codex rereview requested changes")
        else:
            raise DrainError(
                f"PR #{number}: Codex rereview returned without exactly one "
                f"verdict label; inspect {output_file}."
            )
        return refreshed
    finally:
        # Drainer-owned and disposable: force removal so a dirty tree -- the
        # very state the guard above rejects -- cannot mask the error that is
        # already propagating.
        remove_worktree(ctx, review_path, dry_run=False, allow_dirty_force=True)


def recover_stale_approval(
    ctx: RepoContext,
    state: dict[str, Any],
    *,
    dry_run: bool,
) -> bool:
    # Entries needing only forget_pr() bookkeeping are swept in full here and
    # never report recovery work: returning early for each one cost a whole
    # cycle per stale entry, so N departed PRs blocked merges for N intervals.
    # Only genuine rereview work stays serialized one PR per cycle.
    for key in sorted(state["prs"], key=int):
        number = int(key)
        entry = state["prs"][key]
        if entry.get("cleanup") is not None:
            # A recorded cleanup names everything the merge still owes, so it
            # is worked without reading the pull request again: that read can
            # fail, and a merge's outstanding debts must not depend on it.
            if complete_pending_cleanup(ctx, state, number, dry_run=dry_run):
                forget_pr(state, number)
            continue

        pr = get_pr(ctx, number)

        if pr["state"] != "OPEN":
            if pr["state"] != "MERGED":
                # Closed without merging: nothing is owed, and forgetting it
                # must never close an issue or delete a branch.
                forget_pr(state, number)
                continue
            # Merged with nothing recorded -- the drainer stopped between the
            # merge and its record, or the merge predates the record entirely.
            log(f"PR #{number}: merged with no cleanup recorded; planning it now")
            entry["cleanup"] = plan_cleanup(pr)
            if complete_pending_cleanup(ctx, state, number, dry_run=dry_run):
                forget_pr(state, number)
            continue

        approved_head = entry["approved_head"]
        current_head = pr["headRefOid"]
        if current_head == approved_head:
            if not has_label(pr, APPROVE_LABEL):
                # A label removed without a new commit is a deliberate revocation,
                # not a stale review that the drain queue should restore.
                forget_pr(state, number)
            continue

        if has_label(pr, APPROVE_LABEL):
            marker = latest_review_marker(ctx, number)
            if marker == (current_head.lower(), "APPROVE"):
                log(
                    f"PR #{number}: found an approved review marker for the new head "
                    f"{current_head[:12]}"
                )
                remember_approved_head(state, number, current_head)
                return True
            # review-gate.yml's dismiss-stale-approval job deliberately KEEPS
            # this label when a synchronize push touched none of this PR's own
            # files -- a content-safe "merge base into head" branch-forwarding
            # update (see that workflow's own comments, #801). A busy base
            # branch can push several of these before a human or a fresh
            # review ever runs, and none of them post a review marker at the
            # new head, so the check above never matches and this PR would
            # wait forever even though nothing it owns actually changed.
            # Trust the workflow's own verdict for this exact head instead of
            # re-deriving it: the check only completes successfully once
            # dismiss-stale-approval has finished deciding, and the label is
            # only still attached here because it decided to keep it.
            stale_check = classify_check(
                latest_non_skipped_check(pr, STALE_APPROVAL_CHECK)
            )
            if stale_check == "success":
                log(
                    f"PR #{number}: head changed from {approved_head[:12]} to "
                    f"{current_head[:12]}, but {STALE_APPROVAL_CHECK} confirmed "
                    "the push touched none of this PR's own files; keeping the "
                    "existing approval"
                )
                remember_approved_head(state, number, current_head)
                return True
            # No recovery work to report, and nothing was mutated -- keep
            # sweeping so a later entry's bookkeeping is not deferred a cycle.
            log(
                f"PR #{number}: head changed from {approved_head[:12]} to "
                f"{current_head[:12]}; waiting for stale approval removal"
            )
            continue

        if has_label(pr, CHANGES_LABEL):
            entry["last_rereviewed_head"] = current_head
            continue

        if entry.get("last_rereviewed_head") == current_head:
            continue

        entry["last_rereviewed_head"] = current_head
        try:
            refreshed = rereview_pr_with_codex(ctx, pr, dry_run=dry_run)
        except DrainError:
            # Publication/verification failures must remain retryable rather
            # than permanently suppressing this head after one attempt.
            entry["last_rereviewed_head"] = None
            raise
        if (
            refreshed["headRefOid"] == current_head
            and has_label(refreshed, APPROVE_LABEL)
            and not has_label(refreshed, CHANGES_LABEL)
        ):
            remember_approved_head(state, number, current_head)
        return True

    return False


def remove_worktree(
    ctx: RepoContext,
    path: Path,
    *,
    dry_run: bool,
    allow_dirty_force: bool = False,
) -> None:
    log(f"Removing worktree {path}")
    if dry_run:
        return
    proc = run(
        ["git", "worktree", "remove", str(path)],
        cwd=ctx.path,
        check=False,
    )
    if proc.returncode == 0:
        return
    if not path.exists():
        # Registered but already deleted from disk. There is no working tree
        # left to inspect for uncommitted work, and the `git status` below
        # would run with a missing cwd and raise an OSError rather than the
        # DrainError this function's callers handle. Drop the stale
        # registration instead, and report it still owed if git keeps it --
        # a locked entry survives both removal and pruning.
        log(f"Worktree {path} is already gone; pruning its stale registration")
        run(["git", "worktree", "prune"], cwd=ctx.path)
        registered = any(
            Path(entry["worktree"]).resolve() == path
            for entry in parse_worktrees(ctx)
            if "worktree" in entry
        )
        if not registered:
            return
        detail = (proc.stderr or proc.stdout or f"exit code {proc.returncode}").strip()
        raise DrainError(
            f"Worktree {path} is gone from disk but is still registered:\n{detail}"
        )
    if not allow_dirty_force:
        status = run(
            ["git", "status", "--porcelain", "--untracked-files=all"],
            cwd=path,
            check=False,
        )
        if status.returncode != 0:
            detail = (status.stderr or status.stdout or "git status failed").strip()
            raise DrainError(
                f"Standard worktree removal failed for {path}, and its dirty "
                f"state could not be verified; refusing --force.\n{detail}"
            )
        if (status.stdout or "").strip():
            raise DrainError(
                f"Standard worktree removal failed for {path}, which has "
                "uncommitted or untracked files; refusing --force."
            )
    log(f"Standard worktree removal failed for {path}; retrying with --force")
    run(
        ["git", "worktree", "remove", "--force", str(path)],
        cwd=ctx.path,
    )


def delete_local_branch(ctx: RepoContext, branch: str, *, dry_run: bool) -> None:
    proc = run(
        ["git", "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"],
        cwd=ctx.path,
        check=False,
    )
    # Exactly 1 means the ref is absent, which is this step already done.
    # Anything else (128: no repository, unreadable refs) is a failed lookup,
    # and reading it as absence would discharge an obligation never performed.
    if proc.returncode == 1:
        return
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or f"exit code {proc.returncode}").strip()
        raise DrainError(
            f"Could not determine whether local branch {branch} exists:\n{detail}"
        )
    log(f"Deleting local branch {branch}")
    if dry_run:
        return
    run(["git", "branch", "-D", branch], cwd=ctx.path)


def delete_remote_branch(ctx: RepoContext, branch: str, *, dry_run: bool) -> None:
    proc = run(
        ["git", "ls-remote", "--exit-code", "--heads", ctx.remote_name, branch],
        cwd=ctx.path,
        check=False,
    )
    # `--exit-code` reports "no matching refs" as exactly 2; a transient
    # network, auth or remote failure is 128. Only the former means the branch
    # is already gone -- the latter must keep the obligation outstanding rather
    # than let a merged PR be forgotten with its remote branch still there.
    if proc.returncode == 2:
        return
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or f"exit code {proc.returncode}").strip()
        raise DrainError(
            f"Could not determine whether remote branch {branch} exists:\n{detail}"
        )
    log(f"Deleting remote branch {branch}")
    if dry_run:
        return
    run(["git", "push", ctx.remote_name, "--delete", branch], cwd=ctx.path)


def _relocate_untracked_files(ctx: RepoContext) -> tuple[Path, list[str]] | None:
    # Physically moved aside (never staged, stashed, or otherwise recorded in
    # any git ref) so a concurrent `git stash` in another terminal has
    # nothing of ours to collide with.
    proc = run(
        ["git", "ls-files", "--others", "--exclude-standard", "-z"],
        cwd=ctx.path,
        check=False,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or f"exit code {proc.returncode}").strip()
        raise DrainError(f"Could not list untracked files ahead of a temporary stash:\n{detail}")
    paths = [p for p in (proc.stdout or "").split("\0") if p]
    if not paths:
        return None
    holding = Path(tempfile.mkdtemp(prefix="autostash-", dir=str(git_dir(ctx.path))))
    moved: list[str] = []
    try:
        for rel in paths:
            dst = holding / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            (ctx.path / rel).rename(dst)
            moved.append(rel)
    except OSError as exc:
        for rel in moved:
            (holding / rel).rename(ctx.path / rel)
        raise DrainError(f"Could not set aside untracked files ahead of a temporary stash: {exc}")
    return holding, paths


def _has_unsafe_parent(root: Path, dst: Path) -> bool:
    # A symlinked (or otherwise non-directory) parent component that the
    # fast-forward just checked out would redirect mkdir()/rename() outside
    # the worktree entirely -- not just the final path needs checking, any
    # component between root and dst's parent could be the culprit.
    current = root
    for part in dst.relative_to(root).parts[:-1]:
        current = current / part
        if os.path.islink(current):
            return True
        if current.exists() and not current.is_dir():
            return True
    return False


def _restore_untracked_files(ctx: RepoContext, holding: Path, paths: list[str]) -> list[str]:
    failures = []
    for rel in paths:
        dst = ctx.path / rel
        # lexists(), not exists(): a dangling symlink the fast-forward just
        # checked out is a real collision too, but exists() follows it and
        # reports False, which would let rename() replace the symlink itself.
        if os.path.lexists(dst):
            # The fast-forward checked out something new at this path (e.g.
            # upstream added a tracked file/dir here); renaming over it would
            # silently destroy that content, so leave our copy in `holding`
            # for manual reconciliation instead.
            failures.append(f"{rel} (a path now exists there; left under {holding})")
            continue
        if _has_unsafe_parent(ctx.path, dst):
            failures.append(
                f"{rel} (a parent directory is now a symlink or non-directory; "
                f"left under {holding})"
            )
            continue
        try:
            dst.parent.mkdir(parents=True, exist_ok=True)
            (holding / rel).rename(dst)
        except OSError as exc:
            failures.append(f"{rel} ({exc}; left under {holding})")
    if not failures:
        try:
            shutil.rmtree(holding)
        except OSError:
            pass
    return failures


def _snapshot_anchor_ref(tracked_sha: str) -> str:
    return f"refs/drain-prs/autostash/{tracked_sha}"


def _anchor_snapshot(ctx: RepoContext, tracked_sha: str) -> str:
    # `git stash create` returns a commit reachable from no ref at all. If
    # the process died right after this -- before `reset --hard` even runs,
    # let alone before restoration -- that commit would be the *only* copy
    # of the user's changes, and eligible for gc. Anchor it under a private
    # ref immediately, before doing anything destructive to the worktree.
    ref_name = _snapshot_anchor_ref(tracked_sha)
    run(["git", "update-ref", ref_name, tracked_sha], cwd=ctx.path)
    return ref_name


def _release_snapshot_anchor(ctx: RepoContext, ref_name: str) -> None:
    run(["git", "update-ref", "-d", ref_name], cwd=ctx.path, check=False)


def _list_snapshot_anchors(ctx: RepoContext) -> list[tuple[str, str, str]]:
    """Every autostash anchor, as (ref, commit, commit date).

    The pattern is the namespace prefix rather than `.../*`, so it matches
    everything below `refs/drain-prs/autostash/` and no anchor can be missed.
    Over-enumerating is harmless: what an anchor is deleted on is the stash
    match below, not the shape of its name.
    """
    proc = run(
        [
            "git",
            "for-each-ref",
            "--format=%(refname) %(objectname) %(committerdate:iso-strict)",
            "refs/drain-prs/autostash",
        ],
        cwd=ctx.path,
    )
    anchors: list[tuple[str, str, str]] = []
    # A ref name can hold no whitespace at all, so the first two fields split
    # unambiguously; the date is whatever remains (empty for a ref pointing at
    # something that is not a commit).
    for line in (proc.stdout or "").splitlines():
        ref, _, rest = line.strip().partition(" ")
        sha, _, date = rest.partition(" ")
        if ref and sha:
            anchors.append((ref, sha, date.strip() or "date unknown"))
    return anchors


def _stash_entry_shas(ctx: RepoContext) -> set[str]:
    """The commit of every `git stash list` entry, tip and non-tip alike.

    Membership here is the whole redundancy test. `_preserve_unreachable_snapshot`
    stores the snapshot commit itself, so a recovered anchor's object ID is
    literally one of these -- while ancestry from the `refs/stash` tip answers
    a different question, since the tip is only the newest entry and the
    reflog below it holds the rest.
    """
    proc = run(["git", "stash", "list", "--format=%H"], cwd=ctx.path)
    return {line.strip() for line in (proc.stdout or "").splitlines() if line.strip()}


def _reap_redundant_anchor(ctx: RepoContext, ref: str, sha: str, date: str) -> None:
    """Delete one anchor the stash also holds, and prove it afterwards.

    The stash belongs to the user, who can run `git stash drop` or `git stash
    clear` at any moment -- so the membership read that classified this anchor
    describes a moment already past, and deleting on that alone could take the
    last ref to a commit no stash entry holds any more.

    What binds instead is the read *after* the deletion. If the snapshot is
    still a `git stash list` entry once the anchor is gone, it is reachable
    now, which is the strongest claim available. Every other outcome -- the
    entry dropped underneath, or the stash unreadable -- puts the anchor
    straight back, so the ref is never what disappeared.
    """
    restore = f"git stash apply --index {sha}"
    # `-d <ref> <sha>` is a compare-and-swap, so an anchor that moved since
    # enumeration is left alone instead of deleted on a stale reading. Only
    # this ref is named: refs/stash, its reflog, and every stash entry are
    # untouched.
    try:
        proc = run(["git", "update-ref", "-d", ref, sha], cwd=ctx.path, check=False)
    except OSError as exc:
        log(f"Could not delete redundant autostash anchor {ref}: {exc}")
        return
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or f"exit code {proc.returncode}").strip()
        log(f"Could not delete redundant autostash anchor {ref}: {detail}")
        return

    try:
        confirmed = sha in _stash_entry_shas(ctx)
    except (DrainError, OSError) as exc:
        confirmed = False
        why = f"`git stash list` could not be read to confirm its snapshot survived: {exc}"
    else:
        why = "its snapshot is no longer a `git stash list` entry"
    if confirmed:
        log(
            f"Deleted redundant autostash anchor {ref} (commit {sha}, {date}): its "
            f"snapshot stays recoverable with `{restore}`"
        )
        return

    try:
        back = run(["git", "update-ref", ref, sha], cwd=ctx.path, check=False)
        recreated = back.returncode == 0
        detail = (back.stderr or back.stdout or f"exit code {back.returncode}").strip()
    except OSError as exc:
        recreated = False
        detail = str(exc)
    if recreated:
        log(
            f"Restored autostash anchor {ref} (commit {sha}, {date}) immediately "
            f"after deleting it: {why}"
        )
        return
    log(
        f"Deleted autostash anchor {ref} (commit {sha}, {date}) and could not put "
        f"it back ({detail}): {why}. That snapshot may now be referenced by "
        f"nothing -- recover it immediately with `{restore}`."
    )


def sweep_snapshot_anchors(ctx: RepoContext, *, dry_run: bool) -> None:
    """Reap autostash anchors whose snapshot is recoverable; report the rest.

    Called once per process at startup, before any merge or fast-forward, and
    never from inside fast_forward_default_branch() -- so it cannot run while
    an autostash window is open, and can never see this process's own live
    anchor. A conflicted restore therefore still keeps both its anchor and its
    `git stash list` entry; only a later run reaps the redundancy.

    Every failure mode is non-fatal and only logged. A ref sweep must never be
    what stops a pull request from merging.
    """
    try:
        anchors = _list_snapshot_anchors(ctx)
    except (DrainError, OSError) as exc:
        log(f"Could not enumerate autostash anchors; leaving them all in place: {exc}")
        return
    if not anchors:
        return
    try:
        recoverable = _stash_entry_shas(ctx)
    except (DrainError, OSError) as exc:
        # Without the stash list nothing is provably redundant, so every
        # anchor is kept and reported below rather than deleted on a guess.
        log(f"Could not read `git stash list`; keeping every autostash anchor: {exc}")
        recoverable = set()
    for ref, sha, date in anchors:
        restore = f"git stash apply --index {sha}"
        if sha not in recoverable:
            log(
                f"Keeping autostash anchor {ref} (commit {sha}, {date}): its snapshot "
                "is not in `git stash list`, so this ref may hold the only copy of "
                f"local changes. Restore it with `{restore}`."
            )
            continue
        if dry_run:
            log(
                f"Would delete redundant autostash anchor {ref} (commit {sha}, {date}): "
                f"its snapshot is already recoverable with `{restore}`"
            )
            continue
        _reap_redundant_anchor(ctx, ref, sha, date)


def _preserve_unreachable_snapshot(ctx: RepoContext, tracked_sha: str, message: str) -> str:
    # May already be anchored under refs/drain-prs/autostash/<sha> from
    # earlier in the flow, or may not be (e.g. anchoring itself is what
    # failed) -- (re)creating it here is idempotent either way. Also try to
    # surface it through the more familiar `git stash list`, and say plainly
    # where it actually landed rather than assuming success.
    store_proc = run(
        ["git", "stash", "store", "-m", message, tracked_sha],
        cwd=ctx.path,
        check=False,
    )
    if store_proc.returncode == 0:
        return "The snapshotted changes were recovered into `git stash list` for manual resolution."
    ref_name = _snapshot_anchor_ref(tracked_sha)
    ref_proc = run(["git", "update-ref", ref_name, tracked_sha], cwd=ctx.path, check=False)
    if ref_proc.returncode == 0:
        return (
            "The snapshotted changes could not be added to `git stash list`, but are "
            f"preserved at `{ref_name}`; restore with `git stash apply --index {tracked_sha}`."
        )
    return (
        "The snapshotted changes could NOT be preserved under any ref and may be "
        f"garbage-collected; restore them immediately with `git stash apply --index {tracked_sha}`."
    )


def _snapshot_tracked_changes(ctx: RepoContext, message: str) -> str | None:
    # `git stash create` snapshots the index/working-tree diff into a
    # floating commit without touching the shared refs/stash reflog at all,
    # so there is no shared position for a concurrent stash to disturb.
    proc = run(["git", "stash", "create", message], cwd=ctx.path, check=False)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or f"exit code {proc.returncode}").strip()
        raise DrainError(detail)
    return (proc.stdout or "").strip() or None


def _tracked_state_trees(ctx: RepoContext, tracked_sha: str) -> tuple[str, str]:
    """The (working tree, index) trees one `git stash create` commit records.

    A stash commit's own tree is the working tree it saw, and its second parent
    is the index commit git wrote alongside it, so this pair pins exactly the
    tracked state a `reset --hard` would discard.

    Compared by tree rather than by commit ID because the commit IDs of two
    snapshots of identical content need not match: `git stash create` stamps a
    commit time, so a second call that lands one second later produces a
    different commit for the same content. Trees are content-addressed and
    never do that.
    """
    proc = run(
        ["git", "rev-parse", f"{tracked_sha}^{{tree}}", f"{tracked_sha}^2^{{tree}}"],
        cwd=ctx.path,
    )
    trees = [line.strip() for line in (proc.stdout or "").splitlines() if line.strip()]
    if len(trees) != 2:
        raise DrainError(
            f"Could not read the tracked state snapshot {tracked_sha} holds: expected "
            f"a working-tree and an index tree, got {len(trees)}"
        )
    return trees[0], trees[1]


def _require_snapshot_still_current(ctx: RepoContext, tracked_sha: str, message: str) -> None:
    """The final pre-reset protection boundary: is the snapshot still faithful?

    `_snapshot_tracked_changes` records the index and working tree as they
    stood when it ran, and `git reset --hard HEAD` discards whatever is in the
    working tree when *it* runs. A tracked edit written between the two is in
    neither the snapshot nor, afterwards, the working tree -- the reset would
    destroy the only copy. (Untracked files never had this exposure:
    `reset --hard` leaves them alone.)

    So immediately before the reset, re-read the tracked state and compare it
    by content against the snapshot the reset is about to rely on. Matching
    means nothing landed in the window and the snapshot is a faithful copy.
    Anything else -- a newer state, no local changes left at all, or a read
    that fails outright -- raises, and the caller's abort path leaves the
    checkout untouched with the fast-forward owed to a later pass. Newer
    content is never worth less than the snapshot, so a reset is never run on
    a snapshot that is not provably current.

    The recheck's own `git stash create` commit is deliberately left
    unanchored: on the matching path its content is byte-identical to the
    already-anchored snapshot, and on the differing path nothing destructive
    runs, so that content is still in the working tree. Neither case can leave
    the only copy of anything reachable from no ref.

    This bounds the exposure to the moment between this read and the reset; it
    does not close it. A writer that changes a path after this read still wins,
    and eliminating that needs writer coordination the drainer does not have.
    """
    later_sha = _snapshot_tracked_changes(ctx, message)
    before = _tracked_state_trees(ctx, tracked_sha)
    after = _tracked_state_trees(ctx, later_sha) if later_sha is not None else None
    if after == before:
        return
    raise DrainError(
        f"Tracked changes in {ctx.path} are no longer the ones that were snapshotted: "
        "they changed after the snapshot was taken and before the reset that would "
        "have discarded them. The reset was not run and the checkout is untouched, so "
        "the newer content is still in the working tree; the fast-forward is left owed "
        "to a later pass."
    )


def _restore_snapshot(
    ctx: RepoContext,
    tracked_sha: str | None,
    untracked: tuple[Path, list[str]] | None,
    anchor_ref: str | None,
) -> None:
    problems = []
    if tracked_sha is not None:
        apply_proc = run(
            ["git", "stash", "apply", "--index", tracked_sha],
            cwd=ctx.path,
            check=False,
        )
        if apply_proc.returncode != 0:
            detail = (apply_proc.stderr or apply_proc.stdout or "").strip()
            where = _preserve_unreachable_snapshot(
                ctx, tracked_sha, f"drain-prs-autostash-recovery {tracked_sha}"
            )
            problems.append(
                f"tracked changes (commit {tracked_sha}) could not be reapplied"
                + (f": {detail}" if detail else "")
                + f"; {where}"
            )
        elif anchor_ref is not None:
            # Changes are safely back in the working tree; the anchor was
            # only ever needed to survive a crash before this point.
            _release_snapshot_anchor(ctx, anchor_ref)
    if untracked is not None:
        holding, paths = untracked
        failures = _restore_untracked_files(ctx, holding, paths)
        if failures:
            problems.append(
                f"untracked files could not be restored and remain at {holding}: "
                + ", ".join(failures)
            )
    if problems:
        raise DrainError(
            "Fast-forward succeeded, but restoring local changes failed:\n- "
            + "\n- ".join(problems)
        )


def _unmerged_index_paths(ctx: RepoContext) -> list[str]:
    """The paths git itself reports as unmerged in the index, in index order.

    Reads git's own stage entries rather than matching text in some failed
    command's output, so it depends on neither the locale nor the wording of
    a git error. `-z` keeps paths raw instead of quoting the unusual ones,
    and each path carries a stage 1/2/3 entry, so duplicates are dropped.
    """
    proc = run(["git", "ls-files", "--unmerged", "-z"], cwd=ctx.path)
    paths: list[str] = []
    for record in (proc.stdout or "").split("\0"):
        if not record:
            continue
        _, _, path = record.partition("\t")
        if path and path not in paths:
            paths.append(path)
    return paths


def _require_merged_index(ctx: RepoContext) -> None:
    # A conflicted autostash restore leaves unmerged entries in the index,
    # and `git stash create` refuses to snapshot one. Left undetected, every
    # later pass dies at the snapshot step and blames local changes for a
    # state only a human can clear -- forever, at the polling interval.
    #
    # Like the operation-state check this refuses before anything changes:
    # ahead of the fetch, the first --ff-only, the untracked relocation, the
    # snapshot, the anchor, and the reset, so a wedged checkout is left
    # exactly as the human left it -- the partial merge git computed in the
    # working tree included.
    paths = _unmerged_index_paths(ctx)
    if not paths:
        return
    raise DrainError(
        f"Refusing to fast-forward {ctx.default_branch}: the index in {ctx.path} holds "
        "unmerged entries, so no snapshot of local changes can be taken. Local changes "
        "are not what blocked this. Resolve these paths and `git add` them, and the "
        "next ordinary pass discharges the fast-forward: " + ", ".join(paths)
    )


def fast_forward_default_branch(
    ctx: RepoContext,
    *,
    dry_run: bool,
) -> None:
    log(f"Fast-forwarding local {ctx.default_branch}")
    if dry_run:
        return

    _require_merged_index(ctx)

    run(["git", "fetch", "--quiet", ctx.remote_name], cwd=ctx.path)

    def try_ff() -> None:
        run(
            ["git", "merge", "--ff-only", f"{ctx.remote_name}/{ctx.default_branch}"],
            cwd=ctx.path,
        )

    try:
        try_ff()
        return
    except DrainError as ff_exc:
        message = f"drain-prs-autostash-{int(time.time())}-{os.getpid()}"
        untracked = None
        tracked_sha = None
        anchor_ref = None
        try:
            untracked = _relocate_untracked_files(ctx)
            tracked_sha = _snapshot_tracked_changes(ctx, message)
            if tracked_sha is not None:
                # Anchor before doing anything destructive: once
                # `reset --hard` runs, this floating commit is the only
                # copy of the user's changes until restoration completes.
                anchor_ref = _anchor_snapshot(ctx, tracked_sha)
                # The last read of tracked state before the destructive
                # reset, and therefore the final pre-reset protection
                # boundary: an edit that landed since the snapshot is in
                # the working tree and nowhere else, so the reset must not
                # run over one.
                _require_snapshot_still_current(ctx, tracked_sha, message)
                run(["git", "reset", "--hard", "HEAD"], cwd=ctx.path)
        except DrainError as prep_exc:
            if untracked is not None:
                _restore_untracked_files(ctx, *untracked)
            recovery_note = ""
            if tracked_sha is not None:
                recovery_note = " " + _preserve_unreachable_snapshot(ctx, tracked_sha, message)
            raise DrainError(
                "Local changes blocked fast-forward, and preparing a temporary "
                f"snapshot of them failed; aborting.\n{prep_exc}{recovery_note}"
            ) from ff_exc

        if tracked_sha is None and untracked is None:
            raise

        log("Local changes blocked fast-forward; stashed them temporarily")
        try:
            try_ff()
        except DrainError:
            raise
        finally:
            _restore_snapshot(ctx, tracked_sha, untracked, anchor_ref)


def cleanup_pr_snapshot(pr: dict[str, Any]) -> dict[str, Any]:
    """The pull-request facts post-merge cleanup depends on.

    Persisted with the cleanup record so every obligation survives a restart:
    once the PR is merged the queue no longer refetches it, and the worktree
    match is recomputed from exactly these fields.
    """
    return {
        "number": pr["number"],
        "headRefName": pr["headRefName"],
        "headRefOid": pr["headRefOid"],
        "closingIssuesReferences": [
            {
                "number": issue["number"],
                "repository": {
                    "owner": {"login": issue["repository"]["owner"]["login"]},
                    "name": issue["repository"]["name"],
                },
            }
            for issue in pr.get("closingIssuesReferences", [])
        ],
    }


def plan_cleanup(pr: dict[str, Any]) -> dict[str, Any]:
    """Build the post-merge cleanup record for a PR that is about to merge.

    Derived from the pull-request payload alone, so nothing here can fail:
    the record is what makes a successful merge durable, and it must never be
    lost to an error in planning it. Every obligation carries the data needed
    to retry it on its own -- a linked issue keeps its owner and repository
    name, because issue numbers are only meaningful per repository.
    """
    snapshot = cleanup_pr_snapshot(pr)
    branch = snapshot["headRefName"]
    pending: list[dict[str, Any]] = [
        {
            "kind": "issue",
            "repo": f'{issue["repository"]["owner"]["login"]}/'
            f'{issue["repository"]["name"]}',
            "number": issue["number"],
        }
        for issue in snapshot["closingIssuesReferences"]
    ]
    # The worktree comes before the branch it has checked out: git refuses to
    # delete a branch a live worktree holds.
    pending.append({"kind": "worktree"})
    pending.append({"kind": "local-branch", "branch": branch})
    pending.append({"kind": "remote-branch", "branch": branch})
    pending.append({"kind": "fast-forward"})
    return {
        "pr": snapshot,
        "pending": pending,
        "failed_passes": 0,
        "last_error": None,
        "incident": None,
    }


def describe_cleanup_obligation(obligation: dict[str, Any]) -> str:
    kind = obligation.get("kind")
    if kind == "issue":
        return f'closing {obligation["repo"]}#{obligation["number"]}'
    if kind == "worktree":
        return "removing the matching worktree"
    if kind == "local-branch":
        return f'deleting local branch {obligation["branch"]}'
    if kind == "remote-branch":
        return f'deleting remote branch {obligation["branch"]}'
    if kind == "fast-forward":
        return "fast-forwarding the default branch"
    return f"unknown cleanup step {kind!r}"


def run_cleanup_obligation(
    ctx: RepoContext,
    record: dict[str, Any],
    obligation: dict[str, Any],
    *,
    dry_run: bool,
) -> None:
    kind = obligation.get("kind")
    if kind == "issue":
        close_linked_issue(
            ctx, obligation["repo"], obligation["number"], dry_run=dry_run
        )
    elif kind == "worktree":
        # Matched here rather than when the record was written: matching reads
        # the live worktree list and can fail, and a merge must never depend on
        # a step that can fail before it is durably recorded.
        worktree = find_matching_worktree(ctx, record["pr"])
        if worktree is None:
            log(f"PR #{record['pr']['number']}: no matching local worktree found")
            return
        remove_worktree(ctx, worktree, dry_run=dry_run)
    elif kind == "local-branch":
        delete_local_branch(ctx, obligation["branch"], dry_run=dry_run)
    elif kind == "remote-branch":
        delete_remote_branch(ctx, obligation["branch"], dry_run=dry_run)
    elif kind == "fast-forward":
        fast_forward_default_branch(ctx, dry_run=dry_run)
    else:
        raise DrainError(f"Unknown cleanup step {kind!r}")


def run_cleanup_pass(
    ctx: RepoContext,
    record: dict[str, Any],
    *,
    dry_run: bool,
) -> list[str]:
    """Attempt every outstanding obligation once, independently.

    One failing step never skips the ones after it: each is attempted, and the
    record is narrowed to exactly those that are still outstanding. Returns one
    message per step that failed -- which is not the same as the record being
    discharged, since a caller running under a deadline can leave steps it
    never started; `record["pending"]` is what says what is still owed.
    """
    number = record["pr"]["number"]
    remaining: list[dict[str, Any]] = []
    errors: list[str] = []
    for obligation in record["pending"]:
        if command_deadline_expired():
            # A bounded pass starts nothing more once its budget is spent.
            # Untouched rather than attempted-and-failed: nothing was learned
            # about this step, so it is neither an error nor a failed pass.
            remaining.append(obligation)
            log(
                f"PR #{number}: out of time before "
                f"{describe_cleanup_obligation(obligation)}; still outstanding"
            )
            continue
        try:
            run_cleanup_obligation(ctx, record, obligation, dry_run=dry_run)
        # OSError alongside DrainError so the never-raises contract holds for
        # the whole step: a path that disappears under a command leaves an
        # obligation outstanding, it does not abort the pass or the queue.
        except (DrainError, OSError) as exc:
            described = describe_cleanup_obligation(obligation)
            remaining.append(obligation)
            errors.append(f"{described}: {exc}")
            log(f"PR #{number}: post-merge cleanup failed {described}; {exc}")
    record["pending"] = remaining
    return errors


def advance_pending_cleanup(
    ctx: RepoContext,
    record: dict[str, Any],
    *,
    dry_run: bool,
) -> bool:
    """Work a merged PR's recorded cleanup and report whether it is finished.

    Never raises. The merge already landed, so an outstanding obligation is a
    debt to retry, not a reason to fail this PR's attempt or to stop the queue
    -- every other approved PR keeps draining either way. A debt that survives
    CLEANUP_PASSES_BEFORE_INCIDENT passes stops being silent and is surfaced as
    an incident, which clears itself once the last step succeeds.
    """
    number = record["pr"]["number"]
    errors = run_cleanup_pass(ctx, record, dry_run=dry_run)
    # What is left in the record, never merely what failed: a pass bounded by a
    # deadline can end with nothing failed and steps still owed, and treating
    # that as finished would drop obligations nothing ever attempted.
    if not record["pending"]:
        record["failed_passes"] = 0
        record["last_error"] = None
        record["incident"] = None
        if not dry_run:
            # Resolved by (repository, PR) rather than by the id this record
            # happens to name: an incident is written atomically before the
            # state that remembers it, so a crash in between leaves one open
            # against a record naming nothing, and nothing else would close it.
            resolved = drain_prs_service.resolve_cleanup_incident(
                ctx.path,
                number,
                f"PR #{number} finished its post-merge cleanup.",
            )
            if resolved is not None:
                log(
                    f"PR #{number}: resolved cleanup incident "
                    f"{resolved['incident_id']}"
                )
        return True

    if not errors:
        # Nothing failed; the pass ran out of budget before starting the rest.
        # No counter moves and nothing escalates -- an obligation nobody
        # attempted has not resisted anything, and the next pass starts it.
        log(
            f"PR #{number}: {len(record['pending'])} post-merge cleanup step(s) "
            "left unattempted for want of time; will retry"
        )
        return False

    record["failed_passes"] = int(record.get("failed_passes", 0)) + 1
    record["last_error"] = "; ".join(errors)
    passes = record["failed_passes"]
    steps = [describe_cleanup_obligation(item) for item in record["pending"]]
    if passes < CLEANUP_PASSES_BEFORE_INCIDENT or dry_run:
        log(
            f"PR #{number}: {len(record['pending'])} post-merge cleanup step(s) "
            f"outstanding after {passes} pass(es); will retry"
        )
        return False
    # Recorded unconditionally rather than only when this record names no
    # incident: recording is idempotent while one is open, and an id it still
    # names may belong to an incident that has since been resolved -- an
    # operator's `ack` dismisses an incident of any kind, this one included.
    # Trusting the stored id would hide an outstanding debt for good.
    incident = drain_prs_service.record_cleanup_incident(
        repo_path=ctx.path,
        pull_request=number,
        steps=steps,
        error=record["last_error"],
    )
    if incident["incident_id"] != record.get("incident"):
        record["incident"] = incident["incident_id"]
        log(
            f"PR #{number}: post-merge cleanup still outstanding after {passes} "
            f"pass(es); recorded incident {incident['incident_id']} and kept retrying"
        )
    else:
        log(
            f"PR #{number}: post-merge cleanup still outstanding after {passes} "
            f"pass(es) under incident {record['incident']}; kept retrying"
        )
    return False


def complete_pending_cleanup(
    ctx: RepoContext,
    state: dict[str, Any],
    number: int,
    *,
    dry_run: bool,
) -> bool:
    """Advance the recorded cleanup for one PR, discharging it when finished.

    The state entry outlives the merge on purpose: it is the only record that
    these obligations are owed, so it is dropped only once every one of them
    is done.
    """
    entry = state["prs"].get(str(number))
    if entry is None:
        return True
    record = entry.get("cleanup")
    if record is None:
        return True
    if advance_pending_cleanup(ctx, record, dry_run=dry_run):
        entry["cleanup"] = None
        log(f"PR #{number}: post-merge cleanup complete")
        return True
    return False


def recorded_cleanup_prs(state: dict[str, Any]) -> list[int]:
    """The pull requests this queue state records outstanding cleanup for.

    The recorded obligations are the whole selection: an entry with no
    `cleanup` value is a pull request whose standing would have to be read
    from GitHub to learn anything about it, and reading it is exactly what a
    caller working only recorded debt must not do.

    A key that is not a pull-request number names nothing that can be worked,
    so it is left where it is rather than raised over: the debt under it stays
    recorded and projected, which is what an unworkable obligation gets.
    """
    owing: list[int] = []
    for key, entry in state["prs"].items():
        if not isinstance(entry, dict) or entry.get("cleanup") is None:
            continue
        try:
            owing.append(int(key))
        except (TypeError, ValueError):
            log(f"Queue state records cleanup under an unusable key {key!r}; skipping it")
    return sorted(owing)


def outstanding_obligations(state: dict[str, Any], number: int) -> int:
    """How many obligations one entry still records, counting anything it
    cannot read as none: this is arithmetic for a report, never a decision
    about what is owed."""
    entry = state["prs"].get(str(number))
    record = entry.get("cleanup") if isinstance(entry, dict) else None
    pending = record.get("pending") if isinstance(record, dict) else None
    return len(pending) if isinstance(pending, list) else 0


def discharge_recorded_cleanup(
    ctx: RepoContext,
    *,
    dry_run: bool,
    budget_seconds: float = SHUTDOWN_CLEANUP_BUDGET_SECONDS,
) -> int:
    """Work the cleanup already recorded in the queue state once, under a
    budget, and report how many obligations that discharged.

    The shutdown counterpart to the polling loop's sweep. This process holds
    the repository run lock for its whole lifetime, so it is the only thing
    that can work these obligations while it is alive -- and once it exits,
    nothing works them until the next start, which may be days away. So an
    intentional stop spends a bounded slice of its own shutdown on them.

    Bounded twice over, because either bound alone leaves a stop that hangs.
    No obligation starts once the budget is spent, and every command inside
    the pass is bounded by the same deadline, so an obligation that wedges
    stops the pass instead of the stop.

    Never raises, and never widens its own remit: it starts no per-pull-request
    work of any kind, reads no pull request, and leaves everything it could not
    discharge exactly as it found it -- still recorded, still projected by
    `status`, and still under whatever incident it had raised. Outstanding debt
    is a debt to retry, not a reason to fail a stop.
    """
    try:
        state = load_drain_state(ctx)
    except DrainError as exc:
        log(f"Could not read the queue state for a final cleanup pass: {exc}")
        return 0
    owing = recorded_cleanup_prs(state)
    if not owing:
        # Nothing recorded is the common case, and it must cost a stop
        # nothing: no command, no state write, and no state file where the
        # repository had none.
        return 0

    deadline = time.monotonic() + budget_seconds
    log(
        f"Stopping: {len(owing)} pull request(s) still owe post-merge cleanup; "
        f"attempting them for up to {budget_seconds:g}s"
    )
    discharged = 0
    try:
        with command_deadline(deadline):
            for number in owing:
                if time.monotonic() >= deadline:
                    log(
                        "Final cleanup pass ran out of time; "
                        f"PR #{number} and any after it were not attempted"
                    )
                    break
                before = outstanding_obligations(state, number)
                try:
                    if complete_pending_cleanup(ctx, state, number, dry_run=dry_run):
                        forget_pr(state, number)
                        discharged += before
                        continue
                except (DrainError, OSError) as exc:
                    # advance_pending_cleanup() absorbs a failing obligation
                    # itself; this covers the bookkeeping around it -- writing
                    # an incident, say -- so one unwritable path cannot cost
                    # the pull requests after this one their attempt.
                    log(f"PR #{number}: final cleanup pass failed: {exc}")
                discharged += before - outstanding_obligations(state, number)
    # A shutdown pass that raised would take the stop with it, and on the
    # single-pull-request path it would take the caller's result document too.
    except Exception as exc:
        log(f"Final cleanup pass failed unexpectedly: {exc!r}")
    except KeyboardInterrupt:
        log("Final cleanup pass interrupted; leaving the rest outstanding")

    try:
        # Written once, after the pass: what it discharged must be durable
        # before this process releases the run lock, and what it did not is
        # what the next start has to retry.
        save_drain_state(ctx, state, dry_run=dry_run)
    except OSError as exc:
        # The pass still happened; only the record of it is lost, which leaves
        # discharged obligations to be re-verified as already done.
        log(f"Could not persist the final cleanup pass: {exc}")
    still_owed = sum(outstanding_obligations(state, number) for number in owing)
    log(
        f"Final cleanup pass discharged {discharged} obligation(s); "
        f"{still_owed} still outstanding"
    )
    return discharged


def fetch_pr_head(ctx: RepoContext, pr: dict[str, Any]) -> bool:
    """Make the PR's exact head commit available locally.

    Identity is the head OID, never the branch name: a fork's head is not a
    branch of this repository at all, and an unrelated local branch can share
    a fork's `headRefName` while pointing somewhere else entirely. GitHub
    publishes every PR head, fork or not, at `refs/pull/<number>/head`, which
    the default fetch refspec does not cover.
    """
    head = pr["headRefOid"]
    if commit_exists_locally(ctx, head):
        return True
    proc = run(
        [
            "git",
            "fetch",
            "--quiet",
            ctx.remote_name,
            f"refs/pull/{pr['number']}/head",
        ],
        cwd=ctx.path,
        check=False,
    )
    if proc.returncode != 0:
        return False
    return commit_exists_locally(ctx, head)


def merge_conflict_paths(ctx: RepoContext, pr: dict[str, Any]) -> list[str]:
    """Repository-relative paths that conflict between the PR head and the
    default branch.

    `git merge-tree` computes the merge in the object database, so this reads
    the conflict without creating a worktree, a branch, or an index the way
    the removed repair path did. Inspection is best-effort: a conflict the
    drainer cannot describe locally is still a conflict it must report, so
    every failure degrades to an unnamed file list rather than an error.
    """
    number = pr["number"]
    try:
        run(["git", "fetch", "--quiet", ctx.remote_name], cwd=ctx.path)
        if not fetch_pr_head(ctx, pr):
            log(
                f"PR #{number}: head {pr['headRefOid'][:12]} is not available "
                "locally; recording the block without file names"
            )
            return []
        proc = run(
            [
                "git",
                "-c",
                "core.quotePath=false",
                "merge-tree",
                "--write-tree",
                "--name-only",
                f"{ctx.remote_name}/{ctx.default_branch}",
                pr["headRefOid"],
            ],
            cwd=ctx.path,
            check=False,
        )
    except DrainError as exc:
        log(f"PR #{number}: could not inspect the conflicting files: {exc}")
        return []
    if proc.returncode == 0:
        log(
            f"PR #{number}: GitHub reports a conflict that merges cleanly "
            "locally; recording the block without file names"
        )
        return []
    if proc.returncode != 1:
        detail = (proc.stderr or proc.stdout or f"exit code {proc.returncode}").strip()
        log(f"PR #{number}: could not inspect the conflicting files: {detail}")
        return []
    # First line is the merged tree's object ID; the conflicted paths follow
    # until the blank line that separates them from the informational messages.
    paths: list[str] = []
    for line in (proc.stdout or "").splitlines()[1:]:
        if not line.strip():
            break
        paths.append(line)
    return sorted(set(paths))


def record_merge_conflict(
    ctx: RepoContext,
    pr: dict[str, Any],
    *,
    dry_run: bool,
) -> None:
    """Stop working one conflicted PR and raise an open incident for it.

    A conflict resolution is the one artifact in this pipeline no reviewer has
    seen, so the drainer asks instead of guessing. It touches no label -- least
    of all the approval the review gate depends on -- and merges nothing.
    """
    number = pr["number"]
    if dry_run:
        log(
            f"PR #{number}: merge conflict; would record an open drainer "
            "incident and stop merging it"
        )
        return
    existing = drain_prs_service.find_open_conflict_incident(ctx.path, number)
    if existing is not None:
        log(
            f"PR #{number}: merge conflict already recorded as "
            f"{existing[1]['incident_id']}; still blocked"
        )
        return
    paths = merge_conflict_paths(ctx, pr)
    incident = drain_prs_service.record_conflict_incident(
        repo_path=ctx.path,
        pull_request=number,
        files=paths,
    )
    log(
        f"PR #{number}: merge conflict; recorded incident "
        f"{incident['incident_id']} and stopped merging it "
        f"({', '.join(paths) if paths else 'conflicting files unavailable'})"
    )


def reconcile_conflict_incidents(ctx: RepoContext, *, dry_run: bool) -> None:
    """Resolve conflict incidents whose PR is no longer conflicted.

    Runs over the stored incidents rather than the approval queue, so an
    incident still clears once its PR leaves the queue. Only a confirmed
    reading closes one: an unknown mergeability or an unavailable read keeps
    it open, and no other PR's incident is touched.
    """
    if dry_run:
        return
    for incident in drain_prs_service.open_conflict_incidents(ctx.path):
        number = incident.get("pull_request")
        if not isinstance(number, int):
            log(
                f"Incident {incident.get('incident_id')} names no pull request; "
                "leaving it open"
            )
            continue
        try:
            pr = get_pr(ctx, number)
        except DrainError as exc:
            log(
                f"PR #{number}: could not confirm the merge conflict cleared; "
                f"keeping its incident open: {exc}"
            )
            continue
        mergeable = pr.get("mergeable")
        merge_state = pr.get("mergeStateStatus")
        if pr.get("state") != "OPEN":
            note = f"PR #{number} is no longer open."
        elif mergeable == "CONFLICTING" or merge_state == "DIRTY":
            continue
        elif mergeable == "MERGEABLE":
            note = f"PR #{number} merges cleanly again."
        else:
            log(
                f"PR #{number}: mergeability is still {mergeable}; "
                "keeping its conflict incident open"
            )
            continue
        resolved = drain_prs_service.resolve_conflict_incident(ctx.path, number, note)
        if resolved is not None:
            log(f"PR #{number}: resolved conflict incident {resolved['incident_id']}")


def set_outcome(
    report: dict[str, Any] | None,
    reason: str,
    message: str,
    *,
    merged: bool = False,
) -> None:
    """Record why one PR's attempt ended, for a caller that wants it verbatim.

    The queue passes no report and is unaffected. A single-PR run passes one
    so the external result is read off the very decisions the queue makes,
    rather than re-deriving them in a second implementation that could drift.
    Only ever called immediately before the return or raise it describes, so
    a recorded reason is always the one that actually ended the attempt.
    """
    if report is None:
        return
    report["reason"] = reason
    report["message"] = message
    report["merged"] = merged


def describe_check_gates(
    gates: GateConfig, build_state: str, review_state: str
) -> str:
    return (
        f"{render_check_gate('ci', gates.required_ci_check, build_state)}, "
        f"{render_check_gate('review', gates.required_review_check, review_state)}"
    )


def check_gate_reason(build_state: str, review_state: str) -> str:
    # "missing" is a check that has not reported yet, which is a wait rather
    # than a refusal -- the state itself stays in the message so the caller
    # can still tell the two apart.
    if "failure" in (build_state, review_state):
        return "checks_failed"
    return "checks_pending"


def process_pr(
    ctx: RepoContext,
    number: int,
    *,
    dry_run: bool,
    state: dict[str, Any],
    gates: GateConfig,
    report: dict[str, Any] | None = None,
) -> bool:
    pr = get_pr(ctx, number)

    if pr["state"] != "OPEN":
        log(f"PR #{number}: no longer open; skipping")
        set_outcome(
            report,
            "not_eligible",
            f"PR #{number} is no longer open (state {pr['state']}).",
        )
        return False
    if pr.get("isDraft"):
        log(f"PR #{number}: draft; skipping")
        set_outcome(report, "not_eligible", f"PR #{number} is a draft.")
        return False
    if pr["baseRefName"] != ctx.default_branch:
        message = (
            f"PR #{number} targets {pr['baseRefName']}, not {ctx.default_branch}."
        )
        set_outcome(report, "not_eligible", message)
        raise DrainError(message)
    if not has_label(pr, APPROVE_LABEL) or has_label(pr, CHANGES_LABEL):
        log(f"PR #{number}: no longer approved; skipping")
        # The changes label wins when both are attached: a requested change is
        # the more specific -- and more actionable -- thing to report.
        if has_label(pr, CHANGES_LABEL):
            set_outcome(
                report,
                "changes_requested",
                f"PR #{number} is labelled {CHANGES_LABEL}.",
            )
        else:
            set_outcome(
                report,
                "not_approved",
                f"PR #{number} is not labelled {APPROVE_LABEL}.",
            )
        return False

    mergeable = pr.get("mergeable")
    merge_state = pr.get("mergeStateStatus")
    if mergeable == "CONFLICTING" or merge_state == "DIRTY":
        # A blocked outcome for this PR alone, not a drainer failure: the queue
        # loop records no failure and applies no cooldown, so every other
        # approved PR keeps draining in the same run.
        record_merge_conflict(ctx, pr, dry_run=dry_run)
        set_outcome(
            report,
            "merge_conflict",
            f"PR #{number} conflicts with {ctx.default_branch}; "
            "it was reported as an incident and left alone.",
        )
        return False

    if merge_state == "BEHIND":
        update_branch(ctx, pr, dry_run=dry_run)
        if not dry_run:
            refreshed = get_pr(ctx, number)
            if has_label(refreshed, APPROVE_LABEL):
                remember_approved_head(state, number, refreshed["headRefOid"])
        # One cycle does one thing: the branch update is this attempt's whole
        # action, and merging waits for the next one -- exactly as the queue
        # behaves.
        set_outcome(
            report,
            "behind_base",
            f"PR #{number} was behind {ctx.default_branch}; its branch update "
            + ("would be requested" if dry_run else "was requested")
            + ". Run again once the update settles.",
        )
        return True

    build_state = configured_check_state(pr, gates.required_ci_check)
    review_state = configured_check_state(pr, gates.required_review_check)

    # Every configured check and its state travels with each message, so a
    # caller shown one blocking gate is never left guessing about the other.
    gate_detail = describe_check_gates(gates, build_state, review_state)
    if build_state == "failure":
        if rerun_failed_ci(
            ctx,
            pr,
            state=state,
            check_name=gates.required_ci_check or DEFAULT_REQUIRED_CI_CHECK,
            dry_run=dry_run,
        ):
            message = (
                f"PR #{number}: required CI check failed ({gate_detail}); "
                f"automatic rerun requested, polling again in "
                f"{CI_RERUN_INTERVAL_SECONDS}s."
            )
            set_outcome(report, "checks_pending", message)
            return True
        message = (
            f"PR #{number}: required CI check {gates.required_ci_check} failed "
            f"({gate_detail})."
        )
        set_outcome(report, "checks_failed", message)
        raise DrainError(message)
    if review_state == "failure":
        message = (
            f"PR #{number}: required review gate "
            f"{gates.required_review_check} failed ({gate_detail})."
        )
        set_outcome(report, "checks_failed", message)
        raise DrainError(message)

    if not check_gate_satisfied(build_state) or not check_gate_satisfied(review_state):
        if build_state == "success":
            clear_ci_rerun(state, number)
        log(
            f"PR #{number}: waiting "
            f"({gate_detail}, mergeStateStatus={merge_state})"
        )
        set_outcome(
            report,
            check_gate_reason(build_state, review_state),
            f"PR #{number} is waiting on its required checks "
            f"({gate_detail}, mergeStateStatus={merge_state}).",
        )
        return True

    clear_ci_rerun(state, number)

    if mergeable in {"UNKNOWN", None} or merge_state == "UNKNOWN":
        log(f"PR #{number}: mergeability still computing; waiting")
        set_outcome(
            report,
            "mergeability_computing",
            f"PR #{number}: GitHub is still computing mergeability "
            f"(mergeable={mergeable}, mergeStateStatus={merge_state}).",
        )
        return True

    # Re-check mutable gate state immediately before the admin merge. The
    # match-head guard below covers a concurrent push; this covers a verdict
    # withdrawal or a newly pending check on the same head. A mutation that
    # lands in the remaining gap between this read and the merge call can
    # still slip through unnoticed -- that residual race is not eliminated,
    # only mitigated: merge_pr() audits the post-merge state right after a
    # successful merge and raises a fatal PostMergeAuditError if it doesn't
    # match what was just checked here.
    pr = get_pr(ctx, number)
    if not has_label(pr, APPROVE_LABEL) or has_label(pr, CHANGES_LABEL):
        log(f"PR #{number}: approval changed before merge; deferring")
        if has_label(pr, CHANGES_LABEL):
            set_outcome(
                report,
                "changes_requested",
                f"PR #{number} was labelled {CHANGES_LABEL} before the merge.",
            )
        else:
            set_outcome(
                report,
                "not_approved",
                f"PR #{number} lost {APPROVE_LABEL} before the merge.",
            )
        return True
    final_build_state = configured_check_state(pr, gates.required_ci_check)
    final_review_state = configured_check_state(pr, gates.required_review_check)
    final_detail = describe_check_gates(gates, final_build_state, final_review_state)
    if not check_gate_satisfied(final_build_state):
        log(f"PR #{number}: CI changed before merge; deferring")
        set_outcome(
            report,
            check_gate_reason(final_build_state, final_review_state),
            f"PR #{number}: its required CI check changed before the merge "
            f"({final_detail}).",
        )
        return True
    if not check_gate_satisfied(final_review_state):
        log(f"PR #{number}: review gate changed before merge; deferring")
        set_outcome(
            report,
            check_gate_reason(final_build_state, final_review_state),
            f"PR #{number}: its required review gate changed before the merge "
            f"({final_detail}).",
        )
        return True

    merged = merge_pr(ctx, pr, dry_run=dry_run, gates=gates, report=report)
    if not merged:
        set_outcome(
            report,
            "approved_head_changed",
            f"PR #{number}: its head moved away from the approved commit "
            f"{pr['headRefOid'][:12]} during the merge; it needs a fresh review.",
        )
        return True

    if dry_run:
        # Records nothing and mutates nothing, exactly as before: the pass only
        # reports what a real run would clean up.
        set_outcome(
            report,
            "would_merge",
            f"PR #{number} passed every gate; a real run would merge "
            f"{pr['headRefOid'][:12]}.",
        )
        run_cleanup_pass(ctx, plan_cleanup(pr), dry_run=True)
        return True

    # merge_pr() recorded the merged outcome the instant GitHub accepted it,
    # so everything that can still go wrong below reports merged=true.
    record = plan_cleanup(pr)

    # The merge is durable on GitHub the moment it returns, so record what it
    # still owes *before* attempting any of it. A cleanup step that fails after
    # this point is retried from the record; one that failed before it existed
    # left the merge looking like a PR that simply departed the queue, and its
    # issues, branches and worktree leaked silently.
    entry = state["prs"].get(str(number))
    if entry is None:
        # The queue always has an entry for a PR it selected; this only keeps a
        # merge from being lost to a caller that does not.
        remember_approved_head(state, number, pr["headRefOid"])
        entry = state["prs"][str(number)]
    entry["cleanup"] = record
    save_drain_state(ctx, state, dry_run=dry_run)

    outstanding: list[dict[str, Any]] = []
    if complete_pending_cleanup(ctx, state, number, dry_run=dry_run):
        forget_pr(state, number)
    else:
        entry = state["prs"].get(str(number)) or {}
        outstanding = (entry.get("cleanup") or {}).get("pending") or []
    # Persist what the pass achieved rather than leaving it to the caller: the
    # obligations that remain are the ones the next cycle must retry.
    save_drain_state(ctx, state, dry_run=dry_run)
    if outstanding:
        # The queue treats this as an ordinary debt to retry next cycle. A
        # single caller cannot wait for a next cycle, so it is told the merge
        # landed and what it still owes -- recorded only once the debt is
        # durably persisted above.
        steps = ", ".join(describe_cleanup_obligation(item) for item in outstanding)
        set_outcome(
            report,
            "post_merge_cleanup_failed",
            f"PR #{number} merged, but its post-merge cleanup is still "
            f"outstanding ({steps}). The drainer keeps retrying it.",
            merged=True,
        )
    return True


def lock_path_for(root: Path) -> Path:
    return root / ".git" / "drain_prs.lock"


def lock_owner_path_for(root: Path) -> Path:
    return root / ".git" / "drain_prs.lock.owner.json"


def lock_file_is_held(root: Path) -> bool:
    """Whether some process holds the lock file, probed without writing.

    Taking a lock we immediately drop leaves nothing behind, and an absent or
    unreadable file cannot be held by anyone.
    """
    try:
        fd = os.open(lock_path_for(root), os.O_RDONLY)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return True
    except OSError:
        return False
    finally:
        # Closing releases whatever this probe just took.
        os.close(fd)
    return False


def describe_lock_holder(root: Path, *, self_holds_lock_file: bool = False) -> str:
    """Name the run that holds the repository lock, as precisely as it can.

    Which *kind* of run it is comes from which locks it holds, never from
    anything it has written, so the answer is settled atomically by the lock
    acquisition itself. A real run takes the lock file and then the `.git`
    directory; a dry run takes the directory alone, because writing is the
    one thing it must not do. Holding the directory without the file is
    therefore a dry run, with no window in which a starting real run could be
    mistaken for one.

    Only the finer detail -- the PID, the mode, the pull request -- is read
    from what the holder published, and a run reports itself as starting
    rather than guessing when it has not published yet. The lock file holds
    the bare PID because drain_prs_service.lock_pid() and
    install_drainer.repository_drainer_running() read it that way; the mode
    lives in a sidecar, trusted only when it names that same live PID.
    """
    # `self_holds_lock_file` says this process already holds the lock file and
    # lost the directory, so the holder it is describing is by definition one
    # that does not hold the file -- probing would only rediscover ourselves.
    if self_holds_lock_file or not lock_file_is_held(root):
        return "a dry-run inspection, which takes the repository without writing to it"
    pid = drain_prs_service.lock_pid(root)
    if pid is None or not drain_prs_service.pid_alive(pid):
        return "another drain_prs.py run that is still starting up"
    owner: Any = None
    try:
        owner = json.loads(lock_owner_path_for(root).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        owner = None
    if not isinstance(owner, dict) or owner.get("pid") != pid:
        return f"another drain_prs.py run (pid {pid})"
    if owner.get("mode") == "single-pr":
        return f"a single-PR run for PR #{owner.get('pull_request')} (pid {pid})"
    return f"the polling drainer (pid {pid})"


class RunLock:
    """The repository's exclusive run lock, held for the process's lifetime."""

    def __init__(self, fds: list[int]):
        self._fds = fds

    def close(self) -> None:
        # Released in reverse acquisition order, and never allowed to raise:
        # this runs while the process is already on its way out.
        for fd in reversed(self._fds):
            try:
                os.close(fd)
            except OSError:
                pass
        self._fds = []


def _take_flock(fd: int, root: Path, *, self_holds_lock_file: bool = False) -> int:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        os.close(fd)
        holder = describe_lock_holder(
            root, self_holds_lock_file=self_holds_lock_file
        )
        raise RunLockedError(
            f"Another drain_prs.py instance is already running for {root}: "
            f"{holder} holds the lock."
        ) from exc
    except OSError as exc:
        os.close(fd)
        raise DrainError(f"Could not lock {root} for a drainer run: {exc}") from exc
    return fd


def _publish_lock_owner(
    fd: int, root: Path, mode: str, pull_request: int | None
) -> None:
    """Publish who holds the lock, for a contender and for the controller."""
    # The lock file holds nothing but the bare PID, because
    # drain_prs_service.lock_pid() and
    # install_drainer.repository_drainer_running() both parse it that way.
    os.ftruncate(fd, 0)
    os.lseek(fd, 0, os.SEEK_SET)
    os.write(fd, str(os.getpid()).encode("utf-8"))
    owner_path = lock_owner_path_for(root)
    tmp_fd, tmp_name = tempfile.mkstemp(
        prefix=f"{owner_path.name}.", dir=owner_path.parent
    )
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as owner_handle:
            json.dump(
                {"pid": os.getpid(), "mode": mode, "pull_request": pull_request},
                owner_handle,
                sort_keys=True,
            )
            owner_handle.write("\n")
        tmp_path.replace(owner_path)
    except BaseException:
        tmp_path.unlink(missing_ok=True)
        raise


def acquire_lock(
    root: Path,
    *,
    mode: str = "polling",
    pull_request: int | None = None,
    dry_run: bool = False,
) -> RunLock:
    """Take the repository's exclusive run lock, or refuse naming the holder.

    One lock covers both modes, so a single-PR run and the polling service can
    never act on the same repository at once: whichever starts second fails
    here rather than proceeding.

    The `.git` directory is the rendezvous that always exists, which is what
    lets a dry run -- which must create nothing at all -- still exclude a
    concurrent run and be excluded by one, even in a repository where no lock
    file has ever been written.

    Which locks each mode takes is also how a contender tells them apart, so
    the order is part of the contract, not an implementation detail. A real
    run takes the lock file first and the directory second, so from the moment
    it holds the directory it has always held the file too. A dry run takes
    the directory alone. Holding the directory without the file therefore
    means a dry run, at every instant, with nothing written and no startup
    window in which the two could be confused.

    The cost is that a dry run no longer collides with a drainer still running
    from an older version of this script, which locks only the file. That
    exclusion protected nothing: a dry run mutates nothing, so the worst a
    concurrent old run can do to it is make its report a moment stale.
    """
    held: list[int] = []
    try:
        if dry_run:
            held.append(_take_flock(os.open(root / ".git", os.O_RDONLY), root))
            return RunLock(held)
        # Opened without O_TRUNC and rewritten only after the lock is won: a
        # losing contender must never erase the PID of the holder it is about
        # to report.
        lock_fd = _take_flock(
            os.open(lock_path_for(root), os.O_RDWR | os.O_CREAT, 0o644), root
        )
        held.append(lock_fd)
        held.append(
            _take_flock(
                os.open(root / ".git", os.O_RDONLY), root, self_holds_lock_file=True
            )
        )
        # Published only once both locks are held, so a run that loses the
        # second one never leaves its identity behind as the holder's.
        _publish_lock_owner(lock_fd, root, mode, pull_request)
        return RunLock(held)
    except BaseException:
        RunLock(held).close()
        raise


def attempt_candidate(
    ctx: RepoContext,
    number: int,
    *,
    state: dict[str, Any],
    gates: GateConfig,
    dry_run: bool,
) -> str:
    """Give one candidate its turn and classify what it did to the pass.

    The report is the same one a single-PR run fills in, so the queue reads its
    decisions off process_pr()'s own vocabulary rather than re-deriving them
    from a bare True/False that cannot tell a skippable block from a merge.
    """
    report = new_single_pr_report(number)
    raised = False
    try:
        process_pr(
            ctx,
            number,
            dry_run=dry_run,
            state=state,
            gates=gates,
            report=report,
        )
    except (ModelUnavailableError, PostMergeAuditError):
        raise
    except DrainError as exc:
        raised = True
        report["message"] = str(exc)
    outcome = classify_pass_outcome(report["reason"], raised=raised)
    if raised:
        cooldown = record_pr_failure(state, number, report["message"])
        failure_count = state["prs"][str(number)]["consecutive_failures"]
        if cooldown:
            log(
                f"PR #{number}: attempt failed ({failure_count} consecutive); "
                f"skipping it for {cooldown} more pass(es): {report['message']}"
            )
        else:
            log(
                f"PR #{number}: attempt failed ({failure_count} consecutive); "
                f"the next pass looks at it again: {report['message']}"
            )
    else:
        record_pr_success(state, number)
    return outcome


def run_drain_pass(
    ctx: RepoContext,
    eligible: list[dict[str, Any]],
    *,
    state: dict[str, Any],
    gates: GateConfig,
    dry_run: bool,
) -> None:
    """Advance at most one candidate, walking the queue lowest number first.

    A candidate that cannot be advanced right now and says nothing about the
    ones behind it is skipped, and the same pass continues. A candidate with
    work in flight -- a branch update, a requested CI rerun, a check still
    running -- is a barrier: it owns the active lane, and no later pull request
    is updated, rerun, or merged until it releases it. Anything this pass
    cannot classify ends it where it stands.
    """
    by_number = {pr["number"]: pr for pr in eligible}
    active = state.get("active_pr")
    if active is not None and active not in by_number:
        log(
            f"PR #{active}: no longer an eligible candidate; "
            "releasing the active lane"
        )
        state["active_pr"] = None
        active = None

    for number in pass_candidate_order(eligible, active):
        blocked = candidate_block_reason(by_number[number], state)
        if blocked is not None:
            entry = state["prs"][str(number)]
            if blocked == "ci_rerun_exhausted":
                log(
                    f"PR #{number}: its required CI check stayed failed through "
                    "every automatic rerun of this head; skipping it"
                )
            else:
                log(
                    f"PR #{number}: cooling down after "
                    f"{entry.get('consecutive_failures', 0)} consecutive "
                    f"failure(s) until pass {entry.get('retry_after_attempt')}; "
                    "skipping it"
                )
            if state.get("active_pr") == number:
                state["active_pr"] = None
            continue

        attempt = begin_pr_attempt(state, number)
        log(f"Processing PR #{number} (pass {attempt})")
        save_drain_state(ctx, state, dry_run=dry_run)
        outcome = attempt_candidate(
            ctx, number, state=state, gates=gates, dry_run=dry_run
        )
        if outcome == PASS_SKIP:
            if state.get("active_pr") == number:
                state["active_pr"] = None
            save_drain_state(ctx, state, dry_run=dry_run)
            continue
        if outcome in (PASS_ADVANCE_HOLD, PASS_BARRIER):
            state["active_pr"] = number
        elif outcome == PASS_ADVANCE_DONE:
            state["active_pr"] = None
        # A pass failure leaves the lane exactly as it stands: nothing about it
        # says the candidate holding it has been released.
        save_drain_state(ctx, state, dry_run=dry_run)
        return

    save_drain_state(ctx, state, dry_run=dry_run)


def loop(
    ctx: RepoContext,
    *,
    interval: int,
    once: bool,
    dry_run: bool,
    gates: GateConfig,
) -> None:
    # The repository run lock is taken by main() before anything reads or
    # writes, so both this queue loop and a single-PR run are covered by the
    # same one acquisition.
    state = load_drain_state(ctx)
    stale_recovery_failures = 0
    queue_refresh_failures = 0
    while True:
        reconcile_conflict_incidents(ctx, dry_run=dry_run)
        try:
            recovered = recover_stale_approval(ctx, state, dry_run=dry_run)
        except ModelUnavailableError:
            raise
        except DrainError as exc:
            if once:
                raise
            stale_recovery_failures += 1
            if stale_recovery_failures >= MAX_CONSECUTIVE_GLOBAL_FAILURES:
                raise DrainError(
                    "Stale-approval recovery failed "
                    f"{stale_recovery_failures} consecutive times: {exc}"
                ) from exc
            log(
                "Stale-approval recovery failed "
                f"({stale_recovery_failures}/{MAX_CONSECUTIVE_GLOBAL_FAILURES}); "
                f"will retry: {exc}"
            )
            time.sleep(interval)
            continue
        else:
            stale_recovery_failures = 0
        save_drain_state(ctx, state, dry_run=dry_run)

        try:
            approved = get_open_approved_prs(ctx, dry_run=dry_run)
        except DrainError as exc:
            if once:
                raise
            queue_refresh_failures += 1
            if queue_refresh_failures >= MAX_CONSECUTIVE_GLOBAL_FAILURES:
                raise DrainError(
                    "Failed to refresh the PR queue "
                    f"{queue_refresh_failures} consecutive times: {exc}"
                ) from exc
            log(
                "Failed to refresh the PR queue "
                f"({queue_refresh_failures}/{MAX_CONSECUTIVE_GLOBAL_FAILURES}); "
                f"will retry: {exc}"
            )
            time.sleep(interval)
            continue
        else:
            queue_refresh_failures = 0
        eligible: list[dict[str, Any]] = []
        for pr in approved:
            key = str(pr["number"])
            entry = state["prs"].get(key)
            if entry is None:
                remember_approved_head(state, pr["number"], pr["headRefOid"])
                eligible.append(pr)
            elif entry["approved_head"] == pr["headRefOid"]:
                eligible.append(pr)
            else:
                log(
                    f"PR #{pr['number']}: approved label is still attached to "
                    "an unexpected new head; waiting for invalidation"
                )
        save_drain_state(ctx, state, dry_run=dry_run)

        # Advanced once per pass, including a pass that recovers or skips
        # everything, because it is the clock every failure cooldown is
        # denominated in.
        begin_drain_pass(state)
        if recovered:
            save_drain_state(ctx, state, dry_run=dry_run)
        else:
            run_drain_pass(ctx, eligible, state=state, gates=gates, dry_run=dry_run)
        if once:
            return
        # The short cadence follows the lane rather than the last candidate
        # examined: a pass can end on a barrier owned by an earlier one.
        active = state.get("active_pr")
        active_entry = state["prs"].get(str(active)) if active is not None else None
        sleep_seconds = (
            CI_RERUN_INTERVAL_SECONDS
            if active_entry and active_entry.get("ci_rerun_active")
            else interval
        )
        time.sleep(sleep_seconds)


def single_pr_result(
    number: int,
    reason: str,
    message: str,
    *,
    merged: bool = False,
    dry_run: bool = False,
) -> dict[str, Any]:
    """The one JSON document a single-PR run writes to stdout."""
    if reason in ERROR_REASONS:
        outcome = "error"
    elif reason == "merged":
        outcome = "merged"
    else:
        outcome = "no_action"
    return {
        "schema": SINGLE_PR_SCHEMA,
        "version": SINGLE_PR_SCHEMA_VERSION,
        "pull_request": number,
        "outcome": outcome,
        "merged": merged,
        # True exactly when every gate passed and merging was this run's
        # action -- performed for a real run, withheld for a dry one.
        "would_merge": reason in {"merged", "would_merge"},
        "reason": reason,
        "message": message,
        "dry_run": dry_run,
    }


def single_pr_exit_code(result: dict[str, Any]) -> int:
    if result["outcome"] == "error":
        return EXIT_ERROR
    if result["outcome"] == "merged":
        return EXIT_MERGED
    return EXIT_NO_ACTION


def emit_single_pr_result(result: dict[str, Any]) -> "NoReturn":
    # stdout carries this document and nothing else; every human diagnostic
    # went to stderr and the log file.
    print(json.dumps(result, sort_keys=True), flush=True)
    raise SystemExit(single_pr_exit_code(result))


def prepare_single_pr(
    ctx: RepoContext,
    number: int,
    state: dict[str, Any],
    *,
    dry_run: bool,
    report: dict[str, Any],
) -> bool:
    """Apply the queue's per-PR safeguards to one named PR.

    These live in the queue loop rather than in process_pr(), so a caller that
    went straight to process_pr() would merge things the queue would refuse.
    Only the named PR is read and only its own state entry is touched: no
    other PR is enumerated or recovered, no pass counter moves, and neither the
    queue's candidate order nor its active lane is consulted or changed, so
    polling order and per-PR failure cooldowns are exactly as the service left
    them.
    """
    pr = get_pr(ctx, number)
    if pr["state"] != "OPEN":
        set_outcome(
            report,
            "not_eligible",
            f"PR #{number} is no longer open (state {pr['state']}).",
        )
        return False
    if has_label(pr, CHANGES_LABEL):
        set_outcome(
            report, "changes_requested", f"PR #{number} is labelled {CHANGES_LABEL}."
        )
        return False
    if not has_label(pr, APPROVE_LABEL):
        set_outcome(
            report, "not_approved", f"PR #{number} is not labelled {APPROVE_LABEL}."
        )
        return False

    if pr.get("isDraft"):
        if dry_run:
            log(
                f"PR #{number}: approved but still a draft; "
                "would mark it ready for review"
            )
        else:
            log(
                f"PR #{number}: approved but still a draft; "
                "marking it ready for review"
            )
            run(
                ["gh", "pr", "ready", str(number), "--repo", ctx.repo_slug],
                cwd=ctx.path,
            )

    entry = state["prs"].get(str(number))
    if entry is None:
        remember_approved_head(state, number, pr["headRefOid"])
    elif entry["approved_head"] != pr["headRefOid"]:
        log(
            f"PR #{number}: approved label is still attached to an unexpected "
            "new head; waiting for invalidation"
        )
        set_outcome(
            report,
            "approved_head_changed",
            f"PR #{number} still carries {APPROVE_LABEL} on head "
            f"{pr['headRefOid'][:12]}, which is not the approved head "
            f"{entry['approved_head'][:12]}; it needs a fresh review.",
        )
        return False
    return True


def new_single_pr_report(number: int | None) -> dict[str, Any]:
    """The mutable record a single-PR run fills in as it decides.

    Owned by main() rather than by drain_one_pr(), so that whatever ends the
    run -- an interrupt in the final state write included -- the result still
    reports what was already known, above all a merge that landed.
    """
    return {
        "reason": "operational_error",
        "message": f"PR #{number}: the run ended without recording an outcome.",
        "merged": False,
        # An interrupt this run swallowed to keep its result document. It is
        # recorded rather than inferred from the message, because it is what
        # tells main() a stop happened and still owes its final cleanup pass.
        "interrupted": False,
    }


def drain_one_pr(
    ctx: RepoContext,
    number: int,
    *,
    dry_run: bool,
    gates: GateConfig,
    report: dict[str, Any],
) -> dict[str, Any]:
    """Process exactly one pull request and describe what happened.

    Runs the same gates, guards, ordering and post-merge audit as a queue
    cycle -- it is the queue's own process_pr(), not a second implementation
    of it -- and merges nothing the queue would refuse.
    """
    # Stays None until the queue state is read back successfully, so a state
    # file this run could not parse is reported rather than overwritten with
    # an empty one -- it holds other PRs' cooldowns and unfinished cleanups.
    state: dict[str, Any] | None = None
    try:
        state = load_drain_state(ctx)
        if prepare_single_pr(ctx, number, state, dry_run=dry_run, report=report):
            process_pr(
                ctx,
                number,
                dry_run=dry_run,
                state=state,
                gates=gates,
                report=report,
            )
    except PostMergeAuditError as exc:
        # The merge landed on GitHub before the audit read it back, so the
        # caller is told both: it failed, and the PR is merged regardless.
        report["reason"] = "post_merge_audit_failed"
        report["message"] = str(exc)
        report["merged"] = True
    except DrainError as exc:
        # A refusal process_pr() classified on its way out keeps that
        # classification; anything else is an operational failure.
        if report["reason"] not in NO_ACTION_REASONS:
            report["reason"] = "operational_error"
            report["message"] = str(exc)
    except OSError as exc:
        report["reason"] = "operational_error"
        report["message"] = f"PR #{number}: {exc}"
    except KeyboardInterrupt:
        # Swallowed rather than propagated so the caller still gets its one
        # JSON result. Whatever was already recorded stands -- above all a
        # merge that landed before the interrupt arrived. Swallowing it also
        # means main()'s interrupt handler never sees this stop, so it is
        # recorded here for the caller that owes the final cleanup pass.
        report["interrupted"] = True
        report["reason"] = "operational_error"
        report["message"] = f"PR #{number}: interrupted before the run finished."

    # Persisted last and separately so a state-write failure can never mask
    # what already happened on GitHub -- above all a merge that landed.
    if state is not None:
        try:
            save_drain_state(ctx, state, dry_run=dry_run)
        except OSError as exc:
            if report["reason"] not in ERROR_REASONS:
                report["reason"] = "operational_error"
                report["message"] = (
                    f"PR #{number}: could not persist the drainer queue state: {exc}"
                )
        except KeyboardInterrupt:
            report["interrupted"] = True
            if report["reason"] not in ERROR_REASONS:
                report["reason"] = "operational_error"
                report["message"] = (
                    f"PR #{number}: interrupted while persisting the drainer "
                    "queue state."
                )
    return single_pr_result(
        number,
        report["reason"],
        report["message"],
        merged=report["merged"],
        dry_run=dry_run,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Drain approved PRs for a repository using the configured "
            "finalize policy."
        )
    )
    parser.add_argument(
        "--path",
        required=True,
        help="Path to the main checkout of the repository to drain.",
    )
    parser.add_argument(
        "--repo",
        default=None,
        metavar="OWNER/NAME",
        help=(
            "Assert the repository --path is a checkout of; the run is refused "
            "if the checkout's remote names another one."
        ),
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=DEFAULT_INTERVAL_SECONDS,
        help=f"Polling interval in seconds (default: {DEFAULT_INTERVAL_SECONDS}).",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--once",
        action="store_true",
        help="Run a single poll cycle and exit.",
    )
    mode.add_argument(
        "--pr",
        type=int,
        default=None,
        metavar="NUMBER",
        help=(
            "Process exactly this pull request and exit, writing one JSON "
            "result to stdout (exit 0 merged, 2 no action, 1 error)."
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print intended actions without mutating GitHub or the local repo.",
    )
    parser.add_argument(
        "--log-dir",
        default=str(Path(__file__).resolve().parent / "drain_prs_logs"),
        help=(
            "Directory for date-based log files (default: drain_prs_logs "
            "beside the invoked script)."
        ),
    )
    parser.add_argument(
        "--config",
        default=None,
        help=(
            "Path to kanban's config.toml "
            "(default: ~/.config/kanban/config.toml)."
        ),
    )
    args = parser.parse_args()
    if args.pr is not None and args.pr <= 0:
        parser.error("--pr requires a positive pull request number")
    return args


def main() -> None:
    args = parse_args()
    global LOG_DIR, APPROVE_LABEL, CHANGES_LABEL, LOG_TO_STDERR
    number = args.pr
    single = number is not None
    # A single-PR run owns stdout for its one JSON result.
    LOG_TO_STDERR = single
    # A dry run leaves the filesystem exactly as it found it, so it opens no
    # log directory either.
    LOG_DIR = None if args.dry_run else Path(args.log_dir).expanduser().resolve()
    lock_handle = None
    # Bound before the try so the interrupt handler can tell a repository this
    # run never resolved from one it did: only the latter has a run lock held
    # and a queue state worth a final pass.
    ctx: RepoContext | None = None
    # Built before anything can fail, and handed to drain_one_pr() rather than
    # created inside it, so every handler below reports what was already known.
    report = new_single_pr_report(number)
    try:
        try:
            raw_config, config_warnings = kanban_config.load_raw_config(args.config)
            for warning in config_warnings:
                print(f"drain_prs.py warning: {warning}", file=sys.stderr, flush=True)
            # Locked as soon as the git directory is known, before any log
            # line, state read, or GitHub call: a losing contender must find
            # out that it cannot run before it does any of that work.
            root = repo_root(Path(args.path).expanduser().resolve())
            lock_handle = acquire_lock(
                root,
                mode="single-pr" if single else "polling",
                pull_request=number,
                dry_run=args.dry_run,
            )
            ctx = get_repo_context(root, raw_config.remote_name)
            # Before any label, gate, or pull request is read: a caller whose
            # repository this is not must find that out before this run acts
            # on a number that means something else here.
            require_requested_identity(ctx, args.repo)
            resolved_config = kanban_config.resolve_config(ctx.repo_slug, raw_config)
            APPROVE_LABEL = resolved_config.workflow.approval_label
            CHANGES_LABEL = resolved_config.workflow.changes_requested_label
            gates = load_gate_config(ctx)
            log(
                f"Watching {ctx.repo_slug} at {ctx.path} "
                f"(default branch: {ctx.default_branch})"
            )
            log(
                "Required checks: "
                f"{gates.required_ci_check or 'ci disabled'}, "
                f"{gates.required_review_check or 'review disabled'}"
            )
            log(f"Logging to {active_log_path() or 'stderr only (dry run)'}")
            if args.dry_run:
                log("Dry-run mode enabled; no changes will be made")
            # Once per process, on the seam both modes pass through, and
            # before either can merge or fast-forward: the sweep must never
            # run while a fast-forward's own autostash window is open.
            sweep_snapshot_anchors(ctx, dry_run=args.dry_run)
            if single:
                result = drain_one_pr(
                    ctx,
                    number,
                    dry_run=args.dry_run,
                    gates=gates,
                    report=report,
                )
                if report["interrupted"]:
                    # A real interrupt during a `--pr` run is caught inside
                    # drain_one_pr(), so the handler below never sees it --
                    # but the stop it signals owes the same final pass. Run it
                    # here, still holding the run lock, and still before the
                    # caller's one document reaches stdout.
                    discharge_recorded_cleanup(ctx, dry_run=args.dry_run)
                emit_single_pr_result(result)
            loop(
                ctx,
                interval=args.interval,
                once=args.once,
                dry_run=args.dry_run,
                gates=gates,
            )
        except RunLockedError as exc:
            if single:
                emit_single_pr_result(
                    single_pr_result(
                        number, "run_locked", str(exc), dry_run=args.dry_run
                    )
                )
            fail(f"drain_prs.py error: {exc}")
        except (DrainError, kanban_config.KanbanConfigError) as exc:
            # Everything reaching here failed before the pull request was
            # read: an unusable checkout, remote, or drainer configuration.
            if single:
                emit_single_pr_result(
                    single_pr_result(
                        number,
                        "repository_precondition_failed",
                        str(exc),
                        dry_run=args.dry_run,
                    )
                )
            fail(f"drain_prs.py error: {exc}")
        except OSError as exc:
            # An unwritable log directory or lock file fails before any pull
            # request is read. A single-PR caller must still get its result
            # document rather than a traceback and empty stdout.
            if single:
                emit_single_pr_result(
                    single_pr_result(
                        number,
                        "operational_error",
                        f"drain_prs.py could not start: {exc}",
                        merged=report["merged"],
                        dry_run=args.dry_run,
                    )
                )
            fail(f"drain_prs.py error: {exc}")
        except KeyboardInterrupt:
            # The intentional-stop path, for both modes: the launchd runner
            # forwards SIGINT to this process group, and `stop_service` sends
            # the same signal straight to an unmanaged drainer. The run lock is
            # still held here, so this is the last moment anything can work
            # what a merge already recorded -- and the first thing after it is
            # the caller's own result document, which the pass must never
            # write to or displace, so it goes first and speaks only to stderr.
            if ctx is not None:
                discharge_recorded_cleanup(ctx, dry_run=args.dry_run)
            if single:
                emit_single_pr_result(
                    single_pr_result(
                        number,
                        "operational_error",
                        f"PR #{number}: interrupted before the run finished.",
                        merged=report["merged"],
                        dry_run=args.dry_run,
                    )
                )
            log("Interrupted; exiting")
        except Exception as exc:
            # Last resort. A `--pr` caller is promised one JSON document on
            # stdout, so even an unanticipated failure is reported there
            # rather than as a traceback over an empty stdout. The polling
            # service keeps raising: its supervisor records the crash, and
            # the traceback is the diagnosis.
            if not single:
                raise
            emit_single_pr_result(
                single_pr_result(
                    number,
                    "operational_error",
                    f"drain_prs.py failed unexpectedly: {exc!r}",
                    merged=report["merged"],
                    dry_run=args.dry_run,
                )
            )
    finally:
        if lock_handle is not None:
            lock_handle.close()


if __name__ == "__main__":
    main()
