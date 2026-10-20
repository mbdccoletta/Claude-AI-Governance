# Service wrapper (Windows): decrypts the Dynatrace ingest token (DPAPI, current
# user) and starts the local OpenTelemetry Collector. Installed by install.ps1 to
# %USERPROFILE%\.dt-ai-obs\run-collector.ps1 and run by a Scheduled Task at logon.
$ErrorActionPreference = 'Stop'
$Dir = if ($env:DT_AI_OBS_DIR) { $env:DT_AI_OBS_DIR } else { Join-Path $env:USERPROFILE '.dt-ai-obs' }
$secure = Get-Content -Path (Join-Path $Dir 'ingest-token.dpapi') -Raw | ConvertTo-SecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try   { $env:DT_INGEST_TOKEN = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
if (-not $env:DT_INGEST_TOKEN) { throw 'run-collector: empty ingest token; re-run install.ps1' }
$log = Join-Path $Dir 'logs\collector.log'
if ((Test-Path $log) -and ((Get-Item $log).Length -gt 50MB)) { Move-Item -Force $log "$log.1" }
# the collector logs to stderr; with 'Stop' PowerShell 5.1 would turn its first line into a NativeCommandError
$ErrorActionPreference = 'Continue'
& (Join-Path $Dir 'bin\otelcol-contrib.exe') --config (Join-Path $Dir 'otel-collector.yaml') 2>&1 |
    Tee-Object -FilePath $log -Append | Out-Null
