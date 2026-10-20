<#
.SYNOPSIS
  One-command import of the claude.ai Team spend CSV into Dynatrace (layer 3, source=team_csv). Windows / PowerShell 5.1+.

.DESCRIPTION
  Same behaviour as import-team-csv.sh:
    date      yesterday (UTC) unless -Date is given (the claude.ai export covers up to yesterday)
    tenant    from the layer 1/2 install (%USERPROFILE%\.dt-ai-obs\config.env) or -Tenant / DT_TENANT_URL
    delivery  dtctl (current or -Context) with your own login, no token; otherwise an ingest token with bizevents.ingest
              (env DT_BIZEVENTS_TOKEN, a DPAPI file saved by -SaveToken, or a hidden prompt)
    safety    preview + confirmation before anything is sent (-Yes skips it); same-day re-import overwrites via dedup.key

.EXAMPLE
  .\import-team-csv.ps1 .\spend-export.csv
  .\import-team-csv.ps1 .\spend-export.csv -Date 2026-10-18 -OrgId acme -Yes
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Csv,
    [string]$Date,
    [string]$OrgId = 'team',
    [string]$Tenant = $env:DT_TENANT_URL,
    [string]$Context,
    [switch]$Token,
    [switch]$SaveToken,
    [switch]$Yes,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Log($m)  { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Warning $m }
function Die($m)  { Write-Host "error: $m" -ForegroundColor Red; exit 1 }

$Here       = $PSScriptRoot
$Importer   = Join-Path $Here 'import_team_spend.py'
$IngestJs   = Join-Path $Here 'ingest_events.js'
$InstallDir = if ($env:DT_AI_OBS_DIR) { $env:DT_AI_OBS_DIR } else { Join-Path $env:USERPROFILE '.dt-ai-obs' }
$TokenFile  = Join-Path $InstallDir 'bizevents-token.dpapi'

if (-not (Test-Path $Csv)) { Die "file not found: $Csv" }
if (-not (Test-Path $Importer)) { Die "importer not found next to this script: $Importer" }
$py = Get-Command python -ErrorAction SilentlyContinue; if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $py) { Die 'Python 3 is required (python.org or Microsoft Store)' }
$Csv = (Resolve-Path $Csv).Path

# date
$today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
if (-not $Date) { $Date = (Get-Date).ToUniversalTime().AddDays(-1).ToString('yyyy-MM-dd') }
try { [void][datetime]::ParseExact($Date, 'yyyy-MM-dd', $null) } catch { Die "-Date must be yyyy-MM-dd (got '$Date')" }
if ($Date -gt $today) { Die "-Date $Date is in the future (today is $today UTC)" }
if ($Date -eq $today) { Warn "-Date is today ($today): the claude.ai export normally covers up to yesterday" }
$fileDay = (Get-Item $Csv).LastWriteTimeUtc.ToString('yyyy-MM-dd')
$age = ([datetime]$fileDay - [datetime]$Date).Days
if ($age -gt 2 -or $age -lt 0) { Warn "the file was last modified on $fileDay (UTC) but -Date is $Date: check that this export really covers $Date" }

# preview
Log "Preview of $Csv for usage day $Date (org.id=$OrgId)"
$previewRaw = & $py.Source -I $Importer --csv $Csv --date $Date --org-id $OrgId --preview 2>$null
if ($LASTEXITCODE -ne 0) { Die "the file does not look like the claude.ai Team spend export (run: python $Importer --csv '$Csv' --date $Date --preview)" }
$p = $previewRaw | ConvertFrom-Json
Write-Host ("  events (user x product x model): {0}   users: {1}   requests: {2}   tokens: {3:N0}" -f $p.events, $p.users, $p.requests, $p.tokens_total)
Write-Host ("  net spend: US$ {0:N2}   gross: US$ {1:N2}" -f $p.net_spend_usd, $p.gross_spend_usd)
foreach ($prop in ($p.by_product.PSObject.Properties | Sort-Object { -$_.Value.cost_usd })) {
    $d = $prop.Value
    Write-Host ("    {0,-12} events={1,-4} requests={2,-7} tokens={3,-12:N0} US$ {4:N2}" -f $prop.Name, $d.events, $d.requests, $d.tokens, $d.cost_usd)
}
Write-Host ("  models: " + ($p.models -join ', '))
if ($p.rows_without_email) { Write-Host "  note: $($p.rows_without_email) row(s) without e-mail are kept as user.email=null" }
if ($p.unknown_products)   { Write-Host ("  note: unknown product names kept as product=other: " + ($p.unknown_products -join ', ')) }
if ($p.events -eq 0) { Die 'nothing to import: the CSV has no data rows' }
Write-Host '  re-importing the same day overwrites earlier rows (dedup.key); nothing is duplicated.'
if ($DryRun) { Log '-DryRun: nothing sent'; exit 0 }

# delivery
$method = ''
$dtctl = Get-Command dtctl -ErrorAction SilentlyContinue
if (-not $Token -and $dtctl) {
    if ($Context) { $method = 'dtctl' }
    else { $cur = (& dtctl config current-context 2>$null); if ($LASTEXITCODE -eq 0 -and $cur) { $Context = "$cur".Trim(); $method = 'dtctl' } }
}
if (-not $method) {
    $method = 'token'
    if (-not $Tenant -and (Test-Path (Join-Path $InstallDir 'config.env'))) {
        $line = Get-Content (Join-Path $InstallDir 'config.env') | Where-Object { $_ -like 'DT_OTLP_ENDPOINT=*' } | Select-Object -First 1
        if ($line) { $Tenant = ($line -replace '^DT_OTLP_ENDPOINT=', '').Trim("'", '"') -replace '/api/v2/otlp/*$', '' }
    }
    if (-not $Tenant) { Die 'no tenant: pass -Tenant https://<env>.live.dynatrace.com (or install dtctl and log in: then no token is needed)' }
    if ($Tenant -notlike 'https://*' -and $Tenant -notlike 'http://127.0.0.1*' -and $Tenant -notlike 'http://localhost*') { Die "-Tenant must be https:// (got $Tenant)" }
}

if ($method -eq 'dtctl') { Log "Delivery: dtctl exec function (context '$Context', your own login; no token)" }
else { Log "Delivery: bizevents ingest API on $Tenant (token)" }
if (-not $Yes) {
    $ans = Read-Host 'Send these events to Dynatrace? [y/N]'
    if ($ans -notin @('y', 'Y', 'yes', 's', 'S', 'sim')) { Write-Host 'aborted, nothing sent'; exit 0 }
}

if ($method -eq 'dtctl') {
    if (-not (Test-Path $IngestJs)) { Die "helper not found: $IngestJs" }
    $events = & $py.Source -I $Importer --csv $Csv --date $Date --org-id $OrgId --dry-run 2>$null | Out-String
    if ($LASTEXITCODE -ne 0) { Die 'importer failed' }
    $payload = '{"events":' + $events.Trim() + '}'
    $res = $payload | & dtctl --plain --context $Context exec function -f $IngestJs --data - -o json
    if ($LASTEXITCODE -ne 0) { Die 'dtctl ingest failed (is the context logged in? does your user have storage:events:write?)' }
    Write-Host "  result: $($res -join '')"
    Log "Done. Check: dtctl --context $Context query 'fetch bizevents, from:now()-1h | filter event.type == ""claude.usage.daily"" and source == ""team_csv"" | summarize count(), by:{usage.date, org.id}'"
} else {
    $plain = $env:DT_BIZEVENTS_TOKEN
    if (-not $plain -and (Test-Path $TokenFile)) {
        $sec = Get-Content $TokenFile | ConvertTo-SecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if (-not $plain) {
        $sec = Read-Host 'Dynatrace API token with scope bizevents.ingest (hidden)' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        if (-not $SaveToken) { $s = Read-Host 'Save it (DPAPI, current user) for next time? [y/N]'; if ($s -in @('y', 'Y', 'yes', 's', 'S', 'sim')) { $SaveToken = $true } }
    }
    $plain = ($plain -replace '\s', '')
    if ($plain -notmatch '^dt0c01\.[A-Za-z0-9]{24}\.[A-Za-z0-9]{64}$') { Die "token format invalid: expected dt0c01.<24 chars>.<64 chars> (got $($plain.Length) chars; pasted twice?)" }
    if ($SaveToken) {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
        ConvertTo-SecureString -String $plain -AsPlainText -Force | ConvertFrom-SecureString | Set-Content -Path $TokenFile
        Log "Token saved (DPAPI, current user): $TokenFile"
    }
    $env:DT_BIZEVENTS_TOKEN = $plain
    $extra = @(); if ($Tenant -like 'http://*') { $extra += '--allow-http' }
    try {
        & $py.Source -I $Importer --csv $Csv --date $Date --org-id $OrgId --tenant $Tenant --token-env DT_BIZEVENTS_TOKEN @extra
        if ($LASTEXITCODE -ne 0) { Die 'import failed (see the message above)' }
    } finally { Remove-Item Env:\DT_BIZEVENTS_TOKEN -ErrorAction SilentlyContinue; Remove-Variable plain -ErrorAction SilentlyContinue }
    Log 'Done. In Dynatrace: fetch bizevents, from:now()-1h | filter event.type == "claude.usage.daily" and source == "team_csv" | summarize count(), by:{usage.date, org.id}'
}
