# Project Review Findings: PRs #386–#361

This review covered the twelve newest merged pull requests as of 2026-08-19,
ordered by merge time: #386, #376, #379, #377, #374, #372, #371, #365, #364,
#363, #362, and #361. It also reviewed the direct first-parent documentation
commits `3817756`, `394b7ae`, and `2211b01` in that landing interval. The review
checked the linked issue contracts, landed changes, current descendants, local
quality gates, and current tracker state. Broader roadmap and repository-health
observations belong to the accompanying project audit; this report preserves
only confirmed current mistakes that still need one-at-a-time disposition.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [x] PRR-1. Public documentation still says the published first release does not exist — [#401]

## 1. Release-state documentation

### [#401] PRR-1. Public documentation still says the published first release does not exist

> **Captured note:** Correct the stale pre-release statements left in the
> public README and the design document's current-state paragraph. PR #386
> edited that paragraph after publication without reconciling it with the
> release record later in the same document.

**Verification:** `gh release view v1.0.0.0` confirms a non-draft,
non-prerelease GitHub Release published on 2026-08-16 with the
`kanban-1.0.0.0.tar.gz` asset. The repository also has the `v1.0.0.0` tag.
Nevertheless, the README tells readers that no release exists and directs them
to wait or use a source checkout, while the design document's current-state
paragraph says there are no tags or releases and calls #268 open. The same
design document's REL-4 record states that 1.0.0.0 is published, and issue #268
is closed. The contradiction exists at current `master` (`d37dace`).

**Evidence:**

- `README.md:36` — opens the release-archive installation path but says the first
  archive appears only in the future.
- `README.md:38` — states literally that there is no published release yet.
- `README.md:104` — describes a source checkout as the path for anyone who wants
  Kanban before the first release.
- `docs/design.md:88` — begins a current-state release paragraph whose facts were
  last reconciled to the pre-publication state.
- `docs/design.md:92` — says the repository has no tags and the remote has no
  GitHub Releases.
- `docs/design.md:97` — calls release-readiness epic #268 open, although it is
  closed and the processing ledger marks it complete.
- `docs/design.md:6748` — the same document's REL-4 record says Kanban 1.0.0.0 is
  published and records the tag, release, asset, and verification.

**Handoff context:**

- **Current behavior:** A prospective user following the README is told that the
  supported release-install path is unavailable, and the authoritative design
  contract presents mutually contradictory current release states.
- **Expected behavior:** Public and current-state documentation should say that
  v1.0.0.0 is published, link or name the usable release path, and describe the
  source checkout as the development/latest-source path rather than a wait for
  the first release.
- **Scope and constraints:** Documentation-only correction to the README and the
  current-state paragraph in `docs/design.md`. Preserve the historical release
  evidence and do not change release automation, the immutable tag, or the
  published asset.
- **Verification target:** Repository searches find no present-tense claim that
  the first release, tag, or GitHub Release is absent; Markdown links and the
  focused documentation/source-distribution checks remain green.
- **Deduplication:** Closed issue #340 authorized and verified the publication,
  but no open issue tracks reconciling these surviving pre-release statements.
- **Remaining uncertainty:** None.
