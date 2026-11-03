#!/bin/sh
# Automated softphone media test (headless Chrome in Docker, fake mic).
# Usage (from telephony/):  sh scripts/test-media.sh [--echo-only]
set -e
cd "$(dirname "$0")/.."

. scripts/e2e-env.sh

run() {
  echo ""
  echo "=== $3 (dial $1, ${2}s) via $URL ==="
  rc=0
  # shellcheck disable=SC2086
  out=$(docker run --rm $E2E_ENV -e "DIAL=$1" -e "HOLD_SECONDS=$2" softphone-e2e 2>&1) || rc=1
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
