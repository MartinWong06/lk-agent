FROM andrius/asterisk:latest

USER root
RUN mkdir -p /config /etc/asterisk
COPY conf/ /config/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5060/udp 5060/tcp 10000-10100/udp

ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
