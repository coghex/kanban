---
name: pr-rereview
description: Rerun the canonical review for a changed GitHub pull request, preserving either its standalone PR contract or its linked-issue gate, verifying prior blockers, and routing known solver origins to the opposite-brand reviewer or unknown origins to both Codex and Claude. Use when asked to re-review a PR.
argument-hint: "[PR number]"
---

# Rereview Pull Request

Run this in a **Class S** session (see the `model-classes` skill).

<!-- brand:claude -->
Require one positive PR number in `$ARGUMENTS`. This is `{{cmd:pr-review}}` run in the coordinator's rereview mode: read and follow the complete `{{cmd:pr-review}}` workflow, and apply the differences below where it says `--review`.
<!-- brand:codex -->
Require one positive PR number. This is `{{cmd:pr-review}}` run in the coordinator's rereview mode: read and follow the complete `{{cmd:pr-review}}` workflow, and apply the differences below where it says `--review`.
<!-- /brand -->

`{{cmd:pr-review}}` owns everything else, and none of it is restated here: the self-review protocol and the `--self-review-as` declaration that gates it, the issue approval gate with its `--override-issue-gate` and `--override-reason` pair, `--owner-directive`, every returned `"status"` and its recovery, and publication and verification. Where it says to carry a flag on both the briefing and the `--publish-verdict` call, that holds here too.

## What differs from a first review

<!-- brand:claude -->
Run the coordinator with `--rereview <pr>` instead of `--review <pr>`, and with `--allow-no-issue` on both the briefing and the publication:
<!-- brand:codex -->
Run the coordinator with `--rereview <pr>` instead of `--review <pr>`, and with `--allow-no-issue` on both the briefing and the publication. Locate the installed coordinator as `{{cmd:pr-review}}` does, by searching under `$CODEX_HOME` (default `~/.codex`):
<!-- /brand -->

```bash
<!-- brand:claude -->
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py" \
<!-- brand:codex -->
COORDINATOR="$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" -path '*/kanban/*/skills/pr-review/scripts/review_pr.py' 2>/dev/null | head -n1)"
python3 "$COORDINATOR" \
<!-- /brand -->
  --path "$(git rev-parse --show-toplevel)" \
  --rereview <pr> \
  --self-review \
<!-- brand:claude -->
  --self-review-as claude \
<!-- brand:codex -->
  --self-review-as codex \
<!-- /brand -->
  --allow-no-issue \
  --json
```

- **Prior review required.** A prior authenticated-user `pr-review:v1` or `pr-review:v2` comment must exist; the coordinator enforces this itself.
- **Standalone allowance.** `--allow-no-issue` preserves a prior no-issue review contract and does not bypass linked-issue review. If the PR has any closing-issue references, the same freshness-aware issue gate validates every link before reviewing, and a blocked gate behaves exactly as in `{{cmd:pr-review}}`.
- **Prior blockers.** For `"awaiting_self_review"`, `"instructions"` gives you the prior comments and requires you to verify every previous blocker against the current head as well as inspect the complete current change for regressions and new blockers. Perform the rereview yourself, then publish with the `{{cmd:pr-review}}` `--publish-verdict` call carrying `--allow-no-issue` as well:

  ```bash
<!-- brand:claude -->
  python3 "${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py" \
<!-- brand:codex -->
  python3 "$COORDINATOR" \
<!-- /brand -->
    --path "$(git rev-parse --show-toplevel)" \
    --publish-verdict <pr> \
    --expected-head <result.expected_head> \
    --gate-key <result.gate_key> \
    --result <path-to-your-result.json> \
    --expected-override <result.overridden_issues, comma-separated> \
    --allow-no-issue \
    --json
  ```

- **Dual rereview.** For `"reviewed"` (unknown or external origin only), approval must be unanimous.
- **`reviewed:revised`.** After the coordinator has published successfully, remove `reviewed:revised` if it is still present (`gh pr edit <pr> --remove-label reviewed:revised`); Kanban's label state machine routes a PR back through rereview while that label lingers, and removing it is the one label mutation a review-only workflow is required to make. A round that published nothing (blocked, refused, or failed) leaves the label alone.

Return what `{{cmd:pr-review}}` returns, with the prior-concern status and any new blockers in place of its blockers.
