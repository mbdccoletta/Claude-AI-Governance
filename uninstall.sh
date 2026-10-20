#!/usr/bin/env bash
# Dynatrace AI Observability for Claude — uninstaller (macOS / Linux)
# Stops and removes the collector service, the stored token, the Claude Code
# hook entries this asset added, otel-attrs.json and ~/.dt-ai-obs.
#
# Usage: ./uninstall.sh [--keep-hooks] [--keep-binary] [--yes]
#   --keep-hooks    leave ~/.claude/otel-hook.py and the settings.json entries
#   --keep-binary   keep ~/.dt-ai-obs/bin (saves the ~100 MB download next time)
#   --yes           do not ask for confirmation
set -euo pipefail
ASSET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${DT_AI_OBS_DIR:-$HOME/.dt-ai-obs}"
case "$INSTALL_DIR" in ""|/|"$HOME"|"$HOME/") echo "refusing to operate on '$INSTALL_DIR'" >&2; exit 1 ;; esac
[ -f "$INSTALL_DIR/config.env" ] || [ -d "$INSTALL_DIR/bin" ] || echo "warning: $INSTALL_DIR does not look like an install dir (no config.env/bin)" >&2
CLAUDE_DIR="$HOME/.claude"
KEYCHAIN_SERVICE="dt-ai-obs-claude"
LAUNCHD_LABEL="com.dynatrace.dt-ai-obs-claude"
SYSTEMD_UNIT="dt-ai-obs-claude.service"
KEEP_HOOKS=0; KEEP_BINARY=0; YES=0
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-hooks) KEEP_HOOKS=1; shift ;;
    --keep-binary) KEEP_BINARY=1; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
if [ "$YES" = 0 ]; then
  read -r -p "Remove the Dynatrace AI Observability for Claude collector, token and hooks? [y/N] " a
  [[ "$a" =~ ^[Yy] ]] || { echo "aborted"; exit 0; }
fi

# ── service ─────────────────────────────────────────────────────────────────
case "$(uname -s)" in
  Darwin)
    PLIST="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
    log "Stopping launchd agent $LAUNCHD_LABEL"
    launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1 || true
    rm -f "$PLIST"
    ;;
  Linux)
    if command -v systemctl >/dev/null 2>&1 && [ -f "$HOME/.config/systemd/user/$SYSTEMD_UNIT" ]; then
      log "Stopping systemd user unit $SYSTEMD_UNIT"
      systemctl --user disable --now "$SYSTEMD_UNIT" >/dev/null 2>&1 || true
      rm -f "$HOME/.config/systemd/user/$SYSTEMD_UNIT"
      systemctl --user daemon-reload || true
    fi
    ;;
esac
pkill -f "$INSTALL_DIR/bin/otelcol-contrib" 2>/dev/null || true

# ── token ───────────────────────────────────────────────────────────────────
if [ "$(uname -s)" = Darwin ]; then
  log "Removing the Keychain item ($KEYCHAIN_SERVICE)"
  /usr/bin/security delete-generic-password -a "$(id -un)" -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 || true
elif command -v secret-tool >/dev/null 2>&1; then
  secret-tool clear service "$KEYCHAIN_SERVICE" key ingest-token 2>/dev/null || true
fi
rm -f "$INSTALL_DIR/ingest-token"

# ── Claude Code side ────────────────────────────────────────────────────────
if [ "$KEEP_HOOKS" = 0 ]; then
  log "Removing Claude Code hook entries and files"
  python3 -I "$ASSET_DIR/hooks/configure-hooks.py" remove-hooks
  python3 -I "$ASSET_DIR/hooks/configure-hooks.py" native-otel --port "$(sed -n 's/^COLLECTOR_PORT=//p' "$INSTALL_DIR/config.env" 2>/dev/null || echo 4318)" --remove
  if [ -f "$CLAUDE_DIR/otel-hook.py" ] && ! grep -q 'dt-ai-observability-claude' "$CLAUDE_DIR/otel-hook.py"; then
    warn "$CLAUDE_DIR/otel-hook.py was not installed by this asset (VS Code extension?) — leaving it in place"
  else
    rm -f "$CLAUDE_DIR/otel-hook.py"
  fi
  rm -f "$CLAUDE_DIR/otel-attrs.json"
  rm -rf "$CLAUDE_DIR/otel-state"
else
  log "Keeping Claude Code hooks (--keep-hooks)"
fi

# ── files ───────────────────────────────────────────────────────────────────
if [ -d "$INSTALL_DIR" ]; then
  if [ "$KEEP_BINARY" = 1 ]; then
    log "Removing $INSTALL_DIR (keeping bin/)"
    find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 ! -name bin -exec rm -rf {} +
  else
    log "Removing $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
  fi
fi
echo "Done. Restart open Claude Code sessions so the removed hooks stop loading."
