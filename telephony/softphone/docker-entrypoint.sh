#!/bin/sh
set -e
# Render softphone config + optional HTTPS/WSS for LAN getUserMedia
DOMAIN="${SIP_DOMAIN:-voice.local}"
USER="${SOFTPHONE_USER:-1001}"
PASS="${SOFTPHONE_PASSWORD:-change-me-softphone}"
AI="${AI_EXTENSION:-1000}"
DISPLAY="${SOFTPHONE_DISPLAY_NAME:-Demo Softphone}"
PUBLIC_HOST="${SOFTPHONE_PUBLIC_HOST:-}"
KAMAILIO_HOST="${KAMAILIO_HOST:-kamailio}"
ENABLE_HTTPS="${SOFTPHONE_ENABLE_HTTPS:-}"

mkdir -p /etc/nginx/certs

# Auto-enable HTTPS when a LAN public host is set (Docker Desktop WebRTC path)
if [ -z "$ENABLE_HTTPS" ] && [ -n "$PUBLIC_HOST" ]; then
  ENABLE_HTTPS=1
fi
ENABLE_HTTPS="${ENABLE_HTTPS:-0}"

if [ "$ENABLE_HTTPS" = "1" ]; then
  # Self-signed cert with SAN for the LAN IP / hostname
  if command -v openssl >/dev/null 2>&1; then
    SAN="DNS:localhost,IP:127.0.0.1"
    case "$PUBLIC_HOST" in
      *[a-zA-Z]*) SAN="${SAN},DNS:${PUBLIC_HOST}" ;;
      *) SAN="${SAN},IP:${PUBLIC_HOST}" ;;
    esac
    openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
      -keyout /etc/nginx/certs/key.pem \
      -out /etc/nginx/certs/cert.pem \
      -subj "/CN=${PUBLIC_HOST:-localhost}" \
      -addext "subjectAltName=${SAN}" >/tmp/openssl-softphone.log 2>&1 || \
    openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
      -keyout /etc/nginx/certs/key.pem \
      -out /etc/nginx/certs/cert.pem \
      -subj "/CN=${PUBLIC_HOST:-localhost}" >/tmp/openssl-softphone.log 2>&1
  else
    echo "WARNING: openssl missing — HTTPS disabled"
    ENABLE_HTTPS=0
  fi
fi

if [ "$ENABLE_HTTPS" = "1" ] && [ -n "$PUBLIC_HOST" ]; then
  # Browser uses WSS via nginx → Kamailio (avoids mixed-content + getUserMedia block)
  WS_SERVER="${SOFTPHONE_WS_SERVER:-wss://${PUBLIC_HOST}:8443/ws}"
  MEDIA_HINT="$PUBLIC_HOST"
  PREFERRED_URL="https://${PUBLIC_HOST}:8443/"
elif [ -n "$PUBLIC_HOST" ]; then
  WS_SERVER="${SOFTPHONE_WS_SERVER:-ws://${PUBLIC_HOST}:8080}"
  MEDIA_HINT="$PUBLIC_HOST"
  PREFERRED_URL="http://${PUBLIC_HOST}:8088/"
else
  WS_SERVER="${SOFTPHONE_WS_SERVER:-ws://localhost:8080}"
  MEDIA_HINT="${SOFTPHONE_MEDIA_IP:-}"
  PREFERRED_URL="http://localhost:8088/"
fi

cat > /usr/share/nginx/html/config.json <<EOF
{
  "wsServer": "${WS_SERVER}",
  "domain": "${DOMAIN}",
  "authorizationUser": "${USER}",
  "password": "${PASS}",
  "displayName": "${DISPLAY}",
  "aiExtension": "${AI}",
  "traceSip": true,
  "mediaHint": "${MEDIA_HINT}",
  "preferredPageHost": "${PUBLIC_HOST}",
  "preferredPageUrl": "${PREFERRED_URL}",
  "httpsEnabled": $([ "$ENABLE_HTTPS" = "1" ] && echo true || echo false)
}
EOF

# Render nginx config
if [ -f /etc/nginx/nginx.conf.template ]; then
  sed "s|__KAMAILIO_HOST__|${KAMAILIO_HOST}|g" /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
elif [ -f /usr/share/nginx/html/nginx.conf.template ]; then
  sed "s|__KAMAILIO_HOST__|${KAMAILIO_HOST}|g" /usr/share/nginx/html/nginx.conf.template > /etc/nginx/nginx.conf
fi

echo "Softphone UI preferred URL: ${PREFERRED_URL} (https=${ENABLE_HTTPS}, ws=${WS_SERVER})"
exec nginx -g "daemon off;"
