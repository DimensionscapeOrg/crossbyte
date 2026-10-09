# What a peer can cost

Every CrossByte server bounds what one peer can make it hold, and every limit is on by default. Each limit belongs to
the object it is set on: one server, or one client, changing its limits changes no other in the process. Each member
also says what it bounds in its own documentation.

None of these limits bounds how often one address connects: a connection that arrives and leaves at once passes all
of them. A server open to the internet keeps a `RateLimiter` in `admit`, which is asked before any work is done for a
connection:

```haxe
import crossbyte.net.RateLimiter;
import crossbyte.net.ServerWebSocket;

var server = new ServerWebSocket();
// A burst of 20 connections from one address, then one every 3 s.
var joins = new RateLimiter(20, 60);
server.admit = (address, _) -> joins.tryAcquire(RateLimiter.addressKey(address));
```

`RateLimiter.addressKey` keys an IPv6 client by its /64, which is what one subscriber is given.

## TCP servers

A `ServerSocket`, and a `NetHost` built on one, and the `HTTPServer` and `ServerWebSocket` built on it, hold each of
these by default:

| On the server | Default | Bounds |
| --- | --- | --- |
| `maxConnections` | 10,000 | connections open at once; one more is closed as it is accepted, and counted in `refusedConnections` |
| `maxPendingHandshakes` | 256 | TLS handshakes under way; more wait in the kernel's queue |
| `maxPendingHandshakesPerAddress` | 16 | one address's share of those, once half are taken; past it a connection is closed as it is accepted |
| `handshakeTimeout` | 10 s | each TLS handshake, from accept |
| `maxAcceptsPerTick` | 64 | connections taken from the queue in one wake |
| `receiveBufferSize`, `sendBufferSize` | the system's | the kernel's buffers for each connection |

Each `Socket` it accepts holds at most `maxInputBufferSize` (16 MiB) unread and `maxOutputBufferSize` unsent (no
limit by default; HTTP and WebSocket servers set 8 MiB).

A raw connection refused at `maxConnections` is accepted and closed at once, so its peer reads an end of stream, or
a reset if it had sent something. Node's `net.Server.maxConnections` does the same: a server's places free up on the
scale of sessions, so a client left queued in the kernel would wait without a word. A `ServerWebSocket` answers the
upgrade with 503 instead, and an `HTTPServer` (its limit from `HTTPServerConfig.maxConnections`) answers the request.
A `NetHost`'s `maxConnections` is its server's, and a reliable UDP host counts its sessions itself.

Behind a proxy that forwards connections before their client has spoken, every connection has the proxy's address:
set `maxPendingHandshakesPerAddress` to 0 there, and bound each client at the proxy.

### Out of descriptors

Each connection is a descriptor, and a process may hold only so many (`RLIMIT_NOFILE` on Linux and macOS). Natively,
CrossByte raises the soft limit to the hard one as the process starts, as Go and the JVM do: a shell's soft limit of
1,024 would otherwise stop a server near a thousand connections, whatever the hard limit allows. Where the limit is
still below 4,096, the first server to listen says so, once. `-D crossbyte_keep_nofile` leaves the limit alone.

Past the limit an accept fails. On Linux the connection waits in the kernel's queue; macOS drops it instead, so its
client finds it closed. The server sets its listener aside for 5 ms, then twice as long after each failure that
follows, at most a second (Go's `net/http` schedule, and what libuv, Netty and nginx do), and takes a waiting
connection once a descriptor frees. `acceptFailures` counts the failures, and the first of a run is reported as an
`ioError`.

### What arrives and is not read

A socket reads what arrives into a buffer of its own, and holds at most `maxInputBufferSize` of it unread: 16 MiB by
default, twice the largest message any CrossByte transport takes. At the limit it stops reading
(`inputOverflowPolicy = PAUSE`, the default) until the application reads, and what the peer sends waits in the
kernel until TCP's window holds the peer back, so nothing is lost. With `CLOSE`, it closes the connection as soon as
a byte arrives past the limit. HTTP, WebSocket, RPC and `NetConnection` read as data arrives and never reach it.

A game server that reads one message a tick can set it to a few of its messages. Keep it above the largest message
the application waits for whole: under `PAUSE`, an application that waits for more than the limit before it reads
anything waits for good.

```haxe
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.net.ServerSocket;

var server = new ServerSocket();
server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> {
	e.socket.maxInputBufferSize = 64 * 1024; // a few of this game's messages
});
```

### What a connection holds

An idle connection a `ServerSocket` accepted holds about 1.5 KB of heap natively and 1.6 KB on the jvm (a client
about 2 KB), plus the listeners the application adds (two cost about 450 bytes) and the kernel's buffers. Its buffers
keep their storage while the connection is busy, so a message read or written allocates nothing, and let it go once
the connection has read and written nothing for one of its runtime's sweeps, every five seconds: after one 16 KB
message each way, a connection holds 1.7 KB once quiet. A buffer grown past 64 KB lets go as soon
as it empties: natively and on the jvm its storage goes to a pool its runtime keeps, by size, which the next buffer
to grow that far takes from, so a connection sending or receiving a large burst each pass reuses the same storage
rather than allocating it again (1 MB bursts allocate about 17 KB for each megabyte, where growing anew took
2.4 MB). The pool's sizes are a quarter apart (64, 80, 96, 112 and 128 KB, and so on to 32 MB), so a buffer holds
at most a quarter more than it needs, and a buffer takes at once the size its last burst needed. The pool lets go
of what nobody has taken for ten to fifteen seconds. A WebSocket session's buffers, and a message past 64 KB, do
the same. On Node a socket keeps its buffers' storage.

### Many connections, mostly idle

The built-in poll walks every connection on every pass of the runtime: natively on Linux about 77 ns a connection,
so 10,000 idle connections cost a pass 0.77 ms, and a `POLL` runtime at rest 5% of a core at 12 ticks a second and
17% at 60 (in WSL, 4 CPUs). A busy server passes once per batch of arrivals, so the same 10,000 with traffic spread
over 1,000 wakes a second spend most of a core in the poll alone. Past about 10% of a core (10,000 connections at
130 passes a second, or 2,000 at 650), the `crossbyte-libuv` backend, whose pass costs what is ready rather than what
is open, starts to pay. On Windows, 8,000 idle connections cost 3% of a core on the built-in poll (select) and
nothing measurable on libuv.

### The kernel's buffers

Much of what a connection costs is in the kernel: what has arrived and not been read, and what has been written and
not acknowledged. Left alone, the system grows both with use (Linux to 6 MB received and 4 MB sent a connection,
Windows by the connection's bandwidth), so a peer that sends and does not read, or reads nothing, makes the kernel
hold that much for it. `receiveBufferSize` and `sendBufferSize` fix them, on a `Socket` before it connects or on a
`ServerSocket` for every connection it accepts (natively and on the jvm):

```haxe
var server = new ServerSocket();
server.receiveBufferSize = 64 * 1024; // before listen(): the window starts there
server.sendBufferSize = 64 * 1024;
```

What the system will not take waits in the socket's own output buffer instead, where `bytesPending` counts it and
`maxOutputBufferSize` bounds it. A smaller buffer is cheaper and slower over a long path: a connection moves at most
one buffer per round trip.

## WebSocket servers

A `ServerWebSocket` holds the TCP limits above, and these:

| On the server | Default | Bounds |
| --- | --- | --- |
| `maxPendingHandshakes` | 256 | connections still upgrading, TLS and the HTTP upgrade together; more wait in the kernel's queue |
| `maxPendingHandshakesPerAddress` | 16 | one address's share of those, once half are taken; past it a connection is closed as it is accepted |
| `handshakeTimeout` | 10 s | each upgrade, from accept |
| `maxHeaderSize` | 16 KiB | the upgrade request's head, answered `431` past it |
| `maxConnections` | 10,000 | sessions open at once, answered `503` past it |
| `maxMessageSize` | 1 MiB | one message arriving, its frames together, refused on a frame's header with 1009 |
| `maxOutputBufferSize` | 8 MiB | what waits for a peer that is not reading, closed with 1011 past it |
| `idleTimeout` | 60 s | silence from the peer, with a ping sent every `pingInterval` (30 s) meanwhile |
| `closeTimeout` | 5 s | the closing handshake |

A peer's pings are answered one at a time, the newest only (RFC 6455 lets a pong answer only the latest ping), so a
peer that pings and reads nothing is owed one pong however many it sends. `refusedConnections` counts the
connections the two connection limits closed, and `handshakeFailures` the upgrades that never finished.

**What a session holds.** An idle session a server accepted holds about 4 KB of heap natively and 3 KB on the jvm,
plus the kernel's socket buffers; a client about the same. Its upgrade request is kept as the head it arrived as,
and its headers are read from that again if they are asked for after the session opened. A session that has heard
nothing and sent nothing for one `pingInterval` (30 s) lets go of what its buffers held for earlier messages: after
one 16 KB message each way, a session holds 4.6 KB once quiet. Output that waited for a slow peer
goes as soon as it drains.

**What a message costs.** Natively, a message sent or received allocates nothing but the `text` a listener asks for,
which is a `String` of its own and safe to keep; a listener that reads `data` allocates nothing. Its bytes and its
event are the session's own, filled again for the next message, and valid only during the listener's call (see
`Event`). A message past 64 KB is read into storage from the pool its runtime keeps for large buffers (see "What a
connection holds"), given back once the listener returns. A client draws its masking keys from a pool of random
bytes, 8 KB at a time.

**One message to many sessions.** `PreparedMessage` makes a message ready once, encoded and framed as a server sends
it, and each session copies the frames into what it sends, where a `sendText` per session would encode, frame and
copy it again for each:

```haxe
// Given server:ServerWebSocket, room:Array<crossbyte.net.WebSocket>.
import crossbyte.net.PreparedMessage;

var update = PreparedMessage.text('{"type":"move","x":12,"y":40}');
server.broadcast(update);       // every session the server has open
server.broadcast(update, room); // or the ones the application chose
```

Who receives (rooms, topics, areas of interest) stays the application's choice. Preparing copies the bytes, so the
buffer it was made from is the caller's again at once, a message event's payload included; the message itself never
changes, and may be kept and sent again from any runtime. Made with `compress`, it also holds a compressed form,
compressed once, for the sessions that agreed to permessage-deflate. A secure session still encrypts on its own, so
TLS shares only the framing; and a client masks each frame with a key of its own, so a client's `sendPrepared`
shares the encoding and frames it itself. Each session still writes once a pass, however many messages it was sent
in it. A broadcast throws nothing for one session: one not open, or closing, is passed over, and one past its
`maxOutputBufferSize` is closed with 1011.

## HTTP clients

What a server you call can cost you is bounded per request, on the `URLRequest`, so one caller's settings never
reach another's requests:

| `URLRequest` | Default | Bounds |
| --- | --- | --- |
| `idleTimeout` | 30 s | time with nothing arriving; natively, on the jvm and the interpreter also the wait for a load thread past `URLLoader.maxConcurrentLoads` |
| `headTimeout` | 300 s | the response's head, from the request having gone; bytes trickling in do not move it |
| `totalTimeout` | none | the whole load, from `load()` to `COMPLETE` |
| `maxBodySize` | 64 MB | the body on the wire; a larger `Content-Length` is refused before it is read |
| `maxDecompressedSize` | 64 MB | what the body decodes to |
| `maxResponseHeaderSize` | 64 KB | the status line and header fields, 1xx responses included |
| `maxRedirects` | 10 | redirects followed before the load fails |

`0` or less lifts any of them. An idle timeout alone does not bound a request: a server sending a byte at a time
resets it with every byte, so give a request to a server you do not trust a `totalTimeout`. A custom `HTTPBackend`
reads the same limits from its `HTTPRequestContext`; the loader cancels a request past its `totalTimeout` through
the context's `cancelToken`.

**Names.** A socket's connect by name, and every client request, looks the name up on one of four threads the
process keeps for it. A system lookup cannot be stopped, so that is the most a wedged resolver can hold. A caller
waits 30 s for the answer at most (less within a request's idle timeout, and a cancel ends the wait at once). An
answer is kept for 30 s and a failure for 5, and callers asking for a name already being looked up share the
lookup.

## HTTP servers and PHP

An `HTTPServer` holds the TCP limits above, with its own `maxConnections` in `HTTPServerConfig`.
`HTTPServerConfig.phpMaxResponseSize` (8 MiB) bounds a PHP script's response, whose CGI header block is held to
64 KiB and 100 lines besides. `phpMaxExchanges` (64) bounds the requests a runtime has with its PHP backend at once;
more wait their turn within `phpTimeout`, and past 1,024 waiting a request is refused.

## Reliable UDP servers

A `ReliableDatagramServerSocket` opens a session for a CONNECT, on the strength of a source address any sender can
write. What that costs, and what it sends to addresses nobody has proved, is bounded:

| On the server | Default | Bounds |
| --- | --- | --- |
| `maxPendingConnections` | 256 | sessions waiting to finish their handshakes |
| `joinValidation` | `UNDER_PRESSURE` | when a join must show it receives at its address before a session is opened |
| `joinValidationThreshold` | 64 | pending sessions past which `UNDER_PRESSURE` validates |
| `maxResetsPerSecond` (static) | 1,000 | FINs every server in the process sends, together, to addresses with no session |
| `allowRebind` | off | whether a session follows its player to a new address |

Each session holds at most `ReliableDatagramSocket.maxOutputBufferSize` (256 KB) waiting for its congestion window,
past which it is ended with an `ioError` saying why. A game that sends more at once (a level, one large reliable
message) raises the limit, or sets it to 0 for none. [reliable-udp.md](reliable-udp.md) explains the handshake and
what a session and a message cost.

## WebRTC

A `PeerConnectionHost` creates nothing for a datagram until it has proved who sent it: a STUN check is answered only
once its MESSAGE-INTEGRITY checks against a connection's credentials, and DTLS is routed by an address ICE has
proved. So there is no reflection and no half-open table to fill. What follows bounds a peer that has been through
signalling, and can send whatever it likes once connected, sharing a runtime with every other peer on it.

| On the connection | Default | Bounds |
| --- | --- | --- |
| `readyTimeout` | 30 s | `connect` until the whole stack is up, and an ICE restart; 0 for no deadline |
| `maxPeerChannels` | 512 | channels the peer opened that are open at once, what libwebrtc's 1,024 streams give one side; past it an OPEN is refused (no ACK, the stream reset) and counted in `refusedChannels`; 0 for no limit |
| `maxLabelSize` | 1 KiB | the label, and the protocol, of a channel the peer opens, in UTF-8 bytes; refused past it likewise; 0 for the wire's 65,535 |
| `IceAgent.MAX_REMOTE_CANDIDATES` | 64 | the peer's candidates, advertised and learned from where its checks arrive; past it a check from a new place goes unanswered |
| `IceAgent.MAX_LEARNED_LOCAL_CANDIDATES` | 64 | places the peer's answers say it saw this end's checks come from; never paired, since a check leaves from their base |

Under the data channels, an SCTP association holds at most 2 MiB the application has not been given (the window it
advertises), 1 MiB of one message being reassembled in at most 2,048 pieces, and 18,432 pieces in all: fragments and
whole messages waiting their turn, every stream together, the most an honest peer can make it hold. Past either
total it gives back half of what it holds, dropping unfinished messages.

What one packet can make it do is bounded by the packet. One SACK is read a packet, and 256 of its gap blocks. A
FORWARD TSN finds the streams it gives up on by the TSN each starts at, and walks a stream by the shorter of the
range it names and what the stream holds. HEARTBEATs and stream-reset requests draw one packet of answers. No more
than 16,384 fragments go past the peer's cumulative acknowledgement; the rest wait, counted in `bufferedAmount`.
