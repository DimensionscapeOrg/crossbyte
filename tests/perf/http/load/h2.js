// Closed-loop HTTP/2 load: sessions, each with a number of streams in flight.
//
// node h2.js --port P [--sessions 8] [--streams 8] [--procs 4] [--seconds 10]
//   [--warmup 2] [--path /api] [--tls] [--headers browser]
//
// Cleartext is prior knowledge (h2c), as RFC 9113 3.3 has it; --tls offers h2
// by ALPN. Each stream's next request goes out once its response has ended,
// so --sessions x --streams requests are always in flight. Prints one JSON
// line in http.js's shape.
'use strict';
const http2 = require('http2');
const { fork } = require('child_process');
// --headers browser: the fields a browser's fetch() carries; see browser-headers.js.
const BROWSER = require('./browser-headers.js').h2;

function args() {
  const a = { port: 0, sessions: 8, streams: 8, procs: 4, seconds: 10, warmup: 2, path: '/api', tls: false, worker: false };
  const v = process.argv.slice(2);
  for (let i = 0; i < v.length; i++) {
    const k = v[i].replace(/^--/, '');
    if (k === 'worker' || k === 'tls') { a[k] = true; continue; }
    const val = v[++i];
    a[k] = isNaN(+val) ? val : +val;
  }
  return a;
}

const BASE = 1.01, NB = 1900;
function bucket(us) { return us <= 1 ? 0 : Math.min(NB - 1, Math.floor(Math.log(us) / Math.log(BASE))); }
function bucketUs(b) { return Math.pow(BASE, b + 0.5); }
function percentile(h, total, p) {
  const want = total * p; let seen = 0;
  for (let b = 0; b < NB; b++) { seen += h[b]; if (seen >= want) return bucketUs(b) / 1000; }
  return NaN;
}

function worker(a, sessions) {
  const hist = new Float64Array(NB);
  const statuses = {};
  let measuring = false, running = true, done = 0, errors = 0, bytesIn = 0, reconnects = 0;

  function session() {
    const url = (a.tls ? 'https' : 'http') + '://127.0.0.1:' + a.port;
    const c = http2.connect(url, a.tls ? { rejectUnauthorized: false } : {});
    let open = true;
    c.on('error', () => { if (measuring) errors++; });
    c.on('close', () => { open = false; if (running) { if (measuring) reconnects++; session(); } });
    function stream() {
      if (!running || !open) return;
      const sentAt = process.hrtime.bigint();
      let status = 0;
      let req;
      try {
        req = c.request(a.headers === 'browser' ? Object.assign({ ':path': a.path }, BROWSER) : { ':path': a.path });
      } catch (e) {
        if (measuring) errors++;
        return;
      }
      req.on('response', (h) => { status = h[':status']; });
      req.on('data', (d) => { bytesIn += d.length; });
      req.on('end', () => {
        const us = Number(process.hrtime.bigint() - sentAt) / 1000;
        if (measuring) { hist[bucket(us)]++; done++; statuses[status] = (statuses[status] || 0) + 1; }
        stream();
      });
      req.on('error', () => { if (measuring) errors++; });
      req.end();
    }
    c.on('connect', () => { for (let i = 0; i < a.streams; i++) stream(); });
  }
  for (let i = 0; i < sessions; i++) session();
  setTimeout(() => {
    measuring = true;
    const t0 = process.hrtime.bigint();
    setTimeout(() => {
      measuring = false; running = false;
      const secs = Number(process.hrtime.bigint() - t0) / 1e9;
      process.send({ hist: Array.from(hist), done, errors, secs, bytesIn, statuses, reconnects });
      setTimeout(() => process.exit(0), 200);
    }, a.seconds * 1000);
  }, a.warmup * 1000);
}

const a = args();
if (a.worker) {
  process.on('message', (m) => worker(a, m.sessions));
} else {
  const procs = Math.max(1, Math.min(a.procs, a.sessions));
  const results = [];
  for (let p = 0; p < procs; p++) {
    const share = Math.floor(a.sessions / procs) + (p < a.sessions % procs ? 1 : 0);
    const c = fork(__filename, process.argv.slice(2).concat(['--worker']));
    c.on('message', (r) => {
      results.push(r);
      if (results.length < procs) return;
      const hist = new Float64Array(NB); const statuses = {};
      let done = 0, errors = 0, secs = 0, bytesIn = 0, reconnects = 0;
      for (const x of results) {
        x.hist.forEach((v, i) => { hist[i] += v; });
        done += x.done; errors += x.errors; secs = Math.max(secs, x.secs); bytesIn += x.bytesIn; reconnects += x.reconnects;
        for (const k in x.statuses) statuses[k] = (statuses[k] || 0) + x.statuses[k];
      }
      console.log(JSON.stringify({
        sessions: a.sessions, streams: a.streams, path: a.path, tls: a.tls,
        requests: done, rps: Math.round(done / secs), errors, reconnects, statuses,
        p50: +percentile(hist, done, 0.5).toFixed(3), p90: +percentile(hist, done, 0.9).toFixed(3),
        p99: +percentile(hist, done, 0.99).toFixed(3), p999: +percentile(hist, done, 0.999).toFixed(3),
        mbIn: +(bytesIn / 1e6).toFixed(1), seconds: +secs.toFixed(2)
      }));
    });
    c.send({ sessions: share });
  }
}
