# Sourced by test-media.sh / test-security.sh: derive the softphone URL and logins from .env.
env_get() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" .env 2>/dev/null | tr -d '\r' | tail -1 | sed 's/[[:space:]]*$//'
}

HOST_IP=$(env_get SOFTPHONE_PUBLIC_HOST)
if [ -z "$HOST_IP" ]; then
  echo "SOFTPHONE_PUBLIC_HOST missing in .env" >&2
  exit 2
fi
E2E_PRODUCTION=$(env_get PRODUCTION)
if [ "$E2E_PRODUCTION" = "1" ]; then
  URL="${SOFTPHONE_URL:-https://${HOST_IP}/}"
else
  URL="${SOFTPHONE_URL:-https://${HOST_IP}:8443/}"
fi
E2E_SIP_USER=$(env_get SOFTPHONE_USER)
E2E_SIP_PASSWORD=$(env_get SOFTPHONE_PASSWORD)
E2E_BASIC_USER=$(env_get SOFTPHONE_BASIC_AUTH_USER)
E2E_BASIC_PASSWORD=$(env_get SOFTPHONE_BASIC_AUTH_PASSWORD)
E2E_ENV="-e SOFTPHONE_URL=$URL -e SIP_USER=${E2E_SIP_USER:-1001} -e SIP_PASSWORD=${E2E_SIP_PASSWORD:-change-me-softphone}"
[ -z "$E2E_BASIC_USER" ] || E2E_ENV="$E2E_ENV -e BASIC_AUTH_USER=$E2E_BASIC_USER -e BASIC_AUTH_PASSWORD=$E2E_BASIC_PASSWORD"

docker build -q -t softphone-e2e tests/softphone-e2e >/dev/null
