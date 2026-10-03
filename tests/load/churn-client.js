// Churn clients for scenario S (tests/load/ChurnServer.hx), on Node 18 or
// later: HTTP/1.1 with keep-alive, HTTP/2 and WebSocket, each in clear and over
// TLS, the TLS ones resuming the session the last connection was given -- as a
// browser does, and as CrossByte's own native client cannot.
//
//   node churn-client.js --http P --https P --ws P --wss P
//     [--plan 50:300,200:300,1000:300,0:120] [--procs 4] [--think 10]
//     [--tls-share 0.5] [--kinds h1,h2,ws] [--report 10] [--ips 16] [--ops 5:50]
//     [--resume 0]
//
// A session connects, does --ops (5 to 50) requests or messages with up to --think ms
// between them, leaves politely -- `Connection: close` on its last request, a
// GOAWAY, a close frame answered -- and is replaced. --plan is
// concurrency:seconds, phase after phase. Source addresses rotate over
// 127.0.0.1 .. 127.0.0.<ips>, each with its own ephemeral ports, so TIME_WAIT
// does not run a long churn out of them.
//
// Prints a `LOAD {json}` line every --report seconds, summed over the worker
// processes: counts, errors by reason, and latency histograms in the shape
// tests/load/LoadStats.hx decodes.
'use strict';
const net = require('net');
const tls = require('tls');
const http2 = require('http2');
const crypto = require('crypto');
const { fork } = require('child_process');

function parseArgs() {
  const a = {
    http: 0, https: 0, ws: 0, wss: 0, plan: '50:300,200:300,1000:300,0:120', procs: 4, think: 10,
    'tls-share': 0.5, kinds: 'h1,h2,ws', report: 10, ips: 16, worker: -1, timeout: 15000, ops: '5:50', resume: 1
  };
  const v = process.argv.slice(2);
  for (let i = 0; i < v.length; i++) {
    const k = v[i].replace(/^--/, '');
    const val = v[++i];
    a[k] = val !== undefined && val !== '' && !isNaN(+val) ? +val : val;
  }
  a.phases = String(a.plan).split(',').map((p) => { const [c, s] = p.split(':'); return { concurrency: +c, seconds: +s }; });
  a.kindList = String(a.kinds).split(',');
  [a.opsMin, a.opsMax] = String(a.ops).split(':').map(Number);
  if (!(a.opsMax >= a.opsMin)) a.opsMax = a.opsMin;
  return a;
}
const a = parseArgs();

// The same log-scale buckets as LoadStats.Histogram: 2% wide, in microseconds.
const BASE = 1.02, BUCKETS = 1024, LOG_BASE = Math.log(BASE);
class Histogram {
  constructor() { this.counts = new Map(); this.max = 0; }
  add(ms) {
    const us = ms * 1000;
    let b = us <= 1 ? 0 : Math.floor(Math.log(us) / LOG_BASE);
    if (b >= BUCKETS) b = BUCKETS - 1;
    this.counts.set(b, (this.counts.get(b) || 0) + 1);
    if (ms > this.max) this.max = ms;
  }
  mergeEncoded(text) {
    const bar = text.indexOf('|');
    const max = +text.slice(0, bar);
    if (max > this.max) this.max = max;
    const rest = text.slice(bar + 1);
    if (!rest) return;
    for (const pair of rest.split(',')) {
      const [b, n] = pair.split(':');
      this.counts.set(+b, (this.counts.get(+b) || 0) + +n);
    }
  }
  encode() {
    const keys = [...this.counts.keys()].sort((x, y) => x - y);
    return (Math.round(this.max * 1000) / 1000) + '|' + keys.map((k) => k + ':' + this.counts.get(k)).join(',');
  }
}

if (a.worker < 0) {
  parent();
} else {
  worker(a.worker);
}

// ---------------------------------------------------------------------------
// The parent: starts the workers and sums what they report into one line.

function parent() {
  const procs = Math.max(1, a.procs);
  let counts = {}, errors = {}, latency = {}, concurrency = new Map(), cpu = 0;
  const kids = [];
  let finished = 0;
  for (let p = 0; p < procs; p++) {
    const child = fork(__filename, process.argv.slice(2).concat(['--worker', String(p)]));
    child.on('message', (m) => {
      for (const k in m.counts) counts[k] = (counts[k] || 0) + m.counts[k];
      for (const k in m.errors) errors[k] = (errors[k] || 0) + m.errors[k];
      for (const k in m.latency) {
        if (!latency[k]) latency[k] = new Histogram();
        latency[k].mergeEncoded(m.latency[k]);
      }
      concurrency.set(p, m.open);
      cpu += m.cpu;
    });
    child.on('exit', () => {
      finished++;
      if (finished === procs) {
        emit();
        process.exit(0);
      }
    });
    kids.push(child);
  }
  function emit() {
    const lat = {};
    for (const k in latency) lat[k] = latency[k].encode();
    let open = 0;
    for (const n of concurrency.values()) open += n;
    process.stdout.write('LOAD ' + JSON.stringify({ kind: 'churn-clients', concurrency: open, cpu, counts, errors, latency: lat }) + '\n');
    counts = {}; errors = {}; latency = {}; cpu = 0;
  }
  setInterval(emit, a.report * 1000);
}

// ---------------------------------------------------------------------------
// A worker: its share of every phase's sessions.

function worker(index) {
  const procs = Math.max(1, a.procs);
  let counts = {}, errors = {}, latency = {};
  let open = 0, target = 0, sessionIndex = index;
  const tlsSessions = {};
  let lastCpu = process.cpuUsage();

  const count = (name, n = 1) => { counts[name] = (counts[name] || 0) + n; };
  const fail = (kind, reason) => {
    const key = kind + ':' + String(reason).slice(0, 60);
    errors[key] = (errors[key] || 0) + 1;
    if (Object.keys(errors).length < 5 && errors[key] === 1) process.stderr.write('churn ' + key + '\n');
  };
  const time = (name, ms) => { if (!latency[name]) latency[name] = new Histogram(); latency[name].add(ms); };
  const now = () => Number(process.hrtime.bigint()) / 1e6;
  const localAddress = () => '127.0.0.' + (1 + (sessionIndex++ % a.ips));
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const think = () => (a.think > 0 ? sleep(Math.random() * a.think) : Promise.resolve());

  setInterval(() => {
    const used = process.cpuUsage(lastCpu);
    lastCpu = process.cpuUsage();
    const lat = {};
    for (const k in latency) lat[k] = latency[k].encode();
    process.send({ counts, errors, latency: lat, open, cpu: (used.user + used.system) / 1e6 });
    counts = {}; errors = {}; latency = {};
  }, 1000);

  // Sessions: start them while below the phase's share, and let each end on
  // its own; a lower phase is reached as sessions finish.
  function pump() {
    while (open < target) {
      open++;
      runSession().catch((e) => fail('session', e && e.message || e)).finally(() => { open--; setImmediate(pump); });
    }
  }

  (async () => {
    for (const phase of a.phases) {
      target = Math.floor(phase.concurrency / procs) + (index < phase.concurrency % procs ? 1 : 0);
      pump();
      await sleep(phase.seconds * 1000);
    }
    target = 0;
    const giveUp = Date.now() + 20000;
    while (open > 0 && Date.now() < giveUp) await sleep(100);
    await sleep(1100);
    process.exit(0);
  })();

  async function runSession() {
    const kind = a.kindList[Math.floor(Math.random() * a.kindList.length)];
    const secure = Math.random() < a['tls-share'];
    const ops = a.opsMin + Math.floor(Math.random() * (a.opsMax - a.opsMin + 1));
    const name = kind + (secure ? 's' : '');
    if (kind === 'h1') await h1Session(name, secure, ops);
    else if (kind === 'h2') await h2Session(name, secure, ops);
    else await wsSession(name, secure, ops);
  }

  // A TLS connection offering the session the last one of its kind was given.
  function connectTls(port, name, alpn) {
    const options = {
      port, host: '127.0.0.1', localAddress: localAddress(), rejectUnauthorized: false,
      session: a.resume ? tlsSessions[name] : undefined, servername: 'localhost'
    };
    if (alpn) options.ALPNProtocols = alpn;
    const socket = tls.connect(options);
    socket.on('session', (s) => { tlsSessions[name] = s; });
    return socket;
  }

  function settle(socket, secure, name, started) {
    return new Promise((resolve, reject) => {
      const ready = secure ? 'secureConnect' : 'connect';
      const onError = (e) => reject(e);
      socket.once('error', onError);
      socket.once(ready, () => {
        socket.removeListener('error', onError);
        time(name + '.setup', now() - started);
        if (secure) count(socket.isSessionReused() ? 'tls.resumed' : 'tls.full');
        resolve();
      });
    });
  }

  // HTTP/1.1, one connection, requests one after another.
  async function h1Session(name, secure, ops) {
    const started = now();
    const port = secure ? a.https : a.http;
    const socket = secure ? connectTls(port, name, ['http/1.1']) : net.connect({ port, host: '127.0.0.1', localAddress: localAddress() });
    socket.setNoDelay(true);
    let buffer = Buffer.alloc(0), waiting = null, closed = false;
    socket.on('data', (d) => { buffer = buffer.length ? Buffer.concat([buffer, d]) : d; if (waiting) waiting(); });
    socket.on('close', () => { closed = true; if (waiting) waiting(); });
    socket.on('error', () => {});
    try {
      await settle(socket, secure, name, started);
    } catch (e) {
      fail(name, 'connect ' + (e.code || e.message));
      socket.destroy();
      return;
    }
    count(name + '.sessions');
    for (let i = 0; i < ops; i++) {
      const last = i === ops - 1;
      const sent = now();
      const post = i % 3 === 1;
      const body = post ? crypto.randomBytes(256 + Math.floor(Math.random() * 1024)) : null;
      const path = post ? '/echo' : (i % 7 === 3 ? '/page' : '/item/' + Math.floor(Math.random() * 100000));
      socket.write((post ? 'POST ' : 'GET ') + path + ' HTTP/1.1\r\nHost: localhost\r\n'
        + (post ? 'Content-Type: application/octet-stream\r\nContent-Length: ' + body.length + '\r\n' : '')
        + (last ? 'Connection: close\r\n' : '') + '\r\n');
      if (post) socket.write(body);
      const response = await readResponse();
      if (response.error) {
        fail(name, response.error);
        socket.destroy();
        return;
      }
      if (response.status !== 200 || (post && response.length !== body.length)) {
        fail(name, 'status ' + response.status);
        socket.destroy();
        return;
      }
      time(name, now() - sent);
      count(name + '.ops');
      if (!last) await think();
    }
    // The server closes after a `Connection: close` response: wait for it, so
    // the TIME_WAIT is its, as with a browser's last request.
    const deadline = setTimeout(() => { if (!closed) { fail(name, 'server did not close'); socket.destroy(); } }, a.timeout);
    while (!closed) await new Promise((r) => { waiting = r; });
    clearTimeout(deadline);
    socket.destroy();

    function readResponse() {
      return new Promise((resolve) => {
        const timer = setTimeout(() => { waiting = null; resolve({ error: 'timeout' }); }, a.timeout);
        const check = () => {
          const end = buffer.indexOf('\r\n\r\n');
          if (end >= 0) {
            const head = buffer.slice(0, end).toString('latin1');
            const status = +head.split(' ')[1];
            const m = /content-length:\s*(\d+)/i.exec(head);
            if (!m) { clearTimeout(timer); waiting = null; resolve({ error: 'no content-length' }); return; }
            const length = +m[1];
            if (buffer.length >= end + 4 + length) {
              buffer = buffer.slice(end + 4 + length);
              clearTimeout(timer);
              waiting = null;
              resolve({ status, length });
              return;
            }
          }
          if (closed) { clearTimeout(timer); waiting = null; resolve({ error: 'closed mid-response' }); }
        };
        waiting = check;
        check();
      });
    }
  }

  // HTTP/2: prior knowledge in clear, ALPN over TLS; requests one after another
  // on one connection, then a GOAWAY.
  async function h2Session(name, secure, ops) {
    const started = now();
    const port = secure ? a.https : a.http;
    let socket;
    if (secure) {
      socket = connectTls(port, name, ['h2']);
    } else {
      socket = net.connect({ port, host: '127.0.0.1', localAddress: localAddress() });
    }
    try {
      await settle(socket, secure, name, started);
    } catch (e) {
      fail(name, 'connect ' + (e.code || e.message));
      socket.destroy();
      return;
    }
    if (secure && socket.alpnProtocol !== 'h2') {
      fail(name, 'alpn ' + socket.alpnProtocol);
      socket.destroy();
      return;
    }
    const client = http2.connect((secure ? 'https' : 'http') + '://localhost:' + port, { createConnection: () => socket });
    let failed = null;
    client.on('error', (e) => { failed = failed || (e.code || e.message); });
    count(name + '.sessions');
    for (let i = 0; i < ops && !failed; i++) {
      const sent = now();
      const post = i % 3 === 1;
      const body = post ? crypto.randomBytes(256 + Math.floor(Math.random() * 1024)) : null;
      const path = post ? '/echo' : (i % 7 === 3 ? '/page' : '/item/' + Math.floor(Math.random() * 100000));
      const result = await new Promise((resolve) => {
        let status = 0, length = 0, req;
        const timer = setTimeout(() => { resolve({ error: 'timeout' }); try { req.close(); } catch (_) {} }, a.timeout);
        try {
          req = client.request(post ? { ':method': 'POST', ':path': path, 'content-type': 'application/octet-stream' } : { ':path': path });
        } catch (e) {
          clearTimeout(timer);
          resolve({ error: e.code || e.message });
          return;
        }
        req.on('response', (h) => { status = h[':status']; });
        req.on('data', (d) => { length += d.length; });
        req.on('end', () => { clearTimeout(timer); resolve({ status, length }); });
        req.on('error', (e) => { clearTimeout(timer); resolve({ error: e.code || e.message }); });
        if (post) req.end(body); else req.end();
      });
      if (result.error || failed) {
        fail(name, result.error || failed);
        client.destroy();
        return;
      }
      if (result.status !== 200 || (post && result.length !== body.length)) {
        fail(name, 'status ' + result.status);
        client.destroy();
        return;
      }
      time(name, now() - sent);
      count(name + '.ops');
      if (i < ops - 1) await think();
    }
    await new Promise((resolve) => {
      const timer = setTimeout(() => { fail(name, 'close timeout'); client.destroy(); resolve(); }, a.timeout);
      client.close(() => { clearTimeout(timer); resolve(); });
    });
    if (failed && failed !== 'ERR_HTTP2_GOAWAY_SESSION') fail(name, failed);
  }

  // WebSocket: the upgrade, binary messages echoed one after another, and a
  // close frame the server answers before closing the connection itself.
  async function wsSession(name, secure, ops) {
    const started = now();
    const port = secure ? a.wss : a.ws;
    const socket = secure ? connectTls(port, name, null) : net.connect({ port, host: '127.0.0.1', localAddress: localAddress() });
    socket.setNoDelay(true);
    let buffer = Buffer.alloc(0), waiting = null, closed = false;
    socket.on('data', (d) => { buffer = buffer.length ? Buffer.concat([buffer, d]) : d; if (waiting) waiting(); });
    socket.on('close', () => { closed = true; if (waiting) waiting(); });
    socket.on('error', () => {});
    try {
      await settle(socket, secure, name, started);
    } catch (e) {
      fail(name, 'connect ' + (e.code || e.message));
      socket.destroy();
      return;
    }
    const key = crypto.randomBytes(16).toString('base64');
    socket.write('GET /chat HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ' + key + '\r\nSec-WebSocket-Version: 13\r\n\r\n');
    const upgraded = await until(() => {
      const end = buffer.indexOf('\r\n\r\n');
      if (end < 0) return null;
      const head = buffer.slice(0, end).toString('latin1');
      buffer = buffer.slice(end + 4);
      return head.startsWith('HTTP/1.1 101') ? 'ok' : 'refused ' + head.split('\r\n')[0];
    });
    if (upgraded !== 'ok') {
      fail(name, upgraded || 'no upgrade');
      socket.destroy();
      return;
    }
    time(name + '.upgrade', now() - started);
    count(name + '.sessions');
    for (let i = 0; i < ops; i++) {
      const payload = crypto.randomBytes(32 + Math.floor(Math.random() * 480));
      const sent = now();
      socket.write(frame(0x2, payload));
      const echoed = await until(() => readFrame());
      if (!echoed || echoed.error) {
        fail(name, echoed ? echoed.error : (closed ? 'closed' : 'timeout'));
        socket.destroy();
        return;
      }
      if (echoed.opcode !== 0x2 || echoed.payload.length !== payload.length) {
        fail(name, 'bad echo opcode ' + echoed.opcode);
        socket.destroy();
        return;
      }
      time(name, now() - sent);
      count(name + '.ops');
      if (i < ops - 1) await think();
    }
    socket.write(frame(0x8, Buffer.from([0x03, 0xe8])));
    const answer = await until(() => {
      const f = readFrame();
      return f && f.opcode === 0x8 ? f : (f ? null : null);
    });
    if (!answer) fail(name, closed ? 'closed without close frame' : 'no close answer');
    const deadline = setTimeout(() => { if (!closed) { fail(name, 'server did not close'); socket.destroy(); } }, a.timeout);
    while (!closed) await new Promise((r) => { waiting = r; });
    clearTimeout(deadline);
    socket.destroy();

    function until(test) {
      return new Promise((resolve) => {
        const timer = setTimeout(() => { waiting = null; resolve(null); }, a.timeout);
        const check = () => {
          const result = test();
          if (result) { clearTimeout(timer); waiting = null; resolve(result); return; }
          if (closed) { clearTimeout(timer); waiting = null; resolve(null); }
        };
        waiting = check;
        check();
      });
    }
    function readFrame() {
      if (buffer.length < 2) return null;
      const opcode = buffer[0] & 0x0f;
      let length = buffer[1] & 0x7f, offset = 2;
      if (buffer[1] & 0x80) return { error: 'masked frame from server' };
      if (length === 126) { if (buffer.length < 4) return null; length = buffer.readUInt16BE(2); offset = 4; }
      else if (length === 127) { if (buffer.length < 10) return null; length = Number(buffer.readBigUInt64BE(2)); offset = 10; }
      if (buffer.length < offset + length) return null;
      const payload = buffer.slice(offset, offset + length);
      buffer = buffer.slice(offset + length);
      if (opcode === 0x9) { socket.write(frame(0xA, payload)); return readFrame(); }
      if (opcode === 0xA) return readFrame();
      return { opcode, payload };
    }
  }

  function frame(opcode, payload) {
    const mask = crypto.randomBytes(4);
    const n = payload.length;
    const head = n < 126 ? 6 : 8;
    const out = Buffer.alloc(head + n);
    out[0] = 0x80 | opcode;
    if (n < 126) { out[1] = 0x80 | n; mask.copy(out, 2); }
    else { out[1] = 0x80 | 126; out.writeUInt16BE(n, 2); mask.copy(out, 4); }
    for (let i = 0; i < n; i++) out[head + i] = payload[i] ^ mask[i & 3];
    return out;
  }
}
