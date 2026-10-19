#!/usr/bin/env python3
# hook-version: 1.7.0
"""
Dynatrace AI Governance For Devs — Claude Code OTel Hook v2
Captura: prompt, model, tokens, custo, duração total e tool calls (input+output).
Requer: Python 3.6+ (sem dependências externas)
"""
import sys, json, time, random, os, glob, urllib.request, threading

DEFAULT_PORT  = 4318
ATTRS_FILE    = os.path.expanduser("~/.claude/otel-attrs.json")
SERVICE_NAME  = "claude-code"
GEN_AI_SYSTEM = "anthropic"
STATE_DIR     = os.path.expanduser("~/.claude/otel-state")
SETTINGS_FILE = os.path.expanduser("~/.claude/settings.json")
MAX_LEN       = 4096  # corta atributos muito longos

def trunc(v, n=MAX_LEN):
    s = json.dumps(v) if not isinstance(v, str) else v
    return s[:n] + " ...[truncated]" if len(s) > n else s

def rand_trace(): return f"{random.getrandbits(128):032x}"
def rand_span():  return f"{random.getrandbits(64):016x}"

def get_model():
    try:
        with open(SETTINGS_FILE, encoding='utf-8') as f:
            return json.load(f).get("model", "claude")
    except Exception:
        return os.environ.get("CLAUDE_MODEL", "claude")

def read_otel_config():
    """Read custom attributes and config written by the VS Code extension.
    Returns (attrs_dict, capture_prompts_bool).
    Reserved keys prefixed with '_' are extracted and not added as span attributes.
    """
    try:
        with open(ATTRS_FILE, encoding='utf-8') as f:
            data = json.load(f)
        capture_prompts = str(data.get("_capture_prompts", "false")).lower() == "true"
        # Reserved keys are configuration, never span attributes.
        attrs = {k: v for k, v in data.items() if not str(k).startswith("_")}
        return attrs, capture_prompts
    except Exception:
        return {}, False

def collector_url():
    """OTLP HTTP traces URL of the local collector. The extension writes the port
    the collector actually bound to (it may differ from 4318 if that was busy).
    Uses 127.0.0.1 because the collector only listens on loopback."""
    port = DEFAULT_PORT
    try:
        with open(ATTRS_FILE, encoding='utf-8') as f:
            candidate = int(json.load(f).get("_collector_port", DEFAULT_PORT))
        if 1 <= candidate <= 65535:
            port = candidate
    except Exception:
        pass
    return f"http://127.0.0.1:{port}/v1/traces"

def read_last_assistant(session_id):
    """Read model, usage and last text response from the Claude Code session JSONL."""
    result = {"text": "", "model": "", "input_tokens": None, "output_tokens": None}
    try:
        pattern = os.path.expanduser(f"~/.claude/projects/*/{session_id}.jsonl")
        files = glob.glob(pattern)
        if not files:
            return result
        with open(files[0], encoding='utf-8') as f:
            for line in f:
                try:
                    r = json.loads(line)
                    msg = r.get("message") or r
                    if msg.get("role") != "assistant":
                        continue
                    # Model name (e.g. "claude-sonnet-4-6")
                    if msg.get("model"):
                        result["model"] = msg["model"]
                    # Token usage — sum input + cache tokens for real total
                    usage = msg.get("usage") or {}
                    if usage:
                        inp = (usage.get("input_tokens") or 0) + \
                              (usage.get("cache_read_input_tokens") or 0) + \
                              (usage.get("cache_creation_input_tokens") or 0)
                        out = usage.get("output_tokens") or 0
                        if inp: result["input_tokens"] = inp
                        if out: result["output_tokens"] = out
                    # Last text response
                    content = msg.get("content", [])
                    if isinstance(content, list):
                        texts = [b["text"] for b in content
                                 if isinstance(b, dict) and b.get("type") == "text" and b.get("text", "").strip()]
                        if texts:
                            result["text"] = texts[0]
                except Exception:
                    continue
    except Exception:
        pass
    return result

def send_spans(spans_list, resource_attrs=None):
    if not spans_list:
        return
    res_attrs = resource_attrs or []
    res_attrs += [
        {"key": "service.name",           "value": {"stringValue": SERVICE_NAME}},
        {"key": "deployment.environment", "value": {"stringValue": "dev"}},
    ]
    payload = {"resourceSpans": [{"resource": {"attributes": res_attrs},
        "scopeSpans": [{"scope": {"name": "claude-code-hooks", "version": "2.0"},
            "spans": spans_list}]}]}
    try:
        req = urllib.request.Request(
            collector_url(), data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        urllib.request.urlopen(req, timeout=3)
    except Exception:
        pass

def make_span(trace_id, span_id, name, start_ns, end_ns, attrs, parent_id=None, kind=1, events=None):
    s = {
        "traceId": trace_id, "spanId": span_id, "name": name, "kind": kind,
        "startTimeUnixNano": str(start_ns), "endTimeUnixNano": str(end_ns),
        "attributes": attrs, "status": {"code": 1}
    }
    if parent_id:
        s["parentSpanId"] = parent_id
    if events:
        s["events"] = events
    return s

def as_messages(role, text):
    """Format prompt/completion in OpenAI messages format for Dynatrace AI Observability."""
    return json.dumps([{"role": role, "content": trunc(text)}])

def content_event(name, attr_key, role, text, ts_ns):
    """Span event in OTel GenAI format — used by Dynatrace AI Observability app."""
    return {
        "name": name,
        "timeUnixNano": str(ts_ns),
        "attributes": [{"key": attr_key, "value": {"stringValue": as_messages(role, text)}}]
    }

def attr_s(k, v): return {"key": k, "value": {"stringValue": str(v)}}
def attr_d(k, v): return {"key": k, "value": {"doubleValue": float(v)}}
def attr_i(k, v): return {"key": k, "value": {"intValue": str(int(v))}}

def main():
    try:
        event = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    hook_event = event.get("hook_event_name", "unknown")
    tool_name  = event.get("tool_name", "")
    session_id = event.get("session_id") or "default"

    os.makedirs(STATE_DIR, exist_ok=True)
    state_file = os.path.join(STATE_DIR, f"{session_id}.json")

    state = {}
    if os.path.exists(state_file):
        try:
            with open(state_file, encoding='utf-8') as f:
                state = json.load(f)
        except Exception:
            pass

    if not state.get("trace_id"):
        state["trace_id"] = rand_trace()

    trace_id    = state["trace_id"]
    now_ns      = int(time.time() * 1e9)
    raw_attrs, capture_prompts = read_otel_config()
    custom_attrs = [attr_s(k, v) for k, v in raw_attrs.items()]

    # ── UserPromptSubmit: gravar início da conversa ──────────────────────────
    if hook_event == "UserPromptSubmit":
        state["turn_start_ns"]  = now_ns
        state["turn_span_id"]   = rand_span()
        state["prompt_text"]    = event.get("prompt", "")
        state["model"]          = get_model()
        with open(state_file, "w", encoding='utf-8') as f:
            json.dump(state, f)
        sys.exit(0)

    # ── PreToolUse: gravar início da tool call ───────────────────────────────
    if hook_event == "PreToolUse" and tool_name:
        state.setdefault("tools", {})[tool_name] = {
            "start_ns":   now_ns,
            "span_id":    rand_span(),
            "tool_input": trunc(event.get("tool_input", "")),
        }
        with open(state_file, "w", encoding='utf-8') as f:
            json.dump(state, f)
        sys.exit(0)

    # ── PostToolUse: emitir span da tool com duração real ───────────────────
    if hook_event == "PostToolUse" and tool_name:
        ts = state.get("tools", {}).pop(tool_name, {})
        start_ns    = ts.get("start_ns", now_ns)
        span_id     = ts.get("span_id",  rand_span())
        tool_input  = ts.get("tool_input", "")
        tool_resp   = trunc(event.get("tool_response", ""))
        parent_id   = state.get("turn_span_id")
        dur_ms      = (now_ns - start_ns) / 1e6

        attrs = [
            attr_s("gen_ai.system",       GEN_AI_SYSTEM),
            attr_s("claude.session_id",   session_id),
            attr_s("claude.tool_name",    tool_name),
            attr_s("claude.tool_input",   tool_input),
            attr_s("claude.tool_response",tool_resp),
            attr_d("claude.duration_ms",  round(dur_ms, 2)),
        ] + custom_attrs
        send_spans([make_span(trace_id, span_id, f"claude.tool.{tool_name}",
                              start_ns, now_ns, attrs, parent_id)])
        with open(state_file, "w", encoding='utf-8') as f:
            json.dump(state, f)
        sys.exit(0)

    # ── Stop: emitir span raiz da conversa (UserPromptSubmit → Stop) ────────
    if hook_event == "Stop":
        span_id     = state.get("turn_span_id") or rand_span()
        start_ns    = state.get("turn_start_ns", now_ns)
        prompt_text = state.get("prompt_text", "")
        model       = state.get("model", get_model())
        dur_ms      = (now_ns - start_ns) / 1e6

        # Ler modelo, tokens e resposta diretamente do JSONL da sessão
        assistant   = read_last_assistant(session_id)
        completion  = assistant["text"]
        # JSONL tem o nome exato do modelo (ex: "claude-sonnet-4-6"); fallback para settings
        if assistant["model"]:
            model = assistant["model"]
        input_tok   = assistant["input_tokens"]
        output_tok  = assistant["output_tokens"]
        cost_usd    = event.get("cost_usd") or event.get("total_cost_usd")

        attrs = [
            attr_s("gen_ai.system",          GEN_AI_SYSTEM),
            attr_s("gen_ai.operation.name",  "chat"),
            attr_s("gen_ai.request.model",   model),
            attr_s("gen_ai.response.model",  model),
            attr_s("gen_ai.conversation.id", session_id),
            attr_s("claude.session_id",      session_id),
            attr_d("claude.duration_ms",     round(dur_ms, 2)),
        ] + custom_attrs
        if capture_prompts:
            attrs += [
                attr_s("gen_ai.prompt.0.role",        "user"),
                attr_s("gen_ai.prompt.0.content",     trunc(prompt_text)),
                attr_s("gen_ai.completion.0.role",    "assistant"),
                attr_s("gen_ai.completion.0.content", trunc(completion)),
            ]
        if input_tok  is not None: attrs.append(attr_i("gen_ai.usage.input_tokens",  input_tok))
        if output_tok is not None: attrs.append(attr_i("gen_ai.usage.output_tokens", output_tok))
        if cost_usd   is not None: attrs.append(attr_d("gen_ai.usage.cost_usd",      cost_usd))

        # Span events com conteúdo — enviados apenas se capture_prompts estiver habilitado
        events = []
        if capture_prompts:
            if prompt_text:
                events.append(content_event("gen_ai.content.prompt",    "gen_ai.prompt",     "user",      prompt_text, start_ns))
            if completion:
                events.append(content_event("gen_ai.content.completion", "gen_ai.completion", "assistant", completion,  now_ns))

        # Span name "chat {model}" segue a convenção OTel GenAI — reconhecida pelo app AI Observability
        # kind=3 (CLIENT) identifica chamadas LLM no padrão GenAI semântico
        send_spans([make_span(trace_id, span_id, f"chat {model}",
                              start_ns, now_ns, attrs, kind=3, events=events)])

        try: os.remove(state_file)
        except Exception: pass
        sys.exit(0)

    # ── Outros eventos (Notification, etc.) ─────────────────────────────────
    attrs = [attr_s("gen_ai.system", GEN_AI_SYSTEM), attr_s("claude.session_id", session_id)]
    send_spans([make_span(trace_id, rand_span(), f"claude.{hook_event.lower()}",
                          now_ns, now_ns + 1_000_000, attrs)])
    with open(state_file, "w") as f:
        json.dump(state, f)

if __name__ == "__main__":
    t = threading.Thread(target=main, daemon=True)
    t.start()
    t.join(10)  # max 10s — prevents blocking Claude Code indefinitely
