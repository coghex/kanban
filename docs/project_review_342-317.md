# Project Review Findings: PRs #342–#317

This review continued below the completed #343 cursor and covered the next
twelve merged pull requests by merge time: #342, #341, #339, #336, #335,
#330, #326, #325, #324, #323, #322, and #317. It also reviewed all eight
direct first-parent documentation commits interleaved between #343 and #317:
`2ddd1df`, `097eeed`, `83133d5`, `3b12ed3`, `f4b262b`, `c94451b`, `e7a46cc`,
and `d201b7c`. The batch was frozen at `master@4b5c5da` on 2026-08-22. Master
advanced through #464 and #465 while the review was running; those newer
landings were excluded rather than moving the boundary, and both findings
below were rechecked at current `master@d0b6be2`.

Each pull request was checked against its linked issue, pull-request body,
commits, landed diff, canonical review history, current implementation,
callers, and current tests. Each direct commit was checked individually against
its patch and current document state. Later descendants were read only to
establish whether a mistake still exists. This report preserves the two
confirmed current mistakes that still need one-at-a-time disposition.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [ ] PRR-1. Concurrent usage refreshes can erase each other's cached provider snapshots
- [ ] PRR-2. The fixed usage sidebar clips 100%-remaining and long-label rows

## 1. Usage-cache transaction boundary

### PRR-1. Concurrent usage refreshes can erase each other's cached provider snapshots

> **Captured note:** Serialize the shared `usage.json` read-merge-write so a
> TUI refresh, `kanban --usage`, or `kanban --ping` process cannot publish a
> whole map derived from stale cache state and erase another process's
> successful provider refresh.

**Verification:** The cache writer uses an atomic temporary-file rename, which
prevents readers from seeing partial JSON but does not make the callers'
read-merge-write atomic. `kanban --usage` retains the map it loaded before its
provider probes and later replaces the whole file with fresh results merged
into that old map. A ping independently loads the file after its refresh and
also replaces the whole map, while the TUI writes the complete map held in its
own process state. None of the three paths takes a cross-process lock or checks
that the file is still the version it read.

The loss was reproduced under an isolated `XDG_CACHE_HOME`: two simulated
callers both loaded an absent cache, the first wrote a Codex snapshot from its
copy, and the second wrote a Claude snapshot from its independent stale copy.
Both writes returned `Right ()`; the final decoded cache contained only Claude.
The same interleaving is reachable between the ordinary CLI, ping, and TUI
writers, so a successful refresh can silently disappear even though each
caller says it merged rather than replaced provider state.

**Evidence:**

- `src/Kanban/Usage.hs:129-154` — `acquireUsageReport` loads the cache before
  probing, retains that map across both provider calls, then passes
  `Map.union fresh cached` to the whole-file writer without re-reading or
  acquiring a lock.
- `src/Kanban/Ping.hs:269-297` — each ping separately loads the current map and
  calls `writeUsageCache (Map.insert provider snapshot existing)`; two brands
  can therefore start from the same prior map and let the later rename discard
  the earlier result.
- `src/Kanban/UI/Reconcile.hs:354-376` — the dashboard writes the whole
  `appUsage` map it held when that provider event was applied, with no
  coordination against another Kanban process.
- `src/Kanban/Cache.hs:329-357` — `loadUsageCache` and `writeUsageCache` are
  separate public operations, and the writer accepts an already-composed whole
  provider map.
- `src/Kanban/Cache.hs:359-376` — `writeCacheFile` atomically renames a complete
  temporary file but has no lock, compare-and-swap, or merge at the mutation
  boundary.
- `docs/design.md:1791-1793` and `docs/design.md:1940-1943` — the current
  contract says live and ping results are merged while leaving the other
  provider's stored entry intact; the reproduced interleaving violates that
  promise.

**Handoff context:**

- **Current behavior:** Concurrent normal invocations can each report a
  successful cache write while the last whole-file rename drops a provider
  snapshot written by the other invocation. A stale same-brand writer can
  likewise replace a newer snapshot.
- **Expected behavior:** Every enabled-cache write merges against the latest
  committed provider map under one cross-process transaction boundary. A
  successful provider refresh remains present unless a demonstrably newer
  snapshot for that same provider supersedes it.
- **Scope and constraints:** Centralize the transaction in the cache layer or
  an equally universal mutation API used by all three writers. Preserve the
  atomic whole-file replacement, `0600` permissions, unknown-version and
  corrupt-cache behavior, non-fatal warning paths, and the rule that
  `--no-cache` / `cache = false` performs no cache read or write.
- **Verification target:** A deterministic barrier-controlled test runs two
  independent stale readers/writers and proves both provider results survive.
  Add a same-provider ordering case so an older snapshot cannot replace a
  newer one, and exercise the TUI, `--usage`, and ping call paths against the
  shared mutation primitive.
- **Deduplication:** Searches of all tracker states for usage-cache
  concurrency, `usage.json` races, lost updates, stale writes, and snapshot
  overwrites found the originating usage issues #333 and #337 plus adjacent
  cache and coordinator work, but no issue tracking this cross-process loss.
  Existing findings reports contain no usage-cache transaction finding; open
  epic #354 explicitly keeps usage global but does not change or own its write
  concurrency.
- **Remaining uncertainty:** None.

## 2. Usage-sidebar width budget

### PRR-2. The fixed usage sidebar clips 100%-remaining and long-label rows

> **Captured note:** Budget the usage percentage row against the sidebar's
> actual 24-cell interior for every legal percentage and arbitrary sanitized
> provider label, preserving the percentage marker instead of relying on Brick
> to clip the row.

**Verification:** The row concatenates a label padded to a minimum of seven
characters, one separator cell, and a bar whose width grows with the decimal
percentage. At 100%, a seven-cell label plus separator and bar is 25 terminal
cells, one beyond the fixed interior. Labels longer than seven are never
truncated, so they overflow at still lower percentages; external usage-command
labels have no maximum length. The checked-in whole-application estimate frame
shows the observable result: its 100% row ends in `100` rather than `100%`
because the final marker is clipped.

This is not a theoretical boundary missed by a fixture. The focused usage test
documents the exact 25-cell row and calls it an overflow that “has always had,”
then extracts only the first 24 cells from the rendered sidebar. Closed issue
#334 named both the 100% and long-label cases as pre-existing and out of scope;
closed issue #338 preserved them while adding the estimate. Neither issue owns
the still-required correction.

**Evidence:**

- `src/Kanban/UI/Board.hs:128-137` — the sidebar is fixed at 28 cells and
  declares 24 content cells as the budget for every provider row.
- `src/Kanban/UI/Board.hs:300-304` — `drawUsageWindow` concatenates the label
  and bar without measuring, bounding, or truncating the finished row.
- `src/Kanban/UI/Board.hs:339-346` — the ten-cell bar appends brackets, a
  separator, the unbounded decimal rendering, and `%`; three percentage digits
  therefore add a cell compared with the ordinary two-digit shape.
- `src/Kanban/UI/Util.hs:70-71` — `padLabel` pads labels shorter than seven but
  never bounds longer ones and measures `Text.length`, not terminal-cell width.
- `src/Kanban/UsageCommand.hs:200-213` — an external command's label is
  arbitrary sanitized nonempty text with no width limit, making the long-label
  case directly reachable.
- `test/Spec/UI/Usage.hs:295-300` — the test source records the 100% percentage
  row as 25 cells and explicitly leaves its one-cell overflow unrepaired.
- `test/golden/usage-estimate-sidebar.txt:9-12` — the whole-application frame's
  100%-remaining case visibly loses the trailing `%`, rendering
  `5 hour  [██████████] 100`.

**Handoff context:**

- **Current behavior:** A legal 100% snapshot loses its percent marker, and an
  external label longer or wider than the assumed seven cells clips progressively
  more of the bar and percentage.
- **Expected behavior:** Every legal percentage row fits the 24-cell interior
  in terminal display cells, keeps the remaining percentage unambiguous, and
  handles arbitrary sanitized labels with an explicit bounded presentation.
- **Scope and constraints:** Keep the sidebar's contractual 28-cell outer
  width and the existing reset/countdown row behavior. Decide the label
  abbreviation or bar-sizing rule explicitly, and use terminal display width
  so wide Unicode labels cannot bypass it.
- **Verification target:** Sweep percentages 0 through 100 and labels at,
  beyond, and display-wider than the nominal seven-cell width through the whole
  rendered application. Assert no row exceeds 24 cells and that the complete
  percentage, including `%`, remains visible; update the golden so the 100%
  case no longer encodes clipping as expected output.
- **Deduplication:** Searches of all tracker states for percentage-row,
  `padLabel`, 100%, label-width, sidebar-clipping, and usage-overflow terms found
  only #334 and #338, whose approved scopes explicitly decline this repair.
  Existing findings reports contain no matching usage-sidebar width finding.
- **Remaining uncertainty:** The exact label-abbreviation versus bar-compaction
  presentation is a product choice; the current clipping and required 24-cell
  bound are not uncertain.
