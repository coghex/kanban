---
description: Run the canonical opposite-agent frontier review and readiness gate for one existing GitHub issue — not drafting (use /issue). Use only when the user invokes /issue-review or explicitly asks to review, approve, fact-check, or readiness-gate an issue before solving it.
argument-hint: "[issue number]"
---

Require one positive issue number in `$ARGUMENTS`. Use the canonical approver rather than independently commenting or setting labels, so manual reviews and the managed daemon produce the same provenance, structured comment, fingerprint, and labels.

Run this in a **Class S** session (see the `model-classes` skill).

Kanban can work issues in any repository it is pointed at, so the canonical issue-review backend is not necessarily tracked inside the repository under review; resolve its install location through this bundle's `resolve_issue_review_backend.py` rather than a path relative to the repository being worked or any other personal path. The precedence is a non-empty `KANBAN_ISSUE_REVIEW_INSTALL_DIR`, then the backend path `tools/install_issue_review.py` recorded at a fixed location `--install-dir` cannot move, then — only when that record names none, which is how an installation predating the record looks — the directory the record itself lives in. That record has two locations, probed in one order on every platform: the XDG data directory's first, then the macOS user Library directory's. Whichever one exists is the installation, so no step here decides which platform it is on; when neither exists the XDG candidate supplies the answer and the diagnostic names both.
The resolver ships in this plugin's `scripts/`, and Claude Code substitutes `${CLAUDE_PLUGIN_ROOT}` with that install location whatever directory the workflow runs from, so a copy inside the repository being worked is never what runs:

```bash
BACKEND="$(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/resolve_issue_review_backend.py")"
```

If that command fails or leaves `$BACKEND` empty, stop and report exactly the message it printed: it names the record or records that were consulted and the repair for that specific failure, which is not always the bare installer command.

With `$BACKEND` resolved, run the review:

```bash
python3 "$BACKEND" \
  --path "$(git rev-parse --show-toplevel)" \
  --review <issue> \
  --legacy-policy dual \
  --json
```

If `$BACKEND` does not exist, stop and report: "Canonical issue reviewer was not found at $BACKEND. Run `python3 tools/install_issue_review.py` from the Kanban checkout to install it."

Do not pin a reviewer model, reasoning effort, or display name for this run. The backend owns reviewer selection: it routes `issue-origin:claude` to the roster's Codex `issue_gate` assignment, `issue-origin:codex` to the roster's Claude `issue_gate` assignment, and unmarked legacy issues to independent reviews by both. The model processes are read-only; Python alone posts the versioned consolidated comment and switches `reviewed:approve` / `reviewed:changes`.

1. If the queue lock is held, report its structured owner exactly: background daemon or another single-issue review with issue number and PID. Do not call every owner "the daemon," and do not start a concurrent reviewer. Use `--check <issue>` only to report current gate state.
2. An INVALID result is intentionally fatal and never closes the issue. Both daemon and singular review paths send ntfy and open the same circuit breaker, which blocks new solve checks for the issue the incident names until recovery. Other issues keep their ordinary verdict and the daemon keeps approving them. An incident of indeterminate scope — one written before incidents recorded an issue number, or whose `issue` field is not a positive integer — still halts every check in the repository and refuses the daemon's start.
3. On `CHANGES_REQUESTED`, report the result and direct the issue through `/issue-rereview <issue>`. Do not rerun the unchanged spec with `/issue-review`. That repair-and-rereview workflow is this bundle's own packaged command; Kanban's `docs/drafting-workflow-contract.md` declares it and keeps the readiness gate separate from repair.
4. If a selected model fails, stop immediately without retry or substitution. A singular run sends ntfy directly; the managed daemon exits and its service sends the notice. Never apply a verdict label for an incomplete review.

Return the issue number, approval state, route, models, review comment URL when present, and any blocking reasons.
