#!/usr/bin/env python3
"""CLI contract tests. Temporary reports only; never touches pairing or real diagnostics."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ENTRY = Path(__file__).with_name("client_diag.py")


class DiagnosticsContractTests(unittest.TestCase):
    def call(self, *args):
        result = subprocess.run([sys.executable, str(ENTRY), *args], stdin=subprocess.DEVNULL,
                                text=True, capture_output=True, timeout=5)
        self.assertEqual(result.stderr, "")
        return result.returncode, json.loads(result.stdout)

    def report(self, directory, name="one", **changes):
        data = {"schemaVersion": 1, "clientRun": name, "processID": os.getpid(), "platform": "macOS",
                "version": "0.3.8", "build": "1", "updatedAt": time.time(),
                "state": {"connection": "ready", "dataAttached": True},
                "totalEvents": 3, "events": [{"sequence": i, "event": "raceWon"} for i in range(3)]}
        data.update(changes)
        Path(directory, f"client-{name}.json").write_text(json.dumps(data))

    def testDescribeOfflineAndUsageErrorsAreJson(self):
        code, result = self.call("describe")
        self.assertEqual(code, 0)
        self.assertEqual(result["data"]["risk"], "read")
        code, result = self.call("events")
        self.assertEqual(code, 2)
        self.assertEqual(result["error"]["code"], "usage")

    def testMissingEvidenceIsNotHealthy(self):
        with tempfile.TemporaryDirectory() as root:
            code, result = self.call("--directory", root, "status")
            self.assertEqual(code, 3)
            self.assertFalse(result["ok"])

    def testStatusAndEventsAreReadOnlyAndBounded(self):
        with tempfile.TemporaryDirectory() as root:
            self.report(root)
            path = Path(root, "client-one.json")
            before = (path.read_bytes(), path.stat().st_mtime_ns)
            code, result = self.call("--directory", root, "status")
            self.assertEqual(code, 0)
            self.assertTrue(result["data"]["clients"][0]["fresh"])
            code, result = self.call("--directory", root, "events", "--run", "one", "--limit", "1")
            self.assertEqual(code, 0)
            self.assertEqual(len(result["data"]["events"]), 1)
            self.assertTrue(result["meta"]["truncated"])
            self.assertEqual(before, (path.read_bytes(), path.stat().st_mtime_ns))
            code, result = self.call("--directory", root, "events", "--run", "../one")
            self.assertEqual(code, 3)
            self.assertEqual(result["error"]["code"], "run_not_found")
            code, _ = self.call("--directory", root, "events", "--run", "one", "--limit", "129")
            self.assertEqual(code, 2)

    def testActiveFilterPreservesCoverageAndLeavesPhonePidsUnknown(self):
        with tempfile.TemporaryDirectory() as root:
            self.report(root, "live")
            self.report(root, "old", updatedAt=time.time() - 60)
            self.report(root, "phone", platform="iOS")
            code, result = self.call("--directory", root, "status", "--active")
            self.assertEqual(code, 0)
            self.assertEqual([r["clientRun"] for r in result["data"]["clients"]], ["live"])
            self.assertEqual(result["meta"]["validReports"], 3)
            self.assertEqual(result["meta"]["omittedReports"], 2)
            self.assertFalse(result["meta"]["partial"])

    def testVerificationRejectsStalePhoneAndDegradedEvidence(self):
        with tempfile.TemporaryDirectory() as root:
            for changes in ({"updatedAt": time.time() - 60}, {"platform": "iOS"}, {"version": "0.3.7"},
                            {"state": {"connection": "ready", "dataAttached": False}},
                            {"processID": 99999999}):
                self.report(root, **changes)
                code, result = self.call("--directory", root, "verify")
                self.assertEqual(code, 1)
                self.assertEqual(result["error"]["code"], "not_verified")
            self.report(root)
            code, result = self.call("--directory", root, "verify")
            self.assertEqual(code, 0)
            Path(root, "client-bad.json").write_text("invalid")
            code, result = self.call("--directory", root, "status")
            self.assertEqual(code, 0)
            self.assertTrue(result["meta"]["partial"])
            code, _ = self.call("--directory", root, "verify")
            self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
