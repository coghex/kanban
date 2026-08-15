#!/usr/bin/env python3
"""Checkpoint the tracker mutations of one approved document disposition.

Run as:

    python3 tools/tracker_transaction.py \\
        --repo coghex/kanban --root <write-root> --path docs/ui-bugs.md \\
        --acquire --approved --publication-tip <sha> --plan -   < plan.json

Issue #327. `tools/publish_coordination_doc.py` made the *document* half of a
disposition recoverable: a pending publication is recorded before the push, and
the processing workflows stop during preflight while one is outstanding. The
*tracker* half had no such record. A run could create a label, create an issue,
comment on another, and edit an umbrella epic, then terminate before the
document mutation was recorded — and the next invocation would see an unchanged
document, a clear publication preflight, and repeat every one of those
mutations.

This module is the whole mechanism for that missing half, and it is the only
place that mechanism exists. The four processing assets declared in
docs/document-workflow-contract.md §2 keep the policy §9.6 states — when to
acquire, what needs approval, what to report — and invoke this rather than
restating it, for exactly the reason issue #315 gave for the publication
sequence: a sequence written as shell inside a Markdown asset is a chain a
reader can reorder or half-apply, and nothing in the tree can execute it to
find the twenty-first defect.

## The record is repository-shared, not worktree-local

The declared assets write in the `docs-wip` linked worktree, and a later
invocation may resolve a different write root for the same repository. So the
record is a Git reference under `refs/kanban/tracker-transaction/`, resolved
through the repository's *common* Git directory, which every linked worktree of
the clone shares — the same placement `tools/publish_coordination_doc.py` uses
for its pending-publication record, and for the same reason.

## Every transition is a compare-and-swap

`git update-ref <ref> <new> <old>` moves the reference only while it still
holds `<old>`, and `<old>` empty requires the reference to be *absent*. So
acquisition is create-only and atomic — two runs that both observed a clear
read-only preflight cannot both proceed — and no interrupted or losing
transition can erase the durable value that was already there. On top of that,
a transition that would drop or rewrite a confirmed step's identity is refused
outright: a confirmed mutation has already happened, and a record that forgets
it is a record that authorizes doing it again.

## Ambiguity is never resolved automatically

A step enters `intent` before its external mutation begins and records its
exact identity before the next step starts. A process killed in that window
leaves the step ambiguous: GitHub may or may not have accepted the mutation,
and — server-side idempotency being out of scope — nothing here can tell which.
So this module never retries, never adopts a candidate, never advances, never
publishes, and never clears such a record on its own. It advances only on an
explicit human approval that names one exact artifact whose recorded target and
payload fingerprint match, or authorizes a retry against read-only evidence
that the intended postcondition is absent.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import secrets
import socket
import subprocess
import sys
from pathlib import Path

NAMESPACE = "refs/kanban/tracker-transaction"

# The record travels as a blob in the reference's tree rather than in its commit
# subject. A subject is a message, and `commit-tree` is entitled to clean one
# up; a record is data, and an ordered plan of approved payloads is not
# something to hand to a cleanup rule.
RECORD_FILENAME = "record.json"
RECORD_SUBJECT = "kanban tracker transaction record"
RECORD_VERSION = 1

STATE_INTENT_ONLY = "intent-only"
STATE_TRACKER_PENDING = "tracker-pending"
STATE_MUTATION_CONFIRMED = "mutation-confirmed"
STATE_PUBLICATION_PENDING = "publication-pending"
STATE_RESOLVED = "resolved"

RECORD_STATES = (
    STATE_INTENT_ONLY,
    STATE_TRACKER_PENDING,
    STATE_MUTATION_CONFIRMED,
    STATE_PUBLICATION_PENDING,
)

STEP_PLANNED = "planned"
STEP_INTENT = "intent"
STEP_CONFIRMED = "confirmed"

# The tracker-side mutations the four processing assets actually perform, plus
# one declared catch-all. A closed set is the fail-closed choice: an unrecognized
# kind is a plan this module cannot reason about, and accepting it would let a
# mutation be checkpointed under a name no reconciliation rule knows.
STEP_KINDS = (
    "label-create",
    "issue-create",
    "epic-create",
    "epic-adopt-edit",
    "epic-checklist-edit",
    "issue-comment",
    "tracker-edit",
)

# What a plan step must carry, all of them non-empty strings: requirement 4 of
# issue #327 asks for the exact approved target, the payload fingerprint, and
# the observable postcondition, because a fresh invocation with no conversation
# history has nothing else to check a candidate artifact against.
STEP_PLAN_FIELDS = ("kind", "target", "payload_fingerprint", "postcondition")

# What a record read back from the reference must actually contain. Every reader
# below indexes these directly, so this is the boundary at which a document that
# merely parses as JSON stops being mistaken for a record.
RECORD_FIELDS = (
    "repository", "document", "entry_key", "disposition", "state", "steps",
)
RECORD_STEP_FIELDS = (
    "kind", "target", "payload_fingerprint", "postcondition", "state", "identity",
)

DISPOSITIONS = ("new-issue", "existing-issue", "epic-create", "epic-adopt")

# The two kinds that create something the document then names. Everything else
# mutates the tracker without contributing a token the entry must carry, which
# is the distinction requirement 11's "every exact tracker identity *required by
# that disposition*" turns on.
ISSUE_IDENTITY_KINDS = ("issue-create", "epic-create")

MARKER_RE = re.compile(r"^\[#\d+\]$")

# §4's terminal checklist entry, which is what a resolved disposition looks like
# in every document these workflows own. `- [ ]` is an entry the document still
# owes, and a line that is no checklist entry at all is prose.
TERMINAL_ENTRY_RE = re.compile(r"^\s*[-*]\s*\[[xX]\]\s")

# §4's other two markers. Both are terminal-or-not dispositions that mutate no
# tracker and therefore acquire no transaction, so either one appearing on the
# entry a transaction is resolving against contradicts the record.
CONTRADICTORY_MARKERS = ("[no-issue]", "[deferred]")

# Git's "no old value" object name, in both hash lengths. Passed to a delete it
# disables the binding rather than asserting it, so it is refused where a bound
# value is required.
NULL_OID_RE = re.compile(r"^0{40,64}$")


class TransactionError(Exception):
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
        raise TransactionError("git-failed", f"git {' '.join(args)} failed: {detail}")
    return proc


def git_out(args, *, cwd: Path, input_bytes: bytes | None = None) -> str:
    return git(args, cwd=cwd, input_bytes=input_bytes).stdout.decode().strip()


# ---------------------------------------------------------------- identity --
#
# The four helpers below are deliberately this module's own rather than imported
# from tools/publish_coordination_doc.py, which defines the same four. That
# module loads *this* one to report both outstanding records from a single
# preflight (requirement 8), so importing back would make two independently
# invocable command-line tools mutually dependent. The duplication is pinned
# instead: tools/test_tracker_transaction.py asserts both modules key a
# (repository, document) pair identically, so the two cannot drift apart
# unnoticed.


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
        raise TransactionError(
            "bad-repository", f"not an owner/name repository: {raw!r}"
        )
    return "/".join(parts[-2:]).lower()


def resolve_write_root(root: Path) -> Path:
    if not root.is_dir():
        raise TransactionError(
            "bad-write-root", f"write root is not a directory: {root}"
        )
    return Path(git_out(["rev-parse", "--show-toplevel"], cwd=root))


def verify_owner(root: Path, declared: str) -> str:
    """The owner established from the write root's own `origin`, refusing when
    it disagrees with what the caller declared. A tracker transaction is
    irreversible in the wrong repository for exactly the reason §8 gives about
    an issue filed there."""
    proc = git(["remote", "get-url", "origin"], cwd=root, check=False)
    if proc.returncode != 0:
        raise TransactionError(
            "owner-unverifiable",
            f"write root {root} has no origin remote to establish its owner from",
        )
    actual = normalized_slug(proc.stdout.decode())
    wanted = normalized_slug(declared)
    if actual != wanted:
        raise TransactionError(
            "owner-mismatch",
            f"write root {root} belongs to {actual}, not the declared {wanted}",
            write_root_repository=actual,
            declared_repository=wanted,
        )
    return actual


def record_key(repository: str, document: str) -> str:
    """A ref-safe name for one (repository, document) pair, and a distinct one
    for every pair. A digest rather than a path substitution, so `docs/a-b.md`
    and `docs/a/b.md` cannot share one record — the payload carries both values
    in clear for a human to read back."""
    return hashlib.sha256(f"{repository}\0{document}".encode()).hexdigest()[:40]


def transaction_ref(repository: str, document: str) -> str:
    return f"{NAMESPACE}/{record_key(repository, document)}"


# ------------------------------------------------------------------ record --


def record_fault(
    record: dict, *, repository: str | None = None, document: str | None = None
) -> str | None:
    """What stops `record` being usable, or None when nothing does.

    The whole persisted plan, not merely the presence of its keys. A record is
    the only thing a resuming session has: it re-presents each remaining step's
    recorded target and payload for approval and checks a candidate artifact
    against its fingerprint and postcondition, so a step whose target is the
    empty string is not a step that can be resumed — it is a corrupt record that
    must stop the run rather than authorize a mutation nobody can check.

    Validated in one place, and by the writer too: `validate_plan` runs this
    over the record it just built, so what may be acquired and what may be read
    back cannot drift apart.

    The `(repository, document)` binding is checked when the caller knows what
    it asked for. The reference name is a digest of that pair, so a record
    naming a different one is corrupt however it got there.
    """
    missing = [field for field in RECORD_FIELDS if field not in record]
    if missing:
        return f"it is missing {missing}"
    for field in ("repository", "document", "entry_key", "publication_tip"):
        if not isinstance(record.get(field), str) or not record[field].strip():
            return f"its {field} is not a non-empty string"
    if repository is not None and record["repository"] != repository:
        return (
            f"it belongs to {record['repository']!r}, not the {repository!r} it "
            "was read for"
        )
    if document is not None and record["document"] != document:
        return (
            f"it records {record['document']!r}, not the {document!r} it was read "
            "for"
        )
    if record["state"] not in RECORD_STATES:
        return f"its state {record['state']!r} is not a known transaction state"
    if record["disposition"] not in DISPOSITIONS:
        return f"its disposition {record['disposition']!r} is not a known one"
    marker = record.get("marker")
    if marker is not None and (
        not isinstance(marker, str) or not MARKER_RE.match(marker)
    ):
        return f"its marker {marker!r} is not of the exact form [#N]"
    steps = record["steps"]
    if not isinstance(steps, list) or not steps:
        return "its steps are not a non-empty list"
    for position, step in enumerate(steps):
        if not isinstance(step, dict):
            return f"step {position} is not an object"
        absent = [field for field in RECORD_STEP_FIELDS if field not in step]
        if absent:
            return f"step {position} is missing {absent}"
        for field in STEP_PLAN_FIELDS:
            if not isinstance(step.get(field), str) or not step[field].strip():
                return f"step {position} has no {field}"
        if step["kind"] not in STEP_KINDS:
            return f"step {position} has unknown kind {step['kind']!r}"
        if not isinstance(step.get("provides_marker", False), bool):
            return f"step {position} has a non-boolean provides_marker"
        if step["state"] not in (STEP_PLANNED, STEP_INTENT, STEP_CONFIRMED):
            return f"step {position} has unknown state {step['state']!r}"
        if step["state"] == STEP_CONFIRMED and not isinstance(step["identity"], dict):
            return f"step {position} is confirmed but records no identity"
        if step["state"] != STEP_CONFIRMED and step["identity"] is not None:
            return f"step {position} is {step['state']} but records an identity"
    providers = [
        position
        for position, step in enumerate(steps)
        if step.get("provides_marker")
    ]
    if len(providers) > 1:
        return f"steps {providers} each claim to provide the document marker"
    if bool(marker) == bool(providers):
        return (
            "it has no single source for the marker the published entry must "
            "carry"
        )
    return None


def read_record(
    root: Path, ref: str, *, repository: str | None = None,
    document: str | None = None,
):
    """The durable record and the exact reference value it was read from.

    The value is what every later compare-and-swap binds to, so it travels with
    the record rather than being re-read at write time: re-reading would make
    the transition overwrite whatever happened in between, which is the one
    thing a compare-and-swap exists to refuse.
    """
    observed = git(
        ["rev-parse", "--verify", "--quiet", ref], cwd=root, check=False
    ).stdout.decode().strip()
    if not observed:
        return None, ""
    proc = git(
        ["cat-file", "blob", f"{observed}:{RECORD_FILENAME}"], cwd=root, check=False
    )
    if proc.returncode != 0:
        raise TransactionError(
            "record-unreadable",
            f"the tracker transaction at {ref} carries no {RECORD_FILENAME}; it "
            "cannot be interpreted and must be resolved by hand",
            transaction_ref=ref,
            transaction_commit=observed,
        )
    try:
        record = json.loads(proc.stdout.decode(errors="replace"))
    except json.JSONDecodeError as error:
        raise TransactionError(
            "record-unreadable",
            f"the tracker transaction at {ref} is not valid JSON ({error}); it "
            "cannot be interpreted and must be resolved by hand",
            transaction_ref=ref,
            transaction_commit=observed,
        ) from error
    if not isinstance(record, dict) or record.get("version") != RECORD_VERSION:
        raise TransactionError(
            "record-unreadable",
            f"the tracker transaction at {ref} is not a version {RECORD_VERSION} "
            "record; it cannot be interpreted and must be resolved by hand",
            transaction_ref=ref,
            transaction_commit=observed,
        )
    fault = record_fault(record, repository=repository, document=document)
    if fault is not None:
        # Parsing as JSON is not the same as being a record. Every reader below
        # indexes these fields directly, so a well-formed-but-incomplete
        # document — a half-written record, a hand edit — would fail somewhere
        # deeper as a KeyError, escaping the structured refusal this raise
        # exists to give and reaching the caller as a generic internal error
        # with nothing about the transaction in it.
        raise TransactionError(
            "record-unreadable",
            f"the tracker transaction at {ref} is not a well-formed record "
            f"({fault}); it cannot be interpreted and must be resolved by hand",
            transaction_ref=ref,
            transaction_commit=observed,
        )
    return record, observed


def confirmations(record: dict) -> dict:
    return {
        index: step.get("identity")
        for index, step in enumerate(record["steps"])
        if step["state"] == STEP_CONFIRMED
    }


def require_preserved_confirmations(old: dict | None, new: dict) -> None:
    """Requirement 7, enforced at the one place every transition passes.

    A confirmed step's identity is the evidence that its mutation already
    happened. A transition that dropped or rewrote one would leave a record
    that authorizes repeating a mutation GitHub has already accepted, which is
    the failure this whole module exists to prevent — so it is refused here
    rather than trusted to each caller.
    """
    if old is None:
        return
    before, after = confirmations(old), confirmations(new)
    lost = sorted(
        index
        for index, identity in before.items()
        if index not in after or after[index] != identity
    )
    if lost:
        raise TransactionError(
            "confirmation-erased",
            f"the transition would drop or rewrite the confirmed identity of "
            f"step(s) {lost}; a confirmed mutation is never repeated and never "
            "forgotten",
            erased_steps=lost,
        )


def observed_report(
    root: Path, ref: str, *, repository: str | None = None,
    document: str | None = None,
) -> dict:
    """What is durably recorded right now, for a report that has to say so.

    A losing create-only acquisition and a losing compare-and-swap both fail
    because somebody else's record is there, and that record — not this run's
    rejected candidate — is the recovery state the run has to report and resume
    from. Reading it can itself fail, and that answer travels too, as an
    explicitly unreadable record rather than an absent one: the report is
    consumed by a caller deciding whether it may mutate anything, and "no
    transaction" is the one conclusion it must never be able to draw here.

    Never raises. It runs while a failure is already on its way out, and an
    exception from the reporting would replace the refusal it was describing.
    """
    try:
        record, observed = read_record(
            root, ref, repository=repository, document=document
        )
        return {"record_readable": True} | transaction_report(record, ref, observed)
    except Exception as error:  # noqa: BLE001 - reporting may not fail
        message = getattr(error, "message", str(error))
        return {
            "acquired": None,
            "transaction_ref": ref,
            "transaction_state": None,
            "record_readable": False,
            "steps": [],
            "completed_steps": [],
            "confirmed_identities": [],
            "ambiguous_step": None,
            "remaining_steps": [],
            "next_action": (
                f"the tracker transaction at {ref} exists but could not be read "
                f"({message}). Stop: no tracker mutation, publication, or "
                "clearing is permitted until it is resolved by hand"
            ),
        }


def _binding(record: dict) -> dict:
    """The `(repository, document)` a record claims, for the reader that is
    about to check the record actually at the reference against it."""
    return {
        "repository": record.get("repository"),
        "document": record.get("document"),
    }


def write_record(root: Path, ref: str, record: dict, old_value: str) -> str:
    """Store `record` and move `ref` to it, only while `ref` still holds
    `old_value`.

    `old_value` empty means create-only: `update-ref` requires the reference to
    be absent, and creating it is atomic, so exactly one of two concurrent
    acquisitions wins. Any other value is the compare-and-swap: a losing or
    interrupted transition leaves the earlier durable record exactly as it was.
    """
    payload = json.dumps(record, sort_keys=True, indent=2).encode() + b"\n"
    blob = git_out(
        ["hash-object", "-w", "-t", "blob", "--stdin"], cwd=root, input_bytes=payload
    )
    tree = git_out(
        ["mktree"],
        cwd=root,
        input_bytes=f"100644 blob {blob}\t{RECORD_FILENAME}\n".encode(),
    )
    commit = git_out(["commit-tree", tree, "-m", RECORD_SUBJECT], cwd=root)
    proc = git(["update-ref", ref, commit, old_value], cwd=root, check=False)
    if proc.returncode != 0:
        # Losing here is the moment the durable record matters most, so the
        # refusal carries what is actually recorded rather than the name of the
        # reference that refused. Whoever lost has to report the transaction
        # state, its confirmed steps and its permitted next action — and on this
        # path there certainly is one, so answering with empty fields would read
        # as "no transaction" precisely where that is false.
        if not old_value:
            raise TransactionError(
                "transaction-outstanding",
                "a tracker transaction is already recorded for this document; "
                "resolve it before approving another disposition",
                **observed_report(root, ref, **_binding(record)),
            )
        raise TransactionError(
            "record-changed",
            "the tracker transaction changed while this transition was being "
            "applied; the earlier record was left exactly as it was",
            expected_commit=old_value,
            **observed_report(root, ref, **_binding(record)),
        )
    return commit


def clear_record(
    root: Path, ref: str, old_value: str, binding: dict | None = None
) -> None:
    """Remove the record, and only ever the exact value this run inspected.
    An unbound delete would remove whatever record happened to be there,
    including one a later run acquired after this one's had already gone.

    The all-zero object name is refused alongside the empty one, because it is
    the second spelling of the same mistake: `git update-ref -d <ref> <zeros>`
    deletes unconditionally rather than requiring the ref to hold that value.
    `rev-parse --verify` never produces it for a ref that exists, so this is a
    guard against a future caller rather than a live path — which is exactly
    when an unbound delete would be hardest to notice.
    """
    if not old_value or NULL_OID_RE.match(old_value):
        raise TransactionError(
            "clear-unbound",
            f"clearing {ref} requires the value this run read it at",
        )
    proc = git(["update-ref", "-d", ref, old_value], cwd=root, check=False)
    if proc.returncode != 0:
        raise TransactionError(
            "record-retained",
            f"the tracker transaction at {ref} could not be cleared; the next "
            "run's preflight will stop until it is resolved",
            # A record still standing stops every later disposition for this
            # document, so the run that could not remove it says what is still
            # there rather than only that removal failed.
            **observed_report(root, ref, **(binding or {})),
        )


# ------------------------------------------------------------------- state --


def derived_state(record: dict) -> str:
    steps = record["steps"]
    confirmed = sum(1 for step in steps if step["state"] == STEP_CONFIRMED)
    if confirmed == len(steps):
        return (
            STATE_PUBLICATION_PENDING
            if record.get("state") == STATE_PUBLICATION_PENDING
            else STATE_MUTATION_CONFIRMED
        )
    if confirmed:
        return STATE_TRACKER_PENDING
    return STATE_INTENT_ONLY


def ambiguous_index(record: dict) -> int | None:
    for index, step in enumerate(record["steps"]):
        if step["state"] == STEP_INTENT:
            return index
    return None


def required_document_tokens(record: dict) -> list[str]:
    """Every token the published entry must carry for this disposition.

    The disposition's own marker, plus the document token of each confirmed
    step that has one. A label creation and an umbrella-checklist edit have no
    token here — they mutate the tracker without appearing in this document —
    which is what requirement 11's "every exact tracker identity *required by
    that disposition*" distinguishes.
    """
    tokens = []
    marker = record.get("marker")
    if marker:
        tokens.append(marker)
    for step in record["steps"]:
        identity = step.get("identity") or {}
        token = identity.get("document_token")
        if token and token not in tokens:
            tokens.append(token)
    return tokens


def next_action(record: dict) -> str:
    index = ambiguous_index(record)
    if index is not None:
        step = record["steps"][index]
        return (
            f"step {index} ({step['kind']}) began but was never confirmed. Verify "
            "read-only whether its exact postcondition holds, then either bind it "
            "to one exact artifact with --reconcile-step or authorize a retry with "
            "--authorize-retry once the postcondition is proven absent. Never "
            "retry, adopt, advance, publish, or clear this record automatically."
        )
    state = derived_state(record)
    if state in (STATE_INTENT_ONLY, STATE_TRACKER_PENDING):
        remaining = [
            index
            for index, step in enumerate(record["steps"])
            if step["state"] != STEP_CONFIRMED
        ]
        return (
            f"resume this disposition: re-present step {remaining[0]}'s exact "
            "target and payload for explicit approval, then --begin-step it. "
            "Confirmed steps are verified and never repeated."
        )
    if state == STATE_MUTATION_CONFIRMED:
        return (
            "every approved tracker mutation is confirmed. Re-run the read-only "
            "publication preflight, render the recorded disposition against the "
            "tip it reports, and publish; do not reuse the recorded preparation "
            "tip as the publication binding."
        )
    return (
        "publication was handed over but not verified. Confirm whether the "
        "recorded entry carries this disposition and every recorded identity, "
        "then --resolve; never repeat a confirmed tracker mutation."
    )


def transaction_report(record: dict | None, ref: str, observed: str) -> dict:
    """Requirement 13's tracker states, beside §9.5's three document states.

    Reported identically by the preflight, by every refusal, and by every
    successful transition, because the run that has to report them is often the
    run that failed, and a caller told to report five things cannot report them
    from a result that carries two.
    """
    if record is None:
        return {
            "acquired": False,
            "transaction_ref": ref,
            "transaction_state": None,
            "steps": [],
            "completed_steps": [],
            "confirmed_identities": [],
            "ambiguous_step": None,
            "remaining_steps": [],
            "next_action": "none; no tracker transaction is outstanding",
        }
    index = ambiguous_index(record)
    steps = [
        {
            "index": position,
            "kind": step["kind"],
            "target": step["target"],
            "payload_fingerprint": step["payload_fingerprint"],
            "postcondition": step["postcondition"],
            "provides_marker": step.get("provides_marker", False),
            "state": step["state"],
            "identity": step.get("identity"),
        }
        for position, step in enumerate(record["steps"])
    ]
    return {
        "acquired": True,
        "transaction_ref": ref,
        "transaction_commit": observed,
        "transaction_state": derived_state(record),
        "repository": record["repository"],
        "document": record["document"],
        "entry_key": record["entry_key"],
        "disposition": record["disposition"],
        "marker": record.get("marker"),
        # Deliberately not named `publication_tip`: this is the tip the
        # disposition was *prepared* against, and a resuming run must re-run the
        # preflight and bind to the tip that reports rather than to this one,
        # which the branch has very likely moved past.
        "prepared_publication_tip": record.get("publication_tip"),
        "steps": steps,
        "completed_steps": [
            step for step in steps if step["state"] == STEP_CONFIRMED
        ],
        "confirmed_identities": [
            step["identity"] for step in steps if step["state"] == STEP_CONFIRMED
        ],
        "ambiguous_step": None if index is None else steps[index],
        "remaining_steps": [
            step for step in steps if step["state"] == STEP_PLANNED
        ],
        "next_action": next_action(record),
    }


# ----------------------------------------------------------------- actions --


def _text(value) -> str:
    return value.strip() if isinstance(value, str) else ""


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def validate_plan(plan, repository: str, document: str, publication_tip: str) -> dict:
    """The approved plan, normalized into a fresh `intent-only` record.

    Everything requirement 4 asks for is required rather than defaulted: a
    fresh invocation with no conversation history resumes from this and nothing
    else, so a field it can omit is a field a resumption cannot check.

    The publication tip arrives as an argument rather than inside the plan so
    the caller can hand the plan over through a quoted heredoc, whose body is
    data rather than a shell to expand — the same shape the packaged assets
    already use to feed a program to `python3`.
    """
    if not isinstance(plan, dict):
        raise TransactionError("plan-invalid", "the plan is not a JSON object")
    entry_key = _text(plan.get("entry_key"))
    disposition = _text(plan.get("disposition"))
    publication_tip = _text(publication_tip)
    marker = _text(plan.get("marker"))
    if "publication_tip" in plan:
        raise TransactionError(
            "plan-invalid",
            "the plan carries its own publication_tip; the tip is bound with "
            "--publication-tip so there is one source of truth for it",
        )
    if not entry_key:
        raise TransactionError("plan-invalid", "the plan names no entry_key")
    if disposition not in DISPOSITIONS:
        raise TransactionError(
            "plan-invalid",
            f"disposition must be one of {list(DISPOSITIONS)}, not {disposition!r}. "
            "A disposition with no tracker mutation acquires no transaction",
        )
    if not publication_tip:
        raise TransactionError(
            "plan-invalid",
            "no --publication-tip was bound; the disposition was prepared "
            "against one, and a resumption reports the mismatch against it",
        )
    raw_steps = plan.get("steps")
    if not isinstance(raw_steps, list) or not raw_steps:
        raise TransactionError(
            "plan-invalid",
            "the plan has no ordered tracker steps. Every approved tracker "
            "mutation is its own checkpointed step, and a disposition that "
            "mutates nothing acquires no transaction at all",
        )
    steps = []
    for position, raw in enumerate(raw_steps):
        if not isinstance(raw, dict):
            raise TransactionError("plan-invalid", f"step {position} is not an object")
        step = {field: _text(raw.get(field)) for field in STEP_PLAN_FIELDS}
        missing = [field for field in STEP_PLAN_FIELDS if not step[field]]
        if missing:
            raise TransactionError(
                "plan-invalid", f"step {position} is missing {missing}"
            )
        if step["kind"] not in STEP_KINDS:
            raise TransactionError(
                "plan-invalid",
                f"step {position} has kind {step['kind']!r}, which is not one of "
                f"{list(STEP_KINDS)}",
            )
        step["provides_marker"] = bool(raw.get("provides_marker"))
        step["state"] = STEP_PLANNED
        step["identity"] = None
        steps.append(step)
    providers = [index for index, step in enumerate(steps) if step["provides_marker"]]
    if len(providers) > 1:
        raise TransactionError(
            "plan-invalid",
            f"steps {providers} each claim to provide the document marker; exactly "
            "one identity can be the one the entry carries",
        )
    if marker and providers:
        raise TransactionError(
            "plan-invalid",
            "the plan supplies a literal marker and also names a step that "
            "provides one; resolution would have two answers to the same question",
        )
    if not marker and not providers:
        raise TransactionError(
            "plan-invalid",
            "the plan supplies neither a literal marker nor a step that provides "
            "one, so no published entry could ever be verified to carry this "
            "disposition",
        )
    if marker and not MARKER_RE.match(marker):
        raise TransactionError(
            "plan-invalid", f"marker {marker!r} is not of the exact form [#N]"
        )
    built = {
        "version": RECORD_VERSION,
        "repository": repository,
        "document": document,
        "entry_key": entry_key,
        "disposition": disposition,
        "marker": marker or None,
        "publication_tip": publication_tip,
        "state": STATE_INTENT_ONLY,
        "acquired_by": {"host": socket.gethostname(), "pid": os.getpid()},
        "steps": steps,
    }
    # The writer holds itself to what the reader will demand, so a plan that
    # would produce a record no later run could interpret is refused now rather
    # than becoming an outstanding transaction nobody can resolve.
    fault = record_fault(built, repository=repository, document=document)
    if fault is not None:
        raise TransactionError(
            "plan-invalid", f"the plan would record an unusable transaction ({fault})"
        )
    return built


def validate_identity(identity, step: dict, index: int) -> dict:
    """The confirmed identity of one mutation, in whatever shape that kind of
    mutation actually has. Requirement 5: a label creation returns a name, an
    issue creation a number and URL, a comment a comment ID, an adoption edit a
    target plus a verified post-edit fingerprint — so what is required is that
    the artifact is identified at all, not that it has an issue number."""
    if not isinstance(identity, dict):
        raise TransactionError(
            "identity-invalid", f"the identity for step {index} is not a JSON object"
        )
    kind = _text(identity.get("kind")) or step["kind"]
    if kind != step["kind"]:
        raise TransactionError(
            "identity-invalid",
            f"the identity for step {index} is a {kind!r}, but the approved step "
            f"is a {step['kind']!r}; a checkpoint records the mutation that was "
            "approved, not another one",
        )
    confirmed = {
        "kind": kind,
        "id": _text(identity.get("id")),
        "url": _text(identity.get("url")) or None,
        "fingerprint": _text(identity.get("fingerprint")) or None,
        "document_token": _text(identity.get("document_token")) or None,
        "metadata": identity.get("metadata"),
        "postcondition_verified": bool(identity.get("postcondition_verified")),
    }
    if not confirmed["id"]:
        raise TransactionError(
            "identity-invalid",
            f"the identity for step {index} names no id; a checkpoint that cannot "
            "name the artifact it created cannot prove the mutation happened",
        )
    if not confirmed["postcondition_verified"]:
        raise TransactionError(
            "identity-invalid",
            f"the identity for step {index} does not report its observable "
            f"postcondition as verified: {step['postcondition']}",
        )
    if confirmed["metadata"] is not None and not isinstance(confirmed["metadata"], dict):
        raise TransactionError(
            "identity-invalid",
            f"the metadata for step {index} is not a JSON object",
        )
    if confirmed["document_token"] and not MARKER_RE.match(confirmed["document_token"]):
        raise TransactionError(
            "identity-invalid",
            f"document_token {confirmed['document_token']!r} is not of the exact "
            "form [#N]",
        )
    # What "the identity appropriate to its mutation kind" actually means, per
    # kind. Without this the fields are decorative: an issue creation could
    # record any id beside any document token, and resolution — which checks
    # only the token — would then clear a record whose documented artifact is
    # not the one the tracker actually got.
    if kind in ISSUE_IDENTITY_KINDS:
        if not confirmed["id"].isdigit():
            raise TransactionError(
                "identity-invalid",
                f"step {index} created an issue, so its id is that issue's number, "
                f"not {confirmed['id']!r}",
            )
        if not confirmed["url"]:
            raise TransactionError(
                "identity-invalid", f"step {index} records no url for its issue"
            )
        if confirmed["url"].rstrip("/").rsplit("/", 1)[-1] != confirmed["id"]:
            raise TransactionError(
                "identity-invalid",
                f"step {index}'s url {confirmed['url']} does not name issue "
                f"{confirmed['id']}",
            )
        if confirmed["document_token"] != f"[#{confirmed['id']}]":
            raise TransactionError(
                "identity-invalid",
                f"step {index} created issue {confirmed['id']} but its document "
                f"token is {confirmed['document_token']!r}; the entry must name "
                "the artifact that was actually created",
            )
    elif kind == "label-create":
        if not isinstance(confirmed["metadata"], dict) or not confirmed["metadata"]:
            raise TransactionError(
                "identity-invalid",
                f"step {index} created a label, whose identity is its name and the "
                "metadata it was created with",
            )
    elif kind == "issue-comment":
        if not confirmed["url"]:
            raise TransactionError(
                "identity-invalid",
                f"step {index} posted a comment, so it records that comment's id "
                "and url",
            )
    elif not confirmed["fingerprint"]:
        raise TransactionError(
            "identity-invalid",
            f"step {index} edited an existing artifact, so it records that "
            "artifact's identity and the verified post-edit fingerprint",
        )
    if kind not in ISSUE_IDENTITY_KINDS and confirmed["document_token"]:
        raise TransactionError(
            "identity-invalid",
            f"step {index} is a {kind}, which never appears in the document; only "
            "a created issue or epic contributes a token the entry must carry",
        )
    if step.get("provides_marker") and kind not in ISSUE_IDENTITY_KINDS:
        raise TransactionError(
            "identity-invalid",
            f"step {index} claims to provide the document marker, but a {kind} "
            "produces no marker the entry can carry",
        )
    return confirmed


def require_step(record: dict, index: int, expected: str) -> dict:
    steps = record["steps"]
    if index < 0 or index >= len(steps):
        raise TransactionError(
            "step-out-of-range",
            f"this transaction plans {len(steps)} step(s); {index} is not one",
        )
    step = steps[index]
    if step["state"] == STEP_CONFIRMED and expected != STEP_CONFIRMED:
        raise TransactionError(
            "step-already-confirmed",
            f"step {index} is already confirmed as {step['identity']}; a confirmed "
            "mutation is never repeated",
        )
    if step["state"] != expected:
        raise TransactionError(
            f"step-not-{expected}",
            f"step {index} is {step['state']}, not {expected}",
        )
    return step


def action_acquire(root, ref, repository, document, plan, publication_tip) -> dict:
    record = validate_plan(plan, repository, document, publication_tip)
    commit = write_record(root, ref, record, "")
    return {"status": "acquired"} | transaction_report(record, ref, commit)


def action_begin(root, ref, record, observed, index) -> dict:
    """A step enters `intent` before its external mutation begins, and only
    behind the same explicit approval every tracker mutation needs.

    Ordering is enforced rather than assumed: a later step cannot begin while an
    earlier one is unconfirmed, so the ordered plan a resumption follows is the
    order the mutations actually happened in. And no second step may begin while
    one is already ambiguous — that would make two mutations unaccounted for at
    once, with no way to tell which of them landed.
    """
    require_step(record, index, STEP_PLANNED)
    outstanding = ambiguous_index(record)
    if outstanding is not None:
        raise TransactionError(
            "step-ambiguous",
            f"step {outstanding} began and was never confirmed; reconcile it "
            "before beginning another",
            **transaction_report(record, ref, observed),
        )
    earlier = [
        position
        for position in range(index)
        if record["steps"][position]["state"] != STEP_CONFIRMED
    ]
    if earlier:
        raise TransactionError(
            "steps-out-of-order",
            f"step(s) {earlier} are not confirmed, so step {index} may not begin; "
            "the recorded order is the order the mutations happen in",
        )
    token = secrets.token_hex(16)
    record["steps"][index]["state"] = STEP_INTENT
    # Only the digest is durable. The token itself is returned once, to this
    # caller, and exists nowhere else — which is what makes holding it evidence
    # of having run the mutation rather than of having read the record.
    record["steps"][index]["begin_token_digest"] = _digest(token)
    record["state"] = derived_state(record)
    commit = write_record(root, ref, record, observed)
    return {
        "status": "step-begun", "step": index, "begin_token": token,
    } | transaction_report(record, ref, commit)


def action_confirm(root, ref, record, observed, index, identity, begin_token) -> dict:
    """Confirm a step, but only from the run that began it.

    Begin and confirm are separate invocations by design — the mutation happens
    between them — so process identity cannot tell the run that just created an
    issue from a fresh session looking at an interrupted one. What can: the
    token minted by `--begin-step` and returned only to that caller. A resuming
    session has no conversation history and therefore does not have it, so the
    ordinary confirmation stays one flag wide while adoption of an ambiguous
    step is pushed onto `--reconcile-step`, where an exact artifact must be
    approved and matched. Losing the token costs a reconciliation, which is the
    safe direction to fail.
    """
    step = require_step(record, index, STEP_INTENT)
    expected = step.get("begin_token_digest")
    if not expected or not begin_token or not secrets.compare_digest(
        _digest(begin_token), expected
    ):
        raise TransactionError(
            "begin-token-mismatch",
            f"step {index} was begun by another run, so this one cannot confirm "
            "what that mutation returned. It is ambiguous: verify read-only "
            "whether its exact postcondition holds, then reconcile it against one "
            "approved artifact or authorize a retry once it is proven absent",
            **transaction_report(record, ref, observed),
        )
    step["identity"] = validate_identity(identity, step, index)
    step["state"] = STEP_CONFIRMED
    step.pop("begin_token_digest", None)
    record["state"] = derived_state(record)
    commit = write_record(root, ref, record, observed)
    return {"status": "step-confirmed", "step": index} | transaction_report(
        record, ref, commit
    )


def action_reconcile(root, ref, record, observed, index, identity, candidates) -> dict:
    """Bind an ambiguous step to one exact artifact, on explicit approval.

    Requirement 10's whole point is what this refuses: more than one plausible
    candidate, a payload that does not match what was approved, or a target that
    is not the recorded one. A similarly titled artifact is never evidence, so
    the approval has to name the recorded target and the recorded payload
    fingerprint back — anything else leaves the record unresolved and stops.
    """
    step = require_step(record, index, STEP_INTENT)
    if candidates != 1:
        raise TransactionError(
            "candidates-not-unique",
            f"{candidates} candidate artifact(s) were reported for step {index}; "
            "only one exact match may be bound, and a similarly titled artifact "
            "is never sufficient evidence",
            **transaction_report(record, ref, observed),
        )
    if not isinstance(identity, dict):
        raise TransactionError(
            "identity-invalid", f"the identity for step {index} is not a JSON object"
        )
    matched_target = _text(identity.get("matched_target"))
    matched_payload = _text(identity.get("matched_payload_fingerprint"))
    if matched_target != step["target"]:
        raise TransactionError(
            "identity-mismatch",
            f"the approved artifact names target {matched_target!r}, but step "
            f"{index} recorded {step['target']!r}",
            **transaction_report(record, ref, observed),
        )
    if matched_payload != step["payload_fingerprint"]:
        raise TransactionError(
            "identity-mismatch",
            f"the approved artifact's payload fingerprint {matched_payload!r} is "
            f"not step {index}'s recorded {step['payload_fingerprint']!r}",
            **transaction_report(record, ref, observed),
        )
    step["identity"] = validate_identity(identity, step, index)
    step["state"] = STEP_CONFIRMED
    step.pop("begin_token_digest", None)
    record["state"] = derived_state(record)
    commit = write_record(root, ref, record, observed)
    return {"status": "step-reconciled", "step": index} | transaction_report(
        record, ref, commit
    )


def action_authorize_retry(root, ref, record, observed, index) -> dict:
    """Return an ambiguous step to `planned`, on explicit approval and only
    against read-only evidence that its exact postcondition is absent. This is
    the only path back: without proof that nothing landed, retrying is how one
    approved mutation becomes two."""
    require_step(record, index, STEP_INTENT)
    record["steps"][index]["state"] = STEP_PLANNED
    # The retried attempt mints its own token; the abandoned one must not stay
    # presentable by whatever still holds it.
    record["steps"][index].pop("begin_token_digest", None)
    record["state"] = derived_state(record)
    commit = write_record(root, ref, record, observed)
    return {"status": "retry-authorized", "step": index} | transaction_report(
        record, ref, commit
    )


def action_publication_pending(root, ref, record, observed) -> dict:
    state = derived_state(record)
    if state != STATE_MUTATION_CONFIRMED:
        raise TransactionError(
            "state-invalid",
            f"publication may be handed over only from {STATE_MUTATION_CONFIRMED}; "
            f"this transaction is {state}",
            **transaction_report(record, ref, observed),
        )
    record["state"] = STATE_PUBLICATION_PENDING
    commit = write_record(root, ref, record, observed)
    return {"status": "publication-pending"} | transaction_report(record, ref, commit)


def published_document(root: Path, record: dict, source: str, branch: str) -> str:
    """The bytes resolution is verified against.

    `branch` is the ordinary case: the published document as the remote
    publication branch itself carries it. `local` is the `not-published`
    outcome, where the helper declined publication for a `pr-atomic`,
    unmatched, or not-yet-tracked document and applied the approved content to
    the working tree instead — a legitimate terminal state for such a document,
    and the only evidence there is.
    """
    document = record["document"]
    if source == "local":
        target = root / document
        if not target.is_file():
            raise TransactionError(
                "document-unreadable",
                f"{document} does not exist under {root}, so the applied "
                "disposition cannot be verified",
            )
        return target.read_text(encoding="utf-8", errors="replace")
    git(["fetch", "origin", branch], cwd=root)
    proc = git(
        ["show", f"origin/{branch}:{document}"], cwd=root, check=False
    )
    if proc.returncode != 0:
        raise TransactionError(
            "document-unreadable",
            f"origin/{branch} carries no {document}, so the published disposition "
            "cannot be verified",
        )
    return proc.stdout.decode(errors="replace")


def resolution_fault(record: dict, text: str) -> tuple[str | None, list[str]]:
    """Why the published document does not yet carry this disposition, and the
    entry lines that were considered.

    Derived from §4's vocabulary rather than from "some line mentions both
    things". The at-a-glance index is a task list with one line per entry, and
    exactly `- [x]` marks a terminal disposition — so the entry this
    transaction resolves against is a *terminal checklist line* naming the key.
    Requiring that is what distinguishes the three cases a substring search
    cannot tell apart:

    - the entry is still `- [ ]`, so the run that was interrupted never marked
      it and the disposition has not been applied;
    - the mention is incidental prose, a `Related` pointer or a code fence that
      happens to name the key and the number; and
    - the entry is terminal but carries `[no-issue]` or `[deferred]`, which is
      a different disposition from the one this transaction recorded.

    Every tracker transaction's disposition is a linked one — `[no-issue]` and
    `[deferred]` mutate nothing and acquire no transaction — so a terminal entry
    carrying either of those markers contradicts the record rather than
    completing it.
    """
    entry_key = record["entry_key"]
    tokens = required_document_tokens(record)
    naming = [line for line in text.splitlines() if entry_key in line]
    if not naming:
        return f"no line in the document names {entry_key!r}", naming
    terminal = [line for line in naming if TERMINAL_ENTRY_RE.match(line)]
    if not terminal:
        return (
            f"no terminal '- [x]' entry names {entry_key!r}; the disposition was "
            "not applied to the document's index",
            naming,
        )
    carrying = [
        line for line in terminal if all(token in line for token in tokens)
    ]
    if not carrying:
        return (
            f"the terminal entry for {entry_key!r} does not carry every required "
            f"identity {tokens}",
            terminal,
        )
    uncontradicted = [
        line
        for line in carrying
        if not any(marker in line for marker in CONTRADICTORY_MARKERS)
    ]
    if not uncontradicted:
        return (
            f"the terminal entry for {entry_key!r} carries {list(CONTRADICTORY_MARKERS)} "
            "beside the tracker link, which is a different disposition from the "
            "one this transaction recorded",
            carrying,
        )
    return None, uncontradicted


def action_resolve(root, ref, record, observed, source, branch) -> dict:
    """Clear the record, but only against the published entry itself.

    Reachability of a commit says a commit landed, not that it carried this
    disposition. So what is checked is the recorded entry key's own terminal
    entry: it must be marked terminal, carry the disposition's marker and every
    tracker identity this disposition requires the document to name, and carry
    no marker contradicting it. Anything less leaves the record outstanding,
    which is what stops the next run.
    """
    state = derived_state(record)
    if state not in (STATE_MUTATION_CONFIRMED, STATE_PUBLICATION_PENDING):
        raise TransactionError(
            "state-invalid",
            f"a {state} transaction has unconfirmed tracker steps and cannot be "
            "resolved; resume them or abandon the transaction deliberately",
            **transaction_report(record, ref, observed),
        )
    text = published_document(root, record, source, branch)
    tokens = required_document_tokens(record)
    entry_key = record["entry_key"]
    fault, lines = resolution_fault(record, text)
    if fault is not None:
        raise TransactionError(
            "resolution-unverified",
            f"{fault}; commit reachability alone does not resolve a tracker "
            "transaction, so the record is kept",
            source=source,
            required_tokens=tokens,
            entry_lines=lines,
            **transaction_report(record, ref, observed),
        )
    clear_record(root, ref, observed, _binding(record))
    return {
        "status": STATE_RESOLVED,
        "source": source,
        "required_tokens": tokens,
        "repository": record["repository"],
        "document": record["document"],
        "entry_key": entry_key,
        "transaction_ref": ref,
        "transaction_state": STATE_RESOLVED,
        "confirmed_identities": [
            step["identity"] for step in record["steps"]
        ],
    }


def action_abandon(root, ref, record, observed) -> dict:
    """Clear an unfinished transaction without publication, on explicit
    approval and against evidence that none of its unconfirmed mutations
    landed. Whatever it *did* confirm is reported rather than discarded
    silently: those mutations are real, and the document never received them."""
    state = derived_state(record)
    if state not in (STATE_INTENT_ONLY, STATE_TRACKER_PENDING):
        raise TransactionError(
            "state-invalid",
            f"a {state} transaction has every approved mutation confirmed; "
            "reconcile the document and publish it rather than abandoning it",
            **transaction_report(record, ref, observed),
        )
    confirmed = [
        step["identity"] for step in record["steps"] if step["state"] == STEP_CONFIRMED
    ]
    clear_record(root, ref, observed, _binding(record))
    return {
        "status": "abandoned",
        "repository": record["repository"],
        "document": record["document"],
        "entry_key": record["entry_key"],
        "transaction_ref": ref,
        "transaction_state": None,
        "confirmed_identities": confirmed,
        "next_action": (
            "no tracker transaction is outstanding. The confirmed mutations above "
            "already exist and the document never recorded them; reconcile them by "
            "hand"
            if confirmed
            else "no tracker transaction is outstanding"
        ),
    }


def check(root: Path, repository: str, document: str) -> dict:
    """Whether a tracker transaction for this document is outstanding.

    Read-only, takes no lock, and mutates nothing: this is asked during the
    pre-mutation preflight, before the first irreversible step of a run, which
    is the only moment at which learning the answer is still useful.

    A record it cannot interpret is an answer rather than an exception. This is
    the one question whose result a caller acts on by deciding whether it may
    mutate GitHub, so an unreadable record is reported as outstanding and
    unreadable — with the reference and the permitted next action — rather than
    raised past the report and collapsed into a generic failure somewhere up the
    stack. Only an unusable write root or a repository that is not the declared
    one still raises: those are wrong inputs, not record states.
    """
    resolved = resolve_write_root(root)
    owner = verify_owner(resolved, repository)
    ref = transaction_ref(owner, document)
    report = observed_report(resolved, ref, repository=owner, document=document)
    # `acquired` is False only for a record that is genuinely absent and
    # readable. An unreadable one reports None, and reading that as clear is the
    # single conclusion this check must never license.
    return {"status": "clear" if report["acquired"] is False else "outstanding"} | report


def load_json(source: str):
    try:
        text = sys.stdin.read() if source == "-" else Path(source).read_text(
            encoding="utf-8"
        )
    except OSError as error:
        raise TransactionError(
            "payload-unreadable", f"{source} could not be read: {error}"
        ) from error
    try:
        return json.loads(text)
    except json.JSONDecodeError as error:
        raise TransactionError(
            "payload-unreadable", f"{source} is not valid JSON: {error}"
        ) from error


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Checkpoint one approved disposition's tracker mutations."
    )
    parser.add_argument("--repo", required=True, help="the owning owner/name")
    parser.add_argument("--root", required=True, type=Path, help="the local write root")
    parser.add_argument("--path", required=True, help="repository-relative document")
    parser.add_argument("--branch", help="the publication branch, for --resolve")

    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--check", action="store_true")
    action.add_argument("--acquire", action="store_true")
    action.add_argument("--begin-step", type=int, metavar="N")
    action.add_argument("--confirm-step", type=int, metavar="N")
    action.add_argument("--reconcile-step", type=int, metavar="N")
    action.add_argument("--authorize-retry", type=int, metavar="N")
    action.add_argument("--publication-pending", action="store_true")
    action.add_argument("--resolve", action="store_true")
    action.add_argument("--abandon", action="store_true")

    parser.add_argument("--plan", help="file holding the approved plan, or - for stdin")
    parser.add_argument(
        "--publication-tip",
        help="the publication tip this disposition was prepared against",
    )
    parser.add_argument(
        "--identity", help="file holding the confirmed identity, or - for stdin"
    )
    parser.add_argument(
        "--begin-token",
        help="the token --begin-step returned to the run that began this step",
    )
    parser.add_argument(
        "--candidates",
        type=int,
        help="how many candidate artifacts the read-only verification found",
    )
    parser.add_argument(
        "--approved",
        action="store_true",
        help="the user explicitly approved this exact step, artifact, or clearing",
    )
    parser.add_argument(
        "--evidence",
        choices=("absent", "none-landed"),
        help="what authoritative read-only verification established",
    )
    parser.add_argument(
        "--source",
        choices=("branch", "local"),
        default="branch",
        help="verify resolution against the publication branch, or against the "
        "locally applied document when the helper reported not-published with "
        "document_written true",
    )
    args = parser.parse_args(argv)

    try:
        root = resolve_write_root(args.root)
        owner = verify_owner(root, args.repo)
        ref = transaction_ref(owner, args.path)

        if args.check:
            outcome = check(args.root, args.repo, args.path)
            print(json.dumps(outcome, indent=2, sort_keys=True, default=str))
            return 0 if outcome["status"] == "clear" else 1

        if args.acquire:
            if not args.plan:
                parser.error("--acquire requires --plan")
            if not args.publication_tip:
                parser.error("--acquire requires --publication-tip")
            if not args.approved:
                raise TransactionError(
                    "approval-required",
                    "--approved is required: no tracker transaction is acquired "
                    "before the user approves that exact disposition and plan",
                )
            outcome = action_acquire(
                root, ref, owner, args.path, load_json(args.plan),
                args.publication_tip,
            )
            print(json.dumps(outcome, indent=2, sort_keys=True, default=str))
            return 0

        record, observed = read_record(
            root, ref, repository=owner, document=args.path
        )
        if record is None:
            raise TransactionError(
                "no-transaction",
                "no tracker transaction is recorded for this document; acquire "
                "one before the first tracker mutation of an approved disposition",
                transaction_ref=ref,
            )
        original = json.loads(json.dumps(record))

        if args.begin_step is not None:
            if not args.approved:
                raise TransactionError(
                    "approval-required",
                    "--approved is required: a step's exact target and payload are "
                    "re-presented and approved before its mutation begins, in a "
                    "resuming invocation exactly as in the one that acquired it",
                    **transaction_report(record, ref, observed),
                )
            outcome = action_begin(root, ref, record, observed, args.begin_step)
        elif args.confirm_step is not None:
            if not args.identity:
                parser.error("--confirm-step requires --identity")
            outcome = action_confirm(
                root, ref, record, observed, args.confirm_step,
                load_json(args.identity), args.begin_token,
            )
        elif args.reconcile_step is not None:
            if not args.identity:
                parser.error("--reconcile-step requires --identity")
            if not args.approved:
                raise TransactionError(
                    "approval-required",
                    "--approved is required: an ambiguous step is bound to an "
                    "artifact only by explicit user approval of that exact one",
                    **transaction_report(record, ref, observed),
                )
            if args.candidates is None:
                raise TransactionError(
                    "evidence-required",
                    "--candidates is required: how many artifacts the read-only "
                    "verification matched decides whether any binding is permitted",
                    **transaction_report(record, ref, observed),
                )
            outcome = action_reconcile(
                root, ref, record, observed, args.reconcile_step,
                load_json(args.identity), args.candidates,
            )
        elif args.authorize_retry is not None:
            if not args.approved:
                raise TransactionError(
                    "approval-required",
                    "--approved is required: a retry is authorized only by explicit "
                    "user approval",
                    **transaction_report(record, ref, observed),
                )
            if args.evidence != "absent":
                raise TransactionError(
                    "evidence-required",
                    "--evidence absent is required: a retry is authorized only when "
                    "authoritative read-only evidence shows the exact intended "
                    "postcondition does not hold",
                    **transaction_report(record, ref, observed),
                )
            outcome = action_authorize_retry(
                root, ref, record, observed, args.authorize_retry
            )
        elif args.publication_pending:
            outcome = action_publication_pending(root, ref, record, observed)
        elif args.resolve:
            if args.source == "branch" and not args.branch:
                parser.error("--resolve --source branch requires --branch")
            outcome = action_resolve(
                root, ref, record, observed, args.source, args.branch
            )
        else:
            if not args.approved:
                raise TransactionError(
                    "approval-required",
                    "--approved is required: an unfinished transaction is cleared "
                    "without publication only by explicit user approval",
                    **transaction_report(record, ref, observed),
                )
            if args.evidence != "none-landed":
                raise TransactionError(
                    "evidence-required",
                    "--evidence none-landed is required: abandonment needs "
                    "authoritative read-only evidence that no unconfirmed mutation "
                    "landed",
                    **transaction_report(record, ref, observed),
                )
            outcome = action_abandon(root, ref, record, observed)

        # The last line of defence for requirement 7, checked after the
        # transition rather than inside each action: every path above rebuilds
        # the record it read, and a future one that dropped a confirmed identity
        # would otherwise publish a record authorizing that mutation again.
        require_preserved_confirmations(original, record)
        print(json.dumps(outcome, indent=2, sort_keys=True, default=str))
        return 0
    except Exception as error:  # noqa: BLE001 - the boundary is the point
        # An unmodelled failure is still a fail-closed outcome the caller has to
        # report tracker state for. A traceback where a result belongs leaves it
        # with nothing to report and no way to tell what became of the record.
        if not isinstance(error, TransactionError):
            error = TransactionError(
                "internal-error", f"{type(error).__name__}: {error}"
            )
        payload = {
            "acquired": None,
            "transaction_state": None,
            "steps": [],
            "completed_steps": [],
            "confirmed_identities": [],
            "ambiguous_step": None,
            "remaining_steps": [],
            "next_action": (
                "this transaction could not be read or updated. Stop: no tracker "
                "mutation, publication, or clearing is permitted until it is "
                "resolved by hand"
            ),
        }
        payload.update(error.detail)
        payload.update({"status": error.status, "message": error.message})
        print(json.dumps(payload, indent=2, sort_keys=True, default=str))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
