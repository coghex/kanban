"""Manifest gates shared by the tracked Claude and Codex plugin bundles.

Imported by `tools/test_claude_plugin.py` and `tools/test_codex_plugin.py`;
never collected by `unittest discover` itself, since it is not a `test_*.py`
module.

Issue #235: both bundles drifted from their own manifests in two directions
at once, and neither drift had a check.

* **Version.** Providers cache a local-source bundle under the version its
  manifest declares (`$CODEX_HOME/plugins/cache/kanban/kanban/<version>/`),
  so contents that change while the version does not make a weeks-stale
  cache indistinguishable from a current one. That is not hypothetical: it
  is the live incident recorded as WF-2 in `docs/workflow_audit_findings.md`,
  where the cache was missing 8 of 12 tracked skills.
* **Listing.** Each manifest's prose enumerates the workflows it ships. Both
  kept enumerating the original set while the bundles grew — the Claude
  manifest named eight commands beside ten tracked ones, the Codex manifest
  seven skills beside twelve.

The change unit is one pull request: the candidate tracked tree compared with
its default-branch merge base. Committed, staged, and tracked working-tree
edits all count; untracked and ignored files (a `__pycache__/` the test run
itself just wrote, say) never do, because git was never asked to ship them.
An untouched default branch has no delta and therefore no obligation, which
is why the version gate is paired with a planted-violation fixture in each
provider's test module rather than trusted to fire on its own.

Resolution never degrades into a skip. A checkout with no default branch to
compare against raises `BundleGateError` naming the repair, because a gate
that quietly passes when its baseline is missing is the same as no gate;
`.github/workflows/ci.yml` checks out with `fetch-depth: 0` so the baseline
is really there.
"""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path, PurePosixPath

# Ordered fallbacks for the ref a change unit is measured against. An
# ordinary clone sets `origin/HEAD` and it is consulted first (so a renamed
# default branch is honored); `actions/checkout` does not set it, which is
# why the explicit remote and local spellings follow.
DEFAULT_BRANCH_REFS = ("refs/remotes/origin/master", "refs/heads/master")

VERSION_RE = re.compile(r"\A\d+(?:\.\d+)*\Z")

# The exact instruction requirement 3 of issue #235 asks the version failure
# to carry, kept as one constant so both provider modules assert the same
# words the failure actually prints.
VERSION_BUMP_INSTRUCTION = "the bundle version must be bumped in the same change"

# A sigil-prefixed workflow identifier as a manifest names it: `/solve` for
# Claude commands, `$solve` for Codex skills. Whole-token by construction, so
# `pr-rereview` never reads as `pr-review` and `issue-review` never as
# `issue`. The lookbehind keeps a path or URL segment (`https://github.com/
# coghex/kanban`, `./plugins/kanban`) from reading as a `/`-workflow.
IDENTIFIER_PATTERNS = {
    "/": re.compile(r"(?<![\w/.-])/([a-z][a-z0-9]*(?:-[a-z0-9]+)*)"),
    "$": re.compile(r"(?<![\w$])\$([a-z][a-z0-9]*(?:-[a-z0-9]+)*)"),
}


class BundleGateError(RuntimeError):
    """A gate could not be evaluated — distinct from a gate that failed."""


def _git(repo_root: Path, *args: str, check: bool = True):
    proc = subprocess.run(
        ["git", *args], cwd=repo_root, capture_output=True, text=True
    )
    if check and proc.returncode != 0:
        raise BundleGateError(
            f"`git {' '.join(args)}` failed in {repo_root}: {proc.stderr.strip()}"
        )
    return proc


def _ref_exists(repo_root: Path, ref: str) -> bool:
    return (
        _git(repo_root, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}", check=False).returncode
        == 0
    )


def default_branch_ref(repo_root: Path) -> str:
    """The default-branch ref present in this checkout.

    Raises rather than returning a sentinel: a missing baseline must fail the
    gate loudly, never let it pass unenforced.
    """
    candidates = []
    symbolic = _git(
        repo_root, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD", check=False
    )
    if symbolic.returncode == 0 and symbolic.stdout.strip():
        candidates.append(symbolic.stdout.strip())
    candidates.extend(DEFAULT_BRANCH_REFS)
    for ref in candidates:
        if _ref_exists(repo_root, ref):
            return ref
    raise BundleGateError(
        "the plugin bundle gate found no default branch in "
        f"{repo_root} to compare against (tried {', '.join(candidates)}). "
        "Fetch it — in CI, `actions/checkout` needs `fetch-depth: 0` — rather "
        "than letting a bundle change through unenforced."
    )


def resolve_comparison_base(repo_root: Path) -> str:
    """The commit this change unit is measured against.

    The merge base, not the default branch tip: a branch that has not merged
    the latest default-branch commits must still be judged only on what it
    itself changed.
    """
    ref = default_branch_ref(repo_root)
    proc = _git(repo_root, "merge-base", "HEAD", ref, check=False)
    base = proc.stdout.strip()
    if proc.returncode != 0 or not base:
        raise BundleGateError(
            f"HEAD and {ref} share no merge base in {repo_root}, so this change "
            "unit has no baseline. Fetch the default branch's history — in CI, "
            "`actions/checkout` needs `fetch-depth: 0`."
        )
    return base


def tracked_delta(repo_root: Path, base: str, prefix: str) -> list[str]:
    """Tracked paths under `prefix` that differ between `base` and the
    candidate tree — committed, staged, and working-tree edits alike.

    `--no-renames` so a rename is reported as both of its paths rather than
    one entry the pathspec might filter asymmetrically; either way a rename
    touching the bundle is a delta.
    """
    proc = _git(
        repo_root, "diff", "--name-only", "--no-renames", base, "--", prefix
    )
    return sorted({line for line in proc.stdout.splitlines() if line})


def tracked_paths(repo_root: Path, prefix: str) -> list[str]:
    """Every path git tracks under `prefix`."""
    proc = _git(repo_root, "ls-files", "--", prefix)
    return sorted(line for line in proc.stdout.splitlines() if line)


def tracked_command_names(repo_root: Path, commands_prefix: str) -> set[str]:
    """The Claude bundle's shipped workflows: the stem of every tracked
    Markdown command file directly under `commands_prefix`."""
    root = PurePosixPath(commands_prefix)
    return {
        PurePosixPath(path).stem
        for path in tracked_paths(repo_root, commands_prefix)
        if path.endswith(".md") and PurePosixPath(path).parent == root
    }


def tracked_skill_names(repo_root: Path, skills_prefix: str) -> set[str]:
    """The Codex bundle's shipped workflows: the directory of every tracked
    `<skills_prefix>/<name>/SKILL.md`."""
    root = PurePosixPath(skills_prefix)
    names = set()
    for path in tracked_paths(repo_root, skills_prefix):
        candidate = PurePosixPath(path)
        if candidate.name == "SKILL.md" and candidate.parent.parent == root:
            names.add(candidate.parent.name)
    return names


def declared_version(document, source: str) -> str:
    """The version a manifest document declares, refusing anything a
    comparison could not order."""
    version = document.get("version") if isinstance(document, dict) else None
    if not isinstance(version, str) or not VERSION_RE.match(version.strip()):
        raise BundleGateError(
            f"{source} does not declare a comparable version: {version!r}"
        )
    return version.strip()


def version_increased(current: str, base: str) -> bool:
    current_parts = [int(part) for part in current.split(".")]
    base_parts = [int(part) for part in base.split(".")]
    width = max(len(current_parts), len(base_parts))
    pad = lambda parts: tuple(parts) + (0,) * (width - len(parts))  # noqa: E731
    return pad(current_parts) > pad(base_parts)


def manifest_version_at(repo_root: Path, base: str, manifest_relpath: str):
    """The version `manifest_relpath` declared at `base`, or `None` when the
    manifest did not exist there — a bundle this change unit introduces has
    no earlier version to increase past."""
    proc = _git(repo_root, "show", f"{base}:{manifest_relpath}", check=False)
    if proc.returncode != 0:
        return None
    try:
        document = json.loads(proc.stdout)
    except json.JSONDecodeError as error:
        raise BundleGateError(
            f"{manifest_relpath} at {base} is not readable JSON ({error})."
        ) from error
    return declared_version(document, f"{manifest_relpath} at {base}")


def version_gate_failures(
    bundle: str,
    manifest_relpath: str,
    changed_paths: list[str],
    current_version: str,
    base_version,
) -> list[str]:
    """The failure lines a bundle owes: none unless its tracked content
    changed since the baseline without its declared version increasing."""
    if not changed_paths:
        return []
    if base_version is None:
        return []
    if version_increased(current_version, base_version):
        return []
    shown = changed_paths[:5]
    listed = ", ".join(shown) + (", …" if len(changed_paths) > len(shown) else "")
    return [
        f"{bundle}: {len(changed_paths)} tracked file(s) changed since the "
        f"comparison base ({listed}) while {manifest_relpath} still declares "
        f"{current_version!r} (the base declared {base_version!r}) — "
        f"{VERSION_BUMP_INSTRUCTION}, because a provider cache keyed by version "
        "otherwise serves stale contents under a current-looking name."
    ]


def bundle_version_failures(
    repo_root: Path, bundle: str, prefix: str, manifest_relpath: str
) -> list[str]:
    """The version gate, end to end, for one bundle in one checkout."""
    base = resolve_comparison_base(repo_root)
    changed = tracked_delta(repo_root, base, prefix)
    document = json.loads((repo_root / manifest_relpath).read_text(encoding="utf-8"))
    current = declared_version(document, manifest_relpath)
    return version_gate_failures(
        bundle, manifest_relpath, changed, current, manifest_version_at(repo_root, base, manifest_relpath)
    )


def workflow_identifiers(text: str, sigil: str) -> set[str]:
    """Every workflow identifier a manifest string names with `sigil`."""
    try:
        pattern = IDENTIFIER_PATTERNS[sigil]
    except KeyError as error:
        raise BundleGateError(f"no workflow identifier pattern for {sigil!r}") from error
    return set(pattern.findall(text))


def parity_failures(surface: str, mentioned: set[str], shipped: set[str]) -> list[str]:
    """The failure lines one manifest surface owes, in both directions: a
    shipped workflow it does not name, and a name it lists that the bundle
    does not ship."""
    failures = []
    omitted = sorted(shipped - mentioned)
    spurious = sorted(mentioned - shipped)
    if omitted:
        failures.append(
            f"{surface} omits shipped workflow(s): {', '.join(omitted)}"
        )
    if spurious:
        failures.append(
            f"{surface} names workflow(s) the bundle does not ship: {', '.join(spurious)}"
        )
    return failures
