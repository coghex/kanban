# Changelog

Releases appear newest first. Each release is a `##` heading whose text is
exactly that release's package version, and the release's notes run from that
heading to the next `##` heading or the end of the file. That is the whole
boundary rule: a release section can be extracted by its version string alone,
with no trailing marker and no other convention to remember.

A change that has merged but not yet shipped gets its entry in the
`### Unreleased` section above the newest release. Its level-three heading
keeps it invisible to the release machinery, which reads only `##` headings.
Cutting a release is what promotes it: the `### Unreleased` heading is
replaced by `## <version>`, and a fresh empty `### Unreleased` section is
created above it.

### Unreleased

- `kanban --mission <id>` advances exactly one mission in the foreground and
  then exits. It operates only on the mission it was named — a missing,
  malformed, unknown, or repository-mismatched identifier is reported as
  itself and never resolves to a different mission — and it selects nothing:
  repository-wide mission selection and unattended scheduling remain
  unimplemented. The mode is chosen after every observational mode and before
  the dashboard, so an invocation that also names `--doctor`, `--usage`, or a
  well-formed `--ping` runs that mode and starts nothing, while a malformed
  `--ping` still refuses ahead of both. It takes no board lease, so it runs
  beside an open dashboard; what it takes is that mission's own advancement
  lease, which refuses a second runner cleanly while leaving an attached
  dashboard free to read the record and submit ordinary operator commands.
  Every external effect is journaled and flushed before it is attempted and
  the target is reread immediately before it, so a crash leaves an outcome
  nobody observed rather than an effect nobody recorded, and a target that
  moved in between is a typed stale-version result with nothing mutated — a
  result the owning action enforces too, since the recorded version travels
  with the request and is compared against the registry's own read at the last
  instruction before it starts anything, and again inside the worker it
  launched — and inside the repository review host before it starts a
  canonical review or a revision — just before the agent session that will
  mutate the target begins. A target that moved, or that cannot be read at
  all, stops the turn without mutating anything; the first is replanned and
  the second is an unknown outcome the mission waits on rather than a step
  that failed. The two effects with no step record of their own are recovered
  from the same journal: a registered child's launch records the parent it was
  asked for by, so a crash before the session write puts the child back under
  that parent, and an open subtree termination is closed only when every
  registered session under it can be observed to have ended — anything less
  halts the mission for direction instead of signalling twice. A collected
  worker record reads as an unknown ending rather than a clean one, so a
  parent never settles over a child whose outcome is no longer there to read.
  The run's own
  terminal is its authenticated console: a line typed there is handed to the
  controller inside the process, never written down, and can pause or resume
  the mission, resolve an unknown outcome, end a registered subtree, or
  register a child against a named item, while a redirected standard input is
  never read and a command that arrives as a file carries no override authority
  at all. A run that blocks stays at that terminal and asks what to do rather
  than exiting past the only person who can answer; end of input, or the word
  for it, ends it. Resolving an unknown outcome releases the launch record as
  well as the step, so the recovery pass does not undo the answer. What a
  finished worker achieved is decided by the action registry rather than by the
  runner, so a clean exit that produced no attributable pull request and an
  issue action that published no verdict are not reported as work done; a
  registered action that owns no worker is answered in the iteration that
  dispatched it, whether a plan step or a registered child asked for it; a
  child's own end is judged through the action its launch recorded rather than
  by its exit code; child requests are deduplicated by an identity that keeps
  the parent and the request distinguishable; and a target that reached a terminal state between the
  controller's reread and the registry's resolution is a stale plan rather than
  an unresolvable target. The run ends when the
  mission is terminal, paused, or blocked, and reports the transitions it
  made. It never merges a pull request, applies a verdict label, or reports an
  indeterminate result as a success — and never reads a target's absence from
  the open board as one.
- A new `[timeouts]` key, `worker_deadline_seconds`, sets the deadline every
  action worker records at launch — solve, pull-request, issue-host,
  issue-action, and every registry-dispatched worker alike. Omitting it keeps
  the four hours (14400 seconds) that were previously fixed in the code. The
  accepted range is 1 through 604800 seconds (seven days); zero, a negative
  value, and anything above that maximum fail startup naming the full key
  path. Editing it affects only workers launched afterwards: one already
  running keeps the bound its own durable specification recorded.

- A report or design document processed before it has ever been on the
  publication branch now takes its first disposition instead of stranding the
  run. `publish_coordination_doc.py --check-pending` reports the document's
  `working_copy_blob` beside `publication_tip`, publication accepts it back as
  `--expected-working-copy`, and a document absent from the tip is applied over
  the working copy the preflight observed — a fifth named write outcome,
  `applied-over-preflight-copy`, recorded exactly like the two existing applied
  ones — while a copy that moved since, a binding that was not passed, or a
  file that does not exist still writes nothing. The binding guards every
  write to such a document, a continuation over the helper's own recorded
  predecessor included, so a run prepared over an older copy cannot overwrite
  a newer disposition recorded in between. `tracker_transaction.py
  --resolve --source local` no longer refuses a document merely for being
  absent from the tip; the lane check and the applied record decide, so a
  novel document the module never wrote is still refused and one with a lane
  still resolves on the branch only. `process-report`, `process-design-doc`,
  and `note-problem` in both bundles extract and pass the binding and name the
  five cases. Observed on a consuming repository whose documents accumulate in
  the docs worktree until a batch landing, where every first disposition hit
  it (#605).
- Every settled footer notice now disappears on its own ten seconds after it
  settles, instead of sitting in the yellow line until an unrelated press
  cleared it. The rule covers every producer and severity alike — startup
  diagnostics, refusals, errors, action and service results, `Claude usage
  refreshed` — while a notice that explicitly reports an operation the
  application still tracks in progress (a running board or usage refresh, a
  service start or stop, a direct merge, a settling quit) stays for as long as
  that operation does and takes its ten seconds from the moment it settles.
  The expiry arrives as an ordinary application event from a local one-shot
  timer, so the footer redraws and a fullscreen overlay reclaims the rows the
  notice held even when nothing else is happening; `Esc` and every existing
  clearing interaction still dismiss a notice early. The startup line's
  diagnostics — an invalid cache, a settings problem, an authority notice, a
  degraded roster entry — are reported nowhere else, so they now genuinely
  ride the loading fragment until the first board publication: startup's own
  refresh announcements, a usage result, and a history pause compose onto
  the line instead of replacing it, and the first outcome carries the
  diagnostics behind its own notice for the ordinary ten seconds before
  retiring them. Each displayed notice is
  its own instance, so a replacement — identical text included — always gets a
  full new lifetime, an expiry armed for an older instance can never remove a
  newer one, and the direct-merge result carry is now keyed to the instance it
  last wrote rather than to text a later notice could repeat. The notice line
  itself became an abstract lifecycle state (`Kanban.UI.Notice`), which is
  what keeps any future producer from bypassing the rule.

- The six document workflows that hand a document to
  `publish_coordination_doc.py` — `/process-design-doc`, `/process-report` and
  `/note-problem` in both brands — now report the ordinary publication outcome
  by saying nothing about it. A repository whose
  `workflow.direct_publication_paths` is empty is the intended configuration,
  and on that outcome the helper returns `not-published` with the approved
  mutation applied to the working copy and recorded. Each run used to narrate
  that in full — which outcome it was, why publication was declined, the write
  root, the document path, the preserved blob — so one session processing three
  entries of one design document emitted the whole apparatus three times, and a
  working mechanism read like a recurring problem.

  Only the closing report changed. The helper is still invoked, its result is
  still inspected, and the tracker transaction is still resolved before the run
  closes; a run whose transaction could not resolve keeps its full failure and
  recovery report however ordinary the publication result was. Every other
  publication outcome keeps its full report too — an unwritten or unrecorded
  one because the mutation is not where the next run will look for it, a
  published one because it carries a changed-line summary the run has to check,
  and an unmodelled status because its three states are the only account of
  where the document went.

- A new packaged workflow, `/autosolve` (Codex: `$autosolve`), runs `/solve`
  for one GitHub issue and then drives up to five opposite-brand review rounds
  — `/pr-review` in round one, `/pr-rereview` after each pushed fix — until the
  pull request carries `reviewed:approve`. It never reviews, comments on,
  labels, merges, or finalizes the pull request it authored; approval is where
  the run ends and the merge stays a deliberate manual step.

  It is the eighth and last of the workflow commands issue #373's arc vendors,
  so with it every personal copy of a Kanban workflow command is retired and
  every one of the eight is authored once in `tools/command_sources/` and
  rendered into both bundles.

  It is also the only slice in that arc the Claude copy won. Four things lived
  only there and now ship in both brands: the preamble establishing that
  `/solve` and the review workflows are delegated sub-steps whose own terminal
  stop conditions do not end this run; the explicit override of `/solve`'s
  `## Stop Condition`, whose `PR #<number> - <summary>` line is the handoff
  into the review loop rather than a final answer; the `--self-review`
  override, with the route confirmation that makes it checkable; and the
  failure case for a published marker whose `reviewers` names this session's
  own brand rather than the opposite one.

  Every claim that depends on which brand is solving is rendered per brand
  rather than as shared prose — the origin marker the pull request must end
  with, the brand its marker routes the review to, the route the coordinator's
  `--dry-run` must report beforehand, and the `reviewers` value the published
  `pr-review:v2` marker must carry — so neither rendering can tell its reader
  to expect the other brand's marker. The `--self-review` override stays in
  this workflow alone: neither review workflow is amended, and the coordinator
  guard issue #303 added already refuses an absent or mismatched
  `--self-review-as` before any spawn, publish, or label switch, so the
  instruction is belt-and-braces over an enforced guard rather than the only
  thing preventing a same-brand publication.

  Two reconciliations against this repository travel with it. The worktree
  root is spelled `${WORKTREES_ROOT:-$HOME/worktrees}`, as
  `docs/agent-workflow-contract.md` and both shipped `solve` assets spell it,
  so a session with the variable unset resolves the directory `/solve` actually
  used rather than one rooted at nothing. And the repository identity is
  resolved once, announced before anything is claimed, and carried by every
  `gh` call and by the coordinator invocation, which neither personal copy did.

- A new packaged workflow, `/janitor` (Codex: `$janitor`), audits one
  repository's agent-pipeline state and cleans up only what the user approves:
  stale claims and issue worktrees, every registered worktree, workflow
  branches and refs, pull-request and drainer health, stashes and drainer
  recovery objects, stray content, and default-branch drift. It reports first
  and mutates nothing until individual items are approved.

  It reasons over the `janitor-census/v1` snapshot the `scripts/census.py`
  helper vendored into both bundles emits, rather than hand-walking the
  repository. Each brand resolves that helper from its own install location —
  `${CLAUDE_PLUGIN_ROOT}/scripts/census.py` for Claude, a search under
  `${CODEX_HOME:-$HOME/.codex}/plugins/cache` scoped to this skill's own
  `scripts/` for Codex — and a helper that cannot be resolved stops the run
  before its first read rather than after it, since every judgement the
  workflow makes is made over that document.

  A `null` or unavailable collection in the census is an anomaly to diagnose,
  never a clean or empty result: an unreadable worktree is not a clean one, and
  an unreadable retain ledger is not an empty one. The repository-local
  retention ledger is a reminder rather than an exemption — every recorded
  target and its `review_when` condition is revalidated on each run, a stale or
  contradicted entry is reported as a decision, and no ledger entry is written
  before explicit approval.

  Bulk `all-safe` approval covers exactly five fully-proved gates — worktree
  removal, branch deletion, review metadata prune, tracking-ref prune, and the
  default fast-forward — and each names the near-miss that most often reads as
  a pass: a worktree whose only dirt is untracked files, a tip merged into the
  local default but not the remote one, a prune the `--expire now` dry run does
  not name, a `refs/remotes/` entry that proves nothing on its own, and a
  default branch that is ahead or diverged. Dirty or unmerged work, limbo
  worktrees, permanent-worktree content, every recovery object, coordinated-test
  worktrees, and any ambiguous disposition are excluded from bulk approval and
  always need item-level say-so.

  Every apply-path command reaches the approved item and nothing else, because
  a partial approval is the ordinary result. Remote branch deletions go one
  push per branch — one already-gone branch name aborts an entire multi-branch
  `git push origin --delete` client-side, so nothing gets deleted while the
  report reads as though everything did — and each carries the proved SHA as a
  `--force-with-lease`, so a branch someone pushed to after the `ls-remote`
  proof is refused rather than losing work nothing reviewed. A stale
  origin-tracking ref is deleted by name with its recorded value rather than
  through `git fetch --prune`, which would also remove refs the run never
  reported. `git worktree prune --expire now` is the one operation with no
  per-item form, so it is refused unless every record its dry run names was
  approved — a gate that reads the dry run's `stderr`, where Git actually
  writes it, and that is one `&&` chain so the prune is unreachable in a shell
  without `set -e`. A stash is dropped only while its selector still resolves
  to the object the report recorded, and the drop is verified afterwards
  against the object Git says it took: a selector is a position in a reflog, so
  anyone pushing a stash in between shifts it, and dropping `stash@{0}` would
  destroy work the run never inspected. A mismatch is restored with
  `git stash store` before the item fails, so the remaining window between the
  check and the drop loses nothing. And releasing a stale claim is two
  independent commands, since a claim is an assignee *or* a `wip` label: a
  label-only claim needs the label removal alone, and several assignees need
  one removal each.

  The census helper both bundles ship now passes `--no-prune` on the `--fetch`
  refresh. `fetch.prune` is an ordinary configuration, and under it that
  refresh would have deleted every stale origin-tracking ref during the
  read-only pass — before one was reported, let alone approved — which is the
  opposite of what the per-item deletion gate above exists for.

  A stash is judged by its own delta rather than by diffing its
  files against the current branch, with list numbering, emphasis, and
  whitespace normalized, and a line that never landed may be superseded rather
  than missing. The repository is resolved once from the session's checkout,
  announced before the first census run, and passed as `-R "$REPO"` on every
  `gh` call.

- A new packaged workflow, `/finalize` (Codex: `$finalize`), is the manual
  fallback for merging one reviewed pull request when the service-managed PR
  drainer cannot be used. It is not the ordinary merge path and is never taken
  on an agent's own initiative: `tools/drain_prs.py` keeps owning eligible
  merges, and every other packaged workflow still stops at the open pull
  request. `finalize` runs on the pull request the user names, in the turn the
  user asks for it.

  It takes one positive pull request number and checks that it is one before
  reading anything: `gh` accepts a branch name or a URL wherever a number goes,
  so an unvalidated target would let `/finalize some-branch` merge whatever pull
  request that branch has open.

  It finalizes a pull request onto the repository's **default branch** only. A
  pull request can be retargeted to a different base without its head moving,
  which leaves the approval label and the head-bound marker both current while
  the reviewed code would land on a base nobody reviewed it against — the
  review gate workflow strips the label on a push and never on a retarget, and
  the marker records no base to compare with. A stacked pull request onto a
  feature base is deliberately out of scope.

  One window is accepted rather than closed, and documented as such: the base
  is re-read immediately before the merge, but `--match-head-commit` binds only
  the head and has no base counterpart, so a retarget in that last instant
  lands the reviewed head on the new base. Closing it would mean advancing the
  base reference directly with a compare-and-swap rather than asking GitHub to
  merge — a remote write this workflow deliberately does not make — and
  `tools/drain_prs.py` merges with the same call and the same binding
  unattended, so the exposure is the merge primitive's rather than this
  workflow's. The base actually merged onto is named in the report.

  Its gate fails closed and is evaluated twice — once to decide, and again
  immediately before the merge, because labels, the head, and the check set are
  all mutable. It resolves the authenticated GitHub login, reads the whole
  paginated comment feed rather than a bounded window — through a temporary
  file outside the checkout, since that feed is the one unbounded input and an
  argument long enough to carry it exceeds the system limit on exactly the long
  pull requests the pagination exists to read — and requires the
  globally newest marker that login published to name the pull request's
  current head with `verdict=APPROVE`. That marker is the `pr-review:v2` shape
  the review coordinator publishes today, comma-joined `reviewers=` and
  `models=` fields included, with the legacy `pr-review:v1` spelling still
  honoured; a marker authored by anyone else, a malformed one, a stale head,
  and a non-`APPROVE` verdict each refuse. The marker's reviewers must also
  exclude the pull request's own brand — read off the body by exactly
  `originFromBody`'s rules — because an approval published by the brand that
  wrote the code is a self-review that the marker alone cannot reveal; a body
  declaring no origin is the coordinator's dual route, where only a marker
  naming both brands is known to be independent. Beyond the marker, the pull
  request must be approved under the repository's *own* configured
  `approval_mode`, by its own configured `approval_label` or GitHub's
  `reviewDecision`, with the configured changes-requested and blocking labels
  absent — the same global-then-per-repository resolution the coordinator, the
  drainer and the board make, so a repository that renamed its verdict labels
  is read correctly rather than having every approval refused. A `mergeable`
  that is not exactly `MERGEABLE`, a merge state that is not ready, and any
  check that is not successful refuse too. Readiness mirrors Kanban's own
  `mergeStateReady`: `CLEAN`, and a `BLOCKED` state on a `MERGEABLE` pull
  request, which is the branch-protection requirement `--admin` clears.
  `BEHIND` and `UNSTABLE` refuse — `mergeable` says whether a merge would be
  clean, not whether it should happen now, and a head that has not seen its
  base tip belongs in `/fix` and the drainer's branch-update-and-rereview path
  rather than here. A refusal merges nothing, closes nothing, removes no
  worktree, and deletes no branch.

  It merges with `--admin --merge --match-head-commit`, the same call the
  drainer makes, and never `--squash`, `--rebase`, or GitHub auto-merge —
  arming a merge on a head whose checks have not passed is a mutation the gate
  forbids. The linked issue, the pull request's worktree, its branch, and the
  local default branch are only touched after GitHub confirms the pull request
  as `MERGED`.

  It deletes no **remote** branch, and writes to no git remote at all. A
  repository with `delete_branch_on_merge` has GitHub remove the head branch as
  part of the merge, and `tools/drain_prs.py` removes it after its own merges,
  so what a remote deletion here would have added is tidiness — against several
  ways to delete the wrong branch, since the repository identity comes from the
  remote's fetch URL while `git push` follows the multi-valued
  `remote.origin.pushurl`, every one of those URLs receives the push, and a URL
  reduced to an `owner/name` has lost the host it was going to. Where neither
  GitHub nor the drainer removes it, the merged branch stays as a visible,
  reversible leftover.

  The local cleanup is one `&&` chain, so a failed worktree removal, fetch, or
  fast-forward ends it rather than being stepped past into the deletion. A
  cross-repository head is never deleted here under a same-named branch of the
  base repository, and the local base branch is advanced only when the primary
  checkout is on it. The local branch deletion is bound to the reviewed head
  rather than to the branch name — `git update-ref -d <ref> <old-value>` — so a
  branch another actor deleted and recreated under the same name is rejected
  rather than removed. The worktree it removes is identified the same way — the one
  whose checked-out branch is the pull request's head branch and whose `HEAD` is
  the reviewed head, read out of `git worktree list --porcelain` rather than
  matched against a path pattern that a stale worktree of the same number style
  would satisfy. The linked issue is selected the same way: closing references
  carry the repository they belong to and issue numbers are repository-local,
  so only a reference naming this repository is closed and one pointing at
  another repository is skipped rather than turned into a same-numbered issue
  here. It is authored once under `tools/command_sources/` and rendered
  into both bundles, and `CLAUDE.md` and `docs/agent-workflow-contract.md`
  §2.10 now record it as the single explicitly-invoked exception to the
  never-merge rule.

- A new packaged workflow, `/fix` (Codex: `$fix`), clears the one remaining
  obstacle in front of an **already-approved** pull request. It refuses a pull
  request that is not approved under the configured `approval_mode`, and one
  whose `pr-origin` marker names the other brand — the rereview is routed from
  that same marker, so fixing another brand's pull request would end in a
  same-brand review of one's own change. It then resolves a merge conflict,
  updates a branch that is behind its base, or fixes a failed check, pushing at
  most one focused commit and handing off exactly one canonical rereview.

  Everything else fails closed rather than guessing. A check rollup that cannot
  be read completely — GitHub truncates its context list, or an entry will not
  decode, both `ChecksUnknown` to Kanban — stops the run ahead of every branch
  that reads it, since not seeing a failure is not the same as there being
  none. A merge conflict is decided without any check state and so precedes it,
  and resolving one replaces the head that the checks then re-run against. A `BLOCKED` or `UNSTABLE` merge state is reported rather
  than "fixed" by a branch update that cannot clear it, and a still-running
  check stops the run rather than replacing an approved head mid-CI.

  It never retries a check. `tools/drain_prs.py` already reruns a failed
  required check on an approved pull request, keyed to the approved head and
  quarantining it once the allowance is spent; a second rerunner with its own
  ceiling would mean two components disagreeing about the same pull request.

  It runs only on an explicit request to fix or unblock: asking why a pull
  request cannot merge is answered by reporting the obstacle and stopping,
  since a diagnostic question authorises none of the pushes or rereview it
  would otherwise perform. It is authored once under `tools/command_sources/`
  and rendered into both bundles.

## 1.1.0.0

Kanban gains a card filter panel, a settings overlay that edits its model
roster, an operating mode derived from the providers that roster loads, Linux
support for both background services, an issue approval service, and a
documented upgrade path. Two changes affect anyone moving from 1.0.0.0, and
they come first.

### Upgrading from 1.0.0.0

- Kanban publishes no Haskell library. The implementation modules are a
  private `kanban-internal` component, so a package that depended on `kanban`
  and imported `Kanban.*` no longer resolves against this version. Kanban's
  supported interfaces are the `kanban` executable and its command line, the
  documented configuration files, the on-disk compatibility surface, the
  installers under `tools/`, and the workflow contracts under `docs/`;
  importing the implementation was never among them.
- `Kanban.CLI.Options` gained an `optionPing :: [String]` field, positioned
  between `optionJson` and `optionAscii`. Code that constructed that record
  positionally, or matched it exhaustively, no longer compiles. Together with
  the withdrawn library above, that is why this release is a major bump.
- Nothing a user installs changes shape. [Upgrade to a new
  release](README.md#upgrade-to-a-new-release) is the ordered procedure: what
  to stop, what to re-run from the new archive, what to verify with the check
  that can actually observe it, and what is preserved across the move.

### The board

- Press `F` for a card filter panel. `j`/`k` or `Up`/`Down` move between its
  boxes, `Left`/`Right` between groups, `Space` toggles the focused box, and
  `d` restores the defaults. Its criteria combine with the `s` column search
  rather than replacing it.
- A live-agent overlay's sessions take the keyboard the way vim does. Each
  session opens in normal mode, where `i` starts insert, `j`/`k`, `g`/`G`, and
  `Ctrl-D`/`Ctrl-U` scroll its transcript, `1`-`9` answer a pending numbered
  choice, and `q` hides the overlay without interrupting its work. Insert mode
  edits the draft; `Enter` sends it and returns to normal, and `Esc` returns to
  normal without sending. `Esc` stages one step at a time — insert to normal,
  normal to hidden — and never reaches the dashboard's guarded quit. `Tab`
  moves between sessions and leaves each in the mode you left it in.
- The footer's hint line names the keys of whatever surface currently holds
  the keyboard, including every open overlay, rather than always listing the
  board's. It is the dashboard's one context-aware hotkey row.
- A card's top and bottom border runs are drawn in color rather than the
  terminal's default, so the whole border now follows the rule its corners
  already did: an unselected card's border is its status color throughout,
  and on the selected card the left, top, and bottom edges take the selection
  color while the right edge and the corners on it keep the status color.
- One board per repository. A second dashboard on the same GitHub repository
  is refused before it draws a frame, naming the repository and the process
  already holding it. The claim is keyed by the repository rather than by the
  checkout path, so two clones of one repository contend and two spellings of
  its name — `Coghex/Kanban` and `coghex/kanban` — are recognized as the same
  one. The cached `gh` record is now keyed the same way; a record an earlier
  version left under the old case-sensitive name is carried across on the
  first run that can claim it. Only the dashboard takes the claim: `--doctor`,
  `--usage`, `--ping`, and `--glyph-test` are unaffected.

### Agent actions and models

- Kanban's operating mode follows the providers `models.toml` actually loads:
  two is dual, one is single-agent, and none — an empty `agents` list, or a
  file that will not load at all — is no-agent. In no-agent mode the four
  bindings that start agent work, `r`, `S`, `A`, and `a`, leave the footer,
  the card details footer, and the help overlay, and pressing one says which
  mode is in effect instead of starting anything. `p` and `x` stay on all
  three surfaces in every mode, so work an earlier run left running is still
  visible in the process inspector and terminable there, and `u` still updates
  the board while spawning no usage provider. The settings overlay names the
  derived mode on a read-only line.
- The settings overlay `o` opens now edits the model roster as well as
  chat-output verbosity: `j`/`k` or Up/Down pick an assignment, `h`/`l` or
  Left/Right cycle its model, `[`/`]` cycle its effort, and `d` restores the
  picked assignment's default — or repairs a roster too broken to launch
  anything. An edit is saved to `models.toml` under Kanban's XDG
  configuration directory — `~/.config/kanban/models.toml` unless
  `XDG_CONFIG_HOME` names another root — and the running board moves to what
  was saved only once that write succeeds.
- The PR drainer runs on Linux: a systemd user-unit backend joins the macOS
  launchd one. Its install directory, discovery record, runtime state, and
  logs follow each platform's own convention — `~/Library` on macOS, the XDG
  data and state directories on Linux — and an older Linux installation made
  under the `~/Library` shape is relocated to the XDG locations by the next
  default operation.
- An issue approval service keeps the canonical issue reviews moving without
  a terminal left open: installed per repository with
  `python3 tools/install_issue_approval.py` as its own managed job — launchd
  on macOS, a systemd user unit on Linux — it repeatedly advances the open
  backlog one bounded pass at a time, and Kanban discovers and monitors the
  installation beside the drainer's.
- Press `a`, or click the `approve_issues.py` control the sidebar draws beside
  the drainer's, to start or stop that approval service from the board, the
  same way `d` starts and stops the PR drainer.

### Usage

- Each usage window in the sidebar now shows how long until it resets and the
  wall-clock time it resets at, and each provider's name carries the age of
  the numbers under it, so a snapshot restored from a previous session is
  distinguishable from a fresh one.
- A clickable `↻` control in the sidebar starts the same board-and-usage
  update `u` does.
- Tell Kanban roughly what one solve round costs a provider — the
  `estimated_percent_per_solve_round` key in `config.toml` — and the sidebar
  converts each usage window's percentage left into the number of solve
  rounds it still buys.
- `kanban --ping codex` (or `claude`) deliberately starts that provider's
  usage window with one minimal paid request, so a window you are about to
  spend has its full duration ahead of it. Nothing else ever starts a ping,
  and a failed ping is not retried.
- The Claude usage probe and the process census are now correct with the
  util-linux `script` and procps `ps` that Linux ships as well as the BSD
  flavors on macOS, so the usage sidebar reads right on both platforms.
- The Claude usage probe no longer leaves a `claude` process behind when the
  probe fails partway through. The recursive process-group cleanup that
  already covered the timeout and missing-pipe paths now also covers the
  exception path between them.
- Two Kanban processes on one machine no longer lose each other's usage
  numbers. A cached refresh is merged into whatever the snapshot file already
  holds, under a lock taken for that read-merge-write alone, so a slow probe
  in one process cannot roll back a window another process just recorded, and
  an older reading never replaces a newer one.
- The usage sidebar's percentage row stays inside the sidebar whatever it has
  to show: a provider label too wide for its field is cut with the same
  ellipsis a card's elided line carries, rather than pushing the bar and the
  percentage off the edge, and the percentage is right-aligned so one, two,
  and three digits share a column and `100%` still reads in full.

### Installing, upgrading, and configuring

- The documentation carries an ordered release-to-release upgrade path. The
  README's new upgrade section unpacks the new archive beside the old one,
  installs the executable, inventories what is installed and which service jobs
  are running, stops those jobs, moves a provider marketplace off the old
  archive, re-runs each installed component's setup from the new one, verifies
  every advertised component with the check that can actually observe it,
  restarts only what was running, confirms nothing still resolves through the
  old archive, and removes it last — with the reason each step sits where it
  does and a statement of what is preserved and what is deliberately rewritten.
  Every support-table row now has named install, upgrade, verification, and
  removal guidance, including a removal path for the PR drainer and for the
  executable itself.

- The optional setup commands run from an unpacked release archive. None of
  them asks that tree for Git metadata, which a `cabal sdist` archive
  deliberately does not carry. The two that install a background service take
  `--repo` for the checkout the service is for and a new `--asset-root` for
  the tree their links point at; run from an archive with no `--repo`, they
  refuse and say so rather than installing a job against the archive.
  `tools/setup_workflows.py` likewise needs `--target` for a project-scoped
  provider registration when its asset root is not itself a checkout.
  Re-running any of them from a newer archive re-points the links a previous
  archive left, while still refusing to touch a file that is not Kanban's own.

- A `[repositories."owner/name"]` table may now carry `path`, the absolute
  path to where that repository is checked out on this machine, which puts it
  in the repository roster Kanban resolves at startup. It is not an override:
  a table without it is an override table and nothing more, so an existing
  configuration gains no roster entry by upgrading. A relative value fails
  startup — nothing expands `~` — while a path that is missing, unusable, not
  a Git checkout, or a checkout of some other repository is reported in the
  dashboard's startup notice and never blocks the launch.

### The project

- The repository carries a public contributor baseline: `CONTRIBUTING.md`,
  `SUPPORT.md`, `SECURITY.md`, and `CODE_OF_CONDUCT.md` at the root, GitHub
  issue templates for bug reports, feature requests, support questions, and
  the tracker's own shapes, and a pull-request template. `README.md` names
  where to ask a question, where to report a vulnerability, and which platform
  each installable component is supported on.
- [Releasing and maintenance](docs/releasing.md) documents how a release is
  cut, verified, and published, and `docs/issue-approval.md` documents the
  issue approval service.
- The tracked workflow bundles that `tools/setup_workflows.py` installs carry
  eight more commands: `triage`, `retriage`, `backlog-review`, `draft-report`,
  `note-problem`, `project-review`, `drain-prs`, and `push-docs`.

## 1.0.0.0

Kanban is a terminal board for a GitHub repository. It sorts that repository's
issues and pull requests into four columns — Issues, Active, Reviewing, and
Done — and lets you work them with the keyboard or the mouse without leaving
the terminal.

Version 1.0.0.0 is Kanban's first release, so the notes below are a curated
overview of what it does rather than a list of changes. Per-change entries
begin with the next release. Written 2026-08-13.

### The board

- Four columns: **Issues** (open and unassigned), **Active** (assigned),
  **Reviewing** (draft or unapproved pull requests), and **Done** (approved
  pull requests still open). Issues and pull requests stay separate cards, so
  an issue does not vanish because a pull request exists for it.
- Epics group related work and expand or collapse with `e`. Membership comes
  from a `Children` or `Phase` checklist in the epic body when there is one,
  and otherwise from GitHub's native sub-issues, so a repository that uses the
  Add sub-issue button needs no Markdown conventions. An epic with neither is
  shown with a warning that says what is missing.
- `s` searches a column by number and title, and the search can be moved
  between columns without retyping.
- `Enter` opens card details; `j`/`k` and `h`/`l` move between cards and
  columns; `?` lists every control. Mouse selection, scrolling, and details
  work throughout.
- Kanban loads its last saved board at startup and then requests fresh data.
  It does not poll: `u` is how you ask for an update.
- The layout responds to the terminal size, and color and border treatment can
  be set for terminals that need it.

### Agent actions

Optional, and inert until you install their components:

- `S` works an issue and opens a pull request. `r` reviews the selected item,
  starts the revision or rereview when changes were requested, and repairs an
  approved pull request in Done that has a merge conflict, a failed check, or a
  blocking label. `A` runs work, review, and revision as one loop. None of
  these merges anything.
- Reviews are cross-brand: work produced by one provider is reviewed by the
  other, against a canonical readiness gate rather than an ad-hoc opinion.
- Jobs run beside the board. `p` opens the job window, `Esc` hides it, `x`
  stops a job, and a job that asks a question can be answered in place. Most
  jobs survive closing Kanban and are reconnected when you reopen the same
  repository.
- `cabal run kanban -- --doctor` reports whether each action is ready and names
  the command that installs whatever is missing.
  `python3 tools/setup_workflows.py --all --scope user` installs the
  components, and reports exactly what it would do before changing anything.

### Attention and usage

- `i` lists everything waiting on you — open drainer incidents and every job
  that failed, was stopped, or is waiting for an answer — and `Enter` goes to
  the work. The list only reads; nothing in it resolves or retries anything.
- A sidebar shows the available Codex and Claude usage windows, refreshed on
  `u` and hidden with `c`. One provider failing does not stop the other or the
  GitHub board from updating.

### Optional PR drainer

- A per-repository background job that merges pull requests once they are
  approved and their required checks pass, and updates branches that are
  behind. It never resolves a merge conflict: a conflicted pull request is
  reported and left alone.
- Installed as its own macOS LaunchAgent with
  `python3 tools/install_drainer.py`, which previews the installation first.
  Installing does not start it — press `d` in Kanban when you are ready.
- `m` merges a single approved pull request from Done without the drainer.

### Installing and configuring

- Build and install from a source checkout with `cabal build all` and
  `cabal install exe:kanban`. The executable runs the board on its own; keep
  the checkout if you want the agent workflows or the drainer, whose setup
  commands install from it.
- `--path` opens another local repository, `--repo` names a GitHub repository
  explicitly, and `--no-cache` stops Kanban from reading or writing board and
  usage snapshots.
- Display settings live in `~/.config/kanban/settings.json`, workflow and
  provider configuration in `~/.config/kanban/config.toml`, and cached board
  data, logs, and job records under `~/.cache/kanban/`.
- Requirements: Git, the GitHub CLI signed in via `gh auth login`, and GHC and
  Cabal to build. Codex or Claude is needed only for the agent actions.

### Documentation

- [README](README.md) — install and first run.
- [User guide](docs/user-guide.md) — every control and behavior.
- [Workflow setup and preflight](docs/workflow-setup.md) — the agent
  components and how to install or remove them.
- [PR drainer](docs/pr-drainer.md) — the optional merge job.
- [Agent-workflow contract](docs/agent-workflow-contract.md) — what each
  action depends on.
- [Development](docs/development.md) — building, testing, and layout.

Kanban is distributed under the [MIT license](LICENSE).
