# External workflow authoring design

The Grok, Kimi, and Google bundles ship `solve` and `autosolve` as six
hand-maintained Markdown assets. They state one shared workflow policy three
times, nothing compares them, and two defects found in a single review had
already propagated into all three copies. This arc gives them an authored
source rendered by the existing `tools/render_command_sources.py`, so the shared
policy is written once and a drifted output fails a gate instead of shipping.

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Author the external bundles' solve and autosolve workflows from a rendered source — [#715]
- [x] EXT-1. Generalize the command renderer beyond two brands — [#716]
- [x] EXT-2. Render the external solve workflows from an authored source — [#717]
- [ ] EXT-3. Render the external autosolve workflows from an authored source

## Epic contract

- **Goal:** the Grok, Kimi, and Google `solve` and `autosolve` assets are
  rendered outputs of authored sources rather than hand-edited copies, so a
  shared policy change is written once and reaches every bundle that owes it,
  and a stale or hand-edited output fails `tools/render_command_sources.py
  --check`.
- **Done when:** all six external assets are rendered; `--check` covers them;
  the rendered bytes are identical to the pre-migration bytes; and a planted
  shared-policy edit reaches exactly the intended external outputs and no
  others.
- **Users and operators:** the maintainer editing workflow policy, who today
  must remember which of five bundles owes a change; and the Grok, Kimi, and
  Google sessions that execute these assets.
- **Arc label:** `agent-workflows`

## Current state and evidence

Verified against `master@0c663c2ef8d6` on 2026-09-17.

**Six hand-maintained assets, 1,604 lines.**

| Asset | grok | kimi | google |
|---|---|---|---|
| `plugins/kanban/skills/solve/SKILL.md` | 166 | 202 | 202 |
| `plugins/kanban/skills/autosolve/SKILL.md` | 318 | 358 | 358 |

Measured divergence: kimi↔google differ in 22 of 202 solve lines and 50 of 358
autosolve lines; kimi↔grok differ in 62 and 112 respectively.

**The kimi↔google divergence is token substitution.** Every differing solve line
is the brand name, the plugin-root variable (`$KIMI_PLUGIN_ROOT` /
`$GOOGLE_PLUGIN_ROOT`), the marketplace name (`kanban-kimi` / `kanban-google`),
the origin marker (`pr-origin:kimi` / `pr-origin:google`), or the sibling-brand
enumeration described below.

**The grok divergence is concentrated, not diffuse.** Both files carry the same
seven section headings in the same order. Of grok's 62 differing solve lines,
roughly fifty are one contiguous helper-discovery block: Grok resolves
`$GROK_PLUGIN_ROOT` then `$GROK_HOME/installed-plugins/kanban-<hash>/` in two
steps, while the Copilot bundles parse `$COPILOT_HOME/settings.json` for a
recorded marketplace path in three. The remainder is `argument-hint` frontmatter
(grok only) and the argument-binding instruction: Grok receives a substituted
argument, while `kimi-plugin/.../solve/SKILL.md:70` tells the reader "Copilot
skills receive no substituted arguments: the number is whatever the user named".
So the raw 34% figure overstates how scattered the difference is — it is two
brand-block-sized regions.

**A derived enumeration already drifts by construction.** Each bundle's
description names the sibling brands it must not imitate: grok names "a Claude
or Codex solve skill", kimi "a Claude, Codex, or Grok", google "a Claude, Codex,
Grok, or Kimi". The list is a function of the brand set, so adding a sixth brand
makes every existing copy's sentence wrong, and nothing checks it.

**The renderer is already brand-agnostic where it matters.**
`tools/render_command_sources.py` (699 lines, with an 800-line test module)
matches `BRAND_OPEN_RE = brand:[a-z][a-z0-9-]*` and `select_brand(body, brand,
…)` takes any brand string, so the brand-block mechanism needs no redesign.

**Four things are hard-coded to two brands**, all in the same module:

- `SIGILS = {"claude": "/", "codex": "$"}` (`:87`);
- `BRAND_FRONTMATTER_KEYS` (`:98`), whose per-brand tuples differ — grok ships
  `argument-hint`, kimi and google do not;
- `CommandSource`'s two output fields `claude_commands_dir` and
  `codex_skills_dir`; and
- `output_paths` (`:353`).

`COMMAND_SOURCES` has no external entry, so `--check` cannot see any of the six.

**The gate coverage that exists.**
`tools/test_agent_workflow_contract.py:1776`'s `ART_POLICY_SOLVE_ASSETS` asserts
one shared rule family across all five solve assets, with a negative control at
`:1805`. That is the only cross-bundle policy gate reaching the externals —
`NAMING_ASSETS` and `DELEGATING_ASSETS` at `:5203` cover Claude and Codex only.
Outside that module the external solve asset is referenced only by
`tools/test_kimi_plugin.py` and `tools/test_packaged_issue_review_probe.py`. One
rule family is gated; the remaining ~1,600 lines can drift silently.

**The cost is already paid, twice.** Both defects this review found had
propagated into all three copies and survived every gate: the Copilot
helper-discovery assumption (issue #698) and the autosolve approval handoff
wording (issue #699).

**Prior arcs, and an adjacent one nobody has started.** Closed #375 built the
two-brand renderer. Epic #373 was the Claude/Codex vendoring arc, whose own
contract named the same failure mode — "one reconciled source per command rather
than two drifting personal copies". All ten of its slices are delivered and it
remains open. It does not cover the external bundles, which were already tracked
assets and so never entered it.

#373's own Out of scope draws the relevant boundary explicitly:

> Migrating the fourteen existing two-brand command pairs to the shared source.
> Their copies are not mechanically convertible — `process-report`'s two differ
> by 169 body lines — so that is its own arc.

So there are three populations, not two: the commands #373 already sourced, the
fourteen unsourced Claude/Codex pairs it deferred to a future arc, and the six
external assets this arc addresses. D-5 keeps this arc to the third, following
the precedent #373 set: a migration of existing copies is its own arc rather
than an extension of the one that built the mechanism.

**The gap between families is far wider than the gap inside one.** Measured with
`diff` on 2026-09-17: Claude's `autosolve` and Kimi's differ in 280 lines of
roughly 300, and Claude's `solve` and Kimi's in 79 of 145/202. Within the
external trio the figures are 22 and 50 (kimi↔google) and 62 and 112
(kimi↔grok). Claude's and Codex's own `solve` differ in just 15 lines of about
145 — a cheap reconciliation, but one belonging to the fourteen-pair arc rather
than this one.

## Desired experience

A maintainer changing shared workflow policy edits one authored source. Running
`python3 tools/render_command_sources.py` rewrites every bundle output that owes
the change, and `--check` fails in CI if any tracked output does not match what
the source renders. A brand-specific difference — helper discovery, argument
binding, the origin marker, the sibling enumeration — is visible in the source as
an explicit per-brand region rather than as an invisible divergence between
files nobody compares.

Nothing about what a Grok, Kimi, or Google session does changes. The rendered
bytes are the bytes those bundles ship today.

## Scope

### In scope

- Generalizing `tools/render_command_sources.py` and its test module beyond two
  brands.
- Authoring one source for the external `solve` workflow and one for the
  external `autosolve` workflow, and rendering the six existing assets from
  them.
- Registering the new sources in `COMMAND_SOURCES` so `--check` covers them.
- Any bundle version and manifest-consistency bump these edits turn out to owe,
  which D-4 expects to be none.

### Out of scope

- Any change to what the six assets instruct a session to do. The migration is
  behavior-preserving and its outputs are byte-identical.
- Merging the Claude and Codex `solve`/`autosolve` sources into the external
  ones. D-5 keeps them out.
- The corrections already filed as #698 and #699. This arc lands behind them and
  authors their corrected text rather than re-authoring the defects.
- A second templating system. The existing renderer is extended.
- The external bundles' Python assets (`review_pr.py`, `kanban_models.py`,
  `trusted_issue_spec.py`), which have their own parity and byte-identity gates.

## Design

**One mechanism, more brands.** The renderer's structure survives. `SIGILS`,
`BRAND_FRONTMATTER_KEYS`, and `output_paths` become keyed by an arbitrary brand
set, and `CommandSource`'s two output fields become a per-brand mapping so an
entry can render into any subset of bundles. That subsetting is what lets an
external source render into three bundles while `triage` continues to render
into two, without either knowing about the other.

Two brands sharing a sigil is already safe: `IDENTIFIER_PATTERNS` and
`LITERAL_INVOCATION_PATTERNS` are keyed by sigil rather than brand, and grok,
kimi, and google all invoke with `/` as Claude does.

**The shape of a brand region.** Three kinds of per-brand difference appear in
these assets, and they want different treatment:

1. *Token substitution* — the brand name, plugin-root variable, marketplace
   name, and origin marker. A per-brand value the source references by name.
2. *A block* — helper discovery and argument binding, where Grok and the Copilot
   pair say structurally different things. An explicit `<!-- brand:… -->` block,
   which the renderer already supports.
3. *A derived enumeration* — the sibling-brand list, which is a function of the
   brand set rather than an authored constant.

D-2 settles that these live in one source per workflow; D-5 settles that the
source spans the three external brands. The risk to weigh while writing it is that a source
dense with brand blocks becomes harder to maintain than the copies it replaces,
which would defeat the arc.

**Verification is byte-identity, not judgement.** Because the migration is
behavior-preserving, every slice has an exact oracle: render, and compare to the
bytes already tracked. A slice that cannot produce them has found a real
difference the source does not yet express.

## Decisions

### D-0. Brand means the model, not the CLI

A bundle's brand is the model the session runs, not the executable hosting it.
The Copilot CLI hosts several model brands, so a Copilot session running a
Claude model is a Claude participant and stamps `pr-origin:claude` — it must not
load the Kimi or Google bundle. Every issue and pull request carries exactly one
origin brand, drawn from `claude`, `codex`, `kimi`, `google`, `grok`.

Confirmed by the owner on 2026-09-17. This is not new: `kimi-plugin/README.md:32`
and `google-plugin/README.md:33` already state it — "a Copilot session using a
Claude model is a canonical Claude participant and must not load the Kimi
bundle".

*Consequence for this arc:* the renderer's brand axis is the model brand, which
is already how `SIGILS`, the origin markers, and `PullRequestOrigin` are keyed.
No remapping is needed.

*Noted, not owned here:* nothing enforces the rule at runtime. It holds because
the operator chooses which bundle to load, and a Copilot session running Claude
that loads the Kimi bundle would stamp a false origin. That is a gap in the
current bundles rather than in this migration, and belongs in its own finding.

### D-2. One authored source per workflow, covering every brand it renders

Not one source for Grok and another for the Copilot pair. Approved by the owner
on 2026-09-17. D-5 settles which brands that source covers.

*Rationale:* the shared policy has exactly one home, which is the failure this
arc exists to close; splitting it in two would reproduce the drift at a third of
today's scale. The measured divergence supports it — Grok's difference is two
contiguous regions (helper discovery, argument binding), not scattered lines, so
it expresses as brand blocks rather than as a source riddled with them.

### D-3. The sibling-brand enumeration is an implementation detail

Whether the renderer derives it from the brand set or the source authors it per
brand is decided during implementation, by readability. It changes no behavior
and no output byte, so it is not a design decision. Withdrawn as Q-3 and
approved by the owner on 2026-09-17.

### D-4. A migration that changes no bundle bytes owes no version bump

Confirmed by the owner on 2026-09-17. `tools/plugin_bundle_gate.py`'s
`version_gate_failures` fires on tracked content changing within a bundle
prefix; authored sources and the renderer live outside every such prefix, so a
byte-identical migration triggers nothing and none is owed.

### D-5. Each authored source covers the three external brands, not five

The `solve` and `autosolve` sources this arc creates render grok, kimi, and
google. The Claude and Codex assets are untouched, and
`tools/command_sources/autosolve.md` keeps authoring the canonical autosolve
pair as it does today. Approved by the owner on 2026-09-17, resolving Q-1.

*Rationale — the two populations are different families, and the measurements
say so.* Within the external trio, kimi and google differ by 11-14% and grok's
larger difference is two contiguous blocks. Between the families the gap is far
wider: Claude's `autosolve` and Kimi's differ in 280 lines of roughly 300. They
share a name and little else — the canonical one drives an opposite-brand loop
with a documentation-landing path, the external one a Codex-only loop that
refuses doc-landing because its bundle ships no such helper. A five-brand
autosolve source would be mostly brand blocks, which is the outcome D-2's
rationale identifies as defeating the arc. For scale, #373 called a 223-line
divergence "the heaviest reconciliation in the arc" and gave it a slice of its
own; this is larger.

*Rejected alternative, and why it was not the risk it looked like.* An earlier
proposal added a fourth slice bringing Claude and Codex `solve` into the same
source, isolated because it lacked a byte-identity oracle. Measurement reversed
that: those two files differ in 15 lines of about 145, so the reconciliation is
trivial. #373's "not mechanically convertible" warning cited `process-report` at
169 lines, a different pair in that population of fourteen. It is excluded not
for risk but for belonging: taking one pair out of fourteen because it shares a
name with an external workflow would start that arc out of order, inside this
one, and finish nothing.

*Consequence:* the delivery plan stays at three slices. `Claude solve` ↔ `Codex
solve` at 15 differing lines is recorded here as a pointer for whoever starts
the fourteen-pair arc — it is a cheap first slice for that arc, not this one.

### D-1. Deliver as an epic of three dependency-ordered slices

EXT-1 generalizes the renderer and changes no bundle output; EXT-2 and EXT-3
migrate `solve` and `autosolve` respectively and are independent of each other.
Approved by the owner on 2026-09-17 while dispositioning finding PRR-4.

*Rationale:* EXT-1 is reviewable entirely against the existing fixture with no
bundle bytes moving, which is a much cheaper review than one PR that also
rewrites six shipped assets. EXT-2 and EXT-3 then each have an exact
byte-identity oracle over one workflow.

*Consequence:* EXT-1 can start now. EXT-2 and EXT-3 wait for #698 and #699
respectively, so the authored source captures corrected text rather than
re-authoring a known defect.

## Open questions

### Q-1. Resolved by D-5

### Q-3. Resolved by D-3 — implementation detail, not a design choice

Withdrawn. Whether the sibling-brand enumeration is derived by the renderer or
authored per brand is the implementer's call inside EXT-1 and EXT-2, decided by
whichever reads better in the source. It changes no behavior and no output byte.

### Q-4. Resolved by D-4

## Verification strategy

- **Byte-identity, pre and post.** Each migration slice compares its rendered
  output against the bytes tracked before the change. This is the arc's primary
  oracle and admits no judgement.
- **`--check` coverage.** After each migration slice, a hand-edit to any of the
  migrated outputs makes `python3 tools/render_command_sources.py --check` fail.
- **Determinism and idempotence.** Rendering twice produces identical bytes, and
  rendering an already-rendered tree changes nothing.
- **Reach, with a negative control.** A planted shared-policy edit in the source
  reaches exactly the intended external outputs and no others — in particular it
  must not reach the Claude or Codex assets, which D-5 keeps out of scope.
  The negative control is what stops a reach test passing vacuously, following
  `tools/test_drafting_workflow_contract.py`'s `WriteLocationTests` pattern that
  `CLAUDE.md` names.
- **Existing gates keep passing.** `tools/test_coordinator_parity.py`, the
  `trusted_issue_spec.py` byte-identity checks, `ART_POLICY_SOLVE_ASSETS` and its
  control, and each external bundle's own test module.
- **Manifest consistency.** Where a bundle's tracked content does change, its
  `plugin.json` and `marketplace.json` versions increase and agree.
- **No classification edit is owed.** The new authored sources are tracked
  Markdown, which this repository classifies, but `docs/agent-workflow-contract.md`
  §7 already carries a directory row `tools/ | pr-atomic |
  test-parsed;release-document` that covers `tools/command_sources/`. The
  sources are test-parsed by `tools/test_render_command_sources.py`, so
  `pr-atomic` is the correct lane and no §7 edit is required.

## Delivery plan

### EXT-1. Generalize the command renderer beyond two brands

- **Outcome:** `tools/render_command_sources.py` renders an authored source into
  an arbitrary set of brands, proven end to end by VEND-0's fixture for a third
  brand, with every existing bundle output byte-identical and `--check` still
  passing.
- **Scope:** `SIGILS`, `BRAND_FRONTMATTER_KEYS`, `CommandSource`'s output
  mapping, and `output_paths` take an arbitrary brand set; the fixture under
  `tools/command_render_fixture/` gains a third brand; `tools/test_render_command_sources.py`
  covers the generalized forms.
- **Phase:** 1
- **Depends on:** `none`
- **Ordering:** `critical path`, `can land first`
- **Relevant decisions:** D-0, D-1, D-3
- **Acceptance signals:** `python3 tools/render_command_sources.py --check`
  passes; no file under any `*-plugin/` prefix changes; the fixture renders a
  third brand with its own sigil and frontmatter allowlist; a brand absent from
  an entry's mapping receives no output.
- **Out of scope:** registering any external source, and every bundle asset.
- **Open questions:** `None`

### EXT-2. Render the external solve workflows from an authored source

- **Outcome:** `grok`, `kimi`, and `google` `solve/SKILL.md` are rendered
  outputs whose bytes are identical to the pre-migration bytes, and `--check`
  fails on a hand-edit to any of them.
- **Scope:** the three-brand authored source, its `COMMAND_SOURCES` registration,
  and the reach test with its negative control. No bundle version bump is owed
  (D-4).
- **Phase:** 2
- **Depends on:** `EXT-1`; issue #698 landed
- **Ordering:** `independent` of EXT-3
- **Relevant decisions:** D-1, D-2, D-3, D-4, D-5
- **Acceptance signals:** rendered bytes equal the bytes tracked at the
  pre-migration commit; `--check` passes and fails on a planted hand-edit; a
  planted shared-policy edit reaches all three solve outputs and no Claude or
  Codex asset; existing external bundle tests pass.
- **Out of scope:** the autosolve assets; any behavior change to solve.
- **Open questions:** `None`

### EXT-3. Render the external autosolve workflows from an authored source

- **Outcome:** `grok`, `kimi`, and `google` `autosolve/SKILL.md` are rendered
  outputs whose bytes are identical to the pre-migration bytes, and `--check`
  fails on a hand-edit to any of them.
- **Scope:** as EXT-2, for autosolve.
- **Phase:** 2
- **Depends on:** `EXT-1`; issue #699 landed
- **Ordering:** `independent` of EXT-2, `not on the critical path`
- **Relevant decisions:** D-1, D-2, D-3, D-4, D-5
- **Acceptance signals:** as EXT-2, for the three autosolve outputs.
- **Out of scope:** the solve assets; any behavior change to autosolve.
- **Open questions:** `None`

## Source notes

From finding PRR-4 of `docs/project_review_660-648.md`, on why the copies are
the problem rather than the symptom:

> Each external bundle can silently diverge in shared workflow policy even while
> helper/coordinator equality checks pass.

From closed #373's epic contract, naming the same failure mode one generation
earlier:

> one reconciled source per command rather than two drifting personal copies
