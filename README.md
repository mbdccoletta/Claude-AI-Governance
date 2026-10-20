<h1 align="center">Dynatrace AI Observability for Claude</h1>
<p align="center"><em>Claude Desktop app (Code tab) · Claude Code CLI → OpenTelemetry → Dynatrace — no VS Code required</em></p>

<p align="center">
  Per-developer token, cost, model and tool-call observability for Claude Code sessions started from the <strong>Claude Desktop app</strong> or the <strong><code>claude</code> CLI</strong>, landing in Dynatrace through a local OpenTelemetry Collector that runs as a user service. Same hook, same collector, same dashboard as the <a href="../dt-ai-observability-vscode">VS Code extension asset</a> — packaged for machines where VS Code is not in the loop.
</p>

---

## Three layers

| Layer | Source | What it answers | Where |
|---|---|---|---|
| 1 · Hooks | Claude Code hook events → `gen_ai.*` spans | what happened in each conversation and tool call, in real time, prompts optional | this folder (`install.sh`) |
| 2 · Native OTel | Claude Code's own metrics and log events | tokens and cost per API call, sessions, lines of code, commits | this folder (`--enable-native-otel`) |
| 3 · Official | Anthropic Enterprise Analytics API, Console Admin API, Team CSV | what Anthropic bills per user and product for the whole org, incl. claude.ai chat, Cowork, Design, Claude Code web | [`connector/`](connector/README.md) |

Diagrams: [one-page overview](docs/overview.svg) · [data collection architecture](connector/docs/data-collection-architecture.svg) · [installation process](connector/docs/installation-process.svg).

---

## What is measured where

| Where the developer uses Claude | Real time on the machine (layers 1 + 2) | Official from Anthropic (layer 3) |
|---|---|---|
| **Claude Desktop app, Code tab** | ✅ conversations, tool calls, tokens, cost per API call, prompts (opt-in) | ✅ as `claude_code` (Enterprise or Console org) |
| **`claude` CLI in a terminal** | ✅ same (`service.name = claude-code`) | ✅ as `claude_code` |
| **VS Code / Cursor** | ✅ same hook (this installer or the VS Code asset) | ✅ as `claude_code` |
| **Claude Code on the web** (Anthropic cloud) | ⚠️ only native metrics/logs, if the cloud environment sets the `OTEL_*` variables | ✅ as `claude_code` (remote) |
| **Cowork** (inside the Desktop app) | ❌ no hooks, no OTel | ✅ as `cowork` (Enterprise) or via Team CSV |
| **claude.ai chat, Design** | ❌ | ✅ as `chat` / `design` (Enterprise) or via Team CSV |
| **Personal Pro / Max subscription** | ✅ on an instrumented machine | ❌ Anthropic exposes no API for personal plans |
| **Claude via Bedrock, Vertex, Foundry** | ✅ hooks still work for Claude Code | ❌ use the cloud provider's billing |

Rule of thumb: layers 1 + 2 answer *what is happening right now and how* on the machines you instrumented; layer 3 answers *what Anthropic bills the whole organization*, including products with no hooks and people who installed nothing. `dql/official-vs-observed-tokens.dql` joins the two.

### Quick answers

- **Do I need an Anthropic API key?** Only for layer 3. Layers 1 + 2 use a Dynatrace ingest token and Claude's normal login.
- **Is the workflow only for claude.ai?** No. It imports the official usage of the whole org: Claude Code (Desktop, CLI, web) plus chat, Cowork and Design when the org is Enterprise; Claude Code and API usage when it is a Console org.
- **Does it work for Cowork?** Only through layer 3 (Enterprise key or Team CSV): daily tokens and cost per user. Cowork has no hooks, so no prompts or tool calls.
- **Why do I see `<system-reminder>` text in prompts?** You should not any more: the hook strips the blocks the Desktop app injects. Older spans keep them.
- **I use the Desktop app with a personal subscription. What do I get?** Everything from layers 1 + 2 on your machine; nothing from layer 3.

## Anthropic plans vs APIs: what exists (verified in Anthropic's docs, 2026-10-19)

| Claude plan / organization | Official usage & cost API | What you get | Key | Caveats |
|---|---|---|---|---|
| **Free, Pro, Max** (personal) | ❌ none | nothing; only layers 1 + 2 on an instrumented machine | — | Anthropic exposes no per-user data for personal plans |
| **Team** | ❌ no API; manual **spend CSV** export (claude.ai → Settings → Analytics) | per user × product × model: requests, prompt/completion tokens, net and gross spend; up to 90 days, refreshed daily with a 1-day lag | — | no cache-token split; someone must export and run the importer |
| **Enterprise, seat-based** | ⚠️ Analytics API: engagement endpoints yes, cost/usage endpoints return **usage credits**, not dollars | active users, sessions, projects, skills, connectors; tokens per user | Analytics API key (primary owner only) | cost is not in USD |
| **Enterprise, usage-based** | ✅ Analytics API: `user_cost_report`, `user_usage_report`, `cost_report`, `usage_report` | per user × product (chat, claude_code, cowork, claude_design, …) × model, daily: tokens, requests, USD | Analytics API key (primary owner only, `read:analytics`) | data from 2026-01-01; available ~4 h after usage, revised until ~7 days after month end; 60 req/min per org |
| **Console / Claude Platform org** (API customers) | ✅ Admin API: `usage_report/claude_code` (per user, daily), `usage_report/messages` (org/workspace, 1m–1d buckets), `cost_report` (org, daily) | Claude Code per user with model breakdown and estimated cost; API tokens per workspace / key / model; USD per workspace | Admin API key `sk-ant-admin01-…` (org admin) | individual (non-org) accounts have no Admin API; `messages` only returns closed buckets; Console on AWS has no usage API |
| **Claude via Bedrock / Vertex / Foundry** | ❌ not in any Anthropic API | — | — | use the cloud provider's billing; hooks still capture Claude Code sessions |

Key types are not interchangeable: an Admin API key cannot call the Enterprise Analytics API and an Analytics key cannot call the Admin API. An organization that uses both the Claude Platform and Claude Enterprise needs both keys, and this asset runs one workflow per key (`org_type = console` and `org_type = enterprise`).

## Credentials you need

| You want | Dynatrace | Anthropic | Who creates it |
|---|---|---|---|
| Layers 1 + 2: prompts, tokens, cost and tool calls from Claude Desktop / CLI on instrumented machines | ingest API token (`openTelemetryTrace.ingest`, `metrics.ingest`, `logs.ingest`) | **none** — Claude keeps its normal login | Dynatrace admin; each developer pastes it once into the installer |
| Layer 3, Claude **Enterprise** org (claude.ai chat, Cowork, Design, Claude Code of every user) | dtctl OAuth context + Credential vault entry | **Analytics API key** | the org's primary owner, claude.ai → Organization settings → API |
| Layer 3, Claude **Console / API** org (Claude Code per user, API per workspace) | same | **Admin API key** `sk-ant-admin01-…` | an org admin, platform.claude.com/settings/admin-keys |
| Layer 3, Claude **Team** plan | ingest token with `bizevents.ingest` for the CSV importer | none — manual CSV export | a Team admin, claude.ai → Settings → Analytics |
| Optional Dynatrace Evals | platform token (`dt-evals doctor`) | one regular API key for the LLM judge (or another provider) | whoever runs the evals |

The Anthropic key is stored once in the tenant's Credential vault and read by the workflow by name; it never reaches developer machines.

### How it works

```
Claude Desktop app (Code tab)  ─┐  hooks: PreToolUse / PostToolUse /
claude CLI                     ─┤  UserPromptSubmit / Stop  →  ~/.claude/otel-hook.py
                                │        │  OTLP/JSON spans (gen_ai.*)
                                │        ▼
                                │  otelcol-contrib  ·  127.0.0.1:4318  (user service, ~50 MB RAM)
                                │        │  strips prompt content · adds user.email, squad, cost_center
Claude Code native OTel ────────┘        │  (metrics + logs, optional, managed settings)
                                         ▼
                                  HTTPS → https://<tenant>.live.dynatrace.com/api/v2/otlp
                                         /v1/traces  /v1/metrics  /v1/logs
```

**What gets captured**

| Source | Prompt / response | Model | Duration | Tokens | Cost | Tool calls |
|---|---|---|---|---|---|---|
| Hook spans (always on) | opt-in¹ | ✓ | ✓ | ✓ (incl. cache) | ✓ when Claude Code reports it | ✓ with input/output |
| Native OTel metrics + logs (optional) | opt-in² | ✓ | ✓ | ✓ per API call | ✓ `cost_usd` per API call | — |

> ¹ Off by default. When on, the hook drops the `<system-reminder>` blocks the Claude Desktop app injects into the user turn and unwraps `<pasted_content>`, so `gen_ai.prompt.0.content` holds only what the developer typed or pasted. `install.sh --capture-prompts` (or `_capture_prompts: "true"` in `~/.claude/otel-attrs.json`) turns it on; the collector also stops redacting.
> ² Off by default. Claude Code only includes prompt text in the `user_prompt` log event when `OTEL_LOG_USER_PROMPTS=1`; the collector deletes it anyway unless prompt capture is on.

**Who is who** — `service.name`:

| Session started from | Hook spans | Native metrics / logs |
|---|---|---|
| Claude Desktop app, Code tab (`CLAUDE_CODE_ENTRYPOINT=claude-desktop`) | `claude-code-desktop` | `claude-code` ³ |
| `claude` CLI in a terminal | `claude-code` | `claude-code` |

> ³ Claude Code's native telemetry carries no entrypoint attribute (its `terminal.type` is `non-interactive` for the Desktop app and for scripted `claude -p` runs alike). [docs/dql-examples.md](docs/dql-examples.md) shows how to join native logs to the hook spans on the session id to label them.

---

## 📑 Table of contents

| | |
|---|---|
| 🔧 [Prerequisites](#prerequisites) | 📦 [Installation](#installation) |
| ✅ [Verify it's working](#verify) | 🏷️ [Custom attributes](#custom-attributes) |
| 📡 [Claude Code native telemetry (optional)](#native-telemetry) | 🔢 [Understanding token counts](#token-counts) |
| 📊 [Validating data in Dynatrace](#validating) | 🧩 [What gets installed](#what-gets-installed) |
| 🛠️ [Troubleshooting](#troubleshooting) | 🗑️ [Uninstall](#uninstall) |
| 🔒 [Privacy and security](#privacy) | 🧪 [Local test (no tenant)](#local-test) |
| 🧪 [Dynatrace Evals (optional)](#evals) | 🔗 [Relation to the VS Code asset](#relation) |
| 📄 [License](#license) | |

---

<a id="prerequisites"></a>
## 🔧 Prerequisites

| Category | Requirement | Detail |
|---|---|---|
| 🏢 Dynatrace tenant | Tenant type | SaaS (Grail). Use the `.live.dynatrace.com` host for OTLP, never `.apps.` |
| 🏢 Dynatrace tenant | App | AI & LLM Observability (from Hub) — for the Prompts stream / AI Obs views |
| 🏢 Dynatrace tenant | API token scopes | `openTelemetryTrace.ingest` + `metrics.ingest` + `logs.ingest` (`logs.ingest` only needed for native telemetry) |
| 💻 Developer machine | OS | macOS 10.15+ (Intel / Apple Silicon), Linux x64 / arm64, Windows 10 1803+ / 11 x64 / arm64 |
| 💻 Developer machine | Python | Python 3.6+ on `PATH` as `python3` (macOS/Linux) or `python` (Windows) — the hook is a stdlib-only Python script |
| 💻 Developer machine | Tools | `curl` + `tar` (macOS/Linux), `tar.exe` (Windows 10 1803+ ships it), PowerShell 5.1+ |
| 💻 Developer machine | Claude | Claude Desktop app with the Code tab and/or Claude Code CLI 1.0+; Python hooks are a user-level Claude Code feature |
| 🌐 Network (once) | `github.com`, `objects.githubusercontent.com` | HTTPS 443 — release metadata and the ~100 MB `otelcol-contrib` binary |
| 🌐 Network (always) | `<tenant>.live.dynatrace.com` | HTTPS 443 — outbound OTLP |

> The collector keeps running when the tenant is unreachable; data is retried and then dropped, with errors in `~/.dt-ai-obs/logs/collector.log`. A blocked outbound connection does not surface anywhere else.

---

<a id="installation"></a>
## 📦 Installation

Clone or download this folder, then run the installer for your OS. It asks for the endpoint (tenant id is enough), the API token (hidden input), your e-mail and optional squad / cost center. Everything can also be passed as flags or environment variables for silent rollouts.

### macOS / Linux

```bash
./install.sh
```

Silent example:

```bash
DT_INGEST_TOKEN='dt0c01.XXXX' ./install.sh --endpoint abc12345 --email dev@example.com --squad platform --cost-center cc-1234 --non-interactive
```

### Windows (PowerShell)

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1
```

Silent example:

```powershell
$env:DT_INGEST_TOKEN = 'dt0c01.XXXX'
.\install.ps1 -Endpoint abc12345 -Email dev@example.com -Squad platform -CostCenter cc-1234 -NonInteractive
```

### Options (same meaning on both installers)

| `install.sh` | `install.ps1` | Purpose |
|---|---|---|
| `--endpoint` | `-Endpoint` | Tenant id (`abc12345`) or full `https://abc12345.live.dynatrace.com/api/v2/otlp` |
| `--token` / `DT_INGEST_TOKEN` | `-Token` / `DT_INGEST_TOKEN` | API token; prompted (hidden) when omitted |
| `--email` | `-Email` | `user.email` on every signal (defaults to `git config user.email`) |
| `--squad`, `--cost-center`, `--attr K=V` | `-Squad`, `-CostCenter`, `-Attr K=V` | Custom attributes (see below) |
| `--environment` | `-Environment` | `deployment.environment` (default `demo`, same as the VS Code asset) |
| `--collector-port`, `--health-port` | `-CollectorPort`, `-HealthPort` | Defaults 4318 / 13133; the next free port is chosen automatically when busy |
| `--capture-prompts` | `-CapturePrompts` | Send prompt / response content (default off) |
| `--enable-native-otel` | `-EnableNativeOtel` | Add the Claude Code native OTel env block to `~/.claude/settings.json` (see [native telemetry](#native-telemetry)) |
| `--enable-evals` | `-EnableEvals` | Check Node.js ≥ 20 and print how to run [Dynatrace Evals](#evals) on the captured prompts; nothing is executed |
| `--otelcol-version`, `--otelcol-tarball` | `-OtelcolVersion`, `-OtelcolTarball` | Pin the collector release / install from a local tarball (offline) |
| `--quiet-collector` | `-QuietCollector` | No debug exporter (smaller collector log) |
| `--non-interactive` | `-NonInteractive` | Never prompt |

Re-running the installer is safe: it updates the config, keeps existing hook entries, replaces the stored token and restarts the service.

**After installing, restart open Claude Code sessions** (close and reopen the Code tab / the CLI) so the hooks load. Running sessions usually pick the hooks up on their own, but a restart is the reliable path.

---

<a id="verify"></a>
## ✅ Verify it's working

```bash
# macOS / Linux
curl http://127.0.0.1:13133
# Windows
Invoke-WebRequest http://127.0.0.1:13133
# Expected: {"status":"Server available","upSince":"...","uptime":"..."}
```

```bash
python3 hooks/configure-hooks.py status      # hook entries, native OTel env, otel-attrs.json
tail -f ~/.dt-ai-obs/logs/collector.log      # one "Traces"/"Metrics"/"Logs" line per batch
```

Then type a prompt in a Claude Code session and run the health-check query in [docs/dql-examples.md](docs/dql-examples.md#health-check-is-data-arriving) after 1–2 minutes.

---

<a id="custom-attributes"></a>
## 🏷️ Custom attributes

`--squad`, `--cost-center` and `--attr key=value` become resource attributes on **every** signal (hook spans, native metrics and logs) via the collector, and span attributes on hook spans via `~/.claude/otel-attrs.json`. Keys starting with `_` are reserved for the hook's own configuration (`_capture_prompts`, `_collector_port`) and are refused.

| Key | Value | Purpose |
|---|---|---|
| `squad` | `platform` | Filter by team in Dynatrace |
| `cost_center` | `cc-1234` | Chargeback reporting |
| `project` | `migration-v2` | Project-level attribution |

To change them later, re-run the installer with the new flags (the token is prompted again) or edit `~/.claude/otel-attrs.json` and `~/.dt-ai-obs/otel-collector.yaml` and restart the service.

---

<a id="native-telemetry"></a>
## 📡 Claude Code native telemetry (optional)

Claude Code can export its own OpenTelemetry **metrics** (`claude_code.token.usage`, `claude_code.cost.usage`, `claude_code.session.count`, lines of code, commits, PRs, active time) and **log events** (`api_request`, `api_error`, `user_prompt`, `tool_result`, `tool_decision`) when a few environment variables are set. This asset's collector already has `metrics` and `logs` pipelines that forward them to `/api/v2/otlp/v1/metrics` and `/v1/logs`.

Two ways to turn it on:

1. **Per user** — `install.sh --enable-native-otel` merges the env block below into `~/.claude/settings.json` (keys that already exist with other values are left alone). The Desktop app's Code tab reads user settings too, so both clients export.
2. **Fleet-wide (recommended for rollouts)** — copy [managed-settings.example.json](managed-settings.example.json) to the managed settings path, which users cannot override:

| OS | Managed settings path |
|---|---|
| macOS | `/Library/Application Support/ClaudeCode/managed-settings.json` |
| Linux | `/etc/claude-code/managed-settings.json` |
| Windows | `C:\ProgramData\ClaudeCode\managed-settings.json` |

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "http://127.0.0.1:4318",
    "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE": "delta",
    "OTEL_METRIC_EXPORT_INTERVAL": "10000",
    "OTEL_LOGS_EXPORT_INTERVAL": "5000",
    "OTEL_LOG_USER_PROMPTS": "0",
    "OTEL_RESOURCE_ATTRIBUTES": "deployment.environment=demo"
  }
}
```

Why these values: Dynatrace OTLP ingest needs `http/protobuf` and **delta** temporality (the collector's `cumulative_to_delta` processor is a safety net, not a substitute). The endpoint is the local collector, so the API token never has to be in Claude Code's own settings. If the installer had to move the collector to another port, use that port here.

Notes:
- `service.name` of native telemetry is set by Claude Code itself: current builds (2.42+) report `claude-code-desktop` for the Desktop app's Code tab and `claude-code` for the CLI, matching the hook spans; older builds always report `claude-code`. Filter with `in(service.name, {"claude-code", "claude-code-desktop"})` and, for old builds, use the session-id join in [docs/dql-examples.md](docs/dql-examples.md).
- Native events carry the **Anthropic account** e-mail. The collector moves it to `claude.account_email` and stamps the configured `user.email` on every signal, so one field groups all three signals. Install without `--email` to keep Claude Code's own `user.email` instead.
- Native log attributes (`model`, `input_tokens`, `cost_usd`, …) appear as log fields in Grail; `event.name == "api_request"` is the per-call record. The log body (Grail `content`) is the event name prefixed with `claude_code.` (e.g. `claude_code.api_request`), there is no `log.source`, and the records take the `logs:default` OpenPipeline route into the `default_logs` bucket unless your tenant routes them elsewhere.
- **Grail permission check.** Spans and metrics land in `default_spans` / `default_metrics`; native logs land in `default_logs`. If `fetch logs` stays empty while the collector log shows `Logs` batches, first run `fetch dt.system.buckets | filter dt.system.table == "logs"` — the *has access* column of `default_logs` must be `true` for your user (see Troubleshooting).

---

<a id="evals"></a>
## 🧪 Dynatrace Evals (optional)

[dt-evals](https://github.com/dynatrace-oss/dt-evals) (`@dynatrace-oss/dt-evals`, Apache 2.0, alpha) scores production GenAI spans with an LLM judge and writes the verdicts back to the tenant as business events. The spans this asset sends qualify: every Claude Code turn is one `gen_ai.operation.name == "chat"` span with `gen_ai.prompt.0.content` / `gen_ai.completion.0.content` **when prompt capture is on**. [evals/run-evals.sh](evals/run-evals.sh) ([evals/run-evals.ps1](evals/run-evals.ps1) on Windows) wraps the CLI the same way the VS Code asset's *Configurar / Rodar Evals* commands do: same evaluator list, `--since` and `--sample` choices, plus a generated config that matches this asset's span layout and a y/N confirmation before anything that costs money. Nothing runs automatically; the installer only prints the steps (`--enable-evals`).

**What it evaluates.** 15 built-in judge metrics; each produces one verdict per sampled turn: a 0–1 score, a `pass` / `fail` label and a short explanation.

| Group | Evaluators | Reads |
|---|---|---|
| Safety (default set) | `prompt-injection`, `pii-leakage` | prompt; prompt + response |
| Safety (more) | `output-prompt-injection`, `toxicity`, `bias` | response |
| Grounding | `hallucination`, `faithfulness`, `factual-accuracy` | prompt + response |
| Quality | `relevance`, `answer-completeness`, `conciseness`, `fluency`, `summarization-quality`, `context-relevance` | prompt + response |
| Experience | `user-frustration` | prompt |

The default pair answers the two questions a platform team actually has about coding assistants: *is anyone feeding injection payloads to Claude Code (pasted issues, READMEs, tool output), and do prompts or answers carry personal data?* Grounding and quality metrics were designed for RAG and chat products; they run on coding turns too (`--metrics all`) but read the scores with that in mind.

**Prerequisites**

- Prompt capture **ON** (`install.sh --capture-prompts`); the script refuses to run otherwise because the spans carry no text. The hook truncates each attribute to 4 096 characters, so the judge sees the first 4 KB of each prompt and each response.
- Node.js ≥ 20. The CLI runs through `npx`; nothing is installed globally (`DT_EVALS_VERSION` pins a version, `DT_EVALS_BIN` points at an installed binary).
- A **platform token** (`dt0s16…`) with `storage:spans:read`, `storage:buckets:read`, `storage:bizevents:read`, `openpipeline:bizevents:ingest` (`storage:events:write` when the environment URL is `*.apps.dynatrace.com`) and `storage:logs:read` (used by `validate`); `storage:metrics:write` is optional. `run-evals.sh doctor` walks through creating it at `myaccount.dynatrace.com` and stores it as `DT_API_TOKEN` in `evals/.env` (git-ignored, mode 0600 recommended). A classic API token (`dt0c01…`) with equivalent scopes also works. The user behind the token must be able to read the `default_spans` bucket.
- A judge provider key: `ANTHROPIC_API_KEY` (default provider; dt-evals' default model is `claude-sonnet-4-6` unless `--model`), or `OPENAI_API_KEY` with `--provider openai` (`gpt-5-mini`). Azure OpenAI, Gemini, Vertex AI and Bedrock are supported too; `validate` tells you which variable is missing.

**Cost and data caveats**

- Every real run calls the judge once per sampled turn **per evaluator**: `turns in the window × --sample % × evaluators`. Each call sends up to ~8 KB of prompt/response text plus the evaluator prompt to *your* LLM provider account. With the defaults (last hour, 10 %, two evaluators) a busy developer day costs cents; `--metrics all --sample 100 --since 24h` on a fleet does not.
- dt-evals masks e-mail addresses, phone numbers, credit-card and social-security numbers in memory before the judge call. Everything else in the first 4 KB of the turn is sent as-is. That is the one path where captured prompt text leaves the tenant; it is the same text the collector already ships to Dynatrace when capture is on.
- Results are written to the **same tenant** the spans came from. The evaluated text is **not** copied into the result events unless you pass `--store-evaluated-prompt`.
- Start with `preview` (fetches the sampled spans, no judge call, no write) to see the exact turn count, keep the default sample and evaluators for the first run, then scale.

**Commands**

```bash
evals/run-evals.sh plan                                  # generated config + exact command; no network at all
evals/run-evals.sh doctor                                # dtctl check + platform-token walkthrough → evals/.env
export ANTHROPIC_API_KEY=...                             # or OPENAI_API_KEY and --provider openai
evals/run-evals.sh validate                              # config schema, tenant connectivity, judge reachability
evals/run-evals.sh preview --since 6h --sample 25        # what would be judged; reads spans only
evals/run-evals.sh run --since 6h --sample 25 --metrics prompt-injection,pii-leakage,toxicity   # asks y/N, then runs
evals/run-evals.sh runs                                  # local history (~/.dt-eval/runs.json)
```

| Option | Default | Purpose |
|---|---|---|
| `--since 30m\|1h\|6h\|24h` | `1h` | Span lookback window |
| `--sample 10\|25\|50\|100` | `10` | Percent of matching turns judged (random) |
| `--metrics a,b,c` / `all` | `prompt-injection,pii-leakage` | Evaluators; several run in one pass via the generated config |
| `--provider`, `--model` | `anthropic`, dt-evals default | Judge provider / model |
| `--service claude-code\|claude-code-desktop\|both` | `both` | Which client's spans |
| `--env-url` | from `~/.dt-ai-obs/config.env` | Tenant URL (or `DT_ENV_URL`) |
| `--store-evaluated-prompt` | off | Copy prompt/response into the result events |
| `--config PATH` | generated `evals/.dt-eval.yaml` | Use your own dt-evals config (metrics then come from that file unless exactly one `--metrics` is given) |
| `--dry-run`, `--yes` | | Print only / skip the confirmation |

The generated config keeps the scope tight: `operationNames: [chat]`, `filters: service.name in {claude-code, claude-code-desktop}`, `spanFields` mapped to the hook's `gen_ai.prompt.0.content` / `gen_ai.completion.0.content`, `level: agent-span` (one verdict per turn). It contains no secrets, so it is safe to commit a copy as a team baseline.

**Reading the results.** Bizevents with `event.type == "gen_ai.evaluation.result"`, one per turn × evaluator. Useful fields: `gen_ai.evaluation.name`, `gen_ai.evaluation.score.value` (0–1), `gen_ai.evaluation.score.label` (`pass` / `fail`), `gen_ai.evaluation.explanation`, `dt.eval.run_id`, `trace_id` / `span_id` (the Claude Code turn), `gen_ai.request.model` (the **judge** model), `gen_ai.evaluation.input.request_model` (the Claude model that answered). Joining on the trace id with the hook spans adds `user.email`, `squad` and the client:

```dql
fetch bizevents, from:now()-7d
| filter event.type == "gen_ai.evaluation.result"
| summarize turns = countDistinct(trace_id), avg_score = avg(gen_ai.evaluation.score.value),
            fails = countIf(gen_ai.evaluation.score.label == "fail"), by: { gen_ai.evaluation.name }
| sort fails desc
```

```dql
fetch bizevents, from:now()-7d
| filter event.type == "gen_ai.evaluation.result" and gen_ai.evaluation.score.label == "fail"
| join [
    fetch spans, from:now()-7d
    | filter gen_ai.operation.name == "chat" and in(service.name, {"claude-code", "claude-code-desktop"})
    | fieldsAdd trace_id = toString(trace.id)
    | summarize Developer = takeFirst(`user.email`), Squad = takeFirst(squad), Client = takeFirst(service.name), by: { trace_id }
  ], on: { trace_id }, fields: { Developer, Squad, Client }
| summarize fails = count(), by: { Developer, Squad, Client, gen_ai.evaluation.name }
| sort fails desc
```

More variants (per-run summary, latest fails with explanations, drift events) are in [docs/dql-examples.md](docs/dql-examples.md#evaluation-results-dt-evals-optional).

**Dashboard tile suggestion.** Once a run has produced data, add to *Developers AI Usage*: (1) a **single value** tile *PII leakage fails, 7 d* from the first query filtered to `pii-leakage`, color rules green = 0, yellow ≥ 1, red ≥ 5; (2) a **categorical bar chart** *Verdicts per evaluator* (`fails` and `turns - fails` stacked, from the first query); (3) a **table** *Latest fails* (`timestamp`, `gen_ai.evaluation.name`, `Developer`, `Squad`, `gen_ai.evaluation.explanation`, `trace_id`) from the join query with `| sort timestamp desc | limit 20`. The dashboard JSON in this repository is unchanged; adding the tiles is a follow-up after the first real run.

---

<a id="token-counts"></a>
## 🔢 Understanding token counts

A one-line prompt shows up as 20 000+ input tokens. That is correct: every turn sends the system prompt, tool definitions, project context and the conversation history to the model. The hook sums `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` from the session transcript, so `gen_ai.usage.input_tokens` is the real billed payload, not the typed text. The native `api_request` event keeps the four counters separate (`input_tokens`, `cache_read_tokens`, `cache_creation_tokens`, `output_tokens`) and adds Claude Code's own `cost_usd`.

---

<a id="validating"></a>
## 📊 Validating data in Dynatrace

- **AI & LLM Observability app** → Explorer: services `claude-code` and `claude-code-desktop`; Prompts stream shows the `chat <model>` spans (Input/Output only with prompt capture on; System Prompt is always `-`, Claude Code does not expose it to hooks).
- **Dashboard** → upload [Dashboard/Developers AI Usage.json](Dashboard/Developers%20AI%20Usage.json) (unchanged copy of the VS Code asset's dashboard). It groups by `gen_ai.provider.name`, `gen_ai.request.model`, `user.email` and `service.name`, so Desktop and CLI sessions show up side by side. The hook emits `gen_ai.system`; the collector aliases it to `gen_ai.provider.name` so the dashboard's Provider filter matches.
- **Notebooks** → [docs/dql-examples.md](docs/dql-examples.md): usage by developer and client, by model, cost per squad / cost center, tool calls, native `api_request` logs grouped by `user.email` and `model`, daily cost trend, API errors, metrics.

---

<a id="what-gets-installed"></a>
## 🧩 What gets installed

| Path | Content |
|---|---|
| `~/.claude/otel-hook.py` | Hook script ([hooks/otel-hook.py](hooks/otel-hook.py)) — upstream v1.7.0 plus a three-line `service.name` patch ([hooks/otel-hook.patch](hooks/otel-hook.patch)); the verbatim upstream copy is in [hooks/upstream/](hooks/upstream/) |
| `~/.claude/settings.json` | Four `hooks` entries (`PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop`) merged next to existing hooks; optional `env` block for native OTel. A timestamped `.bak-` copy is written before every change |
| `~/.claude/otel-attrs.json` | `os.type`, custom attributes, `_capture_prompts`, `_collector_port` (read by the hook) |
| `~/.dt-ai-obs/bin/otelcol-contrib` | Latest [opentelemetry-collector-releases](https://github.com/open-telemetry/opentelemetry-collector-releases) contrib build (same source and version logic as the VS Code extension), SHA-256 verified |
| `~/.dt-ai-obs/otel-collector.yaml` | Rendered from [collector/otel-collector.yaml](collector/otel-collector.yaml) with endpoint, e-mail, ports and attributes; the token stays `${env:DT_INGEST_TOKEN}` |
| `~/.dt-ai-obs/config.env`, `run-collector.sh` / `.ps1`, `logs/` | Service wrapper: reads the token from the credential store at start-up and `exec`s the collector |
| Token | macOS Keychain item `dt-ai-obs-claude` · Linux Secret Service (`secret-tool`), or `~/.dt-ai-obs/ingest-token` mode 0600 with a warning when no keyring is available · Windows DPAPI-encrypted file `ingest-token.dpapi` (current user) |
| Service | macOS LaunchAgent `com.dynatrace.dt-ai-obs-claude` (`~/Library/LaunchAgents/`, KeepAlive) · Linux `systemd --user` unit `dt-ai-obs-claude.service` · Windows Scheduled Task "Dynatrace AI Observability (Claude) collector" at logon |

Service control:

| | Restart | Stop |
|---|---|---|
| macOS | `launchctl kickstart -k gui/$(id -u)/com.dynatrace.dt-ai-obs-claude` | `launchctl bootout gui/$(id -u)/com.dynatrace.dt-ai-obs-claude` |
| Linux | `systemctl --user restart dt-ai-obs-claude` | `systemctl --user stop dt-ai-obs-claude` |
| Windows | `Start-ScheduledTask -TaskName 'Dynatrace AI Observability (Claude) collector'` | `Stop-ScheduledTask -TaskName '…'` |

---

<a id="troubleshooting"></a>
## 🛠️ Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `curl 127.0.0.1:13133` fails | Service not running | macOS: `launchctl print gui/$(id -u)/com.dynatrace.dt-ai-obs-claude`; Linux: `systemctl --user status dt-ai-obs-claude`; Windows: Task Scheduler → task history. Then read `~/.dt-ai-obs/logs/collector.log` |
| Installer says port 4318 / 13133 busy and picks another | The VS Code extension's collector (or another OTLP receiver) is running | Fine for the hook (it follows `_collector_port`), but update `OTEL_EXPORTER_OTLP_ENDPOINT` for native telemetry; or stop the other collector and re-run the installer |
| `Exporting failed` / `401` / `403` in collector log | Wrong token scopes or `.apps.` host | Re-run the installer with a token that has `openTelemetryTrace.ingest`, `metrics.ingest`, `logs.ingest` and the `.live.` endpoint |
| `400` on `/v1/metrics` | Cumulative temporality from a client | Make sure `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta` reaches Claude Code (managed settings win over user settings) |
| Spans appear, metrics/logs don't | Native OTel not enabled, or the session predates the env change | `python3 hooks/configure-hooks.py status`; restart Claude Code |
| Spans **and** metrics appear, collector log shows `Logs` batches with HTTP 200 and no `partialSuccess`, but `fetch logs` finds nothing (not even by `session.id` or `content`) | Grail **read permission**, not ingest: OTLP logs are stored through the `logs:default` pipeline into the `default_logs` bucket. If the IAM policy of the user running the query lacks `storage:buckets:read` on `default_logs`, the records are stored but invisible to that user. Ingest reports success and nothing in the UI says why. (The record shape is fine — body, `event.name`, timestamp and attribute-count variants were all tested) | 1. `fetch dt.system.buckets \| filter dt.system.table == "logs"` — the *has access* column of `default_logs` must be `true`. 2. `fetch logs, from:now()-2h \| summarize count(), by:{dt.system.bucket, dt.openpipeline.pipelines}` shows where logs you *can* read live. 3. Fix on the tenant: in Account Management → Identity & access → Groups → your group → Permissions, add the built-in policy **Read Logs** (or a custom `ALLOW storage:buckets:read WHERE storage:bucket-name = "default_logs";`) scoped to the environment, with no boundary. If `hasAccess` stays `false` even after that, look for a **`DENY storage:buckets:read WHERE storage:bucket-name = "default_logs"`** statement in a policy bound to one of the user's groups (e.g. a "restricted log access" group): a DENY wins over every ALLOW, so the only fix is to remove the user from that group or drop the statement. **Or** add an OpenPipeline → Logs routing rule `matchesValue(service.name, "claude-code*")` to a pipeline whose storage stage writes to a bucket your users can read (e.g. a dedicated `claude_code_logs` bucket). Re-check with [docs/dql-examples.md](docs/dql-examples.md#native-logs-health-check) |
| No spans at all | Python missing, or sessions started before the hooks were added | `python3 --version`; restart Claude Code; run `echo '{"hook_event_name":"Stop","session_id":"x"}' \| python3 ~/.claude/otel-hook.py; echo $?` (must print 0) |
| `user.email` empty on spans | Installed without `--email` | Re-run with `--email` |
| Prompt text visible in Dynatrace | `--capture-prompts` was used | Re-run without it (the collector redacts again) |
| macOS: Keychain prompt at service start | Item created by another tool | `security delete-generic-password -s dt-ai-obs-claude` and re-run the installer (the `security` CLI must be the item's creator) |
| Linux: `secret-tool` works in the terminal but the service gets an empty token | No D-Bus session for `systemd --user` | Re-run the installer in a desktop session, or accept the 0600 file fallback (uninstall `secret-tool` or run with `TOKEN_BACKEND=file`) |
| Hook spans from a Desktop session show `claude-code` instead of `claude-code-desktop` | Older hook file (VS Code extension rewrote `~/.claude/otel-hook.py`) | Re-run the installer; both tools write the same path, last writer wins. The dashboard works either way |

---

<a id="uninstall"></a>
## 🗑️ Uninstall

```bash
./uninstall.sh            # asks for confirmation; --yes to skip, --keep-hooks / --keep-binary to keep parts
```

```powershell
.\uninstall.ps1           # -Yes, -KeepHooks, -KeepBinary
```

Removes the service, the stored token, the hook entries that reference `otel-hook.py` (other hooks are untouched), the native OTel env keys this asset added, `~/.claude/otel-attrs.json`, `~/.claude/otel-state/` and `~/.dt-ai-obs/`. Restart open Claude Code sessions afterwards.

---

<a id="privacy"></a>
## 🔒 Privacy and security

- **Prompt and response content is not sent by default.** The hook only adds content when `_capture_prompts` is `"true"`, and the collector's `transform/redact_content` processor deletes `gen_ai.prompt*`, `gen_ai.completion*`, `gen_ai.input.messages`, `gen_ai.output.messages`, `gen_ai.system_instructions` (spans and span events) and the native `prompt` log attribute before anything leaves the machine. Metadata (model, tokens, cost, tool names, tool input/output of the hook's tool spans) is kept.
- **Evals are opt-in and never automatic.** [Dynatrace Evals](#evals) only works with capture on, asks before every paid run and is the one path where (masked) prompt text is sent outside the tenant: to the LLM judge provider you configure. Results go back to the same tenant without the evaluated text unless `--store-evaluated-prompt` is given.
- **Token never in plain text on disk**: macOS Keychain, Linux Secret Service or Windows DPAPI; the service wrapper injects it as an environment variable into the collector process only. The Linux file fallback (0600) is used only when no keyring is available and is announced with a warning. The rendered collector config and `config.env` are mode 0600 and contain no token.
- **Loopback only**: OTLP/HTTP, OTLP/gRPC and the health check bind to `127.0.0.1`. Outbound, the collector talks only to your tenant over HTTPS.
- **Verifiable binary**: downloaded from the official OpenTelemetry release page and SHA-256 checked against the published `.sha256` file; a pinned version or a local tarball can be used for air-gapped rollouts.
- **No workspace override**: hooks and attributes live in user-level files; a repository's `.claude/settings.json` cannot change the endpoint or re-enable content capture. Managed settings (admin-controlled) take precedence over user settings for the native OTel env.
- **Stopping telemetry**: stop the service (see table above) or run the uninstaller.

---

<a id="local-test"></a>
## 🧪 Local test (no tenant)

[test/run-local-test.sh](test/run-local-test.sh) installs against a tiny OTLP sink ([test/sink.py](test/sink.py)) on `127.0.0.1:9999` with a dummy token, fires the four hook events for a synthetic Desktop session and a CLI session, optionally runs `claude -p` with native telemetry, checks that no prompt text reached the sink, prints what arrived and (with `--uninstall`) removes everything again. The last run on this Mac is in [test/local-e2e.log](test/local-e2e.log).

```bash
test/run-local-test.sh --native --uninstall            # downloads the collector
test/run-local-test.sh --tarball ./otelcol-contrib_0.163.1_darwin_arm64.tar.gz --uninstall
```

---

<a id="relation"></a>
## 🔗 Relation to the VS Code asset

[dt-ai-observability-vscode](../dt-ai-observability-vscode) embeds the same hook, collector config and dashboard in a VS Code / Cursor extension. This asset reuses them for machines where the Claude Desktop app or the CLI is the client:

| | VS Code asset | This asset |
|---|---|---|
| Hook script | `HOOK_SCRIPT` constant in `src/claudeHooks.ts` (v1.7.0) | Same script, extracted; `service.name` becomes `claude-code-desktop` when `CLAUDE_CODE_ENTRYPOINT=claude-desktop` |
| Collector config | `resources/otel-collector.yaml` | Same receivers / redaction / resource processor; adds a `logs` pipeline, the `gen_ai.provider.name` alias and the `claude.account_email` normalisation; drops the Copilot-specific transform |
| Collector lifecycle | Spawned by the extension while VS Code runs | User service (launchd / systemd / Scheduled Task), independent of any editor |
| Credentials | VS Code SecretStorage | OS credential store + wrapper script |
| Dashboard | `Dashboard/Developers AI Usage.json` | Claude-only variant: GPT / Gemini / Copilot sections removed, Claude filters and defaults |
| Evals | `src/evals.ts`: *Configurar Evals* / *Rodar Evals* commands run `npx @dynatrace-oss/dt-evals` in a terminal (evaluator pick list, since 30m–24h, sample 10–100 %) | `evals/run-evals.sh` / `.ps1`: same CLI, evaluators and choices; config generated for this asset's span layout, prompt-capture check, y/N before paid runs |

Both can coexist on one machine: they write the same `~/.claude/otel-hook.py` and the hook follows whichever collector port is in `otel-attrs.json`. Running two collectors at once is pointless; keep one.

The `connector/` folder in this repository is a separate component (Claude usage connector for the Anthropic admin / usage APIs) with its own README.

---

<a id="license"></a>
## 📄 License

MIT — see [LICENSE](LICENSE)
