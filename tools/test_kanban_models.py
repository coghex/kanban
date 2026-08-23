"""The Python model-roster reader, against the behavior src/Kanban/Models.hs
defines.

That module is the authoritative implementation and this one mirrors it, so the
cases here are its vocabulary rather than a fresh invention: the compiled
defaults cell for cell, the absent-versus-unusable split D-3 fixes, every defect
constructor `RosterDefect` names, and the XDG path resolution both sides share.
A reader that quietly answered "the defaults" for a file it could not read
would let an operator who edited a model go on running agents on the old one,
which is the single failure this whole layer exists to prevent.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
"""

from __future__ import annotations

import os
import tempfile
import tomllib
import unittest
from pathlib import Path
from unittest import mock

import kanban_models


REPO_ROOT = Path(__file__).resolve().parent.parent
MODELS_TOML_EXAMPLE = REPO_ROOT / "models.toml.example"
EXAMPLE = MODELS_TOML_EXAMPLE.read_text(encoding="utf-8")


def roster_file(directory: Path, text: str) -> Path:
    """The file this reader looks for under a configuration root."""
    path = Path(directory) / "kanban" / "models.toml"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


class CompiledDefaultsTests(unittest.TestCase):
    """`DEFAULT_ROSTER` equals the tracked example, cell for cell.

    The same hold `Spec.Config.Models` puts on the Haskell defaults, from this
    side: the example is what an operator copies to start editing, and a reader
    whose compiled answer differed from it would change models the moment
    someone saved an unmodified copy.
    """

    def test_the_compiled_defaults_decode_from_the_tracked_example(self):
        self.assertEqual(
            kanban_models.decode_roster(EXAMPLE, MODELS_TOML_EXAMPLE),
            kanban_models.DEFAULT_ROSTER,
        )

    def test_every_applicable_cell_is_valued(self):
        expected = {
            (role, provider)
            for role in kanban_models.ROLES
            for provider in kanban_models.role_applicability(role)
        }
        self.assertEqual(set(kanban_models.DEFAULT_ROSTER.assignments), expected)
        self.assertEqual(len(expected), 13)

    def test_issue_revise_is_claude_only_and_the_rest_are_both(self):
        self.assertEqual(kanban_models.role_applicability("issue_revise"), ("claude",))
        for role in kanban_models.ROLES:
            if role == "issue_revise":
                continue
            with self.subTest(role=role):
                self.assertEqual(
                    kanban_models.role_applicability(role), kanban_models.PROVIDERS
                )

    def test_the_spawn_cells_this_slice_migrated_carry_todays_values(self):
        # Requirement 16: with no roster file present, every argv these scripts
        # build is byte-identical to what the retired literals produced.
        for cell, expected in (
            (("issue_gate", "codex"), ("gpt-5.6-sol", "xhigh")),
            (("issue_gate", "claude"), ("claude-opus-5", "xhigh")),
            (("drain_rereview", "codex"), ("gpt-5.6-terra", "medium")),
            (("pr_review", "codex"), ("gpt-5.6-terra", "xhigh")),
            (("pr_review", "claude"), ("claude-opus-5", "xhigh")),
        ):
            with self.subTest(cell=cell):
                assignment = kanban_models.DEFAULT_ROSTER.assignment_for(*cell)
                self.assertEqual((assignment.model, assignment.effort), expected)


class RosterPathTests(unittest.TestCase):
    """`models.toml` under the XDG configuration root, resolved exactly as
    `Kanban.Models.rosterPath` and `kanban_config.default_config_path` do."""

    def test_xdg_config_home_decides_when_it_is_set(self):
        with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": "/somewhere/xdg"}):
            self.assertEqual(
                kanban_models.default_roster_path(),
                Path("/somewhere/xdg/kanban/models.toml"),
            )

    def test_the_conventional_directory_applies_when_it_is_not(self):
        environment = {key: value for key, value in os.environ.items()}
        environment.pop("XDG_CONFIG_HOME", None)
        with mock.patch.dict(os.environ, environment, clear=True):
            with mock.patch.object(Path, "home", staticmethod(lambda: Path("/h"))):
                self.assertEqual(
                    kanban_models.default_roster_path(),
                    Path("/h/.config/kanban/models.toml"),
                )

    def test_the_default_path_is_what_load_roster_reads(self):
        # Resolved per call rather than frozen at import, so a process that
        # redirects the configuration root is honored.
        with tempfile.TemporaryDirectory() as tmp:
            roster_file(
                Path(tmp),
                EXAMPLE.replace('model = "gpt-5.6-sol"', 'model = "gpt-5.5"'),
            )
            with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": tmp}):
                assignment = kanban_models.resolve_assignment("issue_gate", "codex")
        self.assertEqual(assignment.model, "gpt-5.5")


class AbsentFileTests(unittest.TestCase):
    """The fresh-install path, and the only absence D-3 makes silent."""

    def test_no_file_at_all_is_the_compiled_defaults(self):
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "kanban" / "models.toml"
            self.assertEqual(
                kanban_models.load_roster(missing), kanban_models.DEFAULT_ROSTER
            )

    def test_a_fallback_stands_in_for_the_defaults_only_when_absent(self):
        stand_in = kanban_models.Assignment("gpt-5.4", "low", "stand-in")
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "kanban" / "models.toml"
            self.assertEqual(
                kanban_models.resolve_assignment(
                    "pr_review", "codex", fallback=stand_in, explicit_path=missing
                ),
                stand_in,
            )
            # And a present, valid file beats it: a fallback is what a bundled
            # consumer declares for a host with no roster, never a value that
            # outranks one the operator wrote.
            present = roster_file(Path(tmp), EXAMPLE)
            self.assertEqual(
                kanban_models.resolve_assignment(
                    "pr_review", "codex", fallback=stand_in, explicit_path=present
                ).model,
                "gpt-5.6-terra",
            )

    def test_a_fallback_does_not_rescue_a_present_unusable_file(self):
        stand_in = kanban_models.Assignment("gpt-5.4", "low", "stand-in")
        with tempfile.TemporaryDirectory() as tmp:
            broken = roster_file(Path(tmp), "schema_version = 1\nagents = 7\n")
            with self.assertRaises(kanban_models.RosterError):
                kanban_models.resolve_assignment(
                    "pr_review", "codex", fallback=stand_in, explicit_path=broken
                )


class UnreadableFileTests(unittest.TestCase):
    """Present-but-unusable, which an existence probe cannot tell from absent.

    Judged by `os.lstat` and then by `os.stat`, mirroring `loadModelRoster`.
    Only `ENOENT` is absence: a directory, a dangling link, a FIFO, and a path
    this account simply cannot reach must all refuse rather than fall through
    to the defaults, and the FIFO must refuse without being opened, because
    opening one blocks until a writer connects.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def assert_unreadable(self, path: Path) -> str:
        with self.assertRaises(kanban_models.RosterError) as caught:
            kanban_models.load_roster(path)
        message = str(caught.exception)
        self.assertIn(str(path), message)
        self.assertIn("could not be read", message)
        return message

    def test_a_directory_at_the_path_refuses(self):
        directory = self.root / "models.toml"
        directory.mkdir()
        self.assertIn("not a regular file", self.assert_unreadable(directory))

    def test_a_dangling_symlink_refuses_rather_than_reading_as_absent(self):
        # The link itself exists, so this is present-but-unusable. Resolving it
        # is what fails, exactly as `getFileStatus` does on the Haskell side --
        # so the refusal names that failure rather than the file's kind.
        link = self.root / "models.toml"
        link.symlink_to(self.root / "gone.toml")
        self.assert_unreadable(link)

    def test_an_unreachable_parent_directory_refuses_rather_than_defaulting(self):
        # The case a `lexists`/`is_file` probe cannot report: both answer False
        # for *every* OSError, so a permission refusal on the way to the file
        # would read exactly like a file that was never created -- and hand the
        # caller the compiled defaults for a roster it could not even look at.
        if os.geteuid() == 0:
            self.skipTest("root traverses a 0000 directory, so the mode proves nothing")
        closed = self.root / "closed"
        closed.mkdir()
        roster = closed / "models.toml"
        roster.write_text(EXAMPLE, encoding="utf-8")
        closed.chmod(0o000)
        self.addCleanup(closed.chmod, 0o700)
        with self.assertRaises(kanban_models.RosterError) as caught:
            kanban_models.load_roster(roster)
        self.assertIn(str(roster), str(caught.exception))
        self.assertIn("could not be read", str(caught.exception))

    def test_an_unreachable_parent_refuses_every_consumer_path_alike(self):
        # Through the accessor a spawn site actually calls, and through the
        # fallback a bundled consumer declares: neither may recover.
        if os.geteuid() == 0:
            self.skipTest("root traverses a 0000 directory, so the mode proves nothing")
        closed = self.root / "closed-consumer"
        closed.mkdir()
        roster = closed / "models.toml"
        roster.write_text(EXAMPLE, encoding="utf-8")
        closed.chmod(0o000)
        self.addCleanup(closed.chmod, 0o700)
        stand_in = kanban_models.Assignment("gpt-5.4", "low", "stand-in")
        for fallback in (None, stand_in):
            with self.subTest(fallback=fallback):
                with self.assertRaises(kanban_models.RosterError):
                    kanban_models.resolve_assignment(
                        "issue_gate", "codex", fallback=fallback, explicit_path=roster
                    )

    def test_a_missing_parent_directory_is_still_plain_absence(self):
        # The fresh-install path goes through the same lstat: no
        # `~/.config/kanban` at all is ENOENT, which is the one absence D-3
        # makes silent.
        missing = self.root / "never-made" / "kanban" / "models.toml"
        self.assertEqual(
            kanban_models.load_roster(missing), kanban_models.DEFAULT_ROSTER
        )

    def test_a_fifo_refuses_without_being_opened(self):
        fifo = self.root / "models.toml"
        os.mkfifo(fifo)
        # No reader is ever attached, so a test that reached an `open` would
        # hang here rather than fail.
        self.assertIn("not a regular file", self.assert_unreadable(fifo))

    def test_a_symlink_to_a_regular_file_stays_loadable(self):
        target = self.root / "real.toml"
        target.write_text(EXAMPLE, encoding="utf-8")
        link = self.root / "models.toml"
        link.symlink_to(target)
        self.assertEqual(kanban_models.load_roster(link), kanban_models.DEFAULT_ROSTER)

    def test_a_file_this_account_cannot_read_refuses(self):
        if os.geteuid() == 0:
            self.skipTest("root reads a 0000 file, so the mode proves nothing")
        unreadable = self.root / "models.toml"
        unreadable.write_text(EXAMPLE, encoding="utf-8")
        unreadable.chmod(0o000)
        self.addCleanup(unreadable.chmod, 0o600)
        self.assert_unreadable(unreadable)


class UnparseableFileTests(unittest.TestCase):
    def test_invalid_toml_names_the_parser_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = roster_file(Path(tmp), "schema_version = [\n")
            with self.assertRaises(kanban_models.RosterError) as caught:
                kanban_models.load_roster(path)
        self.assertIn("is not parseable TOML", str(caught.exception))

    def test_bytes_that_are_not_utf8_are_a_parse_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "models.toml"
            path.write_bytes(b"schema_version = 1\n\xff\xfe\n")
            with self.assertRaises(kanban_models.RosterError) as caught:
                kanban_models.load_roster(path)
        self.assertIn("not UTF-8", str(caught.exception))


class ForeignVersionTests(unittest.TestCase):
    """A well-formed file written by another version of this schema. Its
    payload is not ours to judge, so no further validation runs."""

    def test_a_later_version_is_its_own_failure(self):
        with self.assertRaises(kanban_models.RosterError) as caught:
            kanban_models.decode_roster(
                'schema_version = 2\nagents = ["nonsense"]\n', "/x/models.toml"
            )
        message = str(caught.exception)
        self.assertIn("carries schema_version 2", message)
        self.assertIn("this build reads version 1", message)
        # The nonsense payload is deliberately not reported: judging it would
        # claim to understand a schema this build does not read.
        self.assertNotIn("is invalid", message)

    def test_a_missing_version_is_a_defect_rather_than_a_foreign_one(self):
        with self.assertRaises(kanban_models.RosterError) as caught:
            kanban_models.decode_roster("agents = []\n", "/x/models.toml")
        self.assertIn('"schema_version" is required and missing', str(caught.exception))

    def test_a_wrong_typed_version_is_a_defect(self):
        for value in ('"1"', "true", "1.0"):
            with self.subTest(value=value):
                with self.assertRaises(kanban_models.RosterError) as caught:
                    kanban_models.decode_roster(
                        f"schema_version = {value}\n", "/x/models.toml"
                    )
                self.assertIn(
                    '"schema_version" must be an integer', str(caught.exception)
                )


class DefectVocabularyTests(unittest.TestCase):
    """Every constructor `Kanban.Models.RosterDefect` names, driven here.

    Unknown keys are defects at every level rather than warnings: silently
    skipping a misspelled `[roles.pr_reveiw.codex]` is how an operator ships
    the old model believing they changed it.
    """

    def defects(self, text: str) -> str:
        with self.assertRaises(kanban_models.RosterError) as caught:
            kanban_models.decode_roster(text, "/x/models.toml")
        message = str(caught.exception)
        self.assertIn("is invalid: ", message)
        return message

    def edited(self, *replacements: tuple[str, str]) -> str:
        text = EXAMPLE
        for old, new in replacements:
            self.assertIn(old, text)
            text = text.replace(old, new, 1)
        return text

    def test_the_unedited_example_has_no_defects(self):
        # Or every case below passes vacuously: each is one edit away from a
        # file that really does decode.
        kanban_models.decode_roster(EXAMPLE, "/x/models.toml")

    def test_an_unknown_top_level_key(self):
        self.assertIn(
            '"providrs" is not a key this schema knows',
            self.defects(self.edited(("[providers.codex]", "[providrs.codex]"))),
        )

    def test_an_unknown_key_inside_a_provider_table(self):
        self.assertIn(
            '"providers.codex.modles" is not a key this schema knows',
            self.defects(
                self.edited(('models = ["gpt-5.4"', 'modles = ["gpt-5.4"'))
            ),
        )

    def test_an_unknown_key_inside_an_assignment(self):
        self.assertIn(
            '"roles.solve.codex.modle" is not a key this schema knows',
            self.defects(
                self.edited(
                    (
                        '[roles.solve.codex]\nmodel = "gpt-5.4"',
                        '[roles.solve.codex]\nmodel = "gpt-5.4"\nmodle = "x"',
                    )
                )
            ),
        )

    def test_a_missing_required_key(self):
        self.assertIn(
            '"roles.solve.codex.display" is required and missing',
            self.defects(
                self.edited(
                    (
                        '[roles.solve.codex]\nmodel = "gpt-5.4"\neffort = "high"\n'
                        'display = "gpt-5.4 high"',
                        '[roles.solve.codex]\nmodel = "gpt-5.4"\neffort = "high"',
                    )
                )
            ),
        )

    def test_a_wrong_typed_value(self):
        self.assertIn(
            '"roles.solve.codex.model" must be a string',
            self.defects(
                self.edited(
                    ('[roles.solve.codex]\nmodel = "gpt-5.4"',
                     "[roles.solve.codex]\nmodel = 4")
                )
            ),
        )

    def test_an_empty_catalog_list(self):
        self.assertIn(
            '"providers.claude.efforts" must be a non-empty array of effort names',
            self.defects(
                self.edited(
                    (
                        'efforts = ["low", "medium", "high", "xhigh"]',
                        "efforts = []",
                    )
                )
            ),
        )

    def test_a_repeated_catalog_entry(self):
        self.assertIn(
            '"providers.codex.models" lists "gpt-5.4" more than once',
            self.defects(
                self.edited(
                    (
                        'models = ["gpt-5.4", "gpt-5.5"',
                        'models = ["gpt-5.4", "gpt-5.4", "gpt-5.5"',
                    )
                )
            ),
        )

    def test_a_repeated_agents_entry(self):
        self.assertIn(
            '"agents" lists "codex" more than once',
            self.defects(
                self.edited(
                    ('agents = ["codex", "claude"]', 'agents = ["codex", "codex", "claude"]')
                )
            ),
        )

    def test_an_unknown_provider_key(self):
        self.assertIn(
            '"providers.gemini" does not name a known provider',
            self.defects(self.edited(("[providers.claude]", "[providers.gemini]"))),
        )

    def test_an_unknown_provider_key_inside_a_role(self):
        self.assertIn(
            '"roles.solve.gemini" does not name a known provider',
            self.defects(self.edited(("[roles.solve.codex]", "[roles.solve.gemini]"))),
        )

    def test_an_unknown_role_key(self):
        self.assertIn(
            '"roles.pr_reveiw" does not name a known role',
            self.defects(self.edited(("[roles.pr_review.codex]", "[roles.pr_reveiw.codex]"))),
        )

    def test_an_agent_with_no_provider_declaration(self):
        self.assertIn(
            'agents entry "gemini" has no [providers.gemini] declaration',
            self.defects(
                self.edited(('agents = ["codex", "claude"]', 'agents = ["codex", "claude", "gemini"]'))
            ),
        )

    def test_an_assignment_for_an_undeclared_provider(self):
        # The provider table goes; the assignments stay, so the cells that name
        # it have no catalog to validate against.
        text = EXAMPLE.replace(
            '[providers.claude]\nmodels = ["claude-sonnet-5", "claude-opus-5", '
            '"claude-fable-5"]\nefforts = ["low", "medium", "high", "xhigh"]\n',
            "",
            1,
        )
        self.assertNotIn("[providers.claude]", text)
        message = self.defects(text)
        self.assertIn(
            "roles.solve.claude assigns a provider the file never declares", message
        )

    def test_an_assignment_for_a_provider_the_role_cannot_run_on(self):
        self.assertIn(
            "roles.issue_revise.codex assigns a provider this role cannot run on",
            self.defects(
                self.edited(
                    (
                        '[roles.issue_revise.claude]',
                        '[roles.issue_revise.codex]\nmodel = "gpt-5.4"\n'
                        'effort = "high"\ndisplay = "gpt-5.4 high"\n\n'
                        "[roles.issue_revise.claude]",
                    )
                )
            ),
        )

    def test_a_model_outside_its_providers_list(self):
        self.assertIn(
            'roles.solve.codex names model "gpt-9", which is not in that '
            "provider's models list",
            self.defects(
                self.edited(('[roles.solve.codex]\nmodel = "gpt-5.4"',
                             '[roles.solve.codex]\nmodel = "gpt-9"'))
            ),
        )

    def test_an_effort_outside_its_providers_vocabulary(self):
        self.assertIn(
            'roles.solve.codex names effort "extreme", which is not in that '
            "provider's efforts list",
            self.defects(
                self.edited(
                    (
                        '[roles.solve.codex]\nmodel = "gpt-5.4"\neffort = "high"',
                        '[roles.solve.codex]\nmodel = "gpt-5.4"\neffort = "extreme"',
                    )
                )
            ),
        )

    def test_a_missing_assignment_for_a_loaded_applicable_cell(self):
        text = EXAMPLE.replace(
            '[roles.issue_gate.codex]\nmodel = "gpt-5.6-sol"\neffort = "xhigh"\n'
            'display = "GPT-5.6-Sol xhigh"\n',
            "",
            1,
        )
        self.assertNotIn("[roles.issue_gate.codex]", text)
        self.assertIn(
            "roles.issue_gate.codex is required for a loaded provider this role "
            "applies to, and missing",
            self.defects(text),
        )

    def test_a_present_file_is_never_a_sparse_patch_over_the_defaults(self):
        # The whole class the case above is one instance of: a file carrying
        # only the cell the operator wanted to change is invalid, not a
        # one-cell override of the compiled roster.
        self.assertIn(
            "is required for a loaded provider",
            self.defects(
                "schema_version = 1\n"
                'agents = ["codex", "claude"]\n'
                "[providers.codex]\n"
                'models = ["gpt-5.4"]\n'
                'efforts = ["high"]\n'
                "[providers.claude]\n"
                'models = ["claude-opus-5"]\n'
                'efforts = ["xhigh"]\n'
                "[roles.issue_gate.codex]\n"
                'model = "gpt-5.4"\n'
                'effort = "high"\n'
                'display = "gpt-5.4 high"\n'
            ),
        )

    def test_a_wrong_shaped_top_level_table(self):
        for text, expected in (
            ("schema_version = 1\nagents = 3\n", '"agents" must be an array'),
            ("schema_version = 1\nproviders = 3\n", '"providers" must be a table'),
            ("schema_version = 1\nroles = 3\n", '"roles" must be a table'),
        ):
            with self.subTest(text=text):
                self.assertIn(expected, self.defects(text))

    def test_every_defect_is_reported_rather_than_only_the_first(self):
        message = self.defects(
            self.edited(
                ('[roles.solve.codex]\nmodel = "gpt-5.4"',
                 '[roles.solve.codex]\nmodel = "gpt-9"'),
                ('[roles.solve.claude]\nmodel = "claude-sonnet-5"',
                 '[roles.solve.claude]\nmodel = "claude-9"'),
            )
        )
        self.assertIn('names model "gpt-9"', message)
        self.assertIn('names model "claude-9"', message)


class AssignmentAvailabilityTests(unittest.TestCase):
    """A valid roster that does not cover the cell a caller asked for.

    Distinct from a defect on purpose: this is a refusal to report, not a file
    to fix. `assignment_for` is the only way out of the assignment map for
    exactly this reason -- a bare lookup at each call site would let one of
    them recover with the compiled default.
    """

    def claude_only(self) -> kanban_models.ModelRoster:
        text = EXAMPLE.replace('agents = ["codex", "claude"]', 'agents = ["claude"]', 1)
        return kanban_models.decode_roster(text, "/x/models.toml")

    def test_a_single_agent_roster_is_valid(self):
        self.assertEqual(self.claude_only().agents, ("claude",))

    def test_an_unloaded_provider_refuses_rather_than_defaulting(self):
        with self.assertRaises(kanban_models.AssignmentUnavailable) as caught:
            self.claude_only().assignment_for("issue_gate", "codex")
        self.assertIn('does not load provider "codex"', str(caught.exception))

    def test_a_role_that_cannot_run_on_a_provider_refuses(self):
        with self.assertRaises(kanban_models.AssignmentUnavailable) as caught:
            kanban_models.DEFAULT_ROSTER.assignment_for("issue_revise", "codex")
        self.assertIn('cannot run on provider "codex"', str(caught.exception))

    def test_an_unassigned_cell_of_an_in_process_roster_refuses(self):
        # A validated roster cannot reach this; a value built in process can,
        # and it must refuse rather than invent a default.
        roster = kanban_models.ModelRoster(
            agents=("codex", "claude"),
            providers=dict(kanban_models.DEFAULT_ROSTER.providers),
            assignments={},
        )
        with self.assertRaises(kanban_models.AssignmentUnavailable) as caught:
            roster.assignment_for("pr_review", "codex")
        self.assertIn('no "roles.pr_review.codex" assignment', str(caught.exception))

    def test_an_unknown_role_or_provider_refuses(self):
        for role, provider in (("nonsense", "codex"), ("pr_review", "gemini")):
            with self.subTest(role=role, provider=provider):
                with self.assertRaises(kanban_models.AssignmentUnavailable):
                    kanban_models.DEFAULT_ROSTER.assignment_for(role, provider)

    def test_every_refusal_shares_the_one_error_family(self):
        # Both classes descend from KanbanModelsError, which is what lets a
        # consumer refuse on any roster failure with one handler.
        for error in (kanban_models.RosterError, kanban_models.AssignmentUnavailable):
            with self.subTest(error=error.__name__):
                self.assertTrue(issubclass(error, kanban_models.KanbanModelsError))


class ExampleAgreementTests(unittest.TestCase):
    """The example is a real roster, not just something that parses."""

    def test_every_assignment_names_a_declared_model_and_effort(self):
        document = tomllib.loads(EXAMPLE)
        for role, providers in document["roles"].items():
            for provider, cell in providers.items():
                with self.subTest(role=role, provider=provider):
                    catalog = document["providers"][provider]
                    self.assertIn(cell["model"], catalog["models"])
                    self.assertIn(cell["effort"], catalog["efforts"])

    def test_the_reader_carries_its_managed_asset_marker(self):
        # The issue-review installer links this module beside approve_issues.py
        # and both it and Kanban.Preflight recognize an installed file by this
        # marker rather than by path.
        self.assertEqual(
            kanban_models.KANBAN_MANAGED_ASSET,
            "kanban-managed-asset:issue-review/kanban_models.py",
        )
        self.assertIn(
            kanban_models.KANBAN_MANAGED_ASSET,
            (REPO_ROOT / "tools" / "kanban_models.py").read_text(encoding="utf-8"),
        )


if __name__ == "__main__":
    unittest.main()
