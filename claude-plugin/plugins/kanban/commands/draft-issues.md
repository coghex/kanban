---
description: Audit the repo and draft well-scoped candidate issues (bugs, tech debt, docs, feature gaps, improvements) for review before creating.
argument-hint: "[optional focus area or category]"
---

You expand the issue tracker by finding genuinely new, well-scoped work. Optional focus: $ARGUMENTS (a module, or a category like "docs" or "tech-debt"). If empty, cover the whole repo across all categories. This is the breadth counterpart to /issue — many candidates surveyed, and the ones chosen for creation drafted to the same hand-off bar.

**Explore first:** Build a real picture before proposing anything — read the README, recent git history and merged PRs (regressions, "follow-up"/"deferred"/"TODO" notes), TODO/FIXME/HACK comments, deferred items named in the repo's agent instructions (CLAUDE.md or similar), and obvious gaps (missing tests, stale or incorrect docs/comments, weak error handling, inconsistencies). For a large repo, fan out parallel subagents to audit different modules. The project may be hand-written and messy, so scrutinize comments for staleness/inaccuracy.

**Scope gate — only when the repo declares one:** Treat only an explicit, current, normative scope or priority instruction in the repo's agent instructions (`CLAUDE.md`, `AGENTS.md`, or whichever equivalent you consulted) as a scope gate. Descriptive roadmap or project-status prose is not a gate. If no such instruction is present, there is no gate: candidate selection, hunting sources, and reporting stay exactly as this workflow otherwise specifies, and nothing further in this paragraph applies. A gate constrains discretionary new work only — crashes, regressions, data loss or corruption, broken CI gates, and security issues remain eligible regardless of any gate. When a gate defers a discretionary candidate, report it rather than dropping it: identify the candidate with enough evidence to recognize it, name the gate that defers it, and say it was deferred by that gate. The user may override the deferral at signoff, and an overridden candidate becomes eligible again. If a gate defers every candidate you would otherwise draft, that is not a nothing-worth-opening result: stop and present the deferred candidates as your signoff, each named with its gate, then wait for the user to lift a deferral or confirm the stop. The gate changes selection only — a candidate that passes it is verified, deduplicated, and drafted to exactly the same hand-off bar as any other.

**Dedup every candidate before listing it:**
1. `gh issue list --state open --limit 300 --json number,title,labels` — read every title once, up front.
2. For each surviving candidate, run a keyword search or two with different phrasings, including closed issues: `gh issue list --search "<words>" --state all --limit 20`. A closed `wontfix`/`needs-decision` hit means the idea was already rejected — drop it unless you have genuinely new evidence.
3. Read the bodies of open epics touching the area — a planned child item of an epic counts as a duplicate.

**Present candidates — STOP:** A categorized list — bug / tech-debt / docs / feature-gap / enhancement — each with a title and a one-line description. Weight toward what the repo actually needs; don't pad. For feature gaps where direction is unclear, keep them high-level and flag them as needing a decision from the user rather than silently resolving the design question. List any gate-deferred candidates in that same presentation under a deferred heading, each naming its gate, so choosing one overrides the deferral. Then STOP and ask which to create — accept "all" or a list. Do NOT run `gh issue create` until told which.

**Create:** Expand each chosen candidate to hand-off quality — it will be solved by an autonomous agent that does exactly what the issue says and nothing more, so the body is a contract:
- A bug issue must be verified first: reproduce it, or trace the defect through the actual code and cite `file:line` with the failure path. If verification kills it, report that instead of creating it.
- Requirements say WHAT must be observably true when done — never HOW to code it (one exception: real constraints like serialization compatibility, determinism, perf budgets, append-only enums are requirements and must be stated).
- Acceptance names the exact commands, tests, or probes that must pass — discover the repo's own gates from its agent instructions and CI config.
- Include an Out of scope section fencing adjacent work, plus grounding pointers (where the relevant code lives, which existing feature to mirror).
- Body shape: `## Background`, `## Requirements`, `## Acceptance`, `## Out of scope`, `## Related` — match the tracker's existing style if it differs.

Append `<!-- issue-origin:claude -->` to every body as invisible routing metadata. Write each body to a temp file and create with `gh issue create --title "..." --body-file <file> --label "..."` (existing labels only — check `gh label list`). Report the created numbers/URLs.

**Ambiguity:** If unclear, ask in plain text and stop — no assumptions.
