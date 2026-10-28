# SneakerBot Setup Guide

Pick your deployment target:

- **[AWS EC2 + Docker (recommended)](#aws-ec2--docker)** — runs 24/7 in the cloud
- **[AWS Elastic Beanstalk](#aws-elastic-beanstalk)** — managed Node.js hosting
- **[AWS App Runner](#aws-app-runner)** — fully managed, no server config
- **[Windows](#windows)** — your home PC
- **[Mac](#mac)** — your home Mac
- **[Linux](#linux)** — any Linux machine

---

## Fix: "Can't find package.json"

This error almost always means the ZIP was created from the **wrong folder**. AWS expects `package.json` at the root of the archive, not inside a subfolder.

**Wrong** — zipped the parent folder (creates `sneakerbot/package.json` inside):
```bash
cd ..
zip -r app.zip sneakerbot/         # ❌ package.json ends up nested
```

**Correct** — zipped from inside the project:
```bash
cd sneakerbot
zip -r ../app.zip . --exclude="node_modules/*" --exclude=".git/*"   # ✅
```

On Windows (PowerShell), from inside the project folder:
```powershell
Compress-Archive -Path ".\*" -DestinationPath "..\app.zip"
```

Upload `app.zip` to Elastic Beanstalk / Lambda / whatever service you're using.

---

## Automatic runtime setup (optional)

You can normally skip the manual runtime installs described below. On boot,
`launcher.mjs` checks for Node, Go, Python and a Chrome/Chromium binary, and
downloads whatever is missing into `.local/` inside the project. Everything it
fetches is verified against the publisher's SHA256 before use, versions are
pinned, and a failure is only ever a warning — the bot still starts (degraded to
Node TLS, no browser) rather than refusing to boot.

Skip it entirely, or run it without network access:

```bash
BOOTSTRAP_DISABLE=1 npm start     # never touch the network
BOOTSTRAP_OFFLINE=1 npm start     # report what is missing, download nothing
```

Point the installs somewhere else, or override a pin for an internal mirror:

```bash
BOOTSTRAP_DIR=/opt/sneakerbot-runtimes
BOOTSTRAP_GO_VERSION=1.25.3
BOOTSTRAP_NODE_URL=https://mirror.internal/node/v22.14.0/node-v22.14.0-linux-x64.tar.gz
```

Managed binaries are prepended to `PATH` for the life of the process, so a
runtime downloaded at boot is usable immediately. A newly installed browser is
exported through `PUPPETEER_EXECUTABLE_PATH` the same way, so the first launch
already finds it.

`.local/bin`, `.local/downloads` and `.local/runtimes` are gitignored — they hold
hundreds of megabytes. Delete the folders to force a clean re-download.

---

## AWS Elastic Beanstalk

The most common deployment path if you're using the AWS console.

### Step 1 — Create the ZIP correctly

From inside the project folder (see the fix above if you've had package.json errors):

```bash
zip -r ../sneakerbot.zip . --exclude="node_modules/*" --exclude=".git/*" --exclude="sneakerbot.db"
```

### Step 2 — Create an Elastic Beanstalk environment

1. Open the [Elastic Beanstalk console](https://console.aws.amazon.com/elasticbeanstalk)
2. Click **Create application**
3. Platform: **Node.js**, Platform branch: **Node.js 20**
4. Application code: **Upload your code** → upload `sneakerbot.zip`

### Step 3 — Set environment variables

In the EB console → Configuration → Updates, monitoring, and logging → Environment properties, add:

| Key | Value |
|---|---|
| `SESSION_SECRET` | any random string (run `openssl rand -hex 32`) |
| `NODE_ENV` | `production` |
| `PORT` | `3000` |
| `DATABASE_URL` | (optional) your RDS PostgreSQL URL |

### Step 4 — Set the start command

In Configuration → Updates → Platform software, set:

- **Node command:** `node app.js`

EB runs `npm install` automatically before starting.

---

## AWS App Runner

Fully managed — no EC2 or config required. Uses `apprunner.yaml` (already in the project root).

### From source code (GitHub)

1. Push your project to GitHub
2. Open [App Runner console](https://console.aws.amazon.com/apprunner) → **Create service**
3. Source: **Source code repository** → connect your GitHub → select the repo + branch
4. Build settings: **Use configuration file** (it will find `apprunner.yaml` automatically)
5. Configure environment variables: `SESSION_SECRET`, `NODE_ENV=production`
6. Port: `3000`

### From a container image

```bash
# Build and push to ECR first, then point App Runner at the image
docker build -t sneakerbot .
aws ecr create-repository --repository-name sneakerbot
docker tag sneakerbot:latest YOUR-ACCOUNT.dkr.ecr.REGION.amazonaws.com/sneakerbot:latest
aws ecr get-login-password | docker login --username AWS --password-stdin YOUR-ACCOUNT.dkr.ecr.REGION.amazonaws.com
docker push YOUR-ACCOUNT.dkr.ecr.REGION.amazonaws.com/sneakerbot:latest
```

Then in the App Runner console, choose **Container registry** and select your ECR image.

---

## AWS EC2 + Docker

### What you need
- An EC2 instance running **Ubuntu 22.04 or 24.04** (t3.medium or larger — Chrome is memory-hungry)
- Port **3000** open in your EC2 security group (inbound TCP from your IP)
- SSH access to the instance

### Step 1 — Install Docker on EC2

SSH into your instance, then run:

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin
sudo usermod -aG docker ubuntu
newgrp docker
```

### Step 2 — Copy the project to EC2

Option A — clone from GitHub:
```bash
git clone https://github.com/YOUR_USERNAME/sneakerbot.git
cd sneakerbot
```

Option B — copy from your local machine via `scp`:
```bash
# Run this on your local machine:
scp -r ./sneakerbot ubuntu@YOUR-EC2-IP:~/sneakerbot
```
Then on EC2: `cd ~/sneakerbot`

### Step 3 — Create your .env file

```bash
cp .env.example .env
nano .env
```

At minimum set `SESSION_SECRET`. Generate a random one:
```bash
openssl rand -hex 32
```
Paste the output as the `SESSION_SECRET` value in `.env`.

### Step 4 — Build and start

```bash
docker compose up -d --build
```

First build takes 3–5 minutes (downloads Chrome, Go, Node). After that it starts in seconds.

### Step 5 — Check it's running

```bash
docker compose logs -f
```

Open `http://YOUR-EC2-IP:3000` in your browser — you should see the SneakerBot login page.

### Stopping / restarting

```bash
docker compose down        # stop
docker compose up -d       # start again (uses cached build)
docker compose restart     # restart without rebuild
```

### Updating after code changes

```bash
git pull && docker compose up -d --build
```

### Persistent data on AWS

Docker mounts these from your EC2 filesystem — your data survives rebuilds:

| What | EC2 path |
|---|---|
| Database | `./sneakerbot.db` |
| Chrome profiles | `./profiles/` |
| Order captures | `./orders/` |
| Cookie jar | `./.local/cookie-jar.json` |

### Using AWS RDS instead of SQLite (optional)

If you want PostgreSQL (e.g. for multi-instance or managed backups):

1. Create an RDS PostgreSQL instance in the same region as your EC2
2. Add to your `.env`:
   ```
   DATABASE_URL=postgresql://sneakerbot:yourpassword@your-db.region.rds.amazonaws.com:5432/sneakerbot
   ```
3. `docker compose up -d --build`

The bot auto-detects `DATABASE_URL` and switches from SQLite to PostgreSQL automatically.

---

## Without Docker (direct on EC2)

```bash
# Node.js 20
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# Go 1.22
wget https://go.dev/dl/go1.22.5.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.22.5.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc && source ~/.bashrc

# Chromium
sudo apt-get install -y chromium-browser

# Build the TLS sidecar once
cd tls-sidecar && go build -buildvcs=false -o sidecar . && cd ..

# Configure
npm install
cp .env.example .env
nano .env   # set SESSION_SECRET + PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser

npm run migrate
```

Run with PM2 (keeps running after you log out):

```bash
sudo npm install -g pm2
pm2 start "./tls-sidecar/sidecar" --name tls-sidecar
pm2 start "node app.js" --name sneakerbot
pm2 startup && pm2 save
```

---

## Windows

### Step 1 — Install Node.js
1. Go to https://nodejs.org → click the big green **LTS** button
2. Run the installer, click Next on everything

### Step 2 — Install Go
1. Go to https://go.dev/dl/ → download the Windows `.msi`
2. Run it. Open a new Command Prompt and run `go version` to confirm.

### Step 3 — Install Google Chrome
Download from https://www.google.com/chrome/ if you don't have it.

### Step 4 — Get the project and configure

```cmd
npm install
copy .env.example .env
```

Edit `.env` in Notepad:
```
PUPPETEER_EXECUTABLE_PATH=C:/Program Files/Google/Chrome/Application/chrome.exe
SESSION_SECRET=any-random-string-here
```

### Step 5 — Run (two Command Prompt windows)

**Window 1 — TLS sidecar:**
```cmd
cd tls-sidecar && go run .
```

**Window 2 — Bot:**
```cmd
npm run migrate && node app.js
```

Open http://localhost:3000 in your browser.

---

## Mac

```bash
# Install Node.js and Go (requires Homebrew — https://brew.sh)
brew install node@20 go

npm install
cp .env.example .env
# Edit .env — set SESSION_SECRET and:
# PUPPETEER_EXECUTABLE_PATH=/Applications/Google Chrome.app/Contents/MacOS/Google Chrome
```

Run in two terminals:

```bash
# Terminal 1:
cd tls-sidecar && go run .

# Terminal 2:
npm run migrate && node app.js
```

---

## Linux

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs golang-go chromium-browser

npm install
cp .env.example .env
nano .env  # set PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser

# Terminal 1:
cd tls-sidecar && go run .

# Terminal 2:
npm run migrate && node app.js
```

---

## First login

The first time you open SneakerBot, it asks you to create an admin account. That's your login for all future sessions.

## Proxies (required for Pokemon Center and Walmart checkout)

Datacenter IPs are blocked by Imperva (Pokemon Center) and PerimeterX (Walmart). You need a residential or mobile proxy:

```bash
POST /v1/proxies
{
  "label": "My proxy",
  "host": "proxy.provider.com",
  "port": 12345,
  "username": "user",
  "password": "pass"
}
```

Then set `proxy_id` on your task. The whole stack (session warming + checkout browser + HTTP polling) routes through it automatically.


### Lightweight operational ML
The deployment includes a dependency-free online model (`helpers/ops-ml.js`) that learns from retry outcomes and adjusts retry delays by at most ±15%. It does not choose proxies, identity/fingerprint settings, CAPTCHA behavior, or checkout decisions. State is persisted to `data/ops-ml.json` and is disabled with `OPS_ML_ENABLED=false` if needed.

## Residential proxy bandwidth saver
The default residential policy is designed for a ~1 GiB/month residential allowance. Auto monitoring stays direct; the residential gateway is used automatically for checkout. To explicitly spend residential bandwidth on monitoring, assign a monitor proxy or choose `residential_env` for the monitor role.

Recommended environment:
- `RESIDENTIAL_MONTHLY_BUDGET_MB=1024`
- `RESIDENTIAL_BUDGET_STRICT=true`
- `RESIDENTIAL_CHECKOUT_RESERVE_MB=8`

The dashboard's Proxies tab shows the current monthly residential usage. Provider billing can differ slightly from application-side byte accounting, so leave headroom if the provider counts connection overhead or DNS/transport bytes separately.
