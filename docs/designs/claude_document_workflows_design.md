# Claude document workflows design

The tracked document-workflow bundle is single-brand where it matters most:
`$design-epic`, `$process-design-doc`, and `$draft-report` are declared
Codex-only, the personal Claude copies of the design pair carry
decision-authority guardrails the vendored Codex text dropped, the
write-side `note-problem` exists only in one machine's personal layer, and
a rejected issue's repair-and-rereview loop is closeable only from Codex.
This arc makes the document and issue-drafting loops brand-complete: the
strongest text becomes the pinned source, both plugins derive from it, and
the contracts that declared the gaps are amended instead of silently
outgrown.

The arc is now partly tracked. `docs/workflow_audit_findings.md` processed
WF-7, WF-8, and WF-9 into #239, #240, and #241, after this document's first
pass was written against an unprocessed report. #239 has since merged; #240
is open and `reviewed:approve`; #241 was revised in place per D-6 on
2026-08-12 and is open and `reviewed:revised`. This document therefore
designs the arc *and* records where the filed issues diverge from it — see
D-4 and D-6.

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Make the document and issue-drafting workflow loops brand-complete — [#260]
- [x] CDW-1. Merge the decision-authority guardrails into the tracked design workflows — [#239]
- [x] CDW-2. Derive Claude counterparts for design-epic and process-design-doc — [#241]
- [x] CDW-3. Package the report write side for both brands — [#328]
- [x] CDW-4. Package issue-rereview for both brands — [#240]

## Epic contract

- **Goal:** every document workflow (design capture, design processing,
  report drafting, report processing, observation capture) and the issue
  repair-and-rereview loop can be run from either brand, from the tracked
  bundles, under the same guardrails.
- **Done when:** the document-workflow contract's §2 table declares a
  Claude and Codex asset for each workflow this arc packages, with
  `note-problem` added to the contract's document-workflow *name* set and
  not only its row list; the §3.5 Codex-only asymmetry is amended to
  whatever remains; the drafting contract packages issue-rereview for both
  brands; the strengthened authority text is identical across brands by
  derivation rather than by coincidence; and every touched test parser is
  green.
- **Users and operators:** Vincent working from either brand's session; the
  agent pipeline (assets are what solve/review sessions read); the contract
  tests that pin the declared sets.
- **Arc label:** existing `agent-workflows`.

## Current state and evidence

- **Three of the four slices are filed; CDW-1 has landed.** The
  audit report's ledger reads `WF-7 — [#239]`, `WF-8 — [#240]`,
  `WF-9 — [#241]`; all three carry `agent-workflows`. #239 covers CDW-1 and
  has merged, #240 covers CDW-4 and is open and `reviewed:approve`, and #241
  covered CDW-2 bundled with the `draft-report` half of CDW-3 until D-6's
  revision narrowed it to CDW-2 alone on 2026-08-12. The umbrella epic is #260, created
  2026-08-11 with `epic` and `agent-workflows`; the three older
  `epic`-labeled issues (#79, #122, #159) are closed and cover other arcs.
- **#239's approved review amended its spec away from a verbatim standard.**
  Its cross-agent review (GPT-5.6-Sol, base `0d32e974`, verdict APPROVE)
  records that "the behavioral clauses enumerated in requirement 1 govern;
  implementation does not depend on access to untracked personal Claude
  files," naming the reconciliation with this document's D-3/CDW-1 wording
  explicitly. Verified independently: the personal authority text appears in
  no tracked path — the only in-repo hit for "Human interaction and decision
  authority" is this design document naming the section, so the verbatim
  standard was unevaluable by any tracked test or by CI. D-3's amendment
  adopts the behavioral standard.
- **#241's vendoring model conflicts with this design (D-4).** Its
  requirement 1 vendors `design-epic.md` and `process-design-doc.md`
  byte-for-byte from the personal Claude sources, and its requirement 5
  holds the tracked Codex skills unchanged — making it independent of #239.
  This design derives the Claude pair from #239's strengthened Codex text
  instead, so #241 needs a spec revision; D-6 revises it in place.
- **#241 fences out work D-1 puts in scope.** Its `Out of scope` reads
  "`note-problem` and `backlog` — personal-layer utilities outside the
  document-workflow contract; they remain personal per the audit's WF-6
  disposition," and WF-9's disposition note in the audit report says the
  same. D-1 supersedes both for `note-problem` alone; D-6 repairs the issue
  and D-8 corrects the report.
- **The asymmetry is declared, with a reason this arc satisfies.**
  `docs/document-workflow-contract.md` §3.5: the three workflows are
  Codex-only because "authoring one would be new behavior that no pinned
  source defines," per issue #118's SHA-pinned vendoring model — "The
  Claude plugin must not grow one under this contract until a pinned source
  exists to vendor." CDW-1's strengthened tracked text is exactly such a
  source (D-4).
- **The guardrail regression is concrete (WF-7).** The personal design
  pair carries a "Human interaction and decision authority" section —
  proposals-never-decisions, per-decision signoff, at most three questions
  per stop, "Never bury a blocking ambiguity in the document and proceed" —
  absent from `codex-plugin/plugins/kanban/skills/design-epic/SKILL.md` and
  `process-design-doc/SKILL.md`, which instead say "Leave lesser
  uncertainty in the document instead of blocking useful progress." The
  tracked source of truth is the weaker text.
- **The declared sets are test-pinned in three places, not one.**
  `tools/test_document_workflow_contract.py` hard-codes
  `DOCUMENT_WORKFLOW_NAMES` (four names), `EXPECTED_DECLARED_PATHS` (five
  paths — one Claude, four Codex), and `CODEX_ONLY_WORKFLOWS` (the §3.5
  trio), plus the §3.5 statements verbatim; it also fails if any
  document-workflow name appears in a plugin without a §2 row. Adding
  `note-problem` extends the *name* set, not just the row list — it changes
  what the completeness check polices. Contract, assets, and test move in
  the same PR or nothing moves.
- **The report write side is personal-only, and Codex-only.**
  `~/.codex/skills/note-problem/SKILL.md` (6.1 KB — capture one verified
  observation into a process-report-compatible report) has no tracked copy
  in either plugin, and carries an `agents/` sidecar the tracked-bundle
  checks forbid. `~/.claude/commands/note-problem.md` does not exist, so
  the Claude side is an authored brand adaptation rather than a vendor —
  the same standing #240 gives its Claude asset and #241 gives
  `draft-report.md`. `~/.codex/skills/backlog/` (Markdown-document audit,
  with the untracked 14.6 KB `scripts/scan_backlog.py`) stays personal
  (D-1).
- **issue-rereview is Codex-personal and declared out-of-bundle (WF-8).**
  `~/.codex/skills/issue-rereview/` is the sole copy; both plugins' packaged
  issue-review assets state the rereview workflow is "deliberately outside
  this bundle's packaged set," and `docs/drafting-workflow-contract.md` §2
  (seven rows, `:35-43`) records the boundary.
  `tools/test_drafting_workflow_contract.py` pins
  `DRAFTING_WORKFLOW_NAMES` (four names) and those seven paths; its
  scope-gate, origin-marker, and portable-backend rules would apply to any
  new drafting asset. The backend already supports rereview
  (`tools/approve_issues.py --rereview`), and #240's stated prerequisite
  #238 has merged (PR #244), so nothing blocks it.
- **The declared-inventory surface is wider than one contract file (D-9).**
  Verified: `docs/document-workflow-contract.md` §3's responsibility matrix
  marks `$design-epic`, `$process-design-doc`, and `$draft-report` **Codex
  only** in its own table, so amending §§3.4-3.5 alone leaves the contract
  self-contradictory. `claude-plugin/…/commands/process-report.md` routes its
  Epic disposition to Codex's `$design-epic`/`$process-design-doc`
  (`:262-263`, `:274-276`), and
  `test_claude_epic_disposition_routes_to_packaged_codex_workflows`
  (`tools/test_document_workflow_contract.py:328`) *asserts* the Claude slash
  commands are absent — it fails the moment they exist.
  `tools/test_agent_workflow_contract.py` enumerates its plugin surfaces
  rather than globbing them (`:85`, `:135`, `:149`). The Claude plugin ships
  ten commands, and `claude-plugin/README.md:232` pins "exactly the ten
  packaged workflows"; `codex-plugin/README.md:108` calls the Claude gap
  declared; `docs/README.md:8` describes "the declared Codex-only gap".
  `HASKELL_PARITY_COMMAND_NAMES` is exactly five
  (`tools/test_claude_plugin.py:74`) and stays five — every workflow here is
  user-invoked.
- **The Claude command format is settled.** `claude-plugin/…/commands/*.md`
  frontmatter (`description`, `argument-hint`) plus `$ARGUMENTS` and the
  docs-worktree resolution block; `process-report.md` is byte-identical to
  its personal Claude copy, proving the transpose pattern round-trips.
- **Cross-arc state.** Closed #229 / PR #231 vendored the current
  Codex-only set and defined the SHA-pinned model; closed #79 was the
  portability epic this extends in spirit; #235 (manifest version bumps) has
  merged, so `tools/plugin_bundle_gate.py` now requires a bundle version bump
  in the same change as any bundle edit; #237 (coordination-document
  publication, `blocked`) remains an open workflow-tooling item every slice
  here inherits rather than owns.

## Desired experience

From a Claude session: `/design-epic` captures an epic with the same
authority guardrails this very document was written under; `/process-design-doc`
processes it; `/draft-report` starts a findings report; `/note-problem`
captures one observation into it; `/issue-rereview` repairs a
changes-requested issue and resubmits it to the canonical gate. From a
Codex session: identical capabilities under identical text, as today plus
the write-side and rereview additions. A report or design document started
by one brand is processed by the other without translation, and the
contracts describe exactly what is packaged — no declared gap survives that
a pinned source can close.

## Scope

### In scope

- The authority-guardrail merge into the tracked design pair.
- Claude-plugin counterparts for `design-epic`, `process-design-doc`, and
  `draft-report`, derived per D-4; both-plugin packaging of `note-problem`
  (D-1), dropping its `agents/` sidecar.
- Packaging `issue-rereview` for both brands under the drafting contract.
- Amendments to both contracts' declared sets, workflow-name sets, boundary
  statements, and their test parsers; plugin manifest updates (respecting
  #235's version-bump direction once it lands).
- Reconciling the three filed issues with this design: revising #241 in
  place (D-6) and correcting the audit report's WF-9 disposition note (D-8).

### Out of scope

- The `backlog` workflow and `scan_backlog.py` (D-1: stays personal).
- Reopening WF-6's disposition generally. Only `note-problem` is carved out
  of it; where the personal layer is versioned is unchanged.
- Retiring the personal copies after packaging — machine-local cleanup,
  already covered by WF-6's no-issue disposition.
- Any change to review/solve/repair workflow behavior.
- The epic and triage personal workflows (never document workflows).

## Design

Proposed shape, pending the open questions:

- **Parity by derivation, not by coincidence (D-4, CDW-1 → CDW-2).** First
  the tracked Codex design pair absorbs the authority sections, making the
  strengthened text the reviewed, SHA-addressable source; then the Claude
  counterparts are transposed *from that text* (tool names, `$ARGUMENTS` vs
  prompt wording, origin markers where applicable). That ordering is the
  point, not a formality: the two brands agree because one is derived from
  the other, rather than because two independently drifted lineages happen
  to align. WF-6 measured what independent drift costs — 147 diff lines in
  the `drain-prs` pair alone. §3.5's rationale is satisfied in the order it
  demands, and its statements (test-pinned verbatim) are amended in CDW-2
  to declare whatever remains Codex-only — nothing, once CDW-3 lands.
- **Authority text policy (D-3).** Strict wins uniformly: both brands'
  design pair carries an authority section equivalent in force to the
  personal copies', stated as enumerated behavioral clauses rather than as
  a byte-copy of an untracked file, and the permissive uncertainty sentence
  is replaced by "Never bury a blocking ambiguity in the document and
  proceed." One policy, both brands.
- **Report write side (CDW-3, D-1).** `draft-report` transposes to a
  Claude command from its tracked Codex text (already byte-stable across
  its copies). `note-problem` vendors into the Codex plugin from the
  personal skill — dropping the `agents/` sidecar the tracked-bundle checks
  forbid — and transposes to Claude, joining §2 as a cross-brand pair with
  the same status-vocabulary compatibility §3.4 requires of the process
  pair, and joining `DOCUMENT_WORKFLOW_NAMES` so the completeness check
  polices it. `note-problem` never writes a terminal marker, so like
  `$design-epic` and `$draft-report` it carries only the unchecked
  checklist form under §4. `backlog` stays personal (D-1).
- **issue-rereview packaging (CDW-4, D-2).** As its own asset pair under
  the drafting contract: §2 gains two rows, `DRAFTING_WORKFLOW_NAMES`
  gains the name, the packaged issue-review assets' "deliberately outside"
  sentences are rewritten to point at the packaged sibling, and the asset
  resolves the canonical backend through the installer record exactly as
  issue-review does (the portable-backend rules apply verbatim; rereview
  creates no issue, so the origin-marker creation rules exempt it like
  issue-review). The personal skill's hyphen-spelled `approve-issues.py`
  reference is corrected in the vendored text.
- **Contract-and-test atomicity.** Every slice that changes a declared set
  updates the contract rows, the boundary prose, and the hard-coded test
  expectations in one PR — the same discipline the existing suites force.

## Decisions

### D-1. The roster is the design pair plus the full report loop

User signoff 2026-08-10. `design-epic`, `process-design-doc`,
`draft-report`, and `note-problem` all become tracked cross-brand pairs;
`backlog` and its untracked scanner stay personal — one machine's
Markdown-audit tooling, not pipeline surface. The minimal roster (report
write side left one-brand) and the everything-roster (vendoring
`scan_backlog.py` into the release surface) were rejected. Consequence:
after CDW-2/CDW-3, §3.5's Codex-only set is empty and the section is
rewritten as history-plus-rule rather than deleted.

Reaffirmed 2026-08-11 against the filed issues, which contradict it: #241's
`Out of scope` and the WF-9 disposition note in the audit report both say
`note-problem` stays personal per WF-6. D-1 supersedes them for
`note-problem` only — WF-6 stands for `backlog` and for where the personal
layer is versioned. Further consequence: `note-problem` enters
`DOCUMENT_WORKFLOW_NAMES`, not just §2's row list, and the two contradicting
artifacts are corrected (D-6, D-8).

### D-2. issue-rereview is packaged as its own asset pair

User signoff 2026-08-10. It joins the drafting contract as a Claude+Codex
pair, mirroring pr-revise's standing; issue-review stays single-purpose.
Folding rereview into issue-review (repair authority in the readiness
gate, rule re-derivation) and accepting the asymmetry were rejected.
Consequence: §2 grows to nine rows and the issue-review assets'
"deliberately outside" sentences are rewritten to point at the sibling.

### D-3. Strict authority text wins uniformly

User signoff 2026-08-10. Both brands' design pair carries a "Human
interaction and decision authority" section equivalent in force to the
personal copies', and "Leave lesser uncertainty in the document instead of
blocking useful progress" is replaced by "Never bury a blocking ambiguity
in the document and proceed." Keeping the permissive sentence and
brand-divergent policy were rejected. Consequence: CDW-1 is a pure
strengthening; the cross-brand parity claim covers the authority text.

**Amended 2026-08-11 (user signoff):** the standard is behavioral
equivalence via enumerated clauses, not a verbatim copy of the personal
sections. The original wording — "land verbatim (modulo brand tokens)" —
made acceptance depend on `~/.claude/commands/design-epic.md` and
`process-design-doc.md`, which exist in no tracked path, so neither a
tracked test nor CI can evaluate it; #239's approved review reached the
same conclusion independently and amended its spec to say the enumerated
behavioral clauses govern. The rejected alternative was to hold the
verbatim standard and revise #239 back to it. Nothing about the *substance*
changes: the same guardrails land and the same permissive sentence goes.
The amendment also removes a tension with D-4, whose whole rationale is
that parity comes from deriving off tracked text rather than chasing
personal lineages — an acceptance criterion pointing back at an untracked
personal file cut against that. D-4 itself is unaffected, because CDW-2
derives from the tracked Codex text under either standard.

### D-4. The Claude design pair derives from the strengthened tracked Codex text

User signoff 2026-08-11, with stated uncertainty and an explicit request
that the strongest single text be what both agent classes read. The Claude
`design-epic` and `process-design-doc` commands are transposed from the
post-CDW-1 tracked Codex skills, not vendored byte-for-byte from the
personal Claude sources. `CDW-2` therefore depends on `CDW-1`, and the arc
has a real critical path.

Rationale: D-3 already fixes the authority text, so both routes land the
same guardrails — the difference is everything *else* in the two lineages.
The personal Claude and tracked Codex texts drifted independently, so
vendoring the personal copies would align the brands where they already
agreed and leave the remainder to chance. Deriving one from the other makes
the verification strategy's parity assertion a property of the process
instead of a coincidence to re-check forever.

Rejected: #241's model — vendor the personal Claude sources byte-for-byte
after SHA verification, leaving #241 independent of #239. It is faster and
has a pinned source today, but it buys parity only where parity already
existed.

Consequence: #241's requirements 1 and 5 are wrong under this design and
must be revised (D-6). The SHA pins #241 records stop being the
vendoring authority and become provenance for the authority sections CDW-1
merges.

### D-5. CDW-2 and CDW-3 stay separate slices

User delegated this call 2026-08-11 ("if you think it should be split then
i authorize it"); Claude's call is to keep them split. With `note-problem`
in scope per D-1, CDW-3 is a Claude `draft-report.md` plus a `note-problem`
pair across both plugins plus a §3.4-style status-compatibility statement —
five new assets between the two slices, spanning two contract sections and
a workflow-name set. The slices also carry different urgency: CDW-2 is
critical path, CDW-3 is not, and splitting preserves the ability to land the
critical path without waiting on the report write side.

Rejected: adopting #241's bundling of the Claude design pair with
`draft-report`. Consequence: #241 must be narrowed in place (D-6), and
the two slices contend for the same §2 table and the same test constants,
which D-7 resolves.

### D-6. #241 is revised in place, not closed and refiled

User signoff 2026-08-11. #241 is narrowed to CDW-2: requirement 1 is
rewritten to transpose from the post-#239 tracked Codex text, requirement 5
is dropped, `depends on #239` is added, and the `note-problem` clause is
removed from its `Out of scope`. CDW-3 is filed as a separate new issue.
Closing #241 and refiling two issues was rejected: revision preserves the
number, the review history, and the audit report's `WF-9 — [#241]` link,
which a refile would have to repoint.

Consequence: the edited spec re-enters the gate, so #241 is not workable
until a fresh review approves it. This is a tracker mutation, applied by
`/process-design-doc` under its own signoff, never by a design session.

**Amended 2026-08-11 (user signoff):** the mechanism stated above was wrong,
and the correction carries a hazard worth naming. Editing the body changes
the spec fingerprint — `tools/approve_issues.py` computes it from the body
and excludes the three workflow labels (`:501`) — so `current_gate_status`
stops matching the existing marker, reports "no current opposite-agent v2
review marker matches this spec", and flips the gate to not-approved. But
nothing removes the `reviewed:approve` label: the script strips those labels
only at publication (`:1382-1387`), and `Kanban.Domain` (`:427`) reads
`approvalLabel = "reviewed:approve"`, so the board would go on showing #241
as ready to solve against a spec its review no longer covers. Nor is this a
"rereview" in the backend's sense: `rereview_reviewers` raises "Issue
rereview requires a CHANGES_REQUESTED parent review" (`:681`) and #241's
marker is `verdict=APPROVE`, so the path is a fresh **initial** review,
routed to Codex by the claude origin marker. Therefore, when the revision is
applied, `reviewed:approve` is removed and `reviewed:revised` added — the
label whose own description is "Specification amended and awaiting
opposite-brand rereview" — and the next publication clears it automatically
(`:1383`).

### D-7. CDW-3 is serialized behind CDW-2

User signoff 2026-08-11. `CDW-3` depends on `CDW-2` as well as `CDW-1`. Both
slices add rows to `docs/document-workflow-contract.md` §2 and extend the
same constants in `tools/test_document_workflow_contract.py`, so running
them in parallel guarantees a conflict for whichever PR reaches the drainer
second. Running them in parallel and accepting one conflict repair was
rejected. Consequence: the arc is one chain — CDW-1 → CDW-2 → CDW-3 — with
CDW-4 independent alongside it. CDW-3 remains off the critical path in the
sense that nothing waits on *it*.

### D-8. The audit report's WF-9 note is corrected now, as a standalone publish

User signoff 2026-08-11. `docs/workflow_audit_findings.md` is a coordination
document, so the correction publishes straight to master rather than riding
in a slice's PR. It records that D-1 carved `note-problem` out of WF-6's
disposition — true as of today — rather than claiming an issue already
exists. Deferring it to CDW-3's run and leaving the report alone were both
rejected: a coordination document asserting the opposite of a signed-off
decision is precisely the drift this arc exists to remove, and a later
processing run could read the stale note as authority.

Consequence: one direct-to-master edit, with its exact text approved before
the push. It belongs to no slice and does not enter the epic's checklist.

### D-9. The slice scopes carry the full declared-inventory surface

User signoff 2026-08-11. D-5's split and D-7's serialization both stand.
What changes is the recorded scope: #241's approved review enumerated
surfaces this document's one-line scopes never named, and each one is
verified present in the tree. Every slice now lists them, with the counts it
must land.

Counts, verified today: the Claude plugin ships ten commands, §2 declares
five assets, and `process-report` is the sole cross-brand pair. CDW-2 takes
those to twelve, seven, and three; CDW-3 to fourteen, ten, and five.
`HASKELL_PARITY_COMMAND_NAMES` stays at five throughout, because every
workflow this arc adds is user-invoked and never Kanban-spawned.

The review's own numbers — "eight declared assets and four cross-brand
workflow pairs", "thirteen commands" — assume all three Claude commands land
in one PR *and* predate D-1 adding `note-problem`, so they are stale under
any arc shape and are superseded by the per-slice counts above.

Rejected: reverting the split to inherit the review's amendments unchanged.
It would not have restored the reviewed shape anyway — `note-problem` joined
the arc after that review — and it would have merged a critical-path slice
with one deliberately off it.

Consequence: §3.5 closes in two steps rather than one. CDW-2 reduces the
Codex-only set to `$draft-report` alone; CDW-3 empties it. Both slices still
fit one PR each: the bulk is two, then two more, Markdown assets plus
mechanical count updates across roughly six files.

## Open questions

### Q-1. Which workflows join the tracked cross-brand roster?

Resolved by D-1.

### Q-2. How does issue-rereview become brand-complete?

Resolved by D-2.

### Q-3. Which text wins where the design-pair variants conflict?

Resolved by D-3.

### Q-4. How is #241 reconciled with D-4 and D-5?

#241 is open and `reviewed:approve`, and both decisions invalidate parts of
it: D-4 rejects its vendoring model (requirements 1 and 5) and D-5 rejects
its bundling of `draft-report` with the design pair. It cannot land as
written. Options:

- **Revise #241 in place** — narrow it to CDW-2, rewrite requirement 1 to
  transpose from the post-#239 text, drop requirement 5, add `depends on
  #239`, and file CDW-3 separately. Keeps the number, the review history,
  and the audit report's `WF-9 — [#241]` link intact. The edited spec goes
  back to `reviewed:revised` for opposite-brand rereview.
- **Close #241 and refile two issues** — one per slice, each written against
  this design from the start. Cleaner specs; costs the review history and
  requires the audit report's WF-9 marker to be repointed.

Either way the work reaches the same place; the question is what happens to
the existing approved artifact. Resolved by D-6.

### Q-5. Does CDW-3 depend on CDW-2, or run in parallel?

Both slices add rows to `docs/document-workflow-contract.md` §2 and extend
the same hard-coded constants in `tools/test_document_workflow_contract.py`.
Run in parallel, whichever PR reaches the drainer second conflicts on both
files. Options: serialize (`CDW-3 depends on CDW-2`), trading wall-clock for
a guaranteed clean merge; or keep them parallel and accept one conflict
repair. No behavior differs either way — this is purely delivery order.

Resolved by D-7.

### Q-6. Which artifacts record D-1's supersession, and when?

Two tracked artifacts state that `note-problem` stays personal: #241's
`Out of scope` and the WF-9 disposition note in
`docs/workflow_audit_findings.md`. D-6 already repairs #241's fence, so only
the report note needs its own answer. The report is a
coordination document — it publishes straight to master per `CLAUDE.md` — so
amending it is a direct push, never part of a slice's PR. Options: publish
the correction now as a standalone edit; publish it during CDW-3's run,
when the superseding work actually lands; or leave the report alone and let
this design document carry the supersession by itself, accepting that the
report keeps asserting something this arc has decided against. Note that
#237 (open, `blocked`) is the issue about publishing an approved
coordination-document mutation in the same run that makes it, so the
mechanism is itself unfinished work.

Resolved by D-8.

## Verification strategy

- `tools/test_document_workflow_contract.py` and
  `tools/test_drafting_workflow_contract.py` are the arc's spine: every
  declared-set change lands with its expectation change, and the suites
  prove no undeclared asset and no dangling declaration.
- `tools/test_claude_plugin.py` / `tools/test_codex_plugin.py` validate
  frontmatter and body shape of every packaged asset, and pin the Claude
  command count and the five-name Haskell-parity set.
- `tools/test_agent_workflow_contract.py` is the third pinned inventory and
  the easiest to miss: its plugin surfaces are enumerated, not globbed, so a
  new asset is invisible to it until it is listed by hand (D-9).
- Cross-brand parity: for each packaged pair, a diff modulo the known brand
  transpose set (tool names, invocation tokens, origin markers) is empty —
  the same property `process-report` already exhibits, asserted as a fixture
  where the suites allow. Under D-4 this is a derivation invariant for the
  design pair, so a non-empty diff means the transpose was done wrong, not
  that the lineages drifted.
- The scope-gate, origin-marker, and portable-backend rule families in the
  drafting suite extend to `issue-rereview` (marker-exempt, backend via
  installer record, no model pinning).
- Manual: one design document and one findings report round-trip — started
  by one brand, advanced by the other — recorded as the arc's closing
  evidence.

## Delivery plan

### CDW-1. Merge the decision-authority guardrails into the tracked design workflows

- **Outcome:** the tracked Codex `design-epic` and `process-design-doc`
  carry the authority sections and D-3's conflict resolutions;
  the strengthened text is the pinned source for CDW-2.
- **Scope:** the two SKILL.md bodies; a document-workflow-contract statement
  of the decision-authority boundary with a check that fails when it is
  removed (#239's requirement 3); no declared-set change.
- **Filed as:** #239, merged. Covered this slice as written; no revision was
  identified. Its landed text is CDW-2's transpose source.
- **Phase:** 1
- **Depends on:** none
- **Ordering:** critical path
- **Relevant decisions:** D-3, D-4 (this slice produces D-4's source text)
- **Acceptance signals:** plugin suite green; both tracked design skills
  carry an authority section satisfying D-3's enumerated behavioral
  clauses, verifiable without reference to any untracked file; the
  permissive sentence is gone; the contract check fails when the authority
  statement is deleted.
- **Out of scope:** any Claude-side file; §2/§3.5 changes.
- **Open questions:** None

### CDW-2. Derive Claude counterparts for design-epic and process-design-doc

> **Processed 2026-08-12:** D-6's revision was applied to #241 — narrowed to
> this slice, requirement 1 rewritten to transpose from the post-#239 tracked
> Codex text, the old requirement 5 dropped, `depends on #239` added, and the
> `note-problem` fence removed from `Out of scope`. `reviewed:approve` was
> replaced with `reviewed:revised`; the spec awaits a fresh opposite-brand
> review before it is workable.

- **Outcome:** `/design-epic` and `/process-design-doc` exist as tracked
  Claude commands transposed from CDW-1's strengthened text (D-4), and every
  declared inventory, contract statement, and documentation claim that counts
  or brands the document workflows moves with them.
- **Scope (each item verified against the tree, D-9):**
  - two new command files under `claude-plugin/plugins/kanban/commands/`;
  - `docs/document-workflow-contract.md` — §2 gains two rows; §3's
    responsibility matrix flips two **Codex only** cells; §3.4's
    "only cross-brand pair" language; §3.5 records a *partial* closure,
    leaving `$draft-report` the sole remaining Codex-only workflow;
  - `claude-plugin/…/commands/process-report.md` — its Epic disposition
    hands off to Codex's `$design-epic`/`$process-design-doc` (`:262-263`,
    `:274-276`) and must name the Claude commands instead;
  - `tools/test_document_workflow_contract.py` — `EXPECTED_DECLARED_PATHS`
    5→7, `CODEX_ONLY_WORKFLOWS` 3→1, cross-brand pairs 1→3, and
    `test_claude_epic_disposition_routes_to_packaged_codex_workflows`
    (`:390`, having moved from `:328` when #239 landed) inverted: it currently
    *asserts* the Claude slash commands are absent, so it fails the moment they
    exist;
  - `tools/test_claude_plugin.py` — discovery ten→twelve, with
    `HASKELL_PARITY_COMMAND_NAMES` unchanged at five;
  - `tools/test_agent_workflow_contract.py` — `CLAUDE_PLUGIN_SURFACE_FILES`,
    `DOCUMENT_SURFACE_FILES`, and `DOCUMENT_SURFACE_EXPECTED_COMMANDS` are
    enumerated rather than globbed, plus `docs/agent-workflow-contract.md`'s
    matching prose;
  - `claude-plugin/README.md` (`:8`, `:91`, `:232` "exactly the ten packaged
    workflows"), `codex-plugin/README.md` (`:90`, `:108` "only
    `/process-report`… a declared gap"), `docs/README.md` (`:8`, which
    describes "the declared Codex-only gap"), and the Claude plugin manifest
    description.
- **Filed as:** #241, revised in place per D-6 on 2026-08-12 and now narrowed
  to this slice alone. It is not workable until the revised spec clears a
  fresh review.
- **Phase:** 2
- **Depends on:** CDW-1
- **Ordering:** critical path
- **Relevant decisions:** D-1, D-4, D-5, D-6, D-9
- **Acceptance signals:** `python3 -m unittest discover -s tools -p 'test_*.py'`
  green; transpose-parity diff against the post-CDW-1 Codex text empty; §3.5
  reads as a partial closure naming its pinned source rather than a deletion;
  no tracked file still claims ten Claude commands or a single cross-brand
  pair.
- **Out of scope:** `draft-report` and `note-problem` (CDW-3); issue-rereview
  (CDW-4); emptying §3.5's Codex-only set.
- **Open questions:** None

### [#328] CDW-3. Package the report write side for both brands

- **Outcome:** `/draft-report` exists as a Claude command; `note-problem`
  exists in both plugins as a cross-brand pair; the declared sets, the
  workflow-name set, and §3.5's closure all complete.
- **Scope (each item verified against the tree, D-9):**
  - `claude-plugin/…/commands/draft-report.md`, transposed from the tracked
    Codex skill, pinned by commit and SHA-256 at implementation time;
  - `codex-plugin/…/skills/note-problem/SKILL.md`, vendored from the personal
    skill without its `agents/` sidecar, plus an authored Claude
    `note-problem.md`;
  - `docs/document-workflow-contract.md` — §2 gains three rows; §3's matrix
    gains `note-problem` and flips `$draft-report`; a §3.4-style status
    compatibility statement for the write pair; §3.5's closure completes and
    the Codex-only set empties;
  - `tools/test_document_workflow_contract.py` — `DOCUMENT_WORKFLOW_NAMES`
    4→5, `EXPECTED_DECLARED_PATHS` 7→10, `CODEX_ONLY_WORKFLOWS` emptied,
    cross-brand pairs 3→5, and `note-problem` carrying only the unchecked
    checklist form under §4, as `$design-epic` and `$draft-report` do;
  - `tools/test_claude_plugin.py` discovery twelve→fourteen with parity still
    five; `tools/test_agent_workflow_contract.py`'s enumerated surfaces and
    `docs/agent-workflow-contract.md`; the three READMEs and the manifest.
- **Filed as:** #328, created 2026-08-15 once CDW-2 (#241) merged and D-7's
  serialization cleared. D-6 removed this slice's work from #241, so it became
  a new issue.
- **Phase:** 2
- **Depends on:** CDW-1, CDW-2 (D-7)
- **Ordering:** not on the critical path
- **Relevant decisions:** D-1, D-5, D-9
- **Acceptance signals:** `python3 -m unittest discover -s tools -p 'test_*.py'`
  green; a report created by either brand's draft-report is processable by
  either brand's process-report; the `agents/` sidecar is absent from the
  vendored `note-problem`; §3.5's Codex-only set is empty and the section
  reads as a completed closure record rather than a deletion.
- **Out of scope:** `backlog` (stays personal, D-1).
- **Open questions:** None

### [#240] CDW-4. Package issue-rereview for both brands

- **Outcome:** issue-rereview is a declared cross-brand pair under the
  drafting contract; the issue-review assets point at it instead of
  declaring it out-of-bundle; the repair loop closes from either brand.
- **Scope:** two new assets, drafting-contract §2 and boundary prose,
  `DRAFTING_WORKFLOW_NAMES`/path constants and affected rule families in
  its test, the two issue-review asset sentences, backend-resolution
  parity with issue-review.
- **Filed as:** #240, merged as PR #284 on 2026-08-12. Covers this slice as
  written; its stated prerequisite #238 had merged (PR #244).
- **Phase:** 2
- **Depends on:** none (contract-independent of CDW-1..3)
- **Ordering:** independent
- **Relevant decisions:** D-2
- **Acceptance signals:** drafting suite green including the extended rule
  families; a changes-requested issue is repaired and rereviewed from a
  Claude session against the fake backend.
- **Out of scope:** changing the canonical gate's verdict semantics.
- **Open questions:** None
