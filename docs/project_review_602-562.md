# Project Review Findings: PRs #602–#562

This review covered the twelve newest uncovered merged pull requests at the
frozen selection boundary, in merge-time order: #602, #601, #569, #571, #570,
#568, #567, #566, #565, #564, #563, and #562. It also covered the twenty-three
direct first-parent documentation commits interleaved through that range:
`3eb10f5`, `def5f5a`, `8983a33`, `4912493`, `9b3e000`, `b9dc540`, `0ac97e7`,
`239cd29`, `8d7d931`, `f328bdb`, `12568a7`, `fe4040d`, `0f566ad`, `aeca00c`,
`20b6ffa`, `b40b4f7`, `cce33c1`, `aa0bd53`, `ec54fd1`, `b6019de`, `82d4afa`,
`bfa7197`, and `01f2dc0`. The first twenty-one were rechecked because they also
lay in the preceding PR batch's first-parent span; the last two were reviewed
individually for this batch. The batch was frozen at the repository history
head `origin/master@36bc9f3` on 2026-09-01; no unit or concern was excluded.

Each pull request was checked against its linked issue or standalone contract,
pull-request body, commits and review iterations, landed diff, current
implementation, callers, and focused tests. Each direct commit was checked
against its patch and the current state of the document it changed. The still
current Claude settings-source concern introduced by #600 and unchanged by
#602 remains captured as PRR-1 in `docs/project_review_600-573.md`; it is not
duplicated here. This report preserves three newly confirmed current concerns
that still need one-at-a-time disposition.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [x] PRR-1. Mission store paths do not uniquely identify repositories — [#615]
- [ ] PRR-2. `$fix` accepts approval that belongs to an older head
- [ ] PRR-3. Session-cycle diagnostics include acyclic ancestors

## 1. Durable mission repository isolation

### [#615] PRR-1. Mission store paths do not uniquely identify repositories

> **Captured note:** Give every GitHub repository a collision-free durable
> mission-store root so one repository can never read, block, or overwrite
> another repository's mission records.

**Verification:** PR #601 places each repository's durable mission state under
`<owner>-<repo>`, then replaces slashes, backslashes, colons, and spaces with
hyphens. That mapping is not injective. The distinct valid GitHub repository
identities `a-b/c` and `a/b-c`, for example, both map to `a-b-c`. Opening either
repository therefore produces the same `MissionStore` directory while retaining
a different repository identity only in memory.

The record-level identity checks do not repair the directory collision. A
snapshot write checks that its new payload belongs to the caller's in-memory
repository, then atomically renames it over the shared mission path; it does not
first establish that an existing record in that path belongs to the same
repository. Two colliding stores using the same mission ID can therefore
overwrite one another's snapshot. Immutable specification creation can mistake
the other repository's file for an already-existing specification, and mission
enumeration can expose the other repository's entries as corrupt foreign
records. The current separation test uses names that remain distinct under the
mapping and does not exercise delimiter ambiguity.

Issue #592 literally requested the same `<owner>-<repo>` spelling as the worker
directory, which the implementation supplies. Its higher-level requirement and
the design documents, however, require repository-qualified durable isolation;
the collision defeats that safety property and can lose durable state.

**Evidence:**

- `src/Kanban/Mission/Paths.hs:127-150` — `missionStoreKey` concatenates owner
  and repository with `-`, then maps several possible input characters to the
  same `-` output.
- `src/Kanban/Mission/Store.hs:231-247` — snapshot replacement validates only
  the incoming snapshot against the in-memory store identity before renaming it
  over the repository-colliding path.
- `test/Spec/Mission.hs:329-343` — repository separation is tested only with
  `coghex/kanban` and `coghex/elsewhere`, which cannot reveal the collision.
- `docs/design.md:3125-3158` — mission history is durable state, and foreign
  repository or mission identities must be refused rather than adopted or
  written.
- `docs/superagent_design.md:524-532` — each mission belongs under a private,
  repository-qualified durable root.

**Handoff context:**

- **Current behavior:** Different valid GitHub repository identities can share
  one mission directory. Matching mission IDs then share all record paths, and
  a snapshot write from one repository can replace the other's durable state.
- **Expected behavior:** Repository identity maps injectively to the durable
  mission root, and records for one repository remain invisible and
  unmodifiable while another repository's store is open.
- **Scope and constraints:** Preserve the XDG state location, safe single path
  components, atomic record disciplines, record identity checks, and existing
  Mission IDs and schemas. Decide explicitly whether existing mission
  directories require migration or compatibility lookup. Audit the analogous
  worker-cache key, but do not silently couple a durable-store migration to a
  collectable cache rename.
- **Verification target:** Under one temporary XDG state root, open stores for
  `a-b/c` and `a/b-c` with the same Mission ID. Prove their roots differ and
  their specifications, snapshots, journals, archives, leases, enumeration,
  and deletion remain independent. Add any chosen migration and identity
  fail-closed cases.
- **Deduplication:** Searches of all tracker states for mission-store path,
  repository-key collision, and repository-qualified mission state found no
  issue for this defect. Open epic #354 concerns multi-repository operation but
  does not identify this durable-store collision.
- **Remaining uncertainty:** The required isolation is clear. The durable
  migration policy and whether to correct the worker cache's analogous key in
  the same change remain design choices.

## 2. Approved-fix authority

### PRR-2. `$fix` accepts approval that belongs to an older head

> **Captured note:** Do not let `$fix` modify or push a pull request unless its
> current head is the exact head the accepted review approved.

**Verification:** PR #569's workflow requires an approved pull request before
it mutates anything, but in the default `label` approval mode it proves that
condition only from the presence of `reviewed:approve`. It reads no review
comment or other state that binds that label to `headRefOid`. The pre-push
revalidation repeats the same label or native-review decision and confirms only
that the current head still equals the head recorded at workflow start. If a
new commit is pushed while the approval label remains attached, `$fix` accepts
that unreviewed head as its mutation authority.

The repository's canonical review marker already includes the exact reviewed
SHA, and both its publication path and the drainer treat head identity as part
of approval. The `$fix` workflow itself acknowledges that its own push replaces
the SHA approval named. A mandatory rereview after the fix establishes approval
for the output, but it does not retroactively authorize editing and pushing the
unreviewed input. GitHub's native `reviewDecision` behavior can vary with branch
protection settings; the default label path alone establishes the defect.

**Evidence:**

- `tools/command_sources/fix.md:70-91` — the initial authority gate accepts the
  configured label or native review decision but reads no head-bound canonical
  verdict.
- `tools/command_sources/fix.md:328-353` — the fresh pre-push gate proves the
  head did not move during `$fix`, not that approval belongs to that head.
- `tools/command_sources/fix.md:383-388` — the workflow explicitly recognizes
  that an approval names a SHA when its own push replaces that head.
- `codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py:28-30` —
  the canonical v2 marker records a forty-character reviewed `head`.
- `codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py:1152-1169`
  — canonical verdict publication refuses a changed head.
- `codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py:1272-1282`
  — rereview requires historical review provenance, but not a prior marker on
  the current head; that is suitable for rereview eligibility, not mutation
  authority.
- `tools/drain_prs.py:865-870` and `tools/drain_prs.py:5516-5531` — the drainer
  deliberately stores the approved SHA and blocks when the label remains on a
  different head.

**Handoff context:**

- **Current behavior:** An approval label can survive a branch update, after
  which `$fix` treats the new unreviewed SHA as accepted work and may create a
  worktree, edit it, and push another commit.
- **Expected behavior:** `$fix` begins mutating only when the current head has
  fresh, head-bound approval, or when an explicitly defined positive
  content-safety policy has carried the approval to it.
- **Scope and constraints:** Preserve configured approval modes and labels,
  origin-brand routing, exact repository/head-branch resolution, problem-label
  refusals, no-force pushing, and exactly one canonical rereview after a real
  push. A stale head can be routed to `$pr-review` or refused; do not synthesize
  verdict labels directly.
- **Verification target:** Model a pull request whose current head is `B` while
  its approval label and newest canonical approval marker belong to `A`. Prove
  `$fix` performs no worktree creation, repair, push, or rereview until the
  current head receives valid approval. Retain the during-run head-movement
  and approval-withdrawal refusals.
- **Deduplication:** Searches of all tracker states for `$fix`, stale approval,
  and reviewed-head terms found no current issue for this defect. Closed #230
  defined a content-safe approval-carry policy for the drainer; it is related
  precedent, not a repair of `$fix`.
- **Remaining uncertainty:** The default label mode is definitively unsafe.
  Whether a correction always requires a new review or can reuse #230's
  positive content-safe verdict policy is a product decision.

## 3. Mission session-tree diagnostics

### PRR-3. Session-cycle diagnostics include acyclic ancestors

> **Captured note:** Report only the sessions that actually form a mission
> lineage cycle, independent of which input session validation visits first.

**Verification:** PR #601 validates the session-parent graph by walking upward
from every session. When a node repeats, `lineageCycle` returns the entire set
visited since the starting session rather than the suffix beginning at the
first occurrence. For `tail -> a -> b -> a`, a walk that starts at `tail`
therefore reports `{tail, a, b}` even though `tail` is not a cycle member. A
walk beginning at `a` reports only `{a, b}`, so the diagnostic also depends on
the input ordering selected by `firstError`.

The constructor comment and user-facing message both describe the returned
identities as the cycle's members. The current test uses a pure two-node cycle,
where every visited node happens to be cyclic, and misses an acyclic prefix.
Validation still correctly rejects the malformed graph; the mistake is the
identity and stability of the durable reader/writer diagnostic.

**Evidence:**

- `src/Kanban/Mission/Session.hs:97-100` — validation turns the first returned
  visited set into `MissionSessionCycle`.
- `src/Kanban/Mission/Session.hs:114-131` — `lineageCycle` returns all `seen`
  identities when it revisits one, including any acyclic prefix.
- `src/Kanban/Mission/Session.hs:133-144` — the diagnostic says every returned
  session forms the non-root-reaching lineage.
- `test/Spec/Mission.hs:1487-1493` — coverage contains only two nodes that are
  both members of the cycle.

**Handoff context:**

- **Current behavior:** A cyclic session graph is rejected, but the reported
  member list can falsely include acyclic descendants and changes with input
  order.
- **Expected behavior:** The same graph is rejected with exactly the repeating
  cycle suffix, in stable order, regardless of which session begins the first
  walk.
- **Scope and constraints:** Preserve duplicate, missing-parent,
  cross-mission-parent, and foreign-node validation precedence; preserve the
  durable snapshot schema and reader/writer rejection. Change only cycle-member
  detection and its deterministic diagnostic as needed.
- **Verification target:** Test `tail -> a -> b -> a` in both tail-first and
  cycle-first input orders and require `MissionSessionCycle [a, b]` from pure
  validation. Exercise the same malformed snapshot through both write and read
  paths so their messages name no acyclic session.
- **Deduplication:** Searches of all tracker states for mission session cycle,
  ancestor, lineage, and cycle-member terms found no issue for this defect.
- **Remaining uncertainty:** None. The graph is invalid in either case; only
  the reported cycle membership is wrong.
