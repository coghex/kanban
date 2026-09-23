# Primary checkout permission guard design

Make accidental edits in a repository's primary checkout fail with a filesystem
permission error, prompting agents to use an isolated worktree. Preserve an easy,
explicit owner override and ordinary integration of approved work.

Design state: `exploring`

Owner: `coghex/kanban`. Publication target: `master`.
Captured on 2026-09-22. This is a future workflow design, not an implemented
feature or authorization to change permissions, services, or consuming repositories.

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. Guard primary checkouts against accidental edits while preserving worktree development and explicit owner overrides

Delivery slices are not allocated yet; the proposals and open questions below
need refinement before issue processing. No tracker artifacts were created.

## Epic contract

- **Goal:** agents attempting ordinary edits in a protected primary checkout
  receive permission errors; implementation worktrees remain writable.
- **Done when:** the selected protection can be enabled, inspected, temporarily
  suspended, and restored; integration updates restore protection over their
  resulting files; owner-directed direct edits remain possible; failures report
  the actual protection state without losing local work.
- **Users and operators:** repository owners, agent sessions, and Kanban's
  integration tooling operating on an opted-in repository.
- **Arc label:** None proposed.

## Current state and evidence

Evidence was read from Kanban primary revision
`1cb6c53e8c0eca27b469ca783828fb7d3fe9bbfe`, not inferred from the older
`docs-wip` checkout in which this document was authored.

- `CLAUDE.md` already requires isolated implementation and separate authoring of
  standalone documentation in `docs-wip`. Markdown instructions supply guidance,
  but do not themselves cause a filesystem write to fail.
- `tools/drain_prs.py`, `fast_forward_default_branch`, fetches and attempts a
  fast-forward merge. Its fallback may relocate untracked files, snapshot tracked
  changes, reset the checkout, and restore the snapshot. A permission guard must
  cover that complete mutation lifecycle, not just the merge subprocess.
- `tools/docs_land.sh` resolves the docs and primary worktrees by branch. Its
  final primary synchronization uses `git merge --ff-only` after checking for
  dirty state, divergence, and untracked occupants. Guard integration must retain
  those checks and distinguish successful remote publication from failed local
  synchronization or failed relocking.
- `docs/pr-drainer.md` and `docs/agent-workflow-contract.md` describe the existing
  service, recovery, and workflow authority. The guard would add no authority to
  merge, publish, resolve conflicts, or discard changes.
- `docs/agent-workflow-contract.md` section 7 on this primary revision classifies
  designs under `docs/designs/` as coordination documents. This initial document
  stays local until publication is requested.
- The open issue inventory checked on 2026-09-22 contained no clearly matching
  primary-checkout permission-guard arc. Repeat deduplication before readiness.

The motivating example was Hetoimasia: its primary checkout contained nested
docs and review worktrees, with additional worktrees elsewhere. A recursive
permission change over the whole repository would affect exactly the worktrees
that must remain writable. That repository is evidence for the requirement,
not the owner of this design or a target authorized for rollout now.

## Desired experience

An agent can inspect the primary checkout normally. An attempted source edit
fails with a permission error, and the repository instructions explain that
implementation belongs in an isolated worktree. The agent can create or reuse
a worktree and continue there without unlocking the primary checkout.

Approved integration updates the primary checkout through a temporary writable
scope and returns it to its protected state, including newly created files.
Git uses the same filesystem permissions as other programs: a plain pull or
merge has no automatic exemption. Fetching objects and updating a remote branch
are distinct from writing the local checkout.

The owner can explicitly ask Codex to make a quick direct edit on master. Codex
temporarily unlocks the checkout, performs the requested edit and validation,
then relocks it and reports whether protection was restored. This exception is
part of the intended workflow, not something the design should prohibit.

## Decisions

### D-1. Use a reversible accidental-edit guard

The owner explicitly wants a permission error as a cue for agents and accepts
that an agent running as the owning Unix user can change permissions back.
This is not a security boundary or protection against a determined writer.
Filesystem permissions cannot distinguish models running under the same user.

### D-2. Preserve an explicit owner-directed override

The owner must be able to ask Codex to unlock, write directly to master, and
relock. An ordinary edit failure alone is not an instruction to unlock.

### D-3. Exclude all implementation and documentation worktrees

Protection targets the primary checkout's project content. Other worktrees
remain usable, whether nested beneath that checkout or stored elsewhere.
The design must also preserve the ability to create additional worktrees.

### D-4. Keep this design in Kanban and defer implementation

The owner requested a design document in the workflow tracker's documentation,
explicitly outside Hetoimasia, and does not want implementation yet. The overall
direction was welcomed; the detailed mechanics below remain proposals.

## Proposed design

### P-1. Scope protection to a configured primary checkout

Resolve repository identity, primary checkout, and default branch explicitly.
Protect tracked project files, including code, documentation, and configuration,
and the directories needed to prevent creation, deletion, and replacement.
Remove write permission while preserving read, traversal, and executable bits.
Git does not track these read/write mode changes as source changes.

Discover worktrees through Git and prune their complete directory trees.
Keep designated worktree containers writable for future worktree creation.
Exclude shared Git metadata so linked worktrees can commit, fetch, and operate
normally. Do not follow symlinks or recursively alter unrelated build output,
scratch data, or external paths. A writable excluded child can remain usable
inside a nonwritable but traversable parent.

This protects a checkout path, not the abstract Git branch. Merely switching
that checkout to another branch should not be treated as an automatic unlock;
the precise mismatch policy remains Q-3.

### P-2. One helper owns permission changes

Illustrative command names, not an existing interface:

```sh
checkout-guard status
checkout-guard lock
checkout-guard run -- git pull --ff-only
checkout-guard unlock
```

`status` reports observed protection, exclusions, and any outstanding override
or incomplete operation. `lock` applies or repairs protection. `run` temporarily
restores write access, runs an update, and relocks its resulting files on success,
failure, or ordinary interruption. Explicit `unlock` supports owner-directed
editing across multiple agent tool calls, followed by `lock`.

The helper needs a recoverable record of permissions it changed and the active
operation. The state must live outside protected project content and remain
untracked. Preserve existing permission choices instead of blindly applying
`chmod -R u+w`; define restoration for new and replaced paths before shipping.
Exact storage, ownership, and recovery rules remain Q-2.

Newly created files must be included when relocking, including additions made by
an authorized edit that has not yet been committed. Handling of such files and
their containing directories remains Q-1; scanning only the old tracked list
would miss them. Never claim protection is complete after a partial chmod failure.

### P-3. Integrate at checkout mutation boundaries

Use the same helper in the drainer's full local synchronization lifecycle and
the documentation helper's primary checkout update. Manual pull and merge use
the guarded command, or an explicit unlock/relock session. Existing approval,
dirty-state, snapshot, and conflict-recovery rules continue to apply.

Serialize participating update and override operations so one caller cannot
relock files while another is updating them. A manual override spanning several
tool calls must be visible to integration tooling so it does not autostash or
replace the owner's in-progress edit. The lease/locking protocol remains Q-2.

During any unlock, other processes with the same Unix identity can also write.
The coordination protocol governs cooperating tools, not arbitrary processes.
A crash or SIGKILL may leave a partial or unlocked state; do not promise that
cleanup handlers always run. Report and repair that state on a later explicit
operation without resetting content or concealing the original failure.

### P-4. Explain the guard in agent instructions

Proposed instruction text:

> The primary checkout is intentionally read-only. On a write-permission error,
> use an isolated worktree. Do not unlock it merely to complete an ordinary task.
> When the user explicitly requests a direct edit on master, temporarily unlock
> it, make the requested change, and restore protection before finishing. Report
> whether protection was restored.

Keep the implementation to a helper, concise instructions, and the integration
points that need it. A background watcher, blanket Git interception, and a
hard sandbox are not part of the proposed initial approach.

## Open questions

### Q-1. Exact protected paths and permission semantics

Settle the policy for ignored directories, new untracked override files,
worktree containers, tracked paths overlapping an exclusion, symlinks, hard
links, ACLs, and existing unusual permissions. Chmod on a hard-linked file can
affect another path; mode bits alone may not describe ACL-granted access.
Determine supported cases and informative refusals without expanding this into
a security product. Define how worktree creation in a new container is handled.

### Q-2. Recovery and coordination ownership

Choose the state location and original-mode record, process/lease identity,
serialization with existing integration locks, nested invocation behavior, and
the lifetime of manual overrides across separate tool calls. Specify how stale
state is distinguished from a live editor and how interruption is recovered.
In particular, integration must not silently end a live owner override.

### Q-3. Installation and repository selection

Choose how repositories opt in, how their primary checkout and default branch
are resolved and revalidated, how a branch mismatch is reported, and how the
guard is disabled with permission restoration. Decide packaging and rollout for
Kanban and consuming repositories, including vendored documentation helpers,
and establish the supported macOS/Linux filesystem behavior.

These questions are recorded for a future design session. They do not block
capturing the owner's request and do not authorize choosing answers now.

## Verification strategy

Use temporary repositories under an ordinary non-root user on supported
platforms. Verify observable permission failures for direct edits, atomic file
replacement, deletion, and creation in protected directories. Check executable
bits, traversal, Git cleanliness, and restoration of pre-existing permissions.

Verify that nested and external worktrees can edit, create files, commit, fetch,
and create further worktrees. Prove exclusions stay untouched and paths outside
the intended scope are not modified. Exercise the chosen symlink, hard-link,
ACL, and untracked-file policies.

Exercise successful and failed integration, added/deleted/renamed files,
ordinary interruption, forced termination and recovery, simultaneous helper
calls, and an owner override spanning multiple tool calls. Check both the
command result and the final protection report. Retain the existing drainer
snapshot/recovery and documentation publication checks; no test should discard
local work to manufacture a clean result.

No permission experiments or implementation tests were run to author this
document. These are future acceptance areas, not evidence of delivery.

## Delivery plan

Deferred until Q-1 through Q-3 and the helper/integration boundaries are settled.
Likely implementation surfaces are permission handling, integration lifecycle,
and operator instructions, but no one-PR slice boundaries or delivery sequence
have been approved. Keep this document `exploring`; readiness and tracker
creation require a later explicit request.

When implementation is authorized, its code, required contracts, rollout
instructions, and validation belong together in the relevant implementation
PRs. This standalone design capture does not authorize changing permissions,
installing a service, publishing documentation, or modifying another repository.
