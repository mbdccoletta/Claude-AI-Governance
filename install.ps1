<#
.SYNOPSIS
  Dynatrace AI Observability for Claude — installer (Windows 10 1803+ / 11, PowerShell 5.1+)

.DESCRIPTION
  Makes Claude Code telemetry (Claude Desktop app "Code" tab and the claude CLI)
  land in Dynatrace without VS Code:
    1. installs the Claude Code hook (%USERPROFILE%\.claude\otel-hook.py + settings.json)
    2. writes %USERPROFILE%\.claude\otel-attrs.json
    3. downloads otelcol-contrib into %USERPROFILE%\.dt-ai-obs\bin
    4. renders otel-collector.yaml for your tenant
    5. stores the ingest token encrypted with DPAPI (current user)
    6. registers the collector as a Scheduled Task that runs at logon

.EXAMPLE
  .\install.ps1 -Endpoint abc12345 -Email dev@example.com -Squad platform
  .\install.ps1 -Endpoint https://abc12345.live.dynatrace.com/api/v2/otlp -NonInteractive
#>
[CmdletBinding()]
param(
    [string]$Endpoint = $env:DT_OTLP_ENDPOINT,
    [string]$Token = $env:DT_INGEST_TOKEN,          # or omit and type it (hidden)
    [string]$Email = $env:DT_USER_EMAIL,
    [string]$Squad = $env:DT_SQUAD,
    [string]$CostCenter = $env:DT_COST_CENTER,
    [string[]]$Attr = @(),                          # KEY=VALUE
    [string]$Environment = 'demo',
    [int]$CollectorPort = 0,                        # 0 = 4318 or next free
    [int]$HealthPort = 0,                           # 0 = 13133 or next free
    [switch]$CapturePrompts,
    [switch]$EnableNativeOtel,
    [string]$OtelcolVersion = $env:DT_AI_OBS_OTELCOL_VERSION,
    [string]$OtelcolTarball,
    [switch]$QuietCollector,
    [switch]$NonInteractive
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$AssetDir   = $PSScriptRoot
$InstallDir = if ($env:DT_AI_OBS_DIR) { $env:DT_AI_OBS_DIR } else { Join-Path $env:USERPROFILE '.dt-ai-obs' }
$ClaudeDir  = Join-Path $env:USERPROFILE '.claude'
$HookDst    = Join-Path $ClaudeDir 'otel-hook.py'
$TaskName   = 'Dynatrace AI Observability (Claude) collector'
$ReleasesApi = 'https://api.github.com/repos/open-telemetry/opentelemetry-collector-releases/releases/latest'
$UA = 'dt-ai-observability-claude'

function Log($m)  { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Warning $m }
function Die($m)  { Write-Error $m; exit 1 }

# ── prerequisites ───────────────────────────────────────────────────────────
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { Die 'python not found — the Claude Code hook needs Python 3.6+ (https://www.python.org/downloads/windows/, tick "Add python to PATH")' }
& python -c "import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)" 2>$null
if ($LASTEXITCODE -ne 0) { Die 'python is older than 3.6 or is the Microsoft Store stub — install Python 3 from python.org' }
if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) { Die 'tar.exe not found (Windows 10 1803+ ships it)' }
$arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'AMD64' { 'amd64' } 'ARM64' { 'arm64' } default { Die "unsupported architecture $($env:PROCESSOR_ARCHITECTURE)" } }

# ── inputs ──────────────────────────────────────────────────────────────────
Write-Host "Dynatrace AI Observability for Claude — installer (windows/$arch)`n"
if (-not $Endpoint) {
    if ($NonInteractive) { Die 'missing -Endpoint' }
    $Endpoint = Read-Host 'Dynatrace OTLP endpoint or tenant id (e.g. abc12345 or https://abc12345.live.dynatrace.com/api/v2/otlp)'
}
$Endpoint = $Endpoint.TrimEnd('/')
if ($Endpoint -match '^[A-Za-z0-9]{8}$') { $Endpoint = "https://$($Endpoint.ToLower()).live.dynatrace.com/api/v2/otlp" }
$Endpoint = $Endpoint -replace '/v1/(traces|metrics|logs)$', ''
if ($Endpoint -like '*.apps.dynatrace.com*') { Die 'use the .live.dynatrace.com host for OTLP ingest, not .apps.' }
if ($Endpoint -notmatch '^https?://') { Die "endpoint must start with https:// (got: $Endpoint)" }
if ($Endpoint -notlike '*/api/v2/otlp') { $Endpoint = "$Endpoint/api/v2/otlp" }
if ($Endpoint -like 'http://*') { Warn 'plain http:// endpoint — only use this for local testing' }

if ($Token) {
    $SecureToken = ConvertTo-SecureString -String $Token -AsPlainText -Force
    Remove-Variable Token
} else {
    if ($NonInteractive) { Die 'missing -Token (or env DT_INGEST_TOKEN)' }
    $SecureToken = Read-Host 'Dynatrace API token (openTelemetryTrace.ingest + metrics.ingest + logs.ingest)' -AsSecureString
}
if ($SecureToken.Length -eq 0) { Die 'token is required' }
if (-not $Email) {
    $default = if ($env:CLAUDE_CODE_USER_EMAIL) { $env:CLAUDE_CODE_USER_EMAIL } else { (& git config --global user.email 2>$null) }
    if ($NonInteractive) { $Email = $default } else { $v = Read-Host "Developer e-mail (user.email) [$default]"; $Email = if ($v) { $v } else { $default } }
}
if (-not $NonInteractive) {
    if (-not $Squad)      { $Squad = Read-Host 'Squad / team (optional)' }
    if (-not $CostCenter) { $CostCenter = Read-Host 'Cost center (optional)' }
}
$attrs = @()
if ($Squad)      { $attrs += "squad=$Squad" }
if ($CostCenter) { $attrs += "cost_center=$CostCenter" }
$attrs += $Attr

# ── stop a previous install of this asset (re-install) so its ports read as free ──
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Log 'Stopped the previous collector task (re-install)'
}
Get-Process otelcol-contrib -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $InstallDir 'bin\otelcol-contrib.exe') } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 800

# ── ports ───────────────────────────────────────────────────────────────────
function Test-PortFree([int]$p) {
    try { $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $p); $l.Start(); $l.Stop(); return $true } catch { return $false }
}
function Find-Port([int]$start) { for ($i = 0; $i -le 50; $i++) { if (Test-PortFree ($start + $i)) { return $start + $i } }; Die "no free port from $start" }
function Test-Health([int]$p) { try { return ((Invoke-WebRequest -UseBasicParsing -TimeoutSec 1 "http://127.0.0.1:$p").Content -like '*Server available*') } catch { return $false } }
if ($CollectorPort -eq 0) {
    $CollectorPort = 4318
    if (-not (Test-PortFree $CollectorPort)) {
        if (Test-Health 13133) { Warn 'a collector already answers on 127.0.0.1:13133 (VS Code extension or a previous install) — stop it or run both on different ports (-CollectorPort)' }
        $CollectorPort = Find-Port 4319; Warn "port 4318 is busy — using OTLP port $CollectorPort (the hook follows it via otel-attrs.json)"
    }
}
if ($HealthPort -eq 0) { $HealthPort = 13133; if (-not (Test-PortFree $HealthPort)) { $HealthPort = Find-Port 13134; Warn "port 13133 busy — health check on $HealthPort" } }
$GrpcPort = 4317; if (-not (Test-PortFree $GrpcPort)) { $GrpcPort = Find-Port 4320; Warn "port 4317 busy — OTLP/gRPC on $GrpcPort" }

# ── 1. hook ─────────────────────────────────────────────────────────────────
Log "Installing Claude Code hook -> $HookDst"
New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
Copy-Item (Join-Path $AssetDir 'hooks\otel-hook.py') $HookDst -Force
& python -I (Join-Path $AssetDir 'hooks\configure-hooks.py') install-hooks --hook-path $HookDst --windows
if ($LASTEXITCODE -ne 0) { Die 'hook configuration failed' }

# ── 2. otel-attrs.json ──────────────────────────────────────────────────────
Log "Writing $ClaudeDir\otel-attrs.json"
$attrArgs = @(); foreach ($kv in $attrs) { $attrArgs += @('--attr', $kv) }
$capArgs = @(); if ($CapturePrompts) { $capArgs = @('--capture-prompts') }
& python -I (Join-Path $AssetDir 'hooks\configure-hooks.py') write-attrs --port $CollectorPort --os-type windows @capArgs @attrArgs
if ($LASTEXITCODE -ne 0) { Die 'otel-attrs.json write failed' }

# ── 3. collector binary ─────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'bin'), (Join-Path $InstallDir 'logs') | Out-Null
$Bin = Join-Path $InstallDir 'bin\otelcol-contrib.exe'
$VersionFile = Join-Path $InstallDir 'otelcol-version.txt'
function Verify-Sha256($file, $shaFile) {
    $want = ((Get-Content $shaFile -Raw) -split '\s+')[0].ToLower()
    $have = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLower()
    if ($want -ne $have) { Die "checksum mismatch for $file" }
}
if ($OtelcolTarball) {
    Log "Extracting collector from $OtelcolTarball"
    if (-not (Test-Path $OtelcolTarball)) { Die "tarball not found: $OtelcolTarball" }
    if (Test-Path "$OtelcolTarball.sha256") { Verify-Sha256 $OtelcolTarball "$OtelcolTarball.sha256"; Log 'checksum OK' }
    & tar.exe -xzf $OtelcolTarball -C (Join-Path $InstallDir 'bin') otelcol-contrib.exe
    if ($LASTEXITCODE -ne 0) { Die 'tar extraction failed' }
    ([IO.Path]::GetFileName($OtelcolTarball) -replace '^otelcol-contrib_([0-9.]+)_.*', '$1') | Set-Content $VersionFile
} elseif ((Test-Path $Bin) -and (-not $OtelcolVersion -or ((Get-Content $VersionFile -ErrorAction SilentlyContinue) -eq $OtelcolVersion))) {
    Log "Collector binary already present ($(Get-Content $VersionFile -ErrorAction SilentlyContinue)) — skipping download"
} else {
    if (-not $OtelcolVersion) {
        Log 'Looking up the latest otelcol-contrib release'
        $OtelcolVersion = (Invoke-RestMethod -Uri $ReleasesApi -Headers @{ 'User-Agent' = $UA }).tag_name.TrimStart('v')
    }
    $file = "otelcol-contrib_${OtelcolVersion}_windows_${arch}.tar.gz"
    $url  = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$OtelcolVersion/$file"
    $tmp  = Join-Path ([IO.Path]::GetTempPath()) "dt-ai-obs-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        Log "Downloading $url"
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile (Join-Path $tmp $file) -Headers @{ 'User-Agent' = $UA }
        Invoke-WebRequest -Uri "$url.sha256" -OutFile (Join-Path $tmp "$file.sha256") -Headers @{ 'User-Agent' = $UA }
        Verify-Sha256 (Join-Path $tmp $file) (Join-Path $tmp "$file.sha256"); Log 'checksum OK'
        & tar.exe -xzf (Join-Path $tmp $file) -C (Join-Path $InstallDir 'bin') otelcol-contrib.exe
        if ($LASTEXITCODE -ne 0) { Die 'tar extraction failed' }
        $OtelcolVersion | Set-Content $VersionFile
    } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
Log "Collector: $(& $Bin --version)"

# ── 4. token → DPAPI ────────────────────────────────────────────────────────
Log "Storing the token encrypted with DPAPI (current user) in $InstallDir\ingest-token.dpapi"
$SecureToken | ConvertFrom-SecureString | Set-Content -Path (Join-Path $InstallDir 'ingest-token.dpapi')
# restrict the file to the current user as well
$acl = Get-Acl (Join-Path $InstallDir 'ingest-token.dpapi')
$acl.SetAccessRuleProtection($true, $false)
$acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($env:USERNAME, 'FullControl', 'Allow')))
Set-Acl (Join-Path $InstallDir 'ingest-token.dpapi') $acl

# ── 5. render config + wrapper ──────────────────────────────────────────────
Log "Rendering $InstallDir\otel-collector.yaml"
$renderArgs = @('--template', (Join-Path $AssetDir 'collector\otel-collector.yaml'), '--out', (Join-Path $InstallDir 'otel-collector.yaml'),
                '--endpoint', $Endpoint, '--email', "$Email", '--environment', $Environment, '--os-type', 'windows',
                '--collector-port', $CollectorPort, '--grpc-port', $GrpcPort, '--health-port', $HealthPort)
if ($CapturePrompts) { $renderArgs += '--capture-prompts' }
if ($QuietCollector) { $renderArgs += '--no-debug-exporter' }
& python -I (Join-Path $AssetDir 'collector\render-config.py') @renderArgs @attrArgs
if ($LASTEXITCODE -ne 0) { Die 'config rendering failed' }
@"
# generated by dt-ai-observability-claude install.ps1 on $((Get-Date).ToUniversalTime().ToString('s'))Z
TOKEN_BACKEND=dpapi
DT_OTLP_ENDPOINT=$Endpoint
USER_EMAIL=$Email
COLLECTOR_PORT=$CollectorPort
GRPC_PORT=$GrpcPort
HEALTH_PORT=$HealthPort
CAPTURE_PROMPTS=$([int][bool]$CapturePrompts)
"@ | Set-Content (Join-Path $InstallDir 'config.env')
Copy-Item (Join-Path $AssetDir 'collector\run-collector.ps1') (Join-Path $InstallDir 'run-collector.ps1') -Force
$env:DT_INGEST_TOKEN = 'placeholder'
& $Bin validate --config (Join-Path $InstallDir 'otel-collector.yaml')
Remove-Item Env:\DT_INGEST_TOKEN
if ($LASTEXITCODE -ne 0) { Die 'rendered collector config failed validation' }

# ── 6. native Claude Code OTel (optional) ───────────────────────────────────
if ($EnableNativeOtel) {
    Log "Enabling Claude Code native OTel export -> http://127.0.0.1:$CollectorPort"
    & python -I (Join-Path $AssetDir 'hooks\configure-hooks.py') native-otel --port $CollectorPort
}

# ── 7. scheduled task ───────────────────────────────────────────────────────
Log "Registering Scheduled Task '$TaskName' (at logon, current user)"
$wrapper = Join-Path $InstallDir 'run-collector.ps1'
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$wrapper`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -Hidden
$settings.ExecutionTimeLimit = 'PT0S'   # no time limit (New-ScheduledTaskSettingsSet cannot express "unlimited" on PS 5.1)
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -RunLevel Limited -Force | Out-Null
Get-Process otelcol-contrib -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Bin } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName $TaskName

# ── 8. health check ─────────────────────────────────────────────────────────
Log "Waiting for the collector health check on 127.0.0.1:$HealthPort"
$ok = $false
for ($i = 0; $i -lt 30 -and -not $ok; $i++) { Start-Sleep 1; $ok = Test-Health $HealthPort }
if ($ok) { Log "Collector is up: $((Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$HealthPort").Content)" }
else { Warn "collector did not become healthy in 30 s — check $InstallDir\logs\collector.log" }

@"

Done.
  OTLP endpoint (tenant) : $Endpoint
  Local collector        : http://127.0.0.1:$CollectorPort  (health: http://127.0.0.1:$HealthPort)
  Token storage          : DPAPI file $InstallDir\ingest-token.dpapi
  Hook                   : $HookDst (PreToolUse, PostToolUse, UserPromptSubmit, Stop)
  Attributes             : $ClaudeDir\otel-attrs.json
  Collector config/logs  : $InstallDir\otel-collector.yaml, $InstallDir\logs\collector.log
  Prompt capture         : $(if ($CapturePrompts) { 'ON' } else { 'off' })
  Native Claude OTel     : $(if ($EnableNativeOtel) { 'on (settings.json env)' } else { 'off (see managed-settings.example.json)' })

Next steps:
  * Restart open Claude Code sessions (Desktop Code tab and CLI) so the hooks load.
  * Import Dashboard\Developers AI Usage.json in the tenant (Dashboards -> Upload).
  * Service control:  Start-ScheduledTask -TaskName '$TaskName'   /   Stop-ScheduledTask -TaskName '$TaskName'
"@
