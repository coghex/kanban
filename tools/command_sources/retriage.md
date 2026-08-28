---
name: retriage
description: Update an existing GitHub issue roadmap after issues have been added, closed, merged, or changed. Use when the user invokes {{cmd:retriage}} or asks to refresh, revise, redisplay, or edit a prior {{cmd:triage}} list without rebuilding from scratch, preserving dependency-barrier blank lines, the main sequence, anytime list, and tracker list.
argument-hint: "[optional: paste of the prior roadmap, if not in this conversation]"
---

# Retriage

## Where files go

This workflow reads the tracker through `gh`, reconciles approval markers
through the canonical backend, and drafts its answer in chat; it should not
write into the repository at all. If a step ever does need to write a file, put
it in the `docs-wip` worktree, never the primary checkout — uncommitted files
there are autostashed by the PR drainer's post-merge fast-forward and wedge it
when the restore conflicts. Resolve it by branch:

```bash
DOCS_WT="$(git worktree list --porcelain \
  | awk '/^worktree /{p=substr($0,10)} /^branch refs\/heads\/docs-wip$/{print p; exit}')"
[ -n "$DOCS_WT" ] || DOCS_WT="$(git rev-parse --show-toplevel)"
```

## Goal

Update a previously produced {{cmd:triage}} roadmap. Prefer minimal, stable
edits over a full re-sort.

<!-- brand:claude -->
Use the existing list from this conversation, or one pasted in (`$ARGUMENTS`).
<!-- brand:codex -->
Use the existing list from the conversation, or a list pasted by the user.
<!-- /brand -->
If no previous list is available, fall back to the full {{cmd:triage}} workflow
and say that no prior list was available to preserve.

**This workflow renders nothing of its own.** The roadmap's visual contract,
its `[hotfix]` and `[bug]` priority markers, its difficulty marker, and its
`✓` approval marker are governed by {{cmd:triage}}'s **Output Format** and
**Approval Readiness** sections. Read both and apply them as written. What
follows states only what a refresh does differently, and deliberately keeps no
second copy of those rules — a copy is what drifts, and a roadmap rendered
from a drifted copy silently un-does what the last {{cmd:triage}} decided.

## Workflow

1. Set `REPO` once, before the first GitHub read and before step 5 reconciles
   anything, and use that one identity for every `gh` call below. Without
   `-R`, `gh` targets whatever repository the session's working directory
   happens to be in, so an unnamed call silently refreshes the wrong tracker.

When the user named a repository in their request, that identity is the target.
Otherwise resolve it from the session's own checkout. Resolution reads the
remote and needs no GitHub call of its own, so there is no point in this
workflow at which an unscoped `gh` invocation is correct:

```bash
REPO="$(git remote get-url origin | sed -E 's#\.git$##; s#.*(/|:)([^/:]+/[^/:]+)$#\2#')"
```

Either path leaves `$REPO` holding one `owner/name` before the first `gh` call.
Echo it to the user before step 5 runs, because that step is this workflow's
only mutation and it can remove a label; name it again in the answer's first
line. Reporting what was resolved is what catches a wrong resolution — once
before anything changes, and once beside the lists it produced.

2. Extract issue numbers and sections from the previous roadmap:
   - `Main Sequence`
   - `Anytime List`
   - `Tracker Issues`
   - Existing difficulty estimates, and any `[hotfix]` or `[bug]` priority
     markers, when present

3. Pull current open GitHub issues:

```bash
gh issue list -R "$REPO" --limit "$ISSUE_LIMIT" --state open --json number,title,labels,assignees,body,createdAt,updatedAt,url
```

Step 6 computes every delta from this snapshot's `current_open_numbers` and step 12 verifies that every current open issue appears exactly once, so the snapshot has to be the whole open set rather than its newest page. Set and verify `$ISSUE_LIMIT` as **Complete Snapshots** below specifies, before computing a single delta.

4. Pull open PRs and refresh in-flight status:

```bash
gh pr list -R "$REPO" --state open --limit "$PR_LIMIT" --json number,title,body
```

An issue whose closing pull request fell outside this listing loses its `[in-flight: PR #NNN]` note and becomes eligible for `Start with`, which hands a second agent work already under way. Set and verify `$PR_LIMIT` the same way, before deciding that any issue is not in flight.

An issue referenced by an open PR's `Closes #<n>`, carrying one or more assignees, or labeled `wip` is **in-flight**. Keep it in place and show every applicable work signal: `[in-flight: PR #NNN]`, `[assigned: @login]` (include every assignee), and/or `[wip]`. Add, update, or remove these notes as current PRs, assignments, and labels change; never collapse an assignment into generic `[claimed]`. Never choose an in-flight or `needs-decision` issue as `Start with`.

5. Refresh every approval marker from the canonical backend, as **Refreshing
   Approval Markers** below specifies. Refresh the `[hotfix]` and `[bug]`
   priority markers from the labels step 3 returned at the same time, and
   re-order any bucket whose membership changed.

6. Compute deltas:
   - `closed_or_removed = previous_numbers - current_open_numbers`
   - `new_open = current_open_numbers - previous_numbers`
   - `retained = previous_numbers intersect current_open_numbers`

7. Remove closed/resolved issues from the previous list.

8. Preserve retained issues in their previous relative order unless:
   - a prerequisite was removed and the dependent block can move up,
   - an issue body now says it is blocked/deferred/phase-2,
   - a newly opened issue is an explicit prerequisite for it,
   - its priority bucket changed, which reorders it within its section.

   Preserve a retained issue's difficulty estimate unless its body or affected
   scope changed materially. If the previous roadmap predates difficulty
   markers, estimate every retained issue now.

9. Read bodies for all `new_open` issues and for any retained issue adjacent to a changed dependency. Use:

```bash
gh issue view -R "$REPO" <number> --json number,title,state,closedAt,body,labels
```

10. Insert new issues near their dependency context:
    - New urgent bugs or hardening issues go near the top of their bucket.
    - New children of an existing epic go into that epic's active sequence.
    - New phase-2 or optional issues go to `Anytime List` unless they are a
      required continuation.
    - New epics/umbrella issues go to `Tracker Issues`.
    - New standalone file-split or documentation tasks go to `Anytime List`.

    Estimate and place every new issue by {{cmd:triage}}'s rules rather than by
    a rubric of this workflow's own.

11. Renumber all sections after edits.

12. Verify every current open issue appears exactly once across the three output lists.

## Complete Snapshots

`gh` documents `--limit` as the maximum number of rows to fetch, and it returns
the newest first. A fixed number therefore drops the *oldest* rows, and it drops
them silently: a truncated listing is indistinguishable from a shorter tracker.
Every completeness claim this workflow makes is a claim about the listing it
read, so each listing has to be the whole collection — or the run has to say it
was not.

**A listing limit is never a constant.** Each snapshot listing above — the ones
a completeness claim rests on, not a bounded keyword search for one named issue
or pull request — carries its own limit variable, raised independently of any
other: `$ISSUE_LIMIT` for the open-issue listing, and `$PR_LIMIT` for an
open-pull-request listing where the workflow takes one. Start each at 500, which
reaches most trackers in one round trip, then check what came back against the
limit it was taken with:

- **Fewer rows than the limit** — that listing is the complete collection.
  `--limit` paginates for you, so a short listing is `gh` running out of rows,
  not out of budget.
- **Exactly the limit** — the listing may have been cut off at the cap. Double
  that variable, capped at 10000, and take the listing again.

Repeat until a listing comes back short.

**A completeness check succeeds before the snapshot it covers is used** — for
classification, batch selection, approval reconciliation, or any tracker
mutation. Whichever of those this workflow performs, none of them may read a
snapshot that has not passed, and a partial snapshot is never presented as
complete.

**Fail visibly.** If a listing errors, or still comes back full once its limit
variable has reached 10000, that collection was not read and this run cannot
make the completeness claim it owes. Stop, and name in the diagnostic the
repository `$REPO`, which collection is incomplete — the **open issues** or the
**open pull requests** — and the limit the last listing used. Do not fall back
to the partial snapshot, do not classify or select from what was read, and do
not present a roadmap or a batch as covering anything. This is a stop, not a
warning.

## Refreshing Approval Markers

A refresh is where a stale approval marker does its damage. The roadmap being
edited already carries markers, and carrying them forward re-asserts a
readiness nothing has confirmed since — against a specification no reviewer
saw. So every marker in the answer is recomputed on this run. None is copied
from the previous roadmap. Outside {{cmd:triage}}'s busy-lock fallback, none is
read off an issue's labels; during that fallback, label-backed markers are
recomputed from the verified-complete issue snapshot rather than carried over.

{{cmd:triage}}'s **Approval Readiness** section is the whole rule: which label
is normally a candidate rather than proof, what each reconciliation `outcome`
renders as, and why a top-level `busy` result is the one label-backed fallback.
Read it and apply it as written; this section adds only the two things a refresh
needs on top of it.

Resolve the backend's install location the same way `Kanban.Review.resolveCanonicalIssueReviewer` does rather than a path relative to the repository being retriaged or any other personal path. The precedence is a non-empty `KANBAN_ISSUE_REVIEW_INSTALL_DIR`, then the backend path `tools/install_issue_review.py` recorded at a fixed location `--install-dir` cannot move, then — only when that record names none, which is how an installation predating the record looks — the directory the record itself lives in. That record has two locations, probed in one order on every platform: the XDG data directory's first, then `~/Library`'s. Whichever one exists is the installation, so no step here decides which platform it is on; when neither exists the XDG candidate supplies the answer and the diagnostic names both:

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

One invocation, not one per issue: the backend takes the canonical approval lock at most once for the whole call, and selection is its own because only it has resolved the configured `approval_label`. A completed reconciliation names that label in `approval_label` and a busy one inside `busy_fallback`; use whichever it reports when reporting. For a completed reconciliation, treat every issue it reports as the complete candidate set. For a top-level `busy` result, use {{cmd:triage}}'s verified-snapshot fallback instead of treating the empty `issues` array as the candidate set. Do not follow either result with a per-issue `--check` — two separate calls reopen the read-then-decide window the lock exists to close.

Render each entry exactly as {{cmd:triage}}'s outcome table prescribes,
including its `[needs canonical review]` and `[approval unverified]` notes. For
a completed reconciliation, the refresh-specific consequence is subtraction:
strip any marker the previous roadmap carried for an issue this document does
not report as approved right now. For a top-level `busy` result, strip the old
markers and then recompute them from the snapshot exactly as {{cmd:triage}}'s
busy-lock fallback prescribes, over both configured labels that document
reports. Include {{cmd:triage}}'s required one-time busy-disclosure sentence
immediately after the repository/count line regardless of whether the user
asked for a delta. When the user did ask what changed, also describe the marker
recomputation in the `Delta` line.

**Busy lock.** Apply {{cmd:triage}}'s busy-lock fallback exactly: the current
snapshot's labels, not the previous roadmap's marker, supply each `✓` — both
the approval label that earns one and the changes-requested label that
withholds it; do not retry, do not add `[approval unverified]` merely because
the lock is busy, and claim no successful reconciliation or stale-label
removal. Its mandatory one-time disclosure is part of the fallback, even when
no delta was requested.

**Fail closed outside the busy fallback.** A missing or unresolvable backend,
a GitHub read or write failure, a malformed document, an invalid or missing
`busy_fallback` or either label inside it in a busy document, or an
unverifiable post-mutation state means what {{cmd:triage}} says it means:
render no approval marker for the affected issues, claim no successful removal,
and mark each one `[approval unverified]` with the reason. The previous
roadmap's marker is not a fallback — a run that could not verify drops it rather
than carrying it, and never presents an unverified issue as ready to solve.

## Blank-Line Rules

A blank line inside `Main Sequence` is {{cmd:triage}}'s dependency barrier, and
a refresh has to keep it meaning that.

Insert one only when the next block depends on the prior block being complete
or unblocked. Remove one when the dependency that justified it has been
satisfied by a closed issue. Never add or keep one for visual grouping, and
never leave one stranded above a block whose prerequisite has landed.

## Output Format

The refreshed roadmap is rendered in {{cmd:triage}}'s **Output Format**: the
same three sections, the same numbering, the same marker order, the same
repository named in the first line. A refresh changes what is in the lists,
never their shape.

One thing a refresh has that a first pass does not. If the user asks what
changed, add a short `Delta` line before the lists:

```text
Delta: removed #123/#124, added #130/#131, moved #140 after #139, dropped the approval marker on #128.
```

Do not add the delta by default; the default output is just the refreshed
working list. Do not include URLs unless asked.

## Sanity Checks

Before answering, apply {{cmd:triage}}'s own **Sanity Checks** to the refreshed
lists — they hold unchanged — and then these, which are about the refresh
itself:

- Confirm the answer's first line names the repository step 1 resolved, and
  that the same identity was echoed to the user before step 5 ran.
- Confirm every `gh` call this run made carried `-R "$REPO"`.
- Confirm both listings passed their completeness check before step 5 reconciled
  anything and before any delta was computed, and that no list here was built from
  a snapshot that did not pass.
- Confirm every previously listed issue that is now closed or otherwise not
  open is removed.
- Confirm no approval marker was carried over: every one in the answer was
  recomputed from either an approved entry in this run's reconciliation
  document or, only for a top-level `busy` result, an exact current-snapshot
  match under {{cmd:triage}}'s busy-lock fallback, read off both labels that
  document reports; every other prior marker was removed.
- For a top-level `busy` result, confirm the answer includes {{cmd:triage}}'s
  required busy-disclosure sentence exactly once immediately after the
  repository/count line, even when the user did not request a delta.
- Confirm every retained issue kept its previous relative position unless a
  rule in step 8 moved it, and that a difficulty estimate changed only where
  the issue's body or scope changed materially.
- Confirm new issues were read from their bodies, not placed by title alone.
- Confirm every blank line in `Main Sequence` is still a real dependency
  barrier after the edits.
