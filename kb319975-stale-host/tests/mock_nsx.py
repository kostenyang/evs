#!/usr/bin/env python3
"""Minimal NSX Manager API mock for exercising kb319975_stale_host.py offline.

Run it by hand:

    python tests/mock_nsx.py --scenario rebuilt_host_nsx91 --port 8443
    python kb319975_stale_host.py -n http://127.0.0.1:8443 -p x scan esx04.corp.local

or let tests/test_scan.py start it on an ephemeral port.

Scenarios (what the scan should conclude):

  rebuilt_host_nsx91  NSX 9.1.1, host reinstalled and re-added to vCenter: APIs hold
                      only the new DiscoveredNode, the search index still carries the
                      old TransportNode (UI shows "Orphaned"), /api/v1/fabric/nodes
                      answers HTTP 500. -> KB option 2 (search resync). Mirrors a
                      real customer run, see README.
  discovered_only     New host in vCenter, never prepared, index consistent.
                      -> nothing to clean, apply the TNP.
  fabric_left         NSX 4.x, transport node deleted but HostNode fabric node stays.
                      -> KB option 1.
  live_tn             Healthy transport node, state=success. -> option 3 + WARNING.
  clean               No trace anywhere. -> exit 0.
"""

from __future__ import annotations

import argparse
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

HOST = "esx04.corp.local"
HOST_IP = "10.0.1.14"
VC_UUID = "0a50fae7-eed0-4ed5-9737-386f0a3279a9"
NEW_MOREF = f"{VC_UUID}:host-2695889"
OLD_TN_ID = "75dd5cc8-8b9b-4c72-9c67-c25f7cddee49"
LIVE_TN_ID = "11111111-2222-3333-4444-555555555555"
POLICY_HTN = ("/policy/api/v1/infra/sites/default/enforcement-points/default"
              "/host-transport-nodes")


def discovered_node():
    return {"resource_type": "DiscoveredNode", "external_id": NEW_MOREF, "id": NEW_MOREF,
            "display_name": HOST, "ip_addresses": [HOST_IP], "os_type": "ESXI",
            "origin_id": "cm-1"}


def transport_node(tn_id):
    return {"resource_type": "TransportNode", "id": tn_id, "display_name": HOST,
            "node_deployment_info": {"resource_type": "HostNode", "id": tn_id,
                                     "display_name": HOST, "fqdn": HOST,
                                     "ip_addresses": [HOST_IP]}}


def fabric_node(tn_id):
    return {"resource_type": "HostNode", "id": tn_id, "display_name": HOST,
            "fqdn": HOST, "ip_addresses": [HOST_IP], "os_type": "ESXI"}


def index_entry(resource_type, ident):
    return {"resource_type": resource_type, "id": ident, "display_name": HOST,
            "ip_addresses": [HOST_IP]}


SCENARIOS = {
    "rebuilt_host_nsx91": {
        "version": "9.1.1.0.25991516",
        "fabric_nodes": "HTTP500",
        "transport_nodes": [],
        "discovered_nodes": [discovered_node()],
        "policy_htn": [],
        "search": [index_entry("DiscoveredNode", NEW_MOREF),
                   index_entry("TransportNode", OLD_TN_ID)],
        "tn_states": {},
    },
    "discovered_only": {
        "version": "9.1.1.0.25991516",
        "fabric_nodes": "HTTP500",
        "transport_nodes": [],
        "discovered_nodes": [discovered_node()],
        "policy_htn": [],
        "search": [index_entry("DiscoveredNode", NEW_MOREF)],
        "tn_states": {},
    },
    "fabric_left": {
        "version": "4.2.1.0.24304122",
        "fabric_nodes": [fabric_node(OLD_TN_ID)],
        "transport_nodes": [],
        "discovered_nodes": [],
        "policy_htn": [],
        "search": [index_entry("HostNode", OLD_TN_ID)],
        "tn_states": {},
    },
    "live_tn": {
        "version": "9.1.1.0.25991516",
        "fabric_nodes": "HTTP500",
        "transport_nodes": [transport_node(LIVE_TN_ID)],
        "discovered_nodes": [discovered_node()],
        "policy_htn": [{"resource_type": "HostTransportNode", "id": LIVE_TN_ID,
                        "display_name": HOST,
                        "node_deployment_info": {"ip_addresses": [HOST_IP]}}],
        "search": [index_entry("TransportNode", LIVE_TN_ID),
                   index_entry("DiscoveredNode", NEW_MOREF)],
        "tn_states": {LIVE_TN_ID: {"state": "success"}},
    },
    "clean": {
        "version": "9.1.1.0.25991516",
        "fabric_nodes": "HTTP500",
        "transport_nodes": [],
        "discovered_nodes": [],
        "policy_htn": [],
        "search": [],
        "tn_states": {},
    },
}


class Handler(BaseHTTPRequestHandler):
    scenario: dict = SCENARIOS["clean"]
    requests_seen: list[str] = []

    def log_message(self, *_):  # keep the test output quiet
        pass

    def _send(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _list(self, items):
        self._send(200, {"results": items, "result_count": len(items)})

    def _not_found(self, ident):
        self._send(404, {"httpStatus": "NOT_FOUND", "error_code": 600,
                         "module_name": "common-services",
                         "error_message": f"The requested object : {ident} could not be "
                                          "found. Object identifiers are case sensitive."})

    def do_GET(self):
        sc = self.scenario
        path = urlparse(self.path).path
        Handler.requests_seen.append(f"GET {self.path}")
        if path == "/api/v1/node":
            return self._send(200, {"node_version": sc["version"]})
        if path == "/api/v1/transport-nodes":
            return self._list(sc["transport_nodes"])
        if path == "/api/v1/fabric/nodes":
            if sc["fabric_nodes"] == "HTTP500":
                return self._send(500, {"error_code": 500,
                                        "error_message": "Internal server error"})
            return self._list(sc["fabric_nodes"])
        if path == "/api/v1/fabric/discovered-nodes":
            return self._list(sc["discovered_nodes"])
        if path == POLICY_HTN:
            return self._list(sc["policy_htn"])
        if path == "/api/v1/search/query":
            return self._list(sc["search"])
        if path == "/api/v1/cluster/nodes/status":
            return self._send(200, {"mgmt_cluster_status": {"members": [
                {"ip_address": "192.0.2.11"}, {"ip_address": "192.0.2.12"},
                {"ip_address": "192.0.2.13"}]}})
        for prefix in ("/api/v1/transport-nodes/", POLICY_HTN + "/"):
            if path.startswith(prefix) and path.endswith("/state"):
                ident = path[len(prefix):-len("/state")]
                st = sc["tn_states"].get(ident)
                return self._send(200, st) if st else self._not_found(ident)
        self._not_found(path)

    def do_DELETE(self):
        path = urlparse(self.path).path
        Handler.requests_seen.append(f"DELETE {self.path}")
        ident = path.rsplit("/", 1)[-1]
        sc = self.scenario
        sc["tn_states"].pop(ident, None)
        sc["transport_nodes"] = [t for t in sc["transport_nodes"] if t["id"] != ident]
        sc["policy_htn"] = [t for t in sc["policy_htn"] if t["id"] != ident]
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()


def start(scenario: str, port: int = 0):
    """Start the mock in a daemon thread; returns (server, base_url)."""
    Handler.scenario = json.loads(json.dumps(SCENARIOS[scenario]))  # deep copy
    Handler.requests_seen = []
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_address[1]}"


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scenario", choices=sorted(SCENARIOS), default="rebuilt_host_nsx91")
    ap.add_argument("--port", type=int, default=8443)
    args = ap.parse_args(argv)
    srv, base = start(args.scenario, args.port)
    print(f"mock NSX ({args.scenario}) listening on {base}  -- Ctrl-C to stop")
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        srv.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
