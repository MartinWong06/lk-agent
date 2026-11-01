# End-to-end Windows Docker Desktop softphone bring-up (bridge networking).
# Do NOT use docker-compose.host-asterisk.yml on Docker Desktop Windows.
#
# Usage (from telephony/):
#   powershell -ExecutionPolicy Bypass -File .\scripts\bringup-windows.ps1

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Invoke-Docker {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$DockerArgs)
  # Docker prints progress to stderr; with $ErrorActionPreference=Stop that becomes
  # a terminating NativeCommandError on Windows PowerShell 5.1.
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  & docker @DockerArgs
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  if ($code -ne 0) {
    throw "docker $($DockerArgs -join ' ') failed with exit code $code"
  }
}

function Get-LanIPv4 {
  $ip = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
      $_.IPAddress -notlike "127.*" -and
      $_.IPAddress -notlike "169.254.*" -and
      $_.PrefixOrigin -ne "WellKnown"
    } |
    Sort-Object -Property InterfaceMetric |
    Select-Object -First 1 -ExpandProperty IPAddress
  if (-not $ip) { throw "Could not detect a LAN IPv4 address." }
  return $ip
}

function Set-EnvKey([string]$path, [string]$key, [string]$value) {
  if (-not (Test-Path $path)) {
    Copy-Item ".env.example" $path
  }
  $lines = @(Get-Content $path)
  $found = $false
  $escaped = [regex]::Escape($key)
  $out = foreach ($line in $lines) {
    if ($line -match "^\s*#?\s*$escaped\s*=") {
      $found = $true
      "$key=$value"
    } else {
      $line
    }
  }
  if (-not $found) {
    $out += "$key=$value"
  }
  Set-Content -Path $path -Value $out -Encoding UTF8
}

$lan = Get-LanIPv4
$envFile = Join-Path $Root ".env"
Write-Host "LAN IP: $lan"
Write-Host "Updating $envFile ..."
Set-EnvKey $envFile "SOFTPHONE_PUBLIC_HOST" $lan
Set-EnvKey $envFile "SOFTPHONE_MEDIA_IP" $lan
Set-EnvKey $envFile "SOFTPHONE_WS_SERVER" "ws://${lan}:8080"

Write-Host "Stopping any previous stack (including host-asterisk overlay)..."
try {
  Invoke-Docker compose -f docker-compose.yml -f docker-compose.host-asterisk.yml down
} catch {
  Write-Host "host-asterisk down skipped: $($_.Exception.Message)"
}
Invoke-Docker compose -f docker-compose.yml down

Write-Host "Starting BRIDGE stack (ASTERISK_HOST=asterisk, no host overlay)..."
Invoke-Docker compose -f docker-compose.yml up -d --build --force-recreate --scale agent=1

Write-Host "Waiting for containers..."
Start-Sleep -Seconds 8
Invoke-Docker compose -f docker-compose.yml ps

Write-Host ""
Write-Host "Kamailio dispatcher target (must be sip:asterisk:5060, NOT host.docker.internal):"
$prev = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$kamLogs = & docker compose -f docker-compose.yml logs kamailio --tail 40 2>&1 |
  ForEach-Object { "$_" }
$ErrorActionPreference = $prev
$kamLogs | Select-String -Pattern "dispatch|ASTERISK_HOST|host.docker" | ForEach-Object { $_.Line }

Write-Host ""
Write-Host "Open softphone at:  http://${lan}:8088/"
Write-Host "Do NOT use http://localhost:8088/ (ICE will fail)."
Write-Host "Register -> Call AI once. Expect INVITE progress/accepted then iceConnectionState=connected."
