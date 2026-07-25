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
`unchanged` and runs no command.

See docs/workflow-setup.md for the fresh-clone procedure this implements.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import install_issue_review


COMPONENTS = ("issue-review", "legacy-launcher", "codex-plugin", "claude-plugin")
SCOPES = ("project", "user")

# The plugin identifier both marketplaces publish, and the marketplace name
# both plugin manifests declare. Kept in one place so the conflict check and
# the install commands cannot drift apart.
MARKETPLACE_NAME = "kanban"
PLUGIN_IDENTIFIER = "kanban@kanban"

PROBE_TIMEOUT_SECONDS = 60


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


# -- component planning -------------------------------------------------------


def component_result(component: str, status: str, **extra: Any) -> dict[str, Any]:
    result = {"component": component, "status": status, "commands": []}
    result.update(extra)
    return result


def issue_review_links(repo: Path, install_dir: Path) -> list[tuple[Path, Path]]:
    return [
        (repo / "tools" / "approve_issues.py", install_dir / "approve_issues.py"),
        (repo / "tools" / "kanban_config.py", install_dir / "kanban_config.py"),
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
    status = "unchanged" if results == {"unchanged"} else "install"
    return component_result(
        "issue-review",
        status,
        links=links,
        scope="user (Kanban-namespaced install directory)",
        message=(
            f"Canonical issue-review backend at {install_dir}: "
            + ", ".join(f"{Path(link['destination']).name} {link['result']}" for link in links)
        ),
    )


def plan_legacy_launcher(
    install_dir: Path, legacy_path: Path, *, migrate: bool
) -> dict[str, Any]:
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
    if any(entry_enabled(entry) for entry in entries) and not commands:
        return component_result(
            component,
            "unchanged",
            scope=scope,
            message=f"{PLUGIN_IDENTIFIER} is already installed and enabled for codex.",
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
) -> dict[str, Any]:
    try:
        if component == "issue-review":
            return plan_issue_review(repo, install_dir)
        if component == "legacy-launcher":
            return plan_legacy_launcher(install_dir, legacy_path, migrate=migrate)
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
    whose plan is `unchanged`, `refused`, or `unavailable` runs nothing."""
    if plan["status"] != "install":
        return plan
    component = plan["component"]
    if component == "issue-review":
        results = []
        for source, destination in issue_review_links(repo, install_dir):
            results.append(install_issue_review.install_symlink(source, destination))
        plan = dict(plan, applied=True, results=results)
        return plan
    if component == "legacy-launcher":
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
        default=os.environ.get(
            "KANBAN_ISSUE_REVIEW_INSTALL_DIR", str(install_issue_review.DEFAULT_INSTALL_DIR)
        ),
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
    seen: list[str] = []
    for component in args.component:
        if component not in seen:
            seen.append(component)
    return seen


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
        planned = [
            plan_component(
                component,
                repo=repo,
                target=target,
                install_dir=install_dir,
                legacy_path=legacy_path,
                scope=args.scope,
                migrate=args.migrate_legacy_launcher,
            )
            for component in components
        ]
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
        needs_attention = any(
            plan["status"] in ("refused", "unavailable", "failed") for plan in planned
        )
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
