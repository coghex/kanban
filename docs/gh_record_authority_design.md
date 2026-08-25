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
- [x] GHA-2. Canonicalize and migrate the durable record, refuse a second board, and attribute inherited groups — [no-issue]: delivered by PR #518 as the remaining scope of epic #499

D-1 through D-8 settle the behavior and scope. D-9 preserves the proposed split
that followed D-8 and reconciles it with the delivered result: no separate
GHA-2a or GHA-2b tracker artifact was created, and merged PR `#518` delivered
both halves together as GHA-2 before closing epic `#499`. No open questions
remain. This is a processing-ledger reconciliation, not a material design
change, so the ready state stands.

## Epic contract

- **Goal:** One repository is worked by one board. A second board on the same
  repository is refused deliberately and in true words, instead of being refused
  by accident with a message about something else; and a board that inherits a
  dead board's record can tell that is what it is.
- **Done when:** a second `kanban` on a held repository exits non-zero naming the
  repository and the holder, rather than racing; one repository resolves one
  record and one lease however its owner and name are spelled, and no two
  repositories resolve either; no durable record entry is lost to an interleaved
  write or stranded by the move to the canonical path; a board that crashed
  holding the authority never wedges the next one; a board inheriting a dead
  board's record says so; and `design.md` §3, §15, and §16 record all of it.
- **Users and operators:** anyone who leaves a Kanban board open in two
  terminals on the same repository; and every future board, because a lost
  record entry is a `gh` no later run knows to reclaim.
- **Arc label:** `board-authority`, created during processing of the `EPIC` entry
  and carried by `#499` and `#501` — "One-board-per-repository lease and
  cross-process authority over the durable gh process-group record".

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
- `src/Kanban/Cache.hs:232-235` — the record path is
  `$XDG_CACHE_HOME/kanban/gh-groups/<safeKey(owner/name)>.json`, derived from
  repository identity and nothing else. Two processes on one repository, spelled
  the same way, resolve the same file — and, as the next subsection shows,
  spelled differently they do not.
- `src/Kanban/Cache.hs:552-569` — `writeCacheFile` replaces the file by atomic
  rename. The *file* is never torn; the *transaction* that composed it is not
  protected at all.
- `src/Kanban/GitHub/Guard.hs:299-309` — `recordGhGroup` and `dropGhGroup` each
  read the whole entry list and write a whole new list derived from it, under
  the process-local mutex.
- No cross-process locking primitive existed anywhere in the Haskell tree when
  this arc was written: `flock`, `setLock`, `LockFile`, and `O_EXCL` appeared in
  neither `src/` nor `app/`, and `Worker/Journal.hs`'s `openFd` is an append
  handle. GHA-1 has since landed the first one, in
  `src/Kanban/Repository/Lease.hs`; every other lock this project owns is still
  on the Python side.
- `unix >= 2.8 && < 2.9` is already a dependency of both the library and the
  test suite (`kanban.cabal:201,305`), so POSIX advisory record locks need no
  new package.

### The record's path is neither canonical nor injective

`safeKey` (`src/Kanban/Cache.hs:580-585`) maps `/`, `\`, and `:` to `-` and
changes nothing else. Two consequences follow, and this document originally
assumed neither:

- **One repository can resolve two records.** GitHub's identity is
  case-insensitive, so `Coghex/Kanban` and `coghex/kanban` name one repository —
  and resolve `Coghex-Kanban.json` and `coghex-kanban.json`. A board would not
  see its predecessor's entries at all.
- **Two repositories can resolve one record.** `coghex-kan/ban` and
  `coghex/kan-ban` both resolve `coghex-kan-ban.json`. The envelope's embedded
  `repositoryKey` is compared exactly (`src/Kanban/Cache.hs:270`), so the second
  repository's load is rejected as unusable rather than the collision being
  repaired — and by *The unusable-record refusal never clears the record* below,
  that rejection is permanent.

The lease GHA-1 landed inherits both, because it was keyed the same way:
`repositoryLeasePath` is
`$XDG_CACHE_HOME/kanban/leases/<safeKey(owner/name)>.lock`
(`src/Kanban/Cache.hs:252-255`). A mixed-case second board would therefore not
contend for it, which would make D-1's promise false in exactly the case a user
is most likely to produce — one clone spelled from a URL, another from memory.

`docs/design.md:2905` states the rule that produced this: "the identity used for
GitHub queries, cache paths, and display keeps the case it resolved with." That
sentence stays true of `repositoryCachePath` (`src/Kanban/Cache.hs:206-209`) and
of worker state, and stops being true of the record and the lease. §16 is
therefore a third section this arc amends, which neither this document nor
`#499` had recorded. D-8 settles it.

### What the contract currently promises

`docs/design.md:2030-2039`:

> One repository-scoped coordinator owns every `gh` a board refresh starts and
> the durable `gh` group record for that repository … no interleaving of the
> record's read-modify-write updates can lose an entry. Scope is one
> coordinator per repository within one dashboard process. Nothing here
> schedules across processes; the durable record and the restart-time reclaim
> refusal remain what covers that.

The last sentence is the claim this arc falsifies. The durable record does not
cover the cross-process case, because updating it is not an atomic operation.

(The originating finding cites `docs/design.md:1953-1962`; the passage has since
moved twice, to `1983-1990` and now to `2030-2039`. The wording is unchanged.)

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
(`src/Kanban/Process.hs:67-85`) — and nothing that says which process owns it or
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
   (`Guard.hs:437-439`).
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
repository-identity mismatch (`src/Kanban/Cache.hs:264-270`) — all carried in
one constructor as free text. `Cache.hs:146` states the intent: such a record is
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
later one, until a human deletes that repository's file under
`$XDG_CACHE_HOME/kanban/gh-groups/`. For a genuinely corrupt record that is
correct and deliberate. What it means for a *deliberate* schema bump is that the
cost is not one refusal per installation but a permanent refusal — while
`src/Kanban/UI/Reconcile.hs:311` goes on telling the user "the next refresh
re-checks it and will proceed once it is gone", which nothing would ever make
true.

It is also what makes D-8's undecodable-legacy-candidate rule fail closed rather
than fail destructively: a board that guessed wrong and deleted such a file
would be deleting the only record of a possibly-live `gh`, and a board that
guessed wrong and ignored it would spawn straight past one.

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

The two arcs also meet in §16, which neither had noticed. `#354`'s D-10 keys its
board map by the ASCII-lowercased identity while resting on the same
`docs/design.md:2905` sentence D-8 narrows — it cites `repositoryCachePath`
keying on the identity verbatim as the reason a case-sensitive key was rejected.
Narrowing that sentence to the caches which do still keep their resolved case
strengthens D-10 rather than contradicting it, but the wording has one author at
a time: whichever arc lands second reconciles there too.

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
- One canonical repository key, shared by the record path and the lease path, so
  that one repository resolves one of each however it is spelled and no two
  repositories resolve either (D-8).
- Discovery and restart-safe migration of records written under the old lossy
  key, so the move to the canonical path strands no possibly-live `gh` (D-8).
- Three `design.md` amendments: §3's new non-goal stating that one repository is
  worked by one board (D-1), the retirement of §15's "Nothing here schedules
  across processes", and the narrowing of §16's "cache paths … keep the case it
  resolved with" to the caches for which it stays true (D-8).
- A startup refusal — diagnostic plus non-zero exit — distinct in wording and in
  meaning from the two refusals that already exist (D-2 as amended, D-4).
  §17 itself is untouched (D-2 as amended).
- Optional owner identity on durable record entries, with no schema version
  change and no *schema* migration (D-3 as amended). The path migration D-8 adds
  is a separate thing: the envelope's shape is unchanged, and only its filename
  moves.
- A test harness able to run two independent processes against one isolated
  cache root and pause both at a shared state.

### Out of scope

- Merging two boards' views, or any multi-repository aggregation (§3 non-goal;
  `#354` owns the adjacent arc).
- Changing how a `gh` group is censused, killed, or proven owned. This arc
  changes *who may reclaim which entry and when*, not the reclaim mechanism.
- Repairing `safeKey`, or the paths that still use it. There are three
  independent copies of that mapping, not one — `src/Kanban/Cache.hs:580-585`,
  `src/Kanban/Transcript.hs:91-96`, and `src/Kanban/Worker/Paths.hs:91-96`. They
  have already diverged: the latter two also fold a space to `-`, and both key
  on `owner <> "-" <> name`, which is lossy before their mapping even runs.
  D-8 gives the record and the lease a key of their own and
  touches none of that; after GHA-2, `Cache.hs`'s copy has exactly one caller
  left, `repositoryCachePath` (`:206-209`). Consolidating the three, or fixing
  the worker and transcript paths, is separate work this arc does not do.
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
`System.Posix.IO.setLock` in the already-present `unix` package — held on a lock
file under the XDG cache root. `setLock` rather than `waitToSetLock`: D-2
refuses immediately, so the non-blocking form is the whole acquisition.

GHA-1 landed this as `Kanban.Repository.Lease`, with the lock file at
`$XDG_CACHE_HOME/kanban/leases/<safeKey(owner/name)>.lock`
(`src/Kanban/Cache.hs:252-255`). D-8 moves it beside the record at
`gh-groups/<canonical-key>.lock`, derived from the same declaration the record
path is, so the two can never disagree about which repository they are for.

The kernel releases an `fcntl` lock when its holder dies, however it dies. That
is the entire staleness rule, and it is why this arc proposes no PID file, no
heartbeat, and no reaping of another board's lock — a lock file carrying a PID
would owe a staleness rule of its own, and that rule is where this class of
change historically bleeds review rounds.

Keyed by repository identity, so two boards on two repositories never contend.
That keying is also what keeps `#354` coherent: one process holding several
repository coordinators takes one lease per repository, not a global one.

Two properties of the primitive are not obvious and were found only by building
it. A POSIX record lock belongs to the *process*, so the kernel grants a process
its own lock a second time rather than refusing it; without a module-level
register of what this process holds, two boards inside one process would each be
handed the same repository, and per-acquisition tokens are what stop a stale
lease value from releasing a later acquisition of the same path. And contention
must be classified on `errno` rather than on message text, because the message
GHC derives for `EAGAIN` on macOS reads as "resource exhausted (Resource
temporarily unavailable)", which no reasonable text rule would call contention.

`fcntl` record locks are POSIX and behave the same on macOS and Linux, so this
mechanism carries no new obligation for `#290`. Worth stating because the
alternatives do: `flock(2)` semantics differ across platforms in ways a
portability arc would have to account for, and a PID-file scheme would need a
liveness probe on each.

### The canonical repository key

One declaration produces both paths:

```text
asciiLowercase(owner) <> "%2F" <> asciiLowercase(name)

Coghex/Kanban  ->  coghex%2Fkanban

$XDG_CACHE_HOME/kanban/gh-groups/<canonical-key>.json
$XDG_CACHE_HOME/kanban/gh-groups/<canonical-key>.lock
```

Lowercasing is what makes it canonical for GitHub's case-insensitive identity,
and it is forced by D-1: without it a mixed-case clone takes a second lease on a
repository a first board already holds, and the promise is false. `%2F` is what
makes it injective — `isIdentityCharacter` admits only ASCII letters, digits,
`.`, `_`, and `-` inside a component (`src/Kanban/Repository.hs:181-186`), so
`%` cannot occur in either half and the separator is unambiguous. That holds for
every spelling Kanban accepts, not just one: the bare `--repo` form, the HTTPS
URL form, and the SSH form all funnel through `ownerNamePath` (`:171-179`,
reached from `:98`, `:134`, and `:147`), and it is the only place either
component is validated.

Deriving both paths from that one declaration is the point rather than a
tidiness preference: a lease keyed differently from the record it guards is a
lease that guards nothing.

### The legacy records

Moving the record's path strands whatever the old path holds, and what it holds
is the record of a `gh` that may still be running. So the move is a migration
rather than a rename.

Under the canonical lease, and before the first refresh, a board considers the
canonical record and every legacy flat `.json` whose basename matches this
repository's old lossy key under ASCII case-folding. A readable version-1
envelope belongs to this repository when its embedded `repositoryKey` matches
the current identity case-folded; one naming a colliding *different* repository
is left untouched and contributes nothing. Entries are combined without dropping
any distinct group, exact duplicates may be dropped, canonical state is written
durably before any legacy file is removed, and a legacy file goes only once its
entries are durably canonical or reclaimed and confirmed gone. Interruption at
any point may leave duplicate discoverable state; it may never leave the only
record of a possibly-live `gh` unreachable.

A legacy candidate that could belong to this repository but cannot be decoded
fails startup rather than being deleted or ignored, for the reason *The
unusable-record refusal never clears the record* gives: neither guess is
recoverable.

The envelope's shape does not change. `ghGroupRecordSchemaVersion` stays 1 and
this migration moves a filename rather than rewriting a payload, which is why it
leaves D-3 untouched.

### What the authority governs

Only the durable record and the `gh` spawns the board refresh makes under it.
Not the solve, review, or pull-request workers' own `gh` calls, which never
touch the record; not `--usage`; not `--ping`. Stated as a boundary in Scope
above because a lease that crept wider would make an agent action contend with
the board that started it.

### Entry attribution

`OwnedProcessGroup` (`src/Kanban/Process.hs:67-85`) gains the identity of the
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
instead of calling it "an earlier GitHub refresh". That narrower value has
exactly one consumer, which is why D-5 originally shipped it in the same slice
as the lease. D-9 records why a split was proposed and why the durable plan now
follows the one GHA-2 change that actually landed.

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
two existing refusals (`src/Kanban/UI/Reconcile.hs:305-312`,
`src/Kanban/UI/Events.hs:558-563`) keep their current wording and meaning; this one
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
the sections this arc amends are §3 and §15 rather than §3, §15, and §17. (D-8
later added §16 for an unrelated reason. The point D-2 settles is that §17 is
not among them.)

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

**Consequences:** no schema migration, no invalidation, and no first-upgrade
cost at all. The schema version stays available for a future change that really
is incompatible. `OwnedProcessGroup` gains a hand-written `FromJSON` in place of
the derived one. No slice of this arc carries a durable schema change, which
retires the bundling tension D-5 had accepted. Under D-1 the value remains crash
recovery and honest messages rather than live-group protection. D-8's path
migration is not in tension with any of this: it moves a filename and leaves the
envelope alone.

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
  `owner/name` and nothing else (`Cache.hs:577-578`, `repositoryIdentity`), so a
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

*Temporarily superseded by D-9's proposed split; the delivered shape restored
this decision. See the history note below.*

The owner identity and the corrected reclaim message land in the same pull
request as the lease acquisition and the refusal.

**Rationale:** the user's call. Under D-4 the reclaim only ever runs against a
dead board's record, so attribution has exactly one consumer and shipping it
apart from that consumer would land a field nothing yet reads.

**Consequences:** the arc has two implementation slices. Under D-3 as amended there is no
durable schema change to bundle, so `CLAUDE.md`'s *"Don't bundle unrelated
changes into one pull request"* no longer pushes against this decision the way
it did when D-5 was taken: the tension D-5 accepted deliberately has been
retired rather than merely tolerated, and the schema half is no longer a split
point because there is no schema half.

**Signed off:** by the user, this session. The amendment to D-3 narrowed its
consequences. D-9 later proposed reversing the decomposition, but that proposal
did not become a separate tracker or delivery artifact.

> **History.** D-5 folded attribution into the lease slice because, under D-4,
> the reclaim only ever runs against a dead board's record, so attribution had
> exactly one consumer and shipping it apart would land a field nothing read.
> D-8 then grew that slice by a canonical key and a legacy migration, and the
> resulting review burden prompted D-9's proposed GHA-2a/GHA-2b split. Neither
> half was processed separately: PR #518 delivered both together as the one
> remaining GHA-2 change under epic #499. The durable ledger follows that
> delivered unit while retaining the proposed split in D-9 as design history.

### D-6. The arc remains an epic

`/process-design-doc` will create the umbrella epic first and then one child per
invocation.

**Rationale:** the lease
primitive with its two-process test harness and the behavior change that
consumes it are separately reviewable, and the harness is a prerequisite that
must land and be trusted before the behavior built on it can be judged.

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

### D-8. The record and the lease share one canonical repository key, and legacy records are migrated

*Adopted from epic `#499`, which settled this after this document was written.*

`ghGroupRecordPath` and `repositoryLeasePath` are both derived from
`asciiLowercase(owner) <> "%2F" <> asciiLowercase(name)` and live side by side
under `gh-groups/`. Records written under the old lossy key are discovered by
case-folded basename, verified against their embedded `repositoryKey`, merged
into the canonical record, and removed only once their entries are durably
canonical or confirmed gone. `safeKey` and every other caller of it are
unchanged.

**Rationale:** this document assumed the record path was a repository-unique
identity and that no migration was owed. It is neither. `safeKey`
(`src/Kanban/Cache.hs:580-585`) maps `/`, `\`, and `:` to `-`, so one
repository's two spellings split across two files and two repositories can share
one. D-1 promises that one repository is worked by one board; a lease a
differently cased spelling does not contend for cannot keep that promise. And
moving the record's path without migrating it strands the record of a possibly
live `gh`, which is the one thing the record exists to prevent.

**Consequences:**

- GHA-2 grows by a key declaration, a legacy discovery pass, and a restart-safe
  migration. That growth prompted D-9's split proposal; PR #518 ultimately
  delivered the expanded slice together.
- `design.md` §16's "the identity used for GitHub queries, cache paths, and
  display keeps the case it resolved with" (`docs/design.md:2905`) stops being
  true of the record and the lease, and must be narrowed to the caches for which
  it still holds — the repository snapshot (`src/Kanban/Cache.hs:206-209`) and
  worker state. §16 joins §3 and §15 as a section this arc amends, and `#354`'s
  D-10 rests on the same sentence, so the two arcs reconcile there as they
  already must in §3.
- GHA-1's lease file moves from `leases/` to `gh-groups/`. Nothing takes the
  lease yet, so no installation holds one and the move costs no compatibility.
- The `%2F` spelling is injective only because `Kanban.Repository`'s grammar
  excludes `%` (`src/Kanban/Repository.hs:171-175`). A future widening of that
  grammar would owe this key a fresh look.
- `ghGroupRecordSchemaVersion` stays 1 and the envelope is unchanged, so D-3 is
  untouched.

**Signed off:** by the user, this session.

### D-9. GHA-2's proposed split did not become the delivered decomposition

After D-8 expanded GHA-2, the design proposed GHA-2a for the lease, refusal,
canonical key, migration, and `design.md` amendments, followed by GHA-2b for
the optional owner identity and corrected reclaim wording. The proposed seam
was real: one half governed *who may work this repository*, while the other
governed *what a record entry says about itself*.

Delivery did not use that decomposition. Neither proposed half became a
separate tracker item. Merged PR #518 implemented both together as "GHA-2, the
remaining slice of the epic," closed #499, and passed the combined authority,
migration, ownership, wording, contract, and two-process checks. The durable
ledger and delivery plan therefore restore the stable GHA-2 key and record one
delivered slice, while this decision preserves the considered split rather than
erasing it.

**Consequences:**

- D-5 again describes the delivered unit: attribution lands with the authority
  that consumes it.
- The rejected three-way split remains rejected. Migration must run under the
  lease, and separating it would create an unsafe intermediate authority domain.
- GHA-2 carries all three `design.md` amendments. The owner field and reclaim
  wording still change no separately documented behavior.
- GHA-2 is terminal as `[no-issue]`: the work was delivered under epic #499 and
  PR #518 rather than through a separately numbered child issue.

**Reconciled:** 2026-08-24 from merged PR #518 and closed epic #499. No new
behavior or tracker decision is inferred.

## Open questions

### Q-1. Is one repository open in two boards a configuration Kanban supports?

Resolved by D-1 — explicitly unsupported; §3 gains a non-goal.

### Q-2. What does the contended board do, and what does it show?

Resolved by D-2 as amended — refused immediately, as a startup diagnostic on
stderr with a non-zero exit. (This entry read "with a third §17 notice about the
real cause" until D-2's amendment removed the notice; §17 is untouched.)

### Q-3. Should a record entry name the board that owns it?

Resolved by D-3 as amended — yes, as an optional field, with
`ghGroupRecordSchemaVersion` left at 1 and no schema migration. The path
migration D-8 adds is a separate thing and leaves the envelope alone.

### Q-4. Where does the refusal land?

Resolved by D-4 — at launch, exiting non-zero. The lease is held for the whole
process lifetime.

### Q-5. Under D-1, is entry attribution still worth its own slice?

Resolved by D-5, then revisited by D-9 after D-8 grew the slice. The proposed
split did not become a separate tracker or delivery unit; PR #518 delivered
attribution inside GHA-2. The arc has two implementation slices.

### Q-6. Is this still an epic?

Resolved by D-6 — yes.

### Q-7. Does D-2's §17 notice survive D-4?

Resolved by the amendment to D-2 — it does not. The refusal is a startup
diagnostic, and §17 is untouched by this arc.

### Q-8. Does the refusal name the process holding the repository?

Resolved by D-7 — yes, the repository and the holder's PID, read live from
`getLock`.

### Q-9. Does epic `#499`'s superseding scope belong in this document?

Raised when processing found the epic body carrying a canonical repository key
and a legacy-record migration that appear nowhere here, with the epic's own
`Related` section recording the supersession in one sentence and nothing else
reflecting it. Resolved by D-8 — yes; the epic is the approved contract and this
document now states what it settled.

### Q-10. Does GHA-2 still fit one pull request?

Raised against the reconciled scope: lease acquisition, the refusal, the
canonical key, a restart-safe migration, the optional owner, the corrected
wording, three `design.md` sections, and a harness-backed witness. D-9 proposed
that it did not fit, but delivery supplied stronger evidence: PR #518 landed the
whole scope as one reviewed GHA-2 change. The document follows that terminal
fact rather than retaining two children that never existed.

---

**No open questions remain.** D-1 through D-9 settle the behavior, the scope,
the mechanism, and the decomposition.

## Verification strategy

- A barrier-controlled two-process test is the arc's central new capability. The
  Haskell suite spawned fake *external* executables (`fake gh`, `codex`,
  `claude`) and built temporary Git repositories, but never ran Kanban's own
  record code in two OS processes coordinated at a shared pause point. That
  harness was a prerequisite for proving anything here, which is why GHA-1
  carried it; it landed as `test/Spec/Support/LeaseProbes.hs`, and each probe
  carries its own `Repository` and its own cache root (`:111-116`), so both
  spelling proofs below are stageable without new harness work.
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
- The canonical key owes proofs of both properties that name it. Canonical:
  `Coghex/Kanban` and `coghex/kanban` resolve one record and one lease, and
  contend for it. Injective: `coghex-kan/ban` and `coghex/kan-ban` resolve
  neither the same record nor the same lease, and do not contend.
- Migration owes proofs that no entry is lost — a mixed-case legacy record found
  and merged; canonical and legacy records present together keeping every
  distinct group; a collision neighbour's valid record neither loaded, removed,
  nor made to contend; an undecodable ambiguous candidate failing startup
  without being deleted; and an interruption mid-migration leaving every
  possibly live group discoverable.
- The run-and-exit modes owe a proof that they acquire nothing: `--worker`,
  `--glyph-test`, `--doctor`, `--usage`, and `--ping` all short-circuit ahead of
  dashboard repository resolution (`app/Main.hs:35-103`), and the lease is taken
  only on the branch that reaches `runDashboard` (`:104-127`).
- `design.md` is `pr-atomic`, so the §3, §15, and §16 amendments land in the same
  pull request as the behavior they describe, not as a documentation slice.
  (This bullet said "§15 or §17" before D-2 was amended; §17 is untouched, §3 is
  what gains an entry, and §16 joined under D-8.)
- §3's entries are machine-checked, which the §3 amendment has to satisfy in the
  same pull request: `test/Spec/Design/Witnesses.hs` asserts that declarations
  and document entries match in *both* directions, so the new non-goal lands with
  a witness declaration — or an explicit `Unwitnessed` reason — beside it. A
  witness may not read a path `tools/test_source_distribution.py` excludes, which
  rules out resting it on this document.

## Delivery plan

Two implementation slices. GHA-1 supplied the prerequisite authority and test
harness; GHA-2 consumed it and completed the arc. D-9 records the proposed split
that did not become a separate delivery artifact.

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

### GHA-2. Canonicalize and migrate the durable record, refuse a second board, and attribute inherited groups

- **Outcome:** one repository resolves one record and one lease however it is
  spelled, and no two repositories resolve either; records written under the old
  lossy key are found and moved without stranding a possibly-live `gh`; and a
  second `kanban` on a held repository prints a diagnostic naming the repository
  and the holder's PID and exits non-zero instead of racing. The durable record
  becomes single-writer, so the reproduced lost update can no longer be staged.
- **Scope:** the canonical key declaration and both paths derived from it; the
  legacy discovery pass and its restart-safe migration; lease acquisition during
  dashboard startup and release at exit, with the run-and-exit modes taking no
  lease; the refusal diagnostic, its `getLock` PID, and its exit status; an
  optional owner `ProcessIdentity` on `OwnedProcessGroup` behind a hand-written
  backward-compatible decoder; capture of the dashboard's identity for new
  entries; the corrected inherited-record wording; and the
  `design.md` amendments — §3's new non-goal with its witness declaration, §15's
  retired cross-process sentence, and §16's narrowed cache-path sentence. §17 is
  untouched (D-2 as amended). `design.md` is `pr-atomic`, so all three land here.
- **Phase:** 2
- **Depends on:** `GHA-1`
- **Ordering:** `critical path`
- **Relevant decisions:** `D-1`, `D-2`, `D-3`, `D-4`, `D-5`, `D-6`, `D-7`,
  `D-8`, `D-9`
- **Acceptance signals:** two spellings of one repository contend for one lease
  and resolve one record, while two `safeKey`-colliding repositories contend for
  neither; a second `kanban` on a held repository exits non-zero with a
  diagnostic naming the repository and the holder's PID; a mixed-case legacy
  record is discovered and merged; canonical and legacy records present together
  retain every distinct group; a collision neighbour's record is neither loaded,
  removed, nor made to contend; an undecodable ambiguous candidate fails startup
  without being deleted; an interruption mid-migration leaves every possibly live
  group discoverable; the original two-process reproduction can no longer be
  staged; the run-and-exit modes acquire nothing; a record written before the
  owner field loads unchanged and is described truthfully; a new entry
  round-trips a present owner and an absent one; the owner is never consulted by
  `provablyOurs`, by any signalling decision, or by any reclaim-safety decision;
  a dead board's entries are reclaimed and described as a dead board's; and a
  single board behaves identically to today, which is the arc's loudest
  invariant.
- **Out of scope:** the reclaim mechanism itself; `safeKey` and every other path
  still keyed by it; the agent workers' own `gh` calls; `--usage` and `--ping`.
- **Open questions:** `None`

## Source notes

From `docs/project_review_314-299.md`, finding PRR-1's scope constraint:

> Locking only the write is insufficient because the absent-check-to-spawn
> window would remain; the cross-process authority must cover ownership
> acquisition as well as read-modify-write.

Its remaining uncertainty, which Q-1 restated and D-1 settled:

> Whether the intended product rule is a shared repository lease or an explicit
> one-dashboard-per-repository refusal is a design choice. The current unguarded
> check/write behavior is not safe under either interpretation.

From epic `#499`'s `Related` section, the one sentence in which the supersession
D-8 has now adopted was recorded:

> `docs/gh_record_authority_design.md` — supporting record for decisions D-1
> through D-7. Its earlier assumption that the legacy path is repository-unique
> and requires no path migration is superseded by this issue's canonical-key and
> compatibility requirements.
