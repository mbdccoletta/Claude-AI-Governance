---
name: import-team-csv
description: Import the claude.ai Team plan spend CSV into Dynatrace as claude.usage.daily business events (layer 3 of dt-ai-observability-claude, source=team_csv) with the one-command wrapper connector/csv-import/import-team-csv.sh / .ps1. Use when asked to import, load, upload or send the Team CSV / spend export / "planilha do Team" to Dynatrace, or when the Team workflow reminder says the CSV is due.
---

# Import the claude.ai Team spend CSV (layer 3)

Claude **Team** plans have no usage API. The admin exports a spend CSV from claude.ai (Settings → Analytics → export spend CSV) and
this skill turns it into `claude.usage.daily` business events in the tenant, same schema and dashboard as the Enterprise and Console
sources. Everything after the export is one command; your job is to find the file, confirm the usage day, run the wrapper, and verify.

## Hard rules

- Never ask for, type or paste a Dynatrace token or an Anthropic key. Prefer the **dtctl** delivery (the user's own login); if a token
  is needed, the user types it into the wrapper's hidden prompt themselves (`--save-token` keeps it in the OS credential store).
- Never edit the CSV. If it does not look like the claude.ai spend export, say which columns are missing and stop.
- Do not invent the usage day. The export covers up to **yesterday (UTC)**; that is the wrapper's default. Ask only when the user gives
  a file older than two days or says the export is for another period.
- Preview first, send only after the user says yes (the wrapper asks; pass `--yes` only when the user already approved in chat).
- Re-importing the same day is safe (`dedup.key` overwrites); importing an export under the wrong day is not (it creates a second day).

## Steps

1. **Locate the file.** Usually `~/Downloads/*.csv` just exported from claude.ai. Confirm the path with the user if more than one candidate.
2. **Preview** (no network, no credentials):
   ```bash
   connector/csv-import/import-team-csv.sh ~/Downloads/spend-export.csv --dry-run            # default day = yesterday UTC
   connector/csv-import/import-team-csv.sh ~/Downloads/spend-export.csv --date 2026-10-18 --org-id acme --dry-run
   ```
   Windows: `connector\csv-import\import-team-csv.ps1 .\spend-export.csv -DryRun`.
   Read the preview back to the user: events, users, net spend, products, models, any warning about the file date.
3. **Send.** Same command without `--dry-run`; it picks the delivery:
   - `dtctl` installed and logged in (`dtctl config current-context`) → `dtctl exec function` with the user's session, no token.
     Force a context with `--context <name>`.
   - otherwise a token with scope `bizevents.ingest`: env `DT_BIZEVENTS_TOKEN`, the OS credential store (saved by `--save-token`), or the
     hidden prompt. Tenant comes from the layer 1/2 install (`~/.dt-ai-obs/config.env`) or `--tenant https://<env>.live.dynatrace.com`.
   Answer the `[y/N]` prompt only with the user's explicit approval.
4. **Verify** (dtctl or a notebook):
   ```
   fetch bizevents, from: now() - 1h
   | filter event.type == "claude.usage.daily" and source == "team_csv"
   | summarize events = count(), users = countDistinct(user.email), usd = sum(cost_usd), by: {usage.date, org.id}
   ```
   The layer 3 dashboard shows the rows under the chosen `usage.date`; `org.id = demo-sample` rows (the bundled `sample.csv`) are excluded.

## Cadence

One export per day, imported for the previous UTC day, keeps the dashboard continuous; a weekly export imported under its last day
gives weekly granularity. The Team workflow (`org_type = team`) only logs a daily reminder at 15:00 UTC; the "Freshness per source"
tile shows how old the latest `team_csv` day is.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `does not look like the claude.ai Team spend export` | Wrong file. Required columns: user email, product, total_prompt_tokens, total_completion_tokens, total_net_spend_usd |
| `token format invalid` | Pasted twice or with spaces: a `dt0c01.` token is 96 characters |
| `HTTP 403` on the token path | Token lacks `bizevents.ingest` (classic) / `openpipeline.events.custom` (platform endpoint) |
| `dtctl ingest failed` | Context not logged in, or the user lacks `storage:events:write`; fall back to `--token` |
| Rows show `user.email = null` | The export had empty e-mails (deleted users); they are kept and counted as unknown |
| Dashboard still empty | Check `usage.date` (the day you passed) is inside the tile window (last 30 usage days); the dashboard time picker does not apply |
