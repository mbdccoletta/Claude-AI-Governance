#!/usr/bin/env python3
"""Generate the layer-3 dashboard JSON (official Claude usage & cost per developer, bizevents claude.usage.daily).

Writes, next to this script:
  claude-usage-dashboard.json         dtctl format  {name, type: dashboard, content}  → dtctl apply -f ...
  claude-usage-dashboard.upload.json  Dashboards app "Upload" format (the content object only)

Every data tile applies the dedup rule from ../schema.md (`dedup dedup.key, sort: {timestamp desc}`) and filters on
usage.date, never on the bizevent timestamp (= ingest time). Charts over time use toTimestamp(usage.timestamp).
The two table queries are read from ../dql/ so they stay identical to the documented queries.

Usage:  python3 build.py            # regenerate both files
        python3 build.py --check    # regenerate + structural checks (ids, overlaps, dedup rule, json round-trip)
"""
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
DQL_DIR = HERE.parent / "dql"
NAME = "Claude Usage — Official Cost per Developer (layer 3)"

# ---------------------------------------------------------------- DQL building blocks
BASE_30D = """fetch bizevents, from: now() - 45d
| filter event.type == "claude.usage.daily"
| filter coalesce(org.id, "") != "demo-sample"  // demo rows loaded from csv-import/sample.csv
| filter usage.date >= formatTimestamp(now() - 30d, format: "yyyy-MM-dd", timezone: "UTC")
| dedup dedup.key, sort: {timestamp desc}"""

DEDUP_RULE = "| dedup dedup.key, sort: {timestamp desc}"


def dql_file(name: str) -> str:
    """Read ../dql/<name>, dropping the leading // comment lines (tiles carry the explanation in `description`)."""
    lines = (DQL_DIR / name).read_text(encoding="utf-8").splitlines()
    body = [ln for ln in lines if not ln.lstrip().startswith("//")]
    return "\n".join(body).strip()


Q_TOTAL_COST = BASE_30D + "\n| summarize cost_usd = sum(cost_usd)"

Q_DEVELOPERS = BASE_30D + """
| filter isNotNull(user.email)
| summarize developers = countDistinct(user.email)"""

Q_TOKENS = BASE_30D + "\n| summarize tokens = sum(tokens.total)"

Q_LATEST_DAY = """fetch bizevents, from: now() - 45d
| filter event.type == "claude.usage.daily"
| filter coalesce(org.id, "") != "demo-sample"  // demo rows loaded from csv-import/sample.csv
| dedup dedup.key, sort: {timestamp desc}
| summarize latest_usage_day = max(usage.date)
| fields latest_usage_day"""

# time axis = the usage day (usage.timestamp), NOT the ingest timestamp
Q_DAILY_COST = BASE_30D + """
| makeTimeseries cost_usd = sum(cost_usd), by: {product}, time: toTimestamp(usage.timestamp), interval: 1d, from: now() - 30d, to: now()"""

# same ranking as ../dql/top10-developers-by-cost.dql, reshaped so the bar = total and the stack = product
Q_TOP10 = BASE_30D + """
| filter isNotNull(user.email)
| summarize {
    total_usd = sum(cost_usd),
    claude_code = sum(if(product == "claude_code", cost_usd, else: 0.0)),
    chat = sum(if(product == "chat", cost_usd, else: 0.0)),
    cowork = sum(if(product == "cowork", cost_usd, else: 0.0)),
    design = sum(if(product == "design", cost_usd, else: 0.0)),
    api_other = sum(if(product == "api" or product == "other", cost_usd, else: 0.0))
  }, by: {user.email}
| sort total_usd desc
| limit 10
| fieldsRemove total_usd"""

# same aggregation as ../dql/tokens-by-product-model.dql, reduced to the four token types for a stacked bar
Q_TOKENS_PRODUCT_MODEL = BASE_30D + """
| summarize {
    input = sum(tokens.input),
    output = sum(tokens.output),
    cache_read = sum(tokens.cache_read),
    cache_creation = sum(tokens.cache_creation),
    total = sum(tokens.total)
  }, by: {product, model}
| sort total desc
| limit 25
| fieldsAdd product_model = concat(product, " · ", model)
| fields product_model, input, output, cache_read, cache_creation"""

Q_COST_PER_DEV = dql_file("cost-per-developer-30d.dql")
Q_OFFICIAL_VS_OBSERVED = dql_file("official-vs-observed-tokens.dql")

# coverage KPI: observed (layer 2 logs) / official (layer 3) tokens, claude_code + cowork, last 7 usage days
Q_COVERAGE = """fetch bizevents, from: now() - 10d
| filter event.type == "claude.usage.daily" and in(product, {"claude_code", "cowork"})
| filter coalesce(org.id, "") != "demo-sample"  // demo rows loaded from csv-import/sample.csv
| filter usage.date >= formatTimestamp(now() - 7d, format: "yyyy-MM-dd", timezone: "UTC")
| dedup dedup.key, sort: {timestamp desc}
| summarize official_tokens = sum(tokens.total)
| append [
    fetch logs, from: now() - 7d
    | filter event.name == "api_request" and in(service.name, {"claude-code", "claude-code-desktop", "cowork"})
    | summarize observed_tokens = sum(toLong(input_tokens) + toLong(output_tokens) + toLong(cache_read_tokens) + toLong(cache_creation_tokens))
  ]
| summarize official_tokens = sum(official_tokens), observed_tokens = sum(observed_tokens)
| fieldsAdd coverage_pct = if(official_tokens > 0, observed_tokens * 100.0 / official_tokens, else: 0.0)
| fields coverage_pct"""

Q_FRESHNESS = """fetch bizevents, from: now() - 45d
| filter event.type == "claude.usage.daily"
| filter coalesce(org.id, "") != "demo-sample"  // demo rows loaded from csv-import/sample.csv
| dedup dedup.key, sort: {timestamp desc}
| summarize {
    latest_usage_day = max(usage.date),
    latest_usage = max(toTimestamp(usage.timestamp)),
    data_refreshed_at = max(toTimestamp(data.refreshed_at)),
    last_ingest = max(timestamp),
    developers = countDistinct(user.email),
    records = count()
  }, by: {source}
| fieldsAdd lag_hours = round(toDouble(now() - latest_usage) / 3600000000000.0, decimals: 1)  // hours since the latest usage timestamp; usage.date itself is a UTC yyyy-MM-dd string: never formatTimestamp() it
| fields source, latest_usage_day, lag_hours, data_refreshed_at, last_ingest, developers, records
| sort latest_usage_day desc"""

# ---------------------------------------------------------------- JSON helpers
QUERY_SETTINGS = {
    "maxResultRecords": 1000,
    "defaultScanLimitGbytes": 500,
    "maxResultMegaBytes": 1,
    "defaultSamplingRatio": 10,
    "enableSampling": False,
}
DAVIS = {"enabled": False, "davisVisualization": {"isAvailable": True}}

GREEN, YELLOW, RED = "#2f6862", "#eea53c", "#c62239"


def unit(identifier, category, base, decimals=2, delimiter=True):
    return {
        "identifier": identifier, "unitCategory": category, "baseUnit": base, "displayUnit": None,
        "decimals": decimals, "suffix": "", "delimiter": delimiter, "cascade": None, "added": 1,
    }


def usd(identifier, decimals=2):
    return unit(identifier, "currency", "usd", decimals)


def count(identifier):
    return unit(identifier, "unspecified", "count", 0)


def pct(identifier):
    return unit(identifier, "percentage", "percent", 1, delimiter=False)


def data_tile(title, query, visualization, settings, description=None):
    tile = {
        "type": "data",
        "title": title,
        "query": query,
        "visualization": visualization,
        "visualizationSettings": {"autoSelectVisualization": False, **settings},
        "querySettings": dict(QUERY_SETTINGS),
        "davis": dict(DAVIS),
    }
    if description:
        tile["description"] = description
    return tile


def kpi(title, query, field, icon, units=None, coloring=None, description=None):
    settings = {"singleValue": {"labelMode": "none", "isIconVisible": True, "recordField": field, "prefixIcon": icon}}
    if units:
        settings["unitsOverrides"] = units
    if coloring:
        settings["coloring"] = coloring
    return data_tile(title, query, "singleValue", settings, description)


def markdown(content):
    return {"type": "markdown", "title": "", "content": content}


def categorical_stacked(legend="bottom"):
    return {
        "chartSettings": {
            "legend": {"hidden": False, "position": legend},
            "categoricalBarChartSettings": {
                "layout": "horizontal",
                "categoryAxisTickLayout": "horizontal",
                "scale": "absolute",
                "groupMode": "stacked",
                "colorPaletteMode": "multi-color",
                "valueAxisScale": "linear",
            },
        }
    }


HIGHER_IS_BETTER = {
    "colorRules": [
        {"colorMode": "custom-color", "comparator": ">", "customColor": {"Default": RED}, "field": "coverage_pct", "value": -1},
        {"colorMode": "custom-color", "comparator": ">", "customColor": {"Default": YELLOW}, "field": "coverage_pct", "value": 50},
        {"colorMode": "custom-color", "comparator": ">", "customColor": {"Default": GREEN}, "field": "coverage_pct", "value": 80},
    ]
}

# ---------------------------------------------------------------- tiles + layout (24-column grid)
HEADER = (
    "# Claude usage — official daily cost per developer (layer 3)\n\n"
    "Anthropic's own per-user usage and cost figures, imported once a day by the **claude-usage-connector** workflow as "
    "business events (`event.type = \"claude.usage.daily\"`, one event per user × product × model × UTC day × source). "
    "Billing-grade and complete across claude.ai chat, Cowork, Design, Claude Code (CLI, Desktop and web) — not only the "
    "machines where the layer 1/2 hooks are installed. All tiles cover the **last 30 usage days** (coverage: last 7)."
)

CAVEATS = (
    "### Read me before trusting a number\n\n"
    "* **Time picker does not apply.** Tiles filter on `usage.date` (the day the usage belongs to) with their own window, because the "
    "bizevent `timestamp` is the ingest time. Every tile dedups by `dedup.key` (newest revision wins): Anthropic revises values until "
    "~7 days after month end and the connector re-reads recent days on purpose.\n"
    "* **Amazon Bedrock is not covered** (nor Vertex AI / Foundry): Claude usage through cloud marketplaces does not appear in any "
    "Anthropic usage endpoint. Use the cloud provider's billing export for that spend.\n"
    "* **Claude Team plans** have no API: rows with `source = team_csv` come from `csv-import/import_team_spend.py` (daily spend "
    "export, 1-day lag, no cache-token columns).\n"
    "* **Console `product = api` rows** are org/workspace level: no e-mail, no cost (shown as null).\n"
    "* **Observed coverage** compares with layer 2 (`fetch logs | filter event.name == \"api_request\"`), which only sees "
    "instrumented machines; expect observed ≤ official."
)

tiles = {}
layouts = {}


def place(tile_id, tile, x, y, w, h):
    tiles[tile_id] = tile
    layouts[tile_id] = {"x": x, "y": y, "w": w, "h": h}


# row 0 — header
place("header", markdown(HEADER), 0, 0, 24, 3)

# row 1 — KPIs, last 30 usage days
place("kpi_cost", kpi("Official cost — last 30 usage days", Q_TOTAL_COST, "cost_usd", "MoneyIcon", [usd("cost_usd")],
                      description="sum(cost_usd) over deduped claude.usage.daily events, usage.date in the last 30 days"), 0, 3, 6, 3)
place("kpi_devs", kpi("Developers with usage", Q_DEVELOPERS, "developers", "UserIcon", [count("developers")],
                      description="countDistinct(user.email); org-level api rows (null e-mail) excluded"), 6, 3, 6, 3)
place("kpi_tokens", kpi("Tokens — last 30 usage days", Q_TOKENS, "tokens", "DataIcon", [count("tokens")],
                        description="sum(tokens.total) = input + output + cache_read + cache_creation"), 12, 3, 6, 3)
place("kpi_latest", kpi("Latest usage day imported", Q_LATEST_DAY, "latest_usage_day", "CalendarIcon",
                        description="max(usage.timestamp) across all sources; see the freshness table for the per-source view"), 18, 3, 6, 3)

# row 2 — trend + top 10
place("daily_cost", data_tile(
    "Daily cost by usage day, stacked by product (USD)", Q_DAILY_COST, "barChart",
    {"chartSettings": {"legend": {"hidden": False, "position": "bottom"}, "gapPolicy": "gap"}, "unitsOverrides": [usd("cost_usd")]},
    description="makeTimeseries over toTimestamp(usage.timestamp) (the usage day), interval 1d, by product"), 0, 6, 16, 7)
place("top10", data_tile(
    "Top 10 developers by cost, split by product (USD)", Q_TOP10, "categoricalBarChart",
    {**categorical_stacked(), "unitsOverrides": [usd(f) for f in ("claude_code", "chat", "cowork", "design", "api_other")]},
    description="bar length = total official cost in the last 30 usage days; stack = product"), 16, 6, 8, 7)

# row 3 — tables
place("cost_per_dev", data_tile(
    "Cost per developer — last 30 usage days", Q_COST_PER_DEV, "table",
    {"table": {"rowDensity": "condensed", "enableSparklines": False, "linewrapEnabled": False, "columnWidthStrategy": "content"},
     "unitsOverrides": [usd("cost_usd"), usd("usd_per_1m_tokens"), count("tokens_total"), count("requests")]},
    description="connector/dql/cost-per-developer-30d.dql — requests is null for Console sources (not exposed by that API)"), 0, 13, 12, 8)
place("tokens_product_model", data_tile(
    "Tokens by product × model, stacked by token type", Q_TOKENS_PRODUCT_MODEL, "categoricalBarChart",
    {**categorical_stacked(), "unitsOverrides": [count(f) for f in ("input", "output", "cache_read", "cache_creation")]},
    description="top 25 product × model pairs by tokens.total, last 30 usage days (connector/dql/tokens-by-product-model.dql)"), 12, 13, 12, 8)

# row 4 — coverage: official (layer 3) vs observed (layer 2)
place("coverage_hdr", markdown("### Coverage — official (layer 3 bizevents) vs observed (layer 2 Claude Code and Cowork logs), claude_code + cowork, last 7 usage days"), 0, 21, 24, 1)
place("kpi_coverage", kpi("Observed / official tokens", Q_COVERAGE, "coverage_pct", "CheckmarkIcon", [pct("coverage_pct")], HIGHER_IS_BETTER,
                          description="layer 2 api_request tokens ÷ layer 3 official claude_code + cowork tokens, last 7 usage days; red < 50 %, yellow < 80 %"), 0, 22, 6, 7)
place("coverage_table", data_tile(
    "Official vs observed per developer per day", Q_OFFICIAL_VS_OBSERVED, "table",
    {"table": {"rowDensity": "condensed", "enableSparklines": False, "linewrapEnabled": False, "columnWidthStrategy": "content"},
     "unitsOverrides": [pct("coverage_pct"), usd("official_cost_usd"), usd("observed_cost_usd"), usd("delta_usd"),
                        count("official_tokens"), count("observed_tokens"), count("api_requests")]},
    description="connector/dql/official-vs-observed-tokens.dql — outer join on {user.email, usage.date, product}; a developer with no layer 2 rows shows observed = 0"), 6, 22, 18, 7)

# row 5 — freshness + caveats
place("freshness", data_tile(
    "Freshness per source", Q_FRESHNESS, "table",
    {"table": {"rowDensity": "condensed", "enableSparklines": False, "linewrapEnabled": False, "columnWidthStrategy": "content"},
     "unitsOverrides": [unit("lag_hours", "time", "hour", 1, delimiter=False), count("developers"), count("records")]},
    description="latest usage.date, Anthropic data_refreshed_at watermark (Enterprise only) and last ingest per source — all deduped"), 0, 29, 13, 6)
place("caveats", markdown(CAVEATS), 13, 29, 11, 6)

content = {
    "version": 21,
    "importedWithCode": False,
    "settings": {"defaultTimeframe": {"enabled": True, "value": {"from": "now()-30d", "to": "now()"}}},
    "variables": [],
    "tiles": tiles,
    "layouts": layouts,
    "annotations": [],
}
document = {"name": NAME, "type": "dashboard", "content": content}


# ---------------------------------------------------------------- checks
def check():
    errors = []
    if set(tiles) != set(layouts):
        errors.append("tile ids and layout ids differ")
    cells = {}
    for tid, l in layouts.items():
        if l["x"] + l["w"] > 24:
            errors.append(f"{tid}: x+w > 24")
        for xx in range(l["x"], l["x"] + l["w"]):
            for yy in range(l["y"], l["y"] + l["h"]):
                if (xx, yy) in cells:
                    errors.append(f"{tid} overlaps {cells[(xx, yy)]} at ({xx},{yy})")
                    break
                cells[(xx, yy)] = tid
    for tid, t in tiles.items():
        if t["type"] != "data":
            continue
        q = t["query"]
        if DEDUP_RULE not in q:
            errors.append(f"{tid}: missing dedup rule")
        if "filter event.type == \"claude.usage.daily\"" not in q:
            errors.append(f"{tid}: missing event.type filter")
        if q.count("(") != q.count(")") or q.count("{") != q.count("}") or q.count("[") != q.count("]"):
            errors.append(f"{tid}: unbalanced brackets")
        if re.search(r"\bfilter\s+timestamp\b", q):
            errors.append(f"{tid}: filters on ingest timestamp instead of usage.date")
        if re.search(r'format: "yyyy-MM-dd"\)', q):
            errors.append(f"{tid}: formatTimestamp(..., format: \"yyyy-MM-dd\") without timezone: \"UTC\"")
        if "fetch logs" in q and 'in(product, {"claude_code", "cowork"})' not in q:
            errors.append(f"{tid}: coverage query compares logs (Claude Code + Cowork) with all products")
        if "fetch logs" in q and 'in(service.name, {"claude-code", "claude-code-desktop", "cowork"})' not in q:
            errors.append(f"{tid}: coverage query does not filter the logs side by service.name")
        vs = t["visualizationSettings"]
        rf = vs.get("singleValue", {}).get("recordField")
        if rf and not re.search(rf"\b{re.escape(rf)}\b", q):
            errors.append(f"{tid}: recordField {rf} not in query")
        for u in vs.get("unitsOverrides", []):
            if not re.search(rf"\b{re.escape(u['identifier'])}\b", q):
                errors.append(f"{tid}: unitsOverrides identifier {u['identifier']} not in query")
    return errors


def main():
    out_dtctl = HERE / "claude-usage-dashboard.json"
    out_upload = HERE / "claude-usage-dashboard.upload.json"
    out_dtctl.write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    out_upload.write_text(json.dumps(content, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {out_dtctl.name} ({len(tiles)} tiles) and {out_upload.name}")
    if "--check" in sys.argv:
        errors = check()
        for f in (out_dtctl, out_upload):
            json.loads(f.read_text(encoding="utf-8"))
        if errors:
            print("CHECK FAILED:\n  " + "\n  ".join(errors))
            sys.exit(1)
        print("CHECK OK: ids match, no overlaps, dedup rule + event.type filter in every data tile, UTC formatTimestamp, coverage filters, json round-trips")


if __name__ == "__main__":
    main()
