# Releasing Kanban

The reusable procedure for cutting a Kanban release, in the order it is
performed. It is written for the maintainer and for an agent working under a
release issue's authority, and it is the same document for every version: the
only things that change from one release to the next are the version string and
that release's own evidence, both of which live on that release's issue rather
than in this file.

Nothing here decides *that* a release should happen. That decision is the
maintainer's, it is recorded by opening the version-specific release issue, and
no agent may make it. This document describes how a release is carried out once
that decision exists.

Every release has exactly one tracker artifact: a release issue filed from the
`Maintainer release` template, carrying the checklist these steps drive and the
maintainer's explicit publication authorization. Read
[the evidence section](#where-release-evidence-lives) before you start, because
it is what the last two steps write and it is deliberately not a Markdown file
in this repository.

## Before you start

You need a clean checkout of this repository with `origin` fetched, `gh`
authenticated as an account that can push tags and edit repository settings, and
the pinned toolchain the CI workflow installs. `cabal` must be able to resolve a
build plan, because the rehearsal below builds the candidate archive.

The release issue is open, carries the `release` label, and is assigned to
whoever is running this. Every step below records its result on that issue —
either by checking its item or, where the step says so, by adding the evidence
the item asks for. A step whose result is not recorded has not happened.

## 1. Review the version and PVP compatibility

Decide the new version from the changes that have merged since the previous
release, under the Package Versioning Policy: a breaking change to a supported
interface moves one of the first two components, an addition moves the third,
and a change that is neither moves the fourth. Kanban's supported interfaces are
the executable and its CLI, the documented configuration, the on-disk
compatibility surface, the installers, and the workflow contracts — not the
`Kanban.*` modules, which are implementation seams.

Record the chosen version and the one-line reason for that component choice on
the release issue. The version in `kanban.cabal` and the version the CLI reports
must both become that value; they are bumped in the ordinary pull-request lane,
not here.

## 2. Promote the changelog

[`CHANGELOG.md`](../CHANGELOG.md) states the rule this step follows: cutting a
release replaces the `### Unreleased` heading with `## <version>` and creates a
fresh empty `### Unreleased` section above it. The release machinery reads only
`##` headings, so the promotion is what makes the notes visible to it.

Read the promoted section as a user would. Every entry describes a change to
something a user can observe; anything that reads as an internal note belongs in
the pull request that made it, not in the release notes.

The promotion lands through the ordinary pull-request lane along with the
version bump, so that by the time you select a candidate the notes are already
on `master`.

## 3. Select the candidate commit

Pick one exact commit on `master`. Everything from here to the tag is a
statement about that one commit: the rehearsal, every gate below, the
authorization, and the tag itself all name it, and a gate recorded against a
different commit is not a gate.

```console
git fetch origin
git rev-parse origin/master
gh run list --workflow ci.yml --commit <commit> --json name,conclusion,event,headSha
```

The candidate is eligible only when the required `build-test` job reports
`success` for that exact commit. A run on a different commit — an ancestor, a
descendant, or a pull-request head that was merged into it — does not qualify
it. If `master` moves while you are working, either restart from this step with
the new commit or keep the original one; do not carry gates across.

Record the commit and the CI run on the release issue.

## 4. Rehearse the release on the candidate

A packaging gap costs a whole workflow run to discover, so check it locally
first, from a checkout at the candidate commit:

```console
python3 -m unittest tools.test_source_distribution
python3 -m unittest tools.test_document_classification
```

The rehearsal then runs the real publication path against the candidate under a
dry-run tag, and can create nothing but a draft. A `workflow_dispatch` takes a
branch or tag name rather than a commit, so pin the candidate to a scratch
branch and dispatch against that. The scratch branch triggers nothing — CI runs
on `master` pushes and pull requests only — and the dry-run tag is not a release
tag: it names no ref yet, it matches no `v*` pattern, and the rehearsal refuses
outright under a tag that does.

```console
git push origin <commit>:refs/heads/release-candidate-<n>
gh workflow run Release --ref release-candidate-<n> \
  --field dry_run_tag=release-dry-run-<n>
```

`gh workflow run` reports no run id, so find the run it started and confirm it
is the candidate's before reading anything else:

```console
gh run list --workflow Release --event workflow_dispatch --limit 1 \
  --json databaseId,headSha,status,conclusion
gh run watch <databaseId>
```

The run's `headSha` must be the candidate commit exactly. Anything else is a
rehearsal of some other tree: delete the scratch branch, re-push it at the
candidate, and dispatch again.

Confirm from the run that `build-test` succeeded, that the payload carried
exactly one archive named for the chosen version, and that `publish-dry-run`
created a draft rather than a release. The scratch branch has done its work
once the run's head is confirmed, and nothing downstream reads it:

```console
git push origin --delete release-candidate-<n>
```

**Keep the draft.** Its asset is the only build of this candidate that exists —
no published release carries it — and step 6 upgrades onto it. Step 6 says when
the draft goes.

The archive the rehearsal builds is also what the release will publish, so this
is where a packaging gap surfaces. If the candidate fails here, it is not a
candidate: fix the cause in the ordinary lane, and return to step 3 with a new
commit.

Record the rehearsal run on the release issue.

## 5. Review dependencies and maintenance assumptions

Perform the review [described below](#dependency-and-maintenance-review) against
the candidate, and record its date and result on the release issue. A review
that finds a real change does not block the release by itself — the change enters
the ordinary issue and pull-request lane, and the release either waits for it or
records that it was deferred.

## 6. Perform the manual supported-host upgrade

One person upgrades a real macOS installation from the previous published
release to the candidate, following
[the README's upgrade section](../README.md#upgrade-to-a-new-release) exactly as
a user would. This is the gate no automated check replaces: the rehearsal proves
the archive builds and installs in a clean directory, and this proves an existing
installation survives being moved onto it.

The candidate is not published, so the README's first step — which downloads the
latest public release — is the one step performed differently. Take the archive
from the draft step 4 left, and follow the README from its second step onward:

```console
gh release download release-dry-run-<n> --repo coghex/kanban \
  --pattern 'kanban-*.tar.gz'
tar -xzf kanban-*.tar.gz
```

The upgrade covers, and the record on the release issue names the result of, each
of:

- the executable, installed from the candidate archive and reporting the
  candidate's version;
- the optional workflow assets, re-registered from the new archive;
- the managed components — the issue-review service and the PR drainer — stopped,
  re-pointed at the new archive, and restarted only where they were running
  before;
- `kanban --doctor`, reporting every advertised component ready;
- an interactive board run against a real repository;
- preservation of supported configuration and durable state — the configuration
  files, the cached snapshot, and the service records survive the upgrade rather
  than being recreated empty.

A failure here returns to step 3 with a new candidate.

Once every result above is recorded, the draft has done its work:

```console
gh release delete release-dry-run-<n> --repo coghex/kanban --yes
```

No `--cleanup-tag`: a draft is never published, so GitHub created no
`refs/tags/release-dry-run-<n>` for it and there is nothing to clean up.

## 7. Check the repository settings

The repository's public metadata is part of what a release publishes, so it is
checked before authorization rather than after:

```console
gh repo view coghex/kanban --json description,homepageUrl,repositoryTopics
```

The description must be exactly:

```text
A keyboard-driven terminal board for GitHub issues, pull requests, and agent workflows.
```

The topics must be exactly `haskell`, `terminal`, `tui`, `kanban`, `github`,
`developer-tools`, `ai-agents`, and `brick`. The homepage must be empty: the
README is the product entry point, and a placeholder homepage would advertise a
site that does not exist.

Correct any drift now and record the checked state on the release issue.

## 8. Record the publication authorization

**This step is the authorization, and it is a separate recorded action.** No
other step implies it, no combination of green checks satisfies it, and no agent
may perform it. It is the point at which a human decides that this specific
commit becomes a public release.

The maintainer adds one comment to the release issue naming the version and the
full candidate commit:

```text
Authorized: publish <version> from <commit>.
```

Only then is the authorization item on the checklist checked, and the comment's
URL is recorded beside it. Before that comment exists, step 9 has no authority
and must not be performed. If the candidate changes for any reason, the previous
authorization is void: return to step 3, and obtain a new authorization naming
the new commit.

## 9. Push the one annotated tag

Create exactly one annotated tag naming the authorized commit, and push it:

```console
git tag -a v<version> <commit> -m "Kanban <version>"
git push origin v<version>
```

The tag is the trigger. The release workflow reacts to it, verifies that the tag
is already on the remote, and creates the GitHub Release itself — the tag is
never created by the workflow, and the Release is never created by hand.

From this moment the tag is immutable. Read
[what to do if something fails](#if-something-fails-after-the-tag-is-pushed)
before you push it, because the answer is not to undo this.

## 10. Observe the release workflow

Watch the run the tag triggered:

```console
gh run list --workflow Release --limit 5
gh run watch <run-id>
```

Confirm that `build-test` succeeded, that `publish-release` succeeded, that
`publish-dry-run` was skipped, and that the run's ref is the tag you pushed and
its head is the authorized commit.

## 11. Verify the published release as a consumer

From a clean directory, on a machine that has none of this repository's state,
download the published asset and repeat the build, install, and version check:

```console
gh release download --repo coghex/kanban --pattern 'kanban-*.tar.gz'
shasum -a 256 kanban-*.tar.gz
tar -xzf kanban-*.tar.gz
cd kanban-<version>
cabal build all
cabal install exe:kanban --installdir "$PWD/bin" --overwrite-policy=always
./bin/kanban --version
```

Confirm the release is public and not a draft or prerelease, that it carries
exactly one asset, that the asset's digest matches the one the release run
recorded, and that the installed executable reports the released version.

## 12. Record the evidence and close the issue

Add one comment to the release issue naming, in one compact block:

- the released commit;
- the required CI run on it;
- the tag, and the commit its peeled ref resolves to;
- the release workflow run and its jobs' conclusions;
- the published asset's name and its `sha256` digest;
- the consumer verification from step 11.

Then close the release issue. That comment is the permanent record of the
release, and closing the issue is what ends the procedure.

## Where release evidence lives

Release evidence lives on the release's own issue: the checklist records each
gate as it passes, and one comment after publication records the outcome. That
is the whole of it.

No permanent per-release Markdown file is created, and
[`design.md`](design.md) does not grow with each release. Its section 21 holds
the first release's gate records because that arc predates this procedure, and
it is closed: a later release adds nothing to it. If you find yourself about to
write a release's evidence into a tracked document, the release issue is where
it belongs instead.

## If something fails after the tag is pushed

Once the tag is on the remote it is public, and it is immutable. Whatever has
gone wrong — a failed publisher, a wrong commit, a bad archive, a mistake noticed
a minute later — the response is the same: **report what happened and stop.**

Specifically, and without exception:

- **Do not delete the tag.** Not locally-then-remotely, not "before anyone
  notices".
- **Do not move the tag** to another commit, and do not **force-push** it.
- **Do not reuse** that version number for a different commit, in this release or
  a later one.
- **Do not create the GitHub Release by hand**, or edit one the workflow created,
  to paper over a failed run. The workflow is the only actor that creates a
  Release.

Record the failure on the release issue with everything you observed, leave the
tag exactly where it is, and hand the decision to the maintainer. The repair is
always forward: a new version, a new candidate, and a new pass through this
document.

## Dependency and maintenance review

A manual review, run **before each release** and **approximately quarterly**
while the project is active. It is deliberately manual and issue-first:
automated version-update pull requests are not enabled, because they would cover
only part of this surface and would need an exception to the issue-first review
contract.

The review covers:

- **Direct Haskell dependency bounds.** Every direct dependency in
  `kanban.cabal`, checked for a bound that has gone stale against what actually
  builds.
- **`cabal outdated`.** Run it in the checkout and read every line it reports.
- **The pinned GHC and Cabal versions**, as the CI workflow pins them: whether
  the pin is still a supported toolchain, and what moving it would cost.
- **GitHub Actions major versions.** Every `uses:` in the workflows, checked for
  a major version that has been superseded or deprecated.
- **Supported-platform and security assumptions.** Whether the platforms the
  README's support matrix claims are still the platforms this is tested on, and
  whether anything in the dependency set has a published advisory.

Anything the review finds that needs changing becomes an ordinary issue and
travels the ordinary approval, solve, and pull-request lane. Nothing is changed
directly as part of the review.

A review that finds nothing still has a result, and that result is recorded:

- A **pre-release** review records its date and result on that release's issue,
  as step 5 says.
- An **off-cycle quarterly** review has no release issue to record on, so it gets
  its own: one `release`-labelled dependency-review issue, opened for that
  review, whose closing comment states the date the review was performed and its
  result. That issue is the durable record; it is not a Markdown file, and it is
  not a section of a document.
