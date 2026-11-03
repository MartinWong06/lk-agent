#!/bin/sh
set -e
# Render softphone config + HTTPS/WSS (LAN self-signed or real certificate)
DOMAIN="${SIP_DOMAIN:-voice.local}"
USER="${SOFTPHONE_USER:-1001}"
PASS="${SOFTPHONE_PASSWORD:-change-me-softphone}"
AI="${AI_EXTENSION:-1000}"
DISPLAY="${SOFTPHONE_DISPLAY_NAME:-Demo Softphone}"
PUBLIC_HOST="${SOFTPHONE_PUBLIC_HOST:-}"
KAMAILIO_HOST="${KAMAILIO_HOST:-kamailio}"
ENABLE_HTTPS="${SOFTPHONE_ENABLE_HTTPS:-}"
HTTPS_PORT="${SOFTPHONE_HTTPS_PORT:-8443}"
TURN_USER="${TURN_USER:-softphone}"
TURN_PASSWORD="${TURN_PASSWORD:-change-me-turn}"
TURN_HOST="${SOFTPHONE_PUBLIC_HOST:-${SOFTPHONE_MEDIA_IP:-127.0.0.1}}"
PRODUCTION="${PRODUCTION:-0}"
# Production defaults: no credentials in config.json, no SIP trace, HTTP → HTTPS
if [ "$PRODUCTION" = "1" ]; then
  EMBED_CREDENTIALS="${SOFTPHONE_EMBED_CREDENTIALS:-0}"
  TRACE_SIP="${SOFTPHONE_TRACE_SIP:-0}"
  HTTP_REDIRECT="${SOFTPHONE_HTTP_REDIRECT:-1}"
  HSTS="${SOFTPHONE_HSTS:-1}"
else
  EMBED_CREDENTIALS="${SOFTPHONE_EMBED_CREDENTIALS:-1}"
  TRACE_SIP="${SOFTPHONE_TRACE_SIP:-1}"
  HTTP_REDIRECT="${SOFTPHONE_HTTP_REDIRECT:-0}"
  HSTS="${SOFTPHONE_HSTS:-0}"
fi
BASIC_USER="${SOFTPHONE_BASIC_AUTH_USER:-}"
BASIC_PASS="${SOFTPHONE_BASIC_AUTH_PASSWORD:-}"
TLS_CERT_FILE="${TLS_CERT_FILE:-}"
TLS_KEY_FILE="${TLS_KEY_FILE:-}"

fail() {
  echo "FATAL: $*" >&2
  exit 1
}

if [ "$PRODUCTION" = "1" ]; then
  [ -n "$PUBLIC_HOST" ] || fail "SOFTPHONE_PUBLIC_HOST (domain or public IP) is required (PRODUCTION=1)"
  if [ -n "$BASIC_USER" ]; then
    case "$BASIC_PASS" in
      change-me*|'') fail "SOFTPHONE_BASIC_AUTH_PASSWORD is unset or a change-me default" ;;
    esac
  fi
  if [ "$EMBED_CREDENTIALS" = "1" ]; then
    echo "WARNING: SOFTPHONE_EMBED_CREDENTIALS=1 publishes the SIP password in config.json"
  fi
fi

mkdir -p /etc/nginx/certs /var/www/certbot

# Auto-enable HTTPS when a public host is set
if [ -z "$ENABLE_HTTPS" ] && [ -n "$PUBLIC_HOST" ]; then
  ENABLE_HTTPS=1
fi
ENABLE_HTTPS="${ENABLE_HTTPS:-0}"
if [ "$PRODUCTION" = "1" ]; then
  ENABLE_HTTPS=1
fi

SELF_CERT=/etc/nginx/certs/self-cert.pem
SELF_KEY=/etc/nginx/certs/self-key.pem
make_self_signed() {
  [ -s "$SELF_CERT" ] && [ -s "$SELF_KEY" ] && return 0
  SAN="DNS:localhost,IP:127.0.0.1"
  case "$PUBLIC_HOST" in
    '') ;;
    *[a-zA-Z]*) SAN="${SAN},DNS:${PUBLIC_HOST}" ;;
    *) SAN="${SAN},IP:${PUBLIC_HOST}" ;;
  esac
  openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
    -keyout "$SELF_KEY" -out "$SELF_CERT" \
    -subj "/CN=${PUBLIC_HOST:-localhost}" \
    -addext "subjectAltName=${SAN}" >/tmp/openssl-softphone.log 2>&1 || \
  openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
    -keyout "$SELF_KEY" -out "$SELF_CERT" \
    -subj "/CN=${PUBLIC_HOST:-localhost}" >/tmp/openssl-softphone.log 2>&1
}

# Use the real certificate (e.g. Let's Encrypt) when present, else self-signed.
# Re-run on reload so a certificate issued/renewed later is picked up.
select_certificate() {
  if [ -n "$TLS_CERT_FILE" ] && [ -s "$TLS_CERT_FILE" ] && [ -s "$TLS_KEY_FILE" ]; then
    ln -sf "$TLS_CERT_FILE" /etc/nginx/certs/cert.pem
    ln -sf "$TLS_KEY_FILE" /etc/nginx/certs/key.pem
    echo "TLS: using ${TLS_CERT_FILE}"
  else
    make_self_signed
    ln -sf "$SELF_CERT" /etc/nginx/certs/cert.pem
    ln -sf "$SELF_KEY" /etc/nginx/certs/key.pem
    if [ -n "$TLS_CERT_FILE" ]; then
      echo "TLS: ${TLS_CERT_FILE} not found yet — serving self-signed until it exists"
    else
      echo "TLS: self-signed certificate"
    fi
  fi
}
select_certificate

if [ "$HTTPS_PORT" = "443" ]; then
  HTTPS_ORIGIN="https://${PUBLIC_HOST}"
else
  HTTPS_ORIGIN="https://${PUBLIC_HOST}:${HTTPS_PORT}"
fi

if [ "$ENABLE_HTTPS" = "1" ] && [ -n "$PUBLIC_HOST" ]; then
  # Browser uses WSS via nginx → Kamailio (avoids mixed-content + getUserMedia block)
  WS_SERVER="${SOFTPHONE_WS_SERVER:-wss://${HTTPS_ORIGIN#https://}/ws}"
  MEDIA_HINT="$PUBLIC_HOST"
  PREFERRED_URL="${HTTPS_ORIGIN}/"
elif [ -n "$PUBLIC_HOST" ]; then
  WS_SERVER="${SOFTPHONE_WS_SERVER:-ws://${PUBLIC_HOST}:8080}"
  MEDIA_HINT="$PUBLIC_HOST"
  PREFERRED_URL="http://${PUBLIC_HOST}:8088/"
else
  WS_SERVER="${SOFTPHONE_WS_SERVER:-ws://localhost:8080}"
  MEDIA_HINT="${SOFTPHONE_MEDIA_IP:-}"
  PREFERRED_URL="http://localhost:8088/"
fi

# LAN browsers reach Asterisk directly (Asterisk advertises SOFTPHONE_MEDIA_IP as its
# ICE candidate). Only add STUN/TURN when the coturn profile is running — an
# unreachable TURN server delays every INVITE by the ICE gathering timeout.
if [ "${SOFTPHONE_TURN:-0}" = "1" ]; then
  ICE_SERVERS=$(cat <<JSON
[
    { "urls": "stun:${TURN_HOST}:3478" },
    {
      "urls": "turn:${TURN_HOST}:3478?transport=udp",
      "username": "${TURN_USER}",
      "credential": "${TURN_PASSWORD}"
    },
    {
      "urls": "turn:${TURN_HOST}:3478?transport=tcp",
      "username": "${TURN_USER}",
      "credential": "${TURN_PASSWORD}"
    }
  ]
JSON
)
else
  ICE_SERVERS="[]"
fi

if [ "$EMBED_CREDENTIALS" = "1" ]; then
  PASSWORD_JSON="\"${PASS}\""
else
  PASSWORD_JSON="null"
fi

cat > /usr/share/nginx/html/config.json <<EOF
{
  "wsServer": "${WS_SERVER}",
  "domain": "${DOMAIN}",
  "authorizationUser": "${USER}",
  "password": ${PASSWORD_JSON},
  "displayName": "${DISPLAY}",
  "aiExtension": "${AI}",
  "traceSip": $([ "$TRACE_SIP" = "1" ] && echo true || echo false),
  "mediaHint": "${MEDIA_HINT}",
  "preferredPageHost": "${PUBLIC_HOST}",
  "preferredPageUrl": "${PREFERRED_URL}",
  "httpsEnabled": $([ "$ENABLE_HTTPS" = "1" ] && echo true || echo false),
  "iceServers": ${ICE_SERVERS}
}
EOF

# Optional HTTP basic auth in front of the UI (keeps strangers off the page)
AUTH_BASIC=""
if [ -n "$BASIC_USER" ]; then
  [ -n "$BASIC_PASS" ] || fail "SOFTPHONE_BASIC_AUTH_PASSWORD is required with SOFTPHONE_BASIC_AUTH_USER"
  printf '%s:%s\n' "$BASIC_USER" "$(openssl passwd -apr1 "$BASIC_PASS")" > /etc/nginx/htpasswd
  chmod 644 /etc/nginx/htpasswd
  AUTH_BASIC='auth_basic "Softphone"; auth_basic_user_file /etc/nginx/htpasswd;'
  echo "Basic auth enabled for user ${BASIC_USER}"
fi

if [ "$HTTP_REDIRECT" = "1" ]; then
  HTTP_LOCATION='return 301 https://$host'"$([ "$HTTPS_PORT" = "443" ] || echo ":$HTTPS_PORT")"'$request_uri;'
else
  HTTP_LOCATION='try_files $uri /index.html;'
fi

if [ "$HSTS" = "1" ]; then
  HSTS_LINE='add_header Strict-Transport-Security "max-age=31536000" always;'
else
  HSTS_LINE=''
fi

TEMPLATE=/etc/nginx/nginx.conf.template
[ -f "$TEMPLATE" ] || TEMPLATE=/usr/share/nginx/html/nginx.conf.template
tr -d '\r' < "$TEMPLATE" | sed \
  -e "s|__KAMAILIO_HOST__|${KAMAILIO_HOST}|g" \
  -e "s|__AUTH_BASIC__|${AUTH_BASIC}|g" \
  -e "s|__HTTP_LOCATION__|${HTTP_LOCATION}|g" \
  -e "s|__HSTS__|${HSTS_LINE}|g" \
  > /etc/nginx/nginx.conf
nginx -t -q

# Never serve the template / entrypoint from the web root
rm -f /usr/share/nginx/html/nginx.conf.template /usr/share/nginx/html/docker-entrypoint.sh \
  /usr/share/nginx/html/Dockerfile

# Pick up certificates issued or renewed after start (certbot runs separately)
(
  while sleep "${SOFTPHONE_CERT_RELOAD_SECONDS:-21600}"; do
    select_certificate >/dev/null && nginx -s reload 2>/dev/null || true
  done
) &

echo "Softphone UI: ${PREFERRED_URL} (https=${ENABLE_HTTPS}, ws=${WS_SERVER}, production=${PRODUCTION})"
exec nginx -g "daemon off;"
