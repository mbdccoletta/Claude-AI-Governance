// Ad-hoc function for `dtctl exec function`: ingests the claude.usage.daily events that import-team-csv.sh
// pipes on stdin ({"events": [...]}) through the platform SDK, using the dtctl user's own session.
// No API token needed: the user running dtctl must be allowed to ingest business events (storage:events:write).
import { businessEventsClient } from "@dynatrace-sdk/client-classic-environment-v2";

export default async function (payload) {
  const events = (payload && payload.events) || [];
  if (!events.length) throw new Error("payload.events is empty");
  const bad = events.filter((e) => e["event.type"] !== "claude.usage.daily" || !e["dedup.key"]);
  if (bad.length) throw new Error(`${bad.length} event(s) are not claude.usage.daily with a dedup.key — refusing to ingest`);
  const BATCH = 500;
  let ingested = 0;
  for (let i = 0; i < events.length; i += BATCH) {
    const batch = events.slice(i, i + BATCH);
    await businessEventsClient.ingest({ body: batch, type: "application/json" });
    ingested += batch.length;
  }
  return {
    ingested,
    sources: [...new Set(events.map((e) => e.source))],
    org_ids: [...new Set(events.map((e) => e["org.id"]))],
    dates: [...new Set(events.map((e) => e["usage.date"]))],
  };
}
