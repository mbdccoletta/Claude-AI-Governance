<h1 align="center">Dynatrace AI Observability for Claude</h1>
<p align="center"><em>Claude Desktop app (Code tab) · Claude Code CLI → OpenTelemetry → Dynatrace — no VS Code required</em></p>

<p align="center">
  Per-developer token, cost, model and tool-call observability for Claude Code sessions started from the <strong>Claude Desktop app</strong> or the <strong><code>claude</code> CLI</strong>, landing in Dynatrace through a local OpenTelemetry Collector that runs as a user service. Same hook, same collector, same dashboard as the <a href="../dt-ai-observability-vscode">VS Code extension asset</a> — packaged for machines where VS Code is not in the loop.
</p>

---

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

> ¹ Off by default. `install.sh --capture-prompts` (or `_capture_prompts: "true"` in `~/.claude/otel-attrs.json`) turns it on; the collector also stops redacting.
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
| 🔗 [Relation to the VS Code asset](#relation) | 📄 [License](#license) |

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
| Spans **and** metrics appear, collector log shows `Logs` batches with HTTP 200 and no `partialSuccess`, but `fetch logs` finds nothing (not even by `session.id` or `content`) | Grail **read permission**, not ingest: OTLP logs are stored through the `logs:default` pipeline into the `default_logs` bucket. If the IAM policy of the user running the query lacks `storage:buckets:read` on `default_logs`, the records are stored but invisible to that user. Ingest reports success and nothing in the UI says why. (The record shape is fine — body, `event.name`, timestamp and attribute-count variants were all tested) | 1. `fetch dt.system.buckets \| filter dt.system.table == "logs"` — the *has access* column of `default_logs` must be `true`. 2. `fetch logs, from:now()-2h \| summarize count(), by:{dt.system.bucket, dt.openpipeline.pipelines}` shows where logs you *can* read live. 3. Fix on the tenant: ask an admin to add `default_logs` to your policy (`ALLOW storage:buckets:read WHERE storage:bucket-name = "default_logs";`), **or** add an OpenPipeline → Logs routing rule `matchesValue(service.name, "claude-code*")` to a pipeline whose storage stage writes to a bucket your users can read (e.g. a dedicated `claude_code_logs` bucket). Re-check with [docs/dql-examples.md](docs/dql-examples.md#native-logs-health-check) |
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
| Dashboard | `Dashboard/Developers AI Usage.json` | Identical file |

Both can coexist on one machine: they write the same `~/.claude/otel-hook.py` and the hook follows whichever collector port is in `otel-attrs.json`. Running two collectors at once is pointless; keep one.

The `connector/` folder in this repository is a separate component (Claude usage connector for the Anthropic admin / usage APIs) with its own README.

---

<a id="license"></a>
## 📄 License

MIT — see [LICENSE](LICENSE)
