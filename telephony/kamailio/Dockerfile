FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    kamailio \
    kamailio-websocket-modules \
    kamailio-presence-modules \
    kamailio-tls-modules \
    kamailio-utils-modules \
    kamailio-extra-modules \
    ca-certificates \
    netbase \
    procps \
    && rm -rf /var/lib/apt/lists/*

COPY kamailio.cfg /etc/kamailio/kamailio.cfg
COPY dispatcher.list /etc/kamailio/dispatcher.list.template
COPY entrypoint.sh /entrypoint.sh
# Strip CRLF from Windows checkouts; invoke via /bin/sh so shebang \r cannot break exec
RUN sed -i 's/\r$//' /entrypoint.sh /etc/kamailio/kamailio.cfg \
        /etc/kamailio/dispatcher.list.template \
    && chmod +x /entrypoint.sh

EXPOSE 5060/udp 5060/tcp 8080

ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
