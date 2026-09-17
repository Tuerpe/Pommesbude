# Build-Kontext ist das Projektverzeichnis (siehe docker-compose.yml), damit client/, docs/ und VERSION
# in das Client-Paket gepackt werden koennen, das die Website unter /client/pommesbude-client.zip ausliefert.
FROM node:24-alpine
WORKDIR /app
ENV NODE_ENV=production
RUN apk add --no-cache zip
COPY web/package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY web/server.js web/db.js ./
COPY web/public ./public
COPY VERSION ./VERSION
# Client-Paket bauen: client/ (Setup, Launcher, OBS-Vorlagen) + Anleitungen + VERSION + relay.example.json
COPY client ./pkg/client
COPY docs/ANLEITUNG.md docs/GUIDE.md ./pkg/
COPY relay.example.json Setup.cmd ./pkg/
RUN cp VERSION pkg/VERSION && mkdir -p public/client && cd pkg && zip -qr ../public/client/pommesbude-client.zip . && cd .. && rm -rf pkg
RUN mkdir -p /data
VOLUME ["/data"]
EXPOSE 3000
CMD ["node", "server.js"]
