# Claude document workflows design

The tracked document-workflow bundle is single-brand where it matters most:
`$design-epic`, `$process-design-doc`, and `$draft-report` are declared
Codex-only, the personal Claude copies of the design pair carry
decision-authority guardrails the vendored Codex text dropped, the
write-side `note-problem` exists only in one machine's personal layer, and
a rejected issue's repair-and-rereview loop is closeable only from Codex.
This arc makes the document and issue-drafting loops brand-complete: the
strongest text becomes the pinned source, both plugins vendor it, and the
contracts that declared the gaps are amended instead of silently outgrown.
It subsumes audit findings WF-7, WF-8, and WF-9, which are unprocessed and
should defer to this epic when the report is processed.

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. Make the document and issue-drafting workflow loops brand-complete
- [ ] CDW-1. Merge the decision-authority guardrails into the tracked design workflows
- [ ] CDW-2. Vendor Claude counterparts for design-epic and process-design-doc
- [ ] CDW-3. Vendor Claude and Codex counterparts for the report write side
- [ ] CDW-4. Package issue-rereview for both brands

## Epic contract

- **Goal:** every document workflow (design capture, design processing,
  report drafting, report processing, observation capture) and the issue
  repair-and-rereview loop can be run from either brand, from the tracked
  bundles, under the same guardrails.
- **Done when:** the document-workflow contract's §2 table declares a
  Claude and Codex asset for each workflow this arc vendors; the §3.5
  Codex-only asymmetry is amended to whatever remains; the drafting
  contract packages issue-rereview for both brands; the strengthened
  authority text is identical across brands; and every touched test parser
  is green.
- **Users and operators:** Vincent working from either brand's session; the
  agent pipeline (assets are what solve/review sessions read); the contract
  tests that pin the declared sets.
- **Arc label:** existing `agent-workflows`.

## Current state and evidence

- **The asymmetry is declared, with a reason this arc satisfies.**
  `docs/document-workflow-contract.md` §3.5 (`:100-107`): the three
  workflows are Codex-only because "authoring one would be new behavior
  that no pinned source defines," per issue #118's SHA-pinned vendoring
  model — "The Claude plugin must not grow one under this contract until a
  pinned source exists to vendor." The personal Claude copies
  (`~/.claude/commands/design-epic.md`, `process-design-doc.md`) are
  exactly such a source, and the richer one.
- **The guardrail regression is concrete (WF-7).** The personal design
  pair carries a "Human interaction and decision authority" section —
  proposals-never-decisions, per-decision signoff, at most three questions
  per stop, "Never bury a blocking ambiguity in the document and proceed" —
  absent from `codex-plugin/plugins/kanban/skills/design-epic/SKILL.md` and
  `process-design-doc/SKILL.md`, which instead say "Leave lesser
  uncertainty in the document instead of blocking useful progress." The
  tracked source of truth is the weaker text.
- **The declared-asset machinery is test-pinned.**
  `tools/test_document_workflow_contract.py` hard-codes
  `EXPECTED_DECLARED_PATHS` (`:51-57`), the Codex-only set (`:59`), and the
  §3.5 statements verbatim (`:105-109`); it also fails if any
  document-workflow name appears in a plugin without a §2 row (`:182-188`,
  `:221`). Contract, assets, and test move in the same PR or nothing
  moves.
- **The report write side is personal-only.** `~/.codex/skills/note-problem/`
  (capture one verified observation into a process-report-compatible
  report) has no tracked copy in either plugin and no Claude counterpart
  anywhere; `~/.codex/skills/backlog/` (Markdown-document audit, with the
  untracked 14.6 KB `scripts/scan_backlog.py`) is likewise personal-only.
- **issue-rereview is Codex-personal and declared out-of-bundle (WF-8).**
  `~/.codex/skills/issue-rereview/` is the sole copy; both plugins' packaged
  issue-review assets state the rereview workflow is "deliberately outside
  this bundle's packaged set," and `docs/drafting-workflow-contract.md` §2
  (seven rows, `:35-43`) records the boundary.
  `tools/test_drafting_workflow_contract.py` pins
  `DRAFTING_WORKFLOW_NAMES` (`:43`) and the seven paths (`:45-57`); its
  scope-gate, origin-marker, and portable-backend rules would apply to any
  new drafting asset. The backend already supports rereview
  (`tools/approve_issues.py --rereview`).
- **The Claude command format is settled.** `claude-plugin/…/commands/*.md`
  frontmatter (`description`, `argument-hint`) plus `$ARGUMENTS` and the
  docs-worktree resolution block; `process-report.md` is byte-identical to
  its personal Claude copy, proving the transpose pattern round-trips.
- **Cross-arc state.** WF-7/8/9 are unprocessed in
  `docs/workflow_audit_findings.md` (Lane-1 processing is at WF-6); no
  open issue or epic overlaps (#234-#238 are workflow-tooling items;
  closed #229/#231 vendored the current Codex-only set; closed #79 was the
  portability epic this extends in spirit).

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
- Claude-plugin vendoring of `design-epic`, `process-design-doc`,
  `draft-report`; both-plugin vendoring of `note-problem` (per Q-1).
- Packaging `issue-rereview` for both brands under the drafting contract.
- Amendments to both contracts' declared sets, boundary statements, and
  their test parsers; plugin manifest updates (respecting #235's
  version-bump direction once it lands).

### Out of scope

- The `backlog` workflow and `scan_backlog.py` (per Q-1's answer — see the
  question; default: stays personal).
- Retiring the personal copies after vendoring — machine-local cleanup,
  already covered by WF-6's no-issue disposition.
- Any change to review/solve/repair workflow behavior.
- The epic and triage personal workflows (never document workflows).

## Design

Proposed shape, pending the open questions:

- **Pinned-source rule honored, not bypassed (CDW-1 → CDW-2).** First the
  tracked Codex design pair absorbs the authority sections, making the
  strengthened text the reviewed, SHA-addressable source; then the Claude
  counterparts vendor from it by brand transpose (tool names, `$ARGUMENTS`
  vs prompt wording, origin markers where applicable). §3.5's rationale is
  thereby satisfied in the order it demands, and its statements (test-pinned
  verbatim) are amended in CDW-2 to declare whatever remains Codex-only —
  nothing, if Q-1 chooses the full roster.
- **Authority text policy (D-3).** Strict wins uniformly: the personal
  copies' authority sections land verbatim in both brands' design pair,
  and the permissive uncertainty sentence is replaced by "Never bury a
  blocking ambiguity in the document and proceed." One policy, both
  brands.
- **Report write side (CDW-3, D-1).** `draft-report` transposes to a
  Claude command from its tracked Codex text (already byte-stable across
  its copies). `note-problem` vendors into the Codex plugin from the
  personal skill and transposes to Claude, joining §2 as a cross-brand
  pair with the same status-vocabulary compatibility §3.4 requires of the
  process pair. `backlog` stays personal (D-1).
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

### D-2. issue-rereview is packaged as its own asset pair

User signoff 2026-08-10. It joins the drafting contract as a Claude+Codex
pair, mirroring pr-revise's standing; issue-review stays single-purpose.
Folding rereview into issue-review (repair authority in the readiness
gate, rule re-derivation) and accepting the asymmetry were rejected.
Consequence: §2 grows to nine rows and the issue-review assets'
"deliberately outside" sentences are rewritten to point at the sibling.

### D-3. Strict authority text wins uniformly

User signoff 2026-08-10. The personal copies' "Human interaction and
decision authority" sections land verbatim (modulo brand tokens) in both
brands' design pair, and "Leave lesser uncertainty in the document instead
of blocking useful progress" is replaced by "Never bury a blocking
ambiguity in the document and proceed." Keeping the permissive sentence
and brand-divergent policy were rejected. Consequence: CDW-1 is a pure
strengthening; the cross-brand parity claim covers the authority text.

## Open questions

### Q-1. Which workflows join the tracked cross-brand roster?

Resolved by D-1.

### Q-2. How does issue-rereview become brand-complete?

Resolved by D-2.

### Q-3. Which text wins where the design-pair variants conflict?

Resolved by D-3.

## Verification strategy

- `tools/test_document_workflow_contract.py` and
  `tools/test_drafting_workflow_contract.py` are the arc's spine: every
  declared-set change lands with its expectation change, and the suites
  prove no undeclared asset and no dangling declaration.
- `tools/test_claude_plugin.py` / `tools/test_codex_plugin.py` validate
  frontmatter and body shape of every vendored asset.
- Cross-brand parity: for each vendored pair, a diff modulo the known
  brand transpose set (tool names, invocation tokens, origin markers) is
  empty — the same property `process-report` already exhibits, asserted as
  a fixture where the suites allow.
- The scope-gate, origin-marker, and portable-backend rule families in the
  drafting suite extend to `issue-rereview` (marker-exempt, backend via
  installer record, no model pinning).
- Manual: one design document and one findings report round-trip — started
  by one brand, advanced by the other — recorded as the arc's closing
  evidence.

## Delivery plan

### CDW-1. Merge the decision-authority guardrails into the tracked design workflows

- **Outcome:** the tracked Codex `design-epic` and `process-design-doc`
  carry the authority sections and the Q-3-chosen conflict resolutions;
  the strengthened text is the pinned source for CDW-2.
- **Scope:** the two SKILL.md bodies; document-workflow-contract prose only
  if it quotes affected sentences; no declared-set change.
- **Phase:** 1
- **Depends on:** none
- **Ordering:** critical path
- **Relevant decisions:** D-3
- **Acceptance signals:** plugin suite green; the authority section reads
  identically to the personal source modulo brand tokens; the permissive
  sentence is gone.
- **Out of scope:** any Claude-side file; §2/§3.5 changes.
- **Open questions:** None

### CDW-2. Vendor Claude counterparts for design-epic and process-design-doc

- **Outcome:** `/design-epic` and `/process-design-doc` exist as tracked
  Claude commands transposed from CDW-1's text; §2 gains their rows; §3.5
  is amended; test expectations updated.
- **Scope:** two new command files, contract rows and statements, test
  constants, plugin manifest description.
- **Phase:** 2
- **Depends on:** CDW-1
- **Ordering:** critical path
- **Relevant decisions:** D-1
- **Acceptance signals:** document-workflow and Claude-plugin suites green;
  transpose-parity diff empty; the pinned-source rationale in §3.5 is
  satisfied, not deleted.
- **Out of scope:** report workflows; issue-rereview.
- **Open questions:** None

### CDW-3. Vendor Claude and Codex counterparts for the report write side

- **Outcome:** `/draft-report` exists as a Claude command; `note-problem`
  exists in both plugins as a cross-brand pair; §2 and tests updated.
- **Scope:** the new command/skill files, §2 rows, §3.4-style status
  compatibility statement for the write pair, test constants.
- **Phase:** 2
- **Depends on:** CDW-1
- **Ordering:** not on the critical path
- **Relevant decisions:** D-1
- **Acceptance signals:** suites green; a report created by either brand's
  draft-report is processable by either brand's process-report.
- **Out of scope:** `backlog` (stays personal, D-1).
- **Open questions:** None

### CDW-4. Package issue-rereview for both brands

- **Outcome:** issue-rereview is a declared cross-brand pair under the
  drafting contract; the issue-review assets point at it instead of
  declaring it out-of-bundle; the repair loop closes from either brand.
- **Scope:** two new assets, drafting-contract §2 and boundary prose,
  `DRAFTING_WORKFLOW_NAMES`/path constants and affected rule families in
  its test, the two issue-review asset sentences, backend-resolution
  parity with issue-review.
- **Phase:** 2
- **Depends on:** none (contract-independent of CDW-1..3)
- **Ordering:** independent
- **Relevant decisions:** D-2
- **Acceptance signals:** drafting suite green including the extended rule
  families; a changes-requested issue is repaired and rereviewed from a
  Claude session against the fake backend.
- **Out of scope:** changing the canonical gate's verdict semantics.
- **Open questions:** None
