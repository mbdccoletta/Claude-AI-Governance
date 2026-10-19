// Task 2/4 — enterprise_analytics (org_type = enterprise)
// Source: Claude Enterprise Analytics API (Analytics API key, scope read:analytics)
//   GET /v1/organizations/analytics/user_cost_report   -> per-user cost rows (amount = fractional cents string)
//   GET /v1/organizations/analytics/user_usage_report  -> per-user token rows
// Both called with bucket_width=1d, group_by[]=product,model, limit=1000, for the last N complete UTC days
// (default 10: Anthropic revises cost values until ~7 days after month end, so we re-read and let
// DQL dedup keep the newest record per dedup.key).
import { result } from "@dynatrace-sdk/automation-utils";
import { credentialVaultClient, businessEventsClient } from "@dynatrace-sdk/client-classic-environment-v2";

// @include common.js

const SOURCE = "enterprise_api";
const COST_PATH = "v1/organizations/analytics/user_cost_report";
const USAGE_PATH = "v1/organizations/analytics/user_usage_report";

export default async function () {
  const cfg = await result("resolve_config");
  if (cfg.org_type !== "enterprise") return { skipped: true, reason: `org_type=${cfg.org_type}` };

  const log = (m) => console.log(`[enterprise] ${m}`);
  const apiKey = await resolveApiKey(credentialVaultClient, cfg.credential_id, cfg.credential_name);
  const client = makeAnthropicClient({ baseUrl: cfg.anthropic_base_url, apiKey, log });

  const now = new Date();
  const startingAt = daysAgo(cfg.enterprise_lookback_days, now).toISOString();
  const endingAt = daysAgo(0, now).toISOString(); // today 00:00Z, exclusive => complete days only
  const params = {
    starting_at: startingAt,
    ending_at: endingAt,
    bucket_width: "1d",
    "group_by[]": ["product", "model"],
    limit: 1000,
    exclude_deleted_users: false,
  };
  log(`window ${startingAt} .. ${endingAt} (${cfg.enterprise_lookback_days} days)`);

  const acc = makeAccumulator();
  let refreshedAt = null;
  let orgId = cfg.org_id ?? null;
  const stats = { cost_rows: 0, usage_rows: 0, cost_pages: 0, usage_pages: 0 };

  // --- cost rows -----------------------------------------------------------
  for await (const page of client.paginate(COST_PATH, params)) {
    stats.cost_pages++;
    refreshedAt = page.data_refreshed_at ?? refreshedAt;
    orgId = orgId ?? page.organization_id ?? null;
    for (const row of page.data ?? []) {
      stats.cost_rows++;
      const day = (row.starting_at ?? startingAt).slice(0, 10);
      acc.add({
        ...actorFields(row.actor),
        product: row.product,
        model: row.model,
        date: day,
        source: SOURCE,
        costUsd: centsToUsd(row.amount),
        requests: row.requests ?? null,
        tokensInput: 0, tokensOutput: 0, tokensCacheRead: 0, tokensCacheCreation: 0,
        complete: isComplete(row.ending_at, refreshedAt),
        extra: {
          "cost.list_usd": centsToUsd(row.list_amount),
          "cost.currency": row.currency ?? "USD",
        },
        mergeExtra: (cur, inc) => { cur["cost.list_usd"] = round6((cur["cost.list_usd"] ?? 0) + (inc["cost.list_usd"] ?? 0)); },
      });
    }
  }

  // --- usage rows ----------------------------------------------------------
  for await (const page of client.paginate(USAGE_PATH, params)) {
    stats.usage_pages++;
    refreshedAt = refreshedAt ?? page.data_refreshed_at ?? null;
    orgId = orgId ?? page.organization_id ?? null;
    for (const row of page.data ?? []) {
      stats.usage_rows++;
      const day = (row.starting_at ?? startingAt).slice(0, 10);
      const cc = row.cache_creation ?? {};
      acc.add({
        ...actorFields(row.actor),
        product: row.product,
        model: row.model,
        date: day,
        source: SOURCE,
        costUsd: null,
        requests: row.requests ?? null,
        tokensInput: row.uncached_input_tokens,
        tokensOutput: row.output_tokens,
        tokensCacheRead: row.cache_read_input_tokens,
        tokensCacheCreation: toLong(cc.ephemeral_5m_input_tokens) + toLong(cc.ephemeral_1h_input_tokens),
        complete: isComplete(row.ending_at, refreshedAt),
        extra: { "tools.web_search_requests": toLong(row.server_tool_use?.web_search_requests) },
        mergeExtra: (cur, inc) => { cur["tools.web_search_requests"] = toLong(cur["tools.web_search_requests"]) + toLong(inc["tools.web_search_requests"]); },
      });
    }
  }

  // --- emit ---------------------------------------------------------------
  const events = [];
  for (const f of acc.values()) {
    events.push(await buildEvent({ ...f, orgId, extra: { ...f.extra, "data.refreshed_at": refreshedAt, "user.id": f.userId ?? null } }));
  }
  const sent = await ingestEvents(events, { businessEventsClient, batchSize: cfg.ingest_batch_size, log, dryRun: cfg.dry_run });
  const summary = { source: SOURCE, events: events.length, ingested: cfg.dry_run ? 0 : sent, api_calls: client.calls, data_refreshed_at: refreshedAt, org_id: orgId, ...stats };
  log(JSON.stringify(summary));
  return cfg.dry_run ? { ...summary, sample: events.slice(0, 3) } : summary;
}

// actor.email_address is null for deleted accounts / system service accounts: fall back to the user id
// so those rows still get a stable dedup.key and do not collapse into one "null" user.
function actorFields(actor) {
  const email = actor?.email_address ?? actor?.email ?? null;
  const userId = actor?.user_id ?? null;
  return { email, userId, keyFallback: userId ? `user:${userId}` : "unknown" };
}

function isComplete(endingAt, refreshedAt) {
  if (!endingAt || !refreshedAt) return null;
  return new Date(endingAt).getTime() <= new Date(refreshedAt).getTime();
}
