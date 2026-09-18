# Project-review session liveness: runtime evidence

Issues #687 and #684. This document holds the runtime evidence behind the
session liveness adapter (`project_review_liveness.py`, shipped in both bundles)
and its lifecycle hooks (`hooks/hooks.json` in each bundle), and — in "The
installed workflow's entry path" below — behind the installed `project-review`
workflow that became its caller. The automated suite,
`tools/test_project_review_liveness.py`, pins the adapter's contract with
deterministic hook payloads. This document shows that the installed runtimes
actually deliver those payloads, with the lifetimes the contract assumes. Design
D-17 and its 2026-09-17 amendment in `docs/designs/project_review_ledger_design.md`
state the rules; `docs/agent-workflow-contract.md` §2.13 describes the adapter's
interface.

Every run below used a temporary repository and a synthetic review attempt. No
run reviewed a real pull request, touched GitHub, migrated a consumer ledger, or
published a document.

## Versions and environment

| Item | Value |
|---|---|
| Date | 2026-09-17 |
| Host | macOS 26.6 (Darwin 25.6.0), arm64 |
| Python | 3.14.6 |
| Claude Code | 2.1.274 |
| codex-cli | 0.154.0 |
| Claude bundle | kanban 1.53.0, loaded from this branch with `--plugin-dir` |
| Codex bundle | kanban 1.52.0, installed from this branch's `codex-plugin/` marketplace into an isolated `CODEX_HOME` |
| Claude models | Haiku 4.5 for completion, wrapped and foreground cancel; Sonnet for the rest (Haiku skipped the registration step in one run) |
| Codex model | `gpt-5.6-luna`, reasoning effort `low` |
| Intervals | silence window 20 s, lease renewal 2 s, lease expiry 10 s |

The adapter's minimum supported versions are the two runtime versions above.

## What the runtimes were observed to do

These probes came first and shaped the design. Each used a throwaway plugin
whose hooks logged every event's payload.

### Claude Code 2.1.274

| Case | Hooks fired | Processes |
|---|---|---|
| Normal turn end | `Stop` | — |
| Esc during a 120 s foreground tool | none | tool process killed |
| Esc while generating text between tool calls | none | background process survived, application open |
| `/exit` | `SessionEnd` (`reason: prompt_input_exit`) | background process killed |
| A failed foreground command | `PostToolUseFailure` | — |
| A `run_in_background` Bash call | `PreToolUse`, then `PostToolUse` about 40 ms later | process kept running |

Every tool event, and `Stop`, carried `session_id` and `prompt_id`; tool events
also carried `tool_use_id` and `tool_input.command`. Plugin hooks ran with
`CLAUDE_PLUGIN_ROOT` set to the bundle and needed no trust step.

### codex-cli 0.154.0

| Case | Hooks fired | Processes |
|---|---|---|
| Esc during a 120 s foreground command | `Interrupt` (with `turn_id`) | command moved to a background terminal and kept running; its `PostToolUse` arrived, under the old `turn_id`, only when the process ended |
| An uninterrupted 75 s command | one `PreToolUse`, then one `PostToolUse` 75 s later | — |
| `/exit` between turns | `SessionEnd` (`reason: other`, no `turn_id`) | — |
| `/exit` during a turn | `Interrupt`, then `SessionEnd` | — |

Plugin-shipped hooks load from the plugin's `hooks/hooks.json` with
`PLUGIN_ROOT` set to the installed bundle. They do not run until trusted: the
first launch shows "Hooks need review", and trusting records one entry per hook
in `$CODEX_HOME/config.toml`:

```toml
[hooks.state."kanban@kanban:hooks/hooks.json:pre_tool_use:0:0"]
trusted_hash = "sha256:…"
```

The hash covers the hook's normalized definition (event, matcher and handler),
not the bundle version or path. The adapter recomputes it for every required
hook at registration and compares it with the recorded one; the five hashes
codex-cli recorded for this bundle are pinned in
`tools/test_project_review_liveness.py`. A probe plugin bumped from 0.0.1 to 0.0.2 with
an unchanged `hooks.json` kept running without a new review. A bundle upgrade
therefore needs re-trusting only when `hooks.json` itself changes. The
`[features] hooks` flag must be on (`codex features list` reports its effective
state).

## Setup

Claude Code needs no setup beyond enabling the plugin. For these runs it was
loaded from the branch:

```console
claude --model <model> --plugin-dir <checkout>/claude-plugin/plugins/kanban --dangerously-skip-permissions
```

Codex used a temporary `CODEX_HOME`, so the operator's own configuration was
untouched:

```console
mkdir -p "$SMOKE/runs/codex-home"
cp ~/.codex/auth.json "$SMOKE/runs/codex-home/"
printf '[features]\nhooks = true\n' > "$SMOKE/runs/codex-home/config.toml"
CODEX_HOME="$SMOKE/runs/codex-home" codex plugin marketplace add <checkout>/codex-plugin
CODEX_HOME="$SMOKE/runs/codex-home" codex plugin add kanban@kanban
```

Each scenario repository was also pre-trusted in that `config.toml` with a
`[projects."<repository>"] trust_level = "trusted"` entry. On first launch the
driver answered "Hooks need review" with "Trust all and continue".

## Procedure

The driver below runs one scenario:

```console
LIVENESS_WORKTREE=<checkout> python3 smoke.py <claude|codex> <scenario> "$SMOKE/runs"
```

For each scenario it does this:

1. Create a fresh Git repository holding an empty ledger.
2. Start the runtime in `tmux` in that repository.
3. Paste one prompt, so every step belongs to one invocation (one `prompt_id`
   or `turn_id`). Step 1 is always the real
   `project_review_liveness.py register` command, with a nonce from `nonce`.
4. Watch the attempt's records under `<git common dir>/kanban-project-review/liveness/`.
5. Take the ledger's real `claim --owner-pid <keeper>` as soon as a keeper
   appears, and follow the claim's heartbeat record and renewer.
6. Press keys (Esc, `/exit`) at the points the scenario names, and write the
   timeline to `<runtime>-<scenario>.json`.

Times below are seconds since the driver started.

```python
"""Smoke-test driver for the project-review liveness adapter against installed runtimes.

usage: python3 smoke.py <runtime> <scenario> <workdir>
"""

import importlib.util
import json
import os
import shlex
import subprocess
import sys
import threading
import time
from pathlib import Path

WORKTREE = Path(os.environ["LIVENESS_WORKTREE"])
SILENCE, RENEWAL, EXPIRY = 20, 2, 10
REPO = "coghex/kanban"


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def sh(*argv, **kw):
    return subprocess.run(list(argv), capture_output=True, text=True, **kw)


class Driver:
    def __init__(self, runtime, scenario, workdir):
        self.runtime, self.scenario = runtime, scenario
        self.work = Path(workdir).resolve()
        self.work.mkdir(parents=True, exist_ok=True)
        self.root = self.work / f"{runtime}-{scenario}"
        sh("rm", "-rf", str(self.root))
        self.root.mkdir()
        self.timeline = []
        self.t0 = time.time()
        self.session = f"smoke-{runtime}-{scenario}"
        if runtime == "claude":
            self.bundle = WORKTREE / "claude-plugin/plugins/kanban"
            self.liveness = self.bundle / "scripts/project_review_liveness.py"
            self.ledger_path = self.bundle / "scripts/project_review_ledger.py"
        else:
            self.codex_home = self.work / "codex-home"
            cache = sorted((self.codex_home / "plugins/cache/kanban/kanban").iterdir())
            self.bundle = cache[-1]
            self.liveness = self.bundle / "skills/project-review/scripts/project_review_liveness.py"
            self.ledger_path = self.bundle / "skills/project-review/scripts/project_review_ledger.py"
        self.ledger = load(self.ledger_path, "smoke_ledger")
        self.lv = load(self.liveness, "smoke_liveness")
        sh("git", "init", "-q", cwd=self.root)
        sh("git", "config", "user.email", "smoke@example.invalid", cwd=self.root)
        sh("git", "config", "user.name", "smoke", cwd=self.root)
        document = self.ledger.empty_document()
        document["repositories"][REPO] = self.ledger.empty_repository()
        self.ledger.create_document(self.root, document)
        sh("git", "add", "-A", cwd=self.root)
        sh("git", "commit", "-qm", "ledger", cwd=self.root)
        self.common = self.lv.git_common_directory(self.root)
        self.claimed = None
        self.stop = False

    def mark(self, what, **data):
        entry = {"t": round(time.time() - self.t0, 2), "what": what, **data}
        self.timeline.append(entry)
        print(json.dumps(entry), flush=True)

    # -- tmux
    def launch(self):
        if self.runtime == "claude":
            command = f"claude --model {os.environ.get('SMOKE_CLAUDE_MODEL', 'sonnet')} --plugin-dir {shlex.quote(str(self.bundle))} --dangerously-skip-permissions"
            env = ""
        else:
            command = "codex -m gpt-5.6-luna -c model_reasoning_effort=low --dangerously-bypass-approvals-and-sandbox"
            env = f"CODEX_HOME={shlex.quote(str(self.codex_home))} "
        sh("tmux", "kill-session", "-t", self.session)
        sh("tmux", "new-session", "-d", "-s", self.session, "-x", "200", "-y", "50", "-c", str(self.root), env + command)
        time.sleep(8)
        pane = self.pane()
        if "trust this folder" in pane or "Yes, I trust" in pane:
            self.keys("Down", "Enter")
            time.sleep(4)
        if "Hooks need review" in self.pane():
            self.keys("Down", "Enter")
            time.sleep(4)
        self.mark("launched")

    def pane(self):
        return sh("tmux", "capture-pane", "-p", "-t", self.session).stdout

    def keys(self, *keys):
        for key in keys:
            sh("tmux", "send-keys", "-t", self.session, key)
            time.sleep(0.4)

    def type(self, text):
        buffer = self.work / f"{self.session}.prompt"
        buffer.write_text(text)
        sh("tmux", "load-buffer", "-b", self.session, str(buffer))
        sh("tmux", "paste-buffer", "-p", "-d", "-b", self.session, "-t", self.session)
        time.sleep(2)
        sh("tmux", "send-keys", "-t", self.session, "Enter")
        for _ in range(4):
            time.sleep(2)
            if "[Pasted text" not in self.pane():
                return
            sh("tmux", "send-keys", "-t", self.session, "Enter")

    def escape(self):
        # tmux's first Escape can be swallowed as a meta prefix; a second one
        # a moment later is harmless after the interrupt landed.
        self.keys("Escape")
        time.sleep(0.8)
        self.keys("Escape")

    # -- observation
    def attempts(self):
        return self.lv._attempt_ids(self.common)

    def observe(self):
        seen = {}
        renewals = None
        while not self.stop:
            for attempt in self.attempts():
                try:
                    record = self.lv.read_attempt(self.common, attempt)
                    ended = self.lv.ended_record(self.common, attempt)
                except ValueError:
                    continue
                state = seen.setdefault(attempt, {})
                if record["keeper"] and "registered" not in state:
                    state["registered"] = True
                    self.mark("registered", attempt=attempt, keeper=record["keeper"]["pid"],
                              session=record["session_id"], invocation=record["invocation_id"],
                              version=record["runtime_version"])
                    self.claim(record["keeper"]["pid"])
                if ended is not None and "ended" not in state:
                    state["ended"] = True
                    self.mark("attempt-ended", reason=ended["reason"], ended_at=round(ended["at"] - self.t0, 2))
                if record["keeper"] and "keeper-gone" not in state:
                    standing = self.ledger.holder_standing(record["keeper"])
                    if standing != "live":
                        state["keeper-gone"] = True
                        self.mark("keeper-gone")
                launches = self.lv._launches_directory(self.common, attempt)
                if launches.exists():
                    for f in sorted(launches.iterdir()):
                        if f.name not in state:
                            state[f.name] = True
                            self.mark("launch-record", file=f.name)
                progress = self.lv.attempt_directory(self.common, attempt) / "progress.json"
                if progress.exists():
                    try:
                        at = json.loads(progress.read_text())["at"]
                        if state.get("progress") != at:
                            state["progress"] = at
                            state["last_progress"] = round(at - self.t0, 2)
                    except Exception:
                        pass
            if self.claimed:
                record = self.ledger.read_heartbeat(self.ledger.git_common_directory(self.root), self.claimed["claim"]["token"])
                count = None if record is None else record["renewals"]
                if count != renewals:
                    if count is None or renewals is None or count % 5 == 0:
                        self.mark("heartbeat", renewals=count)
                    renewals = count
                renewer = self.claimed["claim"]["renewer"]
                if "renewer-gone" not in seen and self.ledger.holder_standing(renewer) != "live":
                    seen["renewer-gone"] = True
                    self.mark("renewer-gone", last_renewals=renewals)
            for attempt, state in seen.items():
                if isinstance(state, dict) and state.get("last_progress") is not None and state.get("reported") != state["last_progress"]:
                    state["reported"] = state["last_progress"]
                    self.mark("progress", at=state["last_progress"])
            time.sleep(0.2)

    def claim(self, keeper_pid):
        listing = {"pages": [{"page": 1, "limit": 100, "prs": [{"number": 612, "title": "PR 612", "merged_at": "2026-09-01T00:00:00Z"}]}]}
        done = subprocess.run(
            [sys.executable, str(self.ledger_path), "claim", "--root", str(self.root), "--repo", REPO,
             "--owner-pid", str(keeper_pid), "--renewal", str(RENEWAL), "--expiry", str(EXPIRY)],
            input=json.dumps(listing), capture_output=True, text=True,
        )
        if done.returncode != 0:
            self.mark("claim-refused", stderr=done.stderr.strip())
            return
        self.claimed = json.loads(done.stdout)
        self.mark("claimed", token=self.claimed["claim"]["token"], renewer=self.claimed["claim"]["renewer"]["pid"])

    def wait(self, predicate, label, timeout=240):
        end = time.time() + timeout
        while time.time() < end:
            if predicate():
                return True
            time.sleep(0.25)
        self.mark("timeout", waiting_for=label, pane=[l for l in self.pane().splitlines() if l.strip()][-25:])
        return False

    def has(self, what, **match):
        return any(e["what"] == what and all(e.get(k) == v for k, v in match.items()) for e in self.timeline)

    # -- scenarios
    def prompt(self, steps, tail):
        nonce = sh(sys.executable, str(self.liveness), "nonce").stdout.strip()
        register = (f"python3 {self.liveness} register --runtime {self.runtime} --root {self.root} "
                    f"--repo {REPO} --nonce {nonce} --silence {SILENCE} --renewal {RENEWAL}")
        lines = [
            "This is a scripted smoke test. Run each numbered step below as its own shell tool call, in order, "
            "exactly as written, and add no other tool calls. In later steps replace ATTEMPT with the value of "
            "the \"attempt\" field that step 1 prints.",
            f"Step 1: {register}",
        ]
        for index, step in enumerate(steps, start=2):
            lines.append(f"Step {index}: {step}")
        lines.append(tail)
        return " ".join(lines)

    def run_step(self, label, seconds):
        return (f"python3 {self.liveness} run --root {self.root} --attempt ATTEMPT --launch {label} -- "
                f"python3 -c \"import time; time.sleep({seconds})\"")

    def main(self):
        self.launch()
        observer = threading.Thread(target=self.observe, daemon=True)
        observer.start()
        s = self.scenario
        short = 'python3 -c "import time; time.sleep(4)"'
        if s == "completion":
            self.type(self.prompt([short, short], "Then reply with the single word done."))
            self.wait(lambda: self.has("attempt-ended"), "attempt end")
        elif s == "wrapped":
            self.type(self.prompt([self.run_step("build", 50) + "   (run it in the foreground and wait for it to finish)"],
                                  "Then reply with the single word done."))
            self.wait(lambda: self.has("attempt-ended"), "attempt end", timeout=300)
        elif s == "cancel-foreground":
            self.type(self.prompt([self.run_step("suite", 600) + "   (run it in the foreground and wait for it)"],
                                  "Then reply with the single word done."))
            self.wait(lambda: self.has("launch-record", file="suite.wrapper.json"), "wrapper start")
            time.sleep(SILENCE + 10)
            self.mark("escape-sent")
            self.escape()
            self.wait(lambda: self.has("attempt-ended"), "attempt end", timeout=120)
        elif s == "cancel-background":
            if self.runtime == "claude":
                bg = self.run_step("bg", 600) + "   (use run_in_background set to true for this step)"
            else:
                bg = self.run_step("bg", 600) + "   (start it and do not wait for it: leave it running as a background terminal session and move on immediately)"
            self.type(self.prompt([bg], "Then write a 2000-word essay about rivers as your reply text, with no tool calls."))
            self.wait(lambda: self.has("launch-record", file="bg.wrapper.json"), "wrapper start")
            time.sleep(6)
            self.mark("escape-sent")
            self.escape()
            self.wait(lambda: self.has("attempt-ended"), "attempt end", timeout=120)
            alive = sh("pgrep", "-f", "time.sleep\\(600\\)").stdout.split()
            self.mark("background-process-after-end", alive_pids=alive)
        elif s == "cancel-between":
            self.type(self.prompt([short], "Then write a 2000-word essay about mountains as your reply text, with no tool calls."))
            self.wait(lambda: self.has("progress") and self.has("registered"), "step progress")
            time.sleep(8)
            self.mark("escape-sent")
            self.escape()
            self.wait(lambda: self.has("attempt-ended"), "attempt end", timeout=120)
        elif s == "session-end":
            self.type(self.prompt([short], "Then write a 2000-word essay about oceans as your reply text, with no tool calls."))
            self.wait(lambda: self.has("progress") and self.has("registered"), "step progress")
            time.sleep(6)
            if self.runtime == "claude":
                self.mark("escape-sent")
                self.escape()
                time.sleep(2)
            self.mark("exit-sent")
            self.type("/exit")
            time.sleep(3)
            if not self.has("attempt-ended"):
                self.keys("C-c")
                time.sleep(0.3)
                self.keys("C-c")
                self.mark("ctrl-c-sent")
            self.wait(lambda: self.has("attempt-ended"), "attempt end", timeout=120)
        if self.claimed:
            self.wait(lambda: self.has("renewer-gone"), "renewer exit", timeout=60)
        time.sleep(1)
        self.stop = True
        sh("tmux", "kill-session", "-t", self.session)
        sh("pkill", "-f", "time.sleep\\(600\\)")
        out = self.work / f"{self.runtime}-{self.scenario}.json"
        out.write_text(json.dumps({"runtime": self.runtime, "scenario": s, "silence": SILENCE, "renewal": RENEWAL,
                                   "expiry": EXPIRY, "timeline": self.timeline}, indent=1))
        print("wrote", out)


if __name__ == "__main__":
    Driver(*sys.argv[1:4]).main()
```

## Results

"Last event" is the last bound progress event before the attempt ended.
"Action" is the key the driver sent. Every run took a real claim, and in every
run the renewer exited, retiring the lease, about one expiry (10 s) after the
keeper did.

### Claude Code 2.1.274

| Scenario | Expected | Last event | Action | Attempt ended | Keeper gone | Renewer gone |
|---|---|---|---|---|---|---|
| completion | `Stop` ends the keeper at once | 30.02 | — | 31.03, `Stop` | 31.92 | 41.65 |
| wrapped (50 s foreground) | renewal continues past the silence window while the wrapped call is in flight | 22.01, then tool-finish at 72.28 | — | 73.35, `Stop` | 74.41 | 83.81 |
| cancel during foreground wrapped command | Esc kills the wrapper, then the keeper ends within one poll, the silence window having passed | 16.00 | Esc at 47.40 | 48.79, `silence` | 48.81 | 58.72 |
| backgrounded wrapped command, then cancel | the launch's tool call completes at once, so no exemption; silence ends the keeper while the process survives | 32.51 | Esc at 38.69 | 52.57, `silence` | 52.63 | 61.33 |
| cancel between tool calls | no event; silence ends the keeper | 31.18 | Esc at 34.39 | 51.88, `silence` | 52.08 | 60.76 |
| session termination | `SessionEnd` ends the keeper at once | 38.20 | Esc at 38.96, `/exit` at 42.58 | 44.67, `SessionEnd` | 45.63 | 55.20 |

Some detail on four of these:

- **Wrapped:** there were 50 s without a bound event — 2.5 times the silence
  window — and the heartbeat's renewal count kept rising throughout.
- **Cancel during a foreground wrapped command:** the launch had been exempt for
  31 s of silence, and the keeper ended 1.4 s after Esc.
- **Backgrounded command:** `bg.finish.json` arrived 80 ms after
  `bg.start.json`. The keeper ended 20.06 s after the last event, and the wrapped
  process was still running afterwards.
- **Cancel between tool calls:** the keeper ended 20.7 s after the last event,
  which is the silence window plus up to one keeper poll.

### codex-cli 0.154.0

| Scenario | Expected | Last event | Action | Attempt ended | Keeper gone | Renewer gone |
|---|---|---|---|---|---|---|
| completion | `Stop` ends the keeper at once | 35.78 | — | 36.94, `Stop` | 37.01 | 46.68 |
| wrapped (50 s command) | renewal continues past the silence window while the wrapped call is in flight | 28.75 | — | 60.70, `Stop` | 61.88 | 70.73 |
| cancel during foreground wrapped command | `Interrupt` ends the keeper at once | 26.23 | Esc at 56.37 | 56.44, `Interrupt` | 56.98 | 66.78 |
| background-terminal wrapped command, then cancel | `Interrupt` ends the keeper at once while the process survives | 31.41 | Esc at 37.69 | 37.76, `Interrupt` | 38.20 | 48.04 |
| cancel between tool calls | `Interrupt` ends the keeper at once | 26.21 | Esc at 26.50 | 26.57, `Interrupt` | 27.41 | 36.78 |
| session termination | the keeper ends at once | 26.17 | `/exit` at 24.25, during the turn | 26.40, `Interrupt` | 26.83 | 36.45 |

Some detail on four of these:

- **Wrapped:** the model ran the command through Codex's code-mode `exec`,
  which returned after 30 s while the process kept running, and then ended the
  turn. The keeper held 32 s past the last event — longer than the silence
  window — until `Stop` ended it.
- **Cancel during a foreground wrapped command:** the launch had been exempt for
  30 s of silence.
- **Background-terminal command:** the wrapped process was still running after
  the keeper ended.
- **Session termination:** `/exit` during a turn delivered `Interrupt` first,
  and the `SessionEnd` that followed was discarded and logged against the ended
  attempt. `SessionEnd` ending an active attempt is covered by the automated
  suite.

After the round-1 review added the complete-hook and per-hook trust checks, the
completion scenario was re-run on both installed runtimes with the same setup.
Registration still succeeded, with Codex validating its real recorded trust
hashes for all five hooks: `Stop` ended the attempt at 32.35 s (Codex) and
33.81 s (Claude), and both keepers exited within half a second.

## The installed workflow's entry path (issue #684)

Everything above was collected while nothing installed registered an attempt:
the adapter shipped in both bundles and its tests were its only caller. Issue
#684 made the installed `project-review` workflow that caller. Its PR mode
takes a nonce, registers this adapter in a tool call of its own, and hands the
keeper's pid to `project_review_ledger.py claim --owner-pid` before it claims a
pull request; nothing else in either bundle registers anything.

Two things about the registration changed with that slice, and both are visible
in the command text rather than in the adapter:

- **`--root` is the docs worktree, not the primary checkout.** The adapter reads
  the renewal interval a claim would record out of the ledger under that root,
  to refuse a silence window shorter than it. Pointed at the primary checkout it
  would read a repository with no ledger and validate the window against the
  60-second default instead of this repository's own. Both are worktrees of one
  repository, so the attempt's records land in the same Git common directory
  either way.
- **The register and `run` commands spell the helper's path out.** The hook fires
  before the command runs and reads the text the tool call was given, so it sees
  `$LIVENESS` unexpanded. It recognizes a registration by
  `project_review_liveness.py` followed by `register`; a shell variable in that
  position leaves it nothing to recognize, and the registration then refuses with
  `hooks-not-observed`.

### Setup

The same as above, with the reviewed repository given a `docs-wip` worktree
holding an empty ledger and this repository's lease defaults, and the Claude
bundle's version bumped to 1.55.0 and the Codex bundle's to 1.54.0 by that
slice. `hooks/hooks.json` is unchanged in both, so the Codex trust hashes above
still apply and were reused unmodified.

| Item | Value |
|---|---|
| Date | 2026-09-17 |
| Host | macOS 26.6 (Darwin 25.6.0), arm64 |
| Python | 3.14.6 |
| Claude Code | 2.1.274 for the completion and between-call runs; 2.1.276, auto-installed part-way through, for the during-call runs. Bundle loaded with `--plugin-dir` |
| codex-cli | 0.154.0, bundle installed from this branch into an isolated `CODEX_HOME` |
| Claude model | Haiku 4.5 |
| Codex model | `gpt-5.6-luna` |
| Intervals | silence window 20 s, lease renewal 2 s, lease expiry 10 s |

Each run is one non-interactive invocation, so every step below belongs to one
`prompt_id` or `turn_id`:

```console
claude -p "<the three steps>" --plugin-dir <bundle> --dangerously-skip-permissions --model haiku
CODEX_HOME=<scratch> codex exec --dangerously-bypass-approvals-and-sandbox --model gpt-5.6-luna "<the three steps>"
```

The prompt is the workflow's own steps 2 and 3 and nothing else: run
`project_review_liveness.py nonce`; run `project_review_liveness.py register
--runtime <runtime> --root <docs worktree> --repo coghex/kanban --nonce <the
digits, substituted literally> --silence 20`; run `project_review_ledger.py
claim --root <docs worktree> --repo coghex/kanban --owner-pid <the keeper pid>`
with a one-page merged-pull-request listing on standard input. No run reviewed a
pull request, reached GitHub, or published anything: the listing is a file the
driver wrote, and the repository is a scratch one.

A watcher polled the attempt records and the lease heartbeat throughout and
wrote the timeline. Times are seconds since the driver started.

### Results

| Runtime | Scenario | Registered | Claimed | Attempt ended | Lease retired |
|---|---|---|---|---|---|
| Claude Code 2.1.274 | completion | 11.57 | 14.86 | 17.90, `Stop` | 26.76 |
| Claude Code 2.1.274 | cancellation between tool calls | 10.06 | 13.11 | 33.14, `silence` | 41.51 |
| codex-cli 0.154.0 | completion | 14.08 | 21.17 | 23.71, `Stop` | 33.09 |
| codex-cli 0.154.0 | cancellation between tool calls | 13.10 | 19.44 | 40.21, `silence` | 49.82 |

- **Both runtimes substituted the nonce literally**, unprompted, and the
  handshake was found: Claude's session reported `Generated nonce
  11e959e640b6e30d933432130461f551` and then registered with those digits;
  Codex's transcript shows the same line with `NONCE` replaced by
  `61347199c673442776c472ff434dcabc`. Every registration bound the attempt to
  its own session and invocation id, and every claim that followed named the
  keeper that registration had reported.
- **The cancellation runs kill the whole session process group** once the claim
  is on disk — no `Stop`, no `Interrupt`, no `SessionEnd`, and no descriptor
  closed by hand. Nothing but the keeper's own silence window ends the attempt,
  and the observed ends are 20.03 s (Claude) and 20.77 s (Codex) after the kill:
  the silence window plus at most one keeper poll. The lease then lapsed 8.4 s
  and 9.6 s later, which is the renewer noticing its owner gone and retiring the
  heartbeat within one expiry. Both claims were left on an unreviewed row, so
  the next invocation takes them over rather than finding a completion that
  never happened.
- **A cancellation Codex *does* report is faster**, and the retained runs above
  measure it: `Interrupt` ended the keeper within a second of Esc. The kill here
  is the worse case for both runtimes deliberately.

### Cancellation during a tool call

The runs above cancel between tool calls, by killing the session's process
group. A cancellation *during* a call needs a real interrupt, so these were
driven the way #687's own runs were: the runtime in `tmux`, one prompt pasted
in, and `tmux send-keys Escape` once the claim was on disk and step 4's command
was in flight. Step 4 is
`project_review_liveness.py run … --launch build -- sleep 300`, in the
foreground.

| Runtime | Registered | Claimed | Escape | Attempt ended | Lease retired |
|---|---|---|---|---|---|
| codex-cli 0.154.0 | 27.88 | 35.05 | 98.67 | 98.98, `Interrupt` | 108.20 |
| Claude Code 2.1.276 (run 1) | 27.10 | 30.66 | 38.53 | 151.9, `SessionEnd` | — |
| Claude Code 2.1.276 (run 2) | 24.77 | 27.60 | 35.46 | not within 230 s | — |

Codex behaves as the contract says: `Interrupt` reached the hook 0.31 s after
the Escape, the attempt ended at once, and the renewer retired the lease 9.5 s
later — one expiry.

**Claude Code does not, on 2.1.276.** This is a change from 2.1.274, and it
matters enough to state plainly. The probe table above records, on 2.1.274,
"Esc during a 120 s foreground tool | none | tool process killed". On 2.1.276
the wrapped command was *not* killed: run 2 watched it directly and it was still
running 90 s after the Escape. Because a live wrapper keeps its launch exempt
from the silence window, the keeper then never ends on silence either — run 1's
attempt ended only when the driver killed the session, 113 s after the Escape,
and run 2's had not ended 195 s after it.

So for a cancellation during a *foreground wrapped* command on Claude Code
2.1.276, the bound is not the silence window. That command holds its exemption
until it exits, and its tool-finish event is itself a progress event — so it
refreshes the window rather than ending it, and the keeper waits the window out
afresh afterwards. The bound is the command's remaining run time, plus a silence
window, plus a keeper poll, plus one renewal interval, plus the lease expiry; or
the end of the session, whichever comes first. The renewal interval belongs in
that chain because the renewer follows the keeper rather than ending with it: it
looks at its signal at least once per renewal interval, so it can stamp one more
renewal after the keeper is gone. Run 1 measured the shorter form of that phase
— this implementation looks once per second — and the chain above quotes the
interval the contract promises rather than the poll this build happens to
use. Three consequences,
none of which this arc's code gets wrong:

- The lease is held for that whole time rather than for the documented bound.
  Nothing else can review that pull request meanwhile; it is a delay, not a
  corruption, and the fencing guarantees are untouched.
- `project-review`'s reclaim pass is right to refuse to remove an attempt's
  directory while `status` reports an unfinished launch. That refusal is what
  keeps a surviving command's working tree under it.
- The version row at the top of this document is *measured on*, not *still
  true*. Re-probe the foreground-interrupt case on a Claude Code upgrade before
  quoting §2.13's timings.

Claude Code 2.1.274 auto-updated to 2.1.276 between the completion runs and
these; both versions therefore appear above, each against what it was observed
doing.

### What is retained rather than re-run

The scenarios above this section — a wrapped command holding the exemption open,
a backgrounded command getting none, and `/exit` — were collected against the
same `hooks.json`, and they are the evidence for the keeper's rules themselves.
#684 changed nothing the keeper observes: it changed which root the registration
reads its lease settings from, how the command text spells the helper, and it
added a read-only launch report to `status`, none of which a keeper consults.
The runs in this section cover the entry path as installed at all three points
the requirement names — a completed turn, a cancellation between tool calls, and
a cancellation during one — on both runtimes, and the retained runs remain the
evidence for the rules between them.

The one retained result this section supersedes is Claude Code's
foreground-interrupt row, for 2.1.276 only: it was true when measured on
2.1.274 and is not true now. The row is left where it is, with its version, and
the change recorded above.

## Limitations

- **A cancellation Claude Code does not report is bounded, not immediate.** The
  bound is the silence window (10 minutes by default), plus one renewer poll,
  plus the lease expiry — **provided no wrapped command is still running**. On
  2.1.276 an interrupt does not kill a foreground wrapped command, and a live
  wrapper holds its launch exempt from that window; its finish event then
  refreshes the window rather than ending it. The bound becomes the command's
  remaining run time, plus a silence window, plus a keeper poll, plus one
  renewal interval — the renewer looks at its signal at least once per interval,
  so it may stamp one last renewal after the keeper is gone — plus that
  renewal's expiry, or the end of the session. See "Cancellation during a tool call".
- **The wrapped-command exemption ends when the runtime reports the tool call
  finished.** Codex reports a command it moved to a background terminal as in
  flight until the process exits. So on Codex the exemption lasts as long as the
  wrapped process does. Turn completion, `Interrupt` and `SessionEnd` still end
  the keeper at once. The only end this lengthens is one the runtime never
  reports, such as a Codex process killed without `SessionEnd`, and only by the
  wrapped command's remaining run time.
- **Claude Code's Bash tool caps a foreground command at 10 minutes.** A
  foreground wrapped command therefore cannot outlast the default silence window
  by much. A longer command run in the background gets no exemption, and relies
  on the model's own tool calls while it waits.
- **The hook resolves the repository from the session's working directory.** A
  session whose working directory leaves the repository and all its worktrees
  sends events the hook cannot place. That fails closed: those events renew
  nothing, and the attempt lapses by silence.
