// Opens --conns keep-alive HTTP/1.1 connections, sends one request on each,
// reads its response, then holds them all idle for --seconds; meanwhile a
// trickle of --rate requests a second on one more connection keeps the
// server's STATS "served" count moving (runner.js windows on it).
//
// node idle-http.js --port P [--conns 1000] [--seconds 10] [--warmup 2] [--rate 10]
'use strict';
const net = require('net');

const a = { port: 0, conns: 1000, seconds: 10, warmup: 2, rate: 10, path: '/api' };
const v = process.argv.slice(2);
for (let i = 0; i < v.length; i++) {
  const k = v[i].replace(/^--/, '');
  const val = v[++i];
  a[k] = isNaN(+val) ? val : +val;
}

const request = Buffer.from('GET ' + a.path + ' HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n');
const sockets = [];
let answered = 0, closed = 0;

function open(i) {
  const s = net.connect(a.port, '127.0.0.1', () => s.write(request));
  let got = false;
  s.on('data', () => { if (!got) { got = true; answered++; } });
  s.on('error', () => {});
  s.on('close', () => { closed++; });
  sockets.push(s);
}

// Opened in batches, as a burst of 10k connects overflows a backlog.
let next = 0;
function batch() {
  for (let k = 0; k < 200 && next < a.conns; k++) open(next++);
  if (next < a.conns) setTimeout(batch, 20);
}
batch();

// The trickle.
const ticker = net.connect(a.port, '127.0.0.1');
ticker.on('error', () => {});
ticker.on('data', () => {});
const tick = setInterval(() => ticker.write(request), 1000 / a.rate);

setTimeout(() => {
  clearInterval(tick);
  console.log(JSON.stringify({ conns: a.conns, answered, closed, rps: 0 }));
  process.exit(0);
}, (a.warmup + a.seconds) * 1000);
