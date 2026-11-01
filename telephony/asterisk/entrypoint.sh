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
# IP the BROWSER uses to reach Asterisk RTP (Docker Desktop local UI → 127.0.0.1)
SOFTPHONE_MEDIA_IP="${SOFTPHONE_MEDIA_IP:-127.0.0.1}"
TURN_USER="${TURN_USER:-softphone}"
TURN_PASSWORD="${TURN_PASSWORD:-change-me-turn}"

if [ -z "$LIVEKIT_SIP_HOST" ]; then
  echo "WARNING: LIVEKIT_SIP_HOST is empty — AI dial to LiveKit will fail until set."
  LIVEKIT_SIP_HOST="sip.invalid"
fi

if [ -z "$EXTERNAL_SIP_IP" ]; then
  EXTERNAL_SIP_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "WARNING: EXTERNAL_SIP_IP unset — using ${EXTERNAL_SIP_IP}"
fi

echo "Softphone WebRTC media_address=${SOFTPHONE_MEDIA_IP} (LiveKit external=${EXTERNAL_SIP_IP}, TURN user=${TURN_USER})"

# Render configs from templates (strip CRLF from Windows bind mounts)
render() {
  tr -d '\r' < "$1" | sed \
    -e "s|__SIP_DOMAIN__|${SIP_DOMAIN}|g" \
    -e "s|__SOFTPHONE_USER__|${SOFTPHONE_USER}|g" \
    -e "s|__SOFTPHONE_PASSWORD__|${SOFTPHONE_PASSWORD}|g" \
    -e "s|__AI_EXTENSION__|${AI_EXTENSION}|g" \
    -e "s|__LIVEKIT_SIP_HOST__|${LIVEKIT_SIP_HOST}|g" \
    -e "s|__LIVEKIT_SIP_USERNAME__|${LIVEKIT_SIP_USERNAME}|g" \
    -e "s|__LIVEKIT_SIP_PASSWORD__|${LIVEKIT_SIP_PASSWORD}|g" \
    -e "s|__LIVEKIT_DID__|${LIVEKIT_DID}|g" \
    -e "s|__EXTERNAL_SIP_IP__|${EXTERNAL_SIP_IP}|g" \
    -e "s|__SOFTPHONE_MEDIA_IP__|${SOFTPHONE_MEDIA_IP}|g" \
    -e "s|__TURN_USER__|${TURN_USER}|g" \
    -e "s|__TURN_PASSWORD__|${TURN_PASSWORD}|g" \
    > "$2"
}

render /config/pjsip.conf.template /etc/asterisk/pjsip.conf
render /config/extensions.conf.template /etc/asterisk/extensions.conf
tr -d '\r' < /config/modules.conf > /etc/asterisk/modules.conf
if [ -f /config/rtp.conf.template ]; then
  render /config/rtp.conf.template /etc/asterisk/rtp.conf
else
  tr -d '\r' < /config/rtp.conf > /etc/asterisk/rtp.conf
fi
if [ -f /config/asterisk.conf ]; then
  tr -d '\r' < /config/asterisk.conf > /etc/asterisk/asterisk.conf
fi
# Show WebRTC-critical lines at boot (helps Docker Desktop bring-up)
echo "----- pjsip transport/media (expect: no external_media on UDP) -----"
grep -E '^\[|external_media|media_address|^webrtc|^transport' /etc/asterisk/pjsip.conf || true
echo "----- rtp turn/stun -----"
grep -E 'turn|stun|rtpstart|rtpend' /etc/asterisk/rtp.conf || true
echo "---------------------------------------------------------------"

# Prefer stock logger if present
if [ -f /etc/asterisk/logger.conf ]; then
  :
elif [ -f /config/logger.conf ]; then
  tr -d '\r' < /config/logger.conf > /etc/asterisk/logger.conf
fi

exec asterisk -f -vvv
