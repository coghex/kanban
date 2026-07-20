---
name: pr-review
description: Run the canonical issue-gated review for one GitHub pull request, routing known solver origins to the opposite reviewer and unknown or external origins to independent GPT-5.6-Terra and Claude Opus 4.8 reviews, then publish one consolidated verdict. Use when asked to review a PR.
---

# Review Pull Request

Require one positive PR number. Use the bundled coordinator; do not independently review, comment, label, retry a failed model, or compensate for its result:

```bash
python3 ./scripts/review_pr.py \
  --path "$(git rev-parse --show-toplevel)" \
  --review <pr> \
  --json
```

## Issue approval gate

The coordinator resolves GitHub closing-issue references before inspecting PR provenance or invoking a model. Every linked issue must belong to the current repository and pass the canonical freshness-aware `approve_issues.py --check`; a `reviewed:approve` label alone is insufficient. No linked issue, an external linked issue, or any non-approved linked issue blocks review.

For a blocked gate, the coordinator invokes no reviewer and changes no `reviewed:*` label. It posts exactly:

```text
Issue has not been approved.
```

The comment includes a hidden `pr-review-gate:v1` marker keyed to the linked-issue set. It reuses an existing marker-authored comment from the authenticated GitHub user instead of posting duplicates. Exit status 2 is the expected blocked result.

## Reviewer route

After the gate passes, read one exact final `<!-- pr-origin:claude -->` or `<!-- pr-origin:codex -->` marker. Treat a cross-repository/fork PR as external regardless of its body. Treat an external PR or an absent, duplicated, conflicting, misplaced, or malformed marker as unknown; never guess.

- Claude origin: GPT-5.6-Terra (`gpt-5.6-terra`) at xhigh.
- Codex origin: Claude Opus 4.8 (`claude-opus-4-8`) at xhigh.
- Unknown origin: both canonical reviewers independently at xhigh.

The coordinator gives each reviewer the same approved issue specifications, complete PR metadata and diff, prior comments/reviews, CI, and a read-only extraction of the exact head. Reviewers cannot publish or see each other's result. A dual review approves only when both approve; either blocking verdict yields `CHANGES_REQUESTED`. A missing, malformed, or failed reviewer result stops publication without substitution.

## Publication and verification

Only the coordinator posts the consolidated plain PR comment and switches exactly one matching label, `reviewed:approve` or `reviewed:changes`. Never use a formal GitHub Review submission; the authenticated account may be the PR author. The comment ends with a `pr-review:v2` marker binding reviewer keys, exact model IDs and effort, head SHA, and verdict.

Re-check linked-issue approval and the PR head after model execution, immediately before commenting, immediately before labeling, and during final verification. If the issue gate becomes stale before commenting, publish only the idempotent gate comment. If the head, links, or approval change before commenting, publish no verdict. GitHub cannot atomically combine a comment and label: if state changes after the old-head comment lands, leave its SHA-bound marker in place, clear both verdict labels, and report publication failure. Succeed only when the newest authenticated-user `pr-review:v2` marker matches the current head, the issue gate remains current, and exactly one matching `reviewed:*` label exists. Downstream automation must never trust a label without the matching current-head marker.

Return the PR number, origin or unknown status, issue-gate evidence, reviewer route and models, verdict, reviewed head, per-reviewer blockers, comment URL/status, and label state.
