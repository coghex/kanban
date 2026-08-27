# Project Review Findings: PRs #516–#498

This review continued below the completed #517 cursor and covered the next
twelve merged pull requests in merge-time order: #516, #514, #510, #509, #507,
#506, #505, #504, #503, #502, #500, and #498. It also reviewed the eight direct
first-parent documentation commits interleaved through that landing interval:
`947615b`, `98f2d52`, `9683f00`, `add8fad`, `0aa8830`, `4fffdc9`, `e8f1b76`,
and `fbe2495`. The batch was frozen at `origin/master@9c3b2f9` on 2026-08-27.
The later direct documentation landing `5e27417` was excluded rather than
moving the boundary; the finding below was rechecked against the current
descendant at `origin/master@5e27417`.

Each pull request was checked against its linked issue, pull-request body,
commits, landed diff, canonical review discussion, current implementation,
callers, and focused tests. Each direct commit was checked individually against
its patch and the current state of the document it changed. Later descendants
and open issue #543 were read only to establish whether the mistake still
exists and whether the tracker already owns its correction. This report
preserves the one confirmed current concern that still needs one-at-a-time
disposition.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [x] PRR-1. The scratch-HOME fullscreen check discards the authentication its real refresh requires — [#543]

## 1. Fullscreen live-acceptance environment

### [#543] PRR-1. The scratch-HOME fullscreen check discards the authentication its real refresh requires

> **Captured note:** Correct direct commit `98f2d52`'s live-acceptance
> environment so the isolated tmux session preserves or explicitly provisions
> the GitHub CLI authentication needed to populate its live-only board.

**Verification:** Commit `98f2d52` correctly removed a nonexistent
snapshot-cache fixture from the overlay arc's verification strategy, but
replaced it with a real board refresh under a scratch `HOME`. That environment
does isolate Kanban's default config, cache, and managed-component records. It
also moves the GitHub CLI's default configuration away from the user's existing
login.

The board cannot fall back to a cached open snapshot: its foreground refresh
calls `fetchGitHubSnapshot`, which launches `gh api graphql`, and the runtime
contract makes a `gh auth login` session mandatory. This checkout currently has
no `GH_TOKEN`, `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN`, or `GH_CONFIG_DIR`
environment override; `gh auth status` succeeds through the user's existing
login. Reproducing the design's wrapper environment with only a scratch `HOME`
and those optional token variables absent makes a read of this public
repository exit 4 before making the request:

```console
$ env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GH_CONFIG_DIR \
    HOME=/tmp/kanban-project-review-empty-home \
    gh api repos/coghex/kanban --jq .full_name
To get started with GitHub CLI, please run:  gh auth login
Alternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.
```

The same undocumented dependency has propagated into open issue #543's live
acceptance. A maintainer who is authenticated in the supported way the project
documents can therefore follow the check exactly, get an empty/error board,
and never exercise the details or session overlays the check is supposed to
validate. A shell that happens to export `GH_TOKEN` can pass, but neither the
design nor the issue requires or establishes one, so that does not make the
acceptance reproducible.

**Evidence:**

- `docs/overlay_focus_fullscreen_design.md:469-478` — the live check requires a
  real refresh while redirecting `HOME` to a scratch directory, without
  preserving or provisioning GitHub credentials.
- `src/Kanban/UI/Refresh.hs:308-320` — the board's live-only foreground refresh
  calls `fetchGitHubSnapshot`; there is no open-card cache fallback in this
  path.
- `src/Kanban/GitHub/Run.hs:59-84` — every page resolves and launches the
  installed `gh` executable.
- `src/Kanban/GitHub/Fetch.hs:306-313,492-515` — the snapshot fetch runs the
  generated `gh api graphql` argument vector.
- `docs/agent-workflow-contract.md:1007-1015` — `gh`, signed in via
  `gh auth login`, is mandatory because the board's GitHub data depends on it.
- `docs/user-guide.md:9-21` — the supported startup instructions likewise tell
  the user to run `gh auth login`, not to export a token for every board.
- Open issue #543, Acceptance — the pending implementation issue repeats the
  same scratch-`HOME` tmux check without an authentication requirement.
- The reproduction above — under the prescribed scratch-home shape, `gh api`
  exits 4 and asks for login instead of returning `coghex/kanban`.

**Handoff context:**

- **Current behavior:** The fullscreen design and its open implementation issue
  isolate the tmux session by replacing `HOME`, which also hides the supported
  GitHub CLI login. On a normal `gh auth login` installation without an
  exported token, the required real refresh fails before any overlay behavior
  can be exercised.
- **Expected behavior:** The live-acceptance environment isolates Kanban's
  mutable test state while retaining or explicitly supplying working GitHub
  read authentication, and it proves that the board populated before testing
  the fullscreen and modal-input interactions.
- **Scope and constraints:** Correct the durable design record and the pending
  #543 specification before relying on the check. Preserve open cards as
  live-only, the scratch isolation of Kanban config/cache/managed state, the
  wrapper-based tmux launch, and the existing fullscreen interaction targets.
  Do not make production code provision credentials or weaken the runtime's
  authentication requirement merely to satisfy a test. The exact transport
  may preserve the existing CLI login, provide an explicit test credential, or
  replace the network read with a controlled authenticated/fake-`gh` board,
  provided the check cannot pass on an unpopulated board.
- **Verification target:** Launch the wrapper from an environment authenticated
  only through the project's documented `gh auth login` path and prove its
  first refresh returns at least one card before exercising `f` in details,
  normal-session, and insert-session contexts and reopening an overlay
  windowed. Add an explicit fail-fast assertion for missing authentication or
  an empty/error board so the interaction steps cannot be skipped vacuously.
- **Deduplication:** The full open-issue inventory plus all-state searches for
  scratch-home tmux authentication, `GH_CONFIG_DIR`, `GH_TOKEN`, and live-check
  terms found no tracker item for this defect. Open issue #543 is the affected
  implementation slice, not an owner of the correction: its acceptance embeds
  the same assumption and never states that authentication must survive.
- **Remaining uncertainty:** GitHub CLI credential storage varies by host, and
  an explicitly exported token can make the current wrapper work. The project
  documents `gh auth login` as the supported prerequisite, however, and the
  current checkout reproduces the failure under exactly that supported shape;
  only the preferred credential-preservation mechanism remains a choice.
