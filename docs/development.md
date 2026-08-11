# Development

## Build

```console
cabal update
cabal build all
```

CI uses GHC 9.12.2 and Cabal 3.16.1.0 on Linux. The required
`build-test` check validates package metadata, builds the application, and runs
both test suites. Pull requests also require the `review-approved` check, which
passes while the current pull request carries `reviewed:approve`. A head change
removes that label through the review-gate workflow, requiring a fresh review.
The single exception is a push the workflow can prove touches none of the pull
request's own files — a base-branch update merged forward — which changes only
the branch's ancestry and so keeps the label. Anything it cannot prove
content-free that way, including any failure to establish either file list,
removes the label as before.

## Test

Run the Haskell suite:

```console
cabal test all --test-show-details=direct
```

Run the Python drainer, controller, and installer suite:

```console
python3 -m unittest discover -s tools -p 'test_*.py'
```

The Python tests use temporary repositories and fake command-line tools. They do not contact GitHub or modify the user's LaunchAgents. The one exception is the source-release check below, which runs the real `cabal` against this checkout; it still writes only to a temporary directory.

The Haskell suite includes the golden-frame tests, which compare rendered
terminal frames with the files checked in under `test/golden/`. A normal run
only ever reads them. After a deliberate rendering change, rewrite them with
the explicit switch and read the resulting diff before committing it:

```console
KANBAN_UPDATE_GOLDENS=1 cabal test kanban-test
```

## Source release

The source distribution is meant to be a complete Kanban checkout, so that
everything the packaged documentation advertises — the workflow setup command,
the drainer installer, both provider bundles, and the test suites — is present
after unpacking. Verify it with:

```console
cabal sdist all
python3 -m unittest tools.test_source_distribution
```

That check builds the real archive into a temporary directory, unpacks it, and
compares the result against the repository's tracked file set. Adding a tracked
file under `app/`, `src/`, `test/`, `tools/`, `codex-plugin/`, or
`claude-plugin/` requires no manifest change only when an existing
`kanban.cabal` glob already covers its extension; anything else — a new
top-level file, a new document under `docs/`, a new file extension — fails the
check until `kanban.cabal` declares it and `tools/test_source_distribution.py`
records whether it belongs in a release. It runs in the required `build-test`
job as part of the Python suite, and skips with a reason where `cabal` or the
Git metadata is unavailable, such as inside an unpacked release.

## Source layout

- `app/` — executable entry point.
- `src/Kanban/` — board, GitHub, terminal interface, worker, review, and settings code.
- `test/` — Haskell tests.
- `tools/` — PR drainer, controller, installers, workflow setup, and Python tests.
- `codex-plugin/`, `claude-plugin/` — the tracked workflow bundles Kanban's AI actions invoke by name.
- `.github/workflows/` — continuous integration.

## Further detail

See [design.md](design.md) for the complete behavior contract, architecture notes, and implementation history, and [workflow-setup.md](workflow-setup.md) for installing and diagnosing the optional AI-action components.
