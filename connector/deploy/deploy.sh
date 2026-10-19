#!/usr/bin/env bash
# Deploy the Claude usage connector (layer 3) to the CURRENT dtctl context, end to end:
#   1. outbound allowlist: add api.anthropic.com to builtin:dt-javascript-runtime.allowed-outbound-connections (merge, never overwrite)
#   2. credential vault: upsert a TOKEN credential with the Anthropic key (via dtctl exec function, key never written to disk)
#      (needs environment-api:credentials:* on the dtctl token; with --skip-vault the workflow finds the entry by NAME, --credential-name,
#       or by CREDENTIAL_ID env)
#   3. workflow: render inputs + `dtctl apply --write-id` (idempotent re-deploys through deploy/.out/*.json)
#   4. optional: run once now and show the execution log, then verify with a DQL count per source
#
# Nothing is mutated without --yes. Dry mode (default) prints the plan and the exact dtctl commands.
#
# Usage:
#   export ANTHROPIC_USAGE_KEY='sk-ant-...'            # Enterprise: Analytics API key | Console: Admin API key (sk-ant-admin01-...)
#   deploy/deploy.sh --org-type console --org-id acme [--context <dtctl ctx>] [--run-now] --yes
#   deploy/deploy.sh --org-type team --yes             # no key, no allowlist: only the reminder workflow
# Options: --title <workflow title> --credential-name <name> --skip-allowlist --skip-vault --skip-workflow --key-env <VAR> --private
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/.out"; mkdir -p "$OUT"

ORG_TYPE=""; ORG_ID=""; CTX=""; YES=0; RUN_NOW=0; PRIVATE=""
SKIP_ALLOW=0; SKIP_VAULT=0; SKIP_WF=0
KEY_ENV="ANTHROPIC_USAGE_KEY"
CRED_NAME=""; TITLE=""
SCHEMA="builtin:dt-javascript-runtime.allowed-outbound-connections"
HOST="api.anthropic.com"

while [ $# -gt 0 ]; do
  case "$1" in
    --org-type) ORG_TYPE="$2"; shift 2;;
    --org-id) ORG_ID="$2"; shift 2;;
    --context) CTX="$2"; shift 2;;
    --credential-name) CRED_NAME="$2"; shift 2;;
    --title) TITLE="$2"; shift 2;;
    --key-env) KEY_ENV="$2"; shift 2;;
    --skip-allowlist) SKIP_ALLOW=1; shift;;
    --skip-vault) SKIP_VAULT=1; shift;;
    --skip-workflow) SKIP_WF=1; shift;;
    --run-now) RUN_NOW=1; shift;;
    --private) PRIVATE="--private"; shift;;
    --yes) YES=1; shift;;
    -h|--help) sed -n 2,16p "$0"; exit 0;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done
case "$ORG_TYPE" in enterprise|console|team) ;; *) echo "--org-type must be enterprise|console|team" >&2; exit 2;; esac
DT=(dtctl --plain); [ -n "$CTX" ] && DT+=(--context "$CTX")
if [ "$ORG_TYPE" = "team" ]; then SKIP_ALLOW=1; SKIP_VAULT=1; fi
[ -n "$CRED_NAME" ] || CRED_NAME="Anthropic $ORG_TYPE usage API key"
[ -n "$TITLE" ] || TITLE="Claude usage connector — $ORG_TYPE (dt-ai-observability-claude layer 3)"

run() { echo "+ $*"; if [ "$YES" = 1 ]; then "$@"; fi; }

echo "== target context: $("${DT[@]}" config current-context 2>/dev/null || echo '(current)') | org_type=$ORG_TYPE | mode=$([ "$YES" = 1 ] && echo APPLY || echo DRY)"
[ "$YES" = 1 ] || echo "   (dry mode: printing commands only; add --yes to apply)"

# ---- 1. outbound allowlist ---------------------------------------------------
if [ "$SKIP_ALLOW" = 0 ]; then
  echo "== 1/4 outbound allowlist: ensure $HOST in $SCHEMA"
  if [ "$YES" = 1 ]; then
    rm -f "$OUT/allowlist.json"
    set +e
    "${DT[@]}" get settings --schema "$SCHEMA" -o json 2>/dev/null | python3 "$HERE/merge_allowlist.py" "$HOST" --out "$OUT/allowlist.json"; rc=$?
    set -e
    if [ $rc = 3 ]; then
      printf '{"allowedOutboundConnections":{"enforced":true,"hostList":["%s"]}}\n' "$HOST" > "$OUT/allowlist-value.json"
      run "${DT[@]}" create settings -f "$OUT/allowlist-value.json" --schema "$SCHEMA" --scope environment
    elif [ -f "$OUT/allowlist.json" ] && [ $rc = 0 ] && grep -q "$HOST" "$OUT/allowlist.json"; then
      run "${DT[@]}" apply -f "$OUT/allowlist.json"
    fi
  else
    echo "+ dtctl get settings --schema $SCHEMA -o json | python3 deploy/merge_allowlist.py $HOST --out deploy/.out/allowlist.json && dtctl apply -f deploy/.out/allowlist.json"
  fi
fi

# ---- 2. credential vault ------------------------------------------------------
CRED_ID=""
if [ "$SKIP_VAULT" = 0 ]; then
  echo "== 2/4 credential vault: upsert TOKEN credential \"$CRED_NAME\" from env $KEY_ENV"
  KEY="${!KEY_ENV:-}"
  if [ -z "$KEY" ]; then echo "env var $KEY_ENV is empty — export the Anthropic key first (never paste it into chat or files)" >&2; [ "$YES" = 1 ] && exit 2; fi
  if [ "$YES" = 1 ]; then
    PAYLOAD=$(python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1], "token": sys.argv[2]}))' "$CRED_NAME" "$KEY")
    RES=$("${DT[@]}" exec function -f "$HERE/vault_upsert.js" --payload "$PAYLOAD" -o json)
    CRED_ID=$(printf '%s' "$RES" | python3 -c 'import json,sys; d=json.load(sys.stdin); d=d.get("result",d); print(d.get("id",""))')
    [ -n "$CRED_ID" ] || { echo "could not read credential id from: $RES" >&2; exit 1; }
    echo "   credential id: $CRED_ID ($(printf '%s' "$RES" | grep -o '"created":[a-z]*'))"
  else
    echo "+ dtctl exec function -f deploy/vault_upsert.js --payload '{\"name\":\"$CRED_NAME\",\"token\":\"\$$KEY_ENV\"}' -o json   # -> CREDENTIALS_VAULT-..."
    CRED_ID="CREDENTIALS_VAULT-DRYRUN"
  fi
else
  CRED_ID="${CREDENTIAL_ID:-}"
fi

# ---- 3. workflow -------------------------------------------------------------
if [ "$SKIP_WF" = 0 ]; then
  echo "== 3/4 workflow: render + apply (schedule 15:00 UTC daily)"
  WF_OUT="$OUT/claude-usage-connector.$ORG_TYPE.json"
  ID_ARG=(); [ -f "$WF_OUT" ] && EXISTING=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$WF_OUT") || EXISTING=""
  [ -n "${EXISTING:-}" ] && ID_ARG=(--id "$EXISTING")
  python3 "$HERE/render_workflow.py" --org-type "$ORG_TYPE" --credential-id "$CRED_ID" --org-id "$ORG_ID" --out "$WF_OUT" --title "$TITLE" --credential-name "$CRED_NAME" $PRIVATE ${ID_ARG[@]+"${ID_ARG[@]}"} >/dev/null
  echo "   rendered $WF_OUT${EXISTING:+ (update of $EXISTING)}"
  if [ "$YES" = 1 ]; then
    echo "+ ${DT[*]} apply -f $WF_OUT -o json"
    APPLY_OUT=$("${DT[@]}" apply -f "$WF_OUT" -o json 2>&1) || { echo "$APPLY_OUT"; exit 1; }
    echo "$APPLY_OUT" | grep -E '"(action|id|name)"' || echo "$APPLY_OUT"
    WF_ID=$(printf '%s' "$APPLY_OUT" | python3 -c 'import json,sys,re
raw=sys.stdin.read(); m=re.search(r"\{.*\}", raw, re.S)
d=json.loads(m.group(0)) if m else {}; d=d.get("result",d); print(d.get("id",""))')
    [ -n "$WF_ID" ] || { echo "could not read workflow id from apply output" >&2; exit 1; }
    # stamp the id into the rendered file ourselves (dtctl --write-id does not write JSON files back) => next apply updates in place
    python3 -c 'import json,sys; f=sys.argv[1]; d=json.load(open(f)); d["id"]=sys.argv[2]; json.dump(d, open(f,"w"), indent=2)' "$WF_OUT" "$WF_ID"
  else
    echo "+ ${DT[*]} apply -f $WF_OUT -o json"
    WF_ID="${EXISTING:-}"
  fi
  echo "   workflow id: ${WF_ID:-(assigned on apply)}"
fi

# ---- 4. run once + verify ----------------------------------------------------
echo "== 4/4 verify"
if [ "$RUN_NOW" = 1 ] && [ -n "${WF_ID:-}" ]; then
  run "${DT[@]}" exec workflow "$WF_ID" --wait --show-results --timeout 5m
  echo "   task logs: dtctl logs workflow-execution <execution id> ${CTX:+--context $CTX}"
fi
cat <<Q
+ dtctl query 'fetch bizevents, from: now() - 2d | filter event.type == "claude.usage.daily" | summarize events = count(), developers = countDistinct(user.email), usd = sum(cost_usd), by: {source}'
Q
echo "== done ($([ "$YES" = 1 ] && echo applied || echo dry run))"
