#!/bin/sh
set -e
# Render softphone config from env so operators only edit .env
DOMAIN="${SIP_DOMAIN:-voice.local}"
USER="${SOFTPHONE_USER:-1001}"
PASS="${SOFTPHONE_PASSWORD:-change-me-softphone}"
AI="${AI_EXTENSION:-1000}"
DISPLAY="${SOFTPHONE_DISPLAY_NAME:-Demo Softphone}"
PUBLIC_HOST="${SOFTPHONE_PUBLIC_HOST:-}"

if [ -n "$PUBLIC_HOST" ]; then
  WS_SERVER="${SOFTPHONE_WS_SERVER:-ws://${PUBLIC_HOST}:8080}"
  MEDIA_HINT="$PUBLIC_HOST"
else
  WS_SERVER="${SOFTPHONE_WS_SERVER:-ws://localhost:8080}"
  MEDIA_HINT="${SOFTPHONE_MEDIA_IP:-}"
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
  "preferredPageHost": "${PUBLIC_HOST}"
}
EOF

exec nginx -g "daemon off;"
