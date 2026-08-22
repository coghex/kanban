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

1. Set `REPO` once, before any GitHub read, and use that one identity for every `gh` call below. It is set on exactly one of the two paths here, never left unset.

<!-- brand:claude -->
A supplied repository arrives in `$ARGUMENTS`, which Claude Code substitutes before the session reads this file. When it is non-empty, that identity is the target: take `REPO` from it and skip the resolution below.

```bash
REPO="$ARGUMENTS"
```
<!-- brand:codex -->
A supplied repository arrives in the prompt; Codex substitutes no argument placeholder. When the user named one, that identity is the target: take `REPO` from it and skip the resolution below.

```bash
REPO="<the owner/name the user named>"
```
<!-- /brand -->

Otherwise resolve it from the session's own checkout:

```bash
REPO_REMOTE="$(git remote get-url origin)"
REPO="$(gh repo view "$REPO_REMOTE" --json nameWithOwner --jq .nameWithOwner)"
```

Either path leaves `$REPO` holding one `owner/name` before the first `gh` call. Pass `-R "$REPO"` on every `gh` invocation below, and name that repository in the answer's first line. Without `-R`, `gh` targets whatever repository the session's working directory happens to be in, so an unnamed call silently triages the wrong tracker; reporting what was resolved is what catches a wrong resolution.

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
11. Verify approval readiness through the canonical backend, as **Approval Readiness** below specifies, and mark only confirmed-current approvals with `✓`. Put the marker immediately after the title and before any bracket note. This is display-only: it does not affect ordering, classification, in-flight status, or `Start with` eligibility.

## Approval Readiness

A raw approval label is a **candidate**, not proof. Canonical approval binds an issue to the fingerprint of its current specification through the latest `issue-review:v2` marker, and nothing removes the label when that specification then changes — so a label alone can advertise readiness against a specification no reviewer ever saw. Render `✓` only for an issue the canonical backend confirms is approved right now.

Which label that is belongs to the repository, not to this workflow. `reviewed:approve` is only the default: a repository may configure `workflow.approval_label` to something else, and a workflow that hard-coded the default would quietly reconcile nothing there and go on rendering the stale readiness this section exists to stop. So never name a candidate label here — ask the backend, which has already resolved the configured one, and read the label it reports back.

Resolve the backend's install location the same way `Kanban.Review.resolveCanonicalIssueReviewer` does rather than a path relative to the repository being triaged or any other personal path. The precedence is a non-empty `KANBAN_ISSUE_REVIEW_INSTALL_DIR`, then the backend path `tools/install_issue_review.py` recorded at a fixed location `--install-dir` cannot move, then — only when that record names none, which is how an installation predating the record looks — the directory the record itself lives in. That record has two locations, probed in one order on every platform: the XDG data directory's first, then `~/Library`'s. Whichever one exists is the installation, so no step here decides which platform it is on; when neither exists the XDG candidate supplies the answer and the diagnostic names both:

```bash
XDG_RECORD="$HOME/.local/share/kanban/issue-review/config.json"
[ -z "$XDG_DATA_HOME" ] || XDG_RECORD="$XDG_DATA_HOME/kanban/issue-review/config.json"
RECORD="$HOME/Library/Application Support/kanban/issue-review/config.json"
BACKEND="$(python3 - "$XDG_RECORD" "$RECORD" <<'PY'
import json, os, sys
from pathlib import Path

records = [Path(argument) for argument in sys.argv[1:]]
occupied = [candidate for candidate in records if os.path.lexists(candidate)]
record = occupied[0] if occupied else records[0]
consulted = str(record) if occupied else " and ".join(str(candidate) for candidate in records)
override = os.environ.get("KANBAN_ISSUE_REVIEW_INSTALL_DIR")
if override and override.strip():
    resolved = Path(override).expanduser() / "approve_issues.py"
else:
    if not occupied:
        document = {}
    else:
        try:
            document = json.loads(record.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise SystemExit(f"The install record at {record} is unreadable ({error}).")
    if not isinstance(document, dict):
        raise SystemExit(f"The install record at {record} is not a JSON object.")
    if "backend_path" not in document:
        resolved = record.parent / "approve_issues.py"
    else:
        recorded = document["backend_path"]
        if not isinstance(recorded, str) or not Path(recorded).is_absolute():
            raise SystemExit(f"The install record at {record} does not name an absolute backend_path: {recorded!r}.")
        resolved = Path(recorded)
if not resolved.is_file():
    raise SystemExit(f"Canonical issue reviewer was not found at {resolved} (consulted {consulted}). Run `python3 tools/install_issue_review.py` from the Kanban checkout, adding --install-dir if it belongs elsewhere.")
print(resolved)
PY
)"
```

Then reconcile every candidate in **one** invocation, passing no issue numbers so the backend selects them itself:

```bash
python3 "$BACKEND" --path "$(git rev-parse --show-toplevel)" --repo "$REPO" --reconcile-approvals --legacy-policy dual --json
```

Selection is the backend's because the candidate set is defined by the configured approval label it has already resolved, and because a set chosen before the lock could change before any decision runs. The returned document names that label in `approval_label`; use it when reporting, and treat every issue it reports as the complete candidate set.

One invocation, not one per issue: the backend takes the canonical approval lock at most once for the whole call, so a pass costs one process and one acquisition rather than one of each per candidate.

That mode calls no model, publishes no review comment, and manufactures no verdict. It removes an approval label that is not backed by a current matching `APPROVE` marker, and it does so under the same repository-wide approval lock every other canonical mutation takes, from a read taken after acquiring it. Never reimplement that removal as a bare `gh issue edit` here, and never use `--check` to mutate anything — `--check` is read-only by contract.

Read each entry of the returned document and render from it. Do **not** issue a second `--check` for an issue this document already answered; two separate calls reopen the read-then-decide window the lock exists to close.

| entry `outcome` | what it means | how to render |
|---|---|---|
| `current` | the label is backed by a current `APPROVE` marker | `✓` when `approved` is true; otherwise no `✓`, and report the entry's `reasons` |
| `removed` | the label was stale and the backend removed it | no `✓`; mark `[needs canonical review]` |
| `unlabeled` | the issue carries no approval label | no `✓` |
| `unverified` | nothing could be established | no `✓`; mark `[approval unverified]` and say why, from the entry's `detail` |

`current` with `approved` false is **not** a stale approval. The gate also refuses for reasons that leave the marker perfectly current — a blocking pipeline incident, an issue that is no longer open, or a present `reviewed:changes` label — and the backend deliberately mutates nothing in those cases. Report the entry's own `reasons`; do not describe such an issue as requiring canonical review.

**Fail closed.** A missing or unresolvable backend, a `"busy"` document from lock contention, a GitHub read or write failure, a malformed document, or an unverifiable post-mutation state each mean the same thing: render no `✓` for the affected issues, claim no successful removal, and mark each one `[approval unverified]` with the reason. Never fall back to reading the raw label as readiness, and never present an unverified issue as ready to solve.

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
- Append `✓` only to an issue the canonical backend confirmed approved right now, immediately after its title and before bracket notes. A raw approval label never earns one on its own, whatever the repository configured it to be; see **Approval Readiness**.
- Append exactly one difficulty marker, `[easy]`, `[medium]`, or `[hard]`, after the title/checkmark and before status or placement notes.
- Append `[assigned: @login]` for every assigned issue, listing all assignees when there is more than one. Also retain any applicable `[in-flight: PR #NNN]` and `[wip]` notes.
- Do not include URLs unless asked.
- Do not explain every placement; use bracket notes only when they materially affect work choice. In-flight status always does: `[in-flight: PR #NNN]` / `[assigned: @login]` / `[wip]` / `[needs-decision]`.
- Leave a blank line between main-sequence dependency groups. This is the user's stop sign.
- Do not leave blank lines merely for aesthetics.

## Sanity Checks

Before answering:

- Confirm all open issue numbers appear once across the three lists.
- Confirm every `✓` is backed by a reconciliation entry whose `approved` is true, and that no issue carries one on the strength of its label alone.
- Confirm every candidate the backend reported as `removed` or `unverified` is rendered without `✓` and carries its `[needs canonical review]` or `[approval unverified]` note, and that no such issue is presented as ready to solve or chosen as `Start with`.
- Confirm every issue has exactly one valid difficulty marker.
- Confirm every issue with assignees lists every current assignee, every unassigned issue lacks an assignment note, and no assigned/in-flight issue is `Start with`.
- Confirm every Main Sequence issue participates in an open prerequisite/blocker chain or an explicit shared-file serialization; move standalone urgent work to Anytime.
- Confirm every blank line in `Main Sequence` means "do not proceed past this group until the previous group lands or unblocks," and is justified by an issue dependency or annotated shared-file barrier.
- Confirm the `hotfix` bucket precedes the `bug` bucket, which precedes the remainder, in Anytime and within each Main Sequence block. Confirm every rendered `[hotfix]`/`[bug]` note matches the exact current labels.
- Confirm no likely same-file pair is adjacent in Anytime when a similarly important, same-bucket non-conflicting alternative exists. Inspect at least the first five Anytime entries as a parallel batch and minimize repeated focus areas and touched paths.
- Confirm the first issue is a practical implementation issue, not an epic/tracker, unless the user explicitly asks to start with tracker cleanup.
- Confirm `Start with #NNN` is not in-flight (no open PR, no assignee, no `wip`), `needs-decision`, or blocked by an unresolved external prerequisite — it must be immediately startable by a fresh agent.
- If no GitHub access is available, say what could not be refreshed and organize only the issues the user supplied.
