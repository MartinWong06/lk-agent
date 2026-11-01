# Quick health check after softphone WSS 1006 / INVITE 503/408
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot\..

Write-Host '=== docker compose ps ===' -ForegroundColor Cyan
docker compose ps

Write-Host "`n=== softphone config (iceServers / ws) ===" -ForegroundColor Cyan
docker compose exec -T softphone cat /usr/share/nginx/html/config.json 2>$null

Write-Host "`n=== asterisk pjsip media/transport ===" -ForegroundColor Cyan
docker compose exec -T asterisk grep -E '^\[''|external_media|media_address|^webrtc|^transport|rtpstart|rtpend' /etc/asterisk/pjsip.conf /etc/asterisk/rtp.conf 2>$null

Write-Host "`n=== recent logs ===" -ForegroundColor Cyan
docker compose logs --tail 40 asterisk kamailio coturn softphone 2>$null

Write-Host "`nIf asterisk/kamailio are not Up/healthy, run:" -ForegroundColor Yellow
Write-Host '  docker compose up -d --force-recreate coturn asterisk kamailio softphone'
