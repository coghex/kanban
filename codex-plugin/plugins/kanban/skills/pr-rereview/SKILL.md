---
name: pr-rereview
description: Rerun the canonical issue-gated review for a changed GitHub pull request, verifying prior blockers and routing known solver origins to the opposite-brand reviewer or unknown origins to both Codex and Claude. Use when asked to re-review a PR.
---

# Rereview Pull Request

Require one positive PR number. Read and follow the complete `$pr-review` policy, then use its bundled coordinator in rereview mode. Kanban spawns this workflow with the *reviewed* repository as the working directory, not this plugin's own install location, so locate the installed coordinator by searching under `$CODEX_HOME` (default `~/.codex`) rather than a path relative to the current directory:

```bash
COORDINATOR="$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" -path '*/kanban/*/skills/pr-review/scripts/review_pr.py' 2>/dev/null | head -n1)"
python3 "$COORDINATOR" \
  --path "$(git rev-parse --show-toplevel)" \
  --rereview <pr> \
  --json
```

Do not independently review, comment, label, retry a failed model, or compensate for the coordinator's result.

The same freshness-aware issue gate runs before reviewers. A blocked gate invokes no model, changes no `reviewed:*` label, and idempotently posts only `Issue has not been approved.` with its hidden gate marker.

Require a prior authenticated-user `pr-review:v1` or `pr-review:v2` comment before rereviewing. Give the selected canonical reviewer or reviewers the prior comments and require them to verify every previous blocker against the current head as well as inspect the complete current change for regressions and new blockers.

Use the same origin routing as `$pr-review`: Claude origin routes to the Codex reviewer, Codex origin routes to the Claude reviewer, and unknown or unreliable origin routes independently to both. Neither a specific model nor reasoning effort is pinned or verified; only the brand is selected. Dual rereview approval must be unanimous. Only the coordinator publishes the consolidated `pr-review:v2` verdict and switches exactly one matching `reviewed:*` label after stable-head and current-issue-gate checks.

After the coordinator publishes, remove `reviewed:revised` if it is still present on the PR (`gh pr edit <pr> --remove-label reviewed:revised`); Kanban's label state machine routes a PR back through rereview while that label lingers, and removing it is the one label mutation a review-only workflow is required to make.

Return the PR number, origin or unknown status, issue-gate evidence, reviewer route, verdict, reviewed head, prior-concern status and new blockers per reviewer, comment URL/status, and label state.
