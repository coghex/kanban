"""The Copilot bundles refuse a session whose model is not their brand.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 tools/test_copilot_session_brand.py

Issue #723. `docs/coordination/external_workflow_authoring_design.md` D-0
recorded that nothing enforced "a Kimi bundle runs in a Kimi session" at
runtime: it held only because the operator chose the bundle, and a Copilot
session running Claude that loaded the Kimi bundle stamped a kimi origin on a
pull request it had no business marking. The Kimi and Google `solve` and
`autosolve` skills now read the session's model from the record the Copilot
CLI keeps -- `session-store.db`, opened read-only, for
`$COPILOT_AGENT_SESSION_ID` -- before the claim, and refuse on a mismatch and
on every signal they cannot read.

String search alone cannot prove the check refuses what it must, so the
fenced program is lifted out of each rendered asset and run against fixture
databases. The rest of the module holds where it lives: in all four Copilot
workflow assets, authored once per source, ahead of the claim, ending the
autosolve run on refusal -- and in no Grok, Claude, or Codex asset, which keep
no Copilot database requirement.
"""

from __future__ import annotations

import os
import re
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

SOLVE_SOURCE = "tools/command_sources/external/solve.md"
AUTOSOLVE_SOURCE = "tools/command_sources/external/autosolve.md"
COPILOT_BRANDS = ("kimi", "google")
COPILOT_ASSETS = {
    (brand, workflow): f"{brand}-plugin/plugins/kanban/skills/{workflow}/SKILL.md"
    for brand in COPILOT_BRANDS
    for workflow in ("solve", "autosolve")
}
# The negative controls: none of these runs inside a Copilot session, so none
# may depend on the Copilot session record.
EXCLUDED_ASSETS = (
    "grok-plugin/plugins/kanban/skills/solve/SKILL.md",
    "grok-plugin/plugins/kanban/skills/autosolve/SKILL.md",
    "claude-plugin/plugins/kanban/commands/solve.md",
    "claude-plugin/plugins/kanban/commands/autosolve.md",
    "codex-plugin/plugins/kanban/skills/solve/SKILL.md",
    "codex-plugin/plugins/kanban/skills/autosolve/SKILL.md",
)

GUARD_TOKEN = "assistant_usage_events"
SESSION_TOKEN = "COPILOT_AGENT_SESSION_ID"
REFUSAL_PREFIX = "Session brand refused:"
CLAIM_COMMAND = 'gh issue edit -R "$REPO" <issue> --add-assignee @me'

BASH_FENCE_RE = re.compile(r"```bash\n(?P<body>.*?)\n[ \t]*```", re.DOTALL)
BRAND_BLOCK_RE = re.compile(
    r"<!-- brand:(?P<brands>[a-z,]+) -->\n(?P<body>.*?)(?=<!-- /?brand)", re.DOTALL
)


def read(path):
    return (REPO_ROOT / path).read_text(encoding="utf-8")


def guard_fences(text):
    return [
        match.group("body")
        for match in BASH_FENCE_RE.finditer(text)
        if GUARD_TOKEN in match.group("body")
    ]


def carries_guard(text):
    """The rule the coverage assertions apply, as a function so the planted
    control drives exactly what the assets are held to."""
    return GUARD_TOKEN in text or SESSION_TOKEN in text


def the_guard(path):
    fences = guard_fences(read(path))
    assert len(fences) == 1, f"{path} carries {len(fences)} session model checks"
    return fences[0]


def make_database(path, rows, schema=None):
    connection = sqlite3.connect(path)
    try:
        connection.execute(
            schema
            or "CREATE TABLE assistant_usage_events ("
            "id INTEGER PRIMARY KEY, session_id TEXT, agent_id TEXT, model TEXT)"
        )
        if rows:
            connection.executemany(
                "INSERT INTO assistant_usage_events (session_id, agent_id, model)"
                " VALUES (?, ?, ?)",
                rows,
            )
        connection.commit()
    finally:
        connection.close()


class GuardBehaviorTests(unittest.TestCase):
    """The fenced check, run exactly as each asset spells it, through bash, so
    the `${COPILOT_AGENT_SESSION_ID:-}` and `${COPILOT_HOME:-...}` expansions
    are exercised along with the Python."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.copilot_home = self.root / "copilot"
        self.copilot_home.mkdir()
        self.database = self.copilot_home / "session-store.db"

    def run_guard(self, brand, session="session-1", copilot_home=None, workflow="solve"):
        environment = {
            key: value
            for key, value in os.environ.items()
            if key not in (SESSION_TOKEN, "COPILOT_HOME")
        }
        environment["HOME"] = str(self.root / "home")
        if session is not None:
            environment[SESSION_TOKEN] = session
        if copilot_home is not False:
            environment["COPILOT_HOME"] = str(copilot_home or self.copilot_home)
        return subprocess.run(
            ["bash", "-c", the_guard(COPILOT_ASSETS[(brand, workflow)])],
            capture_output=True,
            text=True,
            env=environment,
            cwd=str(self.root),
            timeout=60,
        )

    def assert_refused(self, proc, *phrases):
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertEqual(proc.stdout, "")
        lines = proc.stderr.splitlines()
        self.assertEqual(len(lines), 1, proc.stderr)
        self.assertTrue(lines[0].startswith(REFUSAL_PREFIX), lines[0])
        for phrase in phrases:
            self.assertIn(phrase, lines[0])
        return lines[0]

    def assert_proceeds(self, proc, model, brand):
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            proc.stdout.strip(),
            f"Session model {model!r} is a {brand} model; this is the {brand} bundle.",
        )

    def test_a_matching_model_proceeds_in_each_copilot_bundle(self):
        for brand, model in (("kimi", "kimi-k3"), ("google", "gemini-3-pro")):
            for workflow in ("solve", "autosolve"):
                with self.subTest(brand=brand, workflow=workflow):
                    self.database.unlink(missing_ok=True)
                    make_database(self.database, [("session-1", None, model)])
                    self.assert_proceeds(
                        self.run_guard(brand, workflow=workflow), model, brand
                    )

    def test_a_claude_session_loading_the_kimi_bundle_refuses_naming_claude(self):
        make_database(self.database, [("session-1", None, "claude-opus-5")])
        line = self.assert_refused(
            self.run_guard("kimi"),
            "'claude-opus-5'",
            "a claude model",
            "this is the kimi bundle",
            "load the kanban-claude bundle instead",
        )
        self.assertIn("Nothing was claimed.", line)

    def test_every_declared_pattern_maps_to_its_brand(self):
        # Requirement 4, as the issue review anchored it: four prefixes and one
        # suffix. Each is run against both bundles, so each pattern is seen
        # both proceeding and refusing.
        cases = (
            ("claude-sonnet-5", "claude"),
            ("kimi-k3", "kimi"),
            ("gemini-3-pro", "google"),
            ("gpt-6-astra", "codex"),
            ("o9-codex", "codex"),
            ("gpt-6-codex", "codex"),
        )
        for model, expected in cases:
            for brand in COPILOT_BRANDS:
                with self.subTest(model=model, bundle=brand):
                    self.database.unlink(missing_ok=True)
                    make_database(self.database, [("session-1", None, model)])
                    proc = self.run_guard(brand)
                    if expected == brand:
                        self.assert_proceeds(proc, model, brand)
                    else:
                        self.assert_refused(
                            proc,
                            f"a {expected} model",
                            f"this is the {brand} bundle",
                            f"load the kanban-{expected} bundle instead",
                        )

    def test_an_unrecognized_model_refuses_without_recommending_a_bundle(self):
        # Anchored and exact: no casefolding, no trimming, no substring match,
        # and a name matching two brands is as unknown as one matching none.
        for model in ("o9", "Kimi-K3", " kimi-k3", "my-kimi-k3", "gemini", "kimi-codex"):
            with self.subTest(model=model):
                self.database.unlink(missing_ok=True)
                make_database(self.database, [("session-1", None, model)])
                line = self.assert_refused(
                    self.run_guard("kimi"),
                    repr(model),
                    "maps to no single known brand",
                    "this is the kimi bundle",
                )
                self.assertNotIn("load the", line)

    def test_a_missing_or_empty_session_id_refuses(self):
        make_database(self.database, [("", None, "kimi-k3"), ("   ", None, "kimi-k3")])
        for session in (None, "", "   "):
            with self.subTest(session=session):
                self.assert_refused(
                    self.run_guard("kimi", session=session),
                    "COPILOT_AGENT_SESSION_ID is unset or empty",
                    "this is the kimi bundle",
                )

    def test_an_absent_database_refuses_and_is_not_created(self):
        proc = self.run_guard("kimi")
        self.assert_refused(proc, "does not exist", "this is the kimi bundle")
        self.assertFalse(self.database.exists())
        self.assertEqual(list(self.copilot_home.iterdir()), [])

    def test_the_default_copilot_home_is_the_one_read(self):
        default_home = self.root / "home" / ".copilot"
        default_home.mkdir(parents=True)
        make_database(default_home / "session-store.db", [("session-1", None, "kimi-k3")])
        self.assert_proceeds(
            self.run_guard("kimi", copilot_home=False), "kimi-k3", "kimi"
        )

    def test_a_session_with_no_main_agent_row_refuses(self):
        make_database(
            self.database,
            [
                ("session-1", "subagent-1", "kimi-k3"),
                ("session-2", None, "kimi-k3"),
            ],
        )
        self.assert_refused(
            self.run_guard("kimi"), "no main-agent entry for session 'session-1'"
        )

    def test_a_newest_main_row_naming_no_model_refuses(self):
        for model in (None, "", "  "):
            with self.subTest(model=model):
                self.database.unlink(missing_ok=True)
                # An older usable row is present and must not be fallen back to.
                make_database(
                    self.database,
                    [("session-1", None, "kimi-k3"), ("session-1", None, model)],
                )
                self.assert_refused(self.run_guard("kimi"), "names no model")

    def test_an_incompatible_schema_or_a_non_database_refuses(self):
        schemas = (
            ("no table", "CREATE TABLE something_else (id INTEGER PRIMARY KEY)"),
            (
                "no agent_id column",
                "CREATE TABLE assistant_usage_events ("
                "id INTEGER PRIMARY KEY, session_id TEXT, model TEXT)",
            ),
        )
        for label, schema in schemas:
            with self.subTest(schema=label):
                self.database.unlink(missing_ok=True)
                make_database(self.database, [], schema=schema)
                self.assert_refused(self.run_guard("kimi"), "could not be read")
        with self.subTest(schema="not sqlite"):
            self.database.unlink()
            self.database.write_text("not a database\n", encoding="utf-8")
            self.assert_refused(self.run_guard("kimi"), "could not be read")

    def test_only_the_newest_main_agent_row_of_this_session_counts(self):
        # A newer subagent row and a newer row of another session both name a
        # matching model; the newest main-agent row of this session does not.
        make_database(
            self.database,
            [
                ("session-1", None, "kimi-k3"),
                ("session-1", None, "claude-opus-5"),
                ("session-1", "subagent-1", "kimi-k3"),
                ("session-2", None, "kimi-k3"),
            ],
        )
        self.assert_refused(self.run_guard("kimi"), "a claude model")

        # And the converse: newer foreign rows do not taint a matching session.
        self.database.unlink()
        make_database(
            self.database,
            [
                ("session-1", None, "claude-opus-5"),
                ("session-1", None, "kimi-k3"),
                ("session-1", "subagent-1", "claude-opus-5"),
                ("session-2", None, "claude-opus-5"),
            ],
        )
        self.assert_proceeds(self.run_guard("kimi"), "kimi-k3", "kimi")

    def test_the_session_id_is_query_data(self):
        make_database(self.database, [("session-1", None, "kimi-k3")])
        self.assert_refused(
            self.run_guard("kimi", session="x' OR '1'='1"), "no main-agent entry"
        )

    def test_the_database_is_left_byte_identical(self):
        make_database(self.database, [("session-1", None, "kimi-k3")])
        before = self.database.read_bytes()
        self.assert_proceeds(self.run_guard("kimi"), "kimi-k3", "kimi")
        self.assertEqual(self.database.read_bytes(), before)


class GuardPlacementTests(unittest.TestCase):
    """Requirements 1 and 5: one check per workflow, authored once per source,
    reaching every Copilot asset and nothing else, ahead of the claim."""

    def test_each_source_authors_the_check_once_inside_the_copilot_block(self):
        texts = {}
        for source in (SOLVE_SOURCE, AUTOSOLVE_SOURCE):
            text = read(source)
            fences = guard_fences(text)
            self.assertEqual(len(fences), 1, source)
            texts[source] = fences[0]
            owners = [
                block.group("brands")
                for block in BRAND_BLOCK_RE.finditer(text)
                if GUARD_TOKEN in block.group("body")
            ]
            self.assertEqual(owners, ["kimi,google"], source)
        # The two workflows run one program, not two that could drift.
        self.assertEqual(texts[SOLVE_SOURCE], texts[AUTOSOLVE_SOURCE])

    def test_every_copilot_asset_carries_the_check_for_its_own_brand(self):
        template = guard_fences(read(SOLVE_SOURCE))[0]
        for (brand, workflow), path in COPILOT_ASSETS.items():
            with self.subTest(asset=path):
                self.assertEqual(
                    the_guard(path), template.replace("{{brand:name}}", brand)
                )

    def test_no_excluded_asset_depends_on_the_copilot_session_record(self):
        for path in EXCLUDED_ASSETS:
            with self.subTest(asset=path):
                self.assertFalse(carries_guard(read(path)), path)

    def test_the_coverage_rule_detects_a_planted_check(self):
        # The control for the negative assertion above.
        planted = read(EXCLUDED_ASSETS[0]) + "\n" + the_guard(COPILOT_ASSETS[("kimi", "solve")])
        self.assertTrue(carries_guard(planted))

    def test_grok_says_it_has_no_deterministic_signal(self):
        text = read("grok-plugin/plugins/kanban/skills/solve/SKILL.md")
        self.assertIn("## Confirm The Session Model", text)
        self.assertIn(
            "The Grok CLI keeps no session record this workflow can read deterministically",
            text,
        )

    def test_solve_checks_before_its_claim(self):
        for brand in COPILOT_BRANDS:
            text = read(COPILOT_ASSETS[(brand, "solve")])
            with self.subTest(brand=brand):
                self.assertEqual(text.count(CLAIM_COMMAND), 1)
                self.assertLess(
                    text.index(the_guard(COPILOT_ASSETS[(brand, "solve")])),
                    text.index(CLAIM_COMMAND),
                )
                squashed = re.sub(r"\s+", " ", text)
                self.assertIn(
                    "stop with exactly the one line it printed: claim no issue, "
                    "push no branch, and open no pull request.",
                    squashed,
                )
                self.assertIn(
                    "The one exception is a refusal from \"Confirm The Session "
                    "Model\": end this workflow with exactly the line that check "
                    "printed, having claimed nothing.",
                    squashed,
                )

    def test_autosolve_checks_before_solve_and_a_refusal_ends_the_run(self):
        for brand in COPILOT_BRANDS:
            path = COPILOT_ASSETS[(brand, "autosolve")]
            text = read(path)
            with self.subTest(brand=brand):
                guard_at = text.index(the_guard(path))
                self.assertLess(guard_at, text.index("## 2. Complete the solve"))
                self.assertLess(
                    guard_at, text.index("## 3. Documentation-only issues")
                )
                squashed = re.sub(r"\s+", " ", text)
                self.assertIn(
                    "A non-zero exit ends this run with exactly the one line it "
                    "printed: do not run /solve, do not reach step 3's reclaim or "
                    "either of its dispositions, and do not reach step 5's review. "
                    "/solve repeats the check before its own claim, and a refusal "
                    "there ends this run the same way.",
                    squashed,
                )
                self.assertIn(
                    "The one exception is a session model refusal, from step 1 or "
                    "from inside /solve: end with exactly the line that check "
                    "printed.",
                    squashed,
                )

    def test_the_fail_closed_reasoning_is_stated_where_the_check_lives(self):
        # Requirement 3: a later reader must not soften a refusal into a warning.
        for path in COPILOT_ASSETS.values():
            with self.subTest(asset=path):
                fence = the_guard(path)
                self.assertIn("A false origin marker is durable", fence)
                self.assertIn("may be softened into a warning", fence)


if __name__ == "__main__":
    unittest.main()
