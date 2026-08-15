# Linux portability design

Kanban is macOS-only by declaration and by three concrete couplings: the PR
drainer is a launchd job, the Claude usage probe spawns BSD `script`, and the
managed installs live under `~/Library/…`. Meanwhile the whole automated
suite already passes on Linux — CI runs `ubuntu-latest` — so the distance to
a truthful "runs on Linux" claim is small and known. This arc closes it: a
systemd backend for the drainer beside launchd, portable probe and path
handling, and platform docs that state exactly what works where. It follows
the public-release epic's honest-macOS claim (its D-4) and upgrades that
claim when the facts change.

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Make Kanban and its optional components run on Linux — [#290]
- [x] LNX-1. Extract a service-manager backend seam in the drainer tools — [#291]
- [x] LNX-2. Add the systemd user-unit backend and lift the darwin gate — [#329]
- [x] LNX-3. Make the Claude probe and process snapshot Linux-correct — [#331]
- [x] LNX-4. Resolve managed install and log paths per platform — [no-issue]: split into the managed-paths arc (`docs/managed_paths_design.md`)
- [ ] LNX-5. State the new platform support in the docs and contracts

## Epic contract

- **Goal:** a Linux user can build, test, and run the board, refresh both
  usage providers, and operate the PR drainer as a systemd user service —
  with macOS behavior unchanged byte-for-byte.
- **Done when:** the drainer installs, starts, drains, and reports status
  through systemd on Linux with the same durable-record contract launchd
  has; the Claude probe returns snapshots under util-linux `script`; managed
  paths resolve idiomatically per platform (delivered by the managed-paths arc
  in `docs/managed_paths_design.md`); and the platform claims in
  README/workflow-setup/pr-drainer match verified reality.
- **Users and operators:** future Linux users of the public release; Vincent
  if a Linux host enters the fleet; CI (which is already the de facto Linux
  verifier); the agent pipeline (drainer contracts unchanged in meaning).
- **Arc label:** proposed `portability`.

## Current state and evidence

- **The automated suite is already Linux-green.** CI runs on `ubuntu-latest`
  (`.github/workflows/ci.yml:18`): warning-clean build, the full Haskell
  suite including golden Brick frames, and the Python drainer/contract
  suite. What has never run on Linux is the live TUI, the live probes, and
  the drainer runtime.
- **The drainer refuses non-macOS by design.** `src/Kanban/Drainer.hs:383-384`
  fails closed: "the PR drainer is a launchd job and needs macOS to run" —
  a single, clean gate to make backend-aware.
- **launchd coupling is concentrated and self-aware.**
  `tools/drain_prs_service.py` imports `plistlib` (`:11`), owns label and
  plist naming with 255-byte discipline (`:29-32`, `:84`, `:202-212`), and
  wraps every `launchctl` call in `run_command` (bootstrap/bootout/
  kickstart/print). `tools/install_drainer.py` mirrors it. Tests already
  fake the launchctl layer, so a second backend inherits the fixture
  pattern.
- **The durable label is a §4 manifest row.**
  `drainer-launchagent-label` = `com.coghex.drain-prs` prefix
  (`docs/agent-workflow-contract.md:601`), asserted by
  `tools/test_agent_workflow_contract.py:1053-1068`; a systemd naming
  scheme extends a test-parsed contract.
- **Managed paths are macOS-spelled at one point each.**
  `tools/kanban_config.py:50` returns
  `~/Library/Application Support/kanban/issue-review` unconditionally; the
  drainer install dir, discovery records, and `~/Library/Logs/kanban/…`
  follow the same convention (§4 personal-path rows name these literally).
- **The Claude probe argv is BSD-only.** `src/Kanban/Claude.hs:118` runs
  `script -q /dev/null <claude> …` — BSD argument order. util-linux `script`
  requires the command via `-c` with the typescript file last; on Linux the
  current argv misparses. `fetchClaudeUsage` already fails closed on a
  missing `script` (`:76-79`).
- **The process snapshot is probably portable, unverified.**
  `src/Kanban/Process.hs:152` runs
  `ps -axo pid=,ppid=,pgid=,stat=,lstart=,command=`; procps-ng accepts
  BSD-style flags and these keywords, but the `lstart` format parse has no
  Linux fixture.
- **`plutil` is macOS-only and optional** (§4 row `plutil-cli`, used
  read-only for LaunchAgent status); `systemctl --user show` is the
  analogue.
- **A stale branch tried part of this and tangled it with rejected work.**
  `ci-linux-container` (Jul 20) mixes a prebuilt-container CI idea and
  `make ci` with the abandoned refuse-dirty-checkout gate; its useful third
  commit already merged via another branch. Proposal: delete the branch,
  take nothing from it.
- **Cross-arc interactions.** Unprocessed WF-11/12/13 target the same
  drainer files (kick cadence, live-checkout advisory, autostash
  escalation); the usage epic's USE slices touch `Claude.hs`; the release
  epic's D-4 states honest-macOS wording this arc later upgrades. No
  tracker epic overlaps (searches return closed items only; #234-#238 are
  workflow-tooling issues).

## Desired experience

On Linux: `cabal build all` and both suites pass (already true); `kanban`
opens the board; `u` refreshes GitHub, Codex, and Claude usage;
`python3 tools/install_drainer.py` installs a systemd user unit whose
lifecycle, discovery record, logs, and incident store behave exactly as the
launchd job's do on macOS — same commands, same records, different service
manager underneath. On macOS: nothing changes at all. In the docs, a reader
learns the truth per component; nothing claims more than a verified path.

## Scope

### In scope

- A backend seam in the drainer tools with launchd and systemd
  implementations; the Haskell-side gate and status reader made
  backend-aware.
- The Claude probe's `script`-flavor handling and a Linux fixture for the
  `ps` snapshot parse.
- Platform statements in README, workflow-setup, pr-drainer, and design.md.

### Out of scope

- Windows or BSD support.
- Per-platform managed install, record, runtime, and log path resolution and
  the §4 rows that name them — split out on 2026-08-12 into
  `docs/managed_paths_design.md`, which owns that arc end to end.
- Changing drainer semantics (merge policy, autostash, incidents) — WF-11,
  WF-12, and WF-13 own those conversations.
- The `setup_workflows.py` provider-plugin components (provider CLIs manage
  their own platform support).
- Containerized/`make ci` CI restructuring (the `ci-linux-container` idea) —
  a separate, optional arc if ever wanted.
- A macOS CI job (macOS stays manually verified as today).

## Design

Proposed shape, pending the open questions:

- **Backend seam (LNX-1).** `drain_prs_service.py` isolates every
  service-manager interaction behind one backend interface: unit-file
  generation, install/uninstall, start/stop/kick, status read, and label
  naming. The launchd backend keeps today's behavior exactly — plists,
  labels, `launchctl` verbs — proven by the existing fixtures rerouted
  through the seam. Pure refactor; no new capability.
- **systemd backend (LNX-2).** Per-repo user units mirroring the launchd
  jobs one-to-one: unit name derived like the label
  (proposal: `kanban-drain-prs-<owner>-<name>.service`, same
  escaping-and-length discipline), files in
  `~/.config/systemd/user/`, lifecycle via `systemctl --user`
  (`daemon-reload`, `start`, `stop`, `kill`), status via
  `systemctl --user show`. The discovery record gains a backend field;
  `Drainer.hs:383`'s gate becomes "no supported service manager found"
  only when neither backend applies. §4 gains the systemd naming row
  beside the launchd one (test expectations updated in the same PR).
- **Probe portability (LNX-3).** `Claude.hs` selects the `script` argv by
  flavor — BSD (`script -q /dev/null cmd…`) vs util-linux
  (`script -q -c "cmd" /dev/null`) — detected once per invocation
  (proposal: by OS, with the flavor recorded in the failure diagnostics).
  The `ps` snapshot parse gains a procps `lstart` fixture; any real
  divergence found becomes part of this slice.
- **Paths (LNX-4, D-2) — now a separate arc.** Idiomatic per-platform
  resolution: macOS keeps `~/Library/…`; Linux uses
  `$XDG_DATA_HOME`/`$XDG_STATE_HOME` homes, with `kanban_config.py` as the
  single resolver both languages consult. The §4 personal-path rows update to
  name both outputs. Split out on 2026-08-12 into
  `docs/managed_paths_design.md`, which carries D-2 forward and settles the
  questions this bullet left open — which XDG root holds which artifact, how
  the vendored bundle assets resolve without a resolver, and how a §4 row
  carries two spellings.
- **Docs (LNX-5).** `workflow-setup.md:17-18`'s "not a cross-platform
  port" sentence, `pr-drainer.md:51`'s macOS-installer claim, the README
  platform matrix (written by the release epic's PUB-2 under its D-4), and
  design.md §14/§17 notes all move to the verified two-platform statement.
  Lands last, after the behavior exists.
- **Sequencing against WF-11/12/13 (D-3).** The backend seam lands first;
  the WF drainer issues, when filed, implement their behavior once through
  the seam so any interval, advisory, or escalation works on both platforms
  from day one. Their issue bodies should record the dependency on LNX-1.
- **Evidence (D-1).** A systemd-enabled container CI job exercises the
  full drainer lifecycle (install, start, kick, status, uninstall) with
  fake `gh` and providers — the strongest claim available without
  hardware, and the docs say exactly that.

## Decisions

### D-1. The Linux claim is container-verified

User signoff 2026-08-10. A systemd-enabled container CI job exercises the
drainer backend's full lifecycle with fake `gh` and provider executables,
on top of the already-Linux-green build and headless suites; the docs
state "verified in CI containers." A real-hardware manual gate was
rejected (no Linux host to commit) and "experimental" wording was rejected
as weaker than the achievable evidence. Consequence: LNX-2 owns the
container job; LNX-5's wording is bounded by this tier and can upgrade if
real hardware ever runs a recorded session.

### D-2. Linux paths are idiomatic XDG

User signoff 2026-08-10. Linux installs, discovery records, and logs
resolve under `$XDG_DATA_HOME`/`$XDG_STATE_HOME`; macOS keeps `~/Library/…`
unchanged; `tools/kanban_config.py` remains the single resolver every
consumer consults. The same-spelling-everywhere alternative was rejected
as alien to Linux users. Consequence: the §4 personal-path rows and their
test update to name both outputs; existing macOS installs never move.
Delivery moved on 2026-08-12: this decision is carried forward verbatim as D-1
of `docs/managed_paths_design.md`, whose arc owns the implementation.

### D-3. The backend seam lands before the WF drainer issues

User signoff 2026-08-10. LNX-1 (and LNX-2 behind it) proceed now; the
WF-11/12/13 fixes are implemented once through the seam rather than once
per platform. Waiting for the unfiled WF issues and unordered interleaving
were both rejected. Consequence: when those issues are filed from the
audit report, their bodies should record the LNX-1 dependency.

## Open questions

### Q-1. What proves the Linux claim, given no Linux host is known to exist here?

Resolved by D-1.

### Q-2. Do Linux paths go idiomatic-XDG or keep the Library spelling?

Resolved by D-2.

### Q-3. Do the WF drainer issues land before or after the backend seam?

Resolved by D-3.

## Verification strategy

- LNX-1 is proven by invariance: the existing launchd fixtures pass
  unchanged through the seam, and generated plists are byte-identical.
- The systemd backend follows the launchd test pattern: faked `systemctl`
  on a temporary PATH, generated unit files asserted as fixtures, and the
  full lifecycle (install, start, kick, status, uninstall, migrate)
  exercised without a real service manager. Real-lifecycle verification is
  the D-1 container job: a systemd-enabled container runs the actual
  install/start/kick/status/uninstall sequence against fake tools.
- Probe portability: captured util-linux `script` transcripts and a procps
  `lstart` sample join the existing fixture families; the BSD paths keep
  their current fixtures.
- Path resolution: owned by the managed-paths arc
  (`docs/managed_paths_design.md`), whose verification strategy covers the
  table-driven resolver test and the §4 reconciliations.
- Docs land last and only claim what the chosen Q-1 evidence supports.

## Delivery plan

### LNX-1. Extract a service-manager backend seam in the drainer tools

- **Outcome:** all launchd interaction in `drain_prs_service.py` and
  `install_drainer.py` sits behind one backend interface; behavior and
  generated plists byte-identical; fixtures rerouted and green.
- **Scope:** the seam, the launchd backend, test rerouting.
- **Phase:** 1
- **Depends on:** none (lands before the WF drainer issues, D-3)
- **Ordering:** critical path
- **Relevant decisions:** D-3
- **Acceptance signals:** existing drainer fixtures pass unchanged;
  plist/label outputs byte-identical; no new behavior observable.
- **Out of scope:** any systemd code; any WF-11/12/13 behavior.
- **Open questions:** None

### [#329] LNX-2. Add the systemd user-unit backend and lift the darwin gate

- **Outcome:** per-repo systemd user units install, start, kick, report
  status, and uninstall through the seam with the same durable records;
  `Drainer.hs` gates on "no supported service manager" instead of darwin;
  §4 gains the systemd naming row.
- **Scope:** the systemd backend, discovery-record backend field, Haskell
  gate and status reader, §4 row and test expectations, the D-1
  systemd-container CI job running the real lifecycle against fake tools.
- **Phase:** 2
- **Depends on:** LNX-1
- **Ordering:** critical path
- **Relevant decisions:** D-1, D-2
- **Acceptance signals:** faked-`systemctl` lifecycle fixtures green;
  launchd behavior untouched; the container job passes the full
  install/start/kick/status/uninstall sequence in CI.
- **Out of scope:** changing what the drainer does once running.
- **Open questions:** None

### [#331] LNX-3. Make the Claude probe and process snapshot Linux-correct

- **Outcome:** the Claude probe runs the flavor-correct `script` argv per
  platform; the `ps` parse has a procps fixture; failures name the flavor.
- **Scope:** `Claude.hs` argv selection, fixtures for util-linux
  transcripts and procps `lstart`, diagnostics.
- **Phase:** 2
- **Depends on:** none
- **Ordering:** independent
- **Relevant decisions:** none beyond structure
- **Acceptance signals:** fixture suites cover both flavors; macOS argv
  byte-identical to today's.
- **Out of scope:** Codex probe (app-server RPC is already portable);
  usage-epic features.
- **Open questions:** None

### LNX-4. Resolve managed install and log paths per platform

> **Disposition 2026-08-12: `[no-issue]`, split into its own arc.** Sizing this
> slice against the tree showed a surface LNX-4 understates: two managed
> installs rather than one (`tools/kanban_config.py`'s resolver governs the
> issue-review backend, not the drainer), twelve packaged spellings across both
> plugin bundles that cannot consult a resolver, and four §4 `personal-path`
> rows behind two machine-checked reconciliations — thirty-four tracked files
> in all. That is more than one reviewable PR. The work now lives in
> `docs/managed_paths_design.md` as its own epic with four slices, carrying
> D-2 forward as its D-1. The section below is retained as the record of what
> this arc originally scoped.

- **Outcome:** install dirs, discovery records, and logs resolve
  per-platform (macOS `~/Library/…`, Linux XDG) from one resolver; §4
  personal-path rows and their test match.
- **Scope:** `kanban_config.py` resolver, Haskell consumers, §4 rows and
  test expectations, migration note for existing installs.
- **Phase:** 2
- **Depends on:** LNX-1
- **Ordering:** not on the critical path
- **Relevant decisions:** D-2
- **Acceptance signals:** table-driven resolver test green on both
  platforms; macOS installs resolve to today's paths unchanged.
- **Out of scope:** moving any existing macOS install.
- **Open questions:** Q-2

### LNX-5. State the new platform support in the docs and contracts

- **Outcome:** README, workflow-setup, pr-drainer, and design.md state the
  verified two-platform reality; the release epic's platform matrix is
  upgraded from honest-macOS.
- **Scope:** the four documents; wording bounded by D-1's evidence tier
  ("verified in CI containers").
- **Phase:** 3
- **Depends on:** LNX-2, LNX-3, and the managed-paths arc
  (`docs/managed_paths_design.md`), which is tracked separately rather than as
  a slice of this one
- **Ordering:** critical path
- **Relevant decisions:** D-1
- **Acceptance signals:** no doc claims a component-platform pair without
  a named verification; workflow-setup's "not a cross-platform port"
  sentence replaced.
- **Out of scope:** marketing.
- **Open questions:** None
