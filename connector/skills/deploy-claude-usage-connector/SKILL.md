---
name: deploy-claude-usage-connector
description: Deploy and operate layer 3 of dt-ai-observability-claude (the Claude usage connector) on a Dynatrace tenant with dtctl — outbound allowlist, credential vault, scheduled workflow, first run, DQL verification, Team CSV import. Use when asked to deploy, install, configure, re-deploy, run or verify the "Claude usage connector", "layer 3", "claude.usage.daily" bizevents or the Anthropic usage/cost import into Dynatrace.
---

# Deploy the Claude usage connector (layer 3) with dtctl

Everything lives in `connector/` of the dt-ai-observability-claude asset. The deploy is scripted; your job is to
collect the four inputs, get explicit approval, run `deploy/deploy.sh --yes`, and verify.

## Hard rules

1. **Never run anything that writes to a tenant without the user's explicit go-ahead in this conversation.**
   Default to the dry run (no `--yes`), show the plan, then ask.
2. **Never ask the user to paste the Anthropic key into the chat and never write it to a file.** The key goes into an
   env var in the user's own terminal (`export ANTHROPIC_USAGE_KEY=...`) and the script passes it straight to the
   credential vault through `dtctl exec function` (payload only). If the var is empty the script stops.
3. Confirm the target: `dtctl config current-context` — and that it is the tenant the user named. Use `--context` otherwise.
4. Prefer `--plain -o json` outputs and read ids from them; never guess ids.

## Inputs to collect

| Input | How to decide |
|---|---|
| `--org-type` | `enterprise` = Claude Enterprise org (claude.ai, usage-based plan) → Analytics API key created by the **primary owner** at claude.ai > Organization settings > API. `console` = Claude Console / Claude Platform org → **Admin API key** (`sk-ant-admin01-…`) from platform.claude.com/settings/admin-keys. `team` = Claude Team plan → no API; CSV importer only. |
| `--org-id` | free label copied to `org.id` on every event (e.g. customer short name). Optional. |
| key | `ANTHROPIC_USAGE_KEY` exported by the user (not needed for `team`). |
| context | dtctl context with scopes: `settings:objects:read/write`, credential vault write (`credentialVault:write` on the classic token or the equivalent platform scope), `automation:workflows:write`, `automation:workflows:run`, `storage:bizevents:read`. Check with `dtctl auth can-i create workflow`. |

## Procedure

```bash
cd <asset root>/connector
python3 workflow/build.py                      # rebuild workflow JSON from tasks/ + lib/ (idempotent)
./test/run_tests.sh | tail -5                  # optional: local proof against the mock (no tenant)
./deploy/deploy.sh --org-type <type> --org-id <label> [--context <ctx>]           # DRY RUN: prints the plan
# ---- ask the user for approval here ----
./deploy/deploy.sh --org-type <type> --org-id <label> [--context <ctx>] --run-now --yes
```

What `--yes` does, in order:
1. `dtctl get settings --schema builtin:dt-javascript-runtime.allowed-outbound-connections` → merge `api.anthropic.com`
   into `hostList` (existing hosts kept) → `dtctl apply`, or `dtctl create settings` when the object does not exist yet.
2. `dtctl exec function -f deploy/vault_upsert.js --payload {name, token}` → TOKEN credential, scope APP_ENGINE, returns
   `CREDENTIALS_VAULT-…` (updates in place when the name already exists).
   **Known limitation (verified 2026-10-19):** the OAuth token from `dtctl auth login` does not carry
   `environment-api:credentials:read/write`, so this step fails with 403 on OAuth contexts. Fallback: the user creates the
   Token credential in the tenant UI (Settings > Credential vault > Add credential: Token, scope *App Engine*) and passes the
   id: `CREDENTIAL_ID=CREDENTIALS_VAULT-… deploy/deploy.sh --org-type <type> --skip-vault …`. A context authenticated with a
   classic API token that has `credentialVault.read/write` makes the automatic path work.
3. `deploy/render_workflow.py` fills `input.org_type / credential_id / org_id` → `dtctl apply -f deploy/.out/claude-usage-connector.<type>.json`.
   The script reads the new id from the apply output and stamps it into the rendered file (dtctl's `--write-id` does not
   write JSON back), so later runs update the same workflow. `dtctl apply` detects workflows from JSON fine (verified).
   The schedule trigger must not carry plain `inputs` values (API 400: expects ScheduleInput objects); the workflow-level
   `input` object is the configuration source.
4. `--run-now`: `dtctl exec workflow <id>`; then `dtctl logs workflow-execution <execution id>` to read the task logs
   (`[enterprise] …` / `[console] …` lines include pages, rows, events, api_calls).

## Credential by name (no vault API scope needed)

Verified on a real tenant (2026-10-19): the Run JavaScript task can list the vault (`credentialVaultClient.listCredentials`)
and read the entry, so the workflow input `credential_name` is enough — no id handling. Default name is
`Anthropic <org_type> usage API key`. When creating the credential in the UI (Settings > Credential vault > Add new credential):
Credential type **Token**, that exact **Name**, Credential scope **AppEngine** (leaves "Dynatrace apps with access" = All applications),
toggle **Allow access without app context, for example, from ad hoc functions in Workflows** ON, **Owner access only** ON
(the owner must be the workflow owner; the UI refuses the toggle ON + owner-only OFF + empty user list). Paste the Anthropic key in **Token**.
Claude must not type the key itself; it can fill every other field in the user's browser and let the user paste + Save.

## One-off runs with other inputs

`dtctl exec workflow <id> --input '{"console_lookback_days": 31}' --wait --show-results` — run params override the workflow
input for that execution only (resolve_config merges defaults <- input <- params). Task result fields: `api_calls`, pages, rows,
`events`, `ingested`. `events: 0` with all calls OK means the org had no usage in the window (verified: 32 calls, 0 rows on an idle org).

## Closed-bucket semantics (why "today" looks empty)

`usage_report/messages` never returns an open bucket: with `bucket_width=1d` the current UTC day is absent regardless of
`ending_at`. The console task therefore reads past days as 1d buckets and today as 1h buckets (closed hours). A request made
at 22:18Z becomes visible when the 22:00–23:00 bucket closes, i.e. right after 23:00Z. `usage_report/claude_code` is a daily
aggregate and typically lags about an hour. `dtctl exec workflow <id> --input '{"console_debug": true}'` returns the bucket
list the task saw (no secrets) when you need to prove where the data is.

## Verify

```bash
dtctl query 'fetch bizevents, from: now() - 2d | filter event.type == "claude.usage.daily" | summarize events = count(), developers = countDistinct(user.email), usd = sum(cost_usd), by: {source}'
dtctl query -f dql/cost-per-developer-30d.dql
```

Expected first-run volume: Enterprise ≈ users × products × models × 10 days; Console ≈ actors × models × 3 days
(+ models × workspaces × 3 for `product=api`). Zero events with a successful execution usually means the org has no
usage in the window, or (Enterprise) the plan is seat-based and the cost endpoints only reflect usage credits.

## Common failures

| Symptom | Cause / fix |
|---|---|
| task log `HTTP 401` from api.anthropic.com | wrong key type for the org (Admin key on an Enterprise org or vice-versa) or key revoked |
| external fetch fails silently / `TypeError: fetch failed` | `api.anthropic.com` missing from the outbound allowlist → re-run step 1 |
| `credential_id is empty` | workflow input not filled → re-run deploy (it re-renders the JSON) |
| `HTTP 400 … cursor` | params changed mid-pagination; the client freezes params, so this points to a modified task script |
| `HTTP 429` repeating | 60 req/min org-wide budget shared with other consumers; the client backs off, lower `enterprise_lookback_days` if needed |
| events present but DQL shows duplicates | missing `dedup dedup.key, sort: {timestamp desc}` — ingest is append-only by design |

## Team plan (CSV)

No workflow data. Each period: export the spend CSV from claude.ai > Settings > Analytics, then
`DT_INGEST_TOKEN=<token with bizevents.ingest> python3 csv-import/import_team_spend.py --csv <file> --date <period end YYYY-MM-DD> --tenant https://<env>.live.dynatrace.com`
(`--dry-run` first). The workflow (`org_type=team`) only logs this reminder daily.

## Removal

`dtctl delete workflow <id>`; remove the vault entry from Settings > Credential vault (or via API); remove `api.anthropic.com`
from the allowlist only if nothing else uses it. Bizevents already ingested stay until bucket retention expires.
