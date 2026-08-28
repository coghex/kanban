#!/usr/bin/env python3
"""The project-review sweep cursor: durable state, and the selection built from it.

Run with: python3 project_review_cursor.py {read,select,record} --help

Issue #548. The vendored `project-review` workflow used to keep its cursor in
conversation context and update a boundary file only when a user asked for it,
so a completed batch left nothing behind. A clean batch left even less: it is
forbidden to write an empty report, so it produced no filename to recover from
either. The next invocation then guessed a range from whatever it could still
see, and the guess was wrong twice while `docs/project_review_466-399.md` was
being produced.

Prose alone cannot fix that, because prose is what already said "preserve the
cursor". What was missing is a mechanism that owns the state: this module. The
workflow reads its selection from `select` before it reviews anything, and
writes its endpoint through `record` after the batch is complete. Both halves
are exercised by `tools/test_project_review_workflow.py` as real state
transitions rather than as sentences found in a rendered asset.

Three rules shape everything below, and each one is a defect that was observed
rather than a preference:

* **The record is the only authority for coverage.** A report's filename
  interval is a claim about a batch, not an enumeration of it: the report named
  `463-455` reviewed #463, #456 and #455 and nothing between them, so reading
  its interval as nine reviewed pull requests would erase six unreviewed ones.
  Only the two filename endpoints are taken from a report, because the filename
  rule guarantees those two were reviewed. Under-counting costs a re-review;
  over-counting loses a unit silently, and only one of those is recoverable. For
  the same reason a report says what to *skip* and never where to *resume*:
  resuming below one would put everything it skipped inside its own interval
  permanently out of reach.
* **A report never establishes direct-commit coverage at all.** That same
  report states that no direct-to-default-branch first-parent commits landed
  inside its interval while eight did. So a first-parent commit is covered when the record
  says it was reviewed, and is otherwise selectable — never dropped because some
  report's prose claimed its interval was empty.
* **The frontier is merge order, not numeric order.** `mergedAt` orders pull
  requests; the number does not. The batch named `466-399` reviewed #466, #467,
  #465, #464, #406 … in that order, so a cursor holding "the smallest number
  reviewed" would describe a batch that never happened.

Everything the module cannot prove, it refuses. A recorded endpoint absent from
the history it is supposed to index is a cursor belonging to some other
repository, and a state document it cannot parse is a state document that might
mean anything; both raise `CursorError` before a unit is selected rather than
being treated as "no cursor yet". A missing document is the one absence that is
not an error, because that is exactly what a repository that has never been
swept looks like.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from pathlib import Path

# Where the state lives inside the reviewed repository's docs worktree. One
# consumer's cursor, so it stays in that consumer's repository rather than
# travelling with the bundle that ships this module.
DOCUMENT_RELATIVE_PATH = "docs/project_review_boundaries.md"

# The reports the workflow writes, which are reconciled alongside the record.
REPORT_GLOB = "project_review_*.md"

SCHEMA_VERSION = 1

# The document is Markdown so a human can read it in the docs worktree, and its
# payload is one fenced JSON object so this module is the only thing that has to
# understand it. The marker is what the parser anchors on: a document without it
# is not this document, whatever else it may contain.
CURSOR_MARKER = "<!-- project-review:cursor:v1 -->"

PAYLOAD_RE = re.compile(
    re.escape(CURSOR_MARKER) + r"\s*```json\n(?P<payload>.*?)\n```",
    re.DOTALL,
)

MODES = ("pr", "direct")

DOCUMENT_HEADER = """# Project review sweep cursor

Machine-owned state for the `project-review` workflow: the oldest unit each
completed batch reviewed, per repository, plus the units a user explicitly
excluded. A clean batch records its endpoint exactly as a finding-bearing batch
does, which is what lets a later invocation carrying no conversational state
resume immediately below it.

Written by `project_review_cursor.py`. Edit it through that helper rather than
by hand: the payload below is parsed strictly, and an edit it cannot read stops
the next sweep instead of being ignored.
"""

# A short SHA is still a SHA; seven characters is what `git log --abbrev` emits
# and what the direct-mode report filenames carry.
SHA_RE = re.compile(r"\A[0-9a-f]{7,40}\Z")

REPO_RE = re.compile(r"\A[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\Z")


class CursorError(RuntimeError):
    """The state, the history, or the request could not be trusted.

    Always fatal. A caller that treated one of these as "no cursor yet" would
    re-review completed history or sweep past a boundary, which are the two
    outcomes the record exists to prevent.
    """


# --------------------------------------------------------------------------
# The state document


def empty_document() -> dict:
    return {"version": SCHEMA_VERSION, "repositories": {}}


def empty_state() -> dict:
    return {
        "pr": {"endpoint": None, "reviewed": []},
        "direct": {"endpoint": None, "reviewed": []},
        "excluded": {"prs": [], "commits": []},
    }


def document_path(root) -> Path:
    return Path(root) / DOCUMENT_RELATIVE_PATH


def parse_document(text: str, source: str) -> dict:
    """The state a cursor document holds, or a refusal naming what stopped it."""
    match = PAYLOAD_RE.search(text)
    if match is None:
        raise CursorError(
            f"{source} carries no {CURSOR_MARKER} block, so it is not a "
            "project-review cursor. Move it aside or repair it; a sweep will "
            "not treat an unreadable cursor as an absent one."
        )
    try:
        document = json.loads(match.group("payload"))
    except json.JSONDecodeError as error:
        raise CursorError(f"{source} holds unreadable cursor JSON ({error}).") from error
    if not isinstance(document, dict):
        raise CursorError(f"{source} holds a cursor payload that is not an object.")
    version = document.get("version")
    if version != SCHEMA_VERSION:
        raise CursorError(
            f"{source} declares cursor schema version {version!r}; this helper "
            f"reads version {SCHEMA_VERSION}."
        )
    repositories = document.get("repositories")
    if not isinstance(repositories, dict):
        raise CursorError(f"{source} declares no `repositories` object.")
    for name, state in repositories.items():
        if not REPO_RE.match(str(name)):
            raise CursorError(f"{source} names {name!r}, which is not an owner/name.")
        repositories[name] = _validated_state(state, f"{source}: {name}")
    return document


def load_document(root) -> dict:
    """The document under `root`, or an empty one when it does not exist.

    The only absence that is not a refusal: a repository that has never been
    swept has no cursor, and that is the state every first invocation starts in.
    """
    path = document_path(root)
    if not path.exists():
        return empty_document()
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise CursorError(f"{path} could not be read ({error}).") from error
    return parse_document(text, str(path))


def _validated_state(state, source: str) -> dict:
    if not isinstance(state, dict):
        raise CursorError(f"{source} is not an object.")
    validated = empty_state()
    pr = state.get("pr", {})
    direct = state.get("direct", {})
    excluded = state.get("excluded", {})
    if not isinstance(pr, dict) or not isinstance(direct, dict) or not isinstance(excluded, dict):
        raise CursorError(f"{source} holds a `pr`, `direct`, or `excluded` value that is not an object.")
    validated["pr"]["reviewed"] = _validated_numbers(pr.get("reviewed", []), f"{source}: pr.reviewed")
    validated["direct"]["reviewed"] = _validated_shas(direct.get("reviewed", []), f"{source}: direct.reviewed")
    validated["excluded"]["prs"] = _validated_numbers(excluded.get("prs", []), f"{source}: excluded.prs")
    validated["excluded"]["commits"] = _validated_shas(excluded.get("commits", []), f"{source}: excluded.commits")
    pr_endpoint = pr.get("endpoint")
    if pr_endpoint is not None:
        if not isinstance(pr_endpoint, dict):
            raise CursorError(f"{source}: pr.endpoint is not an object.")
        number = pr_endpoint.get("number")
        merged_at = pr_endpoint.get("merged_at")
        if not isinstance(number, int) or isinstance(number, bool) or number <= 0:
            raise CursorError(f"{source}: pr.endpoint.number is not a pull-request number.")
        if not isinstance(merged_at, str) or not merged_at.strip():
            raise CursorError(f"{source}: pr.endpoint.merged_at is not a merge timestamp.")
        validated["pr"]["endpoint"] = {"number": number, "merged_at": merged_at}
    direct_endpoint = direct.get("endpoint")
    if direct_endpoint is not None:
        if not isinstance(direct_endpoint, dict):
            raise CursorError(f"{source}: direct.endpoint is not an object.")
        sha = direct_endpoint.get("sha")
        if not isinstance(sha, str) or not SHA_RE.match(sha):
            raise CursorError(f"{source}: direct.endpoint.sha is not a commit SHA.")
        validated["direct"]["endpoint"] = {"sha": sha}
    return validated


def _validated_numbers(values, source: str) -> list:
    if not isinstance(values, list):
        raise CursorError(f"{source} is not a list.")
    numbers = []
    for value in values:
        if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
            raise CursorError(f"{source} holds {value!r}, which is not a pull-request number.")
        numbers.append(value)
    return sorted(set(numbers))


def _validated_shas(values, source: str) -> list:
    if not isinstance(values, list):
        raise CursorError(f"{source} is not a list.")
    shas = []
    for value in values:
        if not isinstance(value, str) or not SHA_RE.match(value):
            raise CursorError(f"{source} holds {value!r}, which is not a commit SHA.")
        shas.append(value)
    return sorted(set(shas))


def state_for(document: dict, repo: str) -> dict:
    """This repository's entry, defaulted rather than created.

    Reading never writes: a `select` against a repository the document does not
    mention has to behave exactly like a `select` against no document at all.
    """
    state = document.get("repositories", {}).get(repo)
    return json.loads(json.dumps(state)) if state else empty_state()


def render_document(document: dict) -> str:
    payload = json.dumps(document, indent=2, sort_keys=True)
    return f"{DOCUMENT_HEADER}\n{CURSOR_MARKER}\n\n```json\n{payload}\n```\n"


def write_document(root, document: dict) -> Path:
    """Replace the document atomically, creating `docs/` if it is absent.

    Atomic because the alternative to a complete write here is a truncated
    cursor, and a truncated cursor stops every later sweep by design.
    """
    path = document_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=str(path.parent), prefix=".project-review-cursor-")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(render_document(document))
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
    return path


# --------------------------------------------------------------------------
# Reports in the same worktree


def report_coverage(root) -> dict:
    """What the sibling reports contribute, which is deliberately little.

    A `project_review_<A>-<B>.md` name is produced by filename rule 4 from the
    batch's newest and oldest reviewed pull request, so those two numbers were
    certainly reviewed and are taken as covered. Nothing between them is: the
    batch may have skipped most of the interval, and a report that says
    otherwise has already been observed to be wrong.

    A direct-mode report contributes nothing at all. Its interval says nothing
    trustworthy about which first-parent commits inside it were read, so a
    commit in that interval is covered only if the record says so.
    """
    directory = Path(root) / "docs"
    reports = []
    prs = set()
    if not directory.is_dir():
        return {"reports": reports, "prs": sorted(prs)}
    for path in sorted(directory.glob(REPORT_GLOB)):
        name = path.name
        if name == Path(DOCUMENT_RELATIVE_PATH).name:
            continue
        stem = name[len("project_review_"): -len(".md")]
        if stem.startswith("direct_"):
            reports.append({"path": f"docs/{name}", "kind": "direct", "identified": []})
            continue
        identified = []
        parts = stem.split("-")
        if all(part.isdigit() for part in parts) and 1 <= len(parts) <= 2:
            identified = sorted({int(part) for part in parts}, reverse=True)
            prs.update(identified)
            reports.append({"path": f"docs/{name}", "kind": "pr", "identified": identified})
        else:
            reports.append({"path": f"docs/{name}", "kind": "unrecognized", "identified": []})
    return {"reports": reports, "prs": sorted(prs)}


# --------------------------------------------------------------------------
# Candidates


def normalize_candidates(mode: str, raw) -> list:
    """The history a selection is made from, in newest-first order.

    Pull requests are re-sorted here by `mergedAt` because `gh`'s own ordering
    is not merge order and the frontier is a merge-order position. First-parent
    commits keep the order they were given, which is `git log`'s own.
    """
    if mode not in MODES:
        raise CursorError(f"unknown mode {mode!r}")
    if not isinstance(raw, list):
        raise CursorError("the candidate history is not a list.")
    if mode == "pr":
        candidates = []
        seen = set()
        for index, item in enumerate(raw):
            if not isinstance(item, dict):
                raise CursorError(f"candidate {index} is not an object.")
            number = item.get("number")
            merged_at = item.get("mergedAt", item.get("merged_at"))
            if not isinstance(number, int) or isinstance(number, bool) or number <= 0:
                raise CursorError(f"candidate {index} declares no pull-request number.")
            if not isinstance(merged_at, str) or not merged_at.strip():
                raise CursorError(f"pull request #{number} declares no mergedAt, so it cannot be ordered.")
            if number in seen:
                raise CursorError(f"pull request #{number} appears twice in the candidate history.")
            seen.add(number)
            candidates.append({"number": number, "merged_at": merged_at})
        candidates.sort(key=lambda entry: (entry["merged_at"], entry["number"]), reverse=True)
        return candidates
    candidates = []
    seen = set()
    for index, item in enumerate(raw):
        sha = item.get("sha") if isinstance(item, dict) else item
        if not isinstance(sha, str) or not SHA_RE.match(sha.strip()):
            raise CursorError(f"candidate {index} is not a commit SHA: {item!r}")
        sha = sha.strip()
        if sha in seen:
            raise CursorError(f"commit {sha} appears twice in the candidate history.")
        seen.add(sha)
        candidates.append({"sha": sha})
    return candidates


def read_candidates(mode: str, source) -> list:
    """`--candidates` as either JSON or, in direct mode, a plain SHA listing.

    The plain listing is what `git log --first-parent --format=%H` prints, so
    the workflow pipes that in without a transformation step of its own.
    """
    text = sys.stdin.read() if source in (None, "-") else Path(source).read_text(encoding="utf-8")
    stripped = text.strip()
    if not stripped:
        return []
    try:
        return normalize_candidates(mode, json.loads(stripped))
    except json.JSONDecodeError:
        if mode != "direct":
            raise CursorError("the candidate history is not readable JSON.")
        return normalize_candidates(mode, stripped.split())


def key_of(mode: str, candidate: dict):
    return candidate["number"] if mode == "pr" else candidate["sha"]


# --------------------------------------------------------------------------
# Selection


def select(
    state: dict,
    mode: str,
    candidates: list,
    count: int,
    start=None,
    reports=None,
    override_boundary: bool = False,
) -> dict:
    """The next batch, and everything the workflow has to announce about it.

    The position is the recorded frontier's; `count` is only how many units to
    take from it. That split is the whole of the resume contract — a user who
    asks for twenty units is asking for a bigger batch, not for the sweep to
    start somewhere else.
    """
    if mode not in MODES:
        raise CursorError(f"unknown mode {mode!r}")
    if count <= 0:
        raise CursorError(f"a batch of {count} units is not a batch.")
    coverage = report_coverage_from(reports)
    covered = set(state[mode]["reviewed"])
    if mode == "pr":
        covered |= set(coverage["prs"])
    excluded = set(state["excluded"]["prs" if mode == "pr" else "commits"])
    keys = [key_of(mode, candidate) for candidate in candidates]
    position = {key: index for index, key in enumerate(keys)}

    endpoint = state[mode]["endpoint"]
    frontier = None
    if start is not None:
        if start not in position:
            raise CursorError(_absent_start_message(mode, start))
        begin = position[start]
        origin = "explicit-start"
    elif override_boundary:
        # The override is about coverage, so it lifts the whole of it: the
        # recorded position and the units that position was built from. The
        # exclusions stay, because a unit the user removed from the sweep was
        # not removed by a boundary.
        begin = 0
        covered = set()
        origin = "boundary-override"
    elif endpoint is not None:
        frontier = endpoint
        endpoint_key = endpoint["number"] if mode == "pr" else endpoint["sha"]
        if endpoint_key not in position:
            raise CursorError(_absent_endpoint_message(mode, endpoint_key))
        begin = position[endpoint_key] + 1
        origin = "recorded-endpoint"
    else:
        # Reports never set the position, only what to skip once it is set.
        # A report's filename endpoints are the two units it certainly
        # reviewed; everything between them may or may not have been, so
        # resuming *below* a report would drop whatever it skipped inside its
        # own interval and drop it permanently. Resuming above one costs a
        # re-review of two announced units instead, and only one of those two
        # errors can be noticed afterwards.
        begin = 0
        origin = "history-head"

    selected = []
    skipped = []
    for index in range(begin, len(candidates)):
        key = keys[index]
        if key in excluded:
            skipped.append({"unit": key, "reason": "excluded"})
            continue
        if key in covered:
            skipped.append({"unit": key, "reason": "covered"})
            continue
        selected.append(candidates[index])
        if len(selected) == count:
            break

    gaps = [
        keys[index]
        for index in range(0, begin)
        if keys[index] not in covered and keys[index] not in excluded
    ]
    return {
        "mode": mode,
        "count": count,
        "origin": origin,
        "begin_index": begin,
        "frontier": frontier,
        "selected": selected,
        "skipped": skipped,
        "gaps": gaps,
        "covered": sorted(covered & set(keys), key=lambda key: position[key]),
        "excluded": sorted(excluded),
        "reports": coverage["reports"],
        "exhausted": len(selected) < count,
    }


def report_coverage_from(reports) -> dict:
    if reports is None:
        return {"reports": [], "prs": []}
    return reports


def _absent_start_message(mode: str, start) -> str:
    if mode == "pr":
        return (
            f"pull request #{start} is not in this repository's merged history, "
            "so it cannot start a batch. Say so and stop; do not review the "
            "nearest number that exists."
        )
    return (
        f"commit {start} is not in the current first-parent history, so it "
        "cannot start a batch."
    )


def _absent_endpoint_message(mode: str, key) -> str:
    if mode == "pr":
        return (
            f"the recorded endpoint #{key} is absent from this repository's "
            "merged history, so the cursor does not belong to this repository. "
            "Say so and stop rather than sweeping past it."
        )
    return (
        f"the recorded endpoint {key} is absent from the current first-parent "
        "ancestry, so the cursor does not belong to this history. Say so and "
        "stop rather than sweeping past it."
    )


# --------------------------------------------------------------------------
# Recording


def record(
    state: dict,
    mode: str,
    candidates: list,
    reviewed: list,
    excluded=None,
) -> dict:
    """Fold a completed batch into the state, and never let the frontier back up.

    Merging rather than replacing is what keeps a user's earlier exclusion from
    being erased by a later batch, and what makes the endpoint a cumulative
    coverage frontier instead of "wherever the last run happened to stop".
    """
    if mode not in MODES:
        raise CursorError(f"unknown mode {mode!r}")
    keys = [key_of(mode, candidate) for candidate in candidates]
    position = {key: index for index, key in enumerate(keys)}
    updated = json.loads(json.dumps(state))
    for unit in reviewed:
        if unit not in position:
            raise CursorError(
                f"{unit} was reported as reviewed but is absent from the "
                "candidate history, so the endpoint it would set cannot be "
                "ordered."
            )
    for unit in excluded or []:
        if unit not in position:
            raise CursorError(
                f"{unit} was reported as excluded but is absent from the "
                "candidate history."
            )
    if not reviewed and not excluded:
        raise CursorError("a completed batch records at least one reviewed or excluded unit.")

    updated[mode]["reviewed"] = sorted(set(updated[mode]["reviewed"]) | set(reviewed))
    excluded_field = "prs" if mode == "pr" else "commits"
    updated["excluded"][excluded_field] = sorted(
        set(updated["excluded"][excluded_field]) | set(excluded or [])
    )

    if reviewed:
        oldest = max(reviewed, key=lambda unit: position[unit])
        updated[mode]["endpoint"] = _advanced_endpoint(
            mode, updated[mode]["endpoint"], candidates[position[oldest]], position
        )
    return updated


def _advanced_endpoint(mode: str, current, candidate: dict, position: dict):
    proposed = (
        {"number": candidate["number"], "merged_at": candidate["merged_at"]}
        if mode == "pr"
        else {"sha": candidate["sha"]}
    )
    if current is None:
        return proposed
    current_key = current["number"] if mode == "pr" else current["sha"]
    if current_key not in position:
        raise CursorError(_absent_endpoint_message(mode, current_key))
    proposed_key = candidate["number"] if mode == "pr" else candidate["sha"]
    # Older means further down a newest-first history, so the frontier only
    # ever moves to a larger index. A batch taken above it — after an explicit
    # boundary override, say — leaves it where it was.
    return proposed if position[proposed_key] > position[current_key] else current


# --------------------------------------------------------------------------
# Command line


def _unit_list(mode: str, raw):
    if not raw:
        return []
    values = [item for item in re.split(r"[,\s]+", raw.strip()) if item]
    if mode == "pr":
        parsed = []
        for value in values:
            token = value.lstrip("#")
            if not token.isdigit():
                raise CursorError(f"{value!r} is not a pull-request number.")
            parsed.append(int(token))
        return parsed
    for value in values:
        if not SHA_RE.match(value):
            raise CursorError(f"{value!r} is not a commit SHA.")
    return values


def _emit(payload) -> int:
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    subparsers = parser.add_subparsers(dest="command", required=True)

    reader = subparsers.add_parser("read", help="print the recorded state")
    reader.add_argument("--root", required=True, help="the docs worktree holding the cursor")
    reader.add_argument("--repo", help="restrict the output to one owner/name")

    selector = subparsers.add_parser("select", help="choose the next batch")
    selector.add_argument("--root", required=True)
    selector.add_argument("--repo", required=True)
    selector.add_argument("--mode", required=True, choices=MODES)
    selector.add_argument("--count", type=int, default=12)
    selector.add_argument("--start", help="an explicit starting pull request or SHA")
    selector.add_argument(
        "--override-boundary",
        action="store_true",
        help="ignore the recorded endpoint and start at the head of the history",
    )
    selector.add_argument("--candidates", default="-", help="a JSON or SHA listing, or - for stdin")

    recorder = subparsers.add_parser("record", help="fold a completed batch into the state")
    recorder.add_argument("--root", required=True)
    recorder.add_argument("--repo", required=True)
    recorder.add_argument("--mode", required=True, choices=MODES)
    recorder.add_argument("--candidates", default="-")
    recorder.add_argument("--reviewed", default="", help="the units this batch reviewed")
    recorder.add_argument("--exclude", default="", help="units the user excluded from every later batch")
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "read":
        document = load_document(args.root)
        if args.repo:
            return _emit({"repo": args.repo, "state": state_for(document, args.repo)})
        return _emit(document)

    document = load_document(args.root)
    state = state_for(document, args.repo)
    candidates = read_candidates(args.mode, args.candidates)

    if args.command == "select":
        start = _unit_list(args.mode, args.start)
        if len(start) > 1:
            raise CursorError("a batch starts at one unit, not several.")
        return _emit(
            select(
                state,
                args.mode,
                candidates,
                args.count,
                start=start[0] if start else None,
                reports=report_coverage(args.root),
                override_boundary=args.override_boundary,
            )
        )

    updated = record(
        state,
        args.mode,
        candidates,
        _unit_list(args.mode, args.reviewed),
        _unit_list(args.mode, args.exclude),
    )
    document.setdefault("repositories", {})[args.repo] = updated
    path = write_document(args.root, document)
    return _emit({"repo": args.repo, "document": str(path), "state": updated})


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CursorError as error:
        print(f"project-review cursor: {error}", file=sys.stderr)
        raise SystemExit(2)
