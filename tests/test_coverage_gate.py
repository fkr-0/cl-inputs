"""Negative and denominator regression tests for the published coverage gate."""
import tempfile
import unittest
from pathlib import Path

from coverage_gate import measure


class CoverageGateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "src/input").mkdir(parents=True)
        (self.root / "src/terminal").mkdir(parents=True)
        (self.root / "src/input/core.lisp").write_text("(defun x () t)\n")
        (self.root / "src/input/events-adapter.lisp").write_text("(defun optional () nil)\n")
        (self.root / "src/input/package.lisp").write_text("(in-package :cl-user)\n")
        self.lcov = self.root / "coverage.info"

    def record(self, source, lines):
        return f"SF:{self.root / source}\n" + "".join(
            f"DA:{line},{count}\n" for line, count in lines
        ) + "end_of_record\n"

    def test_coverage_denominator_and_exclusion(self):
        self.lcov.write_text(
            self.record("src/input/core.lisp", [(1, 1), (2, 0)])
            + self.record("src/input/events-adapter.lisp", [(1, 0)]))
        outcome = measure(self.lcov, self.root)
        self.assertEqual((1, 2), (outcome["covered_lines"], outcome["instrumented_lines"]))
        self.assertEqual(["src/input/events-adapter.lisp", "src/input/package.lisp"], outcome["excluded_files"])

    def test_duplicate_das_do_not_inflate_denominator(self):
        self.lcov.write_text(
            self.record("src/input/core.lisp", [(1, 0), (1, 3)]))
        self.assertEqual((1, 1), (measure(self.lcov, self.root)["covered_lines"],
                                  measure(self.lcov, self.root)["instrumented_lines"]))

    def test_missing_owned_file_is_hard_error(self):
        (self.root / "src/terminal/term.lisp").write_text("(defun term () t)\n")
        self.lcov.write_text(self.record("src/input/core.lisp", [(1, 1)]))
        with self.assertRaisesRegex(ValueError, "term.lisp"):
            measure(self.lcov, self.root)

    def test_zero_denominator_is_hard_error(self):
        self.lcov.write_text(self.record("src/input/core.lisp", []))
        with self.assertRaisesRegex(ValueError, "No instrumented"):
            measure(self.lcov, self.root)

    def test_malformed_da_is_hard_error(self):
        self.lcov.write_text(f"SF:{self.root / 'src/input/core.lisp'}\nDA:1,cat\nend_of_record\n")
        with self.assertRaisesRegex(ValueError, "Malformed DA"):
            measure(self.lcov, self.root)


if __name__ == "__main__":
    unittest.main()
