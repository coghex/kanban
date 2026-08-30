# Workflow command vendoring design

Eight workflow commands are maintained only in the owner's personal collections.
Each exists as up to two hand-edited copies — one under `~/.claude/commands/`,
one under `~/.codex/skills/` — outside this repository's history and both plugin
bundles. A pull request can neither change nor verify them, the two brand copies
have already drifted apart, and nothing gates either. This arc brings them in as
tracked plugin assets, one command per delivery slice, so the generic workflow
lives where it can be reviewed, tested, and shipped.

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Vendor the personal workflow commands as tracked plugin assets — [#373]
- [x] VEND-0. Establish the shared-source mechanism for vendored commands — [#375]
- [x] VEND-1. Vendor triage — [#393]
- [x] VEND-2. Vendor retriage — [#427]
- [x] VEND-3. Vendor backlog-review — [#430]
- [x] VEND-4. Vendor project-review — [#462]
- [x] VEND-5. Vendor drain-prs — [#511]
- [x] VEND-6. Vendor the janitor census helper — [#574]
- [x] VEND-9. Vendor the janitor command over the census — [#575]
- [x] VEND-7. Vendor finalize — [#544]
- [x] VEND-8. Vendor autosolve — [#576]

## Epic contract

- **Goal:** every generic workflow command the owner uses ships from this
  repository as a tracked asset in both plugin bundles, with one reconciled
  source per command rather than two drifting personal copies.
- **Done when:** the eight commands below are tracked plugin assets rendered
  from one authored source per command, the personal copies are retired, the
  bundle manifest gate covers them, and invoking `kanban:<name>` in a consuming
  repository behaves as the copy D-7's reconciliation selected did.
- **Users and operators:** the owner, and any agent session driving the issue
  pipeline in a consuming repository.
- **Arc label:** `agent-workflows`

## Current state and evidence

Eight commands live under `~/.claude/commands/`: `autosolve`,
`backlog-review`, `drain-prs`, `finalize`, `janitor`, `project-review`,
`retriage`, `triage`. Seven have a Codex counterpart under `~/.codex/skills/`;
`finalize` does not.

None is tracked here, and the two brand copies have already diverged:

| command | claude lines | codex lines | differing lines |
|---|---|---|---|
| `autosolve` | 25 | 34 | 39 |
| `backlog-review` | 30 | 46 | 29 |
| `drain-prs` | 94 | 77 | 123 |
| `finalize` | 23 | absent | — |
| `janitor` | 23 | 134 | 143 |
| `project-review` | 79 | 220 | **223** |
| `retriage` | 179 | 179 | 10 |
| `triage` | 161 | 152 | 17 |

`project-review`'s Codex copy is nearly three times its Claude copy, and
`janitor`'s is now nearly six times — it was rewritten on 2026-08-20, after this
design last synced to it, and the 23/25/8 row this table carried until then
described a copy that no longer exists. No gate compares any of them, and no
test asserts either exists.

`janitor` is also the only command in the set whose Codex copy is more than one
file. Beside its `SKILL.md` sit `scripts/census.py` (641 lines),
`references/recovery-state.md` (52), `references/worktree-content.md` (37), and
`agents/openai.yaml` (4) — 734 lines of sibling material against a 134-line
skill body. D-12 through D-15 decide what becomes of it.

This repository already fixed the same defect once. #229 vendored the design and
report document workflows, recording in
`docs/drafting-workflow-contract.md:5-11` that while such assets "existed only
in an owner-maintained personal collection, a repository pull request could
neither change nor verify them." That reasoning applies unchanged to these eight.

The commands are already generic in the way that matters: none references
`synarchy` or any consuming repository. Only `autosolve` and `drain-prs` mention
Kanban tooling at all, and both do so because they drive this repository's own
pipeline components.

One exception has appeared since that survey. `janitor`'s Codex `scripts/census.py`
carries two hardcoded personal paths: `census.py:270` spells
`~/Library/Application Support/kanban/pr-drainer/drain_prs_service.py` directly
instead of asking `tools/kanban_config.py`'s `drainer_install_dir()`, so it finds
nothing on a Linux host or under a `KANBAN_DRAINER_INSTALL_DIR` override; and
`census.py:288-289` resolves `$CODEX_HOME/skills/test/scripts/test_coordinator.py`,
a personal Codex skill this arc does not vendor and Claude has no counterpart to.
D-15 repairs the first and keeps the second as a declared, fail-soft probe.

The existing bundles carry one hand-maintained copy per brand —
`claude-plugin/plugins/kanban/commands/<name>.md` and
`codex-plugin/plugins/kanban/skills/<name>/SKILL.md`. `tools/plugin_bundle_gate.py`
gates which assets are *mentioned versus shipped*; it does not compare their
content.

## Desired experience

The owner invokes `kanban:triage` — or any of the eight — from Claude or Codex,
in whatever repository the session is in, and gets the behavior the personal
copy had. Changing one is a pull request against this repository, reviewed and
gated like any other asset. A brand-specific difference is a deliberate,
reviewable line in a tracked file rather than an accident nobody can see.

## Scope

### In scope

- Reconciling each command's Claude and Codex copies into one tracked source per
  brand bundle, preserving deliberate brand differences and eliminating
  accidental drift.
- Registering each vendored command in the asset inventory and its gate.
- Retiring the personal copy once its vendored replacement ships.
- Renaming cross-command references so a vendored command invokes the command it
  actually means after vendoring.

### Out of scope

- Migrating the fourteen existing two-brand command pairs to the shared source.
  VEND-0 builds the mechanism for the eight vendored here; those pairs migrate
  later on their own schedule (D-6). Claude-only `/draft-issues` is excluded
  outright — it has no second copy to converge.
- Any behavioral redesign of a command beyond what reconciliation forces.
- The document-workflow helper resolution gap (#370). None of these eight
  references those helpers, so this arc neither depends on nor fixes it.
- The four commands already superseded by Kanban equivalents — `issue`,
  `autoissue`, `draft-issues`, `design-epic`.

## Design

Each slice is one command: reconcile, vendor into both bundles, register, retire
the personal copy. The unit is deliberately small so the arc can run alongside
unrelated work without ever holding a large change open. `janitor` is the one
exception, split across two slices by D-16 because its Codex copy brought a
641-line helper program with it; the eight commands are still eight, delivered
in nine slices after VEND-0.

**Reconciliation is the real work, not the move.** For each command the two
brand copies must be compared line by line and each difference classified as a
deliberate brand adaptation — invocation syntax, argument conventions, the
surrounding runtime's capabilities — or as drift. Deliberate differences survive
in both files; drift resolves to whichever copy is correct, and the slice records
which and why. A slice that copies one brand over the other without that pass
has discarded whichever improvements lived only in the loser.

**Cross-command references should be made precise when vendored.** Several
commands invoke others by bare slash name. An agent resolves those by name
regardless of prefix (D-4), so they are not broken today — but a vendored asset
should name the workflow it actually means:

- `retriage` invokes `/triage`
- `janitor` and `finalize` invoke `/drain-prs`
- `autosolve` invokes `/solve`, `/pr-review`, `/pr-rereview`, `/finalize`,
  `/issue`

Each such reference is made precise as part of its own slice. A slice landing
before its target is vendored leaves the reference resolving as it does today.

**`autosolve` carries a live override that must survive.** Its step 3 instructs
the session to use `/pr-review` and `/pr-rereview` while explicitly refusing
their `--self-review` premise, because those workflows assert that Kanban
spawned this session as the opposite-brand reviewer — false under `autosolve`,
which runs as the Claude solver that authored a `pr-origin:claude` PR. Passing
the flag would publish a self-review under `reviewers=codex`. Vendoring
`autosolve` therefore places, inside this repository, a command that instructs
overriding another of this repository's commands. That is legitimate and must be
preserved verbatim, and it stays stated in `autosolve` alone (D-8).

## Decisions

### D-1. One command per delivery slice

Each command is its own issue, worktree and pull request. Reconciliation is a
judgement pass over two files, and batching several makes a diff nobody can
review carefully. It also lets the arc progress in small increments between
other work, which is why this design exists at all.

### D-2. Vendored commands keep their present behavior

A slice reconciles and relocates; it does not redesign. Where the two brand
copies disagree on behavior, the slice picks one and records the reason, but it
does not introduce behavior neither copy had. Behavioral change is a later
issue against a now-reviewable asset.

### D-3. Single-source the vendored commands, mechanism first

The eight are authored once and rendered into both bundle layouts, rather than
maintained as two hand-edited copies. VEND-0 establishes that mechanism before
any command is vendored, because vendoring into the two-copy model and
collapsing later pays the reconciliation cost twice.

The mechanism is built for these eight only. Kanban's existing bundle commands
are **not** migrated here. Fourteen of the fifteen ship as two-brand pairs whose
copies are not mechanically convertible — `process-report`'s two differ by 169
body lines — so migrating them means reconciling fourteen pairs or building a
templating layer, which is its own arc (D-6). The fifteenth, `/draft-issues`,
has no pair at all: `docs/drafting-workflow-contract.md:60,79` makes it Claude
only by contract, and `:372` treats losing that boundary as a violation, so it
is outside any migration this arc could specify.

If VEND-0 finds the mechanism infeasible, its recorded outcome is the two-copy
model plus a content-parity gate, and the eight slices behind it each produce two
files instead of one.

### D-4. Retire each personal copy in its own slice

The personal copy is removed — or moved to a dated superseded directory, as the
2026-08-18 pass did — in the same pull request that ships its replacement.
Leaving both live is what produced the drift in the first place, and a
byte-identical description makes the two indistinguishable in the picker.

**Retiring a personal copy removes the bare name; it does not alias it.**
`plugin.json` declares only `"commands": "./commands/"`, with names taken from
filenames and no alias field, and removing `~/.claude/commands/process-report.md`
made `/process-report` unavailable rather than falling through to
`kanban:process-report`. After each slice the command is invoked as
`kanban:<name>`. Confirmed 2026-08-18: typing `/solve` in a fresh session
reports an unknown command, so a bare name genuinely does not fall through to
the plugin.

Agent-side resolution is more forgiving than the slash-command picker. A
vendored file that says "complete `/solve`" still works, because the agent
reading it resolves the named workflow — which is how `autosolve` drives
`kanban:solve` today without naming the prefix. Re-pointing a cross-command
reference during a slice is therefore for precision, not to repair a break.

### D-5. Name the repository explicitly on every tracker call

Each vendored command resolves the repository once at the start from the
session's checkout, echoes it to the user before its first mutation, and passes
`-R "$REPO"` on every `gh` invocation.

These commands do not publish documents, so they do not need the full
`## Establish the owning repository` section the document workflows carry — no
publication branch, no write root, no §7 lookup. What they do need is the part
that stops a cross-repository mutation: five of the eight mutate a tracker,
branches, worktrees, or merges, and `gh` without `-R` targets whatever repository
the session's directory happens to be in. The hazard is not theoretical — an
issue was filed into `coghex/kanban` from a session rooted in a different
repository during this design, and only an explicit `-R` sent it to the right
place. The echo is what catches the case where resolution was wrong.

### D-6. Do not migrate the existing bundle commands in this arc

The fourteen shipped commands that exist as two-brand pairs keep their two
hand-maintained copies. Migrating those pairs to the shared source is a separate
arc, justified by the same drift evidence but not blocking any slice here.
Claude-only `/draft-issues` is not part of it and never becomes a pair.

### D-7. Reconciliation picks a winner per command, and says why

Where the two brand copies disagree on behavior, the slice chooses one and
records the reason in its pull request. It does not merge both behaviors, and it
does not introduce behavior neither copy had (D-2). Where the Codex copy carries
real improvements the Claude copy lacks — `project-review` and `drain-prs` are
the likely cases — that is stated rather than silently resolved.

### D-8. `autosolve` keeps its override; the real fix is a separate issue

`pr-review` assumes Kanban launched the session as the opposite-brand reviewer
and tells it to pass `--self-review`. Under `autosolve` that is false — the
session is Claude and it authored the PR — so `autosolve` instructs the session
to ignore it.

That override stays where it is, stated in `autosolve` alone. `pr-review` is not
amended to describe the exception, and no caller-brand check is added here:
either would change behavior in a file this arc does not otherwise touch, which
D-2 rules out.

Teaching the review coordinator to refuse a self-review of a PR its caller wrote
would remove the need for the override entirely — and **#303 already did it**.
`review_pr.py:1277-1307` checks the caller's declared brand against the routed
one before any spawn, publish, or label switch, returning
`"status": "self_review_refused"`, and refuses an absent declaration exactly as
it refuses a mismatched one. `autosolve`'s instruction is therefore
belt-and-braces over an enforced guard, not the only thing preventing a bogus
publish. Do not re-file this.

### D-9. `project-review` is report-only, and the Codex copy's behavior wins

The two personal copies implement opposite terminal acts. The Claude copy drafts
issue bodies, stops for approval, and files them with `gh issue create`, treating
a findings report as an explicit-request exception. The Codex copy forbids
tracker writes outright — "do not modify code, push, touch merged PRs, or
create/edit tracker issues" — and writes a canonical findings report to the
branch-resolved `docs-wip` worktree whenever a completed batch has at least one
current finding.

The Codex behavior wins. This is D-7 applied rather than an exception to it: D-7
anticipated `project-review` as a likely case where the Codex copy carries real
improvements, and it does. Direct-commit mode with its parent-walking cursor, the
report-filename precedence, and the structured `Captured note` / `Verification` /
`Evidence` / `Handoff context` capture shape exist only there, and each is
downstream of writing a report rather than an issue body. Picking the Claude copy
would discard all three, which is the failure the `Design` section above names.

It also fits the lane this repository already built. `docs/project_review_386-361.md`
is tracked, `docs/agent-workflow-contract.md` §7 classifies it `coordination` /
`audit-report`, and `process-report` is the one-at-a-time disposition workflow
that turns such a report into tracker artifacts. Filing is therefore not lost,
only deferred one step — report, then `process-report`, then issue — and that
step routes a finding through the readiness gate a direct `gh issue create`
skips. A review workflow that never writes the tracker also cannot mis-file into
the wrong repository, which is the hazard D-5 exists for.

The cost is real and accepted: a Claude session loses the single-invocation
"review these and file three of them" path, and a one-finding batch now costs a
report plus a `process-report` run. The issue-body shape the Claude copy carried
— Background, Requirements, Acceptance, Out of scope, Related — does not move
into `project-review`; it already lives in the workflows that draft issues.

VEND-4's acceptance signals are rewritten to this model. The originals described
only the Claude copy, which is what made them unable to accept the slice.

### D-10. The boundary rule ships as prose; the asset does not

The Codex copy reads `references/review-boundaries.md` before selecting a range
and treats a recorded PR as an exclusive older endpoint. That rule is
instructions, and it renders into both brands as ordinary body prose. The file is
not instructions: its content is one consuming repository's cursor —
`coghex/synarchy`, stop before PR #1296, with #1210 excluded by the user — so
shipping it would put one consumer's state in every install and make recording
where a synarchy sweep stopped a pull request against this repository.

VEND-4 therefore ships no auxiliary asset, and `render_command_sources.py` is not
extended. Its one-file-per-brand shape — `commands/<name>.md` and
`skills/<name>/SKILL.md`, and nothing else — stays exactly as VEND-0 built it,
which is also why no bundle skill today carries a `references/` directory.
`process-report`'s `scripts/` is not a counterexample: those are tracked helper
programs, not rendered output.

The Codex copy's other sibling file needs no decision here. `agents/openai.yaml`
carries interface metadata, and VEND-1 through VEND-3 already established where
that goes — `codex-plugin/plugins/kanban/.codex-plugin/plugin.json`'s `interface`
block, beside the manifest's keywords and descriptions. VEND-4 follows that
established pattern mechanically.

### D-11. The sweep cursor lives in the reviewed repository's docs worktree

D-10 leaves the boundary data without a home. It lives at
`docs/project_review_boundaries.md` under the branch-resolved `docs-wip` worktree
of the repository being reviewed — the same `$DOCS_WT` resolution and the same
directory the reports themselves use, so it adds no write lane the workflow does
not already have. Per-repository state belongs in the repository it describes: it
is visible in a diff, reviewable, survives a change of machine, and is
per-repository by construction rather than by a key inside a shared file.

Two alternatives lost. A state file under the XDG namespace
`claude-plugin/plugins/kanban/scripts/kanban_config.py` already resolves on both
platforms would keep the workflow from writing into a reviewed repository at all
— but under D-9 it writes reports there regardless, so that purity is already
spent, and the cursor would be machine-local and invisible in a diff. Deriving
the cursor from the existing `project_review_*.md` filenames stores nothing and
is already the Codex copy's compaction-recovery path, but it is lossy in exactly
the ways the current file demonstrates: a clean batch writes no report, so a
clean range would be re-reviewed, and "#1210 intentionally excluded by the user"
is a fact no filename can carry.

One consequence lands on this repository specifically. When a sweep of
`coghex/kanban` itself records a boundary,
`docs/project_review_boundaries.md` needs its own `coordination` row in
`docs/agent-workflow-contract.md` §7, exactly as `docs/project_review_386-361.md`
has one. Without that row the fail-closed default makes the file `pr-atomic`, and
the cursor could not be landed the way the reports beside it are.

### D-12. `janitor` vendors the census architecture

The Codex copy's model wins: `scripts/census.py` emits a `janitor-census/v1`
snapshot, and the rendered body verifies anomalies, applies preservation gates,
reports, and applies approved items over that snapshot. The Claude copy's ten
hand-walked prose categories do not survive as the structure.

This is D-7 applied a second time, and for the same reason D-9 gave: the copy
that carries real improvements wins, and picking the other discards what lives
only there. What lives only in the Codex copy is not a nicer wording of the same
audit — it is the compact-census discipline that keeps a first pass from fetching
PR bodies, checks and stash patches in bulk; the `all-safe` preservation gates
that enumerate exactly what qualifies for bulk approval and what never does; the
`null`-is-not-empty rule that makes a failed inventory an anomaly rather than a
clean result; and the retention ledger that lets a "keep this" decision survive
between runs instead of being re-litigated every pass. The prose copy has none of
those, and none of them is reachable by rewording it.

This is the largest slice in the arc by a wide margin, and it is the one place
where D-1's "one command per delivery slice" buys the most: a 641-line program
and a 134-line body reviewed together is already at the edge of one PR.

Three consequences follow, each its own decision below: the two `references/`
files need a lane (D-13), the retention ledger needs a home (D-14), and
`census.py`'s two personal-path couplings need resolving (D-15).

`agents/openai.yaml` needs no decision. VEND-1 through VEND-3 established that
its interface metadata relocates into
`codex-plugin/plugins/kanban/.codex-plugin/plugin.json`'s `interface` block, and
VEND-6 follows that mechanically.

One structural fact the slice inherits rather than chooses. The Claude bundle has
a single shared `claude-plugin/plugins/kanban/scripts/`, and Codex has no shared
scripts root at all — every skill carries its own, as
`codex-plugin/plugins/kanban/skills/process-report/scripts/` does. A `census.py`
that resolves anything through `kanban_config.py` therefore adds a third
gated-identical copy of that module under `skills/janitor/scripts/`, and the
bundle-version gate makes touching the shared module drag both other copies with
it.

*Resolves Q-1.*

### D-13. The two `references/` files do not ship

`references/recovery-state.md` and `references/worktree-content.md` are not
vendored, in either brand. The rendered body carries a short recovery rule in
their place, and `render_command_sources.py` is not extended.

This lands in the same place D-10 did, by a different route. D-10 refused
VEND-4's `references/review-boundaries.md` because its *content* was one
consuming repository's cursor; these two are ordinary instructions, so that
reason does not reach them. What does reach them is D-10's mechanism half: the
one-file-per-brand shape VEND-0 built and five landed slices depend on stays
exactly as it is, and no bundle skill gains a `references/` directory. Extending
the renderer to emit auxiliary files was the alternative, and it lost because it
amends a mechanism ruling five slices are already built on in order to serve one
slice's convenience.

The cost is real and accepted, and it is larger than the fold-into-the-body
option would have been. Dropped outright are the five-step ladder for classifying
an unfamiliar path — `git check-ignore -v`, then exact-path `rg`, then the
producer's source and documentation, then `git log --all --`, then the producer's
own read-only `--validate`/`--status` mode — and the rule that no seed or write
mode is ever run during an audit. Also dropped is the explicit
`unrecovered` / `fully landed` / `contradicted` classification vocabulary,
though the Claude copy's category 10 carries most of that judgement inline
already, which is what makes this less lossy than the line count suggests.
Anything from those two files that the slice finds it cannot do without is folded
into the body as prose rather than reintroduced as a file.

*Resolves Q-2.*

### D-14. The retention ledger stays in the Git common directory

`janitor-retain.json` keeps the location the Codex copy gives it:
`$(git rev-parse --git-common-dir)/janitor-retain.json`, holding
`janitor-retain/v1` items of `id`, `target`, `disposition`, `reason` and
`review_when`. It is shared across every linked worktree of the repository, sits
inside none of them, and is never committed.

D-11 sent VEND-4's sweep cursor to the reviewed repository's docs worktree, and
this decision deliberately does not follow it, because the two hold different
kinds of fact. A sweep cursor names pull request numbers — global, portable,
meaningful on any machine, and worth reviewing in a diff. A retention decision
names `stash@{3}`, a local worktree path, an unmerged local branch: objects that
do not exist on another machine and whose selectors shift between runs. Committing
that produces a tracked file that rots by the next `git stash drop`, which is a
worse failure than invisibility.

Two alternatives lost. The docs-worktree lane (D-11's) loses on the rot above,
and would additionally need a `coordination` §7 row plus its
`EXCLUDED_TRACKED_PATHS` and `config.toml.example` counterparts. Resolving it
through `kanban_config.py`'s XDG namespace keeps the machine-local property but
buys nothing over `--git-common-dir` — the state is already per-repository by
construction there, whereas an XDG path has to key itself by repository — and it
would add a new managed-path family with its own inventory rows.

The invisibility objection is accepted rather than answered. Nothing reviews a
"keep this forever" entry, and the ledger dies with the clone. The skill body's
existing rule is what bounds it: the ledger is a reminder, never an exemption
from live evidence or an approval gate, every recorded target and its
`review_when` condition is revalidated each run, and a stale or contradicted
entry is reported as a decision rather than silently discarded.

*Resolves Q-3.*

### D-15. One coupling is repaired, the other is kept and declared

`census.py`'s two personal-path couplings get different answers, because they
are different problems.

**The drainer path is repaired.** `census.py:270` spells
`~/Library/Application Support/kanban/pr-drainer/drain_prs_service.py` directly,
which finds nothing on a Linux host, ignores `KANBAN_DRAINER_INSTALL_DIR`, and
ignores an `--install-dir` install. The vendored census resolves it through
`tools/kanban_config.py` — the one Python resolution point, already shipped in
both bundles — exactly as VEND-5 made the `drain-prs` asset do, and
`docs/agent-workflow-contract.md`'s two install-directory rows gain both rendered
`census.py` paths the way they gained both rendered `drain-prs` paths.

**The test-coordinator probe is kept.** `census.py:288-289` resolves
`$CODEX_HOME/skills/test/scripts/test_coordinator.py` to recognize the
coordinator-owned detached test base as permanent infrastructure and to report
its per-run worktrees. That skill is not vendored by this arc and has no Claude
counterpart, but the probe already fails soft — an absent coordinator returns
`{"available": false}` — so an install without it reports nothing rather than
breaking. Dropping the category was the alternative, and it loses because those
worktrees would then surface as unexplained anomalies the janitor proposes
cleaning, which is the precise false positive the category exists to prevent.
Making it generic through a new environment variable or config key was the other,
and it loses because a default that finds nothing means the owner must configure
it to keep today's behavior, in exchange for a config surface this arc does not
otherwise touch.

Keeping it is conditional on declaring it. `docs/agent-workflow-contract.md`
already carries a `codex-plugin-cache-root` personal-path row for `/.codex`
marked `external`, so the inventory has the shape; the vendored census's two
rendered paths are named on it, or on a row of its own, and the slice does not
ship until they are. The asymmetry is deliberate and worth stating plainly: the
Claude-side render probes a Codex-side personal skill, and reports nothing when
it is absent, which is every Claude install.

*Resolves Q-4.*

### D-16. `janitor` is delivered in two slices, program then command

VEND-6 ships `census.py` with its tests and its two path resolutions, and VEND-9
ships the rendered body over it. This is the only command in the arc that takes
two pull requests.

D-1 is not weakened by this. It says each *command* is its own issue, worktree
and pull request, because batching several makes a diff nobody can review
carefully — and that reasoning is what splits this one rather than what forbids
splitting it. Unsplit, VEND-6 measured about 3,900 to 4,250 insertions against
VEND-5's 1,685: `census.py` twice at 641 lines, a fourth 1,155-line
`kanban_config.py` home, a test module the size of VEND-5's whole suite, and
only then a body of about 450 lines. That is not a reviewable unit.

Size alone would not decide it; concentration does. The program is roughly 84%
of that diff and would draw more than 84% of the findings — it is new code doing
path resolution, subprocess handling, a JSON schema contract and two personal-path
repairs, which is the shape that yields one blocker per review round. The body is
prose, and VEND-1 through VEND-3 showed prose lands in one or two. Splitting puts
the rounds where the risk is instead of holding a 4,000-line diff open across all
of them.

The seam is the one VEND-0 already proved in this arc: ship a mechanism first,
demonstrated by tests, with nothing invokable. VEND-6 adds no command to either
bundle, so `tools/plugin_bundle_gate.py` sees no new shipped asset and the
personal copies stay live until VEND-9 replaces them, which is what D-4 requires
— the retirement belongs to the pull request that ships the replacement, and
VEND-6 ships no replacement.

Two consequences worth stating. VEND-6 depends on nothing in the arc and can land
first, in parallel with VEND-7 or VEND-8, because it renders no file and so
VEND-0's one-file-per-brand outcome does not bind it. And the umbrella epic #373
carried a single `VEND-6. Vendor janitor` checklist line, which this split turned
into drift; the `/process-design-doc` run that filed VEND-6 as #574 reconciled it
into two on 2026-08-30, with approval, before drafting either.

*Recorded 2026-08-27, on the owner's instruction to split whatever needed it.*

## Open questions

None outstanding. All four below were VEND-6's, and VEND-6's alone — they
arrived with the `janitor` Codex rewrite that landed on 2026-08-20, after the
last design sync, and each now carries its decision. They are kept here with
their `Resolved by` pointers rather than deleted, because the options that lost
are part of why the decisions read as they do. No slice waits on anything.

### Q-1. Which janitor architecture survives? — Resolved by D-12

The two copies are no longer two spellings of one audit. The Claude copy is ten
numbered prose categories an agent walks by hand, each with its own remedy line.
The Codex copy is a helper — `scripts/census.py`, 641 lines — that emits a
`janitor-census/v1` snapshot the skill body then reasons over, with the body cut
to verification, preservation gates, reporting and apply.

D-7 says reconciliation picks a winner per command and says why, and D-2 says a
slice does not introduce behavior neither copy had. What D-7 did not anticipate
is a divergence this deep: this is not "the Codex copy carries real
improvements", it is two designs for the same command. The choice decides
whether VEND-6 vendors a Markdown file or a Markdown file plus a program.

Known options: the census architecture; the prose architecture; or the prose
architecture now with the census deferred to its own later slice.

**Resolved 2026-08-27:** the census architecture, as D-12.

### Q-2. Do the sibling assets ship, and through which lane? — Resolved by D-13

`references/recovery-state.md` and `references/worktree-content.md` are
instructions, not state — unlike VEND-4's `references/review-boundaries.md`,
whose content was one consuming repository's cursor, which is the whole reason
D-10 refused it. So D-10's *reason* does not reach these two, but D-10's
*mechanism ruling* does: `render_command_sources.py` stays one file per brand,
and no bundle skill carries a `references/` directory.

That leaves three shapes. Fold both files' content into the rendered body, which
costs about 89 lines on top of 134 and keeps the renderer untouched. Extend the
renderer to emit auxiliary files, which D-10 declined for VEND-4 but did not
forbid for ever. Or drop them and let the body carry a shorter rule.

`scripts/census.py` is a separate question from the two references even though
Q-2 covers both, because a tracked helper program is not rendered output at all:
`process-report` already ships `publish_coordination_doc.py` and
`tracker_transaction.py` beside its asset, which D-10 explicitly names as not a
counterexample to the one-file-per-brand rule. If Q-1 keeps the census, the lane
for the program is that established `scripts/` lane rather than the renderer.

One asymmetry the shape has to survive: the Claude bundle has a single shared
`claude-plugin/plugins/kanban/scripts/`, while Codex has no shared scripts root
at all — each skill carries its own, as
`codex-plugin/plugins/kanban/skills/process-report/scripts/` does. A census that
imports `kanban_config.py` therefore adds a third gated-identical copy of that
module under `skills/janitor/scripts/`.

**Resolved 2026-08-27:** neither references file ships, as D-13. `census.py`
ships in each bundle's helper-program lane, as D-12 records.

### Q-3. Where does the retention ledger live? — Resolved by D-14

`census.py:17` and its reader put the ledger at
`$(git rev-parse --git-common-dir)/janitor-retain.json` — inside `.git`, shared
across every linked worktree, machine-local, and invisible in a diff. It carries
`janitor-retain/v1` items of `id`, `target`, `disposition`, `reason`,
`review_when`.

D-11 answered the same shape of question for VEND-4's sweep cursor and chose the
reviewed repository's `docs-wip` worktree, reasoning that per-repository state
belongs in the repository it describes, visible in a diff and surviving a change
of machine. Whether that reasoning transfers is genuinely open: a retention
decision about a local worktree or stash may be exactly the machine-local fact
D-11's rejected XDG alternative was accused of being, since the objects it names
do not exist on another machine.

Known options: keep it under `--git-common-dir` as the copy has it; move it to
the reviewed repository's docs worktree as D-11 did; or resolve it through
`kanban_config.py`'s XDG namespace.

**Resolved 2026-08-27:** the Git common directory, as D-14.

### Q-4. What becomes of `census.py`'s two personal-path couplings? — Resolved by D-15

`census.py:270` hardcodes
`~/Library/Application Support/kanban/pr-drainer/drain_prs_service.py`. Kanban
has exactly one Python resolution point for that — `tools/kanban_config.py`'s
`drainer_install_dir()` / `installed_drainer_dir()` — and it already ships in
both bundles, so the repair is available rather than hypothetical. VEND-5 fixed
the identical defect in the `drain-prs` asset and
`docs/agent-workflow-contract.md`'s inventory now names both rendered paths on
the two install-directory rows, which is the precedent.

`census.py:288-289` is different in kind: it resolves
`$CODEX_HOME/skills/test/scripts/test_coordinator.py` and reports coordinated-test
worktrees from it. That skill is not vendored by this arc, has no Claude
counterpart, and its absence is already handled — the function returns
`{"available": False}`. So the question is whether the vendored census keeps a
Codex-only optional probe, drops the coordinated-test category entirely, or
keeps it behind something generic.

**Resolved 2026-08-27:** the drainer path repaired, the test-coordinator probe
kept and declared, as D-15.

## Verification strategy

Arc-level signals:

- The bundle manifest gate (`tools/plugin_bundle_gate.py`) lists each vendored
  command as both mentioned and shipped, for both brands.
- The drafting-workflow contract's asset inventory and its test cover each
  vendored command, so a future change cannot ship a command the inventory does
  not declare — the enforcement #229 established.
- Invoking each vendored command in a consuming repository reproduces the
  behavior of whichever copy that slice's reconciliation selected under D-7 —
  which for `project-review` is the Codex copy, per D-9, and not the Claude one.
  This is demonstrated per slice rather than asserted, because none of these
  commands has automated behavioral coverage today. VEND-6 is the one exception
  D-12 creates: `scripts/census.py` is a program, so its snapshot is asserted by
  a test module and its own `--self-test` rather than demonstrated by hand, and
  only the reasoning the rendered body does over that snapshot stays a
  demonstration.
- Every path a vendored asset resolves is declared in
  `docs/agent-workflow-contract.md`'s external-dependency inventory, naming both
  rendered paths. VEND-5 established this for the drainer install directories;
  D-15 extends it to `census.py`'s drainer resolution and to the personal Codex
  skill its test-coordinator probe reaches for.
- No personal copy remains live for a command whose replacement has shipped.

## Delivery plan

### VEND-0. Establish the shared-source mechanism for vendored commands

- **Outcome:** one authored source per vendored command renders into both bundle
  layouts, or a recorded decision that two copies plus a content-parity gate is
  the answer instead.
- **Scope:** the mechanism and its gate, proved against a **fixture** that is
  authored and rendered but never shipped as an invokable command. No command is
  vendored by this slice, and none of the existing bundle commands is
  migrated (D-6). Proving the mechanism on a real command would vendor it, which
  this slice explicitly does not do; the first real rendering is VEND-1's.
- **Phase:** 0
- **Depends on:** `none`
- **Ordering:** `critical path` — its outcome decides whether every later slice
  produces one file or two.
- **Relevant decisions:** D-3, D-6
- **Acceptance signals:** one authored fixture source renders into both bundle
  layouts, and the rendered outputs match what each brand's loader expects;
  re-running the renderer over unchanged input produces no diff; the fixture is
  absent from both bundles' shipped command sets, so nothing new is invokable;
  and `tools/plugin_bundle_gate.py` still passes. If the mechanism is rejected
  instead, the pull request records why and what the content-parity gate checks
  in its place.
- **Out of scope:** vendoring any of the eight; migrating existing commands;
  changing any command's behavior.
- **Open questions:** `None`

### VEND-1. Vendor triage

- **Outcome:** `kanban:triage` ships in both bundles; the personal copies retire.
- **Scope:** reconcile the 17 differing lines between the Claude and Codex
  copies; register in the inventory and bundle gate; retire the personal copies.
- **Phase:** 1
- **Depends on:** `VEND-0`
- **Ordering:** `critical path` — `retriage` preserves this command's rendered
  sections, so vendoring it first fixes the shared vocabulary once.
- **Relevant decisions:** D-1, D-2, D-3, D-4, D-5, D-7
- **Acceptance signals:** both bundles ship it; the gate lists it; a real triage
  run in a consuming repository produces the same section structure as the
  retired copy, including the hotfix-first ordering tier.
- **Out of scope:** any change to the ordering heuristics beyond what
  reconciliation forces.
- **Open questions:** `None`

### VEND-2. Vendor retriage

- **Outcome:** `kanban:retriage` ships in both bundles; the personal copies retire.
- **Scope:** reconcile 10 differing lines; re-point its `/triage` reference at
  the vendored command; register and retire.
- **Phase:** 1
- **Depends on:** `VEND-0`, `VEND-1`
- **Ordering:** `critical path` — it preserves triage's sections and must match
  the vendored triage's vocabulary.
- **Relevant decisions:** D-1, D-2, D-4, D-5, D-7
- **Acceptance signals:** a retriage run over a roadmap produced by the vendored
  triage makes minimal stable edits and preserves its section structure.
- **Out of scope:** changing the roadmap format.
- **Open questions:** `None`

### VEND-3. Vendor backlog-review

- **Outcome:** `kanban:backlog-review` ships in both bundles; personal copies retire.
- **Scope:** reconcile 29 differing lines across a 30-line and a 46-line copy;
  register and retire.
- **Phase:** 1
- **Depends on:** `VEND-0`
- **Ordering:** `independent` — it invokes no other command.
- **Relevant decisions:** D-1, D-2, D-4, D-5, D-7
- **Acceptance signals:** a backlog-review run proposes per-issue dispositions
  and applies only approved ones.
- **Out of scope:** changing the disposition vocabulary.
- **Open questions:** `None`

### VEND-4. Vendor project-review

- **Outcome:** `kanban:project-review` ships in both bundles; personal copies retire.
- **Scope:** reconcile the largest divergence in the set — 223 differing lines,
  with the Codex copy at 220 lines against the Claude copy's 79 — resolving it to
  the Codex copy's report-only behavior (D-9); fold the boundary rule into the
  rendered body while shipping no `references/` asset (D-10); establish the sweep
  cursor at `docs/project_review_boundaries.md` in the reviewed repository's docs
  worktree, with the `coordination` §7 row this repository's own copy needs
  (D-11); relocate `agents/openai.yaml`'s interface content into `plugin.json`'s
  `interface` block as VEND-1 through VEND-3 did; register and retire.
- **Phase:** 2
- **Depends on:** `VEND-0`
- **Ordering:** `independent`, but the heaviest reconciliation; do not schedule
  it as a warm-up.
- **Relevant decisions:** D-1, D-2, D-4, D-5, D-7, D-9, D-10, D-11
- **Acceptance signals:** a project-review run over a bounded batch writes one
  canonical findings report to the branch-resolved `docs-wip` worktree and
  creates no tracker item; a clean batch writes no report and still preserves its
  cursor; the boundary rule appears in both rendered bodies while neither bundle
  gains a `references/` directory; and the pull request records that the Codex
  copy's behavior won, per D-9.
- **Out of scope:** extending the audit's scope; extending
  `render_command_sources.py` to emit auxiliary files, which D-10 removes the
  need for; and any change to `process-report`'s own disposition behavior, which
  already accepts a report of this shape.
- **Open questions:** `None`

### VEND-5. Vendor drain-prs

- **Outcome:** `kanban:drain-prs` ships in both bundles; personal copies retire.
- **Scope:** reconcile 123 differing lines; confirm every drainer subcommand and
  path it names still matches this repository's drainer; register and retire.
- **Phase:** 2
- **Depends on:** `VEND-0`
- **Ordering:** `critical path` — `janitor` and `finalize` both invoke it.
- **Relevant decisions:** D-1, D-2, D-4, D-5, D-7
- **Acceptance signals:** each documented subcommand — status, install, start,
  stop, restart, logs, incident, recover — behaves as before against the real
  drainer.
- **Out of scope:** changing drainer behavior; this slice vendors its control
  surface only.
- **Open questions:** `None`

### VEND-6. Vendor the janitor census helper

- **Outcome:** `scripts/census.py` ships in both bundles' helper-program lanes,
  emitting a `janitor-census/v1` snapshot, with both of D-15's path resolutions
  settled. No command becomes invokable and no personal copy retires yet.
- **Scope:** the program, its helper-module homes, and its tests. Repair the
  drainer resolution through `kanban_config.py` and add the fourth home that
  needs — Codex has no shared scripts root, so `skills/janitor/scripts/` carries
  its own gated-identical copy, and the enumerations in
  `tools/test_source_distribution.py` and `tools/test_agent_workflow_contract.py`
  grow with it. Keep the test-coordinator probe and declare it, plus the
  `census.py` paths on the two drainer install-directory rows. Read the retention
  ledger from the Git common directory (D-14).
- **Phase:** 2
- **Depends on:** `none`
- **Ordering:** `independent`, and it `can land first`. It renders nothing, so
  VEND-0's one-file-per-brand outcome does not bind it, and it shares no file
  with VEND-7 or VEND-8.
- **Relevant decisions:** D-12, D-14, D-15
- **Acceptance signals:** `census.py --self-test` passes; a census over a real
  repository emits a `janitor-census/v1` document whose worktree, branch, ref,
  claim, stash and drainer collections match what Git and the drainer controller
  independently report; the drainer block is populated on a host whose install
  lives under the XDG data root and under a `KANBAN_DRAINER_INSTALL_DIR`
  override, which the retired copy's hardcoded macOS path could not do; a machine
  with no test coordinator yields `available: false` rather than an error; a
  retain-ledger entry at `$(git rev-parse --git-common-dir)/janitor-retain.json`
  is read back by a run started from a different linked worktree; an unreadable
  collection is reported as `null` and never as empty; and both bundles' shipped
  command sets are unchanged, so `tools/plugin_bundle_gate.py` still passes with
  nothing new invokable.
- **Out of scope:** the rendered `janitor` body and every registration and
  retirement it carries, which is VEND-9; and changing what counts as a stale
  signal.
- **Open questions:** `None`

### VEND-9. Vendor the janitor command over the census

- **Outcome:** `kanban:janitor` ships in both bundles, reasoning over VEND-6's
  snapshot; the personal copies retire.
- **Scope:** the authored source and its two renders — verify anomalies, apply
  the `all-safe` preservation gates, report, and apply approved items over the
  `janitor-census/v1` document. Fold the Claude copy's surviving judgement into
  that body rather than discarding it, and carry a short recovery rule in place
  of the two `references/` files D-13 drops. Re-point its `/drain-prs`
  reference; register in both manifests, both READMEs and the bundle gate;
  retire the personal copies.
- **Phase:** 2
- **Depends on:** `VEND-0`, `VEND-5`, `VEND-6`
- **Ordering:** `not on the critical path`
- **Relevant decisions:** D-1, D-2, D-4, D-5, D-7, D-12, D-13
- **Acceptance signals:** both bundles ship it and the gate lists it as mentioned
  and shipped; a janitor run over a real repository reports anomalies only,
  states what `all-safe` excludes, and mutates nothing before approval; a run
  against a census reporting a `null` collection treats it as an anomaly to
  diagnose rather than a clean result; neither bundle gains a `references/`
  directory; and no personal `janitor` copy remains live.
- **Out of scope:** changing `census.py`, which VEND-6 settles; extending
  `render_command_sources.py` to emit auxiliary files, which D-13 removes the
  need for; and vendoring the personal `test` skill the census probes, which
  D-15 keeps as an optional, declared, fail-soft dependency.
- **Open questions:** `None`

### VEND-7. Vendor finalize

- **Outcome:** `kanban:finalize` ships in both bundles; the personal copy retires.
- **Scope:** author the missing Codex counterpart from the single Claude copy;
  re-point its `/drain-prs`, `/pr-review` and `/pr-rereview` references;
  register and retire.
- **Phase:** 3
- **Depends on:** `VEND-0`, `VEND-5`
- **Ordering:** `not on the critical path`
- **Relevant decisions:** D-1, D-2, D-3, D-4, D-5, D-7
- **Acceptance signals:** both bundles ship it; the command still presents itself
  as the manual fallback for when the drainer cannot be used, rather than the
  ordinary merge path.
- **Out of scope:** making it the default merge route.
- **Open questions:** `None`

### VEND-8. Vendor autosolve

- **Outcome:** `kanban:autosolve` ships in both bundles; personal copies retire.
- **Scope:** reconcile 39 differing lines; re-point `/solve`, `/pr-review`,
  `/pr-rereview`, `/finalize` and `/issue`; preserve the `--self-review`
  override and the two recorded owner decisions verbatim; register and retire.
- **Phase:** 3
- **Depends on:** `VEND-0`, `VEND-7`
- **Ordering:** `critical path` within phase 3 — it orchestrates the others and
  is the most exposed to their names changing.
- **Relevant decisions:** D-1, D-2, D-4, D-5, D-7, D-8
- **Acceptance signals:** an autosolve run reaches `reviewed:approve` through a
  genuine Codex review — the published result reports `"status": "reviewed"`
  with a `reviewers=codex` marker, never `awaiting_self_review` — and still
  stops short of merging.
- **Out of scope:** auto-finalizing, and dropping the sandbox bypass. Both are
  decisions the owner made deliberately; revisiting either is a separate issue.
- **Open questions:** `None`

## Source notes

Two owner decisions recorded for `autosolve` that VEND-8 must not silently
change:

1. `codex exec` runs with `--dangerously-bypass-approvals-and-sandbox`, accepted
   because non-interactive `exec` has no human to approve a prompt and the
   project is already fully trusted for interactive Codex use.
2. `autosolve` stops at `reviewed:approve` and does not auto-run `/finalize`;
   the merge stays a deliberate manual step.
