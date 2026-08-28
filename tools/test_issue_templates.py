"""Contract check for .github/ISSUE_TEMPLATE/.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Issue #434: GitHub's new-issue flow offered no template, so every issue filed
through the web UI arrived shapeless while the drafting workflows each
reproduced the tracker's five-heading shape independently. The two maintainer
templates added alongside this module closed that gap for anyone willing to
write an agent-ready implementation contract.

Issue #537 split the chooser by audience. Three intake templates -- `Bug
report`, `Feature or improvement`, and `Support question` -- ask an outside
reporter only for what they know, and `config.yml` disables blank issues so the
chooser's most inviting option cannot lead away from every shape the pipeline
reads. The maintainer templates keep their tracked paths and bodies and are
presented as `Maintainer issue specification`, `Maintainer epic`, and
`Maintainer release`; only the first two had their chooser wording changed.

The templates are checked rather than trusted because several of their
properties are read as data by something else, and a template that violates one
breaks the pipeline for every issue filed from it:

* `tools/approve_issues.py`'s `ORIGIN_RE` matches an origin marker anywhere in
  an issue body, and `issue_origin` raises when both brands appear. A template
  that spelled the marker while explaining it would mark every issue filed from
  it, or refuse them all. The ordinary template's explanatory comment names
  `issue-origin` in prose and must contain no marker-shaped sequence -- so the
  check here is `issue_origin` itself, run against the complete template file,
  rather than a regex restated in this module. Every other template delegates
  to that explanation instead of keeping a second copy to drift, which is the
  rule `test_only_the_ordinary_template_spells_the_marker_key` holds.
* `src/Kanban/Tracker.hs` parses the epic template's `Children` checklist to
  build the board's tracker hierarchy. `stripCheckbox` (`:200-209`) accepts any
  line whose first non-space character is `-` or `*` followed by `[ ]`, `[x]`,
  or `[X]`, with no awareness of HTML comments, and `findIssueNumber`
  (`:216-231`) reads the first `#N` in what follows. An example item left live
  would therefore attach a real issue to every epic filed from the template.
  Example items stay on single-line comments, which `stripCheckbox` rejects
  because the line starts with `<`.
* Each template's preselected label routes the issue on arrival:
  `claude-plugin/plugins/kanban/commands/triage.md` partitions the queue on the
  exact `bug` label, `src/Kanban/Domain.hs` recognizes a tracker by `epic`, and
  the board filters a release by `release`. `EXPECTED_LABELS` is the one place
  that mapping is written down.
* `config.yml` decides whether the chooser offers a blank issue at all, and
  carries the single contact link that routes a security report privately. It
  is read here with a parser written out in this module, for the reason
  `parse_frontmatter` gives: the rest of this suite takes no YAML dependency,
  and a parser that accepts exactly the documented shape doubles as the
  negative controls the malformed cases need.

An unfilled placeholder checkbox carrying no reference is the intended state:
it yields `TrackerIssueReferenceMissing` and `TrackerChildrenMissing` until the
author lists real children, which is a diagnostic about an empty epic rather
than a wrong one.

The release template's release-safety properties -- the authorization item
arriving unchecked and ahead of the tag item -- are not general template rules,
so they live with the runbook they gate in `tools/test_release_runbook.py`.

The negative controls below run each rule against a synthetic that violates it,
so a rule that matched everything could not pass while asserting nothing.
"""

from __future__ import annotations

import importlib.util
import re
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TEMPLATE_DIR = REPO_ROOT / ".github" / "ISSUE_TEMPLATE"
ORDINARY_TEMPLATE = TEMPLATE_DIR / "issue.md"
EPIC_TEMPLATE = TEMPLATE_DIR / "epic.md"
RELEASE_TEMPLATE = TEMPLATE_DIR / "release.md"
BUG_TEMPLATE = TEMPLATE_DIR / "bug_report.md"
FEATURE_TEMPLATE = TEMPLATE_DIR / "feature_request.md"
SUPPORT_TEMPLATE = TEMPLATE_DIR / "support_question.md"
CHOOSER_CONFIG = TEMPLATE_DIR / "config.yml"

# The three templates an outside reporter is offered. They ask for what a
# reporter knows and for nothing a maintainer would supply later.
INTAKE_TEMPLATES = (BUG_TEMPLATE, FEATURE_TEMPLATE, SUPPORT_TEMPLATE)

# The three written for this repository's agent pipeline, which do ask for
# cited evidence and the exact commands a reviewer runs.
MAINTAINER_TEMPLATES = (ORDINARY_TEMPLATE, EPIC_TEMPLATE, RELEASE_TEMPLATE)

ALL_TEMPLATES = INTAKE_TEMPLATES + MAINTAINER_TEMPLATES

# CLAUDE.md's "Hygiene" section: the shape every issue body in this repository
# takes, in this order. An intake issue keeps it so refining one into a
# maintainer specification is not a structural rewrite (issue #537,
# requirement 4).
REQUIRED_HEADINGS = (
    "Background",
    "Requirements",
    "Acceptance",
    "Out of scope",
    "Related",
)

# GitHub's Markdown issue-template frontmatter keys. A key outside this set is
# ignored silently by GitHub, so a typo would go unnoticed without this.
SUPPORTED_FRONTMATTER_KEYS = frozenset(
    {"name", "about", "title", "labels", "assignees"}
)

# The label Kanban's default tracker configuration recognizes
# (src/Kanban/Domain.hs:526-533). An epic filed without it is not a tracker.
TRACKER_LABEL = "epic"

# The label the release template preselects, which is what the board and the
# backlog filter a release by. It already exists on this repository's tracker;
# the template picks it rather than introducing one (issue #539).
RELEASE_LABEL = "release"

# The labels the intake templates preselect, so an outside reporter is
# categorized on arrival without a maintainer pass. `bug` in particular has its
# own priority bucket in claude-plugin/plugins/kanban/commands/triage.md, which
# is why issue #537 chose preselection knowingly (requirement 6).
BUG_LABEL = "bug"
ENHANCEMENT_LABEL = "enhancement"
QUESTION_LABEL = "question"

# The complete chooser-entry-to-label mapping, asserted exactly rather than by
# membership: a label a template must not carry is as much a part of this as
# one it must. The ordinary template stays unlabeled because a maintainer
# specification is not any one kind of work.
EXPECTED_LABELS = {
    BUG_TEMPLATE.name: (BUG_LABEL,),
    FEATURE_TEMPLATE.name: (ENHANCEMENT_LABEL,),
    SUPPORT_TEMPLATE.name: (QUESTION_LABEL,),
    ORDINARY_TEMPLATE.name: (),
    EPIC_TEMPLATE.name: (TRACKER_LABEL,),
    RELEASE_TEMPLATE.name: (RELEASE_LABEL,),
}

# The one contact link the chooser offers (issue #537, requirement 7). A
# security reporter is routed off the public tracker; anything else would
# divert a question out of it.
SECURITY_ADVISORY_URL = "https://github.com/coghex/kanban/security/advisories/new"

# The heading src/Kanban/Tracker.hs:307-319 recognizes, spelled as this
# repository's own epics spell it.
CHILDREN_HEADING = "Children"

# The token only the ordinary template spells, because it is the one asset that
# explains the convention.
ORIGIN_MARKER_KEY = "issue-origin"

HEADING_RE = re.compile(r"^##\s+(?P<heading>.+?)\s*$", re.MULTILINE)
ANY_HEADING_RE = re.compile(r"^(?P<hashes>#+)\s+(?P<heading>.+?)\s*$")
# Mirrors Kanban.Tracker.stripCheckbox: leading space, a `-` or `*` bullet,
# optional space, then exactly `[ ]`, `[x]`, or `[X]`.
CHECKBOX_RE = re.compile(r"^\s*[-*]\s*\[[ xX]\](?P<contents>.*)$")
# Mirrors Kanban.Tracker.findIssueNumber: the first `#` followed by digits.
ISSUE_REFERENCE_RE = re.compile(r"#(?P<number>\d+)")
# A Markdown indented code block: the shape every maintainer template's
# Acceptance section states its reviewer commands in.
COMMAND_LINE_RE = re.compile(r"^ {4,}\S")
# A heading as Markdown reads one, anchored at column zero. Unlike
# ANY_HEADING_RE above it does not see an indented `#` comment as a heading,
# which is what lets `command_lines` slice a section containing one.
COLUMN_ZERO_HEADING_RE = re.compile(r"^#+\s+(?P<heading>.+?)\s*$")


def setUpModule():
    # `tools/` ships whole in the source distribution and
    # `.github/ISSUE_TEMPLATE/` deliberately does not, so an unpacked release
    # runs this module with nothing to read. That is the packaged state rather
    # than a failure -- the same boundary tools/test_ci_workflow.py sits on for
    # `.github/workflows/`.
    #
    # The directory, not any one file: a checkout that has the directory but is
    # missing a template is a real regression, and
    # test_the_template_directory_holds_exactly_the_declared_templates reports
    # it. Skipping on a missing file would hide exactly that.
    if not TEMPLATE_DIR.is_dir():
        raise unittest.SkipTest(f"{TEMPLATE_DIR} is absent (not a Git checkout)")


def _approve_issues():
    """tools/approve_issues.py, loaded from the module itself so the origin
    rule under test is the one the gate actually runs. Loaded by path under a
    private name, the way tools/test_document_classification.py loads the
    release inventory, so the copy loaded here can never shadow a discovered
    one. Registered in sys.modules before execution because the module builds
    dataclasses at import time, which resolve their own module by name."""
    source = REPO_ROOT / "tools" / "approve_issues.py"
    tools_dir = str(REPO_ROOT / "tools")
    added = tools_dir not in sys.path
    if added:
        sys.path.insert(0, tools_dir)
    name = "_kanban_issue_template_gate"
    try:
        spec = importlib.util.spec_from_file_location(name, source)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        try:
            spec.loader.exec_module(module)
        except Exception:
            del sys.modules[name]
            raise
    finally:
        if added:
            sys.path.remove(tools_dir)
    return module


def split_frontmatter(text):
    """The frontmatter block and the body beneath it. Returns (None, text) when
    the file opens with no `---` fence, which is how GitHub reads it too: the
    template is then offered under its filename with no chooser entry."""
    if not text.startswith("---\n"):
        return None, text
    end = text.find("\n---\n", 3)
    if end == -1:
        return None, text
    return text[4:end], text[end + 5 :]


def parse_frontmatter(block):
    """The `key: value` pairs in a frontmatter block. GitHub's issue-template
    frontmatter is flat scalars only, so this reads it directly rather than
    taking a YAML dependency the rest of the suite does not have."""
    fields = {}
    for line in block.splitlines():
        if not line.strip():
            continue
        key, separator, value = line.partition(":")
        if not separator:
            raise AssertionError(f"frontmatter line is not `key: value`: {line!r}")
        fields[key.strip()] = value.strip().strip("'\"")
    return fields


def declared_labels(text):
    """The labels a template preselects, as a tuple in declaration order. An
    absent or empty `labels` field preselects nothing rather than one label
    named the empty string, which is what a bare split would produce."""
    fields = parse_frontmatter(split_frontmatter(text)[0])
    return tuple(
        item.strip() for item in fields.get("labels", "").split(",") if item.strip()
    )


class ChooserConfigError(AssertionError):
    """A chooser configuration outside the shape GitHub documents. Raised
    rather than silently tolerated so a malformed file is a failure here
    instead of a chooser that quietly drops its contact link."""


TOP_LEVEL_RE = re.compile(r"^(?P<key>[a-z_]+):(?P<value>.*)$")
LIST_ITEM_RE = re.compile(r"^ {2}- (?P<key>[a-z_]+): (?P<value>.+)$")
ITEM_FIELD_RE = re.compile(r"^ {4}(?P<key>[a-z_]+): (?P<value>.+)$")


def parse_chooser_config(text):
    """The keys GitHub reads out of `.github/ISSUE_TEMPLATE/config.yml`:
    `blank_issues_enabled` and the `contact_links` list. Accepts exactly the
    flat, one-level-of-nesting shape GitHub documents -- a scalar, or a list of
    mappings indented two and four spaces -- and raises `ChooserConfigError` on
    anything else. Written out here for the reason `parse_frontmatter` gives,
    and strict on purpose: a permissive reader could not serve as the negative
    control for a malformed configuration."""
    document = {}
    links = None
    item = None
    for number, line in enumerate(text.splitlines(), start=1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = LIST_ITEM_RE.match(line)
        if match:
            if links is None:
                raise ChooserConfigError(
                    f"line {number}: a list item before any list opened"
                )
            item = {match.group("key"): match.group("value").strip()}
            links.append(item)
            continue
        match = ITEM_FIELD_RE.match(line)
        if match:
            if item is None:
                raise ChooserConfigError(
                    f"line {number}: an indented field outside a list item"
                )
            item[match.group("key")] = match.group("value").strip()
            continue
        match = TOP_LEVEL_RE.match(line)
        if match:
            key = match.group("key")
            value = match.group("value").strip()
            item = None
            links = None
            if key in document:
                raise ChooserConfigError(f"line {number}: `{key}` is set twice")
            if value:
                document[key] = value
            else:
                links = []
                document[key] = links
            continue
        raise ChooserConfigError(
            f"line {number}: not a key, a list item, or an item field: {line!r}"
        )
    return document


def headings(text):
    """Every `##` heading, in document order."""
    return [match.group("heading") for match in HEADING_RE.finditer(text)]


def section_lines(text, wanted, level=2):
    """The lines beneath `wanted`, up to the next heading at or above its own
    level. Mirrors how Kanban.Tracker.parseLine closes a tracker section."""
    collected = []
    active = False
    for line in text.splitlines():
        match = ANY_HEADING_RE.match(line.lstrip())
        if match:
            depth = len(match.group("hashes"))
            if match.group("heading").strip() == wanted and depth == level:
                active = True
                continue
            if active and depth <= level:
                break
            continue
        if active:
            collected.append(line)
    return collected


def live_checkbox_references(lines):
    """The issue numbers a tracker parser would read from these lines. A line
    inside a single-line HTML comment is not a checkbox to
    Kanban.Tracker.stripCheckbox, because its first non-space character is
    `<`."""
    found = []
    for line in lines:
        match = CHECKBOX_RE.match(line)
        if not match:
            continue
        reference = ISSUE_REFERENCE_RE.search(match.group("contents"))
        if reference:
            found.append(int(reference.group("number")))
    return found


def command_lines(text, heading="Acceptance"):
    """The indented command lines under a heading -- what a reviewer is asked
    to run. An intake template has none, and a maintainer template has at least
    one.

    Sliced here rather than through `section_lines`, which lstrips a line
    before matching a heading because Kanban.Tracker.parseLine does. Under that
    rule the `    # the exact commands ...` line inside a Markdown command
    block reads as a level-one heading and closes the section -- which is
    exactly the content this looks for. A Markdown heading starts at column
    zero, so this matches there and lets an indented `#` stay a comment.
    """
    collected = []
    active = False
    for line in text.splitlines():
        match = COLUMN_ZERO_HEADING_RE.match(line)
        if match:
            if match.group("heading").strip() == heading:
                active = True
            elif active:
                break
            continue
        if active and COMMAND_LINE_RE.match(line):
            collected.append(line)
    return collected


class IssueTemplateTests(unittest.TestCase):
    """The rules every template owes, asserted against every template rather
    than against a sample: the chooser entry, the frontmatter GitHub reads, the
    five headings, the preselected label, and the absent origin marker."""

    @classmethod
    def setUpClass(cls):
        cls.gate = _approve_issues()
        cls.templates = {
            path.name: path.read_text(encoding="utf-8") for path in ALL_TEMPLATES
        }

    def test_the_template_directory_holds_exactly_the_declared_templates(self):
        self.assertTrue(TEMPLATE_DIR.is_dir(), TEMPLATE_DIR)
        self.assertEqual(
            sorted(path.name for path in TEMPLATE_DIR.glob("*.md")),
            sorted(path.name for path in ALL_TEMPLATES),
            "a template added here owes the rules below and this module's "
            "coverage, so it is named rather than discovered",
        )

    def test_every_template_carries_valid_frontmatter(self):
        for name, text in self.templates.items():
            with self.subTest(template=name):
                block, _ = split_frontmatter(text)
                self.assertIsNotNone(
                    block, f"{name} has no `---` frontmatter fence"
                )
                fields = parse_frontmatter(block)
                self.assertEqual(
                    sorted(set(fields) - SUPPORTED_FRONTMATTER_KEYS),
                    [],
                    f"{name} declares frontmatter keys GitHub ignores",
                )
                for key in ("name", "about"):
                    self.assertTrue(
                        fields.get(key),
                        f"{name} has no chooser {key}, so the chooser entry is "
                        "blank",
                    )

    def test_the_chooser_entries_are_distinct(self):
        # Two entries reading the same is the failure a chooser cannot show its
        # way out of: the author picks one at random. With intake and
        # maintainer entries side by side this decides who files what, so it
        # covers `about` as well as `name`.
        for key in ("name", "about"):
            with self.subTest(field=key):
                values = [
                    parse_frontmatter(split_frontmatter(text)[0])[key]
                    for text in self.templates.values()
                ]
                self.assertEqual(len(set(values)), len(values), key)

    def test_every_template_carries_the_five_headings_in_order(self):
        # A subsequence rather than an equality: the epic template adds its
        # Children heading, and the release template adds a Checklist beneath
        # Requirements.
        for name, text in self.templates.items():
            with self.subTest(template=name):
                present = [
                    heading
                    for heading in headings(text)
                    if heading in REQUIRED_HEADINGS
                ]
                self.assertEqual(present, list(REQUIRED_HEADINGS), name)

    def test_every_template_preselects_exactly_its_declared_labels(self):
        # Exact rather than by membership, so this is the single statement of
        # which chooser entry files what: an absent label is asserted by the
        # same comparison that asserts a present one.
        self.assertEqual(
            sorted(EXPECTED_LABELS),
            sorted(path.name for path in ALL_TEMPLATES),
            "EXPECTED_LABELS names every template and nothing else",
        )
        for name, text in self.templates.items():
            with self.subTest(template=name):
                self.assertEqual(declared_labels(text), EXPECTED_LABELS[name], name)

    def test_a_mislabelled_template_would_be_reported(self):
        # The negative control for the rule above: a template carrying a label
        # meant for another entry must not compare equal.
        planted = self.templates["epic.md"].replace(
            f"labels: {TRACKER_LABEL}\n", f"labels: {BUG_LABEL}\n", 1
        )
        self.assertNotEqual(planted, self.templates["epic.md"], "the label moved")
        self.assertNotEqual(
            declared_labels(planted), EXPECTED_LABELS["epic.md"]
        )

    def test_no_template_declares_an_origin(self):
        # Issue #537's requirement 5, checked through the gate's own function
        # rather than a regex restated here.
        for name, text in self.templates.items():
            with self.subTest(template=name):
                self.assertIsNone(
                    self.gate.issue_origin(text),
                    f"{name} would mark every issue filed from it",
                )

    def test_the_origin_rule_would_catch_a_marked_template(self):
        # The negative control for the rule above: issue_origin must be able to
        # see a marker in a body of this shape at all.
        marked = self.templates["issue.md"] + "\n<!-- issue-origin:claude -->\n"
        self.assertEqual(self.gate.issue_origin(marked), "claude")

    def test_the_ordinary_template_explains_the_absent_marker(self):
        # The property requirement 5 actually needs. Explaining the convention
        # in prose is what makes the rule above load bearing: without the
        # explanation there is nothing a marker could leak out of.
        self.assertIn(ORIGIN_MARKER_KEY, self.templates["issue.md"])

    def test_every_other_template_delegates_that_explanation(self):
        # The explain-or-delegate pair, over every asset that owes the reader
        # the answer: one template states the convention and the rest point at
        # it. Issue #537's requirement 5 as its review amended it -- the intake
        # templates delegate too, because requirement 2 keeps the ordinary
        # template's full explanation where it is.
        for path in ALL_TEMPLATES:
            if path == ORDINARY_TEMPLATE:
                continue
            with self.subTest(template=path.name):
                text = self.templates[path.name]
                self.assertIn("origin marker", text)
                self.assertIn("ordinary issue template", text)

    def test_only_the_ordinary_template_spells_the_marker_key(self):
        # The negative control that makes "never a second copy" enforceable
        # rather than aspirational: a delegating template that grew its own
        # explanation would spell the token, and a rule asserting only presence
        # elsewhere could not see it.
        for path in ALL_TEMPLATES:
            if path == ORDINARY_TEMPLATE:
                continue
            with self.subTest(template=path.name):
                # Counted rather than asserted with assertNotIn so a failure
                # reports how many spellings crept in instead of echoing the
                # whole template.
                self.assertEqual(
                    self.templates[path.name].count(ORIGIN_MARKER_KEY),
                    0,
                    f"{path.name} keeps a second copy of the explanation "
                    "issue.md owns",
                )


class IntakeTemplateTests(unittest.TestCase):
    """Issue #537's requirement 3: the three intake templates ask a reporter
    for what they know and for nothing a maintainer supplies later. The
    maintainer templates are the negative control throughout -- each rule below
    is asserted in both directions, so it cannot pass by matching everything."""

    @classmethod
    def setUpClass(cls):
        cls.intake = {
            path.name: path.read_text(encoding="utf-8") for path in INTAKE_TEMPLATES
        }
        cls.maintainer = {
            path.name: path.read_text(encoding="utf-8")
            for path in MAINTAINER_TEMPLATES
        }

    def test_no_intake_template_asks_for_a_reviewer_command(self):
        # An indented block under Acceptance is where a reviewer command
        # lives, and asking an outside reporter for one is the thing this
        # split exists to stop.
        for name, text in self.intake.items():
            with self.subTest(template=name):
                self.assertEqual(command_lines(text), [], name)

    def test_every_maintainer_template_does_ask_for_one(self):
        # The negative control: without this, deleting every Acceptance
        # command block in the directory would pass the rule above by saying
        # nothing.
        for name, text in self.maintainer.items():
            with self.subTest(template=name):
                self.assertTrue(command_lines(text), name)

    def test_a_planted_command_block_would_be_reported(self):
        # And the control over the extractor itself: an intake template that
        # grew a command block must be visible to `command_lines`.
        planted = self.intake["bug_report.md"].replace(
            "## Acceptance\n", "## Acceptance\n\n    kanban --version\n", 1
        )
        self.assertNotEqual(
            planted, self.intake["bug_report.md"], "the Acceptance heading moved"
        )
        self.assertEqual(command_lines(planted), ["    kanban --version"])

    def test_every_intake_template_marks_its_maintainer_field(self):
        # Requirement 3's "a maintainer-only field may be left blank": the
        # reporter is told which section is not theirs to fill, rather than
        # left to guess from an empty heading.
        for name, text in self.intake.items():
            with self.subTest(template=name):
                self.assertIn("Maintainer field", text)

    def test_no_maintainer_template_marks_one(self):
        # The negative control over the assets whose author fills every
        # section themselves.
        for name, text in self.maintainer.items():
            with self.subTest(template=name):
                self.assertNotIn("Maintainer field", text)


class ChooserConfigTests(unittest.TestCase):
    """Issue #537's requirement 7: blank intake is disabled, and the chooser
    carries exactly one contact link, to the private security advisory form."""

    @classmethod
    def setUpClass(cls):
        if not CHOOSER_CONFIG.is_file():
            raise AssertionError(f"{CHOOSER_CONFIG} is absent")
        cls.text = CHOOSER_CONFIG.read_text(encoding="utf-8")
        cls.document = parse_chooser_config(cls.text)

    def test_blank_issues_are_disabled(self):
        # The whole point of a chooser this repository's workflows read: an
        # "Open a blank issue" link beside the templates is the most inviting
        # entry and leads to none of their shapes.
        self.assertEqual(self.document.get("blank_issues_enabled"), "false")

    def test_a_blank_enabled_configuration_would_be_reported(self):
        planted = self.text.replace(
            "blank_issues_enabled: false", "blank_issues_enabled: true", 1
        )
        self.assertNotEqual(planted, self.text, "the switch moved")
        self.assertEqual(
            parse_chooser_config(planted).get("blank_issues_enabled"), "true"
        )

    def test_the_chooser_carries_exactly_one_contact_link(self):
        links = self.document.get("contact_links")
        self.assertIsInstance(links, list, "contact_links is not a list")
        self.assertEqual(
            len(links),
            1,
            "a second link would divert support questions out of the tracker, "
            "where the Support question template is the single route for them",
        )

    def test_the_contact_link_is_complete_and_targets_the_advisory_form(self):
        link = self.document["contact_links"][0]
        for key in ("name", "about"):
            with self.subTest(field=key):
                self.assertTrue(
                    link.get(key), f"the contact link has no {key} to show"
                )
        self.assertEqual(link.get("url"), SECURITY_ADVISORY_URL)

    def test_a_second_contact_link_would_be_reported(self):
        planted = self.text + (
            "  - name: Ask a question\n"
            "    about: Somewhere other than the tracker.\n"
            "    url: https://example.invalid/\n"
        )
        self.assertEqual(len(parse_chooser_config(planted)["contact_links"]), 2)

    def test_a_retargeted_contact_link_would_be_reported(self):
        planted = self.text.replace(SECURITY_ADVISORY_URL, "https://example.invalid/", 1)
        self.assertNotEqual(planted, self.text, "the advisory URL moved")
        self.assertNotEqual(
            parse_chooser_config(planted)["contact_links"][0].get("url"),
            SECURITY_ADVISORY_URL,
        )

    def test_an_incomplete_contact_link_would_be_reported(self):
        planted = self.text.replace("    about: ", "    description: ", 1)
        self.assertNotEqual(planted, self.text, "the about field moved")
        self.assertIsNone(
            parse_chooser_config(planted)["contact_links"][0].get("about")
        )

    def test_a_malformed_configuration_is_refused(self):
        # The control over the reader itself: a permissive parser would report
        # a missing link as an absent key rather than as the broken file it is,
        # and every rule above would then pass on a chooser GitHub drops.
        for label, planted in (
            ("dedented item", self.text.replace("  - name:", "- name:", 1)),
            ("orphan field", "    url: https://example.invalid/\n" + self.text),
            ("unparsed line", self.text + "contact_links extra\n"),
            ("duplicate key", self.text + "blank_issues_enabled: true\n"),
        ):
            with self.subTest(case=label):
                with self.assertRaises(ChooserConfigError):
                    parse_chooser_config(planted)


class ReleaseTemplateTests(unittest.TestCase):
    """The release template's one property beyond the shared rules: the chooser
    entry preselects the label a release is filtered by. The exact mapping in
    `EXPECTED_LABELS` covers which templates must not carry it; this states why
    this one must (issue #539)."""

    @classmethod
    def setUpClass(cls):
        cls.text = RELEASE_TEMPLATE.read_text(encoding="utf-8")

    def test_the_release_template_preselects_the_release_label(self):
        self.assertIn(RELEASE_LABEL, declared_labels(self.text))


class EpicTemplateTests(unittest.TestCase):
    """The epic template's checklist is parsed by Kanban.Tracker, so it owes
    rules no other template does."""

    @classmethod
    def setUpClass(cls):
        cls.text = EPIC_TEMPLATE.read_text(encoding="utf-8")
        cls.others = {
            path.name: path.read_text(encoding="utf-8")
            for path in ALL_TEMPLATES
            if path != EPIC_TEMPLATE
        }

    def test_the_epic_template_preselects_the_tracker_label(self):
        self.assertIn(
            TRACKER_LABEL,
            declared_labels(self.text),
            "src/Kanban/Tracker.hs:399-409 recognizes a tracker by label, and "
            "reads an `Epic:` title only when the issue has none",
        )

    def test_the_epic_template_carries_a_parsed_children_heading(self):
        self.assertIn(CHILDREN_HEADING, headings(self.text))

    def test_the_children_section_shows_a_checkbox(self):
        lines = section_lines(self.text, CHILDREN_HEADING)
        self.assertTrue(
            any(CHECKBOX_RE.match(line) for line in lines),
            "the section exists to be filled in, so it shows the shape",
        )

    def test_no_live_checklist_item_names_an_issue(self):
        # The rule that keeps a freshly filed epic from claiming someone
        # else's issue as a child.
        self.assertEqual(
            live_checkbox_references(section_lines(self.text, CHILDREN_HEADING)),
            [],
            "an example item must stay on a comment line, which "
            "Kanban.Tracker.stripCheckbox rejects",
        )

    def test_the_example_item_is_present_but_inert(self):
        # Without this, deleting the guidance outright would pass the rule
        # above by saying nothing.
        lines = section_lines(self.text, CHILDREN_HEADING)
        commented = [line for line in lines if line.lstrip().startswith("<!--")]
        self.assertTrue(
            any(ISSUE_REFERENCE_RE.search(line) for line in commented),
            "the template shows what a real child item looks like",
        )
        self.assertEqual(live_checkbox_references(commented), [])

    def test_a_live_example_item_would_be_reported(self):
        # The negative control: the same section with the example uncommented
        # is exactly the mistake this guards, and must not pass.
        planted = self.text.replace(
            "<!-- - [ ] #123 — A1: The first slice. -->",
            "- [ ] #123 — A1: The first slice.",
        )
        self.assertNotEqual(planted, self.text, "the example item moved")
        self.assertEqual(
            live_checkbox_references(section_lines(planted, CHILDREN_HEADING)),
            [123],
        )

    def test_no_other_template_declares_a_tracker_section(self):
        # The negative control over every asset that delegates instead: a
        # Children heading anywhere else would make every issue filed from that
        # template a tracker with no children, and a live checkbox naming an
        # issue would attach it as a child.
        for name, text in self.others.items():
            with self.subTest(template=name):
                self.assertNotIn(CHILDREN_HEADING, headings(text))
                self.assertEqual(live_checkbox_references(text.splitlines()), [])


if __name__ == "__main__":
    unittest.main()
