---
description: Rerun the canonical review for a changed GitHub pull request, preserving either its standalone PR contract or its linked-issue gate, verifying prior blockers, and routing known solver origins to the opposite-brand reviewer or unknown origins to both Codex and Claude. Use when asked to re-review a PR.
argument-hint: "[PR number]"
---

# Rereview Pull Request

Require one positive PR number in `$ARGUMENTS`. Read and follow the complete `/pr-review` policy — including its self-review protocol and the `--self-review-as claude` declaration gating it, which holds only where Kanban spawned this session as the canonical reviewer this pull request routes to — the opposite brand when the roster loads both providers, the sole loaded provider when it loads one — rather than on the pull request's own origin brand where nothing routes to it — then use its bundled coordinator in rereview mode:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py" \
  --path "$(git rev-parse --show-toplevel)" \
  --rereview <pr> \
  --self-review \
  --self-review-as claude \
  --allow-no-issue \
  --json
```

Do not independently comment, label, or compensate for the coordinator's result.

The standalone allowance preserves a prior no-issue review contract; it does not bypass linked-issue review. If the PR has any closing-issue references, the same freshness-aware issue gate validates every link before reviewing. A blocked gate invokes no review and idempotently posts only `Issue has not been approved.` with its hidden gate marker; changes no `reviewed:*` label. Exit status 2 is the expected blocked result.

A blocked gate is this coordinator working, not failing, and clearing it is the linked issue's own review workflow's job. There is one exception, and it is the user's to invoke rather than yours to choose: when the user has asked in this turn to review the pull request anyway, pass `--override-issue-gate` together with `--override-reason "<the reason the user gave>"`. Both halves are required — either flag alone returns `"status": "override_refused"` before anything is read, spawned, or published — and the reason is reproduced verbatim in the published review comment, so the bypass is never silent. It relaxes exactly one thing: that every linked issue carries a current canonical approval. An external or unparseable linked issue, and a pull request with no linked issue at all, still block. The review itself is unchanged: same opposite-brand route, same verdict, same labels, and the approval the drainer merges on. Never pass it on your own initiative, never to get past a gate you merely disagree with, and never with a reason you composed rather than one the user gave.

Require a prior authenticated-user `pr-review:v1` or `pr-review:v2` comment before rereviewing — the coordinator enforces this itself.

Read the returned `"status"`, exactly as in `/pr-review`:

- `"blocked"`: stop, per the gate above.
- `"override_refused"`: `--override-issue-gate` and `--override-reason` were not both supplied, so no override was in force and this pull request was not reviewed. Nothing was published and no label changed. Supply the missing half only if the user really did authorize bypassing the linked issue's approval in this turn; otherwise drop both and report the gate as blocking.
- `"no_agent_mode"`: this installation's model roster loads no provider, so the coordinator has no reviewer to route to and refused before reading the pull request. Nothing was published and no label changed, and no rerun of this command can change that. Stop and report it: adding a provider to the roster's `agents` list is the operator's decision, never this session's.
- `"self_review_refused"`: this session's declared brand is not the reviewer this pull request routes to, so it may not review it. Nothing was published and no label changed. Rerun the same command with both `--self-review` and `--self-review-as` dropped, so the coordinator spawns the routed reviewer itself — the opposite brand when the roster loads both providers, and the sole loaded provider when it loads one; never review it yourself instead. A declaration that MATCHES the routed reviewer is not refused: on a single-agent roster every pull request routes to the one loaded provider, so a matching `--self-review-as` is the normal path and returns `"awaiting_self_review"` even where that reviewer shares the pull request's own origin brand.
- `"awaiting_self_review"` (the normal known-origin case): read `"instructions"` completely. It gives you the prior comments and requires you to verify every previous blocker against the current head as well as inspect the complete current change for regressions and new blockers. Perform the rereview yourself, write your result as a JSON file matching the given schema, then publish it:

  ```bash
  python3 "${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py" \
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
