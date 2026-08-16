---
description: Turn free-form notes, observations, audit requests, or a conversational brain dump into an evidence-backed Markdown findings-report draft, present the complete draft for explicit user approval, and only then create the new report for later one-at-a-time processing with process-report. Use when the user invokes /draft-report, asks to start or make a findings/code-health/audit report, wants their typed notes organized into process-report-compatible concerns, or wants a repository review captured as a report without filing issues or changing implementation.
argument-hint: "[optional: report path, audit subject, or free-form notes]"
---

# Draft Report

Draft one new report from the user's free-form input, show the complete proposed
report in chat, and create the file only after the user explicitly approves that
draft. Leave tracker deduplication, issue disposition, issue drafting, and issue
creation to later `/process-report` runs.

## Establish the owning repository

This workflow writes a document and mutates a tracker. Both are irreversible in
the wrong repository, and moving a Markdown file afterward does not undo an
issue filed where it does not belong. So resolve the owner explicitly before
the first durable write and before the first tracker mutation — never from
whichever checkout the session happens to be sitting in.

Resolve three values together, and treat every one of them as required:

- `$DOC_REPO` — the owning repository as an explicit `owner/repo` slug. It
  scopes every `gh` command in this workflow.
- `$DOC_BRANCH` — that repository's default branch, which is the publication
  target. It is never assumed to be the current checkout's branch.
- `$DOC_ROOT` — a validated local checkout of `$DOC_REPO`, under which every
  document read and write resolves. A slug alone names no place to write.

Resolution has two tiers, and the first tier that matches wins:

**(a) Explicit input.** A repository or a document path the user supplied.
Validate each one, and require them to agree: when the user names both, the
path's own checkout must resolve to that same repository. Conflicting explicit
inputs are unresolved, not a preference to rank.

**(b) A §7 row.** For a document path that is Git-tracked in the checkout
holding it, coverage by exactly one row of `docs/agent-workflow-contract.md` §7
declares the document Kanban-owned. That table is Kanban's own and classifies
Kanban paths only, so it can identify Kanban as the owner and can never
identify a consuming repository. A path covered by no row, covered by more than
one row, or not tracked at all resolves nothing here — and a new document that
no row covers is the expected case rather than an error.

Anything else leaves the owner unresolved.

```bash
# $CANDIDATE is the checkout an explicit path or repository named — never the
# working directory by default. Nothing below reads the process working
# directory, which is the point: every command names its own repository.
DOC_ROOT="$(git -C "$CANDIDATE" rev-parse --show-toplevel)"
DOC_REMOTE="$(git -C "$DOC_ROOT" remote get-url origin)"
DOC_REPO="$(gh repo view "$DOC_REMOTE" --json nameWithOwner --jq .nameWithOwner)"
DOC_BRANCH="$(gh repo view "$DOC_REMOTE" --json defaultBranchRef --jq .defaultBranchRef.name)"

# Tier (b) additionally requires the document to be tracked where it sits.
git -C "$DOC_ROOT" ls-files --error-unmatch -- "$DOC_RELATIVE_PATH"
```

**Fail closed.** An unresolved owner, an unresolved or ambiguous default
branch, or a `$DOC_ROOT` that is not a checkout of `$DOC_REPO` stops the run
before it creates a file, edits a document, or issues any `gh` mutation. Say
exactly which of the three could not be determined, and ask the user for the
owning repository — and for a local path as well when no checkout of it is
available. Falling back to the active checkout, to the current branch, to a
hardcoded path, or to a bare `docs/` prefix is never the repair.

Report the resolved `$DOC_REPO` and `$DOC_BRANCH` to the user before the first
write.

Reading code, tests, or history from another repository as evidence stays
allowed and is never an ownership signal: where you read something does not
make that repository the owner.

Repository routing and the publication lane are separate decisions. `$DOC_REPO`
says where this document and its tracker items belong; whether the document
then publishes as `coordination` or `pr-atomic` is a later question §7 answers
about an already-resolved owner, never a substitute for resolving one.

## Where files go

Never leave uncommitted files in the repository's PRIMARY checkout. The PR
drainer fast-forwards it after every merge and autostashes whatever it finds
there; a restore that conflicts leaves unmerged index entries and wedges
post-merge cleanup until a human clears them. Long-lived uncommitted report
edits are the exact shape that keeps causing it.

Resolve the docs worktree by BRANCH — never a hard-coded path — inside the
already-resolved `$DOC_ROOT`, and do every file write there:

```bash
DOCS_WT="$(git -C "$DOC_ROOT" worktree list --porcelain \
  | awk '/^worktree /{p=substr($0,10)} /^branch refs\/heads\/docs-wip$/{print p; exit}')"
[ -n "$DOCS_WT" ] || DOCS_WT="$DOC_ROOT"
```

Every report or document path in this workflow resolves under `$DOCS_WT`,
whatever the current directory is. Read code from wherever you already are;
write only there. If `$DOC_REPO` has no `docs-wip` worktree the fallback
returns that repository's own primary checkout, which means it does not use
this convention — proceed normally. What the fallback never returns is the
checkout you happen to be sitting in.

## Parse the invocation

Accept natural invocations such as:

```text
/draft-report docs/rendering_findings.md The render stack has several ownership
problems...
```

```text
/draft-report Audit the save system for duplicated serialization logic and
capture whatever you verify.
```

Treat an explicit token ending in `.md` in `$ARGUMENTS` as the desired report
path, and feed it to the ownership resolution above as the explicit path input.
Otherwise infer a concise subject from `$ARGUMENTS` and use
`$DOCS_WT/docs/<subject>_findings.md` when
`$DOCS_WT/docs/` exists, or `$DOCS_WT/<subject>_findings.md`; a bare `docs/`
prefix names nothing until `$DOC_ROOT` is resolved, and a report whose owner
stays unresolved is asked about rather than created. Tell the user the inferred
path, `$DOC_REPO`, and `$DOC_BRANCH` before substantial investigation so they
can redirect any of the three without pausing the work. Never overwrite or repurpose an existing report unless the user
explicitly asks; use `/note-problem` when the intent is to add one observation to
an existing report.

If `$ARGUMENTS` contains neither source notes nor an audit subject, ask only
what the report should cover. The text in `$ARGUMENTS` is source material,
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
   duplicates; that belongs to `/process-report`.
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
   `/process-report` run to re-verify the premise without rediscovering the whole
   audit. Include the user's exact wording as `> **Source note:** ...` only when
   preserving it adds material context.
8. Keep every status box unchecked and every finding heading unmarked. Only
   `/process-report` applies `[#N]`, `[no-issue]`, or `[deferred]` dispositions.
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
   request to run `/draft-report`, create a report, or investigate a subject is
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
2. Create the approved report with one `Write` tool call. Preserve the approved
   content exactly except for corrections the user explicitly included with
   their approval.
3. Re-run the checklist/key/order verification against the written file and
   confirm that no terminal status marker was introduced.

## Publication

A document this workflow newly creates is local and unpublished, and this
workflow never publishes one. It is not yet tracked, so no row of
`docs/agent-workflow-contract.md` §7 matches its path, and an unmatched path is
`pr-atomic` by the fail-closed default — there is no moment at which a novel
document is directly publishable. Its first publication requires a separate pull
request that adds both the document and its `coordination` classification. Only
after that pull request lands may a later processing run publish
direct-to-`master` mutations to it. Creating that enrollment pull request is not
this workflow's job either; say plainly that the document is local so the user
can decide.

An existing document this workflow resumes is unaffected by the above: whether
its edits publish is the processing workflows' question, answered against the
same §7 rows.

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
that the report is ready for `/process-report`, which will handle exactly one
finding per invocation.

<!-- Transposed from the tracked Codex skill
     codex-plugin/plugins/kanban/skills/draft-report/SKILL.md at commit
     86cd55c57d96875b02d529d75259ca62ee446f48, SHA-256
     6e38987ad4d072918f53c3f40d3aa36cd7f439c0eb81a341523f7e43f66ab9aa.
     It differs from that source only in Claude command frontmatter,
     $ARGUMENTS plumbing, Claude tool names, and Claude-sigil workflow
     cross-references; it introduces no new behavior. -->
