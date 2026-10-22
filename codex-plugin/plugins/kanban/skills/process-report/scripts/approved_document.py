#!/usr/bin/env python3
"""Apply one approved document mutation and hand it to `docs-push`.

Run as:

    python3 <bundle>/approved_document.py \\
        --repo coghex/kanban --branch master \\
        --root <write-root> --path docs/ui-bugs.md \\
        --expected-working-copy <preflight working_copy_blob> \\
        --content <file holding the complete approved document>

Issue #830, slice B of #775. `tools/publish_coordination_doc.py` is two things:
a publication mechanism (eligibility, a commit built on the branch tip, a push)
and a document-write protocol every processing workflow relies on. The owner's
`docs-push` replaces the first. This module is the second, kept whole and
reduced to what it owns:

- approved-content application that refuses to overwrite an outside edit;
- per-document serialization;
- the durable `refs/kanban/pending-publication` and `refs/kanban/applied-locally`
  records and the `--check-pending` preflight that reports a publication record
  and a tracker transaction together; and
- the one call that hands a named document to `docs-push`.

It never constructs, signs or pushes a publication commit, never implements a
push or a merge, and never reads `workflow.direct_publication_paths`, §7 of
docs/agent-workflow-contract.md or `workflow.coordination_paths`. Whether a path
may land directly is `docs-push`'s decision, taken from its own configuration;
a refusal is an outcome this module reports, not a lane it routes around.

Slice B adds this module beside the publisher and changes no asset: the
publisher stays in place and keeps working, and slice C is what deletes it and
points the processing workflows here. This module therefore reads, and
coexists with, every record the publisher writes.

## The caller hands over content, never a pre-edited file

`--content` is the complete approved document, and this module writes it. It
binds that content to the verified repository (the write root's own `origin`),
the repository-relative path, the baseline the caller's preflight observed
(`working_copy_blob`) and the exact approved blob, and replaces the document
only while it still holds those baseline bytes. The write is the publisher's
capture-and-refuse protocol (`verify_and_write`), not a read followed by a
write: an outside edit is preserved in the object database and put back, never
overwritten.

The write root is the owning repository's current isolated worktree. `docs-wip`
is neither required nor selected.

## Publication is `docs-push`, and the receipt decides

After the write this module runs `docs-push --expect <approved_blob> --keep -m
<message> <document>` from the write root, naming that one path. `docs-push`
merges three ways, so the blob it publishes can legitimately differ from the
approved input; its output, good or bad, decides nothing. The commit message
carries a marker naming the recorded attempt, and the verdict is reachability
alone, decided against a freshly fetched `origin/<branch>`:

- a commit carrying this attempt's marker lies in the history since the recorded
  tip, and the published blob is that commit's own blob for the document, not
  whatever a later tip holds; or
- the branch already carries the approved blob at the document's path, which is
  the tool's "nothing to land".

A missing tool, a tool that lacks `--expect` or `--keep`, a refusal, a conflict
or a changed file is an explicit `incomplete-publication` outcome carrying the
tool's exact message. Nothing falls back to a raw `git push` or another
publisher, and the approved content and its records stay where they are.

## Recovery points

The pending record is written before the document is replaced, so every
interruption leaves something the next run recognizes:

1. before application: the record exists and the document is still the baseline;
2. after application and before the tool: the document is the approved blob;
3. after publication and before cleanup, including after a three-way merge: the
   document is the merged copy `--keep` left, and the receipt is on the branch;
4. between a tracker checkpoint and its resolution: the preflight reports both
   records, and `tracker_transaction.py` resolves against the published entry.

A record that is stale, changed, malformed or unverifiable stops with a report;
it is never ignored or deleted to proceed.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

LOCK_NAMESPACE = "refs/kanban/publish-lock"
PENDING_NAMESPACE = "refs/kanban/pending-publication"

# What this module applied to a document and has not yet landed. A working tree
# is equally what a hand edit produces, so this reference is the difference: it
# names the exact content this module wrote, which is what lets
# tracker_transaction.py tell an applied disposition from somebody's edit.
APPLIED_NAMESPACE = "refs/kanban/applied-locally"

# The subject of this module's own pending record. A record under
# PENDING_NAMESPACE without it is the publisher's commit-shaped form, which is
# recognized and resumed rather than rejected.
PENDING_SUBJECT = "kanban approved-document pending publication"
PENDING_VERSION = 1
FORM_HELPER = "approved-document"
FORM_PUBLISHER = "publish-coordination-doc"

# The trailer that names one publication attempt in the commit `docs-push`
# builds. Everything that identifies the attempt travels in it, so a receipt is
# bound to the record that asked for it and not merely to bytes that two
# documents can share.
RECEIPT_TRAILER = "Kanban-Approved-Document"

TOOL = "docs-push"
TOOL_CAPABILITIES = ("--expect", "--keep")
TOOL_TIMEOUT_SECONDS = 600

OID_RE = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")
ATTEMPT_RE = re.compile(r"^[0-9a-f]{32}$")


class DocumentError(Exception):
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
        raise DocumentError("git-failed", f"git {' '.join(args)} failed: {detail}")
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
        raise DocumentError("bad-repository", f"not an owner/name repository: {raw!r}")
    return "/".join(parts[-2:]).lower()


def resolve_write_root(root: Path) -> Path:
    """The write root's own top level. A linked worktree is the ordinary case:
    the owning repository's current isolated worktree."""
    if not root.is_dir():
        raise DocumentError("bad-write-root", f"write root is not a directory: {root}")
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
        raise DocumentError(
            "owner-unverifiable",
            f"write root {root} has no origin remote to establish its owner from",
        )
    actual = normalized_slug(proc.stdout.decode())
    wanted = normalized_slug(declared)
    if actual != wanted:
        raise DocumentError(
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


def applied_ref(repository: str, document: str) -> str:
    return f"{APPLIED_NAMESPACE}/{_key(repository, document)}"


def read_applied(root: Path, repository: str, document: str) -> str | None:
    """The content this module last applied locally to `document`, or None.

    It proves one thing and is worth exactly that: these bytes are what this
    module wrote the last time it recorded a write. It says nothing about
    whether that disposition was ever landed anywhere.
    """
    out = git(
        ["rev-parse", "--verify", "--quiet", applied_ref(repository, document)],
        cwd=root,
        check=False,
    ).stdout.decode().strip()
    return out or None


def record_applied(root: Path, repository: str, document: str, blob: str) -> bool:
    """Record `blob` as what this module wrote, and confirm the record took.

    `update-ref` can fail for reasons that have nothing to do with the write
    that just succeeded — a full disk, a contended reference lock, a read-only
    Git directory. Reporting the write as recorded anyway would licence a later
    run to continue over content nothing can prove this module produced, which
    is the one thing the reference exists to prevent. So it is read back, and
    only a reference naming the exact blob counts as recorded.
    """
    ref = applied_ref(repository, document)
    git(["update-ref", ref, blob], cwd=root, check=False)
    return read_applied(root, repository, document) == blob


def common_git_dir(root: Path) -> Path:
    """The repository's common Git directory.

    Refs and scratch files live here rather than under `<root>/.git/`, which in
    a linked worktree is a *file* rather than a directory — the hazard
    tools/drain_prs.py records and that tools/approve_issues.py's lock walked
    into. The write root is a linked worktree, so this is the ordinary case
    rather than the exotic one.
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
        raise DocumentError(
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
        raise DocumentError(
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
        raise DocumentError(
            "lock-foreign-owner",
            f"the lock is held by {host!r}, which cannot be checked from here",
            lock_ref=ref,
            lock_owner=holder,
        )
    if isinstance(pid, int) and process_is_live(pid):
        raise DocumentError(
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
        raise DocumentError(
            "lock-changed",
            "the lock changed while it was being cleared; it was left alone",
            lock_ref=ref,
            observed=observed,
        )
    return {"status": "cleared", "lock_ref": ref, "lock_owner": holder}


# ------------------------------------------------------------------- state --


def blob_at(root: Path, revision: str, document: str) -> str | None:
    """The document's blob at `revision`, or None when it is absent there. An
    absent path is not an empty baseline: it only means the revision does not
    carry the document yet."""
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
        raise DocumentError(
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
            raise DocumentError(
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
            raise DocumentError(
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
            raise DocumentError(
                "document-changed-before-write",
                f"{document} was recreated by another writer during the swap; "
                "that file was left in place and nothing was published",
                preserved_blob=preserved,
            ) from None
    except OSError as error:
        raise DocumentError(
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
                if isinstance(in_flight, DocumentError):
                    in_flight.detail.setdefault("captured_file", str(aside))
                    in_flight.detail.setdefault("captured_blob", captured_blob)
            # If it could not be put back, the temporary stays: the content is
            # in the object database either way, but deleting the only file
            # copy on the way out of a failure would be the worst thing this
            # module could do.

# ---------------------------------------------------------- pending record --


def remote_ref(branch: str) -> str:
    return f"origin/{branch}"


def read_ref(root: Path, ref: str) -> str:
    """The object a reference names, or the empty string when it is absent."""
    return git(
        ["rev-parse", "--verify", "--quiet", ref], cwd=root, check=False
    ).stdout.decode().strip()


def default_message(document: str) -> str:
    return f"docs: publish the approved mutation to {document}"


def receipt_line(pending: dict) -> str:
    """The one line that binds a commit on the branch to a recorded attempt.

    Repository, document, approved blob and the attempt's own identifier all
    travel in it. The blob alone would let a different document that happens to
    hold the same bytes, or an earlier attempt at this one, stand in for the
    publication the record is waiting on.
    """
    payload = json.dumps(
        {
            "attempt": pending["attempt"],
            "blob": pending["approved_blob"],
            "document": pending["document"],
            "repository": pending["repository"],
        },
        sort_keys=True,
        separators=(",", ":"),
    )
    return f"{RECEIPT_TRAILER}: {payload}"


def build_pending_commit(root: Path, document: str, fields: dict) -> str:
    """A parentless commit whose tree is the document at the approved blob and
    whose message carries the record.

    Commit-shaped so it sits in the namespace the publisher's preflight already
    reads, and so the approved bytes are retained by object reachability rather
    than by an object name a prune could orphan. It has no parent on purpose:
    the publisher resuming such a record would otherwise read a parent as its
    pinned tip and push the commit, which is the one thing this module exists
    to take out of that tool's hands. Without a parent the publisher stops.

    Built through a scratch index in the common Git directory, so the write
    root's own index is never touched.
    """
    try:
        handle, scratch_name = tempfile.mkstemp(
            prefix="kanban-approved-index-", dir=str(common_git_dir(root))
        )
        os.close(handle)
    except OSError as error:
        raise DocumentError(
            "scratch-index-unavailable",
            f"a scratch index for {document} could not be created: {error}",
        ) from error
    scratch = Path(scratch_name)
    env = dict(os.environ, GIT_INDEX_FILE=str(scratch))
    try:
        # mkstemp leaves an empty file, which git reads as a corrupt index.
        scratch.unlink()
        update = subprocess.run(
            [
                "git", "update-index", "--add", "--cacheinfo",
                f"100644,{fields['approved_blob']},{document}",
            ],
            cwd=str(root), capture_output=True, env=env,
        )
        if update.returncode != 0:
            raise DocumentError(
                "git-failed",
                f"git update-index failed: {update.stderr.decode().strip()}",
            )
        tree = subprocess.run(
            ["git", "write-tree"], cwd=str(root), capture_output=True, env=env
        )
        if tree.returncode != 0:
            raise DocumentError(
                "git-failed", f"git write-tree failed: {tree.stderr.decode().strip()}"
            )
    finally:
        _quietly(scratch.unlink, missing_ok=True)
    body = json.dumps(fields, sort_keys=True, separators=(",", ":"))
    return git_out(
        ["commit-tree", tree.stdout.decode().strip()],
        cwd=root,
        input_bytes=f"{PENDING_SUBJECT}\n\n{body}\n".encode(),
    )


def _malformed(ref: str, commit: str, why: str) -> DocumentError:
    return DocumentError(
        "pending-malformed",
        f"the pending publication at {ref} {why}; it cannot be interpreted and "
        "must be resolved by hand",
        pending_ref=ref,
        pending_commit=commit,
    )


def read_pending(root: Path, owner: str, document: str) -> dict | None:
    """The pending publication recorded for this document, or None.

    Both forms are recognized: this module's own record, and the publisher's
    commit-shaped one. A record that is neither, or that does not name the
    document it is keyed under, is reported rather than read as absent — an
    absent record is the one conclusion a caller deciding whether it may write
    must never reach by accident.
    """
    ref = pending_ref(owner, document)
    commit = read_ref(root, ref)
    if not commit:
        return None
    kind = git(["cat-file", "-t", commit], cwd=root, check=False)
    if kind.stdout.decode().strip() != "commit":
        raise _malformed(ref, commit, "does not name a commit")
    raw = git_out(["cat-file", "commit", commit], cwd=root)
    _, _, message = raw.partition("\n\n")
    subject, _, body = message.partition("\n")
    recorded = blob_at(root, commit, document)
    if recorded is None:
        raise _malformed(ref, commit, f"does not carry {document}")
    if subject.strip() != PENDING_SUBJECT:
        parent = git(["rev-parse", f"{commit}^"], cwd=root, check=False)
        if parent.returncode != 0:
            raise _malformed(
                ref, commit, "is neither this module's record nor a publisher commit"
            )
        return {
            "form": FORM_PUBLISHER, "ref": ref, "commit": commit,
            "repository": owner, "document": document, "approved_blob": recorded,
            "baseline": None, "rendered_tip": parent.stdout.decode().strip(),
            "attempt": None, "message": None,
        }
    try:
        fields = json.loads(body)
    except json.JSONDecodeError as error:
        raise _malformed(ref, commit, f"is not valid JSON ({error})") from error
    if not isinstance(fields, dict) or fields.get("version") != PENDING_VERSION:
        raise _malformed(ref, commit, f"is not a version {PENDING_VERSION} record")
    for name in ("repository", "document", "approved_blob", "rendered_tip", "attempt"):
        if not isinstance(fields.get(name), str) or not fields[name]:
            raise _malformed(ref, commit, f"has no {name}")
    if fields["repository"] != owner or fields["document"] != document:
        raise _malformed(
            ref, commit,
            f"records {fields['repository']}:{fields['document']}, not the "
            f"{owner}:{document} it is keyed under",
        )
    baseline = fields.get("baseline")
    if baseline is not None and (not isinstance(baseline, str) or not OID_RE.match(baseline)):
        raise _malformed(ref, commit, "has an unusable baseline")
    if (
        not OID_RE.match(fields["approved_blob"])
        or not OID_RE.match(fields["rendered_tip"])
        or not ATTEMPT_RE.match(fields["attempt"])
    ):
        raise _malformed(ref, commit, "has an identifier that is not an object name")
    if fields["approved_blob"] != recorded:
        raise _malformed(
            ref, commit,
            f"names approved blob {fields['approved_blob']} but its tree holds "
            f"{recorded}",
        )
    if (
        git(
            ["cat-file", "-e", f"{fields['rendered_tip']}^{{commit}}"],
            cwd=root, check=False,
        ).returncode
        != 0
    ):
        raise DocumentError(
            "pending-unverifiable",
            f"the pending publication for {document} names a tip "
            f"({fields['rendered_tip'][:12]}) this repository does not have, so "
            "whether it landed cannot be decided",
            pending_ref=ref,
            pending_commit=commit,
        )
    message_text = fields.get("message")
    return {
        "form": FORM_HELPER, "ref": ref, "commit": commit,
        "repository": owner, "document": document,
        "approved_blob": fields["approved_blob"], "baseline": baseline,
        "rendered_tip": fields["rendered_tip"], "attempt": fields["attempt"],
        "message": message_text if isinstance(message_text, str) else None,
    }


def new_pending_fields(
    owner: str, document: str, approved_blob: str, baseline: str | None,
    rendered_tip: str, message: str,
) -> dict:
    return {
        "version": PENDING_VERSION,
        "repository": owner,
        "document": document,
        "approved_blob": approved_blob,
        "baseline": baseline,
        "rendered_tip": rendered_tip,
        "attempt": os.urandom(16).hex(),
        "message": message,
    }


# ------------------------------------------------------------------ landing --


def find_receipt(root: Path, remote: str, pending: dict) -> str | None:
    """The commit on `remote`, since the recorded tip, that carries this
    attempt's marker, or None.

    Searched over the complete reachable range, and the marker must be a whole
    line of the message rather than a substring of one. The oldest match wins: the
    tool is only invoked while nothing has landed, so a second match could only
    be a copy of the first.
    """
    document = pending["document"]
    # The whole reachable range, with no path limit: a path-limited log applies
    # history simplification, and a merge that kept an older copy of the
    # document through its first parent hides a receipt that is reachable
    # through its second. The receipt's scope is validated below instead.
    log = git_out(
        [
            "log", "--format=%H%x1f%B%x1e",
            f"{pending['rendered_tip']}..{remote}",
        ],
        cwd=root,
    )
    expected = receipt_line(pending)
    matches = []
    for entry in log.split("\x1e"):
        commit, separator, body = entry.strip().partition("\x1f")
        if separator and expected in body.splitlines():
            matches.append(commit.strip())
    if not matches:
        return None
    receipt = matches[-1]
    # NUL-delimited, never Git's display form: under the default
    # core.quotePath a path with a non-ASCII byte or a quote comes back quoted
    # and escaped, and comparing that to the document's own spelling rejects a
    # valid receipt.
    listing = git(
        ["diff-tree", "-z", "--no-commit-id", "--name-only", "-r", "--root", receipt],
        cwd=root,
    ).stdout.decode("utf-8", errors="surrogateescape")
    touched = [entry for entry in listing.split("\0") if entry]
    if touched != [document]:
        raise DocumentError(
            "receipt-unverifiable",
            f"the commit {receipt[:12]} carries this attempt's marker but changes "
            f"{touched} rather than {document} alone, so it is not a publication "
            "of this document",
            receipt_commit=receipt,
            changed_paths=touched,
        )
    return receipt


def landing(root: Path, branch: str, pending: dict) -> dict:
    """Whether the recorded mutation has reached `origin/<branch>`, and the blob
    that was published when it has.

    The caller fetches first. Reachability is the whole verdict, and the
    published blob comes from the receipt commit itself, so a later same-document
    advance changes neither the answer nor the blob it names.
    """
    remote = remote_ref(branch)
    document = pending["document"]
    approved = pending["approved_blob"]
    tip_reachable = is_ancestor(root, pending["rendered_tip"], remote)
    if pending["form"] == FORM_PUBLISHER:
        if is_ancestor(root, pending["commit"], remote):
            return {
                "landed": True, "via": "recorded-commit", "published_blob": approved,
                "receipt_commit": pending["commit"],
            }
    elif tip_reachable:
        receipt = find_receipt(root, remote, pending)
        if receipt is not None:
            published = blob_at(root, receipt, document)
            if published is None:
                raise DocumentError(
                    "receipt-unverifiable",
                    f"the receipt commit {receipt[:12]} does not carry {document}",
                    receipt_commit=receipt,
                )
            return {
                "landed": True, "via": "receipt", "published_blob": published,
                "receipt_commit": receipt,
            }
    # "Nothing to land": the branch carries the approved blob at this path now,
    # or carried it at the tip the record was made against. The second half is
    # what keeps the verdict across an interruption: a later edit that moves the
    # document away from those bytes does not un-establish that the mutation
    # was already there, and republishing would reinstate it over that edit.
    for revision in (remote, pending["rendered_tip"]):
        if tip_reachable or revision == remote:
            present = blob_at(root, revision, document)
            if present is not None and present == approved:
                return {
                    "landed": True, "via": "already-present", "published_blob": approved,
                    "receipt_commit": None,
                }
    if not tip_reachable:
        raise DocumentError(
            "pending-stale",
            f"the tip this publication of {document} was recorded against "
            f"({pending['rendered_tip'][:12]}) is not in the history of {remote}, "
            "so whether it landed cannot be verified; the record is kept",
            pending_ref=pending["ref"],
            rendered_tip=pending["rendered_tip"],
        )
    return {"landed": False, "via": None, "published_blob": None, "receipt_commit": None}


# --------------------------------------------------------------------- tool --


def publication_tool() -> dict:
    """The tool this module hands a document to, and whether it can be trusted
    to honour the two guarantees the contract rests on.

    `--expect` is what lands the approved bytes rather than whatever the file
    holds by then, and `--keep` is what leaves the merged copy where the
    document is read from. A tool without either is reported, never worked
    around.
    """
    path = shutil.which("docs-push")
    if path is None:
        return {
            "available": False, "reason": "tool-missing",
            "message": f"{TOOL} was not found on PATH",
        }
    try:
        proc = subprocess.run([path, "--help"], capture_output=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as error:
        return {
            "available": False, "path": path, "reason": "tool-unusable",
            "message": f"{TOOL} --help could not be run: {error}",
        }
    help_text = (proc.stdout + proc.stderr).decode(errors="replace")
    lacking = [flag for flag in TOOL_CAPABILITIES if flag not in help_text]
    if proc.returncode != 0 or lacking:
        return {
            "available": False, "path": path, "reason": "tool-lacks-capability",
            "message": (
                f"{path} does not offer {' or '.join(lacking)}; this module needs "
                f"{' and '.join(TOOL_CAPABILITIES)} to land exactly the approved "
                "bytes"
                if lacking
                else f"{path} --help exited {proc.returncode}"
            ),
        }
    return {"available": True, "path": path}


def run_publication_tool(root: Path, document: str, blob: str, message: str) -> dict:
    """Run `docs-push --expect <blob> --keep -m <message> <document>` from the
    write root. The result describes what happened; it does not say whether the
    document landed."""
    tool = publication_tool()
    if not tool["available"]:
        return {"ran": False} | tool
    try:
        proc = subprocess.run(
            [tool["path"], "--expect", blob, "--keep", "-m", message, document],
            cwd=str(root), capture_output=True, timeout=TOOL_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return {
            "ran": False, "path": tool["path"], "reason": "tool-failed",
            "message": f"{TOOL} could not be run to completion: {error}",
        }
    output = (proc.stdout + proc.stderr).decode(errors="replace").strip()
    return {
        "ran": True, "path": tool["path"], "returncode": proc.returncode,
        "message": output,
    }


# ----------------------------------------------------------------- outcomes --


def document_state(root: Path, document: str) -> dict:
    return {
        "document_edit": {
            "exists": (root / document).is_file(),
            "write_root": str(root),
            "path": document,
            "blob": working_blob(root, document),
        }
    }


def incomplete(
    root: Path, owner: str, branch: str, document: str, pending: dict, tool: dict,
    *, reachable: bool | None, landing_error: str | None = None,
) -> dict:
    """The approved content is applied and recorded and the tool did not land
    it. Reported as an outcome, with the tool's own words, and nothing more is
    attempted."""
    if not tool.get("ran"):
        reason = tool.get("reason", "tool-failed")
    elif tool.get("returncode") != 0:
        reason = "tool-refused"
    elif landing_error is not None:
        reason = "landing-unverifiable"
    else:
        reason = "tool-reported-success-without-landing"
    return {
        "status": "incomplete-publication",
        "reason": reason,
        "message": tool.get("message") or landing_error or "",
        "tool": {
            "path": tool.get("path"), "ran": tool.get("ran", False),
            "returncode": tool.get("returncode"),
        },
        "landing_error": landing_error,
        "repository": owner,
        "branch": branch,
        "document": document,
        "publication_tip": pending["rendered_tip"],
        "approved_blob": pending["approved_blob"],
        "published_blob": None,
        "pending_ref": pending["ref"],
        "pending_commit": pending["commit"],
        "applied_ref": applied_ref(owner, document),
        "remote_branch": remote_ref(branch),
        "remote_contains_commit": reachable,
        "resolution": (
            "the approved content is applied to the write root and its records "
            "are kept; nothing was published and nothing was pushed by other "
            f"means. Fix what {TOOL} reported and re-run this module with the "
            "same content (or --resume) to retry, or land the document through "
            "its owner's own lane"
        ),
    } | document_state(root, document)


def settle_landed(
    root: Path, owner: str, branch: str, document: str, pending: dict, info: dict
) -> dict:
    """Drop the records of a publication that is verified to have landed, but
    only from a write root that still holds what was published.

    Reachability is settled by now. What is not settled is the write root: the
    tool's `--keep` leaves the merged copy there, and an outside process can
    change or stage the document between that and this call. Clearing the
    record then would leave the divergence with nothing pointing at it.
    """
    published = info["published_blob"]
    if working_blob(root, document) != published or staged_blob(
        root, document
    ) != head_blob(root, document):
        raise DocumentError(
            "landed-but-divergent",
            f"{document} reached {branch}, but the write root no longer holds the "
            "published copy or has staged changes to it; the record is kept so "
            "the divergence is not lost",
            remote_contains_commit=True,
            approved_blob=pending["approved_blob"],
            published_blob=published,
            receipt_commit=info["receipt_commit"],
            pending_ref=pending["ref"],
            pending_commit=pending["commit"],
        )
    cleared = {"applied": "absent"}
    applied = read_applied(root, owner, document)
    if applied is not None:
        if applied == pending["approved_blob"]:
            proc = git(
                ["update-ref", "-d", applied_ref(owner, document), applied],
                cwd=root, check=False,
            )
            if proc.returncode != 0:
                raise DocumentError(
                    "record-retained",
                    f"{document} reached {branch}, but its applied record could "
                    "not be cleared; the next run's preflight will report it",
                    remote_contains_commit=True,
                    published_blob=published,
                    applied_ref=applied_ref(owner, document),
                    pending_ref=pending["ref"],
                )
            cleared["applied"] = "cleared"
        else:
            cleared["applied"] = "kept: it names other content"
    proc = git(
        ["update-ref", "-d", pending["ref"], pending["commit"]], cwd=root, check=False
    )
    if proc.returncode != 0:
        raise DocumentError(
            "record-retained",
            f"{document} reached {branch}, but its pending record could not be "
            "cleared; the next run's preflight will stop until it is resolved",
            remote_contains_commit=True,
            published_blob=published,
            pending_ref=pending["ref"],
            pending_commit=pending["commit"],
        )
    cleared["pending"] = "cleared"
    return cleared


def published_outcome(
    root: Path, owner: str, branch: str, document: str, pending: dict, info: dict,
    cleared: dict, *, resumed: str | None, tool: dict | None,
) -> dict:
    return {
        "status": "published",
        "repository": owner,
        "branch": branch,
        "document": document,
        "publication_tip": pending["rendered_tip"],
        "approved_blob": pending["approved_blob"],
        "published_blob": info["published_blob"],
        # `docs-push` merges three ways, so the two legitimately differ; the
        # result reports both rather than requiring them equal.
        "merged": info["published_blob"] != pending["approved_blob"],
        "landed_via": info["via"],
        "receipt_commit": info["receipt_commit"],
        "remote_contains_commit": True,
        "resumed": resumed,
        "records": cleared,
        "tool": None
        if tool is None
        else {
            "path": tool.get("path"), "ran": tool.get("ran", False),
            "returncode": tool.get("returncode"), "message": tool.get("message"),
        },
    } | document_state(root, document)


# ----------------------------------------------------------------- sequence --


def publish_recorded(
    root: Path, owner: str, branch: str, document: str, pending: dict,
    *, resumed: str | None,
) -> dict:
    """The record exists and the document holds the approved blob: land it, or
    recognize that it already landed."""
    info = landing(root, branch, pending)
    if info["landed"]:
        cleared = settle_landed(root, owner, branch, document, pending, info)
        return published_outcome(
            root, owner, branch, document, pending, info, cleared,
            resumed=resumed or "already-landed", tool=None,
        )
    # Every attempt, not only the one that writes: a resume finds the document
    # already holding the approved bytes, and an index entry staged since then
    # is work the tool's settling and the cleanup below would carry or lose.
    require_unstaged(root, document)
    base = pending["message"] or default_message(document)
    tool = run_publication_tool(
        root, document, pending["approved_blob"], f"{base}\n\n{receipt_line(pending)}"
    )
    try:
        git(["fetch", "origin", branch], cwd=root)
        info = landing(root, branch, pending)
    except DocumentError as error:
        # The push may have succeeded. The record is what a later run verifies
        # against, so it stays and the outcome says the answer is unknown.
        return incomplete(
            root, owner, branch, document, pending, tool, reachable=None,
            landing_error=error.message,
        )
    if not info["landed"]:
        return incomplete(root, owner, branch, document, pending, tool, reachable=False)
    cleared = settle_landed(root, owner, branch, document, pending, info)
    return published_outcome(
        root, owner, branch, document, pending, info, cleared,
        resumed=resumed, tool=tool,
    )


def validate_applied(root: Path, owner: str, document: str) -> str | None:
    """The applied record, when there is one and it is usable.

    A record names a blob of applied content. One naming anything else is
    reported and left exactly where it is: replacing it would destroy the only
    evidence of what wrote it, and clearing it later would do so silently.
    """
    ref = applied_ref(owner, document)
    recorded = read_ref(root, ref)
    if not recorded:
        return None
    kind = git(["cat-file", "-t", recorded], cwd=root, check=False)
    if kind.stdout.decode().strip() != "blob":
        raise DocumentError(
            "applied-malformed",
            f"the applied record {ref} names {recorded}, which is not a blob of "
            "applied content; it cannot be interpreted and is left as it is "
            "until it is resolved by hand",
            applied_ref=ref,
            applied_object=recorded,
        )
    return recorded


def record_applied_content(root: Path, owner: str, document: str, blob: str) -> str:
    if read_applied(root, owner, document) == blob:
        return "recorded"
    return "recorded" if record_applied(root, owner, document, blob) else "unrecorded"


def upgrade_publisher_record(
    root: Path, owner: str, document: str, pending: dict, message: str
) -> dict:
    """Re-seat the publisher's commit-shaped record as this module's own, so the
    resumption has an attempt to mark. Bound to the value just read: a record
    that changed in between is reported, not overwritten."""
    fields = new_pending_fields(
        owner, document, pending["approved_blob"],
        blob_at(root, pending["rendered_tip"], document), pending["rendered_tip"],
        message,
    )
    commit = build_pending_commit(root, document, fields)
    proc = git(
        ["update-ref", pending["ref"], commit, pending["commit"]], cwd=root, check=False
    )
    if proc.returncode != 0:
        raise DocumentError(
            "pending-changed",
            f"the pending publication for {document} changed while it was being "
            "resumed; it was left as it is",
            pending_ref=pending["ref"],
        )
    reread = read_pending(root, owner, document)
    if reread is None or reread["commit"] != commit:
        raise DocumentError(
            "pending-changed",
            f"the pending publication for {document} could not be re-read after "
            "it was resumed",
            pending_ref=pending["ref"],
        )
    return reread


def resume_pending(
    root: Path, owner: str, branch: str, document: str, pending: dict,
    approved_blob: str, content: bytes, message: str,
) -> dict:
    """An earlier run recorded a mutation of this document. Finish it, or stop
    with a report: never write something else over it."""
    info = landing(root, branch, pending)
    if pending["approved_blob"] != approved_blob:
        # The caller is approving a different disposition from the one the
        # record names. Publishing the record instead would report success
        # while the new mutation never reached the document, and by now the
        # caller has already mutated the tracker for it.
        raise DocumentError(
            "pending-differs-from-approved",
            f"an earlier mutation of {document} is recorded and "
            + ("has already landed" if info["landed"] else "has not landed")
            + ", and the content supplied now is not it; resume that record "
            "(--resume) before approving a different disposition",
            recorded_blob=pending["approved_blob"],
            approved_blob=approved_blob,
            remote_contains_commit=info["landed"],
            pending_ref=pending["ref"],
            pending_commit=pending["commit"],
        )
    if info["landed"]:
        cleared = settle_landed(root, owner, branch, document, pending, info)
        return published_outcome(
            root, owner, branch, document, pending, info, cleared,
            resumed="already-landed", tool=None,
        )
    current = working_blob(root, document)
    resumed = "applied"
    if current != approved_blob:
        baseline = (
            pending["baseline"]
            if pending["form"] == FORM_HELPER
            else blob_at(root, pending["rendered_tip"], document)
        )
        if baseline is None or current != baseline:
            raise DocumentError(
                "document-not-baseline",
                f"{document} is neither the baseline the pending publication was "
                "recorded over nor the approved content it names, so it carries "
                "work beyond the approved mutation; it was left untouched",
                recorded_blob=pending["approved_blob"],
                baseline_blob=baseline,
                working_blob=current,
                pending_ref=pending["ref"],
                pending_commit=pending["commit"],
                preserved_blob=_preserve(root, (root / document).read_bytes())
                if (root / document).is_file()
                else None,
            )
        require_unstaged(root, document)
        verify_and_write(root, document, baseline, content)
        resumed = "applied-on-resume"
    if pending["form"] == FORM_PUBLISHER:
        pending = upgrade_publisher_record(root, owner, document, pending, message)
        resumed = f"{resumed}; publisher record re-seated"
    record_applied_content(root, owner, document, approved_blob)
    return publish_recorded(
        root, owner, branch, document, pending, resumed=f"resumed: {resumed}"
    )


def start_fresh(
    root: Path, owner: str, branch: str, tip: str, document: str, approved_blob: str,
    content: bytes, message: str, expected_working_copy: str | None,
    expected_tip: str | None,
) -> dict:
    """No record exists: bind the content to its baseline, record the intent,
    replace the document, record the application, then publish."""
    if not expected_working_copy:
        # Not optional, and absent does not mean "skip the check": a caller that
        # fails to carry the preflight's blob would otherwise write over bytes
        # nobody observed.
        raise DocumentError(
            "baseline-required",
            "--expected-working-copy is required: pass the working_copy_blob the "
            "preflight reported, so the approved content is written only over the "
            "bytes it was rendered from",
        )
    current = working_blob(root, document)
    if current is None:
        raise DocumentError(
            "no-baseline",
            f"{document} does not exist under {root}; this module never creates a "
            "document, so nothing was written",
        )
    if current != expected_working_copy:
        raise DocumentError(
            "document-changed-before-write",
            f"{document} is no longer the content the preflight observed "
            f"({expected_working_copy[:12]}, now {current[:12]}); nothing was "
            "written and nothing was published",
            preserved_blob=_preserve(root, (root / document).read_bytes()),
        )
    require_unstaged(root, document)
    if approved_blob == current:
        raise DocumentError(
            "no-mutation",
            f"the approved content for {document} is identical to the content it "
            "would replace; there is nothing to apply or publish",
        )
    rendered_tip = tip
    if expected_tip is not None:
        if (
            git(
                ["cat-file", "-e", f"{expected_tip}^{{commit}}"], cwd=root, check=False
            ).returncode
            != 0
            or not is_ancestor(root, expected_tip, remote_ref(branch))
        ):
            raise DocumentError(
                "tip-unverifiable",
                f"the tip the content was prepared against ({expected_tip[:12]}) "
                f"is not in the history of {remote_ref(branch)}, so a landing "
                "could not be verified against it; re-run the preflight",
                expected_tip=expected_tip,
            )
        rendered_tip = expected_tip
    fields = new_pending_fields(
        owner, document, approved_blob, current, rendered_tip, message
    )
    commit = build_pending_commit(root, document, fields)
    ref = pending_ref(owner, document)
    # Recoverable intent first, create-only: from here an interruption at any
    # point leaves a record whose tree retains the approved bytes.
    if git(["update-ref", ref, commit, ""], cwd=root, check=False).returncode != 0:
        raise DocumentError(
            "pending-exists",
            f"a pending publication appeared for {document} while this run held "
            "its lock; it was left as it is",
            pending_ref=ref,
        )
    try:
        verify_and_write(root, document, current, content)
    except DocumentError:
        # Nothing was applied, so no obligation exists. When the document is
        # the approved content (an unmodelled failure after the swap) the record
        # is exactly what recovery needs and stays.
        if working_blob(root, document) != approved_blob:
            git(["update-ref", "-d", ref, commit], cwd=root, check=False)
        raise
    pending = read_pending(root, owner, document)
    if pending is None:
        raise DocumentError(
            "pending-changed", f"the pending record for {document} vanished", pending_ref=ref
        )
    applied = record_applied_content(root, owner, document, approved_blob)
    outcome = publish_recorded(root, owner, branch, document, pending, resumed=None)
    return outcome | {"applied_record": applied, "write_outcome": "applied-over-baseline"}


def locked_sequence(
    *, root: Path, owner: str, branch: str, tip: str, document: str,
    content: bytes | None, message: str | None, expected_working_copy: str | None,
    expected_tip: str | None,
) -> dict:
    pending = read_pending(root, owner, document)
    validate_applied(root, owner, document)
    if content is None:
        if pending is None:
            raise DocumentError(
                "no-pending-publication",
                f"no pending publication is recorded for {document}, so there is "
                "nothing to resume",
                pending_ref=pending_ref(owner, document),
            )
        # The record's tree retains the approved bytes; resuming needs nothing
        # from the caller.
        content = git(
            ["cat-file", "blob", pending["approved_blob"]], cwd=root
        ).stdout
    approved_blob = git_blob_hash(content)
    # The bytes go into the object database before anything else can fail, so a
    # refusal below does not lose the approved mutation.
    stored = _preserve(root, content)
    if stored != approved_blob:
        raise DocumentError(
            "content-hash-mismatch",
            f"the approved content hashed to {approved_blob} but the object "
            f"database stored {stored}",
        )
    message = message or (pending["message"] if pending else None) or default_message(
        document
    )
    if pending is not None:
        return resume_pending(
            root, owner, branch, document, pending, approved_blob, content, message
        )
    return start_fresh(
        root, owner, branch, tip, document, approved_blob, content, message,
        expected_working_copy, expected_tip,
    )


def failure_states(root: Path, document: str, *, branch: str, reachable) -> dict:
    """The three states a caller must report for any outcome short of
    published: where the document is, what the records are, and whether the
    branch carries the mutation. Absent is a state, not a missing field."""
    return document_state(root, document) | {
        "remote_branch": remote_ref(branch),
        "remote_contains_commit": reachable,
    }


def apply_and_publish(
    *, repository: str, branch: str, root: Path, document: str,
    content: bytes | None, message: str | None = None,
    expected_working_copy: str | None = None, expected_tip: str | None = None,
) -> dict:
    """Apply one approved mutation and publish it through `docs-push`, or report
    why it was not published. `content=None` resumes the recorded mutation.

    Every failure leaves through the one handler below, including those raised
    before the lock is taken, so a caller told to report three states never
    receives a result that carries none.
    """
    try:
        resolved = resolve_write_root(root)
        owner = verify_owner(resolved, repository)
        git(["fetch", "origin", branch], cwd=resolved)
        tip = git_out(["rev-parse", remote_ref(branch)], cwd=resolved)
        lock = lock_ref(owner, document)
        held = acquire_lock(resolved, lock, tip, owner, document)
        try:
            outcome = locked_sequence(
                root=resolved, owner=owner, branch=branch, tip=tip, document=document,
                content=content, message=message,
                expected_working_copy=expected_working_copy, expected_tip=expected_tip,
            )
        except BaseException as error:
            # The lock must come off for anything that leaves this block,
            # including failures this module did not model; only a
            # DocumentError can carry the detail that it did not.
            if not release_lock(resolved, lock, held) and isinstance(
                error, DocumentError
            ):
                error.detail.setdefault("lock_retained", True)
                error.detail.setdefault("lock_ref", lock)
            raise
        if not release_lock(resolved, lock, held):
            raise DocumentError(
                "lock-retained",
                f"{document} was handled, but its publication lock could not be "
                "released; later runs will be blocked until it is cleared",
                outcome_status=outcome.get("status"),
                lock_retained=True,
                lock_ref=lock,
            )
        return outcome
    except Exception as error:  # noqa: BLE001 - the collector is the point
        if not isinstance(error, DocumentError):
            error = DocumentError("internal-error", f"{type(error).__name__}: {error}")
        try:
            states = failure_states(
                Path(git_out(["rev-parse", "--show-toplevel"], cwd=root)),
                document, branch=branch,
                reachable=error.detail.get("remote_contains_commit"),
            )
        except Exception:
            states = {
                "document_edit": {"exists": None, "write_root": str(root), "path": document},
                "remote_branch": remote_ref(branch),
                "remote_contains_commit": error.detail.get("remote_contains_commit"),
            }
        error.detail = {**states, **error.detail}
        raise error


# ---------------------------------------------------------------- preflight --


def tracker_transaction_module():
    """tools/tracker_transaction.py, loaded from beside this file.

    A plain `import` would need `tools/` on `sys.path`, which it is when this
    module runs as a script from the repository and is not when a bundled copy
    runs from a plugin install. The dependency is one-way: that module never
    loads this one, so two independently invocable tools do not become
    mutually dependent, at the cost of each keeping its own copy of the
    (repository, document) digest. tools/test_approved_document.py pins them
    equal.
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
        raise DocumentError(
            "tracker-transaction-unavailable",
            f"the tracker transaction module at {source} could not be loaded "
            f"({error}); the preflight cannot report whether one is outstanding",
        ) from error
    return module


def check_pending(root: Path, repository: str, branch: str, document: str) -> dict:
    """Whether an earlier approved mutation of this document is outstanding —
    its publication, its tracker mutations, or both.

    Callers mutate the tracker before they publish, so this has to be askable
    before they do. It writes nothing and takes no lock. `status` is exactly
    `clear` or `pending`, `publication_tip` is the freshly fetched tip, and
    `working_copy_blob` is the baseline the caller passes back as
    `--expected-working-copy`.

    A tool or module that cannot be read fails closed, with the records already
    read attached: the caller's reason for asking is whether it may mutate the
    tracker, and a tool that cannot land the document is a reason to stop
    before the first irreversible step, not after it.
    """
    resolved = resolve_write_root(root)
    owner = verify_owner(resolved, repository)
    pending_name = pending_ref(owner, document)
    module = tracker_transaction_module()
    try:
        tracker = module.check(resolved, repository, document)
    except Exception as error:  # noqa: BLE001 - the preflight must stay structured
        tracker = {
            "status": "outstanding",
            "message": getattr(error, "message", str(error)),
        } | module.observed_report(resolved, module.transaction_ref(owner, document))
    record, record_fault = None, None
    try:
        record = read_pending(resolved, owner, document)
        validate_applied(resolved, owner, document)
    except DocumentError as error:
        record_fault = error
    kinds = []
    if record is not None or record_fault is not None:
        kinds.append("publication")
    if tracker["status"] != "clear":
        kinds.append("tracker-transaction")
    try:
        # Not check=False: the tip this returns becomes the caller's binding,
        # and one minted from a stale cached ref reads as current.
        git(["fetch", "origin", branch], cwd=resolved)
        observed_tip = git_out(["rev-parse", remote_ref(branch)], cwd=resolved)
        outcome = {
            "status": "pending" if kinds else "clear",
            "document": document,
            "pending_ref": pending_name,
            "publication_tip": observed_tip,
            "working_copy_blob": working_blob(resolved, document),
            "pending_kinds": kinds,
            "tracker_transaction": tracker,
        }
        if record_fault is not None:
            outcome |= {
                "pending_commit": read_ref(resolved, pending_name),
                "record_fault": {
                    "status": record_fault.status, "message": record_fault.message,
                },
                "resolution": (
                    f"{record_fault.message}. Stop: no further disposition of this "
                    "document is permitted until the record is resolved by hand"
                ),
            }
        elif record is not None:
            try:
                info = landing(resolved, branch, record)
                fault = None
            except DocumentError as error:
                info, fault = None, error
            landed = None if info is None else info["landed"]
            outcome |= {
                "pending_commit": record["commit"],
                "record_form": record["form"],
                "recorded_blob": record["approved_blob"],
                "already_landed": landed,
                "published_blob": None if info is None else info["published_blob"],
                "applied_blob": read_applied(resolved, owner, document),
                "resolution": (
                    "the recorded publication reached the branch; run --resume to "
                    "verify it and clear the record"
                    if landed
                    else f"{fault.message}. Stop: resolve the record by hand"
                    if fault is not None
                    else "run --resume to retry the recorded publication through "
                    f"{TOOL}, or clear the record deliberately; do not approve a "
                    "different disposition for this document first"
                ),
            }
            if fault is not None:
                outcome["record_fault"] = {
                    "status": fault.status, "message": fault.message,
                }
    except Exception as error:  # noqa: BLE001 - the report survives the failure
        if not isinstance(error, DocumentError):
            error = DocumentError("internal-error", f"{type(error).__name__}: {error}")
        error.detail.setdefault("pending_kinds", kinds)
        error.detail.setdefault("tracker_transaction", tracker)
        raise error
    tool = publication_tool()
    outcome["publication_tool"] = tool
    if not tool["available"]:
        raise DocumentError(
            "publication-tool-unavailable",
            f"{tool['message']}; nothing could be published, so no disposition of "
            "this document should start",
            **{k: v for k, v in outcome.items() if k != "status"},
            tool_reason=tool["reason"],
        )
    return outcome


# ------------------------------------------------------------- command line --


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Apply one approved document mutation and publish it with docs-push."
    )
    parser.add_argument("--repo", required=True, help="the owning owner/name")
    parser.add_argument("--branch", help="the default branch")
    parser.add_argument("--root", required=True, type=Path, help="the local write root")
    parser.add_argument("--path", required=True, help="repository-relative document")
    parser.add_argument("--content", type=Path, help="file holding the approved content")
    parser.add_argument("--message", default=None)
    parser.add_argument(
        "--expected-working-copy",
        default=None,
        help="the preflight's working_copy_blob: the only bytes the approved "
        "content is written over",
    )
    parser.add_argument(
        "--expected-tip",
        default=None,
        help="the preflight's publication_tip, which the landing is verified "
        "from; the freshly fetched tip when omitted",
    )
    parser.add_argument(
        "--resume",
        action="store_true",
        help="finish the recorded mutation from its retained content",
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
            content = None
            if not args.resume:
                if args.content is None:
                    parser.error(
                        "--content is required unless --resume or "
                        "--clear-stale-lock is given"
                    )
                try:
                    content = args.content.read_bytes()
                except OSError as error:
                    raise DocumentError(
                        "content-unreadable",
                        f"the approved content at {args.content} could not be "
                        f"read: {error}",
                    ) from error
            outcome = apply_and_publish(
                repository=args.repo,
                branch=args.branch,
                root=args.root,
                document=args.path,
                content=content,
                message=args.message,
                expected_working_copy=args.expected_working_copy or None,
                expected_tip=args.expected_tip or None,
            )
    except Exception as error:  # noqa: BLE001 - the boundary is the point
        if not isinstance(error, DocumentError):
            error = DocumentError("internal-error", f"{type(error).__name__}: {error}")
        payload = {
            "document_edit": {
                "exists": None, "write_root": str(args.root), "path": args.path,
            },
            "remote_branch": remote_ref(args.branch) if args.branch else None,
            "remote_contains_commit": None,
        }
        payload.update(error.detail)
        payload.update({"status": error.status, "message": error.message})
        print(json.dumps(payload, indent=2, sort_keys=True, default=str))
        return 1
    print(json.dumps(outcome, indent=2, sort_keys=True, default=str))
    return 0 if outcome.get("status") in ("published", "cleared", "no-lock") else 1


if __name__ == "__main__":
    raise SystemExit(main())
