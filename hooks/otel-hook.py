#!/usr/bin/env python3
# hook-version: 1.7.0
# dt-ai-observability-claude: upstream hook v1.7.0 + patches: service.name, prompt cleaning, locked atomic state,
# tool_use_id correlation, per-turn token sum, tool I/O only with capture (see hooks/otel-hook.patch)
"""
Dynatrace AI Governance For Devs — Claude Code OTel Hook v2
Captura: prompt, model, tokens, custo, duração total e tool calls (input+output).
Requer: Python 3.6+ (sem dependências externas)
"""
import sys, json, time, random, os, glob, urllib.request, threading, re, fcntl, tempfile

DEFAULT_PORT  = 4318
ATTRS_FILE    = os.path.expanduser("~/.claude/otel-attrs.json")
# dt-ai-observability-claude: the Claude Desktop app (Code tab) runs Claude Code with
# CLAUDE_CODE_ENTRYPOINT=claude-desktop. Name those sessions apart from the plain CLI.
SERVICE_NAME  = "claude-code-desktop" if os.environ.get("CLAUDE_CODE_ENTRYPOINT") == "claude-desktop" else "claude-code"
GEN_AI_SYSTEM = "anthropic"
STATE_DIR     = os.path.expanduser("~/.claude/otel-state")
SETTINGS_FILE = os.path.expanduser("~/.claude/settings.json")
MAX_LEN       = 4096  # corta atributos muito longos

# dt-ai-observability-claude: the Claude Desktop app and other harnesses inject
# <system-reminder>…</system-reminder> blocks into the user turn (linked-session
# notes, task results, instruction reminders). They are orchestration noise, not
# the human prompt, so drop them. Pasted text arrives wrapped in
# <pasted_content id="…">…</pasted_content>: keep the text, drop the wrapper.
_RE_SYSREM = re.compile(r"<system-reminder>.*?(</system-reminder>|\Z)", re.S | re.I)
_RE_PASTED = re.compile(r"<pasted_content[^>]*>(.*?)(</pasted_content[^>]*>|\Z)", re.S | re.I)
_RE_HARNESS = re.compile(r"<(command-name|command-message|command-args|local-command-stdout|local-command-stderr|ide_selection|ide_opened_file)[^>]*>.*?(</\1>|\Z)", re.S | re.I)
def clean_prompt(text):
    if not text: return text
    text = _RE_SYSREM.sub("", text)
    text = _RE_HARNESS.sub("", text)
    text = _RE_PASTED.sub(lambda m: m.group(1).strip(), text)
    text = re.sub(r"[ \t]{2,}", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()

# dt-ai-observability-claude: state files are per session, written atomically under an
# exclusive lock so parallel tool calls (and Pre/Post pairs) never lose or corrupt records.
_SAFE_ID = re.compile(r"[^A-Za-z0-9._-]")
def safe_session_id(session_id):
    return _SAFE_ID.sub("_", str(session_id))[:128] or "default"

class StateLock:
    def __init__(self, path):
        self.path = path + ".lock"; self.fh = None
    def __enter__(self):
        self.fh = open(self.path, "a+")
        try: os.chmod(self.path, 0o600)
        except Exception: pass
        fcntl.flock(self.fh.fileno(), fcntl.LOCK_EX)
        return self
    def __exit__(self, *exc):
        try: fcntl.flock(self.fh.fileno(), fcntl.LOCK_UN)
        finally: self.fh.close()

def load_state(path):
    """Read the state file; on a transient parse error retry once instead of minting a new trace."""
    for attempt in (0, 1):
        try:
            with open(path, encoding="utf-8") as f:
                return json.load(f), True
        except FileNotFoundError:
            return {}, False
        except Exception:
            if attempt == 0:
                time.sleep(0.05); continue
            return {}, True
    return {}, False

def save_state(path, state):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".state-", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(state, f)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except Exception:
        try: os.remove(tmp)
        except Exception: pass

def turn_usage(transcript_path, session_id, start_offset):
    """Sum token usage of every assistant message written since start_offset (the whole turn),
    and return the last model and last text response. Falls back to the project glob when the
    hook event carries no transcript_path."""
    result = {"text": "", "model": "", "input_tokens": None, "output_tokens": None, "cost_usd": None, "offset": start_offset}
    path = transcript_path
    if not path or not os.path.isfile(path):
        files = glob.glob(os.path.expanduser(f"~/.claude/projects/*/{session_id}.jsonl"))
        path = files[0] if files else None
    if not path:
        return result
    # Claude Code persists one API response as one transcript line per content block, and every
    # line repeats the response's usage (and costUSD). Count each response once: key by
    # message.id, keep the line with the highest output_tokens (the final streamed value).
    # Lines without an id are counted individually.
    per_msg = {}; anon = 0
    try:
        size = os.path.getsize(path)
        off = start_offset if (isinstance(start_offset, int) and 0 <= start_offset <= size) else 0
        with open(path, encoding="utf-8", errors="replace") as f:
            f.seek(off)
            for line in f:
                try:
                    r = json.loads(line)
                except Exception:
                    continue
                msg = r.get("message") or r
                if not isinstance(msg, dict) or msg.get("role") != "assistant":
                    continue
                if msg.get("model"): result["model"] = msg["model"]
                usage = msg.get("usage") or {}
                c = r.get("costUSD", msg.get("costUSD"))
                if usage or isinstance(c, (int, float)):
                    key = msg.get("id")
                    if not key:
                        anon += 1; key = f"_anon{anon}"
                    prev = per_msg.get(key)
                    if prev is None or (usage.get("output_tokens") or 0) >= (prev[0].get("output_tokens") or 0):
                        per_msg[key] = (usage, c if isinstance(c, (int, float)) else (prev[1] if prev else None))
                content = msg.get("content", [])
                if isinstance(content, list):
                    texts = [b["text"] for b in content if isinstance(b, dict) and b.get("type") == "text" and b.get("text", "").strip()]
                    if texts: result["text"] = texts[-1]
            result["offset"] = f.tell()
    except Exception:
        pass
    usages = [u for u, _ in per_msg.values() if u]
    if usages:
        result["input_tokens"] = sum((u.get("input_tokens") or 0) + (u.get("cache_read_input_tokens") or 0) + (u.get("cache_creation_input_tokens") or 0) for u in usages)
        result["output_tokens"] = sum(u.get("output_tokens") or 0 for u in usages)
    costs = [c for _, c in per_msg.values() if isinstance(c, (int, float))]
    if costs:
        result["cost_usd"] = round(sum(costs), 6)
    return result

def is_human_prompt(entry):
    """True for a transcript line that is a prompt typed by the user (start of a turn):
    role user, not a meta/system-injected line, and no tool_result blocks."""
    if not isinstance(entry, dict) or entry.get("isMeta"):
        return False
    msg = entry.get("message") if isinstance(entry.get("message"), dict) else entry
    if not isinstance(msg, dict) or msg.get("role") != "user":
        return False
    content = msg.get("content")
    if isinstance(content, str):
        return bool(content.strip())
    if isinstance(content, list):
        types = {b.get("type") for b in content if isinstance(b, dict)}
        return "tool_result" not in types and bool(types & {"text", "image", "document"})
    return False

def last_prompt_offset(transcript_path, session_id=""):
    """Byte offset where the current turn starts: the last human prompt in the transcript.
    Used when no UserPromptSubmit was seen for this session (hook installed mid-session, state
    lost), so the Stop span counts only the current turn instead of the whole history.
    Returns None when no prompt can be found."""
    path = transcript_path
    if not path or not os.path.isfile(path):
        files = glob.glob(os.path.expanduser(f"~/.claude/projects/*/{session_id}.jsonl")) if session_id else []
        path = files[0] if files else None
    if not path:
        return None
    found = None
    try:
        pos = 0
        with open(path, "rb") as f:
            for raw in f:
                try:
                    if is_human_prompt(json.loads(raw)):
                        found = pos
                except Exception:
                    pass
                pos += len(raw)
    except Exception:
        return None
    return found

def transcript_offset(transcript_path):
    try:
        return os.path.getsize(transcript_path) if transcript_path and os.path.isfile(transcript_path) else 0
    except Exception:
        return 0

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
    session_id = safe_session_id(event.get("session_id") or "default")
    tool_key   = str(event.get("tool_use_id") or tool_name or "")
    transcript = event.get("transcript_path") or ""

    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    try: os.chmod(STATE_DIR, 0o700)
    except Exception: pass
    state_file = os.path.join(STATE_DIR, f"{session_id}.json")

    raw_attrs, capture_prompts = read_otel_config()
    custom_attrs = [attr_s(k, v) for k, v in raw_attrs.items()]
    now_ns = int(time.time() * 1e9)

    with StateLock(state_file):
        state, existed = load_state(state_file)
        if not state.get("trace_id"):
            state["trace_id"] = rand_trace()
        trace_id = state["trace_id"]
        handle_event(event, hook_event, tool_name, tool_key, session_id, transcript, state, existed,
                     state_file, trace_id, now_ns, capture_prompts, custom_attrs)

def handle_event(event, hook_event, tool_name, tool_key, session_id, transcript, state, existed,
                 state_file, trace_id, now_ns, capture_prompts, custom_attrs):
    # ── UserPromptSubmit: gravar início da conversa ──────────────────────────
    if hook_event == "UserPromptSubmit":
        state["turn_start_ns"]  = now_ns
        state["turn_span_id"]   = rand_span()
        # prompt text is persisted only when capture is on (privacy: nothing on disk otherwise)
        state["prompt_text"]    = clean_prompt(event.get("prompt", "")) if capture_prompts else ""
        state["model"]          = get_model()
        state["transcript_offset"] = transcript_offset(transcript)
        state["tools"]          = {}
        save_state(state_file, state)
        return

    # ── PreToolUse: gravar início da tool call ───────────────────────────────
    if hook_event == "PreToolUse" and tool_name:
        tools = state.setdefault("tools", {})
        # drop stale records (a PostToolUse that never came) so the file cannot grow forever
        for k in [k for k, v in tools.items() if now_ns - v.get("start_ns", now_ns) > 3_600_000_000_000]:
            tools.pop(k, None)
        tools[tool_key] = {
            "start_ns":   now_ns,
            "span_id":    rand_span(),
            "tool_name":  tool_name,
            # tool input (commands, file contents) only when capture is on
            "tool_input": trunc(event.get("tool_input", "")) if capture_prompts else "",
        }
        save_state(state_file, state)
        return

    # ── PostToolUse: emitir span da tool com duração real ───────────────────
    if hook_event == "PostToolUse" and tool_name:
        tools = state.get("tools", {})
        ts = tools.pop(tool_key, None)
        if ts is None:  # older Claude Code without tool_use_id: fall back to the oldest record of that tool
            cands = sorted([(v.get("start_ns", 0), k) for k, v in tools.items() if v.get("tool_name") == tool_name])
            ts = tools.pop(cands[0][1], {}) if cands else {}
        start_ns    = ts.get("start_ns", now_ns)
        span_id     = ts.get("span_id",  rand_span())
        parent_id   = state.get("turn_span_id")
        dur_ms      = (now_ns - start_ns) / 1e6

        attrs = [
            attr_s("gen_ai.system",       GEN_AI_SYSTEM),
            attr_s("claude.session_id",   session_id),
            attr_s("claude.tool_name",    tool_name),
            attr_d("claude.duration_ms",  round(dur_ms, 2)),
        ] + custom_attrs
        if capture_prompts:  # tool I/O carries commands and file contents: opt-in only
            attrs += [attr_s("claude.tool_input",    ts.get("tool_input", "")),
                      attr_s("claude.tool_response", trunc(event.get("tool_response", "")))]
        send_spans([make_span(trace_id, span_id, f"claude.tool.{tool_name}",
                              start_ns, now_ns, attrs, parent_id)])
        save_state(state_file, state)
        return

    # ── Stop: emitir span raiz da conversa (UserPromptSubmit → Stop) ────────
    if hook_event == "Stop":
        span_id     = state.get("turn_span_id") or rand_span()
        start_ns    = state.get("turn_start_ns", now_ns)
        prompt_text = state.get("prompt_text", "")
        model       = state.get("model", get_model())
        dur_ms      = (now_ns - start_ns) / 1e6

        # Modelo, tokens (somados sobre todas as chamadas do turno) e resposta vêm do JSONL da sessão
        # Turn start: offset saved at UserPromptSubmit (or by the previous Stop). Without one — hook
        # installed mid-session or state lost — start at the last human prompt; if none is found,
        # report no token counts rather than summing the whole session history.
        offset = state.get("transcript_offset")
        usage_known = True
        if not isinstance(offset, int):
            offset = last_prompt_offset(transcript, session_id)
            if offset is None:
                usage_known = False
                offset = transcript_offset(transcript)
        assistant   = turn_usage(transcript, session_id, offset)
        if not usage_known:
            assistant["input_tokens"] = assistant["output_tokens"] = assistant["cost_usd"] = None
        completion  = assistant["text"]
        if assistant["model"]:
            model = assistant["model"]
        input_tok   = assistant["input_tokens"]
        output_tok  = assistant["output_tokens"]
        # cost: only what Claude Code itself reports (hook event or transcript costUSD); never fabricated
        cost_usd    = event.get("cost_usd") or event.get("total_cost_usd") or assistant["cost_usd"]

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

        # keep trace_id + a fresh offset for the next turn; drop turn data and tool records
        keep = {"trace_id": trace_id, "transcript_offset": assistant.get("offset", 0)}
        save_state(state_file, keep)
        return

    if hook_event == "SessionEnd":
        for p in (state_file, state_file + ".lock"):
            try: os.remove(p)
            except Exception: pass
        return

    # ── Outros eventos (Notification, etc.): never create a state file for them ───
    attrs = [attr_s("gen_ai.system", GEN_AI_SYSTEM), attr_s("claude.session_id", session_id)]
    send_spans([make_span(trace_id, rand_span(), f"claude.{hook_event.lower()}",
                          now_ns, now_ns + 1_000_000, attrs)])
    if existed:
        save_state(state_file, state)

if __name__ == "__main__":
    t = threading.Thread(target=main, daemon=True)
    t.start()
    t.join(10)  # max 10s — prevents blocking Claude Code indefinitely
