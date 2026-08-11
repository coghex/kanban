# First public release design

Kanban has been in production for months for its own developer, but no
outsider can currently discover, install, and trust it without reading the
source tree. This arc packages the repository for a public release:
versioned, documented for strangers, visually demonstrated, with a
repeatable publish pipeline. The publish act itself belongs to design.md's
existing first-release readiness-gate arc (its `REL-4`); this arc feeds it
(D-7). Almost entirely docs and `.github/` — the only code touched is
version metadata (`kanban.cabal` and the CLI's hard-coded version string).

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. Package Kanban's first public release
- [ ] PUB-1. Establish the release version and start the changelog
- [ ] PUB-2. Rewrite the README and install docs for an outsider audience
- [ ] PUB-3. Produce and embed a fixture-rendered board screenshot
- [ ] PUB-4. Add a tag-triggered release workflow publishing the verified sdist

## Epic contract

- **Goal:** a stranger with `git`, `gh`, and a Haskell toolchain can find
  Kanban, understand what it does in under a minute, install it from a
  versioned release, and run the board — without cloning blind or reading
  contract documents. This arc supplies every packaging precondition for
  that experience; the publish act stays with design.md's `REL-4`.
- **Done when:** version, changelog, outsider README, screenshot, and the
  tag-triggered release workflow are all merged; the workflow's dry run
  publishes a correct draft release; and design.md's `REL-4` publish gate is
  blocked on nothing from this arc — only on its own manual evidence.
- **Users and operators:** outside evaluators and new users (consume);
  Vincent (operates the release process and design.md's manual gates); the
  agent pipeline (must keep passing the release-completeness gates it
  already has).
- **Arc label:** proposed `release` (does not exist yet; current labels have
  no release/infrastructure category).

## Current state and evidence

- **No release has ever been cut**: `git tag -l` is empty, `gh release list`
  is empty. Version is `0.1.0.0` (`kanban.cabal:3`), never bumped.
- **No changelog exists** (no `CHANGELOG*` at the root; synarchy has one,
  kanban does not).
- **Release machinery is half-built and already enforced**:
  `tools/test_source_distribution.py` builds the real `cabal sdist` archive
  and verifies it is a complete checkout — every tracked file needs a stated
  release decision (`RELEASE_TREES`/`RELEASE_ROOT_FILES`/`RELEASE_DOCUMENTS`
  vs `EXCLUDED_TRACKED_PATHS`). CI (`.github/workflows/ci.yml`) pins GHC
  9.12.2 / Cabal 3.16.1.0 and runs `cabal check` first. There is no
  `release.yml`; the only workflows are `ci.yml` and `review-gate.yml`.
- **README.md is functional but not evaluative**: it has Requirements, Build,
  Install, and workflow-setup sections and correctly frames the optional AI
  components, but contains no screenshot or recording, no version/release
  reference, and no explicit platform statement.
- **Platform reality**: `docs/workflow-setup.md` declares macOS the supported
  platform for the optional components (launchd drainer, `script`-wrapper
  usage polling). The board executable itself has no known macOS-only
  dependency, but Linux operation is unverified. A separate proposed arc
  (Linux portability, systemd drainer backend) exists and is deliberately not
  part of this epic.
- **Package metadata** (`kanban.cabal:1-15`): synopsis and description are
  current; `maintainer: coghex` is a bare name, not an email — Hackage upload
  conventions expect a reachable maintainer field.
- **Documentation lanes constrain new files**: every tracked Markdown file
  must classify in `docs/agent-workflow-contract.md` §7 (fail-closed), and
  every tracked file needs a release decision in
  `tools/test_source_distribution.py`. A new `CHANGELOG.md` therefore lands
  with a §7 row and a release-inventory entry in the same PR, or the gates go
  red.
- **design.md embeds its own unprocessed release-readiness arc.** Its
  processing ledger (`docs/design.md:11-15`) holds `EPIC. Complete Kanban's
  first-release readiness gate` with `REL-1` (real-terminal performance
  measurements), `REL-2` (live usage verification), `REL-3`
  (installed-terminal exercise), and `REL-4` (publish the first release,
  depending on the other three). Its decisions D-1..D-3
  (`docs/design.md:2015-2033`) bind the evidence rules, its version note
  (`docs/design.md:2069`) asks what version `REL-4` should carry, and its
  Q-3 asks what publishing means. This arc answers the version and
  publishing-mechanics questions and deliberately leaves the manual gates
  and the publish act there (D-7).
- **A stale release-blocker claim in `docs/design.md:71-77`** (audit finding
  WF-15, being processed separately) says release publication must wait on
  #225; #225 is closed and the exclusion landed. This epic does not own that
  fix but should not race it.
- **The version string exists in two places.** `kanban.cabal:3` and the
  hard-coded `"kanban 0.1.0.0"` in `src/Kanban/CLI.hs:110-111`; a version
  bump must move both. The usage-awareness arc also touches `CLI.hs` —
  coordinate at solve time.
- **Tracker state**: no overlapping epic or release issue exists
  (repo-scoped searches for release/changelog/install return only closed,
  unrelated items; zero open issues at drafting time).
- **Deterministic UI frames exist**: the Brick golden-frame test fixtures
  (`test/golden/*.txt`, `*.attrs`) render the board without a terminal,
  network, or GitHub account — a candidate source for reproducible
  screenshots.

## Desired experience

A visitor lands on the repository and sees, above the fold: what Kanban is,
what it looks like (image or recording), and a three-command install from the
latest release. They can tell within a minute whether the optional AI
workflow layer applies to them, and nothing they are told over-promises: the
README states the supported platform for each component. Cutting a release
is: update the changelog, push a tag, watch the workflow publish a release
whose sdist is the same archive the completeness test already guards. Each
subsequent release is a small diff, not an event.

## Scope

### In scope

- Version choice, changelog file and policy, and their gate-side entries
  (§7 classification row, release inventory).
- README and install-path documentation rewritten for outsiders, including a
  platform statement per component.
- Visual demonstration media and the process for regenerating it.
- A tag-triggered GitHub Actions release workflow publishing the sdist and
  release notes, proven by a dry run.

### Out of scope

- Linux/systemd support for the drainer (separate proposed arc; this epic
  only *states* platform support truthfully).
- Any runtime, TUI, or tools behavior change.
- Homebrew tap or other package-manager distribution (revisit after the
  first release ships; see Q-1).
- Marketing beyond the repository itself (posts, submissions, site).
- The publish act and the manual evidence gates — they remain design.md's
  `REL-1`..`REL-4` (D-7).
- Hackage publication (D-1). Deliberately deferred, not rejected forever: it
  would add a maintainer email, dependency-bounds review, and an ongoing PVP
  obligation. Revisit as its own small arc once the GitHub release exists.

## Design

- **Versioning (D-2).** PVP, as the ecosystem expects. The first public
  release is `1.0.0.0`: months of daily production use back the stability
  claim, and future breaking changes commit to PVP major bumps. Version
  lives solely in `kanban.cabal`; the tag mirrors it (`v1.0.0.0`).
- **Changelog (D-3).** `CHANGELOG.md` at the root, newest-first, one section
  per release. The first entry is a curated "everything until now" summary
  of the feature set; per-change history starts with the next release. The
  release workflow reads the top section as the release notes body.
- **README.** Restructure toward: one-paragraph pitch → media → quickstart
  (release install) → what works where (platform/component matrix) →
  optional AI layer with the existing setup/doctor framing → links into
  `docs/user-guide.md` and the contracts. The existing accurate content is
  kept; this is a reframe, not a rewrite from scratch.
- **Media (D-5, D-6).** Static screenshot(s) rendered from the deterministic
  golden/cache-fixture path — a staged fixture board, no live repository
  data — tracked in-repo under `docs/media/`, referenced by relative path
  from the README, with regeneration steps recorded beside the assets. Each
  asset gets a release decision in `tools/test_source_distribution.py`
  (expected: excluded from the sdist, like the audit reports).
- **Platform statement (D-4).** The README states plainly: macOS supported;
  the board is untested on Linux; the optional components (drainer, usage
  polling) are macOS-only by design today. No Linux CI job in this epic; the
  claim changes only when the separate portability arc changes the facts.
- **Release workflow (D-1 scope).** `release.yml` triggered by `v*` tags:
  build, run the full CI suite, `cabal sdist`, create the GitHub release
  with the sdist asset and the changelog's top section. It reuses the pinned
  toolchain from `ci.yml`. The completeness test remains the gate that the
  archive is whole; the workflow is just the publisher. GitHub is the only
  channel; the workflow prepares no Hackage artifact.

## Decisions

### D-1. GitHub Release is the only distribution channel for this arc

User signoff 2026-08-10. Tag + sdist asset + release notes, nothing else.
Hackage was the leading rejected alternative: it reaches the Haskell audience
but adds a maintainer email, dependency-bounds review, and a standing PVP
obligation; it is deferred to a possible later arc, not merged into this one.
A Homebrew tap was rejected for the same maintenance-tail reason.
Consequence: the Hackage slice was removed from the delivery plan;
`release.yml` prepares no Hackage artifact.

### D-2. The first release is version 1.0.0.0

User signoff 2026-08-10. Months of daily production use back the stability
claim. Consequence: `kanban.cabal` bumps from `0.1.0.0`; the tag is
`v1.0.0.0`; future breaking changes owe PVP major bumps.

### D-3. The changelog opens with a curated summary, not reconstructed history

User signoff 2026-08-10. The first `CHANGELOG.md` entry is a hand-written
overview of the feature set as of 1.0.0.0; per-change history begins with the
next release. The 233-issue archaeology alternative was rejected as heavy
work for little reader value.

### D-5. README media is a fixture-rendered screenshot

User signoff 2026-08-10. The board image is rendered from the deterministic
golden/cache-fixture path: reproducible from a clean checkout, mechanically
regenerable after UI changes, and free of live repository data. A terminal
recording was the rejected alternative — richer, but manual to refresh and
needing a staged board to avoid leaking real issue titles; it can be added
later without reopening this arc.

### D-7. This arc packages; design.md's REL-4 publishes

User signoff 2026-08-10. design.md's embedded first-release readiness arc
keeps the manual evidence gates (`REL-1`..`REL-3`) and the publish act
(`REL-4`); this arc supplies the packaging those slices consume. Slice IDs
here are `PUB-` to avoid colliding with design.md's `REL-` identifiers, and
the former publish slice (previously `REL-5` here) was removed as a
duplicate of design.md's `REL-4`. Consequences: PUB-1's PR resolves
design.md's version note in the same change (design.md is
implementation-coupled); consumer-side verification of the published sdist
belongs to design.md `REL-4`; the rejected alternatives — superseding
design.md's arc from this document, or leaving both publish slices to be
reconciled during processing — were declined to keep one authoritative
publish gate.

### D-6. Media assets are tracked in-repo

User signoff 2026-08-10. Small assets live under `docs/media/` and the
README references them by relative path, so the image is versioned with the
UI it depicts and renders reliably on GitHub. Consequence: each asset needs
a release decision in `tools/test_source_distribution.py`. External hosting
was rejected for its loose regeneration story and URL fragility.

### D-4. The release states an honest macOS-only claim

User signoff 2026-08-10. README says: macOS supported; board untested on
Linux; optional components (drainer, usage polling) macOS-only by design.
No Linux CI job in this epic. The rejected alternatives — verifying the
board on Linux first, or gating on the Linux-portability arc — were declined
to keep this epic shippable and docs/.github-only.

## Open questions

### Q-1. Which distribution channels does the first release commit to?

Resolved by D-1.

### Q-2. What version does the first release carry, and how does the changelog treat pre-release history?

Resolved by D-2 (version) and D-3 (changelog policy).

### Q-3. What platform claim does the release make?

Resolved by D-4.

### Q-4. What form does the README media take, and where do the assets live?

Resolved by D-5 (fixture-rendered screenshot) and D-6 (tracked in-repo under
`docs/media/`).

## Verification strategy

- `cabal check` and `tools/test_source_distribution.py` already gate metadata
  and archive completeness in CI; they remain the backbone.
- The release workflow gets a dry-run path (a prerelease or workflow-dispatch
  run) proven before the real tag.
- Consumer-side verification of the published sdist (download, unpack,
  `cabal build all`, `cabal test all`, `kanban --version`) is recorded under
  design.md `REL-4` when the release is cut (D-7); this arc's dry-run draft
  release proves the pipeline beforehand.
- README claims are checked against `cabal run kanban -- --doctor` output on
  a checkout with no optional components installed, so the outsider path is
  the one actually documented.
- Media regeneration steps are recorded next to the media so a future UI
  change can refresh it without reverse-engineering.

## Delivery plan

### PUB-1. Establish the release version and start the changelog

- **Outcome:** `kanban.cabal` and the CLI version string carry `1.0.0.0`;
  `CHANGELOG.md` exists with the curated first entry; the file classifies in
  §7 and has a release decision, so all gates stay green; design.md's
  version note is resolved in the same PR.
- **Scope:** version bump in `kanban.cabal:3` and
  `src/Kanban/CLI.hs:110-111`, changelog file and policy note, §7 row,
  `tools/test_source_distribution.py` inventory entry, the design.md
  version-note update.
- **Phase:** 1
- **Depends on:** none
- **Ordering:** can land first
- **Relevant decisions:** D-2, D-3
- **Acceptance signals:** full Python suite and `cabal check` pass; the
  changelog's top section reads as usable release notes.
- **Out of scope:** the workflow that consumes the changelog (PUB-4).
- **Open questions:** None

### PUB-2. Rewrite the README and install docs for an outsider audience

- **Outcome:** README restructured as pitch → media slot → quickstart →
  platform/component matrix → optional AI layer → doc links; install path
  documented from a release archive, not only a clone.
- **Scope:** `README.md`, touch-ups to `docs/user-guide.md` intro and
  `docs/README.md` index; a media placeholder PUB-3 fills.
- **Phase:** 1
- **Depends on:** none
- **Ordering:** independent
- **Relevant decisions:** D-4 (platform statement)
- **Acceptance signals:** a reader following only the README on a machine
  without the repo reaches a running board; `--doctor` framing matches what
  a fresh install actually reports.
- **Out of scope:** media production (PUB-3); any setup-tooling change.
- **Open questions:** None

### PUB-3. Produce and embed a fixture-rendered board screenshot

- **Outcome:** the README's media slot filled with a fixture-rendered
  screenshot under `docs/media/`, plus a recorded regeneration procedure.
- **Scope:** media assets, their release decisions, regeneration notes;
  rendering via the golden-frame or fixture-cache path.
- **Phase:** 2
- **Depends on:** PUB-2
- **Ordering:** not on the critical path
- **Relevant decisions:** D-5, D-6
- **Acceptance signals:** media renders on the GitHub README page; the
  regeneration steps produce the same image class from a clean checkout.
- **Out of scope:** demo GIFs of the AI workflow actions (privacy and
  reproducibility review first).
- **Open questions:** None

### PUB-4. Add a tag-triggered release workflow publishing the verified sdist

- **Outcome:** `.github/workflows/release.yml` — on `v*` tag: pinned
  toolchain, full test run, `cabal sdist`, GitHub release created with the
  sdist asset and the changelog's top section as notes.
- **Scope:** the workflow file only; no new scripts under `tools/` unless a
  changelog-extraction one-liner needs a home.
- **Phase:** 2
- **Depends on:** PUB-1
- **Ordering:** critical path
- **Relevant decisions:** D-1, D-7
- **Acceptance signals:** a dry-run (prerelease tag or workflow_dispatch)
  publishes a draft release with the correct asset and notes.
- **Out of scope:** any Hackage artifact preparation (D-1); cutting the real
  release — that is design.md `REL-4` (D-7).
- **Open questions:** None
