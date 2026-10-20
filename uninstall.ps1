<#
.SYNOPSIS
  Dynatrace AI Observability for Claude — uninstaller (Windows)
.DESCRIPTION
  Stops and removes the Scheduled Task, the DPAPI-encrypted token, the Claude
  Code hook entries this asset added, otel-attrs.json and %USERPROFILE%\.dt-ai-obs.
.EXAMPLE
  .\uninstall.ps1 -Yes            # no confirmation
  .\uninstall.ps1 -KeepHooks -KeepBinary
#>
[CmdletBinding()]
param([switch]$KeepHooks, [switch]$KeepBinary, [switch]$Yes)
$ErrorActionPreference = 'Continue'
$AssetDir   = $PSScriptRoot
$InstallDir = if ($env:DT_AI_OBS_DIR) { $env:DT_AI_OBS_DIR } else { Join-Path $env:USERPROFILE '.dt-ai-obs' }
if (-not $InstallDir -or $InstallDir.TrimEnd('\') -in @($env:USERPROFILE, $env:SystemDrive, '')) { throw "refusing to operate on '$InstallDir'" }
$ClaudeDir  = Join-Path $env:USERPROFILE '.claude'
$TaskName   = 'Dynatrace AI Observability (Claude) collector'
function Log($m) { Write-Host "==> $m" -ForegroundColor Cyan }

if (-not $Yes) {
    $a = Read-Host 'Remove the Dynatrace AI Observability for Claude collector, token and hooks? [y/N]'
    if ($a -notmatch '^[Yy]') { Write-Host 'aborted'; exit 0 }
}
Log "Stopping and removing Scheduled Task '$TaskName'"
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
$bin = Join-Path $InstallDir 'bin\otelcol-contrib.exe'
Get-Process otelcol-contrib -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $bin } | Stop-Process -Force -ErrorAction SilentlyContinue

Remove-Item (Join-Path $InstallDir 'ingest-token.dpapi') -Force -ErrorAction SilentlyContinue

if (-not $KeepHooks) {
    Log 'Removing Claude Code hook entries and files'
    & python -I (Join-Path $AssetDir 'hooks\configure-hooks.py') remove-hooks
    $port = 4318
    $cfg = Join-Path $InstallDir 'config.env'
    if (Test-Path $cfg) { $m = Select-String -Path $cfg -Pattern '^COLLECTOR_PORT=(\d+)'; if ($m) { $port = [int]$m.Matches[0].Groups[1].Value } }
    & python -I (Join-Path $AssetDir 'hooks\configure-hooks.py') native-otel --port $port --remove
    $hook = Join-Path $ClaudeDir 'otel-hook.py'
    if ((Test-Path $hook) -and -not (Select-String -Path $hook -Pattern 'dt-ai-observability-claude' -Quiet)) {
        Write-Warning "$hook was not installed by this asset (VS Code extension?) — leaving it in place"
    } else { Remove-Item $hook -Force -ErrorAction SilentlyContinue }
    Remove-Item (Join-Path $ClaudeDir 'otel-attrs.json') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $ClaudeDir 'otel-state') -Recurse -Force -ErrorAction SilentlyContinue
} else { Log 'Keeping Claude Code hooks (-KeepHooks)' }

if (Test-Path $InstallDir) {
    if ($KeepBinary) {
        Log "Removing $InstallDir (keeping bin\)"
        Get-ChildItem $InstallDir -Force | Where-Object { $_.Name -ne 'bin' } | Remove-Item -Recurse -Force
    } else { Log "Removing $InstallDir"; Remove-Item $InstallDir -Recurse -Force }
}
Write-Host 'Done. Restart open Claude Code sessions so the removed hooks stop loading.'
