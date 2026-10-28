import fs from 'node:fs';
import path from 'node:path';

// scan-encoding.mjs ignores .local by default: it holds extracted vendor trees
// (the Go standard library alone has thousands of non-English doc pages), which
// would bury the verdict that application source is clean.
const SKIP = /node_modules|^\.git$|package-lock|^\.local($|\\)/;
const EXT = /\.(md|js|mjs|cjs|json|sh|ya?ml|html|css|txt|ps1)$/;
const rows = [];

const walk = (dir) => {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (SKIP.test(e.name)) continue;
    const f = path.join(dir, e.name);
    if (e.isDirectory()) { walk(f); continue; }
    if (!EXT.test(e.name)) continue;
    const c = fs.readFileSync(f, 'utf8');
    const cjk = c.match(/[\u4e00-\u9fff]/g);
    const mojibake = c.match(/(?:â€|ðŸ|Ã©|Ã¨|Ã )/g);
    if (cjk || mojibake) {
      rows.push({ cjk: cjk ? cjk.length : 0, moji: mojibake ? mojibake.length : 0, file: path.relative('.', f) });
    }
  }
};

walk('.');
rows.sort((a, b) => (b.cjk + b.moji) - (a.cjk + a.moji));
for (const r of rows) console.log(`${r.cjk}\t${r.moji}\t${r.file}`);
console.log(`TOTAL=${rows.length}`);
