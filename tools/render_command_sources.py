"""Render one authored command source into both plugin bundle layouts.

Run with: python3 tools/render_command_sources.py [--check]

Issue #375, slice VEND-0 of `docs/workflow_command_vendoring_design.md`. Its
D-3 decides the vendored workflow commands are authored once and rendered into
both bundles rather than maintained as two hand-edited copies, because the two
personal copies of every command have already drifted — `project-review`'s by
223 lines. This module is that mechanism, built and proved before any command
is vendored so the reconciliation cost is paid once.

Three differences separate the two layouts, and a renderer that reconciles only
some of them ships a broken asset:

* **File layout.** Claude reads `commands/<name>.md`; Codex reads
  `skills/<name>/SKILL.md`.
* **Frontmatter keys.** Claude declares `description` and `argument-hint`;
  Codex declares `name` and `description`. The projection here is an
  allowlist per brand, and the source's own key set is an allowlist too, so a
  `model:` or `permission-mode:` key that would override the model, effort, or
  permission mode Kanban's CLI spawn already pins
  (`docs/agent-workflow-contract.md` §2.1-§2.2) cannot reach a rendered file at
  all — the same keys `tools/test_claude_plugin.py` forbids in the shipped
  bundle, refused one step earlier.
* **Invocation sigil.** Claude workflows are named `/solve`, Codex skills
  `$solve`, throughout the prose and not only in frontmatter. A renderer that
  rewrote paths and keys alone would emit a Codex skill telling its reader to
  type `/solve`.

The sigil is handled by writing every workflow reference as one neutral
`{{cmd:<name>}}` token, which picks up its brand's sigil at render time. A
pattern that rewrote bare `/name` text instead would have to decide, for every
slash in the file, whether it opened a workflow name — and `/dev/null`,
`/tmp/scratch`, `https://github.com/coghex/kanban` and `and/or` all read like
one under some spelling of that rule. The token has no such ambiguity, so
requirement "rewrite invocations, and nothing else" holds by construction.

The token's own failure mode is an author who types `/solve` literally instead,
which would render identically for Claude and wrongly for Codex. So rendering
also refuses a literal sigil-prefixed occurrence of any name in
`workflow_vocabulary()`: every workflow either bundle already ships, every
registered source name, plus the source's own name and its `{{cmd:}}` targets.
That refusal is what makes the token load-bearing rather than a convention. The
vocabulary is read from the tree rather than restated here, so it grows as this
arc vendors commands; a name no bundle ships and no source names yet — one of
the eight still awaiting its slice — is outside it until then, which is why the
vocabulary fails loudly when a bundle directory is missing instead of quietly
shrinking to nothing.

Deliberate per-brand *body* text — argument conventions and installed-helper
resolution, which `docs/workflow_command_vendoring_design.md` D-2/D-7 require to
survive reconciliation — stays authored in the one source, inside a
`<!-- brand:claude -->` / `<!-- brand:codex -->` / `<!-- /brand -->` block. The
shipped `solve` pair needs exactly that: `$ARGUMENTS` against a prompt argument,
`${CLAUDE_PLUGIN_ROOT}` against a `$CODEX_HOME` search. A block naming only one
brand renders as nothing at all for the other.

`COMMAND_SOURCES` is the registry, and `--check` re-renders every entry and
byte-compares it against the tracked output, so a source edited without
re-rendering fails `tools/test_render_command_sources.py` in the required
`build-test` job. A one-time `render && git diff --exit-code` demonstration
would not: it proves the mechanism ran once, never that it keeps being run.

The registry holds two kinds of entry, and the difference is the output
directory alone. VEND-0's fixture renders under `tools/`, deliberately outside
`claude-plugin/.../commands/` and `codex-plugin/.../skills/`, because
`tools/plugin_bundle_gate.py` takes shippedness from location: anything
rendered into either bundle directory becomes invokable and gate-relevant, and
the fixture vendors no command. `triage` — VEND-1, the first real rendering —
renders into those two bundle directories and is therefore shipped, named by
both bundles' manifests and discovered by both providers.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

BRANDS = ("claude", "codex")

# How each provider spells a workflow invocation.
SIGILS = {"claude": "/", "codex": "$"}

# Where each provider discovers the workflows it ships. Read to build the
# vocabulary the literal-sigil refusal is measured against, never written by
# this module: VEND-0 vendors no command.
CLAUDE_COMMANDS_DIR = "claude-plugin/plugins/kanban/commands"
CODEX_SKILLS_DIR = "codex-plugin/plugins/kanban/skills"

# The frontmatter each brand's loader reads, in the order it is written. A key
# absent from the source is simply omitted; a key absent from a brand's tuple
# never reaches that brand's file.
BRAND_FRONTMATTER_KEYS = {
    "claude": ("description", "argument-hint"),
    "codex": ("name", "description"),
}

# What an authored source may declare — an allowlist, so an override key fails
# rendering rather than reaching a bundle.
SOURCE_FRONTMATTER_KEYS = ("name", "description", "argument-hint")
REQUIRED_FRONTMATTER_KEYS = ("name", "description")

# A sigil-prefixed workflow identifier as `tools/plugin_bundle_gate.py` spells
# it, character-for-character — one notion of where a workflow token may start,
# reconciled by a test rather than by an import, because this module is loaded
# both as a bare top-level name and from a `tools.` namespace package.
IDENTIFIER_PATTERNS = {
    "/": re.compile(r"(?<![\w/.-])/([a-z][a-z0-9]*(?:-[a-z0-9]+)*)"),
    "$": re.compile(r"(?<![\w$])\$([a-z][a-z0-9]*(?:-[a-z0-9]+)*)"),
}

# Where such a token may *end*, which the manifest gate does not need and this
# module does. That gate scans short manifest strings and an over-long match
# only ever reports a name the bundle does not ship; this scans whole workflow
# bodies and *refuses the file*, so a false positive blocks legitimate text —
# `/solve/cache` is a path whose first component happens to be a workflow name,
# and `$solve_result` a shell variable that merely starts with one. Neither is
# an invocation. A trailing `.` still ends a token, because prose really does
# end a sentence on one; a `.` that opens a file extension does not.
TOKEN_TAIL = r"(?![\w/-]|\.\w)"

LITERAL_INVOCATION_PATTERNS = {
    sigil: re.compile(pattern.pattern + TOKEN_TAIL)
    for sigil, pattern in IDENTIFIER_PATTERNS.items()
}

WORKFLOW_NAME_RE = re.compile(r"\A[a-z][a-z0-9]*(?:-[a-z0-9]+)*\Z")

FRONTMATTER_RE = re.compile(
    r"\A---\n(?P<frontmatter>.*?)\n---\n(?P<body>.*)\Z", re.DOTALL
)
FIELD_RE = re.compile(r"\A(?P<key>[A-Za-z][A-Za-z0-9_-]*): (?P<value>\S.*)\Z")

BRAND_OPEN_RE = re.compile(r"\A<!--\s*brand:(?P<brand>[a-z][a-z0-9-]*)\s*-->[ \t]*\Z")
BRAND_CLOSE_RE = re.compile(r"\A<!--\s*/brand\s*-->[ \t]*\Z")

COMMAND_REF_RE = re.compile(r"\{\{cmd:(?P<name>[a-z][a-z0-9]*(?:-[a-z0-9]+)*)\}\}")
DIRECTIVE_RE = re.compile(r"\{\{.*?\}\}", re.DOTALL)

# The repair every stale-artifact failure names, kept as one constant so the
# test asserts the words the failure actually prints.
RENDER_INSTRUCTION = "run `python3 tools/render_command_sources.py`"


class CommandSourceError(RuntimeError):
    """An authored source could not be rendered — distinct from a rendered
    output that is merely out of date."""


@dataclass(frozen=True)
class CommandSource:
    """One authored source and the two directories it renders into.

    The output directories are per entry rather than global constants: a
    vendored command renders into the two bundles, while VEND-0's fixture
    renders outside both so nothing new becomes invokable.
    """

    name: str
    source: str
    claude_commands_dir: str
    codex_skills_dir: str
    note: str


COMMAND_SOURCES = (
    CommandSource(
        name="fixture-command",
        source="tools/command_sources/fixture-command.md",
        claude_commands_dir="tools/command_render_fixture/claude/commands",
        codex_skills_dir="tools/command_render_fixture/codex/skills",
        note=(
            "VEND-0's proof fixture. Its outputs mirror each bundle's layout "
            "but land under tools/, so the mechanism is exercised end to end "
            "without adding an invokable command to either bundle."
        ),
    ),
    CommandSource(
        name="triage",
        source="tools/command_sources/triage.md",
        claude_commands_dir=CLAUDE_COMMANDS_DIR,
        codex_skills_dir=CODEX_SKILLS_DIR,
        note=(
            "VEND-1, the first vendored workflow. Unlike the fixture above it "
            "renders into both bundle directories, so both providers ship it "
            "and tools/plugin_bundle_gate.py sees it as shipped."
        ),
    ),
    CommandSource(
        name="push-docs",
        source="tools/command_sources/push-docs.md",
        claude_commands_dir=CLAUDE_COMMANDS_DIR,
        codex_skills_dir=CODEX_SKILLS_DIR,
        note=(
            "Issue #410's documentation-landing workflow. Both brands invoke "
            "the tracked tools/docs_land.sh identically, so the two rendered "
            "assets differ only in argument conventions and sigils."
        ),
    ),
    CommandSource(
        name="retriage",
        source="tools/command_sources/retriage.md",
        claude_commands_dir=CLAUDE_COMMANDS_DIR,
        codex_skills_dir=CODEX_SKILLS_DIR,
        note=(
            "VEND-2, the roadmap refresh that reads triage's own sections "
            "back. It names triage through {{cmd:triage}} rather than a "
            "literal sigil, which is the case the token was built for: the "
            "one command in the registry whose body references another."
        ),
    ),
    CommandSource(
        name="backlog-review",
        source="tools/command_sources/backlog-review.md",
        claude_commands_dir=CLAUDE_COMMANDS_DIR,
        codex_skills_dir=CODEX_SKILLS_DIR,
        note=(
            "VEND-3, the first vendored workflow that closes issues and "
            "rewrites their bodies. Its brand blocks carry text one provider "
            "has and the other does not — two Codex sandbox caveats with no "
            "Claude counterpart — rather than two spellings of one sentence."
        ),
    ),
    CommandSource(
        name="project-review",
        source="tools/command_sources/project-review.md",
        claude_commands_dir=CLAUDE_COMMANDS_DIR,
        codex_skills_dir=CODEX_SKILLS_DIR,
        note=(
            "VEND-4, the heaviest reconciliation in the arc: 223 differing "
            "lines between a 79-line Claude copy that drafted and filed issue "
            "bodies and a 220-line Codex copy that forbids tracker writes and "
            "writes a findings report instead. Design D-9 resolved the two "
            "opposite terminal behaviors in favour of the Codex copy, so the "
            "rendered command is report-only for both brands. D-10 keeps its "
            "boundary rule as body prose and ships no auxiliary asset, which "
            "is why this entry needs nothing from the renderer that the four "
            "above did not."
        ),
    ),
    CommandSource(
        name="drain-prs",
        source="tools/command_sources/drain-prs.md",
        claude_commands_dir=CLAUDE_COMMANDS_DIR,
        codex_skills_dir=CODEX_SKILLS_DIR,
        note=(
            "VEND-5, the first vendored workflow whose reconciliation is "
            "mostly against this repository rather than against the other "
            "brand: both personal copies described a drainer that no longer "
            "exists, so five stale claims were dropped and the controller's "
            "hardcoded macOS path replaced by the portable resolution "
            "docs/pr-drainer.md documents. Design D-7 resolved the subcommand "
            "gap in the richer Claude copy's favour, so both brands now "
            "document all nine control operations."
        ),
    ),
)


def output_paths(entry: CommandSource) -> dict[str, str]:
    """The repository-relative file each brand renders to."""
    return {
        "claude": f"{entry.claude_commands_dir}/{entry.name}.md",
        "codex": f"{entry.codex_skills_dir}/{entry.name}/SKILL.md",
    }


def workflow_vocabulary(repo_root: Path = REPO_ROOT) -> set[str]:
    """Every name this mechanism knows to be a workflow.

    Discovered from the tree — the stem of each shipped Claude command and the
    directory of each shipped Codex skill — plus the registered authored
    sources, so it never has to be restated as a list that could go stale.

    A missing bundle directory raises rather than returning a smaller set: the
    vocabulary is what the literal-sigil refusal is measured against, and one
    that quietly shrank to nothing would turn that refusal off while every
    render still reported success.
    """
    names = {entry.name for entry in COMMAND_SOURCES}
    commands = repo_root / CLAUDE_COMMANDS_DIR
    skills = repo_root / CODEX_SKILLS_DIR
    for directory in (commands, skills):
        if not directory.is_dir():
            raise CommandSourceError(
                f"{directory} is not a directory, so the workflow vocabulary "
                "cannot be read from the tree; render from a checkout that "
                "carries both plugin bundles"
            )
    names |= {path.stem for path in commands.glob("*.md")}
    names |= {path.parent.name for path in skills.glob("*/SKILL.md")}
    return names


def parse_source(text: str, *, origin: str) -> tuple[dict[str, str], str, int]:
    """`(frontmatter fields, body, body's first line number)`.

    Deliberately not a YAML parse: what both loaders read is a flat block of
    `key: value` lines, and accepting more than that here would let a source
    declare something only one brand's loader could interpret.
    """
    match = FRONTMATTER_RE.match(text)
    if match is None:
        raise CommandSourceError(
            f"{origin}: an authored command source must open with a `---` "
            "frontmatter block closed by a `---` line of its own"
        )
    fields: dict[str, str] = {}
    for offset, line in enumerate(match.group("frontmatter").splitlines()):
        lineno = offset + 2
        field = FIELD_RE.match(line)
        if field is None:
            raise CommandSourceError(
                f"{origin}:{lineno}: frontmatter must be `key: value` lines; "
                f"got {line!r}"
            )
        key = field.group("key")
        if key in fields:
            raise CommandSourceError(f"{origin}:{lineno}: duplicate frontmatter key {key!r}")
        if key not in SOURCE_FRONTMATTER_KEYS:
            raise CommandSourceError(
                f"{origin}:{lineno}: unsupported frontmatter key {key!r}; an "
                f"authored source declares only {', '.join(SOURCE_FRONTMATTER_KEYS)}"
            )
        fields[key] = field.group("value").rstrip()
    missing = [key for key in REQUIRED_FRONTMATTER_KEYS if key not in fields]
    if missing:
        raise CommandSourceError(
            f"{origin}: frontmatter must declare {', '.join(missing)}"
        )
    if not WORKFLOW_NAME_RE.match(fields["name"]):
        raise CommandSourceError(
            f"{origin}: {fields['name']!r} is not a workflow name; both providers "
            "take the name from a lowercase hyphenated file or directory name"
        )
    body_line = text[: match.start("body")].count("\n") + 1
    return fields, match.group("body"), body_line


def select_brand(body: str, brand: str, *, origin: str, body_line: int) -> str:
    """`body` with every brand block resolved for `brand`.

    A block opens with `<!-- brand:<name> -->`, may switch variant with another
    such marker, and closes with `<!-- /brand -->`. Marker lines never reach the
    output, and a brand the block does not name contributes nothing — which is
    how a single-branch block expresses text one provider has and the other
    does not.

    A block that contributes nothing would otherwise leave the blank line above
    it and the blank line below it adjacent, so one brand's file carries a gap
    the other's does not. When an elided block is preceded by a blank line, the
    blank line that follows it is consumed with it. Only then: consuming it
    after a non-blank line would run two paragraphs together.
    """
    kept: list[str] = []
    open_line: int | None = None
    active: str | None = None
    seen: set[str] = set()
    emitted = False
    squeeze = False
    for offset, line in enumerate(body.splitlines(keepends=True)):
        lineno = body_line + offset
        stripped = line.rstrip("\n")
        opened = BRAND_OPEN_RE.match(stripped)
        closed = BRAND_CLOSE_RE.match(stripped)
        if squeeze and opened is None and closed is None:
            squeeze = False
            if not stripped.strip():
                continue
        if opened is not None:
            named = opened.group("brand")
            if named not in BRANDS:
                raise CommandSourceError(
                    f"{origin}:{lineno}: unknown brand {named!r}; the brands are "
                    f"{', '.join(BRANDS)}"
                )
            if open_line is None:
                open_line = lineno
                seen = set()
                emitted = False
            elif named in seen:
                raise CommandSourceError(
                    f"{origin}:{lineno}: brand {named!r} appears twice in the block "
                    f"opened at line {open_line}"
                )
            seen.add(named)
            active = named
            continue
        if closed is not None:
            if open_line is None:
                raise CommandSourceError(
                    f"{origin}:{lineno}: `<!-- /brand -->` closes no open brand block"
                )
            open_line = None
            active = None
            squeeze = not emitted and (not kept or not kept[-1].strip())
            continue
        if open_line is not None and active != brand:
            continue
        kept.append(line)
        if open_line is not None:
            emitted = True
    if open_line is not None:
        raise CommandSourceError(
            f"{origin}:{open_line}: brand block is never closed by `<!-- /brand -->`"
        )
    return "".join(kept)


def referenced_names(text: str) -> set[str]:
    """Every workflow `text` names through a `{{cmd:}}` token."""
    return {match.group("name") for match in COMMAND_REF_RE.finditer(text)}


def validate_directives(text: str, *, origin: str) -> None:
    """Refuse any `{{...}}` that is not a command reference.

    Checked over the whole source rather than over the text one brand keeps,
    so a mistyped directive inside a block the rendered brand elides is still
    refused; otherwise it would ship as literal braces the first time the other
    brand rendered.
    """
    for match in DIRECTIVE_RE.finditer(text):
        if COMMAND_REF_RE.fullmatch(match.group(0)) is None:
            raise CommandSourceError(
                f"{origin}: unsupported directive {match.group(0)!r}; the only "
                "directive is {{cmd:<workflow-name>}}"
            )


def substitute_references(text: str, brand: str) -> str:
    """`text` with every `{{cmd:<name>}}` replaced by `brand`'s spelling."""
    sigil = SIGILS[brand]
    return COMMAND_REF_RE.sub(lambda match: sigil + match.group("name"), text)


def literal_invocation_failures(text: str, names: set[str], *, origin: str) -> list[str]:
    """Sigil-prefixed spellings of a known workflow written literally.

    Marker lines are dropped first (`<!-- /brand -->` would otherwise read as
    an invocation of a workflow called `brand`), and `{{cmd:}}` tokens are
    blanked, so what remains is only text the author typed with a sigil.
    """
    lintable = COMMAND_REF_RE.sub(
        " ",
        "".join(
            line
            for line in text.splitlines(keepends=True)
            if not BRAND_OPEN_RE.match(line.rstrip("\n"))
            and not BRAND_CLOSE_RE.match(line.rstrip("\n"))
        ),
    )
    failures = set()
    for sigil, pattern in LITERAL_INVOCATION_PATTERNS.items():
        for match in pattern.finditer(lintable):
            name = match.group(1)
            if name in names:
                failures.add(
                    f"{origin}: {sigil}{name} is written with a literal sigil; "
                    f"an authored source names a workflow as {{{{cmd:{name}}}}} so "
                    "both brands render their own"
                )
    return sorted(failures)


def render(
    entry: CommandSource, source_text: str, brand: str, vocabulary: set[str]
) -> str:
    """One authored source rendered for one brand.

    `vocabulary` is the workflow-name set the literal-sigil refusal is measured
    against — `workflow_vocabulary()` in every non-test caller. It is a
    parameter rather than a lookup so rendering stays a function of its inputs.
    """
    if brand not in BRANDS:
        raise CommandSourceError(f"unknown brand {brand!r}")
    origin = entry.source
    if Path(entry.source).stem != entry.name:
        raise CommandSourceError(
            f"{origin}: registered as {entry.name!r} but its file stem is "
            f"{Path(entry.source).stem!r}; both providers take the workflow name "
            "from the file, so the two must agree"
        )
    validate_directives(source_text, origin=origin)
    fields, body, body_line = parse_source(source_text, origin=origin)
    if fields["name"] != entry.name:
        raise CommandSourceError(
            f"{origin}: frontmatter declares name {fields['name']!r} but the "
            f"registry entry is {entry.name!r}"
        )
    known = set(vocabulary) | {entry.name} | referenced_names(source_text)
    failures = literal_invocation_failures(source_text, known, origin=origin)
    if failures:
        raise CommandSourceError("\n".join(failures))
    selected = select_brand(body, brand, origin=origin, body_line=body_line)
    lines = [
        f"{key}: {substitute_references(fields[key], brand)}"
        for key in BRAND_FRONTMATTER_KEYS[brand]
        if key in fields
    ]
    rendered = (
        "---\n"
        + "".join(f"{line}\n" for line in lines)
        + "---\n"
        + substitute_references(selected, brand)
    )
    return rendered if rendered.endswith("\n") else rendered + "\n"


def render_entry(
    entry: CommandSource, repo_root: Path = REPO_ROOT, vocabulary=None
) -> dict[str, str]:
    """`{repository-relative output path: rendered text}` for one entry."""
    source = repo_root / entry.source
    try:
        source_text = source.read_text(encoding="utf-8")
    except OSError as error:
        raise CommandSourceError(
            f"{entry.source}: authored source is unreadable ({error})"
        ) from error
    if vocabulary is None:
        vocabulary = workflow_vocabulary(repo_root)
    paths = output_paths(entry)
    return {
        paths[brand]: render(entry, source_text, brand, vocabulary)
        for brand in BRANDS
    }


def render_all(repo_root: Path = REPO_ROOT) -> dict[str, str]:
    """Every registered entry rendered, keyed by output path."""
    vocabulary = workflow_vocabulary(repo_root)
    rendered: dict[str, str] = {}
    for entry in COMMAND_SOURCES:
        for path, text in render_entry(entry, repo_root, vocabulary).items():
            if path in rendered:
                raise CommandSourceError(
                    f"two registered sources render to {path}"
                )
            rendered[path] = text
    return rendered


def write_all(repo_root: Path = REPO_ROOT) -> list[str]:
    """Render every entry to disk, returning the paths whose bytes changed.

    Unchanged files are left alone rather than rewritten, so re-running over
    unchanged input is a no-op on disk as well as in the diff.
    """
    changed = []
    for path, text in sorted(render_all(repo_root).items()):
        target = repo_root / path
        if target.is_file() and target.read_text(encoding="utf-8") == text:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        changed.append(path)
    return changed


def check_all(repo_root: Path = REPO_ROOT) -> list[str]:
    """The failure lines the tracked outputs owe: one per missing or stale
    file. Empty means every rendered artifact matches its source."""
    failures = []
    for path, text in sorted(render_all(repo_root).items()):
        target = repo_root / path
        if not target.is_file():
            failures.append(
                f"{path} is missing; it is rendered from an authored command "
                f"source, so {RENDER_INSTRUCTION} and commit the result"
            )
        elif target.read_text(encoding="utf-8") != text:
            failures.append(
                f"{path} is stale against its authored source; "
                f"{RENDER_INSTRUCTION} and commit the result"
            )
    return failures


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--check",
        action="store_true",
        help="report stale or missing rendered files without writing anything",
    )
    args = parser.parse_args(argv)
    try:
        if args.check:
            failures = check_all(REPO_ROOT)
            for failure in failures:
                print(failure, file=sys.stderr)
            return 1 if failures else 0
        changed = write_all(REPO_ROOT)
    except CommandSourceError as error:
        print(str(error), file=sys.stderr)
        return 2
    for path in changed:
        print(f"rendered {path}")
    if not changed:
        print("every rendered command file was already current")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
