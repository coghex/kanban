#!/usr/bin/env python3
"""Print the path of the canonical issue-review backend, `approve_issues.py`.

Run with: python3 resolve_issue_review_backend.py

Issue #841. Fourteen packaged workflow assets (`solve`, `issue-review`,
`issue-rereview`, `triage` and `retriage` in the Claude and Codex bundles, and
`solve` in the Grok, Kimi, Google and Claude-on-Copilot bundles) used to carry
this probe as a pasted bash-and-Python fence, and a test had to drive all of
them to keep them agreeing. They call this script instead, so there is one
program to read and one to test. It prints the resolved path on standard
output and exits 0, or prints one diagnostic on standard error and exits
non-zero; the assets keep their "stop and report exactly the message it
printed" step unchanged.

The precedence is the one `tools/install_issue_review.py` writes its
installation for and the six pull-request coordinators' `approver_path()`
implements separately: a non-empty `KANBAN_ISSUE_REVIEW_INSTALL_DIR` names the
installation directory outright; otherwise the install record names the
backend; and only a record that names none, which is how an installation
predating the record looks, falls back to the directory the record itself
lives in.

The record has two locations, probed in one order on every platform: the XDG
data directory's first, then `~/Library`'s. A location is occupied when
anything exists at its path, a dangling link included, so a broken record is
reported rather than read as "never installed" and stepped past. The first
occupied location is the installation, so nothing here decides which platform
it is on; when neither exists the XDG candidate supplies the answer and the
diagnostic names both. `$XDG_DATA_HOME` moves the first candidate only when it
is set and non-empty, the rule `tools/kanban_config.py`'s
`_xdg_issue_review_dir` follows, not the drainer's absolute-only rule. This
deliberately does not call `kanban_config.issue_review_record_path()`, whose
answer for an absent record depends on the platform, and an installed bundle
carries none of `tools/` to import it from.

An installed bundle carries a byte-identical copy of this file, held by the
copy-parity tests, and imports nothing outside the standard library.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Mapping, Optional, Sequence

OVERRIDE_VARIABLE = "KANBAN_ISSUE_REVIEW_INSTALL_DIR"
BACKEND_NAME = "approve_issues.py"

# The two record locations, spelled whole. The agent-workflow contract's
# `issue-review-discovery-record` rows ground each literal in every file that
# resolves the record, and a path assembled from fragments would pass no such
# check.
XDG_RECORD = "/.local/share/kanban/issue-review/config.json"
LIBRARY_RECORD = "/Library/Application Support/kanban/issue-review/config.json"
XDG_DATA_HOME_RECORD = "/kanban/issue-review/config.json"


class ResolutionError(Exception):
    """The backend cannot be resolved; the message is the whole diagnostic."""


def record_candidates(environment: Mapping[str, str]) -> list[Path]:
    """The two record locations in probe order."""
    home = environment.get("HOME", "")
    xdg_base = environment.get("XDG_DATA_HOME", "")
    xdg_record = xdg_base + XDG_DATA_HOME_RECORD if xdg_base else home + XDG_RECORD
    return [Path(xdg_record), Path(home + LIBRARY_RECORD)]


def resolve_backend(environment: Optional[Mapping[str, str]] = None) -> Path:
    """The backend's path, or a `ResolutionError` carrying the diagnostic."""
    environment = os.environ if environment is None else environment
    records = record_candidates(environment)
    occupied = [candidate for candidate in records if os.path.lexists(candidate)]
    record = occupied[0] if occupied else records[0]
    consulted = (
        str(record) if occupied else " and ".join(str(candidate) for candidate in records)
    )
    override = environment.get(OVERRIDE_VARIABLE)
    if override and override.strip():
        resolved = Path(override).expanduser() / BACKEND_NAME
    else:
        if not occupied:
            document = {}
        else:
            try:
                document = json.loads(record.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                raise ResolutionError(f"The install record at {record} is unreadable ({error}).")
        if not isinstance(document, dict):
            raise ResolutionError(f"The install record at {record} is not a JSON object.")
        if "backend_path" not in document:
            resolved = record.parent / BACKEND_NAME
        else:
            recorded = document["backend_path"]
            if not isinstance(recorded, str) or not Path(recorded).is_absolute():
                raise ResolutionError(
                    f"The install record at {record} does not name an absolute backend_path: {recorded!r}."
                )
            resolved = Path(recorded)
    if not resolved.is_file():
        raise ResolutionError(
            f"Canonical issue reviewer was not found at {resolved} (consulted {consulted}). "
            "Run `python3 tools/install_issue_review.py` from the Kanban checkout, "
            "adding --install-dir if it belongs elsewhere."
        )
    return resolved


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    if arguments:
        print(
            "resolve_issue_review_backend.py takes no arguments; it reads "
            f"{OVERRIDE_VARIABLE}, XDG_DATA_HOME and HOME.",
            file=sys.stderr,
        )
        return 2
    try:
        print(resolve_backend())
    except ResolutionError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
