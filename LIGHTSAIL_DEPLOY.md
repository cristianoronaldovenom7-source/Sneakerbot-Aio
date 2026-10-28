# Lightsail deployment

`sudo ./deploy-lightsail.sh` is the whole install. By default it installs Docker
and the compose plugin, builds the image, and brings the stack up under compose —
see [Docker mode](#docker-mode-default). Set `DEPLOY_MODE=systemd` to run straight
on the host instead.

## Instance size

Plan for **2 GB RAM minimum, 4 GB recommended**. Chromium is the constraint, not
Node: one headless checkout browser is roughly 350–500 MB, and the app clamps its
own checkout concurrency from measured RAM (see `CHECKOUT_MEMORY_BUDGET_MB` /
`CHECKOUT_RESERVED_MEMORY_MB`). On a 512 MB or 1 GB instance the app still starts
and monitors fine, but checkouts will queue and swap.

The installer adds a 2 GB swapfile automatically when the host has under ~3.8 GB
RAM and less than 1.5 GB of swap already, so a 2 GB box survives a checkout burst
instead of being OOM-killed mid-drop. Nothing is added on larger instances.

Use an **x86_64 (amd64)** plan. The Dockerfile cross-compiles both Go helpers for
`GOARCH=amd64`; the installer does build the TLS sidecar natively on arm64, so
Graviton works on a `DEPLOY_MODE=systemd` install but not from the container image.

## Docker mode (default)

1. Upload and extract the bundle into the instance.
2. Run `sudo ./deploy-lightsail.sh`.
3. The script installs Docker + compose, builds the image, starts the stack and
   polls `/healthz` until it answers (up to `HEALTH_PROBE_SECS`, default 90s).
4. Check `docker compose ps` and `docker compose logs -f`.
5. In the Lightsail instance firewall, allow the public port you intend to expose,
   or put the app behind nginx on 80/443.

`/opt/sneakerbot/.env` is created with a generated `SESSION_SECRET` on first run
and preserved on redeploy; compose interpolates it. Edit it to add proxy URLs.

Manage it with `docker compose` (`ps`, `logs -f`, `restart`, `down`). A
`sneakerbot-compose.service` unit restarts the stack after a reboot.

- The Docker install is verified before anything is built: a daemon that does not
  answer, or a missing compose plugin, is treated as failure. With
  `DEPLOY_MODE=auto` (or the default `docker`) that falls back to the systemd
  install rather than leaving the box undeployed.
- Container logs are capped at 3 × 10 MB (Dockerfile-level `daemon.json` and the
  compose service) because unbounded Chromium output has filled small disks.
- `shm_size: 1gb` and `stop_grace_period: 30s` are set in `docker-compose.yml`:
  Chromium renderers die on Docker's 64 MB `/dev/shm` default, and 10s is not
  enough to close cleanly mid-checkout.

## systemd mode

`DEPLOY_MODE=systemd sudo ./deploy-lightsail.sh` skips Docker entirely and builds
the app natively, supervised by `sneakerbot.service` with a restart policy. The
installer removes any bundled Replit/Nix-linked helper binaries and builds native
Linux helpers when Go is available.

**Redeploys preserve the database, browser profiles, captured orders and `.env`.**
Those paths are excluded from the sync step; only code is replaced.

## Lightsail container service

Build the image with the included Dockerfile, push it to Lightsail, expose
container port `3000` as HTTP, and use `/healthz` as the health-check path. The
Docker image builds both Go helpers inside Linux instead of copying host binaries.

## Common failure prevention

- `npm ci` uses `https://registry.npmjs.org`; the lockfile contains no Replit package-firewall URLs.
- The app binds to `0.0.0.0`.
- Production DB pool defaults to 5 instead of 15 for small Lightsail instances.
- Chromium comes from Google's apt repo (`google-chrome-stable`, symlinked to
  `/usr/bin/chromium`), not Ubuntu's `chromium` snap shim, which does not launch
  reliably from a systemd service. The container path installs `chromium` from
  Debian instead, which does work.
- The deploy fails loudly: after start it polls `/healthz` and prints the service
  or container logs when the app does not come up.
- A systemd restart policy recovers the service after a process crash or VM reboot;
  compose uses `restart: unless-stopped`.
- Runtime state directories are created with the service user's ownership.
- `bash scripts/deploy-logic-check.sh` exercises the mode/swap/docker-failure
  decisions without needing root or Docker.

## Role-separated proxies
The dashboard supports separate Monitoring Proxy and Checkout Proxy assignments per task. Existing `proxy_id` tasks remain backward-compatible.

For a residential provider, set `RESIDENTIAL_PROXY_URL` in the Lightsail environment. You can override it per role with `RESIDENTIAL_MONITOR_PROXY_URL` and `RESIDENTIAL_CHECKOUT_PROXY_URL`. The dashboard will show a `Residential Gateway` choice when configured. The application does not supply residential IPs itself; the environment variable is the provider endpoint.
