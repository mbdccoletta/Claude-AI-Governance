// Task 1/4 — resolve_config
// Builds the config object the other tasks read with result("resolve_config"). Keeps all org-type gating in one place.
//
// Trust boundary: the workflow *input* is set by the workflow owner/editor; execution *params* can be set by anyone
// allowed to run the workflow (dtctl exec workflow --input, UI "Run with parameters"). So:
//   - org_type, credential_id, credential_name, anthropic_base_url, allow_custom_base_url, org_id, ingest_batch_size,
//     time_budget_ms come from the workflow input ONLY (a param with one of these names is ignored and logged);
//   - params may override only the run-time knobs in PARAM_OVERRIDABLE (lookback windows, dry_run, debug flags).
// anthropic_base_url must be https://api.anthropic.com unless the input allow_custom_base_url is exactly true
// (meant for the local mock server in test/run_tests.sh — never set it on a tenant).
import { execution } from "@dynatrace-sdk/automation-utils";

const DEFAULTS = {
  org_type: "",                           // enterprise | console | team — REQUIRED in the workflow input
  credential_id: "",                      // CREDENTIALS_VAULT-... holding the Anthropic key (token or password field)
  credential_name: "",                    // alternative: exact vault entry name; default "Anthropic <org_type> usage API key"
  anthropic_base_url: "https://api.anthropic.com",
  allow_custom_base_url: false,           // true => accept another base URL (mocks only; documented in README)
  org_id: null,                           // optional label copied to org.id on every event
  enterprise_lookback_days: 10,           // re-read window: picks up the 7-day post-month revisions
  console_lookback_days: 3,
  console_include_api_usage: true,        // also pull usage_report/messages (product=api, org-level)
  dry_run: false,                         // true => build events, log counts, do not ingest
  console_debug: false,                   // true => return raw bucket metadata of usage_report/messages (no secrets)
  ingest_batch_size: 500,                 // events per ingest request (1-1000; batches are also split at 4 MiB)
  time_budget_ms: 95000,                  // paging stops here (task timeout is 110 s); smaller values only for tests
};

const ORG_TYPES = new Set(["enterprise", "console", "team"]);
const PARAM_OVERRIDABLE = new Set(["enterprise_lookback_days", "console_lookback_days", "console_include_api_usage", "dry_run", "console_debug"]);
const OFFICIAL_BASE_URL = "https://api.anthropic.com";

export default async function () {
  const exe = await execution();
  const fromInput = stripNull((exe && exe.input) || {});
  const fromParams = stripNull((exe && exe.params) || {});

  if (!fromInput.org_type) {
    throw new Error(
      `workflow input org_type is missing (input keys seen: [${Object.keys(fromInput).join(", ")}]). ` +
      "Set org_type to enterprise|console|team in the workflow input (not in run parameters)."
    );
  }
  const ignored = Object.keys(fromParams).filter((k) => !PARAM_OVERRIDABLE.has(k));
  if (ignored.length) console.log(`[resolve_config] ignoring run params not allowed to override the workflow input: ${ignored.join(", ")}`);
  const params = {};
  for (const k of PARAM_OVERRIDABLE) if (k in fromParams) params[k] = fromParams[k];

  const cfg = { ...DEFAULTS, ...fromInput, ...params };
  cfg.org_type = String(cfg.org_type).toLowerCase().trim();
  if (!ORG_TYPES.has(cfg.org_type)) {
    throw new Error(`org_type must be one of enterprise|console|team, got "${cfg.org_type}"`);
  }
  cfg.credential_id = String(cfg.credential_id ?? "");
  cfg.credential_name = String(cfg.credential_name ?? "");
  if (!cfg.credential_id && !cfg.credential_name) cfg.credential_name = `Anthropic ${cfg.org_type} usage API key`;

  cfg.allow_custom_base_url = cfg.allow_custom_base_url === true;
  cfg.anthropic_base_url = String(cfg.anthropic_base_url).trim();
  if (!isOfficialBaseUrl(cfg.anthropic_base_url)) {
    if (!cfg.allow_custom_base_url) {
      throw new Error(`anthropic_base_url must start with ${OFFICIAL_BASE_URL} (got "${cfg.anthropic_base_url}"); set allow_custom_base_url=true only for a local mock`);
    }
    console.log(`[resolve_config] WARNING: allow_custom_base_url=true — the Anthropic key will be sent to ${cfg.anthropic_base_url} (mock/test use only)`);
  }

  cfg.enterprise_lookback_days = clampInt(cfg.enterprise_lookback_days, 1, 31, 10);
  cfg.console_lookback_days = clampInt(cfg.console_lookback_days, 1, 31, 3);
  cfg.ingest_batch_size = clampInt(cfg.ingest_batch_size, 1, 1000, 500);
  cfg.time_budget_ms = clampInt(cfg.time_budget_ms, 2000, 95000, 95000);
  cfg.dry_run = cfg.dry_run === true || cfg.dry_run === "true";
  cfg.console_debug = cfg.console_debug === true || cfg.console_debug === "true";
  cfg.console_include_api_usage = !(cfg.console_include_api_usage === false || cfg.console_include_api_usage === "false");
  console.log(`[resolve_config] org_type=${cfg.org_type} base=${cfg.anthropic_base_url} dry_run=${cfg.dry_run} credential=${cfg.credential_id || ("name:" + cfg.credential_name)} budget_ms=${cfg.time_budget_ms} input_keys=[${Object.keys(fromInput).join(",")}] param_overrides=[${Object.keys(params).join(",")}]`);
  return cfg;
}

// Exactly https://api.anthropic.com, optionally with a path — never another host, scheme or a look-alike prefix.
function isOfficialBaseUrl(v) {
  if (!v.startsWith(OFFICIAL_BASE_URL)) return false;
  try {
    const u = new URL(v);
    return u.protocol === "https:" && u.hostname === "api.anthropic.com" && u.port === "" && !u.username && !u.password;
  } catch {
    return false;
  }
}

function stripNull(o) {
  const out = {};
  for (const [k, v] of Object.entries(o)) if (v !== null && v !== undefined && v !== "") out[k] = v;
  return out;
}

function clampInt(v, min, max, dflt) {
  const n = parseInt(v, 10);
  if (!Number.isFinite(n)) return dflt;
  return Math.min(max, Math.max(min, n));
}
