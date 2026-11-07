#!/bin/sh
# Production bring-up on a Linux VPS with a public IP.
#
# Usage (from telephony/):
#   sudo sh scripts/vps-setup.sh --domain voice.example.com --email you@example.com
#   sudo sh scripts/vps-setup.sh                 # no domain: public IP + self-signed cert
#
# Options:
#   --domain NAME     DNS name pointing at this VPS (enables Let's Encrypt)
#   --email ADDR      Let's Encrypt account e-mail (required with --domain)
#   --public-ip IP    override public IP detection
#   --no-firewall     do not touch ufw
#   --no-up           only write .env, do not start containers
#
# What it does:
#   1. Checks Docker + Compose >= 2.24.
#   2. Writes production values into .env and replaces every empty / change-me secret
#      with a random one (existing real values are kept).
#   3. ufw: allow SSH, 80/tcp, 443/tcp, 20000-20050/udp; deny everything else inbound.
#   4. Starts the stack with docker-compose.prod.yml (only 80/443/RTP published).
#   5. Issues a Let's Encrypt certificate and keeps the renewal container running.
set -eu
cd "$(dirname "$0")/.."

DOMAIN=""
EMAIL=""
PUBLIC_IP=""
FIREWALL=1
START=1
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --public-ip) PUBLIC_IP="$2"; shift 2 ;;
    --no-firewall) FIREWALL=0; shift ;;
    --no-up) START=0; shift ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || die "this script is for Linux hosts"
if [ -n "$DOMAIN" ] && [ -z "$EMAIL" ]; then
  die "--email is required with --domain (Let's Encrypt account)"
fi

# ---------- Docker ----------
say "Checking Docker"
command -v docker >/dev/null 2>&1 || die "Docker not installed. Install: curl -fsSL https://get.docker.com | sh"
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (run with sudo or add your user to the docker group)"
CV=$(docker compose version --short 2>/dev/null | sed 's/^v//') || die "Docker Compose plugin missing (apt install docker-compose-plugin)"
CMAJ=$(echo "$CV" | cut -d. -f1)
CMIN=$(echo "$CV" | cut -d. -f2)
if [ "$CMAJ" -lt 2 ] || { [ "$CMAJ" -eq 2 ] && [ "$CMIN" -lt 24 ]; }; then
  die "Docker Compose $CV is too old; need >= 2.24 for docker-compose.prod.yml"
fi
echo "Docker Compose $CV"

# ---------- Public IP ----------
if [ -z "$PUBLIC_IP" ]; then
  for svc in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    PUBLIC_IP=$(curl -4 -fsS --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]') || true
    case "$PUBLIC_IP" in *.*.*.*) break ;; *) PUBLIC_IP="" ;; esac
  done
fi
if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
fi
[ -n "$PUBLIC_IP" ] || die "could not detect the public IP; pass --public-ip"
echo "Public IP: $PUBLIC_IP"

if [ -n "$DOMAIN" ]; then
  RESOLVED=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')
  if [ "$RESOLVED" != "$PUBLIC_IP" ]; then
    warn "$DOMAIN resolves to '${RESOLVED:-nothing}', not $PUBLIC_IP — Let's Encrypt will fail until DNS is fixed"
  fi
fi
HOST="${DOMAIN:-$PUBLIC_IP}"

# ---------- .env ----------
say "Writing production settings to .env"
[ -f .env ] || cp .env.example .env
sed -i 's/\r$//' .env
chmod 600 .env

env_get() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" .env | tail -1 | sed 's/[[:space:]]*$//'
}
env_set() {
  if grep -q "^[[:space:]]*$1[[:space:]]*=" .env; then
    awk -v k="$1" -v v="$2" 'BEGIN{FS=OFS="="} $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {print k"="v; next} {print}' .env > .env.tmp
    cat .env.tmp > .env && rm -f .env.tmp
  else
    printf '%s=%s\n' "$1" "$2" >> .env
  fi
}
gen_secret() {
  # alphanumeric only: safe in SIP digest, nginx htpasswd, Asterisk and Kamailio configs
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-24}"
}
GENERATED=""
ensure_secret() {
  cur=$(env_get "$1")
  case "$cur" in
    ''|change-me*)
      env_set "$1" "$(gen_secret 24)"
      GENERATED="$GENERATED $1"
      ;;
    *)
      if [ "${#cur}" -lt 12 ]; then
        warn "$1 is shorter than 12 characters — containers will refuse to start in PRODUCTION mode"
      fi
      ;;
  esac
}

env_set PRODUCTION 1
env_set SOFTPHONE_PUBLIC_HOST "$HOST"
env_set SOFTPHONE_MEDIA_IP "$PUBLIC_IP"
env_set SOFTPHONE_WS_SERVER ""
env_set SOFTPHONE_ENABLE_HTTPS 1
env_set EXTERNAL_SIP_IP "$PUBLIC_IP"
case "$(env_get SIP_ALLOWED_ADDRESSES)" in
  ''|203.0.113.*) env_set SIP_ALLOWED_ADDRESSES "$PUBLIC_IP" ;;
esac
[ -n "$(env_get SOFTPHONE_BASIC_AUTH_USER)" ] || env_set SOFTPHONE_BASIC_AUTH_USER voice
ensure_secret SOFTPHONE_PASSWORD
ensure_secret SOFTPHONE_BASIC_AUTH_PASSWORD
ensure_secret LIVEKIT_SIP_PASSWORD
ensure_secret TURN_PASSWORD

LIVEKIT_OK=1
for k in LIVEKIT_URL LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_SIP_HOST; do
  if [ -z "$(env_get "$k")" ]; then
    warn "$k is empty — the AI extension will not work until it is set"
    LIVEKIT_OK=0
  fi
done

mkdir -p data/letsencrypt data/certbot-www

# ---------- Firewall ----------
if [ "$FIREWALL" = 1 ]; then
  if command -v ufw >/dev/null 2>&1; then
    say "Configuring ufw"
    SSH_PORT=$(echo "${SSH_CONNECTION:-}" | awk '{print $4}')
    ufw allow 22/tcp >/dev/null
    [ -z "$SSH_PORT" ] || [ "$SSH_PORT" = 22 ] || ufw allow "$SSH_PORT/tcp" >/dev/null
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw allow 20000:20050/udp >/dev/null
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw --force enable >/dev/null
    ufw status | sed 's/^/  /'
    echo "Note: Docker-published ports bypass ufw; the prod overlay publishes only 80, 443 and RTP."
  else
    warn "ufw not installed — restrict inbound traffic in your provider's firewall to 22/tcp, 80/tcp, 443/tcp, 20000-20050/udp"
  fi
fi

[ "$START" = 1 ] || { say ".env written (--no-up)"; exit 0; }

# ---------- Start ----------
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml"
SERVICES="asterisk kamailio softphone"
[ "$LIVEKIT_OK" = 1 ] && SERVICES="$SERVICES agent"
say "Starting: $SERVICES"
$COMPOSE up -d --build --remove-orphans $SERVICES

# ---------- Let's Encrypt ----------
if [ -n "$DOMAIN" ]; then
  if [ -s "data/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    echo "Let's Encrypt certificate already present for $DOMAIN"
  else
    say "Requesting Let's Encrypt certificate for $DOMAIN"
    i=0
    until curl -fsS --max-time 3 "http://127.0.0.1/healthz" >/dev/null 2>&1; do
      i=$((i + 1)); [ "$i" -lt 30 ] || die "softphone did not come up on port 80"
      sleep 2
    done
    $COMPOSE --profile letsencrypt run --rm certbot certonly --webroot -w /var/www/certbot \
      -d "$DOMAIN" -m "$EMAIL" --agree-tos -n --no-eff-email \
      || die "certbot failed (DNS for $DOMAIN must point at $PUBLIC_IP and port 80 must be open)"
  fi
  $COMPOSE restart softphone
  $COMPOSE --profile letsencrypt up -d certbot
fi

# ---------- Summary ----------
say "Done"
cat <<EOF
Softphone:     https://$HOST/
Page login:    $(env_get SOFTPHONE_BASIC_AUTH_USER) / $(env_get SOFTPHONE_BASIC_AUTH_PASSWORD)
SIP login:     $(env_get SOFTPHONE_USER) / $(env_get SOFTPHONE_PASSWORD)
Dial:          9196 (echo test), $(env_get AI_EXTENSION) (AI agent)
Secrets are in $(pwd)/.env (mode 600).
EOF
[ -n "$DOMAIN" ] || echo "No --domain: the browser will warn about the self-signed certificate."
case " $GENERATED " in
  *" LIVEKIT_SIP_PASSWORD "*)
    echo ""
    echo "LIVEKIT_SIP_PASSWORD was regenerated. Update the LiveKit inbound trunk to match:"
    echo "  uv run --with livekit-api --with python-dotenv python livekit/setup_sip.py"
    ;;
esac
echo ""
echo "Verify:  sh scripts/test-security.sh   and   sh scripts/test-media.sh"
