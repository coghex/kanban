# Project Review Findings: PRs #271–#251

This review continued below the completed #272 cursor and covered the next
twelve merged pull requests by merge time: #271, #267, #266, #265, #259,
#258, #257, #256, #255, #253, #252, and #251. It also reviewed the direct
first-parent documentation commits `e27b98f`, `891ff71`, and `4aaa0c9`
interleaved between #272 and #251. The batch was frozen and verified at
`master@39ca2e3` on 2026-08-22.

Each pull request was checked against its linked issue where one existed,
pull-request body, commits, landed diff, canonical review history, current
implementation, callers, and current tests. The direct commits were checked
against their patches and the current design and findings ledgers. Later
descendants were read only to establish whether a mistake still exists. This
report preserves the one newly confirmed current mistake that still needs
one-at-a-time disposition. PR #259's remaining successful-no-op ready race is
already recorded as PRR-1 in `docs/project_review_297-272.md` and is not
duplicated here.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [x] PRR-1. The mandatory art-decision policy exists only in the Claude workflows — [#493]

## 1. Cross-brand art-decision policy

### [#493] PRR-1. The mandatory art-decision policy exists only in the Claude workflows

> **Captured note:** Apply the same missing-art blocker and user-decision
> boundary to the Codex `$issue` and `$solve` workflows that PR #251 added to
> Claude's `/issue` and `/solve`, and pin the rule across all four assets so the
> two brands cannot silently make different product decisions.

**Verification:** PR #251 says missing textures, icons, sprites, and animations
are explicit tracked blockers; the user decides whether each asset is supplied
or generated; placeholders, reused assets, and scope narrowing are forbidden;
and a solver completes independent work before stopping. Its landed patch
changed only `claude-plugin/plugins/kanban/commands/issue.md` and
`claude-plugin/plugins/kanban/commands/solve.md`. It neither changed the
corresponding Codex assets nor added a regression assertion.

That split still exists at current master. A four-file semantic probe checked
for `texture`, `placeholder`, `generated`, and `art is`: all four anchors are
present in both Claude assets and absent from both Codex assets. The Claude
issue workflow carries a seventh handoff-quality rule devoted to art, while
the Codex list ends after its sixth rule. The Claude solve workflow inserts an
art blocker between implementation and testing, while the Codex workflow moves
directly from implementation to tests. Consequently an identical issue can be
drafted without an art blocker or solved through an agent-selected placeholder
when invoked through Codex, even though the Claude path must stop for the
user's decision.

The focused Python contract suite passed 450 tests with this asymmetry present.
Its drafting contract pins several rules against both `/issue` and `$issue`,
but it contains no art-policy rule; the solve contracts likewise have no test
that names missing art, placeholders, reused assets, or
supplied-versus-generated decisions. The Markdown assets are executable
workflow policy, so passing discovery and dependency checks do not make the
behavioral split safe.

**Evidence:**

- `claude-plugin/plugins/kanban/commands/issue.md:24-33` — the Claude drafting
  rules explicitly make missing art a blocker and reserve supply-versus-
  generation to the user.
- `codex-plugin/plugins/kanban/skills/issue/SKILL.md:25-34` — the corresponding
  Codex rules end without any art requirement and proceed directly to the body
  template.
- `claude-plugin/plugins/kanban/commands/solve.md:106-114` — the Claude solver
  must stop on missing art, forbids placeholders, reuse, and scope narrowing,
  and first completes independent implementation and validation.
- `codex-plugin/plugins/kanban/skills/solve/SKILL.md:107-114` — the Codex solver
  moves from effective-spec implementation directly to test selection, with no
  equivalent decision boundary.
- `docs/drafting-workflow-contract.md:57-75` — `/issue` and `$issue` are the
  two-brand one-candidate workflow and share the same handoff-quality and
  signoff responsibility; no Claude-only art exception is declared.
- `docs/agent-workflow-contract.md:77-82` — both tracked solve workflows are
  named as the paired packaged solve surface.
- PR #251's complete landed file list — only the two Claude Markdown assets
  changed; the advertised workflow policy gained no Codex counterpart and no
  regression test.

**Handoff context:**

- **Current behavior:** Claude issue drafting records missing art as explicit
  tracked work and Claude solving stops for the user's supply-or-generate
  decision. Codex issue drafting and solving receive none of those instructions
  and may silently omit the blocker or choose a placeholder, reused asset, or
  narrowed implementation.
- **Expected behavior:** The same missing-art observation produces the same
  blocker, ownership decision, and stop behavior in both brands. Brand-specific
  syntax, frontmatter, helper resolution, and origin markers remain different;
  the product decision does not.
- **Scope and constraints:** Reconcile only this policy across the existing
  `issue` and `solve` pairs. Do not migrate all existing workflow pairs to the
  authored-source renderer, which issue #375 deliberately excluded, and do not
  generate or choose any actual art. Preserve the issue workflow's explicit
  signoff stop, the solve workflow's independent-work-before-stop requirement,
  and the bundle-version gate for every changed plugin root.
- **Verification target:** Add a contract assertion over all four assets for
  the missing-asset list, explicit blocker, user-owned supplied-versus-generated
  choice, placeholder/reuse/scope-narrowing prohibition, and independent-work
  rule where applicable. Include a planted-removal check per brand and a
  negative control over delegating assets so a rule that accidentally matches
  every Markdown file cannot pass vacuously.
- **Deduplication:** Searches of all tracker states and findings reports for art
  blockers, missing textures/icons/sprites/animations, placeholders, generated
  assets, and Claude/Codex art parity found no owning issue or report. Closed
  issue #118 vendored the independently pinned workflow sources and does not
  own later semantic parity. Closed issue #375 built rendering for new commands
  and explicitly put migration of the existing pairs out of scope.
- **Remaining uncertainty:** None about the current cross-brand drift. If the
  art policy itself is no longer desired, retiring it must be an explicit
  two-brand policy change rather than leaving invocation brand to decide it.
