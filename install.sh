#!/usr/bin/env bash
# Dynatrace AI Observability for Claude — installer (macOS / Linux)
#
# Makes Claude Code telemetry (Claude Desktop app "Code" tab and the claude CLI)
# land in Dynatrace without VS Code:
#   1. installs the Claude Code hook (~/.claude/otel-hook.py + settings.json)
#   2. writes ~/.claude/otel-attrs.json (e-mail, custom attributes, privacy flag)
#   3. downloads otelcol-contrib into ~/.dt-ai-obs/bin
#   4. renders ~/.dt-ai-obs/otel-collector.yaml for your tenant
#   5. stores the ingest token in the OS credential store
#   6. registers the collector as a user service (launchd / systemd --user)
#
# Usage: ./install.sh [options]
#   --endpoint URL|TENANT_ID   Dynatrace OTLP endpoint or tenant id (abc12345)
#   --token TOKEN              API token (scopes: openTelemetryTrace.ingest,
#                              metrics.ingest, logs.ingest); or env DT_INGEST_TOKEN
#   --email ADDRESS            developer e-mail (user.email)
#   --squad NAME               custom attribute squad=NAME
#   --cost-center ID           custom attribute cost_center=ID
#   --attr KEY=VALUE           any other custom attribute (repeatable)
#   --environment NAME         deployment.environment resource attribute (default: demo)
#   --collector-port N         OTLP/HTTP port (default 4318; next free port if busy)
#   --health-port N            health check port (default 13133)
#   --capture-prompts          send prompt/response content (default: off)
#   --enable-native-otel       also turn on Claude Code's native OTel metrics/logs
#                              (env block in ~/.claude/settings.json)
#   --enable-evals             check Node.js >= 20 and print how to score the captured
#                              prompts with Dynatrace Evals (dt-evals); nothing is run
#   --otelcol-version X.Y.Z    collector release (default: 0.163.1, tested; 'latest' to fetch the newest)
#   --otelcol-tarball PATH     use a local release tarball instead of downloading
#   --verbose-collector        enable the collector debug exporter (writes every record, prompts
#                              included, to logs/collector.log; off by default)
#   --non-interactive          never prompt; fail on missing values
#   -h, --help
#
# Environment variables accepted instead of flags: DT_OTLP_ENDPOINT,
# DT_INGEST_TOKEN, DT_USER_EMAIL, DT_SQUAD, DT_COST_CENTER.
set -euo pipefail

ASSET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${DT_AI_OBS_DIR:-$HOME/.dt-ai-obs}"
CLAUDE_DIR="$HOME/.claude"
HOOK_DST="$CLAUDE_DIR/otel-hook.py"
KEYCHAIN_SERVICE="dt-ai-obs-claude"
LAUNCHD_LABEL="com.dynatrace.dt-ai-obs-claude"
SYSTEMD_UNIT="dt-ai-obs-claude.service"
RELEASES_API="https://api.github.com/repos/open-telemetry/opentelemetry-collector-releases/releases/latest"
UA="dt-ai-observability-claude"

ENDPOINT="${DT_OTLP_ENDPOINT:-}"
TOKEN="${DT_INGEST_TOKEN:-}"
EMAIL="${DT_USER_EMAIL:-}"
SQUAD="${DT_SQUAD:-}"
COST_CENTER="${DT_COST_CENTER:-}"
ENVIRONMENT="demo"
EXTRA_ATTRS=()
COLLECTOR_PORT=""
HEALTH_PORT=""
CAPTURE_PROMPTS=0
NATIVE_OTEL=0
ENABLE_EVALS=0
OTELCOL_VERSION="${DT_AI_OBS_OTELCOL_VERSION:-0.163.1}"   # pinned; pass --otelcol-version latest to opt out
OTELCOL_TARBALL=""
QUIET_COLLECTOR=1   # debug exporter off by default (it writes every record, incl. prompts, to collector.log)
NON_INTERACTIVE=0

usage() { awk 'NR>1 && !/^#/ {exit} NR>1 {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"; }
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --endpoint) ENDPOINT="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --squad) SQUAD="$2"; shift 2 ;;
    --cost-center) COST_CENTER="$2"; shift 2 ;;
    --attr) EXTRA_ATTRS+=("$2"); shift 2 ;;
    --environment) ENVIRONMENT="$2"; shift 2 ;;
    --collector-port) COLLECTOR_PORT="$2"; shift 2 ;;
    --health-port) HEALTH_PORT="$2"; shift 2 ;;
    --capture-prompts) CAPTURE_PROMPTS=1; shift ;;
    --enable-native-otel) NATIVE_OTEL=1; shift ;;
    --otelcol-version) OTELCOL_VERSION="$2"; shift 2 ;;
    --otelcol-tarball) OTELCOL_TARBALL="$2"; shift 2 ;;
    --enable-evals) ENABLE_EVALS=1; shift ;;
    --quiet-collector) QUIET_COLLECTOR=1; shift ;;
    --verbose-collector) QUIET_COLLECTOR=0; shift ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# ── platform ────────────────────────────────────────────────────────────────
case "$(uname -s)" in
  Darwin) OS=darwin; OS_TYPE=macos ;;
  Linux)  OS=linux;  OS_TYPE=linux ;;
  *) die "unsupported OS: $(uname -s) (use install.ps1 on Windows)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

# ── prerequisites ───────────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || die "python3 not found — the Claude Code hook needs Python 3.6+"
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)' || die "python3 is older than 3.6"
command -v curl >/dev/null 2>&1 || die "curl not found"
command -v tar  >/dev/null 2>&1 || die "tar not found"
[ -d "$CLAUDE_DIR" ] || warn "$CLAUDE_DIR does not exist yet (Claude Code never ran?) — it will be created"

prompt() { # prompt VAR "label" [default] [secret]
  local var="$1" label="$2" def="${3:-}" secret="${4:-}" val=""
  if [ -n "${!var}" ]; then return 0; fi
  [ "$NON_INTERACTIVE" = 1 ] && { [ -n "$def" ] && { printf -v "$var" '%s' "$def"; return 0; }; die "missing value for $(printf '%s' "$var" | tr '[:upper:]_' '[:lower:]-') (non-interactive)"; }
  if [ -n "$secret" ]; then
    read -r -s -p "$label: " val; echo
  elif [ -n "$def" ]; then
    read -r -p "$label [$def]: " val; val="${val:-$def}"
  else
    read -r -p "$label: " val
  fi
  printf -v "$var" '%s' "$val"
}

# ── inputs ──────────────────────────────────────────────────────────────────
echo "Dynatrace AI Observability for Claude — installer ($OS/$ARCH)"
echo
prompt ENDPOINT "Dynatrace OTLP endpoint or tenant id (e.g. abc12345 or https://abc12345.live.dynatrace.com/api/v2/otlp)"
# normalise: tenant id -> full URL; add /api/v2/otlp; strip /v1/traces; refuse .apps.
ENDPOINT="${ENDPOINT%/}"
if [[ "$ENDPOINT" =~ ^[A-Za-z0-9]{8}$ ]]; then
  ENDPOINT="https://$(printf '%s' "$ENDPOINT" | tr '[:upper:]' '[:lower:]').live.dynatrace.com/api/v2/otlp"
fi
ENDPOINT="${ENDPOINT%/v1/traces}"; ENDPOINT="${ENDPOINT%/v1/metrics}"; ENDPOINT="${ENDPOINT%/v1/logs}"
[[ "$ENDPOINT" == *.apps.dynatrace.com* ]] && die "use the .live.dynatrace.com host for OTLP ingest, not .apps."
[[ "$ENDPOINT" =~ ^https?:// ]] || die "endpoint must start with https:// (got: $ENDPOINT)"
[[ "$ENDPOINT" == */api/v2/otlp ]] || ENDPOINT="$ENDPOINT/api/v2/otlp"
[[ "$ENDPOINT" == http://* ]] && warn "plain http:// endpoint — only use this for local testing"

prompt TOKEN "Dynatrace API token (openTelemetryTrace.ingest + metrics.ingest + logs.ingest)" "" secret
[ -n "$TOKEN" ] || die "token is required"
TOKEN="$(printf '%s' "$TOKEN" | tr -d '[:space:]')"
[[ "$TOKEN" =~ ^dt0c01\.[A-Za-z0-9]{24}\.[A-Za-z0-9]{64}$ ]] || die "token format invalid: expected dt0c01.<24 chars>.<64 chars> (96 chars, got ${#TOKEN}); a token pasted twice into the hidden prompt is the usual cause"
CURL_TLS=(); [[ "$ENDPOINT" == https://* ]] && CURL_TLS=(--proto '=https' --tlsv1.2)
code="$(curl -sS "${CURL_TLS[@]+"${CURL_TLS[@]}"}" -o /dev/null -w '%{http_code}' -m 20 -X POST "$ENDPOINT/v1/traces" -H "Authorization: Api-Token $TOKEN" -H 'Content-Type: application/x-protobuf' --data-binary '' 2>/dev/null || echo 000)"
case "$code" in
  200|400) log "Token accepted by $ENDPOINT (pre-flight HTTP $code)" ;;
  401|403) die "the tenant rejected the token (HTTP $code): check the token value and its scopes (openTelemetryTrace.ingest, metrics.ingest, logs.ingest)" ;;
  000) warn "could not reach $ENDPOINT for the token pre-flight (offline or blocked); continuing" ;;
  *) warn "unexpected pre-flight response HTTP $code from $ENDPOINT; continuing" ;;
esac
DEFAULT_EMAIL="${CLAUDE_CODE_USER_EMAIL:-$(git config --global user.email 2>/dev/null || true)}"
prompt EMAIL "Developer e-mail (user.email)" "$DEFAULT_EMAIL"
if [ "$NON_INTERACTIVE" = 0 ]; then
  [ -n "$SQUAD" ] || read -r -p "Squad / team (optional): " SQUAD
  [ -n "$COST_CENTER" ] || read -r -p "Cost center (optional): " COST_CENTER
fi
ATTRS=()
[ -n "$SQUAD" ] && ATTRS+=("squad=$SQUAD")
[ -n "$COST_CENTER" ] && ATTRS+=("cost_center=$COST_CENTER")
ATTRS+=("${EXTRA_ATTRS[@]+"${EXTRA_ATTRS[@]}"}")

# ── stop a previous install of this asset (re-install) so its ports read as free ──
if [ "$OS" = darwin ]; then
  launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1 && log "Stopped the previous collector service (re-install)" || true
elif command -v systemctl >/dev/null 2>&1; then
  systemctl --user stop "$SYSTEMD_UNIT" >/dev/null 2>&1 && log "Stopped the previous collector service (re-install)" || true
fi
pkill -f "$INSTALL_DIR/bin/otelcol-contrib" 2>/dev/null || true
# bootout/stop return before the process exits: wait (≤5 s) until the previous collector is gone, otherwise
# its ports would still read as busy and this install would silently move to the next free port
for _i in $(seq 1 10); do pgrep -f "$INSTALL_DIR/bin/otelcol-contrib" >/dev/null 2>&1 || break; sleep 0.5; done

# ── ports ───────────────────────────────────────────────────────────────────
port_free() { python3 - "$1" <<'PY'
import socket, sys
s = socket.socket(); s.settimeout(0.2)
# SO_REUSEADDR like the collector itself (Go sets it): lingering TIME_WAIT connections from the
# hook to the previous collector must not make the port read as busy
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", int(sys.argv[1]))); s.close(); sys.exit(0)
except OSError:
    sys.exit(1)
PY
}
pick_port() { # pick_port START
  local p="$1"; local i
  for i in $(seq 0 50); do port_free $((p + i)) && { echo $((p + i)); return 0; }; done
  die "no free port found starting at $p"
}
existing_health() { curl -fs --max-time 1 "http://127.0.0.1:${1}" 2>/dev/null | grep -q 'Server available'; }

# a previous install's ports are reused when not given explicitly (so settings.json / otel-attrs.json keep pointing at the same port)
if [ -f "$INSTALL_DIR/config.env" ]; then
  _prev_port="$(sed -n 's/^COLLECTOR_PORT=//p' "$INSTALL_DIR/config.env" | tr -dc 0-9)"; _prev_health="$(sed -n 's/^HEALTH_PORT=//p' "$INSTALL_DIR/config.env" | tr -dc 0-9)"
  if [ -z "$COLLECTOR_PORT" ] && [ -n "$_prev_port" ] && [ "$_prev_port" != 4318 ] && port_free "$_prev_port"; then COLLECTOR_PORT="$_prev_port"; fi
  if [ -z "$HEALTH_PORT" ] && [ -n "$_prev_health" ] && [ "$_prev_health" != 13133 ] && port_free "$_prev_health"; then HEALTH_PORT="$_prev_health"; fi
fi
if [ -z "$COLLECTOR_PORT" ]; then
  COLLECTOR_PORT=4318
  for _i in 1 2 3 4 5 6; do port_free "$COLLECTOR_PORT" && break; sleep 0.5; done   # a just-stopped collector may still be releasing it
  if ! port_free "$COLLECTOR_PORT"; then
    if existing_health 13133; then
      warn "a collector already answers on 127.0.0.1:13133 (the VS Code extension, or a previous install of this asset)."
      warn "This install will take over port 4318 after the service restarts; stop the other collector or run both on different ports (--collector-port)."
    fi
    COLLECTOR_PORT="$(pick_port 4319)"
    warn "port 4318 is busy — using OTLP port $COLLECTOR_PORT (written to ~/.claude/otel-attrs.json so the hook follows)"
  fi
fi
if [ -z "$HEALTH_PORT" ]; then
  HEALTH_PORT=13133
  port_free "$HEALTH_PORT" || { HEALTH_PORT="$(pick_port 13134)"; warn "port 13133 is busy — health check on $HEALTH_PORT"; }
fi

# ── 1. Claude Code hook ─────────────────────────────────────────────────────
log "Installing Claude Code hook → $HOOK_DST"
mkdir -p "$CLAUDE_DIR"
install -m 0755 "$ASSET_DIR/hooks/otel-hook.py" "$HOOK_DST"
python3 -I "$ASSET_DIR/hooks/configure-hooks.py" install-hooks --hook-path "$HOOK_DST"

# ── 2. otel-attrs.json ──────────────────────────────────────────────────────
log "Writing $CLAUDE_DIR/otel-attrs.json"
ATTR_FLAGS=()
for kv in "${ATTRS[@]+"${ATTRS[@]}"}"; do ATTR_FLAGS+=(--attr "$kv"); done
CAP_FLAG=(); [ "$CAPTURE_PROMPTS" = 1 ] && CAP_FLAG=(--capture-prompts)
python3 -I "$ASSET_DIR/hooks/configure-hooks.py" write-attrs --port "$COLLECTOR_PORT" --os-type "$OS_TYPE" "${CAP_FLAG[@]+"${CAP_FLAG[@]}"}" "${ATTR_FLAGS[@]+"${ATTR_FLAGS[@]}"}"

# ── 3. collector binary ─────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/logs"
chmod 0700 "$INSTALL_DIR" "$INSTALL_DIR/logs"
touch "$INSTALL_DIR/logs/collector.log"; chmod 0600 "$INSTALL_DIR/logs/collector.log"
BIN="$INSTALL_DIR/bin/otelcol-contrib"
fetch_latest_version() {
  curl -fsSL --proto '=https' --tlsv1.2 -H "User-Agent: $UA" "$RELEASES_API" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))'
}
verify_sha256() { # verify_sha256 FILE SHAFILE
  local want have
  want="$(awk '{print $1}' "$2")"
  if command -v sha256sum >/dev/null 2>&1; then have="$(sha256sum "$1" | awk '{print $1}')"; else have="$(shasum -a 256 "$1" | awk '{print $1}')"; fi
  [ "$want" = "$have" ] || die "checksum mismatch for $1"
}
if [ -n "$OTELCOL_TARBALL" ]; then
  log "Extracting collector from $OTELCOL_TARBALL"
  [ -f "$OTELCOL_TARBALL" ] || die "tarball not found: $OTELCOL_TARBALL"
  [ -f "$OTELCOL_TARBALL.sha256" ] && verify_sha256 "$OTELCOL_TARBALL" "$OTELCOL_TARBALL.sha256" && log "checksum OK"
  tar -xzf "$OTELCOL_TARBALL" -C "$INSTALL_DIR/bin" otelcol-contrib
  basename "$OTELCOL_TARBALL" | sed -E 's/^otelcol-contrib_([0-9.]+)_.*/\1/' > "$INSTALL_DIR/otelcol-version.txt"
elif [ -x "$BIN" ] && { [ -z "$OTELCOL_VERSION" ] || [ "$(cat "$INSTALL_DIR/otelcol-version.txt" 2>/dev/null)" = "$OTELCOL_VERSION" ]; }; then
  log "Collector binary already present ($(cat "$INSTALL_DIR/otelcol-version.txt" 2>/dev/null || echo unknown version)) — skipping download"
else
  if [ -z "$OTELCOL_VERSION" ] || [ "$OTELCOL_VERSION" = latest ]; then log "Looking up the latest otelcol-contrib release"; OTELCOL_VERSION="$(fetch_latest_version)"; fi
  [[ "$OTELCOL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid collector version '$OTELCOL_VERSION' (expected X.Y.Z)"
  FILE="otelcol-contrib_${OTELCOL_VERSION}_${OS}_${ARCH}.tar.gz"
  URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/${FILE}"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  log "Downloading $URL"
  curl -fL --proto '=https' --tlsv1.2 --progress-bar -H "User-Agent: $UA" -o "$TMP/$FILE" "$URL"
  curl -fsSL --proto '=https' --tlsv1.2 -H "User-Agent: $UA" -o "$TMP/$FILE.sha256" "$URL.sha256"
  verify_sha256 "$TMP/$FILE" "$TMP/$FILE.sha256"; log "checksum OK"
  tar -xzf "$TMP/$FILE" -C "$INSTALL_DIR/bin" otelcol-contrib
  echo "$OTELCOL_VERSION" > "$INSTALL_DIR/otelcol-version.txt"
fi
chmod 0755 "$BIN"
log "Collector: $("$BIN" --version)"

# ── 4. token → credential store ─────────────────────────────────────────────
if [ "$OS" = darwin ]; then
  log "Storing the token in the macOS Keychain (service: $KEYCHAIN_SERVICE)"
  # note: `security` only accepts the secret as an argument; it is visible in `ps` for the milliseconds the call takes
  /usr/bin/security add-generic-password -a "$(id -un)" -s "$KEYCHAIN_SERVICE" -l "Dynatrace AI Observability (Claude) ingest token" -w "$TOKEN" -U >/dev/null
  TOKEN_BACKEND=keychain
elif command -v secret-tool >/dev/null 2>&1 && printf '%s' "$TOKEN" | secret-tool store --label="Dynatrace AI Observability (Claude) ingest token" service "$KEYCHAIN_SERVICE" key ingest-token 2>/dev/null; then
  log "Token stored in the Secret Service keyring (secret-tool)"
  TOKEN_BACKEND=secret-tool
else
  warn "no usable keyring (secret-tool missing or no session keyring) — storing the token in $INSTALL_DIR/ingest-token with mode 0600"
  umask 077; printf '%s' "$TOKEN" > "$INSTALL_DIR/ingest-token"; chmod 0600 "$INSTALL_DIR/ingest-token"; umask 022
  TOKEN_BACKEND=file
fi
unset TOKEN

# ── 5. render config + wrapper ──────────────────────────────────────────────
log "Rendering $INSTALL_DIR/otel-collector.yaml"
RENDER_FLAGS=(--endpoint "$ENDPOINT" --email "$EMAIL" --environment "$ENVIRONMENT" --os-type "$OS_TYPE"
              --collector-port "$COLLECTOR_PORT" --health-port "$HEALTH_PORT")
[ "$CAPTURE_PROMPTS" = 1 ] && RENDER_FLAGS+=(--capture-prompts)
[ "$QUIET_COLLECTOR" = 1 ] && RENDER_FLAGS+=(--no-debug-exporter)
python3 -I "$ASSET_DIR/collector/render-config.py" --template "$ASSET_DIR/collector/otel-collector.yaml" --out "$INSTALL_DIR/otel-collector.yaml" "${RENDER_FLAGS[@]}" "${ATTR_FLAGS[@]+"${ATTR_FLAGS[@]}"}"
chmod 0600 "$INSTALL_DIR/otel-collector.yaml"
{
  printf '# generated by dt-ai-observability-claude install.sh on %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'TOKEN_BACKEND=%q\nKEYCHAIN_SERVICE=%q\nDT_OTLP_ENDPOINT=%q\nUSER_EMAIL=%q\n' "$TOKEN_BACKEND" "$KEYCHAIN_SERVICE" "$ENDPOINT" "$EMAIL"
  printf 'COLLECTOR_PORT=%q\nHEALTH_PORT=%q\nCAPTURE_PROMPTS=%q\n' "$COLLECTOR_PORT" "$HEALTH_PORT" "$CAPTURE_PROMPTS"
} > "$INSTALL_DIR/config.env"
chmod 0600 "$INSTALL_DIR/config.env"
install -m 0755 "$ASSET_DIR/collector/run-collector.sh" "$INSTALL_DIR/run-collector.sh"
DT_INGEST_TOKEN=placeholder "$BIN" validate --config "$INSTALL_DIR/otel-collector.yaml" || die "rendered collector config failed validation"

# ── 6. native Claude Code OTel (optional) ───────────────────────────────────
if [ "$NATIVE_OTEL" = 1 ]; then
  log "Enabling Claude Code native OTel export → http://127.0.0.1:$COLLECTOR_PORT (env block in settings.json)"
  python3 -I "$ASSET_DIR/hooks/configure-hooks.py" native-otel --port "$COLLECTOR_PORT"
fi

# ── 7. user service ─────────────────────────────────────────────────────────
if [ "$OS" = darwin ]; then
  PLIST="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
  log "Registering launchd agent $LAUNCHD_LABEL"
  mkdir -p "$HOME/Library/LaunchAgents"
  sed "s|__DIR__|$INSTALL_DIR|g" "$ASSET_DIR/collector/com.dynatrace.dt-ai-obs-claude.plist" > "$PLIST"
  launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1 || true
  for _try in 1 2 3; do launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null && break; sleep 1; done
  launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1 || launchctl load -w "$PLIST" 2>/dev/null || die "could not register the launchd agent (see $PLIST)"
  launchctl kickstart -k "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1 || true
  SERVICE_HINT="launchctl kickstart -k gui/$(id -u)/$LAUNCHD_LABEL   # restart
  launchctl bootout gui/$(id -u)/$LAUNCHD_LABEL        # stop"
elif command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  UNIT_DIR="$HOME/.config/systemd/user"
  log "Registering systemd user unit $SYSTEMD_UNIT"
  mkdir -p "$UNIT_DIR"
  sed "s|__DIR__|$INSTALL_DIR|g" "$ASSET_DIR/collector/dt-ai-obs-claude.service" > "$UNIT_DIR/$SYSTEMD_UNIT"
  systemctl --user daemon-reload
  systemctl --user enable --now "$SYSTEMD_UNIT"
  systemctl --user restart "$SYSTEMD_UNIT"
  SERVICE_HINT="systemctl --user restart $SYSTEMD_UNIT   # restart
  systemctl --user stop $SYSTEMD_UNIT      # stop"
else
  warn "no systemd --user session available — starting the collector with nohup; add '$INSTALL_DIR/run-collector.sh' to your login items manually"
  pkill -f "$INSTALL_DIR/bin/otelcol-contrib" 2>/dev/null || true
  nohup bash "$INSTALL_DIR/run-collector.sh" >> "$INSTALL_DIR/logs/collector.log" 2>&1 &
  SERVICE_HINT="nohup bash $INSTALL_DIR/run-collector.sh >> $INSTALL_DIR/logs/collector.log 2>&1 &"
fi

# ── 8. health check ─────────────────────────────────────────────────────────
log "Waiting for the collector health check on 127.0.0.1:$HEALTH_PORT"
ok=0
for _ in $(seq 1 30); do
  if existing_health "$HEALTH_PORT"; then ok=1; break; fi
  sleep 1
done
if [ "$ok" = 1 ]; then
  log "Collector is up: $(curl -fs "http://127.0.0.1:$HEALTH_PORT")"
else
  warn "collector did not become healthy in 30 s — check $INSTALL_DIR/logs/collector.log"
fi

cat <<SUMMARY

Done.
  OTLP endpoint (tenant) : $ENDPOINT
  Local collector        : http://127.0.0.1:$COLLECTOR_PORT  (health: http://127.0.0.1:$HEALTH_PORT)
  Token storage          : $TOKEN_BACKEND
  Hook                   : $HOOK_DST (PreToolUse, PostToolUse, UserPromptSubmit, Stop)
  Attributes             : $CLAUDE_DIR/otel-attrs.json
  Collector config/logs  : $INSTALL_DIR/otel-collector.yaml, $INSTALL_DIR/logs/collector.log
  Prompt capture         : $([ "$CAPTURE_PROMPTS" = 1 ] && echo ON || echo off)
  Native Claude OTel     : $([ "$NATIVE_OTEL" = 1 ] && echo "on (settings.json env)" || echo "off (see managed-settings.example.json)")
  Dynatrace Evals        : not run automatically — evals/run-evals.sh --help (needs prompt capture ON; calls an LLM judge)

Next steps:
  • Restart open Claude Code sessions (Desktop Code tab and CLI) so the hooks load.
  • Import Dashboard/Developers AI Usage.json in the tenant (Dashboards → Upload).
  • Optional: score prompts/responses with Dynatrace Evals — see README "Dynatrace Evals" (evals/run-evals.sh plan).
  • Service control:
  $SERVICE_HINT
SUMMARY

# ── 8. Dynatrace Evals pointer (print only, never runs) ──────────────────────
if [ "$ENABLE_EVALS" = 1 ]; then
  NODE_OK=0
  if command -v node >/dev/null 2>&1; then
    NODE_MAJOR="$(node --version | sed -E 's/^v([0-9]+).*/\1/')"; [ "${NODE_MAJOR:-0}" -ge 20 ] 2>/dev/null && NODE_OK=1
  fi
  cat <<EVALS

Dynatrace Evals (dt-evals) — optional, not started by this installer
  Node.js >= 20          : $([ "$NODE_OK" = 1 ] && echo "ok ($(node --version))" || echo "MISSING — install from https://nodejs.org")
  Prompt capture         : $([ "$CAPTURE_PROMPTS" = 1 ] && echo "ON" || echo "OFF — evaluators need prompt/response text; re-run with --capture-prompts")
  1. Platform token      : $ASSET_DIR/evals/run-evals.sh doctor     (scopes: storage:spans:read storage:buckets:read storage:bizevents:read openpipeline:bizevents:ingest storage:logs:read)
  2. Judge key           : export ANTHROPIC_API_KEY=... (or OPENAI_API_KEY, --provider)
  3. Preview, no judge   : $ASSET_DIR/evals/run-evals.sh preview --since 1h
  4. Real run (asks)     : $ASSET_DIR/evals/run-evals.sh run --since 1h --sample 10 --metrics prompt-injection,pii-leakage
  Each real run calls an external LLM judge (costs money). Results: fetch bizevents | filter event.type == "gen_ai.evaluation.result"
EVALS
fi
