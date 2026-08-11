# Usage awareness design

Vincent runs Claude and Codex under rolling quota windows and points spare
capacity at kanban when synarchy work is blocked. Today the only way to see
either brand's remaining quota or reset time through Kanban is to launch the
full TUI, and there is no way to deliberately start a rolling window before
stepping away. This arc makes quota state reachable from any shell, visible
with countdowns in the board, and deliberately triggerable — so spare tokens
get spent on purpose instead of discovered too late.

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. Make provider quota state visible, quick, and deliberately triggerable
- [ ] USE-1. Add kanban --usage printing cached windows with reset countdowns
- [ ] USE-2. Show reset countdowns and snapshot age in the usage sidebar
- [ ] USE-3. Add a deliberate per-brand window-starting ping action
- [ ] USE-4. Add burn-planning display sized to remaining quota

## Epic contract

- **Goal:** from any shell or from the board, Vincent can answer "how much
  quota is left, when does each window reset, and is a window running" in
  under two seconds, and can start a window on purpose with one command.
- **Done when:** `kanban --usage` prints both brands' windows with countdowns
  without launching the TUI; the sidebar shows the same countdowns and the
  snapshot's age; `kanban --ping <brand>` starts a chosen brand's window and
  confirms it; and the configured "≈N solve rounds left" estimate renders
  wherever usage does.
- **Users and operators:** Vincent interactively (shell and TUI); scripts or
  status bars if a machine-readable output is chosen; the design.md §14
  contract governs the provider probes this arc reuses.
- **Arc label:** proposed `usage` (no existing label fits; `agent-workflows`
  covers the packaged workflow surface, not the provider probes).

## Current state and evidence

- **Both probes already capture everything the features need.** The domain
  types are `UsageSnapshot`/`UsageWindow` with `usageWindowLabel`,
  `usagePercentLeft`, and `usageResetsAt` (`src/Kanban/Domain.hs`). Codex:
  `codex app-server` JSON-RPC `account/rateLimits/read` returns used percent,
  window durations, and reset timestamps (`src/Kanban/Codex.hs:36-160`,
  `docs/design.md:1165-1175`). Claude: the `claude` client under macOS
  `script` in a private PTY, `/usage` scraped and parsed including "Resets …"
  lines inferred to UTC (`src/Kanban/Claude.hs:361-455`,
  `docs/design.md:1177-1208`).
- **The TUI already has a usage surface.** A sidebar shows both providers'
  windows; `u` refreshes GitHub and both probes; a failed provider never
  hides the other; freshness is tracked per provider and snapshots persist in
  `~/.cache/kanban/` (`src/Kanban/UI.hs:77-90,173-179`,
  `src/Kanban/UI/Reconcile.hs:163-176`, `docs/user-guide.md:158-160,168`).
  What it does not show: time-until-reset or the age of a stale snapshot.
- **Refresh policy is contract-bound.** Usage refreshes once at startup and
  on explicit `u` only (`docs/design.md:1156-1159`); §20 defers "automatic
  refresh intervals, disabled by default if ever added"
  (`docs/design.md:2005`). A countdown that ticks locally consumes no
  network and does not breach this; a background re-probe would.
- **External-command escape hatch.** `[usage.codex]`/`[usage.claude]`
  `command` keys replace the built-in probe on every refresh
  (`docs/user-guide.md:41-43`, closed #58). Any new consumer of usage
  snapshots must go through the same provider layer so the escape hatch
  keeps working.
- **CLI shape.** `optparse-applicative` flag modes, no subcommands:
  `--doctor` is the precedent for a run-and-exit mode
  (`src/Kanban/CLI.hs:18-31`). `--version` hard-codes `kanban 0.1.0.0`
  (`src/Kanban/CLI.hs:110-111`) — a file the release arc may also touch;
  coordinate at solve time.
- **Contract touchpoints for a ping.** design.md's release-verification
  decision D-2 states the *probes* are account-status reads and a release
  check must not consume a model prompt (`docs/design.md:2022-2027`); the
  unprocessed design.md slice REL-2 verifies live refreshes "without
  submitting a model prompt" (`docs/design.md:2106-2122`). A ping is the
  opposite by intent — a deliberate, user-invoked consumption action — so
  §14 needs a new action class distinguishing deliberate consumption from
  passive probing, updated in the same PR (design.md is
  implementation-coupled).
- **No overlapping arc.** Repo-scoped tracker searches for usage/quota
  return only closed items (#58, #20, #45); no open issues or epics overlap.

## Desired experience

From any shell: `kanban --usage` answers instantly — each brand, each
window: percent left, "resets in 2h 14m", and the wall-clock reset time,
plus how old the snapshot is. Before stepping away: one command starts a
chosen brand's window so the clock runs while AFK, and the output confirms
the window is live. In the board: the sidebar's windows carry the same
countdowns and a visible snapshot age, so a stale number is never mistaken
for a fresh one. When deciding what to run next, the configured
"≈N solve rounds left" estimate sizes the next batch of kanban work to the
quota that would otherwise expire unspent.

## Scope

### In scope

- A no-TUI CLI usage mode reusing the existing provider layer and cache.
- Reset countdowns and snapshot-age display, shared between CLI and sidebar.
- A deliberate per-brand window-starting action and its §14 action class.
- Burn-planning display as a configured static estimate (D-3).
- design.md §14/§16 and user-guide updates riding each behavior PR.

### Out of scope

- Automatic or background usage refresh (deferred by design.md §20; a local
  ticking countdown is display-only and does not re-probe).
- Changing probe mechanics, the `script` wrapper, or the app-server protocol.
- Cross-machine or historical usage analytics.
- Scheduling or automatically launching solve work when quota is available —
  burn planning informs; it does not act.

## Design

- **Shared formatting core.** One pure module renders a `UsageSnapshot` to
  window lines with countdowns ("Session · 62% left · resets in 2h 14m ·
  7:00 PM") and snapshot age, parameterized by now-time so it is
  deterministic under test. CLI and sidebar both consume it; golden frames
  cover the sidebar, plain unit fixtures cover the CLI text.
- **`kanban --usage` (USE-1, D-1).** A run-and-exit mode beside `--doctor`.
  Cache-first: prints the cached snapshot instantly with its age; `--fresh`
  forces live probes; `--no-cache` implies live. Respects `--config` and the
  external-command escape hatch. Output is human text; a `--json` variant is
  a natural companion for scripts and status bars (proposal, folded into
  USE-1 unless rejected).
- **Sidebar countdowns (USE-2).** The sidebar windows gain "resets in …"
  and the snapshot age when stale. No new network behavior: countdowns
  derive from `usageResetsAt` against the clock. Golden frames updated.
- **Ping (USE-3, D-2).** `kanban --ping claude|codex` — the brand argument
  is required; omitting it is an error, never a default to both. Fires the
  cheapest one-shot non-interactive request the brand offers (Claude: a
  single minimal `claude -p` prompt in the probe's scratch-directory
  conventions; Codex: a minimal `codex exec`), bounded timeouts, then one
  usage refresh so the new window end is confirmed, printed, and cached.
  CLI-only in this arc — no TUI keybinding. §14 gains a "deliberate
  consumption actions" class stating: never run implicitly, never as part
  of a probe, refresh, preflight, or release check — preserving design.md
  D-2's meaning.
- **Burn planning (USE-4, D-3).** A per-brand config key (estimated percent
  consumed per solve round) yields an "≈N solve rounds left this window"
  line in the CLI output and sidebar. Static and honest: the line appears
  only when the key is configured and the window has data; no measurement,
  no persistence beyond config.
- **Failure handling.** CLI mode mirrors the sidebar's isolation contract: a
  failed provider prints its error line and does not mask the other, exit
  code reflects whether any snapshot was produced. Ping failures are
  explicit and never retried silently (a retry would consume again).

## Decisions

### D-1. kanban --usage is cache-first with a --fresh override

User signoff 2026-08-10. Default invocation prints the cached snapshot
instantly with its age; `--fresh` forces live probes; `--no-cache` implies
live. Always-live was rejected for its seconds-per-call latency (the Claude
probe spawns an interactive client); cache-only was rejected because a cold
cache would leave the quick command mute. Consequence: staleness is a
first-class display state in both the CLI and the sidebar.

### D-2. Ping is CLI-only, per-brand, and confirms the window it starts

User signoff 2026-08-10. `kanban --ping claude|codex` with the brand
required — no default, no both-at-once (rejected: consumes quota on an
account the user may be saving), no TUI keybinding in this arc (rejected to
keep the §7 bindings and overlay surface untouched; revisitable later).
After the one-shot request, exactly one usage refresh runs and the new
window end is printed and cached.

### D-3. Burn planning is a configured static estimate

User signoff 2026-08-10. A per-brand config key (estimated percent per
solve round) yields "≈N solve rounds left this window" in usage output.
Display-only was rejected as under-serving the burn-planning goal; a
measured estimator was rejected for its persistence and accuracy
obligations. Consequence: USE-4 stays a thin slice; §16 config docs gain
the key.

## Open questions

### Q-1. What are `kanban --usage`'s freshness semantics?

Resolved by D-1.

### Q-2. What is the ping action's shape?

Resolved by D-2.

### Q-3. How deep does burn planning go in this arc?

Resolved by D-3.

## Verification strategy

- The formatting core is pure and fixture-tested (fixed now-time,
  representative windows: fresh, stale, missing provider, cold cache).
- CLI mode gets fake-provider integration tests via the existing
  `[usage.codex]`/`[usage.claude]` external-command escape hatch — no
  network, no accounts, matching the suite's fake-executable pattern.
- Sidebar countdowns ride the golden Brick frames
  (`KANBAN_UPDATE_GOLDENS` refresh in the same PR).
- Ping's contract (never implicit, bounded, refresh-after) is asserted with
  fake provider executables recording their invocations.
- design.md §14 (and §16 for any new config keys) updated in the same PRs;
  `docs/user-guide.md` gains the new flags and key.

## Delivery plan

### USE-1. Add kanban --usage printing cached windows with reset countdowns

- **Outcome:** `kanban --usage` prints both brands' windows with percent
  left, countdown, reset wall-clock time, and snapshot age, honoring the
  D-1 freshness policy; shared formatting core extracted for USE-2.
- **Scope:** the formatting module, the CLI mode, `--json` companion unless
  rejected, config/escape-hatch/`--no-cache` interaction, docs.
- **Phase:** 1
- **Depends on:** none
- **Ordering:** can land first
- **Relevant decisions:** D-1
- **Acceptance signals:** fake-provider integration tests cover fresh,
  stale, cold-cache, and one-provider-failed paths; output matches fixtures.
- **Out of scope:** sidebar changes; ping; any estimate beyond countdowns.
- **Open questions:** None

### USE-2. Show reset countdowns and snapshot age in the usage sidebar

- **Outcome:** sidebar windows show "resets in …" and the snapshot's age
  when stale, from the shared formatting core; no new network behavior.
- **Scope:** sidebar rendering, golden-frame updates, user-guide sidebar
  section.
- **Phase:** 1
- **Depends on:** USE-1
- **Ordering:** not on the critical path
- **Relevant decisions:** D-1 (staleness is a first-class display state)
- **Acceptance signals:** golden frames show countdowns; a stale snapshot is
  visually distinct from a fresh one.
- **Out of scope:** auto-refresh of any kind (design.md §20).
- **Open questions:** None

### USE-3. Add a deliberate per-brand window-starting ping action

- **Outcome:** `kanban --ping claude|codex` ends with a confirmed new
  window end; design.md §14 gains the deliberate-consumption action class.
- **Scope:** the ping implementation for both brands, its CLI surface, §14
  and user-guide updates, fake-provider tests.
- **Phase:** 2
- **Depends on:** USE-1
- **Ordering:** independent
- **Relevant decisions:** D-2
- **Acceptance signals:** fake-provider tests prove ping runs only when
  explicitly invoked, exactly once, bounded, and triggers one refresh;
  design.md D-2's no-prompt property for probes/refreshes still holds.
- **Out of scope:** scheduling pings; pinging as part of any other action;
  a TUI keybinding (D-2).
- **Open questions:** None

### USE-4. Add burn-planning display sized to remaining quota

- **Outcome:** the configured per-brand estimate renders as "≈N solve
  rounds left this window" in CLI output and sidebar, only when configured
  and the window has data.
- **Scope:** the config key, its §16 documentation, the estimate line in
  the shared formatting core, fixtures.
- **Phase:** 2
- **Depends on:** USE-1, USE-2
- **Ordering:** not on the critical path
- **Relevant decisions:** D-3
- **Acceptance signals:** fixtures cover the estimate arithmetic, the
  unconfigured case (no line), and the missing-window case (no line).
- **Out of scope:** acting on the plan (launching work automatically);
  measured estimation.
- **Open questions:** None
