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
mechanism module does, and each resolves the project-review liveness
adapter from its own bundle, whose two layouts put it in different places.

Three of its collections are answered by a program rather than by Git or
GitHub, and all three are spawned as `sys.executable`: the PR drainer's
controller, the optional personal test coordinator, and -- since issue
#706 -- the project-review liveness adapter, which is the only thing
entitled to say whether one abandoned attempt directory is still in use.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

STATUS_LIMIT = 200
RETAIN_LEDGER = "janitor-retain.json"
RETAIN_LEDGER_LIMIT = 256 * 1024
DRAINER_CONTROLLER = "drain_prs_service.py"
# Where `project-review` puts one directory per invocation (issue #684), under
# the Git common directory every worktree of the audited repository shares, and
# the adapter whose `status` subcommand is the only thing entitled to say what
# state one of those attempts is in (issue #706, requirement 2).
PROJECT_REVIEW_RUNTIME = "kanban-project-review/worktrees"
ATTEMPT_TREE = "tree"
LIVENESS_ADAPTER = "project_review_liveness.py"
LIVENESS_BUNDLE_CANDIDATES = (
    LIVENESS_ADAPTER,
    f"../../project-review/scripts/{LIVENESS_ADAPTER}",
)
LIVENESS_REFUSAL = re.compile(r"refused \((?P<reason>[a-z-]+)\)")
KEEPER_STANDINGS = frozenset({"live", "gone", "unverifiable"})
ATTEMPT_STATES = frozenset({"ended", "active"})
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


def liveness_adapter() -> Path:
    """The project-review liveness adapter, from this census's own bundle.

    Issue #706 requirement 2: an attempt's state comes from that adapter's own
    `status` subcommand and from nothing else, so this program has to find it.
    It is resolved relative to *this file* rather than to the audited checkout,
    for the reason the janitor workflow resolves this census the same way: the
    repository under audit need not track any Kanban tooling, and usually does
    not.

    Two candidates, because the two bundles lay their scripts out differently
    while these two copies of this program stay byte-identical. The Claude
    bundle has one shared `scripts/` directory, so the adapter sits beside this
    file; the Codex bundle gives every skill a `scripts/` directory of its own,
    so the janitor's copy sits two levels away from the `project-review`
    skill's copy of the adapter. Both candidates are inside the bundle this
    file was installed as: neither reaches the audited checkout, and neither
    reaches the other bundle.

    Not resolved by importing the adapter as a module. `status` is a subcommand
    with a documented exit code and a documented JSON document, which is the
    whole interface issue #706 is entitled to read; importing would additionally
    pull the adapter's ledger sibling into this process, and the janitor's read
    side would then depend on an execution model that issue owns rather than on
    the interface it publishes.
    """
    beside = Path(__file__).resolve().parent
    candidates = [
        (beside / relative).resolve() for relative in LIVENESS_BUNDLE_CANDIDATES
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise CensusError(
        "this bundle ships no project-review liveness adapter (looked for "
        + ", ".join(str(candidate) for candidate in candidates)
        + ")"
    )


def directory_footprint(path: Path) -> dict[str, Any]:
    """How many files a directory holds and how many bytes they occupy.

    `null` for both when the walk failed, with the reason: requirement 1 asks
    for the space an abandoned attempt costs, and a measurement this program
    could not make is not a measurement of zero. That is also why `onerror`
    re-raises: `os.walk` ignores a directory it cannot list by default, which
    would report a *smaller* footprint for a directory that could not be read
    rather than no footprint at all.

    Every symlink is counted as one entry of its own `lstat` size and is never
    followed, dangling and directory links included, so a link into the
    operator's home directory contributes its own few bytes rather than that
    tree's gigabytes -- and contributes them once, rather than being descended
    into and counted again. `os.walk` with `followlinks=False` rather than
    `Path.rglob`, because whether `**` descends through a directory symlink is
    a property of the Python version and this measurement should not be.
    """
    def reraise(error: OSError) -> None:
        raise error

    files = 0
    total = 0
    try:
        for directory, subdirectories, names in os.walk(
            path, onerror=reraise, followlinks=False
        ):
            base = Path(directory)
            for name in names:
                files += 1
                total += (base / name).lstat().st_size
            for name in subdirectories:
                entry = base / name
                if entry.is_symlink():
                    files += 1
                    total += entry.lstat().st_size
    except OSError as error:
        return {"files": None, "bytes": None, "error": str(error)}
    return {"files": files, "bytes": total}


def attempt_status(root: Path, adapter: Path, attempt: str) -> dict[str, Any]:
    """One `project_review_liveness.py status` answer, reduced to this census.

    `--root` is the audited checkout, not a documentation worktree. The
    `project-review` workflow passes its docs worktree there because
    *`register`* reads the renewal interval out of the ledger under that root;
    `status` resolves the Git *common* directory and nothing else, so every
    worktree of the repository names the same records and the audited checkout
    is one of them.

    `state` is this program's own word for what the adapter answered, and the
    three failing spellings are kept apart because the janitor does different
    things with them. `unknown` is only an `attempt-unknown` refusal -- an
    attempt whose records were pruned after seven days, which is *over* and
    never provably idle. `error` is everything else: a refusal of another kind,
    a document that did not parse, a field outside its vocabulary, a spawn that
    failed. That answers neither question, so it stays visible rather than
    collapsing into a safe-looking result.
    """
    done = run(
        [
            sys.executable,
            str(adapter),
            "status",
            "--root",
            str(root),
            "--attempt",
            attempt,
        ],
        root,
        check=False,
    )
    if done.returncode != 0:
        detail = (done.stderr or done.stdout).strip() or f"exit {done.returncode}"
        match = LIVENESS_REFUSAL.search(detail)
        refusal = match.group("reason") if match else None
        return {
            "state": "unknown" if refusal == "attempt-unknown" else "error",
            "refusal": refusal,
            "error": detail,
            "keeper_standing": None,
            "unfinished_launches": None,
        }
    try:
        try:
            document = json.loads(done.stdout)
        except ValueError as error:
            raise ValueError(f"invalid status JSON: {error}") from None
        if not isinstance(document, dict):
            raise ValueError("status did not report a JSON object")
        # Each membership test is guarded by its own `isinstance`, because a
        # set membership test is not a total function: `[] in frozenset(...)`
        # raises TypeError, which is not a ValueError and would leave this
        # census with no document at all. A field JSON allows and this program
        # does not expect has to be one attempt's error, the way every other
        # unusable answer here is.
        state = document.get("status")
        if not isinstance(state, str) or state not in ATTEMPT_STATES:
            raise ValueError(f"status reported the unknown state {state!r}")
        standing = document.get("keeper_standing")
        if standing is not None and (
            not isinstance(standing, str) or standing not in KEEPER_STANDINGS
        ):
            raise ValueError(
                f"status reported the unknown keeper standing {standing!r}"
            )
        launches = document.get("unfinished_launches")
        if not isinstance(launches, list) or not all(
            isinstance(label, str) for label in launches
        ):
            raise ValueError("status reported no readable unfinished_launches list")
    except ValueError as error:
        return {"state": "error", "refusal": None, "error": str(error),
                "keeper_standing": None, "unfinished_launches": None}
    return {"state": state, "refusal": None, "error": None,
            "keeper_standing": standing, "unfinished_launches": sorted(launches)}


def attempt_disposition(state: str, keeper_standing: Any, unfinished: Any,
                        *, measured: bool = True) -> dict[str, Any]:
    """Whether one attempt is over, whether it is provably idle, and why not.

    Two questions rather than one, because they exclude different things.
    `over` is what keeps a running invocation's directory out of the report at
    all -- an `active` attempt whose keeper is `live` belongs to somebody,
    however old its directory looks. `cleanable` is the stronger answer a
    removal may be offered for, and it needs the adapter to have *established*
    that nothing is using the directory rather than merely to have failed to
    say that something is.

    So `unverifiable` is not gone: it is a keeper on another host, or a pid this
    process may not signal. An `attempt-unknown` refusal is weaker still, since
    the adapter has no records left to answer either question from -- that
    attempt is over, because no invocation can be holding records that no longer
    exist, and it is never cleanable. `error` answers neither question and is
    `over: None`.

    `unfinished` is the adapter's `unfinished_launches`, which reports every
    wrapped launch that cannot be established to have ended whether or not its
    tool call finished. Its sibling `exempt_launches` answers the silence-window
    question instead and skips a launch whose call has returned, which is
    exactly the backgrounded command that outlives a cancellation -- so this
    reads the former and nothing else. A non-empty list retains, and so does a
    `None`: a launch inventory this program could not read is not an empty one.

    `measured` is the third retaining fact, and it is about this program rather
    than the adapter: an attempt whose age or footprint could not be taken is
    one whose directory this census could not fully read, and the removal it
    would be offered for is recursive. A subdirectory that cannot be listed is
    exactly where something worth keeping would sit unseen -- the `tree/` gate
    proves the pinned *checkout* is clean and says nothing about the rest of the
    directory -- so an unknown size retains even when the adapter's own two
    answers are positive. It does not make the attempt any less `over`: whether
    an invocation is holding it is the adapter's question, and nothing here
    changes that answer.
    """
    if state == "error":
        return {"over": None, "cleanable": False,
                "retention_reasons":
                    ["the adapter did not report this attempt's state"]}
    if state == "active" and keeper_standing == "live":
        return {"over": False, "cleanable": False,
                "retention_reasons": ["a live keeper is holding this attempt"]}
    reasons: list[str] = []
    if not measured:
        reasons.append(
            "this census could not fully measure the directory, so its "
            "contents are unaccounted for"
        )
    if state == "unknown":
        reasons.append(
            "the adapter no longer knows this attempt, so neither its keeper "
            "nor its launches can be established"
        )
    elif state == "active" and keeper_standing != "gone":
        standing = keeper_standing if isinstance(keeper_standing, str) else "unreported"
        reasons.append(f"the keeper's standing is {standing} rather than gone")
    if unfinished is None:
        if state != "unknown":
            reasons.append("the adapter reported no readable launch inventory")
    elif unfinished:
        reasons.append("wrapped launches are still running: " + ", ".join(unfinished))
    return {"over": True, "cleanable": not reasons, "retention_reasons": reasons}


def project_review_attempts(root: Path, common_dir: Path,
                            registered: set[str],
                            warnings: list[str]) -> dict[str, Any]:
    """Every directory `project-review` left under the Git common directory.

    Requirement 1 is the whole inventory, healthy running attempts included;
    which of these rows reaches the operator's anomaly report is the janitor
    workflow's own decision. Requirement 6 is the empty case: a repository that
    has never run `project-review`, or whose last run cleaned up after itself,
    reports `present: false` or an empty list and is not an anomaly.

    `attempts` is `null` exactly when the directory exists and could not be
    listed, which is the same rule `retain_ledger` follows: an unreadable
    inventory reported as an empty one would tell the janitor that nothing was
    left behind.
    """
    directory = common_dir / PROJECT_REVIEW_RUNTIME
    result: dict[str, Any] = {"root": str(directory), "present": False,
                              "adapter": None, "attempts": []}
    if not os.path.lexists(directory):
        return result
    result["present"] = True
    try:
        names = sorted(
            entry.name
            for entry in os.scandir(directory)
            if entry.is_dir() and not entry.is_symlink()
        )
    except OSError as error:
        result["attempts"] = None
        result["error"] = str(error)
        warnings.append(f"project-review attempt directory unreadable: {error}")
        return result
    if not names:
        return result
    adapter: Path | None
    try:
        adapter = liveness_adapter()
    except CensusError as error:
        # Reported, never raised: a census is a read, and an adapter this run
        # could not locate must leave every attempt visibly unresolved rather
        # than absent. Absent would read as "nothing to clean up".
        adapter = None
        warnings.append(f"project-review liveness adapter unavailable: {error}")
    else:
        result["adapter"] = str(adapter)
    now = time.time()
    rows: list[dict[str, Any]] = []
    for name in names:
        path = directory / name
        row: dict[str, Any] = {"attempt": name, "path": str(path)}
        try:
            modified = path.stat().st_mtime
            # Inside the guard with the `stat`, not beside it: a timestamp this
            # platform cannot represent raises from here rather than from the
            # `stat`, and an age that cannot be computed is one row's unknown
            # rather than the whole census's failure.
            row["modified"] = datetime.fromtimestamp(
                modified, timezone.utc
            ).isoformat()
            row["age_seconds"] = round(max(0.0, now - modified), 3)
        except (OSError, OverflowError, ValueError) as error:
            row["modified"] = None
            row["age_seconds"] = None
            row["measurement_error"] = str(error)
            warnings.append(f"project-review attempt {name} could not be aged: {error}")
        footprint = directory_footprint(path)
        row["files"] = footprint["files"]
        row["bytes"] = footprint["bytes"]
        if footprint.get("error"):
            row["measurement_error"] = footprint["error"]
            warnings.append(
                f"project-review attempt {name} could not be measured: "
                f"{footprint['error']}"
            )
        tree = path / ATTEMPT_TREE
        row["tree"] = {
            "path": str(tree),
            "present": tree.is_dir(),
            "registered": str(tree) in registered
            or os.path.realpath(tree) in registered,
        }
        if adapter is None:
            status = {
                "state": "error", "refusal": None,
                "error": "this bundle ships no project-review liveness adapter",
                "keeper_standing": None, "unfinished_launches": None,
            }
        else:
            try:
                status = attempt_status(root, adapter, name)
            except CensusError as error:
                # An adapter that could not be spawned, or that ran past `run`'s
                # timeout, is one attempt's answer missing rather than the
                # census's. Raising here would lose every other collection this
                # document carries, and a janitor with no document cleans
                # nothing -- but it would also lose the *other* attempts, which
                # is how one wedged adapter call would hide four directories.
                status = {"state": "error", "refusal": None, "error": str(error),
                          "keeper_standing": None, "unfinished_launches": None}
        for key in ("state", "refusal", "keeper_standing", "unfinished_launches"):
            row[key] = status[key]
        if status["error"] is not None:
            row["status_error"] = status["error"]
            if status["state"] == "error":
                warnings.append(
                    f"project-review attempt {name} state unresolved: "
                    f"{status['error']}"
                )
        row.update(
            attempt_disposition(
                status["state"], status["keeper_standing"],
                status["unfinished_launches"],
                measured="measurement_error" not in row,
            )
        )
        rows.append(row)
    result["attempts"] = rows
    return result


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
        and wt.get("project_review_attempt") is None
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
    registered_paths = {wt["path"] for wt in worktrees}
    registered_paths |= {os.path.realpath(wt["path"]) for wt in worktrees}
    attempts = project_review_attempts(root, common_dir, registered_paths, warnings)
    # A pinned attempt worktree is that attempt's, not an unexplained detached
    # checkout. Marking it is what keeps it out of `unclassified_worktrees`,
    # where a live invocation's tree would otherwise be offered for an ordinary
    # `git worktree remove` with none of the attempt gates applied to it.
    attempt_trees: dict[str, str] = {}
    for row in attempts["attempts"] or []:
        attempt_trees[row["tree"]["path"]] = row["attempt"]
        attempt_trees[os.path.realpath(row["tree"]["path"])] = row["attempt"]
    for wt in worktrees:
        owner = attempt_trees.get(wt["path"]) or attempt_trees.get(
            os.path.realpath(wt["path"])
        )
        if owner is not None:
            wt["project_review_attempt"] = owner
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
        "project_review_attempts": attempts,
        "drainer": drainer_status(root),
        "drainer_untracked_holdings": holding_directories(common_dir),
        "test_coordinator": test_state,
        "github": github, "signals": signals, "warnings": warnings,
    }
    retained_items = result["retain_ledger"]["items"]
    attempt_rows = attempts["attempts"]
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
        "project_review_attempts": (
            None if attempt_rows is None else len(attempt_rows)
        ),
        "cleanable_project_review_attempts": (
            None if attempt_rows is None
            else sum(1 for row in attempt_rows if row["cleanable"])
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
    # The two questions issue #706 keeps apart, one case each. Collapsing them
    # is the defect its review names: `over` alone would offer a removal for an
    # attempt whose records were pruned, which proves nothing about whether
    # anything is still working in its directory.
    assert attempt_disposition("active", "live", []) == {
        "over": False, "cleanable": False,
        "retention_reasons": ["a live keeper is holding this attempt"]}
    assert attempt_disposition("ended", None, []) == {
        "over": True, "cleanable": True, "retention_reasons": []}
    assert attempt_disposition("active", "gone", []) == {
        "over": True, "cleanable": True, "retention_reasons": []}
    for standing in (None, "unverifiable"):
        retained = attempt_disposition("active", standing, [])
        assert retained["over"] is True and retained["cleanable"] is False
        assert "rather than gone" in retained["retention_reasons"][0]
    pruned = attempt_disposition("unknown", None, None)
    assert pruned["over"] is True and pruned["cleanable"] is False
    assert pruned["retention_reasons"] == [
        "the adapter no longer knows this attempt, so neither its keeper nor "
        "its launches can be established"]
    busy = attempt_disposition("ended", None, ["build"])
    assert busy["over"] is True and busy["cleanable"] is False
    assert busy["retention_reasons"] == [
        "wrapped launches are still running: build"]
    unreadable = attempt_disposition("ended", None, None)
    assert unreadable["over"] is True and unreadable["cleanable"] is False
    # A directory this census could not fully read is still over -- that is the
    # adapter's answer -- and is never offered a recursive removal.
    unmeasured = attempt_disposition("ended", "gone", [], measured=False)
    assert unmeasured["over"] is True and unmeasured["cleanable"] is False
    assert unmeasured["retention_reasons"] == [
        "this census could not fully measure the directory, so its contents "
        "are unaccounted for"]
    assert attempt_disposition("active", "live", [], measured=False)["over"] is False
    broken = attempt_disposition("error", None, None)
    assert broken["over"] is None and broken["cleanable"] is False
    # Resolved from this file's own bundle, which is also the only way either
    # copy can name the adapter at all -- so this proves the bundle ships it.
    assert liveness_adapter().name == LIVENESS_ADAPTER
    # A repository that never ran `project-review` has no attempts, which is an
    # empty list and not an anomaly; `null` stays reserved for a directory that
    # exists and could not be listed.
    assert project_review_attempts(
        Path("/nonexistent"), Path("/nonexistent") / "census-self-test", set(), []
    )["attempts"] == []
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
