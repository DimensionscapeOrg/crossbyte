// One measurement of PerfHttpServer under load, pinned to CPUs 24-31.
//
// node runner.js --label L --exe <PerfHttpServer.exe> --scenario route|mw|static
//   [--load http|h2] [--seconds 8] [--warmup 3] [--env K=V,K=V]
//   [--results file.jsonl] -- [load generator args...]
//
// The server runs on CPUs 24-27 and the load on 28-31 (other agents measure
// on the rest of the machine). The server binds port 0 and says which port
// it got; it exits by itself after warm-up + seconds + 4.
//
// Reads the server's STATS lines over the seconds the load measured (the
// lines whose served count moved, less the first two and the last) and prints
// one JSON line: server CPU per request, user and kernel apart, cores busy,
// GC heap, and the load generator's rate and latency.
'use strict';
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const SERVER_MASK = '0F000000';
const LOAD_MASK = 'F0000000';

function args() {
  const a = { label: 'run', exe: '', scenario: 'route', load: 'http', seconds: 8, warmup: 3, env: '', results: '', rest: [] };
  const v = process.argv.slice(2);
  for (let i = 0; i < v.length; i++) {
    if (v[i] === '--') { a.rest = v.slice(i + 1); break; }
    const k = v[i].replace(/^--/, '');
    a[k] = v[++i];
  }
  a.seconds = +a.seconds; a.warmup = +a.warmup;
  return a;
}

// cmd's start pins a process at creation; its children inherit the mask.
// `window` starts it in a console window of its own instead of this one,
// minimized, so it neither covers the desktop nor takes the focus. (A
// minimized console may draw less than a visible one: a console's cost
// measured so can read lower than on a window someone is watching.)
function pinned(mask, exe, argv, opts, window) {
  const quoted = [exe].concat(argv).map((s) => '"' + s + '"').join(' ');
  return spawn('cmd.exe', ['/d', '/s', '/c', '"start "" ' + (window ? '/min ' : '/b ') + '/wait /affinity ' + mask + ' ' + quoted + '"'],
    Object.assign({ windowsVerbatimArguments: true }, opts));
}

const a = args();
const env = Object.assign({}, process.env, { PERF_SECONDS: String(a.warmup + a.seconds + 4) });
for (const kv of a.env.split(',').filter(Boolean)) {
  const at = kv.indexOf('=');
  // A value holding a list writes it with ';' (the pairs are split on ',').
  env[kv.slice(0, at)] = kv.slice(at + 1).replace(/;/g, ',');
}

const exe = path.resolve(a.exe);
// --stdout pipe (the default): READY and STATS come down a pipe. file: the
// server's stdout is a file (export/perf-http/stdout-<label>.txt) and
// console: a console window of its own, for the access log's cost to each;
// READY and STATS then go to a file of their own (PERF_STATS_FILE).
const mode = a.stdout || 'pipe';
let statsPath = null, stdoutFd = null;
if (mode !== 'pipe') {
  const dir = path.resolve(__dirname, '../../../export/perf-http');
  statsPath = path.join(dir, 'stats-' + a.label + '.txt');
  try { fs.unlinkSync(statsPath); } catch (_) {}
  env.PERF_STATS_FILE = statsPath;
  if (mode === 'file') stdoutFd = fs.openSync(path.join(dir, 'stdout-' + a.label + '.txt'), 'w');
}
// A .js server (the Node build) runs through this node.
const quiet = mode === 'file' ? stdoutFd : 'ignore';
const opts = { cwd: path.dirname(exe), env, stdio: mode === 'pipe' ? ['ignore', 'pipe', 'pipe'] : ['ignore', quiet, quiet] };
const windowed = mode === 'console';
const server = exe.endsWith('.js') ? pinned(SERVER_MASK, process.execPath, [exe, a.scenario], opts, windowed)
  : exe.endsWith('.jar') ? pinned(SERVER_MASK, 'java', ['-jar', exe, a.scenario], opts, windowed)
  : pinned(SERVER_MASK, exe, [a.scenario], opts, windowed);
let out = '', ready = false, loadOut = '';
if (mode === 'pipe') {
  server.stderr.on('data', (d) => { out += d; });
  server.stdout.on('data', onOutput);
} else {
  const poll = setInterval(() => {
    try { out = fs.readFileSync(statsPath, 'utf8'); } catch (_) { return; }
    onOutput('');
    if (ready) clearInterval(poll);
  }, 100);
}
function onOutput(d) {
  out += d;
  if (ready) return;
  const m = /READY ([1-9]\d*)/.exec(out);
  if (!m) return;
  ready = true;
  const script = path.join(__dirname, 'load', a.load + '.js');
  const load = pinned(LOAD_MASK, process.execPath, [script, '--port', m[1], '--seconds', String(a.seconds), '--warmup', String(a.warmup)].concat(a.rest),
    { stdio: ['ignore', 'pipe', 'inherit'] });
  load.stdout.on('data', (d) => { loadOut += d; });
}

const giveUp = setTimeout(() => { if (!ready) { console.log(JSON.stringify({ label: a.label, error: 'server never ready', out })); process.exit(1); } }, 15000);

server.on('exit', () => {
  clearTimeout(giveUp);
  if (statsPath) {
    try { out = fs.readFileSync(statsPath, 'utf8'); } catch (_) {}
    if (stdoutFd !== null) fs.closeSync(stdoutFd);
  }
  const stats = [];
  for (const line of out.split(/\r?\n/)) {
    if (!line.startsWith('STATS ')) continue;
    const o = {};
    for (const kv of line.slice(6).split(' ')) { const [k, v] = kv.split('='); o[k] = +v; }
    stats.push(o);
  }
  let load = {};
  try { load = JSON.parse(loadOut.trim().split(/\r?\n/).pop()); } catch (_) {}
  const moved = [];
  for (let i = 1; i < stats.length; i++) if (stats[i].served > stats[i - 1].served) moved.push(i);
  const use = moved.length >= 4 ? moved.slice(2, moved.length - 1) : moved;
  const row = { label: a.label, scenario: a.scenario, load: a.load, args: a.rest.join(' '), env: a.env };
  if (use.length >= 2) {
    const s = stats[use[0] - 1], e = stats[use[use.length - 1]];
    const dt = e.t - s.t, served = e.served - s.served;
    row.serverRps = Math.round(served / dt);
    row.cores = +((e.cpu - s.cpu) / dt).toFixed(2);
    row.cpuUs = +((e.cpu - s.cpu) / served * 1e6).toFixed(2);
    row.userUs = +((e.user - s.user) / served * 1e6).toFixed(2);
    row.kernelUs = +((e.kernel - s.kernel) / served * 1e6).toFixed(2);
    row.heapMB = +(Math.max(...use.map((i) => stats[i].mem)) / 1e6).toFixed(1);
  } else {
    row.error = 'too few STATS lines';
    row.out = out.slice(-2000);
  }
  // The access log's lines queued and dropped over the window (servers that
  // report them).
  if (use.length >= 2 && stats[use[0] - 1].logged !== undefined) {
    const s = stats[use[0] - 1], e = stats[use[use.length - 1]];
    const logged = e.logged - s.logged, dropped = e.dropped - s.dropped;
    if (logged + dropped > 0) row.accessDropped = +(dropped / (logged + dropped)).toFixed(3);
  }
  for (const k of ['rps', 'p50', 'p99', 'errors', 'reconnects', 'statuses']) if (load[k] !== undefined) row[k] = load[k];
  const line = JSON.stringify(row);
  console.log(line);
  if (a.results) fs.appendFileSync(a.results, line + '\n');
  const prof = /PROFILED (\S+)/.exec(out);
  if (prof) console.log('profile: ' + prof[1]);
});
