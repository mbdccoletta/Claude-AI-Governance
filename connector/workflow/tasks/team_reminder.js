// Task 4/4 — team_reminder (org_type = team)
// Claude Team plans have no per-user usage API. The only official per-user source is the spend CSV
// export in claude.ai > Settings > Analytics (up to 90 days, refreshed daily with a 1-day lag).
// This task exists so the workflow still produces a visible, searchable trace of what to do.
import { result } from "@dynatrace-sdk/automation-utils";

export default async function () {
  const cfg = await result("resolve_config");
  if (cfg.org_type !== "team") return { skipped: true, reason: `org_type=${cfg.org_type}` };
  const msg = [
    "org_type=team: no Anthropic API exposes per-user usage for Team plans.",
    "Export the spend CSV from claude.ai > Settings > Analytics and run:",
    "  python3 connector/csv-import/import_team_spend.py --csv <export.csv> --date <YYYY-MM-DD period end> --tenant <https://ENV.live.dynatrace.com>",
    "with DT_INGEST_TOKEN set (scope bizevents.ingest). Events land as source=team_csv.",
  ].join("\n");
  console.log(`[team] ${msg}`);
  return { source: "team_csv", events: 0, reminder: msg };
}
