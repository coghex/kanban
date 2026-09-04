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
    # A discovered worker's absent-item refusals, composed over an
    # outstanding startup line for the same reason: discovery is forked at
    # startup and routinely answers before the first publication. Three since
    # SAG-10: a discovered issue action is a third kind whose issue can be
    # absent from the cached board.
    "src/Kanban/UI/Worker.hs": 3,
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


# Every notice that tells the user a durable request is under way, and the
# source file it is announced from. Each of these follows a
# `submitReviewCommand`, and the command is only under way if that submission
# actually wrote it: a ledger that could not take the command means nothing
# was asked for, and the submission has already set the failure notice these
# would overwrite.
REQUEST_ANNOUNCEMENTS = {
    "src/Kanban/UI/Review.hs": (
        "Interrupting review #",
        "Interrupting issue review #",
    ),
    "src/Kanban/UI/Events.hs": ("Killing issue review #",),
}

# How far above an announcement its guard may sit. The guard binds the
# submission's result and the notice follows within the same short block; a
# window this size spans that and the comment between them without reaching
# into an unrelated preceding statement.
GUARD_WINDOW = 8

GUARD = re.compile(r"\bwhen\s+requested\b")


def guarded_announcements(source):
    """Each announcement in `source`, paired with whether a guard precedes it."""
    lines = source.splitlines()
    found = []
    for index, line in enumerate(lines):
        for announcement in REQUEST_ANNOUNCEMENTS_ANY:
            if announcement in line and not line.lstrip().startswith("--"):
                window = "\n".join(lines[max(0, index - GUARD_WINDOW) : index + 1])
                found.append((announcement, bool(GUARD.search(window))))
    return found


REQUEST_ANNOUNCEMENTS_ANY = tuple(
    announcement
    for announcements in REQUEST_ANNOUNCEMENTS.values()
    for announcement in announcements
)


class RequestAnnouncementTests(unittest.TestCase):
    """A notice may claim a request is under way only if it was recorded."""

    def test_every_request_announcement_is_guarded(self):
        for path, announcements in REQUEST_ANNOUNCEMENTS.items():
            source = (REPO_ROOT / path).read_text(encoding="utf-8")
            found = dict(guarded_announcements(source))
            for announcement in announcements:
                with self.subTest(path=path, announcement=announcement):
                    self.assertIn(
                        announcement,
                        found,
                        f"{path} no longer announces {announcement!r}; if the "
                        "wording moved, move it here, and if the gesture is "
                        "gone drop the row",
                    )
                    self.assertTrue(
                        found[announcement],
                        f"{path} announces {announcement!r} without checking "
                        "that its command was written. An unwritable ledger "
                        "means nothing was requested, and this overwrites the "
                        "failure notice that says so",
                    )

    def test_detector_finds_an_unguarded_announcement(self):
        # The scanner's own teeth: the guarded shape passes and the bare one
        # does not, so a rule that matched everything could not pass while
        # asserting nothing.
        guarded = (
            "      requested <- submitReviewCommand issueNumber TerminateIssueAction\n"
            "      when requested $\n"
            '        setNotice ("Killing issue review #" <> showText n)\n'
        )
        bare = (
            "      _ <- submitReviewCommand issueNumber TerminateIssueAction\n"
            '      setNotice ("Killing issue review #" <> showText n)\n'
        )
        self.assertEqual(guarded_announcements(guarded), [("Killing issue review #", True)])
        self.assertEqual(guarded_announcements(bare), [("Killing issue review #", False)])
        # A mention in prose is not an announcement.
        self.assertEqual(guarded_announcements('      -- "Killing issue review #" is set below\n'), [])


if __name__ == "__main__":
    unittest.main()
