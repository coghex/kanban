# Project Review Findings: PRs #533–#517

This review covered the twelve newest merged pull requests at the frozen
selection boundary, in merge-time order: #533, #532, #530, #531, #529, #527,
#528, #523, #520, #519, #518, and #517. It also reviewed the nine direct
first-parent documentation commits interleaved through that range: `b0ff0e2`,
`884bf40`, `68bb979`, `8e8e46d`, `7da7081`, `e36589b`, `68cc8b9`, `87698d9`,
and `5711c5a`. The batch was frozen at `origin/master@9a2edb3` on 2026-08-27.
The later direct documentation landing `9c3b2f9` was excluded rather than
moving the boundary; every finding below was rechecked against the current
descendant at `origin/master@9c3b2f9`.

Each pull request was checked against its linked issue or standalone contract,
pull-request body, commits, landed diff, canonical review discussion, current
implementation, callers, and focused tests. Each direct commit was checked
individually against its patch and the current state of the document it
changed. Later descendants were read only to establish whether a mistake still
exists. This report preserves the four confirmed current concerns that still
need one-at-a-time disposition.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [x] PRR-1. No-agent mode removes lifecycle controls for recovered persistent workers — [#546]
- [x] PRR-2. The busy triage fallback marks a changes-requested issue as ready — [#557]
- [ ] PRR-3. Reused process-group IDs can misattribute this board's `gh` to a previous board
- [ ] PRR-4. The reconciled `gh` authority design claims a decoder that was never implemented

## 1. Persistent-worker control in no-agent mode

### [#546] PRR-1. No-agent mode removes lifecycle controls for recovered persistent workers

> **Captured note:** Keep creation of new agent work disabled when no provider
> loads, but preserve an explicit way to inspect and terminate persistent work
> that a previous board already launched and the current board recovers.

**Verification:** PR #532 implemented issue #521 exactly: in no-agent mode it
hides and refuses `p` (`ShowProcesses`) and `x` (`KillWorking`) along with the
bindings that start new agent work. That rule is sound for creation surfaces,
but it was applied to lifecycle controls without reconciling the already-landed
persistent-worker contract.

Startup still discovers workers in every operating mode. The discovery event
unconditionally attaches each descriptor, reconstructs solve or PR sessions
from the worker's durable recorded assignment, and starts monitoring it. This
is intentionally independent of the current roster: a user can launch a
persistent solve or PR worker, later configure `agents = []` or restart with an
unloadable roster, and still inherit the live worker.

Once that happens, the same board hides and refuses `p`, refuses `x`, and
refuses the right-click route to the recovered live session. The orphan notices
continue telling the user to press `p` to inspect or `x` to kill. The result is
not merely a missing footer hint: the board can show and monitor work it owns
but provides no route to inspect or terminate it. The no-agent test fixture
already contains live solve, PR, and review sessions, yet asserts that all six
keys change only the notice, so the suite codifies the lockout instead of
exercising the restart/recovery lifecycle.

The focused no-agent suite passed 26 examples. That confirms the implemented
refusal and its golden presentation; it does not reconcile the conflict with
the persistent-worker requirements.

**Evidence:**

- `src/Kanban/UI.hs:349-355` — startup forks `discoverWorkers` without an
  operating-mode condition.
- `src/Kanban/UI/Events.hs:138-140` — every discovered descriptor is attached.
- `src/Kanban/UI/Worker.hs:177-238` — attachment registers the worker,
  reconstructs a session, and starts its monitor; recovered solve sessions use
  the durable recorded assignment at lines 205-219.
- `src/Kanban/UI/Keys.hs:281-288` — both `KillWorking` and `ShowProcesses` are
  classified as requiring a loaded agent, just like the creation surfaces.
- `src/Kanban/UI/Events.hs:1127-1152` — the right-click route to a live session
  is refused through the same no-agent gate.
- `src/Kanban/UI/Worker.hs:130-175` — orphan status still directs the user to
  the now-refused `p` and `x` actions.
- `test/Spec/OperatingMode.hs:146-185,340-356` — the no-agent fixture carries
  running sessions and asserts that every gated action, plus right-click,
  changes only the refusal notice.
- `docs/design.md:3556-3568,3598-3633,3662-3668` — persistent work survives TUI
  exit, is recovered after restart, remains visible when orphaned, and is
  inspectable and terminable through `p` and `x`.
- `docs/design.md:341-355,401-407` — the later no-agent wording removes those
  same controls without defining an exception or replacement for recovered
  work.

**Handoff context:**

- **Current behavior:** A board started with no loaded provider discovers and
  monitors existing repository-scoped workers, but `p`, `x`, and right-click
  all refuse before opening or changing them.
- **Expected behavior:** No-agent mode continues to block every operation that
  needs to start or resume a provider, while preserving a clearly documented
  management route for work already running. At minimum the user can inspect
  recovered sessions and terminate their owned process trees.
- **Scope and constraints:** Do not re-enable new solve, review, autosolve,
  approval, usage-probe, or model-spawn behavior. Preserve the mode-naming
  refusal for actions that genuinely require a provider, the existing worker
  authority checks, TERM/KILL escalation, survivor verification, and lease
  retention on an unverifiable kill. Reconcile `docs/design.md` §7 with
  Milestone 8 in the same behavior change.
- **Verification target:** Start or fixture a persistent solve and PR worker,
  restart with a no-agent roster, and prove each is visible, inspectable, and
  terminable without spawning a provider. Separately prove that the same mode
  still refuses creation and resume paths and still hides provider-only
  controls.
- **Deduplication:** Searches of all tracker states for no-agent lifecycle,
  recovered-worker, process-inspector, and persistent-worker termination terms
  found issue #521 and epic #412 as the originating work, plus older closed
  process-management issues. None tracks the conflict between #521's blanket
  gate and recovery of work launched by a prior board.
- **Remaining uncertainty:** The exact presentation is a product choice: `p`
  and `x` can remain visible only when manageable work exists, or no-agent mode
  can expose a separate lifecycle-only surface. The need for some management
  route is not presentation-dependent.

## 2. Busy approval reconciliation

### [#557] PRR-2. The busy triage fallback marks a changes-requested issue as ready

> **Captured note:** During the approval lock's busy fallback, do not render a
> readiness checkmark for an issue whose complete snapshot also carries the
> canonical changes-requested label.

**Verification:** PR #528 added a deliberate liveness exception: when canonical
approval reconciliation cannot take its lock, triage and retriage render `✓`
from the configured approval label in their already-complete issue snapshot.
The current instruction applies that rule to every issue with the label and
forbids the ordinary unverified marker.

The same snapshot can also say that the issue carries `reviewed:changes`.
Canonical `current_gate_status` treats that exact label as a refusal reason, so
an issue carrying both labels has `approved: false` during an ordinary
reconciliation and receives no `✓`. During a busy result, however, it receives
one. No extra GitHub read or lock acquisition is needed to avoid the mismatch;
both labels are already in the verified-complete snapshot.

The canonical PR review called this coexistence out twice as a non-blocking
edge case, including in its final approval. The backend normally prevents the
state itself, so manual labeling or external automation is required, but the
roadmap then presents a known blocking state as ready while saying its marks
reflect current labels. The focused reconciliation suite passed all 84 tests;
its asset assertions currently require every approval-labeled issue to receive
the fallback mark and contain no coexistence exception.

**Evidence:**

- `tools/command_sources/triage.md:185-194` — ordinary `current` entries with
  `approved: false` receive no checkmark, including when `reviewed:changes` is
  present, while the busy fallback marks every snapshot issue carrying the
  approval label.
- `tools/command_sources/retriage.md:175-188` — retriage delegates its entire
  readiness decision, including the busy exception, to triage's rule.
- `tools/approve_issues.py:1002-1024` — `current_gate_status` appends
  `has reviewed:changes` to the refusal reasons and derives `approved` from an
  empty reason list.
- `tools/test_reconcile_approvals.py:858-900` — the workflow-asset test pins the
  every-approval-label fallback but does not exclude a snapshot-known blocking
  label.
- PR #528 canonical review discussion — both the changes-requested review and
  the final approval note that an issue carrying both readiness labels still
  receives the busy fallback mark.

**Handoff context:**

- **Current behavior:** A busy reconciliation gives `✓` to an open issue with
  both the configured approval label and `reviewed:changes`, even though a
  non-busy reconciliation over the same state returns `approved: false`.
- **Expected behavior:** The busy fallback remains live and label-backed, but
  suppresses the marker for blockers the complete snapshot can decide without
  the lock. At minimum that includes the canonical changes-requested label.
- **Scope and constraints:** Preserve the one-time busy disclosure, the
  configured approval-label lookup, complete-snapshot requirement, no-retry
  rule, zero-mutation behavior, and fail-closed handling outside this scoped
  fallback. Do not add per-issue backend calls or guess a label absent from the
  contract.
- **Verification target:** Asset tests fixture an issue carrying only the
  approval label, one carrying both approval and changes-requested labels, and
  one carrying neither. Under `outcome: busy`, only the first receives `✓`, in
  both triage and retriage, with the disclosure emitted exactly once.
- **Deduplication:** Searches of all tracker states for the busy fallback,
  label coexistence, `reviewed:changes`, and triage checkmarks found no issue
  for this case. Issue #391 is the originating approval-reconciliation work,
  not ownership of this later busy exception. PR #528 has no linked issue.
- **Remaining uncertainty:** Whether snapshot-known incidents or other
  canonical blockers should also suppress the fallback mark is a wider policy
  question. The exact `reviewed:changes` contradiction is already decided by
  the current gate vocabulary.

## 3. Durable `gh` entry attribution

### PRR-3. Reused process-group IDs can misattribute this board's `gh` to a previous board

> **Captured note:** Track the identity of entries inherited at the first
> reclaim, not only their raw process-group IDs, so a later group this same
> board starts is not described as a predecessor's after the operating system
> reuses a PGID.

**Verification:** PR #518 distinguishes a record entry inherited from a dead
predecessor from one written later by the current board. On the first record
read, `rememberInherited` stores only the entries' integer PGIDs in a set and
never changes that set. Every later diagnostic calls `entryOrigin`, which says
an entry belongs to a previous board whenever its PGID is still in that set.

That is not a stable process identity. After the original inherited group is
confirmed gone and removed from the durable record, its PGID can be reused
during the current dashboard's lifetime. If a new `gh` started by this board
receives that PGID and later needs a cleanup diagnostic, `entryOrigin`
misclassifies it as inherited. The project already treats PID and PGID reuse as
real in its safety model and pins process members to start identities; this
message-only path discards that information.

The existing tests prove predecessor wording and current-board wording with
different PGIDs. They do not exercise reuse of an inherited PGID. Owner
presence cannot repair the decision: as the implementation comments note, new
entries written by this board also carry an owner. This finding is limited to
false diagnostic provenance; the inherited set is passed only to message
construction, and census, liveness, and signaling remain identity-pinned.

**Evidence:**

- `src/Kanban/GitHub/Guard.hs:76-112` — `ghRecordInherited` is a
  `Maybe (Set Int)` whose elements are documented as PGIDs.
- `src/Kanban/GitHub/Guard.hs:446-475` — the first read stores only
  `ownedProcessGroupPid`, and every later origin decision is a raw set-membership
  test on that integer.
- `src/Kanban/GitHub/Guard.hs:477-488` — the inherited value affects only the
  per-entry message; reclaim behavior is intentionally identical.
- `src/Kanban/Process.hs:63-104` — durable groups carry identity-pinned members
  specifically to reject PID reuse, plus informational owner metadata that is
  not authority.
- `test/Spec/GitHub/BoardRefresh.hs:1080-1131` — predecessor and current-board
  message tests use distinct PGIDs and leave the reuse transition uncovered.
- `docs/design.md:3598-3605,3624-3633` — persistent-process cleanup and
  termination verification require start-identity checks rather than raw PID
  continuity.

**Handoff context:**

- **Current behavior:** Once PGID N appears in the record at the board's first
  reclaim, any later entry with PGID N is described as left by a previous board,
  even if the first entry was removed and the current board created the later
  one.
- **Expected behavior:** Attribution recognizes the exact entries inherited at
  first read, or retires a remembered PGID when that inherited claim is
  cleared, so later reuse is described as work this board started.
- **Scope and constraints:** Correct wording only. Do not make owner metadata a
  liveness signal, signaling target, reclaim prerequisite, or source of process
  authority. Preserve the repository lease, member census, start-identity
  checks, and identical cleanup behavior for inherited and current entries.
- **Verification target:** A deterministic seam first classifies an inherited
  entry, clears it, then presents a current-board entry with the same PGID but a
  different member/start identity and proves the message changes to “this board
  started.” Existing predecessor and missing-owner cases remain unchanged.
- **Deduplication:** Searches of all tracker states for PID/PGID reuse,
  `OwnedProcessGroup`, and “previous Kanban board” found closed process-safety
  issue #9 and epic #499. Issue #9 owns identity-safe census and termination;
  #499 is the originating authority arc. Neither tracks reuse in this new
  diagnostic-provenance set.
- **Remaining uncertainty:** None about the false attribution. Its user impact
  is limited to a rare cleanup diagnostic and does not change which processes
  Kanban observes or signals.

## 4. Reconciled authority-design accuracy

### PRR-4. The reconciled `gh` authority design claims a decoder that was never implemented

> **Captured note:** Reconcile the delivered authority design with the actual
> backward-compatible `OwnedProcessGroup` decoder. The compatibility behavior
> exists, but it is supplied by Aeson's generic instance rather than the
> hand-written instance the document repeatedly says landed.

**Verification:** Direct documentation commit `7da7081` reconciled
`docs/gh_record_authority_design.md` after PR #518 delivered GHA-2. The current
document still says `OwnedProcessGroup` would gain, did gain, and was delivered
behind a hand-written `FromJSON` decoder using `.:?` and `.!=`.

The delivered type instead retains `deriving anyclass (FromJSON, ToJSON)`.
Aeson's generic decoder supplies the required optional-field compatibility:
the repository-authority suite constructs the exact legacy JSON shape with no
owner key and proves it decodes to `ownedProcessGroupOwner = Nothing`. Thus the
runtime contract is satisfied and no implementation fix is needed; the
reconciled design's mechanism and delivery record are simply false. Because
the commit explicitly changed the ledger to mark GHA-2 delivered, preserving a
future-tense mechanism that did not land is current design-document drift, not
merely an old proposal.

**Evidence:**

- `docs/gh_record_authority_design.md:421-438` — Entry attribution says the
  derived instance is replaced by a hand-written decoder using `.:?` and `.!=`.
- `docs/gh_record_authority_design.md:519-545` — signed-off D-3 consequences
  repeat that `OwnedProcessGroup` gains a hand-written `FromJSON` instance.
- `docs/gh_record_authority_design.md:883-900` — the reconciled, completed GHA-2
  scope says the optional owner landed behind a hand-written backward-compatible
  decoder.
- `src/Kanban/Process.hs:69-104` — `OwnedProcessGroup` still derives both JSON
  instances generically and declares no custom decoder.
- `test/Spec/Repository/Authority.hs:273-286` — the exact schema-version-1
  shape without an owner key decodes successfully and both owned and unowned
  entries round-trip.
- Direct commit `7da7081` — marks GHA-2 complete as delivered by PR #518 while
  retaining the unimplemented mechanism in the current-state narrative,
  decision consequences, and delivery scope.

**Handoff context:**

- **Current behavior:** Legacy records already decode correctly through the
  generic instance, while the authoritative arc document says a custom decoder
  implements that behavior.
- **Expected behavior:** Describe the compatibility requirement and the actual
  generic implementation, or make the design mechanism-neutral. Do not add a
  custom decoder solely to make historical prose true.
- **Scope and constraints:** Documentation-only correction. Preserve D-3's
  optional owner, schema version 1, no-migration conclusion, and the test-backed
  guarantee that a missing owner decodes as `Nothing`. Audit all three repeated
  claims rather than correcting only the delivery-slice bullet.
- **Verification target:** Repository search finds no remaining claim that
  `OwnedProcessGroup` has a hand-written decoder, while the legacy decode and
  owner round-trip tests remain the cited evidence for compatibility.
- **Deduplication:** Searches of all tracker states and findings reports for a
  hand-written `OwnedProcessGroup` decoder and its JSON compatibility found no
  issue or existing concern. Epic #499 and PR #518 own the delivered behavior,
  not this later reconciliation error.
- **Remaining uncertainty:** None.
