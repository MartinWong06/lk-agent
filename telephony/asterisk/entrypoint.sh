#!/bin/sh
set -e

SIP_DOMAIN="${SIP_DOMAIN:-voice.local}"
SOFTPHONE_USER="${SOFTPHONE_USER:-1001}"
SOFTPHONE_PASSWORD="${SOFTPHONE_PASSWORD:-change-me-softphone}"
AI_EXTENSION="${AI_EXTENSION:-1000}"
LIVEKIT_SIP_HOST="${LIVEKIT_SIP_HOST:-}"
LIVEKIT_SIP_USERNAME="${LIVEKIT_SIP_USERNAME:-asterisk-trunk}"
LIVEKIT_SIP_PASSWORD="${LIVEKIT_SIP_PASSWORD:-change-me-trunk-password}"
LIVEKIT_DID="${LIVEKIT_DID:-+15555550100}"
EXTERNAL_SIP_IP="${EXTERNAL_SIP_IP:-}"

if [ -z "$LIVEKIT_SIP_HOST" ]; then
  echo "WARNING: LIVEKIT_SIP_HOST is empty — AI dial to LiveKit will fail until set."
  LIVEKIT_SIP_HOST="sip.invalid"
fi

if [ -z "$EXTERNAL_SIP_IP" ]; then
  EXTERNAL_SIP_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "WARNING: EXTERNAL_SIP_IP unset — using ${EXTERNAL_SIP_IP}"
fi

# Render configs from templates
render() {
  sed \
    -e "s|__SIP_DOMAIN__|${SIP_DOMAIN}|g" \
    -e "s|__SOFTPHONE_USER__|${SOFTPHONE_USER}|g" \
    -e "s|__SOFTPHONE_PASSWORD__|${SOFTPHONE_PASSWORD}|g" \
    -e "s|__AI_EXTENSION__|${AI_EXTENSION}|g" \
    -e "s|__LIVEKIT_SIP_HOST__|${LIVEKIT_SIP_HOST}|g" \
    -e "s|__LIVEKIT_SIP_USERNAME__|${LIVEKIT_SIP_USERNAME}|g" \
    -e "s|__LIVEKIT_SIP_PASSWORD__|${LIVEKIT_SIP_PASSWORD}|g" \
    -e "s|__LIVEKIT_DID__|${LIVEKIT_DID}|g" \
    -e "s|__EXTERNAL_SIP_IP__|${EXTERNAL_SIP_IP}|g" \
    "$1" > "$2"
}

render /config/pjsip.conf.template /etc/asterisk/pjsip.conf
render /config/extensions.conf.template /etc/asterisk/extensions.conf
cp /config/modules.conf /etc/asterisk/modules.conf
cp /config/rtp.conf /etc/asterisk/rtp.conf
cp /config/asterisk.conf /etc/asterisk/asterisk.conf 2>/dev/null || true

# Prefer stock logger if present
if [ -f /etc/asterisk/logger.conf ]; then
  :
elif [ -f /config/logger.conf ]; then
  cp /config/logger.conf /etc/asterisk/logger.conf
fi

exec asterisk -f -vvv
