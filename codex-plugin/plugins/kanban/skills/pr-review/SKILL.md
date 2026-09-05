---
name: pr-review
description: Run the canonical issue-gated review for one GitHub pull request, routing known solver origins to the opposite-brand reviewer and unknown or external origins to independent Codex and Claude reviews, then publish one consolidated verdict. Use when asked to review a PR.
---

# Review Pull Request

Require one positive PR number. When Kanban's own `r` key spawned this session, it spawned it as the canonical opposite-brand reviewer — that invocation pinned this session's model before this workflow ever ran — so for the normal known-origin case you perform the review yourself and the bundled coordinator only handles safe publication. Treat that as a precondition to check, not a given: a session running on the pull request's *own* origin brand — the solver that opened it, or anything continuing that work — is not its reviewer and must let the coordinator spawn the routed one. Declare this session's brand with `--self-review-as codex`; the coordinator refuses a declaration that is absent or names a brand other than the routed reviewer, publishing nothing and changing no label. Which reviewer a pull request routes to depends on the roster's loaded providers: the opposite brand when both are loaded, and the one loaded provider when only one is — in which case a declaration matching that provider is accepted even though it shares the pull request's own origin brand. Do not independently comment, label, or compensate for the coordinator's result.

Kanban spawns this workflow with the *reviewed* repository as the working directory, not this plugin's own install location, so locate the installed coordinator by searching under `$CODEX_HOME` (default `~/.codex`) rather than a path relative to the current directory:

```bash
COORDINATOR="$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" -path '*/kanban/*/skills/pr-review/scripts/review_pr.py' 2>/dev/null | head -n1)"
python3 "$COORDINATOR" \
  --path "$(git rev-parse --show-toplevel)" \
  --review <pr> \
  --self-review \
  --self-review-as codex \
  --json
```

## Issue approval gate

The coordinator resolves GitHub closing-issue references before inspecting PR provenance. Every linked issue must belong to the current repository and pass the canonical freshness-aware `approve_issues.py --check`; a `reviewed:approve` label alone is insufficient. No linked issue, an external linked issue, or any non-approved linked issue blocks review.

For a blocked gate (`"status": "blocked"`), the coordinator has already posted the idempotent `Issue has not been approved.` comment with its hidden `pr-review-gate:v1` marker and changed no `reviewed:*` label. Exit status 2 is the expected blocked result; stop.

A blocked gate is this coordinator working, not failing, and clearing it is the linked issue's own review workflow's job. There is one exception, and it is the user's to invoke rather than yours to choose: when the user has asked in this turn to review the pull request anyway, pass `--override-issue-gate` together with `--override-reason "<the reason the user gave>"`. Both halves are required — either flag alone returns `"status": "override_refused"` before anything is read, spawned, or published — and the reason is reproduced verbatim in the published review comment, so the bypass is never silent. It relaxes exactly one thing: that every linked issue carries a current canonical approval. An external or unparseable linked issue, and a pull request with no linked issue at all, still block. The review itself is unchanged: same opposite-brand route, same verdict, same labels, and the approval the drainer merges on. Never pass it on your own initiative, never to get past a gate you merely disagree with, and never with a reason you composed rather than one the user gave.

## Reviewer route and self-review

Read the returned `"status"`:

- `"blocked"`: stop, per the gate section above.
- `"override_refused"`: `--override-issue-gate` and `--override-reason` were not both supplied, so no override was in force and this pull request was not reviewed. Nothing was published and no label changed. Supply the missing half only if the user really did authorize bypassing the linked issue's approval in this turn; otherwise drop both and report the gate as blocking.
- `"no_agent_mode"`: this installation's model roster loads no provider, so the coordinator has no reviewer to route to and refused before reading the pull request. Nothing was published and no label changed, and no rerun of this command can change that. Stop and report it: adding a provider to the roster's `agents` list is the operator's decision, never this session's.
- `"self_review_refused"`: this session's declared brand is not the reviewer this pull request routes to, so it may not review it. Nothing was published and no label changed. Rerun the same command with both `--self-review` and `--self-review-as` dropped, so the coordinator spawns the routed reviewer itself — the opposite brand when the roster loads both providers, and the sole loaded provider when it loads one; never review it yourself instead. A declaration that MATCHES the routed reviewer is not refused: on a single-agent roster every pull request routes to the one loaded provider, so a matching `--self-review-as` is the normal path and returns `"awaiting_self_review"` even where that reviewer shares the pull request's own origin brand.
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

Only the coordinator posts the consolidated plain PR comment and switches exactly one matching label, `reviewed:approve` or `reviewed:changes`. On `APPROVE`, it also marks a draft PR ready for review so Kanban moves it to Done even while CI is pending; `CHANGES_REQUESTED` never changes draft state. Never use a formal GitHub Review submission; the authenticated account may be the PR author. The comment ends with a `pr-review:v2` marker binding reviewer keys, head SHA, and verdict.

The coordinator re-checks linked-issue approval and the PR head immediately before commenting, immediately before labeling, and during final verification. An approval is verified once before a draft is marked ready and again afterward. If the issue gate becomes stale before commenting, it publishes only the idempotent gate comment. If the head, links, or approval change before commenting, it publishes no verdict. GitHub cannot atomically combine a comment, label, and draft transition: if state changes after the old-head comment lands, it leaves that SHA-bound marker in place, clears both verdict labels, leaves draft state exactly as it stands, and reports publication failure. It never returns the PR to draft: nothing readable separates a ready transition this publication made from one another actor made in the same window. Downstream automation must never trust a label without the matching current-head marker.

Return the PR number, origin or unknown status, issue-gate evidence, reviewer route, verdict, reviewed head, blockers, comment URL/status, label state, and ready-for-review state.
