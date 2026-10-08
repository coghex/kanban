"""The tracked issue-creation operation, run the way the processing workflows
run it: from each installed bundle, through each asset's own shell fences,
against a repository that tracks none of Kanban's tools and a fake GitHub.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

coghex/moskophoros#64. A `/process-report`-style run walked an issue-creating
step as three commands it chained itself — `--begin-step`, `gh issue create`,
`--confirm-step` — and when the begin failed it ran the create anyway, leaving
an issue with no recorded intent. `tools/test_tracked_issue_create.py` proves
the replacement operation in-process; `tools/test_document_workflow_contract.py`
proves every processing asset spells it. Neither runs what a session runs: the
bundled copy, found by the asset's own lookup, invoked by the asset's own fence.
This module does, for all four processing assets, and asserts what reaches the
fake GitHub:

- the lookup resolves the tool out of the simulated install, byte-identical to
  `tools/`, beside the transaction module it loads, all four mechanism modules
  from one bundle directory; it fails closed when that bundle lacks any of
  them, and, for Codex, when the cache holds more than one Kanban version,
  complete or partial, rather than mixing modules across versions;
- the asset's fingerprint, create, and inspect fences drive one creation to a
  confirmed step and make one POST, and running create again makes none;
- a checkpoint begin that fails makes no GitHub request at all;
- an uncertain outcome leaves the step ambiguous, and the asset's own create
  fence run again — which is the blind retry the incident was — makes no
  request, and its `step-ambiguous`/`none` result is classified unresolved by
  the asset's own ordered rules, never as a refusal that created nothing;
- a refusal made before the record was read (`transaction` null), after an
  uncertain creation, is classified unresolved through the asset's own
  read-only `--check` fence; and
- a recorded target naming another repository makes no GitHub request.
"""

from __future__ import annotations

import filecmp
import json
import os
import re
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))

import test_consuming_repository_documents as consuming
import test_document_workflow_contract as contract
import test_tracked_issue_create as unit

CONSUMING_REPOSITORY = consuming.CONSUMING_REPOSITORY
DOCUMENT = consuming.DOCUMENT
BRANCH = consuming.BRANCH
REQUEST = unit.REQUEST
SOURCE = REPO_ROOT / "tools" / "tracked_issue_create.py"

# The processing assets, with the bundle each installs from and the kind of
# issue-creating step its disposition records. The design pair's distinctive
# creation is the umbrella epic; the report pair's is a child issue.
PROCESSING_ASSETS = (
    ("claude-plugin/plugins/kanban/commands/process-report.md", "claude", "issue-create"),
    ("claude-plugin/plugins/kanban/commands/process-design-doc.md", "claude", "epic-create"),
    ("codex-plugin/plugins/kanban/skills/process-report/SKILL.md", "codex", "issue-create"),
    ("codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md", "codex", "epic-create"),
)

# The four modules a processing asset's lookup resolves as one unit.
MECHANISM_MODULES = (
    "publish_coordination_doc.py",
    "tracker_transaction.py",
    "tracked_issue_create.py",
    "kanban_config.py",
)

PLACEHOLDER_WRITE_RE = re.compile(r"^# write .*\"\$ISSUE_REQUEST\"$", re.MULTILINE)


def tracked_issue_fence(text, marker):
    """The one bash fence in `text` that runs the tool with `marker`."""
    found = [
        match.group("body")
        for match in consuming.BASH_FENCE_RE.finditer(text)
        if '"$TRACKED_ISSUE"' in match.group("body") and marker in match.group("body")
    ]
    if len(found) != 1:
        raise AssertionError(f"expected one fence running {marker}, found {len(found)}")
    return found[0]


def record_check_fence(text):
    """The asset's read-only `--check` of the record, which its result rules
    read when the tool's result carries no transaction."""
    start = text.index("describes this invocation only")
    section = text[start:text.index(contract.RESULT_RULES_START, start)]
    found = [
        match.group("body")
        for match in consuming.BASH_FENCE_RE.finditer(section)
        if '"$TRACKER_TX"' in match.group("body") and "--check" in match.group("body")
    ]
    if len(found) != 1:
        raise AssertionError(f"expected one record --check fence, found {len(found)}")
    return found[0]


class TrackedIssueWorkflowTests(unittest.TestCase):
    maxDiff = None

    # Reused from the consuming-repository module without inheriting its tests.
    install = consuming.ConsumingRepositoryTests.install
    build_repository = consuming.ConsumingRepositoryTests.build_repository
    helper = consuming.ConsumingRepositoryTests.helper
    preflight = consuming.ConsumingRepositoryTests.preflight
    transaction = consuming.ConsumingRepositoryTests.transaction
    setUp_consuming = consuming.ConsumingRepositoryTests.setUp

    def setUp(self):
        self.setUp_consuming()
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(unit.FAKE_GH.format(
            python=sys.executable, title=REQUEST["title"].upper()
        ))
        gh.chmod(0o755)
        self.state_path = self.root / "gh-state.json"
        self.environment = dict(
            os.environ,
            HOME=str(self.home),
            XDG_CONFIG_HOME=str(self.config_home),
            FAKE_GH_STATE=str(self.state_path),
            PATH=f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
        )
        self.approved_request = self.root / "approved-request.json"
        self.approved_request.write_text(json.dumps(REQUEST), encoding="utf-8")

    # -- fake GitHub -----------------------------------------------------------

    def reset_github(self, **state):
        self.state_path.write_text(json.dumps({"issues": [], **state}))

    def github(self):
        return json.loads(self.state_path.read_text())

    def calls(self):
        return self.github().get("calls", [])

    def posts(self):
        return [call for call in self.calls() if "POST" in call]

    def set_github(self, **values):
        state = self.github()
        state.update(values)
        self.state_path.write_text(json.dumps(state))

    # -- the asset, executed -----------------------------------------------------

    def asset_text(self, relative_path):
        return (REPO_ROOT / relative_path).read_text(encoding="utf-8")

    def lookup_environment(self, brand, install_root, plugin_root):
        environment = dict(self.environment)
        if brand == "claude":
            environment["CLAUDE_PLUGIN_ROOT"] = str(plugin_root)
        else:
            environment["CODEX_HOME"] = str(install_root)
            environment.pop("CLAUDE_PLUGIN_ROOT", None)
        return environment

    def run_lookup(self, relative_path, brand):
        install_root, plugin_root = self.install(brand)
        fence = consuming.lookup_fence(self.asset_text(relative_path))
        # The fence ends in its existence check; that check's status is the
        # lookup's verdict, so it is what this script exits with.
        script = (
            fence
            + '\nverdict=$?\nprintf "%s\\n%s\\n" "${TRACKED_ISSUE-}" "${TRACKER_TX-}"\n'
            + 'exit "$verdict"\n'
        )
        return subprocess.run(
            ["bash", "-c", script], capture_output=True, text=True, timeout=60,
            env=self.lookup_environment(brand, install_root, plugin_root),
        ), install_root

    def uninstall(self, brand):
        shutil.rmtree(self.root / f"{brand}-install", ignore_errors=True)

    def classify(self, relative_path, outcome, check=None):
        """The rule the asset's own ordered result rules apply to `outcome`."""
        rules = contract.tracked_issue_result_rules(self.asset_text(relative_path))
        return contract.classify_tracked_issue_result(rules, outcome, check)

    def run_check_fence(self, relative_path, tracker):
        environment = dict(
            self.environment,
            TRACKER_TX=tracker,
            DOC_REPO=CONSUMING_REPOSITORY,
            DOCS_WT=str(self.fixture.docs),
            DOC_RELATIVE_PATH=DOCUMENT,
        )
        proc = subprocess.run(
            ["bash", "-c", record_check_fence(self.asset_text(relative_path))],
            capture_output=True, text=True, timeout=180, env=environment,
        )
        return json.loads(proc.stdout)

    def resolve(self, relative_path, brand):
        """$TRACKED_ISSUE and $TRACKER_TX, as the asset's own lookup sets them."""
        proc, install_root = self.run_lookup(relative_path, brand)
        self.assertEqual(proc.returncode, 0, f"{relative_path}: {proc.stderr}")
        tool, tracker = proc.stdout.splitlines()[:2]
        for path in (tool, tracker):
            self.assertTrue(Path(path).is_file(), path)
            self.assertTrue(path.startswith(str(install_root)), path)
        return tool, tracker

    def run_fence(self, relative_path, marker, tool, *, expect=None):
        """One of the asset's tracked-issue fences, run as the asset runs it:
        bound to the owning repository, the docs worktree, and the document,
        with the step index the plan gives the creation."""
        body = tracked_issue_fence(self.asset_text(relative_path), marker)
        body = body.replace("<N>", "0")
        # The fence leaves writing the approved request to the agent; this is
        # that write, and nothing else is substituted.
        body = PLACEHOLDER_WRITE_RE.sub(
            'cp "$APPROVED_REQUEST" "$ISSUE_REQUEST"', body
        )
        environment = dict(
            self.environment,
            TRACKED_ISSUE=tool,
            DOC_REPO=CONSUMING_REPOSITORY,
            DOCS_WT=str(self.fixture.docs),
            DOC_RELATIVE_PATH=DOCUMENT,
            APPROVED_REQUEST=str(self.approved_request),
        )
        if "ISSUE_REQUEST=" not in body:
            environment["ISSUE_REQUEST"] = str(self.approved_request)
        proc = subprocess.run(
            ["bash", "-c", body], capture_output=True, text=True, timeout=180,
            env=environment,
        )
        if expect is not None:
            self.assertEqual(
                proc.returncode, expect, f"{marker}\n{proc.stdout}\n{proc.stderr}"
            )
        return json.loads(proc.stdout)

    def plan(self, kind, fingerprint, target=None):
        return json.dumps({
            "entry_key": "CR-1",
            "disposition": "new-issue",
            "steps": [{
                "kind": kind,
                "target": target or f"new issue in {CONSUMING_REPOSITORY}",
                "payload_fingerprint": fingerprint,
                "postcondition": "the issue exists with the approved body",
                "provides_marker": True,
            }],
        })

    def prepare(self, relative_path, brand, kind, *, target=None):
        """A consuming repository whose record holds one approved creation,
        fingerprinted by the asset's own fence and acquired through the
        bundled transaction module."""
        self.build_repository()
        self.reset_github()
        tool, tracker = self.resolve(relative_path, brand)
        fingerprinted = self.run_fence(relative_path, "--fingerprint", tool, expect=0)
        self.assertEqual(fingerprinted["status"], "fingerprint", fingerprinted)
        publish = str(Path(tracker).with_name("publish_coordination_doc.py"))
        tip = self.preflight(publish)
        acquired = self.transaction(
            tracker, "--acquire", "--approved", "--publication-tip", tip,
            "--plan", "-",
            stdin=self.plan(kind, fingerprinted["payload_fingerprint"], target),
        )
        self.assertTrue(acquired["acquired"], acquired)
        self.reset_github()
        return tool, tracker

    def report(self, tracker):
        """The bundled transaction module's own read-only preflight."""
        proc = subprocess.run(
            ["python3", tracker, "--repo", CONSUMING_REPOSITORY,
             "--root", str(self.fixture.docs), "--path", DOCUMENT, "--check"],
            capture_output=True, text=True, env=self.environment, timeout=180,
        )
        return json.loads(proc.stdout)

    def step(self, tracker):
        return self.report(tracker)["steps"][0]

    def assert_ambiguous(self, tracker):
        report = self.report(tracker)
        self.assertEqual(report["steps"][0]["state"], "intent", report)
        self.assertEqual(report["ambiguous_step"]["index"], 0, report)

    def lock_ref(self):
        common = Path(consuming.run(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            self.fixture.docs,
        ))
        lock = common / (
            unit.tracker.transaction_ref(CONSUMING_REPOSITORY, DOCUMENT) + ".lock"
        )
        lock.parent.mkdir(parents=True, exist_ok=True)
        lock.write_text("held\n")
        self.addCleanup(lock.unlink, missing_ok=True)
        return lock

    # -- the packaged helper -----------------------------------------------------

    def test_every_processing_asset_resolves_the_bundled_tool(self):
        for relative_path, brand, _kind in PROCESSING_ASSETS:
            with self.subTest(asset=relative_path):
                self.build_repository()
                tool, tracker = self.resolve(relative_path, brand)
                self.assertTrue(filecmp.cmp(tool, SOURCE, shallow=False), tool)
                # The tool loads the transaction module from beside itself, so
                # the copy it runs is the one this asset's lookup also resolved.
                self.assertEqual(Path(tool).parent, Path(tracker).parent)

    def test_every_processing_asset_resolves_all_four_modules_from_one_bundle(self):
        for relative_path, brand, _kind in PROCESSING_ASSETS:
            with self.subTest(asset=relative_path):
                self.build_repository()
                proc, _install_root = self.run_lookup(relative_path, brand)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                _install_root, plugin_root = self.install(brand)
                tool = Path(proc.stdout.splitlines()[0])
                for module in MECHANISM_MODULES:
                    self.assertTrue((tool.parent / module).is_file(), module)
                self.assertTrue(tool.is_relative_to(plugin_root), tool)

    def test_the_lookup_fails_closed_when_the_bundle_lacks_any_module(self):
        for relative_path, brand, _kind in PROCESSING_ASSETS:
            for module in MECHANISM_MODULES:
                with self.subTest(asset=relative_path, missing=module):
                    self.build_repository()
                    self.uninstall(brand)
                    _install_root, plugin_root = self.install(brand)
                    bundled = [
                        path for path in plugin_root.rglob(module)
                        if path.parent.name == "scripts"
                        and path.parent.parent.name == (
                            "process-report" if brand == "codex" else "kanban"
                        )
                    ]
                    self.assertEqual(len(bundled), 1, bundled)
                    bundled[0].unlink()
                    proc, _ = self.run_lookup(relative_path, brand)
                    self.uninstall(brand)
                    self.assertNotEqual(proc.returncode, 0, proc.stdout)

    def test_a_codex_cache_holding_two_versions_fails_closed(self):
        # A second Kanban version beside the first, complete or partial. Each
        # helper searched for on its own would resolve from whichever version
        # find lists first, so one run could record intent through one
        # version's transaction module and create through another's tool. The
        # lookup refuses rather than choosing, before any GitHub request.
        for relative_path, brand, _kind in PROCESSING_ASSETS:
            if brand != "codex":
                continue
            for other in ("complete", "partial-without-tool", "partial-only-tool"):
                with self.subTest(asset=relative_path, other=other):
                    self.build_repository()
                    self.reset_github()
                    self.uninstall(brand)
                    _install_root, plugin_root = self.install(brand)
                    older = plugin_root.with_name("1.3.0")
                    shutil.copytree(plugin_root, older)
                    scripts = older / "skills" / "process-report" / "scripts"
                    if other == "partial-without-tool":
                        (scripts / "tracked_issue_create.py").unlink()
                    elif other == "partial-only-tool":
                        for module in MECHANISM_MODULES[:2] + MECHANISM_MODULES[3:]:
                            (scripts / module).unlink()
                    proc, _ = self.run_lookup(relative_path, brand)
                    self.uninstall(brand)
                    self.assertNotEqual(proc.returncode, 0, proc.stdout)
                    self.assertEqual(self.calls(), [])

    # -- the asset drives one creation ---------------------------------------------

    def test_every_processing_asset_creates_and_confirms_through_one_operation(self):
        for relative_path, brand, kind in PROCESSING_ASSETS:
            with self.subTest(asset=relative_path):
                tool, tracker = self.prepare(relative_path, brand, kind)

                created = self.run_fence(relative_path, "--create", tool, expect=0)
                self.assertTrue(created["ok"], created)
                self.assertEqual(created["status"], "created", created)
                self.assertEqual(created["github_mutation"], "performed", created)
                self.assertEqual(len(self.posts()), 1, self.calls())
                self.assertEqual(
                    self.posts()[0][3], f"repos/{CONSUMING_REPOSITORY}/issues"
                )
                number = created["issue"]["number"]
                step = self.step(tracker)
                self.assertEqual(step["state"], "confirmed", step)
                self.assertEqual(step["identity"]["id"], str(number), step)
                self.assertEqual(step["identity"]["kind"], kind, step)

                # Run again, the step is already confirmed: the asset's "never
                # create the issue again" holds without the agent's restraint.
                again = self.run_fence(relative_path, "--create", tool, expect=0)
                self.assertEqual(again["status"], "already-created", again)
                self.assertEqual(again["github_mutation"], "none", again)
                self.assertEqual(len(self.posts()), 1, self.calls())

    # -- a failed checkpoint ----------------------------------------------------------

    def test_a_failed_checkpoint_makes_no_github_request(self):
        for relative_path, brand, kind in PROCESSING_ASSETS:
            with self.subTest(asset=relative_path):
                tool, tracker = self.prepare(relative_path, brand, kind)
                lock = self.lock_ref()
                refused = self.run_fence(relative_path, "--create", tool, expect=1)
                lock.unlink()
                self.assertFalse(refused["ok"], refused)
                self.assertEqual(refused["status"], "begin-failed", refused)
                self.assertEqual(refused["github_mutation"], "none", refused)
                # Not one gh invocation of any kind: not a POST, and not the
                # read the incident's run would have needed to notice.
                self.assertEqual(self.calls(), [], refused)
                self.assertEqual(self.step(tracker)["state"], "planned")

    # -- an uncertain outcome -----------------------------------------------------------

    def test_an_uncertain_outcome_cannot_be_retried_blindly(self):
        for mode in ("fail-after", "garbage-after"):
            for relative_path, brand, kind in PROCESSING_ASSETS:
                with self.subTest(asset=relative_path, mode=mode):
                    tool, tracker = self.prepare(relative_path, brand, kind)
                    self.set_github(create_mode=mode)

                    uncertain = self.run_fence(
                        relative_path, "--create", tool, expect=1
                    )
                    self.assertFalse(uncertain["ok"], uncertain)
                    self.assertIn(
                        uncertain["github_mutation"], ("unknown", "performed"),
                        uncertain,
                    )
                    self.assertEqual(len(self.posts()), 1, self.calls())
                    self.assert_ambiguous(tracker)

                    # GitHub recovers, and the same fence runs again: the retry
                    # the incident's run would have made. It is refused before
                    # any request, so the issue that already exists stays the
                    # only one.
                    self.set_github(create_mode="ok")
                    retried = self.run_fence(
                        relative_path, "--create", tool, expect=1
                    )
                    self.assertEqual(retried["status"], "step-ambiguous", retried)
                    self.assertEqual(retried["github_mutation"], "none", retried)
                    self.assertEqual(len(self.posts()), 1, self.calls())
                    self.assertEqual(len(self.github()["issues"]), 1)
                    # `none` describes the retry alone. The asset's rules read
                    # the status before the mutation field, so the step is
                    # unresolved — never "refused, nothing was created".
                    self.assertEqual(
                        self.classify(relative_path, uncertain), "Unresolved"
                    )
                    self.assertEqual(
                        self.classify(relative_path, retried), "Unresolved"
                    )

                    # The asset's own recovery fence is read-only and finds the
                    # one issue; binding it still needs explicit approval.
                    inspected = self.run_fence(
                        relative_path, "--inspect", tool, expect=0
                    )
                    self.assertEqual(
                        inspected["candidates"]["evidence"], "unique-exact",
                        inspected,
                    )
                    self.assertEqual(len(self.posts()), 1, self.calls())
                    self.assert_ambiguous(tracker)

    def test_a_refusal_without_a_transaction_after_an_uncertain_creation(self):
        # The step was left ambiguous by an uncertain creation; a later
        # --create with a different request is refused before the tool reads
        # the record, so its result carries no transaction and says nothing
        # about the earlier attempt. The asset's rules read the record through
        # its own --check fence, and classify the step unresolved.
        for relative_path, brand, kind in PROCESSING_ASSETS:
            with self.subTest(asset=relative_path):
                self.approved_request.write_text(json.dumps(REQUEST), encoding="utf-8")
                tool, tracker = self.prepare(relative_path, brand, kind)
                self.set_github(create_mode="fail-after")
                uncertain = self.run_fence(relative_path, "--create", tool, expect=1)
                self.assertEqual(uncertain["github_mutation"], "unknown", uncertain)
                self.assertEqual(len(self.posts()), 1, self.calls())
                self.set_github(create_mode="ok")

                self.approved_request.write_text(
                    json.dumps(dict(REQUEST, title=REQUEST["title"] + " (edited)")),
                    encoding="utf-8",
                )
                refused = self.run_fence(relative_path, "--create", tool, expect=1)
                self.assertEqual(refused["status"], "payload-mismatch", refused)
                self.assertEqual(refused["github_mutation"], "none", refused)
                self.assertIsNone(refused["transaction"], refused)
                self.assertEqual(len(self.posts()), 1, self.calls())

                checked = self.run_check_fence(relative_path, tracker)
                self.assertEqual(checked["ambiguous_step"]["index"], 0, checked)
                self.assertEqual(
                    self.classify(relative_path, refused, checked), "Unresolved"
                )
                # Without the record, the same result reads as a plain refusal:
                # the --check is what the classification depends on.
                self.assertEqual(self.classify(relative_path, refused), "Refused")
                self.assert_ambiguous(tracker)
                self.assertEqual(len(self.github()["issues"]), 1)
        self.approved_request.write_text(json.dumps(REQUEST), encoding="utf-8")

    # -- the creation target --------------------------------------------------------------

    def test_a_target_naming_another_repository_makes_no_github_request(self):
        for relative_path, brand, kind in PROCESSING_ASSETS:
            with self.subTest(asset=relative_path):
                tool, tracker = self.prepare(
                    relative_path, brand, kind, target="new issue in someone/else"
                )
                refused = self.run_fence(relative_path, "--create", tool, expect=1)
                self.assertEqual(refused["status"], "target-mismatch", refused)
                self.assertEqual(refused["github_mutation"], "none", refused)
                self.assertEqual(self.calls(), [], refused)
                self.assertEqual(self.step(tracker)["state"], "planned")


if __name__ == "__main__":
    unittest.main()
