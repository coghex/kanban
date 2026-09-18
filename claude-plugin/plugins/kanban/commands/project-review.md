---
description: Senior-model audit of one merged pull request per invocation, recorded in the reviewed repository's own project-review ledger — select the next pull request from a complete merged-PR inventory, claim it under a session-bound lease, verify every finding against a detached worktree pinned to the fetched default-branch head, and preserve confirmed current mistakes in a ledger-allocated findings report for later /process-report disposition. Never creates or edits a tracker issue, never repeats, and never merges. Trigger when asked to run /project-review or to audit the next merged pull request; reviewing the direct first-parent commits that predate the pull-request workflow is a separate, explicitly requested mode.
argument-hint: "[optional: `direct` — with an explicit request — plus a count, commit SHA, or range, to review pre-PR history instead]"
---

# Project review

You are the senior reviewer in a pipeline where issues and PRs are mass-produced
by lesser autonomous models. Re-examine merged work with fresh, skeptical eyes
and catch what the assembly line missed.

**One pull request per invocation.** A successful run in the default PR mode
completes exactly one review and never starts another. An empty inventory, a
pull request nobody can claim, a refusal, and a cancellation each complete zero
reviews — and none of them falls through into the direct-commit mode below.
Repetition is /auto-project-review's, not this workflow's: there is no
`continue` action here, and no invocation ever begins a second review.

**Review only.** Do not modify the reviewed code, touch merged PRs, or create or
edit tracker issues. This workflow makes no commit and pushes nothing: the
ledger helper's `record` step publishes the one checkpoint, and nothing else in
this document writes to a branch. The findings report it may write is the
durable handoff to /process-report, which turns one finding at a time
into an approved tracker artifact — so filing is not lost here, only deferred
one step, and it passes through the readiness gate on the way.

**Resolve the target — a repository *and* a checkout of it.** Set both `REPO`
and `ROOT` once, before the first GitHub read below. `$REPO` is the
`owner/name` every `gh` call names; `$ROOT` is the local checkout every other
step runs in, and neither substitutes for the other. A `gh` call that names no
repository reads whatever repository the session's working directory happens to
be in, and a review scoped against the wrong tracker spends the whole run
producing a report about code nobody asked you to review.

`$REPO` alone is not the target, because most of this workflow never touches
GitHub: the ledger lives in the docs worktree, the review runs against a
worktree of the reviewed repository, and direct mode walks first-parent history.
Every one of those reads a checkout. Run them all under `$ROOT` with
`git -C "$ROOT"`, never in whatever directory the session happens to be sitting
in.

When the user named a repository, `$ROOT` is a checkout **of that repository**,
and the session's own is not it unless it proves to be. Otherwise both come from
the session's checkout. Resolution reads the remote and needs no GitHub call of
its own, so there is no point in this workflow at which an unscoped `gh`
invocation is correct:

```bash
ROOT="$(git rev-parse --show-toplevel)"
REPO="$(git -C "$ROOT" remote get-url origin | sed -E 's#\.git$##; s#.*(/|:)([^/:]+/[^/:]+)$#\2#')"
```

When the user named a repository, set `REPO` to the name they gave and `ROOT`
to a checkout of it, then run that same `git -C "$ROOT" remote get-url` and
**require the two to agree**. They must name one `owner/name` between them. A
mismatch, or no available checkout of `$REPO`, stops the run before the first
`gh` call: auditing one repository's pull requests against another's code, or
writing its ledger and report into another's docs worktree, is exactly the
failure this check exists to prevent, and neither is undone by moving a file
afterwards. Say which of the two could not be established and ask for a local
path. Falling back to the working directory is never the repair.

Either path leaves `$REPO` holding one `owner/name` and `$ROOT` a checkout of
it, before the first `gh` call. Every `gh` call below names that one identity:
`-R "$REPO"` on each of the pull-request and issue reads, and `$REPO`'s own
owner and name on the inventory query.

**Announce, then read:** name the resolved `$REPO` and the `$ROOT` it was
matched against before the first `gh` call below. Reporting what was resolved is
what catches a wrong resolution, and it catches it only if it lands before
anything has been read from the wrong repository.

## Which mode this invocation is, before anything else

**Decide the mode here, and take only that mode's path.** PR mode is the
default. Direct-commit mode happens only when the user asked for it explicitly
in this turn, and when they did, **none of the PR-mode steps run at all** — not
the ledger read, not the migration, not the inventory, and not the liveness
registration.

That is a correctness rule, not tidiness. Direct mode is the cursor's; a
repository that has never had a ledger must not acquire one by being asked for a
direct batch, and a bundle whose ledger module or liveness adapter could not be
resolved must not be blocked from a mode that needs neither.

- **An explicit direct request:** resolve the scripts directory and `$CURSOR`
  below — direct mode's own fence, and not PR mode's — then the docs worktree,
  then go straight to "Direct-commit mode — explicit request only" and do
  everything there. Skip every numbered step.
- **Anything else:** PR mode, and every step in order.

## Resolve this bundle's helpers

Three modules ship with this plugin rather than with the repository being
reviewed, so each is resolved against this plugin's install location and never
against `$ROOT` or the docs worktree. That lookup is what lets this workflow run
in a repository that tracks no copy of any of them.

**Locate the directory the three share, never one of the modules.** Which of
them this invocation needs is the mode's answer, and the mode was decided above;
a locator that goes looking for one particular module makes every mode depend on
that module being installed:

```bash
SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
[ -d "$SCRIPTS" ]
```

Then resolve and check **only the modules this invocation's mode uses**, in that
mode's own fence, and run the other mode's fence not at all.

PR mode takes the ledger and the adapter:

```bash
LEDGER="$SCRIPTS/project_review_ledger.py"
LIVENESS="$SCRIPTS/project_review_liveness.py"
[ -f "$LEDGER" ] && [ -f "$LIVENESS" ]
```

Direct-commit mode takes the cursor, and neither of the others:

```bash
CURSOR="$SCRIPTS/project_review_cursor.py"
[ -f "$CURSOR" ]
```

`$LEDGER` owns `docs/project_review/ledger.md`, the reviewed repository's own
per-pull-request review record, and every read and write of it below. `$LIVENESS`
is the session-liveness adapter whose keeper process the claim's lease follows.
`$CURSOR` owns `docs/project_review_boundaries.md` and serves the explicit-only
direct-commit mode alone; PR mode never reads or writes it.

**An unresolvable helper stops the run here, before the first read** — and a
module this mode never calls being absent is not one. That is what the two
fences above are for: only one of them runs, so a bundle missing its ledger
module or its adapter refuses a review and still serves a direct batch, and a
bundle missing its cursor refuses a direct batch and still serves a review. A
missing shared directory stops either mode, because nothing can be resolved
without it. Do not substitute a copy tracked in the reviewed repository, a personal copy, or a path
derived from the working directory: the state those modules own belongs to the
repository under review, and a helper resolved from the wrong place writes it
somewhere nobody will look for it again.

## Resolve the docs worktree

Resolve the reviewed repository's docs worktree once, by branch and never by a
hard-coded path. It is `--root` for every helper call below — where the ledger
is read and written, and where a finished report is written:

```bash
DOCS_WT="$(git -C "$ROOT" worktree list --porcelain \
  | awk '/^worktree /{p=substr($0,10)} /^branch refs\/heads\/docs-wip$/{print p; exit}')"
[ -n "$DOCS_WT" ]
```

**An empty `$DOCS_WT` stops the run, and `$ROOT` is not the fallback.** The
primary checkout is where the PR drainer's post-merge fast-forward autostashes
whatever it finds, so a ledger or report written there is not durable state at
all — it is the next merge's wedge. Say the reviewed repository has no
`docs-wip` worktree and ask for one rather than writing anywhere else.

## Migrate a repository that has no ledger yet

**PR mode only.** A direct request reached the direct section above and never
arrives here; that is what keeps a cursor-only batch from creating a ledger.

Read the ledger before anything else touches it:

```bash
python3 "$LEDGER" read --root "$DOCS_WT" --repo "$REPO"
```

A repository whose docs worktree holds `docs/project_review_boundaries.md` or
historical `docs/project_review_*.md` reports but no ledger is a repository whose
coverage has to be imported before a selection means anything. Run the migration
once, on the first invocation in a repository whose ledger does not exist yet:

```bash
python3 "$LEDGER" migrate --root "$DOCS_WT" --repo "$REPO"
```

It refuses outright over an existing ledger, so it runs exactly once however
many invocations follow. A repository with neither a cursor nor a report starts
from an empty ledger and has no stop and nothing to confirm: the same call
establishes that empty ledger, reports `"status": "migrated"` with no rows, and
the run continues. Say which of the two this was.

**A flagged migration stops for the operator.** Exit 3 with `"status":
"flagged"` means the helper read a report whose opening paragraph it will not
read as an enumeration, and it has written nothing. Present every flagged report
by path, with its `candidates` — the pull-request numbers its prose names — and
its `reason`, and **stop for the operator's confirmation**. Do not guess which
candidates were reviewed and do not continue past a flag: importing coverage
that was never real marks unreviewed pull requests reviewed, and discarding real
coverage re-reviews work somebody already did. Neither is recoverable from the
ledger afterwards. When the operator confirms an enumeration, pass it back
verbatim and migrate again:

```bash
python3 "$LEDGER" migrate --root "$DOCS_WT" --repo "$REPO" --confirm "docs/project_review_463-455.md=463,456,455"
```

### Legacy rows

Every row the migration writes is `[legacy]`: the coverage is known, and nothing
about when it was reviewed, what it was verified against, or whether it was
clean is. A `[legacy]` row is not a reviewed row. Selection schedules it in its
own queue — after every never-reviewed pull request, highest number first — and
the ordinary review below converts it: the completed `record` replaces the
`[legacy]` status with `clean` or `findings`, its verification commit, and its
UTC completion time. No separate conversion step exists, and nothing in this
workflow edits a `[legacy]` row by hand.

## One review, end to end

Steps 1 through 9 are one invocation, ordered so that nothing is created before
something needs it: step 1 reads GitHub and writes nothing, step 2 registers the
attempt everything after it is named for, and step 3 is the first to put
anything on disk. Step 9 runs on **every** exit, including the ones that stop
early: each of its steps is owed from the moment the resource it removes exists,
so a run that stops in step 3 still owes it the directory step 2 made, and one
that stops in step 1 owes it nothing.

### 1. Take a complete inventory of merged pull requests

Page the repository's merged pull requests until a page comes back short. A
listing that stopped early is indistinguishable from a repository with fewer
pull requests in it, and the difference is between "#612 has never been reviewed"
and "#612 was never listed" — so the helper accepts only a contiguous sequence
from page 1, taken at one page size, ending in a page shorter than that size:

Take one page per call. `$AFTER` is `null` for the first page and each earlier
page's own `next` for every page after it:

```bash
gh api graphql -F owner="${REPO%%/*}" -F name="${REPO##*/}" -F limit=100 -F cursor="$AFTER" \
  -f query='query($owner:String!,$name:String!,$limit:Int!,$cursor:String){repository(owner:$owner,name:$name){pullRequests(states:MERGED,first:$limit,after:$cursor,orderBy:{field:CREATED_AT,direction:DESC}){pageInfo{endCursor} nodes{number title mergedAt}}}}' \
  --jq '{prs: [.data.repository.pullRequests.nodes[] | {number, title, merged_at: .mergedAt}], next: .data.repository.pullRequests.pageInfo.endCursor}'
```

Repeat that call until a page comes back with fewer than 100 pull requests on
it. That short page is the last one; `next` is what positions the call after it,
and nothing else does. Then assemble the pages into the one listing the helper
reads — in hand, not on disk: step 3 gives it a home once step 2 has made one.
It has this shape:

```json
{"pages": [{"page": 1, "limit": 100, "prs": [{"number": 704, "title": "…", "merged_at": "2026-09-17T18:40:53Z"}]}]}
```

`page` is the page's 1-based position in the order you fetched it and `limit` is
the 100 every page was asked for. The helper reads the sequence rather than the
rows: page numbers must be contiguous from 1, one page size across the whole
walk, nothing after the first short page. Those are what make a listing with an
interior page dropped detectable, so never renumber around a page you skipped.

**A page that fails stops the run.** Say which page failed and stop. This step
writes nothing and starts nothing, so a stop here owes step 9 nothing at all —
which is the reason it comes first. Never hand the helper the pages that did
arrive: a listing with a page missing from it records
every pull request on that page as one this repository does not have.

The last page is short because a page returned at its own limit may be a page of
a longer history and nothing in the page itself can tell the two apart. When the
history ends exactly on a page boundary, the next request comes back with no
rows at all, and that empty page is the short one.

**A listing with no pull requests in it at all stops the run here**, before step
2. A repository that has merged nothing has nothing for this workflow to
review, and registering an attempt for it would start a keeper, write the
adapter's records, and make a directory, all to discover that in step 3. Say the
repository has no merged pull requests and stop; like a failed page, this exit
owes step 9 nothing, because nothing was created.

### 2. Register the session liveness adapter, and reclaim what earlier attempts left

The claim in step 3 is a lease that renews only while a liveness signal is held,
and the signal is the keeper process this adapter starts. Register it **before**
claiming, so an invocation that could never renew claims nothing — and **after**
the inventory, so a repository with nothing to review spawns no keeper and
writes no record.

Take a nonce first:

```bash
python3 "$LIVENESS" nonce
```

Then register in a tool call of its own, **substituting the 32 hex digits that
command printed literally into the command text**:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/project_review_liveness.py" register --runtime claude --root "$DOCS_WT" --repo "$REPO" --nonce 0123456789abcdef0123456789abcdef
```

A shell variable will not do, for either half of that line. The adapter's
lifecycle hook fires *before* this command runs and reads the text the tool call
was given, so what it sees is the unexpanded source: it recognizes a
registration by `project_review_liveness.py` followed by `register`, and takes
the attempt's nonce from the digits beside `--nonce`. A `$LIVENESS` in place of
the helper's own filename, or a `$NONCE` in place of the digits, leaves the hook
with nothing to recognize and writes no handshake — and the registration then
refuses with `hooks-not-observed`, which is also exactly what a disabled or
untrusted hook looks like. That is why this one command spells the helper's path
out where every other call below uses `$LIVENESS`.

`--root` is `$DOCS_WT` rather than `$ROOT`, in both calls and in step 9's
`complete`. The adapter reads the renewal interval the claim will record out of
the ledger under that root, to refuse a silence window shorter than it; pointed
at the primary checkout it would read a repository with no ledger in it, get the
60-second default, and validate the window against an interval this repository
does not use. Both are worktrees of the same repository, so the attempt's own
records land in the one Git common directory either way.

`register` prints the attempt id and the keeper's pid. Record both: `$ATTEMPT`
and `$KEEPER`.

**Everything this invocation creates goes in one directory named for that
attempt**, under the Git common directory every worktree of `$ROOT` shares —
beside the lease's own heartbeat records and the adapter's, and inside no
working tree at all:

```bash
RUNTIME="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)/kanban-project-review/worktrees"
ATTEMPT_DIR="$RUNTIME/$ATTEMPT"
mkdir -p "$ATTEMPT_DIR"
```

The listing step 1 assembled and the worktree step 4 pins both live there, and
step 9 removes the one directory. Nothing this workflow creates is anonymous,
and nothing of it is left where a `docs/` publication or an operator's own
working tree could pick it up.

**Then reclaim the directories earlier attempts left.** This is the only cleanup
a cancellation can get — the runtime ends the keeper, but it cannot run step 9 —
so it runs here, before anything new is made, and it is what makes that exit
recoverable rather than merely harmless. Each directory beside yours under
`$RUNTIME` is some attempt's, so ask the adapter about each one by its name:

```bash
python3 "$LIVENESS" status --root "$DOCS_WT" --attempt "$SIBLING"
```

**An attempt is over** when `status` reports `"status": "ended"`; when it
reports `"status": "active"` but a `keeper_standing` other than `live`, which is
what a keeper killed outright leaves behind — it writes no ended record, so
reading `active` alone would strand that directory for good; or when the adapter
refuses it as `attempt-unknown`, which is what an attempt pruned after seven
days looks like. An `active` attempt with a live keeper belongs to an invocation
running somewhere: leave it alone.

**Over is not reclaimable, and every step from here fails closed.** Removing
this directory deletes a checkout, so the question is never "is there a reason
to keep it" but "can this invocation *establish* that nothing is using it". Two
answers must both be positive, and anything else retains:

- **The keeper is positively gone.** `keeper_standing` is `gone`, or the attempt
  reports `ended`. `unverifiable` is not gone — it is a keeper on another host,
  or a pid this process may not signal — and an `attempt-unknown` refusal is
  worse, because the adapter has no records left to answer either question
  from. Both retain.
- **Nothing it launched is still running.** `status` answers that separately:
  `unfinished_launches` names every wrapped launch that cannot be established to
  have ended, whether or not its tool call finished — which is the question that
  matters here, because the command that outlives a cancelled attempt is a
  backgrounded one, and `exempt_launches` is built to skip exactly those. It
  answers on the *command*, not on the wrapper around it: a wrapper killed with
  `SIGKILL` runs no handler and so dies leaving its command running, which is why
  "the wrapper is gone" establishes nothing. A launch is gone only when the
  command it recorded is gone, or when the wrapper recorded having waited that
  command out; a launch with neither is unfinished, because a wrapper killed
  before it spawned looks exactly like one killed a moment after. A non-empty
  list retains.

A retained directory is reported by path with the reason — the standing that
could not be verified, or the labels still running — and left for a later
invocation, once the answer is positive, or for /janitor, where an
operator can decide what this workflow may not. Deleting a worktree out from
under a live process is the one outcome nothing later can repair, and a
directory left on disk costs only disk.

Reclaim the rest: remove each one's worktree and directory exactly as step 9
does, and say how many you reclaimed and how many you retained and why.

**Never run Git's `worktree prune` here, or anywhere else in this workflow.**
It is repository-wide: it clears the administrative record of every worktree of
this repository whose directory is missing, including ones belonging to a person
or to another agent that this invocation knows nothing about — and this pass is
entitled to touch exactly the attempts it just established were safe to take. It
would not even be reliable for the record it was reached for, since it honours
Git's own prune expiry and a freshly orphaned record is usually inside it.
`git -C "$ROOT" worktree remove --force` clears the record of the one worktree it
removes, and that is the whole of the record-clearing this pass does. A record that outlives it — the directory already gone, so the removal
reports `is not a working tree` — is reported by name, with the attempt it
belonged to, and left for /janitor, exactly as a retained directory is.

**A refusal here stops the run before any claim.** `runtime-unavailable`,
`runtime-unsupported`, `hooks-not-observed`, `hooks-incomplete`, `hooks-disabled`,
`hooks-untrusted`, `plugin-unresolved`, `bundle-mismatch`, `bundle-ambiguous`,
`binding-unavailable` and `silence-too-short` each name what the adapter
observed and what to repair. Report the refusal as it came and stop. Never
substitute this session's own application process for the keeper, never name
some other long-lived pid as `--owner-pid`, and never fall back to a descriptor
that closes when one tool call ends: the lease's whole guarantee is that it
lapses when *this review invocation* does, and an application that outlives the
invocation holds a claim nobody is working on.

### 3. Select and claim exactly one pull request

`claim` selects and claims under one lock, so the pull request it names is the
one it took:

Write the listing step 1 assembled into this attempt's directory, which is the
first thing this invocation puts on disk:

```bash
INVENTORY="$ATTEMPT_DIR/inventory.json"
```

Then claim:

```bash
python3 "$LEDGER" claim --root "$DOCS_WT" --repo "$REPO" --owner-pid "$KEEPER" < "$INVENTORY"
```

It reports the pull request in `selected`, the queue it came from in `queue`,
and the claim's owner token in `claim.token`. Record the number as `$PR` and the
token as `$TOKEN`; every later helper call presents both. Announce the pull
request, its queue, and the inventory's counts before reviewing anything.

Three outcomes are not a claim, and each completes zero reviews:

- **`"status": "no-selectable-row"`** — every merged pull request the listing
  named is excluded. Say so and stop.
- **`"status": "all-claimed"`** — somebody holds a live claim on every
  selectable pull request. The payload names each holder and its deadline.
  Say so and stop; do not wait, and do not take over an unexpired claim.
- **A refusal** — exit 2, with its reason on standard error. Report it and stop.

None of these enters direct mode. Direct-commit review is a separate explicit
request, and an exhausted or unavailable PR queue is not one.

An expired claim is taken over automatically and recorded as an ownership
transition; that is ordinary recovery from a crashed run and needs nothing from
you. From this point on step 9 owes a release as well.

### 4. Pin the review tree

Fetch, resolve the remote default branch's head to a full SHA, and create a
detached temporary worktree at it. The review is verified against that exact
tree and nothing else, so it never depends on the primary checkout staying
where it is.

**Three tool calls, each checked before the next.** A shell runs every line of a
block whatever the ones above it did, so a fetch that failed inside one would be
followed by a resolution against whatever the local remote-tracking refs still
hold — a stale tree, reviewed and recorded as though it were the remote's head,
which is the one thing requirement 1's fetch-failure stop exists to prevent. The
fetch is therefore its own call, and its status is read before anything else
runs:

```bash
git -C "$ROOT" fetch --quiet origin
```

**A failed fetch stops the run**, here, with nothing else attempted: release the
claim through step 9 and say the fetch failed. Never substitute an older local
ref — a review recorded against a SHA the remote never had says nothing about
the code anybody else can see, and a `ls-remote` that answers while a fetch
fails is exactly the shape that makes one look plausible.

Only then resolve the branch and its head:

```bash
DEFAULT_BRANCH="$(git -C "$ROOT" ls-remote --symref origin HEAD | sed -n 's#^ref: refs/heads/\(.*\)[[:space:]]HEAD$#\1#p')"
PIN="$(git -C "$ROOT" rev-parse "refs/remotes/origin/$DEFAULT_BRANCH")"
```

**The default branch is read from the remote, not from
`refs/remotes/origin/HEAD`.** That local symref is written once, by `clone` or
by an explicit `remote set-head`, and a fetch does not refresh it: a repository
whose remote moved from `master` to `main` keeps answering `master` for as long
as the old branch still exists, and the review would then be recorded against a
branch nobody's default is. `ls-remote --symref` asks the remote itself on every
invocation. An empty `$DEFAULT_BRANCH` is a remote that reported no HEAD symref
at all, and an empty `$PIN` is a branch this fetch did not bring down: either
stops the run, through step 9, rather than pinning something nobody named.

Only then create the worktree, inside the directory step 2 made for this
attempt:

```bash
REVIEW_WT="$ATTEMPT_DIR/tree"
git -C "$ROOT" worktree add --detach "$REVIEW_WT" "$PIN"
```

No worktree, lock, or liveness record ever lives under `docs/project_review/`:
that directory publishes, and a runtime artifact in it would publish with it.

`$PIN` is the full SHA recorded as the verification commit in step 8.

### 5. Review the pull request

1. Read its description with `gh pr view -R "$REPO" "$PR"`.
2. Find its linked issue in that description's closing reference and read it
   with `gh issue view -R "$REPO" <m>`. Step 1's call returns the pull
   request's own description, never the specification it claims to satisfy, so
   this is a read of its own rather than a second look at the same text. Treat
   the issue as a proposed specification, not unquestioned authority.
3. Read the merged diff with `gh pr diff -R "$REPO" "$PR"` and judge it against
   what the issue should have required, not merely what the PR claims.
4. Read the touched code **in `$REVIEW_WT`**, plus enough callers and consumers
   to verify that the behavior still holds in context. Every file read that
   decides a finding is a read of that pinned tree; a read of `$ROOT` is a read
   of whatever that checkout happens to be sitting on.
5. Check the commits and messages against what actually landed.

Judge whether the issue's requirements were correct, complete, consistent with
repository constraints, and backed by acceptance capable of failing a wrong
implementation. A faithful implementation of a flawed specification is still
a finding. A PR that deviated from a bad specification to do the right thing is
not.

Hunt especially for unmet requirements, vacuous or mock-only tests, unhandled
edge cases, repository-contract violations, stale comments/docs, unreviewed
scope creep, and semantic conflicts with the work merged around it. Nits are not
findings; a finding must require a real correction.

**A long command runs through the adapter's wrapper.** A build or a test run
inside the review can outlast the silence window, and the keeper cannot tell a
quiet reviewer from a cancelled one. Start such a command through `run`, whose
command text the hook recognizes the same way it recognizes a registration, and
its launch holds the lease open while the tool call is in flight:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/project_review_liveness.py" run --root "$DOCS_WT" --attempt "$ATTEMPT" --launch build -- <command>
```

**Give every launch a label no earlier launch of this attempt has used.**
`build` above is an example, not a name to reuse. The exemption belongs to the
first wrapper that claims a label, so a second `run --launch build` starts its
command and earns no exemption at all: the keeper stops counting it as progress,
and a command long enough to need the wrapper is long enough to lose the claim
while it runs — after which this attempt's `record` is refused and the review's
work is lost. The adapter says so on standard error, naming the launch and the
attempt and giving both reasons it can be un-exempt, an unknown attempt or a
reused label. **That line is a refusal, not a warning to read past.** Name
launches for what they do — `build`, `test-suite`, `bench-after-fix` — and if it
appears, stop the command, choose a label nothing has used, and start it again.

The adapter reports the reuse rather than refusing it, and that is deliberate:
refusing a label before the spawn, or giving a second wrapper an exemption of
its own, would change the adapter's own execution model, which belongs to #687
and not here. So the discipline is this workflow's, and the paragraph above is
it.

It exits with the command's own status. A command the runtime backgrounds
returns from its tool call at once and gets no such exemption, so a long command
belongs in the foreground here.

### 6. Verify each finding against the pinned tree and the row's history

For every suspected finding:

1. Confirm it still exists at `$PIN` — a later merge may already have fixed it.
2. Trace the failure path in that tree's code and cite `file:line`, or capture a
   reproduction command and result run inside `$REVIEW_WT`. Never report a
   hunch.
3. Search open and closed tracker issues for context and deduplication — once
   up front, then a keyword search or two per finding:

   ```bash
   gh issue list -R "$REPO" --state open --limit 300 --json number,title,labels
   gh issue list -R "$REPO" --search "<words>" --state all --limit 20
   ```

   **An already-tracked finding is still a finding.** The tracker search
   decides what its entry's `Deduplication` line says, not whether it has one:
   write the entry, name the open issue that already holds it there, and name it
   in the completion message too. That line is what stops
   /process-report filing a second issue for it — the report is the
   handoff, and filing is that workflow's decision to make with the
   deduplication in front of it, not one to make here by leaving the defect out.
   It is also what makes the review recordable at all: a row is `findings` only
   with a report or an existing-finding link beside it, and a defect this review
   confirmed at `$PIN` cannot honestly be recorded `clean`.
4. Read the reports the row's own history links and compare the finding with
   their `PRR-*` entries. **Read the ledger again for that history, now that
   the claim is held:**

   ```bash
   python3 "$LEDGER" read --root "$DOCS_WT" --repo "$REPO"
   ```

   The read before the migration step is not that history. It was taken before
   the inventory and before the claim, and between the two another invocation
   can have recorded a review of this very pull request and linked a report to
   it; on a repository that migrated in this run it held no rows at all. A
   finding compared against that snapshot is a finding compared against a row
   that has since moved, and the entry it then files is the second copy of
   somebody else's. The claim is what makes this row stable — nobody else can
   record against it while this invocation holds it — so the read taken after it
   is the one that can be trusted, and `claim`'s own payload does not carry the
   row's history.

   Three dispositions follow, and they are not interchangeable:
   - **New** — no earlier report for this pull request describes it. It may
     produce a new report entry.
   - **Repeated** — an earlier report's `PRR-k` describes it and it is still
     unresolved. It produces **no new report entry**: pass
     `--repeat "<report>#PRR-k"` to `record` instead. Filing it again splits one
     defect across two entries that /process-report would then dispose of
     twice.
   - **Recurrence** — an earlier report's `PRR-k` described it, it was resolved,
     and it has returned. It may produce a new report entry, and that entry's
     handoff context must carry `Recurrence of: <report> PRR-k`. Pass
     `--recurrence "<report>#PRR-k"` to `record` as well. The original finding
     appearing in an earlier report is not a reason to suppress the new entry:
     what returned is a new defect in current code with a history.

   A repeated finding with no new or recurring finding beside it is still a
   findings-bearing review. It allocates no report, records its existing-finding
   links, advances the completion timestamp, and earns no clean mark. The
   absence of a report never means the pull request was clean.
5. A **fix link** records that some later pull request corrected an earlier
   finding. Pass `--fixed "<report>#PRR-k=<fix PR>"` and
   `--fixed-merge "<report>#PRR-k=<merge commit>"` only after verifying both
   halves yourself: that the fix pull request merged in `$REPO`, with
   `gh pr view -R "$REPO" <fix PR> --json state,mergedAt,mergeCommit`, and that
   its correction is present in `$REVIEW_WT`. A merged pull request that claims
   a fix is not evidence that the tree carries one.
6. Keep reviewing the rest of the pull request. Do not stop to discuss or file
   one finding.

Capture each new current finding in the established project-review format:

- `Captured note`: the concise correction;
- `Verification`: what was proved and how, against `$PIN`;
- `Evidence`: `file:line` traces in the pinned tree and/or reproduction;
- `Handoff context`: current behavior, expected behavior, scope and
  constraints, verification target, deduplication, uncertainty, and
  `Recurrence of:` where step 6.4 requires it.

State observable requirements and validation boundaries, not an assumed
implementation. Preserve enough context for a later autonomous
/process-report pass to decide and draft one tracker artifact at a time.

### 7. Write a report only for new findings

Write a report when, and only when, at least one finding is new or a verified
recurrence — an already-tracked one included, since step 6.3 gives that an entry
too. A review whose findings are all unresolved repeats writes none, and a clean
review writes none. Do not draft tracker issue bodies, ask which
findings to file, open an issue through `gh`, or append any origin-routing
marker: this workflow never creates or edits a tracker issue, and the user's
invocation authorizes the report handoff rather than a filing.

The helper allocates the name, atomically, under the claim:

```bash
python3 "$LEDGER" allocate-report --root "$DOCS_WT" --repo "$REPO" --pr "$PR" --token "$TOKEN"
```

It returns `report` — `docs/project_review/<PR>.md` for the first report about
this pull request and `docs/project_review/<PR>_<k>.md` for each later one.
**Never choose a report name yourself**: an existing name is never reused, and a
name nobody allocated is one `record` will refuse. Write the file at that path
under `$DOCS_WT`, preserving unrelated dirty files in that worktree.

Use this canonical shape:

```markdown
# Project Review Findings: PR #<number>

<Purpose, the pull request reviewed, the verification commit, and any
explicitly excluded concern.>

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [ ] PRR-1. <Finding title>

## 1. <Concern chapter>

### PRR-1. <Finding title>

> **Captured note:** <Concise correction and offending change.>

**Verification:** <Verified result, against the pinned commit.>

**Evidence:**

- `<file>:<line>` — <failure-path evidence>.

**Handoff context:**

- **Current behavior:** <Observed behavior.>
- **Expected behavior:** <Required behavior.>
- **Scope and constraints:** <Boundaries and related PR/issue.>
- **Verification target:** <Exact checks that should prove the correction.>
- **Deduplication:** <Tracker-search result.>
- **Remaining uncertainty:** <Unknowns, or none.>
```

Keep every new finding unchecked and unmarked. Each stable `PRR-*` key appears
exactly once in the checklist and once in a finding heading, in the same order
and with the same title. The legend line must begin literally `Status legend:`;
an unlabeled list of marker meanings is not canonical. Inspect a neighbouring
`docs/project_review/*.md` report for its shape if one exists — never for its
scope, which the ledger owns.

Run the installed backlog scan when available and require the new path under
`valid_reports`. Run the repository's focused findings-report audit when
applicable.

### 8. Record the completed attempt

`record` writes the outcome into the row, publishes the ledger and the report as
one path-scoped checkpoint on the docs worktree's branch, and releases the
claim:

```bash
python3 "$LEDGER" record --root "$DOCS_WT" --repo "$REPO" --pr "$PR" --token "$TOKEN" \
  --outcome findings --commit "$PIN" --report "docs/project_review/<PR>.md" \
  --repeat "<report>#PRR-k" --recurrence "<report>#PRR-k" \
  --fixed "<report>#PRR-k=<fix PR>" --fixed-merge "<report>#PRR-k=<merge commit>"
```

`--outcome clean` for a review with no finding of any kind; `--outcome findings`
for every other completed review. Every other one has something to link, which
is what the helper requires of a `findings` row: a new or recurring finding has
the report step 7 allocated, an unresolved repeat has its `--repeat`, and an
already-tracked finding has the report entry step 6.3 gives it. `clean` is for
the review that found nothing, and for nothing else. `--commit` is `$PIN`, the tree the review was actually
verified against. `--report` is the allocated path and is omitted when step 7
wrote none. Each `--repeat`, `--recurrence`, `--fixed` and `--fixed-merge` is
repeatable and is omitted when there is none.

The checkpoint is the helper's, and it is the only commit this workflow
produces. Do not stage, commit, publish, push, or land anything yourself — not
the ledger, not the report, not the cursor. A refusal here leaves the claim held
and says so; report it as it came and let step 9 clean up.

### 9. Clean up, on every exit

Every exit runs this — a completed record, a refusal, a failed fetch, a
takeover, and a cancellation alike. **Each resource is owed its cleanup from the
moment it exists**, not from the step that was meant to fill it: a registration
that refused started no keeper, and a claim that was never taken leaves nothing
to release.

So the steps are conditional, in this order, and each runs **only when this
invocation created what it names**. A step whose resource was never created is
not run, and not running it is not a failure.

1. **Stop every process this attempt started** — when step 2 registered one:

   ```bash
   python3 "$LIVENESS" complete --root "$DOCS_WT" --attempt "$ATTEMPT"
   ```

   That ends the keeper, and so the claim's renewal. Stop anything else this
   review launched beside it. A registration that refused started nothing.

2. **Release the claim, unless `record` already did** — when step 3 reported
   `"status": "claimed"` and step 8 did not report `"status": "recorded"`:

   ```bash
   python3 "$LEDGER" release --root "$DOCS_WT" --repo "$REPO" --pr "$PR" --token "$TOKEN"
   ```

   `no-selectable-row`, `all-claimed`, and a claim refusal leave no `$PR` and no
   `$TOKEN`, so there is nothing to release and this step does not run. A
   completed `record` released it already; a second release is refused rather
   than harmful, which is why the condition is the cheaper one to get wrong.

3. **Remove the temporary worktree** — whenever step 4 *attempted* to create
   one, whether or not it reported success:

   ```bash
   git -C "$ROOT" worktree remove --force "$REVIEW_WT"
   ```

   Whether it succeeded is not what decides this. A `worktree add` that failed
   can have left a directory, an administrative record, or both, so an attempt
   is the condition and not an outcome. `is not a working tree` is this step
   finding nothing registered, which is this step done — go on to step 4. Any
   other failure is a real one: retain and report.

4. **Remove this attempt's directory** — whenever step 2 made one, unless step 3
   failed for some reason other than finding nothing to remove:

   ```bash
   rm -rf "$ATTEMPT_DIR"
   ```

   One removal, because everything this invocation created is in there: the
   listing step 3 wrote and the worktree step 4 pinned. `$ATTEMPT_DIR` exists
   from step 2, so an exit before either of them still owes this — which is the
   whole difference between a condition on the resource and a condition on the
   step that was meant to fill it. But it *contains* `$REVIEW_WT`, so removing
   it after a failed `worktree remove` would delete the very worktree the
   previous step just reported it had retained — and where that failure left
   Git's administrative record behind, leave the record naming a directory that
   is gone. A partial removal can end either way, with the record dropped and
   the tree still on disk or both still there, so neither is assumed. When
   step 3 really failed, keep `$ATTEMPT_DIR`, report it by path, and report any
   record still naming it as an unresolved record for /janitor. Do not
   reach for Git's `worktree prune` and do not tell the reader to: it is
   repository-wide, and clearing one attempt's leftover at the price of every
   other worktree's record is not this workflow's to trade. **Never derive a removal target from
   another path**: the parent directory of a variable an early exit never set is
   the working directory, and a recursive removal of that is the one mistake
   this workflow could make that nothing later could repair.

**A cleanup step that fails is reported with the path it retained, never as
removed.** Name the directory still on disk, or the claim still held, so a human
or a later run can finish it. Claiming removal that did not happen is what
leaves an orphan nobody knows to look for.

**Cleanup and every ownership check are scoped to this attempt.** If this
attempt's claim was taken over while it ran, its `record`, its report
allocation, and its release are all refused — correctly — and its cleanup then
stops its own processes and removes its own directory, and touches nothing the
replacement owns. Never remove a directory, end an attempt, or release a claim
that this invocation did not create.

**A cancellation reaches all three of these without a tool call of this
invocation's.** You do not have to reach step 9 for any of them:

- *Processes.* The keeper stops on turn completion, session termination, an
  interruption the runtime reports, and after a bounded silence window for a
  cancellation it does not report. That is #687's mechanism, and it needs
  nothing from the model. A command started through the wrapper is the
  exception in both directions: it holds its launch exempt from that window
  while it runs, and which commands the runtime ends on an interruption is the
  runtime's own answer rather than a general rule. #687's evidence records
  both, each against the version it was measured on, and this workflow states
  them rather than promising past either:

  - **Claude Code 2.1.274:** an interrupt killed a foreground tool's
    processes, while a command the runtime had backgrounded survived it. A
    backgrounded launch's tool call is reported finished about eighty
    milliseconds in, so that survivor holds no exemption — and is the one the
    reclaim pass has to detect by other means.
  - **Claude Code 2.1.276:** an interrupted foreground command keeps going,
    measured still running ninety seconds after the Escape. That one keeps its
    exemption for as long as it runs, so the keeper does not end on silence
    while it does.
  - **codex-cli 0.154.0:** an interrupted foreground command is moved to a
    background terminal and keeps running, its tool-finish event arriving under
    the old turn id only when it ends. Codex's `Interrupt` event ends the
    keeper at once regardless, so the survivor outlives the attempt rather than
    extending it.

  A version is what each of those was measured on, not a guarantee that a newer
  runtime still behaves that way; re-probe before quoting one. So a
  cancellation with a wrapped command still running is not bounded by the
  window alone. When that
  command finally exits, its tool-finish event is itself a progress event, so it
  **refreshes** the silence window rather than ending it: the keeper then waits
  that window out afresh, plus a poll, before the lease starts running down.
  The bound is the command's remaining run time, plus a silence window, plus a
  keeper poll, plus one renewal interval, plus the expiry — or the end of the
  session, whichever comes first. The renewal interval is in there because the
  renewer follows the keeper rather than dying with it: it looks at that signal
  at least once per renewal interval, so it can write one more renewal after the
  keeper is gone, and the expiry that runs down is the one *that* renewal
  stamped. (This implementation looks every renewer poll, a second, which is why
  the measured lapse is shorter than the interval the contract promises.) The
  reclaim pass is what refuses to remove that directory meanwhile.
- *The claim.* Renewal stops with the keeper — within one renewal interval of
  it, by the rule above — so the lease runs out and the row becomes claimable
  again; the next invocation takes it over under the helper's lock and records
  the transition, which is the recovery the lease was designed around. The cancelled attempt cannot write to it afterwards: its token no
  longer owns the claim, so its `record`, its allocation and its release are all
  refused.
- *The directory.* Step 2's reclaim pass takes the directory of a cancelled
  attempt **once it can establish that taking it is safe** — the keeper
  positively gone, and no unfinished launch — and retains it, by name and with
  the reason, until then. That is why everything this invocation creates is
  named for the attempt and kept in one place: an orphan is identifiable, and
  the next invocation in this repository is its owner where it can be, and
  /janitor where it cannot.

So the honest summary is that a cancellation's processes and claim resolve on
their own, and its directory is taken by the next invocation that can prove
nothing is using it — which is the invocation after it in the ordinary case, and
an operator's `janitor` pass where the adapter can no longer answer: an
`attempt-unknown` refusal, a keeper standing that is `unverifiable`, an
unreadable launch record, or a launch still running. Nothing is left in a
working tree or under a publishable path in any of those cases. Say, in the
completion message, what this invocation reclaimed on its way in and what it
retained and why.

### 10. Report, and stop

The completion message names, in one place:

- the pull request reviewed, and the queue `claim` took it from;
- the outcome — `clean`, or the findings and their count;
- the verification commit `$PIN`;
- the report path, or the existing-finding links a repeats-only review recorded;
- the checkpoint commit `record` published;
- fixed-later and already-tracked findings, briefly.

Then stop. There is no continuation prompt, no `continue` action, and no next
batch. A user who wants another review invokes /project-review again;
/auto-project-review is what repeats it without being asked each time.

## Direct-commit mode — explicit request only

Reviewing the direct first-parent commits that predate the pull-request workflow
is a **separate mode, entered only when the user explicitly asks for it in this
turn**. Nothing enters it automatically. An exhausted PR queue does not, a
repository with no merged pull requests does not, a refusal does not, and a bare
`continue` does not — there is no `continue` here at all. Each direct-mode
invocation needs its own explicit direct request, and it reviews one batch and
stops; it never starts another.

This mode keeps the sweep cursor it has always used. It does not read or write
the ledger, and the ledger does not schedule it: `$CURSOR` owns
`docs/project_review_boundaries.md`, whose `direct` endpoint is a moving
older-history frontier that advances to the oldest commit a completed batch
reviewed.

Default to 12 review units.
`$ARGUMENTS` may override the count, or name a commit SHA or range.

**A count is a batch size, not a position.** An explicit count changes how many
units this batch takes and nothing else. Only an explicit commit SHA or range
changes this batch's requested start, and a unit the user excluded is never
selected again by a later invocation. This mode has no boundary to override:
the exclusive PR boundary is the cursor's PR half, which nothing here reads.

Selection is the helper's, and it happens before any unit is reviewed rather
than in the report-writing step, from the first-parent walk itself rather than
from any report's account of it:

```bash
git -C "$ROOT" log --first-parent --format=%H \
  | python3 "$CURSOR" select --root "$DOCS_WT" --repo "$REPO" --mode direct --count "${COUNT:-12}" --start "$RANGE_START" --end "$RANGE_END"
```

`$COUNT` is the requested count and defaults to the 12 above. `$RANGE_START` and
`$RANGE_END` carry a user-supplied range's two endpoints — its newer and its
older — and are empty when the user supplied none; an empty `--start` or
`--end` is no bound at all, so one invocation covers both cases.

**A range needs both of its endpoints.** `$RANGE_START` alone is a starting
point, not a range: the count keeps filling downwards past the older endpoint
whenever coverage or an exclusion thins the middle of the request. `--end` is a
bound rather than a target — the batch stops there whatever the count still had
left, and reports `"bounded": true` rather than `truncated` or `exhausted`,
because it was the request that ended and neither the page nor the history.

**`$RANGE_START` carries the entry point on the first direct batch**, and is
empty for every batch after it. Set it to the first-parent parent of the
earliest pull-request-owned commit already reviewed, and leave it empty for a
repository that has never used pull requests, which begins at HEAD. An empty
`--start` is no start at all, so this one invocation covers both — but leaving
it empty on the *first* batch of a repository that does have PR history restarts
the walk at HEAD and re-reviews PR-owned commits, because direct state is still
empty at that moment and there is no endpoint to position it.

**Walk the whole first-parent history, not a slice starting at the entry
point.** The recorded endpoint has to be inside the listing the helper positions
within, and a walk that began below it would refuse it as a cursor belonging to
some other history. Every batch after the first is positioned by the record.

Announce the helper's `origin`, frontier, `gaps`, and skipped units with the
batch. Every uncovered commit above that frontier appears in `gaps` and must be
announced; never let the direct walk silently discard it.

Two rules govern what the helper's reconciliation may conclude here, and each
one is a mistake this sweep has already made:

- **A report never establishes direct-commit coverage.** A first-parent commit
  inside a reviewed interval is either covered by the recorded endpoint or
  selected; a report's prose about the commits in its interval decides nothing,
  because that prose has been wrong. A report that states its interval held no
  direct commits has been wrong about eight of them, and a commit erased that
  way is erased for good.
- **Unverifiable state stops the run.** A recorded SHA is validated against
  current first-parent ancestry, so a malformed, foreign, or ambiguous cursor
  refuses before review rather than guessing. Report the helper's own message.

A commit may be named at any length `git` itself accepts — four characters up,
the seven a direct-mode report filename carries included. `select` and `record`
resolve an abbreviated SHA against the walk, and refuse a prefix that names more
than one commit rather than choosing between them, so length is never the
refusal; ambiguity is. An endpoint an earlier run recorded in a shorter spelling
keeps working for the same reason.

If context was compacted, recover the cursor with
`python3 "$CURSOR" read --root "$DOCS_WT" --repo "$REPO"` rather than from the
last completed range or a report name: the record survives compaction, a clean
batch, and a fresh session alike, and the two transient sources survive none of
them. Ask only when the helper itself reports state it cannot resolve.

Announce direct mode by short/full SHA range, count, and dates. Restate that
concrete range beside the resolved `$REPO` once the walk returns, before
reviewing anything in it. Stop explicitly after reviewing the initial commit.

### Reviewing direct commits newest-first

Read each first-parent patch and metadata:

```bash
git -C "$ROOT" show --stat --summary <sha>
git -C "$ROOT" diff <sha>^1 <sha>
```

Use an empty-tree diff for the initial commit, which has no first parent to
diff against. Read adjacent commits when the change is a partial step. Treat the
message, historical repository instructions, tests, and subsystem contracts as
evidence, not necessarily a complete specification.

**This mode verifies against `$ROOT`, and owes none of step 6.** Step 6 is PR
mode's: it needs `$PIN`, `$REVIEW_WT`, a claimed row and that row's history, and
none of those exists here — there is no claim, no ledger row, and no pinned
worktree, and a direct batch that went looking for them would find nothing.
Verify each suspected finding this way instead:

1. Confirm it still exists in `$ROOT`'s checkout as it stands — a later commit
   may already have fixed it. That checkout is the whole of what a direct
   finding is verified against, and the completion message names the commit it
   was on so a reader knows which tree that was.
2. Trace the failure path there and cite `file:line`, or capture a reproduction
   command and its result. Never report a hunch.
3. Search open and closed tracker issues for context and deduplication exactly
   as PR mode's step 6.3 does, through the same two issue listings. An
   already-tracked finding still earns an entry whose `Deduplication` names the
   issue that holds it.
4. Capture each current finding in the same four sections PR mode uses —
   `Captured note`, `Verification`, `Evidence`, `Handoff context` — with the
   verification and the evidence taken from `$ROOT` rather than from `$PIN`.

There is no repeat, recurrence or fix link in this mode: those are ledger
entries, and direct mode has no row to link them to. A finding an earlier direct
report already carries is named in the completion message and given no second
entry.

Record fixed-later mistakes as completion-summary one-liners. Only current
mistakes become unprocessed report entries.

A broad blame or survivor inventory is triage, not a reviewed direct-commit
batch. Advance the cursor past a direct commit only after checking its patch,
message, and current descendants individually.

### The direct-mode report and record

A direct batch with at least one confirmed current finding writes one report at
`docs/project_review_direct_<newest7>-<oldest7>.md`, under `$DOCS_WT/`. Its name
is the reviewer's here — no helper allocates it, because no ledger row owns this
batch — and an explicit destination from the user wins over it. A clean batch
writes no report unless the user explicitly asks for one.

Its shape is the one step 7 sets out with two substitutions, and nothing else
from step 7 applies: the title is
`# Project Review Findings: direct commits <newest>–<oldest>`, and the opening
paragraph states the batch's SHA range, the commit the findings were verified
against, and any excluded commit — a pull-request number and `$PIN` have no
meaning here. The legend line, the `## Status` checklist, one `PRR-*` key
appearing once in that checklist and once in a finding heading, and the four
capture sections are all exactly as they are there.

**Record the cursor last.** Record coverage only after every selected unit has
been reviewed and any required report has been written and validated, so a
failed report or a failed cursor write is never reported as a completed batch:

```bash
git -C "$ROOT" log --first-parent --format=%H \
  | python3 "$CURSOR" record --root "$DOCS_WT" --repo "$REPO" --mode direct --reviewed "$REVIEWED" --exclude "$EXCLUDED"
```

The walk is piped in here exactly as it is at selection, and for the same
reason: the helper resolves and orders every reviewed SHA against the candidate
history it is given, so a `record` handed none refuses the batch it is trying to
record rather than recording it against nothing. A batch
that selected nothing records nothing and is not a completed batch: the helper
refuses an empty `--reviewed` with an empty `--exclude`. `record` merges rather
than replaces: an earlier exclusion survives a later batch, and the direct
endpoint only ever moves older.

The cursor and any direct-mode report are left in the docs worktree as
uncommitted working files; the cursor is durable because it is on disk, not
because it was landed. Do not publish or land either unless the user separately
requests it — **direct mode writes to no branch at all**. The one branch write
this workflow ever makes is PR mode's, and it is the helper's: `record`'s
path-scoped checkpoint commit, which touches the ledger and the report it
allocated and nothing else. Direct mode calls `record` on the cursor module,
which commits nothing.

In the completion message, link the report, state its unprocessed finding count,
list fixed-later and already-tracked findings briefly, and name the durable
progress the record now holds. Then stop: no next batch, and no transition back
into PR mode.
