"""The vendored finalize workflow's own behavioral contract.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 tools/test_finalize_workflow.py

Issue #544, slice VEND-7 of `docs/workflow_command_vendoring_design.md` and the
last of the eight commands the arc vendors. It is the only one with no Codex
counterpart to reconcile against — the personal collection held a single Claude
copy — so every difference between that copy and what ships here was decided
against this repository rather than against the other brand, and the assertions
below fall into four kinds.

* **The gate, run rather than read.** The copy's review gate accepted only a
  `<!-- pr-review:v1 ... -->` marker, which
  `claude-plugin/plugins/kanban/scripts/review_pr.py` stopped publishing: it
  emits `pr-review:v2` with comma-joined `reviewers=` and `models=` fields, so
  a v1-only gate refuses every pull request reviewed today. Replacing a stale
  gate with a differently-stale one is not something a string comparison can
  catch, so `GateDecisionTests` runs the rendered fence under `sh` against a
  scripted `gh` and asserts what it decides — including a marker built by the
  coordinator's own `review_marker`, so the accepted shape is the one the
  publisher actually produces rather than one this module invented.
* **What a refusal does not do.** The copy's fail-closed refusal is the one
  behavior carried over verbatim, and it is the only thing standing between an
  unreviewed head and the default branch. `MutationBoundaryTests` therefore
  concatenates every executable fence of the workflow — gate, merge,
  merged-state confirmation, cleanup resolution, cleanup, and the linked
  issue's close — and asserts against the recorded command log that a refusal
  reaches none of them: no merge, no issue close, no worktree removal, no
  branch deletion. The success case is asserted from the same log, as the exact
  repository and head the merge was bound to.
* **Repository scoping.** All four `gh` calls in the personal copy omitted
  `-R`, which targets whatever repository the session's directory happens to be
  in — and this workflow's calls merge a pull request and delete a branch.
  `RepositoryScopeTests` pins the calls the assets make, one spelling each, and
  requires every repository-addressed one to carry `-R "$REPO"`. The
  authenticated-user lookup is the declared exception, because that endpoint
  names no repository; the comment feed embeds `repos/$REPO/...` instead, which
  is the same binding in the shape that call takes.
* **Claims that no longer hold.** `launchd` as *the* drainer's manager (
  `tools/service_manager.py` drives systemd user units on Linux behind the same
  boundary), the owner's name as the reason for a merge commit, and the
  auto-merge arming that would mutate a pull request whose checks have not
  passed are each pinned as absences, with what replaced them pinned as text.
  An asset is the program an agent executes top to bottom, so a stale claim
  left in it is a stale instruction rather than a stale comment.

Every rule here is measured over BOTH rendered assets, and each class carries a
control that plants the failure it is meant to catch: a rule matching
everything would otherwise pass while asserting nothing.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import fake_cli
import render_command_sources as renderer

REPO_ROOT = Path(__file__).resolve().parent.parent

SOURCE = "tools/command_sources/finalize.md"
CLAUDE_ASSET = "claude-plugin/plugins/kanban/commands/finalize.md"
CODEX_ASSET = "codex-plugin/plugins/kanban/skills/finalize/SKILL.md"
RENDERED_ASSETS = (CLAUDE_ASSET, CODEX_ASSET)
CODEX_SKILL_DIR = "codex-plugin/plugins/kanban/skills/finalize"
REVIEW_COORDINATOR = REPO_ROOT / "claude-plugin/plugins/kanban/scripts/review_pr.py"

# A `gh` invocation as the assets actually spell one, in a fenced block or in
# inline code. The lookbehind keeps the `gh` ending a longer word out, and the
# required lowercase subcommand keeps a prose mention of a "`gh` call" out.
GH_INVOCATION_RE = re.compile(r"(?<![\w-])gh (?P<tail>[a-z][^\n`]*)")

REPOSITORY_SCOPE = '-R "$REPO"'

# The word of a `${VAR:?word}` refusal, which the shell evaluates rather than
# prints verbatim.
PARAMETER_REFUSAL_RE = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*:\?([^}]*)\}")

# The three fail-closed guards the workflow carries, by the word each refuses
# with. Enumerated so the scan above is measured against a known set rather
# than against whatever it happens to find.
EXPECTED_REFUSAL_WORDS = (
    "the finalize gate refused; nothing is merged, closed, removed, or deleted",
    "the merge is not confirmed; close nothing, remove nothing, delete nothing",
    "the primary checkout is not on the base branch of this pull request; "
    "leave its branches alone",
    "the head of this pull request lives in another repository; delete no "
    "branch here",
    "pushing to origin does not reach the repository this pull request is in, "
    "or does not reach only it; delete no remote branch here",
)


def gh_invocations(text: str) -> list[str]:
    """Every `gh` call in `text`, with the command substitution's own closing
    `)"` trimmed off.

    Most of these calls fill a shell variable, so the regex's line-tail match
    carries the substitution's punctuation into the call. Trimming it here
    keeps the declared spellings below the ones the asset actually reads as
    commands, rather than the ones a reader would have to mentally strip.
    """
    calls = []
    for match in GH_INVOCATION_RE.finditer(text):
        call = match.group(0)
        # Exactly the two-character suffix, not any run of those characters:
        # `gh issue close "$ISSUE" -R "$REPO"` is a bare line whose own closing
        # quote is part of the call.
        calls.append(call[:-2] if call.endswith(')"') else call)
    return calls

# How `$REPO` is filled: from the remote, with no GitHub call of its own. At
# the point of resolution `$REPO` does not exist yet, so a `gh` call there
# could not carry `-R` and the rule below would have to make an exception for
# the very call that decides which repository everything else is scoped to.
REPOSITORY_RESOLUTION = 'REPO="$(git -C "$ROOT" remote get-url origin'

# The fields the gate reads the pull request with. Pinned because the harness
# scripts `gh` against this exact list: a field dropped from the asset would
# leave the gate deciding without it, and a field dropped here would leave the
# harness answering a question the asset never asked.
PR_VIEW_FIELDS = (
    "number,url,body,headRefOid,headRefName,baseRefName,labels,reviewDecision,"
    "mergeable,mergeStateStatus,closingIssuesReferences"
)

# The two origin markers, character for character as `originFromBody` spells
# them, and as the gate has to.
ORIGIN_MARKERS = {
    "claude": "<!-- pr-origin:claude -->",
    "codex": "<!-- pr-origin:codex -->",
}

# The paginated issue-comment endpoint, embedding the resolved repository the
# way `tools/drain_prs.py` does. `gh pr view --json comments` returns a bounded
# window, so on a long pull request the newest marker can fall outside it.
COMMENT_FEED = 'repos/$REPO/issues/$PR/comments?per_page=100'

# Every `gh` call the workflow makes, by the leading words that identify each,
# split by whether the call addresses a repository. Counted as well as listed:
# a rule over "every `gh` call" passes vacuously if the assets ever stop making
# any.
REPOSITORY_SCOPED_CALLS = (
    'pr view "$PR" -R "$REPO" --json ' + PR_VIEW_FIELDS,
    'api --paginate --slurp "' + COMMENT_FEED + '"',
    'pr checks "$PR" -R "$REPO" --json name,state,bucket',
    'pr merge "$PR" -R "$REPO" --admin --merge --match-head-commit',
    'pr view "$PR" -R "$REPO" --json state,mergedAt',
    'pr view "$PR" -R "$REPO" --json baseRefName',
    'pr view "$PR" -R "$REPO" --json isCrossRepository,headRefName',
    'pr view "$PR" -R "$REPO" --json closingIssuesReferences',
    'issue view "${ISSUE:-0}" -R "$REPO" --json number,state',
    'issue close "$OPEN_ISSUE" -R "$REPO"',
)
# The one call that names no repository, because the endpoint has none. It is
# an enumerated exception rather than a pattern: a second unscoped call added
# later fails the count below rather than inheriting this allowance.
GLOBAL_CALLS = ('api user --jq .login',)
DECLARED_GH_CALL_COUNT = len(REPOSITORY_SCOPED_CALLS) + len(GLOBAL_CALLS)

# The claims the personal copy carried that this repository no longer supports,
# one phrase per claim. Each is pinned as an absence, and what replaced it is
# pinned as text in PreservedBehaviorTests below.
RETIRED_CLAIMS = {
    "the v1-only review gate": "pr-review:v1 ... -->` marker has",
    "launchd as the drainer's manager": "launchd-managed",
    "the owner as the reason for a merge commit": "wants maximum history",
    "auto-merge arming on unfinished checks": "--auto --merge",
    "the claim that GitHub's config has no review gate": "GitHub's config has none",
}

# `docs/agent-workflow-contract.md`'s rule that no credential, personal model
# preference, private endpoint, or machine-specific path may be tracked as a
# required asset.
PRIVATE_IDENTIFIERS = {
    "the owner's login": "coghex",
    "the owner's personal name": "Vincent",
    "a path that does not exist": "$HOME/work/",
    "the owner-scoped job label": "com.coghex",
}

# `tools/service_manager.py` drives systemd user units on Linux and launchd on
# macOS behind one boundary, so neither is asserted as *the* manager.
SERVICE_MANAGER_NAMES = ("launchd", "systemd", "launchctl", "systemctl")

# The behavior the personal copy had that this rendering keeps, one phrase per
# rule. Matched against whitespace-flattened text, so re-wrapping a paragraph
# does not fail the assertion while deleting the rule still does.
PRESERVED_BEHAVIOR = {
    "the drainer owns ordinary merges": (
        "The service-managed PR drainer controlled by"
    ),
    "never chosen automatically": "**Never choose this path automatically.**",
    "the refusal is total": (
        "merge nothing, close nothing, remove no worktree, delete no branch"
    ),
    "no merge commit alternative": (
        "Never `--squash` and never `--rebase`"
    ),
    "the head is pinned as an object": "--match-head-commit",
    "cleanup waits for a confirmed merge": (
        "Nothing is cleaned up on the strength of the merge command's exit "
        "status."
    ),
    "cleanup runs from the primary checkout": (
        "the cleanup runs from the primary checkout, never from inside the "
        "worktree it is about to remove"
    ),
    "the worktree is found by registration": (
        "`git worktree list` is the only source for the worktree path"
    ),
    "never rm -rf a worktree": "never `rm -rf`",
    "the fast-forward is never forced": (
        "The fast-forward is `--ff-only` and never a force"
    ),
    "both deletions are bound to the reviewed head": (
        "**Both deletions are bound to the reviewed head, not to the branch "
        "name.**"
    ),
    "the cleanup is one chain": (
        "**That is one `&&` chain, and it is one on purpose.**"
    ),
    "no refreshing push": (
        'do not push anything to the branch to "refresh" it'
    ),
}

# What replaced each retired claim, so the absences above are a substitution
# rather than a deletion.
REPLACEMENT_TEXT = {
    "the v2 marker the coordinator publishes": "pr-review:v2 reviewers=",
    "the legacy spelling is still honoured": "pr-review:v1 reviewer=",
    "the comma-joined reviewer field": "reviewers=claude,codex",
    "neither service manager is named": "service-managed PR drainer",
    "history preservation is the repository's reason": (
        "every commit of the pull request reaches the default branch"
    ),
    "a pending check is refused rather than armed": (
        "**Do not arm auto-merge.**"
    ),
}

CLAUDE_ONLY_LINES = (
    'PR="$ARGUMENTS"',
    "`$ARGUMENTS` is what Claude Code substitutes before the session reads this file.",
)

CODEX_ONLY_LINES = (
    'PR="<the pull request number the user named>"',
    "Codex substitutes no argument placeholder, so take the number from the prompt.",
)

# The scenario the harness runs against, fixed so every assertion below reads
# against the same pull request.
PR_NUMBER = "42"
REPO_SLUG = "coghex/kanban"
APPROVED_HEAD = "1a2b3c4d5e6f70819293a4b5c6d7e8f900112233"
STALE_HEAD = "99887766554433221100ffeeddccbbaa99887766"
LINKED_ISSUE = "7"
HEAD_BRANCH = "issue-7-example"
BASE_BRANCH = "master"
VIEWER = "coghex"
WORKTREE_PATH = "/tmp/worktrees/coghex/kanban/issue-7-example"
CHECKOUT_ROOT = "/tmp/checkout"

# The two deletions, bound to the reviewed head rather than to the branch name:
# `update-ref -d <ref> <old>` deletes only a ref that still equals it, and the
# lease sends the same head as the expected old value so the server performs a
# compare-and-swap. A name is not an identity — another actor can delete and
# recreate `$BRANCH` between the merge and the cleanup.
LOCAL_DELETE = [
    "-C",
    CHECKOUT_ROOT,
    "update-ref",
    "-d",
    "refs/heads/" + HEAD_BRANCH,
    APPROVED_HEAD,
]
REMOTE_DELETE = [
    "-C",
    CHECKOUT_ROOT,
    "push",
    "origin",
    "--force-with-lease=refs/heads/" + HEAD_BRANCH + ":" + APPROVED_HEAD,
    "--delete",
    HEAD_BRANCH,
]


def read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def body_of(text: str) -> str:
    """`text` with its frontmatter block removed.

    The frontmatter is the one place the two renderings legitimately differ
    beyond the brand blocks -- different keys, and the invocation sigil inside
    the description -- so the brand comparison is made over the body.
    """
    match = re.match(r"\A---\n.*?\n---\n(?P<body>.*)\Z", text, re.DOTALL)
    assert match is not None, "a rendered asset always opens with frontmatter"
    return match.group("body")


# The workflows this source names through a `{{cmd:}}` token, read from the
# source rather than restated, so the brand comparison covers exactly the
# substitutions the renderer performs and no more.
REFERENCED_WORKFLOWS = renderer.referenced_names(read(SOURCE))


def neutralize(text: str, brand: str) -> str:
    """`text` with `brand`'s spelling of each declared `{{cmd:}}` target put
    back into the neutral token."""
    sigil = renderer.SIGILS[brand]
    for name in sorted(REFERENCED_WORKFLOWS, key=len, reverse=True):
        text = text.replace(f"{sigil}{name}", f"{{{{cmd:{name}}}}}")
    return text


def flat(text: str) -> str:
    """`text` with every run of whitespace collapsed to one space, so a phrase
    is found whether or not the source wrapped it across lines."""
    return re.sub(r"\s+", " ", text)


BASH_FENCE_RE = re.compile(r"```bash\n(?P<body>.*?)\n[ \t]*```", re.DOTALL)


def bash_fences(text: str) -> list[str]:
    return [match.group("body") for match in BASH_FENCE_RE.finditer(text)]


def fence_containing(text: str, needle: str) -> str:
    """The one fenced bash block that contains `needle`.

    Exactly one, deliberately: a gate split across two blocks, or duplicated
    into a second, is a rendering an executing agent could run half of.
    """
    matching = [fence for fence in bash_fences(text) if needle in fence]
    assert len(matching) == 1, (
        f"expected one fence containing {needle!r}, got {len(matching)}"
    )
    return matching[0]


def load_review_pr_module():
    """Import the bundled coordinator by file path, the way
    tools/test_claude_plugin.py does: it lives under claude-plugin/, so `-s
    tools` discovery never puts it on sys.path."""
    spec = importlib.util.spec_from_file_location(
        "kanban_finalize_review_pr", REVIEW_COORDINATOR
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def coordinator_marker(head: str, verdict: str, reviewers: list[str]) -> str:
    """A marker built by the publisher's own `review_marker`.

    Hand-writing the accepted shape would be asserting this module's idea of
    it. The one thing the gate has to accept is what
    `claude-plugin/plugins/kanban/scripts/review_pr.py` actually emits, so the
    fixture is produced through that function.
    """
    module = load_review_pr_module()
    lookup = {
        "codex": module.CODEX_REVIEWER,
        "claude": module.CLAUDE_REVIEWER,
    }
    selected = [lookup[key] for key in reviewers]
    models = [f"model-{key}@xhigh" for key in reviewers]
    return module.review_marker(selected, models, head, verdict)


def legacy_marker(head: str, verdict: str) -> str:
    """The `pr-review:v1` spelling, as `tools/drain_prs.py`'s own
    `PR_REVIEW_V1_RE` still recognises it."""
    return f"<!-- pr-review:v1 reviewer=codex head={head} verdict={verdict} -->"


def comment(identifier: int, created_at: str, body: str, login: str = VIEWER) -> dict:
    return {
        "id": identifier,
        "created_at": created_at,
        "user": {"login": login},
        "body": body,
    }


# The ordinary body of a pull request this repository's own solve workflow
# opened: one origin marker, as the final non-whitespace content.
CLAUDE_ORIGIN_BODY = "Closes #7\n\n" + ORIGIN_MARKERS["claude"] + "\n"


def pull_request_state(
    *,
    head: str = APPROVED_HEAD,
    labels: tuple[str, ...] = ("reviewed:approve",),
    mergeable: str = "MERGEABLE",
    merge_state: str = "CLEAN",
    body: str = CLAUDE_ORIGIN_BODY,
    review_decision: str = "",
) -> dict:
    return {
        "number": int(PR_NUMBER),
        "url": f"https://github.com/{REPO_SLUG}/pull/{PR_NUMBER}",
        "body": body,
        "headRefOid": head,
        "headRefName": HEAD_BRANCH,
        "baseRefName": BASE_BRANCH,
        "labels": [{"name": name} for name in labels],
        "reviewDecision": review_decision,
        "mergeable": mergeable,
        "mergeStateStatus": merge_state,
        "closingIssuesReferences": [{"number": int(LINKED_ISSUE)}],
    }


APPROVED_PAGES = [[comment(1, "2026-08-01T00:00:00Z", coordinator_marker(APPROVED_HEAD, "APPROVE", ["codex"]))]]
GREEN_CHECKS = [{"name": "build-test", "state": "SUCCESS", "bucket": "pass"}]

def worktree_record(path: str, head: str, branch: str | None) -> str:
    """One `git worktree list --porcelain` block."""
    lines = [f"worktree {path}", f"HEAD {head}"]
    lines.append("detached" if branch is None else f"branch refs/heads/{branch}")
    return "\n".join(lines) + "\n"


PRIMARY_RECORD = worktree_record(CHECKOUT_ROOT, "0" * 40, BASE_BRANCH)

# The ordinary listing: the primary checkout, then this pull request's own
# worktree on its head branch at the reviewed head.
WORKTREE_LISTING = (
    PRIMARY_RECORD
    + "\n"
    + worktree_record(WORKTREE_PATH, APPROVED_HEAD, HEAD_BRANCH)
)

# A stale worktree for a DIFFERENT pull request whose path carries the same
# `issue-<n>-` shape. The substring match this replaced would have removed it.
DECOY_PATH = "/tmp/worktrees/coghex/kanban/issue-7-something-else"
DECOY_LISTING = PRIMARY_RECORD + "\n" + worktree_record(
    DECOY_PATH, "2" * 40, "issue-7-something-else"
)

# The collision a run with no linked issue used to open: an `issue--` path the
# reduced pattern would have matched.
EMPTY_ISSUE_DECOY_PATH = "/tmp/worktrees/coghex/kanban/issue--leftover"
EMPTY_ISSUE_DECOY_LISTING = PRIMARY_RECORD + "\n" + worktree_record(
    EMPTY_ISSUE_DECOY_PATH, "3" * 40, "issue--leftover"
)

# The right branch, but moved on to a commit this run did not merge.
MOVED_ON_LISTING = PRIMARY_RECORD + "\n" + worktree_record(
    WORKTREE_PATH, "4" * 40, HEAD_BRANCH
)


class Harness:
    """One scripted `gh`/`git` pair plus the fences to run against them."""

    def __init__(self, root: Path, config: str | None = None):
        self.fake = fake_cli.FakeCli(root)
        self.fake.install("gh")
        self.fake.install("git")
        self.root = root
        # The gate resolves its verdict labels from the real well-known path,
        # so the run gets an XDG config root of its own rather than the
        # developer's.
        self.config_home = root / "config"
        (self.config_home / "kanban").mkdir(parents=True, exist_ok=True)
        if config is not None:
            (self.config_home / "kanban" / "config.toml").write_text(
                config, encoding="utf-8"
            )

    def script_github(
        self,
        *,
        viewer: str = VIEWER,
        states: list[dict] | None = None,
        pages: list | None = None,
        checks: list | None = None,
        merged: str = "2026-08-02T00:00:00Z",
        merge_head: str = APPROVED_HEAD,
        cross_repository: bool = False,
        checked_out: str = BASE_BRANCH,
        linked_issue: str | None = LINKED_ISSUE,
        issue_open: bool = True,
        worktree_listing: str = WORKTREE_LISTING,
        local_branch: str | None = APPROVED_HEAD,
        failing_git: list[str] | None = None,
        push_repos: tuple[str, ...] = (REPO_SLUG,),
    ) -> None:
        base = ["pr", "view", PR_NUMBER, "-R", REPO_SLUG, "--json"]
        self.fake.script("gh", ["api", "user", "--jq", ".login"], stdout=viewer + "\n")
        for state in states if states is not None else [pull_request_state()]:
            self.fake.script("gh", base + [PR_VIEW_FIELDS], stdout=json.dumps(state))
        self.fake.script(
            "gh",
            [
                "api",
                "--paginate",
                "--slurp",
                f"repos/{REPO_SLUG}/issues/{PR_NUMBER}/comments?per_page=100",
            ],
            stdout=json.dumps(pages if pages is not None else APPROVED_PAGES),
        )
        self.fake.script(
            "gh",
            ["pr", "checks", PR_NUMBER, "-R", REPO_SLUG, "--json", "name,state,bucket"],
            stdout=json.dumps(checks if checks is not None else GREEN_CHECKS),
        )
        # Scripted for exactly one head. A merge bound to any other one finds
        # no scripted response, so the head binding is enforced by the fixture
        # as well as asserted from the log.
        self.fake.script(
            "gh",
            [
                "pr",
                "merge",
                PR_NUMBER,
                "-R",
                REPO_SLUG,
                "--admin",
                "--merge",
                "--match-head-commit",
                merge_head,
            ],
            stdout="Merged\n",
        )
        self.fake.script("gh", base + ["state,mergedAt"], stdout=merged + "\n")
        self.fake.script("gh", base + ["baseRefName"], stdout=BASE_BRANCH + "\n")
        # Empty stands for a cross-repository head: the asset's own `select`
        # yields nothing there, which is what the deletion guard reads.
        self.fake.script(
            "gh",
            base + ["isCrossRepository,headRefName"],
            stdout=("" if cross_repository else HEAD_BRANCH + "\n"),
        )
        self.fake.script(
            "gh",
            base + ["closingIssuesReferences"],
            stdout=("" if linked_issue is None else linked_issue + "\n"),
        )
        # Empty stands for "no issue, or one that already closed itself": the
        # asset's own `select` yields nothing in both cases.
        self.fake.script(
            "gh",
            ["issue", "view", linked_issue or "0", "-R", REPO_SLUG, "--json"],
            stdout=(
                (linked_issue + "\n") if (issue_open and linked_issue) else ""
            ),
        )
        self.fake.script(
            "gh", ["issue", "close", linked_issue or "0", "-R", REPO_SLUG], stdout=""
        )
        # The specific git reads first: fake_cli takes the first scripted
        # entry whose match is a prefix of the call, so the catch-all has to
        # be inserted last or it would answer these two as well.
        self.fake.script(
            "git",
            ["-C", CHECKOUT_ROOT, "worktree", "list", "--porcelain"],
            stdout=worktree_listing,
        )
        self.fake.script(
            "git",
            ["-C", CHECKOUT_ROOT, "symbolic-ref", "--quiet", "--short", "HEAD"],
            stdout=checked_out + "\n" if checked_out else "",
        )
        # Empty stands for a primary checkout that never had a copy of the
        # branch, which the asset skips rather than fails on.
        self.fake.script(
            "git",
            ["-C", CHECKOUT_ROOT, "rev-parse", "--verify", "--quiet"],
            stdout=("" if local_branch is None else local_branch + "\n"),
        )
        # `git push` uses remote.origin.pushurl when one is configured, so the
        # push URL is read separately from the fetch URL $REPO came from.
        self.fake.script(
            "git",
            ["-C", CHECKOUT_ROOT, "remote", "get-url", "--push", "--all", "origin"],
            stdout="".join(
                f"https://github.com/{one}.git\n" for one in push_repos
            ),
        )
        if failing_git is not None:
            self.fake.script(
                "git",
                ["-C", CHECKOUT_ROOT, *failing_git],
                stderr="fatal: scripted failure\n",
                exit_code=1,
            )
        self.fake.script("git", ["-C"], stdout="")

    def run(self, script: str) -> subprocess.CompletedProcess:
        env = {
            "PATH": os.environ.get("PATH", ""),
            "HOME": str(self.root / "home"),
            "PR": PR_NUMBER,
            "REPO": REPO_SLUG,
            "ROOT": CHECKOUT_ROOT,
            "XDG_CONFIG_HOME": str(self.config_home),
        }
        env.update(self.fake.environ_overrides())
        return subprocess.run(
            ["sh", "-c", script],
            env=env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
        )

    def gh_calls(self) -> list[list[str]]:
        return [call["args"] for call in self.fake.calls("gh")]

    def git_calls(self) -> list[list[str]]:
        return [call["args"] for call in self.fake.calls("git")]


def gate_fence(relative_path: str) -> str:
    return fence_containing(read(relative_path), "VIEWER=")


# The cleanup chain, in the order the asset runs it, by the tokens that
# identify each step. Used to assert that a failure really does end the chain:
# nothing after the failing step may reach the command log.
CLEANUP_CHAIN = (
    ["worktree", "remove"],
    ["fetch", "origin"],
    ["merge", "--ff-only"],
    ["update-ref", "-d"],
    ["push", "origin"],
)


def matches_step(call: list[str], step: list[str]) -> bool:
    return all(token in call for token in step)


def whole_workflow(
    relative_path: str, *, gate_runs: int = 1, include_issue_close: bool = True
) -> str:
    """Every executable fence of the workflow, in the order it documents them.

    The gate is repeated because the asset requires it: it is re-run
    immediately before the merge, with nothing in between, since labels, the
    head and the check set are all mutable.

    The linked issue's close is the one fence the document gates on the cleanup
    chain having succeeded rather than on a shell condition, so a scenario
    asserting the chain's own exit status leaves it out.
    """
    text = read(relative_path)
    fences = [gate_fence(relative_path)] * gate_runs + [
        fence_containing(text, "gh pr merge"),
        fence_containing(text, "MERGED="),
        fence_containing(text, "BRANCH="),
        fence_containing(text, "worktree remove"),
    ]
    if include_issue_close:
        fences.append(fence_containing(text, "gh issue close"))
    return "\n".join(fences)


class RegistrationTests(unittest.TestCase):
    """Requirements 1 and 2: one authored source, two rendered outputs, and
    neither hand-edited."""

    def entry(self) -> renderer.CommandSource:
        matching = [
            entry for entry in renderer.COMMAND_SOURCES if entry.name == "finalize"
        ]
        self.assertEqual(len(matching), 1, "finalize is registered exactly once")
        return matching[0]

    def test_the_source_renders_into_both_bundle_directories(self):
        entry = self.entry()
        self.assertEqual(entry.source, SOURCE)
        self.assertEqual(
            renderer.output_paths(entry),
            {"claude": CLAUDE_ASSET, "codex": CODEX_ASSET},
        )

    def test_each_rendered_file_is_byte_identical_to_a_fresh_render(self):
        rendered = renderer.render_entry(self.entry(), REPO_ROOT)
        for relative_path, text in rendered.items():
            self.assertEqual(text, read(relative_path), relative_path)

    def test_no_auxiliary_asset_ships_beside_either_rendering(self):
        found = sorted(path.name for path in (REPO_ROOT / CODEX_SKILL_DIR).iterdir())
        self.assertEqual(found, ["SKILL.md"])

    def test_no_literal_sigil_survives_in_either_rendering(self):
        # Requirement 3, as the review's correction scopes it: the source uses
        # the four tokens, and each output carries only its own brand's
        # invocations, no opposite-brand invocation, and no unresolved
        # directive.
        for relative_path, brand in ((CLAUDE_ASSET, "claude"), (CODEX_ASSET, "codex")):
            text = read(relative_path)
            other = "codex" if brand == "claude" else "claude"
            with self.subTest(asset=relative_path):
                self.assertNotIn("{{cmd:", text)
                for name in REFERENCED_WORKFLOWS:
                    self.assertIn(renderer.SIGILS[brand] + name, text)
                    self.assertNotIn(renderer.SIGILS[other] + name, text)

    def test_every_fenced_block_is_valid_shell(self):
        # An asset is the program an agent runs, and this one runs a Python
        # gate inside a `$( ... )` command substitution. Bash quote-scans a
        # heredoc body in that position, so ONE bare apostrophe in a Python
        # comment -- "the pull request\'s own brand" -- opens a quote that
        # swallows the rest of the fence and makes the whole block a syntax
        # error. That is invisible to every string assertion in this module and
        # to the renderer, and it costs the run before a single `gh` call.
        for relative_path in RENDERED_ASSETS:
            for index, fence in enumerate(bash_fences(read(relative_path))):
                with self.subTest(asset=relative_path, fence=index):
                    with tempfile.NamedTemporaryFile(
                        "w", suffix=".sh", delete=False
                    ) as handle:
                        handle.write(fence + "\n")
                        script = handle.name
                    self.addCleanup(os.unlink, script)
                    completed = subprocess.run(
                        ["sh", "-n", script],
                        stdin=subprocess.DEVNULL,
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_the_shell_syntax_check_detects_a_planted_unbalanced_quote(self):
        # The control for the check above: the exact defect it exists to
        # catch, planted into the gate fence, must fail it.
        planted = gate_fence(CLAUDE_ASSET).replace(
            "import json", "# the pull request's own brand\nimport json", 1
        )
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as handle:
            handle.write(planted + "\n")
            script = handle.name
        self.addCleanup(os.unlink, script)
        completed = subprocess.run(
            ["sh", "-n", script],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(completed.returncode, 0, completed.stderr)

    def test_no_refusal_word_carries_an_apostrophe(self):
        # A syntactically VALID trap the check above cannot see. A `\'` inside a
        # `${VAR:?word}` is read as an opening quote, so the shell swallows
        # every line up to the next one: two guards a `git merge` apart, both
        # with an apostrophe in their message, silently dropped that merge.
        # Every fence is scanned, not only the two that carry a guard today.
        for relative_path in RENDERED_ASSETS:
            for index, fence in enumerate(bash_fences(read(relative_path))):
                for word in PARAMETER_REFUSAL_RE.findall(fence):
                    with self.subTest(asset=relative_path, fence=index, word=word):
                        self.assertNotIn("'", word)

    def test_the_apostrophe_scan_finds_a_planted_one(self):
        planted = PARAMETER_REFUSAL_RE.findall(
            ''': "${BRANCH:?the head of this request\'s repository}"'''
        )
        self.assertEqual(len(planted), 1, planted)
        self.assertIn("'", planted[0])

    def test_the_apostrophe_scan_reads_the_words_the_assets_carry(self):
        # Non-vacuity: a regex that matched nothing would report no apostrophe
        # for the same reason a clean asset does.
        found = [
            word
            for relative_path in RENDERED_ASSETS
            for fence in bash_fences(read(relative_path))
            for word in PARAMETER_REFUSAL_RE.findall(fence)
        ]
        self.assertEqual(len(found), 2 * len(EXPECTED_REFUSAL_WORDS), found)
        for expected in EXPECTED_REFUSAL_WORDS:
            self.assertIn(expected, found)

    def test_the_source_names_every_workflow_through_a_token(self):
        self.assertEqual(
            REFERENCED_WORKFLOWS,
            {"finalize", "drain-prs", "pr-review", "pr-rereview", "fix"},
        )


class RepositoryScopeTests(unittest.TestCase):
    """Requirement 4, as the review's correction scopes it: repository-
    addressable calls carry `-R "$REPO"`, the repository API endpoint embeds
    `repos/$REPO/...`, the authenticated-user lookup may be global, and no call
    infers the repository from the current directory."""

    def test_the_declared_calls_are_the_ones_the_assets_carry(self):
        # Non-vacuity for the scoping assertion below: a regex that stopped
        # matching would report no unscoped call for the same reason a file
        # with no calls does.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                calls = gh_invocations(read(relative_path))
                self.assertEqual(len(calls), DECLARED_GH_CALL_COUNT, calls)

    def test_each_declared_call_is_present_exactly_as_spelled(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            for leading in REPOSITORY_SCOPED_CALLS + GLOBAL_CALLS:
                with self.subTest(asset=relative_path, call=leading):
                    self.assertIn("gh " + leading, content)

    def test_every_repository_addressed_call_names_the_resolved_repository(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            for call in gh_invocations(content):
                if call == "gh " + GLOBAL_CALLS[0]:
                    continue
                with self.subTest(asset=relative_path, call=call):
                    scoped = REPOSITORY_SCOPE in call or "repos/$REPO/" in call
                    self.assertTrue(
                        scoped,
                        f"{relative_path}: {call!r} would target whatever "
                        "repository the session's working directory happens "
                        "to be in",
                    )

    def test_the_one_global_call_is_the_authenticated_user_lookup(self):
        # The exception is enumerated rather than inferred: a second unscoped
        # call would fail here even though it is equally unscoped.
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            unscoped = [
                call
                for call in gh_invocations(content)
                if REPOSITORY_SCOPE not in call and "repos/$REPO/" not in call
            ]
            with self.subTest(asset=relative_path):
                self.assertEqual(unscoped, ["gh " + GLOBAL_CALLS[0]])

    def test_the_repository_is_resolved_without_a_github_call_of_its_own(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(REPOSITORY_RESOLUTION, content)
                self.assertNotIn("gh repo view", content)

    def test_resolution_precedes_every_github_call(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            first_call = GH_INVOCATION_RE.search(content)
            self.assertIsNotNone(first_call, relative_path)
            with self.subTest(asset=relative_path):
                self.assertLess(
                    content.index(REPOSITORY_RESOLUTION),
                    first_call.start(),
                    f"{relative_path}: the first GitHub call is made before "
                    "$REPO is resolved",
                )

    def test_the_announcement_precedes_every_github_call(self):
        # Reporting what was resolved catches a wrong resolution only if it
        # lands before anything has been merged in the wrong repository.
        announcement = "**Announce, then act:** name the resolved `$REPO`"
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            self.assertIn(announcement, content, relative_path)
            first_call = GH_INVOCATION_RE.search(content)
            self.assertIsNotNone(first_call, relative_path)
            with self.subTest(asset=relative_path):
                self.assertLess(
                    content.index(announcement),
                    first_call.start(),
                    f"{relative_path}: the announcement lands after the first "
                    "GitHub call",
                )

    def test_the_scope_detector_finds_a_planted_unscoped_call(self):
        planted = read(CLAUDE_ASSET) + '\n```bash\ngh pr merge "$PR" --admin\n```\n'
        unscoped = [
            call
            for call in gh_invocations(planted)
            if REPOSITORY_SCOPE not in call and "repos/$REPO/" not in call
        ]
        self.assertIn('gh pr merge "$PR" --admin', unscoped)


class GateDecisionTests(unittest.TestCase):
    """Requirement 5 and its spec additions, run rather than read.

    The rendered gate fence is executed under `sh` against a scripted `gh`, so
    each rule is asserted as the decision it produces. Both renderings are
    driven: they are one render of one source, and a brand block that broke the
    gate on one side would otherwise pass here.
    """

    def decide(
        self, relative_path: str, config: str | None = None, **scripted
    ) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as directory:
            harness = Harness(Path(directory), config=config)
            harness.script_github(**scripted)
            return harness.run(
                gate_fence(relative_path) + '\nprintf "gate=%s\\n" "$HEAD"\n'
            )

    def assertApproved(self, completed, message=""):
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn(f"gate={APPROVED_HEAD}", completed.stdout, message)

    def assertRefused(self, completed, detail):
        self.assertIn("gate=\n", completed.stdout, completed.stdout)
        self.assertIn("Refusing to finalize", completed.stderr)
        self.assertIn(detail, completed.stderr)

    def test_a_coordinator_published_v2_marker_passes(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertApproved(self.decide(relative_path))

    def test_a_coordinator_published_dual_reviewer_v2_marker_passes(self):
        # `review_marker` comma-joins both lists, so a dual review publishes
        # `reviewers=claude,codex`. The personal copy's regex, and
        # `tools/drain_prs.py`'s to this day, accept one reviewer only. A dual
        # review is the coordinator's UNKNOWN-origin route, so the pull request
        # it belongs to is one whose body declares no origin.
        marker = coordinator_marker(APPROVED_HEAD, "APPROVE", ["codex", "claude"])
        self.assertIn("reviewers=codex,claude", marker)
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertApproved(
                    self.decide(
                        relative_path,
                        states=[pull_request_state(body="Closes #7\n")],
                        pages=[[comment(1, "2026-08-01T00:00:00Z", marker)]],
                    )
                )

    def test_an_approval_by_the_pull_requests_own_brand_is_a_self_review(self):
        # The marker names who reviewed, never who wrote, so the origin has to
        # be read off the pull request. A `reviewers=claude` approval on a
        # claude-origin pull request is exactly the self-review the whole
        # opposite-brand routing exists to prevent.
        marker = coordinator_marker(APPROVED_HEAD, "APPROVE", ["claude"])
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(
                        relative_path,
                        pages=[[comment(1, "2026-08-01T00:00:00Z", marker)]],
                    ),
                    "names this pull request's own brand (claude)",
                )

    def test_a_dual_marker_naming_the_origin_brand_is_still_a_self_review(self):
        # Including the opposite brand does not launder the same-brand half.
        marker = coordinator_marker(APPROVED_HEAD, "APPROVE", ["codex", "claude"])
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(
                        relative_path,
                        pages=[[comment(1, "2026-08-01T00:00:00Z", marker)]],
                    ),
                    "names this pull request's own brand (claude)",
                )

    def test_a_codex_origin_pull_request_refuses_a_codex_approval(self):
        # The rule is symmetric, and this is the direction the default fixture
        # cannot exercise.
        marker = coordinator_marker(APPROVED_HEAD, "APPROVE", ["codex"])
        state = pull_request_state(body="Closes #7\n\n" + ORIGIN_MARKERS["codex"] + "\n")
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(
                        relative_path,
                        states=[state],
                        pages=[[comment(1, "2026-08-01T00:00:00Z", marker)]],
                    ),
                    "names this pull request's own brand (codex)",
                )

    def test_a_single_brand_marker_on_an_unknown_origin_pull_request_refuses(self):
        # With no declared origin there is no brand to be opposite of, so a
        # single-brand review cannot be known to be independent.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(
                        relative_path,
                        states=[pull_request_state(body="Closes #7\n")],
                    ),
                    "declares no origin",
                )

    def test_two_origin_markers_refuse_rather_than_picking_one(self):
        body = "Closes #7\n\n" + ORIGIN_MARKERS["codex"] + "\n" + ORIGIN_MARKERS["claude"] + "\n"
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, states=[pull_request_state(body=body)]),
                    "carries both pr-origin markers",
                )

    def test_a_duplicated_origin_marker_refuses(self):
        body = "Closes #7\n\n" + ORIGIN_MARKERS["claude"] + "\n" + ORIGIN_MARKERS["claude"] + "\n"
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, states=[pull_request_state(body=body)]),
                    "carries a duplicate pr-origin marker",
                )

    def test_an_origin_marker_with_trailing_text_refuses(self):
        # `originFromBody` requires it to be the body's final non-whitespace
        # content, so a marker quoted mid-body is not a declaration.
        body = "Closes #7\n\n" + ORIGIN_MARKERS["claude"] + "\n\nand then some prose.\n"
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, states=[pull_request_state(body=body)]),
                    "not the body's final content",
                )

    def test_a_legacy_v1_marker_still_passes(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertApproved(
                    self.decide(
                        relative_path,
                        pages=[
                            [
                                comment(
                                    1,
                                    "2026-08-01T00:00:00Z",
                                    legacy_marker(APPROVED_HEAD, "APPROVE"),
                                )
                            ]
                        ],
                    )
                )

    def test_the_newest_marker_wins_across_pages(self):
        # The refusal is on a LATER page than the approval, which is the
        # ordering a bounded read gets wrong: page one alone would approve.
        pages = [
            [comment(1, "2026-08-01T00:00:00Z", coordinator_marker(APPROVED_HEAD, "APPROVE", ["codex"]))],
            [comment(2, "2026-08-05T00:00:00Z", coordinator_marker(APPROVED_HEAD, "CHANGES_REQUESTED", ["codex"]))],
        ]
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, pages=pages),
                    "verdict=CHANGES_REQUESTED",
                )

    def test_an_out_of_order_page_does_not_change_the_choice(self):
        # Same two comments, pages swapped: the decision is made from the
        # timestamps, not from the order GitHub returned them in.
        pages = [
            [comment(2, "2026-08-05T00:00:00Z", coordinator_marker(APPROVED_HEAD, "CHANGES_REQUESTED", ["codex"]))],
            [comment(1, "2026-08-01T00:00:00Z", coordinator_marker(APPROVED_HEAD, "APPROVE", ["codex"]))],
        ]
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, pages=pages),
                    "verdict=CHANGES_REQUESTED",
                )

    def test_a_marker_published_by_anyone_else_is_not_a_marker(self):
        pages = [
            [
                comment(
                    1,
                    "2026-08-01T00:00:00Z",
                    coordinator_marker(APPROVED_HEAD, "APPROVE", ["codex"]),
                    login="someone-else",
                )
            ]
        ]
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, pages=pages),
                    "no review marker published by",
                )

    def test_the_author_comparison_is_case_insensitive(self):
        # GitHub does not preserve login case in a way that may decide this.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertApproved(self.decide(relative_path, viewer="CogHex"))

    def test_an_unresolved_login_refuses_rather_than_accepting_every_marker(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, viewer=""),
                    "the authenticated GitHub login could not be resolved",
                )

    def test_a_marker_naming_another_head_is_stale(self):
        pages = [
            [
                comment(
                    1,
                    "2026-08-01T00:00:00Z",
                    coordinator_marker(STALE_HEAD, "APPROVE", ["codex"]),
                )
            ]
        ]
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, pages=pages), "not the current head"
                )

    def test_a_malformed_owned_marker_refuses_rather_than_being_skipped(self):
        pages = [
            [comment(1, "2026-08-01T00:00:00Z", coordinator_marker(APPROVED_HEAD, "APPROVE", ["codex"]))],
            [comment(2, "2026-08-05T00:00:00Z", "<!-- pr-review:v2 verdict=APPROVE -->")],
        ]
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, pages=pages), "is malformed"
                )

    def test_a_malformed_marker_refuses_in_any_case_spelling(self):
        # The parsers are case-insensitive, so the opening test has to be too:
        # a case-sensitive one would skip a malformed `<!-- PR-REVIEW:V2 ... -->`
        # and let the older APPROVE beneath it win, which is exactly the
        # fail-open the malformed-marker rule exists to close.
        pages = [
            [comment(1, "2026-08-01T00:00:00Z", coordinator_marker(APPROVED_HEAD, "APPROVE", ["codex"]))],
            [comment(2, "2026-08-05T00:00:00Z", "<!-- PR-REVIEW:V2 verdict=APPROVE -->")],
        ]
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, pages=pages), "is malformed"
                )

    def test_a_well_formed_marker_in_another_case_still_passes(self):
        # Non-vacuity for the case rule above: the parsers really are
        # case-insensitive, so an upper-case marker is not simply refused.
        marker = coordinator_marker(APPROVED_HEAD, "APPROVE", ["codex"]).upper()
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertApproved(
                    self.decide(
                        relative_path,
                        pages=[[comment(1, "2026-08-01T00:00:00Z", marker)]],
                    )
                )

    def test_an_approval_followed_by_a_later_marker_refuses(self):
        # The fail-open this closes: taking the FIRST marker that parses reads
        # a comment opening with a current-head APPROVE and going on to a
        # CHANGES_REQUESTED as the approval alone.
        body = (
            coordinator_marker(APPROVED_HEAD, "APPROVE", ["codex"])
            + "\n\nsecond thoughts\n\n"
            + coordinator_marker(APPROVED_HEAD, "CHANGES_REQUESTED", ["codex"])
        )
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(
                        relative_path,
                        pages=[[comment(1, "2026-08-01T00:00:00Z", body)]],
                    ),
                    "carries 2 review markers",
                )

    def test_an_approval_followed_by_a_malformed_marker_refuses(self):
        # And the malformed test now runs even though a valid marker matched,
        # which it did not when the first parseable one ended the search.
        body = (
            coordinator_marker(APPROVED_HEAD, "APPROVE", ["codex"])
            + "\n\n<!-- pr-review:v2 garbage -->\n"
        )
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(
                        relative_path,
                        pages=[[comment(1, "2026-08-01T00:00:00Z", body)]],
                    ),
                    "is malformed",
                )

    def test_a_marker_repeated_verbatim_refuses(self):
        marker = coordinator_marker(APPROVED_HEAD, "APPROVE", ["codex"])
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(
                        relative_path,
                        pages=[
                            [comment(1, "2026-08-01T00:00:00Z", marker + "\n" + marker)]
                        ],
                    ),
                    "carries 2 review markers",
                )

    def test_a_comment_with_no_marker_is_passed_over_not_refused(self):
        # Non-vacuity for the three above: a comment carrying no marker at all
        # is skipped so an older marker comment can still be found, which is
        # the behavior the opening count has to preserve.
        pages = [
            [comment(1, "2026-08-01T00:00:00Z", coordinator_marker(APPROVED_HEAD, "APPROVE", ["codex"]))],
            [comment(2, "2026-08-05T00:00:00Z", "looks good, merging soon")],
        ]
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertApproved(self.decide(relative_path, pages=pages))

    def test_a_missing_approval_label_refuses(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, states=[pull_request_state(labels=())]),
                    "this repository approves by label",
                )

    def test_a_present_changes_label_refuses(self):
        state = pull_request_state(labels=("reviewed:approve", "reviewed:changes"))
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, states=[state]),
                    "reviewed:changes is attached",
                )

    def test_a_blocking_label_refuses(self):
        # hasProblemLabel treats a blocking label exactly as it treats the
        # changes-requested one, and a blocking label is a human decision.
        state = pull_request_state(labels=("reviewed:approve", "blocked"))
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, states=[state]),
                    "a blocking label is attached: blocked",
                )

    def test_the_label_comparison_folds_case_on_both_sides(self):
        # hasLabel case-folds both sides, so the gate has to as well.
        state = pull_request_state(labels=("Reviewed:Approve",))
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertApproved(self.decide(relative_path, states=[state]))

    def test_a_repository_that_renamed_its_approval_label_is_read_correctly(self):
        # The defect this closes: a hard-coded `reviewed:approve` refuses every
        # approval a repository that renamed the label ever publishes.
        config = '[workflow]\napproval_label = "ship-it"\n'
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertApproved(
                    self.decide(
                        relative_path,
                        config=config,
                        states=[pull_request_state(labels=("ship-it",))],
                    )
                )
                # And the default is no longer an approval there.
                self.assertRefused(
                    self.decide(
                        relative_path,
                        config=config,
                        states=[pull_request_state(labels=("reviewed:approve",))],
                    ),
                    "this repository approves by label",
                )

    def test_a_repository_override_wins_over_the_global_table(self):
        config = (
            '[workflow]\napproval_label = "global-approve"\n\n'
            '[repositories."coghex/kanban".workflow]\n'
            'approval_label = "repo-approve"\n'
        )
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertApproved(
                    self.decide(
                        relative_path,
                        config=config,
                        states=[pull_request_state(labels=("repo-approve",))],
                    )
                )
                self.assertRefused(
                    self.decide(
                        relative_path,
                        config=config,
                        states=[pull_request_state(labels=("global-approve",))],
                    ),
                    "this repository approves by label",
                )

    def test_a_renamed_changes_requested_label_still_refuses(self):
        config = '[workflow]\nchanges_requested_label = "needs-work"\n'
        state = pull_request_state(labels=("reviewed:approve", "needs-work"))
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, config=config, states=[state]),
                    "needs-work is attached",
                )

    def test_a_review_mode_repository_accepts_githubs_own_approval(self):
        # A repository configured for `review` would otherwise look unapproved
        # with a perfectly good approval on it.
        config = '[workflow]\napproval_mode = "review"\n'
        state = pull_request_state(labels=(), review_decision="APPROVED")
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertApproved(
                    self.decide(relative_path, config=config, states=[state])
                )
                self.assertRefused(
                    self.decide(
                        relative_path,
                        config=config,
                        states=[pull_request_state(labels=("reviewed:approve",))],
                    ),
                    "this repository approves by review",
                )

    def test_either_mode_accepts_the_label_alone_and_the_review_alone(self):
        config = '[workflow]\napproval_mode = "either"\n'
        for relative_path in RENDERED_ASSETS:
            for state in (
                pull_request_state(labels=("reviewed:approve",)),
                pull_request_state(labels=(), review_decision="APPROVED"),
            ):
                with self.subTest(asset=relative_path, labels=state["labels"]):
                    self.assertApproved(
                        self.decide(relative_path, config=config, states=[state])
                    )

    def test_an_unreadable_configuration_keeps_the_documented_defaults(self):
        # Fail-soft on the file, not on the gate: an unparseable config must
        # not turn every pull request into an approval or a refusal by accident.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertApproved(
                    self.decide(relative_path, config="this is not toml [[[")
                )

    def test_a_conflicted_pull_request_refuses(self):
        state = pull_request_state(mergeable="CONFLICTING", merge_state="DIRTY")
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, states=[state]),
                    "mergeable=CONFLICTING",
                )

    def test_a_branch_behind_its_base_refuses(self):
        # The case `mergeable` alone walks straight past: MERGEABLE and BEHIND
        # together mean the head has not seen the base tip the reviewed code
        # would land on. Merging it with --admin skips the branch update and
        # the fresh review the drainer would have required.
        state = pull_request_state(merge_state="BEHIND")
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, states=[state]),
                    "mergeStateStatus=BEHIND",
                )

    def test_an_unstable_merge_state_refuses(self):
        state = pull_request_state(merge_state="UNSTABLE")
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, states=[state]),
                    "mergeStateStatus=UNSTABLE",
                )

    def test_a_protected_branch_requirement_is_ready(self):
        # parseMergeState maps a MERGEABLE + BLOCKED pair to MergeProtected,
        # which mergeStateReady accepts: it is the branch-protection
        # requirement `--admin` exists to clear. Refusing it would leave this
        # workflow unable to finalize anything on a protected branch.
        state = pull_request_state(merge_state="BLOCKED")
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertApproved(self.decide(relative_path, states=[state]))

    def test_every_other_merge_state_refuses(self):
        # MergeUnknown is the catch-all in parseMergeState, and it is not a
        # clearance either.
        for merge_state in ("DRAFT", "HAS_HOOKS", "", "SOMETHING_NEW"):
            state = pull_request_state(merge_state=merge_state)
            for relative_path in RENDERED_ASSETS:
                with self.subTest(asset=relative_path, merge_state=merge_state):
                    self.assertRefused(
                        self.decide(relative_path, states=[state]),
                        "mergeStateStatus=" + (merge_state or "unset"),
                    )

    def test_an_uncomputed_merge_state_is_not_a_clearance(self):
        state = pull_request_state(mergeable="UNKNOWN", merge_state="UNKNOWN")
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, states=[state]), "mergeable=UNKNOWN"
                )

    def test_a_pending_check_refuses(self):
        checks = [
            {"name": "build-test", "state": "IN_PROGRESS", "bucket": "pending"},
        ]
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, checks=checks), "build-test:pending"
                )

    def test_a_failed_check_refuses(self):
        checks = [
            {"name": "build-test", "state": "SUCCESS", "bucket": "pass"},
            {"name": "publish-dry-run", "state": "FAILURE", "bucket": "fail"},
        ]
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, checks=checks),
                    "publish-dry-run:fail",
                )

    def test_a_skipped_check_is_not_a_failure(self):
        checks = [
            {"name": "build-test", "state": "SUCCESS", "bucket": "pass"},
            {"name": "publish-release", "state": "SKIPPED", "bucket": "skipping"},
        ]
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertApproved(self.decide(relative_path, checks=checks))

    def test_an_empty_check_set_refuses(self):
        # "no checks reported" is what a conflicted pull request looks like,
        # not what a green one does.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, checks=[]),
                    "GitHub reported no checks on this head",
                )

    def test_a_feed_with_no_marker_at_all_refuses(self):
        pages = [[comment(1, "2026-08-01T00:00:00Z", "looks good to me")]]
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertRefused(
                    self.decide(relative_path, pages=pages),
                    "no review marker published by",
                )


class MutationBoundaryTests(unittest.TestCase):
    """Requirement 5's fail-closed refusal, asserted as what the recorded
    command log does and does not contain.

    The script run here is every executable fence of the workflow in document
    order, so a refusal that leaked past the gate would reach a real merge, a
    real issue close, a real worktree removal and a real branch deletion — and
    each would appear in the log.
    """

    def execute(
        self,
        relative_path: str,
        *,
        gate_runs: int = 2,
        config: str | None = None,
        include_issue_close: bool = True,
        **scripted,
    ):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        harness = Harness(Path(directory.name), config=config)
        harness.script_github(**scripted)
        completed = harness.run(
            whole_workflow(
                relative_path,
                gate_runs=gate_runs,
                include_issue_close=include_issue_close,
            )
        )
        return completed, harness

    def assertNoMutation(self, harness: Harness):
        for call in harness.gh_calls():
            self.assertNotIn("merge", call[:2], call)
            self.assertNotEqual(call[:2], ["issue", "close"], call)
        for call in harness.git_calls():
            self.assertNotIn("remove", call, call)
            self.assertNotIn("branch", call, call)
            self.assertNotIn("--delete", call, call)

    def test_a_refused_gate_reaches_no_mutation_at_all(self):
        refusals = {
            "no approval label": {"states": [pull_request_state(labels=())]},
            "changes requested label": {
                "states": [
                    pull_request_state(labels=("reviewed:approve", "reviewed:changes"))
                ]
            },
            "a stale marker head": {
                "pages": [
                    [
                        comment(
                            1,
                            "2026-08-01T00:00:00Z",
                            coordinator_marker(STALE_HEAD, "APPROVE", ["codex"]),
                        )
                    ]
                ]
            },
            "a changes-requested verdict": {
                "pages": [
                    [
                        comment(
                            1,
                            "2026-08-01T00:00:00Z",
                            coordinator_marker(
                                APPROVED_HEAD, "CHANGES_REQUESTED", ["codex"]
                            ),
                        )
                    ]
                ]
            },
            "a foreign marker author": {
                "pages": [
                    [
                        comment(
                            1,
                            "2026-08-01T00:00:00Z",
                            coordinator_marker(APPROVED_HEAD, "APPROVE", ["codex"]),
                            login="impostor",
                        )
                    ]
                ]
            },
            "a pending check": {
                "checks": [
                    {"name": "build-test", "state": "QUEUED", "bucket": "pending"}
                ]
            },
            "a failed check": {
                "checks": [
                    {"name": "build-test", "state": "FAILURE", "bucket": "fail"}
                ]
            },
            "a merge conflict": {"states": [pull_request_state(mergeable="CONFLICTING")]},
            "a head behind its base": {
                "states": [pull_request_state(merge_state="BEHIND")]
            },
            "an unstable merge state": {
                "states": [pull_request_state(merge_state="UNSTABLE")]
            },
            "an approval by the pull request's own brand": {
                "pages": [
                    [
                        comment(
                            1,
                            "2026-08-01T00:00:00Z",
                            coordinator_marker(APPROVED_HEAD, "APPROVE", ["claude"]),
                        )
                    ]
                ]
            },
        }
        for relative_path in RENDERED_ASSETS:
            for reason, scripted in refusals.items():
                with self.subTest(asset=relative_path, reason=reason):
                    completed, harness = self.execute(relative_path, **scripted)
                    self.assertNotEqual(completed.returncode, 0, completed.stdout)
                    self.assertIn("Refusing to finalize", completed.stderr)
                    self.assertNoMutation(harness)

    def test_approval_withdrawn_between_the_two_gate_runs_stops_the_merge(self):
        # The refresh is the point of running the gate twice: labels, the head
        # and the checks are all mutable, and the value the merge pins is the
        # one the SECOND run validated.
        states = [pull_request_state(), pull_request_state(labels=())]
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                completed, harness = self.execute(relative_path, states=states)
                self.assertNotEqual(completed.returncode, 0)
                self.assertNoMutation(harness)

    def test_the_head_moving_between_the_two_gate_runs_stops_the_merge(self):
        states = [pull_request_state(), pull_request_state(head=STALE_HEAD)]
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                completed, harness = self.execute(relative_path, states=states)
                self.assertNotEqual(completed.returncode, 0)
                self.assertNoMutation(harness)

    def test_an_unconfirmed_merge_cleans_up_nothing(self):
        # The merge command's exit status is not the confirmation: only
        # GitHub reporting the pull request MERGED is.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                completed, harness = self.execute(relative_path, merged="")
                self.assertNotEqual(completed.returncode, 0)
                merges = [call for call in harness.gh_calls() if call[:2] == ["pr", "merge"]]
                self.assertEqual(len(merges), 1, harness.gh_calls())
                for call in harness.gh_calls():
                    self.assertNotEqual(call[:2], ["issue", "close"], call)
                for call in harness.git_calls():
                    self.assertNotIn("remove", call, call)
                    self.assertNotIn("--delete", call, call)

    def test_an_approved_pull_request_merges_at_the_exact_repository_and_head(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                completed, harness = self.execute(relative_path)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                merges = [
                    call for call in harness.gh_calls() if call[:2] == ["pr", "merge"]
                ]
                self.assertEqual(
                    merges,
                    [
                        [
                            "pr",
                            "merge",
                            PR_NUMBER,
                            "-R",
                            REPO_SLUG,
                            "--admin",
                            "--merge",
                            "--match-head-commit",
                            APPROVED_HEAD,
                        ]
                    ],
                )
                self.assertIn(
                    ["issue", "close", LINKED_ISSUE, "-R", REPO_SLUG],
                    harness.gh_calls(),
                )
                git = harness.git_calls()
                self.assertIn(
                    ["-C", CHECKOUT_ROOT, "worktree", "remove", WORKTREE_PATH], git
                )
                self.assertIn(LOCAL_DELETE, git)
                self.assertIn(REMOTE_DELETE, git)
                self.assertIn(
                    ["-C", CHECKOUT_ROOT, "merge", "--ff-only", "origin/" + BASE_BRANCH],
                    git,
                )

    def test_a_cross_repository_head_is_never_deleted_here(self):
        # `headRefName` names a branch in the fork, not here, so deleting it on
        # origin would delete whatever unrelated branch happens to share the
        # name in the base repository. The merge and the local fast-forward are
        # unaffected; both deletions are refused. Nothing is removed either:
        # with no branch of ours, no worktree of ours is on it.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                completed, harness = self.execute(
                    relative_path, cross_repository=True
                )
                self.assertNotEqual(completed.returncode, 0)
                self.assertIn("another repository", completed.stderr)
                git = harness.git_calls()
                self.assertIn(["-C", CHECKOUT_ROOT, "fetch", "origin"], git)
                self.assertIn(
                    ["-C", CHECKOUT_ROOT, "merge", "--ff-only", "origin/" + BASE_BRANCH],
                    git,
                )
                for call in git:
                    self.assertNotIn("remove", call, call)
                    self.assertNotIn("update-ref", call, call)
                    self.assertNotIn("--delete", call, call)

    def test_a_checkout_off_the_base_branch_keeps_its_local_branches(self):
        # `--ff-only` advances whatever branch the checkout has out, so a pull
        # request targeting a non-default base would otherwise move the
        # default branch somewhere it should not go.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                completed, harness = self.execute(
                    relative_path, checked_out="some-other-branch"
                )
                self.assertNotEqual(completed.returncode, 0)
                self.assertIn(
                    "not on the base branch of this pull request", completed.stderr
                )
                git = harness.git_calls()
                self.assertIn(
                    ["-C", CHECKOUT_ROOT, "worktree", "remove", WORKTREE_PATH], git
                )
                for call in git:
                    self.assertNotIn("merge", call, call)
                    self.assertNotIn("branch", call, call)
                    self.assertNotIn("--delete", call, call)

    def test_a_detached_head_keeps_its_local_branches_too(self):
        # `symbolic-ref` prints nothing on a detached HEAD, which the guard has
        # to read as "not on the base" rather than as a match.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                completed, harness = self.execute(relative_path, checked_out="")
                self.assertNotEqual(completed.returncode, 0)
                for call in harness.git_calls():
                    self.assertNotIn("merge", call, call)
                    self.assertNotIn("--delete", call, call)

    def test_a_merged_pull_request_with_no_linked_issue_closes_nothing(self):
        # A standalone pull request is ordinary, and it is not a reason to
        # leave the rest of the cleanup undone.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                completed, harness = self.execute(relative_path, linked_issue=None)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                for call in harness.gh_calls():
                    self.assertNotEqual(call[:2], ["issue", "close"], call)
                git = harness.git_calls()
                self.assertIn(
                    ["-C", CHECKOUT_ROOT, "merge", "--ff-only", "origin/" + BASE_BRANCH],
                    git,
                )
                self.assertIn(LOCAL_DELETE, git)

    def test_an_issue_that_already_closed_itself_is_left_alone(self):
        # `Closes #<n>` closes it on merge, so this is the ordinary case.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                completed, harness = self.execute(relative_path, issue_open=False)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                for call in harness.gh_calls():
                    self.assertNotEqual(call[:2], ["issue", "close"], call)

    def test_a_same_numbered_worktree_for_another_branch_is_left_alone(self):
        # A path is no more an identity than a branch name is: an
        # `issue-<n>-` substring matches a stale worktree for a different pull
        # request that happens to share the number style.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                completed, harness = self.execute(
                    relative_path, worktree_listing=DECOY_LISTING
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                for call in harness.git_calls():
                    self.assertNotIn(DECOY_PATH, call, call)
                    self.assertNotIn("remove", call, call)

    def test_a_pull_request_with_no_linked_issue_matches_no_worktree(self):
        # The collision the old pattern opened: with no issue it reduced to
        # `issue--`, which an unrelated leftover path could satisfy. Selection
        # does not read the issue number at all any more.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                completed, harness = self.execute(
                    relative_path,
                    linked_issue=None,
                    worktree_listing=EMPTY_ISSUE_DECOY_LISTING,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                for call in harness.git_calls():
                    self.assertNotIn(EMPTY_ISSUE_DECOY_PATH, call, call)
                    self.assertNotIn("remove", call, call)

    def test_a_worktree_that_moved_past_the_reviewed_head_is_left_alone(self):
        # Right branch, wrong commit: it carries work this run did not merge,
        # so it is not this run's to remove.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                completed, harness = self.execute(
                    relative_path, worktree_listing=MOVED_ON_LISTING
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                for call in harness.git_calls():
                    self.assertNotIn("remove", call, call)

    def test_the_matching_worktree_is_the_one_removed(self):
        # Non-vacuity for the three assertions above: the same selection, with
        # the pull request's own worktree present, really does find it.
        listing = (
            PRIMARY_RECORD
            + "\n"
            + worktree_record(DECOY_PATH, "2" * 40, "issue-7-something-else")
            + "\n"
            + worktree_record(WORKTREE_PATH, APPROVED_HEAD, HEAD_BRANCH)
        )
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                _, harness = self.execute(relative_path, worktree_listing=listing)
                removals = [
                    call for call in harness.git_calls() if "remove" in call
                ]
                self.assertEqual(
                    removals,
                    [["-C", CHECKOUT_ROOT, "worktree", "remove", WORKTREE_PATH]],
                )

    def test_a_pull_request_with_no_registered_worktree_removes_none(self):
        # The worktree may have been removed already, which is not a reason to
        # run `git worktree remove` against an empty path and then step past
        # the error into the rest of the cleanup.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                completed, harness = self.execute(
                    relative_path, worktree_listing=PRIMARY_RECORD
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                for call in harness.git_calls():
                    self.assertNotIn("remove", call, call)
                git = harness.git_calls()
                self.assertIn(
                    ["-C", CHECKOUT_ROOT, "merge", "--ff-only", "origin/" + BASE_BRANCH],
                    git,
                )
                self.assertIn(LOCAL_DELETE, git)
                self.assertIn(
                    ["issue", "close", LINKED_ISSUE, "-R", REPO_SLUG],
                    harness.gh_calls(),
                )

    def test_no_skipped_step_is_run_against_an_empty_argument(self):
        # The defect the two skips above close: `git worktree remove ""` and
        # `gh issue close ""` are errors this workflow, having no `set -e`,
        # would step straight past.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                _, harness = self.execute(
                    relative_path,
                    worktree_listing=PRIMARY_RECORD,
                    linked_issue=None,
                )
                for call in harness.git_calls() + harness.gh_calls():
                    self.assertNotIn("", call[1:], call)

    def test_a_reused_branch_name_is_never_deleted_by_name_alone(self):
        # A name is not an identity. Both deletions carry the reviewed head as
        # the value they expect to find, so a branch another actor deleted and
        # recreated under the same name cannot be removed by this run.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                _, harness = self.execute(relative_path)
                git = harness.git_calls()
                self.assertIn(LOCAL_DELETE, git)
                self.assertIn(REMOTE_DELETE, git)
                for call in git:
                    if "--delete" in call:
                        lease = [
                            argument
                            for argument in call
                            if argument.startswith("--force-with-lease=")
                        ]
                        self.assertEqual(
                            lease,
                            [
                                "--force-with-lease=refs/heads/"
                                + HEAD_BRANCH
                                + ":"
                                + APPROVED_HEAD
                            ],
                            call,
                        )
                    if "update-ref" in call:
                        self.assertEqual(call[-1], APPROVED_HEAD, call)

    def test_a_primary_checkout_without_the_branch_still_deletes_the_remote(self):
        # Finalizing a pull request whose worktree was somebody else's is a
        # skip, not a failure, and it must not cost the remote deletion.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                completed, harness = self.execute(relative_path, local_branch=None)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                git = harness.git_calls()
                for call in git:
                    self.assertNotIn("update-ref", call, call)
                self.assertIn(REMOTE_DELETE, git)

    def test_a_failed_cleanup_step_deletes_nothing_after_it(self):
        # The cleanup is one `&&` chain precisely so a failure here does not
        # leave a still-checked-out worktree behind while its branch is deleted
        # out from under it.
        for relative_path in RENDERED_ASSETS:
            for index, failing in enumerate(CLEANUP_CHAIN[:-1]):
                with self.subTest(asset=relative_path, step=" ".join(failing)):
                    completed, harness = self.execute(
                        relative_path,
                        failing_git=failing,
                        include_issue_close=False,
                    )
                    self.assertNotEqual(completed.returncode, 0)
                    git = harness.git_calls()
                    # The failing step was attempted, and nothing after it was.
                    self.assertTrue(
                        any(matches_step(call, failing) for call in git), git
                    )
                    for later in CLEANUP_CHAIN[index + 1 :]:
                        for call in git:
                            self.assertFalse(
                                matches_step(call, later),
                                f"{' '.join(later)} ran after {' '.join(failing)} "
                                f"failed: {call}",
                            )

    def test_a_push_url_naming_another_repository_deletes_nothing_remote(self):
        # $REPO comes from the FETCH url. A checkout that fetches from this
        # repository and pushes to another passes every other check --
        # isCrossRepository included -- and would then delete a same-named
        # branch over there.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                completed, harness = self.execute(
                    relative_path, push_repos=("someone-else/kanban",)
                )
                self.assertNotEqual(completed.returncode, 0)
                self.assertIn("does not reach the repository", completed.stderr)
                git = harness.git_calls()
                # The local cleanup up to that point still happened.
                self.assertIn(LOCAL_DELETE, git)
                for call in git:
                    self.assertNotIn("--delete", call, call)

    def test_a_push_url_spelled_in_another_case_is_the_same_repository(self):
        # Non-vacuity for the guard above, and the reason it folds case: a
        # remote URL may spell the identity any way and still name this
        # repository, so an exact match would refuse an ordinary checkout.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                completed, harness = self.execute(
                    relative_path, push_repos=("Coghex/Kanban",)
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertIn(REMOTE_DELETE, harness.git_calls())

    def test_a_second_push_url_naming_another_repository_deletes_nothing(self):
        # `remote.origin.pushurl` is multi-valued and `git push origin` writes
        # to every one of them, so validating the first is not validating the
        # push: a checkout whose first URL is this repository and whose second
        # is a foreign one would delete the same-named branch over there too.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                completed, harness = self.execute(
                    relative_path,
                    push_repos=(REPO_SLUG, "someone-else/kanban"),
                )
                self.assertNotEqual(completed.returncode, 0)
                self.assertIn("does not reach", completed.stderr)
                for call in harness.git_calls():
                    self.assertNotIn("--delete", call, call)

    def test_several_push_urls_all_naming_this_repository_are_accepted(self):
        # Non-vacuity for the check above: it must not simply refuse every
        # multi-URL remote.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                completed, harness = self.execute(
                    relative_path, push_repos=(REPO_SLUG, "Coghex/Kanban")
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertIn(REMOTE_DELETE, harness.git_calls())

    def test_a_remote_with_no_push_url_at_all_deletes_nothing(self):
        # The `seen` half of the check: an empty listing is not "every URL
        # matches", it is nothing to have checked.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                completed, harness = self.execute(relative_path, push_repos=())
                self.assertNotEqual(completed.returncode, 0)
                for call in harness.git_calls():
                    self.assertNotIn("--delete", call, call)

    def test_the_gate_is_re_read_before_the_merge(self):
        # Two runs means two of each read, which is what makes the refresh
        # observable rather than assumed.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                _, harness = self.execute(relative_path)
                gate_reads = [
                    call
                    for call in harness.gh_calls()
                    if call[:6]
                    == ["pr", "view", PR_NUMBER, "-R", REPO_SLUG, "--json"]
                    and call[6] == PR_VIEW_FIELDS
                ]
                self.assertEqual(len(gate_reads), 2, harness.gh_calls())

    def test_the_log_records_a_merge_when_one_really_happens(self):
        # The control for every assertNoMutation above: run the merge fence
        # with a head already in hand and the same log DOES carry a merge, so
        # the refusals are proving an absence the harness can observe.
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        harness = Harness(Path(directory.name))
        harness.script_github()
        script = (
            f'HEAD="{APPROVED_HEAD}"\n'
            + fence_containing(read(CLAUDE_ASSET), "gh pr merge")
        )
        completed = harness.run(script)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(
            [call for call in harness.gh_calls() if call[:2] == ["pr", "merge"]],
            [
                [
                    "pr",
                    "merge",
                    PR_NUMBER,
                    "-R",
                    REPO_SLUG,
                    "--admin",
                    "--merge",
                    "--match-head-commit",
                    APPROVED_HEAD,
                ]
            ],
        )
        with self.assertRaises(AssertionError):
            self.assertNoMutation(harness)


class ResolutionTests(unittest.TestCase):
    """Requirement 4's first half, run against a real Git checkout: one
    repository identity, and the primary checkout even from inside a linked
    worktree."""

    def git(self, cwd: Path, *arguments: str) -> None:
        subprocess.run(
            ["git", *arguments],
            cwd=str(cwd),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=True,
        )

    def resolve(self, relative_path: str, url: str, from_worktree: bool):
        script = (
            fence_containing(read(relative_path), REPOSITORY_RESOLUTION)
            + '\nprintf "%s\\n%s\\n" "$ROOT" "$REPO"\n'
        )
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            checkout = base / "checkout"
            checkout.mkdir()
            self.git(checkout, "init", "--quiet", "-b", "master")
            self.git(checkout, "config", "user.email", "finalize@example.invalid")
            self.git(checkout, "config", "user.name", "Finalize Fixture")
            self.git(checkout, "config", "commit.gpgsign", "false")
            self.git(checkout, "commit", "--quiet", "--allow-empty", "-m", "base")
            self.git(checkout, "remote", "add", "origin", url)
            cwd = checkout
            if from_worktree:
                linked = base / "linked"
                self.git(checkout, "worktree", "add", "--quiet", str(linked), "-b", "work")
                cwd = linked
            completed = subprocess.run(
                ["sh", "-c", script],
                cwd=str(cwd),
                env={"PATH": os.environ.get("PATH", ""), "HOME": str(base / "home")},
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                check=True,
            )
        root, repo = completed.stdout.strip().splitlines()
        return root, repo, checkout

    def test_every_remote_spelling_yields_one_owner_name(self):
        for relative_path in RENDERED_ASSETS:
            for url in (
                "https://github.com/example/demo.git",
                "https://github.com/example/demo",
                "git@github.com:example/demo.git",
            ):
                with self.subTest(asset=relative_path, url=url):
                    _, repo, _ = self.resolve(relative_path, url, from_worktree=False)
                    self.assertEqual(repo, "example/demo")

    def test_the_root_is_the_primary_checkout_even_from_a_linked_worktree(self):
        # The cleanup removes a worktree, so it must not run from inside one.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                root, repo, checkout = self.resolve(
                    relative_path,
                    "https://github.com/example/demo.git",
                    from_worktree=True,
                )
                self.assertEqual(Path(root).resolve(), checkout.resolve())
                self.assertEqual(repo, "example/demo")

    def test_the_two_renderings_resolve_identically(self):
        results = [
            self.resolve(path, "git@github.com:example/demo.git", from_worktree=False)[1]
            for path in RENDERED_ASSETS
        ]
        self.assertEqual(results[0], results[1])


class RetiredClaimTests(unittest.TestCase):
    """Requirement 6: a claim that no longer holds is corrected in the
    rendering rather than carried over."""

    def test_no_retired_claim_survives_in_either_rendering(self):
        for relative_path in RENDERED_ASSETS:
            content = flat(read(relative_path))
            for label, phrase in RETIRED_CLAIMS.items():
                with self.subTest(asset=relative_path, claim=label):
                    self.assertNotIn(phrase, content)

    def test_each_retirement_replaced_the_claim_rather_than_deleting_it(self):
        for relative_path in RENDERED_ASSETS:
            content = flat(read(relative_path))
            for label, phrase in REPLACEMENT_TEXT.items():
                with self.subTest(asset=relative_path, replacement=label):
                    self.assertIn(phrase, content)

    def test_neither_service_manager_is_asserted_as_the_manager(self):
        # tools/service_manager.py drives launchd on macOS and systemd user
        # units on Linux behind one boundary, so a tracked asset naming either
        # would be wrong on the other host.
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path).lower()
            for name in SERVICE_MANAGER_NAMES:
                with self.subTest(asset=relative_path, manager=name):
                    self.assertNotIn(name, content)

    def test_the_retired_claim_detector_finds_a_planted_claim(self):
        planted = flat(read(CLAUDE_ASSET) + "\nThe launchd-managed PR drainer.\n")
        self.assertIn(RETIRED_CLAIMS["launchd as the drainer's manager"], planted)


class PrivateIdentifierTests(unittest.TestCase):
    """Requirement 7: no personal identifier reaches a tracked asset, in either
    rendering or in either bundle's description of this workflow."""

    def surfaces(self) -> dict[str, str]:
        found = {path: read(path) for path in RENDERED_ASSETS}
        for manifest in (
            "claude-plugin/.claude-plugin/marketplace.json",
            "claude-plugin/plugins/kanban/.claude-plugin/plugin.json",
            "codex-plugin/plugins/kanban/.codex-plugin/plugin.json",
        ):
            data = json.loads(read(manifest))
            text = json.dumps(data)
            # Only the parts that describe this workflow: a manifest's
            # homepage and repository fields name the owner's account by
            # necessity, and are not what this rule is about.
            found[manifest] = "\n".join(
                fragment
                for fragment in re.findall(r'"[^"]*finalize[^"]*"', text)
            )
        return found

    def test_no_private_identifier_is_tracked(self):
        for surface, content in self.surfaces().items():
            for label, token in PRIVATE_IDENTIFIERS.items():
                with self.subTest(surface=surface, identifier=label):
                    self.assertNotIn(token, content)

    def test_the_workflow_fragments_really_describe_this_workflow(self):
        # Non-vacuity: an extraction that found nothing would report no
        # identifier for the same reason a clean manifest does.
        surfaces = self.surfaces()
        for surface, content in surfaces.items():
            with self.subTest(surface=surface):
                self.assertIn("finalize", content)


class PreservedBehaviorTests(unittest.TestCase):
    """Requirement 8: the workflow still presents itself as the fallback, and
    the rules the personal copy carried are still the rules."""

    def test_every_preserved_rule_survives_in_both_renderings(self):
        for relative_path in RENDERED_ASSETS:
            content = flat(read(relative_path))
            for label, phrase in PRESERVED_BEHAVIOR.items():
                with self.subTest(asset=relative_path, rule=label):
                    self.assertIn(flat(phrase), content)

    def test_the_drainer_remains_the_ordinary_merge_owner(self):
        for relative_path in RENDERED_ASSETS:
            content = flat(read(relative_path))
            with self.subTest(asset=relative_path):
                self.assertIn("This is the fallback, not the merge path.", content)
                self.assertIn(
                    "It runs when the user asks for it in that turn", content
                )

    def test_the_root_instruction_keeps_the_prohibition_and_names_the_exception(self):
        # The review's correction: CLAUDE.md cannot leave "never merge a pull
        # request" textually intact beside a workflow that runs `gh pr merge`,
        # and it cannot drop the prohibition either.
        content = flat(read("CLAUDE.md"))
        self.assertIn("Never merge a pull request on your own initiative.", content)
        self.assertIn(
            "`tools/drain_prs.py` owns merging eligible PRs out of the Done column.",
            content,
        )
        self.assertIn("The single exception is the packaged `finalize` workflow", content)

    def test_the_contract_declares_finalize_as_the_sole_manual_fallback(self):
        content = flat(read("docs/agent-workflow-contract.md"))
        self.assertIn("### 2.10 Manual finalization", content)
        self.assertIn(
            "`tools/drain_prs.py` owns merging eligible approved pull requests "
            "out of the Done column, and that ownership is unchanged.",
            content,
        )
        self.assertIn("`finalize` is the one declared exception", content)

    def test_both_declaring_documents_are_reachable_from_the_asset_claim(self):
        # Non-vacuity for the two assertions above: they read documents this
        # module names, so the asset has to actually point at the contract
        # section that carries the exception.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertIn("service-managed PR drainer", read(relative_path))


class BrandBoundaryTests(unittest.TestCase):
    """The two renderings differ only where the source says they may."""

    def stripped(self, relative_path: str, brand: str, drop) -> list[str]:
        lines = neutralize(body_of(read(relative_path)), brand).splitlines()
        return [line for line in lines if line not in drop]

    def test_the_bodies_differ_only_by_the_declared_brand_lines(self):
        claude = self.stripped(CLAUDE_ASSET, "claude", CLAUDE_ONLY_LINES)
        codex = self.stripped(CODEX_ASSET, "codex", CODEX_ONLY_LINES)
        self.assertEqual(claude, codex)

    def test_the_argument_convention_is_per_brand(self):
        claude = read(CLAUDE_ASSET)
        codex = read(CODEX_ASSET)
        for line in CLAUDE_ONLY_LINES:
            self.assertIn(line, claude)
            self.assertNotIn(line, codex)
        for line in CODEX_ONLY_LINES:
            self.assertIn(line, codex)
            self.assertNotIn(line, claude)

    def test_the_brand_comparison_detects_a_planted_divergence(self):
        claude = self.stripped(CLAUDE_ASSET, "claude", CLAUDE_ONLY_LINES)
        self.assertNotEqual(claude + ["planted"], self.stripped(CODEX_ASSET, "codex", CODEX_ONLY_LINES))


if __name__ == "__main__":
    unittest.main()
