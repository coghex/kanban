---
name: pr-rereview
description: Rerun the canonical review for a changed GitHub pull request, preserving either its standalone PR contract or its linked-issue gate, verifying prior blockers, and routing known solver origins to the opposite-brand reviewer or unknown origins to both Codex and Claude. Use when asked to re-review a PR.
---

# Rereview Pull Request

Require one positive PR number. Read and follow the complete `$pr-review` policy — including its self-review protocol and the `--self-review-as codex` declaration gating it, which holds only where Kanban spawned this session as the canonical opposite-brand reviewer rather than on the pull request's own origin brand — then use its bundled coordinator in rereview mode. Kanban spawns this workflow with the *reviewed* repository as the working directory, not this plugin's own install location, so locate the installed coordinator by searching under `$CODEX_HOME` (default `~/.codex`) rather than a path relative to the current directory:

```bash
COORDINATOR="$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" -path '*/kanban/*/skills/pr-review/scripts/review_pr.py' 2>/dev/null | head -n1)"
python3 "$COORDINATOR" \
  --path "$(git rev-parse --show-toplevel)" \
  --rereview <pr> \
  --self-review \
  --self-review-as codex \
  --allow-no-issue \
  --json
```

Do not independently comment, label, or compensate for the coordinator's result.

The standalone allowance preserves a prior no-issue review contract; it does not bypass linked-issue review. If the PR has any closing-issue references, the same freshness-aware issue gate validates every link before reviewing. A blocked gate invokes no review and idempotently posts only `Issue has not been approved.` with its hidden gate marker; changes no `reviewed:*` label. Exit status 2 is the expected blocked result.

Require a prior authenticated-user `pr-review:v1` or `pr-review:v2` comment before rereviewing — the coordinator enforces this itself.

Read the returned `"status"`, exactly as in `$pr-review`:

- `"blocked"`: stop, per the gate above.
- `"self_review_refused"`: this session's declared brand is not the reviewer this pull request routes to, so it is running on the PR's own origin brand and may not review it. Nothing was published and no label changed. Rerun the same command with both `--self-review` and `--self-review-as` dropped, so the coordinator spawns the opposite-brand reviewer itself; never review it yourself instead.
- `"awaiting_self_review"` (the normal known-origin case): read `"instructions"` completely. It gives you the prior comments and requires you to verify every previous blocker against the current head as well as inspect the complete current change for regressions and new blockers. Perform the rereview yourself, write your result as a JSON file matching the given schema, then publish it:

  ```bash
  python3 "$COORDINATOR" \
    --path "$(git rev-parse --show-toplevel)" \
    --publish-verdict <pr> \
    --expected-head <result.expected_head> \
    --gate-key <result.gate_key> \
    --result <path-to-your-result.json> \
    --allow-no-issue \
    --json
  ```

  `--publish-verdict` re-verifies the head and issue gate are still exactly what `--self-review` captured before accepting your verdict.

- `"reviewed"`: the coordinator already spawned and published a dual rereview (unknown/external origin only; Kanban's own invocation never routes here). Dual rereview approval must be unanimous.

Neither a specific model nor reasoning effort is pinned or verified anywhere in this flow; for the normal self-reviewed case the reviewer identity is exactly this session, the one Kanban's own invocation already selected and configured. Only the coordinator publishes the consolidated `pr-review:v2` verdict and switches exactly one matching `reviewed:*` label, after stable-head and current-issue-gate checks. An approving rereview also marks a draft PR ready for review and verifies that transition; changes requested leaves draft state untouched.

After the coordinator publishes, remove `reviewed:revised` if it is still present on the PR (`gh pr edit <pr> --remove-label reviewed:revised`); Kanban's label state machine routes a PR back through rereview while that label lingers, and removing it is the one label mutation a review-only workflow is required to make.

Return the PR number, origin or unknown status, issue-gate evidence, reviewer route, verdict, reviewed head, prior-concern status and new blockers, comment URL/status, label state, and ready-for-review state.
