#!/usr/bin/env python3
"""Offline tests for kb319975_stale_host.py against tests/mock_nsx.py.

    python tests/test_scan.py          (from kb319975-stale-host/)
    python -m unittest tests.test_scan
"""

from __future__ import annotations

import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCRIPT = os.path.join(ROOT, "kb319975_stale_host.py")
sys.path.insert(0, HERE)
import mock_nsx  # noqa: E402


def run(scenario: str, *cli: str):
    srv, base = mock_nsx.start(scenario)
    try:
        cmd = [sys.executable, SCRIPT, "-n", base, "-p", "x", "--no-log-file", *cli]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120,
                              cwd=ROOT)
    finally:
        srv.shutdown()
        srv.server_close()
    return proc.returncode, proc.stdout + proc.stderr, list(mock_nsx.Handler.requests_seen)


class ScanTests(unittest.TestCase):

    def test_rebuilt_host_nsx91_is_option_2_only(self):
        """The real customer case: old TN only in the index, new DiscoveredNode live."""
        rc, out, _ = run("rebuilt_host_nsx91", "scan", mock_nsx.HOST)
        self.assertEqual(rc, 2, out)
        self.assertIn("fabric/nodes unavailable on this version (HTTP 500)", out)
        self.assertIn("transport_nodes (0)", out)
        self.assertIn("discovered_nodes (1)", out)
        self.assertIn("search_index (2)", out)
        # index classification
        self.assertRegex(out, r"Search index \(DiscoveredNode\).*mirrors a live API object")
        self.assertRegex(out, r"Search index \(TransportNode\).*STALE \(no API object")
        # recommendations
        self.assertIn("KB option 2", out)
        self.assertIn(mock_nsx.OLD_TN_ID, out)
        self.assertNotIn("KB option 1", out)
        self.assertNotIn("KB option 3", out)
        self.assertIn("not a leftover", out)

    def test_discovered_only_is_not_stale(self):
        rc, out, _ = run("discovered_only", "scan", mock_nsx.HOST)
        self.assertEqual(rc, 2, out)
        self.assertIn("NOT a stale entry", out)
        for opt in ("KB option 1", "KB option 2", "KB option 3", "KB option 4",
                    "KB option 5"):
            self.assertNotIn(opt, out)

    def test_fabric_left_is_option_1(self):
        rc, out, _ = run("fabric_left", "scan", mock_nsx.HOST)
        self.assertEqual(rc, 2, out)
        self.assertIn("fabric_nodes (1)", out)
        self.assertIn("KB option 1", out)
        self.assertNotIn("KB option 2", out)   # index entry mirrors the fabric node
        self.assertRegex(out, r"Search index \(HostNode\).*mirrors a live API object")

    def test_live_tn_warns(self):
        rc, out, _ = run("live_tn", "scan", mock_nsx.HOST)
        self.assertEqual(rc, 2, out)
        self.assertIn("KB option 3", out)
        self.assertIn("KB option 4", out)
        self.assertIn("WARNING", out)
        self.assertNotIn("KB option 2", out)
        self.assertNotIn("STALE", out)

    def test_clean_exits_0(self):
        rc, out, _ = run("clean", "scan", mock_nsx.HOST)
        self.assertEqual(rc, 0, out)
        self.assertIn("No trace of this host", out)

    def test_matches_by_ip_and_short_name(self):
        for target in (mock_nsx.HOST_IP, mock_nsx.HOST.split(".")[0]):
            rc, out, _ = run("rebuilt_host_nsx91", "scan", target)
            self.assertEqual(rc, 2, out)
            self.assertIn("search_index (2)", out)

    def test_state_by_id_object_not_found(self):
        rc, out, reqs = run("rebuilt_host_nsx91", "state", "--id", mock_nsx.OLD_TN_ID)
        self.assertEqual(rc, 0, out)
        self.assertIn("OBJECT NOT FOUND (clean)", out)
        self.assertTrue(any(f"/api/v1/transport-nodes/{mock_nsx.OLD_TN_ID}/state" in r
                            for r in reqs), reqs)

    def test_state_by_id_policy_api(self):
        rc, out, _ = run("rebuilt_host_nsx91", "state", "--api", "policy",
                         "--id", mock_nsx.OLD_TN_ID)
        self.assertEqual(rc, 0, out)
        self.assertIn("OBJECT NOT FOUND (clean)", out)

    def test_delete_dry_run_touches_nothing(self):
        rc, out, reqs = run("live_tn", "delete", "--force-anyway", mock_nsx.HOST)
        self.assertFalse(any(r.startswith("DELETE") for r in reqs), reqs)
        self.assertEqual(rc, 0, out)

    def test_delete_refuses_live_tn_without_force_anyway(self):
        rc, out, reqs = run("live_tn", "delete", "--yes", "--no-confirm", mock_nsx.HOST)
        self.assertEqual(rc, 1, out)
        self.assertFalse(any(r.startswith("DELETE") for r in reqs), reqs)

    def test_delete_force_anyway_polls_until_gone(self):
        rc, out, reqs = run("live_tn", "delete", "--yes", "--no-confirm", "--force-anyway",
                            "--poll-interval", "1", "--poll-timeout", "30", mock_nsx.HOST)
        self.assertEqual(rc, 0, out)
        dels = [r for r in reqs if r.startswith("DELETE")]
        self.assertTrue(dels, reqs)
        for d in dels:
            self.assertIn("force=true", d)
            self.assertIn("unprepare_host=false", d)
        self.assertIn("OBJECT NOT FOUND", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
