"""The bundled project-review ledger's schema, renderer, and migration.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 tools/test_project_review_ledger.py

Issue #680, slice LEDGER-2 of `docs/project_review_ledger_design.md`. The
module under test ships in both bundles and nothing invokes it yet: design
D-19 keeps the installed `project-review` command on the v2 cursor until
LEDGER-6 switches it over, so until then these tests are the module's only
caller. That makes them the whole of its contract rather than a sample of it,
and three properties follow.

* **Fixtures are produced by the mechanism they stand in for.** Every v2
  cursor here is written by `project_review_cursor.py`'s own `record` and
  `write_document`, so a cursor shape this migration cannot read is a cursor
  shape that mechanism cannot write. A v1 cursor is that same recorded payload
  with only its two version tokens rewritten, because v1 and v2 differ in what
  `pr.endpoint` *means* rather than in how it is spelled, and no code in this
  repository writes one any more. The hand-authored boundary document is
  inline text for the same reason turned the other way: nothing ever wrote it
  mechanically, so its shape is exactly the prose a human typed.
* **Reports are inline.** The tracked `docs/project_review_*.md` reports are
  excluded from the source distribution, so a test that read them would pass
  in a checkout and error in an unpacked release. The paragraphs below are
  reproduced from the real reports' shapes -- an annotated list, a cursor
  named before the enumeration, a separately skipped batch, an enumeration
  reaching above its own filename interval -- rather than invented, because
  the parser's whole job is reading prose that already exists.
* **Coverage is asserted as a set, and so is its absence.** Importing too much
  invents review history that no one performed; importing too little
  schedules a re-review of work that was done. Both are silent, so every
  migration assertion below pins the exact row set, and the numbers a
  paragraph names for other reasons -- a cursor, a stop, a skipped batch, a
  report filename -- are pinned as absent rather than left unmentioned.
* **The template sets are pinned closed from both sides.** `SCOPE_TEMPLATES`
  says which sentences introduce a batch, `MENTION_TEMPLATES` which name a
  pull request for some other reason, and `PROSE_TEMPLATES` which name none,
  and each is asserted twice over: every template the module ships must parse
  when filled in, and every wording this pull request's reviews have produced
  -- each admitted by some earlier rule, each of which lost or invented a pull
  request -- must flag. A set that grew back
  toward accepting anything fails the second half; one narrowed into
  uselessness fails the first. Report fixtures are tracked templates filled
  in for the same reason: a fixture in an invented wording would test the
  refusal rather than the reading.

The refusals get the same treatment. A ledger that cannot be parsed is the
one state in which every later invocation must stop, so each malformed shape
is asserted to raise *and* to name what stopped it: a refusal whose message
did not identify the field would leave an operator editing the document by
guesswork, which is how the cursor's own predecessor lost a batch.
"""

from __future__ import annotations

import importlib.util
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

CLAUDE_LEDGER_HELPER = "claude-plugin/plugins/kanban/scripts/project_review_ledger.py"
CODEX_LEDGER_HELPER = (
    "codex-plugin/plugins/kanban/skills/project-review/scripts/"
    "project_review_ledger.py"
)
LEDGER_HELPERS = {"claude": CLAUDE_LEDGER_HELPER, "codex": CODEX_LEDGER_HELPER}

CLAUDE_ASSET = "claude-plugin/plugins/kanban/commands/project-review.md"
CODEX_ASSET = "codex-plugin/plugins/kanban/skills/project-review/SKILL.md"
RENDERED_ASSETS = (CLAUDE_ASSET, CODEX_ASSET)

BUNDLE_ROOTS = ("claude-plugin", "codex-plugin")

REPO = "coghex/kanban"
OTHER_REPO = "coghex/synarchy"

# A merged history whose number order is deliberately not its merge order, for
# the reason docs/project_review_466-399.md records: #571 merged before #569,
# so a batch that reviewed both enumerates them out of numeric order and a
# ledger keyed by number has to survive that.
PR_HISTORY = (
    (612, "2026-09-05T00:00:00Z"),
    (610, "2026-09-04T00:00:00Z"),
    (602, "2026-09-03T00:00:00Z"),
    (601, "2026-09-02T00:00:00Z"),
    (569, "2026-09-01T00:00:00Z"),
    (571, "2026-08-31T00:00:00Z"),
    (570, "2026-08-30T00:00:00Z"),
    (550, "2026-08-29T00:00:00Z"),
    (545, "2026-08-28T00:00:00Z"),
    (533, "2026-08-27T00:00:00Z"),
    (520, "2026-08-26T00:00:00Z"),
    (517, "2026-08-25T00:00:00Z"),
    (500, "2026-08-24T00:00:00Z"),
    (444, "2026-08-23T00:00:00Z"),
    (442, "2026-08-22T00:00:00Z"),
    (432, "2026-08-21T00:00:00Z"),
    (431, "2026-08-20T00:00:00Z"),
    (412, "2026-08-19T00:00:00Z"),
)

DIRECT_HISTORY = (
    "5f0a8f0c1f2e3d4c5b6a798877665544332211aa",
    "4e0a8f0c1f2e3d4c5b6a798877665544332211bb",
    "3d0a8f0c1f2e3d4c5b6a798877665544332211cc",
)

FULL_SHA = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
OTHER_SHA = "b1b2c3d4e5f60718293a4b5c6d7e8f9012345679"


def load_ledger_helper(brand: str):
    """The bundled helper, imported from the copy `brand` actually ships.

    Loaded by path under a private name because it is a bundled asset rather
    than an importable package: `tools/` is not its home, and giving it one
    would make these tests pass against a module the workflow never reaches.
    """
    path = REPO_ROOT / LEDGER_HELPERS[brand]
    spec = importlib.util.spec_from_file_location(
        f"kanban_{brand}_plugin_project_review_ledger", path
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


LEDGER_MODULES = {brand: load_ledger_helper(brand) for brand in LEDGER_HELPERS}
LEDGER = LEDGER_MODULES["claude"]
# Resolved through the module's own sibling loader, so the loader that the
# installed copy depends on is exercised rather than reimplemented here.
CURSOR = LEDGER.cursor_module()


# --------------------------------------------------------------------------
# Fixtures


def write_report(root, name: str, body: str) -> str:
    path = Path(root) / "docs" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    return f"docs/{name}"


def pr_candidates(history=PR_HISTORY):
    return CURSOR.normalize_candidates(
        "pr", [{"number": number, "mergedAt": merged_at} for number, merged_at in history]
    )


def record_cursor(
    root,
    repo=REPO,
    *,
    reviewed=(),
    boundary=None,
    excluded=(),
    direct_reviewed=(),
):
    """A v2 cursor written by the cursor module's own record and writer."""
    document = CURSOR.load_document(root)
    state = CURSOR.state_for(document, repo)
    if reviewed or excluded or boundary is not None:
        state = CURSOR.record(
            state,
            "pr",
            pr_candidates(),
            list(reviewed),
            list(excluded),
            boundary=boundary,
        )
    if direct_reviewed:
        state = CURSOR.record(
            state,
            "direct",
            CURSOR.normalize_candidates("direct", list(DIRECT_HISTORY)),
            list(direct_reviewed),
        )
    document.setdefault("repositories", {})[repo] = state
    CURSOR.write_document(root, document)
    return state


def downgrade_cursor_to_v1(root):
    """The recorded payload, re-marked as the released version-1 document.

    Version 1 spelled the same payload and differed only in what `pr.endpoint`
    meant -- a resume-below frontier that had itself been reviewed, rather than
    an exclusive stop. Nothing writes one any more, so re-marking a recorded v2
    payload is the only way to produce one that is not hand-invented.
    """
    path = CURSOR.document_path(root)
    text = path.read_text(encoding="utf-8")
    text = text.replace(CURSOR.CURSOR_MARKER, CURSOR.LEGACY_CURSOR_MARKER)
    text = text.replace('"version": 2', '"version": 1')
    path.write_text(text, encoding="utf-8")


HAND_AUTHORED_CURSOR = """# Project review boundaries

- `coghex/kanban` — stop before PR #533
  PR #550 was reviewed above the stop as an exception.
"""

HAND_AUTHORED_BARE_STOP = """# Project review boundaries

- `coghex/kanban` — stop before PR #533
"""

# Every report fixture below is a tracked template with its numbers, counts
# and dates filled in. It has to be: a sentence naming a pull request is read
# by matching one of those templates whole, so a fixture in some invented
# wording would test the refusal rather than the reading.

# docs/project_review_183-170.md's shape: a cursor named in the scope sentence,
# and a finding section naming a pull request for its own reasons.
CURSOR_NAMING_REPORT = """# Project Review Findings: PRs #602–#569

This review continued below the completed #610 cursor and covered the next
three merged pull requests by merge time: #602, #601, and #569. There were no
direct first-parent commits interleaved between #610 and #569.

## Finding PRR-1

Something about #612 that is not coverage of it.
"""

# docs/project_review_561-545.md's shape: the user's exclusive stop is named
# inside the scope sentence itself, and again in the sentence after it.
STOP_NAMING_REPORT = """# Project Review Findings: PRs #550–#545

This bounded review covered every eligible merged pull request remaining above
the user's exclusive stop at #533, in merge-time order: #550 and #545. The
bound therefore produced two pull requests rather than the requested twelve; no
pull request numbered #533 or lower was entered.
"""

# Synarchy's docs/project_review_432-412.md: the enumeration reaches above its
# own filename interval because number order and merge order differ.
ABOVE_INTERVAL_REPORT = """# Project Review Findings: PRs #432–#412

This review continued below the completed #446 cursor and covered the next five
merged pull requests by merge time: #432, #442, #444, #431, and #412.
"""

# docs/project_review_463-455.md: every enumerated pull request carries a
# parenthesised annotation, and one annotation names a file.
ANNOTATED_REPORT = """# Project Review Findings: PRs #571–#570

A senior review of the two merged pull requests that landed after the batch
`docs/project_review_602-562.md` covered, taken newest-first over
`coghex/kanban`: #571 (per-entry witnesses for `docs/design.md` §3 and §20),
and #570 (the issue templates).
"""

# docs/project_review_398-353.md: a reviewed enumeration followed by a
# separately named batch that was explicitly skipped.
SKIPPED_BATCH_REPORT = """# Project Review Findings: PRs #520–#517

This review continued below the completed #533 cursor and covered the next two
genuinely unreviewed merged pull requests in merge-time order: #520 and #517.
The previously reported #550 and #545 batch was explicitly skipped rather than
reviewed again.
"""

OVERLAPPING_REPORT = """# Project Review Findings: PRs #520–#500

This review continued below the completed #533 cursor and covered the next two
merged pull requests by merge time: #520 and #500.
"""

AMBIGUOUS_TWO_ENUMERATIONS = """# Project Review Findings: PRs #612–#601

This review covered the two newest merged pull requests at the frozen selection
boundary, in merge-time order: #612 and #610. This review covered the two
newest uncovered merged pull requests at the frozen selection boundary, in
merge-time order: #602 and #601.
"""

AMBIGUOUS_NO_ENUMERATION = """# Project Review Findings: PRs #444–#442

A senior review of #444 and #442 taken newest-first over `coghex/kanban`,
judged against the issues they claimed to satisfy.
"""

NEGATED_SCOPE_REPORT = """# Project Review Findings: PRs #431–#412

The previously reported batch was skipped rather than reviewed again: #431 and
#412.
"""

DIRECT_MODE_REPORT = """# Project Review Findings: direct commits 9cf80f7–f3cff80

This review covered the next two direct first-parent commits by commit time:
#612 and #610, which are named here only to prove a direct report contributes
no pull-request coverage.
"""

LEDGER_DESIGN_SIBLING = """# Project review ledger design

This design document covered the arc's merged pull requests by merge time:
#612, #610, and #602.
"""


def valid_payload(rows=None, repo=REPO):
    return {
        "version": LEDGER.SCHEMA_VERSION,
        "repositories": {
            repo: {
                "rows": rows if rows is not None else {},
                "direct": {"endpoint": None, "reviewed": []},
                "excluded": {"prs": [], "commits": []},
                "migration": {"source": None, "boundary": None, "withheld_boundary": None},
            }
        },
    }


def ledger_text(payload, marker=None) -> str:
    marker = LEDGER.LEDGER_MARKER if marker is None else marker
    body = json.dumps(payload, indent=2, sort_keys=True) if not isinstance(payload, str) else payload
    return f"# Project review ledger\n\nProse a human wrote.\n\n{marker}\n\n```json\n{body}\n```\n"


def completed_row(status="clean", report=None):
    return {
        "status": status,
        "commit": FULL_SHA,
        "completed_at": "2026-09-05T11:22:33Z",
        "report": report,
        "evidence": ["review:2026-09-05"],
        "history": [],
    }


# Filling a template in is how a fixture is written here: a sentence naming a
# pull request is read by matching a template whole, so a fixture in some
# invented wording would test the refusal rather than the reading.
TEMPLATE_FILLERS = {
    "ENUM": "#612 and #610",
    # Deliberately disjoint from the enumeration: a template that puts a pull
    # request outside the batch and a filler that also enumerates it would be
    # a contradiction, and every instantiated template would flag.
    "EXCLUDED": "#533 and #520",
    "NUM": "#533",
    "NUMS": "#533 and #520",
    "COUNT": "two",
    "DATE": "2026-09-05",
    "LIST": ", , and",
}


def instantiate(template: str) -> str:
    return re.sub(
        r"\{([A-Z]+)\}", lambda hole: TEMPLATE_FILLERS[hole.group(1)], template
    )


class LedgerTestCase(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="project-review-ledger-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "docs").mkdir(parents=True, exist_ok=True)

    def parse(self, payload, marker=None):
        return LEDGER.parse_document(ledger_text(payload, marker), "fixture")

    def rows_of(self, state):
        return {int(key) for key in state["rows"]}


# --------------------------------------------------------------------------
# The document


class DocumentParsingTests(LedgerTestCase):
    """Only an absent document reads as empty; everything else is refused."""

    def test_an_absent_document_reads_as_empty(self):
        self.assertEqual(LEDGER.load_document(self.root), LEDGER.empty_document())
        self.assertEqual(
            LEDGER.state_for(LEDGER.load_document(self.root), REPO),
            LEDGER.empty_repository(),
        )

    def test_a_repository_the_document_does_not_mention_reads_as_empty(self):
        # Reading never writes: the absent repository defaults rather than
        # being created, so a read against one cannot leave a row behind.
        document = self.parse(valid_payload({"602": completed_row()}))
        self.assertEqual(LEDGER.state_for(document, OTHER_REPO), LEDGER.empty_repository())
        self.assertNotIn(OTHER_REPO, document["repositories"])

    def test_a_document_without_the_marker_is_refused(self):
        path = LEDGER.document_path(self.root)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("# Not a ledger\n\nSome prose.\n", encoding="utf-8")
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.load_document(self.root)
        self.assertIn(LEDGER.LEDGER_MARKER, str(raised.exception))

    def test_the_cursor_marker_does_not_satisfy_the_ledger_parser(self):
        # The two documents coexist until LEDGER-6, and the markers are
        # distinct precisely so neither parser reads the other's document as
        # its own. Handing the ledger a real cursor is the strongest form of
        # that check, so the cursor here is one its own writer produced.
        record_cursor(self.root, reviewed=[602, 601])
        cursor_text = CURSOR.document_path(self.root).read_text(encoding="utf-8")
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.parse_document(cursor_text, "the cursor document")
        self.assertIn(LEDGER.LEDGER_MARKER, str(raised.exception))

    def test_a_line_separator_cannot_smuggle_a_marker_into_the_document(self):
        # The previous round's fix counted marker lines; this one closes the
        # other half, which is a value that can create a line. An explicit
        # list of break characters missed U+2028, so the reader's own
        # `str.splitlines` decides instead.
        smuggled = "a" + chr(0x2028) + LEDGER.LEDGER_MARKER + chr(0x2028) + "b"
        with self.assertRaises(LEDGER.LedgerError) as raised:
            self.parse(valid_payload({"602": dict(completed_row(), evidence=[smuggled])}))
        self.assertIn("line break", str(raised.exception))

    def test_a_marker_inside_the_documents_own_data_is_not_a_second_marker(self):
        # An evidence note may say anything, including the marker. Such a note
        # renders into its table cell and its payload string, and a count over
        # the raw text made the document refuse its own output.
        rows = {
            "602": {
                "status": "legacy",
                "commit": None,
                "completed_at": None,
                "report": None,
                "evidence": [LEDGER.LEDGER_MARKER],
                "history": [],
            }
        }
        document = self.parse(valid_payload(rows))
        rendered = LEDGER.render_document(document)
        self.assertEqual(rendered.count(LEDGER.LEDGER_MARKER), 3)
        self.assertEqual(LEDGER.parse_document(rendered, "round trip"), document)
        # ... while a marker on a line of its own is still a second marker.
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.parse_document(
                f"{rendered}\n{LEDGER.LEDGER_MARKER}\n\n```json\n{{}}\n```\n", "fixture"
            )
        self.assertIn("2", str(raised.exception))

    def test_a_second_payload_block_is_refused(self):
        # A bad merge or a hand-edit leaves two. Taking the first would
        # silently choose between two ledgers, and nothing afterwards could
        # tell that a choice had been made.
        first = ledger_text(valid_payload({"602": completed_row()}))
        second = ledger_text(valid_payload({"601": completed_row()}))
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.parse_document(first + second, "fixture")
        self.assertIn("2", str(raised.exception))
        self.assertIn(LEDGER.LEDGER_MARKER, str(raised.exception))

    def test_unreadable_json_is_refused(self):
        with self.assertRaises(LEDGER.LedgerError) as raised:
            self.parse("{not json at all")
        self.assertIn("unreadable ledger JSON", str(raised.exception))

    def test_an_unexpected_version_is_refused(self):
        payload = valid_payload()
        payload["version"] = LEDGER.SCHEMA_VERSION + 1
        with self.assertRaises(LEDGER.LedgerError) as raised:
            self.parse(payload)
        self.assertIn("schema version", str(raised.exception))

    def test_a_version_that_merely_equals_one_is_refused(self):
        # `True == 1` and `1.0 == 1` in Python, so an equality test alone
        # would read either as schema version 1 and normalize a malformed
        # document into an accepted one.
        for version in (True, 1.0, "1", None, [1]):
            with self.subTest(version=version):
                payload = valid_payload()
                payload["version"] = version
                with self.assertRaises(LEDGER.LedgerError) as raised:
                    self.parse(payload)
                self.assertIn("schema version", str(raised.exception))

    def test_a_repeated_json_key_is_refused(self):
        # `json.loads` keeps the last of a repeated key and says nothing, so a
        # payload naming one repository, row, or field twice would be read as
        # whichever copy came last -- the duplicate-block refusal above, one
        # level further in.
        payload = (
            '{"version": 1, "repositories": {"coghex/kanban": {'
            '"rows": {}, "rows": {"602": null}, '
            '"direct": {"endpoint": null, "reviewed": []}, '
            '"excluded": {"prs": [], "commits": []}, '
            '"migration": {"source": null, "boundary": null, '
            '"withheld_boundary": null}}}}'
        )
        with self.assertRaises(LEDGER.LedgerError) as raised:
            self.parse(payload)
        self.assertIn("more than once", str(raised.exception))
        self.assertIn("rows", str(raised.exception))

    def test_a_payload_that_is_not_an_object_is_refused(self):
        with self.assertRaises(LEDGER.LedgerError) as raised:
            self.parse("[1, 2, 3]")
        self.assertIn("not an object", str(raised.exception))

    def test_a_document_without_repositories_is_refused(self):
        with self.assertRaises(LEDGER.LedgerError) as raised:
            self.parse({"version": LEDGER.SCHEMA_VERSION})
        self.assertIn("`repositories`", str(raised.exception))

    def test_a_repository_key_that_is_not_owner_name_is_refused(self):
        payload = valid_payload(repo="kanban")
        with self.assertRaises(LEDGER.LedgerError) as raised:
            self.parse(payload)
        self.assertIn("owner/name", str(raised.exception))

    def test_every_malformed_row_is_refused_by_name(self):
        # One subTest per malformed shape, each asserting the refusal names
        # what stopped it. A refusal that merely raised would leave an
        # operator editing a strictly parsed document by guesswork.
        cases = {
            "row key is not a number": ({"six-oh-two": completed_row()}, "not a pull-request number"),
            "row key has a leading zero": ({"0602": completed_row()}, "not a pull-request number"),
            "row is not an object": ({"602": "clean"}, "not an object"),
            "unknown row field": (
                {"602": dict(completed_row(), verdict="ok")},
                "unrecognized field(s) verdict",
            ),
            "status outside the four": (
                {"602": dict(completed_row(), status="approved")},
                "not one of clean, findings, legacy, never-reviewed",
            ),
            "abbreviated verification commit": (
                {"602": dict(completed_row(), commit="a1b2c3d")},
                "not a full 40-character commit SHA",
            ),
            "non-UTC timestamp": (
                {"602": dict(completed_row(), completed_at="2026-09-05 11:22:33+01:00")},
                "not a UTC",
            ),
            "impossible date": (
                {"602": dict(completed_row(), completed_at="2026-02-30T00:00:00Z")},
                "not a real date",
            ),
            "clean row with no commit": (
                {"602": dict(completed_row(), commit=None)},
                "names no verification commit",
            ),
            "clean row with no time": (
                {"602": dict(completed_row(), completed_at=None)},
                "names no completed-review time",
            ),
            "findings row with no report": (
                {"602": dict(completed_row(status="findings"), report=None)},
                "links no report",
            ),
            "legacy row with a commit": (
                {
                    "602": {
                        "status": "legacy",
                        "commit": FULL_SHA,
                        "completed_at": None,
                        "report": None,
                        "evidence": ["cursor:docs/project_review_boundaries.md"],
                        "history": [],
                    }
                },
                "names a verification commit",
            ),
            "legacy row with a time": (
                {
                    "602": {
                        "status": "legacy",
                        "commit": None,
                        "completed_at": "2026-09-05T11:22:33Z",
                        "report": None,
                        "evidence": ["cursor:docs/project_review_boundaries.md"],
                        "history": [],
                    }
                },
                "names a completed-review time",
            ),
            "legacy row with no evidence": (
                {
                    "602": {
                        "status": "legacy",
                        "commit": None,
                        "completed_at": None,
                        "report": None,
                        "evidence": [],
                        "history": [],
                    }
                },
                "names no evidence",
            ),
            "absolute report path": (
                {"602": dict(completed_row(status="findings"), report="/etc/passwd")},
                "not a repository-relative document path",
            ),
            "escaping report path": (
                {"602": dict(completed_row(status="findings"), report="../../secrets.md")},
                "not a repository-relative document path",
            ),
            "duplicated evidence": (
                {"602": dict(completed_row(), evidence=["one", "one"])},
                "twice",
            ),
            "evidence carrying a newline": (
                {"602": dict(completed_row(), evidence=["one\ntwo"])},
                "line break",
            ),
            "evidence carrying a unicode line separator": (
                {"602": dict(completed_row(), evidence=["one" + chr(0x2028) + "two"])},
                "line break",
            ),
            "evidence carrying a unicode paragraph separator": (
                {"602": dict(completed_row(), evidence=["one" + chr(0x2029) + "two"])},
                "line break",
            ),
            "evidence carrying a next-line character": (
                {"602": dict(completed_row(), evidence=["one" + chr(0x85) + "two"])},
                "line break",
            ),
            "evidence carrying a tab": (
                {"602": dict(completed_row(), evidence=["one\ttwo"])},
                "control character",
            ),
            "boundary merge time carrying a line separator": (
                None,
                "line break",
            ),
            "evidence that is not a list": (
                {"602": dict(completed_row(), evidence="one")},
                "not a list",
            ),
            "history that is not a list": (
                {"602": dict(completed_row(), history={})},
                "not a list",
            ),
            "history entry kind missing": (
                {"602": dict(completed_row(), history=[{"outcome": None, "commit": None,
                                                        "completed_at": "2026-09-05T11:22:33Z",
                                                        "report": None}])},
                "declares no kind",
            ),
            "history entry kind is not a slug": (
                {"602": dict(completed_row(), history=[{"kind": 12, "outcome": None,
                                                        "commit": None,
                                                        "completed_at": "2026-09-05T11:22:33Z",
                                                        "report": None}])},
                "not an entry kind",
            ),
            "unknown history field": (
                {"602": dict(completed_row(), history=[{"kind": "review", "outcome": None,
                                                        "commit": None,
                                                        "completed_at": "2026-09-05T11:22:33Z",
                                                        "report": None, "note": "x"}])},
                "unrecognized field(s) note",
            ),
            "history outcome outside the two": (
                {"602": dict(completed_row(), history=[{"kind": "review", "outcome": "legacy",
                                                        "commit": FULL_SHA,
                                                        "completed_at": "2026-09-05T11:22:33Z",
                                                        "report": None}])},
                "not one of clean, findings or null",
            ),
            "history entry that needs its row": (
                {"602": dict(completed_row(), history=[{"kind": "review", "outcome": "clean",
                                                        "commit": None,
                                                        "completed_at": "2026-09-05T11:22:33Z",
                                                        "report": None}])},
                "not self-contained",
            ),
            "findings history entry with no report": (
                {"602": dict(completed_row(), history=[{"kind": "review",
                                                        "outcome": "findings",
                                                        "commit": OTHER_SHA,
                                                        "completed_at": "2026-08-30T09:00:00Z",
                                                        "report": None}])},
                "links no report",
            ),
            "history entry with no time": (
                {"602": dict(completed_row(), history=[{"kind": "takeover", "outcome": None,
                                                        "commit": None, "completed_at": None,
                                                        "report": None}])},
                "not self-contained",
            ),
            "migration source outside the four": (
                None,
                "migration.source",
            ),
        }
        for name, (rows, expected) in cases.items():
            with self.subTest(shape=name):
                payload = valid_payload(rows if rows is not None else {})
                if rows is None and name == "migration source outside the four":
                    payload["repositories"][REPO]["migration"]["source"] = "guessed"
                elif rows is None:
                    payload["repositories"][REPO]["migration"]["boundary"] = {
                        "number": 533,
                        "merged_at": "2026-08-26" + chr(0x2028) + "T20:37:34Z",
                    }
                with self.assertRaises(LEDGER.LedgerError) as raised:
                    self.parse(payload)
                self.assertIn(expected, str(raised.exception))

    def test_a_marker_with_no_complete_payload_behind_it_is_refused(self):
        # The second half of the duplicate-block refusal: a bad merge can
        # leave a marker whose fence never closes, and counting only
        # well-formed payloads would call that document fine while ignoring
        # whichever state the broken half held.
        good = ledger_text(valid_payload({"602": completed_row()}))
        dangling = f"\n{LEDGER.LEDGER_MARKER}\n\n```json\n{{\"version\": 1}}\n"
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.parse_document(good + dangling, "fixture")
        self.assertIn("2", str(raised.exception))
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.parse_document(
                f"# Ledger\n\n{LEDGER.LEDGER_MARKER}\n\n```json\n{{}}\n", "fixture"
            )
        self.assertIn("no complete", str(raised.exception))

    def test_no_level_of_the_document_accepts_a_field_it_cannot_read(self):
        # The other half of the same silence: a field written by a newer
        # helper, or misspelled by a hand-edit, would be dropped on the next
        # write rather than refused. Checked at every level, because a strict
        # schema that was strict about rows and lax about the object holding
        # them is not strict.
        document = valid_payload({"602": completed_row()})
        document["extra"] = 1
        with self.assertRaises(LEDGER.LedgerError) as raised:
            self.parse(document)
        self.assertIn("unrecognized field(s) extra", str(raised.exception))
        for path, field in (
            ((), "rowz"),
            (("direct",), "frontier"),
            (("excluded",), "issues"),
            (("migration",), "reason"),
        ):
            with self.subTest(level="/".join(path) or "repository", field=field):
                payload = valid_payload({"602": completed_row()})
                target = payload["repositories"][REPO]
                for step in path:
                    target = target[step]
                target[field] = "x"
                with self.assertRaises(LEDGER.LedgerError) as raised:
                    self.parse(payload)
                self.assertIn(f"unrecognized field(s) {field}", str(raised.exception))
        payload = valid_payload()
        payload["repositories"][REPO]["direct"]["endpoint"] = {
            "sha": DIRECT_HISTORY[0],
            "when": "yesterday",
        }
        with self.assertRaises(LEDGER.LedgerError) as raised:
            self.parse(payload)
        self.assertIn("unrecognized field(s) when", str(raised.exception))
        payload = valid_payload()
        payload["repositories"][REPO]["migration"]["boundary"] = {
            "number": 533,
            "merged_at": "2026-08-26T20:37:34Z",
            "why": "x",
        }
        with self.assertRaises(LEDGER.LedgerError) as raised:
            self.parse(payload)
        self.assertIn("unrecognized field(s) why", str(raised.exception))

    def test_every_declared_field_must_be_present_rather_than_defaulted(self):
        # A truncated but still-parseable edit is the failure this closes: a
        # repository without `rows` would read as a repository with none, and
        # a row without `history` as one whose previous attempts never
        # happened. Both are silent, and both erase state the document exists
        # to keep.
        for field in ("rows", "direct", "excluded", "migration"):
            with self.subTest(repository_field=field):
                payload = valid_payload({"602": completed_row()})
                del payload["repositories"][REPO][field]
                with self.assertRaises(LEDGER.LedgerError) as raised:
                    self.parse(payload)
                self.assertIn(f"declares no {field}", str(raised.exception))
        for field, parent, keys in (
            ("endpoint", "direct", None),
            ("reviewed", "direct", None),
            ("prs", "excluded", None),
            ("commits", "excluded", None),
            ("source", "migration", None),
            ("boundary", "migration", None),
            ("withheld_boundary", "migration", None),
        ):
            with self.subTest(**{parent: field}):
                payload = valid_payload({"602": completed_row()})
                del payload["repositories"][REPO][parent][field]
                with self.assertRaises(LEDGER.LedgerError) as raised:
                    self.parse(payload)
                self.assertIn(f"declares no {field}", str(raised.exception))
        for field in LEDGER.ROW_KEYS:
            with self.subTest(row_field=field):
                row = completed_row()
                del row[field]
                with self.assertRaises(LEDGER.LedgerError) as raised:
                    self.parse(valid_payload({"602": row}))
                self.assertIn(f"declares no {field}", str(raised.exception))
        for field in LEDGER.HISTORY_KEYS:
            with self.subTest(history_field=field):
                entry = {
                    "kind": "review",
                    "outcome": "clean",
                    "commit": FULL_SHA,
                    "completed_at": "2026-09-05T11:22:33Z",
                    "report": None,
                }
                del entry[field]
                with self.assertRaises(LEDGER.LedgerError) as raised:
                    self.parse(valid_payload({"602": dict(completed_row(), history=[entry])}))
                self.assertIn(f"declares no {field}", str(raised.exception))

    def test_direct_and_excluded_are_held_to_the_cursor_modules_own_validation(self):
        # Design D-16 carries these two structures across untouched, so the
        # rules they are held to are the cursor's rather than a second set
        # written here. A ledger that relaxed them would accept direct state
        # the cursor itself would refuse on the next read.
        payload = valid_payload()
        payload["repositories"][REPO]["direct"]["reviewed"] = ["not-a-sha"]
        with self.assertRaises(LEDGER.LedgerError) as raised:
            self.parse(payload)
        self.assertIn("not a commit SHA", str(raised.exception))
        payload = valid_payload()
        payload["repositories"][REPO]["excluded"]["prs"] = [0]
        with self.assertRaises(LEDGER.LedgerError) as raised:
            self.parse(payload)
        self.assertIn("not a pull-request number", str(raised.exception))

    def test_a_valid_document_of_every_status_parses(self):
        rows = {
            "612": completed_row(),
            "610": completed_row(status="findings", report="docs/project_review/610.md"),
            "602": {
                "status": "legacy",
                "commit": None,
                "completed_at": None,
                "report": "docs/project_review_602-562.md",
                "evidence": ["report:docs/project_review_602-562.md"],
                "history": [],
            },
            "601": {
                "status": "never-reviewed",
                "commit": None,
                "completed_at": None,
                "report": None,
                "evidence": [],
                "history": [],
            },
        }
        state = LEDGER.state_for(self.parse(valid_payload(rows)), REPO)
        self.assertEqual(
            {key: row["status"] for key, row in state["rows"].items()},
            {"612": "clean", "610": "findings", "602": "legacy", "601": "never-reviewed"},
        )


# --------------------------------------------------------------------------
# The rendered body


class RenderingTests(LedgerTestCase):
    """The table a human reads, and the payload the module reads back."""

    def rendered(self, rows, **state):
        payload = valid_payload(rows)
        payload["repositories"][REPO].update(state)
        document = self.parse(payload)
        return LEDGER.render_document(document), document

    def test_only_a_clean_row_displays_a_checkmark(self):
        rows = {
            "612": completed_row(),
            "610": completed_row(status="findings", report="docs/project_review/610.md"),
            "602": {
                "status": "legacy",
                "commit": None,
                "completed_at": None,
                "report": None,
                "evidence": ["cursor:docs/project_review_boundaries.md"],
                "history": [],
            },
            "601": {
                "status": "never-reviewed",
                "commit": None,
                "completed_at": None,
                "report": None,
                "evidence": [],
                "history": [],
            },
        }
        text, _ = self.rendered(rows)
        lines = {
            line.split("|")[1].strip(): line
            for line in text.splitlines()
            if line.startswith("| #")
        }
        self.assertIn("✓", lines["#612"])
        for number in ("#610", "#602", "#601"):
            with self.subTest(row=number):
                self.assertNotIn("✓", lines[number])
        self.assertIn("[legacy]", lines["#602"])
        self.assertIn("never reviewed", lines["#601"])

    def test_a_completed_review_shows_its_commit_and_utc_time(self):
        text, _ = self.rendered({"612": completed_row()})
        row = next(line for line in text.splitlines() if line.startswith("| #612"))
        self.assertIn(f"`{FULL_SHA}`", row)
        self.assertIn("2026-09-05T11:22:33Z", row)

    def test_a_findings_row_links_its_report_and_a_legacy_row_may_too(self):
        rows = {
            "610": completed_row(status="findings", report="docs/project_review/610.md"),
            "602": {
                "status": "legacy",
                "commit": None,
                "completed_at": None,
                "report": "docs/project_review_602-562.md",
                "evidence": ["report:docs/project_review_602-562.md"],
                "history": [],
            },
        }
        text, _ = self.rendered(rows)
        # A link resolves from docs/project_review/ledger.md, so a report in
        # the ledger's own directory is named bare and a pre-ledger report one
        # directory up is reached through `..`. Storing repository-relative
        # paths and rendering them verbatim would break every older link.
        self.assertIn("[docs/project_review/610.md](610.md)", text)
        self.assertIn(
            "[docs/project_review_602-562.md](../project_review_602-562.md)", text
        )

    def test_a_row_with_nothing_to_show_renders_placeholders_rather_than_blanks(self):
        rows = {
            "601": {
                "status": "never-reviewed",
                "commit": None,
                "completed_at": None,
                "report": None,
                "evidence": [],
                "history": [],
            }
        }
        text, _ = self.rendered(rows)
        row = next(line for line in text.splitlines() if line.startswith("| #601"))
        self.assertEqual(row.count("—"), 4)

    def test_an_empty_repository_renders_a_table_free_statement(self):
        text, _ = self.rendered({})
        self.assertIn("No merged pull request has a ledger row yet.", text)
        self.assertNotIn("| PR |", text)

    def test_carried_over_state_and_provenance_are_visible_to_a_reader(self):
        text, _ = self.rendered(
            {},
            direct={"endpoint": {"sha": DIRECT_HISTORY[1]}, "reviewed": [DIRECT_HISTORY[0]]},
            excluded={"prs": [444], "commits": [DIRECT_HISTORY[2]]},
            migration={
                "source": "boundary-document",
                "boundary": {"number": 533, "merged_at": "legacy-exclusive-boundary"},
                "withheld_boundary": 533,
            },
        )
        self.assertIn(f"frontier `{DIRECT_HISTORY[1]}`", text)
        self.assertIn("#444", text)
        self.assertIn("boundary-document", text)
        self.assertIn("#533 was withheld from coverage", text)

    def test_rendering_round_trips_through_the_parser(self):
        rows = {
            "612": dict(
                completed_row(),
                history=[
                    {
                        "kind": "review",
                        "outcome": "findings",
                        "commit": OTHER_SHA,
                        "completed_at": "2026-08-30T09:00:00Z",
                        "report": "docs/project_review/612.md",
                    },
                    {
                        "kind": "review",
                        "outcome": "clean",
                        "commit": FULL_SHA,
                        "completed_at": "2026-09-05T11:22:33Z",
                        "report": None,
                    },
                    {
                        "kind": "takeover",
                        "outcome": None,
                        "commit": None,
                        "completed_at": "2026-09-05T10:00:00Z",
                        "report": None,
                    },
                ],
            )
        }
        text, document = self.rendered(rows)
        reparsed = LEDGER.parse_document(text, "round trip")
        self.assertEqual(reparsed, document)
        # Every entry survives, in order, with its own commit and time: a
        # refresh never erases the previous verification's date and hash.
        history = reparsed["repositories"][REPO]["rows"]["612"]["history"]
        self.assertEqual(
            [(entry["kind"], entry["outcome"], entry["commit"]) for entry in history],
            [
                ("review", "findings", OTHER_SHA),
                ("review", "clean", FULL_SHA),
                ("takeover", None, None),
            ],
        )

    def test_a_pipe_in_evidence_cannot_break_the_table(self):
        text, _ = self.rendered({"612": dict(completed_row(), evidence=["a | b"])})
        row = next(line for line in text.splitlines() if line.startswith("| #612"))
        self.assertIn("a \\| b", row)
        # Six cells, so seven delimiters once the escaped pipe is discounted;
        # an unescaped one would render as a seventh cell and shift every
        # column after it.
        self.assertEqual(row.replace("\\|", "").count("|"), 7)


# --------------------------------------------------------------------------
# The report scope parser


class ReportScopeTests(LedgerTestCase):
    """What a report's opening paragraph does and does not establish."""

    def scope(self, body, path="docs/project_review_602-569.md"):
        return LEDGER.report_scope(body, path)

    def paragraph(self, *sentences, path="docs/project_review_612-610.md"):
        body = "# Project Review Findings: PRs #612–#610\n\n" + " ".join(sentences) + "\n"
        return LEDGER.report_scope(body, path)

    def scope_sentence(self, contains=", in merge-time order:"):
        """One tracked scope template, filled in, chosen by what it contains.

        By shape rather than by index, so adding a template does not silently
        move which one a mutation below is applied to.
        """
        for template in LEDGER.SCOPE_TEMPLATES:
            if contains in template:
                return instantiate(template)
        raise AssertionError(f"no scope template contains {contains!r}")

    def mutated(self, sentence, old, new):
        """`sentence` with `old` replaced, refusing a replacement that did not.

        A mutation that silently does not apply leaves the test asserting that
        an unmodified scope sentence parses, which it does -- so the test
        passes while checking nothing.
        """
        body = sentence.replace(old, new, 1)
        self.assertNotEqual(body, sentence, f"{old!r} is not in the sentence")
        return body

    def test_every_scope_template_is_read_and_returns_its_enumeration(self):
        # The set is the contract, so it is asserted as a set: every template
        # the module ships must parse, filled in. A template that stopped
        # matching its own shape would be a report this migration silently
        # started flagging.
        for template in LEDGER.SCOPE_TEMPLATES:
            with self.subTest(template=template[:56]):
                scope = self.paragraph(instantiate(template))
                self.assertIsNone(scope["flag"], scope["flag"])
                self.assertEqual(scope["reviewed"], [612, 610])

    def test_every_mention_and_prose_template_contributes_nothing(self):
        # The other half: each of the remaining templates beside a batch
        # leaves the batch readable and adds no coverage of its own. The
        # unnumbered ones are here because a paragraph is read as a whole
        # sequence -- a sentence nobody read cannot be said to have been
        # accounted for.
        for template in LEDGER.MENTION_TEMPLATES + LEDGER.PROSE_TEMPLATES:
            with self.subTest(template=template[:56]):
                scope = self.paragraph(
                    instantiate(LEDGER.SCOPE_TEMPLATES[0]), instantiate(template)
                )
                self.assertIsNone(scope["flag"], scope["flag"])
                self.assertEqual(scope["reviewed"], [612, 610])

    def test_a_cursor_named_in_the_scope_sentence_is_not_imported(self):
        scope = self.scope(CURSOR_NAMING_REPORT)
        self.assertIsNone(scope["flag"], scope["flag"])
        self.assertEqual(scope["reviewed"], [602, 601, 569])
        self.assertNotIn(610, scope["reviewed"])

    def test_a_number_in_a_later_section_is_not_imported(self):
        # #612 appears only under the finding heading, which is exactly the
        # kind of mention design D-9 refuses to treat as coverage.
        self.assertNotIn(612, self.scope(CURSOR_NAMING_REPORT)["reviewed"])

    def test_a_stop_named_inside_the_scope_sentence_is_not_imported(self):
        scope = self.scope(STOP_NAMING_REPORT)
        self.assertIsNone(scope["flag"], scope["flag"])
        self.assertEqual(scope["reviewed"], [550, 545])
        self.assertNotIn(533, scope["reviewed"])

    def test_an_enumeration_above_its_own_filename_interval_is_imported(self):
        scope = self.scope(ABOVE_INTERVAL_REPORT, "docs/project_review_432-412.md")
        self.assertIsNone(scope["flag"], scope["flag"])
        self.assertEqual(scope["reviewed"], [432, 442, 444, 431, 412])

    def test_an_annotated_enumeration_is_flagged_rather_than_read(self):
        # docs/project_review_463-455.md annotates every pull request in its
        # enumeration. Two rounds were spent deciding which annotations were
        # safe to drop -- "(not reviewed)", then "(unreviewed)", then "(out of
        # scope)" -- and each answer was a list of the spellings someone had
        # thought of. None is dropped now, so this report takes one
        # `--confirm`, which is the recovery path rather than a gap in it.
        scope = self.scope(ANNOTATED_REPORT, "docs/project_review_571-570.md")
        self.assertEqual(scope["reviewed"], [])
        self.assertEqual(scope["candidates"], [570, 571])
        self.assertIn("--confirm", scope["flag"])

    def test_a_separately_skipped_batch_is_not_imported(self):
        scope = self.scope(SKIPPED_BATCH_REPORT, "docs/project_review_520-517.md")
        self.assertIsNone(scope["flag"], scope["flag"])
        self.assertEqual(scope["reviewed"], [520, 517])
        self.assertEqual({550, 545} & set(scope["reviewed"]), set())

    def test_two_scope_sentences_are_flagged_with_every_candidate_number(self):
        scope = self.scope(AMBIGUOUS_TWO_ENUMERATIONS, "docs/project_review_612-601.md")
        self.assertEqual(scope["reviewed"], [])
        self.assertEqual(scope["candidates"], [601, 602, 610, 612])
        self.assertIn("2 reviewed-pull-request enumerations", scope["flag"])
        self.assertIn("--confirm", scope["flag"])

    def test_an_unreadable_sentence_flags_even_beside_a_readable_one(self):
        scope = self.paragraph(
            instantiate(LEDGER.SCOPE_TEMPLATES[0]), "It also reviewed #601."
        )
        self.assertEqual(scope["reviewed"], [])
        self.assertIn("does not read", scope["flag"])
        self.assertIn("#601", scope["flag"])

    def test_an_unintroduced_enumeration_is_flagged_with_every_candidate_number(self):
        scope = self.scope(AMBIGUOUS_NO_ENUMERATION, "docs/project_review_444-442.md")
        self.assertEqual(scope["reviewed"], [])
        self.assertEqual(scope["candidates"], [442, 444])
        self.assertIn("does not read", scope["flag"])

    def test_a_paragraph_of_readable_sentences_that_names_no_batch_is_flagged(self):
        # Every sentence matches, and none of them introduces an enumeration.
        scope = self.paragraph(instantiate(LEDGER.PROSE_TEMPLATES[0]))
        self.assertEqual(scope["reviewed"], [])
        self.assertIn("names no reviewed-pull-request enumeration", scope["flag"])

    def test_a_paragraph_in_an_unread_wording_is_flagged(self):
        scope = self.paragraph(
            "This review covered a batch of merged pull requests and wrote up "
            "what it found."
        )
        self.assertEqual(scope["reviewed"], [])
        self.assertEqual(scope["candidates"], [])
        self.assertIn("does not read", scope["flag"])

    def test_a_report_with_no_title_paragraph_is_flagged(self):
        scope = self.scope("Just a line with no heading and no paragraph under one.\n")
        self.assertIsNotNone(scope["flag"])
        self.assertEqual(scope["reviewed"], [])

    def test_a_negated_scope_sentence_is_flagged_rather_than_imported(self):
        scope = self.scope(NEGATED_SCOPE_REPORT, "docs/project_review_431-412.md")
        self.assertEqual(scope["reviewed"], [])
        self.assertIsNotNone(scope["flag"])

    def test_no_annotation_is_dropped_whatever_it_says(self):
        # Deciding which annotations were safe to drop cost two rounds and
        # produced a list of spellings both times. An annotation is prose, and
        # prose is what this parser has stopped reading, so every one of these
        # flags -- including ones that say nothing about reviewing at all.
        scope_sentence = self.scope_sentence()
        for annotation in (
            "not reviewed",
            "unreviewed",
            "skipped",
            "deferred",
            "pending",
            "no review",
            "not in scope",
            "out of scope",
            "`out of scope`",
            "`unreviewed`",
            "the issue templates",
            "anything at all",
        ):
            with self.subTest(annotation=annotation):
                scope = self.paragraph(
                    self.mutated(scope_sentence, "#612", f"#612 ({annotation})")
                )
                self.assertEqual(scope["reviewed"], [])
                self.assertIsNotNone(scope["flag"])

    def test_a_sentence_that_contradicts_itself_is_not_read(self):
        # A scope sentence says how many pull requests it covered as well as
        # which, and either half can be the stale one. Deciding between them
        # is the operator's call, so a disagreement flags rather than trusting
        # the list.
        sentence = self.scope_sentence("This review covered the {COUNT} newest merged")
        for label, enumeration in (
            ("more than it says", "#612, #610, and #602"),
            ("fewer than it says", "#612"),
            ("the same one twice", "#612 and #612"),
        ):
            with self.subTest(enumeration=label):
                scope = self.paragraph(
                    self.mutated(sentence, "#612 and #610", enumeration)
                )
                self.assertEqual(scope["reviewed"], [])
                self.assertIn("does not read", scope["flag"])
        # ... and the agreeing sentence it was mutated from still parses.
        scope = self.paragraph(sentence)
        self.assertIsNone(scope["flag"], scope["flag"])
        self.assertEqual(scope["reviewed"], [612, 610])

    def test_a_pull_request_cannot_be_both_enumerated_and_excluded(self):
        # A template says which numbers its sentence puts outside the batch --
        # the cursor it resumed below, the stop it did not cross, a landing it
        # excluded, a batch someone else reported, the bound it stayed above.
        # A paragraph that also enumerates one of them contradicts itself.
        batch = "#550 and #533"
        for label, body in {
            "its own stop": (
                "This bounded review covered every eligible merged pull "
                "request remaining above the user's exclusive stop at #533, "
                f"in merge-time order: {batch}."
            ),
            "its own cursor": (
                "This review continued below the completed #533 cursor and "
                f"covered the next two merged pull requests by merge time: {batch}."
            ),
            "a bound in a later sentence": (
                "This bounded review covered every eligible merged pull "
                "request remaining above the user's exclusive stop at #520, "
                f"in merge-time order: {batch}. The bound therefore produced "
                "two pull requests rather than the requested twelve; no pull "
                "request numbered #533 or lower was entered."
            ),
            "a landing in a later sentence": (
                "This review covered the two newest merged pull requests at "
                "the frozen selection boundary, in merge-time order: #612 and "
                "#610. Master advanced through #610 while verification was "
                "running; that newer landing was excluded rather than moving "
                "the boundary, and the finding below was rechecked at current."
            ),
            "a reported batch in a later sentence": (
                "This review continued below the completed #533 cursor and "
                "covered the next two genuinely unreviewed merged pull "
                "requests in merge-time order: #520 and #517. The previously "
                "reported #520 and #545 batch was explicitly skipped rather "
                "than reviewed again."
            ),
        }.items():
            with self.subTest(contradiction=label):
                scope = self.scope(
                    f"# Project Review Findings: PRs #612–#517\n\n{body}\n",
                    "docs/project_review_612-517.md",
                )
                self.assertEqual(scope["reviewed"], [])
                self.assertIn("outside the batch", scope["flag"])

    def test_an_interval_endpoint_may_be_in_the_batch(self):
        # The control, and the property nine tracked reports depend on: an
        # interval's endpoints and the landing a commit came after are context
        # rather than exclusion, and the oldest reviewed pull request is
        # routinely one end of the span its direct commits sit in.
        scope = self.paragraph(
            "This review continued below the completed #533 cursor and "
            "covered the next two merged pull requests by merge time: #612 "
            "and #610.",
            "There were no direct first-parent commits interleaved between "
            "#533 and #610.",
        )
        self.assertIsNone(scope["flag"], scope["flag"])
        self.assertEqual(scope["reviewed"], [612, 610])

    def test_an_enumeration_needs_a_delimiter_between_its_pull_requests(self):
        # With the punctuation and the conjunction both optional, "#612#610"
        # and "#612 #610" read as two-item lists, so malformed prose
        # established coverage instead of asking for confirmation.
        sentence = self.scope_sentence("This review covered the {COUNT} newest merged")
        for label, enumeration in (
            ("no delimiter at all", "#612#610"),
            ("a space and nothing else", "#612 #610"),
            ("a stray word between", "#612 then #610"),
        ):
            with self.subTest(enumeration=label):
                scope = self.paragraph(
                    self.mutated(sentence, "#612 and #610", enumeration)
                )
                self.assertEqual(scope["reviewed"], [])
                self.assertIsNotNone(scope["flag"])
        # ... and the delimiters the tracked reports use still read.
        for enumeration in ("#612 and #610", "#612, #610", "#612, and #610"):
            with self.subTest(delimiter=enumeration):
                scope = self.paragraph(
                    self.mutated(sentence, "#612 and #610", enumeration)
                    if enumeration != "#612 and #610"
                    else sentence
                )
                self.assertIsNone(scope["flag"], scope["flag"])
                self.assertEqual(scope["reviewed"], [612, 610])

    def test_a_count_word_is_read_as_the_number_the_reports_spell(self):
        # The tracked reports spell their batch size in words, including the
        # hyphenated compounds, and every one of them agrees with the list it
        # introduces -- which is what makes the check above a check rather
        # than a new way to flag eighteen working reports.
        self.assertEqual(LEDGER.count_value("twelve"), 12)
        self.assertEqual(LEDGER.count_value("twenty-nine"), 29)
        self.assertEqual(LEDGER.count_value("29"), 29)
        self.assertIsNone(LEDGER.count_value("several"))

    def test_a_parenthesis_anywhere_makes_its_sentence_unreadable(self):
        # A qualifier bracketed into an otherwise-matching sentence would
        # otherwise be blanked back into a match.
        scope = self.paragraph(
            self.mutated(
                self.scope_sentence(), " order:", " order (but none were reviewed):"
            )
        )
        self.assertEqual(scope["reviewed"], [])
        self.assertIsNotNone(scope["flag"])

    def test_only_the_four_code_span_shapes_the_reports_use_are_masked(self):
        # Blanking a word in backticks leaves a gap a template spans happily,
        # so the four shapes the tracked reports' spans take are spelled out
        # rather than approximated by "one token" -- which also masked `never`
        # and `unreviewed`.
        for span in (
            "`097eeed`",
            "`1544709bcfbf197c87e55ea69a7be8988bb90965`",
            "`master@2e2003e`",
            "`origin/master@3215e3d`",
            "`docs/project_review_456-446.md`",
            "`docs/design.md`",
            "`coghex/kanban`",
        ):
            with self.subTest(masked=span):
                self.assertIsNotNone(LEDGER.CODE_SPAN_RE.match(span))
        for span in ("`never`", "`unreviewed`", "`skipped`", "`but none were reviewed`"):
            with self.subTest(kept=span):
                self.assertIsNone(LEDGER.CODE_SPAN_RE.match(span))
        # ... and a kept span leaves its sentence unread.
        for old, new in (
            ("This review covered", "This review `never` covered"),
            (" order:", " order `but none were reviewed`:"),
        ):
            with self.subTest(mutation=new):
                sentence = self.scope_sentence(
                    ", in merge-time order:" if old == " order:" else "This review covered"
                )
                scope = self.paragraph(self.mutated(sentence, old, new))
                self.assertEqual(scope["reviewed"], [])
                self.assertIsNotNone(scope["flag"])

    def test_every_wording_the_review_rounds_produced_is_flagged(self):
        # The wordings this pull request's reviews produced that an earlier
        # *reading* rule admitted: each matched some verb, object, role word
        # or clause test and so lost or invented a pull request. Together they
        # are what the templates exist to refuse, so they are asserted as one
        # set rather than one at a time.
        #
        # A sentence that matches a template and then disagrees with itself is
        # a different refusal and has its own test above, with the agreeing
        # sentence beside it as a control. The set is not counted here, in
        # prose or in a name: it grows whenever a review finds another wording,
        # and a number beside it would be stale by the time the entry below it
        # was written.
        opening = self.scope_sentence()
        wordings = {
            "two colon clauses in one sentence": (
                "This review covered the first two merged pull requests: #612 "
                "and #610; it also reviewed the next two: #533 and #520."
            ),
            "colonless list beside a parsed one": (
                "This review covered the merged pull requests #612 and #610; "
                "it also reviewed these merged pull requests: #533 and #520."
            ),
            "bare singleton": f"{opening} It also reviewed #601.",
            "noun-prefixed singleton": f"{opening} It also reviewed PR #601.",
            "mixed positive and negative clause": (
                f"{opening} It did not review #571, but it also reviewed "
                "these: #601 and #533."
            ),
            "parenthesised sentence": f"{opening} (It also reviewed #601.)",
            "backticked pull request": f"{opening} It also reviewed `#601`.",
            "and-joined predicates": f"{opening} It also reviewed #601 and skipped #533.",
            "preposition span": f"{opening} It also reviewed PRs from #601 through #533.",
            "negative claim introducing a list": (
                "No pull requests were reviewed; the candidates were: #601 and #533."
            ),
            "role word behind a pull-request noun": (
                f"{opening} It also reviewed the previously reported PR #601."
            ),
            "verb taking another object": (
                "This review covered direct commits and noted pending merged "
                "pull requests: #601 and #533."
            ),
            "verb taking metadata": (
                "This review covered metadata associated with pending merged "
                "pull requests: #601 and #533."
            ),
            "passive review behind a role word": (
                f"{opening} The previously reported #601 and #533 were also reviewed."
            ),
            "active review behind a role word": (
                f"{opening} The previously reported #601 and #533 received a "
                "fresh review."
            ),
            "counterfactual clause": (
                "If this review had covered the two merged pull requests, "
                "they would have been: #601 and #533."
            ),
            "conditional clause": (
                "Had this review covered the two merged pull requests, the "
                "batch would be: #601 and #533."
            ),
            "landmark handed to a reviewing verb": (
                f"{opening} It also reviewed the reported #601 and #533 batch."
            ),
            "cursor handed to a reviewing verb": (
                f"{opening} It also reviewed the completed #601 cursor."
            ),
            "suffix withdrawing the clause's own claim": (
                "This review covered the two merged pull requests' metadata "
                "but failed to review the pull requests themselves: #601 and "
                "#533."
            ),
            "reported batch that was reviewed": (
                f"{opening} The previously reported #601 and #533 batch was "
                "also reviewed."
            ),
            "stop that was reviewed": (
                f"{opening} The exclusive stop at #601 was also reviewed."
            ),
            "landing this review also covered": (
                f"{opening} Master advanced through #601, which this review "
                "also covered."
            ),
            "non-coverage predicate reversed past a semicolon": (
                f"{opening} The previously reported #601 and #533 batch was "
                "skipped; it was reviewed again here."
            ),
            "non-coverage predicate reversed in the next sentence": (
                f"{opening} The previously reported #601 and #533 batch was "
                "skipped. That batch was reviewed again here."
            ),
            "non-coverage predicate negated": (
                f"{opening} The previously reported #601 and #533 batch was "
                "not skipped."
            ),
            "reviewing verb outside a lookback window": (
                f"{opening} It also reviewed the merged pull requests "
                "interleaved between #601 and #533."
            ),
            "unnumbered sentence reversing a numbered one": (
                f"{opening} The previously reported #601 and #533 batch was "
                "explicitly skipped rather than reviewed again. That batch was "
                "nevertheless reviewed in this pass."
            ),
            "unnumbered claim of further coverage": (
                f"{opening} Everything else was reviewed too."
            ),
        }
        for label, body in wordings.items():
            with self.subTest(wording=label):
                scope = self.scope(
                    f"# Project Review Findings: PRs #612–#520\n\n{body}\n",
                    "docs/project_review_612-520.md",
                )
                self.assertEqual(scope["reviewed"], [], label)
                self.assertIsNotNone(scope["flag"], label)


# --------------------------------------------------------------------------
# Migration


class MigrationTests(LedgerTestCase):
    """Coverage is imported from evidence, and from nothing else."""

    def migrate(self, repo=REPO, **kwargs):
        return LEDGER.migrate(self.root, repo, **kwargs)

    def test_a_fresh_repository_migrates_to_an_empty_ledger(self):
        result = self.migrate()
        self.assertEqual(result["status"], "migrated")
        self.assertEqual(result["state"]["rows"], {})
        self.assertEqual(result["cursor"]["source"], "absent")
        self.assertIsNone(result["cursor"]["document"])
        self.assertTrue(LEDGER.document_path(self.root).is_file())
        # Nothing is scheduled as never-reviewed either: the complete merged-PR
        # inventory is LEDGER-3's, and inventing rows without it would be a
        # claim about a history this slice never reads.
        self.assertEqual(result["state"], LEDGER.state_for(
            LEDGER.load_document(self.root), REPO
        ))

    def test_a_v2_cursor_contributes_its_recorded_set_and_keeps_its_boundary_as_provenance(self):
        record_cursor(self.root, reviewed=[602, 601, 569], boundary=533)
        result = self.migrate()
        self.assertEqual(result["cursor"]["source"], "cursor-v2")
        self.assertEqual(self.rows_of(result["state"]), {602, 601, 569})
        self.assertEqual(result["state"]["migration"]["boundary"]["number"], 533)
        self.assertIsNone(result["state"]["migration"]["withheld_boundary"])
        # The boundary is provenance, not coverage: it takes no row of its own.
        self.assertNotIn("533", result["state"]["rows"])
        for key in ("602", "601", "569"):
            with self.subTest(row=key):
                row = result["state"]["rows"][key]
                self.assertEqual(row["status"], "legacy")
                self.assertIsNone(row["commit"])
                self.assertIsNone(row["completed_at"])
                self.assertEqual(
                    row["evidence"], ["cursor:docs/project_review_boundaries.md"]
                )

    def test_a_v1_cursor_contributes_its_frontier_as_coverage(self):
        # Version 1's `pr.endpoint` was the oldest PR the batch reviewed, so it
        # is real coverage and the cursor module's own read migrates it into
        # the reviewed set. Unlike the hand-authored stop below, nothing is
        # withheld.
        record_cursor(self.root, reviewed=[602, 601], boundary=500)
        downgrade_cursor_to_v1(self.root)
        result = self.migrate()
        self.assertEqual(result["cursor"]["source"], "cursor-v1")
        self.assertEqual(self.rows_of(result["state"]), {602, 601, 500})
        self.assertIsNone(result["state"]["migration"]["boundary"])
        self.assertIsNone(result["state"]["migration"]["withheld_boundary"])

    def test_a_hand_authored_stop_is_withheld_while_its_exception_is_imported(self):
        # The unchanged cursor parser returns every `PR #N` in the bullet as
        # reviewed, the exclusive stop included. A stop is the one pull request
        # the batch did not enter, so it is withheld here; the exceptional
        # reviewed PR named in the same bullet still arrives.
        (self.root / "docs" / "project_review_boundaries.md").write_text(
            HAND_AUTHORED_CURSOR, encoding="utf-8"
        )
        result = self.migrate()
        self.assertEqual(result["cursor"]["source"], "boundary-document")
        self.assertEqual(self.rows_of(result["state"]), {550})
        self.assertEqual(result["state"]["migration"]["withheld_boundary"], 533)
        self.assertEqual(result["state"]["migration"]["boundary"]["number"], 533)

    def test_a_bare_hand_authored_stop_establishes_no_coverage_at_all(self):
        # The negative control for the case above: with no exceptional PR in
        # the bullet, the parser's reviewed set is the stop alone, and the
        # ledger takes none of it.
        (self.root / "docs" / "project_review_boundaries.md").write_text(
            HAND_AUTHORED_BARE_STOP, encoding="utf-8"
        )
        result = self.migrate()
        self.assertEqual(result["state"]["rows"], {})
        self.assertEqual(result["state"]["migration"]["withheld_boundary"], 533)

    def test_a_withheld_stop_returns_when_a_report_independently_evidences_it(self):
        # Correction to requirement 4: the stop is retained when separate
        # reviewed evidence establishes coverage. Its row then rests on the
        # report alone, never on the stop declaration.
        (self.root / "docs" / "project_review_boundaries.md").write_text(
            HAND_AUTHORED_BARE_STOP, encoding="utf-8"
        )
        path = write_report(
            self.root,
            "project_review_533-517.md",
            "# Project Review Findings: PRs #533–#517\n\n"
            "This review covered the two newest merged pull requests at the "
            "frozen selection boundary, in merge-time order: #533 and #517.\n",
        )
        result = self.migrate()
        self.assertEqual(self.rows_of(result["state"]), {533, 517})
        self.assertEqual(result["state"]["rows"]["533"]["evidence"], [f"report:{path}"])
        self.assertEqual(result["state"]["migration"]["withheld_boundary"], 533)

    def test_report_enumerations_are_imported_with_the_report_as_evidence(self):
        record_cursor(self.root, reviewed=[612], boundary=533)
        path = write_report(self.root, "project_review_602-569.md", CURSOR_NAMING_REPORT)
        result = self.migrate()
        self.assertEqual(self.rows_of(result["state"]), {612, 602, 601, 569})
        self.assertEqual(result["state"]["rows"]["602"]["evidence"], [f"report:{path}"])
        self.assertEqual(result["state"]["rows"]["602"]["report"], path)
        self.assertEqual(
            result["state"]["rows"]["612"]["evidence"],
            ["cursor:docs/project_review_boundaries.md"],
        )
        self.assertIsNone(result["state"]["rows"]["612"]["report"])

    def test_an_above_interval_enumeration_is_imported(self):
        write_report(self.root, "project_review_432-412.md", ABOVE_INTERVAL_REPORT)
        result = self.migrate()
        self.assertEqual(self.rows_of(result["state"]), {432, 442, 444, 431, 412})

    def test_overlapping_reports_leave_one_row_carrying_every_evidence_source(self):
        record_cursor(self.root, reviewed=[520])
        first = write_report(self.root, "project_review_520-500.md", OVERLAPPING_REPORT)
        second = write_report(self.root, "project_review_520-517.md", SKIPPED_BATCH_REPORT)
        result = self.migrate()
        self.assertEqual(self.rows_of(result["state"]), {520, 517, 500})
        self.assertEqual(
            result["state"]["rows"]["520"]["evidence"],
            [
                "cursor:docs/project_review_boundaries.md",
                f"report:{first}",
                f"report:{second}",
            ],
        )
        # The link is the first report in path order; the rest stay in
        # evidence rather than being dropped for the one that won.
        self.assertEqual(result["state"]["rows"]["520"]["report"], first)

    def test_the_boundaries_document_and_a_design_sibling_contribute_nothing(self):
        # The report glob matches both, and both carry `#N` tokens. Only what
        # the cursor module classifies as a PR report is read, so neither
        # produces a row and neither produces a flag.
        record_cursor(self.root, reviewed=[602])
        write_report(self.root, "project_review_ledger_design.md", LEDGER_DESIGN_SIBLING)
        result = self.migrate()
        self.assertEqual(result["flags"], [])
        self.assertEqual(self.rows_of(result["state"]), {602})
        kinds = {report["path"]: report["kind"] for report in result["reports"]}
        self.assertEqual(kinds["docs/project_review_ledger_design.md"], "unrecognized")
        self.assertNotIn("docs/project_review_boundaries.md", kinds)

    def test_a_direct_mode_report_contributes_no_pull_request_rows(self):
        write_report(self.root, "project_review_direct_9cf80f7-f3cff80.md", DIRECT_MODE_REPORT)
        result = self.migrate()
        self.assertEqual(result["flags"], [])
        self.assertEqual(result["state"]["rows"], {})
        kinds = {report["path"]: report["kind"] for report in result["reports"]}
        self.assertEqual(kinds["docs/project_review_direct_9cf80f7-f3cff80.md"], "direct")

    def test_direct_state_is_carried_across_unchanged(self):
        state = record_cursor(
            self.root,
            reviewed=[602],
            direct_reviewed=[DIRECT_HISTORY[0], DIRECT_HISTORY[1]],
        )
        result = self.migrate()
        self.assertEqual(result["state"]["direct"], state["direct"])
        self.assertTrue(state["direct"]["reviewed"])
        self.assertIsNotNone(state["direct"]["endpoint"])
        # No direct commit becomes a row: the PR table is PR-only (D-16).
        self.assertEqual(self.rows_of(result["state"]), {602})

    def test_exclusions_are_carried_across_unchanged(self):
        state = record_cursor(self.root, reviewed=[602], excluded=[444, 442])
        result = self.migrate()
        self.assertEqual(result["state"]["excluded"], state["excluded"])
        self.assertEqual(result["state"]["excluded"]["prs"], [442, 444])
        # An excluded pull request is not coverage and takes no row.
        self.assertEqual(self.rows_of(result["state"]), {602})

    def test_the_old_cursor_document_survives_the_migration_byte_for_byte(self):
        record_cursor(self.root, reviewed=[602, 601], boundary=533)
        path = CURSOR.document_path(self.root)
        before = path.read_bytes()
        self.migrate()
        self.assertEqual(path.read_bytes(), before)

    def test_a_migrated_ledger_reads_back_as_what_the_migration_reported(self):
        record_cursor(self.root, reviewed=[602, 601], boundary=533, direct_reviewed=[DIRECT_HISTORY[0]])
        write_report(self.root, "project_review_432-412.md", ABOVE_INTERVAL_REPORT)
        result = self.migrate()
        self.assertEqual(
            LEDGER.state_for(LEDGER.load_document(self.root), REPO), result["state"]
        )

    def test_a_second_migration_refuses_rather_than_overwriting(self):
        record_cursor(self.root, reviewed=[602])
        self.migrate()
        before = LEDGER.document_path(self.root).read_bytes()
        with self.assertRaises(LEDGER.LedgerError) as raised:
            self.migrate()
        self.assertIn("already exists", str(raised.exception))
        self.assertEqual(LEDGER.document_path(self.root).read_bytes(), before)

    def test_an_unparseable_cursor_stops_the_migration(self):
        (self.root / "docs" / "project_review_boundaries.md").write_text(
            "# Boundaries\n\nNothing this parser recognizes.\n", encoding="utf-8"
        )
        with self.assertRaises(LEDGER.LedgerError) as raised:
            self.migrate()
        self.assertIn("could not be read", str(raised.exception))
        self.assertFalse(LEDGER.document_path(self.root).exists())

    def test_a_repository_identity_that_is_not_owner_name_is_refused(self):
        with self.assertRaises(LEDGER.LedgerError):
            self.migrate(repo="kanban")


class FlaggedMigrationTests(LedgerTestCase):
    """An ambiguous paragraph blocks the write and is recovered by confirmation."""

    def test_every_report_is_inspected_and_nothing_is_written_while_one_is_flagged(self):
        record_cursor(self.root, reviewed=[612])
        clear = write_report(self.root, "project_review_432-412.md", ABOVE_INTERVAL_REPORT)
        flagged = write_report(
            self.root, "project_review_612-601.md", AMBIGUOUS_TWO_ENUMERATIONS
        )
        also_flagged = write_report(
            self.root, "project_review_444-442.md", AMBIGUOUS_NO_ENUMERATION
        )
        result = LEDGER.migrate(self.root, REPO)
        self.assertEqual(result["status"], "flagged")
        self.assertIsNone(result["state"])
        self.assertIsNone(result["document"])
        # All of them, not just the first: a migration that stopped at the
        # head of the list would need one confirmation round per flag.
        self.assertEqual(
            sorted(flag["report"] for flag in result["flags"]), sorted([flagged, also_flagged])
        )
        self.assertEqual(
            {flag["report"]: flag["candidates"] for flag in result["flags"]},
            {flagged: [601, 602, 610, 612], also_flagged: [442, 444]},
        )
        # The unambiguous report was still read, so a later confirmation round
        # does not have to re-establish it.
        self.assertEqual(
            next(report for report in result["reports"] if report["path"] == clear)["reviewed"],
            [432, 442, 444, 431, 412],
        )
        self.assertFalse(LEDGER.document_path(self.root).exists())

    def test_a_confirmed_enumeration_completes_the_migration_once(self):
        cursor_path = CURSOR.document_path(self.root)
        record_cursor(self.root, reviewed=[612])
        before = cursor_path.read_bytes()
        write_report(self.root, "project_review_432-412.md", ABOVE_INTERVAL_REPORT)
        flagged = write_report(
            self.root, "project_review_612-601.md", AMBIGUOUS_TWO_ENUMERATIONS
        )
        first = LEDGER.migrate(self.root, REPO)
        self.assertEqual(first["status"], "flagged")
        self.assertEqual(cursor_path.read_bytes(), before)

        second = LEDGER.migrate(self.root, REPO, {flagged: [612, 610]})
        self.assertEqual(second["status"], "migrated")
        self.assertEqual(self.rows_of(second["state"]), {612, 610, 432, 442, 444, 431, 412})
        self.assertEqual(
            second["state"]["rows"]["610"]["evidence"],
            [f"report:{flagged} (operator-confirmed)"],
        )
        self.assertEqual(
            second["state"]["rows"]["612"]["evidence"],
            [
                "cursor:docs/project_review_boundaries.md",
                f"report:{flagged} (operator-confirmed)",
            ],
        )
        # #602 and #601 were candidates the operator did not confirm, so they
        # are absent rather than imported alongside the ones that were.
        self.assertNotIn("602", second["state"]["rows"])
        self.assertNotIn("601", second["state"]["rows"])
        self.assertEqual(cursor_path.read_bytes(), before)

        # ... and only once. A third invocation refuses rather than rebuilding.
        with self.assertRaises(LEDGER.LedgerError):
            LEDGER.migrate(self.root, REPO, {flagged: [612, 610]})

    def test_an_annotated_report_is_completed_by_confirming_it(self):
        # The one tracked report this parser does not read is the one whose
        # every enumerated pull request carries an annotation. Its recovery is
        # the ordinary one, so it is asserted end to end rather than left as a
        # property of the scope parser.
        path = write_report(self.root, "project_review_571-570.md", ANNOTATED_REPORT)
        flagged = LEDGER.migrate(self.root, REPO)
        self.assertEqual(flagged["status"], "flagged")
        self.assertEqual([flag["report"] for flag in flagged["flags"]], [path])
        self.assertEqual(flagged["flags"][0]["candidates"], [570, 571])
        self.assertFalse(LEDGER.document_path(self.root).exists())

        result = LEDGER.migrate(self.root, REPO, {path: [571, 570]})
        self.assertEqual(result["status"], "migrated")
        self.assertEqual(self.rows_of(result["state"]), {571, 570})
        self.assertEqual(
            result["state"]["rows"]["571"]["evidence"],
            [f"report:{path} (operator-confirmed)"],
        )

    def test_a_confirmed_empty_enumeration_imports_nothing_from_that_report(self):
        flagged = write_report(
            self.root, "project_review_444-442.md", AMBIGUOUS_NO_ENUMERATION
        )
        result = LEDGER.migrate(self.root, REPO, {flagged: []})
        self.assertEqual(result["status"], "migrated")
        self.assertEqual(result["state"]["rows"], {})

    def test_a_confirmation_replaces_the_parsers_reading_of_an_unflagged_report(self):
        path = write_report(self.root, "project_review_432-412.md", ABOVE_INTERVAL_REPORT)
        result = LEDGER.migrate(self.root, REPO, {path: [432, 412]})
        self.assertEqual(self.rows_of(result["state"]), {432, 412})
        self.assertTrue(
            next(report for report in result["reports"] if report["path"] == path)["confirmed"]
        )

    def test_a_confirmation_naming_no_such_report_is_refused(self):
        write_report(self.root, "project_review_432-412.md", ABOVE_INTERVAL_REPORT)
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.migrate(self.root, REPO, {"docs/project_review_999-998.md": [999]})
        self.assertIn("project_review_999-998.md", str(raised.exception))
        self.assertFalse(LEDGER.document_path(self.root).exists())

    def test_a_confirmation_naming_a_direct_report_is_refused(self):
        path = write_report(
            self.root, "project_review_direct_9cf80f7-f3cff80.md", DIRECT_MODE_REPORT
        )
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.migrate(self.root, REPO, {path: [612]})
        self.assertIn(path, str(raised.exception))


# --------------------------------------------------------------------------
# The command line


class CommandLineTests(LedgerTestCase):
    """Three outcomes, three exit codes, one JSON shape."""

    def run_module(self, *argv):
        return subprocess.run(
            [sys.executable, str(REPO_ROOT / CLAUDE_LEDGER_HELPER), *argv],
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
        )

    def test_read_and_migrate_succeed_with_exit_zero(self):
        record_cursor(self.root, reviewed=[602, 601], boundary=533)
        migrated = self.run_module("migrate", "--root", str(self.root), "--repo", REPO)
        self.assertEqual(migrated.returncode, 0, migrated.stderr)
        reported = json.loads(migrated.stdout)
        self.assertEqual(reported["status"], "migrated")
        read = self.run_module("read", "--root", str(self.root), "--repo", REPO)
        self.assertEqual(read.returncode, 0, read.stderr)
        self.assertEqual(json.loads(read.stdout)["state"], reported["state"])

    def test_a_flagged_migration_exits_three_with_its_flags_on_stdout(self):
        write_report(self.root, "project_review_612-601.md", AMBIGUOUS_TWO_ENUMERATIONS)
        result = self.run_module("migrate", "--root", str(self.root), "--repo", REPO)
        # Neither success nor refusal: the migration read everything and is
        # waiting for a decision, and a caller that read it as a refusal would
        # retry it unchanged forever.
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "flagged")

    def test_a_refusal_exits_two_with_its_reason_on_stderr(self):
        path = LEDGER.document_path(self.root)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("# Not a ledger\n", encoding="utf-8")
        result = self.run_module("read", "--root", str(self.root))
        self.assertEqual(result.returncode, 2)
        self.assertIn("project-review ledger:", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_read_without_a_repository_prints_the_whole_document(self):
        record_cursor(self.root, reviewed=[602])
        self.run_module("migrate", "--root", str(self.root), "--repo", REPO)
        result = self.run_module("read", "--root", str(self.root))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(REPO, json.loads(result.stdout)["document"]["repositories"])

    def test_a_malformed_confirmation_is_refused(self):
        for raw in ("docs/project_review_432-412.md", "=612", "docs/a.md=twelve"):
            with self.subTest(confirmation=raw):
                with self.assertRaises(LEDGER.LedgerError):
                    LEDGER.main(
                        ["migrate", "--root", str(self.root), "--repo", REPO, "--confirm", raw]
                    )

    def test_the_same_report_cannot_be_confirmed_twice(self):
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.main(
                [
                    "migrate",
                    "--root",
                    str(self.root),
                    "--repo",
                    REPO,
                    "--confirm",
                    "docs/project_review_432-412.md=432",
                    "--confirm",
                    "docs/project_review_432-412.md=412",
                ]
            )
        self.assertIn("more than once", str(raised.exception))


# --------------------------------------------------------------------------
# Packaging


class BundledLedgerHelperTests(unittest.TestCase):
    """The module ships in both bundles and nothing invokes it yet."""

    def test_both_bundles_carry_the_helper_and_the_copies_are_identical(self):
        claude = (REPO_ROOT / CLAUDE_LEDGER_HELPER).read_bytes()
        codex = (REPO_ROOT / CODEX_LEDGER_HELPER).read_bytes()
        self.assertTrue(claude, CLAUDE_LEDGER_HELPER)
        self.assertEqual(claude, codex)

    def test_each_copy_sits_beside_the_cursor_it_reads(self):
        # The migration loads the cursor module from beside itself, so a copy
        # shipped into a directory without one would resolve nothing wherever
        # it installs.
        for relative_path in LEDGER_HELPERS.values():
            with self.subTest(copy=relative_path):
                sibling = (REPO_ROOT / relative_path).parent / "project_review_cursor.py"
                self.assertTrue(sibling.is_file(), str(sibling))

    def test_both_copies_load_and_agree_on_their_document_contract(self):
        claude, codex = LEDGER_MODULES["claude"], LEDGER_MODULES["codex"]
        self.assertEqual(claude.LEDGER_MARKER, codex.LEDGER_MARKER)
        self.assertEqual(claude.SCHEMA_VERSION, codex.SCHEMA_VERSION)
        self.assertEqual(claude.LEDGER_RELATIVE_PATH, codex.LEDGER_RELATIVE_PATH)

    def test_the_ledger_marker_is_distinct_from_the_cursors(self):
        self.assertNotEqual(LEDGER.LEDGER_MARKER, CURSOR.CURSOR_MARKER)
        self.assertNotEqual(LEDGER.LEDGER_MARKER, CURSOR.LEGACY_CURSOR_MARKER)
        self.assertNotEqual(LEDGER.LEDGER_RELATIVE_PATH, CURSOR.DOCUMENT_RELATIVE_PATH)

    def test_the_helper_spawns_no_external_command(self):
        # Pinned as an absence because a helper that shelled out would need
        # declaring in docs/agent-workflow-contract.md, and would also be
        # reaching a checkout the caller never told it about. Its declared
        # surface in tools/test_agent_workflow_contract.py is an empty set for
        # exactly this reason.
        source = (REPO_ROOT / CLAUDE_LEDGER_HELPER).read_text(encoding="utf-8")
        for forbidden in ("subprocess", "os.system", "os.popen"):
            with self.subTest(spelling=forbidden):
                self.assertNotIn(forbidden, source)

    def test_no_bundled_asset_resolves_the_new_module(self):
        # Design D-19: the installed command keeps reading the v2 cursor until
        # LEDGER-6 switches it over, so nothing but the two copies themselves
        # may name this module. Asserted over the whole of both bundles rather
        # than over the two rendered assets alone, because a manifest, a
        # skill, or a sibling script naming it would make it invokable just as
        # surely as a command file would.
        shipped = {Path(path).name for path in LEDGER_HELPERS.values()}
        naming = []
        for bundle in BUNDLE_ROOTS:
            for path in sorted((REPO_ROOT / bundle).rglob("*")):
                if not path.is_file() or path.name in shipped:
                    continue
                try:
                    content = path.read_text(encoding="utf-8")
                except (OSError, UnicodeDecodeError):
                    continue
                if "project_review_ledger" in content:
                    naming.append(str(path.relative_to(REPO_ROOT)))
        self.assertEqual(naming, [])

    def test_the_rendered_assets_still_resolve_only_the_cursor(self):
        # The non-vacuity control for the scan above: the same bundles do name
        # the cursor, in both rendered assets, so "nothing names the ledger" is
        # a property of this slice rather than of a search that finds nothing.
        for relative_path in RENDERED_ASSETS:
            content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
            with self.subTest(asset=relative_path):
                self.assertIn("project_review_cursor.py", content)
                self.assertNotIn("project_review_ledger", content)


if __name__ == "__main__":
    unittest.main()
