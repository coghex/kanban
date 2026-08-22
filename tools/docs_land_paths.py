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
  name into two), the exact spelling of what is on disk and tracked (a name
  differing only by case would publish a case-conflicting tree entry through
  a case-insensitive filesystem), and no symlinks — leaf or ancestor, since a
  symlinked directory resolves the leaf outside the worktree — other than the
  verified `AGENTS.md` alias.
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
ignored, deleted, or present only on the publication tip — with its state, its
§7 row and lane, how it stands against the fetched `origin/master`, and whether
it is a ready landing candidate. Both modes are read-only.

Issue #438. That `origin/master` comparison names a DIRECTION rather than a
bare difference, because documents reach master through two lanes that never
touch this worktree — pull requests carrying pr-atomic documents, and
`tools/publish_coordination_doc.py` — so a differing document is as likely to
be upstream's newer text as it is to be work waiting to land. Direction is
read against the merge base of `HEAD` and the publication tip: only the local
side moved is `differs` (ahead, the landing candidate), only upstream moved is
`behind`, both moved is `diverged`, and an upstream-only addition — absent at
the merge base and here, present upstream — is `absent-here`. The `landable`
column keeps answering the §7/path POLICY question alone; `readiness` is the
separate operational one, so a behind, diverged, or absent-here row states
that it is not a candidate and names its remedy.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import unicodedata
from pathlib import Path, PurePosixPath


def fold_key(text: str) -> str:
    """The comparison key for filesystem-collision checks: NFC-normalized,
    Unicode-case-folded. `lower()` misses fold pairs such as Σ/ς, and macOS
    filesystems treat NFC and NFD spellings of one name as the same file, so
    both normalizations belong in the key."""
    return unicodedata.normalize("NFC", text).casefold()

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
    # utf-8 with surrogateescape rather than the locale's codec: filenames
    # are bytes, and a C locale must not make a café.md unreadable.
    proc = subprocess.run(
        ["git", "-C", str(worktree), *args],
        capture_output=True,
        encoding="utf-8",
        errors="surrogateescape",
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
    # Split on the raw string, not PurePosixPath: the latter silently
    # normalizes `.` components and repeated slashes away, so a
    # non-canonical spelling would pass here and then fail deep inside
    # `git update-index` as an invalid path.
    if any(part in ("", ".", "..") for part in argument.split("/")):
        raise Refusal(
            f"{argument}: `.`/`..`/empty components are refused; name the "
            "canonical repository-relative path"
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


def verify_exact_spelling(worktree: Path, path: str) -> None:
    """Refuse a name that reaches a document only through case folding.

    On a case-insensitive filesystem `is_file()` answers yes for
    `docs/coordination/readme.md` when the document is `README.md`, while
    every exact Git lookup answers no — and landing the folded spelling would
    publish a second, case-conflicting tree entry. The walk compares each
    component against the parent directory's actual entries textually, so it
    behaves identically on case-sensitive and case-insensitive filesystems."""
    parent = worktree
    for part in PurePosixPath(path).parts:
        try:
            entries = os.listdir(parent)
        except OSError:
            # The parent is gone (a deletion); the exact Git lookups below
            # decide whether the name still names anything.
            return
        if part not in entries:
            folded = sorted(
                entry for entry in entries if fold_key(entry) == fold_key(part)
            )
            if folded:
                raise Refusal(
                    f"{path}: case-mismatched spelling — this component is "
                    f"{folded[0]!r} on disk; name the exact spelling, or the "
                    "landing would publish a case-conflicting second entry"
                )
            return
        parent = parent / part


_CASEFOLD_KNOWN: dict[str, dict[str, set[str]]] = {}


def casefold_collision(worktree: Path, path: str) -> str | None:
    """An existing tracked or upstream spelling that `path` (or one of its
    directory prefixes) equals under case folding without equalling exactly,
    or None. This is the filesystem-independent half of the exact-spelling
    guarantee: a genuinely distinct file created on a case-sensitive
    filesystem must not land beside an entry it case-collides with, because
    the published tree could then never check out case-insensitively."""
    key = str(worktree)
    known = _CASEFOLD_KNOWN.get(key)
    if known is None:
        entries = {
            entry
            for entry in run_git(worktree, "ls-files", "-z").stdout.split("\0")
            if entry
        }
        entries |= {
            entry
            for entry in run_git(
                worktree, "ls-tree", "-r", "-z", "--name-only", CONTRACT_REF
            ).stdout.split("\0")
            if entry
        }
        known = {}
        for entry in entries:
            parts = PurePosixPath(entry).parts
            for depth in range(1, len(parts) + 1):
                prefix = "/".join(parts[:depth])
                known.setdefault(fold_key(prefix), set()).add(prefix)
        _CASEFOLD_KNOWN[key] = known
    parts = PurePosixPath(path).parts
    for depth in range(1, len(parts) + 1):
        prefix = "/".join(parts[:depth])
        spellings = known.get(fold_key(prefix))
        if spellings and prefix not in spellings:
            return sorted(spellings)[0]
    return None


def upstream_object_type(worktree: Path, path: str) -> str | None:
    """The object type at `path` on the publication tip, or None when the
    tip has nothing there."""
    proc = run_git(
        worktree, "cat-file", "-t", f"{CONTRACT_REF}:{path}", check=False
    )
    return proc.stdout.strip() if proc.returncode == 0 else None


def selection_nesting_conflicts(paths: list[str]) -> list[list[str]]:
    """Pairs among `paths` where one is a whole-component prefix of another.
    A tree cannot hold `docs/x.md` as a file and `docs/x.md/y.md` beneath it
    at once, so such a selection must refuse rather than reach the index
    build as a plumbing error."""
    conflicts: list[list[str]] = []
    for one in paths:
        for other in paths:
            if one != other and row_covers(one + "/", other):
                pair = sorted([one, other])
                if pair not in conflicts:
                    conflicts.append(pair)
    return conflicts


def selection_casefold_conflicts(paths: list[str]) -> list[list[str]]:
    """Groups of distinct spellings among `paths` — or their directory
    prefixes — that fold to the same name. `casefold_collision` compares a
    name against what already exists; this compares the selection against
    itself, because on a case-sensitive filesystem one invocation can name
    two genuinely distinct new documents whose spellings differ only by
    case, and a tree carrying both could never check out case-insensitively."""
    seen: dict[str, set[str]] = {}
    for path in paths:
        parts = PurePosixPath(path).parts
        for depth in range(1, len(parts) + 1):
            prefix = "/".join(parts[:depth])
            seen.setdefault(fold_key(prefix), set()).add(prefix)
    return [
        sorted(variants)
        for _, variants in sorted(seen.items())
        if len(variants) > 1
    ]


def verify_names_a_document(worktree: Path, path: str) -> None:
    on_disk = worktree / path
    verify_exact_spelling(worktree, path)
    collision = casefold_collision(worktree, path)
    if collision is not None:
        raise Refusal(
            f"{path}: differs only by case from the existing {collision!r}; "
            "name the exact spelling — a second entry differing only by case "
            "cannot be checked out on a case-insensitive filesystem"
        )
    # The landing commit is built directly on the publication tip, so the
    # named path must fit that tree's topology: a file (or symlink) at an
    # ancestor position there, or a directory at the leaf, would otherwise
    # surface as a raw index-plumbing error instead of a refusal.
    parts = PurePosixPath(path).parts
    for depth in range(1, len(parts)):
        prefix = "/".join(parts[:depth])
        if upstream_object_type(worktree, prefix) == "blob":
            raise Refusal(
                f"{path}: {prefix} is a file on {CONTRACT_REF}, so nothing "
                "can land beneath it"
            )
    if upstream_object_type(worktree, path) == "tree":
        raise Refusal(
            f"{path}: is a directory on {CONTRACT_REF}; land documents one "
            "file at a time"
        )
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
    if on_disk.exists() and not on_disk.is_file():
        # A FIFO, socket, or device where the document should be: reading it
        # to hash could block indefinitely, so it never reaches
        # `git hash-object` — not even for a dry-run plan. A genuinely
        # absent path remains the deletion case below.
        raise Refusal(
            f"{path}: is not a regular file on disk; only regular Markdown "
            "documents land"
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
    for variants in selection_casefold_conflicts(canonical):
        refusals.append(
            f"{' and '.join(variants)}: differ only by case within one "
            "selection, and a tree carrying both could never check out on a "
            "case-insensitive filesystem"
        )
    for pair in selection_nesting_conflicts(canonical):
        refusals.append(
            f"{' and '.join(pair)}: one selected path nests beneath the "
            "other, and a tree cannot carry both"
        )
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
    """Two-letter porcelain codes for every changed or untracked path.

    NUL-delimited (`-z`) rather than line-based: Git C-quotes filenames
    containing quotes or non-ASCII bytes in newline output, and a parser
    stripping quotes would report `caf\\303\\251.md` for a document really
    named `café.md`. With `-z` every path arrives verbatim; a rename or copy
    record is followed by its source path as its own NUL-delimited field."""
    states: dict[str, str] = {}
    records = run_git(
        worktree, "status", "--porcelain", "-z", "--", "*.md"
    ).stdout.split("\0")
    index = 0
    while index < len(records):
        record = records[index]
        index += 1
        if len(record) < 4:
            continue
        code, path = record[:2], record[3:]
        states[path] = code
        if code[0] in ("R", "C"):
            # The record after a rename or copy is the SOURCE path. A rename
            # leaves its source staged for deletion, and dropping it here
            # would show the renamed-away document as clean — inviting a
            # selection that omits the necessary deletion.
            if index < len(records) and records[index]:
                if code[0] == "R":
                    states.setdefault(records[index], "D ")
            index += 1
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
    if index == "R" or work == "R":
        described.append("renamed")
    if index == "T" or work == "T":
        described.append("typechange")
    if index not in (" ", "?", "D"):
        described.append("staged")
    if work == "M":
        described.append("modified")
    return "+".join(described) if described else code.strip() or "clean"


# How each `vs origin/master` value reads in the `readiness` column: whether
# the row is an ordinary landing candidate, and when it is not, the state and
# the remedy. Landing a behind or absent-here path would replace upstream's
# newer text with this worktree's older copy — or delete the document
# outright — so those rows must never read like the ahead ones.
READINESS = {
    "same": "nothing to land",
    "differs": "ready",
    "behind": (
        "not ready: only origin/master moved since the merge base, so this "
        "copy is the older one; rebase docs-wip onto origin/master, then "
        "rerun -l"
    ),
    "absent-here": (
        "not ready: origin/master added this document and this worktree has "
        "no copy, so landing it would delete it; rebase docs-wip onto "
        "origin/master, then rerun -l"
    ),
    "diverged": (
        "not ready: both sides changed since the merge base; rebase docs-wip "
        "or resolve this path, then rerun -l"
    ),
}


def merge_base(worktree: Path) -> str:
    """The merge base of the docs worktree's HEAD and the publication tip.

    Every direction below is read against this commit rather than against the
    tip: comparing with the tip alone answers only *whether* two texts differ,
    which is precisely the conflation this exists to end. A worktree with no
    common ancestor cannot be landed from either — tools/docs_land.sh builds
    its own risk checks on the same merge base — so the inventory stops with
    the reason rather than guessing a direction."""
    proc = run_git(worktree, "merge-base", "HEAD", CONTRACT_REF, check=False)
    base = proc.stdout.strip()
    if proc.returncode != 0 or not base:
        raise SystemExit(
            f"{worktree} shares no history with {CONTRACT_REF}, so no "
            "document's direction can be read; nothing lands from a worktree "
            f"that is not descended from {CONTRACT_REF}"
        )
    return base


def name_set(worktree: Path, *args: str) -> set[str]:
    """A NUL-delimited `git` name listing as a set, empty entries dropped.

    NUL-delimited for the same reason every other listing here is: newline
    output C-quotes a filename carrying quotes or non-ASCII bytes, and a
    direction keyed by `caf\\303\\251.md` would silently never match the
    document really named `café.md`."""
    return {
        entry
        for entry in run_git(worktree, *args).stdout.split("\0")
        if entry
    }


def local_change_set(
    worktree: Path, base: str, states: dict[str, str], ignored: set[str]
) -> set[str]:
    """Documents whose LOCAL side moved since `base`.

    `git diff <base>` against the working tree covers the committed, staged,
    unstaged, deleted, and executable-mode changes of tracked documents in one
    reading. It says nothing about untracked or ignored files, though — they
    are not in the index for it to compare — so both are added here: a
    document that exists only in this worktree is local work whatever its
    bytes happen to equal upstream, and trackedness stays significant."""
    changed = name_set(
        worktree, "diff", "--name-only", "-z", "--no-renames", base, "--", "*.md"
    )
    changed |= {path for path, code in states.items() if code == "??"}
    changed |= ignored
    return changed


def divergence(
    worktree: Path,
    path: str,
    differs: bool,
    local_changed: bool,
    upstream_changed: bool,
    base_paths: set[str],
    upstream_paths: set[str],
    tracked: set[str],
) -> str:
    """One document's direction against `origin/master`.

    `differs` is the inventory's existing local-versus-tip answer and is
    preserved exactly: a document that already read `same` still does, and a
    direction is only ever named for one that already read `differs`. Within
    that, the three-way split is by which side moved from the merge base, with
    the upstream-only addition broken out as its own subtype — the state that
    looks most like a landing candidate and is in fact a deletion."""
    if not differs:
        return "same"
    if upstream_changed and not local_changed:
        if (
            path not in base_paths
            and path in upstream_paths
            and path not in tracked
            and not os.path.lexists(worktree / path)
        ):
            return "absent-here"
        return "behind"
    if upstream_changed and local_changed:
        return "diverged"
    # Only the local side moved — or neither did, which an untracked document
    # holding upstream's exact bytes reaches. Both are ahead: landing either
    # replaces nothing upstream that this worktree has not already seen.
    return "differs"


def inventory(worktree: Path) -> int:
    rows = contract_rows(worktree)
    states = worktree_states(worktree)
    # Every listing is NUL-delimited for the same reason worktree_states is:
    # newline output C-quotes unusual filenames, and the inventory must show
    # every document by its real name.
    tracked = name_set(worktree, "ls-files", "-z", "--", "*.md")
    differing = name_set(
        worktree, "diff", "--name-only", "-z", "--no-renames",
        CONTRACT_REF, "--", "*.md",
    )
    # Ignored untracked documents are invisible to `status --porcelain`, but
    # an ignored file under a classified directory is still a landable
    # document the no-argument workflow must be able to offer.
    ignored = name_set(
        worktree, "ls-files", "-z", "--others", "--ignored",
        "--exclude-standard", "--", "*.md",
    )
    # The merge base and the two trees around it: which side of it a document
    # moved on is what separates a landing candidate from a revert.
    base = merge_base(worktree)
    local_changed = local_change_set(worktree, base, states, ignored)
    upstream_changed = name_set(
        worktree, "diff", "--name-only", "-z", "--no-renames",
        base, CONTRACT_REF, "--", "*.md",
    )
    # Whole-tree name listings rather than a `*.md` pathspec, matching
    # casefold_collision's reading: these answer only membership questions.
    base_paths = name_set(worktree, "ls-tree", "-r", "-z", "--name-only", base)
    upstream_paths = name_set(
        worktree, "ls-tree", "-r", "-z", "--name-only", CONTRACT_REF
    )
    universe = sorted(tracked | differing | set(states) | ignored)
    print(
        "path | tracked | state | vs origin/master | §7 row | lane | "
        "readiness | landable"
    )
    for path in universe:
        if path in ignored and path not in states:
            state = "ignored"
        elif (
            path not in tracked
            and path not in states
            and not os.path.lexists(worktree / path)
        ):
            # An upstream-only addition reaches the universe through the
            # comparison with the tip while having no local presence at all.
            # `clean` would be a plain lie about a document that is not here.
            state = "absent"
        else:
            state = describe_state(states.get(path))
        is_tracked = "yes" if path in tracked else "no"
        differs = path in differing or path not in tracked
        direction = divergence(
            worktree, path, differs, path in local_changed,
            path in upstream_changed, base_paths, upstream_paths, tracked,
        )
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
            f"{path} | {is_tracked} | {state} | {direction} | {row_name} | "
            f"{lane} | {READINESS[direction]} | {landable}"
        )
    return 0


def main(argv: list[str] | None = None) -> int:
    # Emit utf-8 whatever the locale says: the inventory prints filenames,
    # and a C locale must not turn café.md into an encoding error.
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="backslashreplace")
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
