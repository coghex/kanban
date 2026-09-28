# Concurrent readers of the durable `gh` record design

Kanban's durable `gh` process-group record promises that a `gh` this project
started is never left running, unaccounted, beside a `gh` it is about to
start. The board-authority arc (`docs/designs/gh_record_authority_design.md`, epic
#499) made that promise hold across dashboards by giving one dashboard the
repository lease and treating everything it found in the record as a dead
predecessor's. That arc drew its boundary in true words: the record was
reached only from the board-refresh path, and the agent workers' own `gh`
calls never touched it.

Mission Control (#595, merged 2026-09-04) moved that boundary without moving
the authority. The mission runner reads the board and observes targets through
the record, and every worker now rereads its target's precondition through it,
each from a process that holds no lease. The record now has three kinds of
reader and exactly one of them is entitled to the assumption the record's
classification rests on. This design settles what the other two are, so a
mission runner sitting beside a dashboard — the attachment §15 says is
intended, and the one the mission runner service (#597) made permanent —
is not refused by a guard that thinks it is a ghost.

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Reconcile the durable `gh` record with readers that hold no repository lease — [#642]
- [x] GHR-1. Serialize the durable record's read-modify-write across processes — [#720]
- [x] GHR-2. Classify a recorded `gh` by its writer's liveness rather than by first sight — [#721]
- [ ] GHR-3. Give the mission runner and the worker precondition one record authority each, and prove three readers together

## Epic contract

- **Goal:** A mission runner, a worker rereading its precondition, and a
  dashboard can read GitHub for one repository at the same time, from separate
  processes, and none of them refuses, waits on, or signals another's healthy
  `gh`; while a `gh` that any of them abandoned is still found and reclaimed
  by whichever reader comes next.
- **Done when:** the audit's reproduction — a second reader starting while a
  healthy fetch runs — completes instead of refusing; two processes writing the
  record concurrently lose no entry; an abandoned `gh` from a killed runner or
  worker is reclaimed by the next reader of any kind; and `docs/design.md` §15
  no longer claims both that non-dashboard readers run beside the board and
  that nothing but the board can have written the record.
- **Users and operators:** the operator running `kanban --mission` or the
  installed mission runner service (#597) beside an open board; every worker Kanban launches,
  since each rereads its precondition through the same record; and the
  maintainers of `Kanban.GitHub.Guard`, who inherit the classification rule.
- **Arc label:** `board-authority` (existing; the label the predecessor arc
  used)

## Current state and evidence

Verified against `master` at `ddd33d9` on 2026-09-07. The audit that surfaced
this is finding KA-2 of `docs/coordination/project_audit_findings.md`; its
reproduction log survives at `/tmp/kanban-audit-20260905/github.log`.

### One lock per process, and one per call

- Every `gh` the guard spawns is registered in the repository's durable record
  before it runs (`registerSpawnedGh`, `src/Kanban/GitHub/Guard.hs:332`), and
  the read-modify-write of that file is serialized by `withRecordLock`
  (`Guard.hs:142`), which is `withMVar` over an `MVar` minted by
  `newGhRecordLock`. Nothing locks the file itself; `writeCacheFile`
  (`src/Kanban/Cache.hs:814`) renames a temporary file into place, which makes
  each write atomic and does nothing for two writers that both read the same
  predecessor.
- The dashboard mints one such lock per repository coordinator
  (`src/Kanban/UI/Refresh.hs:265`) and holds the repository lease for its
  life. The mission runner mints a fresh one for every board read
  (`src/Kanban/Mission/Runner.hs:428`) and every target observation
  (`Runner.hs:464`). The worker precondition check mints a fresh one per call
  in the worker's own process (`src/Kanban/Worker/Precondition.hs:54`),
  reached from `Kanban.Worker` at `Worker.hs:746` and from the issue host.
- `liveMissionDriver` is constructed only by `runMissionMode`
  (`Runner.hs:259`), so the readers in play are exactly three: the dashboard
  coordinator, the `--mission` runner, and the `--worker` precondition reread.
  The dashboard does not advance missions itself; it reads the durable mission
  record and submits commands.

### The classification rule and the premise it rests on

- `reclaimRecordedGhGroups` (`Guard.hs:382`) runs before every open fetch and
  every history page (`src/Kanban/GitHub/Fetch.hs:202,250`). On a lock's first
  read of the record, `rememberInherited` (`Guard.hs:474`) freezes every pgid
  present as *inherited*, and `entryOrigin` (`Guard.hs:517`) then describes
  each of them as "a gh left by a previous Kanban board".
- The premise is stated in `docs/design.md` §15 at line 2549: "What separates
  a leftover from a board's own work is not the owner but the record the board
  found at its first reclaim, since under the lease nothing else could have
  written it." The Guard module's own comments say the same
  (`Guard.hs:101-104`).
- The same section says, at line 2524, that `--mission` takes only the
  mission's advancement lease and that "a mission runner and a dashboard on
  the same repository therefore run side by side, which is exactly the
  attachment the mission contract expects". §5 says the same of `--mission` at
  line 226. §3's non-goal at line 74 declines concurrent *dashboards* only.
- The predecessor arc excluded workers on a fact that was true when written:
  "the `gh` calls the solve, review, and pull-request workers make … run
  outside the durable record entirely — the record and guard are reached only
  from the board-refresh path" (`docs/designs/gh_record_authority_design.md:308-312`,
  restated at `:416` and `:596`). Commits `aa4f9db`, `13b4538`, and `54d5adf`
  of 2026-09-04, all under #595, are where `preconditionStillHolds` and the
  runner's reads started going through the guard.

### Hazard A — a healthy concurrent read is refused (reproduced)

The audit held one fake `gh api` open under one guard, then started a second
`fetchGitHubSnapshot` under an independent lock in the same process. The
second refused:

```text
a gh process could not be confirmed stopped (a gh left by a previous Kanban
board (pgid 56466) still accounts for 2 running process(es) that cannot be
identified as this repository's, so they cannot be signalled from here);
refusing to start another until it is
```

The first fetch then completed normally. In production the same shape is a
mission board read landing while the dashboard's refresh is mid-page, or a
worker's precondition reread landing while either is. A runner whose target
observation fails ends the run, by the runner's own design (`Runner.hs:447-
462`); a worker whose reread fails refuses its turn as
`workerUnverifiedTargetReason`.

### Hazard B — a healthy `gh` is never signalled (verified, the audit's open question)

A running `gh` is recorded uncensused (`OwnedProcessGroup pgid [] False`,
`Guard.hs:339`); the census that pins identities is written only after the
leader is reaped, for its survivors (`src/Kanban/GitHub/Run.hs:160-166`).
`reclaimGhGroup` signals only a censused group whose known identities are
still in it (`provablyOurs`, `Guard.hs:585`), so a concurrent reader's healthy
`gh` is watched and refused over, never killed. The finding's "did not kill
another reader" is therefore a property, not a gap in the reproduction.

### Hazard C — the lost update (traced, not reproduced)

Two processes each hold their own `MVar`, so nothing orders one process's
read against the other's write. A runner registering its `gh` while the
dashboard drops a finished one can leave either the runner's live entry or the
dashboard's out of the file. A live entry dropped is a `gh` the record no
longer covers, which is the one thing the record exists to prevent. The
predecessor arc reproduced the same hazard between two dashboards
(`gh_record_authority_design.md:133`) and closed it by forbidding the second
dashboard; that closure does not reach readers the lease does not govern.

### Deduplication

No open issue owns this. #499, #501, and #558 built the lease and the owner
metadata on the premise above. #595 is closed with the runner deliberately not
taking the board lease. #597's body records that choice
(`mission_runner_design.md:106-110`) and says nothing about the record; its
RUN-1 will run this reader permanently beside dashboards. Searches for "gh
record lease concurrent", "previous Kanban board", "mission fetch guard
lease", "worker precondition guard record", and "reclaim gh group refuse"
returned nothing open.

## Desired experience

- An operator with a board open runs `kanban --mission <id>`, or the runner
  service advances a mission, while the board refreshes. Both reads complete.
  Neither sees a notice about a `gh` left by a previous board.
- A worker launched from either rereads its precondition while the launcher's
  own `gh` is running, and gets an answer about its target rather than a
  refusal about somebody else's process.
- A runner killed mid-fetch leaves a `gh` behind. The next reader — the
  dashboard's next refresh, the next runner turn, or the next worker — finds
  it, describes it as what it is, and reclaims it the way a dead dashboard's
  leftover is reclaimed today.
- §15 describes one rule for whose `gh` an entry is, and every reader follows
  it.

## Scope

### In scope

- Cross-process serialization of the record's read-modify-write.
- The rule by which a reader decides whether a recorded `gh` is a live
  reader's or an abandoned leftover, and the message that names it.
- The mission runner's and the worker precondition's use of the record.
- A test that runs a dashboard-shaped reader, a runner-shaped reader, and a
  worker-shaped reader against one repository at once, in separate processes.
- The `docs/design.md` §15 text that currently states both halves of the
  contradiction, and the Guard module's comments that restate it.

### Out of scope

- The repository lease itself, its key, and the refusal of a second dashboard
  (D-1 through D-8 of the predecessor arc stand).
- The mission advancement lease (§16) and the runner service's scheduling
  (#597 RUN-5).
- The solve, review, and pull-request workers' *agent* `gh` calls — the ones
  the provider makes inside a session — which still run outside the record.
- Automatic background polling, cross-machine coordination, and anything the
  predecessor arc's out-of-scope list already declines.
- Reclaiming a `gh` the record never held.

## Design

The record has one job: a `gh` any Kanban process started must be findable by
the next Kanban process that is about to start one, so that an abandoned group
is reclaimed before it is overlapped. Today the record answers "is this entry
abandoned?" with "was it here before I first looked?", and that question has
the right answer only for a reader that knows nothing else could have been
writing. Three directions were open; D-2 chose P-B, and P-A and P-C are kept
below as the alternatives it rejected.

### Proposal P-A. Restore the boundary: non-lease readers stay out of the record

The runner's reads and the worker's precondition reread spawn `gh` under a
guard whose record is in-memory only, so they neither read nor write the
durable file. The dashboard's rule stays exactly as D-3 and D-8 left it.

*Consequences.* Smallest change, and it makes the predecessor arc's boundary
statement true again. But a runner or worker killed mid-fetch leaves a `gh`
nothing will ever reclaim, and RUN-1 installs a reader that runs unattended for
weeks. Hazard C disappears only because the second writer disappears. The
finding's handoff — "retain abandoned-process recovery while distinguishing
healthy concurrent readers" — is not met; only the second half is.

### Proposal P-B. Extend the authority: one shared record, many writers, liveness-based ownership

The record becomes a genuinely multi-writer file. Its read-modify-write is
serialized by a POSIX lock on the file, taken and released around each
rewrite (GHR-1). Each entry names the writing process by an identity the
kernel can vouch for — the writer's pid and start time, which `ProcessIdentity`
already carries as the optional owner field (D-3 of the predecessor arc) —
and a reader classifies an entry as *live* while that identity is still
running and as *abandoned* once it is not (GHR-2). "Inherited at first sight"
stops being the rule. A live entry is left alone and does not block the
reader; an abandoned one is reclaimed exactly as today. Every reader holds one
lock per process rather than one per call (GHR-3).

*Consequences.* Meets the finding's handoff in full and makes the record's
promise hold for RUN-1's permanent reader. It reopens the "genuine concurrency
design" D-1 of the predecessor arc declined — but for a configuration §15
already says Kanban supports, not for a second dashboard. It changes the
meaning of the owner field from informational to decisive, which D-3 said it
was not, so D-3's rationale needs restating rather than silently reversing.
The identity is process-scoped, so the lease's own caveat applies in reverse:
an entry whose writer's identity could not be captured has no liveness to
test, and the arc must say what such an entry is (settled by D-3).

### Proposal P-C. Separate records: one file per reader process, reclaimable by anyone

Each non-dashboard process writes its own record file beside the dashboard's,
keyed by the repository and its own identity. A reader reclaims from every
file whose writer is no longer running and ignores the rest.

*Consequences.* Removes the shared-file race without a file lock, and keeps the
dashboard's file exactly as it is. But it multiplies the migration, cleanup,
and legacy-record surface D-8 just canonicalized, and the "whose writer is
still running" test is the same one P-B needs, so it saves the lock and costs
a directory of files. Recorded as considered; not proposed as the direction.

### What is common to every direction

- A healthy `gh` is never signalled by another reader. This holds today
  (Hazard B) and stays a requirement, not a side effect.
- The reclaim of an abandoned group keeps its verified TERM-then-KILL
  escalation and its refusal when ownership cannot be proven.
- `docs/design.md` §15 says one rule, once. The sentence at line 2549 and the
  one at line 2524 cannot both survive as written under any direction.
- Isolation by `XDG_CACHE_HOME` is preserved, so the existing isolated
  cache-root test conventions keep working.

## Decisions

### D-1. This is an epic rather than one issue

The work is a design decision (Q-1) plus dependency-ordered slices whose
first, cross-process atomicity, is independently reviewable and testable with
the two-process harness #501 built. It is also a stated prerequisite of a
reader (#597 RUN-1) that will otherwise make the defect permanent.

**Rationale:** one issue would hand a solver the choice among P-A, P-B, and
P-C, which is the user's; and it would bundle a file-lock change, a
classification change, and two call-site changes into one review.

**Consequences:** the arc is captured here and filed through
`/process-design-doc`; finding KA-2 is marked with the epic's number when it
exists.

**Signed off:** by the user, 2026-09-07, as the `/process-report` disposition
for KA-2.

### D-2. The authority is extended: one shared record, many writers, liveness-based ownership

Proposal P-B is the direction. The record stays one file per repository, its
read-modify-write is serialized across processes by a lock on the file, every
entry names the process that wrote it, and a reader classifies an entry as
live while that process is running and as abandoned once it is not.

**Rationale:** it is the only direction that keeps both halves of the
finding's handoff — healthy concurrent readers are distinguished *and*
abandoned-process recovery is retained — and #597 RUN-1 will run the affected
reader unattended for weeks, which is exactly when an unreclaimed leftover
matters. P-A was rejected because it abandons recovery for the readers that
need it most; P-C because it needs the same liveness test and adds a directory
of files to the migration surface D-8 just canonicalized.

**Consequences:** D-1 of the predecessor arc stands for dashboards — a second
dashboard is still refused — but its rationale, that a genuine concurrency
design was for a configuration nobody asked for, no longer covers non-dashboard
readers, which §15 already says run beside the board. D-3 of that arc, which
made the owner field informational, is superseded: the owner becomes the fact
liveness is tested against, and GHR-2 annotates the predecessor document to say
so. The first-sight rule (`rememberInherited`, `entryOrigin`) is retired.

**Signed off:** by the user, 2026-09-07.

### D-3. A reader that cannot identify itself does not write the shared record

An entry this release writes always carries its writer's process identity.
A reader whose process snapshot fails, and so has no identity to record, falls
back to an in-memory guard for that spawn and writes nothing to the shared
file. An entry with no owner can therefore only have been written by an older
release, and it is handled as today: watched until its pgid is unoccupied,
never signalled.

**Rationale:** the alternatives both guess. Treating an ownerless entry as
abandoned risks refusing over a live reader that could not name itself;
treating it as live until its pgid empties risks never reclaiming it across
pgid reuse. Not writing it removes the ambiguous case from this release's
records instead of ruling on it. A reader with no snapshot could not reclaim
anything anyway — reclaim needs the same snapshot — so it loses nothing it
could have used.

**Consequences:** the owner field becomes required on write and stays optional
on read, for legacy entries. GHR-2 carries the fallback and its refusal text.
D-5 extends the rule to the dashboard.

**Signed off:** by the user, 2026-09-07.

### D-4. This arc lands before #597 RUN-1

The mission runner service is not installed until every slice here has
merged, so an installed runner never ships refusing beside an open board.

**Rationale:** RUN-1 turns the refused reader into a permanent one; landing it
first would make Hazard A the ordinary state of every installation for as long
as the gap lasted.

**Consequences:** `mission_runner_design.md` gains a dependency note naming
this arc, added in GHR-3; RUN-1's `Depends on` gains this arc's epic when it
is filed. The RUN arc's other slices are unaffected.

**Signed off:** by the user, 2026-09-07.

**Overtaken, 2026-09-28.** RUN-1 (#666), RUN-2 (#667), and RUN-3 (#668)
merged on 2026-09-12 through 2026-09-14 (PRs #676, #677, #690) without a
dependency on #642, so the runner service became installable before any slice
here landed. GHR-1 (#720) and GHR-2 (#721) merged on 2026-09-24 and closed
Hazards A and C for installed runners too. The ordering this decision imposed
can no longer be met and is withdrawn: GHR-3 adds no dependency note to
`mission_runner_design.md`. Epic #642 owes two edits — its `Done when` line
naming that note, and its dependency-structure sentence saying RUN-1 is
blocked by this epic — to be presented for approval alongside GHR-3's
epic-checklist change. Until GHR-3 lands, the gap still open on an installed
runner is the one D-6 closes.

**Amendment signed off:** by the user, 2026-09-28.

### D-5. D-3 covers every writer, the dashboard included, and identity is taken per spawn

The rule is uniform: a dashboard whose process snapshot fails does not write
the shared record for that spawn either, and falls back to the in-memory
guard exactly as a runner or worker does. To keep that from costing a whole
session, the writer's identity is attempted at each spawn rather than fixed
once at startup: today `acquireBoardAuthority` captures it a single time
(`src/Kanban/Repository/Authority.hs:79`) and hands it to the coordinator, so
one transient failure would leave the board ownerless for its life.

**Rationale:** a reader with no snapshot cannot reclaim anything — every
reclaim pass begins by taking one (`reclaimGhGroup`, `Guard.hs:555`) — so an
ownerless entry it wrote could only be read by *another* process, which under
D-2 classifies by liveness and has no liveness to test. Recording it buys
nothing any reader can use, and exempting the dashboard would leave one
writer producing exactly the entries the rule cannot classify. One rule for
every writer is also what lets §15 say the rule once.

**Consequences:** §15's sentence "a board whose snapshot failed still holds
the repository and still records every `gh` it starts" is rewritten in GHR-2:
the board still holds the repository, and records each `gh` whose spawn it
could identify itself for. The owner moves from a field settled at authority
acquisition to one resolved at spawn time; `authorityOwner` may stay as the
message's name for the board but no longer decides what is written. A
snapshot that fails persistently leaves that board's `gh` groups unrecorded
for as long as it fails, which is the same exposure the board has today for
reclaim.

**Signed off:** by the user, 2026-09-07, who delegated the choice to the
agent's recommendation.

### D-6. Every reader process holds one record lock for its life

The mission runner's `kanban --mission` process and the repository's
issue-review host each construct one `GhRecordLock` when the process starts,
and pass it to every read they take: the runner's board reads and target
observations, and the host's precondition reread for each child it adopts. The
persistent worker, which rereads once per process, takes its lock the same way.
`liveMissionDriver` and `preconditionStillHolds` take the lock from their
caller instead of minting one per call.

**Rationale:** the lock carries the in-memory held-back refusal
(`ghRecordHeldBack`), which §15 says "is the repository's for the rest of the
process". A lock minted per call forgets it at the next read, which then
spawns past a possibly-live group nothing durable accounts for. The
issue-review host is one detached process per repository serving many children
(`Kanban.Worker.IssueHost`'s module header), so a lock per child would drop it
the same way. The dashboard already complies: `newBoardRefreshCoordinator`
builds one lock for the coordinator's life. Rejected: one lock per turn, as
GHR-3 first read.

**Consequences:** GHR-3 reads "for its process life" for both readers. The
lock carries no identity — since #721, `registerSpawnedGh` resolves the writer
at each spawn — so GHR-3's `ProcessIdentity` item leaves the slice as already
delivered.

**Signed off:** by the user, 2026-09-28.

## Open questions

### Q-1. Which direction: restore the boundary, extend the authority, or separate the records?

Resolved by D-2. P-A was the smallest change and abandoned recovery for
non-dashboard readers; P-C was P-B with files instead of a lock. The plan is
written for P-B.

### Q-2. Under P-B, what is an entry whose writer identity is absent?

Resolved by D-3. The options were to treat it as abandoned, to treat it as
live until its pgid is unoccupied, or to refuse the write; the third was
chosen.

### Q-3. Does this arc land before #597 RUN-1, or does RUN-1 carry a stated dependency on it?

Resolved by D-4. This arc lands first. (Overtaken; see D-4.)

### Q-4. Does D-3 cover the dashboard, or only the readers that hold no lease?

Resolved by D-5. The readings were uniform (the dashboard falls back to the
in-memory guard too) and dashboard-exempt (the lease holder keeps writing
ownerless entries the liveness rule cannot classify); the uniform reading was
chosen, with identity taken per spawn so a transient failure costs one
spawn's record rather than a session's.

## Verification strategy

- **Two processes, not two threads.** A POSIX lock and a process identity are
  both process-scoped, so a fixture built from threads proves the opposite of
  what it claims. `test/Spec/Support/LeaseProbes.hs` already re-runs the test
  binary as gated child processes with file-carried answers; GHR-1's
  lost-update test and GHR-3's three-reader test take that shape.
- **A fake `gh` that holds.** The audit's probe used a fake `gh` on a
  temporary `PATH` that touches a marker file and sleeps; the parent waits for
  the marker and then starts the second reader. That is the rendezvous every
  concurrency assertion here needs, and the suite's fake-executable
  conventions (`docs/design.md` §18) already provide it.
- **Every reclaim message stays spelled.** `test/Spec/GitHub/BoardRefresh.hs`
  pins "a gh left by a previous Kanban board" and "a gh this board started";
  GHR-2 changes those spellings deliberately and re-pins them.
- **The predecessor arc's harness keeps passing.** `test/Spec/Repository/Lease.hs`
  and the D-8 migration tests are the regression net for the lease and the
  record path, neither of which this arc moves.
- **`docs/design.md` is `pr-atomic`.** The §15 amendment lands in the same pull
  request as the classification change it describes.

## Delivery plan

Written for P-B (D-2).

### GHR-1. Serialize the durable record's read-modify-write across processes

> Filed as [#720]. Three points were settled during processing and are
> recorded here as issue scope rather than as new decisions. The lock is
> carried by a new persistent, never-renamed lock file derived from
> `ghGroupPath`, because `writeGhGroupRecord` replaces the record by
> `renameFile` and `repositoryLeasePath` is already `<key>.lock`. `#720`
> also covers `reclaimRecordedGhGroups`' read at `Guard.hs:471`, which
> straddles the lock boundary today, and `migrateGhGroupRecord`, whose
> safety argument is the lease premise D-2 retires. It amends only
> `docs/design.md` §15's lost-update sentence and §16's durable-state
> inventory; §15's `--mission` clause and its first-sight text remain
> GHR-2's.

- **Outcome:** two processes rewriting one repository's record concurrently
  lose no entry, and a two-process test proves it.
- **Scope:** a file-scoped lock around every read-modify-write of the record
  in `Kanban.GitHub.Guard` and `Kanban.Cache`, held for the duration of the
  rewrite and released with it; the `MVar` stays as the in-process
  serializer. A two-process lost-update test in the `LeaseProbes` shape.
- **Phase:** 1
- **Depends on:** `none`
- **Ordering:** `can land first`
- **Relevant decisions:** D-1, D-2
- **Acceptance signals:** the lost-update probe fails on `master` and passes
  after; every existing Guard, BoardRefresh, and Lease test is unchanged; the
  lease descriptor is not the lock descriptor, so taking the record lock never
  releases a held lease.
- **Out of scope:** any change to what an entry means or who reclaims it.
- **Open questions:** `None`

### GHR-2. Classify a recorded `gh` by its writer's liveness rather than by first sight

> Filed as [#721], depending on [#720]. Three points were settled during
> processing and are recorded here as issue scope rather than as new
> decisions. D-3's in-memory fallback changes what is *written*, never
> whether a spawn is allowed: a failed snapshot over a non-empty record
> still refuses the fetch as today, and the fallback covers the absent or
> empty record alone. The reclaim messages pin four facts, not three —
> the reader's own entry keeps `"a gh this board started"` beside a
> distinct spelling for another live reader's. The `docs/design.md` line
> references above moved since `ddd33d9`: the first-sight premise is at
> `:2879` and the `--mission` clause at `:2850`, and §5's `--mission`
> paragraph says nothing about the record, so it owes no edit. The
> `gh_record_authority_design.md` annotation travels inside [#721]'s pull
> request rather than through its §7 `coordination` lane, since it records
> the decision that change reverses.

- **Outcome:** a reader treats an entry as live while its writer is running
  and as abandoned once it is not, so a healthy concurrent reader's `gh`
  neither blocks nor is signalled, and a dead process's `gh` is reclaimed by
  the next reader of any kind.
- **Scope:** the owner identity becomes required on every entry this release
  writes, and a reader with no identity — the dashboard included — falls back
  to an in-memory guard for that spawn and writes nothing (D-3, D-5), with
  the identity attempted at each spawn rather than fixed at authority
  acquisition; `rememberInherited`/`entryOrigin` are
  replaced by a liveness test against the process snapshot; the reclaim
  messages name a live reader, an abandoned reader, and a legacy ownerless
  entry in three spellings; the §15 paragraphs at lines 2524 and 2549 are
  rewritten to one rule and the Guard comments with them; D-3's rationale in
  the predecessor document is annotated as superseded by this arc's D-2.
- **Phase:** 2
- **Depends on:** GHR-1
- **Ordering:** `critical path`
- **Relevant decisions:** D-1, D-2, D-3, D-5
- **Acceptance signals:** the audit's reproduction completes both reads; an
  entry whose writer is dead is reclaimed with the existing escalation; a
  reader whose snapshot fails spawns under the in-memory guard and the record
  gains no ownerless entry; the re-pinned message tests pass; `Spec.Design`
  witnesses and the §7 key test are untouched.
- **Out of scope:** the runner's and worker's own lock lifetimes (GHR-3).
- **Open questions:** `None`

### GHR-3. Give the mission runner and the worker precondition one record authority each, and prove three readers together

- **Outcome:** the mission runner's process and the issue-review host each
  hold one record lock for their process life, so a held-back refusal outlives
  the read that earned it; a three-process test — dashboard-shaped,
  runner-shaped, worker-shaped — reads one repository at once and every read
  completes.
- **Scope:** `liveMissionDriver` and `preconditionStillHolds` take a
  `GhRecordLock` from their caller; the `--mission` entry point, the
  issue-review host, and the persistent worker each construct one per process
  (D-6); the three-reader test in the `RecordWriters`/`LeaseProbes` shape.
- **Phase:** 3
- **Depends on:** GHR-2
- **Ordering:** `critical path`
- **Relevant decisions:** D-1, D-2, D-3, D-6
- **Acceptance signals:** the three-reader probe passes; a refusal held back
  by one runner read turns away that process's next read; a runner killed
  mid-fetch leaves an entry the next dashboard refresh reclaims; the
  `--mission` deadline and precondition tests from #595 are unchanged.
- **Out of scope:** the runner service's supervision of its workers (#597
  RUN-4).
- **Open questions:** `None`

## Source notes

The finding's handoff context, quoted because it names the property the
plan is held to: "Define ownership and synchronization across dashboard,
mission, and worker reads. Retain abandoned-process recovery while
distinguishing healthy concurrent readers. Add a test that exercises those
readers together."
