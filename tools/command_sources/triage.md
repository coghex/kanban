---
name: triage
description: Organize a GitHub repository's open issues into prerequisite-aware roadmap blocks, a hotfix/bug-prioritized and conflict-minimized Anytime queue, and a tracker/epic list. Use when the user invokes {{cmd:triage}} or asks to order, sequence, prioritize, roadmap, group, or visually organize open GitHub issues, especially when they want parallel-safe picks and explicit prerequisite barriers.
argument-hint: "[optional repo owner/name — defaults to the current repo]"
---

# Triage

## Goal

Produce a compact, visually usable issue roadmap from the current open GitHub issues. Optimize for a user leaving the answer open as a work queue.

The key visual contract:

- A blank line inside `Main Sequence` means a **dependency barrier**: stop spinning up new agents past that gap until the prior group is merged or unblocked.
- Consecutive issues within the same no-blank block may generally be worked in parallel unless their text says `->`, `depends`, or another explicit ordering cue.
- `Main Sequence` is the prerequisite/blocker lane: include open dependency chains, issues that gate other open issues, and explicitly ordered critical-path work. Do not put a merely urgent or impactful standalone issue there.
- Self-contained issues go in `Anytime List`. Treat it as a priority-ordered, parallel-friendly triage queue, not an unordered remainder list.
- Epic/tracker issues go in `Tracker Issues`, not the main sequence, unless the issue itself contains concrete implementation work.

## Workflow

1. Resolve the repository once, before any GitHub read, and use that one identity for every `gh` call below.

<!-- brand:claude -->
A supplied repository arrives in `$ARGUMENTS`; when it is non-empty, that identity is the target and the resolution below is skipped.
<!-- brand:codex -->
A supplied repository arrives in the prompt; when the user named one, that identity is the target and the resolution below is skipped.
<!-- /brand -->

```bash
REPO_REMOTE="$(git remote get-url origin)"
REPO="$(gh repo view "$REPO_REMOTE" --json nameWithOwner --jq .nameWithOwner)"
```

Pass `-R "$REPO"` on every `gh` invocation below, and name the resolved repository in the answer's first line. Without `-R`, `gh` targets whatever repository the session's working directory happens to be in, so an unnamed call silently triages the wrong tracker; reporting what was resolved is what catches a wrong resolution.

2. Pull fresh open issue data. Prefer `gh` if no GitHub issue-listing connector is available:

```bash
gh issue list -R "$REPO" --limit 500 --state open --json number,title,labels,assignees,body,createdAt,updatedAt,url
```

3. Pull open PRs so in-flight work is visible:

```bash
gh pr list -R "$REPO" --state open --limit 100 --json number,title,body
```

An issue referenced by an open PR's `Closes #<n>`, carrying one or more assignees, or labeled `wip` is **in-flight**. Keep it in its normal section, order it under the rules below, and show every applicable work signal: `[in-flight: PR #NNN]`, `[assigned: @login]` (include every assignee), and/or `[wip]`. Never collapse an assignment into a generic `[claimed]` note, and never choose any in-flight issue as `Start with` — an agent picking it would collide with existing work.

4. Read issue bodies, not just titles. Dependencies and "deferred/follow-up" status are usually in bodies.
5. For referenced prerequisite issues that materially affect ordering, check whether they are open or closed:

```bash
gh issue view -R "$REPO" <number> --json number,title,state,closedAt,body,labels
```

6. Infer each issue's likely focus area and touched paths from its body. Use explicit file lists when present; otherwise use the narrowest reasonable subsystem such as CI/tooling, worldgen, persistence, UI, graphics, Lua/AI, gameplay, or documentation. This is scheduling metadata, not an output requirement.
7. Classify every currently open issue exactly once into:
   - `Main Sequence`: prerequisite/blocker chains and explicit critical-path ordering.
   - `Anytime List`: self-contained work with no open prerequisite and no open dependent that makes it part of a chain.
   - `Tracker Issues`: epics, umbrella trackers, stale trackers, and bookkeeping issues.

8. Build the Main Sequence dependency groups and the Anytime priority order using the rules below.
9. Estimate every issue's implementation difficulty as `easy`, `medium`, or `hard` using the rubric below.
10. Before final output, verify the classification covers all open issues and has no duplicates.
11. Mark every issue carrying the exact `reviewed:approve` label with `✓` in the rendered lists. Put the marker immediately after the title and before any bracket note. This is display-only: it does not affect ordering, classification, in-flight status, or `Start with` eligibility.

## Ordering Heuristics

### Label priority

Use three strict priority buckets in this order wherever issues are otherwise eligible for the same list or dependency group:

1. Issues carrying the exact `hotfix` label.
2. Issues carrying the exact `bug` label but not `hotfix`.
3. All remaining issues.

Do not promote a lower bucket above an upper bucket merely to improve subsystem alternation. If an issue carries both labels, order it as `hotfix`. Render every applicable priority label as `[hotfix]` and/or `[bug]` after the difficulty marker so the ordering is visible.

Within each bucket, prioritize:

1. Immediate correctness and hardening impact: crashes, data loss, security, broken builds or CI, and regressions.
2. Upstream leverage: low-level contracts, shared primitives, schemas, interfaces, build/tooling behavior, or fixes that block many issues or would change how downstream issues should be solved.
3. Rework avoidance: work that should land before several otherwise-independent issues because those issues would need to adapt to it.
4. Broader player or maintainer impact, then narrower/local work.

### Main Sequence membership and grouping

Build an open-issue dependency graph from explicit body evidence. Add an issue to `Main Sequence` when at least one applies:

- it has an open issue prerequisite;
- another open issue explicitly depends on it or it directly unblocks active work;
- it is part of an explicitly ordered, open critical-path chain;
- it has an external prerequisite and participates in a chain with another open issue.

Closed prerequisites do not keep an otherwise self-contained issue in Main Sequence. Urgency alone does not put an issue there; urgent standalone work belongs at the top of Anytime.

Render Main Sequence as dependency-ready waves:

- The first block contains the currently startable roots of open chains plus externally blocked roots that must remain visible.
- Each later block contains issues whose open prerequisites appear in earlier blocks.
- Dependency topology overrides label priority across blocks: never move a dependent `hotfix` ahead of its prerequisite. Apply label priority only among issues eligible for the same block.
- Within a block, apply `hotfix` → `bug` → remainder, upstream leverage, and the parallel-safety rules below.
- Within the same label bucket and impact band, put immediately startable roots before in-flight or externally blocked roots.
- If two dependency-ready issues are likely to edit the same file, serialize them into successive blocks unless an explicit implementation plan proves the edits disjoint. Add `[after #NNN; shared files]` to make the procedural barrier visible.
- A blank line is allowed only for an actual prerequisite barrier or a deliberate shared-file serialization barrier. Never use one for visual grouping or priority alone.

### Anytime List ordering

Order Anytime as the repository's practical pick-next queue:

1. Partition it strictly into `hotfix`, then `bug`, then remainder.
2. Compute the impact/upstream-leverage order within each bucket.
3. Schedule the bucket greedily for parallel safety:
   - Prefer a candidate whose likely touched files do not overlap any of the preceding three entries.
   - Never place two issues likely to touch the same file adjacent while any same-bucket, similarly important non-conflicting candidate remains.
   - Prefer alternating focus areas; avoid adjacent issues from the same subsystem when a similarly important candidate from another subsystem is available.
   - Treat shared files as stronger evidence than a shared subsystem label. Different files in one subsystem may still be safe in parallel.
   - Do not bury a materially more urgent or much more upstream issue solely to create variety. Alternate among issues of comparable urgency and leverage.
4. When conflicts are unavoidable because a bucket is small or homogeneous, minimize the overlap and annotate material collisions such as `[same-file conflict with #NNN]`.
5. Within a priority bucket, rank immediately startable issues ahead of comparable in-flight or `needs-decision` issues. Never move an in-flight lower-priority-label issue ahead of a higher label bucket.

The intended result is that taking the first several unclaimed Anytime entries produces a useful mix of work that can proceed concurrently with low merge-conflict risk.

### General ordering rules

Respect workflow labels: `needs-decision` means the issue awaits a user call (mark `[needs-decision]`); `wip` means an agent is already on it (treat as in-flight). Neither is ever `Start with`.

Keep active feature arcs together and order their child issues by explicit dependencies in the bodies. If an epic says a child depends on another child, respect that. If a child prerequisite is already closed, do not include it as active work.

For feature epics:

- Put the epic itself in `Tracker Issues`.
- Put open implementation children in `Main Sequence` only when they form an open critical path or prerequisite chain.
- Put deferrable or phase-2 children in `Anytime List` only if the body says they are not on the critical path and they otherwise satisfy Anytime's self-contained rule.

For refactor issues:

- Put refactors that directly unblock active work in `Main Sequence`.
- Put standalone file-split refactors in `Anytime List` unless they form a known dependency chain.
- Put central/cycle-sensitive type splits late.
- Keep known chains together:
  - API registration before broad Lua API splits.
  - Save command split before save type split.
  - Timeline/type splits before downstream timeline/river splits.
  - Boot/CLI split before preview or new boot modes when relevant.
  - These chains reflect past triages — before letting one order anything, confirm its earlier link is still open; a chain whose prerequisite already landed no longer constrains.

For issue bodies with explicit wording, prefer the body over generic heuristics:

- `depends on`, `blocked by`, `must land first`, `phase 1/2`, `critical path`, `not on v1 critical path`.
- `independent`, `can land first`, `stubbable`, `optional`, `phase 2`, `deferred`.
- `epic`, `umbrella`, `tracker`, `stale`, `update or close`.

Choose `Start with` from the immediately startable, non-in-flight, non-`needs-decision` candidates in the first Main Sequence block and the top of Anytime. Apply `hotfix` → `bug` → remainder first, then urgency and unblock breadth. Do not assume it must come from Main Sequence.

## Difficulty Estimates

Estimate implementation difficulty from the issue body, affected surface, integration risk, and verification burden:

- `easy`: narrow and well-specified; localized content, docs, mechanical edits, or a small fix with cheap focused verification.
- `medium`: spans several files or one subsystem; requires moderate design/integration work, careful edge cases, or multiple focused tests.
- `hard`: cross-cutting architecture, concurrency, persistence/save compatibility, worldgen/rendering, a large feature arc, substantial ambiguity, or expensive/high-risk verification.

Rate the work itself, not its urgency, priority, queue position, or time spent waiting on dependencies. For trackers, estimate the remaining epic scope. For deferred or `needs-decision` issues, estimate the likely implementation if approved. Choose exactly one rating for every issue; do not use ranges or `unknown`.

## Output Format

Keep the final answer short and terminal-readable. Use this shape:

````text
I refreshed GitHub for <owner>/<name>. Current open issue count: N.

Start with #NNN.

**Main Sequence**
```text
01. #NNN  Title ✓  [medium] [hotfix] [assigned: @octocat]
02. #NNN  Title  [easy] [bug]

03. #NNN  Title  [hard]
04. #NNN  Title  [medium]

05. #NNN  Title  [easy] [late; reason]
```

**Anytime List**
```text
A01. #NNN  Title ✓  [easy] [hotfix]
A02. #NNN  Title  [medium] [art task]
```

**Tracker Issues**
```text
T01. #NNN  Epic/tracker title ✓  [hard]
T02. #NNN  Epic/tracker title  [medium] [likely stale/update-or-close]
```
````

Important formatting rules:

- Name the resolved repository in the first line, exactly as step 1 resolved it. It is the only signal that the lists below came from the intended tracker.
- Use two-digit numbering in `Main Sequence`.
- Use `A01`, `A02` numbering in `Anytime List`.
- Use `T01`, `T02` numbering in `Tracker Issues`.
- Preserve issue numbers and concise titles.
- Append `✓` to every issue labeled `reviewed:approve`, immediately after its title and before bracket notes; do not mark unlabeled issues.
- Append exactly one difficulty marker, `[easy]`, `[medium]`, or `[hard]`, after the title/checkmark and before status or placement notes.
- Append `[assigned: @login]` for every assigned issue, listing all assignees when there is more than one. Also retain any applicable `[in-flight: PR #NNN]` and `[wip]` notes.
- Do not include URLs unless asked.
- Do not explain every placement; use bracket notes only when they materially affect work choice. In-flight status always does: `[in-flight: PR #NNN]` / `[assigned: @login]` / `[wip]` / `[needs-decision]`.
- Leave a blank line between main-sequence dependency groups. This is the user's stop sign.
- Do not leave blank lines merely for aesthetics.

## Sanity Checks

Before answering:

- Confirm all open issue numbers appear once across the three lists.
- Confirm every `reviewed:approve` issue has exactly one `✓`, and no issue without that label has one.
- Confirm every issue has exactly one valid difficulty marker.
- Confirm every issue with assignees lists every current assignee, every unassigned issue lacks an assignment note, and no assigned/in-flight issue is `Start with`.
- Confirm every Main Sequence issue participates in an open prerequisite/blocker chain or an explicit shared-file serialization; move standalone urgent work to Anytime.
- Confirm every blank line in `Main Sequence` means "do not proceed past this group until the previous group lands or unblocks," and is justified by an issue dependency or annotated shared-file barrier.
- Confirm the `hotfix` bucket precedes the `bug` bucket, which precedes the remainder, in Anytime and within each Main Sequence block. Confirm every rendered `[hotfix]`/`[bug]` note matches the exact current labels.
- Confirm no likely same-file pair is adjacent in Anytime when a similarly important, same-bucket non-conflicting alternative exists. Inspect at least the first five Anytime entries as a parallel batch and minimize repeated focus areas and touched paths.
- Confirm the first issue is a practical implementation issue, not an epic/tracker, unless the user explicitly asks to start with tracker cleanup.
- Confirm `Start with #NNN` is not in-flight (no open PR, no assignee, no `wip`), `needs-decision`, or blocked by an unresolved external prerequisite — it must be immediately startable by a fresh agent.
- If no GitHub access is available, say what could not be refreshed and organize only the issues the user supplied.
