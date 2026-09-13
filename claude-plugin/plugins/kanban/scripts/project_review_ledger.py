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
* **A sentence is read by matching a template whole, or it is not read.** A
  report whose opening paragraph does not read as exactly one reviewed-PR
  enumeration produces no row at all. Every sentence naming a pull request
  must match one of the templates in `SCOPE_TEMPLATES` or
  `MENTION_TEMPLATES` — the nineteen tracked reports' own sentences with
  their numbers, counts, dates and code spans punched out — and a paragraph
  carrying one that matches neither flags by name.

  Templates rather than a grammar, because the grammar was tried. Fifteen
  review rounds each produced a wording it did not cover, in both directions:
  "It also reviewed PR #10" dropped a pull request, "covered direct commits
  and noted pending pull requests: #10 and #9" invented a review of two,
  "If this review had covered the two merged pull requests, they would have
  been: #10 and #9" invented one from a counterfactual. Widening the rules
  moved the boundary and never closed it, because anything that composes —
  a verb here, an object there, free text after — composes into sentences
  nobody enumerated. A template composes with nothing.

  This is affordable only because the language is finite. These reports are
  history: from LEDGER-6 the workflow writes into `docs/project_review/`,
  where this migration never looks, so the set grows only when a consumer
  turns up with a historical report it does not cover — a reviewed edit with
  a fixture beside it.

  Every sentence is read, not only the ones carrying a number: an unnumbered
  sentence reverses a numbered one just as easily — "That batch was
  nevertheless reviewed in this pass" — and a sentence nobody read cannot be
  said to have been accounted for. So the paragraph matches as a sequence,
  against `SCOPE_TEMPLATES`, `MENTION_TEMPLATES` and `PROSE_TEMPLATES`
  together, or it flags.

  Prose in brackets and prose in backticks are read the same way: not at all.
  A parenthesis makes its sentence unreadable, and only a path, a ref or an
  abbreviated commit is masked out of a code span. Eighteen of the nineteen
  tracked reports parse; `docs/project_review_463-455.md` annotates every
  pull request in its enumeration, so it flags and takes one `--confirm`.
  That is the recovery path this migration was built around, and one
  confirmation over nineteen reports is the whole price of never inventing a
  review again.

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


def confined(root, path) -> Path:
    """`path`, proven to resolve inside `root`, or a refusal.

    Joining a relative path to `--root` is a lexical operation and every read
    and write below follows symlinks, so a `docs/project_review_12-11.md`
    pointing outside the worktree was read and imported and a symlinked
    ledger directory would have been written through. The reach this module
    declares is "files under `--root`", and that is a statement about where
    the bytes are rather than about how the path is spelled.
    """
    root_path = Path(root)
    try:
        anchor = root_path.resolve(strict=False)
        resolved = Path(path).resolve(strict=False)
    except OSError as error:
        raise LedgerError(f"{path} could not be resolved ({error}).") from error
    if anchor != resolved and anchor not in resolved.parents:
        raise LedgerError(
            f"{path} resolves to {resolved}, which is outside {anchor}; this "
            "helper reads and writes only inside the root it was given."
        )
    return Path(path)


def parse_document(text: str, source: str) -> dict:
    """The state a ledger document holds, or a refusal naming what stopped it."""
    # The marker is counted, not just the complete blocks behind it. A bad
    # merge leaves a second marker whose fence may be dangling, and a reader
    # that only counted well-formed payloads would call that document fine
    # while ignoring whichever state the broken half held.
    #
    # Counted as whole lines, which is how `render_document` writes it. A
    # count over the raw text also counted the marker where it is data rather
    # than structure -- an evidence note may say anything, including this, and
    # such a note renders into its table cell and its payload string and made
    # the document refuse its own output.
    markers = sum(1 for line in text.splitlines() if line.strip() == LEDGER_MARKER)
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
    An unreadable one is not that state. `Path.exists()` answers false for a
    ledger it merely could not look up -- under a directory with no search
    permission, say -- so absence is taken from `FileNotFoundError` and every
    other lookup failure is reported.
    """
    path = confined(root, document_path(root))
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return empty_document()
    except OSError as error:
        raise LedgerError(
            f"{path} could not be read ({error}); an unreadable ledger is not "
            "an absent one."
        ) from error
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


def _require_one_line(value: str, source: str) -> None:
    """One line by the same definition the document is read back with.

    `render_document` writes the marker on a line of its own and
    `parse_document` counts lines to find it, so a value carrying a line break
    would split its rendered row and could put a second marker line into a
    document this helper wrote itself. An explicit list of break characters
    missed U+2028; `str.splitlines` is what the reader uses, so it is what
    decides here.
    """
    if value.splitlines() != [value]:
        raise LedgerError(
            f"{source} holds {value!r}, which carries a line break; the "
            "document is read back a line at a time, so a value spanning two "
            "of them is not one this helper can write."
        )
    if any(character < " " or character == "\x7f" for character in value):
        raise LedgerError(
            f"{source} holds {value!r}, which carries a control character; "
            "an evidence note is one line of readable text."
        )


def _validated_evidence(values, source: str) -> list:
    if not isinstance(values, list):
        raise LedgerError(f"{source} is not a list.")
    evidence = []
    for value in values:
        if not isinstance(value, str) or not value.strip():
            raise LedgerError(f"{source} holds {value!r}, which is not an evidence note.")
        _require_one_line(value, source)
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
        _require_one_line(merged_at, f"{source}: migration.boundary.merged_at")
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


def create_document(root, document: dict) -> Path:
    """Create the document, or refuse because something already holds its name.

    Written whole into a temporary file and then linked into place. `os.link`
    fails when the name is taken, and it fails as one operation, so two
    migrations racing each other cannot both believe they created the ledger
    -- which a look-then-write could, and did: both passed `exists()`, both
    reached the write, and the second replaced the first.

    Whole-file-then-link for the reason the write was atomic before: the
    alternative to a complete ledger is a truncated one, and a truncated
    ledger stops every later invocation by design.
    """
    path = confined(root, document_path(root))
    parent = confined(root, path.parent)
    parent.mkdir(parents=True, exist_ok=True)
    confined(root, parent)
    handle, temporary = tempfile.mkstemp(dir=str(parent), prefix=".project-review-ledger-")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(render_document(document))
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            raise LedgerError(
                f"{path} already exists, so a ledger is already established "
                "under this root. A second migration would replace completed "
                "reviews with legacy rows; edit the ledger through this helper "
                "instead."
            ) from error
    finally:
        try:
            os.unlink(temporary)
        except OSError:
            pass
    return path


# --------------------------------------------------------------------------
# Reading a report's own scope enumeration
#
# A whole sentence is matched against a literal template, or it is not read at
# all. Nothing composes: there is no "verb somewhere, object somewhere, free
# text after", because fifteen review rounds established that every free
# relationship is one an English sentence walks through. Rounds 1 through 10
# widened exclusions; rounds 11 through 15 replaced them with allowlists of
# *parts* and the parts still composed into sentences nobody enumerated -- a
# counterfactual "If this review had covered ...", a suffix withdrawing its
# own clause, a reversal one sentence later.
#
# The templates below are the nineteen tracked reports' own sentences with
# their numbers, counts, dates and blanked code spans punched out. That is the
# whole accepted language. A sentence naming a pull request in any other
# wording matches nothing and flags its report for one `--confirm`, which is
# what requirement 5 asks for and what no amount of widening produced.
#
# This is affordable because the language is finite and closed. These reports
# are history: `project-review` has written its last one in this shape, and
# from LEDGER-6 on it writes into `docs/project_review/` where this migration
# never looks. A template is added only when a consumer turns up with a
# historical report this set does not cover, and that is a reviewed edit with
# a fixture beside it.

# A backticked span is masked because report prose puts paths, SHAs and
# boundaries in code spans, and `docs/project_review_463-455.md` inside one is
# a filename rather than two pull requests.
#
# Only the four things those spans actually hold are masked, spelled out
# rather than approximated by "one token": an abbreviated commit, a ref at a
# commit, a tracked document, an owner/name repository. A token-shaped rule
# also masked `never` and `unreviewed`, and blanking a word leaves a gap a
# template spans happily -- "This review `never` covered the two newest merged
# pull requests ...: #601 and #533" read as the template it interrupts.
BACKTICK_RE = re.compile(r"`[^`]*`")
CODE_SPAN_RE = re.compile(
    r"\A`(?:"
    r"[0-9a-f]{7,40}"                          # an abbreviated commit
    r"|[\w.-]+(?:/[\w.-]+)*@[0-9a-f]{7,40}"    # a ref at a commit
    r"|[\w.-]+(?:/[\w.-]+)*\.md"              # a tracked document
    r"|[A-Za-z0-9._-]+/[A-Za-z0-9._-]+"        # an owner/name repository
    r")`\Z"
)

PAREN_RE = re.compile(r"\([^()]*\)")

NUMBER_RE = re.compile(r"#(\d+)")

# Sentence boundaries as report prose actually spells them. A period inside a
# code span is already masked, so this does not split `origin/master@a1b2c3d`
# or a filename.
SENTENCE_SPLIT_RE = re.compile(r"(?<=\.)\s+")

# A parenthesis is replaced by a character no template contains, and there is
# no exception. Two rounds were spent deciding which annotations were safe to
# drop -- "(not reviewed)" then "(unreviewed)" then "(out of scope)" -- and
# each answer was a list of the spellings someone had thought of. An
# annotation is prose, and prose is what this parser has stopped reading.
#
# `docs/project_review_463-455.md` pays for it: every pull request in its
# enumeration carries one, so it flags and takes one `--confirm`. That is the
# recovery path the migration was built around rather than a gap in it, and
# one confirmation over nineteen reports is the whole cost of never inventing
# a review again.
UNREADABLE_MARK = "\x00"

HOLE_RE = re.compile(r"\{([A-Z]+)\}")

# A scope sentence says how many pull requests it covered as well as which,
# and the two have to agree. "covered the two newest merged pull requests ...:
# #612, #610, and #602" contradicts itself, and prose that contradicts itself
# is prose this helper cannot read -- a stale count is exactly as likely to
# mean a stale list as a stale number, and choosing between them is the
# operator's.
COUNT_WORDS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
    "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
    "thirty": 30,
}


def count_value(text: str):
    """`"twelve"` as 12, or None when the word is not one this helper knows."""
    text = text.strip().lower()
    if text.isdigit():
        return int(text)
    if "-" in text:
        tens, _, unit = text.partition("-")
        if tens in COUNT_WORDS and unit in COUNT_WORDS:
            return COUNT_WORDS[tens] + COUNT_WORDS[unit]
        return None
    return COUNT_WORDS.get(text)

# What separates two pull requests in a list. Required, not optional: with
# both the punctuation and the conjunction optional, "#612#610" and "#612
# #610" read as two-item enumerations, and malformed prose then established
# coverage instead of asking for confirmation.
LIST_SEPARATOR = r"(?:\s*[,;]\s*(?:and\s+|&\s*)?|\s+and\s+|\s*&\s*)"

HOLE_PATTERNS = {
    # The reviewed enumeration a scope template introduces.
    "ENUM": rf"(?P<enum>#\d+(?:{LIST_SEPARATOR}#\d+)*)",
    # A pull request the sentence puts *outside* the batch: the cursor it
    # resumed below, the stop it did not cross, a landing it excluded, a batch
    # someone else reported, the bound it stayed above. Captured, because a
    # paragraph that both excludes a pull request and enumerates it
    # contradicts itself and is not one this helper can read.
    "EXCLUDED": rf"(?P<excluded>#\d+(?:{LIST_SEPARATOR}#\d+)*)",
    # A pull request named for context rather than exclusion -- an interval's
    # endpoints, the landing a commit came after. These legitimately overlap
    # the batch: nine tracked reports name their oldest reviewed pull request
    # as one end of the span their direct commits sit in.
    "NUM": r"#\d+",
    "NUMS": rf"#\d+(?:{LIST_SEPARATOR}#\d+)*",
    "COUNT": r"(?:(?:twenty|thirty)-(?:one|two|three|four|five|six|seven|"
             r"eight|nine)|one|two|three|four|five|six|seven|eight|nine|ten|"
             r"eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|"
             r"eighteen|nineteen|twenty|thirty|\d+)",
    "DATE": r"\d{4}-\d{2}-\d{2}",
    # What a run of blanked code spans leaves behind: their separators.
    "LIST": r"(?:[,\s]|\band\b)+",
}

# What a hole looks like at its edges, for deciding whether the gap beside it
# needs whitespace. A template's tokens were joined by `\s*`, so "This
# reviewcovered the two newest merged pull requests ...: #612 and #610" read
# as the template it runs two words of together.
HOLE_EDGES = {
    "ENUM": ("#", "9"),
    "EXCLUDED": ("#", "9"),
    "NUM": ("#", "9"),
    "NUMS": ("#", "9"),
    "COUNT": ("a", "a"),
    "DATE": ("9", "9"),
    "LIST": (",", ","),
}

# `#` counts as a word character here: "completed#533" is no more a sentence
# than "reviewcovered" is.
WORD_EDGE_RE = re.compile(r"[A-Za-z0-9#]")


def _edge(token: str, last: bool) -> str:
    """The character a token presents to the gap beside it."""
    match = HOLE_RE.search(token)
    if last:
        if match and match.end() == len(token):
            return HOLE_EDGES[match.group(1)][1]
        return token[-1]
    if match and match.start() == 0:
        return HOLE_EDGES[match.group(1)][0]
    return token[0]

# The sentences that introduce a batch. Exactly one of these must match a
# paragraph, and its `{ENUM}` is the batch. Nine shapes over eighteen tracked
# reports; the nineteenth annotates every pull request in its enumeration, so
# it flags and takes one `--confirm`.
SCOPE_TEMPLATES = (
    "This bounded review covered every eligible merged pull request remaining above the user's exclusive stop at {EXCLUDED}, in merge-time order: {ENUM}.",
    'This review continued below the completed {EXCLUDED} cursor and covered the next {COUNT} genuinely unreviewed merged pull requests in merge-time order: {ENUM}.',
    'This review continued below the completed {EXCLUDED} cursor and covered the next {COUNT} merged pull requests by merge time: {ENUM}.',
    'This review continued below the completed {EXCLUDED} cursor and covered the next {COUNT} merged pull requests in merge-time order: {ENUM}.',
    'This review continued below the completed {EXCLUDED} cursor and covered {COUNT} previously unreviewed merged pull requests at the frozen selection boundary, newest-first by merge time: {ENUM}.',
    'This review covered the {COUNT} newest merged pull requests as of {DATE}, ordered by merge time: {ENUM}.',
    'This review covered the {COUNT} newest merged pull requests at the frozen review boundary on {DATE}, ordered by merge time: {ENUM}.',
    'This review covered the {COUNT} newest merged pull requests at the frozen selection boundary, in merge-time order: {ENUM}.',
    'This review covered the {COUNT} newest uncovered merged pull requests at the frozen selection boundary, in merge-time order: {ENUM}.',
)

# The sentences that name a pull request for some other reason: a cursor, an
# interval's endpoints, a landing that arrived mid-review, a batch someone
# else reported, a numeric bound. Matching one contributes nothing, which is
# the point -- it says the numbers were accounted for rather than overlooked.
MENTION_TEMPLATES = (
    'It also reviewed all {COUNT} direct first-parent documentation commits interleaved between {NUMS}, from through: {LIST}.',
    'It also reviewed all {COUNT} direct first-parent documentation commits interleaved between {NUMS}: {LIST}.',
    'It also reviewed the direct first-parent commits {LIST}, and interleaved between {NUMS}.',
    'It also reviewed the direct first-parent documentation commit interleaved between {NUMS}.',
    'It also reviewed the direct first-parent documentation commits and that landed after {NUMS} inside that boundary.',
    'It also reviewed the direct first-parent documentation commits {LIST}, and interleaved between {NUMS}.',
    'Master advanced through {EXCLUDED} while the review was running; those newer landings were excluded rather than moving the boundary, and both findings below were rechecked at current.',
    'Master advanced through {EXCLUDED} while verification was running; that newer landing was excluded rather than moving the boundary, and both findings below were rechecked at current.',
    'Master advanced through {EXCLUDED} while verification was running; that newer landing was excluded rather than moving the boundary, and the finding below was rechecked at current.',
    'The bound therefore produced {COUNT} pull requests rather than the requested {COUNT}; no pull request numbered {EXCLUDED} or lower was entered.',
    'The previously reported {EXCLUDED} batch was explicitly skipped rather than reviewed again.',
    'There were no direct first-parent commits interleaved between {NUMS}.',
)

# The sentences that name no pull request at all. They are here because
# skipping them let one reverse a sentence that did: "The previously reported
# #601 and #533 batch was explicitly skipped rather than reviewed again. That
# batch was nevertheless reviewed in this pass." A paragraph is read as a
# whole sequence or not at all, so a sentence outside these shapes flags its
# report however few numbers it carries.
PROSE_TEMPLATES = (
    'Broader roadmap and repository-health observations belong to the accompanying project audit; this report preserves only confirmed current mistakes that still need {COUNT}-at-a-time disposition.',
    'Direct first-parent landings newer than the frozen boundary were excluded rather than moving the batch while it was in progress.',
    'Each pull request was checked against its linked issue, landed diff, commits, current implementation, callers, and current tests; each direct commit was checked individually against its patch and current document state.',
    'For every pull request, the review read the linked issue contract, pull-request description, commits and landed diff, then traced affected behavior through the current descendants.',
    'It also covered the {COUNT} direct first-parent documentation commits interleaved through that range: {LIST}.',
    'It also reviewed the direct first-parent documentation commits {LIST}, and in that landing interval.',
    'It also reviewed the {COUNT} direct first-parent commits interleaved through that span: {LIST}.',
    'It also reviewed the {COUNT} direct first-parent documentation commits interleaved through that landing interval: {LIST}.',
    'It also reviewed the {COUNT} direct first-parent documentation commits interleaved through that range: {LIST}.',
    "Its implementation is; the intervening commits edit only, so they do not alter this batch's code or the finding below.",
    "Its implementation is; the {COUNT} intervening commits edit only, so they do not alter this batch's code or the finding below.",
    'Later descendants were read only to establish whether a mistake still exists.',
    'Master advanced to the documentation landing while validation was running; that newer commit was excluded rather than moving the boundary, and the finding below was rechecked there unchanged.',
    'Origin advanced by {COUNT} documentation-only landings to while validation was running; those newer commits were excluded rather than moving the boundary, and they do not touch the finding below.',
    'Origin advanced once more to while validation was running, through another edit to that same report; the frozen boundary did not move.',
    'The batch was frozen and verified at on {DATE}.',
    'The batch was frozen at on {DATE}.',
    'The batch was frozen at the repository history head on {DATE}; no unit or concern was excluded.',
    'The discontinuities are deliberate: {LIST}, and already record the intervening pull requests as reviewed, so their coverage was not duplicated.',
    "The first {COUNT} were rechecked because they also lay in the preceding PR batch's first-parent span; the last {COUNT} were reviewed individually for this batch.",
    'The later direct documentation landing was excluded rather than moving the boundary; every finding below was rechecked against the current descendant at.',
    'The later direct documentation landing was excluded rather than moving the boundary; the finding below was rechecked against the current descendant at.',
    'The review also covered the {COUNT} direct first-parent documentation commits interleaved through the selected landing interval: {LIST}.',
    'The review checked the linked issue contracts, landed changes, current descendants, local quality gates, and current tracker state.',
    'This report preserves only confirmed current mistakes that still need {COUNT}-at-a-time disposition.',
    'This report preserves the {COUNT} confirmed current mistakes that still need {COUNT}-at-a-time disposition.',
)

def compile_template(template: str):
    """One template as a whole-sentence pattern.

    Tokens are joined by `\\s*` so a report's line wrapping and its spacing
    around punctuation do not matter, and nothing else is permitted between
    them: a template matches the sentence entire or not at all.
    """
    parts = []
    captured = False
    for token in template.split():
        pieces = []
        index = 0
        for hole in HOLE_RE.finditer(token):
            pieces.append(re.escape(token[index:hole.start()]))
            pattern = HOLE_PATTERNS[hole.group(1)]
            # The first `{COUNT}` is captured, so a scope sentence's claim
            # about how many pull requests it covered can be checked against
            # the list it then gives. Later ones are not: no scope template
            # has a second, and a mention template's counts are about commits.
            if hole.group(1) == "COUNT" and not captured:
                pattern = f"(?P<count>{pattern})"
                captured = True
            pieces.append(pattern)
            index = hole.end()
        pieces.append(re.escape(token[index:]))
        parts.append("".join(pieces))
    tokens = template.split()
    joined = [parts[0]]
    for index, part in enumerate(parts[1:], start=1):
        # Whitespace between two word-ish edges, optional elsewhere: a report
        # may wrap a line or space its punctuation differently, but it may not
        # run two words together.
        separator = (
            r"\s+"
            if WORD_EDGE_RE.match(_edge(tokens[index - 1], last=True))
            and WORD_EDGE_RE.match(_edge(tokens[index], last=False))
            else r"\s*"
        )
        joined.append(separator)
        joined.append(part)
    return re.compile(r"\A" + "".join(joined) + r"\Z", re.IGNORECASE)


SCOPE_PATTERNS = tuple(compile_template(template) for template in SCOPE_TEMPLATES)
MENTION_PATTERNS = tuple(compile_template(template) for template in MENTION_TEMPLATES)
PROSE_PATTERNS = tuple(compile_template(template) for template in PROSE_TEMPLATES)


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
        if NUMBER_RE.search(span) or not CODE_SPAN_RE.match(span):
            return span
        return " " * len(span)

    return BACKTICK_RE.sub(blank, text)


def _sentence_spans(text: str) -> list:
    """`(offset, sentence)` for each sentence, offsets into `text`."""
    spans = []
    start = 0
    for match in SENTENCE_SPLIT_RE.finditer(text):
        spans.append((start, text[start:match.start()]))
        start = match.end()
    spans.append((start, text[start:]))
    return spans


def _normalized(sentence: str) -> str:
    """One sentence in the form a template is written in.

    Line wrapping collapses and a space before punctuation goes -- a report's
    wrapping is not something it means. A parenthesis becomes a character no
    template contains, so a sentence carrying one is a sentence this parser
    does not read.
    """
    marked = PAREN_RE.sub(UNREADABLE_MARK, sentence)
    collapsed = " ".join(marked.split())
    return re.sub(r"\s+([,;:.])", r"\1", collapsed).strip()


def _excluded_numbers(found) -> set:
    """The pull requests a matched template puts outside its batch."""
    captured = found.groupdict().get("excluded")
    if not captured:
        return set()
    return {int(number) for number in NUMBER_RE.findall(captured)}


def _self_contradiction(found, numbers: list):
    """Why a matched scope sentence disagrees with itself, or None.

    A sentence that names a pull request twice, or that says it covered a
    different number of them than it goes on to list, is prose this helper
    cannot read. Either half could be the stale one, and deciding which is
    the operator's call rather than this parser's.
    """
    repeated = sorted({number for number in numbers if numbers.count(number) > 1})
    if repeated:
        return (
            "an enumeration naming "
            + ", ".join(f"#{number}" for number in repeated)
            + " more than once"
        )
    declared = found.groupdict().get("count")
    if declared is None:
        return None
    value = count_value(declared)
    if value is None or value == len(numbers):
        return None
    return (
        f"a sentence saying it covered {declared} pull requests and then "
        f"listing {len(numbers)}"
    )


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
    enumerations = []
    unreadable = []
    excluded = set()
    for _, sentence in _sentence_spans(masked):
        normalized = _normalized(sentence)
        if not normalized:
            continue
        matched = [
            found
            for found in (pattern.match(normalized) for pattern in SCOPE_PATTERNS)
            if found
        ]
        if matched:
            for found in matched:
                excluded |= _excluded_numbers(found)
                numbers = [int(number) for number in NUMBER_RE.findall(found.group("enum"))]
                contradiction = _self_contradiction(found, numbers)
                if contradiction is not None:
                    unreadable.append(contradiction)
                else:
                    enumerations.append(numbers)
            continue
        # Every sentence, not only the ones carrying a number: an unnumbered
        # one reverses a numbered one just as easily -- "That batch was
        # nevertheless reviewed in this pass" -- and a sentence nobody read
        # cannot be said to have been accounted for.
        mention = next(
            (found for found in (p.match(normalized) for p in MENTION_PATTERNS) if found),
            None,
        )
        if mention is not None:
            excluded |= _excluded_numbers(mention)
            continue
        if any(pattern.match(normalized) for pattern in PROSE_PATTERNS):
            continue
        unreadable.append(normalized)
    contradicted = sorted(set(enumerations[0]) & excluded) if len(enumerations) == 1 else []
    if len(enumerations) == 1 and not unreadable and not contradicted:
        return {"path": path, "reviewed": enumerations[0], "candidates": candidates, "flag": None}
    if unreadable:
        reason = (
            "carries a sentence this helper does not read: "
            f"{unreadable[0]!r}"
        )
    elif contradicted:
        reason = (
            "enumerates "
            + ", ".join(f"#{number}" for number in contradicted)
            + " as reviewed and elsewhere places "
            + ("them" if len(contradicted) > 1 else "it")
            + " outside the batch"
        )
    elif not enumerations:
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
    path = confined(root, document_path(root))
    # An early refusal so a run that cannot succeed does no reading, and a
    # second one at the moment of creation so two runs that both got past
    # this one cannot both publish.
    if _name_is_taken(path):
        raise LedgerError(
            f"{path} already exists, so a ledger is already established under "
            "this root. A second migration would replace completed reviews "
            "with legacy rows; edit the ledger through this helper instead."
        )
    cursor_relative = cursor.DOCUMENT_RELATIVE_PATH
    cursor_path = confined(root, Path(root) / cursor_relative)
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
    written = create_document(root, document)
    result["document"] = str(written)
    result["state"] = document["repositories"][repo]
    return result


def _name_is_taken(path: Path) -> bool:
    """Whether anything holds this name, a broken symlink included.

    `lstat` rather than `exists`, which answers false both for a name nothing
    holds and for one it could not look up, and false for a dangling symlink
    that would still defeat the creation below.
    """
    try:
        os.lstat(path)
    except FileNotFoundError:
        return False
    except OSError as error:
        raise LedgerError(
            f"{path} could not be looked up ({error}); a name this helper "
            "cannot examine is not a free one."
        ) from error
    return True


def _cursor_source(cursor, cursor_path: Path) -> str:
    """Which of the three record shapes `cursor_path` holds.

    Classified with the cursor module's own markers so this never disagrees
    with the parser that reads the file a moment later. Only the hand-authored
    shape needs distinguishing on its own account -- its exclusive stop is not
    coverage -- but naming all three makes the migration's provenance say what
    it actually read.
    """
    try:
        text = cursor_path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return "absent"
    except OSError as error:
        raise LedgerError(
            f"{cursor_path} could not be read ({error}); an unreadable record "
            "is not an absent one."
        ) from error
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
    directory = confined(root, Path(root) / "docs")
    try:
        os.listdir(directory)
    except FileNotFoundError:
        pass
    except OSError as error:
        raise LedgerError(
            f"{directory} could not be listed ({error}); a directory this "
            "helper cannot enumerate is not one with no reports in it."
        ) from error
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
        report_path = confined(root, Path(root) / entry["path"])
        try:
            text = report_path.read_text(encoding="utf-8")
        except OSError as error:
            raise LedgerError(
                f"{report_path} could not be read ({error}); every report is "
                "inspected, so one that cannot be stops the migration."
            ) from error
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
