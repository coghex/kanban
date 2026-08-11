# CLAUDE.md

Instructions for Claude Code sessions started at this repository's root.
`docs/design.md` is the authoritative contract; this file is an entry point, not a
replacement for it.

## Build and test

```console
cabal build all
cabal test all --test-show-details=direct
python3 -m unittest discover -s tools -p 'test_*.py'
```

CI (`.github/workflows/ci.yml`) pins GHC 9.12.2 and Cabal 3.16.1.0, runs `cabal check`
and `cabal update` first, then all three commands above. Locally, run what covers the
paths you changed — the Haskell suite for `src/`, `app/`, and `test/`, the Python suite
for `tools/` — and leave the full sweep to CI unless asked for more.

## The contract

- `docs/design.md` is the complete behavior contract. A behavior change must stay
  consistent with it or update it in the same PR.
- Its opening status paragraph and the milestones in section 19 record what is already
  implemented. Read them before concluding something is missing.
- `docs/agent-workflow-contract.md` is authoritative for the external executables,
  authority, and durable state the solve, review, and drainer actions depend on.
- `docs/development.md` has the build, test, and layout basics; `docs/pr-drainer.md` and
  `docs/workflow-setup.md` cover the optional local components.
- Every tracked Markdown file takes one of two publication lanes, classified in
  `docs/agent-workflow-contract.md` section 7. The eleven coordination documents publish
  straight to master, bypassing the PR lane:
  `docs/claude_document_workflows_design.md`, `docs/code-health-report.md`,
  `docs/document_workflow_findings.md`, `docs/drainer-bugs.md`,
  `docs/linux_portability_design.md`, `docs/multi_repo_boards_design.md`,
  `docs/pipeline-hardening.md`, `docs/public_release_design.md`,
  `docs/ui-bugs.md`, `docs/usage_awareness_design.md`, and
  `docs/workflow_audit_findings.md`. Everything else is pr-atomic and
  lands with its implementation through a pull request. Anything unclassified is
  pr-atomic too — that default fails closed, so a new document never publishes directly
  until section 7 says it may.

## Quality gates

- Warning-clean builds are mandatory. `cabal.project` applies `-Werror` to package
  `kanban`, on top of the `-Wall -Wcompat -Widentities -Wincomplete-uni-patterns
  -Wincomplete-record-updates -Wpartial-fields -Wredundant-constraints` set in
  `kanban.cabal`'s `common warnings`, so a new warning fails the build.
- Behavior changes come with tests. Reuse the suite's established patterns instead of
  inventing a harness (`docs/design.md` section 18): pure and fixture tests that need no
  terminal, network, or GitHub account; golden Brick frames for layout; temporary Git
  repositories; and fake `gh`, `codex`, and `claude` executables placed on a temporary
  `PATH`.
- Never open or push to a pull request over a failing gate you selected.

## Source layout

Modules live in `src/Kanban/`; search the group that matches the change.

- `Domain`, `Workflow`, `Card`, `Tracker` — board state, column classification, and
  tracker hierarchy.
- `Repository`, `GitHub`, `Cache`, `Config`, `Settings`, `Paths`, `CLI` — repository
  resolution, GitHub data, the last-good snapshot, configuration, and the private
  directories under the XDG roots.
- `UI` with `UI.*`, `Layout`, `Text`, `GlyphTest` — terminal presentation, responsive
  layout, and external-text sanitization. `UI` itself is only the composition root;
  the seams live beside it — `UI.Types` (state), `UI.Theme`, `UI.Board`, `UI.Overlay`,
  and `UI.Details` (drawing), `UI.Events` (dispatch), `UI.Session`, `UI.Solve`,
  `UI.Review`, `UI.PullRequest`, `UI.Worker` (lifecycles), `UI.Refresh` and
  `UI.Reconcile` (refresh), and `UI.AutoSolve`, the autosolve loop as pure functions.
- `Worker`, `Solve`, `Review` with `Review.*`, `PullRequestFlow`, `Codex`, `Claude`,
  `Process`, `Transcript`, `Preflight`, `Provider`, `StreamReader`, `CommandCapture` —
  the agent execution layer. `Review` itself is the Codex app-server client and the
  compatibility facade every consumer imports; its seams live beside it —
  `Review.Types` (wire and result payloads), `Review.Client` (the `ReviewClient`
  record and its tool registry), `Review.Tools` (the `gh` and `claude` tool runners),
  `Review.Canonical` (the `approve_issues.py` gate), `Review.Prompts` (instructions
  and JSON schemas), and `Review.Diagnostics` (shared failure vocabulary).
- `Drainer` with `tools/` — the launchd-managed PR drainer and its Python tests.

Elsewhere: `app/` is the executable entry point, `test/` the Haskell tests, and
`codex-plugin/` and `claude-plugin/` the tracked workflow bundles Kanban's AI actions
invoke by name.

## Pipeline conventions

This repository is developed by agents, and the board reads their state off GitHub.

- Workflow labels: `reviewed:approve` for approved work, `reviewed:changes` for changes
  requested, `reviewed:revised` for a revision handed back for rereview.
- Origin markers route work to an opposite-brand reviewer. Issue bodies carry
  `<!-- issue-origin:codex -->` or `<!-- issue-origin:claude -->`. A pull request body
  carries exactly one of `<!-- pr-origin:codex -->` or `<!-- pr-origin:claude -->` as its
  final non-whitespace content — `Kanban.PullRequestFlow.originFromBody` rejects a
  duplicated, mixed, or trailing-text marker.
- Never merge a pull request. Solve and review agents stop at the open PR;
  `tools/drain_prs.py` owns merging eligible PRs out of the Done column.

## Hygiene

- Never commit `dist-newstyle/`, profiling or eventlog output, `__pycache__/`, or scratch
  files. Keep temporary work outside the tree.
- Issue bodies follow the tracker's shape: Background, Requirements, Acceptance,
  Out of scope, Related.
- Don't bundle unrelated changes into one pull request.
