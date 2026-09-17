#!/usr/bin/env python3
"""The project-review ledger: per-PR review state, and the migration into it.

Run with: python3 project_review_ledger.py
          {read,migrate,select,claim,renew,release,fence,lease-defaults} --help

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

`select` is the scheduler on top of that document (issue #681, slice
LEDGER-3). It reads one thing from the caller -- the pages of merged pull
requests the caller fetched -- and it reads them with the same suspicion the
migration reads a report with, because a listing that stopped early is
indistinguishable from a repository with fewer pull requests in it, and the
difference is between "#612 has never been reviewed" and "#612 was never
listed". So the pages carry their own continuation metadata and are accepted
only as a contiguous sequence from page 1 that ends in a page shorter than
its own limit; anything else is refused before a row is written or a pull
request is chosen (design D-11).

A listing that passes is the repository's known universe, and it is recorded
as one: a merged pull request with no row gains a never-reviewed one, a row
that already exists keeps its status, evidence and history and takes the
listing's title and merge time, and a row the listing does not name is kept
and reported rather than deleted -- a shrunken listing is a thing to notice,
not a thing to act on. Selection then walks D-8's three queues over the rows
the listing named: never-reviewed newest-merged first, then `[legacy]`
highest number first, then completed reviews oldest first, clean and
findings-bearing alike (D-4), passing over any row somebody holds a live
claim on. It is a function of the ledger, the inventory, and which of those
claims are live, so two runs over the same inputs choose the same pull
request; `select` reports that choice, and `claim` makes the same one and
takes it.

`claim`, `renew`, `release` and `fence` are the lease on top of selection
(issue #682, slice LEDGER-4): an expiring owner-token claim taken on the pull
request selection chose, before any review effort is spent on it (design D-12
and D-17). The ledger row holds the claim's token, its start and its effective
renewal and expiry settings; the renewable expiry lives in a heartbeat record
outside the reviewed tree, so a renewal never rewrites a publishable document.
Every ledger write, and every validation a mutation depends on, happens under
one repository lock held as a Git reference in the Git common directory, which
every linked worktree of the repository shares. The section headed "The
lease" below carries the rules.

Its reach is pinned in `tools/test_agent_workflow_contract.py`. Every
repository document it opens is under the `--root` it was given; the lease's
process-control records -- the lock reference and the heartbeat records --
are under that root's Git common directory, never under `docs/`. It spawns
exactly two things: `git`, for the common directory and the lock reference,
and the renewer, which is this same file run through `sys.executable`. The one
file it reads from anywhere else is `project_review_cursor.py` beside itself,
which is the parser this migration is required to read the existing record
through rather than a second implementation of. The merged-pull-request
listing arrives on standard input for the same reason: an `--inventory <path>`
would be the obvious convenience and it would also be the one read this module
makes at a path nothing checked.

Everything the document itself cannot prove, it refuses. A ledger with no
marker, unreadable JSON, a version it does not read, a status outside the four, an
abbreviated verification SHA, a non-UTC timestamp, a dated legacy row, or a
completed review missing its commit raises `LedgerError` naming what stopped
it. A missing document is the one absence that is not an error, because that
is exactly what a repository that has never been migrated looks like. A
migration over a ledger that already exists refuses too: the first one is the
one that read the evidence, and a second would overwrite completed reviews
with legacy rows.

The versions it reads are a closed set too, and a wider one than the version
it writes: a repository migrated by an earlier release holds a schema version
1 ledger, whose rows predate the `title` and `merged_at` version 2 adds, or a
version 2 one, whose rows and repositories predate the `claim` and
`lease_defaults` version 3 adds. Refusing either would strand that
repository's only record of its coverage behind the helper that is meant to
carry it forward. So both are read and upgraded on the way in -- by naming the
fields each version introduced, never by defaulting whatever a row happens to
be missing -- and every write publishes version 3.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import importlib.util
import json
import math
import os
import posixpath
import re
import secrets
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from select import select as wait_readable

# Where the ledger lives inside the reviewed repository's docs worktree. One
# directory for every ledger-era document (design D-18), so a consumer enrolls
# it once rather than once per report.
LEDGER_RELATIVE_PATH = "docs/project_review/ledger.md"
LEDGER_DIRECTORY = posixpath.dirname(LEDGER_RELATIVE_PATH)

# Version 2 adds a row's `title` and `merged_at`, which the merged-pull-request
# listing supplies (issue #681). Version 3 adds a row's `claim` and a
# repository's `lease_defaults` (issue #682). Versions 1 and 2 are still read,
# because a repository migrated by an earlier release has a ledger in one of
# those shapes and a reader that refused it would strand the only record of
# that repository's coverage behind a helper that cannot open it. They are read
# and never written: an older document parses into the current shape with the
# fields it predates absent, and the next write publishes it as version 3.
SCHEMA_VERSION = 3
READABLE_SCHEMA_VERSIONS = (1, 2, 3)

# Distinct from `<!-- project-review:cursor:v2 -->` on purpose: the two
# documents coexist until LEDGER-6, and a parser that anchored on the other
# one's marker would read whichever document it was handed as its own.
#
# Its `v1` names the container -- one marker line, one fenced JSON payload
# after it -- and not the payload's schema, which the payload states itself in
# `version`. The two are versioned separately on purpose: a schema change that
# also moved the marker would make every older document unfindable by the
# reader that is meant to upgrade it.
LEDGER_MARKER = "<!-- project-review:ledger:v1 -->"

# The closing delimiter is a whole line. Without that, the first three
# backticks on any line closed the block, so a rendered ledger whose final
# fence was edited to ```json or ```junk still parsed -- two fence-looking
# lines to the counter above, and a payload that stopped short of the suffix
# here, while the Markdown had no complete block at all.
PAYLOAD_RE = re.compile(
    re.escape(LEDGER_MARKER) + r"\s*```json\n(?P<payload>.*?)\n```[ \t]*(?:\n|\Z)",
    re.DOTALL,
)

# A fenced-code delimiter as Markdown defines one: three or more backticks or
# tildes, indented no more than three spaces. Counted rather than matched for
# its info string, because every spelling of a fence is a block a reader sees
# and only one of them was a block this parser saw.
FENCE_RE = re.compile(r"\A {0,3}(?:`{3,}|~{3,})")

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

TIMESTAMP_RE = re.compile(r"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\Z")

REPO_RE = re.compile(r"\A[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\Z")

# `str.isdigit()` is true of "²" and of "٣", and `int()` accepts one and
# raises on the other -- so a row keyed by a superscript reached `int()` past
# the check that was supposed to refuse it and left a traceback where the
# refusal should have been. A pull-request number is ASCII decimal.
#
# Bounded, because `int()` refuses a string of more than a few thousand
# digits and raises where the refusal belongs. Twelve digits is far past any
# pull-request number a tracker will issue and far short of that limit, so
# the bound is reached only by something that was never a number.
DIGIT_LIMIT = 12
DECIMAL_RE = re.compile(rf"[0-9]{{1,{DIGIT_LIMIT}}}")

# A repository-relative POSIX path. Absolute paths and `..` segments are
# refused because a rendered link resolves them against the reader's browser,
# not against this module.
PATH_RE = re.compile(r"\A[A-Za-z0-9._/-]+\Z")

# `title` and `merged_at` are the listing's half of a row and the rest is the
# review's. They are optional for the same reason the migration invents no
# dates: a row imported from a report predates any listing, so it carries
# neither until a complete inventory names its pull request, and neither is
# ever paired with a status.
#
# `claim` is the lease's half, and is null whenever nobody holds the row.
ROW_KEYS = (
    "status",
    "title",
    "merged_at",
    "commit",
    "completed_at",
    "report",
    "evidence",
    "history",
    "claim",
)
HISTORY_KEYS = ("kind", "outcome", "commit", "completed_at", "report")

# What `migrate` read the cursor's half of the evidence from, in the order
# `project_review_cursor.parse_document` itself prefers them.
MIGRATION_SOURCES = ("cursor-v2", "cursor-v1", "boundary-document", "absent")

DOCUMENT_HEADER = """# Project review ledger

Machine-owned state for the `project-review` workflow: one row per merged pull
request, per repository, with its title, when it merged, its status, the commit
a completed review verified it against, when that review completed, the report
it produced, and the evidence the row rests on. A checkmark means a clean review
against the commit beside it; `[legacy]` means coverage established by a
document that predates this ledger, with no date and no commit invented for it.
A title and a merge time are the listing's to supply, so a row that no merged-PR
listing has named yet carries neither rather than a guess.

Written by `project_review_ledger.py`. Edit it through that helper rather than
by hand: the payload below is parsed strictly, and an edit it cannot read stops
the next invocation instead of being ignored.
"""

TABLE_HEADER = (
    "| PR | Title | Merged (UTC) | Status | Verified at | Completed (UTC) "
    "| Report | Evidence |\n"
    "| ---: | --- | --- | --- | --- | --- | --- | --- |"
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
        "lease_defaults": None,
    }


def empty_row(status: str = "never-reviewed") -> dict:
    return {
        "status": status,
        "title": None,
        "merged_at": None,
        "commit": None,
        "completed_at": None,
        "report": None,
        "evidence": [],
        "history": [],
        "claim": None,
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
    # Counted over the document, not only behind the marker, and counted as
    # fences rather than as one spelling of one: ```JSON, ``` json, four
    # backticks and a tilde fence are all the same block to a Markdown reader
    # and were all invisible to a line equal to "```json".
    fences = sum(1 for line in text.splitlines() if FENCE_RE.match(line))
    if fences != 2:
        raise LedgerError(
            f"{source} carries {fences} fence lines; a ledger holds exactly "
            "one fenced block, and a reader that took one of several would be "
            "choosing between them without saying so."
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
    except ValueError as error:
        # `JSONDecodeError` is one of these, and so is the refusal `int()`
        # raises on a numeric literal of more than a few thousand digits.
        raise LedgerError(f"{source} holds unreadable ledger JSON ({error}).") from error
    if not isinstance(document, dict):
        raise LedgerError(f"{source} holds a ledger payload that is not an object.")
    version = document.get("version")
    # `True == 1` and `1.0 == 1` in Python, so a membership test alone would
    # read a boolean or a float as schema version 1 and normalize a malformed
    # document into an accepted one.
    if (
        not isinstance(version, int)
        or isinstance(version, bool)
        or version not in READABLE_SCHEMA_VERSIONS
    ):
        raise LedgerError(
            f"{source} declares ledger schema version {version!r}; this helper "
            f"reads {' and '.join(str(known) for known in READABLE_SCHEMA_VERSIONS)} "
            f"and writes {SCHEMA_VERSION}."
        )
    repositories = document.get("repositories")
    if not isinstance(repositories, dict):
        raise LedgerError(f"{source} declares no `repositories` object.")
    _require_keys(document, DOCUMENT_KEYS, source)
    parsed = empty_document()
    for name, state in repositories.items():
        if not REPO_RE.match(str(name)):
            raise LedgerError(f"{source} names {name!r}, which is not an owner/name.")
        if version < SCHEMA_VERSION:
            state = _upgraded_repository(state, version)
        parsed["repositories"][name] = _validated_repository(state, f"{source}: {name}")
    return parsed


# What each schema version added to a row, so an older document is upgraded by
# naming the version that introduced a field rather than by defaulting whatever
# happens to be missing. Defaulting is what `_require_keys` refuses, and for
# good reason: it is how a truncated edit erases rows. An upgrade keyed on the
# declared version is the opposite -- the document says which shape it is in,
# and only the fields that shape genuinely predates are supplied.
ROW_FIELDS_ADDED_IN = {2: ("title", "merged_at"), 3: ("claim",)}
REPOSITORY_FIELDS_ADDED_IN = {3: ("lease_defaults",)}


def _added_since(table: dict, version: int) -> list:
    return [
        field
        for introduced, fields in sorted(table.items())
        if introduced > version
        for field in fields
    ]


def _upgraded_repository(state, version: int):
    """One repository's entry read out of an older schema into the current one.

    Rows gain the fields versions 2 and 3 added and the repository gains the
    field version 3 added, each a field the older writer could not have known
    about and each null in the shape that predates it. Everything else is
    passed through untouched so the validation below sees exactly what the
    document said.
    """
    if not isinstance(state, dict):
        return state
    upgraded = dict(
        {field: None for field in _added_since(REPOSITORY_FIELDS_ADDED_IN, version) if field not in state},
        **state,
    )
    rows = state.get("rows")
    if not isinstance(rows, dict):
        return upgraded
    added = _added_since(ROW_FIELDS_ADDED_IN, version)
    upgraded["rows"] = {
        key: (
            dict({field: None for field in added if field not in row}, **row)
            if isinstance(row, dict)
            else row
        )
        for key, row in rows.items()
    }
    return upgraded


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
    except FileNotFoundError as error:
        # `read_text` raises this for a name nothing holds, for a symlink with
        # nothing behind it, and for a name behind a broken directory. Only
        # the first is absence; the others are a ledger someone put there and
        # broke, and reading them as "never migrated" both loses the state and
        # lets a migration write over the name.
        require_reachable(root, path)
        if _name_is_taken(path):
            raise LedgerError(
                f"{path} is a link with nothing behind it; a broken ledger is "
                "not an absent one."
            ) from error
        return empty_document()
    except (OSError, UnicodeDecodeError) as error:
        # `UnicodeDecodeError` is a `ValueError`, so a ledger holding bytes
        # that are not UTF-8 left a traceback where the refusal belongs.
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


REPOSITORY_KEYS = ("rows", "direct", "excluded", "migration", "lease_defaults")
DIRECT_KEYS = ("endpoint", "reviewed")
EXCLUDED_KEYS = ("prs", "commits")
MIGRATION_KEYS = ("source", "boundary", "withheld_boundary")


DOCUMENT_KEYS = ("version", "repositories")
ENDPOINT_KEYS = ("sha",)
BOUNDARY_KEYS = ("number", "merged_at")


# What an unreadable field costs the document that carries it, which is not
# the same cost in both directions. A ledger is read and rewritten, so a field
# nothing here understands is a field the next write drops; a listing is read
# once and never written back, and a field nothing here understands may be the
# very thing that said the listing was complete.
LEDGER_UNKNOWN_FIELD_COST = "one it would drop on the next write"
LISTING_UNKNOWN_FIELD_COST = (
    "one whose bearing on this listing's completeness it cannot know"
)


def _require_keys(
    mapping,
    keys,
    source: str,
    subject: str = "a ledger",
    consequence: str = LEDGER_UNKNOWN_FIELD_COST,
) -> None:
    """Every declared field present and nothing else, at every level.

    Two silences, closed together because they are one decision. Defaulting a
    missing field is how a truncated but still-parseable edit erases rows,
    direct progress, exclusions, or a row's previous attempts; dropping an
    unrecognized one is how a field written by a newer helper, or misspelled
    by a hand-edit, disappears through a read-and-rewrite. A strictly parsed
    document refuses both rather than normalizing either away.

    `subject` is what the refusal calls the thing that owes those fields, and
    `consequence` is what an unreadable one costs it. The merged-pull-request
    listing is held to the same rule and is not a ledger: a refusal that told
    its caller what "a ledger states", or that an unknown field would be
    dropped by a write that never happens to a listing, would be describing
    the wrong document to go and fix.
    """
    missing = [key for key in keys if key not in mapping]
    if missing:
        raise LedgerError(
            f"{source} declares no {', '.join(missing)}; {subject} states every "
            f"one of {', '.join(keys)} rather than leaving any to a default."
        )
    unknown = sorted(set(mapping) - set(keys))
    if unknown:
        raise LedgerError(
            f"{source} carries unrecognized field(s) {', '.join(unknown)}; it "
            f"holds exactly {', '.join(keys)}, and a field this helper cannot "
            f"read is {consequence}."
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
    if state["lease_defaults"] is not None:
        validated["lease_defaults"] = _validated_lease_settings(
            state["lease_defaults"], f"{source}: lease_defaults"
        )
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
    if not DECIMAL_RE.fullmatch(text) or text != str(int(text)) or int(text) <= 0:
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
    validated["title"] = _validated_optional_title(row["title"], f"{source}: title")
    validated["merged_at"] = _validated_optional_timestamp(
        row["merged_at"], f"{source}: merged_at"
    )
    validated["commit"] = _validated_optional_sha(row["commit"], f"{source}: commit")
    validated["completed_at"] = _validated_optional_timestamp(
        row["completed_at"], f"{source}: completed_at"
    )
    validated["report"] = _validated_optional_path(row["report"], f"{source}: report")
    validated["evidence"] = _validated_evidence(row["evidence"], f"{source}: evidence")
    validated["history"] = _validated_history(row["history"], f"{source}: history")
    if row["claim"] is not None:
        validated["claim"] = _validated_claim(row["claim"], f"{source}: claim")
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


def _validated_optional_title(value, source: str):
    """A pull request's own title as the listing gave it, or nothing.

    Not normalized, not truncated and not invented: the title is evidence
    about which pull request a row is, so a row shows the listing's own words
    or shows that it has none.
    """
    if value is None:
        return None
    if not isinstance(value, str):
        raise LedgerError(
            f"{source} holds {value!r}, which is not a pull-request title."
        )
    _require_one_line(value, source)
    return value


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
            "a value this helper renders into the table is one line of "
            "readable text."
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
    if entry.get("kind") == TAKEOVER_KIND:
        return _validated_takeover_entry(entry, source)
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
    _require_coherent_provenance(origin, boundary, withheld, source)
    return {"source": origin, "boundary": boundary, "withheld_boundary": withheld}


def _require_coherent_provenance(origin, boundary, withheld, source: str) -> None:
    """The combinations a migration can actually produce, and no others.

    Each field was checked on its own, so a record could say it carried
    nothing over and still hold the boundary it carried -- which the table
    then rendered as "Nothing carried over from a previous record" while the
    payload said otherwise. A provenance record that describes a migration
    that never happened is worse than no record: it is one an operator would
    read and believe.
    """
    if origin in (None, "absent"):
        if boundary is not None or withheld is not None:
            raise LedgerError(
                f"{source}: migration says it read {origin!r} and still holds a "
                "boundary; a record carried over from nothing carries nothing."
            )
        return
    if origin == "cursor-v1" and boundary is not None:
        raise LedgerError(
            f"{source}: migration reads a v1 cursor and holds an exclusive "
            "boundary; version 1's endpoint is coverage, and the cursor's own "
            "parser retires it on read."
        )
    if withheld is None:
        if origin == "boundary-document" and boundary is not None:
            raise LedgerError(
                f"{source}: migration read a hand-authored record holding a "
                f"stop at #{boundary['number']} and withheld nothing; that "
                "record spells its stop as coverage, so a migration that read "
                "one always has a stop to withhold."
            )
        return
    if origin != "boundary-document":
        raise LedgerError(
            f"{source}: migration withheld a boundary from a {origin!r} record; "
            "only the hand-authored document spells its stop as coverage, so "
            "only it has a stop to withhold."
        )
    if boundary is None or withheld != boundary["number"]:
        raise LedgerError(
            f"{source}: migration withheld #{withheld} while its boundary is "
            f"{boundary and boundary['number']}; the withheld pull request is "
            "the boundary, or it is a number from nowhere."
        )


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
            _cell(row["title"]) if row["title"] else "—",
            row["merged_at"] or "—",
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
    # Backslashes first: escaping the pipe in "left\\|right" without them
    # produces an even backslash run, which leaves the pipe a cell delimiter
    # and shifts every column after it.
    return text.replace("\\", "\\\\").replace("|", "\\|")


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

    An edit to an established ledger publishes through `publish_document`
    instead, which is the same writer over `os.replace`.
    """
    path = confined(root, document_path(root))
    parent = _prepared_directory(root, path)
    temporary = _rendered_into_temporary(parent, document)
    try:
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            raise LedgerError(
                f"{path} already exists, so a ledger is already established "
                "under this root. A second migration would replace completed "
                "reviews with legacy rows; edit the ledger through this helper "
                "instead."
            ) from error
        except OSError as error:
            raise LedgerError(
                f"{path} could not be created ({error}); a ledger this helper "
                "cannot publish is not one it may report as written."
            ) from error
    finally:
        _discard(temporary)
    return path


def publish_document(root, document: dict) -> Path:
    """Replace the document with this one, atomically.

    The same writer as `create_document` and deliberately not the same
    publication: `os.link` refuses a name something already holds, which is
    exactly what a migration wants and exactly what an edit to an established
    ledger cannot use. `os.replace` puts a complete document where the
    previous complete document was, in one operation, so a reader never sees
    a half-written ledger and an interrupted write leaves the previous one
    intact.

    What it does not do is sequence two writers. Two selections racing each
    other would lose one of their reconciliations, because each rendered the
    whole document from the state it read, so every caller that edits an
    established ledger holds `repository_lock` across its read and this
    write (design D-12).
    """
    path = confined(root, document_path(root))
    parent = _prepared_directory(root, path)
    temporary = _rendered_into_temporary(parent, document)
    try:
        os.replace(temporary, path)
    except OSError as error:
        _discard(temporary)
        raise LedgerError(
            f"{path} could not be replaced ({error}); a ledger this helper "
            "cannot publish is not one it may report as written."
        ) from error
    return path


def _prepared_directory(root, path: Path) -> Path:
    """The ledger's own directory, proven usable and proven inside `root`."""
    parent = confined(root, path.parent)
    require_reachable(root, path)
    try:
        parent.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        raise LedgerError(
            f"{parent} could not be created ({error}); the ledger's own "
            "directory is the one thing this helper makes, so failing to make "
            "it is a refusal rather than a traceback."
        ) from error
    return confined(root, parent)


def _rendered_into_temporary(parent: Path, document: dict) -> str:
    """The whole document, written beside where it is going.

    Whole-file-then-publish for the reason every write here is: the
    alternative to a complete ledger is a truncated one, and a truncated
    ledger stops every later invocation by design.
    """
    handle, temporary = tempfile.mkstemp(dir=str(parent), prefix=".project-review-ledger-")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(render_document(document))
    except BaseException:
        _discard(temporary)
        raise
    return temporary


def _discard(temporary: str) -> None:
    try:
        os.unlink(temporary)
    except OSError:
        pass


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

# `\d` matches "١", and `int("#١٢"[1:])` is 12 -- so a report writing its
# batch in Arabic-Indic digits was read as coverage of pull requests it never
# spells. ASCII, and bounded, and refusing to stop early: a longer run of
# digits is not a pull-request number with a tail, it is not one at all.
# No leading zero and no zero: "#0001" is not how a tracker writes #1 and
# "#0" is not a pull request at all. Both were read as numbers, one silently
# normalized into coverage and the other carried to a fatal refusal deep in
# the migration where a report flag belonged.
NUMBER_TOKEN = rf"#[1-9][0-9]{{0,{DIGIT_LIMIT - 1}}}(?![0-9])"
NUMBER_RE = re.compile(rf"#([1-9][0-9]{{0,{DIGIT_LIMIT - 1}}})(?![0-9])")

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
    if DECIMAL_RE.fullmatch(text):
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
    "ENUM": rf"(?P<enum>{NUMBER_TOKEN}(?:{LIST_SEPARATOR}{NUMBER_TOKEN})*)",
    # A pull request the sentence puts *outside* the batch: the cursor it
    # resumed below, the stop it did not cross, a landing it excluded, a batch
    # someone else reported, the bound it stayed above. Captured, because a
    # paragraph that both excludes a pull request and enumerates it
    # contradicts itself and is not one this helper can read.
    "EXCLUDED": rf"(?P<excluded>{NUMBER_TOKEN}(?:{LIST_SEPARATOR}{NUMBER_TOKEN})*)",
    # A pull request named for context rather than exclusion -- an interval's
    # endpoints, the landing a commit came after. These legitimately overlap
    # the batch: nine tracked reports name their oldest reviewed pull request
    # as one end of the span their direct commits sit in.
    "NUM": NUMBER_TOKEN,
    "NUMS": rf"{NUMBER_TOKEN}(?:{LIST_SEPARATOR}{NUMBER_TOKEN})*",
    # `\d` matches "٣" and `count_value` does not, so a template that took a
    # Unicode digit produced a count nothing could read -- and an unreadable
    # count was treated as no count, which is how a sentence declaring three
    # pull requests and listing two got past the cardinality check.
    "COUNT": r"(?:(?:twenty|thirty)-(?:one|two|three|four|five|six|seven|"
             r"eight|nine)|one|two|three|four|five|six|seven|eight|nine|ten|"
             r"eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|"
             rf"eighteen|nineteen|twenty|thirty|[0-9]{{1,{DIGIT_LIMIT}}}(?![0-9]))",
    "DATE": r"[0-9]{4}-[0-9]{2}-[0-9]{2}",
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
    if value is None:
        # Belt and braces behind the ASCII template above: a count this helper
        # cannot read is not a count it may ignore.
        return f"a sentence saying it covered {declared!r} pull requests"
    if value == len(numbers):
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
    require_reachable(root, path)
    if _name_is_taken(path):
        raise LedgerError(
            f"{path} already exists, so a ledger is already established under "
            "this root. A second migration would replace completed reviews "
            "with legacy rows; edit the ledger through this helper instead."
        )
    cursor_relative = cursor.DOCUMENT_RELATIVE_PATH
    cursor_path = confined(root, Path(root) / cursor_relative)
    source, state = _read_cursor(cursor, cursor_path, repo)

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


def require_reachable(root, path) -> None:
    """Every directory between `root` and `path` is one, or a refusal.

    A dangling `docs/project_review` makes `read_text` raise the same
    `FileNotFoundError` a missing ledger does, and `lstat` on the ledger
    behind it raises it too -- so a broken ancestor read as a repository that
    had never been migrated, and a migration past it died on `mkdir` with an
    exception the CLI had no answer for. A component that exists and is not a
    directory is a place this helper cannot put a ledger, and saying so is
    not the same as saying there is no ledger.
    """
    anchor = Path(root).resolve(strict=False)
    ancestors = []
    current = Path(path).parent
    while True:
        ancestors.append(current)
        if current.parent == current or current.resolve(strict=False) == anchor:
            break
        current = current.parent
    for ancestor in reversed(ancestors):
        try:
            os.lstat(ancestor)
        except FileNotFoundError:
            continue
        except OSError as error:
            raise LedgerError(
                f"{ancestor} could not be looked up ({error}); a path this "
                "helper cannot examine is not a clear one."
            ) from error
        if not os.path.isdir(ancestor):
            raise LedgerError(
                f"{ancestor} is not a directory; the ledger lives under it, "
                "so a link with nothing behind it or a file in its place is "
                "not an absent ledger but an unusable one."
            )


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


def _read_cursor(cursor, cursor_path: Path, repo: str):
    """`(source, state)` from one read of the record.

    One read, because there were two: the file was opened to classify its
    shape and opened again to parse its state, and the cursor's own writer
    publishes by atomic replacement. A replacement landing between them made
    the provenance and the coverage describe different documents -- classified
    as a v2 cursor, parsed as a hand-authored one, and its stop imported as
    reviewed instead of withheld. The ledger is written once and cannot be
    overwritten, so that error would have been permanent.

    Classified with the cursor module's own markers, and parsed with its own
    parser, so neither half is a second opinion about the same bytes.
    """
    try:
        text = cursor_path.read_text(encoding="utf-8")
    except FileNotFoundError as error:
        if _name_is_taken(cursor_path):
            raise LedgerError(
                f"{cursor_path} is a link with nothing behind it; a broken "
                "record is not an absent one, and migrating past it would "
                "write a ledger this root can never correct."
            ) from error
        return "absent", cursor.state_for(cursor.empty_document(), repo)
    except (OSError, UnicodeDecodeError) as error:
        raise LedgerError(
            f"{cursor_path} could not be read ({error}); an unreadable record "
            "is not an absent one."
        ) from error
    if cursor.PAYLOAD_RE.search(text):
        source = "cursor-v2"
    elif cursor.LEGACY_PAYLOAD_RE.search(text):
        source = "cursor-v1"
    else:
        source = "boundary-document"
    try:
        document = cursor.parse_document(text, str(cursor_path))
    except cursor.CursorError as error:
        raise LedgerError(
            f"the existing record at {cursor_path} could not be read ({error}); "
            "the migration reads it through the cursor's own parser and will "
            "not guess at a record it cannot parse."
        ) from error
    return source, cursor.state_for(document, repo)


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
        # Confined and read before the confirmation branch, not after it. A
        # confirmation used to skip both, so a report path that was a symlink
        # out of the worktree, a link with nothing behind it, or a directory
        # became a row's evidence -- evidence nobody can go and check, which
        # is the one thing a legacy row is for.
        report_path = confined(root, Path(root) / entry["path"])
        try:
            text = report_path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as error:
            raise LedgerError(
                f"{report_path} could not be read ({error}); every report is "
                "inspected, so one that cannot be stops the migration."
            ) from error
        if entry["path"] in confirmations:
            record["reviewed"] = sorted(set(confirmations.pop(entry["path"])), reverse=True)
            record["confirmed"] = True
            reports.append(record)
            continue
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
# The merged-pull-request inventory

# What a caller hands `select`: the pages it fetched, in the order it fetched
# them, each one saying what it asked for and what came back.
#
# The page number is the part a caller might think is redundant, and it is the
# part that makes the sequence checkable. Page lengths alone cannot tell "page
# 1, page 2, page 3" from "page 1, page 3" -- both are a run of full pages
# ending in a short one -- so a listing with an interior page dropped read as
# complete, and every pull request on the missing page became a pull request
# this repository does not have. The numbers turn that into a contiguity
# check against the position each page was handed in.
INVENTORY_KEYS = ("pages",)
PAGE_KEYS = ("page", "limit", "prs")
LISTED_KEYS = ("number", "title", "merged_at")

# The three queues of design D-8, named so a caller can tell which one its
# pull request came out of without re-deriving the order itself.
QUEUE_NEVER_REVIEWED = "never-reviewed"
QUEUE_LEGACY = "legacy"
QUEUE_REFRESH = "refresh"

TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%SZ"


def parse_inventory(raw, source: str) -> dict:
    """A complete listing of the repository's merged pull requests, or a refusal.

    Complete is the whole of what this function decides, and it decides it
    from the pages rather than from the rows on them: a contiguous sequence
    starting at page 1, one page size across the whole walk, every page
    holding no more than it asked for, nothing after the first page that came
    back short, and a short page at the end. The last rule is the one design
    D-11 turns on -- a page returned at its own limit may be a page of a
    longer history, and nothing in the page itself can tell the two apart --
    so a listing that ends full is refused asking for the next page rather
    than recorded as a universe.

    One page size, because a page number means nothing without one. A page
    number is an offset expressed in page sizes, so "page 1 of 2, page 2 of
    4" names rows 1-2 and then rows 5-8, and the two pull requests in between
    are ones no page ever carried. Contiguous numbering said the walk was
    whole and a short final page said it had ended, and both were true of a
    listing with a hole in the middle of it.

    Every refusal here happens before anything is selected or written, so a
    listing this function does not accept leaves the ledger exactly as it was.
    """
    if not isinstance(raw, dict):
        raise LedgerError(f"{source} is not an object.")
    _require_keys(
        raw,
        INVENTORY_KEYS,
        source,
        "a merged-pull-request listing",
        LISTING_UNKNOWN_FIELD_COST,
    )
    pages = raw["pages"]
    if not isinstance(pages, list):
        raise LedgerError(f"{source}: pages is not a list.")
    if not pages:
        raise LedgerError(
            f"{source} carries no pages at all; an empty sequence is not a "
            "listing that came back empty, it is a listing nobody made, and "
            "recording it would state that this repository has never merged a "
            "pull request."
        )
    listed = []
    seen = {}
    short = None
    size = None
    for index, page in enumerate(pages):
        position = index + 1
        where = f"{source}: page {position}"
        if not isinstance(page, dict):
            raise LedgerError(f"{where} is not an object.")
        _require_keys(
            page, PAGE_KEYS, where, "a listing page", LISTING_UNKNOWN_FIELD_COST
        )
        declared = page["page"]
        if isinstance(declared, bool) or not isinstance(declared, int) or declared != position:
            raise LedgerError(
                f"{where} declares page number {declared!r}; the pages are read "
                f"as the contiguous sequence the caller fetched, so the page in "
                f"this position is {position}. A repeat, a gap, or a listing "
                "that does not start at page 1 is a listing with a page missing "
                "from it, and a missing page is pull requests this repository "
                "would be recorded as not having."
            )
        if short is not None:
            raise LedgerError(
                f"{where} follows page {short}, which came back short of its own "
                "limit and is therefore the last page of the history; a page "
                "after the last one describes a listing this helper cannot place."
            )
        limit = page["limit"]
        if isinstance(limit, bool) or not isinstance(limit, int) or limit <= 0:
            raise LedgerError(
                f"{where} declares limit {limit!r}, which is not a positive page "
                "size; the limit is the only thing that says whether the page "
                "came back short, so a page without one proves nothing about "
                "the history behind it."
            )
        if size is None:
            size = limit
        elif limit != size:
            raise LedgerError(
                f"{where} declares limit {limit}, but page 1 declared {size}; a "
                "page number is an offset expressed in page sizes, so a walk "
                "that changed its page size skips or repeats the rows between "
                "the two and its numbering no longer says which rows were "
                "listed. List the whole history at one page size."
            )
        rows = page["prs"]
        if not isinstance(rows, list):
            raise LedgerError(f"{where}: prs is not a list.")
        if len(rows) > limit:
            raise LedgerError(
                f"{where} carries {len(rows)} pull requests at limit {limit}; a "
                "page cannot hold more than it asked for, so its limit does not "
                "describe the request that produced it."
            )
        if len(rows) < limit:
            short = position
        for offset, entry in enumerate(rows):
            listed.append(_validated_listed(entry, seen, f"{where}, entry {offset}"))
    if short is None:
        last = pages[-1]
        raise LedgerError(
            f"{source} ends with page {len(pages)}, which came back at its own "
            f"limit of {last['limit']}; a full page may be a page of a longer "
            "history, so the next page is needed before this listing is a "
            "complete one."
        )
    return {"pages": len(pages), "listed": listed}


def _validated_listed(entry, seen: dict, source: str) -> dict:
    if not isinstance(entry, dict):
        raise LedgerError(f"{source} is not an object.")
    _require_keys(
        entry, LISTED_KEYS, source, "a listed pull request", LISTING_UNKNOWN_FIELD_COST
    )
    number = entry["number"]
    if isinstance(number, bool) or not isinstance(number, int) or number <= 0:
        raise LedgerError(
            f"{source} holds {number!r}, which is not a pull-request number."
        )
    if len(str(number)) > DIGIT_LIMIT:
        # The bound the row keys are read back under. A number past it would
        # be written into a ledger the parser then refuses, which is a
        # repository this helper has broken rather than one it has recorded.
        raise LedgerError(
            f"{source} holds #{number}, which is longer than the "
            f"{DIGIT_LIMIT} digits a pull-request number is read back under."
        )
    if number in seen:
        raise LedgerError(
            f"{source} names pull request #{number}, which {seen[number]} named "
            "already; one pull request listed twice is a listing that does not "
            "describe what the repository holds, and a reader that took either "
            "copy would be choosing between them without saying so."
        )
    seen[number] = source
    title = entry["title"]
    if not isinstance(title, str):
        raise LedgerError(
            f"{source} holds title {title!r} for #{number}, which is not a "
            "pull-request title."
        )
    _require_one_line(title, f"{source}: title")
    if entry["merged_at"] is None:
        raise LedgerError(
            f"{source} names #{number} with no merge time; the never-reviewed "
            "queue is an order over merge times, so a pull request without one "
            "cannot be placed in it."
        )
    merged_at = _validated_optional_timestamp(entry["merged_at"], f"{source}: merged_at")
    return {"number": number, "title": title, "merged_at": merged_at}


def _instant(value, source: str) -> datetime:
    """A validated timestamp as the moment it names.

    Compared as a moment rather than as text. The spelling this document
    accepts happens to sort chronologically, which is exactly why an ordering
    built on it is worth stating: the next spelling that is added would sort
    some other way, and an order that silently stopped being chronological is
    not a thing a test would see.
    """
    if not isinstance(value, str):
        raise LedgerError(
            f"{source} holds {value!r}, which is not a time this helper can "
            "order a queue by."
        )
    try:
        return datetime.strptime(value, TIMESTAMP_FORMAT)
    except ValueError as error:
        raise LedgerError(f"{source} holds {value!r}, which is not a real date ({error}).") from error


def reconcile(state: dict, inventory: dict) -> dict:
    """Fold a complete listing into one repository's rows, in place.

    The listing owns which pull requests exist and what they are called; the
    ledger owns what has been done about them. So a listed pull request with
    no row gains a never-reviewed one, a listed pull request that already has
    a row keeps its status, its commit, its completed time, its report, its
    evidence and its history and takes only the listing's title and merge
    time, and a row the listing does not name is kept.

    Kept, and reported. A row the listing lost is either a pull request that
    stopped being merged or a listing that is lying about the repository, and
    neither is something to resolve by deleting the only record of a review
    that was performed (design D-11). It stops being selectable, because
    selection is over what the repository currently holds, and it comes back
    the moment a listing names it again.
    """
    rows = state["rows"]
    added = []
    refreshed = []
    for entry in inventory["listed"]:
        key = str(entry["number"])
        row = rows.get(key)
        if row is None:
            row = empty_row("never-reviewed")
            rows[key] = row
            added.append(entry["number"])
        else:
            refreshed.append(entry["number"])
        row["title"] = entry["title"]
        row["merged_at"] = entry["merged_at"]
    listed = {entry["number"] for entry in inventory["listed"]}
    absent = sorted(int(key) for key in rows if int(key) not in listed)
    return {
        "added": sorted(added),
        "refreshed": sorted(refreshed),
        "absent": absent,
    }


def queues(state: dict, inventory: dict) -> list:
    """Design D-8's three queues over the rows this listing named, in order.

    Over the rows the listing named, because a row the listing does not name
    is a pull request this repository does not currently hold, and scheduling
    a review of one would be reviewing something nobody can look at. That is
    the only thing that keeps a row out of a queue besides the repository's
    own exclusions.

    1. Never-reviewed, newest merge time first, ties by descending number.
    2. `[legacy]`, highest number first -- numbers explicitly, not merge
       dates, which is the distinction D-8 records the owner making.
    3. Completed reviews, oldest completed time first, ties by ascending
       number, clean and findings-bearing alike (D-4).

    Every order is total, so the queues are a function of the ledger and the
    listing and of nothing else -- not of the order the pages arrived in, and
    not of the order a JSON object happened to render its keys in.
    """
    listed = {entry["number"] for entry in inventory["listed"]}
    excluded = set(state["excluded"]["prs"])
    # Read out of the rows rather than looked up by listed number, so this
    # function is total over any state it is handed rather than raising a
    # `KeyError` at a caller that reconciled the wrong thing. Every order
    # below is imposed explicitly, so the order the rows happen to be stored
    # in reaches nothing.
    eligible = [
        (int(key), row)
        for key, row in state["rows"].items()
        if int(key) in listed and int(key) not in excluded
    ]
    never = [item for item in eligible if item[1]["status"] == "never-reviewed"]
    legacy = [item for item in eligible if item[1]["status"] == "legacy"]
    refresh = [item for item in eligible if item[1]["status"] in COMPLETED_STATUSES]
    never.sort(
        key=lambda item: (
            _instant(item[1]["merged_at"], f"#{item[0]}: merged_at"),
            item[0],
        ),
        reverse=True,
    )
    legacy.sort(key=lambda item: item[0], reverse=True)
    refresh.sort(
        key=lambda item: (
            _instant(item[1]["completed_at"], f"#{item[0]}: completed_at"),
            item[0],
        )
    )
    return [
        (QUEUE_NEVER_REVIEWED, never),
        (QUEUE_LEGACY, legacy),
        (QUEUE_REFRESH, refresh),
    ]


def select(root, repo: str, inventory, lock_wait: float = None) -> dict:
    """Record one complete listing and choose the one pull request to review.

    The listing is parsed before the ledger is read and the choice is made
    before anything is written, so a refusal at any point leaves the document
    byte for byte as it was. The read, the choice and the write happen under
    `repository_lock`, so a claim another invocation records meanwhile is not
    overwritten by this one's reconciliation.

    A ledger has to exist first, and this is not a formality. `migrate` is
    what reads the old cursor and the sibling reports into `[legacy]` rows,
    and it refuses to run over a ledger that already exists -- so a selection
    that established the ledger itself would record every merged pull request
    as never-reviewed and close the only door legacy coverage comes through.
    A repository with no history to import still starts with `migrate`, which
    writes it an empty ledger.

    A pull request somebody holds a live claim on is skipped and reported, and
    selection continues in queue order. A choice that is an expired claim is
    reported as one; taking it over is `claim`'s, not this function's.
    """
    listing = _listing_for(repo, inventory)
    with repository_lock(root, lock_wait) as common:
        chosen = _choose(root, repo, listing, common, time.time())
        if chosen["pick"] is None and chosen["skipped"]:
            return _selection_result("all-claimed", chosen, repo, None)
        written = _publish_reconciled(root, repo, chosen)
        return _selection_result(
            "selected" if chosen["pick"] else "no-selectable-row", chosen, repo, written
        )


def _listing_for(repo: str, inventory) -> dict:
    if not REPO_RE.match(str(repo)):
        raise LedgerError(f"{repo!r} is not an owner/name repository identity.")
    return parse_inventory(inventory, "the merged-pull-request inventory")


def _choose(root, repo: str, listing: dict, common: Path, now: float) -> dict:
    """The ledger reconciled with the listing, and D-8's first unheld row.

    Read here, under the caller's lock, and never from anything computed
    before it was taken: a candidate chosen from an earlier read is not
    authority to claim a pull request somebody has claimed since.
    """
    path = confined(root, document_path(root))
    document = load_document(root)
    if not document["repositories"]:
        raise LedgerError(
            f"{path} holds no ledger, so there is nothing to record this "
            f"listing against. Migrate {repo} first: a selection that "
            "established the ledger itself would record every merged pull "
            "request as never-reviewed, and no later migration could correct "
            "it."
        )
    if repo not in document["repositories"]:
        named = ", ".join(sorted(document["repositories"]))
        raise LedgerError(
            f"{path} holds no entry for {repo}; it holds {named}. A listing is "
            "recorded as one repository's known universe, and a repository "
            "this ledger has never been migrated for has no coverage for it to "
            "be recorded against."
        )
    state = state_for(document, repo)
    reconciliation = reconcile(state, listing)
    validated = _validated_repository(state, f"the ledger reconciled for {repo}")
    rows = validated["rows"]
    listed = {entry["number"] for entry in listing["listed"]}
    # Over every listed pull request and only those, excluded ones included:
    # the counts describe the universe this listing established, while the
    # queue size below describes what could have been selected out of it.
    counts = {status: 0 for status in ROW_STATUSES}
    for key, row in rows.items():
        if int(key) in listed:
            counts[row["status"]] += 1
    pick = None
    skipped = []
    for name, queue in queues(validated, listing):
        for number, row in queue:
            deadline = None
            if row["claim"] is not None:
                deadline = lease_deadline(common, repo, number, row["claim"])
                if now < deadline:
                    skipped.append(
                        {
                            "number": number,
                            "token": row["claim"]["token"],
                            "deadline": precise_timestamp(deadline),
                        }
                    )
                    continue
            pick = {
                "number": number,
                "row": row,
                "queue": {"name": name, "size": len(queue)},
                "expired_claim": (
                    None
                    if row["claim"] is None
                    else {
                        "token": row["claim"]["token"],
                        "deadline": precise_timestamp(deadline),
                    }
                ),
            }
            break
        if pick is not None:
            break
    return {
        "document": document,
        "state": validated,
        "listing": listing,
        "reconciliation": reconciliation,
        "excluded": sorted(listed & set(validated["excluded"]["prs"])),
        "counts": counts,
        "pick": pick,
        "skipped": skipped,
    }


def _publish_reconciled(root, repo: str, chosen: dict) -> Path:
    document = chosen["document"]
    document["repositories"][repo] = _validated_repository(
        chosen["state"], f"the ledger written for {repo}"
    )
    return publish_document(root, document)


def _selection_result(status: str, chosen: dict, repo: str, written) -> dict:
    """What `select` and `claim` both report, in one shape.

    `document` is null exactly when nothing was written: every candidate was
    held by a live claim, so the invocation recorded neither the listing nor a
    claim (`all-claimed`), and `skipped_claims` says who holds each of them.
    """
    rows = chosen["state"]["rows"]
    pick = chosen["pick"]
    return {
        "status": status,
        "repo": repo,
        "document": None if written is None else str(written),
        "selected": (
            None
            if pick is None
            else {
                "number": pick["number"],
                "title": pick["row"]["title"],
                "merged_at": pick["row"]["merged_at"],
                "row_status": pick["row"]["status"],
                "expired_claim": pick["expired_claim"],
            }
        ),
        "queue": None if pick is None else pick["queue"],
        "skipped_claims": chosen["skipped"],
        "inventory": {
            "pages": chosen["listing"]["pages"],
            "listed": len(chosen["listing"]["listed"]),
            "added": chosen["reconciliation"]["added"],
            "refreshed": chosen["reconciliation"]["refreshed"],
            "excluded": chosen["excluded"],
            "counts": chosen["counts"],
            # The rows this listing did not name, with whatever the ledger
            # knows about them and nothing else. A row imported from a report
            # has no title and no merge time, and inventing either here would
            # be this helper answering a question only a listing can.
            "retained_absent": [
                {
                    "number": number,
                    "title": rows[str(number)]["title"],
                    "merged_at": rows[str(number)]["merged_at"],
                    "row_status": rows[str(number)]["status"],
                }
                for number in chosen["reconciliation"]["absent"]
            ],
        },
    }


# --------------------------------------------------------------------------
# The lease
#
# Design D-12 and D-17, issue #682. A claim is an expiring owner token on one
# row, taken before review effort is spent and renewed while the session that
# took it is alive. Four rules shape it, and each closes a way two owners, or
# no owner, could come out of an ordinary crash.
#
# * **One lock sequences every ledger write and the check it depends on.** The
#   lock is a Git reference created with `update-ref <ref> <new> ""`, which
#   refuses a reference that already exists, so exactly one invocation holds
#   it. It lives in the Git common directory, so every linked worktree of the
#   repository -- the docs worktree the ledger is in, and whichever worktree
#   the session runs from -- takes the same one. A fencing check made outside
#   it could be overtaken by a takeover before the mutation it approved.
# * **A dead lock holder is recovered, a live or unverifiable one never is.**
#   The lock records its holder's host and pid, which is what makes "gone"
#   decidable at all. A holder on this host whose pid no longer exists is
#   cleared by `update-ref -d <ref> <observed>`, which deletes only the exact
#   lock that was inspected, so a delayed recovery cannot remove the lock a
#   later invocation took meanwhile. A holder on another host, or a pid this
#   process may not signal, is refused naming the holder, and a live one is
#   waited on for a bounded time and then refused. A lease's expiry never
#   breaks a lock: the two are different resources.
# * **The ledger records the claim; a heartbeat record carries its expiry.**
#   The row's `claim` holds the token, the start and the effective settings,
#   written once when the claim is taken. The deadline a renewal extends is in
#   `<common dir>/kanban-project-review/leases/<token>.json`, replaced whole on
#   every renewal, so a heartbeat never rewrites the ledger or any other
#   publishable document. When that record is absent the deadline is the
#   claim's start plus its expiry; when it is present and unreadable, or names
#   another claim, every decision that needs the deadline refuses rather than
#   treating the claim as either live or expired.
# * **Renewal follows the session, not the application.** `claim` starts a
#   renewer -- this file, run again through `sys.executable` in a session of
#   its own with its standard streams on the null device -- that renews only
#   while a liveness signal the caller names is held: an inherited descriptor
#   whose writers the session holds open, or an owner process the invocation
#   names by pid. Neither is defaulted, and the inherited parent pid is never
#   one, because that is the long-lived application rather than the review
#   session (D-17). The renewer checks the signal at least once per renewal
#   interval, and exits without writing when it has been lost, when the claim
#   has expired, and when its token no longer owns the row.

DEFAULT_RENEWAL_SECONDS = 60
DEFAULT_EXPIRY_SECONDS = 15 * 60
LEASE_SETTING_KEYS = ("renewal_seconds", "expiry_seconds")
CLAIM_KEYS = ("token", "started_at", "renewal_seconds", "expiry_seconds")

TAKEOVER_KIND = "takeover"
TAKEOVER_KEYS = ("kind", "at", "previous_token", "token")

TOKEN_RE = re.compile(r"\A[0-9a-f]{32}\Z")

# A lease is timed below the second: a test runs one with a fraction of a
# second between renewals, and a start truncated to the second would move the
# deadline an absent heartbeat record falls back to by up to a second.
PRECISE_TIMESTAMP_RE = re.compile(
    r"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z\Z"
)
PRECISE_TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%S.%fZ"

LOCK_REF = "refs/kanban/project-review-lock"
LOCK_RECORD_KEYS = ("host", "pid", "nonce")
LOCK_WAIT_SECONDS = 10.0
LOCK_POLL_SECONDS = 0.02

RUNTIME_DIRECTORY = "kanban-project-review"
HEARTBEAT_KEYS = ("token", "repo", "pr", "deadline", "renewals", "renewer")
RENEWER_KEYS = ("host", "pid")

# The longest the renewer waits between two looks at its liveness signal. A
# production renewal interval is a minute; a released claim should not keep
# its renewer that long.
RENEWER_POLL_SECONDS = 1.0

# The environment variables that would point `git` at some repository other
# than the one `--root` is in.
GIT_LOCATION_VARIABLES = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE")


class LeaseRefused(LedgerError):
    """A lease operation this invocation may not perform, and who holds it.

    `reason` is one short word a caller can branch on; `owner` is what the
    refusal found in the way -- the claim's current token, or a lock holder's
    record -- and is part of the message too.
    """

    def __init__(self, reason: str, message: str, owner=None):
        suffix = "" if owner is None else f" Recorded owner: {json.dumps(owner, sort_keys=True)}."
        super().__init__(f"refused ({reason}): {message}{suffix}")
        self.reason = reason
        self.owner = owner


def precise_timestamp(instant: float) -> str:
    return datetime.fromtimestamp(instant, timezone.utc).strftime(PRECISE_TIMESTAMP_FORMAT)


def _precise_instant(value, source: str) -> float:
    if not isinstance(value, str) or not PRECISE_TIMESTAMP_RE.match(value):
        raise LedgerError(
            f"{source} holds {value!r}, which is not a UTC "
            "YYYY-MM-DDTHH:MM:SS.ffffffZ timestamp."
        )
    try:
        parsed = datetime.strptime(value, PRECISE_TIMESTAMP_FORMAT)
    except ValueError as error:
        raise LedgerError(f"{source} holds {value!r}, which is not a real date ({error}).") from error
    return parsed.replace(tzinfo=timezone.utc).timestamp()


def _validated_token(value, source: str) -> str:
    if not isinstance(value, str) or not TOKEN_RE.match(value):
        raise LedgerError(f"{source} holds {value!r}, which is not an owner token.")
    return value


def _validated_seconds(value, source: str):
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
        or value <= 0
    ):
        raise LedgerError(
            f"{source} holds {value!r}, which is not a positive number of seconds."
        )
    return value


def _validated_lease_settings(settings, source: str) -> dict:
    """A renewal interval and an expiry, and a pair that can actually renew.

    An expiry no longer than the renewal interval lapses between two
    renewals of a perfectly healthy session, so that pair is refused rather
    than recorded.
    """
    if not isinstance(settings, dict):
        raise LedgerError(f"{source} is not an object.")
    _require_keys(settings, LEASE_SETTING_KEYS, source)
    renewal = _validated_seconds(settings["renewal_seconds"], f"{source}: renewal_seconds")
    expiry = _validated_seconds(settings["expiry_seconds"], f"{source}: expiry_seconds")
    if expiry <= renewal:
        raise LedgerError(
            f"{source} renews every {renewal} seconds and expires after {expiry}; "
            "a lease that expires before its next renewal lapses while its "
            "session is alive."
        )
    return {"renewal_seconds": renewal, "expiry_seconds": expiry}


def _validated_claim(claim, source: str) -> dict:
    if not isinstance(claim, dict):
        raise LedgerError(f"{source} is not an object.")
    _require_keys(claim, CLAIM_KEYS, source)
    settings = _validated_lease_settings(
        {key: claim[key] for key in LEASE_SETTING_KEYS}, source
    )
    started = claim["started_at"]
    _precise_instant(started, f"{source}: started_at")
    return {
        "token": _validated_token(claim["token"], f"{source}: token"),
        "started_at": started,
        **settings,
    }


def _validated_takeover_entry(entry, source: str) -> dict:
    """A recorded change of owner: both tokens and the time, and nothing else.

    Self-contained like every other history entry: it names the token that
    lost the row as well as the one that took it, so it can be read after the
    claim it describes has been released and the row claimed again.
    """
    _require_keys(entry, TAKEOVER_KEYS, source)
    at = entry["at"]
    _precise_instant(at, f"{source}: at")
    previous = _validated_token(entry["previous_token"], f"{source}: previous_token")
    token = _validated_token(entry["token"], f"{source}: token")
    if previous == token:
        raise LedgerError(
            f"{source} records a takeover by the token it took over from; a "
            "takeover is a change of owner."
        )
    return {"kind": TAKEOVER_KIND, "at": at, "previous_token": previous, "token": token}


def effective_lease_settings(state: dict, renewal=None, expiry=None) -> dict:
    """The settings a new claim records: overrides, then the ledger, then D-17.

    Resolved once, when the claim is taken, and written into it. Nothing reads
    the defaults again for that claim, so a later change to them -- or a later
    invocation's overrides -- cannot reach a claim that already exists.
    """
    defaults = state["lease_defaults"] or {
        "renewal_seconds": DEFAULT_RENEWAL_SECONDS,
        "expiry_seconds": DEFAULT_EXPIRY_SECONDS,
    }
    return _validated_lease_settings(
        {
            "renewal_seconds": defaults["renewal_seconds"] if renewal is None else renewal,
            "expiry_seconds": defaults["expiry_seconds"] if expiry is None else expiry,
        },
        "the lease settings",
    )


# ---- Git and the runtime directory


def _git(root, arguments, input_bytes=None):
    environment = {
        name: value
        for name, value in os.environ.items()
        if name not in GIT_LOCATION_VARIABLES
    }
    try:
        return subprocess.run(
            ["git", *arguments],
            cwd=str(root),
            capture_output=True,
            input=input_bytes,
            env=environment,
        )
    except OSError as error:
        raise LedgerError(
            f"git could not be run in {root} ({error}); the lease's lock and "
            "heartbeat records live in that repository's Git common directory."
        ) from error


def _git_output(root, arguments, input_bytes=None) -> str:
    proc = _git(root, arguments, input_bytes)
    if proc.returncode != 0:
        detail = os.fsdecode(proc.stderr or proc.stdout).strip()
        raise LedgerError(f"git {' '.join(arguments)} failed in {root}: {detail}")
    return os.fsdecode(proc.stdout).strip()


def git_common_directory(root) -> Path:
    """Where this repository keeps what all of its worktrees share."""
    proc = _git(root, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
    if proc.returncode != 0:
        raise LedgerError(
            f"{root} is not inside a Git repository "
            f"({os.fsdecode(proc.stderr).strip()}); the lease's lock and "
            "heartbeat records live in that repository's Git common directory, "
            "so a root outside one cannot be claimed or selected under the lock."
        )
    return Path(os.fsdecode(proc.stdout).strip())


def heartbeat_path(common: Path, token: str) -> Path:
    return Path(common) / RUNTIME_DIRECTORY / "leases" / f"{token}.json"


def read_heartbeat(common: Path, token: str):
    """The heartbeat record for `token`, None when there is none, or a refusal."""
    path = heartbeat_path(common, token)
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except (OSError, UnicodeDecodeError) as error:
        raise LeaseRefused(
            "heartbeat-unreadable",
            f"the heartbeat record {path} could not be read ({error}), so this "
            "claim's deadline is unknown.",
        ) from error
    try:
        record = json.loads(raw, object_pairs_hook=_no_duplicate_keys)
        if not isinstance(record, dict):
            raise LedgerError(f"{path} is not an object.")
        _require_keys(record, HEARTBEAT_KEYS, str(path), "a heartbeat record")
        _validated_token(record["token"], f"{path}: token")
        if not REPO_RE.match(str(record["repo"])):
            raise LedgerError(f"{path}: repo is not an owner/name.")
        number = record["pr"]
        if isinstance(number, bool) or not isinstance(number, int) or number <= 0:
            raise LedgerError(f"{path}: pr is not a pull-request number.")
        _precise_instant(record["deadline"], f"{path}: deadline")
        renewals = record["renewals"]
        if isinstance(renewals, bool) or not isinstance(renewals, int) or renewals < 0:
            raise LedgerError(f"{path}: renewals is not a count.")
        renewer = record["renewer"]
        if renewer is not None:
            if not isinstance(renewer, dict):
                raise LedgerError(f"{path}: renewer is not an object.")
            _require_keys(renewer, RENEWER_KEYS, f"{path}: renewer", "a renewer record")
            pid = renewer["pid"]
            if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 1:
                raise LedgerError(f"{path}: renewer.pid is not a process id.")
    except (_DuplicateKey, ValueError, LedgerError) as error:
        raise LeaseRefused(
            "heartbeat-unreadable",
            f"the heartbeat record {path} is not one this helper can read "
            f"({error}), so this claim's deadline is unknown.",
        ) from error
    return record


def write_heartbeat(common: Path, record: dict) -> None:
    """Replace the record whole, so a reader never sees half of one."""
    path = heartbeat_path(common, record["token"])
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        handle, temporary = tempfile.mkstemp(dir=str(path.parent), prefix=".heartbeat-")
        try:
            with os.fdopen(handle, "w", encoding="utf-8") as stream:
                json.dump(record, stream, indent=2, sort_keys=True)
            os.replace(temporary, path)
        except BaseException:
            _discard(temporary)
            raise
    except OSError as error:
        raise LedgerError(
            f"the heartbeat record {path} could not be written ({error})."
        ) from error


def remove_heartbeat(common: Path, token: str) -> None:
    try:
        heartbeat_path(common, token).unlink()
    except FileNotFoundError:
        pass
    except OSError as error:
        raise LedgerError(
            f"the heartbeat record for {token} could not be removed ({error})."
        ) from error


def lease_deadline(common: Path, repo: str, number: int, claim: dict) -> float:
    """When `claim` expires, from the heartbeat record or from the claim itself.

    The record is authoritative when it exists, because it is what renewal
    extends. When it does not, the deadline is the one the claim was taken
    with: the start plus the claim's own expiry. A record that names another
    claim is refused rather than read, because a deadline taken from the wrong
    claim decides this one's fate on somebody else's heartbeat.
    """
    record = read_heartbeat(common, claim["token"])
    if record is None:
        return _precise_instant(claim["started_at"], "the claim's started_at") + claim["expiry_seconds"]
    if (record["token"], record["repo"], record["pr"]) != (claim["token"], repo, number):
        raise LeaseRefused(
            "heartbeat-mismatch",
            f"the heartbeat record for {claim['token']} names "
            f"{record['repo']}#{record['pr']} and token {record['token']}, not "
            f"{repo}#{number}, so this claim's deadline is unknown.",
            owner={"token": claim["token"]},
        )
    return _precise_instant(record["deadline"], "the heartbeat record's deadline")


# ---- The repository lock


_LOCK_BLOBS = {}


def _lock_blob(root) -> tuple:
    """This process's lock record, stored once as a Git blob.

    One record per process rather than per acquisition: the host, the pid and
    a nonce identify the process, and a process that is gone never takes the
    lock again, so the blob a recovery observed cannot come back as somebody
    else's lock. Writing it once also keeps a renewer from adding a loose
    object to the repository every renewal.
    """
    common = git_common_directory(root)
    key = str(common)
    if key not in _LOCK_BLOBS:
        record = {"host": socket.gethostname(), "pid": os.getpid(), "nonce": secrets.token_hex(16)}
        blob = _git_output(
            root,
            ["hash-object", "-w", "--stdin"],
            json.dumps(record, sort_keys=True).encode("utf-8"),
        )
        _LOCK_BLOBS[key] = (os.getpid(), blob, record)
    pid, blob, record = _LOCK_BLOBS[key]
    if pid != os.getpid():
        del _LOCK_BLOBS[key]
        return _lock_blob(root)
    return common, blob, record


def observed_lock(root):
    """The object the lock reference holds right now, or None when unheld."""
    proc = _git(root, ["rev-parse", "--verify", "--quiet", LOCK_REF])
    value = os.fsdecode(proc.stdout).strip()
    return value if proc.returncode == 0 and value else None


def lock_holder(root, observed: str) -> dict:
    """The holder the observed lock records, or a refusal naming what is there."""
    proc = _git(root, ["cat-file", "blob", observed])
    raw = os.fsdecode(proc.stdout)
    try:
        if proc.returncode != 0:
            raise ValueError(os.fsdecode(proc.stderr).strip())
        holder = json.loads(raw, object_pairs_hook=_no_duplicate_keys)
        if not isinstance(holder, dict) or set(holder) != set(LOCK_RECORD_KEYS):
            raise ValueError("not a lock record")
        pid = holder["pid"]
        if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 1:
            raise ValueError("no process id")
        if not isinstance(holder["host"], str):
            raise ValueError("no host")
    except (_DuplicateKey, ValueError) as error:
        raise LeaseRefused(
            "lock-unreadable",
            f"{LOCK_REF} holds {observed}, whose holder record cannot be read "
            f"({error}); a holder nothing can identify is never cleared.",
            owner={"object": observed, "record": raw[:200]},
        ) from error
    return holder


def holder_standing(holder: dict) -> str:
    """`gone`, `live`, or `unverifiable`, and only `gone` may be cleared.

    A holder on another host cannot be looked up from here, and a pid this
    process may not signal exists but cannot be examined; both are
    unverifiable rather than dead (the rule `clear_stale_lock` in
    `publish_coordination_doc.py` applies).
    """
    if holder["host"] != socket.gethostname():
        return "unverifiable"
    try:
        os.kill(holder["pid"], 0)
    except ProcessLookupError:
        return "gone"
    except PermissionError:
        return "unverifiable"
    except OSError:
        return "unverifiable"
    return "live"


def clear_dead_lock(root, observed: str) -> bool:
    """Delete the lock only if it is still exactly the one that was inspected.

    A recovery that decided a holder was gone and then stalled must not
    delete whatever lock exists when it resumes; `update-ref -d <ref> <old>`
    deletes nothing unless the reference still holds `<old>`.
    """
    return _git(root, ["update-ref", "-d", LOCK_REF, observed]).returncode == 0


@contextlib.contextmanager
def repository_lock(root, wait: float = None):
    """Hold the repository's helper lock for the body, yielding the common dir."""
    wait = LOCK_WAIT_SECONDS if wait is None else wait
    common, blob, _ = _lock_blob(root)
    give_up = time.monotonic() + wait
    while True:
        proc = _git(root, ["update-ref", LOCK_REF, blob, ""])
        if proc.returncode == 0:
            break
        observed = observed_lock(root)
        if observed is None:
            if time.monotonic() >= give_up:
                raise LedgerError(
                    f"{LOCK_REF} could not be created and is not held "
                    f"({os.fsdecode(proc.stderr).strip()})."
                )
            time.sleep(LOCK_POLL_SECONDS)
            continue
        holder = lock_holder(root, observed)
        standing = holder_standing(holder)
        if standing == "gone":
            clear_dead_lock(root, observed)
            continue
        if standing == "unverifiable":
            raise LeaseRefused(
                "lock-unverifiable",
                f"{LOCK_REF} is held by pid {holder['pid']} on "
                f"{holder['host']!r}, which cannot be checked from here; it is "
                "left in place.",
                owner=holder,
            )
        if time.monotonic() >= give_up:
            raise LeaseRefused(
                "lock-busy",
                f"{LOCK_REF} is held by live pid {holder['pid']} and was not "
                f"released within {wait} seconds.",
                owner=holder,
            )
        time.sleep(LOCK_POLL_SECONDS)
    try:
        yield common
    finally:
        clear_dead_lock(root, blob)


# ---- Fencing


def _refusal_for(row, number: int, token: str, repo: str):
    """Why `token` does not own row `number`, or None when it does."""
    claim = None if row is None else row["claim"]
    if claim is not None and claim["token"] == token:
        return None
    current = None if claim is None else {"token": claim["token"]}
    replaced = row is not None and any(
        entry["kind"] == TAKEOVER_KIND and entry["previous_token"] == token
        for entry in row["history"]
    )
    if replaced:
        return LeaseRefused(
            "replaced",
            f"{token} was taken over on {repo}#{number} and no longer owns it.",
            owner=current,
        )
    if claim is None:
        return LeaseRefused(
            "unclaimed", f"{repo}#{number} carries no claim for {token} to present."
        )
    return LeaseRefused(
        "not-owner", f"{token} does not own the claim on {repo}#{number}.", owner=current
    )


@contextlib.contextmanager
def fenced(root, repo: str, number: int, token: str, lock_wait: float = None):
    """Hold the lock and prove `token` is the current, unexpired owner.

    The one fencing check every protected mutation goes through. It yields
    only while the lock is held, so the mutation the body performs and the
    ownership it was approved on cannot be separated by a takeover: nothing
    can change the owner until the body has finished.

    It yields the parsed document, that repository's state, the row, the
    claim, its deadline and its heartbeat record, so the body mutates exactly
    what was validated rather than something it read again.
    """
    if not REPO_RE.match(str(repo)):
        raise LedgerError(f"{repo!r} is not an owner/name repository identity.")
    _validated_token(token, "the presented token")
    with repository_lock(root, lock_wait) as common:
        document = load_document(root)
        state = state_for(document, repo)
        row = state["rows"].get(str(number))
        refusal = _refusal_for(row, number, token, repo)
        if refusal is not None:
            raise refusal
        claim = row["claim"]
        deadline = lease_deadline(common, repo, number, claim)
        now = time.time()
        if now >= deadline:
            raise LeaseRefused(
                "expired",
                f"the claim on {repo}#{number} expired at "
                f"{precise_timestamp(deadline)} and may only be taken over.",
                owner={"token": claim["token"], "deadline": precise_timestamp(deadline)},
            )
        yield {
            "common": common,
            "document": document,
            "state": state,
            "row": row,
            "claim": claim,
            "deadline": deadline,
            "heartbeat": read_heartbeat(common, token),
            "now": now,
        }


def fence(root, repo: str, number: int, token: str, lock_wait: float = None) -> dict:
    with fenced(root, repo, number, token, lock_wait) as held:
        return {
            "status": "owner",
            "repo": repo,
            "pr": number,
            "token": token,
            "deadline": precise_timestamp(held["deadline"]),
        }


def renew(
    root, repo: str, number: int, token: str, lock_wait: float = None, renewer=None
) -> dict:
    """Extend the current owner's deadline by its own expiry, and nothing else.

    The ledger is not written: the new deadline goes into the heartbeat
    record, and the claim's settings are the ones it was taken with. A record
    that has gone missing is written afresh, naming `renewer` when the
    renewer itself is the caller.
    """
    with fenced(root, repo, number, token, lock_wait) as held:
        previous = held["heartbeat"]
        deadline = held["now"] + held["claim"]["expiry_seconds"]
        write_heartbeat(
            held["common"],
            {
                "token": token,
                "repo": repo,
                "pr": number,
                "deadline": precise_timestamp(deadline),
                "renewals": 0 if previous is None else previous["renewals"] + 1,
                "renewer": renewer if previous is None else previous["renewer"],
            },
        )
        return {
            "status": "renewed",
            "repo": repo,
            "pr": number,
            "token": token,
            "deadline": precise_timestamp(deadline),
        }


def release(root, repo: str, number: int, token: str, lock_wait: float = None) -> dict:
    """End the current owner's claim: the row's claim and its heartbeat go.

    Its renewer stops because the heartbeat record it renews has gone, which
    it looks for between renewals and answers with a renewal the fencing
    check now refuses; it is never signalled by pid, because a pid this
    invocation did not start may by now be somebody else's process.
    """
    with fenced(root, repo, number, token, lock_wait) as held:
        document, state = held["document"], held["state"]
        state["rows"][str(number)]["claim"] = None
        document["repositories"][repo] = _validated_repository(
            state, f"the ledger released for {repo}"
        )
        written = publish_document(root, document)
        remove_heartbeat(held["common"], token)
        renewer = None if held["heartbeat"] is None else held["heartbeat"]["renewer"]
        return {
            "status": "released",
            "repo": repo,
            "pr": number,
            "token": token,
            "document": str(written),
            "renewer": renewer,
        }


def set_lease_defaults(root, repo: str, renewal, expiry, lock_wait: float = None) -> dict:
    """Record this repository's lease defaults for claims taken from now on."""
    settings = _validated_lease_settings(
        {"renewal_seconds": renewal, "expiry_seconds": expiry}, "the lease defaults"
    )
    if not REPO_RE.match(str(repo)):
        raise LedgerError(f"{repo!r} is not an owner/name repository identity.")
    with repository_lock(root, lock_wait):
        document = load_document(root)
        if repo not in document["repositories"]:
            raise LedgerError(
                f"{document_path(root)} holds no entry for {repo}; migrate it first."
            )
        state = state_for(document, repo)
        state["lease_defaults"] = settings
        document["repositories"][repo] = _validated_repository(
            state, f"the ledger written for {repo}"
        )
        written = publish_document(root, document)
    return {"status": "defaults-set", "repo": repo, "document": str(written), **settings}


# ---- Liveness


def liveness_source(liveness_fd=None, owner_pid=None) -> dict:
    """The one signal a claim's renewal follows, checked before anything is written.

    Exactly one is required. A claim with neither would be renewed by nothing
    the session controls, and the parent pid is not a fallback: that is the
    application process, which outlives every review it runs (D-17).
    """
    if (liveness_fd is None) == (owner_pid is None):
        raise LeaseRefused(
            "liveness-required",
            "a claim names exactly one liveness signal, --liveness-fd or "
            "--owner-pid; renewal follows the review session's own lifetime and "
            "is never inferred from the invoking process.",
        )
    if liveness_fd is not None:
        _require_live_descriptor(liveness_fd)
        return {"kind": "descriptor", "fd": liveness_fd}
    if isinstance(owner_pid, bool) or not isinstance(owner_pid, int) or owner_pid <= 1:
        raise LeaseRefused("liveness-invalid", f"{owner_pid!r} is not an owner process id.")
    if owner_pid == os.getpid():
        raise LeaseRefused(
            "liveness-invalid",
            "the owner process is this short-lived helper invocation, which "
            "exits as soon as the claim is recorded.",
        )
    standing = holder_standing({"host": socket.gethostname(), "pid": owner_pid})
    if standing == "gone":
        raise LeaseRefused("liveness-lost", f"owner process {owner_pid} is not running.")
    if standing == "unverifiable":
        raise LeaseRefused(
            "liveness-unverifiable",
            f"owner process {owner_pid} cannot be examined from here, so its "
            "exit could never be observed.",
        )
    return {"kind": "process", "pid": owner_pid}


def _require_live_descriptor(fd) -> None:
    """A descriptor whose closure is observable: a pipe's or socket's read side.

    Readable end-of-file is the signal. A regular file never reaches it by
    anyone closing anything, and a pipe's write end is never readable at all,
    so either would renew forever; both are refused. The standard streams are
    refused too, because the renewer's are the null device.
    """
    if isinstance(fd, bool) or not isinstance(fd, int) or fd < 3:
        raise LeaseRefused(
            "liveness-invalid",
            f"{fd!r} is not a descriptor a renewer can inherit; the standard "
            "streams are not liveness signals.",
        )
    try:
        mode = os.fstat(fd).st_mode
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    except OSError as error:
        raise LeaseRefused("liveness-invalid", f"descriptor {fd} is not open ({error}).") from error
    if stat.S_ISFIFO(mode):
        if flags & os.O_ACCMODE != os.O_RDONLY:
            raise LeaseRefused(
                "liveness-invalid",
                f"descriptor {fd} is not the read side of a pipe, so its "
                "writers closing it would never be seen.",
            )
    elif not stat.S_ISSOCK(mode):
        raise LeaseRefused(
            "liveness-invalid",
            f"descriptor {fd} is neither a pipe nor a socket, so nothing closing "
            "it can be observed.",
        )
    if _descriptor_closed(fd, 0):
        raise LeaseRefused(
            "liveness-lost", f"descriptor {fd} is already closed by every writer."
        )


def _descriptor_closed(fd: int, timeout: float) -> bool:
    """True once every writer has closed `fd`; bytes written into it are ignored."""
    try:
        ready, _, _ = wait_readable([fd], [], [], timeout)
        if not ready:
            return False
        return os.read(fd, 65536) == b""
    except OSError:
        return True


def _signal_lost(source: dict, timeout: float) -> bool:
    """Wait up to `timeout` for the signal to be lost, and say whether it was."""
    if source["kind"] == "descriptor":
        return _descriptor_closed(source["fd"], timeout)
    time.sleep(timeout)
    return holder_standing({"host": socket.gethostname(), "pid": source["pid"]}) != "live"


# ---- Claiming and the renewer


HELPER_PATH = Path(__file__).resolve()


def claim(
    root,
    repo: str,
    inventory,
    liveness_fd=None,
    owner_pid=None,
    renewal=None,
    expiry=None,
    lock_wait: float = None,
) -> dict:
    """Select under the lock, claim or take over the pick, and start its renewer.

    The liveness signal and the listing are checked before the lock is taken,
    so an invocation that could never renew records nothing. Under the lock
    the ledger is read afresh, live claims are skipped in queue order, and the
    first unheld row is claimed; when that row's claim has expired it is taken
    over, and the row's history gains one entry naming both tokens and the
    time.

    The renewer is started before the claim is published, and is stopped
    again when publishing fails. It needs no ordering beyond that: it waits
    for the lock this invocation holds, and when it gets it, it renews only a
    claim the ledger says its token owns.
    """
    source = liveness_source(liveness_fd, owner_pid)
    for value, name in ((renewal, "--renewal"), (expiry, "--expiry")):
        if value is not None:
            _validated_seconds(value, name)
    listing = _listing_for(repo, inventory)
    if not sys.executable:
        raise LedgerError(
            "this Python cannot name its own interpreter, so it cannot start the "
            "renewer a claim needs."
        )
    with repository_lock(root, lock_wait) as common:
        now = time.time()
        chosen = _choose(root, repo, listing, common, now)
        pick = chosen["pick"]
        if pick is None:
            if chosen["skipped"]:
                return dict(_selection_result("all-claimed", chosen, repo, None), claim=None, takeover=None)
            written = _publish_reconciled(root, repo, chosen)
            return dict(
                _selection_result("no-selectable-row", chosen, repo, written),
                claim=None,
                takeover=None,
            )
        number = pick["number"]
        state = chosen["state"]
        settings = effective_lease_settings(state, renewal, expiry)
        token = secrets.token_hex(16)
        row = state["rows"][str(number)]
        previous = row["claim"]
        if previous is not None:
            row["history"].append(
                {
                    "kind": TAKEOVER_KIND,
                    "at": precise_timestamp(now),
                    "previous_token": previous["token"],
                    "token": token,
                }
            )
        row["claim"] = {"token": token, "started_at": precise_timestamp(now), **settings}
        deadline = now + settings["expiry_seconds"]
        renewer = _start_renewer(root, repo, number, token, source)
        try:
            write_heartbeat(
                common,
                {
                    "token": token,
                    "repo": repo,
                    "pr": number,
                    "deadline": precise_timestamp(deadline),
                    "renewals": 0,
                    "renewer": {"host": socket.gethostname(), "pid": renewer.pid},
                },
            )
            written = _publish_reconciled(root, repo, chosen)
        except BaseException:
            _stop_started_renewer(renewer)
            remove_heartbeat(common, token)
            raise
        if previous is not None:
            remove_heartbeat(common, previous["token"])
        result = _selection_result("claimed", chosen, repo, written)
        result["claim"] = dict(
            row["claim"],
            deadline=precise_timestamp(deadline),
            renewer={"host": socket.gethostname(), "pid": renewer.pid},
            liveness=source["kind"],
        )
        result["takeover"] = (
            None if previous is None else {"previous_token": previous["token"]}
        )
        return result


def _start_renewer(root, repo: str, number: int, token: str, source: dict):
    """The renewer, detached from everything but the signal it follows.

    A session of its own, so the terminal's signals to this invocation's
    process group do not reach it; the null device for all three standard
    streams, so a caller capturing this invocation's output sees it end when
    this invocation does; and no inherited descriptor but the liveness one.
    """
    if source["kind"] == "descriptor":
        signal_arguments = ["--liveness-fd", str(source["fd"])]
        inherited = (source["fd"],)
    else:
        signal_arguments = ["--owner-pid", str(source["pid"])]
        inherited = ()
    try:
        return subprocess.Popen(
            [
                sys.executable,
                str(HELPER_PATH),
                "renewer",
                "--root",
                str(Path(root).resolve()),
                "--repo",
                repo,
                "--pr",
                str(number),
                "--token",
                token,
                *signal_arguments,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            pass_fds=inherited,
            close_fds=True,
            start_new_session=True,
            cwd="/",
        )
    except OSError as error:
        raise LedgerError(f"the renewer could not be started ({error}).") from error


def _stop_started_renewer(renewer) -> None:
    try:
        renewer.terminate()
        renewer.wait(timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        with contextlib.suppress(OSError):
            renewer.kill()


class _Stopped(Exception):
    pass


def _stop_on_signal(signum, frame):
    raise _Stopped()


def run_renewer(root, repo: str, number: int, token: str, source: dict) -> str:
    """Renew `token`'s claim until the signal is lost or the claim is not its own.

    Returns why it stopped. Every stop writes nothing: a lost signal leaves the
    last heartbeat to lapse on its own, an expired claim is left for takeover,
    and a claim released or taken over has had its heartbeat removed by the
    invocation that did so. A renewer removes no ledger claim, no lock it
    does not hold, and no heartbeat record at all.

    A heartbeat record that disappears is not taken as a release on its own
    say-so: it brings the next renewal forward, and that renewal's fencing
    check decides. A release or a takeover refuses it, and the renewer stops
    at once; a record removed from under a claim its token still owns is
    written again.
    """
    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(signum, _stop_on_signal)
    try:
        with repository_lock(root) as common:
            document = load_document(root)
            row = state_for(document, repo)["rows"].get(str(number))
            if _refusal_for(row, number, token, repo) is not None:
                return "not-owner"
            renewal = row["claim"]["renewal_seconds"]
        record = heartbeat_path(common, token)
        identity = {"host": socket.gethostname(), "pid": os.getpid()}
        poll = min(renewal, RENEWER_POLL_SECONDS)
        due = time.monotonic() + renewal
        while True:
            if _signal_lost(source, max(0.0, min(poll, due - time.monotonic()))):
                return "signal-lost"
            if time.monotonic() < due and os.path.lexists(record):
                continue
            try:
                renew(root, repo, number, token, renewer=identity)
            except LeaseRefused as refusal:
                if refusal.reason.startswith("lock-"):
                    # Not this claim's fate: try again at the next look, and
                    # let the claim lapse if the lock never comes back.
                    due = time.monotonic() + poll
                    continue
                return refusal.reason
            due = time.monotonic() + renewal
    except _Stopped:
        return "signalled"
    except LedgerError:
        return "refused"


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
        if not DECIMAL_RE.fullmatch(stripped) or int(stripped) <= 0:
            raise LedgerError(f"{token!r} is not a pull-request number.")
        numbers.append(int(stripped))
    return path, numbers


def read_inventory(stream=None) -> dict:
    """The merged-pull-request listing, read from standard input.

    Standard input and nothing else. A `--inventory <path>` would be the
    obvious convenience and it would also be the one thing that takes this
    module outside the reach it declares: every repository document it opens
    is under the `--root` it was given, and a path flag is a read of whatever the
    caller names. The listing is the caller's own `gh` output, so the caller
    already has it in hand.
    """
    stream = sys.stdin if stream is None else stream
    text = stream.read()
    if not text.strip():
        raise LedgerError(
            "no merged-pull-request listing arrived on standard input; "
            "`select` records the listing as this repository's known universe, "
            "and an empty input is not an empty repository."
        )
    try:
        return json.loads(text, object_pairs_hook=_no_duplicate_keys)
    except _DuplicateKey as error:
        raise LedgerError(
            f"the merged-pull-request listing names {error.key!r} more than "
            "once in one object; a listing that repeats a key states two "
            "values for it and a reader that took one would be choosing "
            "without saying so."
        ) from error
    except ValueError as error:
        raise LedgerError(
            f"the merged-pull-request listing is not readable JSON ({error})."
        ) from error


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
    selector = subparsers.add_parser(
        "select",
        help=(
            "record a complete merged-pull-request listing from standard input "
            "and choose the one pull request to review next"
        ),
    )
    selector.add_argument("--root", required=True)
    selector.add_argument("--repo", required=True)

    claimer = subparsers.add_parser(
        "claim",
        help=(
            "select as `select` does, skipping live claims, then claim or take "
            "over the pick and start its renewer"
        ),
    )
    claimer.add_argument("--root", required=True)
    claimer.add_argument("--repo", required=True)
    _add_liveness_arguments(claimer)
    claimer.add_argument(
        "--renewal", type=float, help="seconds between renewals, for this claim only"
    )
    claimer.add_argument(
        "--expiry", type=float, help="seconds a renewal extends the lease by, for this claim only"
    )

    for name, text in (
        ("renew", "extend the current owner's lease by its own expiry"),
        ("release", "end the current owner's claim"),
        ("fence", "succeed only for the current, unexpired owner"),
    ):
        command = subparsers.add_parser(name, help=text)
        _add_claim_identity_arguments(command)

    defaults = subparsers.add_parser(
        "lease-defaults", help="set this repository's lease defaults for later claims"
    )
    defaults.add_argument("--root", required=True)
    defaults.add_argument("--repo", required=True)
    defaults.add_argument("--renewal", type=float, required=True)
    defaults.add_argument("--expiry", type=float, required=True)

    renewer = subparsers.add_parser("renewer", help=argparse.SUPPRESS)
    _add_claim_identity_arguments(renewer)
    _add_liveness_arguments(renewer)
    return parser


def _add_claim_identity_arguments(command) -> None:
    command.add_argument("--root", required=True)
    command.add_argument("--repo", required=True)
    command.add_argument("--pr", type=int, required=True)
    command.add_argument("--token", required=True)


def _add_liveness_arguments(command) -> None:
    command.add_argument(
        "--liveness-fd",
        type=int,
        help="an inherited pipe or socket descriptor whose closure ends renewal",
    )
    command.add_argument(
        "--owner-pid",
        type=int,
        help="a process, named explicitly, whose exit ends renewal",
    )


def main(argv=None) -> int:
    """0 migrated, read, selected or a lease operation done, 3 flagged, 2 refused.

    Three outcomes rather than two because a flagged migration is neither: it
    read every report successfully and is waiting for a decision only the
    operator can make, and a caller that saw it as a refusal would retry it
    unchanged forever.

    A selection that finds nothing to review is a fourth thing again, and it
    is not an outcome of its own: `no-selectable-row` is a successful run over
    a repository whose every merged pull request is excluded or unlisted, so
    it exits 0 and says so in the payload. A caller parses this command's
    standard output only when it exits 0, and only a refusal writes to
    standard error. So is `all-claimed`, a claim or selection over a repository
    whose every selectable pull request somebody holds a live claim on: it
    exits 0, writes nothing, and names each holder.

    A lease refusal -- an expired, replaced or unknown token, a liveness
    signal that is missing or already lost, an unreadable heartbeat, a lock
    held by a live or unverifiable holder -- is a refusal like any other: exit
    2, with its reason word and the recorded owner on standard error.
    """
    args = build_parser().parse_args(argv)
    if args.command == "read":
        document = load_document(args.root)
        if args.repo:
            return _emit(
                {"status": "read", "repo": args.repo, "state": state_for(document, args.repo)}
            )
        return _emit({"status": "read", "document": document})

    if args.command == "select":
        return _emit(select(args.root, args.repo, read_inventory()))

    if args.command == "claim":
        # The signal is checked before standard input is read, so a claim that
        # could never renew does not first consume the caller's listing.
        liveness_source(args.liveness_fd, args.owner_pid)
        return _emit(
            claim(
                args.root,
                args.repo,
                read_inventory(),
                liveness_fd=args.liveness_fd,
                owner_pid=args.owner_pid,
                renewal=args.renewal,
                expiry=args.expiry,
            )
        )

    if args.command in ("renew", "release", "fence"):
        operation = {"renew": renew, "release": release, "fence": fence}[args.command]
        return _emit(operation(args.root, args.repo, args.pr, args.token))

    if args.command == "lease-defaults":
        return _emit(set_lease_defaults(args.root, args.repo, args.renewal, args.expiry))

    if args.command == "renewer":
        run_renewer(
            args.root,
            args.repo,
            args.pr,
            args.token,
            liveness_source(args.liveness_fd, args.owner_pid),
        )
        return 0

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
