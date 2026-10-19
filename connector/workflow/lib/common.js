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
// backoff on 429/5xx (honours Retry-After), 410 => cursor expired => restart from page 1.
// Pagination never changes query params between pages; only `page` is appended.
// ---------------------------------------------------------------------------
function makeAnthropicClient({ baseUrl, apiKey, log = console.log, minIntervalMs = 1100, maxRetries = 5 }) {
  let lastCallAt = 0;
  let calls = 0;

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
      lastCallAt = Date.now();
      calls++;
      const res = await fetch(url.toString(), {
        method: "GET",
        headers: { "x-api-key": apiKey, "anthropic-version": ANTHROPIC_VERSION, accept: "application/json", "user-agent": USER_AGENT },
      });
      if (res.status === 429 || res.status >= 500) {
        if (attempt >= maxRetries) throw new Error(`HTTP ${res.status} on ${url.pathname} after ${attempt} retries`);
        const ra = Number(res.headers.get("retry-after"));
        const delay = Number.isFinite(ra) && ra > 0 ? ra * 1000 : Math.min(30000, 1000 * 2 ** attempt);
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

  // Yields every page. Params are frozen for the whole cursor sequence (API requirement).
  async function* paginate(path, baseParams) {
    const frozen = Object.freeze({ ...baseParams });
    let page;
    let restarts = 0;
    for (;;) {
      let body;
      try {
        body = await get(path, page ? { ...frozen, page } : frozen);
      } catch (e) {
        if (e && e.status === 410 && restarts < 1) {
          log(`[anthropic] cursor expired on ${path}; restarting from page 1`);
          restarts++;
          page = undefined;
          continue;
        }
        throw e;
      }
      yield body;
      if (!body || !body.has_more || !body.next_page) return;
      page = body.next_page;
    }
  }

  return { get, paginate, get calls() { return calls; } };
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

// Ingest in batches (bizevents ingest limit is 5 MiB/request; 500 small events ~ 300 KB).
async function ingestEvents(events, { businessEventsClient, batchSize = 500, log = console.log, dryRun = false }) {
  let sent = 0;
  for (let i = 0; i < events.length; i += batchSize) {
    const batch = events.slice(i, i + batchSize);
    if (dryRun) {
      log(`[ingest] dry-run: would send ${batch.length} events`);
    } else {
      await businessEventsClient.ingest({ body: batch, type: "application/json" });
    }
    sent += batch.length;
    log(`[ingest] ${sent}/${events.length} events`);
  }
  return sent;
}

// Accumulator keyed by (email|product|model|date): sums tokens/cost over duplicate rows.
function makeAccumulator() {
  const map = new Map();
  function key(f) {
    return [f.email ?? f.keyFallback ?? "", normalizeProduct(f.product), f.model ?? "unknown", f.date].join("|");
  }
  return {
    add(f) {
      const k = key(f);
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
    get size() {
      return map.size;
    },
  };
}
