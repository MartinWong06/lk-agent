# Quick health check for silent calls / WSS 1006 / INVITE 503/408
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot\..

Write-Host '=== docker compose ps ===' -ForegroundColor Cyan
docker compose ps

Write-Host "`n=== .env media settings (must be this PC's LAN IP) ===" -ForegroundColor Cyan
Select-String -Path .env -Pattern '^(SOFTPHONE_PUBLIC_HOST|SOFTPHONE_MEDIA_IP|SOFTPHONE_WS_SERVER|SOFTPHONE_TURN|EXTERNAL_SIP_IP|LIVEKIT_SIP_HOST)=' |
  ForEach-Object { $_.Line }

Write-Host "`n=== softphone config (ws / iceServers) ===" -ForegroundColor Cyan
docker compose exec -T softphone cat /usr/share/nginx/html/config.json 2>$null

Write-Host "`n=== asterisk media config (expect '<container-ip> => <LAN>,include_local_address') ===" -ForegroundColor Cyan
docker compose exec -T asterisk sh -c "grep -E 'external_media|media_address|^allow|rtpstart|rtpend|=>' /etc/asterisk/pjsip.conf /etc/asterisk/rtp.conf" 2>$null

Write-Host "`n=== kamailio WS listener + record_route ===" -ForegroundColor Cyan
docker compose exec -T kamailio sh -c "bash -c ':</dev/tcp/127.0.0.1/8080' && echo 'WS :8080 listening' || echo 'WS :8080 NOT listening'; grep -c record_route /tmp/kamailio.cfg /etc/kamailio/kamailio.cfg" 2>$null

Write-Host "`n=== recent logs (errors / call teardown) ===" -ForegroundColor Cyan
docker compose logs --tail 200 asterisk kamailio softphone 2>$null |
  Select-String -Pattern 'ERROR|WARNING|dispatch|Spawn|Hangup|503|408|1006|tcp_init|ice_host' |
  Select-Object -Last 40 | ForEach-Object { $_.Line }
docker compose logs --tail 60 agent 2>$null |
  Select-String -Pattern 'Using inference|user said|agent_state|session error|no agent speaking|registered worker' |
  ForEach-Object { $_.Line }

Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host '  Full reset:      powershell -ExecutionPolicy Bypass -File .\scripts\bringup-windows.ps1'
Write-Host '  Automated test:  powershell -ExecutionPolicy Bypass -File .\scripts\test-media.ps1'
