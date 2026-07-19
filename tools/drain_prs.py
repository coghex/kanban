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


APPROVE_LABEL = "reviewed:approve"
CHANGES_LABEL = "reviewed:changes"
DEFAULT_REQUIRED_CI_CHECK = "build-test"
DEFAULT_REQUIRED_REVIEW_CHECK = "review-approved"
CONFIG_FILENAME = ".drain-prs.json"
STALE_APPROVAL_CHECK = "dismiss-stale-approval"
DEFAULT_INTERVAL_SECONDS = 300
MAX_AUTO_REPAIR_CONFLICT_FILES = 2
MAX_CONFLICT_REVIEW_ROUNDS = 5
UPDATE_BRANCH_WAIT_SECONDS = 180
UPDATE_BRANCH_POLL_SECONDS = 3
MODEL_TIMEOUT_SECONDS = 60 * 60
STATE_VERSION = 2
FAILURES_BEFORE_BACKOFF = 2
MAX_BACKOFF_ATTEMPTS = 16
MAX_CONSECUTIVE_GLOBAL_FAILURES = 3
FINALIZE_MODEL = "gpt-5.6-terra"
FINALIZE_EFFORT = "medium"
CONFLICT_REVIEW_MODEL = os.environ.get(
    "DRAIN_PRS_CLAUDE_REVIEW_MODEL", "claude-opus-4-8"
)
CONFLICT_REVIEW_EFFORT = "xhigh"
NTFY_URL = os.environ.get("KANBAN_DRAINER_NTFY_URL")
PR_REVIEW_V1_RE = re.compile(
    r"<!--\s*pr-review:v1\s+reviewer=(claude|codex)\s+"
    r"head=([0-9a-fA-F]{40})\s+"
    r"verdict=(APPROVE|CHANGES_REQUESTED)\s*-->",
    re.IGNORECASE,
)
LEGACY_CODEX_REVIEW_RE = re.compile(
    r"<!--\s*codex-review\s+head=([0-9a-fA-F]{40})\s+"
    r"verdict=(APPROVE|CHANGES_REQUESTED)\s*-->",
    re.IGNORECASE,
)
TEXTLIKE_CONFLICT_EXTENSIONS = {
    ".c",
    ".cc",
    ".cpp",
    ".cabal",
    ".csv",
    ".go",
    ".h",
    ".hs",
    ".html",
    ".java",
    ".js",
    ".json",
    ".lua",
    ".md",
    ".py",
    ".rb",
    ".rs",
    ".sh",
    ".sql",
    ".toml",
    ".ts",
    ".tsx",
    ".txt",
    ".xml",
    ".yaml",
    ".yml",
}
LOG_DIR: Path | None = None


class DrainError(RuntimeError):
    pass


class ModelUnavailableError(DrainError):
    pass


@dataclass
class RepoContext:
    path: Path
    repo_slug: str
    repo_name: str
    default_branch: str


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


def parse_repo_slug(remote_url: str) -> str:
    remote_url = remote_url.strip()
    ssh_match = re.match(r"git@github\.com:([^/]+)/(.+?)(?:\.git)?$", remote_url)
    if ssh_match:
        return f"{ssh_match.group(1)}/{ssh_match.group(2)}"
    https_match = re.match(
        r"https://github\.com/([^/]+)/(.+?)(?:\.git)?$",
        remote_url,
    )
    if https_match:
        return f"{https_match.group(1)}/{https_match.group(2)}"
    raise DrainError(f"Unsupported origin remote URL: {remote_url}")


def get_repo_context(path: Path) -> RepoContext:
    root = repo_root(path)
    remote_url = run(["git", "remote", "get-url", "origin"], cwd=root).stdout.strip()
    repo_slug = parse_repo_slug(remote_url)
    repo_name = repo_slug.split("/", 1)[1]
    try:
        ref = run(
            ["git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
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
    data = run_json(
        [
            "gh",
            "pr",
            "view",
            str(number),
            "--repo",
            ctx.repo_slug,
            "--json",
            "comments",
        ],
        cwd=ctx.path,
    )
    comments = sorted(
        data.get("comments", []),
        key=lambda comment: comment.get("createdAt") or "",
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


def conflict_file_is_textlike(path: str) -> bool:
    suffix = Path(path).suffix.lower()
    return suffix in TEXTLIKE_CONFLICT_EXTENSIONS


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


def remove_approval_label(ctx: RepoContext, number: int) -> None:
    log(f"PR #{number}: removing stale {APPROVE_LABEL} before conflict repair")
    run(
        [
            "gh",
            "pr",
            "edit",
            str(number),
            "--repo",
            ctx.repo_slug,
            "--remove-label",
            APPROVE_LABEL,
        ],
        cwd=ctx.path,
    )
    refreshed = get_pr(ctx, number)
    if has_label(refreshed, APPROVE_LABEL):
        raise DrainError(
            f"PR #{number}: failed to remove stale {APPROVE_LABEL!r} "
            "before conflict repair."
        )


def remove_approval_label_if_present(ctx: RepoContext, number: int) -> None:
    refreshed = get_pr(ctx, number)
    if not has_label(refreshed, APPROVE_LABEL):
        return
    remove_approval_label(ctx, number)


def mark_changes_requested(ctx: RepoContext, number: int) -> None:
    refreshed = get_pr(ctx, number)
    args = [
        "gh",
        "pr",
        "edit",
        str(number),
        "--repo",
        ctx.repo_slug,
    ]
    if has_label(refreshed, APPROVE_LABEL):
        args.extend(["--remove-label", APPROVE_LABEL])
    if not has_label(refreshed, CHANGES_LABEL):
        args.extend(["--add-label", CHANGES_LABEL])
    if len(args) > 7:
        run(args, cwd=ctx.path)
    refreshed = get_pr(ctx, number)
    if has_label(refreshed, APPROVE_LABEL) or not has_label(
        refreshed, CHANGES_LABEL
    ):
        raise DrainError(
            f"PR #{number}: failed to leave exactly {CHANGES_LABEL!r} after "
            "conflict repair stopped."
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


def merge_pr(ctx: RepoContext, pr: dict[str, Any], *, dry_run: bool) -> bool:
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
) -> tuple[Path, bool]:
    existing = find_matching_worktree(ctx, pr)
    if existing is not None:
        return existing, False

    tmpdir = Path(
        tempfile.mkdtemp(prefix=f"drain-prs-rereview-{pr['number']}-", dir="/private/tmp")
    )
    run(["git", "fetch", "--quiet", "origin", pr["headRefName"]], cwd=ctx.path)
    run(
        [
            "git",
            "worktree",
            "add",
            "--detach",
            str(tmpdir),
            f"origin/{pr['headRefName']}",
        ],
        cwd=ctx.path,
    )
    return tmpdir, True


def drain_rereview_prompt(number: int, expected_head: str) -> str:
    return f"""You are GPT-5.6-Terra, the final drain-queue reviewer for PR #{number}.

The queue detected an unexpected push after approval. Review only: do not edit files, commit, push, merge, close issues, or remove worktrees.

1. Fetch `headRefOid` and require it to equal {expected_head}; otherwise report a stale request and do not comment or label.
2. Read the linked issue and authoritative comments, PR body, checks, latest prior `<!-- pr-review:v1 ... -->` comment (or legacy `<!-- codex-review ... -->` comment), new commits, and full merge-base diff.
3. For every prior blocking concern, state Resolved, Partially resolved, or Unresolved with file/line evidence. Review the complete current diff for regressions and unmet issue requirements. Nits never block.
4. Re-fetch the head before publishing. If it changed, do not comment or label.
5. Post APPROVE or CHANGES REQUESTED as a PR comment ending with exactly `<!-- pr-review:v1 reviewer=codex head=<reviewed_head> verdict=APPROVE -->` or `<!-- pr-review:v1 reviewer=codex head=<reviewed_head> verdict=CHANGES_REQUESTED -->`.
6. Re-fetch the head, then switch `reviewed:approve` / `reviewed:changes` to match the verdict. Re-fetch once more; if the head moved, remove the label you added and report the stale result.

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

    review_path, temporary = prepare_review_worktree(ctx, pr)
    output_file = Path(f"/private/tmp/drain-prs-rereview-{number}.out")
    prompt = drain_rereview_prompt(number, expected_head)

    try:
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
        if temporary:
            remove_worktree(ctx, review_path, dry_run=False)


def recover_stale_approval(
    ctx: RepoContext,
    state: dict[str, Any],
    *,
    dry_run: bool,
) -> bool:
    for key in sorted(state["prs"], key=int):
        number = int(key)
        entry = state["prs"][key]
        pr = get_pr(ctx, number)

        if pr["state"] != "OPEN":
            forget_pr(state, number)
            return True

        approved_head = entry["approved_head"]
        current_head = pr["headRefOid"]
        if current_head == approved_head:
            if not has_label(pr, APPROVE_LABEL):
                # A label removed without a new commit is a deliberate revocation,
                # not a stale review that the drain queue should restore.
                forget_pr(state, number)
                return True
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
            log(
                f"PR #{number}: head changed from {approved_head[:12]} to "
                f"{current_head[:12]}; waiting for stale approval removal"
            )
            return False

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


def cleanup_repair_worktree(ctx: RepoContext, path: Path, branch: str) -> None:
    # This is a drainer-owned disposable worktree and may contain an
    # intentionally unfinished/conflicted merge when repair is declined.
    remove_worktree(ctx, path, dry_run=False, allow_dirty_force=True)
    delete_local_branch(ctx, branch, dry_run=False)


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
        ["git", "ls-remote", "--exit-code", "--heads", "origin", branch],
        cwd=ctx.path,
        check=False,
    )
    if proc.returncode != 0:
        return
    log(f"Deleting remote branch {branch}")
    if dry_run:
        return
    run(["git", "push", "origin", "--delete", branch], cwd=ctx.path)


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
    holding = Path(tempfile.mkdtemp(prefix="autostash-", dir=str(ctx.path / ".git")))
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


def _preserve_unreachable_snapshot(ctx: RepoContext, tracked_sha: str, message: str) -> str:
    # `tracked_sha` is otherwise reachable from no ref and eligible for gc;
    # try to make it durably discoverable before handing off to a human, and
    # say plainly where it actually landed rather than assuming success.
    store_proc = run(
        ["git", "stash", "store", "-m", message, tracked_sha],
        cwd=ctx.path,
        check=False,
    )
    if store_proc.returncode == 0:
        return "The snapshotted changes were recovered into `git stash list` for manual resolution."
    ref_name = f"refs/drain-prs/autostash/{tracked_sha}"
    ref_proc = run(["git", "update-ref", ref_name, tracked_sha], cwd=ctx.path, check=False)
    if ref_proc.returncode == 0:
        return (
            "The snapshotted changes could not be added to `git stash list`, but were "
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

    run(["git", "fetch", "--quiet", "origin"], cwd=ctx.path)

    def try_ff() -> None:
        run(
            ["git", "merge", "--ff-only", f"origin/{ctx.default_branch}"],
            cwd=ctx.path,
        )

    try:
        try_ff()
        return
    except DrainError as ff_exc:
        message = f"drain-prs-autostash-{int(time.time())}-{os.getpid()}"
        untracked = None
        tracked_sha = None
        try:
            untracked = _relocate_untracked_files(ctx)
            tracked_sha = _snapshot_tracked_changes(ctx, message)
            if tracked_sha is not None:
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
            _restore_snapshot(ctx, tracked_sha, untracked)


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


def inspect_conflict_files(
    ctx: RepoContext,
    pr: dict[str, Any],
) -> tuple[Path, str, list[str]]:
    tmpdir = Path(
        tempfile.mkdtemp(prefix=f"drain-prs-conflict-{pr['number']}-", dir="/private/tmp")
    )
    repair_branch = f"drain-prs-repair-{pr['number']}-{int(time.time())}"
    run(["git", "fetch", "--quiet", "origin"], cwd=ctx.path)
    run(
        [
            "git",
            "worktree",
            "add",
            "-b",
            repair_branch,
            str(tmpdir),
            f"origin/{pr['headRefName']}",
        ],
        cwd=ctx.path,
    )

    proc = run(
        ["git", "merge", "--no-commit", "--no-ff", f"origin/{ctx.default_branch}"],
        cwd=tmpdir,
        check=False,
    )
    if proc.returncode == 0:
        cleanup_repair_worktree(ctx, tmpdir, repair_branch)
        raise DrainError(
            f"PR #{pr['number']} is marked conflicting by GitHub, but it merged cleanly locally."
        )

    conflicts = run(
        ["git", "diff", "--name-only", "--diff-filter=U"],
        cwd=tmpdir,
    ).stdout.splitlines()
    if not conflicts:
        cleanup_repair_worktree(ctx, tmpdir, repair_branch)
        raise DrainError(
            f"PR #{pr['number']} failed to merge locally, but no conflict files were detected."
        )
    return tmpdir, repair_branch, conflicts


def codex_conflict_prompt(
    ctx: RepoContext,
    pr: dict[str, Any],
    conflicts: list[str],
) -> str:
    conflict_lines = "\n".join(f"- {path}" for path in conflicts)
    linked_issues = ", ".join(
        f"#{issue['number']}" for issue in pr.get("closingIssuesReferences", [])
    ) or "none"
    return f"""You are repairing a merge conflict for PR #{pr['number']} in {ctx.repo_slug}.

Repository main checkout: {ctx.path}
Temporary repair worktree: current working directory
Default branch: {ctx.default_branch}
PR head branch on origin: {pr['headRefName']}
Linked issues: {linked_issues}

Current branch is a temporary local repair branch created from origin/{pr['headRefName']}.
A merge of origin/{ctx.default_branch} into the current branch has already been started and is currently conflicted.

Conflict files:
{conflict_lines}

Your job:
1. Resolve the merge conflict, preserving the PR's intent while incorporating current {ctx.default_branch}.
2. Keep the scope tightly limited to the merge repair.
3. Run the smallest relevant validation for the files you touched.
4. Commit the merge resolution.
5. Push the repaired result back to origin/{pr['headRefName']} using the current HEAD.

Constraints:
- Do not merge the PR.
- Do not close issues.
- Do not remove any worktrees or branches.
- Do not comment on the PR or add/remove any labels. Python owns approval state,
  and a fresh Claude reviewer must approve the exact repaired head.
- Never force-push.
- Do not make unrelated refactors.
- Use `gh`/`git` directly; assume local GitHub auth already works.

When done, leave the worktree in a clean committed state and report briefly what you changed."""


def codex_conflict_fix_prompt(
    ctx: RepoContext,
    pr: dict[str, Any],
    *,
    round_number: int,
    expected_head: str,
) -> str:
    return f"""You are the Codex repair agent in conflict-review round {round_number} for PR #{pr['number']} in {ctx.repo_slug}.

The current PR head must be {expected_head}. A fresh Claude reviewer requested changes to the prior merge-conflict repair.

Your job:
1. Fetch `headRefOid` and stop without changing anything unless it is exactly {expected_head}.
2. Read the newest `<!-- pr-review:v1 reviewer=claude ... verdict=CHANGES_REQUESTED -->` PR comment and resolve every blocking concern.
3. Inspect the linked issue, the complete current PR diff, and relevant code so the fix preserves both the PR's intent and current {ctx.default_branch} behavior.
4. Keep changes minimal and limited to the review findings.
5. Run the smallest relevant validation, commit the fixes, and push current HEAD to origin/{pr['headRefName']}.

Constraints:
- Do not merge the PR or modify/close its issue.
- Do not comment on the PR or add/remove any labels. A fresh Claude reviewer owns the next verdict.
- Never force-push.
- Leave the current worktree clean and committed.

Report briefly which review findings you resolved and what validation ran."""


def claude_conflict_review_prompt(
    ctx: RepoContext,
    pr: dict[str, Any],
    *,
    round_number: int,
    expected_head: str,
) -> str:
    return f"""You are a fresh independent Claude reviewer in conflict-review round {round_number} for PR #{pr['number']} in {ctx.repo_slug}.

The PR was previously approved, then required an automated merge-conflict repair by Codex. Review only: do not edit files, commit, push, merge, close or modify issues, or remove worktrees.

1. Fetch `headRefOid` and require it to equal {expected_head}; if it differs, do not comment or label.
2. Read the PR body, linked issue and authoritative comments, commits, CI, the latest prior `pr-review:v1` comment, and the complete current merge-base diff.
3. Inspect the conflict-resolution commit and any later Codex review-fix commits especially carefully. Verify that they preserve the approved PR's intent while incorporating current {ctx.default_branch}. Recheck prior blocking concerns and inspect for regressions or unmet requirements. Nits never block.
4. Re-fetch the head immediately before publishing. If it differs from {expected_head}, do not comment or label.
5. Publish exactly one concise PR comment using the `gh` CLI. Use APPROVE only when no blocker remains; otherwise use CHANGES_REQUESTED with actionable file/line references. Never use a formal `gh pr review` submission because the authenticated account owns the PR. End the comment with exactly one of:
   `<!-- pr-review:v1 reviewer=claude head={expected_head} verdict=APPROVE -->`
   `<!-- pr-review:v1 reviewer=claude head={expected_head} verdict=CHANGES_REQUESTED -->`
6. Re-fetch the head, then set exactly one matching label and remove the other using `gh pr edit`: `reviewed:approve` for APPROVE or `reviewed:changes` for CHANGES_REQUESTED. Re-fetch once more; if the head moved, remove the label you added and report the stale result.

Use the `gh` CLI only for GitHub publication. Report the verdict, prior-concern statuses, new findings, reviewed head, and comment/label status."""


def run_codex_conflict_agent(
    ctx: RepoContext,
    pr: dict[str, Any],
    *,
    worktree: Path,
    prompt: str,
    action: str,
    output_file: Path,
) -> None:
    try:
        run(
            [
                "codex",
                "exec",
                "--ignore-user-config",
                "--ephemeral",
                "-m",
                FINALIZE_MODEL,
                "-c",
                f'model_reasoning_effort="{FINALIZE_EFFORT}"',
                "--dangerously-bypass-approvals-and-sandbox",
                "--skip-git-repo-check",
                "-o",
                str(output_file),
                "-",
            ],
            cwd=worktree,
            input_text=prompt,
            timeout=MODEL_TIMEOUT_SECONDS,
        )
    except DrainError as exc:
        notify_model_failure(ctx, pr["number"], action, exc)
        raise ModelUnavailableError(
            f"{FINALIZE_MODEL}@{FINALIZE_EFFORT} failed during {action} "
            f"for PR #{pr['number']}; no retry or fallback was attempted. "
            f"Inspect {output_file}."
        ) from exc


def run_claude_conflict_reviewer(
    ctx: RepoContext,
    pr: dict[str, Any],
    *,
    worktree: Path,
    round_number: int,
    expected_head: str,
) -> str:
    prompt = claude_conflict_review_prompt(
        ctx,
        pr,
        round_number=round_number,
        expected_head=expected_head,
    )
    output_file = Path(
        f"/private/tmp/drain-prs-conflict-review-{pr['number']}-r{round_number}.out"
    )
    local_head = run(["git", "rev-parse", "HEAD"], cwd=worktree).stdout.strip()
    local_status = run(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        cwd=worktree,
    ).stdout.strip()
    if local_status:
        raise DrainError(
            f"PR #{pr['number']}: conflict-review worktree was dirty before "
            f"Claude round {round_number}."
        )
    if local_head != expected_head:
        raise DrainError(
            f"PR #{pr['number']}: conflict-review worktree head "
            f"{local_head[:12]} did not match expected PR head {expected_head[:12]}."
        )
    try:
        proc = run(
            [
                "claude",
                "-p",
                "--model",
                CONFLICT_REVIEW_MODEL,
                "--effort",
                CONFLICT_REVIEW_EFFORT,
                "--permission-mode",
                "bypassPermissions",
                "--no-session-persistence",
            ],
            cwd=worktree,
            input_text=prompt,
            timeout=MODEL_TIMEOUT_SECONDS,
        )
        output_file.write_text(proc.stdout or "", encoding="utf-8")
    except (DrainError, OSError) as exc:
        try:
            remove_approval_label_if_present(ctx, pr["number"])
        except DrainError as cleanup_exc:
            log(
                f"PR #{pr['number']}: could not verify stale approval removal "
                f"after Claude failure: {cleanup_exc}"
            )
        notify_model_failure(
            ctx,
            pr["number"],
            f"conflict-review round {round_number}",
            exc,
            model=CONFLICT_REVIEW_MODEL,
            effort=CONFLICT_REVIEW_EFFORT,
        )
        raise ModelUnavailableError(
            f"{CONFLICT_REVIEW_MODEL}@{CONFLICT_REVIEW_EFFORT} failed during "
            f"conflict-review round {round_number} for PR #{pr['number']}; "
            f"no retry or fallback was attempted. Inspect {output_file}."
        ) from exc

    refreshed = get_pr(ctx, pr["number"])
    final_local_head = run(["git", "rev-parse", "HEAD"], cwd=worktree).stdout.strip()
    final_local_status = run(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        cwd=worktree,
    ).stdout.strip()
    if refreshed["headRefOid"] != expected_head:
        remove_approval_label_if_present(ctx, pr["number"])
        raise DrainError(
            f"PR #{pr['number']}: head changed during Claude conflict review "
            f"({expected_head[:12]} -> {refreshed['headRefOid'][:12]})."
        )
    if final_local_head != local_head or final_local_status:
        remove_approval_label_if_present(ctx, pr["number"])
        raise DrainError(
            f"PR #{pr['number']}: Claude conflict review round {round_number} "
            "modified the repair worktree; approval was removed."
        )
    details = latest_review_details(ctx, pr["number"])
    approve = has_label(refreshed, APPROVE_LABEL)
    changes = has_label(refreshed, CHANGES_LABEL)
    if details == ("claude", expected_head.lower(), "APPROVE"):
        if approve and not changes:
            return "APPROVE"
    elif details == ("claude", expected_head.lower(), "CHANGES_REQUESTED"):
        if changes and not approve:
            return "CHANGES_REQUESTED"
    remove_approval_label_if_present(ctx, pr["number"])
    raise DrainError(
        f"PR #{pr['number']}: Claude conflict review round {round_number} "
        "did not publish a matching current-head marker and exactly one verdict label."
    )


def verify_codex_conflict_push(
    ctx: RepoContext,
    pr: dict[str, Any],
    *,
    worktree: Path,
    previous_head: str,
    action: str,
) -> dict[str, Any]:
    refreshed = get_pr(ctx, pr["number"])
    if refreshed["headRefOid"] == previous_head:
        raise DrainError(
            f"PR #{pr['number']}: Codex {action} finished without pushing a new head."
        )
    refreshed = wait_for_branch_update_policy(
        ctx,
        pr["number"],
        previous_head,
        timeout_seconds=UPDATE_BRANCH_WAIT_SECONDS,
        poll_seconds=UPDATE_BRANCH_POLL_SECONDS,
    )
    if has_label(refreshed, APPROVE_LABEL):
        raise DrainError(
            f"PR #{pr['number']}: stale {APPROVE_LABEL!r} remained after Codex {action}; "
            "refusing to let the repair agent approve its own head."
        )
    local_head = run(["git", "rev-parse", "HEAD"], cwd=worktree).stdout.strip()
    if local_head != refreshed["headRefOid"]:
        raise DrainError(
            f"PR #{pr['number']}: Codex {action} left local HEAD "
            f"{local_head[:12]} but pushed PR head {refreshed['headRefOid'][:12]}."
        )
    status = run(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        cwd=worktree,
    ).stdout.strip()
    if status:
        raise DrainError(
            f"PR #{pr['number']}: Codex {action} left the repair worktree dirty."
        )
    return refreshed


def repair_conflict_with_codex(
    ctx: RepoContext,
    pr: dict[str, Any],
    *,
    dry_run: bool,
) -> bool:
    tmpdir, repair_branch, conflicts = inspect_conflict_files(ctx, pr)
    conflict_summary = ", ".join(conflicts)
    approval_invalidated = False
    try:
        if len(conflicts) > MAX_AUTO_REPAIR_CONFLICT_FILES:
            raise DrainError(
                f"PR #{pr['number']} has {len(conflicts)} conflict files "
                f"({conflict_summary}); refusing automatic repair."
            )
        non_text = [path for path in conflicts if not conflict_file_is_textlike(path)]
        if non_text:
            raise DrainError(
                f"PR #{pr['number']} has non-text conflict files "
                f"({', '.join(non_text)}); refusing automatic repair."
            )

        log(
            f"PR #{pr['number']}: starting cross-reviewed conflict repair for "
            f"{conflict_summary}"
        )
        if dry_run:
            log(
                f"PR #{pr['number']}: would remove stale approval, run Codex "
                f"repair, and alternate up to {MAX_CONFLICT_REVIEW_ROUNDS} "
                "fresh Claude review round(s)"
            )
            return True

        approval_invalidated = True
        remove_approval_label(ctx, pr["number"])
        previous_head = pr["headRefOid"]
        output_file = Path(f"/private/tmp/drain-prs-conflict-{pr['number']}.out")
        run_codex_conflict_agent(
            ctx,
            pr,
            worktree=tmpdir,
            prompt=codex_conflict_prompt(ctx, pr, conflicts),
            action="merge-conflict repair",
            output_file=output_file,
        )
        current = verify_codex_conflict_push(
            ctx,
            pr,
            worktree=tmpdir,
            previous_head=previous_head,
            action="merge-conflict repair",
        )

        for round_number in range(1, MAX_CONFLICT_REVIEW_ROUNDS + 1):
            current_head = current["headRefOid"]
            log(
                f"PR #{pr['number']}: Claude conflict-review round "
                f"{round_number}/{MAX_CONFLICT_REVIEW_ROUNDS} for {current_head[:12]}"
            )
            verdict = run_claude_conflict_reviewer(
                ctx,
                pr,
                worktree=tmpdir,
                round_number=round_number,
                expected_head=current_head,
            )
            if verdict == "APPROVE":
                log(
                    f"PR #{pr['number']}: conflict repair approved by Claude "
                    f"after {round_number} round(s)"
                )
                return True
            if round_number == MAX_CONFLICT_REVIEW_ROUNDS:
                log(
                    f"PR #{pr['number']}: conflict repair still has requested "
                    f"changes after {MAX_CONFLICT_REVIEW_ROUNDS} rounds; leaving "
                    f"{CHANGES_LABEL} for human follow-up"
                )
                return False

            fix_output = Path(
                f"/private/tmp/drain-prs-conflict-fix-{pr['number']}-r{round_number}.out"
            )
            run_codex_conflict_agent(
                ctx,
                pr,
                worktree=tmpdir,
                prompt=codex_conflict_fix_prompt(
                    ctx,
                    pr,
                    round_number=round_number,
                    expected_head=current_head,
                ),
                action=f"conflict-review fix round {round_number}",
                output_file=fix_output,
            )
            current = verify_codex_conflict_push(
                ctx,
                pr,
                worktree=tmpdir,
                previous_head=current_head,
                action=f"conflict-review fix round {round_number}",
            )
        return False
    except DrainError:
        if approval_invalidated:
            try:
                mark_changes_requested(ctx, pr["number"])
            except DrainError as cleanup_exc:
                log(
                    f"PR #{pr['number']}: could not leave the failed conflict "
                    f"repair safely labeled: {cleanup_exc}"
                )
        raise
    finally:
        cleanup_repair_worktree(ctx, tmpdir, repair_branch)


def process_pr(
    ctx: RepoContext,
    number: int,
    *,
    dry_run: bool,
    repair_conflicts: bool,
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
        if repair_conflicts:
            repaired = repair_conflict_with_codex(ctx, pr, dry_run=dry_run)
            if repaired and not dry_run:
                refreshed = get_pr(ctx, number)
                if has_label(refreshed, APPROVE_LABEL):
                    remember_approved_head(state, number, refreshed["headRefOid"])
            return repaired
        raise DrainError(
            f"PR #{number} has a merge conflict "
            f"(mergeable={mergeable}, mergeStateStatus={merge_state})."
        )

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
    # withdrawal or a newly pending check on the same head.
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

    merged = merge_pr(ctx, pr, dry_run=dry_run)
    if not merged:
        return True
    cleanup_after_merge(ctx, pr, dry_run=dry_run)
    if not dry_run:
        forget_pr(state, number)
    return True


def acquire_lock(ctx: RepoContext):
    lock_path = ctx.path / ".git" / "drain_prs.lock"
    handle = open(lock_path, "w", encoding="utf-8")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        raise DrainError(
            f"Another drain_prs.py instance is already running for {ctx.path}."
        ) from exc
    handle.write(str(os.getpid()))
    handle.flush()
    return handle


def loop(
    ctx: RepoContext,
    *,
    interval: int,
    once: bool,
    dry_run: bool,
    repair_conflicts: bool,
    gates: GateConfig,
) -> None:
    lock_handle = acquire_lock(ctx)
    state = load_drain_state(ctx)
    stale_recovery_failures = 0
    queue_refresh_failures = 0
    try:
        while True:
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
                        repair_conflicts=repair_conflicts,
                        state=state,
                        gates=gates,
                    )
                except ModelUnavailableError:
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
        "--no-conflict-repair",
        action="store_true",
        help="Fail immediately on merge conflicts instead of invoking Codex repair.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    global LOG_DIR
    LOG_DIR = Path(args.log_dir).expanduser().resolve()
    try:
        ctx = get_repo_context(Path(args.path).expanduser().resolve())
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
            repair_conflicts=not args.no_conflict_repair,
            gates=gates,
        )
    except DrainError as exc:
        fail(f"drain_prs.py error: {exc}")
    except KeyboardInterrupt:
        log("Interrupted; exiting")


if __name__ == "__main__":
    main()
