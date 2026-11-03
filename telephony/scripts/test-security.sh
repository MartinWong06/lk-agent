#!/bin/sh
# Security checks against the running stack (headless Chrome + SIP.js in Docker):
# SIP digest auth, no open relay, brute-force lockout, basic auth, headers, and
# (PRODUCTION=1) that Kamailio SIP/WS ports are not published.
# Usage (from telephony/):  sh scripts/test-security.sh
set -e
cd "$(dirname "$0")/.."
. scripts/e2e-env.sh

status=0
if [ "$E2E_PRODUCTION" = "1" ]; then
  echo "=== published ports on $HOST_IP ==="
  for p in 5060 8080 8088 8443; do
    if timeout 3 bash -c ": </dev/tcp/$HOST_IP/$p" 2>/dev/null; then
      echo "FAIL  tcp/$p is reachable (should be closed)"
      status=1
    else
      echo "PASS  tcp/$p closed"
    fi
  done
fi

echo ""
echo "=== SIP / HTTP checks via $URL ==="
extra=""
[ "$E2E_PRODUCTION" = "1" ] && extra="-e EXPECT_PRODUCTION=1"
# shellcheck disable=SC2086
docker run --rm $E2E_ENV $extra --entrypoint node softphone-e2e /e2e/security.mjs || status=1

[ "$status" = 0 ] && echo "ALL SECURITY CHECKS PASSED" || echo "SECURITY CHECKS FAILED"
exit "$status"
