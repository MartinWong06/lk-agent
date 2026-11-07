FROM mcr.microsoft.com/playwright:v1.56.1-noble
WORKDIR /e2e
RUN npm init -y >/dev/null && npm install --no-audit --no-fund playwright@1.56.1 >/dev/null
COPY run.mjs security.mjs probe.mjs ./
ENTRYPOINT ["node", "/e2e/run.mjs"]
