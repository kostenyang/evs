#!/bin/bash
# =============================================================================
# kb385606-mp2policy.sh
#
# KB 385606 - "Check for data inconsistencies in DB upgrade" NSX precheck error
#             for VCF 9 upgrades ("MP Objects found in DB")
# https://knowledge.broadcom.com/external/article/385606
#
# Run this ON the NSX Manager appliance (root shell), or on any Linux host that
# can reach the NSX Manager. Defaults to localhost.
#
#   NSX Manager root shell:
#     nsx-mgr> st en                  # engineering mode
#     nsx-mgr:~# bash /tmp/kb385606-mp2policy.sh --action check
#
# What it does (mirrors the KB, in order):
#   1. Bridge Firewall  - list leftover Manager-mode L2 firewall sections
#   2. migration-coordinator - report / optionally start the service
#   3. Inventory MP objects eligible for promotion
#   4. (optional) delete Bridge Firewall sections
#   5. Start Manager -> Policy promotion
#   6. Poll until the promotion finishes
#   7. Re-verify + dump promotion history, write a JSON report
#
# Exit codes:
#   0  clean - rerun the upgrade prechecks
#   1  remediation still required (MP objects / bridge FW / indeterminate)
#   2  execution error (auth, connectivity, API failure, timeout, missing deps)
#   3  promotion finished but some objects failed
#
# Requires: bash, curl, and one of python3 / python / jq
# =============================================================================

set -u
umask 077

HOST=""            # empty = ask interactively (defaults to localhost on Enter)
HOST_NAME=""       # hostname only, no port - used for the netrc machine entry
USERNAME="admin"
PASSWORD=""
ACTION="check"
START_COORD=0
REMOVE_BRIDGE_FW=0
SKIP_FAILED="false"
TIMEOUT_MIN=120
POLL_SEC=20
OUT=""
ASSUME_YES=0
VERBOSE=0

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'USAGE'

Usage: kb385606-mp2policy.sh [options]

  --host <ip|fqdn>     NSX Manager to work on. Accepts an IP, an FQDN, an
                       optional :port, or a pasted https:// URL.
                       Omit it and the script asks (Enter = localhost).
  -u, --user <name>    admin user (default: admin)
  -p, --password <pw>  password; else $NSX_PASSWORD, else prompted
  --action check|promote
                       check   = read-only inventory + verdict (default)
                       promote = start coordinator, run MP->Policy promotion
  --start-coordinator  allow starting migration-coordinator in check mode
                       (implicit with --action promote)
  --remove-bridge-fw   delete non-default L2 (Bridge) firewall sections
                       (promote only; asks per section unless --yes)
  --skip-failed        skip_failed_resources=true ("Skip and Continue")
  --timeout-min <n>    promotion poll timeout, default 120
  --poll-sec <n>       poll interval, default 20
  --out <file>         JSON report path (default /var/log/kb385606-<ts>.json
                       or ./kb385606-<ts>.json if /var/log is not writable)
  -y, --yes            do not ask for confirmation on deletes
  -v, --verbose        echo every API call
  -h, --help           this help
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host)               HOST="$2"; shift 2 ;;
    -u|--user)            USERNAME="$2"; shift 2 ;;
    -p|--password)        PASSWORD="$2"; shift 2 ;;
    --action)             ACTION="$2"; shift 2 ;;
    --start-coordinator)  START_COORD=1; shift ;;
    --remove-bridge-fw)   REMOVE_BRIDGE_FW=1; shift ;;
    --skip-failed)        SKIP_FAILED="true"; shift ;;
    --timeout-min)        TIMEOUT_MIN="$2"; shift 2 ;;
    --poll-sec)           POLL_SEC="$2"; shift 2 ;;
    --out)                OUT="$2"; shift 2 ;;
    -y|--yes)             ASSUME_YES=1; shift ;;
    -v|--verbose)         VERBOSE=1; shift ;;
    -h|--help)            usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$ACTION" in
  check|promote) ;;
  *) echo "--action must be 'check' or 'promote'" >&2; exit 2 ;;
esac
[ "$ACTION" = "promote" ] && START_COORD=1

# ------------------------------------------------------------------ output --
if [ -t 1 ]; then
  C_RST=$'\033[0m'; C_CYN=$'\033[36m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_RED=$'\033[31m'; C_GRY=$'\033[90m'
else
  C_RST=""; C_CYN=""; C_GRN=""; C_YEL=""; C_RED=""; C_GRY=""
fi
step() { printf '\n%s=== %s%s\n' "$C_CYN" "$*" "$C_RST"; }
# read one line from the terminal even when stdin is redirected
ask() { # ask <prompt-text>  -> answer in $ANSWER
  printf '%s' "$1" >&2
  ANSWER=""
  # prefer the terminal so a redirected stdin does not swallow the prompt, but
  # fall back to stdin when there is no controlling tty (piped / scripted runs)
  if [ -r /dev/tty ] && IFS= read -r ANSWER 2>/dev/null < /dev/tty; then
    return 0
  fi
  IFS= read -r ANSWER || ANSWER=""
}
interactive() { [ -r /dev/tty ] || [ -t 0 ]; }
ok()   { printf '  %s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '  %s[WARN]%s %s\n' "$C_YEL" "$C_RST" "$*"; }
bad()  { printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*"; }
info() { printf '  %s[ .. ]%s %s\n' "$C_GRY" "$C_RST" "$*"; }

# ------------------------------------------------------------ dependencies --
have() { command -v "$1" >/dev/null 2>&1; }
have curl || { echo "curl not found" >&2; exit 2; }

# --------------------------------------------------------- target selection --
# Accepts an IP, an FQDN, optionally with a scheme, a port, or a trailing path:
#   10.20.30.40        nsx-mgr.corp.local        https://nsx-mgr.corp.local/
#   nsx-mgr.corp.local:443                       [2001:db8::1]
normalize_host() {
  local h="$1"
  # trim the ends only - whitespace inside must fail validation, not be swallowed
  h="$(printf '%s' "$h" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  h="${h#http://}"; h="${h#https://}"   # tolerate a pasted URL
  h="${h%%/*}"                          # drop any path
  h="${h%.}"                            # drop a trailing dot on an FQDN
  printf '%s' "$h"
}

# splits $1 into HOST_NAME (no port) + HOST (host[:port]); returns 1 if invalid
parse_host() {
  local h name port rest
  h="$(normalize_host "$1")"
  [ -n "$h" ] || return 1
  case "$h" in
    \[*\]*)  name="${h%%]*}]"; rest="${h#*]}"; port="${rest#:}" ;;  # [IPv6]:port
    *:*:*)   name="[$h]";      port="" ;;                          # bare IPv6
    *:*)     name="${h%%:*}";  port="${h##*:}" ;;
    *)       name="$h";        port="" ;;
  esac
  case "$name" in
    \[*\]) : ;;                                                    # IPv6 literal
    *[!A-Za-z0-9.-]*|-*|.*|*.) return 1 ;;                         # illegal chars
    *) : ;;
  esac
  if [ -n "$port" ]; then
    case "$port" in ''|*[!0-9]*) return 1 ;; esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    HOST="${name}:${port}"
  else
    HOST="$name"
  fi
  HOST_NAME="$name"
  return 0
}

if [ -n "$HOST" ]; then
  parse_host "$HOST" || { echo "invalid --host value: $HOST" >&2; exit 2; }
elif interactive; then
  while : ; do
    ask 'NSX Manager IP or FQDN [localhost]: '
    [ -n "$ANSWER" ] || ANSWER="localhost"
    if parse_host "$ANSWER"; then break; fi
    echo "  not a valid IP / FQDN: $ANSWER" >&2
  done
else
  parse_host localhost
fi

# resolvable? warn early instead of leaving the customer with a bare curl error
case "$HOST_NAME" in
  \[*\]|localhost) : ;;                    # IPv6 literal / localhost - nothing to resolve
  *[A-Za-z]*)                              # has a letter, so it is a name
    if have getent && ! getent hosts "$HOST_NAME" >/dev/null 2>&1; then
      warn "$HOST_NAME does not resolve on this host - check DNS, or use the IP instead"
    fi ;;
esac

PY=""
for c in python3 python; do have "$c" && { PY="$c"; break; }; done
if [ -z "$PY" ] && ! have jq; then
  echo "need python3 (or python, or jq) to parse JSON responses" >&2
  exit 2
fi

# json_get <dotted.path>   - JSON on stdin, prints scalar or compact JSON
json_get() {
  if [ -n "$PY" ]; then
    "$PY" -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
cur = d
for k in sys.argv[1].split("."):
    if isinstance(cur, dict) and k in cur:
        cur = cur[k]
    else:
        sys.exit(1)
print(cur if not isinstance(cur, (dict, list)) else json.dumps(cur))
' "$1" 2>/dev/null
  else
    jq -er --arg p "$1" 'getpath($p | split("."))
      | if type=="object" or type=="array" then tojson else . end' 2>/dev/null
  fi
}

# ------------------------------------------------------------------- creds --
if [ -z "$PASSWORD" ]; then
  if [ -n "${NSX_PASSWORD:-}" ]; then
    PASSWORD="$NSX_PASSWORD"
  else
    stty -echo 2>/dev/null
    ask "Password for ${USERNAME}@${HOST}: "
    stty echo 2>/dev/null
    printf '\n' >&2
    PASSWORD="$ANSWER"
  fi
fi
[ -n "$PASSWORD" ] || { echo "empty password" >&2; exit 2; }

# credentials go in a 0600 netrc, never on the curl command line (ps-visible).
# netrc matches on the hostname only, so any :port must not be included here.
NETRC="$(mktemp)"
chmod 600 "$NETRC"
printf 'machine %s login %s password %s\n' "$HOST_NAME" "$USERNAME" "$PASSWORD" > "$NETRC"
WORKDIR="$(mktemp -d)"
cleanup() { rm -f "$NETRC"; rm -rf "$WORKDIR"; }
trap cleanup EXIT INT TERM

# --------------------------------------------------------------- api helper --
HTTP=""
BODY=""
api() { # api <METHOD> <PATH> [JSON_BODY]
  local method="$1" path="$2" body="${3:-}"
  local url="https://${HOST}${path}"
  [ "$VERBOSE" -eq 1 ] && printf '  %s> %s %s%s\n' "$C_GRY" "$method" "$url" "$C_RST" >&2
  local tmp="$WORKDIR/resp"
  if [ -n "$body" ]; then
    HTTP=$(curl -sk --netrc-file "$NETRC" --max-time 300 \
      -H 'Accept: application/json' -H 'Content-Type: application/json' \
      -X "$method" -d "$body" -o "$tmp" -w '%{http_code}' "$url")
  else
    HTTP=$(curl -sk --netrc-file "$NETRC" --max-time 300 \
      -H 'Accept: application/json' \
      -X "$method" -o "$tmp" -w '%{http_code}' "$url")
  fi
  local rc=$?
  BODY="$(cat "$tmp" 2>/dev/null)"
  if [ $rc -ne 0 ]; then HTTP="000"; return 1; fi
  case "$HTTP" in 2*) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------- report accumulation ---
if [ -z "$OUT" ]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  if [ -w /var/log ]; then OUT="/var/log/kb385606-${TS}.json"; else OUT="./kb385606-${TS}.json"; fi
fi
R_STARTED="$(date -Iseconds 2>/dev/null || date)"
R_VERSION=""; R_COORD=""; R_VERDICT=""
R_PRESTATS="null"; R_POSTSTATS="null"; R_SUMMARY="null"; R_HISTORY="null"
R_BRIDGE_JSON="[]"
MP_TOTAL=-1        # -1 = unknown
BRIDGE_BLOCKING=0
BRIDGE_REMOVED=0
FAILED_TOTAL=0
LEFT_TOTAL=0

write_report() {
  local code="$1"
  local finished; finished="$(date -Iseconds 2>/dev/null || date)"
  cat > "$OUT" <<EOF
{
  "kb": "385606",
  "nsxManager": "$HOST",
  "action": "$ACTION",
  "startedAt": "$R_STARTED",
  "finishedAt": "$finished",
  "nsxVersion": "$R_VERSION",
  "migrationCoordinator": "$R_COORD",
  "bridgeFirewall": $R_BRIDGE_JSON,
  "bridgeFirewallBlocking": $BRIDGE_BLOCKING,
  "bridgeFirewallRemoved": $BRIDGE_REMOVED,
  "mpObjectsBefore": $MP_TOTAL,
  "mpObjectsRemaining": $LEFT_TOTAL,
  "failedObjects": $FAILED_TOTAL,
  "prePromotionStats": $R_PRESTATS,
  "statusSummary": $R_SUMMARY,
  "postPromotionStats": $R_POSTSTATS,
  "history": $R_HISTORY,
  "verdict": "$R_VERDICT",
  "exitCode": $code
}
EOF
  printf '\n%sReport: %s%s\n' "$C_CYN" "$OUT" "$C_RST"
}
finish() { write_report "$1"; exit "$1"; }

# ============================================================ 0. connect ====
step "0. Connect to NSX Manager $HOST"
if ! api GET /api/v1/node; then
  bad "cannot reach NSX API (HTTP $HTTP)"
  case "$HTTP" in
    000) info "no HTTP response - wrong IP/FQDN, no route, or 443 blocked by a firewall"
         info "target was https://${HOST}/api/v1/node" ;;
    401|403) info "authentication rejected - check user/password, or the account may be locked" ;;
  esac
  finish 2
fi
R_VERSION="$(printf '%s' "$BODY" | json_get product_version)"
NODE_NAME="$(printf '%s' "$BODY" | json_get hostname)"
ok "connected - NSX ${R_VERSION:-?} / hostname ${NODE_NAME:-?}"

# =================================================== 1. bridge firewall =====
step "1. Bridge Firewall (Manager-mode L2 firewall sections)"
BRIDGE_TSV="$WORKDIR/bridge.tsv"
: > "$BRIDGE_TSV"
if api GET '/api/v1/firewall/sections?page_size=1000'; then
  printf '%s' "$BODY" > "$WORKDIR/fw.json"
  if [ -n "$PY" ]; then
    "$PY" -c '
import sys, json
d = json.load(open(sys.argv[1]))
for s in d.get("results", []):
    if s.get("section_type") != "LAYER2":
        continue
    is_def = bool(s.get("is_default", False))
    rules  = int(s.get("rule_count", 0) or 0)
    # blocking = non-default section, or a default section that still has rules
    must   = (not is_def) or rules > 0
    print("\t".join([s.get("id",""), s.get("display_name",""),
                     str(rules), str(is_def).lower(), str(must).lower()]))
' "$WORKDIR/fw.json" > "$BRIDGE_TSV" 2>/dev/null
  else
    jq -r '.results[]? | select(.section_type=="LAYER2")
      | [ .id, .display_name, (.rule_count//0|tostring),
          (.is_default//false|tostring),
          (((.is_default//false)|not) or ((.rule_count//0) > 0) | tostring) ]
      | @tsv' "$WORKDIR/fw.json" > "$BRIDGE_TSV" 2>/dev/null
  fi
  BRIDGE_BLOCKING=$(awk -F'\t' '$5=="true"' "$BRIDGE_TSV" | wc -l | tr -d ' ')
  R_BRIDGE_JSON="$(awk -F'\t' 'BEGIN{printf "["; n=0}
    { if (n++) printf ","; gsub(/"/,"\\\"",$2);
      printf "{\"id\":\"%s\",\"displayName\":\"%s\",\"ruleCount\":%s,\"isDefault\":%s,\"mustRemove\":%s}",
             $1,$2,($3==""?0:$3),($4==""?"false":$4),($5==""?"false":$5) }
    END{printf "]"}' "$BRIDGE_TSV")"
  [ -n "$R_BRIDGE_JSON" ] || R_BRIDGE_JSON="[]"
  if [ "$BRIDGE_BLOCKING" -eq 0 ]; then
    ok "no Bridge / L2 firewall section needs removal"
  else
    warn "$BRIDGE_BLOCKING L2 (Bridge) firewall section(s) must be removed:"
    printf '        %-40s %-30s %6s %8s\n' ID NAME RULES DEFAULT
    awk -F'\t' '$5=="true" {printf "        %-40s %-30s %6s %8s\n", $1, $2, $3, $4}' "$BRIDGE_TSV"
  fi
else
  warn "MP firewall section API unavailable (HTTP $HTTP) - removed in NSX 9.x, skipping"
fi

# =========================================== 2. migration-coordinator =======
step "2. migration-coordinator service"
COORD_RUNNING=0
if api GET /api/v1/node/services/migration-coordinator/status; then
  R_COORD="$(printf '%s' "$BODY" | json_get runtime_state)"
  [ "$R_COORD" = "running" ] && COORD_RUNNING=1
else
  R_COORD="unknown"
fi
if [ "$COORD_RUNNING" -eq 1 ]; then
  ok "migration-coordinator: $R_COORD"
else
  warn "migration-coordinator: ${R_COORD:-unknown} (must be running before promotion)"
fi

if [ "$COORD_RUNNING" -eq 0 ] && [ "$START_COORD" -eq 1 ]; then
  info "starting migration-coordinator ..."
  if ! api POST '/api/v1/node/services/migration-coordinator?action=start'; then
    # fall back to the admin CLI when running on the appliance itself
    if have nsxcli; then
      info "API start failed (HTTP $HTTP), trying: nsxcli -c 'start service migration-coordinator'"
      nsxcli -c "start service migration-coordinator" >/dev/null 2>&1
    else
      bad "could not start migration-coordinator (HTTP $HTTP)"
      info "run this on any Manager node admin CLI: start service migration-coordinator"
      finish 2
    fi
  fi
  deadline=$(( $(date +%s) + 600 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 10
    if api GET /api/v1/node/services/migration-coordinator/status; then
      R_COORD="$(printf '%s' "$BODY" | json_get runtime_state)"
      [ "$R_COORD" = "running" ] && { COORD_RUNNING=1; break; }
    fi
  done
  if [ "$COORD_RUNNING" -eq 1 ]; then
    ok "migration-coordinator is running"
  else
    bad "migration-coordinator did not reach 'running' within 10 minutes"
    finish 2
  fi
fi

# ================================================ 3. inventory MP objects ===
step "3. Manager (MP) objects eligible for promotion"
if api GET '/api/v1/migration/mp-to-policy/stats?pre_promotion=true'; then
  R_PRESTATS="$BODY"
  printf '%s' "$BODY" > "$WORKDIR/pre.json"
  MP_TOTAL="$(printf '%s' "$BODY" | json_get total_count)"
  case "$MP_TOTAL" in ''|*[!0-9]*) MP_TOTAL=-1 ;; esac
  if [ "$MP_TOTAL" -eq 0 ]; then
    ok "no leftover MP objects"
  elif [ "$MP_TOTAL" -gt 0 ]; then
    warn "$MP_TOTAL MP object(s) pending promotion:"
    printf '        %-28s %-14s %6s %9s %7s\n' RESOURCE_TYPE STATUS TOTAL PROMOTED FAILED
    if [ -n "$PY" ]; then
      "$PY" -c '
import sys, json
d = json.load(open(sys.argv[1]))
for r in d.get("migration_stats", []):
    print("        %-28s %-14s %6s %9s %7s" % (
        r.get("resource_type",""), r.get("promotion_status",""),
        r.get("total_count",""), r.get("promoted_objects_count",""),
        r.get("failed_objects_count","")))
' "$WORKDIR/pre.json"
    else
      jq -r '.migration_stats[]? | "        \(.resource_type)\t\(.promotion_status)\t\(.total_count)\t\(.promoted_objects_count)\t\(.failed_objects_count)"' "$WORKDIR/pre.json"
    fi
  fi
else
  # the endpoint returns HTTP 500 when migration-coordinator is not running:
  # that is "unknown", not "clean"
  MP_TOTAL=-1
  warn "pre-promotion stats unavailable (HTTP $HTTP) - MP object count is UNKNOWN"
  [ "$COORD_RUNNING" -eq 0 ] && \
    info "cause: migration-coordinator is not running; rerun with --start-coordinator"
fi

# =============================================== check mode stops here ======
if [ "$ACTION" = "check" ]; then
  step "Verdict"
  if [ "$MP_TOTAL" -eq 0 ] && [ "$BRIDGE_BLOCKING" -eq 0 ]; then
    R_VERDICT="CLEAN"
    ok 'clean - "Check for data inconsistencies in DB" precheck should pass'
    finish 0
  fi
  if [ "$MP_TOTAL" -lt 0 ] && [ "$BRIDGE_BLOCKING" -eq 0 ]; then
    R_VERDICT="INDETERMINATE"
    warn "cannot determine MP object count; rerun as:"
    printf '    %s --host %s --action check --start-coordinator%s\n' "$0" "$HOST" ""
    finish 1
  fi
  R_VERDICT="REMEDIATION_REQUIRED"
  bad "remediation required:"
  [ "$MP_TOTAL" -gt 0 ] && printf '         - %s MP object(s) to promote to Policy\n' "$MP_TOTAL"
  [ "$MP_TOTAL" -lt 0 ] && printf '         - MP object count unknown (coordinator not running)\n'
  [ "$BRIDGE_BLOCKING" -gt 0 ] && printf '         - %s Bridge/L2 firewall section(s) to remove\n' "$BRIDGE_BLOCKING"
  extra=""
  [ "$BRIDGE_BLOCKING" -gt 0 ] && extra=" --remove-bridge-fw"
  printf '\n  Remediate with:\n    %s%s --host %s --action promote --skip-failed%s%s\n' \
    "$C_YEL" "$0" "$HOST" "$extra" "$C_RST"
  finish 1
fi

# ============================================ 4. remove bridge firewall =====
if [ "$BRIDGE_BLOCKING" -gt 0 ]; then
  step "4. Bridge Firewall removal"
  if [ "$REMOVE_BRIDGE_FW" -eq 1 ]; then
    while IFS=$'\t' read -r id name rules isdef must; do
      [ "$must" = "true" ] || continue
      if [ "$ASSUME_YES" -ne 1 ]; then
        printf '  Delete L2 firewall section "%s" (%s, %s rules)? [y/N] ' "$name" "$id" "$rules"
        IFS= read -r reply </dev/tty || reply=""
        case "$reply" in y|Y|yes|YES) ;; *) info "skipped $id"; continue ;; esac
      fi
      if api DELETE "/api/v1/firewall/sections/${id}?cascade=true"; then
        ok "deleted $name ($id)"
        BRIDGE_REMOVED=$((BRIDGE_REMOVED + 1))
      else
        bad "delete failed for $name ($id) - HTTP $HTTP"
      fi
    done < "$BRIDGE_TSV"
  else
    warn "$BRIDGE_BLOCKING section(s) left in place (--remove-bridge-fw not given)"
    info "UI path: System > General Settings > User Interface -> Manager mode -> Security > Bridge Firewall"
  fi
fi

# ==================================================== 5. start promotion ====
step "5. Manager -> Policy promotion"
if [ "$MP_TOTAL" -lt 0 ]; then
  bad "MP object inventory unknown - refusing to start promotion blindly"
  R_VERDICT="INDETERMINATE"
  finish 2
elif [ "$MP_TOTAL" -eq 0 ]; then
  ok "nothing to promote, skipping"
else
  if [ "$ASSUME_YES" -ne 1 ]; then
    printf '  Promote %s MP object(s) to Policy on %s? [y/N] ' "$MP_TOTAL" "$HOST"
    IFS= read -r reply </dev/tty || reply=""
    case "$reply" in y|Y|yes|YES) ;; *) info "aborted by user"; R_VERDICT="ABORTED"; finish 1 ;; esac
  fi
  if ! api POST /api/v1/migration/mp-to-policy \
        "{\"skip_failed_resources\": ${SKIP_FAILED}, \"mode\": \"GENERIC\"}"; then
    bad "failed to start promotion (HTTP $HTTP)"
    printf '  %s\n' "$BODY"
    finish 2
  fi
  ok "promotion started (skip_failed_resources=$SKIP_FAILED)"

  # ================================================ 6. poll until done ======
  step "6. Polling promotion progress"
  deadline=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
  done_flag=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep "$POLL_SEC"
    api GET /api/v1/migration/status-summary || continue
    R_SUMMARY="$BODY"
    printf '%s' "$BODY" > "$WORKDIR/sum.json"
    overall="$(printf '%s' "$BODY" | json_get overall_migration_status)"
    if [ -n "$PY" ]; then
      line="$("$PY" -c '
import sys, json
d = json.load(open(sys.argv[1]))
for c in d.get("component_status", []):
    if c.get("component_type") == "MP_TO_POLICY_MIGRATION":
        print("%s %s" % (c.get("status","UNKNOWN"), c.get("percent_complete",0)))
        break
else:
    print("UNKNOWN 0")
' "$WORKDIR/sum.json")"
    else
      line="$(jq -r '(.component_status[]? | select(.component_type=="MP_TO_POLICY_MIGRATION")
                      | "\(.status) \(.percent_complete)") // "UNKNOWN 0"' "$WORKDIR/sum.json" | head -1)"
    fi
    cstatus="${line%% *}"; cpct="${line##* }"
    info "$(date +%H:%M:%S)  overall=${overall:-?}  migration=${cstatus} ${cpct}%"
    case "$cstatus" in SUCCESS|FAILED|PAUSED|CANCELED) done_flag=1; break ;; esac
    case "$overall"  in SUCCESS|FAILED)                done_flag=1; break ;; esac
  done
  if [ "$done_flag" -eq 0 ]; then
    bad "promotion did not finish within ${TIMEOUT_MIN} minutes"
    info "check the UI: System > General Settings > Manager Objects Promotion"
    R_VERDICT="TIMEOUT"
    finish 2
  fi
  ok "promotion finished - overall=${overall:-?}"
fi

# ======================================================== 7. re-verify =====
step "7. Verification"
if api GET /api/v1/migration/mp-to-policy/stats; then
  R_POSTSTATS="$BODY"
  printf '%s' "$BODY" > "$WORKDIR/post.json"
  printf '        %-28s %-14s %6s %9s %7s\n' RESOURCE_TYPE STATUS TOTAL PROMOTED FAILED
  if [ -n "$PY" ]; then
    "$PY" -c '
import sys, json
d = json.load(open(sys.argv[1]))
for r in d.get("migration_stats", []):
    print("        %-28s %-14s %6s %9s %7s" % (
        r.get("resource_type",""), r.get("promotion_status",""),
        r.get("total_count",""), r.get("promoted_objects_count",""),
        r.get("failed_objects_count","")))
' "$WORKDIR/post.json"
    FAILED_TOTAL="$("$PY" -c '
import sys, json
d = json.load(open(sys.argv[1]))
print(sum(int(r.get("failed_objects_count", 0) or 0) for r in d.get("migration_stats", [])))
' "$WORKDIR/post.json")"
  else
    jq -r '.migration_stats[]? | "        \(.resource_type)\t\(.promotion_status)\t\(.total_count)\t\(.promoted_objects_count)\t\(.failed_objects_count)"' "$WORKDIR/post.json"
    FAILED_TOTAL="$(jq -r '[.migration_stats[]?.failed_objects_count | tonumber? // 0] | add // 0' "$WORKDIR/post.json")"
  fi
fi
case "$FAILED_TOTAL" in ''|*[!0-9]*) FAILED_TOTAL=0 ;; esac

if api GET '/api/v1/migration/mp-to-policy/stats?pre_promotion=true'; then
  LEFT_TOTAL="$(printf '%s' "$BODY" | json_get total_count)"
fi
case "$LEFT_TOTAL" in ''|*[!0-9]*) LEFT_TOTAL=0 ;; esac

if api GET /api/v1/migration/mp-policy-promotion/history; then
  R_HISTORY="$BODY"
  printf '%s' "$BODY" > "$WORKDIR/hist.json"
  if [ -n "$PY" ]; then
    "$PY" -c '
import sys, json, datetime
d = json.load(open(sys.argv[1]))
for h in d.get("results", [])[:6]:
    try:
        ts = datetime.datetime.fromtimestamp(int(h.get("date_time",0))/1000).isoformat(timespec="seconds")
    except Exception:
        ts = "?"
    print("        history: %s  %s" % (ts, h.get("status","")))
' "$WORKDIR/hist.json"
  fi
fi

BRIDGE_LEFT=$(( BRIDGE_BLOCKING - BRIDGE_REMOVED ))

step "Verdict"
if [ "$LEFT_TOTAL" -eq 0 ] && [ "$FAILED_TOTAL" -eq 0 ] && [ "$BRIDGE_LEFT" -le 0 ]; then
  R_VERDICT="CLEAN"
  ok "all done - rerun the NSX / VCF upgrade prechecks"
  finish 0
fi
if [ "$FAILED_TOTAL" -gt 0 ]; then
  R_VERDICT="PROMOTED_WITH_FAILURES"
  bad "$FAILED_TOTAL object(s) failed to promote - resolve manually and rerun"
else
  R_VERDICT="REMEDIATION_REQUIRED"
fi
[ "$LEFT_TOTAL"  -gt 0 ] && bad "$LEFT_TOTAL MP object(s) still not promoted"
[ "$BRIDGE_LEFT" -gt 0 ] && bad "$BRIDGE_LEFT Bridge/L2 firewall section(s) still present"

if [ "$FAILED_TOTAL" -gt 0 ]; then finish 3; else finish 1; fi
