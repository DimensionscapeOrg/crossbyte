// Lists every Dynamic / Any / reflection / untyped / cast use in the http
// area, by file and kind, for the audit's "Dynamic and reflection
// inventory". Comment lines are skipped.
//
// node tests/perf/http/inventory.js [--lines]   (from the worktree root)
'use strict';
const fs = require('fs');
const path = require('path');

const roots = ['src/crossbyte/http', 'src/crossbyte/_internal/http', 'src/crossbyte/url', 'src/crossbyte/_internal/php'];
const kinds = [
  ['catchDynamic', /catch\s*\(\s*\w+\s*:\s*Dynamic\s*\)/],
  ['Dynamic', /\bDynamic\b/],
  ['Any', /\bAny\b/],
  ['Reflect', /\bReflect\./],
  ['untyped', /\buntyped\b/],
  ['Type.', /\bType\.\w+/],
  ['isOfType', /Std\.isOfType|Std\.is\(/],
  ['downcast', /Std\.downcast/],
  ['cast(x,T)', /\bcast\s*\([^)]*,/],
  ['anonTypedef', /^\s*(private\s+)?typedef\s+\w+\s*=\s*\{/],
];

function walk(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.name.endsWith('.hx')) out.push(p);
  }
  return out;
}

const showLines = process.argv.includes('--lines');
const totals = {};
for (const root of roots) {
  if (!fs.existsSync(root)) continue;
  for (const file of walk(root, [])) {
    const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
    const counts = {};
    const hits = [];
    let inBlock = false;
    lines.forEach((line, i) => {
      const t = line.trim();
      if (inBlock) { if (t.includes('*/')) inBlock = false; return; }
      if (t.startsWith('/*') || t.startsWith('/**')) { if (!t.includes('*/')) inBlock = true; return; }
      if (t.startsWith('//') || t.startsWith('*')) return;
      const code = line.replace(/\/\/.*$/, '').replace(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/g, '""');
      for (const [k, re] of kinds) {
        if (k === 'Dynamic' && kinds[0][1].test(code) && (code.match(/\bDynamic\b/g) || []).length === 1) continue;
        if (re.test(code)) { counts[k] = (counts[k] || 0) + 1; hits.push([i + 1, k, t]); }
      }
    });
    if (hits.length === 0) continue;
    console.log(file.replace(/\\/g, '/') + '  ' + JSON.stringify(counts));
    for (const k in counts) totals[k] = (totals[k] || 0) + counts[k];
    if (showLines) for (const [n, k, t] of hits) console.log('   ' + n + ' [' + k + '] ' + t.slice(0, 150));
  }
}
console.log('TOTAL ' + JSON.stringify(totals));
