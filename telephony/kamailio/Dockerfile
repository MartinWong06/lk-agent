FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    kamailio \
    kamailio-websocket-modules \
    kamailio-presence-modules \
    kamailio-tls-modules \
    kamailio-utils-modules \
    kamailio-extra-modules \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY kamailio.cfg /etc/kamailio/kamailio.cfg
COPY dispatcher.list /etc/kamailio/dispatcher.list.template
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5060/udp 5060/tcp 8080

ENTRYPOINT ["/entrypoint.sh"]
