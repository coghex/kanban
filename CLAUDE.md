# CLAUDE.md

Instructions for Claude Code sessions started at this repository's root. Kanban is
two things: a Haskell terminal board for a GitHub repository with the Codex and
Claude usage panel beside it, and the owner's tracked workflow skills and scripts.
The application drives none of the second; they are installed by their own scripts.
`docs/design.md` is the authoritative contract for the application; this file is an
entry point, not a replacement for it.

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

- `docs/design.md` is the complete behavior contract for the application: the board,
  the usage panel, the configuration, and the command line. A behavior change must
  stay consistent with it or update it in the same PR.
- Section 19's `Implementation state` paragraph, its `Retired` paragraph and the
  milestones beneath them record what is already implemented and what was removed.
  Read them before concluding something is missing: the application's agent control
  was removed on purpose.
- `docs/agent-workflow-contract.md` is authoritative for the external executables,
  authority, and durable state the owner's skills and scripts — the drainer, the
  approval and review scripts, the plugin bundles — depend on. The application does
  not consume it.
- `docs/vision.md` is the owner's document; change it only as the owner has settled.
- `docs/development.md` has the build, test, and layout basics; `docs/pr-drainer.md` and
  `docs/workflow-setup.md` cover the optional local components.
- Documentation lands with `docs-push`; Markdown that is code goes through a pull
  request. See "Markdown changes" below.

### Markdown changes

- Documentation lands with the owner's `docs-push` tool as soon as it is ready,
  from whatever worktree you are in: `docs-push [-m "message"] <paths...>`. It
  needs no owner request, review, pull request or `docs-wip` worktree. That
  includes documentation that goes with a code change: land it with `docs-push`
  and link it from the pull request body (`Docs: docs/x.md @ <commit>`), so a
  docs fix never costs a re-review or a CI run.
- Markdown that is code goes through the pull request with its code: the plugin
  bundles, `tools/command_sources/`, `.github/`, `CLAUDE.md`/`AGENTS.md`, and the
  documents a test parses or an implementation is coupled to
  (`docs/design.md`, the three workflow contracts). `docs-push` refuses those
  and says why; the list is `coghex/kanban` in `~/.config/docs-push.json`. A
  plugin command file is held to its bundle version by
  `BundleVersionGateTests`, and `docs/design.md`'s section 7 key table is
  compared against `Kanban.UI.Keys` by `Spec.UI.Keys`; splitting either from
  what gates it leaves `master` red between the two landings.
- `docs/agent-workflow-contract.md` section 7 classifies Kanban's own documents
  for the processing workflows' publication helper: coordination documents
  publish straight to master through it, everything else is pr-atomic to it,
  and the workflow then lands the document with `docs-push`. Anything
  unclassified is pr-atomic.
- Documentation does not carry code's review burden. That is a statement about
  process, not licence to leave the contracts in "The contract" above
  inconsistent with the behavior they describe.

## Quality gates

- Warning-clean builds are mandatory. `cabal.project` applies `-Werror` to package
  `kanban`, on top of the `-Wall -Wcompat -Widentities -Wincomplete-uni-patterns
  -Wincomplete-record-updates -Wpartial-fields -Wredundant-constraints` set in
  `kanban.cabal`'s `common warnings`, so a new warning fails the build.
- Behavior changes come with tests. Reuse the suite's established patterns instead of
  inventing a harness (`docs/design.md` section 18): pure and fixture tests that need no
  terminal, network, or GitHub account; golden Brick frames for layout, regenerated only
  with `KANBAN_UPDATE_GOLDENS=1` and read before committing; temporary Git repositories;
  and fake `gh`, `codex`, and `claude` executables placed on a temporary `PATH`, which
  stand in for the GitHub fetch and the two usage providers.
- Never open or push to a pull request over a failing gate you selected.
- A workflow command or skill Markdown file is the program an agent executes, so an
  edit under `claude-plugin/`, `codex-plugin/`, `grok-plugin/`, `kimi-plugin/`, `google-plugin/`,
  or `claude-copilot-plugin/`
  is a behavior change and takes a
  regression assertion like any other. `WriteLocationTests` in
  `tools/test_drafting_workflow_contract.py` is the pattern: the rules asserted against
  every asset that owes them, plus a negative control over the assets that delegate
  instead, so a rule matching everything cannot pass while asserting nothing.
- Editing a list, tuple, or table means auditing the whole file for prose that counts or
  describes it, not just the diff. A module docstring saying "the eleven documents" sat
  seventy lines above the tuple it described, and stayed wrong through several changes
  that grew it.

## Source layout

Modules live in `src/Kanban/`; search the group that matches the change.

- `Domain`, `Workflow`, `Card`, `Tracker`, `Filter` — board state, column
  classification, tracker hierarchy, and the composable card filter criteria.
- `Repository` with `Repository.*`, `GitHub` with `GitHub.*`, `Cache`, `Config`, `Paths`,
  `CLI` — repository resolution and the board lease, GitHub data and its refresh
  coordinator, the last-good snapshot and the durable `gh` record, configuration (it
  accepts and ignores the keys the scripts own), the private directories under the XDG
  cache root, and the command line.
- `Usage` with `Usage.Render`, `UsageCommand`, `Codex`, `Claude`, `Provider` — provider
  quota windows, the wording the sidebar and `--usage` share, the configured external
  usage commands, and the two built-in readers: `Codex` and `Claude` read account
  status only and submit no model prompt.
- `UI` with `UI.*`, `Layout`, `Text`, `GlyphTest`, `Browser` — terminal presentation,
  responsive layout, external-text sanitization, and the one place a URL is handed
  to the platform's page opener. `UI` itself is only the composition root;
  the seams live beside it — `UI.Types` and `UI.State` (state), `UI.Theme`,
  `UI.Board`, `UI.Overlay`, and `UI.Details` (drawing), `UI.Events` (dispatch),
  `UI.Keys` (the one declaration site for a board key binding, held against
  `docs/design.md` §7 by a test), `UI.Search`, `UI.Filter`, `UI.Selection`
  (column search, filter panel, and selection), `UI.Notice` (the notice line and its
  expiry), `UI.Refresh` and `UI.Reconcile` (refresh), and `UI.Util`.
- `Process`, `CommandCapture` — the bounded child-process helpers the GitHub fetch and
  the usage readers run through.

Elsewhere: `app/` is the executable entry point, `test/` the Haskell tests,
`Fixture` the invented board the golden frames and the tracked screenshot are drawn
from. `claude-plugin/`, `codex-plugin/` and the external-origin bundles
(`grok-plugin/`, `kimi-plugin/`, `google-plugin/`, `claude-copilot-plugin/`) are the
owner's tracked skills; `tools/` holds the scripts that install them and the services
they use (`setup_workflows.py`, the PR drainer, the issue approval service). The
application invokes none of them. `claude-copilot-plugin/` is the same pair for a Copilot
CLI session running a Claude model: the brand is the model, not the host, so it stamps
the claude origin and Codex reviews it.

## Pipeline conventions

This repository is developed by agents, and the board reads their state off GitHub.
The labels and markers below are the conventions of the owner's skills and scripts,
which are tracked here; the application does not apply, require or interpret them
beyond drawing the labels GitHub reports.

- Workflow labels: `reviewed:approve` for approved work, `reviewed:changes` for changes
  requested, `reviewed:revised` for a revision handed back for rereview.
- Origin markers route work to an opposite-brand reviewer. An agent-filed issue body
  carries `<!-- issue-origin:codex -->`, `<!-- issue-origin:claude -->`,
  `<!-- issue-origin:kimi -->`, or `<!-- issue-origin:google -->` — a kimi-origin or
  google-origin issue's canonical reviewer is Codex, since neither is a spawned
  provider. Issue revision is refused for those origins; the authoring
  session authors its own amendment. An issue
  filed through GitHub's web UI carries neither by design — the templates under
  `.github/ISSUE_TEMPLATE/` add no marker — and `tools/approve_issues.py` reads that
  absence as legacy provenance, routing it to both reviewers under the default
  `--legacy-policy dual` rather than to one. A pull request body
  carries exactly one of `<!-- pr-origin:codex -->`, `<!-- pr-origin:claude -->`,
  `<!-- pr-origin:grok -->`, `<!-- pr-origin:kimi -->`, or `<!-- pr-origin:google -->` as its
  final non-whitespace content — the review coordinator's `origin_from_body`
  (`review_pr.py` in the plugin bundles) rejects a duplicated, mixed, or
  trailing-text marker. A grok-origin, kimi-origin, or
  google-origin pull request is a known origin Codex reviews; none of them is a
  spawned provider, so revision and repair of those origins are refused.
- Never merge a pull request on your own initiative. Solve, review, and
  autonomous agents stop at the open PR; `tools/drain_prs.py` owns merging
  eligible PRs out of the Done column. The single exception is the packaged
  `finalize` workflow, and it is the user's to invoke, not an agent's to
  choose: it merges one named pull request, only when the user asks for it in
  that turn because the drainer cannot be used, and it refuses any pull request
  whose current head lacks a fresh opposite-brand approval marker, a passing
  check set, and a clean merge state. See `docs/agent-workflow-contract.md`
  §2.10.

## Hygiene

- Never commit `dist-newstyle/`, profiling or eventlog output, `__pycache__/`, or scratch
  files. Keep temporary work outside the tree.
- Issue bodies follow the tracker's shape: Background, Requirements, Acceptance,
  Out of scope, Related.
- Don't bundle unrelated changes into one pull request.
