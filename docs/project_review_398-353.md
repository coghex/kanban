# Project Review Findings: PRs #398–#353

This review continued below the completed #399 cursor and covered the next
twelve genuinely unreviewed merged pull requests in merge-time order: #398,
#397, #396, #394, #395, #392, #389, #388, #360, #359, #356, and #353. The
previously reported #386, #376, #379, #377, #374, #372, #371, #365, #364,
#363, #362, and #361 batch was explicitly skipped rather than reviewed again.
The review also covered the three direct first-parent documentation commits
interleaved through the selected landing interval: `9cf80f7`, `f3cff80`, and
`efe15b3`. The batch was frozen at
`origin/master@1544709bcfbf197c87e55ea69a7be8988bb90965` on 2026-08-27.

Each selected pull request was checked against its linked issue, pull-request
body, commits, landed diff, canonical review discussion, current
implementation, callers, and focused tests. Each direct commit was checked
individually against its patch and the current state of the documents it
changed. Later descendants were read only to establish whether a mistake still
exists: in particular, PR #388's explicitly tracked residual issue #390 was
fixed by later PR #406 and is not a current finding. The stale README filter-key
concern visible while reading #360 is already preserved in
`docs/project_review_466-399.md` and was not duplicated. This report preserves
the two new current concerns that still need one-at-a-time disposition.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [x] PRR-1. The systemd reader ignores ExecStart resets and can invoke the wrong controller — [#549]
- [x] PRR-2. The lane contract says assignment is balance-only despite a required safety placement — [#552]

## 1. Systemd controller discovery

### [#549] PRR-1. The systemd reader ignores ExecStart resets and can invoke the wrong controller

> **Captured note:** Correct PR #353 / commit `1b2034c`'s systemd-unit reader so
> empty `ExecStart=` resets and multiple-command validity are interpreted the
> way systemd interprets them, rather than discarding resets and concatenating
> distinct commands into one argument vector.

**Verification:** Static tracing confirms a current mismatch on an ordinary
systemd override shape. systemd's parser clears the accumulated command list
when it reads an empty assignment, and its service verifier refuses more than
one `ExecStart=` command unless the service is `Type=oneshot`. Kanban instead
filters every empty assignment out, tokenizes every non-empty assignment, and
concatenates all their words.

For this valid reset sequence:

```ini
[Service]
Type=exec
ExecStart="/old/controller" "run"
ExecStart=
ExecStart="/actual/controller" "run"
```

systemd's effective command is `/actual/controller run`. Direct evaluation of
the current list comprehension and `concatMap` yields
`Right ["/old/controller", "run", "/actual/controller", "run"]`.
`controllerFromProgramArguments` then keeps `/old/controller` as the
executable, removes only the final `run`, and later invokes that retired command
with the second executable among its arguments. With two non-empty directives
and no reset, systemd rejects the `Type=exec` unit while Kanban still constructs
and invokes a combined command. The focused existing Haskell parser tests and
all 80 Python service-manager tests pass because neither suite covers repeated
or reset-then-replaced `ExecStart=` semantics.

**Evidence:**

- `src/Kanban/Drainer.hs:619-632` — systemd discovery reads the unit, passes it
  through `unitExecStartArguments`, and trusts the returned words as the
  controller command.
- `src/Kanban/Drainer.hs:649-678` — the reader claims to model what systemd
  runs, drops empty `ExecStart=` assignments, and concatenates every remaining
  directive; its comment incorrectly says later directives append.
- `src/Kanban/Drainer.hs:714-732,782-789` — the first concatenated word becomes
  the executable and the rebuilt command is used for status, start, and stop
  operations.
- `test/Spec/Drainer.hs:362-387` — the contract tests call the unit authoritative
  and cover one command, a missing command, and a lone empty assignment, but no
  reset followed by a replacement or invalid multiple-command unit.
- `docs/agent-workflow-contract.md:631-645` and `docs/design.md:2414-2418` — both
  current contracts require the command read from the definition to remain
  authoritative for what the service manager actually runs.
- [systemd `config_parse_exec`](https://github.com/systemd/systemd/blob/85cdcad36b9e02471aa9b579db0d7a49009d9a1b/src/core/load-fragment.c#L904-L907)
  — an empty assignment frees the accumulated command list; [systemd service
  verification](https://github.com/systemd/systemd/blob/85cdcad36b9e02471aa9b579db0d7a49009d9a1b/src/core/service.c#L1049-L1050)
  rejects multiple start commands for every non-oneshot service.

**Handoff context:**

- **Current behavior:** A hand-edited unit or a unit assembled with a resetting
  drop-in can make Kanban invoke a stale controller or reject valid controller
  arguments even though systemd runs only the post-reset command. An invalid
  multi-command `Type=exec` unit can likewise be treated as an executable
  controller definition even though systemd refuses it.
- **Expected behavior:** Controller discovery either reconstructs the one
  effective `ExecStart` command systemd accepts or fails closed with reinstall
  guidance. It never invokes a command different from the effective unit and
  never accepts a unit systemd rejects for command multiplicity.
- **Scope and constraints:** Preserve direct unit-file discovery, exact argv
  with no shell, existing specifier and quoting behavior, backend-specific
  diagnostics, and the installer-generated single-command unit. Treat reset
  semantics and service-type validity as observable requirements rather than
  prescribing a particular parser design.
- **Verification target:** Add fixtures for an old command followed by an empty
  reset and a replacement, consecutive non-empty commands under `Type=exec`,
  and any supported `Type=oneshot` multiplicity. Assert that discovery returns
  exactly the effective command or a precise refusal, then exercise status and
  start/stop construction so the wrong executable cannot be reached.
- **Deduplication:** The full issue inventory and all-state searches for
  `ExecStart`, systemd parser, reset, and controller command found no tracker
  item for this mismatch. Closed issue #329 introduced the backend but does not
  separately own the parser correction.
- **Remaining uncertainty:** Whether Kanban intends to support multi-command
  `Type=oneshot` definitions is a product choice; reset handling and refusal of
  invalid non-oneshot multiplicity are not.

## 2. Test-suite lane contract

### [#552] PRR-2. The lane contract says assignment is balance-only despite a required safety placement

> **Captured note:** Reconcile PR #394 / commit `9cc7e91`'s foundational lane
> documentation with PR #506 / commit `af33eda`'s later safety exception:
> `suiteGroups` now contains a placement that must not overlap another group,
> so the shared contract cannot keep saying assignment affects balance only.

**Verification:** The two current module comments directly contradict each
other. `Spec.Support.Lanes` says its process-isolation inventory is complete,
no group is constrained to another group's lane, and `suiteGroups` decides
balance rather than safety. `Spec.hs` now says `Spec.Repository.Lease` is the
one group placed for safety instead of cost: running it beside
`Spec.Agent.Usage` materially increased late-sweep flakes, while placing both
in `UsageLane` serializes them. The actual assignment follows the later safety
rule, so runtime behavior is currently protected, but the reusable lane
contract tells a future rebalancing change that no such constraint exists.

**Evidence:**

- `test/Spec/Support/Lanes.hs:43-66` — the shared runner contract concludes that
  no future group has a lane constraint and that `suiteGroups` decides balance,
  not safety.
- `test/Spec.hs:97-117` — the live suite inventory explicitly documents
  `Spec.Repository.Lease` as the one safety placement and quantifies the flake
  increase observed when it overlaps `Spec.Agent.Usage`.
- `test/Spec.hs:145-146` — both groups are assigned to `UsageLane`, which makes
  them serial within the lane process.
- `git blame` — the absolute balance-only claim survives from PR #394's
  `9cc7e91`; the repository-lease placement was added later by PR #506's
  `af33eda` without reconciling that shared prose.

**Handoff context:**

- **Current behavior:** The suite is safely packed today, but its central lane
  module tells maintainers that moving any group between lanes is a balance-only
  operation. Following that statement for `Spec.Repository.Lease` can restore
  the documented high-rate process-sweep flake.
- **Expected behavior:** The shared contract records every safety-sensitive
  co-location or points unambiguously to the authoritative constraint next to
  `suiteGroups`; no balance guidance claims safety constraints are absent while
  one is active.
- **Scope and constraints:** Preserve separate-process lanes, serial execution
  within each lane, the current Repository.Lease/Agent.Usage non-overlap, and
  the measured-cost packing guidance. This may be a documentation-only
  correction unless a stronger machine-checked assignment invariant is chosen.
- **Verification target:** Repository searches find no remaining claim that
  lane membership is only balance-sensitive, the safety exception is visible
  from the shared runner contract and the group roster, and the focused suite
  assignment checks remain green. If the exception is removed instead, first
  prove the two groups can overlap repeatedly without reintroducing the late
  sweep.
- **Deduplication:** The full issue inventory and all-state searches for lane
  safety, balance, `suiteGroups`, Repository.Lease, and UsageLane found only
  closed issue #501, which introduced the repository lease and its test harness;
  no issue tracks the contradictory current lane documentation.
- **Remaining uncertainty:** The observed flake rate is historical rather than
  reproduced during this read-only review. The current comments nevertheless
  state opposite requirements, and the suite deliberately retains the safety
  placement.
