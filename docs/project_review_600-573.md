# Project Review Findings: PRs #600–#573

This review covered the twelve newest uncovered merged pull requests at the
frozen selection boundary, in merge-time order: #600, #599, #598, #596, #584,
#583, #582, #581, #579, #580, #578, and #573. It also reviewed the twenty-one
direct first-parent documentation commits interleaved through that range:
`3eb10f5`, `def5f5a`, `8983a33`, `4912493`, `9b3e000`, `b9dc540`, `0ac97e7`,
`239cd29`, `8d7d931`, `f328bdb`, `12568a7`, `fe4040d`, `0f566ad`, `aeca00c`,
`20b6ffa`, `b40b4f7`, `cce33c1`, `aa0bd53`, `ec54fd1`, `b6019de`, and
`82d4afa`. The batch was frozen at the repository history head
`origin/master@742bd3e` on 2026-08-31; no unit or concern was excluded.

Each pull request was checked against its linked issue or standalone contract,
pull-request body, commits, landed diff, current implementation, callers, and
focused tests. Each direct commit was checked individually against its patch
and the current state of the document it changed. This report preserves the two
confirmed current concerns that still need one-at-a-time disposition.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [x] PRR-1. Claude embedded reviews still inherit local settings and hooks — [#606]
- [ ] PRR-2. Janitor proves one remote endpoint but can delete from others

## 1. Claude embedded-review isolation

### [#606] PRR-1. Claude embedded reviews still inherit local settings and hooks

> **Captured note:** Correct PR #600's Claude launch so an embedded review does
> not load the operator's user, project, or local settings and cannot run their
> hooks merely by starting a review.

**Verification:** PR #600 describes `--strict-mcp-config` plus `--tools ""` as
the complete hermetic boundary and claims those flags stop the operator's
`SessionStart` hook. The landed argument list contains those two controls but no
control over settings sources. The installed Claude Code 2.1.252 help assigns
the flags narrower meanings: `--strict-mcp-config` ignores other MCP
configurations, and an empty `--tools` disables the built-in tool set;
`--setting-sources` independently controls user, project, and local settings,
while restricted mode explicitly ignores those settings. Therefore the launch
still loads the settings that declare hooks, and a configured hook can execute
in the repository-root child process even though MCP servers and built-in tools
are disabled.

The two launch tests assert the incomplete argument list verbatim and call it
hermetic. The stream fixture even emits and ignores a `hook_started` record,
but no test provides user, project, or local settings and proves their hook is
not run. The backend is landed but is not yet selected by the board's current
constant provider route; open issues #587–#589 add its tools, control parity, and
eventual provider routing. None requires isolation from settings sources, so
activating the backend as specified would expose this latent launch defect.

**Evidence:**

- `src/Kanban/ProviderAdapter.hs:279-304` — the comment promises machine-config
  isolation, but `claudeReviewArguments` carries no settings-source control.
- `test/Spec/Agent/Adapter.hs:177-208` — the adapter test calls the launch
  hermetic while pinning only MCP and built-in-tool isolation.
- `test/Spec/Agent/ClaudeReview.hs:80-105` — the live fake-executable test
  repeats the incomplete argv as the expected launch.
- `test/Spec/Agent/ClaudeReview.hs:441-458` — the decoder accepts a
  `SessionStart` `hook_started` event but does not prove that configured hooks
  are excluded from the real child.
- `docs/model_settings_design.md:672-676` — D-15 requires a hermetic session
  that does not inherit the machine's Claude Code configuration.
- Installed `claude --help` for Claude Code 2.1.252 — `--setting-sources`
  controls user/project/local settings; `--strict-mcp-config` controls only MCP
  configurations; restricted mode explicitly ignores those settings.

**Handoff context:**

- **Current behavior:** The landed Claude review process disables non-declared
  MCP servers and built-in tools but still reads user, project, and local
  settings, allowing their lifecycle hooks to run when the backend starts.
- **Expected behavior:** Starting an embedded review cannot load or execute
  operator- or repository-defined Claude settings and hooks; only configuration
  deliberately supplied by Kanban is in scope.
- **Scope and constraints:** Preserve the stream-json channel, structured
  verdict schema, roster-selected model and effort, empty built-in tool set,
  strict MCP boundary, repository working directory, and the MCP re-entry that
  issue #587 will add. Do not solve the separate tool, interrupt, or routing
  slices owned by #587–#589.
- **Verification target:** Run a fake or isolated real CLI with user, project,
  and local settings that each declare an observable `SessionStart` hook, then
  prove the adapter's embedded-review launch executes none of them while its
  intended stream and Kanban-supplied configuration still work. Pin the full
  corrected argv at both the adapter and live-launch seams.
- **Deduplication:** Searches of all tracker states for Claude settings-source,
  hook, hermetic-launch, and embedded-review terms found no issue for this
  defect. Open #587 calls the existing flags hermetic but owns only Kanban's MCP
  tools; #588 and #589 own interrupt parity and provider routing.
- **Remaining uncertainty:** The backend is not yet reachable through the
  current board route, so the defect is latent until #589 or another caller
  selects Claude. The incomplete isolation and the behavior of the shipped CLI
  flags are otherwise established.

## 2. Janitor remote-deletion authority

### PRR-2. Janitor proves one remote endpoint but can delete from others

> **Captured note:** Do not let PR #581's janitor delete a remote branch until
> the endpoint proved and reported to the user is the exact endpoint every
> approved push will mutate.

**Verification:** The janitor derives GitHub's `owner/name` from `origin`'s
fetch URL, reads branch heads with `git ls-remote --heads origin`, and records
the observed SHA. After approval it runs `git push origin` with a SHA-bound
force-with-lease. The lease prevents deletion when the named branch moved, but
it does not bind the push destination: Git may use `remote.origin.pushurl` for
pushes, that setting may name multiple endpoints, and reducing the fetch URL to
`owner/name` discarded its host before the user was told which repository was
being audited. A different push endpoint with the same branch at the recorded
SHA therefore satisfies the lease and can be deleted even though every GitHub
read and the `ls-remote` proof described another repository.

This is not a hypothetical outside the repository's safety model. PR #573,
reviewed in the same batch, deliberately removed remote-branch deletion from
the finalize workflow for exactly this fetch-URL/pushurl/host mismatch. The
authoritative workflow contract retains that rationale. PR #581 added the same
remote mutation to janitor later in merge order without resolving or even
reporting those destination identities. Its tests use one fetch/push endpoint
and exercise only the moving-branch lease, so they cannot expose the mismatch.

**Evidence:**

- `tools/command_sources/janitor.md:48-64` — repository identity is reduced
  from the fetch URL to `owner/name`, losing the remote host and all push URLs.
- `tools/command_sources/janitor.md:151-160` — branch existence and SHA are
  proved with `ls-remote` against `origin`'s read side.
- `tools/command_sources/janitor.md:296-306` — the approved deletion is sent by
  `git push origin`, which can resolve through different or multiple push URLs.
- `tools/test_janitor_workflow.py:999-1068` — the remote-deletion harness gives
  `origin` one endpoint for both reading and pushing; it has no pushurl or
  cross-host case.
- `docs/agent-workflow-contract.md:1671-1680` — the finalize contract says a
  remote deletion is unsafe because fetch identity, multi-valued pushurl, and
  host-erasing `owner/name` reduction do not form one authority boundary.
- PR #573's landed diff — finalize deletes no remote branch specifically
  because `git push` may follow multiple `remote.origin.pushurl` values and the
  reduced repository name loses the host.

**Handoff context:**

- **Current behavior:** Janitor can report and obtain approval for a branch in
  one GitHub/fetch repository, then send its deletion to one or more different
  push endpoints. The SHA lease checks branch state, not repository identity.
- **Expected behavior:** A remote branch is deleted only when every actual push
  target is the exact repository whose branch and SHA were audited and shown to
  the user. If that identity cannot be proved cheaply and immediately before
  mutation, janitor leaves the remote branch as visible cleanup debt.
- **Scope and constraints:** Preserve read-only census behavior, item-level
  approval, one branch per command, full-SHA recording, immediate rechecks, and
  the force-with-lease guard against concurrent branch movement. A conservative
  no-remote-delete outcome is acceptable; do not weaken local branch or
  tracking-ref cleanup gates.
- **Verification target:** Add rendered-asset coverage with a fetch URL for the
  audited repository and one or multiple different push URLs, including a
  same-`owner/name` repository on another host. Prove no unreported endpoint is
  mutated. Retain the existing test that moves the audited branch after proof
  and expects the SHA lease to refuse deletion.
- **Deduplication:** Searches of all tracker states for janitor pushurl, remote
  host, and remote-branch deletion terms found no issue for this defect. Closed
  #575 introduced janitor, while closed #544 and PR #573 record the same safety
  analysis only for finalize and do not repair janitor.
- **Remaining uncertainty:** None about the authority mismatch. Whether the
  eventual correction removes remote deletion or proves and displays every
  push target is an implementation tradeoff for later disposition.
