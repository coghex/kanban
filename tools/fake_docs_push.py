#!/usr/bin/env python3
"""A controlled stand-in for the owner's external `docs-push`, for tests.

Not a test module (no `test_*.py` prefix), so discovery never collects it.
tools/test_approved_document.py writes this file's source into a temporary
`bin/` directory as an executable named `docs-push` and puts that directory
first on `PATH`; the real tool and `~/.config/docs-push.json` are never touched.

It implements the *contract* `tools/approved_document.py` relies on, in the
fewest lines that make the contract observable, and claims nothing about the
owner's git engine (its three-way merge details, its lost-push-race retry, its
`--get` base recording), whose coverage stays with its owner and is documented
in docs/document-workflow-contract.md rather than copied here:

- `--help` lists `--expect` and `--keep`;
- `--expect BLOB` reads the one path once and refuses unless those bytes are
  exactly that blob;
- the commit is built on `origin/<default>`, carries only the named path, and
  uses the message it was given; the path is merged three ways when upstream
  moved, and a real conflict publishes nothing;
- `--keep` leaves the landed copy in a worktree whose branch has commits of its
  own, and a worktree that can fast-forward does so (and keeps the landed copy
  when it cannot).

Every invocation is appended, as JSON, to `$FAKE_DOCS_PUSH_LOG`, so a test can
assert the exact arguments the helper passed. `$FAKE_DOCS_PUSH_MODE` selects a
behavior beyond a clean landing:

    land                       the contract above (the default)
    refuse                     refuses the path as code, exit 2
    claims-success             prints a landing and exits 0 without publishing
    pushed-but-failed          publishes, then exits 2 with an error
    racing-edit                the file changes before the tool reads it
    dies-before-keep           publishes, then stops before `--keep` settles the file
    hang                       never returns (the caller's timeout must stop it)
    leaves-child               exits 2 leaving a child in its process group whose
                               stdio is closed (pid in $FAKE_DOCS_PUSH_CHILD_PID)
    hang-with-child            hangs with a child in its own process group
    hang-with-escapee          hangs with a child in a session of its own that
                               keeps the output pipes open (pid in
                               $FAKE_DOCS_PUSH_CHILD_PID)
    lacks-expect, lacks-keep   `--help` omits that flag
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

MODE = os.environ.get("FAKE_DOCS_PUSH_MODE", "land")
LOG = os.environ.get("FAKE_DOCS_PUSH_LOG")
DEFAULT = "master"


def git(*args, data=None, check=True, env=None):
    proc = subprocess.run(["git", *args], capture_output=True, input=data, env=env)
    if check and proc.returncode:
        print(f"docs-push: git {args[0]}: {proc.stderr.decode().strip()}", file=sys.stderr)
        sys.exit(2)
    return proc


def text(*args, **kwargs):
    return git(*args, **kwargs).stdout.decode().strip()


def blob(revision, path):
    proc = git("rev-parse", "--verify", "--quiet", f"{revision}:{path}", check=False)
    name = proc.stdout.decode().strip()
    return git("cat-file", "blob", name).stdout if name else None


def log(entry):
    if LOG:
        with open(LOG, "a", encoding="utf-8") as stream:
            stream.write(json.dumps(entry) + "\n")


def main(args):
    if "--help" in args or "-h" in args:
        log({"help": True})
        flags = [flag for flag in ("--expect BLOB", "--keep") if MODE != f"lacks-{flag.split()[0][2:]}"]
        print("usage: docs-push [-h] [-m MESSAGE] " + " ".join(f"[{f}]" for f in flags) + " paths")
        return 0
    expect, keep, message, paths = None, False, None, []
    iterator = iter(args)
    for argument in iterator:
        if argument == "--expect":
            expect = next(iterator)
        elif argument == "--keep":
            keep = True
        elif argument == "-m":
            message = next(iterator)
        else:
            paths.append(argument)
    log({"argv": args, "cwd": os.getcwd(), "expect": expect, "keep": keep,
         "message": message, "paths": paths})
    if len(paths) != 1:
        print("docs-push: --expect takes exactly one path to land", file=sys.stderr)
        return 2
    path = paths[0]
    if MODE == "hang":
        import time
        time.sleep(120)
        return 0
    if MODE == "leaves-child":
        child = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(60)"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if os.environ.get("FAKE_DOCS_PUSH_CHILD_PID"):
            Path(os.environ["FAKE_DOCS_PUSH_CHILD_PID"]).write_text(str(child.pid))
        print(f"docs-push: {path}: gave up, leaving a helper running", file=sys.stderr)
        return 2
    if MODE in ("hang-with-child", "hang-with-escapee"):
        import time
        child = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(60)"],
            start_new_session=MODE == "hang-with-escapee",
        )
        if os.environ.get("FAKE_DOCS_PUSH_CHILD_PID"):
            Path(os.environ["FAKE_DOCS_PUSH_CHILD_PID"]).write_text(str(child.pid))
        time.sleep(120)
        return 0
    if MODE == "refuse":
        print(f"docs-push: {path}: counts as code (docs/*.md: tests read it); "
              "use a pull request", file=sys.stderr)
        return 2
    if MODE == "claims-success":
        print(f"landed {path} on {DEFAULT} as 0123456789; this checkout fast-forwarded to it")
        return 0
    root = Path(text("rev-parse", "--show-toplevel"))
    os.chdir(root)
    target = root / path
    if MODE == "racing-edit":
        target.write_bytes(target.read_bytes() + b"\nan edit that raced the tool\n")
    ours = target.read_bytes()
    held = text("hash-object", "--stdin", data=ours)
    if expect and held != expect:
        print(f"docs-push: {path}: holds {held}, not the expected {expect}; nothing landed",
              file=sys.stderr)
        return 2
    git("fetch", "-q", "origin", DEFAULT)
    upstream = f"origin/{DEFAULT}"
    base = blob(text("merge-base", "HEAD", upstream), path)
    theirs = blob(upstream, path)
    if theirs == ours:
        print(f"nothing to land: {path} already match {DEFAULT}")
        return 0
    if theirs is None or theirs == base:
        merged = ours
    elif ours == base:
        merged = theirs
    else:
        with tempfile.TemporaryDirectory() as scratch:
            names = []
            for name, data in (("ours", ours), ("base", base or b""), ("theirs", theirs)):
                (Path(scratch) / name).write_bytes(data)
                names.append(str(Path(scratch) / name))
            proc = git("merge-file", "-p", *names, check=False)
        if proc.returncode:
            print(f"docs-push: {path}: conflicts with an upstream edit made since this "
                  f"branch started; run docs-push --get {path}, redo your edit on that "
                  "copy, and push again", file=sys.stderr)
            return 2
        merged = proc.stdout
    with tempfile.TemporaryDirectory() as scratch:
        env = {**os.environ, "GIT_INDEX_FILE": str(Path(scratch) / "index")}
        git("read-tree", upstream, env=env)
        name = text("hash-object", "-w", "--stdin", data=merged)
        git("update-index", "--add", "--cacheinfo", f"100644,{name},{path}", env=env)
        tree = text("write-tree", env=env)
    commit = text("commit-tree", tree, "-p", upstream, "-m", message or f"docs: {path}")
    pushed = git("push", "-q", "origin", f"{commit}:refs/heads/{DEFAULT}", check=False)
    git("fetch", "-q", "origin", DEFAULT)
    if pushed.returncode:
        print("docs-push: could not push; nothing else changed", file=sys.stderr)
        return 2
    if MODE == "dies-before-keep":
        print("docs-push: interrupted while settling the worktree", file=sys.stderr)
        return 2
    can_fast_forward = git("merge-base", "--is-ancestor", "HEAD", upstream, check=False).returncode == 0
    if keep and not can_fast_forward:
        target.write_bytes(merged)
    elif can_fast_forward:
        head = blob("HEAD", path)
        if head is None:
            target.unlink(missing_ok=True)
        else:
            target.write_bytes(head)
        if git("merge", "--ff-only", "-q", upstream, check=False).returncode and keep:
            target.write_bytes(merged)
    if MODE == "pushed-but-failed":
        print("docs-push: the push was not acknowledged; nothing else changed", file=sys.stderr)
        return 2
    print(f"landed {path} on {DEFAULT} as {commit[:10]}; settled")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
