#!/bin/sh
set -e
# Substitute Asterisk host into a writable dispatcher list at runtime
ASTERISK_HOST="${ASTERISK_HOST:-asterisk}"
TEMPLATE="${DISPATCHER_TEMPLATE:-/etc/kamailio/dispatcher.list.template}"
# Host-mounted configs may still have CRLF on Windows bind mounts
CFG="${KAMAILIO_CFG:-/etc/kamailio/kamailio.cfg}"
if [ -f "$CFG" ]; then
  tr -d '\r' < "$CFG" > /tmp/kamailio.cfg
  CFG=/tmp/kamailio.cfg
fi
tr -d '\r' < "$TEMPLATE" | sed "s/__ASTERISK_HOST__/${ASTERISK_HOST}/g" > /tmp/dispatcher.list
echo "Kamailio dispatcher ASTERISK_HOST=${ASTERISK_HOST} (expect 'asterisk' on Docker Desktop bridge)"
if [ "$ASTERISK_HOST" = "host.docker.internal" ]; then
  echo "WARNING: ASTERISK_HOST=host.docker.internal usually breaks INVITE on Docker Desktop Windows."
  echo "         Use: docker compose -f docker-compose.yml up   (no host-asterisk overlay)"
fi
exec kamailio -DD -E -f "$CFG"
