"""Contract check for .github/pull_request_template.md (issue #494).

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

The template must carry no `pr-origin` marker anywhere, its own explanatory
ORIGIN COMMENT included. That is not a style preference: three parsers route on
that marker, and each of them counts occurrences across the whole body with no
awareness of HTML comments.

* `src/Kanban/PullRequestFlow.hs`'s `originFromBody` counts each exact marker
  over the complete body: both brands present is
  `PR body contains both pr-origin markers`, and either brand twice is
  `PR body contains a duplicate pr-origin marker`.
* Both packaged coordinators' `origin_from_body`
  (`claude-plugin/plugins/kanban/scripts/review_pr.py` and
  `codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py`) reject on
  `body.count("pr-origin:") != 1`, then convert the rejection to `None`, which
  `route_reviewers` reads as unknown origin and sends to both brands.

So an editor who pastes a marker into the ORIGIN COMMENT to show a contributor
what one looks like -- the exact mistake that comment warns against -- turns
every agent-authored pull request opened from the template into a
duplicate-marker body. The Haskell reader surfaces that as a notice
(`src/Kanban/UI/PullRequest.hs`) or halts autosolve
(`src/Kanban/UI/AutoSolve.hs`); the two coordinators silently route the review
to both brands, reaching the self-review hazard by another door. Required CI
stays green throughout.

Issue #435 made this a requirement and checkable, but discharged it by hand in
PR #456's body. This module is the committed equivalent, and the Python half of
it: the Haskell parser is exercised the same way by
`test/Spec/Agent/PullRequestFlow.hs`, which reads this same tracked file.

Both assertions per coordinator are load bearing, and neither subsumes the
other:

* Against the template as it stands, `origin_from_body` must report no origin.
  This is what catches a marker pasted anywhere ahead of the body's end.
* Against the template with `<!-- pr-origin:claude -->` appended -- the body an
  agent actually opens -- it must report `claude`. This is the negative control
  proving the rule above can tell a marked template from an unmarked one, and
  it is also what catches a stray `pr-origin:` spelling the first assertion
  cannot see: a second occurrence anywhere, marker-shaped or not, makes the
  count check reject the composed body.

The rule is run through each coordinator's own function rather than a regex
restated here, so what is checked is what actually routes.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TEMPLATE_PATH = ".github/pull_request_template.md"
TEMPLATE = REPO_ROOT / TEMPLATE_PATH

# The two vendored copies of the review coordinator. Each bundle ships its own
# (docs/agent-workflow-contract.md §3), and tools/test_coordinator_parity.py
# bounds how far they may diverge -- so both are exercised here rather than one
# standing in for the other.
COORDINATORS = {
    "claude": REPO_ROOT
    / "claude-plugin"
    / "plugins"
    / "kanban"
    / "scripts"
    / "review_pr.py",
    "codex": REPO_ROOT
    / "codex-plugin"
    / "plugins"
    / "kanban"
    / "skills"
    / "pr-review"
    / "scripts"
    / "review_pr.py",
}

# The marker an agent-authored body ends with. Spelled here, in a module no
# parser reads, rather than in the template.
CLAUDE_MARKER = "<!-- pr-origin:claude -->"


def load_coordinator(brand: str):
    """One coordinator, loaded from its own path under a private name so the
    copy loaded here can never shadow a discovered module, the way
    tools/test_self_review_caller_brand.py loads them."""
    source = COORDINATORS[brand]
    name = f"_kanban_pull_request_template_{brand}_review_pr"
    spec = importlib.util.spec_from_file_location(name, source)
    if spec is None or spec.loader is None:
        raise AssertionError(f"could not import {source}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except Exception:
        del sys.modules[name]
        raise
    return module


class PullRequestTemplateOriginTests(unittest.TestCase):
    """Requirement 1: no `pr-origin` marker survives in the tracked template,
    checked through the parsers that route on it."""

    @classmethod
    def setUpClass(cls):
        # The tracked file itself, not a copy or an excerpt: what GitHub
        # pre-fills is the only text this contract is about. It ships in the
        # source distribution (`RELEASE_DOCUMENTS` in
        # tools/test_source_distribution.py), so an unpacked release has it to
        # read and this module needs no skip for one.
        cls.template = TEMPLATE.read_text(encoding="utf-8")
        cls.coordinators = {
            brand: load_coordinator(brand) for brand in COORDINATORS
        }

    def test_no_coordinator_reads_an_origin_from_the_template(self):
        for brand, module in self.coordinators.items():
            with self.subTest(coordinator=brand):
                self.assertIsNone(
                    module.origin_from_body(self.template),
                    f"{TEMPLATE_PATH} carries a pr-origin marker, which the "
                    f"{brand} coordinator would read as an origin",
                )

    def test_every_coordinator_reads_the_appended_marker(self):
        # The negative control, and the body an agent actually opens: the
        # template plus its own trailing marker must route to exactly one
        # brand. A stray marker or `pr-origin:` spelling anywhere in the
        # template makes this composed body ambiguous, and each coordinator
        # answers None instead.
        marked = f"{self.template.rstrip()}\n\n{CLAUDE_MARKER}\n"
        for brand, module in self.coordinators.items():
            with self.subTest(coordinator=brand):
                self.assertEqual(
                    module.origin_from_body(marked),
                    "claude",
                    f"a pull request opened from {TEMPLATE_PATH} would not "
                    f"route by origin under the {brand} coordinator",
                )

    def test_the_template_explains_the_marker_without_spelling_it(self):
        # Requirement 5: the property the rules above protect is that the
        # template describes the convention rather than demonstrating it, so
        # the assertion anchors on text the correct file actually contains.
        # `test_issue_templates.py`'s equivalent asserts the literal
        # `issue-origin` token, which the ordinary issue template does spell --
        # every other template there delegates to it; asserting `pr-origin`
        # here would fail against the file as it should be.
        self.assertIn("ORIGIN COMMENT", self.template)
        self.assertIn("origin marker", self.template)
        # Counted rather than asserted with assertNotIn so a failure reports
        # how many spellings crept in instead of echoing the whole template.
        self.assertEqual(
            self.template.count("pr-origin"),
            0,
            f"{TEMPLATE_PATH} spells the pr-origin token, which every body "
            "opened from it then carries a second time",
        )


if __name__ == "__main__":
    unittest.main()
