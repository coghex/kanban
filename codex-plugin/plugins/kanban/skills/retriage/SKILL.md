---
name: retriage
description: Update an existing GitHub issue roadmap after issues have been added, closed, merged, or changed. Use when the user invokes $retriage or asks to refresh, revise, redisplay, or edit a prior $triage list without rebuilding from scratch, preserving dependency-barrier blank lines, the main sequence, anytime list, and tracker list.
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

Update a previously produced $triage roadmap. Prefer minimal, stable
edits over a full re-sort.

Use the existing list from the conversation, or a list pasted by the user.
If no previous list is available, fall back to the full $triage workflow
and say that no prior list was available to preserve.

**This workflow renders nothing of its own.** The roadmap's visual contract,
its `[hotfix]` and `[bug]` priority markers, its difficulty marker, and its
`✓` approval marker are governed by $triage's **Output Format** and
**Approval Readiness** sections. Read both and apply them as written. What
follows states only what a refresh does differently, and deliberately keeps no
second copy of those rules — a copy is what drifts, and a roadmap rendered
from a drifted copy silently un-does what the last $triage decided.

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
gh issue list -R "$REPO" --limit 500 --state open --json number,title,labels,assignees,body,createdAt,updatedAt,url
```

4. Pull open PRs and refresh in-flight status:

```bash
gh pr list -R "$REPO" --state open --limit 100 --json number,title,body
```

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

    Estimate and place every new issue by $triage's rules rather than by
    a rubric of this workflow's own.

11. Renumber all sections after edits.

12. Verify every current open issue appears exactly once across the three output lists.

## Refreshing Approval Markers

A refresh is where a stale approval marker does its damage. The roadmap being
edited already carries markers, and carrying them forward re-asserts a
readiness nothing has confirmed since — against a specification no reviewer
saw. So every marker in the answer is recomputed on this run. None is copied
from the previous roadmap, and none is read off an issue's labels.

$triage's **Approval Readiness** section is the whole rule: which label
is a candidate rather than proof, what each reconciliation `outcome` renders
as, and why a candidate label never earns a marker on its own. Read it and
apply it as written; this section adds only the two things a refresh needs on
top of it.

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

One invocation, not one per issue: the backend takes the canonical approval lock at most once for the whole call, and selection is its own because only it has resolved the configured `approval_label`. The returned document names that label; use it when reporting, and treat every issue it reports as the complete candidate set. Do not follow it with a per-issue `--check` for an issue it already answered — two separate calls reopen the read-then-decide window the lock exists to close.

Render each entry exactly as $triage's outcome table prescribes,
including its `[needs canonical review]` and `[approval unverified]` notes. The
refresh-specific consequence is subtraction: strip any marker the previous
roadmap carried for an issue this document does not report as approved right
now, and say so in the `Delta` line when the user asked what changed.

**Fail closed.** A missing or unresolvable backend, a `"busy"` document from
lock contention, a GitHub read or write failure, a malformed document, or an
unverifiable post-mutation state each mean what that section says they mean:
render no approval marker for the affected issues, claim no successful
removal, and mark each one `[approval unverified]` with the reason. The
previous roadmap's marker is not a fallback — a run that could not verify
drops it rather than carrying it, and never presents an unverified issue as
ready to solve.

## Blank-Line Rules

A blank line inside `Main Sequence` is $triage's dependency barrier, and
a refresh has to keep it meaning that.

Insert one only when the next block depends on the prior block being complete
or unblocked. Remove one when the dependency that justified it has been
satisfied by a closed issue. Never add or keep one for visual grouping, and
never leave one stranded above a block whose prerequisite has landed.

## Output Format

The refreshed roadmap is rendered in $triage's **Output Format**: the
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

Before answering, apply $triage's own **Sanity Checks** to the refreshed
lists — they hold unchanged — and then these, which are about the refresh
itself:

- Confirm the answer's first line names the repository step 1 resolved, and
  that the same identity was echoed to the user before step 5 ran.
- Confirm every `gh` call this run made carried `-R "$REPO"`.
- Confirm every previously listed issue that is now closed or otherwise not
  open is removed.
- Confirm no approval marker was carried over: every one in the answer traces
  to an entry of this run's reconciliation document, and every issue that
  document did not report as approved right now has lost the marker it had.
- Confirm every retained issue kept its previous relative position unless a
  rule in step 8 moved it, and that a difficulty estimate changed only where
  the issue's body or scope changed materially.
- Confirm new issues were read from their bodies, not placed by title alone.
- Confirm every blank line in `Main Sequence` is still a real dependency
  barrier after the edits.
