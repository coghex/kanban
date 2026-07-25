---
name: issue-review
description: Run or inspect the canonical frontier-model, opposite-agent review for one numbered GitHub issue, posting its versioned spec comment and readiness label through the canonical issue-review backend. Use when the user invokes $issue-review or asks to review, approve, fact-check, or readiness-gate an issue before solving it.
---

# Review Issue

Use the canonical Python approver so manual reviews and the daemon produce the same provenance, structured comment, fingerprint, and labels. Do not independently post a competing review or set a verdict label.

1. Require one positive issue number.
2. Resolve the current repository root and the canonical backend. Kanban can review issues in any repository it is pointed at, so this backend is not necessarily tracked inside the repository under review; resolve the Kanban-managed install location the same way `Kanban.Review.canonicalIssueReviewerPath` does (`KANBAN_ISSUE_REVIEW_INSTALL_DIR` when set, otherwise `~/Library/Application Support/kanban/issue-review/approve_issues.py`) rather than a path relative to the repository being reviewed or any other personal path:

   ```bash
   BACKEND="${KANBAN_ISSUE_REVIEW_INSTALL_DIR:-$HOME/Library/Application Support/kanban/issue-review}/approve_issues.py"
   python3 "$BACKEND" \
     --path "$(git rev-parse --show-toplevel)" \
     --review <issue> \
     --legacy-policy dual \
     --json
   ```

   If `$BACKEND` does not exist, stop and report: "Canonical issue reviewer was not found at $BACKEND. Run `python3 tools/install_issue_review.py` from the Kanban checkout to install it."
3. Do not pin a reviewer model, reasoning effort, or display name for this run. The backend owns reviewer selection: it routes `issue-origin:claude` to GPT-5.6-Sol xhigh, `issue-origin:codex` to Claude Fable 5 xhigh, and unmarked legacy issues to independent reviews by both. The model processes are read-only; Python alone posts the consolidated comment and switches `reviewed:approve` / `reviewed:changes`.
4. If the queue lock is held, report its structured owner exactly: background daemon or another single-issue review with issue number and PID. Do not call every owner "the daemon," and do not start a concurrent reviewer. Use `--check <issue>` only to report current gate state.
5. An INVALID result is intentionally fatal and never closes the issue. Both daemon and singular review paths send ntfy and open the same circuit breaker that blocks all new solve checks until recovery.
6. On `CHANGES_REQUESTED`, direct the issue through the `issue-rereview` workflow after reporting the result. Do not rerun the unchanged spec with `$issue-review`. That repair-and-rereview workflow is deliberately outside this bundle's packaged set; Kanban's own `docs/drafting-workflow-contract.md` records the boundary.
7. If a selected model fails, stop immediately without retry or substitution. A singular run sends ntfy directly; the managed daemon exits and its service sends the notice. Never apply a verdict label for the incomplete review.

Return the issue number, approval state, route, models, review comment URL when present, and any blocking reasons.
