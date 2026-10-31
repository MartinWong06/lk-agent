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
Write-Host "SOFTPHONE_WS_SERVER=ws://${ip}:8080"
Write-Host ""
Write-Host "Then recreate and open the softphone via LAN (not localhost):"
Write-Host "  docker compose up -d --force-recreate asterisk softphone kamailio"
Write-Host "  http://${ip}:8088/"
Write-Host ""
