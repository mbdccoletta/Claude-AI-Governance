#!/usr/bin/env bash
# End-to-end local test (macOS/Linux) — no Dynatrace tenant involved.
#
# 1. starts test/sink.py on 127.0.0.1:9999 (stand-in for the tenant)
# 2. runs install.sh against it with a dummy token
# 3. fires the four hook events synthetically (one "desktop" session, one "cli")
# 4. optionally (--native) runs `claude -p` so Claude Code's native OTel metrics/logs flow too
# 5. prints what the sink received and writes test/local-e2e.log
# 6. with --uninstall, runs uninstall.sh --yes at the end
#
# Usage: test/run-local-test.sh [--tarball PATH] [--native] [--uninstall] [--wait SECONDS]
set -euo pipefail
A="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$A/test"
LOG="$T/local-e2e.log"
SINK_DIR="$T/sink-data"
TARBALL=""; NATIVE=0; UNINSTALL=0; WAIT=20
while [ $# -gt 0 ]; do
  case "$1" in
    --tarball) TARBALL="$2"; shift 2 ;;
    --native) NATIVE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --wait) WAIT="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done
rm -rf "$SINK_DIR"; mkdir -p "$SINK_DIR"
: > "$LOG"
say() { printf '\n### %s\n' "$*" | tee -a "$LOG"; }
run() { "$@" 2>&1 | tee -a "$LOG"; }

say "sink: starting on 127.0.0.1:9999"
python3 -I "$T/sink.py" --port 9999 --dir "$SINK_DIR" > "$T/sink.log" 2>&1 &
SINK_PID=$!
trap 'kill $SINK_PID 2>/dev/null || true' EXIT
sleep 1; curl -fs http://127.0.0.1:9999/ | tee -a "$LOG"

say "install.sh against the sink (dummy token, prompts OFF, native OTel env ON)"
INSTALL_ARGS=(--endpoint http://127.0.0.1:9999 --token dummy-token-not-real --email test@example.com
              --squad platform --cost-center cc-1234 --non-interactive --enable-native-otel)
[ -n "$TARBALL" ] && INSTALL_ARGS+=(--otelcol-tarball "$TARBALL")
run bash "$A/install.sh" "${INSTALL_ARGS[@]}"

PORT="$(sed -n 's/^COLLECTOR_PORT=//p' "$HOME/.dt-ai-obs/config.env")"
HPORT="$(sed -n 's/^HEALTH_PORT=//p' "$HOME/.dt-ai-obs/config.env")"
say "health: $(curl -fs "http://127.0.0.1:$HPORT")"
say "hook status"; run python3 -I "$A/hooks/configure-hooks.py" status

fire() { # fire ENTRYPOINT SESSION_ID
  local ep="$1" sid="$2" envs=()
  [ -n "$ep" ] && envs=(CLAUDE_CODE_ENTRYPOINT="$ep")
  # fake session transcript so the Stop event finds a model + token usage
  mkdir -p "$HOME/.claude/projects/dt-ai-obs-e2e"
  printf '%s\n' '{"message":{"role":"assistant","model":"claude-sonnet-4-5","usage":{"input_tokens":12,"cache_read_input_tokens":18000,"output_tokens":42},"content":[{"type":"text","text":"synthetic answer"}]}}' > "$HOME/.claude/projects/dt-ai-obs-e2e/$sid.jsonl"
  for ev in \
    "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$sid\",\"prompt\":\"synthetic prompt (must NOT reach the sink)\"}" \
    "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"$sid\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}" \
    "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$sid\",\"tool_name\":\"Bash\",\"tool_response\":\"file1 file2\"}" \
    "{\"hook_event_name\":\"Stop\",\"session_id\":\"$sid\",\"cost_usd\":0.0123}"; do
    printf '%s' "$ev" | env "${envs[@]+"${envs[@]}"}" python3 "$HOME/.claude/otel-hook.py"; echo "  hook exit=$? ($(printf '%s' "$ev" | cut -c1-60)...)" | tee -a "$LOG"
    sleep 0.3
  done
  rm -rf "$HOME/.claude/projects/dt-ai-obs-e2e"
}
say "firing synthetic hook events — Desktop Code tab session (CLAUDE_CODE_ENTRYPOINT=claude-desktop)"
fire claude-desktop e2e-desktop-0001
say "firing synthetic hook events — plain CLI session"
fire "" e2e-cli-0002

if [ "$NATIVE" = 1 ]; then
  say "native Claude Code OTel: running 'claude -p' with telemetry pointed at the collector"
  CLAUDE_BIN="$(command -v claude || true)"; [ -n "$CLAUDE_BIN" ] || CLAUDE_BIN="${CLAUDE_CODE_EXECPATH:-}"   # Desktop-bundled binary as fallback
  if [ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ]; then
    echo "using $CLAUDE_BIN" | tee -a "$LOG"
    env -u CLAUDECODE CLAUDE_CODE_ENABLE_TELEMETRY=1 OTEL_METRICS_EXPORTER=otlp OTEL_LOGS_EXPORTER=otlp \
        OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:$PORT" \
        OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta OTEL_METRIC_EXPORT_INTERVAL=2000 OTEL_LOGS_EXPORT_INTERVAL=1000 \
        "$CLAUDE_BIN" -p "Reply with the single word OK" --model claude-haiku-4-5 2>&1 | tee -a "$LOG" || echo "claude -p failed (exit $?)" | tee -a "$LOG"
  else
    echo "claude CLI not on PATH — skipping native test" | tee -a "$LOG"
  fi
fi

say "waiting ${WAIT}s for the collector batch (5s) to flush to the sink"
sleep "$WAIT"

say "sink received"
cat "$T/sink.log" | tee -a "$LOG"
say "sink summary (requests per path)"
grep -o '"path": "[^"]*"' "$T/sink.log" | sort | uniq -c | tee -a "$LOG"
say "privacy check: synthetic prompt text must not appear in any payload"
if grep -rl "synthetic prompt" "$SINK_DIR" >/dev/null 2>&1; then echo "FAIL: prompt content leaked" | tee -a "$LOG"; else echo "OK: no prompt content in payloads" | tee -a "$LOG"; fi
say "payload checks (substring search in the decoded protobuf bodies)"
check() { # check LABEL PATTERN FILEGLOB
  local n; n=$(cat $3 2>/dev/null | grep -a -c "$2" || true)
  printf '  %-58s %s\n' "$1" "$([ "${n:-0}" -gt 0 ] && echo "OK ($n file(s))" || echo "not seen")" | tee -a "$LOG"
}
check "traces: service.name claude-code-desktop (Desktop Code tab)" 'claude-code-desktop' "$SINK_DIR/*traces*.bin"
check "traces: gen_ai.provider.name alias added by the collector" 'gen_ai.provider.name' "$SINK_DIR/*traces*.bin"
check "traces: gen_ai.usage.input_tokens from the session transcript" 'gen_ai.usage.input_tokens' "$SINK_DIR/*traces*.bin"
check "traces: configured user.email (test@example.com)" 'test@example.com' "$SINK_DIR/*traces*.bin"
check "traces: custom attribute cost_center" 'cost_center' "$SINK_DIR/*traces*.bin"
check "metrics: claude_code.* counters (native OTel)" 'claude_code\.' "$SINK_DIR/*metrics*.bin"
check "logs: claude_code events (native OTel)" 'claude_code\.' "$SINK_DIR/*logs*.bin"
check "logs: account e-mail moved to claude.account_email" 'claude.account_email' "$SINK_DIR/*logs*.bin"
check "logs: configured user.email (test@example.com)" 'test@example.com' "$SINK_DIR/*logs*.bin"
say "collector log (tail, truncated lines)"
tail -n 25 "$HOME/.dt-ai-obs/logs/collector.log" | cut -c1-220 | tee -a "$LOG"

if [ "$UNINSTALL" = 1 ]; then
  say "uninstall.sh --yes"
  run bash "$A/uninstall.sh" --yes
  say "post-uninstall check"
  for f in "$HOME/.dt-ai-obs" "$HOME/Library/LaunchAgents/com.dynatrace.dt-ai-obs-claude.plist" "$HOME/.claude/otel-hook.py" "$HOME/.claude/otel-attrs.json" "$HOME/.claude/otel-state"; do
    [ -e "$f" ] && echo "  STILL PRESENT: $f" || echo "  removed: $f"
  done | tee -a "$LOG"
  if [ "$(uname -s)" = Darwin ]; then
    /usr/bin/security find-generic-password -s dt-ai-obs-claude >/dev/null 2>&1 && echo "  STILL PRESENT: keychain item" || echo "  removed: keychain item dt-ai-obs-claude"
  fi | tee -a "$LOG"
  python3 -I "$A/hooks/configure-hooks.py" status | tee -a "$LOG"
fi
say "done — full log in $LOG"
