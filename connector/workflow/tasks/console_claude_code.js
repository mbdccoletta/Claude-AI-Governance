// Task 3/4 — console_claude_code (org_type = console)
// Source: Claude Console Admin API (Admin API key sk-ant-admin01-...)
//   GET /v1/organizations/usage_report/claude_code?starting_at=YYYY-MM-DD&limit=1000&page=...
//       per actor/day rows with model_breakdown[] -> product=claude_code; api_actor rows => user.email "apikey:<name>"
//   GET /v1/organizations/usage_report/messages?bucket_width=1d&group_by[]=model&group_by[]=workspace_id
//       org-level token usage -> product=api, user.email=null, api.workspace_id set (no per-user data exists here);
//       1d buckets for past days + 1h buckets for today, because the API only returns closed buckets
// Time budget: paging stops at cfg.time_budget_ms (default 95 s of the 110 s task timeout); the accumulator is flushed
// when less than the reserve is left and once at the end; the summary carries { partial: true, reason } when the
// window was not fully read (the next scheduled run re-reads the lookback window; dedup.key keeps the newest record).
import { result } from "@dynatrace-sdk/automation-utils";
import { credentialVaultClient, businessEventsClient } from "@dynatrace-sdk/client-classic-environment-v2";

// @include common.js

const SOURCE = "console_api";
const CC_PATH = "v1/organizations/usage_report/claude_code";
const MSG_PATH = "v1/organizations/usage_report/messages";

export default async function () {
  const cfg = await result("resolve_config");
  if (cfg.org_type !== "console") return { skipped: true, reason: `org_type=${cfg.org_type}` };

  const log = (m) => console.log(`[console] ${m}`);
  const apiKey = await resolveApiKey(credentialVaultClient, cfg.credential_id, cfg.credential_name);
  const deadline = Date.now() + cfg.time_budget_ms;
  const reserveMs = flushReserveMs(cfg.time_budget_ms);
  const client = makeAnthropicClient({ baseUrl: cfg.anthropic_base_url, apiKey, log, deadline });

  const now = new Date();
  const days = [];
  for (let i = 0; i < cfg.console_lookback_days; i++) days.push(utcDay(daysAgo(i, now)));
  log(`days: ${days.join(", ")}`);

  const acc = makeAccumulator();
  let orgId = cfg.org_id ?? null;
  const stats = { claude_code_rows: 0, claude_code_pages: 0, api_rows: 0, api_pages: 0, flushes: 0, ingested: 0, events_built: 0 };
  const today = utcDay(daysAgo(0, now));
  const sample = [];
  const flush = () => flushAccumulator(acc, {
    build: (f) => ({ ...f, orgId, extra: { ...f.extra, ...(f.userId ? { "user.id": f.userId } : {}) } }),
    businessEventsClient, batchSize: cfg.ingest_batch_size, log, dryRun: cfg.dry_run, stats, sampleOut: sample,
  });
  const maybeFlush = async () => { if (client.remainingMs() < reserveMs && acc.dirtySize) { log(`budget low (${client.remainingMs()} ms left): flushing ${acc.dirtySize} entries`); await flush(); } };

  // --- Claude Code per-user rows (one call chain per day) -------------------
  for (const day of days) {
    for await (const page of client.paginate(CC_PATH, { starting_at: day, limit: 1000 })) {
      stats.claude_code_pages++;
      for (const row of page.data ?? []) {
        stats.claude_code_rows++;
        orgId = orgId ?? row.organization_id ?? null;
        const rowDay = (row.date ?? day).slice(0, 10);
        const actor = row.actor ?? {};
        const who = actorFields(actor);
        const cm = row.core_metrics ?? {};
        for (const mb of row.model_breakdown ?? []) {
          acc.add({
            ...who,
            product: "claude_code",
            model: mb.model,
            date: rowDay,
            source: SOURCE,
            costUsd: centsToUsd(mb.estimated_cost?.amount),
            requests: null, // not exposed by this endpoint
            tokensInput: mb.tokens?.input,
            tokensOutput: mb.tokens?.output,
            tokensCacheRead: mb.tokens?.cache_read,
            tokensCacheCreation: mb.tokens?.cache_creation,
            complete: rowDay !== today,
            extra: {
              "actor.type": actor.type ?? null,
              "claude_code.customer_type": row.customer_type ?? null,
              "claude_code.subscription_type": row.subscription_type ?? null,
              "claude_code.terminal_types": row.terminal_type ? [row.terminal_type] : [],
              "claude_code.remote": row.is_remote === true,
              // core metrics are per actor-day and repeated on each model row of that actor-day;
              // aggregate them with max() or takeAny() per (user.email, usage.date) in DQL, never sum across models.
              "claude_code.sessions": toLong(cm.num_sessions),
              "claude_code.commits": toLong(cm.commits_by_claude_code),
              "claude_code.pull_requests": toLong(cm.pull_requests_by_claude_code),
              "claude_code.lines_added": toLong(cm.lines_of_code?.added),
              "claude_code.lines_removed": toLong(cm.lines_of_code?.removed),
              "claude_code.tool_accepted": sumTool(row.tool_actions, "accepted"),
              "claude_code.tool_rejected": sumTool(row.tool_actions, "rejected"),
            },
            mergeExtra: (cur, inc) => {
              // same actor+model+day split across local/remote or terminals: union terminals, sum per-row metrics
              cur["claude_code.terminal_types"] = Array.from(new Set([...(cur["claude_code.terminal_types"] ?? []), ...(inc["claude_code.terminal_types"] ?? [])]));
              cur["claude_code.remote"] = cur["claude_code.remote"] || inc["claude_code.remote"];
              for (const k of ["claude_code.sessions", "claude_code.commits", "claude_code.pull_requests", "claude_code.lines_added", "claude_code.lines_removed", "claude_code.tool_accepted", "claude_code.tool_rejected"]) {
                cur[k] = toLong(cur[k]) + toLong(inc[k]);
              }
            },
          });
        }
      }
      await maybeFlush();
    }
    if (client.partial) break; // deadline/page cap: do not start the next day's cursor chain
  }

  // --- optional: org-level API usage by model + workspace (product=api) -----
  // usage_report/messages only returns CLOSED buckets: with bucket_width=1d the current day never appears.
  // So: 1d buckets for the previous days + 1h buckets for today (closed hours), both summed per UTC day.
  if (cfg.console_include_api_usage) {
    const groupBy = ["model", "workspace_id"];
    const calls = [];
    if (cfg.console_lookback_days > 1) {
      calls.push({ label: "1d", params: { starting_at: daysAgo(cfg.console_lookback_days - 1, now).toISOString(), ending_at: daysAgo(0, now).toISOString(), bucket_width: "1d", "group_by[]": groupBy, limit: Math.min(31, cfg.console_lookback_days - 1) } });
    }
    calls.push({ label: "1h", params: { starting_at: daysAgo(0, now).toISOString(), bucket_width: "1h", "group_by[]": groupBy, limit: 24 } });
    stats.debug_buckets = cfg.console_debug ? [] : undefined;
    for (const call of calls) {
      for await (const page of client.paginate(MSG_PATH, call.params)) {
        stats.api_pages++;
        if (cfg.console_debug) {
          for (const b of page.data ?? []) stats.debug_buckets.push({ width: call.label, starting_at: b.starting_at, ending_at: b.ending_at, results: (b.results ?? []).length });
        }
        for (const bucket of page.data ?? []) {
          const day = (bucket.starting_at ?? call.params.starting_at).slice(0, 10);
          for (const r of bucket.results ?? []) {
            stats.api_rows++;
            const ws = r.workspace_id ?? "default";
            const cc = r.cache_creation ?? {};
            acc.add({
              email: null,
              keyFallback: `workspace:${ws}`,
              product: "api",
              model: r.model,
              date: day,
              source: SOURCE,
              costUsd: null, // usage_report/messages has no cost; use /v1/organizations/cost_report for org-level USD
              requests: null,
              tokensInput: r.uncached_input_tokens,
              tokensOutput: r.output_tokens,
              tokensCacheRead: r.cache_read_input_tokens,
              tokensCacheCreation: toLong(cc.ephemeral_5m_input_tokens) + toLong(cc.ephemeral_1h_input_tokens),
              complete: day !== today,
              extra: { "api.workspace_id": r.workspace_id ?? null, "tools.web_search_requests": toLong(r.server_tool_use?.web_search_requests) },
              mergeExtra: (cur, inc) => { cur["tools.web_search_requests"] = toLong(cur["tools.web_search_requests"]) + toLong(inc["tools.web_search_requests"]); },
            });
          }
        }
        await maybeFlush();
      }
    }
  }

  await flush();
  const partial = client.partial;
  const summary = {
    source: SOURCE, events: acc.size, ingested: stats.ingested, api_calls: client.calls, org_id: orgId, days,
    time_budget_ms: cfg.time_budget_ms, elapsed_ms: Date.now() - (deadline - cfg.time_budget_ms),
    partial: Boolean(partial), ...(partial ? { reason: partial.reason } : {}),
    ...stats,
  };
  log(JSON.stringify(summary));
  return cfg.dry_run ? { ...summary, sample } : summary;
}

// user_actor rows: user.email from email_address; without it fall back to a stable `user:<user_id>` dedup key
// (user.email stays null, user.id is set) exactly like the Enterprise adapter, else "unknown-user".
// api_actor rows (CI keys etc.): user.email = "apikey:<api_key_name>".
function actorFields(actor) {
  if (actor.type === "api_actor") return { email: `apikey:${actor.api_key_name ?? "unknown"}` };
  const email = actor.email_address ?? actor.email ?? null;
  const userId = actor.user_id ?? actor.account_uuid ?? null;
  if (email) return { email, userId };
  return { email: null, userId, keyFallback: userId ? `user:${userId}` : "unknown-user" };
}

function sumTool(toolActions, field) {
  let n = 0;
  for (const v of Object.values(toolActions ?? {})) n += toLong(v?.[field]);
  return n;
}
