#!/usr/bin/env python3

"""Install Kanban's opt-in agent-workflow components on this machine.

Deliberately separate from `tools/install_drainer.py`, which stays limited
to loading a stopped LaunchAgent: nothing here installs, starts, or
configures the PR drainer, an approval daemon, or an agent session. It also
never installs credentials, changes a provider's model/approval/sandbox
defaults, or copies opaque files into an undocumented global directory —
each provider component is installed through that provider's own documented
`plugin marketplace add` / `plugin add|install` mechanism, and the canonical
issue-review backend through the same never-replace-an-ordinary-file
symlink policy `tools/install_issue_review.py` already implements.

Dry run first: with no `--apply`, every component is inspected and the exact
planned action printed, and nothing at all is written. `--apply` performs
that same plan. Re-running converges: an already-correct component reports
`unchanged` and runs no command. "Correct" includes content, not only
registration -- the Codex bundle is installed by copy into a provider cache
with no update command, so a cache that has fallen behind the tracked bundle
is reported as `repair` and refreshed through that provider's own
remove-then-add.

See docs/workflow-setup.md for the fresh-clone procedure this implements.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path, PurePosixPath
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

# A dry run must write nothing at all, and importing a sibling module would
# otherwise leave CPython's bytecode cache behind in the checkout's
# `tools/__pycache__`. The previous policy is restored immediately, so
# importing this module from a test or another tool does not silently change
# how the rest of that process behaves.
_previous_bytecode_policy = sys.dont_write_bytecode
sys.dont_write_bytecode = True
try:
    import install_issue_review
finally:
    sys.dont_write_bytecode = _previous_bytecode_policy


COMPONENTS = ("issue-review", "legacy-launcher", "codex-plugin", "claude-plugin")
SCOPES = ("project", "user")

# The plugin identifier both marketplaces publish, and the marketplace name
# both plugin manifests declare. Kept in one place so the conflict check, the
# install commands, and the installed-bundle cache path cannot drift apart:
# a provider identifier is `<plugin>@<marketplace>`, and Codex's own cache is
# partitioned by those same two names.
PLUGIN_NAME = "kanban"
MARKETPLACE_NAME = "kanban"
PLUGIN_IDENTIFIER = f"{PLUGIN_NAME}@{MARKETPLACE_NAME}"

# The tracked Codex bundle, relative to the checkout root. `codex-plugin/` is
# the marketplace; this is the one plugin it publishes, and the directory the
# provider copies into its cache.
CODEX_BUNDLE_SEGMENTS = ("codex-plugin", "plugins", PLUGIN_NAME)
CODEX_BUNDLE_PREFIX = "/".join(CODEX_BUNDLE_SEGMENTS)

PROBE_TIMEOUT_SECONDS = 60

# How many diverging paths a human-readable message names before summarizing
# the rest. The JSON output always carries the complete lists.
DIVERGENCE_MESSAGE_LIMIT = 8


class SetupError(RuntimeError):
    pass


# -- provider probing ---------------------------------------------------------


def run_command(
    args: list[str], *, cwd: Path | None = None
) -> subprocess.CompletedProcess[str]:
    """Run one provider command. Empty stdin and a bounded timeout keep both
    the read-only probes and the install commands non-interactive."""
    return subprocess.run(
        args,
        cwd=None if cwd is None else str(cwd),
        text=True,
        capture_output=True,
        stdin=subprocess.DEVNULL,
        timeout=PROBE_TIMEOUT_SECONDS,
    )


def probe_json(args: list[str], *, cwd: Path | None = None) -> Any:
    """Read a provider's own `--json` listing, or raise SetupError.

    A listing that cannot be read is never treated as "nothing installed":
    guessing that would turn a provider Kanban cannot introspect into a
    silent reinstall over whatever is already there.
    """
    try:
        proc = run_command(args, cwd=cwd)
    except (OSError, subprocess.SubprocessError) as exc:
        raise SetupError(f"Could not run `{' '.join(args)}`: {exc}") from exc
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip().splitlines()
        summary = detail[0] if detail else f"exited {proc.returncode}"
        raise SetupError(f"`{' '.join(args)}` failed: {summary}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise SetupError(f"Could not decode the output of `{' '.join(args)}`: {exc}") from exc


def _walk_objects(payload: Any):
    if isinstance(payload, dict):
        yield payload
        for value in payload.values():
            yield from _walk_objects(value)
    elif isinstance(payload, list):
        for value in payload:
            yield from _walk_objects(value)


def plugin_entries(payload: Any) -> list[dict[str, Any]]:
    """Every object in a provider's plugin listing that names the Kanban
    bundle, under either provider's identifier field. Walking structurally
    keeps this tolerant of each listing's own envelope."""
    return [
        entry
        for entry in _walk_objects(payload)
        if any(entry.get(key) == PLUGIN_IDENTIFIER for key in ("pluginId", "id"))
    ]


def entry_installed(entry: dict[str, Any]) -> bool:
    """A listing without an `installed` field enumerates installed plugins
    only, so a listed entry counts as installed there."""
    value = entry.get("installed")
    return True if value is None else bool(value)


def entry_enabled(entry: dict[str, Any]) -> bool:
    value = entry.get("enabled")
    return entry_installed(entry) and (True if value is None else bool(value))


def marketplace_entries(payload: Any) -> list[dict[str, Any]]:
    return [
        entry
        for entry in _walk_objects(payload)
        if entry.get("name") == MARKETPLACE_NAME and "name" in entry
    ]


def marketplace_sources(entry: dict[str, Any]) -> list[str]:
    """Every string in a marketplace entry that could name where it was
    added from. Both providers report this differently (`path`/
    `installLocation` versus a nested `marketplaceSource.source`), so all of
    them are collected and compared rather than one shape being assumed."""
    sources: list[str] = []
    for obj in _walk_objects(entry):
        for key in ("path", "installLocation", "root", "source", "repo"):
            value = obj.get(key)
            # "/" keeps only values that can name a location — a local path
            # or an owner/repo reference — and drops each provider's bare
            # source-kind tags ("directory", "github", "local").
            if isinstance(value, str) and "/" in value and value not in sources:
                sources.append(value)
    return sources


def marketplace_matches(entry: dict[str, Any], expected_root: Path) -> bool:
    expected = expected_root.resolve()
    for source in marketplace_sources(entry):
        try:
            if Path(source).expanduser().resolve() == expected:
                return True
        except OSError:
            continue
    return False


# -- installed Codex bundle inspection ----------------------------------------
#
# `codex plugin list --json` answers "is it registered and enabled", never
# "is what got copied still the bundle this checkout tracks". The provider
# copies the bundle into its own cache at install time and offers no update
# command for a local-source marketplace, so a checkout that moves ahead
# leaves every Codex session running the bundle as it was when it was last
# added -- with no signal anywhere that it happened. Comparing the cache
# against the tracked bundle is what turns that into a reported, repairable
# state.


def codex_home() -> Path:
    """Where Codex keeps its own configuration and plugin cache: a non-empty
    `CODEX_HOME`, else the documented `~/.codex` default."""
    value = os.environ.get("CODEX_HOME", "")
    if value.strip():
        return Path(value).expanduser()
    return Path.home() / ".codex"


def codex_bundle_root(repo: Path) -> Path:
    return repo.joinpath(*CODEX_BUNDLE_SEGMENTS)


def codex_bundle_version(repo: Path) -> str:
    """The version the tracked bundle declares for itself, which is the cache
    directory the provider installs it into. Deliberately not a search for
    whichever version happens to be cached: selecting a different one would
    silently compare against a bundle this checkout never published."""
    manifest = codex_bundle_root(repo) / ".codex-plugin" / "plugin.json"
    try:
        document = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SetupError(
            f"Could not read the tracked Codex plugin manifest at {manifest}: {exc}"
        ) from exc
    version = document.get("version") if isinstance(document, dict) else None
    if not isinstance(version, str) or not version.strip():
        raise SetupError(
            f"The tracked Codex plugin manifest at {manifest} declares no usable "
            "version, so the installed bundle it should be compared against cannot "
            "be identified."
        )
    return version.strip()


def codex_cache_dir(repo: Path) -> Path:
    return (
        codex_home()
        / "plugins"
        / "cache"
        / MARKETPLACE_NAME
        / PLUGIN_NAME
        / codex_bundle_version(repo)
    )


def tracked_bundle_files(repo: Path) -> list[str]:
    """Every Git-tracked path under the tracked Codex bundle, relative to it.

    Tracked content is the whole definition of the bundle: a file the
    checkout carries but Git does not track is not something the provider was
    ever asked to install, so it can never make an installation look stale.
    """
    try:
        proc = run_command(
            ["git", "ls-files", "-z", "--", CODEX_BUNDLE_PREFIX], cwd=repo
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise SetupError(f"Could not list the tracked Codex bundle in {repo}: {exc}") from exc
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip().splitlines()
        raise SetupError(
            f"Could not list the tracked Codex bundle in {repo}: "
            + (detail[0] if detail else f"git ls-files exited {proc.returncode}")
        )
    prefix = CODEX_BUNDLE_PREFIX + "/"
    tracked = sorted(
        entry[len(prefix) :]
        for entry in proc.stdout.split("\0")
        if entry.startswith(prefix)
    )
    if not tracked:
        raise SetupError(
            f"{repo} tracks no files under {CODEX_BUNDLE_PREFIX}, so there is no "
            "tracked bundle to compare the installed one against."
        )
    return tracked


def checkout_ignored(repo: Path, relative_paths: list[str]) -> set[str]:
    """The subset of bundle-relative paths this checkout's own ignore rules
    exclude. A directory is passed with a trailing slash, which is how git is
    told the path is one.

    Applied to the *installed* side as well as the checkout, and that is the
    point. The provider copies the bundle directory as it finds it and then
    executes the packaged coordinator from the copy, so `__pycache__/` lands
    in the cache from both directions. Counting an interpreter artefact as
    installed content would make the component report a repair it can never
    converge -- the refresh would recreate the artefact on first use -- which
    is exactly the non-convergence this whole check exists to end.
    """
    if not relative_paths:
        return set()
    prefix = CODEX_BUNDLE_PREFIX + "/"
    try:
        proc = subprocess.run(
            ["git", "check-ignore", "-z", "--stdin"],
            cwd=str(repo),
            input="\0".join(prefix + path for path in relative_paths),
            text=True,
            capture_output=True,
            timeout=PROBE_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise SetupError(f"Could not apply {repo}'s ignore rules: {exc}") from exc
    # 0: some path is ignored. 1: none is. Anything else is a real failure,
    # and guessing "nothing is ignored" there would report artefacts as
    # divergence.
    if proc.returncode not in (0, 1):
        detail = (proc.stderr or proc.stdout or "").strip().splitlines()
        raise SetupError(
            f"Could not apply {repo}'s ignore rules: "
            + (detail[0] if detail else f"git check-ignore exited {proc.returncode}")
        )
    return {
        entry[len(prefix) :]
        for entry in proc.stdout.split("\0")
        if entry.startswith(prefix)
    }


def installed_bundle_entries(cache: Path) -> tuple[list[str], list[str]]:
    """The files and the directories under an installed bundle, each relative
    to it. A directory that cannot be read raises rather than reading as
    empty: an unreadable cache is an unusable one, not a diverged one.

    Directories are collected as well as files because a directory holding no
    file at all is still installed content — an emptied or left-behind skill
    directory is invisible to a file-only inventory, and would read as
    convergence.
    """

    def _fail(error: OSError) -> None:
        raise error

    files: list[str] = []
    directories: list[str] = []
    try:
        for current, names, filenames in os.walk(cache, onerror=_fail):
            for name in names:
                directories.append(Path(current, name).relative_to(cache).as_posix())
            for name in filenames:
                files.append(Path(current, name).relative_to(cache).as_posix())
    except OSError as exc:
        raise SetupError(f"Could not read the installed Codex bundle at {cache}: {exc}") from exc
    return sorted(files), sorted(directories)


def tracked_ancestors(tracked: list[str]) -> set[str]:
    """Every directory a tracked path lies inside. These are the directories
    the bundle defines, so an installed directory outside this set is one the
    tracked bundle does not have."""
    return {
        parent.as_posix()
        for path in tracked
        for parent in PurePosixPath(path).parents
        if parent.as_posix() != "."
    }


def unexpected_directories(
    directories: list[str], tracked: list[str], extra_files: list[str]
) -> list[str]:
    """Installed directories the tracked bundle does not define, reduced to
    the ones worth naming: the shallowest of a nested run, and only when no
    reported extra file beneath one already names it.

    `extra_files` must already have the ignore rules applied. An ignored file
    is not content, so it cannot stand in for the directory holding it — a
    `skills/retired/` whose only occupant is a `__pycache__/` artefact is
    still an installed directory the tracked bundle does not define, and
    suppressing it on the strength of a file that is then filtered away would
    report the whole cache as converged. Keeping only the shallowest of a
    nested run loses nothing, because git ignores every descendant of an
    ignored directory.
    """
    defined = tracked_ancestors(tracked)
    candidates = [path for path in directories if path not in defined]
    return [
        path
        for path in candidates
        if not any(path.startswith(other + "/") for other in candidates)
        and not any(name.startswith(path + "/") for name in extra_files)
    ]


def _same_bytes(tracked_file: Path, installed_file: Path) -> bool:
    try:
        return tracked_file.read_bytes() == installed_file.read_bytes()
    except OSError as exc:
        raise SetupError(
            f"Could not compare {installed_file} against {tracked_file}: {exc}"
        ) from exc


def codex_cache_divergence(repo: Path) -> dict[str, Any] | None:
    """How the installed Codex bundle differs from the tracked one, or None
    when they match. Raises SetupError when the installed side cannot be read
    at all, so an unusable cache is reported rather than repaired blindly."""
    cache = codex_cache_dir(repo)
    tracked = tracked_bundle_files(repo)
    bundle_root = codex_bundle_root(repo)
    if not os.path.lexists(cache):
        # An enabled installation whose cache is simply not there is the same
        # repairable state as a stale one: the provider will recreate it.
        return {
            "cache": str(cache),
            "installed": False,
            "missing": tracked,
            "extra": [],
            "different": [],
        }
    if not cache.is_dir():
        raise SetupError(
            f"The installed Codex bundle path {cache} is not a readable directory, so "
            f"{PLUGIN_IDENTIFIER} cannot be compared against {bundle_root}."
        )
    installed_files, installed_directories = installed_bundle_entries(cache)
    installed = set(installed_files)
    tracked_set = set(tracked)
    missing = [path for path in tracked if path not in installed]
    different = [
        path
        for path in tracked
        if path in installed and not _same_bytes(bundle_root / path, cache / path)
    ]
    # Files first, and only the ones that survive the ignore rules go on to
    # suppress the directories holding them.
    unexpected_files = sorted(installed - tracked_set)
    extra_files = sorted(set(unexpected_files) - checkout_ignored(repo, unexpected_files))
    # Queried with a trailing slash, which is how `git check-ignore` is told a
    # path is a directory — a directory-only rule such as `__pycache__/` does
    # not match the bare spelling of a path that is not in the checkout.
    unexpected_dirs = [
        path + "/"
        for path in unexpected_directories(installed_directories, tracked, extra_files)
    ]
    extra = sorted(
        extra_files + sorted(set(unexpected_dirs) - checkout_ignored(repo, unexpected_dirs))
    )
    if not missing and not different and not extra:
        return None
    return {
        "cache": str(cache),
        "installed": True,
        "missing": missing,
        "extra": extra,
        "different": different,
    }


def _name_paths(paths: list[str]) -> str:
    shown = ", ".join(paths[:DIVERGENCE_MESSAGE_LIMIT])
    remaining = len(paths) - DIVERGENCE_MESSAGE_LIMIT
    return f"{shown} (+{remaining} more)" if remaining > 0 else shown


def divergence_message(repo: Path, divergence: dict[str, Any]) -> str:
    """Name the divergence in bundle-relative paths. Only paths belonging to
    Kanban's own installed bundle are reported, so nothing else under
    `CODEX_HOME` is exposed by asking about this one."""
    cache = divergence["cache"]
    bundle_root = codex_bundle_root(repo)
    if not divergence["installed"]:
        return (
            f"{PLUGIN_IDENTIFIER} is installed and enabled for codex, but its bundle is "
            f"not cached at {cache}, so every Codex session runs no tracked skill from "
            f"{bundle_root}. Re-adding the plugin restores it."
        )
    groups = [
        (name, divergence[name])
        for name in ("missing", "different", "extra")
        if divergence[name]
    ]
    detail = "; ".join(f"{name} ({len(paths)}): {_name_paths(paths)}" for name, paths in groups)
    return (
        f"{PLUGIN_IDENTIFIER} is installed and enabled for codex, but the bundle cached "
        f"at {cache} no longer matches the tracked bundle in {bundle_root} — {detail}. "
        f"Codex has no plugin update command for a local-source marketplace, so the "
        f"refresh is `codex plugin remove {PLUGIN_IDENTIFIER}` followed by "
        f"`codex plugin add {PLUGIN_IDENTIFIER}`."
    )


# -- component planning -------------------------------------------------------


def component_result(component: str, status: str, **extra: Any) -> dict[str, Any]:
    result = {"component": component, "status": status, "commands": []}
    result.update(extra)
    return result


def issue_review_links(repo: Path, install_dir: Path) -> list[tuple[Path, Path]]:
    """Every link this component installs, from the installer's own inventory.

    Read from `install_issue_review.BACKEND_MODULES` rather than restated, so
    the two supported ways to install this backend cannot converge on different
    sets: setup is not a second definition of what an installation is.
    """
    return [
        (repo / "tools" / name, install_dir / name)
        for name in install_issue_review.BACKEND_MODULES.values()
    ]


def plan_issue_review(repo: Path, install_dir: Path) -> dict[str, Any]:
    links = []
    for source, destination in issue_review_links(repo, install_dir):
        if not source.is_file():
            raise SetupError(f"Repository does not contain the required backend file: {source}")
        links.append(
            {
                "source": str(source),
                "destination": str(destination),
                "result": install_issue_review.plan_symlink(
                    source.resolve(strict=True), destination
                ),
            }
        )
    results = {link["result"] for link in links}
    if "refused" in results:
        refused = next(link for link in links if link["result"] == "refused")
        return component_result(
            "issue-review",
            "refused",
            links=links,
            scope="user (Kanban-namespaced install directory)",
            message=install_issue_review.symlink_refusal_reason(Path(refused["destination"])),
        )
    # Setup is the other supported way to install this backend, so it has to
    # publish the same discovery record the installer does -- otherwise a
    # custom install made here would be undiscoverable. The record is part of
    # the plan, not a side effect of it: an installation whose links are
    # already correct but whose record predates them still has work to do, and
    # reporting that as `unchanged` would skip the repair.
    record = {
        "path": str(install_issue_review.discovery_record_path()),
        "backend_path": str(install_dir / "approve_issues.py"),
        "result": install_issue_review.plan_discovery_record(install_dir, None),
    }
    converged = results == {"unchanged"} and record["result"] == "unchanged"
    return component_result(
        "issue-review",
        "unchanged" if converged else "install",
        links=links,
        record=record,
        scope="user (Kanban-namespaced install directory)",
        message=(
            f"Canonical issue-review backend at {install_dir}: "
            + ", ".join(f"{Path(link['destination']).name} {link['result']}" for link in links)
            + f"; discovery record {record['path']} {record['result']}"
        ),
    )


def backend_is_installed(install_dir: Path) -> bool:
    """Whether a Kanban-managed backend already occupies install_dir.

    Exactly the shape `plan_issue_review` converges on and
    `Kanban.Preflight` counts as installed: for each installed asset, a
    symlink resolving to a file that carries that asset's identity marker.
    All of them are required, since `approve_issues.py` imports both
    `kanban_config.py` and `kanban_models.py` at module scope.

    An ordinary marker-bearing copy is deliberately *not* accepted. Setup
    refuses to manage that path and preflight reports it as a conflicting
    installation, so treating it as ready here would install a compatibility
    launcher pointing at something the rest of the system will not use.
    """
    for name in install_issue_review.BACKEND_MODULES.values():
        path = install_dir / name
        if not path.is_symlink() or not path.is_file():
            return False
        if not install_issue_review.is_managed_asset(path, name):
            return False
    return True


def plan_legacy_launcher(
    install_dir: Path, legacy_path: Path, *, migrate: bool, backend_ready: bool
) -> dict[str, Any]:
    # The launcher is a symlink *to* the managed backend link, so installing
    # it without that backend would produce a launcher pointing at nothing
    # -- and with --migrate-legacy-launcher it would first move the user's
    # own launcher aside to make room for that dangling link.
    if not backend_ready:
        return component_result(
            "legacy-launcher",
            "unavailable",
            scope="user (pre-Kanban automation compatibility)",
            message=(
                f"The canonical issue-review backend is not installed at {install_dir}, so "
                "the compatibility launcher would point at nothing. Install it first, or "
                "select --component issue-review in the same run."
            ),
        )
    plan = install_issue_review.plan_legacy_launcher(
        legacy_path, install_dir / "approve_issues.py", allow_migration=migrate
    )
    status = {"refused": "refused", "unchanged": "unchanged"}.get(plan["status"], "install")
    if plan["status"] == "refused":
        # The installer's own refusal text is the authority here, so the two
        # can never describe the same preserved file differently.
        message = f"{legacy_path}: {plan['message']}"
    else:
        message = f"Compatibility launcher at {legacy_path}: {plan['status']}"
        if plan.get("backup_path"):
            message += f" (previous file preserved at {plan['backup_path']})"
    return component_result(
        "legacy-launcher",
        status,
        plan=plan,
        scope="user (pre-Kanban automation compatibility)",
        message=message,
    )


def plan_codex_plugin(repo: Path, scope: str) -> dict[str, Any]:
    component = "codex-plugin"
    marketplace_root = repo / "codex-plugin"
    if scope != "user":
        return component_result(
            component,
            "refused",
            scope=scope,
            message=(
                "Codex registers plugins in your own $CODEX_HOME/config.toml, which is "
                "user-global; it has no project-scoped install. Re-run with --scope user "
                "to choose that explicitly."
            ),
        )
    executable = shutil.which("codex")
    if executable is None:
        return component_result(
            component,
            "unavailable",
            scope=scope,
            message="codex was not found on PATH; install the Codex CLI first.",
        )
    commands: list[list[str]] = []
    marketplaces = marketplace_entries(
        probe_json([executable, "plugin", "marketplace", "list", "--json"], cwd=repo)
    )
    for entry in marketplaces:
        if not marketplace_matches(entry, marketplace_root):
            return component_result(
                component,
                "refused",
                scope=scope,
                message=(
                    f"A Codex marketplace named `{MARKETPLACE_NAME}` is already registered "
                    f"from {', '.join(marketplace_sources(entry)) or 'an unreported source'}, "
                    f"not {marketplace_root}. It is left untouched; remove it with "
                    f"`codex plugin marketplace remove {MARKETPLACE_NAME}` and re-run, or "
                    "point --repo at that checkout."
                ),
            )
    if not marketplaces:
        commands.append([executable, "plugin", "marketplace", "add", str(marketplace_root)])
    entries = plugin_entries(probe_json([executable, "plugin", "list", "--json"], cwd=repo))
    if any(entry_enabled(entry) for entry in entries):
        # Registered and enabled is not the same as current. Read-only, and
        # reached only once the marketplace conflict above has cleared, so a
        # marketplace registered from another checkout still refuses first
        # and still runs nothing.
        divergence = codex_cache_divergence(repo)
        if divergence:
            commands.append([executable, "plugin", "remove", PLUGIN_IDENTIFIER])
            commands.append([executable, "plugin", "add", PLUGIN_IDENTIFIER])
            return component_result(
                component,
                "repair",
                scope=scope,
                commands=commands,
                divergence=divergence,
                message=divergence_message(repo, divergence),
            )
        if not commands:
            return component_result(
                component,
                "unchanged",
                scope=scope,
                divergence=None,
                message=(
                    f"{PLUGIN_IDENTIFIER} is already installed and enabled for codex, and "
                    f"its cached bundle matches {codex_bundle_root(repo)}."
                ),
            )
    if any(entry_installed(entry) and not entry_enabled(entry) for entry in entries):
        return component_result(
            component,
            "refused",
            scope=scope,
            message=(
                f"{PLUGIN_IDENTIFIER} is installed for codex but disabled. It is left "
                f"untouched; remove it with `codex plugin remove {PLUGIN_IDENTIFIER}` and "
                "re-run, or re-enable it yourself."
            ),
        )
    if not any(entry_enabled(entry) for entry in entries):
        commands.append([executable, "plugin", "add", PLUGIN_IDENTIFIER])
    return component_result(
        component,
        "install",
        scope=scope,
        commands=commands,
        message=f"Install {PLUGIN_IDENTIFIER} for codex from {marketplace_root}.",
    )


def plan_claude_plugin(repo: Path, target: Path, scope: str) -> dict[str, Any]:
    component = "claude-plugin"
    marketplace_root = repo / "claude-plugin"
    executable = shutil.which("claude")
    if executable is None:
        return component_result(
            component,
            "unavailable",
            scope=scope,
            message="claude was not found on PATH; install Claude Code first.",
        )
    commands: list[list[str]] = []
    marketplaces = marketplace_entries(
        probe_json([executable, "plugin", "marketplace", "list", "--json"], cwd=target)
    )
    for entry in marketplaces:
        if not marketplace_matches(entry, marketplace_root):
            return component_result(
                component,
                "refused",
                scope=scope,
                message=(
                    f"A Claude Code marketplace named `{MARKETPLACE_NAME}` is already "
                    f"registered from {', '.join(marketplace_sources(entry)) or 'an unreported source'}, "
                    f"not {marketplace_root}. It is left untouched; remove it with "
                    f"`claude plugin marketplace remove {MARKETPLACE_NAME}` and re-run, or "
                    "point --repo at that checkout."
                ),
            )
    if not marketplaces:
        commands.append(
            [executable, "plugin", "marketplace", "add", str(marketplace_root), "--scope", scope]
        )
    entries = plugin_entries(probe_json([executable, "plugin", "list", "--json"], cwd=target))
    if any(entry_enabled(entry) for entry in entries) and not commands:
        return component_result(
            component,
            "unchanged",
            scope=scope,
            target=str(target),
            message=f"{PLUGIN_IDENTIFIER} is already installed and enabled for claude.",
        )
    if any(entry_installed(entry) and not entry_enabled(entry) for entry in entries):
        return component_result(
            component,
            "refused",
            scope=scope,
            target=str(target),
            message=(
                f"{PLUGIN_IDENTIFIER} is installed for claude but disabled. It is left "
                f"untouched; re-enable it with `claude plugin enable {PLUGIN_IDENTIFIER}` "
                f"or remove it with `claude plugin uninstall {PLUGIN_IDENTIFIER}` and re-run."
            ),
        )
    if not any(entry_enabled(entry) for entry in entries):
        commands.append([executable, "plugin", "install", PLUGIN_IDENTIFIER, "--scope", scope])
    return component_result(
        component,
        "install",
        scope=scope,
        target=str(target),
        commands=commands,
        message=(
            f"Install {PLUGIN_IDENTIFIER} for claude from {marketplace_root} in {scope} scope"
            + (f", declared in {target}." if scope == "project" else ".")
        ),
    )


def plan_component(
    component: str,
    *,
    repo: Path,
    target: Path,
    install_dir: Path,
    legacy_path: Path,
    scope: str,
    migrate: bool,
    backend_ready: bool,
) -> dict[str, Any]:
    try:
        if component == "issue-review":
            return plan_issue_review(repo, install_dir)
        if component == "legacy-launcher":
            return plan_legacy_launcher(
                install_dir, legacy_path, migrate=migrate, backend_ready=backend_ready
            )
        if component == "codex-plugin":
            return plan_codex_plugin(repo, scope)
        if component == "claude-plugin":
            return plan_claude_plugin(repo, target, scope)
    except SetupError as exc:
        return component_result(component, "unavailable", scope=scope, message=str(exc))
    raise SetupError(f"Unknown component: {component}")


# -- applying -----------------------------------------------------------------


def apply_component(
    plan: dict[str, Any],
    *,
    repo: Path,
    target: Path,
    install_dir: Path,
    legacy_path: Path,
    migrate: bool,
) -> dict[str, Any]:
    """Perform exactly the plan that was inspected and reported. A component
    whose plan is `unchanged`, `refused`, or `unavailable` runs nothing; an
    `install` or a `repair` runs the commands it named, in that order.
    `repair` is produced by the codex-plugin component alone, which is why
    the convergence re-check below is the Codex bundle comparison."""
    if plan["status"] not in ("install", "repair"):
        return plan
    component = plan["component"]
    if component == "issue-review":
        results = []
        for source, destination in issue_review_links(repo, install_dir):
            results.append(install_issue_review.install_symlink(source, destination))
        # After the links, never before: the record names a backend, so it
        # must not name one that failed to arrive. `None` for the config
        # reference because setup has no --config of its own -- the merge
        # carries forward whatever a previous install stored.
        record_path = install_issue_review.write_discovery_record(install_dir, None)
        plan = dict(
            plan,
            applied=True,
            results=results,
            record=dict(plan["record"], path=str(record_path), result="written"),
        )
        return plan
    if component == "legacy-launcher":
        # Re-checked here, not only at plan time: the backend this launcher
        # points at may be installed by an earlier component in this same
        # run, and nothing may move the user's own launcher aside for a link
        # to a backend that did not actually arrive.
        if not backend_is_installed(install_dir):
            return dict(
                plan,
                status="failed",
                applied=False,
                message=(
                    f"The canonical issue-review backend is still not installed at "
                    f"{install_dir}; the compatibility launcher was left untouched."
                ),
            )
        result = install_issue_review.migrate_legacy_launcher(
            legacy_path, install_dir / "approve_issues.py", allow_migration=migrate
        )
        return dict(plan, applied=True, plan=result)
    cwd = repo if component == "codex-plugin" else target
    outputs = []
    for command in plan["commands"]:
        proc = run_command(command, cwd=cwd)
        outputs.append(
            {
                "command": command,
                "exit_code": proc.returncode,
                "output": (proc.stdout + proc.stderr).strip(),
            }
        )
        if proc.returncode != 0:
            return dict(
                plan,
                status="failed",
                applied=False,
                outputs=outputs,
                message=(
                    f"`{' '.join(command)}` exited {proc.returncode}. Nothing further was "
                    "attempted for this component."
                ),
            )
    if plan["status"] == "repair":
        # The provider reporting success is not evidence that the cache now
        # matches: verify the same comparison that planned the repair, so a
        # refresh that silently did not converge is reported rather than
        # counted as a repair.
        try:
            divergence = codex_cache_divergence(repo)
        except SetupError as exc:
            return dict(plan, status="failed", applied=False, outputs=outputs, message=str(exc))
        if divergence:
            return dict(
                plan,
                status="failed",
                applied=False,
                outputs=outputs,
                divergence=divergence,
                message=(
                    "The refresh ran, but the installed bundle still does not match the "
                    f"tracked one: {divergence_message(repo, divergence)}"
                ),
            )
        return dict(
            plan,
            applied=True,
            outputs=outputs,
            divergence=None,
            message=(
                f"Refreshed {PLUGIN_IDENTIFIER} for codex; the bundle cached at "
                f"{codex_cache_dir(repo)} now matches {codex_bundle_root(repo)}."
            ),
        )
    return dict(plan, applied=True, outputs=outputs)


# -- CLI ----------------------------------------------------------------------


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Install Kanban's opt-in agent-workflow components. Inspects and reports "
            "the exact plan by default; pass --apply to perform it."
        )
    )
    parser.add_argument(
        "--component",
        action="append",
        choices=COMPONENTS,
        default=None,
        help="Component to set up (repeatable). Required unless --all is given.",
    )
    parser.add_argument("--all", action="store_true", help="Select every component.")
    parser.add_argument(
        "--scope",
        choices=SCOPES,
        default="project",
        help=(
            "Where a provider registration is declared. Project scope is the default; "
            "a user-global registration must be chosen explicitly."
        ),
    )
    parser.add_argument(
        "--repo",
        default=str(Path(__file__).resolve().parent.parent),
        help="Kanban checkout providing the tracked assets (default: this checkout).",
    )
    parser.add_argument(
        "--target",
        default=None,
        help=(
            "Repository a project-scoped registration is declared in "
            "(default: the --repo checkout)."
        ),
    )
    parser.add_argument(
        "--install-dir",
        # The env-override-then-default rule itself lives in one place too,
        # so this and the installer's own --install-dir cannot disagree.
        default=str(install_issue_review.selected_install_dir()),
        help="Stable per-user script-link directory for the issue-review backend.",
    )
    parser.add_argument(
        "--legacy-path",
        default=str(install_issue_review.DEFAULT_LEGACY_PATH),
        help="Compatibility launcher path pre-migration automation invokes.",
    )
    parser.add_argument(
        "--migrate-legacy-launcher",
        action="store_true",
        help=(
            "Back up and replace an ordinary pre-Kanban file at --legacy-path. Without "
            "this, an ordinary file there is preserved and refused."
        ),
    )
    parser.add_argument(
        "--apply", action="store_true", help="Perform the reported plan instead of only printing it."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Explicitly inspect and report without writing (the default behaviour).",
    )
    parser.add_argument("--json", action="store_true", help="Print JSON output.")
    return parser.parse_args(argv)


def selected_components(args: argparse.Namespace) -> list[str]:
    if args.all:
        if args.component:
            raise SetupError("Pass either --all or --component, not both.")
        return list(COMPONENTS)
    if not args.component:
        raise SetupError(
            "Select at least one component explicitly: "
            + ", ".join(f"--component {name}" for name in COMPONENTS)
            + ", or --all."
        )
    # Canonical order, not the order they were typed: the compatibility
    # launcher points at the backend the issue-review component installs, so
    # it has to be planned and applied after it whichever way round the user
    # asked for them.
    return [component for component in COMPONENTS if component in set(args.component)]


def plan_needs_attention(plan: dict[str, Any]) -> bool:
    """Whether a component still needs the user to act after this run.

    A pending `repair` does: an installed bundle that no longer matches the
    tracked one silently runs stale workflows, and a dry run's job is to say
    so and exit non-zero. A repair `--apply` already performed does not — the
    same run converged it, and an ordinary fresh install has never been
    "attention" either.
    """
    if plan["status"] in ("refused", "unavailable", "failed"):
        return True
    return plan["status"] == "repair" and not plan.get("applied")


def print_plan(result: dict[str, Any]) -> None:
    if result["dry_run"]:
        print(f"Dry run for {result['repo']}; nothing will be changed.")
    else:
        print(f"Applying Kanban workflow setup for {result['repo']}.")
    for component in result["components"]:
        print(f"  {component['component']}: {component['status']}")
        print(f"    {component['message']}")
        for command in component.get("commands", []):
            prefix = "would run" if result["dry_run"] else "ran"
            print(f"    {prefix}: {' '.join(command)}")
    if result["needs_attention"]:
        print("Some components need your attention; nothing was replaced.")
    elif result["dry_run"]:
        print("Re-run with --apply to perform this plan.")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        if args.apply and args.dry_run:
            raise SetupError("Pass either --apply or --dry-run, not both.")
        components = selected_components(args)
        repo = install_issue_review.repository_root(Path(args.repo))
        target = Path(args.target).expanduser().resolve() if args.target else repo
        install_dir = Path(args.install_dir).expanduser().resolve()
        legacy_path = Path(args.legacy_path).expanduser()
        planned: list[dict[str, Any]] = []
        for component in components:
            # A backend already installed counts, and so does one this same
            # run is about to install: components are applied in the
            # canonical order selected_components returns, so issue-review
            # lands before the launcher that depends on it.
            backend_ready = backend_is_installed(install_dir) or any(
                plan["component"] == "issue-review"
                and plan["status"] in ("install", "unchanged")
                for plan in planned
            )
            planned.append(
                plan_component(
                    component,
                    repo=repo,
                    target=target,
                    install_dir=install_dir,
                    legacy_path=legacy_path,
                    scope=args.scope,
                    migrate=args.migrate_legacy_launcher,
                    backend_ready=backend_ready,
                )
            )
        if args.apply:
            planned = [
                apply_component(
                    plan,
                    repo=repo,
                    target=target,
                    install_dir=install_dir,
                    legacy_path=legacy_path,
                    migrate=args.migrate_legacy_launcher,
                )
                for plan in planned
            ]
        needs_attention = any(plan_needs_attention(plan) for plan in planned)
        result = {
            "dry_run": not args.apply,
            "repo": str(repo),
            "target": str(target),
            "scope": args.scope,
            "install_dir": str(install_dir),
            "components": planned,
            "needs_attention": needs_attention,
        }
        if args.json:
            print(json.dumps(result, indent=2, sort_keys=True))
        else:
            print_plan(result)
        return 1 if needs_attention else 0
    except (SetupError, install_issue_review.InstallError, OSError) as exc:
        if args.json:
            print(json.dumps({"error": str(exc)}, indent=2), file=sys.stderr)
        else:
            print(f"setup_workflows.py: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
