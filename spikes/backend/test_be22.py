"""Safety and capture checks; all child commands are synthetic, never Cursor."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import be22


class SpikeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="kaban-be22-test-")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.work = root / "work"
        self.work.mkdir()
        (self.work / "run-home").mkdir()
        (self.work / "clone").mkdir()
        be22.save(self.work / "state.json", {"cli": sys.executable, "userHome": "/fake/user",
                   "evidence": str(root / "evidence"), "starts": []})
        self.spike = be22.Spike(self.work)

    def test_two_starts_survive_reopen_and_no_implicit_retry(self):
        self.assertEqual(be22.claim_start(self.spike, "normal"), 1)
        reopened = be22.Spike(self.work)
        with self.assertRaises(ValueError):
            be22.claim_start(reopened, "normal")
        with self.assertRaises(ValueError):
            be22.claim_start(reopened, "resume")
        self.assertEqual(be22.claim_start(reopened, "retry-first"), 2)
        with self.assertRaises(ValueError):
            be22.claim_start(be22.Spike(self.work), "retry-first")

    def test_resume_requires_successful_first_session(self):
        be22.claim_start(self.spike, "normal")
        self.spike.state.update(sessionId="session-fixture", firstComplete=True)
        self.assertEqual(be22.claim_start(self.spike, "resume"), 2)

    def test_redaction_before_evidence_write(self):
        secret = self.spike.token
        self.spike.write("capture.json", {"message": secret + " /fake/user/config",
                           "authorization": "Bearer " + secret, "email": "person@example.com"})
        text = (self.spike.evidence / "capture.json").read_text()
        self.assertNotIn(secret, text)
        self.assertNotIn("person@example.com", text)
        self.assertNotIn("/fake/user", text)
        json.loads(text)

    def test_status_does_not_persist_account_or_token(self):
        script = self.work / "fake-cli"
        script.write_text("#!" + sys.executable + "\nimport json\nprint(json.dumps(" + repr({
            "isAuthenticated": True, "hasAccessToken": True, "userInfo": {"name": "PRIVATE ACCOUNT"},
            "accessToken": "PRIVATE SECRET"}) + "))\n")
        script.chmod(0o755)
        self.spike.state["cli"] = str(script)
        rc, out = self.spike.free_command("status", ["status"], status=True)
        self.assertEqual(rc, 0)
        self.assertTrue(json.loads(out)["isAuthenticated"])
        self.assertNotIn("PRIVATE", (self.spike.evidence / "status.stdout").read_text())

    def test_capture_kills_process_tree_at_init_and_keeps_stream(self):
        sentinel = self.work / "survivor"
        child = "import time;from pathlib import Path;time.sleep(.6);Path(%r).touch()" % str(sentinel)
        code = ("import subprocess,sys,time,json;"
                "subprocess.Popen([sys.executable,'-c',%r]);" % child +
                "print(json.dumps({'type':'system','subtype':'init','model':%r," % be22.MODEL_NAME +
                "'session_id':'fixture-session'}),flush=True);time.sleep(10)")
        facts = be22.capture(self.spike, [sys.executable, "-c", code], "run", True, trace=False, timeout=3)
        self.assertTrue(facts["initSeen"])
        self.assertTrue(facts["killRequested"])
        self.assertEqual(facts["toolsSeen"], 0)
        self.assertNotEqual(facts["exit"], 0)
        time.sleep(.7)
        self.assertFalse(sentinel.exists())
        summary = json.loads((self.spike.evidence / "run/summary.json").read_text())
        self.assertEqual(summary["init"]["session_id"], "fixture-session")

    def test_tool_before_init_does_not_claim_init_was_seen(self):
        code = "import time;print('{\"type\":\"tool_call\",\"subtype\":\"started\"}',flush=True);time.sleep(10)"
        facts = be22.capture(self.spike, [sys.executable, "-c", code], "run", True, trace=False, timeout=3)
        self.assertFalse(facts["initSeen"])
        self.assertEqual(facts["toolsSeen"], 1)
        self.assertTrue(facts["killRequested"])

    def test_capture_records_exit_and_redacts_both_pipes(self):
        code = ("import sys;print(%r);print(%r,file=sys.stderr);sys.exit(7)" %
                (json.dumps({"type": "result", "result": self.spike.token}), self.spike.token))
        facts = be22.capture(self.spike, [sys.executable, "-c", code], "run", False, trace=False, timeout=3)
        self.assertEqual(facts["exit"], 7)
        for path in (self.spike.evidence / "run").iterdir():
            self.assertNotIn(self.spike.token, path.read_text())

    def test_failed_auth_does_not_spend_budget_or_request_sudo(self):
        self.spike.write("environment/version.stdout", "fixture-version\n")
        with patch.object(self.spike, "free_command", side_effect=[
                (0, "fixture-version\n"), (0, '{"isAuthenticated":false}')]), \
                patch.object(be22.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "not authenticated"):
                be22.paid(self.spike, "normal")
            run.assert_not_called()
        self.assertEqual(be22.Spike(self.work).state["starts"], [])

    def test_observer_failure_keeps_gate_closed(self):
        from contextlib import contextmanager

        @contextmanager
        def unavailable(*_):
            raise ValueError("observer unavailable")
            yield

        sentinel = self.work / "must-not-start"
        code = "from pathlib import Path;Path(%r).touch()" % str(sentinel)
        with patch.object(be22, "fs_trace", unavailable):
            with self.assertRaisesRegex(ValueError, "observer unavailable"):
                be22.capture(self.spike, [sys.executable, "-c", code], "run", False, trace=True)
        self.assertFalse(sentinel.exists())

    def test_metadata_observer_records_changes_without_following_links(self):
        private = self.work / "credential-fixture"
        private.mkdir()
        credential = private / "secret.txt"
        credential.write_text("SECRET VALUE MUST NEVER BE READ")
        (self.spike.home / "Keychains").symlink_to(private, target_is_directory=True)
        with be22.metadata_trace(self.spike, "metadata"):
            (self.spike.repo / "new.txt").write_text("new")
            credential.write_text("CHANGED PRIVATE VALUE")
        data = (self.spike.evidence / "metadata/filesystem-changes.json").read_text()
        self.assertIn("new.txt", data)
        self.assertNotIn("secret.txt", data)
        self.assertNotIn("PRIVATE VALUE", data)

    def test_summary_understands_real_tool_envelope_metadata(self):
        fixture = Path(__file__).resolve().parents[2] / "research/spike-1-2026-10-28/run-1/stream.jsonl"
        events = [json.loads(line) for line in fixture.read_text().splitlines()]
        tools = [be22.kspike.tool_info(event) for event in events if event.get("type") == "tool_call"]
        self.assertEqual(sum(tool["kind"] == "mcpToolCall" for tool in tools), 4)
        self.assertEqual(sum(tool["kind"] == "shellToolCall" for tool in tools), 2)
        self.assertTrue(all(tool["kind"].endswith("ToolCall") for tool in tools))


if __name__ == "__main__":
    unittest.main()
