# Reliable UDP

`ReliableDatagramServerSocket` and `ReliableDatagramSocket` carry messages over UDP, each in a delivery mode of its
own: reliable, unreliable, or sequenced on one of 256 channels. This page covers how a session starts, what happens
when a player's address changes, encryption, sending one message to many sessions, and what a session costs. The
server's limits are in [limits.md](limits.md#reliable-udp-servers), and the classes' own documentation covers the
rest, including resuming a player over TCP or WebSocket.

## Joining

A client sends CONNECT, carrying its connection id and the payload its `connect` passed (for the server's `admit`),
every three seconds until the server's HANDSHAKE arrives. Each side's HANDSHAKE says where its sequence starts, and
the client's answer completes it.

`admit` is asked before the server holds anything for the session, and `maxPendingConnections` (256) bounds the
sessions still finishing their handshakes. Since UDP lets any sender write any source address, a server can also make
a join prove that it receives at its address. With `joinValidation` at its default, `UNDER_PRESSURE`, that happens
once more than `joinValidationThreshold` (64) sessions are pending. A validated join has one step more: the server
answers the first CONNECT with a cookie, its keyed hash of the address, port, connection id and time, keeping
nothing, and the client sends the CONNECT again at once with the cookie in it. Only a CONNECT that returns its
cookie, from where the cookie was sent, reaches `admit`.

So a flood of CONNECTs from forged addresses holds at most the threshold's worth of slots, and a real player joins
through it a round trip later; an ordinary join, below the threshold, costs nothing extra. A 1.0 client pads its
CONNECT to 29 bytes, so nothing the server sends back to one is larger. A client from 1.0.0-rc.1, which cannot return
a cookie, joins only while joins are not validated.

## Resets

A frame from an address with no session (a peer whose session the server closed, or one that has restarted) is
answered with a FIN that ends the peer's session at once, so it stops sending into nothing. All the servers in a
process share one allowance of these, `maxResetsPerSecond` (1,000), which holds a second's worth.

## Players who move

A session is found by its peer's address and port, so a player whose address changes (a NAT that hands out a new
port, a phone moving from Wi-Fi to a mobile network) arrives as a stranger, and is reset. With `allowRebind` on, the
server gives each session a key in its HANDSHAKE, and the reset it sends a stranger carries a challenge for the
stranger's address. The player's session, still live, answers from its new address with a REBIND proving it holds
the key; the server moves the session there, on the same object, and both sides send again what was lost meanwhile.
Over loopback, traffic resumed a round trip after the first frame from the new port: 0.2 ms natively, 0.35 ms on
the jvm.

Without encryption the key crosses the network in the clear, so turn rebinding on with encryption, or where nobody
hostile shares the players' paths. An encrypted session's rebind key is derived at both ends with its sealing keys
and never sent, so even someone who saw the whole handshake cannot move it.

TCP and WebSocket connections cannot follow an address: those players reconnect and resume, as
`ReliableDatagramServerSocket`'s class documentation shows under "Resuming a player". That is also the fallback for a
peer from before 1.0.

## Encrypted sessions

A session can seal every datagram after its CONNECT with a key the application gives both ends, as netcode.io does.
CrossByte exchanges no keys and checks no certificates here; that is what DTLS (`crossbyte.net.rtc`) and TLS are
for. Typically a login service, over HTTPS, signs the player in and hands it a connect token and a key; the client
sends the token as its `connect` payload, and the game server derives the same key from the token with a secret only
the servers hold. "Encrypted sessions", in `ReliableDatagramServerSocket`'s class documentation, is that whole
example: the tokens, the key derivation with `HKDF`, the login service, the server and the client.

| Where | What |
| --- | --- |
| `ReliableDatagramSocket.encryptionKey` | the client's 32-byte key, set before `connect`; null (the default) is a session in the clear |
| `ReliableDatagramServerSocket.encryptionKeyFor(address, port, payload)` | asked for each CONNECT `admit` lets in: the session's key, or null |
| `connect` / `connectRelayed` on the server | an `encryptionKey` argument, for sessions it dials |
| `ReliableDatagramSocket.isEncryptionSupported`, `encrypted` | whether this target can, and whether this session does |
| `unauthenticatedDatagrams`, `replayedDatagrams`, `lateDatagrams` | what an encrypted session dropped |
| `ENCRYPTION_OVERHEAD`, `MAX_ENCRYPTED_PAYLOAD_SIZE`, `maxPayloadSize` | 21 bytes a datagram; so 1,179-byte frames, and no sealed datagram past the 1,211 bytes of one in the clear |

**How it works.** Each end of an attempt contributes 16 random bytes in the clear. HKDF-SHA-256 over both and the
application's key gives each direction a key and an IV of its own, so a key given to two sessions never seals two
datagrams alike. Every datagram is sealed with ChaCha20-Poly1305 (RFC 8439). Its nonce is the direction's IV XOR a
64-bit packet number, as TLS 1.3 and QUIC build theirs, and only the number's low 32 bits are sent. The header (a
type byte and that number) is authenticated. A 1,024-number replay window drops a datagram seen before, or older,
before decrypting it. Messages of every delivery mode, acknowledgements, bundles, keepalives and the FIN are all
sealed. CONNECTs and the rebind's PATH frames are not, and an encrypted session's rebind proof is keyed with a key
both ends derive and neither sends.

**It fails closed.** A session that asked for encryption never falls back to the clear. A peer that answers without
it (one from before encryption was added, or a server that gave it no key), a key that does not match, and a
server's refusal each end the attempt with an `ioError` naming the reason, then `close`. A server whose
`encryptionKeyFor` gives a key to a CONNECT that asked for none refuses it too.

**What it does not protect.** Who talks to whom, when, how often and how much (datagram sizes, timing, counts,
packet numbers). The CONNECT and its token, which go in the clear, so a token must be worthless without the key (as
the example's are). Past sessions, once a key or the servers' secret is known: there is no forward secrecy in this
mode. A server's reset is not authenticated either, so it does not end an encrypted session; one whose server
restarted ends at its `idleTimeout`.

| Target | Sealed with | Seal + open, per datagram, 100 B / 1,200 B |
| --- | --- | --- |
| native | libsodium | 0.95 / 2.6 us |
| jvm | CrossByte's own ChaCha20-Poly1305 (Java 8 has none) | 1.1 / 7.9 us |
| Node | Node's `crypto` from 896 bytes, CrossByte's own below (faster there) | 1.5 / 6.5 us |
| HashLink, neko, interpreter | not supported: no secure random source | (none) |

In a real workload (200 sessions over loopback, a reliable and a sequenced message each way a round), encryption
added about 1.25 us a datagram natively, sealing at one end and opening at the other, and nothing to what a message
allocates. A session in the clear is unchanged. An encrypted session a server holds costs about 1.8 KB more than one
in the clear (keys, IVs, the replay window); the buffers it seals and opens into are the server's, shared.

## One message to many sessions

A server sending the same state to many players makes it a `PreparedDatagram` once, and sends that:

```haxe
// Given server:crossbyte.net.ReliableDatagramServerSocket, session:crossbyte.net.ReliableDatagramSocket, snapshot:crossbyte.io.ByteArray, room:Array<crossbyte.net.ReliableDatagramSocket>.
import crossbyte.net.DeliveryMode;
import crossbyte.net.PreparedDatagram;

var state = PreparedDatagram.of(snapshot);                // copied once
server.broadcast(state);                                   // every session connected
server.broadcast(state, room);                             // or the ones the game chose
server.broadcast(state, room, DeliveryMode.sequenced(0)); // in any delivery mode
session.sendPrepared(state);                               // or one at a time
```

Each session frames it with its own sequence numbers, bundles it with whatever else it sends, paces it by its own
window and sends it again as often as its own peer needs, all from the prepared bytes: it holds a record of each frame
in flight and no copy. A `send` per session copies the message for each, and holds every copy until that session's
peer acknowledges it.

For a kilobyte to 1,000 sessions with 1% loss each way, what the sessions hold for it until every peer has it is
under 0.1 MB of frame records, where a `send` each holds 1.27 MB (9 KB against 1.08 MB on the jvm). The call takes
630 ns a session natively, where a `send` each takes 880 to 940 (500 against 630 to 645 on the jvm), and natively it
allocates nothing for the message, where a `send` each allocates 630 KB.

Who receives (rooms, areas of interest) stays the game's choice. An encrypted session shares the message the same
way, sealing each datagram as it goes into a buffer its server's sessions share; what it cannot share is the sealing,
since its keys are its own. As with `ServerWebSocket.broadcast`, nothing is thrown for one session: one not connected
or closing is passed over, and one past its output limit under `THROW` is not thrown for.

## What a session costs

**Memory.** An idle session a server holds costs about 2.7 KB natively and 1.6 KB on the jvm (heap after a full
collection with 1,000 idle sessions connected, less with none, over 1,000), and an encrypted one about 1.9 KB more
natively (1.3 KB on the jvm). What only some sessions use is made when they first need it:

- the ring holding frames that arrive past a gap is made when the first such frame arrives, with 16 slots; it grows
  as far as the frames held reach, and goes at the next keepalive check that finds it empty;
- the buffer a session writes what it sends into grows to the largest bundle the session has sent, and goes back to
  a small one after a keepalive period with nothing sent;
- a session in `DATAGRAM` mode has no stream buffers;
- a session that sends or receives sequenced messages keeps counters for the channels it uses, eight at a time.

A server's sessions share what each writes a HANDSHAKE's and an ACK's payload into. What is left is mostly the
session itself (its fields, listeners and keepalive timer) and the server's maps that find it.

**Garbage per message: none natively.** A reliable message is copied when it is sent, so the caller may reuse its
bytes as soon as `send` returns, and the copy is kept until the peer acknowledges it, since only this side can send
it again. It is kept in a frame taken from a pool, one for all of a server's sessions on its runtime. A frame's
buffer is the smallest of 64, 128, 256, 512, 768 or 1,024 bytes that holds the message, or a whole 1,200-byte frame,
and the frame goes back to the pool once acknowledged. The frames in flight are found by sequence in a ring, not a
map.

A 200-byte message delivered and acknowledged allocates nothing natively, and nothing on the jvm under Java 8, where
CrossByte gives the selector an array to put the sockets it finds ready in, in place of the set it would add each to (as
Netty does). What can remain there is the JDK's own: its selector boxes the descriptor of each socket it finds ready,
16 bytes, on Windows every one (which the JIT often leaves out) and on Linux one past 127. A later Java keeps its own
set: 32 bytes a select with anything ready, at each end.

The pool keeps as many frames as were in flight at once in the last ten to twenty seconds, plus 64. A game server's
tick sends to every session and has it all back before the next, so a thousand frames go out and come back every
tick, and all of them are kept for the next. Once the traffic falls, what was kept for it goes within twenty seconds;
once nothing has come back for ten, all but 64 go.

**What a pass sends.** Natively a server's socket gathers the datagrams its sessions send in a pass and sends them
together when the pass ends (on Linux with `sendmmsg`). They wait in 64 KB chunks that every datagram socket of the
runtime takes from one pool, each datagram whole in one chunk, and the chunks go back to the pool once sent. The
pool keeps what the busiest pass needed while passes go on taking chunks; what a pass no longer needs waits five
seconds more as spare, so a server pausing between matches takes its chunks back, and once ten to fifteen seconds
pass with none taken, all but one chunk go. A 1 KB broadcast to 10,000 sessions holds 10 MB of chunks while the
server keeps broadcasting and 0.2 MB once it is quiet.
