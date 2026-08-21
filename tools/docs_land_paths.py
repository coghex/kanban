"""Path validation, §7 classification, and inventory for tools/docs_land.sh.

Run with: python3 tools/docs_land_paths.py --worktree <docs-worktree> \
    (--gate [--] <path>... | --inventory)

Issue #410. The landing script commits and pushes exactly the paths it is
given, so which paths it may be given is a policy question, answered here in
one place rather than inside shell text:

* A path must be a literal, repository-relative Markdown file inside the docs
  worktree — no absolute paths, no traversal, no directories, no Git pathspec
  magic, no glob metacharacters (ordinary Git pathspecs glob by default, so a
  `*` would otherwise expand), no control characters (the canonical-path
  handoff below is line-delimited, so an embedded newline would split one
  name into two), and no symlinks — leaf or ancestor, since a symlinked
  directory resolves the leaf outside the worktree — other than the verified
  `AGENTS.md` alias.
* `AGENTS.md` is a tracked symlink to `CLAUDE.md`, so a selection of the alias
  is canonicalized to `CLAUDE.md` and reported; an alias object that has been
  changed or replaced is refused, because editing through the alias changes
  the target rather than the Git path named `AGENTS.md`.
* Classification is read from `origin/master`'s
  `docs/agent-workflow-contract.md` §7 — the publication tip, not the local
  copy — and applies §7's whole-component matching. A path is eligible only
  when exactly one row covers it and the row cites no `test-parsed` or
  `implementation-coupled` reason. The root instruction documents `CLAUDE.md`
  and `AGENTS.md` are the sole exception: CLAUDE.md's manual docs-worktree
  publication exception already grants them the direct lane.
* Anything unclassified fails closed with the specific missing
  classification, mirroring `tools/test_document_classification.py`.

`--gate` prints the canonical path list on stdout (one per line) and notes on
stderr, exiting nonzero with every refusal when any named path is refused.
`--inventory` prints one row per known Markdown document — tracked, untracked,
ignored, or deleted — with its state, its §7 row and lane, and whether it
differs from the fetched `origin/master`. Both modes are read-only.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

CONTRACT_PATH = "docs/agent-workflow-contract.md"
CONTRACT_REF = "origin/master"

# §7's fence and row shapes, spelled exactly the way
# tools/test_document_classification.py parses the tracked contract, so the
# two readers cannot disagree about what a row is.
SECTION_7_FENCE_RE = re.compile(
    r"^##\s*7\.\s*Document publication classification\s*$.*?```text\n(?P<body>.*?)\n```",
    re.DOTALL | re.MULTILINE,
)
CLASSIFICATION_ROW_RE = re.compile(
    r"^(?P<path>\S+)\s*\|\s*(?P<klass>[\w-]+)\s*\|\s*(?P<reasons>[^|]+?)\s*$"
)

# The reasons that keep a document in the pull-request lane for this command.
# `release-document` deliberately does not gate: what ships in an archive is a
# packaging question, and CLAUDE.md's manual publication exception already
# pushes documentation-only diffs of such documents straight to master.
GATING_REASONS = ("test-parsed", "implementation-coupled")

# The root instruction documents. CLAUDE.md's "Manual docs-worktree
# publication" section names them as landable despite their
# implementation-coupled row, and they are the only such exception.
ROOT_CONTRACT_CANONICAL = "CLAUDE.md"
ROOT_CONTRACT_ALIAS = "AGENTS.md"

# What actually breaks when a gated row's document lands alone, keyed by the
# declaring row. A row outside this map still names its reasons; this adds the
# specific gate where §7's prose records one.
KNOWN_GATES = {
    "docs/design.md": (
        "test/Spec/UI/Keys.hs holds its §7 key table against Kanban.UI.Keys"
    ),
    "docs/agent-workflow-contract.md": (
        "tools/test_agent_workflow_contract.py parses its §4 manifest and "
        "tools/test_document_classification.py parses its §7 table"
    ),
    "docs/document-workflow-contract.md": (
        "tools/test_document_workflow_contract.py parses its §2 asset table"
    ),
    "docs/drafting-workflow-contract.md": (
        "tools/test_drafting_workflow_contract.py parses its §2 asset table"
    ),
    "docs/media/README.md": (
        "tools/test_board_screenshot.py reconciles its regeneration procedure"
    ),
    "claude-plugin/": (
        "BundleVersionGateTests holds a plugin command file to its bundle "
        "version"
    ),
    "codex-plugin/": (
        "BundleVersionGateTests holds a plugin skill file to its bundle "
        "version"
    ),
    "tools/": (
        "tools/test_render_command_sources.py byte-compares the rendered "
        "workflow files against the authored sources here"
    ),
}

REASON_EXPLANATIONS = {
    "test-parsed": "a tracked test reads it as data, so landing it alone can fail build-test",
    "implementation-coupled": (
        "CLAUDE.md's \"The contract\" requires it to stay consistent with "
        "behavior in the same pull request"
    ),
}


class Refusal(Exception):
    """One named path cannot land, with the reason the user needs."""


def run_git(
    worktree: Path, *args: str, check: bool = True, literal: bool = False
) -> subprocess.CompletedProcess:
    # Pathspec-mode variables are scrubbed so the caller's environment cannot
    # change what `ls-files -- '*.md'` below means; the landing script sets
    # GIT_LITERAL_PATHSPECS for its own scoped calls, and inheriting it here
    # would turn that glob into a literal filename.
    env = {
        key: value
        for key, value in os.environ.items()
        if key
        not in (
            "GIT_LITERAL_PATHSPECS",
            "GIT_GLOB_PATHSPECS",
            "GIT_NOGLOB_PATHSPECS",
            "GIT_ICASE_PATHSPECS",
            "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_INDEX_FILE",
        )
    }
    if literal:
        # For a call whose pathspec is one user-named path: expansion there
        # would let a name reach git as a pattern, which the validation above
        # already refuses — this keeps the two readings from ever diverging.
        env["GIT_LITERAL_PATHSPECS"] = "1"
    proc = subprocess.run(
        ["git", "-C", str(worktree), *args],
        capture_output=True,
        text=True,
        env=env,
    )
    if check and proc.returncode != 0:
        raise SystemExit(
            f"git {' '.join(args)} failed in {worktree}:\n{proc.stderr.strip()}"
        )
    return proc


def contract_rows(worktree: Path) -> dict[str, dict]:
    """§7's rows as read from the publication tip, keyed by declared path."""
    proc = run_git(
        worktree, "show", f"{CONTRACT_REF}:{CONTRACT_PATH}", check=False
    )
    if proc.returncode != 0:
        raise SystemExit(
            f"{CONTRACT_REF} carries no {CONTRACT_PATH}, so no path can be "
            "classified; nothing lands without a §7 classification"
        )
    fence = SECTION_7_FENCE_RE.search(proc.stdout)
    if fence is None:
        raise SystemExit(
            f"{CONTRACT_REF}:{CONTRACT_PATH} has no §7 classification fence, "
            "so no path can be classified; nothing lands without one"
        )
    rows: dict[str, dict] = {}
    for line in fence.group("body").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = CLASSIFICATION_ROW_RE.match(line)
        if match is None:
            raise SystemExit(f"unparseable §7 classification row: {line!r}")
        row = match.groupdict()
        row["reasons"] = [
            reason.strip() for reason in row["reasons"].split(";") if reason.strip()
        ]
        rows[row["path"]] = row
    return rows


def row_covers(declared_path: str, markdown_path: str) -> bool:
    """One §7 row against one path, by whole path component — the same rule
    tools/test_document_classification.py enforces."""
    if not declared_path.endswith("/"):
        return declared_path == markdown_path
    prefix = PurePosixPath(declared_path.rstrip("/")).parts
    return PurePosixPath(markdown_path).parts[: len(prefix)] == prefix


def matching_rows(rows: dict[str, dict], markdown_path: str) -> list[str]:
    return sorted(path for path in rows if row_covers(path, markdown_path))


def validate_shape(argument: str) -> str:
    """`argument` as a clean repository-relative Markdown path, or Refusal."""
    if not argument or argument.strip() != argument:
        raise Refusal(f"{argument!r}: not a repository-relative path")
    if any(ord(character) < 0x20 or character == "\x7f" for character in argument):
        # The canonical-path handoff to tools/docs_land.sh is line-delimited,
        # so an embedded newline would split one validated name into two and
        # hand the second past validation and classification entirely. No
        # document here carries a control character, so all of them are
        # refused rather than escaped.
        raise Refusal(
            f"{argument!r}: control characters are refused; name each "
            "document by its plain repository-relative path"
        )
    if argument.startswith("/") or argument.startswith("~"):
        raise Refusal(
            f"{argument}: absolute and home-relative paths are refused; name "
            "the document relative to the repository root"
        )
    if argument.startswith(":"):
        raise Refusal(
            f"{argument}: Git pathspec magic is refused; name the literal path"
        )
    if "\\" in argument:
        raise Refusal(f"{argument}: backslashes are refused; use `/` separators")
    if any(character in argument for character in "*?[]"):
        # Leading `:` covers pathspec magic, but ordinary Git pathspecs glob
        # by default — `docs/coordination/*.md` would otherwise reach
        # `git ls-files -- <path>` and expand. The exact-named-path contract
        # means one argument names one document, so the metacharacters are
        # refused rather than expanded.
        raise Refusal(
            f"{argument}: glob metacharacters are refused; name each literal "
            "path, one document per argument"
        )
    if argument.endswith("/"):
        raise Refusal(
            f"{argument}: names a directory; land documents one file at a time"
        )
    parts = PurePosixPath(argument).parts
    if any(part in (".", "..") for part in parts) or "" in parts:
        raise Refusal(
            f"{argument}: `.`/`..` components are refused; name the literal "
            "repository-relative path"
        )
    if not argument.endswith(".md"):
        raise Refusal(
            f"{argument}: only Markdown documents land through this command; "
            "everything else takes the pull-request lane"
        )
    return argument


def verify_alias(worktree: Path) -> None:
    """The AGENTS.md alias object must be the tracked, unmodified symlink to
    CLAUDE.md before a selection of it may canonicalize."""
    listed = run_git(worktree, "ls-files", "-s", "--", ROOT_CONTRACT_ALIAS).stdout
    fields = listed.split()
    if not fields or fields[0] != "120000":
        raise Refusal(
            f"{ROOT_CONTRACT_ALIAS}: the tracked alias is no longer a symlink "
            f"to {ROOT_CONTRACT_CANONICAL}; repair it through the pull-request "
            "lane before landing through it"
        )
    status = run_git(
        worktree, "status", "--porcelain", "--", ROOT_CONTRACT_ALIAS
    ).stdout.strip()
    on_disk = worktree / ROOT_CONTRACT_ALIAS
    if (
        status
        or not on_disk.is_symlink()
        or os.readlink(on_disk) != ROOT_CONTRACT_CANONICAL
    ):
        raise Refusal(
            f"{ROOT_CONTRACT_ALIAS}: the alias object has been changed or "
            f"replaced; it must stay a symlink to {ROOT_CONTRACT_CANONICAL}, "
            "and a change to the alias itself takes the pull-request lane"
        )


def assess(
    worktree: Path, rows: dict[str, dict], argument: str
) -> tuple[str | None, str | None]:
    """`(canonical path, refusal)` — exactly one of the two is set.

    The one landability decision, shared by `--gate` and `--inventory` so the
    inventory can never advertise a path the gate would then refuse: shape
    validation, alias canonicalization, symlink and existence checks, and §7
    classification, in that order."""
    try:
        path = validate_shape(argument)
        if path == ROOT_CONTRACT_ALIAS:
            verify_alias(worktree)
            path = ROOT_CONTRACT_CANONICAL
        verify_names_a_document(worktree, path)
    except Refusal as refusal:
        return None, str(refusal)
    refusal_text = classification_refusal(rows, path)
    if refusal_text is not None:
        return None, refusal_text
    return path, None


def verify_names_a_document(worktree: Path, path: str) -> None:
    on_disk = worktree / path
    # A symlinked ancestor would resolve the leaf outside the worktree (or to
    # a different tracked location), so `is_file()` and the classification
    # would both be judging a path the landing does not actually name —
    # publishing external content under a docs path. Refused component by
    # component; the root AGENTS.md alias is a leaf, never an ancestor, so it
    # needs no exemption here.
    ancestor = worktree
    for part in PurePosixPath(path).parts[:-1]:
        ancestor = ancestor / part
        if ancestor.is_symlink():
            raise Refusal(
                f"{path}: ancestor {ancestor.relative_to(worktree)} is a "
                "symlink, so the named path can escape the docs worktree; "
                "symlinked ancestors are refused"
            )
    if on_disk.is_dir():
        raise Refusal(f"{path}: names a directory, not a document")
    if on_disk.is_symlink():
        raise Refusal(
            f"{path}: symlinks other than the verified {ROOT_CONTRACT_ALIAS} "
            "alias are refused"
        )
    tracked = run_git(worktree, "ls-files", "--", path, literal=True).stdout.strip()
    upstream = run_git(
        worktree, "cat-file", "-e", f"{CONTRACT_REF}:{path}", check=False
    )
    if not on_disk.is_file() and not tracked and upstream.returncode != 0:
        raise Refusal(
            f"{path}: names no document — absent from the docs worktree, the "
            f"index, and {CONTRACT_REF}"
        )


def classification_refusal(rows: dict[str, dict], path: str) -> str | None:
    """Why §7 keeps `path` out of the direct lane, or None when it may land."""
    matched = matching_rows(rows, path)
    if not matched:
        return (
            f"{path}: no §7 row in {CONTRACT_PATH} classifies it, and an "
            "unclassified document is pr-atomic to every consumer (fail "
            "closed); add its classification row before landing it"
        )
    if len(matched) > 1:
        return (
            f"{path}: §7 rows {', '.join(matched)} all cover it; a document "
            "with two lanes has no lane, so nothing lands until the rows are "
            "repaired"
        )
    row = rows[matched[0]]
    if path == ROOT_CONTRACT_CANONICAL:
        # The root instruction documents are the sole exception to the gated
        # reasons. assess() canonicalizes the AGENTS.md alias to CLAUDE.md
        # before classification, so exempting the canonical name covers both.
        return None
    gating = [reason for reason in row["reasons"] if reason in GATING_REASONS]
    if gating:
        details = [
            f"{reason} ({REASON_EXPLANATIONS[reason]})" for reason in gating
        ]
        gate = KNOWN_GATES.get(matched[0])
        suffix = f"; {gate}" if gate else ""
        return (
            f"{path}: §7 row {matched[0]!r} declares "
            f"{' and '.join(details)}{suffix}. It lands through a pull "
            "request with what gates it."
        )
    return None


def gate(worktree: Path, arguments: list[str]) -> int:
    rows = contract_rows(worktree)
    canonical: list[str] = []
    refusals: list[str] = []
    for argument in arguments:
        path, refusal_text = assess(worktree, rows, argument)
        if refusal_text is not None:
            refusals.append(refusal_text)
            continue
        if path != argument:
            print(
                f"note: {argument} is the {path} alias; landing {path}",
                file=sys.stderr,
            )
        if path not in canonical:
            canonical.append(path)
    if refusals:
        for refusal in refusals:
            print(f"refused: {refusal}", file=sys.stderr)
        return 2
    if not canonical:
        print("refused: no path names a landable document", file=sys.stderr)
        return 2
    for path in canonical:
        print(path)
    return 0


def worktree_states(worktree: Path) -> dict[str, str]:
    """Two-letter porcelain codes for every changed or untracked path."""
    states: dict[str, str] = {}
    out = run_git(worktree, "status", "--porcelain", "--", "*.md").stdout
    for line in out.splitlines():
        if len(line) > 3:
            path = line[3:]
            if " -> " in path:
                path = path.split(" -> ", 1)[1]
            states[path.strip('"')] = line[:2]
    return states


def describe_state(code: str | None) -> str:
    if code is None:
        return "clean"
    if code == "??":
        return "untracked"
    index, work = code[0], code[1]
    described = []
    if index == "D" or work == "D":
        described.append("deleted")
    if index == "T" or work == "T":
        described.append("typechange")
    if index not in (" ", "?", "D"):
        described.append("staged")
    if work == "M":
        described.append("modified")
    return "+".join(described) if described else code.strip() or "clean"


def inventory(worktree: Path) -> int:
    rows = contract_rows(worktree)
    states = worktree_states(worktree)
    tracked = set(
        run_git(worktree, "ls-files", "--", "*.md").stdout.splitlines()
    )
    differing = set(
        run_git(
            worktree, "diff", "--name-only", CONTRACT_REF, "--", "*.md"
        ).stdout.splitlines()
    )
    # Ignored untracked documents are invisible to `status --porcelain`, but
    # an ignored file under a classified directory is still a landable
    # document the no-argument workflow must be able to offer.
    ignored = set(
        run_git(
            worktree, "ls-files", "--others", "--ignored",
            "--exclude-standard", "--", "*.md",
        ).stdout.splitlines()
    )
    universe = sorted(tracked | differing | set(states) | ignored)
    print("path | tracked | state | vs origin/master | §7 row | lane | landable")
    for path in universe:
        if path in ignored and path not in states:
            state = "ignored"
        else:
            state = describe_state(states.get(path))
        is_tracked = "yes" if path in tracked else "no"
        differs = "differs" if path in differing or path not in tracked else "same"
        matched = matching_rows(rows, path)
        row_name = matched[0] if len(matched) == 1 else ("none" if not matched else "multiple")
        lane = rows[matched[0]]["klass"] if len(matched) == 1 else "-"
        canonical_path, refusal_text = assess(worktree, rows, path)
        if refusal_text is not None:
            landable = f"no ({refusal_text})"
        elif canonical_path != path:
            landable = f"yes (as {canonical_path})"
        else:
            landable = "yes"
        print(
            f"{path} | {is_tracked} | {state} | {differs} | {row_name} | "
            f"{lane} | {landable}"
        )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--worktree", required=True, type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--gate", action="store_true")
    mode.add_argument("--inventory", action="store_true")
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args(argv)
    worktree = args.worktree
    if not (worktree / ".git").exists():
        raise SystemExit(f"{worktree} is not a Git worktree")
    if args.inventory:
        if args.paths:
            parser.error("--inventory takes no paths")
        return inventory(worktree)
    if not args.paths:
        parser.error("--gate needs at least one path")
    return gate(worktree, args.paths)


if __name__ == "__main__":
    raise SystemExit(main())
