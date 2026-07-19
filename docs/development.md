# Development

## Build

```console
cabal update
cabal build all
```

CI uses GHC 9.12.2 and Cabal 3.16.1.0 on macOS. The required
`build-test` check validates package metadata, builds the application, and runs
both test suites. Pull requests also require the `review-approved` check, which
passes while the current pull request carries `reviewed:approve`. A head change
removes that label through the review-gate workflow, requiring a fresh review.

## Test

Run the Haskell suite:

```console
cabal test all --test-show-details=direct
```

Run the Python drainer, controller, and installer suite:

```console
python3 -m unittest discover -s tools -p 'test_*.py'
```

The Python tests use temporary repositories and fake command-line tools. They do not contact GitHub or modify the user's LaunchAgents.

## Source layout

- `app/` — executable entry point.
- `src/Kanban/` — board, GitHub, terminal interface, worker, review, and settings code.
- `test/` — Haskell tests.
- `tools/` — PR drainer, controller, installer, and Python tests.
- `.github/workflows/` — continuous integration.

## Further detail

See [design.md](design.md) for the complete behavior contract, architecture notes, and implementation history.
