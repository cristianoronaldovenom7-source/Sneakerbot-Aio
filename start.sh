#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

export NODE_ENV="${NODE_ENV:-production}"
export PORT="${PORT:-3000}"
# SQLite serialises on a single connection; a large pool just wastes handles.
# Keep this modest so a 512 MB–1 GB Lightsail box is not overcommitted.
export DB_POOL_MAX="${DB_POOL_MAX:-5}"
export CPU_PERFORMANCE_MODE="${CPU_PERFORMANCE_MODE:-max}"
export HTTP_MAX_SOCKETS="${HTTP_MAX_SOCKETS:-128}"
export HTTP_MAX_FREE_SOCKETS="${HTTP_MAX_FREE_SOCKETS:-32}"
export HTTP_SOCKET_TIMEOUT_MS="${HTTP_SOCKET_TIMEOUT_MS:-30000}"
export PUPPETEER_EXECUTABLE_PATH="${PUPPETEER_EXECUTABLE_PATH:-}"

# Let launcher.mjs size the libuv threadpool from the actual core count instead
# of pinning 8 threads onto a 1-vCPU instance.
if [[ -z "${UV_THREADPOOL_SIZE:-}" ]]; then
  CORES="$(nproc 2>/dev/null || echo 1)"
  export UV_THREADPOOL_SIZE="$(( CORES + 2 < 8 ? 8 : (CORES + 2 > 16 ? 16 : CORES + 2) ))"
fi

log() { printf '[start.sh] %s\n' "$*"; }

# `set -e` plus an unresolvable Chromium is the most common "it started but every
# task fails" report — surface it at boot rather than per task.
CHROME_BIN="${PUPPETEER_EXECUTABLE_PATH:-/usr/bin/chromium}"
if [[ -x "$CHROME_BIN" ]]; then
  log "Chromium: $CHROME_BIN"
else
  log "WARNING: Chromium not executable at $CHROME_BIN — browser tasks will fail."
fi

# Docker bind-mounts a missing file path as a DIRECTORY. Repair it before the
# DB layer tries to open ./sneakerbot.db as a file.
if [[ -d "$ROOT_DIR/sneakerbot.db" ]]; then
  log 'sneakerbot.db exists as a directory — repairing to a file.'
  rmdir "$ROOT_DIR/sneakerbot.db" 2>/dev/null || rm -rf "$ROOT_DIR/sneakerbot.db"
  : > "$ROOT_DIR/sneakerbot.db"
fi

mkdir -p "$ROOT_DIR/profiles" "$ROOT_DIR/orders" "$ROOT_DIR/.local"

# The checked-in Replit builds of the Go helpers use a Nix loader path and are
# not portable to a normal Ubuntu/Debian Lightsail VM. Prefer locally compiled
# helpers when present; otherwise leave the Node app able to start and let the
# optional helper fail closed.
if [[ -x "$ROOT_DIR/tls-sidecar/sidecar" ]]; then
  :
elif [[ -x "$ROOT_DIR/tls-sidecar/tls-sidecar" && "${USE_PREBUILT_REPLIT_HELPER:-0}" == "1" ]]; then
  log 'Using explicitly requested prebuilt TLS sidecar.'
else
  rm -f "$ROOT_DIR/tls-sidecar/sidecar"
fi

SIDECAR_PID=""
if [[ -x "$ROOT_DIR/tls-sidecar/sidecar" || ( -x "$ROOT_DIR/tls-sidecar/tls-sidecar" && "${USE_PREBUILT_REPLIT_HELPER:-0}" == "1" ) ]]; then
  SIDECAR_BIN="$ROOT_DIR/tls-sidecar/sidecar"
  [[ -x "$SIDECAR_BIN" ]] || SIDECAR_BIN="$ROOT_DIR/tls-sidecar/tls-sidecar"
  log "Starting TLS sidecar: $SIDECAR_BIN"
  "$SIDECAR_BIN" &
  SIDECAR_PID=$!
fi

cleanup() {
  if [[ -n "$SIDECAR_PID" ]]; then
    kill "$SIDECAR_PID" 2>/dev/null || true
    wait "$SIDECAR_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

log "Running database migrations..."
npm run migrate

log "CPU mode: ${CPU_PERFORMANCE_MODE}; UV threadpool: ${UV_THREADPOOL_SIZE}; HTTP keep-alive sockets: ${HTTP_MAX_SOCKETS}"
log "Starting SneakerBot on ${PORT}..."
# `exec` makes Node the supervised process so systemd/dumb-init see real exit
# codes and SIGTERM. The sidecar is a sibling in the same cgroup, so it is torn
# down with the service on stop/restart.
#
# launcher.mjs, not app.js: it is what runs the runtime bootstrap (helpers/
# bootstrap-env.js) and sizes the threadpool. Exec'ing app.js directly skipped
# both, so a container with no Chromium and no Go had no chance to repair itself.
exec node launcher.mjs
