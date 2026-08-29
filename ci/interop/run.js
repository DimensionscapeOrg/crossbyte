// Puts a real RTCPeerConnection in front of CrossByte's WebRTC stack, in both
// directions.
//
// This is the only test in the repository whose result depends on an
// implementation nobody here wrote. Every other test proves this code agrees
// with itself, which is worth a great deal and is not the same thing: an
// integrity scheme, a checksum byte order or a chunk layout can be perfectly
// self-consistent and understood by nothing else alive.
//
// Both directions run because they exercise opposite role combinations.
// Answering a browser leaves CrossByte ICE-controlled and the DTLS client;
// offering to one inverts both, so the browser opens the SCTP association and
// takes the even data channel streams. A stack driving both roles from one bit
// passes the first and cannot complete the second -- which is exactly what it
// did until the roles were separated.
//
// Usage: node ci/interop/run.js
// Needs puppeteer and the peer built by `haxe ci/browser-interop.hxml`.

const http = require('http');
const fs = require('fs');
const path = require('path');
const dgram = require('dgram');
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

/** One CrossByte peer, and a promise-shaped way to wait on what it says. */
function startPeer(instruction) {
  const peer = spawn(peerPath, [], { stdio: ['pipe', 'pipe', 'pipe'] });
  const events = [];
  const errors = [];
  const waiters = new Map();

  readline.createInterface({ input: peer.stdout }).on('line', line => {
    let event;
    try {
      event = JSON.parse(line);
    } catch (_) {
      errors.push('unparseable line from peer: ' + line);
      return;
    }

    events.push(event);
    console.log('  peer: ' + JSON.stringify(event).slice(0, 140));

    const waiting = waiters.get(event.event);
    if (waiting) {
      waiters.delete(event.event);
      waiting(event);
    }
  });

  peer.stderr.on('data', chunk => {
    errors.push(String(chunk));
    // CROSSBYTE_DTLS_DEBUG makes the peer narrate its handshake on stderr.
    // Asking for it and then swallowing it would be a strange thing to do.
    if (process.env.CROSSBYTE_DTLS_DEBUG) process.stderr.write(String(chunk));
  });
  peer.stdin.write(JSON.stringify(instruction) + '\n');

  return {
    events,
    errors,
    send: value => peer.stdin.write(JSON.stringify(value) + '\n'),
    kill: () => peer.kill(),
    wait(name, ms) {
      const existing = events.find(event => event.event === name);
      if (existing) return Promise.resolve(existing);

      return new Promise((resolve, reject) => {
        waiters.set(name, resolve);
        setTimeout(() => reject(new Error('the peer never reported "' + name + '"')), ms);
      });
    }
  };
}

/**
 * Can anything at all reach the peer's socket?
 *
 * A firewall that silently drops inbound UDP to a freshly built executable
 * looks exactly like an ICE bug from the inside. This separates the two before
 * the browser is involved, and it earned its place: the first run of this test
 * failed with no inbound traffic at all, and knowing loopback was equally
 * silent is what moved the search off the network and onto the socket.
 */
async function probeReachable(sdp) {
  const targets = [];

  for (const line of sdp.split(/\r?\n/)) {
    const match = /^a=candidate:\S+ \d+ udp \d+ (\S+) (\d+) typ host/.exec(line);
    if (match && match[1].indexOf(':') < 0) targets.push({ address: match[1], port: Number(match[2]) });
  }

  const probe = dgram.createSocket('udp4');
  await new Promise(resolve => probe.bind(0, '0.0.0.0', resolve));

  for (const target of targets) {
    // First byte 0 so the peer routes it to the ICE agent, which rejects it.
    // Reaching the socket at all is the whole of what is being asked.
    probe.send(Buffer.from([0, 1, 0, 0]), target.port, target.address);
  }

  await new Promise(resolve => setTimeout(resolve, 500));
  probe.close();
}

async function browserOffers(page) {
  console.log('\n=== the browser offers, CrossByte answers ===');
  console.log('  CrossByte should end up ICE-controlled and the DTLS client');

  const offer = await page.evaluate('window.__createOffer()');

  if (!offer || offer.indexOf('m=application') < 0) {
    throw new Error('the browser produced no data channel offer');
  }

  const peer = startPeer({ mode: 'answer', sdp: offer });

  try {
    const answer = await peer.wait('answer', 15000);

    if (!answer.sdp || answer.sdp.indexOf('a=fingerprint') < 0) {
      throw new Error('the peer produced no usable answer');
    }

    if (answer.sdp.indexOf('a=setup:active') < 0) {
      throw new Error('an answer to actpass should claim the DTLS client role, and this one did not');
    }

    await probeReachable(answer.sdp);
    await page.evaluate('window.__acceptAnswer(' + JSON.stringify(answer.sdp) + ')');

    await page.waitForFunction('window.__interop.echoed !== null || window.__interop.failed !== null', { timeout: TIMEOUT_MS });
    const result = await page.evaluate('window.__interop');

    if (result.failed) throw new Error('the browser reported: ' + result.failed);
    if (result.echoed !== 'echo:from the browser') {
      throw new Error('expected the peer to echo, got: ' + JSON.stringify(result.echoed));
    }

    const ready = peer.events.find(event => event.event === 'ready');

    if (!ready || ready.dtlsClient !== true || ready.iceControlling !== false) {
      throw new Error('the answering peer took the wrong roles: ' + JSON.stringify(ready));
    }

    console.log('  passed: answered, and took the ICE-controlled / DTLS-client pair');
  } finally {
    peer.kill();
  }
}

async function crossbyteOffers(page) {
  console.log('\n=== CrossByte offers, the browser answers ===');
  console.log('  CrossByte should end up ICE-controlling and the DTLS server');

  const peer = startPeer({ mode: 'offer' });

  try {
    const offer = await peer.wait('offer', 15000);

    if (!offer.sdp || offer.sdp.indexOf('m=application') < 0) {
      throw new Error('the peer produced no data channel offer');
    }

    if (offer.sdp.indexOf('a=setup:actpass') < 0) {
      throw new Error('an offer should leave the DTLS role open, and this one did not');
    }

    await probeReachable(offer.sdp);

    const answer = await page.evaluate('window.__answerOffer(' + JSON.stringify(offer.sdp) + ')');

    if (!answer || answer.indexOf('a=fingerprint') < 0) {
      throw new Error('the browser produced no usable answer');
    }

    peer.send({ sdp: answer });

    await page.waitForFunction('window.__interop.echoed !== null || window.__interop.failed !== null', { timeout: TIMEOUT_MS });
    const result = await page.evaluate('window.__interop');

    if (result.failed) throw new Error('the browser reported: ' + result.failed);
    if (result.echoed !== 'from crossbyte') {
      throw new Error('expected the browser to receive the message, got: ' + JSON.stringify(result.echoed));
    }

    await peer.wait('message', 10000);

    const ready = peer.events.find(event => event.event === 'ready');

    // The combination the other direction never reaches, and the one a stack
    // with a single role bit gets wrong.
    if (!ready || ready.dtlsClient !== false || ready.iceControlling !== true) {
      throw new Error('the offering peer took the wrong roles: ' + JSON.stringify(ready));
    }

    console.log('  passed: offered, and took the ICE-controlling / DTLS-server pair');
  } finally {
    peer.kill();
  }
}

(async () => {
  await new Promise(resolve => server.listen(PORT, '127.0.0.1', resolve));

  const browser = await puppeteer.launch({
    args: [
      '--no-sandbox',
      '--disable-dev-shm-usage',
      // Without this Chrome replaces every host candidate with a random .local
      // mDNS name, which nothing here resolves -- so the two peers would
      // exchange candidates neither could dial and the test would fail for a
      // reason unrelated to the code under test. It is a privacy measure aimed
      // at pages fingerprinting a visitor's network, and turning it off is
      // appropriate for a loopback test and nowhere else. A deployment facing
      // real browsers reaches them through reflexive or relayed candidates
      // instead; see PeerConnection's documentation.
      '--disable-features=WebRtcHideLocalIpsWithMdns'
    ]
  });

  let failed = null;

  for (const direction of [browserOffers, crossbyteOffers]) {
    const page = await browser.newPage();
    const pageErrors = [];
    page.on('pageerror', error => pageErrors.push(String(error)));
    page.on('console', message => {
      if (message.type() === 'error') pageErrors.push('console.error: ' + message.text());
    });

    try {
      await page.goto('http://127.0.0.1:' + PORT + '/index.html', { waitUntil: 'domcontentloaded' });
      await direction(page);

      if (pageErrors.length > 0) {
        throw new Error('the page reported errors:\n  ' + pageErrors.join('\n  '));
      }
    } catch (error) {
      failed = failed || error.message;
      console.error('\nFAILED (' + direction.name + '): ' + error.message);
      const log = await page.evaluate('(window.__interop && window.__interop.log || []).join("\\n")').catch(() => '');
      if (log) console.error('browser log:\n' + log);
      if (pageErrors.length) console.error('page errors:\n  ' + pageErrors.join('\n  '));
    }

    await page.close();
  }

  await browser.close();
  server.close();

  if (failed) {
    console.error('\nINTEROP FAILED: ' + failed);
    process.exit(1);
  }

  console.log('');
  console.log('INTEROP PASSED');
  console.log('  a real RTCPeerConnection and CrossByte opened a data channel and');
  console.log('  exchanged messages, in both directions and both role pairings.');
})();
