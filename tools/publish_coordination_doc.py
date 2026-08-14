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
import json
import os
import re
import socket
import subprocess
import sys
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


def is_ancestor(root: Path, commit: str, revision: str) -> bool:
    return (
        git(
            ["merge-base", "--is-ancestor", commit, revision], cwd=root, check=False
        ).returncode
        == 0
    )


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
    git(["update-ref", "-d", pending], cwd=root, check=False)
    return {
        "status": "published",
        "resumed": "already-landed",
        "commit": recorded,
        "published_blob": blob_at(root, recorded, document),
        "remote_contains_commit": True,
        "document": document,
        "branch": branch,
        "document_edit": {"exists": True, "write_root": str(root), "path": document},
    }


def publish(
    *, repository: str, branch: str, root: Path, document: str, content: bytes, message: str
) -> dict:
    root = resolve_write_root(root)
    owner = verify_owner(root, repository)

    git(["fetch", "origin", branch], cwd=root)
    tip = git_out(["rev-parse", f"origin/{branch}"], cwd=root)

    lock = lock_ref(owner, document)
    pending = pending_ref(owner, document)
    acquire_lock(root, lock, tip)
    try:
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

        current = working_blob(root, document)
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
        if working_blob(root, document) != baseline:
            raise PublishError(
                "document-changed-before-write",
                f"{document} changed after its baseline was verified; nothing was "
                "written and nothing was published",
            )
        (root / document).write_bytes(content)

        commit = build_commit(root, tip, document, approved_blob, message)
        touched = changed_paths(root, tip, commit)
        if touched != [document]:
            raise PublishError(
                "not-isolated",
                f"the publication commit changes {touched} rather than {document} alone",
                changed_paths=touched,
            )

        landed, push_error = _push_and_verify(root, branch, commit, pending)
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
    finally:
        release_lock(root, lock)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Publish one approved mutation.")
    parser.add_argument("--repo", required=True, help="the owning owner/name")
    parser.add_argument("--branch", required=True, help="the publication branch")
    parser.add_argument("--root", required=True, type=Path, help="the local write root")
    parser.add_argument("--path", required=True, help="repository-relative document")
    parser.add_argument("--content", type=Path, help="file holding the approved content")
    parser.add_argument("--message", default=None)
    parser.add_argument("--clear-stale-lock", action="store_true")
    args = parser.parse_args(argv)

    try:
        if args.clear_stale_lock:
            root = resolve_write_root(args.root)
            owner = verify_owner(root, args.repo)
            outcome = clear_stale_lock(root, lock_ref(owner, args.path))
        else:
            if args.content is None:
                parser.error("--content is required unless --clear-stale-lock is given")
            outcome = publish(
                repository=args.repo,
                branch=args.branch,
                root=args.root,
                document=args.path,
                content=args.content.read_bytes(),
                message=args.message
                or f"docs: publish the approved mutation to {args.path}",
            )
    except PublishError as error:
        print(
            json.dumps(
                {"status": error.status, "message": error.message, **error.detail},
                indent=2,
                sort_keys=True,
                default=str,
            )
        )
        return 1
    print(json.dumps(outcome, indent=2, sort_keys=True, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
