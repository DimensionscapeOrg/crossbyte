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
// Both are run twice more, against a browser hiding its addresses and one not.
// By default Chrome publishes every host candidate as a random .local mDNS
// name -- a privacy measure, so a page cannot fingerprint a visitor's network
// -- and nothing here resolves those. This test used to switch that off, which
// made it a test of a browser no visitor runs. It is left on now, and what
// carries the connection instead is asserted rather than assumed: the browser
// can still reach CrossByte, whose addresses are real, and the check it sends
// teaches CrossByte where it is. ICE calls that a peer-reflexive candidate.
//
// Usage: node ci/interop/run.js
// Needs puppeteer and the peer built by `haxe ci/browser-interop.hxml`.

const http = require('http');
const fs = require('fs');
const path = require('path');
const dgram = require('dgram');
const { spawn } = require('child_process');
const readline = require('readline');

// Whatever the operating system hands out. A fixed number in the dynamic
// range is one Windows may have reserved: Hyper-V and WinNAT exclude blocks of
// it at boot, and on a machine where 50501-50600 is one of them, a fixed 50574
// failed with "listen EACCES" before the browser was ever launched.
let PORT = 0;
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

/**
 * Asserts how the connection was made, not merely that it was.
 *
 * With the browser hiding its addresses, every candidate it publishes is a
 * .local name that resolves to nothing here, so no pair built from its
 * description can be dialled. What is left is the check the browser sends to
 * CrossByte -- whose addresses are real -- and the source address on it, which
 * ICE turns into a peer-reflexive candidate. If that is the mechanism, the
 * selected pair says prflx; anything else means the connection was made some
 * way this test did not intend and does not describe.
 */
function checkPath(ready, mdns, browserSdp, peerSdp) {
  const path = ready.path;

  if (!path) {
    throw new Error('the peer reported no selected pair');
  }

  const hostCandidates = browserSdp.split(/\r?\n/)
    .filter(line => /^a=candidate:/.test(line) && / typ host/.test(line));
  const named = hostCandidates.filter(line => /\.local /.test(line));

  if (mdns) {
    // Should Chrome ever stop hiding these, this case would quietly go back to
    // proving the easy one, so the premise is checked before the conclusion.
    if (hostCandidates.length === 0 || named.length !== hostCandidates.length) {
      throw new Error('expected every browser host candidate to be a .local name, got:\n  ' +
        hostCandidates.join('\n  '));
    }

    if (path.remoteType !== 'prflx') {
      throw new Error('with the browser hiding its addresses the path can only be learned from an ' +
        'incoming check, so the remote candidate should be peer-reflexive; got ' + JSON.stringify(path));
    }
  } else {
    if (named.length > 0) {
      throw new Error('expected the browser to publish real addresses with mDNS off, got:\n  ' +
        hostCandidates.join('\n  '));
    }

    // Here CrossByte's own checks reach an address the browser published, so
    // the pair it settles on is one it built rather than one it was taught.
    if (path.remoteType !== 'host') {
      throw new Error('with real addresses on both sides the selected pair should be a host one; got ' +
        JSON.stringify(path));
    }
  }

  // Everything above would hold for a peer reachable only over loopback, which
  // is a connection that works because both ends share a machine and would not
  // otherwise. Asserting the *selected* pair is not loopback would be checking
  // something nobody here decides -- both of CrossByte's candidates carry the
  // same priority and the controlling agent picks -- so what is asserted is
  // what the peer offered. Gathering only toward the browser's candidates left
  // it advertising 127.0.0.1 alone, and this is that regression.
  const advertised = peerSdp.split(/\r?\n/)
    .filter(line => /^a=candidate:/.test(line))
    .map(line => line.split(' ')[4]);
  const routable = advertised.filter(address => address !== '127.0.0.1' && address !== '::1');

  if (hasRoutableAddress() && routable.length === 0) {
    throw new Error('CrossByte advertised nothing but loopback while this machine has a routable ' +
      'address, so no browser anywhere else could have reached it: ' + JSON.stringify(advertised));
  }

  console.log('    path: ' + path.localAddress + ' -> ' + path.remoteAddress + ' (' + path.remoteType +
    '), advertised ' + advertised.join(', '));
}

/** Whether this machine has an address a peer elsewhere could use. */
function hasRoutableAddress() {
  for (const addresses of Object.values(require('os').networkInterfaces())) {
    for (const address of addresses || []) {
      if (address.family === 'IPv4' && !address.internal) return true;
    }
  }
  return false;
}

async function browserOffers(page, mdns) {
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

    // Binary, and empty binary. RFC 8831 gives a zero-length message a
    // protocol id of its own, carried as one zero byte -- a subtlety both ends
    // of a homogeneous pair could get wrong together, which is why the browser
    // referees it.
    if (result.binaryEchoed !== '1,2,3,0,250,255') {
      throw new Error('binary did not survive the round trip: ' + JSON.stringify(result.binaryEchoed));
    }

    if (!result.emptyBinaryEchoed) {
      throw new Error('an empty binary message did not survive the round trip');
    }

    const ready = peer.events.find(event => event.event === 'ready');

    if (!ready || ready.dtlsClient !== true || ready.iceControlling !== false) {
      throw new Error('the answering peer took the wrong roles: ' + JSON.stringify(ready));
    }

    checkPath(ready, mdns, offer, answer.sdp);

    // Partial reliability, RFC 3758 and RFC 8832's channel types. The terms
    // the browser asked for have to arrive intact...
    for (const expected of [{ label: 'state', ordered: false }, { label: 'ordered-state', ordered: true }]) {
      const terms = peer.events.find(event => event.event === 'terms' && event.label === expected.label);

      if (!terms || terms.ordered !== expected.ordered || terms.maxRetransmits !== 0 || terms.maxPacketLifeTime != null) {
        throw new Error('the browser asked for ' + JSON.stringify(expected) + ' with maxRetransmits 0 and CrossByte read ' +
          JSON.stringify(terms));
      }
    }

    // ...and a message CrossByte gave up on has to be skipped by the browser,
    // which holds the ordered messages after it until a FORWARD TSN says so.
    await page.waitForFunction('window.__interop.orderedState.length >= 5', { timeout: 15000 }).catch(() => {});
    const orderedState = await page.evaluate('window.__interop.orderedState');

    if (!peer.events.find(event => event.event === 'lost')) {
      throw new Error('the peer never lost the message it was meant to, so nothing needed skipping');
    }

    if (JSON.stringify(orderedState) !== JSON.stringify(['kept-1', 'kept-2', 'kept-3', 'kept-4', 'kept-5'])) {
      throw new Error('after CrossByte gave up on a message the browser received ' + JSON.stringify(orderedState) +
        ': it did not act on the FORWARD TSN, or took the lost message after all');
    }

    // The other way: CrossByte lost the browser's first message on arrival, so
    // what it delivers after that is its reading of Chrome's FORWARD TSN.
    const received = await peer.wait('ordered-received', 15000).catch(() => null);
    const dropped = peer.events.find(event => event.event === 'dropped');

    if (!dropped || dropped.text !== 'b-lost') {
      throw new Error('the peer never lost the browser\'s first message, so nothing needed skipping: ' + JSON.stringify(dropped));
    }

    if (!received || JSON.stringify(received.texts) !== JSON.stringify(['b-kept-1', 'b-kept-2', 'b-kept-3', 'b-kept-4', 'b-kept-5'])) {
      throw new Error('after the browser gave up on a message CrossByte received ' + JSON.stringify(received && received.texts) +
        ': it did not follow the browser\'s FORWARD TSN');
    }

    console.log('  passed: answered, and took the ICE-controlled / DTLS-client pair');
    console.log('  passed: partially reliable channels read both ways, and a message given up on was skipped each way');
  } finally {
    peer.kill();
  }
}

async function crossbyteOffers(page, mdns) {
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

    checkPath(ready, mdns, answer, offer.sdp);

    // The terms CrossByte wrote into DCEP, as the browser reads them.
    await page.waitForFunction('window.__interop.stateTerms !== null', { timeout: 10000 }).catch(() => {});
    const stateTerms = await page.evaluate('window.__interop.stateTerms');

    if (!stateTerms || stateTerms.ordered !== false || stateTerms.maxRetransmits !== 0) {
      throw new Error('CrossByte opened an unordered channel with maxRetransmits 0 and the browser read ' + JSON.stringify(stateTerms));
    }

    console.log('  passed: offered, and took the ICE-controlling / DTLS-server pair');
    console.log('  passed: the browser read the partially reliable channel CrossByte opened');
  } finally {
    peer.kill();
  }
}

(async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  PORT = server.address().port;

  let failed = null;

  // mDNS on is the browser everyone actually runs, and the harder case: no
  // address CrossByte can dial, so the path has to be learned from an incoming
  // check. Off is kept as well, because it is the only configuration where
  // CrossByte's own checks reach a candidate the browser published -- the
  // sending half of ICE, which the other configuration never exercises.
  for (const mdns of [true, false]) {
    console.log('\n########  browser ' + (mdns ? 'hiding its addresses (.local mDNS names)' :
      'publishing real addresses') + '  ########');

    const browser = await puppeteer.launch({
      args: [
        '--no-sandbox',
        '--disable-dev-shm-usage'
      ].concat(mdns ? [] : ['--disable-features=WebRtcHideLocalIpsWithMdns'])
    });

    for (const direction of [browserOffers, crossbyteOffers]) {
      const page = await browser.newPage();
      const pageErrors = [];
      page.on('pageerror', error => pageErrors.push(String(error)));
      page.on('console', message => {
        if (message.type() === 'error') pageErrors.push('console.error: ' + message.text());
      });

      try {
        await page.goto('http://127.0.0.1:' + PORT + '/index.html', { waitUntil: 'domcontentloaded' });
        await direction(page, mdns);

        if (pageErrors.length > 0) {
          throw new Error('the page reported errors:\n  ' + pageErrors.join('\n  '));
        }
      } catch (error) {
        failed = failed || error.message;
        console.error('\nFAILED (' + direction.name + ', mdns ' + mdns + '): ' + error.message);
        const log = await page.evaluate('(window.__interop && window.__interop.log || []).join("\n")').catch(() => '');
        if (log) console.error('browser log:\n' + log);
        if (pageErrors.length) console.error('page errors:\n  ' + pageErrors.join('\n  '));
      }

      await page.close();
    }

    await browser.close();
  }

  server.close();

  if (failed) {
    console.error('\nINTEROP FAILED: ' + failed);
    process.exit(1);
  }

  console.log('');
  console.log('INTEROP PASSED');
  console.log('  a real RTCPeerConnection and CrossByte opened a data channel and');
  console.log('  exchanged messages, in both directions and both role pairings,');
  console.log('  against a browser publishing its addresses and one hiding them.');
})();
