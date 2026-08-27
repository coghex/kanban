"""Safety-rule check for docs/releasing.md and the maintainer release template.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 -m unittest tools.test_release_runbook

Issue #539: the release procedure used to exist only as the first release's
history. `docs/releasing.md` states it reusably, and `.github/ISSUE_TEMPLATE/`'s
`release.md` is the per-release checklist that drives it. Both are prose, so
most of what they say is not this module's business.

Four things in them are, because each is a rule whose quiet removal would not
look like a regression to a reader:

* **Publication cannot happen without a recorded human authorization.** The
  runbook carries it as a step of its own, ahead of the tag push, naming the
  exact comment a maintainer has to leave; the template carries it as an
  unchecked item saying the same. A release procedure whose authorization is a
  clause inside another step is one an agent can satisfy by inference, which is
  the failure the step exists to prevent.
* **A pushed tag is immutable.** The one irreversible action in the procedure is
  the tag push, and every plausible repair afterwards — delete it, move it,
  reuse the version, force-push, publish the Release by hand — makes a published
  version mean two different things. The runbook forbids each by name.
* **Release evidence lives on the release issue.** Not in `docs/design.md`,
  whose section 21 is the closed first-release record, and not in a new Markdown
  file per version.
* **The dependency review is real work with a recorded result.** Five named
  subjects, two cadences, the ordinary issue lane for anything it finds, and a
  durable place to record a review that finds nothing.

The runbook is also version-neutral, which is what makes it reusable at all: a
release's own numbers belong to that release's issue.

The rules are predicates over the document text rather than assertions about
its wording, and each is run twice -- once against the live document, and once
against a copy with that rule's own sentence removed or inverted. A rule that
matched everything could not pass the second run while asserting nothing.

`tools/` ships whole in the source distribution and `.github/ISSUE_TEMPLATE/`
deliberately does not, so the template class skips on the missing directory the
way `tools/test_issue_templates.py` does. The runbook itself is a packaged
document, so its rules run in an unpacked release too.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RUNBOOK = REPO_ROOT / "docs" / "releasing.md"
TEMPLATE_DIR = REPO_ROOT / ".github" / "ISSUE_TEMPLATE"
RELEASE_TEMPLATE = TEMPLATE_DIR / "release.md"

# The runbook's ordered procedure, by `##` heading. Requirement 1's sequence:
# version, changelog, candidate, rehearsal, dependencies, upgrade, settings,
# authorization, tag, observation, verification, evidence. Pinned in order
# because the order is the contract -- a gate recorded after the tag push is
# not a gate.
PROCEDURE_HEADINGS = (
    "1. Review the version and PVP compatibility",
    "2. Promote the changelog",
    "3. Select the candidate commit",
    "4. Rehearse the release on the candidate",
    "5. Review dependencies and maintenance assumptions",
    "6. Perform the manual supported-host upgrade",
    "7. Check the repository settings",
    "8. Record the publication authorization",
    "9. Push the one annotated tag",
    "10. Observe the release workflow",
    "11. Verify the published release as a consumer",
    "12. Record the evidence and close the issue",
)

AUTHORIZATION_HEADING = "8. Record the publication authorization"
TAG_HEADING = "9. Push the one annotated tag"
CANDIDATE_HEADING = "3. Select the candidate commit"
UPGRADE_HEADING = "6. Perform the manual supported-host upgrade"
SETTINGS_HEADING = "7. Check the repository settings"
OBSERVE_HEADING = "10. Observe the release workflow"
EVIDENCE_STEP_HEADING = "12. Record the evidence and close the issue"
EVIDENCE_HEADING = "Where release evidence lives"
FAILURE_HEADING = "If something fails after the tag is pushed"
DEPENDENCY_HEADING = "Dependency and maintenance review"

# The five prohibitions requirement 4 names, in the terms it names them.
# Keyed by rule name so a negative control can say which one it removed.
TAG_IMMUTABILITY_RULES = {
    "delete": "do not delete the tag",
    "move": "do not move the tag",
    "reuse": "do not reuse",
    "force-push": "force-push",
    "by-hand": "do not create the github release by hand",
}

# What makes the authorization a gate rather than a formality: the recorded
# artifact a maintainer has to leave, and the two claims that say nothing else
# substitutes for it.
AUTHORIZATION_RULES = {
    "recorded-comment": "authorized: publish <version> from <commit>.",
    "not-implied": "no other step implies it",
    "not-an-agent": "no agent may perform it",
}

# Requirement 5's evidence location, in both halves: where it goes, and the two
# places it deliberately does not.
EVIDENCE_RULES = {
    "release-issue": "release evidence lives on the release's own issue",
    "no-markdown-file": "no permanent per-release markdown file is created",
    "design-does-not-grow": "design.md does not grow",
}

# The six items requirement 5 says the evidence comment names.
EVIDENCE_ITEMS = {
    "commit": "released commit",
    "ci-run": "required ci run",
    "tag": "the tag",
    "release-run": "release workflow run",
    "digest": "digest",
    "consumer": "consumer verification",
}

# The candidate-identity boundary: one exact commit, carrying the required
# check, and gates that do not travel to another commit.
CANDIDATE_RULES = {
    "one-commit": "pick one exact commit on master",
    "required-check": "required build-test job reports success for that exact commit",
    "no-carry": "do not carry gates across",
}

# What the one manual host gate covers. Anything dropped from this list is a
# part of an upgrade nothing else exercises.
UPGRADE_ITEMS = {
    "executable": "the executable",
    "workflow-assets": "optional workflow assets",
    "managed-components": "managed components",
    "doctor": "--doctor",
    "board-run": "interactive board run",
    "state": "preservation of supported configuration and durable state",
}

# The repository metadata the settings step checks, exactly as the decision
# that fixed it states. Restated here so drift in either direction fails.
REPOSITORY_DESCRIPTION = (
    "A keyboard-driven terminal board for GitHub issues, pull requests, "
    "and agent workflows."
)
REPOSITORY_TOPICS = (
    "haskell",
    "terminal",
    "tui",
    "kanban",
    "github",
    "developer-tools",
    "ai-agents",
    "brick",
)

# Requirement 8's five subjects, its two cadences, its lane, and the two places
# a result is recorded.
DEPENDENCY_RULES = {
    "haskell-bounds": "direct haskell dependency bounds",
    "cabal-outdated": "cabal outdated",
    "toolchain-pins": "the pinned ghc and cabal versions",
    "actions-versions": "github actions major versions",
    "platform-security": "supported-platform and security assumptions",
    "cadence-release": "before each release",
    "cadence-quarterly": "approximately quarterly",
    "ordinary-lane": "becomes an ordinary issue and travels the ordinary approval, "
    "solve, and pull-request lane",
    "record-pre-release": "records its date and result on that release's issue",
    "record-off-cycle": "dependency-review issue",
}

# A four-component package version, or any other dotted numeric run. The
# runbook spells every version `<version>`: a literal here is either a
# particular release's number or evidence from one, and requirement 2 forbids
# both.
VERSION_LITERAL_RE = re.compile(r"(?<![.\d])\d+(?:\.\d+){2,}(?![.\d])")

HEADING_RE = re.compile(r"^(?P<hashes>#+)\s+(?P<heading>.+?)\s*$")
MARKDOWN_LINK_RE = re.compile(r"\[(?P<text>[^\]\n]*)\]\([^)\s]*(?:\s+\"[^\"]*\")?\)")
# `- [ ] 8. ...` / `- [x] 8. ...`: a checklist item and whether it is checked.
CHECKLIST_ITEM_RE = re.compile(r"^\s*-\s*\[(?P<mark>[ xX])\]\s*(?P<body>.*)$")


def normalized(text):
    """Lower-cased text with Markdown emphasis, code spans, and link syntax
    reduced to the words a reader sees, and whitespace collapsed.

    The rules below are about what the document says, not how it is marked up
    or wrapped, so bolding a prohibition or reflowing a paragraph must not fail
    them -- while deleting one still does."""
    plain = MARKDOWN_LINK_RE.sub(lambda match: match.group("text"), text)
    plain = plain.replace("*", "").replace("`", "")
    return " ".join(plain.lower().split())


def headings(text, level=2):
    """Every heading at `level`, in document order."""
    found = []
    for line in text.splitlines():
        match = HEADING_RE.match(line)
        if match and len(match.group("hashes")) == level:
            found.append(match.group("heading").strip())
    return found


def section(text, wanted, level=2):
    """The body beneath `wanted`, up to the next heading at or above its own
    level. Empty when the heading is absent, which is how a deleted section
    reaches the rules below."""
    collected = []
    active = False
    for line in text.splitlines():
        match = HEADING_RE.match(line)
        if match:
            depth = len(match.group("hashes"))
            if depth == level and match.group("heading").strip() == wanted:
                active = True
                continue
            if active and depth <= level:
                break
            continue
        if active:
            collected.append(line)
    return "\n".join(collected)


def missing_rules(haystack, rules):
    """The rule names whose phrase is absent from `haystack`, which is already
    normalized. Sorted so a failure names the same gaps in the same order."""
    return sorted(name for name, phrase in rules.items() if phrase not in haystack)


def tag_immutability_gaps(text):
    """Requirement 4's prohibitions that the post-tag failure section does not
    state. Bound to that section rather than the whole document: a prohibition
    that survives only as an aside somewhere else is not the unambiguous
    response the requirement asks for."""
    return missing_rules(
        normalized(section(text, FAILURE_HEADING)), TAG_IMMUTABILITY_RULES
    )


def authorization_gaps(text):
    """Requirement 3's gate: a step of its own, ahead of the tag push, naming
    the comment that records it and denying that anything else substitutes."""
    gaps = missing_rules(
        normalized(section(text, AUTHORIZATION_HEADING)), AUTHORIZATION_RULES
    )
    present = headings(text)
    if AUTHORIZATION_HEADING not in present:
        gaps.append("own-step")
    elif TAG_HEADING not in present:
        gaps.append("tag-step")
    elif present.index(AUTHORIZATION_HEADING) > present.index(TAG_HEADING):
        gaps.append("precedes-tag")
    return sorted(gaps)


def evidence_gaps(text):
    """Requirement 5, in both halves: where the evidence goes, what the comment
    names, and the two places release records deliberately do not grow."""
    gaps = missing_rules(normalized(section(text, EVIDENCE_HEADING)), EVIDENCE_RULES)
    gaps += missing_rules(
        normalized(section(text, EVIDENCE_STEP_HEADING)), EVIDENCE_ITEMS
    )
    return sorted(gaps)


def candidate_identity_gaps(text):
    """The one-commit boundary every pre-tag gate is recorded against."""
    return missing_rules(normalized(section(text, CANDIDATE_HEADING)), CANDIDATE_RULES)


def upgrade_coverage_gaps(text):
    """What the single manual supported-host gate has to cover."""
    return missing_rules(normalized(section(text, UPGRADE_HEADING)), UPGRADE_ITEMS)


def repository_setting_gaps(text):
    """The exact public metadata the settings step checks before
    authorization: the description verbatim, all eight topics, and an empty
    homepage."""
    body = normalized(section(text, SETTINGS_HEADING))
    gaps = []
    if normalized(REPOSITORY_DESCRIPTION) not in body:
        gaps.append("description")
    gaps += [f"topic:{topic}" for topic in REPOSITORY_TOPICS if topic not in body]
    if "homepage must be empty" not in body:
        gaps.append("empty-homepage")
    return sorted(gaps)


def dependency_review_gaps(text):
    """Requirement 8's subjects, cadences, lane, and recorded results."""
    return missing_rules(
        normalized(section(text, DEPENDENCY_HEADING)), DEPENDENCY_RULES
    )


def version_literals(text):
    """Dotted numeric runs the runbook must not contain (requirement 2)."""
    return sorted(set(VERSION_LITERAL_RE.findall(text)))


def checklist_items(text):
    """(checked, body) for every checklist item, in document order.

    An item's body runs to the next item or the next unindented line, because
    the interesting items are the ones long enough to wrap -- reading only the
    first line would let the sentence that makes an item a gate sit one line
    below the rule looking for it."""
    found = []
    collecting = None
    for line in text.splitlines():
        match = CHECKLIST_ITEM_RE.match(line)
        if match:
            collecting = [match.group("body")]
            found.append([match.group("mark") in "xX", collecting])
            continue
        if collecting is not None and line[:1].isspace() and line.strip():
            collecting.append(line.strip())
            continue
        collecting = None
    return [(checked, normalized(" ".join(body))) for checked, body in found]


def template_authorization_gaps(text):
    """The template's half of requirement 3: the authorization is an item of
    its own, it arrives unchecked, it names the comment that satisfies it, and
    it sits ahead of the tag item. A pre-checked box is the interesting
    failure -- it ships a release issue whose gate is already satisfied."""
    items = checklist_items(text)
    authorization = [
        (index, checked, body)
        for index, (checked, body) in enumerate(items)
        if "publication authorized" in body
    ]
    tag = [
        index
        for index, (_, body) in enumerate(items)
        if "tag created on the authorized commit" in body
    ]
    gaps = []
    if not authorization:
        return ["authorization-item"]
    if len(authorization) > 1:
        gaps.append("one-authorization-item")
    index, checked, body = authorization[0]
    if checked:
        gaps.append("starts-unchecked")
    if "authorized: publish <version> from <commit>." not in body:
        gaps.append("names-the-comment")
    if "no agent may check this item" not in body:
        gaps.append("not-an-agent")
    if not tag:
        gaps.append("tag-item")
    elif index > tag[0]:
        gaps.append("precedes-tag")
    return sorted(gaps)


class ReleaseRunbookTests(unittest.TestCase):
    """The live document satisfies every rule."""

    @classmethod
    def setUpClass(cls):
        cls.text = RUNBOOK.read_text(encoding="utf-8")

    def test_the_procedure_states_its_steps_in_order(self):
        self.assertEqual(
            [
                heading
                for heading in headings(self.text)
                if heading in PROCEDURE_HEADINGS
            ],
            list(PROCEDURE_HEADINGS),
        )

    def test_the_runbook_is_version_neutral(self):
        self.assertEqual(
            version_literals(self.text),
            [],
            "the runbook spells every version `<version>`; a literal is either "
            "one release's number or evidence from it",
        )

    def test_the_candidate_is_one_commit_carrying_the_required_check(self):
        self.assertEqual(candidate_identity_gaps(self.text), [])

    def test_the_manual_upgrade_gate_states_what_it_covers(self):
        self.assertEqual(upgrade_coverage_gaps(self.text), [])

    def test_the_settings_step_names_the_exact_repository_state(self):
        self.assertEqual(repository_setting_gaps(self.text), [])

    def test_the_authorization_is_a_recorded_step_before_the_tag_push(self):
        self.assertEqual(authorization_gaps(self.text), [])

    def test_the_pushed_tag_is_immutable(self):
        self.assertEqual(tag_immutability_gaps(self.text), [])

    def test_release_evidence_lives_on_the_release_issue(self):
        self.assertEqual(evidence_gaps(self.text), [])

    def test_the_dependency_review_is_specified_and_recorded(self):
        self.assertEqual(dependency_review_gaps(self.text), [])


class RunbookRuleControlTests(unittest.TestCase):
    """The negative controls. Each removes or inverts exactly the sentence its
    rule is about, and asserts the rule names that gap -- so a rule cannot pass
    by matching everything, and deleting a safety statement from the runbook
    cannot pass by matching nothing."""

    @classmethod
    def setUpClass(cls):
        cls.text = RUNBOOK.read_text(encoding="utf-8")

    def without(self, phrase, replacement=""):
        """The runbook with one passage replaced, asserting that exactly one
        passage was there to replace: a control that silently matched nothing
        would make its own assertion vacuous.

        Words are matched across any run of whitespace, and case-insensitively,
        because the passages below are prose: reflowing a paragraph, or naming
        a rule the way the normalized rule spells it, must not turn a control
        into a false alarm about a rule that is still stated."""
        pattern = re.compile(
            r"\s+".join(re.escape(word) for word in phrase.split()), re.IGNORECASE
        )
        planted, replaced = pattern.subn(replacement, self.text)
        self.assertEqual(
            replaced, 1, f"the passage this control removes moved: {phrase!r}"
        )
        return planted

    def test_deleting_a_tag_prohibition_is_reported(self):
        planted = self.without("- **Do not delete the tag.**", "- Fix it.")
        self.assertEqual(tag_immutability_gaps(planted), ["delete"])

    def test_deleting_the_whole_failure_section_is_reported(self):
        planted = self.text.replace(
            f"## {FAILURE_HEADING}", "## Recovering from a bad release"
        )
        self.assertEqual(
            tag_immutability_gaps(planted), sorted(TAG_IMMUTABILITY_RULES)
        )

    def test_deleting_the_authorization_step_is_reported(self):
        planted = self.text.replace(f"## {AUTHORIZATION_HEADING}", "## Notes")
        self.assertEqual(
            authorization_gaps(planted),
            sorted(list(AUTHORIZATION_RULES) + ["own-step"]),
        )

    def test_an_authorization_after_the_tag_push_is_reported(self):
        # Reordering alone, with every sentence intact: an authorization the
        # tag step has already passed is not a gate.
        start = self.text.index(f"## {AUTHORIZATION_HEADING}")
        middle = self.text.index(f"## {TAG_HEADING}")
        end = self.text.index(f"## {OBSERVE_HEADING}")
        self.assertLess(start, middle, "the two steps are not adjacent")
        planted = (
            self.text[:start]
            + self.text[middle:end]
            + self.text[start:middle]
            + self.text[end:]
        )
        self.assertEqual(authorization_gaps(planted), ["precedes-tag"])

    def test_an_authorization_with_no_recorded_comment_is_reported(self):
        planted = self.without(
            "Authorized: publish <version> from <commit>.",
            "The maintainer is happy with it.",
        )
        self.assertEqual(authorization_gaps(planted), ["recorded-comment"])

    def test_an_authorization_anything_can_satisfy_is_reported(self):
        planted = self.without(
            "no other step implies it",
            "the checklist above generally covers it",
        )
        self.assertEqual(authorization_gaps(planted), ["not-implied"])

    def test_evidence_moving_into_a_tracked_document_is_reported(self):
        planted = self.without(
            "No permanent per-release Markdown file is created",
            "Each release adds a subsection to the design document",
        )
        self.assertEqual(evidence_gaps(planted), ["no-markdown-file"])

    def test_an_evidence_comment_missing_an_item_is_reported(self):
        planted = self.without("- the published asset's name and its `sha256` digest;\n")
        self.assertEqual(evidence_gaps(planted), ["digest"])

    def test_a_version_literal_is_reported(self):
        planted = self.without("git tag -a v<version>", "git tag -a v1.1.0.0")
        self.assertEqual(version_literals(planted), ["1.1.0.0"])

    def test_a_candidate_that_need_not_carry_the_check_is_reported(self):
        planted = self.without(
            "required `build-test` job reports\n`success` for that exact commit",
            "pipeline is generally green",
        )
        self.assertEqual(candidate_identity_gaps(planted), ["required-check"])

    def test_an_upgrade_gate_missing_a_covered_item_is_reported(self):
        planted = self.without("- `kanban --doctor`, reporting every advertised component ready;\n")
        self.assertEqual(upgrade_coverage_gaps(planted), ["doctor"])

    def test_a_drifted_repository_description_is_reported(self):
        planted = self.without(
            REPOSITORY_DESCRIPTION, "A terminal board for GitHub."
        )
        self.assertEqual(repository_setting_gaps(planted), ["description"])

    def test_a_dropped_repository_topic_is_reported(self):
        planted = self.without("`developer-tools`, ", "")
        self.assertEqual(repository_setting_gaps(planted), ["topic:developer-tools"])

    def test_a_dependency_review_missing_a_subject_is_reported(self):
        planted = self.without("**`cabal outdated`.**", "**Everything else.**")
        self.assertEqual(dependency_review_gaps(planted), ["cabal-outdated"])

    def test_a_clean_off_cycle_review_with_nowhere_to_go_is_reported(self):
        planted = self.without("dependency-review issue", "conversation")
        self.assertEqual(dependency_review_gaps(planted), ["record-off-cycle"])

    def test_a_rule_set_is_not_vacuous_against_an_empty_document(self):
        # The blanket control: every rule reports every gap when there is no
        # document at all, so none of them can pass by finding nothing.
        for gaps, rules in (
            (tag_immutability_gaps(""), TAG_IMMUTABILITY_RULES),
            (candidate_identity_gaps(""), CANDIDATE_RULES),
            (upgrade_coverage_gaps(""), UPGRADE_ITEMS),
            (dependency_review_gaps(""), DEPENDENCY_RULES),
        ):
            with self.subTest(rules=sorted(rules)):
                self.assertEqual(gaps, sorted(rules))
        self.assertEqual(
            evidence_gaps(""), sorted(list(EVIDENCE_RULES) + list(EVIDENCE_ITEMS))
        )
        self.assertEqual(
            authorization_gaps(""),
            sorted(list(AUTHORIZATION_RULES) + ["own-step"]),
        )
        self.assertEqual(repository_setting_gaps(""), sorted(
            ["description", "empty-homepage"]
            + [f"topic:{topic}" for topic in REPOSITORY_TOPICS]
        ))


class MaintainerReleaseTemplateTests(unittest.TestCase):
    """The template's authorization gate: unchecked, its own item, naming the
    comment that satisfies it, and ahead of the tag item."""

    @classmethod
    def setUpClass(cls):
        # The directory, not the file: a checkout missing the template is a
        # regression tools/test_issue_templates.py reports, and skipping on the
        # file would hide it. Absent altogether is the packaged state -- see
        # this module's docstring.
        if not TEMPLATE_DIR.is_dir():
            raise unittest.SkipTest(f"{TEMPLATE_DIR} is absent (not a Git checkout)")
        cls.text = RELEASE_TEMPLATE.read_text(encoding="utf-8")

    def test_the_template_authorization_gate_is_intact(self):
        self.assertEqual(template_authorization_gaps(self.text), [])

    def test_a_pre_satisfied_authorization_is_reported(self):
        # The failure that would ship a release issue whose gate is already
        # met: the box arrives checked.
        planted = self.text.replace(
            "- [ ] 8. **Publication authorized.**",
            "- [x] 8. **Publication authorized.**",
        )
        self.assertNotEqual(planted, self.text, "the authorization item moved")
        self.assertEqual(template_authorization_gaps(planted), ["starts-unchecked"])

    def test_a_missing_authorization_item_is_reported(self):
        planted = re.sub(
            r"^- \[ \] 8\. \*\*Publication authorized\.\*\*.*?(?=^- \[ \] 9\.)",
            "",
            self.text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertNotEqual(planted, self.text, "the authorization item moved")
        self.assertEqual(template_authorization_gaps(planted), ["authorization-item"])

    def test_an_authorization_after_the_tag_item_is_reported(self):
        items = checklist_items(self.text)
        authorization = next(
            index for index, (_, body) in enumerate(items)
            if "publication authorized" in body
        )
        tag = next(
            index for index, (_, body) in enumerate(items)
            if "tag created on the authorized commit" in body
        )
        self.assertLess(authorization, tag)
        lines = self.text.splitlines(keepends=True)
        starts = [
            number
            for number, line in enumerate(lines)
            if CHECKLIST_ITEM_RE.match(line)
        ]
        block = lines[starts[authorization] : starts[authorization + 1]]
        rest = lines[: starts[authorization]] + lines[starts[authorization + 1] :]
        moved = rest[: starts[tag]] + block + rest[starts[tag] :]
        self.assertEqual(
            template_authorization_gaps("".join(moved)), ["precedes-tag"]
        )

    def test_an_authorization_naming_no_comment_is_reported(self):
        planted = self.text.replace(
            "`Authorized: publish <version> from <commit>.`", "approved verbally"
        )
        self.assertNotEqual(planted, self.text, "the authorization comment moved")
        self.assertEqual(template_authorization_gaps(planted), ["names-the-comment"])

    def test_the_template_points_at_the_runbook_for_the_procedure(self):
        # Requirement 7's boundary: the template drives the procedure, it does
        # not restate it. A second copy of the steps is what would drift.
        self.assertIn("docs/releasing.md", self.text)


if __name__ == "__main__":
    unittest.main()
