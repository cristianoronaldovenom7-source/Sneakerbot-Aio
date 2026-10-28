import 'dotenv/config';
import express from 'express';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import router from './routes/index.js';
import { restoreMonitors, startPersistentMonitorScheduler, stopPersistentMonitorScheduler, startPcBusinessHoursScheduler, stopPcBusinessHoursScheduler } from './api/Tasks/monitor.js';
import { startAkamaiServer, stopAkamaiServer } from './helpers/akamai.js';
import { startTrainer, stopTrainer } from './helpers/trainer.js';
import { sessionMiddleware, requireAuth, isFirstRun, cookieSecure } from './helpers/auth.js';
import { rateLimit, loginKey } from './helpers/rate-limit.js';
import { tlsVerifyMode } from './helpers/stock-monitor.js';
import authRouter from './api/Auth/index.js';
import { disposeAll as disposePrewarmAll } from './helpers/prewarm-engine.js';
import db from './db/index.js';
import { cpuSnapshot, performanceProfile } from './helpers/cpu-performance.js';
import { networkPerformanceSnapshot } from './helpers/network-performance.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

const app = express();
const PORT = process.env.PORT || 3000;

app.disable('x-powered-by');

// Rate-limit keys use req.ip, which behind a reverse proxy is the proxy's address
// unless Express is told to trust it — every client would otherwise share one
// bucket. Default to 1 hop (the usual single nginx/Lightsail front); operators on
// a different topology override with TRUST_PROXY.
const trustProxy = String(process.env.TRUST_PROXY ?? '').trim();
app.set('trust proxy', trustProxy === '' ? 1 : (Number.isFinite(Number(trustProxy)) ? Number(trustProxy) : trustProxy));

app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'SAMEORIGIN');
  res.setHeader('Referrer-Policy', 'no-referrer');
  next();
});

app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: false, limit: '1mb' }));

// Login is the only credential surface and it was unlimited: bcrypt at cost 12 is
// deliberately expensive, which also makes it a cheap way to pin a core. 10 tries
// per 5 minutes, keyed on username+IP so one attacker cannot lock the owner out.
app.use('/auth/login', rateLimit({
  name: 'login', windowMs: 5 * 60_000, max: 10, key: loginKey
}));
app.use('/auth/setup', rateLimit({ name: 'setup', windowMs: 10 * 60_000, max: 10 }));

// Broad API ceiling. Generous enough that a dashboard poll loop and a 1000-task
// monitor fleet never notice, tight enough that a runaway tab cannot starve
// checkout traffic. 429s carry Retry-After so a well-behaved client backs off.
app.use('/v1', rateLimit({ name: 'api', windowMs: 60_000, max: 600 }));

// Liveness + dependency readiness. Unauthenticated, so it must stay cheap and must
// not leak secrets — it reports shapes, not values.
//
// Returns 503 when a hard dependency is down so a load balancer takes the instance
// out, and 200 while merely degraded (queue pressure, no TLS sidecar) so a single
// soft fault does not page anyone. That distinction is the difference between a
// monitor and an alarm generator.
app.get('/healthz', async (_req, res) => {
  const mem = process.memoryUsage();
  const checks = {};

  try {
    await db.raw('select 1');
    checks.database = { ok: true };
  } catch (err) {
    checks.database = { ok: false, error: err.message.slice(0, 120) };
  }

  try {
    const { sidecarState } = await import('./helpers/tls-client.js');
    // The sidecar is an optimisation, not a hard dependency: Node TLS degrades in.
    checks.tlsSidecar = { ok: sidecarState() === 'up', degradedOnly: true };
  } catch (_) {
    checks.tlsSidecar = { ok: false, degradedOnly: true };
  }

  let activeMonitors = null;
  try {
    const { getAllMonitors } = await import('./helpers/monitor-store.js');
    activeMonitors = Object.values(getAllMonitors() || {}).filter((m) => m?.active).length;
  } catch (_) { /* reported as null */ }

  const hardDown = Object.values(checks).some((c) => !c.ok && !c.degradedOnly) || Boolean(_req.app?.locals?.startupFailed);
  const payload = {
    ok: !hardDown,
    uptime: Math.round(process.uptime()),
    activeMonitors,
    checks,
    // A failed boot is itself a health signal now that we stay up instead of exiting.
    ...(_req.app?.locals?.startupFailed
      ? { startup: { ok: false, error: _req.app.locals.startupError || 'startup incomplete' } }
      : {}),
    // Ops needs to see the security posture, not just liveness. Both of these were
    // silent defaults before.
    security: {
      tlsVerification: tlsVerifyMode(),
      sessionSecret: process.env.SESSION_SECRET ? 'configured' : 'fallback',
      cookieSecure: cookieSecure() ? 'on' : 'off'
    },
    memory: {
      rssMb: Math.round(mem.rss / 1048576),
      heapUsedMb: Math.round(mem.heapUsed / 1048576),
      heapTotalMb: Math.round(mem.heapTotal / 1048576)
    },
    cpu: cpuSnapshot(),
    performance: performanceProfile(),
    network: networkPerformanceSnapshot()
  };

  // Shallow endpoint for LB probe paths that only want a boolean.
  if (_req.query?.shallow === '1') return res.status(200).json({ ok: true });

  return res.status(hardDown ? 503 : 200).json(payload);
});

// Session must be before all routes
app.use(sessionMiddleware);

// Auth routes (login, logout, setup, register, approve/decline) — no auth required
app.use(authRouter);

// Static files (CSS, JS, images, harvester.html) — no auth needed.
// In development, disable caching so UI edits (dashboard HTML/JS/CSS) always
// show up on the next load instead of serving a stale cached copy. Production
// keeps normal caching for performance.
const isDev = process.env.NODE_ENV !== 'production';
app.use(express.static(join(__dirname, 'public'), {
  index: false,
  etag: !isDev,
  lastModified: !isDev,
  cacheControl: !isDev,
  setHeaders: (res) => {
    if (isDev) res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
  }
}));

// Root: check auth, redirect to /setup on first run, /login otherwise
app.get('/', async (req, res) => {
  if (!req.session?.userId) {
    const first = await isFirstRun().catch(() => false);
    return res.redirect(first ? '/setup' : '/login');
  }
  if (isDev) res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
  res.sendFile(join(__dirname, 'public', 'index.html'));
});

// All API routes require a valid session
app.use('/v1', requireAuth, router);

app.use((err, req, res, next) => {
  if (res.headersSent) return;
  const status = err.statusCode || 500;
  const message = err.message || 'Internal Server Error';
  res.status(status).json({ success: false, message, data: {} });
});

let shuttingDown = false;

const shutdown = async (reason = 'signal') => {
  if (shuttingDown) return;
  shuttingDown = true;
  console.error(`[App] Graceful shutdown: ${reason}`);
  stopTrainer();
  stopAkamaiServer();
  stopPersistentMonitorScheduler();
  stopPcBusinessHoursScheduler();
  await disposePrewarmAll().catch(() => {});
  await new Promise((resolve) => server.close(resolve));
};

const server = app.listen(PORT, '0.0.0.0', async () => {
  console.log(`SneakerBot API running on port ${PORT}`);
  try {
    // Keep `npm start` and other direct launches as safe as the deployment
    // wrapper: apply pending schema migrations before any scheduler/monitor
    // queries touch newly-added columns or indexes. Knex serializes concurrent
    // migrations, so this is safe for normal single-process deployments and
    // multi-instance Postgres deployments.
    await db.migrate.latest();
    await startAkamaiServer();
    await restoreMonitors();
    startPersistentMonitorScheduler();
    startPcBusinessHoursScheduler();
    startTrainer();
  } catch (err) {
    // Do NOT exit. A hard exit turns a diagnosable dependency outage into a crash
    // loop: the proxy restarts us forever and /healthz never answers, so all an
    // operator sees is "connection refused". Staying up lets /healthz report 503 with
    // the actual failing check, and monitors can be restored once the DB returns.
    console.error(`[App] Startup initialization failed: ${err.message}`, err.stack);
    app.locals.startupFailed = true;
    app.locals.startupError = err.message;
    const retry = Number(process.env.STARTUP_RETRY_MS || 30_000);
    if (retry > 0) {
      setTimeout(() => {
        restoreMonitors()
          .then(() => {
            startPersistentMonitorScheduler();
            startPcBusinessHoursScheduler();
            app.locals.startupFailed = false;
            app.locals.startupError = null;
            console.log('[App] Startup retry succeeded — monitors restored');
          })
          .catch((e) => console.error(`[App] Startup retry failed: ${e.message}`));
      }, retry).unref?.();
    }
  }
});

process.on('SIGTERM', () => { shutdown('SIGTERM').finally(() => process.exit(0)); });
process.on('SIGINT',  () => { shutdown('SIGINT').finally(() => process.exit(0)); });

process.on('uncaughtException', (err) => {
  console.error('[App] uncaughtException — restarting process for a clean state:', err.message, err.stack);
  shutdown('uncaughtException').finally(() => process.exit(1));
});
process.on('unhandledRejection', (reason) => {
  console.error('[App] unhandledRejection — restarting process for a clean state:', reason?.message ?? reason);
  shutdown('unhandledRejection').finally(() => process.exit(1));
});

export default app;
