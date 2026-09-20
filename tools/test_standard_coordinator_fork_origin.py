"""What a fork pull request's origin marker means to the standard coordinators.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 tools/test_standard_coordinator_fork_origin.py

Issue #696. `docs/agent-workflow-contract.md` §2.2 makes `pr-origin:grok`,
`pr-origin:kimi`, and `pr-origin:google` known origins whose cross-brand
reviewer is Codex, never Claude and never both. The Codex and Claude bundled
coordinators honored that for a same-repository pull request and broke it for a
fork: `pr_origin` discarded everything but a kimi or google marker when
`isCrossRepository` was set, so a grok fork pull request fell through to the
unknown dual route. That spends Claude quota the Grok action's preflight never
required, fails outright on an installation with no Claude, and then blocks the
merge, because finalize refuses a dual-brand approval on a grok-origin pull
request.

`/solve` opens a fork pull request with `--head <push-owner>:<branch>`, which
GitHub reports as `isCrossRepository`, so this is the ordinary shape of an
external-origin pull request rather than an exotic one.

The three external bundles already behaved correctly and are covered by
tools/test_grok_plugin.py, tools/test_kimi_plugin.py, and
tools/test_google_plugin.py. The two standard bundles carried no fork-origin
regression test at all -- only in-module `--self-test` asserts, which name what
that one file believes rather than what the workflow does -- so the assertions
here are made against the production functions of both standard copies:

* **The whole origin/route matrix**, every marker over both repository
  relationships, rather than the one case the defect was reported in. A fix
  spelled as a special case for grok on a fork would pass a grok-only test and
  still be wrong about the two markers that must keep resolving to nothing
  there.
* **The spawn itself**, through the production `run_reviews`, over fake
  `codex`/`claude` executables on a temporary PATH. The route is an argument to
  a function; what the pull request costs is which executable runs. Asserting
  the route alone would leave that step untested, and it is the step the issue
  is about.

tools/test_coordinator_parity.py holds the two standard copies against each
other and against the external ones; this module is about what they do, not
about whether they agree.
"""

from __future__ import annotations

import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parent.parent

STANDARD_COORDINATORS = {
    "codex": REPO_ROOT
    / "codex-plugin"
    / "plugins"
    / "kanban"
    / "skills"
    / "pr-review"
    / "scripts"
    / "review_pr.py",
    "claude": REPO_ROOT
    / "claude-plugin"
    / "plugins"
    / "kanban"
    / "scripts"
    / "review_pr.py",
}

# One reference copy that was already right, so a fix that aligned the standard
# copies downward -- dropping kimi and google too -- cannot pass here.
GROK_COORDINATOR = (
    REPO_ROOT / "grok-plugin" / "plugins" / "kanban" / "scripts" / "review_pr.py"
)

DUAL_ROUTE = ["codex", "claude"]

# Origin marker -> (origin on a fork, origin on a same-repository PR). The
# three external brands survive a fork because none of them is a spawned
# provider: their marker is provenance the reviewer routing needs, not a claim
# about who can review. A codex or claude marker does not survive, because on a
# fork anyone may write one and it would choose that pull request's reviewer.
FORK_ORIGIN_MATRIX = {
    "grok": ("grok", "grok"),
    "kimi": ("kimi", "kimi"),
    "google": ("google", "google"),
    "codex": (None, "codex"),
    "claude": (None, "claude"),
    None: (None, None),
}

# Origin -> the reviewers dual mode routes it to, with both providers loaded.
EXPECTED_ROUTES = {
    "grok": ["codex"],
    "kimi": ["codex"],
    "google": ["codex"],
    "codex": ["claude"],
    "claude": ["codex"],
    None: DUAL_ROUTE,
}

# A reviewer executable that answers like the real one and records that it ran.
# `codex exec` writes its structured result to the path after `-o`; `claude -p`
# writes its own to stdout. This interpreter by absolute path, because the
# shebang is resolved before PATH is anything this test controls.
FAKE_REVIEWER = """#!{interpreter}
import json, sys
from pathlib import Path

argv = sys.argv[1:]
log = Path({log!r})
calls = json.loads(log.read_text(encoding="utf-8")) if log.exists() else []
calls.append(argv)
log.write_text(json.dumps(calls), encoding="utf-8")
sys.stdin.read()
review = {{"verdict": "APPROVE", "summary": "fixture", "blocking_concerns": []}}
if "-o" in argv:
    Path(argv[argv.index("-o") + 1]).write_text(json.dumps(review), encoding="utf-8")
else:
    sys.stdout.write(json.dumps({{"result": json.dumps(review)}}))
"""


def load_coordinator(brand: str, path: Path | None = None):
    """Import one coordinator by file path. Each lives under its own bundle,
    which `-s tools` discovery never puts on sys.path."""
    target = path or STANDARD_COORDINATORS[brand]
    spec = importlib.util.spec_from_file_location(
        f"kanban_fork_origin_{brand}_review_pr", target
    )
    if spec is None or spec.loader is None:
        raise AssertionError(f"could not import {target}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def pull_request(origin: str | None, *, fork: bool) -> dict:
    """A pull request body shaped the way `/solve` writes one: the origin
    marker as the final non-whitespace content, after a summary."""
    body = "Closes #7\n\nA short approach summary.\n"
    if origin is not None:
        body += f"\n<!-- pr-origin:{origin} -->\n"
    return {
        "number": 7,
        "url": "https://github.com/coghex/kanban/pull/7",
        "state": "OPEN",
        "headRefOid": "a" * 40,
        "body": body,
        "isCrossRepository": fork,
        "isDraft": False,
        "labels": [],
        "closingIssuesReferences": [],
    }


class ForkOriginRoutingTests(unittest.TestCase):
    """The origin every marker resolves to, and the reviewers it routes to.

    Dual mode with both providers loaded is pinned rather than read from
    whatever roster the host running this suite carries: the route depends on
    the operating mode, so an unpinned mode would make every case here answer a
    different question on a single-agent machine.
    """

    def setUp(self):
        self.modules = {
            brand: load_coordinator(brand) for brand in STANDARD_COORDINATORS
        }

    def route(self, module, origin):
        return [
            reviewer.key
            for reviewer in module.route_reviewers(
                origin, mode="dual", loaded=("codex", "claude")
            )
        ]

    def test_every_marker_resolves_to_the_same_origin_in_both_coordinators(self):
        for marker, (fork_origin, same_repo_origin) in FORK_ORIGIN_MATRIX.items():
            for fork, expected in ((True, fork_origin), (False, same_repo_origin)):
                for brand, module in self.modules.items():
                    with self.subTest(marker=marker, fork=fork, coordinator=brand):
                        self.assertEqual(
                            module.pr_origin(pull_request(marker, fork=fork)),
                            expected,
                        )

    def test_every_marker_routes_the_same_way_in_both_coordinators(self):
        for marker, (fork_origin, same_repo_origin) in FORK_ORIGIN_MATRIX.items():
            for fork, origin in ((True, fork_origin), (False, same_repo_origin)):
                for brand, module in self.modules.items():
                    with self.subTest(marker=marker, fork=fork, coordinator=brand):
                        self.assertEqual(
                            self.route(module, origin), EXPECTED_ROUTES[origin]
                        )

    def test_a_grok_fork_pull_request_routes_to_codex_alone(self):
        # The reported defect, named directly: not merely "not both", but
        # exactly Codex, so a fix that routed it to Claude alone would fail.
        for brand, module in self.modules.items():
            with self.subTest(coordinator=brand):
                origin = module.pr_origin(pull_request("grok", fork=True))
                self.assertEqual(origin, "grok")
                self.assertEqual(self.route(module, origin), ["codex"])

    def test_the_external_reference_copy_agrees_on_every_case(self):
        # The three external bundles ship one identical coordinator that was
        # already correct here. Comparing against it keeps "aligned" meaning
        # aligned upward: dropping kimi and google from the standard copies
        # would satisfy a matrix written only from this module's own idea of
        # the contract.
        reference = load_coordinator("grok", GROK_COORDINATOR)
        for marker, (fork_origin, same_repo_origin) in FORK_ORIGIN_MATRIX.items():
            for fork, expected in ((True, fork_origin), (False, same_repo_origin)):
                with self.subTest(marker=marker, fork=fork):
                    self.assertEqual(
                        reference.pr_origin(pull_request(marker, fork=fork)), expected
                    )

    def test_a_malformed_grok_marker_is_refused_on_a_fork_exactly_as_at_home(self):
        # Requirement 4: relaxing the cross-repository filter must not relax
        # `origin_from_body`. A duplicated, mixed, or trailing-text marker is
        # not a marker, wherever the pull request came from.
        marker = "<!-- pr-origin:grok -->"
        malformed = {
            "duplicated": f"body\n\n{marker}\n{marker}\n",
            "mixed": f"body\n\n{marker}\n<!-- pr-origin:codex -->\n",
            "trailing text": f"body\n\n{marker}\nand one more thought\n",
        }
        for label, body in malformed.items():
            for fork in (True, False):
                for brand, module in self.modules.items():
                    with self.subTest(body=label, fork=fork, coordinator=brand):
                        pr = pull_request("grok", fork=fork)
                        pr["body"] = body
                        self.assertIsNone(module.pr_origin(pr))
                        self.assertEqual(self.route(module, None), DUAL_ROUTE)

    def test_single_agent_mode_still_collapses_a_grok_fork_origin(self):
        # Requirement 5, and the issue review's reminder that §2.2 requires
        # this exception: a one-provider installation reviews with the provider
        # it has, grok origin or not, because the opposite-brand promise is a
        # property of a two-provider roster.
        for brand, module in self.modules.items():
            for provider in ("codex", "claude"):
                with self.subTest(coordinator=brand, loaded=provider):
                    origin = module.pr_origin(pull_request("grok", fork=True))
                    reviewers = module.route_reviewers(
                        origin, mode="single-agent", loaded=(provider,)
                    )
                    self.assertEqual([item.key for item in reviewers], [provider])

    def test_no_agent_mode_still_routes_a_grok_fork_origin_to_nobody(self):
        for brand, module in self.modules.items():
            with self.subTest(coordinator=brand):
                origin = module.pr_origin(pull_request("grok", fork=True))
                self.assertEqual(
                    module.route_reviewers(origin, mode="no-agent", loaded=()), []
                )


class ForkOriginSpawnTests(unittest.TestCase):
    """Which executable actually runs for a grok fork pull request.

    The route is a list of records; the cost and the availability requirement
    are a process. Both standard coordinators are driven through their own
    production `run_reviews` in dual mode with both providers loaded, over fake
    `codex` and `claude` executables on a temporary PATH -- no network, no
    provider account -- and the assertion is that `claude` was never executed.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.logs = {}
        for binary in ("codex", "claude"):
            log = self.root / f"{binary}.calls.json"
            self.logs[binary] = log
            script = self.bin_dir / binary
            script.write_text(
                FAKE_REVIEWER.format(interpreter=sys.executable, log=str(log)),
                encoding="utf-8",
            )
            script.chmod(script.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP)

    def calls(self, binary: str) -> list[list[str]]:
        log = self.logs[binary]
        if not log.exists():
            return []
        return json.loads(log.read_text(encoding="utf-8"))

    def run_reviews_for(self, module, pr: dict) -> list[dict]:
        """The production route and the production spawn, wired the way
        workflow() wires them: the origin comes off the pull request, the
        reviewers come off the origin, and run_reviews spawns them."""
        origin = module.pr_origin(pr)
        reviewers = module.route_reviewers(
            origin, mode="dual", loaded=("codex", "claude")
        )
        sources = self.root / "sources"
        sources.mkdir(exist_ok=True)

        def extract() -> Path:
            return Path(tempfile.mkdtemp(dir=sources))

        # PATH is prepended, not replaced: the fakes are python3 scripts and a
        # one-directory PATH would hide the interpreter's own environment from
        # everything the coordinator runs.
        path = f"{self.bin_dir}{os.pathsep}{os.environ.get('PATH', '')}"
        with mock.patch.dict(os.environ, {"PATH": path}):
            return module.run_reviews(
                reviewers,
                {"pull_request": pr, "diff": "", "linked_issues": []},
                extract,
                False,
            )

    def test_a_grok_fork_pull_request_spawns_codex_and_never_claude(self):
        for brand, path in STANDARD_COORDINATORS.items():
            with self.subTest(coordinator=brand):
                module = load_coordinator(brand, path)
                results = self.run_reviews_for(
                    module, pull_request("grok", fork=True)
                )
                self.assertEqual([item["verdict"] for item in results], ["APPROVE"])
                self.assertEqual(len(self.calls("codex")), 1)
                self.assertEqual(
                    self.calls("claude"),
                    [],
                    "a grok-origin fork pull request must spend no Claude quota",
                )
                for log in self.logs.values():
                    log.unlink(missing_ok=True)

    def test_an_unmarked_fork_pull_request_still_spawns_both(self):
        # The control. Without it, a coordinator that spawned nothing at all,
        # or that had lost the dual route entirely, would pass the case above.
        for brand, path in STANDARD_COORDINATORS.items():
            with self.subTest(coordinator=brand):
                module = load_coordinator(brand, path)
                results = self.run_reviews_for(module, pull_request(None, fork=True))
                self.assertEqual(len(results), 2)
                self.assertEqual(len(self.calls("codex")), 1)
                self.assertEqual(len(self.calls("claude")), 1)
                for log in self.logs.values():
                    log.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
