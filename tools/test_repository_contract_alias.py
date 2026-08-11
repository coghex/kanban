"""Equality check for the two names the repository contract is read under.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 -m unittest tools.test_repository_contract_alias

Issue #242: the repository contract lives in `CLAUDE.md`, which a Claude
session reads by name. A Codex session reads `AGENTS.md` and nothing else, so
without that second name a Codex session in this checkout operates with no lane
rules, no never-merge rule, and no quality gates. `AGENTS.md` is therefore a
repository-relative symlink to `CLAUDE.md`: one contract, two entry points, no
second copy to drift.

A symlink satisfies that trivially, which is exactly why it is checked rather
than assumed. What the check has to survive is somebody replacing the link with
a copy -- at which point the two names hold two contracts and the copy silently
falls behind. So this module follows `AGENTS.md` and compares its bytes with
`CLAUDE.md`'s. Bytes, not normalized text: "exact content" has to mean a
trailing-newline or line-ending difference fails too, since a diverged copy
usually starts out differing by no more than that.

The failure modes are enumerated rather than collapsed into one "is it usable"
predicate, because each has a different repair: the alias can be absent, be a
dangling link, be a directory, point outside the repository, or resolve to
different bytes. An absolute or checkout-specific symlink target is rejected on
sight even though it resolves on the author's machine -- the requirement is that
a *fresh checkout* reads one contract.

`tools/test_source_distribution.py` reuses `alias_gap` against the unpacked
archive, so the packaged tree has to carry the same guarantee.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# The name a Codex session reads, and the name it must resolve to.
ALIAS_NAME = "AGENTS.md"
CONTRACT_NAME = "CLAUDE.md"

# The only symlink target that works in a fresh checkout on any machine.
EXPECTED_LINK_TARGET = CONTRACT_NAME


def alias_gap(root=REPO_ROOT):
    """Why `AGENTS.md` does not resolve to `CLAUDE.md`'s exact content under
    `root`, as a repair-shaped sentence, or None when it does."""
    root = Path(root)
    alias = root / ALIAS_NAME
    contract = root / CONTRACT_NAME

    # The alias's own integrity first, then the contract it points at, so a
    # dangling link is reported as the broken link it is rather than as a
    # missing contract: the two need different repairs.

    # lexists, so a dangling link reaches the branch below instead of counting
    # as absent.
    if not os.path.lexists(alias):
        return (
            f"{ALIAS_NAME} is absent from {root}, so a Codex session there "
            f"reads no repository contract. Add it as the symlink "
            f"`ln -s {EXPECTED_LINK_TARGET} {ALIAS_NAME}`."
        )

    if alias.is_symlink():
        target = os.readlink(alias)
        if os.path.normpath(target) != EXPECTED_LINK_TARGET:
            return (
                f"{ALIAS_NAME} under {root} is a symlink to {target!r}, not to "
                f"the repository-relative {EXPECTED_LINK_TARGET}. An absolute "
                "or escaping target resolves only where it was created, not in "
                "a fresh checkout."
            )
        if not alias.exists():
            return (
                f"{ALIAS_NAME} under {root} is a dangling symlink to "
                f"{target!r}; it resolves to nothing."
            )

    if alias.is_dir():
        return f"{ALIAS_NAME} under {root} is a directory, not the contract."

    if not contract.is_file():
        return (
            f"{CONTRACT_NAME} is missing from {root}, so there is no contract "
            f"for {ALIAS_NAME} to alias."
        )

    if not alias.is_file():
        return (
            f"{ALIAS_NAME} under {root} does not resolve to a regular file, so "
            f"it cannot carry {CONTRACT_NAME}'s content."
        )

    try:
        alias_bytes = alias.read_bytes()
        contract_bytes = contract.read_bytes()
    except OSError as error:
        return f"{ALIAS_NAME} under {root} could not be read: {error}."

    if alias_bytes != contract_bytes:
        return (
            f"{ALIAS_NAME} under {root} resolves to {len(alias_bytes)} bytes "
            f"but {CONTRACT_NAME} holds {len(contract_bytes)}; the two names no "
            "longer carry one contract. Restore the symlink rather than "
            "re-syncing a copy."
        )

    return None


def _fixture(root, alias=None, contract="contract\n", link_target=None):
    """A miniature checkout: `CLAUDE.md` holding `contract`, plus whatever
    `AGENTS.md` is supposed to be. The negative cases run against these rather
    than against the live tree, so each one fails for its own reason."""
    root = Path(root)
    if contract is not None:
        (root / CONTRACT_NAME).write_text(contract, encoding="utf-8")
    if link_target is not None:
        os.symlink(link_target, root / ALIAS_NAME)
    elif alias is not None:
        (root / ALIAS_NAME).write_text(alias, encoding="utf-8")
    return root


class ContractAliasTests(unittest.TestCase):
    """The live tree: `AGENTS.md` is tracked and holds the contract."""

    def test_the_alias_resolves_to_the_contract(self):
        self.assertIsNone(alias_gap())

    def test_the_alias_is_tracked(self):
        proc = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "ls-files", "--", ALIAS_NAME],
            text=True,
            capture_output=True,
        )
        if proc.returncode != 0:
            self.skipTest(
                f"{REPO_ROOT} is not a readable Git checkout, so the tracked "
                "file set cannot be inspected; this runs in a checkout, not "
                "from an unpacked release."
            )
        self.assertEqual(
            proc.stdout.split(),
            [ALIAS_NAME],
            f"{ALIAS_NAME} must be tracked: an untracked local file gives a "
            "Codex session in a fresh clone no contract at all.",
        )

    def test_the_alias_is_a_repository_relative_symlink(self):
        alias = REPO_ROOT / ALIAS_NAME
        self.assertTrue(alias.is_symlink(), f"{ALIAS_NAME} is not a symlink")
        self.assertEqual(os.readlink(alias), EXPECTED_LINK_TARGET)


class AliasGapTests(unittest.TestCase):
    """The check is load-bearing rather than decorative: point it at a checkout
    with each way the alias can break and it names that one."""

    def gap_for(self, **fixture):
        with tempfile.TemporaryDirectory(prefix="kanban-alias-") as temp_dir:
            return alias_gap(_fixture(temp_dir, **fixture))

    def test_a_correct_symlink_passes(self):
        self.assertIsNone(self.gap_for(link_target=EXPECTED_LINK_TARGET))

    def test_a_dot_slash_symlink_target_passes(self):
        # `./CLAUDE.md` is the same repository-relative target spelled longer.
        self.assertIsNone(self.gap_for(link_target=f"./{CONTRACT_NAME}"))

    def test_an_identical_regular_copy_passes(self):
        # Requirement 1 allows an alternative that preserves one source of
        # truth, so this check tests content rather than file type.
        self.assertIsNone(self.gap_for(alias="contract\n"))

    def test_an_absent_alias_is_reported(self):
        self.assertIn("is absent", self.gap_for() or "")

    def test_an_absent_contract_is_reported(self):
        self.assertIn(
            "is missing", self.gap_for(contract=None, alias="contract\n") or ""
        )

    def test_a_dangling_symlink_is_reported(self):
        # Right target, nothing there: reported as the broken link rather than
        # as an absent alias or an absent contract.
        self.assertIn(
            "dangling",
            self.gap_for(link_target=EXPECTED_LINK_TARGET, contract=None) or "",
        )

    def test_a_symlink_to_the_wrong_file_is_reported(self):
        self.assertIn("not to the", self.gap_for(link_target="README.md") or "")

    def test_an_absolute_symlink_target_is_reported(self):
        # Resolves on the machine that made it; gives a fresh checkout nothing.
        gap = self.gap_for(link_target=str(REPO_ROOT / CONTRACT_NAME))
        self.assertIn("fresh checkout", gap or "")

    def test_an_escaping_symlink_target_is_reported(self):
        self.assertIn("not to the", self.gap_for(link_target=f"../{CONTRACT_NAME}") or "")

    def test_a_diverged_regular_copy_is_reported(self):
        self.assertIn("one contract", self.gap_for(alias="contract, revised\n") or "")

    def test_a_copy_differing_only_in_trailing_newline_is_reported(self):
        # The byte comparison the review required: normalized text comparison
        # passes this, and this is how a copy usually starts to diverge.
        self.assertIn("one contract", self.gap_for(alias="contract") or "")

    def test_a_copy_differing_only_in_line_endings_is_reported(self):
        self.assertIn("one contract", self.gap_for(alias="contract\r\n") or "")

    def test_a_directory_at_the_alias_path_is_reported(self):
        with tempfile.TemporaryDirectory(prefix="kanban-alias-") as temp_dir:
            root = _fixture(temp_dir)
            (root / ALIAS_NAME).mkdir()
            self.assertIn("is a directory", alias_gap(root) or "")

    def test_a_symlink_to_a_directory_is_reported(self):
        # Right target name, wrong kind of thing at it.
        with tempfile.TemporaryDirectory(prefix="kanban-alias-") as temp_dir:
            root = Path(temp_dir)
            (root / CONTRACT_NAME).mkdir()
            os.symlink(EXPECTED_LINK_TARGET, root / ALIAS_NAME)
            self.assertIn("is a directory", alias_gap(root) or "")

    def test_an_alias_that_is_not_a_regular_file_is_reported(self):
        # The catch-all after the named kinds: something that is neither a
        # regular file nor a directory still fails closed rather than being
        # read as the contract.
        with tempfile.TemporaryDirectory(prefix="kanban-alias-") as temp_dir:
            root = _fixture(temp_dir)
            try:
                os.mkfifo(root / ALIAS_NAME)
            except (AttributeError, NotImplementedError, OSError) as error:
                self.skipTest(f"named pipes are unavailable here: {error}")
            self.assertIn("regular file", alias_gap(root) or "")


if __name__ == "__main__":
    unittest.main()
