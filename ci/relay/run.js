// Puts a TURN server nobody here wrote in front of CrossByte's relay.
//
// The suite already connects two peers through a relay, against a server this
// repository wrote. That is worth having and cannot answer one question: a
// server that verifies a request with the very code that produced it agrees
// perfectly about anything both ends are wrong about. Long-term credentials
// are the obvious place for that -- the key is MD5 of username, realm and
// password rather than the password itself, and an implementation can have
// every byte of the integrity right and still derive the wrong key -- but the
// same applies to permissions, Send indications and the wrapping of relayed
// data.
//
// node-turn implements RFC 5389 and 5766. What it accepts is evidence.
//
// The peers are given only their relayed candidates and bind different
// loopback addresses, so neither is told an address of the other's it could
// dial and the server's permission checking has something to distinguish. What
// crosses is a real data channel message, over DTLS and SCTP, every byte of it
// forwarded twice.
//
// Usage: node ci/relay/run.js
// Needs node-turn and the peer built by `haxe ci/relay-interop.hxml`.

const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const PEER = path.join(__dirname, '..', '..', 'export', 'relay', 'RelayInteropPeer.exe');
const PORT = Number(process.env.CROSSBYTE_TURN_PORT || 34783);
const USERNAME = 'crossbyte';
const PASSWORD = 'a-relay-credential';
const REALM = 'crossbyte.test';

let Turn;
try {
  Turn = require('node-turn');
} catch (_) {
  console.error('node-turn is not installed. Run: npm install --no-save node-turn');
  process.exit(2);
}

const peerPath = fs.existsSync(PEER) ? PEER : PEER.replace(/\.exe$/, '');

if (!fs.existsSync(peerPath)) {
  console.error('No relay peer at ' + PEER + '. Build it: haxe ci/relay-interop.hxml');
  process.exit(2);
}

const events = [];

const server = new Turn({
  authMech: 'long-term',
  credentials: { [USERNAME]: PASSWORD },
  realm: REALM,
  listeningIps: ['127.0.0.1'],
  listeningPort: PORT,
  relayIps: ['127.0.0.1'],
  debugLevel: 'ALL',
  debug: (level, message) => {
    const line = String(message);
    events.push(line);

    // How many times the server forwarded, which for a message of a hundred
    // and twenty-eight kilobytes is a count in the hundreds and for a greeting
    // that fits in one datagram is a handful. It says the chunks really did
    // cross one at a time rather than the far end having been reached some
    // other way.
    if (/relaying data/i.test(line)) {
      relayed++;
    }
  }
});

let relayed = 0;

server.start();
console.log('node-turn on 127.0.0.1:' + PORT + ', long-term credentials, realm "' + REALM + '"');
console.log('');

// Not spawnSync: that blocks this process, and a server unable to read its
// socket while the client talks to it answers nothing at all -- which looks
// exactly like a peer that never sent anything.
const peer = spawn(peerPath, ['127.0.0.1', String(PORT), USERNAME, PASSWORD], { stdio: ['ignore', 'pipe', 'inherit'] });

let output = '';
peer.stdout.on('data', chunk => {
  output += chunk;
  process.stdout.write(chunk);
});

peer.on('exit', code => {
  server.stop();

  const failures = [];

  if (!/SUCCESS/.test(output)) {
    failures.push('the peers did not exchange a message through the relay');
  }

  // A message far larger than a datagram, so the chunking, the ordering and the
  // acknowledgements all cross the relay rather than only a greeting that fits
  // in one packet.
  if (!/128KB message crossed intact/.test(output)) {
    failures.push('a message larger than one datagram did not survive the relay');
  }

  // The path has to be the relayed one. Nothing else was offered, so anything
  // else would mean the peers found each other some way this does not describe.
  if (!/connected over relay -> relay/.test(output)) {
    failures.push('the connection did not settle on the relayed pair');
  }

  // And the server has to have done the work. These are its own words for the
  // exchange, so they say the allocation was granted by something that is not
  // this repository rather than merely reported as granted.
  const granted = events.filter(line => /allocate success/i.test(line)).length;

  if (granted < 2) {
    failures.push('expected two allocations to be granted, the server logged ' + granted);
  }

  if (!events.some(line => /relaying data/i.test(line))) {
    failures.push('the server never relayed any data, so nothing crossed it');
  }

  // A hundred and twenty-eight kilobytes is a hundred and twenty-eight chunks
  // of a kilobyte, and each one is forwarded on its own. A handful of forwards
  // would mean the large message arrived some way this does not describe.
  if (relayed < 128) {
    failures.push('the server forwarded only ' + relayed + ' datagrams, too few for the message that crossed');
  }

  console.log('');
  console.log('the server logged ' + events.length + ' events, ' + granted + ' allocations granted');
  console.log('it forwarded ' + relayed + ' datagrams between the two peers');

  if (failures.length > 0 || code !== 0) {
    console.error('');
    console.error('RELAY INTEROP FAILED');
    for (const failure of failures) console.error('  ' + failure);
    if (code !== 0) console.error('  the peer exited with ' + code);

    console.error('');
    console.error('what the server logged:');
    for (const line of events.slice(-40)) console.error('  ' + line.split('\n')[0]);
    process.exit(1);
  }

  console.log('');
  console.log('RELAY INTEROP PASSED');
  console.log('  two peers with no path between them but a relay written by somebody');
  console.log('  else opened a data channel and a message crossed it.');

  // Stopping the server does not release its socket, so the event loop stays
  // alive with nothing left to do and the run hangs after having passed --
  // which a CI job reports as a timeout rather than as the success it was.
  process.exit(0);
});
