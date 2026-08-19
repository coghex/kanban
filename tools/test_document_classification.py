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

# §7's reason vocabulary. `audit-report` is the only one that admits the
# coordination lane; the other three are the ways a document can be coupled to
# the tree tightly enough that changing it alone can break something.
REASONS = ("test-parsed", "release-document", "implementation-coupled", "audit-report")
COORDINATION_REASON = "audit-report"

# The documents a tracked test reads as data, and what reads each. Pinned
# rather than discovered: a grep for a path in a test module also hits the
# release lists and the prose comments that merely name a document, so it would
# report every doc as parsed. Correction from issue #225's canonical review:
# docs/design.md is parsed by test/Spec/UI/Keys.hs and both plugin bundles are
# parsed by their own modules, so the reason is not confined to the two
# workflow-contract documents the issue body named.
TEST_PARSED_PATHS = {
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

# The coordination documents §7 names in prose, so a contributor can place
# a known document without reading the machine-readable rows. Reconciled
# against those rows below: the prose is the human-readable answer, and it must
# not be able to drift from the one the check enforces. The count word is
# matched loosely so adding a report only updates the sentence, not this regex.
PROSE_COORDINATION_SENTENCE_RE = re.compile(
    r"The \w+ `coordination` documents are\s+(?P<body>.*?)\.\s*\*\*Every other",
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
        "A consuming repository declares its own coordination paths through the "
        "drainer configuration key workflow.coordination_paths"
    ),
    "no-inference-for-consumers": (
        "Kanban never infers a consuming repository's classes from file extension "
        "or directory"
    ),
    "component-boundary": "matched by whole path component rather than by string prefix",
    "assets-are-not-documents": "it classifies documents, not bundle assets",
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


def coordination_drift(configured, coordination_rows):
    """(configured but unclassified, classified but unconfigured). Empty on both
    sides is the only agreement between §7's rows and the example override."""
    return (
        sorted(set(configured) - set(coordination_rows)),
        sorted(set(coordination_rows) - set(configured)),
    )


def configured_test_parsed_paths(configured, declared=TEST_PARSED_PATHS):
    """Configured coordination paths a tracked test reads as data. Matched
    through row_covers() rather than by set intersection, because two of the
    declared entries are directory rows: a bundle document listed by its own
    path would slip past `in TEST_PARSED_PATHS`."""
    return sorted(path for path in configured if matching_rows(declared, path))


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

    def test_the_audit_report_reason_is_exactly_the_coordination_lane(self):
        # The two halves of §7's "this is the only reason that admits the
        # coordination lane": a coordination row cites nothing else, and no
        # pr-atomic row cites it. Without the second half the reason could
        # quietly spread to documents that must not publish directly.
        for path, row in sorted(self.rows.items()):
            if row["klass"] == "coordination":
                self.assertEqual(row["reasons"], [COORDINATION_REASON], path)
            else:
                self.assertNotIn(COORDINATION_REASON, row["reasons"], path)

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

    def test_the_kanban_override_is_exactly_the_section_7_coordination_rows(self):
        configured = configured_coordination_paths(self.config, self.raw)
        unclassified, unconfigured = coordination_drift(configured, self.coordination)
        self.assertEqual(
            (unclassified, unconfigured),
            ([], []),
            "config.toml.example's coghex/kanban coordination_paths and the "
            "coordination rows of docs/agent-workflow-contract.md §7 disagree",
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
                    configured_coordination_paths(config, raw), self.coordination
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
