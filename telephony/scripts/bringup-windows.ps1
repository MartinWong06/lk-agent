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
  # Prefer the adapter that owns the default route; skip Hyper-V/WSL/Docker/VPN virtual NICs
  # (picking vEthernet 172.x makes Asterisk advertise an IP the browser cannot reach).
  $virtual = 'vEthernet|WSL|Hyper-V|Docker|VirtualBox|VMware|Loopback|Tailscale|ZeroTier|VPN'
  $cfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
    Where-Object {
      $_.IPv4DefaultGateway -ne $null -and
      $_.NetAdapter.Status -eq 'Up' -and
      $_.InterfaceAlias -notmatch $virtual
    } |
    Sort-Object { $_.IPv4DefaultGateway.RouteMetric + $_.NetIPv4Interface.InterfaceMetric } |
    Select-Object -First 1
  $ip = $null
  if ($cfg) { $ip = ($cfg.IPv4Address | Select-Object -First 1).IPAddress }
  if (-not $ip) {
    $ip = Get-NetIPAddress -AddressFamily IPv4 |
      Where-Object {
        $_.IPAddress -notlike '127.*' -and
        $_.IPAddress -notlike '169.254.*' -and
        $_.PrefixOrigin -ne 'WellKnown' -and
        $_.InterfaceAlias -notmatch $virtual
      } |
      Sort-Object -Property InterfaceMetric |
      Select-Object -First 1 -ExpandProperty IPAddress
  }
  if (-not $ip) { throw 'Could not detect a LAN IPv4 address.' }
  return $ip
}

function Open-FirewallPorts {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) {
    Write-Host 'NOTE: not elevated - skipping Windows Firewall rules. If audio is one-way/silent, rerun'
    Write-Host '      this script as Administrator once (opens TCP 8443 and UDP 20000-20050).'
    return
  }
  $rules = @(
    @{ Name = 'EnterpriseVoice-Softphone-HTTPS'; Protocol = 'TCP'; Port = '8443' },
    @{ Name = 'EnterpriseVoice-Asterisk-RTP'; Protocol = 'UDP'; Port = '20000-20050' }
  )
  foreach ($r in $rules) {
    if (-not (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue)) {
      New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Action Allow `
        -Protocol $r.Protocol -LocalPort $r.Port -Profile Any | Out-Null
      Write-Host ('Firewall rule added: ' + $r.Name)
    }
  }
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
Set-EnvKey $envFile 'SOFTPHONE_WS_SERVER' ('wss://' + $lan + ':8443/ws')
Set-EnvKey $envFile 'SOFTPHONE_ENABLE_HTTPS' '1'
# LAN softphone media goes straight to Asterisk (ice_host_candidates); TURN is opt-in.
if (-not (Select-String -Path $envFile -Pattern '^\s*SOFTPHONE_TURN\s*=' -Quiet)) {
  Set-EnvKey $envFile 'SOFTPHONE_TURN' '0'
}

Open-FirewallPorts

Write-Host 'Stopping any previous stack (including host-asterisk overlay and coturn)...'
[void](Invoke-Docker -AllowFail -DockerArgs @('compose','-f','docker-compose.yml','-f','docker-compose.host-asterisk.yml','--profile','turn','down','--remove-orphans'))
[void](Invoke-Docker -AllowFail -DockerArgs @('compose','-f','docker-compose.yml','--profile','turn','down','--remove-orphans'))

Write-Host 'Building/starting asterisk + kamailio + softphone (bridge)...'
[void](Invoke-Docker -DockerArgs @('compose','-f','docker-compose.yml','up','-d','--build','--force-recreate','asterisk','kamailio','softphone'))

# Always rebuild the agent: agent.py is baked into the image, so --no-build silently
# keeps old code (e.g. a previous model/noise-cancellation setup).
Write-Host 'Building/starting agent...'
$agentOk = Invoke-Docker -AllowFail -DockerArgs @('compose','-f','docker-compose.yml','up','-d','--build','--force-recreate','--scale','agent=1','agent')
if (-not $agentOk) {
  Write-Host 'Agent build failed (registry/network) - falling back to the existing local image...'
  $agentOk = Invoke-Docker -AllowFail -DockerArgs @('compose','-f','docker-compose.yml','up','-d','--no-build','--force-recreate','--scale','agent=1','agent')
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
Write-Host 'Expect INVITE accepted then iceConnectionState=connected and remote track unmuted.'
Write-Host ''
Write-Host 'Automated check (headless browser, echo 9196 + AI 1000):'
Write-Host '  powershell -ExecutionPolicy Bypass -File .\scripts\test-media.ps1'
