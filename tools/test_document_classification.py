"""Completeness check for docs/agent-workflow-contract.md §7.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Issue #225: the intended policy is that coordination documents — designs,
findings reports, and their status ledgers — publish straight to `master`,
while code contracts land atomically with their implementation. Nothing in the
tree said which document is which, so an automated publisher had no way to tell
them apart. §7 states the classification; this module holds it to being
exhaustive, unambiguous, and grounded in the tree.

The subject inventory is `git ls-files '*.md'`, not a list restated here: a
document is classified or reported the moment it is tracked, rather than
whenever someone remembers to add it. The classification in §7 is this module's
independent source of truth. The release inventories in
tools/test_source_distribution.py corroborate it — every RELEASE_DOCUMENTS
entry must classify pr-atomic — but are never the source the classes are read
from, because release packaging and publication policy have to stay free to
diverge.

Fail-closed is the property under test rather than a comment: a tracked
Markdown file matching no row fails this check, so an unclassified document is
pr-atomic to every consumer and is never direct-master eligible.
"""

from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path, PurePosixPath

REPO_ROOT = Path(__file__).resolve().parent.parent
CONTRACT_PATH = REPO_ROOT / "docs" / "agent-workflow-contract.md"
CLAUDE_MD_PATH = REPO_ROOT / "CLAUDE.md"
CONFIG_EXAMPLE_PATH = REPO_ROOT / "config.toml.example"

# The one repository the example configuration declares live coordination paths
# for. §7's table is Kanban's own, so its rows may only ever reach a
# per-repository override keyed by Kanban's own canonical slug.
KANBAN_REPOSITORY_KEY = "coghex/kanban"

CLASSES = ("coordination", "pr-atomic")

# §7's reason vocabulary. `audit-report` and `coordination-note` are the only
# two that admit the coordination lane — the ledgered reports and the
# free-form notes under docs/coordination/ (issue #409) — and the other three
# are the ways a document can be coupled to the tree tightly enough that
# changing it alone can break something.
REASONS = (
    "test-parsed",
    "release-document",
    "implementation-coupled",
    "audit-report",
    "coordination-note",
)
COORDINATION_REASONS = ("audit-report", "coordination-note")

# The documents a tracked test reads as data, and what reads each. Pinned
# rather than discovered: a grep for a path in a test module also hits the
# release lists and the prose comments that merely name a document, so it would
# report every doc as parsed. Correction from issue #225's canonical review:
# docs/design.md is parsed by test/Spec/UI/Keys.hs and both plugin bundles are
# parsed by their own modules, so the reason is not confined to the two
# workflow-contract documents the issue body named.
TEST_PARSED_PATHS = {
    # tools/test_issue_templates.py reads both templates' frontmatter, their
    # headings, and the epic template's Children checklist, which
    # src/Kanban/Tracker.hs parses in an issue filed from it (issue #434).
    ".github/ISSUE_TEMPLATE/",
    # tools/test_pull_request_template.py and test/Spec/Agent/PullRequestFlow.hs
    # both read the tracked pull-request template and run the three parsers
    # that route on its absent pr-origin marker over it (issue #494).
    ".github/pull_request_template.md",
    # tools/test_agent_workflow_contract.py parses §4; this module parses §7.
    "docs/agent-workflow-contract.md",
    # test/Spec/UI/Keys.hs parses the §7 keybinding table.
    "docs/design.md",
    # tools/test_document_workflow_contract.py parses its §2 asset table.
    "docs/document-workflow-contract.md",
    # tools/test_drafting_workflow_contract.py parses its §2 asset table.
    "docs/drafting-workflow-contract.md",
    # tools/test_board_screenshot.py reconciles the regeneration procedure's
    # pinned font, geometry, and paths against the renderer's own constants.
    "docs/media/README.md",
    # tools/test_claude_plugin.py reads every packaged command's frontmatter
    # and body.
    "claude-plugin/",
    # tools/test_codex_plugin.py reads every packaged skill the same way.
    "codex-plugin/",
    # tools/test_render_command_sources.py reads the authored command sources
    # under tools/command_sources/ and byte-compares the files rendered from
    # them, so editing either alone fails build-test (issue #375).
    "tools/",
}

# The coordination declarations §7 names in prose, so a contributor can place
# a known document without reading the machine-readable rows. Reconciled
# against those rows below: the prose is the human-readable answer, and it must
# not be able to drift from the one the check enforces. The sentence carries no
# count — a count would go stale the moment a note landed under a directory
# row (issue #409) — so what is compared is the set of backticked paths.
PROSE_COORDINATION_SENTENCE_RE = re.compile(
    r"The `coordination` documents are\s+(?P<body>.*?)\.\s*\*\*Every other",
    re.DOTALL,
)

# A miniature classification and inventory for the negative cases below. They
# run against this rather than against the live tree so that each one fails for
# its own reason: an inventory-derived fixture would make every negative case
# fail again the moment a real document went unclassified, burying the one
# assertion that actually described the gap.
FIXTURE_DECLARED = {
    "CLAUDE.md",
    "codex-plugin/",
    "docs/design.md",
    "docs/ui-bugs.md",
}
FIXTURE_INVENTORY = [
    "CLAUDE.md",
    "codex-plugin/plugins/kanban/skills/solve/SKILL.md",
    "docs/design.md",
    "docs/ui-bugs.md",
]

SECTION_7_FENCE_RE = re.compile(
    r"^##\s*7\.\s*Document publication classification\s*$.*?```text\n(?P<body>.*?)\n```",
    re.DOTALL | re.MULTILINE,
)

CLASSIFICATION_ROW_RE = re.compile(
    r"^(?P<path>\S+)\s*\|\s*(?P<klass>[\w-]+)\s*\|\s*(?P<reasons>[^|]+?)\s*$"
)

# §7's fail-closed default and consuming-repository rule, and the pointer
# CLAUDE.md owes contributors. Compared against normalized() output so
# reflowing a paragraph or bolding a phrase does not fail CI.
CONTRACT_STATEMENTS = {
    "fail-closed-default": "Anything unclassified is pr-atomic to every consumer",
    "unknown-is-never-direct-master": "never direct-master eligible",
    "classification-is-kanbans-own": "This classification is Kanban's own",
    "consumer-declares-its-own": (
        "A consuming repository declares its own direct-publication lane through "
        "workflow.direct_publication_paths"
    ),
    "no-inference-for-consumers": (
        "Kanban never infers a consuming repository's classes from file extension "
        "or directory"
    ),
    "component-boundary": "matched by whole path component rather than by string prefix",
    "assets-are-not-documents": "it classifies documents, not bundle assets",
    # Issue #409: the release exclusion and the drainer read a directory
    # declaration over every tracked descendant, deliberately, while the rows
    # classify tracked Markdown alone — recorded so the difference cannot be
    # read as drift between the row and the configuration.
    "wider-coverage-is-deliberate": (
        "covers every tracked descendant whatever its extension"
    ),
}

CLAUDE_MD_STATEMENTS = {
    "points-at-the-section": "agent-workflow-contract.md section 7",
    "names-both-lanes": "coordination documents publish straight to master",
    "names-the-pr-lane": "everything else is pr-atomic",
    "states-fail-closed": "Anything unclassified is pr-atomic",
}


def normalized(text: str) -> str:
    """Collapse whitespace and drop markdown emphasis so an assertion on a
    documented boundary survives reflowing a paragraph or bolding a word."""
    return re.sub(r"\s+", " ", text.replace("*", "").replace("`", ""))


def canonical(text: str) -> str:
    """normalized() plus case folding, for prose asserted across two files
    where the same rule legitimately starts a sentence in one and appears
    mid-sentence in the other."""
    return normalized(text).lower()


def contract_text() -> str:
    return CONTRACT_PATH.read_text(encoding="utf-8")


def _release_inventory():
    """tools/test_source_distribution.py's release lists, loaded from the
    module itself rather than copied here. Loaded by path under a private name
    so this works whether unittest imported that module as a bare top-level
    name (discovery with -s tools) or inside a `tools.` namespace package, and
    so the copy loaded here can never shadow the discovered one."""
    source = REPO_ROOT / "tools" / "test_source_distribution.py"
    spec = importlib.util.spec_from_file_location("_kanban_release_inventory", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _config_loader():
    """tools/kanban_config.py, loaded by path under a private name for the same
    reason _release_inventory() is: this module is discovered both as a bare
    top-level name and inside a `tools.` namespace package, and the copy loaded
    here must never shadow the one the loader's own tests import."""
    source = REPO_ROOT / "tools" / "kanban_config.py"
    spec = importlib.util.spec_from_file_location("_kanban_config_loader", source)
    module = importlib.util.module_from_spec(spec)
    # Registered before execution because @dataclass resolves each class's own
    # module out of sys.modules while the body is still running; an unregistered
    # module raises there rather than at import.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def load_example_config(path=CONFIG_EXAMPLE_PATH):
    """`path` through the real configuration loader, as (module, raw, warnings).

    Read through tools/kanban_config.py rather than a private TOML parse, so
    what is asserted is the value a drainer actually resolves — including the
    per-repository merge, which is the whole point of putting Kanban's rows
    under an override instead of the global default."""
    config = _config_loader()
    raw, warnings = config.load_raw_config(str(path))
    return config, raw, warnings


def configured_coordination_paths(config, raw, key=KANBAN_REPOSITORY_KEY):
    """The coordination paths `key` resolves to, as a set."""
    return set(config.resolve_config(key, raw).workflow.coordination_paths)


def declared_coverage(declared_paths, markdown_paths):
    """The tracked Markdown paths `declared_paths` covers — §7's own subject,
    which is the set the rows and the configured entries are reconciled over.
    The release and drainer consumers deliberately cover more (every tracked
    descendant of a directory declaration, whatever its extension); §7 records
    that difference, and this comparison stays on the classification's side of
    it."""
    return {path for path in markdown_paths if matching_rows(declared_paths, path)}


def coordination_drift(configured, coordination_rows, markdown_paths):
    """(covered by configuration but by no coordination row, covered by a row
    but by no configured entry), over the tracked Markdown inventory. Empty on
    both sides is the only agreement between §7's rows and the example
    override — compared as effective coverage rather than set membership, so
    the `docs/coordination/` row and the identical configured entry agree
    without either side enumerating the directory's children (issue #409)."""
    configured_cover = declared_coverage(configured, markdown_paths)
    row_cover = declared_coverage(coordination_rows, markdown_paths)
    return (
        sorted(configured_cover - row_cover),
        sorted(row_cover - configured_cover),
    )


def undeclared_configured_entries(configured, coordination_rows):
    """Configured entries that are not themselves §7 coordination
    declarations, sorted.

    Coverage over tracked Markdown cannot see these: a configured `src/`
    covers no tracked Markdown and overlaps no test-parsed declaration, so
    both comparisons stay silent — yet the drainer reads the entry over every
    file, and would treat a `src/Kanban/Domain.hs` advance as
    coordination-only. The declaration strings are the subject here, so the
    check is exact while still naming a directory as one string with no child
    enumerated."""
    return sorted(set(configured) - set(coordination_rows))


def declarations_overlap(one: str, other: str) -> bool:
    """Whether two declarations cover any common path: either names the other
    exactly, or a directory declaration covers the other's anchor."""
    return row_covers(one, other.rstrip("/")) or row_covers(other, one.rstrip("/"))


def configured_test_parsed_paths(configured, declared=TEST_PARSED_PATHS):
    """Configured coordination entries that overlap content a tracked test
    reads as data, in either direction: a test-parsed declaration covering the
    configured entry (a bundle document listed by its own path would slip past
    `in TEST_PARSED_PATHS`), or a configured directory covering a test-parsed
    declaration — a broad entry such as `docs/` covers `docs/design.md`
    without being covered by anything (issue #409)."""
    return sorted(
        path
        for path in configured
        if any(declarations_overlap(path, parsed) for parsed in declared)
    )


def invalid_coordination_lane_reasons(rows):
    """Rows whose class and reasons disagree about the coordination lane, with
    the stray reasons: a `coordination` row citing anything outside
    `audit-report`/`coordination-note`, or a `pr-atomic` row citing either of
    them. Both halves matter — without the second, a coordination reason could
    quietly spread to documents that must not publish directly."""
    violations = {}
    for path, row in sorted(rows.items()):
        cited = set(row["reasons"])
        if row["klass"] == "coordination":
            stray = sorted(cited - set(COORDINATION_REASONS))
        else:
            stray = sorted(cited & set(COORDINATION_REASONS))
        if stray:
            violations[path] = stray
    return violations


def tracked_markdown(repo_root=REPO_ROOT):
    """Every Git-tracked *.md path, repository-relative. The subject inventory
    is discovered rather than enumerated, so a document added later is
    classified or reported as soon as it is tracked."""
    proc = subprocess.run(
        ["git", "-C", str(repo_root), "ls-files", "-z", "--", "*.md"],
        text=True,
        capture_output=True,
    )
    if proc.returncode != 0:
        raise AssertionError(f"git ls-files failed:\n{proc.stderr}")
    return sorted(entry for entry in proc.stdout.split("\0") if entry)


def parse_classification(text=None):
    """Rows from the §7 machine-readable fence, keyed by declared path.
    Anchored to the §7 heading so §4's dependency manifest — or any ```text
    fence added to this document later — can never be parsed as the
    classification. Parameterized by text so the load-bearing tests below can
    drive it against a fixture rather than only against the document that
    already passes."""
    fence_match = SECTION_7_FENCE_RE.search(contract_text() if text is None else text)
    if fence_match is None:
        raise AssertionError(
            "docs/agent-workflow-contract.md has no ```text classification "
            "fence under its '## 7. Document publication classification' heading"
        )
    rows = {}
    for line in fence_match.group("body").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = CLASSIFICATION_ROW_RE.match(line)
        if match is None:
            raise AssertionError(f"unparseable classification row: {line!r}")
        row = match.groupdict()
        row["reasons"] = [
            reason.strip() for reason in row["reasons"].split(";") if reason.strip()
        ]
        if row["path"] in rows:
            raise AssertionError(f"duplicate classification row for {row['path']!r}")
        rows[row["path"]] = row
    return rows


def row_covers(declared_path: str, markdown_path: str) -> bool:
    """Whether one §7 row covers one tracked Markdown path.

    A row ending in `/` is a directory row and covers the tracked Markdown
    files beneath that directory, compared by whole path component: the
    `codex-plugin/` row covers codex-plugin/plugins/.../SKILL.md and never a
    sibling such as codex-plugin-old/. Any other row names one file exactly.
    Non-Markdown files are not this classification's subject at all, so the
    caller passes only *.md paths.
    """
    if not declared_path.endswith("/"):
        return declared_path == markdown_path
    prefix = PurePosixPath(declared_path.rstrip("/")).parts
    return PurePosixPath(markdown_path).parts[: len(prefix)] == prefix


def matching_rows(declared_paths, markdown_path):
    return [path for path in declared_paths if row_covers(path, markdown_path)]


def unclassified_paths(declared_paths, markdown_paths):
    """Tracked Markdown that no row covers. These fail closed: pr-atomic to
    every consumer, and reported here so the gap is repaired rather than
    silently inherited."""
    return sorted(
        path for path in markdown_paths if not matching_rows(declared_paths, path)
    )


def doubly_classified_paths(declared_paths, markdown_paths):
    """Tracked Markdown that two or more rows cover, with the rows that
    collided. A document with two rows has two lanes, which is no lane."""
    collisions = {}
    for path in markdown_paths:
        matched = matching_rows(declared_paths, path)
        if len(matched) > 1:
            collisions[path] = sorted(matched)
    return collisions


def missing_declared_paths(declared_paths, repo_root=REPO_ROOT):
    """Declared paths absent from the tree: a file row whose file is gone, or a
    directory row whose directory is gone."""
    missing = []
    for path in sorted(declared_paths):
        target = repo_root / path.rstrip("/")
        if path.endswith("/"):
            if not target.is_dir():
                missing.append(path)
        elif not target.is_file():
            missing.append(path)
    return missing


def missing_statements(text, statements, normalize=normalized):
    """The declared statements `text` no longer makes, by key."""
    document = normalize(text)
    return sorted(
        key
        for key, statement in statements.items()
        if normalize(statement) not in document
    )


def prose_coordination_set(text=None):
    """The coordination documents §7 names in prose, as a set of paths."""
    document = text if text is not None else contract_text()
    match = PROSE_COORDINATION_SENTENCE_RE.search(document)
    if match is None:
        raise AssertionError(
            "docs/agent-workflow-contract.md §7 no longer names its coordination "
            "documents in prose; contributors would have to read the "
            "machine-readable rows to place a known document"
        )
    return set(re.findall(r"`([^`]+)`", match.group("body")))


class ClassificationShapeTests(unittest.TestCase):
    def setUp(self):
        self.rows = parse_classification()

    def test_every_row_declares_a_known_class_and_at_least_one_known_reason(self):
        for path, row in sorted(self.rows.items()):
            self.assertIn(row["klass"], CLASSES, path)
            self.assertTrue(row["reasons"], f"{path} states no reason")
            for reason in row["reasons"]:
                self.assertIn(reason, REASONS, path)

    def test_the_coordination_reasons_are_exactly_the_coordination_lane(self):
        # The two halves of §7's "audit-report and coordination-note are the
        # only reasons that admit the coordination lane": a coordination row
        # cites nothing outside that pair, and no pr-atomic row cites either.
        # Without the second half a coordination reason could quietly spread
        # to documents that must not publish directly.
        self.assertEqual(invalid_coordination_lane_reasons(self.rows), {})

    def test_a_lane_reason_violation_is_reported_in_both_directions(self):
        # The check above is load-bearing rather than decorative: a planted
        # coordination row citing a pr-atomic reason, and a planted pr-atomic
        # row citing either coordination reason, are each named.
        def planted(path, klass, reasons):
            return {path: {"path": path, "klass": klass, "reasons": reasons}}

        self.assertEqual(
            invalid_coordination_lane_reasons(
                planted("docs/x.md", "coordination", ["release-document"])
            ),
            {"docs/x.md": ["release-document"]},
        )
        for reason in COORDINATION_REASONS:
            with self.subTest(reason=reason):
                self.assertEqual(
                    invalid_coordination_lane_reasons(
                        planted("docs/y.md", "pr-atomic", ["test-parsed", reason])
                    ),
                    {"docs/y.md": [reason]},
                )
        self.assertEqual(
            invalid_coordination_lane_reasons(
                planted("docs/z.md", "coordination", ["audit-report"])
                | planted("docs/coordination/", "coordination", ["coordination-note"])
            ),
            {},
        )

    def test_the_test_parsed_reason_names_exactly_the_parsed_documents(self):
        declared = {
            path for path, row in self.rows.items() if "test-parsed" in row["reasons"]
        }
        self.assertEqual(
            declared,
            TEST_PARSED_PATHS,
            "the test-parsed reason must name exactly the documents a tracked "
            "test reads as data",
        )

    def test_every_test_parsed_document_is_pr_atomic(self):
        # Requirement 5: a document a test parses can fail build-test when it
        # changes alone, so it cannot take the direct-master lane.
        for path in sorted(TEST_PARSED_PATHS):
            self.assertEqual(self.rows[path]["klass"], "pr-atomic", path)

    def test_a_row_may_record_more_than_one_reason(self):
        # The correction that produced the `;`-separated form: both contract
        # documents are test-parsed and released, and losing either rationale
        # would understate what changing them breaks.
        for path in ("docs/design.md", "docs/agent-workflow-contract.md"):
            self.assertEqual(
                sorted(self.rows[path]["reasons"]),
                ["implementation-coupled", "release-document", "test-parsed"],
                path,
            )


class ClassificationCoverageTests(unittest.TestCase):
    def setUp(self):
        self.rows = parse_classification()
        self.declared = set(self.rows)
        self.markdown = tracked_markdown()

    def test_the_tracked_markdown_inventory_is_non_empty(self):
        # Guards the whole class: if git ls-files ever returned nothing, every
        # coverage assertion below would pass vacuously.
        self.assertTrue(self.markdown)
        self.assertIn("docs/design.md", self.markdown)

    def test_every_tracked_markdown_file_matches_a_row(self):
        unclassified = unclassified_paths(self.declared, self.markdown)
        self.assertEqual(
            unclassified,
            [],
            "tracked Markdown with no row in docs/agent-workflow-contract.md §7. "
            "Each is pr-atomic to every consumer until classified: "
            f"{unclassified}",
        )

    def test_no_tracked_markdown_file_matches_two_rows(self):
        collisions = doubly_classified_paths(self.declared, self.markdown)
        self.assertEqual(
            collisions,
            {},
            f"tracked Markdown covered by more than one §7 row: {collisions}",
        )

    def test_every_declared_path_exists_in_the_tree(self):
        missing = missing_declared_paths(self.declared)
        self.assertEqual(
            missing,
            [],
            f"declared in docs/agent-workflow-contract.md §7 but absent: {missing}",
        )

    def test_the_plugin_bundles_are_covered_through_a_directory_row(self):
        # Requirement 1's directory row, exercised rather than assumed: the 24
        # tracked bundle documents reach their class through two rows.
        bundle_docs = [
            path
            for path in self.markdown
            if path.startswith(("claude-plugin/", "codex-plugin/"))
        ]
        self.assertTrue(bundle_docs)
        for path in bundle_docs:
            self.assertEqual(
                matching_rows(self.declared, path),
                [path.split("/", 1)[0] + "/"],
                path,
            )
            self.assertNotIn(path, self.declared, f"{path} is covered twice")

    def test_an_unclassified_tracked_markdown_path_is_reported(self):
        # The absence check is load-bearing rather than decorative: point it at
        # an isolated inventory holding a document no row covers and it names
        # that one.
        self.assertEqual(unclassified_paths(FIXTURE_DECLARED, FIXTURE_INVENTORY), [])
        self.assertEqual(
            unclassified_paths(
                FIXTURE_DECLARED, FIXTURE_INVENTORY + ["docs/newly-tracked-report.md"]
            ),
            ["docs/newly-tracked-report.md"],
        )

    def test_a_document_added_under_a_declared_directory_is_already_covered(self):
        # The other side of the same rule: a new packaged workflow inherits its
        # bundle's class instead of being reported, which is why a directory row
        # covers the bundles once rather than per file.
        added = "codex-plugin/plugins/kanban/skills/brand-new/SKILL.md"
        self.assertEqual(
            unclassified_paths(FIXTURE_DECLARED, FIXTURE_INVENTORY + [added]), []
        )
        self.assertEqual(matching_rows(FIXTURE_DECLARED, added), ["codex-plugin/"])

    def test_a_sibling_of_a_declared_directory_is_not_covered_by_it(self):
        # The documented component boundary: `codex-plugin/` is a statement
        # about one tracked component, not about every name that starts the
        # same way. A string-prefix match would silently classify these.
        for stray in (
            "codex-plugin-old/plugins/kanban/skills/solve/SKILL.md",
            "claude-plugin-vendor/README.md",
        ):
            self.assertEqual(matching_rows(self.declared, stray), [], stray)
        self.assertEqual(
            unclassified_paths(
                FIXTURE_DECLARED, FIXTURE_INVENTORY + ["codex-plugin-old/x.md"]
            ),
            ["codex-plugin-old/x.md"],
        )

    def test_the_coordination_directory_is_covered_through_its_directory_row(self):
        # Issue #409's directory row, exercised against the live tree: every
        # tracked note under docs/coordination/ reaches the coordination lane
        # through the one row, and the seed README proves the set non-empty.
        self.assertIn("docs/coordination/", self.declared)
        covered = [
            path for path in self.markdown if path.startswith("docs/coordination/")
        ]
        self.assertIn("docs/coordination/README.md", covered)
        for path in covered:
            self.assertEqual(
                matching_rows(self.declared, path), ["docs/coordination/"], path
            )
            self.assertNotIn(path, self.declared, f"{path} is covered twice")

    def test_a_note_added_under_the_coordination_directory_is_already_covered(self):
        # Requirement 5: tracking a new note needs no §7 edit. The added path
        # inherits the directory row rather than being reported unclassified.
        added = "docs/coordination/scratch-note.md"
        self.assertEqual(matching_rows(self.declared, added), ["docs/coordination/"])
        self.assertEqual(unclassified_paths(self.declared, self.markdown + [added]), [])

    def test_a_coordination_directory_sibling_is_not_covered(self):
        # The whole-component boundary on the new row: a similarly prefixed
        # sibling matches no row and therefore fails closed as pr-atomic.
        for stray in (
            "docs/coordination-old/scratch-note.md",
            "docs/coordination2/scratch-note.md",
        ):
            self.assertEqual(matching_rows(self.declared, stray), [], stray)

    def test_an_overlapping_directory_and_file_declaration_is_a_conflict(self):
        # Requirement 10's example: `docs/` plus `docs/ui-bugs.md` covers one
        # document twice, which is two lanes and therefore no lane.
        self.assertEqual(
            doubly_classified_paths({"docs/", "docs/ui-bugs.md"}, ["docs/ui-bugs.md"]),
            {"docs/ui-bugs.md": ["docs/", "docs/ui-bugs.md"]},
        )

    def test_a_declared_path_missing_from_the_tree_is_reported(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo_root = Path(temp_dir)
            for path in sorted(self.declared):
                target = repo_root / path.rstrip("/")
                if path.endswith("/"):
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text("x\n", encoding="utf-8")
            self.assertEqual(missing_declared_paths(self.declared, repo_root), [])

            (repo_root / "docs" / "ui-bugs.md").unlink()
            self.assertEqual(
                missing_declared_paths(self.declared, repo_root), ["docs/ui-bugs.md"]
            )

    def test_a_declared_directory_missing_from_the_tree_is_reported(self):
        # A directory row is checked as a directory: a file left at that path,
        # or nothing at all, is a broken declaration either way.
        with tempfile.TemporaryDirectory() as temp_dir:
            repo_root = Path(temp_dir)
            self.assertEqual(
                missing_declared_paths({"codex-plugin/"}, repo_root), ["codex-plugin/"]
            )
            (repo_root / "codex-plugin").write_text("not a directory\n", encoding="utf-8")
            self.assertEqual(
                missing_declared_paths({"codex-plugin/"}, repo_root), ["codex-plugin/"]
            )

    def test_two_overlapping_declarations_are_reported(self):
        # The realistic regression: a bundle document given its own row while
        # its bundle's directory row still stands, so the file carries two
        # lanes. Neither row is wrong on its own, which is why this is checked
        # rather than left to review.
        self.assertEqual(
            doubly_classified_paths(FIXTURE_DECLARED, FIXTURE_INVENTORY), {}
        )
        overlapping = FIXTURE_DECLARED | {
            "codex-plugin/plugins/kanban/skills/solve/SKILL.md"
        }
        self.assertEqual(
            doubly_classified_paths(overlapping, FIXTURE_INVENTORY),
            {
                "codex-plugin/plugins/kanban/skills/solve/SKILL.md": [
                    "codex-plugin/",
                    "codex-plugin/plugins/kanban/skills/solve/SKILL.md",
                ]
            },
        )

    def test_two_overlapping_directory_declarations_are_reported(self):
        nested = FIXTURE_DECLARED | {"codex-plugin/plugins/"}
        self.assertEqual(
            doubly_classified_paths(nested, FIXTURE_INVENTORY),
            {
                "codex-plugin/plugins/kanban/skills/solve/SKILL.md": [
                    "codex-plugin/",
                    "codex-plugin/plugins/",
                ]
            },
        )


class ReleaseInventoryReconciliationTests(unittest.TestCase):
    """The release lists corroborate the classification; they never define it.

    tools/test_source_distribution.py already records, for a different purpose,
    which documents ship. That agreement is worth asserting — but as a
    reconciliation between two independent statements, so release packaging and
    publication policy stay free to diverge later.
    """

    def setUp(self):
        self.rows = parse_classification()
        self.release = _release_inventory()

    def test_every_release_document_is_pr_atomic(self):
        # Requirement 5, read straight off the other module's live tuple rather
        # than a copy: a document that ships cannot publish direct-to-master.
        for path in self.release.RELEASE_DOCUMENTS:
            self.assertIn(
                path,
                self.rows,
                f"{path} ships in RELEASE_DOCUMENTS but has no §7 row",
            )
            self.assertEqual(self.rows[path]["klass"], "pr-atomic", path)

    def test_the_release_document_reason_is_grounded_in_a_release_inventory(self):
        released_trees = tuple(f"{tree}/" for tree in self.release.RELEASE_TREES)
        shipped = set(self.release.RELEASE_DOCUMENTS) | set(
            self.release.RELEASE_ROOT_FILES
        )
        excluded = set(self.release.EXCLUDED_TRACKED_PATHS)
        for path, row in sorted(self.rows.items()):
            claims_release = "release-document" in row["reasons"]
            in_inventory = path in shipped or path.startswith(released_trees)
            self.assertEqual(
                claims_release,
                in_inventory,
                f"{path}: the release-document reason and "
                "tools/test_source_distribution.py's inventories disagree",
            )
            if claims_release:
                self.assertNotIn(path, excluded, path)

    def test_every_coordination_document_is_a_release_exclusion(self):
        excluded = set(self.release.EXCLUDED_TRACKED_PATHS)
        for path, row in sorted(self.rows.items()):
            if row["klass"] == "coordination":
                self.assertIn(
                    path,
                    excluded,
                    f"{path} publishes direct-to-master but ships in the release",
                )


class CoordinationPathConfigurationTests(unittest.TestCase):
    """Issue #237: §7 says which documents may publish direct-to-master, and
    `workflow.coordination_paths` is what a drainer actually reads. Those are
    two independent statements of one policy, so they are reconciled here rather
    than left to agree by hand — beside the §7 parser that already exists, so
    the example configuration is not checked behind a second one.

    The classification is Kanban's own (§7), which is why the paths live under a
    `coghex/kanban` override and the global default ships empty: a consuming
    repository must declare its own rather than inherit Kanban's.

    Each negative case runs against its own miniature fixture, following this
    module's convention, so a planted violation reports its own cause instead of
    failing again for whatever the live tree happens to be missing.
    """

    def setUp(self):
        self.rows = parse_classification()
        self.coordination = {
            path for path, row in self.rows.items() if row["klass"] == "coordination"
        }
        self.markdown = tracked_markdown()
        self.config, self.raw, self.warnings = load_example_config()

    def write_fixture(self, directory, global_paths, override_paths):
        """A miniature config with only the keys these tests assert."""
        def render(paths):
            return "[" + ", ".join(f'"{path}"' for path in paths) + "]"

        path = Path(directory) / "config.toml"
        path.write_text(
            "[workflow]\n"
            f"coordination_paths = {render(global_paths)}\n\n"
            f'[repositories."{KANBAN_REPOSITORY_KEY}".workflow]\n'
            f"coordination_paths = {render(override_paths)}\n",
            encoding="utf-8",
        )
        return path

    def test_the_tracked_example_loads_with_no_warnings(self):
        # Guards every assertion below: an unknown key or a rejected table would
        # warn here and leave the override silently never applying.
        self.assertEqual(self.warnings, [])

    def test_the_global_coordination_default_is_empty(self):
        self.assertEqual(
            self.raw.workflow.coordination_paths,
            frozenset(),
            "config.toml.example's global workflow.coordination_paths must stay "
            "empty: §7's classification describes Kanban and is never inferred "
            "for a consuming repository",
        )

    def test_the_kanban_override_covers_exactly_the_section_7_coordination_set(self):
        # Effective coverage over the tracked Markdown inventory rather than
        # set membership, so the `docs/coordination/` directory row and the
        # identical configured entry agree without enumerating children.
        configured = configured_coordination_paths(self.config, self.raw)
        unclassified, unconfigured = coordination_drift(
            configured, self.coordination, self.markdown
        )
        self.assertEqual(
            (unclassified, unconfigured),
            ([], []),
            "config.toml.example's coghex/kanban coordination_paths and the "
            "coordination rows of docs/agent-workflow-contract.md §7 disagree",
        )
        self.assertEqual(
            undeclared_configured_entries(configured, self.coordination),
            [],
            "config.toml.example's coghex/kanban coordination_paths carries an "
            "entry that is no §7 coordination declaration",
        )

    def test_the_directory_row_and_directory_entry_agree_without_enumeration(self):
        # The agreement requirement 9 asks for, proven against an inventory
        # holding children neither side names: one row, one entry, any number
        # of notes.
        rows = {"docs/coordination/", "docs/ui-bugs.md"}
        inventory = [
            "docs/coordination/README.md",
            "docs/coordination/scratch-note.md",
            "docs/ui-bugs.md",
        ]
        self.assertEqual(coordination_drift(rows, rows, inventory), ([], []))
        # A configuration that lost the directory reports every covered note,
        # not a stale-looking directory string.
        self.assertEqual(
            coordination_drift({"docs/ui-bugs.md"}, rows, inventory),
            ([], ["docs/coordination/README.md", "docs/coordination/scratch-note.md"]),
        )

    def test_no_configured_coordination_path_is_a_test_parsed_document(self):
        # config.toml.example's own warning above the global default: never list
        # a document a test parses, because changing one alone really can fail
        # CI. §7 already forbids it through the audit-report reason; this is the
        # same rule asserted where the drainer reads it.
        configured = configured_coordination_paths(self.config, self.raw)
        self.assertEqual(configured_test_parsed_paths(configured), [])

    def test_another_repository_inherits_the_empty_global_default(self):
        # The override must not leak: a consuming repository resolving through
        # the same file gets nothing, which is what keeps §7 Kanban-only.
        self.assertEqual(
            configured_coordination_paths(self.config, self.raw, key="someone/other"),
            set(),
        )

    def test_an_override_that_drifts_from_the_rows_is_reported(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            drifted = (self.coordination - {"docs/ui-bugs.md"}) | {"docs/design.md"}
            path = self.write_fixture(temp_dir, [], sorted(drifted))
            config, raw, _ = load_example_config(path)
            self.assertEqual(
                coordination_drift(
                    configured_coordination_paths(config, raw),
                    self.coordination,
                    self.markdown,
                ),
                (["docs/design.md"], ["docs/ui-bugs.md"]),
            )

    def test_a_test_parsed_path_added_to_the_override_is_reported(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = self.write_fixture(
                temp_dir,
                [],
                sorted(self.coordination | {"docs/design.md"}),
            )
            config, raw, _ = load_example_config(path)
            self.assertEqual(
                configured_test_parsed_paths(
                    configured_coordination_paths(config, raw)
                ),
                ["docs/design.md"],
            )

    def test_a_bundle_document_added_to_the_override_is_reported(self):
        # The directory-row half of the same check: `codex-plugin/` is
        # test-parsed, so a file beneath it is too even though its own path
        # appears in no TEST_PARSED_PATHS entry.
        with tempfile.TemporaryDirectory() as temp_dir:
            planted = "codex-plugin/plugins/kanban/skills/solve/SKILL.md"
            path = self.write_fixture(temp_dir, [], sorted(self.coordination | {planted}))
            config, raw, _ = load_example_config(path)
            self.assertEqual(
                configured_test_parsed_paths(
                    configured_coordination_paths(config, raw)
                ),
                [planted],
            )

    def test_a_configured_entry_covering_no_markdown_is_still_reported(self):
        # The fail-open gap the Codex review of PR #411 named: `src/` covers
        # no tracked Markdown, so the coverage comparison reports no drift,
        # and it overlaps no test-parsed declaration — yet the drainer reads
        # the entry over every file and would treat a src/Kanban/Domain.hs
        # advance as coordination-only. The declaration-string reconciliation
        # is what reports it.
        with tempfile.TemporaryDirectory() as temp_dir:
            path = self.write_fixture(
                temp_dir, [], sorted(self.coordination | {"src/"})
            )
            config, raw, _ = load_example_config(path)
            configured = configured_coordination_paths(config, raw)
            # The blind spots, asserted so this regression documents why the
            # exact check below exists rather than duplicating it.
            self.assertEqual(
                coordination_drift(configured, self.coordination, self.markdown),
                ([], []),
            )
            self.assertEqual(configured_test_parsed_paths(configured), [])
            self.assertEqual(
                undeclared_configured_entries(configured, self.coordination),
                ["src/"],
            )

    def test_a_configured_directory_covering_test_parsed_content_is_reported(self):
        # The reverse direction issue #409 closes: nothing covers the broad
        # entry `docs/`, but `docs/` covers `docs/design.md`, which a tracked
        # test parses — so the entry itself is reported.
        with tempfile.TemporaryDirectory() as temp_dir:
            path = self.write_fixture(
                temp_dir, [], sorted(self.coordination | {"docs/"})
            )
            config, raw, _ = load_example_config(path)
            self.assertEqual(
                configured_test_parsed_paths(
                    configured_coordination_paths(config, raw)
                ),
                ["docs/"],
            )

    def test_test_parsed_overlap_is_detected_in_both_directions(self):
        # The predicate itself, both ways and neither: a configured directory
        # covering a test-parsed file, a configured file beneath a test-parsed
        # directory, and a coordination directory overlapping nothing.
        self.assertEqual(
            configured_test_parsed_paths({"docs/"}),
            ["docs/"],
        )
        self.assertEqual(
            configured_test_parsed_paths({"claude-plugin/commands/solve.md"}),
            ["claude-plugin/commands/solve.md"],
        )
        self.assertEqual(
            configured_test_parsed_paths({"docs/coordination/", "docs/ui-bugs.md"}),
            [],
        )

    def test_a_non_empty_global_default_is_reported(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = self.write_fixture(
                temp_dir, ["docs/ui-bugs.md"], sorted(self.coordination)
            )
            _, raw, _ = load_example_config(path)
            self.assertEqual(raw.workflow.coordination_paths, frozenset({"docs/ui-bugs.md"}))
            self.assertNotEqual(raw.workflow.coordination_paths, frozenset())

    def test_the_fixture_shape_agrees_with_the_tracked_example(self):
        # Keeps the negative cases honest: a fixture the loader parsed
        # differently from config.toml.example would prove nothing about it.
        with tempfile.TemporaryDirectory() as temp_dir:
            path = self.write_fixture(temp_dir, [], sorted(self.coordination))
            config, raw, warnings = load_example_config(path)
            self.assertEqual(warnings, [])
            self.assertEqual(raw.workflow.coordination_paths, frozenset())
            self.assertEqual(
                configured_coordination_paths(config, raw),
                configured_coordination_paths(self.config, self.raw),
            )


class DocumentedBoundaryTests(unittest.TestCase):
    """§7's fail-closed default and its consuming-repository boundary are
    load-bearing prose: they are the reason an unknown document is pr-atomic
    rather than direct-master eligible, and the reason this table is never
    applied to another repository's tree."""

    def test_the_contract_states_every_declared_boundary(self):
        self.assertEqual(missing_statements(contract_text(), CONTRACT_STATEMENTS), [])

    def test_removing_a_boundary_statement_is_reported(self):
        text = normalized(contract_text())
        for key, statement in CONTRACT_STATEMENTS.items():
            with self.subTest(statement=key):
                mutated = text.replace(normalized(statement), "")
                self.assertEqual(missing_statements(mutated, CONTRACT_STATEMENTS), [key])

    def test_the_prose_coordination_set_matches_the_rows(self):
        rows = parse_classification()
        from_rows = {
            path for path, row in rows.items() if row["klass"] == "coordination"
        }
        self.assertEqual(prose_coordination_set(), from_rows)

    def test_a_prose_set_that_drifts_from_the_rows_is_reported(self):
        # Swap one coordination document's mention for a pr-atomic one. The
        # bare path literal keeps this fixture independent of where in the
        # prose list the document happens to sit.
        mutated = contract_text().replace(
            "`docs/code-health-report.md`",
            "`docs/design.md`",
        )
        rows = parse_classification()
        from_rows = {
            path for path, row in rows.items() if row["klass"] == "coordination"
        }
        self.assertNotEqual(prose_coordination_set(mutated), from_rows)

    def test_claude_md_points_contributors_at_the_classification(self):
        # Requirement 7: a contributor must be able to tell which lane a
        # document takes without reading the machine-readable rows. Case-folded
        # because these rules are stated in two files and the same clause opens
        # a sentence in one where it runs mid-sentence in the other.
        self.assertEqual(
            missing_statements(
                CLAUDE_MD_PATH.read_text(encoding="utf-8"),
                CLAUDE_MD_STATEMENTS,
                normalize=canonical,
            ),
            [],
        )

    def test_removing_the_claude_md_pointer_is_reported(self):
        text = canonical(CLAUDE_MD_PATH.read_text(encoding="utf-8"))
        for key, statement in CLAUDE_MD_STATEMENTS.items():
            with self.subTest(statement=key):
                mutated = text.replace(canonical(statement), "")
                self.assertEqual(
                    missing_statements(mutated, CLAUDE_MD_STATEMENTS, normalize=canonical),
                    [key],
                )


class FenceAnchoringTests(unittest.TestCase):
    """§4 and §7 are two machine-readable fences in one document. Each parser
    is anchored to its own heading; the §4 half of this pair lives in
    tools/test_agent_workflow_contract.py."""

    def test_the_classification_parser_is_anchored_to_its_own_section(self):
        fixture = (
            "# Contract\n\n"
            "## 4. Dependency manifest\n\n"
            "```text\n"
            "fixture-cli | executable | fixture | src/Fixture.hs | kanban | supported | no\n"
            "```\n\n"
            "## 7. Document publication classification\n\n"
            "```text\n"
            "docs/ui-bugs.md | coordination | audit-report\n"
            "```\n"
        )
        rows = parse_classification(fixture)
        self.assertEqual(
            rows,
            {
                "docs/ui-bugs.md": {
                    "path": "docs/ui-bugs.md",
                    "klass": "coordination",
                    "reasons": ["audit-report"],
                }
            },
        )

    def test_the_real_contract_yields_no_dependency_row(self):
        source = REPO_ROOT / "tools" / "test_agent_workflow_contract.py"
        spec = importlib.util.spec_from_file_location("_kanban_agent_contract", source)
        agent_contract = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(agent_contract)
        manifest_ids = {row["id"] for row in agent_contract.parse_manifest()}
        self.assertIn("gh-cli", manifest_ids)
        rows = parse_classification()
        self.assertIn("docs/design.md", rows)
        self.assertEqual(
            sorted(set(rows) & manifest_ids),
            [],
            "the §7 parser captured rows from the §4 dependency fence",
        )

    def test_a_document_without_the_section_is_reported(self):
        with self.assertRaises(AssertionError):
            parse_classification("# Contract\n\n```text\na | b | c\n```\n")


if __name__ == "__main__":
    unittest.main()
