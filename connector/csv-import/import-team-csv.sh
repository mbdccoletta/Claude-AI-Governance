#!/usr/bin/env bash
# import-team-csv.sh — one-command import of the claude.ai Team spend CSV into Dynatrace (layer 3, source=team_csv).
#
# Usage:
#   connector/csv-import/import-team-csv.sh <spend-export.csv> [options]
#
# Defaults that remove the usual mistakes:
#   date      yesterday (UTC) — the day the claude.ai export covers (daily refresh, 1-day lag). Override with --date YYYY-MM-DD.
#   tenant    taken from the layer 1/2 install (~/.dt-ai-obs/config.env) when present; else --tenant / DT_TENANT_URL.
#   delivery  1) --context <dtctl context> or a current dtctl context → `dtctl exec function` with your own login, no token;
#             2) otherwise an ingest token with bizevents.ingest: env DT_BIZEVENTS_TOKEN, the OS credential store
#                (saved by --save-token), or a hidden prompt.
#   safety    a preview (events, users, USD, products, models) and a y/N confirmation before anything is sent (--yes skips it);
#             re-importing the same day overwrites through dedup.key instead of duplicating.
#
# Options:
#   --date YYYY-MM-DD    UTC day the export covers (default: yesterday)
#   --org-id <id>        label written to org.id (default: "team")
#   --tenant <url>       https://<env>.live.dynatrace.com (token delivery)
#   --context <name>     dtctl context to ingest with (dtctl delivery; default: current context when dtctl is installed)
#   --token              force token delivery even when dtctl is available
#   --save-token         store the token you type in the OS credential store for next time (macOS Keychain / secret-tool / 0600 file)
#   --yes                no confirmation prompt
#   --dry-run            preview only, send nothing
#   -h, --help
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPORTER="$HERE/import_team_spend.py"
INGEST_JS="$HERE/ingest_events.js"
INSTALL_DIR="${DT_AI_OBS_DIR:-$HOME/.dt-ai-obs}"
KC_SERVICE="dt-ai-obs-claude-bizevents"

CSV=""; DATE=""; ORG_ID="team"; TENANT="${DT_TENANT_URL:-}"; CTX=""; FORCE_TOKEN=0; SAVE_TOKEN=0; YES=0; DRY=0
usage() { awk 'NR>1 && !/^#/ {exit} NR>1 {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --date) DATE="$2"; shift 2 ;;
    --org-id) ORG_ID="$2"; shift 2 ;;
    --tenant) TENANT="$2"; shift 2 ;;
    --context) CTX="$2"; shift 2 ;;
    --token) FORCE_TOKEN=1; shift ;;
    --save-token) SAVE_TOKEN=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) [ -z "$CSV" ] && CSV="$1" || die "only one CSV file, got '$CSV' and '$1'"; shift ;;
  esac
done

command -v python3 >/dev/null || die "python3 is required"
[ -n "$CSV" ] || { usage; die "give the exported CSV file as the first argument"; }
[ -f "$CSV" ] || die "file not found: $CSV"
[ -f "$IMPORTER" ] || die "importer not found next to this script: $IMPORTER"

# ── date: yesterday UTC unless given; sanity against today and the file's age ─────────────────────────
TODAY="$(python3 -c 'import datetime as d; print(d.datetime.now(d.timezone.utc).strftime("%Y-%m-%d"))')"
[ -n "$DATE" ] || DATE="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)-d.timedelta(days=1)).strftime("%Y-%m-%d"))')"
python3 -c 'import sys,datetime as d; d.datetime.strptime(sys.argv[1], "%Y-%m-%d")' "$DATE" 2>/dev/null || die "--date must be YYYY-MM-DD (got '$DATE')"
[[ "$DATE" > "$TODAY" ]] && die "--date $DATE is in the future (today is $TODAY UTC)"
[ "$DATE" = "$TODAY" ] && warn "--date is today ($TODAY): the claude.ai export normally covers up to yesterday"
FILE_DAY="$(python3 -c 'import os,sys,datetime as d; print(d.datetime.fromtimestamp(os.path.getmtime(sys.argv[1]), d.timezone.utc).strftime("%Y-%m-%d"))' "$CSV")"
AGE_DAYS="$(python3 -c 'import sys,datetime as d; a=d.datetime.strptime(sys.argv[1],"%Y-%m-%d"); b=d.datetime.strptime(sys.argv[2],"%Y-%m-%d"); print((b-a).days)' "$DATE" "$FILE_DAY")"
if [ "$AGE_DAYS" -gt 2 ] || [ "$AGE_DAYS" -lt 0 ]; then
  warn "the file was last modified on $FILE_DAY (UTC) but --date is $DATE: check that this export really covers $DATE"
fi

# ── preview ───────────────────────────────────────────────────────────────────────────────────────────
log "Preview of $CSV for usage day $DATE (org.id=$ORG_ID)"
PREVIEW="$(python3 -I "$IMPORTER" --csv "$CSV" --date "$DATE" --org-id "$ORG_ID" --preview 2>/dev/null)" || die "the file does not look like the claude.ai Team spend export (run: python3 $IMPORTER --csv '$CSV' --date $DATE --preview)"
python3 - "$PREVIEW" <<'PY'
import json, sys
p = json.loads(sys.argv[1])
print(f"  events (user x product x model): {p['events']}   users: {p['users']}   requests: {p['requests']}   tokens: {p['tokens_total']:,}")
print(f"  net spend: US$ {p['net_spend_usd']:,.2f}   gross: US$ {p['gross_spend_usd']:,.2f}")
for prod, d in sorted(p["by_product"].items(), key=lambda kv: -kv[1]["cost_usd"]):
    print(f"    {prod:12} events={d['events']:<4} requests={d['requests']:<7} tokens={d['tokens']:<12,} US$ {d['cost_usd']:,.2f}")
print(f"  models: {', '.join(p['models'])}")
if p["rows_without_email"]:
    print(f"  note: {p['rows_without_email']} row(s) without e-mail are kept as user.email=null")
if p["unknown_products"]:
    print(f"  note: unknown product names kept as product=other: {', '.join(p['unknown_products'])}")
if p["events"] == 0:
    sys.exit("  nothing to import: the CSV has no data rows")
PY
echo "  re-importing the same day overwrites earlier rows (dedup.key); nothing is duplicated."
[ "$DRY" = 1 ] && { log "--dry-run: nothing sent"; exit 0; }

# ── delivery method ───────────────────────────────────────────────────────────────────────────────────
METHOD=""
if [ "$FORCE_TOKEN" = 0 ] && command -v dtctl >/dev/null 2>&1; then
  if [ -n "$CTX" ]; then METHOD=dtctl
  elif CUR="$(dtctl config current-context 2>/dev/null)" && [ -n "$CUR" ]; then CTX="$CUR"; METHOD=dtctl; fi
fi
if [ -z "$METHOD" ]; then
  METHOD=token
  if [ -z "$TENANT" ] && [ -f "$INSTALL_DIR/config.env" ]; then
    TENANT="$(sed -n 's/^DT_OTLP_ENDPOINT=//p' "$INSTALL_DIR/config.env" | tr -d "'\"" | sed 's#/api/v2/otlp/*$##')"
  fi
  [ -n "$TENANT" ] || die "no tenant: pass --tenant https://<env>.live.dynatrace.com (or install dtctl and log in: then no token is needed)"
  [[ "$TENANT" == https://* || "$TENANT" == http://127.0.0.1* || "$TENANT" == http://localhost* ]] || die "--tenant must be https:// (got $TENANT)"
fi

# ── confirm ───────────────────────────────────────────────────────────────────────────────────────────
if [ "$METHOD" = dtctl ]; then log "Delivery: dtctl exec function (context '$CTX', your own login; no token)"
else log "Delivery: bizevents ingest API on $TENANT (token)"; fi
if [ "$YES" != 1 ]; then
  read -r -p "Send these events to Dynatrace? [y/N] " ans
  case "$ans" in y|Y|yes|s|S|sim) ;; *) echo "aborted, nothing sent"; exit 0 ;; esac
fi

# ── send ──────────────────────────────────────────────────────────────────────────────────────────────
if [ "$METHOD" = dtctl ]; then
  [ -f "$INGEST_JS" ] || die "helper not found: $INGEST_JS"
  RES="$(python3 -I "$IMPORTER" --csv "$CSV" --date "$DATE" --org-id "$ORG_ID" --dry-run 2>/dev/null \
        | python3 -c 'import json,sys; sys.stdout.write(json.dumps({"events": json.load(sys.stdin)}))' \
        | dtctl --plain --context "$CTX" exec function -f "$INGEST_JS" --data - -o json)" || die "dtctl ingest failed (is the context logged in? does your user have storage:events:write?)"
  echo "$RES" | python3 -c 'import json,sys; r=json.load(sys.stdin); r=r.get("result", r) if isinstance(r, dict) else r; print("  result:", json.dumps(r))' 2>/dev/null || echo "$RES"
  log "Done. Check: dtctl --context $CTX query 'fetch bizevents, from:now()-1h | filter event.type == \"claude.usage.daily\" and source == \"team_csv\" | summarize count(), by:{usage.date, org.id}'"
else
  TOKEN="${DT_BIZEVENTS_TOKEN:-}"
  if [ -z "$TOKEN" ]; then
    case "$(uname -s)" in
      Darwin) TOKEN="$(/usr/bin/security find-generic-password -s "$KC_SERVICE" -w 2>/dev/null || true)" ;;
      *) if command -v secret-tool >/dev/null 2>&1; then TOKEN="$(secret-tool lookup service "$KC_SERVICE" key ingest-token 2>/dev/null || true)"; fi
         [ -z "$TOKEN" ] && [ -f "$INSTALL_DIR/bizevents-token" ] && TOKEN="$(cat "$INSTALL_DIR/bizevents-token")" ;;
    esac
  fi
  if [ -z "$TOKEN" ]; then
    [ -t 0 ] || die "no token: set DT_BIZEVENTS_TOKEN (scope bizevents.ingest) or run once with --save-token in a terminal"
    read -r -s -p "Dynatrace API token with scope bizevents.ingest (hidden): " TOKEN; echo
    [ "$SAVE_TOKEN" = 1 ] || { read -r -p "Save it in the OS credential store for next time? [y/N] " s; case "$s" in y|Y|yes|s|S|sim) SAVE_TOKEN=1 ;; esac; }
  fi
  TOKEN="$(printf '%s' "$TOKEN" | tr -d '[:space:]')"
  [[ "$TOKEN" =~ ^dt0c01\.[A-Za-z0-9]{24}\.[A-Za-z0-9]{64}$ ]] || die "token format invalid: expected dt0c01.<24 chars>.<64 chars> (got ${#TOKEN} chars; pasted twice?)"
  if [ "$SAVE_TOKEN" = 1 ]; then
    case "$(uname -s)" in
      Darwin) /usr/bin/security add-generic-password -a "$(id -un)" -s "$KC_SERVICE" -l "Dynatrace bizevents ingest token (Claude Team CSV import)" -w "$TOKEN" -U >/dev/null && log "Token saved in the macOS Keychain (service $KC_SERVICE)" ;;
      *) if command -v secret-tool >/dev/null 2>&1; then printf '%s' "$TOKEN" | secret-tool store --label="Dynatrace bizevents ingest token (Claude Team CSV import)" service "$KC_SERVICE" key ingest-token && log "Token saved in the Secret Service (service $KC_SERVICE)"
         else mkdir -p "$INSTALL_DIR"; chmod 0700 "$INSTALL_DIR"; printf '%s' "$TOKEN" > "$INSTALL_DIR/bizevents-token"; chmod 0600 "$INSTALL_DIR/bizevents-token"; log "Token saved in $INSTALL_DIR/bizevents-token (0600)"; fi ;;
    esac
  fi
  ALLOW=(); [[ "$TENANT" == http://* ]] && ALLOW=(--allow-http)
  DT_BIZEVENTS_TOKEN="$TOKEN" python3 -I "$IMPORTER" --csv "$CSV" --date "$DATE" --org-id "$ORG_ID" --tenant "$TENANT" --token-env DT_BIZEVENTS_TOKEN "${ALLOW[@]+"${ALLOW[@]}"}"
  log "Done. In Dynatrace: fetch bizevents, from:now()-1h | filter event.type == \"claude.usage.daily\" and source == \"team_csv\" | summarize count(), by:{usage.date, org.id}"
fi
