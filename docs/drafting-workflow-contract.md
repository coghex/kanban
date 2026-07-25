# Kanban drafting and issue-review workflow contract

## 1. Purpose and scope

This document is the canonical responsibility matrix for the packaged
issue-drafting and issue-review workflows the Kanban plugins ship. Before
these assets were tracked, the drafting and canonical-review contracts existed
only in an owner-maintained personal command/skill collection, so a repository
pull request could neither change nor verify them. Vendoring them here makes
each contract reviewable, testable, and portable to any project that installs
a Kanban plugin.

Scope boundaries:

- These workflows are **user- or daemon-invoked**, never spawned by Kanban's
  own CLI. Kanban's Haskell code spawns exactly four workflows per brand
  (`solve`, `pr-review`, `pr-rereview`, `pr-revise`), which is why the
  drafting and issue-review assets are deliberately excluded from the Haskell
  invocation-parity pinning in `tools/test_claude_plugin.py` and
  `tools/test_codex_plugin.py`. See
  [agent-workflow-contract.md](agent-workflow-contract.md) for the workflows
  Kanban does invoke by name.
- This document defines responsibilities and boundaries only. It does not
  define scope or priority gating for candidate selection; that remains
  future work tracked separately.

## 2. Declared assets

Machine-readable; parsed verbatim by
`tools/test_drafting_workflow_contract.py`. Columns:
`brand | invocation | path`.

```text
claude | /issue | claude-plugin/plugins/kanban/commands/issue.md
claude | /draft-issues | claude-plugin/plugins/kanban/commands/draft-issues.md
claude | /autoissue | claude-plugin/plugins/kanban/commands/autoissue.md
claude | /issue-review | claude-plugin/plugins/kanban/commands/issue-review.md
codex | $issue | codex-plugin/plugins/kanban/skills/issue/SKILL.md
codex | $autoissue | codex-plugin/plugins/kanban/skills/autoissue/SKILL.md
codex | $issue-review | codex-plugin/plugins/kanban/skills/issue-review/SKILL.md
```

The list above is exhaustive. A drafting or issue-review asset that exists in
either plugin without a row here fails the completeness check in §7, and so
does a row whose path is missing from the tracked tree.

## 3. Responsibility matrix

| Workflow | Brands | Breadth | Creates issues? | Reviews afterward? |
| --- | --- | --- | --- | --- |
| `/issue`, `$issue` | Claude and Codex | Exactly **one** candidate per run | Only after explicit user signoff | No |
| `/draft-issues` | **Claude only** | **Many** candidates surveyed per run | Only the candidates the user selects, after a stop-and-ask | No |
| `/autoissue`, `$autoissue` | Claude and Codex | Delegates to the one-candidate workflow | Via its delegate, after signoff | Yes — immediately, with no second confirmation |
| `/issue-review`, `$issue-review` | Claude and Codex | One numbered issue | No | Is the review itself |

### 3.1 One candidate: `/issue` and `$issue`

`/issue` and `$issue` each find and fully draft **exactly one** issue per run.
Runners-up are reported as one-line mentions and are never drafted. Each run
verifies the candidate is real (reproduce a bug or trace it through code with
a `file:line` citation; confirm a feature or code-health gap does not already
exist), deduplicates it against open and closed tracker issues plus the
bodies of any open epics touching the area, and drafts it to hand-off quality
as a contract an autonomous solver can satisfy without the user present.

Both workflows **stop for explicit user signoff** and must not run
`gh issue create` before it. "Nothing worth opening" and "this duplicates
#N" are valid terminal results.

### 3.2 Claude-only breadth: `/draft-issues`

`/draft-issues` is the **breadth counterpart** to `/issue`: it surveys many
candidates across the whole repository, presents them as a categorized list,
stops to ask which to create, and only then expands the chosen ones to the
same hand-off bar. It is **packaged for the Claude brand only** — there is
deliberately no `$draft-issues` Codex skill, and the Codex plugin must not
grow one under this contract. The Codex side covers drafting through the
one-candidate `$issue` workflow instead.

### 3.3 Delegation plus review: `/autoissue` and `$autoissue`

`/autoissue` and `$autoissue` join two existing contracts and replace
neither. Each:

1. **Delegates drafting** to its own brand's one-candidate workflow (`/issue`
   or `$issue`), preserving every requirement of that contract — verification,
   deduplication, hand-off-quality drafting, the origin marker, and the
   mandatory signoff stop.
2. **Stops without review** whenever the delegated drafting workflow stops
   before creation — a duplicate, nothing worth opening, a clarification
   request, or any other early stop. No review runs in that case.
3. On approval, **creates** the issue exactly as the delegated workflow
   specifies and captures its number and URL.
4. **Immediately runs the canonical review** (`/issue-review <issue>` or
   `$issue-review <issue>`). The original `autoissue` invocation already
   authorizes that review, so the workflow must **not** ask for a second
   confirmation between creation and review.

The full sequence is therefore draft → signoff → create → canonical review.
Each `autoissue` workflow preserves whichever origin marker its delegated
drafting workflow produced (§4); it never rewrites or substitutes one.

### 3.4 The readiness gate: `/issue-review` and `$issue-review`

`/issue-review` and `$issue-review` are the **direct** canonical
readiness-gate workflows for one numbered issue. They do not hunt for, draft,
or create issues. Each delegates the whole verdict to the canonical backend
(§5) so that a manual review and the managed daemon produce identical
provenance, structured comment, fingerprint, and labels; neither may post a
competing review or set a verdict label itself. On `CHANGES_REQUESTED` they
report and route the issue to the separate `issue-rereview` repair workflow,
which is deliberately **not** part of this packaged set, rather than rerunning
an unchanged spec.

### 3.5 Not a candidate-hunting workflow: `/epic`

`/epic` plans a **user-specified feature arc** into an epic plus
dependency-ordered child issues. It is **not** a discretionary
candidate-hunting workflow: it never independently selects what work is worth
doing, so it does not belong to this drafting contract and is deliberately
**not packaged** in either plugin. `/issue`, `$issue`, and `/draft-issues`
are the discretionary hunters; `/epic` only decomposes an arc the user
supplied.

## 4. Origin markers

Every issue a packaged drafting workflow creates ends its body with an
origin marker. `tools/approve_issues.py` (`ORIGIN_RE`) parses it to route the
issue to the opposite agent for canonical review, and
`src/Kanban/Review.hs` tells reviewers to find it, so the literals are a
hard contract, not a formatting preference:

- Claude-created issue bodies end with `<!-- issue-origin:claude -->`.
- Codex-created issue bodies end with `<!-- issue-origin:codex -->`.

Each `autoissue` workflow preserves the marker produced by its delegated
drafting workflow. The marker is invisible routing metadata, never a
requirement of the issue itself. `tools/test_drafting_workflow_contract.py`
asserts these exact literals appear in the packaged assets of the matching
brand, so drift from the parser's accepted format fails CI.

## 5. Portable canonical backend

The packaged issue-review workflows — including `autoissue`'s immediate
review handoff — resolve the canonical backend the same way
`Kanban.Review.canonicalIssueReviewerPath` and the packaged `solve`
workflows do:

```bash
BACKEND="${KANBAN_ISSUE_REVIEW_INSTALL_DIR:-$HOME/Library/Application Support/kanban/issue-review}/approve_issues.py"
```

That is the Kanban-managed install path defined in
[agent-workflow-contract.md §3](agent-workflow-contract.md#3-migration-boundary)
and installed by `python3 tools/install_issue_review.py`. The packaged
workflows must never reference `~/work/approve-issues.py` — the optional
pre-migration compatibility launcher — or any other user-local workflow path.

Reviewer selection belongs to the backend, not to the packaged workflow. No
packaged asset may pin a reviewer model, reasoning effort, display name,
permission mode, approval policy, or working directory; the personal model
pins carried by the pre-vendoring sources were dropped on purpose, matching
[agent-workflow-contract.md §5](agent-workflow-contract.md#5-portable-install-policy)
and the forbidden-frontmatter/forbidden-manifest policies in
`tools/test_claude_plugin.py` and `tools/test_codex_plugin.py`.

## 6. Project-scoped locations

The declared assets in §2 live inside each plugin's own tracked tree:

- Claude commands: `claude-plugin/plugins/kanban/commands/`, discovered
  through the `"commands": "./commands/"` declaration in
  `claude-plugin/plugins/kanban/.claude-plugin/plugin.json`.
- Codex skills: `codex-plugin/plugins/kanban/skills/<name>/SKILL.md`,
  discovered per-directory through the `"skills": "./skills/"` declaration in
  `codex-plugin/plugins/kanban/.codex-plugin/plugin.json`.

Both are picked up by file placement alone — adding a workflow needs no
manifest schema change. Because these locations are project-scoped rather
than user-scoped, a consuming project reaches them through the plugin install
or link flow described in each plugin's README, which is the surface the
planned opt-in cross-project setup work (issue #78) installs or links for
other repositories. This document is the inventory that flow consumes; it is
not itself an installer.

## 7. Completeness check

`tools/test_drafting_workflow_contract.py` (discovered by
`python3 -m unittest discover -s tools -p 'test_*.py'`, which CI already
runs) parses §2 and fails if:

- a declared asset path is absent from the tracked tree;
- a drafting or issue-review asset exists under either plugin that §2 does
  not declare;
- a required origin-marker literal (§4) is missing from this document or from
  a packaged asset of the matching brand;
- this document no longer states the Claude-only `/draft-issues` boundary
  (§3.2) or the non-hunting, unpackaged `/epic` boundary (§3.5);
- the packaged `autoissue` assets no longer describe delegating drafting,
  stopping without review before creation, creating after signoff, and
  immediately running the canonical review without a second confirmation;
- a packaged issue-review or `autoissue` asset resolves the backend anywhere
  other than the documented Kanban-managed install path (§5).

The discovery, frontmatter, and no-personal-path coverage for these assets
lives with the rest of each plugin's structural coverage in
`tools/test_claude_plugin.py` and `tools/test_codex_plugin.py`, and their
external-command and user-scoped-path surface is reconciled against the §4
dependency manifest of
[agent-workflow-contract.md](agent-workflow-contract.md#4-dependency-manifest)
by `tools/test_agent_workflow_contract.py`.
