#!/usr/bin/env bash
# Service wrapper: resolves the Dynatrace ingest token from the OS credential
# store and starts the local OpenTelemetry Collector. Installed by install.sh to
# ~/.dt-ai-obs/run-collector.sh and run by launchd (macOS) / systemd --user (Linux).
set -euo pipefail
DIR="${DT_AI_OBS_DIR:-$HOME/.dt-ai-obs}"
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
    echo "run-collector: unknown TOKEN_BACKEND '$TOKEN_BACKEND'" >&2; exit 78 ;;
esac
if [ -z "$DT_INGEST_TOKEN" ]; then
  echo "run-collector: empty ingest token (backend: $TOKEN_BACKEND); re-run install.sh" >&2
  exit 78
fi
export DT_INGEST_TOKEN
exec "$DIR/bin/otelcol-contrib" --config "$DIR/otel-collector.yaml"
