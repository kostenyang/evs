#!/usr/bin/env bash
# KB 452458 — update the primary (principal) datastore recorded for a cluster in the
# SDDC Manager inventory. Run ON the SDDC Manager appliance as the `vcf` user.
#
# This only rewrites the SDDC Manager control-plane record. It does NOT move any VM,
# FCD/PV, vCLS VM or content library; do the vSphere / Supervisor work first.
#
#   kb452458-primary-datastore.sh export   -d <domainId> -c <clusterId> [-w <workdir>]
#   kb452458-primary-datastore.sh update   -d <domainId> -c <clusterId> -m <newDatastoreMoRef> -t <TYPE> [-n <newDatastoreName>] [-w <workdir>] [--kb-style] [--yes]
#   kb452458-primary-datastore.sh verify   -d <domainId> -c <clusterId> [-w <workdir>]
#   kb452458-primary-datastore.sh rollback -d <domainId> -c <clusterId> [-w <workdir>] [--yes]
#
# Verified on SDDC Manager 9.1.1 (see README.md for the observed endpoint behaviour).
set -euo pipefail

BASE="http://localhost/inventory/extensions/vi"
TYPES="VSAN VSAN_ESA VSAN_MAX VSAN_REMOTE NFS NFS41 FC VMFS VVOL VVOL_FC VVOL_ISCSI VVOL_NFS"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
die()   { echo "ERROR: $*" >&2; exit 1; }
log()   { echo "[$(date +%H:%M:%S)] $*"; }

ACTION="${1:-}"; [ -n "$ACTION" ] || usage; shift
DOMAIN_ID=""; CLUSTER_ID=""; NEW_MOREF=""; NEW_TYPE=""; NEW_NAME=""; WORKDIR="$HOME/kb452458"; KB_STYLE=0; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    -d) DOMAIN_ID="$2"; shift 2;;
    -c) CLUSTER_ID="$2"; shift 2;;
    -m) NEW_MOREF="$2"; shift 2;;
    -t) NEW_TYPE="$2"; shift 2;;
    -n) NEW_NAME="$2"; shift 2;;
    -w) WORKDIR="$2"; shift 2;;
    --kb-style) KB_STYLE=1; shift;;
    --yes) YES=1; shift;;
    -h|--help) usage;;
    *) die "unknown argument: $1";;
  esac
done
[ -n "$DOMAIN_ID" ] && [ -n "$CLUSTER_ID" ] || die "-d <domainId> and -c <clusterId> are required"
command -v python3 >/dev/null || die "python3 not found"
mkdir -p "$WORKDIR"; cd "$WORKDIR"

# --- helpers -------------------------------------------------------------------------
fetch_domain() {   # $1 = output file
  curl -sf "$BASE/domainInventory?domainIds=$DOMAIN_ID" -o "$1" || die "GET domainInventory failed"
  python3 - "$1" "$CLUSTER_ID" <<'PY' || die "cluster not found in exported domain inventory"
import json,sys
d=json.load(open(sys.argv[1]))
assert d and any(c["id"]==sys.argv[2] for c in d[0]["clusters"])
PY
}
extract_cluster() {  # $1 = domain json, $2 = out file
  python3 - "$1" "$2" "$CLUSTER_ID" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))[0]
c=[x for x in d["clusters"] if x["id"]==sys.argv[3]][0]
json.dump(c,open(sys.argv[2],"w"),indent=2)
print(json.dumps({k:c.get(k) for k in ("id","sourceId","primaryDatastoreSourceId","primaryDatastoreType","primaryDatastoreName","isImported")}))
PY
}
put_cluster() {  # $1 = cluster json
  local code
  code=$(curl -s -o "$WORKDIR/last-response.txt" -w '%{http_code}' -X PUT -H 'Content-Type: application/json' \
         --data @"$1" "$BASE/clusters/$CLUSTER_ID")
  [ "$code" = "200" ] || { cat "$WORKDIR/last-response.txt"; echo; die "PUT /clusters/$CLUSTER_ID returned HTTP $code"; }
  log "PUT /clusters/$CLUSTER_ID -> HTTP 200"
}
put_domain_kb_style() {  # $1 = domain json (already modified)
  python3 - "$1" "$WORKDIR/domain-put.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))[0]
json.dump({"clusters":d["clusters"],"esxis":d["esxis"]},open(sys.argv[2],"w"))
PY
  local code
  code=$(curl -s -o "$WORKDIR/last-response.txt" -w '%{http_code}' -X PUT -H 'Content-Type: application/json' \
         --data @"$WORKDIR/domain-put.json" "$BASE/clusters")
  [ "$code" = "200" ] || { cat "$WORKDIR/last-response.txt"; echo; die "PUT /clusters returned HTTP $code"; }
  log "PUT /clusters (KB style, clusters+esxis) -> HTTP 200"
}
confirm() { [ "$YES" = 1 ] && return 0; read -r -p "$1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ] || die "aborted"; }

# --- actions -------------------------------------------------------------------------
case "$ACTION" in
  export)
    fetch_domain domain.json
    [ -f domain.json.bak ] || { cp domain.json domain.json.bak; log "saved rollback copy: $WORKDIR/domain.json.bak"; }
    log "current cluster record:"; extract_cluster domain.json cluster-current.json
    log "exported: $WORKDIR/domain.json, $WORKDIR/cluster-current.json"
    ;;

  update)
    [ -n "$NEW_MOREF" ] && [ -n "$NEW_TYPE" ] || die "-m <newDatastoreMoRef> and -t <TYPE> are required"
    case " $TYPES " in *" $NEW_TYPE "*) ;; *) die "invalid -t '$NEW_TYPE'. Valid: $TYPES";; esac
    [[ "$NEW_MOREF" =~ ^datastore-[0-9]+$ ]] || die "-m must be a vCenter datastore MoRef like datastore-123"
    fetch_domain domain.json
    [ -f domain.json.bak ] || { cp domain.json domain.json.bak; log "saved rollback copy: $WORKDIR/domain.json.bak"; }
    log "before:"; extract_cluster domain.json cluster-before.json
    python3 - domain.json domain-new.json cluster-new.json "$CLUSTER_ID" "$NEW_MOREF" "$NEW_TYPE" "$NEW_NAME" <<'PY'
import json,sys
src,dst,cl,cid,moref,typ,name=sys.argv[1:8]
d=json.load(open(src))
c=[x for x in d[0]["clusters"] if x["id"]==cid][0]
c["primaryDatastoreSourceId"]=moref
c["primaryDatastoreType"]=typ
if name: c["primaryDatastoreName"]=name
else: c.pop("primaryDatastoreName",None)
json.dump(d,open(dst,"w")); json.dump(c,open(cl,"w"),indent=2)
PY
    log "after (to be written):"; extract_cluster domain-new.json cluster-new.json
    confirm "Write this record to the SDDC Manager inventory?"
    if [ "$KB_STYLE" = 1 ]; then put_domain_kb_style domain-new.json; else put_cluster cluster-new.json; fi
    log "re-reading inventory:"; fetch_domain domain-after.json; extract_cluster domain-after.json cluster-after.json
    python3 - cluster-after.json "$NEW_MOREF" "$NEW_TYPE" <<'PY' || die "post-update check FAILED — run 'rollback' now"
import json,sys
c=json.load(open(sys.argv[1]))
assert c.get("primaryDatastoreSourceId")==sys.argv[2], "primaryDatastoreSourceId mismatch"
assert c.get("primaryDatastoreType")==sys.argv[3], "primaryDatastoreType is %r (null means the enum was rejected silently)"%c.get("primaryDatastoreType")
PY
    log "OK. Next: verify with the public API (this script's 'verify' prints the command) and run Sync Changes in the SDDC Manager UI."
    ;;

  verify)
    fetch_domain domain-verify.json
    log "inventory record:"; extract_cluster domain-verify.json cluster-verify.json
    python3 - cluster-verify.json <<'PY' || die "primaryDatastoreType is null — the record is broken, run 'rollback'"
import json,sys
c=json.load(open(sys.argv[1])); assert c.get("primaryDatastoreType")
PY
    cat <<EOF

Public-API check (from any host, needs an API token):
  TOKEN=\$(curl -sk -X POST https://<sddc-manager>/v1/tokens -H 'Content-Type: application/json' \\
          -d '{"username":"<user>","password":"<password>"}' | jq -r .accessToken)
  curl -sk https://<sddc-manager>/v1/clusters/$CLUSTER_ID -H "Authorization: Bearer \$TOKEN" \\
       | jq '{name,primaryDatastoreName,primaryDatastoreType,isDefault}'
Expected: primaryDatastoreType = new type; primaryDatastoreName = name resolved from vCenter; name/isDefault NOT null.
EOF
    ;;

  rollback)
    [ -f domain.json.bak ] || die "no $WORKDIR/domain.json.bak — nothing to roll back to"
    log "record that will be restored:"; extract_cluster domain.json.bak cluster-orig.json
    confirm "Restore this original record?"
    put_cluster cluster-orig.json
    fetch_domain domain-after-rollback.json; log "now:"; extract_cluster domain-after-rollback.json cluster-after-rollback.json
    ;;

  *) usage;;
esac
