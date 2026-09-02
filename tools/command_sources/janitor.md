---
name: janitor
description: "Audit the agent pipeline's state signals and clean only what the user approves: claims, worktrees and their stray files, workflow branches and refs, pull-request and drainer health, stashes, recovery objects, and default-branch drift. Use for {{cmd:janitor}}, housekeeping, unexplained dirty or generated files, stale local or GitHub state, and pre- or post-pipeline cleanup. Reports first and mutates only approved, revalidated items."
---

# Pipeline Janitor

Produce an anomaly-only snapshot that preserves every possible copy of work.
Keep the primary checkout clean, intentional long-lived state visible, and the
local and GitHub signals consistent. Never clean by age or naming alone.

This audits a pipeline where autonomous agents claim issues (an assignee, or a
`wip` label, plus an `issue-<n>-<slug>` worktree), open pull requests, take
label-gated reviews, and merge through the service-managed PR drainer
{{cmd:drain-prs}} controls. An agent that dies mid-flow leaves debris that
silently blocks its issue forever, because the solve workflow's own collision
checks read these exact signals. Find it all. Report first; touch nothing
without approval.

## 0. Resolve this bundle's helper, then the repository

**Resolve the census helper first.** It ships with this plugin rather than with
the repository being audited, so it is resolved against this plugin's install
location and never against the audited checkout:

<!-- brand:claude -->
```bash
CENSUS="${CLAUDE_PLUGIN_ROOT}/scripts/census.py"
[ -f "$CENSUS" ]
```
<!-- brand:codex -->
```bash
CENSUS="$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" -path '*/kanban/*/skills/janitor/scripts/census.py' 2>/dev/null | head -n1)"
[ -n "$CENSUS" ]
```
<!-- /brand -->

That lookup resolves this plugin's own install location regardless of the
invoking working directory, which is what lets this workflow audit a repository
that tracks no copy of the helper.

**An unresolvable helper stops the run here, before the first read.** Not after
one: every judgement below is made over the census document, so a run that has
already read state it cannot interpret has spent GitHub calls to produce
nothing. Say the helper could not be resolved and stop. Hand-walking the
repository in its place is not the repair — it is the drift this slice retired.

**Resolve the repository once, from the session's checkout, and announce it.**
`$ROOT` is the checkout every `git` step and the census itself run against;
`$REPO` is the `owner/name` every `gh` call names. Neither substitutes for the
other, and a `gh` call without `-R` reads whatever repository the session's
working directory happens to be in — which, in an audit that removes worktrees
and deletes branches, is the one mistake that cannot be undone by re-reading:

```bash
ROOT="$(git rev-parse --show-toplevel)"
REPO="$(git -C "$ROOT" remote get-url origin | sed -E 's#\.git$##; s#.*(/|:)([^/:]+/[^/:]+)$#\2#')"
ENDPOINT="$(git -C "$ROOT" remote get-url origin \
  | sed -E -e 's%^([A-Za-z0-9+.-]+://)[^@/]*@%\1<redacted>@%' \
           -e 's%^[^/@:]*(:[^/@]*)?@%<redacted>@%' \
           -e 's%[?#].*%%')"
```

Name the resolved `$REPO` and `$ROOT` before the first census run, and never
re-resolve either afterwards. Announcing them is what catches a wrong
resolution, and it catches it only while nothing has been read or written
against the wrong repository. Pass `-R "$REPO"` on every `gh` invocation in
this workflow.

`$REPO` is an `owner/name` with the host thrown away. That is everything a
`gh` call needs and not enough to name a Git endpoint, so `$ENDPOINT` keeps the
effective fetch URL whole: it is the endpoint `git ls-remote origin` reads, and
the only thing a remote deletion can be bound to. Announce it beside the other
two.

`$ENDPOINT` is announced redacted, because a fetch URL may carry a credential.
The whole userinfo goes, not merely the part after a `:` — a bare
`https://<token>@host/owner/name.git` puts the secret in the username position,
and nothing can tell a secret username from an ordinary one — and so does
everything from the first `?` or `#`. **Every endpoint identity this run
shows** — that one, and every push destination §2 reads into the report or a
refusal below names — is shown through that same redaction. A push URL carries
a credential exactly as a fetch URL does. Redaction is for display only: the
destination proof in §5 compares the URLs Git itself reports, because two
endpoints differing only in their credentials are two endpoints.

## 1. Compact census

Read the repository's agent instructions, then run:

```bash
python3 "$CENSUS" --repo "$ROOT" --fetch
```

`--fetch` refreshes `origin` without pruning. The program emits a
`janitor-census/v1` document: every registered worktree's concise status,
branch and ref reachability, stale tracking refs, claims and open-PR links,
default divergence, ordinary stashes, and the managed drainer's incidents,
cleanup debt, recovery refs and stashes, and untracked holding directories. It
also recognizes the coordinated-test base and active run worktrees without
loading test history, and it reads the terse repository-local retention ledger
`janitor-retain.json` from the Git common directory, which keeps machine-local
decisions outside every worktree. Those two arguments are the whole invocation:
pass nothing else.

**Keep the first pass small.** Do not fetch PR bodies, issue titles, comments,
checks, logs, full diffs, or stash patches in bulk. Do not enumerate ignored
files globally, scan shared worktree roots, or crawl `.git`; the census reads
only registered and repository-owned state.

**A `null` or unavailable collection is an anomaly, never a clean result.** A
truncated status list, a `null` counter, a `warnings` entry, an
`"available": false` block, or an inventory that could not be read means the
inspection failed and must be diagnosed. An unreadable worktree is not a clean
one, and an unreadable retain ledger is not an empty one. Report the failure as
its own item; never let it collapse into "nothing to clean".

**The retention ledger is a reminder, not an exemption** from live evidence or
from an approval gate. Revalidate each recorded target and its `review_when`
condition on every run. Report a stale or contradicted entry as a decision;
never silently discard the entry or the state it retains. When the user asks to
record a retain decision, add one concise item with a stable id, target,
disposition, reason, and review condition. Update or remove an item only with
approval, or after its recorded condition is proved. **No ledger mutation
happens before explicit approval** — the ledger is state like any other.

## 2. Verify anomalies only

Target only the candidates the census named, one targeted read each. **Run no
seed, write, install, or repair mode of any producer during an audit**, however
convenient its output would be: this step reads. Every fenced command below is
a template — fill its `$ISSUE`, `$PR`, `$BRANCH` or `$STASH` from the census
item being confirmed, and run one per candidate rather than one per category.

- **Claims and issue worktrees:** confirm a candidate against its issue and its
  branch's own pull-request history, never against a bulk listing:

  ```bash
  gh issue view "$ISSUE" -R "$REPO" --json number,state,assignees,labels,updatedAt
  gh pr list -R "$REPO" --state all --head "$BRANCH" --json number,state,mergedAt,labels
  ```

  A claim with neither worktree nor open closing PR is a stale candidate;
  confirm age and activity before disposition. An open issue worktree with no
  open PR is limbo — inspect assignment and `wip`, the latest PR disposition,
  explicit retention notes, dirt, upstream equality, and the last commit — and
  an agent may be working in it right now, so limbo is always report-only and
  always needs individual say-so. A closed issue is only a zombie candidate
  until the worktree's content and its branch's recoverability pass the gates
  in §3. Multiple worktrees or multiple closing PRs for one issue are signal
  mismatches, not cleanup. A confirmed stale claim loses only its assignees
  and its `wip` label; never alter issue content or approval labels.
- **Worktrees:** `git worktree list --porcelain` is repository-scoped truth and
  covers legacy paths and repository-scoped `<root>/<owner>/<repo>/…` paths
  alike. Never scan a shared worktree root or infer ownership from a directory
  name. Verify a missing entry before pruning its metadata:

  ```bash
  git -C "$ROOT" worktree list --porcelain
  git -C "$ROOT" worktree prune --dry-run --expire now --verbose
  ```

  For a detached review checkout, inspect only its inferred target; a live or
  unknown target, or a dirty checkout, is retain-only. Repository-declared
  permanent worktrees — the documentation-authoring worktree above all — are
  never removal candidates and are not listed as ones.
- **Coordinated tests:** the coordinator-owned detached test base is permanent
  read-only infrastructure. For a per-run worktree, inspect its coordinator
  record and preserve a dirty evidentiary harness. Use the coordinator's own
  `cleanup`, never raw Git removal; an active or unclassified run is
  retain-only.
- **Branches and refs:** audit workflow branches (`issue-*`, `pr-*`,
  `kanban-drainer/*`) with no worktree and no open PR, plus any other
  unexplained branch. A merged workflow branch may be cleanup; an unmerged
  branch is retained work. Compare remote-tracking refs against the remote
  itself before proposing any prune or remote deletion — local tracking refs
  lie:

  ```bash
  git -C "$ROOT" ls-remote --heads origin
  git -C "$ROOT" remote get-url --push --all origin \
    | sed -E -e 's%^([A-Za-z0-9+.-]+://)[^@/]*@%\1<redacted>@%' \
             -e 's%^[^/@:]*(:[^/@]*)?@%<redacted>@%' \
             -e 's%[?#].*%%'
  ```

  Those two reads answer different questions, and a remote branch needs both
  before it is proposed for deletion. `ls-remote` reads through `origin`'s
  **fetch** endpoint — `$ENDPOINT`, the one this run announced — while a push
  goes to `origin`'s **push** destinations, which are a separate, multi-valued
  setting. `git remote get-url --push --all origin` reports those destinations
  after Git's own rewriting, so it is the read that says where a deletion would
  actually land. It goes through §0's redaction, character for character,
  because this read is what puts a destination into the report and a push URL
  can carry a token as readily as a fetch URL can. A branch whose deletion
  would reach any destination other than `$ENDPOINT` is reported as visible
  cleanup debt — named, with the reason — and no remote deletion is proposed
  for it.

  Nothing here is the proof. Redaction is a function, so two destinations that
  were equal stay equal and this comparison never refuses a branch it should
  have kept; two that differ only in their credentials read as one here, and
  §5's own read — of what Git reports, unredacted, immediately before the push
  — is what refuses them. This one only decides what to report.
- **PR and drainer state:** the controller status the census carries is
  authoritative for service health and cleanup debt; do not recreate its
  eligibility algorithm. Route an incident or a stopped service to
  {{cmd:drain-prs}} `recover`. For a `reviewed:changes` pull request, read only
  the newest canonical review marker and the commits since it:

  ```bash
  gh pr view "$PR" -R "$REPO" --json headRefOid,labels,commits
  gh api --paginate --slurp "repos/$REPO/issues/$PR/comments?per_page=100"
  ```

  The comment feed is read paginated rather than through a bounded `--json
  comments` window, because on a long pull request the newest marker falls
  outside that window and the audit would report a verdict that is not the
  current one. An unchanged head means resume {{cmd:pr-revise}}; a newer head
  needs {{cmd:pr-rereview}} first. A pull request with no verdict at all is
  `unreviewed`, not automatically abandoned. Approved pull requests stay
  drainer-managed: report the controller's reason if one is waiting, and read
  its checks only for a candidate you are about to call ready.

  ```bash
  gh pr checks "$PR" -R "$REPO" --json name,state,bucket
  ```
- **Recovery objects — every one is a possible last copy of work.** Age is
  evidence of neglect, never evidence that content is expendable. Judge a stash
  by its own delta and never by diffing its files against the current branch: a
  months-old stash shows thousands of changed lines merely because the branch
  moved on, which says nothing about whether its work is lost.

  ```bash
  git -C "$ROOT" stash show -p "$STASH"
  ```

  Compare that delta's added lines against the current files with list
  numbering, emphasis, and whitespace normalized — prose that was rewrapped, or
  a list item renumbered from `5.` to `6.`, is the same content, and an
  exact-line comparison reports it as lost when it is not. A line that
  genuinely never landed may still be superseded rather than missing: check
  whether current behavior contradicts it before proposing a restore, because
  reinstating a superseded sentence puts a false statement back into the
  documentation. Classify each object as `fully landed`, `unlanded content`
  (quote the lines), or `contradicted by current behavior` (cite what
  supersedes it); anything not provably `fully landed` or
  `contradicted by current behavior` is retain-only and needs item-level
  approval. Drainer recovery state carries three extra rules: a drainer stash
  is an ordinary stash entry created by a failed preparation or restore and is
  classified the same way; a kept autostash anchor under
  `refs/drain-prs/autostash/<sha>` may be the only named copy when no stash
  points at the same commit, so it is retained unless a matching stash proves
  it redundant; and a `.git/autostash-*` holding directory is reconciled file
  by file, never removed as a unit, and never before every contained file has
  its own disposition.
- **Dirty and stray content:** the primary checkout's dirt is always an
  anomaly. A permanent worktree is exempt from removal, not from content
  auditing: identify its publication workflow from the repository's own
  instructions before judging anything in it, and never infer that an untracked
  file is disposable or that a file under a documentation directory ought to be
  committed. Locks, leases, caches, and recovery artifacts do not become source
  merely to silence `git status`, and a persistent lock whose correctness
  depends on a stable inode is never unlinked. An ordinary dirty feature
  worktree is recoverable work, never a cleanup candidate. Every disposition in
  this class needs item-level approval.
- **Default branch:** report operations in progress and divergence from
  `origin/<default>`. Offer only a clean, operation-free fast-forward. An ahead
  or diverged default branch needs diagnosis; never reset it.

## 3. Preservation gates

An item qualifies for bulk `all-safe` only when **every** applicable fact below
is current and proved. One unproved fact disqualifies the item and moves it to
item-level approval; it never downgrades to a warning. The near-misses named
beside each gate are the cases that most often read as a pass and are not.

- **Worktree removal:** the exact registered path from the porcelain listing,
  not a repository-declared permanent worktree, no operation in progress, an
  empty status *including untracked files*, a terminal target, and a HEAD
  merged into the remote default branch. *Near-miss:* a worktree whose only
  dirt is untracked files has a non-empty status and stays item-level.
- **Branch deletion:** no worktree and no open PR, the full SHA recorded, and
  the tip merged into the remote default branch; for a remote branch,
  `ls-remote` additionally proves the branch still exists at that SHA, the
  deletion carries that SHA as a `--force-with-lease` so the proof and the push
  describe one commit, every effective push destination for `origin` is proved
  to be that same endpoint, and remote deletions go **one push per branch**.
  *Near-miss:* a tip merged into
  the local default branch but not into the remote one is unmerged for this
  gate; and a remote name `ls-remote` no longer lists is a stale tracking ref
  rather than a deletion target — one already-gone branch name aborts an
  entire multi-branch `git push origin --delete` client-side, so nothing at
  all gets deleted while the report reads as though everything did.
  *Near-miss:* a push destination that reduces to the same `owner/name` as the
  audited endpoint is not that endpoint — the reduction discarded the host, so
  two repositories of the same name on different hosts read as one.
- **Review metadata prune:** the directory is already missing *and* the
  `--expire now` dry run names it. *Near-miss:* an entry the dry run does not
  name is still registered, whatever the filesystem suggests.
- **Tracking-ref prune:** `ls-remote` proves the origin head absent.
  *Near-miss:* a `refs/remotes/` entry with no local branch proves nothing on
  its own — a stale tracking ref is exactly what that looks like.
- **Default fast-forward:** a clean default worktree, no operation in progress,
  the local branch not ahead, and the drainer reporting no active operation.
  *Near-miss:* a default branch that is ahead or diverged needs diagnosis, and
  is never resolved by a reset or by a merge that is not a fast-forward.

Dirty or unmerged work, limbo worktrees, permanent-worktree content, every
recovery object, coordinated-test worktrees, unknown branches and unknown
review targets, and any ambiguous disposition are **excluded from `all-safe`**
and always require item-level approval. "Keep; no remediation" is a valid
result.

## 4. Report, then stop

Report the audited default SHA and the census counts, then the anomalies and
nothing else. Group them as `retain/decision`, `safe cleanup`, and
`pipeline attention`; give each item a stable id, concise evidence, a
disposition, and the exact command or workflow that would carry it out.
Collapse a clear area into one sentence rather than printing an empty category.
State explicitly what `all-safe` excludes, then **stop for approval and touch
nothing**. Accept "all-safe", a group, or single item ids.

## 5. Apply approved items

Rerun the census with the same two arguments before applying anything, so every
gate is rechecked against current state rather than against the snapshot the
report was written from:

```bash
python3 "$CENSUS" --repo "$ROOT" --fetch
```

Recheck each item's gates immediately before its own command and skip anything
that changed. **Every command below acts on one approved item and nothing else.**
A partial approval is the normal result of §4, so a command that would also reach
an item the user did not approve is refused rather than run. Apply items
individually, recording deleted branch and ref SHAs in the result. Never use
`rm -rf`, force-remove a dirty worktree, delete an unmerged branch, drop
unproved recovery state, force-push, reset, or hand-edit the drainer's locks,
queue state, scheduler state, or incidents.

Each command is a template: every variable in it comes from the approved item,
and `$DEFAULT` from the census's own `default_branch`.

**Per-item deletions.** Each names one target exactly and carries the value the
report recorded for it, so a target another actor moved between the report and
the apply is refused rather than deleted:

```bash
git -C "$ROOT" worktree remove "$WORKTREE"
git -C "$ROOT" branch -d "$BRANCH"
PUSH_ENDPOINTS="$(git -C "$ROOT" remote get-url --push --all origin)" &&
  [ -n "$PUSH_ENDPOINTS" ] &&
  [ "$PUSH_ENDPOINTS" = "$(git -C "$ROOT" remote get-url origin)" ] &&
  git -C "$ROOT" push origin "--force-with-lease=refs/heads/$BRANCH:$SHA" ":refs/heads/$BRANCH"
[ "$(git -C "$ROOT" rev-parse --verify --quiet "$STASH^{commit}")" = "$STASH_SHA" ] &&
  DROPPED="$(git -C "$ROOT" stash drop "$STASH")" &&
  DROPPED_SHA="${DROPPED##*\(}" &&
  DROPPED_SHA="${DROPPED_SHA%\)}" &&
  { [ "$DROPPED_SHA" = "$STASH_SHA" ] ||
      git -C "$ROOT" stash store -m "janitor: restored an unapproved stash" \
        "$DROPPED_SHA"; } &&
  [ "$DROPPED_SHA" = "$STASH_SHA" ]
git -C "$ROOT" update-ref -d "$REF" "$REF_SHA"
git -C "$ROOT" update-ref -d "$TRACKING_REF" "$TRACKING_SHA"
```

Remove a worktree by its exact registered path, never by a reconstructed one.
Delete a remote branch one push per branch, and never with a bare `--delete`:
that deletes whatever the branch points at *now*, so a branch someone pushed to
after the `ls-remote` proof loses work nothing ever reviewed. The
`--force-with-lease` naming the recorded SHA refuses that push instead, and the
proof and the deletion then describe the same commit.

**The lease binds the branch; nothing in it binds the destination.** `git push`
does not necessarily write to the URL `ls-remote` read: `remote.origin.pushurl`
replaces the fetch URL for pushes when it is set, it is multi-valued and every
one of its values receives the same push, and a `url.<base>.pushInsteadOf` rule
redirects the push with no `pushurl` in the configuration at all. So the
deletion is a chain, and its push is reached only while
`git remote get-url --push --all origin` — which reports the destinations after
all of that rewriting — answers with exactly one entry equal to `origin`'s own
effective fetch URL: the endpoint `$ENDPOINT` names, and the one `ls-remote`
proved the branch on. Any other answer refuses the push, an empty one included.
Nothing is deleted, the branch stays as visible cleanup debt, and the report
names the destination that could not be proved. That comparison is made against
the URLs Git reports rather than against the redacted `$ENDPOINT` or the
reduced `$REPO`, because a redaction and a reduction each make two different
endpoints look like one.

**A stash selector is a position in a reflog, not an identity**, which is why
the drop above is three steps rather than one. Anyone who runs `git stash push`
between the report and the apply — a person in another worktree, a drainer
autostash — shifts every selector down by one, and a bare
`git stash drop stash@{0}` then destroys work this run never inspected and the
user never approved. Dropping highest selector index first covers only the
shifts this run causes itself, as each drop moves every lower selector.

Re-resolving the selector to its recorded object immediately before its own drop
refuses the item when the shift already happened. It cannot refuse a shift that
lands *between* that check and the drop, because those are two Git processes and
nothing holds the reflog still across them — so the drop is verified afterwards
as well. `git stash drop` names the object it dropped, and a dropped stash
commit stays reachable through that id, so a mismatch is put straight back with
`git stash store` and the item then fails. Nothing is lost either way, which is
the invariant that matters; the restored stash returns at the top of the list,
so re-run the census before touching stashes again rather than reusing the
selectors the report was written with.

Taking Git's index lock around both steps would close the window instead — a
concurrent `git stash push` cannot write the index — and it is deliberately not
done: creating that lock by hand blocks every other operation in the repository,
strands the lock if the run dies, and is the same hand-editing of a lock file
this workflow forbids for the drainer. A recoverable mistake is better than a
wedged repository. Record each selector and its full object id in the report
before anything is dropped.

**The expected value on `update-ref -d` is mandatory, and must be the full SHA
the report recorded.** It deletes the ref only while it still equals that value,
which is what keeps a ref another actor moved from being deleted — and an
all-zero value is not a weak guard but the opposite of one: Git reads it as
"expect no ref" and deletes unconditionally. An empty or unrecorded value is a
missing recheck, so stop and re-report rather than substituting anything for it.
A stale origin-tracking ref is deleted the same way, one ref at a time:
`git fetch --prune origin` would additionally remove every other ref that
happens to be stale, including refs this run never reported and the user never
saw.

**The worktree metadata prune is the one operation Git offers no per-item form
for**, so it is refused unless every record it would remove is approved:

```bash
LISTING="$(mktemp)"
STATUS=0
git -C "$ROOT" worktree prune --dry-run --expire now --verbose >"$LISTING" 2>&1 &&
  UNAPPROVED="$(sed -n 's#^Removing worktrees/\([^:]*\):.*#\1#p' "$LISTING" \
    | grep -vxF "$APPROVED_RECORDS" || :)" &&
  [ -z "$UNAPPROVED" ] &&
  git -C "$ROOT" worktree prune --expire now || STATUS=$?
rm -f "$LISTING"
[ "$STATUS" = 0 ]
```

`$APPROVED_RECORDS` is the newline-separated list of record names the user
approved, and an empty one refuses every prune. A record the dry run names that
is not on that list stops the prune: report the unapproved records and ask,
rather than pruning them because they happened to be in the way.

Three details in that block are load-bearing. **`2>&1` is not tidiness:** Git
writes the `Removing worktrees/…` diagnostics to *stderr*, so a pipeline reading
stdout alone sees an empty listing, subtracts nothing from it, and prunes every
record including the ones nobody approved — a gate that reads as one and is not.
**It is one `&&` chain** so the prune is unreachable unless the dry run
succeeded and the subtraction came back empty; a plain sequence of lines would
run the prune anyway in a shell without `set -e`, which is most of them. And the
listing goes through `mktemp` rather than a pipe so the dry run's own exit status
is what the chain tests: a failed dry run produces no matching lines either, and
would otherwise read exactly like "nothing unapproved". The `|| :` is only for
`grep`, which exits non-zero when it matches nothing — here the good case, since
that means no record was named that the user did not approve. `rm -f` sits
outside the chain so the temporary listing is removed on the refusing path too,
and it is written outside the audited checkout, as `fix` and `finalize` write
theirs — with the chain's own status carried around it in `$STATUS` and
re-raised afterwards, so a cleanup that succeeds cannot report a refusal as a
success. `$UNAPPROVED` still holds the offending record names at that point:
name them.

**Releasing a stale claim is two independent commands**, because a claim is an
assignee *or* a `wip` label and may be either, both, or several assignees:

```bash
gh issue edit "$ISSUE" -R "$REPO" --remove-assignee "$ASSIGNEE"
gh issue edit "$ISSUE" -R "$REPO" --remove-label wip
```

Run the first once per assignee the census recorded, and the second only when
the issue actually carries `wip`. A label-only claim runs the second alone: a
single combined command would pass an empty assignee and fail before it reached
the label, leaving the claim exactly as it was. A claim with several assignees
needs one removal each, rather than one call that drops the first and reports
the claim released. Neither command touches issue content or approval labels.

The default fast-forward runs in the worktree that actually has the default
branch checked out, resolved from the porcelain listing rather than assumed to
be `$ROOT`:

```bash
PRIMARY="$(git -C "$ROOT" worktree list --porcelain \
  | awk -v want="branch refs/heads/$DEFAULT" '/^worktree /{p=substr($0,10)} $0==want{print p; exit}')"
[ -n "$PRIMARY" ]
git -C "$PRIMARY" merge --ff-only "origin/$DEFAULT"
```

After all approved actions, rerun the census and report applied, skipped,
failed, and remaining items. Do not turn a partial failure into broader
cleanup.
