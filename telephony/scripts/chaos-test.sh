#!/bin/sh
# Chaos / self-healing proof for the telephony stack.
#
# Usage (from telephony/):
#   sh scripts/chaos-test.sh
#   E2E_NETWORK=host sh scripts/chaos-test.sh   # recommended on a VPS
#
# Writes reports/self-healing-<UTC>.md with per-scenario pass/fail and MTTR.
set -eu
cd "$(dirname "$0")/.."
. scripts/e2e-env.sh

COMPOSE="docker compose"
REPORT_DIR=reports
mkdir -p "$REPORT_DIR"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
REPORT="$REPORT_DIR/self-healing-$STAMP.md"
TARGET_MTTR=60

pass_n=0
fail_n=0
ROWS=""

say() { printf '\n==> %s\n' "$*"; }

wait_healthy() {
  name="$1"
  deadline=$(( $(date +%s) + ${2:-90} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || echo missing)
    case "$st" in
      healthy|running) echo "$st"; return 0 ;;
    esac
    sleep 2
  done
  echo "$st"
  return 1
}

started_at() {
  docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null || echo ""
}

probe_invite() {
  # shellcheck disable=SC2086
  docker run --rm $E2E_DOCKER_OPTS $E2E_ENV -e PROBE=invite -e DIAL="${1:-9196}" \
    --entrypoint node softphone-e2e /e2e/probe.mjs 2>/dev/null | grep '^PROBE' | tail -1
}

echo_media() {
  # shellcheck disable=SC2086
  docker run --rm $E2E_DOCKER_OPTS $E2E_ENV -e DIAL=9196 -e HOLD_SECONDS=12 softphone-e2e 2>/dev/null \
    | grep -E '^RESULT:' | tail -1
}

record() {
  name="$1"
  ok="$2"
  mttr="$3"
  detail="$4"
  if [ "$ok" = "1" ]; then
    pass_n=$((pass_n + 1))
    mark=PASS
  else
    fail_n=$((fail_n + 1))
    mark=FAIL
  fi
  ROWS="$ROWS
| $name | $mark | ${mttr}s | $detail |"
  printf '  [%s] %s (mttr=%ss) %s\n' "$mark" "$name" "$mttr" "$detail"
}

# ---------- baseline ----------
say "Baseline: stack healthy + echo call"
$COMPOSE up -d autoheal asterisk kamailio softphone >/dev/null
wait_healthy enterprise-voice-kamailio-1 60 >/dev/null
wait_healthy enterprise-voice-asterisk-1 60 >/dev/null
wait_healthy enterprise-voice-softphone-1 30 >/dev/null
base=$(echo_media || true)
case "$base" in
  *PASS*) record "baseline-echo" 1 0 "$base" ;;
  *) record "baseline-echo" 0 0 "${base:-no RESULT}" ;;
esac

# ---------- 1. freeze Kamailio (SIGSTOP) → unhealthy → autoheal ----------
# Freezing leaves the container "running" so Docker restart-policy never fires;
# the HTTP healthcheck fails and autoheal recreates it. (Some DinD hosts also
# ignore restart-unless-stopped after `docker kill`, so this is the portable proof.)
say "1) freeze Kamailio (SIGSTOP) — expect autoheal restart + invite 200"
t0=$(date +%s)
before=$(started_at enterprise-voice-kamailio-1)
docker exec enterprise-voice-kamailio-1 pkill -STOP -x kamailio 2>/dev/null || true
ok=0
mttr=0
detail="autoheal did not restart"
for i in $(seq 1 36); do
  sleep 5
  after=$(started_at enterprise-voice-kamailio-1)
  st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' enterprise-voice-kamailio-1 2>/dev/null || echo missing)
  if [ -n "$after" ] && [ "$after" != "$before" ] && [ "$st" = "healthy" ]; then
    mttr=$(( $(date +%s) - t0 ))
    inv=$(probe_invite)
    case "$inv" in
      *'"status":200'*) ok=1; detail="autoheal restarted; $inv" ;;
      *) detail="restarted but invite failed: $inv" ;;
    esac
    break
  fi
done
$COMPOSE up -d kamailio >/dev/null 2>&1 || true
wait_healthy enterprise-voice-kamailio-1 60 >/dev/null || true
record "freeze-kamailio-autoheal" "$ok" "$mttr" "$detail"

# ---------- 3. stop Asterisk (fast 503 + recover) ----------
say "3) stop Asterisk — expect fast 503 then recover to 200"
$COMPOSE stop asterisk >/dev/null
sleep 12
inv_down=$(probe_invite)
ms=$(printf '%s' "$inv_down" | sed -n 's/.*"ms":\([0-9]*\).*/\1/p')
ok_fast=0
case "$inv_down" in
  *'"status":503'*)
    if [ -n "$ms" ] && [ "$ms" -lt 5000 ]; then ok_fast=1; fi
    ;;
esac
t0=$(date +%s)
$COMPOSE start asterisk >/dev/null
wait_healthy enterprise-voice-asterisk-1 90 >/dev/null
# wait for dispatcher dst-up
ok_up=0
inv_up=""
for i in $(seq 1 20); do
  sleep 3
  inv_up=$(probe_invite)
  case "$inv_up" in
    *'"status":200'*) ok_up=1; break ;;
  esac
done
mttr=$(( $(date +%s) - t0 ))
ok=0
[ "$ok_fast" = 1 ] && [ "$ok_up" = 1 ] && ok=1
record "asterisk-down-fast503" "$ok" "$mttr" "down=$inv_down up=$inv_up"

# ---------- 4. softphone auto re-register ----------
say "4) restart Kamailio while registered — expect softphone SELFHEAL re-register"
rm -f /tmp/chaos-watch.out
# shellcheck disable=SC2086
(docker run --rm $E2E_DOCKER_OPTS $E2E_ENV -e PROBE=watch -e WATCH_SECONDS=70 \
  --entrypoint node softphone-e2e /e2e/probe.mjs > /tmp/chaos-watch.out 2>&1) &
WP=$!
ready=0
for i in $(seq 1 30); do
  sleep 1
  if grep -q 'PROBE READY' /tmp/chaos-watch.out 2>/dev/null; then ready=1; break; fi
done
if [ "$ready" = 1 ]; then
  $COMPOSE restart kamailio >/dev/null
  wait "$WP" || true
else
  kill "$WP" 2>/dev/null || true
  wait "$WP" 2>/dev/null || true
fi
watch_line=$(grep '^PROBE {' /tmp/chaos-watch.out | tail -1 || true)
ok=0
mttr=0
case "$watch_line" in
  *'"pass":true'*)
    ok=1
    mttr=$(printf '%s' "$watch_line" | sed -n 's/.*"recoverySeconds":\([0-9.]*\).*/\1/p' | cut -d. -f1)
    mttr=${mttr:-0}
    ;;
esac
record "softphone-reregister" "$ok" "$mttr" "${watch_line:-no watch result}"

# ---------- 5. kill agent (if present) ----------
say "5) kill agent — expect restart (skip AI call if no LiveKit creds)"
if docker inspect enterprise-voice-agent-1 >/dev/null 2>&1; then
  t0=$(date +%s)
  before=$(started_at enterprise-voice-agent-1)
  docker kill enterprise-voice-agent-1 >/dev/null 2>&1 || true
  ok=0
  mttr=0
  detail="agent did not restart"
  for i in $(seq 1 30); do
    sleep 3
    after=$(started_at enterprise-voice-agent-1)
    st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' enterprise-voice-agent-1 2>/dev/null || echo missing)
    if [ -n "$after" ] && [ "$after" != "$before" ]; then
      mttr=$(( $(date +%s) - t0 ))
      case "$st" in
        healthy|running|starting)
          ok=1
          detail="restarted status=$st"
          ;;
      esac
      break
    fi
  done
  record "kill-agent-restart" "$ok" "$mttr" "$detail"
else
  record "kill-agent-restart" 1 0 "skipped (agent not running)"
fi

# ---------- report ----------
{
  echo "# Self-healing chaos report"
  echo
  echo "- Generated: $STAMP (UTC)"
  echo "- Softphone URL: $URL"
  echo "- E2E_NETWORK: ${E2E_NETWORK:-default}"
  echo "- Target MTTR: < ${TARGET_MTTR}s"
  echo
  echo "| Scenario | Result | MTTR | Detail |"
  echo "|----------|--------|------|--------|$ROWS"
  echo
  echo "**Summary:** $pass_n passed, $fail_n failed"
} > "$REPORT"

say "Wrote $REPORT"
echo "PASS=$pass_n FAIL=$fail_n"
[ "$fail_n" = 0 ]
