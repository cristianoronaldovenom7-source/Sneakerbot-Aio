import os from 'node:os';

const cores = Math.max(1, os.availableParallelism?.() || os.cpus().length || 1);
const requested = Number.parseInt(process.env.UV_THREADPOOL_SIZE || '0', 10);
if (!Number.isFinite(requested) || requested < 1) {
  process.env.UV_THREADPOOL_SIZE = String(Math.min(16, Math.max(8, cores + 2)));
}

// Publish the host memory ceiling for the fingerprint generator, which uses it to
// pick how large a monitor to draw. On a small box a 1366-wide viewport is real
// RAM saved; on a big one the generator ignores the hint and stays normal.
//
// Set here, before app.js, because fingerprints are generated lazily on first
// launch and reading the value later would race the first task.
if (!process.env.HOST_MEMORY_BYTES) {
  const total = os.totalmem?.() || 0;
  if (total > 0) process.env.HOST_MEMORY_BYTES = String(total);
}

// Verify the runtimes a checkout depends on BEFORE the app boots, and fetch any
// that are missing. Deliberately advisory: a failed download logs a warning and
// boot continues, because a missing Go sidecar already degrades to Node TLS and
// refusing to start would be a worse trade than running degraded.
//
// Node itself is the one gap bootstrap cannot repair mid-process (we are already
// running), so its result is reported but a node upgrade still needs a restart.
//
// BOOTSTRAP_DISABLE=1 skips the whole pass for fast/offline starts.
if (process.env.BOOTSTRAP_DISABLE !== '1') {
  try {
    const { bootstrapRuntimes, formatReport } = await import('./helpers/bootstrap-env.js');
    const report = await bootstrapRuntimes({ chromium: true });
    const text = formatReport(report);
    if (text) console.warn(text);
    const installed = report.results.filter((r) => r.status === 'installed').map((r) => r.name);
    if (installed.length) console.log(`[bootstrap] installed: ${installed.join(', ')}`);
  } catch (err) {
    // bootstrap-env.js is written not to throw; this catches the import itself
    // (e.g. a truncated file) so a broken bootstrap can never stop boot.
    console.warn(`[bootstrap] skipped: ${err.message}`);
  }
}

await import('./app.js');
