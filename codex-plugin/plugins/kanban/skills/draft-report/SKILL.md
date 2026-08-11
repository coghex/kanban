---
name: draft-report
description: Turn free-form notes, observations, audit requests, or a conversational brain dump into an evidence-backed Markdown findings-report draft, present the complete draft for explicit user approval, and only then create the new report for later one-at-a-time processing with process-report. Use when the user invokes $draft-report, asks to start or make a findings/code-health/audit report, wants their typed notes organized into process-report-compatible concerns, or wants a repository review captured as a report without filing issues or changing implementation.
---

# Draft Report

Draft one new report from the user's free-form input, show the complete proposed
report in chat, and create the file only after the user explicitly approves that
draft. Leave tracker deduplication, issue disposition, issue drafting, and issue
creation to later `process-report` runs.

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

## Parse the invocation

Accept natural invocations such as:

```text
$draft-report docs/rendering_findings.md The render stack has several ownership
problems...
```

```text
$draft-report Audit the save system for duplicated serialization logic and
capture whatever you verify.
```

Treat an explicit token ending in `.md` as the desired report path. Otherwise
infer a concise subject and use `docs/<subject>_findings.md` when `docs/` exists,
or `<subject>_findings.md` at the repository root. Tell the user the inferred
path before substantial investigation so they can redirect it without pausing
the work. Never overwrite or repurpose an existing report unless the user
explicitly asks; use `note-problem` when the intent is to add one observation to
an existing report.

If the invocation contains neither source notes nor an audit subject, ask only
what the report should cover. The text after `$draft-report` is source material,
not a request that must already be organized or precisely worded.

## Investigate and draft the report

1. Read applicable repository instructions. Read any report named by the user as
   a format example, but do not copy its findings or project-specific claims.
2. Establish the report's subject, scope, and stable item prefix. Prefer a short
   uppercase prefix derived from the subject, such as `UI`, `SAVE`, or `CH`.
3. Extract candidate concerns from the source material. Split concerns only when
   they could reasonably receive independent dispositions or tracker items.
   Keep symptoms with a shared cause together, and preserve important nuance
   from the user's wording.
4. Investigate each candidate against the current repository:
   - locate and read the owning implementation, not just matching lines;
   - inspect focused tests, documentation, configuration, and history when they
     materially confirm or contradict the claim;
   - search the complete relevant corpus rather than one source directory;
   - reproduce safely when proportionate and permitted by repository rules;
   - record uncertainty instead of converting an assumption into a fact.
5. Omit a candidate only when investigation clearly disproves it or shows it is
   an exact duplicate of another finding in this same report. Briefly tell the
   user about omitted candidates in the handoff. Do not search GitHub for
   duplicates; that belongs to `process-report`.
6. Group the retained findings into a small number of descriptive level-two
   chapters. Preserve the source order when no stronger thematic order exists.
   Give every finding a stable sequential key and a neutral, specific title.
7. Compose the complete proposed report without creating or editing its target
   file. Use this structure:

   ```markdown
   # <Descriptive findings title>

   <One or two sentences describing purpose and scope.>

   Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
   reviewed and deliberately never to be filed · `[deferred]` blocked on a
   concrete precondition

   ## Methodology

   <What input was supplied, what repository surface was inspected, and any
   important limits.>

   ## Status

   - [ ] <KEY-1>. <Short title>
   - [ ] <KEY-2>. <Short title>

   ---

   ## <Concern chapter>

   ### <KEY-1>. <Short title>

   <Concise statement of the verified concern and why it matters.>

   **Evidence:**

   - `<path>:<line>` — <what this establishes>.

   **Handoff context:**

   - **Current behavior:** <observable behavior>.
   - **Expected direction:** <desired property, without prescribing a design>.
   - **Scope and constraints:** <relevant boundaries, compatibility, and tests>.
   - **Remaining uncertainty:** <unknowns, or `None at draft time.`>.
   ```

   Adapt the prose within each finding to the subject; do not pad obvious
   findings with boilerplate. Keep enough evidence and context for a fresh
   `process-report` run to re-verify the premise without rediscovering the whole
   audit. Include the user's exact wording as `> **Source note:** ...` only when
   preserving it adds material context.
8. Keep every status box unchecked and every finding heading unmarked. Only
   `process-report` applies `[#N]`, `[no-issue]`, or `[deferred]` dispositions.
9. Verify that checklist order matches heading order, every key appears exactly
   once in the checklist and once as a finding heading, no duplicate keys exist,
   and the draft contains no accidental terminal markers.

## Approval gate

1. Present the intended path and the complete proposed Markdown report in the
   final response. Do not summarize in place of the draft or omit chapters for
   length.
2. State explicitly that no report file has been written yet, then ask the user
   to approve the draft or request changes.
3. Do not create or edit the report before explicit approval. The initial
   request to run `draft-report`, create a report, or investigate a subject is
   authorization to prepare the draft, not approval of unseen content.
4. If the user requests changes, revise the draft and present the complete
   updated version again. Approval applies only to the latest version the user
   has seen.
5. Skip this gate only when the user explicitly instructs this invocation to
   bypass draft review and write without approval.

## Write the approved report

1. After approval, confirm the target path is still available. Never overwrite
   or repurpose a file that appeared after drafting; stop and request a new path
   if the target now exists.
2. Create the approved report in one `apply_patch` edit. Preserve the approved
   content exactly except for corrections the user explicitly included with
   their approval.
3. Re-run the checklist/key/order verification against the written file and
   confirm that no terminal status marker was introduced.

## Boundaries

- Draft and, after approval, create a findings report, not an issue backlog,
  implementation plan, or patch.
- Do not modify implementation code, file issues, mutate GitHub, or choose issue
  dispositions.
- Do not invent a minimum finding count. A narrow input may yield one finding;
  a clean audit may yield none. If none survive verification, explain that and
  do not create an empty report unless the user explicitly wants the audit
  record.
- Do not treat line counts, naming preferences, or structural oddities as
  self-proving defects. State the concrete maintenance, correctness, user, or
  operational cost.
- Respect repository testing tiers and application-launch safety rules.

## Handoff

Before approval, report the intended path, finding count, item-key range, major
chapters, and any omitted or uncertain source notes. End by stating that no file
has been written and asking the user to approve the displayed draft or request
changes.

After approval and creation, report the created path, finding count, item-key
range, major chapters, and any omitted or uncertain source notes. End by stating
that the report is ready for `process-report`, which will handle exactly one
finding per invocation.
