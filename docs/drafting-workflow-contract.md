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
  own CLI. Kanban's Haskell code spawns exactly five workflows per brand
  (`solve`, `pr-review`, `pr-rereview`, `pr-revise`, and — since issue #127 —
  `repair`), which is why the
  drafting and issue-review assets are deliberately excluded from the Haskell
  invocation-parity pinning in `tools/test_claude_plugin.py` and
  `tools/test_codex_plugin.py`. See
  [agent-workflow-contract.md](agent-workflow-contract.md) for the workflows
  Kanban does invoke by name.
- This document defines responsibilities, boundaries, and the scope gate
  (§4) that a consuming project may declare to narrow which discretionary
  candidates the hunters propose. It does not define any project's gate; that
  content belongs in that project's own agent instructions.

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
either plugin without a row here fails the completeness check in §8, and so
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
drafting workflow produced (§5); it never rewrites or substitutes one.

### 3.4 The readiness gate: `/issue-review` and `$issue-review`

`/issue-review` and `$issue-review` are the **direct** canonical
readiness-gate workflows for one numbered issue. They do not hunt for, draft,
or create issues. Each delegates the whole verdict to the canonical backend
(§6) so that a manual review and the managed daemon produce identical
provenance, structured comment, fingerprint, and labels; neither may post a
competing review or set a verdict label itself. On `CHANGES_REQUESTED` they
report and route the issue to the separate `issue-rereview` repair workflow,
which is deliberately **not** part of this packaged set, rather than rerunning
an unchanged spec.

### 3.5 Not a candidate-hunting workflow: arc decomposition

Arc decomposition plans a **user-specified feature arc** into an epic plus
dependency-ordered child issues. It is **not** a discretionary
candidate-hunting workflow: it never independently selects what work is worth
doing, so it does not belong to this drafting contract, and an `epic` asset
is deliberately **not packaged in either plugin**. The decomposition itself
belongs to the `design-epic` and `process-design-doc` pair declared in
[document-workflow-contract.md](document-workflow-contract.md): `design-epic`
captures the arc as a durable design document, and `process-design-doc` later
files its slices as tracker items. The personal `/epic` command that once
created epic trees directly was retired 2026-08-11 in that pipeline's favor.
`/issue`, `$issue`, and `/draft-issues` are the discretionary hunters; arc
decomposition only works an arc the user supplied.

## 4. Scope gate

Candidate selection is **ungated by default**. A consuming project that is in
a declared phase can narrow the discretionary work the hunters propose by
stating that phase in its own agent instructions. Nothing in this repository
defines any project's gate, and no gate is machine-parsed: prose agent
instructions are the whole interface.

The rules in §4.1–§4.5 are carried by every asset that performs or drives
discretionary candidate discovery — `/issue`, `$issue`, `/draft-issues`,
`/autoissue`, and `$autoissue`. The `autoissue` workflows carry them because
they drive discovery through their delegate (§3.3); each must surface the
deferrals its delegate reports and pass a user override back to it rather
than resolving one itself. `/issue-review` and `$issue-review` judge an
already-filed issue instead of hunting candidates, so the gate does not reach
them, and arc decomposition is excluded for the same reason it is unpackaged
(§3.5): it
decomposes a user-supplied arc rather than independently selecting what work
is worth doing.

### 4.1 What counts as a gate

Treat only an explicit, current, normative scope or priority instruction in
the repo's agent instructions (`CLAUDE.md`, `AGENTS.md`, or whichever
equivalent that workflow consulted) as a scope gate. Descriptive roadmap or
project-status prose is not a gate: a section narrating what a project has
built, or hopes to build someday, states no current instruction and must not
change selection.

### 4.2 No gate: unchanged behavior

If no such instruction is present, there is no gate: candidate selection,
hunting sources, and reporting stay exactly as each workflow otherwise
specifies. Every gate instruction in this section is conditional on a gate
being present, which is what makes the absent-gate case a genuine no-op. That
conditionality — not output comparison — is the reviewable property, because
agent runs are nondeterministic: this contract guarantees unchanged policy,
sources, and reporting behavior, never an identical candidate list across
runs.

### 4.3 Exemptions

A gate constrains discretionary new work only. Crashes, regressions, data
loss or corruption, broken CI gates, and security issues remain eligible
regardless of any gate. A declared phase states which improvements a project
wants pursued; it is never permission to leave that project broken, losing
data, or exploitable.

### 4.4 Deferred candidates are reported, not dropped

When a gate defers a discretionary candidate, report it rather than dropping
it: identify the candidate with enough evidence to recognize it, name the
gate that defers it, and say it was deferred by that gate. The user may
override the deferral at signoff, and an overridden candidate becomes
eligible again. The stop-and-ask interaction each hunting workflow already
performs (§3.1, §3.2) is that override surface; the gate must not bypass,
replace, or add a confirmation step to it.

That override surface has to exist even when the gate leaves nothing to
draft. The one-candidate workflows otherwise reach signoff only by producing
a draft, and may report "nothing worth opening" and stop — which would strand
a deferral the user never saw. So: if a gate defers every candidate a
workflow would otherwise draft, that is not a nothing-worth-opening result.
The workflow stops and presents the deferred candidates as its signoff, each
named with its gate, then waits for the user to lift a deferral or confirm
the stop. Only a run whose candidates were killed by verification or
deduplication — not by a gate — may report nothing worth opening.

### 4.5 Selection only

A discretionary candidate that falls inside a declared scope stays eligible.
The gate changes selection only — a candidate that passes it is verified,
deduplicated, and drafted to exactly the same hand-off bar as any other
candidate, through the same hunting sources, the same deduplication, the same
body template, and the same signoff flow.

## 5. Origin markers

Every issue a packaged drafting workflow creates ends its body with an
origin marker. `tools/approve_issues.py` (`ORIGIN_RE`) parses it to route the
issue to the opposite agent for canonical review, and
`src/Kanban/Review/Prompts.hs` tells reviewers to find it, so the literals
are a hard contract, not a formatting preference:

- Claude-created issue bodies end with `<!-- issue-origin:claude -->`.
- Codex-created issue bodies end with `<!-- issue-origin:codex -->`.

Each `autoissue` workflow preserves the marker produced by its delegated
drafting workflow. The marker is invisible routing metadata, never a
requirement of the issue itself. `tools/test_drafting_workflow_contract.py`
asserts these exact literals appear in the packaged assets of the matching
brand, so drift from the parser's accepted format fails CI.

## 6. Portable canonical backend

The packaged issue-review workflows — including `autoissue`'s immediate
review handoff — resolve the canonical backend the same way
`Kanban.Review.resolveCanonicalIssueReviewer` and the packaged `solve`
workflows do:

```bash
RECORD="$HOME/Library/Application Support/kanban/issue-review/config.json"
BACKEND="$(python3 - "$RECORD" <<'PY'
import json, os, sys
from pathlib import Path

record = Path(sys.argv[1])
override = os.environ.get("KANBAN_ISSUE_REVIEW_INSTALL_DIR")
if override and override.strip():
    resolved = Path(override).expanduser() / "approve_issues.py"
else:
    if not os.path.lexists(record):
        document = {}
    else:
        try:
            document = json.loads(record.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise SystemExit(f"The install record at {record} is unreadable ({error}).")
    if not isinstance(document, dict):
        raise SystemExit(f"The install record at {record} is not a JSON object.")
    if "backend_path" not in document:
        resolved = record.parent / "approve_issues.py"
    else:
        recorded = document["backend_path"]
        if not isinstance(recorded, str) or not Path(recorded).is_absolute():
            raise SystemExit(f"The install record at {record} does not name an absolute backend_path: {recorded!r}.")
        resolved = Path(recorded)
if not resolved.is_file():
    raise SystemExit(f"Canonical issue reviewer was not found at {resolved} (consulted {record}). Run `python3 tools/install_issue_review.py` from the Kanban checkout, adding --install-dir if it belongs elsewhere.")
print(resolved)
PY
)"
```

The precedence is a non-empty `KANBAN_ISSUE_REVIEW_INSTALL_DIR`, then the
backend path `tools/install_issue_review.py` recorded in that document, then
— only when the record names none, which is what an installation predating
the record looks like — the directory the record itself lives in. The
document's own location is fixed even when `--install-dir` moves everything
else, because a workflow that inherits no environment still has to find an
installation made anywhere; see
[agent-workflow-contract.md §5](agent-workflow-contract.md#5-portable-install-policy).
No packaged workflow reconstructs the install path from its parts, and none
may reference `~/work/approve-issues.py` — the optional pre-migration
compatibility launcher — or any other user-local workflow path.

Reviewer selection belongs to the backend, not to the packaged workflow. No
packaged asset may pin a reviewer model, reasoning effort, display name,
permission mode, approval policy, or working directory; the personal model
pins carried by the pre-vendoring sources were dropped on purpose, matching
[agent-workflow-contract.md §5](agent-workflow-contract.md#5-portable-install-policy)
and the forbidden-frontmatter/forbidden-manifest policies in
`tools/test_claude_plugin.py` and `tools/test_codex_plugin.py`.

## 7. Project-scoped locations

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

## 8. Completeness check

`tools/test_drafting_workflow_contract.py` (discovered by
`python3 -m unittest discover -s tools -p 'test_*.py'`, which CI already
runs) parses §2 and fails if:

- a declared asset path is absent from the tracked tree;
- a drafting or issue-review asset exists under either plugin that §2 does
  not declare;
- a required origin-marker literal (§5) is missing from this document or from
  a packaged asset of the matching brand;
- this document no longer states the Claude-only `/draft-issues` boundary
  (§3.2) or the non-hunting, unpackaged arc-decomposition boundary (§3.5);
- the packaged `autoissue` assets no longer describe delegating drafting,
  stopping without review before creation, creating after signoff, and
  immediately running the canonical review without a second confirmation;
- this document or any of the five discretionary-discovery assets drops a
  scope-gate rule from §4 — what counts as a gate, the absent-gate no-op, the
  correctness/stability/data-integrity/broken-CI/security exemptions, the
  overridable deferral report, or selection-only — so the document and those
  five assets cannot state different gate or exemption rules;
- a one-candidate hunter stops leaving "nothing worth opening" conditional on
  the gate, which would let an all-deferred run end before the user ever saw
  the deferral it should have been offered (§4.4);
- a discretionary-discovery asset states a gate instruction ahead of the
  absent-gate guard that conditions it, which is the mechanical form of §4.2's
  requirement that every gate instruction be conditional on a gate;
- an `issue-review` asset grows scope-gate language, which would mean the gate
  had leaked into a workflow that judges filed issues rather than hunting
  candidates (§4);
- a packaged issue-review or `autoissue` asset resolves the backend anywhere
  other than the documented Kanban-managed install path (§6).

The discovery, frontmatter, and no-personal-path coverage for these assets
lives with the rest of each plugin's structural coverage in
`tools/test_claude_plugin.py` and `tools/test_codex_plugin.py`, and their
external-command and user-scoped-path surface is reconciled against the §4
dependency manifest of
[agent-workflow-contract.md](agent-workflow-contract.md#4-dependency-manifest)
by `tools/test_agent_workflow_contract.py`.
