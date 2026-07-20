#!/usr/bin/env bash
#
# Local mirror of the CI gate. `make ci` runs this; it executes the same
# checks .github/workflows/ci.yml runs, in the same order, so a green run
# here predicts a green remote run ("green locally => green in CI").
#
# Remote CI runs these on Linux (the official haskell:9.12.2 container);
# running this script on your Mac is the macOS coverage for this
# macOS-targeted tool. -Werror is already scoped to `package kanban` in
# the committed cabal.project, so it applies here automatically and does
# not leak into dependency builds — no cabal.project.local juggling.
#
# Uses your default build profile and the existing dist-newstyle, so it
# reuses a warm build instead of forcing a rebuild.
set -euo pipefail

# Run from the repo root regardless of caller CWD.
cd "$(dirname "$0")/.."

echo "==> [1/3] check package metadata"
cabal check

echo "==> [2/3] build + Haskell tests (-Werror on package kanban)"
cabal build all
cabal test all --test-show-details=direct

echo "==> [3/3] Python drainer, controller, and installer tests"
python3 -m unittest discover -s tools -p 'test_*.py'

echo "==> make ci: all gates passed"
