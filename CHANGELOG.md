# Changelog

## Unreleased

- docs: Uninstall section (README and GUIDE) now lists exactly what is removed per OS, when to use `--keep-hooks` / `--keep-binary`, how to verify the machine is clean, and how it coexists with the VS Code extension.

## 1.0.1 — 2026-10-20

Hardening release: the four batches (P1–P4) of [docs/FINAL-REVIEW.md](docs/FINAL-REVIEW.md). No schema or dashboard-id changes;
re-run the installer and `connector/deploy/deploy.sh` to pick everything up.

### P1 · hook privacy and integrity
- `claude.tool_input` / `claude.tool_response` are sent only with `--capture-prompts`; the collector redaction processor also deletes them (`error_mode: propagate`).
- State file per session is written atomically under an exclusive lock (`fcntl.flock`); tool records are keyed by `tool_use_id`
  (fallback by name for older Claude Code); stale records expire; nothing is written for events of unknown sessions; `SessionEnd` cleans up.
- Tokens are summed over every assistant message of the turn (offset taken from `transcript_path` at `UserPromptSubmit`), model and last
  reply come from the transcript; `gen_ai.usage.cost_usd` is set only from values Claude Code reports (`cost_usd` on the Stop event or
  `costUSD` in the transcript), never estimated.
- State directory 0700, files 0600, session ids sanitised; prompt text persisted only when capture is on; prompt cleaner also strips
  harness tags (`<command-*>`, `<local-command-stdout>`, `<ide_*>`), unclosed blocks and repeated spaces.
- New `test/hook_tests.py` (isolated HOME + loopback sink): concurrency, privacy gates, token sums, state hygiene, dead collector.

### P2 · layer 3 workflow — trust boundary, time budget, incremental ingest
- `resolve_config` reads `org_type`, `credential_*`, `anthropic_base_url`, `org_id`, `ingest_batch_size` and `time_budget_ms` from the
  workflow **input** only; run parameters may override just the lookback windows, `console_include_api_usage`, `dry_run` and `console_debug`
  (anything else is ignored and logged). `anthropic_base_url` must be `https://api.anthropic.com` (URL-parsed; look-alike hosts rejected)
  unless `allow_custom_base_url: true` (mocks only). Missing `org_type` fails fast.
- 95 s time budget per task (`MAX_PAGES` 200, `Retry-After` clamped to 20 s and never slept across the deadline); accumulated events are
  flushed when < 15 s are left and at the end; results carry `partial`, `reason`, `flushes`, `elapsed_ms`, `events_built`, `ingested`.
  Ingest batches split by count **and** 4 MiB.
- `requests` no longer double-counted (cost rows pass `null`); Console user actors without e-mail get `user.email: null` and a `user:<id>`
  dedup key.
- Workflow imported private; `vault_upsert.js` creates the credential with **Owner access only**; `deploy.sh` pipes the Anthropic key to
  dtctl on stdin (never argv or a file), splits allowlist read and merge so a dtctl error is never mistaken for "create", warns when the
  allowlist is not enforced, and gains `--public`.
- DQL: `product == "claude_code"` filter restored in `official-vs-observed-tokens.dql`, logs side limited to `service.name`
  `claude-code` / `claude-code-desktop`, `timezone: "UTC"` on every `formatTimestamp`; dashboard rebuilt and `--check` extended.
- Mock server gains `MOCK_PAGES` / `MOCK_SLOW` (429 + `Retry-After`); the test suite adds guard, budget, requests-parity and
  ingest-split scenarios. Verified on a real tenant (console workflow run: SUCCESS, `partial: false`).

### P3 · installer, collector and supply chain
- Ingest token: whitespace stripped, format enforced (`dt0c01.<24>.<64>`) and an empty pre-flight POST to `<endpoint>/v1/traces`;
  401/403 abort the install (a double paste into the hidden prompt used to be accepted and fail with 401 later). Both installers.
- Collector debug exporter **off by default** (`--verbose-collector` / `-VerboseCollector` turns it on; `--quiet-collector` kept for
  compatibility). `~/.dt-ai-obs` and `logs/` are 0700, `collector.log` 0600 and rotated at 50 MiB by the wrapper.
- otelcol-contrib pinned to 0.163.1 by default (`--otelcol-version latest` opts out; versions validated as X.Y.Z), downloads with
  `--proto '=https' --tlsv1.2`; `@dynatrace-oss/dt-evals` pinned to 0.3.3-alpha (`DT_EVALS_VERSION` overrides).
- gRPC receiver (4317) removed: nothing used it. `memory_limiter` first in every pipeline (256 MiB / 64 MiB spike).
- Missing or empty token no longer restart-loops the service: the wrapper sleeps 5 min before exit 78 and systemd has
  `RestartPreventExitStatus=78`. `run-collector.ps1` runs the collector with `$ErrorActionPreference='Continue'` so the first stderr
  line no longer kills the wrapper on PowerShell 5.1.
- `configure-hooks.py`: an already-installed hook whose path changed is updated; native env block removed by our own value pattern,
  not only the exact value; `settings.json` backups are 0600 and only the last three are kept.
- `config.env` written with shell quoting; `uninstall.sh` / `.ps1` refuse `/`, `$HOME` or an empty install dir; `launchctl bootstrap`
  retried; `--help` prints the whole header (no fixed line range).
- `import_team_spend.py`: `--tenant` must be https (loopback or `--allow-http` for mocks), retries 429/5xx with backoff, strict date check,
  5 MiB batch guard.
- Re-install: waits for the previous collector to exit, probes ports with `SO_REUSEADDR` and retries the default port briefly, so a
  re-install no longer drifts silently to 4319.

### Team CSV: one command, no guesswork
- New `connector/csv-import/import-team-csv.sh` / `.ps1`: usage day defaults to yesterday (UTC) with a file-date sanity check, tenant
  taken from the layer 1/2 install, delivery through **dtctl with the user's own login** (`ingest_events.js`, no token) or a
  `bizevents.ingest` token kept in the OS credential store (`--save-token`), preview (events, users, USD, products, models) and `[y/N]`
  confirmation before sending, `--dry-run` / `--yes`. `import_team_spend.py` gains `--preview`.
- New skill `connector/skills/import-team-csv/SKILL.md` so Claude can run the import on request. Both delivery paths verified
  (mock sink and a real tenant).

### Shared dashboard compatibility
- `--squad` / `-Squad` now also writes `user.team` (same value), the key the *Developers AI Usage* dashboard of the VS Code asset — and this
  asset's Claude-only copy — groups by in "Custo por time" / "Uso por time"; those tiles were empty for machines instrumented by this asset.
  `--team` accepted as an alias. Verified on a real tenant with the VS Code dashboard's own query.

### P4 · developer dimensions on the native metrics
- New `transform/metric_dimensions` (after the `resource` processor in the metrics pipeline) copies `user.email`,
  `deployment.environment` and every custom attribute (`squad`, `cost_center`, `--attr …`) from the resource onto each datapoint, so
  `timeseries … by: {user.email}` on `claude_code.*` works without a tenant-side allow-list. The renderer emits one statement per
  custom attribute. Verified on a real tenant.


## 1.0.0 — 2026-10-19

First complete version of **Dynatrace AI Observability for Claude**: three layers, one tenant.

### Layer 1 · Claude Code hooks → spans
- `install.sh` / `install.ps1`: hook (`~/.claude/otel-hook.py`, upstream v1.7.0 + two small patches in `hooks/otel-hook.patch`:
  `service.name=claude-code-desktop` for the Desktop app and the prompt cleaning below),
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
- `user.email`, `squad` and `cost_center` are resource attributes on the native metrics, not datapoint dimensions: `timeseries … by: {user.email}`
  on `claude_code.*` returns null (verified). Per-developer splits come from the hook spans and the `api_request` log events; datapoint-level
  stamping in the collector is planned. *(fixed in 1.0.1, P4)*
- `claude.tool_input` / `claude.tool_response` (first 4 KiB) are sent on every tool span regardless of `--capture-prompts`; a redaction option is planned. *(fixed in 1.0.1, P1)*
- The installer only checks that the ingest token is non-empty (a double paste into the hidden prompt yields 401); a format check is planned. *(fixed in 1.0.1, P3)*
