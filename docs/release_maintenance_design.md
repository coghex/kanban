# Repeatable public release maintenance design

Kanban's first public release proved that the repository could produce and
publish one complete source archive. The next release is 1.1.0.0: the public
package surface shipped in 1.0.0.0 has changed incompatibly, and this release
uses that major-version boundary to make the executable—not the implementation
library—the supported product (D-1, D-3). The release should prove something
different from 1.0.0.0: that publishing is now an ordinary maintainer operation, that a
stranger can understand the project's support boundaries, and that upgrading
from an earlier release is considered rather than rediscovered after
publication. This arc is also a deliberate practice ground for maintaining a
small public product without inventing obligations one maintainer cannot keep.

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Prepare and publish Kanban 1.1.0.0 through a repeatable release process — [#534]
- [x] RLM-1. Make the implementation library private and guard the package boundary — [#535]
- [ ] RLM-2. Establish the public maintainer, support, and conduct baseline
- [ ] RLM-3. Add human-facing issue intake without weakening agent specifications
- [ ] RLM-4. Document a supported release-to-release upgrade path
- [ ] RLM-5. Add the reusable release and maintenance runbook
- [ ] RLM-6. Verify installation from the exact candidate source archive
- [ ] RLM-7. Prepare the 1.1.0.0 release candidate

## Epic contract

- **Goal:** prepare and publish Kanban 1.1.0.0 through a documented,
  repeatable maintainer process while reducing the largest sources of
  uncertainty for a new user: how to install or upgrade it, what surface is
  supported, and where to get help or report a problem.
- **Done when:** all seven implementation slices are closed; the epic itself
  has recorded a clean candidate rehearsal, the supported 1.0.0.0-to-1.1.0.0
  upgrade, the pre-release dependency review, and the maintainer's final
  authorization; the annotated `v1.1.0.0` tag has caused the workflow to
  publish the sole verified source asset; the public description, topics,
  support routes, and issue intake are accurate; and the epic's final evidence
  comment records the release commit, workflow run, asset digest, and clean
  public download check before it closes.
- **Users and operators:** terminal-oriented GitHub users (install and
  operate); outside contributors and security reporters (evaluate and
  contact); Terry (release operator and sole maintainer).
- **Arc label:** existing `release`.
- **Release transaction:** the epic is also D-8's one version-specific release
  issue. Child pull requests close only their child issues; the epic remains
  open through final authorization, tag publication, public verification, and
  its compact evidence comment.

## Current state and evidence

### The first release is real and strongly verified

- `v1.0.0.0` and its GitHub Release were published on 2026-08-16. The release
  carries one asset, `kanban-1.0.0.0.tar.gz`, whose digest is recorded by
  GitHub and in `docs/design.md` section 21.
- `.github/workflows/release.yml` derives the version from `kanban.cabal`,
  requires an exact `v<version>` tag, takes release notes from the first
  versioned `CHANGELOG.md` section, runs the complete Haskell and Python gates,
  builds the real `cabal sdist`, records the archive and notes digests before
  the job boundary, and re-verifies them in the only job with publication
  authority.
- The same workflow has a draft-only rehearsal path. Its source-distribution
  gate verifies that the archive contains the setup tools, both provider
  bundles, tests, and packaged documentation rather than only the executable's
  Haskell sources.
- `docs/design.md` section 21 preserves the one-time REL-1 through REL-4
  evidence: installed performance, live provider usage, terminal exercise,
  tag publication, and a clean consumer download/build/install check.

### The second release already has substantial contents

- `kanban.cabal` and `kanban --version` still report `1.0.0.0`.
  `CHANGELOG.md` has an `Unreleased` section with thirteen user-visible entries.
- `master` is 541 commits beyond `v1.0.0.0` at the start of this design. The
  package gained several modules in `exposed-modules`, including approval,
  model-roster, managed-path, ping, repository-authority, and settings
  surfaces.
- The existing public API has also changed incompatibly. `Kanban.CLI` exports
  `Options (..)`; since 1.0.0.0, its public record constructor gained the
  `optionPing` field. Existing clients constructing the released record no
  longer compile unchanged. Under the PVP choice recorded by the first-release
  design, that is a major-version change: 1.0.1.0 is not policy-correct unless
  compatibility is restored. A 1.1.0.0 release is the direct versioning answer.

### Installation remains source-oriented

- The sole release asset is the complete Cabal source distribution. The README
  asks a user to install GHC and Cabal, download and unpack the archive, run
  `cabal update` and `cabal install exe:kanban`, and keep the extracted
  directory because the optional installers and workflow bundles live there.
- There is no binary bundle, Hackage upload, Homebrew formula or tap, platform
  installer, package checksum file, SBOM, or release provenance attestation.
  The workflow intentionally asserts that GitHub source release is the only
  distribution channel because that was the signed-off first-release scope.
- Workflow setup documents fresh installation, repair, removal, and stale
  plugin detection in detail. There is no short end-user upgrade path tying a
  new release archive, the executable, installed workflow bundles, managed
  backends, and background services into one version-to-version procedure.

### The supported product boundary was ambiguous at package level

- The README sells an executable product, but `kanban.cabal` has an unnamed
  main library exposing most `Kanban.*` modules. Cabal treats the unnamed main
  library as public; an executable-only package can instead use a private named
  sublibrary for code shared with its tests.
- This distinction matters before Hackage publication. Publishing the current
  package would make the exposed module list an installable public library API,
  while the project currently documents no supported Haskell API and changes
  those modules as implementation seams.
- The version policy says PVP, so the project either needs to compare and
  support that library API across releases or explicitly make it internal and
  version the executable product without implying otherwise. D-3 chooses the
  latter for 1.1.0.0.

### The public repository surface is mostly present but unfinished

- The repository is public and has a README, MIT license, contributing guide,
  security policy with private vulnerability reporting, issue templates, pull
  request template, protected `master`, and a published release. GitHub's
  community profile scores it at 85 percent.
- Repository metadata still describes it as `my kanban`, with no topics or
  homepage. GitHub's ordinary repository metadata query does not currently
  report a detected license even though the community-profile API recognizes
  the root `LICENSE` as MIT.
- The Cabal metadata names `coghex` as both author and maintainer without a
  contact address, while the MIT copyright line names `Terry`. D-5 resolves
  the public identity as Terry Coghlan with `vincecoghlan@gmail.com` as the
  maintainer contact.
- There is no code of conduct. A repository-wide search finds no conduct,
  respect, harassment, inclusion, moderation, or enforcement policy in
  `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, or the GitHub templates.
  `CONTRIBUTING.md` explains the issue-first workflow and review pipeline, but
  not interaction standards. D-6 therefore adds a local policy rather than
  duplicating text already in the README.
- `SECURITY.md` already makes the latest release the only supported one,
  promises no response deadline, and says fixes reach the next release rather
  than a backport branch. No broader document currently states whether that
  same best-effort/latest-only policy applies to ordinary support.
- The two issue templates are written for maintainers and agents. The ordinary
  template asks a reporter to supply repository evidence, numbered behavioral
  requirements, exact reviewer commands, and an explicit out-of-scope section;
  the epic template exposes the board's parsed child-checklist contract. Those
  are good specification forms after triage, but a high barrier for a stranger
  trying to report a bug, ask a question, or describe an idea.
- No dependency-update bot is configured. GitHub Dependabot can keep Actions
  references current, but it does not manage Cabal dependencies, and an
  unsolicited standalone bot pull request does not fit this repository's
  issue-first, approved-specification review path without a separate exception.
- The closed first-release epics #268 and #282 established readiness evidence
  and source-release packaging; this arc consumes rather than repeats them.
  Closed #434 created the current maintainer-oriented templates, and closed
  #459 created the security policy and private reporting route. `PROD-22` in
  `docs/product_readiness_findings.md` previously recorded no issue for a code
  of conduct while there was no outside community and no enforcement address;
  D-5 through D-7 deliberately supersede that conditional disposition now that
  the maintainer has supplied an address and chosen a public-maintenance
  baseline.
- A readiness check on 2026-08-26 found no open release, packaging, public-
  maintenance, support, conduct, issue-intake, or dependency epic. The open
  tracker contains unrelated UI, model-settings, multi-repository, portability,
  and agent-workflow arcs, so the proposed umbrella is not a duplicate.

## Desired experience

### For a user

A stranger can decide quickly whether Kanban suits them, install the supported
product without reverse-engineering the repository, and understand the
component-level platform matrix. When the next release appears they can tell what
changed, whether an existing configuration or installation needs attention,
how to upgrade, how to remove it, and where to report a bug or vulnerability.

### For the maintainer

A release begins with a bounded checklist rather than a historical design
archaeology pass. The maintainer chooses a version, curates the changelog,
rehearses the exact payload, verifies a clean install and one supported upgrade,
authorizes one tag push, watches the workflow, verifies the public result, and
records any recovery. The same runbook applies to 1.1.1.0 or 1.1.0.1 with only
the version and release-specific evidence changed.

The process should teach useful maintenance habits—compatibility review,
release notes, artifact verification, support boundaries, dependency upkeep,
and post-release follow-through—without adopting distribution channels or
service-level promises solely because large projects have them.

## Scope

### In scope

- The 1.1.0.0 version, changelog promotion, rehearsal, publication, and
  post-publication verification.
- A reusable release runbook, including authorization, failure recovery, and
  the evidence retained after publication.
- A clean-install and version-to-version upgrade story for every component the
  adopted distribution advertises.
- The executable-only public contract and the private implementation-library
  boundary selected by D-3.
- Accurate GitHub and Cabal metadata, support/contact routes, and an explicit
  decision about community interaction policy.
- The GitHub-source-only distribution selected for 1.1.0.0, plus a durable
  handoff into the easier-installation arc that follows it (D-2).
- Lightweight dependency and packaging upkeep appropriate to a sole
  maintainer.

### Out of scope unless a distribution decision brings it in

- A marketing site, telemetry, analytics, paid support, sponsorship, or a
  promised release calendar.
- Windows support.
- A public hosted service or any server-side Kanban component.
- Backport branches and simultaneous support for multiple release lines.
- Adopting every packaging ecosystem at once.

## Proposals

These are agent-authored directions, not decisions.

### P-1. Treat the next version as the repeatability release, not the everything release

Adopted for this arc by D-1 and D-2.

Use 1.1.0.0 unless the released Haskell API is restored to compatibility. Keep
the GitHub source archive as the only distribution channel for that release,
but make the second release prove the reusable maintainer loop: public metadata,
a release runbook, consumer installation, upgrade verification from 1.0.0.0,
changelog curation, and post-publication checks. Design easier installation as
a follow-up once the supported product boundary is explicit.

This is the smallest arc that keeps the existing PVP promise and teaches
release maintenance without turning one version into simultaneous Hackage,
Homebrew, binary-signing, and platform support projects.

### P-2. Support the executable and make the Haskell implementation library private

Adopted by D-3.

State that Kanban's supported public interface is the executable, documented
configuration, on-disk compatibility promises, installers, and workflow
contracts—not imports from `Kanban.*`. Convert the unnamed main library to a
private named sublibrary in the 1.1.0.0 release. That keeps the current test and
executable architecture while avoiding an accidental promise to stabilize
dozens of internal modules. Because 1.0.0.0 already exposed the unnamed
library, the conversion is itself a breaking package-API change and does not
fit in 1.0.1.0 under PVP.

If the project later wants a reusable Haskell API, expose a deliberately small
public library in its own design rather than inheriting the present module list.

### P-3. Add distribution channels one maintenance tail at a time

The recommended order after the repeatability release is:

1. Hackage, if the package boundary and maintainer identity are settled. It
   gives Haskell users `cabal install kanban` but still requires a toolchain;
   candidate uploads are the natural rehearsal because published package
   versions cannot be deleted.
2. A Homebrew tap or platform binary bundle only after Kanban decides where
   the optional tools and plugin assets live outside an extracted source tree.
   Installing only the executable would make the advertised optional product
   incomplete.
3. Build provenance or an SBOM after there are binary artifacts whose build
   origin is meaningfully harder to inspect than a source archive tied to a
   tag. GitHub supports Actions-generated artifact attestations for public
   repositories, so this does not need a custom signing system when the need
   arrives.

### P-4. Prefer a small, explicit public-maintenance baseline

Adopted across D-4 through D-7, D-10, and D-11.

For the next release, polish the repository description and topics; reconcile author,
maintainer, license, and contact identity; add an ordinary support route and
response-expectation statement; decide whether to adopt a code of conduct; and
make the issue templates distinguish external bug reports from internal epic
specifications. Do not add governance, funding, or ceremony without a present
user or maintainer need.

### P-5. Adopt Contributor Covenant 3.0 with a private conduct-report route

Adopted by D-7.

Use the English Contributor Covenant 3.0 generated by its official adoption
builder, including its standard scope and recommended consequence ladder.
Conduct reports go privately to `vincecoghlan@gmail.com`, never to a public
issue; that address is an enforcement route under this policy, not a response-
time promise or a replacement for GitHub's separate private vulnerability
reporting form.

This avoids inventing a one-off prohibited-behavior and enforcement policy,
while still requiring the maintainer to read and apply the adopted standard
rather than treating the file as a community-profile badge.

### P-6. Authorize every publication through one release issue

Adopted by D-8.

Generalize the first release's D-14 pattern rather than inventing a second
authority model. One version-specific release issue carries the checklist and
the maintainer's explicit final publication signoff. Once every required gate
is satisfied on the selected `master` commit, a solver agent creates and pushes
the annotated `v<version>` tag under that issue's authority; the release
workflow alone creates the GitHub Release.

After publication, the same issue receives one compact evidence comment naming
the commit, CI run, tag, release run, asset digest, and consumer verification,
then closes. `docs/releasing.md` owns the reusable process; version-specific
records stay with their tracker transaction instead of growing
`docs/design.md` or creating one permanent Markdown file per release. A failure
after the tag push remains stop-and-report: never delete, move, or recreate a
public release tag and never create the Release by hand.

### P-7. Combine automated artifact smoke tests with one manual supported-host upgrade

Adopted by D-9.

The release rehearsal should automatically unpack the candidate sdist in a
clean directory, build and install the executable from that unpacked artifact,
and verify `kanban --version`. This catches packaging defects in the thing a
consumer receives rather than only in the checkout that produced it.

Before the tag is authorized, the release issue should also record one manual
macOS upgrade from the published 1.0.0.0 installation to the candidate: update
the executable, repair or upgrade the optional workflow assets and managed
components through their supported commands, run `--doctor`, and exercise the
board without losing supported configuration or durable state. Real provider
accounts, launchd, and an interactive terminal make that an operator gate
rather than fake CI. After publication, a clean consumer downloads the public
asset and repeats the core build/install/version check.

### P-8. Describe the product plainly and use a small discovery vocabulary

Adopted by D-10.

Use this GitHub repository description:

> A keyboard-driven terminal board for GitHub issues, pull requests, and agent
> workflows.

Set the topics to `haskell`, `terminal`, `tui`, `kanban`, `github`,
`developer-tools`, `ai-agents`, and `brick`. Leave the homepage field empty
until the project has a real site or durable external landing page; the README
is currently the correct product entry point. The description matches the
README's primary board experience while acknowledging the optional agent work
without making Codex or Claude a prerequisite. The topic set is deliberately
small enough to stay accurate rather than acting as a keyword catalogue.

### P-9. Add human intake templates without weakening the internal issue contract

Adopted by D-11.

Add three public Markdown templates: **Bug report**, **Feature or improvement**,
and **Support question**. Each uses short, plain-language prompts but emits the
same five headings the agent pipeline expects: Background, Requirements,
Acceptance, Out of scope, and Related. Prompts may tell a reporter that
maintainer-only fields can be left blank; intake is not expected to arrive as
an approved implementation specification.

Retain the current ordinary and epic templates, but rename their chooser labels
to **Maintainer issue specification** and **Maintainer epic** so an outside
reporter is not led into them. Add the issue-chooser configuration, disable
unstructured blank issues, and provide a contact link to GitHub's private
security-advisory form. Keep ordinary support in public issues under D-4 rather
than introducing Discussions or an email support queue in this release.

Markdown templates are preferable here to GitHub issue forms: they are stable,
reviewable files, preserve the exact headings the existing workflows consume,
and avoid making the release depend on an issue-forms feature GitHub still
documents as public preview.

### P-10. Make dependency review periodic and issue-first; do not enable Dependabot yet

Adopted by D-12.

Add a lightweight maintenance checklist to the runbook and perform it before
1.1.0.0, before each later release, and approximately quarterly while the
project is active. It inventories direct Haskell version bounds, runs `cabal
outdated`, checks the pinned GHC and Cabal versions, reviews GitHub Actions major
versions, and checks whether supported platform assumptions or security notices
require work. Each real change enters the normal issue, approval, solve, and PR
lane; a clean review records only its date and result.

Do not add Dependabot version-update pull requests in this arc. Its available
GitHub Actions updater would cover only part of the dependency surface, while
its standalone PRs would need a bot-specific exception to the repository's
issue-first and canonical review contracts. Revisit grouped automated updates
when manual reviews are demonstrably being missed or when a later pipeline
design gives dependency bots a first-class, equally reviewed route.

## Decisions

### D-1. The next release is 1.1.0.0

User signoff 2026-08-26. Kanban 1.0.0.0 shipped an unnamed public Cabal
library, and its exported API has since changed incompatibly: at minimum,
`Kanban.CLI.Options (..)` gained a constructor field. The release therefore
increments the PVP major version from 1.0 to 1.1 rather than presenting the
change as the compatible minor release 1.0.1.0.

Consequence: the Cabal version, CLI version, changelog heading, tag, release
name, archive name, upgrade verification, and public documentation all name
1.1.0.0. Restoring the accidental library API solely to retain 1.0.1.0 and
abandoning the recorded PVP policy were rejected.

### D-2. Version 1.1.0.0 remains a GitHub source release, and easier installation is next

User signoff 2026-08-26. The complete verified `cabal sdist` stays the only
distribution channel for 1.1.0.0. Hackage, Homebrew, and prebuilt binary
bundles do not join this release's critical path. The release instead proves
the repeatable maintenance loop around the channel already delivered and
verified by 1.0.0.0.

This is a sequencing decision, not a rejection of easier installation. The
next product arc after 1.1.0.0 is explicitly the easier-distribution work. It
will choose and own its first additional channel after D-3 has given it a clear
package boundary; P-3's Hackage-first ordering remains a proposal for that
future design rather than a decision silently made here.

### D-3. The executable is the supported product and the implementation library becomes private

User signoff 2026-08-26. Kanban's supported public interfaces are the
executable and CLI, documented configuration, supported on-disk compatibility,
installers, and workflow contracts. Importing `Kanban.*` modules is not a
supported product surface.

The unnamed main library becomes a private named sublibrary in 1.1.0.0. The
executable and tests continue sharing that component, but another package
cannot depend on it as a public Kanban library. The 1.1 major-version boundary
owns the removal of the library exposed by 1.0.0.0. Any future reusable Haskell
API must be designed as a deliberately small public component rather than
promoting the current implementation seams by default.

### D-4. Ordinary support is latest-release-only and best effort

User signoff 2026-08-26. Ordinary support follows the sustainable promise
already made by `SECURITY.md`: only the latest release is supported, responses
and release timing are best effort, no response time or release cadence is
promised, and fixes are not backported to older release lines.

Public issues are the route for bugs, support questions, and feature requests;
GitHub's private vulnerability-reporting form remains the route for security
reports. Documentation must make those routes and expectations easy to find
without implying paid support, a service-level objective, or guaranteed
acceptance of a contribution.

### D-5. Public maintainer identity is Terry Coghlan

User signoff 2026-08-26. Public package and license metadata use `Terry
Coghlan`; the durable maintainer contact is `vincecoghlan@gmail.com`. The Cabal
`author` and `maintainer` fields, the MIT copyright line, and any package-index
metadata added by the later distribution arc use that identity consistently.

Repository ownership remains `coghex/kanban`, and security disclosure remains
the private GitHub advisory route rather than ordinary email. Publishing the
email as package-maintainer metadata does not turn it into a promised support
channel under D-4.

### D-6. Kanban carries a local code of conduct

User signoff 2026-08-26. A root `CODE_OF_CONDUCT.md` will state the interaction
and enforcement standard for issues, pull requests, and other project spaces.
`CONTRIBUTING.md` links to it rather than copying it, and the public
documentation index makes it discoverable. The existing README and
contribution guide contain no conduct policy to preserve or consolidate.

D-7 supplies the adopted standard and enforcement wording. The file must enter
the source distribution and the repository's Markdown classification in the
same implementation slice, so the public release and documentation gates
remain complete.

### D-7. Adopt Contributor Covenant 3.0 and its recommended enforcement ladder

User signoff 2026-08-26. `CODE_OF_CONDUCT.md` uses the English Contributor
Covenant 3.0 produced by the official adoption builder, including its standard
scope and recommended consequence ladder. Conduct reports go privately to
`vincecoghlan@gmail.com`, never to a public issue.

That address is an enforcement route for project-space conduct, not a response-
time promise, an ordinary support channel, or a substitute for GitHub's private
vulnerability-reporting form. A bespoke policy was rejected because it would
make one maintainer independently define and maintain the behavior, scope,
enforcement, and appeals framework the adopted standard already supplies.

### D-8. A version-specific release issue authorizes an agent-pushed tag

User signoff 2026-08-26. Every release has one version-specific issue carrying
the checklist and the maintainer's explicit final publication signoff. Once
the selected `master` commit has every required gate, a solver agent may create
and push exactly one annotated `v<version>` tag under that issue's authority.
The release workflow remains the only actor that creates the GitHub Release.

`docs/releasing.md` owns the reusable process. After publication, the release
issue receives one evidence comment naming the commit, CI run, tag, release
run, asset digest, and consumer verification, then closes. Release-specific
records no longer grow `docs/design.md` or create a permanent Markdown file per
version. If anything fails after the tag push, the operator reports and stops:
no tag deletion, move, reuse, or force-push, and no hand-created Release.

### D-9. Automate the candidate install and retain one manual supported-host upgrade

User signoff 2026-08-26. The release rehearsal automatically unpacks the
candidate sdist in a clean directory, builds and installs the executable from
that artifact, and verifies `kanban --version`. Before final tag authorization,
the release issue also records one manual macOS upgrade from the published
1.0.0.0 installation to the candidate, covering the executable, optional
workflow assets, managed components, `--doctor`, an interactive board run, and
preservation of supported configuration and durable state.

After publication, a clean consumer downloads the public asset and repeats the
core build/install/version check. Real provider accounts, launchd, and terminal
behavior stay manual; the first release's full performance and live-usage
campaign does not repeat for every release unless a later change gives a
specific reason to rerun it.

### D-10. Use plain GitHub metadata and no placeholder homepage

User signoff 2026-08-26. The repository description is “A keyboard-driven
terminal board for GitHub issues, pull requests, and agent workflows.” Its
topics are `haskell`, `terminal`, `tui`, `kanban`, `github`,
`developer-tools`, `ai-agents`, and `brick`. The homepage remains empty until
the project has a real site or durable external landing page; the repository
README is the current product entry point.

This wording leads with the board, acknowledges the optional agent layer, and
does not imply Codex or Claude is required. Vendor-specific and speculative
discovery keywords were rejected in favor of a small set the product actually
owns.

### D-11. Offer three human-facing Markdown issue templates

User signoff 2026-08-26. GitHub's issue chooser offers Bug report, Feature or
improvement, and Support question templates with short plain-language prompts.
Their output retains Background, Requirements, Acceptance, Out of scope, and
Related in that order so an intake issue can be refined into the existing
agent specification without a structural rewrite. Prompts may leave
maintainer-only fields blank; an outside reporter is not expected to arrive
with reviewer commands or a final implementation contract.

The present templates remain available as Maintainer issue specification and
Maintainer epic. Blank external intake is disabled, and the chooser links
security reporters to GitHub's private advisory form. Markdown was chosen over
preview-status issue forms because it preserves exact workflow-consumed
headings in stable tracked files.

### D-12. Review dependencies manually before releases and approximately quarterly

User signoff 2026-08-26. The reusable maintenance checklist inventories direct
Haskell bounds, runs `cabal outdated`, reviews the pinned GHC and Cabal
versions, checks GitHub Actions major versions, and reevaluates supported-
platform and security assumptions. It runs before 1.1.0.0, before each later
release, and approximately quarterly while the project is active. A real
change enters the ordinary issue, approval, solve, and pull-request lane; a
clean review records its date and result.

Dependabot version-update pull requests are not enabled in this arc. Its
GitHub Actions updater covers only part of the dependency surface and its
standalone bot PRs would require an exception to the issue-first review
contract. Automation can be redesigned later if manual reviews are actually
missed or the pipeline gains a first-class bot route with equal review.

## Open questions

### Q-6. Should the proposed 1.0.1.0 release become 1.1.0.0?

Resolved by D-1.

### Q-1. Is easier installation a blocker for the next release?

Resolved by D-2. Easier installation is the next planned product arc, not a
blocker for 1.1.0.0.

### Q-2. Is the supported public product the executable rather than a Haskell library API?

Resolved by D-3.

### Q-3. What ordinary support promise should a sole maintainer make?

Resolved by D-4.

### Q-4. Which public maintainer identity and contact should package metadata use?

Resolved by D-5.

### Q-5. Should interaction standards be local to this repository?

Resolved by D-6.

### Q-7. Which code-of-conduct standard and enforcement wording should Kanban adopt?

Resolved by D-7.

### Q-8. Should every release use a version-specific authorization issue and agent-pushed tag?

Resolved by D-8.

### Q-9. Which release verification remains manual?

Resolved by D-9.

### Q-10. What exact description and topics should the public repository use?

Resolved by D-10.

### Q-11. How should an outside user open a useful issue?

Resolved by D-11.

### Q-12. What dependency-maintenance cadence fits this project?

Resolved by D-12.

## Verification strategy

The existing release workflow and its Python contract tests remain the base.
The completed design should add only the evidence required by its adopted
surface:

- a clean consumer download, unpack, build, install, and `--version` check from
  the rehearsed next-release artifact;
- an upgrade exercise beginning with the published 1.0.0.0 archive and ending
  with the next-version executable and each advertised optional component current,
  without losing supported configuration or durable state;
- a package-boundary check that fails if a supposedly executable-only release
  exposes an accidental public library, or an API-diff review if the library
  remains public;
- link and metadata checks over the public install, support, security, and
  contribution routes;
- chooser-contract checks that render or inspect every public and maintainer
  issue template, preserve the five standard headings and unmarked human
  provenance, and confirm the private-security contact target;
- a recorded pre-release dependency review covering Cabal bounds, the pinned
  toolchain, workflow action majors, supported-platform assumptions, and any
  security notices, with ordinary linked issues for changes that must block the
  release;
- repository-state checks that the public description and topics equal D-10,
  the homepage is empty, and GitHub detects the expected community-health
  files;
- no Hackage, Homebrew, binary-signing, provenance, or SBOM gate in this arc;
  the later distribution design owns the checks for whichever channel it
  actually adopts;
- one post-publication consumer verification against the public release URL,
  recorded in a compact release record rather than appended to the historical
  first-release evidence chapter.

## Delivery plan

The epic is the version-specific release transaction required by D-8. The
seven child slices below each fit one issue and one reviewable pull request.
Once they are closed, the epic—not another child—owns the operator-only gates,
the user's final authorization, the single annotated tag push, the workflow
result, the public consumer check, and the closing evidence comment.

### RLM-1. Make the implementation library private and guard the package boundary

- **Outcome:** Kanban 1.1 exposes the executable product without advertising
  the implementation modules as a public Cabal library.
- **Scope:** convert the unnamed main library to a private named sublibrary;
  keep the executable and test suite depending on it; add a package-boundary
  regression that examines a real package or source distribution rather than
  trusting only the stanza spelling.
- **Phase:** 1 — package contract
- **Depends on:** `none`
- **Ordering:** `can land first`
- **Relevant decisions:** D-1, D-3
- **Acceptance signals:** `cabal check`, the warning-clean build, and the full
  Haskell suite pass; the executable and tests still link; an outside package
  cannot depend on a public `kanban` library; the real sdist retains everything
  needed to build and test Kanban itself.
- **Out of scope:** designing a future public Haskell API, changing runtime
  behavior, or bumping the release version before the candidate slice.
- **Open questions:** None.

### RLM-2. Establish the public maintainer, support, and conduct baseline

- **Outcome:** the packaged project consistently names its maintainer and gives
  users separate, sustainable routes for ordinary support, security, and
  conduct reports.
- **Scope:** align Cabal author/maintainer metadata and the MIT copyright line
  to Terry Coghlan; add root `SUPPORT.md` and Contributor Covenant 3.0
  `CODE_OF_CONDUCT.md`; link them from the README, contribution guide, and
  documentation index; classify and include the release documents in the
  source archive; update the inventory tests and their whole-file prose.
- **Phase:** 2 — public baseline
- **Depends on:** RLM-1
- **Ordering:** `critical path`
- **Relevant decisions:** D-4, D-5, D-6, D-7
- **Acceptance signals:** the source archive contains the exact policies and
  package identity; public issues, private vulnerability reporting, and private
  conduct email are not conflated; the support text promises latest-release-
  only best effort with no response or cadence guarantee; document-
  classification, source-distribution, and package checks pass.
- **Out of scope:** changing security handling, promising email support, adding
  governance or funding, or modifying the live GitHub description and topics,
  which the epic applies and verifies under D-10.
- **Open questions:** None.

### RLM-3. Add human-facing issue intake without weakening agent specifications

- **Outcome:** a stranger can report a bug, request an improvement, or ask for
  support without being asked to write an agent-ready implementation contract.
- **Scope:** add the three D-11 Markdown templates; rename the existing chooser
  entries to Maintainer issue specification and Maintainer epic; add chooser
  configuration that disables blank intake and links private security reports;
  add regression coverage for headings, origin-marker absence, epic parser
  requirements, labels, and contact targets.
- **Phase:** 3A — public intake
- **Depends on:** RLM-2
- **Ordering:** `required parallel branch`
- **Relevant decisions:** D-4, D-11
- **Acceptance signals:** GitHub's chooser exposes the intended five entries
  with no misleading default; each human template retains the five standard
  headings in order and no agent-origin marker; the maintainer epic still
  carries the parsed child checklist; security reporters are routed privately;
  the Python contract suite passes.
- **Out of scope:** GitHub Discussions, issue-form YAML, automatic triage or
  approval, changing legacy dual-review provenance, or changing the issue body
  parser.
- **Open questions:** None.

### RLM-4. Document a supported release-to-release upgrade path

- **Outcome:** a 1.0.0.0 user can upgrade the executable and whichever optional
  components they installed without guessing which old extracted archive still
  owns them or discarding supported state.
- **Scope:** add version-neutral upgrade instructions to the public install and
  workflow documentation; cover downloading and retaining the new release
  archive, installing the executable, applying workflow-bundle and managed-
  component repairs from that archive, running `--doctor`, verifying the
  version, preserving supported configuration and durable state, and using the
  existing removal paths when a component is no longer wanted.
- **Phase:** 3B — user lifecycle
- **Depends on:** RLM-2
- **Ordering:** `critical path`
- **Relevant decisions:** D-2, D-3, D-4, D-9
- **Acceptance signals:** every advertised component has explicit install,
  upgrade/repair, verification, and removal guidance; README wording remains
  truthful both immediately before and after a release; packaged relative
  links and command paths resolve from an unpacked sdist; documentation and
  source-distribution tests pass.
- **Out of scope:** a new package manager, automatic in-app updater, migration
  of unsupported private files, Windows support, or claiming Linux evidence
  beyond the existing component matrix.
- **Open questions:** None.

### RLM-5. Add the reusable release and maintenance runbook

- **Outcome:** a future maintainer can drive a release from one version-
  specific issue without reconstructing the first-release design history.
- **Scope:** add packaged `docs/releasing.md` and a Maintainer release issue
  template; specify version/PVP and compatibility review, changelog promotion,
  candidate selection, CI and draft rehearsal, D-12's dependency check, D-9's
  manual upgrade, D-10's repository-setting check, final human authorization,
  the single annotated tag push, workflow observation, immutable-tag failure
  response, public verification, evidence comment, and closure; classify and
  inventory the new files with regression coverage for the safety-critical
  rules.
- **Phase:** 4 — operator lifecycle
- **Depends on:** RLM-4
- **Ordering:** `critical path`
- **Relevant decisions:** D-1, D-2, D-4, D-8, D-9, D-10, D-12
- **Acceptance signals:** the runbook separates reusable procedure from
  version-specific evidence; the template cannot authorize publication without
  explicit maintainer signoff; post-tag failure instructions forbid deletion,
  movement, reuse, force-push, or hand publication; the runbook and all links
  ship in the sdist; contract and packaging tests pass.
- **Out of scope:** automating the tag decision, storing one permanent Markdown
  record per release, promising a release calendar, or adding a package-
  registry process.
- **Open questions:** None.

### RLM-6. Verify installation from the exact candidate source archive

- **Outcome:** both dry-run and real release paths fail before publication if
  the source archive cannot build, install, and report the intended version as
  an isolated consumer receives it.
- **Scope:** extend the release build job to extract its one named sdist into a
  clean temporary directory, build and install `exe:kanban` from that unpacked
  tree into an isolated destination, execute that binary's `--version`, and
  hold the behavior with release-workflow tests that distinguish the archive
  from the checkout.
- **Phase:** 5 — automated candidate gate
- **Depends on:** RLM-5
- **Ordering:** `critical path`
- **Relevant decisions:** D-2, D-3, D-9
- **Acceptance signals:** the gate runs against the same digest-recorded archive
  later handed to the publisher; a missing, malformed, unbuildable, or wrong-
  version archive blocks both rehearsal and publication; existing release
  authority boundaries stay intact; the Haskell and Python release suites pass.
- **Out of scope:** installing optional provider bundles in CI, real provider
  calls, launchd/systemd exercises, interactive terminal verification, or
  post-publication network checks.
- **Open questions:** None.

### RLM-7. Prepare the 1.1.0.0 release candidate

- **Outcome:** `master` contains one internally consistent, releasable 1.1.0.0
  candidate whose only remaining work is the epic's recorded operator gates and
  publication transaction.
- **Scope:** bump Cabal and CLI versions to 1.1.0.0; promote the curated
  Unreleased notes to the exact release heading and open a fresh empty
  Unreleased section; review every change since `v1.0.0.0` for user-visible
  notes, compatibility, upgrade implications, and stale version-specific
  documentation; run the complete release-candidate gates.
- **Phase:** 6 — release candidate
- **Depends on:** RLM-3, RLM-6
- **Ordering:** `critical path`
- **Relevant decisions:** D-1, D-2, D-3, D-8, D-9, D-12
- **Acceptance signals:** version consistency, changelog extraction, package
  boundary, full Haskell and Python suites, and real sdist checks pass on the
  selected `master` commit; no document claims 1.1.0.0 is already published;
  the epic can name the exact commit and proceed to its dependency review,
  draft rehearsal, manual 1.0.0.0 upgrade, final signoff, tag, workflow, and
  public-download checks.
- **Out of scope:** pushing `v1.1.0.0`, creating the GitHub Release by hand,
  adding Hackage/Homebrew/binary distribution, or starting the easier-
  distribution follow-up arc.
- **Open questions:** None.

## Source notes

> **Source note:** "I want to get it all ready for a 1.0.1.0 release. What
> other packaging should I do to get this into a public facing product? It's
> not a big product, but I'm trying to learn what it takes to maintain a
> released product, so that I can get used to the process."

External references consulted for the recommendations:

- [GitHub repository topics](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/classifying-your-repository-with-topics)
  for topic format and discovery behavior.
- [GitHub issue-template configuration](https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/configuring-issue-templates-for-your-repository)
  for chooser configuration, contact links, and issue forms' preview status.
- [GitHub Dependabot version updates](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/configuring-dependabot-version-updates?learn=dependency_version_updates&learnProduct=code-security)
  for supported update ecosystems and GitHub Actions configuration.
