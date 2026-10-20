#!/usr/bin/env bash
# Service wrapper: resolves the Dynatrace ingest token from the OS credential
# store and starts the local OpenTelemetry Collector. Installed by install.sh to
# ~/.dt-ai-obs/run-collector.sh and run by launchd (macOS) / systemd --user (Linux).
set -euo pipefail
umask 077
DIR="${DT_AI_OBS_DIR:-$HOME/.dt-ai-obs}"
# simple size-based rotation of the log the service manager appends to (no root/logrotate needed)
LOG="$DIR/logs/collector.log"
if [ -f "$LOG" ] && [ "$(stat -f %z "$LOG" 2>/dev/null || stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 52428800 ]; then
  mv -f "$LOG" "$LOG.1" 2>/dev/null || true
fi
# shellcheck disable=SC1091
. "$DIR/config.env"   # TOKEN_BACKEND, KEYCHAIN_SERVICE, ...

case "${TOKEN_BACKEND:-file}" in
  keychain)
    DT_INGEST_TOKEN="$(/usr/bin/security find-generic-password -a "$(/usr/bin/id -un)" -s "$KEYCHAIN_SERVICE" -w)" ;;
  secret-tool)
    DT_INGEST_TOKEN="$(secret-tool lookup service "$KEYCHAIN_SERVICE" key ingest-token)" ;;
  file)
    DT_INGEST_TOKEN="$(cat "$DIR/ingest-token")" ;;
  *)
    echo "run-collector: unknown TOKEN_BACKEND '$TOKEN_BACKEND'" >&2; sleep 300; exit 78 ;;
esac
if [ -z "$DT_INGEST_TOKEN" ]; then
  echo "run-collector: empty ingest token (backend: $TOKEN_BACKEND); re-run install.sh" >&2
  sleep 300   # throttle the service manager's restart loop (locked keyring, missing item)
  exit 78
fi
export DT_INGEST_TOKEN
exec "$DIR/bin/otelcol-contrib" --config "$DIR/otel-collector.yaml"
