// The server PerfHttpClient fetches from: Node's http, keep-alive, a small
// JSON body. --pad N adds an X-Pad header of N bytes, to price what the
// client pays per byte of response head. Binds 127.0.0.1:0, prints
// "READY <port>", exits after --seconds.
'use strict';
const http = require('http');

const a = { pad: 0, seconds: 20 };
const v = process.argv.slice(2);
for (let i = 0; i < v.length; i++) a[v[i].replace(/^--/, '')] = +v[++i];

const body = Buffer.from('{"ok":true,"id":12345,"name":"crossbyte","tags":["fast","small"],"score":98.5}');
const pad = a.pad > 0 ? 'x'.repeat(a.pad) : null;
const server = http.createServer((req, res) => {
  const headers = { 'Content-Type': 'application/json', 'Content-Length': body.length };
  if (pad) headers['X-Pad'] = pad;
  res.writeHead(200, headers);
  res.end(body);
});
server.keepAliveTimeout = 30000;
server.listen(0, '127.0.0.1', () => {
  console.log('READY ' + server.address().port);
  setTimeout(() => process.exit(0), a.seconds * 1000);
});
