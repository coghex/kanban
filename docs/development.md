# Development

## Build

```console
cabal update
cabal build all
```

CI uses GHC 9.12.2 and Cabal 3.16.1.0 on Linux. `.github/workflows/ci.yml` runs
the Haskell work and the `tools/` suite as independent jobs that overlap,
alongside the container-verified drainer lifecycle. The `tools/` job installs no
Haskell toolchain: nothing in that suite needs one except the source
distribution check below, which runs in the Haskell job.

That compiler is restored from a cache rather than installed. ghcup is pointed
at a `~/.ghcup` the job owns outright, that directory is what the cache covers,
and the key names the runner, both pinned versions, and the installation
layout — never a source file, since the compiler does not change when a module
does. There are deliberately no fallback keys: a prefix match would be a tree
built for some other pin, and a miss reinstalls, which is slower and still
correct. The job then executes `ghc` and `cabal` and requires them to report the
pins before anything builds, so a restore that lost an executable bit or a
symlink fails there rather than quietly building with something else.

`.github/workflows/release.yml`'s `build-test` job resolves the toolchain the
same way, and has to: a release built by a different compiler than CI verified
is invisible in either workflow read on its own.
`tools/test_toolchain_parity.py` compares the two to each other rather than to a
literal, so bumping the pin in one of them alone fails.

The required `build-test` check is the aggregate over all of them. It runs no
build or test step of its own and succeeds only when every other job in the
workflow succeeded, failing explicitly when one did not — a dependency failure
merely *skips* a dependent job, and nothing that reads this check treats a skip
as a refusal. A job added to `ci.yml` that `build-test` does not depend on fails
`tools/test_ci_workflow.py`.

Pull requests also require the `review-approved` check, which passes while the
current pull request carries `reviewed:approve`. A head change removes that
label through the review-gate workflow, requiring a fresh review. The single
exception is a push the workflow can prove touches none of the pull request's
own files — a base-branch update merged forward — which changes only the
branch's ancestry and so keeps the label. Anything it cannot prove
content-free that way, including any failure to establish either file list,
removes the label as before. A removal the workflow cannot confirm actually
happened fails the job rather than reporting a decision the label does not
reflect.

## Test

Run the Haskell suite:

```console
cabal test all --test-show-details=direct
```

Run the Python drainer, controller, and installer suite:

```console
python3 -m unittest discover -s tools -p 'test_*.py'
```

The Python tests use temporary repositories and fake command-line tools. They do not contact GitHub or modify the user's LaunchAgents or systemd user units. The one exception is the source-release check below, which runs the real `cabal` against this checkout; it still writes only to a temporary directory.

The Haskell suite includes the golden-frame tests, which compare rendered
terminal frames with the files checked in under `test/golden/`. A normal run
only ever reads them. After a deliberate rendering change, rewrite them with
the explicit switch and read the resulting diff before committing it:

```console
KANBAN_UPDATE_GOLDENS=1 cabal test kanban-test
```

## Changing the version

The package version is written twice: `kanban.cabal`'s `version:` field and the
hard-coded `infoOption "kanban <version>"` literal in `src/Kanban/CLI.hs`.
`tools/test_version_consistency.py` fails when they disagree, so a bump has to
change both in the same commit. It pins the literal's shape as well as its
digits — rewording or splitting the string fails the check rather than passing
it unchecked — and it fails closed when either literal cannot be read at all.
Deduplicating the two into one source is deliberately not done yet.

Record the release under a `##` heading in `CHANGELOG.md` whose text is exactly
the new version. That heading is the section boundary the release notes are
extracted by, so nothing else delimits a release.

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
records whether it belongs in a release. It runs in `ci.yml`'s Haskell job,
which is where the toolchain it drives is installed, and that step fails when
the check reports a skip rather than a result. It skips with a reason where
`cabal` or the Git metadata is unavailable — inside an unpacked release, and in
the toolchain-free job that runs the rest of the Python suite.

## Changing a workflow bundle

A change that touches tracked content under `claude-plugin/` or `codex-plugin/`
must raise that bundle's declared manifest version in the same change, and must
leave the manifest still naming exactly the workflows the bundle ships.
`tools/test_claude_plugin.py` and `tools/test_codex_plugin.py` enforce both
through `tools/plugin_bundle_gate.py`, so both fail in the required
`build-test` job rather than after the fact.

- **Version.** Bump `codex-plugin/plugins/kanban/.codex-plugin/plugin.json`, or
  — for Claude, which declares its version twice — both
  `claude-plugin/plugins/kanban/.claude-plugin/plugin.json` and the plugin
  entry in `claude-plugin/.claude-plugin/marketplace.json`, which must agree.
  Codex caches a local-source bundle under exactly that version
  (`$CODEX_HOME/plugins/cache/kanban/kanban/<version>/`), so an unchanged
  version makes a stale cache indistinguishable from a current one.
- **Listing.** Add the workflow to every manifest field that enumerates them:
  the description on the Claude side (in both manifests), and the description,
  keywords, `interface.shortDescription`, `interface.longDescription`, and
  `interface.defaultPrompt` on the Codex side.

The change unit is one pull request: the candidate tracked tree compared with
its default-branch merge base, counting committed, staged, and tracked
working-tree edits and ignoring untracked files. `.github/workflows/ci.yml`
therefore checks out with `fetch-depth: 0`; without that baseline the check
fails rather than passing unenforced.

## Rendering a shared command source

Some workflow commands are authored once and rendered into both bundle
layouts, instead of being maintained as two hand-edited copies that drift.
`tools/render_command_sources.py` holds the registry and the transformation:

```console
python3 tools/render_command_sources.py            # write both files
python3 tools/render_command_sources.py --check    # report stale ones
```

An authored source lives under `tools/command_sources/` and carries the union
of both brands' frontmatter. It names a workflow with a `cmd` directive rather
than a literal `/name` or `$name`, so each brand's file gets its own sigil, and
it keeps deliberate per-brand body text inside a
`<!-- brand:claude -->` / `<!-- brand:codex -->` / `<!-- /brand -->` block.
Rendering refuses a literal sigil written where a directive belongs.

After editing a source, re-render and commit both generated files.
`tools/test_render_command_sources.py` re-renders every registered source and
byte-compares it against the tracked output, so a source changed without a
re-render fails the required `build-test` job.

Only a fixture is registered today (issue #375): it renders under `tools/`,
outside both bundles, so nothing new becomes invokable while the mechanism is
proved. A command rendered into `claude-plugin/.../commands/` or
`codex-plugin/.../skills/` is shipped, and the bundle rules above apply to it.

## Source layout

- `app/` — executable entry point.
- `src/Kanban/` — board, GitHub, terminal interface, worker, review, and settings code.
- `test/` — Haskell tests.
- `tools/` — PR drainer, controller, installers, workflow setup, and Python tests.
- `codex-plugin/`, `claude-plugin/` — the tracked workflow bundles, in two halves: the solve, PR-review, PR-rereview, PR-revise, and repair workflows Kanban's AI actions spawn by name, and the drafting and document workflows you invoke yourself in a Codex or Claude session, which no Kanban action spawns.
- `.github/workflows/` — continuous integration.

## Further detail

See [design.md](design.md) for the complete behavior contract, architecture notes, and implementation history, and [workflow-setup.md](workflow-setup.md) for installing and diagnosing the optional AI-action components.
