# Bizevent schema — `claude.usage.daily`

One business event per **(user, product, model, UTC day, source)**. Written by the Workflow tasks (Enterprise and Console
adapters) and by `csv-import/import_team_spend.py` (Team). Stored in Grail as `fetch bizevents`.

## Required fields

| Field | Type | Values / notes |
|---|---|---|
| `event.type` | string | always `claude.usage.daily` |
| `event.provider` | string | `dt-ai-observability-claude` |
| `schema.version` | string | `1.0` |
| `user.email` | string \| null | Developer e-mail. Console API-key actors: `apikey:<api_key_name>`. Console org-level API rows (`product=api`): `null`. Enterprise deleted/system accounts: `null` (see `user.id`). |
| `product` | string | normalised enum `chat` \| `claude_code` \| `cowork` \| `design` \| `api` \| `other` (mapping below) |
| `model` | string | Anthropic model id, e.g. `claude-opus-5-5`; `unknown` when the source does not break down by model |
| `tokens.input` | long | uncached input tokens |
| `tokens.output` | long | output tokens |
| `tokens.cache_read` | long | cache read input tokens (0 for Team CSV: not exported) |
| `tokens.cache_creation` | long | cache creation tokens, 5 m + 1 h buckets summed (0 for Team CSV) |
| `tokens.total` | long | sum of the four above (convenience) |
| `requests` | long \| null | API/message requests; `null` when the source does not expose it (Console `claude_code`, `api`) |
| `cost_usd` | double \| null | USD. Anthropic amounts arrive as decimal strings in cents and are divided by 100. `null` for Console `product=api` rows (that endpoint has no cost) |
| `source` | string | `enterprise_api` \| `console_api` \| `team_csv` |
| `usage.date` | string | UTC day `yyyy-MM-dd` the usage belongs to (NOT the ingest time) |
| `usage.timestamp` | string | `usage.date` + `T00:00:00Z`, for `toTimestamp()` in charts |
| `usage.complete` | boolean \| null | `true` when the day is complete per the source (Enterprise: day end ≤ `data_refreshed_at`; Console: day < today); `null` when unknown |
| `org.id` | string \| null | Anthropic organization id when the API returns it, else the `org_id` workflow input |
| `dedup.key` | string | idempotency key: first 32 hex chars of `SHA-256("email|product|model|date|source")` |

`dedup.key` details: `email` is `user.email`, or a stable fallback when it is null (`user:<user_id>` for Enterprise deleted
accounts, `workspace:<workspace_id or default>` for Console `api` rows, `unknown` for Team rows without e-mail). The
implementation is identical in `workflow/lib/common.js` and `csv-import/import_team_spend.py` (parity is asserted by the test).

## Optional fields (per source)

| Field | Source | Meaning |
|---|---|---|
| `product.raw` | all | Anthropic's product value before normalisation (`chat_cowork_unified`, `claude_design`, …) |
| `user.id` | enterprise, team | Anthropic `actor.user_id` / Team `account UUID` |
| `cost.list_usd`, `cost.currency` | enterprise | pre-discount list price |
| `cost.gross_usd`, `model.family` | team | gross spend and model family from the CSV |
| `data.refreshed_at` | enterprise | `data_refreshed_at` watermark of the API response |
| `tools.web_search_requests` | enterprise, console api | server tool use |
| `api.workspace_id` | console api | Console workspace (`null` = default workspace) |
| `actor.type` | console | `user_actor` \| `api_actor` |
| `claude_code.*` | console | `sessions`, `commits`, `pull_requests`, `lines_added`, `lines_removed`, `tool_accepted`, `tool_rejected`, `terminal_types[]`, `remote`, `customer_type`, `subscription_type`. These are **actor-day** metrics copied onto every model row of that actor-day. Aggregate them with `takeAny()`/`max()` per `(user.email, usage.date)`, never `sum()` across models. |

## Product mapping

| Anthropic value | `product` |
|---|---|
| `chat`, `chat_cowork_unified`, `claude-tag`, `claude_in_chrome` | `chat` |
| `claude_code`, `claude code` | `claude_code` |
| `cowork`, `office_agent` | `cowork` |
| `claude_design`, `design` | `design` |
| `api` (Console `usage_report/messages`) | `api` |
| anything else | `other` (check `product.raw`) |

## Timestamps and dedup

* The bizevent `timestamp` is the **ingest time**. The connector re-reads the last 10 days (Enterprise) / 3 days (Console)
  every run because Anthropic revises cost values until ~7 days after month end, so the same `dedup.key` is ingested
  several times. Bizevent ingest is append-only: there is no upsert.
* Always dedupe in DQL, newest record wins:

```dql
fetch bizevents, from: now() - 45d
| filter event.type == "claude.usage.daily"
| filter usage.date >= formatTimestamp(now() - 30d, format: "yyyy-MM-dd")
| dedup dedup.key, sort: {timestamp desc}
```

* Filter on `usage.date` (the day the usage belongs to), not on `timestamp`. Give `fetch` a `from:` wider than the
  analysed window (ingest happens 1–10 days after the usage day) — the queries in `dql/` use `now() - 45d` for a 30-day view.
* To chart by usage day: `| fieldsAdd day = toTimestamp(usage.timestamp)` then `summarize ... by: {day}` or `makeTimeseries ..., time: toTimestamp(usage.timestamp)`.

## Example

```json
{
  "event.type": "claude.usage.daily",
  "event.provider": "dt-ai-observability-claude",
  "schema.version": "1.0",
  "user.email": "alice@example.com",
  "product": "claude_code",
  "product.raw": "claude_code",
  "model": "claude-opus-5-5",
  "tokens.input": 61964,
  "tokens.output": 16216,
  "tokens.cache_read": 363233,
  "tokens.cache_creation": 4275,
  "tokens.total": 445688,
  "requests": null,
  "cost_usd": 45.67,
  "source": "console_api",
  "usage.date": "2026-10-18",
  "usage.timestamp": "2026-10-18T00:00:00Z",
  "usage.complete": true,
  "org.id": "org_mock01",
  "dedup.key": "15ffabccbda0704d2a71f01d2ba32e89",
  "actor.type": "user_actor",
  "claude_code.sessions": 7,
  "claude_code.commits": 9
}
```

The example's `dedup.key` is `sha256("alice@example.com|claude_code|claude-opus-5-5|2026-10-18|console_api")[:32]`.

Prompts, completions and file contents are never collected by this layer: the sources are aggregate billing/usage APIs.
