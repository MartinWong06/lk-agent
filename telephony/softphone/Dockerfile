FROM nginx:alpine
RUN apk add --no-cache openssl
COPY . /usr/share/nginx/html/
COPY nginx.conf.template /etc/nginx/nginx.conf.template
COPY docker-entrypoint.sh /docker-entrypoint.sh
# Strip CRLF from Windows checkouts; invoke via /bin/sh so shebang \r cannot break exec
RUN sed -i 's/\r$//' /docker-entrypoint.sh /etc/nginx/nginx.conf.template \
    && chmod +x /docker-entrypoint.sh
EXPOSE 80 443
ENTRYPOINT ["/bin/sh", "/docker-entrypoint.sh"]
