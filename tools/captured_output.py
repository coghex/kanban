"""Keep a test's console output off the console unless the test fails.

The drainer and the approval service log straight to stdout and stderr, and the
suites that drive them in-process used to write every one of those lines into
the terminal. A passing run of the tooling suite buried its own result under
them, and a real failure's traceback scrolled past among them.

`install()` wraps `unittest.TestCase.run`, so each test runs with `sys.stdout`
and `sys.stderr` pointing at buffers. What the code under test wrote is dropped
when the test passes and appended to the test's own failure or error report
when it does not: the report a reader needs carries the log lines produced
during that test, as `unittest`'s buffer mode (which the canonical command does
not use) would have.

Two things are deliberately not captured:

* A `ResourceWarning` and an `Exception ignored in ...` report are forwarded to
  the real stream the moment they are written. They are how a leaked file or
  pipe announces itself, usually from a finalizer that runs during some later
  test, and CI's guard (`tools/check_resource_warnings.py`) finds them in the
  run's output. A capture that swallowed them would make every leak invisible.
* A subprocess that inherits the real file descriptors writes past the buffers.
  `fileno()` reports the real stream's descriptor so a test that hands
  `sys.stdout` to `subprocess` keeps working.

Production logging is untouched: this module is imported only by tests.
"""

from __future__ import annotations

import functools
import io
import sys
import unittest

# Text that marks a leak. The real stream sees it even while a test is captured.
FORWARDED_MARKERS = ("ResourceWarning", "Exception ignored")

_INSTALLED = "_captures_output"


class _CapturedStream(io.StringIO):
    """A buffer standing in for one of the process's real standard streams."""

    def __init__(self, real, *, forward_leaks: bool) -> None:
        super().__init__()
        self._real = real
        self._forward_leaks = forward_leaks

    def write(self, text: str) -> int:
        written = super().write(text)
        if self._forward_leaks and any(marker in text for marker in FORWARDED_MARKERS):
            self._real.write(text)
            self._real.flush()
        return written

    def fileno(self) -> int:
        return self._real.fileno()

    def isatty(self) -> bool:
        return False


def _annotation(out: _CapturedStream, err: _CapturedStream) -> str:
    """The captured text as it is appended to a report, or nothing."""
    parts = []
    for label, stream in (("Stdout", out), ("Stderr", err)):
        text = stream.getvalue()
        if text:
            parts.append(f"\n{label}:\n{text}" + ("" if text.endswith("\n") else "\n"))
    return "".join(parts)


def _attach(result, marks: dict[str, int], out, err) -> None:
    """Append the captured text to every failure or error this test added.

    A test that passed added none, so what it wrote is dropped.
    """
    annotation = _annotation(out, err)
    if not annotation:
        return
    for name, start in marks.items():
        entries = getattr(result, name, None)
        if not isinstance(entries, list):
            continue
        for index in range(start, len(entries)):
            case, report = entries[index]
            entries[index] = (case, report + annotation)


def install() -> None:
    """Capture every test's console output from here on. Idempotent."""
    original = unittest.TestCase.run
    if getattr(original, _INSTALLED, False):
        return

    @functools.wraps(original)
    def run(self, result=None):
        real_out, real_err = sys.stdout, sys.stderr
        out = _CapturedStream(real_out, forward_leaks=False)
        err = _CapturedStream(real_err, forward_leaks=True)
        marks = {
            name: len(getattr(result, name, None) or ())
            for name in ("failures", "errors")
        }
        sys.stdout, sys.stderr = out, err
        try:
            outcome = original(self, result)
        finally:
            sys.stdout, sys.stderr = real_out, real_err
        _attach(outcome if outcome is not None else result, marks, out, err)
        return outcome

    setattr(run, _INSTALLED, True)
    unittest.TestCase.run = run
