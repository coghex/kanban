"""Focused tests for tools/drain_prs.py.

Covers the round-10 fix delegating parse_repo_slug to
kanban_config.parse_repository_name, so the drainer accepts the same
broader remote forms (ssh://, http://, git://, bare owner/name) the
dashboard's own parseRepositoryName does, not only
git@github.com:/https://github.com/; and the round-13 fix making the
conflict-review agent prompts pass an explicit --repo to every gh command,
instead of relying on gh's own default-repository inference (which can
target the wrong repository in a checkout with more than one remote, even
though ctx.repo_slug itself was already resolved from the configured
remote_name).
"""

import unittest
from pathlib import Path

import drain_prs


class ParseRepoSlugTests(unittest.TestCase):
    def test_accepts_the_broader_remote_forms(self):
        self.assertEqual(
            drain_prs.parse_repo_slug("ssh://git@github.com/coghex/kanban.git"),
            "coghex/kanban",
        )
        self.assertEqual(drain_prs.parse_repo_slug("coghex/kanban"), "coghex/kanban")

    def test_raises_drain_error_on_an_unparseable_value(self):
        with self.assertRaises(drain_prs.DrainError):
            drain_prs.parse_repo_slug("not-a-repo")


def make_ctx(repo_slug="upstream-owner/kanban", remote_name="upstream"):
    return drain_prs.RepoContext(
        path=Path("/fake-repo"),
        repo_slug=repo_slug,
        repo_name="kanban",
        default_branch="main",
        remote_name=remote_name,
    )


class ConflictReviewPromptRepoScopingTests(unittest.TestCase):
    """A checkout configured with a non-default remote_name (e.g.
    remote_name=upstream selecting an upstream repo while "origin" still
    points at a fork) must not let gh's own default-repository inference
    silently target the fork inside these spawned-agent prompts."""

    def test_claude_conflict_review_prompt_requires_repo_on_every_gh_command(self):
        prompt = drain_prs.claude_conflict_review_prompt(
            make_ctx(), {"number": 89}, round_number=1, expected_head="a" * 40
        )
        self.assertIn("--repo upstream-owner/kanban", prompt)
        self.assertIn(
            "gh pr view 89 --repo upstream-owner/kanban --json headRefOid", prompt
        )
        self.assertIn("gh pr comment 89 --repo upstream-owner/kanban", prompt)
        self.assertIn("gh pr edit 89 --repo upstream-owner/kanban", prompt)

    def test_codex_conflict_fix_prompt_requires_repo_on_its_gh_read(self):
        prompt = drain_prs.codex_conflict_fix_prompt(
            make_ctx(),
            {"number": 89, "headRefName": "issue-42-fix"},
            round_number=1,
            expected_head="a" * 40,
        )
        self.assertIn("--repo upstream-owner/kanban", prompt)

    def test_drain_rereview_prompt_requires_repo_on_every_gh_command(self):
        prompt = drain_prs.drain_rereview_prompt(make_ctx(), 89, "a" * 40)
        self.assertIn("--repo upstream-owner/kanban", prompt)
        self.assertIn("gh pr comment 89 --repo upstream-owner/kanban", prompt)
        self.assertIn("gh pr edit 89 --repo upstream-owner/kanban", prompt)


if __name__ == "__main__":
    unittest.main()
