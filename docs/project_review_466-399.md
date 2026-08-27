# Project Review Findings: PRs #466–#399

This review continued below the completed #468 cursor and covered twelve
previously unreviewed merged pull requests at the frozen selection boundary
`9f0f2db`, newest-first by merge time: #466, #467, #465, #464, #406, #408,
#405, #404, #403, #402, #400, and #399. The discontinuities are deliberate:
`docs/project_review_463-455.md`, `docs/project_review_456-446.md`, and
`docs/project_review_442-411.md` already record the intervening pull requests
as reviewed, so their coverage was not duplicated.

The first-parent walk also reviewed 22 direct commits in the selected landing
intervals. Between #468 and #466 these were `ed90877`, `6d54e98`, `2e2003e`,
`b03d6e6`, `bc1a12e`, `a936022`, `aa0f7b3`, `ed91623`, `801e611`,
`909669a`, `3b230b5`, and `5b0d2b7`. Between #463 and #456 these were
`3b3c54f`, `a920f7c`, `b80f628`, `e84f732`, `65001ff`, and `331d70e`.
Between #411 and #399 these were `9e38115`, `8edae1a`, `ef9726a`, and
`76f2111`. Each was checked individually against its message, patch, adjacent
partial steps, and current descendants. The #463–#455 report incorrectly says
there were no direct commits in its interval; `7550744` and `173f1e0` were
already covered by the #456–#446 report, while the other six were first audited
here and were clean.

Each selected pull request was judged against its linked issue when it had one,
its description, commits, merged diff, current implementation, callers, and
focused tests. Later descendants were read to establish current behavior; that
trace also exposed PR #519's surviving README drift, recorded below rather than
discarded because its landing was newer than this batch. The focused checks
passed: rendered workflow assets are current; 140 project-review,
release-workflow, and screenshot tests pass; and 465 relocation, coordination
publication, drafting-workflow, document-classification, and source-distribution
tests pass with one platform skip. The repository advanced to `1544709` while
validation ran; newer pull requests remain excluded from the selected batch,
but every finding below was rechecked at that current tip.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [x] PRR-1. Clean batches leave project-review without a durable resume cursor — [#548]
- [ ] PRR-2. A stale pre-gate stop can terminate a drainer restarted after relocation
- [ ] PRR-3. The ready Mission Control design still declares closed prerequisites and its own classification absent
- [ ] PRR-4. The README still advertises the filter's retired lowercase key

## 1. Historical sweep continuity

### [#548] PRR-1. Clean batches leave project-review without a durable resume cursor

> **Captured note:** Correct PR #466 and direct design commit `a920f7c` so every
> completed project-review batch leaves an exact, recoverable endpoint even
> when the batch is clean and the user did not separately request a boundary
> write. A fresh session must not restart at the newest PRs, duplicate a
> previously reviewed range, or skip direct first-parent commits.

**Verification:** Confirmed by static trace and by this run's range selection.
The current workflow reads `docs/project_review_boundaries.md` only when it
already exists and updates it only on a separate user request. A clean batch is
forbidden from writing an empty report, so its only cursor is the completion
message in transient conversation context. Compaction recovery may use an
unambiguous report name, but the workflow does not inventory nearby reports
until after the batch has already been reviewed and a new report is being
prepared. The docs worktree currently has no boundary file.

That gap was observable twice in this run. Starting from the conversational
#468 cursor initially selected #466 through #450. Inspecting two existing
reports later established that #463 through #446 had already been reviewed.
The replacement selection then included #442 through #419, until the separate
#442–#411 report was discovered and forced a second correction to #406 through
#399. Report filenames are insufficient as the fallback the design says they
are: clean batches create none, and `docs/project_review_463-455.md` says no
direct first-parent commits landed between #463 and #456 even though the log
contains eight. Two were named by the older #456–#446 report; the other six had
never been audited until this run.

**Evidence:**

- `tools/command_sources/project-review.md:84` — the only dedicated durable
  cursor is an optional `project_review_boundaries.md`; line 91 says to update
  it only when the user separately asks.
- `tools/command_sources/project-review.md:163` — recovery is delegated to the
  last conversational range or an unambiguous report name, neither of which
  exists for a clean batch in a fresh session.
- `tools/command_sources/project-review.md:258` — nearby reports are first
  inspected after review, in the report-writing step, too late to prevent
  duplicate range selection.
- `tools/command_sources/project-review.md:339` — a clean batch writes no report
  and only says to preserve its cursor; no durable preservation action follows.
- `tools/test_project_review_workflow.py:324` and `:436` — the tests pin those
  two prose rules independently, including “updated only on request” and “no
  empty report”, but exercise no state transition in which a fresh second
  invocation resumes after a clean first invocation.
- `docs/project_review_463-455.md:3` and `:11` — the report is itself used as a
  prior-range cursor while asserting that every commit in its interval is
  PR-owned. `git log --first-parent 9b224b3..4b5c5da` shows eight direct commits:
  `3b3c54f`, `a920f7c`, `b80f628`, `e84f732`, `65001ff`, `331d70e`,
  `7550744`, and `173f1e0`.

**Handoff context:**

- **Current behavior:** `continue` is reliable only while the prior completion
  message remains in context or the user has proactively requested a boundary
  write. A fresh session after a clean batch has no durable endpoint. Reports
  can cover finding-bearing batches, but selection does not reconcile their
  coverage up front and they need not represent direct commits accurately.
- **Expected behavior:** After every completed batch, the exact oldest reviewed
  PR landing and direct first-parent endpoint are recoverable in a fresh
  session. The next invocation selects the next older unreviewed units without
  hidden chat history, an empty findings report, duplicate review, or a lost
  explicit exclusion.
- **Scope and constraints:** The observable contract belongs in the authored
  project-review source and both rendered assets, with non-vacuous regression
  coverage. The implementation may persist a dedicated cursor, inventory and
  reconcile durable coverage, or use another explicit mechanism. Preserve the
  docs-worktree write rule and do not create tracker items or empty findings
  reports as cursor side effects.
- **Verification target:** In a temporary repository, run one clean batch and
  then simulate a fresh second invocation with no conversational state; the
  second selection starts immediately below the first batch. Repeat with a
  finding-bearing report, an interleaved direct commit, an explicit exclusion,
  and overlapping legacy reports. Assert that every PR and direct commit is
  covered exactly once and a clean batch still creates no findings report.
- **Deduplication:** The open-issue inventory and searches for project-review
  cursor, clean-batch resume, duplicated history, and omitted direct commits
  found only closed issue #462, whose accepted specification introduced the
  current rules. No issue tracks this failure mode separately.
- **Remaining uncertainty:** The durable representation and its publication
  timing need a design decision; the required resume behavior and current loss
  of state do not.

## 2. Relocated controller safety

### PRR-2. A stale pre-gate stop can terminate a drainer restarted after relocation

> **Captured note:** Complete PR #406 / issue #390's stale-controller bound for
> `stop_service`: a controller that resolved the legacy installation before
> relocation must not signal the relocated drainer when that drainer is started
> again after relocation has finished.

**Verification:** Static tracing confirms a reachable current violation. The
historical-controller fixture deliberately removes #367's up-front installation
gate from `stop_service`. Its stale status path sits under the sealed legacy
runtime root and reads empty, but `status_snapshot` independently reads the
checkout's `.git/drain_prs.lock`, which is shared by the old and relocated
controllers. Once the relocated drainer is started from that checkout, the
stale snapshot classifies the live lock PID as `external`; the old stop then
sends that PID `SIGINT` before reaching a discovery-record lock, runtime guard,
or any other artifact relocation sealed.

The existing regression releases the stale controller immediately after
relocation, when relocation's precondition guarantees no drainer is running.
It therefore proves only the `already stopped` branch and declares the
signalling branch unreachable. That reasoning expires as soon as a current
controller starts the relocated job, which is an ordinary supported lifecycle
after the migration is complete.

**Evidence:**

- `tools/test_drainer_relocation.py:3145` — the pre-gate transformation removes
  the installation transaction that current `stop_service` performs before its
  snapshot.
- `tools/drain_prs_service.py:1736` — the snapshot reads the installation-bound
  status file, but lines 1742–1751 separately read the checkout lock and call a
  live lock holder `external` even when the status file is absent.
- `tools/drain_prs_service.py:1786` — the returned `drainer_pid` falls back to
  that live checkout-lock PID.
- `tools/drain_prs_service.py:2168` — after the removed gate, `stop_service`
  reads the snapshot; lines 2175–2181 signal an `external` PID before any later
  guarded write.
- `tools/test_drainer_relocation.py:3752` — the fixture relocates and releases
  the stale process immediately, with no destination restart between them.
- `tools/test_drainer_relocation.py:3893` — the test accepts a successful
  no-op and lines 3903–3908 call signalling unreachable solely because
  relocation itself refuses while a job is live; it does not cover a job
  started after relocation.

**Handoff context:**

- **Current behavior:** A pre-#367 controller bound before relocation is safe
  while the destination job remains stopped. If that job is later started from
  the same checkout, invoking the stale controller's stop path observes its
  live checkout PID and sends it `SIGINT`, mutating the relocated installation
  despite the sealed legacy location.
- **Expected behavior:** Every stale transition after relocation either refuses
  or is a verified no-op against both locations. In particular, a stale stop
  cannot signal, unload, or otherwise change a relocated job regardless of
  whether the destination job was started after relocation.
- **Scope and constraints:** Preserve current controllers' transaction gates,
  the destination controller's start/stop lifecycle, canonical repository
  identity, and PR #406's protections for install/start/uninstall, tree writers,
  record writers, definitions, and operator repair notices. The correction must
  cover bytes predating #367 rather than relying on new refusal logic in those
  bytes.
- **Verification target:** Bind the deterministic pre-gate controller before
  relocation, complete and seal the relocation, start the destination drainer,
  then invoke the bound old controller's stop. Assert non-success or a proven
  harmless refusal, the relocated process and manager definition remain live
  and unchanged, both locations and seals are byte-identical, and no signal or
  manager mutation was issued by the stale process.
- **Deduplication:** Searches for stale stop, restarted relocated drainer,
  pre-gate stop, and sealed-location stop found closed issues #378 and #390,
  which introduced the current gates and external bounds, but no issue for this
  post-relocation restart path.
- **Remaining uncertainty:** A live fixture reproduction should pin whether the
  current manager wrapper observes the child exit as a stop or restart, but the
  unauthorized `SIGINT` is reached before that distinction and is itself the
  violated postcondition.

## 3. Design readiness evidence

### PRR-3. The ready Mission Control design still declares closed prerequisites and its own classification absent

> **Captured note:** Reconcile direct landing commit `2e2003e` with the Mission
> Control design that `b03d6e6` marked ready: its current-state evidence must
> stop saying issue #425 remains open, the approval arc is only partly landed,
> and `docs/superagent_design.md` has no coordination classification.

**Verification:** The ready document contains two stale readiness claims. Issue
#425 closed on 2026-08-21 through the operating-documentation merge and epic
#318 is now closed, so the issue-approval authority is complete rather than
partly landed with documentation outstanding. More directly, `2e2003e` added
`docs/superagent_design.md` to the section 7 coordination table,
`config.toml.example`, and the source-distribution exclusion in the same commit
that landed the document; its current-state section still predicts that exact
classification as a future change and calls the file pr-atomic.

**Evidence:**

- `docs/superagent_design.md:9` — the document declares itself ready for issue
  processing.
- `docs/superagent_design.md:105` — the current-state evidence calls the
  persistent approval arc partly landed; lines 108–110 say #425 remains open.
- `docs/superagent_design.md:116` — the same current-state section says this
  design is absent from section 7 and therefore pr-atomic.
- `docs/agent-workflow-contract.md:2587` — the live section 7 table classifies
  `docs/superagent_design.md` as `coordination | audit-report`.
- `config.toml.example:218` and `tools/test_source_distribution.py:256` — the
  other two classification registries name the same document, exactly as
  direct commit `2e2003e` intended.

**Handoff context:**

- **Current behavior:** A fresh process-design-doc session is handed a document
  marked ready whose evidence says one consumed authority is unfinished and
  whose publication-lane statement contradicts the repository contract that
  landed it.
- **Expected behavior:** A ready design's verified-current-state section
  reflects the current tracker and publication classification. Historical
  sequencing may remain where explicitly dated, but it must not be presented
  as a live prerequisite or live lane decision.
- **Scope and constraints:** Documentation-only evidence refresh. Preserve the
  resolved D-1 through D-30 decisions, delivery order, stable slice keys, and
  issue-processing ledger; do not redesign Mission Control or file its epic as
  part of this correction.
- **Verification target:** The current-state section records #318/#425 as
  complete and identifies the existing coordination lane; repository searches
  find no remaining present-tense claim that #425 is open or this design is
  unclassified, and the focused findings/design-document classification checks
  remain green.
- **Deduplication:** Repository-wide open and closed issue searches for Mission
  Control design classification, superagent publication, readiness evidence,
  and #425's stale state found no issue tracking this contradiction.
- **Remaining uncertainty:** None.

## 4. Public key documentation

### PRR-4. The README still advertises the filter's retired lowercase key

> **Captured note:** Complete later descendant PR #519 / issue #513's key
> migration by changing the README quickstart from lowercase `f` to uppercase
> `F`. The changelog carries the same historical release-note spelling, but its
> audit is already owned by open release-candidate issue #541 and is excluded
> from this new finding.

**Verification:** The executable binding and both authoritative user documents
agree that uppercase `F` opens the card filter. The root README still tells a
new user to press lowercase `f`. PR #519 changed the implementation, design,
user guide, golden frames, screenshot, and screenshot provenance, but its file
list omitted both `README.md` and `CHANGELOG.md`; issue #513 enumerated ten
design lines and seven user-guide lines while omitting the public quickstart.
Open issue #543 plans to claim lowercase `f` only while an overlay is open and
explicitly preserves its no-op behavior on the bare board, so that feature will
not make the README's filter instruction true again.

**Evidence:**

- `README.md:90` — the quickstart says lowercase `f` filters the cards.
- `src/Kanban/UI/Keys.hs:198` — the only board binding for `ShowFilter` is
  uppercase `F`.
- `docs/design.md:315` — the tested section 7 contract names uppercase `F`.
- `docs/user-guide.md:98` — the user guide's keyboard table also names
  uppercase `F`.
- `tools/test_board_screenshot.py:332` — README coverage checks the screenshot
  reference, not the quickstart key table; no focused test couples that table
  to `Kanban.UI.Keys`.

**Handoff context:**

- **Current behavior:** Following the public quickstart and pressing `f` on the
  board does nothing; the filter actually opens with `F`.
- **Expected behavior:** The root README names the current board key, and future
  key migrations account for every public key table rather than only the
  authoritative design and detailed user guide.
- **Scope and constraints:** Correct the README quickstart. Leave #543's
  overlay-only fullscreen design intact. Do not duplicate #541's changelog
  audit or rewrite historical design records that intentionally describe the
  old lowercase binding.
- **Verification target:** The README quickstart says `F`; a repository search
  leaves no present-tense public instruction that lowercase `f` opens the
  board filter, while the design/user-guide key contract and focused Haskell
  key tests remain green.
- **Deduplication:** Searches for README filter key, quickstart filter panel,
  stale filter key, and key documentation found closed #348 and #513 plus open
  #543, but no issue correcting the README. Open #541 owns the analogous
  changelog entry through its required audit of every merge since 1.0.0.0.
- **Remaining uncertainty:** None.
