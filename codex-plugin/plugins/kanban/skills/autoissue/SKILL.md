---
name: autoissue
description: Draft one verified, deduplicated GitHub issue with $issue, create it only after explicit user signoff, then immediately run the canonical $issue-review opposite-agent readiness gate. Use only when the user invokes $autoissue or explicitly asks for this combined draft-create-review workflow.
---

# Autoissue With Opposite-Agent Review

Run `$issue`, including any lead supplied with the invocation, then review the created issue through `$issue-review`. Read and follow both skills completely; this skill only joins their workflows and does not replace either contract.

## Draft and signoff

1. Run `$issue` for exactly one candidate.
2. Preserve every `$issue` requirement, especially verification, deduplication, hand-off-quality drafting, the `<!-- issue-origin:codex -->` origin marker, and the mandatory stop for explicit user signoff.
3. If `$issue` finds a duplicate, finds nothing worth opening, needs clarification, or otherwise stops before creation, stop this workflow too. Do not run a review.
4. If the user requests draft changes, revise and re-present the complete draft under `$issue`; do not create or review it yet.

The user's explicit approval of the issue draft authorizes its creation. The original `$autoissue` invocation already authorizes the canonical review immediately afterward; do not ask for a second confirmation between those steps.

## Create and review

1. Create the approved issue exactly as `$issue` specifies and capture its positive issue number and URL.
2. Immediately run `$issue-review <issue>` and follow its canonical `approve_issues.py` procedure verbatim, including its Kanban-managed backend resolution through `KANBAN_ISSUE_REVIEW_INSTALL_DIR`. Do not independently review, comment, retry, substitute a model, or set readiness labels.
3. Preserve `$issue-review` stop conditions:
   - Report a held queue lock with its structured owner and do not start a concurrent review.
   - On `CHANGES_REQUESTED`, report the result and direct the issue through the `issue-rereview` workflow; do not rerun the unchanged issue. That repair-and-rereview workflow is deliberately outside this bundle's packaged set; Kanban's own `docs/drafting-workflow-contract.md` records the boundary.
   - On INVALID or model failure, stop exactly as `$issue-review` requires.
4. Return the created issue number and URL plus the review state, route, model or models, review comment URL when present, and all blocking reasons.
