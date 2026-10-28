# Build the TLS sidecar from source.
FROM golang:1.25-bookworm AS tls-builder
WORKDIR /src
COPY tls-sidecar/go.mod tls-sidecar/go.sum ./
RUN go mod download
COPY tls-sidecar/ .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -buildvcs=false -o /out/tls-sidecar .

# Build the optional Akamai helper from its own module. The app can still start
# if this helper is unavailable; building it here makes the container portable.
FROM golang:1.25-bookworm AS akamai-builder
WORKDIR /src
COPY vendor/akamai-bmp/go.mod vendor/akamai-bmp/go.sum ./
RUN go mod download
COPY vendor/akamai-bmp/ .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -buildvcs=false -o /out/akamai-bmp ./cmd/akamai-bmp-server/main.go

FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    fonts-liberation \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libcups2 \
    libdrm2 \
    libgbm1 \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libxss1 \
    libxtst6 \
    ca-certificates \
    curl \
    dumb-init \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package*.json ./
RUN npm ci --omit=dev --registry=https://registry.npmjs.org \
    && npm cache clean --force

COPY . .
COPY vendor/akamai-bmp-devices.json ./vendor/akamai-bmp-devices.json

# Restore the compiled helper binaries after the source copy.
COPY --from=tls-builder /out/tls-sidecar ./tls-sidecar/sidecar
COPY --from=akamai-builder /out/akamai-bmp ./vendor/akamai-bmp-server
RUN chmod +x ./start.sh ./tls-sidecar/sidecar ./vendor/akamai-bmp-server

ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    NODE_ENV=production \
    PORT=3000 \
    DB_POOL_MAX=5

EXPOSE 3000

# The bot stays "up" even when the event loop is wedged or Chromium is dead, so
# probe the real health route rather than just the listening socket.
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["./start.sh"]
