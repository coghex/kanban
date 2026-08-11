---
name: process-report
description: Process a large Markdown findings, audit, or code-health report one concern at a time, resuming from a durable status checklist and annotations in the report. Use when asked to run process-report, continue reviewing a report, find its next actionable concern, decide whether that concern deserves no issue, a deferral, an existing issue link, one new issue, or an epic, and record the approved disposition so a fresh context resumes at the following concern.
---

# Process Report

Process exactly one finding per invocation. Treat the report file as the durable
cursor; never depend on conversation history to know where to resume.

Resolve the report path under `$DOCS_WT` (see "Where files go" below) before
reading or editing it — a repo-relative report path names the copy in the docs
worktree, not the one in whatever checkout you happen to be sitting in.

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

This contract is shared with the Claude `/process-report` command. The markers,
note formats, and checklist below are identical in both, so a report started by
one can be resumed by the other without translation. Do not introduce a
Codex-only marker or note shape.

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
marker is used. Never treat incidental issue numbers in a finding's prose,
examples, or Related section as a processed marker.

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

1. Resolve the user-supplied report path relative to the working directory.
   Stop with a concise error if it does not exist or is not a Markdown file.
2. Read the applicable repository instructions before investigating.
3. Read the report header, status legend, and status checklist, then list its
   finding headings with `rg -n '^#{2,6} ' <report>`. Infer the report's
   finding-heading level and item-key pattern from neighboring entries; for
   example, a report may use level-three `CH-N` headings rather than plain
   numbers.
4. Choose exactly one finding, by this precedence. `[#N]` and `[no-issue]`
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

5. Read that finding from its heading through the next finding heading. Read
   earlier or later findings only when needed to understand an explicit
   cross-reference. Do not evaluate runners-up or batch later findings.
6. Stop without editing anything when nothing is selectable:

   - Every finding is `[#N]` or `[no-issue]` — report completion.
   - Only `[deferred]` findings remain and none of their preconditions are met —
     report that the report is blocked rather than finished, listing each finding
     with the precondition still outstanding and what would clear it. Do not call
     this completion; the difference matters to whoever reads the result.

## 2. Verify the concern

Treat report text as a lead, not as proof.

- Inspect the current code, tests, documentation, history, and configuration
  needed to confirm or reject the claim.
- Search the complete relevant corpus, including secondary test trees that the
  report may have omitted.
- For a bug, reproduce it when safe and proportionate, or trace the concrete
  failure path with file-and-line evidence.
- For code health or documentation, confirm the stale/dead/duplicated surface
  still exists and identify the authoritative replacement or contract.
- Respect repository testing tiers and safety rules. Do not launch a graphical
  application merely to evaluate a finding.
- Do not modify implementation code during report processing.

Correct minor factual errors in the finding when presenting the evidence. A
corrected count does not invalidate the underlying concern unless it changes
the conclusion.

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

3. Read any plausible match and every open epic whose body may already own the
   work. A planned epic child is a duplicate.
4. Respect prior `wontfix`, `invalid`, or decision records unless the finding
   supplies materially new evidence.

## 4. Recommend one disposition

Choose exactly one:

### No issue

Use when the claim is false, already fixed, harmless enough that tracker and PR
overhead exceed its value, or deliberately out of scope. Do not use it for a real
concern you are merely unsure how to scope — that is `Deferred`. Present:

- the recommendation and evidence;
- the exact proposed `[no-issue]` note; and
- any consequence of leaving the code unchanged.

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

Present the issue number, why it covers the finding, and any proposed comment
containing genuinely new evidence. Do not post a comment or mark the report
without approval.

### One new issue

Use when the work fits one reviewable PR. Present the draft exactly as it would
be posted:

- imperative title;
- existing labels only;
- `## Background` with verification evidence;
- numbered, observable `## Requirements`;
- exact, proportionate commands in `## Acceptance`;
- explicit `## Out of scope`;
- `## Related`; and
- `<!-- issue-origin:codex -->` as the final line.

Specify what must be true, not how to implement it. Preserve repository
constraints such as compatibility, determinism, persistence, performance, and
required steering-document updates. Below the draft, include short Evidence and
Dedup notes. State that no later finding was examined.

Stop for explicit approval. Never create the issue while merely presenting or
revising the draft.

### Epic

Use only when the concern genuinely requires multiple dependency-ordered PRs
or an unresolved product/design decision. Explain why one issue is insufficient
and propose the decomposition boundary. Stop for user agreement, then use the
available `epic` workflow. Do not force epic-sized work into one issue.

## 5. Apply the approved disposition

Only after explicit approval:

- **New issue:** create the approved body with `gh issue create --body-file`
  using a temporary file and approved existing labels. Confirm the returned
  issue number before editing the report.
- **Existing issue:** optionally post only an explicitly approved comment, then
  confirm the target issue still exists.
- **Epic:** complete the approved epic workflow and obtain its tracker number.
- **No issue:** make no external mutation.
- **Deferred:** make no external mutation.

Then update only the selected finding:

- Prefix its heading with `[#N]` for a confirmed issue or epic.
- Prefix it with `[no-issue]` and insert the approved Disposition note for a
  no-issue decision.
- Prefix it with `[deferred]` and insert the approved Deferred note when the
  concern is real but blocked. When promoting a previously deferred finding,
  remove both its `[deferred]` marker and its Deferred note before applying the
  new marker, so no stale precondition survives beside a filed issue.
- Update that finding's status-checklist line in the same edit: set its marker,
  check the box for a terminal disposition, and add or clear the deferred
  precondition. A run that marks a heading and leaves the checklist stale has
  produced two contradictory answers to the same question.
- Preserve the finding body and unrelated user changes.
- Use `apply_patch` for the report edit.
- Do not mark a finding if issue creation or lookup failed.
- Do not commit, push, or open a PR unless separately requested.

Verify heading and checklist agree, and that the run changed exactly one finding,
with `rg -n '<item-key>' <report>` and `git diff --stat -- <report>`. For a
created or linked issue, also verify its title, state, labels, and URL.

Report, in this order: the disposition and its tracker link if any; the report
line as it now reads; and the number of findings still unchecked, so the next run
starts from a known position.

Stop after this one finding. Advance to the next only when the user explicitly
asks or invokes `process-report` again. Never batch a second finding into the
same run, even when the next one looks trivial or obviously related — the
one-at-a-time rule is what keeps each disposition individually approved.
