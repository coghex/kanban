---
description: Survey the repo for MANY candidate issues (bugs, tech debt, docs, feature gaps, improvements), not one candidate (use /issue); shows the full drafted bodies and waits for approval before creating.
argument-hint: "[optional focus area or category]"
---

You expand the issue tracker by finding genuinely new, well-scoped work. Optional focus: $ARGUMENTS (a module, or a category like "docs" or "tech-debt"). If empty, cover the whole repo across all categories. This is the breadth counterpart to /issue — many candidates surveyed, and the ones chosen drafted to the same hand-off bar and shown in full before anything is created. For exactly one candidate, use /issue instead.

Run this in a **Class S** session (see the `model-classes` skill).

**Explore first:** Build a real picture before proposing anything — read the README, recent git history and merged PRs (regressions, "follow-up"/"deferred"/"TODO" notes), TODO/FIXME/HACK comments, deferred items named in the repo's agent instructions (CLAUDE.md or similar), and obvious gaps (missing tests, stale or incorrect docs/comments, weak error handling, inconsistencies). Audit the repository in your own session; do not spawn subagents. If the user asked for subagents for this task, you may use them, and only on Sonnet. The project may be hand-written and messy, so scrutinize comments for staleness/inaccuracy.

**Scope gate — only when the repo declares one:** Treat only an explicit, current, normative scope or priority instruction in the repo's agent instructions (`CLAUDE.md`, `AGENTS.md`, or whichever equivalent you consulted) as a scope gate. Descriptive roadmap or project-status prose is not a gate. If no such instruction is present, there is no gate: candidate selection, hunting sources, and reporting stay exactly as this workflow otherwise specifies, and nothing further in this paragraph applies. A gate constrains discretionary new work only — crashes, regressions, data loss or corruption, broken CI gates, and security issues remain eligible regardless of any gate. When a gate defers a discretionary candidate, report it rather than dropping it: identify the candidate with enough evidence to recognize it, name the gate that defers it, and say it was deferred by that gate. The user may override the deferral at signoff, and an overridden candidate becomes eligible again. If a gate defers every candidate you would otherwise draft, that is not a nothing-worth-opening result: stop and present the deferred candidates as your signoff, each named with its gate, then wait for the user to lift a deferral or confirm the stop. The gate changes selection only — a candidate that passes it is verified, deduplicated, and drafted to exactly the same hand-off bar as any other.

**Dedup every candidate before listing it:**
1. `gh issue list --state open --limit 300 --json number,title,labels` — read every title once, up front.
2. For each surviving candidate, run a keyword search or two with different phrasings, including closed issues: `gh issue list --search "<words>" --state all --limit 20`. A closed `wontfix`/`needs-decision` hit means the idea was already rejected — drop it unless you have genuinely new evidence.
3. Read the bodies of open epics touching the area — a planned child item of an epic counts as a duplicate.

**Present candidates — STOP:** A categorized list — bug / tech-debt / docs / feature-gap / enhancement — each with a title and a one-line description. Weight toward what the repo actually needs; don't pad. For feature gaps where direction is unclear, keep them high-level and flag them as needing a decision from the user rather than silently resolving the design question. List any gate-deferred candidates in that same presentation under a deferred heading, each naming its gate, so choosing one overrides the deferral. Then STOP and ask which to draft — accept "all" or a list. Choosing candidates from the list is not signoff of their bodies: it only selects what you draft next. Do NOT run `gh issue create` at this stage.

**Where files go:** This workflow files through `gh` and drafts in chat; it should not write into the repository at all. Its one filesystem write is the `--body-file` temp file — put that under the system temp directory, never inside a checkout. If a step ever does need a file in the repo, and that repo keeps a `docs-wip` worktree, write it there rather than the primary checkout: a PR drainer fast-forwards the primary after every merge and autostashes whatever it finds, and a restore that conflicts leaves unmerged index entries and wedges post-merge cleanup until a human clears them. Resolve it by BRANCH, never a hard-coded path:

```bash
DOCS_WT="$(git worktree list --porcelain \
  | awk '/^worktree /{p=substr($(0),10)} /^branch refs\/heads\/docs-wip$/{print p; exit}')"
[ -n "$DOCS_WT" ] || DOCS_WT="$(git rev-parse --show-toplevel)"
```

A repository with no `docs-wip` worktree does not use this convention — the fallback returns its own primary checkout and you proceed normally.

**Draft the chosen candidates:** Expand each chosen candidate to hand-off quality — it will be solved by an autonomous agent that does exactly what the issue says and nothing more, so the body is a contract:
- A bug issue must be verified first: reproduce it, or trace the defect through the actual code and cite `file:line` with the failure path. If verification kills it, report that instead of drafting it.
- Requirements say WHAT must be observably true when done — never HOW to code it (one exception: real constraints like serialization compatibility, determinism, perf budgets, append-only enums are requirements and must be stated).
- Acceptance names the exact commands, tests, or probes that must pass — discover the repo's own gates from its agent instructions and CI config.
- Include an Out of scope section fencing adjacent work, plus grounding pointers (where the relevant code lives, which existing feature to mirror).
- If the change invalidates a statement in the repo's agent instructions (CLAUDE.md or similar) or a load-bearing comment, updating that doc IS a requirement — name the file. Stale steering docs actively misdirect the next agent.
- Never silently resolve a design question. Either surface it at signoff for the user to decide (then bake the answer into requirements), or put it in a "Deliberately open" section with instructions to stop and ask — and say which.
- **Art is tracked work, not an implementation detail.** If the change needs a texture, icon, sprite, or animation that does not exist, say so explicitly: name each missing asset and what it is for. Record it as an explicit blocker in the issue body so the solver hits it deliberately, rather than resolving it in the draft. Art gets its own issue, its own PR, and the user's signoff on every texture — they decide whether they supply the file or have it generated, and unless they have already said which, the issue must tell the solver to stop and ask. Never assume a placeholder, a reused asset, or a narrowed scope resolves the gap. A missing asset is an execution dependency, not a readiness failure of the issue: list each one with its purpose, visual constraints, dependencies, and the criteria the user will apply to approve the finished image; keep a supply method the user has already chosen, and otherwise leave the choice of method and the authorization to generate until the solver needs the asset. Never substitute a placeholder or drop the requirement.
- **Scope to one PR.** The solve workflow is one issue → one worktree → one PR. A candidate that is genuinely larger than one pull request is split at signoff: propose the split and draft each piece, each of which stands as its own issue.
- Body shape: `## Background`, `## Requirements`, `## Acceptance`, `## Out of scope`, `## Related` — match the tracker's existing style if it differs.

Append `<!-- issue-origin:claude -->` as the final line of every body as invisible routing metadata.

**Signoff on the bodies — STOP:** Present every drafted issue exactly as it will be posted: title, proposed labels (existing labels only — check `gh label list`), and the complete body verbatim, including each piece of a split candidate. Do not summarize a body to a title or a one-line description. Then STOP and wait for the user's explicit approval of those bodies. If they ask for changes, revise and present the complete revised draft again. **Do NOT run `gh issue create` until the user has explicitly approved the drafts**, and create only the drafts they approved.

**Create:** Only after that approval, ensure each approved body still ends with `<!-- issue-origin:claude -->`, write it to a temp file, and create it with `gh issue create --title "..." --body-file <file> --label "..."` (existing labels only — check `gh label list`). Report the created numbers/URLs.

**Ambiguity:** If unclear, ask in plain text and stop — no assumptions.
