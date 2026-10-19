#!/usr/bin/env bash
# End-to-end local test: mock Anthropic + mock Dynatrace sink, Node adapters, CSV importer.
# No tenant, no real key, no network beyond 127.0.0.1. Output is tee'd to test/test.log.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PORT="${MOCK_PORT:-8787}"
export DT_MOCK_URL="http://127.0.0.1:$PORT"
export MOCK_ANTHROPIC_KEY="sk-ant-mock-key-not-real"
LOG="$HERE/test.log"

python3 "$ROOT/workflow/build.py" >/dev/null
python3 "$HERE/mock_server.py" --port "$PORT" 2>"$HERE/mock_server.stderr" &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null || true' EXIT
for i in $(seq 1 30); do curl -sf "$DT_MOCK_URL/_stats" >/dev/null 2>&1 && break; sleep 0.2; done
curl -sf -X POST "$DT_MOCK_URL/_reset" >/dev/null

{
  echo "=== dt-ai-observability-claude connector — local test run $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "node $(node --version), $(python3 --version), mock=$DT_MOCK_URL"
  echo

  echo "--- [1/5] enterprise adapter (org_type=enterprise, 10-day window, cost+usage, 2 pages each, 429 on first call) ---"
  WF_PARAMS='{"org_type":"enterprise","credential_id":"CREDENTIALS_VAULT-MOCK","anthropic_base_url":"'"$DT_MOCK_URL"'","enterprise_lookback_days":10}' \
    node "$HERE/run_task.mjs" resolve_config enterprise_analytics console_claude_code team_reminder
  echo

  echo "--- [2/5] console adapter (org_type=console, credential looked up by NAME, 3 days claude_code + messages by model+workspace) ---"
  WF_PARAMS='{"org_type":"console","credential_id":"","anthropic_base_url":"'"$DT_MOCK_URL"'","console_lookback_days":3}' \
    node "$HERE/run_task.mjs" resolve_config enterprise_analytics console_claude_code team_reminder
  echo

  echo "--- [3/5] team no-op task (org_type=team) ---"
  WF_PARAMS='{"org_type":"team","credential_id":""}' \
    node "$HERE/run_task.mjs" resolve_config enterprise_analytics console_claude_code team_reminder
  echo

  echo "--- [4/5] CSV importer --dry-run (first 2 events shown) ---"
  python3 "$ROOT/csv-import/import_team_spend.py" --csv "$ROOT/csv-import/sample.csv" --date 2026-10-18 --org-id org_team_demo --dry-run \
    | python3 -c 'import json,sys; ev=json.load(sys.stdin); print(json.dumps(ev[:2], indent=2)); print(f"... {len(ev)} events total")'
  echo

  echo "--- [5/5] CSV importer -> mock sink ---"
  DT_INGEST_TOKEN=dt0c01.MOCK.TOKEN python3 "$ROOT/csv-import/import_team_spend.py" \
    --csv "$ROOT/csv-import/sample.csv" --date 2026-10-18 --org-id org_team_demo --tenant "$DT_MOCK_URL"
  echo

  echo "--- dedup.key parity (Python importer vs JS common.js) for (alice@example.com, chat, claude-sonnet-5-5, 2026-10-18, team_csv) ---"
  PY_KEY=$(python3 -c 'import sys; sys.path.insert(0, "'"$ROOT"'/csv-import"); import import_team_spend as m; print(m.dedup_key("alice@example.com","chat","claude-sonnet-5-5","2026-10-18","team_csv"))')
  JS_KEY=$(node --input-type=module -e '
    const src = (await import("node:fs")).readFileSync("'"$ROOT"'/workflow/lib/common.js","utf8");
    const mod = await import("data:text/javascript," + encodeURIComponent(src + "\nexport { dedupKey };"));
    console.log(await mod.dedupKey({email:"alice@example.com",product:"chat",model:"claude-sonnet-5-5",date:"2026-10-18",source:"team_csv"}));')
  echo "python: $PY_KEY"
  echo "node:   $JS_KEY"
  [ "$PY_KEY" = "$JS_KEY" ] && echo "PARITY_OK" || { echo "PARITY_MISMATCH"; exit 1; }
  echo

  echo "--- sink summary ---"
  curl -s "$DT_MOCK_URL/_stats" | python3 -c '
import json,sys; s=json.load(sys.stdin)
print("events received:", s["events"]); print("by source:", json.dumps(s["by_source"])); print("by product:", json.dumps(s["by_product"]))
from collections import Counter
c=Counter((r["method"],r["path"].split("?")[0],r["status"]) for r in s["requests"])
print("requests to mock (method, path, status, count):")
for (m,p,st),n in sorted(c.items()): print(f"  {m:4} {st} {n:3}  {p}")'
  echo
  echo "--- one sample event per source ---"
  curl -s "$DT_MOCK_URL/_sink" | python3 -c '
import json,sys; ev=json.load(sys.stdin); seen=set()
for e in ev:
    if e["source"] in seen: continue
    seen.add(e["source"]); print(json.dumps(e, indent=2))'
  echo
  echo "--- schema checks over all sink events ---"
  curl -s "$DT_MOCK_URL/_sink" | python3 -c '
import json,sys,re; ev=json.load(sys.stdin)
req=["event.type","user.email","product","model","tokens.input","tokens.output","tokens.cache_read","tokens.cache_creation","requests","cost_usd","source","usage.date","org.id","dedup.key"]
bad=[e for e in ev if any(k not in e for k in req)]
badtype=[e for e in ev if e["event.type"]!="claude.usage.daily"]
badkey=[e for e in ev if not re.fullmatch(r"[0-9a-f]{32}", e["dedup.key"])]
baddate=[e for e in ev if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", e["usage.date"])]
badprod=[e for e in ev if e["product"] not in {"chat","claude_code","cowork","design","api","other"}]
dups=len(ev)-len({e["dedup.key"] for e in ev})
print(f"events={len(ev)} missing_fields={len(bad)} bad_event_type={len(badtype)} bad_dedup_key={len(badkey)} bad_date={len(baddate)} bad_product={len(badprod)} duplicate_keys_in_single_run={dups}")
api=[e for e in ev if e["product"]=="api"]; ak=[e for e in ev if str(e["user.email"]).startswith("apikey:")]
print(f"api rows (user.email null, api.workspace_id set): {len(api)}; api_actor rows (user.email apikey:*): {len(ak)}")
print("SCHEMA_OK" if not (bad or badtype or badkey or baddate or badprod or dups) else "SCHEMA_FAIL"); sys.exit(1 if (bad or badtype or badkey or baddate or badprod or dups) else 0)'
  echo
  echo "=== ALL TESTS PASSED ==="
} 2>&1 | tee "$LOG"
