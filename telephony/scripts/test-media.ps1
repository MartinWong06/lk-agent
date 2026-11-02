# Automated softphone media test (headless Chrome in Docker, fake mic).
# Registers 1001, dials, and checks ICE + inbound RTP + audio energy.
#
# Usage (from telephony/):
#   powershell -ExecutionPolicy Bypass -File .\scripts\test-media.ps1            # echo 9196 + AI 1000
#   powershell -ExecutionPolicy Bypass -File .\scripts\test-media.ps1 -EchoOnly
#
# ASCII-only script body so Windows PowerShell 5.1 parses safely.
param(
  [switch]$EchoOnly,
  [int]$EchoSeconds = 45,
  [int]$AiSeconds = 25
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$envFile = Join-Path $Root '.env'
$hostIp = $null
if (Test-Path $envFile) {
  $line = Select-String -Path $envFile -Pattern '^\s*SOFTPHONE_PUBLIC_HOST\s*=\s*(\S+)' | Select-Object -First 1
  if ($line) { $hostIp = $line.Matches[0].Groups[1].Value }
}
if (-not $hostIp) { throw 'SOFTPHONE_PUBLIC_HOST missing in .env - run scripts\bringup-windows.ps1 first.' }
$url = 'https://' + $hostIp + ':8443/'

Write-Host ('Building softphone-e2e test image ...')
& docker build -q -t softphone-e2e (Join-Path $Root 'tests\softphone-e2e') | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'docker build softphone-e2e failed' }

function Invoke-MediaTest([string]$dial, [int]$seconds, [string]$label) {
  Write-Host ''
  Write-Host ('=== ' + $label + ' (dial ' + $dial + ', ' + $seconds + 's) via ' + $url + ' ===') -ForegroundColor Cyan
  $out = & docker run --rm -e ('SOFTPHONE_URL=' + $url) -e ('DIAL=' + $dial) -e ('HOLD_SECONDS=' + $seconds) softphone-e2e 2>&1
  $code = $LASTEXITCODE
  $out | Select-String -Pattern '^    "(survivedSeconds|finalIce|inboundPackets|inboundAudioEnergy|outboundPackets|codec|selectedPair)"|RESULT:' |
    ForEach-Object { $_.Line }
  return ($code -eq 0)
}

$echoOk = Invoke-MediaTest '9196' $EchoSeconds 'Asterisk echo (WebRTC/ICE/RTP path)'
$aiOk = $true
if (-not $EchoOnly) {
  $aiOk = Invoke-MediaTest '1000' $AiSeconds 'AI agent (Asterisk -> LiveKit SIP -> agent greeting audio)'
}

Write-Host ''
if ($echoOk -and $aiOk) {
  Write-Host 'ALL MEDIA TESTS PASSED' -ForegroundColor Green
  exit 0
}
if (-not $echoOk) {
  Write-Host 'Echo failed: browser<->Asterisk media is broken. Run scripts\doctor-windows.ps1' -ForegroundColor Red
} else {
  Write-Host 'Echo passed but AI failed: check `docker compose logs agent asterisk --tail 80` (LiveKit SIP/agent/Inference).' -ForegroundColor Red
}
exit 1
