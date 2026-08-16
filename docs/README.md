# Documentation

## Start here

- [Project overview and quickstart](../README.md) — what Kanban is, installing
  it from a release archive, and the platform and component support matrix.
- [User guide](user-guide.md) — board layout, controls, reviews, and background jobs.
- [Workflow setup and preflight](workflow-setup.md) — installing the optional AI-action components from a fresh clone, and diagnosing why one is not ready.
- [PR drainer](pr-drainer.md) — installation, configuration, operation, and logs.

## For contributors

- [Development](development.md) — source layout, build commands, and tests.
- [Design and implementation notes](design.md) — detailed behavior and engineering decisions.
- [Bug findings](bugs.md) — repository evidence collected for later triage,
  with the status of each entry.
- [Media](media/README.md) — the tracked board screenshot, what it is derived
  from, and how to regenerate and review it.

## Workflow contracts

These describe what Kanban's AI actions depend on. Read them when changing or
operating those workflows, not to install or use the board.

- [Agent-workflow contract](agent-workflow-contract.md) — every external workflow Kanban's AI actions depend on, ownership, and the portable-install policy.
- [Drafting and issue-review workflow contract](drafting-workflow-contract.md) — the packaged issue-drafting and canonical issue-review workflows, their responsibilities, and their boundaries.
- [Design and report document workflow contract](document-workflow-contract.md) — the packaged design-document and findings-report workflows, their shared status vocabulary, and the five cross-brand pairs that now cover every one of them.
