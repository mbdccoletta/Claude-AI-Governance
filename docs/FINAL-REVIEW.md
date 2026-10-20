# Análise final — dt-ai-observability-claude 1.0.0 (2026-10-19)

Três revisões independentes (segurança, correção de código, documentação) sobre o commit `626562e`, mais verificações próprias
(DQL validado no tenant de laboratório, renderização dos diagramas, conteúdo do log local do collector). Relatórios completos:
[SECURITY-REVIEW.md](SECURITY-REVIEW.md) · [CODE-REVIEW.md](CODE-REVIEW.md) · [DOCS-REVIEW.md](DOCS-REVIEW.md).

## Veredito

**Funciona e está pronto para demonstração; não está pronto para rollout em clientes sem o lote P1.** O que está sólido: token de ingest
no cofre do SO, collector só em loopback, checksum do binário baixado, deploy em dry-run por padrão, hook que nunca bloqueia o Claude Code,
nomes/flags/escopos/campos da documentação batendo com o código, suíte local do conector passando (403 eventos, paridade do `dedup.key`,
backoff em 429, cursor congelado). Os problemas reais estão em quatro frentes: **privacidade por padrão** (input/output de tool calls
exportados mesmo com captura desligada), **concorrência do hook** (arquivo de estado sem lock), **escala e confiança do workflow**
(orçamento de tempo, parâmetros aceitos sem validação) e **endurecimento do instalador** (validação do token, debug exporter, versões fixas).

## O que já foi corrigido hoje

| Item | Onde | Estado |
|---|---|---|
| 5 exemplos DQL inválidos (vírgula antes de `by:`) | docs/dql-examples.md | corrigido, 20/20 validados com `dtctl verify query`, commit `626562e` |
| Diagramas de `connector/docs/` com texto cortado | connector/docs/*.svg | redesenhados e verificados em renderização |
| Permissões do log local do collector (0644, com prompts) | ~/.dt-ai-obs/logs | mitigado nesta máquina (0700/0600); correção definitiva no instalador está no lote P3 |
| Blocos `<system-reminder>` nos prompts capturados | hooks/otel-hook.py | corrigido no commit `7b9fbea` |
| 38 itens de documentação (consistência, "quem faz o quê", planos × APIs, chave só na camada 3) | README, GUIDE, connector/README, schema, meta.yaml | em aplicação (docs) |

## Achados consolidados (deduplicados entre as três revisões)

Severidade: **A** = alta, **M** = média, **B** = baixa. Origem: S = segurança, C = código, D = docs.

### Lote P1 — privacidade e integridade dos dados (antes de qualquer rollout)

| # | Sev | Origem | Onde | Problema | Correção |
|---|---|---|---|---|---|
| 1 | A | S1, C6, D7 | hooks/otel-hook.py:229-230; collector/otel-collector.yaml:42-57 | `claude.tool_input` / `claude.tool_response` (4 KiB cada: comandos, conteúdo de arquivos, possíveis segredos) vão em todo tool span mesmo com `--capture-prompts` off; a redação só apaga `gen_ai.*` | gate no hook por `capture_prompts` **e** `delete_key` no processador de redação; documentar |
| 2 | A | C1, C2 | hooks/otel-hook.py:179-236, 206, 217 | Arquivo de estado lido/escrito sem lock nem substituição atômica; tool calls paralelos perdem registros e corrompem o JSON; registros de tool indexados por `tool_name` (dois `Read` em voo colidem); `trace_id` re-gerado em falha de parse | escrita atômica (`tempfile` + `os.replace`) com `fcntl.flock`; indexar por `tool_use_id`; nunca re-gerar `trace_id` |
| 3 | A | C5 | hooks/otel-hook.py:255,275; 5 tiles do dashboard | `gen_ai.usage.cost_usd` lido de um campo que o evento Stop do Claude Code não envia; o teste e2e fabrica o valor; tiles de custo da camada 1 ficam vazias | calcular custo a partir do uso no transcript (tabela de preços por modelo) ou apontar as tiles para `api_request` dos logs nativos |
| 4 | M | C11, C24, S9 | hooks/otel-hook.py:82-104, 198-201, 175-176 | Tokens só da última mensagem do assistente (subconta o turno); prompt gravado no estado em disco mesmo com captura off; diretório de estado 0755 | somar `usage` de todo o turno (offset gravado no UserPromptSubmit); gravar prompt só com captura on; 0700/0600 |

### Lote P2 — workflow da camada 3 (confiança e escala)

| # | Sev | Origem | Onde | Problema | Correção |
|---|---|---|---|---|---|
| 5 | A | S2 | connector/workflow/tasks/resolve_config.js; lib/common.js; deploy/vault_upsert.js; build.py | `anthropic_base_url`, `credential_id`, `credential_name` aceitos dos parâmetros de execução sem validação; workflow `isPrivate:false`; vault `ownerAccessOnly:false` | ler só do `input` do workflow; fixar `https://api.anthropic.com`; `isPrivate:true`; `ownerAccessOnly:true`; deploy confere allowlist `enforced` |
| 6 | A | C3, S10 | lib/common.js; enterprise_analytics.js; console_claude_code.js | Chamadas serializadas a ≥1,1 s, nada ingerido até paginar tudo, timeout 110 s → ~95 chamadas; org com 2000 usuários × 10 dias (~160 páginas) nunca gera eventos; `Retry-After` sem teto; sem limite de páginas nem checagem de 5 MiB | ingest incremental por página/dia, orçamento de tempo com `partial:true`, teto de backoff, `MAX_PAGES`, lotes por tamanho |
| 7 | M | C8 | enterprise_analytics.js:58,86 | `requests` somado das linhas de custo **e** de uso → dobrado quando o cost report também traz `requests` | `requests: null` nas linhas de custo |
| 8 | M | C9, D20 | connector/dql/official-vs-observed-tokens.dql:9 | O filtro `product == "claude_code"` ficou dentro de um comentário → cobertura diluída por chat/cowork; lado dos logs sem filtro de `service.name`; `formatTimestamp` sem `timezone: "UTC"` | restaurar o filtro, filtrar `service.name`, `timezone: "UTC"` (também em build.py) |
| 9 | M | C12, C13, S6 | connector/deploy/deploy.sh:63-71, 84-85 | Falha do dtctl na allowlist silenciada; chave da Anthropic em argv (`ps`) | tratar rc≠0; payload via arquivo 0600 / stdin |
| 10 | B | C22, C27, S10 | console_claude_code.js:44; resolve_config.js | `user_actor` sem e-mail vira "unknown"; sem fail-fast quando `org_type` falta; `ingest_batch_size` sem clamp | fallback por `user.id`; `die` sem `org_type`; clamp 1-1000 |

### Lote P3 — instalador, collector e supply chain

| # | Sev | Origem | Onde | Problema | Correção |
|---|---|---|---|---|---|
| 11 | M | S3, D8 | collector/otel-collector.yaml:87-117; install.sh:266; plist/service | Debug exporter ligado por padrão grava e-mail, ids, tool I/O e prompts (se on) em `collector.log` 0644, sem rotação | desligar por padrão (`--verbose-collector` para ligar); logs 0700/0600; rotação (newsyslog/logrotate) |
| 12 | M | C7, D8 | install.sh:143-144; install.ps1:75-82 | Token só checado como não vazio: colar 3× foi aceito e só falhou com 401 depois | regex `^dt0c01\.[A-Z0-9]{24}\.[A-Z0-9]{64}$` + POST vazio de pré-voo (401/403 → abortar) |
| 13 | M | S4, S5 | install.sh:214-239; evals/run-evals.sh:64 | otelcol `latest` sem versão fixa e checksum da mesma origem; `npx dt-evals@latest` sem pin; curl sem `--proto '=https' --tlsv1.2` | fixar versão + SHA no repositório; `DT_EVALS_VERSION`; endurecer curl |
| 14 | A (Windows, a verificar) | C4 | collector/run-collector.ps1:4,12; install.ps1:218 | `$ErrorActionPreference='Stop'` + `2>&1` em exe nativo (PowerShell 5.1) → wrapper morre na primeira linha de stderr; serviço reinicia a cada minuto | `Continue` / `Start-Process` com redirecionamentos; testar em Windows |
| 15 | M | C14, C15, C28 | hooks/configure-hooks.py:78-98, 164-169; uninstall.* | Hook já instalado em outro caminho não é atualizado; remoção do bloco env só por valor exato; grupo misto duplicado | comparar o comando; reutilizar a regex "ours"; tratar grupos mistos |
| 16 | B | S7, S8, S11-S15, C16-C19, C25 | collector, launchd/systemd, install.sh, uninstall.sh, import_team_spend.py | gRPC 4317 sem uso; sem `memory_limiter`; loop de restart em exit 78; `config.env` sem quoting; `rm -rf` no uninstall sem checagem; `--tenant` sem forçar https; `error_mode: ignore` na redação; backups de settings.json 0644 | ver linhas e correções nos relatórios |

### Lote P4 — métricas nativas por desenvolvedor (funcional)

| # | Sev | Origem | Onde | Problema | Correção |
|---|---|---|---|---|---|
| 17 | M | D10 (verificado no tenant) | collector/otel-collector.yaml; docs | `user.email`, `squad`, `cost_center` são resource attributes e **não viram dimensões** das métricas `claude_code.*` (`timeseries … by:{user.email}` retorna null) | copiar para atributos do datapoint no collector (OTTL `set(attributes[...], resource.attributes[...])` no contexto datapoint) ou documentar a allow-list de resource attributes no tenant |

## Plano proposto

1. **P1** (privacidade + hook): 1, 2, 3, 4 — cerca de 150 linhas em `otel-hook.py` e `otel-collector.yaml`, com teste de concorrência e validador de payload; regenera `hooks/otel-hook.patch`.
2. **P2** (workflow): 5, 6, 7, 8, 9, 10 — `common.js`, as duas tasks, `build.py`, `render_workflow.py`, `deploy.sh`, DQL; suíte local do conector cobre 6, 7 e 8 com mock de 60 páginas e `Retry-After`.
3. **P3** (instalador): 11, 12, 13, 15, 16 — `install.sh`/`.ps1`, wrappers, `configure-hooks.py`; 14 só com teste em Windows.
4. **P4** (métricas): 17 — `otel-collector.yaml` + docs.

Cada lote é um commit próprio, com testes locais e, para P2 e P4, validação no tenant de laboratório. Nenhum lote foi iniciado: todos tocam código e
dependem de confirmação. Os testes sugeridos pelas revisões (10 em CODE-REVIEW.md, checklist em SECURITY-REVIEW.md) entram no mesmo lote do item que cobrem.
