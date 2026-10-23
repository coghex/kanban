---
name: issue-review
description: Run or inspect the canonical frontier-model, opposite-agent review for one numbered GitHub issue, posting its versioned spec comment and readiness label through the canonical issue-review backend. It does not draft or create issues (use $issue). Use when the user invokes $issue-review or asks to review, approve, fact-check, or readiness-gate an issue before solving it.
---

# Review Issue

Use the canonical Python approver so manual reviews and the daemon produce the same provenance, structured comment, fingerprint, and labels. Do not independently post a competing review or set a verdict label.

Run this in a **Class S** session (see the `model-classes` skill).

## Resolving The Canonical Backend

Kanban can work issues in any repository it is pointed at, so the canonical issue-review backend is not necessarily tracked inside the repository under review; resolve its install location through this bundle's `resolve_issue_review_backend.py` rather than a path relative to the repository being worked or any other personal path. The precedence is a non-empty `KANBAN_ISSUE_REVIEW_INSTALL_DIR`, then the backend path `tools/install_issue_review.py` recorded at a fixed location `--install-dir` cannot move, then — only when that record names none, which is how an installation predating the record looks — the directory the record itself lives in. That record has two locations, probed in one order on every platform: the XDG data directory's first, then the macOS user Library directory's. Whichever one exists is the installation, so no step here decides which platform it is on; when neither exists the XDG candidate supplies the answer and the diagnostic names both.
The resolver ships in this skill's own `scripts/`, and the installed copy is located under `$CODEX_HOME` (default `~/.codex`) rather than by a path relative to the current directory, so a copy inside the repository being worked is never what runs:

```bash
RESOLVER="$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" -path '*/kanban/*/skills/issue-review/scripts/resolve_issue_review_backend.py' 2>/dev/null | head -n1)"
BACKEND="$(python3 "${RESOLVER:?resolve_issue_review_backend.py was not found under the installed Kanban plugin}")"
```

If that leaves `$RESOLVER` empty, or the resolver fails or leaves `$BACKEND` empty, stop and report exactly the message it printed: it names the record or records that were consulted and the repair for that specific failure, which is not always the bare installer command.

## Steps

1. Require one positive issue number.
2. Resolve the current repository root, and `$BACKEND` exactly as "Resolving The Canonical Backend" above specifies:

   ```bash
   python3 "$BACKEND" \
     --path "$(git rev-parse --show-toplevel)" \
     --review <issue> \
     --legacy-policy dual \
     --json
   ```
3. If `$BACKEND` does not exist, stop and report: "Canonical issue reviewer was not found at $BACKEND. Run `python3 tools/install_issue_review.py` from the Kanban checkout to install it."
4. Do not pin a reviewer model, reasoning effort, or display name for this run. The backend owns reviewer selection: it routes `issue-origin:claude` to the roster's Codex `issue_gate` assignment, `issue-origin:codex` to the roster's Claude `issue_gate` assignment, and unmarked legacy issues to independent reviews by both. The model processes are read-only; Python alone posts the consolidated comment and switches `reviewed:approve` / `reviewed:changes`.
5. If the queue lock is held, report its structured owner exactly: background daemon or another single-issue review with issue number and PID. Do not call every owner "the daemon," and do not start a concurrent reviewer. Use `--check <issue>` only to report current gate state.
6. An INVALID result is intentionally fatal and never closes the issue. Both daemon and singular review paths send ntfy and open the same circuit breaker, which blocks new solve checks for the issue the incident names until recovery. Other issues keep their ordinary verdict and the daemon keeps approving them. An incident of indeterminate scope — one written before incidents recorded an issue number, or whose `issue` field is not a positive integer — still halts every check in the repository and refuses the daemon's start.
7. On `CHANGES_REQUESTED`, direct the issue through `$issue-rereview <issue>` after reporting the result. Do not rerun the unchanged spec with `$issue-review`. That repair-and-rereview workflow is this bundle's own packaged skill; Kanban's `docs/drafting-workflow-contract.md` declares it and keeps the readiness gate separate from repair.
8. If a selected model fails, stop immediately without retry or substitution. A singular run sends ntfy directly; the managed daemon exits and its service sends the notice. Never apply a verdict label for the incomplete review.

Return the issue number, approval state, route, models, review comment URL when present, and any blocking reasons.
