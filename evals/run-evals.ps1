<#
.SYNOPSIS
  Dynatrace Evals for Claude Code spans (Windows, PowerShell 5.1+) — wrapper for @dynatrace-oss/dt-evals.

.DESCRIPTION
  Scores the gen_ai.* "chat" spans this asset sends (one per Claude Code turn) with an LLM judge
  (prompt injection, PII leakage, toxicity, ...) and writes the results back to the tenant as
  bizevents (event.type == "gen_ai.evaluation.result"). Needs prompt capture ON
  (install.ps1 -CapturePrompts). Every real run calls an external LLM judge: it costs money and
  the masked prompt text leaves the tenant for that call. Nothing runs without confirmation.

  Commands: run (default) | plan (= run -DryRun) | preview (dt-evals --dry-run: reads spans,
  no judge, no write) | validate | doctor | configure | status | evaluators | runs

.EXAMPLE
  .\evals\run-evals.ps1 -DryRun                                   # print config + command only
  .\evals\run-evals.ps1 preview -Since 6h -Sample 25              # what would be judged (reads tenant)
  .\evals\run-evals.ps1 run -Metrics prompt-injection,pii-leakage # real run (asks first)
  .\evals\run-evals.ps1 doctor                                    # platform-token walkthrough → evals\.env
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('run', 'plan', 'preview', 'validate', 'doctor', 'configure', 'status', 'evaluators', 'runs', 'help')]
    [string]$Command = 'run',
    [string]$Since = '1h',                       # 30m | 1h | 6h | 24h
    [ValidateRange(1, 100)][int]$Sample = 10,    # percent of matching spans
    [string[]]$Metrics = @('prompt-injection', 'pii-leakage'),   # or 'all'
    [ValidateSet('openai', 'anthropic', 'azure-openai', 'gemini', 'vertex', 'bedrock')]
    [string]$Provider = 'anthropic',
    [string]$Model,
    [string]$EnvUrl = $env:DT_ENV_URL,
    [ValidateSet('both', 'claude-code', 'claude-code-desktop')]
    [string]$Service = 'both',
    [int]$Concurrency = 0,
    [switch]$StoreEvaluatedPrompt,
    [string]$Config,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$AllowNoCapture
)
$ErrorActionPreference = 'Stop'

$EvalsDir   = $PSScriptRoot
$InstallDir = if ($env:DT_AI_OBS_DIR) { $env:DT_AI_OBS_DIR } else { Join-Path $env:USERPROFILE '.dt-ai-obs' }
$AttrsFile  = Join-Path $env:USERPROFILE '.claude\otel-attrs.json'
$Pkg        = '@dynatrace-oss/dt-evals'
$PkgVersion = if ($env:DT_EVALS_VERSION) { $env:DT_EVALS_VERSION } else { 'latest' }
$AllMetrics = @('prompt-injection', 'output-prompt-injection', 'pii-leakage', 'toxicity', 'bias', 'hallucination',
                'faithfulness', 'factual-accuracy', 'relevance', 'context-relevance', 'answer-completeness',
                'conciseness', 'fluency', 'summarization-quality', 'user-frustration')

function Log($m)  { Write-Host "==> $m" -ForegroundColor Blue }
function Warn($m) { Write-Host "warning: $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "error: $m" -ForegroundColor Red; exit 1 }

if ($Command -eq 'help') { Get-Help $PSCommandPath -Detailed; exit 0 }
if ($Command -eq 'plan') { $Command = 'run'; $DryRun = $true }

if ($Since -notmatch '^[0-9]+(m|h|d)$') { Die "-Since must look like 30m, 1h, 6h, 24h (got '$Since')" }
if ($Metrics.Count -eq 1 -and $Metrics[0] -eq 'all') { $Metrics = $AllMetrics }
$Metrics = @($Metrics | ForEach-Object { $_.Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($m in $Metrics) { if ($AllMetrics -notcontains $m) { Die "unknown evaluator '$m' (run: $PSCommandPath evaluators)" } }

function Need-Node {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { Die 'Node.js >= 20 is required for dt-evals (https://nodejs.org)' }
    $v = (& node --version).TrimStart('v'); $major = [int]($v.Split('.')[0])
    if ($major -lt 20) { Die "Node.js v$v found, dt-evals needs >= 20" }
    if (-not $env:DT_EVALS_BIN -and -not (Get-Command npx -ErrorAction SilentlyContinue)) { Die 'npx not found (comes with npm); or set DT_EVALS_BIN' }
}

function Capture-On {
    if (-not (Test-Path $AttrsFile)) { return $false }
    try { $d = Get-Content $AttrsFile -Raw | ConvertFrom-Json; return ("$($d._capture_prompts)".ToLower() -eq 'true') } catch { return $false }
}

function Derive-EnvUrl {
    if ($script:EnvUrl) { return }
    $cfg = Join-Path $InstallDir 'config.env'
    if (Test-Path $cfg) {
        $ep = (Get-Content $cfg | Where-Object { $_ -like 'DT_OTLP_ENDPOINT=*' } | Select-Object -First 1) -replace '^DT_OTLP_ENDPOINT=', ''
        if ($ep -match '^(https?://[^/]+)') { $script:EnvUrl = $Matches[1] }
        if ($script:EnvUrl -match '^http://(127\.0\.0\.1|localhost)') { $script:EnvUrl = '' }   # local test sink
    }
}

function Judge-KeyVar {
    switch ($Provider) {
        'openai' { 'OPENAI_API_KEY' } 'anthropic' { 'ANTHROPIC_API_KEY' } 'azure-openai' { 'AZURE_OPENAI_API_KEY' }
        'gemini' { 'GOOGLE_API_KEY' } 'vertex' { 'GOOGLE_CLOUD_PROJECT' } 'bedrock' { 'AWS_ACCESS_KEY_ID' }
    }
}
function DotEnv-Has($name) {
    $f = Join-Path $EvalsDir '.env'
    return (Test-Path $f) -and ((Get-Content $f) -match "^$name=.")
}

function Write-Config {
    $script:Config = Join-Path $EvalsDir '.dt-eval.yaml'
    $svc = if ($Service -eq 'both') { '[claude-code, claude-code-desktop]' } else { "[$Service]" }
    $lines = @(
        "# generated by dt-ai-observability-claude evals/run-evals.ps1 on $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))",
        '# no secrets here: DT_API_TOKEN and the judge key come from the environment or evals\.env',
        'schemaVersion: 3', 'name: claude-code',
        'dynatrace:', "  environmentUrl: $EnvUrl",
        'judge:', "  provider: $Provider")
    if ($Model) { $lines += "  model: $Model" }
    $lines += @('  timeout: 30000', '  maxRetries: 2', "  concurrency: $(if ($Concurrency -gt 0) { $Concurrency } else { 5 })",
        'scope:', "  since: $Since",
        '  level: agent-span                 # one verdict per Claude Code turn',
        '  operationNames: [chat]            # the hook''s per-turn span',
        '  filters:', "    service.name: $svc",
        '  spanFields:', '    input: gen_ai.prompt.0.content', '    output: gen_ai.completion.0.content', '    model: gen_ai.request.model',
        '  sampling:', '    strategy: random', "    percent: $Sample",
        'metrics:', '  enabled:')
    foreach ($m in $Metrics) { $lines += "    - $m" }
    $lines += "storeEvaluatedPrompt: $(if ($StoreEvaluatedPrompt) { 'true' } else { 'false' })"
    Set-Content -Path $Config -Value $lines -Encoding UTF8
}

function DtEvals-CmdLine([string[]]$a) {
    $bin = if ($env:DT_EVALS_BIN) { $env:DT_EVALS_BIN } else { "npx -y $Pkg@$PkgVersion" }
    return "$bin $($a -join ' ')"
}
function Invoke-DtEvals([string[]]$a) {
    Push-Location $EvalsDir   # so dt-evals loads evals\.env and relative paths
    try {
        if ($env:DT_EVALS_BIN) { & $env:DT_EVALS_BIN @a } else { & npx -y "$Pkg@$PkgVersion" @a }
        return $LASTEXITCODE
    } finally { Pop-Location }
}

switch ($Command) {
    'evaluators' { Need-Node; exit (Invoke-DtEvals @('evaluators', 'list')) }
    'status'     { Need-Node; exit (Invoke-DtEvals @('status')) }
    'runs'       { Need-Node; exit (Invoke-DtEvals @('runs', 'list')) }
    'doctor' {
        Need-Node; Derive-EnvUrl
        Log 'dt-evals doctor: checks dtctl, walks you through a platform token (saved to evals\.env, never printed)'
        Log 'Create the token at https://myaccount.dynatrace.com/platformTokens with: storage:spans:read storage:buckets:read storage:bizevents:read openpipeline:bizevents:ingest storage:logs:read'
        $a = @('doctor'); if ($EnvUrl) { $a += @('--env-url', $EnvUrl) }
        exit (Invoke-DtEvals $a)
    }
    'configure' {
        Need-Node; Derive-EnvUrl
        Log "dt-evals interactive wizard -> $EvalsDir\.dt-eval.yaml (secrets go to evals\.env)"
        Warn "the wizard does not know this asset's span layout; a later 'run' regenerates the config with the Claude Code scope"
        $a = @('configure', '--output', '.dt-eval.yaml', '--since', $Since, '--provider', $Provider)
        if ($EnvUrl) { $a += @('--env-url', $EnvUrl) }; if ($Model) { $a += @('--model', $Model) }
        exit (Invoke-DtEvals $a)
    }
}

# run / preview / validate
if (-not $DryRun) { Need-Node }
Derive-EnvUrl
if (-not $EnvUrl) { Die 'tenant URL unknown: pass -EnvUrl https://abc12345.live.dynatrace.com or set DT_ENV_URL' }

$captureOn = Capture-On
if (-not $captureOn) {
    if ($AllowNoCapture) { Warn "prompt capture is OFF in $AttrsFile - the spans carry no prompt/response text, evaluators will have nothing to score" }
    else { Die "prompt capture is OFF (`"_capture_prompts`" != `"true`" in $AttrsFile). Re-run install.ps1 with -CapturePrompts, restart Claude Code sessions, wait for new turns, then retry. (-AllowNoCapture overrides.)" }
}

$userConfig = $false
if ($Config) {
    if (-not (Test-Path $Config)) { Die "-Config $Config not found" }
    $Config = (Resolve-Path $Config).Path; $userConfig = $true
} else { Write-Config }

$runArgs = @('run', '--config', $Config, '--since', $Since, '--sample', "$Sample")
if ($Concurrency -gt 0) { $runArgs += @('--concurrency', "$Concurrency") }
if ($StoreEvaluatedPrompt) { $runArgs += '--store-evaluated-prompt' }
if ($userConfig -and $Metrics.Count -eq 1) { $runArgs += @('--metric', $Metrics[0]) }
if ($Command -eq 'preview') { $runArgs += '--dry-run' }
if ($Command -eq 'validate') { $runArgs = @('validate', '--config', $Config) }

$tokenSrc = if ($env:DT_API_TOKEN) { 'environment' } elseif (DotEnv-Has 'DT_API_TOKEN') { 'evals\.env' } else { 'missing' }
$keyVar = Judge-KeyVar
$keySrc = if ([Environment]::GetEnvironmentVariable($keyVar)) { 'environment' } elseif (DotEnv-Has $keyVar) { 'evals\.env' } else { 'missing' }
$mode = if ($DryRun) { 'dry-run (nothing executed)' } elseif ($Command -eq 'preview') { 'preview (reads spans, no judge call, no write)' } elseif ($Command -eq 'validate') { 'validate (connectivity checks only)' } else { 'REAL RUN: calls the judge (costs money) and writes bizevents' }
$svcText = if ($Service -eq 'both') { '{claude-code, claude-code-desktop}' } else { "{$Service}" }

@"

Dynatrace Evals - Claude Code spans
  Tenant               : $EnvUrl
  Spans                : gen_ai.operation.name == "chat", service.name in $svcText, last $Since
  Sample               : $Sample % of matching spans (random)
  Evaluators           : $($Metrics -join ',')$(if ($userConfig -and $Metrics.Count -gt 1) { '  (taken from your -Config file; -Metrics ignored)' })
  Judge                : $Provider$(if ($Model) { " / $Model" })  (key ${keyVar}: $keySrc)
  Dynatrace token      : DT_API_TOKEN: $tokenSrc
  Results              : bizevents event.type == "gen_ai.evaluation.result" in the same tenant$(if ($StoreEvaluatedPrompt) { ' (WITH prompt/response text)' })
  Prompt capture       : $(if ($captureOn) { 'ON' } else { 'OFF' })
  Config               : $Config$(if ($userConfig) { ' (yours, not modified)' })
  Mode                 : $mode

Command:
  cd $EvalsDir; $(DtEvals-CmdLine $runArgs)
"@ | Write-Host

if ($DryRun) {
    Log "dry-run: config written to $Config (no secrets). Nothing was executed and no network call was made."
    Write-Host "Judge calls on a real run ~ matching spans x $Sample % x $($Metrics.Count) evaluator(s); use '$PSCommandPath preview' to see the exact span count without calling the judge."
    exit 0
}
if ($tokenSrc -eq 'missing') { Die "DT_API_TOKEN not set (environment or evals\.env). Run '$PSCommandPath doctor' for the platform-token walkthrough." }
if ($Command -eq 'run') {
    if ($keySrc -eq 'missing') { Warn "$keyVar not set - the judge call will fail; set it or put it in evals\.env" }
    if (-not $Yes) {
        $ans = Read-Host "This calls the $Provider judge for every sampled turn and writes results to $EnvUrl. Proceed? [y/N]"
        if ($ans -notmatch '^(y|yes)$') { Write-Host 'aborted'; exit 0 }
    }
}
Log (DtEvals-CmdLine $runArgs)
$rc = Invoke-DtEvals $runArgs
if ($Command -eq 'run' -and $rc -eq 0) {
    @"

Read the results in Dynatrace (Notebooks / Dashboards):
  fetch bizevents, from:now()-$Since
  | filter event.type == "gen_ai.evaluation.result"
  | summarize runs = countDistinct(dt.eval.run_id), avg_score = avg(gen_ai.evaluation.score.value),
              fails = countIf(gen_ai.evaluation.score.label == "fail"), by:{gen_ai.evaluation.name}
Local run history: $(DtEvals-CmdLine @('runs', 'list'))
"@ | Write-Host
}
exit $rc
