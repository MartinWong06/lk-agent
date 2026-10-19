#!/bin/sh
set -e
# Substitute Asterisk host into dispatcher list at runtime
ASTERISK_HOST="${ASTERISK_HOST:-asterisk}"
sed "s/__ASTERISK_HOST__/${ASTERISK_HOST}/g" /etc/kamailio/dispatcher.list > /tmp/dispatcher.list
cp /tmp/dispatcher.list /etc/kamailio/dispatcher.list
exec kamailio -DD -E -f /etc/kamailio/kamailio.cfg
