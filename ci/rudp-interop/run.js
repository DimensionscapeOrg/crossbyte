// Runs encrypted reliable UDP sessions between CrossByte built for different
// targets: native (libsodium), the jvm (CrossByte's own ChaCha20-Poly1305,
// since Java 8 has none) and Node (its crypto, and CrossByte's own for small
// datagrams). The suite proves each target's sealed bytes against vectors
// computed elsewhere; this proves whole sessions, handshake, key schedule,
// every delivery mode, a graceful close, across processes.
//
// Usage: node ci/rudp-interop/run.js
// Needs the three ends built: haxe ci/rudp-interop.hxml,
// haxe ci/rudp-interop-jvm.hxml, haxe ci/rudp-interop-node.hxml.

const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { spawn } = require('child_process');

const ROOT = path.join(__dirname, '..', '..');
const ENDS = {
  native: { cmd: path.join(ROOT, 'export', 'rudp-interop', 'RudpInteropPeer.exe'), args: [] },
  jvm: { cmd: 'java', args: ['-jar', path.join(ROOT, 'export', 'rudp-interop-jvm', 'RudpInteropPeer.jar')] },
  node: { cmd: process.execPath, args: [path.join(ROOT, 'export', 'rudp-interop-node', 'peer.js')] },
};

for (const [name, end] of Object.entries(ENDS)) {
  const file = end.args.length > 0 ? end.args[end.args.length - 1] : end.cmd;
  if (!fs.existsSync(file)) {
    console.error(`The ${name} end is not built: ${file}`);
    process.exit(2);
  }
}

function start(end, args) {
  const child = spawn(ENDS[end].cmd, ENDS[end].args.concat(args), { stdio: ['ignore', 'pipe', 'pipe'] });
  child.output = '';
  child.stdout.on('data', (d) => (child.output += d));
  child.stderr.on('data', (d) => (child.output += d));
  child.done = new Promise((resolve) => child.on('exit', (code) => resolve(code)));
  return child;
}

function portOf(server, timeoutMs) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + timeoutMs;
    const timer = setInterval(() => {
      const m = /PORT (\d+)/.exec(server.output);
      if (m) {
        clearInterval(timer);
        resolve(Number(m[1]));
      } else if (Date.now() > deadline) {
        clearInterval(timer);
        reject(new Error('no PORT line: ' + server.output));
      }
    }, 20);
  });
}

async function pair(serverEnd, clientEnd, refused) {
  const key = crypto.randomBytes(32).toString('hex');
  const clientKey = refused ? crypto.randomBytes(32).toString('hex') : key;
  const server = start(serverEnd, ['server', key]);
  let port;
  try {
    port = await portOf(server, 30000);
  } catch (e) {
    server.kill();
    return { ok: false, text: e.message };
  }
  const client = start(clientEnd, ['client', String(port), clientKey].concat(refused ? ['refused'] : []));
  const clientCode = await client.done;
  if (refused) {
    server.kill();
  }
  const serverCode = refused ? 0 : await server.done;
  const ok = clientCode === 0 && serverCode === 0;
  return { ok, text: `client ${clientCode}: ${client.output.trim()} | server ${serverCode}: ${server.output.trim().replace(/\s+/g, ' ')}` };
}

(async () => {
  const runs = [
    ['native', 'native', false],
    ['native', 'jvm', false],
    ['native', 'node', false],
    ['jvm', 'native', false],
    ['node', 'native', false],
    ['jvm', 'node', false],
    ['native', 'jvm', true],
    ['native', 'node', true],
    ['jvm', 'native', true],
  ];
  let failed = 0;
  for (const [s, c, refused] of runs) {
    const result = await pair(s, c, refused);
    console.log(`${result.ok ? 'ok  ' : 'FAIL'} ${s} server, ${c} client${refused ? ', wrong key' : ''}: ${result.text}`);
    if (!result.ok) failed++;
  }
  console.log(`rudp-interop: ${runs.length - failed} of ${runs.length} passed`);
  process.exit(failed === 0 ? 0 : 1);
})();
