---
name: issue-review
<!-- brand:claude -->
description: Run the canonical opposite-agent frontier review and readiness gate for one existing GitHub issue — not drafting (use {{cmd:issue}}). Use only when the user invokes {{cmd:issue-review}} or explicitly asks to review, approve, fact-check, or readiness-gate an issue before solving it.
<!-- brand:codex -->
description: Run or inspect the canonical frontier-model, opposite-agent review for one numbered GitHub issue, posting its versioned spec comment and readiness label through the canonical issue-review backend. It does not draft or create issues (use {{cmd:issue}}). Use when the user invokes {{cmd:issue-review}} or asks to review, approve, fact-check, or readiness-gate an issue before solving it.
<!-- /brand -->
argument-hint: "[issue number]"
---

<!-- brand:claude -->
Require one positive issue number in `$ARGUMENTS`. Use the canonical approver rather than independently commenting or setting labels, so manual reviews and the managed daemon produce the same provenance, structured comment, fingerprint, and labels.
<!-- brand:codex -->
# Review Issue

Use the canonical Python approver so manual reviews and the daemon produce the same provenance, structured comment, fingerprint, and labels. Do not independently post a competing review or set a verdict label.
<!-- /brand -->

Run this in a **Class S** session (see the `model-classes` skill).
<!-- brand:codex -->

## Resolving The Canonical Backend
<!-- /brand -->

Kanban can work issues in any repository it is pointed at, so the canonical issue-review backend is not necessarily tracked inside the repository under review; resolve its install location the same way `Kanban.Review.resolveCanonicalIssueReviewer` does rather than a path relative to the repository being worked or any other personal path. The precedence is a non-empty `KANBAN_ISSUE_REVIEW_INSTALL_DIR`, then the backend path `tools/install_issue_review.py` recorded at a fixed location `--install-dir` cannot move, then — only when that record names none, which is how an installation predating the record looks — the directory the record itself lives in. That record has two locations, probed in one order on every platform: the XDG data directory's first, then `~/Library`'s. Whichever one exists is the installation, so no step here decides which platform it is on; when neither exists the XDG candidate supplies the answer and the diagnostic names both:

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

If that command fails or leaves `$BACKEND` empty, stop and report exactly the message it printed: it names the record or records that were consulted and the repair for that specific failure, which is not always the bare installer command.

<!-- brand:claude -->
With `$BACKEND` resolved, run the review:
<!-- brand:codex -->
## Steps
<!-- /brand -->

<!-- brand:claude -->
```bash
python3 "$BACKEND" \
  --path "$(git rev-parse --show-toplevel)" \
  --review <issue> \
  --legacy-policy dual \
  --json
```
<!-- brand:codex -->
1. Require one positive issue number.
2. Resolve the current repository root, and `$BACKEND` exactly as "Resolving The Canonical Backend" above specifies:
<!-- /brand -->

<!-- brand:claude -->
If `$BACKEND` does not exist, stop and report: "Canonical issue reviewer was not found at $BACKEND. Run `python3 tools/install_issue_review.py` from the Kanban checkout to install it."

Do not pin a reviewer model, reasoning effort, or display name for this run. The backend owns reviewer selection: it routes `issue-origin:claude` to the roster's Codex `issue_gate` assignment, `issue-origin:codex` to the roster's Claude `issue_gate` assignment, and unmarked legacy issues to independent reviews by both. The model processes are read-only; Python alone posts the versioned consolidated comment and switches `reviewed:approve` / `reviewed:changes`.

1. If the queue lock is held, report its structured owner exactly: background daemon or another single-issue review with issue number and PID. Do not call every owner "the daemon," and do not start a concurrent reviewer. Use `--check <issue>` only to report current gate state.
2. An INVALID result is intentionally fatal and never closes the issue. Both daemon and singular review paths send ntfy and open the same circuit breaker, which blocks new solve checks for the issue the incident names until recovery. Other issues keep their ordinary verdict and the daemon keeps approving them. An incident of indeterminate scope — one written before incidents recorded an issue number, or whose `issue` field is not a positive integer — still halts every check in the repository and refuses the daemon's start.
3. On `CHANGES_REQUESTED`, report the result and direct the issue through `{{cmd:issue-rereview}} <issue>`. Do not rerun the unchanged spec with `{{cmd:issue-review}}`. That repair-and-rereview workflow is this bundle's own packaged command; Kanban's `docs/drafting-workflow-contract.md` declares it and keeps the readiness gate separate from repair.
4. If a selected model fails, stop immediately without retry or substitution. A singular run sends ntfy directly; the managed daemon exits and its service sends the notice. Never apply a verdict label for an incomplete review.
<!-- brand:codex -->
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
7. On `CHANGES_REQUESTED`, direct the issue through `{{cmd:issue-rereview}} <issue>` after reporting the result. Do not rerun the unchanged spec with `{{cmd:issue-review}}`. That repair-and-rereview workflow is this bundle's own packaged skill; Kanban's `docs/drafting-workflow-contract.md` declares it and keeps the readiness gate separate from repair.
8. If a selected model fails, stop immediately without retry or substitution. A singular run sends ntfy directly; the managed daemon exits and its service sends the notice. Never apply a verdict label for the incomplete review.
<!-- /brand -->

Return the issue number, approval state, route, models, review comment URL when present, and any blocking reasons.
