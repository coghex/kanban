"""Build a Git fixture once with real `git`, then hand every test its own copy.

The heavy `tools/` test modules each stand a real temporary repository up from
`setUp`: `git init`, a commit, a bare remote, a push, a linked worktree, a
clone, a merge. That is around twenty forks per test, and it is the same
twenty every time -- the cost is process spawning, not test logic.

This module keeps the spawning but pays it once. A fixture family declares how
to build its repository, that build runs a single time into an immutable
template, and each test gets an independent filesystem copy of it.

The trap a copy has to survive is that Git records absolute paths. A linked
worktree's `.git` file names the main repository's `worktrees/<name>`
directory, the matching `worktrees/<name>/gitdir` names the worktree, a
clone's `remote.origin.url` names the repository it came from, and reflog
messages name the URL a clone came from. A copy placed at a new path is
therefore a repository whose linkage and remote still point at the template,
which reads correctly and writes to shared state -- the silent direction.
`GitTemplate.copy()` rewrites every one of those, then refuses to hand back a
copy in which any occurrence of the template's location survives. The refusal
is the point: a metadata file this module has not learned about becomes a loud
failure rather than a test that quietly mutates its neighbour's fixture.

Not a test module itself (no `test_*.py` prefix), so `unittest discover` never
collects it; test modules import it as a plain library.

`tools/test_git_fixture.py` is this module's own coverage.
"""

from __future__ import annotations

import atexit
import hashlib
import os
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path
from typing import Callable, Iterator


class RelocationError(RuntimeError):
    """A copy still names its template and nothing here knows how to repair it.

    Raised instead of returning the copy, because the failure it stands for --
    a test reaching the shared template through its own fixture -- succeeds at
    reads and only corrupts writes.
    """


# Where a surviving template path is a hole in this module rather than
# something to patch over: object storage is compressed or checksummed, and
# the index is a binary record whose entries are length-prefixed. Rewriting
# either would corrupt it, so a hit in one is reported, never repaired.
def _is_opaque(relative: Path) -> bool:
    return "objects" in relative.parts or _is_stat_record(relative)


def _is_stat_record(relative: Path) -> bool:
    """A Git index: filesystem identity, not repository content."""
    return relative.parts[-1] in {"index", "index.lock"}


def _walk(root: Path) -> Iterator[os.DirEntry]:
    """Every entry below `root`, symlinks yielded but never followed."""
    stack = [str(root)]
    while stack:
        with os.scandir(stack.pop()) as entries:
            for entry in entries:
                yield entry
                if entry.is_dir(follow_symlinks=False):
                    stack.append(entry.path)


def _freeze(root: Path) -> None:
    """Take write permission off the whole tree.

    Requirement 3 of issue #384 is that the template is never mutated after it
    is built. Asserting that after the fact would only catch the mutation that
    already happened; taking the permission away makes the attempt fail where
    it is made.
    """
    for entry in _walk(root):
        if entry.is_symlink():
            continue
        mode = stat.S_IMODE(entry.stat(follow_symlinks=False).st_mode)
        os.chmod(entry.path, mode & ~0o222)
    os.chmod(root, stat.S_IMODE(root.stat().st_mode) & ~0o222)


def _thaw(root: Path) -> None:
    """Give owner write permission back, preserving every other bit.

    The exact inverse of `_freeze` under the usual 022 umask, which is what
    both the copies and this module's own cleanup need.
    """
    os.chmod(root, stat.S_IMODE(root.stat().st_mode) | 0o200)
    for entry in _walk(root):
        if entry.is_symlink():
            continue
        mode = stat.S_IMODE(entry.stat(follow_symlinks=False).st_mode)
        os.chmod(entry.path, mode | 0o200)


def path_forms(path: Path) -> list[str]:
    """The spellings Git may have recorded for `path`, longest first.

    On macOS a temporary directory is reached through `/var/...` and resolves
    to `/private/var/...`; Git writes whichever it computed, and both turn up
    in the same fixture -- a clone's `remote.origin.url` keeps the spelling it
    was given while `git worktree add` records the resolved one. Longest first
    so substituting the resolved spelling cannot leave the shorter one behind
    embedded in what it just wrote.
    """
    forms = {str(path), os.path.realpath(path)}
    return sorted(forms, key=len, reverse=True)


def _substitutions(source: Path, destination: Path) -> list[tuple[bytes, bytes]]:
    """Byte replacements carrying `source`'s spellings over to `destination`.

    Both live under one parent, so each spelling of the source has exactly one
    counterpart: the literal path maps to the literal path and the resolved
    path to the resolved path, which is what Git itself would have written had
    the fixture been built at the destination in the first place.
    """
    olds = path_forms(source)
    news = path_forms(destination)
    if len(olds) != len(news):
        # One of the two is reached through a symlink and the other is not,
        # so there is no spelling-for-spelling correspondence to apply.
        raise RelocationError(
            f"{source} and {destination} do not resolve through the same parent"
        )
    return [(old.encode(), new.encode()) for old, new in zip(olds, news)]


def _apply(blob: bytes, substitutions: list[tuple[bytes, bytes]]) -> bytes:
    for old, new in substitutions:
        blob = blob.replace(old, new)
    return blob


def _relocate(source: Path, destination: Path) -> None:
    """Rewrite every path in `destination` that still names `source`.

    Every file is read, not a curated list of them, and anything still naming
    the source after the pass this module knows how to make is raised rather
    than shipped.
    """
    substitutions = _substitutions(source, destination)
    olds = [old for old, _ in substitutions]
    for entry in _walk(destination):
        path = Path(entry.path)
        if entry.is_symlink():
            target = os.readlink(path)
            moved = _apply(target.encode(), substitutions).decode()
            if moved != target:
                os.unlink(path)
                os.symlink(moved, path)
            continue
        if entry.is_dir(follow_symlinks=False):
            continue
        blob = path.read_bytes()
        if not any(old in blob for old in olds):
            continue
        relative = path.relative_to(destination)
        if _is_opaque(relative):
            raise RelocationError(
                f"{relative} names the fixture template at {source} and cannot "
                "be rewritten; tools/git_fixture.py does not know how to "
                "relocate this file"
            )
        path.write_bytes(_apply(blob, substitutions))

    # Fail closed: a spelling this module did not anticipate would otherwise
    # leave the copy routing at the template, which reads fine and writes to
    # the wrong repository.
    for entry in _walk(destination):
        if entry.is_symlink():
            residue = os.readlink(entry.path).encode()
        elif entry.is_dir(follow_symlinks=False):
            continue
        else:
            residue = Path(entry.path).read_bytes()
        for old in olds:
            if old in residue:
                relative = Path(entry.path).relative_to(destination)
                raise RelocationError(
                    f"{relative} still names the fixture template at "
                    f"{old.decode()} after relocation"
                )


class GitTemplate:
    """One immutable Git fixture and the independent copies handed to tests.

    `build` receives the directory to build into and a dictionary for whatever
    the build learned that a test needs -- commit SHAs and the like. Only
    location-independent values belong in it: paths would name the template.
    """

    def __init__(self, build: Callable[[Path, dict], None], *, label: str = "fixture"):
        self._home = Path(tempfile.mkdtemp(prefix=f"kanban-{label}-"))
        atexit.register(self.cleanup)
        self.root = self._home / "template"
        self.root.mkdir()
        self._copies = self._home / "copies"
        self._copies.mkdir()
        self.data: dict = {}
        build(self.root, self.data)
        self._working_trees = [
            tree.relative_to(self.root) for tree in working_trees(self.root)
        ]
        _freeze(self.root)
        self._serial = 0

    def copy(self) -> Path:
        """A fresh, writable, fully relocated copy of the template."""
        destination = self._copies / str(self._serial)
        self._serial += 1
        shutil.copytree(self.root, destination, symlinks=True)
        _thaw(destination)
        _relocate(self.root, destination)
        self._refresh_indexes(destination)
        return destination

    def _refresh_indexes(self, destination: Path) -> None:
        """Re-stat every working tree so its index describes the copy.

        A Git index records each file's device and inode alongside its size
        and timestamps, and copying necessarily changes the first two. Left
        alone, the copy is a checkout with a stale index: `git status` still
        reports it clean because it falls back to comparing content, but the
        plumbing that trusts stat alone -- `git diff-files`, and the refresh
        inside `git stash create` -- sees every tracked file as modified.
        That is a different repository from the one the template built, so
        the copy is handed back only once Git has re-stated it.
        """
        for tree in self._working_trees:
            path = destination / tree
            proc = subprocess.run(
                ["git", "update-index", "--refresh", "-q"],
                cwd=str(path),
                text=True,
                capture_output=True,
            )
            if proc.returncode != 0:
                raise RelocationError(
                    f"the copy at {path} did not come back clean:\n"
                    f"{proc.stdout}\n{proc.stderr}"
                )

    def discard(self, destination: Path) -> None:
        shutil.rmtree(destination, ignore_errors=True)

    def cleanup(self) -> None:
        if self._home.exists():
            _thaw(self._home)
            shutil.rmtree(self._home, ignore_errors=True)


class GitTemplateMixin:
    """A `unittest.TestCase` mixin: build the fixture once, copy it per test.

    The template is cached on whichever class in the MRO actually declares
    `build_git_template`, so a fixture family shares one template across all
    of its subclasses, while a subclass that overrides the builder to add
    scenario state of its own gets a second template built once for that
    class. Caching on the declaring class is what makes both true without a
    registry to keep in step.
    """

    @classmethod
    def build_git_template(cls, root: Path, data: dict) -> None:
        """Run the real `git` commands that produce this family's fixture."""
        raise NotImplementedError

    @classmethod
    def _git_template_owner(cls) -> type:
        for klass in cls.__mro__:
            if "build_git_template" in klass.__dict__:
                return klass
        raise TypeError(f"{cls.__name__} declares no build_git_template")

    @classmethod
    def git_template(cls) -> GitTemplate:
        owner = cls._git_template_owner()
        template = owner.__dict__.get("_GIT_TEMPLATE")
        if template is None:
            template = GitTemplate(owner.build_git_template, label=owner.__name__)
            owner._GIT_TEMPLATE = template
        return template

    def checkout_git_template(self) -> Path:
        """This test's own copy, removed when the test ends.

        Safe to call more than once in one test -- each call is a separate
        copy -- which is what a case that re-runs its own `setUp()` per
        subtest needs.
        """
        template = self.git_template()
        root = template.copy()
        self.addCleanup(template.discard, root)
        self.template_data = dict(template.data)
        # Named for the mixin's benefit: fixture classes spell their own root
        # differently (`self.root` here, `self.fx.dir` there), and the
        # isolation coverage below has to find it without caring which.
        self.git_fixture_root = root
        return root


# -- what tests assert about a copy -------------------------------------------


def _git(args: list[str], cwd: Path) -> str:
    proc = subprocess.run(
        ["git", *args], cwd=str(cwd), text=True, capture_output=True
    )
    if proc.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed in {cwd}:\n{proc.stderr}")
    return proc.stdout.strip()


def repositories(root: Path) -> list[Path]:
    """Every directory under `root` that Git can run commands in.

    Both kinds count: a working tree, found by its `.git` entry whether that
    is a directory or a linked worktree's file, and a bare repository, found
    by the administrative files it keeps at its top level. A fixture's clones
    and simulated upstreams are repositories too, and each has to be checked.
    """
    found = []

    administrative = ("HEAD", "objects", "refs", "config")

    def looks_bare(candidate: Path) -> bool:
        return all((candidate / name).exists() for name in administrative)

    def visit(directory: Path) -> None:
        if (directory / ".git").exists():
            found.append(directory)
        elif directory != root and looks_bare(directory):
            found.append(directory)
            return
        with os.scandir(directory) as entries:
            children = sorted(
                (
                    entry.path
                    for entry in entries
                    if entry.is_dir(follow_symlinks=False) and entry.name != ".git"
                )
            )
        for child in children:
            visit(Path(child))

    visit(root)
    return found


def working_trees(root: Path) -> list[Path]:
    """The repositories under `root` that have a checkout, bare ones aside."""
    return [
        repository
        for repository in repositories(root)
        if (repository / ".git").exists()
    ]


def assert_repositories_are_self_contained(test, root: Path) -> None:
    """Every path Git resolves in every repository under `root` is under it.

    Asserted from what Git itself reports -- the resolved git directory, the
    common directory, the registered worktrees, the configured remotes -- and
    not from the metadata text this module rewrote, so a rewrite that produced
    a well-formed lie would still fail here.
    """
    inspected = repositories(root)
    test.assertTrue(inspected, f"no Git repository found under {root}")
    prefix = f"{os.path.realpath(root)}{os.sep}"

    def within(reported: str) -> bool:
        return os.path.realpath(reported).startswith(prefix)

    for repository in inspected:
        for query in ("--git-dir", "--git-common-dir"):
            resolved = _git(["rev-parse", "--path-format=absolute", query], repository)
            test.assertTrue(
                within(resolved),
                f"{repository.name} resolves {query} outside its copy: {resolved}",
            )
        for line in _git(["worktree", "list", "--porcelain"], repository).splitlines():
            if line.startswith("worktree "):
                registered = line[len("worktree "):]
                test.assertTrue(
                    within(registered),
                    f"{repository.name} registers a worktree outside its copy: "
                    f"{registered}",
                )
        remotes = subprocess.run(
            ["git", "config", "--get-regexp", r"^remote\..*\.url$"],
            cwd=str(repository),
            text=True,
            capture_output=True,
        )
        for line in remotes.stdout.splitlines():
            _, _, url = line.partition(" ")
            if url.startswith(("http://", "https://", "git@", "ssh://")):
                continue
            test.assertTrue(
                within(url),
                f"{repository.name} keeps a remote outside its copy: {url}",
            )


def fingerprint(root: Path) -> dict[str, str]:
    """What `root` holds, with its own location normalized away.

    Requirement 5 of issue #384 wants a later copy to be what the template
    built, and requirement 4 wants every path in a copy to name that copy;
    those only agree once the comparison ignores the substitution relocation
    makes. Every spelling of `root` collapses to one marker here, so two trees
    that differ solely by where they sit fingerprint identically.

    The Git index is left out for the same reason: it is a record of device
    and inode numbers, which no copy can carry over and which say nothing
    about what the repository holds. What the index would have proved --
    that a copy is a clean checkout of what the template committed -- is
    proved instead by `git status` reporting nothing in it.
    """
    olds = [form.encode() for form in path_forms(root)]
    marker = b"<fixture-root>"
    digest: dict[str, str] = {}
    for entry in _walk(root):
        relative = Path(entry.path).relative_to(root)
        if _is_stat_record(relative):
            continue
        relative = str(relative)
        if entry.is_symlink():
            target = os.readlink(entry.path).encode()
            for old in olds:
                target = target.replace(old, marker)
            digest[relative] = "symlink:" + hashlib.sha256(target).hexdigest()
        elif entry.is_dir(follow_symlinks=False):
            digest[relative] = "directory"
        else:
            blob = Path(entry.path).read_bytes()
            for old in olds:
                blob = blob.replace(old, marker)
            digest[relative] = hashlib.sha256(blob).hexdigest()
    return digest


class SharedTemplateIsolationTests:
    """Requirement 4 and 5 coverage, mixed into one class per fixture family.

    Mixed in rather than written once against a synthetic repository, because
    what has to hold is that *these* fixtures -- with their linked worktrees,
    their clones and their simulated upstreams -- are isolated, and each
    family's own shape is where that can go wrong.

    Not a `TestCase` itself, so importing it collects nothing; a module pairs
    it with the fixture whose copies it should be checking.
    """

    def test_every_repository_in_this_copy_resolves_inside_it(self):
        assert_repositories_are_self_contained(self, self.git_fixture_root)

    def test_mutating_this_copy_leaves_the_template_and_the_next_copy_pristine(self):
        template = self.git_template()
        before = fingerprint(template.root)

        self._mutate_the_copy()

        self.assertEqual(
            fingerprint(template.root),
            before,
            "the shared template changed while a test worked on its copy",
        )
        successor = self.checkout_git_template()
        self.assertEqual(
            fingerprint(successor),
            before,
            "a later copy did not come back as the template built it",
        )
        assert_repositories_are_self_contained(self, successor)
        for tree in working_trees(successor):
            self.assertEqual(
                _git(["status", "--porcelain"], tree),
                "",
                f"the checkout at {tree.name} did not come back clean",
            )

    def _mutate_the_copy(self):
        """Representative Git mutations against this family's own fixture."""
        raise NotImplementedError
