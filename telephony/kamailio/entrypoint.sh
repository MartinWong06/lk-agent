#!/bin/sh
set -e
# Substitute Asterisk host into a writable dispatcher list at runtime
ASTERISK_HOST="${ASTERISK_HOST:-asterisk}"
SIP_DOMAIN="${SIP_DOMAIN:-voice.local}"
TEMPLATE="${DISPATCHER_TEMPLATE:-/etc/kamailio/dispatcher.list.template}"
# Host-mounted configs may still have CRLF on Windows bind mounts
CFG="${KAMAILIO_CFG:-/etc/kamailio/kamailio.cfg}"

# SIP accounts allowed to REGISTER / call: "user:pass,user2:pass2".
# Defaults to the single softphone account.
SIP_USERS="${SIP_USERS:-${SOFTPHONE_USER:-1001}:${SOFTPHONE_PASSWORD:-change-me-softphone}}"

fail() {
  echo "FATAL: $*" >&2
  exit 1
}

USERS_CFG=/tmp/kamailio-users.cfg
{
  echo 'event_route[htable:mod-init] {'
  OLDIFS="$IFS"
  IFS=','
  for entry in $SIP_USERS; do
    IFS="$OLDIFS"
    entry=$(printf '%s' "$entry" | tr -d '\r' | sed 's/^ *//;s/ *$//')
    [ -n "$entry" ] || continue
    user="${entry%%:*}"
    pass="${entry#*:}"
    case "$user" in
      ''|*[!A-Za-z0-9_.+-]*) fail "invalid SIP username '$user' (allowed: A-Z a-z 0-9 _ . + -)" ;;
    esac
    case "$pass" in
      "$entry"|'') fail "SIP user '$user' has no password (format user:pass)" ;;
      *'"'*|*'\'*|*'$'*) fail "SIP password for '$user' must not contain \" \\ or \$" ;;
    esac
    if [ "${PRODUCTION:-0}" = "1" ]; then
      case "$pass" in
        change-me*) fail "SIP password for '$user' is still a change-me default (PRODUCTION=1)" ;;
      esac
      [ "${#pass}" -ge 12 ] || fail "SIP password for '$user' must be >= 12 chars (PRODUCTION=1)"
    fi
    echo "    \$sht(users=>$user) = \"$pass\";"
    echo "SIP account enabled: $user" >&2
    IFS=','
  done
  IFS="$OLDIFS"
  echo '}'
} > "$USERS_CFG"
chmod 600 "$USERS_CFG"

AUTH_SECRET="${KAMAILIO_AUTH_SECRET:-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')}"

tr -d '\r' < "$CFG" | sed \
  -e "s|__SIP_DOMAIN__|${SIP_DOMAIN}|g" \
  -e "s|__AUTH_SECRET__|${AUTH_SECRET}|g" \
  > /tmp/kamailio.cfg
CFG=/tmp/kamailio.cfg

# Resolve each Asterisk hostname to an IP so INVITEs survive container recreate
# (Kamailio's ds_dns_mode updates probes but can leave INVITE on a stale IP).
# ASTERISK_HOSTS="asterisk,asterisk-b" → one dispatcher destination per node.
ASTERISK_HOSTS="${ASTERISK_HOSTS:-$ASTERISK_HOST}"
DS_LINE=$(tr -d '\r' < "$TEMPLATE" | grep '__ASTERISK_HOST__' | head -1)
HEADER=$(tr -d '\r' < "$TEMPLATE" | grep -v '__ASTERISK_HOST__')

resolve_host() {
  h="$1"
  case "$h" in
    *[!0-9.]*|'') ;;
    *) echo "$h"; return 0 ;;
  esac
  # Prefer getent (glibc) then busybox nslookup
  ip=$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}')
  if [ -z "$ip" ]; then
    ip=$(nslookup "$h" 2>/dev/null | awk '/^Address: / && $2 !~ /#/{print $2; exit}')
  fi
  echo "${ip:-$h}"
}

write_dispatcher() {
  out="$1"
  {
    echo "$HEADER"
    for h in $(echo "$ASTERISK_HOSTS" | tr ',' ' '); do
      ip=$(resolve_host "$h")
      echo "$DS_LINE" | sed "s/__ASTERISK_HOST__/${ip}/g"
      echo "dispatcher: $h -> $ip" >&2
    done
  } > "$out"
}

write_dispatcher /tmp/dispatcher.list
echo "Kamailio dispatcher ASTERISK_HOSTS=${ASTERISK_HOSTS} domain=${SIP_DOMAIN}"
if [ "$ASTERISK_HOST" = "host.docker.internal" ]; then
  echo "WARNING: ASTERISK_HOST=host.docker.internal usually breaks INVITE on Docker Desktop Windows."
  echo "         Use: docker compose -f docker-compose.yml up   (no host-asterisk overlay)"
fi

# Background: when Asterisk is recreated its IP changes. Rewrite the list and
# ask Kamailio to reload so the next INVITE hits the new address.
(
  PREV=$(cat /tmp/dispatcher.list)
  while sleep 10; do
    write_dispatcher /tmp/dispatcher.list.new 2>/dev/null || continue
    NEW=$(cat /tmp/dispatcher.list.new)
    if [ "$NEW" != "$PREV" ]; then
      mv /tmp/dispatcher.list.new /tmp/dispatcher.list
      PREV="$NEW"
      echo "SELFHEAL dispatcher-reload (Asterisk IP changed)"
      kamcmd dispatcher.reload 2>/dev/null || true
    else
      rm -f /tmp/dispatcher.list.new
    fi
  done
) &

exec kamailio -DD -E -f "$CFG"
