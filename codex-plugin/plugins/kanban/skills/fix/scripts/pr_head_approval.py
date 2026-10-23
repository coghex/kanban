#!/usr/bin/env python3
"""Head-bound approval of one pull request, evaluated for one caller policy.

`fix` and `finalize` both refuse to act on an approval that cannot be bound to
the pull request's CURRENT head, and both must read fresh authority again
immediately before they mutate. This module owns that evaluation so the two
workflows stop maintaining it separately. It is read-only: it reads the pull
request, the authenticated login, and the evidence feeds through `gh`, decides,
and prints one JSON object. It never merges, pushes, labels, comments or
reviews, and it never publishes anything.

`tools/pr_head_approval.py` is the owning source. Byte-identical copies ship in
the Claude bundle (`scripts/`) and in the Codex bundle beside each caller
(`skills/fix/scripts/`, `skills/finalize/scripts/`), because the Codex bundle
has no shared scripts root. The workflows resolve their own bundle's copy.

Invocation
==========

    pr_head_approval.py --policy {fix,finalize} --repo OWNER/NAME --pr N
                        [--brand {claude,codex}] [--config PATH]

* `--policy` names the caller. The two callers keep DIFFERENT approval rules
  and this module does not unify them; see "Policies".
* `--repo` is the resolved repository the pull request lives in. Every `gh`
  read is scoped to it with `-R`, so a fork checkout never redirects a read to
  a same-numbered pull request elsewhere.
* `--pr` is exactly one positive pull request number. A branch name, a URL, an
  empty value, or a second token is a usage error: `gh` accepts those wherever
  a number goes.
* `--brand` is the active bundle's brand, and is REQUIRED for `fix` and
  refused for `finalize`.
* `--config` is the caller's explicit Kanban configuration file; an empty value
  means none was supplied. Without one the configuration is read from
  `$XDG_CONFIG_HOME/kanban/config.toml` (default `~/.config/kanban/config.toml`).
  The global `[workflow]` table is overridden per repository by
  `[repositories."owner/name".workflow]` (the key is the ASCII-lowercased
  repository). An absent or unreadable file keeps the documented defaults, and
  the result reports which of those happened.

Result
======

stdout is exactly one JSON object, on approval AND on every refusal:

    approved        true only when the policy approves; otherwise false
    policy          "fix" | "finalize"
    mode            the effective approval mode: "label" | "review" | "either"
    head            the pull request's current head this run evaluated, or null
                    when it could not be read
    approval_head   the head the decisive evidence names, or null when the
                    evidence names none (missing, unreadable, or unattributed)
    origin          the pr-origin marker's brand, or null when the body has none
    publisher       the authenticated login that owns canonical markers, or null
    reason          why the policy refused, or null on approval
    marker_history  true when the publisher has ever published a pr-review
                    marker on this pull request, false when it has not, and null
                    when the feed was not read or could not be read
    config          {"path": ..., "status": "read" | "absent" | "unreadable"}
    paths           the evidence path outcomes that explain the decision; each
                    is {"met": bool, "evidence": ..., "head": ..., "detail": ...}
                    fix:      "label" and "review"
                    finalize: "signal" and "canonical"

A usage error is reported the same way, with `policy` null when it could not be
read and an added `"usage": true`.

Exit status reports the policy's FINAL decision: 0 only when `approved` is true,
1 for any refusal, 2 for a usage error. A callers' success test is BOTH exit 0
AND `approved` exactly true; nonempty JSON, missing or malformed output, and a
nonzero status never count as success, and the `head` and `approval_head` of a
refusal are diagnostics, never authority. Under fix's `either` mode a read or
parse failure confined to ONE evidence path is that path's unmet outcome and the
helper still exits 0 when the other path approves independently; a failure of an
input every path needs (the authenticated publisher, the pull request metadata,
a readable current head, the origin check) always refuses. The result carries no
workflow command name and no brand-specific remedy wording: the workflows render
those, choosing from `marker_history` and the path outcomes.

Policies
========

`fix` (pushes a commit onto a head it did not review):

* The body must carry exactly ONE pr-origin marker, of exactly one kind, as its
  final non-whitespace content, and it must name `--brand`. Missing, mixed,
  duplicate, trailing-text, other-brand and external-origin markers refuse.
* The configured changes-requested and blocking labels refuse under every mode.
* `label`: the configured approval label AND a valid current-head canonical
  marker. `review`: `reviewDecision == APPROVED` AND a valid current-head native
  review. `either`: the two paths are evaluated independently and either one
  suffices; one failing never vetoes the other.
* The canonical marker must read `verdict=APPROVE` at the current head and its
  `reviewers=` must not name the validated origin brand (a self-review).
* The native evidence keeps only the opinionated reviews (`APPROVED`,
  `CHANGES_REQUESTED`), the newest per author by `submitted_at` with the review
  id breaking ties, and requires a surviving `APPROVED` whose `commit_id` is the
  current head. Dismissed, superseded, stale and unattributed approvals do not.

`finalize` (merges, so it is stricter about whose approval it trusts):

* The configured mode's label / `reviewDecision` signal AND a valid current-head
  canonical marker are BOTH required under EVERY mode. Native reviews are never
  fetched and never substitute for the marker.
* The changes-requested and blocking labels refuse.
* One valid final Claude/Codex origin requires a `reviewers=` set that excludes
  that brand; an absent origin requires exactly Claude and Codex; a grok, kimi
  or google origin requires exactly Codex. Mixed, duplicate and non-final origin
  markers refuse.
* Mergeability, merge state, checks, default branch and base are NOT evaluated
  here; they stay in the finalize workflow, which must also require the head it
  reads to equal this module's approved `head`.

Canonical evidence, for both callers
====================================

The marker is the one the bundled coordinator publishes today,
`<!-- pr-review:v2 reviewers=... models=... head=... verdict=... -->`, with
comma-joined `reviewers=`; the legacy `<!-- pr-review:v1 reviewer=... -->` shape
is honoured too. Only a comment the AUTHENTICATED login wrote counts, so an
unresolved login refuses before any evidence is read. The COMPLETE paginated
feed is read and flattened before it is ordered, and the newest marker-bearing
comment is selected by creation time with the comment id breaking ties BEFORE it
is validated: every marker opening in it must parse and exactly one must exist,
and a malformed or multiply-marked newest comment never falls back to an older
approval. A newer non-approval standing over an older approval refuses.
`marker_history` is about that same selection: any such owned opening, whatever
head it named, whether a later one superseded it, or whether the approval label
is currently attached.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path

POLICIES = ("fix", "finalize")
BRANDS = ("claude", "codex")
MODES = ("label", "review", "either")

# Bounds one `gh` read. The paginated feeds are the slow ones, and a read that
# never returns must refuse rather than hold a merge or a push open.
GH_TIMEOUT_SECONDS = 180

PR_FIELDS = "number,body,headRefOid,labels,reviewDecision"

V1_RE = re.compile(
    r"<!--\s*pr-review:v1\s+reviewer=(?P<reviewers>claude|codex)\s+"
    r"head=(?P<head>[0-9a-f]{40})\s+"
    r"verdict=(?P<verdict>APPROVE|CHANGES_REQUESTED)\s*-->",
    re.IGNORECASE,
)
# The coordinator joins both lists with commas, so a dual-reviewer marker is
# the ordinary shape rather than an exception, and `models=` is one token.
V2_RE = re.compile(
    r"<!--\s*pr-review:v2\s+"
    r"reviewers=(?P<reviewers>(?:claude|codex)(?:,(?:claude|codex))*)\s+"
    r"models=\S+\s+"
    r"head=(?P<head>[0-9a-f]{40})\s+"
    r"verdict=(?P<verdict>APPROVE|CHANGES_REQUESTED)\s*-->",
    re.IGNORECASE,
)
# Case-insensitive like the two parsers above, and for the same reason they
# are: a marker this gate cannot parse must be detected in every spelling it
# could be written in. A case-sensitive opening test would skip a malformed
# `PR-REVIEW:V2` marker and let an older APPROVE win, which is the fail-open
# the malformed-marker rule exists to close.
MARKER_OPENING_RE = re.compile(r"<!--\s*pr-review:v", re.IGNORECASE)
HEAD_RE = re.compile(r"\A[0-9a-f]{40}\Z")
REPO_RE = re.compile(r"\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")

# The origin markers, character for character as `origin_from_body` in the
# bundled coordinator spells them. A different spacing is not one of these
# markers there and is not one here. Grok, Kimi, and Google are known origins
# Codex reviews; none is a spawned provider and none ever appears in
# `reviewers=`.
ORIGIN_MARKERS = {
    "claude": "<!-- pr-origin:claude -->",
    "codex": "<!-- pr-origin:codex -->",
    "grok": "<!-- pr-origin:grok -->",
    "kimi": "<!-- pr-origin:kimi -->",
    "google": "<!-- pr-origin:google -->",
}
UNKNOWN_ORIGIN_REVIEWERS = {"claude", "codex"}
EXTERNAL_ORIGIN_REVIEWERS = {
    "grok": {"codex"},
    "kimi": {"codex"},
    "google": {"codex"},
}


class EvidenceError(Exception):
    """One evidence record cannot be read, so the path that needs it is unmet.

    Never a veto of the other path: the caller catches it at the boundary of the
    path that raised it and reports that path unmet.
    """


class Refusal(Exception):
    """The policy refuses. Carries the concrete reason the caller reports."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def new_result(policy: str | None) -> dict:
    return {
        "approved": False,
        "policy": policy,
        "mode": None,
        "head": None,
        "approval_head": None,
        "origin": None,
        "publisher": None,
        "reason": None,
        "marker_history": None,
        "config": {"path": None, "status": None},
        "paths": {},
    }


def record_id(item: dict) -> int:
    """A feed record's numeric id, the tie-break between equal timestamps.

    A record whose id is not a number cannot be ordered, and guessing an order
    could let the wrong marker or review speak, so it is an evidence failure of
    the path reading the feed rather than a value to default.
    """
    value = item.get("id") or 0
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise EvidenceError("a record id is not a number")
    try:
        return int(value)
    except ValueError:
        raise EvidenceError("a record id is not a number") from None


def path_outcome(met: bool, evidence: str, head: str | None, detail: str | None) -> dict:
    return {"met": met, "evidence": evidence, "head": head, "detail": detail}


# --------------------------------------------------------------------------
# Reading GitHub. Every read is `gh`, scoped to the resolved repository, and
# read-only. A failed or unparsable read is None, never a guess.
# --------------------------------------------------------------------------


def gh_output(arguments: list[str]) -> str | None:
    try:
        completed = subprocess.run(
            ["gh", *arguments],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=GH_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0:
        return None
    return completed.stdout


def read_json(arguments: list[str]):
    text = gh_output(arguments)
    if text is None:
        return None
    try:
        return json.loads(text)
    except ValueError:
        return None


def read_pages(arguments: list[str]) -> list[dict] | None:
    """A paginated feed flattened to its items, oldest page first, or None.

    `--slurp` wraps the pages in one array. The whole feed is read: a bounded
    view can leave the newest item outside it, and an older one would then
    speak for a head nobody reviewed.
    """
    pages = read_json(arguments)
    if not isinstance(pages, list):
        return None
    items: list[dict] = []
    for page in pages:
        if not isinstance(page, list):
            return None
        items.extend(item for item in page if isinstance(item, dict))
    return items


# --------------------------------------------------------------------------
# Configuration: the global [workflow] table, overridden per repository.
# --------------------------------------------------------------------------


def load_workflow(repo: str, explicit: str) -> dict:
    """The verdict labels and approval mode this repository is configured with.

    Exactly the resolution the bundled coordinator, the drainer and the board
    make, so a repository that renamed its verdict labels is read the same way
    here as everywhere else. An unreadable or absent file keeps the documented
    defaults.
    """
    settings = {
        "approval_label": "reviewed:approve",
        "changes_label": "reviewed:changes",
        "blocked_labels": {"blocked"},
        "approval_mode": "label",
    }
    if explicit.strip():
        path = Path(explicit).expanduser()
    else:
        xdg = os.environ.get("XDG_CONFIG_HOME")
        path = (Path(xdg) if xdg else Path.home() / ".config") / "kanban" / "config.toml"
    document: dict = {}
    status = "absent"
    if path.is_file():
        try:
            with path.open("rb") as handle:
                document = tomllib.load(handle)
            status = "read"
        except (tomllib.TOMLDecodeError, OSError):
            document = {}
            status = "unreadable"

    def apply(table) -> None:
        if not isinstance(table, dict):
            return
        workflow = table.get("workflow")
        if not isinstance(workflow, dict):
            return
        if isinstance(workflow.get("approval_label"), str) and workflow["approval_label"]:
            settings["approval_label"] = workflow["approval_label"]
        named = workflow.get("changes_requested_label")
        if isinstance(named, str) and named:
            settings["changes_label"] = named
        blocking = workflow.get("blocked_labels")
        if isinstance(blocking, list) and all(isinstance(one, str) for one in blocking):
            settings["blocked_labels"] = set(blocking)
        mode = workflow.get("approval_mode")
        if mode in MODES:
            settings["approval_mode"] = mode

    apply(document)
    repositories = document.get("repositories")
    if isinstance(repositories, dict):
        # The override key is the canonical ASCII-lowercased owner/name, folded
        # the one way Kanban.Config folds it rather than with Unicode lowering.
        ascii_lower = str.maketrans(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz"
        )
        apply(repositories.get(repo.translate(ascii_lower)))
    settings["config"] = {"path": str(path), "status": status}
    return settings


# --------------------------------------------------------------------------
# Evidence shared by both policies.
# --------------------------------------------------------------------------


def label_names(state: dict) -> set[str]:
    # hasLabel folds case on both sides, so the comparison here does too.
    return {
        str(item.get("name") or "").casefold()
        for item in state.get("labels") or []
        if isinstance(item, dict)
    }


def problem_label_reason(settings: dict, labels: set[str]) -> str | None:
    """The unconditional refusal a changes-requested or blocking label is."""
    if settings["changes_label"].casefold() in labels:
        return settings["changes_label"] + " is attached"
    # hasProblemLabel treats a blocking label exactly as it treats the
    # changes-requested one, and a blocking label is a decision a human made.
    blocking = sorted(
        one for one in settings["blocked_labels"] if one.casefold() in labels
    )
    if blocking:
        return "a blocking label is attached: " + ", ".join(blocking)
    return None


def parse_origin(body: str) -> tuple[str | None, str | None]:
    """(origin, refusal detail), by exactly the rules `origin_from_body`
    applies in the bundled coordinator: one marker, of one kind, as the final
    non-whitespace content of the body."""
    stripped = body.rstrip()
    counts = {brand: body.count(marker) for brand, marker in ORIGIN_MARKERS.items()}
    present = [brand for brand, count in counts.items() if count]
    # Mixed kinds, however many, are "both" in the existing refusal text; "more
    # than once" of one kind is "not zero or one".
    if len(present) not in (0, 1):
        return None, "the pull request body carries both pr-origin markers"
    if any(count not in (0, 1) for count in counts.values()):
        return None, "the pull request body carries a duplicate pr-origin marker"
    origin = present[0] if present else None
    if origin is not None and not stripped.endswith(ORIGIN_MARKERS[origin]):
        return None, "the pr-origin marker is not the body's final content"
    return origin, None


class Selection:
    """The outcome of choosing the one marker that speaks for a pull request."""

    def __init__(self, kind: str, detail: str | None = None, match=None):
        self.kind = kind
        self.detail = detail
        self.match = match

    @property
    def ok(self) -> bool:
        return self.kind == "ok"

    @property
    def head(self) -> str | None:
        return self.match.group("head").lower() if self.match else None

    @property
    def verdict(self) -> str | None:
        return self.match.group("verdict").upper() if self.match else None

    @property
    def reviewers(self) -> set[str]:
        if not self.match:
            return set()
        return {
            part.strip().lower()
            for part in self.match.group("reviewers").split(",")
            if part.strip()
        }


def owned_login(comment: dict) -> str:
    author = comment.get("user") or {}
    return str(author.get("login") or "") if isinstance(author, dict) else ""


def select_marker(comments: list[dict], publisher: str) -> tuple[Selection, bool]:
    """(the selection, whether the publisher ever published a marker opening).

    Among the comments the authenticated publisher wrote, the newest
    marker-bearing one is selected by creation time with the comment id
    breaking ties, and only THEN is what it says tested.
    """
    ordered = sorted(
        comments,
        key=lambda item: (str(item.get("created_at") or ""), record_id(item)),
        reverse=True,
    )
    history = False
    chosen: Selection | None = None
    for comment in ordered:
        if owned_login(comment).lower() != publisher.lower():
            continue
        body = str(comment.get("body") or "")
        # Every marker in the comment, not the first one that parses. A comment
        # opening with a current-head APPROVE and going on to a
        # CHANGES_REQUESTED or a malformed one would otherwise be read as the
        # approval alone, and the malformed test would never run because a
        # valid match had been found.
        openings = len(MARKER_OPENING_RE.findall(body))
        if openings == 0:
            continue
        history = True
        if chosen is not None:
            continue
        found = list(V2_RE.finditer(body)) + list(V1_RE.finditer(body))
        if len(found) != openings:
            chosen = Selection("malformed", "a review marker you published is malformed")
        elif len(found) != 1:
            chosen = Selection(
                "multiple",
                "the newest comment you published carries "
                + str(len(found))
                + " review markers, and only one can be the verdict",
            )
        else:
            chosen = Selection("ok", match=found[0])
    if chosen is None:
        chosen = Selection(
            "missing",
            "no review marker published by " + publisher + " is in the feed",
        )
    return chosen, history


def marker_verdict_reason(selection: Selection, head: str) -> str | None:
    """Why a selected, well-formed marker is not an approval of `head`."""
    if selection.verdict != "APPROVE":
        return "the newest marker you published reads verdict=" + str(selection.verdict)
    if selection.head != head:
        return (
            "the newest marker you published names head "
            + str(selection.head)
            + ", not the current head "
            + head
        )
    return None


# --------------------------------------------------------------------------
# Shared preamble: the inputs every path needs.
# --------------------------------------------------------------------------


def read_publisher(result: dict) -> str:
    # Fail closed on the identity: an unresolved login would make every
    # ownership comparison below vacuously true.
    login = gh_output(["api", "user", "--jq", ".login"])
    publisher = (login or "").strip()
    if not publisher:
        raise Refusal("the authenticated GitHub login could not be resolved")
    result["publisher"] = publisher
    return publisher


def read_state(repo: str, pr: str, result: dict) -> dict:
    state = read_json(["pr", "view", pr, "-R", repo, "--json", PR_FIELDS])
    if not isinstance(state, dict):
        raise Refusal("the pull request could not be read")
    return state


def read_head(state: dict, result: dict) -> str:
    head = str(state.get("headRefOid") or "").lower()
    if HEAD_RE.match(head) is None:
        raise Refusal("the pull request's current head could not be read")
    result["head"] = head
    return head


def read_comments(repo: str, pr: str) -> list[dict] | None:
    return read_pages(
        ["api", "--paginate", "--slurp", f"repos/{repo}/issues/{pr}/comments?per_page=100"]
    )


def read_reviews(repo: str, pr: str) -> list[dict] | None:
    return read_pages(
        ["api", "--paginate", "--slurp", f"repos/{repo}/pulls/{pr}/reviews?per_page=100"]
    )


# --------------------------------------------------------------------------
# The fix policy.
# --------------------------------------------------------------------------


def native_path(
    reviews: list[dict] | None, head: str, review_decision: bool
) -> dict:
    """The `review` path: an effective native approval naming the current head.

    Only the opinionated reviews count (`APPROVED`, `CHANGES_REQUESTED`), the
    newest per author by `submitted_at` with the review id breaking ties. A
    `DISMISSED` review is not evidence, and an author's later opinion
    supersedes the earlier one.
    """
    if reviews is None:
        return path_outcome(False, "unreadable", None, "the reviews could not be read")
    newest: dict[str, dict] = {}
    for review in reviews:
        state = str(review.get("state") or "").upper()
        if state not in ("APPROVED", "CHANGES_REQUESTED"):
            continue
        author = owned_login(review).casefold()
        if not author:
            # An approval no author can be attached to cannot be superseded or
            # trusted: it is not evidence.
            continue
        key = (str(review.get("submitted_at") or ""), record_id(review))
        held = newest.get(author)
        if held is None or key > held["key"]:
            newest[author] = {"key": key, "state": state, "review": review}
    approvals = [
        entry["review"] for entry in newest.values() if entry["state"] == "APPROVED"
    ]
    if not approvals:
        detail = "no author's newest opinionated review is an approval"
        if not review_decision:
            detail = "reviewDecision is not APPROVED, and " + detail
        return path_outcome(False, "missing", None, detail)
    commits = sorted(
        {str(one.get("commit_id") or "").lower() for one in approvals} - {""}
    )
    if not commits:
        return path_outcome(
            False, "unattributed", None, "no approving review names a commit"
        )
    if head in commits:
        if not review_decision:
            return path_outcome(
                False, "approve", head, "reviewDecision is not APPROVED"
            )
        return path_outcome(True, "approve", head, None)
    return path_outcome(
        False,
        "stale",
        commits[-1],
        "the approving reviews name "
        + ", ".join(commits)
        + ", not the current head "
        + head,
    )


def label_path(
    attached: bool,
    label: str,
    comments: list[dict] | None,
    publisher: str,
    head: str,
    brand: str,
    result: dict,
) -> dict:
    """The `label` path: the approval label AND a valid current-head marker."""
    reasons = []
    if not attached:
        reasons.append("the configured approval label " + label + " is not attached")
    if comments is None:
        reasons.append("the comment feed could not be read")
        return path_outcome(False, "unreadable", None, "; ".join(reasons))
    selection, history = select_marker(comments, publisher)
    result["marker_history"] = history
    if not selection.ok:
        reasons.append(selection.detail)
        return path_outcome(False, selection.kind, None, "; ".join(reasons))
    problem = marker_verdict_reason(selection, head)
    evidence = "approve"
    if selection.verdict != "APPROVE":
        evidence = "non-approval"
    elif selection.head != head:
        evidence = "stale"
    elif brand in selection.reviewers:
        evidence = "self-review"
        problem = (
            "the newest marker names this bundle's own brand ("
            + brand
            + ") as a reviewer, which is a self-review"
        )
    if problem is not None:
        reasons.append(problem)
    return path_outcome(not reasons, evidence, selection.head, "; ".join(reasons) or None)


def evaluate_fix(repo: str, pr: str, brand: str, explicit_config: str, result: dict) -> None:
    publisher = read_publisher(result)
    settings = load_workflow(repo, explicit_config)
    result["config"] = settings["config"]
    result["mode"] = mode = settings["approval_mode"]
    state = read_state(repo, pr, result)
    head = read_head(state, result)

    origin, problem = parse_origin(str(state.get("body") or ""))
    result["origin"] = origin
    if problem is not None:
        raise Refusal(problem)
    if origin is None:
        raise Refusal(
            "the pull request body carries no pr-origin marker, and fix requires "
            "the " + brand + " origin"
        )
    if origin != brand:
        raise Refusal(
            "the pull request is " + origin + "-origin, and this bundle fixes "
            "only " + brand + "-origin pull requests"
        )

    labels = label_names(state)
    problem = problem_label_reason(settings, labels)
    if problem is not None:
        raise Refusal(problem)

    attached = settings["approval_label"].casefold() in labels
    review_decision = str(state.get("reviewDecision") or "").upper() == "APPROVED"

    def confine(name: str, build) -> dict:
        # A parse failure in one path's evidence is that path's unmet outcome.
        # It must never reach the outer handler, which would refuse the whole
        # evaluation and veto a path that holds independently.
        try:
            return build()
        except Exception as error:
            return path_outcome(
                False,
                "unreadable",
                None,
                f"the {name} evidence could not be parsed ({type(error).__name__})",
            )

    paths = result["paths"]
    if mode in ("label", "either"):
        paths["label"] = confine(
            "label",
            lambda: label_path(
                attached,
                settings["approval_label"],
                read_comments(repo, pr),
                publisher,
                head,
                brand,
                result,
            ),
        )
    if mode in ("review", "either"):
        paths["review"] = confine(
            "review",
            lambda: native_path(read_reviews(repo, pr), head, review_decision),
        )

    met = [name for name, outcome in paths.items() if outcome["met"]]
    # Either path is enough under `either`; the others need their one path.
    if met:
        result["approval_head"] = paths[met[0]]["head"]
        return
    named = [outcome["head"] for outcome in paths.values() if outcome["head"]]
    result["approval_head"] = named[0] if named else None
    raise Refusal(
        mode
        + " mode: "
        + "; ".join(
            f"the {name} path is unmet ({outcome['detail']})"
            for name, outcome in paths.items()
        )
    )


# --------------------------------------------------------------------------
# The finalize policy.
# --------------------------------------------------------------------------


def finalize_origin_reason(origin: str | None, reviewers: set[str]) -> str | None:
    """Whose approval a merge may rest on, read off the pull request's origin.

    The marker alone cannot say whether an approval is independent: it names who
    reviewed, not who wrote the code.
    """
    if origin is None:
        # No declared origin is the dual route the coordinator takes: with no
        # brand to be opposite of, only a review carrying BOTH spawned
        # providers is known to be independent of whoever wrote the code. None
        # of Grok, Kimi, or Google is in that set: they are not reviewer
        # brands.
        if reviewers != UNKNOWN_ORIGIN_REVIEWERS:
            return (
                "this pull request declares no origin, so only a dual-brand review "
                "is known to be independent; the newest marker names "
                + ",".join(sorted(reviewers))
            )
    elif origin in reviewers:
        return (
            "the newest marker names this pull request's own brand ("
            + origin
            + ") as a reviewer, which is a self-review"
        )
    elif origin in EXTERNAL_ORIGIN_REVIEWERS and reviewers != EXTERNAL_ORIGIN_REVIEWERS[origin]:
        return (
            "a "
            + origin
            + "-origin pull request is reviewed by Codex only; the newest "
            "marker names " + ",".join(sorted(reviewers))
        )
    return None


def evaluate_finalize(repo: str, pr: str, explicit_config: str, result: dict) -> None:
    publisher = read_publisher(result)
    settings = load_workflow(repo, explicit_config)
    result["config"] = settings["config"]
    result["mode"] = mode = settings["approval_mode"]
    state = read_state(repo, pr, result)
    paths = result["paths"]

    # The head is a diagnostic on every refusal, so it is recorded as soon as it
    # is readable; a head that is not readable still refuses, at the point the
    # configured signal and the problem labels have been weighed.
    head_text = str(state.get("headRefOid") or "").lower()
    if HEAD_RE.match(head_text) is not None:
        result["head"] = head_text

    labels = label_names(state)
    by_label = settings["approval_label"].casefold() in labels
    by_review = str(state.get("reviewDecision") or "").upper() == "APPROVED"
    signal = {"label": by_label, "review": by_review, "either": by_label or by_review}[mode]
    paths["signal"] = path_outcome(
        signal,
        "approved" if signal else "missing",
        None,
        None if signal else "the configured " + mode + " signal is not present",
    )
    if not signal:
        raise Refusal(
            "this repository approves by "
            + mode
            + " and the pull request is not approved that way"
        )
    problem = problem_label_reason(settings, labels)
    if problem is not None:
        raise Refusal(problem)

    head = read_head(state, result)

    comments = read_comments(repo, pr)
    if comments is None:
        paths["canonical"] = path_outcome(
            False, "unreadable", None, "the comment feed could not be read"
        )
        raise Refusal("the pull request or its comment feed could not be read")
    try:
        selection, history = select_marker(comments, publisher)
    except EvidenceError:
        paths["canonical"] = path_outcome(
            False, "unreadable", None, "the comment feed could not be parsed"
        )
        raise Refusal("the pull request or its comment feed could not be read") from None
    result["marker_history"] = history
    if not selection.ok:
        paths["canonical"] = path_outcome(False, selection.kind, None, selection.detail)
        raise Refusal(selection.detail)

    origin, problem = parse_origin(str(state.get("body") or ""))
    result["origin"] = origin
    result["approval_head"] = selection.head
    if problem is not None:
        paths["canonical"] = path_outcome(False, "origin", selection.head, problem)
        raise Refusal(problem)
    problem = finalize_origin_reason(origin, selection.reviewers)
    if problem is None:
        problem = marker_verdict_reason(selection, head)
    if problem is not None:
        paths["canonical"] = path_outcome(
            False,
            "stale" if selection.head != head else "refused",
            selection.head,
            problem,
        )
        raise Refusal(problem)
    paths["canonical"] = path_outcome(True, "approve", selection.head, None)


# --------------------------------------------------------------------------
# Entry point.
# --------------------------------------------------------------------------


class UsageError(Exception):
    pass


class Parser(argparse.ArgumentParser):
    """Reports a usage error as the contract's refusal object, not only as text."""

    def error(self, message: str):
        raise UsageError(message)


def build_parser() -> argparse.ArgumentParser:
    parser = Parser(
        prog="pr_head_approval.py",
        description="Evaluate head-bound approval of one pull request for a caller policy.",
        add_help=False,
        allow_abbrev=False,
    )
    parser.add_argument("--policy", required=True, choices=POLICIES)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--pr", required=True)
    parser.add_argument("--brand", choices=BRANDS)
    parser.add_argument("--config", default="")
    return parser


def evaluate(arguments: argparse.Namespace) -> dict:
    result = new_result(arguments.policy)
    try:
        if REPO_RE.match(arguments.repo) is None:
            raise UsageError("--repo must be one owner/name")
        # `gh` accepts a branch name or a URL wherever a number goes, so an
        # unvalidated target would evaluate (and let a caller then act on)
        # whatever pull request that branch happens to have open.
        if not (arguments.pr.isascii() and arguments.pr.isdigit()) or int(arguments.pr) < 1:
            raise UsageError("--pr must be exactly one positive pull request number")
        if arguments.policy == "fix" and arguments.brand is None:
            raise UsageError("--brand is required for the fix policy")
        if arguments.policy == "finalize" and arguments.brand is not None:
            raise UsageError("--brand is not accepted by the finalize policy")
        pr = str(int(arguments.pr))
        try:
            if arguments.policy == "fix":
                evaluate_fix(arguments.repo, pr, arguments.brand, arguments.config, result)
            else:
                evaluate_finalize(arguments.repo, pr, arguments.config, result)
        except Refusal as refusal:
            result["approved"] = False
            result["reason"] = refusal.reason
            return result
        except Exception as error:  # fail closed on anything unforeseen
            result["approved"] = False
            result["reason"] = (
                "the approval could not be evaluated: " + type(error).__name__
            )
            return result
        result["approved"] = True
        result["reason"] = None
        return result
    except UsageError as error:
        result["approved"] = False
        result["reason"] = "usage: " + str(error)
        result["usage"] = True
        return result


def main(argv: list[str] | None = None) -> int:
    try:
        arguments = build_parser().parse_args(argv)
    except (UsageError, SystemExit) as error:
        result = new_result(None)
        result["reason"] = "usage: " + (
            str(error) if isinstance(error, UsageError) else "invalid arguments"
        )
        result["usage"] = True
        sys.stdout.write(json.dumps(result) + "\n")
        return 2
    result = evaluate(arguments)
    sys.stdout.write(json.dumps(result) + "\n")
    if result["approved"] is True:
        return 0
    if result.get("usage"):
        return 2
    sys.stderr.write(
        "pr_head_approval: " + str(arguments.policy) + " refused: " + str(result["reason"]) + "\n"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
