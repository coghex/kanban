---
description: Run the canonical opposite-agent frontier review and readiness gate for one GitHub issue
argument-hint: "[issue number]"
---

Require one positive issue number in `$ARGUMENTS`. Use the canonical approver rather than independently commenting or setting labels, so manual reviews and the managed daemon produce the same provenance, structured comment, fingerprint, and labels.

Kanban can work issues in any repository it is pointed at, so the canonical issue-review backend is not necessarily tracked inside the repository under review; resolve its install location the same way `Kanban.Review.resolveCanonicalIssueReviewer` does rather than a path relative to the repository being worked or any other personal path. The precedence is a non-empty `KANBAN_ISSUE_REVIEW_INSTALL_DIR`, then the backend path `tools/install_issue_review.py` recorded at a fixed location `--install-dir` cannot move, then — only when that record names none, which is how an installation predating the record looks — the directory the record itself lives in:

```bash
RECORD="$HOME/Library/Application Support/kanban/issue-review/config.json"
BACKEND="$(python3 - "$RECORD" <<'PY'
import json, os, sys
from pathlib import Path

record = Path(sys.argv[1])
override = os.environ.get("KANBAN_ISSUE_REVIEW_INSTALL_DIR")
if override and override.strip():
    resolved = Path(override).expanduser() / "approve_issues.py"
else:
    try:
        document = json.loads(record.read_text(encoding="utf-8"))
    except FileNotFoundError:
        document = {}
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"The install record at {record} is unreadable ({error}).")
    if not isinstance(document, dict):
        raise SystemExit(f"The install record at {record} is not a JSON object.")
    recorded = document.get("backend_path")
    if recorded is None:
        resolved = record.parent / "approve_issues.py"
    elif isinstance(recorded, str) and Path(recorded).is_absolute():
        resolved = Path(recorded)
    else:
        raise SystemExit(f"The install record at {record} names a backend_path that is not absolute: {recorded!r}.")
if not resolved.is_file():
    raise SystemExit(f"Canonical issue reviewer was not found at {resolved} (consulted {record}). Run `python3 tools/install_issue_review.py` from the Kanban checkout, adding --install-dir if it belongs elsewhere.")
print(resolved)
PY
)"
```

If that command fails or leaves `$BACKEND` empty, stop and report exactly the message it printed: it names the record that was consulted and the repair for that specific failure, which is not always the bare installer command.

With `$BACKEND` resolved, run the review:

```bash
python3 "$BACKEND" \
  --path "$(git rev-parse --show-toplevel)" \
  --review <issue> \
  --legacy-policy dual \
  --json
```

Do not pin a reviewer model, reasoning effort, or display name for this run. The backend owns reviewer selection: it routes `issue-origin:claude` to GPT-5.6-Sol xhigh, `issue-origin:codex` to Claude Fable 5 xhigh, and unmarked legacy issues to independent reviews by both. The model processes are read-only; Python alone posts the versioned consolidated comment and switches `reviewed:approve` / `reviewed:changes`.

1. If the queue lock is held, report its structured owner exactly: background daemon or another single-issue review with issue number and PID. Do not call every owner "the daemon," and do not start a concurrent reviewer. Use `--check <issue>` only to report current gate state.
2. An INVALID result is intentionally fatal and never closes the issue. Both daemon and singular review paths send ntfy and open the same circuit breaker that blocks all new solve checks until recovery.
3. On `CHANGES_REQUESTED`, report the result and direct the issue through the `issue-rereview` workflow. Do not rerun the unchanged spec with `/issue-review`. That repair-and-rereview workflow is deliberately outside this bundle's packaged set; Kanban's own `docs/drafting-workflow-contract.md` records the boundary.
4. If a selected model fails, stop immediately without retry or substitution. A singular run sends ntfy directly; the managed daemon exits and its service sends the notice. Never apply a verdict label for an incomplete review.

Return the issue number, approval state, route, models, review comment URL when present, and any blocking reasons.
