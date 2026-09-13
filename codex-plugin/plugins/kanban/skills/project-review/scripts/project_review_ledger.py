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
* **Ambiguity is flagged, never guessed.** A report whose opening paragraph
  does not read as exactly one reviewed-PR enumeration produces no row at all.
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
    match = PAYLOAD_RE.search(text)
    if match is None:
        raise LedgerError(
            f"{source} carries no {LEDGER_MARKER} block, so it is not a "
            "project-review ledger. Move it aside or repair it; an invocation "
            "will not treat an unreadable ledger as an absent one."
        )
    try:
        document = json.loads(match.group("payload"))
    except json.JSONDecodeError as error:
        raise LedgerError(f"{source} holds unreadable ledger JSON ({error}).") from error
    if not isinstance(document, dict):
        raise LedgerError(f"{source} holds a ledger payload that is not an object.")
    version = document.get("version")
    if version != SCHEMA_VERSION:
        raise LedgerError(
            f"{source} declares ledger schema version {version!r}; this helper "
            f"expected version {SCHEMA_VERSION}."
        )
    repositories = document.get("repositories")
    if not isinstance(repositories, dict):
        raise LedgerError(f"{source} declares no `repositories` object.")
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


def _validated_repository(state, source: str) -> dict:
    if not isinstance(state, dict):
        raise LedgerError(f"{source} is not an object.")
    validated = empty_repository()
    rows = state.get("rows", {})
    if not isinstance(rows, dict):
        raise LedgerError(f"{source}: rows is not an object.")
    for key, row in rows.items():
        number = _validated_row_key(key, source)
        validated["rows"][str(number)] = _validated_row(row, f"{source}: #{number}")
    carried = _validated_carryover(state, source)
    validated["direct"] = carried["direct"]
    validated["excluded"] = carried["excluded"]
    validated["migration"] = _validated_migration(state.get("migration"), source)
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
    unknown = sorted(set(row) - set(ROW_KEYS))
    if unknown:
        raise LedgerError(
            f"{source} carries unrecognized row field(s) {', '.join(unknown)}; "
            f"a ledger row holds exactly {', '.join(ROW_KEYS)}."
        )
    status = row.get("status")
    if status not in ROW_STATUSES:
        raise LedgerError(
            f"{source} declares status {status!r}, which is not one of "
            f"{', '.join(ROW_STATUSES)}."
        )
    validated = empty_row(status)
    validated["commit"] = _validated_optional_sha(row.get("commit"), f"{source}: commit")
    validated["completed_at"] = _validated_optional_timestamp(
        row.get("completed_at"), f"{source}: completed_at"
    )
    validated["report"] = _validated_optional_path(row.get("report"), f"{source}: report")
    validated["evidence"] = _validated_evidence(row.get("evidence", []), f"{source}: evidence")
    validated["history"] = _validated_history(row.get("history", []), f"{source}: history")
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
    unknown = sorted(set(entry) - set(HISTORY_KEYS))
    if unknown:
        raise LedgerError(
            f"{source} carries unrecognized history field(s) {', '.join(unknown)}; "
            f"an entry holds exactly {', '.join(HISTORY_KEYS)}."
        )
    kind = entry.get("kind")
    if not isinstance(kind, str) or not re.match(r"\A[a-z][a-z0-9-]*\Z", kind):
        raise LedgerError(f"{source} declares kind {kind!r}, which is not an entry kind.")
    outcome = entry.get("outcome")
    if outcome is not None and outcome not in COMPLETED_STATUSES:
        raise LedgerError(
            f"{source} declares outcome {outcome!r}, which is not one of "
            f"{', '.join(COMPLETED_STATUSES)} or null."
        )
    validated = {
        "kind": kind,
        "outcome": outcome,
        "commit": _validated_optional_sha(entry.get("commit"), f"{source}: commit"),
        "completed_at": _validated_optional_timestamp(
            entry.get("completed_at"), f"{source}: completed_at"
        ),
        "report": _validated_optional_path(entry.get("report"), f"{source}: report"),
    }
    if outcome is not None and (validated["commit"] is None or validated["completed_at"] is None):
        raise LedgerError(
            f"{source} records a completed {outcome} attempt without both its "
            "verification commit and its completed-review time; an entry that "
            "needs the row beside it to be read is not self-contained."
        )
    if outcome is None and validated["completed_at"] is None:
        raise LedgerError(
            f"{source} records a {kind} entry with no timestamp; an entry that "
            "cannot be placed in time is not self-contained."
        )
    return validated


def _validated_migration(migration, source: str) -> dict:
    if migration is None:
        return empty_repository()["migration"]
    if not isinstance(migration, dict):
        raise LedgerError(f"{source}: migration is not an object.")
    unknown = sorted(set(migration) - {"source", "boundary", "withheld_boundary"})
    if unknown:
        raise LedgerError(
            f"{source}: migration carries unrecognized field(s) {', '.join(unknown)}."
        )
    origin = migration.get("source")
    if origin is not None and origin not in MIGRATION_SOURCES:
        raise LedgerError(
            f"{source}: migration.source is {origin!r}, which is not one of "
            f"{', '.join(MIGRATION_SOURCES)}."
        )
    boundary = migration.get("boundary")
    if boundary is not None:
        if not isinstance(boundary, dict):
            raise LedgerError(f"{source}: migration.boundary is not an object.")
        number = boundary.get("number")
        merged_at = boundary.get("merged_at")
        if not isinstance(number, int) or isinstance(number, bool) or number <= 0:
            raise LedgerError(
                f"{source}: migration.boundary.number is not a pull-request number."
            )
        if not isinstance(merged_at, str) or not merged_at.strip():
            raise LedgerError(
                f"{source}: migration.boundary.merged_at is not a merge timestamp."
            )
        boundary = {"number": number, "merged_at": merged_at}
    withheld = migration.get("withheld_boundary")
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
# a filename, not two pull requests.
BACKTICK_RE = re.compile(r"`[^`]*`")

# An annotation on an enumerated pull request -- `#463 (per-entry witnesses)`.
# Removed before the shape check, because the annotation is prose and the
# shape check is about the list. A pull request named only inside one is
# deliberately dropped: an annotation says what a reviewed PR was about, so a
# number appearing only there is something that PR referred to.
PAREN_RE = re.compile(r"\([^()]*\)")

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
    r"\b(?:not|never|rather than|instead of|skipped|skipping|excluded|"
    r"excluding|omitted|omitting)\b",
    re.IGNORECASE,
)

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
    return BACKTICK_RE.sub(lambda match: " " * len(match.group(0)), text)


def _sentence_enumeration(sentence: str):
    """The pull requests this sentence identifies as reviewed, or None."""
    colon = sentence.rfind(":")
    if colon < 0:
        return None
    head, tail = sentence[:colon], sentence[colon + 1:]
    if not SCOPE_TRIGGER_RE.search(head):
        return None
    if SCOPE_NEGATION_RE.search(head):
        return None
    while True:
        reduced = PAREN_RE.sub(" ", tail)
        if reduced == tail:
            break
        tail = reduced
    normalized = " ".join(tail.split()).rstrip(".").strip()
    if not normalized or not ENUMERATION_RE.match(normalized):
        return None
    return [int(number) for number in NUMBER_RE.findall(normalized)]


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
    candidates = sorted({int(number) for number in NUMBER_RE.findall(masked)})
    enumerations = [
        found
        for found in (
            _sentence_enumeration(sentence)
            for sentence in SENTENCE_SPLIT_RE.split(masked)
        )
        if found
    ]
    if len(enumerations) == 1:
        return {"path": path, "reviewed": enumerations[0], "candidates": candidates, "flag": None}
    if not enumerations:
        reason = "names no reviewed-pull-request enumeration"
    else:
        reason = f"names {len(enumerations)} reviewed-pull-request enumerations"
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
