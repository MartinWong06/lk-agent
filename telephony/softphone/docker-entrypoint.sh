#!/bin/sh
set -e
# Render softphone config from env so operators only edit .env
WS_SERVER="${SOFTPHONE_WS_SERVER:-ws://localhost:8080}"
DOMAIN="${SIP_DOMAIN:-voice.local}"
USER="${SOFTPHONE_USER:-1001}"
PASS="${SOFTPHONE_PASSWORD:-change-me-softphone}"
AI="${AI_EXTENSION:-1000}"
DISPLAY="${SOFTPHONE_DISPLAY_NAME:-Demo Softphone}"

cat > /usr/share/nginx/html/config.json <<EOF
{
  "wsServer": "${WS_SERVER}",
  "domain": "${DOMAIN}",
  "authorizationUser": "${USER}",
  "password": "${PASS}",
  "displayName": "${DISPLAY}",
  "aiExtension": "${AI}",
  "traceSip": true
}
EOF

exec nginx -g "daemon off;"
