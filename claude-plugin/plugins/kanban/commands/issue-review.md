---
description: Run the canonical opposite-agent frontier review and readiness gate for one GitHub issue
argument-hint: "[issue number]"
---

Require one positive issue number in `$ARGUMENTS`. Use the canonical approver rather than independently commenting or setting labels, so manual reviews and the managed daemon produce the same provenance, structured comment, fingerprint, and labels.

Kanban can review issues in any repository it is pointed at, so this backend is not necessarily tracked inside the repository under review; resolve the Kanban-managed install location the same way `Kanban.Review.canonicalIssueReviewerPath` does (`KANBAN_ISSUE_REVIEW_INSTALL_DIR` when set, otherwise `~/Library/Application Support/kanban/issue-review/approve_issues.py`) rather than a path relative to the repository being reviewed or any other personal path:

```bash
BACKEND="${KANBAN_ISSUE_REVIEW_INSTALL_DIR:-$HOME/Library/Application Support/kanban/issue-review}/approve_issues.py"
python3 "$BACKEND" \
  --path "$(git rev-parse --show-toplevel)" \
  --review <issue> \
  --legacy-policy dual \
  --json
```

If `$BACKEND` does not exist, stop and report: "Canonical issue reviewer was not found at $BACKEND. Run `python3 tools/install_issue_review.py` from the Kanban checkout to install it."

Do not pin a reviewer model, reasoning effort, or display name for this run. The backend owns reviewer selection: it routes `issue-origin:claude` to GPT-5.6-Sol xhigh, `issue-origin:codex` to Claude Fable 5 xhigh, and unmarked legacy issues to independent reviews by both. The model processes are read-only; Python alone posts the versioned consolidated comment and switches `reviewed:approve` / `reviewed:changes`.

1. If the queue lock is held, report its structured owner exactly: background daemon or another single-issue review with issue number and PID. Do not call every owner "the daemon," and do not start a concurrent reviewer. Use `--check <issue>` only to report current gate state.
2. An INVALID result is intentionally fatal and never closes the issue. Both daemon and singular review paths send ntfy and open the same circuit breaker that blocks all new solve checks until recovery.
3. On `CHANGES_REQUESTED`, report the result and direct the issue through the `issue-rereview` workflow. Do not rerun the unchanged spec with `/issue-review`. That repair-and-rereview workflow is deliberately outside this bundle's packaged set; Kanban's own `docs/drafting-workflow-contract.md` records the boundary.
4. If a selected model fails, stop immediately without retry or substitution. A singular run sends ntfy directly; the managed daemon exits and its service sends the notice. Never apply a verdict label for an incomplete review.

Return the issue number, approval state, route, models, review comment URL when present, and any blocking reasons.
