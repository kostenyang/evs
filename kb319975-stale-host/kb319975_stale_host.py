#!/usr/bin/env python3
"""KB 319975 - NSX host install / upgrade failures caused by stale host entries.

https://knowledge.broadcom.com/external/article/319975

When an ESXi host is removed from vCenter without first removing NSX, entries for
that host stay behind in the NSX database (and in the NSX search index). Adding a
rebuilt host back with the same name or IP then fails with errors such as
"Node with same ip already exists", "Discovered node with id is already prepared",
or "Failed to get Host status for upgrade unit".

This script runs locally (no NSX appliance shell needed) and implements the KB's
workaround options against the NSX Manager APIs:

  scan     inventory every trace of a host: Manager API, Policy API, fabric nodes,
           discovered nodes and the search index -- and say which KB option applies
  state    KB option 3/4 step 1: read the transport-node state (Manager + Policy)
  resync   KB option 2: "start search resync policy|manager|telemetry|all" on every
           NSX Manager node over SSH, then re-scan
  delete   KB option 3/4: force delete the stale transport node
           (force=true&unprepare_host=false) and poll state until "Object not found"
  cleanup  the KB's sequential approach: scan -> [resync] -> delete -> poll -> re-scan
  report   write a JSON findings file plus the checklist Broadcom Support asks for
           (KB option 5 / database cleanup)

Nothing is deleted unless --yes is passed; every other command is read-only.

Requires: Python 3.8+ (standard library only). `resync` additionally needs paramiko,
and prints the commands to run by hand if it is not installed.
"""

from __future__ import annotations

import argparse
import base64
import getpass
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

KB_URL = "https://knowledge.broadcom.com/external/article/319975"
KB_FIXED_IN = "NSX 4.2.3 and 9.0.1"

POLICY_HTN = ("/policy/api/v1/infra/sites/{site}/enforcement-points/{ep}"
              "/host-transport-nodes")

NOT_FOUND_RE = re.compile(r"object\s*not\s*found|could not be found|does not exist",
                          re.IGNORECASE)


# --------------------------------------------------------------------------- #
# output helpers
# --------------------------------------------------------------------------- #

class Log:
    """Console + optional file logging."""

    def __init__(self, path: str | None = None):
        self.fh = None
        if path:
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
            self.fh = open(path, "a", encoding="utf-8")
            self.path = path

    def __call__(self, msg: str = "", stderr: bool = False) -> None:
        line = f"[{datetime.now().strftime('%H:%M:%S')}] {msg}" if msg else ""
        print(line, file=sys.stderr if stderr else sys.stdout, flush=True)
        if self.fh:
            self.fh.write(line + "\n")
            self.fh.flush()

    def raw(self, msg: str) -> None:
        print(msg, flush=True)
        if self.fh:
            self.fh.write(msg + "\n")
            self.fh.flush()


def table(rows: list[dict], columns: list[tuple[str, str]], log: Log) -> None:
    """Print rows as a fixed-width table. columns = [(key, header), ...]."""
    if not rows:
        log.raw("  (none)")
        return
    widths = []
    for key, header in columns:
        widths.append(max(len(header), *(len(str(r.get(key, "") or "")) for r in rows)))
    log.raw("  " + "  ".join(h.ljust(w) for (_, h), w in zip(columns, widths)))
    log.raw("  " + "  ".join("-" * w for w in widths))
    for r in rows:
        log.raw("  " + "  ".join(str(r.get(k, "") or "").ljust(w)
                                 for (k, _), w in zip(columns, widths)))


# --------------------------------------------------------------------------- #
# NSX API client
# --------------------------------------------------------------------------- #

class ApiError(Exception):
    def __init__(self, status: int, body, url: str):
        self.status = status
        self.body = body
        self.url = url
        detail = body
        if isinstance(body, dict):
            detail = body.get("error_message") or body.get("details") or json.dumps(body)
        super().__init__(f"HTTP {status} {url}: {str(detail)[:400]}")

    @property
    def not_found(self) -> bool:
        """True when NSX says the object is gone (what the KB polls for)."""
        if self.status == 404:
            return True
        text = json.dumps(self.body) if isinstance(self.body, (dict, list)) else str(self.body)
        return bool(NOT_FOUND_RE.search(text))


class NsxClient:
    def __init__(self, host: str, user: str, password: str, *, verify: bool = True,
                 ca_bundle: str | None = None, timeout: int = 60, log: Log | None = None):
        if "://" in host:
            self.base = host.rstrip("/")
        else:
            self.base = "https://" + host.strip().rstrip("/")
        self.user = user
        self.timeout = timeout
        self.log = log or Log()
        self._auth = base64.b64encode(f"{user}:{password}".encode()).decode()
        if self.base.startswith("http://"):
            self.ctx = None
        elif verify:
            self.ctx = ssl.create_default_context(cafile=ca_bundle)
        else:
            self.ctx = ssl._create_unverified_context()

    # -- plumbing ---------------------------------------------------------- #

    def request(self, method: str, path: str, *, params: dict | None = None,
                body: dict | None = None):
        url = self.base + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", "Basic " + self._auth)
        req.add_header("Accept", "application/json")
        if data:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout, context=self.ctx) as resp:
                raw = resp.read().decode("utf-8", "replace")
                return resp.status, _maybe_json(raw)
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", "replace")
            raise ApiError(exc.code, _maybe_json(raw), url) from None
        except urllib.error.URLError as exc:
            reason = str(exc.reason)
            hint = ""
            if "CERTIFICATE_VERIFY_FAILED" in reason:
                hint = ("\n       NSX Manager uses a self-signed certificate by default -- "
                        "pass --ca-bundle <pem> or --insecure.")
            raise SystemExit(f"ERROR: cannot reach {url}: {reason}{hint}")

    def get(self, path: str, params: dict | None = None):
        return self.request("GET", path, params=params)[1]

    def get_optional(self, path: str, params: dict | None = None):
        """GET that tolerates removed/forbidden endpoints across NSX versions."""
        try:
            return self.get(path, params)
        except ApiError as exc:
            if exc.status in (400, 403, 404, 405, 500):
                self.log(f"  note: {path} unavailable on this version (HTTP {exc.status})")
                return None
            raise

    def list_all(self, path: str, params: dict | None = None) -> list[dict]:
        """Follow NSX cursor paging and return every result."""
        out: list[dict] = []
        params = dict(params or {})
        params.setdefault("page_size", 1000)
        while True:
            page = self.get_optional(path, params)
            if not page:
                break
            out.extend(page.get("results") or [])
            cursor = page.get("cursor")
            if not cursor or not page.get("results"):
                break
            params["cursor"] = cursor
        return out

    # -- typed calls ------------------------------------------------------- #

    def node_version(self) -> str:
        info = self.get_optional("/api/v1/node") or {}
        return info.get("node_version") or info.get("product_version") or "unknown"

    def manager_nodes(self) -> list[str]:
        """Management IPs of every NSX Manager node (for the SSH resync step)."""
        ips: list[str] = []
        status = self.get_optional("/api/v1/cluster/nodes/status") or {}
        for entry in (status.get("mgmt_cluster_status") or {}).get("members") or []:
            if entry.get("ip_address"):
                ips.append(entry["ip_address"])
        if not ips:
            for node in self.list_all("/api/v1/cluster/nodes"):
                addr = (node.get("appliance_mgmt_listen_addr")
                        or ((node.get("manager_role") or {})
                            .get("api_listen_addr") or {}).get("ip_address"))
                if addr:
                    ips.append(addr)
        seen, uniq = set(), []
        for ip in ips:
            if ip not in seen:
                seen.add(ip)
                uniq.append(ip)
        return uniq


def _maybe_json(raw: str):
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except ValueError:
        return raw


# --------------------------------------------------------------------------- #
# matching + discovery
# --------------------------------------------------------------------------- #

def _ips_of(obj: dict) -> list[str]:
    ndi = obj.get("node_deployment_info") or {}
    for src in (obj, ndi):
        for key in ("ip_addresses", "managed_by_server_ips"):
            if src.get(key):
                return [str(v) for v in src[key]]
    for key in ("ip_address", "managed_by_server"):
        if obj.get(key):
            return [str(obj[key])]
    return []


def _names_of(obj: dict) -> list[str]:
    ndi = obj.get("node_deployment_info") or {}
    vals = [obj.get("display_name"), obj.get("id"), obj.get("external_id"),
            obj.get("unique_id"), obj.get("node_id"), obj.get("os_type"),
            ndi.get("display_name"), ndi.get("fqdn"), ndi.get("id"),
            obj.get("fqdn")]
    return [str(v) for v in vals if v]


def matches(obj: dict, target: str) -> bool:
    """Match a NSX object against a display name, FQDN, short name, IP or UUID."""
    t = target.strip().lower()
    t_short = t.split(".")[0]
    for name in _names_of(obj):
        n = name.lower()
        if n == t or n.split(".")[0] == t_short:
            return True
    return any(ip.lower() == t for ip in _ips_of(obj))


def _finding(source: str, obj: dict, *, ident: str, api: str, state: str = "") -> dict:
    ndi = obj.get("node_deployment_info") or {}
    return {
        "source": source,
        "api": api,
        "id": ident,
        "display_name": obj.get("display_name") or ndi.get("display_name") or "",
        "ips": ",".join(_ips_of(obj)),
        "state": state,
        "path": obj.get("path") or "",
        "raw": obj,
    }


def discover(client: NsxClient, target: str, args, log: Log) -> dict:
    """Collect every trace of `target` from the Manager API, Policy API and search index."""
    log(f"scanning NSX {client.base} for '{target}' ...")
    found: dict[str, list[dict]] = {
        "transport_nodes": [], "fabric_nodes": [], "discovered_nodes": [],
        "policy_host_transport_nodes": [], "search_index": [],
    }

    for tn in client.list_all("/api/v1/transport-nodes"):
        if matches(tn, target):
            found["transport_nodes"].append(
                _finding("Manager API transport node", tn, ident=tn.get("id", ""),
                         api="manager"))

    for fn in client.list_all("/api/v1/fabric/nodes", {"resource_type": "HostNode"}):
        if matches(fn, target):
            found["fabric_nodes"].append(
                _finding("Manager API fabric node", fn, ident=fn.get("id", ""),
                         api="manager"))

    for dn in client.list_all("/api/v1/fabric/discovered-nodes"):
        if matches(dn, target):
            found["discovered_nodes"].append(
                _finding("Discovered node (vCenter)", dn,
                         ident=dn.get("external_id") or dn.get("id", ""), api="manager"))

    policy_path = POLICY_HTN.format(site=args.site, ep=args.enforcement_point)
    for htn in client.list_all(policy_path):
        if matches(htn, target):
            found["policy_host_transport_nodes"].append(
                _finding("Policy API host transport node", htn, ident=htn.get("id", ""),
                         api="policy"))

    # The search index is what the UI and SDDC Manager pre-checks read, and it is the
    # thing KB option 2 (search resync) repairs. A hit here with no hit above is the
    # textbook "stale entry only in the index" case.
    query = ("resource_type:(TransportNode OR HostNode OR DiscoveredNode OR "
             "PolicyHostTransportNode)")
    idx = client.get_optional("/api/v1/search/query",
                              {"query": query, "page_size": 1000}) or {}
    for obj in idx.get("results") or []:
        if matches(obj, target):
            found["search_index"].append(
                _finding(f"Search index ({obj.get('resource_type', '?')})", obj,
                         ident=obj.get("id") or obj.get("external_id", ""), api="search"))

    return found


def attach_states(client: NsxClient, found: dict, args) -> None:
    for item in found["transport_nodes"]:
        item["state"] = read_state(client, "manager", item["id"], args)["summary"]
    for item in found["policy_host_transport_nodes"]:
        item["state"] = read_state(client, "policy", item["id"], args)["summary"]


def read_state(client: NsxClient, api: str, ident: str, args) -> dict:
    """KB option 3/4 step 1 -- GET .../state. 'Object not found' means it is clean."""
    if api == "manager":
        path = f"/api/v1/transport-nodes/{urllib.parse.quote(ident)}/state"
    else:
        path = (POLICY_HTN.format(site=args.site, ep=args.enforcement_point)
                + f"/{urllib.parse.quote(ident)}/state")
    try:
        body = client.get(path)
    except ApiError as exc:
        if exc.not_found:
            return {"api": api, "id": ident, "path": path, "exists": False,
                    "summary": "OBJECT NOT FOUND (clean)", "body": exc.body}
        raise
    st = body.get("state") or (body.get("details") or [{}])[0].get("state") or ""
    failures = body.get("failure_code") or body.get("error_message") or ""
    summary = f"EXISTS state={st or '?'}"
    if failures:
        summary += f" ({str(failures)[:60]})"
    return {"api": api, "id": ident, "path": path, "exists": True,
            "summary": summary, "body": body}


# --------------------------------------------------------------------------- #
# recommendations
# --------------------------------------------------------------------------- #

def recommend(found: dict) -> list[str]:
    mgr = found["transport_nodes"]
    pol = found["policy_host_transport_nodes"]
    fab = found["fabric_nodes"]
    dis = found["discovered_nodes"]
    idx = found["search_index"]
    tips: list[str] = []

    if not any((mgr, pol, fab, dis, idx)):
        tips.append("No trace of this host in NSX. Nothing for this KB to clean up -- "
                    "re-check the name/IP you passed, or look at the vCenter / ESXi side "
                    "(for a vLCM cluster: `nsxcli -c del nsx` on the host).")
        return tips

    if mgr:
        tips.append("KB option 3 (Manager API): force delete the transport node -- "
                    "`delete --api manager --id <uuid> --yes`.")
    if pol:
        tips.append("KB option 4 (Policy API): force delete the host transport node -- "
                    "`delete --api policy --id <node_name> --yes`.")
    if idx and not (mgr or pol):
        tips.append("Only the search index still lists this host -- this is exactly "
                    "KB option 2: run `resync` (start search resync policy/manager/"
                    "telemetry) and wait at least 10 minutes.")
    if (fab or dis) and not (mgr or pol):
        tips.append("A fabric/discovered node entry is left without a transport node. "
                    "Try KB option 1 (UI: select host > REMOVE NSX > Force Delete) "
                    "after moving the host to standalone in vSphere.")
    if any(i["state"].startswith("EXISTS state=success") for i in mgr + pol):
        tips.append("WARNING: at least one entry reports state=success -- that can be a "
                    "LIVE, healthy transport node. Confirm the host really is gone from "
                    "vCenter before deleting anything.")
    tips.append("If entries survive every option above, this is KB option 5: open a "
                "Broadcom Support case for scripted database cleanup "
                "(`report` builds the information they ask for).")
    return tips


# --------------------------------------------------------------------------- #
# commands
# --------------------------------------------------------------------------- #

def print_findings(found: dict, log: Log) -> int:
    total = 0
    cols = [("source", "SOURCE"), ("id", "ID"), ("display_name", "DISPLAY NAME"),
            ("ips", "IP"), ("state", "STATE")]
    for key in ("transport_nodes", "fabric_nodes", "discovered_nodes",
                "policy_host_transport_nodes", "search_index"):
        rows = found[key]
        total += len(rows)
        log.raw("")
        log.raw(f"{key} ({len(rows)})")
        table(rows, cols, log)
    log.raw("")
    return total


def cmd_scan(client: NsxClient, args, log: Log) -> int:
    found = discover(client, args.target, args, log)
    attach_states(client, found, args)
    total = print_findings(found, log)
    log(f"{total} matching entrie(s).")
    log.raw("")
    log.raw("Recommended next step(s):")
    for tip in recommend(found):
        log.raw(f"  * {tip}")
    log.raw("")
    if args.json_out:
        save_json(args.json_out, {"target": args.target, "nsx": client.base,
                                  "findings": found}, log)
    return 0 if total == 0 else 2


def cmd_state(client: NsxClient, args, log: Log) -> int:
    targets = []
    if args.id:
        targets = [(args.api or "manager", args.id)]
    else:
        found = discover(client, args.target, args, log)
        targets = [(i["api"], i["id"]) for i in found["transport_nodes"]
                   + found["policy_host_transport_nodes"]]
        if not targets:
            log("no transport node entry found for this host.")
            return 0
    rc = 0
    for api, ident in targets:
        st = read_state(client, api, ident, args)
        log(f"{api:7s} {ident}: {st['summary']}")
        log.raw(f"         GET {client.base}{st['path']}")
        if args.verbose:
            log.raw(json.dumps(st["body"], indent=2)[:4000])
        if st["exists"]:
            rc = 2
    return rc


def cmd_resync(client: NsxClient, args, log: Log) -> int:
    """KB option 2 -- search reindex on every NSX Manager node."""
    cmds = (["start search resync all"] if args.all else
            ["start search resync policy", "start search resync manager",
             "start search resync telemetry"])
    nodes = args.managers or client.manager_nodes()
    if not nodes:
        log("could not enumerate NSX Manager nodes; pass --managers ip1,ip2,ip3", True)
        return 1
    log(f"manager node(s): {', '.join(nodes)}")

    try:
        import paramiko  # type: ignore
    except ImportError:
        log("paramiko not installed -- run these by hand on EVERY manager node "
            "(`ssh admin@<node>`), then wait 10+ minutes:", True)
        for node in nodes:
            log.raw(f"  # {node}")
            for c in cmds:
                log.raw(f"  {c}")
        return 1

    if not args.yes:
        log("dry run: would run the commands below on each node (pass --yes to execute)")
        for c in cmds:
            log.raw(f"  {c}")
        return 0

    password = args.ssh_password or args.password
    for node in nodes:
        log(f"--- {node}")
        cli = paramiko.SSHClient()
        cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            cli.connect(node, username=args.ssh_user, password=password,
                        timeout=args.timeout, look_for_keys=False, allow_agent=False)
            # An admin SSH session lands straight in nsxcli, so the commands can be
            # fed on stdin of a single shell.
            chan = cli.invoke_shell()
            time.sleep(2)
            for c in cmds:
                chan.send(c + "\n")
                time.sleep(3)
            time.sleep(5)
            out = chan.recv(65535).decode("utf-8", "replace") if chan.recv_ready() else ""
            for line in out.splitlines():
                if line.strip():
                    log.raw(f"    {line.rstrip()}")
        except Exception as exc:  # noqa: BLE001 - report and keep going
            log(f"    SSH to {node} failed: {exc}", True)
        finally:
            cli.close()

    wait = args.reindex_wait
    log(f"waiting {wait}s for reindexing (KB: minimum 10 minutes) ...")
    time.sleep(wait)
    found = discover(client, args.target, args, log) if args.target else None
    if found is not None:
        attach_states(client, found, args)
        total = print_findings(found, log)
        log(f"{total} matching entrie(s) after resync.")
        if total and not args.all:
            log("still listed -- KB says to then run `resync --all`, then retry the "
                "UI force delete (option 1) or `delete` (option 3/4).")
        return 0 if total == 0 else 2
    return 0


def cmd_delete(client: NsxClient, args, log: Log, prefound: dict | None = None) -> int:
    """KB option 3 / 4 -- force delete, then poll state until 'Object not found'."""
    if args.id:
        victims = [(args.api or "manager", args.id, args.target or args.id)]
    else:
        found = prefound
        if found is None:
            found = discover(client, args.target, args, log)
            attach_states(client, found, args)
            print_findings(found, log)
        pool = found["transport_nodes"] + found["policy_host_transport_nodes"]
        if args.api:
            pool = [i for i in pool if i["api"] == args.api]
        victims = [(i["api"], i["id"], i["display_name"]) for i in pool]
        healthy = [i for i in pool if i["state"].startswith("EXISTS state=success")]
        if healthy and not args.force_anyway:
            log("REFUSING to delete: these entries report state=success, i.e. they look "
                "like live transport nodes:", True)
            for i in healthy:
                log.raw(f"    {i['api']} {i['id']} {i['display_name']}")
            log("Confirm the host is really gone from vCenter, then re-run with "
                "--force-anyway.", True)
            return 1

    if not victims:
        log("nothing to delete.")
        return 0

    log.raw("")
    log.raw("KB prerequisite -- for an INSTALL failure, move the failed host to "
            "standalone (out of the cluster) in vSphere first.")
    log.raw("Deleting with force=true & unprepare_host=false:")
    for api, ident, name in victims:
        log.raw(f"    [{api}] {ident} {name}")
    if not args.yes:
        log("dry run: nothing was deleted. Re-run with --yes to execute.")
        return 0
    if not args.no_confirm and sys.stdin.isatty():
        if input("Type 'delete' to continue: ").strip().lower() != "delete":
            log("aborted.")
            return 1

    rc = 0
    for api, ident, _name in victims:
        if api == "manager":
            path = f"/api/v1/transport-nodes/{urllib.parse.quote(ident)}"
        else:
            path = (POLICY_HTN.format(site=args.site, ep=args.enforcement_point)
                    + f"/{urllib.parse.quote(ident)}")
        params = {"force": "true", "unprepare_host": "false"}
        log(f"DELETE {client.base}{path}?force=true&unprepare_host=false")
        try:
            status, body = client.request("DELETE", path, params=params)
            log(f"  HTTP {status} {str(body)[:200]}")
        except ApiError as exc:
            if exc.not_found:
                log("  already gone.")
                continue
            log(f"  delete failed: {exc}", True)
            rc = 2
            continue
        if not poll_until_gone(client, api, ident, args, log):
            rc = 2
    return rc


def poll_until_gone(client: NsxClient, api: str, ident: str, args, log: Log) -> bool:
    """KB: poll the GET state call until 'Object not found' is returned."""
    deadline = time.time() + args.poll_timeout
    attempt = 0
    while True:
        attempt += 1
        st = read_state(client, api, ident, args)
        log(f"  poll #{attempt}: {st['summary']}")
        if not st["exists"]:
            log(f"  {api} {ident} is clean.")
            return True
        if time.time() + args.poll_interval > deadline:
            log(f"  still present after {args.poll_timeout}s -- escalate: KB option 5 "
                f"(Broadcom Support database cleanup).", True)
            return False
        time.sleep(args.poll_interval)


def cmd_cleanup(client: NsxClient, args, log: Log) -> int:
    """The KB's sequential approach, in one run."""
    log("=== step 1/4: scan ===")
    found = discover(client, args.target, args, log)
    attach_states(client, found, args)
    total = print_findings(found, log)
    if total == 0:
        log("nothing stale found; done.")
        return 0

    if args.with_resync:
        log("=== step 2/4: KB option 2 (search resync) ===")
        cmd_resync(client, args, log)
    else:
        log("=== step 2/4: skipped (pass --with-resync for KB option 2) ===")

    log("=== step 3/4: KB option 3/4 (force delete + poll) ===")
    if args.with_resync:  # the resync step already re-scanned; get a fresh view
        found = discover(client, args.target, args, log)
        attach_states(client, found, args)
    rc = cmd_delete(client, args, log, prefound=found)

    log("=== step 4/4: re-scan ===")
    found = discover(client, args.target, args, log)
    attach_states(client, found, args)
    left = print_findings(found, log)
    if left:
        log(f"{left} entrie(s) still present.", True)
        for tip in recommend(found):
            log.raw(f"  * {tip}")
        return rc or 2
    log("host is clean in NSX -- re-add it to the vSphere cluster and re-run host "
        "preparation / the upgrade pre-check.")
    return rc


def cmd_report(client: NsxClient, args, log: Log) -> int:
    """KB option 5 -- bundle what Broadcom Support asks for."""
    found = discover(client, args.target, args, log)
    attach_states(client, found, args)
    print_findings(found, log)
    version = client.node_version()
    report = {
        "generated": datetime.now().astimezone().isoformat(timespec="seconds"),
        "kb": KB_URL,
        "kb_permanent_fix": KB_FIXED_IN,
        "nsx_manager": client.base,
        "nsx_version": version,
        "manager_nodes": client.manager_nodes(),
        "target": args.target,
        "findings": found,
        "recommendations": recommend(found),
        "support_checklist": [
            f"NSX version: {version} (permanent fix is in {KB_FIXED_IN})",
            "Was the failure during an UPGRADE or an INSTALL / host preparation?",
            "Which KB 319975 workaround options were already completed (1-4)?",
            "NSX Manager log bundle + ESXi host log bundle",
            "Exact error messages and screenshots from the failing task",
        ],
    }
    out = args.json_out or os.path.join(args.out_dir,
                                        f"kb319975-report-{_stamp()}.json")
    save_json(out, report, log)
    log.raw("")
    log.raw("Attach to the Broadcom Support case:")
    for item in report["support_checklist"]:
        log.raw(f"  - {item}")
    log.raw("")
    return 0


def save_json(path: str, payload, log: Log) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, ensure_ascii=False)
    log(f"wrote {path}")


def _stamp() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="kb319975_stale_host.py",
        description=f"NSX stale host entry triage / cleanup -- KB 319975 ({KB_URL})",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Read-only unless --yes is given. See README.md.")
    p.add_argument("-n", "--nsx", help="NSX Manager IP / FQDN (or VIP)")
    p.add_argument("-u", "--user", default=os.environ.get("NSX_USER", "admin"))
    p.add_argument("-p", "--password", default=os.environ.get("NSX_PASSWORD"),
                   help="NSX admin password (env NSX_PASSWORD, else prompted)")
    p.add_argument("--insecure", action="store_true",
                   help="skip TLS verification (self-signed NSX certificate)")
    p.add_argument("--ca-bundle", help="PEM file to verify the NSX certificate against")
    p.add_argument("--timeout", type=int, default=60, help="HTTP/SSH timeout (s)")
    p.add_argument("--site", default="default", help="Policy API site id")
    p.add_argument("--enforcement-point", default="default",
                   help="Policy API enforcement point id")
    p.add_argument("--out-dir", default="kb319975-out",
                   help="directory for the run log and JSON output")
    p.add_argument("--json-out", help="explicit JSON output file")
    p.add_argument("--no-log-file", action="store_true")
    p.add_argument("-v", "--verbose", action="store_true")

    sub = p.add_subparsers(dest="command")

    def add_target(sp, required=True):
        sp.add_argument("target", nargs=None if required else "?",
                        help="host display name, FQDN, short name, IP or UUID")

    sp = sub.add_parser("scan", help="inventory every NSX trace of a host")
    add_target(sp)

    sp = sub.add_parser("state", help="read transport node state (KB option 3/4 step 1)")
    add_target(sp, required=False)
    sp.add_argument("--id", help="transport node UUID (manager) or node name (policy)")
    sp.add_argument("--api", choices=["manager", "policy"])

    sp = sub.add_parser("resync", help="KB option 2: search resync on all manager nodes")
    add_target(sp, required=False)
    sp.add_argument("--all", action="store_true",
                    help="run `start search resync all` instead of policy/manager/telemetry")
    sp.add_argument("--managers", type=lambda s: [x.strip() for x in s.split(",") if x.strip()],
                    help="comma separated manager IPs (default: read from the cluster API)")
    sp.add_argument("--ssh-user", default="admin")
    sp.add_argument("--ssh-password", help="default: same as --password")
    sp.add_argument("--reindex-wait", type=int, default=600,
                    help="seconds to wait after resync (KB: >= 600)")
    sp.add_argument("--yes", action="store_true", help="actually run the commands")

    sp = sub.add_parser("delete", help="KB option 3/4: force delete + poll until gone")
    add_target(sp, required=False)
    sp.add_argument("--id", help="transport node UUID (manager) or node name (policy)")
    sp.add_argument("--api", choices=["manager", "policy"],
                    help="restrict to one API (default: both)")
    sp.add_argument("--poll-interval", type=int, default=300, help="KB: every 5 minutes")
    sp.add_argument("--poll-timeout", type=int, default=3600)
    sp.add_argument("--force-anyway", action="store_true",
                    help="delete even if the entry reports state=success")
    sp.add_argument("--no-confirm", action="store_true", help="skip the typed prompt")
    sp.add_argument("--yes", action="store_true", help="actually delete")

    sp = sub.add_parser("cleanup", help="scan -> [resync] -> delete -> poll -> re-scan")
    add_target(sp)
    sp.add_argument("--with-resync", action="store_true", help="include KB option 2")
    sp.add_argument("--all", action="store_true")
    sp.add_argument("--managers", type=lambda s: [x.strip() for x in s.split(",") if x.strip()])
    sp.add_argument("--ssh-user", default="admin")
    sp.add_argument("--ssh-password")
    sp.add_argument("--reindex-wait", type=int, default=600)
    sp.add_argument("--api", choices=["manager", "policy"])
    sp.add_argument("--id")
    sp.add_argument("--poll-interval", type=int, default=300)
    sp.add_argument("--poll-timeout", type=int, default=3600)
    sp.add_argument("--force-anyway", action="store_true")
    sp.add_argument("--no-confirm", action="store_true")
    sp.add_argument("--yes", action="store_true")

    sp = sub.add_parser("report", help="KB option 5: findings + support checklist (JSON)")
    add_target(sp)

    return p


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.command:
        parser.print_help()
        return 1

    # interactive fallbacks, so the operator does not have to remember flags
    if not args.nsx:
        args.nsx = input("NSX Manager IP or FQDN: ").strip()
        if not args.nsx:
            parser.error("--nsx is required")
    if not getattr(args, "target", None) and args.command in ("scan", "cleanup", "report"):
        args.target = input("ESXi host name / FQDN / IP: ").strip()
    if not args.password:
        args.password = getpass.getpass(f"Password for {args.user}@{args.nsx}: ")

    log_path = None if args.no_log_file else os.path.join(
        args.out_dir, f"kb319975-{args.command}-{_stamp()}.log")
    log = Log(log_path)
    log(f"KB 319975 helper -- {args.command} (fixed permanently in {KB_FIXED_IN})")

    client = NsxClient(args.nsx, args.user, args.password, verify=not args.insecure,
                       ca_bundle=args.ca_bundle, timeout=args.timeout, log=log)
    version = client.node_version()
    log(f"NSX {client.base} version {version}")

    handler = {"scan": cmd_scan, "state": cmd_state, "resync": cmd_resync,
               "delete": cmd_delete, "cleanup": cmd_cleanup, "report": cmd_report}
    try:
        return handler[args.command](client, args, log)
    except ApiError as exc:
        log(f"ERROR: {exc}", True)
        return 1
    except KeyboardInterrupt:
        log("interrupted.", True)
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
