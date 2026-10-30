#!/usr/bin/env python3
"""Check FE-22 evidence failure handling without Swift, GUI or Cursor."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("acceptance", Path(__file__).with_name("check-frontend-acceptance.py"))
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)


class EvidenceTests(unittest.TestCase):
    def test_exit_report_and_capture_must_all_succeed(self):
        with tempfile.TemporaryDirectory() as directory:
            report, png = Path(directory) / "result.json", Path(directory) / "window.png"
            self.assertEqual(acceptance.validate_result(0, False, report), "failed")
            report.write_text("not json")
            self.assertEqual(acceptance.validate_result(0, False, report), "failed")
            report.write_text(json.dumps({"result": "functional_passed_popup_unverified"}))
            self.assertEqual(acceptance.validate_result(0, False, report), "failed")
            report.write_text(json.dumps({"result": "passed"}))
            self.assertEqual(acceptance.validate_result(1, False, report), "failed")
            self.assertEqual(acceptance.validate_result(0, True, report), "timed_out")
            self.assertEqual(acceptance.validate_result(0, False, report, png), "failed")
            png.write_bytes(b"\x89PNG\r\n\x1a\n")
            self.assertEqual(acceptance.validate_result(0, False, report, png), "passed")

    def test_failure_is_durable_and_later_success_does_not_hide_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            qa = acceptance.Acceptance(root, {})
            self.assertTrue(qa.run("ok", [sys.executable, "-c", "pass"], "test"))
            self.assertEqual(json.loads((root / "summary.json").read_text())["result"], "running")
            self.assertFalse(qa.run("failed", [sys.executable, "-c", "raise SystemExit(3)"], "test"))
            self.assertTrue(qa.run("later", [sys.executable, "-c", "pass"], "test"))
            qa.data["finishedUnix"] = 1
            qa.save()
            saved = json.loads((root / "summary.json").read_text())
            self.assertEqual(saved["result"], "automated_failed_live_unverified")
            self.assertEqual(saved["steps"][1]["exitCode"], 3)
            self.assertEqual(saved["liveAcceptance"], "unverified")

    def test_timeout_is_saved_and_success_remains_partial(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            qa = acceptance.Acceptance(root, {})
            self.assertFalse(qa.run("timeout", [sys.executable, "-c", "import time; time.sleep(10)"], "test", timeout=0.05))
            self.assertEqual(qa.data["steps"][0]["result"], "timed_out")
        with tempfile.TemporaryDirectory() as directory:
            qa = acceptance.Acceptance(Path(directory), {})
            qa.run("ok", [sys.executable, "-c", "pass"], "test")
            qa.data["finishedUnix"] = 1
            qa.save()
            self.assertEqual(qa.data["result"], "automated_passed_live_unverified")
            self.assertEqual(qa.data["visualInspection"], "manual_required")

    def test_missing_executable_is_a_recorded_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            qa = acceptance.Acceptance(Path(directory), {})
            self.assertFalse(qa.run("missing", [str(Path(directory) / "missing")], "test"))
            self.assertEqual(qa.data["steps"][0]["exitCode"], 127)
            self.assertIn("launchError", qa.data["steps"][0])


if __name__ == "__main__":
    unittest.main()
