#!/usr/bin/env python3
"""Apply one approved document mutation and hand it to `docs-push`.

Run as:

    python3 <bundle>/approved_document.py \\
        --repo coghex/kanban --branch master \\
        --root <write-root> --path docs/ui-bugs.md \\
        --expected-working-copy <preflight working_copy_blob> \\
        --content <file holding the complete approved document>

Issue #830, slice B of #775; recovery contract in
docs/designs/approved_document_recovery_design.md. `tools/publish_coordination_doc.py`
is two things: a publication mechanism (eligibility, a commit built on the branch
tip, a push) and a document-write protocol every processing workflow relies on.
The owner's `docs-push` replaces the first. This module is the second, reduced
to what it owns:

- approved-content application that refuses to overwrite an outside edit, and
  keeps custody of every file it moves;
- per-document serialization;
- the durable `refs/kanban/pending-publication` intent record and
  `refs/kanban/applied-locally` blob record, and the `--check-pending` preflight
  that reports a publication record and a tracker transaction together; and
- the one call that hands a named document to `docs-push`.

It never constructs, signs or pushes a publication commit, never implements a
push or a merge, and never reads `workflow.direct_publication_paths`, §7 of
docs/agent-workflow-contract.md or `workflow.coordination_paths`. Whether a path
may land directly is `docs-push`'s decision; a refusal is an outcome this module
reports, not a lane it routes around. The publisher stays in place and keeps
working until slice C; this module reads, and coexists with, every record it
writes.

## One retained intent, and custody before every move

The pending record is the durable intent and the recovery journal. It is a
parentless commit whose tree roots the approved bytes, the baseline and any
captured foreign edit under fixed internal names, so an object is retained by
reachability and not by a name in JSON. It is created absent-only before the
document is touched, rewritten and deleted only by compare-and-swap, and is
never discarded because something later failed: an application error keeps it.

Before the document is moved, a capture descriptor naming an exclusively
reserved directory beside it, the scratch and aside files in it and the
originating worktree is persisted and read back. Custody of the document begins
at the rename, before any read; a Python flag set after the rename is not
evidence of anything. After a crash the exact recorded locations are inspected.
Files are installed and restored by exclusive link only, and a captured file is
unlinked only after its restoration or its retention is verified.

## The tool, and landing decided by evidence

The helper records a handoff marker, then the child's pid, start time and exact
argv, before it waits on `docs-push --expect <approved_blob> --keep -m <message>
<document>`. Landing is decided only by evidence in the freshly fetched
`origin/<default>`, over the interval from the recorded tip `R` (inclusive)
through the fetched tip: a receipt commit carrying this attempt's marker, or the
approved blob at the document's path. Saved evidence is validated by the same
rules as rediscovered evidence and takes precedence; invalid saved evidence
stops. The tool's output decides nothing. An automatic retry after a handoff
that did not land also needs the exact child to be gone and an affirmative
`non_fast_forward` rule on the publication branch.

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
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.parse
from pathlib import Path, PurePosixPath

LOCK_NAMESPACE = "refs/kanban/publish-lock"
PENDING_NAMESPACE = "refs/kanban/pending-publication"
ABANDONED_NAMESPACE = "refs/kanban/abandoned-publication"
FETCHED_NAMESPACE = "refs/kanban/fetched"

# What this module applied to a document and has not yet landed. A working tree
# is equally what a hand edit produces, so this reference is the difference: it
# names the exact content this module wrote, which is what lets
# tracker_transaction.py tell an applied disposition from somebody's edit.
APPLIED_NAMESPACE = "refs/kanban/applied-locally"

# The subject of this module's own pending record. A record under
# PENDING_NAMESPACE without it is the publisher's commit-shaped form, which is
# recognized and resumed rather than rejected. Version 1 (the paused branch's
# own form, whose tree holds the document at its own path) is read and migrated.
PENDING_SUBJECT = "kanban approved-document pending publication"
PENDING_VERSION = 2
FORM_HELPER = "approved-document"
FORM_PUBLISHER = "publish-coordination-doc"

# Internal tree entries of a version-2 record, under a fixed directory a
# document path may not use.
PAYLOAD_DIR = "kanban-approved-document"
PAYLOAD_NAMES = ("approved", "baseline", "captured", "predecessor", "predecessor-record")

# The trailer that names one publication attempt in the commit `docs-push`
# builds. Everything that identifies the attempt travels in it, so a receipt is
# bound to the record that asked for it and not merely to bytes that two
# documents can share.
RECEIPT_TRAILER = "Kanban-Approved-Document"

TOOL = "docs-push"
TOOL_CAPABILITIES = ("--expect", "--keep")
TOOL_TIMEOUT_SECONDS = 600
# How long a killed tool's pipes are awaited before something is taken to be holding them.
DESCENDANT_GRACE_SECONDS = 10

OID_RE = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")
ATTEMPT_RE = re.compile(r"^[0-9a-f]{32}$")
# A captured edit that a later capture displaced stays rooted under its own name.
CAPTURED_VERSION_RE = re.compile(r"^captured-[0-9]+$")
HANDOFF_STATES = ("marker", "running", "finished")


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


def ref_oid(root: Path, spec: str) -> str:
    """The object `spec` names, or the empty string when it is *verifiably*
    absent. A command that failed, or that said anything on stderr, is not
    absence: an unreadable reference raises, so that an outstanding record can
    never read as clear because the read broke."""
    proc = git(["rev-parse", "--verify", "--quiet", spec], cwd=root, check=False)
    out = proc.stdout.decode().strip()
    if proc.returncode == 0 and out:
        return out
    if proc.returncode == 1 and not out and not proc.stderr.strip():
        return ""
    raise DocumentError(
        "ref-unreadable",
        f"{spec} could not be read ({(proc.stderr or proc.stdout).decode(errors='replace').strip() or proc.returncode}); "
        "it is not treated as absent",
        ref=spec,
    )


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


def check_canonical(document: str) -> None:
    """One spelling per document. `./docs/a.md`, `docs//a.md` and `docs/a.md`
    name one file and would otherwise key three locks and three records; the
    helper and the tracker each refuse every spelling but the canonical one."""
    parts = document.split("/")
    if (
        not document
        or document.endswith("/")
        or any(part in ("", ".", "..") for part in parts)
    ):
        raise DocumentError(
            "document-name-unsupported",
            f"{document!r} is not the canonical repository-relative spelling of a "
            "file (no leading, repeated or trailing separators, no . or .. parts)",
        )


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
    check_canonical(document)
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
    return ref_oid(root, applied_ref(repository, document)) or None


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
    if not ref_oid(root, ref):
        return None
    subject = git_out(["log", "-1", "--format=%s", ref], cwd=root)
    try:
        owner = json.loads(subject)
    except json.JSONDecodeError:
        owner = None
    return owner if isinstance(owner, dict) else {"host": None, "pid": None, "raw": subject}


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
    observed = ref_oid(root, ref)
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
    if type(pid) is not int or pid <= 1:
        # A lock that names no usable owner does not show its owner is dead.
        raise DocumentError(
            "lock-owner-unusable",
            f"the lock names no usable owner process ({pid!r}), so it cannot be "
            "shown to be stale; it is left as it is",
            lock_ref=ref,
            lock_owner=holder,
        )
    if process_is_live(pid):
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
    return ref_oid(root, f"{revision}:{document}") or None


def working_blob(root: Path, document: str) -> str | None:
    target = root / document
    if not target.is_file():
        return None
    return git_out(["hash-object", "--", str(target)], cwd=root)


def index_entries(root: Path, document: str) -> list:
    """The document's index entries as (mode, object, stage): none when it is
    unindexed, more than one (or a non-zero stage) when it is unmerged."""
    listing = git(
        ["ls-files", "-s", "-z", "--", f":(literal){document}"], cwd=root
    ).stdout.decode("utf-8", errors="surrogateescape")
    entries = []
    for entry in listing.split("\0"):
        meta, _, _ = entry.partition("\t")
        fields = meta.split()
        if len(fields) == 3:
            entries.append(tuple(fields))
    return entries


def head_entry(root: Path, document: str):
    """(mode, object) of the document at HEAD, or None when HEAD lacks it."""
    listing = git(
        ["ls-tree", "-z", "HEAD", "--", f":(literal){document}"], cwd=root
    ).stdout.decode("utf-8", errors="surrogateescape")
    for entry in listing.split("\0"):
        meta, _, _ = entry.partition("\t")
        fields = meta.split()
        if len(fields) == 3:
            return fields[0], fields[2]
    return None


def index_differs(root: Path, document: str) -> bool:
    """Whether the index holds *any* change to the document: another blob, a
    mode-only change, a deletion, or an unresolved entry."""
    entries, head = index_entries(root, document), head_entry(root, document)
    if not entries:
        return head is not None
    if len(entries) == 1 and entries[0][2] == "0" and head is not None:
        return (entries[0][0], entries[0][1]) != head
    return True


def require_unstaged(root: Path, document: str) -> None:
    """Refuse a document with a staged change in the write root.

    The end state this module promises is that the document path is left
    unstaged, so the index entry must already match HEAD in blob *and* mode and
    must not be unmerged. Hashing only the working file misses an index-only edit
    — `git apply --cached` leaves the file itself untouched, and `update-index
    --chmod` changes nothing but a mode — and publishing over one would both
    carry somebody's unapproved staged work forward and break the single defined
    state reconciliation depends on.
    """
    if index_differs(root, document):
        raise DocumentError(
            "document-staged",
            f"{document} has a staged change in the write root; publication needs "
            "the document unstaged so its end state is defined",
            staged_entries=[list(entry) for entry in index_entries(root, document)],
            head_entry=head_entry(root, document),
        )


def is_ancestor(root: Path, commit: str, revision: str) -> bool:
    """Whether `commit` is `revision` or one of its ancestors. Only Git's
    verified answers count: 0 is yes, 1 is no, and any other outcome (a command
    that failed, an object that could not be read) is unknown and raises, so a
    broken comparison can never read as a negative."""
    proc = git(["merge-base", "--is-ancestor", commit, revision], cwd=root, check=False)
    if proc.returncode == 0:
        return True
    if proc.returncode == 1 and not proc.stderr.strip():
        return False
    raise DocumentError(
        "ancestry-unreadable",
        f"whether {commit[:12]} is an ancestor of {revision[:12]} could not be "
        f"decided ({proc.stderr.decode(errors='replace').strip() or proc.returncode})",
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




# ---------------------------------------------------------- pending record --


def remote_ref(branch: str) -> str:
    return f"origin/{branch}"


def read_ref(root: Path, ref: str) -> str:
    """The object a reference names, or the empty string when it is absent."""
    return ref_oid(root, ref)


def default_message(document: str) -> str:
    return f"docs: publish the approved mutation to {document}"


def check_supported_name(document: str) -> None:
    """Refuse a path this module cannot track, before anything is recorded or
    touched rather than halfway through a recovery."""
    check_canonical(document)
    parts = PurePosixPath(document).parts
    if (
        not document
        or "\n" in document
        or "\0" in document
        or document.startswith("/")
        or ".." in parts
        or (parts and parts[0] == PAYLOAD_DIR)
    ):
        raise DocumentError(
            "document-name-unsupported",
            f"{document!r} is not a repository-relative path this module can "
            "track (no newline, absolute, parent or reserved-directory names)",
        )


def actual_spelling(root: Path, document: str) -> None:
    """Refuse a spelling the filesystem would resolve to a different one: on a
    case-insensitive (or Unicode-normalizing) filesystem `Docs/notes.md` and
    `docs/notes.md` are one file but would key two locks and two records. Each
    existing component must be spelled exactly as the directory stores it."""
    current = root
    for part in PurePosixPath(document).parts:
        try:
            names = os.listdir(current)
        except FileNotFoundError:
            return
        except OSError as error:
            raise DocumentError(
                "document-path-unsafe", f"{current} could not be listed ({error})"
            ) from error
        if part not in names:
            folded = unicodedata.normalize("NFC", part).casefold()
            twins = [
                name for name in names
                if unicodedata.normalize("NFC", name).casefold() == folded
            ]
            if twins:
                raise DocumentError(
                    "document-name-unsupported",
                    f"{document!r} is spelled {part!r} where the filesystem stores "
                    f"{twins[0]!r}: one file must have one spelling, so it is not "
                    "keyed under both",
                )
            return
        current = current / part


def confine(root: Path, document: str) -> None:
    """Refuse a document whose path leaves the verified worktree: every existing
    component below the root must be a real directory (or the final file), never
    a symlink, so a link cannot carry a write or a recovery outside it."""
    actual_spelling(root, document)
    current = root
    for part in PurePosixPath(document).parts:
        current = current / part
        try:
            info = os.lstat(current)
        except FileNotFoundError:
            return
        except OSError as error:
            raise DocumentError(
                "document-path-unsafe", f"{current} could not be inspected ({error})"
            ) from error
        if stat.S_ISLNK(info.st_mode):
            raise DocumentError(
                "document-path-unsafe",
                f"{current} is a symbolic link, so {document} is not confined to "
                f"the write root {root}; nothing was moved or written",
                path=str(current),
            )


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


def build_pending_commit(root: Path, fields: dict, payloads: dict) -> str:
    """A parentless commit whose message carries the record and whose tree roots
    every payload under a fixed internal directory.

    Commit-shaped so it sits in the namespace the publisher's preflight already
    reads, and so the payloads are retained by object reachability and not by
    an object name a prune could orphan. Parentless on purpose: the publisher
    resuming such a record would otherwise read a parent as its pinned tip and
    push the commit, which is the one thing this module exists to take out of
    that tool's hands. Without a parent the publisher stops. Built through a
    scratch index in the common Git directory, so the write root's own index is
    never touched.
    """
    try:
        handle, scratch_name = tempfile.mkstemp(
            prefix="kanban-approved-index-", dir=str(common_git_dir(root))
        )
        os.close(handle)
    except OSError as error:
        raise DocumentError(
            "scratch-index-unavailable",
            f"a scratch index for {fields['document']} could not be created: {error}",
        ) from error
    scratch = Path(scratch_name)
    env = dict(os.environ, GIT_INDEX_FILE=str(scratch))
    try:
        # mkstemp leaves an empty file, which git reads as a corrupt index.
        scratch.unlink()
        for name, blob in sorted(payloads.items()):
            update = subprocess.run(
                [
                    "git", "update-index", "--add", "--cacheinfo",
                    f"100644,{blob},{PAYLOAD_DIR}/{name}",
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


def capture_fault(capture, attempt: str) -> str | None:
    if not isinstance(capture, dict):
        return "its capture descriptor is not an object"
    if capture.get("directory") != f".kanban-attempt-{attempt}":
        return "its capture directory is not this attempt's reservation"
    for name in ("scratch", "aside"):
        value = capture.get(name)
        if not isinstance(value, str) or not value or "/" in value or value in (".", ".."):
            return f"its capture {name} is not a plain file name"
    if not isinstance(capture.get("worktree"), str) or not capture["worktree"]:
        return "its capture names no worktree"
    return None


def handoff_fault(handoff) -> str | None:
    if not isinstance(handoff, dict):
        return "its handoff is not an object"
    if handoff.get("state") not in HANDOFF_STATES:
        return f"its handoff state {handoff.get('state')!r} is unknown"
    if not isinstance(handoff.get("host"), str):
        return "its handoff names no host"
    argv = handoff.get("argv")
    if not isinstance(argv, list) or not all(isinstance(item, str) for item in argv):
        return "its handoff argv is not a list of strings"
    child = handoff.get("child")
    if child is not None:
        if (
            not isinstance(child, dict)
            or not isinstance(child.get("pid"), int)
            or not isinstance(child.get("start"), str)
            or not isinstance(child.get("argv"), list)
        ):
            return "its handoff child identity is unusable"
    if handoff["state"] == "running" and child is None:
        return "a running handoff names no child"
    result = handoff.get("result")
    if result is not None and (
        not isinstance(result, dict)
        or not isinstance(result.get("returncode"), (int, type(None)))
        or not isinstance(result.get("unresolved", ""), str)
    ):
        return "its handoff result is unusable"
    return None


def landing_evidence_fault(evidence) -> str | None:
    """What makes recorded landing evidence unusable in shape, or None. Whether
    it is *true* is `validate_evidence`'s question, asked of the repository."""
    if not isinstance(evidence, dict):
        return "it is not an object"
    if evidence.get("via") not in ("receipt", "already-present"):
        return f"its via {evidence.get('via')!r} is not a known landing"
    for name in ("published_blob", "evidence_commit"):
        value = evidence.get(name)
        if not isinstance(value, str) or not OID_RE.match(value):
            return f"its {name} is not an object name"
    receipt = evidence.get("receipt_commit")
    if receipt is not None and (not isinstance(receipt, str) or not OID_RE.match(receipt)):
        return "its receipt_commit is not an object name"
    return None


def tree_paths(root: Path, commit: str) -> dict:
    """Every blob in a commit's tree, by path."""
    listing = git(["ls-tree", "-r", "-z", commit], cwd=root).stdout.decode(
        "utf-8", errors="surrogateescape"
    )
    found = {}
    for entry in listing.split("\0"):
        meta, _, path = entry.partition("\t")
        fields = meta.split()
        if len(fields) == 3 and fields[1] == "blob":
            found[path] = fields[2]
    return found


def read_pending(root: Path, owner: str, document: str) -> dict | None:
    """The pending publication recorded for this document, or None.

    All three forms are recognized: this module's version-2 record, the paused
    branch's version-1 record, and the publisher's commit-shaped one. A record
    that is none of them, or that does not name the document it is keyed under,
    is reported rather than read as absent — an absent record is the one
    conclusion a caller deciding whether it may write must never reach by
    accident.
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
    tree = tree_paths(root, commit)
    base = {
        "ref": ref, "commit": commit, "repository": owner, "document": document,
        "branch": None, "root": None, "capture": None, "handoff": None,
        "landing_evidence": None, "payloads": {}, "message": None,
    }
    if subject.strip() != PENDING_SUBJECT:
        recorded = tree.get(document)
        if recorded is None:
            raise _malformed(ref, commit, f"does not carry {document}")
        parents = git(
            ["rev-list", "--parents", "-n", "1", commit], cwd=root, check=False
        ).stdout.decode().split()[1:]
        if len(parents) != 1:
            raise _malformed(
                ref, commit,
                "is neither this module's record nor a single-parent publisher commit",
            )
        if receipt_paths(root, commit) != [document]:
            raise _malformed(
                ref, commit, f"does not change {document} alone, as a publisher commit does"
            )
        return base | {
            "form": FORM_PUBLISHER, "version": 0, "approved_blob": recorded,
            "baseline": None, "rendered_tip": parents[0],
            "attempt": None, "payloads": {"approved": recorded},
        }
    try:
        fields = json.loads(body)
    except json.JSONDecodeError as error:
        raise _malformed(ref, commit, f"is not valid JSON ({error})") from error
    version = fields.get("version") if isinstance(fields, dict) else None
    if version not in (1, 2):
        raise _malformed(ref, commit, f"is not a version 1 or {PENDING_VERSION} record")
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
    if version == 1:
        payloads = {"approved": tree.get(document)}
        if payloads["approved"] != fields["approved_blob"]:
            raise _malformed(
                ref, commit,
                f"names approved blob {fields['approved_blob']} but its tree holds "
                f"{payloads['approved']}",
            )
    else:
        prefix = f"{PAYLOAD_DIR}/"
        payloads = {
            path[len(prefix):]: blob
            for path, blob in tree.items()
            if path.startswith(prefix)
            and (path[len(prefix):] in PAYLOAD_NAMES or CAPTURED_VERSION_RE.match(path[len(prefix):]))
        }
        if payloads.get("approved") != fields["approved_blob"]:
            raise _malformed(ref, commit, "does not root its approved blob")
        if (baseline is None) != ("baseline" not in payloads) or (
            baseline is not None and payloads["baseline"] != baseline
        ):
            raise _malformed(ref, commit, "does not root its baseline")
        for name in ("branch", "root"):
            if not isinstance(fields.get(name), str) or not fields[name]:
                raise _malformed(ref, commit, f"has no {name}")
        if fields.get("capture") is not None:
            fault = capture_fault(fields["capture"], fields["attempt"])
            if fault is not None:
                raise _malformed(ref, commit, fault)
        if fields.get("handoff") is not None:
            fault = handoff_fault(fields["handoff"])
            if fault is not None:
                raise _malformed(ref, commit, fault)
    evidence = fields.get("landing")
    if evidence is not None:
        fault = landing_evidence_fault(evidence)
        if fault is not None:
            raise _malformed(ref, commit, f"carries unusable landing evidence ({fault})")
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
    return base | {
        "form": FORM_HELPER, "version": version,
        "approved_blob": fields["approved_blob"], "baseline": baseline,
        "rendered_tip": fields["rendered_tip"], "attempt": fields["attempt"],
        "message": message_text if isinstance(message_text, str) else None,
        "branch": fields.get("branch"), "root": fields.get("root"),
        "capture": fields.get("capture"), "handoff": fields.get("handoff"),
        "landing_evidence": evidence, "payloads": payloads,
    }


def new_pending_fields(
    owner: str, branch: str, document: str, approved_blob: str, baseline: str | None,
    rendered_tip: str, message: str, root: Path,
) -> dict:
    return {
        "version": PENDING_VERSION, "repository": owner, "branch": branch,
        "document": document, "attempt": os.urandom(16).hex(), "root": str(root),
        "baseline": baseline, "approved_blob": approved_blob,
        "rendered_tip": rendered_tip, "message": message, "capture": None,
        "handoff": None, "landing": None,
    }


def create_pending(root: Path, owner: str, fields: dict, payloads: dict) -> dict:
    """Create the intent absent-only, and read it back before trusting it. A
    write whose effect cannot be read back is not absence."""
    document = fields["document"]
    commit = build_pending_commit(root, fields, payloads)
    ref = pending_ref(owner, document)
    created = git(["update-ref", ref, commit, ""], cwd=root, check=False)
    actual = read_ref(root, ref)
    if created.returncode != 0 and actual != commit:
        raise DocumentError(
            "pending-exists",
            f"a pending publication appeared for {document} while this run held "
            "its lock; it was left as it is",
            pending_ref=ref,
        )
    pending = read_pending(root, owner, document)
    if pending is None or pending["commit"] != commit:
        raise DocumentError(
            "pending-unverified",
            f"the pending record for {document} could not be read back as written",
            pending_ref=ref,
        )
    return pending


def rewrite_pending(
    root: Path, pending: dict, *, branch: str | None = None, root_id: Path | None = None,
    payloads: dict | None = None, **changes,
) -> dict:
    """Replace the record under compare-and-swap against the value just read,
    keeping every payload and field and applying `changes` (capture, handoff,
    landing, message). Always writes the current version, rooting the
    predecessor's raw record when it is migrated so nothing it carried is lost.
    """
    fields = {
        "version": PENDING_VERSION,
        "repository": pending["repository"],
        "branch": branch or pending.get("branch"),
        "document": pending["document"],
        "attempt": pending["attempt"] or os.urandom(16).hex(),
        "root": str(root_id) if root_id is not None else pending.get("root"),
        "baseline": pending["baseline"],
        "approved_blob": pending["approved_blob"],
        "rendered_tip": pending["rendered_tip"],
        "message": pending["message"],
        "capture": pending["capture"],
        "handoff": pending["handoff"],
        "landing": pending["landing_evidence"],
    }
    for name, value in changes.items():
        fields["landing" if name == "landing_evidence" else name] = value
    kept = dict(pending["payloads"])
    if pending["form"] == FORM_PUBLISHER and fields["baseline"] is None:
        fields["baseline"] = blob_at(root, pending["rendered_tip"], pending["document"])
    if fields["baseline"] is not None:
        kept.setdefault("baseline", fields["baseline"])
    if pending["version"] != PENDING_VERSION:
        kept["predecessor-record"] = _preserve(
            root, git(["cat-file", "commit", pending["commit"]], cwd=root).stdout
        )
    kept.update(payloads or {})
    if not fields["branch"] or not fields["root"]:
        raise DocumentError(
            "pending-unmigratable",
            "a record without a branch and write root cannot be rewritten",
            pending_ref=pending["ref"],
        )
    commit = build_pending_commit(root, fields, kept)
    proc = git(["update-ref", pending["ref"], commit, pending["commit"]], cwd=root, check=False)
    actual = read_ref(root, pending["ref"])
    if proc.returncode != 0 and actual != commit:
        raise DocumentError(
            "pending-changed",
            f"the pending publication for {pending['document']} changed while it "
            "was being updated; it was left as it is",
            pending_ref=pending["ref"],
        )
    reread = read_pending(root, pending["repository"], pending["document"])
    if reread is None or reread["commit"] != commit:
        raise DocumentError(
            "pending-unverified",
            f"the pending publication for {pending['document']} could not be read "
            "back after it was updated",
            pending_ref=pending["ref"],
        )
    return reread


# ------------------------------------------------------------- applied record --


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


def require_applied_matches_document(root: Path, document: str, applied: str | None) -> None:
    """A standalone applied record (no intent) describes the working copy it was
    written for. When the document has since diverged from it, the record is the
    only evidence of what was applied there and it is not replaced merely because
    it is a valid blob: the divergence is reported, and stays, until the operator
    reconciles it explicitly."""
    if applied is None:
        return
    state, blob = file_state(root / document)
    if state != "file" or blob != applied:
        raise DocumentError(
            "applied-diverged",
            f"the applied record for {document} names {applied[:12]}, but the "
            f"document is now {(blob or state)[:12]}; the record is kept, and "
            "nothing is approved over it, until the divergence is reconciled "
            "(remove the record by hand once it is accounted for)",
            applied_object=applied, working_blob=blob,
        )


def require_applied_agrees_with_pending(
    root: Path, owner: str, pending: dict, applied: str | None = None
) -> str | None:
    """An intent and an applied record that name unrelated content contradict one
    another, and the contradiction is found before anything is recovered,
    migrated, persisted or applied: the applied record is absent, the intent's
    own approved blob, or the predecessor the intent rooted. Returns the applied
    blob it validated."""
    document = pending["document"]
    ref = applied_ref(owner, document)
    current = applied if applied is not None else validate_applied(root, owner, document)
    if (
        current is not None
        and current != pending["approved_blob"]
        and current != pending["payloads"].get("predecessor")
    ):
        raise DocumentError(
            "applied-conflict",
            f"the applied record {ref} names other content than this attempt "
            "rooted as its predecessor; it was left as it is",
            applied_ref=ref,
            applied_object=current,
        )
    return current


def record_applied_content(root: Path, owner: str, pending: dict) -> str:
    """Record the applied bytes, under compare-and-swap against what was read.
    A different valid predecessor is replaced only when the intent roots it."""
    document, blob = pending["document"], pending["approved_blob"]
    ref = applied_ref(owner, document)
    current = require_applied_agrees_with_pending(root, owner, pending)
    if current == blob:
        return "recorded"
    git(["update-ref", ref, blob, current or ""], cwd=root, check=False)
    return "recorded" if read_ref(root, ref) == blob else "unrecorded"


# ------------------------------------------------------------ capture custody --


def file_state(path: Path):
    """('absent'|'file'|'other', blob). Never reads a failure as absence or as
    emptiness: an unreadable file is neither, and raises."""
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return "absent", None
    except OSError as error:
        raise DocumentError(
            "file-unreadable", f"{path} could not be inspected ({error})", path=str(path)
        ) from error
    if not stat.S_ISREG(info.st_mode):
        return "other", None
    try:
        return "file", git_blob_hash(Path(path).read_bytes())
    except OSError as error:
        raise DocumentError(
            "file-unreadable",
            f"{path} could not be read ({error}); it is not treated as absent or empty",
            path=str(path),
        ) from error


def reserve_directory(directory: Path) -> None:
    """Exclusively create this attempt's reservation. A seam a test can reach."""
    os.mkdir(directory, 0o700)


def write_scratch(path: Path, content: bytes, mode: int) -> None:
    descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(path, mode)


def rename_aside(target: Path, aside: Path) -> None:
    """Move the document into custody, atomically. A seam a test can reach."""
    os.rename(target, aside)


def read_captured(aside: Path) -> bytes:
    return Path(aside).read_bytes()


def link_into_place(source: Path, target: Path) -> None:
    """Put a file at the document's path, failing if anything is already there.
    `link` is the one filesystem primitive here that refuses rather than
    overwrites, which is what makes a lost race detectable."""
    os.link(source, target)


def restore_exclusive(aside: Path, target: Path) -> None:
    """Return a captured file to its path without overwriting anything, by hard
    link so the inode and its mode travel with it. When linking is unavailable
    the file is copied exclusively; a partial copy is reported as divergent by
    the caller and the aside is kept."""
    try:
        link_into_place(aside, target)
        return
    except FileExistsError:
        raise
    except OSError:
        pass
    data = Path(aside).read_bytes()
    mode = stat.S_IMODE(os.lstat(aside).st_mode)
    descriptor = os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY, mode)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(data)
    os.chmod(target, mode)


def capture_locations(root: Path, pending: dict):
    """(directory, aside, scratch) of the recorded capture, validated: the
    descriptor must belong to this worktree and this attempt, and nothing it
    names may be a symlink or a different kind of entry."""
    capture = pending["capture"]
    if capture["worktree"] != str(root):
        raise DocumentError(
            "capture-foreign-worktree",
            f"the capture was recorded for {capture['worktree']}, not {root}; it "
            "is left as it is",
            capture=capture,
        )
    directory = (root / pending["document"]).parent / capture["directory"]
    return directory, directory / capture["aside"], directory / capture["scratch"]


def inspect_capture(root: Path, pending: dict) -> dict:
    directory, aside, scratch = capture_locations(root, pending)
    try:
        info = os.lstat(directory)
        present = True
    except FileNotFoundError:
        present = False
    if present:
        if not stat.S_ISDIR(info.st_mode):
            raise DocumentError(
                "capture-inconsistent",
                f"{directory} is not the directory this attempt reserved",
                path=str(directory),
            )
        unexpected = sorted(
            entry for entry in os.listdir(directory)
            if entry not in (aside.name, scratch.name)
        )
        if unexpected:
            raise DocumentError(
                "capture-inconsistent",
                f"{directory} holds unexpected entries {unexpected}",
                path=str(directory),
            )
    return {
        "directory": directory, "aside_path": aside, "scratch_path": scratch,
        "present": present,
        "aside": safe_state(aside) if present else ("absent", None),
        "scratch": safe_state(scratch) if present else ("absent", None),
        "target": file_state(root / pending["document"]),
    }


def safe_state(path: Path):
    """`file_state`, with an unreadable file reported as its own state so that a
    capture that cannot be read is still restored and kept, never lost."""
    try:
        return file_state(path)
    except DocumentError:
        return "unreadable", None


def remove_file(path: Path, directory: bool = False) -> None:
    """Remove one leftover, treating an already-missing one as removed. A seam."""
    try:
        path.rmdir() if directory else path.unlink()
    except FileNotFoundError:
        pass


def finish_capture(root: Path, pending: dict, inspected: dict) -> dict:
    """Remove this attempt's leftovers and clear its descriptor. Only called once
    the actual captured bytes are restored, rooted or known equal to the rooted
    baseline; a leftover that cannot be removed keeps the descriptor."""
    leftovers = []
    for path in (inspected["aside_path"], inspected["scratch_path"]):
        try:
            remove_file(path)
        except OSError:
            leftovers.append(str(path))
    if not leftovers and inspected["present"]:
        try:
            remove_file(inspected["directory"], directory=True)
        except OSError:
            leftovers.append(str(inspected["directory"]))
    if leftovers:
        raise DocumentError(
            "capture-cleanup-incomplete",
            f"the capture leftovers {leftovers} could not be removed; the intent "
            "keeps naming them",
            leftovers=leftovers,
            pending_ref=pending["ref"],
        )
    return persist_capture(root, pending, None)


def capture_stop(status: str, message: str, inspected: dict, pending: dict) -> DocumentError:
    return DocumentError(
        status, message,
        pending_ref=pending["ref"], aside=str(inspected["aside_path"]),
        capture_states={
            "aside": inspected["aside"][0], "scratch": inspected["scratch"][0],
            "target": inspected["target"][0],
        },
        aside_blob=inspected["aside"][1], target_blob=inspected["target"][1],
        approved_blob=pending["approved_blob"], baseline_blob=pending["baseline"],
    )


def persist_capture(root: Path, pending: dict, capture) -> dict:
    """Record (or clear) the capture descriptor. A named seam."""
    return rewrite_pending(root, pending, capture=capture)


def persist_handoff(root: Path, pending: dict, handoff) -> dict:
    """Record the tool handoff. A named seam."""
    return rewrite_pending(root, pending, handoff=handoff)


def persist_landing(root: Path, pending: dict, branch: str, evidence: dict) -> dict:
    """Save verified landing evidence into the intent. A named seam."""
    return rewrite_pending(
        root, pending, branch=branch, root_id=Path(pending.get("root") or root),
        landing=evidence,
    )


def preserve_captured(root: Path, data: bytes) -> str:
    """Store the captured bytes as an object. A named seam."""
    return _preserve(root, data)


def root_capture(root: Path, pending: dict, captured: str) -> dict:
    """Retain a captured foreign edit by reachability in the intent.

    Every distinct version observed stays rooted: the newest is `captured`, and
    the one it displaces moves to `captured-<n>` in the same rewrite, so a record
    that is rewritten never makes an earlier captured version unreachable."""
    held = pending["payloads"]
    versions = {name: blob for name, blob in held.items()
                if name == "captured" or CAPTURED_VERSION_RE.match(name)}
    if captured in versions.values():
        return pending
    changes = {"captured": captured}
    if "captured" in held:
        serial = 1 + sum(1 for name in versions if CAPTURED_VERSION_RE.match(name))
        changes[f"captured-{serial}"] = held["captured"]
    return rewrite_pending(root, pending, payloads=changes)


def recover_capture(root: Path, pending: dict) -> dict:
    """Settle an interrupted capture from what is actually on disk, never from a
    flag: inspect the recorded locations, restore or retain, and return the
    intent with its descriptor cleared — or stop with the state reported."""
    confine(root, pending["document"])
    inspected = inspect_capture(root, pending)
    approved, baseline = pending["approved_blob"], pending["baseline"]
    target_state, target_blob = inspected["target"]
    if target_state == "other":
        raise capture_stop(
            "capture-conflict", "the document's path is not a regular file", inspected, pending
        )
    aside_state, aside_blob = inspected["aside"]
    if aside_state == "unreadable":
        if target_state == "absent":
            try:
                restore_exclusive(inspected["aside_path"], root / pending["document"])
            except OSError:
                pass
        raise capture_stop(
            "capture-unreadable",
            f"the captured file {inspected['aside_path']} cannot be read; it is "
            "kept and is not treated as empty",
            inspected, pending,
        )
    if aside_state == "other":
        raise capture_stop(
            "capture-inconsistent", "the captured entry is not a regular file", inspected, pending
        )
    if aside_state == "absent":
        # Nothing was taken. A harmless reservation, unless the document is
        # missing too, which nobody here may invent a file for.
        if target_state == "absent":
            raise capture_stop(
                "capture-lost",
                f"neither {pending['document']} nor its capture exists; the "
                "rooted payloads are the only copies, and the unexpected "
                "deletion needs explicit reconciliation",
                inspected, pending,
            )
        return finish_capture(root, pending, inspected)
    if target_state == "absent":
        restore_exclusive(inspected["aside_path"], root / pending["document"])
        restored = file_state(root / pending["document"])
        if restored != ("file", aside_blob):
            raise capture_stop(
                "capture-divergent",
                "the restored document is not the captured file; the capture is kept",
                inspected | {"target": restored}, pending,
            )
        if aside_blob != baseline:
            pending = root_capture(root, pending, _preserve(root, Path(inspected["aside_path"]).read_bytes()))
        return finish_capture(root, pending, inspected | {"target": restored})
    if target_blob == approved and aside_blob == baseline:
        return finish_capture(root, pending, inspected)
    if target_blob == aside_blob:
        return finish_capture(root, pending, inspected)
    if aside_blob != baseline:
        pending = root_capture(root, pending, _preserve(root, Path(inspected["aside_path"]).read_bytes()))
    raise capture_stop(
        "capture-conflict",
        f"{pending['document']} and its captured file differ; both are kept for "
        "reconciliation and nothing was overwritten",
        inspected, pending,
    )


def apply_over_baseline(root: Path, pending: dict, content: bytes) -> dict:
    """Replace the document with the approved content, only while it still holds
    the rooted baseline, keeping custody of the original at every step.

    The descriptor is persisted and read back before the rename; custody begins
    at the rename, before any read. Nothing after it unlinks the captured file
    unless its restoration or retention is verified.
    """
    document = pending["document"]
    confine(root, document)
    target = root / document
    state, blob = file_state(target)
    if state != "file" or blob != pending["baseline"]:
        raise DocumentError(
            "document-changed-before-write",
            f"{document} is no longer the baseline this attempt was recorded "
            "over; nothing was moved, written or published",
            working_blob=blob, baseline_blob=pending["baseline"],
            preserved_blob=_preserve(root, target.read_bytes()) if state == "file" else None,
        )
    require_unstaged(root, document)
    mode = stat.S_IMODE(os.lstat(target).st_mode)
    name = f".kanban-attempt-{pending['attempt']}"
    directory = target.parent / name
    try:
        reserve_directory(directory)
    except FileExistsError:
        if not directory.is_dir() or directory.is_symlink() or any(directory.iterdir()):
            raise DocumentError(
                "capture-inconsistent",
                f"{directory} already exists and is not an empty reservation",
                path=str(directory),
            ) from None
    except OSError as error:
        raise DocumentError(
            "document-unwritable",
            f"the reservation {directory} could not be created ({error}); "
            "nothing was moved",
        ) from error
    descriptor = {
        "directory": name, "scratch": "scratch", "aside": "aside", "worktree": str(root),
    }
    pending = persist_capture(root, pending, descriptor)
    aside, scratch = directory / "aside", directory / "scratch"
    try:
        write_scratch(scratch, content, mode)
        rename_aside(target, aside)
    except OSError as error:
        raise DocumentError(
            "document-unwritable",
            f"{document} could not be prepared for replacement ({error}); the "
            "intent and this attempt's reservation are kept",
            pending_ref=pending["ref"],
        ) from error
    inspected = {
        "directory": directory, "aside_path": aside, "scratch_path": scratch,
        "present": True, "aside": ("file", None), "scratch": ("file", None),
        "target": ("absent", None),
    }
    try:
        data = read_captured(aside)
        captured = preserve_captured(root, data)
    except OSError as error:
        try:
            restore_exclusive(aside, target)
        except OSError:
            pass
        raise DocumentError(
            "capture-unreadable",
            f"the captured {document} could not be read ({error}); the captured "
            f"file is kept at {aside} and was not treated as empty",
            aside=str(aside), pending_ref=pending["ref"],
        ) from error
    inspected["aside"] = ("file", captured)
    if captured != pending["baseline"]:
        pending = root_capture(root, pending, captured)
        restored = False
        try:
            restore_exclusive(aside, target)
            restored = file_state(target) == ("file", captured)
        except OSError:
            pass
        if restored:
            finish_capture(root, pending, inspected | {"target": ("file", captured)})
        raise DocumentError(
            "document-changed-before-write",
            f"{document} was changed between its verification and the swap; "
            + (
                "the captured edit was rooted and put back"
                if restored
                else "the captured edit was rooted and is kept at " + str(aside)
            )
            + "; nothing was published",
            preserved_blob=captured, restored=restored, aside=str(aside),
            pending_ref=pending["ref"],
        )
    try:
        link_into_place(scratch, target)
    except FileExistsError:
        raise DocumentError(
            "document-changed-before-write",
            f"{document} was recreated by another writer during the swap; that "
            f"file was left in place and the original is kept at {aside}",
            aside=str(aside), pending_ref=pending["ref"],
        ) from None
    except OSError as error:
        restored = False
        try:
            restore_exclusive(aside, target)
            restored = file_state(target) == ("file", captured)
        except OSError:
            pass
        if restored:
            finish_capture(root, pending, inspected | {"target": ("file", captured)})
        raise DocumentError(
            "document-unwritable",
            f"{document} could not be replaced ({error}); "
            + ("the original was put back" if restored else f"the original is kept at {aside}"),
            aside=str(aside), restored=restored, pending_ref=pending["ref"],
        ) from error
    return finish_capture(root, pending, inspected | {"target": ("file", pending["approved_blob"])})


# ------------------------------------------------------------------ landing --
#
# Landing is three-valued: yes, no, or unknown. "No" is concluded only after a
# complete, successful search of the publication interval; anything that cannot
# be read raises, and a raise never licenses a write, a tool call or a cleanup.


def fresh_tip(root: Path, branch: str) -> str:
    """The commit the remote's `<branch>` names right after a *successful* fetch.

    The fetch names its own destination, a private reference, so the answer is
    the object that fetch brought and does not depend on how (or whether) the
    repository's configured refspec maps the branch onto `origin/<branch>`: a
    narrowed or remapped refspec leaves that cached name stale after a
    successful fetch. Every check in one classification uses this object name,
    not a moving symbolic ref, and a failed fetch cannot certify a cached ref
    as fresh."""
    destination = (
        f"{FETCHED_NAMESPACE}/{hashlib.sha256(branch.encode()).hexdigest()[:16]}"
    )
    fetched = git(
        ["fetch", "origin", f"+refs/heads/{branch}:{destination}"], cwd=root, check=False
    )
    if fetched.returncode != 0:
        raise DocumentError(
            "fetch-failed",
            f"origin/{branch} could not be fetched "
            f"({fetched.stderr.decode(errors='replace').strip()}), so nothing "
            "about its history can be concluded",
        )
    return git_out(["rev-parse", "--verify", f"{destination}^{{commit}}"], cwd=root)


def interval_commits(root: Path, fresh: str, recorded_tip: str) -> list[str]:
    """`Anc(F) minus Anc(R)`, oldest first in topological order: every commit
    reachable from the fetched tip and not from the recorded one, merges and
    their second parents included, with no path limit and no history
    simplification. Deterministic, so a choice among equal candidates is stable."""
    listed = git(
        ["rev-list", "--topo-order", "--reverse", fresh, f"^{recorded_tip}"],
        cwd=root, check=False,
    )
    if listed.returncode != 0:
        raise DocumentError(
            "landing-unverifiable",
            f"the history between {recorded_tip[:12]} and {fresh[:12]} could not be "
            "read, so whether the mutation landed cannot be decided",
        )
    return listed.stdout.decode().split()


class TreeReader:
    """Walk the document's path in each commit's trees through one
    `git cat-file --batch`, so that an absent path is *proved* absent — the
    parent tree was read and does not list it — and a tree that cannot be read
    is unknown. A batch probe of `commit:path` reports both as "missing"."""

    def __init__(self, root: Path):
        self.root = root
        self.width = 32 if git_out(["rev-parse", "--show-object-format"], cwd=root) == "sha256" else 20
        self.process = subprocess.Popen(
            ["git", "cat-file", "--batch"], cwd=str(root), stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        self.trees: dict = {}

    def __enter__(self):
        return self

    def __exit__(self, *_):
        _quietly(self.process.stdin.close)
        _quietly(self.process.stdout.close)
        _quietly(self.process.wait)

    def read(self, spec: str):
        self.process.stdin.write(f"{spec}\n".encode())
        self.process.stdin.flush()
        header = self.process.stdout.readline().decode().split()
        if len(header) != 3 or header[1] == "missing":
            raise DocumentError(
                "landing-unverifiable",
                f"{spec} could not be read from the object database, so whether the "
                "mutation landed cannot be decided",
            )
        data = self.process.stdout.read(int(header[2]))
        self.process.stdout.read(1)
        return header[0], header[1], data

    def entries(self, oid: str) -> dict:
        if oid not in self.trees:
            _, kind, data = self.read(oid)
            if kind != "tree":
                raise DocumentError("landing-unverifiable", f"{oid} is not a tree")
            found, index = {}, 0
            while index < len(data):
                space, nul = data.index(b" ", index), data.index(b"\0", index)
                name = data[space + 1:nul].decode("utf-8", errors="surrogateescape")
                found[name] = (data[index:space].decode(), data[nul + 1:nul + 1 + self.width].hex())
                index = nul + 1 + self.width
            self.trees[oid] = found
        return self.trees[oid]

    def blob_in(self, commit: str, parts: tuple) -> str | None:
        oid, kind, _ = self.read(f"{commit}^{{tree}}")
        if kind != "tree":
            raise DocumentError("landing-unverifiable", f"{commit} has no readable tree")
        for position, part in enumerate(parts):
            listing = self.entries(oid)
            if part not in listing:
                return None
            mode, oid = listing[part]
            if position == len(parts) - 1:
                return oid if mode in ("100644", "100755") else None
            if mode != "40000":
                return None
        return None


def blobs_at(root: Path, commits: list[str], document: str) -> list[str | None]:
    """The document's blob in each commit. None means the path is *proved*
    absent from a tree that was read; anything unreadable raises."""
    parts = tuple(PurePosixPath(document).parts)
    with TreeReader(root) as reader:
        return [reader.blob_in(commit, parts) for commit in commits]


def is_shallow(root: Path) -> bool:
    answer = git(["rev-parse", "--is-shallow-repository"], cwd=root, check=False)
    return answer.returncode != 0 or answer.stdout.decode().strip() != "false"


def receipt_paths(root: Path, commit: str) -> list[str]:
    """The paths a commit changes, NUL-delimited and never Git's display form:
    under the default core.quotePath a path with a non-ASCII byte or a quote
    comes back quoted and escaped, and comparing that to the document's own
    spelling rejects a valid receipt."""
    listing = git(
        ["diff-tree", "-z", "--no-commit-id", "--name-only", "-r", "--root", commit],
        cwd=root,
    ).stdout.decode("utf-8", errors="surrogateescape")
    return [entry for entry in listing.split("\0") if entry]


def receipt_fault(root: Path, commit: str, pending: dict) -> str | None:
    """Why `commit` is not this attempt's publication, or None. One ordinary
    (single-parent) commit carrying the exact whole-line trailer and changing
    exactly the document; a merge carrying a copied trailer is not a receipt."""
    body = git(["log", "-1", "--format=%P%x1f%B", commit], cwd=root, check=False)
    if body.returncode != 0:
        return "the commit cannot be read"
    parents, _, message = body.stdout.decode(errors="replace").partition("\x1f")
    if len(parents.split()) != 1:
        return "it is not a single-parent publication commit"
    if receipt_line(pending) not in message.splitlines():
        return "it does not carry this attempt's marker"
    if receipt_paths(root, commit) != [pending["document"]]:
        return f"it does not change {pending['document']} alone"
    return None


def find_receipt(root: Path, fresh: str, pending: dict) -> str | None:
    """The one commit in the interval carrying this attempt's marker."""
    log = git_out(
        ["log", "--format=%H%x1f%B%x1e", "--topo-order", fresh, f"^{pending['rendered_tip']}"],
        cwd=root,
    )
    expected = receipt_line(pending)
    marked = []
    for entry in log.split("\x1e"):
        commit, separator, body = entry.strip().partition("\x1f")
        if separator and expected in body.splitlines():
            marked.append(commit.strip())
    if len(marked) > 1:
        raise DocumentError(
            "receipt-ambiguous",
            f"{len(marked)} commits carry this attempt's marker; one attempt has "
            "one publication, so the history is inconsistent and nothing is "
            "chosen among them",
            receipt_commits=marked,
        )
    if not marked:
        return None
    fault = receipt_fault(root, marked[0], pending)
    if fault is not None:
        raise DocumentError(
            "receipt-unverifiable",
            f"the commit {marked[0][:12]} carries this attempt's marker but is not "
            f"a publication of {pending['document']} ({fault})",
            receipt_commit=marked[0],
        )
    return marked[0]


def validate_evidence(root: Path, fresh: str, pending: dict, evidence: dict) -> dict:
    """Hold saved or rediscovered evidence to the recorded publication and to the
    interval `{R} union (Anc(F) minus Anc(R))`.

    Saved evidence is a claim, and is checked by exactly the rules rediscovery
    uses; anything less is unverifiable and stops, and is never discarded to
    make room for a fallback search."""
    document, recorded_tip = pending["document"], pending["rendered_tip"]
    commit = evidence["evidence_commit"]

    def unverifiable(why: str) -> DocumentError:
        return DocumentError(
            "landing-evidence-unverifiable",
            f"the landing recorded for {document} cannot be trusted ({why}); the "
            "record is kept",
            pending_ref=pending["ref"], evidence_commit=commit,
        )

    in_history = git(["cat-file", "-e", f"{commit}^{{commit}}"], cwd=root, check=False)
    if in_history.returncode != 0 or not is_ancestor(root, commit, fresh):
        raise unverifiable(f"{commit[:12]} is not in the history of the fetched tip")
    if commit != recorded_tip and is_ancestor(root, commit, recorded_tip):
        raise unverifiable(
            f"{commit[:12]} is at or before the recorded tip, outside the "
            "publication interval"
        )
    if evidence["via"] == "already-present":
        if evidence["published_blob"] != pending["approved_blob"]:
            raise unverifiable(
                f"it names {evidence['published_blob'][:12]} rather than the "
                f"approved blob {pending['approved_blob'][:12]}"
            )
        if evidence.get("receipt_commit") is not None:
            raise unverifiable("an already-present landing has no receipt")
    else:
        if commit == recorded_tip or evidence.get("receipt_commit") != commit:
            raise unverifiable("its receipt is not the commit it names as evidence")
        fault = receipt_fault(root, commit, pending)
        if fault is not None:
            raise unverifiable(fault)
    if blob_at(root, commit, document) != evidence["published_blob"]:
        raise unverifiable(f"{commit[:12]} does not carry the published content")
    return {
        "landed": True, "via": evidence["via"],
        "published_blob": evidence["published_blob"],
        "receipt_commit": evidence.get("receipt_commit"),
        "evidence_commit": commit, "fresh_tip": fresh,
    }


def landing(root: Path, branch: str, pending: dict, fresh: str | None = None) -> dict:
    """Whether the recorded mutation reached `origin/<branch>`, as {landed: True
    with the evidence} or {landed: False}. Unknown raises.

    The caller's `fresh` (or a fresh fetch) is the one tip used throughout.
    `R` must exist and be reachable from it before anything is accepted, a
    current-tip blob match included. Saved evidence takes precedence and is
    validated, never bypassed; without it the interval is searched in full:
    a receipt first (it identifies the actual merged publication), then the
    approved blob at the document's path in any commit of the interval.
    """
    fresh = fresh or fresh_tip(root, branch)
    document, approved = pending["document"], pending["approved_blob"]
    recorded_tip = pending["rendered_tip"]
    if not is_ancestor(root, recorded_tip, fresh):
        raise DocumentError(
            "pending-stale",
            f"the tip this publication of {document} was recorded against "
            f"({recorded_tip[:12]}) is not in the history of {remote_ref(branch)}, "
            "so whether it landed cannot be verified; the record is kept",
            pending_ref=pending["ref"], rendered_tip=recorded_tip,
        )
    if pending.get("landing_evidence") is not None:
        return validate_evidence(root, fresh, pending, pending["landing_evidence"])
    commits = interval_commits(root, fresh, recorded_tip)
    if pending["form"] == FORM_PUBLISHER and pending["commit"] in commits:
        return {
            "landed": True, "via": "recorded-commit", "published_blob": approved,
            "receipt_commit": pending["commit"], "evidence_commit": pending["commit"],
            "fresh_tip": fresh,
        }
    if pending["form"] == FORM_HELPER:
        receipt = find_receipt(root, fresh, pending)
        if receipt is not None:
            published = blob_at(root, receipt, document)
            return validate_evidence(root, fresh, pending, {
                "via": "receipt", "published_blob": published,
                "receipt_commit": receipt, "evidence_commit": receipt,
            })
    candidates = [recorded_tip, *commits]
    for commit, blob in zip(candidates, blobs_at(root, candidates, document)):
        if blob == approved:
            return validate_evidence(root, fresh, pending, {
                "via": "already-present", "published_blob": approved,
                "receipt_commit": None, "evidence_commit": commit,
            })
    if is_shallow(root):
        raise DocumentError(
            "landing-unverifiable",
            f"the history of {remote_ref(branch)} is shallow, so a negative cannot "
            "be concluded; fetch complete history first",
        )
    return {"landed": False, "fresh_tip": fresh}


def confirm_landing(root: Path, branch: str, pending: dict, fresh: str | None = None):
    """`landing`, and when it finds a landing nothing durable yet records, record
    it by compare-and-swap before anything else is done. Returns the (possibly
    rewritten) pending record and the landing. A failed save raises, keeping the
    intent: the landing is rediscovered next time by the same rules."""
    info = landing(root, branch, pending, fresh)
    if (
        info["landed"]
        and pending.get("landing_evidence") is None
        and info["via"] != "recorded-commit"
    ):
        pending = persist_landing(root, pending, branch, {
            "via": info["via"], "published_blob": info["published_blob"],
            "receipt_commit": info["receipt_commit"],
            "evidence_commit": info["evidence_commit"],
        })
    return pending, info


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


def process_identity(pid: int):
    """{start, args} of the live process `pid`, or None when it does not exist.
    Anything that cannot be inspected raises: unknown is not gone."""
    try:
        proc = subprocess.run(
            ["ps", "-o", "lstart=,args=", "-p", str(pid)],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise DocumentError(
            "process-inspection-failed", f"process {pid} could not be inspected ({error})"
        ) from error
    output = proc.stdout.strip()
    if not output:
        if proc.returncode == 1 and not proc.stderr.strip():
            return None
        raise DocumentError(
            "process-inspection-failed",
            f"process {pid} could not be inspected (ps exited {proc.returncode})",
        )
    start = output[:24].strip()
    if len(start) < 20:
        raise DocumentError(
            "process-inspection-failed", f"process {pid} has no readable start time"
        )
    return {"start": start, "args": output[24:].strip()}


def child_state(handoff: dict | None) -> str:
    """'none', 'gone', 'live' or 'unknown' for the tool a handoff started.

    The identity is the pid, the operating-system start time and the exact argv,
    never the pid alone, and a leader that has exited is gone only when its
    process group is empty too: a reused pid is a different process, and neither blocks
    this one nor may be touched. A marker with no child recorded (the crash
    between spawning and recording it), a changed argv for the same live
    process, and any failed inspection are unknown, which is not quiescent."""
    if handoff is None:
        return "none"
    if handoff["state"] == "finished":
        return "gone"
    if handoff.get("host") != socket.gethostname():
        # A process that is absent here says nothing about one on the machine
        # that started it (a shared or recovered Git directory).
        return "unknown"
    if (handoff.get("result") or {}).get("unresolved"):
        # The tool's own process ended but what it started was not known to be
        # gone: only the operator can say it is.
        return "unknown"
    child = handoff.get("child")
    if child is None or child["pid"] <= 1:
        return "unknown"
    try:
        identity = process_identity(child["pid"])
    except DocumentError:
        return "unknown"
    if identity is None or identity["start"] != child["start"]:
        # The leader is gone. What it started may not be: the tool was the
        # leader of its own process group, so any member left in that group
        # (a reused pid that leads a group of its own reads the same way, which
        # errs toward waiting) means quiescence is not established.
        return "unknown" if group_alive(child["pid"]) else "gone"
    return "live" if identity["args"] == " ".join(child["argv"]) else "unknown"


def parse_json_stream(text: str) -> list:
    """Every JSON value in `text`, for `gh api --paginate`, which prints one
    document per page back to back."""
    decoder, index, found = json.JSONDecoder(), 0, []
    while index < len(text):
        if text[index].isspace():
            index += 1
            continue
        value, index = decoder.raw_decode(text, index)
        found.append(value)
    return found


def gh_json(path: str):
    gh = shutil.which("gh")
    if gh is None:
        raise DocumentError("gh-missing", "gh was not found on PATH")
    try:
        proc = subprocess.run(
            [gh, "api", "--paginate", path], capture_output=True, text=True, timeout=120
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise DocumentError("gh-failed", f"gh api {path} could not be run ({error})") from error
    if proc.returncode != 0:
        raise DocumentError(
            "gh-failed", f"gh api {path} failed: {(proc.stderr or proc.stdout).strip()}"
        )
    try:
        return parse_json_stream(proc.stdout)
    except ValueError as error:
        raise DocumentError("gh-failed", f"gh api {path} returned unreadable JSON") from error


def retry_gate(repository: str, branch: str) -> dict:
    """Whether an automatic negative-history retry is permitted (design D-5).

    Only an active, applicable `non_fast_forward` rule on the publication branch,
    read fresh from GitHub, permits it; readable classic protection that
    disables force pushes is the alternative. The rule is the gate: bypass
    actors and the pushing identity's permissions are deliberately not read, an
    accepted residual risk. A missing, inactive, unreadable or ambiguous answer
    grants nothing, and an earlier positive answer is never reused.
    """
    owner, _, name = repository.partition("/")
    quoted = urllib.parse.quote(branch, safe="")
    reasons = []
    try:
        pages = gh_json(f"repos/{owner}/{name}/rules/branches/{quoted}")
        entries = [item for page in pages for item in (page if isinstance(page, list) else [page])]
        if any(isinstance(item, dict) and item.get("type") == "non_fast_forward" for item in entries):
            return {"ok": True, "via": "rules"}
        reasons.append("no active non_fast_forward rule applies to the branch")
    except DocumentError as error:
        reasons.append(error.message)
    try:
        pages = gh_json(f"repos/{owner}/{name}/branches/{quoted}/protection")
        protection = pages[0] if pages else None
        enabled = (protection or {}).get("allow_force_pushes", {}).get("enabled") if isinstance(protection, dict) else None
        if enabled is False:
            return {"ok": True, "via": "classic-protection"}
        reasons.append("classic protection does not explicitly disable force pushes")
    except DocumentError as error:
        reasons.append(error.message)
    return {"ok": False, "reason": "; ".join(reasons)}


def recheck_before_spawn(root: Path, document: str, approved_blob: str) -> None:
    """The last look before the tool is started: the index entry is not staged
    and the document still holds the approved bytes. Everything slow (the
    capability probe, the gate, the fresh history read, the handoff write) has
    already happened, so what this sees is what the tool will be handed."""
    require_unstaged(root, document)
    state, blob = file_state(root / document)
    if state != "file" or blob != approved_blob:
        raise DocumentError(
            "document-not-applied",
            f"{document} no longer holds the approved content, so it is not handed "
            "to the tool",
            working_blob=blob,
        )


def run_publication_tool(root: Path, pending: dict, message: str, recheck=None):
    """Run `docs-push --expect <blob> --keep -m <message> <document>` from the
    write root, recording the handoff before and during. Returns (result,
    pending): the result describes what happened and does not say whether the
    document landed; `pending` is the intent as last rewritten.

    The capability probe comes first, the marker second and `recheck` last, so
    nothing between the check and the spawn can move what the tool is handed.
    A refused recheck takes the marker back: no tool was started."""
    tool = publication_tool()
    if not tool["available"]:
        return {"ran": False} | tool, pending
    argv = [
        tool["path"], "--expect", pending["approved_blob"], "--keep", "-m", message,
        pending["document"],
    ]
    previous = pending["handoff"]
    # Marker first: once it is written the tool may run, whatever happens next.
    pending = persist_handoff(root, pending, {
        "state": "marker", "host": socket.gethostname(), "argv": argv,
        "child": None, "result": None,
    })
    if recheck is not None:
        try:
            recheck()
        except DocumentError:
            persist_handoff(root, pending, previous)
            raise
    try:
        proc = subprocess.Popen(
            argv, cwd=str(root), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except OSError as error:
        pending = persist_handoff(root, pending, dict(
            pending["handoff"], state="finished", result={"returncode": None}
        ))
        return {
            "ran": False, "path": tool["path"], "reason": "tool-failed",
            "message": f"{TOOL} could not be started: {error}",
        }, pending
    try:
        identity = process_identity(proc.pid)
        if identity is not None:
            pending = persist_handoff(root, pending, dict(
                pending["handoff"], state="running",
                child={"pid": proc.pid, "start": identity["start"], "argv": argv},
            ))
    except DocumentError:
        # The child is running and its identity is unrecorded: the marker
        # stays, and a later retry is blocked until the operator establishes
        # quiescence. This run still waits for it.
        pass
    timed_out, abandoned = False, False
    try:
        stdout, stderr = proc.communicate(timeout=TOOL_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        timed_out = True
        stop_group(proc)
        try:
            stdout, stderr = proc.communicate(timeout=DESCENDANT_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            # Something that was not stopped still holds the tool's pipes.
            stdout, stderr, abandoned = b"", b"", True
            try:
                proc.wait(timeout=DESCENDANT_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                pass
            for stream in (proc.stdout, proc.stderr):
                if stream is not None:
                    stream.close()
    if abandoned or group_alive(proc.pid, DESCENDANT_GRACE_SECONDS):
        # The tool's own process is reaped but part of what it started is not
        # known to be gone, so it may still publish. The handoff stays
        # unresolved until the operator establishes quiescence.
        pending = persist_handoff(root, pending, dict(
            pending["handoff"], result={"returncode": None, "unresolved": "descendants"},
        ))
        return {
            "ran": False, "path": tool["path"], "reason": "tool-not-quiescent",
            "message": f"{TOOL} left processes running; whether it published is unknown "
            "until they are gone",
        }, pending
    pending = persist_handoff(root, pending, dict(
        pending["handoff"], state="finished",
        result={"returncode": None if timed_out else proc.returncode},
    ))
    output = (stdout + stderr).decode(errors="replace").strip()
    if timed_out:
        return {
            "ran": False, "path": tool["path"], "reason": "tool-failed",
            "message": f"{TOOL} did not finish within {TOOL_TIMEOUT_SECONDS}s and was stopped",
        }, pending
    return {
        "ran": True, "path": tool["path"], "returncode": proc.returncode, "message": output,
    }, pending


def stop_group(proc) -> None:
    """Kill the tool's whole process group (it was started as a session leader),
    then the process itself; killing only the leader strands whatever it forked."""
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except OSError:
        pass
    proc.kill()


def group_alive(pgid: int, settle: float = 0.0) -> bool:
    """Whether any live process is still in process group `pgid`, allowing
    `settle` seconds for processes that were just killed to be reaped.

    The process table is read, not signalled: a signal probe counts a zombie
    that nothing has reaped (a container without an init) as a member for good.
    A table that cannot be read is an answer of "yes", never of "no"."""
    deadline = time.monotonic() + settle
    while True:
        try:
            listing = subprocess.run(
                ["ps", "-A", "-o", "pgid=,stat="], capture_output=True, text=True,
                timeout=30,
            )
        except (OSError, subprocess.TimeoutExpired):
            return True
        if listing.returncode != 0:
            return True
        members = [
            fields for fields in (line.split() for line in listing.stdout.splitlines())
            if fields and fields[0] == str(pgid)
            and not (len(fields) > 1 and fields[1].startswith("Z"))
        ]
        if not members:
            return False
        if time.monotonic() >= deadline:
            return True
        time.sleep(0.05)


# ----------------------------------------------------------------- outcomes --


def document_state(root: Path, document: str) -> dict:
    try:
        state, blob = file_state(root / document)
    except DocumentError:
        state, blob = "unreadable", None
    return {
        "document_edit": {
            "exists": state == "file", "state": state, "write_root": str(root),
            "path": document, "blob": blob,
        }
    }


def incomplete(
    root: Path, owner: str, branch: str, pending: dict, *, reason: str, message: str,
    next_action: str, tool: dict | None = None, reachable: bool | None = False,
    landing_error: str | None = None,
) -> dict:
    """The approved content is applied and recorded and the publication did not
    complete. Reported as an outcome with the exact reason, the tool's own words
    when it spoke, and the next safe action; nothing more is attempted."""
    tool = tool or {}
    return {
        "status": "incomplete-publication",
        "reason": reason,
        "message": message,
        "next_action": next_action,
        "tool": {
            "path": tool.get("path"), "ran": tool.get("ran", False),
            "returncode": tool.get("returncode"),
        },
        "landing_error": landing_error,
        "repository": owner,
        "branch": branch,
        "document": pending["document"],
        "publication_tip": pending["rendered_tip"],
        "approved_blob": pending["approved_blob"],
        "published_blob": None,
        "pending_ref": pending["ref"],
        "pending_commit": pending["commit"],
        "applied_ref": applied_ref(owner, pending["document"]),
        "remote_branch": remote_ref(branch),
        "remote_contains_commit": reachable,
    } | document_state(root, pending["document"])


def tool_incomplete(root, owner, branch, pending, tool, *, reachable=False, landing_error=None):
    if not tool.get("ran"):
        reason = tool.get("reason", "tool-failed")
    elif tool.get("returncode") != 0:
        reason = "tool-refused"
    elif landing_error is not None:
        reason = "landing-unverifiable"
    else:
        reason = "tool-reported-success-without-landing"
    if landing_error is not None:
        message = "publication outcome unknown: " + landing_error + (
            f" (tool said: {tool['message']})" if tool.get("message") else ""
        )
    else:
        message = tool.get("message") or ""
    return incomplete(
        root, owner, branch, pending, reason=reason, message=message, tool=tool,
        reachable=reachable, landing_error=landing_error,
        next_action=(
            f"the approved content and its intent are kept; fix what {TOOL} "
            "reported and re-run with the same content (or --resume). A retry "
            "after a handoff also needs the exact child gone and an affirmative "
            "non_fast_forward rule on the branch"
        ),
    )


def delete_ref(root: Path, ref: str, expected: str) -> bool:
    """CAS-delete, then trust only a read-back: a failed command whose effect
    landed is success, and a successful one that left the ref is not."""
    git(["update-ref", "-d", ref, expected], cwd=root, check=False)
    return read_ref(root, ref) == ""


def settle_landed(
    root: Path, owner: str, branch: str, document: str, pending: dict, info: dict,
    operator_quiescent: bool = False,
) -> dict:
    """Clean up a publication that is verified to have landed, but only from a
    write root that still holds what was published, with nothing unresolved.

    Reachability is settled by now. What is not settled is the write root: the
    tool's `--keep` leaves the merged copy there, and an outside process can
    change or stage the document between that and this call. The applied record
    goes first, then the intent, so a crash cannot leave an applied-only record
    of a new-format attempt; the lock is released by the caller.
    """
    published = info["published_blob"]
    if pending["capture"] is not None:
        raise DocumentError(
            "capture-unresolved",
            f"{document} landed, but a capture of the document is unresolved; the "
            "record is kept",
            pending_ref=pending["ref"],
        )
    children = child_state(pending["handoff"])
    # The operator's confirmation covers an identity that was never recorded; it
    # never overrides a child known to be live.
    if children == "live" or (children == "unknown" and not operator_quiescent):
        raise DocumentError(
            "tool-child-not-quiescent",
            f"{document} landed, but the tool's child process is {children}; the "
            "record is kept",
            pending_ref=pending["ref"],
        )
    state, blob = file_state(root / document)
    if state != "file" or blob != published or index_differs(root, document):
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
    applied = validate_applied(root, owner, document)
    if applied is not None:
        if applied == pending["approved_blob"]:
            if not delete_ref(root, applied_ref(owner, document), applied):
                raise DocumentError(
                    "record-retained",
                    f"{document} reached {branch}, but its applied record could "
                    "not be cleared; the next run's preflight will report it",
                    remote_contains_commit=True, published_blob=published,
                    applied_ref=applied_ref(owner, document), pending_ref=pending["ref"],
                )
            cleared["applied"] = "cleared"
        elif applied == pending["payloads"].get("predecessor"):
            cleared["applied"] = "kept: it is the rooted predecessor"
        else:
            raise DocumentError(
                "applied-conflict",
                f"{document} reached {branch}, but its applied record names other "
                "content than this attempt applied or rooted; both records are kept "
                "until it is reconciled",
                remote_contains_commit=True, published_blob=published,
                applied_ref=applied_ref(owner, document), applied_object=applied,
                pending_ref=pending["ref"],
            )
    if not delete_ref(root, pending["ref"], pending["commit"]):
        raise DocumentError(
            "record-retained",
            f"{document} reached {branch}, but its pending record could not be "
            "cleared (or changed concurrently); the next run's preflight will "
            "stop until it is resolved",
            remote_contains_commit=True, published_blob=published,
            pending_ref=pending["ref"], pending_commit=pending["commit"],
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
        # result reports both rather than requiring them equal. Historically
        # landed is not the same as present at today's tip.
        "merged": info["published_blob"] != pending["approved_blob"],
        "landed_via": info["via"],
        "receipt_commit": info["receipt_commit"],
        "evidence_commit": info["evidence_commit"],
        "current_branch_blob": blob_at(root, info["fresh_tip"], document),
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


def unquiet_tool(
    root: Path, owner: str, branch: str, pending: dict, operator_quiescent: bool
) -> dict | None:
    """The incomplete-publication outcome that refuses a recovery write while the
    recorded tool child is live or unknown (unknown only unless the operator has
    confirmed quiescence), or None when nothing owed a wait remains."""
    children = child_state(pending["handoff"])
    if children == "live" or (children == "unknown" and not operator_quiescent):
        return incomplete(
            root, owner, branch, pending, reason="tool-child-not-quiescent",
            message=f"the earlier {TOOL} child is {children}; the document is not "
            "written beside it",
            next_action="establish that the recorded child has exited (a reused "
            "pid is not the child), then resume; --operator-quiescent confirms "
            "it when the identity was never recorded or the host differs",
            reachable=None,
        )
    return None


def publish_recorded(
    root: Path, owner: str, branch: str, document: str, pending: dict,
    *, resumed: str | None, operator_quiescent: bool = False,
) -> dict:
    """The intent exists and the document holds the approved blob: land it, or
    recognize that it already landed."""
    pending, info = confirm_landing(root, branch, pending)
    if info["landed"]:
        cleared = settle_landed(
            root, owner, branch, document, pending, info, operator_quiescent
        )
        return published_outcome(
            root, owner, branch, document, pending, info, cleared,
            resumed=resumed or "already-landed", tool=None,
        )
    # Every attempt, not only the one that writes: a resume finds the document
    # already holding the approved bytes, and an index entry staged since then
    # is work the tool's settling and the cleanup below would carry or lose.
    require_unstaged(root, document)
    state, blob = file_state(root / document)
    if state != "file" or blob != pending["approved_blob"]:
        raise DocumentError(
            "document-not-applied",
            f"{document} does not hold the approved content, so it is not handed "
            "to the tool",
            working_blob=blob,
        )
    if pending["handoff"] is not None:
        # A retry: the tool already ran (or may have) and nothing landed.
        blocked = unquiet_tool(root, owner, branch, pending, operator_quiescent)
        if blocked is not None:
            return blocked
        gate = retry_gate(owner, branch)
        if not gate["ok"]:
            return incomplete(
                root, owner, branch, pending, reason="retry-gate-unsatisfied",
                message=gate["reason"],
                next_action="reconcile by hand: negative history alone does not "
                "authorize a retry, and nothing was published by other means",
                reachable=None,
            )
        # The earlier child may have published between the negative check above
        # and now. Quiescence and the gate come first, then a fresh
        # classification: only a negative taken after both authorizes a call.
        pending, info = confirm_landing(root, branch, pending)
        if info["landed"]:
            cleared = settle_landed(
                root, owner, branch, document, pending, info, operator_quiescent
            )
            return published_outcome(
                root, owner, branch, document, pending, info, cleared,
                resumed=resumed or "already-landed", tool=None,
            )
    base = pending["message"] or default_message(document)
    tool, pending = run_publication_tool(
        root, pending, f"{base}\n\n{receipt_line(pending)}",
        recheck=lambda: recheck_before_spawn(root, document, pending["approved_blob"]),
    )
    try:
        pending, info = confirm_landing(root, branch, pending)
    except DocumentError as error:
        # The push may have succeeded. The intent is what a later run verifies
        # against, so it stays and the outcome says the answer is unknown.
        return tool_incomplete(
            root, owner, branch, pending, tool, reachable=None,
            landing_error=error.message,
        )
    if not info["landed"]:
        return tool_incomplete(root, owner, branch, pending, tool)
    cleared = settle_landed(
            root, owner, branch, document, pending, info, operator_quiescent
        )
    return published_outcome(
        root, owner, branch, document, pending, info, cleared,
        resumed=resumed, tool=tool,
    )


def resume_pending(
    root: Path, owner: str, branch: str, document: str, pending: dict,
    approved_blob: str, content: bytes, message: str, operator_quiescent: bool,
) -> dict:
    """An earlier run recorded a mutation of this document. Finish it, or stop
    with a report: never write something else over it."""
    if pending["branch"] not in (None, branch):
        raise DocumentError(
            "branch-mismatch",
            f"the pending publication was recorded for {pending['branch']}, not "
            f"{branch}; it was left as it is",
            pending_ref=pending["ref"],
        )
    if pending["capture"] is not None:
        # Read-only first: a record that is stale or whose evidence cannot be
        # verified is refused with the capture, the document and the record as
        # they were.
        landing(root, branch, pending)
        blocked = unquiet_tool(root, owner, branch, pending, operator_quiescent)
        if blocked is not None:
            return blocked
        pending = recover_capture(root, pending)
    pending, info = confirm_landing(root, branch, pending)
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
        cleared = settle_landed(
            root, owner, branch, document, pending, info, operator_quiescent
        )
        return published_outcome(
            root, owner, branch, document, pending, info, cleared,
            resumed="already-landed", tool=None,
        )
    state, current = file_state(root / document)
    resumed = "applied"
    if current != approved_blob:
        baseline = (
            pending["baseline"]
            if pending["form"] == FORM_HELPER
            else blob_at(root, pending["rendered_tip"], document)
        )
        if state != "file" or baseline is None or current != baseline:
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
                if state == "file"
                else None,
            )
    if pending["version"] != PENDING_VERSION or pending["form"] == FORM_PUBLISHER:
        # Validated first, migrated second, and only when something is about to
        # be written: an unusable situation leaves the original record exactly
        # as it was. The original stays rooted in the replacement.
        pending = rewrite_pending(root, pending, branch=branch, root_id=root)
    if current != approved_blob:
        # A write to the document alongside a tool that may still be running
        # would race it; quiescence comes before any recovery write.
        blocked = unquiet_tool(root, owner, branch, pending, operator_quiescent)
        if blocked is not None:
            return blocked
        pending = apply_over_baseline(root, pending, content)
        resumed = "applied-on-resume"
    record_applied_content(root, owner, pending)
    return publish_recorded(
        root, owner, branch, document, pending, resumed=f"resumed: {resumed}",
        operator_quiescent=operator_quiescent,
    )


def start_fresh(
    root: Path, owner: str, branch: str, tip: str, document: str, approved_blob: str,
    content: bytes, message: str, expected_working_copy: str | None,
    expected_tip: str | None, operator_quiescent: bool,
) -> dict:
    """No intent exists: bind the content to its baseline, record the intent,
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
    state, current = file_state(root / document)
    if state == "absent":
        raise DocumentError(
            "no-baseline",
            f"{document} does not exist under {root}; this module never creates a "
            "document, so nothing was written",
        )
    if state != "file" or current != expected_working_copy:
        raise DocumentError(
            "document-changed-before-write",
            f"{document} is no longer the content the preflight observed "
            f"({expected_working_copy[:12]}, now {(current or state)[:12]}); nothing "
            "was written and nothing was published",
            preserved_blob=_preserve(root, (root / document).read_bytes())
            if state == "file"
            else None,
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
            git(["cat-file", "-e", f"{expected_tip}^{{commit}}"], cwd=root, check=False).returncode
            != 0
            or not is_ancestor(root, expected_tip, tip)
        ):
            raise DocumentError(
                "tip-unverifiable",
                f"the tip the content was prepared against ({expected_tip[:12]}) "
                f"is not in the history of {remote_ref(branch)}, so a landing "
                "could not be verified against it; re-run the preflight",
                expected_tip=expected_tip,
            )
        rendered_tip = expected_tip
    # The baseline must be an object before a record can root it; a novel
    # document was never hashed into the object database.
    if _preserve(root, (root / document).read_bytes()) != current:
        raise DocumentError(
            "document-changed-before-write",
            f"{document} changed while its baseline was being recorded; nothing "
            "was moved or written",
        )
    payloads = {"approved": approved_blob, "baseline": current}
    predecessor = validate_applied(root, owner, document)
    if predecessor is not None and predecessor != approved_blob:
        payloads["predecessor"] = predecessor
    fields = new_pending_fields(
        owner, branch, document, approved_blob, current, rendered_tip, message, root
    )
    # The initial intent, created absent-only: from here every error keeps it.
    pending = create_pending(root, owner, fields, payloads)
    pending = apply_over_baseline(root, pending, content)
    applied = record_applied_content(root, owner, pending)
    outcome = publish_recorded(
        root, owner, branch, document, pending, resumed=None,
        operator_quiescent=operator_quiescent,
    )
    return outcome | {"applied_record": applied, "write_outcome": "applied-over-baseline"}


def abandon_intent(root: Path, owner: str, document: str) -> dict:
    """Explicit operator recovery: set aside an intent whose content has been
    accounted for. Refused while a capture is unresolved or a tool was ever
    handed the document; the record is moved to an abandoned reference (which
    keeps every rooted payload), never simply deleted."""
    pending = read_pending(root, owner, document)
    if pending is None:
        raise DocumentError(
            "no-pending-publication", f"no pending publication is recorded for {document}"
        )
    if pending["capture"] is not None or pending["handoff"] is not None:
        raise DocumentError(
            "abandon-refused",
            "an intent with an unresolved capture or a tool handoff is not "
            "abandoned: settle the capture and establish what landed first",
            pending_ref=pending["ref"],
        )
    kept = f"{ABANDONED_NAMESPACE}/{pending['ref'].rsplit('/', 1)[1]}/{pending['commit']}"
    made = git(["update-ref", kept, pending["commit"], ""], cwd=root, check=False)
    if read_ref(root, kept) != pending["commit"]:
        raise DocumentError(
            "abandon-refused",
            "the intent could not be retained under its own archive reference, so "
            "it was not set aside" + (f" ({made.stderr.decode().strip()})" if made.returncode else ""),
            pending_ref=pending["ref"],
        )
    if not delete_ref(root, pending["ref"], pending["commit"]):
        raise DocumentError(
            "record-retained", "the intent could not be set aside", pending_ref=pending["ref"]
        )
    return {
        "status": "abandoned", "document": document, "abandoned_ref": kept,
        "approved_blob": pending["approved_blob"], "baseline": pending["baseline"],
    }


def locked_sequence(
    *, root: Path, owner: str, branch: str, tip: str, document: str,
    content: bytes | None, message: str | None, expected_working_copy: str | None,
    expected_tip: str | None, operator_quiescent: bool,
) -> dict:
    check_supported_name(document)
    confine(root, document)
    pending = read_pending(root, owner, document)
    applied = validate_applied(root, owner, document)
    if pending is None:
        require_applied_matches_document(root, document, applied)
    else:
        require_applied_agrees_with_pending(root, owner, pending, applied)
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
        content = git(["cat-file", "blob", pending["approved_blob"]], cwd=root).stdout
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
            root, owner, branch, document, pending, approved_blob, content, message,
            operator_quiescent,
        )
    return start_fresh(
        root, owner, branch, tip, document, approved_blob, content, message,
        expected_working_copy, expected_tip, operator_quiescent,
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
    operator_quiescent: bool = False,
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
        tip = fresh_tip(resolved, branch)
        lock = lock_ref(owner, document)
        held = acquire_lock(resolved, lock, tip, owner, document)
        try:
            outcome = locked_sequence(
                root=resolved, owner=owner, branch=branch, tip=tip, document=document,
                content=content, message=message,
                expected_working_copy=expected_working_copy, expected_tip=expected_tip,
                operator_quiescent=operator_quiescent,
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


def clear_stale_lock_checked(
    root: Path, repository: str, document: str, operator_quiescent: bool = False
) -> dict:
    """`clear_stale_lock`, refused while the tool's child may still be running: a
    dead helper alone does not prove its publication child has stopped. A child
    known to be live is never overridden, an unreadable intent refuses rather than
    reading as none, and the operator's confirmation covers only an identity that
    was never recorded."""
    resolved = resolve_write_root(root)
    owner = verify_owner(resolved, repository)
    pending = read_pending(resolved, owner, document)
    children = "none" if pending is None else child_state(pending["handoff"])
    if children == "live" or (children == "unknown" and not operator_quiescent):
        raise DocumentError(
            "lock-child-not-quiescent",
            f"the tool's child process is {children}, so the lock stays; "
            "establish quiescence first",
            pending_ref=pending["ref"],
        )
    return clear_stale_lock(resolved, lock_ref(owner, document))


# ---------------------------------------------------------------- preflight --


def tracker_transaction_module():
    """tools/tracker_transaction.py, loaded from beside this file.

    A plain `import` would need `tools/` on `sys.path`, which it is when this
    module runs as a script from the repository and is not when a bundled copy
    runs from a plugin install. That module loads this one only on its local
    resolution path, which this module never reaches, so the two loads do not
    recur. tools/test_approved_document.py pins the shared (repository,
    document) digest equal.
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


def orphan_captures(root: Path, document: str, record: dict | None) -> list[str]:
    """Populated capture directories beside the document that no intent names.

    A leftover from a record that predates the descriptor (or a deleted one) is
    custody of a real file nobody is tracking: it is reported for manual
    binding or restoration, never guessed to belong to a new approval and never
    deleted. An empty reservation is harmless and is not reported."""
    owned = None
    if record is not None and record.get("capture"):
        owned = record["capture"]["directory"]
    found = []
    try:
        for entry in sorted((root / document).parent.glob(".kanban-attempt-*")):
            if entry.name == owned or entry.is_symlink() or not entry.is_dir():
                continue
            files = sorted(child.name for child in entry.iterdir())
            if files:
                found.append(str(entry))
    except OSError:
        return [str((root / document).parent / ".kanban-attempt-*") + " (unreadable)"]
    return found


def preflight_once(root: Path, repository: str, branch: str, document: str) -> dict:
    """One evaluation of `check_pending`'s question — whether an earlier approved
    mutation of this document is outstanding —
    its publication, its tracker mutations, or both.

    Callers mutate the tracker before they publish, so this has to be askable
    before they do. It repairs nothing and takes no lock (its fetch is the one
    Git update it makes); the mutating entry point revalidates under the lock.
    `status` is exactly `clear` or `pending`, `publication_tip` is the freshly
    fetched tip, and `working_copy_blob` is the baseline the caller passes back
    as `--expected-working-copy`. Unknown is reported as null, never as false.

    A tool or module that cannot be read fails closed, with the records already
    read attached: the caller's reason for asking is whether it may mutate the
    tracker, and a tool that cannot land the document is a reason to stop
    before the first irreversible step, not after it.
    """
    resolved = resolve_write_root(root)
    owner = verify_owner(resolved, repository)
    check_supported_name(document)
    confine(resolved, document)
    pending_name = pending_ref(owner, document)
    module = tracker_transaction_module()
    try:
        tracker = module.check(resolved, repository, document)
    except Exception as error:  # noqa: BLE001 - the preflight must stay structured
        tracker = {
            "status": "outstanding",
            "message": getattr(error, "message", str(error)),
        } | module.observed_report(resolved, module.transaction_ref(owner, document))
    record, fault = None, None
    try:
        record = read_pending(resolved, owner, document)
        applied = validate_applied(resolved, owner, document)
        if record is None:
            require_applied_matches_document(resolved, document, applied)
        elif applied not in (None, record["approved_blob"], record["payloads"].get("predecessor")):
            raise DocumentError(
                "applied-conflict",
                f"the applied record names {applied[:12]}, which is neither this "
                "attempt's content nor its rooted predecessor",
                applied_object=applied,
            )
    except DocumentError as error:
        fault = error
    working = None
    try:
        working = file_state(resolved / document)[1]
    except DocumentError as error:
        # An unreadable document is neither clear nor absent: it is pending.
        fault = fault or error
    kinds = []
    if record is not None or fault is not None:
        kinds.append("publication")
    if tracker["status"] != "clear":
        kinds.append("tracker-transaction")
    orphans = orphan_captures(resolved, document, record)
    if orphans:
        kinds.append("capture")
    try:
        # Not check=False: the tip this returns becomes the caller's binding,
        # and one minted from a stale cached ref reads as current.
        fresh = fresh_tip(resolved, branch)
        outcome = {
            "status": "pending" if kinds else "clear",
            "document": document,
            "pending_ref": pending_name,
            "publication_tip": fresh,
            "working_copy_blob": working,
            "pending_kinds": kinds,
            "tracker_transaction": tracker,
            "orphan_captures": orphans,
        }
        if fault is not None:
            outcome |= {
                "pending_commit": read_ref(resolved, pending_name),
                "record_fault": {"status": fault.status, "message": fault.message},
                "already_landed": None,
                "resolution": (
                    f"{fault.message}. Stop: no further disposition of this "
                    "document is permitted until the record is resolved by hand"
                ),
            }
        elif record is not None:
            landed, info, landing_fault = None, None, None
            try:
                info = landing(resolved, branch, record, fresh)
                landed = info["landed"]
            except DocumentError as error:
                landing_fault = error
            outcome |= {
                "pending_commit": record["commit"],
                "record_form": record["form"],
                "record_version": record["version"],
                "recorded_blob": record["approved_blob"],
                "already_landed": landed,
                "published_blob": None if not info or not landed else info["published_blob"],
                "evidence": None if not info or not landed else {
                    "via": info["via"], "commit": info["evidence_commit"],
                },
                "applied_blob": read_ref(resolved, applied_ref(owner, document)) or None,
                "handoff": None if record["handoff"] is None else {
                    "state": record["handoff"]["state"],
                    "child": child_state(record["handoff"]),
                },
                "resolution": (
                    "the recorded publication reached the branch; run --resume to "
                    "verify it and clear the record"
                    if landed
                    else f"{landing_fault.message}. Stop: resolve the record by hand"
                    if landing_fault is not None
                    else "run --resume to retry the recorded publication through "
                    f"{TOOL}, or set the intent aside with --abandon-intent; do not "
                    "approve a different disposition for this document first"
                ),
            }
            if record["capture"] is not None:
                try:
                    seen = inspect_capture(resolved, record)
                    outcome["capture"] = {
                        "aside": str(seen["aside_path"]),
                        "states": {
                            "aside": seen["aside"][0], "scratch": seen["scratch"][0],
                            "target": seen["target"][0],
                        },
                    }
                except DocumentError as error:
                    outcome["capture"] = {"fault": error.message}
                outcome["resolution"] = (
                    "an interrupted capture of the document is recorded; run "
                    "--resume to settle it from what is on disk"
                )
            if landing_fault is not None:
                outcome["record_fault"] = {
                    "status": landing_fault.status, "message": landing_fault.message,
                }
    except Exception as error:  # noqa: BLE001 - the report survives the failure
        if not isinstance(error, DocumentError):
            error = DocumentError("internal-error", f"{type(error).__name__}: {error}")
        error.detail.setdefault("pending_kinds", kinds)
        error.detail.setdefault("tracker_transaction", tracker)
        error.detail.setdefault("already_landed", None)
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


def preflight_snapshot(resolved: Path, owner: str, document: str, module) -> tuple:
    """The records a preflight's answer depends on, read fail-closed."""
    try:
        working = file_state(resolved / document)
    except DocumentError as error:
        working = ("unreadable", error.message)
    return (
        ref_oid(resolved, lock_ref(owner, document)),
        ref_oid(resolved, pending_ref(owner, document)),
        ref_oid(resolved, applied_ref(owner, document)),
        module.ref_value(resolved, module.transaction_ref(owner, document)),
        working,
    )


def check_pending(root: Path, repository: str, branch: str, document: str) -> dict:
    """Whether an earlier approved mutation of this document is outstanding —
    its publication, its tracker mutations, or both — answered from a stable
    snapshot.

    A preflight that raced another run could report `clear` over a publication
    that finished while it was fetching. So the lock and the records are read
    before and after, a held lock is reported (`pending`, kind `lock`) rather
    than ignored, and a snapshot that moved is re-read; one that will not settle
    is a refusal, not an answer. The mutating entry point revalidates under the
    document lock either way.
    """
    resolved = resolve_write_root(root)
    owner = verify_owner(resolved, repository)
    check_supported_name(document)
    module = tracker_transaction_module()
    for _ in range(3):
        before = preflight_snapshot(resolved, owner, document, module)
        outcome = preflight_once(resolved, repository, branch, document)
        after = preflight_snapshot(resolved, owner, document, module)
        if before == after:
            break
    else:
        raise DocumentError(
            "preflight-changed",
            f"the records for {document} kept changing while the preflight read "
            "them, so no answer is given; run it again when no other run is active",
            pending_ref=pending_ref(owner, document),
        )
    if after[0]:
        outcome["pending_kinds"] = list(outcome["pending_kinds"]) + ["lock"]
        outcome["status"] = "pending"
        outcome["lock"] = {
            "ref": lock_ref(owner, document), "owner": read_lock_owner(resolved, lock_ref(owner, document)),
        }
        outcome.setdefault(
            "resolution",
            "another run holds this document's lock (or one died holding it); "
            "wait for it, or clear a provably abandoned lock with --clear-stale-lock",
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
    parser.add_argument(
        "--operator-quiescent",
        action="store_true",
        help="the operator has established that no earlier tool child is running "
        "(for a handoff whose child identity was never recorded)",
    )
    parser.add_argument(
        "--abandon-intent",
        action="store_true",
        help="set aside an intent whose content has been accounted for",
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
            check_supported_name(args.path)
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
            outcome = clear_stale_lock_checked(
                args.root, args.repo, args.path, args.operator_quiescent
            )
        elif args.abandon_intent:
            root = resolve_write_root(args.root)
            outcome = abandon_intent(root, verify_owner(root, args.repo), args.path)
        else:
            content = None
            if not args.resume:
                if args.content is None:
                    parser.error(
                        "--content is required unless --resume, --abandon-intent "
                        "or --clear-stale-lock is given"
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
                operator_quiescent=args.operator_quiescent,
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
    return 0 if outcome.get("status") in ("published", "cleared", "no-lock", "abandoned") else 1


if __name__ == "__main__":
    raise SystemExit(main())
