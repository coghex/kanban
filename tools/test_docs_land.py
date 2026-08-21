"""Regression tests for tools/docs_land.sh and its push-docs workflow assets.

Run with: python3 -m unittest discover -s tools -p 'test_docs_land.py'

Issue #410. The helper's whole reason to exist is that it lands ONLY the
paths it is named while the docs worktree is deliberately holding OTHER
unfinished documents — dirty, staged, or already committed — and it pushes
straight to master under admin bypass with no PR review. Every landing case
here runs the real script against a hermetic, offline sandbox: a local bare
repository as `origin`, a primary worktree on `master` and a second worktree
on `docs-wip`, because the script resolves both worktrees BY BRANCH and
unconditionally fetches and pushes. The bare origin carries a pre-receive
hook that prints the protected-ref warning on every push, so every landing
here also proves success is judged by rev-list reachability rather than push
output. The sandbox overrides HOME and the git config environment so a
developer's global git settings cannot make these pass or fail for unrelated
reasons.

The sandbox seeds its own docs/agent-workflow-contract.md with a §7
classification fence, because the script reads classification from the
publication tip (`origin/master`) of whatever repository it runs in.

`PushDocsWorkflowAssetTests` at the bottom covers the two rendered workflow
assets the same way WriteLocationTests covers the drafting assets: the rules
each asset owes, the removal of each rule detected, and a negative control so
a rule matching everything cannot pass while asserting nothing.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "tools" / "docs_land.sh"


def _load_paths_module():
    """tools/docs_land_paths.py loaded by path under a private name, so the
    function-level assertions work whether this module was discovered with
    `-s tools` or imported as `tools.test_docs_land`, and a fresh load per
    call keeps the module's per-worktree cache from crossing sandboxes."""
    import importlib.util

    source = REPO_ROOT / "tools" / "docs_land_paths.py"
    spec = importlib.util.spec_from_file_location(
        "_docs_land_paths_under_test", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

# A 20-line body so an upstream edit to the LAST line and a local edit to
# the FIRST line merge cleanly. The force-override case needs a file that
# is dirty here and also changed upstream (to trip the risk predictor)
# without the autostash replay then conflicting for unrelated reasons.
B_SEED = "".join(f"b line {i}\n" for i in range(1, 21))

# The classification the sandbox's origin/master publishes. The gated rows
# mirror the real repository's shape: the root instruction documents carry
# the coupled reasons the root-contract exception overrides, docs/design.md
# is the refused code-gated path, and docs/coordination/ is a directory row.
SANDBOX_CONTRACT = """# Contract

## 7. Document publication classification

Sandbox copy; only the fence below matters to the reader under test.

```text
AGENTS.md | pr-atomic | release-document;implementation-coupled
CLAUDE.md | pr-atomic | release-document;implementation-coupled
docs/agent-workflow-contract.md | pr-atomic | test-parsed;release-document;implementation-coupled
docs/design.md | pr-atomic | test-parsed;release-document;implementation-coupled
docs/a.md | coordination | audit-report
docs/b.md | coordination | audit-report
docs/del.md | coordination | audit-report
docs/keep.md | coordination | audit-report
docs/new.md | coordination | audit-report
docs/upstream.md | coordination | audit-report
docs/coordination/ | coordination | coordination-note
```
"""

PROTECTED_REF_HOOK = """#!/bin/sh
echo "Bypassed rule violations found for refs/heads/master:" >&2
echo "- Changes must be made through a pull request." >&2
exit 0
"""


class Sandbox:
    """A throwaway repo trio: bare origin + master worktree + docs-wip."""

    def __init__(self, tmp: str) -> None:
        # realpath because git records resolved worktree paths and macOS
        # hands out /var/folders symlinks for temp directories.
        self.root = Path(os.path.realpath(tmp))
        self.origin = self.root / "origin.git"
        self.main = self.root / "main"
        self.docs = self.root / "docs"

        home = self.root / "home"
        home.mkdir()
        gitconfig = self.root / "gitconfig"
        gitconfig.write_text("", encoding="utf-8")

        # Drop every inherited GIT_* variable: GIT_DIR or GIT_WORK_TREE
        # leaking in from the caller would point the sandbox at the real
        # repository.
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        env.update({
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "GIT_CONFIG_GLOBAL": str(gitconfig),
            "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_AUTHOR_NAME": "Docs Land Test",
            "GIT_AUTHOR_EMAIL": "docs-land@example.invalid",
            "GIT_COMMITTER_NAME": "Docs Land Test",
            "GIT_COMMITTER_EMAIL": "docs-land@example.invalid",
            "GIT_EDITOR": "true",
            "GIT_TERMINAL_PROMPT": "0",
            "LC_ALL": "C",
        })
        self.env = env
        self._build()

    # --- plumbing -----------------------------------------------------
    def git(self, *args: str, cwd: Path | None = None) -> str:
        done = subprocess.run(
            ["git", *args], cwd=str(cwd or self.main), env=self.env,
            capture_output=True, text=True)
        if done.returncode != 0:
            raise RuntimeError(
                f"sandbox git {' '.join(args)} failed:\n{done.stderr}")
        return done.stdout

    def _build(self) -> None:
        subprocess.run(["git", "init", "--bare", "-q", str(self.origin)],
                       env=self.env, check=True, capture_output=True)
        # Name the default branch explicitly: init.defaultBranch is `main`
        # on current git, and the script only knows `master`.
        self.git("symbolic-ref", "HEAD", "refs/heads/master", cwd=self.origin)
        hook = self.origin / "hooks" / "pre-receive"
        hook.parent.mkdir(exist_ok=True)
        hook.write_text(PROTECTED_REF_HOOK, encoding="utf-8")
        hook.chmod(0o755)

        self.main.mkdir()
        self.git("init", "-q")
        self.git("symbolic-ref", "HEAD", "refs/heads/master")
        self.git("config", "user.name", "Docs Land Test")
        self.git("config", "user.email", "docs-land@example.invalid")
        self.git("config", "commit.gpgsign", "false")

        (self.main / "docs").mkdir()
        self.write(self.main, "docs/a.md", "a seed\n")
        self.write(self.main, "docs/b.md", B_SEED)
        self.write(self.main, "docs/del.md", "del seed\n")
        self.write(self.main, "docs/keep.md", "keep seed\n")
        self.write(self.main, "docs/design.md", "design seed\n")
        self.write(self.main, "docs/agent-workflow-contract.md", SANDBOX_CONTRACT)
        self.write(self.main, "docs/coordination/README.md", "notes live here\n")
        self.write(self.main, "CLAUDE.md", "root contract seed\n")
        os.symlink("CLAUDE.md", self.main / "AGENTS.md")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "seed")
        self.git("remote", "add", "origin", str(self.origin))
        self.git("push", "-q", "-u", "origin", "master")
        self.git("worktree", "add", "-q", str(self.docs), "-b", "docs-wip",
                 "origin/master")

    # --- fixtures -----------------------------------------------------
    @staticmethod
    def write(wt: Path, rel: str, text: str) -> None:
        path = wt / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def stage_unrelated_b(self, body: str = "b wip\n" + B_SEED) -> str:
        """Leave an unfinished, STAGED docs/b.md in the docs worktree."""
        self.write(self.docs, "docs/b.md", body)
        self.git("add", "docs/b.md", cwd=self.docs)
        return body

    def move_master_upstream(self, rel: str = "docs/upstream.md") -> None:
        """Advance origin/master via a path that is NOT dirty in docs/."""
        self.write(self.main, rel, "upstream\n")
        self.git("add", rel)
        self.git("commit", "-q", "-m", "upstream change")
        self.git("push", "-q", "origin", "master")

    # --- observations -------------------------------------------------
    def run_script(self, *args: str) -> subprocess.CompletedProcess:
        """Invoke the real script from the PRIMARY checkout, as documented.

        Decoded as utf-8 explicitly: the inventory emits filenames in utf-8
        whatever the locale, and these assertions read them back verbatim."""
        return subprocess.run(
            ["bash", str(SCRIPT), *args], cwd=str(self.main), env=self.env,
            capture_output=True, encoding="utf-8")

    def head(self, ref: str = "HEAD") -> str:
        return self.git("rev-parse", ref, cwd=self.docs).strip()

    def commit_files(self, ref: str = "origin/master") -> set[str]:
        """The paths the tip commit of `ref` touched."""
        out = self.git("diff-tree", "--no-commit-id", "--name-only", "-r",
                       ref, cwd=self.docs)
        return {line for line in out.splitlines() if line}

    def porcelain(self, wt: Path) -> dict[str, str]:
        out = self.git("status", "--porcelain", cwd=wt)
        return {line[3:]: line[:2] for line in out.splitlines() if line}

    def blob(self, ref: str, rel: str) -> str | None:
        try:
            return self.git("show", f"{ref}:{rel}", cwd=self.docs)
        except RuntimeError:
            return None

    def tracked(self, ref: str) -> set[str]:
        out = self.git("ls-tree", "-r", "--name-only", ref, cwd=self.docs)
        return {line for line in out.splitlines() if line}

    def index_state(self, wt: Path) -> str:
        return self.git("ls-files", "-s", cwd=wt)

    def snapshot(self) -> dict:
        """Everything a refused or dry run must leave untouched."""
        return {
            "head": self.head(),
            "upstream": self.head("origin/master"),
            "index": self.index_state(self.docs),
            "status": self.porcelain(self.docs),
            "main_head": self.git("rev-parse", "HEAD").strip(),
        }


class DocsLandCase(unittest.TestCase):
    """One sandbox per test, torn down with the temporary directory."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="docs-land-test-")
        self.addCleanup(self.tmp.cleanup)
        self.sb = Sandbox(self.tmp.name)


class NamedPathIsolationTests(DocsLandCase):
    def test_unrelated_staged_file_is_not_landed(self):
        sb = self.sb
        sb.write(sb.docs, "docs/a.md", "a landed\n")
        b_body = sb.stage_unrelated_b()
        # Unrelated UNSTAGED work too: the guarantee covers both.
        sb.write(sb.docs, "docs/keep.md", "keep wip\n")

        done = sb.run_script("-m", "Land A", "docs/a.md")
        self.assertEqual(done.returncode, 0, done.stderr)

        # The primary guarantee, asserted directly on the landing commit.
        self.assertEqual(sb.commit_files(), {"docs/a.md"})
        self.assertEqual(sb.blob("origin/master", "docs/a.md"), "a landed\n")
        self.assertEqual(sb.blob("origin/master", "docs/b.md"), B_SEED)
        self.assertEqual(sb.blob("origin/master", "docs/keep.md"), "keep seed\n")

        # The unmoved-master case takes the fast path, so each side keeps its
        # exact prior index disposition — staged stays staged, dirty stays
        # dirty — and docs-wip ends on the landing commit.
        status = sb.porcelain(sb.docs)
        self.assertEqual(status.get("docs/b.md"), "M ", status)
        self.assertEqual(status.get("docs/keep.md"), " M", status)
        self.assertEqual(
            (sb.docs / "docs/b.md").read_text(encoding="utf-8"), b_body)
        self.assertEqual(
            (sb.docs / "docs/keep.md").read_text(encoding="utf-8"), "keep wip\n")
        self.assertEqual(sb.head(), sb.head("origin/master"))

        self.assertIn("landed: origin/master now contains", done.stdout)
        self.assertIn("docs-wip fast-forwarded to the landing commit", done.stdout)
        self.assertIn("primary checkout fast-forwarded", done.stdout)

    def test_unchanged_named_path_publishes_nothing(self):
        sb = self.sb
        b_body = sb.stage_unrelated_b()
        before = sb.snapshot()

        done = sb.run_script("-m", "Land A", "docs/a.md")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("nothing to land", done.stdout)
        self.assertEqual(sb.head(), before["head"])
        self.assertEqual(sb.head("origin/master"), before["upstream"])
        self.assertEqual(sb.blob("origin/master", "docs/b.md"), B_SEED)
        self.assertEqual(sb.porcelain(sb.docs).get("docs/b.md"), "M ")
        self.assertEqual(
            (sb.docs / "docs/b.md").read_text(encoding="utf-8"), b_body)

    def test_add_modify_delete_across_multiple_paths(self):
        sb = self.sb
        sb.write(sb.docs, "docs/a.md", "a modified\n")
        sb.write(sb.docs, "docs/new.md", "brand new\n")
        (sb.docs / "docs/del.md").unlink()
        sb.stage_unrelated_b()

        done = sb.run_script("-m", "Land three", "docs/a.md", "docs/del.md",
                             "docs/new.md")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(
            sb.commit_files(), {"docs/a.md", "docs/del.md", "docs/new.md"})

        published = sb.tracked("origin/master")
        self.assertIn("docs/new.md", published)
        self.assertNotIn("docs/del.md", published)
        self.assertEqual(sb.blob("origin/master", "docs/a.md"), "a modified\n")
        self.assertEqual(sb.blob("origin/master", "docs/b.md"), B_SEED)
        self.assertEqual(sb.porcelain(sb.docs).get("docs/b.md"), "M ")


class FileModeTests(DocsLandCase):
    def test_executable_bit_changes_land_and_survive_content_updates(self):
        # An executable-bit-only change is a real difference: with a
        # hard-coded landing mode it would report as unchanged and never
        # land, and a later content update would silently strip the bit.
        sb = self.sb
        (sb.docs / "docs/a.md").chmod(0o755)

        plan = sb.run_script("-n", "-m", "Make A executable", "docs/a.md")
        self.assertEqual(plan.returncode, 0, plan.stderr)
        self.assertIn("plan: land docs/a.md (mode)", plan.stdout)

        done = sb.run_script("-m", "Make A executable", "docs/a.md")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("landed: origin/master now contains", done.stdout)
        listed = sb.git(
            "ls-tree", "origin/master", "--", "docs/a.md", cwd=sb.docs)
        self.assertEqual(listed.split()[0], "100755")
        self.assertEqual(sb.blob("origin/master", "docs/a.md"), "a seed\n")

        sb.write(sb.docs, "docs/a.md", "a executable landed\n")
        (sb.docs / "docs/a.md").chmod(0o755)
        done = sb.run_script("-m", "Update A", "docs/a.md")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(
            sb.blob("origin/master", "docs/a.md"), "a executable landed\n")
        listed = sb.git(
            "ls-tree", "origin/master", "--", "docs/a.md", cwd=sb.docs)
        self.assertEqual(listed.split()[0], "100755")


class CommittedWorkTests(DocsLandCase):
    def test_committed_unselected_work_survives_locally_and_never_lands(self):
        # CLAUDE.md directs agents to leave standalone changes committed and
        # unpushed on docs-wip, so a landing must work in exactly that state:
        # the selected committed document lands, the unselected committed one
        # neither lands nor is lost.
        sb = self.sb
        sb.write(sb.docs, "docs/a.md", "a committed\n")
        sb.git("add", "docs/a.md", cwd=sb.docs)
        sb.git("commit", "-q", "-m", "WIP a", cwd=sb.docs)
        sb.write(sb.docs, "docs/b.md", "b committed\n")
        sb.git("add", "docs/b.md", cwd=sb.docs)
        sb.git("commit", "-q", "-m", "WIP b", cwd=sb.docs)

        done = sb.run_script("-m", "Land A", "docs/a.md")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(sb.commit_files(), {"docs/a.md"})
        self.assertEqual(sb.blob("origin/master", "docs/a.md"), "a committed\n")
        self.assertEqual(sb.blob("origin/master", "docs/b.md"), B_SEED)

        # The unselected commit survives locally, still unpushed; the
        # selected one became empty on the rebase and was dropped.
        ahead = sb.git("rev-list", "--count", "origin/master..HEAD",
                       cwd=sb.docs).strip()
        self.assertEqual(ahead, "1")
        self.assertEqual(sb.blob("HEAD", "docs/b.md"), "b committed\n")
        self.assertIn("1 unpushed local commit(s)", done.stdout)

    def test_prior_interrupted_landing_still_completes(self):
        # A run interrupted after its local commit but before any push: the
        # rerun lands the same content and converges docs-wip onto it.
        sb = self.sb
        sb.write(sb.docs, "docs/a.md", "a landed\n")
        sb.git("add", "docs/a.md", cwd=sb.docs)
        sb.git("commit", "-q", "-m", "Land A", cwd=sb.docs)
        b_body = sb.stage_unrelated_b()

        done = sb.run_script("-m", "Land A", "docs/a.md")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(sb.blob("origin/master", "docs/a.md"), "a landed\n")
        self.assertEqual(sb.blob("origin/master", "docs/b.md"), B_SEED)
        ahead = sb.git("rev-list", "--count", "origin/master..HEAD",
                       cwd=sb.docs).strip()
        self.assertEqual(ahead, "0")
        # Reconciliation ran the rebase path, so only survival is guaranteed
        # for the unrelated work — the autostash replays without --index.
        self.assertEqual(
            (sb.docs / "docs/b.md").read_text(encoding="utf-8"), b_body)
        self.assertIn("docs/b.md", sb.porcelain(sb.docs))


class RebasePathTests(DocsLandCase):
    def test_isolation_holds_when_the_rebase_path_runs(self):
        sb = self.sb
        # Move master via a path that is NOT dirty here, so the pre-flight
        # risk predictor does not exit 3 before the rebase is exercised.
        sb.move_master_upstream()
        sb.write(sb.docs, "docs/a.md", "a landed\n")
        b_body = sb.stage_unrelated_b()

        done = sb.run_script("-m", "Land A", "docs/a.md")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("rebasing onto the landed master", done.stdout)
        self.assertEqual(sb.commit_files(), {"docs/a.md"})

        published = sb.tracked("origin/master")
        self.assertIn("docs/upstream.md", published)
        self.assertEqual(sb.blob("origin/master", "docs/a.md"), "a landed\n")
        self.assertEqual(sb.blob("origin/master", "docs/b.md"), B_SEED)
        # On the rebase path only SURVIVAL is required: git's autostash
        # replays with `git stash apply` (never --index), so staged entries
        # legitimately come back unstaged.
        self.assertEqual(
            (sb.docs / "docs/b.md").read_text(encoding="utf-8"), b_body)
        self.assertIn("docs/b.md", sb.porcelain(sb.docs))

    def test_risk_predictor_and_force_override(self):
        sb = self.sb
        # docs/b.md dirty here AND changed on master: exactly the
        # autostash-conflict shape the predictor exists to catch.
        sb.write(sb.main, "docs/b.md", B_SEED.replace("b line 20", "b upstream 20"))
        sb.git("add", "docs/b.md")
        sb.git("commit", "-q", "-m", "upstream touches b")
        sb.git("push", "-q", "origin", "master")

        sb.write(sb.docs, "docs/a.md", "a landed\n")
        b_body = "b local 1\n" + "".join(f"b line {i}\n" for i in range(2, 21))
        sb.write(sb.docs, "docs/b.md", b_body)
        sb.git("add", "docs/b.md", cwd=sb.docs)
        before = sb.snapshot()

        blocked = sb.run_script("-m", "Land A", "docs/a.md")
        self.assertEqual(blocked.returncode, 3, blocked.stderr)
        self.assertIn("dirty or untracked here AND changed on master", blocked.stderr)
        self.assertEqual(sb.head(), before["head"])
        self.assertEqual(sb.head("origin/master"), before["upstream"])

        forced = sb.run_script("-f", "-m", "Land A", "docs/a.md")
        self.assertEqual(forced.returncode, 0, forced.stderr)
        self.assertEqual(sb.commit_files(), {"docs/a.md"})
        self.assertEqual(
            sb.blob("origin/master", "docs/b.md"),
            B_SEED.replace("b line 20", "b upstream 20"))
        self.assertEqual(
            (sb.docs / "docs/b.md").read_text(encoding="utf-8"),
            b_body.replace("b line 20", "b upstream 20"))

    def test_untracked_unselected_upstream_collision_is_predicted(self):
        # An unselected path that is untracked here and newly added on
        # master is never autostashed, so the reconciliation rebase's
        # checkout would refuse it outright — after the push had already
        # landed. The predictor must stop before anything is published.
        sb = self.sb
        sb.move_master_upstream("docs/new.md")
        sb.write(sb.docs, "docs/new.md", "local untracked draft\n")
        sb.write(sb.docs, "docs/a.md", "a landed\n")
        before = sb.snapshot()

        blocked = sb.run_script("-m", "Land A", "docs/a.md")
        self.assertEqual(blocked.returncode, 3, blocked.stderr)
        self.assertIn("docs/new.md", blocked.stderr)
        self.assertIn("untracked", blocked.stderr)
        self.assertEqual(sb.snapshot(), before)
        self.assertEqual(
            (sb.docs / "docs/new.md").read_text(encoding="utf-8"),
            "local untracked draft\n")

    def test_ignored_untracked_upstream_collision_is_predicted(self):
        # An IGNORED untracked file is the worst spelling of the collision
        # above: an --exclude-standard listing never shows it, and the
        # reconciliation checkout does not refuse it — it silently overwrites
        # it after the push already landed. The predictor asks about each
        # upstream-changed path's local state directly, so ignored and
        # unignored untracked files stop the run the same way.
        sb = self.sb
        sb.move_master_upstream("docs/new.md")
        exclude = sb.main / ".git" / "info" / "exclude"
        exclude.parent.mkdir(parents=True, exist_ok=True)
        exclude.write_text("docs/new.md\n", encoding="utf-8")
        sb.write(sb.docs, "docs/new.md", "ignored local draft\n")
        sb.write(sb.docs, "docs/a.md", "a landed\n")
        before = sb.snapshot()

        blocked = sb.run_script("-m", "Land A", "docs/a.md")
        self.assertEqual(blocked.returncode, 3, blocked.stderr)
        self.assertIn("docs/new.md", blocked.stderr)
        self.assertIn("ignored", blocked.stderr)
        self.assertEqual(sb.snapshot(), before)
        self.assertEqual(
            (sb.docs / "docs/new.md").read_text(encoding="utf-8"),
            "ignored local draft\n")

    def test_ignored_dangling_symlink_upstream_collision_is_predicted(self):
        # A dangling symlink fails -e yet still occupies its path, and when
        # it is also ignored nothing else surfaces it — the reconciliation
        # checkout would silently replace it after the push landed. The
        # predictor must treat any on-disk presence at an upstream-changed
        # path as a collision.
        sb = self.sb
        sb.move_master_upstream("docs/new.md")
        exclude = sb.main / ".git" / "info" / "exclude"
        exclude.parent.mkdir(parents=True, exist_ok=True)
        exclude.write_text("docs/new.md\n", encoding="utf-8")
        os.symlink("does-not-exist", sb.docs / "docs" / "new.md")
        sb.write(sb.docs, "docs/a.md", "a landed\n")
        before = sb.snapshot()

        blocked = sb.run_script("-m", "Land A", "docs/a.md")
        self.assertEqual(blocked.returncode, 3, blocked.stderr)
        self.assertIn("docs/new.md", blocked.stderr)
        self.assertEqual(sb.snapshot(), before)
        self.assertTrue((sb.docs / "docs/new.md").is_symlink())
        self.assertEqual(
            os.readlink(sb.docs / "docs/new.md"), "does-not-exist")

    def test_ancestor_symlink_upstream_collision_is_predicted(self):
        # The occupant can be an ANCESTOR: an untracked symlink at
        # docs/coordination/newdir while master newly adds a file beneath
        # that component. The leaf neither exists nor is a symlink, so a
        # leaf-only test misses it, yet the reconciliation checkout must
        # replace the symlink to create the real directory — after the push
        # already landed.
        sb = self.sb
        sb.move_master_upstream("docs/coordination/newdir/foo.md")
        os.symlink(
            "does-not-exist", sb.docs / "docs" / "coordination" / "newdir")
        sb.write(sb.docs, "docs/a.md", "a landed\n")
        before = sb.snapshot()

        blocked = sb.run_script("-m", "Land A", "docs/a.md")
        self.assertEqual(blocked.returncode, 3, blocked.stderr)
        self.assertIn("docs/coordination/newdir", blocked.stderr)
        self.assertEqual(sb.snapshot(), before)
        self.assertTrue((sb.docs / "docs/coordination/newdir").is_symlink())
        self.assertEqual(
            os.readlink(sb.docs / "docs/coordination/newdir"),
            "does-not-exist")

    def test_non_ascii_untracked_upstream_collision_is_predicted(self):
        # `git diff --name-only` C-quotes a non-ASCII filename, so a
        # line-based upstream-changed list would carry
        # "docs/coordination/caf\\303\\251.md" and never match the on-disk
        # café.md occupying that path. The NUL-delimited list must.
        sb = self.sb
        sb.move_master_upstream("docs/coordination/café.md")
        sb.write(sb.docs, "docs/coordination/café.md", "local draft\n")
        sb.write(sb.docs, "docs/a.md", "a landed\n")
        before = sb.snapshot()

        blocked = sb.run_script("-m", "Land A", "docs/a.md")
        self.assertEqual(blocked.returncode, 3, blocked.stderr)
        self.assertIn("café.md", blocked.stderr)
        self.assertEqual(sb.snapshot(), before)
        self.assertEqual(
            (sb.docs / "docs/coordination/café.md").read_text(encoding="utf-8"),
            "local draft\n")

    def test_ancestor_regular_file_upstream_collision_is_predicted(self):
        # The occupant at an ancestor slot can be a plain untracked FILE:
        # docs/coordination/newdir as a regular file while master adds
        # newdir/foo.md. Nothing exists at the leaf and no symlink is
        # involved, yet the reconciliation checkout needs that component as
        # a real directory — after the push already landed.
        sb = self.sb
        sb.move_master_upstream("docs/coordination/newdir/foo.md")
        sb.write(sb.docs, "docs/coordination/newdir", "a plain file\n")
        sb.write(sb.docs, "docs/a.md", "a landed\n")
        before = sb.snapshot()

        blocked = sb.run_script("-m", "Land A", "docs/a.md")
        self.assertEqual(blocked.returncode, 3, blocked.stderr)
        self.assertIn("docs/coordination/newdir", blocked.stderr)
        self.assertEqual(sb.snapshot(), before)
        self.assertEqual(
            (sb.docs / "docs/coordination/newdir").read_text(encoding="utf-8"),
            "a plain file\n")

    def test_replaced_tracked_directory_symlink_is_predicted(self):
        # docs-wip replaces the tracked docs/coordination directory with an
        # untracked symlink while master adds a file beneath the real
        # directory. The symlink's path still prefix-matches its tracked
        # descendants, so a tracked-ness test over the prefix calls it safe —
        # yet the reconciliation checkout needs the real directory there and
        # would fail (or clobber the symlink) only after publication.
        sb = self.sb
        sb.move_master_upstream("docs/coordination/other.md")
        shutil.rmtree(sb.docs / "docs" / "coordination")
        os.symlink(
            "does-not-exist", sb.docs / "docs" / "coordination")
        sb.write(sb.docs, "docs/a.md", "a landed\n")
        before = sb.snapshot()

        blocked = sb.run_script("-m", "Land A", "docs/a.md")
        self.assertEqual(blocked.returncode, 3, blocked.stderr)
        self.assertIn("docs/coordination", blocked.stderr)
        self.assertEqual(sb.snapshot(), before)
        self.assertTrue((sb.docs / "docs/coordination").is_symlink())
        self.assertEqual(
            os.readlink(sb.docs / "docs/coordination"), "does-not-exist")

    def test_selected_path_changed_upstream_is_refused_without_force(self):
        # A named path that also moved upstream would be overwritten
        # wholesale by the landing; that must be a stop, not a silent loss.
        sb = self.sb
        sb.write(sb.main, "docs/a.md", "a upstream\n")
        sb.git("add", "docs/a.md")
        sb.git("commit", "-q", "-m", "upstream touches a")
        sb.git("push", "-q", "origin", "master")
        sb.write(sb.docs, "docs/a.md", "a local\n")
        before = sb.snapshot()

        blocked = sb.run_script("-m", "Land A", "docs/a.md")
        self.assertEqual(blocked.returncode, 3, blocked.stderr)
        self.assertIn("changed on master since this worktree's base", blocked.stderr)
        self.assertEqual(sb.head("origin/master"), before["upstream"])

        forced = sb.run_script("-f", "-m", "Land A", "docs/a.md")
        self.assertEqual(forced.returncode, 0, forced.stderr)
        self.assertEqual(sb.blob("origin/master", "docs/a.md"), "a local\n")


class PushVerificationTests(DocsLandCase):
    def test_protected_ref_warning_is_not_read_as_failure(self):
        # The sandbox origin's pre-receive hook prints the warning on every
        # push, so this landing succeeds only if success is judged by
        # reachability rather than push output.
        sb = self.sb
        sb.write(sb.docs, "docs/a.md", "a landed\n")
        done = sb.run_script("-m", "Land A", "docs/a.md")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("Bypassed rule violations", done.stderr)
        self.assertIn("landed: origin/master now contains", done.stdout)
        self.assertEqual(sb.blob("origin/master", "docs/a.md"), "a landed\n")

    def test_ignored_file_in_the_primary_checkout_blocks_the_fast_forward(self):
        # `status --porcelain` omits ignored files, so the clean check alone
        # would let the fast-forward silently overwrite an ignored file in
        # the primary checkout at the very path this landing added. The
        # publication itself still succeeds; only the convenience
        # fast-forward is skipped, and it says which path is occupied.
        sb = self.sb
        exclude = sb.main / ".git" / "info" / "exclude"
        exclude.parent.mkdir(parents=True, exist_ok=True)
        exclude.write_text("docs/new.md\n", encoding="utf-8")
        sb.write(sb.main, "docs/new.md", "primary ignored draft\n")
        main_head = sb.git("rev-parse", "HEAD").strip()
        sb.write(sb.docs, "docs/new.md", "landed content\n")

        done = sb.run_script("-m", "Land new", "docs/new.md")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("landed: origin/master now contains", done.stdout)
        self.assertIn("untracked or ignored files", done.stdout)
        self.assertIn("not fast-forwarding", done.stdout)
        self.assertIn("docs/new.md", done.stdout)
        self.assertEqual(
            sb.blob("origin/master", "docs/new.md"), "landed content\n")
        self.assertEqual(sb.git("rev-parse", "HEAD").strip(), main_head)
        self.assertEqual(
            (sb.main / "docs/new.md").read_text(encoding="utf-8"),
            "primary ignored draft\n")

    def test_ignored_non_ascii_file_in_the_primary_blocks_the_fast_forward(self):
        # The primary probe walks the same C-quoting hazard: an ignored
        # café.md in the primary checkout at the landed path must be
        # recognized from the NUL-delimited update list, or the fast-forward
        # silently overwrites it.
        sb = self.sb
        exclude = sb.main / ".git" / "info" / "exclude"
        exclude.parent.mkdir(parents=True, exist_ok=True)
        exclude.write_text("docs/coordination/café.md\n", encoding="utf-8")
        sb.write(sb.main, "docs/coordination/café.md", "primary ignored\n")
        main_head = sb.git("rev-parse", "HEAD").strip()
        sb.write(sb.docs, "docs/coordination/café.md", "landed content\n")

        done = sb.run_script("-m", "Land café", "docs/coordination/café.md")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("landed: origin/master now contains", done.stdout)
        self.assertIn("not fast-forwarding", done.stdout)
        self.assertIn("café.md", done.stdout)
        self.assertEqual(
            sb.blob("origin/master", "docs/coordination/café.md"),
            "landed content\n")
        self.assertEqual(sb.git("rev-parse", "HEAD").strip(), main_head)
        self.assertEqual(
            (sb.main / "docs/coordination/café.md").read_text(encoding="utf-8"),
            "primary ignored\n")

    def test_ignored_ancestor_file_in_the_primary_blocks_the_fast_forward(self):
        # An ignored regular FILE at the ancestor slot in the primary
        # checkout: porcelain-invisible, no symlink involved, and the
        # fast-forward would replace it to create the real directory the
        # landed path needs.
        sb = self.sb
        exclude = sb.main / ".git" / "info" / "exclude"
        exclude.parent.mkdir(parents=True, exist_ok=True)
        exclude.write_text("docs/coordination/newdir\n", encoding="utf-8")
        sb.write(sb.main, "docs/coordination/newdir", "primary plain file\n")
        main_head = sb.git("rev-parse", "HEAD").strip()
        sb.write(sb.docs, "docs/coordination/newdir/foo.md", "landed content\n")

        done = sb.run_script(
            "-m", "Land foo", "docs/coordination/newdir/foo.md")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("landed: origin/master now contains", done.stdout)
        self.assertIn("not fast-forwarding", done.stdout)
        self.assertIn("docs/coordination/newdir", done.stdout)
        self.assertEqual(
            sb.blob("origin/master", "docs/coordination/newdir/foo.md"),
            "landed content\n")
        self.assertEqual(sb.git("rev-parse", "HEAD").strip(), main_head)
        self.assertEqual(
            (sb.main / "docs/coordination/newdir").read_text(encoding="utf-8"),
            "primary plain file\n")

    def test_ignored_ancestor_symlink_in_the_primary_blocks_the_fast_forward(self):
        # The primary-checkout probe must walk ancestors too: an ignored
        # symlink at docs/coordination/newdir is porcelain-invisible and the
        # landed path beneath it neither exists nor is a symlink there, yet
        # the fast-forward would replace the symlink to create the real
        # directory.
        sb = self.sb
        exclude = sb.main / ".git" / "info" / "exclude"
        exclude.parent.mkdir(parents=True, exist_ok=True)
        exclude.write_text("docs/coordination/newdir\n", encoding="utf-8")
        os.symlink(
            "does-not-exist", sb.main / "docs" / "coordination" / "newdir")
        main_head = sb.git("rev-parse", "HEAD").strip()
        sb.write(sb.docs, "docs/coordination/newdir/foo.md", "landed content\n")

        done = sb.run_script(
            "-m", "Land foo", "docs/coordination/newdir/foo.md")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("landed: origin/master now contains", done.stdout)
        self.assertIn("not fast-forwarding", done.stdout)
        self.assertIn("docs/coordination/newdir", done.stdout)
        self.assertEqual(
            sb.blob("origin/master", "docs/coordination/newdir/foo.md"),
            "landed content\n")
        self.assertEqual(sb.git("rev-parse", "HEAD").strip(), main_head)
        self.assertTrue((sb.main / "docs/coordination/newdir").is_symlink())
        self.assertEqual(
            os.readlink(sb.main / "docs/coordination/newdir"),
            "does-not-exist")

    def test_clean_primary_with_local_commits_skips_the_fast_forward(self):
        # A clean checkout is not necessarily fast-forwardable: with local
        # commits, merge --ff-only exits nonzero, and under set -e that
        # would report the whole run — verified publication included — as a
        # failure it was not.
        sb = self.sb
        sb.write(sb.main, "docs/keep.md", "primary local work\n")
        sb.git("add", "docs/keep.md")
        sb.git("commit", "-q", "-m", "local primary commit")
        main_head = sb.git("rev-parse", "HEAD").strip()
        sb.write(sb.docs, "docs/a.md", "a landed\n")

        done = sb.run_script("-m", "Land A", "docs/a.md")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("landed: origin/master now contains", done.stdout)
        self.assertIn(
            "local commits not on origin/master; not fast-forwarding",
            done.stdout)
        self.assertEqual(sb.blob("origin/master", "docs/a.md"), "a landed\n")
        self.assertEqual(sb.git("rev-parse", "HEAD").strip(), main_head)

    def test_dirty_primary_checkout_skips_the_fast_forward(self):
        sb = self.sb
        sb.write(sb.main, "docs/keep.md", "primary wip\n")
        main_head = sb.git("rev-parse", "HEAD").strip()
        sb.write(sb.docs, "docs/a.md", "a landed\n")

        done = sb.run_script("-m", "Land A", "docs/a.md")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("primary checkout is dirty; not fast-forwarding", done.stdout)
        self.assertEqual(sb.git("rev-parse", "HEAD").strip(), main_head)
        self.assertEqual(
            (sb.main / "docs/keep.md").read_text(encoding="utf-8"),
            "primary wip\n")


class ClassificationGateTests(DocsLandCase):
    def test_a_code_gated_path_is_refused_by_name(self):
        sb = self.sb
        sb.write(sb.docs, "docs/design.md", "design wip\n")
        before = sb.snapshot()

        done = sb.run_script("-m", "Land design", "docs/design.md")
        self.assertEqual(done.returncode, 6, done.stdout)
        self.assertIn("docs/design.md", done.stderr)
        self.assertIn("test-parsed", done.stderr)
        self.assertIn("Spec/UI/Keys", done.stderr)
        self.assertIn("pull request", done.stderr)
        self.assertEqual(sb.snapshot(), before)

    def test_a_classified_untracked_document_lands(self):
        sb = self.sb
        sb.write(sb.docs, "docs/coordination/scratch-note.md", "a fresh note\n")
        done = sb.run_script("-m", "Land note", "docs/coordination/scratch-note.md")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(sb.commit_files(), {"docs/coordination/scratch-note.md"})
        self.assertEqual(
            sb.blob("origin/master", "docs/coordination/scratch-note.md"),
            "a fresh note\n")

    def test_an_unclassified_untracked_document_is_refused(self):
        sb = self.sb
        sb.write(sb.docs, "docs/rogue.md", "no row covers this\n")
        before = sb.snapshot()
        done = sb.run_script("-m", "Land rogue", "docs/rogue.md")
        self.assertEqual(done.returncode, 6, done.stdout)
        self.assertIn("docs/rogue.md", done.stderr)
        self.assertIn("no §7 row", done.stderr)
        self.assertIn("fail", done.stderr)
        self.assertEqual(sb.snapshot(), before)

    def test_the_root_contract_lands_despite_its_coupled_row(self):
        sb = self.sb
        sb.write(sb.docs, "CLAUDE.md", "root contract revised\n")
        done = sb.run_script("-m", "Land the root contract", "CLAUDE.md")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(sb.commit_files(), {"CLAUDE.md"})
        self.assertEqual(
            sb.blob("origin/master", "CLAUDE.md"), "root contract revised\n")

    def test_an_alias_selection_canonicalizes_to_the_root_contract(self):
        sb = self.sb
        # Editing "through the alias" edits the target: the git path
        # AGENTS.md stays a symlink blob either way.
        sb.write(sb.docs, "CLAUDE.md", "root contract revised\n")
        done = sb.run_script("-m", "Land the root contract", "AGENTS.md")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("AGENTS.md is the CLAUDE.md alias; landing CLAUDE.md",
                      done.stderr)
        self.assertEqual(sb.commit_files(), {"CLAUDE.md"})
        self.assertEqual(
            sb.blob("origin/master", "CLAUDE.md"), "root contract revised\n")
        self.assertEqual(sb.blob("origin/master", "AGENTS.md"), "CLAUDE.md")

    def test_a_changed_alias_object_is_refused(self):
        sb = self.sb
        (sb.docs / "AGENTS.md").unlink()
        sb.write(sb.docs, "AGENTS.md", "no longer a symlink\n")
        before = sb.snapshot()
        done = sb.run_script("-m", "Land the alias", "AGENTS.md")
        self.assertEqual(done.returncode, 6, done.stdout)
        self.assertIn("changed or replaced", done.stderr)
        self.assertEqual(sb.head("origin/master"), before["upstream"])

    def test_a_symlinked_ancestor_cannot_smuggle_an_external_file(self):
        # An untracked directory symlink under a classified directory row
        # resolves the leaf outside the worktree: the file exists, the leaf
        # is not itself a symlink, and the directory row matches — so without
        # the ancestor walk the script would hash and publish the external
        # file under a docs path.
        sb = self.sb
        outside = sb.root / "outside"
        outside.mkdir()
        (outside / "note.md").write_text("external content\n", encoding="utf-8")
        os.symlink(outside, sb.docs / "docs" / "coordination" / "escape")
        before = sb.snapshot()

        done = sb.run_script(
            "-m", "Land note", "docs/coordination/escape/note.md")
        self.assertEqual(done.returncode, 6, done.stdout)
        self.assertIn("symlink", done.stderr)
        self.assertIn("docs/coordination/escape", done.stderr)
        self.assertEqual(sb.snapshot(), before)
        self.assertNotIn(
            "docs/coordination/escape/note.md", sb.tracked("origin/master"))

    def test_case_mismatched_spelling_is_refused(self):
        # On a case-insensitive filesystem is_file() answers yes for the
        # folded spelling while every exact Git lookup answers no, and the
        # landing would publish a case-conflicting second tree entry. The
        # textual directory-listing walk refuses it identically on both
        # filesystem kinds.
        sb = self.sb
        before = sb.snapshot()
        done = sb.run_script(
            "-m", "Land readme", "docs/coordination/readme.md")
        self.assertEqual(done.returncode, 6, done.stdout)
        self.assertIn("case", done.stderr)
        self.assertIn("README.md", done.stderr)
        self.assertEqual(sb.snapshot(), before)

    def test_case_conflicting_selection_is_refused(self):
        # On a case-sensitive filesystem one invocation can name two
        # genuinely distinct new documents differing only by case; each
        # passes individually, and only the selection-level check keeps the
        # pair out of one published tree. The scenario cannot be constructed
        # on a case-insensitive filesystem, where the second write would
        # reopen the first file.
        sb = self.sb
        probe = sb.root / "case-probe"
        probe.write_text("x", encoding="utf-8")
        insensitive = (sb.root / "CASE-PROBE").exists()
        probe.unlink()
        if insensitive:
            self.skipTest("needs a case-sensitive filesystem (runs in CI)")
        sb.write(sb.docs, "docs/coordination/Foo.md", "one\n")
        sb.write(sb.docs, "docs/coordination/foo.md", "two\n")
        before = sb.snapshot()

        done = sb.run_script(
            "-m", "Land both",
            "docs/coordination/Foo.md", "docs/coordination/foo.md")
        self.assertEqual(done.returncode, 6, done.stdout)
        self.assertIn("differ only by case within one selection", done.stderr)
        self.assertEqual(sb.snapshot(), before)

    def test_selection_casefold_conflicts_are_detected(self):
        # The function-level half runs on every filesystem: leaf conflicts,
        # directory-prefix conflicts, and the clean case.
        module = _load_paths_module()
        self.assertEqual(
            module.selection_casefold_conflicts(
                ["docs/coordination/Foo.md", "docs/coordination/foo.md"]),
            [["docs/coordination/Foo.md", "docs/coordination/foo.md"]])
        self.assertEqual(
            module.selection_casefold_conflicts(
                ["docs/A/x.md", "docs/a/y.md"]),
            [["docs/A", "docs/a"]])
        self.assertEqual(
            module.selection_casefold_conflicts(["docs/a.md", "docs/b.md"]),
            [])

    def test_casefold_collision_names_the_existing_spelling(self):
        # The filesystem-independent half: a genuinely distinct file created
        # on a case-sensitive filesystem must not land beside an entry it
        # case-collides with. Driven at the function level because the
        # colliding file itself cannot exist on a case-insensitive
        # development machine.
        sb = self.sb
        module = _load_paths_module()
        self.assertEqual(
            module.casefold_collision(sb.docs, "docs/coordination/readme.md"),
            "docs/coordination/README.md")
        self.assertEqual(
            module.casefold_collision(sb.docs, "Docs/a.md"), "docs")
        self.assertIsNone(module.casefold_collision(sb.docs, "docs/a.md"))
        self.assertIsNone(
            module.casefold_collision(sb.docs, "docs/coordination/new-note.md"))

    def test_invalid_path_shapes_are_refused(self):
        sb = self.sb
        before = sb.snapshot()
        cases = {
            "/etc/motd.md": "absolute",
            "../outside.md": "..",
            "docs/": "directory",
            "docs/a.txt": "Markdown",
            ":(glob)docs/*.md": "pathspec magic",
            # Ordinary pathspecs glob by default, so without an explicit
            # refusal `git ls-files -- <path>` would expand these into
            # documents the argument never literally named.
            "docs/coordination/*.md": "glob metacharacters",
            "docs/?.md": "glob metacharacters",
            "docs/[ab].md": "glob metacharacters",
            # The gate's canonical-path handoff is line-delimited, so an
            # embedded newline would split one validated argument into two
            # paths, the second never validated or classified at all.
            "docs/coordination/x\nCLAUDE.md": "control characters",
            "docs/a\tb.md": "control characters",
        }
        for argument, needle in cases.items():
            with self.subTest(argument=argument):
                done = sb.run_script("-m", "Land", argument)
                self.assertEqual(done.returncode, 6, done.stdout)
                self.assertIn(needle, done.stderr)
        os.symlink("a.md", sb.docs / "docs" / "linked.md")
        done = sb.run_script("-m", "Land", "docs/linked.md")
        self.assertEqual(done.returncode, 6, done.stdout)
        self.assertIn("symlink", done.stderr)
        (sb.docs / "docs" / "linked.md").unlink()
        self.assertEqual(sb.snapshot(), before)


class DryRunTests(DocsLandCase):
    def test_dry_run_reports_the_plan_and_changes_nothing(self):
        sb = self.sb
        sb.write(sb.docs, "docs/a.md", "a landed\n")
        b_body = sb.stage_unrelated_b()
        before = sb.snapshot()

        done = sb.run_script("-n", "-m", "Land A", "docs/a.md")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("plan: subject: Land A", done.stdout)
        self.assertIn("plan: land docs/a.md (modify)", done.stdout)
        self.assertIn("plan: destination: origin/master", done.stdout)
        self.assertIn("plan: reconcile: fast-forward docs-wip", done.stdout)
        self.assertIn("dry run: nothing was committed, pushed, or moved",
                      done.stdout)

        self.assertEqual(sb.snapshot(), before)
        self.assertEqual(
            (sb.docs / "docs/a.md").read_text(encoding="utf-8"), "a landed\n")
        self.assertEqual(
            (sb.docs / "docs/b.md").read_text(encoding="utf-8"), b_body)


class InventoryTests(DocsLandCase):
    def test_inventory_reports_states_lanes_and_refusals(self):
        sb = self.sb
        sb.write(sb.docs, "docs/a.md", "a wip\n")
        sb.write(sb.docs, "docs/coordination/fresh-note.md", "note\n")
        sb.write(sb.docs, "docs/rogue.md", "unclassified\n")
        (sb.docs / "docs/keep.md").unlink()

        done = sb.run_script("-l")
        self.assertEqual(done.returncode, 0, done.stderr)
        rows = {
            line.split(" | ")[0]: line
            for line in done.stdout.splitlines()
            if " | " in line
        }
        self.assertIn("path | tracked", done.stdout.splitlines()[0])

        self.assertIn("modified", rows["docs/a.md"])
        self.assertIn("differs", rows["docs/a.md"])
        self.assertIn("coordination", rows["docs/a.md"])
        self.assertIn("| yes", rows["docs/a.md"])

        self.assertIn("untracked", rows["docs/coordination/fresh-note.md"])
        self.assertIn("docs/coordination/", rows["docs/coordination/fresh-note.md"])
        self.assertIn("| yes", rows["docs/coordination/fresh-note.md"])

        self.assertIn("untracked", rows["docs/rogue.md"])
        self.assertIn("no (", rows["docs/rogue.md"])

        self.assertIn("deleted", rows["docs/keep.md"])
        self.assertIn("no (", rows["docs/design.md"])
        self.assertIn("test-parsed", rows["docs/design.md"])
        # A clean, eligible, unmodified document still appears.
        self.assertIn("clean", rows["docs/del.md"])
        self.assertIn("same", rows["docs/del.md"])
        # The intact alias is landable, reported under its canonical name.
        self.assertIn("yes (as CLAUDE.md)", rows["AGENTS.md"])

    def test_inventory_includes_an_ignored_landable_document(self):
        # `status --porcelain` never shows an ignored untracked file, but an
        # ignored document under a classified directory row is still landable
        # and the no-argument workflow must be able to offer it.
        sb = self.sb
        exclude = sb.main / ".git" / "info" / "exclude"
        exclude.parent.mkdir(parents=True, exist_ok=True)
        exclude.write_text("docs/coordination/local-note.md\n", encoding="utf-8")
        sb.write(sb.docs, "docs/coordination/local-note.md", "ignored note\n")

        done = sb.run_script("-l")
        self.assertEqual(done.returncode, 0, done.stderr)
        rows = {
            line.split(" | ")[0]: line
            for line in done.stdout.splitlines()
            if " | " in line
        }
        row = rows["docs/coordination/local-note.md"]
        self.assertIn("ignored", row)
        self.assertIn("docs/coordination/", row)
        self.assertIn("| yes", row)

    def test_inventory_shows_a_non_ascii_document_verbatim_and_it_lands(self):
        # Git C-quotes unusual filenames in newline output, so a line-based
        # parser would show café.md as caf\303\251.md and refuse it for its
        # backslashes; the NUL-delimited listings must carry the real name,
        # and the named path must land.
        sb = self.sb
        sb.write(sb.docs, "docs/coordination/café.md", "accent\n")

        done = sb.run_script("-l")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertNotIn("\\303", done.stdout)
        rows = {
            line.split(" | ")[0]: line
            for line in done.stdout.splitlines()
            if " | " in line
        }
        row = rows["docs/coordination/café.md"]
        self.assertIn("untracked", row)
        self.assertIn("| yes", row)

        landed = sb.run_script("-m", "Land café", "docs/coordination/café.md")
        self.assertEqual(landed.returncode, 0, landed.stderr)
        self.assertEqual(
            sb.blob("origin/master", "docs/coordination/café.md"), "accent\n")

    def test_inventory_applies_the_same_validation_as_the_gate(self):
        # A replaced alias object and an untracked symlink both pass
        # classification alone; the gate refuses them, so an inventory that
        # judged classification alone would advertise them as landable and
        # mislead the no-argument workflow's approved selection.
        sb = self.sb
        (sb.docs / "AGENTS.md").unlink()
        sb.write(sb.docs, "AGENTS.md", "no longer a symlink\n")
        os.symlink(
            "README.md", sb.docs / "docs" / "coordination" / "alias-note.md")

        done = sb.run_script("-l")
        self.assertEqual(done.returncode, 0, done.stderr)
        rows = {
            line.split(" | ")[0]: line
            for line in done.stdout.splitlines()
            if " | " in line
        }
        self.assertIn("no (", rows["AGENTS.md"])
        self.assertIn("changed or replaced", rows["AGENTS.md"])
        self.assertIn("no (", rows["docs/coordination/alias-note.md"])
        self.assertIn("symlink", rows["docs/coordination/alias-note.md"])


class WorktreeResolutionTests(DocsLandCase):
    def test_a_missing_docs_worktree_fails_before_any_mutation(self):
        sb = self.sb
        sb.git("worktree", "remove", "--force", str(sb.docs))
        done = sb.run_script("-m", "Land A", "docs/a.md")
        self.assertEqual(done.returncode, 1, done.stdout)
        self.assertIn("docs-wip", done.stderr)


# ---------------------------------------------------------------------
# macOS Bash 3.2 compatibility
# ---------------------------------------------------------------------
# `bash -n` is a SYNTAX parse under whichever bash is on PATH — bash 5.x on
# CI and on any Homebrew Mac — where every bash-4-only construct below parses
# cleanly. So the version constraint needs its own explicit check.
BASH4_ONLY = [
    (r"\bmapfile\b", "mapfile"),
    (r"\breadarray\b", "readarray"),
    (r"\bcoproc\b", "coproc"),
    (r"\b(?:declare|typeset|local)\s+(?:-[a-zA-Z]+\s+)*-[a-zA-Z]*A",
     "associative array declaration (declare -A)"),
    (r"\$\{[^}]*\^\^", "${var^^} case conversion"),
    (r"\$\{[^}]*,,", "${var,,} case conversion"),
    (r"&>>", "&>> append redirection"),
    (r"\[\[\s+-v\s", "[[ -v ]] (bash 4.2)"),
]


class Bash32CompatibilityTests(unittest.TestCase):
    @staticmethod
    def code_lines() -> list[tuple[int, str]]:
        """The script's executable lines, with whole-line comments dropped.

        The header documents the constraint by NAMING the constructs it
        avoids, so scanning raw text would fail on the very comment that
        records the rule.
        """
        return [(i, line)
                for i, line in enumerate(SCRIPT.read_text(encoding="utf-8")
                                         .splitlines(), 1)
                if not line.lstrip().startswith("#")]

    def test_the_script_parses_and_avoids_bash_4_syntax(self):
        parsed = subprocess.run(["bash", "-n", str(SCRIPT)],
                                capture_output=True, text=True)
        self.assertEqual(parsed.returncode, 0, parsed.stderr)
        lines = self.code_lines()
        self.assertTrue(lines, "the script has executable lines to scan")
        for pattern, label in BASH4_ONLY:
            hits = [f"line {i}" for i, line in lines if re.search(pattern, line)]
            self.assertEqual(hits, [], f"{label} found at {hits}")


# ---------------------------------------------------------------------
# The push-docs workflow assets
# ---------------------------------------------------------------------
# There is no behavioral prompt-testing harness here, so the reviewable
# property is the asset text itself — the WriteLocationTests pattern from
# tools/test_drafting_workflow_contract.py: the rules asserted against every
# asset that owes them, plus a negative control over assets that must not
# state them, so a rule matching everything cannot pass while asserting
# nothing.
PUSH_DOCS_ASSETS = (
    "claude-plugin/plugins/kanban/commands/push-docs.md",
    "codex-plugin/plugins/kanban/skills/push-docs/SKILL.md",
)

# Assets that have nothing to do with landing documentation and must state
# none of these rules.
PUSH_DOCS_NEGATIVE_CONTROLS = (
    "claude-plugin/plugins/kanban/commands/triage.md",
    "claude-plugin/plugins/kanban/commands/solve.md",
    "codex-plugin/plugins/kanban/skills/triage/SKILL.md",
    "codex-plugin/plugins/kanban/skills/solve/SKILL.md",
)

# Written without a workflow sigil so one spelling survives both brands'
# rendering; compared over canonical() text.
PUSH_DOCS_RULES = (
    "tools/docs_land.sh",
    "never land the whole worktree unprompted",
    "explicit approval of the exact path list",
    "never work around a refusal",
    "never pass -f",
)


def canonical(text: str) -> str:
    return re.sub(r"\s+", " ", text.replace("*", "").replace("`", "")).lower()


class PushDocsWorkflowAssetTests(unittest.TestCase):
    def setUp(self):
        self.assets = {
            path: canonical((REPO_ROOT / path).read_text(encoding="utf-8"))
            for path in PUSH_DOCS_ASSETS
        }

    def test_every_asset_states_every_rule(self):
        missing = []
        for path, text in self.assets.items():
            for rule in PUSH_DOCS_RULES:
                if rule not in text:
                    missing.append(f"{path}: missing rule {rule!r}")
        self.assertEqual(missing, [], "\n".join(missing))

    def test_dropping_a_rule_from_an_asset_is_reported(self):
        # The property under test is that removal fails, not merely that the
        # text happens to be present today.
        for path, text in self.assets.items():
            for rule in PUSH_DOCS_RULES:
                mutated = text.replace(rule, "")
                self.assertNotIn(
                    rule, mutated,
                    f"{path}: {rule!r} survived its own removal, so this "
                    "check would not notice the edit")

    def test_the_rules_are_not_vacuous(self):
        offenders = []
        for path in PUSH_DOCS_NEGATIVE_CONTROLS:
            text = canonical((REPO_ROOT / path).read_text(encoding="utf-8"))
            for rule in PUSH_DOCS_RULES:
                if rule in text:
                    offenders.append(
                        f"{path} states {rule!r}; a rule that matches "
                        "unrelated assets asserts nothing here")
        self.assertEqual(offenders, [], "\n".join(offenders))


if __name__ == "__main__":
    unittest.main()
