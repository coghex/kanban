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

Four rules shape everything below, and each one is a defect that was observed
rather than a preference:

* **PR mode starts at merged HEAD and stops at its boundary.** The PR endpoint
  is an exclusive older boundary, not a resume-below frontier. Every default
  invocation scans newest-first from the latest merge, skips durable coverage,
  and never crosses that boundary. This is what lets merges that landed after
  the previous review be audited instead of reported as gaps and discarded.
* **The record is the durable authority for coverage.** A report's filename
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
* **The boundary is merge order, not numeric order.** `mergedAt` orders pull
  requests; the number does not. The helper therefore resolves the named PR
  inside the sorted merged history before it decides where the exclusive stop
  lies.

A bounded listing is the fifth rule, and the one a count check cannot express.
`gh pr list --limit N` returns a page, and the question a sweep has to answer is
not whether that page holds twelve rows — it is whether twelve *selectable* rows
survive above the recorded boundary once coverage and exclusions come out. A
page that does not reach the boundary cannot prove where to stop, even when its
first twelve rows are selectable. So the caller declares the limit
it used, and a short batch is reported as `truncated` when the page came back at
that limit and `exhausted` only when it came back under it. The same distinction
governs a refusal: a unit absent from a page at its own limit means raise the
limit, not that the unit does not exist.

Everything else the module cannot prove, it refuses. A recorded endpoint absent from
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

SCHEMA_VERSION = 2
LEGACY_SCHEMA_VERSION = 1

# The document is Markdown so a human can read it in the docs worktree, and its
# payload is one fenced JSON object so this module is the only thing that has to
# understand it. The marker is what the parser anchors on: a document without it
# is not this document, whatever else it may contain.
CURSOR_MARKER = "<!-- project-review:cursor:v2 -->"
LEGACY_CURSOR_MARKER = "<!-- project-review:cursor:v1 -->"

PAYLOAD_RE = re.compile(
    re.escape(CURSOR_MARKER) + r"\s*```json\n(?P<payload>.*?)\n```",
    re.DOTALL,
)
LEGACY_PAYLOAD_RE = re.compile(
    re.escape(LEGACY_CURSOR_MARKER) + r"\s*```json\n(?P<payload>.*?)\n```",
    re.DOTALL,
)

MODES = ("pr", "direct")

DOCUMENT_HEADER = """# Project review sweep cursor

Machine-owned state for the `project-review` workflow: each repository's
exclusive older PR boundary, the units completed batches reviewed, the direct
history endpoint, and the units a user explicitly excluded. PR selection always
starts at the latest merge and stops before its boundary; a clean batch records
reviewed coverage exactly as a finding-bearing batch does.

Written by `project_review_cursor.py`. Edit it through that helper rather than
by hand: the payload below is parsed strictly, and an edit it cannot read stops
the next sweep instead of being ignored.
"""

# A short SHA is still a SHA, and how short is git's question rather than this
# module's: `core.abbrev` will not go below four characters, so four is the
# floor here too. Seven is merely the length `git log --abbrev` happens to emit
# and the direct-mode report filenames happen to carry, and a floor set there
# refuses a five-character abbreviation git itself resolves — before
# `resolve_key` can say whether it names one commit or several, which is the
# question that actually decides it. Anything above the floor is a candidate
# spelling, and resolution, not this pattern, accepts or refuses it.
SHA_RE = re.compile(r"\A[0-9a-f]{4,40}\Z")

REPO_RE = re.compile(r"\A[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\Z")

LEGACY_BOUNDARY_RE = re.compile(
    r"^- `(?P<repo>[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)`\s+—\s+"
    r"stop before PR #(?P<boundary>\d+)(?P<tail>[^\n]*(?:\n  [^\n]*)*)",
    re.MULTILINE,
)


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
    legacy_machine_state = False
    if match is None:
        match = LEGACY_PAYLOAD_RE.search(text)
        legacy_machine_state = match is not None
    if match is None:
        legacy = parse_legacy_document(text)
        if legacy is not None:
            return legacy
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
    expected_version = LEGACY_SCHEMA_VERSION if legacy_machine_state else SCHEMA_VERSION
    if version != expected_version:
        raise CursorError(
            f"{source} declares cursor schema version {version!r}; this helper "
            f"expected version {expected_version} for its marker."
        )
    repositories = document.get("repositories")
    if not isinstance(repositories, dict):
        raise CursorError(f"{source} declares no `repositories` object.")
    migrated = empty_document()
    for name, state in repositories.items():
        if not REPO_RE.match(str(name)):
            raise CursorError(f"{source} names {name!r}, which is not an owner/name.")
        validated = _validated_state(state, f"{source}: {name}")
        if legacy_machine_state:
            validated = migrate_v1_state(validated)
        migrated["repositories"][name] = validated
    return migrated


def migrate_v1_state(state: dict) -> dict:
    """Turn the released resume-below PR frontier into exact coverage.

    Version 1 advanced `pr.endpoint` to the oldest reviewed PR in every batch.
    Treating that value as version 2's fixed stop would silently erase all
    older history. Retain it as reviewed coverage and remove it as a boundary;
    direct mode's endpoint already had the intended moving-frontier meaning.
    """
    migrated = json.loads(json.dumps(state))
    endpoint = migrated["pr"]["endpoint"]
    if endpoint is not None:
        migrated["pr"]["reviewed"] = sorted(
            set(migrated["pr"]["reviewed"]) | {endpoint["number"]}
        )
        migrated["pr"]["endpoint"] = None
    return migrated


def parse_legacy_document(text: str):
    """Migrate the original human-authored exclusive-boundary document.

    The old document's continuation lines may name exceptional reviewed PRs
    above the boundary (Synarchy's #1411 is the observed case), so every PR
    number in that repository's bullet is retained as reviewed coverage. The
    next successful `record` writes the canonical machine-owned form.
    """
    matches = list(LEGACY_BOUNDARY_RE.finditer(text))
    if not matches:
        return None
    document = empty_document()
    repositories = document["repositories"]
    for match in matches:
        repo = match.group("repo")
        if repo in repositories:
            raise CursorError(f"legacy cursor names {repo!r} more than once.")
        state = empty_state()
        boundary = int(match.group("boundary"))
        state["pr"]["endpoint"] = {
            "number": boundary,
            "merged_at": "legacy-exclusive-boundary",
        }
        state["pr"]["reviewed"] = sorted(
            {int(number) for number in re.findall(r"#(\d+)", match.group(0))}
        )
        repositories[repo] = state
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


def resolve_key(mode: str, key, keys: list):
    """The candidate `key` names, or `None` when it names none of them.

    A commit has as many spellings as it has abbreviations, and the two ends of
    this module meet in different ones: `git log --format=%H` prints forty
    characters, while a user naming a commit reads the seven a direct-mode
    report filename carries, and an endpoint recorded by an earlier run may be
    either. Exact equality would reject `ed90877` against `ed90877ac1…` — a
    real commit, correctly spelled, refused as absent — so a SHA matches a
    candidate when one is a prefix of the other, in whichever direction.

    Ambiguity is a refusal rather than a choice: a prefix that names two
    commits names neither, and picking one would sweep a range nobody asked
    for. Pull-request numbers have one spelling and take the exact path.
    """
    if key in keys:
        return key
    if mode == "pr":
        return None
    matches = [
        candidate
        for candidate in keys
        if candidate.startswith(key) or key.startswith(candidate)
    ]
    if len(matches) > 1:
        raise CursorError(
            f"{key} names {len(matches)} commits in this history "
            f"({', '.join(sorted(matches))}), so it identifies none of them. "
            "Name more characters."
        )
    return matches[0] if matches else None


def resolve_all(mode: str, values, keys: list, keep_unmatched: bool = False) -> list:
    """`values` in the spelling this history uses.

    A value this history does not hold is dropped by default, which is the safe
    direction for the coverage and exclusion sets `select` builds: a unit the
    history does not contain cannot be selected from it either, so leaving it
    out changes nothing, while keeping a stale spelling would silently stop a
    recorded unit from matching the candidate it names.

    `keep_unmatched` is what `record` writes back with. There the value is state
    rather than a filter, and a unit outside the listing this batch happened to
    take is not a unit that stopped existing.
    """
    resolved = []
    for value in values:
        found = resolve_key(mode, value, keys)
        if found is not None:
            resolved.append(found)
        elif keep_unmatched:
            resolved.append(value)
    return resolved


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
    listing_limit=None,
    end=None,
) -> dict:
    """The next batch, and everything the workflow has to announce about it.

    PR mode always starts at merged HEAD unless the user supplies a start. Its
    recorded endpoint is an exclusive older stop boundary; durable reviewed,
    report, and exclusion coverage is skipped while walking towards it. Direct
    mode keeps the older-history resume frontier because its batches really do
    continue beneath the previous one.

    A range has two endpoints and `start` is only one of them. Without `end`,
    the count keeps filling past the older endpoint whenever coverage or an
    exclusion thins the middle of the request — so a user who asked for
    #466–#461 and had three of those already reviewed would be handed three
    units from below #461 to make the number up. `end` is that older bound, and
    it is a bound rather than a target: the batch stops there whatever the
    count still had left.
    """
    if mode not in MODES:
        raise CursorError(f"unknown mode {mode!r}")
    if count <= 0:
        raise CursorError(f"a batch of {count} units is not a batch.")
    partial = listing_is_partial(candidates, listing_limit)
    coverage = report_coverage_from(reports)
    covered = set(state[mode]["reviewed"])
    if mode == "pr":
        covered |= set(coverage["prs"])
    excluded = set(state["excluded"]["prs" if mode == "pr" else "commits"])
    keys = [key_of(mode, candidate) for candidate in candidates]
    position = {key: index for index, key in enumerate(keys)}
    covered = set(resolve_all(mode, covered, keys))
    excluded = set(resolve_all(mode, excluded, keys))

    endpoint = state[mode]["endpoint"]
    frontier = endpoint if mode == "direct" else None
    boundary = endpoint if mode == "pr" else None
    boundary_key = None
    stop = len(candidates)
    if boundary is not None and not override_boundary:
        recorded_key = boundary["number"]
        boundary_key = resolve_key(mode, recorded_key, keys)
        if boundary_key is None:
            raise CursorError(_absent_endpoint_message(mode, recorded_key, partial))
        stop = position[boundary_key]

    if start is not None:
        supplied_start, start = start, resolve_key(mode, start, keys)
        if start is None:
            raise CursorError(_absent_start_message(mode, supplied_start, partial))
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
    elif mode == "direct" and endpoint is not None:
        recorded_key = endpoint["number"] if mode == "pr" else endpoint["sha"]
        endpoint_key = resolve_key(mode, recorded_key, keys)
        if endpoint_key is None:
            raise CursorError(_absent_endpoint_message(mode, recorded_key, partial))
        begin = position[endpoint_key] + 1
        origin = "recorded-endpoint"
    else:
        # Reports and recorded PRs say what to skip, never where to begin.
        # Starting at merged HEAD is what catches work that landed after the
        # prior review and fills every uncovered gap before the fixed boundary.
        begin = 0
        origin = "recorded-boundary" if boundary_key is not None else "history-head"

    if end is not None:
        supplied_end, end = end, resolve_key(mode, end, keys)
        if end is None:
            raise CursorError(_absent_end_message(mode, supplied_end, partial))
        requested_stop = position[end] + 1
        if boundary_key is not None and requested_stop > stop:
            raise CursorError(
                f"the range ends at {supplied_end}, beyond recorded boundary "
                f"#{boundary_key}. Override the boundary explicitly to cross it."
            )
        stop = requested_stop
        if stop <= begin:
            raise CursorError(
                f"the range ends at {supplied_end}, which is newer than its "
                "starting point, so the range holds nothing to review."
            )
    elif boundary_key is not None and stop <= begin:
        raise CursorError(
            "the requested start is at or beyond the recorded PR boundary. "
            "Override the boundary explicitly to cross it."
        )

    selected = []
    skipped = []
    for index in range(begin, stop):
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

    short = len(selected) < count
    # A batch the requested range ended is short by request. Reporting it as
    # truncated would send the workflow raising a limit that cannot help, and
    # reporting it as exhausted would tell the sweep that PR history had run
    # out when only the user's range had.
    boundary_reached = (
        mode == "pr" and boundary_key is not None and end is None and short
    )
    bounded = short and (end is not None or boundary_key is not None)
    return {
        "mode": mode,
        "count": count,
        "origin": origin,
        "begin_index": begin,
        "frontier": frontier,
        "boundary": boundary,
        "selected": selected,
        "skipped": skipped,
        "gaps": [],
        "covered": sorted(covered & set(keys), key=lambda key: position[key]),
        "excluded": sorted(excluded),
        "reports": coverage["reports"],
        "short": short,
        "bounded": bounded,
        "boundary_reached": boundary_reached,
        "range_end": end,
        # Two different answers to one short batch, and collapsing them is the
        # defect: `truncated` means the page ran out and the missing units may
        # be on the next one, while `exhausted` means the history ran out. A
        # sweep that reads the first as the second enters direct mode with
        # merged pull requests still unreviewed behind it.
        "truncated": short and partial and not bounded,
        "exhausted": short and not partial and not bounded,
    }


def report_coverage_from(reports) -> dict:
    if reports is None:
        return {"reports": [], "prs": []}
    return reports


# The repair a partial listing asks for, kept as one constant so the two
# refusals and the tests all name the same words.
RAISE_LIMIT_INSTRUCTION = "raise the listing limit and list again"


def listing_is_partial(candidates: list, listing_limit) -> bool:
    """Whether the listing may have stopped short of the history it indexes.

    A page that came back with fewer rows than it asked for is the whole of
    what remains; one that came back at its own limit may be a page of a longer
    history, and nothing in the page itself can tell the two apart.

    A caller that declares no limit is taken at its word that the listing is
    complete, because the unbounded caller is the real one: direct mode hands
    over a whole `git log --first-parent` walk, and reporting that as possibly
    truncated would send the workflow raising a limit it never set. PR mode
    always declares one, and a test pins that it does.
    """
    if listing_limit is None:
        return False
    return len(candidates) >= int(listing_limit)


def _absent_start_message(mode: str, start, partial: bool = False) -> str:
    if partial:
        unit = f"pull request #{start}" if mode == "pr" else f"commit {start}"
        return (
            f"{unit} is absent from a listing that came back at its own limit, "
            f"so it may be on the next page rather than missing: "
            f"{RAISE_LIMIT_INSTRUCTION}."
        )
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


def _absent_end_message(mode: str, end, partial: bool = False) -> str:
    unit = f"pull request #{end}" if mode == "pr" else f"commit {end}"
    if partial:
        return (
            f"the range ends at {unit}, which is absent from a listing that "
            f"came back at its own limit, so it may be on the next page: "
            f"{RAISE_LIMIT_INSTRUCTION}."
        )
    return (
        f"the range ends at {unit}, which is not in this history. Say so and "
        "stop; do not review the nearest unit that exists."
    )


def _absent_endpoint_message(mode: str, key, partial: bool = False) -> str:
    if partial:
        unit = f"#{key}" if mode == "pr" else str(key)
        return (
            f"the recorded endpoint {unit} is absent from a listing that came "
            f"back at its own limit, so it may be on the next page rather than "
            f"foreign: {RAISE_LIMIT_INSTRUCTION}."
        )
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
    listing_limit=None,
    boundary=None,
) -> dict:
    """Fold a completed batch into durable coverage.

    PR batches add reviewed coverage while preserving their exclusive older
    boundary. That boundary changes only through the explicit `boundary`
    argument. Direct batches keep their older-history frontier and advance it
    to the oldest commit the completed batch reviewed.
    """
    if mode not in MODES:
        raise CursorError(f"unknown mode {mode!r}")
    partial = listing_is_partial(candidates, listing_limit)
    keys = [key_of(mode, candidate) for candidate in candidates]
    position = {key: index for index, key in enumerate(keys)}
    updated = json.loads(json.dumps(state))
    reviewed = [_resolved_or_raise(mode, unit, keys, "reviewed", partial) for unit in reviewed]
    excluded = [
        _resolved_or_raise(mode, unit, keys, "excluded", partial)
        for unit in (excluded or [])
    ]
    if boundary is not None:
        if mode != "pr":
            raise CursorError("only PR mode has an exclusive older boundary.")
        boundary = _resolved_or_raise(mode, boundary, keys, "boundary", partial)
    # Everything already recorded is re-spelled the way this history spells it,
    # so a state written from a `--format=%h` walk and one written from a
    # `%H` walk converge rather than accumulating two names for one commit.
    excluded_field = "prs" if mode == "pr" else "commits"
    updated[mode]["reviewed"] = resolve_all(
        mode, updated[mode]["reviewed"], keys, keep_unmatched=True
    )
    updated["excluded"][excluded_field] = resolve_all(
        mode, updated["excluded"][excluded_field], keys, keep_unmatched=True
    )
    # A recording listing is taken after the batch was reviewed, which can be a
    # long way after it was selected. Merges landing in between push older rows
    # off a bounded page, so a reviewed unit missing from one is far more often
    # a short page than a wrong claim -- and refusing it as a wrong claim would
    # leave a completed batch with no durable endpoint at all, which is the
    # defect this module exists to close.
    if not reviewed and not excluded and boundary is None:
        raise CursorError(
            "a completed batch records at least one reviewed or excluded unit, "
            "or an explicitly requested PR boundary."
        )

    updated[mode]["reviewed"] = sorted(set(updated[mode]["reviewed"]) | set(reviewed))
    updated["excluded"][excluded_field] = sorted(
        set(updated["excluded"][excluded_field]) | set(excluded)
    )

    if mode == "pr":
        recorded = updated["pr"]["endpoint"]
        if boundary is not None:
            candidate = candidates[position[boundary]]
            updated["pr"]["endpoint"] = {
                "number": candidate["number"],
                "merged_at": candidate["merged_at"],
            }
        elif recorded is not None:
            recorded_key = resolve_key(mode, recorded["number"], keys)
            if recorded_key is None:
                raise CursorError(
                    _absent_endpoint_message(mode, recorded["number"], partial)
                )
            candidate = candidates[position[recorded_key]]
            updated["pr"]["endpoint"] = {
                "number": candidate["number"],
                "merged_at": candidate["merged_at"],
            }
    elif reviewed:
        oldest = max(reviewed, key=lambda unit: position[unit])
        updated[mode]["endpoint"] = _advanced_endpoint(
            mode,
            updated[mode]["endpoint"],
            candidates[position[oldest]],
            position,
            partial,
        )
    return updated


def _resolved_or_raise(mode: str, unit, keys: list, role: str, partial: bool):
    found = resolve_key(mode, unit, keys)
    if found is None:
        raise CursorError(_absent_recorded_message(unit, role, partial))
    return found


def _absent_recorded_message(unit, role: str, partial: bool) -> str:
    if partial:
        return (
            f"{unit} was reported as {role} but is absent from a listing that "
            f"came back at its own limit, so it may have been pushed off the "
            f"page by a later merge: {RAISE_LIMIT_INSTRUCTION}."
        )
    return (
        f"{unit} was reported as {role} but is absent from the candidate "
        "history, so the endpoint it would set cannot be ordered."
    )


def _advanced_endpoint(mode: str, current, candidate: dict, position: dict, partial: bool = False):
    proposed = (
        {"number": candidate["number"], "merged_at": candidate["merged_at"]}
        if mode == "pr"
        else {"sha": candidate["sha"]}
    )
    if current is None:
        return proposed
    recorded_key = current["number"] if mode == "pr" else current["sha"]
    current_key = resolve_key(mode, recorded_key, list(position))
    if current_key is None:
        raise CursorError(_absent_endpoint_message(mode, recorded_key, partial))
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
        "--end",
        help=(
            "the older endpoint of an explicit range; the batch stops there "
            "whatever the count still had left"
        ),
    )
    selector.add_argument(
        "--override-boundary",
        action="store_true",
        help="ignore the recorded endpoint and start at the head of the history",
    )
    selector.add_argument("--candidates", default="-", help="a JSON or SHA listing, or - for stdin")
    selector.add_argument(
        "--listing-limit",
        type=int,
        help=(
            "the --limit the candidate listing was taken with, so a short "
            "batch can be reported as truncated rather than as exhausted"
        ),
    )

    recorder = subparsers.add_parser("record", help="fold a completed batch into the state")
    recorder.add_argument("--root", required=True)
    recorder.add_argument("--repo", required=True)
    recorder.add_argument("--mode", required=True, choices=MODES)
    recorder.add_argument("--candidates", default="-")
    recorder.add_argument("--listing-limit", type=int)
    recorder.add_argument("--reviewed", default="", help="the units this batch reviewed")
    recorder.add_argument("--exclude", default="", help="units the user excluded from every later batch")
    recorder.add_argument(
        "--boundary",
        help="an explicitly requested exclusive older PR boundary",
    )
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
        end = _unit_list(args.mode, args.end)
        if len(end) > 1:
            raise CursorError("a range ends at one unit, not several.")
        return _emit(
            select(
                state,
                args.mode,
                candidates,
                args.count,
                start=start[0] if start else None,
                reports=report_coverage(args.root),
                override_boundary=args.override_boundary,
                listing_limit=args.listing_limit,
                end=end[0] if end else None,
            )
        )

    boundary = _unit_list(args.mode, args.boundary)
    if len(boundary) > 1:
        raise CursorError("a PR sweep has one exclusive older boundary.")
    updated = record(
        state,
        args.mode,
        candidates,
        _unit_list(args.mode, args.reviewed),
        _unit_list(args.mode, args.exclude),
        listing_limit=args.listing_limit,
        boundary=boundary[0] if boundary else None,
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
