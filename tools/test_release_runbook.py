"""Safety-rule check for docs/releasing.md, the maintainer release template, and
SUPPORT.md's report-what-you-have-installed bullet.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 -m unittest tools.test_release_runbook

Issue #539: the release procedure used to exist only as the first release's
history. `docs/releasing.md` states it reusably, and `.github/ISSUE_TEMPLATE/`'s
`release.md` is the per-release checklist that drives it. Both are prose, so
most of what they say is not this module's business.

Six things in them are, because each is a rule whose quiet removal would not
look like a regression to a reader:

* **Publication cannot happen without a recorded human authorization.** The
  runbook carries it as a step of its own, ahead of the tag push, naming the
  exact comment a maintainer has to leave; the template carries it as an
  unchecked item saying the same. A release procedure whose authorization is a
  clause inside another step is one an agent can satisfy by inference, which is
  the failure the step exists to prevent.
* **A pushed tag is immutable.** The one irreversible action in the procedure is
  the tag push, and every plausible repair afterwards — delete it, move it,
  reuse the version, force-push, publish the Release by hand — makes a published
  version mean two different things. The runbook forbids each by name.
* **Release evidence lives on the release issue.** Not in `docs/design.md`,
  whose section 21 is the closed first-release record, and not in a new Markdown
  file per version.
* **The dependency review is real work with a recorded result.** Five named
  subjects, two cadences, the ordinary issue lane for anything it finds, and a
  durable place to record a review that finds nothing.
* **The rehearsal is bound to the run its own dispatch created.** `gh workflow
  run` reports no run id, so the run has to be found afterwards. Found by the
  scratch branch, the candidate commit, and a creation floor captured before
  dispatching -- never by taking whichever `Release` run is newest, which
  selects another operator's dispatch as readily as this one's and puts it in
  the release evidence. This rule reads the fenced command rather than the
  paragraph around it, because that is what an operator runs, and the
  template's item records which run the answer turned out to be.
* **`kanban --doctor` reports AI-action readiness and nothing else.** Issue
  #618: the manual upgrade gate required it "reporting every advertised
  component ready" and named the managed components as "the issue-review
  service and the PR drainer", so an operator could satisfy the written gate
  without observing either managed job while trying to stop one that does not
  exist -- `tools/install_issue_review.py` installs a backend and starts no
  daemon. The two managed jobs are the PR drainer and the issue approval
  service, each observed through its own controller's returned `status` state.
  `SUPPORT.md` told a reporter the same false thing, which is why it is a
  subject of this module rather than of one of its own: the claim is one rule,
  and a second module would be a second place for it to drift. What the rule
  reads is the claim itself -- "reports X" parsed out and held to naming
  AI-action readiness and nothing wider -- rather than whether the right words
  appear near `--doctor`. Asking the looser question is how the first attempt
  at this rule accepted "AI-action readiness and all optional-component
  readiness": every required phrase was present, and the sentence still handed
  a managed service back.

The runbook is also version-neutral, which is what makes it reusable at all: a
release's own numbers belong to that release's issue.

The rules are predicates over the document text rather than assertions about
its wording, and each is run twice -- once against the live document, and once
against a copy with that rule's own sentence removed or inverted. A rule that
matched everything could not pass the second run while asserting nothing.

`tools/` ships whole in the source distribution and `.github/ISSUE_TEMPLATE/`
deliberately does not, so the template class skips on the missing directory the
way `tools/test_issue_templates.py` does. The runbook and `SUPPORT.md` are both
packaged documents, so their rules run in an unpacked release too.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RUNBOOK = REPO_ROOT / "docs" / "releasing.md"
TEMPLATE_DIR = REPO_ROOT / ".github" / "ISSUE_TEMPLATE"
RELEASE_TEMPLATE = TEMPLATE_DIR / "release.md"
SUPPORT = REPO_ROOT / "SUPPORT.md"

# The runbook's ordered procedure, by `##` heading. Requirement 1's sequence:
# version, changelog, candidate, rehearsal, dependencies, upgrade, settings,
# authorization, tag, observation, verification, evidence. Pinned in order
# because the order is the contract -- a gate recorded after the tag push is
# not a gate.
PROCEDURE_HEADINGS = (
    "1. Review the version and PVP compatibility",
    "2. Promote the changelog",
    "3. Select the candidate commit",
    "4. Rehearse the release on the candidate",
    "5. Review dependencies and maintenance assumptions",
    "6. Perform the manual supported-host upgrade",
    "7. Check the repository settings",
    "8. Record the publication authorization",
    "9. Push the one annotated tag",
    "10. Observe the release workflow",
    "11. Verify the published release as a consumer",
    "12. Record the evidence and close the issue",
)

AUTHORIZATION_HEADING = "8. Record the publication authorization"
TAG_HEADING = "9. Push the one annotated tag"
CANDIDATE_HEADING = "3. Select the candidate commit"
UPGRADE_HEADING = "6. Perform the manual supported-host upgrade"
SETTINGS_HEADING = "7. Check the repository settings"
OBSERVE_HEADING = "10. Observe the release workflow"
EVIDENCE_STEP_HEADING = "12. Record the evidence and close the issue"
EVIDENCE_HEADING = "Where release evidence lives"
FAILURE_HEADING = "If something fails after the tag is pushed"
DEPENDENCY_HEADING = "Dependency and maintenance review"

# The five prohibitions requirement 4 names, in the terms it names them.
# Keyed by rule name so a negative control can say which one it removed.
TAG_IMMUTABILITY_RULES = {
    "delete": "do not delete the tag",
    "move": "do not move the tag",
    "reuse": "do not reuse",
    "force-push": "force-push",
    "by-hand": "do not create the github release by hand",
}

# What makes the authorization a gate rather than a formality: the recorded
# artifact a maintainer has to leave, and the two claims that say nothing else
# substitutes for it.
AUTHORIZATION_RULES = {
    "recorded-comment": "authorized: publish <version> from <commit>.",
    "not-implied": "no other step implies it",
    "not-an-agent": "no agent may perform it",
}

# Requirement 5's evidence location, in both halves: where it goes, and the two
# places it deliberately does not.
EVIDENCE_RULES = {
    "release-issue": "release evidence lives on the release's own issue",
    "no-markdown-file": "no permanent per-release markdown file is created",
    "design-does-not-grow": "design.md does not grow",
}

# The six items requirement 5 says the evidence comment names.
EVIDENCE_ITEMS = {
    "commit": "released commit",
    "ci-run": "required ci run",
    "tag": "the tag",
    "release-run": "release workflow run",
    "digest": "digest",
    "consumer": "consumer verification",
}

# The candidate-identity boundary: one exact commit, carrying the required
# check, and gates that do not travel to another commit.
CANDIDATE_RULES = {
    "one-commit": "pick one exact commit on master",
    "required-check": "required build-test job reports success for that exact commit",
    "no-carry": "do not carry gates across",
}

# What the one manual host gate covers. Anything dropped from this list is a
# part of an upgrade nothing else exercises.
UPGRADE_ITEMS = {
    "executable": "the executable",
    "workflow-assets": "optional workflow assets",
    "managed-components": "managed components",
    "doctor": "--doctor",
    "board-run": "interactive board run",
    "state": "preservation of supported configuration and durable state",
}

# Issue #618's half of the same gate, kept separate from UPGRADE_ITEMS because
# that mapping asks only whether each subject is mentioned. `--doctor` is
# mentioned by a gate that credits it with the whole upgrade, which is how the
# false claim survived a passing suite: what has to be checked is what the gate
# *says* about each of these, not that the words appear.

# --- What a `kanban --doctor` claim may say, in either document ---
#
# `--doctor` is a read-only report on AI-action readiness
# (src/Kanban/Preflight/Readiness.hs). Both documents credited it with more,
# and the claim is one rule, so one vocabulary serves both.
#
# The claim is read as a clause rather than as a substring of the surrounding
# prose. Requiring `ai-action readiness` to appear *somewhere* nearby is what
# let the first attempt at this rule pass a claim reading "AI-action readiness
# and all optional-component readiness": the correct words were present, and
# the sentence still handed a managed service back to doctor.
DOCTOR_CLAIM_RE = re.compile(r"--doctor[^;.]*?\breport(?:s|ing)?\b (?P<claim>[^;.]*)")

# The scope a claim has to carry.
DOCTOR_SCOPE_RULE = "ai-action readiness"

# A managed service named inside a claim, in the word either is recognizable
# by once the claim is normalized.
CLAIMED_SERVICE_WORDS = ("drainer", "approval service")

# The other way a claim reaches a managed service: quantifying over the
# components instead of naming one. This is what makes the rule a rule rather
# than a list of forbidden sentences -- "every advertised component ready",
# "all optional-component readiness", and the anaphoric "which of them are
# ready" are one defect written three ways, and every one of them quantifies.
COMPONENT_QUANTIFIER_RE = re.compile(
    r"\b(?:every|all|each|both|any|which)\b[^;.]*"
    r"\b(?:component|components|them|three|service|services|job|jobs)\b"
)

# --- The runbook's manual upgrade gate ---
#
# The two managed jobs, named as they are installed --
# `tools/install_drainer.py`'s and `tools/install_issue_approval.py`'s.
MANAGED_SERVICE_NAMES = {
    "drainer": "pr drainer",
    "approval": "issue approval service",
}

# The managed component that does not exist. `tools/install_issue_review.py`
# installs a backend and starts no daemon, so a gate naming an "issue-review
# service" sends the operator to stop something nothing installed. Checked over
# the whole runbook rather than the gate alone: the name is wrong wherever it
# appears, and a mention that migrated into another step is the same defect.
ABSENT_MANAGED_SERVICE = "issue-review service"

# That the doctor item denies substituting for the two service checks, which
# is the sentence a reader acts on when deciding whether to run them.
DOCTOR_SUBSTITUTION_RULE = "does not stand in for"

# Each managed job is observed through its own controller, and the two rules
# are separate so a control can drop one check while the other stands. The
# gate carries `--doctor` either way, which is the point: a gate merely
# mentioning `--doctor` satisfies UPGRADE_ITEMS and still leaves both of these
# reported.
SERVICE_STATUS_RULES = {
    "drainer-status": "the pr drainer's controller status",
    "approval-status": "the issue approval service's controller status",
}

# How a status result is recorded, in both halves. The positive half is the
# one the canonical review asked for: `status` exits zero for a repository
# whose job was never installed (docs/issue-approval.md, "Reading status"), so
# the returned `state` is the evidence. Stating only the prohibition would let
# the instruction to read the state disappear while the gate still forbade the
# exit code -- which leaves an operator told what not to do and not what to do.
RETURNED_STATE_RULE = "the state the controller returned"
NOT_AN_EXIT_CODE_RULE = "not that the command exited zero"

# The repository metadata the settings step checks, exactly as the decision
# that fixed it states. Restated here so drift in either direction fails.
REPOSITORY_DESCRIPTION = (
    "A keyboard-driven terminal board for GitHub issues, pull requests, "
    "and agent workflows."
)
REPOSITORY_TOPICS = (
    "haskell",
    "terminal",
    "tui",
    "kanban",
    "github",
    "developer-tools",
    "ai-agents",
    "brick",
)

# Requirement 8's five subjects, its two cadences, its lane, and the two places
# a result is recorded.
DEPENDENCY_RULES = {
    "haskell-bounds": "direct haskell dependency bounds",
    "cabal-outdated": "cabal outdated",
    "toolchain-pins": "the pinned ghc and cabal versions",
    "actions-versions": "github actions major versions",
    "platform-security": "supported-platform and security assumptions",
    "cadence-release": "before each release",
    "cadence-quarterly": "approximately quarterly",
    "ordinary-lane": "becomes an ordinary issue and travels the ordinary approval, "
    "solve, and pull-request lane",
    "record-pre-release": "records its date and result on that release's issue",
    "record-off-cycle": "dependency-review issue",
}

REHEARSAL_HEADING = "4. Rehearse the release on the candidate"

# The rehearsal's fenced commands, with backslash continuations joined: the
# discovery command wraps across four lines, and a flag on the third of them
# belongs to the command that starts on the first.
CONSOLE_FENCE_RE = re.compile(r"```console\n(?P<body>.*?)\n[ \t]*```", re.DOTALL)
CONTINUATION_RE = re.compile(r"\\\n[ \t]*")

# What the fenced `gh run list` filters on, so the row it returns belongs to
# this rehearsal's own dispatch: the scratch branch, the candidate commit, and
# the creation floor captured before dispatching. Either flag spelling
# satisfies a rule -- these are about what the command asks GitHub for, not how
# it is typed.
RUN_SELECTION_FILTERS = {
    "branch": re.compile(r"(?<![\w-])(?:--branch|-b)[ =]+\"?release-candidate-<n>\"?"),
    "commit": re.compile(r"(?<![\w-])(?:--commit|-c)[ =]+\"?<commit>\"?"),
    "created": re.compile(r"(?<![\w-])--created[ =]+\"?>=?<dispatched-after>\"?"),
}

# The identity the same command asks for. `databaseId` is what gets watched and
# recorded; the other four are what let the operator check that the row it came
# from is this rehearsal's before either happens.
RUN_SELECTION_FIELDS = ("databaseId", "headBranch", "headSha", "createdAt", "url")

# `--limit`/`-L` truncates the listing, which is how the repository-wide
# newest-first selection hid the ambiguity it should have reported: a second
# eligible run has to be visible before the procedure can refuse to choose
# between them.
LIMIT_FLAG_RE = re.compile(r"(?<![\w-])(?:--limit|-L)(?:[ =]|$)")
JSON_FIELDS_RE = re.compile(r"(?<![\w-])--json[ =]+([A-Za-z0-9_,]+)")

# The instructions around that command, which stay prose because that is where
# they live: a listing that has not caught up is waited out, a listing with two
# rows stops the step, a row failing a correlation check is rejected rather
# than watched, and the record names the run together with what it was
# correlated on.
REHEARSAL_PROCEDURE_RULES = {
    "fresh-branch": "its own scratch-branch name and is dispatched once against it",
    "stable-window": "reuses that one value rather than a fresh reading",
    "repeat-the-query": "repeat the same query",
    "wait-not-redispatch": "do not dispatch again",
    "investigate-a-fault": "is a fault to investigate",
    "ambiguous-listing": "newest-first is not a tiebreak",
    "reject-foreign-run": "is not this rehearsal's evidence",
    "keep-querying": "reject it and keep querying",
    "record-run-identity": "its url or databaseid",
    "record-correlation": "the scratch branch and the candidate commit it was "
    "correlated on",
}

# The template's half of that record: the box is checked against a named run,
# not against "a rehearsal happened". Which run was watched, and what made it
# this rehearsal's, is the whole of what a later reader can check.
TEMPLATE_REHEARSAL_RULES = {
    "run-identity": "url or database id",
    "correlation": "the branch and commit it was correlated on",
}

# The fenced discovery command itself, and the repository-wide newest-first one
# it replaced. Spelled out so the controls below can swap one for the other and
# assert what the rules then report -- the defect restored verbatim, rather
# than an approximation of it.
SELECTION_COMMAND = """gh run list --workflow Release --event workflow_dispatch \\
  --branch release-candidate-<n> --commit <commit> \\
  --created ">=<dispatched-after>" \\
  --json databaseId,headBranch,headSha,createdAt,status,conclusion,url"""
UNCORRELATED_COMMAND = """gh run list --workflow Release --event workflow_dispatch --limit 1 \\
  --json databaseId,headSha,status,conclusion"""
SELECTION_FENCE = f"```console\n{SELECTION_COMMAND}\n```"
UNCORRELATED_FENCE = f"```console\n{UNCORRELATED_COMMAND}\n```"

# One mutation per filter, each a substring of that command, so a control
# names the filter it dropped rather than reporting that something changed.
# Cut from the command rather than from the document, because `--commit
# <commit>` is also how step 3 asks for the candidate's CI run.
FILTER_CONTROL_PHRASES = {
    "branch": "--branch release-candidate-<n>",
    "commit": "--commit <commit>",
    "created": '--created ">=<dispatched-after>"',
}

# What run_selection_gaps reports when the step carries no single fenced
# command for its rules to be about: the missing command, and every rule that
# had nothing to read.
NO_SELECTION_COMMAND_GAPS = sorted(
    ["selection-command"]
    + list(RUN_SELECTION_FILTERS)
    + [f"field:{field}" for field in RUN_SELECTION_FIELDS]
)

# The gaps the uncorrelated command leaves: every filter, the three identity
# fields it never requested, and the truncation that hid the ambiguity.
UNCORRELATED_SELECTION_GAPS = sorted(
    list(RUN_SELECTION_FILTERS)
    + ["field:createdAt", "field:headBranch", "field:url", "no-limit-selection"]
)

# The remediation the correlation replaces, as a prohibition: nothing reaches a
# second dispatch from a listing that merely has not matched yet. The causes
# the step does name for a fresh attempt are a run that failed and a dispatch
# that was never accepted, and a listing is neither.
REDISPATCH_ON_MISMATCH_RE = re.compile(
    r"(?:anything else|no row|does not match|mismatch)[^.]*\bdispatch again\b"
)

# A four-component package version, or any other dotted numeric run. The
# runbook spells every version `<version>`: a literal here is either a
# particular release's number or evidence from one, and requirement 2 forbids
# both.
VERSION_LITERAL_RE = re.compile(r"(?<![.\d])\d+(?:\.\d+){2,}(?![.\d])")

# SUPPORT.md's report-what-you-have-installed bullet, which told a reporter
# `kanban --doctor` reports which of the three optional components are ready.
# A support report could therefore cite a clean doctor run as evidence that the
# drainer or the approval job was healthy when neither was observed. Scoped to
# the one bullet rather than to the section: the neighbouring "Read the guides"
# bullet ends on "why one might not be ready", which is a true sentence about
# the components and no claim about anything that observes them.
SUPPORT_HEADING = "Before opening an issue"
SUPPORT_BULLET_OPENING = "Say what you have installed"

# Where the bullet sends a reporter for the other two components. The same
# phrases the runbook's gate uses, because it is the same instruction: observe
# each managed job through its own controller's status.
SUPPORT_CONTROLLER_RULES = {
    "drainer-controller": "the pr drainer's controller status",
    "approval-controller": "the issue approval service's controller status",
}

# A readiness attribution anywhere in that bullet, and the two things allowed
# to carry one. The claim rules above read the doctor sentence; they cannot see
# a *second* sentence that hands the same readiness back without naming doctor
# again -- "It also reports whether the PR drainer and the issue approval
# service are ready" recreates the defect with every clause-level rule still
# satisfied. So every readiness attribution in the bullet has to name what
# observes it, and the only two observers are `--doctor` and a controller's
# status. Deliberately strict, and deliberately confined to this one bullet:
# the repair for a sentence it reports is to say what observes the readiness
# it claims, never to loosen the rule.
READINESS_RE = re.compile(r"\bread(?:y|iness)\b|\breport(?:s|ed|ing)?\b")
CONTROLLER_OBSERVER = "controller status"

HEADING_RE = re.compile(r"^(?P<hashes>#+)\s+(?P<heading>.+?)\s*$")
MARKDOWN_LINK_RE = re.compile(r"\[(?P<text>[^\]\n]*)\]\([^)\s]*(?:\s+\"[^\"]*\")?\)")
# `- [ ] 8. ...` / `- [x] 8. ...`: a checklist item and whether it is checked.
CHECKLIST_ITEM_RE = re.compile(r"^\s*-\s*\[(?P<mark>[ xX])\]\s*(?P<body>.*)$")


def normalized(text):
    """Lower-cased text with Markdown emphasis, code spans, and link syntax
    reduced to the words a reader sees, and whitespace collapsed.

    The rules below are about what the document says, not how it is marked up
    or wrapped, so bolding a prohibition or reflowing a paragraph must not fail
    them -- while deleting one still does."""
    plain = MARKDOWN_LINK_RE.sub(lambda match: match.group("text"), text)
    plain = plain.replace("*", "").replace("`", "")
    return " ".join(plain.lower().split())


def headings(text, level=2):
    """Every heading at `level`, in document order."""
    found = []
    for line in text.splitlines():
        match = HEADING_RE.match(line)
        if match and len(match.group("hashes")) == level:
            found.append(match.group("heading").strip())
    return found


def section(text, wanted, level=2):
    """The body beneath `wanted`, up to the next heading at or above its own
    level. Empty when the heading is absent, which is how a deleted section
    reaches the rules below."""
    collected = []
    active = False
    for line in text.splitlines():
        match = HEADING_RE.match(line)
        if match:
            depth = len(match.group("hashes"))
            if depth == level and match.group("heading").strip() == wanted:
                active = True
                continue
            if active and depth <= level:
                break
            continue
        if active:
            collected.append(line)
    return "\n".join(collected)


def bullet(text, heading, opening):
    """The one `- ` list item beneath `heading` whose first line contains
    `opening`, with its continuation lines joined. Empty when absent, which is
    how a deleted bullet reaches the rules above."""
    collected = []
    active = False
    for line in section(text, heading).splitlines():
        if line.startswith("- "):
            if active:
                break
            active = opening in line
            if not active:
                continue
        if active:
            collected.append(line)
    return "\n".join(collected)


def sentences(body):
    """`body`, already normalized, split into sentences. Crude on purpose: the
    rule that reads these is about which sentence carries a claim, and the
    documents it reads write plain declarative prose."""
    return [said.strip() for said in body.split(". ") if said.strip()]


def missing_rules(haystack, rules):
    """The rule names whose phrase is absent from `haystack`, which is already
    normalized. Sorted so a failure names the same gaps in the same order."""
    return sorted(name for name, phrase in rules.items() if phrase not in haystack)


def tag_immutability_gaps(text):
    """Requirement 4's prohibitions that the post-tag failure section does not
    state. Bound to that section rather than the whole document: a prohibition
    that survives only as an aside somewhere else is not the unambiguous
    response the requirement asks for."""
    return missing_rules(
        normalized(section(text, FAILURE_HEADING)), TAG_IMMUTABILITY_RULES
    )


def authorization_gaps(text):
    """Requirement 3's gate: a step of its own, ahead of the tag push, naming
    the comment that records it and denying that anything else substitutes."""
    gaps = missing_rules(
        normalized(section(text, AUTHORIZATION_HEADING)), AUTHORIZATION_RULES
    )
    present = headings(text)
    if AUTHORIZATION_HEADING not in present:
        gaps.append("own-step")
    elif TAG_HEADING not in present:
        gaps.append("tag-step")
    elif present.index(AUTHORIZATION_HEADING) > present.index(TAG_HEADING):
        gaps.append("precedes-tag")
    return sorted(gaps)


def evidence_gaps(text):
    """Requirement 5, in both halves: where the evidence goes, what the comment
    names, and the two places release records deliberately do not grow."""
    gaps = missing_rules(normalized(section(text, EVIDENCE_HEADING)), EVIDENCE_RULES)
    gaps += missing_rules(
        normalized(section(text, EVIDENCE_STEP_HEADING)), EVIDENCE_ITEMS
    )
    return sorted(gaps)


def candidate_identity_gaps(text):
    """The one-commit boundary every pre-tag gate is recorded against."""
    return missing_rules(normalized(section(text, CANDIDATE_HEADING)), CANDIDATE_RULES)


def upgrade_coverage_gaps(text):
    """What the single manual supported-host gate has to cover."""
    return missing_rules(normalized(section(text, UPGRADE_HEADING)), UPGRADE_ITEMS)


def doctor_claim_gaps(claim):
    """What one `kanban --doctor` claim gets wrong, if anything.

    Shared by both documents because it is one rule stated twice. A claim is
    sound when it says AI-action readiness, names no managed service, and
    quantifies over no set of components -- the third being what a claim
    reaches a managed service through when it declines to name one."""
    gaps = []
    if DOCTOR_SCOPE_RULE not in claim:
        gaps.append("doctor-scope")
    gaps += [
        f"doctor-covers:{word}" for word in CLAIMED_SERVICE_WORDS if word in claim
    ]
    if COMPONENT_QUANTIFIER_RE.search(claim):
        gaps.append("doctor-covers-every-component")
    return gaps


def doctor_claims(body):
    """Every `--doctor` claim in already-normalized `body`, in order. Every one
    of them is held to the rule: a document is free to mention doctor twice,
    and the second mention is exactly where a corrected first one grows a
    qualifier back."""
    return [match.group("claim") for match in DOCTOR_CLAIM_RE.finditer(body)]


def upgrade_service_readiness_gaps(text):
    """What the gate says about the managed jobs and about `--doctor`.

    Issue #618, in one predicate because the halves are one rule: the gate
    names the two managed jobs that exist, requires each one's own controller
    `status` and the `state` that status returned, and scopes every `--doctor`
    claim it makes. Drop any of those and a clean doctor run stands in for a
    service nothing observed.

    `absent-managed-service` reports a defect being present rather than a rule
    being absent, so it does not fire against an empty document. Its teeth are
    the control that plants the wrong name back."""
    body = normalized(section(text, UPGRADE_HEADING))
    gaps = missing_rules(body, MANAGED_SERVICE_NAMES)
    gaps += missing_rules(body, SERVICE_STATUS_RULES)
    if RETURNED_STATE_RULE not in body:
        gaps.append("returned-state")
    if NOT_AN_EXIT_CODE_RULE not in body:
        gaps.append("not-an-exit-code")
    if DOCTOR_SUBSTITUTION_RULE not in body:
        gaps.append("doctor-not-a-substitute")
    claims = doctor_claims(body)
    if not claims:
        gaps.append("doctor-claim")
    for claim in claims:
        gaps += doctor_claim_gaps(claim)
    if ABSENT_MANAGED_SERVICE in normalized(text):
        gaps.append("absent-managed-service")
    return sorted(set(gaps))


def support_doctor_scope_gaps(text):
    """What SUPPORT.md tells a reporter `kanban --doctor` covers.

    The bullet has to claim AI-action readiness, claim it for nothing else,
    attribute every other readiness it mentions to a controller's status, and
    send the reporter to each managed service's own controller for the other
    two. `doctor-claim` is the gap when the bullet makes no doctor claim at
    all, which is also how a deleted bullet reaches this rule."""
    body = normalized(bullet(text, SUPPORT_HEADING, SUPPORT_BULLET_OPENING))
    gaps = missing_rules(body, SUPPORT_CONTROLLER_RULES)
    claims = doctor_claims(body)
    if not claims:
        gaps.append("doctor-claim")
    for claim in claims:
        gaps += doctor_claim_gaps(claim)
    for said in sentences(body):
        if not READINESS_RE.search(said):
            continue
        if "--doctor" in said or CONTROLLER_OBSERVER in said:
            continue
        gaps.append("unattributed-readiness")
    return sorted(set(gaps))


def repository_setting_gaps(text):
    """The exact public metadata the settings step checks before
    authorization: the description verbatim, all eight topics, and an empty
    homepage."""
    body = normalized(section(text, SETTINGS_HEADING))
    gaps = []
    if normalized(REPOSITORY_DESCRIPTION) not in body:
        gaps.append("description")
    gaps += [f"topic:{topic}" for topic in REPOSITORY_TOPICS if topic not in body]
    if "homepage must be empty" not in body:
        gaps.append("empty-homepage")
    return sorted(gaps)


def dependency_review_gaps(text):
    """Requirement 8's subjects, cadences, lane, and recorded results."""
    return missing_rules(
        normalized(section(text, DEPENDENCY_HEADING)), DEPENDENCY_RULES
    )


def console_fences(text):
    """Every ```console fence body in `text`, in document order."""
    return [match.group("body") for match in CONSOLE_FENCE_RE.finditer(text)]


def fenced_commands(fence):
    """A fence's commands, with backslash continuations joined into one line."""
    joined = CONTINUATION_RE.sub(" ", fence)
    return [line.strip() for line in joined.splitlines() if line.strip()]


def run_selection_command(text):
    """The rehearsal step's fenced `gh run list` invocation.

    `None` when the step carries no such fenced command, or carries more than
    one: either way there is no single command for the rules below to be
    about, and two discovery commands are themselves the ambiguity the step
    exists to refuse.

    Read out of the fence deliberately. normalized() strips backticks, so a
    rule run over the section's prose is satisfied by a sentence that merely
    names the flags, while the command an operator runs is the one in the
    fence. The extraction is tools/test_finalize_workflow.py's, adapted to
    this document's `console` fences."""
    found = [
        command
        for fence in console_fences(section(text, REHEARSAL_HEADING))
        for command in fenced_commands(fence)
        if command.startswith("gh run list")
    ]
    return found[0] if len(found) == 1 else None


def requested_json_fields(command):
    """The field names `command` asks `--json` for."""
    match = JSON_FIELDS_RE.search(command)
    if match is None:
        return set()
    return {field for field in match.group(1).split(",") if field}


def run_selection_gaps(text):
    """The correlation, against the fenced command rather than the paragraph
    around it: the filters that bind the listing to this dispatch, the identity
    fields that make its row checkable, and the absence of the truncation that
    hid a second eligible run."""
    command = run_selection_command(text)
    if command is None:
        return list(NO_SELECTION_COMMAND_GAPS)
    gaps = [
        name
        for name, pattern in RUN_SELECTION_FILTERS.items()
        if not pattern.search(command)
    ]
    requested = requested_json_fields(command)
    gaps += [
        f"field:{field}" for field in RUN_SELECTION_FIELDS if field not in requested
    ]
    if LIMIT_FLAG_RE.search(command):
        gaps.append("no-limit-selection")
    return sorted(gaps)


def rehearsal_procedure_gaps(text):
    """The instructions that read the listing that command returns: wait for a
    row rather than dispatching again, stop on two rows, reject a row that
    fails a correlation check, and record which run was watched and why it was
    this rehearsal's. The redispatch remediation is a gap when it is present
    rather than when it is absent."""
    body = normalized(section(text, REHEARSAL_HEADING))
    gaps = missing_rules(body, REHEARSAL_PROCEDURE_RULES)
    if REDISPATCH_ON_MISMATCH_RE.search(body):
        gaps.append("no-mismatch-redispatch")
    return sorted(gaps)


def version_literals(text):
    """Dotted numeric runs the runbook must not contain (requirement 2)."""
    return sorted(set(VERSION_LITERAL_RE.findall(text)))


def checklist_items(text):
    """(checked, body) for every checklist item, in document order.

    An item's body runs to the next item or the next unindented line, because
    the interesting items are the ones long enough to wrap -- reading only the
    first line would let the sentence that makes an item a gate sit one line
    below the rule looking for it."""
    found = []
    collecting = None
    for line in text.splitlines():
        match = CHECKLIST_ITEM_RE.match(line)
        if match:
            collecting = [match.group("body")]
            found.append([match.group("mark") in "xX", collecting])
            continue
        if collecting is not None and line[:1].isspace() and line.strip():
            collecting.append(line.strip())
            continue
        collecting = None
    return [(checked, normalized(" ".join(body))) for checked, body in found]


def template_rehearsal_gaps(text):
    """The rehearsal item names the run it recorded and what that run was
    correlated on, so the release issue says which run was watched rather than
    that one was."""
    items = [
        body
        for _, body in checklist_items(text)
        if "rehearsal dispatched" in body
    ]
    if len(items) != 1:
        return sorted(["rehearsal-item"] + list(TEMPLATE_REHEARSAL_RULES))
    return missing_rules(items[0], TEMPLATE_REHEARSAL_RULES)


def template_authorization_gaps(text):
    """The template's half of requirement 3: the authorization is an item of
    its own, it arrives unchecked, it names the comment that satisfies it, and
    it sits ahead of the tag item. A pre-checked box is the interesting
    failure -- it ships a release issue whose gate is already satisfied."""
    items = checklist_items(text)
    authorization = [
        (index, checked, body)
        for index, (checked, body) in enumerate(items)
        if "publication authorized" in body
    ]
    tag = [
        index
        for index, (_, body) in enumerate(items)
        if "tag created on the authorized commit" in body
    ]
    gaps = []
    if not authorization:
        return ["authorization-item"]
    if len(authorization) > 1:
        gaps.append("one-authorization-item")
    index, checked, body = authorization[0]
    if checked:
        gaps.append("starts-unchecked")
    if "authorized: publish <version> from <commit>." not in body:
        gaps.append("names-the-comment")
    if "no agent may check this item" not in body:
        gaps.append("not-an-agent")
    if not tag:
        gaps.append("tag-item")
    elif index > tag[0]:
        gaps.append("precedes-tag")
    return sorted(gaps)


class ReleaseRunbookTests(unittest.TestCase):
    """The live document satisfies every rule."""

    @classmethod
    def setUpClass(cls):
        cls.text = RUNBOOK.read_text(encoding="utf-8")

    def test_the_procedure_states_its_steps_in_order(self):
        self.assertEqual(
            [
                heading
                for heading in headings(self.text)
                if heading in PROCEDURE_HEADINGS
            ],
            list(PROCEDURE_HEADINGS),
        )

    def test_the_runbook_is_version_neutral(self):
        self.assertEqual(
            version_literals(self.text),
            [],
            "the runbook spells every version `<version>`; a literal is either "
            "one release's number or evidence from it",
        )

    def test_the_candidate_is_one_commit_carrying_the_required_check(self):
        self.assertEqual(candidate_identity_gaps(self.text), [])

    def test_the_manual_upgrade_gate_states_what_it_covers(self):
        self.assertEqual(upgrade_coverage_gaps(self.text), [])

    def test_the_manual_upgrade_gate_observes_both_managed_services(self):
        self.assertEqual(upgrade_service_readiness_gaps(self.text), [])

    def test_the_settings_step_names_the_exact_repository_state(self):
        self.assertEqual(repository_setting_gaps(self.text), [])

    def test_the_authorization_is_a_recorded_step_before_the_tag_push(self):
        self.assertEqual(authorization_gaps(self.text), [])

    def test_the_pushed_tag_is_immutable(self):
        self.assertEqual(tag_immutability_gaps(self.text), [])

    def test_release_evidence_lives_on_the_release_issue(self):
        self.assertEqual(evidence_gaps(self.text), [])

    def test_the_dependency_review_is_specified_and_recorded(self):
        self.assertEqual(dependency_review_gaps(self.text), [])

    def test_the_rehearsal_selects_the_run_its_own_dispatch_created(self):
        self.assertEqual(run_selection_gaps(self.text), [])

    def test_the_rehearsal_waits_for_its_run_instead_of_dispatching_again(self):
        self.assertEqual(rehearsal_procedure_gaps(self.text), [])


class RunbookRuleControlTests(unittest.TestCase):
    """The negative controls. Each removes or inverts exactly the sentence its
    rule is about, and asserts the rule names that gap -- so a rule cannot pass
    by matching everything, and deleting a safety statement from the runbook
    cannot pass by matching nothing."""

    @classmethod
    def setUpClass(cls):
        cls.text = RUNBOOK.read_text(encoding="utf-8")

    def without(self, phrase, replacement=""):
        """The runbook with one passage replaced, asserting that exactly one
        passage was there to replace: a control that silently matched nothing
        would make its own assertion vacuous.

        Words are matched across any run of whitespace, and case-insensitively,
        because the passages below are prose: reflowing a paragraph, or naming
        a rule the way the normalized rule spells it, must not turn a control
        into a false alarm about a rule that is still stated."""
        pattern = re.compile(
            r"\s+".join(re.escape(word) for word in phrase.split()), re.IGNORECASE
        )
        planted, replaced = pattern.subn(replacement, self.text)
        self.assertEqual(
            replaced, 1, f"the passage this control removes moved: {phrase!r}"
        )
        return planted

    def replacing(self, block, replacement):
        """The runbook with one literal block substituted, asserting the block
        was there. Literal rather than `without`'s whitespace-tolerant match,
        because these blocks are fenced commands: their line breaks and
        continuations are the thing being changed, and a `\\` in one is an
        escape to `re.sub`'s replacement template rather than a character."""
        self.assertIn(block, self.text, "the block this control replaces moved")
        return self.text.replace(block, replacement)

    def test_deleting_a_tag_prohibition_is_reported(self):
        planted = self.without("- **Do not delete the tag.**", "- Fix it.")
        self.assertEqual(tag_immutability_gaps(planted), ["delete"])

    def test_deleting_the_whole_failure_section_is_reported(self):
        planted = self.text.replace(
            f"## {FAILURE_HEADING}", "## Recovering from a bad release"
        )
        self.assertEqual(
            tag_immutability_gaps(planted), sorted(TAG_IMMUTABILITY_RULES)
        )

    def test_deleting_the_authorization_step_is_reported(self):
        planted = self.text.replace(f"## {AUTHORIZATION_HEADING}", "## Notes")
        self.assertEqual(
            authorization_gaps(planted),
            sorted(list(AUTHORIZATION_RULES) + ["own-step"]),
        )

    def test_an_authorization_after_the_tag_push_is_reported(self):
        # Reordering alone, with every sentence intact: an authorization the
        # tag step has already passed is not a gate.
        start = self.text.index(f"## {AUTHORIZATION_HEADING}")
        middle = self.text.index(f"## {TAG_HEADING}")
        end = self.text.index(f"## {OBSERVE_HEADING}")
        self.assertLess(start, middle, "the two steps are not adjacent")
        planted = (
            self.text[:start]
            + self.text[middle:end]
            + self.text[start:middle]
            + self.text[end:]
        )
        self.assertEqual(authorization_gaps(planted), ["precedes-tag"])

    def test_an_authorization_with_no_recorded_comment_is_reported(self):
        planted = self.without(
            "Authorized: publish <version> from <commit>.",
            "The maintainer is happy with it.",
        )
        self.assertEqual(authorization_gaps(planted), ["recorded-comment"])

    def test_an_authorization_anything_can_satisfy_is_reported(self):
        planted = self.without(
            "no other step implies it",
            "the checklist above generally covers it",
        )
        self.assertEqual(authorization_gaps(planted), ["not-implied"])

    def test_evidence_moving_into_a_tracked_document_is_reported(self):
        planted = self.without(
            "No permanent per-release Markdown file is created",
            "Each release adds a subsection to the design document",
        )
        self.assertEqual(evidence_gaps(planted), ["no-markdown-file"])

    def test_an_evidence_comment_missing_an_item_is_reported(self):
        planted = self.without("- the published asset's name and its `sha256` digest;\n")
        self.assertEqual(evidence_gaps(planted), ["digest"])

    def test_a_version_literal_is_reported(self):
        planted = self.without("git tag -a v<version>", "git tag -a v1.1.0.0")
        self.assertEqual(version_literals(planted), ["1.1.0.0"])

    def test_a_candidate_that_need_not_carry_the_check_is_reported(self):
        planted = self.without(
            "required `build-test` job reports\n`success` for that exact commit",
            "pipeline is generally green",
        )
        self.assertEqual(candidate_identity_gaps(planted), ["required-check"])

    def test_an_upgrade_gate_missing_a_covered_item_is_reported(self):
        # Re-anchored to the corrected doctor item (issue #618): the control
        # that used to remove the false "every advertised component ready"
        # sentence was coupled to wording the gate no longer carries, so it
        # would have gone vacuous the moment the claim was fixed.
        planted = self.without(
            "- `kanban --doctor`, reporting AI-action readiness; that is the "
            "whole of what it reports, so it does not stand in for either "
            "service check below;\n"
        )
        self.assertEqual(upgrade_coverage_gaps(planted), ["doctor"])

    def test_a_gate_naming_a_managed_service_that_does_not_exist_is_reported(self):
        # The incorrect service name on its own: both real jobs are still
        # named by the two status items below, so nothing but the wrong name
        # is reported.
        planted = self.without(
            "the PR drainer and the issue approval service",
            "the issue-review service and the PR drainer",
        )
        self.assertEqual(
            upgrade_service_readiness_gaps(planted), ["absent-managed-service"]
        )

    def test_a_doctor_item_claiming_every_component_is_reported(self):
        # The false claim, in the wording the gate carried and in two that mean
        # the same thing. Each is planted into an item that still says
        # `AI-action readiness` and still denies substituting, so what is
        # reported is the claim alone -- and a rule keyed to the one historical
        # sentence would pass the other two, which is how the first attempt at
        # this rule failed its canonical review.
        equivalents = (
            "every advertised component ready",
            "all optional-component readiness",
            "which of them are ready",
        )
        for claim in equivalents:
            with self.subTest(claim=claim):
                planted = self.without(
                    "reporting AI-action readiness;",
                    f"reporting AI-action readiness and {claim};",
                )
                self.assertEqual(
                    upgrade_service_readiness_gaps(planted),
                    ["doctor-covers-every-component"],
                )

    def test_a_doctor_item_naming_a_managed_service_is_reported(self):
        # The other way a claim reaches a managed job: naming one outright.
        planted = self.without(
            "reporting AI-action readiness;",
            "reporting AI-action readiness and the PR drainer's;",
        )
        self.assertEqual(
            upgrade_service_readiness_gaps(planted), ["doctor-covers:drainer"]
        )

    def test_a_doctor_item_with_no_readable_claim_is_reported(self):
        # The rule reads a claim rather than a sentence containing the right
        # words, so an item that states none is reported rather than passing
        # for lack of anything to disagree with.
        planted = self.without(
            "`kanban --doctor`, reporting AI-action readiness;",
            "`kanban --doctor`, which covers what it covers;",
        )
        self.assertEqual(upgrade_service_readiness_gaps(planted), ["doctor-claim"])

    def test_a_doctor_item_that_does_not_scope_itself_is_reported(self):
        planted = self.without(
            "reporting AI-action readiness;", "reporting what it reports;"
        )
        self.assertEqual(upgrade_service_readiness_gaps(planted), ["doctor-scope"])

    def test_a_doctor_item_that_may_substitute_for_a_service_is_reported(self):
        planted = self.without(
            "so it does not stand in for either service check below",
            "so read it alongside the checks below",
        )
        self.assertEqual(
            upgrade_service_readiness_gaps(planted), ["doctor-not-a-substitute"]
        )

    def test_dropping_one_service_status_check_is_reported(self):
        # One control per managed job, each keeping the other check and the
        # correctly scoped doctor item: a rule reporting "the services are
        # covered" as one bit could not name which one went.
        controls = {
            "drainer-status": "- the PR drainer's controller `status`, for every "
            "repository the drainer's own\n  record named;\n",
            "approval-status": "- the issue approval service's controller `status`, "
            "for every repository its own\n  record named;\n",
        }
        for gap, item in controls.items():
            with self.subTest(check=gap):
                planted = self.without(item)
                self.assertEqual(upgrade_service_readiness_gaps(planted), [gap])

    def test_a_gate_that_only_mentions_doctor_is_reported(self):
        # Requirement 4's headline control: with both service checks gone the
        # gate still contains `--doctor`, still scopes it correctly, and still
        # names both managed jobs -- so upgrade_coverage_gaps is satisfied and
        # nothing about a substring of the gate says either service was
        # observed.
        planted = self.without(
            "- the PR drainer's controller `status`, for every repository the "
            "drainer's own\n  record named;\n"
        )
        planted = planted.replace(
            "- the issue approval service's controller `status`, for every "
            "repository its own\n  record named;\n",
            "",
        )
        self.assertEqual(upgrade_coverage_gaps(planted), [])
        self.assertEqual(
            upgrade_service_readiness_gaps(planted),
            ["approval-status", "drainer-status"],
        )

    def test_a_status_result_read_as_an_exit_code_is_reported(self):
        planted = self.without(
            "not that the\ncommand exited zero", "and the command exited zero"
        )
        self.assertEqual(upgrade_service_readiness_gaps(planted), ["not-an-exit-code"])

    def test_a_gate_that_never_asks_for_the_returned_state_is_reported(self):
        # The positive half, dropped while the prohibition stands: an operator
        # told only what a result is *not* has been told nothing to record.
        planted = self.without(
            "is the `state` the controller returned, not that the",
            "is not that the",
        )
        self.assertEqual(upgrade_service_readiness_gaps(planted), ["returned-state"])

    def test_a_drifted_repository_description_is_reported(self):
        planted = self.without(
            REPOSITORY_DESCRIPTION, "A terminal board for GitHub."
        )
        self.assertEqual(repository_setting_gaps(planted), ["description"])

    def test_a_dropped_repository_topic_is_reported(self):
        planted = self.without("`developer-tools`, ", "")
        self.assertEqual(repository_setting_gaps(planted), ["topic:developer-tools"])

    def test_a_dependency_review_missing_a_subject_is_reported(self):
        planted = self.without("**`cabal outdated`.**", "**Everything else.**")
        self.assertEqual(dependency_review_gaps(planted), ["cabal-outdated"])

    def test_a_clean_off_cycle_review_with_nowhere_to_go_is_reported(self):
        planted = self.without("dependency-review issue", "conversation")
        self.assertEqual(dependency_review_gaps(planted), ["record-off-cycle"])

    def test_dropping_a_correlation_filter_is_reported(self):
        # One control per filter, each naming the filter it dropped: a rule
        # that reported "correlated" as one bit could not do this.
        for name, phrase in FILTER_CONTROL_PHRASES.items():
            with self.subTest(filter=name):
                self.assertIn(phrase, SELECTION_COMMAND)
                weakened = SELECTION_COMMAND.replace(phrase, "")
                planted = self.replacing(
                    SELECTION_FENCE, f"```console\n{weakened}\n```"
                )
                self.assertEqual(run_selection_gaps(planted), [name])

    def test_a_selection_command_missing_an_identity_field_is_reported(self):
        planted = self.without(
            "--json databaseId,headBranch,headSha,createdAt,status,conclusion,url",
            "--json databaseId,headSha,createdAt,status,conclusion,url",
        )
        self.assertEqual(run_selection_gaps(planted), ["field:headBranch"])

    def test_the_repository_wide_newest_first_selection_is_reported(self):
        # The defect itself, restored: a `Release` dispatch chosen by recency
        # across the whole repository, checked for its commit only afterwards.
        self.assertEqual(
            run_selection_gaps(self.replacing(SELECTION_FENCE, UNCORRELATED_FENCE)),
            UNCORRELATED_SELECTION_GAPS,
        )

    def test_naming_the_filters_in_prose_alone_is_reported(self):
        # The failure the fence extraction exists for: the paragraph says
        # everything the rule asks for, and the command an operator runs still
        # selects whichever run is newest.
        planted = self.replacing(SELECTION_FENCE, UNCORRELATED_FENCE).replace(
            "Read that listing before watching anything:",
            "Scope it with `--branch release-candidate-<n>`, `--commit <commit>`, "
            'and `--created ">=<dispatched-after>"`, requesting `databaseId`, '
            "`headBranch`, `headSha`, `createdAt`, and `url`.\n\n"
            "Read that listing before watching anything:",
        )
        self.assertEqual(run_selection_gaps(planted), UNCORRELATED_SELECTION_GAPS)

    def test_a_rehearsal_with_no_fenced_selection_command_is_reported(self):
        # The command deleted outright: prose describing a query nobody can
        # run satisfies nothing.
        self.assertEqual(
            run_selection_gaps(self.replacing(SELECTION_FENCE, "")),
            NO_SELECTION_COMMAND_GAPS,
        )

    def test_two_fenced_selection_commands_are_reported(self):
        # Two discovery commands are two answers to one question, and no rule
        # can say which of them the operator ran.
        planted = self.replacing(
            SELECTION_FENCE,
            f"```console\n{SELECTION_COMMAND}\n{SELECTION_COMMAND}\n```",
        )
        self.assertEqual(run_selection_gaps(planted), NO_SELECTION_COMMAND_GAPS)

    def test_dispatching_again_on_a_listing_that_has_not_caught_up_is_reported(self):
        planted = self.without("Do not dispatch again", "Dispatch it again")
        self.assertEqual(rehearsal_procedure_gaps(planted), ["wait-not-redispatch"])

    def test_a_mismatch_that_sends_the_operator_back_to_dispatch_is_reported(self):
        # The remediation this step replaced: a row that fails a correlation
        # check used to mean re-push and dispatch again, which is how ordinary
        # listing lag produced a duplicate run.
        planted = self.without(
            "Reject it and keep querying rather than watching it.",
            "Anything else is a rehearsal of some other tree: delete the "
            "scratch branch, re-push it at the candidate, and dispatch again.",
        )
        self.assertEqual(
            rehearsal_procedure_gaps(planted),
            ["keep-querying", "no-mismatch-redispatch"],
        )

    def test_a_rehearsal_record_naming_no_run_is_reported(self):
        planted = self.without("its `url` or `databaseId`,", "it,")
        self.assertEqual(rehearsal_procedure_gaps(planted), ["record-run-identity"])

    def test_a_rehearsal_record_naming_no_correlation_is_reported(self):
        planted = self.without(
            "together with the scratch branch and the candidate commit it was "
            "correlated on,",
            "",
        )
        self.assertEqual(rehearsal_procedure_gaps(planted), ["record-correlation"])

    def test_a_listing_with_two_rows_that_picks_one_is_reported(self):
        planted = self.without(
            "and newest-first is not a tiebreak", "so take the newest"
        )
        self.assertEqual(rehearsal_procedure_gaps(planted), ["ambiguous-listing"])

    def test_a_rule_set_is_not_vacuous_against_an_empty_document(self):
        # The blanket control: every rule reports every gap when there is no
        # document at all, so none of them can pass by finding nothing.
        for gaps, rules in (
            (tag_immutability_gaps(""), TAG_IMMUTABILITY_RULES),
            (candidate_identity_gaps(""), CANDIDATE_RULES),
            (upgrade_coverage_gaps(""), UPGRADE_ITEMS),
            (dependency_review_gaps(""), DEPENDENCY_RULES),
            (rehearsal_procedure_gaps(""), REHEARSAL_PROCEDURE_RULES),
        ):
            with self.subTest(rules=sorted(rules)):
                self.assertEqual(gaps, sorted(rules))
        self.assertEqual(
            evidence_gaps(""), sorted(list(EVIDENCE_RULES) + list(EVIDENCE_ITEMS))
        )
        self.assertEqual(
            authorization_gaps(""),
            sorted(list(AUTHORIZATION_RULES) + ["own-step"]),
        )
        self.assertEqual(repository_setting_gaps(""), sorted(
            ["description", "empty-homepage"]
            + [f"topic:{topic}" for topic in REPOSITORY_TOPICS]
        ))
        self.assertEqual(run_selection_gaps(""), NO_SELECTION_COMMAND_GAPS)
        # `absent-managed-service` reports a defect being present, so an empty
        # document leaves it silent by construction -- its control above is
        # what shows it non-vacuous. The claim rules report `doctor-claim`
        # here for the same reason: there is no claim to read.
        self.assertEqual(
            upgrade_service_readiness_gaps(""),
            sorted(
                list(MANAGED_SERVICE_NAMES)
                + list(SERVICE_STATUS_RULES)
                + [
                    "doctor-claim",
                    "doctor-not-a-substitute",
                    "not-an-exit-code",
                    "returned-state",
                ]
            ),
        )


class MaintainerReleaseTemplateTests(unittest.TestCase):
    """The template's authorization gate -- unchecked, its own item, naming the
    comment that satisfies it, and ahead of the tag item -- and its rehearsal
    item, which records which run was watched."""

    @classmethod
    def setUpClass(cls):
        # The directory, not the file: a checkout missing the template is a
        # regression tools/test_issue_templates.py reports, and skipping on the
        # file would hide it. Absent altogether is the packaged state -- see
        # this module's docstring.
        if not TEMPLATE_DIR.is_dir():
            raise unittest.SkipTest(f"{TEMPLATE_DIR} is absent (not a Git checkout)")
        cls.text = RELEASE_TEMPLATE.read_text(encoding="utf-8")

    def test_the_template_authorization_gate_is_intact(self):
        self.assertEqual(template_authorization_gaps(self.text), [])

    def test_a_pre_satisfied_authorization_is_reported(self):
        # The failure that would ship a release issue whose gate is already
        # met: the box arrives checked.
        planted = self.text.replace(
            "- [ ] 8. **Publication authorized.**",
            "- [x] 8. **Publication authorized.**",
        )
        self.assertNotEqual(planted, self.text, "the authorization item moved")
        self.assertEqual(template_authorization_gaps(planted), ["starts-unchecked"])

    def test_a_missing_authorization_item_is_reported(self):
        planted = re.sub(
            r"^- \[ \] 8\. \*\*Publication authorized\.\*\*.*?(?=^- \[ \] 9\.)",
            "",
            self.text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertNotEqual(planted, self.text, "the authorization item moved")
        self.assertEqual(template_authorization_gaps(planted), ["authorization-item"])

    def test_an_authorization_after_the_tag_item_is_reported(self):
        items = checklist_items(self.text)
        authorization = next(
            index for index, (_, body) in enumerate(items)
            if "publication authorized" in body
        )
        tag = next(
            index for index, (_, body) in enumerate(items)
            if "tag created on the authorized commit" in body
        )
        self.assertLess(authorization, tag)
        lines = self.text.splitlines(keepends=True)
        starts = [
            number
            for number, line in enumerate(lines)
            if CHECKLIST_ITEM_RE.match(line)
        ]
        block = lines[starts[authorization] : starts[authorization + 1]]
        rest = lines[: starts[authorization]] + lines[starts[authorization + 1] :]
        moved = rest[: starts[tag]] + block + rest[starts[tag] :]
        self.assertEqual(
            template_authorization_gaps("".join(moved)), ["precedes-tag"]
        )

    def test_an_authorization_naming_no_comment_is_reported(self):
        planted = self.text.replace(
            "`Authorized: publish <version> from <commit>.`", "approved verbally"
        )
        self.assertNotEqual(planted, self.text, "the authorization comment moved")
        self.assertEqual(template_authorization_gaps(planted), ["names-the-comment"])

    def test_the_rehearsal_item_records_the_run_it_was_correlated_on(self):
        self.assertEqual(template_rehearsal_gaps(self.text), [])

    def test_a_rehearsal_item_recording_no_correlation_is_reported(self):
        planted = self.text.replace(
            "together\n      with the branch and commit it was correlated on;", ";"
        )
        self.assertNotEqual(planted, self.text, "the rehearsal item moved")
        self.assertEqual(template_rehearsal_gaps(planted), ["correlation"])

    def test_a_missing_rehearsal_item_is_reported(self):
        # The blanket control for this rule: no item, every gap.
        self.assertEqual(
            template_rehearsal_gaps(""),
            sorted(["rehearsal-item"] + list(TEMPLATE_REHEARSAL_RULES)),
        )

    def test_the_template_points_at_the_runbook_for_the_procedure(self):
        # Requirement 7's boundary: the template drives the procedure, it does
        # not restate it. A second copy of the steps is what would drift.
        self.assertIn("docs/releasing.md", self.text)


class SupportDocumentTests(unittest.TestCase):
    """SUPPORT.md's report-what-you-have-installed bullet, and the controls
    that show its rules are not vacuous.

    `SUPPORT.md` is a packaged root document, so this class needs no skip: it
    is present in a Git checkout and in an unpacked release alike."""

    @classmethod
    def setUpClass(cls):
        cls.text = SUPPORT.read_text(encoding="utf-8")

    def without(self, phrase, replacement=""):
        """SUPPORT.md with one passage replaced, asserting exactly one passage
        was there to replace. The runbook class's helper, over this
        document."""
        pattern = re.compile(
            r"\s+".join(re.escape(word) for word in phrase.split()), re.IGNORECASE
        )
        planted, replaced = pattern.subn(replacement, self.text)
        self.assertEqual(
            replaced, 1, f"the passage this control removes moved: {phrase!r}"
        )
        return planted

    def test_the_installed_components_bullet_scopes_doctor_correctly(self):
        self.assertEqual(support_doctor_scope_gaps(self.text), [])

    def test_the_bullet_that_gave_doctor_the_whole_roster_is_reported(self):
        # The wording this document actually carried, planted back verbatim.
        # The claim is anaphoric -- "which of them" is the three-component list
        # in the clause before it -- so what catches it is that it quantifies
        # over the components instead of naming one, and the controller
        # directions go with it.
        planted = self.without(
            "installed separately, and no single\n  check covers all three. "
            "`kanban --doctor` reports AI-action readiness and\n  nothing else. "
            "For the other two, run each managed service's own controller\n"
            "  `status` and say what state it returned — the\n"
            "  [PR drainer's controller status](docs/pr-drainer.md#manual-status) "
            "and the\n  [issue approval service's controller "
            "status](docs/issue-approval.md#reading-status).",
            "installed separately;\n  `kanban --doctor` reports which of them "
            "are ready on your machine.",
        )
        self.assertEqual(
            support_doctor_scope_gaps(planted),
            [
                "approval-controller",
                "doctor-covers-every-component",
                "doctor-scope",
                "drainer-controller",
            ],
        )

    def test_a_doctor_claim_naming_a_managed_service_is_reported(self):
        # The explicit form of the same defect, with the controller directions
        # left standing: only the claim is wrong, and only the claim is
        # reported -- once per service it names.
        planted = self.without(
            "`kanban --doctor` reports AI-action readiness and\n  nothing else.",
            "`kanban --doctor` reports whether the PR drainer and the issue "
            "approval service are ready.",
        )
        self.assertEqual(
            support_doctor_scope_gaps(planted),
            [
                "doctor-covers:approval service",
                "doctor-covers:drainer",
                "doctor-scope",
            ],
        )

    def test_a_doctor_claim_that_quantifies_over_the_components_is_reported(self):
        # The scope words kept, a quantifier added: the bullet still says
        # AI-action readiness and still names both controllers, and the claim
        # still hands the other two components back.
        planted = self.without(
            "reports AI-action readiness and\n  nothing else.",
            "reports AI-action readiness and which of them are ready.",
        )
        self.assertEqual(
            support_doctor_scope_gaps(planted), ["doctor-covers-every-component"]
        )

    def test_a_later_sentence_reassigning_readiness_is_reported(self):
        # The hole a clause-level rule cannot see: the doctor sentence is left
        # exactly as it stands, correct in isolation, and a sentence after it
        # gives the two managed services back without naming doctor again.
        planted = self.without(
            "nothing else. For the other two,",
            "nothing else. It also reports whether the PR drainer and the "
            "issue approval service are ready. For the other two,",
        )
        self.assertEqual(
            support_doctor_scope_gaps(planted), ["unattributed-readiness"]
        )

    def test_dropping_one_controller_direction_is_reported(self):
        controls = {
            "drainer-controller": (
                "the\n  [PR drainer's controller "
                "status](docs/pr-drainer.md#manual-status) and ",
                "",
            ),
            "approval-controller": (
                " and the\n  [issue approval service's controller "
                "status](docs/issue-approval.md#reading-status)",
                "",
            ),
        }
        for gap, (phrase, replacement) in controls.items():
            with self.subTest(direction=gap):
                planted = self.without(phrase, replacement)
                self.assertEqual(support_doctor_scope_gaps(planted), [gap])

    def test_a_bullet_that_says_nothing_about_doctor_is_reported(self):
        # The blanket control: no bullet, no claim to read, every gap. The
        # readiness sweep reports a defect being present, so it is silent
        # here -- the control above is what shows it non-vacuous.
        self.assertEqual(
            support_doctor_scope_gaps(""),
            sorted(list(SUPPORT_CONTROLLER_RULES) + ["doctor-claim"]),
        )


if __name__ == "__main__":
    unittest.main()
