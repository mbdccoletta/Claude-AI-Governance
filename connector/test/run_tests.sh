#!/usr/bin/env bash
# End-to-end local test: mock Anthropic + mock Dynatrace sink, Node adapters, CSV importer.
# No tenant, no real key, no network beyond 127.0.0.1. Output is tee'd to test/test.log.
#
# The automation-utils shim reads the workflow INPUT from WF_INPUT and the run PARAMS from WF_PARAMS, mirroring
# execution().input / execution().params. org_type, credential_*, anthropic_base_url come from WF_INPUT only (see
# workflow/tasks/resolve_config.js); the mock base URL needs allow_custom_base_url=true, exactly as a tenant would.
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

# workflow input for the mock: credential + base URL are input-only, allow_custom_base_url unlocks the loopback URL
input_json() { # $1 = org_type, $2 = extra JSON fields (optional, without braces)
  printf '{"org_type":"%s","credential_id":"%s","anthropic_base_url":"%s","allow_custom_base_url":true%s}' "$1" "${CRED_ID-CREDENTIALS_VAULT-MOCK}" "$DT_MOCK_URL" "${2:+,$2}"
}
# run the task chain, print its output, and keep the RESULT lines in $RESULTS for assertions
run_chain() { RESULTS=$(node "$HERE/run_task.mjs" "$@" 2>&1 | tee /dev/stderr | grep '^RESULT ' || true); }
result_of() { printf '%s\n' "$RESULTS" | sed -n "s/^RESULT $1 ([0-9]* ms): //p"; }
assert_json() { # $1 = json, $2 = python expression over d, $3 = message
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); ok=eval(sys.argv[2]); print(("ASSERT_OK  " if ok else "ASSERT_FAIL") + " " + sys.argv[3]); sys.exit(0 if ok else 1)' "$1" "$2" "$3"
}

{
  echo "=== dt-ai-observability-claude connector — local test run $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "node $(node --version), $(python3 --version), mock=$DT_MOCK_URL"
  echo

  echo "--- [1/9] enterprise adapter (org_type=enterprise, 10-day window, cost+usage, 2 pages each, 429 on first call) ---"
  WF_INPUT="$(input_json enterprise '"enterprise_lookback_days":10')" run_chain resolve_config enterprise_analytics console_claude_code team_reminder
  R=$(result_of enterprise_analytics)
  assert_json "$R" 'd["partial"] is False and d["ingested"] == d["events"] and d["events"] > 0 and d["flushes"] == 1' "full run: partial=false, every accumulated entry ingested exactly once"
  echo
  echo "--- requests not doubled: sink enterprise_api events vs the mock's user_usage_report (cost rows carry requests too) ---"
  curl -s "$DT_MOCK_URL/_sink" | python3 -c '
import json, sys, urllib.request
from datetime import datetime, timedelta, timezone
from urllib.parse import urlencode
base = sys.argv[1]
today = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
params = [("starting_at", (today - timedelta(days=10)).strftime("%Y-%m-%dT%H:%M:%S.000Z")), ("ending_at", today.strftime("%Y-%m-%dT%H:%M:%S.000Z")),
          ("bucket_width", "1d"), ("group_by[]", "product"), ("group_by[]", "model"), ("limit", "1000"), ("exclude_deleted_users", "false")]
PRODUCT = {"chat": "chat", "chat_cowork_unified": "chat", "claude_code": "claude_code", "cowork": "cowork", "claude_design": "design", "api": "api"}
def fetch(page=None):
    q = params + ([("page", page)] if page else [])
    req = urllib.request.Request(f"{base}/v1/organizations/analytics/user_usage_report?{urlencode(q)}", headers={"x-api-key": "sk-ant-mock", "anthropic-version": "2023-06-01"})
    return json.load(urllib.request.urlopen(req))
expected, page, pages = {}, None, 0
while True:
    body = fetch(page); pages += 1
    for r in body["data"]:
        a = r["actor"]; k = (a.get("email_address") or "user:" + a["user_id"], PRODUCT.get(r["product"], "other"), r["model"], r["starting_at"][:10])
        expected[k] = expected.get(k, 0) + r["requests"]
    if not body.get("has_more"): break
    page = body["next_page"]
ev = [e for e in json.load(sys.stdin) if e["source"] == "enterprise_api"]
bad, matched, cost_only = [], 0, 0
for e in ev:
    k = (e["user.email"] or "user:" + str(e.get("user.id")), e["product"], e["model"], e["usage.date"])
    exp = expected.get(k)
    if exp is None:
        cost_only += 1
        if e["requests"] is not None: bad.append((k, e["requests"], None))
    else:
        matched += 1
        if e["requests"] != exp: bad.append((k, e["requests"], exp))
print(f"usage rows: {sum(1 for _ in expected)} keys over {pages} pages; sink events: {len(ev)} (matched {matched}, cost-only {cost_only} with requests=null); mismatches: {len(bad)}")
for b in bad[:5]: print("  MISMATCH", b)
print("REQUESTS_OK" if not bad and matched else "REQUESTS_FAIL"); sys.exit(1 if bad or not matched else 0)' "$DT_MOCK_URL"
  echo

  echo "--- [2/9] console adapter (org_type=console, credential looked up by NAME, 3 days claude_code + messages by model+workspace) ---"
  CRED_ID="" WF_INPUT="$(input_json console '"console_lookback_days":3')" run_chain resolve_config enterprise_analytics console_claude_code team_reminder
  R=$(result_of console_claude_code)
  assert_json "$R" 'd["partial"] is False and d["ingested"] == d["events"] and d["events"] > 0' "full run: partial=false, every accumulated entry ingested"
  echo

  echo "--- [3/9] team no-op task (org_type=team) ---"
  WF_INPUT='{"org_type":"team","credential_id":""}' run_chain resolve_config enterprise_analytics console_claude_code team_reminder
  echo

  echo "--- [4/9] resolve_config guards: params cannot override credential/base URL; org_type must come from input; base URL pinned ---"
  WF_INPUT='{"org_type":"team"}' WF_PARAMS='{"anthropic_base_url":"http://127.0.0.1:1/evil","credential_id":"CREDENTIALS_VAULT-ATTACKER","credential_name":"other","org_type":"enterprise","dry_run":true,"console_lookback_days":99}' \
    run_chain resolve_config
  R=$(result_of resolve_config)
  assert_json "$R" 'd["anthropic_base_url"] == "https://api.anthropic.com" and d["credential_id"] == "" and d["credential_name"] == "Anthropic team usage API key" and d["org_type"] == "team" and d["dry_run"] is True and d["console_lookback_days"] == 31 and d["ingest_batch_size"] == 500' \
    "params ignored for base URL/credential/org_type; dry_run and lookback (clamped to 31) honoured"
  if WF_INPUT='{}' WF_PARAMS='{"org_type":"enterprise"}' node "$HERE/run_task.mjs" resolve_config >"$HERE/.guard.out" 2>&1; then echo "ASSERT_FAIL missing org_type in input was accepted"; exit 1; fi
  grep -q "workflow input org_type is missing" "$HERE/.guard.out" || { echo "ASSERT_FAIL unexpected error for missing org_type:"; cat "$HERE/.guard.out"; exit 1; }
  echo "ASSERT_OK   missing org_type in input fails fast ($(grep -o 'org_type is missing[^.]*' "$HERE/.guard.out" | head -1))"
  if WF_INPUT="{\"org_type\":\"enterprise\",\"anthropic_base_url\":\"$DT_MOCK_URL\"}" node "$HERE/run_task.mjs" resolve_config >"$HERE/.guard.out" 2>&1; then echo "ASSERT_FAIL custom base URL accepted without allow_custom_base_url"; exit 1; fi
  grep -q "anthropic_base_url must start with https://api.anthropic.com" "$HERE/.guard.out" || { echo "ASSERT_FAIL unexpected error for custom base URL:"; cat "$HERE/.guard.out"; exit 1; }
  echo "ASSERT_OK   custom base URL rejected without allow_custom_base_url"
  if WF_INPUT='{"org_type":"enterprise","anthropic_base_url":"https://api.anthropic.com.evil.example/"}' node "$HERE/run_task.mjs" resolve_config >"$HERE/.guard.out" 2>&1; then echo "ASSERT_FAIL look-alike host accepted"; exit 1; fi
  echo "ASSERT_OK   look-alike host https://api.anthropic.com.evil.example rejected"
  WF_INPUT='{"org_type":"team","ingest_batch_size":99999,"time_budget_ms":1}' run_chain resolve_config
  assert_json "$(result_of resolve_config)" 'd["ingest_batch_size"] == 1000 and d["time_budget_ms"] == 2000' "ingest_batch_size clamped to 1000, time_budget_ms clamped to the 2 s floor"
  rm -f "$HERE/.guard.out"
  echo

  echo "--- [5/9] time budget, enterprise: 40 small pages per report, one Retry-After: 20 on the 3rd page, time_budget_ms=12000 ---"
  curl -sf -X POST "$DT_MOCK_URL/_reset" >/dev/null
  curl -sf -X POST "$DT_MOCK_URL/_config" -d '{"pages":40,"slow":true}' >/dev/null
  WF_INPUT="$(input_json enterprise '"time_budget_ms":12000')" run_chain resolve_config enterprise_analytics
  R=$(result_of enterprise_analytics)
  assert_json "$R" 'd["partial"] is True and "reason" in d and d["ingested"] > 0 and d["flushes"] >= 1 and d["cost_pages"] == 2 and d["usage_pages"] >= 1 and d["elapsed_ms"] < 12000 + 4000' \
    "partial=true with a reason, events ingested before the deadline, 20 s Retry-After not slept (cost stopped at 2 pages), usage still paged"
  SINK=$(curl -s "$DT_MOCK_URL/_stats")
  assert_json "$SINK" 'd["by_source"].get("enterprise_api", 0) > 0' "sink holds enterprise_api events from the partial run"
  echo

  echo "--- [6/9] time budget, console: 1-row pages, time_budget_ms=8000 -> stops between day chains, partial with events ---"
  curl -sf -X POST "$DT_MOCK_URL/_reset" >/dev/null
  curl -sf -X POST "$DT_MOCK_URL/_config" -d '{"pages":40,"slow":false}' >/dev/null
  CRED_ID="" WF_INPUT="$(input_json console '"console_lookback_days":3,"time_budget_ms":8000')" run_chain resolve_config console_claude_code
  R=$(result_of console_claude_code)
  assert_json "$R" 'd["partial"] is True and d["ingested"] > 0 and d["claude_code_pages"] >= 3 and d["elapsed_ms"] < 8000 + 4000' "partial=true, events ingested, finished shortly after the 8 s budget"
  curl -sf -X POST "$DT_MOCK_URL/_reset" >/dev/null
  echo

  echo "--- [7/9] accumulator unit checks: requests from usage rows only; ingest batches split by count and by bytes ---"
  node --input-type=module -e '
    const src = (await import("node:fs")).readFileSync(process.argv[1], "utf8");
    const m = await import("data:text/javascript," + encodeURIComponent(src + "\nexport { makeAccumulator, ingestEvents, flushReserveMs };"));
    const acc = m.makeAccumulator();
    const base = { email: "a@x", product: "claude_code", model: "m", date: "2026-10-01", source: "enterprise_api" };
    acc.add({ ...base, costUsd: 1.5, requests: null, tokensInput: 0 });   // cost row (the API also returns requests here; the task passes null)
    acc.add({ ...base, costUsd: null, requests: 10, tokensInput: 100 });   // usage row
    acc.add({ ...base, costUsd: null, requests: 5, tokensInput: 50 });     // second usage row, same key
    const v = acc.values()[0];
    const ok1 = v.requests === 15 && v.tokensInput === 150 && v.costUsd === 1.5 && acc.size === 1;
    console.log((ok1 ? "ASSERT_OK  " : "ASSERT_FAIL") + ` accumulator: requests=${v.requests} (expected 15, not 30), tokensInput=${v.tokensInput}, costUsd=${v.costUsd}`);
    const d1 = acc.takeDirty().length, d2 = acc.takeDirty().length; acc.add({ ...base, requests: 1 }); const d3 = acc.takeDirty().length;
    console.log(((d1 === 1 && d2 === 0 && d3 === 1) ? "ASSERT_OK  " : "ASSERT_FAIL") + ` dirty tracking: ${d1},${d2},${d3} (expected 1,0,1)`);
    const sizes = []; const client = { ingest: async ({ body }) => { sizes.push(body.length); } };
    const big = Array.from({ length: 1200 }, (_, i) => ({ "event.type": "t", i, pad: "x".repeat(10_000) }));
    const sent = await m.ingestEvents(big, { businessEventsClient: client, batchSize: 500, maxBatchBytes: 1024 * 1024, log: () => {} });
    const ok3 = sent === 1200 && sizes.every((n) => n <= 104) && sizes.length >= 12;
    console.log((ok3 ? "ASSERT_OK  " : "ASSERT_FAIL") + ` ingest split by bytes: ${sizes.length} batches of <= ${Math.max(...sizes)} events for 1200 x 10 KB with a 1 MiB cap (sent ${sent})`);
    const small = Array.from({ length: 1001 }, (_, i) => ({ "event.type": "t", i })); sizes.length = 0;
    await m.ingestEvents(small, { businessEventsClient: client, batchSize: 500, log: () => {} });
    console.log(((sizes.join(",") === "500,500,1") ? "ASSERT_OK  " : "ASSERT_FAIL") + ` ingest split by count: ${sizes.join(",")} (expected 500,500,1)`);
    console.log(((m.flushReserveMs(95000) === 15000 && m.flushReserveMs(12000) === 3000 && m.flushReserveMs(2000) === 1000) ? "ASSERT_OK  " : "ASSERT_FAIL") + " flush reserve: 15 s at 95 s, 3 s at 12 s, 1 s floor");
    if (!(ok1 && ok3 && d1 === 1 && d2 === 0 && d3 === 1)) process.exit(1);' "$ROOT/workflow/lib/common.js"
  echo

  echo "--- [8/9] CSV importer --dry-run (first 2 events shown) ---"
  python3 "$ROOT/csv-import/import_team_spend.py" --csv "$ROOT/csv-import/sample.csv" --date 2026-10-18 --org-id org_team_demo --dry-run \
    | python3 -c 'import json,sys; ev=json.load(sys.stdin); print(json.dumps(ev[:2], indent=2)); print(f"... {len(ev)} events total")'
  echo

  echo "--- [9/9] CSV importer -> mock sink (after the enterprise + console full runs are replayed into the sink) ---"
  WF_INPUT="$(input_json enterprise)" node "$HERE/run_task.mjs" resolve_config enterprise_analytics >/dev/null
  CRED_ID="" WF_INPUT="$(input_json console)" node "$HERE/run_task.mjs" resolve_config console_claude_code >/dev/null
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

  echo "--- dashboard builder structural checks (dedup rule, UTC formatTimestamp, coverage filters) ---"
  python3 "$ROOT/dashboard/build.py" --check
  echo
  echo "=== ALL TESTS PASSED ==="
} 2>&1 | sed "s#$ROOT#connector#g" | tee "$LOG"   # no local absolute paths in the committed log
