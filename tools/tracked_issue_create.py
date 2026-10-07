#!/usr/bin/env python3
"""Create one checkpointed tracker issue as a single fail-closed operation.

Run as:

    python3 <bundle>/tracked_issue_create.py \\
        --repo coghex/kanban --root <write-root> --path docs/designs/x.md \\
        --step 0 --create --approved --request -   < request.json

where `request.json` is `{"title": ..., "body": ..., "labels": [...]}`, and the
step's recorded `payload_fingerprint` is what

    python3 <bundle>/tracked_issue_create.py --fingerprint --request -

prints for that same request.

## Why this exists

`tools/tracker_transaction.py` checkpoints an approved disposition's tracker
mutations, but a workflow drove it as a chain of separate shell commands:
`--begin-step`, then `gh issue create`, then `--confirm-step` with an identity
assembled by hand. A chain is something a caller can half-apply. One run's
`--begin-step` failed, the caller carried on regardless, and the issue it then
created existed with no durable intent recorded for it — exactly the
unaccounted-for mutation the transaction exists to prevent.

This module makes the issue-creating step one operation that cannot be
half-applied by its caller:

1. the request is validated, its payload fingerprint must equal the one the
   approved plan recorded for the step, and the step's recorded target must
   name the repository the issue is created in — a plan approved for
   `someone/else` never creates in the write root's repository;
2. the step's intent is recorded durably through `tracker_transaction.py`'s own
   `action_begin` compare-and-swap, and **no GitHub request is made unless that
   write succeeded**;
3. the issue is created through the REST API, and the identity GitHub returned
   — number, URL, title, body, labels — is checked against the request;
4. the step is confirmed with that identity, using the begin token held in this
   process from step 2 to step 4, so the correlation between the recorded
   intent and the created issue never passes through the caller.

The caller consumes one structured result. Its `github_mutation` field is the
answer a caller needs before doing anything else: `none` (no issue was or could
have been created by this run), `performed` (one was), or `unknown` (one may
have been). Every outcome other than `created` and `already-created` stops.

## Recovery is the transaction's, not a second journal

There is no state here beyond the existing tracker transaction record. An
interrupted or uncertain creation leaves its step in `intent`, which
`tracker_transaction.py` already treats as ambiguous and refuses to advance. A
later `--create` for that step refuses before any request. `--inspect` reports,
read-only, every issue created in the repository since the step began whose
title or body matches the request, and from that evidence a human may approve
exactly one of the two recovery transitions issue #327 permits:

- `--reconcile --issue N --approved` binds the step to issue `N` only when `N`
  is the one exact match and nothing else is even similar; it goes through
  `action_reconcile`, so the record's own target and fingerprint checks apply;
- `--authorize-retry --approved` returns the step to `planned` only when
  nothing created since the step began matches or resembles the request; it
  goes through `action_authorize_retry`, and creates nothing itself.

A confirmed step is never created again: `--create` for it verifies the
recorded issue still exists and reports `already-created`.

Recovery decides on GitHub's evidence only when that evidence is complete.
The listing is paged in ascending creation order to a conclusive short page
and read twice; every row, pull requests included, must carry a valid number,
canonical URL in the repository, title, body (null is legitimate; omitted is
not), labels, and creation time; and every JSON value, here as in the request
and the create response, must parse strictly, without duplicate keys. Anything
else — empty output, a stub row, a truncated or repeated page, a listing that
does not end or changes between reads — is refused as `evidence-incomplete`:
the step stays ambiguous and blocks creation, and neither binding nor retry is
permitted, because a listing that could not be read proves nothing about what
exists. A valid, complete, empty listing is evidence of absence, and even then
only the user's explicit approval returns the step to planned.

The window `--inspect` searches starts at the commit time of the record's
current value — while a step is ambiguous, no other transition can have moved
it, so that is when the step began — less a clock-skew margin.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import importlib.util
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

FINGERPRINT_PREFIX = "issue-v1:sha256:"
REQUEST_FIELDS = ("title", "body", "labels")

# GitHub's own limits; a request beyond them fails at GitHub, after intent was
# recorded, which turns a validation error into an ambiguous step.
TITLE_LIMIT = 256
BODY_LIMIT = 65536

# How far before the recorded begin an issue may have been stamped by GitHub's
# clock and still be this step's creation.
CLOCK_SKEW_SECONDS = 900

# The listing recovery reads: a page size, and the most pages it reads before
# refusing the listing as one it cannot read whole.
LISTING_PAGE_SIZE = 100
LISTING_PAGE_LIMIT = 50

CREATE_TIMEOUT_SECONDS = 120
READ_TIMEOUT_SECONDS = 60

MUTATION_NONE = "none"
MUTATION_PERFORMED = "performed"
MUTATION_UNKNOWN = "unknown"

EVIDENCE_ABSENT = "absent"
EVIDENCE_UNIQUE = "unique-exact"
EVIDENCE_AMBIGUOUS = "ambiguous"

# An `owner/name` named in a step's free-text target, such as the
# `coghex/kanban` of "new issue in coghex/kanban".
REPOSITORY_SLUG_RE = re.compile(
    r"(?<![\w./-])([A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?/[A-Za-z0-9._-]+)"
    r"(?![\w/-])"
)
GITHUB_URL_PREFIX_RE = re.compile(r"https?://github\.com/", re.IGNORECASE)


def tracker_module():
    """tools/tracker_transaction.py, loaded from beside this file: the record,
    its compare-and-swap, and every transition are that module's alone."""
    source = Path(__file__).resolve().parent / "tracker_transaction.py"
    spec = importlib.util.spec_from_file_location(
        "_kanban_tracker_for_issue_create", source
    )
    if spec is None or spec.loader is None:
        raise ImportError(f"no loader for {source}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tracker = tracker_module()


class OperationError(Exception):
    """A refusal with a machine-readable `status`."""

    def __init__(self, status: str, message: str, **detail):
        super().__init__(message)
        self.status = status
        self.message = message
        self.detail = detail


class GitHubError(Exception):
    pass


# ----------------------------------------------------------------- request --


def normalize_request(raw) -> dict:
    """The request exactly as it will be sent, or a refusal.

    Unknown fields are refused rather than ignored: a field this module drops
    is a part of the approved payload that silently never reaches GitHub.
    """
    if not isinstance(raw, dict):
        raise OperationError("request-invalid", "the request is not a JSON object")
    unknown = sorted(set(raw) - set(REQUEST_FIELDS))
    if unknown:
        raise OperationError(
            "request-invalid", f"the request carries unsupported field(s) {unknown}"
        )
    title = raw.get("title")
    if not isinstance(title, str) or not title.strip():
        raise OperationError("request-invalid", "the request has no title")
    title = title.strip()
    if "\n" in title or "\r" in title:
        raise OperationError("request-invalid", "the title spans more than one line")
    if len(title) > TITLE_LIMIT:
        raise OperationError(
            "request-invalid", f"the title exceeds {TITLE_LIMIT} characters"
        )
    body = raw.get("body")
    if not isinstance(body, str) or not body.strip():
        raise OperationError("request-invalid", "the request has no body")
    body = body.replace("\r\n", "\n")
    if len(body) > BODY_LIMIT:
        raise OperationError(
            "request-invalid", f"the body exceeds {BODY_LIMIT} characters"
        )
    labels = raw.get("labels", [])
    if not isinstance(labels, list):
        raise OperationError("request-invalid", "labels is not a list")
    names = []
    for label in labels:
        if not isinstance(label, str) or not label.strip():
            raise OperationError("request-invalid", f"label {label!r} is not a name")
        names.append(label.strip())
    return {"title": title, "body": body, "labels": sorted(set(names))}


def payload_fingerprint(request: dict) -> str:
    canonical = json.dumps(
        {field: request[field] for field in REQUEST_FIELDS},
        sort_keys=True, ensure_ascii=False, separators=(",", ":"),
    )
    return FINGERPRINT_PREFIX + hashlib.sha256(canonical.encode()).hexdigest()


# ------------------------------------------------------------------ GitHub --


class DuplicateKeyError(ValueError):
    pass


def _unique_keys(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise DuplicateKeyError(f"duplicate JSON key {key!r}")
        value[key] = item
    return value


_STRICT_DECODER = json.JSONDecoder(object_pairs_hook=_unique_keys)


def strict_json(text: str):
    """Exactly one JSON value: no duplicate keys, whose last value Python would
    otherwise keep silently, and nothing after it. Raises ValueError."""
    if not isinstance(text, str):
        raise ValueError("no text to parse")
    start = len(text) - len(text.lstrip())
    value, end = _STRICT_DECODER.raw_decode(text, start)
    if text[end:].strip():
        raise ValueError(f"data follows the JSON value at offset {end}")
    return value


def _github_json(text: str, what: str):
    try:
        return strict_json(text)
    except ValueError as error:
        raise GitHubError(f"{what} is not one strict JSON value: {error}") from error


class GhCli:
    """The three GitHub calls this operation makes, through `gh api`."""

    def __init__(self, executable: str | None = None):
        self.executable = (
            shutil.which("gh") if executable is None else executable
        )

    def available(self) -> bool:
        return bool(self.executable)

    def _run(self, command, *, input_text=None, timeout):
        """Run `command`, a `["gh", ...]` list, with the resolved `gh`."""
        if not self.executable:
            raise OSError("gh is not on PATH")
        return subprocess.run(
            [self.executable, *command[1:]], input=input_text, capture_output=True,
            text=True, timeout=timeout,
        )

    def create_issue(self, repository: str, request: dict):
        """The completed `gh api` process; raises OSError when it could not be
        started and subprocess.TimeoutExpired when it did not finish."""
        return self._run(
            ["gh", "api", "--method", "POST", f"repos/{repository}/issues",
             "--input", "-"],
            input_text=json.dumps(request), timeout=CREATE_TIMEOUT_SECONDS,
        )

    def _read(self, command):
        try:
            proc = self._run(command, timeout=READ_TIMEOUT_SECONDS)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise GitHubError(f"{' '.join(command)} could not run: {error}") from error
        if proc.returncode != 0:
            raise GitHubError(
                f"{' '.join(command)} failed: {(proc.stderr or proc.stdout).strip()}"
            )
        return proc.stdout

    def get_issue(self, repository: str, number: str) -> dict | None:
        """The issue, or None when GitHub reports it does not exist."""
        command = ["gh", "api", f"repos/{repository}/issues/{number}"]
        try:
            proc = self._run(command, timeout=READ_TIMEOUT_SECONDS)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise GitHubError(f"{' '.join(command)} could not run: {error}") from error
        if proc.returncode != 0:
            if "HTTP 404" in proc.stderr or "HTTP 410" in proc.stderr:
                return None
            raise GitHubError(
                f"{' '.join(command)} failed: {(proc.stderr or proc.stdout).strip()}"
            )
        return _json_object(proc.stdout)

    def listing_page(self, repository: str, since: str, page: int) -> list:
        value = _github_json(self._read([
            "gh", "api", "--method", "GET",
            f"repos/{repository}/issues?state=all&sort=created&direction=asc"
            f"&since={since}&per_page={LISTING_PAGE_SIZE}&page={page}",
        ]), f"issue listing page {page}")
        if not isinstance(value, list):
            raise GitHubError(f"issue listing page {page} is not a JSON array")
        return value

    def _one_pass(self, repository: str, since: str) -> list[dict]:
        entries, seen = [], set()
        for page in range(1, LISTING_PAGE_LIMIT + 1):
            items = self.listing_page(repository, since, page)
            if len(items) > LISTING_PAGE_SIZE:
                raise GitHubError(
                    f"issue listing page {page} holds {len(items)} entries, more "
                    f"than the {LISTING_PAGE_SIZE} requested"
                )
            for offset, item in enumerate(items):
                where = f"listing page {page} entry {offset}"
                try:
                    entry = listing_entry(repository, item)
                except GitHubError as error:
                    raise GitHubError(f"{where}: {error}") from error
                if entry["number"] in seen:
                    raise GitHubError(
                        f"{where} repeats #{entry['number']}: the pages shifted "
                        "while they were read"
                    )
                seen.add(entry["number"])
                entries.append(item)
            if len(items) < LISTING_PAGE_SIZE:
                return entries
        raise GitHubError(
            f"the issue listing did not end within {LISTING_PAGE_LIMIT} pages"
        )

    def issues_since(self, repository: str, since: str) -> list[dict]:
        """Every issue and pull request updated at or after `since`, complete,
        each entry validated, or a GitHubError.

        Pages are read in ascending creation order until a short page: a full
        page always means another must be read, so a listing that is exactly a
        multiple of the page size still ends on a conclusive empty page. Page
        offsets are not a snapshot — an issue deleted or transferred mid-read
        shifts every later entry back one, silently skipping one — so the
        listing is read twice and both passes must name the same issues in
        the same order."""
        first = self._one_pass(repository, since)
        second = self._one_pass(repository, since)
        if [item["number"] for item in first] != [item["number"] for item in second]:
            raise GitHubError(
                "the issue listing changed between two complete reads; it is "
                "not a consistent view of what exists"
            )
        return first


def _json_object(text: str) -> dict:
    value = _github_json(text, "GitHub's response")
    if not isinstance(value, dict):
        raise GitHubError("GitHub's response is not a JSON object")
    return value


PULL_URL_RE = re.compile(
    r"^https://github\.com/(?P<slug>[^/\s#]+/[^/\s#]+)/pull/(?P<number>\d+)$",
    re.IGNORECASE,
)

_MISSING = object()


def _number(issue: dict) -> int:
    number = issue.get("number", _MISSING)
    if not isinstance(number, int) or isinstance(number, bool) or number <= 0:
        raise GitHubError(f"no valid number ({'missing' if number is _MISSING else repr(number)})")
    return number


def issue_identity(repository: str, issue: dict) -> dict:
    """`{number, url}` of an issue GitHub returned, refusing anything that is
    not a plain issue of `repository` at its canonical URL."""
    number = _number(issue)
    url = issue.get("html_url")
    if "pull_request" in issue:
        raise GitHubError(f"#{number} is a pull request, not an issue")
    named = tracker.github_artifact(url if isinstance(url, str) else "", repository)
    if named != (str(number), None):
        raise GitHubError(
            f"GitHub returned {url!r}, which is not issue {number} of {repository}"
        )
    return {"number": number, "url": url}


def parse_timestamp(value) -> datetime.datetime:
    """A GitHub `YYYY-MM-DDTHH:MM:SSZ` timestamp, or a GitHubError."""
    if isinstance(value, str):
        try:
            parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            parsed = None
        if parsed is not None and parsed.tzinfo is not None:
            return parsed
    raise GitHubError(f"{value!r} is not a GitHub timestamp")


def _content_fields(issue: dict, number: int) -> None:
    """Every field a match or a window test reads, present and well-formed.
    A missing field is not a null one: GitHub sends `"body": null` for an
    issue without a body, and omits nothing, so an omitted body is a response
    that could not be read — reading it as empty could turn an issue whose
    title was edited into evidence that nothing was created."""
    for field in ("title", "body", "labels", "created_at"):
        if field not in issue:
            raise GitHubError(f"#{number} omits {field}")
    if not isinstance(issue["title"], str):
        raise GitHubError(f"#{number} has a malformed title")
    if issue["body"] is not None and not isinstance(issue["body"], str):
        raise GitHubError(f"#{number} has a malformed body")
    labels = issue["labels"]
    if not isinstance(labels, list) or not all(
        isinstance(label, str)
        or (isinstance(label, dict) and isinstance(label.get("name"), str))
        for label in labels
    ):
        raise GitHubError(f"#{number} has malformed labels")
    parse_timestamp(issue["created_at"])


def listing_entry(repository: str, item) -> dict:
    """`{kind, number}` of one listing row, validated before anything decides
    to exclude it: a pull request row must be a real pull request of
    `repository`, so a malformed row cannot hide behind a `pull_request` key."""
    if not isinstance(item, dict):
        raise GitHubError(f"{type(item).__name__}, not an issue")
    if "pull_request" not in item:
        issue_evidence(repository, item)
        return {"kind": "issue", "number": item["number"]}
    number = _number(item)
    pull = item["pull_request"]
    url = item.get("html_url")
    match = PULL_URL_RE.match(url) if isinstance(url, str) else None
    if (
        not isinstance(pull, dict)
        or match is None
        or match.group("slug").lower() != repository.lower()
        or int(match.group("number")) != number
        or pull.get("html_url") != url
    ):
        raise GitHubError(f"#{number} is not a well-formed pull request of {repository}")
    _content_fields(item, number)
    return {"kind": "pull", "number": number}


def issue_evidence(repository: str, issue) -> dict:
    """`{number, url}` of an issue GitHub returned, checked field by field:
    a malformed entry is evidence that could not be read, never evidence of
    absence."""
    if not isinstance(issue, dict):
        raise GitHubError(f"GitHub returned {type(issue).__name__}, not an issue")
    identity = issue_identity(repository, issue)
    _content_fields(issue, identity["number"])
    return identity


def issue_matches(issue: dict, request: dict) -> bool:
    """Whether `issue` carries the request's exact title and body and every
    requested label. Labels are a subset test because automation may add more
    after creation; title and body are what the approval named."""
    present = {
        label.get("name") if isinstance(label, dict) else label
        for label in issue["labels"]
    }
    return (
        issue["title"].strip() == request["title"]
        and (issue["body"] or "").replace("\r\n", "\n") == request["body"]
        and set(request["labels"]) <= present
    )


def issue_resembles(issue: dict, request: dict) -> bool:
    title = issue["title"].strip().casefold()
    body = (issue["body"] or "").replace("\r\n", "\n").strip()
    return title == request["title"].casefold() or body == request["body"].strip()


# --------------------------------------------------------------- operation --


def creation_target_refusal(step: dict, repository: str):
    """`(status, message)` when the step's recorded target does not name exactly
    `repository`, else None. The target is what the user approved; the
    repository is where this run would create. Both must agree before begin."""
    target = step.get("target") or ""
    named = {
        slug.lower() for slug in REPOSITORY_SLUG_RE.findall(
            GITHUB_URL_PREFIX_RE.sub(" ", target)
        )
    }
    if not named:
        return (
            "target-unverifiable",
            f"step target {target!r} names no owner/name repository, so it cannot be "
            f"shown to approve creating in {repository}",
        )
    if len(named) > 1:
        return (
            "target-unverifiable",
            f"step target {target!r} names several repositories "
            f"{sorted(named)}; it cannot be shown to approve creating in "
            f"{repository}",
        )
    if named != {repository.lower()}:
        return (
            "target-mismatch",
            f"step target {target!r} approves creating in {named.pop()}, not in "
            f"{repository}; nothing was created",
        )
    return None


class Context:
    """One validated request, bound to one step of one durable record."""

    def __init__(self, root, repository, document, index, raw_request):
        self.request = normalize_request(raw_request)
        self.fingerprint = payload_fingerprint(self.request)
        self.root = tracker.resolve_write_root(Path(root))
        self.repository = tracker.verify_owner(self.root, repository)
        self.document = document
        self.ref = tracker.transaction_ref(self.repository, document)
        self.index = index
        self.reload()

    def reload(self):
        record, observed = tracker.read_record(
            self.root, self.ref, repository=self.repository, document=self.document
        )
        if record is None:
            raise OperationError(
                "no-transaction",
                "no tracker transaction is recorded for this document; acquire the "
                "approved plan with tracker_transaction.py --acquire first",
            )
        steps = record["steps"]
        if not isinstance(self.index, int) or not 0 <= self.index < len(steps):
            raise OperationError(
                "step-out-of-range",
                f"this transaction plans {len(steps)} step(s); {self.index} is not one",
            )
        step = steps[self.index]
        if step["kind"] not in tracker.ISSUE_IDENTITY_KINDS:
            raise OperationError(
                "step-not-issue-creation",
                f"step {self.index} is a {step['kind']}, not an issue creation",
            )
        target_refusal = creation_target_refusal(step, self.repository)
        if target_refusal is not None:
            raise OperationError(*target_refusal)
        if step["payload_fingerprint"] != self.fingerprint:
            raise OperationError(
                "payload-mismatch",
                f"the request's fingerprint {self.fingerprint} is not step "
                f"{self.index}'s approved {step['payload_fingerprint']}",
            )
        self.record, self.observed = record, observed
        self.step = step

    def report(self) -> dict:
        return tracker.transaction_report(self.record, self.ref, self.observed)

    def durable_report(self) -> dict:
        """What is recorded now, re-read, for a result that follows a failure."""
        return tracker.observed_report(
            self.root, self.ref, repository=self.repository, document=self.document
        )

    def command(self, action: str) -> str:
        return (
            f"tracked_issue_create.py --repo {self.repository} --root {self.root} "
            f"--path {self.document} --step {self.index} --request <the same "
            f"request> {action}"
        )


def result(status, *, ok, message, github_mutation, ctx=None, transaction=None,
           issue=None, next_action=None, **extra) -> dict:
    if transaction is None and ctx is not None:
        transaction = ctx.report()
    payload = {
        "ok": ok,
        "status": status,
        "message": message,
        "github_mutation": github_mutation,
        "issue": issue,
        "transaction": transaction,
        "next_action": next_action or (
            transaction.get("next_action") if transaction else None
        ) or "stop: no tracker mutation is permitted until this is resolved",
    }
    if ctx is not None:
        payload["correlation"] = {
            "repository": ctx.repository,
            "document": ctx.document,
            "transaction_ref": ctx.ref,
            "step": ctx.index,
            "payload_fingerprint": ctx.fingerprint,
        }
    payload.update(extra)
    return payload


def refusal(error, ctx=None) -> dict:
    """A refusal made before this run could have mutated GitHub."""
    detail = dict(getattr(error, "detail", {}) or {})
    transaction = None
    if ctx is not None:
        transaction = ctx.durable_report()
    elif "transaction_ref" in detail:
        transaction = detail
    extra = {"cause": detail["cause"]} if "cause" in detail else {}
    return result(
        getattr(error, "status", "internal-error"),
        ok=False,
        message=getattr(error, "message", f"{type(error).__name__}: {error}"),
        github_mutation=MUTATION_NONE,
        ctx=ctx,
        transaction=transaction,
        next_action=(
            "stop: nothing was created. Fix the cause and run the operation again"
            if transaction is None or transaction.get("acquired") is False
            else None
        ),
        **extra,
    )


def verify_confirmed(ctx: Context, github) -> dict:
    """A confirmed step's issue must still be the one recorded. Content may
    since have been edited by people; existence and identity may not change."""
    identity = ctx.step["identity"]
    issue = {"number": int(identity["id"]), "url": identity["url"]}
    try:
        found = github.get_issue(ctx.repository, identity["id"])
    except GitHubError as error:
        return result(
            "verification-failed", ok=False, github_mutation=MUTATION_NONE, ctx=ctx,
            issue=issue,
            message=f"step {ctx.index} is confirmed, but its issue could not be "
            f"read back ({error}); it is never created again",
            next_action="retry the read-only verification; never create this issue again",
        )
    if found is None:
        return result(
            "confirmed-artifact-missing", ok=False, github_mutation=MUTATION_NONE,
            ctx=ctx, issue=issue,
            message=f"step {ctx.index} is confirmed as {issue['url']}, but GitHub "
            "reports that issue does not exist",
            next_action="stop and report to the user; a confirmed mutation is "
            "never repeated or replaced automatically",
        )
    try:
        same = issue_evidence(ctx.repository, found) == issue
        problem = "it names a different issue"
    except GitHubError as error:
        same, problem = False, str(error)
    if not same:
        return result(
            "verification-failed", ok=False, github_mutation=MUTATION_NONE,
            ctx=ctx, issue=issue,
            message=f"step {ctx.index} is confirmed as {issue['url']}, but GitHub's "
            f"read-back is not that issue, whole ({problem}); it is never "
            "created again",
            next_action="stop and report to the user; retry the read-only "
            "verification, and never create this issue again",
        )
    return result(
        "already-created", ok=True, github_mutation=MUTATION_NONE, ctx=ctx,
        issue=issue, content_matches=issue_matches(found, ctx.request),
        message=f"step {ctx.index} was already confirmed as {issue['url']}; "
        "nothing was created",
    )


def _uncertain(ctx, status, message, github_mutation, issue=None, **extra) -> dict:
    return result(
        status, ok=False, message=message, github_mutation=github_mutation,
        ctx=ctx, transaction=ctx.durable_report(), issue=issue,
        next_action=(
            f"stop. Step {ctx.index} stays ambiguous and is never retried "
            f"automatically. Run `{ctx.command('--inspect')}`, show the user what "
            "it found, and only on their explicit approval either bind the one "
            "exact issue with --reconcile --issue N --approved or, when nothing "
            "matches, authorize a retry with --authorize-retry --approved"
        ),
        **extra,
    )


def create(root, repository, document, index, raw_request, *, approved,
           github=None) -> dict:
    github = github or GhCli()
    ctx = None
    try:
        ctx = Context(root, repository, document, index, raw_request)
        state = ctx.step["state"]
        if state == tracker.STEP_CONFIRMED:
            return verify_confirmed(ctx, github)
        if state == tracker.STEP_INTENT:
            return _uncertain(
                ctx, "step-ambiguous",
                f"step {index} began earlier and was never confirmed, so an issue "
                "may already exist for it; this run created nothing",
                MUTATION_NONE,
            )
        if not approved:
            raise OperationError(
                "approval-required",
                "--approved is required: the exact issue is approved before it "
                "is created",
            )
        if not github.available():
            raise OperationError(
                "gh-unavailable", "gh is not on PATH, so no issue could be created"
            )
        try:
            begun = tracker.action_begin(
                ctx.root, ctx.ref, ctx.record, ctx.observed, index
            )
        except tracker.TransactionError as error:
            raise OperationError(
                "begin-failed",
                f"the step's intent could not be recorded ({error.status}: "
                f"{error.message}); no issue was created",
                cause=error.status,
            ) from error
    except (OperationError, GitHubError, tracker.TransactionError) as error:
        return refusal(error, ctx)
    except Exception as error:  # noqa: BLE001 - nothing was sent yet
        return refusal(OperationError("internal-error", f"{type(error).__name__}: {error}"), ctx)

    # From here the record says intent: GitHub may be mutated.
    token = begun["begin_token"]
    ctx.observed = begun["transaction_commit"]
    begin_commit = ctx.observed
    try:
        try:
            proc = github.create_issue(ctx.repository, ctx.request)
        except OSError as error:
            return _uncertain(
                ctx, "create-not-sent",
                f"gh could not be started ({error}); no request reached GitHub, but "
                "the recorded intent still needs an approved retry",
                MUTATION_NONE, begin_commit=begin_commit,
            )
        except subprocess.TimeoutExpired:
            return _uncertain(
                ctx, "outcome-uncertain",
                "the create request did not finish; GitHub may have created the issue",
                MUTATION_UNKNOWN, begin_commit=begin_commit,
            )
        if proc.returncode != 0:
            return _uncertain(
                ctx, "outcome-uncertain",
                "the create request failed; GitHub may still have created the "
                f"issue: {(proc.stderr or proc.stdout).strip()[-2000:]}",
                MUTATION_UNKNOWN, begin_commit=begin_commit,
            )
        try:
            created = _json_object(proc.stdout)
            issue = issue_evidence(ctx.repository, created)
        except GitHubError as error:
            return _uncertain(
                ctx, "outcome-uncertain",
                f"the create request succeeded but its response is unusable ({error})",
                MUTATION_UNKNOWN, begin_commit=begin_commit,
                response=proc.stdout[-2000:],
            )
        if not issue_matches(created, ctx.request):
            return _uncertain(
                ctx, "created-mismatch",
                f"GitHub created {issue['url']}, but not with the approved title, "
                "body, and labels",
                MUTATION_PERFORMED, issue=issue, begin_commit=begin_commit,
            )
        identity = {
            "kind": ctx.step["kind"],
            "id": str(issue["number"]),
            "url": issue["url"],
            "document_token": f"[#{issue['number']}]",
            "postcondition_verified": True,
        }
        original = json.loads(json.dumps(ctx.record))
        try:
            confirmed = tracker.action_confirm(
                ctx.root, ctx.ref, ctx.record, ctx.observed, index, identity, token
            )
            tracker.require_preserved_confirmations(original, ctx.record)
        except tracker.TransactionError as error:
            return _uncertain(
                ctx, "created-unconfirmed",
                f"{issue['url']} was created, but confirming it failed "
                f"({error.status}: {error.message})",
                MUTATION_PERFORMED, issue=issue, begin_commit=begin_commit,
            )
        ctx.observed = confirmed["transaction_commit"]
        return result(
            "created", ok=True, github_mutation=MUTATION_PERFORMED, ctx=ctx,
            issue=issue, begin_commit=begin_commit,
            message=f"created and confirmed {issue['url']} for step {index}",
        )
    except Exception as error:  # noqa: BLE001 - a request may have been sent
        return _uncertain(
            ctx, "outcome-uncertain", f"{type(error).__name__}: {error}",
            MUTATION_UNKNOWN, begin_commit=begin_commit,
        )


def window_start(ctx: Context) -> str:
    seconds = int(tracker.git_out(
        ["show", "-s", "--format=%ct", ctx.observed], cwd=ctx.root
    ))
    start = datetime.datetime.fromtimestamp(
        seconds - CLOCK_SKEW_SECONDS, tz=datetime.timezone.utc
    )
    return start.strftime("%Y-%m-%dT%H:%M:%SZ")


def candidates(ctx: Context, github) -> dict:
    """Every issue created since the ambiguous step began that is the request's
    exact issue, or merely resembles it. Read-only."""
    since = window_start(ctx)
    start = parse_timestamp(since)
    exact, similar = [], []
    for item in github.issues_since(ctx.repository, since):
        # Every row was validated whole by the listing, pull requests included.
        if "pull_request" in item:
            continue
        identity = issue_evidence(ctx.repository, item)
        if parse_timestamp(item["created_at"]) < start:
            continue
        entry = identity | {
            "title": item.get("title"), "created_at": item.get("created_at"),
        }
        if issue_matches(item, ctx.request):
            exact.append(entry)
        elif issue_resembles(item, ctx.request):
            similar.append(entry)
    if not exact and not similar:
        evidence = EVIDENCE_ABSENT
    elif len(exact) == 1 and not similar:
        evidence = EVIDENCE_UNIQUE
    else:
        evidence = EVIDENCE_AMBIGUOUS
    return {
        "window_start": since, "exact": exact, "similar": similar,
        "evidence": evidence,
    }


def evidence_refusal(ctx: Context, error: GitHubError) -> dict:
    """GitHub's evidence could not be read whole: no recovery decision."""
    return result(
        "evidence-incomplete", ok=False, github_mutation=MUTATION_NONE, ctx=ctx,
        transaction=ctx.durable_report(),
        message=f"GitHub's issue evidence is incomplete or malformed ({error}); "
        f"step {ctx.index} stays ambiguous",
        next_action=(
            "stop. Neither binding nor retry is permitted on unreadable evidence; "
            f"run `{ctx.command('--inspect')}` again once GitHub returns a "
            "complete listing, and report to the user if it does not"
        ),
    )


def _ambiguous_context(root, repository, document, index, raw_request):
    ctx = Context(root, repository, document, index, raw_request)
    if ctx.step["state"] != tracker.STEP_INTENT:
        raise OperationError(
            "step-not-ambiguous",
            f"step {index} is {ctx.step['state']}, not ambiguous; there is nothing "
            "to recover",
        )
    return ctx


def inspect(root, repository, document, index, raw_request, *, github=None) -> dict:
    github = github or GhCli()
    ctx = None
    try:
        ctx = _ambiguous_context(root, repository, document, index, raw_request)
        found = candidates(ctx, github)
    except GitHubError as error:
        return evidence_refusal(ctx, error)
    except (OperationError, tracker.TransactionError) as error:
        return refusal(error, ctx)
    permitted = {
        EVIDENCE_ABSENT: (
            "nothing created since the step began matches or resembles the "
            "request. With the user's explicit approval, --authorize-retry "
            "--approved returns the step to planned"
        ),
        EVIDENCE_UNIQUE: (
            f"issue #{found['exact'][0]['number']} is the one exact match. With "
            "the user's explicit approval, --reconcile --issue "
            f"{found['exact'][0]['number']} --approved binds the step to it"
            if found["exact"] else ""
        ),
        EVIDENCE_AMBIGUOUS: (
            "more than one issue matches or resembles the request; neither binding "
            "nor retry is permitted. Stop and report the candidates to the user"
        ),
    }[found["evidence"]]
    return result(
        "inspected", ok=True, github_mutation=MUTATION_NONE, ctx=ctx,
        message=f"step {index} is ambiguous; evidence: {found['evidence']}",
        next_action=permitted, candidates=found,
    )


def reconcile(root, repository, document, index, raw_request, issue_number, *,
              approved, github=None) -> dict:
    github = github or GhCli()
    ctx = None
    try:
        ctx = _ambiguous_context(root, repository, document, index, raw_request)
        if not approved:
            raise OperationError(
                "approval-required",
                "--approved is required: an ambiguous step is bound only on the "
                "user's explicit approval of that exact issue",
            )
        found = candidates(ctx, github)
        numbers = [entry["number"] for entry in found["exact"]]
        if found["evidence"] != EVIDENCE_UNIQUE or numbers != [issue_number]:
            return result(
                "candidates-not-unique", ok=False, github_mutation=MUTATION_NONE,
                ctx=ctx, candidates=found,
                message=f"issue #{issue_number} is not the one exact match for step "
                f"{index} (exact: {numbers}, similar: "
                f"{[entry['number'] for entry in found['similar']]}); the step "
                "stays ambiguous",
                next_action="stop and report the candidates to the user; a "
                "similarly titled issue is never sufficient evidence",
            )
        issue = {"number": issue_number, "url": found["exact"][0]["url"]}
        identity = {
            "kind": ctx.step["kind"],
            "id": str(issue_number),
            "url": issue["url"],
            "document_token": f"[#{issue_number}]",
            "postcondition_verified": True,
            "matched_target": ctx.step["target"],
            "matched_payload_fingerprint": ctx.step["payload_fingerprint"],
        }
        outcome = tracker.action_reconcile(
            ctx.root, ctx.ref, ctx.record, ctx.observed, index, identity, 1
        )
        ctx.observed = outcome["transaction_commit"]
    except GitHubError as error:
        return evidence_refusal(ctx, error)
    except (OperationError, tracker.TransactionError) as error:
        return refusal(error, ctx)
    return result(
        "reconciled", ok=True, github_mutation=MUTATION_NONE, ctx=ctx, issue=issue,
        candidates=found,
        message=f"step {index} is bound to {issue['url']}",
    )


def authorize_retry(root, repository, document, index, raw_request, *,
                    approved, github=None) -> dict:
    github = github or GhCli()
    ctx = None
    try:
        ctx = _ambiguous_context(root, repository, document, index, raw_request)
        if not approved:
            raise OperationError(
                "approval-required",
                "--approved is required: a retry is authorized only by the user",
            )
        found = candidates(ctx, github)
        if found["evidence"] != EVIDENCE_ABSENT:
            return result(
                "retry-refused", ok=False, github_mutation=MUTATION_NONE, ctx=ctx,
                candidates=found,
                message=f"step {index}'s issue may exist: something created since "
                "it began matches or resembles the request",
                next_action="stop and report the candidates to the user",
            )
        outcome = tracker.action_authorize_retry(
            ctx.root, ctx.ref, ctx.record, ctx.observed, index
        )
        ctx.observed = outcome["transaction_commit"]
    except GitHubError as error:
        return evidence_refusal(ctx, error)
    except (OperationError, tracker.TransactionError) as error:
        return refusal(error, ctx)
    return result(
        "retry-authorized", ok=True, github_mutation=MUTATION_NONE, ctx=ctx,
        candidates=found,
        message=f"step {index} is planned again; nothing was created",
        next_action=(
            "re-present the exact issue for approval, then run --create --approved "
            "for this step"
        ),
    )


# --------------------------------------------------------------------- CLI --


def load_request(source: str):
    try:
        text = sys.stdin.read() if source == "-" else Path(source).read_text(
            encoding="utf-8"
        )
        return strict_json(text)
    except (OSError, ValueError) as error:
        raise OperationError(
            "request-unreadable", f"{source} is not a readable JSON request: {error}"
        ) from error


def main(argv: list[str] | None = None, *, github=None) -> int:
    parser = argparse.ArgumentParser(
        description="Create one checkpointed tracker issue, fail-closed."
    )
    parser.add_argument("--repo", help="the owning owner/name")
    parser.add_argument("--root", type=Path, help="the local write root")
    parser.add_argument("--path", help="repository-relative document")
    parser.add_argument("--step", type=int, help="the issue-creating step's index")
    parser.add_argument(
        "--request", required=True, help="file holding the request, or - for stdin"
    )
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--fingerprint", action="store_true")
    action.add_argument("--create", action="store_true")
    action.add_argument("--inspect", action="store_true")
    action.add_argument("--reconcile", action="store_true")
    action.add_argument("--authorize-retry", action="store_true")
    parser.add_argument("--issue", type=int, help="the issue --reconcile binds")
    parser.add_argument(
        "--approved", action="store_true",
        help="the user explicitly approved this exact creation, binding, or retry",
    )
    args = parser.parse_args(argv)

    try:
        raw = load_request(args.request)
        if args.fingerprint:
            request = normalize_request(raw)
            outcome = {
                "ok": True, "status": "fingerprint", "github_mutation": MUTATION_NONE,
                "payload_fingerprint": payload_fingerprint(request),
                "request": request,
            }
        else:
            missing = [
                flag for flag, value in (
                    ("--repo", args.repo), ("--root", args.root),
                    ("--path", args.path), ("--step", args.step),
                ) if value is None
            ]
            if missing:
                parser.error(f"this action requires {' '.join(missing)}")
            common = (args.root, args.repo, args.path, args.step, raw)
            if args.create:
                outcome = create(*common, approved=args.approved, github=github)
            elif args.inspect:
                outcome = inspect(*common, github=github)
            elif args.reconcile:
                if args.issue is None:
                    parser.error("--reconcile requires --issue")
                outcome = reconcile(
                    *common, args.issue, approved=args.approved, github=github
                )
            else:
                outcome = authorize_retry(
                    *common, approved=args.approved, github=github
                )
    except OperationError as error:
        outcome = refusal(error)
    print(json.dumps(outcome, indent=2, sort_keys=True, default=str))
    return 0 if outcome["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
