#!/usr/bin/env python3

from __future__ import annotations

import argparse
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
from dataclasses import dataclass
from pathlib import Path
from typing import Any, NoReturn

import drain_prs_service
import kanban_config


APPROVE_LABEL = "reviewed:approve"
CHANGES_LABEL = "reviewed:changes"
DEFAULT_REQUIRED_CI_CHECK = "build-test"
DEFAULT_REQUIRED_REVIEW_CHECK = "review-approved"
CONFIG_FILENAME = ".drain-prs.json"
STALE_APPROVAL_CHECK = "dismiss-stale-approval"
DEFAULT_INTERVAL_SECONDS = 300
UPDATE_BRANCH_WAIT_SECONDS = 180
UPDATE_BRANCH_POLL_SECONDS = 3
MODEL_TIMEOUT_SECONDS = 60 * 60
STATE_VERSION = 2
FAILURES_BEFORE_BACKOFF = 2
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


class DrainError(RuntimeError):
    pass


class ModelUnavailableError(DrainError):
    pass


class PostMergeAuditError(DrainError):
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
    print(line, flush=True)
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
    append_log_line(message)
    raise SystemExit(1)


def run(
    args: list[str],
    *,
    cwd: Path,
    check: bool = True,
    capture_output: bool = True,
    input_text: str | None = None,
    timeout: int | None = None,
) -> subprocess.CompletedProcess[str]:
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


def require_clean_worktree(root: Path) -> None:
    proc = run(
        ["git", "status", "--porcelain=v1", "--untracked-files=all"],
        cwd=root,
    )
    status = (proc.stdout or "").strip()
    if status:
        raise DrainError(
            "Refusing to start PR drainer: repository has uncommitted changes. "
            "Commit, stash, or discard them first.\n"
            + status
        )


def parse_repo_slug(remote_url: str) -> str:
    try:
        return kanban_config.parse_repository_name(remote_url)
    except kanban_config.KanbanConfigError as exc:
        raise DrainError(f"Unsupported remote URL: {remote_url}") from exc


def get_repo_context(path: Path, remote_name: str = "origin") -> RepoContext:
    root = repo_root(path)
    require_clean_worktree(root)
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


def migrate_drain_state(state: dict[str, Any], *, source: str) -> dict[str, Any]:
    if not isinstance(state.get("prs"), dict):
        raise DrainError(f"Unsupported drain state in {source}; inspect or remove it.")
    if state.get("version") == 1:
        state["version"] = STATE_VERSION
        state["attempt_counter"] = 0
    elif state.get("version") != STATE_VERSION:
        raise DrainError(f"Unsupported drain state in {source}; inspect or remove it.")
    state.setdefault("attempt_counter", 0)
    for entry in state["prs"].values():
        entry.setdefault("consecutive_failures", 0)
        entry.setdefault("retry_after_attempt", 0)
        entry.setdefault("last_attempt", 0)
        entry.setdefault("last_error", None)
    return state


def load_drain_state(ctx: RepoContext) -> dict[str, Any]:
    path = drain_state_path(ctx)
    if not path.exists():
        return {"version": STATE_VERSION, "attempt_counter": 0, "prs": {}}
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
    }


def forget_pr(state: dict[str, Any], number: int) -> None:
    state["prs"].pop(str(number), None)


def failure_backoff_attempts(consecutive_failures: int) -> int:
    if consecutive_failures < FAILURES_BEFORE_BACKOFF:
        return 0
    exponent = consecutive_failures - FAILURES_BEFORE_BACKOFF
    return min(2**exponent, MAX_BACKOFF_ATTEMPTS)


def begin_pr_attempt(state: dict[str, Any], number: int) -> int:
    state["attempt_counter"] += 1
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
    entry["retry_after_attempt"] = state["attempt_counter"] + cooldown
    entry["last_error"] = error
    return cooldown


def choose_next_pr(
    approved: list[dict[str, Any]],
    state: dict[str, Any],
) -> tuple[dict[str, Any] | None, bool]:
    if not approved:
        return None, False

    attempt_counter = state["attempt_counter"]
    ready = [
        pr
        for pr in approved
        if state["prs"][str(pr["number"])]["retry_after_attempt"]
        <= attempt_counter
    ]
    if ready:
        return (
            min(
                ready,
                key=lambda pr: (
                    state["prs"][str(pr["number"])]["last_attempt"],
                    pr["number"],
                ),
            ),
            False,
        )

    # Every remaining PR is cooling down. Probe the one due soonest rather
    # than idling forever; repeated failures rotate naturally as each retry
    # pushes that PR's next-attempt counter farther out.
    return (
        min(
            approved,
            key=lambda pr: (
                state["prs"][str(pr["number"])]["retry_after_attempt"],
                state["prs"][str(pr["number"])]["last_attempt"],
                pr["number"],
            ),
        ),
        True,
    )


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
    ctx: RepoContext, pr: dict[str, Any], *, dry_run: bool, gates: GateConfig
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


def close_linked_issues(
    ctx: RepoContext,
    pr: dict[str, Any],
    *,
    dry_run: bool,
) -> None:
    for issue in pr.get("closingIssuesReferences", []):
        number = issue["number"]
        repo_slug = f'{issue["repository"]["owner"]["login"]}/{issue["repository"]["name"]}'
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
            continue
        log(f"Closing linked issue {repo_slug}#{number}")
        if dry_run:
            continue
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
        pr = get_pr(ctx, number)

        if pr["state"] != "OPEN":
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
    if proc.returncode != 0:
        return
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
    if proc.returncode != 0:
        return
    log(f"Deleting remote branch {branch}")
    if dry_run:
        return
    run(["git", "push", ctx.remote_name, "--delete", branch], cwd=ctx.path)


def _git_dir(ctx: RepoContext) -> Path:
    # Not ctx.path / ".git": for a linked worktree that's a gitdir *file*
    # (a pointer to .git/worktrees/<name>), not a directory, so mkdtemp()
    # under it would fail outright. This resolves the real one either way.
    proc = run(["git", "rev-parse", "--absolute-git-dir"], cwd=ctx.path, check=False)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or f"exit code {proc.returncode}").strip()
        raise DrainError(f"Could not resolve the git directory for {ctx.path}:\n{detail}")
    return Path((proc.stdout or "").strip())


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
    holding = Path(tempfile.mkdtemp(prefix="autostash-", dir=str(_git_dir(ctx))))
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


def fast_forward_default_branch(
    ctx: RepoContext,
    *,
    dry_run: bool,
) -> None:
    log(f"Fast-forwarding local {ctx.default_branch}")
    if dry_run:
        return

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


def cleanup_after_merge(
    ctx: RepoContext,
    pr: dict[str, Any],
    *,
    dry_run: bool,
) -> None:
    close_linked_issues(ctx, pr, dry_run=dry_run)
    worktree = find_matching_worktree(ctx, pr)
    if worktree is not None:
        remove_worktree(ctx, worktree, dry_run=dry_run)
    else:
        log(f"PR #{pr['number']}: no matching local worktree found")
    delete_local_branch(ctx, pr["headRefName"], dry_run=dry_run)
    delete_remote_branch(ctx, pr["headRefName"], dry_run=dry_run)
    fast_forward_default_branch(ctx, dry_run=dry_run)


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


def process_pr(
    ctx: RepoContext,
    number: int,
    *,
    dry_run: bool,
    state: dict[str, Any],
    gates: GateConfig,
) -> bool:
    pr = get_pr(ctx, number)

    if pr["state"] != "OPEN":
        log(f"PR #{number}: no longer open; skipping")
        return False
    if pr.get("isDraft"):
        log(f"PR #{number}: draft; skipping")
        return False
    if pr["baseRefName"] != ctx.default_branch:
        raise DrainError(
            f"PR #{number} targets {pr['baseRefName']}, not {ctx.default_branch}."
        )
    if not has_label(pr, APPROVE_LABEL) or has_label(pr, CHANGES_LABEL):
        log(f"PR #{number}: no longer approved; skipping")
        return False

    mergeable = pr.get("mergeable")
    merge_state = pr.get("mergeStateStatus")
    if mergeable == "CONFLICTING" or merge_state == "DIRTY":
        # A blocked outcome for this PR alone, not a drainer failure: the queue
        # loop records no failure and applies no cooldown, so every other
        # approved PR keeps draining in the same run.
        record_merge_conflict(ctx, pr, dry_run=dry_run)
        return False

    if merge_state == "BEHIND":
        update_branch(ctx, pr, dry_run=dry_run)
        if not dry_run:
            refreshed = get_pr(ctx, number)
            if has_label(refreshed, APPROVE_LABEL):
                remember_approved_head(state, number, refreshed["headRefOid"])
        return True

    build_state = configured_check_state(pr, gates.required_ci_check)
    review_state = configured_check_state(pr, gates.required_review_check)

    if build_state == "failure":
        raise DrainError(
            f"PR #{number}: required CI check {gates.required_ci_check} failed."
        )
    if review_state == "failure":
        raise DrainError(
            f"PR #{number}: required review gate "
            f"{gates.required_review_check} failed."
        )

    if not check_gate_satisfied(build_state) or not check_gate_satisfied(review_state):
        log(
            f"PR #{number}: waiting "
            f"({render_check_gate('ci', gates.required_ci_check, build_state)}, "
            f"{render_check_gate('review', gates.required_review_check, review_state)}, "
            f"mergeStateStatus={merge_state})"
        )
        return True

    if mergeable in {"UNKNOWN", None} or merge_state == "UNKNOWN":
        log(f"PR #{number}: mergeability still computing; waiting")
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
        return True
    if not check_gate_satisfied(
        configured_check_state(pr, gates.required_ci_check)
    ):
        log(f"PR #{number}: CI changed before merge; deferring")
        return True
    if not check_gate_satisfied(
        configured_check_state(pr, gates.required_review_check)
    ):
        log(f"PR #{number}: review gate changed before merge; deferring")
        return True

    merged = merge_pr(ctx, pr, dry_run=dry_run, gates=gates)
    if not merged:
        return True
    cleanup_after_merge(ctx, pr, dry_run=dry_run)
    if not dry_run:
        forget_pr(state, number)
    return True


def acquire_lock(ctx: RepoContext):
    lock_path = ctx.path / ".git" / "drain_prs.lock"
    # Never truncate before flock: mode "w" erased the running instance's
    # recorded PID as soon as a second instance tried, destroying the only
    # record of who holds the lock the failed contender is reporting.
    handle = open(lock_path, "a+", encoding="utf-8")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        handle.close()
        raise DrainError(
            f"Another drain_prs.py instance is already running for {ctx.path}."
        ) from exc
    handle.seek(0)
    handle.truncate()
    handle.write(str(os.getpid()))
    handle.flush()
    return handle


def loop(
    ctx: RepoContext,
    *,
    interval: int,
    once: bool,
    dry_run: bool,
    gates: GateConfig,
) -> None:
    lock_handle = acquire_lock(ctx)
    state = load_drain_state(ctx)
    stale_recovery_failures = 0
    queue_refresh_failures = 0
    try:
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

            selected, probing_cooldown = choose_next_pr(eligible, state)
            if selected is not None and not recovered:
                number = selected["number"]
                attempt = begin_pr_attempt(state, number)
                entry = state["prs"][str(number)]
                failures = entry["consecutive_failures"]
                if probing_cooldown:
                    log(
                        f"All approved PRs are cooling down; probing PR #{number} "
                        f"after {failures} consecutive failure(s)"
                    )
                else:
                    log(f"Processing PR #{number} (queue attempt {attempt})")
                save_drain_state(ctx, state, dry_run=dry_run)
                try:
                    process_pr(
                        ctx,
                        number,
                        dry_run=dry_run,
                        state=state,
                        gates=gates,
                    )
                except (ModelUnavailableError, PostMergeAuditError):
                    raise
                except DrainError as exc:
                    cooldown = record_pr_failure(state, number, str(exc))
                    failure_count = state["prs"][str(number)][
                        "consecutive_failures"
                    ]
                    if cooldown:
                        log(
                            f"PR #{number}: attempt failed ({failure_count} consecutive); "
                            f"skipping it for {cooldown} other queue attempt(s): {exc}"
                        )
                    else:
                        log(
                            f"PR #{number}: attempt failed ({failure_count} consecutive); "
                            f"it remains in the fair rotation: {exc}"
                        )
                else:
                    record_pr_success(state, number)
                save_drain_state(ctx, state, dry_run=dry_run)
            if once:
                return
            time.sleep(interval)
    finally:
        lock_handle.close()


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
        "--interval",
        type=int,
        default=DEFAULT_INTERVAL_SECONDS,
        help=f"Polling interval in seconds (default: {DEFAULT_INTERVAL_SECONDS}).",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Run a single poll cycle and exit.",
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
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    global LOG_DIR, APPROVE_LABEL, CHANGES_LABEL
    LOG_DIR = Path(args.log_dir).expanduser().resolve()
    try:
        raw_config, config_warnings = kanban_config.load_raw_config(args.config)
        for warning in config_warnings:
            print(f"drain_prs.py warning: {warning}", file=sys.stderr, flush=True)
        ctx = get_repo_context(
            Path(args.path).expanduser().resolve(), raw_config.remote_name
        )
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
        log(f"Logging to {active_log_path()}")
        if args.dry_run:
            log("Dry-run mode enabled; no changes will be made")
        loop(
            ctx,
            interval=args.interval,
            once=args.once,
            dry_run=args.dry_run,
            gates=gates,
        )
    except DrainError as exc:
        fail(f"drain_prs.py error: {exc}")
    except kanban_config.KanbanConfigError as exc:
        fail(f"drain_prs.py error: {exc}")
    except KeyboardInterrupt:
        log("Interrupted; exiting")


if __name__ == "__main__":
    main()
