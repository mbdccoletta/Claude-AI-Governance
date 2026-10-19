#!/usr/bin/env bash
# Deploy all three org types to one tenant in a single command (one workflow + one vault credential per type).
#   export ANTHROPIC_ENTERPRISE_KEY='...'   # Analytics API key (Claude Enterprise)  — skipped if empty
#   export ANTHROPIC_CONSOLE_KEY='...'      # Admin API key sk-ant-admin01-... (Claude Console) — skipped if empty
#   deploy/deploy_all.sh --context cca --org-id fov-demo [--run-now] --yes
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARGS=()
while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done
pass=(); for a in ${ARGS[@]+"${ARGS[@]}"}; do pass+=("$a"); done

if [ -n "${ANTHROPIC_ENTERPRISE_KEY:-}" ]; then
  echo "########## enterprise ##########"; "$HERE/deploy.sh" --org-type enterprise --key-env ANTHROPIC_ENTERPRISE_KEY ${pass[@]+"${pass[@]}"}
else echo "########## enterprise: ANTHROPIC_ENTERPRISE_KEY empty — skipped ##########"; fi
if [ -n "${ANTHROPIC_CONSOLE_KEY:-}" ]; then
  echo "########## console ##########"; "$HERE/deploy.sh" --org-type console --key-env ANTHROPIC_CONSOLE_KEY ${pass[@]+"${pass[@]}"}
else echo "########## console: ANTHROPIC_CONSOLE_KEY empty — skipped ##########"; fi
echo "########## team ##########"; "$HERE/deploy.sh" --org-type team ${pass[@]+"${pass[@]}"}
