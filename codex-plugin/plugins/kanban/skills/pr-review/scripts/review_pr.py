#!/usr/bin/env python3
"""Run the canonical, issue-gated pull-request review workflow."""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any


REVIEW_TIMEOUT_SECONDS = 7200
GATE_TEXT = "Issue has not been approved."
VALID_ORIGIN_RE = re.compile(r"<!-- pr-origin:(claude|codex) -->")
REVIEW_MARKER_RE = re.compile(
    r"<!-- pr-review:v2 reviewers=(?P<reviewers>\S+) models=(?P<models>\S+) "
    r"head=(?P<head>[0-9a-f]{40}) verdict=(?P<verdict>APPROVE|CHANGES_REQUESTED) -->"
)

REVIEW_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "verdict": {"type": "string", "enum": ["APPROVE", "CHANGES_REQUESTED"]},
        "summary": {"type": "string"},
        "blocking_concerns": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "line": {"type": "string"},
                    "body": {"type": "string"},
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
    model: str
    effort: str = "xhigh"


# These are Kanban's canonical review-action models (docs/design.md,
# src/Kanban/PullRequestFlow.hs's codexModel/claudeModel): the identity this
# coordinator spawns as the opposite-brand reviewer, not a model override of
# the top-level $pr-review/$pr-rereview/$pr-revise invocation itself, which
# Kanban's own CLI spawn already pins.
CODEX_REVIEWER = Reviewer("codex", "GPT-5.6-Terra", "gpt-5.6-terra")
CLAUDE_REVIEWER = Reviewer("claude", "Claude Opus 4.8", "claude-opus-4-8")


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


def repository_name(root: Path) -> str:
    value = gh_json(root, ["repo", "view", "--json", "nameWithOwner"])
    name = value.get("nameWithOwner") if isinstance(value, dict) else None
    if not isinstance(name, str) or "/" not in name:
        raise WorkflowError("could not resolve GitHub repository identity")
    return name


def pr_view(root: Path, number: int) -> dict[str, Any]:
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
        ]
    )
    value = gh_json(root, ["pr", "view", str(number), "--json", fields])
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


def route_reviewers(origin: str | None) -> list[Reviewer]:
    if origin == "claude":
        return [CODEX_REVIEWER]
    if origin == "codex":
        return [CLAUDE_REVIEWER]
    return [CODEX_REVIEWER, CLAUDE_REVIEWER]


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


def approver_path() -> Path:
    """Resolve Kanban's canonical issue-review backend the same way
    `Kanban.Review.canonicalIssueReviewerPath` does: `KANBAN_ISSUE_REVIEW_INSTALL_DIR`
    when set, otherwise the Kanban-managed install directory. This coordinator
    never hard-codes the pre-migration compatibility launcher path; see
    docs/agent-workflow-contract.md §3."""
    override = os.environ.get("KANBAN_ISSUE_REVIEW_INSTALL_DIR")
    install_dir = Path(override).expanduser() if override else Path.home() / "Library" / "Application Support" / "kanban" / "issue-review"
    path = install_dir / "approve_issues.py"
    if not path.is_file():
        raise WorkflowError(
            f"Canonical issue reviewer was not found at {path}. Run "
            "`python3 tools/install_issue_review.py` from the Kanban checkout to install it."
        )
    return path


def check_issue(root: Path, number: int) -> dict[str, Any]:
    proc = run(
        [
            sys.executable,
            str(approver_path()),
            "--path",
            str(root),
            "--check",
            str(number),
            "--legacy-policy",
            "dual",
            "--json",
        ],
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
) -> dict[str, Any]:
    numbers, invalid = linked_issue_numbers(pr, repo)
    checks = [check_issue(root, number) for number in numbers]
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


def post_comment(root: Path, number: int, body: str) -> str:
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", prefix="pr-review-", suffix=".md") as handle:
        handle.write(body)
        handle.flush()
        proc = run(["gh", "pr", "comment", str(number), "--body-file", handle.name], cwd=root)
    return proc.stdout.strip()


def publish_gate_comment(
    root: Path,
    repo: str,
    pr: dict[str, Any],
    gate: dict[str, Any],
    *,
    allow_no_issue: bool,
) -> tuple[str, str]:
    marker = gate_marker(
        repo,
        gate["issues"],
        gate["invalid_links"],
        allow_no_issue=allow_no_issue,
    )
    body = f"{GATE_TEXT}\n\n{marker}\n"
    refreshed = pr_view(root, pr["number"])
    refreshed_gate = gate_status(root, refreshed, repo, allow_no_issue=allow_no_issue)
    if refreshed_gate["key"] != gate["key"] or refreshed_gate["approved"]:
        raise WorkflowError("issue gate changed before publication; rerun the review")
    login = viewer_login(root)
    existing = has_owned_gate_comment(pr_comments(root, repo, pr["number"]), login, body)
    if existing:
        return "existing", existing
    refreshed = pr_view(root, pr["number"])
    refreshed_gate = gate_status(root, refreshed, repo, allow_no_issue=allow_no_issue)
    if refreshed_gate["key"] != gate["key"] or refreshed_gate["approved"]:
        raise WorkflowError("issue gate changed before publication; rerun the review")
    url = post_comment(root, pr["number"], body)
    return "posted", url


def issue_context(root: Path, repo: str, number: int) -> dict[str, Any]:
    issue = gh_json(
        root,
        ["issue", "view", str(number), "--json", "number,title,body,state,url,author,labels"],
    )
    comments = paginated_api(root, f"repos/{repo}/issues/{number}/comments?per_page=100")
    return {"issue": issue, "comments": comments}


def collect_context(root: Path, repo: str, pr: dict[str, Any], issue_numbers: list[int]) -> dict[str, Any]:
    diff = run(["gh", "pr", "diff", str(pr["number"])], cwd=root).stdout
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


def ensure_commit(root: Path, number: int, head: str) -> None:
    present = subprocess.run(
        ["git", "cat-file", "-e", f"{head}^{{commit}}"],
        cwd=root,
        capture_output=True,
        check=False,
    ).returncode == 0
    if not present:
        run(["git", "fetch", "--no-tags", "origin", f"pull/{number}/head"], cwd=root, timeout=600)
    run(["git", "cat-file", "-e", f"{head}^{{commit}}"], cwd=root)


def extract_source(root: Path, number: int, head: str, destination: Path) -> None:
    ensure_commit(root, number, head)
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


def review_prompt(context: dict[str, Any], reviewer: Reviewer, rereview: bool) -> str:
    mode = "rereview" if rereview else "review"
    return f"""Independently {mode} the pull request represented below as {reviewer.display_name}.

The current working directory is a read-only extraction of the exact PR head. Inspect relevant source and tests there. The JSON payload is authoritative for any linked approved issue specifications, the full patch, commits, prior reviews/comments, and CI. When linked_issues is empty, evaluate the PR directly from its title, body, patch, repository context, and tests. For a rereview, explicitly verify prior blocking concerns as well as finding regressions or new blockers.

Review only. Do not edit files, access GitHub, publish, label, commit, push, or merge. Evaluate correctness, regressions, missing required tests, scope, and satisfaction of the effective review contract. Use CHANGES_REQUESTED only for concrete human-action blockers; do not block on optional style preferences. Use APPROVE only when there are no blocking concerns.

Return only the requested structured result. Keep the summary concise. Each blocker must have an actionable repository-relative path, line (or an empty string if no single line applies), and explanation.

REVIEW_PAYLOAD:
{json.dumps(context, indent=2, sort_keys=True)}
"""


def validate_review(value: Any, reviewer: Reviewer) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise WorkflowError(f"{reviewer.display_name} returned a non-object result")
    verdict = value.get("verdict")
    summary = value.get("summary")
    concerns = value.get("blocking_concerns")
    if verdict not in {"APPROVE", "CHANGES_REQUESTED"}:
        raise WorkflowError(f"{reviewer.display_name} returned an invalid verdict")
    if not isinstance(summary, str) or not summary.strip() or len(summary) > 4000:
        raise WorkflowError(f"{reviewer.display_name} returned an invalid summary")
    if not isinstance(concerns, list) or len(concerns) > 30:
        raise WorkflowError(f"{reviewer.display_name} returned invalid blocking concerns")
    for concern in concerns:
        if not isinstance(concern, dict) or set(concern) != {"path", "line", "body"}:
            raise WorkflowError(f"{reviewer.display_name} returned a malformed blocker")
        if not all(isinstance(concern[key], str) for key in ("path", "line", "body")):
            raise WorkflowError(f"{reviewer.display_name} returned a malformed blocker")
        if not concern["body"].strip() or len(concern["body"]) > 2000:
            raise WorkflowError(f"{reviewer.display_name} returned an invalid blocker body")
    if verdict == "APPROVE" and concerns:
        raise WorkflowError(f"{reviewer.display_name} approved with blocking concerns")
    if verdict == "CHANGES_REQUESTED" and not concerns:
        raise WorkflowError(f"{reviewer.display_name} requested changes without a blocker")
    return {
        "reviewer": reviewer.key,
        "display_name": reviewer.display_name,
        "model": reviewer.model,
        "effort": reviewer.effort,
        "verdict": verdict,
        "summary": summary.strip(),
        "blocking_concerns": concerns,
    }


def invoke_codex(reviewer: Reviewer, prompt: str, cwd: Path) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="pr-review-codex-") as temp:
        schema_path = Path(temp) / "schema.json"
        output_path = Path(temp) / "result.json"
        schema_path.write_text(json.dumps(REVIEW_SCHEMA), encoding="utf-8")
        run(
            [
                "codex",
                "exec",
                "--ephemeral",
                "--ignore-user-config",
                "--skip-git-repo-check",
                "-m",
                reviewer.model,
                "-c",
                f'model_reasoning_effort="{reviewer.effort}"',
                "-s",
                "read-only",
                "-C",
                str(cwd),
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
    return validate_review(value, reviewer)


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
    proc = run(
        [
            "claude",
            "-p",
            "--model",
            reviewer.model,
            "--effort",
            reviewer.effort,
            "--permission-mode",
            "dontAsk",
            "--tools",
            "Read,Grep,Glob",
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
    return validate_review(parse_claude_output(proc.stdout), reviewer)


def invoke_reviewer(reviewer: Reviewer, prompt: str, cwd: Path) -> dict[str, Any]:
    if reviewer.key == "codex":
        return invoke_codex(reviewer, prompt, cwd)
    return invoke_claude(reviewer, prompt, cwd)


def run_reviews(
    reviewers: list[Reviewer],
    context: dict[str, Any],
    source: Path,
    rereview: bool,
) -> list[dict[str, Any]]:
    prompts = {item.key: review_prompt(context, item, rereview) for item in reviewers}
    if len(reviewers) == 1:
        item = reviewers[0]
        return [invoke_reviewer(item, prompts[item.key], source)]
    results: dict[str, dict[str, Any]] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(reviewers)) as pool:
        futures = {
            pool.submit(invoke_reviewer, item, prompts[item.key], source): item
            for item in reviewers
        }
        for future in concurrent.futures.as_completed(futures):
            item = futures[future]
            try:
                results[item.key] = future.result()
            except Exception as exc:
                raise WorkflowError(f"{item.display_name} review failed: {exc}") from exc
    return [results[item.key] for item in reviewers]


def aggregate_verdict(results: list[dict[str, Any]]) -> str:
    return "CHANGES_REQUESTED" if any(item["verdict"] == "CHANGES_REQUESTED" for item in results) else "APPROVE"


def review_marker(reviewers: list[Reviewer], head: str, verdict: str) -> str:
    reviewer_keys = ",".join(item.key for item in reviewers)
    models = ",".join(f"{item.model}@{item.effort}" for item in reviewers)
    return (
        f"<!-- pr-review:v2 reviewers={reviewer_keys} models={models} "
        f"head={head} verdict={verdict} -->"
    )


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
    lines.append(review_marker(reviewers, head, verdict))
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
) -> dict[str, Any]:
    pr = pr_view(root, number)
    if pr["headRefOid"] != expected_head:
        raise WorkflowError("PR head changed; no current-head verdict may be labeled")
    gate = gate_status(root, pr, repo, allow_no_issue=allow_no_issue)
    if gate["key"] != expected_gate_key:
        raise WorkflowError("linked issues changed; no verdict was published")
    if not gate["approved"]:
        raise WorkflowError("issue approval became stale; no current verdict may be labeled")
    return gate


def set_verdict_label(root: Path, number: int, verdict: str) -> None:
    add = "reviewed:approve" if verdict == "APPROVE" else "reviewed:changes"
    remove = "reviewed:changes" if verdict == "APPROVE" else "reviewed:approve"
    run(["gh", "pr", "edit", str(number), "--add-label", add, "--remove-label", remove], cwd=root)


def clear_verdict_labels(root: Path, number: int) -> None:
    run(
        [
            "gh",
            "pr",
            "edit",
            str(number),
            "--remove-label",
            "reviewed:approve",
            "--remove-label",
            "reviewed:changes",
        ],
        cwd=root,
    )


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
    head: str,
    verdict: str,
    gate_key_value: str,
    *,
    allow_no_issue: bool,
) -> dict[str, Any]:
    pr = pr_view(root, number)
    if pr["headRefOid"] != head:
        raise WorkflowError("PR head changed after publication")
    labels = [item.get("name") for item in pr.get("labels") or [] if isinstance(item, dict)]
    expected = "reviewed:approve" if verdict == "APPROVE" else "reviewed:changes"
    verdict_labels = [item for item in labels if item in {"reviewed:approve", "reviewed:changes"}]
    if verdict_labels != [expected]:
        raise WorkflowError(f"publication label verification failed: {verdict_labels}")
    gate = gate_status(root, pr, repo, allow_no_issue=allow_no_issue)
    if gate["key"] != gate_key_value or not gate["approved"]:
        raise WorkflowError("publication issue-gate verification failed")
    login = viewer_login(root)
    latest = latest_owned_review_marker(pr_comments(root, repo, number), login)
    if latest is None:
        raise WorkflowError("published review marker was not found")
    marker, url = latest
    expected_models = ",".join(f"{item.model}@{item.effort}" for item in reviewers)
    expected_reviewers = ",".join(item.key for item in reviewers)
    if (
        marker.group("head") != head
        or marker.group("verdict") != verdict
        or marker.group("models") != expected_models
        or marker.group("reviewers") != expected_reviewers
    ):
        raise WorkflowError("newest review marker does not match the published verdict")
    return {"comment_url": url, "labels": verdict_labels}


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


def workflow(
    root: Path,
    number: int,
    *,
    rereview: bool,
    dry_run: bool,
    allow_no_issue: bool,
) -> tuple[int, dict[str, Any]]:
    repo = repository_name(root)
    pr = pr_view(root, number)
    gate = gate_status(root, pr, repo, allow_no_issue=allow_no_issue)
    origin = pr_origin(pr)
    reviewers = route_reviewers(origin)
    base = {
        "pr": number,
        "url": pr["url"],
        "head": pr["headRefOid"],
        "origin": origin or "unknown",
        "route": "+".join(item.key for item in reviewers),
        "models": [f"{item.model}@{item.effort}" for item in reviewers],
        "review_mode": "standalone" if allow_no_issue else "issue-gated",
        "issue_gate": gate,
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
        )
        return 2, {**base, "status": "blocked", "comment_status": status, "comment_url": url}
    if rereview:
        require_prior_review(root, repo, number)
    if dry_run:
        return 0, {**base, "status": "ready", "comment_status": "dry-run"}

    context = collect_context(root, repo, pr, gate["issues"])
    with tempfile.TemporaryDirectory(prefix=f"pr-{number}-source-") as temp:
        source = Path(temp)
        extract_source(root, number, pr["headRefOid"], source)
        results = run_reviews(reviewers, context, source, rereview)

    refreshed_pr = pr_view(root, number)
    refreshed_gate = gate_status(
        root,
        refreshed_pr,
        repo,
        allow_no_issue=allow_no_issue,
    )
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
    )
    post_comment(root, number, body)
    try:
        require_current_review_state(
            root,
            repo,
            number,
            pr["headRefOid"],
            gate["key"],
            allow_no_issue=allow_no_issue,
        )
        set_verdict_label(root, number, verdict)
        verified = verify_publication(
            root,
            repo,
            number,
            reviewers,
            pr["headRefOid"],
            verdict,
            gate["key"],
            allow_no_issue=allow_no_issue,
        )
    except WorkflowError as exc:
        try:
            clear_verdict_labels(root, number)
        except WorkflowError as cleanup_exc:
            raise WorkflowError(
                f"publication failed ({exc}); verdict-label cleanup also failed ({cleanup_exc})"
            ) from cleanup_exc
        raise WorkflowError(f"publication failed ({exc}); both verdict labels were cleared") from exc
    return 0, {
        **base,
        "status": "reviewed",
        "verdict": verdict,
        "review_results": results,
        "comment_status": "posted",
        **verified,
    }


def self_test() -> None:
    assert CODEX_REVIEWER.model == "gpt-5.6-terra"
    assert CODEX_REVIEWER.effort == "xhigh"
    assert CLAUDE_REVIEWER.model == "claude-opus-4-8"
    assert CLAUDE_REVIEWER.effort == "xhigh"
    assert origin_from_body("body\n\n<!-- pr-origin:claude -->") == "claude"
    assert origin_from_body("body\n\n<!-- pr-origin:codex -->") == "codex"
    assert origin_from_body("external contribution") is None
    assert origin_from_body("<!-- pr-origin:codex -->\ntext") is None
    assert origin_from_body("<!-- pr-origin:codex -->\n<!-- pr-origin:codex -->") is None
    assert origin_from_body("<!-- pr-origin:unknown -->") is None
    assert [item.key for item in route_reviewers(None)] == ["codex", "claude"]
    assert [item.key for item in route_reviewers("claude")] == ["codex"]
    assert [item.key for item in route_reviewers("codex")] == ["claude"]
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
    review = review_marker([CODEX_REVIEWER, CLAUDE_REVIEWER], "a" * 40, "APPROVE")
    match = REVIEW_MARKER_RE.fullmatch(review)
    assert match and match.group("reviewers") == "codex,claude"
    print("self-test passed")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--path", type=Path, default=Path.cwd(), help="Repository checkout path")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--review", type=int, metavar="PR", help="Review one pull request")
    mode.add_argument("--rereview", type=int, metavar="PR", help="Rereview one changed pull request")
    parser.add_argument("--dry-run", action="store_true", help="Check gate and route without writes or model calls")
    parser.add_argument(
        "--allow-no-issue",
        action="store_true",
        help="Allow a PR with no linked issue; linked issues still require canonical approval",
    )
    parser.add_argument("--json", action="store_true", help="Print structured output")
    parser.add_argument("--self-test", action="store_true", help="Run pure unit checks")
    args = parser.parse_args()
    if not args.self_test and args.review is None and args.rereview is None:
        parser.error("one of --review, --rereview, or --self-test is required")
    number = args.review if args.review is not None else args.rereview
    if number is not None and number < 1:
        parser.error("PR number must be positive")
    return args


def main() -> None:
    args = parse_args()
    if args.self_test:
        self_test()
        return
    number = args.review if args.review is not None else args.rereview
    try:
        root = Path(
            run(["git", "rev-parse", "--show-toplevel"], cwd=args.path.resolve()).stdout.strip()
        ).resolve()
        code, result = workflow(
            root,
            number,
            rereview=args.rereview is not None,
            dry_run=args.dry_run,
            allow_no_issue=args.allow_no_issue,
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
