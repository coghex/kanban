---
name: autoissue
<!-- brand:claude -->
description: Draft one issue with {{cmd:issue}}, create it after signoff, then run the canonical opposite-agent issue review — not drafting alone (use {{cmd:issue}}), not review of an existing issue (use {{cmd:issue-review}}). Use only when the user invokes {{cmd:autoissue}} or explicitly asks for this combined draft-create-review workflow.
<!-- brand:codex -->
description: Draft one verified, deduplicated GitHub issue with {{cmd:issue}}, create it only after explicit user signoff, then immediately run the canonical {{cmd:issue-review}} opposite-agent readiness gate — not drafting alone (use {{cmd:issue}}), not review of an existing issue (use {{cmd:issue-review}}). Use only when the user invokes {{cmd:autoissue}} or explicitly asks for this combined draft-create-review workflow.
<!-- /brand -->
argument-hint: "[optional: symptom, area, or idea to investigate]"
---

<!-- brand:claude -->
Run `{{cmd:issue}}` with `$ARGUMENTS`, then review the created issue through `{{cmd:issue-review}}`. Follow both commands completely; this command only joins their workflows and does not replace either contract.
<!-- brand:codex -->
# Autoissue With Opposite-Agent Review

Run `{{cmd:issue}}`, including any lead supplied with the invocation, then review the created issue through `{{cmd:issue-review}}`. Read and follow both skills completely; this skill only joins their workflows and does not replace either contract.
<!-- /brand -->

Run this in a **Class S** session (see the `model-classes` skill).

## Draft and signoff

<!-- brand:claude -->
1. Run `{{cmd:issue}}` for exactly one candidate, passing `$ARGUMENTS` through as its lead.
2. Preserve every `{{cmd:issue}}` requirement, especially verification, deduplication, hand-off-quality drafting, `<!-- issue-origin:claude -->`, and the mandatory stop for explicit user signoff.
<!-- brand:codex -->
1. Run `{{cmd:issue}}` for exactly one candidate.
2. Preserve every `{{cmd:issue}}` requirement, especially verification, deduplication, hand-off-quality drafting, the `<!-- issue-origin:codex -->` origin marker, and the mandatory stop for explicit user signoff.
<!-- /brand -->
3. If `{{cmd:issue}}` finds a duplicate, finds nothing worth opening, needs clarification, or otherwise stops before creation, stop this workflow too. Do not run a review.
4. If the user requests draft changes, revise and re-present the complete draft under `{{cmd:issue}}`; do not create or review it yet.

The user's explicit approval of the issue draft authorizes its creation. The original `{{cmd:autoissue}}` invocation already authorizes the canonical review immediately afterward; do not ask for a second confirmation between those steps.

## Scope gate

**Scope gate — only when the repo declares one:** Treat only an explicit, current, normative scope or priority instruction in the repo's agent instructions (`CLAUDE.md`, `AGENTS.md`, or whichever equivalent you consulted) as a scope gate. Descriptive roadmap or project-status prose is not a gate. If no such instruction is present, there is no gate: candidate selection, hunting sources, and reporting stay exactly as this workflow otherwise specifies, and nothing further in this paragraph applies. A gate constrains discretionary new work only — crashes, regressions, data loss or corruption, broken CI gates, and security issues remain eligible regardless of any gate. When a gate defers a discretionary candidate, report it rather than dropping it: identify the candidate with enough evidence to recognize it, name the gate that defers it, and say it was deferred by that gate. The user may override the deferral at signoff, and an overridden candidate becomes eligible again. If a gate defers every candidate you would otherwise draft, that is not a nothing-worth-opening result: stop and present the deferred candidates as your signoff, each named with its gate, then wait for the user to lift a deferral or confirm the stop. The gate changes selection only — a candidate that passes it is verified, deduplicated, and drafted to exactly the same hand-off bar as any other.

`{{cmd:issue}}` applies that gate while hunting. Preserve it through delegation: surface every deferral `{{cmd:issue}}` reports in the signoff presentation without editing it, and pass a user override back to `{{cmd:issue}}` rather than resolving the deferral yourself. The gate never changes what gets created after approval, and it never adds a confirmation step.

## Create and review

1. Create the approved issue exactly as `{{cmd:issue}}` specifies and capture its positive issue number and URL.
2. Immediately run `{{cmd:issue-review}} <issue>` and follow its canonical `approve_issues.py` procedure verbatim, including its Kanban-managed backend resolution through `KANBAN_ISSUE_REVIEW_INSTALL_DIR`. Do not independently review, comment, retry, substitute a model, or set readiness labels.
3. Preserve `{{cmd:issue-review}}` stop conditions:
   - Report a held queue lock with its structured owner and do not start a concurrent review.
<!-- brand:claude -->
   - On `CHANGES_REQUESTED`, report the result and direct the issue through `{{cmd:issue-rereview}} <issue>`; do not rerun the unchanged issue. That repair-and-rereview workflow is this bundle's own packaged command; Kanban's `docs/drafting-workflow-contract.md` declares it and keeps the readiness gate separate from repair.
<!-- brand:codex -->
   - On `CHANGES_REQUESTED`, report the result and direct the issue through `{{cmd:issue-rereview}} <issue>`; do not rerun the unchanged issue. That repair-and-rereview workflow is this bundle's own packaged skill; Kanban's `docs/drafting-workflow-contract.md` declares it and keeps the readiness gate separate from repair.
<!-- /brand -->
   - On INVALID or model failure, stop exactly as `{{cmd:issue-review}}` requires.
4. Return the created issue number and URL plus the review state, route, model or models, review comment URL when present, and all blocking reasons.
