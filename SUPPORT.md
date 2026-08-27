# Support

Kanban has **one maintainer**, and support here is best effort. This document
states what that means and where each kind of report goes. It promises nothing
beyond what is written below.

## What is supported

**The latest release only.** Fixes are made on `master` and reach users in the
next release cut from it. Older releases are not patched, and no fix is
backported to a release line that has already shipped — upgrading to the latest
release is how a fix is obtained.

That is the same promise
[the security policy](SECURITY.md#supported-versions) already makes, applied to
ordinary bugs, questions, and feature requests.

## What to expect

- **No promised response time.** Reports and questions are read as the
  maintainer gets to them.
- **No release cadence.** A release is cut when there is something worth
  releasing, not on a schedule.
- **No promise that a change will be accepted.** Whether a bug is fixed or a
  feature is built is the maintainer's call, made case by case.

None of this is a service-level objective, and there is no paid support tier.

## Where to send it

Three routes, one for each kind of report. Use the one that matches what you
have.

| What you have | Where it goes |
| --- | --- |
| A bug, a question about using Kanban, or a feature request | A [public issue](https://github.com/coghex/kanban/issues) |
| A security vulnerability | GitHub's [private vulnerability-reporting form](https://github.com/coghex/kanban/security/advisories/new) — see [the security policy](SECURITY.md) |
| A code of conduct concern | The maintainer privately, at the address [the code of conduct](CODE_OF_CONDUCT.md) names |

That email address is the enforcement route for conduct concerns and is not a
support channel: a bug, question, or feature request sent there gets no faster
an answer than the public issue it belongs in.

## Before opening an issue

- **Search the open and closed issues first.** The behavior may already be
  recorded.
- **Say which version you are on.** `kanban --version` prints it.
- **Say what you have installed.** Kanban's AI actions, PR drainer, and issue
  approval service are optional components installed separately;
  `kanban --doctor` reports which of them are ready on your machine.
- **Read the guides.** The [user guide](docs/user-guide.md) covers the board and
  its controls, and [workflow setup and preflight](docs/workflow-setup.md)
  covers the optional components and why one might not be ready.

If you intend to send a change rather than a report,
[CONTRIBUTING.md](CONTRIBUTING.md) states how work is proposed, reviewed, and
landed here — an issue comes first, and an unsolicited pull request is not
promised review.
