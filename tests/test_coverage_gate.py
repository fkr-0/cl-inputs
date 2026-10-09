"""Negative and denominator regression tests for the published coverage gate."""
import tempfile
import unittest
import json
import subprocess
import sys
from pathlib import Path

from coverage_gate import measure


class CoverageGateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "src/input").mkdir(parents=True)
        (self.root / "src/terminal").mkdir(parents=True)
        (self.root / "src/input/core.lisp").write_text(
            "(defun x () t)\n(defun y () nil)\n")
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

    def test_negative_hit_count_is_hard_error(self):
        self.lcov.write_text(self.record("src/input/core.lisp", [(1, -1)]))
        with self.assertRaisesRegex(ValueError, "Invalid DA"):
            measure(self.lcov, self.root)

    def test_zero_or_negative_line_number_is_hard_error(self):
        for lineno in (0, -1):
            with self.subTest(lineno=lineno):
                self.lcov.write_text(self.record("src/input/core.lisp", [(lineno, 1)]))
                with self.assertRaisesRegex(ValueError, "Invalid DA"):
                    measure(self.lcov, self.root)

    def test_lcov_line_beyond_actual_source_is_hard_error(self):
        self.lcov.write_text(self.record("src/input/core.lisp", [(999, 1)]))
        with self.assertRaisesRegex(ValueError, "exceeds"):
            measure(self.lcov, self.root)

    def test_unterminated_record_is_hard_error(self):
        self.lcov.write_text(f"SF:{self.root / 'src/input/core.lisp'}\nDA:1,1\n")
        with self.assertRaisesRegex(ValueError, "Unterminated"):
            measure(self.lcov, self.root)

    def test_unpaired_end_record_is_hard_error(self):
        self.lcov.write_text("end_of_record\n" + self.record("src/input/core.lisp", [(1, 1)]))
        with self.assertRaisesRegex(ValueError, "without SF"):
            measure(self.lcov, self.root)

    def test_nested_source_record_is_hard_error(self):
        self.lcov.write_text(
            f"SF:{self.root / 'src/input/core.lisp'}\n"
            f"SF:{self.root / 'src/input/core.lisp'}\nDA:1,1\nend_of_record\n")
        with self.assertRaisesRegex(ValueError, "Nested SF"):
            measure(self.lcov, self.root)

    def test_external_files_and_optional_adapter_do_not_inflate_denominator(self):
        self.lcov.write_text(
            self.record("src/input/core.lisp", [(1, 0), (2, 1)])
            + self.record("src/input/events-adapter.lisp", [(1, 1)])
            + f"SF:{self.root / 'tests/a-test.lisp'}\nDA:1,1\nend_of_record\n")
        outcome = measure(self.lcov, self.root)
        self.assertEqual((1, 2),
                         (outcome["covered_lines"], outcome["instrumented_lines"]))
        self.assertEqual(["src/input/core.lisp"], list(outcome["per_file"]))

    def test_cli_fails_threshold_and_emits_red_evidence(self):
        self.lcov.write_text(self.record("src/input/core.lisp", [(1, 1), (2, 0)]))
        report = self.root / "measure.json"
        badge = self.root / "badge.json"
        command = [sys.executable, str(Path(__file__).with_name("coverage_gate.py")),
                   str(self.lcov), "--root", str(self.root), "--min", "85",
                   "--out", str(report), "--badge", str(badge)]
        rejected = subprocess.run(command, check=False, capture_output=True, text=True)
        self.assertEqual(1, rejected.returncode, rejected.stdout + rejected.stderr)
        self.assertEqual((1, 2), (json.loads(report.read_text())["covered_lines"],
                                  json.loads(report.read_text())["instrumented_lines"]))
        self.assertEqual("red", json.loads(badge.read_text())["color"])
        self.assertEqual("50.00%", json.loads(badge.read_text())["message"])

    def test_cli_passes_real_covered_denominator(self):
        self.lcov.write_text(self.record("src/input/core.lisp", [(1, 1), (2, 1)]))
        badge = self.root / "badge.json"
        passed = subprocess.run(
            [sys.executable, str(Path(__file__).with_name("coverage_gate.py")),
             str(self.lcov), "--root", str(self.root), "--min", "85",
             "--out", str(self.root / "measure.json"), "--badge", str(badge)],
            check=False, capture_output=True, text=True)
        self.assertEqual(0, passed.returncode, passed.stdout + passed.stderr)
        self.assertEqual("brightgreen", json.loads(badge.read_text())["color"])
        self.assertEqual("100.00%", json.loads(badge.read_text())["message"])


if __name__ == "__main__":
    unittest.main()
