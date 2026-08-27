# Project Review Findings: PRs #244–#219

This review continued below the completed #251 cursor and covered the next
twelve merged pull requests by merge time: #244, #243, #233, #232, #231,
#228, #226, #227, #222, #221, #220, and #219. It also reviewed the direct
first-parent commits `0775285`, `0d32e97`, `5877666`, `7d0d23e`, `a2b4e72`,
`d893026`, `3eb13a6`, `d4d035e`, `d5c0400`, `282ceeb`, and `3e417fd`
interleaved between #251 and #219. The batch was frozen and verified at
`master@39ca2e3` on 2026-08-22. Master advanced to the documentation landing
`2e2003e` while validation was running; that newer commit was excluded rather
than moving the boundary, and the finding below was rechecked there unchanged.

Each pull request was checked against its linked issue where one existed,
pull-request body, commits, landed diff, canonical review history, current
implementation, callers, and current tests. The direct commits were checked
against their patches and the current contract, design, and findings-ledger
state. Later descendants were read only to establish whether a mistake still
exists. This report preserves the one newly confirmed current mistake that
still needs one-at-a-time disposition. PR #243's interim routing from Claude
to the then-Codex-only design pipeline was superseded by closed issue #241,
which added the packaged Claude design pair, so that historical workaround is
not duplicated as a finding.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [x] PRR-1. The completed code-health ledger still relies on an expired CH-4 disposition — [no-issue]

## 1. Code-health status after the drainer crossed its revisit threshold

### [no-issue] PRR-1. The completed code-health ledger still relies on an expired CH-4 disposition

> **Disposition:** No issue — the work this finding names is a ledger
> correction, not tracker work, and it has now been done rather than filed.
> `tools/drain_prs.py` was read end to end at 5,549 lines and 152 top-level
> definitions on 2026-08-27, and CH-4 was re-decided in
> `docs/code-health-report.md` on structure and coupling instead of a line
> count, so it carries no revisit threshold left to expire; that report's status
> header, checklist row, finding heading, severity wording, measurements, fix
> shape and coverage log were reconciled in the same pass, which settles the
> "in progress" versus "18 of 18 resolved" contradiction this finding reported.
> The read found exactly one clean seam — the autostash, anchor,
> stash-retirement and fast-forward cluster at `tools/drain_prs.py:2725-3645`,
> reachable through three entry points and depending outward on four names — and
> its extraction was deliberately declined as legibility rather than
> correctness, at the cost of a live-install reinstall on the component that
> merges pull requests. No decomposition issue is owed.

> **Captured note:** Re-read the current `tools/drain_prs.py` and give CH-4 a
> fresh disposition now that the report's own roughly 5,000-line revisit
> condition has cleared; reconcile the report's overall status at the same
> time.

**Verification:** PR #220 advertised completion of the audit records and
release checklist. At that pull request's merge, `tools/drain_prs.py` was 3,967
lines. The CH-4 disposition used that measurement to keep the finding at
`[no-issue]`: it cited closed epic #159's rough 5,000-line allowance for Python,
said the drainer was still below it, and explicitly said to revisit if the file
crossed that bar.

That clearing condition is now satisfied. At the frozen current master,
`tools/drain_prs.py` is 5,318 lines and contains 147 top-level functions,
compared with 121 at PR #220's merge. The intervening diff adds 1,492 lines and
removes 141. This batch itself contains substantial growth in the same safety-
critical module: PR #219 added bounded shutdown cleanup, issue #223/PR #226
added the late-edit snapshot boundary, issue #224/PR #228 added the
coordination-only merge path, and issue #230/PR #233 added content-safe
branch-update approval handling.
Those changes are individually tested and no runtime defect was reproduced,
but they invalidate the measurement and the explicit condition used to close
CH-4 without an issue.

The durable report has not reacted. Its checklist still calls the file a
3,967-line script and checks CH-4 as `[no-issue]`; its summary still says all 18
findings are resolved; the disposition still says the file is below the rough
bar; and the report's introduction separately still labels the overall audit
“in progress.” A soft size threshold is a reading prompt, not proof that a
split is required, but a disposition that says “revisit if” cannot remain
current after the stated event while the ledger simultaneously claims no work
is owed.

The focused Python sweep passed 906 selected tests after the three modules that
require `tools/` as their working directory were rerun there. The full Haskell
suite passed 1,554 examples. The concern is therefore the stale durable audit
decision and the missed reassessment it promised, not evidence that the current
drainer behavior is failing.

**Evidence:**

- `docs/code-health-report.md:26-28` — the report still declares its audit “in
  progress,” despite the completed checklist and PR #220's completion claim.
- `docs/code-health-report.md:65` and `:81` — CH-4 remains checked as a
  3,967-line `[no-issue]` finding while the summary says all 18 findings are
  resolved.
- `docs/code-health-report.md:428-445` — the disposition depends on being below
  roughly 5,000 lines and expressly says to revisit once that bar is crossed.
- `docs/code-health-report.md:450-465` — the retained “current measurements”
  and fix-shape discussion still use 3,967 lines and the pre-growth sibling
  module and test sizes.
- `tools/drain_prs.py` at `master@39ca2e3` — `wc -l` reports 5,318 lines and
  `rg -c '^def '` reports 147 top-level functions.
- `git diff --numstat 56c45e5..39ca2e3 -- tools/drain_prs.py` — 1,492 inserted
  lines and 141 deleted since PR #220's merge; the merge snapshot itself is
  exactly 3,967 lines.
- Closed issue #159 — its Haskell decomposition epic explicitly excludes
  Python and rejects an ongoing size gate, so crossing the rough threshold
  requires a fresh evidence-based read rather than an automatic split.

**Handoff context:**

- **Current behavior:** The durable code-health report tells a reader both that
  the audit is in progress and that all findings are resolved. Its only
  disposition for the now-5,318-line merge-authority script is checked and
  terminal based on a 3,967-line measurement plus a revisit condition that has
  since occurred.
- **Expected behavior:** Re-read the current module at its present seams and
  record one current disposition for CH-4. If the phase ordering and ownership
  boundaries still justify `[no-issue]`, say why the result remains acceptable
  above the former prompt and refresh the measurements. If the new review
  identifies a concrete split or other correction, file only that evidence-
  backed scope. In either case, make the report's overall status agree with its
  checklist.
- **Scope and constraints:** Do not turn #159's soft observation into a CI cap,
  split code solely to reduce a number, or reopen the completed Haskell epic.
  Preserve the flat-script installation and vendoring boundaries unless a
  current read establishes a worthwhile seam and accounts for every consumer.
  This is first a ledger correction and reassessment; a refactor issue is only
  one possible result.
- **Verification target:** Read `tools/drain_prs.py` end to end at current
  master, inventory its current responsibility clusters and external entry
  points, compare them with the CH-4 rationale, and update the status row,
  heading, measurements, disposition, coverage log, and overall audit status
  consistently. Run the Python suites covering any code or contract paths that
  the chosen disposition changes.
- **Deduplication:** Searches across all tracker states and every findings
  report found no issue or project-review finding that owns the expired CH-4
  revisit. Closed #159 is the cited Haskell-only epic and explicitly excludes
  Python; closed #54 supplied the drainer's original test harness but did not
  own module decomposition. CH-4 itself is the stale closed disposition being
  reassessed, not an independently active tracker item.
- **Remaining uncertainty:** Crossing the soft threshold proves that the
  recorded clearing rationale is stale, not that decomposition is the right
  result. The current end-to-end read decides whether this ends as a refreshed
  `[no-issue]` disposition or a scoped issue.
