"""Builds docs/Relatorio-Observabilidade-Claude-Dynatrace.pdf (pt-BR). Run: python3 docs/build_report.py (needs reportlab and macOS Arial fonts)."""
import os
from reportlab.lib.pagesizes import A4
from reportlab.lib import colors
from reportlab.lib.units import mm
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.enums import TA_LEFT
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (BaseDocTemplate, PageTemplate, Frame, Paragraph, Spacer, Table,
                                TableStyle, Image, PageBreak, KeepTogether)

ASSET = os.path.expanduser("~/projects/dt-ai-observability-claude")
OUT = os.path.join(ASSET, "docs", "Relatorio-Observabilidade-Claude-Dynatrace.pdf")
IMG = os.path.join(ASSET, "docs", "images", "cowork")

F = "/System/Library/Fonts/Supplemental/"
pdfmetrics.registerFont(TTFont("Arial", F + "Arial.ttf"))
pdfmetrics.registerFont(TTFont("Arial-Bold", F + "Arial Bold.ttf"))
pdfmetrics.registerFont(TTFont("ArialU", F + "Arial Unicode.ttf"))
from reportlab.pdfbase.pdfmetrics import registerFontFamily
registerFontFamily("Arial", normal="Arial", bold="Arial-Bold", italic="Arial", boldItalic="Arial-Bold")

INK = colors.HexColor("#1b1b22"); MUTED = colors.HexColor("#5b5b66"); ACCENT = colors.HexColor("#4f46e5")
OK = colors.HexColor("#1f7a4d"); WARN = colors.HexColor("#a15c00"); BAD = colors.HexColor("#b42318")
LINE = colors.HexColor("#d9d9e0"); SOFT = colors.HexColor("#f4f4f7")

S = {
    "title": ParagraphStyle("title", fontName="Arial-Bold", fontSize=22, leading=27, textColor=INK, spaceAfter=6),
    "sub": ParagraphStyle("sub", fontName="Arial", fontSize=11.5, leading=16, textColor=MUTED, spaceAfter=14),
    "h1": ParagraphStyle("h1", fontName="Arial-Bold", fontSize=15, leading=19, textColor=INK, spaceBefore=10, spaceAfter=6),
    "h2": ParagraphStyle("h2", fontName="Arial-Bold", fontSize=11.5, leading=15, textColor=ACCENT, spaceBefore=8, spaceAfter=4),
    "p": ParagraphStyle("p", fontName="Arial", fontSize=9.6, leading=13.6, textColor=INK, spaceAfter=5),
    "b": ParagraphStyle("b", fontName="Arial", fontSize=9.6, leading=13.4, textColor=INK, leftIndent=11, bulletIndent=2, spaceAfter=3),
    "cell": ParagraphStyle("cell", fontName="Arial", fontSize=8.4, leading=11, textColor=INK),
    "cellb": ParagraphStyle("cellb", fontName="Arial-Bold", fontSize=8.4, leading=11, textColor=INK),
    "head": ParagraphStyle("head", fontName="Arial-Bold", fontSize=8.4, leading=11, textColor=colors.white),
    "cap": ParagraphStyle("cap", fontName="Arial", fontSize=8, leading=10.5, textColor=MUTED, spaceAfter=8),
    "callout": ParagraphStyle("callout", fontName="Arial", fontSize=10, leading=14.5, textColor=INK),
    "code": ParagraphStyle("code", fontName="ArialU", fontSize=8.4, leading=11.5, textColor=INK),
}

def P(t, s="p"): return Paragraph(t, S[s])
def B(t): return Paragraph(t, S["b"], bulletText="•")
def tag(text, color): return f'<font color="{color.hexval().replace("0x", "#")}"><b>{text}</b></font>'
SIM = tag("SIM", OK); NAO = tag("NÃO", BAD); PARC = tag("PARCIAL", WARN); DOC = tag("A VALIDAR", WARN)

def table(rows, widths, head=True, zebra=True):
    data = []
    for i, r in enumerate(rows):
        style = "head" if (head and i == 0) else "cell"
        data.append([c if not isinstance(c, str) else Paragraph(c, S[style]) for c in r])
    t = Table(data, colWidths=widths, repeatRows=1 if head else 0)
    ts = [("VALIGN", (0, 0), (-1, -1), "TOP"), ("LEFTPADDING", (0, 0), (-1, -1), 5), ("RIGHTPADDING", (0, 0), (-1, -1), 5),
          ("TOPPADDING", (0, 0), (-1, -1), 4), ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
          ("LINEBELOW", (0, 0), (-1, -1), 0.4, LINE)]
    if head: ts.append(("BACKGROUND", (0, 0), (-1, 0), INK))
    if zebra:
        for i in range(1 if head else 0, len(rows)):
            if i % 2 == 0: ts.append(("BACKGROUND", (0, i), (-1, i), SOFT))
    t.setStyle(TableStyle(ts)); return t

def callout(text, color=ACCENT):
    t = Table([[Paragraph(text, S["callout"])]], colWidths=[174 * mm])
    t.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, -1), SOFT), ("LINEBEFORE", (0, 0), (0, -1), 3, color),
                           ("LEFTPADDING", (0, 0), (-1, -1), 9), ("RIGHTPADDING", (0, 0), (-1, -1), 9),
                           ("TOPPADDING", (0, 0), (-1, -1), 7), ("BOTTOMPADDING", (0, 0), (-1, -1), 7)]))
    return t

def img(name, width_mm, caption):
    path = os.path.join(IMG, name)
    from reportlab.lib.utils import ImageReader
    iw, ih = ImageReader(path).getSize()
    w = width_mm * mm; h = w * ih / iw
    return KeepTogether([Image(path, width=w, height=h), P(caption, "cap")])

def footer(c, doc):
    c.saveState(); c.setFillColor(colors.white); c.rect(0, 0, A4[0], A4[1], stroke=0, fill=1)
    c.setFont("Arial", 7.5); c.setFillColor(MUTED)
    c.drawString(18 * mm, 10 * mm, "dt-ai-observability-claude · Observabilidade de uso do Claude no Dynatrace · 21/10/2026")
    c.drawRightString(192 * mm, 10 * mm, f"Página {doc.page}")
    c.setStrokeColor(LINE); c.line(18 * mm, 14 * mm, 192 * mm, 14 * mm); c.restoreState()

doc = BaseDocTemplate(OUT, pagesize=A4, leftMargin=18 * mm, rightMargin=18 * mm, topMargin=16 * mm, bottomMargin=20 * mm,
                      title="Observabilidade de uso do Claude no Dynatrace", author="Dynatrace LATAM SE",
                      subject="Resultado da validação de 19 e 20/10/2026")
doc.addPageTemplates([PageTemplate(id="p", frames=[Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id="f")], onPage=footer)])
W = doc.width
st = []

# ── 1. Capa + resumo
st += [P("Observabilidade de uso do Claude no Dynatrace", "title"),
       P("Resultado da validação de 19 e 20/10/2026 — o que conseguimos medir por usuário, como configurar sem duplicar dados, "
         "o que a Anthropic não expõe e o que fica pendente.", "sub")]
st.append(callout("<b>Em uma frase:</b> todo uso de Claude que gera telemetria — Claude Code em qualquer interface, Cowork e as conversas "
                  "que usam o espaço de trabalho na nuvem — chega ao Dynatrace por usuário e em tempo real, com tokens e custo. "
                  "O que não aparece é o volume de tokens do <b>chat simples</b> de pergunta e resposta: a Anthropic não expõe isso no "
                  "plano Team, e no Team esse uso já está coberto pela mensalidade do assento."))
st.append(Spacer(1, 8))
st.append(P("Resumo executivo", "h1"))
for t in [
    "<b>Validado de ponta a ponta</b> num tenant Dynatrace com uma organização Claude Team de teste: Claude Code (aba Code do Desktop, CLI, "
    "VS Code e Cursor), Cowork pela web e pelo Desktop, e chat unificado quando a conversa roda código ou usa arquivos.",
    "<b>Duas fontes complementares:</b> o asset instalado nas máquinas (hook + OpenTelemetry nativo do Claude Code) e a exportação "
    "OpenTelemetry que o admin liga no console do claude.ai para o Cowork. Nada precisa ser instalado para o Cowork.",
    "<b>Custo e tokens</b> vêm de um único tipo de evento, <font face='ArialU'>api_request</font>, emitido uma vez por chamada ao modelo, "
    "com o mesmo esquema para Claude Code, Cowork e chat unificado. Isso evita contar o mesmo uso duas vezes.",
    "<b>Limitação da Anthropic:</b> chat simples (web e Desktop) não gera telemetria em nenhum modo. No Team, o único número é o "
    "excedente de gasto, por exportação manual com um dia de atraso. Tokens de todo chat por usuário só existem no Claude Enterprise por uso.",
    "<b>A validação também corrigiu o próprio asset:</b> o hook contava tokens em dobro e, se instalado no meio de uma sessão, somava o "
    "histórico inteiro. As duas falhas foram corrigidas e o dashboard passou a usar o custo reportado pelo próprio Claude Code."]:
    st.append(B(t))

# ── 2. Cobertura
st.append(P("O que chega ao Dynatrace", "h1"))
st.append(table([
    ["Uso do Claude", "Chega?", "Como", "O que vem"],
    ["Claude Code — aba Code do Desktop e CLI", SIM, "asset nas máquinas (hook + OTel nativo)", "tokens e custo por chamada, modelo, conversa e ferramentas, <font face='ArialU'>user.email</font>, time, prompts opcionais"],
    ["Claude Code — VS Code e Cursor", SIM, "extensão do VS Code (mesmo hook)", "o mesmo"],
    ["Cowork — web e Desktop", SIM, "OTel ligado pelo admin no claude.ai", "tokens, custo, modelo, ferramentas, <font face='ArialU'>user.email</font>"],
    ["Chat que roda código ou usa arquivos", SIM + " (com unificado ligado)", "mesmo export do Cowork", "o mesmo do Cowork"],
    ["Chat simples (pergunta e resposta)", NAO, "não há telemetria", "Team: só excedente via CSV manual. Enterprise por uso: API diária"],
    ["Claude Design, Claude in Chrome", NAO, "não há telemetria", "só Analytics API do Enterprise ou CSV"],
    ["Office Agents (Excel, Word, PowerPoint)", DOC, "OTel documentado como só Enterprise", "traces a partir do navegador, sem custo; exige collector com CORS"],
], [44 * mm, 22 * mm, 46 * mm, W - 112 * mm]))
st.append(Spacer(1, 4))
st.append(P("Fontes oficiais de custo (a fatura) ficam à parte: CSV de gastos no Team (manual, 1 dia de atraso, só excedente) e Analytics API "
            "no Enterprise por uso (automática, atualizada a cada ~4 h). Servem para conciliar, não para monitorar.", "cap"))

st.append(Spacer(1, 4))
# ── 3. Como funciona
st.append(P("Como funciona", "h1"))
st.append(table([
    ["Camada", "Fonte", "Onde configura", "Responde"],
    ["1 · Hook", "eventos do Claude Code viram spans <font face='ArialU'>gen_ai</font>", "instalador do asset em cada máquina", "o que aconteceu em cada conversa: ferramentas, duração, prompts (opcional)"],
    ["2 · OTel nativo", "métricas e eventos do próprio Claude Code e do Cowork", "instalador (<font face='ArialU'>--enable-native-otel</font>) e console admin do claude.ai", "tokens e custo por chamada, por usuário, em tempo real"],
    ["3 · Oficial", "Analytics API (Enterprise) ou CSV de gastos (Team)", "workflow no Dynatrace ou importador", "o que a Anthropic cobra — conciliação mensal"],
], [24 * mm, 46 * mm, 48 * mm, W - 118 * mm]))
st.append(Spacer(1, 6))
st.append(P("Caminho dos dados", "h2"))
st.append(P("<font face='ArialU'>Claude Code (máquina) → hook + OTel nativo → collector local (127.0.0.1) → Dynatrace OTLP (traces, logs, métricas)</font>", "code"))
st.append(P("<font face='ArialU'>Cowork / chat unificado (nuvem Anthropic) → OTel configurado no console admin → Dynatrace OTLP (logs)</font>", "code"))
st.append(P("<font face='ArialU'>Anthropic Analytics API ou CSV do Team → workflow / importador → Dynatrace (bizevents claude.usage.daily)</font>", "code"))
st.append(Spacer(1, 6))
st.append(P("O collector local guarda o token no cofre do sistema operacional, remove conteúdo de prompt quando a captura está desligada e "
            "carimba <font face='ArialU'>user.email</font>, time e centro de custo em todos os sinais.", "p"))

# ── 4. Configuração recomendada
st.append(P("Configuração recomendada — sem duplicar dados", "h1"))
st.append(table([
    ["Onde", "O que fazer", "Quem"],
    ["claude.ai (org Team ou Enterprise)", "Dados e privacidade → Monitoramento: endpoint <font face='ArialU'>https://&lt;env&gt;.live.dynatrace.com/api/v2/otlp</font>, "
     "protocolo http/protobuf, header <font face='ArialU'>Authorization=Api-Token &lt;token&gt;</font>. Recursos → Chat: ligar "
     "<b>Chat e Cowork unificados</b>.", "admin / Owner"],
    ["Máquina de cada desenvolvedor", "<font face='ArialU'>./install.sh --enable-native-otel</font>. Quem usa VS Code instala a extensão <b>ou</b> o asset, nunca os dois.", "cada dev, uma vez"],
    ["Alternativa sem instalar (Team / Enterprise)", "Configurações da organização → Claude Code → Managed settings: variáveis do OTel nativo no bloco env. "
     "Cobre CLI, IDEs, aba Code e Claude Code na web; um repositório não consegue desligar. <i>Documentado, ainda não validado.</i>", "admin"],
    ["Dynatrace", "Importar os dashboards <i>Claude Developers Usage</i> e <i>Claude Usage — Official Cost</i>. Token com logs.ingest, metrics.ingest e "
     "openTelemetryTrace.ingest.", "admin Dynatrace"],
], [40 * mm, W - 68 * mm, 28 * mm]))
st.append(Spacer(1, 6))
st.append(P("Uma fonte da verdade por pergunta", "h2"))
st.append(table([
    ["Pergunta", "Fonte única", "Regra"],
    ["Quantos tokens e quanto custou, por usuário, agora", "logs <font face='ArialU'>event.name == \"api_request\"</font> de "
     "<font face='ArialU'>claude-code</font>, <font face='ArialU'>claude-code-desktop</font> e <font face='ArialU'>cowork</font>", "um evento por chamada ao modelo"],
    ["O que aconteceu na conversa", "spans do hook (<font face='ArialU'>chat …</font>, <font face='ArialU'>claude.tool.*</font>)", "nunca somar tokens dos spans com os dos logs"],
    ["Quanto foi cobrado", "CSV do Team ou Analytics API do Enterprise", "comparar com o tempo real, nunca somar"],
], [52 * mm, 70 * mm, W - 122 * mm]))

st.append(PageBreak())
# ── 5. Telas
st.append(P("Telas de configuração", "h1"))
st.append(P("Host do tenant e nome da organização mascarados.", "cap"))
st.append(img("admin-monitoring-pt.png", 172, "Dados e privacidade → Monitoramento: bloco do Cowork, Cowork na nuvem e chat unificado, e bloco do Office Agents."))
st.append(img("admin-capabilities-unified-chat-pt.png", 172, "Recursos → Chat: toggle <b>Chat e Cowork unificados</b> (beta). Com ele ligado, conversas que usam o espaço de trabalho passam a ser exportadas."))
st.append(KeepTogether([Table([[Image(os.path.join(IMG, "desktop-unified-home.png"), width=50 * mm, height=50 * mm * 510 / 350),
                                Image(os.path.join(IMG, "desktop-classic-chat-cowork.png"), width=86 * mm, height=86 * mm * 673 / 762)]],
                              colWidths=[64 * mm, W - 64 * mm], style=[("VALIGN", (0, 0), (-1, -1), "TOP")]),
                        P("Desktop com o modo unificado ligado (Home, sem aba Cowork) e desligado (seletor Chat | Cowork).", "cap")]))

st.append(PageBreak())
# ── 6. Limitações e opções
st.append(P("Limitações da Anthropic e opções", "h1"))
st.append(P("A varredura completa das documentações da Anthropic (apps, API e Claude Code) confirmou que <b>não existe</b> API ou telemetria "
            "de uso por usuário para o plano Team além do OTel do Claude Code e do Cowork. O que existe para o chat simples:", "p"))
st.append(table([
    ["Opção", "Pega o chat simples?", "Contrapartida", "Status"],
    ["Claude Enterprise por uso — Analytics API", SIM + ", tokens e custo por usuário", "mudança de plano; dados atualizados a cada ~4 h, revisados até 7 dias após o fim do mês", "conector pronto, testado com dados simulados"],
    ["Claude Desktop em modo terceiros (3P)", SIM + ", Chat, Cowork e Code em tempo real", "cobrança por token (API, Bedrock, Vertex, Foundry); sem claude.ai web; conversas ficam no dispositivo", DOC],
    ["Claude apps gateway (hospedado pela empresa)", PARC + " (Desktop 3P e Claude Code)", "infraestrutura própria; cobrança por token", DOC],
    ["Ficar no Team", NAO, "chat dentro da cota não tem custo por token; excedente aparece no CSV mensal", "configuração atual"],
], [44 * mm, 36 * mm, 58 * mm, W - 138 * mm]))
st.append(Spacer(1, 6))
st.append(P("Comportamentos confirmados em teste", "h2"))
for t in [
    "Com o modo unificado, <b>o Claude decide</b> se a conversa vai para o espaço de trabalho. Pergunta simples, leitura de imagem e criação "
    "de arquivo pela ferramenta do chat <b>não</b> foram exportadas; pedido com execução de código foi.",
    "Tarefa do Cowork iniciada no Desktop com pasta local roda, no Team, como <b>sessão na nuvem</b> com a pasta compartilhada e chega como "
    "<font face='ArialU'>cowork.surface = remote</font>.",
    "O Cowork roda numa máquina virtual isolada: o hook do asset e a extensão do VS Code não o enxergam. A única fonte é o OTel do console admin.",
    "O CSV de gastos do Team é manual (só Owner), atualiza com um dia de atraso e lista só o excedente; uma org nova não mostra nada até o dia seguinte.",
    "Um token com o prefixo <font face='ArialU'>dt0c01.</font> duplicado no header faz a exportação falhar <b>sem nenhum aviso</b> no console do claude.ai.",
]:
    st.append(B(t))
st.append(P("Divergências na documentação da Anthropic", "h2"))
for t in [
    "A central de ajuda diz que o Team mantém chat e Cowork clássicos, mas o toggle do modo unificado existia e funcionou na org Team de teste.",
    "A ajuda indica \"Organization settings > Cowork\" para o OTel; na interface ele estava em Dados e privacidade → Monitoramento.",
    "O guia da Claude Code Analytics API diz que uso por assinatura não aparece; a referência da API documenta <font face='ArialU'>customer_type = subscription</font> e <font face='ArialU'>subscription_type = team</font>.",
]:
    st.append(B(t))
st.append(P("Um chamado com essas limitações e pedidos (chat no export OTel, API de uso para o Team, Office Agents no Team) foi redigido para a Anthropic.", "cap"))

st.append(PageBreak())
# ── 7. Correções e pendências
st.append(P("Correções feitas durante a validação", "h1"))
st.append(table([
    ["Problema encontrado", "Efeito", "Correção"],
    ["O histórico do Claude Code grava uma resposta em várias linhas, uma por bloco, e cada uma repete o uso", "o hook somava todas: tokens de entrada ×1,9 e de saída ×2,4", "contagem por <font face='ArialU'>message.id</font>, uma vez por resposta (teste de regressão)"],
    ["Asset instalado com uma sessão já aberta", "o primeiro turno somava o histórico inteiro (313 milhões de tokens em um span)", "o turno começa na última mensagem do usuário; sem ela, o span sai sem tokens"],
    ["Custo do dashboard calculado por tabela de preços sobre os tokens do hook", "valores inflados e preços desatualizados", "tiles passaram a usar o <font face='ArialU'>cost_usd</font> do <font face='ArialU'>api_request</font> (dashboard v9 no tenant)"],
    ["Header do OTel com <font face='ArialU'>dt0c01.</font> duplicado", "nada chegava, sem erro", "documentado no roteiro de validação e no troubleshooting"],
], [56 * mm, 52 * mm, W - 108 * mm]))
st.append(Spacer(1, 8))
st.append(P("Pendências", "h1"))
st.append(table([
    ["Item", "Responsável", "Situação"],
    ["Enviar o chamado à Anthropic (texto pronto)", "Marcelo", "a fazer"],
    ["Exportar o CSV de gastos do Team e testar o formato no importador", "Marcelo + asset", "dados disponíveis a partir de 21/10"],
    ["Ligar o OTel nativo por managed settings (sem instalador)", "teste na org Team", DOC],
    ["Office Agents, Desktop 3P, Claude Code na web, Claude no Slack", "conforme demanda do cliente", DOC],
], [92 * mm, 38 * mm, W - 130 * mm]))
st.append(Spacer(1, 8))
st.append(P("Onde está", "h1"))
for t in [
    "Repositório: <font face='ArialU'>github.com/mbdccoletta/Claude-AI-Governance</font> — instaladores (macOS, Linux, Windows), hook, configuração do collector, "
    "conector da camada 3, dashboards e documentação (README em inglês, GUIDE em português, roteiro de validação do Cowork).",
    "Seção do README/GUIDE <i>Configuração recomendada, status de cobertura e fontes da verdade</i> resume este relatório com links para a documentação da Anthropic.",
    "Fontes principais: code.claude.com/docs/en/monitoring-usage, /server-managed-settings, /analytics, /costs; "
    "platform.claude.com/docs/en/manage-claude/analytics-api; support.claude.com/en/articles/14477985 (Cowork OTel) e 12883420 (analytics Team/Enterprise).",
]:
    st.append(B(t))

doc.build(st)
print(OUT)
