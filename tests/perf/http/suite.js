// Runs a list of runner.js cases, repetitions interleaved (A B C A B C ...),
// and prints a summary: median server CPU per request, user and kernel, and
// the spread (min-max) over the repetitions.
//
// node tests/perf/http/suite.js <cases.json> [--reps 3] [--results out.jsonl]
//
// cases.json: [{ "label": "...", "exe": "...", "scenario": "route",
//   "load": "http", "env": "K=V,K=V", "seconds": 6, "warmup": 2,
//   "args": ["--conns", "32"] }, ...]
'use strict';
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const argv = process.argv.slice(2);
const casesFile = argv[0];
let reps = 3, results = '';
for (let i = 1; i < argv.length; i++) {
  if (argv[i] === '--reps') reps = +argv[++i];
  else if (argv[i] === '--results') results = argv[++i];
}
const cases = JSON.parse(fs.readFileSync(casesFile, 'utf8'));
const runner = path.join(__dirname, 'runner.js');
const rows = {};

for (let r = 0; r < reps; r++) {
  for (const c of cases) {
    const args = [runner, '--label', c.label, '--exe', c.exe, '--scenario', c.scenario || 'route', '--load', c.load || 'http',
      '--seconds', String(c.seconds || 6), '--warmup', String(c.warmup || 2)];
    if (c.env) args.push('--env', c.env);
    if (c.stdout) args.push('--stdout', c.stdout);
    if (results) args.push('--results', results);
    args.push('--');
    for (const a of c.args || []) args.push(a);
    const out = spawnSync(process.execPath, args, { encoding: 'utf8' });
    const line = (out.stdout || '').trim().split(/\r?\n/).find((l) => l.startsWith('{'));
    let row = {};
    try { row = JSON.parse(line); } catch (_) { row = { error: 'no result', stdout: out.stdout, stderr: out.stderr }; }
    (rows[c.label] = rows[c.label] || []).push(row);
    console.log(JSON.stringify(row));
  }
}

const med = (xs) => { const s = xs.slice().sort((a, b) => a - b); return s[Math.floor(s.length / 2)]; };
console.log('\nlabel                          cpuUs (min-max)        userUs (min-max)       kernelUs   rps');
for (const c of cases) {
  const rs = (rows[c.label] || []).filter((x) => x.cpuUs != null);
  if (rs.length === 0) { console.log(c.label + '  no results'); continue; }
  const cpu = rs.map((x) => x.cpuUs), user = rs.map((x) => x.userUs), kern = rs.map((x) => x.kernelUs), rps = rs.map((x) => x.serverRps);
  console.log(c.label.padEnd(30) + ' ' + (med(cpu).toFixed(2) + ' (' + Math.min(...cpu).toFixed(2) + '-' + Math.max(...cpu).toFixed(2) + ')').padEnd(22)
    + ' ' + (med(user).toFixed(2) + ' (' + Math.min(...user).toFixed(2) + '-' + Math.max(...user).toFixed(2) + ')').padEnd(22)
    + ' ' + med(kern).toFixed(2).padEnd(10) + ' ' + med(rps));
}
