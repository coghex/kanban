# Managed paths design

Kanban installs two things into the user's home: the PR drainer and the
canonical issue-review backend. Both spell their install directories,
discovery records, runtime state, and logs as macOS `~/Library/…` paths at
every point that names them — twenty-plus places across Haskell, Python, both
packaged plugin bundles, and the contract manifest that polices them. Kanban's
own state already resolves through the XDG roots on both platforms, so the
`~/Library` convention governs exactly this managed-install surface. This arc
makes that surface resolve per platform so the drainer and the agent pipeline
can run on Linux, while every existing macOS install stays exactly where it is.

Split out of `docs/linux_portability_design.md`'s LNX-4, which underspecified
the surface: it named one resolver and one component, and the real surface is
two managed installs, two languages, two vendored bundles, and four contract
rows with two machine-checked reconciliations.

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. Resolve Kanban's managed installs, records, and logs per platform
- [ ] PATH-1. Make one platform-aware resolver own the issue-review paths
- [ ] PATH-2. Route the drainer's install, record, runtime, and log paths
- [ ] PATH-3. Resolve the Haskell consumers' managed paths per platform
- [ ] PATH-4. Repoint the packaged plugin assets at the resolved record

## Epic contract

- **Goal:** on Linux, every Kanban-managed install directory, discovery
  record, runtime file, and log resolves to an idiomatic XDG location, and
  every consumer — Haskell, Python, and both packaged bundles — agrees on it;
  on macOS, every one of those paths is byte-identical to today's.
- **Done when:** the drainer and the issue-review backend install, discover,
  run, and log under the applicable XDG home on Linux; no consumer spells a
  managed path a second way that could disagree with the resolver; the §4
  `personal-path` rows and both home-relative-path reconciliations describe
  both platforms and stay green; and no existing macOS install moves.
- **Users and operators:** future Linux users of the public release; the agent
  pipeline, whose solve, review, and issue-review workflows resolve the
  issue-review record on whatever host they run on; Vincent, whose live macOS
  installs must not move.
- **Arc label:** existing `portability` — its description already reads
  "Linux support and cross-platform service, probe, and path behavior".

## Current state and evidence

- **Two managed installs, resolved independently.** `tools/kanban_config.py:50`
  returns `~/Library/Application Support/kanban/issue-review` for the
  issue-review backend; the drainer never consults it and spells its own at
  `tools/drain_prs_service.py:53` (`~/Library/LaunchAgents`), `:60`
  (`~/Library/Application Support/kanban/pr-drainer/config.json`), `:64`
  (`DEFAULT_INSTALL_DIR`, the record's parent), and `:85`
  (`~/Library/Logs/kanban/pr-drainer`). `RUNTIME_ROOT` (`:86`) hangs off the
  install dir. So LNX-4's "`kanban_config.py` resolver" named a module that
  today governs the *other* component.
- **The Haskell side spells both again.** `src/Kanban/Drainer.hs:349` builds
  the drainer record path and `src/Kanban/Review/Canonical.hs:134` the
  issue-review record path, each as its own `home <> "/Library/…"` literal.
  Both are deliberate duplications of a fixed location — see the closed #155,
  which established discovery-by-record precisely so an `--install-dir`
  install stays findable.
- **Kanban's own state is already XDG, on both platforms.**
  `src/Kanban/Paths.hs` creates application state under the XDG roots, and
  `tools/kanban_config.py:189-192` resolves the workflow config to
  `$XDG_CONFIG_HOME`/`~/.config/kanban/config.toml` mirroring
  `Kanban.Config.defaultConfigPath`. macOS therefore already reads
  `~/.config/kanban/config.toml` today. The `~/Library` convention is not
  Kanban-wide; it covers the managed-install surface only.
- **Twelve packaged spellings, one path, no resolver available.** Both plugin
  bundles spell `~/Library/Application Support/kanban/issue-review/config.json`
  in their `review_pr.py`, in the `solve`, `issue-review`, and `issue-rereview`
  skill or command documents, and in both bundle READMEs.
  `claude-plugin/plugins/kanban/scripts/review_pr.py:420` builds it from a
  hardcoded `Path.home()`, with a comment explaining that the record's own path
  is the one thing that cannot move. These are vendored standalone assets: they
  cannot import `tools/kanban_config.py`, so whatever a two-platform record
  path costs, they pay it twelve times. Bundle changes also pass
  `tools/plugin_bundle_gate.py`'s version gate.
- **Four contract rows, two machine checks.**
  `docs/agent-workflow-contract.md` §4 carries `approve-issues-backend`,
  `issue-review-discovery-record`, `drainer-discovery-record`, and
  `drainer-install-dir` as `personal-path` rows, each declaring "the exact
  literal string the check searches for" plus the files expected to contain it.
  `tools/test_agent_workflow_contract.py:766` fails any tracked file that
  "builds an undocumented home-relative path", and §4 describes it as the
  markdown counterpart of a Haskell home-relative-path check. A second
  spelling per component is therefore a contract-shape change, not a code
  change with documentation to follow.
- **Test fixtures pin the literals too.** `test/Spec/Agent/Protocol.hs:219`
  asserts a user-facing message mentions
  `/Library/Application Support/kanban/issue-review/config.json`, and the
  Python suites (`test_drain_prs_service.py`, `test_install_issue_review.py`,
  `test_single_pr_drain.py`, both plugin gates) assert against the same
  spellings.
- **Environment overrides already exist and are the escape hatch.**
  `KANBAN_ISSUE_REVIEW_INSTALL_DIR` (`tools/kanban_config.py:42`) and
  `KANBAN_DRAINER_INSTALL_DIR` (`tools/drain_prs_service.py:65`) relocate the
  install directories. Neither moves the discovery record, by design: a
  dashboard that inherited no environment still has to find an install made
  with `--install-dir`.
- **Sequencing context.** Epic #290's LNX-2 adds the systemd backend and lands
  before this arc, so a Linux install may briefly create `~/Library/…`
  directories that this arc relocates. #291 (the service-manager seam) is open
  and unstarted; its body names LNX-4 as the owner of path resolution, which
  this split supersedes.

## Desired experience

A Linux user installs the drainer and the issue-review backend and finds them
where a Linux user looks: data under `$XDG_DATA_HOME`, state and logs under
`$XDG_STATE_HOME`, nothing under a `Library` directory. An agent workflow
running on that host resolves the issue-review record without being told where
it is. A macOS user notices nothing: every install, record, runtime file, and
log stays byte-for-byte where it is today, and no migration runs. A future
contributor who adds a new managed path cannot spell it once and forget the
other platform, because the contract check fails closed on the undeclared
spelling.

## Scope

### In scope

- Per-platform resolution of both managed installs: install directories,
  discovery records, runtime state, and logs.
- The Haskell consumers of those records (`Drainer.hs`, `Review/Canonical.hs`)
  and their diagnostics.
- The packaged plugin assets and both bundle READMEs that spell the
  issue-review record.
- The §4 `personal-path` rows and both home-relative-path reconciliations.
- Documentation prose that states a managed path, updated in the same PR as
  the behavior it describes.

### Out of scope

- Kanban's own cache, config, and settings paths — already XDG on both
  platforms.
- `~/Library/LaunchAgents` and plist naming — macOS-only by construction, and
  the systemd unit location is LNX-2's.
- Moving, migrating, or touching any existing macOS install.
- Windows or BSD path conventions.
- The systemd backend, the Claude probe, and the platform-support statements —
  LNX-2, LNX-3, and LNX-5 in epic #290.
- Changing what the drainer or the issue reviewer does once running.

## Design

Proposed shape, pending the open questions below.

- **One resolver per language, not per component.** `tools/kanban_config.py`
  becomes the single Python resolver for both managed installs, with the
  drainer's constants derived from it rather than spelled beside it. The
  Haskell side gets the matching resolution point so `Drainer.hs` and
  `Review/Canonical.hs` stop each carrying a literal. Two resolution points
  total, one per language, mirroring how `default_config_path` already mirrors
  `Kanban.Config.defaultConfigPath`.
- **macOS output is the invariant.** Every slice proves the macOS spelling is
  unchanged before it claims the Linux one, so the existing fixtures are the
  regression test rather than a rewritten expectation.
- **Contract rows land with their slice.** The §4 reconciliation fails closed,
  so a slice that changes a spelling updates its own rows and tests in the same
  PR. There is deliberately no trailing "update the contract" slice.
- **The packaged bundles probe rather than branch (D-4).** They cannot consult
  the resolver, so instead of duplicating the platform decision twelve times
  they try both known locations in a fixed order and use whichever exists. The
  decision stays in one place; the assets only need to know both literals,
  which the §4 rows already declare.
- **The Linux mapping (D-5).** Install directories and discovery records
  resolve under `$XDG_DATA_HOME/kanban/…`; logs under
  `$XDG_STATE_HOME/kanban/…`; runtime state stays install-dir-relative exactly
  as `RUNTIME_ROOT` is today, so `--install-dir` keeps moving the runtime with
  the scripts and the record's own path stays the fixed thing that cannot
  move.
- **Contract rows come in platform pairs (D-6).** Each affected §4 row gains a
  Linux sibling with its own literal token and file list, so the one-token-
  per-row invariant both reconciliations rely on survives unchanged.
- **Writing is single-valued; discovery probes (D-7, D-8).** "Where does a
  fresh install go" is one platform-determined answer. "Where is the installed
  thing" tries the XDG location, then `~/Library`. Every consumer — both
  resolvers and all twelve packaged assets — uses the same order, so no two
  sides can disagree about which install is live.
- **The migration closes the LNX-2 window (D-9).** A Linux install made before
  this arc is moved to its XDG location by the installer's next run. macOS is
  never migrated because D-1 leaves it already correct.
- **One accepted intermediate.** Between PATH-2 and PATH-3, the Python side
  resolves Linux paths while the Haskell side still spells `~/Library`. That
  window is invisible in practice: epic #290 does not claim a working Linux
  board until LNX-5, and PATH-3 closes it by giving the Haskell side the same
  probe.

## Decisions

### D-1. Linux managed paths are idiomatic XDG; macOS keeps `~/Library`

Inherited from `docs/linux_portability_design.md` D-2, user signoff
2026-08-10. Linux installs, discovery records, and logs resolve under the XDG
homes; macOS keeps `~/Library/…` unchanged; a single resolver every consumer
that can reach one consults. The same-spelling-everywhere alternative was
rejected there as alien to Linux users. Consequence: the §4 personal-path rows
and their checks name both outputs, and existing macOS installs never move.

### D-2. The systemd backend lands before this arc

User signoff 2026-08-12. Epic #290's LNX-2 lands first and may temporarily
create `~/Library/…` directories on a Linux host; this arc relocates them.
Waiting for this arc before the systemd backend was rejected as stretching
#290's critical path behind a multi-issue arc. Consequence: this arc inherits
whatever spelling LNX-2 ships on Linux, and Q-4 decides whether it migrates
such an install or simply supersedes it.

### D-3. Managed paths are their own arc, not an LNX-2 fold

User signoff 2026-08-12. The path work leaves epic #290 as its own epic rather
than being folded into LNX-2 or left as the single LNX-4 slice. Folding was
rejected as producing a PR too large for the canonical reviewer to ingest;
reshaping #290's Phase 2 in place was rejected as putting two distinct concerns
under one epic. Consequence: LNX-4 becomes `[no-issue]` pointing at this epic,
LNX-5's dependency list drops it, and #290's Phase 2 checklist and dependency
prose update through that disposition.

### D-4. The packaged assets probe both locations in a fixed order

User signoff 2026-08-12. Each vendored bundle asset tries both known record
locations and uses whichever exists, rather than carrying the platform
decision. Duplicating a platform branch twelve times was rejected as twelve
copies of one decision that the §4 check cannot police — it catches an
undeclared literal, not a wrong branch. Moving the record to one
platform-independent location was rejected because it would move a live macOS
install. Consequence: PATH-4 changes twelve assets to a two-location probe,
the §4 rows declare both literals, and Q-5 must fix the order.

### D-5. Install directories and records go to the data home, logs to the state home

User signoff 2026-08-12. On Linux, install directories and discovery records
resolve under `$XDG_DATA_HOME/kanban/…` and logs under
`$XDG_STATE_HOME/kanban/…`; runtime state stays install-dir-relative as
`RUNTIME_ROOT` is today. A strict four-way split placing runtime in
`$XDG_RUNTIME_DIR` was rejected because that directory is not guaranteed for a
non-login session — which is exactly how a systemd user unit may run — and it
would stop runtime following `--install-dir`. One root for everything was
rejected as putting logs in the data home. Consequence: two Linux roots appear
in the resolver and in the §4 rows; the install-dir-to-runtime relationship is
preserved unchanged on both platforms.

### D-6. Each affected §4 row gains a Linux sibling row

User signoff 2026-08-12. `personal-path` rows stay one-literal-per-row; a
component with two spellings gets a second row naming the Linux token and its
files. A `;`-separated token pair was rejected for breaking the "exact literal
string the check searches for" invariant both reconciliations rely on; a new
platform column was rejected for changing the shape of every §4 row including
those this arc never touches. Consequence: the four affected rows become
eight, and each slice adds its own sibling row in the same PR.

### D-7. The probe tries the XDG location first

User signoff 2026-08-12. Every prober — packaged asset and resolver alike —
tries the XDG location before `~/Library`. A Linux host still carrying an
LNX-2-era install therefore prefers the correct new location, and on macOS,
where nothing writes an XDG record, the first probe misses and the second hits
with no behavior change and no platform branch. `~/Library`-first was rejected
because it would make a stale Linux install win indefinitely;
platform-idiomatic-first was rejected for reintroducing in twelve places the
branch D-4 removed.

### D-8. Resolvers answer one write path and probe for discovery

User signoff 2026-08-12. Each resolver separates "where does a fresh install
go", which is single-valued and platform-determined, from "where is the
installed thing", which probes both locations in D-7's order. This mirrors the
distinction the code already draws between `DEFAULT_INSTALL_DIR` and the
discovery record, and it keeps every consumer agreeing on both platforms.
Single-valued resolvers relying on migration were rejected for making the
arc's correctness depend on the installer being re-run; reporting the stray
install without resolving it was rejected as leaving the operator to act.
Consequence: PATH-1 through PATH-3 each implement both halves, and the
found-but-unexpected case has a defined answer rather than a diagnostic.

### D-9. The installer migrates a `~/Library`-spelled Linux install

User signoff 2026-08-12. On Linux, the installer moves an install found at the
macOS-spelled location to the XDG one on its next run, following the existing
`LEGACY_CONFIG_PATH` precedent for a pre-consolidation install. Detect-and-
report was rejected as leaving a split state; ignoring it was rejected because
a real Linux host that ran LNX-2 early would stay inconsistent. Consequence:
PATH-2 carries the migration and its fixtures; macOS installs are still never
touched, since D-1 keeps their location correct.

## Open questions

### Q-1. How do the vendored plugin assets resolve a two-platform record path?

Resolved by D-4.

### Q-2. Which XDG root holds which artifact?

Resolved by D-5.

### Q-3. How does a §4 row carry two spellings?

Resolved by D-6.

### Q-4. Does this arc migrate a Linux install made under LNX-2?

Resolved by D-9.

### Q-5. In which order does the probe try the two locations?

Resolved by D-7.

### Q-6. Do the two resolvers probe as well, or answer with one path?

Resolved by D-8.

No open questions remain. Every slice below is deliberately closed; a solver
that finds one of these decisions contradicted by the code should stop and
return the arc here rather than deciding it in a PR.

## Verification strategy

- Every slice proves macOS invariance first: existing fixtures pass unchanged
  and generated paths are byte-identical, before any Linux expectation is
  added.
- Path resolution gets one table-driven test over (platform × component ×
  environment override × which location exists) so a new managed path cannot
  be added with only one platform's expectation, and the D-7 order is asserted
  for each location alone and for both present at once.
- The D-9 migration is proven by seeding a `~/Library`-spelled install on a
  simulated Linux host, running the installer, and asserting the install
  moved, the record followed, and the same run on macOS is a no-op.
- The §4 reconciliations stay green throughout and are the mechanism that
  catches an undeclared second spelling; a slice that changes a spelling
  without its row fails the Python suite.
- The packaged bundles keep their existing gate coverage
  (`tools/test_claude_plugin.py`, `tools/test_codex_plugin.py`,
  `tools/plugin_bundle_gate.py`), which already assert their vendored path
  spellings.
- Linux behavior rides epic #290's evidence tier: the Ubuntu suite plus, for
  the drainer lifecycle, LNX-2's systemd-enabled container job.

## Delivery plan

Shaped by D-4 through D-9, with no open questions remaining. Each slice keeps
its own §4 sibling rows and documentation prose in the same PR, because the
reconciliation fails closed on a spelling whose row is missing.

### PATH-1. Make one platform-aware resolver own the issue-review paths

- **Outcome:** `tools/kanban_config.py` answers one write path per platform
  for the issue-review install and probes both locations for discovery; macOS
  output byte-identical; the override behavior unchanged.
- **Scope:** the resolver's two halves, its §4 sibling row,
  `tools/install_issue_review.py`, and the Python fixtures.
- **Phase:** 1
- **Depends on:** none
- **Ordering:** critical path
- **Relevant decisions:** D-1, D-5, D-6, D-7, D-8
- **Acceptance signals:** table-driven resolver test green over platform ×
  override × which location exists; existing macOS fixtures unchanged; §4
  reconciliation green with the new sibling row.
- **Out of scope:** the drainer's paths; the Haskell consumers; the bundles.
- **Open questions:** None

### PATH-2. Route the drainer's install, record, runtime, and log paths

- **Outcome:** `drain_prs_service.py` and `install_drainer.py` derive every
  managed path from the resolver instead of spelling it, and the installer
  migrates a `~/Library`-spelled Linux install on its next run; macOS output
  byte-identical and never migrated.
- **Scope:** the four drainer path constants, their §4 sibling rows, the D-9
  migration, and the drainer fixtures.
- **Phase:** 2
- **Depends on:** PATH-1
- **Ordering:** critical path
- **Relevant decisions:** D-1, D-2, D-5, D-6, D-7, D-8, D-9
- **Acceptance signals:** drainer fixtures pass with macOS spellings
  unchanged; Linux resolution asserted; the migration moves a seeded
  `~/Library` Linux install and is a no-op on macOS; §4 reconciliation green
  with the new sibling rows.
- **Out of scope:** `~/Library/LaunchAgents`, plists, and the systemd unit
  location, which belong to LNX-2.
- **Open questions:** Q-4, Q-6

### PATH-3. Resolve the Haskell consumers' managed paths per platform

- **Outcome:** `Drainer.hs` and `Review/Canonical.hs` discover their records
  through the same probe order from one Haskell resolution point, with
  diagnostics naming the resolved path.
- **Scope:** both modules, the Haskell resolution point, and the Haskell
  fixtures that pin the literals, including
  `test/Spec/Agent/Protocol.hs:219`.
- **Phase:** 2
- **Depends on:** PATH-1, PATH-2
- **Ordering:** critical path
- **Relevant decisions:** D-1, D-5, D-6, D-7, D-8
- **Acceptance signals:** Haskell suite green with macOS expectations
  unchanged; the probe order asserted off-host for each location and for both
  present.
- **Out of scope:** the darwin service gate, which is LNX-2's.
- **Open questions:** None

### PATH-4. Repoint the packaged plugin assets at the resolved record

- **Outcome:** both bundles' scripts, workflow documents, and READMEs try both
  record locations in the fixed order and use whichever exists.
- **Scope:** twelve spellings across two bundles, their gates, and the bundle
  version discipline.
- **Phase:** 3
- **Depends on:** PATH-1
- **Ordering:** not on the critical path
- **Relevant decisions:** D-1, D-4, D-7
- **Acceptance signals:** both plugin gates green; no vendored asset resolves
  a path the resolver would not; the probe order asserted for a host holding
  each location and both.
- **Out of scope:** any other packaged workflow behavior.
- **Open questions:** None
