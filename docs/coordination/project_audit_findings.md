# Kanban project audit

Audit of `master` at `c89bc0b`, September 5, 2026, emphasizing the visual board and optional agent coordinator.

## Assessment

The strongest parts are the explicit workflow model, tracker grouping, selection handling, terminal text sanitization, and extensive golden-frame tests. Visually, the cards expose useful information without requiring constant detail-panel navigation. I would prioritize responsiveness and card density before a visual redesign.

The coordinator’s separation of dispatch from observation, durable worker records, and explicit handling of unknown outcomes are sensible choices. Its main weakness is how those components interact: mission execution reuses machinery built around a single dashboard’s ownership assumptions.

The tests are substantial, but the verified failures below show where coverage needs to move toward combined operation and persistence failures.

## Methodology

Inspected the design’s implementation state, workflow contracts, board rendering/navigation/filtering, GitHub process management, action registry, mission runner/controller/store, and selected drainer and CI paths. Reviewed the checked-in board image and golden frames.

Validation completed:

| Check | Result |
|---|---|
| `cabal check` | No warnings or errors |
| `cabal build all` | Passed |
| Haskell suite | 2,536 examples, zero failures |
| Python suite | 3,640 tests, two skipped, no failures |

Additional compiled probes used production functions, fake `gh` commands, and temporary storage. No live agent sessions or GitHub mutations were performed. Implementation files remain unchanged.

This was a targeted audit, not exhaustive verification of every module.

Status legend: `[ ]` unprocessed · `[#N]` filed · `[no-issue]` deliberately not filed · `[deferred]` awaiting a concrete precondition.

## Status

- [ ] KA-1. Rendering cost grows with offscreen cards
- [ ] KA-2. Concurrent mission and board reads conflict over process bookkeeping
- [ ] KA-3. Precondition reads do not bind the selected repository
- [ ] KA-4. Failed command persistence can lose a pause request
- [ ] KA-5. Precondition reads bypass the configured GitHub timeout

## Board responsiveness

### KA-1. Rendering cost grows with offscreen cards

**Priority: medium; highest board priority.**

The column renderer constructs every standalone card and every expanded tracker child inside its viewport. Clipping does not restrict rendering work to the visible cards.

Using the production application renderer at a fixed **164×50 cells**, repeated renders produced these median CPU times:

| Cards | Render time |
|---:|---:|
| 100 | 17 ms |
| 500 | 90 ms |
| 1,000 | 176 ms |
| 5,000 | 879 ms |

Selection changed between renders. Wall times closely matched CPU times.

**Evidence:** [column rendering](/Users/vincentcoghlan/work/kanban/src/Kanban/UI/Board.hs:746), [card construction](/Users/vincentcoghlan/work/kanban/src/Kanban/UI/Board.hs:822), [measurement log](/tmp/kanban-audit-20260905/render-cpu.log).

**Handoff context:** Preserve the uncapped dataset while reducing offscreen work through viewport-aware rendering or carefully invalidated caching. Preserve variable card heights, search, tracker expansion, selection, and mouse targets.

**Remaining uncertainty:** These are synthetic frame-construction measurements with simple cards, not measurements of interactive latency on your larger project.

## Mission reliability

### KA-2. Concurrent mission and board reads conflict over process bookkeeping

**Priority: high.**

Missions are allowed to run beside a dashboard. However, each mission board read creates a separate in-process lock around the same repository-wide `gh` record. Reclamation assumes an existing record belongs to a previous dashboard.

**Reproduction:** Hold one fake GitHub fetch open, then start another fetch with an independent lock. The second refuses to start, describing the first as a `gh` left by a previous Kanban board. The first subsequently completes successfully.

**Evidence:** [mission fetch setup](/Users/vincentcoghlan/work/kanban/src/Kanban/Mission/Runner.hs:427), [ownership assumption](/Users/vincentcoghlan/work/kanban/src/Kanban/GitHub/Guard.hs:103), [reclamation](/Users/vincentcoghlan/work/kanban/src/Kanban/GitHub/Guard.hs:402), [reproduction log](/tmp/kanban-audit-20260905/github.log).

**Handoff context:** Define ownership and synchronization across dashboard, mission, and worker reads. Retain abandoned-process recovery while distinguishing healthy concurrent readers. Add a test that exercises those readers together.

**Remaining uncertainty:** The false refusal is reproduced. This reproduction did not kill another reader or demonstrate lost record updates.

### KA-3. Precondition reads do not bind the selected repository

**Priority: high.**

The precondition reader invokes `gh issue view` or `gh pr view` without `--repo`. Its process launcher also sets no working directory. The supplied `Repository` controls bookkeeping, but does not select which repository GitHub CLI reads.

**Reproduction:** Ask the production mission driver to observe `audit-owner/audit-target` while running from the Kanban checkout. It executes:

```text
issue view 844 --json number,updatedAt,labels,state
```

The working directory remains the Kanban checkout. Additionally, a fake response naming item **999** is accepted as item **844**: the decoder requests `number` but never validates it.

**Evidence:** [command arguments and decoding](/Users/vincentcoghlan/work/kanban/src/Kanban/GitHub/Precondition.hs:74), [process configuration](/Users/vincentcoghlan/work/kanban/src/Kanban/GitHub/Run.hs:80), [reproduction log](/tmp/kanban-audit-20260905/github.log).

**Handoff context:** Bind reads explicitly to the resolved repository and validate returned identity. Cover `--path` from another directory, `--repo` overrides, and custom remote configurations.

**Remaining uncertainty:** The argument, directory, and identity-validation defects are reproduced; no wrong-repository mutation was attempted.

### KA-4. Failed command persistence can lose a pause request

**Priority: high.**

Command completion removes the request even when the snapshot transition failed. It also discards errors from writing the command’s journal entry.

**Reproduction:** Queue a pause, then temporarily prevent replacement of the readable snapshot. The controller:

1. Reports `MissionControllerFailed`.
2. Removes the pause request.
3. Leaves `MissionRunning` in the snapshot.

After repairing the write fault, the pause is no longer queued. A separate probe made `events.jsonl` unwritable; the controller still returned `MissionCommandApplied` and removed the request.

**Evidence:** [command completion](/Users/vincentcoghlan/work/kanban/src/Kanban/Mission/Controller.hs:1347), [discarded journal result](/Users/vincentcoghlan/work/kanban/src/Kanban/Mission/Controller.hs:1987), [lost-pause reproduction](/tmp/kanban-audit-20260905/lost-command.log), [journal reproduction](/tmp/kanban-audit-20260905/commands.log).

**Handoff context:** Preserve a request until its transition and acknowledgment have been durably accounted for. Propagate persistence failures and ensure replay remains safe when the transition succeeded before acknowledgment failed.

**Remaining uncertainty:** Both cases were reproduced in temporary stores. The snapshot failure ends the current run with an error; the concern is lost operator intent on recovery.

### KA-5. Precondition reads bypass the configured GitHub timeout

**Priority: medium.**

The mission’s target precondition read calls the raw process runner without a timeout. The foreground controller waits synchronously, so its iteration budget does not bound this wait, and queued commands cannot be processed during it.

**Reproduction:** Configure `timeouts.github_seconds = 1` and use a fake `gh` that sleeps for three seconds. The production mission driver returns a successful reading after approximately **3.55 seconds**.

**Evidence:** [target read](/Users/vincentcoghlan/work/kanban/src/Kanban/Mission/Runner.hs:463), [synchronous controller loop](/Users/vincentcoghlan/work/kanban/src/Kanban/Mission/Runner.hs:319), [measurement log](/tmp/kanban-audit-20260905/deadline.log).

**Handoff context:** Apply an explicit deadline, retain verified process cleanup, and report timeout as an unverified precondition. Test a non-answering process alongside normal responses.

**Remaining uncertainty:** Worker-level deadlines may bound worker callers; they do not bound the foreground mission’s own read.
