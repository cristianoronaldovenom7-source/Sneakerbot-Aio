#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="${APP_DIR:-/opt/sneakerbot}"
APP_USER="${APP_USER:-sneakerbot}"
NODE_MAJOR="${NODE_MAJOR:-22}"
PORT="${PORT:-3000}"
# 'docker' runs the app in containers (Docker + compose plugin are installed
# automatically). 'systemd' runs it straight on the host. 'auto' prefers docker
# and falls back to systemd only if the engine cannot be installed.
DEPLOY_MODE="${DEPLOY_MODE:-docker}"

log() { printf '[lightsail] %s\n' "$*"; }
warn() { printf '[lightsail] WARNING: %s\n' "$*" >&2; }

if [[ $EUID -ne 0 ]]; then
  echo 'Run this script as root (sudo ./deploy-lightsail.sh).' >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo 'This installer targets Ubuntu/Debian Lightsail instances.' >&2
  exit 2
fi

case "$DEPLOY_MODE" in
  docker|systemd|auto) ;;
  *) echo "DEPLOY_MODE must be docker, systemd or auto (got '$DEPLOY_MODE')." >&2; exit 2 ;;
esac

export DEBIAN_FRONTEND=noninteractive
log 'Installing system packages...'
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git build-essential python3 pkg-config libsqlite3-dev rsync openssl gnupg unzip

# A single Chromium renderer fits a 2 GB box, a checkout burst does not. Without
# swap the OOM killer takes the whole bot down mid-drop, which looks like a
# random "it just died" to the operator. Add swap only when RAM is small and the
# host has none, so a 4 GB+ instance keeps its fast path.
ensure_swap() {
  local mem_mb swap_mb
  mem_mb="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)"
  swap_mb="$(awk '/^SwapTotal:/{print int($2/1024)}' /proc/meminfo)"
  if (( mem_mb >= 3800 )) || (( swap_mb >= 1500 )); then
    log "Swap ok (RAM ${mem_mb}MB, swap ${swap_mb}MB) — leaving as is."
    return
  fi
  log "Adding a 2G swapfile (RAM ${mem_mb}MB, swap ${swap_mb}MB) to survive checkout bursts..."
  if ! fallocate -l 2G /swapfile 2>/dev/null; then
    dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  fi
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
  sysctl -w vm.swappiness=10 >/dev/null
  grep -q '^vm.swappiness' /etc/sysctl.conf || printf 'vm.swappiness=10\n' >> /etc/sysctl.conf
}
ensure_swap

# Do NOT use Ubuntu's `chromium` package: on 20.04+ it is a snap shim that
# frequently fails to launch headless from a systemd service (no snapd session,
# and the shim path moves). Install Google's own .deb instead.
#
# This runs in BOTH modes on purpose. Docker mode does not need the host binary
# (the image ships Debian chromium), but installing it keeps `/usr/bin/chromium`
# resolvable so a later DEPLOY_MODE=systemd redeploy works without re-running the
# browser step, and the version check below surfaces a broken repo either way.
#
# NOTE: Google's apt repo (dl.google.com/linux/chrome/deb) publishes
# google-chrome-stable/beta/unstable — there is NO package called `chromium`
# there. A symlink keeps the app's default /usr/bin/chromium path working.
if ! chromium --version >/dev/null 2>&1; then
  log 'Installing Chromium from the official Google package...'
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
    | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
  echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main' \
    > /etc/apt/sources.list.d/google-chrome.list
  apt-get update
  if apt-get install -y --no-install-recommends google-chrome-stable; then
    ln -sf /opt/google/chrome/chrome /usr/bin/chromium
  else
    log 'google-chrome-stable failed; falling back to the distro package.'
    apt-get install -y --no-install-recommends chromium || apt-get install -y --no-install-recommends chromium-browser || true
  fi
fi

if chromium --version >/dev/null 2>&1; then
  log "Chromium ready: $(chromium --version)"
else
  log 'WARNING: Chromium is not runnable — browser tasks will fail until it is installed.'
fi

if ! command -v node >/dev/null 2>&1 || [[ "$(node -p 'process.versions.node.split(".")[0]')" -lt "$NODE_MAJOR" ]]; then
  log "Installing Node.js ${NODE_MAJOR}.x..."
  curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -
  apt-get install -y nodejs
fi

# ---------- Docker engine + compose plugin ----------
# Installed here rather than in the docs because a fresh Lightsail box has no
# engine at all, and a half-configured docker is worse than none: we verify the
# daemon actually answers before switching mode to docker.
DOCKER_READY=0

docker_usable() { docker info >/dev/null 2>&1; }

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker_usable; then
    log 'Docker already installed and responding.'
  else
    log 'Installing Docker engine from the official repository...'
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
      "$(dpkg --print-architecture)" "$(. /etc/os-release && echo "$VERSION_CODENAME")" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update
    if ! apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
      warn 'Docker install failed.'
      return 1
    fi
  fi

  # Chromium writes a lot of container logs; unbounded json-file logs have
  # filled small Lightsail disks and wedged the daemon. Cap them, and keep
  # containers alive across a daemon restart.
  #
  # The JSON body below is brace-balanced, which is what lets the function
  # extractor in scripts/deploy-logic-check.sh count its way to the end of this
  # function instead of stopping at the first closing-brace-looking line.
  install -d -m 0755 /etc/docker
  if [[ ! -f /etc/docker/daemon.json ]]; then
    cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
JSON
  fi

  systemctl enable --now docker
  # Compose v2 ships as a CLI plugin; older apt trees still push the standalone
  # `docker-compose` python script, which needs a shim to keep one command name.
  if ! docker compose version >/dev/null 2>&1; then
    if command -v docker-compose >/dev/null 2>&1; then
      log 'Only standalone docker-compose present — shimming it as a plugin.'
      install -d -m 0755 /usr/local/lib/docker/cli-plugins
      ln -sf "$(command -v docker-compose)" /usr/local/lib/docker/cli-plugins/docker-compose
    else
      apt-get install -y --no-install-recommends docker-compose-plugin || true
    fi
  fi

  if ! docker_usable; then
    warn 'Docker daemon is not responding after install.'
    return 1
  fi
  if ! docker compose version >/dev/null 2>&1; then
    warn 'The docker compose plugin is unavailable.'
    return 1
  fi
  DOCKER_READY=1
  log "Docker ready: $(docker --version); $(docker compose version --short 2>/dev/null || echo 'compose ok')"
}

if [[ "$DEPLOY_MODE" != 'systemd' ]]; then
  if install_docker; then
    : # DOCKER_READY=1
  else
    if [[ "$DEPLOY_MODE" == 'docker' ]]; then
      warn 'DEPLOY_MODE=docker but Docker is unusable — falling back to the systemd install so the box still deploys.'
    fi
    DEPLOY_MODE=systemd
  fi
fi

# Route the container runtime's base image pulls through the same registry the
# app uses; Docker Hub rate-limits anonymous pulls per IP and a drop-night
# rebuild must not fail on a 429.
if [[ "$DOCKER_READY" == '1' ]]; then
  log 'Pre-pulling base images...'
  docker pull node:22-bookworm-slim || warn 'node:22-bookworm-slim pre-pull failed (build will retry).'
  docker pull golang:1.25-bookworm   || warn 'golang:1.25-bookworm pre-pull failed (build will retry).'
fi

# The Go toolchain is only needed by the HOST (systemd) path — the Dockerfile
# builds both helpers in its own builder stages. In docker mode it is skipped, so
# a container deploy does not spend ~2 minutes downloading a compiler it will not
# use. Run with DEPLOY_MODE=systemd if you ever need the host builds.
#
# The helper modules need a modern toolchain: vendor/akamai-bmp declares
# `go 1.25.3`, and GOTOOLCHAIN-based auto-upgrade only exists in Go >= 1.21.
# Ubuntu 22.04's `golang-go` is 1.18, which would silently fail both helper
# builds and leave the bot running WITHOUT the TLS sidecar (i.e. without the
# browser-grade JA3/JA4 fingerprint that Best Buy / Pokemon Center WAFs look at).
GO_VERSION="${GO_VERSION:-1.25.3}"

go_version_ok() {
  command -v go >/dev/null 2>&1 || return 1
  local have
  have="$(go env GOVERSION 2>/dev/null || go version 2>/dev/null | awk '{print $3}')"
  have="${have#go}"
  [ -n "$have" ] || return 1
  [ "$(printf '%s\n%s\n' "$GO_VERSION" "$have" | sort -V | head -n1)" = "$GO_VERSION" ]
}

if [[ "$DEPLOY_MODE" == 'systemd' ]] && ! go_version_ok; then
  case "$(uname -m)" in
    aarch64|arm64) GOARCH_PICK=arm64 ;;
    *)             GOARCH_PICK=amd64 ;;
  esac
  log "Installing Go ${GO_VERSION} (${GOARCH_PICK}) for native helper builds..."
  # Stage the extraction and only swap it into place on success, so a partial or
  # failed download never leaves /usr/local/go half-written.
  if curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH_PICK}.tar.gz" -o /tmp/go.tgz \
     && rm -rf /tmp/go-stage && mkdir -p /tmp/go-stage \
     && tar -C /tmp/go-stage -xzf /tmp/go.tgz \
     && [ -x /tmp/go-stage/go/bin/go ]; then
    rm -rf /usr/local/go
    mv /tmp/go-stage/go /usr/local/go
    rm -rf /tmp/go-stage /tmp/go.tgz
    ln -sf /usr/local/go/bin/go /usr/local/bin/go
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
    log "Go $(/usr/local/go/bin/go version | awk '{print $3}') installed to /usr/local/go"
  else
    rm -rf /tmp/go-stage /tmp/go.tgz
    log 'Go download/extract failed; continuing without optional native Go helpers.'
  fi
fi

if [[ "$DEPLOY_MODE" == 'systemd' ]]; then
  if command -v go >/dev/null 2>&1; then
    log "Go detected: $(go version)"
  else
    log 'Go unavailable; continuing without optional native Go helpers.'
  fi
elif [[ "$DOCKER_READY" == '1' ]]; then
  log 'Go helpers are compiled inside the image — skipping the host toolchain.'
fi

id -u "$APP_USER" >/dev/null 2>&1 || useradd --system --create-home --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
mkdir -p "$APP_DIR" "$APP_DIR/profiles" "$APP_DIR/orders" "$APP_DIR/.local"
chown -R "$APP_USER":"$APP_USER" "$APP_DIR"

# This script is designed to be run from the extracted project directory.
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$SRC_DIR" != "$APP_DIR" ]]; then
  log "Syncing application to $APP_DIR..."
  # --delete keeps the tree clean, but the runtime state below MUST be excluded
  # or every redeploy silently wipes the production database, browser profiles
  # and captured orders. `sneakerbot.db*` covers the WAL/SHM sidecars too.
  rsync -a --delete \
    --exclude '.env' \
    --exclude 'node_modules' \
    --exclude 'sneakerbot.db' \
    --exclude 'sneakerbot.db-wal' \
    --exclude 'sneakerbot.db-shm' \
    --exclude 'profiles' \
    --exclude 'orders' \
    --exclude '.local' \
    --exclude 'tls-sidecar/sidecar' \
    --exclude 'vendor/akamai-bmp-server' \
    "$SRC_DIR/" "$APP_DIR/"
fi

cd "$APP_DIR"

# Bootstrap .env on first deploy. Without this the app boots with the fallback
# SESSION_SECRET (every session invalidated on restart) and an oversized DB pool.
if [[ ! -f "$APP_DIR/.env" ]]; then
  log 'Creating .env from lightsail.env.example...'
  if [[ -f "$APP_DIR/lightsail.env.example" ]]; then
    cp "$APP_DIR/lightsail.env.example" "$APP_DIR/.env"
  else
    printf 'NODE_ENV=production\nPORT=%s\n' "$PORT" > "$APP_DIR/.env"
  fi
  SECRET="$(openssl rand -hex 32)"
  if grep -q '^SESSION_SECRET=' "$APP_DIR/.env"; then
    sed -i "s|^SESSION_SECRET=.*|SESSION_SECRET=${SECRET}|" "$APP_DIR/.env"
  else
    printf 'SESSION_SECRET=%s\n' "$SECRET" >> "$APP_DIR/.env"
  fi
  log 'Generated a random SESSION_SECRET.'
else
  log 'Keeping the existing .env.'
fi
chown "$APP_USER":"$APP_USER" "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"

# Runtime state directories. `touch` the SQLite file so it exists as a FILE: if
# it is ever mounted (Docker bind-mount) while absent, the engine creates a
# *directory* at that path and better-sqlite3 fails to open it.
mkdir -p "$APP_DIR/profiles" "$APP_DIR/orders" "$APP_DIR/.local"
[[ -f "$APP_DIR/sneakerbot.db" ]] || : > "$APP_DIR/sneakerbot.db"
chown -R "$APP_USER":"$APP_USER" "$APP_DIR/profiles" "$APP_DIR/orders" "$APP_DIR/.local"
chown "$APP_USER":"$APP_USER" "$APP_DIR/sneakerbot.db"
chmod 600 "$APP_DIR/sneakerbot.db"

log 'Installing Node dependencies from the public npm registry...'
if [[ "$DEPLOY_MODE" == 'systemd' ]]; then
  runuser -u "$APP_USER" -- env npm_config_registry=https://registry.npmjs.org npm ci --omit=dev

  # Only compile the Go helpers when a compatible Go toolchain is available.
  if command -v go >/dev/null 2>&1; then
    log 'Building TLS sidecar for this host...'
    if (cd tls-sidecar && GOTOOLCHAIN=auto go build -trimpath -ldflags='-s -w' -buildvcs=false -o sidecar .); then
      chmod +x tls-sidecar/sidecar
    else
      log 'TLS sidecar build failed; continuing without optional sidecar.'
      rm -f tls-sidecar/sidecar
    fi
    log 'Building Akamai helper for this host...'
    if (cd vendor/akamai-bmp && GOTOOLCHAIN=auto go build -trimpath -ldflags='-s -w' -buildvcs=false -o ../akamai-bmp-server ./cmd/akamai-bmp-server/main.go); then
      chmod +x vendor/akamai-bmp-server
    else
      log 'Akamai helper build failed; continuing without optional helper.'
      rm -f vendor/akamai-bmp-server
    fi
  else
    log 'Go is unavailable; removing non-portable checked-in helper binaries.'
    rm -f tls-sidecar/sidecar vendor/akamai-bmp-server
  fi
else
  log 'Docker mode — dependencies and Go helpers are built inside the image.'
  # A host-built binary copied into the image would be shadowed by the
  # Dockerfile's own COPY; dropping them keeps the build context honest.
  rm -f tls-sidecar/sidecar vendor/akamai-bmp-server
fi

if [[ "$DEPLOY_MODE" == 'systemd' ]]; then
cat > /etc/systemd/system/sneakerbot.service <<UNIT
[Unit]
Description=SneakerBot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=-$APP_DIR/.env
Environment=NODE_ENV=production
Environment=PORT=$PORT
Environment=DB_POOL_MAX=5
Environment=PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium
ExecStart=$APP_DIR/start.sh
Restart=always
RestartSec=3
TimeoutStopSec=30
KillSignal=SIGTERM
PrivateTmp=true
# Chromium needs far more than the 64 MB default /dev/shm; without this the
# renderer crashes mid-checkout on small instances.
PrivateDevices=false
LimitNOFILE=65535
# Give the process a moment to bind before the first health probe.
ExecStartPost=/bin/sh -c 'for i in \$(seq 1 30); do curl -fsS http://127.0.0.1:$PORT/healthz >/dev/null 2>&1 && exit 0; sleep 1; done; exit 0'

[Install]
WantedBy=multi-user.target
UNIT

chown -R "$APP_USER":"$APP_USER" "$APP_DIR"
systemctl daemon-reload
systemctl enable sneakerbot.service
systemctl restart sneakerbot.service
else
  # ---------- Docker path ----------
  # Compose reads $APP_DIR/.env for ${...} interpolation (it is the project
  # directory) and the container gets its own environment from the compose
  # service block. `.env` is 600/owned by the service user and compose runs as
  # root here, so no extra exposure is introduced.
  #
  # The container runs as root by design (Chromium needs to write its own
  # sandbox/cache), so the bind-mounted state must be writable from inside it.
  # SQLite also needs the *file* to exist, hence the touch above.
  chown -R "$APP_USER":"$APP_USER" "$APP_DIR" 2>/dev/null || true
  chmod 666 "$APP_DIR/sneakerbot.db"

  if ! grep -q '^SESSION_SECRET=.\{32,\}' "$APP_DIR/.env" 2>/dev/null; then
    warn '.env has no usable SESSION_SECRET — sessions will be invalidated on restart.'
  fi

  log 'Building the application image (this pulls Chromium and both Go helpers)...'
  if ! docker compose build --pull; then
    echo 'Docker build failed — see the output above.' >&2
    exit 3
  fi

  log 'Starting the container stack...'
  # --remove-orphans clears containers from a previous compose file revision.
  docker compose up -d --remove-orphans

  # The unit only exists to bring the stack back after a reboot; compose owns
  # the process lifecycle from here on.
  cat > /etc/systemd/system/sneakerbot-compose.service <<UNIT
[Unit]
Description=SneakerBot (docker compose)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable sneakerbot-compose.service
fi

# Verify the service actually came up instead of reporting success blindly. A
# container that is "up" is not the same as an app that answers — probe /healthz.
HEALTH_PROBE_SECS="${HEALTH_PROBE_SECS:-90}"
log "Waiting up to ${HEALTH_PROBE_SECS}s for /healthz..."
HEALTHY=0
for _ in $(seq 1 "$HEALTH_PROBE_SECS"); do
  if curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then HEALTHY=1; break; fi
  sleep 1
done

if [[ "$HEALTHY" == '1' ]]; then
  log "Deployment complete via ${DEPLOY_MODE} — health check passed."
else
  log "Service started but /healthz did not respond within ${HEALTH_PROBE_SECS}s. Recent logs:"
  if [[ "$DEPLOY_MODE" == 'docker' ]]; then
    docker compose ps || true
    docker compose logs --tail 60 --no-color || true
  else
    journalctl -u sneakerbot.service -n 40 --no-pager || true
  fi
fi

if [[ "$DEPLOY_MODE" == 'docker' ]]; then
  log 'Manage:  docker compose ps; docker compose logs -f; docker compose restart'
  log 'Restart after reboot: systemctl restart sneakerbot-compose.service'
else
  log 'Manage:  systemctl status sneakerbot.service'
fi
log "Health:  curl -fsS http://127.0.0.1:${PORT}/healthz"
log 'Public access requires a Lightsail firewall rule for the chosen port (or a reverse proxy on 80/443).'
