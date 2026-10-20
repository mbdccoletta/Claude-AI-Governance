# Documentation review — dt-ai-observability-claude 1.0.0

Independent accuracy and usability review of the documentation set (README.md, GUIDE.md, CHANGELOG.md, meta.yaml,
docs/overview.svg, docs/dql-examples.md, connector/README.md, connector/schema.md, connector/skills/…/SKILL.md,
connector/docs/*.svg, the inline help of install.sh / install.ps1 / connector/deploy/deploy.sh / evals/run-evals.sh).
Every claim was checked against the scripts in the repository; no tenant was queried and nothing was executed
except `connector/dashboard/build.py --check` (read-only effect: regenerated files were byte-identical, working tree unchanged)
and a headless-Chrome render of the three SVGs.

Reviewed at commit `626562e` (2026-10-19). Line numbers refer to that state.

---

## 1. Summary and readability verdict

**Verdict: good, close to ready; not yet shippable as-is.** The README is unusually complete for a field asset: the
coverage matrix ("What is measured where"), the Anthropic plans × APIs table, the credentials table and the Grail
`default_logs` DENY troubleshooting are exactly what a first-time reader needs and should not be touched. The DQL in
all documents parses logically and the field/metric/event names match the code (`gen_ai.*`, `claude.*`,
`claude_code.token.usage` / `cost.usage` / `session.count`, native events without the `claude_code.` prefix, bizevent
fields in `schema.md` = `workflow/lib/common.js`). Flags, env vars, scope names, paths and service names in the docs
match `install.sh`, `install.ps1`, `deploy.sh` and `run-evals.sh`.

What keeps it from shipping:

1. **Lab-tenant leftovers** survived the "scrub" commit: `fov`, `cca`, `fov-demo` and a stale "pendência" note in
   `connector/deploy/deploy_all.sh` and `connector/docs/installation-process.svg`, plus a personal absolute path in
   `connector/test/test.log`.
2. **Three internal contradictions** a careful reader will trip on: native `service.name` for the Desktop app
   (`claude-code` in one table, `claude-code-desktop` two screens later), the dashboard ("unchanged copy" vs
   "Claude-only variant"), and the hook patch ("three-line" vs the prompt-cleaning function that is also in it).
3. **Two wrong instructions**: `TOKEN_BACKEND=file` is not an installer option, and editing `otel-attrs.json` alone
   does not stop the collector from redacting.
4. **The two connector diagrams overflow their boxes** when rendered with a standard sans-serif font (dozens of clipped
   strings) and both say `deploy.sh` deploys dashboards, which it does not.
5. **Four known pitfalls are missing** from troubleshooting: 401 from a double-pasted token, empty dashboard because of
   the `Modelo` variable defaults, `user.email` on *metrics* (resource attribute → not a dimension unless allow-listed),
   and the fact that tool input/output leaves the machine even with prompt capture off.
6. **GUIDE.md (PT) drifts from README.md**: it starts using "camadas 1+2 / camada 3" before defining them, has no link to
   the diagrams or to `connector/README.md`, and lacks several troubleshooting and privacy bullets.

Readability for the two audiences:

* **Sales engineer / platform team (EN, README)**: can answer (a) which layer, (b) which plan exposes which API/key,
  (c) that layers 1+2 need no Anthropic key, (d) what Cowork / chat / web / personal / Bedrock get, in the first two
  screens. (e) privacy defaults are stated but the tool-I/O caveat is buried in a parenthetical. (f) *who does what in
  which order* is only in the Portuguese SVG and in `connector/README.md`; the README itself never gives the
  admin → developer → admin sequence. (g) verification is good; troubleshooting misses the four pitfalls above.
* **PT-BR reader (GUIDE)**: gets layers 1+2 well; layer 3 is a credentials table plus "README próprio" in English.
  Acceptable if stated up front; today it is not.

---

## 2. Findings

Severity: **Blocker** = must fix before submission to the field-asset library · **Major** = wrong or contradictory
instruction a reader will act on · **Minor** = inaccuracy or drift that costs time · **Nit** = polish.

| # | Sev | Where | Problem (evidence) | Proposed fix / wording |
|---|---|---|---|---|
| 1 | Blocker | `connector/deploy/deploy_all.sh:5`; `connector/docs/installation-process.svg:92` | Lab-tenant references: `--context cca --org-id fov-demo` in the usage comment; the SVG says `logs claude_code.api_request etc. (pendência: não visíveis no Grail do fov)`. "fov"/"cca" are the lab tenant/context; the "pendência" is also stale — CHANGELOG and `data-collection-architecture.svg` say the native-logs DENY was fixed on 2026-10-19. Commit 301fef8 ("scrub lab-tenant references") missed these. | `deploy_all.sh`: `deploy/deploy_all.sh --context <dtctl ctx> --org-id acme [--run-now] --yes`. SVG line 92: `logs claude_code.api_request etc. (ver permissões IAM do bucket default_logs) · service.name distingue Desktop de CLI`. |
| 2 | Blocker | `connector/test/test.log:40,96` | Tracked log contains the author's absolute path `/Users/marcelo.coletta/projects/…/sample.csv`. CHANGELOG and connector README point readers at this file. | Make `run_tests.sh` print the path relative to `connector/` (`csv-import/sample.csv`) and regenerate the log, or scrub the two lines. Consider git-ignoring both `*.log` files and shipping a short excerpt in the README instead. |
| 3 | Major | `README.md:99` vs `README.md:265`; `docs/dql-examples.md:3-5` vs `:90-91`; `GUIDE.md:74` | Contradiction on the native `service.name` of the Desktop app. Line 99 table: Desktop native = `claude-code` ³ ("carries no entrypoint attribute"). Line 265: "current builds (2.42+) report `claude-code-desktop`". dql-examples intro says native = `claude-code`, section at line 90 says `claude-code-desktop` for 2.42+. GUIDE already has the 2.42+ wording. | Make line 99 read: `claude-code-desktop` (Claude Code ≥ 2.42; older builds: `claude-code` ³) and move footnote ³ to "older builds carry no entrypoint attribute…". dql-examples lines 3-5: "…native OTel metrics and logs (`service.name` = `claude-code-desktop` on Claude Code ≥ 2.42, `claude-code` on the CLI and older builds)". |
| 4 | Major | `README.md:369` vs `README.md:5,469`, `CHANGELOG.md` "Scope", `GUIDE.md:363` | Line 369: "upload Dashboard/Developers AI Usage.json (**unchanged copy** of the VS Code asset's dashboard)". Line 5: "same dashboard". Line 469 and CHANGELOG: "Claude-only variant: GPT / Gemini / Copilot sections removed, Claude filters and defaults". The JSON is the Claude-only variant (variables default to `anthropic` + Claude models; tile 0 says "Claude Developers Usage"). | Line 369: "upload … (the Claude-only variant of the VS Code asset's dashboard: same tiles, GPT/Gemini/Copilot sections removed, `Provider`/`Modelo` defaults set to Anthropic/Claude)". Line 5: "same hook, same collector, a Claude-only cut of the same dashboard". |
| 5 | Major | `README.md:413` (Linux `secret-tool` row) | "accept the 0600 file fallback (uninstall `secret-tool` or run with `TOKEN_BACKEND=file`)". `install.sh` never reads a `TOKEN_BACKEND` env var (lines 229-241 choose the backend by probing `secret-tool`); only `run-collector.sh` reads it from `config.env`. The advice does nothing. | Either add an installer flag (`--token-backend keychain\|secret-tool\|file`) or fix the text: "…or switch to the file fallback by hand: `printf '%s' "$TOKEN" > ~/.dt-ai-obs/ingest-token && chmod 0600 ~/.dt-ai-obs/ingest-token`, set `TOKEN_BACKEND=file` in `~/.dt-ai-obs/config.env`, then `systemctl --user restart dt-ai-obs-claude`". Mirror in GUIDE.md:317. |
| 6 | Major | `README.md:92` footnote ¹ | "`install.sh --capture-prompts` (or `_capture_prompts: "true"` in `~/.claude/otel-attrs.json`) turns it on; the collector also stops redacting." Editing the JSON alone makes the **hook** send content but the collector's `transform/redact_content` still deletes it — the processor is only removed at render time by `--capture-prompts` (`render-config.py:91-94`). The parenthetical implies equivalence. | "Turn it on with `install.sh --capture-prompts`: it sets `_capture_prompts: "true"` in `~/.claude/otel-attrs.json` **and** renders the collector without the `transform/redact_content` processor. Editing the JSON by hand is not enough — the collector keeps redacting until it is re-rendered." |
| 7 | Major | `README.md:85-93, 436`; `GUIDE.md:374`; `docs/overview.svg` ("Prompts só se o dev habilitar") | Privacy clarity: `claude.tool_input` and `claude.tool_response` are attached to every tool span **unconditionally** (`hooks/otel-hook.py:208-231`, truncated at 4 096 chars) and the collector only redacts `gen_ai.prompt*`/`completion*`. For Read/Write/Edit/Bash that is file contents and shell commands leaving the machine with capture *off*. The README says it in a parenthetical ("tool input/output of the hook's tool spans is kept") that a privacy reviewer will miss. | Add a dedicated bullet under Privacy (README + GUIDE): "**Tool input/output is always sent.** Each `claude.tool.<name>` span carries `claude.tool_input` and `claude.tool_response` (first 4 KB each: shell commands, file paths, file contents read or written). `--capture-prompts` does not control this. To drop it, add `delete_key(attributes, "claude.tool_input")` / `…"claude.tool_response"` to `transform/redact_content` in `~/.dt-ai-obs/otel-collector.yaml` and restart the service." Ideally add a `--redact-tool-io` flag. Also change the overview.svg bullet to "Prompts só se o dev habilitar; entrada/saída de tools sempre (4 KB)". |
| 8 | Major | `README.md:398-414`, `GUIDE.md:305-318` (Troubleshooting) | Known pitfall not documented: **401 right after a fresh install because the token was pasted twice** into the hidden `read -s` prompt (terminal/clipboard managers that paste on Cmd-V *and* on Enter). `install.sh:143` only checks non-empty; `installation-process.svg` box 4 even claims "validar formato antes de gravar", which does not exist. | Add a row: "`401` in `collector.log` although the token is new → the hidden prompt received the token twice or with whitespace. Check the stored length: macOS `security find-generic-password -s dt-ai-obs-claude -w \| wc -c` (a `dt0c01.` token is 96 chars); re-run with `DT_INGEST_TOKEN=… ./install.sh … --non-interactive`." And in `install.sh`: warn when `$TOKEN` does not match `^dt0[cs]0[01]\.[A-Za-z0-9]{24}\.[A-Za-z0-9]{64}$` (warn, don't fail). Fix the SVG claim or implement it. |
| 9 | Major | `README.md:366-370` (Validating), Troubleshooting; `Dashboard/Developers AI Usage.json` variables | Known pitfall not documented: the `Modelo` variable has a **fixed default list** (`claude-fable-5-1`, `claude-opus-5-5`, …) and every tile filters `in(gen_ai.request.model, $Modelo)`. A tenant whose spans report e.g. `claude-sonnet-4-5` (the value used by `test/run-local-test.sh`) sees empty tiles until the user opens the filter and ticks the model. | Add a row: "Dashboard tiles empty but `fetch spans` shows data → open the `Modelo` filter and select your models; the default list is a snapshot of model ids. The variable query lists only models seen in the dashboard timeframe." Better: regenerate the dashboard with the variable defaulting to all values. Same for `Provider` if the hook ever changes `gen_ai.system`. |
| 10 | Major | `README.md:266, 232`; `docs/dql-examples.md:155-166`; `GUIDE.md:237` | "one field (`user.email`) groups all three signals". For **metrics** the collector stamps `user.email`, `squad`, `cost_center` as *resource* attributes (`otel-collector.yaml:32-36`); the only datapoint attributes are Claude Code's own (`type`, `model`, `user.id`, `session.id`, …). Dynatrace turns OTLP resource attributes into metric dimensions only for an allow-list (Settings → Metrics → OpenTelemetry metrics), so `timeseries … by: {user.email}` on `claude_code.*` is likely empty. CHANGELOG verifies the metrics arrive but not this dimension; the local e2e log (`test/local-e2e.log:102-106`) shows `user.email` at ResourceMetrics level only. | Verify on a tenant. Then either document the tenant setting ("add `user.email`, `squad`, `cost_center` to *Resource and scope attributes to be added as dimensions*") or move the stamping to datapoint level in `transform/native_email` (`set(datapoint.attributes["user.email"], resource.attributes["user.email"])`). Until then mark the two `timeseries` examples as "requires the resource-attribute allow-list". |
| 11 | Major | `docs/overview.svg` ("Faz sozinho: allowlist de saída, workflow agendado, **dashboards**, execução de teste, DQL"); `connector/docs/installation-process.svg` tenant step "4 · Dashboards (dtctl apply)"; `data-collection-architecture.svg` ("3 workflow via dtctl apply · **4 dashboards** · 5 run-now") | `deploy.sh` has four steps: allowlist, vault, workflow, run-now + verify DQL (`deploy.sh:58-131`). It never applies a dashboard; both dashboards are imported by hand (`connector/README.md:117-126`, README "Validating"). The diagrams promise more than the script does. | overview.svg: "Faz sozinho: allowlist de saída, credencial (quando o contexto permite), workflow agendado, execução de teste e DQL de verificação · dashboards: importar os 2 JSON (Dashboards → Upload)". installation-process.svg step 4: "Dashboards (manual) · Upload dos 2 JSON na app Dashboards (ou `dtctl apply -f connector/dashboard/…json`)". Same in data-collection-architecture.svg. |
| 12 | Major | `connector/docs/installation-process.svg`, `connector/docs/data-collection-architecture.svg` (rendering) | With a standard sans-serif font (Chrome headless, macOS Helvetica) both diagrams **overflow**: text runs under the next box or off the 1180/1240 px canvas. Clipped strings include: "4 entradas em settings.jso…", "config renderizada: redação, resource, logs pipelin…", "fetch spans \| filter service.name == "c…", every box of the right-hand column (0c, 0d, tenant 1-5, "Execução diária", "Por tipo de organização"), the two footer lines, "Camada 3 · Workflow "Claude usage connector" (no tena…", "tudo vira bizeven…", "Por desenvolvedor · … install.ps1 (Wi…", the whole "Papéis" box. `docs/overview.svg` renders cleanly. | Widen the canvases (e.g. 1500 × 820 / 1560 × 900), shorten the longest lines, or set `font-size` 11 → 10 and add `textLength`/`lengthAdjust` on the long `<text>` nodes. Re-render with `chrome --headless --screenshot` before committing (the SVGs are linked from the README and embedded in connector/README). |
| 13 | Major | `GUIDE.md:8-29` (opening), whole file | The guide uses "camadas 1 + 2" and "camada 3" from the first table on, but never defines the three layers (README has the "Three layers" table at line 10-18 and the diagram links at line 18). GUIDE has no link to `docs/overview.svg` (which is in Portuguese!), to `connector/README.md`, to `connector/schema.md` or the deploy skill; layer 3 setup exists only in English. | Insert before "O que é medido onde": the three-layer table (Hooks → spans · OTel nativo → métricas/logs · Oficial → bizevents, com "onde fica" = `install.sh` / `--enable-native-otel` / `connector/`) and the sentence "Diagramas: [visão geral](docs/overview.svg) · [coleta](connector/docs/data-collection-architecture.svg) · [instalação](connector/docs/installation-process.svg). A camada 3 (connector) está documentada em inglês em `connector/README.md`; o resumo em português está no diagrama de visão geral." |
| 14 | Major | `README.md` (no section), `GUIDE.md` (no section) | (f) Order of steps and roles is never spelled out in the Markdown. The reader must infer admin-once / developer-each / admin-once from the credentials table, the overview SVG (PT) and connector/README "Installation at a glance". | Add a 6-line "Installation order" right after "Credentials you need": 1 Dynatrace admin: install AI & LLM Observability app, create ingest token (3 scopes), check `default_logs` read access, import `Dashboard/Developers AI Usage.json`. 2 Each developer: `./install.sh` (or `.ps1`), restart Claude Code, run the health-check DQL. 3 (optional, admin, once) layer 3: Claude org owner/admin creates the Analytics/Admin key → Dynatrace admin stores it in the Credential vault (name `Anthropic <org_type> usage API key`) → `connector/deploy/deploy.sh --org-type … --run-now --yes` → import `connector/dashboard/claude-usage-dashboard.upload.json`. Team plan: run the CSV importer instead. Same in GUIDE. |
| 15 | Major | `README.md:398-414` (Troubleshooting) | Missing row for the connector side's most common symptom on the main README (it is in SKILL.md:94-103 and connector/README:141-147 only): "today's rows empty" because `usage_report/messages` returns closed buckets only, and "task log HTTP 401" = wrong key type. The README's Troubleshooting is the page people land on. | Add two rows that point to the connector docs: "Layer 3 workflow succeeds, `events: 0` for today → `usage_report/messages` returns closed buckets only (1 h lag); `claude_code` daily aggregate lags ~1 h; see connector/README § Freshness" and "Task log `HTTP 401` from api.anthropic.com → Admin key on an Enterprise org or vice-versa; see connector/README § Which organization type". |
| 16 | Minor | `README.md:379`; `GUIDE.md:155,349`; `CHANGELOG.md` Layer 1 first bullet | "upstream v1.7.0 plus a **three-line** `service.name` patch". `hooks/otel-hook.patch` is 50+ lines: the `service.name` line plus the `clean_prompt()` function (system-reminder stripping, `<pasted_content>` unwrap) and its call. CHANGELOG lists prompt cleaning separately but still calls the patch "service.name=claude-code-desktop patch". | "upstream v1.7.0 plus two small patches ([hooks/otel-hook.patch](hooks/otel-hook.patch)): `service.name = claude-code-desktop` when `CLAUDE_CODE_ENTRYPOINT=claude-desktop`, and prompt cleaning (drops `<system-reminder>` blocks, unwraps `<pasted_content>`) before the prompt is stored". |
| 17 | Minor | `README.md:236` ("merges the env block below") | `--enable-native-otel` writes the 8 keys of `NATIVE_ENV` (`configure-hooks.py:31-40`); the block shown (and `managed-settings.example.json`) has 10: `OTEL_LOG_USER_PROMPTS` and `OTEL_RESOURCE_ATTRIBUTES` are **not** written by the installer. Harmless (defaults are the same) but "the env block below" is not literally true. | "merges the first eight keys of the block below (`OTEL_LOG_USER_PROMPTS` defaults to off and `deployment.environment` is already stamped by the collector, so they are only needed in managed settings)". |
| 18 | Minor | `README.md:5,461`; `GUIDE.md:58` | Link `../dt-ai-observability-vscode` resolves only when the sibling folder exists next to the clone; broken on GitHub, in the asset library and in any zip. `meta.yaml` already has the library path. | Use the library/GitHub URL of the VS Code asset, or plain text "the dt-ai-observability-vscode asset (`/integrations/application/dt-ai-observability-vscode`)". |
| 19 | Minor | `README.md:35`; `GUIDE.md:21` | "`dql/official-vs-observed-tokens.dql` joins the two" — path is `connector/dql/official-vs-observed-tokens.dql` relative to the README. | Write `connector/dql/official-vs-observed-tokens.dql` and make it a link. |
| 20 | Minor | `connector/dql/official-vs-observed-tokens.dql:9,6`; connector/README:107,135 | The comment says "drop the sample.csv demo rows **and product == "claude_code"**" but no product filter exists, so `official_tokens` sums chat + Cowork + Design + API rows while `observed_tokens` only has Claude Code logs → `coverage_pct` is diluted on Enterprise orgs. The layer-2 side has no `service.name` filter (any `api_request` log in the tenant joins) and `formatTimestamp(timestamp, …)` uses the query timezone while `usage.date` is a UTC day. | Add `\| filter product == "claude_code"` after the dedup, `\| filter in(service.name, {"claude-code", "claude-code-desktop"}) and event.name == "api_request"` on the right side, and `formatTimestamp(timestamp, format: "yyyy-MM-dd", timezone: "UTC")`. Rebuild the dashboard (`build.py --check`) since the table tile embeds this file. Fix the comment. |
| 21 | Minor | `connector/README.md:62-70` (inputs table) | Table lists `credential_id` as "required unless team" and omits `credential_name` (the by-name lookup the same page describes in step 1 and that `resolve_config.js:31` defaults to `Anthropic <org_type> usage API key`), `anthropic_base_url` and `console_debug` (documented in SKILL.md:80). | Add rows: `credential_name` — vault entry name, used when `credential_id` is empty — default `Anthropic <org_type> usage API key`; `anthropic_base_url` — `https://api.anthropic.com`; `console_debug` — return the bucket list seen by the console task — `false`. Change `credential_id` to "— (optional when the entry is named as above)". Also update the workflow JSON `description` string which still says only `credential_id`. |
| 22 | Minor | `connector/README.md:50`, SKILL.md:65-66 vs `connector/deploy/vault_upsert.js:16` | UI instructions say **Owner access only ON**; the scripted path creates the credential with `ownerAccessOnly: false`. A reader who created it in the UI with owner-only ON and then runs `deploy.sh` without `--skip-vault` gets it silently flipped to shared on update. | State both: "The UI path uses *Owner access only* ON (owner = workflow owner). `deploy.sh` creates/updates the entry with owner-access-only **off** (shared with all app-engine consumers) because the dtctl actor is usually not the workflow owner; set it back in the UI if your policy requires it." |
| 23 | Minor | `connector/schema.md:79-104` (example) | The example's `dedup.key` (`b1ed2feece1edba0818373f9fb189f1a`) is not the SHA-256 of its own fields: `sha256("alice@example.com\|claude_code\|claude-opus-5-5\|2026-10-18\|console_api")[:32]` = `15ffabccbda0704d2a71f01d2ba32e89`. Anyone validating parity against the doc will think the rule is wrong. | Replace with `15ffabccbda0704d2a71f01d2ba32e89` (or regenerate the example from the mock). |
| 24 | Minor | `README.md:29`; `GUIDE.md:15`; overview.svg row "Claude Code na web" | "only native metrics/logs, if the cloud environment sets the `OTEL_*` variables". Without a local collector the cloud env must point straight at the tenant *with the ingest token* (`OTEL_EXPORTER_OTLP_HEADERS=Authorization=Api-Token …`) and `http/protobuf`; the asset's redaction/e-mail stamping does not apply there. CHANGELOG says it, the tables do not. | Add to the cell: "(endpoint = `https://<tenant>.live.dynatrace.com/api/v2/otlp`, token in `OTEL_EXPORTER_OTLP_HEADERS`; no local collector, so no redaction or `user.email` stamping)". |
| 25 | Minor | `README.md:275`; `CHANGELOG.md` Evals bullet | CHANGELOG: "`evals/run-evals.ps1` (unverified)". README presents the `.ps1` as an equal alternative with no caveat. | README line 275: "([evals/run-evals.ps1](evals/run-evals.ps1) on Windows — same options, not yet exercised end to end)". |
| 26 | Minor | `meta.yaml` `setup_instructions`, `related_assets` | Layer 3 instructions omit the outbound allowlist and the `ANTHROPIC_USAGE_KEY` env var that `deploy.sh` requires, and the import of `connector/dashboard/claude-usage-dashboard.upload.json`; `related_assets` path `/apps/application/ai-observability-3-0` could not be verified offline. There is no `version` field (1.0.0 is only in CHANGELOG/GUIDE). | Append: "export the Anthropic key as ANTHROPIC_USAGE_KEY in the shell that runs deploy.sh (it adds api.anthropic.com to the JS-runtime outbound allowlist, stores the key in the vault, applies and runs the workflow); then import connector/dashboard/claude-usage-dashboard.upload.json." Confirm the related-asset path and add `version: 1.0.0` if the library template has it. |
| 27 | Minor | `README.md:449` | "The last run **on this Mac** is in test/local-e2e.log" — personal phrasing in a public README. | "A sample run (macOS arm64, 2026-10-19) is in [test/local-e2e.log](test/local-e2e.log)." |
| 28 | Minor | `Dashboard/Developers AI Usage.json` tile `Claude_logo` | Markdown tile loads an image from `registry.npmmirror.com` (a third-party npm mirror). Corporate proxies block it and it is an external dependency in a shipped dashboard. | Drop the image or inline an SVG/emoji; mention nothing in docs once removed. |
| 29 | Minor | `GUIDE.md:305-318` vs `README.md:398-414` | GUIDE lacks the rows "Prompt text visible in Dynatrace" and "macOS: Keychain prompt at service start"; GUIDE Privacy (372-377) lacks the Evals bullet and the "no workspace override" bullet; GUIDE native-telemetry list (224) omits `tool_decision`. | Port the three rows/bullets; add `tool_decision` to line 224. |
| 30 | Minor | `connector/README.md:59`; `connector/deploy/deploy.sh:7` header | Both say `dtctl apply … --write-id`; `deploy.sh:113` comments that `--write-id` "does not write JSON files back" and stamps the id itself. The manual-import hint therefore does not keep the id for later updates. | README line 59: "`dtctl apply -f workflow/claude-usage-connector.json` (note the returned id; put it in the JSON as `id` for later updates)". deploy.sh header line 7: "`dtctl apply` + id stamped into deploy/.out/*.json by the script". |
| 31 | Minor | `connector/docs/installation-process.svg` dev header | "./install.sh --endpoint <tenant> --email …" — the Windows form is absent and `[--capture-prompts] [--enable-native-otel]` is cut off in the render. | "install.sh / install.ps1 --endpoint <tenant> --email … [--enable-native-otel] [--capture-prompts]" on two lines. |
| 32 | Nit | `install.sh:71` (`usage()`), `--help` | `sed -n '2,38p'` prints lines 2-38; line 37 is `set -euo pipefail`, so `--help` ends with a stray "set -euo pipefail". | `sed -n '2,36p'`. |
| 33 | Nit | `install.sh:2-13` header; `install.sh:307,343`; `install.ps1:220,245` | Header lists 6 steps, the script has 8 numbered sections and two of them are both "8."; same duplicate in the .ps1. | Renumber (health check 8, Evals pointer 9) and list 8 steps in the header. |
| 34 | Nit | `README.md:190` | "Running sessions usually pick the hooks up on their own, but a restart is the reliable path." Claude Code snapshots hook config at session start; GUIDE simply says close and reopen. | "Restart open sessions; hooks are read at session start." |
| 35 | Nit | `README.md:77` vs `GUIDE.md:103` | "~50 MB RAM" vs "~50–80 MB de RAM … ~200 MB em disco". | Use "~50–80 MB RAM, ~200 MB disk" in both. |
| 36 | Nit | `README.md:315-325` (Evals option table), `GUIDE.md:283` | `--concurrency N` and `--allow-no-capture` exist in `run-evals.sh` (lines 92, 97) and in the `.ps1`, not in the docs. | Add both rows ("parallel judge calls, dt-evals default 5"; "run even when capture is off — nothing to score, for testing the pipeline"). |
| 37 | Nit | `connector/schema.md:48-57` (product mapping) | `common.js` and the importer also map `"claude code"` (with a space) → `claude_code`; the table does not list it. | Add `claude code` to the `claude_code` row. |
| 38 | Nit | `README.md:106-117` (TOC) | TOC starts after four major sections (Three layers, What is measured where, Anthropic plans, Credentials); those are not in the TOC. | Add them as the first row, or move the TOC above "Three layers". |

Verified and **correct** (no finding): all `install.sh`/`install.ps1` options in the README table exist with the same
meaning; env vars `DT_OTLP_ENDPOINT`, `DT_INGEST_TOKEN`, `DT_USER_EMAIL`, `DT_SQUAD`, `DT_COST_CENTER`,
`DT_AI_OBS_DIR`, `DT_AI_OBS_OTELCOL_VERSION`; token scopes (ingest: `openTelemetryTrace.ingest`, `metrics.ingest`,
`logs.ingest`; CSV: `bizevents.ingest`; evals platform token scopes identical in README, GUIDE, `run-evals.sh` header
and `install.sh --enable-evals`; dtctl scopes in SKILL.md); service/Keychain/LaunchAgent/systemd/Scheduled Task names;
installed paths; `service.name` values of the hook; `gen_ai.*`/`claude.*` span attributes; `claude.tool.<name>` and
`chat <model>` span names; native event names without prefix and `claude_code.` body prefix; metric keys; bizevent
fields and optional fields vs `common.js`/tasks; dedup rule parity (asserted by the test); workflow schedule 15:00 UTC,
4 tasks, inputs and defaults; `deploy.sh` options and 4-step order; `run-evals.sh` commands/options and the generated
config; uninstall flags and what is removed (`otel-state/` included); all relative links and anchors except
`../dt-ai-observability-vscode`; URL-encoded `Dashboard/Developers%20AI%20Usage.json`; version strings (1.0.0, hook
1.7.0, schema 1.0, UA `dt-ai-observability-claude/1.0`); CHANGELOG content matches the code; DQL syntax (including the
`summarize …, by:` commas fixed in 626562e; connector queries use `summarize { } , by:` correctly; `dedup` and `join`
forms are valid). `test/local-e2e.log` is already scrubbed (`REDACTED_*`, `<scratchpad>`, `test@example.com`).

---

## 3. "First 10 minutes" reading path for a new user

**Sales engineer preparing a demo / first conversation (EN)**

1. README "Three layers" (1 min) — decide which layers matter for the account.
2. README "What is measured where" + "Quick answers" (2 min) — the Cowork / claude.ai / web / personal / Bedrock answers.
3. README "Anthropic plans vs APIs" (2 min) — which key the customer can actually produce (Enterprise usage-based vs
   seat-based vs Console vs Team).
4. README "Credentials you need" (1 min) — who creates what. *(after fix #14: the "Installation order" list)*
5. `docs/overview.svg` (2 min) — one page to show the customer (PT today; consider an EN copy).
6. README "Installation" → run `./install.sh` on your own laptop (2 min), restart Claude Code, run the health-check DQL
   from `docs/dql-examples.md`.

**Platform / FinOps engineer rolling it out (EN)**

1. README "Prerequisites" and "Privacy and security" (including the tool-I/O caveat after fix #7).
2. "Installation" → silent example for the fleet; "Claude Code native telemetry" → managed settings.
3. "Verify it's working" + `docs/dql-examples.md` health checks (spans, then native logs health check).
4. "Troubleshooting" — read the `default_logs` row before the first IAM question arrives.
5. `connector/README.md` top to "Setup" → decide `org_type`, get the key from the Claude org owner, then
   `connector/skills/deploy-claude-usage-connector/SKILL.md` (or let Claude Code run it).
6. `connector/schema.md` "Timestamps and dedup" — the one rule every custom query needs.

**Leitor em português (GUIDE)**: "O que é medido onde" → "Respostas rápidas" → "Planos × APIs" → "Credenciais" →
`docs/overview.svg` → "Instalação" → "Validação" → "Troubleshooting". Para a camada 3, `connector/README.md` (EN).

---

## 4. Already clear — do not touch

* README "What is measured where" matrix and "Quick answers" — the best part of the document; wording is precise
  (`as claude_code`, `as cowork`, personal plans = nothing, Bedrock = cloud billing).
* "Anthropic plans vs APIs" table incl. the seat-based "usage credits, not dollars" caveat, the key-type
  non-interchangeability paragraph and "one workflow per key".
* "Credentials you need" table with the "Who creates it" column and the sentence "the Anthropic key … never reaches
  developer machines".
* The `default_logs` / IAM DENY troubleshooting row and `docs/dql-examples.md` "Native logs health check" — long, but
  it is the one problem nobody can diagnose from the UI; keep every word.
* "Understanding token counts" (why one line = 20 000 tokens) and the "Who is who" idea (once #3 is fixed).
* Evals section: cost formula (`turns × sample % × evaluators`), the "one path where text leaves the tenant" statement,
  the recommendation to start with `preview`, and the generated-config description.
* `connector/README.md` "Which organization type needs which key", "Freshness and caveats" and the dashboard notes
  ("time picker does not apply", "open each tile once"); `schema.md` "Timestamps and dedup"; SKILL.md "Hard rules",
  "Closed-bucket semantics" and "Common failures".
* `docs/overview.svg` layout and content (except the two sentences in #7 and #11) — renders cleanly at 1400 × 1010.
* The installers' summary block and "Next steps" — they already tell the user to restart sessions, import the
  dashboard and how to control the service.
