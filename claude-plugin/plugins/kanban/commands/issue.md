---
description: Find ONE actionable issue (bug, feature, code health), verify it's real, dedup it against the tracker, and draft it to hand-off quality — stops for signoff before creating.
argument-hint: "[optional: symptom, area, or idea to investigate]"
---

You find and fully draft ONE issue per run. It will be solved by an autonomous agent that does exactly what the issue says and nothing more — no double-checking, no asking questions. So the draft is a contract: requirements specific enough that a wrong implementation FAILS acceptance, with the implementation method left entirely to the solver. You never create the issue without explicit signoff.

**Target:** If $ARGUMENTS is non-empty, that's your lead — investigate it. Otherwise hunt for the single most valuable actionable item: recent git history and merged PRs (regressions, "follow-up"/"deferred"/"TODO" notes), TODO/FIXME/HACK comments, deferred items named in the repo's agent instructions (CLAUDE.md or similar), doc-vs-code drift, shipped features with no test/probe coverage, weak error handling on real inputs. Weight by user value and actionability. Pick ONE candidate; keep runners-up as one-line mentions for the final report — do not draft them.

**Verify it's real — never draft from an unverified hunch:**
- Bug: reproduce it, or trace the defect through the actual code and cite `file:line` with the failure path. Capture evidence for the issue body: exact command/seed/steps, observed vs expected.
- Feature / code health: read enough code to confirm it doesn't already exist (even partially), and identify what it must integrate with.
- If verification kills the candidate, say so and move to the next. "Nothing worth opening" is a valid result — report it and stop.

**Dedup — before drafting anything:**
1. `gh issue list --state open --limit 300 --json number,title,labels` — read every title.
2. Run 2–3 keyword searches with different phrasings, including closed issues: `gh issue list --search "<words>" --state all --limit 20`. A closed `wontfix`/`needs-decision` hit means the idea was already rejected — respect that unless you have genuinely new evidence.
3. Read the bodies of any open epics touching this area — a planned child item of an epic counts as a duplicate.

If a match exists: do NOT draft. Report the existing issue number, and if you learned something new, propose comment text for it — but don't post that without approval either.

**Draft to hand-off quality.** Rules, in priority order:
1. Requirements say WHAT must be observably true when done — never HOW to code it. No function names, data structures, module layouts, or algorithms, with one exception: real constraints (serialization compatibility rules, determinism, perf budgets, append-only enums, platform quirks) are requirements and must be stated explicitly, because the solver won't discover them on its own.
2. Every requirement must be independently checkable by the solver without the user present. Acceptance names the exact commands, tests, or probes that must pass — discover the repo's own gates from its agent instructions and CI config, and name exact invocations. If the change needs a new test to be verifiable, requiring that test IS a requirement.
3. If the change invalidates a statement in the repo's agent instructions (CLAUDE.md or similar) or a load-bearing comment, updating that doc IS a requirement — name the file. Stale steering docs actively misdirect the next agent.
4. Grounding pointers are welcome and are not implementation guidance: where the relevant code lives, which existing feature to mirror conventions from, which test tier covers this area. Pointers orient the solver; they don't prescribe its choices.
5. Fence the scope with an explicit Out of scope section — name the adjacent work that must NOT ride along, especially anything tempting.
6. Never silently resolve a design question. Either surface it at signoff for the user to decide (then bake the answer into requirements), or put it in a "Deliberately open" section with instructions to stop and ask — and say which.

Body template (match the tracker's existing style if it differs): title in the imperative, prefixed with the feature-arc tag if the tracker uses them (e.g. `[farming]`); then `## Background` (why now, with your verification evidence — repro command, observed vs expected, or the gap traced in code), `## Requirements` (numbered, each observable and testable), `## Acceptance` (the "done when" list — exact commands and expected outcomes), `## Out of scope`, `## Related` (issues/PRs, with one clause on how each relates). Append `<!-- issue-origin:claude -->` as the final line of every draft; it is invisible routing metadata, not a requirement.

**Scope to one PR.** The solve workflow is one issue → one worktree → one PR. If the work is genuinely larger, say so at signoff and propose the split — but still draft only the first actionable piece this run.

**Signoff — STOP:** Present the draft exactly as it will be posted: title, proposed labels (existing labels only — check `gh label list`), and the full body verbatim. Below it, three short notes: evidence (why it's real, one or two sentences), dedup (nearest existing issue and why this is different), runners-up (one line each). Then STOP and wait. **Do NOT run `gh issue create` until the user explicitly approves.** If they ask for changes, revise and re-present the full body.

**Create:** Only after approval: ensure the final body still ends with `<!-- issue-origin:claude -->`, write it to a temp file, then `gh issue create --title "..." --body-file <file> --label "..."`. Report the issue number and URL in one line.

**Ambiguity:** If anything is unclear or you'd be guessing, stop and ask in plain text — no assumptions.
