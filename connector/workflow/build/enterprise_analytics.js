// Task 2/4 — enterprise_analytics (org_type = enterprise)
// Source: Claude Enterprise Analytics API (Analytics API key, scope read:analytics)
//   GET /v1/organizations/analytics/user_cost_report   -> per-user cost rows (amount = fractional cents string)
//   GET /v1/organizations/analytics/user_usage_report  -> per-user token rows
// Both called with bucket_width=1d, group_by[]=product,model, limit=1000, for the last N complete UTC days
// (default 10: Anthropic revises cost values until ~7 days after month end, so we re-read and let
// DQL dedup keep the newest record per dedup.key).
// Time budget: paging stops at cfg.time_budget_ms (default 95 s of the 110 s task timeout); the accumulator is flushed
// to bizevents when less than the reserve is left and once at the end, so a big org still ingests something every run
// and the summary says { partial: true, reason } when the window was not fully read (next run re-reads it anyway).
import { result } from "@dynatrace-sdk/automation-utils";
import { credentialVaultClient, businessEventsClient } from "@dynatrace-sdk/client-classic-environment-v2";

// ============================================================================
// common.js — shared helpers for every connector task.
// This file is inlined into each task by workflow/build.py (marker: "// @include common.js"),
// so the workflow JSON embeds self-contained scripts. Runs unchanged in the
// Dynatrace JS runtime and under Node >= 20 (Web Crypto, fetch, URL are global in both).
// ============================================================================

const SCHEMA_EVENT_TYPE = "claude.usage.daily";
const SCHEMA_VERSION = "1.0";
const EVENT_PROVIDER = "dt-ai-observability-claude";
const ANTHROPIC_VERSION = "2023-06-01";
const USER_AGENT = "dt-ai-observability-claude/1.0 (Dynatrace Workflow connector)";

// Anthropic product values -> schema product enum (chat|claude_code|cowork|design|api|other).
// The raw value is always preserved in product.raw.
const PRODUCT_MAP = {
  chat: "chat",
  chat_cowork_unified: "chat",
  "claude-tag": "chat",
  claude_in_chrome: "chat",
  claude_code: "claude_code",
  "claude code": "claude_code",
  cowork: "cowork",
  office_agent: "cowork",
  claude_design: "design",
  design: "design",
  api: "api",
};

function normalizeProduct(raw) {
  if (raw === null || raw === undefined || raw === "") return "other";
  const k = String(raw).trim().toLowerCase();
  return PRODUCT_MAP[k] ?? "other";
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function sha256Hex(text) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Idempotency key: first 32 hex chars of SHA-256("email|product|model|date|source").
// Must stay byte-identical to csv-import/import_team_spend.py:dedup_key().
async function dedupKey({ email, product, model, date, source }) {
  const parts = [email, product, model, date, source].map((v) => (v === null || v === undefined ? "" : String(v)));
  return (await sha256Hex(parts.join("|"))).slice(0, 32);
}

// Anthropic amounts are decimal strings in (fractional) cents, e.g. "41280.000000" = $412.80.
// Returned as USD rounded to 6 decimals. Fine for dashboarding; for invoicing-grade sums use a decimal lib.
function centsToUsd(v) {
  if (v === null || v === undefined || v === "") return 0;
  const n = typeof v === "number" ? v : Number(String(v).trim());
  if (!Number.isFinite(n)) return 0;
  return Math.round((n / 100) * 1e6) / 1e6;
}

function round6(n) {
  return Math.round(n * 1e6) / 1e6;
}

function utcDay(d) {
  return d.toISOString().slice(0, 10);
}

// Midnight UTC of (today - n days).
function daysAgo(n, now = new Date()) {
  const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  d.setUTCDate(d.getUTCDate() - n);
  return d;
}

function toLong(v) {
  const n = Number(v);
  return Number.isFinite(n) ? Math.round(n) : 0;
}

// Build one bizevent in the claude.usage.daily schema (see schema.md).
async function buildEvent(f) {
  const product = normalizeProduct(f.product);
  const keyEmail = f.email ?? f.keyFallback ?? "";
  const ev = {
    "event.type": SCHEMA_EVENT_TYPE,
    "event.provider": EVENT_PROVIDER,
    "schema.version": SCHEMA_VERSION,
    "user.email": f.email ?? null,
    product,
    "product.raw": f.product ?? null,
    model: f.model ?? "unknown",
    "tokens.input": toLong(f.tokensInput),
    "tokens.output": toLong(f.tokensOutput),
    "tokens.cache_read": toLong(f.tokensCacheRead),
    "tokens.cache_creation": toLong(f.tokensCacheCreation),
    "tokens.total": toLong(f.tokensInput) + toLong(f.tokensOutput) + toLong(f.tokensCacheRead) + toLong(f.tokensCacheCreation),
    requests: f.requests === null || f.requests === undefined ? null : toLong(f.requests),
    cost_usd: f.costUsd === null || f.costUsd === undefined ? null : round6(f.costUsd),
    source: f.source,
    "usage.date": f.date,
    "usage.timestamp": `${f.date}T00:00:00Z`,
    "usage.complete": f.complete ?? null,
    "org.id": f.orgId ?? null,
    "dedup.key": await dedupKey({ email: keyEmail, product, model: f.model ?? "unknown", date: f.date, source: f.source }),
    ...(f.extra ?? {}),
  };
  return ev;
}

// ---------------------------------------------------------------------------
// Anthropic HTTP client: 60 req/min org-wide budget -> >= minIntervalMs between calls,
// backoff on 429/5xx (honours Retry-After, clamped to maxRetryAfterMs), 410 => cursor expired => restart from page 1.
// Pagination never changes query params between pages; only `page` is appended.
//
// Time budget: the task runtime kills a task at `timeout` (110 s in build.py). Every call is serialized at >= 1.1 s,
// so a large org (users x days x product x model rows, 1000 per page) cannot always be paged in one run. The client
// therefore carries a `deadline` (default: now + 95 s) and a page cap (`maxPages`, default 200): paginate() stops
// yielding when either is hit and records why in `client.partial` ({ reason, path, pages }). A back-off sleep that
// would end after the deadline is not taken: the call is abandoned and the cursor sequence ends as partial too.
// Callers flush what they have (see flushAccumulator) and report { partial: true, reason } so the next scheduled run,
// which re-reads the whole window, completes the picture (dedup.key: newest record wins).
// ---------------------------------------------------------------------------
const DEFAULT_TIME_BUDGET_MS = 95_000;
const DEFAULT_MAX_PAGES = 200;
const MAX_RETRY_AFTER_MS = 20_000;

function makeAnthropicClient({
  baseUrl, apiKey, log = console.log, minIntervalMs = 1100, maxRetries = 5,
  deadline = Date.now() + DEFAULT_TIME_BUDGET_MS, maxPages = DEFAULT_MAX_PAGES, maxRetryAfterMs = MAX_RETRY_AFTER_MS,
}) {
  let lastCallAt = 0;
  let calls = 0;
  let partial = null; // { reason, path, pages } once the budget or the page cap stopped a cursor sequence

  function remainingMs() {
    return deadline - Date.now();
  }

  function budgetError(reason) {
    const e = new Error(`time budget exhausted: ${reason}`);
    e.budgetExceeded = true;
    return e;
  }

  async function get(path, params = {}) {
    const url = new URL(path, baseUrl.endsWith("/") ? baseUrl : baseUrl + "/");
    for (const [k, v] of Object.entries(params)) {
      if (v === null || v === undefined) continue;
      if (Array.isArray(v)) v.forEach((x) => url.searchParams.append(k, String(x)));
      else url.searchParams.set(k, String(v));
    }
    let attempt = 0;
    for (;;) {
      const wait = lastCallAt + minIntervalMs - Date.now();
      if (wait > 0) await sleep(wait);
      if (remainingMs() <= 0) throw budgetError(`deadline reached before calling ${url.pathname}`);
      lastCallAt = Date.now();
      calls++;
      const res = await fetch(url.toString(), {
        method: "GET",
        headers: { "x-api-key": apiKey, "anthropic-version": ANTHROPIC_VERSION, accept: "application/json", "user-agent": USER_AGENT },
      });
      if (res.status === 429 || res.status >= 500) {
        if (attempt >= maxRetries) throw new Error(`HTTP ${res.status} on ${url.pathname} after ${attempt} retries`);
        const ra = Number(res.headers.get("retry-after"));
        const delay = Number.isFinite(ra) && ra > 0 ? Math.min(maxRetryAfterMs, ra * 1000) : Math.min(30000, 1000 * 2 ** attempt);
        if (delay >= remainingMs()) {
          log(`[anthropic] ${res.status} on ${url.pathname}; backing off ${delay} ms would pass the deadline (${remainingMs()} ms left) — stopping here`);
          throw budgetError(`retry of ${url.pathname} (${delay} ms back-off) does not fit in the remaining ${remainingMs()} ms`);
        }
        log(`[anthropic] ${res.status} on ${url.pathname}; backing off ${delay} ms (attempt ${attempt + 1}/${maxRetries})`);
        await sleep(delay);
        attempt++;
        continue;
      }
      if (!res.ok) {
        const body = await res.text();
        const err = new Error(`HTTP ${res.status} ${url.pathname}: ${body.slice(0, 400)}`);
        err.status = res.status;
        throw err;
      }
      return res.json();
    }
  }

  // Yields every page until the API says there is no more, the deadline passes or maxPages is reached.
  // Params are frozen for the whole cursor sequence (API requirement). On a budget/page-cap stop the
  // generator returns normally and `client.partial` is set; callers check it after the loop.
  async function* paginate(path, baseParams) {
    const frozen = Object.freeze({ ...baseParams });
    let page;
    let pages = 0;
    let restarts = 0;
    for (;;) {
      if (remainingMs() <= 0) {
        const reason = `deadline reached after ${pages} page(s) of ${path}`;
        partial = partial ?? { reason, path, pages };
        log(`[anthropic] ${reason}${pages ? "" : " (not started)"}`);
        return;
      }
      if (pages >= maxPages) {
        const reason = `page cap ${maxPages} reached on ${path}`;
        partial = partial ?? { reason, path, pages };
        log(`[anthropic] ${reason}`);
        return;
      }
      let body;
      try {
        body = await get(path, page ? { ...frozen, page } : frozen);
      } catch (e) {
        if (e && e.budgetExceeded) {
          partial = partial ?? { reason: `${e.message} (after ${pages} page(s) of ${path})`, path, pages };
          return;
        }
        if (e && e.status === 410 && restarts < 1) {
          log(`[anthropic] cursor expired on ${path}; restarting from page 1`);
          restarts++;
          page = undefined;
          continue;
        }
        throw e;
      }
      pages++;
      yield body;
      if (!body || !body.has_more || !body.next_page) return;
      page = body.next_page;
    }
  }

  return {
    get,
    paginate,
    remainingMs,
    get calls() { return calls; },
    get partial() { return partial; },
    get deadline() { return deadline; },
  };
}

// Resolve the Anthropic key from the credential vault: by id (CREDENTIALS_VAULT-...) or, when the id is empty,
// by exact credential name (the workflow actor lists the vault and picks the entry). TOKEN or USERNAME_PASSWORD types.
async function resolveApiKey(credentialVaultClient, credentialId, credentialName) {
  let id = credentialId;
  if (!id && credentialName) {
    // listCredentials = GET /credentials (metadata only); getCredentials would be GET /credentials/{id}
    const list = await credentialVaultClient.listCredentials({ pageSize: 500 });
    const hit = (list?.credentials ?? []).find((c) => c.name === credentialName);
    if (!hit) throw new Error(`No credential vault entry named "${credentialName}" (create a Token credential with App Engine scope, or set credential_id)`);
    id = hit.id;
  }
  if (!id) throw new Error("credential_id and credential_name are both empty — set one workflow input to the vault entry holding the Anthropic key");
  const creds = await credentialVaultClient.getCredentialsDetails({ id });
  const key = creds?.token ?? creds?.password ?? null;
  if (!key) throw new Error(`Credential ${id} has neither token nor password`);
  return key;
}

// Ingest in batches: by count (batchSize, default 500) AND by serialized size (maxBatchBytes, default 4 MiB —
// the bizevents ingest limit is 5 MiB per request; 500 small events are ~300 KB, Console rows with claude_code.* extras are bigger).
const MAX_BATCH_BYTES = 4 * 1024 * 1024;
const _enc = new TextEncoder();

async function ingestEvents(events, { businessEventsClient, batchSize = 500, maxBatchBytes = MAX_BATCH_BYTES, log = console.log, dryRun = false }) {
  let sent = 0;
  let batch = [];
  let bytes = 2; // "[" + "]"
  async function flush() {
    if (!batch.length) return;
    if (dryRun) {
      log(`[ingest] dry-run: would send ${batch.length} events (${bytes} bytes)`);
    } else {
      await businessEventsClient.ingest({ body: batch, type: "application/json" });
    }
    sent += batch.length;
    log(`[ingest] ${sent}/${events.length} events`);
    batch = [];
    bytes = 2;
  }
  for (const ev of events) {
    const size = _enc.encode(JSON.stringify(ev)).length + 1; // + ","
    if (batch.length && (batch.length >= batchSize || bytes + size > maxBatchBytes)) await flush();
    batch.push(ev);
    bytes += size;
  }
  await flush();
  return sent;
}

// Accumulator keyed by (email|product|model|date): sums tokens/cost over duplicate rows.
// `requests` is summed only from rows that carry it (cost rows must pass requests: null, otherwise the
// Enterprise cost report, which also returns `requests`, would double the usage-report count).
// Tracks which keys changed since the last takeDirty() so incremental flushes re-send only updated entries.
function makeAccumulator() {
  const map = new Map();
  const dirty = new Set();
  function key(f) {
    return [f.email ?? f.keyFallback ?? "", normalizeProduct(f.product), f.model ?? "unknown", f.date].join("|");
  }
  return {
    add(f) {
      const k = key(f);
      dirty.add(k);
      const cur = map.get(k);
      if (!cur) {
        map.set(k, { ...f, extra: { ...(f.extra ?? {}) } });
        return;
      }
      for (const t of ["tokensInput", "tokensOutput", "tokensCacheRead", "tokensCacheCreation"]) cur[t] = toLong(cur[t]) + toLong(f[t]);
      if (f.requests !== null && f.requests !== undefined) cur.requests = toLong(cur.requests) + toLong(f.requests);
      if (f.costUsd !== null && f.costUsd !== undefined) cur.costUsd = (cur.costUsd ?? 0) + f.costUsd;
      if (f.complete !== undefined) cur.complete = cur.complete && f.complete;
      if (f.mergeExtra) f.mergeExtra(cur.extra, f.extra ?? {});
    },
    values() {
      return Array.from(map.values());
    },
    // Entries added/changed since the previous takeDirty(); clears the dirty set.
    takeDirty() {
      const out = [];
      for (const k of dirty) out.push(map.get(k));
      dirty.clear();
      return out;
    },
    get size() {
      return map.size;
    },
    get dirtySize() {
      return dirty.size;
    },
  };
}

// Incremental flush used by the tasks: build events for the dirty accumulator entries and ingest them.
// Called when the remaining time budget drops under `reserveMs` and once at the end, so a run that hits the
// deadline has already ingested most of what it paged. Re-sending a key later (with more rows merged in) is safe:
// every DQL reader dedups by dedup.key keeping the newest record.
// `build(f)` maps an accumulator entry to the buildEvent() input (adds orgId / extra fields per source).
async function flushAccumulator(acc, { build, businessEventsClient, batchSize, log, dryRun, stats, sampleOut }) {
  const entries = acc.takeDirty();
  if (!entries.length) return 0;
  const events = [];
  for (const f of entries) events.push(await buildEvent(await build(f)));
  if (sampleOut && sampleOut.length < 3) sampleOut.push(...events.slice(0, 3 - sampleOut.length));
  const sent = await ingestEvents(events, { businessEventsClient, batchSize, log, dryRun });
  stats.flushes = (stats.flushes ?? 0) + 1;
  stats.ingested = (stats.ingested ?? 0) + (dryRun ? 0 : sent);
  stats.events_built = (stats.events_built ?? 0) + events.length;
  return sent;
}

// Reserve for the final flush: 15 s, or a quarter of the budget when the budget itself is small (tests).
function flushReserveMs(budgetMs) {
  return Math.min(15_000, Math.max(1_000, Math.floor(budgetMs / 4)));
}


const SOURCE = "enterprise_api";
const COST_PATH = "v1/organizations/analytics/user_cost_report";
const USAGE_PATH = "v1/organizations/analytics/user_usage_report";

export default async function () {
  const cfg = await result("resolve_config");
  if (cfg.org_type !== "enterprise") return { skipped: true, reason: `org_type=${cfg.org_type}` };

  const log = (m) => console.log(`[enterprise] ${m}`);
  const apiKey = await resolveApiKey(credentialVaultClient, cfg.credential_id, cfg.credential_name);
  const deadline = Date.now() + cfg.time_budget_ms;
  const reserveMs = flushReserveMs(cfg.time_budget_ms);
  const client = makeAnthropicClient({ baseUrl: cfg.anthropic_base_url, apiKey, log, deadline });

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
  const stats = { cost_rows: 0, usage_rows: 0, cost_pages: 0, usage_pages: 0, flushes: 0, ingested: 0, events_built: 0 };
  const sample = [];
  const flush = () => flushAccumulator(acc, {
    build: (f) => ({ ...f, orgId, extra: { ...f.extra, "data.refreshed_at": refreshedAt, "user.id": f.userId ?? null } }),
    businessEventsClient, batchSize: cfg.ingest_batch_size, log, dryRun: cfg.dry_run, stats, sampleOut: sample,
  });
  // flush early once the budget is nearly spent, so the final flush has little left to send
  const maybeFlush = async () => { if (client.remainingMs() < reserveMs && acc.dirtySize) { log(`budget low (${client.remainingMs()} ms left): flushing ${acc.dirtySize} entries`); await flush(); } };

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
        requests: null, // the cost report may also carry `requests`; counting it here would double the usage-report value
        tokensInput: 0, tokensOutput: 0, tokensCacheRead: 0, tokensCacheCreation: 0,
        complete: isComplete(row.ending_at, refreshedAt),
        extra: {
          "cost.list_usd": centsToUsd(row.list_amount),
          "cost.currency": row.currency ?? "USD",
        },
        mergeExtra: (cur, inc) => { cur["cost.list_usd"] = round6((cur["cost.list_usd"] ?? 0) + (inc["cost.list_usd"] ?? 0)); },
      });
    }
    await maybeFlush();
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
    await maybeFlush();
  }

  // --- emit ---------------------------------------------------------------
  // Final flush sends the entries changed since the last early flush. If the deadline hit during cost paging, the
  // usage loop above returned at once (paginate checks the deadline first) and client.partial explains why.
  await flush();
  const partial = client.partial;
  const summary = {
    source: SOURCE, events: acc.size, ingested: stats.ingested, api_calls: client.calls, data_refreshed_at: refreshedAt, org_id: orgId,
    time_budget_ms: cfg.time_budget_ms, elapsed_ms: Date.now() - (deadline - cfg.time_budget_ms),
    partial: Boolean(partial), ...(partial ? { reason: partial.reason } : {}),
    ...stats,
  };
  log(JSON.stringify(summary));
  return cfg.dry_run ? { ...summary, sample } : summary;
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
