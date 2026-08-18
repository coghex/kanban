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

- [ ] EPIC. Vendor the personal workflow commands as tracked plugin assets
- [ ] VEND-0. Establish the shared-source mechanism for vendored commands
- [ ] VEND-1. Vendor triage
- [ ] VEND-2. Vendor retriage
- [ ] VEND-3. Vendor backlog-review
- [ ] VEND-4. Vendor project-review
- [ ] VEND-5. Vendor drain-prs
- [ ] VEND-6. Vendor janitor
- [ ] VEND-7. Vendor finalize
- [ ] VEND-8. Vendor autosolve

## Epic contract

- **Goal:** every generic workflow command the owner uses ships from this
  repository as a tracked asset in both plugin bundles, with one reconciled
  source per command rather than two drifting personal copies.
- **Done when:** the eight commands below are tracked plugin assets rendered
  from one authored source per command, the personal copies are retired, the
  bundle manifest gate covers them, and invoking `kanban:<name>` in a consuming
  repository behaves as the retired personal copy did.
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
| `janitor` | 22 | 24 | 8 |
| `project-review` | 79 | 220 | **223** |
| `retriage` | 179 | 179 | 10 |
| `triage` | 161 | 152 | 17 |

`project-review`'s Codex copy is nearly three times its Claude copy. No gate
compares them, and no test asserts either exists.

This repository already fixed the same defect once. #229 vendored the design and
report document workflows, recording in
`docs/drafting-workflow-contract.md:5-11` that while such assets "existed only
in an owner-maintained personal collection, a repository pull request could
neither change nor verify them." That reasoning applies unchanged to these eight.

The commands are already generic in the way that matters: none references
`synarchy` or any consuming repository, and none carries a hardcoded personal
path. Only `autosolve` and `drain-prs` mention Kanban tooling at all, and both
do so because they drive this repository's own pipeline components.

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

- Migrating the fifteen existing bundle commands to the shared source. VEND-0
  builds the mechanism for the eight vendored here; the existing commands
  migrate later on their own schedule (D-6).
- Any behavioral redesign of a command beyond what reconciliation forces.
- The document-workflow helper resolution gap (#370). None of these eight
  references those helpers, so this arc neither depends on nor fixes it.
- The four commands already superseded by Kanban equivalents — `issue`,
  `autoissue`, `draft-issues`, `design-epic`.

## Design

Each slice is one command: reconcile, vendor into both bundles, register, retire
the personal copy. The unit is deliberately small so the arc can run alongside
unrelated work without ever holding a large change open.

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

The mechanism is built for these eight only. Kanban's fifteen existing commands
are **not** migrated here: their brand copies are not mechanically convertible —
`process-report`'s two copies differ by 169 body lines — so migrating them means
reconciling fifteen pairs or building a templating layer, which is its own arc
(D-6).

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

Kanban's fifteen shipped commands keep their two hand-maintained brand copies.
Migrating them to the shared source is a separate arc, justified by the same
drift evidence but not blocking any slice here.

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

## Open questions

None. Every question raised during design is recorded as a decision above.

## Verification strategy

Arc-level signals:

- The bundle manifest gate (`tools/plugin_bundle_gate.py`) lists each vendored
  command as both mentioned and shipped, for both brands.
- The drafting-workflow contract's asset inventory and its test cover each
  vendored command, so a future change cannot ship a command the inventory does
  not declare — the enforcement #229 established.
- Invoking each vendored command in a consuming repository reproduces the
  retired personal copy's behavior. This is demonstrated per slice rather than
  asserted, because none of these commands has automated behavioral coverage
  today.
- No personal copy remains live for a command whose replacement has shipped.

## Delivery plan

### VEND-0. Establish the shared-source mechanism for vendored commands

- **Outcome:** one authored source per vendored command renders into both bundle
  layouts, or a recorded decision that two copies plus a content-parity gate is
  the answer instead.
- **Scope:** the mechanism and its gate, exercised on one command as proof. No
  command is vendored by this slice, and none of the fifteen existing bundle
  commands is migrated (D-6).
- **Phase:** 0
- **Depends on:** `none`
- **Ordering:** `critical path` — its outcome decides whether every later slice
  produces one file or two.
- **Relevant decisions:** D-3, D-6
- **Acceptance signals:** the proof command is shipped in both bundles from one
  source; `tools/plugin_bundle_gate.py` lists it as mentioned and shipped for
  both brands; if the mechanism is rejected, the pull request records why and
  what the parity gate checks instead.
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
  with the Codex copy at 220 lines against the Claude copy's 79 — deciding
  explicitly which behavior survives; register and retire.
- **Phase:** 2
- **Depends on:** `VEND-0`
- **Ordering:** `independent`, but the heaviest reconciliation; do not schedule
  it as a warm-up.
- **Relevant decisions:** D-1, D-2, D-4, D-5, D-7
- **Acceptance signals:** a project-review run audits recent merged PRs and
  drafts findings without filing anything unapproved; the pull request states
  which copy's behavior won and why.
- **Out of scope:** extending the audit's scope.
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

### VEND-6. Vendor janitor

- **Outcome:** `kanban:janitor` ships in both bundles; personal copies retire.
- **Scope:** reconcile 8 differing lines; re-point its `/drain-prs` reference;
  register and retire.
- **Phase:** 2
- **Depends on:** `VEND-0`, `VEND-5`
- **Ordering:** `not on the critical path`
- **Relevant decisions:** D-1, D-2, D-4, D-5, D-7
- **Acceptance signals:** a janitor run reports stale claims, zombie worktrees
  and orphan branches, and cleans up only what was approved.
- **Out of scope:** changing what counts as a stale signal.
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
