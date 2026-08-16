"""Unit tests for tools/kanban_config.py.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
"""

import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import kanban_config as kc


def write(tmp: Path, text: str) -> Path:
    path = tmp / "config.toml"
    path.write_text(text, encoding="utf-8")
    return path


class MissingFileTests(unittest.TestCase):
    def test_missing_file_yields_documented_defaults(self):
        with tempfile.TemporaryDirectory() as tmp:
            raw, warnings = kc.load_raw_config(str(Path(tmp) / "does-not-exist.toml"))
        self.assertEqual(warnings, [])
        self.assertEqual(raw, kc.RawConfig())
        self.assertTrue(raw.cache)
        self.assertEqual(raw.remote_name, "origin")
        self.assertEqual(raw.workflow.approval_label, "reviewed:approve")
        self.assertEqual(raw.workflow.changes_requested_label, "reviewed:changes")
        self.assertEqual(raw.workflow.blocked_labels, frozenset({"blocked"}))
        self.assertEqual(raw.workflow.tracker_labels, frozenset({"epic"}))
        self.assertEqual(raw.workflow.additional_tracker_section_headings, ())
        self.assertEqual(raw.workflow.approval_mode, "label")
        self.assertEqual(raw.workflow.blocking_severity, "red")
        self.assertEqual(raw.workflow.problem_style_labels, frozenset())
        self.assertEqual(raw.workflow.ui_style_labels, frozenset())
        self.assertEqual(raw.workflow.coordination_paths, frozenset())
        self.assertEqual(raw.limits.excerpt_lines, 3)
        self.assertEqual(raw.timeouts.github_seconds, 30)
        self.assertEqual(raw.timeouts.codex_seconds, 10)
        self.assertEqual(raw.timeouts.claude_seconds, 45)
        self.assertEqual(raw.timeouts.ping_codex_seconds, 120)
        self.assertEqual(raw.timeouts.ping_claude_seconds, 120)
        self.assertIsNone(raw.usage.codex_command)
        self.assertIsNone(raw.usage.claude_command)
        self.assertIsNone(raw.usage.codex_estimated_percent_per_solve_round)
        self.assertIsNone(raw.usage.claude_estimated_percent_per_solve_round)
        self.assertEqual(raw.repositories, {})

    def test_default_config_path_is_under_home_config_kanban(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("XDG_CONFIG_HOME", None)
            self.assertEqual(
                kc.default_config_path(), Path.home() / ".config" / "kanban" / "config.toml"
            )

    def test_default_config_path_honors_xdg_config_home_like_the_haskell_side(self):
        with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": "/tmp/custom-xdg"}):
            self.assertEqual(
                kc.default_config_path(), Path("/tmp/custom-xdg") / "kanban" / "config.toml"
            )


FULL_FIXTURE = """
cache = false
remote_name = "upstream"

[workflow]
approval_label = "verdict:go"
changes_requested_label = "verdict:no"
blocked_labels = ["blocked", "on-hold"]
tracker_labels = ["epic", "tracker"]
additional_tracker_section_headings = ["Extra Heading"]
approval_mode = "either"
blocking_severity = "amber"
problem_style_labels = ["defect"]
ui_style_labels = ["interface", "input"]
coordination_paths = ["docs/status.md", "ROADMAP.md"]

[limits]
excerpt_lines = 7

[timeouts]
github_seconds = 11
codex_seconds = 22
claude_seconds = 33
ping_codex_seconds = 44
ping_claude_seconds = 55

[usage.codex]
command = ["/usr/local/bin/my-codex-usage", "--json"]
estimated_percent_per_solve_round = 8

[usage.claude]
command = ["/usr/local/bin/my-claude-usage"]
estimated_percent_per_solve_round = 12

[repositories."acme/widgets".workflow]
approval_label = "acme:go"
blocked_labels = ["only-this"]
ui_style_labels = ["widget-ui"]
coordination_paths = ["docs/widgets.md"]

[repositories."acme/widgets".limits]
excerpt_lines = 9

[repositories."acme/widgets".timeouts]
claude_seconds = 999
ping_claude_seconds = 888
"""


class FullFixtureTests(unittest.TestCase):
    def test_every_key_decodes_correctly(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write(Path(tmp), FULL_FIXTURE)
            raw, warnings = kc.load_raw_config(str(path))
        self.assertEqual(warnings, [])
        self.assertFalse(raw.cache)
        self.assertEqual(raw.remote_name, "upstream")
        self.assertEqual(raw.workflow.approval_label, "verdict:go")
        self.assertEqual(raw.workflow.changes_requested_label, "verdict:no")
        self.assertEqual(raw.workflow.blocked_labels, frozenset({"blocked", "on-hold"}))
        self.assertEqual(raw.workflow.tracker_labels, frozenset({"epic", "tracker"}))
        self.assertEqual(
            raw.workflow.additional_tracker_section_headings, ("Extra Heading",)
        )
        self.assertEqual(raw.workflow.approval_mode, "either")
        self.assertEqual(raw.workflow.blocking_severity, "amber")
        # Display-only on the Haskell side; carried here so the shared schema
        # accepts a documented key instead of warning it as unknown.
        self.assertEqual(raw.workflow.problem_style_labels, frozenset({"defect"}))
        self.assertEqual(
            raw.workflow.ui_style_labels, frozenset({"interface", "input"})
        )
        # Read by drain_prs.py alone, and carried on the Haskell side only so
        # the shared schema stays one schema.
        self.assertEqual(
            raw.workflow.coordination_paths,
            frozenset({"docs/status.md", "ROADMAP.md"}),
        )
        self.assertEqual(raw.limits.excerpt_lines, 7)
        self.assertEqual(raw.timeouts.github_seconds, 11)
        self.assertEqual(raw.timeouts.codex_seconds, 22)
        self.assertEqual(raw.timeouts.claude_seconds, 33)
        # Documented ping bounds decode like every other timeout instead of
        # warning as unknown keys.
        self.assertEqual(raw.timeouts.ping_codex_seconds, 44)
        self.assertEqual(raw.timeouts.ping_claude_seconds, 55)
        self.assertEqual(
            raw.usage.codex_command.argv, ("/usr/local/bin/my-codex-usage", "--json")
        )
        self.assertEqual(raw.usage.claude_command.argv, ("/usr/local/bin/my-claude-usage",))
        # Both providers carry the estimate rather than warning about it as an
        # unknown key, even though nothing in Python renders the value.
        self.assertEqual(raw.usage.codex_estimated_percent_per_solve_round, 8)
        self.assertEqual(raw.usage.claude_estimated_percent_per_solve_round, 12)
        self.assertIn("acme/widgets", raw.repositories)


class MergeAndSelectionTests(unittest.TestCase):
    def _raw(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write(Path(tmp), FULL_FIXTURE)
            raw, _ = kc.load_raw_config(str(path))
        return raw

    def test_repository_array_replaces_rather_than_extends_global_array(self):
        raw = self._raw()
        resolved = kc.resolve_config("acme/widgets", raw)
        self.assertEqual(resolved.workflow.blocked_labels, frozenset({"only-this"}))
        self.assertNotIn("blocked", resolved.workflow.blocked_labels)
        self.assertNotIn("on-hold", resolved.workflow.blocked_labels)

    def test_repository_override_merges_with_global_for_omitted_fields(self):
        raw = self._raw()
        resolved = kc.resolve_config("acme/widgets", raw)
        self.assertEqual(resolved.workflow.approval_label, "acme:go")
        # changes_requested_label was not overridden for this repository.
        self.assertEqual(resolved.workflow.changes_requested_label, "verdict:no")
        self.assertEqual(resolved.limits.excerpt_lines, 9)
        self.assertEqual(resolved.timeouts.claude_seconds, 999)
        self.assertEqual(resolved.timeouts.github_seconds, 11)
        # The ping bounds inherit and override on exactly the same terms as
        # the account-status timeouts beside them.
        self.assertEqual(resolved.timeouts.ping_claude_seconds, 888)
        self.assertEqual(resolved.timeouts.ping_codex_seconds, 44)
        # The overridden styling array replaces the global one; the omitted
        # one inherits it, exactly like every other workflow collection.
        self.assertEqual(resolved.workflow.ui_style_labels, frozenset({"widget-ui"}))
        self.assertEqual(resolved.workflow.problem_style_labels, frozenset({"defect"}))

    def test_coordination_paths_inherit_globally_and_are_replaced_per_repository(self):
        raw = self._raw()
        # A repository the fixture does not name inherits the global array
        # whole; the one that names its own replaces it rather than extending
        # it, exactly like every other workflow collection.
        self.assertEqual(
            kc.resolve_config("other/repo", raw).workflow.coordination_paths,
            frozenset({"docs/status.md", "ROADMAP.md"}),
        )
        self.assertEqual(
            kc.resolve_config("acme/widgets", raw).workflow.coordination_paths,
            frozenset({"docs/widgets.md"}),
        )

    def test_selection_normalizes_the_resolved_identity_to_lowercase(self):
        raw = self._raw()
        # A remote such as git@github.com:Acme/Widgets.git resolves with the
        # clone's casing; the override key stays canonical lowercase.
        for identity in ("Acme/Widgets", "ACME/WIDGETS", "aCmE/wIdGeTs"):
            with self.subTest(identity=identity):
                resolved = kc.resolve_config(identity, raw)
                self.assertEqual(resolved.workflow.approval_label, "acme:go")
                # Merge and precedence survive the normalized lookup.
                self.assertEqual(resolved.workflow.changes_requested_label, "verdict:no")
                self.assertEqual(resolved.limits.excerpt_lines, 9)
                self.assertEqual(resolved.timeouts.claude_seconds, 999)
                self.assertEqual(resolved.timeouts.github_seconds, 11)

    def test_selection_folds_case_the_ascii_only_way_the_dashboard_does(self):
        # A Unicode fold (str.lower() here, Data.Text.toLower there) maps the
        # KELVIN SIGN onto "k" and would match; the two languages' full
        # Unicode tables need not agree, so both sides fold ASCII only. A
        # non-ASCII identity then matches no canonical key, and does not raise.
        self.assertEqual("\u212a".lower(), "k")
        with tempfile.TemporaryDirectory() as tmp:
            path = write(
                Path(tmp),
                '[workflow]\napproval_label = "global"\n'
                '[repositories."acme/kanban".workflow]\napproval_label = "override"\n',
            )
            raw, _ = kc.load_raw_config(str(path))
        self.assertEqual(kc.resolve_config("acme/Kanban", raw).workflow.approval_label, "override")
        self.assertEqual(
            kc.resolve_config("acme/\u212aanban", raw).workflow.approval_label, "global"
        )

    def test_script_consumers_read_the_dashboard_labels_for_a_mixed_case_slug(self):
        # approve_issues.py and drain_prs.py both take exactly this pair from
        # exactly this call, passing the repo slug they resolved from the
        # remote. A mixed-case clone must not send them to the global labels
        # while the dashboard uses the override's.
        raw = self._raw()
        dashboard = kc.resolve_config("acme/widgets", raw).workflow
        for slug in ("acme/widgets", "Acme/Widgets", "ACME/WIDGETS"):
            with self.subTest(slug=slug):
                consumer = kc.resolve_config(slug, raw).workflow
                self.assertEqual(
                    (consumer.approval_label, consumer.changes_requested_label),
                    (dashboard.approval_label, dashboard.changes_requested_label),
                )
                self.assertEqual(consumer.approval_label, "acme:go")

    def test_unrelated_repository_table_has_zero_effect(self):
        raw = self._raw()
        resolved = kc.resolve_config("someone/else", raw)
        self.assertEqual(resolved.workflow.approval_label, "verdict:go")
        self.assertEqual(resolved.workflow.blocked_labels, frozenset({"blocked", "on-hold"}))
        self.assertEqual(resolved.limits.excerpt_lines, 7)
        self.assertEqual(resolved.timeouts.claude_seconds, 33)

    def test_resolved_config_carries_global_only_fields_unchanged(self):
        raw = self._raw()
        resolved = kc.resolve_config("acme/widgets", raw)
        self.assertFalse(resolved.cache)
        self.assertEqual(resolved.remote_name, "upstream")
        self.assertEqual(
            resolved.usage.codex_command.argv,
            ("/usr/local/bin/my-codex-usage", "--json"),
        )


class MalformedTomlTests(unittest.TestCase):
    def test_malformed_toml_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write(Path(tmp), "not valid toml [[[")
            with self.assertRaises(kc.KanbanConfigError):
                kc.load_raw_config(str(path))


class SemanticValidationErrorTests(unittest.TestCase):
    def _expect_error(self, text: str, expected_fragment: str):
        with tempfile.TemporaryDirectory() as tmp:
            path = write(Path(tmp), text)
            with self.assertRaises(kc.KanbanConfigError) as ctx:
                kc.load_raw_config(str(path))
        self.assertIn(expected_fragment, str(ctx.exception))
        self.assertIn(str(path), str(ctx.exception))

    def test_empty_approval_label_raises(self):
        self._expect_error(
            '[workflow]\napproval_label = ""\n', "workflow.approval_label"
        )

    def test_empty_remote_name_raises(self):
        self._expect_error('remote_name = ""\n', "remote_name")

    def test_bad_approval_mode_raises(self):
        self._expect_error(
            '[workflow]\napproval_mode = "sometimes"\n', "workflow.approval_mode"
        )

    def test_invalid_coordination_paths_raise(self):
        for text in (
            '[workflow]\ncoordination_paths = [""]\n',
            '[workflow]\ncoordination_paths = "docs/status.md"\n',
            "[workflow]\ncoordination_paths = [1]\n",
        ):
            with self.subTest(text=text):
                self._expect_error(text, "workflow.coordination_paths")

    def test_bad_blocking_severity_raises(self):
        self._expect_error(
            '[workflow]\nblocking_severity = "blue"\n', "workflow.blocking_severity"
        )

    def test_non_positive_excerpt_lines_raises(self):
        self._expect_error("[limits]\nexcerpt_lines = -1\n", "limits.excerpt_lines")

    def test_non_positive_timeout_raises(self):
        self._expect_error(
            "[timeouts]\ngithub_seconds = 0\n", "timeouts.github_seconds"
        )

    def test_ping_timeouts_get_the_same_validation_as_every_other_timeout(self):
        overflowing = kc._MAX_TIMEOUT_SECONDS + 1
        for key in ("ping_codex_seconds", "ping_claude_seconds"):
            for value in (0, -1, overflowing):
                with self.subTest(key=key, value=value):
                    self._expect_error(
                        f"[timeouts]\n{key} = {value}\n", f"timeouts.{key}"
                    )

    def test_timeout_overflowing_microsecond_conversion_raises_but_the_boundary_is_accepted(self):
        overflowing = kc._MAX_TIMEOUT_SECONDS + 1
        self._expect_error(
            f"[timeouts]\ngithub_seconds = {overflowing}\n", "timeouts.github_seconds"
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = write(Path(tmp), f"[timeouts]\ngithub_seconds = {kc._MAX_TIMEOUT_SECONDS}\n")
            raw, warnings = kc.load_raw_config(str(path))
        self.assertEqual(warnings, [])
        self.assertEqual(raw.timeouts.github_seconds, kc._MAX_TIMEOUT_SECONDS)

    def test_empty_command_array_raises(self):
        self._expect_error(
            "[usage.codex]\ncommand = []\n", "usage.codex.command"
        )

    def test_empty_command_executable_raises(self):
        self._expect_error(
            '[usage.codex]\ncommand = [""]\n', "usage.codex.command"
        )

    def test_out_of_range_solve_round_estimate_raises_for_either_provider(self):
        # The estimate divides the remaining percentage, so zero has to be an
        # error; the upper bound is what makes it a percentage of a window.
        # The message names the whole path because the two providers configure
        # the key independently.
        for provider in ("codex", "claude"):
            for value in ("0", "-1", "101"):
                with self.subTest(provider=provider, value=value):
                    self._expect_error(
                        f"[usage.{provider}]\nestimated_percent_per_solve_round = {value}\n",
                        f"usage.{provider}.estimated_percent_per_solve_round",
                    )

    def test_non_integer_solve_round_estimate_raises_for_either_provider(self):
        # `true` is the case the two schemas would otherwise disagree on: bool
        # is a subclass of int in Python, so an isinstance check alone would
        # read it as 1 while the Haskell integer matcher rejects it outright.
        for provider in ("codex", "claude"):
            for value in ("7.5", "true", '"8"'):
                with self.subTest(provider=provider, value=value):
                    self._expect_error(
                        f"[usage.{provider}]\nestimated_percent_per_solve_round = {value}\n",
                        f"usage.{provider}.estimated_percent_per_solve_round",
                    )

    def test_boundary_solve_round_estimates_are_accepted_without_warnings(self):
        for provider, value in (("codex", 1), ("claude", 100)):
            with self.subTest(provider=provider, value=value):
                with tempfile.TemporaryDirectory() as tmp:
                    path = write(
                        Path(tmp),
                        f"[usage.{provider}]\nestimated_percent_per_solve_round = {value}\n",
                    )
                    raw, warnings = kc.load_raw_config(str(path))
                self.assertEqual(warnings, [])
                self.assertEqual(
                    getattr(raw.usage, f"{provider}_estimated_percent_per_solve_round"), value
                )
                # The estimate is a sibling of `command`, not nested inside it:
                # a table carrying only the estimate is valid configuration.
                self.assertIsNone(getattr(raw.usage, f"{provider}_command"))

    def test_limit_exceeding_the_bounded_int_raises_but_the_boundary_is_accepted(self):
        overflowing = kc._MAX_INT64 + 1
        self._expect_error(
            f"[limits]\nexcerpt_lines = {overflowing}\n", "limits.excerpt_lines"
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = write(Path(tmp), f"[limits]\nexcerpt_lines = {kc._MAX_INT64}\n")
            raw, warnings = kc.load_raw_config(str(path))
        self.assertEqual(warnings, [])
        self.assertEqual(raw.limits.excerpt_lines, kc._MAX_INT64)

    def test_global_approval_and_changes_requested_labels_colliding_raises(self):
        self._expect_error(
            '[workflow]\napproval_label = "lgtm"\nchanges_requested_label = "LGTM"\n',
            "workflow.approval_label",
        )

    def test_label_colliding_with_the_reserved_reviewed_revised_label_raises(self):
        self._expect_error(
            '[workflow]\napproval_label = "reviewed:revised"\n', "reviewed:revised"
        )
        self._expect_error(
            '[workflow]\nchanges_requested_label = "Reviewed:Revised"\n', "reviewed:revised"
        )

    def test_repository_override_that_collides_only_once_merged_with_global_raises(self):
        self._expect_error(
            "\n".join(
                [
                    '[workflow]',
                    'approval_label = "lgtm"',
                    'changes_requested_label = "needs-work"',
                    '[repositories."acme/widgets".workflow]',
                    'changes_requested_label = "lgtm"',
                ]
            ),
            'repositories."acme/widgets".workflow',
        )


class RepositoryGlobalOnlyKeyTests(unittest.TestCase):
    def _expect_error(self, text: str, expected_fragment: str):
        with tempfile.TemporaryDirectory() as tmp:
            path = write(Path(tmp), text)
            with self.assertRaises(kc.KanbanConfigError) as ctx:
                kc.load_raw_config(str(path))
        self.assertIn(expected_fragment, str(ctx.exception))

    def test_cache_inside_repository_table_raises(self):
        self._expect_error(
            '[repositories."acme/widgets"]\ncache = true\n',
            'repositories."acme/widgets".cache',
        )

    def test_remote_name_inside_repository_table_raises(self):
        self._expect_error(
            '[repositories."acme/widgets"]\nremote_name = "fork"\n',
            'repositories."acme/widgets".remote_name',
        )

    def test_usage_inside_repository_table_raises(self):
        self._expect_error(
            '[repositories."acme/widgets".usage]\n',
            'repositories."acme/widgets".usage',
        )


class RepositoryKeyGrammarTests(unittest.TestCase):
    """Mirrors Spec.Config.Loading's canonical repository-key cases."""

    def _expect_rejected(self, key: str):
        with tempfile.TemporaryDirectory() as tmp:
            path = write(
                Path(tmp), f'[repositories."{key}".workflow]\napproval_label = "x"\n'
            )
            with self.assertRaises(kc.KanbanConfigError) as ctx:
                kc.load_raw_config(str(path))
        # The error names the full offending key path, not just its parent.
        self.assertIn(f'repositories."{key}"', str(ctx.exception))

    def test_noncanonical_keys_are_rejected_naming_the_key(self):
        for key in (
            "Coghex/Kanban",
            "kanban",
            "/kanban",
            "coghex/",
            "coghex//kanban",
            "coghex/kanban/extra",
            "coghex/kanban.git",
            "https://github.com/coghex/kanban",
            "git@github.com:coghex/kanban.git",
            " coghex/kanban",
            "coghex/kanban ",
            "coghex/kan ban",
            "coghex/kanban!",
        ):
            with self.subTest(key=key):
                self._expect_rejected(key)

    def test_every_character_the_grammar_allows_is_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write(
                Path(tmp),
                '[repositories."a-c.o_1/k-n.b_2".workflow]\napproval_label = "x"\n',
            )
            raw, warnings = kc.load_raw_config(str(path))
        self.assertEqual(warnings, [])
        self.assertIn("a-c.o_1/k-n.b_2", raw.repositories)


class UnknownKeyWarningTests(unittest.TestCase):
    def test_unknown_top_level_key_warns_and_does_not_raise(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write(Path(tmp), "made_up_key = 1\n")
            raw, warnings = kc.load_raw_config(str(path))
        self.assertEqual(raw, kc.RawConfig())
        self.assertEqual(len(warnings), 1)
        self.assertIn("made_up_key", warnings[0])

    def test_unknown_nested_key_warns_with_full_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write(Path(tmp), '[workflow]\nnot_a_real_field = "x"\n')
            raw, warnings = kc.load_raw_config(str(path))
        self.assertEqual(raw.workflow.approval_label, "reviewed:approve")
        self.assertEqual(len(warnings), 1)
        self.assertIn("workflow.not_a_real_field", warnings[0])

    def test_unknown_key_inside_repository_table_warns_with_full_path(self):
        text = '[repositories."acme/widgets".workflow]\nnot_real = "x"\n'
        with tempfile.TemporaryDirectory() as tmp:
            path = write(Path(tmp), text)
            raw, warnings = kc.load_raw_config(str(path))
        self.assertIn("acme/widgets", raw.repositories)
        self.assertEqual(len(warnings), 1)
        self.assertIn('repositories."acme/widgets".workflow.not_real', warnings[0])

    def test_retired_open_connection_caps_warn_like_any_other_unknown_key(self):
        # A refresh follows both open connections to their final page, so
        # max_open_issues and max_open_pull_requests are gone from the schema
        # rather than merely ignored. A file that still sets them is a file
        # with unknown keys in it -- one warning apiece, at either scope, and
        # nothing about the resolved configuration changes.
        text = (
            "[limits]\n"
            "max_open_issues = 500\n"
            "max_open_pull_requests = 200\n"
            '[repositories."acme/widgets".limits]\n'
            "max_open_issues = 999\n"
            "max_open_pull_requests = 400\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = write(Path(tmp), text)
            raw, warnings = kc.load_raw_config(str(path))
        self.assertEqual(len(warnings), 4)
        reported = "\n".join(warnings)
        for key in ("limits.max_open_issues", "limits.max_open_pull_requests"):
            self.assertIn(key, reported)
            self.assertIn(f'repositories."acme/widgets".{key}', reported)
        self.assertEqual(raw.limits, kc.LimitsConfig())
        self.assertEqual(
            kc.resolve_config("acme/widgets", raw).limits, kc.LimitsConfig()
        )


class RepositoryNameParsingTests(unittest.TestCase):
    """parse_repository_name is the permissive display-slug parser
    approve_issues.py and drain_prs.py's own parse_repo_slug delegate to. It
    keeps the last two segments of anything, which is what lets a fixture
    repository with a plain local-path remote address itself; see
    GithubRepositoryParsingTests for the canonical-identity parser."""

    def test_accepts_ssh_shorthand(self):
        self.assertEqual(kc.parse_repository_name("git@github.com:coghex/kanban.git"), "coghex/kanban")

    def test_accepts_https(self):
        self.assertEqual(kc.parse_repository_name("https://github.com/coghex/kanban.git"), "coghex/kanban")
        self.assertEqual(kc.parse_repository_name("https://github.com/coghex/kanban"), "coghex/kanban")

    def test_accepts_http_ssh_scheme_and_git_scheme(self):
        self.assertEqual(kc.parse_repository_name("http://github.com/coghex/kanban"), "coghex/kanban")
        self.assertEqual(kc.parse_repository_name("ssh://git@github.com/coghex/kanban.git"), "coghex/kanban")
        self.assertEqual(kc.parse_repository_name("git://github.com/coghex/kanban.git"), "coghex/kanban")

    def test_accepts_a_bare_owner_name(self):
        self.assertEqual(kc.parse_repository_name("coghex/kanban"), "coghex/kanban")

    def test_raises_on_an_unparseable_value(self):
        with self.assertRaises(kc.KanbanConfigError):
            kc.parse_repository_name("not-a-repo")

    def test_keeps_the_last_two_segments_of_a_local_path(self):
        # Relied on by tools/test_single_pr_drain.py, whose bare remote lives
        # at <tmp>/acme/widgets.git precisely so the drainer resolves its own
        # repository context without a GitHub URL.
        self.assertEqual(
            kc.parse_repository_name("/tmp/xyz/acme/widgets.git"), "acme/widgets"
        )


class GithubRepositoryParsingTests(unittest.TestCase):
    """parse_github_repository names a repository *on github.com*, and mirrors
    Kanban.Repository.parseRepositoryName's accept set exactly. The drainer's
    per-repository job identity is derived from it, and Kanban selects that
    job's record by the identity its own parser resolved, so a value one side
    accepts and the other rejects would present as a drainer that is installed
    and simultaneously not installed."""

    def test_accepts_the_bare_owner_name_form(self):
        self.assertEqual(kc.parse_github_repository("coghex/kanban"), "coghex/kanban")
        self.assertEqual(
            kc.parse_github_repository("  coghex/kanban.git  "), "coghex/kanban"
        )
        self.assertEqual(kc.parse_github_repository("/coghex/kanban/"), "coghex/kanban")

    def test_accepts_the_url_and_scp_forms_github_actually_serves(self):
        for value in (
            "https://github.com/coghex/kanban",
            "https://github.com/coghex/kanban.git",
            "HTTPS://GitHub.com/coghex/kanban",
            "https://www.github.com/coghex/kanban",
            "https://user@github.com/coghex/kanban",
            "https://github.com:443/coghex/kanban",
            "ssh://git@github.com/coghex/kanban.git",
            "git://github.com/coghex/kanban.git",
            "git@github.com:coghex/kanban.git",
        ):
            with self.subTest(value=value):
                self.assertEqual(kc.parse_github_repository(value), "coghex/kanban")

    def test_accepts_the_full_identity_charset(self):
        for name in ("kan.ban", "kan-ban", "kan_ban", "k", "0"):
            with self.subTest(name=name):
                self.assertEqual(
                    kc.parse_github_repository(f"cog-hex.1_x/{name}"),
                    f"cog-hex.1_x/{name}",
                )

    def test_rejects_a_foreign_host(self):
        for value in (
            "git@gitlab.com:coghex/kanban.git",
            "https://gitlab.com/coghex/kanban.git",
            "ssh://git@git.example.test/coghex/kanban.git",
            "https://github.com.example.test/coghex/kanban",
            "git@evil-github.com:coghex/kanban.git",
        ):
            with self.subTest(value=value):
                with self.assertRaises(kc.KanbanConfigError):
                    kc.parse_github_repository(value)

    def test_rejects_the_http_scheme_github_does_not_serve_clone_urls_over(self):
        with self.assertRaises(kc.KanbanConfigError):
            kc.parse_github_repository("http://github.com/coghex/kanban")

    def test_rejects_ambiguous_extra_path_segments(self):
        for value in (
            "https://github.com/coghex/kanban/tree/master",
            "https://github.com/coghex/kanban/pull/147",
            "git@github.com:22/coghex/kanban",
            "coghex/kanban/extra",
        ):
            with self.subTest(value=value):
                with self.assertRaises(kc.KanbanConfigError):
                    kc.parse_github_repository(value)

    def test_rejects_everything_else_rather_than_deriving_a_label_from_it(self):
        for value in (
            "/tmp/acme/widgets.git",
            "file:///tmp/acme/widgets.git",
            "../acme/widgets",
            "not-a-repo",
            "coghex",
            "coghex/",
            "/",
            "",
            "coghex/kan ban",
            "coghex/kan~ban",
            "coghex/kan/ban",
            "https://github.com/coghex",
            "https://github.com",
            "https://github.com:notaport/coghex/kanban",
            "github.com:coghex/kanban",
        ):
            with self.subTest(value=value):
                with self.assertRaises(kc.KanbanConfigError):
                    kc.parse_github_repository(value)

    def test_normalization_folds_case_only_spellings_together(self):
        # GitHub owner and repository names are case-insensitive, so two
        # spellings that differ only in case name one repository — and
        # therefore one drainer.
        for value in (
            "CogHex/Kanban",
            "coghex/kanban",
            "COGHEX/KANBAN",
            "git@GitHub.com:CogHex/Kanban.git",
        ):
            with self.subTest(value=value):
                self.assertEqual(
                    kc.normalize_github_repository(value), "coghex/kanban"
                )
        # And the unnormalized parser keeps the spelling it was given, so the
        # folding is a decision this module makes rather than a side effect.
        self.assertEqual(kc.parse_github_repository("CogHex/Kanban"), "CogHex/Kanban")


if __name__ == "__main__":
    unittest.main()
