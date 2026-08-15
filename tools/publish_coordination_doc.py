#!/usr/bin/env python3
"""Publish one approved coordination-document mutation.

Run as:

    python3 tools/publish_coordination_doc.py \\
        --repo coghex/kanban --branch master \\
        --root <write-root> --path docs/ui-bugs.md \\
        --content <file holding the complete approved document>

Issue #315. The document workflows declared in
docs/document-workflow-contract.md §2 publish an approved `coordination`
mutation in the same run that applies it (issue #237). The *policy* — which
assets publish, what makes a document eligible, one artifact per invocation,
the approval stop — lives in those assets and in §9. This module is the whole
*mechanism*, and it is the only place that mechanism exists.

It is a module rather than shell in those assets because the mechanism was
first written that way, where twelve review rounds found twenty defects and
nothing in the tree could execute the sequence to find a twenty-first. Two
properties follow from the change:

- the sequence is one process holding one lock, rather than a chain a reader
  might reorder or half-apply; and
- every safety property below is a test in
  tools/test_publish_coordination_doc.py that performs a real publication
  against a temporary repository.

## The caller hands over content, never a pre-edited file

`--content` is the complete approved document, and this module writes it; the
caller does not. That is what makes a foreign same-file edit unpublishable
rather than merely unlikely: the published bytes never come from the working
tree, so an edit landing beside this run cannot be swept into its commit. The
working tree is read only to establish the baseline and to recognize a pending
publication — both of which exist to refuse when it holds anything unexpected.

## The write root is not the publication branch

Every declared asset writes in the `docs-wip` linked worktree while publication
targets the default branch. So the baseline, the eligibility classification and
the resumption checks are all computed against the fixed publication tip's blob
for the path — never against the write root's HEAD — and this module never
checks out, resets, switches or advances any branch or HEAD there. The only
file it writes is the document itself, and it never stages it.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath

# §7 is Kanban's own statement about Kanban, so it can only ever authorize
# publication to Kanban itself. A consuming repository that installed the
# plugins has no coordination lane through this module.
CANONICAL_REPOSITORY = "coghex/kanban"

CLASSIFICATION_PATH = "docs/agent-workflow-contract.md"
COORDINATION_CLASS = "coordination"
SECTION_7_HEADING = "## 7. Document publication classification"

# Rows are `path | class | reasons`. The parse is anchored to §7's heading and
# stops at the next heading, so §4's dependency fence cannot satisfy it.
CLASSIFICATION_ROW_RE = re.compile(
    r"^(?P<path>\S+)\s*\|\s*(?P<klass>[\w-]+)\s*\|\s*(?P<reasons>[^|]+?)\s*$"
)

LOCK_NAMESPACE = "refs/kanban/publish-lock"
PENDING_NAMESPACE = "refs/kanban/pending-publication"


class PublishError(Exception):
    """A reported outcome rather than a traceback. `status` is the
    machine-readable name the caller branches on."""

    def __init__(self, status: str, message: str, **detail):
        super().__init__(message)
        self.status = status
        self.message = message
        self.detail = detail


def git(args, *, cwd: Path, check: bool = True, input_bytes: bytes | None = None):
    proc = subprocess.run(
        ["git", *args], cwd=str(cwd), capture_output=True, input=input_bytes
    )
    if check and proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).decode(errors="replace").strip()
        raise PublishError("git-failed", f"git {' '.join(args)} failed: {detail}")
    return proc


def git_out(args, *, cwd: Path, input_bytes: bytes | None = None) -> str:
    return git(args, cwd=cwd, input_bytes=input_bytes).stdout.decode().strip()


# ---------------------------------------------------------------- identity --


def normalized_slug(raw: str) -> str:
    """`owner/name`, case-folded, from a slug or a remote URL. GitHub
    identities are case-insensitive, so two spellings name one repository."""
    value = raw.strip()
    value = re.sub(
        r"^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)", "", value
    )
    value = re.sub(r"\.git$", "", value).strip("/")
    parts = [part for part in value.split("/") if part]
    if len(parts) < 2:
        raise PublishError("bad-repository", f"not an owner/name repository: {raw!r}")
    return "/".join(parts[-2:]).lower()


def resolve_write_root(root: Path) -> Path:
    """The write root's own top level. A linked worktree is the ordinary case:
    the assets write in `docs-wip`."""
    if not root.is_dir():
        raise PublishError("bad-write-root", f"write root is not a directory: {root}")
    return Path(git_out(["rev-parse", "--show-toplevel"], cwd=root))


def verify_owner(root: Path, declared: str) -> str:
    """The owner established from the write root's own `origin`, refusing when
    it disagrees with what the caller declared.

    §8 of docs/document-workflow-contract.md records a verified
    wrong-repository write. Trusting the argument would leave that failure in
    place, because the argument is exactly what a mistaken caller gets wrong.
    """
    proc = git(["remote", "get-url", "origin"], cwd=root, check=False)
    if proc.returncode != 0:
        raise PublishError(
            "owner-unverifiable",
            f"write root {root} has no origin remote to establish its owner from",
        )
    actual = normalized_slug(proc.stdout.decode())
    wanted = normalized_slug(declared)
    if actual != wanted:
        raise PublishError(
            "owner-mismatch",
            f"write root {root} belongs to {actual}, not the declared {wanted}",
            write_root_repository=actual,
            declared_repository=wanted,
        )
    return actual


# -------------------------------------------------------------------- lock --


def _key(repository: str, document: str) -> str:
    """A ref-safe name for one (repository, document) pair, and a distinct one
    for every pair.

    Not `/` replaced by `-`: that maps `docs/a-b.md` and `docs/a/b.md` to the
    same name, so two different documents would share a lock and a pending
    record — one failing to publish would block the other, and a record left by
    one could be resolved against the other. A digest of the pair collides for
    no input, at the cost of being unreadable; the lock's own payload carries
    the repository and document in clear for `git for-each-ref` to show, and a
    pending record's commit names the document in its tree.
    """
    return hashlib.sha256(f"{repository}\0{document}".encode()).hexdigest()[:40]


def lock_ref(repository: str, document: str) -> str:
    """Keyed on owner and document, so two documents never contend and two
    repositories sharing a machine never collide."""
    return f"{LOCK_NAMESPACE}/{_key(repository, document)}"


def pending_ref(repository: str, document: str) -> str:
    return f"{PENDING_NAMESPACE}/{_key(repository, document)}"


def common_git_dir(root: Path) -> Path:
    """The repository's common Git directory.

    Refs and scratch files live here rather than under `<root>/.git/`, which in
    a linked worktree is a *file* rather than a directory — the hazard
    tools/drain_prs.py records and that tools/approve_issues.py's lock walked
    into. Every declared asset writes in the `docs-wip` linked worktree, so
    this is the ordinary case rather than the exotic one.
    """
    return Path(
        git_out(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd=root)
    )


def new_content_file(root: Path, document: str) -> Path:
    """A scratch path for this invocation's rendered content, minted here.

    The caller must not choose it. A name derived from the document collides
    between two runs of the same document, and a fixed name collides between
    any two runs at all — either way one run reads the other's approved content
    and publishes it under its own document's name. `mkstemp` in the common Git
    directory is unique per invocation by construction, which is the property
    no caller-side convention can promise.
    """
    directory = common_git_dir(root)
    handle, path = tempfile.mkstemp(
        prefix=f"kanban-approved-{_key('', document)}-", dir=str(directory)
    )
    os.close(handle)
    return Path(path)


def owner_token(repository: str = "", document: str = "") -> str:
    """This run's identity, plus what it holds. The ref name is a digest, so
    the payload is where a human or a stale-lock sweep learns which document a
    lock belongs to."""
    return json.dumps(
        {
            "host": socket.gethostname(),
            "pid": os.getpid(),
            "repository": repository,
            "document": document,
        },
        sort_keys=True,
        separators=(",", ":"),
    )


def read_lock_owner(root: Path, ref: str) -> dict | None:
    proc = git(["rev-parse", "--verify", "--quiet", ref], cwd=root, check=False)
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    subject = git_out(["log", "-1", "--format=%s", ref], cwd=root)
    try:
        return json.loads(subject)
    except json.JSONDecodeError:
        return {"host": None, "pid": None, "raw": subject}


def acquire_lock(
    root: Path, ref: str, tip: str, repository: str = "", document: str = ""
) -> str:
    """Atomic per-document mutual exclusion.

    `update-ref <ref> <new> ""` requires the ref to be absent, and creating it
    is atomic, so exactly one caller wins. The ref points at a commit whose
    subject carries this run's ownership identity, which is what lets a stale
    lock be told from a live one.
    """
    commit = git_out(
        ["commit-tree", f"{tip}^{{tree}}", "-m", owner_token(repository, document)],
        cwd=root,
    )
    proc = git(["update-ref", ref, commit, ""], cwd=root, check=False)
    if proc.returncode != 0:
        raise PublishError(
            "locked",
            "another run holds this document's publication lock",
            lock_ref=ref,
            lock_owner=read_lock_owner(root, ref) or {},
        )
    return commit


def release_lock(root: Path, ref: str, value: str) -> bool:
    """Drop the lock, and only ever *this* run's lock.

    `update-ref -d <ref> <old>` deletes only while the ref still holds that
    exact value. An unconditional delete would remove whatever lock happened to
    be there — including one another run acquired after this one's had already
    gone — and two publishers holding a lock each is the one thing it exists to
    prevent.
    """
    if not value:
        # Required, not defaulted: an unbound delete removes whatever lock is
        # there, which is precisely the defect this signature exists to make
        # unrepresentable.
        raise PublishError(
            "lock-release-unbound",
            f"releasing {ref} requires the value this run acquired",
        )
    proc = git(["update-ref", "-d", ref, value], cwd=root, check=False)
    return proc.returncode == 0


def process_is_live(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def clear_stale_lock(root: Path, ref: str) -> dict:
    """Clear a lock only once its owner is provably gone.

    A lock whose owner is still running, or whose owner is another host and so
    cannot be checked from here, is refused: clearing either would produce two
    simultaneous publishers, which is the thing the lock exists to prevent.
    """
    observed = git(
        ["rev-parse", "--verify", "--quiet", ref], cwd=root, check=False
    ).stdout.decode().strip()
    holder = read_lock_owner(root, ref)
    if holder is None or not observed:
        return {"status": "no-lock", "lock_ref": ref}
    host, pid = holder.get("host"), holder.get("pid")
    if host != socket.gethostname():
        raise PublishError(
            "lock-foreign-owner",
            f"the lock is held by {host!r}, which cannot be checked from here",
            lock_ref=ref,
            lock_owner=holder,
        )
    if isinstance(pid, int) and process_is_live(pid):
        raise PublishError(
            "lock-owner-live",
            f"the lock owner pid {pid} is still running",
            lock_ref=ref,
            lock_owner=holder,
        )
    # Delete the exact ref this call inspected. Two clearers can agree the
    # same owner is dead; without this, the slower one deletes whatever lock
    # exists by then — which may be a live publisher's.
    proc = git(["update-ref", "-d", ref, observed], cwd=root, check=False)
    if proc.returncode != 0:
        raise PublishError(
            "lock-changed",
            "the lock changed while it was being cleared; it was left alone",
            lock_ref=ref,
            observed=observed,
        )
    return {"status": "cleared", "lock_ref": ref, "lock_owner": holder}


# ------------------------------------------------------------- eligibility --


def parse_classification(text: str) -> dict[str, str]:
    """§7's rows, keyed by declared path. Anchored to §7's heading and stopped
    at the next heading, so no other table in that document can be read as the
    classification."""
    rows: dict[str, str] = {}
    section = False
    for line in text.splitlines():
        if line.strip() == SECTION_7_HEADING:
            section = True
            continue
        if section and line.startswith("## "):
            break
        if not section:
            continue
        stripped = line.strip()
        if not stripped or stripped.startswith(("#", "`", "-", "|")):
            continue
        match = CLASSIFICATION_ROW_RE.match(stripped)
        if match is not None:
            rows[match.group("path")] = match.group("klass")
    return rows


def row_covers(declared: str, document: str) -> bool:
    """§7's own matching semantics, so this module cannot disagree with
    tools/test_document_classification.py: a directory row matches by whole
    path component and never by string prefix."""
    if not declared.endswith("/"):
        return declared == document
    prefix = PurePosixPath(declared.rstrip("/")).parts
    return PurePosixPath(document).parts[: len(prefix)] == prefix


def classify(rows: dict[str, str], document: str):
    """(class, matching rows). No row is the fail-closed default; more than one
    row is two lanes, which is no lane."""
    matched = sorted(path for path in rows if row_covers(path, document))
    if len(matched) != 1:
        return None, matched
    return rows[matched[0]], matched


def eligibility(root: Path, owner: str, tip: str, document: str) -> tuple[bool, str]:
    """Whether this document may publish directly, and why not when it may not.

    A decision rather than a refusal: an ineligible document is an ordinary
    outcome of a run whose disposition was still approved, and the approved
    mutation still has to survive it.
    """
    if owner != CANONICAL_REPOSITORY:
        return False, (
            f"{owner} has no coordination lane; §7 classifies "
            f"{CANONICAL_REPOSITORY} and nothing else"
        )
    proc = git(["show", f"{tip}:{CLASSIFICATION_PATH}"], cwd=root, check=False)
    if proc.returncode != 0:
        return False, (
            f"the publication tip carries no {CLASSIFICATION_PATH}, so it has no "
            "coordination lane"
        )
    klass, matched = classify(
        parse_classification(proc.stdout.decode(errors="replace")), document
    )
    if klass != COORDINATION_CLASS:
        return False, (
            f"{document} is classified {klass or 'by no §7 row'} rather than "
            f"{COORDINATION_CLASS}, so it is pr-atomic and lands with its "
            f"implementation (matching rows: {matched or 'none'})"
        )
    return True, ""


# ------------------------------------------------------------------- state --


def blob_at(root: Path, revision: str, document: str) -> str | None:
    """The document's blob at `revision`, or None when it is absent there. An
    absent path is not an empty baseline: a novel document stays local until a
    pull request adds it and its classification (#237)."""
    proc = git(
        ["rev-parse", "--verify", "--quiet", f"{revision}:{document}"],
        cwd=root,
        check=False,
    )
    out = proc.stdout.decode().strip()
    return out or None


def working_blob(root: Path, document: str) -> str | None:
    target = root / document
    if not target.is_file():
        return None
    return git_out(["hash-object", "--", str(target)], cwd=root)


def staged_blob(root: Path, document: str) -> str | None:
    """The document's index entry in the write root, or None when unindexed."""
    proc = git(["rev-parse", "--verify", "--quiet", f":{document}"], cwd=root, check=False)
    out = proc.stdout.decode().strip()
    return out or None


def head_blob(root: Path, document: str) -> str | None:
    return blob_at(root, "HEAD", document)


def require_unstaged(root: Path, document: str) -> None:
    """Refuse a document with a staged change in the write root.

    The end state this module promises is that the document path is left
    unstaged, so the index entry must already match the write root's HEAD.
    Hashing only the working file misses an index-only edit — `git apply
    --cached` leaves the file itself untouched — and publishing over one would
    both carry somebody's unapproved staged work forward and break the single
    defined state reconciliation depends on.
    """
    staged, head = staged_blob(root, document), head_blob(root, document)
    if staged != head:
        raise PublishError(
            "document-staged",
            f"{document} has a staged change in the write root; publication needs "
            "the document unstaged so its end state is defined",
            staged_blob=staged,
            head_blob=head,
        )


def is_ancestor(root: Path, commit: str, revision: str) -> bool:
    return (
        git(
            ["merge-base", "--is-ancestor", commit, revision], cwd=root, check=False
        ).returncode
        == 0
    )


def git_blob_hash(data: bytes) -> str:
    """A blob's object name, computed here rather than by a subprocess.

    The check that the document is still the baseline and the write that
    replaces it must be as close together as the process can make them: a
    `git hash-object` between them is a fork, an exec and a pipe during which
    an outside edit can land and be destroyed unseen.
    """
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def _quietly(action, *args, **kwargs) -> bool:
    """Run a cleanup step that must never raise.

    Cleanup happens on the way out, often with an exception already
    propagating and always after the document may have been replaced. A raise
    from here would substitute itself for the real error, escape the structured
    result every other failure returns, and skip the lock release on its way
    past. Failing to tidy up is worth strictly less than any of that.
    """
    try:
        action(*args, **kwargs)
        return True
    except OSError:
        return False


def read_for_write(target: Path):
    """The document's bytes and the stat they were read from, together.

    A seam as much as a helper: the window this module must close is between
    reading the file and replacing it, and a test can only inject an edit into
    that window if the read is something it can wrap.
    """
    if not target.is_file():
        return b"", None
    with open(target, "rb") as handle:
        return handle.read(), os.fstat(handle.fileno())


def _preserve(root: Path, data: bytes) -> str:
    """Put `data` in the object database, so refusing to publish it does not
    lose it. Recoverable afterwards with `git cat-file -p <blob>`."""
    return git_out(
        ["hash-object", "-w", "-t", "blob", "--stdin"], cwd=root, input_bytes=data
    )


def rename_aside(target: Path, aside: Path) -> None:
    """Move the document out of the way, atomically. A seam a test can reach."""
    os.rename(target, aside)


def link_into_place(scratch: Path, target: Path) -> None:
    """Put the new content at the document's path, failing if anything is
    already there. `link` is the one filesystem primitive here that refuses
    rather than overwrites, which is what makes the gap detectable."""
    os.link(scratch, target)


def put_back(aside: Path, target: Path, data: bytes, mode: int) -> bool:
    """Return the captured document to its path without overwriting anything.

    `link` refuses when the path is occupied, which is the point: by the time a
    recovery runs, another writer may already have created a file there, and
    that file is newer than what is being put back. Restoring must never be the
    step that destroys a write — the same rule the swap itself follows.

    It also never raises. This runs on the way out of a failure, and a
    restoration that throws would replace the real error with its own and leave
    the document deleted. When `link` is unavailable for some reason other than
    the path being taken, the document is recreated exclusively instead: that
    still refuses an occupied path, where a rename would check and then
    overwrite — the very race this module declines to run anywhere else.
    """
    try:
        link_into_place(aside, target)
        return True
    except FileExistsError:
        return False
    except OSError:
        pass
    try:
        descriptor = os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY, mode)
    except OSError:
        return False
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
        os.chmod(target, mode)
        return True
    except OSError:
        return False


def verify_and_write(root: Path, document: str, baseline: str, content: bytes) -> None:
    """Replace the document, refusing if it is not the baseline — and never
    overwriting whatever is actually there.

    A check followed by a write can always be raced, and POSIX offers no
    compare-and-swap on file content, so this does not check and then write.
    It *captures* instead:

    - `rename` moves whatever occupies the path out of the way atomically, so
      nothing can be clobbered by this module — an in-place edit and a wholesale
      replacement are both carried out of the way intact, and whichever it is
      gets hashed;
    - if that is not the baseline it is preserved in the object database, moved
      back, and the run fails closed;
    - `link` then puts the new content in place and *fails* if anything was
      created in the gap, in which case what was created stays and the captured
      document is moved back.

    The document is briefly absent between those two steps: a reader in that
    instant sees no file rather than a torn or wrong one, which is the cost of
    never destroying somebody else's write.
    """
    target = root / document
    handle = scratch = aside = None
    captured, captured_mode, captured_blob = b"", 0o644, None
    # Only a completed capture may be restored. Before it, `captured` is a
    # placeholder rather than the document, and putting *that* back would
    # invent a file rather than return one.
    captured_ok = False
    try:
        existing, _ = read_for_write(target)
        if git_blob_hash(existing) != baseline:
            raise PublishError(
                "document-changed-before-write",
                f"{document} changed after its baseline was verified; nothing was "
                "written and nothing was published",
                preserved_blob=_preserve(root, existing),
            )

        handle, scratch_name = tempfile.mkstemp(
            prefix=f".{target.name}.kanban-publish-", dir=str(target.parent)
        )
        scratch = Path(scratch_name)
        with os.fdopen(handle, "wb") as stream:
            handle = None
            stream.write(content)
        # mkstemp creates 0600, and the swap replaces the file, so the mode
        # travels with it rather than silently narrowing a document other
        # people and processes read.
        os.chmod(scratch, os.stat(target).st_mode & 0o7777)

        captured_mode = os.stat(target).st_mode & 0o7777
        aside = Path(
            tempfile.mkdtemp(prefix=".kanban-publish-aside-", dir=str(target.parent))
        ) / target.name
        rename_aside(target, aside)

        captured, _ = read_for_write(aside)
        captured_ok = True
        # Unconditionally, and before anything else can fail: from here the
        # document exists only as this temporary, so its content belongs
        # somewhere durable whatever happens next.
        captured_blob = _preserve(root, captured)
        if captured_blob != baseline:
            preserved = captured_blob
            restored = put_back(aside, target, captured, captured_mode)
            raise PublishError(
                "document-changed-before-write",
                f"{document} was changed between its verification and the swap; "
                + (
                    "the change was put back and nothing was published"
                    if restored
                    else "another writer had already recreated the document, so "
                    "that file was left in place and the captured change is "
                    "recoverable from the object database; nothing was published"
                ),
                preserved_blob=preserved,
                restored=restored,
            )

        try:
            link_into_place(scratch, target)
        except FileExistsError:
            # Somebody created the document in the gap. Their file is the most
            # recent write and stays exactly as it is — moving the captured
            # copy back over it would destroy the write this whole design
            # exists to protect. What was captured is the baseline, which the
            # publication branch already carries, and it is preserved anyway so
            # the report can name both.
            preserved = _preserve(root, captured)
            raise PublishError(
                "document-changed-before-write",
                f"{document} was recreated by another writer during the swap; "
                "that file was left in place and nothing was published",
                preserved_blob=preserved,
            ) from None
    except OSError as error:
        raise PublishError(
            "document-unwritable",
            f"{document} could not be read or replaced: {error}",
        ) from error
    finally:
        # Cleanup runs after the document may already have been replaced, so
        # nothing in here may raise: an exception thrown from a `finally`
        # replaces whatever was propagating, and one thrown from *here* would
        # escape the result contract entirely and skip the lock release with
        # it. Every step below is best-effort by construction.
        if handle is not None:
            _quietly(os.close, handle)
        # Only this invocation's own temporaries, each created exclusively.
        if scratch is not None:
            _quietly(scratch.unlink, missing_ok=True)
        if aside is not None:
            # Between the rename and the link the document does not exist, and
            # `aside` holds the only copy of it. *Any* failure in that gap —
            # not just the one this code anticipated — must therefore put it
            # back before the temporary is dropped, or a failed publication
            # deletes the cursor it was trying to publish. Checked as an
            # invariant on the way out rather than repeated at each raise,
            # because the failure that matters here is the one not enumerated.
            restored = True
            if captured_ok and not _quietly(target.stat):
                restored = put_back(aside, target, captured, captured_mode)
            elif not captured_ok:
                # The rename never completed, so nothing was taken and there is
                # nothing to give back. A missing document here was removed by
                # somebody else; recreating it from the placeholder would turn
                # their deletion into an unapproved empty file.
                restored = True
            if restored:
                _quietly(aside.unlink, missing_ok=True)
                _quietly(aside.parent.rmdir)
            else:
                # Kept — but a file kept somewhere nobody is told about is only
                # marginally better than one deleted, so the path travels with
                # the failure that is already on its way out.
                in_flight = sys.exc_info()[1]
                if isinstance(in_flight, PublishError):
                    in_flight.detail.setdefault("captured_file", str(aside))
                    in_flight.detail.setdefault("captured_blob", captured_blob)
            # If it could not be put back, the temporary stays: the content is
            # in the object database either way, but deleting the only file
            # copy on the way out of a failure would be the worst thing this
            # module could do.


def build_commit(root: Path, tip: str, document: str, blob: str, message: str) -> str:
    """A commit on `tip` whose tree is `tip`'s with exactly one blob replaced.

    Built through a scratch index in the common Git directory, so the write
    root's own index is never touched — the caller's staged work elsewhere is
    not this module's to disturb — and a tree derived from `tip` cannot carry a
    second path.
    """
    # Minted, never named. A predictable path in the shared common Git
    # directory is somebody else's file waiting to happen — an interrupted
    # run's, another tool's — and this both rewrites it via `read-tree` and
    # deletes it afterwards. The same rule the working-tree temporaries follow.
    try:
        handle, scratch_name = tempfile.mkstemp(
            prefix="kanban-publish-index-", dir=str(common_git_dir(root))
        )
        os.close(handle)
    except OSError as error:
        raise PublishError(
            "scratch-index-unavailable",
            f"a scratch index for {document} could not be created: {error}",
        ) from error
    scratch = Path(scratch_name)
    env = dict(os.environ, GIT_INDEX_FILE=str(scratch))
    try:
        for args in (
            ["read-tree", tip],
            ["update-index", "--add", "--cacheinfo", f"100644,{blob},{document}"],
        ):
            proc = subprocess.run(
                ["git", *args], cwd=str(root), capture_output=True, env=env
            )
            if proc.returncode != 0:
                raise PublishError(
                    "git-failed",
                    f"git {' '.join(args)} failed: {proc.stderr.decode().strip()}",
                )
        tree = subprocess.run(
            ["git", "write-tree"], cwd=str(root), capture_output=True, env=env
        ).stdout.decode().strip()
    finally:
        # Best-effort, like every other cleanup here: this runs after the
        # document has already been replaced but before the candidate commit
        # and its record exist, so a raise would strand an approved local
        # document with nothing to resume from.
        _quietly(scratch.unlink, missing_ok=True)
    return git_out(["commit-tree", tree, "-p", tip, "-m", message], cwd=root)


def changed_paths(root: Path, base: str, commit: str) -> list[str]:
    return [
        line
        for line in git_out(["diff", "--name-only", base, commit], cwd=root).splitlines()
        if line
    ]


def change_summary(root: Path, base: str, commit: str, document: str) -> dict:
    """What this publication actually changed, as counts and hunk headers.

    The caller hands over whole-file content, so an unintended collateral
    rewrite is invisible to the changed-path check — one path changes either
    way. Reporting the region that changed is what makes such a rewrite visible
    to the run that caused it.
    """
    added = removed = 0
    stat = git_out(["diff", "--numstat", base, commit, "--", document], cwd=root)
    if stat:
        fields = stat.split("\t")
        if len(fields) >= 2 and fields[0].isdigit() and fields[1].isdigit():
            added, removed = int(fields[0]), int(fields[1])
    hunks = [
        line
        for line in git_out(
            ["diff", "--unified=0", base, commit, "--", document], cwd=root
        ).splitlines()
        if line.startswith("@@")
    ]
    return {"added": added, "removed": removed, "hunks": hunks}


# ------------------------------------------------------------------ publish --


def _push_and_verify(
    root: Path, branch: str, commit: str, pending: str
) -> tuple[bool, str]:
    """Record, push, and decide by reachability alone.

    The record is written *before* the push, so a run killed between a
    successful push and its verification still leaves something the next run
    recognizes as landed. Reachability is the whole verdict: a concurrent
    same-document advance leaves the commit an ancestor while the local file no
    longer equals the branch, and calling that a failure would make the next
    run republish over the other writer.
    """
    git(["update-ref", pending, commit], cwd=root)
    pushed = git(
        ["push", "origin", f"{commit}:refs/heads/{branch}"], cwd=root, check=False
    )
    git(["fetch", "origin", branch], cwd=root)
    landed = is_ancestor(root, commit, f"origin/{branch}")
    return landed, (pushed.stderr or b"").decode(errors="replace").strip()


def _resume(
    root: Path, branch: str, tip: str, document: str, pending: str, current: str,
    approved_blob: str,
) -> dict:
    """The document differs from the tip before this run wrote anything.

    That is publishable only when it is exactly a previous run's recorded,
    unpublished mutation. Content identity alone is not enough: the recorded
    commit was built on the tip its own run pinned, and rebuilding it onto a
    newer tip would push pre-advance content over whatever the other writer put
    there.
    """
    recorded = git(
        ["rev-parse", "--verify", "--quiet", pending], cwd=root, check=False
    ).stdout.decode().strip()
    if not recorded:
        raise PublishError(
            "document-not-baseline",
            f"{document} differs from the publication tip and no pending "
            "publication is recorded, so its content is not an approved mutation "
            "this module can publish",
            working_blob=current,
        )
    recorded_blob = blob_at(root, recorded, document)
    if recorded_blob != current:
        raise PublishError(
            "document-not-baseline",
            f"{document} differs from the pending publication recorded for it, so "
            "it carries work beyond the approved mutation",
            recorded_blob=recorded_blob,
            working_blob=current,
            local_commit=recorded,
            pending_ref=pending,
        )
    if recorded_blob != approved_blob:
        # The caller is publishing a *different* disposition from the one the
        # record names. Publishing the record instead would report success
        # while the newly approved mutation never reached the document — and by
        # now the caller has already mutated the tracker for it.
        raise PublishError(
            "pending-differs-from-approved",
            f"an earlier unpublished mutation of {document} is recorded, and the "
            "content supplied now is not it; resolve that record before publishing "
            "a different disposition",
            recorded_blob=recorded_blob,
            approved_blob=approved_blob,
            local_commit=recorded,
            pending_ref=pending,
            remote_contains_commit=False,
        )
    parent = git_out(["rev-parse", f"{recorded}^"], cwd=root)
    if parent != tip:
        raise PublishError(
            "pending-stale",
            f"the pending publication for {document} was built on {parent[:12]}, but "
            f"the branch has advanced to {tip[:12]}; retrying would replace the "
            "advance with pre-advance content",
            local_commit=recorded,
            pending_parent=parent,
            publication_tip=tip,
        )
    landed, push_error = _push_and_verify(root, branch, recorded, pending)
    if not landed:
        raise PublishError(
            "unpublished",
            "the retried publication was not accepted by the remote branch",
            push_stderr=push_error,
            remote_contains_commit=False,
            local_commit=recorded,
            pending_ref=pending,
            document_edit={"exists": True, "write_root": str(root), "path": document},
        )
    clear_record_or_report_divergence(
        root, document, pending, recorded_blob, branch, recorded
    )
    return {
        "status": "published",
        "resumed": "retried",
        "commit": recorded,
        "published_blob": recorded_blob,
        "remote_contains_commit": True,
        "document": document,
        "branch": branch,
        "changes": change_summary(root, tip, recorded, document),
    }


def tracker_transaction_module():
    """tools/tracker_transaction.py, loaded from beside this file.

    A plain `import` would need `tools/` on `sys.path`, which it is when this
    module runs as a script and is not when a test loads it by path. The
    dependency is one-way by construction — that module never loads this one —
    so two independently invocable command-line tools do not become mutually
    dependent, at the cost of each keeping its own copy of four small identity
    helpers. tools/test_tracker_transaction.py pins the pair that matters, the
    (repository, document) key, so the copies cannot drift apart unseen.
    """
    source = Path(__file__).resolve().parent / "tracker_transaction.py"
    try:
        spec = importlib.util.spec_from_file_location(
            "_kanban_tracker_transaction", source
        )
        if spec is None or spec.loader is None:
            raise ImportError(f"no loader for {source}")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    except Exception as error:  # noqa: BLE001 - reported, never raised bare
        # Fail closed rather than reporting a clear preflight: an outstanding
        # tracker transaction that cannot be read is exactly the state in which
        # proceeding repeats a mutation GitHub has already accepted.
        raise PublishError(
            "tracker-transaction-unavailable",
            f"the tracker transaction module at {source} could not be loaded "
            f"({error}); the preflight cannot report whether one is outstanding",
        ) from error
    return module


def check_pending(root: Path, repository: str, branch: str, document: str) -> dict:
    """Whether an earlier approved mutation of this document is outstanding —
    its publication, its tracker mutations, or both.

    Callers mutate the tracker before they publish, so this has to be askable
    *before* they do: learning about an unresolved record afterwards means a
    second issue already exists for a disposition that cannot be applied. Issue
    #327 added the other half of the same question, because a run can equally
    have created the issue and then died before recording anything — so one
    preflight answers for both records rather than leaving the newer one to a
    check the assets might not make. This only reads — no lock, no write, no
    fetch of anything it does not need.

    `status` stays exactly `clear` or `pending`, and `publication_tip` stays
    where it was: the assets branch on those, and a preflight that reported a
    third state or moved the binding would be a silent caller-contract change.
    `pending_kinds` says which record is outstanding when one is.
    """
    resolved = resolve_write_root(root)
    owner = verify_owner(resolved, repository)
    pending = pending_ref(owner, document)
    recorded = git(
        ["rev-parse", "--verify", "--quiet", pending], cwd=resolved, check=False
    ).stdout.decode().strip()
    module = tracker_transaction_module()
    try:
        tracker = module.check(resolved, repository, document)
    except Exception as error:  # noqa: BLE001 - the preflight must stay structured
        # The whole point of this call is to tell a caller whether it may mutate
        # the tracker, so a failure inside it has to arrive as a tracker answer
        # rather than as an exception that leaves the boundary reporting a
        # document failure and an internal error. `observed_report` never
        # raises, and reports an unreadable record as unreadable rather than as
        # absent — which is what keeps this fail-closed instead of merely
        # structured.
        tracker = {
            "status": "outstanding",
            "message": getattr(error, "message", str(error)),
        } | module.observed_report(resolved, module.transaction_ref(owner, document))
    kinds = []
    if recorded:
        kinds.append("publication")
    if tracker["status"] != "clear":
        kinds.append("tracker-transaction")
    try:
        # Not check=False: the tip this returns becomes the caller's binding,
        # and a binding minted from a stale cached ref is worse than no
        # preflight at all — it reads as current and licenses a publication
        # against a document that has already moved.
        git(["fetch", "origin", branch], cwd=resolved)
        observed_tip = git_out(["rev-parse", f"origin/{branch}"], cwd=resolved)
        outcome = {
            "status": "pending" if kinds else "clear",
            "document": document,
            "pending_ref": pending,
            "publication_tip": observed_tip,
            "pending_kinds": kinds,
            "tracker_transaction": tracker,
        }
        if not recorded:
            return outcome
        landed = is_ancestor(resolved, recorded, f"origin/{branch}")
        return outcome | {
            "pending_commit": recorded,
            "recorded_blob": blob_at(resolved, recorded, document),
            "already_landed": landed,
            "resolution": (
                "the recorded publication reached the branch; re-run publication "
                "with the recorded content to reconcile and clear it"
                if landed
                else "re-run publication with the recorded content to retry it, or "
                "clear the record deliberately; do not approve a different "
                "disposition for this document first"
            ),
        }
    except Exception as error:  # noqa: BLE001 - the report survives the failure
        # An unreachable remote, a branch that no longer exists, a broken object
        # database. Whatever it is, the records were already read and they are
        # what the run has to report: failing here without them tells a caller
        # holding an outstanding transaction nothing about it, at the one moment
        # it most needs to know it may not mutate anything.
        if not isinstance(error, PublishError):
            error = PublishError("internal-error", f"{type(error).__name__}: {error}")
        error.detail.setdefault("pending_kinds", kinds)
        error.detail.setdefault("tracker_transaction", tracker)
        raise error


def failure_states(root: Path, document: str, *, commit: str | None,
                   branch: str, reachable: bool | None) -> dict:
    """§9.5's three states, for every unpublished outcome.

    A failure that happened before the write still answers all three — with
    "the document is as it was" and "no publication commit exists" — because a
    caller told to report three states cannot report them from a result that
    omits two. Absent is a state, not a missing field.
    """
    target = root / document
    return {
        "document_edit": {
            "exists": target.is_file(),
            "write_root": str(root),
            "path": document,
            "blob": working_blob(root, document),
        },
        "local_publication_commit": commit,
        "remote_branch": f"origin/{branch}",
        "remote_contains_commit": reachable,
    }


def clear_record_or_report_divergence(
    root: Path, document: str, pending: str, published_blob: str, branch: str,
    commit: str,
) -> None:
    """Drop the pending record, but only from a write root that still matches
    what was published.

    Reachability is settled by the time this runs, so the publication is a
    fact. What is not settled is the write root: an outside process can change
    or stage the document between the verification and this call. Clearing the
    record then would leave that divergence with nothing pointing at it, which
    is the guarantee §9 makes about a landed record — and it holds however the
    publication got there, freshly or by resumption.
    """
    if working_blob(root, document) != published_blob or staged_blob(
        root, document
    ) != head_blob(root, document):
        raise PublishError(
            "landed-but-divergent",
            f"{document} reached {branch}, but the write root has been changed or "
            "staged since; the record is kept so the divergence is not lost",
            remote_contains_commit=True,
            local_commit=commit,
            published_blob=published_blob,
            pending_ref=pending,
        )
    proc = git(["update-ref", "-d", pending, commit], cwd=root, check=False)
    if proc.returncode != 0:
        # Bound to the recorded value, like every other ref this module
        # removes. A record left behind stops the next preflight and therefore
        # every later disposition for this document, so a publication that
        # could not clear it says so rather than reporting plain success.
        raise PublishError(
            "record-retained",
            f"{document} reached {branch}, but its pending record could not be "
            "cleared; the next run's preflight will stop until it is resolved",
            remote_contains_commit=True,
            local_commit=commit,
            published_blob=published_blob,
            pending_ref=pending,
        )


def resolve_landed_pending(
    root: Path, branch: str, pending: str, document: str, approved_blob: str
):
    """A recorded publication that already reached the branch, if there is one.

    This is asked before the baseline is compared, because a landed record is
    exactly the case the baseline cannot see: the branch now carries the
    approved content, so the document equals the tip and the run looks like it
    has nothing to do. Left unresolved, the record would survive every later
    run — and a run interrupted between a successful push and its verification
    is precisely how it is created.
    """
    recorded = git(
        ["rev-parse", "--verify", "--quiet", pending], cwd=root, check=False
    ).stdout.decode().strip()
    if not recorded or not is_ancestor(root, recorded, f"origin/{branch}"):
        return None
    approved = blob_at(root, recorded, document)
    if approved != approved_blob:
        # Only the recorded mutation landed. Reporting this call as published
        # would tell a caller that has already created its own tracker item
        # that its disposition reached the branch, when nothing of it did —
        # the same confusion the unlanded resumption path refuses.
        raise PublishError(
            "pending-differs-from-approved",
            f"the publication recorded for {document} reached {branch}, but it is "
            "not the content supplied now; reconcile that record before "
            "publishing a different disposition",
            recorded_blob=approved,
            approved_blob=approved_blob,
            remote_contains_commit=True,
            local_commit=recorded,
            pending_ref=pending,
        )
    clear_record_or_report_divergence(
        root, document, pending, approved, branch, recorded
    )
    return {
        "status": "published",
        "resumed": "already-landed",
        "commit": recorded,
        "published_blob": blob_at(root, recorded, document),
        "remote_contains_commit": True,
        "document": document,
        "branch": branch,
        # Every published result carries the summary, including a recovered
        # one: the caller is told to check it against the disposition it
        # applied, and a recovered run has the same reason to.
        "changes": change_summary(root, f"{recorded}^", recorded, document),
        "document_edit": {"exists": True, "write_root": str(root), "path": document},
    }


def publish(
    *, repository: str, branch: str, root: Path, document: str, content: bytes,
    message: str, expected_tip: str | None = None,
) -> dict:
    """Publish one approved mutation, or report why it was not published.

    Every failure leaves through the one handler below, including the ones
    raised before the lock is taken — an owner mismatch, an unreachable remote,
    a lock another run holds. A caller told to report three states cannot
    report them from a result that carries none, and "the run never got far
    enough to write anything" is an answer to all three rather than an excuse
    for omitting them.
    """
    try:
        resolved = resolve_write_root(root)
        owner = verify_owner(resolved, repository)
        git(["fetch", "origin", branch], cwd=resolved)
        tip = git_out(["rev-parse", f"origin/{branch}"], cwd=resolved)
        if expected_tip is not None and expected_tip != tip:
            # The caller rendered its content against `expected_tip` and then
            # mutated its tracker. If the branch has moved since, that content
            # is a whole-file image of a document that no longer exists, and
            # publishing it would drop whatever landed in between — silently,
            # because it changes exactly the one path a correct publication
            # changes. The caller has to re-read and re-render.
            raise PublishError(
                "tip-moved",
                f"{branch} advanced from {expected_tip[:12]} to {tip[:12]} after "
                "this content was rendered; re-read the document and render the "
                "disposition again",
                expected_tip=expected_tip,
                publication_tip=tip,
                remote_contains_commit=False,
            )

        lock = lock_ref(owner, document)
        pending = pending_ref(owner, document)
        held = acquire_lock(resolved, lock, tip, owner, document)
        try:
            outcome = _publish_locked(
                root=resolved, owner=owner, branch=branch, tip=tip, document=document,
                content=content, message=message, pending=pending,
            )
        except BaseException as error:
            # A `finally` here would release and then re-raise, and the check
            # below would never run — so a lock that outlived a *failed*
            # publication would block every later run while the report named
            # only the original failure. The failure keeps priority; the
            # retained lock travels with it.
            #
            # BaseException rather than PublishError: the lock must come off
            # for anything that leaves this block, including the failures this
            # module did not model. Only a PublishError can carry the detail.
            if not release_lock(resolved, lock, held) and isinstance(
                error, PublishError
            ):
                error.detail.setdefault("lock_retained", True)
                error.detail.setdefault("lock_ref", lock)
            raise
        if not release_lock(resolved, lock, held):
            # And on the successful path it is the whole story: the document
            # published, but every later run for it is now blocked.
            raise PublishError(
                "lock-retained",
                f"{document} was published, but its publication lock could not be "
                "released; later runs will be blocked until it is cleared",
                remote_contains_commit=outcome.get("remote_contains_commit"),
                local_commit=outcome.get("commit"),
                lock_retained=True,
                lock_ref=lock,
            )
        return outcome
    except Exception as error:  # noqa: BLE001 - the collector is the point
        if not isinstance(error, PublishError):
            # An unmodelled failure is still an unpublished outcome, and by the
            # time one happens the document may already hold the approved
            # bytes. Converting it here rather than at the CLI boundary is what
            # lets the state collector run against a resolved write root and
            # report where that edit actually is.
            error = PublishError("internal-error", f"{type(error).__name__}: {error}")
        try:
            states = failure_states(
                Path(git_out(["rev-parse", "--show-toplevel"], cwd=root)),
                document,
                commit=error.detail.get("local_commit"),
                branch=branch,
                reachable=error.detail.get("remote_contains_commit"),
            )
        except Exception:
            # A write root too broken to inspect still answers all three, as
            # unknowns rather than as absent fields.
            states = {
                "document_edit": {"exists": None, "write_root": str(root), "path": document},
                "local_publication_commit": error.detail.get("local_commit"),
                "remote_branch": f"origin/{branch}",
                "remote_contains_commit": error.detail.get("remote_contains_commit"),
            }
        error.detail = {**states, **error.detail}
        # `raise` alone re-raises the *original*, which for an unmodelled
        # failure is the very exception this handler just converted — the
        # conversion would be assigned and then discarded.
        raise error


def _publish_locked(*, root, owner, branch, tip, document, content, message, pending):
    """The sequence itself, run with the lock held. Split from publish() so
    every failure leaving it passes through one place that attaches §9.5's
    three states."""
    publishable, why_not = eligibility(root, owner, tip, document)
    baseline = blob_at(root, tip, document)
    if baseline is None:
        publishable, why_not = False, (
            f"{document} is absent from the publication tip; a novel document "
            "stays local until a pull request adds it and its classification"
        )

    approved_blob = git_blob_hash(content)
    already = resolve_landed_pending(root, branch, pending, document, approved_blob)
    if already is not None:
        return {"repository": owner, "publication_tip": tip} | already

    # Before any outcome, including the ineligible one: the state this module
    # promises to leave is "the document path is unstaged", and returning a
    # normal result while it is staged contradicts that whether or not a
    # publication was possible.
    require_unstaged(root, document)

    if not publishable:
        # The disposition was still approved, and by now the caller has very
        # likely already mutated the tracker. Refusing to publish must not also
        # discard the approved mutation: it goes into the object database
        # unconditionally, and onto the document too whenever that can be done
        # without clobbering anything.
        preserved = _preserve(root, content)
        applied = False
        if baseline is not None and working_blob(root, document) == baseline:
            verify_and_write(root, document, baseline, content)
            applied = True
        return {
            "status": "not-published",
            "reason": why_not,
            "repository": owner,
            "branch": branch,
            "document": document,
            "publication_tip": tip,
            "approved_blob": preserved,
            "document_written": applied,
            "remote_contains_commit": False,
            "local_publication_commit": None,
            "document_edit": {
                "exists": (root / document).is_file(),
                "write_root": str(root),
                "path": document,
            },
        }

    # A record that has not landed and is not being resumed is unresolved
    # work, not debris. Publishing fresh would overwrite the ref and lose the
    # only pointer to an earlier run's approved mutation — the state left
    # behind when a rejected push is followed by reverting the document.
    outstanding = git(
        ["rev-parse", "--verify", "--quiet", pending], cwd=root, check=False
    ).stdout.decode().strip()

    current = working_blob(root, document)
    if current == baseline and outstanding:
        raise PublishError(
            "pending-unresolved",
            f"an earlier publication of {document} is recorded and has not landed, "
            "but the document no longer carries it; resolve that record before "
            "publishing something else",
            local_commit=outstanding,
            remote_contains_commit=False,
            pending_ref=pending,
            recorded_blob=blob_at(root, outstanding, document),
        )
    if current != baseline:
        return {"repository": owner, "publication_tip": tip} | _resume(
            root, branch, tip, document, pending, current, approved_blob
        )

    # The commit is built from this blob, so it must exist in the object
    # database as well as be known by name. Not an assert: `python3 -O` would
    # strip it, leaving the object unwritten and `commit-tree` to fail on a
    # missing blob — and an AssertionError would escape the result contract
    # every other failure here honours.
    written = _preserve(root, content)
    if written != approved_blob:
        raise PublishError(
            "content-hash-mismatch",
            f"the approved content hashed to {approved_blob} but the object "
            f"database stored {written}",
        )
    if approved_blob == baseline:
        raise PublishError(
            "no-mutation",
            f"the approved content for {document} is identical to the publication "
            "tip; there is nothing to publish",
        )

    # Re-read immediately before writing. The window between the baseline
    # check and the write is small but real, and an outside-protocol edit
    # landing in it must survive rather than be overwritten by this write.
    require_unstaged(root, document)
    verify_and_write(root, document, baseline, content)

    commit = build_commit(root, tip, document, approved_blob, message)
    touched = changed_paths(root, tip, commit)
    if touched != [document]:
        raise PublishError(
            "not-isolated",
            f"the publication commit changes {touched} rather than {document} alone",
            changed_paths=touched,
        )

    try:
        landed, push_error = _push_and_verify(root, branch, commit, pending)
    except PublishError as error:
        # The candidate exists and the record already names it, so a failure
        # in the push or the verification that followed must say so — that is
        # exactly the state a recovery needs, and the moment it is hardest to
        # reconstruct afterwards.
        error.detail.setdefault("local_commit", commit)
        error.detail.setdefault("pending_ref", pending)
        error.detail.setdefault("remote_contains_commit", None)
        raise
    if not landed:
        # The mutation stays in the write root as the approved content and
        # the record identifies it exactly. No local branch moved, so
        # nothing here can wedge the drainer's fast-forward.
        raise PublishError(
            "unpublished",
            "the publication was not accepted by the remote branch",
            push_stderr=push_error,
            remote_contains_commit=False,
            local_commit=commit,
            pending_ref=pending,
            document_edit={"exists": True, "write_root": str(root), "path": document},
        )

    clear_record_or_report_divergence(
        root, document, pending, approved_blob, branch, commit
    )
    new_tip = git_out(["rev-parse", f"origin/{branch}"], cwd=root)
    return {
        "status": "published",
        "repository": owner,
        "branch": branch,
        "document": document,
        "publication_tip": tip,
        "commit": commit,
        "published_blob": approved_blob,
        "remote_contains_commit": True,
        "branch_advanced_after_push": new_tip != commit,
        "changes": change_summary(root, tip, commit, document),
        "document_edit": {"exists": True, "write_root": str(root), "path": document},
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Publish one approved mutation.")
    parser.add_argument("--repo", required=True, help="the owning owner/name")
    parser.add_argument("--branch", help="the publication branch")
    parser.add_argument("--root", required=True, type=Path, help="the local write root")
    parser.add_argument("--path", required=True, help="repository-relative document")
    parser.add_argument("--content", type=Path, help="file holding the approved content")
    parser.add_argument("--message", default=None)
    parser.add_argument(
        "--expected-tip",
        default=None,
        help="the publication tip the content was rendered against",
    )
    parser.add_argument("--clear-stale-lock", action="store_true")
    parser.add_argument(
        "--new-content-file",
        action="store_true",
        help="mint and print a scratch path for this invocation's content",
    )
    parser.add_argument(
        "--check-pending",
        action="store_true",
        help="report any outstanding publication for this document and stop",
    )
    args = parser.parse_args(argv)

    try:
        if args.new_content_file:
            root = resolve_write_root(args.root)
            verify_owner(root, args.repo)
            print(new_content_file(root, args.path))
            return 0
        if not args.branch:
            parser.error("--branch is required unless --new-content-file is given")
        if args.check_pending:
            outcome = check_pending(
                resolve_write_root(args.root), args.repo, args.branch, args.path
            )
            print(json.dumps(outcome, indent=2, sort_keys=True, default=str))
            return 0 if outcome["status"] == "clear" else 1
        if args.clear_stale_lock:
            root = resolve_write_root(args.root)
            owner = verify_owner(root, args.repo)
            outcome = clear_stale_lock(root, lock_ref(owner, args.path))
        else:
            if args.content is None:
                parser.error("--content is required unless --clear-stale-lock is given")
            if not args.expected_tip:
                # Not optional on this path, and emphatically not "absent means
                # skip the check": a caller that fails to extract the tip would
                # otherwise silently publish with the guard disabled, which is
                # indistinguishable from having no guard at all.
                raise PublishError(
                    "expected-tip-required",
                    "--expected-tip is required to publish; pass the "
                    "publication_tip the preflight reported, so content rendered "
                    "against a superseded document cannot be published",
                )
            try:
                content = args.content.read_bytes()
            except OSError as error:
                raise PublishError(
                    "content-unreadable",
                    f"the approved content at {args.content} could not be read: {error}",
                ) from error
            outcome = publish(
                repository=args.repo,
                branch=args.branch,
                root=args.root,
                document=args.path,
                content=content,
                message=args.message
                or f"docs: publish the approved mutation to {args.path}",
                expected_tip=args.expected_tip,
            )
    except Exception as error:  # noqa: BLE001 - the boundary is the point
        # The envelope is guaranteed at this boundary, not only inside
        # publish(): a failure raised before the sequence starts — unreadable
        # content, an unusable write root — is still an unpublished outcome the
        # caller must report all three states for. And an error this module
        # never modelled is still an unpublished outcome: the caller branches
        # on the result, so a traceback where a result belongs leaves it with
        # nothing to report and no way to tell what happened to its document.
        if not isinstance(error, PublishError):
            error = PublishError(
                "internal-error", f"{type(error).__name__}: {error}"
            )
        payload = {
            "document_edit": {
                "exists": None,
                "write_root": str(args.root),
                "path": args.path,
            },
            "local_publication_commit": None,
            "remote_branch": f"origin/{args.branch}" if args.branch else None,
            "remote_contains_commit": None,
        }
        payload.update(error.detail)
        payload.update({"status": error.status, "message": error.message})
        print(json.dumps(payload, indent=2, sort_keys=True, default=str))
        return 1
    print(json.dumps(outcome, indent=2, sort_keys=True, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
