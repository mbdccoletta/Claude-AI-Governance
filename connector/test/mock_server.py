#!/usr/bin/env python3
"""Local mock of the three Anthropic sources + a Dynatrace bizevents sink. Stdlib only, no network.

Endpoints (GET unless noted):
  /v1/organizations/analytics/user_cost_report      Enterprise per-user cost rows (2 pages, cursor bound to params)
  /v1/organizations/analytics/user_usage_report     Enterprise per-user usage rows (2 pages)
  /v1/organizations/usage_report/claude_code        Console per-user Claude Code rows (2 pages)
  /v1/organizations/usage_report/messages           Console org-level buckets grouped by model+workspace
  POST /api/v2/bizevents/ingest                     Dynatrace classic bizevents ingest (JSON array or object)
  POST /platform/ingest/custom/events/<endpoint>    Dynatrace platform custom events ingest
  /_sink                                            all events received so far (JSON)
  /_stats                                           counts by source + request log
  POST /_reset                                      clear sink and counters

Behaviour under test: the FIRST request to each Anthropic path returns 429 with Retry-After: 1 (exercises backoff);
a cursor presented with different query params returns 400 (exercises "never change params mid-cursor");
a missing/invalid x-api-key returns 401.

Time-budget knobs (env at start-up, or POST /_config {"pages": N, "slow": true}; POST /_reset restores the env values):
  MOCK_PAGES=N   split every report into N small pages instead of 2 (large-org simulation)
  MOCK_SLOW=1    the first request for the THIRD page (page index 2) of any report answers 429 with Retry-After: 20, once

Usage: python3 mock_server.py [--port 8787]
"""
import argparse
import base64
import hashlib
import json
import os
import random
import sys
import threading
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ENV_CONFIG = {"pages": max(2, int(os.environ.get("MOCK_PAGES", "2") or 2)), "slow": os.environ.get("MOCK_SLOW", "") in ("1", "true", "yes")}
STATE = {"events": [], "requests": [], "throttled": set(), "slow_done": False, "config": dict(ENV_CONFIG), "lock": threading.Lock()}
USERS = ["alice@example.com", "bob@example.com", "carol@example.com", None]  # None = deleted/system account
USER_IDS = {"alice@example.com": "user_01A", "bob@example.com": "user_01B", "carol@example.com": "user_01C", None: "user_01DELETED"}
MODELS = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
ENT_PRODUCTS = ["chat", "claude_code", "cowork", "claude_design", "chat_cowork_unified"]
API_KEYS = ["ci-bot", "nightly-eval"]
WORKSPACES = [None, "wrkspc_01PLATFORM", "wrkspc_01DATA"]
ORG_ID = "org_mock01"


def rng(*parts):
    seed = int(hashlib.sha256("|".join(map(str, parts)).encode()).hexdigest()[:8], 16)
    return random.Random(seed)


def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


def day_range(starting_at, ending_at):
    s = datetime.fromisoformat(starting_at.replace("Z", "+00:00")).replace(hour=0, minute=0, second=0, microsecond=0)
    e = datetime.fromisoformat(ending_at.replace("Z", "+00:00")) if ending_at else s + timedelta(days=7)
    days = []
    d = s
    while d + timedelta(days=1) <= e and len(days) < 31:  # API semantics: a bucket is returned only if it ENDS before ending_at
        days.append(d)
        d += timedelta(days=1)
    return days


def cursor_for(path, params, page_no):
    canon = json.dumps({k: v for k, v in sorted(params.items()) if k != "page"}, sort_keys=True)
    sig = hashlib.sha256((path + canon).encode()).hexdigest()[:12]
    return "page_" + base64.urlsafe_b64encode(f"{sig}:{page_no}".encode()).decode()


def parse_cursor(path, params):
    page = params.get("page", [None])[0]
    if not page:
        return 0, None
    try:
        sig, n = base64.urlsafe_b64decode(page[5:].encode()).decode().split(":")
    except Exception:
        return None, "invalid cursor"
    expected = cursor_for(path, params, int(n))
    if expected != page:
        return None, "Pagination cursor does not match the query parameters that issued it. Restart from the first page."
    return int(n), None


def paginate(path, params, rows, page_size=None):
    """Split rows into config["pages"] pages (default 2, or by page_size) with cursors bound to the params."""
    n, err = parse_cursor(path, params)
    if err:
        return None, err
    limit = int(params.get("limit", ["1000"])[0])
    with STATE["lock"]:
        pages = STATE["config"]["pages"]
    size = page_size or max(1, min(limit, -(-len(rows) // pages)))  # ceil(rows / pages): force `pages` pages when possible
    start = n * size
    chunk = rows[start:start + size]
    has_more = start + size < len(rows)
    return {"data": chunk, "has_more": has_more, "next_page": cursor_for(path, params, n + 1) if has_more else None}, None


# ---------------------------------------------------------------- enterprise
def enterprise_rows(kind, params):
    days = day_range(params["starting_at"][0], params.get("ending_at", [None])[0])
    rows = []
    for d in days:
        for email in USERS:
            for product in ENT_PRODUCTS:
                for model in MODELS:
                    r = rng(kind, d.date(), email, product, model)
                    if r.random() < 0.55:  # sparse matrix
                        continue
                    base = {
                        "actor": {"type": "user_actor", "user_id": USER_IDS[email], "email_address": email,
                                  "name": "Deleted User" if email is None else email.split("@")[0].title(), "deleted": email is None},
                        "product": product, "model": model,
                        "starting_at": iso(d), "ending_at": iso(d + timedelta(days=1)),
                        "requests": r.randint(5, 400),
                    }
                    if kind == "cost":
                        amount = r.uniform(50, 90000)  # fractional cents
                        base.update({"amount": f"{amount:.6f}", "list_amount": f"{amount * 1.15:.6f}", "currency": "USD",
                                     "cost_type": None, "token_type": None})
                    else:
                        base.update({
                            "uncached_input_tokens": r.randint(1000, 900000), "output_tokens": r.randint(500, 300000),
                            "cache_read_input_tokens": r.randint(0, 2000000),
                            "cache_creation": {"ephemeral_5m_input_tokens": r.randint(0, 50000), "ephemeral_1h_input_tokens": r.randint(0, 5000)},
                            "server_tool_use": {"web_search_requests": r.randint(0, 20)},
                            "total_tokens": 0,
                        })
                    rows.append(base)
    return rows


def enterprise_report(kind, path, params):
    body, err = paginate(path, params, enterprise_rows(kind, params))
    if err:
        return 400, {"type": "error", "error": {"type": "invalid_request_error", "message": err}}
    refreshed = datetime.now(timezone.utc) - timedelta(hours=5)
    body.update({"data_refreshed_at": iso(refreshed), "organization_id": ORG_ID})
    return 200, body


# ------------------------------------------------------------------- console
def claude_code_rows(day):
    rows = []
    for email in [u for u in USERS if u]:
        for is_remote in (False, True):
            r = rng("cc", day, email, is_remote)
            if is_remote and r.random() < 0.5:
                continue
            mb = []
            for model in MODELS[:2]:
                if r.random() < 0.3:
                    continue
                mb.append({"model": model,
                           "tokens": {"input": r.randint(1000, 90000), "output": r.randint(500, 30000),
                                      "cache_read": r.randint(0, 500000), "cache_creation": r.randint(0, 40000)},
                           "estimated_cost": {"amount": r.randint(20, 5000), "currency": "USD"}})
            rows.append({
                "actor": {"type": "user_actor", "email_address": email},
                "core_metrics": {"commits_by_claude_code": r.randint(0, 10), "lines_of_code": {"added": r.randint(0, 900), "removed": r.randint(0, 400)},
                                 "num_sessions": r.randint(1, 12), "pull_requests_by_claude_code": r.randint(0, 3)},
                "customer_type": "api", "date": f"{day}T00:00:00Z", "is_remote": is_remote,
                "model_breakdown": mb, "organization_id": ORG_ID,
                "terminal_type": "claude-code-web" if is_remote else r.choice(["iTerm.app", "vscode", "WarpTerminal"]),
                "tool_actions": {"edit_tool": {"accepted": r.randint(0, 40), "rejected": r.randint(0, 5)},
                                 "write_tool": {"accepted": r.randint(0, 10), "rejected": r.randint(0, 2)}},
                "subscription_type": None,
            })
    for key in API_KEYS:
        r = rng("cc-api", day, key)
        rows.append({
            "actor": {"type": "api_actor", "api_key_name": key},
            "core_metrics": {"commits_by_claude_code": r.randint(0, 30), "lines_of_code": {"added": r.randint(0, 3000), "removed": r.randint(0, 1000)},
                             "num_sessions": r.randint(5, 60), "pull_requests_by_claude_code": r.randint(0, 10)},
            "customer_type": "api", "date": f"{day}T00:00:00Z", "is_remote": True,
            "model_breakdown": [{"model": "claude-sonnet-5-5",
                                 "tokens": {"input": r.randint(50000, 900000), "output": r.randint(10000, 200000), "cache_read": r.randint(0, 3000000), "cache_creation": r.randint(0, 100000)},
                                 "estimated_cost": {"amount": r.randint(500, 40000), "currency": "USD"}}],
            "organization_id": ORG_ID, "terminal_type": "github-actions", "tool_actions": {}, "subscription_type": None,
        })
    return rows


def claude_code_report(path, params):
    day = params["starting_at"][0]
    body, err = paginate(path, params, claude_code_rows(day))
    if err:
        return 400, {"type": "error", "error": {"type": "invalid_request_error", "message": err}}
    return 200, body


def messages_report(path, params):
    width = params.get("bucket_width", ["1d"])[0]
    if width == "1h":
        s = datetime.fromisoformat(params["starting_at"][0].replace("Z", "+00:00"))
        nowh = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
        hours = []
        h = s
        while h + timedelta(hours=1) <= nowh and len(hours) < int(params.get("limit", ["24"])[0]):
            hours.append(h)
            h += timedelta(hours=1)
        buckets = []
        for h in hours:
            r = rng("msg-h", h.isoformat())
            res = [] if r.random() < 0.6 else [{"account_id": None, "api_key_id": None, "workspace_id": None, "model": "claude-haiku-5-5",
                   "uncached_input_tokens": r.randint(10, 500), "output_tokens": r.randint(10, 300), "cache_read_input_tokens": 0,
                   "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 0}, "server_tool_use": {"web_search_requests": 0}}]
            buckets.append({"starting_at": iso(h), "ending_at": iso(h + timedelta(hours=1)), "results": res})
        return 200, {"data": buckets, "has_more": False, "next_page": None}
    days = day_range(params["starting_at"][0], params.get("ending_at", [None])[0])
    group_by = params.get("group_by[]", [])
    buckets = []
    for d in days:
        results = []
        for ws in (WORKSPACES if "workspace_id" in group_by else [None]):
            for model in (MODELS if "model" in group_by else [None]):
                r = rng("msg", d.date(), ws, model)
                results.append({
                    "account_id": None, "api_key_id": None, "workspace_id": ws, "model": model,
                    "uncached_input_tokens": r.randint(10000, 5000000), "output_tokens": r.randint(5000, 900000),
                    "cache_read_input_tokens": r.randint(0, 9000000),
                    "cache_creation": {"ephemeral_5m_input_tokens": r.randint(0, 300000), "ephemeral_1h_input_tokens": r.randint(0, 20000)},
                    "server_tool_use": {"web_search_requests": r.randint(0, 50)},
                    "context_window": None, "inference_geo": None, "service_tier": None, "speed": None, "service_account_id": None,
                })
        buckets.append({"starting_at": iso(d), "ending_at": iso(d + timedelta(days=1)), "results": results})
    return 200, {"data": buckets, "has_more": False, "next_page": None}


# ------------------------------------------------------------------- handler
class Handler(BaseHTTPRequestHandler):
    server_version = "mock-anthropic-dynatrace/1.0"

    def log_message(self, fmt, *args):  # quieter default logging
        sys.stderr.write("[mock] %s %s\n" % (self.command, self.path))

    def _send(self, status, body, ctype="application/json", headers=None):
        data = json.dumps(body).encode() if not isinstance(body, (bytes, str)) else (body.encode() if isinstance(body, str) else body)
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _record(self, path, status):
        with STATE["lock"]:
            STATE["requests"].append({"method": self.command, "path": path, "status": status})

    def do_GET(self):
        u = urlparse(self.path)
        params = parse_qs(u.query, keep_blank_values=True)
        path = u.path
        if path == "/_sink":
            with STATE["lock"]:
                return self._send(200, STATE["events"])
        if path == "/_stats":
            with STATE["lock"]:
                by_source, by_product = {}, {}
                for e in STATE["events"]:
                    by_source[e.get("source")] = by_source.get(e.get("source"), 0) + 1
                    by_product[e.get("product")] = by_product.get(e.get("product"), 0) + 1
                return self._send(200, {"events": len(STATE["events"]), "by_source": by_source, "by_product": by_product,
                                        "requests": STATE["requests"]})
        if path.startswith("/v1/organizations/"):
            key = self.headers.get("x-api-key")
            if not key or not key.startswith("sk-ant"):
                self._record(path, 401)
                return self._send(401, {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}})
            if not self.headers.get("anthropic-version"):
                self._record(path, 400)
                return self._send(400, {"type": "error", "error": {"type": "invalid_request_error", "message": "anthropic-version header required"}})
            with STATE["lock"]:
                first = path not in STATE["throttled"]
                STATE["throttled"].add(path)
            if first:
                self._record(path, 429)
                return self._send(429, {"type": "error", "error": {"type": "rate_limit_error", "message": "simulated"}}, headers={"Retry-After": "1"})
            page_no, _ = parse_cursor(path, params)
            with STATE["lock"]:
                slow_now = STATE["config"]["slow"] and not STATE["slow_done"] and page_no == 2
                if slow_now:
                    STATE["slow_done"] = True
            if slow_now:
                self._record(path, 429)
                return self._send(429, {"type": "error", "error": {"type": "rate_limit_error", "message": "simulated slow Retry-After"}}, headers={"Retry-After": "20"})
            if path == "/v1/organizations/analytics/user_cost_report":
                status, body = enterprise_report("cost", path, params)
            elif path == "/v1/organizations/analytics/user_usage_report":
                status, body = enterprise_report("usage", path, params)
            elif path == "/v1/organizations/usage_report/claude_code":
                status, body = claude_code_report(path, params)
            elif path == "/v1/organizations/usage_report/messages":
                status, body = messages_report(path, params)
            else:
                status, body = 404, {"type": "error", "error": {"type": "not_found_error", "message": path}}
            self._record(path, status)
            return self._send(status, body)
        self._record(path, 404)
        return self._send(404, {"error": "unknown path", "path": path})

    def do_POST(self):
        u = urlparse(self.path)
        path = u.path
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if path == "/_reset":
            with STATE["lock"]:
                STATE["events"].clear(); STATE["requests"].clear(); STATE["throttled"].clear()
                STATE["slow_done"] = False; STATE["config"] = dict(ENV_CONFIG)
            return self._send(200, {"ok": True})
        if path == "/_config":
            cfg = json.loads(raw.decode() or "{}")
            with STATE["lock"]:
                if "pages" in cfg:
                    STATE["config"]["pages"] = max(2, int(cfg["pages"]))
                if "slow" in cfg:
                    STATE["config"]["slow"] = bool(cfg["slow"])
                STATE["slow_done"] = False
                return self._send(200, {"ok": True, "config": STATE["config"]})
        if path == "/api/v2/bizevents/ingest" or path.startswith("/platform/ingest/custom/events/"):
            auth = self.headers.get("Authorization", "")
            if not (auth.startswith("Api-Token ") or auth.startswith("Bearer ")):
                self._record(path, 401)
                return self._send(401, {"error": {"code": 401, "message": "Authorization header missing"}})
            try:
                payload = json.loads(raw.decode() or "null")
            except json.JSONDecodeError as e:
                self._record(path, 400)
                return self._send(400, {"error": {"code": 400, "message": f"invalid JSON: {e}"}})
            items = payload if isinstance(payload, list) else [payload]
            bad = [i for i in items if not isinstance(i, dict) or "event.type" not in i]
            if bad:
                self._record(path, 400)
                return self._send(400, {"error": {"code": 400, "message": f"{len(bad)} items without event.type"}})
            with STATE["lock"]:
                STATE["events"].extend(items)
            self._record(path, 202)
            return self._send(202, b"", ctype="text/plain")
        self._record(path, 404)
        return self._send(404, {"error": "unknown path", "path": path})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--host", default="127.0.0.1")
    a = ap.parse_args()
    srv = ThreadingHTTPServer((a.host, a.port), Handler)
    print(f"mock server listening on http://{a.host}:{a.port}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
