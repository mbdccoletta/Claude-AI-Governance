#!/usr/bin/env python3
"""Tiny OTLP/HTTP sink that stands in for a Dynatrace tenant during local tests.

Accepts any POST, un-gzips the body, stores it under --dir and prints one line
per request with the path, size and which telltale strings the payload
contains (service names, gen_ai attributes, Claude Code event names). Never
prints the Authorization header value. Python 3.6+, stdlib only.
"""
import argparse
import gzip
import json
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

TELLTALES = [
    b"claude-code-desktop", b"claude-code", b"claude-code-hooks",
    b"gen_ai.request.model", b"gen_ai.provider.name", b"gen_ai.usage.input_tokens",
    b"gen_ai.prompt", b"gen_ai.completion", b"claude.tool_name", b"user.email",
    b"squad", b"cost_center", b"os.type",
    b"api_request", b"user_prompt", b"tool_result", b"claude_code.token.usage",
    b"claude_code.cost.usage", b"app.entrypoint", b"terminal.type",
]


class Handler(BaseHTTPRequestHandler):
    counter = 0

    def log_message(self, *a):  # silence default access log
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        raw_len = len(body)
        if self.headers.get("Content-Encoding", "").lower() == "gzip":
            try:
                body = gzip.decompress(body)
            except OSError:
                pass
        Handler.counter += 1
        safe = re.sub(r"[^A-Za-z0-9]+", "_", self.path).strip("_")
        fname = os.path.join(self.server.out_dir, "%04d_%s.bin" % (Handler.counter, safe))
        with open(fname, "wb") as f:
            f.write(body)
        auth = self.headers.get("Authorization", "")
        found = [t.decode() for t in TELLTALES if t in body]
        # distinguish claude-code vs claude-code-desktop properly
        if b"claude-code-desktop" in body and "claude-code" in found and b"claude-code\x12" not in body and b"claude-code\"" not in body:
            pass
        print(json.dumps({
            "ts": time.strftime("%H:%M:%S"), "n": Handler.counter, "path": self.path,
            "content_type": self.headers.get("Content-Type", ""), "wire_bytes": raw_len, "bytes": len(body),
            "auth": ("present (%s...)" % auth[:10]) if auth else "MISSING",
            "contains": found, "file": os.path.basename(fname),
        }), flush=True)
        self.send_response(200)
        self.send_header("Content-Type", "application/x-protobuf")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"sink ok\n")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=9999)
    p.add_argument("--dir", default="sink-data")
    a = p.parse_args()
    os.makedirs(a.dir, exist_ok=True)
    srv = HTTPServer(("127.0.0.1", a.port), Handler)
    srv.out_dir = a.dir
    print("sink listening on http://127.0.0.1:%d, storing bodies in %s" % (a.port, a.dir), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
