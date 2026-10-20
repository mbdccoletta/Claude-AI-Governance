<h1 align="center">Dynatrace AI Observability for Claude</h1>
<p align="center"><em>Claude Desktop app (Code tab) · Claude Code CLI → OpenTelemetry → Dynatrace — no VS Code required</em></p>

<p align="center">
  Per-developer token, cost, model and tool-call observability for Claude Code sessions started from the <strong>Claude Desktop app</strong> or the <strong><code>claude</code> CLI</strong>, landing in Dynatrace through a local OpenTelemetry Collector that runs as a user service. Same hook, same collector, a Claude-only cut of the same dashboard as the <a href="https://github.com/Dynatrace-Internal/field-asset-library/tree/main/integrations/application/dt-ai-observability-vscode">VS Code extension asset</a> — packaged for machines where VS Code is not in the loop.
</p>

---

<a id="three-layers"></a>
## Three layers

| Layer | Source | What it answers | Where |
|---|---|---|---|
| 1 · Hooks | Claude Code hook events → `gen_ai.*` spans | what happened in each conversation and tool call, in real time, prompts optional | this folder (`install.sh`) |
| 2 · Native OTel | Claude Code's own metrics and log events; Cowork's admin-configured OTel events | tokens and cost per API call, sessions, lines of code, commits; Cowork sessions | this folder (`--enable-native-otel`); Cowork: claude.ai admin console, see [Cowork telemetry](#cowork-telemetry) |
| 3 · Official | Anthropic Enterprise Analytics API, Console Admin API, Team CSV | what Anthropic bills per user and product for the whole org, incl. claude.ai chat, Cowork, Design, Claude Code web | [`connector/`](connector/README.md) |

Diagrams: [one-page overview](docs/overview.svg) · [data collection architecture](connector/docs/data-collection-architecture.svg) · [installation process](connector/docs/installation-process.svg).

---

<a id="what-is-measured-where"></a>
## What is measured where

| Where the developer uses Claude | Real time on the machine (layers 1 + 2) | Official from Anthropic (layer 3) |
|---|---|---|
| **Claude Desktop app, Code tab** | ✅ conversations, tool calls, tokens, cost per API call, prompts (opt-in) | ✅ as `claude_code` (Enterprise or Console org) |
| **`claude` CLI in a terminal** | ✅ same (`service.name = claude-code`) | ✅ as `claude_code` |
| **VS Code / Cursor** | ✅ same hook (this installer or the VS Code asset) | ✅ as `claude_code` |
| **Claude Code on the web** (Anthropic cloud) | ⚠️ only native metrics/logs, if the cloud environment sets the `OTEL_*` variables (endpoint = `https://<tenant>.live.dynatrace.com/api/v2/otlp`, token in `OTEL_EXPORTER_OTLP_HEADERS`, `http/protobuf`; no local collector, so no redaction or `user.email` stamping) | ✅ as `claude_code` (remote) |
| **Cowork** (local Desktop sessions and cloud sessions on desktop, web, mobile) | ✅ admin-configured OTel export, Team and Enterprise (**validated 2026-10-20** from claude.ai web and from the Desktop app): logs with `service.name = cowork`, `api_request` with model, tokens, cost and user e-mail, same schema as layer 2; no hooks, so no `gen_ai` spans. See [Cowork telemetry](#cowork-telemetry) | ✅ as `cowork` (Enterprise usage-based); Team CSV: **overage only** |
| **claude.ai chat, Design** (web and Desktop chat) | ❌ no hooks, no OTel. ⚠️ with *Chat and Cowork unified* turned on (beta toggle on Team and Enterprise): conversations that use the cloud workspace (code, files) arrive through the Cowork OTel export; plain Q&A does not (**validated on Team, 2026-10-20**) | ✅ as `chat` / `design` (Enterprise usage-based). Team and seat-based Enterprise: spend CSV with **overage only** (spend beyond the seat allotment; empty when extra usage is off), so this is a partial picture, not total consumption |
| **Personal Pro / Max subscription** | ✅ on an instrumented machine | ❌ Anthropic exposes no API for personal plans |
| **Claude via Bedrock, Vertex, Foundry** | ✅ hooks still work for Claude Code | ❌ use the cloud provider's billing |

Rule of thumb: layers 1 + 2 answer *what is happening right now and how* on the machines you instrumented; layer 3 answers *what Anthropic bills the whole organization*, including products with no hooks and people who installed nothing. [`connector/dql/official-vs-observed-tokens.dql`](connector/dql/official-vs-observed-tokens.dql) joins the two.

### Quick answers

- **Do I need an Anthropic API key?** Only for layer 3. Layers 1 + 2 use a Dynatrace ingest token and Claude's normal login.
- **Is the workflow only for claude.ai?** No. It imports the official usage of the whole org: Claude Code (Desktop, CLI, web) plus chat, Cowork and Design when the org is Enterprise; Claude Code and API usage when it is a Console org.
- **Does it work for Cowork?** Yes, two ways. Real time: the claude.ai admin enables Cowork's own OpenTelemetry export (Team and Enterprise) and points it at the Dynatrace logs endpoint or at a reachable collector; events land as `event.name == "api_request"` with tokens, cost and `user.email`, like layer 2 (see [Cowork telemetry](#cowork-telemetry)). Official: layer 3 as product `cowork` on Enterprise usage-based plans. Cowork has no hooks, so no `gen_ai` spans or tool-call input/output.
- **And claude.ai chat on a Team plan?** No source gives total tokens per user: there is no API (confirmed by Anthropic's docs and by FinOps vendors such as Finout) and the spend CSV only lists **overage** beyond the seat allotment. The gap closes by turning on *Chat and Cowork unified* (beta toggle, already available on Team): chats then run as Cowork sessions and flow through the Cowork OTel export with tokens and cost per user (validated 2026-10-20). Tools that "automate" the Team CSV do it with a headless browser on an Owner's session; this asset does not ship that.
- **Why do I see `<system-reminder>` text in prompts?** You should not any more: the hook strips the blocks the Desktop app injects. Older spans keep them.
- **I use the Desktop app with a personal subscription. What do I get?** Everything from layers 1 + 2 on your machine; nothing from layer 3.
- **How often does layer 3 run?** Once a day, 15:00 UTC, all three workflows; layers 1 + 2 are real time. Running more often brings nothing new: the Console API only returns closed buckets, Enterprise data for day D is complete around 13:30 UTC on D+1 and gets revised for ~7 days (each run re-reads 10 days, newest revision wins by `dedup.key`), and the 60 req/min budget is shared org-wide. To see today earlier, run the workflow by hand (`dtctl exec workflow <id> --wait`); to change the time, edit the workflow's schedule in the tenant or `connector/workflow/build.py`.

<a id="plans-vs-apis"></a>
## Anthropic plans vs APIs: what exists (verified in Anthropic's docs, 2026-10-19; Cowork OTel and Team CSV rows re-checked 2026-10-20)

| Claude plan / organization | Official usage & cost API | What you get | Key | Caveats |
|---|---|---|---|---|
| **Free, Pro, Max** (personal) | ❌ none | nothing; only layers 1 + 2 on an instrumented machine | — | Anthropic exposes no per-user data for personal plans |
| **Team** | ❌ no API; manual **spend CSV** export (claude.ai → Settings → Analytics, Owner or Primary Owner only). ✅ Cowork OTel export (admin) | per user × product × model: requests, prompt/completion tokens, net and gross spend, **overage only** (spend that exceeds the seat allotment; no report at all when extra usage is off; flat seat fees never appear); up to 90 days, refreshed daily with a 1-day lag | — | partial picture of chat; no cache-token split; someone must export and run the importer. Claude Code and Cowork are fully covered by layers 1 + 2 and the Cowork OTel export |
| **Enterprise, seat-based** | ⚠️ Analytics API: engagement endpoints yes, cost/usage endpoints return **usage credits**, not dollars. ✅ Cowork OTel export (admin) | active users, sessions, projects, skills, connectors; tokens per user | Analytics API key (primary owner only) | cost is not in USD; the spend CSV only reflects spend that exceeds the seat allotment; the per-member analytics toggle does not exist on this plan |
| **Enterprise, usage-based** | ✅ Analytics API: `user_cost_report`, `user_usage_report`, `cost_report`, `usage_report` | per user × product (chat, claude_code, cowork, claude_design, …) × model, daily: tokens, requests, USD | Analytics API key (primary owner only, `read:analytics`) | data from 2026-01-01; available ~4 h after usage, revised until ~7 days after month end; 60 req/min per org |
| **Console / Claude Platform org** (API customers) | ✅ Admin API: `usage_report/claude_code` (per user, daily), `usage_report/messages` (org/workspace, 1m–1d buckets), `cost_report` (org, daily) | Claude Code per user with model breakdown and estimated cost; API tokens per workspace / key / model; USD per workspace | Admin API key `sk-ant-admin01-…` (org admin) | individual (non-org) accounts have no Admin API; `messages` only returns closed buckets; Console on AWS has no usage API |
| **Claude via Bedrock / Vertex / Foundry** | ❌ not in any Anthropic API | — | — | use the cloud provider's billing; hooks still capture Claude Code sessions |

Key types are not interchangeable: an Admin API key cannot call the Enterprise Analytics API and an Analytics key cannot call the Admin API. An organization that uses both the Claude Platform and Claude Enterprise needs both keys, and this asset runs one workflow per key (`org_type = console` and `org_type = enterprise`).

<a id="credentials"></a>
## Credentials you need

| You want | Dynatrace | Anthropic | Who creates it |
|---|---|---|---|
| Layers 1 + 2: prompts, tokens, cost and tool calls from Claude Desktop / CLI on instrumented machines | ingest API token (`openTelemetryTrace.ingest`, `metrics.ingest`, `logs.ingest`) | **none** — Claude keeps its normal login | Dynatrace admin; each developer pastes it once into the installer |
| Layer 3, Claude **Enterprise** org (claude.ai chat, Cowork, Design, Claude Code of every user) | dtctl OAuth context + Credential vault entry | **Analytics API key** | the org's primary owner, claude.ai → Organization settings → API |
| Layer 3, Claude **Console / API** org (Claude Code per user, API per workspace) | same | **Admin API key** `sk-ant-admin01-…` | an org admin, platform.claude.com/settings/admin-keys |
| Layer 3, Claude **Team** plan | ingest token with `bizevents.ingest` for the CSV importer | none — manual CSV export (overage only) | a Team **Owner or Primary Owner** (Admins cannot export), claude.ai → Settings → Analytics |
| Cowork real-time events (Team and Enterprise) | ingest token with `logs.ingest` (or a collector the cloud can reach) | none — admin console setting | a claude.ai org admin, Organization settings → Cowork → Monitoring |
| Optional Dynatrace Evals | platform token (`dt-evals doctor`) | one regular API key for the LLM judge (or another provider) | whoever runs the evals |

The Anthropic key is stored once in the tenant's Credential vault and read by the workflow by name; it never reaches developer machines.

### Installation order / who does what

1. **Dynatrace admin, once**: install the AI & LLM Observability app from the Hub, create the ingest token (`openTelemetryTrace.ingest`, `metrics.ingest`, `logs.ingest`), check that the developers' IAM group can read the `default_logs` bucket (see [Troubleshooting](#troubleshooting)), import [Dashboard/Developers AI Usage.json](Dashboard/Developers%20AI%20Usage.json) (Dashboards → Upload).
2. **Each developer**: run `./install.sh` (or `.\install.ps1`) with the token, restart open Claude Code sessions, run the health-check DQL from [docs/dql-examples.md](docs/dql-examples.md#health-check-is-data-arriving).
3. **Optional, admin, once — layer 3**: the Claude org primary owner / admin creates the Analytics or Admin API key → the Dynatrace admin stores it in the Credential vault (name `Anthropic <org_type> usage API key`) → `connector/deploy/deploy.sh --org-type enterprise|console --org-id <label> --run-now --yes` (allowlist, vault, workflow, first run) → import `connector/dashboard/claude-usage-dashboard.upload.json` (Dashboards → Upload, or `dtctl apply -f connector/dashboard/claude-usage-dashboard.json`). Team plan: run the CSV importer instead of the workflow.
4. **Team plans only, Team Owner, daily or weekly**: export the spend CSV from claude.ai and run `connector/csv-import/import-team-csv.sh <file>` (one command: default day = yesterday UTC, preview, confirmation, delivery through dtctl or a `bizevents.ingest` token). The CSV holds **overage spend only**, so treat the result as "extra usage per user", not total consumption. Developers never touch this; see [connector/README.md](connector/README.md#4-team-plan-csv-importer).
5. **Optional, claude.ai admin, once — Cowork**: enable Cowork's OpenTelemetry export in the admin console and point it at Dynatrace (see [Cowork telemetry](#cowork-telemetry)). Nothing to install on developer machines.

### How it works

```
Claude Desktop app (Code tab)  ─┐  hooks: PreToolUse / PostToolUse /
claude CLI                     ─┤  UserPromptSubmit / Stop  →  ~/.claude/otel-hook.py
                                │        │  OTLP/JSON spans (gen_ai.*)
                                │        ▼
                                │  otelcol-contrib  ·  127.0.0.1:4318  (user service, ~50–80 MB RAM, ~200 MB disk)
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

> ¹ Off by default. When on, the hook drops the `<system-reminder>` blocks the Claude Desktop app injects into the user turn and unwraps `<pasted_content>`, so `gen_ai.prompt.0.content` holds only what the developer typed or pasted. Turn it on with `install.sh --capture-prompts`: it sets `_capture_prompts: "true"` in `~/.claude/otel-attrs.json` **and** renders the collector config without the `transform/redact_content` processor. Editing the JSON by hand is not enough — the collector keeps redacting until it is re-rendered by the installer. Tool input/output is sent regardless (see [Privacy](#privacy)).
> ² Off by default. Claude Code only includes prompt text in the `user_prompt` log event when `OTEL_LOG_USER_PROMPTS=1`; the collector deletes it anyway unless prompt capture is on.

**Who is who** — `service.name`:

| Session started from | Hook spans | Native metrics / logs |
|---|---|---|
| Claude Desktop app, Code tab (`CLAUDE_CODE_ENTRYPOINT=claude-desktop`) | `claude-code-desktop` | `claude-code-desktop` (Claude Code ≥ 2.42; older builds: `claude-code` ³) |
| `claude` CLI in a terminal | `claude-code` | `claude-code` |

> ³ Verified with Desktop 2.42304. Older builds' native telemetry carries no entrypoint attribute (their `terminal.type` is `non-interactive` for the Desktop app and for scripted `claude -p` runs alike), so they report `claude-code` for both clients. [docs/dql-examples.md](docs/dql-examples.md) shows how to join native logs to the hook spans on the session id to label them.

---

## 📑 Table of contents

| | |
|---|---|
| 🧱 [Three layers](#three-layers) · [What is measured where](#what-is-measured-where) · ✅ [Recommended setup](#recommended-setup) | 🗝️ [Anthropic plans vs APIs](#plans-vs-apis) · [Credentials you need](#credentials) |
| 🔧 [Prerequisites](#prerequisites) | 📦 [Installation](#installation) |
| ✅ [Verify it's working](#verify) | 🏷️ [Custom attributes](#custom-attributes) |
| 📡 [Claude Code native telemetry (optional)](#native-telemetry) · 🤝 [Cowork telemetry](#cowork-telemetry) | 🔢 [Understanding token counts](#token-counts) |
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
| `--otelcol-version`, `--otelcol-tarball` | `-OtelcolVersion`, `-OtelcolTarball` | Collector release (default pinned to 0.163.1, the tested one; `latest` fetches the newest) / install from a local tarball (offline) |
| `--verbose-collector` | `-VerboseCollector` | Enable the collector debug exporter: every record (prompts included when capture is on) is written to `~/.dt-ai-obs/logs/collector.log`. Off by default since 1.0.1 (`--quiet-collector` is still accepted) |
| `--non-interactive` | `-NonInteractive` | Never prompt |

Re-running the installer is safe: it updates the config, keeps existing hook entries, replaces the stored token and restarts the service.

**After installing, restart open Claude Code sessions** (close and reopen the Code tab / the CLI) so the hooks load: hooks are read at session start.

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
tail -f ~/.dt-ai-obs/logs/collector.log      # export errors; one "Traces"/"Metrics"/"Logs" line per batch only with --verbose-collector
```

Then type a prompt in a Claude Code session and run the health-check query in [docs/dql-examples.md](docs/dql-examples.md#health-check-is-data-arriving) after 1–2 minutes.

---

<a id="custom-attributes"></a>
## 🏷️ Custom attributes

`--squad`, `--cost-center` and `--attr key=value` become resource attributes on **every** signal (hook spans, native metrics and logs) via the collector, span attributes on hook spans via `~/.claude/otel-attrs.json`, and (since 1.0.1) datapoint attributes, i.e. dimensions, on the native `claude_code.*` metrics. Keys starting with `_` are reserved for the hook's own configuration (`_capture_prompts`, `_collector_port`) and are refused.

| Key | Value | Purpose |
|---|---|---|
| `squad` | `platform` | Filter by team in Dynatrace; `--squad` also writes the same value as `user.team`, the key the shared *Developers AI Usage* dashboard (this asset and the VS Code asset) groups by in "Custo por time" / "Uso por time" |
| `cost_center` | `cc-1234` | Chargeback reporting |
| `project` | `migration-v2` | Project-level attribution |

To change them later, re-run the installer with the new flags (the token is prompted again) or edit `~/.claude/otel-attrs.json` and `~/.dt-ai-obs/otel-collector.yaml` and restart the service.

---

<a id="native-telemetry"></a>
## 📡 Claude Code native telemetry (optional)

Claude Code can export its own OpenTelemetry **metrics** (`claude_code.token.usage`, `claude_code.cost.usage`, `claude_code.session.count`, lines of code, commits, PRs, active time) and **log events** (`api_request`, `api_error`, `user_prompt`, `tool_result`, `tool_decision`) when a few environment variables are set. This asset's collector already has `metrics` and `logs` pipelines that forward them to `/api/v2/otlp/v1/metrics` and `/v1/logs`.

Two ways to turn it on:

1. **Per user** — `install.sh --enable-native-otel` merges the first eight keys of the block below into `~/.claude/settings.json` (keys that already exist with other values are left alone; `OTEL_LOG_USER_PROMPTS` defaults to off and `deployment.environment` is already stamped by the collector, so those two are only needed in managed settings). The Desktop app's Code tab reads user settings too, so both clients export.
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
- Native events carry the **Anthropic account** e-mail. The collector moves it to `claude.account_email` and stamps the configured `user.email` on every signal, so one field groups the hook spans and the native log events. Install without `--email` to keep Claude Code's own `user.email` instead.
- **Developer dimensions on the native metrics (1.0.1+).** Claude Code's datapoints carry only its own dimensions (`type`, `model`, `user.id`, `session.id`, …) and Dynatrace does not turn OTLP *resource* attributes into dimensions unless they are allow-listed in the tenant, so with 1.0.0 `timeseries … by: {user.email}` on `claude_code.*` returned `null`. Since 1.0.1 the collector copies `user.email`, `deployment.environment` and every custom attribute (`squad`, `cost_center`, `--attr …`) onto each datapoint (`transform/metric_dimensions`), so `timeseries sum(claude_code.token.usage), by: {user.email}` works out of the box. The hook spans and the `api_request` log events carry the same fields.
- Native log attributes (`model`, `input_tokens`, `cost_usd`, …) appear as log fields in Grail; `event.name == "api_request"` is the per-call record. The log body (Grail `content`) is the event name prefixed with `claude_code.` (e.g. `claude_code.api_request`), there is no `log.source`, and the records take the `logs:default` OpenPipeline route into the `default_logs` bucket unless your tenant routes them elsewhere.
- **Grail permission check.** Spans and metrics land in `default_spans` / `default_metrics`; native logs land in `default_logs`. If `fetch logs` stays empty while the collector log shows `Logs` batches, first run `fetch dt.system.buckets | filter dt.system.table == "logs"` — the *has access* column of `default_logs` must be `true` for your user (see Troubleshooting).

---

<a id="evals"></a>
<a id="recommended-setup"></a>
## ✅ Recommended setup, coverage status and sources of truth (2026-10-20)

**Setup that covers every scenario without double counting**

| Where | What to turn on |
|---|---|
| claude.ai org (Team or Enterprise) | Cowork **Monitoring** pointed straight at Dynatrace ([Cowork telemetry](#cowork-telemetry)); **Chat and Cowork unified** on (Capabilities → Chat) |
| Each developer machine | this asset with native OTel (`./install.sh --enable-native-otel`). VS Code / Cursor users install **either** the VS Code extension **or** this asset, never both |
| Alternative for native OTel, no install (Team / Enterprise) | claude.ai → Organization settings → Claude Code → **Managed settings**: put the `CLAUDE_CODE_ENABLE_TELEMETRY`, `OTEL_*_EXPORTER`, `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`, `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_EXPORTER_OTLP_HEADERS` keys in its `env` block. It reaches the CLI, VS Code / JetBrains, the Desktop Code tab and Claude Code on the web, and a repository cannot switch it off (user-scope settings written by the installer can be overridden per repo). Each interactive CLI user approves the endpoint once; Code-tab and IDE sessions apply it without a dialog. The header token is visible to users' clients, so use a dedicated ingest-only token. Hook spans (conversation detail, prompts) still need the installer. **Documented, not yet validated here.** Source: [server-managed settings](https://code.claude.com/docs/en/server-managed-settings) |
| Dynatrace | both dashboards; on Enterprise usage-based, the layer 3 Analytics API workflow. On **Team**, the spend CSV is **optional, for monthly billing reconciliation only**: it is manual (Owner export), refreshed with a 1-day lag, lists only overage, and a new org shows nothing until the next day — it is not a monitoring source |

**One source of truth per question**

| Question | Source | Why it does not double count |
|---|---|---|
| Tokens and cost per user, real time | logs `event.name == "api_request"` for `service.name` in `claude-code`, `claude-code-desktop`, `cowork` | one event per model call, same schema for Claude Code, Cowork and unified chat |
| What happened in a conversation (tools, duration, prompts) | hook spans (`chat …`, `claude.tool.*`) | use for behaviour only — never add span tokens to log tokens, they are the same tokens |
| What was actually billed | layer 3 (Team CSV / Enterprise Analytics API) | official and daily — compare with real time, never add |

Rules: hook spans and native OTel measure the same Claude Code usage (totals come from the logs); one installation per machine (the extension and this asset write the same hook, last writer wins); unified chat already arrives as `cowork`; the Team CSV is only the billed overage, a slice of the same usage; Cowork runs in an isolated VM and never goes through the hook.

**Coverage status**

| Status | Surfaces |
|---|---|
| ✅ Validated end to end on a tenant | Claude Code in the Desktop Code tab and the CLI (hook spans + native `api_request`); Claude Code in VS Code / Cursor (VS Code asset); Cowork from claude.ai web and from the Desktop app; unified chat that uses the cloud workspace (code, files); both dashboards with real data |
| 📄 Documented by Anthropic, not yet validated here | Team spend CSV with a real export; Enterprise Analytics API with real data (mock-tested); Office Agents OTel (documented Enterprise-only, traces from the browser, needs a CORS-enabled collector); Claude Desktop in third-party (3P) mode; Claude Code on the web and Claude in Slack (see below) |
| ❌ No telemetry exists | plain chat Q&A (web and Desktop, any mode) — only the Team CSV overage or the Enterprise Analytics API (daily); Claude Design and Claude in Chrome — only Analytics API or CSV |

Caveats: OTel cost is an estimate at API list price, not the invoice; on Team and seat-based Enterprise, usage inside the seat allotment has no per-token cost (it is the flat seat fee); prompts and responses are off by default everywhere.

**Options to also capture plain chat (documented, not validated)**

- **Claude Enterprise, usage-based** — the Analytics API returns chat tokens and cost per user per day; this asset's layer 3 already imports it.
- **Claude Desktop in third-party (3P) mode** — the Desktop routes all inference to a provider you choose (Claude API, Bedrock, Vertex, Foundry or a gateway) and, with `otlpEndpoint` (+ `otlpHeadersHelper` for the token), exports logs and metrics for **Chat, Cowork and Code** sessions with token counts and `enduser.id`. Trade-offs: billing moves from seats to per token, claude.ai web is not covered (Desktop only), conversations stay on the device, features ship later. Single-machine test: Help → Troubleshooting → Enable Developer Mode → Developer → Configure Third-Party Inference. Sources: [3P overview](https://claude.com/docs/third-party/claude-desktop/overview), [3P telemetry](https://claude.com/docs/third-party/claude-desktop/telemetry).
- **Claude apps gateway** — a self-hosted gateway in front of Claude Code and the 3P Desktop that meters spend per developer, enforces limits and relays OTel with `user.email` and IdP groups (`telemetry.forward_to`). Source: [gateway configuration](https://code.claude.com/docs/en/claude-apps-gateway-config).

**Other surfaces (documented, not validated)**

- **Claude Code on the web** — set the `CLAUDE_CODE_ENABLE_TELEMETRY` / `OTEL_*` keys in the org's **server-managed settings** (central, no per-machine install; put the collector credential there, not in environment variables).
- **Claude in Slack (Claude Tag)** — does not receive server-managed settings; set the variables on the org's shared cloud environment and allow the collector host in its network allowlist; sessions carry `app.entrypoint = claude-in-slack` with `OTEL_METRICS_INCLUDE_ENTRYPOINT=true`. Source: [Monitoring](https://code.claude.com/docs/en/monitoring-usage).

---

<a id="cowork-telemetry"></a>
## 🤝 Cowork telemetry (Team and Enterprise, no install on the machine)

Cowork sessions (local ones in the Desktop app and cloud ones started from desktop, web or mobile) do not run the Claude Code hook, but Anthropic exports their events over OpenTelemetry when a claude.ai admin configures an OTLP endpoint. Nothing is exported until that is done. Source: [Monitor Claude Cowork activity with OpenTelemetry](https://support.claude.com/en/articles/14477985-monitor-claude-cowork-activity-with-opentelemetry).

**Validated on 2026-10-20** with a Claude Team org pointed at a Dynatrace SaaS tenant: sessions from claude.ai web (unified chat and Cowork) and Cowork tasks started in the Claude Desktop app with a local folder arrived as log records with tokens, cost, model and user e-mail. Step-by-step runbook (pt-BR) with the DQL files in [`docs/dql/`](docs/dql/): [docs/cowork-validation.md](docs/cowork-validation.md).

| Item | Value |
|---|---|
| Plans | Team and Enterprise (validated on Team) |
| Where | claude.ai → Organization settings → Data and privacy → **Monitoring** → *Cowork, Cowork in the cloud, and unified chat and Cowork* (Owner / admin). Direct link: `claude.ai/admin-settings/data-privacy-controls#cowork-monitoring` |
| OTLP endpoint | `https://<env>.live.dynatrace.com/api/v2/otlp` — the **base** URL, without `/v1/logs` (the exporter appends it; validated). Use `.live.`, not `.apps.`. The host is added to Cowork's network egress allowlist automatically |
| OTLP protocol | **http/protobuf** (the Dynatrace OTLP endpoint rejects JSON) |
| OTLP headers | `Authorization=Api-Token dt0c01.<public>.<secret>` — `key=value` form as the field's placeholder shows; classic token with **Ingest logs** (`logs.ingest`). Paste the token right after `Api-Token ` and check it starts with a single `dt0c01.` (a doubled prefix fails with 401 and nothing arrives, with no error shown in the console) |
| Resource attributes | optional, e.g. `deployment.environment=validation,claude.org=<org>`; they arrive as log attributes and help filter |
| Signal | **logs only** (`/api/v2/otlp/v1/logs`); no spans, no metrics |
| `service.name` | `cowork` (scope `com.anthropic.claude_code.events`, `service.version` = Claude Agent SDK version) |
| Where the session ran | `cowork.surface`. `remote` = the agent ran on Anthropic's cloud. On a Team org this includes Cowork tasks started **from the Desktop app with a local folder**: the Desktop creates a cloud session and shares the folder with it (validated 2026-10-20, Desktop 2.42304.2). A task running entirely in the Desktop's local VM was not observed in that setup |
| Events seen | `api_request`, `user_prompt`, `assistant_response`, `tool_decision`, `tool_result`, `mcp_server_connection`, `plugin_loaded`, `hook_*`, `managed_settings_resolved`, `permission_mode_changed` — same names and fields as Claude Code's native telemetry (layer 2) |
| `api_request` fields | `model`, `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_creation_tokens` (+ `_5m` / `_1h`), `cost_usd`, `cost_usd_micros`, `duration_ms`, `ttft_ms`, `effort`, `speed`, `query_source`, `session.id`, `prompt.id`, `request_id` |
| Identity | `user.email`, `user.account_uuid`, `user.id`, `organization.id` always present |
| Content | `prompt` arrives as `<REDACTED>` (only `prompt_length`) by default; turning content on needs the `otlpContentCapture` device policy (set it to `[]` to keep it off on older Desktop builds) |
| Minimum Desktop | 1.1.4173 for local sessions, 1.22209.3 for cloud sessions |

```dql
fetch logs, from:now()-24h
| filter service.name == "cowork" and event.name == "api_request"
| summarize requests = count(),
            input = sum(toLong(input_tokens)), output = sum(toLong(output_tokens)),
            cache_read = sum(toLong(cache_read_tokens)), cache_creation = sum(toLong(cache_creation_tokens)),
            cost_usd = sum(toDouble(cost_usd)),
  by: {user.email, model, cowork.surface}
| sort cost_usd desc
```

**What gets exported depends on the org's chat mode** (validated 2026-10-20 on a Team org):

| Org setting *Chat and Cowork unified* | Cowork (web and Desktop) | Chat (web and Desktop) |
|---|---|---|
| **Off** — classic Chat \| Cowork selector | ✅ exported (validated from the Desktop app with a local folder) | ❌ not exported |
| **On** (beta) — one Home, no separate Cowork | ✅ exported (validated from claude.ai web) | ⚠️ **only conversations that move to the cloud workspace** (code execution, attached files or folders, longer tasks) are exported, as `service.name = cowork` — validated from claude.ai web and the Desktop app. A plain Q&A with no workspace stays a classic chat and is **not** exported, and neither is the classic chat's own file creation ("Created a file") when Claude does not move the conversation to the workspace — Claude decides, not the user (tested 2026-10-20) |

**Recommendation:** to see as much as possible (Claude Code + Cowork + chat that uses the workspace) per developer, turn **Chat and Cowork unified** on (Organization settings → Capabilities → Chat). Before doing it at a customer, flag that it is beta, that users lose the Chat/Cowork selector and their conversations run on Anthropic's cloud, and that their security team may need to review code execution and file access in the cloud (Anthropic links a security guide from the toggle). Leave *Early access: Run Cowork in the cloud* as it is; it is a separate setting and was off during the validation.

Screens (tenant host and org name masked):

| Organization settings → Data and privacy → Monitoring, empty | Configured |
|---|---|
| ![Monitoring form, empty](docs/images/cowork/monitoring-empty.png) | ![Monitoring form, configured](docs/images/cowork/monitoring-configured.png) |

| Desktop, unified **on** (Home, no Cowork tab) | Desktop, unified **off** (Chat \| Cowork selector) |
|---|---|
| ![Desktop unified Home](docs/images/cowork/desktop-unified-home.png) | ![Desktop classic Chat and Cowork](docs/images/cowork/desktop-classic-chat-cowork.png) |

Same screens in the Portuguese UI — Monitoring under **Dados e privacidade** and the unified toggle under **Recursos → Chat**:

![Admin Monitoring, pt-BR UI](docs/images/cowork/admin-monitoring-pt.png)

![Chat and Cowork unified toggle, pt-BR UI](docs/images/cowork/admin-capabilities-unified-chat-pt.png)

Office Agents block with *Copy settings from Cowork*: ![Office Agents](docs/images/cowork/office-agents-copy-settings.png)

**In the dashboard:** the *Cowork e chat unificado* section of *Developers AI Usage* fills from these events as soon as they land (validated on the lab tenant: cost, requests, active developers, tokens, tokens by model, top developers with `cowork.surface`).

Notes:

- **Dashboards.** *Developers AI Usage* has a **Cowork e chat unificado** section (cost, requests, active developers, tokens, tokens over time by model, top developers with `cowork.surface`) read from these logs; its other tiles read `gen_ai` spans, which Cowork does not send, and its Provider/Modelo variables do not apply to the Cowork section. The layer 2 log queries in [docs/dql-examples.md](docs/dql-examples.md) accept `cowork` next to `claude-code` / `claude-code-desktop`, and the layer 3 coverage tiles compare `claude_code` and `cowork` per product.
- **Unified chat counts as Cowork.** With *Chat and Cowork unified* (beta toggle, available on Team and Enterprise under Organization settings → Capabilities → Chat) conversations that move to the cloud workspace (code, files, longer tasks) run as Cowork sessions and are exported here; plain Q&A stays a classic chat and is not exported, so the chat gap narrows but does not close. Validated: a conversation that used the workspace in claude.ai web arrived as `service.name = cowork`, `cowork.surface = remote`. Note: Anthropic's help center says Team organizations keep classic chat and Cowork; the unified beta toggle was nevertheless present and working on a Team org on 2026-10-20, so availability may vary by rollout — check the org's Capabilities page.
- **Delay.** Cloud sessions took several minutes to show up in Grail on the first run; allow up to ~20 minutes before troubleshooting.
- **Token placement.** Pointing the admin console straight at Dynatrace puts an ingest token in the claude.ai admin console (encrypted at rest by Anthropic). Use a dedicated `logs.ingest`-only token so it can be revoked on its own. For redaction or fan-out, use a collector with a public HTTPS endpoint; the local `127.0.0.1:4318` collector of this asset cannot receive cloud sessions.
- **Office Agents** (Excel, PowerPoint, Word, Outlook add-ins) have their own Monitoring block on the same page with a *Copy settings from Cowork* button, but Anthropic documents this export as **Enterprise-only** (and direct cloud-provider deployments), it sends **traces** (one `agent.stream` span per model call with tokens, model and `user.email`, **no cost**) **from the user's browser**, so the collector must answer CORS for the add-in origin — a direct Dynatrace OTLP endpoint will most likely be blocked by the browser. Plan a collector you run in front of Dynatrace. Not validated here. Source: [Office Agents OpenTelemetry](https://claude.com/docs/office-agents/opentelemetry).
- Cowork also appears in layer 3 as product `cowork` (Enterprise usage-based) and, as overage, in the Team spend CSV.

---

## 🧪 Dynatrace Evals (optional)

[dt-evals](https://github.com/dynatrace-oss/dt-evals) (`@dynatrace-oss/dt-evals`, Apache 2.0, alpha) scores production GenAI spans with an LLM judge and writes the verdicts back to the tenant as business events. The spans this asset sends qualify: every Claude Code turn is one `gen_ai.operation.name == "chat"` span with `gen_ai.prompt.0.content` / `gen_ai.completion.0.content` **when prompt capture is on**. [evals/run-evals.sh](evals/run-evals.sh) ([evals/run-evals.ps1](evals/run-evals.ps1) on Windows — same options, not yet exercised end to end) wraps the CLI the same way the VS Code asset's *Configurar / Rodar Evals* commands do: same evaluator list, `--since` and `--sample` choices, plus a generated config that matches this asset's span layout and a y/N confirmation before anything that costs money. Nothing runs automatically; the installer only prints the steps (`--enable-evals`).

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
| `--concurrency N` | dt-evals default (5) | Parallel judge calls |
| `--allow-no-capture` | off | Run even when prompt capture is off — nothing to score, for testing the pipeline |
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

**Cost and tokens in the dashboard (since 2026-10-20).** The Claude Code cost and token tiles of *Developers AI Usage* (overview cost, cost by model and by team, tokens over time, top developers, prompt caching, per-model detail) read Claude Code's native `api_request` log events: tokens are `input_tokens + cache_read_tokens + cache_creation_tokens + output_tokens` and cost is the `cost_usd` Claude Code reports (list-price estimate; set the managed setting `modelPricing` to use contracted rates). They need native OTel on (`--enable-native-otel`, or the org's server-managed settings). Hook spans still feed requests, sessions, active developers, latency and errors. The earlier per-family price formula over span tokens was dropped: span tokens were double counted (see CHANGELOG) and list prices drift.

---

<a id="validating"></a>
## 📊 Validating data in Dynatrace

- **AI & LLM Observability app** → Explorer: services `claude-code` and `claude-code-desktop`; Prompts stream shows the `chat <model>` spans (Input/Output only with prompt capture on; System Prompt is always `-`, Claude Code does not expose it to hooks).
- **Dashboard** → upload [Dashboard/Developers AI Usage.json](Dashboard/Developers%20AI%20Usage.json) (the Claude-only variant of the VS Code asset's dashboard: same tiles, GPT/Gemini/Copilot sections removed, `Provider`/`Modelo` defaults set to Anthropic/Claude). If the tiles stay empty although `fetch spans` shows data, open the `Modelo` filter and tick your models — the default list is a snapshot of model ids (see Troubleshooting). It groups by `gen_ai.provider.name`, `gen_ai.request.model`, `user.email` and `service.name`, so Desktop and CLI sessions show up side by side. The hook emits `gen_ai.system`; the collector aliases it to `gen_ai.provider.name` so the dashboard's Provider filter matches.
- **Notebooks** → [docs/dql-examples.md](docs/dql-examples.md): usage by developer and client, by model, cost per squad / cost center, tool calls, native `api_request` logs grouped by `user.email` and `model`, daily cost trend, API errors, metrics.

---

<a id="what-gets-installed"></a>
## 🧩 What gets installed

| Path | Content |
|---|---|
| `~/.claude/otel-hook.py` | Hook script ([hooks/otel-hook.py](hooks/otel-hook.py)) — upstream v1.7.0 plus two small patches ([hooks/otel-hook.patch](hooks/otel-hook.patch)): `service.name = claude-code-desktop` when `CLAUDE_CODE_ENTRYPOINT=claude-desktop`, and prompt cleaning (drops `<system-reminder>` blocks, unwraps `<pasted_content>`) before the prompt is stored; the verbatim upstream copy is in [hooks/upstream/](hooks/upstream/) |
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
| `401` in `collector.log` right after a fresh install, although the token is new and has the right scopes | The hidden `read -s` prompt received the token **twice** or with whitespace (some terminals / clipboard managers paste on Cmd-V *and* on Enter). Since 1.0.1 the installer rejects anything that is not `dt0c01.<24>.<64>` and sends an empty pre-flight POST to `/v1/traces` (401/403 abort the install), so this applies to installs made with 1.0.0 | Check the stored length — a `dt0c01.` token is 96 characters (`dt0c01.` + 24 + `.` + 64): macOS `security find-generic-password -s dt-ai-obs-claude -w \| tr -d '\n' \| wc -c`; Linux `secret-tool lookup service dt-ai-obs-claude key ingest-token \| wc -c` or `wc -c < ~/.dt-ai-obs/ingest-token`. Then re-run without typing it: `DT_INGEST_TOKEN='dt0c01.…' ./install.sh --endpoint … --email … --non-interactive` |
| Dashboard tiles empty but `fetch spans` shows data | The `Modelo` variable of *Developers AI Usage* has a fixed default list of model ids and every tile filters `in(gen_ai.request.model, $Modelo)` (span tiles) or `in(model, $Modelo)` (native-log tiles; the variable lists models from both sources); a tenant whose spans report another model (e.g. `claude-sonnet-4-5`) sees nothing until the model is ticked | Open the `Modelo` filter and select your models (the variable query lists only models seen in the dashboard timeframe). Same for `Provider` if `gen_ai.system` ever changes |
| `400` on `/v1/metrics` | Cumulative temporality from a client | Make sure `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta` reaches Claude Code (managed settings win over user settings) |
| Spans appear, metrics/logs don't | Native OTel not enabled, or the session predates the env change | `python3 hooks/configure-hooks.py status`; restart Claude Code |
| Spans **and** metrics appear, collector log shows `Logs` batches with HTTP 200 and no `partialSuccess`, but `fetch logs` finds nothing (not even by `session.id` or `content`) | Grail **read permission**, not ingest: OTLP logs are stored through the `logs:default` pipeline into the `default_logs` bucket. If the IAM policy of the user running the query lacks `storage:buckets:read` on `default_logs`, the records are stored but invisible to that user. Ingest reports success and nothing in the UI says why. (The record shape is fine — body, `event.name`, timestamp and attribute-count variants were all tested) | 1. `fetch dt.system.buckets \| filter dt.system.table == "logs"` — the *has access* column of `default_logs` must be `true`. 2. `fetch logs, from:now()-2h \| summarize count(), by:{dt.system.bucket, dt.openpipeline.pipelines}` shows where logs you *can* read live. 3. Fix on the tenant: in Account Management → Identity & access → Groups → your group → Permissions, add the built-in policy **Read Logs** (or a custom `ALLOW storage:buckets:read WHERE storage:bucket-name = "default_logs";`) scoped to the environment, with no boundary. If `hasAccess` stays `false` even after that, look for a **`DENY storage:buckets:read WHERE storage:bucket-name = "default_logs"`** statement in a policy bound to one of the user's groups (e.g. a "restricted log access" group): a DENY wins over every ALLOW, so the only fix is to remove the user from that group or drop the statement. **Or** add an OpenPipeline → Logs routing rule `matchesValue(service.name, "claude-code*")` to a pipeline whose storage stage writes to a bucket your users can read (e.g. a dedicated `claude_code_logs` bucket). Re-check with [docs/dql-examples.md](docs/dql-examples.md#native-logs-health-check) |
| No spans at all | Python missing, or sessions started before the hooks were added | `python3 --version`; restart Claude Code; run `echo '{"hook_event_name":"Stop","session_id":"x"}' \| python3 ~/.claude/otel-hook.py; echo $?` (must print 0) |
| `user.email` empty on spans | Installed without `--email` | Re-run with `--email` |
| Prompt text visible in Dynatrace | `--capture-prompts` was used | Re-run without it (the collector redacts again) |
| macOS: Keychain prompt at service start | Item created by another tool | `security delete-generic-password -s dt-ai-obs-claude` and re-run the installer (the `security` CLI must be the item's creator) |
| Linux: `secret-tool` works in the terminal but the service gets an empty token | No D-Bus session for `systemd --user` | Re-run the installer in a desktop session, or switch to the file fallback by hand. The installer has no flag for this: it picks the backend automatically (macOS Keychain → `secret-tool` → `~/.dt-ai-obs/ingest-token` mode 0600 when no keyring answers). To force the file: `umask 077; printf '%s' "$TOKEN" > ~/.dt-ai-obs/ingest-token; chmod 0600 ~/.dt-ai-obs/ingest-token`, set `TOKEN_BACKEND=file` in `~/.dt-ai-obs/config.env`, then `systemctl --user restart dt-ai-obs-claude` |
| Hook spans from a Desktop session show `claude-code` instead of `claude-code-desktop` | Older hook file (VS Code extension rewrote `~/.claude/otel-hook.py`) | Re-run the installer; both tools write the same path, last writer wins. The dashboard works either way |
| Layer 3 workflow succeeds but `events: 0` for today | `usage_report/messages` returns closed buckets only (today = 1 h buckets, visible after the hour closes); `usage_report/claude_code` is a daily aggregate that lags ~1 h | Wait for the next run or `dtctl exec workflow <id>` later; see [connector/README.md § Freshness and caveats](connector/README.md#freshness-and-caveats) |
| Layer 3 task log shows `HTTP 401` from `api.anthropic.com` | Wrong key type for the org (Admin key on an Enterprise org or vice-versa) or key revoked | Create the key the org type needs and update the vault entry; see [connector/README.md § Which organization type needs which key](connector/README.md#which-organization-type-needs-which-key) |

---

<a id="uninstall"></a>
## 🗑️ Uninstall

Run the uninstaller from the asset folder (the same one you installed from):

```bash
./uninstall.sh            # asks for confirmation; --yes to skip, --keep-hooks / --keep-binary to keep parts
```

```powershell
.\uninstall.ps1           # -Yes, -KeepHooks, -KeepBinary
```

Everything the installer created is removed; nothing else in `~/.claude/settings.json` is touched:

| What | Where | macOS | Linux | Windows |
|---|---|---|---|---|
| Collector service (stopped first) | user service | LaunchAgent `com.dynatrace.dt-ai-obs-claude` | `systemctl --user` unit `dt-ai-obs-claude.service` | Scheduled Task *Dynatrace AI Observability (Claude) collector* |
| Ingest token | OS credential store | Keychain item | `secret-tool` entry (or the 0600 file) | DPAPI-encrypted file |
| Claude Code hook entries | `~/.claude/settings.json` → `hooks` | the four entries (`PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop`) that reference `otel-hook.py`; other hooks stay | same | same |
| Native OTel env block (if `--enable-native-otel` was used) | `~/.claude/settings.json` → `env` | the `CLAUDE_CODE_ENABLE_TELEMETRY` / `OTEL_*` keys this asset added | same | same |
| Hook script, attributes, state | `~/.claude/` | `otel-hook.py`, `otel-attrs.json`, `otel-state/` | same | same |
| Collector binary, config, logs | `~/.dt-ai-obs/` | whole folder | same | same |

Options:

| Flag (bash / PowerShell) | Use it when |
|---|---|
| `--yes` / `-Yes` | scripted removal, no confirmation prompt |
| `--keep-binary` / `-KeepBinary` | you plan to reinstall: keeps `~/.dt-ai-obs/bin` and saves the ~100 MB collector download |
| `--keep-hooks` / `-KeepHooks` | you want the hook to keep emitting to another collector on `127.0.0.1:4318` (for example the VS Code extension's); the hook never blocks Claude Code if nothing is listening |

Afterwards, **restart any open Claude Code session** (terminal or Desktop Code tab): hooks and env are read at startup, so a running session keeps the old ones until it is restarted.

To confirm the machine is clean:

```bash
launchctl list | grep dt-ai-obs ; ls ~/.dt-ai-obs ~/.claude/otel-hook.py 2>&1 ; python3 -c "import json,os;s=json.load(open(os.path.expanduser('~/.claude/settings.json')));print(list((s.get('hooks') or {}).keys()), [k for k in (s.get('env') or {}) if k.startswith('OTEL')])"
```

All four commands should report nothing installed (`No such file`, `[] []`). On the tenant side nothing is deleted: spans, metrics and logs already ingested stay in Grail until their bucket retention expires, and the dashboard keeps working on that history.

> **VS Code / Cursor extension users:** this asset and the *Dynatrace AI Governance For Devs* extension write the same `~/.claude/otel-hook.py` and hook entries. If both were installed, remove the extension with `code --uninstall-extension DynatraceExtensionCommunity.dt-ai-observability` (or its *Remove Claude Code Hooks* command) **and** run this uninstaller; whichever runs last leaves the machine clean.

---

<a id="privacy"></a>
## 🔒 Privacy and security

- **Prompt and response content is not sent by default.** The hook only adds content when `_capture_prompts` is `"true"`, and the collector's `transform/redact_content` processor deletes `gen_ai.prompt*`, `gen_ai.completion*`, `gen_ai.input.messages`, `gen_ai.output.messages`, `gen_ai.system_instructions` (spans and span events) and the native `prompt` log attribute before anything leaves the machine. Metadata (model, tokens, cost, tool names) is kept.
- **Tool input/output is always sent.** Each `claude.tool.<name>` span carries `claude.tool_input` and `claude.tool_response` (first 4 KiB each: shell commands, file paths, and the contents of files Claude Code reads or writes) on every tool span, **only when `--capture-prompts` is on: the hook omits them otherwise and the collector's redaction processor deletes them as a second guard (since 1.0.1).
- **Evals are opt-in and never automatic.** [Dynatrace Evals](#evals) only works with capture on, asks before every paid run and is the one path where (masked) prompt text is sent outside the tenant: to the LLM judge provider you configure. Results go back to the same tenant without the evaluated text unless `--store-evaluated-prompt` is given.
- **Token never in plain text on disk**: macOS Keychain, Linux Secret Service or Windows DPAPI; the service wrapper injects it as an environment variable into the collector process only. The Linux file fallback (0600) is used only when no keyring is available and is announced with a warning. The rendered collector config and `config.env` are mode 0600 and contain no token.
- **Loopback only**: OTLP/HTTP, OTLP/gRPC and the health check bind to `127.0.0.1`. Outbound, the collector talks only to your tenant over HTTPS.
- **Verifiable binary**: downloaded from the official OpenTelemetry release page and SHA-256 checked against the published `.sha256` file; a pinned version or a local tarball can be used for air-gapped rollouts.
- **No workspace override**: hooks and attributes live in user-level files; a repository's `.claude/settings.json` cannot change the endpoint or re-enable content capture. Managed settings (admin-controlled) take precedence over user settings for the native OTel env.
- **Stopping telemetry**: stop the service (see table above) or run the uninstaller.

---

<a id="local-test"></a>
## 🧪 Local test (no tenant)

`python3 test/hook_tests.py` exercises the hook alone (isolated HOME, loopback sink): 8 parallel tool calls, privacy gates, per-turn token sums, state-file hygiene, dead collector.

[test/run-local-test.sh](test/run-local-test.sh) installs against a tiny OTLP sink ([test/sink.py](test/sink.py)) on `127.0.0.1:9999` with a dummy token, fires the four hook events for a synthetic Desktop session and a CLI session, optionally runs `claude -p` with native telemetry, checks that no prompt text reached the sink, prints what arrived and (with `--uninstall`) removes everything again. A sample run (macOS arm64, 2026-10-19) is in [test/local-e2e.log](test/local-e2e.log).

```bash
test/run-local-test.sh --native --uninstall            # downloads the collector
test/run-local-test.sh --tarball ./otelcol-contrib_0.163.1_darwin_arm64.tar.gz --uninstall
```

---

<a id="relation"></a>
## 🔗 Relation to the VS Code asset

[dt-ai-observability-vscode](https://github.com/Dynatrace-Internal/field-asset-library/tree/main/integrations/application/dt-ai-observability-vscode) (`/integrations/application/dt-ai-observability-vscode` in the field asset library) embeds the same hook, collector config and dashboard in a VS Code / Cursor extension. This asset reuses them for machines where the Claude Desktop app or the CLI is the client:

| | VS Code asset | This asset |
|---|---|---|
| Hook script | `HOOK_SCRIPT` constant in `src/claudeHooks.ts` (v1.7.0) | Same script, extracted; `service.name` becomes `claude-code-desktop` when `CLAUDE_CODE_ENTRYPOINT=claude-desktop` |
| Collector config | `resources/otel-collector.yaml` | Same receivers / redaction / resource processor; adds a `logs` pipeline, the `gen_ai.provider.name` alias and the `claude.account_email` normalisation; drops the Copilot-specific transform |
| Collector lifecycle | Spawned by the extension while VS Code runs | User service (launchd / systemd / Scheduled Task), independent of any editor |
| Credentials | VS Code SecretStorage | OS credential store + wrapper script |
| Dashboard | `Dashboard/Developers AI Usage.json` | Claude-only variant: GPT / Gemini / Copilot sections removed, Claude filters and defaults |
| Evals | `src/evals.ts`: *Configurar Evals* / *Rodar Evals* commands run `npx @dynatrace-oss/dt-evals` in a terminal (evaluator pick list, since 30m–24h, sample 10–100 %) | `evals/run-evals.sh` / `.ps1`: same CLI, evaluators and choices; config generated for this asset's span layout, prompt-capture check, y/N before paid runs |

Both can coexist on one machine: they write the same `~/.claude/otel-hook.py` and the hook follows whichever collector port is in `otel-attrs.json`. Running two collectors at once is pointless; keep one.

**Same dashboard, same data.** Spans from this asset carry the attributes the VS Code asset's *Developers AI Usage* dashboard queries
(`gen_ai.provider.name = "anthropic"`, `gen_ai.request.model`, `gen_ai.operation.name = "chat"`, `gen_ai.conversation.id`,
`gen_ai.usage.*`, `user.email`, `user.team`), so machines instrumented by either asset land in the same tiles, in the same tenant.
Two things to know when you open the VS Code asset's copy of the dashboard: its `Provider` / `Modelo` variables default to
`gcp.vertex_ai` / `github` / `openai` and older model names, so select `anthropic` and the Claude models once (the Claude-only copy in
`Dashboard/` defaults to them); and its "por time" tiles group by `user.team`, which this asset writes from `--squad` (also kept as `squad`).

The `connector/` folder in this repository is a separate component (Claude usage connector for the Anthropic admin / usage APIs) with its own README.

---

<a id="license"></a>
## 📄 License

MIT — see [LICENSE](LICENSE)
