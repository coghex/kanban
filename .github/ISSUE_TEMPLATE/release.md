---
name: Maintainer release
about: The version-specific checklist and publication authorization for one release
title: ''
labels: release
assignees: ''
---

<!--
One issue per release. This issue is the release's only tracker artifact: it
carries the checklist below, the maintainer's explicit publication
authorization, and — after publication — the single evidence comment that is
the permanent record. No per-release Markdown file is created and no tracked
document grows.

The procedure lives in docs/releasing.md and is not repeated here. Each item
below names a step of that document; read the step before checking its item.

Leave the origin marker off, for the reason the ordinary issue template gives.

Opening this issue is the decision that a release should happen, and it is the
maintainer's alone. Checking the authorization item is a second, separate
decision, made only after the comment that item names exists.
-->

## Background

Which release this is, and why it is being cut now — what has merged since the
previous release that a user would want.

Version: `<version>`

## Requirements

1. Every gate `docs/releasing.md` names passes on one exact `master` commit, and
   is recorded here against that commit.
2. The release is published by the release workflow from one annotated
   `v<version>` tag pushed under this issue's authorization, and by nothing
   else.
3. This issue carries the release's evidence and then closes.

### Checklist

Check an item only once its step's result is recorded here.

- [ ] 1. Version chosen and its PVP component justified.
- [ ] 2. `### Unreleased` promoted to `## <version>`, and a fresh empty
      `### Unreleased` created above it.
- [ ] 3. Candidate commit selected, with required `build-test` success on that
      exact commit.
- [ ] 4. Rehearsal dispatched on the candidate, its run's head confirmed to
      be that commit; draft created and kept for item 6.
- [ ] 5. Dependency and maintenance review performed; date and result recorded.
- [ ] 6. Manual macOS upgrade performed, from the previous published release
      onto the candidate archive kept from item 4; each covered item's result
      recorded; the draft then deleted.
- [ ] 7. Repository description, topics, and empty homepage checked.
- [ ] 8. **Publication authorized.** Check this only after the maintainer has
      commented `Authorized: publish <version> from <commit>.` on this issue,
      and record that comment's URL beside this item. Nothing else authorizes
      publication, and no agent may check this item.
- [ ] 9. One annotated `v<version>` tag created on the authorized commit and
      pushed.
- [ ] 10. Release workflow run observed: `build-test` and `publish-release`
      succeeded, `publish-dry-run` skipped.
- [ ] 11. Published release verified from a clean consumer download.
- [ ] 12. Evidence comment added, naming the commit, CI run, tag, release run,
      asset digest, and consumer verification.

## Acceptance

    # from a clean checkout at the candidate commit
    cabal build all && cabal test all --test-show-details=direct
    python3 -m unittest discover -s tools -p 'test_*.py'

The published release is public, is not a draft or prerelease, carries exactly
one asset, and the asset's digest matches the one the release run recorded.

## Out of scope

- Anything that changes the procedure itself. `docs/releasing.md` is edited
  through the ordinary pull-request lane, not from this issue.
- Any repair that deletes, moves, reuses, or force-pushes the tag once it is
  pushed, or that creates the GitHub Release by hand. If something fails after
  the tag push, report it here and stop.

## Related

- `docs/releasing.md` — the procedure every item above names.
- The previous release's issue, for the version this one upgrades from.
