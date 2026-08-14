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
    if actual != CANONICAL_REPOSITORY:
        raise PublishError(
            "not-eligible",
            f"{actual} has no coordination lane; §7 classifies "
            f"{CANONICAL_REPOSITORY} and nothing else",
            repository=actual,
        )
    return actual


# -------------------------------------------------------------------- lock --


def _key(repository: str, document: str) -> str:
    return f"{repository}/{document}".replace("/", "-")


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


def owner_token() -> str:
    return json.dumps(
        {"host": socket.gethostname(), "pid": os.getpid()},
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


def acquire_lock(root: Path, ref: str, tip: str) -> None:
    """Atomic per-document mutual exclusion.

    `update-ref <ref> <new> ""` requires the ref to be absent, and creating it
    is atomic, so exactly one caller wins. The ref points at a commit whose
    subject carries this run's ownership identity, which is what lets a stale
    lock be told from a live one.
    """
    commit = git_out(
        ["commit-tree", f"{tip}^{{tree}}", "-m", owner_token()], cwd=root
    )
    proc = git(["update-ref", ref, commit, ""], cwd=root, check=False)
    if proc.returncode != 0:
        raise PublishError(
            "locked",
            "another run holds this document's publication lock",
            lock_ref=ref,
            lock_owner=read_lock_owner(root, ref) or {},
        )


def release_lock(root: Path, ref: str) -> None:
    git(["update-ref", "-d", ref], cwd=root, check=False)


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
    holder = read_lock_owner(root, ref)
    if holder is None:
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
    release_lock(root, ref)
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


def require_eligible(root: Path, tip: str, document: str) -> list[str]:
    proc = git(["show", f"{tip}:{CLASSIFICATION_PATH}"], cwd=root, check=False)
    if proc.returncode != 0:
        raise PublishError(
            "not-eligible",
            f"the publication tip carries no {CLASSIFICATION_PATH}, so it has no "
            "coordination lane",
        )
    klass, matched = classify(
        parse_classification(proc.stdout.decode(errors="replace")), document
    )
    if klass != COORDINATION_CLASS:
        raise PublishError(
            "not-eligible",
            f"{document} is not classified {COORDINATION_CLASS} by §7 of the "
            "publication tip",
            classification=klass,
            matching_rows=matched,
        )
    return matched


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


def replace_document(scratch: Path, target: Path) -> None:
    """The atomic swap, as a seam a test can inject into.

    Everything the module can do about the instant between its last look and
    this call is on the other side of it — so this is the boundary a race test
    has to be able to reach.
    """
    os.replace(scratch, target)


def verify_and_write(root: Path, document: str, baseline: str, content: bytes) -> None:
    """Replace the document, refusing — and undoing — if it is not the baseline.

    A check followed by a write can always be raced: nothing stops another
    process writing in the instant between them, and no POSIX primitive offers
    compare-and-swap on file content. So this does not rely on the check
    holding. It takes a hard link to the document's inode first, and that link
    is what the swap is judged against afterwards:

    - an in-place edit landing at any point before the swap is visible through
      the link, because the link and the document are the same inode. The
      content is preserved in the object database, the swap is undone by
      putting that inode back, and the run fails closed;
    - a writer that *replaces* the document instead changes its inode, which is
      compared against the link's before the swap;

    so an outside edit is either refused before the swap or restored after it,
    and in both cases recoverable. The swap itself is atomic, so no reader sees
    a torn document.
    """
    target = root / document
    backup = handle = scratch = None
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
        # mkstemp creates 0600. Replacing the document with it would silently
        # narrow the permissions of a file other people and processes read, so
        # the swap carries the mode the document already had.
        os.chmod(scratch, os.stat(target).st_mode & 0o7777)

        backup = Path(
            tempfile.mkdtemp(prefix=".kanban-publish-backup-", dir=str(target.parent))
        ) / target.name
        os.link(target, backup)
        if os.stat(target).st_ino != os.stat(backup).st_ino:
            raise PublishError(
                "document-changed-before-write",
                f"{document} was replaced by another writer before the swap; "
                "nothing was published",
            )

        replace_document(scratch, target)
        scratch = None

        # The link still names the inode the document had. Anything written
        # into it up to the swap is visible here, and undoable.
        landed, _ = read_for_write(backup)
        if git_blob_hash(landed) != baseline:
            preserved = _preserve(root, landed)
            os.replace(backup, target)
            backup = None
            raise PublishError(
                "document-changed-before-write",
                f"{document} was changed between its verification and the swap; "
                "the change was restored and nothing was published",
                preserved_blob=preserved,
            )
    except OSError as error:
        # An unwritable document is an unpublished outcome like any other, not
        # a traceback for the caller to interpret.
        raise PublishError(
            "document-unwritable",
            f"{document} could not be read or replaced: {error}",
        ) from error
    finally:
        if handle is not None:
            os.close(handle)
        # Only ever this invocation's own temporaries, each created
        # exclusively: a deterministic name would collide with — and delete —
        # an unrelated untracked file that happened to be called the same.
        if scratch is not None:
            scratch.unlink(missing_ok=True)
        if backup is not None:
            backup.unlink(missing_ok=True)
            backup.parent.rmdir()


def build_commit(root: Path, tip: str, document: str, blob: str, message: str) -> str:
    """A commit on `tip` whose tree is `tip`'s with exactly one blob replaced.

    Built through a scratch index in the common Git directory, so the write
    root's own index is never touched — the caller's staged work elsewhere is
    not this module's to disturb — and a tree derived from `tip` cannot carry a
    second path.
    """
    scratch = common_git_dir(root) / f"kanban-publish-index-{_key('', document)}-{blob}"
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
        scratch.unlink(missing_ok=True)
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
    root: Path, branch: str, tip: str, document: str, pending: str, current: str
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
        )
    parent = git_out(["rev-parse", f"{recorded}^"], cwd=root)
    if parent != tip:
        raise PublishError(
            "pending-stale",
            f"the pending publication for {document} was built on {parent[:12]}, but "
            f"the branch has advanced to {tip[:12]}; retrying would replace the "
            "advance with pre-advance content",
            pending_commit=recorded,
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
    git(["update-ref", "-d", pending], cwd=root, check=False)
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


def resolve_landed_pending(root: Path, branch: str, pending: str, document: str):
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
    if working_blob(root, document) != approved or staged_blob(
        root, document
    ) != head_blob(root, document):
        # The publication did land — that is a fact about the remote, reported
        # as one. What is refused is *clearing the record*, because the write
        # root no longer holds what landed: something changed or staged the
        # document afterwards, and dropping the record would leave that
        # divergence with nothing pointing at it.
        raise PublishError(
            "landed-but-divergent",
            f"the recorded publication for {document} reached {branch}, but the "
            "document has been changed or staged since; the record is kept so the "
            "divergence is not lost",
            remote_contains_commit=True,
            local_commit=recorded,
            published_blob=approved,
            pending_ref=pending,
        )
    git(["update-ref", "-d", pending], cwd=root, check=False)
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
    *, repository: str, branch: str, root: Path, document: str, content: bytes, message: str
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

        lock = lock_ref(owner, document)
        pending = pending_ref(owner, document)
        acquire_lock(resolved, lock, tip)
        try:
            return _publish_locked(
                root=resolved, owner=owner, branch=branch, tip=tip, document=document,
                content=content, message=message, pending=pending,
            )
        finally:
            release_lock(resolved, lock)
    except PublishError as error:
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
        raise


def _publish_locked(*, root, owner, branch, tip, document, content, message, pending):
    """The sequence itself, run with the lock held. Split from publish() so
    every failure leaving it passes through one place that attaches §9.5's
    three states."""
    require_eligible(root, tip, document)

    baseline = blob_at(root, tip, document)
    if baseline is None:
        raise PublishError(
            "not-eligible",
            f"{document} is absent from the publication tip; a novel document "
            "stays local until a pull request adds it and its classification",
        )

    already = resolve_landed_pending(root, branch, pending, document)
    if already is not None:
        return {"repository": owner, "publication_tip": tip} | already

    require_unstaged(root, document)

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
            root, branch, tip, document, pending, current
        )

    approved_blob = git_out(
        ["hash-object", "-w", "-t", "blob", "--stdin"], cwd=root, input_bytes=content
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

    git(["update-ref", "-d", pending], cwd=root, check=False)
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
    parser.add_argument("--clear-stale-lock", action="store_true")
    parser.add_argument(
        "--new-content-file",
        action="store_true",
        help="mint and print a scratch path for this invocation's content",
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
        if args.clear_stale_lock:
            root = resolve_write_root(args.root)
            owner = verify_owner(root, args.repo)
            outcome = clear_stale_lock(root, lock_ref(owner, args.path))
        else:
            if args.content is None:
                parser.error("--content is required unless --clear-stale-lock is given")
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
            )
    except PublishError as error:
        # The envelope is guaranteed at this boundary, not only inside
        # publish(): a failure raised before the sequence starts — unreadable
        # content, an unusable write root — is still an unpublished outcome the
        # caller must report all three states for.
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
