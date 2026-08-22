# Security Policy

Kanban is a terminal board that runs on a developer's own machine, drives their
authenticated GitHub and agent CLIs, and — through its optional installers —
can leave persistent background jobs behind. That surface is worth a private
disclosure route, and this document is it.

## Reporting a vulnerability

**Report privately through GitHub, not in a public issue.**

Use this repository's private vulnerability reporting form:

> **<https://github.com/coghex/kanban/security/advisories/new>**

If that link ever moves, the navigation is: the repository's **Security** tab →
**Advisories** → **Report a vulnerability**. Only the maintainer and the people
you add to the advisory can read what you submit there.

**Do not put vulnerability details in a public issue, pull request, discussion,
or commit message**, and do not open a public issue to ask whether something
counts — send it through the form and it will be triaged there. A public report
is the one outcome this policy exists to avoid; if you have already filed one,
say so in the advisory rather than adding more detail to the public thread.

A useful report names the affected version or commit, what an attacker gains,
and the smallest sequence of steps that reproduces it. Kanban's optional
components are installed separately, so say which of them are installed on the
machine you reproduced on.

## What to expect

Kanban has **one maintainer**, and this is best effort with **no guaranteed
response time**. Rather than promise a schedule that cannot be kept:

- Reports are read as the maintainer gets to them, and acknowledged in the
  advisory thread.
- You will be told whether the report is considered in scope, and, if it is,
  roughly what the fix looks like.
- Fixes land on `master` through the project's normal reviewed pull-request
  pipeline. There is no separate security branch and no backporting to older
  releases: the fix is in the next release cut after it lands.
- Credit in the advisory is yours if you want it; say so in the report.
- Please keep the report private until a fix has landed, or until the
  maintainer agrees it can be disclosed.

## Scope

Kanban has two scopes, because installing the optional components changes what
is on the machine. Both are in scope; report against whichever you reproduced
on, and say which.

### The board on its own

The `kanban` executable and the terminal UI, with no optional component
installed. This covers at least:

- **The user's authenticated CLIs.** Kanban invokes the terminal user's own
  `gh`, `codex`, and `claude` with their credentials — `kanban --doctor` runs
  the preflight that confirms it reaches all three. A path by which board state,
  repository data, or external text causes an invocation the user did not
  ask for, or reaches a repository outside the configured one, is in scope.
- **On-disk caches.** Cache directories are created `0700` and cache files
  `0600`. Kanban never caches an open issue or pull-request body; completed
  history is the deliberate exception and carries the whole stable payload of a
  settled item, **bodies included, from private repositories**
  (`docs/design.md` §16). That exception is protected by permission rather than
  by omission, so anything that loosens those permissions, writes cached
  content outside the intended directories, or puts an *open* private item's
  body on disk is in scope.
- **External text reaching the terminal.** Issue and pull-request text, agent
  output, and other data Kanban does not author are sanitized by `Kanban.Text`
  before they are drawn. A way to get escape sequences, control characters, or
  other terminal-controlling bytes past that sanitization and into the
  terminal is in scope.
- **Configuration and secrets handling** — a token, credential, or private
  repository body that reaches a log, a transcript, or a world-readable file.

### The board plus the optional installed components

Everything above, plus what the installers put on the machine. These are not
installed by default and each is installed deliberately:

- **The PR drainer** (`tools/install_drainer.py`) and **the issue approval
  service** (`tools/install_issue_approval.py`) install **persistent background
  jobs** — a launchd LaunchAgent on macOS, a systemd user unit on Linux — that
  run on the user's behalf without the board being open. The drainer merges
  eligible pull requests; the approval service runs the canonical review
  backend against queued issues. Anything that lets an unintended input reach
  one of those jobs, widens what it will merge, publish, or execute, or lets
  another local user influence the job's definition or its durable state, is in
  scope.
- **The canonical issue-review backend** (`tools/install_issue_review.py`),
  which is **not a background service**: it installs a Kanban-managed
  executable link to the tracked backend plus a discovery record naming that
  link's absolute path. Because that record and link decide which executable
  later runs as the reviewer, a way to make the resolution point at an
  attacker-chosen file — defeating the managed-asset marker that guards
  re-pointing, or the record's own integrity — is in scope.

### Not vulnerabilities here

- **Kanban acting as the terminal user.** Running the user's authenticated
  `gh`, `codex`, and `claude` with their credentials, and merging or reviewing
  on their behalf once a component is installed, is the documented design. A
  report that Kanban can therefore do what that user can do is not a finding;
  a report that it can be made to do so *without* the user's intent is.
- **Vulnerabilities in `gh`, `codex`, `claude`, GHC, or another dependency.**
  Report those to the projects that own them. If Kanban's *use* of one is what
  creates the exposure, that is in scope here.
- **Findings that assume an attacker already has the user's account** on the
  machine, or already holds their GitHub credentials.

## Supported versions

Fixes are made on `master` and reach users in the next release cut from it. The
latest release is the only supported one; older releases are not patched.
