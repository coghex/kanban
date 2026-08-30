#!/usr/bin/env python3
"""Emit a compact, non-remediating janitor census for one Git repository.

The janitor workflow's whole read side. It resolves nothing and repairs
nothing: every collection below is a signal the workflow presents to a
human, who decides what may be cleaned up. That is why an inspection that
*fails* is reported as `null` rather than as an empty result -- an
unreadable worktree is not a clean one, and an unreadable retain ledger is
not an empty one.

Issue #574 vendored this program into both plugin bundles from a personal
Codex skill, so a pull request can change and verify it. Byte-identical
copies live at claude-plugin/plugins/kanban/scripts/census.py and
codex-plugin/plugins/kanban/skills/janitor/scripts/census.py; each loads
kanban_config.py from beside itself, the way every other vendored
mechanism module does.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

STATUS_LIMIT = 200
RETAIN_LEDGER = "janitor-retain.json"
RETAIN_LEDGER_LIMIT = 256 * 1024
DRAINER_CONTROLLER = "drain_prs_service.py"
ISSUE_BRANCH = re.compile(r"(?:^|/)issue-(\d+)(?:-|$)")
WORKFLOW_BRANCH = re.compile(r"^(?:issue-\d+(?:-|$)|pr-?\d+(?:-|$)|kanban-drainer/)")
REVIEW_TARGETS = (
    ("issue", re.compile(r"(?:^|/)approve-issues?-(\d+)(?:-|/|$)")),
    ("pull_request", re.compile(r"(?:^|/)(?:drain-prs-rereview-|[^/]+-pr-?)(\d+)(?:-|/|$)")),
)


class CensusError(RuntimeError):
    pass


_KANBAN_CONFIG_MODULE = None


def kanban_config_module():
    """tools/kanban_config.py, loaded from beside this file.

    Loaded by path rather than imported for the reason
    publish_coordination_doc.py's own loader is: `tools/` is on `sys.path`
    when a module runs as a script from the repository and is not when a
    bundled copy runs from a plugin install, and the bundled copy has to
    resolve the same way the tracked one does.

    Memoized, so every collection that asks a managed location of it gets
    one module rather than two executions that could straddle an install.
    """
    global _KANBAN_CONFIG_MODULE
    if _KANBAN_CONFIG_MODULE is not None:
        return _KANBAN_CONFIG_MODULE
    source = Path(__file__).resolve().parent / "kanban_config.py"
    name = "_kanban_config_for_census"
    try:
        spec = importlib.util.spec_from_file_location(name, source)
        if spec is None or spec.loader is None:
            raise ImportError(f"no loader for {source}")
        module = importlib.util.module_from_spec(spec)
        # Registered before execution: that module defines dataclasses, and
        # @dataclass resolves its own class's __module__ through sys.modules
        # while the class body is still being processed.
        sys.modules[name] = module
        try:
            spec.loader.exec_module(module)
        except BaseException:
            sys.modules.pop(name, None)
            raise
    except Exception as error:  # noqa: BLE001 - reported, never raised bare
        raise CensusError(
            f"the configuration module at {source} could not be loaded "
            f"({error})"
        ) from error
    _KANBAN_CONFIG_MODULE = module
    return module


def run(argv: list[str], cwd: Path, *, check: bool = True,
        timeout: int = 90) -> subprocess.CompletedProcess[str]:
    try:
        done = subprocess.run(argv, cwd=cwd, text=True, capture_output=True,
                              timeout=timeout)
    except (OSError, subprocess.SubprocessError) as error:
        raise CensusError(f"{' '.join(argv)}: {error}") from None
    if check and done.returncode != 0:
        detail = (done.stderr or done.stdout).strip()
        raise CensusError(f"{' '.join(argv)}: {detail or f'exit {done.returncode}'}")
    return done


def git(root: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return run(["git", *args], root, check=check)


def gh(root: Path, *args: str) -> Any:
    return json.loads(run(["gh", *args], root).stdout)


def parse_worktrees(raw: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    for line in raw.splitlines():
        if not line:
            if current:
                rows.append(current)
                current = None
            continue
        key, _, value = line.partition(" ")
        if key == "worktree":
            if current:
                rows.append(current)
            current = {"path": value}
        elif current is not None:
            if key in {"detached", "bare"}:
                current[key] = True
            elif key in {"locked", "prunable"}:
                current[key] = value or True
            else:
                current[key] = value
    if current:
        rows.append(current)
    return rows


def issue_number(branch: str | None, path: str) -> int | None:
    for candidate in (branch or "", Path(path).name):
        match = ISSUE_BRANCH.search(candidate)
        if match:
            return int(match.group(1))
    return None


def review_target(path: str) -> dict[str, Any] | None:
    for kind, pattern in REVIEW_TARGETS:
        match = pattern.search(path)
        if match:
            return {"kind": kind, "number": int(match.group(1))}
    return None


def summarize_status(raw: str, limit: int = STATUS_LIMIT) -> dict[str, Any]:
    lines = [line for line in raw.splitlines() if line]
    result: dict[str, Any] = {"count": len(lines)}
    if lines:
        result["entries"] = lines[:limit]
    if len(lines) > limit:
        result["truncated"] = True
    return result


def worktree_status(path: Path) -> dict[str, Any]:
    if not path.is_dir():
        return {"count": None, "entries": [], "truncated": False,
                "error": "directory missing"}
    done = run(["git", "status", "--porcelain=v1", "--untracked-files=all"],
               path, check=False)
    if done.returncode != 0:
        return {"count": None, "entries": [], "truncated": False,
                "error": (done.stderr or done.stdout).strip()}
    return summarize_status(done.stdout)


def operation_state(path: Path) -> list[str]:
    if not path.is_dir():
        return []
    done = run(["git", "rev-parse", "--path-format=absolute", "--git-dir"],
               path, check=False)
    if done.returncode != 0:
        return []
    git_dir = Path(done.stdout.strip())
    markers = {
        "MERGE_HEAD": "merge", "CHERRY_PICK_HEAD": "cherry-pick",
        "REVERT_HEAD": "revert", "BISECT_LOG": "bisect",
        "rebase-merge": "rebase", "rebase-apply": "rebase",
    }
    return sorted({name for marker, name in markers.items()
                   if (git_dir / marker).exists()})


def rev_divergence(root: Path, left: str, right: str) -> dict[str, int] | None:
    done = git(root, "rev-list", "--left-right", "--count",
               f"{left}...{right}", check=False)
    if done.returncode != 0:
        return None
    values = done.stdout.split()
    if len(values) != 2:
        return None
    return {"ahead": int(values[0]), "behind": int(values[1])}


def is_ancestor(root: Path, older: str, newer: str) -> bool | None:
    done = git(root, "merge-base", "--is-ancestor", older, newer, check=False)
    if done.returncode == 0:
        return True
    if done.returncode == 1:
        return False
    return None


def default_branch(root: Path) -> str:
    done = git(root, "symbolic-ref", "--quiet", "--short",
               "refs/remotes/origin/HEAD", check=False)
    if done.returncode == 0 and done.stdout.strip().startswith("origin/"):
        return done.stdout.strip().split("/", 1)[1]
    for candidate in ("master", "main"):
        if git(root, "show-ref", "--verify", "--quiet",
               f"refs/remotes/origin/{candidate}", check=False).returncode == 0:
            return candidate
    branch = git(root, "branch", "--show-current").stdout.strip()
    if branch:
        return branch
    raise CensusError("cannot resolve the default branch")


def branch_inventory(root: Path, default: str) -> tuple[list[dict[str, Any]],
                                                         list[dict[str, Any]]]:
    fmt = "%(refname)\t%(objectname)\t%(upstream:short)\t%(symref)\t%(committerdate:iso8601-strict)"
    raw = git(root, "for-each-ref", f"--format={fmt}",
              "refs/heads", "refs/remotes").stdout
    local: list[dict[str, Any]] = []
    tracking: list[dict[str, Any]] = []
    for line in raw.splitlines():
        ref, sha, upstream, symref, date = (line.split("\t") + [""] * 5)[:5]
        if symref:
            continue
        if ref.startswith("refs/heads/"):
            name = ref.removeprefix("refs/heads/")
            row: dict[str, Any] = {
                "name": name, "sha": sha, "upstream": upstream or None,
                "date": date or None,
                "merged_to_default": is_ancestor(root, sha, f"origin/{default}"),
            }
            if upstream:
                row["upstream_divergence"] = rev_divergence(root, sha, upstream)
            local.append(row)
        elif ref.startswith("refs/remotes/"):
            tracking.append({"ref": ref, "sha": sha})
    return local, tracking


def remote_heads(root: Path) -> dict[str, str]:
    heads: dict[str, str] = {}
    for line in git(root, "ls-remote", "--heads", "origin").stdout.splitlines():
        sha, ref = line.split("\t", 1)
        heads[ref.removeprefix("refs/heads/")] = sha
    return heads


def stash_inventory(root: Path) -> list[dict[str, str]]:
    raw = git(root, "stash", "list",
              "--format=%gd%x00%H%x00%ci%x00%gs").stdout
    rows: list[dict[str, str]] = []
    for line in raw.splitlines():
        parts = line.split("\0", 3)
        if len(parts) == 4:
            rows.append(dict(zip(("selector", "sha", "date", "message"), parts)))
    return rows


def validate_retain_ledger(doc: Any) -> list[dict[str, str]]:
    if not isinstance(doc, dict) or doc.get("schema") != "janitor-retain/v1":
        raise ValueError("expected schema 'janitor-retain/v1'")
    raw_items = doc.get("items")
    if not isinstance(raw_items, list):
        raise ValueError("items must be an array")
    required = ("id", "target", "disposition", "reason", "review_when")
    items: list[dict[str, str]] = []
    seen: set[str] = set()
    for index, raw in enumerate(raw_items):
        if not isinstance(raw, dict):
            raise ValueError(f"items[{index}] must be an object")
        item: dict[str, str] = {}
        for key in required:
            value = raw.get(key)
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"items[{index}].{key} must be a non-empty string")
            item[key] = value.strip()
        if item["id"] in seen:
            raise ValueError(f"duplicate item id {item['id']!r}")
        seen.add(item["id"])
        items.append(item)
    return items


def retain_ledger(common_dir: Path, warnings: list[str]) -> dict[str, Any]:
    """The repository's retain ledger, read from the *common* directory.

    `git rev-parse --git-common-dir` rather than `--git-dir`, so a census run
    from any linked worktree reads the one ledger the repository has instead of
    a per-worktree one no other run would see. Nothing tracks the file.

    `items` is always present, and is `None` exactly when the ledger exists but
    could not be read. An unreadable ledger reported as an empty one would tell
    the janitor that nothing is retained, which is the reading under which it
    would propose deleting everything the ledger was protecting.

    Presence is `os.path.lexists`, not `Path.exists()`: the question is whether
    a directory entry is there, not whether following it lands on a file. A
    dangling symlink is an entry that exists and cannot be read, so it belongs
    in the unreadable case below; `exists()` follows the link and would answer
    "absent" -- `items: []` -- for a ledger the operator can see in the
    directory listing.
    """
    path = common_dir / RETAIN_LEDGER
    if not os.path.lexists(path):
        return {"present": False, "items": []}
    result: dict[str, Any] = {"present": True, "path": str(path), "items": None}
    try:
        if not path.is_file() or path.is_symlink():
            raise ValueError("must be a regular, non-symlink file")
        if path.stat().st_size > RETAIN_LEDGER_LIMIT:
            raise ValueError(f"exceeds {RETAIN_LEDGER_LIMIT} bytes")
        doc = json.loads(path.read_text(encoding="utf-8"))
        result["items"] = validate_retain_ledger(doc)
    except (OSError, UnicodeError, ValueError) as error:
        result["error"] = str(error)
        warnings.append(f"janitor retain ledger unreadable: {error}")
    return result


def holding_directories(common_dir: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in sorted(common_dir.glob("autostash-*")):
        row: dict[str, Any] = {"path": str(path), "kind": "symlink" if path.is_symlink()
                               else "directory" if path.is_dir() else "other"}
        if path.is_dir() and not path.is_symlink():
            files = [p for p in path.rglob("*") if p.is_file() and not p.is_symlink()]
            row["files"] = len(files)
            row["bytes"] = sum(p.stat().st_size for p in files)
        rows.append(row)
    return rows


def drainer_controller() -> Path:
    """The PR drainer's controller, resolved the way every other component
    resolves it, through `kanban_config.drainer_install_dir()`.

    That function is this repository's one Python resolution point for the
    drainer's install directory: the KANBAN_DRAINER_INSTALL_DIR override first,
    then whichever of the two managed locations actually holds an installation
    -- `~/.local/share/kanban/pr-drainer` as the XDG data root spells it, and
    `~/Library/Application Support/kanban/pr-drainer` -- and only then this
    platform's own write path. Those two locations are written out here to
    ground this file in the contract's `drainer-install-dir` and
    `drainer-install-dir-xdg` rows; neither literal is what runs. Spelling
    either one here instead would find nothing on a Linux host, ignore the
    override, and ignore an `--install-dir` install.
    """
    return kanban_config_module().drainer_install_dir() / DRAINER_CONTROLLER


def drainer_status(root: Path) -> dict[str, Any]:
    try:
        controller = drainer_controller()
    except CensusError as error:
        # Fail soft, and distinguishably: a census is a read, so a controller
        # this run could not even locate is reported rather than raised. The
        # `error` key is what separates it from the plain absence below.
        return {"available": False, "error": str(error)}
    if not controller.is_file():
        return {"available": False}
    done = run([sys.executable, str(controller), "--path", str(root),
                "--json", "status"], root, check=False)
    if done.returncode != 0:
        return {"available": True, "error": (done.stderr or done.stdout).strip()}
    try:
        doc = json.loads(done.stdout)
    except ValueError as error:
        return {"available": True, "error": f"invalid status JSON: {error}"}
    keys = ("state", "launchd_loaded", "operation", "last_activity",
            "open_incidents", "cleanup_obligations", "kept_autostash_anchors",
            "drainer_stashes")
    return {"available": True, **{key: doc.get(key) for key in keys}}


def test_coordinator_status(root: Path, common_dir: Path) -> dict[str, Any]:
    """Active test runs and proposals, when this host has a test coordinator.

    An optional, external dependency: $CODEX_HOME -- `~/.codex` by default --
    may hold a personal test skill whose coordinator this reads. Nothing in
    either bundle installs one, so the absent case is the ordinary one and is
    reported as `available: false` rather than as an error.
    """
    codex_root = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    coordinator = codex_root / "skills/test/scripts/test_coordinator.py"
    registry = common_dir / "codex-test/registry.json"
    if not coordinator.is_file():
        return {"available": False}
    if not registry.is_file():
        return {"available": True, "initialized": False}
    commands = (
        ("runs", ["list", "--repo", str(root), "--active", "--json"]),
        ("proposals", ["proposal-list", "--repo", str(root), "--active", "--json"]),
    )
    docs: dict[str, Any] = {}
    for key, args in commands:
        done = run([sys.executable, str(coordinator), *args], root, check=False)
        if done.returncode != 0:
            return {"available": True, "initialized": True,
                    "error": (done.stderr or done.stdout).strip()}
        try:
            docs[key] = json.loads(done.stdout)
        except ValueError as error:
            return {"available": True, "initialized": True,
                    "error": f"invalid {key} JSON: {error}"}
    paths = docs["runs"].get("paths", {})
    runs = [{key: row.get(key) for key in
             ("run_id", "test_id", "status", "heartbeat_at", "worktree_path")}
            for row in docs["runs"].get("runs", [])]
    proposals = [{key: row.get(key) for key in
                  ("proposal_id", "test_id", "status", "created_at")}
                 for row in docs["proposals"].get("proposals", [])]
    return {"available": True, "initialized": True,
            "base_worktree": paths.get("base_worktree"),
            "active_runs": runs, "active_proposals": proposals}


def github_inventory(root: Path, warnings: list[str]) -> dict[str, Any]:
    try:
        repository = gh(root, "repo", "view", "--json", "nameWithOwner")["nameWithOwner"]
        issues_raw = gh(root, "issue", "list", "--state", "open", "--limit", "1000",
                        "--json", "number,assignees,labels")
        prs_raw = gh(root, "pr", "list", "--state", "open", "--limit", "1000",
                     "--json", "number,headRefName,headRefOid,labels,"
                               "closingIssuesReferences,mergeable,mergeStateStatus,"
                               "updatedAt,isDraft")
    except (CensusError, KeyError, ValueError) as error:
        warnings.append(f"GitHub census unavailable: {error}")
        return {"available": False}
    if len(issues_raw) == 1000:
        warnings.append("open-issue census reached its 1000-item limit")
    if len(prs_raw) == 1000:
        warnings.append("open-PR census reached its 1000-item limit")

    open_issues = sorted(item["number"] for item in issues_raw)
    claims: list[dict[str, Any]] = []
    claim_by_issue: dict[int, dict[str, Any]] = {}
    for item in issues_raw:
        labels = [label["name"] for label in item.get("labels", [])]
        assignees = [entry["login"] for entry in item.get("assignees", [])]
        if assignees or "wip" in labels:
            claim = {"issue": item["number"], "assignees": assignees,
                     "wip": "wip" in labels}
            claims.append(claim)
            claim_by_issue[item["number"]] = claim

    prs: list[dict[str, Any]] = []
    for item in prs_raw:
        closing = []
        for issue in item.get("closingIssuesReferences", []):
            owner = issue.get("repository", {}).get("owner", {}).get("login")
            name = issue.get("repository", {}).get("name")
            if f"{owner}/{name}".casefold() == repository.casefold():
                closing.append(issue["number"])
        prs.append({
            "number": item["number"], "head": item["headRefName"],
            "head_sha": item["headRefOid"],
            "labels": [label["name"] for label in item.get("labels", [])],
            "closing_issues": sorted(closing), "mergeable": item.get("mergeable"),
            "merge_state": item.get("mergeStateStatus"),
            "updated": item.get("updatedAt"), "draft": item.get("isDraft", False),
        })
    return {"available": True, "issues_complete": len(issues_raw) < 1000,
            "prs_complete": len(prs_raw) < 1000,
            "repository": repository,
            "open_issue_numbers": open_issues, "claims": claims,
            "open_prs": prs, "_claim_by_issue": claim_by_issue}


def derived_signals(worktrees: list[dict[str, Any]], local: list[dict[str, Any]],
                    heads: dict[str, str], github: dict[str, Any],
                    default: str) -> dict[str, Any]:
    if not github.get("available"):
        return {}
    open_issues = set(github["open_issue_numbers"])
    issues_complete = github.get("issues_complete", True)
    prs_complete = github.get("prs_complete", True)
    claims = github["_claim_by_issue"]
    prs = github["open_prs"]
    prs_by_issue: dict[int, list[int]] = defaultdict(list)
    for pr in prs:
        for number in pr["closing_issues"]:
            prs_by_issue[number].append(pr["number"])

    issue_worktrees: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for wt in worktrees:
        number = wt.get("issue")
        if number is not None:
            issue_worktrees[number].append(wt)

    review_worktrees = [
        {"path": wt["path"], "target": wt["review_target"],
         "exists": wt["exists"], "dirty": wt["status"].get("count")}
        for wt in worktrees if wt.get("review_target")
    ]

    stale_claims = []
    unknown_claim_linkage = []
    for number, claim in claims.items():
        if not issue_worktrees.get(number) and not prs_by_issue.get(number):
            (stale_claims if prs_complete else unknown_claim_linkage).append(claim)

    limbo = []
    zombies = []
    unknown_issue_state = []
    unknown_pr_linkage = []
    signal_mismatches = []
    for number, rows in sorted(issue_worktrees.items()):
        if number not in open_issues and issues_complete:
            zombies.append({"issue": number, "worktrees": [row["path"] for row in rows]})
        elif number not in open_issues:
            unknown_issue_state.append({"issue": number,
                                        "worktrees": [row["path"] for row in rows]})
        elif not prs_by_issue.get(number) and prs_complete:
            limbo.append({"issue": number, "claimed": number in claims,
                          "worktrees": [row["path"] for row in rows]})
        elif not prs_by_issue.get(number):
            unknown_pr_linkage.append({"issue": number,
                                       "worktrees": [row["path"] for row in rows]})
        if len(rows) > 1:
            signal_mismatches.append({"issue": number, "problem": "multiple worktrees",
                                      "worktrees": [row["path"] for row in rows]})
    for number, pr_numbers in sorted(prs_by_issue.items()):
        if len(pr_numbers) > 1:
            signal_mismatches.append({"issue": number,
                                      "problem": "multiple open closing PRs",
                                      "pull_requests": pr_numbers})
        if number in open_issues and number not in claims:
            signal_mismatches.append({"issue": number,
                                      "problem": "open PR but no assignee/wip",
                                      "pull_requests": pr_numbers})

    worktree_branches = {wt.get("branch") for wt in worktrees if wt.get("branch")}
    pr_heads = {pr["head"] for pr in prs}
    local_by_name = {row["name"]: row for row in local}
    pr_head_mismatches = []
    for pr in prs:
        row = local_by_name.get(pr["head"])
        if row and row["sha"] != pr["head_sha"]:
            pr_head_mismatches.append({"pull_request": pr["number"],
                                       "branch": pr["head"],
                                       "local_sha": row["sha"],
                                       "pr_sha": pr["head_sha"]})
    workflow_divergence = [
        {"branch": row["name"], **row["upstream_divergence"]}
        for row in local if WORKFLOW_BRANCH.match(row["name"])
        and row.get("upstream_divergence")
        and any(row["upstream_divergence"].values())
    ]
    unattached_local = [
        {**row, "workflow_owned": bool(WORKFLOW_BRANCH.match(row["name"]))}
        for row in local if row["name"] not in {default, "docs-wip"}
        and row["name"] not in worktree_branches and row["name"] not in pr_heads
    ]
    orphan_remote = [{"name": name, "sha": sha,
                      "merged_to_default": is_ancestor(Path(worktrees[0]["repo_root"]),
                                                        sha, f"origin/{default}")}
                     for name, sha in sorted(heads.items())
                     if name != default and WORKFLOW_BRANCH.match(name)
                     and name not in worktree_branches and name not in pr_heads]
    unclassified_worktrees = [
        {"path": wt["path"], "branch": wt.get("branch"),
         "dirty": wt["status"].get("count"), "exists": wt["exists"]}
        for wt in worktrees if wt.get("branch") not in {default, "docs-wip"}
        and wt.get("issue") is None and wt.get("review_target") is None
        and wt.get("coordinator_role") is None
        and wt.get("branch") not in pr_heads
    ]
    return {"stale_claims": stale_claims, "limbo_issue_worktrees": limbo,
            "zombie_candidates": zombies, "signal_mismatches": signal_mismatches,
            "unknown_issue_state_worktrees": unknown_issue_state,
            "unknown_claim_linkage": unknown_claim_linkage,
            "unknown_pr_linkage_issue_worktrees": unknown_pr_linkage,
            "unattached_local_branches": unattached_local,
            "orphan_workflow_remote_branches": orphan_remote,
            "review_worktrees": review_worktrees,
            "unclassified_worktrees": unclassified_worktrees,
            "open_pr_local_head_mismatches": pr_head_mismatches,
            "workflow_branch_upstream_divergence": workflow_divergence}


def census(repo: Path, *, fetch: bool, local_only: bool) -> dict[str, Any]:
    root = Path(git(repo, "rev-parse", "--show-toplevel").stdout.strip()).resolve()
    warnings: list[str] = []
    if fetch:
        # --no-prune is not a default this can be left to infer: `fetch.prune`
        # is an ordinary configuration a user or a repository may set true, and
        # under it this refresh would delete every stale origin-tracking ref
        # before the census had even reported one. The janitor workflow this
        # program feeds treats a stale tracking ref as an anomaly the user
        # approves individually, so a fetch that pruned them would destroy the
        # very state it exists to inventory, and would do it during the
        # read-only pass. Passed explicitly so the behavior is the program's
        # rather than the host's.
        done = git(root, "fetch", "--no-prune", "origin", check=False)
        if done.returncode != 0:
            warnings.append(f"git fetch origin failed: {(done.stderr or done.stdout).strip()}")
    default = default_branch(root)
    common_dir = Path(git(root, "rev-parse", "--path-format=absolute",
                          "--git-common-dir").stdout.strip())
    worktrees = parse_worktrees(git(root, "worktree", "list", "--porcelain").stdout)
    for wt in worktrees:
        path = Path(wt["path"])
        branch_ref = wt.get("branch")
        branch = branch_ref.removeprefix("refs/heads/") if branch_ref else None
        wt["branch"] = branch
        wt["exists"] = path.is_dir()
        wt["status"] = worktree_status(path)
        wt["operations"] = operation_state(path)
        wt["issue"] = issue_number(branch, wt["path"])
        wt["review_target"] = review_target(wt["path"])
        wt["repo_root"] = str(root)
    test_state = test_coordinator_status(root, common_dir)
    test_paths = {row.get("worktree_path") for row in test_state.get("active_runs", [])}
    for wt in worktrees:
        if wt["path"] == test_state.get("base_worktree"):
            wt["coordinator_role"] = "test-base"
        elif wt["path"] in test_paths:
            wt["coordinator_role"] = "active-test-run"
    local, tracking = branch_inventory(root, default)
    heads = remote_heads(root)
    live_refs = {f"refs/remotes/origin/{name}" for name in heads}
    stale_tracking = [row for row in tracking
                      if row["ref"].startswith("refs/remotes/origin/")
                      and row["ref"] not in live_refs]
    configured_remotes = sorted(git(root, "remote").stdout.split())
    missing_remote_tracking = []
    other_remote_tracking = []
    for row in tracking:
        relative = row["ref"].removeprefix("refs/remotes/")
        remote = relative.split("/", 1)[0]
        if remote == "origin":
            continue
        if remote not in configured_remotes:
            missing_remote_tracking.append(row)
        else:
            other_remote_tracking.append(row)
    github = {"available": False} if local_only else github_inventory(root, warnings)
    signals = derived_signals(worktrees, local, heads, github, default)
    open_issue_count = len(github.get("open_issue_numbers", []))
    github.pop("_claim_by_issue", None)
    github.pop("open_issue_numbers", None)
    if github.get("available"):
        github["open_issue_count"] = open_issue_count
    for wt in worktrees:
        wt.pop("repo_root", None)
        if wt.get("issue") is None:
            wt.pop("issue", None)
        if wt.get("review_target") is None:
            wt.pop("review_target", None)
    default_divergence = rev_divergence(root, default, f"origin/{default}")
    result = {
        "schema": "janitor-census/v1", "repo_root": str(root),
        "default_branch": default,
        "default_head": git(root, "rev-parse", default).stdout.strip(),
        "remote_default_head": git(root, "rev-parse", f"origin/{default}").stdout.strip(),
        "default_divergence": default_divergence,
        "worktrees": worktrees, "local_branches": local,
        "remote_heads": [{"name": name, "sha": sha} for name, sha in sorted(heads.items())],
        "stale_tracking_refs": stale_tracking, "stashes": stash_inventory(root),
        "configured_remotes": configured_remotes,
        "tracking_refs_for_missing_remotes": missing_remote_tracking,
        "other_remote_tracking_refs": other_remote_tracking,
        "retain_ledger": retain_ledger(common_dir, warnings),
        "drainer": drainer_status(root),
        "drainer_untracked_holdings": holding_directories(common_dir),
        "test_coordinator": test_state,
        "github": github, "signals": signals, "warnings": warnings,
    }
    retained_items = result["retain_ledger"]["items"]
    result["counts"] = {
        "worktrees": len(worktrees), "dirty_worktrees": sum(
            1 for wt in worktrees if wt["status"].get("count")),
        "local_branches": len(local), "remote_heads": len(heads),
        "stale_tracking_refs": len(stale_tracking), "stashes": len(result["stashes"]),
        "open_issues": open_issue_count,
        "open_prs": len(github.get("open_prs", [])),
        "retained_items": (
            None if retained_items is None else len(retained_items)
        ),
    }
    return result


def self_test() -> None:
    raw = ("worktree /tmp/main\nHEAD abc\nbranch refs/heads/master\n\n"
           "worktree /tmp/review\nHEAD def\ndetached\nprunable gitdir file points nowhere\n\n")
    rows = parse_worktrees(raw)
    assert rows[0]["branch"] == "refs/heads/master"
    assert rows[1]["detached"] is True and rows[1]["prunable"]
    assert issue_number("issue-42-example", "/tmp/nope") == 42
    assert issue_number(None, "/tmp/issue-77-repair") == 77
    assert issue_number("feature", "/tmp/nope") is None
    assert review_target("/tmp/approve-issues-1492-abcd") == {
        "kind": "issue", "number": 1492}
    assert review_target("/tmp/repo-pr-42-abcd") == {
        "kind": "pull_request", "number": 42}
    summary = summarize_status(" M a\n?? b\n", limit=1)
    assert summary == {"count": 2, "entries": [" M a"], "truncated": True}
    assert summarize_status("") == {"count": 0}
    assert WORKFLOW_BRANCH.match("kanban-drainer/merge-9")
    assert not WORKFLOW_BRANCH.match("docs-wip")
    ledger = validate_retain_ledger({
        "schema": "janitor-retain/v1",
        "items": [{"id": "keep-one", "target": "branch docs-wip:path",
                   "disposition": "retain", "reason": "durable state",
                   "review_when": "its owning workflow completes"}],
    })
    assert ledger[0]["id"] == "keep-one"
    try:
        validate_retain_ledger({"schema": "janitor-retain/v1", "items": [
            {"id": "duplicate", "target": "a", "disposition": "retain",
             "reason": "one", "review_when": "later"},
            {"id": "duplicate", "target": "b", "disposition": "retain",
             "reason": "two", "review_when": "later"},
        ]})
    except ValueError:
        pass
    else:
        raise AssertionError("duplicate retain-ledger IDs were accepted")
    # A repository with no ledger has no retained items, which is an empty
    # list; `null` is reserved for a ledger that exists and could not be read.
    assert retain_ledger(Path("/nonexistent") / "janitor-census-self-test", []) == {
        "present": False, "items": []}
    # Resolved, not spelled -- and this also proves the bundle shipped the
    # configuration module beside this one, since loading it is the only way
    # the controller can be named at all.
    controller = drainer_controller()
    assert controller.name == DRAINER_CONTROLLER
    assert controller.parent == kanban_config_module().drainer_install_dir()
    print("census self-test: PASS")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=os.getcwd())
    parser.add_argument("--fetch", action="store_true",
                        help="refresh origin without pruning before the census")
    parser.add_argument("--local-only", action="store_true",
                        help="skip GitHub queries")
    parser.add_argument("--pretty", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    try:
        result = census(Path(args.repo), fetch=args.fetch,
                        local_only=args.local_only)
    except CensusError as error:
        print(f"janitor census: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2 if args.pretty else None,
                     sort_keys=True, separators=None if args.pretty else (",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
