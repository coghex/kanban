# Project Review Findings: PRs #183–#170

This review continued below the completed #185 cursor and covered the next
twelve merged pull requests by merge time: #183, #182, #181, #180, #179,
#178, #177, #176, #175, #174, #173, and #170. There were no direct
first-parent commits interleaved between #185 and #170. The batch was frozen
at `origin/master@3215e3d` on 2026-08-22. Its implementation is
`2e2003e`; the intervening commits edit only
`docs/project_review_456-446.md`, so they do not alter this batch's code or
the finding below.

Each pull request was checked against its linked issue, effective reviewed
specification, pull-request body, commits, landed diff, canonical review
history, current implementation, callers, and current tests. Later descendants
were read only to establish whether a mistake still exists. The test-suite
split, canonical-reviewer record discovery, label-chip configuration,
per-repository drainer identity, implementation-key parsing, bounded worker
state, external usage commands, ordering and Unicode coverage, test repairs,
and byte-oriented subprocess capture remain present and covered. Review-time
defects involving malformed or dangling reviewer records, drainer identity and
record transactions, ambiguous implementation-key prefixes, colliding lease
keys, external-command setup failures, missing standalone-PR ordering
coverage, stale test counts, locale-sensitive Git invocation, recycled process
groups, and reaped probe wrappers were corrected before their pull requests
were approved. They are not duplicated here.

The current Claude termination group passed its four focused examples. A
separate process-level reproduction then exercised the uncovered exception
edge and confirmed the surviving descendant described below. The same frozen
implementation had already passed the full 1,554-example Haskell suite during
the immediately preceding batch. This report preserves the one newly
confirmed current mistake that still needs one-at-a-time disposition.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [ ] PRR-1. Claude probe I/O exceptions bypass descendant cleanup — [deferred]: PR #479 unmerged

## 1. Claude usage-probe lifecycle

### [deferred] PRR-1. Claude probe I/O exceptions bypass descendant cleanup

> **Deferred:** This report is not yet a tracked coordination document, so a
> disposition applied to it cannot be recorded — publication returns
> `no-baseline` and writes nothing, which would strand the tracker
> transaction with the issue already filed. Cleared when PR #479 merges and
> `docs/project_review_183-170.md` is covered by a §7 `coordination` row on
> `master`. The finding itself is verified and its issue drafted and
> approved; only the filing is held.

> **Captured note:** Complete PR #175's process-ownership guarantee by routing
> every exception after the Claude probe starts through its census-aware
> descendant cleanup before the provider returns an error.

**Verification:** PR #175 added recursive process-identity census and bounded
INT → TERM → KILL escalation for the explicit timeout, clean-exit, and
missing-pipe branches. `runProcess` does not protect that cleanup with an
exception-safe boundary, however. An `IOException` from transcript capture or
from writing the clean-exit sequence unwinds directly through
`withCreateProcess`; the outer `try` converts it to `RequestFailed`, but no
call to `stopProcess`, `finishProcess`, or their descendant census has run.
`withCreateProcess` can clean up the direct `script` wrapper, but it does not
own a Claude child that the pty placed in a separate session and process group.

A disposable harness drove the exported `runClaudeProvider` through that
exact current path. Its fake BSD `script` wrapper launched an INT-, TERM-, and
HUP-resistant child in a separate process group, emitted a complete usage
transcript, and exited before Kanban wrote the clean-exit sequence. The result
was
`Left RequestFailed ("... hPutBuf: resource vanished (Broken pipe) ...")`.
After the provider returned and a further 300 ms elapsed,
`readProcessSnapshot` still found the recorded child alive with parent PID 1
and its own process-group ID. The harness then killed that exact group so the
verification itself left no stray process.

The four existing focused termination examples all pass because their
fixtures keep the pipe open until the expected clean-exit request or wait for
the explicit timeout. None closes a pipe while a separately grouped child
survives, so the green suite does not cross the leaking branch.

**Evidence:**

- `src/Kanban/Claude.hs:166-180` — the `IOException` handler surrounds
  `withCreateProcess` and converts any exception into a provider error, but it
  has no cleanup action for the already-started process tree.
- `src/Kanban/Claude.hs:221-239` — only the explicit timeout and missing-pipe
  branches call `stopProcess`; exceptions from `captureUsage` or
  `requestCleanExit` leave before either cleanup function is reached.
- `src/Kanban/Claude.hs:248-286` and `:308-312` — prompt responses and the
  `ESC` plus `/exit` sequence write and flush the pty input handle, operations
  that can raise when the wrapper or client closes unexpectedly.
- `src/Kanban/Claude.hs:314-337` — `finishProcess` and `stopProcess` are the
  paths that capture the wrapper and recursive descendants before reaping and
  route them through verified escalation; the exception edge bypasses both.
- `test/Spec/Agent/Usage.hs:187-249` — the lifecycle group covers clean exit,
  timeout with same- and separate-group descendants, and a forced kill after a
  valid capture, but not a broken capture or exit-request pipe.
- `docs/design.md:1950-1952` and `:4718-4738` — usage probes are short-lived
  workers, and the release evidence explains that a pty-separated Claude
  process can be reparented out of Kanban's descendant tree and therefore must
  be checked against the whole process table.

**Handoff context:**

- **Current behavior:** If the Claude wrapper or client closes a pipe while
  Kanban is capturing the usage screen or sending `/exit`, the refresh reports
  `RequestFailed` but can leave a separately grouped Claude descendant alive
  and reparented under PID 1.
- **Expected behavior:** Once a Claude probe has started, every return path —
  success, timeout, decode failure, missing pipes, or exception — completes
  descendant-aware cleanup before publishing its result. A cleanup failure
  remains a provider failure and never permits a snapshot to be reported as
  fresh.
- **Scope and constraints:** Preserve the current script-flavor diagnostics,
  normal fast path, bounded INT → TERM → KILL cadence, PID/start-identity and
  fresh-group-membership checks, snapshot-failure fallback safety, and the
  rule that unrelated or recycled processes are never signalled. This is the
  built-in Claude usage probe only, not the external usage-command provider or
  the authenticated Claude reviewer runner.
- **Verification target:** Add a real-process fixture whose wrapper closes the
  pty after spawning a separate-group, signal-resistant child. Exercise at
  least the clean-exit write failure, require the provider to return a bounded
  failure, and verify both recorded identities are absent from the whole
  process table afterward. Covering an input write during transcript capture
  as a second exception point would hold the broader cleanup invariant rather
  than only this reproduction.
- **Deduplication:** Searches across all open and closed tracker items and all
  findings reports found no active owner for this exception path. Closed issue
  #20 and PR #175 own bounded group-wide termination after the explicit normal
  and timeout branches; their tests are the adjacent coverage, not an open
  correction. Closed #331 changes `script` flavor selection, and closed #270
  records successful live-refresh lifecycle evidence. CH-12A-1 in
  `docs/code-health-report.md` concerns the separate authenticated review
  subprocess and was fixed by #154.
- **Remaining uncertainty:** The production frequency depends on how often
  `script` or Claude Code exits between capture and the next pty write. The
  broken-pipe event and surviving-child outcome are reproduced; there is no
  uncertainty that the current exception branch skips owned-descendant
  cleanup.
