"""The bundled project-review ledger's schema, renderer, and migration.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 tools/test_project_review_ledger.py

Issue #680, slice LEDGER-2 of `docs/project_review_ledger_design.md`. The
module under test ships in both bundles and nothing invokes it yet: design
D-19 keeps the installed `project-review` command on the v2 cursor until
LEDGER-6 switches it over, so until then these tests are the module's only
caller. That makes them the whole of its contract rather than a sample of it,
and these properties follow.

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
import os
import re
import threading
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
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


def row(status, **fields):
    """One row, built from the module's own shape rather than beside it.

    `empty_row` is what the helper writes, so a field added to a row turns up
    in every fixture here instead of leaving a hand-written literal that the
    parser then refuses for a reason the test was never about.
    """
    built = LEDGER.empty_row(status)
    unknown = sorted(set(fields) - set(built))
    assert not unknown, f"a row has no {', '.join(unknown)}"
    built.update(fields)
    return built


def completed_row(status="clean", report=None):
    return row(
        status,
        commit=FULL_SHA,
        completed_at="2026-09-05T11:22:33Z",
        report=report,
        evidence=["review:2026-09-05"],
    )


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


# A ledger exactly as the previous release rendered one: schema version 1,
# whose rows carry no `title` and no `merged_at` because that writer had no
# such fields. Held verbatim rather than rebuilt from the current module,
# because the thing under test is whether this helper can open a document it
# did not write, and a fixture the current renderer produced would be the
# current shape with an older number on it.
PREVIOUS_RELEASE_LEDGER = """# Project review ledger

Machine-owned state for the `project-review` workflow: one row per merged pull
request, per repository, with its status, the commit a completed review
verified it against, when that review completed, the report it produced, and
the evidence the row rests on. A checkmark means a clean review against the
commit beside it; `[legacy]` means coverage established by a document that
predates this ledger, with no date and no commit invented for it.

Written by `project_review_ledger.py`. Edit it through that helper rather than
by hand: the payload below is parsed strictly, and an edit it cannot read stops
the next invocation instead of being ignored.

## coghex/kanban

| PR | Status | Verified at | Completed (UTC) | Report | Evidence |
| ---: | --- | --- | --- | --- | --- |
| #612 | ✓ clean | `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa` | 2026-09-05T11:22:33Z | — | review:2026-09-05 |
| #610 | [legacy] | — | — | — | cursor:docs/project_review_boundaries.md |
| #602 | never reviewed | — | — | — | — |

- Migrated from the cursor-v2 record.

<!-- project-review:ledger:v1 -->

```json
{
  "repositories": {
    "coghex/kanban": {
      "direct": {
        "endpoint": null,
        "reviewed": []
      },
      "excluded": {
        "commits": [],
        "prs": []
      },
      "migration": {
        "boundary": null,
        "source": "cursor-v2",
        "withheld_boundary": null
      },
      "rows": {
        "602": {
          "commit": null,
          "completed_at": null,
          "evidence": [],
          "history": [],
          "report": null,
          "status": "never-reviewed"
        },
        "610": {
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md"
          ],
          "history": [],
          "report": null,
          "status": "legacy"
        },
        "612": {
          "commit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "completed_at": "2026-09-05T11:22:33Z",
          "evidence": [
            "review:2026-09-05"
          ],
          "history": [],
          "report": null,
          "status": "clean"
        }
      }
    }
  },
  "version": 1
}
```
"""


# --------------------------------------------------------------------------
# The merged-pull-request listing a selection is made from

# Merge order and number order agree unless a test says otherwise. Most of
# these tests are not about the difference between them, and the two that are
# spell their own times.
MERGE_EPOCH = datetime(2026, 1, 1)


def merge_time(number: int) -> str:
    return (MERGE_EPOCH + timedelta(hours=number)).strftime("%Y-%m-%dT%H:%M:%SZ")


def merged(number, at=None, title=None):
    """One pull request as the listing names it."""
    return {
        "number": number,
        "title": f"Pull request #{number}" if title is None else title,
        "merged_at": merge_time(number) if at is None else at,
    }


def listing(entries, limit=100):
    """The pages a caller fetched, paginated the way `gh` hands them back.

    A listing that divides exactly into full pages ends with an empty one,
    because that is what the caller sees: it asks for the next page and gets
    nothing, and that empty page is the proof the history stopped.
    """
    entries = list(entries)
    chunks = [entries[index:index + limit] for index in range(0, len(entries), limit)]
    if not chunks or len(chunks[-1]) == limit:
        chunks.append([])
    return {
        "pages": [
            {"page": position, "limit": limit, "prs": chunk}
            for position, chunk in enumerate(chunks, start=1)
        ]
    }


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
        rows = {"602": row("legacy", evidence=[LEDGER.LEDGER_MARKER])}
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

    def test_a_closing_fence_carrying_a_suffix_does_not_close_the_block(self):
        # The first three backticks on a line closed the payload, so a
        # rendered ledger whose final fence was edited to ```json or ```junk
        # still parsed: two fence-looking lines to the counter, a payload that
        # stopped short of the suffix to the parser, and no complete block at
        # all to a Markdown reader.
        rendered = LEDGER.render_document(self.parse(valid_payload()))
        for suffix in ("```json", "```junk", "``` trailing"):
            with self.subTest(closing=suffix):
                body = rendered.rstrip("\n")
                broken = body[: body.rindex("```")] + suffix + "\n"
                with self.assertRaises(LEDGER.LedgerError):
                    LEDGER.parse_document(broken, "fixture")
        # ... and the fence the renderer writes still closes it.
        self.assertEqual(
            LEDGER.parse_document(rendered, "round trip"), self.parse(valid_payload())
        )

    def test_a_second_fenced_payload_is_refused_however_it_is_spelled(self):
        # Counting only the blocks behind a marker let a bare second fence
        # through, and then counting only lines equal to "```json" let every
        # other spelling of one through: they are all the same block to a
        # Markdown reader, and all were invisible here.
        rendered = LEDGER.render_document(self.parse(valid_payload()))
        for opening in ("```json", "```JSON", "``` json", "````json", "~~~json", "```"):
            with self.subTest(fence=opening):
                with self.assertRaises(LEDGER.LedgerError) as raised:
                    LEDGER.parse_document(
                        rendered + f'\n{opening}\n{{"version": 1}}\n```\n', "fixture"
                    )
                self.assertIn("fence lines", str(raised.exception))

    def test_a_number_too_long_for_python_to_convert_is_refused(self):
        # `int()` refuses a string of more than a few thousand digits, so a
        # payload holding one left a traceback where the refusal belongs.
        # Written as raw JSON: `json.dumps` refuses the same integer, which
        # is the point -- the number only ever arrives as text.
        oversized = (
            '{"version": 1, "repositories": {"coghex/kanban": {"rows": {}, '
            '"direct": {"endpoint": null, "reviewed": []}, '
            '"excluded": {"prs": [' + "9" * 5000 + '], "commits": []}, '
            '"migration": {"source": null, "boundary": null, '
            '"withheld_boundary": null}}}}'
        )
        with self.assertRaises(LEDGER.LedgerError):
            LEDGER.parse_document(ledger_text(oversized), "fixture")
        with self.assertRaises(LEDGER.LedgerError):
            LEDGER._confirmation("docs/project_review_12-11.md=#" + "1" * 5000)

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
            "row key is a superscript digit": (
                {"\u00b2": completed_row()},
                "not a pull-request number",
            ),
            "row key is an arabic-indic digit": (
                {"\u0663": completed_row()},
                "not a pull-request number",
            ),
            "row key longer than any number": (
                {"9" * 5000: completed_row()},
                "not a pull-request number",
            ),
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
                    "602": row(
                        "legacy",
                        commit=FULL_SHA,
                        evidence=["cursor:docs/project_review_boundaries.md"],
                    )
                },
                "names a verification commit",
            ),
            "legacy row with a time": (
                {
                    "602": row(
                        "legacy",
                        completed_at="2026-09-05T11:22:33Z",
                        evidence=["cursor:docs/project_review_boundaries.md"],
                    )
                },
                "names a completed-review time",
            ),
            "legacy row with no evidence": (
                {"602": row("legacy")},
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
        # A bad merge can leave a marker whose fence never closes, and
        # counting only well-formed payloads would call that document fine
        # while ignoring whichever state the broken half held.
        good = ledger_text(valid_payload({"602": completed_row()}))
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.parse_document(good + '\n```json\n{"version": 1}\n', "fixture")
        self.assertIn("fence lines", str(raised.exception))
        # ... and one that also carries a second marker refuses on that first.
        dangling = f"\n{LEDGER.LEDGER_MARKER}\n\n```json\n{{\"version\": 1}}\n"
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.parse_document(good + dangling, "fixture")
        self.assertIn("markers", str(raised.exception))
        # ... and a document whose one fenced block is not the marker's own.
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.parse_document(
                f"# Ledger\n\n{LEDGER.LEDGER_MARKER}\n\nprose in between\n\n"
                "```json\n{}\n```\n",
                "fixture",
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

    def test_a_provenance_record_must_describe_a_migration_that_could_happen(self):
        # Each field was checked on its own, so a record could say it carried
        # nothing over and still hold the boundary it carried -- which the
        # table renders as "Nothing carried over from a previous record" while
        # the payload says otherwise. A provenance record describing a
        # migration that never happened is one an operator would believe.
        boundary = {"number": 533, "merged_at": "legacy-exclusive-boundary"}
        for label, migration in {
            "nothing read, a boundary held": {
                "source": None, "boundary": boundary, "withheld_boundary": None},
            "no record read, a boundary held": {
                "source": "absent", "boundary": boundary, "withheld_boundary": None},
            "a v2 cursor withholding a stop": {
                "source": "cursor-v2", "boundary": boundary, "withheld_boundary": 533},
            "a v1 cursor holding a boundary": {
                "source": "cursor-v1", "boundary": boundary, "withheld_boundary": None},
            "a withheld number that is not the boundary": {
                "source": "boundary-document", "boundary": boundary,
                "withheld_boundary": 520},
            "a withheld number with no boundary": {
                "source": "boundary-document", "boundary": None,
                "withheld_boundary": 533},
            "a hand-authored stop withheld from nothing": {
                "source": "boundary-document", "boundary": boundary,
                "withheld_boundary": None},
        }.items():
            with self.subTest(provenance=label):
                payload = valid_payload()
                payload["repositories"][REPO]["migration"] = migration
                with self.assertRaises(LEDGER.LedgerError):
                    self.parse(payload)
        # ... and the shapes a migration does produce still parse.
        for label, migration in {
            "a hand-authored stop, withheld": {
                "source": "boundary-document", "boundary": boundary,
                "withheld_boundary": 533},
            "a v2 cursor with its boundary": {
                "source": "cursor-v2", "boundary": boundary, "withheld_boundary": None},
            "a hand-authored record this repository is absent from": {
                "source": "boundary-document", "boundary": None,
                "withheld_boundary": None},
        }.items():
            with self.subTest(provenance=label):
                payload = valid_payload()
                payload["repositories"][REPO]["migration"] = migration
                self.assertEqual(
                    LEDGER.state_for(self.parse(payload), REPO)["migration"], migration
                )

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
            "602": row(
                "legacy",
                report="docs/project_review_602-562.md",
                evidence=["report:docs/project_review_602-562.md"],
            ),
            "601": row("never-reviewed"),
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
            "602": row("legacy", evidence=["cursor:docs/project_review_boundaries.md"]),
            "601": row("never-reviewed"),
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
            "602": row(
                "legacy",
                report="docs/project_review_602-562.md",
                evidence=["report:docs/project_review_602-562.md"],
            ),
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
        text, _ = self.rendered({"601": row("never-reviewed")})
        rendered = next(line for line in text.splitlines() if line.startswith("| #601"))
        # Six: a never-reviewed row that no listing has named yet knows its
        # number and nothing else, so every other cell is a placeholder.
        self.assertEqual(rendered.count("—"), 6)

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

    def delimiters(self):
        """How many `|` one intact row carries, taken from the header itself.

        Counted rather than written down, so a column added to the table does
        not leave a stale number here quietly asserting the old shape.
        """
        return LEDGER.TABLE_HEADER.splitlines()[0].count("|")

    def test_a_backslash_before_a_pipe_cannot_break_the_table(self):
        # Escaping the pipe without escaping the backslash in front of it
        # produces an even backslash run, which leaves the pipe a delimiter
        # and shifts every column after it.
        text, _ = self.rendered({"612": dict(completed_row(), evidence=["left\\|right"])})
        rendered = next(line for line in text.splitlines() if line.startswith("| #612"))
        self.assertIn("left\\\\\\|right", rendered)
        self.assertEqual(
            rendered.replace("\\\\", "").replace("\\|", "").count("|"), self.delimiters()
        )

    def test_a_pipe_in_evidence_cannot_break_the_table(self):
        text, _ = self.rendered({"612": dict(completed_row(), evidence=["a | b"])})
        rendered = next(line for line in text.splitlines() if line.startswith("| #612"))
        self.assertIn("a \\| b", rendered)
        # An unescaped pipe would render as one cell more than the header
        # declares and shift every column after it.
        self.assertEqual(rendered.replace("\\|", "").count("|"), self.delimiters())

    def test_a_pipe_in_a_title_cannot_break_the_table(self):
        # A title is the first cell whose text this repository does not write:
        # it arrives from the merged-pull-request listing, so it is escaped
        # exactly as an evidence note is rather than trusted to be tame.
        text, _ = self.rendered({"612": dict(completed_row(), title="a | b")})
        rendered = next(line for line in text.splitlines() if line.startswith("| #612"))
        self.assertIn("a \\| b", rendered)
        self.assertEqual(rendered.replace("\\|", "").count("|"), self.delimiters())

    def test_a_listed_title_and_merge_time_are_shown_beside_the_number(self):
        text, _ = self.rendered(
            {
                "612": dict(
                    completed_row(), title="Read the discriminators first",
                    merged_at="2026-09-05T09:00:00Z",
                )
            }
        )
        rendered = next(line for line in text.splitlines() if line.startswith("| #612"))
        self.assertIn("Read the discriminators first", rendered)
        self.assertIn("2026-09-05T09:00:00Z", rendered)


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

    def test_two_words_run_together_are_not_a_sentence(self):
        # Tokens were joined by `\s*`, so "This reviewcovered the two newest
        # merged pull requests ...: #612 and #610" matched the template it
        # runs two words of together. Wrapping and punctuation spacing stay
        # free; a word boundary does not.
        sentence = self.scope_sentence("This review covered the {COUNT} newest merged")
        scope = self.paragraph(
            self.mutated(sentence, "This review covered", "This reviewcovered")
        )
        self.assertEqual(scope["reviewed"], [])
        self.assertIsNotNone(scope["flag"])
        # ... while a report that wrapped the same sentence differently reads.
        self.assertEqual(
            self.paragraph(sentence.replace(" ", "\n", 3))["reviewed"], [612, 610]
        )

    def test_a_pull_request_reference_is_canonical_and_positive(self):
        # "#0001" is not how a tracker writes #1 and "#0" is not a pull
        # request. One was silently normalized into coverage; the other was
        # carried to a fatal refusal deep in the migration where a report flag
        # belonged.
        sentence = self.scope_sentence("This review covered the {COUNT} newest merged")
        for enumeration in ("#0001 and #11", "#0 and #11", "#012 and #11"):
            with self.subTest(enumeration=enumeration):
                scope = self.paragraph(
                    self.mutated(sentence, "#612 and #610", enumeration)
                )
                self.assertEqual(scope["reviewed"], [])
                self.assertIsNotNone(scope["flag"])

    def test_a_pull_request_number_is_ascii_and_bounded(self):
        # `\d` matches "١", and `int("١٢")` is 12, so a report writing its
        # batch in Arabic-Indic digits read as coverage of pull requests it
        # never spells. A longer run than any tracker issues is not a number
        # with a tail either; it is not one at all.
        sentence = self.scope_sentence("This review covered the {COUNT} newest merged")
        for label, enumeration in (
            ("arabic-indic digits", "#\u0661\u0662 and #\u0661\u0661"),
            ("more digits than int() converts", "#" + "1" * 5000 + " and #11"),
        ):
            with self.subTest(enumeration=label):
                scope = self.paragraph(
                    self.mutated(sentence, "#612 and #610", enumeration)
                )
                self.assertEqual(scope["reviewed"], [])
                self.assertIsNotNone(scope["flag"])

    def test_a_count_this_helper_cannot_read_is_not_a_missing_count(self):
        # `\d` matches "٣" and `count_value` does not, so a template taking a
        # Unicode digit produced a count nothing could read -- and an
        # unreadable count was treated as no count, which let a sentence
        # declaring three pull requests and listing two through.
        sentence = self.scope_sentence("This review covered the {COUNT} newest merged")
        scope = self.paragraph(self.mutated(sentence, " two ", " \u0663 "))
        self.assertEqual(scope["reviewed"], [])
        self.assertIsNotNone(scope["flag"])

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
# The inventory and the three queues


class SelectionTestCase(LedgerTestCase):
    """Fixtures built by the helper itself, never as objects beside it.

    Every ledger a test here starts from is written through the module's own
    writer and read back through its own parser, so a fixture that the parser
    would refuse fails as a fixture rather than passing as a selection. The
    rows are assembled from `empty_row`, which is the shape the helper writes,
    so a field added to a row turns up here instead of being silently absent.
    """

    def establish(self, rows, excluded=(), repo=REPO, root=None):
        root = self.root if root is None else root
        document = LEDGER.empty_document()
        state = LEDGER.empty_repository()
        state["rows"] = dict(rows)
        state["excluded"]["prs"] = sorted(excluded)
        document["repositories"][repo] = state
        if LEDGER.document_path(root).exists():
            LEDGER.publish_document(root, document)
        else:
            LEDGER.create_document(root, document)
        return LEDGER.state_for(LEDGER.load_document(root), repo)

    def migrated(self, **kwargs):
        """A ledger of `[legacy]` rows, produced by `migrate` itself."""
        record_cursor(self.root, **kwargs)
        return LEDGER.migrate(self.root, REPO)["state"]

    def select(self, entries, limit=100, repo=REPO, root=None):
        return LEDGER.select(
            self.root if root is None else root, repo, listing(entries, limit)
        )

    def selected(self, entries, **kwargs):
        return self.select(entries, **kwargs)["selected"]["number"]

    def rows_on_disk(self, repo=REPO):
        return LEDGER.state_for(LEDGER.load_document(self.root), repo)["rows"]

    def clean(self, completed_at, **fields):
        return row("clean", commit=FULL_SHA, completed_at=completed_at, **fields)

    def findings(self, completed_at, report="docs/project_review/610.md", **fields):
        return row(
            "findings",
            commit=FULL_SHA,
            completed_at=completed_at,
            report=report,
            **fields,
        )


class InventoryTests(SelectionTestCase):
    """What a listing has to prove before it is a repository's known universe."""

    def setUp(self):
        super().setUp()
        self.establish({})

    def refuses(self, pages, expected):
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.select(self.root, REPO, {"pages": pages})
        self.assertIn(expected, str(raised.exception))
        return str(raised.exception)

    def test_a_complete_listing_records_every_page_it_carries(self):
        # Two full pages and an empty terminal one: the shape a caller reaches
        # when the history divides exactly into pages, and the shape a rule
        # written only against "the last page is shorter" would have refused.
        result = self.select([merged(number) for number in (612, 610, 602, 601)], limit=2)
        self.assertEqual(result["inventory"]["pages"], 3)
        self.assertEqual(result["inventory"]["listed"], 4)
        self.assertEqual(set(self.rows_on_disk()), {"612", "610", "602", "601"})

    def test_a_listing_whose_last_page_came_back_full_asks_for_the_next_one(self):
        message = self.refuses(
            [{"page": 1, "limit": 2, "prs": [merged(612), merged(610)]}],
            "the next page is needed",
        )
        self.assertIn("limit of 2", message)

    def test_a_page_sequence_that_is_not_contiguous_from_page_one_is_refused(self):
        # Page lengths alone cannot tell a dropped interior page from a
        # shorter history, and the pull requests on the dropped page would be
        # recorded as pull requests this repository does not have.
        cases = {
            "an interior page missing": [
                {"page": 1, "limit": 2, "prs": [merged(612), merged(610)]},
                {"page": 3, "limit": 2, "prs": [merged(602)]},
            ],
            "a sequence that does not start at page 1": [
                {"page": 2, "limit": 2, "prs": [merged(612)]},
            ],
            "a page number repeated": [
                {"page": 1, "limit": 2, "prs": [merged(612), merged(610)]},
                {"page": 1, "limit": 2, "prs": [merged(602)]},
            ],
            "a page number that is not a number": [
                {"page": "1", "limit": 2, "prs": [merged(612)]},
            ],
            "a page number that is a boolean": [
                {"page": True, "limit": 2, "prs": [merged(612)]},
            ],
        }
        for label, pages in cases.items():
            with self.subTest(listing=label):
                self.refuses(pages, "declares page number")

    def test_a_walk_that_changed_its_page_size_is_refused(self):
        # A page number is an offset expressed in page sizes. "Page 1 of 2,
        # page 2 of 4" names rows 1-2 and then rows 5-8, and the rows in
        # between are ones no page ever carried -- while contiguous numbering
        # said the walk was whole and a short final page said it had ended.
        cases = {
            "a page size that grew": [
                {"page": 1, "limit": 2, "prs": [merged(612), merged(610)]},
                {"page": 2, "limit": 4, "prs": [merged(602), merged(601)]},
            ],
            "a page size that shrank": [
                {"page": 1, "limit": 4, "prs": [merged(n) for n in (612, 610, 602, 601)]},
                {"page": 2, "limit": 2, "prs": [merged(533)]},
            ],
            "a page size that changed on the last page only": [
                {"page": 1, "limit": 2, "prs": [merged(612), merged(610)]},
                {"page": 2, "limit": 2, "prs": [merged(602), merged(601)]},
                {"page": 3, "limit": 3, "prs": []},
            ],
        }
        for label, pages in cases.items():
            with self.subTest(listing=label):
                message = self.refuses(pages, "page 1 declared")
                self.assertIn("one page size", message)

    def test_one_page_size_across_the_walk_is_accepted(self):
        # The non-vacuity control for the refusal above: the same numbering
        # and the same short final page pass when the size never moved.
        result = self.select([merged(number) for number in (612, 610, 602)], limit=2)
        self.assertEqual(result["inventory"]["listed"], 3)

    def test_a_page_after_the_last_one_is_refused(self):
        self.refuses(
            [
                {"page": 1, "limit": 3, "prs": [merged(612)]},
                {"page": 2, "limit": 3, "prs": [merged(610)]},
            ],
            "came back short of its own limit",
        )

    def test_a_listing_with_no_pages_at_all_is_refused(self):
        # Distinct from a listing whose one page came back empty, which is a
        # repository that has merged nothing and is accepted below.
        self.refuses([], "carries no pages at all")

    def test_a_repository_that_has_merged_nothing_lists_one_empty_page(self):
        result = self.select([])
        self.assertEqual(result["inventory"]["listed"], 0)
        self.assertEqual(result["status"], "no-selectable-row")

    def test_a_page_limit_that_is_not_a_positive_integer_is_refused(self):
        for limit in (0, -1, "100", True, 1.0, None):
            with self.subTest(limit=limit):
                self.refuses(
                    [{"page": 1, "limit": limit, "prs": []}], "not a positive page size"
                )

    def test_a_page_carrying_more_rows_than_it_asked_for_is_refused(self):
        self.refuses(
            [{"page": 1, "limit": 1, "prs": [merged(612), merged(610)]}],
            "cannot hold more than it asked for",
        )

    def test_a_page_states_exactly_the_fields_a_page_has(self):
        for label, page in (
            ("a field it cannot read", {"page": 1, "limit": 2, "prs": [], "cursor": "x"}),
            ("a field left out", {"page": 1, "limit": 2}),
        ):
            with self.subTest(page=label):
                with self.assertRaises(LEDGER.LedgerError):
                    LEDGER.select(self.root, REPO, {"pages": [page]})

    def test_a_listing_states_exactly_the_fields_a_listing_has(self):
        for raw in ({"pages": [], "limit": 2}, {}, [], "pages"):
            with self.subTest(listing=raw):
                with self.assertRaises(LEDGER.LedgerError):
                    LEDGER.select(self.root, REPO, raw)

    def test_a_listing_refusal_names_the_listing_rather_than_the_ledger(self):
        # The listing and the ledger are held to the same strictness and are
        # two different documents. A refusal that told its caller what "a
        # ledger states", or that an unknown field would be dropped by a write
        # that never happens to a listing, would send them to the one that is
        # fine.
        missing = {
            "a merged-pull-request listing": {},
            "a listing page": {"pages": [{"page": 1, "limit": 2}]},
            "a listed pull request": {
                "pages": [{"page": 1, "limit": 2, "prs": [{"number": 612, "title": "t"}]}]
            },
        }
        for subject, raw in missing.items():
            with self.subTest(subject=subject, refusal="a field left out"):
                with self.assertRaises(LEDGER.LedgerError) as raised:
                    LEDGER.select(self.root, REPO, raw)
                self.assertIn(f"{subject} states every one of", str(raised.exception))
        unknown = (
            {"pages": [], "limit": 2},
            {"pages": [{"page": 1, "limit": 2, "prs": [], "hasNextPage": False}]},
            {
                "pages": [
                    {
                        "page": 1,
                        "limit": 2,
                        "prs": [dict(merged(612), author="someone")],
                    }
                ]
            },
        )
        for raw in unknown:
            with self.subTest(refusal="a field it cannot read"):
                with self.assertRaises(LEDGER.LedgerError) as raised:
                    LEDGER.select(self.root, REPO, raw)
                self.assertIn(
                    LEDGER.LISTING_UNKNOWN_FIELD_COST, str(raised.exception)
                )

    def test_a_ledger_refusal_still_names_the_ledger(self):
        # The non-vacuity control for the two subjects above: the ledger keeps
        # its own wording, so "the listing names the listing" is a property of
        # the parameter rather than of one message that fits both.
        payload = valid_payload({"602": completed_row()})
        del payload["repositories"][REPO]["rows"]["602"]["status"]
        with self.assertRaises(LEDGER.LedgerError) as raised:
            self.parse(payload)
        self.assertIn("a ledger states every one of", str(raised.exception))
        payload = valid_payload({"602": dict(completed_row(), verdict="ok")})
        with self.assertRaises(LEDGER.LedgerError) as raised:
            self.parse(payload)
        self.assertIn(LEDGER.LEDGER_UNKNOWN_FIELD_COST, str(raised.exception))

    def test_a_pull_request_listed_twice_is_refused(self):
        self.refuses(
            [
                {"page": 1, "limit": 1, "prs": [merged(612)]},
                {"page": 2, "limit": 1, "prs": [merged(612)]},
                {"page": 3, "limit": 1, "prs": []},
            ],
            "named",
        )

    def test_a_listed_pull_request_names_a_real_merge_time(self):
        for label, entry in (
            ("no merge time", dict(merged(612), merged_at=None)),
            ("a merge time that is not a timestamp", dict(merged(612), merged_at="yesterday")),
            ("a merge time that is not a date", dict(merged(612), merged_at="2026-02-30T00:00:00Z")),
            ("a local merge time", dict(merged(612), merged_at="2026-09-05T10:00:00")),
        ):
            with self.subTest(entry=label):
                with self.assertRaises(LEDGER.LedgerError):
                    LEDGER.select(
                        self.root, REPO, {"pages": [{"page": 1, "limit": 2, "prs": [entry]}]}
                    )

    def test_a_listed_title_is_one_line_of_text(self):
        for label, title in (
            ("a title that is not a string", 612),
            ("a title carrying a line break", "two\nlines"),
            ("a title carrying a line separator", "two\u2028lines"),
            ("a title carrying a control character", "bell\x07"),
        ):
            with self.subTest(title=label):
                with self.assertRaises(LEDGER.LedgerError):
                    LEDGER.select(
                        self.root,
                        REPO,
                        {"pages": [{"page": 1, "limit": 2, "prs": [merged(612, title=title)]}]},
                    )

    def test_a_listed_number_is_a_pull_request_number(self):
        for label, number in (
            ("zero", 0),
            ("negative", -1),
            ("a boolean", True),
            ("a float", 612.0),
            ("a string", "612"),
            ("longer than a row key is read back under", 10 ** LEDGER.DIGIT_LIMIT),
        ):
            with self.subTest(number=label):
                with self.assertRaises(LEDGER.LedgerError):
                    LEDGER.select(
                        self.root,
                        REPO,
                        {
                            "pages": [
                                {
                                    "page": 1,
                                    "limit": 2,
                                    "prs": [merged(number, at="2026-09-05T10:00:00Z")],
                                }
                            ]
                        },
                    )

    def test_a_refused_listing_leaves_the_ledger_byte_for_byte_as_it_was(self):
        # Every refusal, not just the first one a listing can hit: the whole
        # listing is proven before a row is written, so a page that is fine
        # before a page that is not still records nothing.
        self.select([merged(612), merged(610)])
        path = LEDGER.document_path(self.root)
        before = path.read_bytes()
        cases = {
            "a final page at its own limit": [
                {"page": 1, "limit": 2, "prs": [merged(612), merged(610)]}
            ],
            "a malformed merge time on a later page": [
                {"page": 1, "limit": 1, "prs": [merged(612)]},
                {"page": 2, "limit": 1, "prs": [dict(merged(610), merged_at="soon")]},
                {"page": 3, "limit": 1, "prs": []},
            ],
            "a pull request listed twice": [
                {"page": 1, "limit": 3, "prs": [merged(612), merged(610), merged(612)]}
            ],
            "a page that does not follow the one before it": [
                {"page": 1, "limit": 1, "prs": [merged(612)]},
                {"page": 3, "limit": 1, "prs": []},
            ],
            "a walk that changed its page size": [
                {"page": 1, "limit": 2, "prs": [merged(612), merged(610)]},
                {"page": 2, "limit": 4, "prs": [merged(602)]},
            ],
        }
        for label, pages in cases.items():
            with self.subTest(listing=label):
                with self.assertRaises(LEDGER.LedgerError):
                    LEDGER.select(self.root, REPO, {"pages": pages})
                self.assertEqual(path.read_bytes(), before)

    def test_a_ledger_resolving_outside_the_root_is_not_written_through(self):
        # The reach this module declares is "files under --root", and a
        # selection writes where a migration only read.
        outside = tempfile.TemporaryDirectory(prefix="project-review-outside-")
        self.addCleanup(outside.cleanup)
        directory = tempfile.TemporaryDirectory(prefix="project-review-root-")
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        (root / "docs").mkdir()
        (root / "docs" / "project_review").symlink_to(outside.name)
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.select(root, REPO, listing([merged(612)]))
        self.assertIn("outside", str(raised.exception))


class ResultSchemaTests(SelectionTestCase):
    """The object a caller parses, in both of the states it is emitted in."""

    INVENTORY_KEYS = {
        "pages",
        "listed",
        "added",
        "refreshed",
        "excluded",
        "counts",
        "retained_absent",
    }

    def test_a_selection_states_its_choice_its_queue_and_its_inventory(self):
        self.establish({})
        result = self.select([merged(612), merged(610)])
        self.assertEqual(
            set(result), {"status", "repo", "document", "selected", "queue", "inventory"}
        )
        self.assertEqual(result["repo"], REPO)
        self.assertEqual(result["document"], str(LEDGER.document_path(self.root)))
        self.assertEqual(
            set(result["selected"]), {"number", "title", "merged_at", "row_status"}
        )
        self.assertEqual(set(result["queue"]), {"name", "size"})
        self.assertEqual(set(result["inventory"]), self.INVENTORY_KEYS)
        self.assertEqual(set(result["inventory"]["counts"]), set(LEDGER.ROW_STATUSES))

    def test_the_no_selectable_row_state_carries_the_same_object(self):
        # The same keys, so a caller reads one shape and branches on `status`
        # rather than discovering which fields a second state happens to have.
        self.establish({}, excluded=[612])
        result = self.select([merged(612)])
        self.assertEqual(result["status"], "no-selectable-row")
        self.assertEqual(
            set(result), {"status", "repo", "document", "selected", "queue", "inventory"}
        )
        self.assertIsNone(result["selected"])
        self.assertIsNone(result["queue"])
        self.assertEqual(set(result["inventory"]), self.INVENTORY_KEYS)

    def test_every_reported_queue_name_is_one_the_module_declares(self):
        declared = {
            LEDGER.QUEUE_NEVER_REVIEWED,
            LEDGER.QUEUE_LEGACY,
            LEDGER.QUEUE_REFRESH,
        }
        entries = [merged(612), merged(610), merged(602)]
        seen = set()
        for excluded in ([], [612], [612, 610]):
            self.establish(
                {
                    "612": row("never-reviewed", merged_at=merge_time(612)),
                    "610": row(
                        "legacy", evidence=["cursor:docs/project_review_boundaries.md"]
                    ),
                    "602": self.clean("2026-09-05T00:00:00Z"),
                },
                excluded=excluded,
            )
            seen.add(self.select(entries)["queue"]["name"])
        self.assertEqual(seen, declared)


class SchemaUpgradeTests(SelectionTestCase):
    """A ledger the previous release wrote is opened, not stranded."""

    def previous_release(self):
        path = LEDGER.document_path(self.root)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(PREVIOUS_RELEASE_LEDGER, encoding="utf-8")
        return path

    def test_a_ledger_from_the_previous_release_reads_into_the_current_shape(self):
        state = LEDGER.state_for(
            LEDGER.parse_document(PREVIOUS_RELEASE_LEDGER, "previous release"), REPO
        )
        self.assertEqual(
            {key: value["status"] for key, value in state["rows"].items()},
            {"612": "clean", "610": "legacy", "602": "never-reviewed"},
        )
        for key in state["rows"]:
            with self.subTest(row=key):
                # Absent, not invented: the older writer had no listing to take
                # either from, and the next one supplies both.
                self.assertIsNone(state["rows"][key]["title"])
                self.assertIsNone(state["rows"][key]["merged_at"])
        self.assertEqual(state["rows"]["610"]["evidence"], [
            "cursor:docs/project_review_boundaries.md"
        ])
        self.assertEqual(state["rows"]["612"]["completed_at"], "2026-09-05T11:22:33Z")

    def test_a_read_of_an_older_ledger_reports_the_current_version(self):
        document = LEDGER.parse_document(PREVIOUS_RELEASE_LEDGER, "previous release")
        self.assertEqual(document["version"], LEDGER.SCHEMA_VERSION)

    def test_a_selection_upgrades_a_previous_release_ledger_without_losing_it(self):
        path = self.previous_release()
        result = self.select([merged(612), merged(610), merged(602)])
        rows = self.rows_on_disk()
        self.assertEqual(
            {key: value["status"] for key, value in rows.items()},
            {"612": "clean", "610": "legacy", "602": "never-reviewed"},
        )
        self.assertEqual(rows["610"]["title"], "Pull request #610")
        self.assertEqual(rows["610"]["merged_at"], merge_time(610))
        self.assertEqual(
            rows["610"]["evidence"], ["cursor:docs/project_review_boundaries.md"]
        )
        self.assertEqual(rows["612"]["commit"], "a" * 40)
        # #602 is the only never-reviewed row, so the first queue takes it and
        # the legacy row keeps waiting, exactly as it would in a ledger this
        # release had written itself.
        self.assertEqual(result["selected"]["number"], 602)
        self.assertIn(f'"version": {LEDGER.SCHEMA_VERSION}', path.read_text(encoding="utf-8"))

    def test_an_upgraded_ledger_reads_back_as_a_current_one(self):
        self.previous_release()
        self.select([merged(612), merged(610), merged(602)])
        reread = LEDGER.load_document(self.root)
        self.assertEqual(reread["version"], LEDGER.SCHEMA_VERSION)
        self.assertEqual(
            LEDGER.render_document(reread),
            LEDGER.document_path(self.root).read_text(encoding="utf-8"),
        )

    def test_a_current_document_still_states_every_row_field(self):
        # The control the upgrade needs: it is keyed on the version the
        # document declares, not on "a missing field is fine". A version 2
        # document that leaves one out is the truncated edit `_require_keys`
        # exists to refuse.
        for field in ("title", "merged_at"):
            with self.subTest(field=field):
                payload = valid_payload({"602": completed_row()})
                del payload["repositories"][REPO]["rows"]["602"][field]
                with self.assertRaises(LEDGER.LedgerError) as raised:
                    self.parse(payload)
                self.assertIn(f"declares no {field}", str(raised.exception))

    def test_a_schema_version_this_helper_does_not_read_is_refused(self):
        for version in (0, LEDGER.SCHEMA_VERSION + 1, -1):
            with self.subTest(version=version):
                payload = valid_payload({"602": completed_row()})
                payload["version"] = version
                with self.assertRaises(LEDGER.LedgerError) as raised:
                    self.parse(payload)
                self.assertIn("schema version", str(raised.exception))

    def test_an_older_row_that_already_carries_the_newer_fields_is_validated(self):
        # The upgrade supplies only what the older shape genuinely lacks, so a
        # version 1 document a hand edit gave a title to is still held to what
        # a title has to be rather than having it replaced by a default.
        payload = valid_payload({"602": dict(completed_row(), title=612)})
        payload["version"] = 1
        with self.assertRaises(LEDGER.LedgerError) as raised:
            self.parse(payload)
        self.assertIn("not a pull-request title", str(raised.exception))


class ReconciliationTests(SelectionTestCase):
    """The listing says what exists; the ledger says what was done about it."""

    def test_a_listed_pull_request_with_no_row_gains_a_never_reviewed_one(self):
        self.establish({"612": self.clean("2026-09-05T11:22:33Z")})
        result = self.select([merged(612), merged(610)])
        rows = self.rows_on_disk()
        self.assertEqual(rows["610"]["status"], "never-reviewed")
        self.assertEqual(rows["610"]["title"], "Pull request #610")
        self.assertEqual(rows["610"]["merged_at"], merge_time(610))
        self.assertEqual(result["inventory"]["added"], [610])
        self.assertEqual(result["inventory"]["refreshed"], [612])

    def test_an_existing_row_keeps_its_review_and_takes_the_listing_metadata(self):
        # The case design D-9 leaves behind: a row imported from a report
        # predates every listing, so the first inventory is where it learns
        # what its pull request is called and when it merged. Learning that
        # must not cost it the coverage it was imported with.
        self.migrated(reviewed=[602, 601], boundary=533)
        before = self.rows_on_disk()["602"]
        self.assertEqual(before["status"], "legacy")
        self.assertIsNone(before["title"])
        self.select([merged(602, title="The imported one"), merged(601)])
        after = self.rows_on_disk()["602"]
        self.assertEqual(after["status"], "legacy")
        self.assertEqual(after["title"], "The imported one")
        self.assertEqual(after["merged_at"], merge_time(602))
        self.assertEqual(after["evidence"], before["evidence"])
        self.assertEqual(after["history"], before["history"])

    def test_a_completed_row_keeps_every_field_a_review_wrote(self):
        established = self.establish(
            {
                "612": self.findings(
                    "2026-09-05T11:22:33Z",
                    evidence=["review:2026-09-05"],
                    history=[
                        {
                            "kind": "review",
                            "outcome": "clean",
                            "commit": FULL_SHA,
                            "completed_at": "2026-09-01T00:00:00Z",
                            "report": None,
                        }
                    ],
                )
            }
        )
        self.select([merged(612)])
        after = self.rows_on_disk()["612"]
        for field in ("status", "commit", "completed_at", "report", "evidence", "history"):
            with self.subTest(field=field):
                self.assertEqual(after[field], established["rows"]["612"][field])

    def test_a_row_the_listing_does_not_name_is_kept_and_reported(self):
        self.establish(
            {
                "612": self.clean("2026-09-05T11:22:33Z"),
                "610": row("legacy", evidence=["cursor:docs/project_review_boundaries.md"]),
            }
        )
        result = self.select([merged(612)])
        self.assertIn("610", self.rows_on_disk())
        self.assertEqual(
            result["inventory"]["retained_absent"],
            [
                {
                    "number": 610,
                    # Nothing invented for a row no listing has ever named:
                    # the ledger knows its number and its coverage and says
                    # only that.
                    "title": None,
                    "merged_at": None,
                    "row_status": "legacy",
                }
            ],
        )

    def test_a_retained_row_is_not_selected_while_the_listing_omits_it(self):
        self.establish(
            {
                "612": self.clean("2026-09-05T11:22:33Z"),
                "610": row("never-reviewed", merged_at=merge_time(610)),
            }
        )
        self.assertEqual(self.selected([merged(612)]), 612)
        self.assertEqual(self.selected([merged(612), merged(610)]), 610)

    def test_a_row_the_ledger_lost_comes_back_as_never_reviewed(self):
        # Losing a row loses its history, which is the cost of losing it; what
        # must not happen is the pull request quietly staying out of the
        # schedule because nothing remembers it exists.
        self.establish({"612": self.clean("2026-09-05T11:22:33Z")})
        result = self.select([merged(612), merged(610)])
        self.assertEqual(result["selected"]["number"], 610)
        self.assertEqual(result["selected"]["row_status"], "never-reviewed")


class QueueOrderTests(SelectionTestCase):
    """Design D-8's three queues, in order, over a listing that names them all."""

    def test_the_never_reviewed_queue_takes_the_newest_merge_first(self):
        self.establish({})
        result = self.select([merged(602), merged(612), merged(610)])
        self.assertEqual(result["selected"]["number"], 612)
        self.assertEqual(result["queue"], {"name": "never-reviewed", "size": 3})

    def test_a_never_reviewed_tie_is_broken_by_the_higher_number(self):
        # Two pull requests merged in the same second: the order still has to
        # be total, or the choice depends on the order the pages arrived in.
        self.establish({})
        same = "2026-09-05T10:00:00Z"
        result = self.select([merged(610, at=same), merged(612, at=same)])
        self.assertEqual(result["selected"]["number"], 612)

    def test_the_legacy_queue_takes_the_highest_number_first(self):
        # Numbers explicitly, not merge dates: D-8 records the owner choosing
        # that distinction, so the fixture merges the lower number later.
        self.migrated(reviewed=[602, 612])
        result = self.select(
            [merged(602, at="2026-09-09T00:00:00Z"), merged(612, at="2026-09-01T00:00:00Z")]
        )
        self.assertEqual(result["selected"]["number"], 612)
        self.assertEqual(result["queue"], {"name": "legacy", "size": 2})

    def test_the_refresh_queue_takes_the_oldest_completed_review_first(self):
        # Clean and findings-bearing rows in one queue (D-4): a review with
        # findings is a completed attempt, so it waits its turn behind older
        # attempts instead of monopolizing the schedule.
        self.establish(
            {
                "612": self.clean("2026-09-05T00:00:00Z"),
                "610": self.findings("2026-09-03T00:00:00Z"),
                "602": self.clean("2026-09-04T00:00:00Z"),
            }
        )
        result = self.select([merged(612), merged(610), merged(602)])
        self.assertEqual(result["selected"]["number"], 610)
        self.assertEqual(result["queue"], {"name": "refresh", "size": 3})

    def test_a_refresh_tie_is_broken_by_the_lower_number(self):
        same = "2026-09-05T00:00:00Z"
        self.establish({"612": self.clean(same), "610": self.clean(same)})
        self.assertEqual(self.selected([merged(612), merged(610)]), 610)

    def test_the_last_never_reviewed_row_empties_the_first_queue(self):
        rows = {
            "612": row("never-reviewed", merged_at=merge_time(612)),
            "610": row("legacy", evidence=["cursor:docs/project_review_boundaries.md"]),
        }
        self.establish(rows)
        self.assertEqual(self.selected([merged(612), merged(610)]), 612)
        self.establish(dict(rows, **{"612": self.clean("2026-09-05T00:00:00Z")}))
        result = self.select([merged(612), merged(610)])
        self.assertEqual(result["selected"]["number"], 610)
        self.assertEqual(result["queue"]["name"], "legacy")

    def test_converting_the_last_legacy_row_empties_the_second_queue(self):
        legacy = row("legacy", evidence=["cursor:docs/project_review_boundaries.md"])
        self.establish({"612": self.clean("2026-09-05T00:00:00Z"), "610": legacy})
        self.assertEqual(self.selected([merged(612), merged(610)]), 610)
        self.establish(
            {
                "612": self.clean("2026-09-05T00:00:00Z"),
                "610": self.findings("2026-09-06T00:00:00Z"),
            }
        )
        result = self.select([merged(612), merged(610)])
        self.assertEqual(result["selected"]["number"], 612)
        self.assertEqual(result["queue"]["name"], "refresh")

    def test_a_newly_merged_pull_request_outranks_conversion_and_refresh(self):
        # Priority is reevaluated on every invocation (D-8), so a pull request
        # that merged while the legacy queue was being worked does not wait
        # for that queue to empty.
        self.establish(
            {
                "612": self.clean("2026-09-05T00:00:00Z"),
                "610": row("legacy", evidence=["cursor:docs/project_review_boundaries.md"]),
            }
        )
        self.assertEqual(self.selected([merged(612), merged(610)]), 610)
        result = self.select([merged(612), merged(610), merged(613)])
        self.assertEqual(result["selected"]["number"], 613)
        self.assertEqual(result["queue"]["name"], "never-reviewed")

    def test_a_completed_review_is_not_selected_ahead_of_an_older_one(self):
        # With a stable inventory the schedule moves forward: the pull request
        # just reviewed goes to the back, and the one that has waited longest
        # comes next (D-4).
        self.establish(
            {
                "612": self.clean("2026-09-05T00:00:00Z"),
                "610": self.clean("2026-09-04T00:00:00Z"),
                "602": self.clean("2026-09-03T00:00:00Z"),
            }
        )
        entries = [merged(612), merged(610), merged(602)]
        self.assertEqual(self.selected(entries), 602)
        self.establish(
            {
                "612": self.clean("2026-09-05T00:00:00Z"),
                "610": self.clean("2026-09-04T00:00:00Z"),
                "602": self.clean("2026-09-06T00:00:00Z"),
            }
        )
        self.assertEqual(self.selected(entries), 610)

    def test_selection_is_a_function_of_the_ledger_and_the_listing(self):
        self.establish({})
        entries = [merged(612), merged(610), merged(602)]
        first = self.select(entries)
        second = self.select(list(reversed(entries)))
        self.assertEqual(first["selected"], second["selected"])
        self.assertEqual(first["queue"], second["queue"])

    def test_the_only_merged_pull_request_repeats_in_the_refresh_queue(self):
        # A one-pull-request repository necessarily repeats it (D-4), and the
        # result says which queue that came from so a caller can tell a repeat
        # from a first review.
        self.establish({"612": self.clean("2026-09-05T00:00:00Z")})
        result = self.select([merged(612)])
        self.assertEqual(result["selected"]["number"], 612)
        self.assertEqual(result["selected"]["row_status"], "clean")
        self.assertEqual(result["queue"], {"name": "refresh", "size": 1})


class ExclusionAndEmptinessTests(SelectionTestCase):
    """What the repository has taken out of scope, and what is left."""

    def excluded_ledger(self, rows):
        return self.establish(rows, excluded=[610])

    def test_an_excluded_pull_request_is_never_selected_in_any_queue(self):
        cases = {
            "never-reviewed": row("never-reviewed", merged_at=merge_time(610)),
            "legacy": row("legacy", evidence=["cursor:docs/project_review_boundaries.md"]),
            "clean": self.clean("2026-09-01T00:00:00Z"),
            "findings": self.findings("2026-09-01T00:00:00Z"),
        }
        for status, excluded_row in cases.items():
            with self.subTest(queue=status):
                directory = tempfile.TemporaryDirectory(prefix="project-review-root-")
                self.addCleanup(directory.cleanup)
                root = Path(directory.name)
                (root / "docs").mkdir()
                self.establish(
                    {"610": excluded_row, "602": self.clean("2026-09-09T00:00:00Z")},
                    excluded=[610],
                    root=root,
                )
                result = self.select([merged(610), merged(602)], root=root)
                self.assertEqual(result["selected"]["number"], 602)
                self.assertEqual(result["inventory"]["excluded"], [610])

    def test_a_queue_size_counts_only_what_it_could_have_selected(self):
        self.excluded_ledger(
            {
                "612": row("never-reviewed", merged_at=merge_time(612)),
                "610": row("never-reviewed", merged_at=merge_time(610)),
            }
        )
        result = self.select([merged(612), merged(610)])
        self.assertEqual(result["queue"], {"name": "never-reviewed", "size": 1})

    def test_the_inventory_counts_cover_every_listed_row_including_excluded_ones(self):
        self.excluded_ledger(
            {
                "612": self.clean("2026-09-05T00:00:00Z"),
                "610": row("legacy", evidence=["cursor:docs/project_review_boundaries.md"]),
            }
        )
        result = self.select([merged(612), merged(610), merged(602)])
        self.assertEqual(
            result["inventory"]["counts"],
            {"clean": 1, "findings": 0, "legacy": 1, "never-reviewed": 1},
        )
        self.assertEqual(result["inventory"]["listed"], 3)

    def test_a_repository_with_nothing_selectable_says_so_rather_than_refusing(self):
        # A distinct successful state, not a refusal: there is nothing wrong
        # with the listing or the ledger, and a caller that retried this as a
        # failure would retry it unchanged forever.
        self.excluded_ledger({"610": row("never-reviewed", merged_at=merge_time(610))})
        result = self.select([merged(610)])
        self.assertEqual(result["status"], "no-selectable-row")
        self.assertIsNone(result["selected"])
        self.assertIsNone(result["queue"])
        self.assertEqual(result["inventory"]["counts"]["never-reviewed"], 1)

    def test_the_listing_is_recorded_even_when_nothing_is_selectable(self):
        # The universe is what the listing says it is whether or not anything
        # in it can be reviewed, so the next invocation starts from the rows
        # this one recorded rather than discovering them again.
        self.establish({}, excluded=[610, 602])
        result = self.select([merged(610), merged(602)])
        self.assertEqual(result["status"], "no-selectable-row")
        self.assertEqual(set(self.rows_on_disk()), {"610", "602"})
        self.assertEqual(result["inventory"]["excluded"], [602, 610])


class SelectionRefusalTests(SelectionTestCase):
    """A selection needs a ledger a migration established, not one it invents."""

    def test_a_selection_without_a_ledger_refuses_rather_than_establishing_one(self):
        # `migrate` refuses to run over an existing ledger, so a selection
        # that created one would record every merged pull request as
        # never-reviewed and close the only door legacy coverage comes
        # through.
        with self.assertRaises(LEDGER.LedgerError) as raised:
            self.select([merged(612)])
        self.assertIn("holds no ledger", str(raised.exception))
        self.assertFalse(LEDGER.document_path(self.root).exists())

    def test_a_selection_for_a_repository_the_ledger_does_not_name_is_refused(self):
        self.establish({})
        path = LEDGER.document_path(self.root)
        before = path.read_bytes()
        with self.assertRaises(LEDGER.LedgerError) as raised:
            self.select([merged(612)], repo="coghex/other")
        self.assertIn("holds no entry for coghex/other", str(raised.exception))
        self.assertEqual(path.read_bytes(), before)

    def test_a_repository_identity_that_is_not_owner_name_is_refused(self):
        self.establish({})
        with self.assertRaises(LEDGER.LedgerError) as raised:
            self.select([merged(612)], repo="kanban")
        self.assertIn("owner/name", str(raised.exception))

    def test_a_ledger_this_helper_cannot_read_is_not_an_absent_one(self):
        path = LEDGER.document_path(self.root)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("# Not a ledger\n", encoding="utf-8")
        with self.assertRaises(LEDGER.LedgerError) as raised:
            self.select([merged(612)])
        self.assertIn("not a project-review ledger", str(raised.exception))

    def test_another_repository_entry_survives_a_selection(self):
        document = LEDGER.empty_document()
        for name in (REPO, "coghex/other"):
            document["repositories"][name] = LEDGER.empty_repository()
        document["repositories"]["coghex/other"]["rows"]["7"] = row(
            "legacy", evidence=["cursor:docs/project_review_boundaries.md"]
        )
        LEDGER.create_document(self.root, document)
        self.select([merged(612)])
        reread = LEDGER.load_document(self.root)
        self.assertEqual(
            set(reread["repositories"]["coghex/other"]["rows"]), {"7"}
        )
        self.assertEqual(set(reread["repositories"][REPO]["rows"]), {"612"})


# --------------------------------------------------------------------------
# The command line


class CommandLineTests(LedgerTestCase):
    """Three outcomes, three exit codes, one JSON shape."""

    def run_module(self, *argv, stdin=None):
        return subprocess.run(
            [sys.executable, str(REPO_ROOT / CLAUDE_LEDGER_HELPER), *argv],
            capture_output=True,
            text=True,
            input=stdin,
            stdin=None if stdin is not None else subprocess.DEVNULL,
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

    def test_a_selection_exits_zero_with_its_choice_on_stdout(self):
        self.run_module("migrate", "--root", str(self.root), "--repo", REPO)
        pages = json.dumps(listing([merged(612), merged(610)]))
        result = self.run_module(
            "select", "--root", str(self.root), "--repo", REPO, stdin=pages
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        reported = json.loads(result.stdout)
        self.assertEqual(reported["status"], "selected")
        self.assertEqual(reported["selected"]["number"], 612)

    def test_a_selection_with_nothing_to_review_still_exits_zero(self):
        self.run_module("migrate", "--root", str(self.root), "--repo", REPO)
        result = self.run_module(
            "select",
            "--root",
            str(self.root),
            "--repo",
            REPO,
            stdin=json.dumps(listing([])),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        reported = json.loads(result.stdout)
        self.assertEqual(reported["status"], "no-selectable-row")
        self.assertIsNone(reported["selected"])

    def test_a_refused_listing_exits_two_with_nothing_on_stdout(self):
        # A caller parses stdout only on exit 0, so a refusal that printed a
        # partial object there would be parsed as a selection.
        self.run_module("migrate", "--root", str(self.root), "--repo", REPO)
        full = {"pages": [{"page": 1, "limit": 1, "prs": [merged(612)]}]}
        result = self.run_module(
            "select", "--root", str(self.root), "--repo", REPO, stdin=json.dumps(full)
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("the next page is needed", result.stderr)

    def test_a_listing_this_command_cannot_read_is_refused(self):
        self.run_module("migrate", "--root", str(self.root), "--repo", REPO)
        for label, stdin in (
            ("nothing at all", ""),
            ("whitespace", "   \n"),
            ("text that is not JSON", "not json"),
            ("a repeated key", '{"pages": [], "pages": []}'),
        ):
            with self.subTest(stdin=label):
                result = self.run_module(
                    "select", "--root", str(self.root), "--repo", REPO, stdin=stdin
                )
                self.assertEqual(result.returncode, 2)
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

    def test_a_confirmation_naming_a_non_ascii_digit_is_refused(self):
        # `str.isdigit()` is true of "²" and `int()` raises on it, so the
        # check that was meant to refuse this left a traceback instead.
        with self.assertRaises(LEDGER.LedgerError):
            LEDGER._confirmation("docs/project_review_12-11.md=#\u00b2")

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


class FilesystemTests(LedgerTestCase):
    """Where this module reads and writes, and what it does when it cannot."""

    def test_a_report_resolving_outside_the_root_is_refused(self):
        # Joining a relative path to `--root` is lexical, and every read below
        # follows symlinks, so a report pointing out of the worktree was read
        # and its pull requests imported.
        outside = tempfile.TemporaryDirectory(prefix="project-review-outside-")
        self.addCleanup(outside.cleanup)
        target = Path(outside.name) / "project_review_12-11.md"
        target.write_text(
            "# Project Review Findings: PRs #12–#11\n\n"
            "This review covered the two newest merged pull requests at the "
            "frozen selection boundary, in merge-time order: #12 and #11.\n",
            encoding="utf-8",
        )
        os.symlink(target, self.root / "docs" / "project_review_12-11.md")
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.migrate(self.root, REPO)
        self.assertIn("outside", str(raised.exception))
        self.assertFalse(LEDGER.document_path(self.root).exists())

    def test_a_confirmation_does_not_excuse_a_report_from_its_path_checks(self):
        # The confirmation branch ran before the confinement check and the
        # read, so a confirmed path that was a symlink out of the worktree, a
        # link with nothing behind it, or a directory became a row's evidence
        # -- evidence nobody can go and check, which is the one thing a legacy
        # row is for.
        outside = tempfile.TemporaryDirectory(prefix="project-review-outside-")
        self.addCleanup(outside.cleanup)
        elsewhere = Path(outside.name) / "elsewhere.md"
        elsewhere.write_text("# Elsewhere\n\nprose\n", encoding="utf-8")
        name = "project_review_12-11.md"
        for label, make in (
            ("a symlink out of the root", lambda target: os.symlink(elsewhere, target)),
            ("a link with nothing behind it",
             lambda target: os.symlink(self.root / "docs" / "nothing.md", target)),
            ("a directory", lambda target: target.mkdir()),
        ):
            with self.subTest(report=label):
                directory = tempfile.TemporaryDirectory(prefix="project-review-root-")
                self.addCleanup(directory.cleanup)
                root = Path(directory.name)
                (root / "docs").mkdir()
                make(root / "docs" / name)
                with self.assertRaises(LEDGER.LedgerError):
                    LEDGER.migrate(root, REPO, {f"docs/{name}": [12, 11]})
                self.assertFalse(LEDGER.document_path(root).exists())

    def test_a_ledger_resolving_outside_the_root_is_refused(self):
        outside = tempfile.TemporaryDirectory(prefix="project-review-outside-")
        self.addCleanup(outside.cleanup)
        (self.root / "docs" / "project_review").symlink_to(outside.name)
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.load_document(self.root)
        self.assertIn("outside", str(raised.exception))

    def test_provenance_and_coverage_come_from_one_snapshot_of_the_cursor(self):
        # The migration read the cursor twice -- once to classify its shape,
        # once to parse its state -- and the cursor's writer publishes by
        # atomic replacement. A replacement landing between the two made the
        # two halves describe different documents, and the ledger is written
        # once and cannot be corrected.
        #
        # Driven deterministically: the record is replaced by a hand-authored
        # one the instant it is first read. Under a second read the state
        # would come from that replacement -- #533 imported as reviewed off a
        # `legacy-exclusive-boundary` endpoint while the provenance still said
        # cursor-v2. Under one read the replacement cannot be seen at all.
        record_cursor(self.root, reviewed=[602, 601], boundary=533)
        cursor_path = CURSOR.document_path(self.root)
        replacement = (
            "# Project review boundaries\n\n"
            "- `coghex/kanban` — stop before PR #533\n"
        )
        reads = []
        original = Path.read_text

        def read_once(self_path, *args, **kwargs):
            content = original(self_path, *args, **kwargs)
            if Path(self_path) == cursor_path:
                reads.append(str(self_path))
                cursor_path.write_text(replacement, encoding="utf-8")
            return content

        Path.read_text = read_once
        try:
            result = LEDGER.migrate(self.root, REPO)
        finally:
            Path.read_text = original

        self.assertEqual(len(reads), 1, "the record is read once, not twice")
        self.assertEqual(result["cursor"]["source"], "cursor-v2")
        self.assertEqual(self.rows_of(result["state"]), {602, 601})
        self.assertIsNone(result["state"]["migration"]["withheld_boundary"])
        self.assertNotEqual(
            result["state"]["migration"]["boundary"]["merged_at"],
            "legacy-exclusive-boundary",
        )

    def test_two_migrations_racing_cannot_both_create_the_ledger(self):
        # A look-then-write let both pass `exists()`, both reach the write,
        # and the second replace the first. Creation is one operation now.
        record_cursor(self.root, reviewed=[602])
        outcomes = []
        barrier = threading.Barrier(2)

        def migrate(repo):
            barrier.wait()
            try:
                outcomes.append((repo, LEDGER.migrate(self.root, repo)["status"]))
            except LEDGER.LedgerError:
                outcomes.append((repo, "refused"))

        threads = [
            threading.Thread(target=migrate, args=(repo,))
            for repo in (REPO, OTHER_REPO)
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        statuses = sorted(status for _, status in outcomes)
        self.assertEqual(statuses, ["migrated", "refused"])
        written = LEDGER.load_document(self.root)["repositories"]
        self.assertEqual(len(written), 1)
        # ... and the one that won is the one in the document.
        winner = next(repo for repo, status in outcomes if status == "migrated")
        self.assertEqual(list(written), [winner])

    def test_an_unreadable_ledger_is_not_an_absent_one(self):
        # `Path.exists()` answers false both for a name nothing holds and for
        # one it could not look up, so a ledger under a directory with no
        # search permission read as a repository that had never been migrated.
        record_cursor(self.root, reviewed=[602])
        LEDGER.migrate(self.root, REPO)
        directory = self.root / "docs" / "project_review"
        mode = directory.stat().st_mode
        os.chmod(directory, 0o000)
        self.addCleanup(os.chmod, directory, mode)
        if os.access(directory / "ledger.md", os.R_OK):
            self.skipTest("this user can read through a mode-000 directory")
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.load_document(self.root)
        self.assertIn("not an absent one", str(raised.exception))

    def test_an_unlistable_docs_directory_is_not_an_empty_one(self):
        # ... and the same for report discovery, which walks a glob whose
        # errors are silent: a migration over an unreadable `docs/` reported
        # no reports and wrote an empty ledger.
        write_report(self.root, "project_review_432-412.md", ABOVE_INTERVAL_REPORT)
        directory = self.root / "docs"
        mode = directory.stat().st_mode
        os.chmod(directory, 0o300)
        self.addCleanup(os.chmod, directory, mode)
        if os.access(directory, os.R_OK):
            self.skipTest("this user can list a mode-300 directory")
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.migrate(self.root, REPO)
        self.assertIn("could not be listed", str(raised.exception))

    def test_a_dangling_ledger_symlink_is_not_a_free_name(self):
        # `exists()` answers false for a symlink with nothing behind it, and a
        # migration that believed the name free would then fail to create it.
        directory = self.root / "docs" / "project_review"
        directory.mkdir(parents=True)
        (directory / "ledger.md").symlink_to(self.root / "docs" / "nothing.md")
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.migrate(self.root, REPO)
        self.assertIn("already exists", str(raised.exception))

    def test_bytes_that_are_not_utf_8_are_refused_rather_than_raised(self):
        # `UnicodeDecodeError` is a `ValueError`, not an `OSError`, so a
        # document holding bytes that are not UTF-8 left a traceback where the
        # refusal belongs -- and the CLI exited 1 instead of 2.
        directory = self.root / "docs" / "project_review"
        directory.mkdir(parents=True)
        (directory / "ledger.md").write_bytes(b"\xff\xfe not utf-8")
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.load_document(self.root)
        self.assertIn("not an absent one", str(raised.exception))

    def test_a_record_or_report_that_is_not_utf_8_stops_the_migration(self):
        (self.root / "docs" / "project_review_boundaries.md").write_bytes(b"\xff\xfe")
        with self.assertRaises(LEDGER.LedgerError):
            LEDGER.migrate(self.root, REPO)
        (self.root / "docs" / "project_review_boundaries.md").unlink()
        (self.root / "docs" / "project_review_12-11.md").write_bytes(b"\xff\xfe")
        # ... including on the path a confirmation takes, which reads the
        # report before standing in for this helper's reading of it.
        with self.assertRaises(LEDGER.LedgerError):
            LEDGER.migrate(self.root, REPO, {"docs/project_review_12-11.md": [12, 11]})
        self.assertFalse(LEDGER.document_path(self.root).exists())

    def test_a_broken_directory_above_the_ledger_is_not_an_absent_one(self):
        # `read_text` raises the same FileNotFoundError for a ledger behind a
        # broken directory as for one that was never written, and `lstat` on
        # the ledger raises it too -- so a dangling `docs/project_review` read
        # as a repository that had never been migrated, and a migration past
        # it died on `mkdir` with an exception the CLI had no answer for.
        for label, make in (
            ("a dangling project_review",
             lambda root: os.symlink(root / "docs" / "missing", root / "docs" / "project_review")),
            ("a file where project_review goes",
             lambda root: (root / "docs" / "project_review").write_text("x", encoding="utf-8")),
            ("a dangling docs",
             lambda root: os.symlink(root / "missing", root / "docs")),
        ):
            with self.subTest(shape=label):
                directory = tempfile.TemporaryDirectory(prefix="project-review-root-")
                self.addCleanup(directory.cleanup)
                root = Path(directory.name)
                if label != "a dangling docs":
                    (root / "docs").mkdir()
                make(root)
                with self.assertRaises(LEDGER.LedgerError):
                    LEDGER.load_document(root)
                with self.assertRaises(LEDGER.LedgerError):
                    LEDGER.migrate(root, REPO)

    def test_a_dangling_symlink_is_not_an_absent_document(self):
        # `read_text` raises FileNotFoundError both for a name nothing holds
        # and for a link with nothing behind it. Reading the second as "never
        # migrated" loses the state someone put there and broke.
        directory = self.root / "docs" / "project_review"
        directory.mkdir(parents=True)
        (directory / "ledger.md").symlink_to(self.root / "docs" / "nothing.md")
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.load_document(self.root)
        self.assertIn("nothing behind it", str(raised.exception))

    def test_a_dangling_cursor_symlink_stops_the_migration(self):
        # The same read, one document over, and the worse outcome: classified
        # as absent, the migration would have succeeded with an empty ledger
        # and the no-overwrite rule would then refuse to correct it.
        (self.root / "docs" / "project_review_boundaries.md").symlink_to(
            self.root / "docs" / "nothing.md"
        )
        with self.assertRaises(LEDGER.LedgerError) as raised:
            LEDGER.migrate(self.root, REPO)
        self.assertIn("nothing behind it", str(raised.exception))
        self.assertFalse(LEDGER.document_path(self.root).exists())

    def test_a_root_that_genuinely_has_nothing_still_reads_and_migrates(self):
        # The control for all four: absence is still absence.
        self.assertEqual(LEDGER.load_document(self.root), LEDGER.empty_document())
        self.assertEqual(LEDGER.migrate(self.root, REPO)["status"], "migrated")


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
