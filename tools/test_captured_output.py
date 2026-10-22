"""Tests for `captured_output`, the capture that keeps a passing run quiet.

The capture has to do three things at once, and each is asserted here with a
passing, a failing, and an erroring case: a passing test's console output is
dropped, a failing or erroring test's report carries it, and a leak's
diagnostics still reach the real stream where CI's guard looks for them.
"""

import io
import sys
import unittest

import captured_output
import check_resource_warnings

captured_output.install()


def inner_case(body, *, cleanup=None):
    """A one-test case built on the spot, so discovery never collects it."""

    class Inner(unittest.TestCase):
        def runTest(self):
            body(self)

    case = Inner()
    if cleanup is not None:
        case.addCleanup(cleanup)
    return case


class CaptureTests(unittest.TestCase):
    def run_inner(self, body, *, cleanup=None):
        """Run a case under the capture, reporting what reached the outside.

        The outside is a pair of plain buffers this method installs, not this
        test's own capture: that one forwards a leak diagnostic to the real
        stream, which would put the inner tests' deliberate diagnostics into
        the run's output and trip the guard that reads it.
        """
        saved = sys.stdout, sys.stderr
        outside_out, outside_err = io.StringIO(), io.StringIO()
        sys.stdout, sys.stderr = outside_out, outside_err
        try:
            result = unittest.TestResult()
            inner_case(body, cleanup=cleanup).run(result)
            restored = sys.stdout is outside_out and sys.stderr is outside_err
        finally:
            sys.stdout, sys.stderr = saved
        self.assertTrue(restored, "the inner run did not restore the streams")
        return result, (outside_out.getvalue(), outside_err.getvalue())

    def test_a_passing_test_writes_nothing_to_either_stream(self):
        def body(case):
            print("drainer: Processing PR #42 (pass 1)")
            print("approve_issues.py error: refused", file=sys.stderr)

        result, leaked = self.run_inner(body)
        self.assertTrue(result.wasSuccessful())
        self.assertEqual(leaked, ("", ""))

    def test_a_failing_test_reports_what_it_wrote(self):
        def body(case):
            print("drainer: Merging PR #42")
            print("gh: server error", file=sys.stderr)
            case.fail("the merge did not happen")

        result, leaked = self.run_inner(body)
        self.assertEqual(leaked, ("", ""))
        self.assertEqual(len(result.failures), 1)
        report = result.failures[0][1]
        self.assertIn("the merge did not happen", report)
        self.assertIn("Stdout:\ndrainer: Merging PR #42\n", report)
        self.assertIn("Stderr:\ngh: server error\n", report)

    def test_an_erroring_test_reports_what_it_wrote(self):
        def body(case):
            print("drainer: Closing linked issue acme/widgets#99")
            raise RuntimeError("boom")

        result, leaked = self.run_inner(body)
        self.assertEqual(leaked, ("", ""))
        self.assertEqual(len(result.errors), 1)
        report = result.errors[0][1]
        self.assertIn("RuntimeError: boom", report)
        self.assertIn("Stdout:\ndrainer: Closing linked issue acme/widgets#99\n", report)

    def test_a_test_that_wrote_nothing_gets_no_empty_section(self):
        result, _leaked = self.run_inner(lambda case: case.fail("plain"))
        self.assertNotIn("Stdout:", result.failures[0][1])
        self.assertNotIn("Stderr:", result.failures[0][1])

    def test_a_report_gets_only_its_own_tests_output(self):
        # Two tests in one result: the first fails noisily, the second passes
        # noisily. The second's output must not be attached to the first's report.
        result = unittest.TestResult()
        first = inner_case(lambda case: (print("first test log"), case.fail("one")))
        second = inner_case(lambda case: print("second test log"))
        first.run(result)
        second.run(result)
        self.assertEqual(len(result.failures), 1)
        self.assertIn("first test log", result.failures[0][1])
        self.assertNotIn("second test log", result.failures[0][1])

    def test_output_written_by_a_cleanup_is_captured_too(self):
        result, leaked = self.run_inner(
            lambda case: None, cleanup=lambda: print("cleanup log line")
        )
        self.assertTrue(result.wasSuccessful())
        self.assertEqual(leaked, ("", ""))

    def test_a_leak_diagnostic_reaches_the_real_stream(self):
        # The diagnostic of a leak is what CI's guard reads, and it often
        # arrives from a finalizer during a test that did nothing wrong.
        def body(case):
            sys.stderr.write("x.py:1: ResourceWarning: unclosed file <_io.FileIO>\n")
            sys.stderr.write("Exception ignored in: <finalizer>\n")
            print("an ordinary log line", file=sys.stderr)

        result, leaked = self.run_inner(body)
        self.assertTrue(result.wasSuccessful())
        self.assertIn("ResourceWarning: unclosed file", leaked[1])
        self.assertIn("Exception ignored in", leaked[1])
        self.assertNotIn("ordinary log line", leaked[1])
        self.assertEqual(leaked[0], "")

    def test_a_real_unclosed_file_is_detectable_through_the_capture(self):
        import gc
        import warnings

        def body(case):
            with warnings.catch_warnings():
                warnings.simplefilter("always", ResourceWarning)
                handle = open(__file__, "rb")
                del handle
                gc.collect()

        _result, leaked = self.run_inner(body)
        self.assertTrue(check_resource_warnings.leak_lines(leaked[1]), leaked[1])

    def test_the_streams_are_restored_when_the_test_errors(self):
        # run_inner asserts both streams are the ones it installed afterwards.
        self.run_inner(lambda case: (_ for _ in ()).throw(KeyError("gone")))

    def test_installing_twice_wraps_once(self):
        wrapped = unittest.TestCase.run
        captured_output.install()
        self.assertIs(unittest.TestCase.run, wrapped)

    def test_the_captured_stream_still_names_a_real_descriptor(self):
        real = io.TextIOWrapper(io.BytesIO())
        stream = captured_output._CapturedStream(real, forward_leaks=False)
        with self.assertRaises(io.UnsupportedOperation):
            stream.fileno()
        self.assertFalse(stream.isatty())


class LeakGuardTests(unittest.TestCase):
    def test_a_clean_run_has_no_leak_lines(self):
        text = "..........\n----\nRan 10 tests in 0.1s\n\nOK\n"
        self.assertEqual(check_resource_warnings.leak_lines(text), [])

    def test_both_kinds_of_finalizer_report_are_leaks(self):
        text = (
            "f.py:3: ResourceWarning: unclosed file <_io.TextIOWrapper name='x'>\n"
            "Exception ignored in: <function X.__del__>\n"
        )
        self.assertEqual(len(check_resource_warnings.leak_lines(text)), 2)


if __name__ == "__main__":
    unittest.main()
