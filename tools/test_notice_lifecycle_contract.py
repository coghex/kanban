"""The notice lifecycle's source contract (issue #590 requirement 7).

`Kanban.UI.Notice` makes the notice line's state abstract, so no producer can
show a notice except through its lifecycle transitions -- that half of the
contract is the type checker's. What the types cannot pin is *which* producers
classify their notice as active: any call site spelling `ActiveWhile`,
`noticeSetFor`, `setNoticeFor`, or `noticeSetOverStartupReport` opts a notice
out of the ten-second settled lifetime for as long as its declared activity
runs. This module holds that
inventory: the exact files, and the exact number of active-classification
sites in each, so every producer outside the inventory is settled by
construction and a new active site is a reviewed edit here rather than a
site-local judgment call.
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Every spelling that can classify a notice as active. `ActiveWhile` is the
# one constructor of the active life, `noticeSetFor` and `setNoticeFor` take a
# `NoticeActivity` on their way to it, and `noticeSetOverStartupReport` keeps
# an outstanding startup line active by composing onto it; a new helper
# wrapping any of these belongs in this family the moment it exists.
ACTIVE_SPELLINGS = ("ActiveWhile", "noticeSetFor", "setNoticeFor", "noticeSetOverStartupReport")

ACTIVE_TOKEN = re.compile(r"\b(?:" + "|".join(ACTIVE_SPELLINGS) + r")\b")

# The declared inventory: every source file allowed to classify a notice as
# active, with its exact number of active-classification tokens -- export and
# import list mentions included, since a module that stops importing a helper
# has genuinely left the inventory. Everything under src/ absent from this
# table must contain none at all -- which is the "every other notice producer
# is settled" assertion.
ACTIVE_SITES = {
    # The abstract machine itself: the `ActiveWhile` constructor's declaration
    # and the settle transition that reads it.
    "src/Kanban/UI/Notice.hs": 2,
    # The pure entry point `noticeSetFor` (export list, signature, defining
    # equation, and its body's `ActiveWhile`) and the composition
    # `noticeSetOverStartupReport` (export list, signature, defining
    # equation, and its `noticeSetFor`), which keeps a startup line carrying
    # its one-time diagnostics active rather than replaced.
    "src/Kanban/UI/Util.hs": 8,
    # The `EventM` wrapper `setNoticeFor` over the entry point: export list,
    # signature, defining equation, and the `noticeSetFor` it delegates to.
    "src/Kanban/UI/State.hs": 4,
    # The composed startup notice, riding the startup fetch: shown at
    # launch, and re-shown by `restoreStartupNotice` over the announcements
    # the startup refreshes themselves make.
    "src/Kanban/UI.hs": 2,
    # `Refreshing GitHub…` / `GitHub refresh is already running` over the
    # direct-merge carry, and both providers' usage-refresh notices, running
    # and already-running alike.
    "src/Kanban/UI/Refresh.hs": 5,
    # The quit's `Stopping GitHub work…`, twice — the first press and the
    # re-press while the cleanup is still settling — plus the history pause
    # composed over an outstanding startup line.
    "src/Kanban/UI/Events.hs": 3,
    # The drainer toggle's optimistic report and the direct merge's
    # `Merging PR #n…`.
    "src/Kanban/UI/PullRequest.hs": 2,
    # The approval service toggle's optimistic report, plus the helper's
    # import.
    "src/Kanban/UI/Approval.hs": 2,
    # The usage results and the completed-cache warning, each composed over
    # an outstanding startup line rather than allowed to replace it.
    "src/Kanban/UI/Reconcile.hs": 3,
}


def strip_comments(source: str) -> str:
    """Drop `--` line comments and `{- -}` block comments before counting.

    A doc comment naming `ActiveWhile` is prose, not a classification site,
    and counting it would make every comment edit a contract edit.
    """
    without_blocks = re.sub(r"\{-.*?-\}", "", source, flags=re.DOTALL)
    return "\n".join(line.split("--", 1)[0] for line in without_blocks.splitlines())


def active_token_count(source: str) -> int:
    return len(ACTIVE_TOKEN.findall(strip_comments(source)))


def active_sites_in_tree() -> dict:
    counts = {}
    for path in sorted((REPO_ROOT / "src").rglob("*.hs")):
        count = active_token_count(path.read_text(encoding="utf-8"))
        if count:
            counts[path.relative_to(REPO_ROOT).as_posix()] = count
    return counts


class NoticeActiveInventoryTests(unittest.TestCase):
    def test_every_producer_outside_the_inventory_is_settled(self):
        counts = active_sites_in_tree()
        # The negative control is per-declared-file: an inventory row the
        # detector recovers nothing from is asserting nothing.
        for relative_path in sorted(ACTIVE_SITES):
            with self.subTest(declared=relative_path):
                self.assertIn(
                    relative_path,
                    counts,
                    f"{relative_path} is declared an active-notice site but the "
                    "detector recovers no active-classification spelling from "
                    "it; the inventory row is asserting nothing",
                )
        self.assertEqual(
            counts,
            ACTIVE_SITES,
            "the set of active-notice classification sites moved. A producer "
            "may keep a notice past the ten-second lifetime only by naming a "
            "NoticeActivity the inventory in Kanban.UI.Util.noticeActivityLive "
            "tracks; declare the new or removed site here with what keeps it "
            "alive, and leave every other producer settled",
        )

    def test_detector_detects_each_spelling(self):
        # The scanner's own teeth, per spelling and against its blind spots:
        # a planted call site of each family member is found, whatever its
        # spacing, and a comment or block comment mentioning one is not.
        for spelling in ACTIVE_SPELLINGS:
            with self.subTest(spelling=spelling):
                self.assertEqual(active_token_count(f"x = {spelling} y\n"), 1)
                self.assertEqual(active_token_count(f"x =\n  {spelling}\n    y\n"), 1)
                self.assertEqual(active_token_count(f"-- {spelling} in prose\n"), 0)
                self.assertEqual(active_token_count(f"{{- {spelling} -}}\nx = 1\n"), 0)
        # A lookalike identifier is not the family.
        self.assertEqual(active_token_count("x = noticeSetForever y\n"), 0)
        self.assertEqual(active_token_count("x = reActiveWhile y\n"), 0)


if __name__ == "__main__":
    unittest.main()
