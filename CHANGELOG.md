# Changelog

## 1.0.0 — 2026-10-19

First complete version of **Dynatrace AI Observability for Claude**: three layers, one tenant.

### Layer 1 · Claude Code hooks → spans
- `install.sh` / `install.ps1`: hook (`~/.claude/otel-hook.py`, upstream v1.7.0 + `service.name=claude-code-desktop` patch),
  developer attributes, otelcol-contrib as a user service (launchd / systemd / Scheduled Task), ingest token in the OS credential store,
  optional `--capture-prompts`, `uninstall.sh` / `uninstall.ps1`.
- Prompt cleaning: `<system-reminder>…</system-reminder>` blocks injected by the Claude Desktop app are dropped and
  `<pasted_content>` wrappers removed before `gen_ai.prompt.0.content` is set (hook patch, see `hooks/otel-hook.patch`).
- Verified on a real tenant: chat and tool-call spans with prompt/response content when enabled; Desktop vs CLI distinguishable by `service.name`.

### Layer 2 · Claude Code native OpenTelemetry
- `--enable-native-otel` writes the env block into `~/.claude/settings.json`; collector carries a logs pipeline and moves the Anthropic
  account e-mail to `claude.account_email` so `user.email` stays the configured one.
- Verified: `claude_code.token.usage` (input/output/cacheRead/cacheCreation), `claude_code.cost.usage`, `claude_code.session.count`,
  log events `api_request` (tokens + `cost_usd`), `user_prompt`, `tool_decision`, `tool_result` (event names without prefix).
- Troubleshooting learned the hard way: OTLP logs export 200 but `fetch logs` empty = check `fetch dt.system.buckets` `has_access` for
  `default_logs` and look for DENY policies on the user's IAM groups.

### Layer 3 · Official usage & cost (`connector/`)
- Workflow `claude-usage-connector.json` (schedule 15:00 UTC, 4 Run-JavaScript tasks gated by `org_type`): Enterprise Analytics API
  (`user_cost_report` + `user_usage_report`, 10-day re-read for revisions), Console Admin API (`usage_report/claude_code` per user,
  `usage_report/messages` per workspace; 1d buckets for past days + 1h buckets for today because the API only returns closed buckets),
  Team reminder. Credential found by name in the vault. 60 req/min budget, backoff on 429, frozen cursors, 410 restart, batched ingest.
- Unified bizevent `claude.usage.daily` with `dedup.key`; `schema.md`; four DQL queries; `csv-import/import_team_spend.py` for Team plans.
- `deploy/deploy.sh` / `deploy_all.sh` (dtctl): outbound allowlist merge, workflow apply with id stamping, run-now, verification;
  `skills/deploy-claude-usage-connector/SKILL.md` lets Claude Code run the deployment.
- Dashboard `connector/dashboard/claude-usage-dashboard.json` (14 tiles, demo rows excluded); local test suite with a mock of the
  three Anthropic endpoints and a bizevents sink (`connector/test/run_tests.sh`).

### Optional · Dynatrace Evals (`evals/`)
- `evals/run-evals.sh` (and `.ps1`, unverified) wrap `@dynatrace-oss/dt-evals`: `plan` / `preview` / `validate` / `doctor` / `run`,
  evaluators default to `prompt-injection,pii-leakage`, sample 10 % of the last hour, confirmation before any judge call. Requires
  prompt capture ON; results land as bizevents `gen_ai.evaluation.result`. `install.sh --enable-evals` only checks Node 20+ and prints the steps.

### Scope
- Claude only: the dashboard keeps just the Claude sections (GPT, Gemini and Copilot tiles removed), variables default to
  `anthropic` and Claude models, and every span query filters Claude models. Other assistants are the VS Code asset's job.

### Known limitations
- Personal Pro/Max subscriptions have no official usage source; Claude via Bedrock/Vertex/Foundry is not covered.
- Enterprise adapter validated against the documented API shapes and a mock only (no Enterprise key was available).
- Credential vault creation via dtctl needs `environment-api:credentials:*`; with an OAuth context create the credential in the UI.
- Native logs/metrics from Claude Code on the web require the OTEL_* variables in the cloud environment (no local collector there).
