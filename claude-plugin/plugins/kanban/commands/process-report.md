---
description: Process a Markdown findings or code-health report one concern at a time, resuming from a durable status checklist and issue/no-issue/deferred annotations, and stopping for approval before any disposition.
argument-hint: "<path-to-report.md>"
---

Process exactly one finding from the report named by `$ARGUMENTS`. Treat the
report file as the durable cursor so a fresh Claude context resumes at the
correct place without conversation history.

If `$ARGUMENTS` is empty, ask for the Markdown report path and stop.

Resolve that path under `$DOCS_WT` (see "Where files go" below) before reading
or editing it — a repo-relative report path names the copy in the docs worktree,
not the one in whatever checkout you happen to be sitting in.

## Where files go

Never leave uncommitted files in the repository's PRIMARY checkout. The PR
drainer fast-forwards it after every merge and autostashes whatever it finds
there; a restore that conflicts leaves unmerged index entries and wedges
post-merge cleanup until a human clears them. Long-lived uncommitted report
edits are the exact shape that keeps causing it.

Resolve the docs worktree by BRANCH — never a hard-coded path — and do every
file write there:

```bash
DOCS_WT="$(git worktree list --porcelain \
  | awk '/^worktree /{p=substr($0,10)} /^branch refs\/heads\/docs-wip$/{print p; exit}')"
[ -n "$DOCS_WT" ] || DOCS_WT="$(git rev-parse --show-toplevel)"
```

Every report or document path in this workflow resolves under `$DOCS_WT`,
whatever the current directory is. Read code from wherever you already are;
write only there. If the repository has no `docs-wip` worktree the fallback
returns the primary checkout, which means that repository does not use this
convention — proceed normally.

## Status contract

Prefer the report's existing status convention when it is equally explicit.
Otherwise use these canonical markers in the finding heading:

- `[#123]`: linked to GitHub issue or epic 123, whether newly created or already
  existing.
- `[no-issue]`: reviewed and deliberately never to be filed.
- `[deferred]`: reviewed, should be filed, but blocked on a stated precondition.
- No marker: unprocessed.

For `[no-issue]`, add this visible note immediately below the heading:

```markdown
> **Disposition:** No issue — <concise evidence-backed reason>.
```

For `[deferred]`, add this visible note immediately below the heading:

```markdown
> **Deferred:** <what blocks filing> — <the concrete precondition that clears it>.
```

`[no-issue]` and `[deferred]` are not interchangeable, and the difference is
whether the work will ever happen. `[no-issue]` closes a finding: the claim is
false, already fixed, too harmless to track, or deliberately out of scope.
`[deferred]` keeps it open: the concern is real and should become an issue, but
filing now would produce a bad issue. Reaching for `[no-issue]` because a finding
is merely unclear silently discards real work — when in doubt, defer.

A deferral is only valid with a **concrete, checkable precondition**: a file or
test not yet read, a premise not yet verified, or a specific issue that must land
first. "Needs more thought", "low priority", and "revisit later" are not
preconditions, and a finding that cannot state one is unprocessed rather than
deferred.

If the report has a status legend, add each marker's meaning the first time that
marker is used. Never treat incidental issue numbers in prose, examples, or
Related sections as processed markers.

## Status checklist

A report carries one checklist near its top, a single line per finding, as the
at-a-glance index of the whole document. Create it on the first run if the report
has none, seeding it from the existing headings. Otherwise update it in the same
edit that marks a finding — never as a separate pass.

```markdown
## Status

- [x] 1. Test suite is one 9,200-line module — [#148]
- [ ] 2. `UI.hs` is a god-module — [deferred]: bodies unread
- [x] 6. LaunchAgent label is a machine-wide singleton — [#147]
- [x] 10. Process-group hardening not swept — [no-issue]
- [ ] 13. Config layer has no per-repository override
```

Rules:

- A box is checked only for a **terminal** disposition — filed (`[#N]`) or closed
  (`[no-issue]`). `[deferred]` and unmarked stay unchecked, because both still
  represent work the report owes. The count of unchecked boxes is therefore the
  count of findings still outstanding.
- Each line carries the finding's number or item key, a title short enough to scan,
  and its marker. A `[deferred]` line appends the precondition in a few words, so
  the checklist alone answers "what is blocked and on what."
- The checklist mirrors the headings; it never becomes a second source of truth. If
  the two disagree, the headings win and the checklist is corrected.
- Findings the report gains later are appended unchecked. Never delete a line to
  make the list look finished.

## 1. Locate the next finding

1. Resolve `$ARGUMENTS` relative to the working directory. Stop with a concise
   error if it does not exist or is not a Markdown file.
2. Read the repository's applicable `CLAUDE.md`, `AGENTS.md`, or equivalent
   instructions before investigating.
3. Read the report header, status legend, and status checklist, then list finding
   headings with:

   ```bash
   rg -n '^#{2,6} ' "$ARGUMENTS"
   ```

4. Infer the finding-heading level and item-key pattern from neighboring
   entries; for example, a report may use level-three `CH-N` headings rather than
   plain numbers.
5. Choose exactly one finding, by this precedence. `[#N]` and `[no-issue]`
   findings are never selected.

   1. **A `[deferred]` finding whose precondition is now satisfied.** Take the
      first such finding, top to bottom. Confirm the precondition actually holds
      by checking it — read the file the note names, verify the premise, or
      confirm the blocking issue merged. Never take the note's word for it; a
      precondition written weeks ago is a claim, not a fact. If it holds, clear
      the `[deferred]` marker and its note, then process the finding normally.
   2. **Otherwise, the first finding carrying no marker.**

   Deferred work outranks new work deliberately. A deferred finding has already
   been investigated once, and the moment its blocker clears is exactly when that
   investigation is still worth something. Left behind the queue, it is how a real
   concern quietly becomes permanent.

6. Read from that heading through the next finding heading. Read other findings
   only when needed to resolve an explicit cross-reference. Do not evaluate
   runners-up or batch later entries.
7. Stop without editing when nothing is selectable:

   - Every finding is `[#N]` or `[no-issue]` — report completion.
   - Only `[deferred]` findings remain and none of their preconditions are met —
     report that the report is blocked rather than finished, listing each finding
     with the precondition still outstanding and what would clear it. Do not call
     this completion; the difference matters to whoever reads the result.

## 2. Verify the concern

Treat the report as a lead, not proof.

- Inspect the current code, tests, documentation, history, and configuration
  needed to confirm or reject the claim.
- Search every relevant source and test tree, including secondary suites the
  report may have omitted.
- For a bug, reproduce it when safe and proportionate, or trace the concrete
  failure path with file-and-line evidence.
- For code health or documentation, confirm the stale/dead/duplicated surface
  still exists and identify the authoritative replacement or contract.
- Respect repository testing tiers and safety rules. Never open a graphical
  application merely to evaluate a finding.
- Do not modify implementation code during this workflow.

Correct minor factual errors in the finding when presenting evidence. A count
correction does not invalidate the concern unless it changes the conclusion.

## 3. Deduplicate

Before recommending a new tracker item:

1. Read every open issue title:

   ```bash
   gh issue list --state open --limit 300 --json number,title,labels
   ```

2. Run two or three differently phrased searches across open and closed issues:

   ```bash
   gh issue list --search "<keywords>" --state all --limit 20
   ```

3. Read plausible matches and all open epics whose bodies may own the work. A
   planned epic child counts as a duplicate.
4. Respect prior `wontfix`, `invalid`, or decision records unless materially
   new evidence changes the premise.

## 4. Recommend exactly one disposition

### No issue

Use when the claim is false, already fixed, too harmless to justify tracker and
PR overhead, or deliberately out of scope. Do not use it for a real concern you
are merely unsure how to scope — that is `Deferred`. Present:

- the recommendation and evidence;
- the exact proposed `[no-issue]` note; and
- the consequence of leaving the code unchanged.

Stop for explicit approval before editing the report.

### Deferred

Use when the concern is real and should become an issue, but filing now would
produce a bad one. The three cases that justify it:

- **Evidence incomplete** — the finding rests on structure, counts, or an export
  list, and the code that would specify the fix has not been read. An issue
  written from this hands a solve agent a guess dressed as a plan.
- **Premise unverified** — something not yet checked could materially shrink or
  invalidate the finding. Name the exact file or test that settles it.
- **Blocked on sequencing** — the change would conflict with issues already
  filed, or depends on one of them landing first. Name those issues.

Present the recommendation, the evidence gathered so far, the exact proposed
`[deferred]` note, and the concrete precondition that clears it. State plainly
that this is not a decision against the work. Stop for explicit approval before
editing the report.

Deferral is a scheduling decision, not a verdict, so it is bounded: do not defer
a finding that is already fully evidenced and unblocked merely because the fix
looks large. Size is what `Epic` is for.

### Existing issue or epic

Present its number, why it covers the finding, and any proposed comment
containing genuinely new evidence. Do not comment or mark the report without
approval.

### One new issue

Use when the work fits one reviewable PR. Present the complete draft exactly as
it would be posted:

- imperative title;
- existing labels only;
- `## Background` with verification evidence;
- numbered, observable `## Requirements`;
- exact, proportionate commands in `## Acceptance`;
- explicit `## Out of scope`;
- `## Related`; and
- `<!-- issue-origin:claude -->` as the final line.

Specify observable outcomes rather than implementation method. Preserve
repository constraints such as compatibility, determinism, persistence,
performance, and required steering-document updates. Below the draft, include
short Evidence and Dedup notes and state that no later finding was examined.

Stop for explicit approval. Never create an issue while merely presenting or
revising its draft.

### Epic

Use only when the concern requires multiple dependency-ordered PRs or an
unresolved product/design decision. Explain why one issue is insufficient and
propose the decomposition boundary. Stop for agreement, then hand the arc to
Codex's `$design-epic` workflow; its slices are filed later through Codex's
`$process-design-doc`. Do not compress epic-sized work into one issue.

## 5. Apply the approved disposition

Only after explicit approval:

- **New issue:** write the approved body to a temporary file, create it with
  `gh issue create --body-file`, apply only approved existing labels, and
  confirm the returned issue number.
- **Existing issue:** optionally post only an explicitly approved comment, then
  confirm the target issue still exists.
- **Epic:** hand the approved arc to Codex's `$design-epic` workflow for capture
  in a design document, then process its `EPIC` entry through
  `$process-design-doc` and record the created tracker number.
- **No issue:** make no external mutation.
- **Deferred:** make no external mutation.

Then edit only the selected report finding:

- Prefix its heading with `[#N]` for a confirmed issue or epic.
- Prefix it with `[no-issue]` and insert the approved Disposition note when no
  tracker item will be created.
- Prefix it with `[deferred]` and insert the approved Deferred note when the
  concern is real but blocked. When promoting a previously deferred finding,
  remove both its `[deferred]` marker and its Deferred note before applying the
  new marker, so no stale precondition survives beside a filed issue.
- Update that finding's status-checklist line in the same edit: set its marker,
  check the box for a terminal disposition, and add or clear the deferred
  precondition. A run that marks a heading and leaves the checklist stale has
  produced two contradictory answers to the same question.
- Preserve the finding body and all unrelated changes.
- Never mark the finding when issue creation or lookup failed.
- Do not commit, push, or open a PR unless separately requested.

Verify heading and checklist agree, and that the run changed exactly one finding:

```bash
rg -n '<item-key>' "$ARGUMENTS"
git diff --stat -- "$ARGUMENTS"
```

For a created or linked issue, also verify its title, state, labels, and URL.

Report, in this order: the disposition and its tracker link if any; the report
line as it now reads; and the number of findings still unchecked, so the next run
starts from a known position.

Stop after this one finding. Advance only when the user explicitly asks or runs
`/process-report` again. Never batch a second finding into the same run, even
when the next one looks trivial or obviously related — the one-at-a-time rule is
what keeps each disposition individually approved.
