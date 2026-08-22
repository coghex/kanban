# Project Review Findings: PRs #442–#411

This review continued below the completed #446 cursor and covered the next
twelve merged pull requests by merge time: #442, #441, #440, #439, #436,
#433, #426, #419, #416, #415, #413, and #411. It also reviewed all 29 direct
first-parent documentation commits interleaved between #446 and #411, from
`b35c0e1` through `5a61099`: `b35c0e1`, `90e28c5`, `cab55e0`, `51ce039`,
`f8d0772`, `2a0f968`, `74dd6aa`, `d8c3938`, `f84fb67`, `40f39a8`,
`48b7746`, `46c937f`, `26f7d80`, `c88506a`, `25b87cd`, `dd1515d`,
`cb6529e`, `ec8bb1b`, `656d8ca`, `3d522ae`, `1c21dfb`, `6eacc2c`,
`cf66fac`, `6d373e7`, `73b56ee`, `3fd7078`, `13a3c6d`, `5f44bd7`, and
`5a61099`. Each pull request was checked against its linked issue, landed diff,
commits, current implementation, callers, and current tests; each direct commit
was checked individually against its patch and current document state. Later
descendants were read only to establish whether a mistake still exists. This
report preserves the two confirmed current mistakes that still need
one-at-a-time disposition.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [ ] PRR-1. Retriage silently truncates the tracker snapshot it calls exhaustive
- [ ] PRR-2. The approval sidebar control is absent from the Unreleased notes

## 1. Retriage snapshot completeness

### PRR-1. Retriage silently truncates the tracker snapshot it calls exhaustive

> **Captured note:** Replace PR #442's finite issue and pull-request listing
> caps with an exhaustive repository-scoped read, so retriage cannot silently
> omit open work while claiming that every current open issue was classified.

**Verification:** Static tracing confirms a reachable contradiction in the
current shipped workflow. The issue snapshot requests at most 500 items and
the pull-request snapshot at most 100; the installed `gh` help defines
`--limit` as the maximum number fetched. The workflow then computes its current
set solely from those results and requires every current open issue to appear
exactly once. A repository with 501 open issues therefore drops at least one
issue without a diagnostic, while a repository with 101 open pull requests can
miss an in-flight `Closes #N` signal and present that issue as available. The
canonical source and both rendered assets carry the caps, and
`python3 tools/render_command_sources.py --check` confirms they are the current
shipped renderings.

**Evidence:**

- `tools/command_sources/retriage.md:74` — the workflow says it is pulling the
  current open issue set.
- `tools/command_sources/retriage.md:77` — that read uses `--limit 500`, an
  upper bound rather than pagination through the whole set.
- `tools/command_sources/retriage.md:83` — the in-flight pull-request read is
  independently capped at 100.
- `tools/command_sources/retriage.md:93` — every later delta is computed from
  the capped `current_open_numbers` set.
- `tools/command_sources/retriage.md:129` — the final check nevertheless claims
  every current open issue appears exactly once.
- `claude-plugin/plugins/kanban/commands/retriage.md:72` — a rendered plugin
  asset ships the same capped issue command; the Codex rendering does too.
- `tools/test_reconcile_approvals.py:905` — the retriage contract-test class
  pins rendering, repository scope, and approval behavior, but has no
  completeness or pagination assertion capable of rejecting these finite
  caps.

**Handoff context:**

- **Current behavior:** On a large tracker, retriage silently treats the first
  500 open issues as the complete issue set and the first 100 open pull
  requests as the complete in-flight set. Omitted issues disappear from the
  roadmap; omitted pull requests can make claimed work look available.
- **Expected behavior:** Retriage obtains every open issue and every open pull
  request needed for in-flight classification, or fails visibly without
  presenting a partial roadmap as exhaustive.
- **Scope and constraints:** Correct the canonical retriage source introduced
  by PR #442 / closed issue #427, re-render both plugin assets, and preserve its
  one-repository scope, stable-order delta rules, and one-call canonical
  approval reconciliation. Triage and backlog-review contain analogous finite
  issue-list commands; audit the shared workflow family while deciding the
  correction, without making unrelated roadmap-policy changes.
- **Verification target:** Contract coverage rejects a finite maximum as proof
  of completeness and exercises or structurally requires traversal beyond 500
  issues and beyond 100 pull requests. The render check proves both bundles
  carry the corrected source, and a simulated over-limit tracker cannot lose
  an issue or an in-flight signal silently.
- **Deduplication:** A search of all open and closed issues for pagination,
  truncation, finite limits, and exhaustive open-issue loading found the
  originating #427 and application-data issue #305, but no issue tracking the
  capped triage/retriage workflow snapshot.
- **Remaining uncertainty:** None.

## 2. Unreleased-note accrual

### PRR-2. The approval sidebar control is absent from the Unreleased notes

> **Captured note:** Add PR #439's user-visible approval-service control to the
> current Unreleased notes, and audit later qualifying merges so the section
> again represents every merged but unshipped user-visible change as PR #426's
> changelog contract requires.

**Verification:** The only release remains `v1.0.0.0`, so PR #439's lowercase
`a` binding and clickable sidebar control are merged but unshipped. The current
changelog explicitly requires such changes to enter `### Unreleased`, yet that
section ends with the underlying issue-approval service and never mentions the
new control that starts or stops it. `git log -- CHANGELOG.md` shows no edit
after PR #426's backfill commit, despite PR #439 landing later. The release
tests remain green because they verify the heading's position and invisibility
to release extraction, not whether later qualifying changes actually accrue.

**Evidence:**

- `CHANGELOG.md:9` — the tracked policy says a merged but unshipped change gets
  an entry under `### Unreleased`.
- `CHANGELOG.md:16` — the live Unreleased section begins here and contains no
  approval-control entry before the `1.0.0.0` release heading at line 52.
- `CHANGELOG.md:45` — the nearest entry describes installation and monitoring
  of the service beneath the control, not the later ability to start or stop it
  from the board.
- `src/Kanban/UI/Keys.hs:222` — current behavior exposes the new lowercase `a`
  action, whose description is to start or stop the issue approval service.
- `docs/design.md:291` — the authoritative key contract exposes both the key
  and click paths, making the change directly observable to a board user.
- `tools/test_release_workflow.py:713` — current tracked-changelog coverage
  proves the Unreleased heading is present and correctly placed but does not
  couple its entries to later user-visible merges.

**Handoff context:**

- **Current behavior:** Release-note readers see the issue-approval service but
  not the subsequently merged board control for operating it, and the
  Unreleased section has not accrued any entry since the PR that created it.
- **Expected behavior:** Every qualifying user-visible merge since the newest
  release is represented by reader-facing text in the current Unreleased
  section; at minimum, the `a`/click approval-service control from PR #439 is
  present.
- **Scope and constraints:** This is a current omission by PR #439 / closed
  issue #421 against the convention established by PR #426 / closed issue
  #418. Preserve `### Unreleased` as a level-three heading, leave the shipped
  `## 1.0.0.0` notes unchanged, and do not infer release cadence, version
  choice, or automated per-PR enforcement that #418 explicitly left out of
  scope.
- **Verification target:** Audit merged PRs after PR #426 against #418's
  user-visible qualification rule, add each missing reader-facing entry, and
  keep the release-workflow suite green with `grep -m1 '^## '` still selecting
  `## 1.0.0.0`.
- **Deduplication:** A search of all tracker states for changelog, Unreleased,
  accrual, and the approval control found the closed originating issues #418
  and #421 but no issue tracking the post-#426 omission.
- **Remaining uncertainty:** None.
