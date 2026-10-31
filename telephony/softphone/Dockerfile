FROM nginx:alpine
COPY . /usr/share/nginx/html/
COPY docker-entrypoint.sh /docker-entrypoint.sh
# Strip CRLF from Windows checkouts; invoke via /bin/sh so shebang \r cannot break exec
RUN sed -i 's/\r$//' /docker-entrypoint.sh \
    && chmod +x /docker-entrypoint.sh
EXPOSE 80
ENTRYPOINT ["/bin/sh", "/docker-entrypoint.sh"]
