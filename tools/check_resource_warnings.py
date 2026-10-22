#!/usr/bin/env python3
"""Fail when a captured test run reports a leaked resource.

CI's `python` job runs the tooling suite with its output kept in a file and
hands that file here. A leaked file, pipe, or temporary directory is announced
by a `ResourceWarning` from a finalizer, and a finalizer's own failure is
printed as `Exception ignored in ...` without touching the exit status, so the
suite can exit 0 with a leak in its output. This reads the output instead of
trusting the status, and so does not depend on `-W error`, which cannot reach
either.

    check_resource_warnings.py OUTPUT_FILE

Exits 0 when the output names no leak, 1 and prints each offending line when it
does, and 2 when the file cannot be read.
"""

from __future__ import annotations

import sys
from pathlib import Path

from captured_output import FORWARDED_MARKERS


def leak_lines(text: str) -> list[str]:
    return [
        line
        for line in text.splitlines()
        if any(marker in line for marker in FORWARDED_MARKERS)
    ]


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        text = Path(argv[0]).read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        print(f"check_resource_warnings.py: cannot read {argv[0]}: {error}", file=sys.stderr)
        return 2
    found = leak_lines(text)
    if not found:
        return 0
    print(
        f"The run reported {len(found)} leaked-resource line(s); every one is a "
        "file, pipe, or directory some test or tool opened and never closed:",
        file=sys.stderr,
    )
    for line in found:
        print(f"  {line}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
