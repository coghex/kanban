# Project Review Findings: PRs #463–#455

A senior review of the three merged pull requests that landed after the batch
`docs/project_review_456-446.md` covered, taken newest-first over `coghex/kanban`:
#463 (per-entry witnesses for `docs/design.md` §3 and §20), #456 (the
pull-request template), and #455 (the issue templates). Each was judged against
the issue it claimed to satisfy, its commits, and the code at HEAD
(`4b5c5da`), and each issue was judged as a proposed specification in its own
right rather than as unquestioned authority.

No direct-to-`master` first-parent commits landed inside this interval; every
commit in it is PR-owned.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [ ] PRR-1. The pull-request template's marker-absence rule is verified once, by hand, and held by nothing

## 1. Acceptance that cannot fail a later wrong implementation

### PRR-1. The pull-request template's marker-absence rule is verified once, by hand, and held by nothing

> **Captured note:** PR #456 added `.github/pull_request_template.md`, whose
> explanatory comment describes the `pr-origin` marker's three rules while
> deliberately containing no marker-shaped sequence — because
> `Kanban.PullRequestFlow.originFromBody` counts occurrences anywhere in the
> body, so one literal marker inside that comment would make every agent-opened
> pull request a duplicate-marker body. Issue #435 made that a requirement
> (requirement 3) and made it mechanically checkable, but its acceptance
> discharged it with a one-shot `grep -c` and a `cabal repl` reading of the
> committed file, recorded in the pull request body. Nothing in the tree checks
> it now. Its sibling #455, merged 18 minutes earlier, gave the *issue*
> templates exactly the durable check this one lacks.

**Verification:** Confirmed at HEAD by static trace and by search. The template
is currently correct — `grep -c -- '<!-- pr-origin:' .github/pull_request_template.md`
prints `0` — so this is a missing regression check, not present breakage. A
search of the whole tree for readers of the file returns two hits, both in
`tools/test_source_distribution.py`, and both about whether the file *ships*;
no test in `test/` or `tools/` runs `originFromBody`, a coordinator's
`origin_from_body`, or any equivalent against the template's text.

**Evidence:**

- `src/Kanban/PullRequestFlow.hs:62-74` — `originFromBody` decides from
  `occurrenceCount` over the whole body: `codexCount > 1 || claudeCount > 1`
  returns `Left "PR body contains a duplicate pr-origin marker"`, and
  `codexCount > 0 && claudeCount > 0` returns `Left "PR body contains both
  pr-origin markers"`. Neither branch cares that the extra occurrence sits
  inside an HTML comment.
- `.github/pull_request_template.md:19-44` — the ORIGIN COMMENT states rule 2
  itself ("writing it out a second time, in prose or inside a comment such as
  this one, reads as a duplicate and routing fails just the same. That is why
  this comment describes the marker rather than showing it"). The rule is
  documented in the very file that would break it, and enforced nowhere.
- `tools/test_issue_templates.py:261-289` — the sibling contract for
  `.github/ISSUE_TEMPLATE/`: `test_no_template_declares_an_origin` runs
  `approve_issues.issue_origin` against each complete template file, and
  `test_the_origin_rule_would_catch_a_marked_template` is its negative control,
  appending `<!-- issue-origin:claude -->` and requiring the rule to report
  `claude`. Its module docstring (`:12-20`) names the exact hazard — "A template
  that spelled the marker while explaining it would mark every issue filed from
  it, or refuse them all" — and says the check is `issue_origin` itself "run
  against the complete template file, rather than a regex restated in this
  module".
- `grep -rn 'pull_request_template' test/ tools/ src/` → only
  `tools/test_source_distribution.py:46` (a docstring) and `:126` (the shipped-
  path tuple). No behavioral reader.

**Handoff context:**

- **Current behavior:** The pull-request template's freedom from a literal
  `pr-origin` marker is an invariant the file's own prose relies on, verified
  once by hand in PR #456 and asserted by no committed check. An editor who
  pastes a marker into the explanatory comment to show a contributor what it
  looks like — the exact mistake that comment warns against — turns every
  agent-authored pull request opened from the template into a duplicate-marker
  body. `originFromBody` then returns `Left`, the origin goes unknown, and the
  canonical coordinator routes the review to both brands, which reaches the
  self-review hazard by another door. Required CI stays green throughout.
- **Expected behavior:** A committed check fails when
  `.github/pull_request_template.md` contains a `pr-origin` marker in any
  position, comments included, and it is the real parser rather than a regex
  restated in the test. A negative control proves that check can distinguish a
  marked template from an unmarked one, so it cannot pass while asserting
  nothing.
- **Scope and constraints:** One test module or one added case; no change to
  `originFromBody`, its callers, or the dual-review fallback — issue #435 put
  all three explicitly out of scope and there is no reason to reopen them. The
  natural home is beside the existing coverage: either a case in
  `test/Spec/Agent/PullRequestFlow.hs` reading the tracked template and
  requiring `Left "PR body has no valid pr-origin marker"`, or a Python module
  mirroring `tools/test_issue_templates.py` against the two packaged
  coordinators' `origin_from_body`. Issue #435's own acceptance names both
  routes; what it did not do is require the result to be committed. Whichever is
  chosen must reach a required CI job.
- **Verification target:** With the check in place, appending
  `<!-- pr-origin:claude -->` to `.github/pull_request_template.md` turns the
  owning suite red, and removing it turns the suite green again — the same
  by-hand demonstration `tools/test_issue_templates.py`'s negative control
  automates for the issue side.
- **Deduplication:** No open issue covers it. `gh issue list -R coghex/kanban
  --state open --limit 300` returns nothing matching template, origin, or
  marker; `--search "pull_request_template" --state all` returns only the closed
  #435, and `--search "pr-origin template" --state all` returns #435, #434,
  #432, #384, #118 and #61, all closed and none about durable coverage of the
  template.
- **Remaining uncertainty:** None about the gap. The choice between the Haskell
  and Python homes is a judgement for the fix: the Haskell route holds the
  template against the parser Kanban's own board uses, while the Python route
  additionally covers the two packaged coordinators that route reviews. Holding
  it against all three is what PR #456's own by-hand evidence table did, so
  reproducing that table as a committed check is the fullest reading.
