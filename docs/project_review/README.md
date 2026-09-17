# Project-review ledger and reports

This directory is the `project-review` workflow's own publishable home. It holds
`ledger.md` — one readable row per merged pull request, recording whether that
pull request has been reviewed, against which commit, when, and with what
evidence — and every findings report the ledger-era workflow writes, named
`<PR>.md` for a pull request's first report and `<PR>_<k>.md` for each later one.
`tools/command_sources/project-review.md` and the two bundle assets rendered
from it are the workflow; `project_review_ledger.py`, shipped in both bundles,
is the only thing that writes `ledger.md` or allocates a report name here.

**Every tracked Markdown file beneath this directory takes the `coordination`
publication lane, with no per-file declaration.** One directory row in
[`docs/agent-workflow-contract.md` §7](../agent-workflow-contract.md#7-document-publication-classification)
says so — `docs/project_review/ | coordination | audit-report` — and
`tools/test_source_distribution.py`'s `EXCLUDED_TRACKED_PATHS` and
`config.toml.example`'s `coordination_paths` for `coghex/kanban` carry the same
entry. That is what lets a one-pull-request-per-review cadence add reports
without a registry edit per report: a report written here is publishable the
moment it exists. Design D-18 of
[`docs/designs/project_review_ledger_design.md`](../designs/project_review_ledger_design.md)
records the decision. A consuming repository enrols the same directory through a
single `workflow.direct_publication_paths` entry.

This file is that row's tracked seed, so the directory exists before the
workflow first writes to it.

**Runtime artifacts never live here.** The lease's lock reference, its heartbeat
records, the liveness adapter's handshakes and attempt records, and the
temporary worktree a review is verified against all live under the repository's
Git common directory or under `mktemp -d`, outside every working tree. This
directory publishes; anything left in it publishes with it.

The `docs/project_review_<newest>-<oldest>.md` reports beside `docs/` are the
pre-ledger sweep's, and they stay where they are with their own §7 rows. The
migration imports their verified coverage without moving them.
