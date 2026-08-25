// Puts a real RTCPeerConnection in front of CrossByte's WebRTC stack.
//
// This is the only test in the repository whose result depends on an
// implementation nobody here wrote. Every other test proves this code agrees
// with itself, which is worth a great deal and is not the same thing: an
// integrity scheme, a checksum byte order or a chunk layout can be perfectly
// self-consistent and understood by nothing else alive.
//
// A browser offers, the native peer answers, a data channel opens, and a
// message is echoed back. If that happens, the wire formats are right.
//
// Usage: node ci/interop/run.js
// Needs puppeteer and the peer built by `haxe ci/browser-interop.hxml`.

const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const readline = require('readline');

const PORT = 50574;
const ROOT = __dirname;
const PEER = path.join(__dirname, '..', '..', 'export', 'interop', 'BrowserInteropPeer.exe');
const TIMEOUT_MS = 60000;

let puppeteer;
try {
  puppeteer = require('puppeteer');
} catch (_) {
  console.error('puppeteer is not installed. Run: npm install --no-save puppeteer');
  process.exit(2);
}

const peerPath = fs.existsSync(PEER) ? PEER : PEER.replace(/\.exe$/, '');

if (!fs.existsSync(peerPath)) {
  console.error('No interop peer at ' + PEER + '. Build it: haxe ci/browser-interop.hxml');
  process.exit(2);
}

const server = http.createServer((request, response) => {
  const requested = request.url.split('?')[0];

  if (requested === '/favicon.ico') {
    response.writeHead(204);
    response.end();
    return;
  }

  fs.readFile(path.join(ROOT, requested === '/' ? 'index.html' : requested), (error, body) => {
    if (error) {
      response.writeHead(404);
      response.end('not found');
      return;
    }
    response.writeHead(200, { 'Content-Type': 'text/html' });
    response.end(body);
  });
});

function fail(message, detail) {
  console.error('INTEROP FAILED: ' + message);
  if (detail) console.error(detail);
  process.exitCode = 1;
}

(async () => {
  await new Promise(resolve => server.listen(PORT, '127.0.0.1', resolve));

  const peer = spawn(peerPath, [], { stdio: ['pipe', 'pipe', 'pipe'] });
  const events = [];
  const peerErrors = [];
  const waiters = new Map();

  // Every line the peer writes is one JSON event. Waiting on an event by name
  // keeps the sequencing here explicit rather than buried in timeouts.
  readline.createInterface({ input: peer.stdout }).on('line', line => {
    let event;
    try {
      event = JSON.parse(line);
    } catch (_) {
      peerErrors.push('unparseable line from peer: ' + line);
      return;
    }

    events.push(event);
    console.log('  peer: ' + JSON.stringify(event).slice(0, 120));

    const waiting = waiters.get(event.event);
    if (waiting) {
      waiters.delete(event.event);
      waiting(event);
    }
  });

  peer.stderr.on('data', chunk => peerErrors.push(String(chunk)));

  function waitForPeer(name, ms) {
    const existing = events.find(event => event.event === name);
    if (existing) return Promise.resolve(existing);

    return new Promise((resolve, reject) => {
      waiters.set(name, resolve);
      setTimeout(() => reject(new Error('the peer never reported "' + name + '"')), ms);
    });
  }

  const browser = await puppeteer.launch({
    args: [
      '--no-sandbox',
      '--disable-dev-shm-usage',
      // Without this Chrome replaces every host candidate with a random
      // .local mDNS name, which nothing here can resolve -- so the two peers
      // would exchange candidates neither could dial and the test would fail
      // for a reason that has nothing to do with the code under test. It is
      // a privacy measure aimed at pages fingerprinting a visitor's network,
      // and turning it off is appropriate here and nowhere else.
      '--disable-features=WebRtcHideLocalIpsWithMdns'
    ]
  });

  const page = await browser.newPage();
  const pageErrors = [];
  page.on('pageerror', error => pageErrors.push(String(error)));
  page.on('console', message => {
    if (message.type() === 'error') pageErrors.push('console.error: ' + message.text());
  });

  try {
    await page.goto('http://127.0.0.1:' + PORT + '/index.html', { waitUntil: 'domcontentloaded' });

    console.log('browser is creating an offer...');
    const offer = await page.evaluate('window.__createOffer()');

    if (!offer || offer.indexOf('m=application') < 0) {
      throw new Error('the browser produced no data channel offer');
    }

    console.log('offer gathered, handing it to the peer');
    peer.stdin.write(JSON.stringify({ sdp: offer }) + '\n');

    const answer = await waitForPeer('answer', 15000);

    if (!answer.sdp || answer.sdp.indexOf('a=fingerprint') < 0) {
      throw new Error('the peer produced no usable answer');
    }

    // Before involving the browser: can anything at all reach the peer's
    // socket? A firewall that silently drops inbound UDP to a freshly built
    // executable looks exactly like an ICE bug from the inside, and this
    // separates the two in one round trip.
    const dgram = require('dgram');
    const probes = [];

    for (const line of answer.sdp.split(/\r?\n/)) {
      const match = /^a=candidate:\S+ \d+ udp \d+ (\S+) (\d+) typ host/.exec(line);
      if (match && match[1].indexOf(':') < 0) probes.push({ address: match[1], port: Number(match[2]) });
    }

    const probe = dgram.createSocket('udp4');
    await new Promise(resolve => probe.bind(0, '0.0.0.0', resolve));

    for (const target of probes) {
      // First byte 0 so the peer routes it to the ICE agent and counts it as
      // STUN-shaped; the agent will reject it, which is fine -- the counter is
      // what is being read.
      probe.send(Buffer.from([0, 1, 0, 0]), target.port, target.address);
      console.log('  probing ' + target.address + ':' + target.port);
    }

    await new Promise(resolve => setTimeout(resolve, 1500));
    probe.close();

    console.log('answer received, handing it to the browser');
    await page.evaluate('window.__acceptAnswer(' + JSON.stringify(answer.sdp) + ')');

    console.log('waiting for the connection...');
    await page.waitForFunction('window.__interop.echoed !== null || window.__interop.failed !== null', {
      timeout: TIMEOUT_MS
    });

    const result = await page.evaluate('window.__interop');

    if (result.failed) {
      throw new Error('the browser reported: ' + result.failed);
    }

    if (result.echoed !== 'echo:from the browser') {
      throw new Error('expected the peer to echo the message, got: ' + JSON.stringify(result.echoed));
    }

    console.log('');
    console.log('INTEROP PASSED');
    console.log('  a real RTCPeerConnection and CrossByte opened a data channel');
    console.log('  and exchanged a message in each direction.');
  } catch (error) {
    fail(error.message, [
      'peer events: ' + JSON.stringify(events, null, 2),
      peerErrors.length ? 'peer stderr:\n' + peerErrors.join('') : '',
      pageErrors.length ? 'page errors:\n' + pageErrors.join('\n') : '',
      'browser log:\n' + (await page.evaluate('(window.__interop && window.__interop.log || []).join("\\n")').catch(() => ''))
    ].filter(Boolean).join('\n\n'));
  }

  await browser.close();
  peer.kill();
  server.close();

  if (pageErrors.length > 0) {
    console.error('the page reported errors:');
    for (const error of pageErrors) console.error('  ' + error);
    process.exitCode = 1;
  }
})();
