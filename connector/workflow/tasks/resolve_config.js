// Task 1/4 — resolve_config
// Merges defaults <- workflow input <- trigger/run params into one config object that the
// other tasks read with result("resolve_config"). Keeps all org-type gating in one place.
import { execution } from "@dynatrace-sdk/automation-utils";

const DEFAULTS = {
  org_type: "enterprise",                 // enterprise | console | team
  credential_id: "",                      // CREDENTIALS_VAULT-... holding the Anthropic key (token or password field)
  credential_name: "",                    // alternative: exact vault entry name; default "Anthropic <org_type> usage API key"
  anthropic_base_url: "https://api.anthropic.com",
  org_id: null,                           // optional label copied to org.id on every event
  enterprise_lookback_days: 10,           // re-read window: picks up the 7-day post-month revisions
  console_lookback_days: 3,
  console_include_api_usage: true,        // also pull usage_report/messages (product=api, org-level)
  dry_run: false,                         // true => build events, log counts, do not ingest
  console_debug: false,                   // true => return raw bucket metadata of usage_report/messages (no secrets)
  ingest_batch_size: 500,
};

const ORG_TYPES = new Set(["enterprise", "console", "team"]);

export default async function () {
  const exe = await execution();
  const fromInput = (exe && exe.input) || {};
  const fromParams = (exe && exe.params) || {};
  const cfg = { ...DEFAULTS, ...stripNull(fromInput), ...stripNull(fromParams) };
  cfg.org_type = String(cfg.org_type || "").toLowerCase().trim();
  if (!ORG_TYPES.has(cfg.org_type)) {
    throw new Error(`org_type must be one of enterprise|console|team, got "${cfg.org_type}"`);
  }
  if (!cfg.credential_id && !cfg.credential_name) cfg.credential_name = `Anthropic ${cfg.org_type} usage API key`;
  cfg.enterprise_lookback_days = clampInt(cfg.enterprise_lookback_days, 1, 31, 10);
  cfg.console_lookback_days = clampInt(cfg.console_lookback_days, 1, 31, 3);
  cfg.dry_run = cfg.dry_run === true || cfg.dry_run === "true";
  cfg.console_include_api_usage = !(cfg.console_include_api_usage === false || cfg.console_include_api_usage === "false");
  console.log(`[resolve_config] org_type=${cfg.org_type} base=${cfg.anthropic_base_url} dry_run=${cfg.dry_run} credential=${cfg.credential_id || ("name:" + cfg.credential_name)}`);
  return cfg;
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
