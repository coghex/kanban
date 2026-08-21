# Kanban product readiness findings

A collection of findings from the 2026-08-19 standing audit of this repository,
with focused evidence captured for later disposition through `process-report`.

The audit's question was not "does Kanban work" — it does, and every gate the
project defines for itself was green when this report was written. The question
was what separates a program that works from a product someone else could
depend on. Kanban is one maintainer's tool that supports `~/work/synarchy`, and
it is deliberately being raised to product standards as a practice exercise, so
"nobody else is affected" is never a disposition reason in this report.

Distinct from `docs/code-health-report.md`, which audits the source file by file
for portability and pipeline scars. This report is about the outward surface —
what a stranger reads, what the contract promises, which gates actually execute,
and the conventions this project enforces in prose but nowhere else.

Status legend: `[ ]` unprocessed · `[#N]` filed · `[no-issue]` closed without an
issue · `[deferred]` blocked on a concrete precondition

> **Scope.** Six chapters: the first impression a stranger gets (1), gates
> that do not run where they matter (2), places the design contract contradicts
> itself (3), a closed arc's apparatus left inside that contract (4), recovery
> state with no expiry (5), and the conventions a contributor cannot see (6).
>
> **Processing precondition — cleared.** This document is now a `coordination`
> document in `docs/agent-workflow-contract.md` section 7 and in `CLAUDE.md`, so
> it publishes straight to master and dispositions after the first land
> normally. It is recorded here because the hazard it describes is real and the
> clearance is what removes it: while the document matched no section 7 row it
> was `pr-atomic` to every consumer, and issue **#385** records what that meant
> in practice — a document with no publication lane could take exactly one
> disposition before its working copy stopped matching the publication tip,
> after which every later run stopped at its preflight.
>
> **Ordering note.** Chapter 3's findings are five slices of one document and
> touch adjacent lines; landing them in listed order avoids gratuitous
> conflicts. Chapter 4's PROD-15 states the rule that PROD-13 and PROD-14 are
> the first application of, so it is specified against them rather than the
> reverse. Nothing else here blocks anything else.
>
> **Motivation, recorded once so no finding has to repeat it.** Merged pull
> requests classified by what they changed ran 55 product / 28 pipeline in July
> 2026 and 19 product / 67 pipeline in August, while pipeline changes cost a
> mean 6.1 branch commits against 3.2 for product changes. Every finding below
> is on the product side of that split, and several exist precisely because the
> product side stopped being watched: `docs/ui-bugs.md` and
> `docs/drainer-bugs.md` were last touched 2026-08-07 and hold one finding each.

## Status

- [x] PROD-1. The README denies the release whose install path it documents — [#401]
- [x] PROD-2. The board screenshot predates two shipped features — [#417]
- [x] PROD-3. The repository describes itself as "my kanban" — [no-issue]
- [x] PROD-4. The changelog has recorded nothing since the release that opened it — [#418]
- [x] PROD-5. Nothing states when a release is cut, so 34 merges sit unreleased — [no-issue]
- [x] PROD-6. The screenshot gate is skipped on every CI run by that job's own design — [#422]
- [x] PROD-7. The approval-relocation example passes alone and fails in the full suite — [#420]
- [x] PROD-8. Section 3 forbids the completed-work archive section 16 specifies — [#423]
- [x] PROD-9. Section 20 still defers the merged-work history view that shipped — [#424]
- [x] PROD-10. Section 3 forbids the multi-repository board epic #354 plans — [no-issue]
- [x] PROD-11. Section 20 still defers multi-repository aggregation — [no-issue]
- [ ] PROD-12. Nothing holds sections 3 and 20 against the rest of the document — [deferred]: #423 and #424 must land first
- [x] PROD-13. The contract opens with a finished epic's processing ledger — [#428]
- [x] PROD-14. The contract closes with that epic's decisions and delivery plan — [#429]
- [ ] PROD-15. Nothing states when an arc's scaffolding leaves the document it was added to — [deferred]: #428 and #429 must land first
- [ ] PROD-16. A conflicted autostash restore preserves a stash nothing ever reaps
- [ ] PROD-17. Five stale recovery stashes sit on the primary checkout now
- [ ] PROD-18. The contribution protocol is recorded only in agent-facing instructions
- [ ] PROD-19. No issue template encodes the tracker's required body shape
- [ ] PROD-20. No pull-request template encodes the origin marker the router parses
- [ ] PROD-21. No security policy, though the project installs services and runs agents
- [ ] PROD-22. No code of conduct

---

## Chapter 1 — What a stranger meets first

Five findings about the repository's outward surface: its install instructions,
its screenshot, its one-line description, and its release record. None of them
touch behavior. All of them are the first thing anyone evaluating this project
reads, and four of the five are stale rather than wrong-by-design — they were
true when written and were overtaken by work that shipped afterwards.

### [#401] PROD-1. The README denies the release whose install path it documents

**Verification:** Verified — the README's release-archive section documents the
correct commands and then asserts, in bold, that the release those commands
download does not exist. It has existed since 2026-08-16, and it carries exactly
the asset the section describes.

**Evidence:**

- `README.md:37-38` — "**The first such archive appears when `v1.0.0.0` is
  published; there is no published release yet.**"
- `README.md:39` — "Until then, use the source checkout below." routes the
  reader away from the release path entirely.
- `gh release view v1.0.0.0` — published `2026-08-16T00:48:09Z`, `isDraft`
  false, one asset `kanban-1.0.0.0.tar.gz` at 1,631,111 bytes.
- `git tag` — `v1.0.0.0` is the repository's only tag.
- `kanban.cabal:3` — `version: 1.0.0.0`, matching the tag.
- The commands in the block immediately above the false claim
  (`README.md:42-48`) already work as written; `gh release download` with no tag
  resolves to this release.

**Handoff context:**

- **Current behavior:** A reader who reaches the supported install path is told
  in bold that it is unavailable, and is redirected to the source-checkout path
  intended as the interim fallback. The verified install artifact — the one
  `docs/development.md` and REL-4 treat as what a release consumer receives —
  is the one nobody is told to use.
- **Expected behavior:** The release-archive section states that releases exist
  and names the current one, with no interim-fallback framing. The
  source-checkout section remains, as the contributor path rather than the
  substitute for a missing release.
- **Scope and constraints:** Documentation only. Keep the existing commands —
  they are correct. Do not hard-code the version into the download commands; the
  section already explains that omitting the tag resolves to the latest release,
  and that property is what keeps the block from going stale again. Whatever
  wording replaces the claim must not need editing at the next release either.

### [#417] PROD-2. The board screenshot predates two shipped features

**Verification:** Verified and reproduced — `docs/media/board-wide.png` is the
image at the top of the README, it is rendered from a tracked golden frame, and
that frame has changed twice since the image was last rendered. Re-rendering
does not reproduce the checked-in file.

**Evidence:**

- `tools/render_board_screenshot.py:63-66` — the image at `docs/media/board-wide.png`
  is rendered from `test/golden/board-wide.txt` and `test/golden/board-wide.attrs`.
- `README.md:13` — that image is the README's only screenshot, carrying alt text
  that describes the board's contents.
- `git log -- docs/media/board-wide.png` — last rendered at `efe15b3`
  (2026-08-16).
- `git log efe15b3..HEAD -- test/golden/board-wide.txt test/golden/board-wide.attrs`
  — the frame changed afterwards in `99c5859` ("Add the `f` filter panel and
  compose its criteria with column search") and `f8cd27c` ("Let the sidebar's own
  control start the update `u` starts").
- Reproduced in isolation on master @ `d37dace`:
  `python3 -m unittest discover -s tools -p 'test_board_screenshot.py'` fails
  with `68109 != 67731 : re-rendering the golden frame no longer reproduces
  docs/media/board-wide.png`.
- `tools/test_board_screenshot.py:320` — the failing case names its own remedy:
  regenerate with `tools/render_board_screenshot.py` and review the diff.

**Handoff context:**

- **Current behavior:** The README shows a board without the filter panel and
  without the sidebar's update control, two features the same README documents
  in prose. The full Python suite is therefore red on a clean master for anyone
  with Pillow and the pinned fonts installed.
- **Expected behavior:** `docs/media/board-wide.png` reproduces byte-for-byte
  from the current golden frame, and the suite passes on a clean checkout.
- **Scope and constraints:** Regenerate through
  `tools/render_board_screenshot.py` rather than by hand — the renderer is the
  provenance, and a hand-produced image is exactly what the byte comparison
  exists to refuse. Review the visual diff before committing: the point is to
  confirm the new frame shows the two features, not merely to make the assertion
  pass. Check whether the README's alt text at `README.md:13` still describes the
  regenerated image, and update it in the same change if it does not. This
  finding is about the stale artifact; PROD-6 is about why nothing caught it.

### [no-issue] PROD-3. The repository describes itself as "my kanban"

> **Disposition:** No issue — the whole fix is one `gh repo edit` against GitHub
> repository metadata, which is not tracked content and produces no diff, so it
> cannot travel this tracker's claim → worktree → PR → drainer lane. Recorded
> here instead: set the description to `kanban.cabal:4`'s synopsis,
> "Event-driven GitHub workflow dashboard for the terminal", and the topics to
> `haskell`, `tui`, `brick`, `terminal`, `github`, `kanban`, `dashboard`,
> `developer-tools`. `homepage` stays unset: `kanban.cabal:8` declares only the
> repository's own URL, which GitHub already links.

**Verification:** Verified — the repository is public, MIT licensed, carries a
tagged release and a README written for an outsider, and its GitHub description
is a three-word personal note.

**Evidence:**

- `gh repo view coghex/kanban` — `visibility: PUBLIC`, `description: "my kanban"`,
  0 stars, 0 forks, 0 watchers, no topics set.
- `kanban.cabal:4` — the package already carries a real one-line synopsis:
  "Event-driven GitHub workflow dashboard for the terminal".
- `README.md:3-6` — the README opens with a considered two-sentence description
  written for a stranger.
- `LICENSE` and `kanban.cabal:10-11` — MIT, declared and shipped.
- Issue #287, "Rewrite the README and install docs for an outsider audience,"
  closed 2026-08-15 — the outsider framing was a deliberate, completed decision
  that the repository metadata was never brought in line with.

**Handoff context:**

- **Current behavior:** The description shown in search results, on the release
  page, and beside every reference to the repository contradicts the audience
  the README was deliberately rewritten for.
- **Expected behavior:** The repository description states what Kanban is, in
  one line consistent with the cabal synopsis and the README's opening. Topics
  are set so the repository is findable by what it is.
- **Scope and constraints:** This is GitHub repository metadata, not a tracked
  file, so it is set with `gh repo edit` rather than a commit — which means the
  acceptance evidence is command output, not a diff. Keep the wording consistent
  with `kanban.cabal:4` so there is one description of this project, not three.
  Deciding the topic list is part of the work; there is no existing list to copy.

### [#418] PROD-4. The changelog has recorded nothing since the release that opened it

**Verification:** Verified — the changelog was created with the 1.0.0.0 release,
declares that per-change entries begin with the next release, and has not been
touched since. Thirty-four merges have landed behind it.

**Evidence:**

- `CHANGELOG.md:9` — `## 1.0.0.0` is the file's only release heading.
- `CHANGELOG.md:17-18` — "Version 1.0.0.0 is Kanban's first release, so the notes
  below are a curated overview of what it does rather than a list of changes.
  Per-change entries begin with the next release."
- `git log -1 -- CHANGELOG.md` — last touched 2026-08-13, by the commit that
  established version 1.0.0.0.
- `git rev-list --count v1.0.0.0..HEAD --merges` — 34 merged pull requests since
  the tag, including user-visible work: the `f` filter panel (#360), completed
  issue and pull-request history (#335), the usage sidebar's update control
  (#361), reset countdowns (#341), `kanban --usage` (#339), and the per-brand
  ping action (#342).
- `CHANGELOG.md:3-7` — the file states its own boundary rule, so an accruing
  section has a defined shape to be written into.

**Handoff context:**

- **Current behavior:** The stated convention has never executed. Thirty-four
  merges of user-visible change are recorded only in commit messages and pull
  request titles, so the next release either reconstructs its notes from
  `git log` or ships without them.
- **Expected behavior:** Changes accrue as they land rather than being
  reconstructed at release time, in a section whose heading the existing
  boundary rule can already extract.
- **Scope and constraints:** The boundary rule at `CHANGELOG.md:3-7` is
  load-bearing — `tools/test_release_workflow.py` and the release workflow
  extract a release's notes by its version string alone — so whatever holds
  unreleased entries must not break that extraction, and the fix must state how
  an unreleased section becomes a released one. Backfilling the 34 merges is a
  judgement call that belongs in the issue: decide it explicitly rather than
  leaving it to whoever picks the work up. Landing this without PROD-5 leaves a
  log that accrues forever and never cuts.

### [no-issue] PROD-5. Nothing states when a release is cut, so 34 merges sit unreleased

> **Disposition:** No issue — the mechanism is complete and self-consistent
> (`release.yml` derives the version from `kanban.cabal`, requires the tag to be
> `v<version>`, and requires `CHANGELOG.md`'s first `##` heading to match it), and
> `docs/development.md`'s "Changing the version" section already documents the bump
> itself. What remains is policy prose — what triggers a release, which component of
> the four-part version moves for which kind of change, and what evidence a release
> needs beyond required CI — belonging in that same section. `docs/development.md`
> carries only the `release-document` reason, which `tools/docs_land_paths.py`'s
> `GATING_REASONS` deliberately does not gate, so a documentation-only change to it
> lands with `/push-docs` rather than through the tracker's claim → worktree → PR lane.

**Verification:** Verified — the release *mechanism* is complete and tested, but
no document says what triggers it, so it has run exactly once.

**Evidence:**

- `.github/workflows/release.yml` — a tag-triggered workflow builds and verifies
  the sdist and publishes it as a release asset; issue #324 established it and
  `tools/test_release_workflow.py` (1,004 lines) covers it.
- `git tag` — one tag, `v1.0.0.0`, 2026-08-16. The mechanism has fired once.
- `docs/design.md:3278` onward — section 21 records the release *evidence* gates
  (REL-1 through REL-4) that preceded the first release, and nothing about
  subsequent ones.
- `docs/public_release_design.md` — 5 of 5 slices processed; the arc's scope was
  publishing the first release, not establishing a cadence.
- `kanban.cabal:3` — still `1.0.0.0`, though the tree has diverged by 34 merges.
- `CHANGELOG.md` — see PROD-4; the two findings are the two halves of the same
  missing loop.

**Handoff context:**

- **Current behavior:** Publishing a release is a fully mechanised act that
  nobody is obliged to perform, so the released artifact drifts further from
  master with every merge. The install path PROD-1 restores points at an
  increasingly old build.
- **Expected behavior:** A written rule an agent or the maintainer can apply
  without judgement: what triggers a release, who bumps the version, which
  component of the four-part version moves for which kind of change, and what
  evidence a release needs beyond required CI.
- **Scope and constraints:** Documentation and contract, not implementation —
  `release.yml` already does the work and must not be rebuilt. Decide where the
  rule lives: `docs/development.md` covers contributor mechanics,
  `docs/design.md` section 21 covers release evidence, and this rule is arguably
  neither. Note that the four-part version and the tag spelling `v<version>` are
  already fixed by decision D-5 and by `release.yml`; this issue chooses when to
  move the number, not how to spell it.

---

## Chapter 2 — Gates that cannot run where they matter

Two findings about tests that exist, are correct, and do not protect anything.
The first is skipped everywhere it would matter; the second fails only where
nobody looks. Both are independently landable, and neither changes application
behavior.

### [#422] PROD-6. The screenshot gate is skipped on every CI run by that job's own design

**Verification:** Verified — the pixel-level cases skip when Pillow or the
pinned fonts are absent, the CI job that runs the Python suite installs neither,
and the skip reason in the code says so explicitly. The gate has never executed
in CI.

**Evidence:**

- `tools/test_board_screenshot.py:292-300` — `RenderingTests.setUpClass` calls
  `_rendering_gap()` and raises `unittest.SkipTest` when it returns a reason.
- `tools/test_board_screenshot.py:61-72` — that helper returns "Pillow is not
  installed, so the golden frame cannot be rasterised; **the required CI job
  installs GHC and Cabal only**." The code states the gap as a known fact.
- `.github/workflows/ci.yml:78-93` — the `python` job is `checkout` then
  `python3 -m unittest discover -s tools -p 'test_*.py'`. It installs no
  packages and no fonts.
- `docs/design.md` section 18 and `docs/development.md:48` describe the Python
  suite as hermetic; adding a rasterisation dependency is a deliberate departure
  that has to be argued, not assumed.
- Consequence, observed: master @ `d37dace` is green in CI and red locally.
  PROD-2's drift reached the README because the only thing that checks it cannot
  run where changes are gated.

**Handoff context:**

- **Current behavior:** Four rendering cases — cell geometry, glyph coverage,
  the missing-glyph refusal, and the byte-for-byte screenshot comparison — skip
  on every pull request. A stale screenshot, a clipped glyph, or a font
  regression reaches master unchallenged, and the maintainer's local suite is
  the only place any of it surfaces.
- **Expected behavior:** The rendering cases execute in required CI, so a change
  that alters the golden frame without regenerating the image fails before it
  merges.
- **Scope and constraints:** The pinned fonts are the hard part, not Pillow —
  establish what `renderer.load_fonts()` requires and whether it can be
  satisfied on `ubuntu-latest` reproducibly, because a font that resolves to a
  different file renders different bytes and would make the gate worse than
  useless. If it cannot be made reproducible, that is a real answer and the
  finding's disposition is the alternative gate, not the obvious one. Whatever
  lands must keep `build-test` as the single aggregate required check
  (`.github/workflows/ci.yml:162-168`); adding a job means adding it to that
  aggregate's `needs`, never to branch protection.

### [#420] PROD-7. The approval-relocation example passes alone and fails in the full suite

**Verification:** Verified as a genuine order- or leftover-process dependency,
not a defect in the code under test — the example fails in a full-suite run and
passes when its module runs alone.

**Evidence:**

- Full-suite run on master @ `d37dace`, 2026-08-19:
  `test_install_issue_approval.RelocationTests.test_two_installs_of_one_repository_into_two_directories_leave_one`
  failed with `InstallError("An issue approval controller for acme/widgets is
  already running from /var/folders/.../widgets (PID 81911), which is installing
  or removing this job. Stop it before installing this repository's job.")`.
- Isolated rerun of the same module immediately afterwards:
  `python3 -m unittest discover -s tools -p 'test_install_issue_approval.py'` —
  105 tests, OK.
- `ps -p 81911` — no such process at the time of the rerun, so the guard fired
  on a recorded owner rather than a genuinely live one.
- `tools/test_install_issue_approval.py:1503` — the assertion is
  `self.assertEqual(failures, [])`, so the failure is the guard refusing an
  install the example expects to succeed.
- Precedent in this repository: a killed run orphaning a fake executable that
  keeps writing a shared record has previously produced deterministic-looking
  failures in unrelated suites, so a leaked child is a known failure mode here
  rather than a novel hypothesis.

**Handoff context:**

- **Current behavior:** The example's outcome depends on state left by other
  tests in the same run — most likely a live-owner record whose process is gone,
  or a child process that outlived the test that spawned it. A full-suite run
  cannot be trusted to mean the same thing twice, which is the property that
  makes a red suite easy to ignore.
- **Expected behavior:** The example produces the same result whether it runs
  alone, in its module, or in a full discovery run.
- **Scope and constraints:** Diagnose before fixing — establish whether the
  contaminating state is a stale record file, a shared temporary path, or a
  leaked child, because the three have different fixes and only one of them is
  in this test. Reproduce it first; a fix for an unreproduced flake is a guess.
  Do not weaken the running-owner guard itself to make the example pass: that
  guard is the single-owner protection PROD-relevant work has repeatedly
  reinforced, and a test that leaks state is the thing to repair.

---

## Chapter 3 — The contract contradicts what it specifies

`CLAUDE.md` makes `docs/design.md` the complete behavior contract and the thing
every review arbitrates against. Two of its lists — section 3's non-goals and
section 20's deferred ideas — were written before the work they forbid shipped,
and have not been revisited. The body of the same document now specifies the
behavior those lists prohibit.

Each finding below is one line of one list, so they are separately landable, but
they touch adjacent lines in two places; landing them in listed order avoids
gratuitous conflicts. PROD-12 is the preventive counterpart and is specified
against the other four.

### [#423] PROD-8. Section 3 forbids the completed-work archive section 16 specifies

**Verification:** Verified — the non-goal and the specification are in the same
document, and the specification is what shipped.

**Evidence:**

- `docs/design.md:203` — non-goal: "A permanent archive of merged or closed
  work."
- `docs/design.md:2709` — "Completed history is the one exception, and carries
  the whole stable payload of a settled item, bodies included," describing what
  is deliberately written to disk and why.
- `docs/design.md:888` — the Done column holds "every completed pull request,
  carrying a `MERGED` badge when it landed and a `CLOSED` badge when it did not."
- `docs/design.md:609` — the board draws a `LOADING COMPLETED HISTORY` panel, so
  the feature has a specified loading state.
- `docs/design.md:1581` — "Completed history is acquired the same way, in the
  background."
- Shipped in #326 (background load and cache) and #335 (read-only history,
  hidden by default), both merged 2026-08-15.

**Handoff context:**

- **Current behavior:** The contract's non-goals list forbids a feature the same
  contract specifies across five sections and that shipped in two pull requests.
  A reviewer citing section 3 can block correct work, and a reader cannot tell
  which half is authoritative.
- **Expected behavior:** Section 3 no longer forbids completed-work history.
  Whatever genuinely remains a non-goal in that area — if anything does — is
  stated in terms the rest of the document agrees with.
- **Scope and constraints:** Do not simply delete the line without deciding what
  it was protecting. The original concern is visible at `docs/design.md:2707-2716`:
  never caching an *open* item's body. That constraint is still live and still
  correct, so the replacement should preserve it rather than losing it along with
  the obsolete half. Documentation only; no behavior changes.

### [#424] PROD-9. Section 20 still defers the merged-work history view that shipped

**Verification:** Verified — section 20 lists as intentionally out of the first
release a feature that landed before the first release was published.

**Evidence:**

- `docs/design.md:3273` — deferred idea: "A merged-work history view separate
  from the live Done column."
- `docs/design.md:3275-3276` — the list's closing rationale: "These are
  intentionally outside the first release so the core remains a small,
  predictable, read-only dashboard."
- #335, "Render completed issues and pull requests as read-only history, hidden
  by default," merged 2026-08-15 — before the `v1.0.0.0` release of 2026-08-16.
- `docs/design.md:886-892` — the shipped shape differs from the deferred one in
  a way worth preserving: completed pull requests appear *in* Done under a
  filter criterion, not in a separate view.
- `docs/card_filter_design.md` — 6 of 6 slices processed; the arc that delivered
  it is complete.

**Handoff context:**

- **Current behavior:** The deferred-ideas list claims the first release
  deliberately excludes a feature the first release contains.
- **Expected behavior:** The entry is gone, and section 20's closing rationale
  still reads truthfully about the entries that remain.
- **Scope and constraints:** Note the distinction the shipped design settled —
  history is a filter criterion on the existing columns, not a separate view —
  and do not reintroduce the separate-view framing while removing the entry. If
  section 20's closing sentence about the first release no longer describes the
  surviving list, fix it in the same change. Documentation only.

### [no-issue] PROD-10. Section 3 forbids the multi-repository board epic #354 plans

> **Disposition:** No issue — the amendment is already a planned child of epic #354,
> "MRB-3. Add the repository tab bar and amend the design contract".
> `docs/multi_repo_boards_design.md` decision D-4 (user signoff 2026-08-10) settles
> both what it says — §3's non-goal is *narrowed*, keeping merged interleaved boards,
> automatic background refresh, and forge adapters excluded — and when it lands: "in
> MRB-3's PR with the first visible multi-repo behavior." Landing it earlier is also
> wrong on the merits: MRB-1 ships "no new UI surface" and is out of scope for "any
> rendering or switching", so it never aggregates repositories in one running board,
> and `CLAUDE.md` requires a contract update to accompany its behavior change rather
> than precede it — amending §3 first would make design.md describe behavior the tree
> does not have, which is this chapter's own defect inverted.

**Verification:** Verified — an open epic with a complete design document plans
the exact capability section 3 names as a non-goal. Unlike PROD-8 and PROD-9,
this contradiction is ahead of the work rather than behind it.

**Evidence:**

- `docs/design.md:204-205` — non-goal: "Multi-repository aggregation in one
  running board. Each invocation represents one repository selected by its path."
- Epic #354, "Run one Kanban session over several repositories," open, labelled
  `epic` and `multi-repo`.
- `docs/multi_repo_boards_design.md` — the arc's design document, 625 lines, 1 of
  6 slices processed; MRB-1 through MRB-5 are unprocessed.
- MRB-1's own scope, "Add a configured repository roster with per-repo paths,"
  directly contradicts "each invocation represents one repository selected by its
  path."
- `CLAUDE.md` — "`docs/design.md` is the complete behavior contract. A behavior
  change must stay consistent with it or update it in the same PR," which makes
  this a blocker a solver hits rather than a discrepancy a reader notices.

**Handoff context:**

- **Current behavior:** The first multi-repo slice cannot satisfy the contract
  and the contract simultaneously. Whoever solves MRB-1 must either amend
  section 3 inside an implementation pull request — bundling a contract decision
  with a feature — or be blocked by a rule the maintainer wrote.
- **Expected behavior:** Section 3 reflects the decision that multi-repository
  boards are being built, so MRB-1 is an ordinary implementation slice.
- **Scope and constraints:** This is a decision, not a cleanup: removing the
  non-goal commits the project to the arc. The design document already argues
  the case and is the place that reasoning belongs, so this issue records the
  decision in section 3 and cites it, rather than re-deriving it. Land this
  before MRB-1 is drafted, not alongside it — the whole point is that the
  contract question stops being the feature's problem. `docs/design.md:205` also
  carries the "each invocation represents one repository" clause, which is the
  half that actually changes; decide its replacement explicitly rather than
  deleting the bullet whole.

### [no-issue] PROD-11. Section 20 still defers multi-repository aggregation

> **Disposition:** No issue — the same planned child of epic #354 that carries §3's
> amendment carries this one. `docs/multi_repo_boards_design.md` decision D-4 (user
> signoff 2026-08-10) states that "§20's 'Multi-repository aggregation' deferral is
> removed"; MRB-3's outcome is "design.md §3/§20 amended"; and the arc's in-scope list
> names "the design.md §3/§20 amendment" as one item, so §3 and §20 are a single
> amendment rather than two. §20 keeps its remaining entries — forge adapters
> explicitly "stays deferred, §20". As with PROD-10, it lands in MRB-3's PR beside the
> first visible multi-repo behavior rather than ahead of it.

**Verification:** Verified — the same capability appears in both lists, so
correcting section 3 alone leaves the contradiction half-fixed.

**Evidence:**

- `docs/design.md:3271` — deferred idea: "Multi-repository aggregation."
- `docs/design.md:204` — the section 3 non-goal PROD-10 covers, stating the same
  restriction in more detail.
- Epic #354 and `docs/multi_repo_boards_design.md`, as in PROD-10.
- The duplication is why this is filed separately: a change that amends only
  section 3 leaves section 20 contradicting the arc, and section 20 is the list a
  reader consults for "what is deliberately not being built."

**Handoff context:**

- **Current behavior:** Two lists forbid the same planned capability, and fixing
  one leaves the other as a citable blocker.
- **Expected behavior:** Section 20 no longer defers multi-repository
  aggregation.
- **Scope and constraints:** Land after PROD-10, which carries the decision;
  this finding is the second half of applying it, not an independent judgement.
  If PROD-10's disposition is to keep the non-goal, this finding closes as
  `[no-issue]` rather than becoming its own change. Documentation only.

### [deferred] PROD-12. Nothing holds sections 3 and 20 against the rest of the document

> **Deferred:** A check written today goes red on master — §3's completed-work-archive
> entry and §20's merged-work-history entry are exactly what #423 and #424 remove — so a
> solver would meet a failing gate two other open issues own. This is the finding's own
> "land after PROD-8 through PROD-11" constraint. **Precondition:** #423 and #424 merge,
> leaving §3 and §20 with no entry the body of `docs/design.md` contradicts. Two
> corrections for whoever writes the issue then. The split is two contradictions behind
> shipped features (PROD-8, PROD-9) and two ahead of planned work (PROD-10, PROD-11), not
> three and one. And the two framings above are not equivalent: `docs/design.md`'s body
> mentions multi-repository boards nowhere outside those two entries, so a
> *within-document* check stays clean on them, while "holding the lists against the arc
> documents in `docs/`" fails on exactly the two entries
> `docs/multi_repo_boards_design.md` D-4 deliberately leaves standing until MRB-3 — the
> false blocker this finding warns against.

**Verification:** Verified — the repository already demonstrates the mechanism
that would have caught PROD-8 through PROD-11, applied to one section only.

**Evidence:**

- `docs/design.md:392` onward — section 7's key table is held against the
  implementation by a test: `Spec.UI.Keys` compares the table's rows verbatim
  against `Kanban.UI.Keys`'s `bindingContract`, so a binding cannot drift from
  the document.
- `CLAUDE.md` source-layout notes record that relationship deliberately: `UI.Keys`
  is "the one declaration site for a board key binding, held against
  `docs/design.md` §7 by a test."
- No equivalent exists for sections 3 or 20. Four contradictions accumulated
  across roughly five weeks, three of them behind features that shipped.
- The contradictions are not subtle — each is a single line naming a capability
  the document specifies elsewhere — which is what makes a mechanical check
  plausible here.

**Handoff context:**

- **Current behavior:** Sections 3 and 20 are prose nothing checks, in a document
  every review arbitrates against. They drift silently, and each drift becomes a
  blocker a solver discovers.
- **Expected behavior:** A contradiction between a non-goal or deferred idea and
  what the rest of the document specifies is caught mechanically, in required CI,
  rather than by audit.
- **Scope and constraints:** The design work is deciding what is actually
  checkable, and that decision belongs in the issue rather than being assumed.
  A verbatim comparison like section 7's does not transfer — these lists name
  capabilities in prose, not rows with an implementation counterpart. Weaker but
  real options exist: requiring each entry to carry a marker that a matching
  specification does not exist, or holding the lists against the arc documents in
  `docs/`. A check that produces false blockers is worse than none, so scoping
  this to something narrow and reliable is the work. Land after PROD-8 through
  PROD-11 so the check is written against a document that already passes it.

---

## Chapter 4 — A closed arc left its apparatus in the contract

The first-release epic finished and its processing scaffolding stayed. Two
findings remove it, from the front and the back of the document, and a third
states the rule that stops the next arc doing the same thing. The removals are
mechanical; the rule is the one that has to be thought about.

### [#428] PROD-13. The contract opens with a finished epic's processing ledger

**Verification:** Verified — 133 lines of epic-processing apparatus for a closed
epic sit ahead of section 1, so the authoritative contract opens with a
completed checklist rather than its purpose.

**Evidence:**

- `docs/design.md:1-8` — the document opens with "Design state: `ready for issue
  processing`" and a status legend for issue processing.
- `docs/design.md:9-16` — "## Processing status", listing EPIC and REL-1 through
  REL-4, every box ticked.
- `docs/design.md:17-39` — "## Epic contract" for epic #268.
- `docs/design.md:40-61` — "## Release scope".
- `docs/design.md:62-133` — "## Current state and evidence".
- `docs/design.md:134` — "## 1. Purpose", the actual beginning of the contract.
- Epic #268 closed `2026-08-16T13:20:26Z`; `docs/public_release_design.md` shows
  5 of 5 slices processed.

**Handoff context:**

- **Current behavior:** Anyone opening the behavior contract — a contributor, a
  reviewer, or an agent reading it before a change — reads a finished epic's
  bookkeeping first, and the numbered contract starts 134 lines in.
- **Expected behavior:** The document opens with section 1. Anything in the
  removed span that is durable rather than procedural is preserved where it
  belongs, not deleted with the scaffolding.
- **Scope and constraints:** Read the span before removing it —
  "Current state and evidence" in particular may hold statements that outlive
  the arc, and `CLAUDE.md` tells readers that the opening status paragraph
  records what is already implemented, so something has to still answer that.
  Section 21 already exists as the permanent home for release evidence (decision
  D-13), so prefer moving durable content there over inventing a new location.
  `CLAUDE.md` itself may need a matching edit if it points at a paragraph that
  stops existing. Documentation only.

### [#429] PROD-14. The contract closes with that epic's decisions and delivery plan

**Verification:** Verified — 456 lines of the same epic's apparatus sit after
section 21, past the end of the numbered contract.

**Evidence:**

- `docs/design.md:6865-7082` — "## Decisions", D-1 onward, the release arc's
  resolved decisions.
- `docs/design.md:7083-7167` — "## Open questions", Q-1 through Q-8, every one
  marked resolved.
- `docs/design.md:7168-7190` — "## Verification strategy".
- `docs/design.md:7191-7320` — "## Delivery plan", the arc's slice ordering.
- `docs/design.md:7156` — Q-8 states the intent directly: the arc scaffolding
  "is temporary processing apparatus that presumably comes out when the arc
  closes."
- The numbered contract ends at section 21; everything after `:7320` is nothing,
  so these four sections are the document's tail.

**Handoff context:**

- **Current behavior:** 456 lines of resolved decisions and a completed delivery
  plan trail the contract, and the document's own Q-8 says they were meant to be
  removed.
- **Expected behavior:** The document ends with section 21. Decisions that
  constrain future work — rather than recording how the release arc reached its
  answer — survive in the numbered sections they constrain.
- **Scope and constraints:** Some decisions here are still load-bearing and must
  not be lost: D-5 fixes the tag spelling `v<version>`, D-12 fixes which artifact
  the gates measure, and D-13 established section 21 itself. Identify those
  before deleting, and record each where it applies — PROD-5 may be the natural
  home for the release-cadence-adjacent ones, so check whether that issue exists
  yet and cross-reference rather than duplicating. Land alongside or after
  PROD-13; they are two halves of one cleanup and splitting them across releases
  leaves the document lopsided. Documentation only.

### [deferred] PROD-15. Nothing states when an arc's scaffolding leaves the document it was added to

> **Deferred:** The rule is supposed to describe what #428 and #429 do, and both are
> still open. #429's constraint in particular — section 21 cites 13 of the 14 decisions
> 43 times — forces the answer to the rule's hardest clause, what becomes of a closed
> arc's decisions, and that answer is undetermined until it lands. Writing the rule now
> is the retrofit this finding warns against. **Precondition:** #428 and #429 merge,
> after which the rule states what they did. One sharpening for whoever writes it: the
> mechanism is that the state machine has no terminal state — `design-epic.md:303`
> defines `exploring` and `ready for issue processing` and no third value, and
> `process-design-doc.md:206` reports completion and stops — so all seven design
> documents sit at `ready for issue processing`, including the five already complete and
> `docs/multi_repo_boards_design.md` (1/6) and `docs/model_settings_design.md` (2/14)
> still in flight. That state machine is where a rule would attach.

**Verification:** Verified — `process-design-doc` and the design-epic workflow
add processing apparatus to durable documents, and no contract says when it
comes out. `docs/design.md` is the first document to demonstrate the
consequence; it will not be the last.

**Evidence:**

- `docs/design.md:7156` — Q-8 hedges on exactly this: the scaffolding "presumably
  comes out when the arc closes." "Presumably" is the whole finding.
- `docs/design.md:1-133` and `:6865-7320` — 589 lines of a closed arc's
  apparatus, 8% of the document, still present three days after epic #268 closed.
- Five further design documents carry the same "Design state" header and
  processing-status shape and will reach the same end state:
  `docs/card_filter_design.md` (6 of 6 processed),
  `docs/usage_awareness_design.md` (5 of 5),
  `docs/claude_document_workflows_design.md` (5 of 5),
  `docs/issue_search_design.md` (4 of 4), and
  `docs/public_release_design.md` (5 of 5) — every one of them already complete.
- `docs/agent-workflow-contract.md` and the `process-design-doc` command define
  how apparatus is *added* and how a slice is recorded; neither defines a
  terminal state for the apparatus itself.

**Handoff context:**

- **Current behavior:** Every processed design document accumulates apparatus
  permanently. Five arcs are already complete, and their documents will each
  need the judgement call PROD-13 and PROD-14 are making by hand.
- **Expected behavior:** A written rule that names when an arc's scaffolding is
  removed, what is preserved and where, and who does it — so closing an epic has
  a defined effect on the document that produced it.
- **Scope and constraints:** The distinction the rule has to draw is between a
  *specification document* like `docs/design.md`, where apparatus is a visitor
  in a permanent contract, and an *arc document* like
  `docs/card_filter_design.md`, which is entirely apparatus and may reasonably
  keep it as a record. Do not write a rule that deletes the second kind.
  Decide where the rule lives — `docs/agent-workflow-contract.md` governs the
  workflows that create the apparatus and is the strongest candidate. This is
  specified against PROD-13 and PROD-14: let those two settle what "preserved
  where it belongs" means in practice, then write the rule they followed rather
  than one they have to be retrofitted to.

---

## Chapter 5 — Recovery state that never expires

Issue #202 taught the drainer to reap the *anchors* its autostash leaves, and it
works — `refs/drain-prs/**` is empty on this checkout. The stash entries the same
recovery path deliberately preserves got no equivalent treatment, so they
accumulate. One finding is the missing reaper; the other is the accumulation
already present.

### PROD-16. A conflicted autostash restore preserves a stash nothing ever reaps

**Verification:** Verified as a real gap with a correct premise — the
preservation is deliberate and should stay; what is missing is any path that
retires a preserved snapshot once it is known to be unrecoverable or
superseded.

**Evidence:**

- `tools/drain_prs.py:2870` — when `git stash apply --index` fails, the snapshot
  is preserved under the message `drain-prs-autostash-recovery <sha>`.
- `tools/drain_prs.py:2877-2880` — the success path calls
  `_release_snapshot_anchor`, with the comment "the anchor was only ever needed
  to survive a crash before this point." The anchor has a release path; the
  stash does not.
- `tools/drain_prs_service.py:1570-1618` — `autostash_inventory` reports
  `kept_autostash_anchors` and `drainer_stashes` side by side, so status already
  distinguishes the reaped kind from the unreaped one.
- `tools/drain_prs_service.py:70` — the recognising pattern, so the drainer
  already knows which stashes are its own.
- Issue #202, "Reap autostash anchors whose snapshot is recoverable, and report
  the rest," closed — its body scopes itself to anchors and explicitly describes
  keeping the stash as the belt-and-braces half. The gap is the deliberate
  remainder of a closed issue, not an oversight in it.
- Observed effect: `refs/drain-prs/**` is empty on this checkout while five
  recovery stashes remain, which is exactly #202 working and this finding not
  being covered by it.

**Handoff context:**

- **Current behavior:** Every conflicted restore adds a permanent stash entry.
  The drainer reports them as live recovery state indefinitely, so the signal
  that a snapshot needs a human's attention never distinguishes yesterday's from
  last month's.
- **Expected behavior:** A preserved snapshot has a defined end: it is retired
  once its content is known to be recovered or superseded, and until then it is
  reported in a way that says which it is.
- **Scope and constraints:** Never reap a snapshot that might hold unrecovered
  work — the preservation exists because the alternative is losing a user's
  changes, and a wrong reap is unrecoverable. That constraint is what makes this
  non-trivial: the fix has to establish recoverability rather than assume it from
  age, and "old" is not "recovered." Age alone is a reporting improvement, not a
  reaping criterion. Reuse #202's established shape for deciding recoverability
  rather than inventing a second one.

### PROD-17. Five stale recovery stashes sit on the primary checkout now

**Verification:** Verified — five stashes are present on
`/Users/vincentcoghlan/work/kanban`, the newest 8 days old at the time of the
audit, and none holds recoverable work.

**Evidence:**

- `git stash list` on master @ `d37dace` — five entries:
  `stash@{0}` and `stash@{1}` carrying `drain-prs-autostash-recovery` messages
  (2026-08-11 and 2026-07-30), and `stash@{2}` through `stash@{4}` from
  2026-07-20 (`unreferenced-kanban-screenshot-20260720`,
  `pre-master-update-recovery-20260720`, `drain-prs-autostash-1784437386`).
- `tools/drain_prs_service.py status` reports the first two under
  `drainer_stashes`, with `kept_autostash_anchors` empty.
- Content comparison against master: `stash@{0}`'s copy of
  `claude-plugin/plugins/kanban/commands/issue.md` is identical to master's, and
  its other two files are older versions of files master has since advanced.
- `stash@{1}`'s copy of `docs/design.md` is 5,989 lines smaller than master's,
  so the snapshot predates the bulk of the document.
- `stash@{4}` contains `test/Spec.hs` as a monolith; that file is now 103 lines,
  having been split into 58 per-subsystem modules by #148. The snapshot predates
  a completed refactor.

**Handoff context:**

- **Current behavior:** Five snapshots no one will ever restore are reported as
  recovery state, and two of them are what the drainer's status surfaces when
  asked whether anything needs attention.
- **Expected behavior:** The checkout carries no recovery stash that has already
  been superseded.
- **Scope and constraints:** This is operational cleanup on one machine's
  working checkout, not a code change, and it may well be the right disposition
  to clear them by hand and close this `[no-issue]` with that recorded — decide
  that explicitly rather than filing an issue reflexively. Verify each stash's
  content against master before dropping it; the evidence above covers four of
  five, and `stash@{2}`'s screenshot snapshot was not inspected. `git stash drop`
  is not reversible once the reflog expires. If PROD-16 lands first, check
  whether its reaper handles these rather than clearing them twice.

---

## Chapter 6 — The conventions a contributor cannot see

This repository enforces unusually strict conventions — an issue body shape, a
pull-request origin marker a parser rejects malformed spellings of, a
publication lane per document, a no-merge rule. All of them are recorded in
`CLAUDE.md`, which is addressed to agents working in this checkout, and none of
them are visible to anyone arriving through GitHub. Five findings, each a
standard file this project has a specific reason to want.

### PROD-18. The contribution protocol is recorded only in agent-facing instructions

**Verification:** Verified — no `CONTRIBUTING.md` exists, and the rules a
contributor would need are in a file written to instruct agents operating in a
local checkout.

**Evidence:**

- No `CONTRIBUTING.md` at the repository root or under `.github/`.
- `CLAUDE.md:1-4` — addressed to "Claude Code sessions started at this
  repository's root," not to contributors.
- `AGENTS.md` is a tracked symlink to `CLAUDE.md` (git mode `120000`), held by
  `tools/test_repository_contract_alias.py` — so both instruction files are the
  same agent-facing document.
- Rules a contributor cannot discover otherwise: the three build and test
  commands and which to run for which paths (`CLAUDE.md:7-24`); warning-clean
  builds under `-Werror` (`:59-62`); "Never merge a pull request"
  (`:121-122`); the publication lanes (`:30-49`); and the issue body shape
  (`:128`).
- `docs/development.md` (164 lines) covers build, test, and layout basics but
  none of the workflow rules above.

**Handoff context:**

- **Current behavior:** The project's actual contribution rules are addressed to
  an audience of agents. GitHub shows no contributing guide, so a human arriving
  at the repository sees the README's install path and nothing about how work is
  proposed, reviewed, or landed.
- **Expected behavior:** A `CONTRIBUTING.md` GitHub links from the issue and
  pull-request UI, stating how to build and test, what the review gate requires,
  and the rules that would otherwise surprise someone — particularly that pull
  requests are never merged by hand.
- **Scope and constraints:** Do not duplicate `CLAUDE.md` — a second copy of the
  same rules is the drift this project has already paid for elsewhere. Point at
  the existing documents and state only what is genuinely contributor-facing and
  not already in `docs/development.md`. Decide honestly what the answer is for an
  outside contributor given that the pipeline is agent-driven and `master` is
  protected; "this project does not currently accept outside pull requests" is a
  legitimate and useful thing for the file to say if it is true.

### PROD-19. No issue template encodes the tracker's required body shape

**Verification:** Verified — issue bodies must follow a fixed five-heading shape
and carry an origin marker, and both requirements live only in prose.

**Evidence:**

- No `.github/ISSUE_TEMPLATE/` directory and no `.github/issue_template.md`.
- `CLAUDE.md:128-129` — "Issue bodies follow the tracker's shape: Background,
  Requirements, Acceptance, Out of scope, Related."
- `CLAUDE.md:116-117` — issue bodies carry `<!-- issue-origin:codex -->` or
  `<!-- issue-origin:claude -->`, which routes the work to an opposite-brand
  reviewer.
- Every open issue in the tracker follows the shape, so the convention is real
  and consistently applied — by workflows, not by anything GitHub enforces.
- The canonical readiness gate `approve_issues.py` reviews issues against that
  shape, so a malformed issue is caught late, after filing, rather than at
  composition.

**Handoff context:**

- **Current behavior:** The shape is reproduced by each drafting workflow
  independently. Anyone filing through GitHub's web UI — including the
  maintainer on a phone — gets an empty box and no indication that a shape
  exists.
- **Expected behavior:** GitHub's new-issue flow offers a template carrying the
  five headings and whatever origin marker is correct for a human-filed issue.
- **Scope and constraints:** Decide what origin a human-filed issue declares —
  the two existing markers name agent brands, and the answer may be that a
  template omits the marker and the readiness gate treats unmarked issues as it
  already does. Check that behavior before writing the template rather than
  inventing a third marker. Keep the template consistent with what
  `approve_issues.py` actually gates on; a template that produces issues the gate
  rejects would be worse than none. Consider whether the `epic` shape needs its
  own template, since epics carry a children or phase checklist that ordinary
  issues do not.

### PROD-20. No pull-request template encodes the origin marker the router parses

**Verification:** Verified — pull request bodies must end with exactly one origin
marker, a parser rejects every malformed spelling, and nothing at composition
time helps anyone get it right.

**Evidence:**

- No `.github/pull_request_template.md` or `.github/PULL_REQUEST_TEMPLATE/`.
- `CLAUDE.md:118-119` — a pull request body "carries exactly one of
  `<!-- pr-origin:codex -->` or `<!-- pr-origin:claude -->` as its final
  non-whitespace content."
- `src/Kanban/PullRequestFlow.hs:62-63` — `originFromBody` returns
  `Either Text PullRequestOrigin`, rejecting duplicated, mixed, or
  trailing-text markers rather than guessing.
- The failure is not hypothetical: a marker mentioned in body prose counts as a
  duplicate, origin resolves to unknown, and the review routes to both brands
  instead of the opposite one — which is how a solver session can end up
  reviewing its own pull request.
- `CLAUDE.md:118-119` — a further body constraint with the same character: a
  closing keyword in prose creates a real closing reference and trips the
  fail-closed issue gate.

**Handoff context:**

- **Current behavior:** Two body constraints with non-obvious failure modes are
  enforced by a parser and a gate, and communicated only in agent instructions. A
  hand-written pull request that mentions either marker in prose, or describes
  history with a closing keyword, fails in a way whose cause is not visible from
  the error.
- **Expected behavior:** The new-pull-request body starts from a template that
  puts the marker where the parser expects it and warns, in a comment the
  template carries, about mentioning either marker or a closing keyword in prose.
- **Scope and constraints:** The marker must be the final non-whitespace content,
  so the template's own trailing content is the thing to get right — verify the
  rendered result against `originFromBody` rather than assuming. A template
  comment that itself contains a marker spelling would create the exact duplicate
  it warns about; check that too. Human-filed pull requests may have no correct
  brand answer, in which case the template should say what to do instead of
  offering a wrong default.

### PROD-21. No security policy, though the project installs services and runs agents

**Verification:** Verified — no `SECURITY.md` exists, and the project's optional
components do things that make a disclosure path meaningful rather than
ceremonial.

**Evidence:**

- No `SECURITY.md` at the repository root or under `.github/`.
- `tools/install_drainer.py` and `tools/install_issue_approval.py` install
  persistent launchd jobs or systemd user units that run on the user's behalf.
- `docs/design.md:2703-2716` — Kanban writes caches containing whole bodies of
  completed private-repository items to disk, protected by `0600` permissions
  under a `0700` directory, and the document argues that protection explicitly.
- The application invokes the user's authenticated `gh`, `codex`, and `claude`
  CLIs, and `kanban --doctor` confirms it reaches all three with the terminal
  user's credentials.
- `src/Kanban/Text.hs` and the sanitization discipline exist because external
  text reaches a terminal, which is a deliberate injection-surface decision
  already taken seriously in the code.
- The repository is public, so someone finding a problem in any of the above has
  no stated way to report it privately.

**Handoff context:**

- **Current behavior:** A finder's only options are a public issue or nothing.
  For a project that writes private repository content to disk and installs
  background services, a public issue is the wrong first move.
- **Expected behavior:** A `SECURITY.md` stating where to report privately, what
  is in scope, and what response to expect — honestly scoped to a single
  maintainer's actual capacity.
- **Scope and constraints:** Do not promise a response time that cannot be met;
  an unmet security SLA is worse than an honest "best effort, no guarantee."
  Enabling GitHub private vulnerability reporting is a repository setting, so
  like PROD-3 the acceptance evidence is partly command or UI state rather than a
  diff. Scope statements should name the optional components explicitly, since
  the board alone and the board plus installed services have very different
  surfaces.

### PROD-22. No code of conduct

**Verification:** Verified — no `CODE_OF_CONDUCT.md` exists. Recorded for
completeness of the community-health set; it is the weakest finding in this
chapter and may well close without an issue.

**Evidence:**

- No `CODE_OF_CONDUCT.md` at the repository root or under `.github/`.
- `gh repo view coghex/kanban` — 0 forks, 0 watchers, and every one of the 191
  pull requests authored by `coghex`; there is no community to govern today.
- GitHub's community-standards checklist counts it, alongside the contributing
  guide and security policy this chapter's other findings cover.

**Handoff context:**

- **Current behavior:** The repository is public with no stated conduct
  expectations. Nothing has happened that needed them.
- **Expected behavior:** Either a `CODE_OF_CONDUCT.md` — conventionally the
  Contributor Covenant, with a real contact address — or a recorded decision that
  one is deliberately not adopted while the project has no outside contributors.
- **Scope and constraints:** A code of conduct with no named enforcement contact
  is decoration; if it is adopted, the contact has to be real. This is the
  finding most likely to be correctly closed `[no-issue]` with that reasoning
  recorded, and doing so is a legitimate outcome rather than a skipped one. If
  PROD-18's contributing guide concludes that outside contributions are not
  currently accepted, that conclusion probably settles this finding too.
