# End-to-end Windows Docker Desktop softphone bring-up (bridge networking).
# Do NOT use docker-compose.host-asterisk.yml on Docker Desktop Windows.
#
# Usage (from telephony/):
#   powershell -ExecutionPolicy Bypass -File .\scripts\bringup-windows.ps1
#
# ASCII-only script body so Windows PowerShell 5.1 (ANSI default) parses safely.

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Invoke-Docker {
  param(
    [switch]$AllowFail,
    [Parameter(Mandatory = $true)][string[]]$DockerArgs
  )
  # Docker prints progress to stderr; with ErrorActionPreference=Stop that becomes
  # a terminating NativeCommandError on Windows PowerShell 5.1.
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  & docker @DockerArgs
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  if ($code -ne 0) {
    $msg = "docker $($DockerArgs -join ' ') failed with exit code $code"
    if ($AllowFail) {
      Write-Host "WARNING: $msg"
      return $false
    }
    throw $msg
  }
  return $true
}

function Get-LanIPv4 {
  $ip = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
      $_.IPAddress -notlike '127.*' -and
      $_.IPAddress -notlike '169.254.*' -and
      $_.PrefixOrigin -ne 'WellKnown'
    } |
    Sort-Object -Property InterfaceMetric |
    Select-Object -First 1 -ExpandProperty IPAddress
  if (-not $ip) { throw 'Could not detect a LAN IPv4 address.' }
  return $ip
}

function Set-EnvKey([string]$path, [string]$key, [string]$value) {
  if (-not (Test-Path $path)) {
    Copy-Item '.env.example' $path
  }
  $lines = @(Get-Content $path)
  $found = $false
  $escaped = [regex]::Escape($key)
  $out = foreach ($line in $lines) {
    if ($line -match ("^\s*#?\s*" + $escaped + "\s*=")) {
      $found = $true
      ($key + '=' + $value)
    } else {
      $line
    }
  }
  if (-not $found) {
    $out += ($key + '=' + $value)
  }
  Set-Content -Path $path -Value $out -Encoding ASCII
}

$lan = Get-LanIPv4
$envFile = Join-Path $Root '.env'
Write-Host ('LAN IP: ' + $lan)
Write-Host ('Updating ' + $envFile + ' ...')
Set-EnvKey $envFile 'SOFTPHONE_PUBLIC_HOST' $lan
Set-EnvKey $envFile 'SOFTPHONE_MEDIA_IP' $lan
# Coturn external-ip must match LAN (used by browser ICE + compose command)
if (-not (Select-String -Path $envFile -Pattern '^TURN_USER=' -Quiet)) {
  Add-Content -Path $envFile -Value "TURN_USER=softphone"
}
if (-not (Select-String -Path $envFile -Pattern '^TURN_PASSWORD=' -Quiet)) {
  Add-Content -Path $envFile -Value "TURN_PASSWORD=change-me-turn"
}
Set-EnvKey $envFile 'SOFTPHONE_WS_SERVER' ('wss://' + $lan + ':8443/ws')
Set-EnvKey $envFile 'SOFTPHONE_ENABLE_HTTPS' '1'

Write-Host 'Stopping any previous stack (including host-asterisk overlay)...'
[void](Invoke-Docker -AllowFail -DockerArgs @('compose','-f','docker-compose.yml','-f','docker-compose.host-asterisk.yml','down'))
[void](Invoke-Docker -DockerArgs @('compose','-f','docker-compose.yml','down'))

Write-Host 'Building/starting softphone + kamailio + asterisk (bridge)...'
[void](Invoke-Docker -DockerArgs @('compose','-f','docker-compose.yml','up','-d','--build','--force-recreate','softphone','kamailio','asterisk'))

Write-Host 'Starting agent (reuse local image if present; rebuild only if needed)...'
$agentOk = Invoke-Docker -AllowFail -DockerArgs @('compose','-f','docker-compose.yml','up','-d','--no-build','--scale','agent=1','agent')
if (-not $agentOk) {
  Write-Host 'No usable agent image - trying rebuild from Docker Hub astral/uv base...'
  $agentOk = Invoke-Docker -AllowFail -DockerArgs @('compose','-f','docker-compose.yml','build','agent')
  if ($agentOk) {
    $agentOk = Invoke-Docker -AllowFail -DockerArgs @('compose','-f','docker-compose.yml','up','-d','--scale','agent=1','agent')
  }
}
if (-not $agentOk) {
  Write-Host 'WARNING: agent did not start (registry/network). Softphone SIP path is still up.'
  Write-Host 'AI audio needs the agent. Retry later or build when Docker Hub/ghcr is reachable.'
}

Write-Host 'Waiting for containers...'
Start-Sleep -Seconds 8
[void](Invoke-Docker -DockerArgs @('compose','-f','docker-compose.yml','ps'))

Write-Host ''
Write-Host 'Kamailio dispatcher target (must be sip:asterisk:5060, NOT host.docker.internal):'
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$kamLogs = & docker @('compose','-f','docker-compose.yml','logs','kamailio','--tail','40') 2>&1 |
  ForEach-Object { "$_" }
$ErrorActionPreference = $prev
$kamLogs | Select-String -Pattern 'dispatch|ASTERISK_HOST|host.docker' | ForEach-Object { $_.Line }

Write-Host ''
Write-Host ('Open softphone at:  https://' + $lan + ':8443/')
Write-Host '  step1: Accept the self-signed certificate warning (Advanced -> Proceed)'
Write-Host '  step2: Allow microphone'
Write-Host '  step3: Register -> Call AI once'
Write-Host 'Do NOT use http://localhost:8088/ (ICE fails) or plain http://LAN:8088/ (mic blocked).'
Write-Host 'Expect INVITE progress/accepted then iceConnectionState=connected.'
