#!/usr/bin/env python3
"""Hook unit/concurrency tests: isolated HOME, loopback OTLP sink, no network. Run: python3 test/hook_tests.py"""
import json, os, subprocess, sys, tempfile, threading, time, pathlib, random
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
HOOK = ROOT / "hooks" / "otel-hook.py"
SPANS = []

class Sink(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); body = json.loads(self.rfile.read(n) or b"{}")
        for rs in body.get("resourceSpans", []):
            for ss in rs.get("scopeSpans", []):
                SPANS.extend(ss.get("spans", []))
        self.send_response(200); self.end_headers(); self.wfile.write(b"{}")

def run_hook(env, event):
    return subprocess.run([sys.executable, str(HOOK)], input=json.dumps(event), text=True, env=env, capture_output=True, timeout=20)

def attrs(span):
    return {a["key"]: list(a["value"].values())[0] for a in span.get("attributes", [])}

def main():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Sink); port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    home = tempfile.mkdtemp(prefix="hook-home-"); claude = pathlib.Path(home) / ".claude"; claude.mkdir()
    (claude / "settings.json").write_text(json.dumps({"model": "claude-test"}))
    env = dict(os.environ, HOME=home, CLAUDE_CODE_ENTRYPOINT="claude-desktop")
    failures = []
    def check(cond, msg):
        print(("ok   " if cond else "FAIL ") + msg); failures.append(msg) if not cond else None

    # --- transcript with 3 assistant messages in the turn (+1 before the turn) and costUSD on one
    tr = pathlib.Path(home) / "t.jsonl"
    before = {"message": {"role": "assistant", "model": "claude-old", "usage": {"input_tokens": 999, "output_tokens": 999}, "content": [{"type": "text", "text": "old"}]}}
    tr.write_text(json.dumps(before) + "\n")
    def add_turn():
        with open(tr, "a") as f:
            for i, (inp, cr, out) in enumerate([(10, 100, 5), (20, 200, 6), (30, 300, 7)]):
                m = {"message": {"role": "assistant", "model": "claude-x", "usage": {"input_tokens": inp, "cache_read_input_tokens": cr, "cache_creation_input_tokens": 1, "output_tokens": out}, "content": [{"type": "text", "text": f"reply {i}"}]}}
                if i == 1: m["costUSD"] = 0.25
                f.write(json.dumps(m) + "\n")

    for capture in ("false", "true"):
        SPANS.clear()
        (claude / "otel-attrs.json").write_text(json.dumps({"_collector_port": port, "_capture_prompts": capture, "squad": "t"}))
        sid = f"sess-{capture}"
        base = {"session_id": sid, "transcript_path": str(tr)}
        r = run_hook(env, dict(base, hook_event_name="UserPromptSubmit", prompt="hello <system-reminder>noise</system-reminder> world"))
        check(r.returncode == 0, f"[{capture}] UserPromptSubmit exits 0")
        state_path = claude / "otel-state" / f"{sid}.json"
        st = json.loads(state_path.read_text())
        check((st.get("prompt_text") == "hello world") if capture == "true" else st.get("prompt_text") == "", f"[{capture}] prompt persisted only when capture on (got {st.get('prompt_text')!r})")
        check(oct(state_path.stat().st_mode & 0o777) == "0o600", f"[{capture}] state file is 0600")
        check(oct((claude / "otel-state").stat().st_mode & 0o777) == "0o700", f"[{capture}] state dir is 0700")
        # 8 concurrent tool calls, same tool name, distinct tool_use_id
        def pair(i):
            ev = dict(base, hook_event_name="PreToolUse", tool_name="Read", tool_use_id=f"tu{i}", tool_input={"file_path": f"/f{i}"})
            run_hook(env, ev); time.sleep(random.random() * 0.05)
            run_hook(env, dict(ev, hook_event_name="PostToolUse", tool_response={"out": i}))
        ths = [threading.Thread(target=pair, args=(i,)) for i in range(8)]
        [t.start() for t in ths]; [t.join() for t in ths]
        time.sleep(0.5)
        tools = [s for s in SPANS if s["name"] == "claude.tool.Read"]
        check(len(tools) == 8, f"[{capture}] 8 parallel tool calls -> 8 tool spans (got {len(tools)})")
        check(len({s["spanId"] for s in tools}) == 8 and len({s["traceId"] for s in tools}) == 1, f"[{capture}] distinct span ids, one trace id")
        st = json.loads(state_path.read_text()); check(st.get("tools") == {}, f"[{capture}] no stale tool records after Post")
        io_present = any("claude.tool_input" in attrs(s) or "claude.tool_response" in attrs(s) for s in tools)
        check(io_present == (capture == "true"), f"[{capture}] tool I/O attributes present only when capture on (present={io_present})")
        # Stop: tokens summed over the turn, cost from transcript only
        add_turn()
        r = run_hook(env, dict(base, hook_event_name="Stop")); time.sleep(0.5)
        chat = [s for s in SPANS if s["name"].startswith("chat ")]
        check(len(chat) == 1 and chat[0]["name"] == "chat claude-x", f"[{capture}] one chat span named after the transcript model")
        a = attrs(chat[0]) if chat else {}
        check(a.get("gen_ai.usage.input_tokens") == "663" and a.get("gen_ai.usage.output_tokens") == "18", f"[{capture}] tokens summed over the turn, excluding messages before it (in={a.get('gen_ai.usage.input_tokens')} out={a.get('gen_ai.usage.output_tokens')})")
        check(abs(float(a.get("gen_ai.usage.cost_usd", 0)) - 0.25) < 1e-9, f"[{capture}] cost taken from transcript costUSD only")
        check(("gen_ai.prompt.0.content" in a) == (capture == "true"), f"[{capture}] prompt content only when capture on")
        if capture == "true":
            check(a.get("gen_ai.prompt.0.content") == "hello world" and a.get("gen_ai.completion.0.content") == "reply 2", f"[{capture}] cleaned prompt and last completion")
        st = json.loads(state_path.read_text()); check(set(st) == {"trace_id", "transcript_offset"}, f"[{capture}] after Stop only trace_id+offset remain")
        # Notification on an unknown session must not create a state file
        r = run_hook(env, {"session_id": "ghost", "hook_event_name": "Notification"})
        check(not (claude / "otel-state" / "ghost.json").exists(), f"[{capture}] other events never create state files")
        # SessionEnd removes the state and lock
        run_hook(env, dict(base, hook_event_name="SessionEnd"))
        check(not state_path.exists() and not pathlib.Path(str(state_path) + ".lock").exists(), f"[{capture}] SessionEnd removes state and lock")
        # a second turn starts from the new offset (no double counting of the previous turn)
        tr.write_text(tr.read_text())  # unchanged
    # --- hook installed mid-session: Stop with no stored turn start must count only the current turn
    SPANS.clear()
    (claude / "otel-attrs.json").write_text(json.dumps({"_collector_port": port, "_capture_prompts": "false"}))
    tr2 = pathlib.Path(home) / "mid.jsonl"
    hist = []
    for k in range(3):  # three earlier turns with large usage
        hist.append({"type": "user", "message": {"role": "user", "content": f"old prompt {k}"}})
        hist.append({"type": "assistant", "message": {"role": "assistant", "model": "claude-x", "usage": {"input_tokens": 100000, "output_tokens": 50000}, "content": [{"type": "text", "text": "old"}]}})
        hist.append({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": f"t{k}", "content": "r"}]}})
    hist.append({"type": "user", "isMeta": True, "message": {"role": "user", "content": "<system-reminder>meta</system-reminder>"}})
    hist.append({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "current prompt"}]}})
    hist.append({"type": "assistant", "message": {"role": "assistant", "model": "claude-y", "usage": {"input_tokens": 7, "cache_read_input_tokens": 3, "output_tokens": 2}, "content": [{"type": "text", "text": "a"}]}})
    hist.append({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "tz", "content": "r"}]}})
    hist.append({"type": "assistant", "message": {"role": "assistant", "model": "claude-y", "usage": {"input_tokens": 5, "output_tokens": 4}, "content": [{"type": "text", "text": "b"}]}})
    tr2.write_text("".join(json.dumps(h) + "\n" for h in hist))
    run_hook(env, {"session_id": "mid", "hook_event_name": "Stop", "transcript_path": str(tr2)}); time.sleep(0.5)
    chat = [s for s in SPANS if s["name"].startswith("chat")]
    a = attrs(chat[0]) if chat else {}
    check(len(chat) == 1 and int(a.get("gen_ai.usage.input_tokens", -1)) == 15 and int(a.get("gen_ai.usage.output_tokens", -1)) == 6,
          f"mid-session install: Stop counts only the turn after the last human prompt (in={a.get('gen_ai.usage.input_tokens')}, out={a.get('gen_ai.usage.output_tokens')})")
    # no human prompt at all -> no token attributes instead of the whole history
    SPANS.clear()
    tr3 = pathlib.Path(home) / "noprompt.jsonl"
    tr3.write_text(json.dumps({"type": "assistant", "message": {"role": "assistant", "model": "claude-x", "usage": {"input_tokens": 999999, "output_tokens": 1}, "content": []}}) + "\n")
    run_hook(env, {"session_id": "noprompt", "hook_event_name": "Stop", "transcript_path": str(tr3)}); time.sleep(0.5)
    chat = [s for s in SPANS if s["name"].startswith("chat")]
    a = attrs(chat[0]) if chat else {}
    check(len(chat) == 1 and "gen_ai.usage.input_tokens" not in a, "no human prompt in transcript: span carries no token counts")

    # dead collector must not block
    (claude / "otel-attrs.json").write_text(json.dumps({"_collector_port": 1, "_capture_prompts": "false"}))
    t0 = time.time(); run_hook(env, {"session_id": "x", "hook_event_name": "UserPromptSubmit", "prompt": "p", "transcript_path": str(tr)}); run_hook(env, {"session_id": "x", "hook_event_name": "Stop", "transcript_path": str(tr)})
    check(time.time() - t0 < 12, f"dead collector: hook returns quickly ({time.time()-t0:.1f}s)")
    srv.shutdown()
    print("\n" + ("HOOK TESTS PASSED" if not failures else f"HOOK TESTS FAILED: {len(failures)}"))
    sys.exit(1 if failures else 0)

if __name__ == "__main__":
    main()
