FROM andrius/asterisk:latest

USER root
RUN mkdir -p /config /etc/asterisk
COPY conf/ /config/
COPY entrypoint.sh /entrypoint.sh
# Strip CRLF from Windows checkouts; invoke via /bin/sh so shebang \r cannot break exec
RUN find /config -type f -exec sed -i 's/\r$//' {} + \
    && sed -i 's/\r$//' /entrypoint.sh \
    && chmod +x /entrypoint.sh

EXPOSE 5060/udp 5060/tcp 10000-10100/udp

ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
