#!/usr/bin/env bash
# Dynatrace Evals for Claude Code spans (macOS / Linux)
#
# Wraps the open-source CLI @dynatrace-oss/dt-evals so the gen_ai.* spans this
# asset sends (one "chat" span per Claude Code turn) can be scored by an LLM
# judge: prompt injection, PII leakage, toxicity, ... Results are written back
# to the same tenant as bizevents (event.type == "gen_ai.evaluation.result").
#
# The evaluators need the prompt/response text, so this only works when the
# asset was installed with --capture-prompts (otel-attrs.json _capture_prompts).
# Every real run calls an external LLM judge (your OpenAI / Anthropic / Azure /
# Gemini / Bedrock account): it costs money and the masked prompt text leaves
# the tenant for the judge call. Nothing here runs without a confirmation.
#
# Usage: evals/run-evals.sh [command] [options]
#
# Commands
#   run          (default) write the eval config, confirm, run `dt-evals run`
#   plan         alias for `run --dry-run`: print config + command, no network
#   preview      `dt-evals run --dry-run`: fetches the matching spans from the
#                tenant and prints what would be judged; no judge call, no write
#   validate     `dt-evals validate`: config schema, tenant connectivity, judge key
#   doctor       `dt-evals doctor`: environment check + platform token walkthrough
#                (saves DT_API_TOKEN to evals/.env)
#   configure    the interactive dt-evals wizard (optional, this script writes
#                its own config; use it if you prefer the wizard)
#   status       `dt-evals status`         evaluators  `dt-evals evaluators list`
#   runs         `dt-evals runs list`      help        this text
#
# Options
#   --since 30m|1h|6h|24h      span lookback window                 (default 1h)
#   --sample 10|25|50|100      percent of matching spans to judge   (default 10)
#   --metrics a,b,c            evaluators to run; "all" = all 15 built-ins
#                              (default prompt-injection,pii-leakage)
#   --provider NAME            judge provider: openai|anthropic|azure-openai|
#                              gemini|vertex|bedrock                (default anthropic)
#   --model NAME               judge model (default: dt-evals' default per provider)
#   --env-url URL              tenant URL; default derived from the installed
#                              collector config (~/.dt-ai-obs/config.env) or $DT_ENV_URL
#   --service NAME             claude-code | claude-code-desktop | both (default both)
#   --concurrency N            parallel judge calls (dt-evals default 5)
#   --store-evaluated-prompt   copy prompt/response into the result bizevents (default off)
#   --config PATH              use an existing .dt-eval.yaml instead of generating one
#   --dry-run                  print the generated config and the exact command;
#                              nothing is executed, no network at all
#   --yes                      skip the confirmation before a real run
#   --allow-no-capture         run even if prompt capture is off (nothing to judge)
#   -h, --help
#
# Environment: DT_API_TOKEN (platform token dt0s16… with the scopes below, or an
# API token dt0c01…), the judge key (ANTHROPIC_API_KEY, OPENAI_API_KEY, …),
# DT_EVALS_VERSION (npm version or tag, default latest), DT_EVALS_BIN (use an
# installed binary instead of npx). dt-evals also loads evals/.env automatically.
#
# Token scopes (platform token): storage:spans:read, storage:buckets:read,
# storage:bizevents:read, openpipeline:bizevents:ingest (storage:events:write on
# *.apps.dynatrace.com), storage:logs:read (validate probe), storage:metrics:write (optional).
set -euo pipefail

EVALS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSET_DIR="$(cd "$EVALS_DIR/.." && pwd)"
INSTALL_DIR="${DT_AI_OBS_DIR:-$HOME/.dt-ai-obs}"
ATTRS_FILE="$HOME/.claude/otel-attrs.json"
PKG="@dynatrace-oss/dt-evals"
DT_EVALS_VERSION="${DT_EVALS_VERSION:-latest}"
ALL_METRICS="prompt-injection,output-prompt-injection,pii-leakage,toxicity,bias,hallucination,faithfulness,factual-accuracy,relevance,context-relevance,answer-completeness,conciseness,fluency,summarization-quality,user-frustration"

CMD="run"
SINCE="1h"; SAMPLE="10"; METRICS="prompt-injection,pii-leakage"
PROVIDER="anthropic"; MODEL=""; ENV_URL="${DT_ENV_URL:-}"; SERVICE="both"
CONCURRENCY=""; STORE_PROMPT=0; CONFIG=""; DRY_RUN=0; YES=0; ALLOW_NO_CAPTURE=0

usage() { sed -n '2,57p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  run|plan|preview|validate|doctor|configure|status|evaluators|runs|help) CMD="$1"; shift ;;
esac
[ "$CMD" = plan ] && { CMD="run"; DRY_RUN=1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    --sample) SAMPLE="$2"; shift 2 ;;
    --metrics|--metric) METRICS="$2"; shift 2 ;;
    --provider) PROVIDER="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --env-url) ENV_URL="$2"; shift 2 ;;
    --service) SERVICE="$2"; shift 2 ;;
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
    --store-evaluated-prompt) STORE_PROMPT=1; shift ;;
    --config) CONFIG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --allow-no-capture) ALLOW_NO_CAPTURE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done
[ "$CMD" = help ] && { usage; exit 0; }

# ── validation of inputs ────────────────────────────────────────────────────
[[ "$SINCE" =~ ^[0-9]+(m|h|d)$ ]] || die "--since must look like 30m, 1h, 6h, 24h (got '$SINCE')"
[[ "$SAMPLE" =~ ^[0-9]+$ ]] && [ "$SAMPLE" -ge 1 ] && [ "$SAMPLE" -le 100 ] || die "--sample must be 1-100 (got '$SAMPLE')"
case "$PROVIDER" in openai|anthropic|azure-openai|gemini|vertex|bedrock) ;; *) die "unknown --provider '$PROVIDER'" ;; esac
case "$SERVICE" in both|claude-code|claude-code-desktop) ;; *) die "--service must be claude-code, claude-code-desktop or both" ;; esac
[ "$METRICS" = all ] && METRICS="$ALL_METRICS"
METRICS="${METRICS// /}"
IFS=',' read -r -a METRIC_LIST <<<"$METRICS"
[ "${#METRIC_LIST[@]}" -ge 1 ] || die "--metrics needs at least one evaluator"
for m in "${METRIC_LIST[@]}"; do
  case ",$ALL_METRICS," in *",$m,"*) ;; *) die "unknown evaluator '$m' (run: $0 evaluators)" ;; esac
done

# ── prerequisites (local only) ──────────────────────────────────────────────
need_node() {
  command -v node >/dev/null 2>&1 || die "Node.js >= 20 is required for dt-evals (https://nodejs.org)"
  local major; major="$(node --version | sed -E 's/^v([0-9]+).*/\1/')"
  [ "$major" -ge 20 ] 2>/dev/null || die "Node.js $(node --version) found, dt-evals needs >= 20"
  if [ -z "${DT_EVALS_BIN:-}" ]; then
    command -v npx >/dev/null 2>&1 || die "npx not found (comes with npm); or set DT_EVALS_BIN=/path/to/dt-evals"
  fi
}

capture_on() {
  [ -f "$ATTRS_FILE" ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if str(d.get("_capture_prompts","false")).lower()=="true" else 1)' "$ATTRS_FILE"
  else
    grep -Eq '"_capture_prompts"[[:space:]]*:[[:space:]]*"?true"?' "$ATTRS_FILE"
  fi
}

derive_env_url() {
  # ~/.dt-ai-obs/config.env: DT_OTLP_ENDPOINT=https://abc12345.live.dynatrace.com/api/v2/otlp
  [ -n "$ENV_URL" ] && return 0
  if [ -f "$INSTALL_DIR/config.env" ]; then
    local ep; ep="$(sed -n 's/^DT_OTLP_ENDPOINT=//p' "$INSTALL_DIR/config.env" | head -1)"
    if [[ "$ep" =~ ^(https?://[^/]+) ]]; then
      ENV_URL="${BASH_REMATCH[1]}"
      case "$ENV_URL" in http://127.0.0.1*|http://localhost*) ENV_URL="" ;; esac   # local test sink
    fi
  fi
}

judge_key_var() {
  case "$PROVIDER" in
    openai) echo OPENAI_API_KEY ;; anthropic) echo ANTHROPIC_API_KEY ;;
    azure-openai) echo AZURE_OPENAI_API_KEY ;; gemini) echo GOOGLE_API_KEY ;;
    vertex) echo GOOGLE_CLOUD_PROJECT ;; bedrock) echo AWS_ACCESS_KEY_ID ;;
  esac
}

dotenv_has() { [ -f "$EVALS_DIR/.env" ] && grep -Eq "^$1=." "$EVALS_DIR/.env"; }

# ── config generation ───────────────────────────────────────────────────────
write_config() {
  CONFIG="$EVALS_DIR/.dt-eval.yaml"
  local svc_filter
  if [ "$SERVICE" = both ]; then svc_filter="[claude-code, claude-code-desktop]"; else svc_filter="[$SERVICE]"; fi
  {
    echo "# generated by dt-ai-observability-claude evals/run-evals.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# no secrets here: DT_API_TOKEN and the judge key come from the environment or evals/.env"
    echo "schemaVersion: 3"
    echo "name: claude-code"
    echo "dynatrace:"
    echo "  environmentUrl: $ENV_URL"
    echo "judge:"
    echo "  provider: $PROVIDER"
    [ -n "$MODEL" ] && echo "  model: $MODEL"
    echo "  timeout: 30000"
    echo "  maxRetries: 2"
    echo "  concurrency: ${CONCURRENCY:-5}"
    echo "scope:"
    echo "  since: $SINCE"
    echo "  level: agent-span                 # one verdict per Claude Code turn"
    echo "  operationNames: [chat]            # the hook's per-turn span"
    echo "  filters:"
    echo "    service.name: $svc_filter"
    echo "  spanFields:"
    echo "    input: gen_ai.prompt.0.content"
    echo "    output: gen_ai.completion.0.content"
    echo "    model: gen_ai.request.model"
    echo "  sampling:"
    echo "    strategy: random"
    echo "    percent: $SAMPLE"
    echo "metrics:"
    echo "  enabled:"
    for m in "${METRIC_LIST[@]}"; do echo "    - $m"; done
    echo "storeEvaluatedPrompt: $([ "$STORE_PROMPT" = 1 ] && echo true || echo false)"
  } >"$CONFIG"
  chmod 0600 "$CONFIG"
}

dt_evals() {
  # run from evals/ so dt-evals picks up evals/.env and relative config paths
  if [ -n "${DT_EVALS_BIN:-}" ]; then (cd "$EVALS_DIR" && "$DT_EVALS_BIN" "$@")
  else (cd "$EVALS_DIR" && npx -y "$PKG@$DT_EVALS_VERSION" "$@"); fi
}

dt_evals_cmdline() {
  if [ -n "${DT_EVALS_BIN:-}" ]; then printf '%s' "$DT_EVALS_BIN"; else printf 'npx -y %s@%s' "$PKG" "$DT_EVALS_VERSION"; fi
  printf ' %q' "$@"; echo
}

# ── pass-through commands ───────────────────────────────────────────────────
case "$CMD" in
  evaluators) need_node; dt_evals evaluators list; exit $? ;;
  status)     need_node; dt_evals status; exit $? ;;
  runs)       need_node; dt_evals runs list; exit $? ;;
  doctor)
    need_node; derive_env_url
    log "dt-evals doctor: checks dtctl, walks you through a platform token (saved to evals/.env, never printed)"
    log "Create the token at https://myaccount.dynatrace.com/platformTokens with: storage:spans:read storage:buckets:read storage:bizevents:read openpipeline:bizevents:ingest storage:logs:read"
    dt_evals doctor ${ENV_URL:+--env-url "$ENV_URL"}; exit $? ;;
  configure)
    need_node; derive_env_url
    log "dt-evals interactive wizard → $EVALS_DIR/.dt-eval.yaml (secrets go to evals/.env)"
    warn "the wizard does not know this asset's span layout; re-running '$0 run' later regenerates the config with the Claude Code scope (operationNames, service.name filter, spanFields)"
    dt_evals configure --output .dt-eval.yaml --since "$SINCE" ${ENV_URL:+--env-url "$ENV_URL"} --provider "$PROVIDER" ${MODEL:+--model "$MODEL"}; exit $? ;;
esac

# ── run / preview / validate ────────────────────────────────────────────────
[ "$DRY_RUN" = 1 ] || need_node
derive_env_url
[ -n "$ENV_URL" ] || die "tenant URL unknown: pass --env-url https://abc12345.live.dynatrace.com or set DT_ENV_URL (the asset's ~/.dt-ai-obs/config.env was not found or points at a local sink)"

if ! capture_on; then
  if [ "$ALLOW_NO_CAPTURE" = 1 ]; then
    warn "prompt capture is OFF in $ATTRS_FILE — the spans have no prompt/response text, evaluators will have nothing to score"
  else
    die "prompt capture is OFF (\"_capture_prompts\" != \"true\" in $ATTRS_FILE). Re-run install.sh with --capture-prompts, restart Claude Code sessions, wait for new turns, then retry. (--allow-no-capture overrides.)"
  fi
fi

if [ -n "$CONFIG" ]; then
  [ -f "$CONFIG" ] || die "--config $CONFIG not found"
  CONFIG="$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG")"
  USER_CONFIG=1
else
  USER_CONFIG=0
  write_config
fi

RUN_ARGS=(run --config "$CONFIG" --since "$SINCE" --sample "$SAMPLE")
[ -n "$CONCURRENCY" ] && RUN_ARGS+=(--concurrency "$CONCURRENCY")
[ "$STORE_PROMPT" = 1 ] && RUN_ARGS+=(--store-evaluated-prompt)
if [ "$USER_CONFIG" = 1 ] && [ "${#METRIC_LIST[@]}" -eq 1 ]; then RUN_ARGS+=(--metric "${METRIC_LIST[0]}"); fi
[ "$CMD" = preview ] && RUN_ARGS+=(--dry-run)
[ "$CMD" = validate ] && RUN_ARGS=(validate --config "$CONFIG")

TOKEN_SRC="missing"
if [ -n "${DT_API_TOKEN:-}" ]; then TOKEN_SRC="environment"; elif dotenv_has DT_API_TOKEN; then TOKEN_SRC="evals/.env"; fi
KEY_VAR="$(judge_key_var)"; KEY_SRC="missing"
if [ -n "${!KEY_VAR:-}" ]; then KEY_SRC="environment"; elif dotenv_has "$KEY_VAR"; then KEY_SRC="evals/.env"; fi

cat <<SUMMARY

Dynatrace Evals — Claude Code spans
  Tenant               : $ENV_URL
  Spans                : gen_ai.operation.name == "chat", service.name in $([ "$SERVICE" = both ] && echo "{claude-code, claude-code-desktop}" || echo "{$SERVICE}"), last $SINCE
  Sample               : $SAMPLE % of matching spans (random)
  Evaluators           : $METRICS$([ "$USER_CONFIG" = 1 ] && [ "${#METRIC_LIST[@]}" -gt 1 ] && echo "  (taken from your --config file; --metrics ignored)")
  Judge                : $PROVIDER${MODEL:+ / $MODEL}  (key $KEY_VAR: $KEY_SRC)
  Dynatrace token      : DT_API_TOKEN: $TOKEN_SRC
  Results              : bizevents event.type == "gen_ai.evaluation.result" in the same tenant$([ "$STORE_PROMPT" = 1 ] && echo " (WITH prompt/response text)")
  Prompt capture       : $(capture_on && echo ON || echo OFF)
  Config               : $CONFIG$([ "$USER_CONFIG" = 1 ] && echo " (yours, not modified)")
  Mode                 : $([ "$DRY_RUN" = 1 ] && echo "dry-run (nothing executed)" || { [ "$CMD" = preview ] && echo "preview (reads spans, no judge call, no write)" || { [ "$CMD" = validate ] && echo "validate (connectivity checks only)" || echo "REAL RUN: calls the judge (costs money) and writes bizevents"; }; })

Command:
  cd $EVALS_DIR && $(dt_evals_cmdline "${RUN_ARGS[@]}")
SUMMARY

if [ "$DRY_RUN" = 1 ]; then
  echo; log "dry-run: config written to $CONFIG (no secrets). Nothing was executed and no network call was made."
  echo "Judge calls on a real run ≈ matching spans × $SAMPLE % × ${#METRIC_LIST[@]} evaluator(s); use '$0 preview' to see the exact span count without calling the judge."
  exit 0
fi

[ "$TOKEN_SRC" != missing ] || die "DT_API_TOKEN not set (environment or evals/.env). Run '$0 doctor' for the platform-token walkthrough."
if [ "$CMD" = run ]; then
  [ "$KEY_SRC" != missing ] || warn "$KEY_VAR not set — the judge call will fail; export it or put it in evals/.env"
  if [ "$YES" != 1 ]; then
    [ -t 0 ] || die "refusing a real run without confirmation on a non-interactive shell; add --yes"
    printf 'This calls the %s judge for every sampled turn and writes results to %s. Proceed? [y/N] ' "$PROVIDER" "$ENV_URL"
    read -r ans; case "$ans" in y|Y|yes|YES) ;; *) echo "aborted"; exit 0 ;; esac
  fi
fi

log "$(dt_evals_cmdline "${RUN_ARGS[@]}")"
rc=0; dt_evals "${RUN_ARGS[@]}" || rc=$?
if [ "$CMD" = run ] && [ $rc -eq 0 ]; then
  cat <<NEXT

Read the results in Dynatrace (Notebooks / Dashboards):
  fetch bizevents, from:now()-$SINCE
  | filter event.type == "gen_ai.evaluation.result"
  | summarize runs = countDistinct(dt.eval.run_id), avg_score = avg(gen_ai.evaluation.score.value),
              fails = countIf(gen_ai.evaluation.score.label == "fail"), by:{gen_ai.evaluation.name}
Local run history: $(dt_evals_cmdline runs list)
NEXT
fi
exit $rc
