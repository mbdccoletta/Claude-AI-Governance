#!/usr/bin/env python3
"""Import the claude.ai Team spend CSV export as claude.usage.daily bizevents (source=team_csv).

Team plans have no per-user API. The admin exports the spend CSV from claude.ai > Settings > Analytics
(up to 90 days, refreshed daily with a 1-day lag). This script maps it to the connector schema (see ../schema.md)
and POSTs it to the tenant's bizevents ingest endpoint. Python 3 stdlib only.

Expected columns (header names are normalised: case-insensitive, spaces -> underscores):
  user email, account UUID, product, model, model family, total_requests, total_prompt_tokens,
  total_completion_tokens, total_net_spend_usd, total_gross_spend_usd

Usage:
  export DT_INGEST_TOKEN=dt0c01....            # scope: bizevents.ingest (classic) or openpipeline.events.custom (platform)
  python3 import_team_spend.py --csv export.csv --date 2026-10-18 --tenant https://abc12345.live.dynatrace.com
  python3 import_team_spend.py --csv export.csv --date 2026-10-18 --dry-run          # prints payload, sends nothing

Options:
  --date         UTC day the export covers (period end). Becomes usage.date on every event. Required.
  --org-id       optional label copied to org.id
  --endpoint     ingest path (default /api/v2/bizevents/ingest; e.g. /platform/ingest/custom/events/claude.usage)
  --batch-size   events per POST (default 500; ingest limit is 5 MiB per request)
  --token-env    env var holding the token (default DT_INGEST_TOKEN)
"""
import argparse
import csv
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
import urllib.parse

SCHEMA_EVENT_TYPE = "claude.usage.daily"
SCHEMA_VERSION = "1.0"
EVENT_PROVIDER = "dt-ai-observability-claude"
SOURCE = "team_csv"

PRODUCT_MAP = {
    "chat": "chat", "chat_cowork_unified": "chat", "claude-tag": "chat", "claude_in_chrome": "chat",
    "claude_code": "claude_code", "claude code": "claude_code",
    "cowork": "cowork", "office_agent": "cowork",
    "claude_design": "design", "design": "design",
    "api": "api",
}

COLUMN_ALIASES = {
    "user_email": ["user_email", "email", "user", "member_email"],
    "account_uuid": ["account_uuid", "account_id", "user_uuid", "uuid"],
    "product": ["product", "surface"],
    "model": ["model", "model_name"],
    "model_family": ["model_family", "family"],
    "total_requests": ["total_requests", "requests"],
    "total_prompt_tokens": ["total_prompt_tokens", "prompt_tokens", "input_tokens"],
    "total_completion_tokens": ["total_completion_tokens", "completion_tokens", "output_tokens"],
    "total_net_spend_usd": ["total_net_spend_usd", "net_spend_usd", "net_spend"],
    "total_gross_spend_usd": ["total_gross_spend_usd", "gross_spend_usd", "gross_spend"],
}


def norm_header(h):
    return re.sub(r"[^a-z0-9]+", "_", (h or "").strip().lower()).strip("_")


def normalize_product(raw):
    if raw is None or str(raw).strip() == "":
        return "other"
    return PRODUCT_MAP.get(str(raw).strip().lower(), "other")


def dedup_key(email, product, model, date, source):
    """First 32 hex chars of SHA-256("email|product|model|date|source"). Byte-identical to workflow/lib/common.js."""
    parts = ["" if v is None else str(v) for v in (email, product, model, date, source)]
    return hashlib.sha256("|".join(parts).encode("utf-8")).hexdigest()[:32]


def to_int(v):
    try:
        return int(round(float(str(v).replace(",", "").strip() or 0)))
    except ValueError:
        return 0


def to_float(v):
    try:
        return round(float(str(v).replace("$", "").replace(",", "").strip() or 0), 6)
    except ValueError:
        return 0.0


def resolve_columns(fieldnames):
    normalized = {norm_header(f): f for f in fieldnames}
    resolved = {}
    for key, aliases in COLUMN_ALIASES.items():
        for a in aliases:
            if a in normalized:
                resolved[key] = normalized[a]
                break
    missing = [k for k in ("user_email", "product", "total_prompt_tokens", "total_completion_tokens", "total_net_spend_usd") if k not in resolved]
    if missing:
        raise SystemExit(f"CSV is missing required columns: {missing}. Found: {list(fieldnames)}")
    return resolved


def read_csv(path, date, org_id):
    with open(path, newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        cols = resolve_columns(reader.fieldnames or [])
        g = lambda row, k: row.get(cols[k]) if k in cols else None  # noqa: E731
        merged = {}
        for row in reader:
            email = (g(row, "user_email") or "").strip().lower() or None
            product_raw = g(row, "product")
            product = normalize_product(product_raw)
            model = (g(row, "model") or "unknown").strip() or "unknown"
            key = (email or "unknown", product, model)
            ev = merged.get(key)
            if ev is None:
                ev = {
                    "event.type": SCHEMA_EVENT_TYPE,
                    "event.provider": EVENT_PROVIDER,
                    "schema.version": SCHEMA_VERSION,
                    "user.email": email,
                    "user.id": (g(row, "account_uuid") or None),
                    "product": product,
                    "product.raw": product_raw,
                    "model": model,
                    "model.family": (g(row, "model_family") or None),
                    "tokens.input": 0,
                    "tokens.output": 0,
                    "tokens.cache_read": 0,       # not in the Team export
                    "tokens.cache_creation": 0,   # not in the Team export
                    "tokens.total": 0,
                    "requests": 0,
                    "cost_usd": 0.0,
                    "cost.gross_usd": 0.0,
                    "source": SOURCE,
                    "usage.date": date,
                    "usage.timestamp": f"{date}T00:00:00Z",
                    "usage.complete": True,
                    "org.id": org_id,
                    "dedup.key": dedup_key(email or "unknown", product, model, date, SOURCE),
                }
                merged[key] = ev
            ev["tokens.input"] += to_int(g(row, "total_prompt_tokens"))
            ev["tokens.output"] += to_int(g(row, "total_completion_tokens"))
            ev["tokens.total"] = ev["tokens.input"] + ev["tokens.output"]
            ev["requests"] += to_int(g(row, "total_requests"))
            ev["cost_usd"] = round(ev["cost_usd"] + to_float(g(row, "total_net_spend_usd")), 6)
            ev["cost.gross_usd"] = round(ev["cost.gross_usd"] + to_float(g(row, "total_gross_spend_usd")), 6)
        return list(merged.values())


def post_batch(url, token, batch, retries=3):
    body = json.dumps(batch).encode("utf-8")
    if len(body) > 5 * 1024 * 1024:
        raise SystemExit(f"batch too large ({len(body)} bytes > 5 MiB); lower --batch-size")
    import time as _time
    for attempt in range(retries + 1):
        req = urllib.request.Request(url, data=body, method="POST", headers={
            "Content-Type": "application/json; charset=utf-8",
            "Authorization": f"Api-Token {token}",
            "User-Agent": "dt-ai-observability-claude/1.0 (team csv importer)",
        })
        try:
            with urllib.request.urlopen(req, timeout=60) as res:
                return res.status, res.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            text = e.read().decode("utf-8", "replace")
            if e.code in (429, 500, 502, 503, 504) and attempt < retries:
                wait = min(30, 2 ** attempt * 2)
                print(f"[team_csv] HTTP {e.code}, retrying in {wait}s", file=sys.stderr); _time.sleep(wait); continue
            return e.code, text
        except urllib.error.URLError as e:
            if attempt < retries:
                _time.sleep(2 ** attempt * 2); continue
            raise SystemExit(f"ingest failed: {e}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--csv", required=True)
    ap.add_argument("--date", required=True, help="UTC day the export covers, YYYY-MM-DD")
    ap.add_argument("--tenant", help="https://<env>.live.dynatrace.com (or apps.dynatrace.com for platform endpoints)")
    ap.add_argument("--endpoint", default="/api/v2/bizevents/ingest")
    ap.add_argument("--org-id", default=None)
    ap.add_argument("--batch-size", type=int, default=500)
    ap.add_argument("--token-env", default="DT_INGEST_TOKEN")
    ap.add_argument("--dry-run", action="store_true", help="print the events (JSON array) instead of sending")
    ap.add_argument("--preview", action="store_true", help="print a JSON summary of what would be sent (no tenant needed) and exit")
    ap.add_argument("--allow-http", action="store_true", help="allow a plain http:// tenant URL (local tests only)")
    a = ap.parse_args()

    try:
        import datetime as _dt
        _dt.datetime.strptime(a.date, "%Y-%m-%d")
    except ValueError:
        raise SystemExit("--date must be a valid YYYY-MM-DD day")

    events = read_csv(a.csv, a.date, a.org_id)
    total_cost = round(sum(e["cost_usd"] for e in events), 2)
    print(f"[team_csv] {len(events)} events from {a.csv} for {a.date}; users={len({e['user.email'] for e in events})} net_spend_usd={total_cost}", file=sys.stderr)

    if a.preview:
        by_product = {}
        for e in events:
            d = by_product.setdefault(e["product"], {"events": 0, "requests": 0, "tokens": 0, "cost_usd": 0.0})
            d["events"] += 1; d["requests"] += e["requests"]; d["tokens"] += e["tokens.total"]; d["cost_usd"] = round(d["cost_usd"] + e["cost_usd"], 2)
        print(json.dumps({
            "file": a.csv, "date": a.date, "org_id": a.org_id, "source": SOURCE,
            "events": len(events), "users": len({e["user.email"] for e in events if e["user.email"]}),
            "rows_without_email": sum(1 for e in events if not e["user.email"]),
            "unknown_products": sorted({str(e["product.raw"]) for e in events if e["product"] == "other"}),
            "models": sorted({e["model"] for e in events}),
            "requests": sum(e["requests"] for e in events), "tokens_total": sum(e["tokens.total"] for e in events),
            "net_spend_usd": total_cost, "gross_spend_usd": round(sum(e["cost.gross_usd"] for e in events), 2),
            "by_product": by_product,
        }, indent=2))
        return

    if a.dry_run:
        print(json.dumps(events, indent=2))
        return

    if not a.tenant:
        raise SystemExit("--tenant is required unless --dry-run")
    token = os.environ.get(a.token_env)
    if not token:
        raise SystemExit(f"env var {a.token_env} is not set")
    _host = urllib.parse.urlparse(a.tenant).hostname or ""
    if not a.tenant.lower().startswith("https://") and not a.allow_http and _host not in ("127.0.0.1", "localhost", "::1"):
        raise SystemExit("--tenant must be https:// (the token travels in a header); use --allow-http only against a local mock")
    url = a.tenant.rstrip("/") + a.endpoint
    sent = 0
    for i in range(0, len(events), a.batch_size):
        batch = events[i:i + a.batch_size]
        status, text = post_batch(url, token, batch)
        if status not in (200, 201, 202, 204):
            raise SystemExit(f"ingest failed: HTTP {status} {text[:300]}")
        sent += len(batch)
        print(f"[team_csv] ingested {sent}/{len(events)} (HTTP {status})", file=sys.stderr)
    print(json.dumps({"source": SOURCE, "events": len(events), "ingested": sent, "date": a.date, "endpoint": url}))


if __name__ == "__main__":
    main()
