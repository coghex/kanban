# Project Review Findings: PRs #660–#648

Target: `coghex/kanban`, reviewed on 2026-09-10 at
`master@19acaf1ea3cf8fad7637c8c884a0553aef3b3c4b` in
`/Users/vincentcoghlan/work/kanban`.

This is a subject-scoped audit of exactly six merged pull requests, in merge
order newest first: #660, #658, #654, #653, #649, and #648. They introduce the
Google/Gemini, Kimi, and Grok origin routing and solve/autosolve bundles. The
linked Kimi issues #651 and #652, their canonical amendments, all six PR bodies,
commit histories, review iterations, landed changes, current consumers, and
relevant tests were inspected. The interleaved UI, mission, and precondition
PRs are outside this audit and are not recorded as reviewed. Direct commits
`f72928c`, `3f42963`, and `1c9bb94` were inspected individually; they only update
the unrelated board-quick-wins report's dispositions and introduce no integration
behavior. The existing exclusive older PR boundary remains #533.

The integrations deliberately add external author origins, not spawned
providers. Their absence from the board's solver chooser, usage tracking, and
provider adapters is consistent with their scope. Board revision/repair is
refused; autosolve performs revisions in the original external session. Kimi
and Google additionally support issue-origin recognition, which their specs
requested. Grok issue-origin support was not requested.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [x] PRR-1. Standard reviewers lose Grok provenance on fork pull requests — [#696]
- [x] PRR-2. Copilot helper discovery rejects valid remote marketplace records — [#698]
- [x] PRR-3. Autosolve approval handoff contradicts the drainer contract — [#699]
- [x] PRR-4. External solve workflows duplicate their policy without an authored source — [#715]
- [ ] PRR-5. Bundle brand is never checked against the model the session runs

## 1. Review routing across entry points

### [#696] PRR-1. Standard reviewers lose Grok provenance on fork pull requests

> **Captured note:** Complete Grok's fork-PR routing across the standard Codex
> and Claude coordinators. PR #649 fixed this only in the external coordinator;
> the standard coordinators still discard a valid Grok origin and take the
> dual-review route, contrary to the Codex-only origin contract introduced by
> PR #648. Kimi and Google later received the corresponding fix everywhere.

**Verification:** Imported all five current coordinator modules and called their
production `pr_origin` and `route_reviewers` functions with a valid final marker,
`isCrossRepository=True`, dual mode, and both providers loaded. No GitHub write
or model invocation was performed.

| Coordinator | Grok fork | Kimi fork | Google fork |
|---|---|---|---|
| Codex | Unknown; Codex + Claude | Kimi; Codex | Google; Codex |
| Claude | Unknown; Codex + Claude | Kimi; Codex | Google; Codex |
| Grok, Kimi, Google | Grok; Codex | Kimi; Codex | Google; Codex |

The board selects Codex for a valid Grok body, then invokes its packaged
`pr-review`/`pr-rereview` workflow. That workflow consults the standard Codex
coordinator, so the discrepancy affects a real handoff outside Grok's own
autosolve. It can spend Claude quota or fail when Claude is unavailable even
though the Grok action's preflight correctly required only Codex. A dual approval
also conflicts with finalize's requirement of a Codex-only marker for Grok.

**Evidence:**

- `codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py:568` —
  `pr_origin` retains only Kimi and Google markers for fork PRs.
- `claude-plugin/plugins/kanban/scripts/review_pr.py:615` — the same omission.
- `grok-plugin/plugins/kanban/scripts/review_pr.py:615` — the external copy
  retains Grok, Kimi, and Google; the other external copies are byte-identical.
- `codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py:452` —
  unknown origins become the two-provider route in dual mode.
- `src/Kanban/PullRequestFlow.hs:220` and `:486` — the Haskell route chooses
  Codex and dispatches the packaged review command.
- `codex-plugin/plugins/kanban/skills/pr-review/SKILL.md:13` — that command
  resolves the standard coordinator and delegates review routing to it.
- `tools/test_coordinator_parity.py:343` — the parity fixture expressly permits
  the differing fork-origin sets, so the passing gate preserves this defect.
- `docs/agent-workflow-contract.md:180` — known Grok/Kimi/Google origins have
  Codex as their dual-mode reviewer, never both brands.

**Handoff context:**

- **Current behavior:** A Grok fork PR works through external autosolve but
  receives a different reviewer route through the standard review workflows.
- **Expected behavior:** All supported review entry points retain the same
  valid Grok fork provenance and choose Codex in dual mode.
- **Scope and constraints:** Align the two standard coordinators, their parity
  record, and relevant bundle versions. Preserve malformed-marker rejection,
  single-agent/no-agent behavior, and existing treatment of other fork origins.
  Do not add Grok as a spawned provider or canonical reviewer.
- **Verification target:** Exercise every coordinator against each external
  origin on same-repository and fork PRs, then exercise the standard workflow
  with fake executables to prove no Claude spawn for a Grok fork. Check the
  resulting marker is accepted by the existing finalize gate.
- **Deduplication:** Open-issue inventory and all-state searches for `grok fork`
  and `grok origin` found no issue covering this surviving standard-coordinator
  gap. Closed #651/#652 describe Kimi work, not a pending Grok correction.
- **Remaining uncertainty:** None about the reproduced route disagreement.
  This audit did not launch paid reviewers on a live fork PR.

## 2. Copilot installation compatibility

### [#698] PRR-2. Copilot helper discovery rejects valid remote marketplace records

> **Captured note:** Reconcile Kimi and Google's advertised copied/git-source
> installation fallback with their rejection of valid Git/GitHub marketplace
> records. This behavior originates in PR #654 and was copied into PR #660.
> A local marketplace installation or explicit plugin-root launch works.

**Verification:** Extracted the actual Python locator fences from both solve
and autosolve skills and executed them from an unrelated temporary directory.
Each temporary Copilot profile contained exactly one installed Kanban helper
at the documented hashed-install path. Its settings had a same-name marketplace
with a valid non-directory source shape, for example:

```json
{"extraKnownMarketplaces":{"kanban-kimi":{"source":{"source":"github","repo":"example/kanban-kimi-marketplace"}}}}
```

The Google case used a `git` source and `url`. All four locators exited 1 with
empty stdout and `do not name kanban-<brand> as a directory source`, before
the copied-install search. Pointing the explicit plugin-root argument at the
same installed tree made all four pass, proving the helper's presence and
relative layout were not the problem. The fixture source URLs were never
contacted and the inert helper files were never executed.

GitHub's [Copilot configuration reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference)
documents `directory`, `git`, and `github` as valid marketplace source kinds.
The installed Copilot CLI 1.0.83's `plugin marketplace add --help` also accepts
GitHub repositories, URLs, and local paths. Existing tests specifically assert
that a GitHub marketplace record must fail, so this is a compatibility/contract
gap the tests preserve, not a test failure.

**Evidence:**

- `kimi-plugin/plugins/kanban/skills/solve/SKILL.md:126` and `:133` — any
  same-name marketplace entry is treated as local; non-directory sources exit
  before the installed-plugin search at line 143.
- `kimi-plugin/plugins/kanban/skills/autosolve/SKILL.md:215` — the analogous
  coordinator locator has the same control flow.
- `google-plugin/plugins/kanban/skills/solve/SKILL.md:126` and
  `google-plugin/plugins/kanban/skills/autosolve/SKILL.md:215` — the copied
  Google locators behave identically.
- `kimi-plugin/README.md:62` and `google-plugin/README.md:63` — describe a
  copied git-source install fallback when no local marketplace entry exists.
- `tools/test_kimi_plugin.py:414` and `:429` — the passing copied-install
  fixture omits the marketplace record; the next test requires rejection when
  a GitHub record is present.
- `tools/test_google_plugin.py:401` and `:416` — the same fixture gap and
  explicit rejection assertion.

**Handoff context:**

- **Current behavior:** Local checkout marketplace installs and explicit
  plugin-root launches work. A remote marketplace record for the expected
  brand prevents discovery of an otherwise valid copied install.
- **Expected behavior:** State and test an accurate installation contract. If
  remote/copied installs are supported, resolve them using their actual source
  and install identity. If only local-checkout installs are intended, say so
  explicitly and remove the misleading remote fallback promise.
- **Scope and constraints:** Correct both locators for both Copilot bundles,
  their tests, and any affected documentation/version metadata. Keep malformed
  records, ambiguous installs, and wrong-brand helper selection fail-closed;
  do not fix this by accepting any arbitrary `kanban-*` directory.
- **Verification target:** Use a valid same-name Git/GitHub marketplace record
  plus its copied install, alongside local-record and explicit-root controls.
  Retain missing-helper, malformed-settings, and multiple-install refusals.
  A real CLI installation fixture is preferable to a synthetic empty profile.
- **Deduplication:** All-state searches for `marketplace resolver`, `copied
  install`, `kimi plugin`, and `google plugin` found no pending correction.
  Closed #652 specifies the local marketplace decision table but does not
  resolve the mismatch between valid remote records and the README fallback.
- **Remaining uncertainty:** This audit reproduced locator behavior with
  realistic synthetic remote records, not a published remote Kanban
  marketplace. No failure is claimed for the documented local launch commands;
  those were separately installed successfully with the real CLI.

## 3. Autosolve approval handoff

### [#699] PRR-3. Autosolve approval handoff contradicts the drainer contract

> **Captured note:** Every packaged autosolve workflow stops after approval,
> but its terminal wording directs the user to run `finalize`. The external
> bundles do not ship that workflow, and the current agent-workflow contract
> gives ordinary eligible merges to the PR drainer. Manual finalization is an
> explicit, drainer-unavailable fallback, not the normal autosolve handoff.

**Verification:** Read the authored Claude/Codex autosolve source, each of the
three external autosolve skills, their terminal-behavior assertions, and
`docs/agent-workflow-contract.md` §2.10. No workflow, drainer, or GitHub
mutation was launched.

**Evidence:**

- `tools/command_sources/autosolve.md` supplies the inherited terminal wording
  for the Claude/Codex outputs.
- The Grok, Kimi, and Google autosolve skills carry the same manual-finalize
  implication despite having no such workflow in their bundles.
- `tools/test_autosolve_workflow.py` accepts the old handoff, so the existing
  passing suite preserves it.
- `docs/agent-workflow-contract.md` §2.10 gives merging to the drainer and
  reserves `finalize` for an explicit user request when the drainer cannot be
  used.

**Handoff context:**

- **Current behavior:** Approval ends with an instruction that is unavailable
  for three bundles and misstates the ordinary merge authority.
- **Expected behavior:** Every bundle reports approval without promising or
  directing a merge; the documentation may explain that a running drainer owns
  subsequent eligible merges, while preserving the manual fallback boundary.
- **Scope and constraints:** Update the common source, rendered Claude/Codex
  assets, and the three external assets together; assert the corrected terminal
  behavior across all five. Preserve the five-round loop, verdict-label
  authority, and prohibition on autosolve merge/finalize/drainer control.
- **Verification target:** A planted restoration of the unconditional
  `finalize` instruction in any output fails; existing negative assertions
  still prove no workflow executes merge, finalize, or drainer control.
- **Deduplication:** Current open- and all-state title searches found no issue
  for this handoff inconsistency. #576 is its inherited source, not a pending
  correction.
- **Remaining uncertainty:** A consuming repository need not have a running
  drainer, so corrected wording must not promise that approval will merge.

## 4. Shared external workflow authoring

### [#715] PRR-4. External solve workflows duplicate their policy without an authored source

> **Captured note:** Grok, Kimi, and Google each retain independently edited
> solve and autosolve skill files. The copies already propagated both the
> Copilot-discovery defect and the stale approval-handoff wording. Existing
> renderer support covers only Claude/Codex, leaving six external workflow
> outputs outside a shared authored-policy and stale-output check.

**Verification:** Compared the external solve/autosolve skills, their bundle
tests, and `tools/render_command_sources.py`'s declared source/output registry.
The Python coordinators and trusted helpers have separate parity gates; this
finding concerns the natural-language workflow policy.

**Evidence:**

- Kimi and Google workflow bodies are near-identical apart from brand-specific
  names and installation details; Grok shares their policy with distinct CLI
  argument binding and helper discovery.
- `tools/render_command_sources.py --check` detects stale rendered
  Claude/Codex command outputs but has no external solve/autosolve source or
  output registration.
- The independently copied files preserved the PRR-2 locator assumption and
  PRR-3 terminal handoff until this review exposed both.

**Handoff context:**

- **Current behavior:** Each external bundle can silently diverge in shared
  workflow policy even while helper/coordinator equality checks pass.
- **Expected behavior:** One explicitly targeted authored solve source and one
  autosolve source render self-contained Grok, Kimi, and Google outputs, with
  their required frontmatter, argument forms, origin markers, and lookup
  boundaries made explicit.
- **Scope and constraints:** Extend the existing renderer rather than create a
  second templating system. Preserve the Claude/Codex output bytes, external
  inventories, helper/coordinator parity gates, and brand-specific runtime
  differences. This is a behavior-preserving migration after PRR-2 and PRR-3
  are corrected.
- **Verification target:** Deterministic and idempotent renders, stale-output
  rejection, exact pre/post-migration output comparison, and a planted shared
  policy change affecting all three intended external outputs but no others.
- **Deduplication:** No current tracker issue covers shared external workflow
  authoring. #375 established the existing renderer; #373 covered the earlier
  Claude/Codex vendoring arc.
- **Remaining uncertainty:** The implementation must preserve platform-specific
  distinctions rather than treating the three bundles as a blind text
  substitution.

## 5. Bundle brand provenance

### PRR-5. Bundle brand is never checked against the model the session runs

> **Captured note:** Nothing enforces at runtime that a bundle's brand matches
> the model the session is actually running, so a Copilot session running a
> Claude model that loads the Kimi or Google bundle stamps a false origin marker
> on Claude-authored work.

**Verification:** Verified — the rule is documented in both Copilot bundles and
enforced nowhere, no reliable runtime signal for the running model exists, and
the default Copilot profile on the audited host is currently in the hazardous
configuration. Read the bundle READMEs and skills, grepped both bundles for the
model, probed the installed Copilot CLI 1.0.85 for a model signal, and inspected
the host's own Copilot profile. No workflow was launched and nothing was mutated.

**Evidence:**

- `kimi-plugin/README.md:32` and `google-plugin/README.md:33` — state the rule:
  "a Copilot session using a Claude model is a canonical Claude participant and
  must not load the Kimi bundle", and the Google equivalent.
- `kimi-plugin/README.md:5,40,55` and `google-plugin/README.md:5,41,56` — the
  model appears only in prose and launch examples. The `--model` occurrences in
  each bundle's `review_pr.py` near `:1305` and `:1354` pin the nested canonical
  reviewer's model, not the hosting session's.
- `kimi-plugin/plugins/kanban/skills/solve/SKILL.md:183` and the Google copy at
  the same line — require `<!-- pr-origin:kimi -->` / `<!-- pr-origin:google -->`
  as the final body line, unconditionally. No step reads what model is running.
- `~/.copilot/settings.json` on the audited host — `model: claude-opus-4.8` with
  `enabledPlugins: {"kanban@kanban-kimi": true}`. Plain `copilot` in this profile
  is a Claude session with the Kimi bundle enabled. Both READMEs prescribe an
  isolated `COPILOT_HOME` to keep these apart.
- Copilot CLI 1.0.85 — `settings.json`'s `model` is the configured default and
  `--model` overrides it per session; no `COPILOT_*` variable reaches a skill's
  environment, and `open-sessions-state.json` records no model. So the running
  model is not reliably observable from inside a skill.
- `docs/agent-workflow-contract.md:223` — grok, kimi, and google are known
  origins whose cross-brand reviewer is Codex, never Claude and never both.
- `codex-plugin/plugins/kanban/skills/finalize/SKILL.md:356` — compares the
  review marker's reviewer set with `!=` against `EXTERNAL_ORIGIN_REVIEWERS`,
  `{"codex"}` for kimi and google; the `elif origin in reviewers` branch above it
  is the self-review refusal that the origin marker's truth underwrites.

**Handoff context:**

- **Current behavior:** a Copilot session stamps its loaded bundle's brand
  regardless of the model generating the work. Brand and bundle agree only
  because the operator chose the matching bundle and profile.
- **Expected behavior:** provenance a reader can rely on. Either the session
  establishes that its model matches the bundle's brand before stamping, or the
  documentation states plainly that the marker records which bundle was loaded
  rather than which model authored the change, and the operator setup makes
  mismatching hard.
- **Scope and constraints:** the two Copilot bundles are the subject. A false
  `kimi` marker on Claude-authored code still routes to Codex, a legitimate
  opposite-brand reviewer for Claude, so no review published so far is unsound —
  what is lost is the provenance record and the premise of the self-review
  refusal. A Copilot session running a Codex-family model would route wrongly.
  Any guard must stay fail-closed and must not make the bundles unusable on a
  host where the model cannot be determined.
- **Remaining uncertainty:** whether the Grok CLI can host other model brands
  was not examined; `$GROK_HOME` is a separate CLI and may not have the gap. No
  pull request has been checked for a marker that is actually false — the hazard
  is established from configuration, not from a mislabelled artifact found in
  the tracker.

## 6. Validation and model comparison

The following checks passed at the audited HEAD:

- 395 Python tests: Grok/Kimi/Google bundles, coordinator parity, finalize,
  trusted issue specs, and packaged issue-review discovery.
- 240 Python tests: workflow contracts, source distribution, document
  classification, and drafting contracts.
- 93 Haskell examples after a warning-clean rebuild:
  `cabal test kanban-test --test-show-details=direct --test-options='--match grok --match kimi --match google --match single-agent --match routing'`.
- Real local-marketplace registration and installation for all three bundles,
  each under its own temporary `GROK_HOME` or `COPILOT_HOME`. Copilot reported
  two skills and enabled the expected Kimi/Google marketplace; Grok installed
  its Kanban plugin. No personal profile was changed.
- Production-function fork routing and all four Copilot locator probes
  described above. Temporary reproduction artifacts were retained at
  `/tmp/kanban-integration-review.ihM8MK/`; the fixtures and observed results
  are described here so the findings do not depend on that temporary path.

No live solve/autosolve model session, GitHub mutation, or code fix was performed.
Tests establish routing/packaging behavior, not the models' ability to follow
every natural-language instruction on an arbitrary future issue.

On the evidence of these PRs, Gemini Flash delivered the cleanest extension,
Kimi is close behind, and Grok needed the most supervision. This is a ranking
of the observed work, not a general model capability benchmark. GitHub origin
markers identify the authoring brand, not an attested model ID; attribution to
the named models follows the user's account.

| Authoring model | Reviewed PRs | Changes-requested rounds before approval | Assessment |
|---|---|---|---|
| Gemini Flash | #658, #660 | 1 + 3 | Best observed delivery. Routing consistently extended Kimi; initial core review caught a deterministic test expectation error and a missing contract update. Plugin rereviews concerned stale counts/descriptions, not newly broken routing. |
| Kimi | #653, #654 | 2 + 3 | Close second, with more original integration work: first Copilot packaging, local marketplace discovery, and external issue-origin support. Review caught missing normative issue-revision/fork rules, a live revision race, incomplete coverage, and a dangling-settings-symlink fallback. |
| Grok | #648, #649 | 2 + 8 | Most supervision. Review caught missing bundle bumps/finalize support, argument binding, broken install discovery, an unavailable docs workflow, leaked claims, repeated route-publication races, and fork support. |

These are counts of canonical `CHANGES_REQUESTED` publications, not distinct
bugs or comparable task effort. Repeated count/prose corrections inflated all
three totals. Grok built the first external-provider pattern; Kimi inherited
its reviewed fixes, and Gemini inherited both predecessors. The final quality
also reflects substantial Codex/Claude review assistance.

Examples of already-fixed findings, not additional open entries: Grok's
[initial plugin review](https://github.com/coghex/kanban/pull/649#issuecomment-5579251760)
and [publication-race rereview](https://github.com/coghex/kanban/pull/649#issuecomment-5580522595),
Kimi's [missing contract behavior](https://github.com/coghex/kanban/pull/653#issuecomment-5589548665),
and Google's [initial core review](https://github.com/coghex/kanban/pull/658#issuecomment-5609611308).
No newly confirmed finding was already covered by an open tracker issue.

## 7. Suggestions beyond the five findings

- Keep these models on bounded issue implementation with independent Codex
  review. The review history demonstrates that the gate caught substantial
  failures; the merged code should not be treated as unaided model output.
- Add one behavior matrix across every coordinator, origin, operating mode,
  and fork status. Existing byte/parity gates can agree with a wrong expected
  difference, as PRR-1 demonstrates.
- Avoid manually repeating inventory counts in prose, or derive those passages.
  Many review rounds corrected counts without improving runtime behavior.
- To compare the models fairly, use several similarly sized approved issues
  and track first-review functional blockers, reviewer time, completion rate,
  and cost. These six dependent integrations are too small and uneven a sample
  for an overall capability ranking.
