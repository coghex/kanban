"""Contract check for .github/ISSUE_TEMPLATE/.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Issue #434: GitHub's new-issue flow offers no template, so every issue filed
through the web UI arrives shapeless while the drafting workflows each
reproduce the tracker's five-heading shape independently. The templates added
alongside this module close that gap.

They are checked rather than trusted because two of their properties are read
as data by something else, and a template that violates either one breaks the
pipeline for every issue filed from it:

* `tools/approve_issues.py`'s `ORIGIN_RE` matches an origin marker anywhere in
  an issue body, and `issue_origin` raises when both brands appear. A template
  that spelled the marker while explaining it would mark every issue filed from
  it, or refuse them all. The explanatory comment may name `issue-origin` in
  prose and must contain no marker-shaped sequence -- so the check here is
  `issue_origin` itself, run against the complete template file, rather than a
  regex restated in this module.
* `src/Kanban/Tracker.hs` parses the epic template's `Children` checklist to
  build the board's tracker hierarchy. `stripCheckbox` (`:200-209`) accepts any
  line whose first non-space character is `-` or `*` followed by `[ ]`, `[x]`,
  or `[X]`, with no awareness of HTML comments, and `findIssueNumber`
  (`:216-231`) reads the first `#N` in what follows. An example item left live
  would therefore attach a real issue to every epic filed from the template.
  Example items stay on single-line comments, which `stripCheckbox` rejects
  because the line starts with `<`.

The `Maintainer release` template joined them later (issue #539). It owes the
shared rules above like any other template, and it owes one of its own: it
preselects the `release` label the board and the backlog filter a release by.
Its release-safety properties -- the authorization item arriving unchecked and
ahead of the tag item -- are not general template rules, so they live with the
runbook they gate in `tools/test_release_runbook.py`.

An unfilled placeholder checkbox carrying no reference is the intended state:
it yields `TrackerIssueReferenceMissing` and `TrackerChildrenMissing` until the
author lists real children, which is a diagnostic about an empty epic rather
than a wrong one.

The negative controls below run each rule against a synthetic body that
violates it, so a rule that matched everything could not pass while asserting
nothing.
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

# CLAUDE.md's "Hygiene" section: the shape every issue body in this repository
# takes, in this order.
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

# The heading src/Kanban/Tracker.hs:307-319 recognizes, spelled as this
# repository's own epics spell it.
CHILDREN_HEADING = "Children"

HEADING_RE = re.compile(r"^##\s+(?P<heading>.+?)\s*$", re.MULTILINE)
ANY_HEADING_RE = re.compile(r"^(?P<hashes>#+)\s+(?P<heading>.+?)\s*$")
# Mirrors Kanban.Tracker.stripCheckbox: leading space, a `-` or `*` bullet,
# optional space, then exactly `[ ]`, `[x]`, or `[X]`.
CHECKBOX_RE = re.compile(r"^\s*[-*]\s*\[[ xX]\](?P<contents>.*)$")
# Mirrors Kanban.Tracker.findIssueNumber: the first `#` followed by digits.
ISSUE_REFERENCE_RE = re.compile(r"#(?P<number>\d+)")


def setUpModule():
    # `tools/` ships whole in the source distribution and
    # `.github/ISSUE_TEMPLATE/` deliberately does not, so an unpacked release
    # runs this module with nothing to read. That is the packaged state rather
    # than a failure -- the same boundary tools/test_ci_workflow.py sits on for
    # `.github/workflows/`.
    #
    # The directory, not either file: a checkout that has the directory but is
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


class IssueTemplateTests(unittest.TestCase):
    """The properties requirements 1 through 4 promise, asserted against every
    template that owes them."""

    @classmethod
    def setUpClass(cls):
        cls.gate = _approve_issues()
        cls.templates = {
            path.name: path.read_text(encoding="utf-8")
            for path in (ORDINARY_TEMPLATE, EPIC_TEMPLATE, RELEASE_TEMPLATE)
        }

    def test_the_template_directory_holds_exactly_the_declared_templates(self):
        self.assertTrue(TEMPLATE_DIR.is_dir(), TEMPLATE_DIR)
        self.assertEqual(
            sorted(path.name for path in TEMPLATE_DIR.glob("*.md")),
            ["epic.md", "issue.md", "release.md"],
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
        # way out of: the author picks one at random.
        for key in ("name", "about"):
            with self.subTest(field=key):
                values = [
                    parse_frontmatter(split_frontmatter(text)[0])[key]
                    for text in self.templates.values()
                ]
                self.assertEqual(len(set(values)), len(values), key)

    def test_every_template_carries_the_five_headings_in_order(self):
        # A subsequence rather than an equality: the epic template adds its
        # Children heading, which requirement 3 asks for.
        for name, text in self.templates.items():
            with self.subTest(template=name):
                present = [
                    heading
                    for heading in headings(text)
                    if heading in REQUIRED_HEADINGS
                ]
                self.assertEqual(present, list(REQUIRED_HEADINGS), name)

    def test_no_template_declares_an_origin(self):
        # Requirement 2, checked through the gate's own function rather than a
        # regex restated here.
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
        # The property requirement 2 actually needs. Explaining the convention
        # in prose is what makes the rule above load bearing: without the
        # explanation there is nothing a marker could leak out of.
        self.assertIn("issue-origin", self.templates["issue.md"])

    def test_the_release_template_delegates_that_explanation(self):
        # The same delegation the epic template makes, over the third asset
        # that owes the reader the answer and must not keep a second copy of
        # it to drift.
        text = self.templates["release.md"]
        self.assertIn("origin marker", text)
        self.assertIn("ordinary issue template", text)

    def test_the_epic_template_delegates_that_explanation(self):
        # The negative control over the asset that delegates rather than
        # restating: the epic template owes the reader the same answer, and
        # points at where it is given instead of keeping a second copy to
        # drift.
        text = self.templates["epic.md"]
        self.assertIn("origin marker", text)
        self.assertIn("ordinary issue template", text)


class ReleaseTemplateTests(unittest.TestCase):
    """Requirement 7's one property beyond the shared rules: the chooser entry
    preselects the label a release is filtered by."""

    @classmethod
    def setUpClass(cls):
        cls.text = RELEASE_TEMPLATE.read_text(encoding="utf-8")
        cls.others = {
            path.name: path.read_text(encoding="utf-8")
            for path in (ORDINARY_TEMPLATE, EPIC_TEMPLATE)
        }

    def test_the_release_template_preselects_the_release_label(self):
        fields = parse_frontmatter(split_frontmatter(self.text)[0])
        labels = [item.strip() for item in fields.get("labels", "").split(",")]
        self.assertIn(RELEASE_LABEL, labels)

    def test_no_other_template_preselects_it(self):
        # The negative control over the assets that must not: a `release` label
        # on the ordinary or epic template would label every issue filed from
        # it as a release.
        for name, text in self.others.items():
            with self.subTest(template=name):
                fields = parse_frontmatter(split_frontmatter(text)[0])
                labels = [
                    item.strip() for item in fields.get("labels", "").split(",")
                ]
                self.assertNotIn(RELEASE_LABEL, labels)


class EpicTemplateTests(unittest.TestCase):
    """Requirement 3: the epic template's checklist is parsed by
    Kanban.Tracker, so it owes rules the ordinary template does not."""

    @classmethod
    def setUpClass(cls):
        cls.text = EPIC_TEMPLATE.read_text(encoding="utf-8")
        cls.ordinary = ORDINARY_TEMPLATE.read_text(encoding="utf-8")

    def test_the_epic_template_preselects_the_tracker_label(self):
        fields = parse_frontmatter(split_frontmatter(self.text)[0])
        labels = [item.strip() for item in fields.get("labels", "").split(",")]
        self.assertIn(
            TRACKER_LABEL,
            labels,
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

    def test_the_ordinary_template_declares_no_tracker_section(self):
        # The negative control over the asset that delegates instead: a
        # Children heading in the ordinary template would make every issue
        # filed from it a tracker with no children.
        self.assertNotIn(CHILDREN_HEADING, headings(self.ordinary))
        self.assertEqual(
            live_checkbox_references(self.ordinary.splitlines()),
            [],
        )


if __name__ == "__main__":
    unittest.main()
