#!/usr/bin/env python3
"""Run `approved_document.main` in a child process with named faults injected.

Not a test module (no `test_*.py` prefix), and never loaded by production code:
tools/test_approved_document_faults.py starts this as a subprocess. A fault is a
named seam in the helper — an operation it performs, before or after — plus what
happens there:

    exit        write the seam's id to the parent's pipe, then `os._exit(86)`
                immediately, so nothing the helper would do next (and no
                `finally` block) runs: the process died
    fail        raise as the operation itself would (an OSError for a file
                operation, a DocumentError for a Git one) instead of running it
    fail-after  run the operation, then raise: the effect landed but the
                command reported failure, the ambiguous case
    edit        write foreign bytes to the document, then continue
    create      create the document exclusively with foreign bytes, then continue

`KANBAN_TEST_FAULTS` is a JSON list of {"seam": "<function>.<before|after>",
"mode": ..., "nth": N, "id": "<T-row.name>"}. A seam that names no function in
the helper fails the harness with exit 2, so a typo can never silently run the
success path. The parent asserts the seam receipt and exit code 86 before it
starts recovery; no sleep, signal or timing selects a crash point.
"""

from __future__ import annotations

import errno
import importlib.util
import json
import os
import sys

EXIT_CODE = 86
FOREIGN = b"# a foreign edit made by the fault harness\n"

# Operations that fail as the filesystem would, not as Git would.
FILE_OPERATIONS = {
    "reserve_directory", "write_scratch", "rename_aside", "read_captured",
    "link_into_place", "restore_exclusive", "remove_file", "file_state",
    "preserve_captured",
}


def load(path):
    spec = importlib.util.spec_from_file_location("approved_document_under_fault", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def install(module, fault, pipe, document):
    function, _, when = fault["seam"].rpartition(".")
    original = getattr(module, function, None)
    if original is None or when not in ("before", "after"):
        print(f"unknown fault seam {fault['seam']!r}", file=sys.stderr)
        sys.exit(2)
    mode, nth = fault.get("mode", "exit"), fault.get("nth", 1)
    count = [0]

    def raise_fault():
        if function in FILE_OPERATIONS:
            raise OSError(errno.EIO, f"injected failure at {fault.get('id', fault['seam'])}")
        raise module.DocumentError(
            "git-failed", f"injected failure at {fault.get('id', fault['seam'])}"
        )

    def fire(position):
        if position != when:
            return
        if mode == "exit":
            os.write(pipe, fault.get("id", fault["seam"]).encode())
            os._exit(EXIT_CODE)
        if mode == "edit":
            with open(document, "wb") as stream:
                stream.write(FOREIGN)
        elif mode == "create":
            descriptor = os.open(document, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(FOREIGN)
        elif mode == "fail" and position == "before":
            raise_fault()
        elif mode == "fail-after" and position == "after":
            raise_fault()

    def wrapper(*args, **kwargs):
        count[0] += 1
        active = count[0] == nth
        if active:
            fire("before")
        result = original(*args, **kwargs)
        if active:
            fire("after")
        return result

    setattr(module, function, wrapper)


def main(argv):
    helper, rest = argv[0], argv[1:]
    module = load(helper)
    pipe = int(os.environ.get("KANBAN_TEST_SEAM_FD", "-1"))
    document = os.environ.get("KANBAN_TEST_DOCUMENT", "")
    for fault in json.loads(os.environ.get("KANBAN_TEST_FAULTS", "[]")):
        install(module, fault, pipe, document)
    return module.main(rest)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
