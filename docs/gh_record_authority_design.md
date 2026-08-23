# Cross-process authority for the durable `gh` group record design

Kanban's durable `gh` process-group record exists so that a `gh` this project
started is never left running, unaccounted, beside a `gh` it is about to start.
Within one dashboard process that promise holds: one repository-scoped
coordinator owns every spawn and every record update. Across two dashboard
processes opened on the same repository it does not hold at all — the record is
a shared file guarded by a lock that lives in one address space.

This arc gives that record a real cross-process authority, and settles what a
second board on the same repository is actually supposed to do.

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Hold one repository to one board and give its `gh` record an owner — [#499]
- [x] GHA-1. Add the repository-scoped lease and its two-process test harness — [#501]
- [ ] GHA-2. Hold the repository at launch, refuse a second board, and give record entries an owner

D-1 through D-7 are signed off and fix this decomposition. No open questions
remain. D-3 was amended after processing found its migration premise false
against the tree, and that amendment carries its own readiness signoff.

## Epic contract

- **Goal:** One repository is worked by one board. A second board on the same
  repository is refused deliberately and in true words, instead of being refused
  by accident with a message about something else; and a board that inherits a
  dead board's record can tell that is what it is.
- **Done when:** a second `kanban` on a held repository exits non-zero naming the
  repository and the holder, rather than racing; no durable record entry can be
  lost to an interleaved write; a board that crashed holding the authority never
  wedges the next one; a board inheriting a dead board's record says so; and
  `design.md` §3 and §15 record all of it.
- **Users and operators:** anyone who leaves a Kanban board open in two
  terminals on the same repository; and every future board, because a lost
  record entry is a `gh` no later run knows to reclaim.
- **Arc label:** `board-authority`, created during processing — "One-board-per-repository
  lease and cross-process authority over the durable gh process-group record".

## Current state and evidence

### The record and its lock

- `src/Kanban/GitHub/Guard.hs:62-90` — `GhRecordLock` is an `MVar ()` beside an
  `IORef (Maybe Text)`. `newGhRecordLock` mints a fresh one per call. Both live
  only in the calling process's address space, though the surrounding comment
  describes the record as repository-scoped and durable.
- `src/Kanban/UI/Refresh.hs:227` — the one production construction site, inside
  `newBoardRefreshCoordinator`. Every dashboard therefore gets its own lock.
  (`src/Kanban/UI/Refresh.hs:332` is the cleanup suite's seam, not a second
  production coordinator.)
- `src/Kanban/Cache.hs:205-208` — the record path is
  `$XDG_CACHE_HOME/kanban/gh-groups/<owner-name>.json`, keyed by repository
  identity and nothing else. Two processes on one repository resolve the same
  file.
- `src/Kanban/Cache.hs:359-376` — `writeCacheFile` replaces the file by atomic
  rename. The *file* is never torn; the *transaction* that composed it is not
  protected at all.
- `src/Kanban/GitHub/Guard.hs:299-309` — `recordGhGroup` and `dropGhGroup` each
  read the whole entry list and write a whole new list derived from it, under
  the process-local mutex.
- No cross-process locking primitive exists anywhere in the Haskell tree:
  `flock`, `setLock`, `LockFile`, and `O_EXCL` appear in neither `src/` nor
  `app/`. `Worker/Journal.hs`'s `openFd` is an append handle. Every lock this
  project owns today is on the Python side.
- `unix >= 2.8 && < 2.9` is already a dependency of both the library and the
  test suite (`kanban.cabal:199,299`), so POSIX advisory record locks need no
  new package.

### What the contract currently promises

`docs/design.md:1983-1990`:

> One repository-scoped coordinator owns every `gh` a board refresh starts and
> the durable `gh` group record for that repository … no interleaving of the
> record's read-modify-write updates can lose an entry. Scope is one
> coordinator per repository within one dashboard process. Nothing here
> schedules across processes; the durable record and the restart-time reclaim
> refusal remain what covers that.

The last sentence is the claim this arc falsifies. The durable record does not
cover the cross-process case, because updating it is not an atomic operation.

(The originating finding cites `docs/design.md:1953-1962`; the passage has since
moved to `1983-1990`. The wording is unchanged.)

### Hazard A — the lost update (reproduced)

Two processes read the same entry list and both write a whole list derived from
their own stale read. The later rename discards the earlier writer's entry
wholesale. Reproduced under an isolated `XDG_CACHE_HOME`: both reads returned
`GhGroupRecordAbsent`, writing group 100 from the first view and group 200 from
the second both returned `Right ()`, and the final load contained group 200
alone.

The lost entry is exactly the possibly-live `gh` the record exists to make a
later fetch reclaim or refuse.

### Hazard B — a board reclaims another live board's group

**This hazard is not in the originating finding, and it is the one that decides
the arc's shape.**

`reclaimRecordedGhGroups` (`src/Kanban/GitHub/Guard.hs:327-366`) reclaims *every*
recorded entry. An entry carries a pgid, a member list, and a censused flag
(`src/Kanban/Process.hs:67-82`) — and nothing that says which process owns it or
whether that process is still alive. So a second board cannot tell "an abandoned
group from an earlier run" from "a group another board is using right now".

What happens today, traced:

1. Board A spawns `gh` and registers it uncensused —
   `OwnedProcessGroup groupPid [] False` (`Guard.hs:290`). The registration
   happens while A's child is still parked on the spawn barrier, so within A
   there is no instant where a running `gh` is unrecorded (`Run.hs:88-93`).
2. Board B starts a refresh. `reclaimRecordedGhGroups` reads the record and sees
   A's live entry, described as "an earlier GitHub refresh".
3. `reclaimGhGroup` censuses the group, finds A's live `gh` occupying it, and
   asks `provablyOurs` — which is `False` because the entry is uncensused
   (`Guard.hs:436-439`).
4. B returns `Left`, and its whole refresh is refused with:
   *"a gh from an earlier GitHub refresh (pgid N) still accounts for 1 running
   process(es) that cannot be identified as this repository's…"*

So a second board is **already** effectively refused today — accidentally, by a
predicate meant for a different question, and with a message that is false about
what it found. `censused = True` is written only from failed-cleanup paths
(`Group.hs:132,136`, `Run.hs:166`), so a live-and-healthy group is not currently
at risk of being killed by another board; the safety here rests on that
coincidence rather than on anything the design says.

### The unusable-record refusal never clears the record

`loadGhGroupRecord` returns `GhGroupRecordUnusable` for four distinct causes —
an `IOException`, a JSON decode failure, an unsupported schema version, and a
repository-identity mismatch (`src/Kanban/Cache.hs:219-223`) — all carried in
one constructor as free text. `Cache.hs:135` states the intent: such a record is
"never silently treated as 'nothing recorded'".

The reclaim honors that by refusing —
`GhGroupRecordUnusable message -> refuse message`
(`src/Kanban/GitHub/Guard.hs:351`) — and `refuse` (`:374-375`) only records a
cleanup failure and returns `Left`. It never removes the file.
`removeGhGroupRecord` has exactly two call sites, `dropGhGroup`'s empty-list
branch (`:308`) and the path taken once every entry is reclaimed (`:366`), and
neither is reachable from the unusable branch, because the refusal precedes any
reclaim and any spawn. `recordedGhGroups` (`:314-319`) does map an unusable load
to `[]`, but no writer ever runs. No test anywhere pins this behavior.

So an unusable record refuses every board refresh, in that process and in every
later one, until a human deletes
`$XDG_CACHE_HOME/kanban/gh-groups/<owner-name>.json`. For a genuinely corrupt
record that is correct and deliberate. What it means for a *deliberate* schema
bump is that the cost is not one refusal per installation but a permanent
refusal — while `src/Kanban/UI/Reconcile.hs:309` goes on telling the user "the
next refresh re-checks it and will proceed once it is gone", which nothing would
ever make true.

That matters because a record file exists precisely when an earlier refresh
could not confirm its `gh` dead — a state that self-heals today, since the
record loads, the reclaim censuses the group, and `:366` clears it. A bump would
convert a self-healing state into a wedged one. D-3 is amended accordingly.

### Deduplication

Five open issues read in full. None covers this. `#132` (verified `gh`
termination) and `#301` (the one-process repository coordinator) are the
originating work and are closed. `#354` (Epic: run one Kanban session over
several repositories) is the mirror image — one process, several repositories —
and touches `Refresh.hs:227` without covering this; its per-repository
coordinators must each take a per-repository lease rather than one global one.
No findings report in `docs/` mentions `gh-groups`, `GhRecordLock`, or a
process-group record.

`docs/design.md:56-73` §3 non-goals excludes multi-repository aggregation in one
board; it says nothing about several boards on one repository, so that
configuration is currently neither supported nor excluded. D-1 closes that gap by
adding the missing non-goal.

Both arcs therefore amend §3, and the two edits must not undo each other.
`#354`'s MRB-3 *narrows* the existing "Multi-repository aggregation in one
running board" non-goal — an overturn approved on 2026-08-10 — while this arc
*adds* one. The wording that survives both is about **repository → board**
uniqueness ("a repository is worked by one board at a time"), never about one
board per process, which is precisely what MRB-3 is making false. Whichever
lands second reconciles against the other, and both owe a witness declaration.

## Desired experience

A repository is worked by one board at a time, and Kanban says so plainly.

- A board opened on a repository no other board holds behaves exactly as it does
  today. Nothing about the single-board experience changes — this arc is
  invisible unless a second board exists.
- A second `kanban` on a repository another board already holds never draws a
  board at all. It prints a diagnostic naming the repository and exits non-zero
  (D-4). It does not race, does not silently degrade, and does not report the
  refusal as something else.
- A board whose predecessor was killed proceeds without a human. The authority is
  released by the kernel when its holder dies, and the leftover record entries
  are recognizable as a dead board's rather than guessed at.
- The two refusals Kanban already renders keep their current meanings and their
  current wording. "Could not be confirmed stopped" is about an unreclaimed
  `gh`; the startup refusal is about another board holding the repository.
  Merging them would make both useless.

## Scope

### In scope

- A cross-process authority for the durable record, keyed by repository.
- A new `design.md` §3 non-goal stating that one repository is worked by one
  board (D-1), and the retirement of §15's "Nothing here schedules across
  processes".
- A startup refusal — diagnostic plus non-zero exit — distinct in wording and in
  meaning from the two refusals that already exist (D-2 as amended, D-4).
  §17 itself is untouched (D-2 as amended).
- Optional owner identity on durable record entries, with no schema version
  change and no migration (D-3 as amended).
- A test harness able to run two independent processes against one isolated
  cache root and pause both at a shared state.

### Out of scope

- Merging two boards' views, or any multi-repository aggregation (§3 non-goal;
  `#354` owns the adjacent arc).
- Changing how a `gh` group is censused, killed, or proven owned. This arc
  changes *who may reclaim which entry and when*, not the reclaim mechanism.
- Automatic background polling of any kind (§3 non-goal).
- Cross-*machine* coordination over a shared home directory. Named here so it is
  explicitly not promised.
- The `gh` calls the solve, review, and pull-request workers make. Those run
  outside the durable record entirely — the record and guard are reached only
  from the board-refresh path (`src/Kanban/GitHub/Coordinator.hs:674,730`) — and
  the authority must not extend to them or an agent action would contend with
  the board that launched it.
- `kanban --usage` and `kanban --ping`. Neither touches the record or spawns
  `gh`, so neither takes the authority. A second terminal running `--usage`
  against a held repository keeps working.

## Design

### The authority

A repository-keyed POSIX advisory record lock — `fcntl`, via
`System.Posix.IO.setLock` in the already-present `unix` package — held on a file
beside the record under the XDG cache root. `setLock` rather than
`waitToSetLock`: D-2 refuses immediately, so the non-blocking form is the whole
acquisition.

The kernel releases an `fcntl` lock when its holder dies, however it dies. That
is the entire staleness rule, and it is why this arc proposes no PID file, no
heartbeat, and no reaping of another board's lock — a lock file carrying a PID
would owe a staleness rule of its own, and that rule is where this class of
change historically bleeds review rounds.

Keyed by repository identity, exactly as the record path already is
(`src/Kanban/Cache.hs:205-208`), so two boards on two repositories never contend.
That keying is also what keeps `#354` coherent: one process holding several
repository coordinators takes one lease per repository, not a global one.

`fcntl` record locks are POSIX and behave the same on macOS and Linux, so this
mechanism carries no new obligation for `#290`. Worth stating because the
alternatives do: `flock(2)` semantics differ across platforms in ways a
portability arc would have to account for, and a PID-file scheme would need a
liveness probe on each.

### What the authority governs

Only the durable record and the `gh` spawns the board refresh makes under it.
Not the solve, review, or pull-request workers' own `gh` calls, which never
touch the record; not `--usage`; not `--ping`. Stated as a boundary in Scope
above because a lease that crept wider would make an agent action contend with
the board that started it.

### Entry attribution

`OwnedProcessGroup` (`src/Kanban/Process.hs:67-82`) gains the identity of the
board that owns the entry — PID plus start time, the same shape
`Kanban.Process` already uses to survive PID reuse — as an **optional** field.
`ghGroupRecordSchemaVersion` stays 1.

The change is additive: every existing entry is otherwise valid and fully
readable by the new binary, and the only thing that could make it unreadable is
*requiring* the new key. Requiredness, not the version number, is what would
break an existing record — a required field fails `.:` on a missing key with or
without a bump, and lands in the never-clearing refusal above. An optional field
decoded with `.:?` reads a pre-change record unchanged, with the owner absent,
which is exactly what it is. `WorkerState` already carries a
`Maybe ProcessIdentity` on a durable record for this reason, behind a
hand-written decoder using `.:?` and `.!=`
(`src/Kanban/Worker/Types.hs:185,197-210`); `OwnedProcessGroup` uses the derived
instance today (`Process.hs:84-85`), so it gains one of its own.

What attribution buys under D-1 is narrower than it would have been under a
coordinating design, and worth stating exactly: with one board per repository,
no board should ever meet another *live* board's entry. Attribution is therefore
not a live-group guard here — it is how a board recognizes a *dead* board's
leftovers as such, and how the reclaim's message can be true about what it found
instead of calling it "an earlier GitHub refresh". Because that narrower value
has exactly one consumer, D-5 ships it in the same slice as the lease rather
than on its own.

It is also not the only signal available for that message. Under D-4 a board
holds the lease for its whole life, so any entry already present when a process
performs its first reclaim was necessarily written by a process that is now
dead, while entries appearing later in the same process are that process's own.
That distinction needs no stored owner at all, and it is what lets the corrected
message be true of a pre-change record too. The owner adds *which* board and
when it started, rather than supplying the distinction itself.

### The refusal

A startup diagnostic on stderr and a non-zero exit (D-4), worded about the
repository being held rather than about a `gh` that could not be stopped. The
two existing refusals (`src/Kanban/UI/Reconcile.hs:305`,
`src/Kanban/UI/Events.hs:550`) keep their current wording and meaning; this one
is not a variant of either, and under D-2 as amended it does not join them in
§17 at all.

It names the holding process's PID (D-7). `fcntl`'s `getLock` returns the
holder's PID at refusal time, so the identification is free and cannot go stale
the way a PID file's would.

## Decisions

### D-1. One repository is worked by one board; a second is refused

`design.md` §3 gains a non-goal saying so. Two boards on one repository is not a
configuration Kanban coordinates; it is one it declines.

**Rationale:** the alternative is a genuine concurrency design — two boards
fetching, two live `gh` groups, a record that must attribute and protect both —
for a configuration nobody has asked for. Declining it is cheaper to build, far
cheaper to prove, and honest about what Kanban does.

**Consequences:** §3 gains a non-goal. The arc becomes a refusal mechanism
rather than a coordination mechanism, which is why the epic call from
`/process-report` was revisited and reaffirmed (D-6). Anyone who does want two views of one
repository has no supported path, and that is now a stated position rather than
an accident.

**Signed off:** by the user, this session.

### D-2. The refused board is refused immediately, as a startup diagnostic

*Amended after D-4; see the history note below.*

No waiting, no bounded retry. The refusal is a diagnostic on stderr and a
non-zero exit status. **§17 is not touched by this arc.**

**Rationale:** waiting means acquiring off the Brick event thread and a whole
async path to keep the UI live, to spare the user a few seconds in a
configuration D-1 has just declared unsupported. Immediate refusal also makes
`setLock` sufficient and `waitToSetLock` unnecessary.

**Consequences:** the acquisition is non-blocking, so no part of this lands on
the event thread. `design.md`'s §17 keeps exactly its current two refusals, and
GHA-2 amends two design sections rather than three.

**Signed off:** by the user, this session, in both its original and its amended
form.

> **History.** D-2 was first signed off as *"refused immediately, with a new §17
> notice"*. D-4 then placed the refusal before the board launches, and §17 is
> the running board's error surface — a process that exits at startup renders no
> notice, so the two halves could not both stand. The user was asked to choose
> between amending D-2 and reopening D-4, and amended D-2. The "refused
> immediately, no waiting" half was never in question and is unchanged.

### D-3. Record entries carry their owner's identity, as an optional field

*Amended after the unusable-record finding; see the history note below.*

`OwnedProcessGroup` gains an owner `ProcessIdentity` as an **optional** field,
decoded with `.:?`. `ghGroupRecordSchemaVersion` stays 1. Records written before
the change load unchanged, with the owner absent.

**Rationale:** an entry that says what group it is but not whose forces every
reader to guess, and the change that fixes that is additive. A required field —
with or without a version bump — makes every existing record unreadable, and the
existing unusable-record path refuses the fetch without ever clearing it, so the
cost is not one refusal per installation but a permanent refusal until a human
deletes the file. The "permanent unknown-owner branch that must fail closed
everywhere" the original decision feared does not exist under D-1: `provablyOurs`
keys on the censused flag and on identity matching, never on the owner
(`src/Kanban/GitHub/Guard.hs:437-439`), so an absent owner fails nothing closed.
It changes one message.

**Consequences:** no migration, no invalidation, and no first-upgrade cost at
all. The schema version stays available for a future change that really is
incompatible. `OwnedProcessGroup` gains a hand-written `FromJSON` in place of the
derived one. GHA-2 no longer carries a durable schema change, which retires the
bundling tension D-5 had accepted. Under D-1 the value remains crash recovery
and honest messages rather than live-group protection.

**Signed off:** by the user, this session, in both its original and its amended
form.

> **History.** D-3 was first signed off as *"record entries carry their owner's
> identity, at schema version 2"*, on the stated premise that version-1 records
> "load as unusable exactly once and are cleared by the refusal path that
> already handles that". Processing verified that premise against the tree and
> found it false — the refusal never clears, as *The unusable-record refusal
> never clears the record* records. The user was shown the finding and the three
> directions it opened: repair the premise, have GHA-2 delete the record on a
> signal that today merges four causes, or take the optional field the original
> decision had rejected. The user chose the optional field. That the entry
> carries its owner at all was never in question and is unchanged.

### D-4. The refusal happens at launch, and the lease is held for the process's life

`kanban` takes the repository's lease during startup. If another process holds
it, `kanban` prints a diagnostic and exits non-zero without drawing a board. The
lease is released when the process ends, by the kernel if not before.

**Rationale:** it is the strongest reading of D-1 and the cheapest to prove —
there is no second board, so there is no second board's behavior to specify. It
also removes the read-only board state that the degraded alternative would have
required every action path to respect.

**Consequences, and several of them matter:**

- **The durable record becomes single-writer by construction.** Only one process
  can reach it at a time, and within that process the coordinator already
  serializes every mutation. So Hazard A — the reproduced lost update — is
  closed by the lease itself, and this arc needs no per-mutation cross-process
  locking around `recordGhGroup` or `dropGhGroup`. That is a real simplification
  of what the originating finding asked for, and it is worth stating plainly:
  the finding's *"the cross-process authority must cover ownership acquisition
  as well as read-modify-write"* is satisfied by covering acquisition alone,
  because acquisition now subsumes the rest.
- **Two checkouts of one repository contend.** The record is keyed by
  `owner/name` and nothing else (`Cache.hs:225`, `repositoryIdentity`), so a
  board in a worktree and a board in the primary checkout resolve the same
  record and the same lease. One of them is refused. This follows necessarily:
  keying the lease by checkout path instead would let both proceed against one
  shared record, which is precisely the race being closed.
- **Different cache roots do not contend, and need not.** Two boards under
  different `XDG_CACHE_HOME` values resolve different records *and* different
  lease files. Neither can see or reclaim the other's groups, so there is
  nothing to serialize. This is also what keeps the existing isolated-cache-root
  test conventions working unchanged.
- **`--usage`, `--ping`, and the agent workers are unaffected**, since none of
  them touches the record.
- D-2's §17 notice lost its renderer, and D-2 was amended accordingly.

**Signed off:** by the user, this session.

### D-5. Attribution folds into GHA-2 rather than taking its own slice

The owner identity and the corrected reclaim message land in the same pull
request as the lease acquisition and the refusal.

**Rationale:** the user's call. Under D-4 the reclaim only ever runs against a
dead board's record, so attribution has exactly one consumer and shipping it
apart from that consumer would land a field nothing yet reads.

**Consequences:** the arc has two slices. Under D-3 as amended there is no
durable schema change to bundle, so `CLAUDE.md`'s *"Don't bundle unrelated
changes into one pull request"* no longer pushes against this decision the way
it did when D-5 was taken: the tension D-5 accepted deliberately has been
retired rather than merely tolerated, and the schema half is no longer a split
point because there is no schema half.

**Signed off:** by the user, this session. The amendment to D-3 narrowed its
consequences; the decision itself is unchanged.

### D-6. The arc remains an epic

`/process-design-doc` will create the umbrella epic first and then one child per
invocation.

**Rationale:** even at two slices, the lease primitive with its two-process test
harness and the behavior change that consumes it are separately reviewable, and
the harness is a prerequisite that must land and be trusted before the behavior
built on it can be judged.

**Consequences:** the `EPIC` entry in the processing ledger stands. The
`/process-report` disposition of PRR-1 as `Epic` is unchanged, and PRR-1's
`[#N]` marker will name the epic created from this document.

**Signed off:** by the user, this session.

### D-7. The refusal names the repository and the holding process's PID

The startup diagnostic reads, in substance:

```text
kanban: another Kanban board is already open on coghex/kanban (pid 4812).
Close it before opening another.
```

**Rationale:** "which terminal is it?" is the user's actual next question, and
`fcntl`'s `getLock` answers it for free — the holder's PID comes back from the
kernel as part of discovering that the lock is held.

**Consequences:** GHA-2 reads `getLock` on the refusal path as well as taking
`setLock` on the acquisition path. The PID is read live at refusal time, so it
cannot go stale the way a PID recorded in a file could; there is no window in
which the printed PID names a process that has already released the lease,
because the lease being held is what produced the PID.

**Signed off:** by the user, this session.

## Open questions

### Q-1. Is one repository open in two boards a configuration Kanban supports?

Resolved by D-1 — explicitly unsupported; §3 gains a non-goal.

### Q-2. What does the contended board do, and what does it show?

Resolved by D-2 — refused immediately, with a third §17 notice about the real
cause.

### Q-3. Should a record entry name the board that owns it?

Resolved by D-3 as amended — yes, as an optional field, with
`ghGroupRecordSchemaVersion` left at 1 and no migration.

### Q-4. Where does the refusal land?

Resolved by D-4 — at launch, exiting non-zero. The lease is held for the whole
process lifetime.

### Q-5. Under D-1, is entry attribution still worth its own slice?

Resolved by D-5 — folded into GHA-2. The arc has two slices.

### Q-6. Is this still an epic?

Resolved by D-6 — yes.

### Q-7. Does D-2's §17 notice survive D-4?

Resolved by the amendment to D-2 — it does not. The refusal is a startup
diagnostic, and §17 is untouched by this arc.

### Q-8. Does the refusal name the process holding the repository?

Resolved by D-7 — yes, the repository and the holder's PID, read live from
`getLock`.

---

**No open questions remain.** D-1 through D-7 settle the behavior, the scope,
the mechanism, and the decomposition.

## Verification strategy

- A barrier-controlled two-process test is the arc's central new capability. The
  Haskell suite today spawns fake *external* executables (`fake gh`, `codex`,
  `claude`) and builds temporary Git repositories, but never runs Kanban's own
  record code in two OS processes coordinated at a shared pause point. That
  harness is a prerequisite for proving anything here, which is why GHA-1
  carries it.
- Each proof runs against an isolated `XDG_CACHE_HOME`, as the original
  reproduction did.
- Cases the arc must cover: two boards contending for one repository, exactly
  one proceeding; a board crashing while holding the authority, and the next one
  proceeding without human action; a board crashing with a live `gh` registered,
  so the next one both takes the lease and reclaims; two boards on *different*
  repositories proceeding concurrently (the authority must not globally
  serialize); a record written before the owner field loading unchanged with its
  owner absent, and still drawing a true reclaim message; and the single-board
  case behaving identically to today, which is the arc's loudest invariant.
- The refusal's wording is itself a test subject: the startup diagnostic must be
  distinguishable from `Reconcile.hs:305` and `Events.hs:550`, which mean
  something else, and must carry the holder's PID (D-7).
- The exit status is part of the contract, not an afterthought — a second
  `kanban` exits non-zero, which is what makes the refusal scriptable.
- `design.md` is `pr-atomic`, so the §3 and §15 amendments land in the same pull
  request as the behavior they describe, not as a documentation slice. (This
  bullet said "§15 or §17" before D-2 was amended; §17 is untouched and §3 is
  what gains an entry.)
- §3's entries are machine-checked, which the §3 amendment has to satisfy in the
  same pull request: `test/Spec/Design/Witnesses.hs` asserts that declarations
  and document entries match in *both* directions, so the new non-goal lands with
  a witness declaration — or an explicit `Unwitnessed` reason — beside it. A
  witness may not read a path `tools/test_source_distribution.py` excludes, which
  rules out resting it on this document.

## Delivery plan

Two slices, D-5. Every decision this plan depends on is signed off.

### GHA-1. Add the repository-scoped lease and its two-process test harness

- **Outcome:** a repository-keyed `fcntl` lease exists, with a test harness that
  can run two independent processes against one isolated cache root and pause
  both at a shared state. No change to how the record is used yet.
- **Scope:** the lease primitive over `System.Posix.IO.setLock`; acquisition,
  release, and kernel-release-on-death semantics; the two-process barrier
  harness; proof that different repositories never contend.
- **Phase:** 1
- **Depends on:** `none`
- **Ordering:** `can land first`
- **Relevant decisions:** `D-2`, `D-4`
- **Acceptance signals:** two processes contend for one repository's lease and
  exactly one holds it; a `SIGKILL`ed holder's lease is available to the next
  process with no human action and no staleness rule of our own; two
  repositories never contend; two isolated cache roots never contend.
- **Out of scope:** any change to `Guard.hs`'s record behavior; the refusal's
  user-facing wording; anything `kanban` does with the lease.
- **Open questions:** `None`

### GHA-2. Hold the repository at launch, refuse a second board, and give record entries an owner

- **Outcome:** a second `kanban` on a held repository prints a diagnostic and
  exits non-zero instead of racing; the durable record becomes single-writer, so
  the reproduced lost update can no longer be staged; and a board that inherits
  a dead board's record recognizes it as such rather than calling it "an earlier
  GitHub refresh".
- **Scope:** lease acquisition during startup and release at exit; the refusal
  diagnostic and exit status; an optional owner `ProcessIdentity` on
  `OwnedProcessGroup`, behind the hand-written decoder that keeps pre-change
  records readable (`ghGroupRecordSchemaVersion` stays 1, D-3 as amended); the
  reclaim's corrected message; and the `design.md` amendments — §3's new
  non-goal with its witness declaration, and §15's retired cross-process
  sentence. §17 is untouched (D-2 as amended). `design.md` is `pr-atomic`, so all
  of that lands here rather than separately.
- **Phase:** 2
- **Depends on:** `GHA-1`
- **Ordering:** `critical path`
- **Relevant decisions:** `D-1`, `D-2`, `D-3`, `D-4`, `D-5`
- **Acceptance signals:** a second `kanban` on a held repository exits non-zero
  with a diagnostic naming the repository and the holder's PID; the original
  two-process reproduction can no longer be staged; a record written before the
  owner field loads unchanged with its owner absent, and is still described
  truthfully; a dead board's entries are reclaimed and described as a dead
  board's; and a single board behaves identically to today, which is the arc's
  loudest invariant.
- **Out of scope:** the reclaim mechanism itself — this changes what the reclaim
  knows and says, never how it censuses or kills; the agent workers' own `gh`
  calls; `--usage` and `--ping`.
- **Open questions:** `None`
- **Note:** this slice used to carry a durable schema change beside a behavior
  change, and named that half as its split point if the review burden proved too
  high. D-3 as amended removes the schema change, so neither the bundling
  tension nor that split point applies any more. What remains is the lease, the
  refusal, the optional owner field, the corrected message, and the `design.md`
  amendments.

## Source notes

From `docs/project_review_314-299.md`, finding PRR-1's scope constraint:

> Locking only the write is insufficient because the absent-check-to-spawn
> window would remain; the cross-process authority must cover ownership
> acquisition as well as read-modify-write.

Its remaining uncertainty, which Q-1 restated and D-1 settled:

> Whether the intended product rule is a shared repository lease or an explicit
> one-dashboard-per-repository refusal is a design choice. The current unguarded
> check/write behavior is not safe under either interpretation.
