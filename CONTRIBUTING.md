# Contributing to Kanban

Kanban is developed largely by AI agents working against a maintainer-operated
review pipeline, so the contribution path here is not the usual one. This guide
states how outside work is proposed, reviewed, and landed. It stays deliberately
thin: the operational detail belongs to the documents linked at the end, and is
not repeated here.

## Propose the work in an issue first

1. **Open a GitHub issue** describing the bug, gap, or change you have in mind.
2. **Wait for maintainer agreement** on whether the change belongs in the
   project and how it should be scoped. That agreement comes before any code.
3. **Then prepare a pull request** for the change as agreed.

**Unsolicited pull requests are not promised review or acceptance.** A pull
request that arrives with no agreed issue behind it may be closed unreviewed,
however good the change is. Opening an issue first costs far less than writing
work the project cannot take.

## What an agreed pull request goes through

A pull request has two required checks to clear:

- **`build-test`** — the aggregate build-and-test check. It has to be green.
- **`review-approved`** — passes once the canonical agent review has approved
  the pull request as it currently stands.

That review is **run by the maintainer**, not by a contributor: you neither
start it nor record its verdict. Expect to revise the pull request in response
to it, the same way the project's own changes are revised.

Approved pull requests are **landed by the maintainer's automation rather than
merged by hand** — nobody on this project merges a pull request manually — so an
approved change may wait a little before it lands.

## Where the details live

Two documents are authoritative, and this guide does not restate them:

- **[docs/development.md](docs/development.md)** — setup, building, running the
  test suites, and what the required checks verify.
- **[CLAUDE.md](CLAUDE.md)** — the repository's agent workflow: the contracts a
  change must stay consistent with, the quality gates it must meet, the source
  layout, and the landing conventions. Codex reads that same file through the
  tracked `AGENTS.md` alias.

Read `docs/development.md` before you build, and `CLAUDE.md` before you write a
change you intend to submit.
