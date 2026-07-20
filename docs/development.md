# Development

## Build

```console
cabal update
cabal build all
```

## Local CI gate

Before pushing, run the same checks CI runs:

```console
make ci
```

This builds the library and executable with `-Werror`, runs the Haskell test
suite, and runs the Python drainer suite against your locally installed
toolchain — running it on your Mac is the macOS coverage for this
macOS-targeted tool. A green `make ci` predicts a green remote run; match CI's
compiler (GHC 9.12.2) for the closest prediction.

## Continuous integration

Remote CI runs on Linux in the official `haskell:9.12.2` container, so the
GHC/Cabal toolchain is baked into the image rather than installed on every run.
The required `build-test` check validates package metadata, builds the
application, and runs the Haskell test suite; the separate `drainer-tests` check
runs the Python drainer, controller, and installer suite. Pull requests also
require the `review-approved` check, which passes while the current pull request
carries `reviewed:approve`. A head change removes that label through the
review-gate workflow, requiring a fresh review.

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
