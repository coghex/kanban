# Model settings design

Every model identifier and reasoning-effort level the agent pipeline uses is a
bare literal today, duplicated across nine invocation sites in three languages,
with display strings and prompt prose that have already drifted from the wire
values. This arc replaces those literals with one data-driven roster: shipped
defaults, a user settings file, and a settings screen that edits which model
performs which pipeline step at which effort. The provider set the roster
loads also selects the operating mode: two providers preserve today's
cross-brand pipeline, one provider routes review to itself behind mode-aware
gates, and zero providers leave a board-only Kanban with the agent chrome
hidden. A third provider stays future headroom the schema must not preclude.

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Drive agent model and effort selection from a settings roster — [#412]
- [ ] MODEL-1. Define the model roster schema, loader, writer, and compiled defaults
- [ ] MODEL-2. Resolve the Haskell spawn sites from the roster
- [ ] MODEL-7. Record spawn-time assignments in worker specs and replay them on resume
- [ ] MODEL-3. Derive display labels and prompt prose from the roster
- [ ] MODEL-4. Resolve the Python and plugin spawn sites from the roster
- [ ] MODEL-5. Extend the settings screen to edit role assignments
- [ ] MODEL-8. Derive the operating mode from the loaded provider set
- [ ] MODEL-9. Implement no-agent mode: board-only UI and spawn refusal
- [ ] MODEL-12. Extract the provider adapter interface behind the agent flows
- [ ] MODEL-13. Implement the Claude embedded-review backend
- [ ] MODEL-10. Implement single-agent review routing in the Haskell flows
- [ ] MODEL-11. Make the Python gates and plugin reviews single-agent aware
- [ ] MODEL-6. Package the defaults and document the roster surface

## Epic contract

- **Goal:** Every model and effort an agent session receives is resolved from
  one roster with shipped defaults; no spawn site in `src/`, `tools/`, or the
  plugin bundles carries a bare model literal; the user can change any
  role assignment from the settings screen and the next session of that kind
  uses it; and the loaded provider set selects the operating mode — dual,
  single-agent, or board-only — with no separate mode setting.
- **Done when:** the roster file format is defined and versioned; all Haskell,
  Python, and plugin invocation sites read it; display labels and prompt prose
  derive from it (ending the wire/display divergence); the settings screen
  edits and persists it; the defaults ship in the release artifact; the three
  operating modes behave as specified (dual unchanged, single-agent reviewing
  self-brand behind mode-aware gates, no-agent presenting a board-only UI);
  no component speaks only one provider's protocol — the embedded issue
  review runs on either loaded provider through a per-provider adapter
  interface; and `docs/design.md` plus `docs/agent-workflow-contract.md`
  describe roles, defaults, and modes instead of naming models inline.
- **Users and operators:** the board operator changing models as providers
  release new ones; the pipeline's review agents, whose parity gates stop
  pinning source text; operators running Claude-only or Codex-only installs;
  users running Kanban as a plain board.
- **Arc label:** None proposed

## Current state and evidence

### The real model matrix (verified 2026-08-20)

The owner's recollection ("Opus 5 solves, GPT-5.6-Sol reviews, both xhigh") is
close to the issue-gate row only. The full matrix:

| Site | Codex | Claude |
| --- | --- | --- |
| Solve (`src/Kanban/Solve.hs:203-234`) | gpt-5.4 · high | claude-sonnet-5 · high |
| PR review, opposite brand (`src/Kanban/PullRequestFlow.hs:257-269`) | gpt-5.6-terra · xhigh | claude-opus-5 · xhigh |
| PR revise/repair, own brand (same) | gpt-5.4 · high | claude-sonnet-5 · **xhigh** |
| Embedded issue review thread (`src/Kanban/Review.hs:385,491`) | gpt-5.4 · high | — (client is Codex-only) |
| Nested revision tool `kanban_run_claude` (`src/Kanban/Review/Tools.hs:339-346`) | — | claude-sonnet-5 · high |
| Canonical issue gate (`tools/approve_issues.py:46-57`) | gpt-5.6-sol · xhigh | claude-opus-5 · xhigh |
| Drainer stale-head rereview (`tools/drain_prs.py:85-86`) | gpt-5.6-terra · **medium** | — |
| Claude-plugin nested PR review (`claude-plugin/.../scripts/review_pr.py:54-57`) | gpt-5.6-terra · xhigh | claude-opus-5 · xhigh |
| Ping (`src/Kanban/Ping.hs:154-171`) | *(CLI default model)* · minimal | *(CLI default model)* · low |

Asymmetries worth knowing: Claude PR revision runs xhigh while Codex revision
runs high (`claudeEffort` is unconditional at `PullRequestFlow.hs:269`); the
embedded issue-review thread (gpt-5.4) and the canonical gate (gpt-5.6-sol)
use different Codex models for what reads as the same job; the drainer's
rereview is the pipeline's only `medium`. Ping deliberately passes no model at
all (`Ping.hs:139-153` records why).

### Drift that has already happened

- Display constants diverged in *form* from wire values the day they were
  written: `src/Kanban/Solve/Event.hs:110-124` renders "gpt-5.4 high",
  "Sonnet 5 high", "GPT-5.6-Terra xhigh", "Opus 5 xhigh" independently of the
  argv literals.
- Prompt prose names models: `src/Kanban/Review/Prompts.hs:85,140-146` and
  transcript literals at `src/Kanban/UI/Review.hs:817,827`.
- `docs/code-health-report.md:547-556` already flags the bare literals as a
  noted-not-filed finding, and `:808-812` calls the plugin-pinned IDs "a
  maintenance clock."

### What locks the current values in

- `test/Spec/Agent/PullRequestFlow.hs:145-155` and
  `test/Spec/Agent/Solve.hs:62-67` assert exact argv.
- `tools/test_claude_plugin.py:756-765` asserts the **source text** of
  `PullRequestFlow.hs`'s selection functions against the plugin copy — a
  Haskell literal change breaks a Python test by design.
- `docs/design.md` §7 (`:708-756`), §19 (`:3283-3285`) name the models in
  prose; `docs/agent-workflow-contract.md` §2.2 (`:183-213`) states the policy
  that model selection stays with Kanban's invoking code, and `:215-225`
  documents the Claude-plugin pin as a deliberate exception.
- Stale-approval reconciliation compares recorded `models` in the approval
  marker (`docs/agent-workflow-contract.md` §2.3.1 `:373-378`), so a roster
  change invalidates standing approvals and forces rereview. That is correct
  behavior — a review by a retired model is not the canonical review — but it
  is a consequence to state, not discover.

### Infrastructure already in place

- `src/Kanban/Settings.hs` (133 lines): JSON at
  `~/.config/kanban/settings.json`, schema-versioned (v1), one setting (chat
  verbosity), atomic 0600 save via temp-file rename. A clean template.
- `src/Kanban/Config.hs`: TOML at `~/.config/kanban/config.toml` via
  `toml-parser >= 2.0` — **read-only**; nothing in the repository writes TOML
  today. `toml-parser-2.0.2.0` exposes `Toml.Schema.ToValue` and
  `Toml.Pretty`, so writing needs no new dependency. Python mirrors reads with
  `tomllib` (`tools/kanban_config.py:37`).
- A `SettingsOverlay` **already exists** (`o` key, `src/Kanban/UI/Overlay.hs:156-176`,
  `src/Kanban/UI/Events.hs:136-140,577-591`) — a static three-choice radio
  list for chat verbosity. No cursor, scroll, mouse, or text entry. The filter
  panel (`src/Kanban/UI/Filter.hs`) is the established richer pattern: pure
  input decoder + applier, focus movement, clickable `Name` targets, tests in
  `test/Spec/UI/FilterPanel.hs`.
- The only existing override surface is environment variables in
  `tools/approve_issues.py:54-57` (`APPROVE_ISSUES_CODEX_MODEL` etc.).
- `src/Kanban/Provider.hs` is **not** an agent-provider abstraction — it is
  usage-telemetry vocabulary. The real brand plumbing is four independent
  two-constructor enums: `SolverBrand` (`src/Kanban/Solve/Event.hs:41`,
  serialized into persisted worker specs), `PullRequestOrigin`
  (`src/Kanban/PullRequestFlow.hs:45`), `PingBrand` (`src/Kanban/Ping.hs:107`),
  and `UsageProvider` (`src/Kanban/Domain.hs:39`).
- Plugin command frontmatter is **forbidden** from carrying model or effort
  keys, enforced by `tools/test_claude_plugin.py:148-172` and the renderer —
  the bundles already delegate model policy to the backend, which is exactly
  where a roster lives.
- A resumed Codex solve session re-passes `--model` from the literal
  (`src/Kanban/Solve.hs:216-222`), so today a "model change" (i.e., editing
  the source) would retroactively change resumed sessions too.

## Desired experience

- The operator presses `o`, sees the current role → model/effort matrix with
  the shipped default marked, changes "PR review (claude)" from Opus 5 xhigh
  to something newer, and the next Claude-side PR review uses it. No rebuild,
  no source edit, no test churn.
- A provider ships a new model: the operator adds its ID to that provider's
  model list (file edit or settings screen), assigns it to roles, done.
- Every surface that *names* a model — solve chooser, session headers, worker
  rows, review transcripts, reviewer prompts — shows the value the roster
  resolved, so what the UI says is what the argv carries.
- The Python gate, the drainer, and the plugin's nested reviewers read the
  same roster, so "which model reviews issues" has one answer, not three.
- Defaults ship with the release; a fresh install behaves exactly like today
  with no roster file present.
- Removing a provider from the roster's loaded set is how the system changes
  shape: with one provider, review routes to that provider's own models; with
  none, Kanban is a clean board with no agent shortcuts, no usage sidebar,
  and no solver behaviors. No mode toggle exists to disagree with the
  provider set.

## Scope

### In scope

- A versioned TOML roster: provider declarations (executable identity, model
  list, effort vocabulary) and role assignments (provider-scoped model +
  effort + display label) for every site in the matrix above except ping.
- Compiled-in defaults equal to today's wire values, byte-for-byte at the
  argv level when no user file exists.
- Operating modes derived from the loaded provider set: dual (today's
  pipeline, unchanged), single-agent (self-brand review behind mode-aware
  checks and gates), and no-agent (board-only UI with agent shortcuts
  hidden and solve/review unavailable).
- A compiled per-provider adapter interface as the single place Kanban
  constructs agent-session provider processes, with the embedded issue
  review made provider-generic — including a Claude backend — so no
  component speaks only one provider's protocol (D-13).
- Haskell loader/writer, Python reader, and consumption at all nine sites.
- Display-label and prompt-prose derivation from the roster.
- Settings-screen editing with persistence and reset-to-default.
- Release packaging of the defaults and the documentation sweep.

### Out of scope

- A third provider. The adapters stay compiled per provider (see Data
  model); adding a brand is future work the schema must not preclude.
- The external plugin system — providers shipping manifests that declare
  their interfaces and protocols for load-time discovery. That is its own
  future arc; it binds to the adapter interface this arc builds (D-13)
  rather than redoing it, and the roster's open-keyed provider tables stay
  forward-compatible with it.
- Ping model/effort configuration — its modelless, minimal-effort shape is a
  documented deliberate choice (`Ping.hs:139-153`).
- Usage-quota estimation tuning (`estimated_percent_per_solve_round`) —
  adjacent, already configurable in `config.toml`.
- Per-repository roster overrides (D-9): the roster is per-system; a future
  epic would own per-repository policy if it is ever wanted.
- Mid-session model switching for live workers. The roster governs new spawns;
  a running or resumed session replays its spawn-time assignment (D-7).

## Design

### Data model

Two layers, deliberately provider-generic:

- **Providers** declare what exists: a stable key (`codex`, `claude`), the
  executable it maps to, the model IDs the operator considers available, and
  the effort vocabulary the CLI accepts (Codex: minimal/low/medium/high/xhigh;
  Claude: low/medium/high/xhigh). How a provider turns (model, effort) into
  argv — Codex's `-m X -c model_reasoning_effort="Y"` versus Claude's
  `--model X --effort Y`, and the Codex app-server's JSON `model`/`effort`
  fields — stays a compiled adapter per provider, not data. Argv shape as
  data is the third-provider problem and is out of scope.
- **Roles** name the pipeline steps and assign each (role, provider) pair a
  model, an effort, and a display label. Proposed role keys, mapped from the
  matrix: `solve`, `pr_review`, `pr_revise` (covers repair — same arm today),
  `issue_review` (embedded thread), `issue_revise` (the nested
  `kanban_run_claude` tool), `issue_gate` (the canonical
  `approve_issues.py` reviewers), `drain_rereview`. The plugin's nested PR
  reviewers resolve through `pr_review`. `issue_review` and `issue_gate` stay
  distinct roles (D-5) — today they genuinely differ (gpt-5.4 vs gpt-5.6-sol),
  and preserving the true matrix means no behavior changes on day one; an
  operator who wants them unified assigns them the same values. Each role
  also carries a compiled *applicability* — which providers it can run on at
  all (D-14): `issue_revise` is Claude-only by construction (it names the
  authenticated-Claude revision tool; a Codex-only install revises inside the
  review thread itself), `drain_rereview` applies to both brands, and every
  other role applies to both. Applicability is code structure, not
  configuration, so it lives beside the compiled role registry rather than in
  the file.

### File sketch

```toml
schema_version = 1

# The loaded provider set — and therefore the operating mode (D-8, D-10).
# Two entries: dual. One: single-agent. Empty: no-agent, board only.
agents = ["codex", "claude"]

[providers.codex]
models = ["gpt-5.4", "gpt-5.5", "gpt-5.6-terra", "gpt-5.6-sol"]
efforts = ["minimal", "low", "medium", "high", "xhigh"]

[providers.claude]
models = ["claude-sonnet-5", "claude-opus-5", "claude-fable-5"]
efforts = ["low", "medium", "high", "xhigh"]

[roles.pr_review.codex]
model = "gpt-5.6-terra"
effort = "xhigh"
display = "GPT-5.6-Terra xhigh"

[roles.pr_review.claude]
model = "claude-opus-5"
effort = "xhigh"
display = "Opus 5 xhigh"
# ... one table per (role, provider) pair
```

Validation: an assignment's model must appear in its provider's `models`, its
effort in that provider's `efforts`, every entry in `agents` must name a
declared provider, and every role the binary knows must resolve for every
loaded provider that role applies to (D-14) — a role inapplicable to a
provider needs no assignment for it, and validation never demands one.
Unknown role keys and unknown provider keys in the file are errors, not
ignored — silently skipping a misspelled `[roles.pr_reveiw.codex]` is how an
operator ships the old model believing they changed it. Editing a
`[providers.X]` table never changes the loaded set; only the `agents` list
does (D-10), so a model-list tweak can never switch operating modes as a
side effect.

### Compiled defaults

The complete role × provider grid, so totality is checkable at a glance:
thirteen applicable cells, every one valued. The two cells marked *new* are
additions this arc makes for the single-provider modes (D-14); neither is
consulted by any dual-mode spawn until its slice lands, so the
defaults-reproduce-today guarantee holds.

| role | codex | claude |
| --- | --- | --- |
| `solve` | gpt-5.4 · high | claude-sonnet-5 · high |
| `pr_review` | gpt-5.6-terra · xhigh | claude-opus-5 · xhigh |
| `pr_revise` | gpt-5.4 · high | claude-sonnet-5 · xhigh |
| `issue_review` | gpt-5.4 · high | claude-opus-5 · xhigh *(new — activates with MODEL-13)* |
| `issue_revise` | *inapplicable (D-14)* | claude-sonnet-5 · high |
| `issue_gate` | gpt-5.6-sol · xhigh | claude-opus-5 · xhigh |
| `drain_rereview` | gpt-5.6-terra · medium | claude-opus-5 · medium *(new — activates with MODEL-11's claude-only resolution)* |

### Resolution order

1. Compiled defaults (a `defaultRoster` value in the new module) — always
   complete, always equal to the tracked example file.
2. The user roster file — overrides per (role, provider) assignment and may
   extend provider model lists.
3. The existing `APPROVE_ISSUES_*` environment variables stay the
   highest-precedence override, for the `issue_gate` role only (D-6):
   compiled defaults < roster file < environment.

Failure semantics (D-3): file absent → defaults, silently, the
fresh-install path. File present but unparseable, schema-version foreign, or
invalid → the board loads and read-only features work, but every agent spawn
that would consult the roster refuses with a visible error naming the file and
the defect. No silent fallback to defaults: an operator who edited the file to
change a model must never have an agent quietly run on the old one. This is
the absent-versus-unusable split the pipeline's review culture already
enforces elsewhere, decided up front instead of one blocker per round.

### Consumption

- **Haskell:** a new `Kanban.Models` module (name open) owns the types,
  defaults, TOML decode/encode, and validation. The resolved roster loads once
  at startup beside `ResolvedConfig` and threads to: `solveArguments`
  (`Solve.hs`), the four selection functions (`PullRequestFlow.hs` — they
  become lookups, preserving `agentForAction`'s brand routing untouched),
  `beginIssueReview`'s `thread/start` and `sendTurnStart`'s `turn/start`
  (`Review.hs`), and the `kanban_run_claude` argv (`Review/Tools.hs`).
- **Python:** a `kanban_models.py` reader (tomllib, mirroring
  `kanban_config.py`'s shape) consumed by `approve_issues.py`,
  `drain_prs.py`, and the Claude plugin's `review_pr.py`; the Codex plugin's
  copy keeps its no-pinning delegation contract and never gains the reader's
  model values (D-2 as amended), though it reads the loaded-provider set for
  MODEL-11's mode awareness. The reader ships exactly the way
  `kanban_config.py` already does — byte-identical copies in `tools/` and in
  both plugin bundles' `scripts/` directories, held identical by the same
  parity discipline — because an installed coordinator runs from its bundle
  with no `tools/` sibling and must load the reader from beside itself. The
  drainer re-reads per drain cycle so a roster edit does not require a
  service restart; a new module under `tools/` means `install_drainer.py`
  (and the issue-approval installer, which relocates its own module set)
  must be rerun on live installs, which the slice must say out loud.
- **Display and prose:** the four constants in `Solve/Event.hs:110-124` become
  functions of the roster (`display` labels), as do the solve chooser rows,
  session/worker labels, `Prompts.hs` reviewer-identity prose, and the
  `UI/Review.hs` transcript prefixes. This ends the class of drift, not just
  the current instances.

### Provider adapter interface (D-13)

A compiled per-provider adapter — one record per brand — becomes the only
place Kanban constructs *agent-session* provider processes: solve and
PR-flow argv assembly, the embedded review session, one-shot runs like the
nested revision tool, and the review tool registry all resolve through it.
Two launchers deliberately stay outside it, because they are not agent
sessions and consume no roster value: `Ping.hs` (modelless by design, D-2)
and the usage probes in `Codex.hs`/`Claude.hs`, which spawn provider CLIs
only to read account status. The existing Codex
app-server client (`Review.hs` and its seams) becomes the Codex
implementation; a new Claude embedded-review backend (mechanism Q-12,
deliberately open) becomes the Claude one, closing the last single-protocol
component. The nested revision tool is Claude-only (D-14) and registers only
when Claude is loaded: a Codex-only install carries no revision tool at all,
and its review thread performs revisions itself rather than delegating to a
nested spawn. This interface is deliberately the seed of the future
plugin arc: an external provider manifest system would populate exactly this
record at load time instead of compiling it in, which is why that arc can be
separate without rework here.

### Settings screen

Extend the existing `SettingsOverlay` rather than adding a second entry point:
the chat-verbosity radio stays, and a roster section lists role × provider
rows showing `model · effort`, with the default-marked value dimmed when
overridden. Editing follows the filter-panel pattern (pure input decoder +
applier, focus movement, clickable targets, golden frames): a focused row
cycles through the provider's declared model list and effort vocabulary rather
than free-text entry — the model list is data, so a pick list stays correct
without a text editor. Free-text entry for *adding* a model ID to a provider
list can ride the search-overlay input pattern or stay file-only for this arc
(kept small deliberately; the slice records which). Saving writes the roster
file atomically (same temp-file + 0600 + rename discipline as
`Settings.hs:108-126`) and updates the in-memory roster so subsequent spawns
use it. New key bindings land in `UI/Keys.hs` and therefore in
`docs/design.md` §7's tested key table in the same PR.

### Session stability (D-7)

At spawn, the resolved assignment — provider, model, effort, display label —
is recorded into the persisted worker spec, and resume replays the recorded
values rather than consulting the live roster. A session keeps one model for
its whole life; the roster governs the *next* spawn. The replay is
unconditional: a recorded model later removed from the roster still replays
(the spec is authoritative for that session's life; if the provider retired
the model, the CLI fails visibly at resume, which is the honest outcome). A
legacy spec with no recorded assignment — the field is additive — resolves
from the live roster on its first resume and records the result then. This is
a persisted-format change to `~/.cache/kanban/workers/**.spec.json` and lands
as its own slice (MODEL-7) so MODEL-2's blast radius stays bounded.

### Consequences the design accepts

- Changing a reviewer role's assignment invalidates stale-approval markers
  (contract §2.3.1) — standing approvals recorded under the old model will
  reconcile to rereview. Correct, and the settings screen should say so on
  reviewer-role edits.
- The `tools/test_claude_plugin.py` source-text parity gate stops asserting
  Haskell source and instead asserts the compiled defaults against the plugin
  copy's fallback values — the gate's job (the two lanes cannot silently
  diverge) survives; its mechanism changes.
- `docs/design.md` §7/§19 stop naming models inline and instead describe the
  role vocabulary and point at the defaults table; each slice carries its own
  doc edits per the repository's same-PR consistency rule.

### Operating modes (D-8)

The mode is never a setting. It derives from the provider set the roster
loads — the explicit `agents` list (D-10): two providers → dual, one →
single-agent, zero → no-agent. Compiled defaults load both providers, so a
fresh install is dual and identical to today.

- **Dual** — today's pipeline, unchanged: cross-brand routing via
  `agentForAction`, opposite-brand canonical reviews, dual review for
  unmarked origins.
- **Single-agent** — every role resolves through the loaded provider. Review
  becomes self-brand, and the checks and gates that assume an opposite brand
  become mode-aware rather than silently bypassed. The roster's per-role
  assignments still apply, so review independence degrades gracefully to
  cross-model-within-brand (Sonnet solves, Opus reviews) rather than
  vanishing. Origin markers keep being written (D-12) so a later return to
  dual mode finds valid provenance. The inventory exposed that the embedded
  issue-review client speaks only the Codex app-server protocol
  (`src/Kanban/Review.hs`); D-13 closes that gap inside this arc — the
  embedded review runs through the loaded provider's adapter backend
  (MODEL-12, MODEL-13), so a Claude-only install keeps the action. The solve
  chooser auto-selects the loaded provider; usage and ping surfaces show only
  that provider.
- **No-agent** — the board without the pipeline: solve, review, autosolve,
  and worker actions are unavailable, their shortcuts hidden from every help
  and footer surface but deliberately still handled — pressing one produces
  the mode-naming refusal notice rather than silence — and the usage sidebar
  and ping have nothing to show. Reads, filters,
  search, and details work untouched. Spawn paths refuse with a mode-naming
  message in the D-3 vocabulary. The drainer degrades gracefully (D-11): it
  keeps merging eligible PRs, and any step needing a model raises a
  fail-closed incident naming the mode.

Mode changes take effect like any roster edit — at the next spawn (D-7 keeps
live sessions on their recorded assignments) — and a mode change that alters
who reviews invalidates stale-approval markers exactly as a model change
does.

## Decisions

### D-1. The roster format is TOML, not YAML

The owner initially imagined YAML, then explicitly approved TOML
(2026-08-20): "toml is fine, i just assumed i chose yaml but it doesnt
matter." Consequences: the existing `toml-parser` dependency covers both read
(`Toml.Schema.FromValue`) and write (`Toml.Schema.ToValue` + `Toml.Pretty`),
Python reads it with stdlib `tomllib`, and no YAML parser enters
`kanban.cabal`. The house config surface stays single-format.

### D-2. The roster governs the full matrix

Approved 2026-08-20. All nine sites are in scope: the four Haskell spawn
paths, `approve_issues.py`, the drainer's stale-head rereview, and the Claude
plugin's pinned `review_pr.py` reviewers. Ping stays out by design — and,
amended on canonical review the same day, so does the Codex plugin's
`review_pr.py` copy: it deliberately passes no model or effort flags (brand
selection only, recording `models=unspecified`, the delegation contract
§2.2 documents), so there is nothing for a roster to replace, and giving it
pins would change day-one behavior the compiled defaults are required to
preserve. MODEL-4 asserts that no-pinning contract as a negative control
instead of covering it. Consequences: the arc keeps MODEL-4 (Python and
plugin consumption) and the cross-language parity gate; "which model reviews
issues" resolves to one answer; the Claude plugin's pins become fallbacks
behind the shared reader.

### D-3. A present-but-unusable roster refuses agent spawns

Approved 2026-08-20. Absent file → compiled defaults silently. Present but
unparseable, foreign-versioned, or invalid → the board loads and read-only
features work, but agent spawns that consult the roster refuse with a visible
error naming the file and the defect until it is repaired. Never a silent
fallback to defaults. Consequences: the failure vocabulary is enumerated in
MODEL-1 with one tested arm per cause, and the spawn paths gain a refusal
message surface.

### D-4. Defaults compile in; the user roster is a TUI-owned `models.toml`

Approved 2026-08-20. Compiled defaults live in the binary and must equal the
tracked `models.toml.example`, which ships in the release beside
`config.toml.example`. The user's current roster lives at
`~/.config/kanban/models.toml`, written atomically by the settings screen.
`config.toml` stays human-owned and read-only; `settings.json` stays
UI-preference-only, preserving the line `docs/design.md:2812-2814` draws.
Consequences: no writer for `config.toml` is ever built for this arc, and the
defaults-equal-example invariant gets its own test.

### D-5. Embedded issue review and the canonical gate stay separate roles

Approved 2026-08-20. The roster carries `issue_review` (the embedded client's
thread, gpt-5.4 high today) and `issue_gate` (the `approve_issues.py`
reviewers, gpt-5.6-sol xhigh today) as distinct roles. Consequences: the
defaults reproduce today's matrix exactly, no behavior changes on day one,
and unification stays available by assigning both roles the same values.

### D-6. The `APPROVE_ISSUES_*` environment variables remain the top override

Approved 2026-08-20. For the `issue_gate` role only, precedence is compiled
defaults < roster file < environment variables, covering the model, effort,
and display-name variables alike. Consequences: existing wrapper scripts and
operational muscle memory keep working; MODEL-4 documents the precedence and
tests all three layers.

### D-7. Sessions record their spawn-time assignment and replay it on resume

Approved 2026-08-20. The worker spec gains the resolved assignment at spawn;
resume replays it instead of reading the live roster (full semantics in
Design, "Session stability"). Consequences: an additive persisted-format
change to the worker spec, delivered as its own slice (MODEL-7) between the
Haskell spawn-site migration and the display work.

### D-8. Operating modes ship in this arc and derive from the loaded provider set

Approved 2026-08-20, reversing the earlier headroom-only assumption at the
owner's direction. The mode is never a settings toggle: it is selected by the
number of providers the roster loads. Two is today's dual cross-brand
pipeline. One is single-agent — the loaded provider reviews its own work, and
every check and gate that assumes an opposite brand becomes mode-aware rather
than silently bypassed. Zero is no-agent — a board-only Kanban whose solve
and review behaviors are unavailable and whose related shortcuts are not
displayed. Consequences: four new slices (MODEL-8 through MODEL-11), a
mode-declaration mechanism in the schema (Q-9), and mode-awareness in the
contract's gate descriptions.

### D-9. The roster is per-system

Approved 2026-08-20. Every repository a Kanban instance serves uses the same
model settings; the owner sees no current use case for per-repository
overrides, and if one appears it becomes a new epic. Consequences: no
repository-override table enters the roster schema, and the multi-repo arc
(epic #354) needs nothing from this one.

### D-10. The loaded provider set is an explicit `agents` list

Approved 2026-08-20. A top-level `agents = ["codex", "claude"]` key names the
loaded providers; the compiled default lists both. Removing a provider — and
therefore changing the operating mode — is a deliberate edit of this one key.
Editing a `[providers.X]` table never changes the loaded set, so a model-list
tweak cannot switch modes as a side effect; a listed provider that fails
validation refuses spawns per D-3, never silently downgrading dual to
self-review. Consequences: the key ships in MODEL-1's schema; MODEL-8
derives the mode from it.

### D-11. The drainer degrades gracefully below dual mode

Approved 2026-08-20. In single-agent mode the `drain_rereview` role resolves
through the loaded provider like every other role. In no-agent mode the
drainer keeps merging eligible PRs — a human can still apply approval
labels — and any step that needs a model raises a fail-closed incident
naming the mode. It never refuses to start, and it never skips a model step
silently. Consequences: MODEL-11 implements and tests the incident arm.

### D-12. Origin markers are written in every mode

Approved 2026-08-20. Solve sessions keep writing `issue-origin` and
`pr-origin` markers in single-agent mode; routing resolves every action to
the loaded provider regardless of marker, and provenance survives a later
return to dual mode with routable origins intact. Consequences: no marker
machinery is gated on mode, and the unmarked-origin rules keep their current
meaning in dual mode.

### D-13. No component is single-protocol: a provider adapter interface ships in this arc

Approved 2026-08-20. The owner's rule: any component that speaks only one
provider's protocol gets fixed inside this arc. A compiled per-provider
adapter interface — spawn arguments, the embedded review session, one-shot
runs, and the review tool registry — becomes the only place Kanban
constructs agent-session provider processes (the modelless ping and the
usage probes stay outside it by design); the existing Codex app-server
client becomes
its Codex implementation, and a Claude embedded-review backend is built
beside it (mechanism Q-12, deliberately open). The external plugin system —
providers shipping manifests that declare their interfaces and protocols for
load-time discovery — is deliberately a separate future arc that binds to
this interface; the roster schema stays forward-compatible with it.
Consequences: two new slices (MODEL-12, MODEL-13), and single-agent routing
(MODEL-10) lands after the Claude backend so Claude-only mode never ships
with a refused embedded review.

### D-14. Roles carry compiled applicability, and `drain_rereview` gains a Claude default

Approved 2026-08-20, resolving a canonical-review blocker: the baseline
matrix has no Codex assignment for `issue_revise` and had no Claude
assignment for `drain_rereview`, which the every-role-resolves validation
rule and the single-provider modes jointly could not tolerate. Each role now
declares, in the compiled role registry, which providers it applies to:
`issue_revise` is Claude-only by construction (a Codex-only install revises
inside the review thread), every other role applies to both brands, and
validation requires an assignment only for loaded providers a role applies
to. Two cells were unvalued under that rule, and both gain compiled
defaults (approved 2026-08-20): `drain_rereview.claude` =
**claude-opus-5 · medium**, inert until a Claude-only install runs the
drainer, where MODEL-11's loaded-provider resolution needs it; and
`issue_review.claude` = **claude-opus-5 · xhigh**, the assignment the
Claude embedded-review backend (MODEL-13) resolves — the owner chose to
match the issue gate's weight rather than mirror the Codex side's
lighter embedded thread. With those two cells the applicability ×
assignment grid is total; the Compiled defaults table in Design enumerates
all thirteen. Consequences: MODEL-1 carries applicability and both new
defaults; the defaults-reproduce-today guarantee is unchanged, because no
dual-mode spawn consults either new assignment before its slice lands.

## Open questions

### Q-1. Which invocation sites are in scope for configurability?

Resolved by D-2 (full matrix, ping excluded).

### Q-2. What happens when the roster file is present but unusable?

Resolved by D-3 (absent → defaults; present-but-unusable → refuse spawns
visibly, never a silent fallback).

### Q-3. Where do defaults and current settings live?

Resolved by D-4 (compiled defaults + tracked example in the release + a
TUI-owned `~/.config/kanban/models.toml`).

### Q-4. Do `issue_review` (embedded) and `issue_gate` (canonical) stay separate roles?

Resolved by D-5 (separate roles, faithful to today's matrix).

### Q-5. What happens to the `APPROVE_ISSUES_*` environment variables?

Resolved by D-6 (kept as the highest-precedence override for `issue_gate`).

### Q-6. Does a resumed session use the roster at resume time or its original model?

Resolved by D-7 (spawn-time assignment recorded in the worker spec and
replayed on resume; MODEL-7 delivers it).

### Q-7. Is mode headroom (single-agent, no-agent) schema-only in this arc?

Resolved by D-8 — the owner brought the modes into scope (2026-08-20);
delivery in MODEL-8 through MODEL-11.

### Q-8. Are roster overrides ever per-repository?

Resolved by D-9 (per-system; per-repository policy would be a new epic).

### Q-9. How does the roster declare which providers are loaded?

Resolved by D-10 (an explicit `agents` list; provider-table edits can never
switch modes as a side effect).

### Q-10. What does the drainer do below dual mode?

Resolved by D-11 (graceful degradation: merging continues, model-needing
steps raise fail-closed incidents naming the mode).

### Q-11. Are origin markers still written in single-agent mode?

Resolved by D-12 (markers are written in every mode; routing resolves to the
loaded provider regardless).

### Q-12. What mechanism backs the Claude embedded-review adapter?

Deliberately open; affects MODEL-13 only. Claude has no app-server
equivalent of Codex's JSON-RPC surface, so the backend will drive the
authenticated `claude` CLI in print/stream mode, expose Kanban's review
tools to it over MCP, use the Agent SDK, or combine these. The choice needs
investigation of the CLI's current capabilities at implementation time and
is resolved when MODEL-13 is processed: that slice stops and asks with a
concrete proposal before any implementation.

## Verification strategy

- Pure decode/validate/encode round-trip tests for the roster module, plus
  the absent/unparseable/foreign-version/invalid-reference matrix from Q-2 —
  enumerated up front, one test per arm.
- The existing argv assertions (`Spec/Agent/PullRequestFlow.hs`,
  `Spec/Agent/Solve.hs`) migrate to build expected argv from
  `defaultRoster`, plus one test proving defaults produce byte-identical argv
  to today's literals at the moment of migration.
- Cross-language parity: a gate comparing the compiled Haskell defaults, the
  tracked example file, `tools/kanban_models.py`'s view of it, and the plugin
  copies' fallbacks — replacing the source-text assertion in
  `tools/test_claude_plugin.py:756-765`.
- Golden Brick frames for the extended settings overlay; key-table consistency
  via the existing `Spec.UI.Keys` contract when bindings are added.
- Spawn-level checks with the established fake `codex`/`claude` executables on
  a temporary `PATH`, asserting a user roster file actually changes the argv a
  worker receives.
- Mode coverage: roster fixtures deriving dual, both single-agent variants,
  and no-agent; golden frames per mode; and standing assertions that
  dual-mode argv and frames stay byte-identical to master while the mode
  slices land.
- Adapter integrity: the interface extraction (MODEL-12) lands with zero
  behavior change — no golden or argv expectation moves — and the Claude
  backend (MODEL-13) mirrors the Codex client's fake-executable coverage,
  including its failure vocabulary.
- Documentation consistency: `docs/design.md` §7/§16/§19 and
  `docs/agent-workflow-contract.md` §2.2 updated in the slices that change the
  behavior they describe.

## Delivery plan

### MODEL-1. Define the model roster schema, loader, writer, and compiled defaults

- **Outcome:** a new Haskell module owning provider/role/assignment types,
  `defaultRoster` equal to today's matrix, TOML decode + encode, validation
  with the full failure vocabulary, and atomic save mirroring `Settings.hs`.
  No call site changes; the module is fully tested but unconsumed.
- **Scope:** types, defaults, parse/print, validation, the `agents`
  loaded-provider list (D-10), per-role compiled applicability with the
  `drain_rereview` Claude default (D-14), file path
  (`~/.config/kanban/models.toml` per D-4), load-at-startup plumbing into
  the app's resolved configuration without any consumer reading it yet.
- **Phase:** 1
- **Depends on:** none
- **Ordering:** critical path
- **Relevant decisions:** D-1, D-3, D-4, D-5, D-10, D-14
- **Acceptance signals:** round-trip and validation tests pass; decoding the
  tracked example file yields exactly `defaultRoster`; the D-3 failure matrix
  has one asserted arm per cause.
- **Out of scope:** consuming the roster anywhere; the settings screen; Python.
- **Open questions:** None

### MODEL-2. Resolve the Haskell spawn sites from the roster

- **Outcome:** `Solve.hs`, `PullRequestFlow.hs`, `Review.hs`, and
  `Review/Tools.hs` take their model/effort from the resolved roster; the
  selection functions become lookups; argv under defaults is byte-identical
  to before.
- **Scope:** the four Haskell sites, threading the roster through their entry
  points, migrating `Spec/Agent/PullRequestFlow.hs` and `Spec/Agent/Solve.hs`
  to roster-driven expectations, and repointing the
  `tools/test_claude_plugin.py` source-text gate at the defaults data (the
  gate must not go red between landings, so it moves in this PR).
- **Phase:** 2
- **Depends on:** MODEL-1
- **Ordering:** critical path
- **Relevant decisions:** D-1, D-3
- **Acceptance signals:** a temporary user roster file in a test changes the
  argv the fake `codex`/`claude` executables record; with no file, argv is
  unchanged from master; the parity gate compares data, not source text.
- **Out of scope:** display labels and prose (MODEL-3); Python sites
  (MODEL-4); recording assignments into worker specs (MODEL-7) — until it
  lands, resume keeps today's shape and reads the roster live.
- **Open questions:** None

### MODEL-7. Record spawn-time assignments in worker specs and replay them on resume

- **Outcome:** the persisted worker spec carries the resolved assignment
  (provider, model, effort, display label) from spawn, and resume replays it
  unconditionally; a session keeps one model for its whole life per D-7.
- **Scope:** the additive spec field and its `FromJSON`/`ToJSON`, the resume
  paths in `Solve.hs` reading the recorded values instead of the live roster,
  the legacy-spec arm (no recorded assignment → resolve live once, record),
  and tests covering fresh spec, replay-after-roster-edit, and legacy spec.
- **Phase:** 2
- **Depends on:** MODEL-1, MODEL-2
- **Ordering:** critical path
- **Relevant decisions:** D-7
- **Acceptance signals:** a test edits the roster between spawn and resume
  and the fake CLI still receives the spawn-time model; a spec written by
  master resumes without error and gains the recorded field.
- **Out of scope:** any UI for per-session model display beyond what MODEL-3
  derives; spec migration tooling (the field is additive).
- **Open questions:** None

### MODEL-3. Derive display labels and prompt prose from the roster

- **Outcome:** every user-visible model name — solve chooser, session and
  worker labels, reviewer prompts, transcript prefixes — renders the roster's
  `display` value for the assignment actually in force.
- **Scope:** `Solve/Event.hs:110-124` constants become roster functions;
  `UI/Overlay.hs`, `UI/Util.hs`, `UI/Solve.hs`, `UI/Session.hs`,
  `UI/Worker.hs` consumers; `Review/Prompts.hs` reviewer-identity prose;
  `UI/Review.hs:817,827` transcript literals; affected golden frames and
  protocol/supervision string assertions.
- **Phase:** 2
- **Depends on:** MODEL-1, MODEL-2
- **Ordering:** not on the critical path
- **Relevant decisions:** D-1
- **Acceptance signals:** changing a role's `display` in a test roster changes
  the chooser row and session header in golden frames; no string in `src/`
  names a model outside the roster module.
- **Out of scope:** plugin prose that names models
  (`claude-plugin/.../commands/issue-review.md` — prose saying "the backend
  owns selection" stays true and stays put).
- **Open questions:** None

### MODEL-4. Resolve the Python and plugin spawn sites from the roster

- **Outcome:** `approve_issues.py`, `drain_prs.py`, and the Claude plugin's
  `review_pr.py` resolve model/effort through a shared
  `tools/kanban_models.py` reader with their current values as compiled
  fallbacks; the Codex plugin's copy keeps its no-pinning delegation
  contract and is held to it by a negative control; one cross-language
  parity gate holds every roster-backed copy to the tracked defaults.
- **Scope:** the reader module in its three homes — `tools/` plus a
  byte-identical copy in each plugin bundle's `scripts/`, the shipping
  pattern `kanban_config.py` already follows, with the copies held
  byte-identical by the same gate and the new bundled asset declared in the
  bundle inventories; `issue_gate` consumption in `approve_issues.py` under
  the D-6 precedence (defaults < roster file < environment);
  `drain_rereview` in `drain_prs.py`, re-read per drain cycle; the Claude
  plugin copy's pinned constants become fallbacks behind the reader, loaded
  from beside the coordinator rather than from `tools/`; a negative
  assertion that the Codex plugin copy passes no model or effort flags (D-2
  as amended); the cross-language parity gate; stated rerun requirements
  for `install_drainer.py` and the issue-approval installer on live
  installs (new module under `tools/`).
- **Phase:** 2
- **Depends on:** MODEL-1
- **Ordering:** independent
- **Relevant decisions:** D-1, D-2, D-3, D-6
- **Acceptance signals:** the Python suite proves a roster file changes the
  model each roster-backed script passes to its fake CLI and that absence
  preserves today's values; the env layer wins over the file for
  `issue_gate`; the Codex plugin copy still spawns with no model or effort
  flags; the byte-identity gate fails when any of the reader's three copies
  drifts; the parity gate fails when any roster-backed copy's fallback
  drifts from the tracked defaults.
- **Out of scope:** changing which brand any script routes to; giving the
  Codex plugin copy pins — D-2 as amended keeps its delegation contract, and
  the roster never reaches it.
- **Open questions:** None

### MODEL-5. Extend the settings screen to edit role assignments

- **Outcome:** the `o` overlay gains a roster section: role × provider rows,
  focus movement, cycling through declared models and efforts, default
  markers, reset-to-default, atomic persist, live in-memory update, and a
  stale-approval warning on reviewer-role edits.
- **Scope:** overlay drawing and geometry, the filter-panel-style input
  decoder/applier, `Name` targets for mouse, `UI/Keys.hs` bindings plus the
  `docs/design.md` §7 key-table rows in the same PR, save/load wiring,
  golden frames, and event tests.
- **Phase:** 3
- **Depends on:** MODEL-1, MODEL-2
- **Ordering:** critical path
- **Relevant decisions:** D-1
- **Acceptance signals:** golden frames for the extended overlay; an event
  test drives a selection change, asserts the file on disk and that the next
  spawned fake worker receives the new argv; `Spec.UI.Keys` stays green.
- **Out of scope:** free-text entry for new model IDs unless the slice's
  design review keeps it (file-editing covers it otherwise); editing provider
  lists' effort vocabularies from the screen.
- **Open questions:** None

### MODEL-8. Derive the operating mode from the loaded provider set

- **Outcome:** a mode value (dual, single-agent, no-agent) computed at
  startup from the roster's `agents` list (D-10) and threaded wherever
  spawning and drawing will need it; dual behavior byte-identical; the
  settings overlay shows the derived mode read-only (the mode is shown by
  settings, never set there).
- **Scope:** the mode type and its derivation from the `agents` list already
  in MODEL-1's schema, plumbing into the resolved configuration and
  `AppState`, and the read-only mode line in the settings overlay.
- **Phase:** 4
- **Depends on:** MODEL-1, MODEL-2
- **Ordering:** critical path
- **Relevant decisions:** D-8, D-10
- **Acceptance signals:** roster fixtures derive each of the three modes;
  dual-mode argv and golden frames are unchanged from before the slice.
- **Out of scope:** any behavior keyed on the mode (MODEL-9, MODEL-10,
  MODEL-11).
- **Open questions:** None

### MODEL-9. Implement no-agent mode: board-only UI and spawn refusal

- **Outcome:** with zero providers loaded, Kanban is a board: agent actions
  are unavailable, their shortcuts hidden from every help and footer surface
  but deliberately still handled so a press produces the mode-naming refusal
  notice, spawn paths refuse the same way, and the usage sidebar and ping
  are absent; reads, filters, search, and details are untouched.
- **Scope:** mode-aware key visibility in `UI/Keys.hs` with the
  `docs/design.md` §7 key-table rows updated in the same PR (the table is a
  tested contract via `Spec.UI.Keys`), refusal arms in `UI/Events.hs`,
  usage and ping gating, and board-only golden frames.
- **Phase:** 4
- **Depends on:** MODEL-8
- **Ordering:** independent
- **Relevant decisions:** D-8, D-3
- **Acceptance signals:** a no-agent golden frame shows no agent shortcuts or
  usage panels; agent keys produce the refusal notice; `Spec.UI.Keys` stays
  green.
- **Out of scope:** the drainer's degraded behavior (MODEL-11, per Q-10).
- **Open questions:** None

### MODEL-12. Extract the provider adapter interface behind the agent flows

- **Outcome:** a compiled per-provider adapter record is the only place
  Kanban constructs agent-session provider processes — solve and PR-flow
  argv assembly,
  the embedded review session, one-shot runs, and the review tool registry —
  with the existing Codex app-server client and Claude CLI paths relocated
  behind it. A pure refactor: no behavior change anywhere.
- **Scope:** the adapter type beside the roster types, moving `Review.hs`
  client construction and the `Solve.hs`/`PullRequestFlow.hs`/
  `Review/Tools.hs` process assembly behind adapter lookups, module seams
  following the established split pattern, and relocating affected tests.
- **Phase:** 4
- **Depends on:** MODEL-1, MODEL-2
- **Ordering:** critical path
- **Relevant decisions:** D-13
- **Acceptance signals:** the full Haskell suite passes with no golden-frame
  or argv-expectation updates; the agent-session flows — `Solve.hs`,
  `PullRequestFlow.hs`, `Review.hs`, and `Review/Tools.hs` — contain no
  provider process construction outside adapter lookups, with the
  deliberately unadapted launchers (`Ping.hs` and the `Codex.hs`/`Claude.hs`
  usage probes, which are not agent sessions and consume no roster value)
  named as the gate's explicit exclusions rather than silently skipped.
- **Out of scope:** any new backend (MODEL-13); mode-keyed behavior;
  adapting the ping and usage-probe launchers, which stay as they are by
  design.
- **Open questions:** None

### MODEL-13. Implement the Claude embedded-review backend

- **Outcome:** the embedded issue review runs on Claude through its adapter
  backend, with the review tool registry (the `gh` runner; the nested
  revision tool registered only when Claude is loaded, per D-14 — a
  Codex-only install carries no revision tool and revises inside the review
  thread) and transcript/diagnostic parity with the Codex path; a
  Claude-only install keeps the embedded review action.
- **Scope:** the backend per Q-12's resolution, tool availability, failure
  vocabulary parity through `Review.Diagnostics`, and fake-executable tests
  mirroring the Codex client's coverage.
- **Phase:** 4
- **Depends on:** MODEL-12
- **Ordering:** critical path
- **Relevant decisions:** D-13
- **Acceptance signals:** fake-CLI tests run an embedded review end to end on
  the Claude backend; the Codex path's tests are untouched.
- **Out of scope:** single-agent routing (MODEL-10); any change to the Codex
  backend beyond relocation already done in MODEL-12.
- **Open questions:** Q-12 (deliberately open — this slice stops and asks
  with a concrete mechanism proposal before implementation)

### MODEL-10. Implement single-agent review routing in the Haskell flows

- **Outcome:** with one provider loaded, solve, PR review, revise, repair,
  and the embedded issue review all resolve to that provider through its
  adapter backend; the solve chooser auto-selects it; usage and ping show
  only the loaded provider.
- **Scope:** mode-aware `agentForAction` and `PullRequestFlow` routing, the
  chooser and related UI, embedded-review provider selection, reviewer
  identity in prompts, and tests covering both single-provider variants.
- **Phase:** 4
- **Depends on:** MODEL-8, MODEL-3, MODEL-13
- **Ordering:** critical path
- **Relevant decisions:** D-8, D-12
- **Acceptance signals:** fixtures prove a Claude-origin PR reviews on Claude
  in Claude-only mode and that the embedded review runs on the loaded
  provider's backend in both single-agent variants; origin markers are still
  written (D-12); dual-mode routing is untouched.
- **Out of scope:** the Python gates and plugin copies (MODEL-11); any change
  to dual-mode routing.
- **Open questions:** None

### MODEL-11. Make the Python gates and plugin reviews single-agent aware

- **Outcome:** `approve_issues.py`, both `review_pr.py` copies, and the
  drainer consult the loaded provider set: single-agent mode reviews with the
  loaded provider regardless of origin, unmarked-origin dual review collapses
  to one reviewer, the drainer degrades gracefully (D-11), and
  `docs/agent-workflow-contract.md` §2.2/§2.3 describe the modes.
- **Scope:** mode resolution in `tools/kanban_models.py`, routing in the
  three review scripts, the drainer's fail-closed incident arm, contract
  updates, and the parity gates extended to mode-aware behavior.
- **Phase:** 4
- **Depends on:** MODEL-4, MODEL-8
- **Ordering:** not on the critical path
- **Relevant decisions:** D-8, D-2, D-11
- **Acceptance signals:** fake-CLI tests prove single-agent routing in both
  review scripts and the drainer's no-agent incident arm (D-11); dual-mode
  behavior is unchanged.
- **Open questions:** None

### MODEL-6. Package the defaults and document the roster surface

- **Outcome:** the tracked example roster ships in the release artifact
  beside `config.toml.example`; `docs/design.md` §16 documents the file and
  §7/§19 describe roles instead of naming models; the contract's §2.2 model
  policy points at the roster; `docs/user-guide.md` gains the operator
  walkthrough.
- **Scope:** release packaging wiring, the documentation sweep for whatever
  prose remains after the earlier slices carried their own edits, and
  `claude-plugin/README.md:245`'s pinned-pair paragraph.
- **Phase:** 5
- **Depends on:** MODEL-2, MODEL-4, MODEL-5, MODEL-11
- **Ordering:** not on the critical path
- **Relevant decisions:** D-1
- **Acceptance signals:** the release artifact contains the example roster;
  no tracked document names a wire model ID outside the defaults table and
  the historical reports.
- **Out of scope:** coordination with `docs/public_release_design.md`'s
  slices beyond adding one packaged file.
- **Open questions:** None

## Source notes

The owner's framing (2026-08-20): settings should dictate which models are
canonical for the various agent sessions, replacing hardcoded selection; the
system should be data-driven enough to adapt to other model providers; a
settings screen first ("i thought i had one but i guess i didnt" — one
exists but edits only chat verbosity), then a config format saving default
and current user settings, packaged in the release; then the ability to
change which model performs which steps at which effort levels; two providers
(claude, codex) supported now, with future plans for a single agent and for
no agents ("just kanban").

On bringing modes into scope (2026-08-20): "single agent would need to
bypass any cross agent checks. no longer would codex be reviewing claude,
but a provider would need to review itself, so we have to rewrite our checks
and gates to be aware of the single agent mode. for no agent mode i want
just the board, no agent solver behaviors, and the related shortcuts should
not display … these modes wont be set in the settings of course, they are
backend modes selected by the number of agents loaded in to the system." On
scope of overrides: per-system for now; per-repository would be its own epic
if ever wanted.

On the provider interface (2026-08-20): "if any component only speaks one
app-server protocol, then it is going to need to be part of this epic arc to
fix it. ideally we would have a system that worked like plugins, with each
agent defining its interface, and the protocols, and then kanban will figure
out how to interface." The owner approved landing the compiled adapter
interface and the Claude embedded-review backend in this arc, with the
external plugin/manifest system as a separate future arc that binds to the
adapter interface.
