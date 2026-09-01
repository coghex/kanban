"""Release-completeness and package-boundary checks for the Cabal source
distribution.

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
  carries -- `SECURITY.md`, that guide's disclosure-side companion: a
  recipient holding only the unpacked tree holds the very code the policy
  scopes -- the caches, the optional persistent jobs, the managed reviewer
  link -- so the private reporting route and that scope have to travel with
  it rather than being reachable only from the upstream repository page --
  `CODE_OF_CONDUCT.md` and `SUPPORT.md`, the rest of that public baseline: the
  conduct standard governing the project spaces the packaged `CONTRIBUTING.md`
  sends a contributor into, which links it rather than restating it, and the
  statement of what ordinary support promises -- the latest release only, best
  effort -- and which of the three routes a bug, a vulnerability, and a conduct
  concern each take. A recipient holding only the unpacked tree therefore holds
  the standard the contribution guide binds them to and the answer to where a
  report goes, rather than reaching either one only from upstream --
  `LICENSE`, `kanban.cabal`, the `config.toml.example` and
  `models.toml.example` configuration templates, the twelve user
  and workflow-contract documents under `docs/`,
  `.github/pull_request_template.md` -- the body GitHub pre-fills for a new
  pull request, and the composition-time companion to the packaged
  `CONTRIBUTING.md`: a recipient following that guide from an agreed issue to
  a pull request reads this file for what the body has to satisfy. The issue
  templates excluded below were classified the other way, so each `.github/`
  document states its own decision rather than inheriting one from the
  directory --
  `cabal.project` -- that one because the packaged `CLAUDE.md` describes it
  as what applies the mandatory `-Werror` gate to the `cabal build all` and
  `cabal test all` runs the packaged `README.md` tells the recipient to
  make -- and
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

The same unpacked archive settles a second question: what the package
publishes. Kanban's supported interfaces are the executable and its CLI, the
documented configuration, the on-disk compatibility surface, the installers,
and the workflow contracts -- not an importable `Kanban.*` library, whose
modules are implementation seams that get split and respelled whenever the code
wants it. So the package publishes no library, and "The package boundary"
section of `SourceDistributionTest` holds it there. Those checks read Cabal,
not `kanban.cabal`: they ask the real unpacked archive for the library
components Cabal elaborates for it, and then ask, once per library, whether a
separate consumer package can name it. A stanza rewritten to restore a public
library would sail past a text check watching for the old spelling; it cannot
sail past Cabal's own answer.

Prerequisites are `cabal` on `PATH` and a Git checkout of this repository.
The boundary checks need one thing more -- a `cabal` that can resolve the
unpacked package's own build plan, which means an index and a compiler inside
its `base` bound -- and skip where they cannot get it, since a refusal to
resolve is then the environment's rather than the boundary's. Neither holds
inside an unpacked release -- which nonetheless carries this
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
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path, PurePosixPath
from types import SimpleNamespace

REPO_ROOT = Path(__file__).resolve().parent.parent

SDIST_TIMEOUT_SECONDS = 600

# A package of its own, used to ask the one question a `.cabal` stanza cannot
# answer: whether something *outside* this package can name a library of it.
# `{dependencies}` is the `build-depends` entry under test.
BOUNDARY_PROBE_PACKAGE = """cabal-version: 3.0
name: kanban-boundary-probe
version: 0
build-type: Simple

library
  default-language: Haskell2010
  hs-source-dirs: .
  exposed-modules: KanbanBoundaryProbe
  build-depends: {dependencies}
"""

# The Cabal solver's own wording for the two ways this package can refuse an
# outside `build-depends` entry. Asserting the exact reason is what keeps an
# unrelated index, network, or solver failure from reading as proof of privacy:
# any other failure means the probe never reached the question. That the wording
# is the pinned toolchain's is `tools/test_toolchain_parity.py`'s business; a
# `cabal` upgrade that rephrases these fails here, loudly, rather than passing
# on a refusal it stopped understanding.
NO_SUCH_LIBRARY_REASON = (
    "requires library from kanban, but the component does not exist"
)
PRIVATE_LIBRARY_REASON = (
    "requires library '{name}' from kanban, but the component is private"
)

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
    "CODE_OF_CONDUCT.md",
    "CONTRIBUTING.md",
    "LICENSE",
    "README.md",
    "SECURITY.md",
    "SUPPORT.md",
    "cabal.project",
    "config.toml.example",
    "kanban.cabal",
    "models.toml.example",
)

RELEASE_DOCUMENTS = (
    ".github/pull_request_template.md",
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
    "docs/releasing.md",
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
    "docs/gh_record_authority_design.md",
    "docs/issue_approval_queue_design.md",
    "docs/issue_search_design.md",
    "docs/linux_portability_design.md",
    "docs/managed_paths_design.md",
    "docs/mission_runner_design.md",
    "docs/model_settings_design.md",
    "docs/multi_repo_boards_design.md",
    "docs/overlay_focus_fullscreen_design.md",
    "docs/pipeline-hardening.md",
    "docs/product_readiness_findings.md",
    "docs/project_review_183-170.md",
    "docs/project_review_195-185.md",
    "docs/project_review_218-196.md",
    "docs/project_review_244-219.md",
    "docs/project_review_271-251.md",
    "docs/project_review_297-272.md",
    "docs/project_review_314-299.md",
    "docs/project_review_342-317.md",
    "docs/project_review_386-361.md",
    "docs/project_review_398-353.md",
    "docs/project_review_442-411.md",
    "docs/project_review_456-446.md",
    "docs/project_review_463-455.md",
    "docs/project_review_466-399.md",
    "docs/project_review_516-498.md",
    "docs/project_review_533-517.md",
    "docs/public_release_design.md",
    "docs/release_maintenance_design.md",
    "docs/superagent_design.md",
    "docs/text_selection_design.md",
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
# The model-roster reader joins them for BOTH bundles since issue #572: each
# coordinator loads a copy from beside itself to read the roster's loaded
# provider set, which is what decides who reviews a pull request. What the two
# do with it still differs -- the Claude copy resolves the `pr_review` cells
# and pins them, the Codex copy resolves no cell and passes no model or effort
# (D-2) -- but a release that shipped either coordinator without its reader
# would install a workflow that cannot route at all.
# Issue #574's janitor census joins them on the same terms: it is the janitor
# workflow's whole read side, and it loads a configuration module from beside
# itself the way the publication module does, so a bundle that shipped the
# census without that sibling would resolve no drainer at all. The Codex bundle
# needs its own second copy of `kanban_config.py` because it has no shared
# scripts root -- each skill carries what it loads.
# Eleven modules: five in the Claude bundle and six in the Codex bundle.
BUNDLED_MECHANISM_MODULES = (
    "claude-plugin/plugins/kanban/scripts/census.py",
    "claude-plugin/plugins/kanban/scripts/kanban_config.py",
    "claude-plugin/plugins/kanban/scripts/kanban_models.py",
    "claude-plugin/plugins/kanban/scripts/publish_coordination_doc.py",
    "claude-plugin/plugins/kanban/scripts/tracker_transaction.py",
    "codex-plugin/plugins/kanban/skills/janitor/scripts/census.py",
    "codex-plugin/plugins/kanban/skills/janitor/scripts/kanban_config.py",
    "codex-plugin/plugins/kanban/skills/pr-review/scripts/kanban_models.py",
    "codex-plugin/plugins/kanban/skills/process-report/scripts/kanban_config.py",
    "codex-plugin/plugins/kanban/skills/process-report/scripts/publish_coordination_doc.py",
    "codex-plugin/plugins/kanban/skills/process-report/scripts/tracker_transaction.py",
)

# Issue #548's project-review cursor mechanism, asserted for the same reason
# and against the same failure: the workflow's resume contract is that helper,
# so a release that shipped the command without it would install a sweep that
# refuses to start. One copy per bundle, each beside the command that calls it.
BUNDLED_CURSOR_MODULES = (
    "claude-plugin/plugins/kanban/scripts/project_review_cursor.py",
    "codex-plugin/plugins/kanban/skills/project-review/scripts/project_review_cursor.py",
)

# What each `tools/setup_workflows.py` component installs from. Keyed to that
# module's own COMPONENTS tuple, so a new component cannot land without a
# stated source bundle.
COMPONENT_SOURCES = {
    "issue-review": (
        "tools/approve_issues.py",
        "tools/install_issue_review.py",
        "tools/kanban_config.py",
        "tools/kanban_models.py",
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

# A `tools/` module named the way a document tells the reader to run it --
# `python3 -m unittest tools.test_source_distribution`. The dotted form is a
# path into the packaged tree that the slash-shaped pattern above cannot see,
# and `docs/releasing.md` (issue #539) joins `docs/development.md` and
# `docs/media/README.md` in advertising modules that way, so a document naming
# a module the archive does not carry hands its reader a command that cannot
# run. Only `tools.`: it is the one package an unpacked archive can import
# from its own root.
DOCUMENTED_TEST_MODULE = re.compile(r"-m\s+unittest\s+(tools\.[\w.]+)")


def documented_module_paths(text):
    """The archive-relative source files a document's `unittest` invocations
    name, as paths. `tools.test_x` is `tools/test_x.py`; a dotted subpackage
    resolves the same way."""
    return sorted(
        {
            module.replace(".", "/") + ".py"
            for module in DOCUMENTED_TEST_MODULE.findall(text)
        }
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


# ---- Executing the packaged setup paths -------------------------------------
#
# The archive carries every advertised setup command. Whether it *contains*
# them is what the inventory checks above answer; whether they *run* there is a
# different question, and only running them answers it. So the cases at the end
# of this module drive the unpacked tree's own scripts as subprocesses, against
# a temporary home and a temporary target checkout.
#
# Subprocesses rather than imports, deliberately. The archive's `tools/` carries
# modules with the same names as this checkout's -- `kanban_config`,
# `service_manager`, `drain_prs_service` -- so importing them into this process
# would either collide in `sys.modules` with the ones already loaded or, worse,
# silently answer with the checkout's copy while the test believed it was
# reading the archive's. Everything is therefore steered through the
# environment and `PATH`, which is also how a real recipient's shell reaches
# them.

# One scriptable stand-in, used for every faked executable. It records the
# request -- arguments *and* working directory, because for a provider command
# the directory is part of the request -- and answers from a table read out of
# the environment. A table entry matches when every word it names appears
# anywhere in the arguments, which is what lets one entry answer both
# `plugin marketplace list --json` and a provider that spells the same query
# differently; entries are tried in order, so a narrower one is listed first.
_SHIM = r"""#!/usr/bin/env python3
import json
import os
import sys

binary = {binary!r}
argv = sys.argv[1:]
with open(os.environ["ARCHIVE_SETUP_LOG"], "a", encoding="utf-8") as handle:
    handle.write(
        json.dumps({{"binary": binary, "args": argv, "cwd": os.getcwd()}}) + "\n"
    )
for entry in json.loads(os.environ["ARCHIVE_SETUP_RESPONSES"]):
    if entry["binary"] != binary:
        continue
    match = entry["match"]
    if all(word in argv for word in match):
        sys.stdout.write(entry.get("stdout", ""))
        sys.exit(entry.get("exit", 0))
sys.exit({default_exit})
"""

# `git` is not faked. The target checkout is a real repository and the
# installers really have to read it; what this wrapper adds is a record of
# every invocation, so a case can assert which tree each one was about.
_GIT_WRAPPER = r"""#!/usr/bin/env python3
import json
import os
import subprocess
import sys

argv = sys.argv[1:]
with open(os.environ["ARCHIVE_SETUP_LOG"], "a", encoding="utf-8") as handle:
    handle.write(
        json.dumps({"binary": "git", "args": argv, "cwd": os.getcwd()}) + "\n"
    )
sys.exit(subprocess.run([os.environ["ARCHIVE_SETUP_REAL_GIT"], *argv]).returncode)
"""

# What each faked executable answers. The provider tables describe a machine
# with nothing installed; the service-manager tables describe a manager holding
# no job of ours, which is the state a first install has to be able to see.
_SHIM_RESPONSES = [
    {"binary": "codex", "match": ["marketplace", "list"], "stdout": "[]"},
    {"binary": "codex", "match": ["plugin", "list", "--json"], "stdout": "[]"},
    {"binary": "claude", "match": ["marketplace", "list"], "stdout": "[]"},
    {"binary": "claude", "match": ["plugin", "list", "--json"], "stdout": "[]"},
    # launchd: no job of ours is loaded, and loading one succeeds.
    {"binary": "launchctl", "match": ["print"], "exit": 1},
    # systemd: the user manager is reachable, and knows no unit of ours.
    {
        "binary": "systemctl",
        "match": ["show", "--property", "Version"],
        "stdout": "254\n",
    },
]

_ARTIFACT_NAMES = {"__pycache__"}
_ARTIFACT_SUFFIXES = (".pyc", ".pyo")


def _tree_snapshot(root):
    """Every file under `root` with its exact content, and every symlink with
    its exact target, minus what the interpreter writes for any Python program
    it runs. A `.pyc` beside a module says nothing about whether the tool that
    imported it wrote anything."""
    snapshot = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if set(relative.parts) & _ARTIFACT_NAMES or path.name.endswith(
            _ARTIFACT_SUFFIXES
        ):
            continue
        if path.is_file() and not path.is_symlink():
            snapshot[relative.as_posix()] = path.read_bytes()
        elif path.is_symlink():
            snapshot[relative.as_posix()] = os.readlink(path)
    return snapshot


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

    def test_a_documented_unittest_invocation_resolves_to_a_module_path(self):
        self.assertEqual(
            documented_module_paths(
                "Run `python3 -m unittest tools.test_source_distribution`, or\n"
                "python3 -m  unittest tools.sub.test_thing\n"
            ),
            ["tools/sub/test_thing.py", "tools/test_source_distribution.py"],
        )

    def test_a_discover_invocation_names_no_module(self):
        # The negative control for the pattern above: `discover -s tools` names
        # a directory to search rather than a module to import, so reading it
        # as a module path would report a file that was never meant to exist.
        self.assertEqual(
            documented_module_paths(
                "python3 -m unittest discover -s tools -p 'test_*.py'"
            ),
            [],
        )

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
        # The package-boundary checks build their consumer packages in here, so
        # those too are removed with the workspace rather than left behind.
        cls.workspace_root = root
        # Memoized by the boundary helpers below; each is one `cabal` run, and
        # every boundary test wants the same answer.
        cls.elaborated_components = None
        cls.plan_gap = None
        cls.probe_harness_checked = False
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
            "invoke, each bundle its review coordinator's model roster "
            "reader, and each the janitor census with the configuration "
            "module beside it; a bundle that ships the workflows without them "
            "installs a command that fails closed in every repository.",
        )

    def test_the_bundled_project_review_cursor_ships_with_both_bundles(self):
        self.assert_present(
            BUNDLED_CURSOR_MODULES,
            "Both provider bundles must carry the project-review cursor "
            "helper their sweep resolves before its first read; a bundle that "
            "ships the command without it installs a sweep that stops at its "
            "own helper lookup in every repository.",
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

    def test_documented_test_modules_exist_in_the_archive(self):
        missing = []
        for relative in sorted(self.archive_files):
            if not relative.endswith(".md"):
                continue
            document = self.unpacked_root / relative
            for named in documented_module_paths(
                document.read_text(encoding="utf-8", errors="replace")
            ):
                if named not in self.archive_files:
                    missing.append(f"{relative} names {named}")
        self.assertEqual(
            [],
            sorted(set(missing)),
            "Every `python3 -m unittest tools.<module>` a packaged document "
            "advertises must resolve to a module in the unpacked archive.",
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

    # ---- Executing the packaged setup paths ------------------------------

    def packaged_setup_workspace(self):
        """A machine a release recipient could be: a temporary home, a
        temporary target checkout, and a `PATH` holding only stand-ins.

        Both service managers' executables are supplied rather than one,
        because which of them this host is managed by is the code under test's
        own question -- `service_manager._probe_service_manager` asks
        `sys.platform` and `shutil.which` -- and a fixture that answered it
        would be testing its own guess. Neither stand-in touches real launchd
        or systemd state: they record what they were asked and answer from a
        table.
        """
        workspace = tempfile.TemporaryDirectory(prefix="kanban-archive-setup-")
        self.addCleanup(workspace.cleanup)
        root = Path(workspace.name).resolve()
        home = root / "home"
        (home / "work").mkdir(parents=True)
        binaries = root / "bin"
        binaries.mkdir()
        log = root / "commands.jsonl"

        real_git = shutil.which("git")
        self.assertIsNotNone(real_git, "the prerequisite check guarantees git")
        for name, default_exit in (
            ("codex", 0),
            ("claude", 0),
            ("launchctl", 0),
            ("systemctl", 0),
        ):
            shim = binaries / name
            shim.write_text(
                _SHIM.format(binary=name, default_exit=default_exit),
                encoding="utf-8",
            )
            os.chmod(shim, 0o755)
        wrapper = binaries / "git"
        wrapper.write_text(_GIT_WRAPPER, encoding="utf-8")
        os.chmod(wrapper, 0o755)
        (binaries / "python3").symlink_to(sys.executable)

        target = root / "target"
        target.mkdir()
        gitconfig = root / "gitconfig"
        gitconfig.write_text("", encoding="utf-8")
        git_environment = {
            **os.environ,
            "GIT_CONFIG_GLOBAL": str(gitconfig),
            "GIT_CONFIG_NOSYSTEM": "1",
        }
        for command in (
            [real_git, "init", "-q", str(target)],
            [
                real_git,
                "-C",
                str(target),
                "remote",
                "add",
                "origin",
                "git@github.com:acme/widgets.git",
            ],
        ):
            proc = _run(command, env=git_environment)
            self.assertEqual(proc.returncode, 0, proc.stderr)

        install_root = root / "installed"
        environment = {
            # The stand-ins first, then the system directories the real `git`
            # and the `#!/usr/bin/env python3` shims resolve through.
            "PATH": os.pathsep.join([str(binaries), "/usr/bin", "/bin"]),
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_DATA_HOME": str(home / ".local" / "share"),
            "XDG_STATE_HOME": str(home / ".local" / "state"),
            "XDG_RUNTIME_DIR": str(root / "runtime"),
            "GIT_CONFIG_GLOBAL": str(gitconfig),
            "GIT_CONFIG_NOSYSTEM": "1",
            "ARCHIVE_SETUP_LOG": str(log),
            "ARCHIVE_SETUP_RESPONSES": json.dumps(_SHIM_RESPONSES),
            "ARCHIVE_SETUP_REAL_GIT": real_git,
            "KANBAN_ISSUE_REVIEW_INSTALL_DIR": str(install_root / "issue-review"),
            "LC_ALL": "C.UTF-8",
            "LANG": "C.UTF-8",
        }
        return SimpleNamespace(
            root=root,
            home=home,
            target=target,
            install_root=install_root,
            log=log,
            environment=environment,
        )

    def run_packaged(self, workspace, script, *arguments, cwd=None):
        """One packaged setup command, run the way `README.md` says to run it:
        out of the extracted release directory."""
        return _run(
            [sys.executable, str(self.unpacked_root / "tools" / script), *arguments],
            cwd=str(self.unpacked_root if cwd is None else cwd),
            env=workspace.environment,
            timeout=SDIST_TIMEOUT_SECONDS,
        )

    def recorded_commands(self, workspace, binary=None):
        if not workspace.log.exists():
            return []
        entries = [
            json.loads(line)
            for line in workspace.log.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        return [
            entry for entry in entries if binary is None or entry["binary"] == binary
        ]

    def assert_no_git_question_about_the_archive(self, workspace):
        """No `git` invocation was *about* the unpacked archive.

        The tree a git call is about is its `-C` argument, or its working
        directory when it has none -- which is how `git ls-files` and
        `git check-ignore` are reached, so both spellings the asset root used
        to be validated and inventoried through are covered. The commands
        legitimately run from inside the archive all name the target with
        `-C`, so running them there is not itself a hit.
        """
        offenders = []
        for entry in self.recorded_commands(workspace, "git"):
            subjects = [
                entry["args"][index + 1]
                for index, word in enumerate(entry["args"])
                if word == "-C" and index + 1 < len(entry["args"])
            ] or [entry["cwd"]]
            for subject in subjects:
                resolved = Path(subject).resolve()
                if resolved == self.unpacked_root or self.unpacked_root in resolved.parents:
                    offenders.append(entry)
        self.assertEqual(
            [],
            offenders,
            "A packaged setup path asked Git about the unpacked archive, which "
            "carries no Git metadata. The asset root must be validated and "
            "inventoried by its files.",
        )

    def test_workflow_setup_applies_every_component_from_the_archive(self):
        workspace = self.packaged_setup_workspace()
        install_dir = workspace.install_root / "issue-review"

        plan = self.run_packaged(
            workspace,
            "setup_workflows.py",
            "--all",
            "--scope",
            "user",
            "--install-dir",
            str(install_dir),
            "--json",
        )
        self.assertEqual(plan.returncode, 0, plan.stdout + plan.stderr)
        planned = json.loads(plan.stdout)
        self.assertEqual(planned["repo"], str(self.unpacked_root))
        for component in planned["components"]:
            with self.subTest(component=component["component"]):
                self.assertEqual(component["status"], "install", component)

        applied = self.run_packaged(
            workspace,
            "setup_workflows.py",
            "--all",
            "--scope",
            "user",
            "--install-dir",
            str(install_dir),
            "--apply",
            "--json",
        )
        self.assertEqual(applied.returncode, 0, applied.stdout + applied.stderr)

        for name in ("approve_issues.py", "kanban_config.py", "kanban_models.py"):
            with self.subTest(module=name):
                link = install_dir / name
                self.assertTrue(link.is_symlink(), link)
                self.assertEqual(
                    link.resolve(), self.unpacked_root / "tools" / name
                )
        self.assertEqual(
            (workspace.home / "work" / "approve-issues.py").resolve(),
            (install_dir / "approve_issues.py").resolve(),
        )
        marketplaces = [
            entry
            for entry in self.recorded_commands(workspace)
            if entry["binary"] in ("codex", "claude")
            and entry["args"][:3] == ["plugin", "marketplace", "add"]
        ]
        self.assertEqual(len(marketplaces), 2, marketplaces)
        for entry in marketplaces:
            with self.subTest(provider=entry["binary"]):
                self.assertTrue(
                    entry["args"][3].startswith(str(self.unpacked_root)), entry
                )
        self.assert_no_git_question_about_the_archive(workspace)

    def test_a_second_codex_pass_converges_without_asking_git(self):
        # The convergence pass a released install reaches on its second run:
        # the bundle is registered and enabled, so setup compares the cached
        # copy against the tracked one. In a checkout that inventory is
        # `git ls-files` and `git check-ignore`; from an archive it has to be
        # answered without either.
        workspace = self.packaged_setup_workspace()
        bundle = self.unpacked_root / "codex-plugin" / "plugins" / "kanban"
        version = json.loads(
            (bundle / ".codex-plugin" / "plugin.json").read_text(encoding="utf-8")
        )["version"]
        cache = (
            workspace.home
            / ".codex"
            / "plugins"
            / "cache"
            / "kanban"
            / "kanban"
            / version
        )
        shutil.copytree(bundle, cache)
        responses = _SHIM_RESPONSES + [
            {
                "binary": "codex",
                "match": ["marketplace", "list"],
                "stdout": json.dumps(
                    [
                        {
                            "name": "kanban",
                            "path": str(self.unpacked_root / "codex-plugin"),
                        }
                    ]
                ),
            },
            {
                "binary": "codex",
                "match": ["plugin", "list", "--json"],
                "stdout": json.dumps(
                    [{"id": "kanban@kanban", "installed": True, "enabled": True}]
                ),
            },
        ]
        # Prepended, because the shim answers with the first matching entry.
        workspace.environment["ARCHIVE_SETUP_RESPONSES"] = json.dumps(
            responses[-2:] + responses[:-2]
        )

        proc = self.run_packaged(
            workspace,
            "setup_workflows.py",
            "--component",
            "codex-plugin",
            "--scope",
            "user",
            "--json",
        )

        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        component = json.loads(proc.stdout)["components"][0]
        self.assertEqual(component["component"], "codex-plugin")
        self.assertEqual(component["status"], "unchanged", component)
        self.assertEqual(component["commands"], [])
        self.assert_no_git_question_about_the_archive(workspace)

        # The negative control, because "converged" and "compared nothing"
        # look identical from the outside: change one cached file and the same
        # command must report the repair, still without asking Git anything
        # about the archive.
        stale = next(path for path in sorted(cache.rglob("*.md")) if path.is_file())
        stale.write_text("# stale\n", encoding="utf-8")
        repair = self.run_packaged(
            workspace,
            "setup_workflows.py",
            "--component",
            "codex-plugin",
            "--scope",
            "user",
            "--json",
        )
        self.assertEqual(repair.returncode, 1, repair.stdout + repair.stderr)
        component = json.loads(repair.stdout)["components"][0]
        self.assertEqual(component["status"], "repair", component)
        self.assertEqual(
            component["divergence"]["different"],
            [stale.relative_to(cache).as_posix()],
        )
        self.assert_no_git_question_about_the_archive(workspace)

    def test_workflow_setup_refuses_project_scope_without_a_target(self):
        workspace = self.packaged_setup_workspace()

        proc = self.run_packaged(
            workspace,
            "setup_workflows.py",
            "--component",
            "claude-plugin",
            "--json",
        )

        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        payload = json.loads(proc.stdout or proc.stderr)
        component = payload["components"][0]
        self.assertEqual(component["status"], "refused", component)
        self.assertIn("--target", component["message"])
        self.assertIsNone(payload["target"])
        # Nothing was asked of the provider, and nothing was declared in the
        # archive.
        self.assertEqual(self.recorded_commands(workspace, "claude"), [])
        self.assertFalse((self.unpacked_root / ".claude").exists())

    def test_workflow_setup_registers_project_scope_in_an_explicit_target(self):
        workspace = self.packaged_setup_workspace()

        proc = self.run_packaged(
            workspace,
            "setup_workflows.py",
            "--component",
            "claude-plugin",
            "--target",
            str(workspace.target),
            "--apply",
            "--json",
        )

        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        payload = json.loads(proc.stdout)
        self.assertEqual(payload["repo"], str(self.unpacked_root))
        self.assertEqual(payload["target"], str(workspace.target))
        calls = self.recorded_commands(workspace, "claude")
        self.assertNotEqual([], calls)
        for entry in calls:
            with self.subTest(call=entry["args"]):
                self.assertEqual(entry["cwd"], str(workspace.target))
        self.assert_no_git_question_about_the_archive(workspace)

    def test_the_pr_drainer_refuses_the_archive_as_its_own_target(self):
        workspace = self.packaged_setup_workspace()

        proc = self.run_packaged(workspace, "install_drainer.py", "--json")

        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        error = json.loads(proc.stderr)["error"]
        self.assertIn("--repo", error)
        self.assertIn(str(self.unpacked_root), error)
        self.assertFalse((workspace.install_root / "pr-drainer").exists())
        self.assertEqual(self.recorded_commands(workspace, "launchctl"), [])
        self.assertEqual(self.recorded_commands(workspace, "systemctl"), [])

    def test_the_pr_drainer_installs_against_an_explicit_target(self):
        workspace = self.packaged_setup_workspace()
        install_dir = workspace.install_root / "pr-drainer"

        proc = self.run_packaged(
            workspace,
            "install_drainer.py",
            "--repo",
            str(workspace.target),
            "--install-dir",
            str(install_dir),
            "--json",
        )

        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        result = json.loads(proc.stdout)
        # The existing field keeps its existing meaning, and the second root
        # is reported beside it.
        self.assertEqual(result["repo"], str(workspace.target))
        self.assertEqual(result["asset_root"], str(self.unpacked_root))
        self.assertEqual(result["repository"], "acme/widgets")
        for name in (
            "drain_prs.py",
            "drain_prs_service.py",
            "kanban_config.py",
            "kanban_models.py",
            "service_manager.py",
        ):
            with self.subTest(module=name):
                link = install_dir / name
                self.assertTrue(link.is_symlink(), link)
                self.assertEqual(
                    link.resolve(), self.unpacked_root / "tools" / name
                )
        definition = self.installed_definition(result)
        self.assertIn(str(workspace.target), definition)
        self.assertNotIn(str(self.unpacked_root), definition)
        self.assert_no_git_question_about_the_archive(workspace)

    def test_a_newer_archive_takes_over_a_previous_archives_drainer_links(self):
        # The upgrade shape: an older release is unpacked and installed from,
        # then a newer one is installed from while the older is still on disk.
        # Every link is recognized as Kanban's own by the marker its tracked
        # file carries, so the newer archive takes them over rather than
        # refusing.
        workspace = self.packaged_setup_workspace()
        install_dir = workspace.install_root / "pr-drainer"
        previous = workspace.root / "previous-release"
        shutil.copytree(self.unpacked_root, previous)

        first = _run(
            [
                sys.executable,
                str(previous / "tools" / "install_drainer.py"),
                "--repo",
                str(workspace.target),
                "--install-dir",
                str(install_dir),
                "--json",
            ],
            cwd=str(previous),
            env=workspace.environment,
            timeout=SDIST_TIMEOUT_SECONDS,
        )
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertEqual(
            (install_dir / "drain_prs.py").resolve(), previous / "tools" / "drain_prs.py"
        )

        second = self.run_packaged(
            workspace,
            "install_drainer.py",
            "--repo",
            str(workspace.target),
            "--install-dir",
            str(install_dir),
            "--json",
        )

        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        for name in (
            "drain_prs.py",
            "drain_prs_service.py",
            "kanban_config.py",
            "kanban_models.py",
            "service_manager.py",
        ):
            with self.subTest(module=name):
                self.assertEqual(
                    (install_dir / name).resolve(), self.unpacked_root / "tools" / name
                )
        # The previous archive is still there: recognition is what allowed the
        # takeover, not the old target having gone away.
        self.assertTrue((previous / "tools" / "drain_prs.py").is_file())

    def test_the_issue_approval_service_installs_against_an_explicit_target(self):
        workspace = self.packaged_setup_workspace()
        backend_dir = workspace.install_root / "issue-review"
        approval_dir = workspace.install_root / "issue-approval"
        # This service resolves the canonical backend rather than installing
        # one, so the archive's own issue-review installer supplies it first.
        backend = self.run_packaged(
            workspace,
            "install_issue_review.py",
            "--install-dir",
            str(backend_dir),
            "--json",
        )
        self.assertEqual(backend.returncode, 0, backend.stdout + backend.stderr)
        self.assertEqual(json.loads(backend.stdout)["repo"], str(self.unpacked_root))

        proc = self.run_packaged(
            workspace,
            "install_issue_approval.py",
            "--repo",
            str(workspace.target),
            "--install-dir",
            str(approval_dir),
            "--json",
        )

        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        result = json.loads(proc.stdout)
        self.assertEqual(result["repo"], str(workspace.target))
        self.assertEqual(result["asset_root"], str(self.unpacked_root))
        self.assertEqual(result["job"]["repository"], "acme/widgets")
        for name in result["links"]:
            with self.subTest(module=name):
                link = Path(result["links"][name]["destination"])
                self.assertTrue(link.is_symlink(), link)
                self.assertEqual(
                    link.resolve(), self.unpacked_root / "tools" / name
                )
        definition = self.installed_definition(result)
        self.assertIn(str(workspace.target), definition)
        self.assertNotIn(str(self.unpacked_root), definition)
        self.assert_no_git_question_about_the_archive(workspace)

    def test_the_issue_approval_service_refuses_the_archive_as_its_own_target(self):
        workspace = self.packaged_setup_workspace()

        proc = self.run_packaged(workspace, "install_issue_approval.py", "--json")

        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        error = json.loads(proc.stderr)["error"]
        self.assertIn("--repo", error)
        self.assertIn(str(self.unpacked_root), error)
        self.assertFalse((workspace.install_root / "issue-approval").exists())

    def test_dry_runs_from_the_archive_change_nothing(self):
        workspace = self.packaged_setup_workspace()
        before_archive = _tree_snapshot(self.unpacked_root)
        before_target = _tree_snapshot(workspace.target)
        before_home = _tree_snapshot(workspace.home)

        for script, arguments in (
            (
                "setup_workflows.py",
                (
                    "--all",
                    "--scope",
                    "user",
                    "--install-dir",
                    str(workspace.install_root / "issue-review"),
                ),
            ),
            (
                "install_issue_review.py",
                ("--install-dir", str(workspace.install_root / "issue-review")),
            ),
            (
                "install_drainer.py",
                (
                    "--repo",
                    str(workspace.target),
                    "--install-dir",
                    str(workspace.install_root / "pr-drainer"),
                ),
            ),
        ):
            with self.subTest(script=script):
                proc = self.run_packaged(
                    workspace, script, *arguments, "--dry-run", "--json"
                )
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

        self.assertEqual(_tree_snapshot(self.unpacked_root), before_archive)
        self.assertEqual(_tree_snapshot(workspace.target), before_target)
        self.assertEqual(_tree_snapshot(workspace.home), before_home)
        self.assertFalse(workspace.install_root.exists())

    def installed_definition(self, result):
        """The service definition an install just wrote, whichever manager
        this host selected.

        The key is the *backend's* own name for it -- `plist` under launchd,
        `unit` under systemd -- so the result is searched for either rather
        than a path being guessed. Which one is present is the host's answer,
        and asserting on it here would be this fixture deciding what the
        selection under test should have decided.
        """
        for document in (result, result.get("controller", {}), result.get("job", {})):
            if not isinstance(document, dict):
                continue
            for key in ("plist", "unit"):
                recorded = document.get(key)
                if recorded:
                    return Path(recorded).read_text(encoding="utf-8")
        raise AssertionError(f"no service definition recorded in {result}")

    # ---- The package boundary -------------------------------------------
    #
    # Kanban's supported interfaces are the executable and its CLI, the
    # documented configuration, the on-disk compatibility surface, the
    # installers, and the workflow contracts. An importable `Kanban.*` library
    # is not among them: those modules are implementation seams, split and
    # respelled whenever the code wants it. So the package publishes no library
    # at all, and the two checks below hold it there.
    #
    # Neither reads `kanban.cabal`. What a stanza spells and what Cabal makes
    # of it are different questions, and only the second decides what a
    # recipient can depend on -- a rewritten stanza that restores a public
    # library would sail past any text check that was watching for the old
    # spelling. These ask Cabal instead, about the real unpacked archive: once
    # for the components it elaborates, and once per library for whether a
    # package that is not this one can name it.

    def elaborated_library_components(self):
        """Every library component Cabal elaborates for the unpacked package.

        Read from the `plan.json` a real `cabal build all --dry-run` writes in
        the unpacked source distribution. `lib` is the unnamed main library --
        the public one, the whole point of this section -- and `lib:<name>` is
        a named sublibrary, whose visibility `plan.json` does not record and
        the consumer probe below decides.

        That run is also this section's positive control for the environment:
        it resolves the package's own dependencies against the real index, so a
        probe failure below that names a library component is about that
        component rather than about a missing index or an offline runner.

        Where it cannot resolve one at all, this section skips. `cabal sdist`
        needs neither an index nor a compatible compiler, so the class above
        runs anywhere `cabal` does -- including CI's toolchain-free `python`
        job, which has a `cabal` but no `cabal update` and a GHC outside the
        package's own `base` bound. Nothing a public library could do makes
        this run fail, so a failure here is the environment and not the
        boundary. The skip cannot quietly retire the check either: the job that
        installs the pinned toolchain runs this module by name and fails on a
        skipped result.
        """
        cls = type(self)
        if cls.plan_gap is not None:
            self.skipTest(cls.plan_gap)
        if cls.elaborated_components is None:
            builddir = self.workspace_root / "plan"
            proc = _run(
                [
                    "cabal",
                    "build",
                    "all",
                    "--dry-run",
                    "--builddir",
                    str(builddir),
                ],
                cwd=str(self.unpacked_root),
                timeout=SDIST_TIMEOUT_SECONDS,
            )
            if proc.returncode != 0:
                cls.plan_gap = (
                    "the unpacked source distribution cannot resolve a build "
                    "plan here, so a refusal to depend on one of its libraries "
                    "would not distinguish a private library from an "
                    "unreachable one. That needs a package index (`cabal "
                    "update`) and a compiler inside the package's own `base` "
                    "bound.\n"
                    f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
                )
                self.skipTest(cls.plan_gap)
            plan = json.loads((builddir / "cache" / "plan.json").read_text("utf-8"))
            cls.elaborated_components = sorted(
                unit["component-name"]
                for unit in plan["install-plan"]
                if unit.get("pkg-name") == "kanban"
                and unit.get("component-name", "").split(":")[0] == "lib"
            )
        return cls.elaborated_components

    def probe_dependency(self, dependency):
        """Run `cabal` over a separate package that depends on `dependency`.

        Returns the completed process. The probe is a package of its own, in a
        project of its own, so what it asks Cabal is exactly what an outside
        package asks: not what the stanza says, but whether this dependency
        resolves against the real unpacked archive.
        """
        cls = type(self)
        if not cls.probe_harness_checked:
            # A probe that cannot resolve even `base` proves nothing about
            # Kanban, so establish that this scaffolding works before reading
            # any refusal below as a verdict. Once per class: it is a `cabal`
            # run, and the answer cannot change between tests.
            control = self.run_probe("base")
            self.assertEqual(
                0,
                control.returncode,
                "The boundary probe must resolve when it asks for nothing from "
                "this package. It did not, so its refusals below would say "
                "nothing about the package boundary.\n"
                f"stdout:\n{control.stdout}\nstderr:\n{control.stderr}",
            )
            cls.probe_harness_checked = True
        return self.run_probe(f"base, {dependency}")

    def run_probe(self, dependencies):
        # Resolved for the reason setUpClass resolves the unpacked root: on a
        # platform whose temporary directory is itself a symlink, a relative
        # path between one resolved end and one unresolved end walks out
        # through the link and lands nowhere.
        workspace = Path(
            tempfile.mkdtemp(dir=self.workspace_root, prefix="boundary-probe-")
        ).resolve()
        package = workspace / "probe"
        package.mkdir()
        (package / "KanbanBoundaryProbe.hs").write_text(
            "module KanbanBoundaryProbe where\n", encoding="utf-8"
        )
        (package / "probe.cabal").write_text(
            BOUNDARY_PROBE_PACKAGE.format(dependencies=dependencies),
            encoding="utf-8",
        )
        # The unpacked archive joins the project as a second local package, so
        # the probe is resolved against the real thing a recipient unpacks.
        # Named relatively: `packages:` is whitespace-separated, and the only
        # name reached this way is the `<package>-<version>` directory Cabal
        # itself chose, rather than a temporary path this run does not control.
        archive = os.path.relpath(self.unpacked_root, workspace)
        (workspace / "cabal.project").write_text(
            f"packages: ./probe/\n          {archive}/\n",
            encoding="utf-8",
        )
        return _run(
            [
                "cabal",
                "build",
                "kanban-boundary-probe",
                "--dry-run",
                "--builddir",
                str(workspace / "dist"),
            ],
            cwd=str(workspace),
            timeout=SDIST_TIMEOUT_SECONDS,
        )

    def test_the_package_publishes_no_unnamed_main_library(self):
        self.assertNotIn(
            "lib",
            self.elaborated_library_components(),
            "The unpacked source distribution has an unnamed main library. "
            "Cabal publishes that one, so the package would again advertise an "
            "installable `Kanban.*` API it does not support. The implementation "
            "modules belong in a private named sublibrary.",
        )
        probe = self.probe_dependency("kanban")
        self.assertNotEqual(
            0,
            probe.returncode,
            "A package that is not this one resolved a plain `kanban` library "
            "dependency against the unpacked archive. The package must publish "
            "no library.\n"
            f"stdout:\n{probe.stdout}\nstderr:\n{probe.stderr}",
        )
        self.assertIn(
            NO_SUCH_LIBRARY_REASON,
            probe.stdout + probe.stderr,
            "The probe failed for some reason other than this package having "
            "no public library, so it proves nothing about the boundary: an "
            "index, network, or solver failure is not evidence of privacy.",
        )

    def test_no_named_library_of_this_package_is_public(self):
        sublibraries = [
            component
            for component in self.elaborated_library_components()
            if component != "lib"
        ]
        # Never vacuous: the implementation modules live in a named
        # sublibrary, so finding none means the enumeration above broke rather
        # than that there is nothing to check.
        self.assertNotEqual(
            [],
            sublibraries,
            "Cabal elaborated no named library for this package. The "
            "implementation modules are supposed to be in one, so this check "
            "has lost sight of its subject rather than passing.",
        )
        for component in sublibraries:
            name = component.split(":", 1)[1]
            with self.subTest(sublibrary=name):
                probe = self.probe_dependency(f"kanban:{name}")
                self.assertNotEqual(
                    0,
                    probe.returncode,
                    f"A package that is not this one resolved `kanban:{name}` "
                    "against the unpacked archive, so that implementation "
                    "library is published. Named sublibraries need "
                    "`visibility: private`.\n"
                    f"stdout:\n{probe.stdout}\nstderr:\n{probe.stderr}",
                )
                self.assertIn(
                    PRIVATE_LIBRARY_REASON.format(name=name),
                    probe.stdout + probe.stderr,
                    "The probe failed for some reason other than "
                    f"`{name}` being private, so it proves nothing about the "
                    "boundary: an index, network, or solver failure is not "
                    "evidence of privacy.",
                )


if __name__ == "__main__":
    unittest.main()
