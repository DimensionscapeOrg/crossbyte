// Closed-loop keep-alive HTTP/1.1 load over raw sockets.
//
// node http.js --port P [--conns 64] [--procs 4] [--seconds 10] [--warmup 2]
//   [--path /api] [--accept identity|gzip|br] [--post BYTES] [--close]
//   [--headers browser]
//
// Each connection sends a request and the next only once the response is
// whole, so the rate measured is what the server sustains at that many
// connections in flight. A response saying "Connection: close" (or a close
// the server makes unannounced) is followed by a new connection at once.
// --close asks for a new connection per request.
// Prints one JSON line: requests, rps, statuses, latency percentiles (ms).
'use strict';
const net = require('net');
const tls = require('tls');
const { fork } = require('child_process');

function args() {
  const a = { port: 0, conns: 64, procs: 4, seconds: 10, warmup: 2, path: '/api', accept: 'identity', post: 0, close: false, tls: false, resume: false, worker: false };
  const v = process.argv.slice(2);
  for (let i = 0; i < v.length; i++) {
    const k = v[i].replace(/^--/, '');
    if (k === 'close' || k === 'worker' || k === 'tls' || k === 'resume') { a[k] = true; continue; }
    const val = v[++i];
    a[k] = isNaN(+val) ? val : +val;
  }
  return a;
}

// Log-scale latency histogram, 1 us to ~100 s, 1% wide buckets.
const BASE = 1.01, NB = 1900;
function bucket(us) { return us <= 1 ? 0 : Math.min(NB - 1, Math.floor(Math.log(us) / Math.log(BASE))); }
function bucketUs(b) { return Math.pow(BASE, b + 0.5); }
function percentile(h, total, p) {
  const want = total * p; let seen = 0;
  for (let b = 0; b < NB; b++) { seen += h[b]; if (seen >= want) return bucketUs(b) / 1000; }
  return NaN;
}

const CRLF2 = Buffer.from([13, 10, 13, 10]);
const LAST_CHUNK = Buffer.from([13, 10, 48, 13, 10, 13, 10]); // CRLF "0" CRLF CRLF
const CLOSE_HEADER = new RegExp('\\nconnection:\\s*close');

function worker(a, conns) {
  const hist = new Float64Array(NB);
  const statuses = {};
  let measuring = false, running = true, done = 0, errors = 0, bytesIn = 0, reconnects = 0, resumed = 0, full = 0;
  let lastSession;
  const body = a.post ? Buffer.alloc(a.post, 120) : null;
  // --headers browser: the fourteen fields a browser's fetch() carries, about
  // 700 bytes, so the parser and the header map see what a real API sees.
  const browser = a.headers === 'browser' ? require('./browser-headers.js').h1 : '';
  const head = (a.post ? 'POST' : 'GET') + ' ' + a.path + ' HTTP/1.1\r\nHost: 127.0.0.1\r\n' + browser
    + (a.accept !== 'identity' ? 'Accept-Encoding: ' + a.accept + '\r\n' : '')
    + (a.post ? 'Content-Type: application/octet-stream\r\nContent-Length: ' + a.post + '\r\n' : '')
    + (a.close ? 'Connection: close\r\n' : '') + '\r\n';
  const request = body ? Buffer.concat([Buffer.from(head), body]) : Buffer.from(head);

  function start() {
    // TLS without session resumption, so --close prices a full handshake.
    // TLS without session resumption, so --close prices a full handshake,
    // unless --resume: then each connection offers the session its last one
    // was given, as a returning browser does.
    const s = a.tls
      ? tls.connect({ port: a.port, host: '127.0.0.1', rejectUnauthorized: false, maxVersion: 'TLSv1.2', session: a.resume ? lastSession : undefined })
      : net.connect(a.port, '127.0.0.1');
    if (a.tls && a.resume) s.on('session', (sess) => { lastSession = sess; });
    if (a.tls) s.on('secureConnect', () => { if (measuring) { if (s.isSessionReused()) resumed++; else full++; } });
    s.setNoDelay(true);
    let buf = Buffer.alloc(0), sentAt = 0n, need = -1, headerEnd = -1, chunked = false, closing = false, status = 0, ended = false;
    const send = () => { sentAt = process.hrtime.bigint(); s.write(request); };
    s.on(a.tls ? 'secureConnect' : 'connect', send);
    s.on('data', (d) => {
      bytesIn += d.length;
      buf = buf.length ? Buffer.concat([buf, d]) : d;
      for (;;) {
        if (headerEnd < 0) {
          headerEnd = buf.indexOf(CRLF2);
          if (headerEnd < 0) return;
          const h = buf.toString('latin1', 0, headerEnd).toLowerCase();
          const m = /content-length:\s*(\d+)/.exec(h);
          chunked = /transfer-encoding:\s*chunked/.test(h);
          closing = CLOSE_HEADER.test(h);
          status = +h.substr(9, 3);
          need = m ? +m[1] : (chunked ? -2 : 0);
        }
        let end;
        if (chunked) {
          const z = buf.indexOf(LAST_CHUNK, headerEnd);
          if (z < 0) return;
          end = z + LAST_CHUNK.length;
        } else {
          end = headerEnd + 4 + need;
          if (buf.length < end) return;
        }
        const us = Number(process.hrtime.bigint() - sentAt) / 1000;
        if (measuring) { hist[bucket(us)]++; done++; statuses[status] = (statuses[status] || 0) + 1; }
        buf = buf.subarray(end); headerEnd = -1; need = -1;
        if (!running) { ended = true; s.destroy(); return; }
        if (a.close || closing) {
          ended = true; s.destroy();
          if (closing && !a.close && measuring) reconnects++;
          start();
          return;
        }
        send();
      }
    });
    s.on('error', () => { if (measuring) errors++; });
    // A close the server made without announcing it: a new connection at once.
    s.on('close', () => { if (!ended && running) { if (measuring) reconnects++; start(); } });
  }
  for (let i = 0; i < conns; i++) start();
  setTimeout(() => {
    measuring = true;
    const t0 = process.hrtime.bigint();
    setTimeout(() => {
      measuring = false; running = false;
      const secs = Number(process.hrtime.bigint() - t0) / 1e9;
      process.send({ hist: Array.from(hist), done, errors, secs, bytesIn, statuses, reconnects, resumed, full });
      setTimeout(() => process.exit(0), 200);
    }, a.seconds * 1000);
  }, a.warmup * 1000);
}

const a = args();
if (a.worker) {
  process.on('message', (m) => worker(a, m.conns));
} else {
  const procs = Math.max(1, Math.min(a.procs, a.conns));
  const results = [];
  for (let p = 0; p < procs; p++) {
    const share = Math.floor(a.conns / procs) + (p < a.conns % procs ? 1 : 0);
    const c = fork(__filename, process.argv.slice(2).concat(['--worker']));
    c.on('message', (r) => {
      results.push(r);
      if (results.length < procs) return;
      const hist = new Float64Array(NB); const statuses = {};
      let done = 0, errors = 0, secs = 0, bytesIn = 0, reconnects = 0, resumed = 0, full = 0;
      for (const x of results) {
        x.hist.forEach((v, i) => { hist[i] += v; });
        done += x.done; errors += x.errors; secs = Math.max(secs, x.secs); bytesIn += x.bytesIn; reconnects += x.reconnects; resumed += x.resumed; full += x.full;
        for (const k in x.statuses) statuses[k] = (statuses[k] || 0) + x.statuses[k];
      }
      console.log(JSON.stringify({
        conns: a.conns, path: a.path, accept: a.accept, post: a.post, close: a.close,
        requests: done, rps: Math.round(done / secs), errors, reconnects, statuses, handshakes: { resumed, full },
        p50: +percentile(hist, done, 0.5).toFixed(3), p90: +percentile(hist, done, 0.9).toFixed(3),
        p99: +percentile(hist, done, 0.99).toFixed(3), p999: +percentile(hist, done, 0.999).toFixed(3),
        mbIn: +(bytesIn / 1e6).toFixed(1), seconds: +secs.toFixed(2)
      }));
    });
    c.send({ conns: share });
  }
}
