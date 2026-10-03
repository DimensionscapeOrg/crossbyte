// One measurement of PerfHttpClient (URLLoader) against load/peer.js, pinned
// like runner.js: the client on CPUs 24-27, the Node peer on 28-31.
//
// node client-runner.js --label L --exe <PerfHttpClient.exe> [--pad N]
//   [--loaders 1] [--seconds 8] [--warmup 2] [--results file.jsonl]
//
// Prints one JSON line: client CPU per completed load, user and kernel apart.
'use strict';
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const a = { label: 'client', exe: '', pad: 0, loaders: 1, seconds: 8, warmup: 2, results: '' };
const v = process.argv.slice(2);
for (let i = 0; i < v.length; i++) a[v[i].replace(/^--/, '')] = v[++i];
a.seconds = +a.seconds; a.warmup = +a.warmup;

function pinned(mask, exe, argv, opts) {
  const quoted = [exe].concat(argv).map((s) => '"' + s + '"').join(' ');
  return spawn('cmd.exe', ['/d', '/s', '/c', '"start "" /b /wait /affinity ' + mask + ' ' + quoted + '"'],
    Object.assign({ windowsVerbatimArguments: true }, opts));
}

const life = a.seconds + a.warmup + 4;
const peer = pinned('F0000000', process.execPath, [path.join(__dirname, 'load', 'peer.js'), '--pad', String(a.pad), '--seconds', String(life + 3)],
  { stdio: ['ignore', 'pipe', 'inherit'] });
let peerOut = '', started = false, out = '';
peer.stdout.on('data', (d) => {
  peerOut += d;
  if (started) return;
  const m = /READY (\d+)/.exec(peerOut);
  if (!m) return;
  started = true;
  const exe = path.resolve(a.exe);
  const env = Object.assign({}, process.env, { PERF_SECONDS: String(life), PERF_LOADERS: String(a.loaders) });
  const client = pinned('0F000000', exe, ['http://127.0.0.1:' + m[1] + '/api'], { cwd: path.dirname(exe), env, stdio: ['ignore', 'pipe', 'pipe'] });
  client.stdout.on('data', (x) => { out += x; });
  client.stderr.on('data', (x) => { out += x; });
  client.on('exit', report);
});

function report() {
  const stats = [];
  for (const line of out.split(/\r?\n/)) {
    if (!line.startsWith('STATS ')) continue;
    const o = {};
    for (const kv of line.slice(6).split(' ')) { const [k, val] = kv.split('='); o[k] = +val; }
    stats.push(o);
  }
  // Skip the warm-up seconds and the last line.
  const use = stats.filter((s) => s.t >= a.warmup).slice(0, -1);
  const row = { label: a.label, pad: +a.pad, loaders: +a.loaders };
  if (use.length >= 2) {
    const s = use[0], e = use[use.length - 1];
    const dt = e.t - s.t, n = e.served - s.served;
    row.rps = Math.round(n / dt);
    row.cores = +((e.cpu - s.cpu) / dt).toFixed(2);
    row.cpuUs = +((e.cpu - s.cpu) / n * 1e6).toFixed(1);
    row.userUs = +((e.user - s.user) / n * 1e6).toFixed(1);
    row.kernelUs = +((e.kernel - s.kernel) / n * 1e6).toFixed(1);
    row.failed = e.failed;
  } else {
    row.error = 'too few STATS lines';
    row.out = out.slice(-1500);
  }
  const line = JSON.stringify(row);
  console.log(line);
  if (a.results) fs.appendFileSync(a.results, line + '\n');
}
