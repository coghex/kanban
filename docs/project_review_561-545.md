# Project Review Findings: PRs #561–#545

This bounded review covered every eligible merged pull request remaining above
the user's exclusive stop at #533, in merge-time order: #561, #560, #559,
#554, #553, #551, #550, #547, and #545. The bound therefore produced nine
pull requests rather than the requested twelve; no pull request numbered #533
or lower was entered. It also reviewed the nine direct first-parent commits
interleaved through that span: `08d54bf`, `93e9441`, `8ee7171`, `a9c86d2`,
`0b4e3e5`, `c31dc5c`, `4871ee2`, `d7e7236`, and `8b5010e`.

The batch was frozen at `origin/master@36bc9f3` on 2026-09-01. The later
descendant commits `318ab4d` and `35f2de5` were excluded rather than moving the
selection boundary; every concern below was rechecked against the current
descendant at `origin/master@35f2de5`, whose changes do not touch the relevant
paths.

Each pull request was checked against its linked issue or standalone contract,
pull-request body, commits, landed diff, canonical review discussion, current
implementation, callers, and focused tests. Each direct commit was checked
individually against its patch and the current state of the document it
changed. Later descendants were read only to establish whether a mistake still
exists. This report preserves the three confirmed current concerns that still
need one-at-a-time disposition.

The same pass verified three earlier concerns as completed rather than carrying
them forward: #561 finishes the filter-key documentation correction from
`docs/project_review_466-399.md` PRR-4; #559 fixes the reset and multiplicity
defect from `docs/project_review_398-353.md` PRR-1; and #553 restores the
persistent-worker controls from `docs/project_review_533-517.md` PRR-1. The
direct documentation commits correctly record the dispositions and design
refreshes they claim.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [ ] PRR-1. Public support and release gates assign managed-service readiness to `--doctor`
- [ ] PRR-2. The release rehearsal can select a different workflow dispatch
- [ ] PRR-3. The systemd controller reader silently misparses valid command quoting

## 1. Optional-component readiness

### PRR-1. Public support and release gates assign managed-service readiness to `--doctor`

> **Captured note:** Keep `kanban --doctor` scoped to the AI actions it actually
> checks, require the PR drainer and issue approval service to be verified with
> their controllers, and name those two managed services consistently in every
> public support and release instruction.

**Verification:** PR #547 added `SUPPORT.md` as part of the public maintainer
baseline. Its issue-preparation checklist says the AI actions, PR drainer, and
issue approval service are optional components and that `kanban --doctor`
reports which of them are ready. The executable does not do that. Its preflight
action type explicitly excludes the drainer, its doctor roster contains only
AI-agent actions, and its own heading describes an AI-action readiness report.
The issue approval service is absent too.

The later README upgrade procedure states the real boundary clearly: use
`--doctor` for AI-action readiness and each service's controller for service
status. PR #560's reusable release runbook nevertheless repeats the stale
boundary. Its manual upgrade gate requires `--doctor` to report “every
advertised component ready,” then names the managed components as the
“issue-review service and the PR drainer.” There is no managed issue-review
service to stop and restart. The managed second job is the issue approval
service; the issue-review backend is one of the workflow assets and is not a
service-status substitute.

An operator can therefore satisfy the written release gate without observing
either managed service, and can omit the approval job while trying to stop a
nonexistent issue-review service. A support report can likewise cite a clean
doctor result as evidence the drainer or approval job is healthy when neither
was checked.

The focused release-runbook suite passed 31 tests. That confirms the current
text shape, not the service boundary: its upgrade predicate looks only for a
`--doctor` item, and its negative control removes the exact false sentence that
says the command reports every component ready. The install/setup suites also
passed (73 setup tests, 38 drainer-install tests, 113 approval-install tests,
and 52 issue-review-install tests); those exercise the separate components and
do not make doctor a service-status probe.

**Evidence:**

- `SUPPORT.md:44-54` — the public checklist assigns readiness for the AI
  actions, PR drainer, and issue approval service to `kanban --doctor`.
- `src/Kanban/Preflight/Readiness.hs:63-73` — `PreflightAction` is explicitly
  the in-app AI-action roster, and the comment explicitly excludes the PR
  drainer.
- `src/Kanban/Preflight/Readiness.hs:386-418` — `doctorActions` contains only
  issue-review, issue-revision, solve, autosolve, and pull-request actions; the
  output identifies itself as “AI-action readiness.”
- `README.md:539-561` — the supported upgrade procedure says doctor observes
  AI-action readiness alone and assigns drainer and approval status to their
  own controllers.
- `docs/releasing.md:188-201` — the release gate misnames the issue approval
  service and separately requires doctor to report every advertised component
  ready.
- `README.md:229-247,416-429,514-532` — the actual second managed job is the
  issue approval service, while its issue-review backend is a resolved workflow
  dependency rather than another service.
- `tools/test_release_runbook.py:132-141,391-395,511-513` — coverage requires a
  doctor bullet but does not validate its scope, and the negative control is
  coupled to the false “every advertised component ready” wording.

**Handoff context:**

- **Current behavior:** Doctor reports only AI-action readiness. Public support
  says it also reports service readiness, while the release gate both repeats
  that claim and substitutes an “issue-review service” for the issue approval
  service.
- **Expected behavior:** Support and release instructions use doctor only for
  AI actions, name the PR drainer and issue approval service as the managed
  jobs, and require each installed job's controller status when claiming the
  advertised product is ready.
- **Scope and constraints:** Correct `SUPPORT.md`, `docs/releasing.md`, and the
  release-runbook regression rules together. Preserve the separate setup,
  status, stop, reinstall, and restart flows; do not broaden doctor into a
  mutating service controller. These documents are in the pull-request lane,
  and the parsed runbook test must travel with them.
- **Verification target:** Regression fixtures reject any support or release
  text that assigns drainer/approval readiness to doctor, reject “issue-review
  service” as a managed job, and require controller status for both actual
  services. Keep a negative control proving that merely mentioning `--doctor`
  cannot satisfy the service-readiness rule.
- **Deduplication:** Searches of all tracker states for doctor readiness,
  optional and managed components, the issue-review service, and the approval
  service found closed source issues #425, #460, #536, #538, and #539, plus the
  open release epic #534. Those own the component guides and release arc; none
  tracks these current cross-document contradictions.
- **Remaining uncertainty:** None. The executable and the current README agree
  on the real component boundary.

## 2. Rehearsal-run identity

### PRR-2. The release rehearsal can select a different workflow dispatch

> **Captured note:** Bind the rehearsal evidence to the workflow run created by
> the immediately preceding dispatch, rather than treating the repository's
> newest `workflow_dispatch` run as causally identical to it.

**Verification:** PR #560's runbook pushes the candidate to a scratch branch,
dispatches `Release` against that ref, and then says to find “the run it
started.” The command that follows lists the single newest `Release`
`workflow_dispatch` run repository-wide. It does not filter on the scratch
branch, candidate commit, triggering user, or a creation time captured before
the dispatch.

That query can observe a different operator's newer dispatch, or a prior run
while the just-created run has not appeared in the listing yet. Checking
`headSha` only after choosing that unrelated run does not establish causality.
If the other run has a different commit, the runbook tells the operator to
dispatch again instead of waiting for the original run to become visible,
creating a duplicate. If it has the same commit, the check passes and the
operator can watch and record the wrong run, including a run created with a
different dry-run input.

The installed GitHub CLI exposes `--branch`, `--commit`, `--created`, and
`--user` filters for `gh run list`, and its JSON output includes `headBranch`,
`headSha`, `createdAt`, and the run URL. The runbook uses none of those
correlation fields except reading `headSha` after selection. Its 31 passing
tests verify procedure order and the presence of broad evidence nouns; they do
not assert that the dispatch and selected run are the same event.

**Evidence:**

- `docs/releasing.md:95-120` — dispatch is scoped to
  `release-candidate-<n>`, but the subsequent `gh run list` is scoped only by
  workflow and event and takes `--limit 1`; a mismatch causes another dispatch.
- `docs/releasing.md:122-142` — the selected database ID is watched and recorded
  as the rehearsal evidence, so a false match escapes the selection step.
- [GitHub CLI `gh run list` manual](https://cli.github.com/manual/gh_run_list)
  — branch, commit, creation-date, and user filters, plus branch/SHA/time JSON
  fields, are available to narrow the run identity.
- `tools/test_release_runbook.py:56-141,391-395,504-513` — the checked contract
  covers step ordering, candidate prose, upgrade nouns, and other safety rules,
  but defines no dispatch-to-run correlation rule or negative control.
- Issue #539 and open epic #534 — both require durable evidence for the release
  workflow run; neither defines the repository-wide `--limit 1` result as
  acceptable evidence of the dispatch just made.

**Handoff context:**

- **Current behavior:** The rehearsal watches whichever matching workflow run
  is newest when the one-shot query executes, then proves only that selected
  run's commit.
- **Expected behavior:** Capture the run URL/ID returned by CLI versions that
  provide it, or poll from a pre-dispatch time anchor for a run matching the
  unique scratch branch, exact candidate commit, actor, and creation window.
  Eventual visibility waits for the original dispatch; it does not trigger a
  second dispatch merely because the first list response lacks it.
- **Scope and constraints:** Correct the reusable procedure and its regression
  rule without actually publishing or rehearsing a release. Preserve the exact
  candidate check, dry-run-only tag, scratch-branch cleanup, human publication
  authorization, and pushed-tag immutability. A workflow change is unnecessary
  unless command-level correlation cannot be made unambiguous.
- **Verification target:** A deterministic command transcript presents an
  unrelated newer dispatch, then delays visibility of the intended run. The
  procedure selects and watches only the intended branch/SHA/time-bounded run
  and dispatches exactly once. A same-SHA run with the wrong branch or creation
  window is also rejected.
- **Deduplication:** Searches of all tracker states for workflow dispatch/run
  correlation, `gh run list`, release rehearsal, dry-run tags, and candidate
  identity found closed release issues #289, #340, #539, #540, and #541, plus
  open release epic #534. None tracks this selection race in the new runbook.
- **Remaining uncertainty:** GitHub CLI versions differ on whether
  `gh workflow run` returns a usable run URL. The fallback correlation and
  visibility-polling path must therefore remain explicit; the current
  repository-wide newest-run query is insufficient under either behavior.

## 3. systemd command-word parsing

### PRR-3. The systemd controller reader silently misparses valid command quoting

> **Captured note:** Decode the systemd unit's command words under systemd's
> actual quoting rules—or fail closed on syntax Kanban cannot decode—so status,
> start, and stop never invoke a different argv from the service manager.

**Verification:** PR #559 correctly unified the drainer and approval-service
readers and implemented the reset and command-multiplicity semantics required
by issue #549. The shared word parser, however, recognizes only double quotes
at the start of a word, strips any backslash only while inside those quotes,
and otherwise splits on spaces or tabs. Its Haddock and tests call this
“systemd's own quoting” and say a hand-edited unit remains authoritative.

systemd's unit syntax also permits a whole item to be enclosed in single quotes
and removes those quotes. For this ordinary valid command:

```ini
[Service]
ExecStart=/usr/bin/python3 '/install dir/controller.py' run
```

systemd gives Python one script-path argument,
`/install dir/controller.py`. Evaluating the current
`unitExecStartArguments` against that exact unit produced:

```text
Right ["/usr/bin/python3","'/install","dir/controller.py'","run"]
```

Kanban therefore constructs a different command, retaining the quote
characters and splitting the path at its space. The same parser feeds both the
PR drainer and issue approval controller, and the parsed argv is what their
status, start, and stop paths invoke. This is not a display-only mismatch: a
valid hand-edited job can run under systemd while every dashboard control tries
the wrong controller command.

The focused Haskell suite passed all seven matching systemd-command tests. Its
first test covers double quoting, and the next covers one unquoted spelling,
`%%`, `\\`, and `\"`; no fixture covers single quotes or systemd's defined
C-style word escapes. The suite's own comment says it must not test a convenient
subset, so the passing result exposes an incomplete fixture rather than a
supported limitation.

**Evidence:**

- [systemd's `systemd.syntax` source](https://github.com/systemd/systemd/blob/main/man/systemd.syntax.xml)
  — the authoritative quoting section allows both single and double quotes
  around a whole item, removes them, and defines C-style escapes and line
  continuation.
- `src/Kanban/Drainer.hs:650-671` — the parsed argv is exactly what status,
  start, and stop invoke, while the Haddock claims systemd's own quoting and
  hand-edited-unit authority.
- `src/Kanban/Drainer.hs:690-761` — `unitWords` branches on `"` only, treats a
  single quote as a bare character, splits the following space, and cannot
  report malformed or unsupported syntax.
- `src/Kanban/ApprovalService.hs:13-22,90,1059-1067` — the approval service now
  intentionally shares `unitExecStartArguments`, so both managed services have
  the same misparse.
- `test/Spec/Drainer.hs:363-382` — the tests claim exact systemd quoting but
  fixture only double quotes and the selected existing escapes.
- `docs/agent-workflow-contract.md:771-775` and
  `docs/design.md:2491-2497` — the command read from `ExecStart` stays
  authoritative for what the service manager actually runs.
- Issue #549 requirement 4 and its out-of-scope list — the correction preserved
  the old double-quote subset and explicitly deferred specifier expansion, but
  did not define single-quoted command words as invalid or relax the
  authoritative-command contract.

**Handoff context:**

- **Current behavior:** Valid single-quoted command words are split and retain
  their quotes; additional defined escape syntax is either altered incorrectly
  or accepted without a faithful decode. Both service controllers can then
  invoke an argv systemd never used.
- **Expected behavior:** The shared parser faithfully handles systemd's defined
  whole-word single/double quoting, escapes, and continuation needed by
  `ExecStart`, and rejects malformed or deliberately unsupported syntax rather
  than returning a plausible wrong argv.
- **Scope and constraints:** Keep one shared reader, direct unit-file discovery,
  reset and multiplicity handling, no shell/glob expansion, backend-specific
  diagnostics, and the generated single-command `Type=exec` unit. Reconcile
  the explicitly deferred `%h`/`%i` specifier boundary rather than silently
  broadening it while fixing word syntax.
- **Verification target:** Shared parser fixtures cover single- and
  double-quoted paths, every supported escape class, line continuation,
  unmatched quotes, and explicitly unsupported specifiers. End-to-end drainer
  and approval discovery proves a single-quoted controller path reaches the
  exact executable/arguments for status, start, and stop; malformed or
  unsupported forms reach the existing unreadable-definition guidance and
  execute nothing.
- **Deduplication:** Searches of all tracker states for systemd quoting,
  single-quoted `ExecStart`, and controller-command parsing found only closed
  issue #549, the originating reset/multiplicity correction. Open Linux epic
  #290 is related platform scope, not ownership of this parser defect.
- **Remaining uncertainty:** The exact supported boundary for specifier and
  environment expansion remains a product decision already deferred by #549.
  The single-quote reproduction and the resulting argv mismatch are not
  uncertain.
