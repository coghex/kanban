---
name: pr-review
description: Run the canonical issue-gated review for one GitHub pull request, routing known solver origins to the opposite-brand reviewer and unknown or external origins to independent Codex and Claude reviews, then publish one consolidated verdict. Use when asked to review a PR.
---

# Review Pull Request

Require one positive PR number. Kanban already spawned this session as the canonical opposite-brand reviewer — its own CLI invocation pinned this session's model before this workflow ever ran — so for the normal known-origin case you perform the review yourself; the bundled coordinator only handles safe publication. Do not independently comment, label, or compensate for the coordinator's result.

Kanban spawns this workflow with the *reviewed* repository as the working directory, not this plugin's own install location, so locate the installed coordinator by searching under `$CODEX_HOME` (default `~/.codex`) rather than a path relative to the current directory:

```bash
COORDINATOR="$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" -path '*/kanban/*/skills/pr-review/scripts/review_pr.py' 2>/dev/null | head -n1)"
python3 "$COORDINATOR" \
  --path "$(git rev-parse --show-toplevel)" \
  --review <pr> \
  --self-review \
  --json
```

## Issue approval gate

The coordinator resolves GitHub closing-issue references before inspecting PR provenance. Every linked issue must belong to the current repository and pass the canonical freshness-aware `approve_issues.py --check`; a `reviewed:approve` label alone is insufficient. No linked issue, an external linked issue, or any non-approved linked issue blocks review.

For a blocked gate (`"status": "blocked"`), the coordinator has already posted the idempotent `Issue has not been approved.` comment with its hidden `pr-review-gate:v1` marker and changed no `reviewed:*` label. Exit status 2 is the expected blocked result; stop.

## Reviewer route and self-review

Read the returned `"status"`:

- `"blocked"`: stop, per the gate section above.
- `"awaiting_self_review"`: this is the normal known-origin case (exactly one reviewer route). Read `"instructions"` completely — it contains the full review payload (linked issue specs, PR metadata and diff, prior comments/reviews, CI) and the exact result schema to use — and perform the review yourself, using your own reasoning and tools. Do not edit files, comment, or label; write your result as a JSON file matching the given schema (`verdict`, `summary`, `blocking_concerns`), then publish it:

  ```bash
  python3 "$COORDINATOR" \
    --path "$(git rev-parse --show-toplevel)" \
    --publish-verdict <pr> \
    --expected-head <result.expected_head> \
    --gate-key <result.gate_key> \
    --result <path-to-your-result.json> \
    --json
  ```

  `--publish-verdict` re-verifies the PR head and issue gate are still exactly what `--self-review` captured before accepting your verdict; if either drifted, it fails and tells you to rerun `--review --self-review` for a fresh context rather than publish against stale state.

- `"reviewed"`: the coordinator already spawned and published a dual review (unknown/external origin only — Kanban's own invocation never produces this, since every Kanban-created PR carries a known `pr-origin` marker); nothing further to do.

The coordinator does not pin or verify which specific model backs a reviewer for the rare dual-review fallback; it selects only the brand (`codex`/`claude`), deferring to that installation's own configured default. For the normal self-reviewed case, the reviewer identity is exactly this session — the one Kanban's own invocation already selected and configured.

## Publication and verification

Only the coordinator posts the consolidated plain PR comment and switches exactly one matching label, `reviewed:approve` or `reviewed:changes`. Never use a formal GitHub Review submission; the authenticated account may be the PR author. The comment ends with a `pr-review:v2` marker binding reviewer keys, head SHA, and verdict.

The coordinator re-checks linked-issue approval and the PR head immediately before commenting, immediately before labeling, and during final verification. If the issue gate becomes stale before commenting, it publishes only the idempotent gate comment. If the head, links, or approval change before commenting, it publishes no verdict. GitHub cannot atomically combine a comment and label: if state changes after the old-head comment lands, it leaves that SHA-bound marker in place, clears both verdict labels, and reports publication failure. Downstream automation must never trust a label without the matching current-head marker.

Return the PR number, origin or unknown status, issue-gate evidence, reviewer route, verdict, reviewed head, blockers, comment URL/status, and label state.
