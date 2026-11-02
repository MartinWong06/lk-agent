#!/bin/sh
# Automated softphone media test (headless Chrome in Docker, fake mic).
# Usage (from telephony/):  sh scripts/test-media.sh [--echo-only]
set -e
cd "$(dirname "$0")/.."

HOST_IP=$(sed -n 's/^[[:space:]]*SOFTPHONE_PUBLIC_HOST[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' .env 2>/dev/null | tr -d '\r' | head -1)
if [ -z "$HOST_IP" ]; then
  echo "SOFTPHONE_PUBLIC_HOST missing in .env" >&2
  exit 2
fi
URL="https://${HOST_IP}:8443/"

docker build -q -t softphone-e2e tests/softphone-e2e >/dev/null

run() {
  echo ""
  echo "=== $3 (dial $1, ${2}s) via $URL ==="
  rc=0
  out=$(docker run --rm -e "SOFTPHONE_URL=$URL" -e "DIAL=$1" -e "HOLD_SECONDS=$2" softphone-e2e 2>&1) || rc=1
  printf '%s\n' "$out" \
    | grep -E '^    "(survivedSeconds|finalIce|inboundPackets|inboundAudioEnergy|outboundPackets|codec|selectedPair)"|RESULT:' || true
  return "$rc"
}

status=0
run 9196 "${ECHO_SECONDS:-45}" "Asterisk echo (WebRTC/ICE/RTP path)" || status=1
if [ "$1" != "--echo-only" ]; then
  run 1000 "${AI_SECONDS:-25}" "AI agent (LiveKit SIP -> agent greeting audio)" || status=1
fi
[ "$status" = 0 ] && echo "ALL MEDIA TESTS PASSED" || echo "MEDIA TEST FAILED"
exit "$status"
