"""Agreement check for Kanban's two version literals.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 -m unittest tools.test_version_consistency

Issue #283: the package version lives in `kanban.cabal`'s `version:` field and
again, hard-coded, in `src/Kanban/CLI.hs`'s `infoOption "kanban <version>"`.
Nothing read either one, so `kanban --version` could report a version the
package had not declared and no gate would notice. This module is that gate. It
does not deduplicate the literals into one source -- that stays out of scope --
it only holds them to agreeing.

What "diverge" means here is deliberately narrow and mechanical:

* The subject on the Cabal side is the value of the top-level `version:` field.
  `cabal-version:` is a different field and is not matched, because the pattern
  is anchored at the start of a line.
* The subject on the Haskell side is the version token inside the `infoOption`
  string literal, and the check pins the surrounding shape `kanban <version>`
  as well as the token. Rewording the literal, splitting it into concatenated
  pieces, or appending anything after the version therefore fails the check
  rather than passing it silently: dropping or respelling the `kanban `
  prefix leaves nothing to read and raises, while extra text on either side
  of the version lands inside the captured token, which then cannot equal the
  declared version. The acceptance criterion is that `kanban --version` prints
  exactly `kanban <version>`, so the prefix and the absence of a suffix are
  part of what is under test, not incidental syntax.

Fail-closed is the property, not a comment. Every way of *not* finding a
version -- an unreadable or missing file, no `version:` field, no matching
`infoOption` literal, or more than one candidate for either -- raises
`VersionLookupError` and fails the check. A version that cannot be read is
never treated as a version that agrees.

This module needs neither `cabal` nor `git`, only the two files, and both of
them ship: `kanban.cabal` through `RELEASE_ROOT_FILES` and `src/Kanban/CLI.hs`
through the `src` tree in `RELEASE_TREES`, both in
`tools/test_source_distribution.py`. Since `tools/` ships whole and the
packaged `README.md` advertises the `unittest discover` command that collects
this file, it runs from an unpacked release exactly as it runs in a checkout.
There is no environment it has to skip in.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CABAL_PATH = REPO_ROOT / "kanban.cabal"
CLI_PATH = REPO_ROOT / "src" / "Kanban" / "CLI.hs"

# The top-level `version:` field. Anchored at the start of a line so that
# `cabal-version:` -- a different field with its own values -- cannot match.
CABAL_VERSION = re.compile(r"^version:[ \t]*(\S+)[ \t]*$", re.MULTILINE)

# The hard-coded `--version` output. The `kanban ` prefix and the closing quote
# are part of the pattern, so the whole advertised shape is pinned and not just
# the digits inside it.
CLI_VERSION = re.compile(r'infoOption\s+"kanban ([^"]*)"')


class VersionLookupError(Exception):
    """A version literal could not be read or parsed. Always a failure."""


def read_text(path):
    """The file's text, or a stated failure. A version that cannot be read is
    never a version that agrees."""
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise VersionLookupError(f"{path} could not be read: {error}") from error


def cabal_version(text, source="kanban.cabal"):
    """The value of the top-level `version:` field."""
    found = CABAL_VERSION.findall(text)
    if not found:
        raise VersionLookupError(
            f"{source} declares no top-level `version:` field, so the package "
            "version cannot be read."
        )
    if len(found) > 1:
        raise VersionLookupError(
            f"{source} declares {len(found)} top-level `version:` fields "
            f"({', '.join(found)}), so the package version is ambiguous."
        )
    return found[0]


def cli_version(text, source="src/Kanban/CLI.hs"):
    """The version token inside `infoOption "kanban <version>"`."""
    found = CLI_VERSION.findall(text)
    if not found:
        raise VersionLookupError(
            f'{source} contains no `infoOption "kanban <version>"` literal, so '
            "the version `--version` prints cannot be read. A reworded or "
            "reformatted literal fails here rather than passing unchecked."
        )
    if len(found) > 1:
        raise VersionLookupError(
            f"{source} contains {len(found)} `infoOption \"kanban <version>\"` "
            f"literals ({', '.join(found)}), so the printed version is ambiguous."
        )
    return found[0]


def divergence(cabal_text, cli_text):
    """The mismatch between the two literals, or None when they agree."""
    declared = cabal_version(cabal_text)
    printed = cli_version(cli_text)
    if declared == printed:
        return None
    return (
        f"kanban.cabal declares version {declared!r} but src/Kanban/CLI.hs "
        f"prints {printed!r}; `kanban --version` must print "
        f"exactly `kanban {declared}`."
    )


# Divergent stand-ins for the two real files, kept minimal so the detector is
# exercised against a mismatch it must report rather than against prose.
FIXTURE_CABAL = """cabal-version:      3.0
name:               kanban
version:            1.0.0.0
synopsis:           Fixture
"""

FIXTURE_CLI = """versionOption :: Parser (a -> a)
versionOption = infoOption "kanban 0.9.0.0" (long "version" <> help "Show version")
"""


class VersionConsistency(unittest.TestCase):
    def test_the_two_literals_agree(self):
        self.assertIsNone(
            divergence(read_text(CABAL_PATH), read_text(CLI_PATH)),
            "kanban.cabal's version and src/Kanban/CLI.hs's `--version` literal "
            "must name the same version.",
        )

    def test_both_readers_find_a_version_in_the_real_files(self):
        # Shape only. Pinning the number here would make a later release bump
        # fail a check whose subject is agreement, not any particular version.
        for source, version in (
            ("kanban.cabal", cabal_version(read_text(CABAL_PATH))),
            ("src/Kanban/CLI.hs", cli_version(read_text(CLI_PATH))),
        ):
            with self.subTest(source=source):
                self.assertRegex(version, r"^\d+(\.\d+)*$")

    def test_a_divergence_is_reported(self):
        # The detector is load-bearing rather than decorative: point it at
        # fixtures whose literals disagree and it names both sides.
        report = divergence(FIXTURE_CABAL, FIXTURE_CLI)
        self.assertIsNotNone(report, "Divergent literals must be reported.")
        self.assertIn("1.0.0.0", report)
        self.assertIn("0.9.0.0", report)

    def test_changing_either_literal_alone_diverges(self):
        # Both directions, because a bump can be forgotten on either side.
        agreeing_cli = FIXTURE_CLI.replace("0.9.0.0", "1.0.0.0")
        self.assertIsNone(divergence(FIXTURE_CABAL, agreeing_cli))
        self.assertIsNotNone(
            divergence(FIXTURE_CABAL.replace("1.0.0.0", "1.1.0.0"), agreeing_cli),
            "Bumping kanban.cabal alone must be reported.",
        )
        self.assertIsNotNone(
            divergence(FIXTURE_CABAL, agreeing_cli.replace("1.0.0.0", "1.1.0.0")),
            "Bumping the CLI literal alone must be reported.",
        )


class FailsClosed(unittest.TestCase):
    def test_a_missing_file_is_a_failure(self):
        with self.assertRaises(VersionLookupError):
            read_text(REPO_ROOT / "kanban.cabal.does-not-exist")

    def test_a_directory_in_place_of_a_file_is_a_failure(self):
        with self.assertRaises(VersionLookupError):
            read_text(REPO_ROOT / "src")

    def test_a_package_without_a_version_field_is_a_failure(self):
        with self.assertRaises(VersionLookupError):
            cabal_version("cabal-version:      3.0\nname:               kanban\n")

    def test_an_indented_version_field_is_not_the_package_version(self):
        # `version:` inside a stanza is some other stanza's field, so it must
        # not be mistaken for the package's own.
        with self.assertRaises(VersionLookupError):
            cabal_version("name: kanban\nlibrary\n  version: 9.9.9.9\n")

    def test_two_version_fields_are_a_failure(self):
        with self.assertRaises(VersionLookupError):
            cabal_version("version: 1.0.0.0\nversion: 2.0.0.0\n")

    def test_a_missing_cli_literal_is_a_failure(self):
        with self.assertRaises(VersionLookupError):
            cli_version('versionOption = infoOption "1.0.0.0" (long "version")')

    def test_a_literal_without_the_kanban_prefix_is_a_failure(self):
        # Losing the prefix, or spelling it differently, is a lookup failure:
        # there is no `kanban <version>` literal left to read.
        for literal in (
            'infoOption "1.0.0.0" (long "version")',
            'infoOption "Kanban 1.0.0.0" (long "version")',
            'infoOption ("kanban " <> "1.0.0.0") (long "version")',
        ):
            with self.subTest(literal=literal):
                with self.assertRaises(VersionLookupError):
                    cli_version(literal)

    def test_a_literal_that_is_not_exactly_kanban_version_does_not_agree(self):
        # The other half of pinning the shape. These do parse, but the token
        # carries the extra text, so it cannot equal the declared version --
        # which is how `kanban <version>` stays exact rather than approximate.
        for literal in (
            'infoOption "kanban version 1.0.0.0" (long "version")',
            'infoOption "kanban 1.0.0.0 (dev)" (long "version")',
            'infoOption "kanban  1.0.0.0" (long "version")',
        ):
            with self.subTest(literal=literal):
                self.assertNotEqual(cli_version(literal), "1.0.0.0")
                self.assertIsNotNone(
                    divergence(FIXTURE_CABAL, literal),
                    "A literal that is not exactly `kanban <version>` must be "
                    "reported.",
                )

    def test_two_cli_literals_are_a_failure(self):
        with self.assertRaises(VersionLookupError):
            cli_version('infoOption "kanban 1.0.0.0" x\ninfoOption "kanban 2.0.0.0" y')


if __name__ == "__main__":
    unittest.main()
