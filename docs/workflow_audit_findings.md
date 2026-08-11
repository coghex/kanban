# Workflow audit findings

Findings from the 2026-08-10 audit of the kanban × synarchy agent workflow: the
tracked plugin bundles, the personal `~/.claude` and `~/.codex` skill layers, the
provider plugin caches, the PR drainer installation, and the workflow contract
documents. Captures verified concerns for one-at-a-time processing; files no
issues and changes no implementation.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Methodology

Source material is a full-session audit performed 2026-08-10 against kanban @
`4146f43` and synarchy @ `67edfa8f` (both masters synced with origin): an
on-disk inventory of both checkouts, `~/.claude`, `~/.codex`, the LaunchAgents
and Application Support installs; pairwise diffs of every workflow definition
across its copy locations (`claude-plugin/`, `codex-plugin/`,
`~/.claude/commands/`, `~/.codex/skills/`, and both provider plugin caches);
full reads of `docs/agent-workflow-contract.md`, `docs/workflow-setup.md`,
`docs/pr-drainer.md`, `docs/drafting-workflow-contract.md`, and
`docs/development.md`; and live GitHub PR/label state via `gh`. Limits:
machine-local paths cite this workstation's layout; line numbers reference the
audited commits; synarchy-side repository internals were not audited beyond
drainer and docs-worktree state.

## Status

- [ ] WF-1. Personal PR-review workflows in both brands invoke the retired coordinator generation
- [ ] WF-2. The Codex plugin cache is stale and the tracked skills resolve their coordinator from it
- [ ] WF-3. Plugin manifests never version-bump, so caches cannot detect staleness
- [ ] WF-4. The two tracked review coordinators diverge beyond the documented model-pinning exception
- [ ] WF-5. trusted_issue_spec.py exists only in the personal Codex solve skill
- [ ] WF-6. The personal skill layer is unversioned and drifting between brands
- [ ] WF-7. The vendored design workflows dropped the personal copies' decision-authority guardrails
- [ ] WF-8. The issue repair-and-rereview loop is closeable only from Codex
- [ ] WF-9. The Claude plugin has no design-document or report-drafting workflows
- [ ] WF-10. The kanban repository has no AGENTS.md
- [ ] WF-11. Approved pull requests merge only while the drainer is explicitly kicked
- [ ] WF-12. The production drainer executes from the live development checkout
- [ ] WF-13. Kept autostash anchors and recovery stashes have no escalation or triage path
- [ ] WF-14. DW-1/DW-3/DW-10 defer on a clearing condition that is unsatisfiable as written
- [ ] WF-15. design.md's status paragraph names a resolved release blocker
- [ ] WF-16. agent-workflow-contract prose drifts from its own manifest and tests
- [ ] WF-17. Cross-reference and coverage omissions across the workflow documents
- [ ] WF-18. Codex config pins trusted hashes for a hooks file that no longer exists
- [ ] WF-19. ~/work/drain_prs.py is an ungoverned launcher the contract does not cover
- [ ] WF-20. Superseded local backups and retired artifacts linger on the workstation

---

## Stale execution surfaces

### WF-1. Personal PR-review workflows in both brands invoke the retired coordinator generation

`~/.claude/commands/pr-review.md`, `pr-rereview.md`, and `pr-revise.md`, and
their `~/.codex/skills` twins, all invoke
`python3 ~/.codex/skills/pr-review/scripts/review-pr.py` (hyphenated filename).
That script is 925 lines against the tracked coordinators' 1449/1460 and
contains zero occurrences of `--self-review` or `--publish-verdict`: no issue
approval gate, no `blocked`/`awaiting_self_review`/`reviewed` dispatch, no
`--allow-no-issue`, no mandatory `reviewed:revised` label removal on rereview,
and it pins reviewer models the current assets forbid pinning. Because Claude
lists both `/pr-review` (personal) and `/kanban:pr-review` (plugin), which
generation runs depends on which name is typed; a legacy-path review can bypass
the issue-approval gate and publish markers the current gate rejects.

**Evidence:**

- `~/.claude/commands/pr-review.md` — invokes `~/.codex/skills/pr-review/scripts/review-pr.py`; describes the pre-self-review protocol and pins `gpt-5.6-terra`/`claude-opus-5`.
- `~/.codex/skills/pr-review/scripts/review-pr.py` — 925 lines; `grep -c 'self-review\|publish-verdict'` returns 0.
- `claude-plugin/plugins/kanban/commands/pr-review.md:10-13` — current generation resolves `${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py`.
- `docs/workflow-setup.md:183-187` — unpackaged personal copies of these workflows are explicitly unsupported.

**Handoff context:**

- **Current behavior:** two review protocol generations are simultaneously invocable per brand; name choice silently selects one.
- **Expected direction:** exactly one resolvable copy per workflow per brand — retire the personal `pr-review`/`pr-rereview`/`pr-revise`/`pr-review-standalone` copies and the legacy `review-pr.py`.
- **Scope and constraints:** machine-local cleanup plus any repository guidance that should record the retirement; `pr-review-standalone` is fully superseded by `--allow-no-issue`.
- **Remaining uncertainty:** whether any active session or automation still names the personal copies.

### WF-2. The Codex plugin cache is stale and the tracked skills resolve their coordinator from it

The Codex marketplace entry last updated 2026-07-21. The cache at
`~/.codex/plugins/cache/kanban/kanban/1.0.0/` is missing 8 of the 12 tracked
skills — `autoissue`, `design-epic`, `draft-report`, `issue`, `issue-review`,
`process-design-doc`, `process-report`, `repair` — and carries outdated
`pr-rereview`, `pr-revise`, `solve`, and `review_pr.py`. The tracked Codex
skills resolve their shared coordinator with `find` over
`$CODEX_HOME/plugins/cache`, so even a current tracked skill executes the stale
coordinator. From a Codex session today `$repair` does not exist and the
document workflows vendored by #229/#231 are absent. The Claude side is current
only because its directory-source marketplace serves commands live from the
repository.

**Evidence:**

- `~/.codex/config.toml` — `[marketplaces.kanban] last_updated = "2026-07-21T17:30:55Z"`, source `~/work/kanban/codex-plugin`.
- `diff -rq ~/.codex/plugins/cache/kanban/kanban/1.0.0 codex-plugin/plugins/kanban` — 8 missing skill directories, 4 differing files including `review_pr.py`.
- `docs/agent-workflow-contract.md:625-635` — documents the `find`-over-cache coordinator resolution.
- `tools/setup_workflows.py` — the convergent installer whose re-run repairs this.

**Handoff context:**

- **Current behavior:** Codex sessions run a three-week-old bundle; newly vendored capability is silently absent.
- **Expected direction:** refresh the install (`python3 tools/setup_workflows.py --apply`) and make staleness detectable — see WF-3 — or surfaced by preflight/janitor.
- **Scope and constraints:** the refresh itself is machine-local; a freshness check would touch preflight or workflow docs.
- **Remaining uncertainty:** whether `codex plugin` update semantics re-copy an unchanged-version bundle, which determines if WF-3 is the whole root cause.

### WF-3. Plugin manifests never version-bump, so caches cannot detect staleness

Both tracked `plugin.json` files still declare `1.0.0` while bundle contents
changed materially across #229/#231/#232. Provider caches are keyed by version
(`cache/kanban/kanban/1.0.0/`), so an unchanged version string makes a stale
cache indistinguishable from a current one. The manifests' descriptions also
lag: the Claude manifest omits `process-report` and `repair`; the tracked Codex
manifest describes 7 skills while shipping 12.

**Evidence:**

- `claude-plugin/plugins/kanban/.claude-plugin/plugin.json` — `"version": "1.0.0"`; description names 8 commands, directory ships 10.
- `codex-plugin/plugins/kanban/.codex-plugin/plugin.json` — `"version": "1.0.0"`; keywords/description name 7 skills, directory ships 12.
- `~/.codex/plugins/cache/kanban/kanban/1.0.0/.codex-plugin/plugin.json` — older manifest describing 4 skills, cached under the same version.

**Handoff context:**

- **Current behavior:** bundle changes land without a version change; caches pin the same `1.0.0` path forever.
- **Expected direction:** any change under `claude-plugin/` or `codex-plugin/` bumps that manifest's version in the same PR, and the plugin test suites enforce description-vs-contents parity.
- **Scope and constraints:** `tools/test_claude_plugin.py` / `tools/test_codex_plugin.py` already parse the bundles and are the natural enforcement point.
- **Remaining uncertainty:** none at draft time.

### WF-4. The two tracked review coordinators diverge beyond the documented model-pinning exception

`claude-plugin/plugins/kanban/scripts/review_pr.py` and
`codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py` differ in
both directions. The Claude copy's nested-model pinning is a documented,
deliberate divergence. The Codex copy's issue-vs-PR-number guard is not: it
gained `url_names_a_pull_request()` / `github_number_kind()` and a guarded
`gh pr view` that fails cleanly with "#N is an ISSUE, not a pull request",
while the Claude copy retains the bare unguarded call and fails messily when
given an issue number.

**Evidence:**

- `claude-plugin/plugins/kanban/scripts/review_pr.py:53-56` — pinned model constants, with an in-file comment declaring the deliberate divergence.
- `docs/agent-workflow-contract.md:115-125` — records the model-pinning exception; records no number-kind asymmetry.
- `codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py` — `url_names_a_pull_request`, `github_number_kind`, guarded `gh pr view`; absent from the Claude copy.

**Handoff context:**

- **Current behavior:** `/kanban:pr-review <issue-number>` on the Claude side produces an unguarded failure the Codex side reports cleanly.
- **Expected direction:** backport the number-kind guard to the Claude coordinator; either document every remaining divergence as deliberate or extract shared logic so only the pinning block differs.
- **Scope and constraints:** the coordinators are test-parsed plugin assets; changes ride the pr-atomic lane with the plugin suites.
- **Remaining uncertainty:** whether other undocumented deltas exist beyond the four the diff surfaced (models, guard, `verify_publication` signature, self-test block).

## Untracked load-bearing assets

### WF-5. trusted_issue_spec.py exists only in the personal Codex solve skill

`~/.codex/skills/solve/scripts/trusted_issue_spec.py` (6,488 bytes) appears
nowhere in the kanban repository, yet implements a stricter trust boundary than
the tracked solve skills: it honors issue comments only from the exact logins
`claude`/`codex`/`coghex`, where the tracked skill accepts the weaker
`author_association` OWNER/MEMBER/COLLABORATOR rule. The stronger security
control is unversioned, unreviewed, single-machine, and one brand only.

**Evidence:**

- `~/.codex/skills/solve/scripts/trusted_issue_spec.py` — exists; `find` over the kanban tree returns no counterpart.
- `codex-plugin/plugins/kanban/skills/solve/SKILL.md` — uses the `author_association` rule; no reference to the helper.

**Handoff context:**

- **Current behavior:** Codex-personal solve runs the strict allowlist; both tracked solve skills and Claude-side solve run the weaker rule.
- **Expected direction:** vendor the helper into the repository and adopt the login-allowlist rule in both tracked solve skills.
- **Scope and constraints:** trust-boundary change; deserves review as a security tightening, not a refactor.
- **Remaining uncertainty:** whether the exact-login rule is compatible with future collaborators beyond the three known logins.

### WF-6. The personal skill layer is unversioned and drifting between brands

Nine workflows exist only in personal directories — `epic`, `triage`,
`retriage`, `janitor`, `autosolve`, `project-review`, `backlog-review`,
`drain-prs` in both brands, `finalize` in Claude only — with no git history, no
backup, and measurable cross-brand drift (`drain-prs`: 147 diff lines between
`~/.claude/commands/drain-prs.md` and `~/.codex/skills/drain-prs/SKILL.md`;
`autosolve`: 48). The docs-routing "Where files go" convention is also
inconsistently present across copies of the vendored workflows. A machine loss
or an unnoticed divergence is a silent workflow loss.

**Evidence:**

- `~/.claude/commands/` and `~/.codex/skills/` — the nine names above absent from both plugin bundles.
- `docs/workflow-setup.md:45-46` — setup deliberately manages no personal skill copies; the layer is outside every contract.

**Handoff context:**

- **Current behavior:** brand copies of the same personal workflow are edited independently and diverge.
- **Expected direction:** one git-backed source per workflow (a dotfiles-style repo, or a non-release personal bundle) with both brands' copies derived from it.
- **Scope and constraints:** deliberately outside the kanban release surface; any in-repo home must stay out of the source distribution.
- **Remaining uncertainty:** which brand's variant is canonical for each drifted pair.

### WF-7. The vendored design workflows dropped the personal copies' decision-authority guardrails

The personal `design-epic` and `process-design-doc` carry a "Human interaction
and decision authority" section absent from the vendored Codex-plugin copies:
proposals-never-decisions, per-decision signoff, "at most three focused
questions," and "Never bury a blocking ambiguity in the document and proceed."
The vendored copies state the opposite for that last point ("Leave lesser
uncertainty in the document instead of blocking useful progress"). The tracked
source of truth is the more permissive text, so retiring the personal copies as
intended silently deletes the guardrails.

**Evidence:**

- `~/.claude/commands/design-epic.md`, `~/.claude/commands/process-design-doc.md` — contain the authority section.
- `codex-plugin/plugins/kanban/skills/design-epic/SKILL.md`, `.../process-design-doc/SKILL.md` — lack it; carry the permissive uncertainty sentence.

**Handoff context:**

- **Current behavior:** tracked and personal copies encode different signoff policies for the same workflow.
- **Expected direction:** merge the authority sections into the tracked skills, then retire the personal copies; the stricter policy should win deliberately, not lapse by default.
- **Scope and constraints:** content-only skill edits, pr-atomic lane; interacts with WF-9 if Claude-side copies are vendored.
- **Remaining uncertainty:** whether any of the permissive wording was an intentional relaxation during vendoring.

## Brand capability asymmetries

### WF-8. The issue repair-and-rereview loop is closeable only from Codex

`issue-rereview` exists solely as `~/.codex/skills/issue-rereview/`. Both
plugin bundles explicitly declare it outside the packaged set. A rejected
issue's repair-and-rereview loop therefore cannot be completed from a Claude
session at all — the drafting cycle is brand-asymmetric at its recovery step,
and the only implementation is personal-layer (WF-6).

**Evidence:**

- `~/.codex/skills/issue-rereview/` — sole copy; references `approve-issues.py` by a legacy hyphen spelling.
- `claude-plugin`/`codex-plugin` issue-review assets — both state the rereview workflow is "deliberately outside this bundle's packaged set."
- `docs/drafting-workflow-contract.md:35-43` — §2 asset table contains no issue-rereview row.

**Handoff context:**

- **Current behavior:** a changes-requested issue review can only be answered from Codex.
- **Expected direction:** a packaged rereview path both brands can run — either a vendored `issue-rereview` pair or rereview folded into the packaged `issue-review` assets.
- **Scope and constraints:** extends the drafting contract's declared asset set; its tests enumerate the packaged names and must move with it.
- **Remaining uncertainty:** whether keeping rereview out-of-bundle was a scoping decision with reasons not recorded in the contract.

### WF-9. The Claude plugin has no design-document or report-drafting workflows

`design-epic`, `process-design-doc`, and `draft-report` are Codex-only in the
tracked bundles — a declared asymmetry — and `note-problem` and `backlog` exist
only in the personal Codex layer. From a Claude session there is no tracked way
to draft a design document, process one, start a findings report, or append a
verified observation to one; personal Claude copies cover only the first two,
and they diverge from the tracked text (WF-7). This report itself had to be
drafted from the Codex skill's instructions for that reason.

**Evidence:**

- `docs/document-workflow-contract.md:100` — "Declared Codex-only asymmetry."
- `claude-plugin/plugins/kanban/commands/` — contains no `design-epic.md`, `process-design-doc.md`, or `draft-report.md`; `process-report.md` is the sole document workflow.
- `~/.codex/skills/note-problem/`, `~/.codex/skills/backlog/` — no Claude counterpart in any location.

**Handoff context:**

- **Current behavior:** document workflows are effectively single-brand despite both brands doing document-producing work.
- **Expected direction:** revisit the declared asymmetry; vendor Claude-side counterparts seeded from the richer personal variants per WF-7.
- **Scope and constraints:** touches the document-workflow contract's asset table and its test.
- **Remaining uncertainty:** whether drafting-experience differences between brands motivated the original asymmetry.

### WF-10. The kanban repository has no AGENTS.md

synarchy symlinks `AGENTS.md → CLAUDE.md` so both brands read one contract; kanban
has only `CLAUDE.md`. A Codex session opened in the kanban checkout (a trusted
project in the Codex config) reads no repository instructions: no lane rules,
no never-merge rule, no quality gates. The Codex-plugin skills even reference
"CLAUDE.md / AGENTS.md" as though both resolve.

**Evidence:**

- `~/work/synarchy/AGENTS.md` — symlink to `CLAUDE.md`; `~/work/kanban/AGENTS.md` — absent.
- `codex-plugin/plugins/kanban/skills/issue/SKILL.md` — instructs reading "CLAUDE.md / AGENTS.md".

**Handoff context:**

- **Current behavior:** Codex sessions in kanban operate without the repository contract.
- **Expected direction:** the same symlink synarchy uses.
- **Scope and constraints:** new tracked file — pr-atomic lane; confirm the source-distribution and document-classification tests accept a symlink.
- **Remaining uncertainty:** none at draft time.

## Merge path and durable state

### WF-11. Approved pull requests merge only while the drainer is explicitly kicked

Both drainer LaunchAgents are `RunAtLoad=false`, `KeepAlive=false`, with no
`StartInterval`: the service runs only while the kanban TUI (or a manual
kickstart) drives it, and each run ends "stopped intentionally." At audit time
four PRs (synarchy #1223/#1224/#1225, kanban #233) carried `reviewed:approve`
with green CI and sat unmerged because every approval landed after the last
run. The manual lane therefore has no merge path while the TUI is closed. This
may be the intended operating model, but no document states the decision.

**Evidence:**

- `~/Library/LaunchAgents/com.coghex.drain-prs.coghex.{kanban,synarchy}.plist` — no `StartInterval`; `RunAtLoad`/`KeepAlive` false.
- `~/Library/Logs/kanban/pr-drainer/*/service.out` — final lines "Interrupted; exiting / PR drainer stopped intentionally", timestamps preceding all four approvals.

**Handoff context:**

- **Current behavior:** approved work waits for the next TUI session or manual kickstart, indefinitely.
- **Expected direction:** a recorded decision — either doctrine ("merges happen while the board is open"; document it in `docs/pr-drainer.md`) or a modest `StartInterval` so approvals drain lane-independently.
- **Scope and constraints:** installer (`tools/install_drainer.py`) and pr-drainer docs if the interval is chosen.
- **Remaining uncertainty:** whether always-on draining conflicts with the deliberate user-controlled lifecycle the drain-prs workflow encodes.

### WF-12. The production drainer executes from the live development checkout

`~/Library/Application Support/kanban/pr-drainer/drain_prs.py`,
`drain_prs_service.py`, and `kanban_config.py` are symlinks into
`~/work/kanban/tools/`, and the issue-review backend resolves the same way. The
drainer that merges synarchy PRs therefore runs whatever is on disk in the
kanban working tree at that moment: a mid-edit file, a checked-out feature
branch, or a mid-rebase state changes production behavior for both
repositories. The inverse trade of WF-2 — never stale, but never isolated.

**Evidence:**

- `ls -la ~/Library/Application\ Support/kanban/pr-drainer/` — three symlinks into the checkout.
- Both LaunchAgent plists — execute `drain_prs_service.py` from that install dir with the checkout as working directory.

**Handoff context:**

- **Current behavior:** edits to `tools/` in the working tree hot-swap the running automation for both repositories.
- **Expected direction:** keep the symlink model but log an advisory when the resolved source differs from `origin/master` — report-only, never a refusal, per the manual-workflow-compatibility rule.
- **Scope and constraints:** drainer must keep working in a dirty checkout; advisory belongs in the service loop's existing log stream.
- **Remaining uncertainty:** whether a feature-branch checkout during long solve sessions occurs often enough to justify more than logging.

### WF-13. Kept autostash anchors and recovery stashes have no escalation or triage path

The drainer preserves autostash anchors and recovery stashes correctly, then
repeats a quiet log line forever; nothing escalates and nothing owns triage. At
audit time: synarchy anchor `refs/drain-prs/autostash/dd21df5a…` (2,247
insertions across 7 docs files, Aug 9) warned on every pass that it "may hold
the only copy of local changes"; kanban held four stashes including
`drain-prs-autostash-recovery` WIP touching `tools/approve_issues.py` and
`docs/design.md`, and two near-duplicate snapshots of the same
`drain_prs_service.py` WIP. These accumulate until a human notices the log.

**Evidence:**

- `~/Library/Logs/kanban/pr-drainer/coghex.synarchy/service.out` — the kept-anchor warning with restore instructions, repeated per pass.
- `git -C ~/work/kanban stash list` — four entries; `stash@{0}` contains uncommitted `approve_issues.py` and `design.md` changes.

**Handoff context:**

- **Current behavior:** possibly-sole copies of work sit in refs and stashes with only a per-pass log line.
- **Expected direction:** surface kept anchors and recovery stashes somewhere a human routinely looks — the janitor workflow's standing checks, a drainer incident after N passes, or the board UI.
- **Scope and constraints:** detection data already exists in the drainer; this is routing, not new analysis. The current instances also need one manual triage pass.
- **Remaining uncertainty:** whether the two near-duplicate kanban stashes are snapshots of identical work.

### WF-14. DW-1/DW-3/DW-10 defer on a clearing condition that is unsatisfiable as written

The three open findings in `docs/document_workflow_findings.md` defer on
DW-11, which is closed and whose vendoring landed. But the written clearing
condition can never be met: it requires the four document workflows to appear
in the *drafting* contract's §2 asset table — they landed in the separate
document-workflow contract instead — and to exist under
`claude-plugin/plugins/kanban/commands/`, though three of the four are declared
Codex-only. The deferrals will sit forever unless re-evaluated against the
contract that actually shipped.

**Evidence:**

- `docs/document_workflow_findings.md:81-86` — the clearing note naming `docs/drafting-workflow-contract.md` §2 and requiring Claude-side files.
- `docs/document-workflow-contract.md:39-43` — where the four workflows are actually declared.
- `docs/document-workflow-contract.md:100` — the declared Codex-only asymmetry that blocks the Claude-side half of the condition.

**Handoff context:**

- **Current behavior:** three findings are marked deferred on a precondition that is materially satisfied and literally impossible.
- **Expected direction:** re-evaluate DW-1, DW-3, and DW-10 against the shipped contract and rewrite or discharge the deferral notes.
- **Scope and constraints:** `document_workflow_findings.md` is a coordination document; its edits publish straight to master.
- **Remaining uncertainty:** whether DW-1 and DW-3 clear outright or convert to actionable issues once re-read.

## Documentation contract drift

### WF-15. design.md's status paragraph names a resolved release blocker

`docs/design.md:71-77` still states that `tools/test_source_distribution.py`
has one current failure — `docs/document_workflow_findings.md` tracked without
a release/exclusion decision — and that "release publication must wait" on
issue #225. That work landed: the file is in `EXCLUDED_TRACKED_PATHS` and
classified `coordination` in the agent-workflow contract. design.md is itself
classified implementation-coupled; this is the drift that classification
exists to prevent.

**Evidence:**

- `docs/design.md:71-77` — the stale status claim.
- `tools/test_source_distribution.py:104` — the exclusion entry.
- `docs/agent-workflow-contract.md:889` — the coordination classification.

**Handoff context:**

- **Current behavior:** the authoritative contract's opening status names a nonexistent release blocker.
- **Expected direction:** update the status paragraph to the post-#225 state.
- **Scope and constraints:** design.md is test-parsed; touch only the prose paragraph.
- **Remaining uncertainty:** none at draft time.

### WF-16. agent-workflow-contract prose drifts from its own manifest and tests

Three prose passages contradict the machine-checked reality beside them:
`:400` attributes the `ps` spawn to `src/Kanban/Worker.hs` while the manifest
row and the actual call are `src/Kanban/Process.hs:152`; `:807-808` claims the
check fails on a drainer LaunchAgent *plist* manifest row that does not exist
(the test asserts the label prefix, and `:203-208` says the plist deliberately
has no row, while `:234-236` calls it "not a personal path"); and `:756-763`
describes the plugin scan as a glob where `:562-565` correctly says it is an
enumerated list.

**Evidence:**

- `docs/agent-workflow-contract.md:400` vs `docs/agent-workflow-contract.md:596` and `src/Kanban/Process.hs:152`.
- `docs/agent-workflow-contract.md:807-808` vs `tools/test_agent_workflow_contract.py:1053-1068`.
- `docs/agent-workflow-contract.md:756-763` vs `:562-565` and `tools/test_agent_workflow_contract.py:64-76`.

**Handoff context:**

- **Current behavior:** a reader following the prose looks in the wrong module, expects a nonexistent manifest row, and misunderstands the scan mechanism.
- **Expected direction:** correct the three passages to match the manifest and tests, mirroring the `GitHub.hs → GitHub/Run.hs` correction already recorded at `:751-755`.
- **Scope and constraints:** prose-only edits to a test-parsed document; keep the parsed sections untouched.
- **Remaining uncertainty:** none at draft time.

### WF-17. Cross-reference and coverage omissions across the workflow documents

Four documents under-describe the shipped system: the drafting contract never
mentions the document-workflow contract though its §2 claims exhaustiveness
under an unstated name-scoping, and its §7 still calls the setup surface
"planned" (#78) though `tools/setup_workflows.py` shipped;
`docs/workflow-setup.md`'s per-action coverage list omits `repair` though its
own preamble includes it; `docs/pr-drainer.md`'s `coordination_paths` warning
names only 2 of the 6 test-parsed documents; and `docs/development.md`
describes the plugin bundles as only what "Kanban's AI actions invoke by name"
though twelve packaged workflows are never CLI-spawned.

**Evidence:**

- `docs/drafting-workflow-contract.md:45` and `:293-297` — the exhaustiveness claim and stale "planned" reference; zero grep hits for the document workflows.
- `docs/workflow-setup.md:143-164` vs `:8-9` — coverage bullets missing `repair`.
- `docs/pr-drainer.md:465-469` vs `docs/agent-workflow-contract.md:899-907` — 2 of 6 test-parsed rows named.
- `docs/development.md:70` and `:24` — the under-descriptions.

**Handoff context:**

- **Current behavior:** each document is individually defensible but a reader of any one of them gets an incomplete inventory.
- **Expected direction:** one cross-reference and wording pass; a single docs PR covers all four files, plausibly together with WF-15/WF-16.
- **Scope and constraints:** all four are pr-atomic release documents; two are test-parsed.
- **Remaining uncertainty:** none at draft time.

## Local install state

### WF-18. Codex config pins trusted hashes for a hooks file that no longer exists

`~/.codex/config.toml` carries `[hooks.state]` trusted hashes for five hooks
declared in `~/.codex/hooks.json` (`pre_tool_use`, `permission_request`,
`post_tool_use`, `user_prompt_submit`, `stop`), but that file does not exist.
Whatever those hooks enforced has silently stopped running, and the config no
longer reflects reality.

**Evidence:**

- `~/.codex/config.toml` — five `hooks.state."…hooks.json:…"` entries with trusted hashes.
- `ls ~/.codex/hooks.json` — no such file.

**Handoff context:**

- **Current behavior:** hook enforcement is silently absent; residual trust state persists.
- **Expected direction:** restore `hooks.json` if the hooks were intentional, else delete the residue.
- **Scope and constraints:** machine-local; no repository change unless the hooks belonged to the pipeline and deserve vendoring.
- **Remaining uncertainty:** what the five hooks did and where their source lives.

### WF-19. ~/work/drain_prs.py is an ungoverned launcher the contract does not cover

`~/work/drain_prs.py` is a bare symlink to `tools/drain_prs.py`, bypassing the
managed install dir the drainer docs designate. Its issue-review sibling
(`~/work/approve-issues.py`) is a governed legacy launcher with a contract
policy and a migration path; the drainer analogue has no policy statement at
all.

**Evidence:**

- `~/work/drain_prs.py` — symlink directly into the checkout.
- `docs/agent-workflow-contract.md:206-207` — the deferred personal-path list covers the approve-issues launcher; no drainer-launcher analogue anywhere.
- `docs/pr-drainer.md:69-70` — designates the managed install dir as the execution home.

**Handoff context:**

- **Current behavior:** an undocumented second entry point to production merging exists outside the managed install.
- **Expected direction:** retire the symlink, or give it the same governed-legacy-launcher status its sibling has.
- **Scope and constraints:** one contract sentence plus machine-local cleanup.
- **Remaining uncertainty:** whether anything (shell history, muscle memory, a script) still invokes it.

### WF-20. Superseded local backups and retired artifacts linger on the workstation

Verified-superseded litter accumulates where workflows live: eight
`*.pre-worktree.bak` files (five in `~/.claude/commands/`, three in
`~/.codex/skills/`), each a strict subset of its live file;
`~/Library/LaunchAgents/com.coghex.drain-prs.plist.retired`;
`~/Library/Application Support/kanban/legacy-claude-commands-2026-08-07/`; and
`~/work/approve-issues.py.pre-kanban-backup`. Individually harmless, together
they make the load-bearing inventory of the personal layer hard to read
(compare WF-1's ambiguity).

**Evidence:**

- `~/.claude/commands/*.pre-worktree.bak`, `~/.codex/skills/*/SKILL.md.pre-worktree.bak` — diffs against live files contain only additions in the live copy.
- `~/Library/LaunchAgents/com.coghex.drain-prs.plist.retired` — retired single-repo plist superseded by the per-repo pair.

**Handoff context:**

- **Current behavior:** backup and retired files sit beside live workflow definitions indefinitely.
- **Expected direction:** delete after a final confirmation pass; the migration-era backups fall with WF-1's cleanup.
- **Scope and constraints:** machine-local only; nothing in-repo.
- **Remaining uncertainty:** whether `legacy-claude-commands-2026-08-07/` holds any command that never made it into a live copy.
