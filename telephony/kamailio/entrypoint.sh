#!/bin/sh
set -e
# Substitute Asterisk host into a writable dispatcher list at runtime
ASTERISK_HOST="${ASTERISK_HOST:-asterisk}"
TEMPLATE="${DISPATCHER_TEMPLATE:-/etc/kamailio/dispatcher.list.template}"
sed "s/__ASTERISK_HOST__/${ASTERISK_HOST}/g" "$TEMPLATE" > /tmp/dispatcher.list
exec kamailio -DD -E -f /etc/kamailio/kamailio.cfg
