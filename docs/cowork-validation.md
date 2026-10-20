# Validação do OTel do Cowork com o cliente

Roteiro para confirmar, em uma organização Claude **Team ou Enterprise** do cliente, que a exportação OpenTelemetry do Cowork chega ao Dynatrace com tokens, custo e e-mail por usuário. Nada é instalado nas máquinas dos desenvolvedores: a configuração é feita uma vez por um admin da org no claude.ai.

Leva cerca de 30 minutos: 10 do admin do claude.ai, 5 do admin Dynatrace, o resto é gerar tráfego e consultar.

> Não funciona com assinatura pessoal (Free, Pro, Max): essas contas não têm organização nem a área *Organization settings*. É por isso que a validação precisa ser feita na org do cliente.

**Validado em 2026-10-20** numa org Team, pelo claude.ai web e pelo app Desktop (tarefa Cowork com pasta local, que no Team roda como sessão na nuvem com a pasta compartilhada): eventos com `service.name = cowork`, `cowork.surface = remote`, `api_request` com tokens, custo, modelo e `user.email`; prompts chegam como `<REDACTED>`; só logs, sem spans nem métricas.

Fonte: [Monitor Claude Cowork activity with OpenTelemetry](https://support.claude.com/en/articles/14477985-monitor-claude-cowork-activity-with-opentelemetry) (Anthropic).

## 1. O que pedir ao cliente antes

| Pergunta | Por quê |
|---|---|
| Qual plano: Team ou Enterprise? | Pro/Max não têm a configuração |
| Quem é Owner ou admin da org no claude.ai? | só esse papel vê *Organization settings → Cowork* |
| Versão do Claude Desktop dos usuários de teste (menu Claude → About) | mínimo 1.1.4173 para sessões locais, 1.22209.3 para sessões na nuvem |
| O cliente já usa o modo *Chat and Cowork unified*? (Enterprise, beta) | se sim, as conversas de chat também saem por esta exportação |
| Há política contra enviar e-mails de usuários a ferramentas externas? | o e-mail vai sempre nos eventos, mesmo sem captura de conteúdo |

## 2. Dynatrace: token de ingest (admin Dynatrace, 5 min)

1. No tenant, `Ctrl+K` → **Access tokens** → **Generate new token**.
2. Nome `claude-cowork-otel`, escopo apenas **Ingest logs** (`logs.ingest`). Nenhum outro.
3. Copie o `dt0c01...` uma única vez. Ele vai ficar cifrado no console da Anthropic; um token dedicado permite revogar sem afetar nada mais.

Se o tenant restringe leitura de logs por grupo IAM, confira que o grupo de quem vai consultar lê o bucket `default_logs` (o mesmo ponto do [Troubleshooting do README](../README.md#troubleshooting)): sem isso os eventos entram mas `fetch logs` volta vazio.

## 3. claude.ai: ligar a exportação (admin da org, 10 min)

1. Clique nas iniciais no canto inferior esquerdo → **Organization settings**.
2. **Data and privacy** → aba **Monitoring** → bloco *Cowork, Cowork in the cloud, and unified chat and Cowork* (link direto: `claude.ai/admin-settings/data-privacy-controls#cowork-monitoring`).
3. Preencha:

| Campo | Valor |
|---|---|
| OTLP endpoint | `https://<env>.live.dynatrace.com/api/v2/otlp` (URL base, **sem** `/v1/logs`; `.live.`, nunca `.apps.`) |
| OTLP protocol | **HTTP/protobuf** (o Dynatrace rejeita HTTP/JSON) |
| OTLP headers | nome `Authorization`, valor `Api-Token dt0c01...` |

4. Salve.

O exportador acrescenta `/v1/logs` sozinho (validado em 2026-10-20). No campo de header, cole o token logo depois de `Api-Token ` e confira que ele começa com **um único** `dt0c01.`: prefixo duplicado dá 401 e nada chega, sem erro visível no console. Não habilite captura de conteúdo para a validação: tokens, modelo, custo e e-mail já vêm por padrão. Para garantir que nenhum build antigo do Desktop envie conteúdo, o admin pode definir a device policy `otlpContentCapture` como `[]`.

Alternativa quando o cliente não quer o token no console da Anthropic ou precisa de redação: apontar para um OpenTelemetry Collector com endpoint HTTPS público, que a nuvem da Anthropic e os desktops alcancem, e dele para o Dynatrace. O collector local em `127.0.0.1:4318` deste asset não serve para isso.

## 4. Gerar tráfego (2 usuários, 5 min)

- Usuário A, Claude Desktop: abrir o Cowork, pedir uma tarefa curta que use pelo menos uma ferramenta (ler uma pasta, por exemplo), deixar terminar.
- Usuário B, claude.ai web: iniciar uma sessão Cowork na nuvem com uma tarefa semelhante.
- Aguardar 2 a 3 minutos.

## 5. Consultar no Dynatrace

Rode as queries de `docs/dql/` nesta ordem, em um Notebook, com a janela "última hora":

| Passo | Arquivo | O que esperar |
|---|---|---|
| 1 | [`cowork-01-discovery.dql`](dql/cowork-01-discovery.dql) | linhas por `service.name` e `event.name` (`api_request`, `user_prompt`, `tool_result`...). Anote o `service.name` que o Cowork usa |
| 2 | [`cowork-02-sample-record.dql`](dql/cowork-02-sample-record.dql) | um registro `api_request` completo: confira os campos `model`, `input_tokens`, `output_tokens`, `cost_usd`, `user.email` |
| 3 | [`cowork-03-tokens-by-user.dql`](dql/cowork-03-tokens-by-user.dql) | tokens e custo por usuário e modelo, os dois usuários de teste presentes |
| 4 | [`cowork-04-ingest-health.dql`](dql/cowork-04-ingest-health.dql) | só se nada chegou: separa erro de payload de erro de autenticação |

Se o passo 1 mostra eventos mas o passo 3 vem vazio, o Cowork nomeia os campos de forma diferente do Claude Code. O registro do passo 2 é o que permite ajustar o dashboard e a doc do asset.

## 6. Troubleshooting

| Sintoma | Causa provável | Ação |
|---|---|---|
| Nada chega | prefixo `dt0c01.` duplicado no header (o caso mais comum: digitar `dt0c01.` e colar o token que já começa com ele) | redigitar o header: `Authorization=Api-Token ` + token colado |
| Nada chega, passo 4 mostra `rejected > 0` | protocolo HTTP/JSON, ou endpoint com `/v1/logs` duplicado | trocar para HTTP/protobuf; usar a URL base |
| Teste "local" no Desktop não gera evento | a sessão não chegou a rodar: com *Chat and Cowork unified* ligado a aba Cowork some; trocar de conta logo após enviar encerra a sessão | rodar pela aba Cowork (ou Home), esperar a resposta terminar antes de trocar de conta; `~/Library/Logs/Claude/main.log` mostra `grantRemoteSessionFolders` quando a tarefa com pasta local começa |
| Usuário mandou só chat | sem o *Chat and Cowork unified* ligado, o chat não exporta | ligar o toggle em Organization settings → Chat, ou testar com uma tarefa Cowork |
| Nada chega, `received = 0` | token sem `logs.ingest`, host `.apps.`, ou Desktop abaixo da versão mínima | regerar token; usar `.live.`; atualizar o Desktop |
| Eventos chegam, `fetch logs` vazio para quem consulta | grupo IAM sem leitura do bucket `default_logs` | política IAM de leitura no bucket |
| Só o usuário do Desktop aparece | versão do Desktop abaixo de 1.22209.3 para sessões na nuvem, ou a sessão web ainda não terminou | atualizar; esperar e repetir |
| Aparece texto de prompt nos eventos | build antigo do Desktop com `otlpContentCapture` indefinida | admin define a policy como `[]` |

## 7. O que devolver para o asset

Preencha e envie (sem o e-mail real, se preferir):

```
Plano da org:                 Team | Enterprise (por assento | por uso)
Versão do Desktop testada:    
service.name do Cowork:       
event.name observados:        
Campos do api_request:        model= input_tokens= output_tokens= cache_read_tokens= cost_usd= user.email=
Sessão na nuvem apareceu?     sim | não
Chat and Cowork unified?      sim | não
Registro completo do passo 2: (colar)
```

Com isso o asset recebe: a seção de Cowork da doc sem o aviso de "não validado", os filtros do dashboard ajustados aos campos reais e, se o `service.name` for próprio, uma linha separada de Cowork na visão por desenvolvedor.

## Mensagem pronta para o admin do cliente

> Olá! Para o teste de observabilidade do Cowork no Dynatrace preciso de 10 minutos de alguém com papel de Owner ou admin da org no claude.ai. Caminho: iniciais no canto inferior esquerdo → Organization settings → Cowork → Monitoring. Preencher: endpoint `https://<env>.live.dynatrace.com/api/v2/otlp` (sem `/v1/logs`), protocolo HTTP/protobuf, header `Authorization=Api-Token <token que eu envio por canal seguro>` (um único `dt0c01.` no início do token). Não precisa ligar captura de conteúdo. Depois disso, dois usuários rodam uma tarefa curta no Cowork (um no Desktop, um no claude.ai web) e eu confiro no Dynatrace. Nada é instalado nas máquinas.
