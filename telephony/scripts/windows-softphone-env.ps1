# Prints SOFTPHONE_PUBLIC_HOST / media env for Docker Desktop WebRTC on Windows.
# Usage (from telephony/):
#   powershell -ExecutionPolicy Bypass -File .\scripts\windows-softphone-env.ps1

$ErrorActionPreference = "Stop"
$ip = Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object {
    $_.IPAddress -notlike "127.*" -and
    $_.IPAddress -notlike "169.254.*" -and
    $_.PrefixOrigin -ne "WellKnown"
  } |
  Sort-Object -Property InterfaceMetric |
  Select-Object -First 1 -ExpandProperty IPAddress

if (-not $ip) {
  Write-Error "Could not detect a LAN IPv4 address."
}

Write-Host ""
Write-Host "Add these lines to telephony\.env :"
Write-Host "SOFTPHONE_PUBLIC_HOST=$ip"
Write-Host "SOFTPHONE_MEDIA_IP=$ip"
Write-Host "SOFTPHONE_WS_SERVER=wss://${ip}:8443/ws"
Write-Host "SOFTPHONE_ENABLE_HTTPS=1"
Write-Host ""
Write-Host "Then recreate and open the softphone via HTTPS LAN (not localhost / not plain http):"
Write-Host "  docker compose up -d --force-recreate asterisk softphone kamailio"
Write-Host "  https://${ip}:8443/"
Write-Host ""
