"""Release-completeness check for the Cabal source distribution.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 -m unittest tools.test_source_distribution

The archive `cabal sdist all` produces is meant to be a complete Kanban
checkout: everything needed to build, test, configure, and provision the
advertised features from the unpacked archive. `cabal check` cannot see a
gap here, because a file that is not declared as a package input is simply
not a package input. So this test builds the real archive, unpacks it, and
inspects the unpacked tree.

Checking the manifest text in `kanban.cabal` would not be enough: the
declarations are globs, and whether a glob reaches a given file is a Cabal
behavior, not a property of the text. Neither would a hand-maintained list
of expected paths, which cannot see a file that was never added to it. The
expected inventory is therefore derived from the repository's own tracked
file set, so a tool, workflow asset, or document added later has to reach
the archive or fail this test.

Every tracked file gets a stated release decision, and
`test_every_tracked_file_has_a_stated_release_decision` fails when a newly
tracked file has none:

* In, as a whole tree: `app/`, `src/`, `test/`, `tools/`, `codex-plugin/`,
  `claude-plugin/`, and `docs/media/` ship every tracked file they contain.
  `docs/media/` is a tree rather than a list of files because the packaged
  `README.md` shows `docs/media/board-wide.png` through a repository-relative
  path: an asset that document names has to be in the archive or
  `test_packaged_document_links_resolve_inside_the_archive` fails, and a
  second asset added later inherits that decision instead of needing a new
  one. Its regeneration procedure ships for the same reason the other
  documents do -- a recipient holding only the unpacked tree can remake the
  image from `test/golden/`, which the archive also carries -- and is named
  in `RELEASE_DOCUMENTS` as well as covered by the tree, because that tuple
  is what `docs/agent-workflow-contract.md` §7's `release-document` reason is
  reconciled against.
* In, individually: `README.md`, `CLAUDE.md` and its `AGENTS.md` alias --
  the one session contract under the two names Claude and Codex each read
  it by -- `CONTRIBUTING.md`, the guide GitHub presents beside its issue
  and pull-request interfaces, which states how outside work is proposed,
  reviewed, and landed and links the two contracts the archive already
  carries -- `LICENSE`, `kanban.cabal`, the `config.toml.example` and
  `models.toml.example` configuration templates, the eleven user
  and workflow-contract documents under `docs/`, `cabal.project` -- that
  one because the packaged `CLAUDE.md` describes it as what applies the
  mandatory `-Werror` gate to the `cabal build all` and `cabal test all`
  runs the packaged `README.md` tells the recipient to make -- and
  `CHANGELOG.md`, whose top section is the notes for the very version the
  archive carries, so a recipient holding only the unpacked tree can tell
  what that version contains without consulting the upstream repository.
* Out: `.drain-prs.json`, which `docs/pr-drainer.md` documents as optional
  per-repository drainer configuration and which is therefore the local
  configuration requirement 2 excludes; `.gitignore`, `.github/workflows/`, and
  `.github/ISSUE_TEMPLATE/`, which only do anything in the upstream Git
  repository; and the development
  audit reports, design documents, and coordination notes
  `EXCLUDED_TRACKED_PATHS` declares — each by exact path, or whole directories
  through a trailing-slash entry such as `docs/coordination/` that covers
  every tracked descendant by whole path component — which no runtime, setup,
  test, or workflow path reads and which no packaged document links to.

Prerequisites are `cabal` on `PATH` and a Git checkout of this repository.
Neither holds inside an unpacked release -- which nonetheless carries this
file, since `tools/` ships whole, and whose own `README.md` advertises the
`unittest discover` command that collects it. That case skips with a reason
rather than erroring. Anything else -- `cabal sdist` failing, an unreadable
archive -- is a hard failure.

A skip is a pass to `unittest`, so where the prerequisites do hold this
module is not left to whole-suite discovery: `.github/workflows/ci.yml`'s
`haskell` job runs it by name, after installing the pinned toolchain, and
fails the step on a skipped or empty result. The toolchain-free `python` job
runs the rest of the suite and collects this module too, where it skips.
"""

import ast
import importlib.util
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path, PurePosixPath

REPO_ROOT = Path(__file__).resolve().parent.parent

SDIST_TIMEOUT_SECONDS = 600

# Trees that ship whole: every tracked file under them must reach the archive.
RELEASE_TREES = (
    "app",
    "claude-plugin",
    "codex-plugin",
    "docs/media",
    "src",
    "test",
    "tools",
)

# Tracked files outside those trees that ship.
RELEASE_ROOT_FILES = (
    "AGENTS.md",
    "CHANGELOG.md",
    "CLAUDE.md",
    "CONTRIBUTING.md",
    "LICENSE",
    "README.md",
    "cabal.project",
    "config.toml.example",
    "kanban.cabal",
    "models.toml.example",
)

RELEASE_DOCUMENTS = (
    "docs/README.md",
    "docs/agent-workflow-contract.md",
    "docs/bugs.md",
    "docs/design.md",
    "docs/development.md",
    "docs/document-workflow-contract.md",
    "docs/drafting-workflow-contract.md",
    "docs/issue-approval.md",
    # Also reached by the `docs/media` tree above. Named here as well because
    # this is the tuple §7's `release-document` reason is reconciled against,
    # so a media document's publication lane stays stated where the other
    # documents' are.
    "docs/media/README.md",
    "docs/pr-drainer.md",
    "docs/user-guide.md",
    "docs/workflow-setup.md",
)

# Tracked paths that deliberately do not ship. See the module docstring for
# why each one is out. An entry ending in `/` declares a whole directory:
# every tracked descendant is deliberately excluded, compared by whole path
# component through excluded_entry_covers below, so a coordination note added
# beneath `docs/coordination/` needs no entry of its own (issue #409).
EXCLUDED_TRACKED_PATHS = (
    ".drain-prs.json",
    # GitHub's new-issue templates: they populate the web UI's issue form in
    # the upstream repository and do nothing in an unpacked archive, the same
    # boundary the workflows below sit on. A trailing-slash entry so a template
    # added later inherits the decision, and so a non-Markdown file such as a
    # chooser config.yml is covered too -- §7 sees only the *.md files.
    ".github/ISSUE_TEMPLATE/",
    # CI's own harness for the drainer's systemd lifecycle: an image that boots
    # systemd, the unit that runs the check inside it, and the check itself.
    # Out for the same reason the workflows below are — it verifies the source
    # distribution rather than being part of it, and it is useless without a
    # container runtime and a GitHub Actions runner to build one on.
    ".github/systemd-lifecycle/Dockerfile",
    ".github/systemd-lifecycle/lifecycle-check.service",
    ".github/systemd-lifecycle/lifecycle_check.py",
    ".github/workflows/ci.yml",
    ".github/workflows/release.yml",
    ".github/workflows/review-gate.yml",
    ".gitignore",
    "docs/card_filter_design.md",
    "docs/claude_document_workflows_design.md",
    "docs/code-health-report.md",
    "docs/coordination/",
    "docs/document_workflow_findings.md",
    "docs/drainer-bugs.md",
    "docs/issue_approval_queue_design.md",
    "docs/issue_search_design.md",
    "docs/linux_portability_design.md",
    "docs/managed_paths_design.md",
    "docs/model_settings_design.md",
    "docs/multi_repo_boards_design.md",
    "docs/pipeline-hardening.md",
    "docs/product_readiness_findings.md",
    "docs/project_review_386-361.md",
    "docs/public_release_design.md",
    "docs/ui-bugs.md",
    "docs/usage_awareness_design.md",
    "docs/workflow_audit_findings.md",
    "docs/workflow_command_vendoring_design.md",
)

# The files each provider's `plugin marketplace add` reads. They are the only
# tracked bundle files under dot-prefixed directories -- the one glob-semantics
# detail whose silent change would strand both bundles while every other bundle
# file still shipped -- so they are asserted by exact name.
PROVIDER_MANIFESTS = (
    "claude-plugin/.claude-plugin/marketplace.json",
    "claude-plugin/plugins/kanban/.claude-plugin/plugin.json",
    "codex-plugin/.agents/plugins/marketplace.json",
    "codex-plugin/plugins/kanban/.codex-plugin/plugin.json",
)

# Issue #370's vendored document mechanism, asserted by exact name rather than
# left to the whole-tree rule above. A workflow that ships without the modules
# it invokes is inert wherever it installs -- the defect that issue reports --
# and "the tree ships" is the guarantee that was already true while these files
# existed only under tools/. Naming them here is what makes an unpacked release
# prove it carries them.
BUNDLED_MECHANISM_MODULES = (
    "claude-plugin/plugins/kanban/scripts/kanban_config.py",
    "claude-plugin/plugins/kanban/scripts/publish_coordination_doc.py",
    "claude-plugin/plugins/kanban/scripts/tracker_transaction.py",
    "codex-plugin/plugins/kanban/skills/process-report/scripts/kanban_config.py",
    "codex-plugin/plugins/kanban/skills/process-report/scripts/publish_coordination_doc.py",
    "codex-plugin/plugins/kanban/skills/process-report/scripts/tracker_transaction.py",
)

# What each `tools/setup_workflows.py` component installs from. Keyed to that
# module's own COMPONENTS tuple, so a new component cannot land without a
# stated source bundle.
COMPONENT_SOURCES = {
    "issue-review": (
        "tools/approve_issues.py",
        "tools/install_issue_review.py",
        "tools/kanban_config.py",
    ),
    "legacy-launcher": (
        "tools/approve_issues.py",
        "tools/install_issue_review.py",
    ),
    "codex-plugin": (
        "codex-plugin/.agents/plugins/marketplace.json",
        "codex-plugin/plugins/kanban/.codex-plugin/plugin.json",
    ),
    "claude-plugin": (
        "claude-plugin/.claude-plugin/marketplace.json",
        "claude-plugin/plugins/kanban/.claude-plugin/plugin.json",
    ),
}

FORBIDDEN_DIRECTORY_NAMES = frozenset(
    {".git", "__pycache__", "dist-newstyle", "node_modules"}
)

FORBIDDEN_SUFFIXES = (".pyc", ".pyo", ".log", ".orig", ".rej")

# [text](target) and [text](target "title"), excluding image-only syntax noise.
MARKDOWN_LINK = re.compile(r"\[[^\]\n]*\]\(\s*([^)\s]+)(?:\s+\"[^\"]*\")?\s*\)")

# Paths into the packaged trees named as literal text by the documentation --
# `python3 tools/setup_workflows.py`, and so on.
DOCUMENTED_TREE_PATH = re.compile(
    r"\b((?:tools|codex-plugin|claude-plugin)/[\w./-]+\.(?:py|json|md))"
)


def excluded_entry_covers(entry: str, path: str) -> bool:
    """Whether one EXCLUDED_TRACKED_PATHS entry covers `path`.

    An entry ending in `/` covers every descendant of that directory, compared
    by whole path component — `docs/coordination/` covers
    `docs/coordination/scratch-note.md` and never a sibling such as
    `docs/coordination-old/scratch-note.md`. Any other entry names one file
    exactly; nothing here is a glob or a string prefix. The same
    whole-component rule §7's directory rows and `workflow.coordination_paths`
    use, restated over this module's own subject: tracked files, whatever
    their extension.
    """
    if not entry.endswith("/"):
        return entry == path
    prefix = PurePosixPath(entry.rstrip("/")).parts
    return bool(prefix) and PurePosixPath(path).parts[: len(prefix)] == prefix


def expanded_exclusions(tracked, entries=EXCLUDED_TRACKED_PATHS):
    """(the tracked files the entries deliberately exclude, the directory
    entries covering no tracked file).

    A directory entry expands over its tracked descendants rather than being
    treated as a stale file, and a declared directory that exists but covers
    no tracked content is reported: an exclusion excluding nothing is a stale
    declaration either way.
    """
    files, uncovered = set(), []
    for entry in entries:
        if entry.endswith("/"):
            covered = {path for path in tracked if excluded_entry_covers(entry, path)}
            if not covered:
                uncovered.append(entry)
            files |= covered
        else:
            files.add(entry)
    return files, uncovered


def _run(args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, **kwargs)


def _prerequisite_gap():
    """Why this test cannot run here, or None when it can."""
    if shutil.which("cabal") is None:
        return (
            "cabal is not on PATH, so the source distribution cannot be built; "
            "this check runs in a Git checkout with the Haskell toolchain "
            "installed, not from an unpacked release."
        )
    if shutil.which("git") is None:
        return (
            "git is not on PATH, so the tracked file set that defines the "
            "expected archive inventory cannot be read."
        )
    toplevel = _run(["git", "-C", str(REPO_ROOT), "rev-parse", "--show-toplevel"])
    if toplevel.returncode != 0:
        return (
            f"{REPO_ROOT} is not a Git checkout, so the tracked file set that "
            "defines the expected archive inventory cannot be read."
        )
    if Path(toplevel.stdout.strip()).resolve() != REPO_ROOT:
        # An unpacked release extracted inside some other repository: Git
        # answers, but about a working tree that is not this one.
        return (
            f"{REPO_ROOT} is not the root of its Git checkout, so the tracked "
            "file set that defines the expected archive inventory cannot be read."
        )
    return None


def _contract_alias():
    """tools/test_repository_contract_alias.py's check, loaded from the module
    itself rather than reimplemented here, so the archive is held to exactly
    the equality the checkout is. Loaded by path under a private name for the
    reason tools/test_document_classification.py loads this module that way:
    discovery may have imported it as a bare top-level name or inside a
    `tools.` namespace package, and the copy loaded here must not shadow the
    discovered one."""
    source = REPO_ROOT / "tools" / "test_repository_contract_alias.py"
    spec = importlib.util.spec_from_file_location("_kanban_contract_alias", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _tracked_files(*paths):
    proc = _run(["git", "-C", str(REPO_ROOT), "ls-files", "-z", "--", *paths])
    if proc.returncode != 0:
        raise AssertionError(f"git ls-files failed:\n{proc.stderr}")
    return {entry for entry in proc.stdout.split("\0") if entry}


class ExclusionDeclarationTests(unittest.TestCase):
    """The coverage semantics the two archive checks above decide with,
    exercised without building an archive so they run wherever the Python
    suite does — the sdist assertions themselves skip without `cabal`, and a
    skip is a pass to `unittest`."""

    def test_a_directory_entry_covers_descendants_by_whole_component(self):
        entry = "docs/coordination/"
        for covered in (
            "docs/coordination/scratch-note.md",
            "docs/coordination/deep/nested.md",
            "docs/coordination/asset.png",
        ):
            self.assertTrue(excluded_entry_covers(entry, covered), covered)
        for stray in (
            "docs/coordination-old/scratch-note.md",
            "docs/coordination.md",
            "docs/design.md",
        ):
            self.assertFalse(excluded_entry_covers(entry, stray), stray)

    def test_a_file_entry_covers_exactly_itself(self):
        self.assertTrue(excluded_entry_covers("docs/ui-bugs.md", "docs/ui-bugs.md"))
        self.assertFalse(excluded_entry_covers("docs/ui-bugs.md", "docs/ui-bugs2.md"))
        self.assertFalse(excluded_entry_covers("docs/ui-bugs.md", "docs/ui-bugs.md/x"))

    def test_a_directory_entry_expands_over_its_tracked_descendants(self):
        tracked = {
            "docs/coordination/README.md",
            "docs/coordination/scratch-note.md",
            "docs/coordination-old/kept.md",
            "docs/ui-bugs.md",
        }
        files, uncovered = expanded_exclusions(
            tracked, entries=("docs/coordination/", "docs/ui-bugs.md")
        )
        self.assertEqual(uncovered, [])
        self.assertEqual(
            files,
            {
                "docs/coordination/README.md",
                "docs/coordination/scratch-note.md",
                "docs/ui-bugs.md",
            },
        )

    def test_a_directory_entry_covering_nothing_is_reported(self):
        files, uncovered = expanded_exclusions(
            {"docs/ui-bugs.md"}, entries=("docs/coordination/", "docs/ui-bugs.md")
        )
        self.assertEqual(uncovered, ["docs/coordination/"])
        self.assertEqual(files, {"docs/ui-bugs.md"})

    def test_an_archived_descendant_of_an_excluded_directory_is_detected(self):
        # The absence check's predicate, driven with a planted archive
        # inventory: the descendant was never listed by name, and coverage
        # still finds it.
        archived = {
            "docs/coordination/scratch-note.md",
            "docs/coordination-old/kept.md",
            "docs/design.md",
        }
        present = sorted(
            path
            for path in archived
            if any(
                excluded_entry_covers(entry, path)
                for entry in ("docs/coordination/", ".drain-prs.json")
            )
        )
        self.assertEqual(present, ["docs/coordination/scratch-note.md"])

    def test_the_live_declarations_cover_tracked_content_when_git_answers(self):
        # The live tuple, held to the same rule wherever a Git checkout is
        # available — which the Python-only CI job is, unlike `cabal`.
        if shutil.which("git") is None:  # pragma: no cover - environment guard
            self.skipTest("git is not on PATH")
        toplevel = _run(["git", "-C", str(REPO_ROOT), "rev-parse", "--show-toplevel"])
        if toplevel.returncode != 0:
            self.skipTest(f"{REPO_ROOT} is not a Git checkout")
        _, uncovered = expanded_exclusions(_tracked_files())
        self.assertEqual(uncovered, [])


class SourceDistributionTest(unittest.TestCase):
    """Assertions against one real, unpacked `cabal sdist all` archive."""

    @classmethod
    def setUpClass(cls):
        gap = _prerequisite_gap()
        if gap is not None:
            raise unittest.SkipTest(gap)

        workspace = tempfile.TemporaryDirectory(prefix="kanban-sdist-")
        cls.addClassCleanup(workspace.cleanup)
        root = Path(workspace.name)
        output = root / "sdist"
        # Both the build directory and the output land outside the checkout,
        # so the run neither reads nor leaves state in the working tree.
        builddir = root / "dist"

        proc = _run(
            [
                "cabal",
                "sdist",
                "all",
                "--builddir",
                str(builddir),
                "--output-directory",
                str(output),
            ],
            cwd=str(REPO_ROOT),
            timeout=SDIST_TIMEOUT_SECONDS,
        )
        if proc.returncode != 0:
            raise AssertionError(
                "cabal sdist all failed with exit code "
                f"{proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            )

        archives = sorted(output.glob("*.tar.gz"))
        if len(archives) != 1:
            raise AssertionError(
                f"expected exactly one source archive in {output}, found: "
                f"{[archive.name for archive in archives]}"
            )
        cls.archive = archives[0]

        unpacked = root / "unpacked"
        with tarfile.open(cls.archive) as tar:
            try:
                tar.extractall(unpacked, filter="data")
            except TypeError:  # Python without the extraction filter.
                tar.extractall(unpacked)

        entries = sorted(unpacked.iterdir())
        if len(entries) != 1 or not entries[0].is_dir():
            raise AssertionError(
                f"expected the archive to unpack to a single directory, found: "
                f"{[entry.name for entry in entries]}"
            )
        # Resolved, so that the containment check below compares like with
        # like on platforms whose temporary directory is itself a symlink.
        cls.unpacked_root = entries[0].resolve()

        # Everything below reads the unpacked tree, not the tar member list,
        # so what is asserted is what a recipient actually gets on disk.
        cls.archive_files = set()
        cls.archive_directories = set()
        for dirpath, dirnames, filenames in os.walk(cls.unpacked_root):
            here = Path(dirpath)
            for name in dirnames:
                cls.archive_directories.add(
                    (here / name).relative_to(cls.unpacked_root).as_posix()
                )
            for name in filenames:
                cls.archive_files.add(
                    (here / name).relative_to(cls.unpacked_root).as_posix()
                )

    def assert_present(self, paths, why):
        missing = sorted(set(paths) - self.archive_files)
        self.assertEqual(
            [],
            missing,
            f"{why}\nMissing from {self.archive.name}: {missing}\n"
            "Declare them in kanban.cabal's extra-source-files or "
            "extra-doc-files.",
        )

    def test_every_tracked_file_has_a_stated_release_decision(self):
        tracked = _tracked_files()
        excluded, uncovered = expanded_exclusions(tracked)
        self.assertEqual(
            [],
            uncovered,
            "These EXCLUDED_TRACKED_PATHS directory entries cover no tracked "
            "file. A declared directory must exist and cover tracked content; "
            "remove the stale declarations.",
        )
        classified = (
            _tracked_files(*RELEASE_TREES)
            | set(RELEASE_ROOT_FILES)
            | set(RELEASE_DOCUMENTS)
            | excluded
        )

        self.assertEqual(
            [],
            sorted(tracked - classified),
            "These tracked files are neither declared as release assets nor "
            "listed as deliberate exclusions in this module. Decide whether "
            "each belongs in the source distribution and record that decision "
            "in RELEASE_ROOT_FILES, RELEASE_DOCUMENTS, or "
            "EXCLUDED_TRACKED_PATHS.",
        )
        self.assertEqual(
            [],
            sorted(classified - tracked),
            "These paths are named by this module but are no longer tracked. "
            "Remove the stale entries.",
        )

    def test_release_trees_ship_every_tracked_file(self):
        self.assert_present(
            _tracked_files(*RELEASE_TREES),
            "Every tracked file under "
            f"{', '.join(RELEASE_TREES)} must reach the source distribution.",
        )

    def test_release_root_files_and_documents_ship(self):
        self.assert_present(
            RELEASE_ROOT_FILES + RELEASE_DOCUMENTS,
            "The packaged README, session instructions, license, example "
            "configuration, project file, and every user or workflow-contract "
            "document must reach the source distribution.",
        )

    def test_the_packaged_contract_alias_resolves_to_the_contract(self):
        # Carrying both names is not the guarantee. A recipient's Codex session
        # reads AGENTS.md and nothing else, so the archive has to hold the
        # contract's exact bytes under that name -- whether the archiver kept
        # the symlink or dereferenced it into a copy.
        alias = _contract_alias()
        self.assert_present(
            (alias.ALIAS_NAME, alias.CONTRACT_NAME),
            "The source distribution must carry the session contract under "
            "both the name Claude reads and the name Codex reads.",
        )
        self.assertIsNone(
            alias.alias_gap(self.unpacked_root),
            f"{alias.ALIAS_NAME} reached {self.archive.name} without resolving "
            f"to {alias.CONTRACT_NAME}'s content, so an unpacked release hands "
            "a Codex session a contract that is not the one it ships.",
        )

    def test_the_bundled_document_mechanism_ships_with_both_bundles(self):
        self.assert_present(
            BUNDLED_MECHANISM_MODULES,
            "Both provider bundles must carry the publication, tracker "
            "transaction, and configuration modules their document workflows "
            "invoke; a bundle that ships the workflows without them installs "
            "a command that fails closed in every repository.",
        )

    def test_provider_bundle_manifests_ship(self):
        self.assert_present(
            PROVIDER_MANIFESTS,
            "Both provider bundles must carry the manifests "
            "`plugin marketplace add` reads.",
        )

    def test_deliberately_excluded_tracked_files_are_absent(self):
        # Coverage rather than set membership, so an archived descendant of an
        # excluded directory is detected, not only an exact listed path.
        present = sorted(
            path
            for path in self.archive_files
            if any(
                excluded_entry_covers(entry, path)
                for entry in EXCLUDED_TRACKED_PATHS
            )
        )
        self.assertEqual(
            [],
            present,
            "These tracked paths are documented as deliberate exclusions but "
            "reached the archive. Either narrow the kanban.cabal declaration "
            "or move them to a release list here.",
        )

    def test_archive_carries_nothing_untracked(self):
        stray = sorted(self.archive_files - _tracked_files())
        self.assertEqual(
            [],
            stray,
            "The source distribution carries files that are not tracked in "
            "the repository. Generated output, local state, and scratch files "
            "must not be declared as package inputs.",
        )

    def test_generated_artifacts_are_absent(self):
        polluted = sorted(
            path
            for path in self.archive_directories
            if set(Path(path).parts) & FORBIDDEN_DIRECTORY_NAMES
        )
        self.assertEqual(
            [], polluted, "The unpacked archive contains generated directories."
        )

        compiled = sorted(
            path
            for path in self.archive_files
            if path.endswith(FORBIDDEN_SUFFIXES)
            or set(Path(path).parts[:-1]) & FORBIDDEN_DIRECTORY_NAMES
        )
        self.assertEqual(
            [],
            compiled,
            "The unpacked archive contains compiled, log, or merge-artifact "
            "files.",
        )

    def test_packaged_document_links_resolve_inside_the_archive(self):
        broken = []
        for relative in sorted(self.archive_files):
            if not relative.endswith(".md"):
                continue
            document = self.unpacked_root / relative
            for target in MARKDOWN_LINK.findall(
                document.read_text(encoding="utf-8", errors="replace")
            ):
                if ":" in target.split("/", 1)[0] or target.startswith("#"):
                    continue  # Absolute URL or same-document anchor.
                path = target.split("#", 1)[0]
                if not path:
                    continue
                resolved = (document.parent / path).resolve()
                inside = (
                    resolved == self.unpacked_root
                    or self.unpacked_root in resolved.parents
                )
                if not inside or not resolved.exists():
                    broken.append(f"{relative} -> {target}")
        self.assertEqual(
            [],
            broken,
            "Every repository-relative link in a packaged document must "
            "resolve inside the unpacked archive.",
        )

    def test_documented_tree_paths_exist_in_the_archive(self):
        missing = []
        for relative in sorted(self.archive_files):
            if not relative.endswith(".md"):
                continue
            document = self.unpacked_root / relative
            for named in DOCUMENTED_TREE_PATH.findall(
                document.read_text(encoding="utf-8", errors="replace")
            ):
                if named not in self.archive_files:
                    missing.append(f"{relative} names {named}")
        self.assertEqual(
            [],
            sorted(set(missing)),
            "Every setup, installer, or bundle path named by a packaged "
            "document must exist in the unpacked archive.",
        )

    def test_setup_workflow_components_have_their_sources(self):
        setup = self.unpacked_root / "tools" / "setup_workflows.py"
        self.assertIn(
            "tools/setup_workflows.py",
            self.archive_files,
            "The archive must carry the setup orchestrator itself.",
        )

        declared = None
        for node in ast.parse(setup.read_text(encoding="utf-8")).body:
            targets = getattr(node, "targets", [])
            if isinstance(node, ast.Assign) and any(
                isinstance(target, ast.Name) and target.id == "COMPONENTS"
                for target in targets
            ):
                declared = tuple(ast.literal_eval(node.value))
        self.assertIsNotNone(
            declared, "tools/setup_workflows.py no longer declares COMPONENTS."
        )
        self.assertEqual(
            sorted(declared),
            sorted(COMPONENT_SOURCES),
            "COMPONENT_SOURCES must name the source bundle of every component "
            "tools/setup_workflows.py can install.",
        )

        for component in sorted(COMPONENT_SOURCES):
            with self.subTest(component=component):
                self.assert_present(
                    COMPONENT_SOURCES[component],
                    f"Installing the {component} component from an unpacked "
                    "release needs its tracked source bundle.",
                )


if __name__ == "__main__":
    unittest.main()
