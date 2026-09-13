#!/usr/bin/env python3
"""The project-review ledger: per-PR review state, and the migration into it.

Run with: python3 project_review_ledger.py {read,migrate} --help

Issue #680, slice LEDGER-2 of `docs/project_review_ledger_design.md`. The
sweep cursor this module supersedes records which pull requests a batch
covered and nothing else: not whether the batch found anything, not the commit
it was verified against, not when. `project_review_cursor.py` is deliberately
frugal that way, because its one job is to stop the next sweep from re-reading
completed history. A ledger has to answer a different question — "what is this
pull request's review state, and on what evidence?" — and that question needs
a row per pull request rather than a set of numbers.

So this module owns `docs/project_review/ledger.md`: a readable per-repository
table, a marker of its own, and one strictly parsed fenced JSON payload. It
ships beside the cursor in both bundles and is exercised only by
`tools/test_project_review_ledger.py` until LEDGER-6 switches the installed
workflow over (design D-19). Nothing here reads or writes the cursor document:
the cursor is the live consumer record until then, and this module only ever
reads it.

Four rules shape the migration, and each is a way the obvious implementation
would have lied about history:

* **Coverage is imported, never inferred.** The cursor's recorded set and a
  report's own scope enumeration are evidence. A filename interval is not: the
  report named `463-455` reviewed #463, #456 and #455 and nothing between them,
  so reading its interval as nine reviewed pull requests would erase six
  unreviewed ones. Every imported row names the document it came from, so the
  migration's output is checkable against the prose it was read from.
* **The enumeration is not bounded by the filename.** Synarchy's
  `project_review_432-412.md` opens by naming #442 and #444, which are above
  its own interval, because number order and merge order differ. A parser that
  refused them would drop real coverage (design D-9).
* **A boundary is not coverage.** The hand-authored cursor document spells its
  exclusive stop as `stop before PR #533`, and `parse_legacy_document` — quite
  correctly for its own purpose, which is to keep exceptional reviewed PRs
  named in the same bullet — returns every `PR #N` in that bullet as reviewed,
  the stop included. A stop is the one PR the batch deliberately did *not*
  enter, so it is withheld here unless some other source establishes it, and
  the withholding is recorded in the document rather than left implicit.
* **Ambiguity is flagged, never guessed, and the default is to flag.** A
  report whose opening paragraph does not read as exactly one reviewed-PR
  enumeration produces no row at all. The reading runs in both directions: one
  pass finds the enumeration it can be sure of, and a second demands an
  explanation for every pull request the first did not take. A number the
  paragraph does not explain — as a cursor, a boundary, an interval endpoint,
  a later landing, or work a clause says was *not* reviewed — flags the
  report by name rather than being passed over. That direction is the whole
  point: a wording nobody anticipated costs one confirmation, where the
  opposite default costs a pull request that no one finds out was dropped.
  The migration inspects every report, returns every flag, and writes nothing
  while one remains; a caller that knows what a paragraph meant supplies the
  enumeration through `--confirm` and the same migration then completes. The
  two failure modes a silent parser would pick between — inventing coverage
  and discarding it — are both unrecoverable, and neither is worth a guess.

Its reach is as narrow as the cursor's, and pinned as such in
`tools/test_agent_workflow_contract.py`: it spawns no external command, and
every repository file it opens is under the `--root` it was given. The one
file it reads from anywhere else is `project_review_cursor.py` beside itself,
which is the parser this migration is required to read the existing record
through rather than a second implementation of.

Everything the document itself cannot prove, it refuses. A ledger with no
marker, unreadable JSON, an unexpected version, a status outside the four, an
abbreviated verification SHA, a non-UTC timestamp, a dated legacy row, or a
completed review missing its commit raises `LedgerError` naming what stopped
it. A missing document is the one absence that is not an error, because that
is exactly what a repository that has never been migrated looks like. A
migration over a ledger that already exists refuses too: the first one is the
one that read the evidence, and a second would overwrite completed reviews
with legacy rows.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import posixpath
import re
import sys
import tempfile
from datetime import datetime
from pathlib import Path

# Where the ledger lives inside the reviewed repository's docs worktree. One
# directory for every ledger-era document (design D-18), so a consumer enrolls
# it once rather than once per report.
LEDGER_RELATIVE_PATH = "docs/project_review/ledger.md"
LEDGER_DIRECTORY = posixpath.dirname(LEDGER_RELATIVE_PATH)

SCHEMA_VERSION = 1

# Distinct from `<!-- project-review:cursor:v2 -->` on purpose: the two
# documents coexist until LEDGER-6, and a parser that anchored on the other
# one's marker would read whichever document it was handed as its own.
LEDGER_MARKER = "<!-- project-review:ledger:v1 -->"

PAYLOAD_RE = re.compile(
    re.escape(LEDGER_MARKER) + r"\s*```json\n(?P<payload>.*?)\n```",
    re.DOTALL,
)

# Exactly four, and the closed set is the point: `clean` and `findings` are
# completed reviews with evidence, `legacy` is coverage established by a
# document rather than by a review this mechanism ran, and `never-reviewed` is
# the absence of both. A fifth spelling would be a status no scheduler knows
# how to order.
ROW_STATUSES = ("clean", "findings", "legacy", "never-reviewed")

# A completed review carries both its commit and its time, and no other status
# carries either. That pairing is what D-5's checkmark means, and splitting it
# is how a row comes to claim a verification it cannot name.
COMPLETED_STATUSES = ("clean", "findings")

# The full hash, not the cursor's 4-to-40 abbreviation window. The cursor
# resolves its abbreviations against a `git log` listing it was handed; nothing
# here is handed one, so an abbreviation it could not expand would be a
# verification commit that names several.
FULL_SHA_RE = re.compile(r"\A[0-9a-f]{40}\Z")

TIMESTAMP_RE = re.compile(r"\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\Z")

REPO_RE = re.compile(r"\A[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\Z")

# A repository-relative POSIX path. Absolute paths and `..` segments are
# refused because a rendered link resolves them against the reader's browser,
# not against this module.
PATH_RE = re.compile(r"\A[A-Za-z0-9._/-]+\Z")

ROW_KEYS = ("status", "commit", "completed_at", "report", "evidence", "history")
HISTORY_KEYS = ("kind", "outcome", "commit", "completed_at", "report")

# What `migrate` read the cursor's half of the evidence from, in the order
# `project_review_cursor.parse_document` itself prefers them.
MIGRATION_SOURCES = ("cursor-v2", "cursor-v1", "boundary-document", "absent")

DOCUMENT_HEADER = """# Project review ledger

Machine-owned state for the `project-review` workflow: one row per merged pull
request, per repository, with its status, the commit a completed review
verified it against, when that review completed, the report it produced, and
the evidence the row rests on. A checkmark means a clean review against the
commit beside it; `[legacy]` means coverage established by a document that
predates this ledger, with no date and no commit invented for it.

Written by `project_review_ledger.py`. Edit it through that helper rather than
by hand: the payload below is parsed strictly, and an edit it cannot read stops
the next invocation instead of being ignored.
"""

TABLE_HEADER = (
    "| PR | Status | Verified at | Completed (UTC) | Report | Evidence |\n"
    "| ---: | --- | --- | --- | --- | --- |"
)

STATUS_LABELS = {
    "clean": "✓ clean",
    "findings": "findings",
    "legacy": "[legacy]",
    "never-reviewed": "never reviewed",
}


class _DuplicateKey(ValueError):
    """A JSON object repeated a key, which the decoder would resolve silently."""

    def __init__(self, key):
        super().__init__(key)
        self.key = key


def _no_duplicate_keys(pairs):
    seen = {}
    for key, value in pairs:
        if key in seen:
            raise _DuplicateKey(key)
        seen[key] = value
    return seen


class LedgerError(RuntimeError):
    """The ledger, the evidence, or the request could not be trusted.

    Always fatal. A caller that treated one of these as "no ledger yet" would
    overwrite completed reviews with legacy rows, which is the one outcome
    this document exists to make impossible.
    """


# --------------------------------------------------------------------------
# The cursor module beside this one

_CURSOR_MODULE = None


def cursor_module():
    """`project_review_cursor.py`, loaded from beside this file.

    Loaded by path rather than imported for the reason `census.py`'s own
    loader is: the directory holding this module is on `sys.path` when it runs
    as a script and is not when something imports it by path, and the
    migration has to resolve the same cursor either way. Memoized so a single
    run reads one module rather than executing it once per document.

    Reusing that parser is deliberate. It already migrates the v1 payload and
    the hand-authored document on read, and a second implementation of those
    rules here would be a second answer to "what did the cursor say".
    """
    global _CURSOR_MODULE
    if _CURSOR_MODULE is not None:
        return _CURSOR_MODULE
    source = Path(__file__).resolve().parent / "project_review_cursor.py"
    name = "_project_review_cursor_for_ledger"
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
        raise LedgerError(
            f"the cursor module at {source} could not be loaded ({error}); "
            "the ledger migration reads the cursor through its own parser, so "
            "it cannot proceed without it."
        ) from error
    _CURSOR_MODULE = module
    return module


# --------------------------------------------------------------------------
# The ledger document


def empty_document() -> dict:
    return {"version": SCHEMA_VERSION, "repositories": {}}


def empty_repository() -> dict:
    return {
        "rows": {},
        "direct": {"endpoint": None, "reviewed": []},
        "excluded": {"prs": [], "commits": []},
        "migration": {"source": None, "boundary": None, "withheld_boundary": None},
    }


def empty_row(status: str = "never-reviewed") -> dict:
    return {
        "status": status,
        "commit": None,
        "completed_at": None,
        "report": None,
        "evidence": [],
        "history": [],
    }


def document_path(root) -> Path:
    return Path(root) / LEDGER_RELATIVE_PATH


def parse_document(text: str, source: str) -> dict:
    """The state a ledger document holds, or a refusal naming what stopped it."""
    # The marker is counted, not just the complete blocks behind it. A bad
    # merge leaves a second marker whose fence may be dangling, and a reader
    # that only counted well-formed payloads would call that document fine
    # while ignoring whichever state the broken half held.
    markers = text.count(LEDGER_MARKER)
    if markers == 0:
        raise LedgerError(
            f"{source} carries no {LEDGER_MARKER} block, so it is not a "
            "project-review ledger. Move it aside or repair it; an invocation "
            "will not treat an unreadable ledger as an absent one."
        )
    if markers > 1:
        raise LedgerError(
            f"{source} carries {markers} {LEDGER_MARKER} markers; exactly one "
            "is expected, and a reader that took one of them would be choosing "
            "between two ledgers without saying so."
        )
    matches = list(PAYLOAD_RE.finditer(text))
    if len(matches) != 1:
        raise LedgerError(
            f"{source} carries a {LEDGER_MARKER} marker that no complete "
            "fenced JSON payload follows; the payload is the ledger, and a "
            "marker without one is a truncated document rather than an empty "
            "repository."
        )
    match = matches[0]
    try:
        document = json.loads(match.group("payload"), object_pairs_hook=_no_duplicate_keys)
    except json.JSONDecodeError as error:
        raise LedgerError(f"{source} holds unreadable ledger JSON ({error}).") from error
    except _DuplicateKey as error:
        # `json.loads` keeps the last of a repeated key and says nothing, so a
        # payload naming one repository, row, or field twice would be read as
        # whichever copy happened to come last. That is the duplicate-block
        # refusal above, one level further in.
        raise LedgerError(
            f"{source} names {error.key!r} more than once in one object; a "
            "ledger that repeats a key states two values for it and a reader "
            "that took one would be choosing without saying so."
        ) from error
    if not isinstance(document, dict):
        raise LedgerError(f"{source} holds a ledger payload that is not an object.")
    version = document.get("version")
    # `True == 1` and `1.0 == 1` in Python, so an equality test alone would
    # read a boolean or a float as schema version 1 and normalize a malformed
    # document into an accepted one.
    if not isinstance(version, int) or isinstance(version, bool) or version != SCHEMA_VERSION:
        raise LedgerError(
            f"{source} declares ledger schema version {version!r}; this helper "
            f"expected the integer {SCHEMA_VERSION}."
        )
    repositories = document.get("repositories")
    if not isinstance(repositories, dict):
        raise LedgerError(f"{source} declares no `repositories` object.")
    _require_keys(document, DOCUMENT_KEYS, source)
    parsed = empty_document()
    for name, state in repositories.items():
        if not REPO_RE.match(str(name)):
            raise LedgerError(f"{source} names {name!r}, which is not an owner/name.")
        parsed["repositories"][name] = _validated_repository(state, f"{source}: {name}")
    return parsed


def load_document(root) -> dict:
    """The document under `root`, or an empty one when it does not exist.

    The only absence that is not a refusal: a repository that has never been
    migrated has no ledger, and that is the state every first read starts in.
    """
    path = document_path(root)
    if not path.exists():
        return empty_document()
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise LedgerError(f"{path} could not be read ({error}).") from error
    return parse_document(text, str(path))


def state_for(document: dict, repo: str) -> dict:
    """This repository's entry, defaulted rather than created.

    Reading never writes: a read against a repository the document does not
    mention behaves exactly like a read against no document at all.
    """
    state = document.get("repositories", {}).get(repo)
    return json.loads(json.dumps(state)) if state else empty_repository()


# --------------------------------------------------------------------------
# Validation


REPOSITORY_KEYS = ("rows", "direct", "excluded", "migration")
DIRECT_KEYS = ("endpoint", "reviewed")
EXCLUDED_KEYS = ("prs", "commits")
MIGRATION_KEYS = ("source", "boundary", "withheld_boundary")


DOCUMENT_KEYS = ("version", "repositories")
ENDPOINT_KEYS = ("sha",)
BOUNDARY_KEYS = ("number", "merged_at")


def _require_keys(mapping, keys, source: str) -> None:
    """Every declared field present and nothing else, at every level.

    Two silences, closed together because they are one decision. Defaulting a
    missing field is how a truncated but still-parseable edit erases rows,
    direct progress, exclusions, or a row's previous attempts; dropping an
    unrecognized one is how a field written by a newer helper, or misspelled
    by a hand-edit, disappears through a read-and-rewrite. A strictly parsed
    document refuses both rather than normalizing either away.
    """
    missing = [key for key in keys if key not in mapping]
    if missing:
        raise LedgerError(
            f"{source} declares no {', '.join(missing)}; a ledger states every "
            f"one of {', '.join(keys)} rather than leaving any to a default."
        )
    unknown = sorted(set(mapping) - set(keys))
    if unknown:
        raise LedgerError(
            f"{source} carries unrecognized field(s) {', '.join(unknown)}; it "
            f"holds exactly {', '.join(keys)}, and a field this helper cannot "
            "read is one it would drop on the next write."
        )


def _validated_repository(state, source: str) -> dict:
    if not isinstance(state, dict):
        raise LedgerError(f"{source} is not an object.")
    _require_keys(state, REPOSITORY_KEYS, source)
    validated = empty_repository()
    rows = state["rows"]
    if not isinstance(rows, dict):
        raise LedgerError(f"{source}: rows is not an object.")
    for key, row in rows.items():
        number = _validated_row_key(key, source)
        validated["rows"][str(number)] = _validated_row(row, f"{source}: #{number}")
    for key, expected in (("direct", DIRECT_KEYS), ("excluded", EXCLUDED_KEYS)):
        if not isinstance(state[key], dict):
            raise LedgerError(f"{source}: {key} is not an object.")
        _require_keys(state[key], expected, f"{source}: {key}")
    endpoint = state["direct"]["endpoint"]
    if endpoint is not None:
        if not isinstance(endpoint, dict):
            raise LedgerError(f"{source}: direct.endpoint is not an object.")
        _require_keys(endpoint, ENDPOINT_KEYS, f"{source}: direct.endpoint")
    carried = _validated_carryover(state, source)
    validated["direct"] = carried["direct"]
    validated["excluded"] = carried["excluded"]
    validated["migration"] = _validated_migration(state["migration"], source)
    return validated


def _validated_carryover(state, source: str) -> dict:
    """`direct` and `excluded`, validated by the cursor module rather than again here.

    Design D-16 keeps direct-commit progress exactly as the cursor held it, so
    the rules it is held to are the cursor's own: the same endpoint shape, the
    same SHA spelling, the same exclusion lists. A second implementation of
    those rules in this file would be a second answer to the same question,
    and the migration copies these two structures across untouched precisely
    so there is only one. The refusal is re-raised as a `LedgerError` because
    the document that failed is this one.
    """
    cursor = cursor_module()
    try:
        return cursor._validated_state(
            {
                "pr": {"endpoint": None, "reviewed": []},
                "direct": state.get("direct", {}),
                "excluded": state.get("excluded", {}),
            },
            source,
        )
    except cursor.CursorError as error:
        raise LedgerError(str(error)) from error


def _validated_row_key(key, source: str) -> int:
    text = str(key)
    if not text.isdigit() or text != str(int(text)) or int(text) <= 0:
        raise LedgerError(
            f"{source} keys a row by {key!r}, which is not a pull-request number."
        )
    return int(text)


def _validated_row(row, source: str) -> dict:
    if not isinstance(row, dict):
        raise LedgerError(f"{source} is not an object.")
    _require_keys(row, ROW_KEYS, source)
    status = row["status"]
    if status not in ROW_STATUSES:
        raise LedgerError(
            f"{source} declares status {status!r}, which is not one of "
            f"{', '.join(ROW_STATUSES)}."
        )
    validated = empty_row(status)
    validated["commit"] = _validated_optional_sha(row["commit"], f"{source}: commit")
    validated["completed_at"] = _validated_optional_timestamp(
        row["completed_at"], f"{source}: completed_at"
    )
    validated["report"] = _validated_optional_path(row["report"], f"{source}: report")
    validated["evidence"] = _validated_evidence(row["evidence"], f"{source}: evidence")
    validated["history"] = _validated_history(row["history"], f"{source}: history")
    _require_completion_pairing(status, validated, source)
    return validated


def _require_completion_pairing(status: str, row: dict, source: str) -> None:
    """A completed review names both its commit and its time; nothing else names either.

    The two halves are one fact. A row with a commit and no time cannot be
    scheduled and a row with a time and no commit cannot be checked, and a
    legacy row that acquired either would be claiming a verification the
    migration was careful never to invent.
    """
    if status in COMPLETED_STATUSES:
        if row["commit"] is None:
            raise LedgerError(
                f"{source} is {status} but names no verification commit; a "
                "completed review records the commit it was verified against."
            )
        if row["completed_at"] is None:
            raise LedgerError(
                f"{source} is {status} but names no completed-review time; a "
                "completed review records when it completed."
            )
        if status == "findings" and row["report"] is None:
            raise LedgerError(
                f"{source} is findings but links no report; the findings are "
                "the report, so a findings row without one names nothing."
            )
        return
    if row["commit"] is not None:
        raise LedgerError(
            f"{source} is {status} but names a verification commit; only a "
            "completed review has one."
        )
    if row["completed_at"] is not None:
        raise LedgerError(
            f"{source} is {status} but names a completed-review time; only a "
            "completed review has one."
        )
    if status == "legacy" and not row["evidence"]:
        raise LedgerError(
            f"{source} is legacy but names no evidence; legacy coverage is a "
            "claim about a document, and a claim with no document behind it "
            "is indistinguishable from never-reviewed."
        )


def _validated_optional_sha(value, source: str):
    if value is None:
        return None
    if not isinstance(value, str) or not FULL_SHA_RE.match(value):
        raise LedgerError(
            f"{source} holds {value!r}, which is not a full 40-character commit SHA."
        )
    return value


def _validated_optional_timestamp(value, source: str):
    if value is None:
        return None
    if not isinstance(value, str) or not TIMESTAMP_RE.match(value):
        raise LedgerError(
            f"{source} holds {value!r}, which is not a UTC "
            "YYYY-MM-DDTHH:MM:SSZ timestamp."
        )
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as error:
        raise LedgerError(f"{source} holds {value!r}, which is not a real date ({error}).") from error
    return value


def _validated_optional_path(value, source: str):
    if value is None:
        return None
    if not isinstance(value, str) or not value.strip():
        raise LedgerError(f"{source} holds {value!r}, which is not a document path.")
    if not PATH_RE.match(value) or value.startswith("/") or ".." in value.split("/"):
        raise LedgerError(
            f"{source} holds {value!r}, which is not a repository-relative "
            "document path."
        )
    return value


def _validated_evidence(values, source: str) -> list:
    if not isinstance(values, list):
        raise LedgerError(f"{source} is not a list.")
    evidence = []
    for value in values:
        if not isinstance(value, str) or not value.strip():
            raise LedgerError(f"{source} holds {value!r}, which is not an evidence note.")
        # A newline or a control character would split the rendered row it
        # sits in, and the table is what a human reads the ledger through.
        if any(character < " " or character == "\x7f" for character in value):
            raise LedgerError(
                f"{source} holds {value!r}, which carries a control character; "
                "an evidence note is one line of readable text."
            )
        if value in evidence:
            raise LedgerError(f"{source} names {value!r} twice.")
        evidence.append(value)
    return evidence


def _validated_history(values, source: str) -> list:
    if not isinstance(values, list):
        raise LedgerError(f"{source} is not a list.")
    return [
        _validated_history_entry(value, f"{source}[{index}]")
        for index, value in enumerate(values)
    ]


def _validated_history_entry(entry, source: str) -> dict:
    """One completed attempt, readable without any entry beside it.

    Self-contained is the whole contract (design D-17): an entry that recorded
    only what changed since the previous one would become unreadable the
    moment an earlier entry was archived, and archival is exactly what a
    never-truncated history eventually needs.
    """
    if not isinstance(entry, dict):
        raise LedgerError(f"{source} is not an object.")
    _require_keys(entry, HISTORY_KEYS, source)
    kind = entry["kind"]
    if not isinstance(kind, str) or not re.match(r"\A[a-z][a-z0-9-]*\Z", kind):
        raise LedgerError(f"{source} declares kind {kind!r}, which is not an entry kind.")
    outcome = entry["outcome"]
    if outcome is not None and outcome not in COMPLETED_STATUSES:
        raise LedgerError(
            f"{source} declares outcome {outcome!r}, which is not one of "
            f"{', '.join(COMPLETED_STATUSES)} or null."
        )
    validated = {
        "kind": kind,
        "outcome": outcome,
        "commit": _validated_optional_sha(entry["commit"], f"{source}: commit"),
        "completed_at": _validated_optional_timestamp(
            entry["completed_at"], f"{source}: completed_at"
        ),
        "report": _validated_optional_path(entry["report"], f"{source}: report"),
    }
    if outcome is not None and (validated["commit"] is None or validated["completed_at"] is None):
        raise LedgerError(
            f"{source} records a completed {outcome} attempt without both its "
            "verification commit and its completed-review time; an entry that "
            "needs the row beside it to be read is not self-contained."
        )
    if outcome == "findings" and validated["report"] is None:
        raise LedgerError(
            f"{source} records a completed findings attempt that links no "
            "report; the findings are the report, so an entry without one "
            "cannot be read once a later clean review has taken the row."
        )
    if outcome is None and validated["completed_at"] is None:
        raise LedgerError(
            f"{source} records a {kind} entry with no timestamp; an entry that "
            "cannot be placed in time is not self-contained."
        )
    return validated


def _validated_migration(migration, source: str) -> dict:
    if not isinstance(migration, dict):
        raise LedgerError(f"{source}: migration is not an object.")
    _require_keys(migration, MIGRATION_KEYS, f"{source}: migration")
    origin = migration["source"]
    if origin is not None and origin not in MIGRATION_SOURCES:
        raise LedgerError(
            f"{source}: migration.source is {origin!r}, which is not one of "
            f"{', '.join(MIGRATION_SOURCES)}."
        )
    boundary = migration["boundary"]
    if boundary is not None:
        if not isinstance(boundary, dict):
            raise LedgerError(f"{source}: migration.boundary is not an object.")
        _require_keys(boundary, BOUNDARY_KEYS, f"{source}: migration.boundary")
        number = boundary["number"]
        merged_at = boundary["merged_at"]
        if not isinstance(number, int) or isinstance(number, bool) or number <= 0:
            raise LedgerError(
                f"{source}: migration.boundary.number is not a pull-request number."
            )
        if not isinstance(merged_at, str) or not merged_at.strip():
            raise LedgerError(
                f"{source}: migration.boundary.merged_at is not a merge timestamp."
            )
        boundary = {"number": number, "merged_at": merged_at}
    withheld = migration["withheld_boundary"]
    if withheld is not None:
        if not isinstance(withheld, int) or isinstance(withheld, bool) or withheld <= 0:
            raise LedgerError(
                f"{source}: migration.withheld_boundary is not a pull-request number."
            )
    return {"source": origin, "boundary": boundary, "withheld_boundary": withheld}


# --------------------------------------------------------------------------
# Rendering


def render_document(document: dict) -> str:
    repositories = document.get("repositories", {})
    sections = [
        _render_repository(name, repositories[name]) for name in sorted(repositories)
    ]
    body = "\n".join(sections) if sections else "No repository has a ledger entry yet.\n"
    payload = json.dumps(document, indent=2, sort_keys=True)
    return f"{DOCUMENT_HEADER}\n{body}\n{LEDGER_MARKER}\n\n```json\n{payload}\n```\n"


def _render_repository(repo: str, state: dict) -> str:
    lines = [f"## {repo}", ""]
    rows = state.get("rows", {})
    if rows:
        lines.append(TABLE_HEADER)
        for key in sorted(rows, key=int, reverse=True):
            lines.append(_render_row(int(key), rows[key]))
    else:
        lines.append("No merged pull request has a ledger row yet.")
    lines.append("")
    lines.extend(_render_notes(state))
    lines.append("")
    return "\n".join(lines)


def _render_row(number: int, row: dict) -> str:
    return "| " + " | ".join(
        (
            f"#{number}",
            STATUS_LABELS[row["status"]],
            f"`{row['commit']}`" if row["commit"] else "—",
            row["completed_at"] or "—",
            _render_report_link(row["report"]),
            _cell("; ".join(row["evidence"])) if row["evidence"] else "—",
        )
    ) + " |"


def _render_report_link(report) -> str:
    """A link that resolves from the ledger's own directory.

    The payload stores repository-relative paths because that is what every
    other consumer of a report path uses, but the ledger is one directory down
    from `docs/`, so a stored `docs/project_review_602-562.md` has to render as
    `../project_review_602-562.md` or the reader follows it into a file that
    is not there. The pre-ledger reports all live in that parent directory
    (design D-18 leaves them where they are), so this is the common case
    rather than the exotic one.
    """
    if not report:
        return "—"
    target = posixpath.relpath(report, LEDGER_DIRECTORY)
    return f"[{_cell(report)}]({target})"


def _cell(text: str) -> str:
    return text.replace("|", "\\|")


def _render_notes(state: dict) -> list:
    notes = []
    direct = state["direct"]
    if direct["endpoint"] or direct["reviewed"]:
        frontier = f"`{direct['endpoint']['sha']}`" if direct["endpoint"] else "none"
        notes.append(
            f"- Direct first-parent history: frontier {frontier}, "
            f"{len(direct['reviewed'])} reviewed commit(s). Direct commits keep "
            "their own frontier and never take a row here."
        )
    excluded = state["excluded"]
    if excluded["prs"] or excluded["commits"]:
        parts = []
        if excluded["prs"]:
            parts.append(", ".join(f"#{number}" for number in excluded["prs"]))
        if excluded["commits"]:
            parts.append(", ".join(f"`{sha}`" for sha in excluded["commits"]))
        notes.append(f"- Excluded by the user: {'; '.join(parts)}.")
    migration = state["migration"]
    if migration["source"]:
        note = f"- Migrated from the {migration['source']} record."
        if migration["boundary"]:
            note += (
                f" Its exclusive boundary #{migration['boundary']['number']} is "
                "kept as provenance only and schedules nothing."
            )
        if migration["withheld_boundary"]:
            note += (
                f" #{migration['withheld_boundary']} was withheld from coverage: "
                "the record named it only as that stop, and a stop is the one "
                "pull request a batch did not enter."
            )
        notes.append(note)
    if not notes:
        notes.append("- Nothing carried over from a previous record.")
    return notes


def write_document(root, document: dict) -> Path:
    """Replace the document atomically, creating its directory if it is absent.

    Atomic because the alternative to a complete write here is a truncated
    ledger, and a truncated ledger stops every later invocation by design.
    """
    path = document_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=str(path.parent), prefix=".project-review-ledger-")
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
# Reading a report's own scope enumeration

# A backticked span is masked rather than removed so every offset below still
# lines up. It is masked at all because report prose puts paths, SHAs and
# boundaries in code spans, and `docs/project_review_463-455.md` inside one is
# a filename, not two pull requests. A span that spells a pull request the way
# a pull request is spelled is kept, because masking it would hide it from the
# accounting pass rather than from the reading -- no opening paragraph in the
# tracked reports has one, so nothing real is kept by this.
BACKTICK_RE = re.compile(r"`[^`]*`")

# An annotation on an enumerated pull request -- `#463 (per-entry witnesses)`.
# Masked before anything else is read, because the annotation is prose and
# everything below is about the list. A pull request named only inside one is
# deliberately dropped: an annotation says what a reviewed PR was about, so a
# number appearing only there is something that PR referred to.
PAREN_RE = re.compile(r"\([^()]*\)")

# A run of pull-request numbers joined by nothing but list punctuation. One
# number is a run too: the count was never what separated a claim of coverage
# from a mention, and a lone dropped pull request is lost exactly as quietly
# as a list would be.
RUN_RE = re.compile(r"#\d+(?:\s*[,;]?\s*(?:and|&)?\s*#\d+)*")

# The landmark roles a report gives a pull request other than "this batch
# reviewed it": a cursor it resumed below, a stop it did not cross, a boundary
# it froze at, a landing that arrived while it ran, a batch someone else
# reported, a numeric threshold. Every leftover number in the tracked reports
# sits beside one of these words.
#
# Roles, not prepositions. `from`, `through` and `after` were on this list and
# excused "It also reviewed PRs from #601 through #533", because a preposition
# says where a number sits in a phrase and nothing about what the phrase
# claims. A role word names what the number *is*, which is the question, and a
# reviewing verb's plain object has no role word beside it.
MENTION_ROLE_RE = re.compile(
    r"\b(?:cursor|cursors|stop|stops|stopped|boundary|boundaries|frontier|"
    r"landing|landings|landed|batch|batches|completed|reported|advanced|"
    r"numbered)\b",
    re.IGNORECASE,
)

# How far in front of a run a role word counts, in words. In front only, and
# two words only, because that is where every tracked report puts it -- "the
# completed #185 cursor", "exclusive stop at #533", "advanced through #466",
# "previously reported #386", "landed after #456", "request numbered #533" --
# and because a window that also looked behind would excuse "It also reviewed
# the #601 batch", where the role word belongs to the verb's object rather
# than to the number.
ROLE_WINDOW = 2

# `interleaved between #446 and #411` -- an interval's two endpoints. The one
# form with no role word of its own, and structural enough to recognize by
# shape: `between` directly in front, and exactly two numbers joined by `and`.
INTERVAL_LEAD_RE = re.compile(r"\bbetween\s*\Z", re.IGNORECASE)
INTERVAL_RUN_RE = re.compile(r"\A#\d+\s+and\s+#\d+\Z")

# There is deliberately no clause- or sentence-scoped "this was not reviewed"
# excuse here. Three attempts at one each reached a pull request it should not
# have: a sentence-wide negation silenced the positive half of "It did not
# review #8, but it also reviewed these: #10 and #9"; narrowing it to the
# conjunct left "It also reviewed #10 and skipped #9", where `and` joins two
# predicates and cannot be split on because it also joins a batch's items.
# The excuse is now one rule -- the word immediately in front of the run --
# because that is the only relationship a parser can establish without
# understanding the sentence. A pull request a report says it did *not* review
# therefore flags unless that word puts it somewhere else, which costs a
# confirmation and never a dropped pull request.

NUMBER_RE = re.compile(r"#(\d+)")

# Sentence boundaries as report prose actually spells them. A period inside a
# code span is already masked, so this does not split `origin/master@a1b2c3d`
# or a filename.
SENTENCE_SPLIT_RE = re.compile(r"(?<=\.)\s+")

# The verbs an opening paragraph uses to say what the batch actually entered.
SCOPE_TRIGGER_RE = re.compile(
    r"\b(?:covered|covers|covering|reviewed|reviewing|reviews|review of)\b",
    re.IGNORECASE,
)

# ... and the words that turn one of those into its opposite, anywhere before
# the colon. "The previously reported batch was skipped rather than reviewed
# again: #386, ..." carries a reviewing verb and a well-formed enumeration and
# means precisely the opposite of coverage, and the negation that says so sits
# before the verb rather than after it. Refusing the sentence does not import
# the wrong thing and does not silently drop the right one either: a paragraph
# left with no readable enumeration is flagged for confirmation. A cursor, a
# boundary and a stop are not negations and are not listed here -- every real
# report names those before its verb while still enumerating real coverage
# after the colon, and the shape check below is what keeps them out.
SCOPE_NEGATION_RE = re.compile(
    r"\b(?:not|no|none|never|neither|nothing|without|rather than|instead of|"
    r"skipped|skipping|excluded|excluding|omitted|omitting)\b",
    re.IGNORECASE,
)

# A pull-request noun. Where one stands between a landmark role and the
# number, the number is the noun's, not the role's: "the previously reported
# PR #10" is a pull request this batch reviewed, however the role word in
# front of it reads, while "request numbered #533" puts the role last and
# means the threshold.
PR_NOUN_RE = re.compile(r"\b(?:PRs?|pull\s+requests?)\b", re.IGNORECASE)

# What a reviewed-PR enumeration looks like once its annotations are gone:
# pull-request numbers, separators, and nothing else. This is the whole of the
# "exactly one reviewed-PR enumeration" test -- a colon introducing SHAs,
# filenames, or prose is not one, so the sentence that lists a batch's direct
# commits contributes nothing without needing a rule of its own.
ENUMERATION_RE = re.compile(r"\A#\d+(?:\s*[,;]?\s*(?:and|&)?\s*#\d+)*\Z")


def opening_paragraph(text: str):
    """The first paragraph under the report's title, or None.

    Only the opening paragraph is read. Every later section names pull
    requests for other reasons -- a finding's context, a deduplication check,
    a link to where something was fixed -- and importing those would turn a
    mention into coverage.
    """
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if line.startswith("# "):
            start = index + 1
            break
    if start is None:
        return None
    while start < len(lines) and not lines[start].strip():
        start += 1
    end = start
    while end < len(lines) and lines[end].strip():
        end += 1
    if end == start:
        return None
    return "\n".join(lines[start:end])


def _masked(text: str) -> str:
    def blank(match):
        span = match.group(0)
        return span if NUMBER_RE.search(span) else " " * len(span)

    return BACKTICK_RE.sub(blank, text)


def _unannotated(text: str) -> str:
    """The same text with every parenthesised annotation blanked in place.

    Blanked rather than removed so every offset below still lines up with the
    paragraph it came from, which is what lets a run be placed relative to the
    colon that introduced the accepted enumeration.

    A parenthesis holding a pull-request number is left alone, because it is
    not an annotation this helper may throw away: "(It also reviewed #10.)" is
    a whole sentence in brackets, and blanking it would hide the one number
    the accounting pass exists to catch. No annotation in the tracked reports
    carries a number, so nothing real is kept by this and anything new that
    does is accounted for rather than erased.
    """
    def blank(match):
        span = match.group(0)
        return span if NUMBER_RE.search(span) else " " * len(span)

    while True:
        reduced = PAREN_RE.sub(blank, text)
        if reduced == text:
            return text
        text = reduced


def _enumeration_clauses(sentence: str) -> list:
    """Every colon in `sentence` that introduces pull-request numbers.

    A sentence introduces its enumeration with a colon, so the colons are
    where the candidates are. Taking only the last one would read "covered one
    batch: #12 and #11; it also reviewed another: #10 and #9" as coverage of
    #10 and #9 alone and drop the other two silently -- the single outcome
    this parser must never produce. Each colon is judged against the text
    before it, which is what says whether the numbers after it were reviewed,
    and against the segment up to the next colon, which is where they are.
    """
    positions = [index for index, character in enumerate(sentence) if character == ":"]
    clauses = []
    for order, position in enumerate(positions):
        head = sentence[:position]
        end = positions[order + 1] if order + 1 < len(positions) else len(sentence)
        # The reviewing verb has to be in the clause that introduces the
        # colon, not merely somewhere earlier in the sentence. "No pull
        # requests were reviewed; the candidates were: #10 and #9" carries one
        # in its first clause and claims the opposite in its second, and a
        # search over the whole head would have read the candidates as
        # coverage. The negation search stays over the whole head, because
        # widening *that* only refuses more.
        if not SCOPE_TRIGGER_RE.search(head.rsplit(";", 1)[-1]):
            continue
        if SCOPE_NEGATION_RE.search(head):
            continue
        if NUMBER_RE.search(sentence[position + 1:end]):
            clauses.append(position)
    return clauses


def _sentence_enumeration(sentence: str):
    """`(reviewed, ambiguous, accepted_from)` for one sentence.

    `ambiguous` is a sentence carrying more than one reviewed enumeration. It
    is not the same as reading nothing: a sentence this parser cannot resolve
    must flag its whole report even when some other sentence did resolve, or
    the report's coverage would be the part that happened to be readable.
    `accepted_from` is the offset the accepted enumeration starts at, so the
    mention check below can tell the numbers this reading took from the ones
    it left behind.
    """
    clauses = _enumeration_clauses(sentence)
    if not clauses:
        return None, False, None
    if len(clauses) > 1:
        return None, True, None
    start = clauses[0] + 1
    normalized = " ".join(sentence[start:].split()).rstrip(".").strip()
    if not normalized or not ENUMERATION_RE.match(normalized):
        return None, False, None
    return [int(number) for number in NUMBER_RE.findall(normalized)], False, start


def _sentence_spans(text: str) -> list:
    """`(offset, sentence)` for each sentence, offsets into `text`."""
    spans = []
    start = 0
    for match in SENTENCE_SPLIT_RE.finditer(text):
        spans.append((start, text[start:match.start()]))
        start = match.end()
    spans.append((start, text[start:]))
    return spans


def _unaccounted_mentions(sentence: str, accepted_from) -> list:
    """Every pull request the accepted reading neither took nor accounts for.

    This is the parser's whole safety property, and it runs the opposite way
    round from the reading above. The reading looks for the one enumeration it
    can be sure of; this looks at everything it did *not* take and demands an
    explanation for each. A number with none is not quietly ignored -- it
    flags the report, and the flag names it, so the operator decides.

    One thing explains a number: a landmark role in the two words in front of
    it -- "the completed #185 cursor", "the previously reported #386 ...
    batch", "advanced through #466", "landed after #456", "request numbered
    #533" -- or the one structural form, an interval's two endpoints behind
    `between`. A pull-request noun standing between the role and the number
    cancels it: in "the previously reported PR #10" the number belongs to
    `PR`, so the batch reviewed it whatever `reported` says about where it
    came from.

    Everything looser than that has been tried here and has reached a pull
    request it should not have: a negation somewhere in the sentence, then
    somewhere in the conjunct, then a bare preposition in front of the number.
    A preposition says where a number sits in a phrase and nothing about what
    the phrase claims, which is why "It also reviewed PRs from #601 through
    #533" walked past it. "It also reviewed #10", "It also reviewed PR #10",
    "it also reviewed these: #10 and #9", and "It also reviewed #10 and
    skipped #9" fail this too, which is the point.
    """
    unaccounted = []
    for match in RUN_RE.finditer(sentence):
        if accepted_from is not None and match.start() >= accepted_from:
            continue
        run = " ".join(match.group(0).split())
        if INTERVAL_RUN_RE.match(run) and INTERVAL_LEAD_RE.search(sentence[: match.start()]):
            continue
        window = " ".join(sentence[: match.start()].split()[-ROLE_WINDOW:])
        roles = list(MENTION_ROLE_RE.finditer(window))
        # The nearest role word, and nothing between it and the number that
        # would make the number a pull-request noun's rather than the role's.
        if roles and not PR_NOUN_RE.search(window[roles[-1].end():]):
            continue
        unaccounted.append(run)
    return unaccounted


def report_scope(text: str, path: str) -> dict:
    """What one report says it reviewed, or why that could not be read.

    A flag is not a failure of the report: it is this parser declining to
    decide. `reason` and `candidates` are what the operator needs to answer
    the question themselves and hand the answer back through `--confirm`.
    """
    paragraph = opening_paragraph(text)
    if paragraph is None:
        return {
            "path": path,
            "reviewed": [],
            "candidates": [],
            "flag": (
                f"{path} has no paragraph under a `# ` title, so it states no "
                "reviewed scope this migration can read."
            ),
        }
    masked = _masked(paragraph)
    # Candidates keep their annotations, because the operator answering a flag
    # wants every number the paragraph mentions, not the subset this parser
    # would have been willing to read.
    candidates = sorted({int(number) for number in NUMBER_RE.findall(masked)})
    readable = _unannotated(masked)
    enumerations = []
    ambiguous = False
    readings = []
    for _, sentence in _sentence_spans(readable):
        found, unclear, accepted_from = _sentence_enumeration(sentence)
        if unclear:
            ambiguous = True
        elif found:
            enumerations.append(found)
        readings.append((sentence, accepted_from))
    # A paragraph with no single accepted reading has taken nothing, so every
    # number in it is left over and every one of them is reported.
    unaccounted = [
        run
        for sentence, accepted_from in readings
        for run in _unaccounted_mentions(
            sentence, accepted_from if len(enumerations) == 1 else None
        )
    ]
    if len(enumerations) == 1 and not ambiguous and not unaccounted:
        return {"path": path, "reviewed": enumerations[0], "candidates": candidates, "flag": None}
    if ambiguous:
        reason = "carries more than one reviewed-pull-request enumeration in a single sentence"
    elif len(enumerations) > 1:
        reason = f"names {len(enumerations)} reviewed-pull-request enumerations"
    elif unaccounted:
        reason = (
            f"names {'; '.join(unaccounted)} outside any enumeration this "
            "helper can read as its scope, and outside any wording that would "
            "explain them as something other than reviewed work"
        )
    else:
        reason = "names no reviewed-pull-request enumeration"
    return {
        "path": path,
        "reviewed": [],
        "candidates": candidates,
        "flag": (
            f"{path}: its opening paragraph {reason}, so no row was written "
            f"from it. Its candidate pull requests are "
            f"{', '.join(f'#{number}' for number in candidates) or 'none'}; "
            f"confirm the reviewed ones with --confirm '{path}=<list>'."
        ),
    }


# --------------------------------------------------------------------------
# Migration


def migrate(root, repo: str, confirmations=None) -> dict:
    """Build one repository's ledger from the cursor and the sibling reports.

    Reads, in this order of authority, whatever `docs/project_review_boundaries.md`
    holds -- the v2 cursor, the v1 cursor, or the hand-authored boundary
    document -- through the cursor module's own parser, then every sibling
    report that module classifies as a PR report. Writes nothing while any
    report is flagged, and writes nothing at all over an existing ledger. The
    cursor document is neither deleted nor rewritten: it remains the live
    consumer record until LEDGER-6 switches the workflow over.
    """
    if not REPO_RE.match(str(repo)):
        raise LedgerError(f"{repo!r} is not an owner/name repository identity.")
    confirmations = dict(confirmations or {})
    cursor = cursor_module()
    path = document_path(root)
    if path.exists():
        raise LedgerError(
            f"{path} already exists, so a ledger is already established under "
            "this root. A second migration would replace completed reviews "
            "with legacy rows; edit the ledger through this helper instead."
        )
    cursor_relative = cursor.DOCUMENT_RELATIVE_PATH
    cursor_path = Path(root) / cursor_relative
    source = _cursor_source(cursor, cursor_path)
    try:
        state = cursor.state_for(cursor.load_document(root), repo)
    except cursor.CursorError as error:
        raise LedgerError(
            f"the existing record at {cursor_path} could not be read ({error}); "
            "the migration reads it through the cursor's own parser and will "
            "not guess at a record it cannot parse."
        ) from error

    boundary = state["pr"]["endpoint"]
    reviewed = set(state["pr"]["reviewed"])
    withheld = None
    # A hand-authored record spells its exclusive stop as `stop before PR #N`
    # and `parse_legacy_document` returns every `PR #N` in that bullet as
    # reviewed, the stop included -- correctly for its own purpose, which is to
    # keep an exceptional reviewed PR named in the same bullet. Here the stop
    # is the one pull request the batch deliberately did not enter, so it is
    # withheld unless a report independently names it below.
    if source == "boundary-document" and boundary and boundary["number"] in reviewed:
        withheld = boundary["number"]
        reviewed.discard(withheld)

    reports, flags = _report_scopes(cursor, root, confirmations)
    unknown = sorted(confirmations)
    if unknown:
        raise LedgerError(
            "confirmed enumerations name "
            f"{', '.join(unknown)}, which the reports under "
            f"{Path(root) / 'docs'} do not include as pull-request reports."
        )
    result = {
        "status": "flagged" if flags else "migrated",
        "repo": repo,
        "document": None,
        "state": None,
        "flags": flags,
        "reports": reports,
        "cursor": {
            "document": cursor_relative if source != "absent" else None,
            "source": source,
            "boundary": boundary,
            "reviewed": sorted(reviewed),
            "withheld_boundary": withheld,
        },
    }
    if flags:
        return result

    rows = {}
    for number in sorted(reviewed):
        _record_legacy(rows, number, f"cursor:{cursor_relative}", None)
    for report in reports:
        note = f"report:{report['path']}"
        if report["confirmed"]:
            note += " (operator-confirmed)"
        for number in report["reviewed"]:
            _record_legacy(rows, number, note, report["path"])

    migrated = empty_repository()
    migrated["rows"] = rows
    migrated["direct"] = state["direct"]
    migrated["excluded"] = state["excluded"]
    migrated["migration"] = {
        "source": source,
        "boundary": boundary,
        "withheld_boundary": withheld,
    }
    document = empty_document()
    document["repositories"][repo] = _validated_repository(
        migrated, f"the ledger migrated for {repo}"
    )
    written = write_document(root, document)
    result["document"] = str(written)
    result["state"] = document["repositories"][repo]
    return result


def _cursor_source(cursor, cursor_path: Path) -> str:
    """Which of the three record shapes `cursor_path` holds.

    Classified with the cursor module's own markers so this never disagrees
    with the parser that reads the file a moment later. Only the hand-authored
    shape needs distinguishing on its own account -- its exclusive stop is not
    coverage -- but naming all three makes the migration's provenance say what
    it actually read.
    """
    if not cursor_path.exists():
        return "absent"
    try:
        text = cursor_path.read_text(encoding="utf-8")
    except OSError as error:
        raise LedgerError(f"{cursor_path} could not be read ({error}).") from error
    if cursor.PAYLOAD_RE.search(text):
        return "cursor-v2"
    if cursor.LEGACY_PAYLOAD_RE.search(text):
        return "cursor-v1"
    return "boundary-document"


def _report_scopes(cursor, root, confirmations: dict):
    """Every sibling report, with what it contributes and what it flagged.

    Classification is the cursor module's, not a fresh glob: it already
    separates the cursor document, a PR report, a direct-mode report, and a
    filename it does not recognize, and the same glob that finds the reports
    also finds `project_review_boundaries.md` and
    `project_review_ledger_design.md`. Only a PR report's prose is read, so
    neither of those -- nor a direct-mode report, whose interval says nothing
    about pull requests -- can produce a row or a flag.
    """
    reports = []
    flags = []
    for entry in cursor.report_coverage(root)["reports"]:
        record = {
            "path": entry["path"],
            "kind": entry["kind"],
            "reviewed": [],
            "confirmed": False,
        }
        if entry["kind"] != "pr":
            reports.append(record)
            continue
        if entry["path"] in confirmations:
            record["reviewed"] = sorted(set(confirmations.pop(entry["path"])), reverse=True)
            record["confirmed"] = True
            reports.append(record)
            continue
        report_path = Path(root) / entry["path"]
        try:
            text = report_path.read_text(encoding="utf-8")
        except OSError as error:
            raise LedgerError(f"{report_path} could not be read ({error}).") from error
        scope = report_scope(text, entry["path"])
        if scope["flag"]:
            flags.append(
                {
                    "report": entry["path"],
                    "candidates": scope["candidates"],
                    "reason": scope["flag"],
                }
            )
        else:
            record["reviewed"] = scope["reviewed"]
        reports.append(record)
    return reports, flags


def _record_legacy(rows: dict, number: int, evidence: str, report) -> None:
    if number <= 0:
        raise LedgerError(f"#{number} is not a pull-request number.")
    key = str(number)
    row = rows.setdefault(key, empty_row("legacy"))
    if evidence not in row["evidence"]:
        row["evidence"].append(evidence)
    # The row keeps every contributing source in `evidence`; `report` is the
    # first one that is an actual report, so a row imported from the cursor
    # alone links nothing rather than linking the cursor.
    if report and row["report"] is None:
        row["report"] = report


# --------------------------------------------------------------------------
# Command line


def _confirmation(raw: str) -> tuple:
    if "=" not in raw:
        raise LedgerError(
            f"{raw!r} is not a confirmed enumeration; spell it "
            "'<report path>=#1,#2' (an empty list confirms that the report "
            "contributes no coverage)."
        )
    path, _, listed = raw.partition("=")
    path = path.strip()
    if not path:
        raise LedgerError(f"{raw!r} names no report.")
    numbers = []
    for token in (item for item in re.split(r"[,\s]+", listed.strip()) if item):
        stripped = token.lstrip("#")
        if not stripped.isdigit() or int(stripped) <= 0:
            raise LedgerError(f"{token!r} is not a pull-request number.")
        numbers.append(int(stripped))
    return path, numbers


def _emit(payload) -> int:
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    subparsers = parser.add_subparsers(dest="command", required=True)

    reader = subparsers.add_parser("read", help="print the recorded ledger")
    reader.add_argument("--root", required=True, help="the docs worktree holding the ledger")
    reader.add_argument("--repo", help="restrict the output to one owner/name")

    migrator = subparsers.add_parser(
        "migrate", help="build the ledger from the cursor and the sibling reports"
    )
    migrator.add_argument("--root", required=True)
    migrator.add_argument("--repo", required=True)
    migrator.add_argument(
        "--confirm",
        action="append",
        default=[],
        metavar="REPORT=LIST",
        help=(
            "the reviewed pull requests one report enumerates, taken in place "
            "of this helper's own reading of it; repeatable"
        ),
    )
    return parser


def main(argv=None) -> int:
    """0 migrated or read, 3 flagged with nothing written, 2 refused.

    Three outcomes rather than two because a flagged migration is neither: it
    read every report successfully and is waiting for a decision only the
    operator can make, and a caller that saw it as a refusal would retry it
    unchanged forever.
    """
    args = build_parser().parse_args(argv)
    if args.command == "read":
        document = load_document(args.root)
        if args.repo:
            return _emit(
                {"status": "read", "repo": args.repo, "state": state_for(document, args.repo)}
            )
        return _emit({"status": "read", "document": document})

    confirmations = {}
    for raw in args.confirm:
        path, numbers = _confirmation(raw)
        if path in confirmations:
            raise LedgerError(f"{path} is confirmed more than once.")
        confirmations[path] = numbers
    result = migrate(args.root, args.repo, confirmations)
    _emit(result)
    return 3 if result["status"] == "flagged" else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except LedgerError as error:
        print(f"project-review ledger: {error}", file=sys.stderr)
        raise SystemExit(2)
