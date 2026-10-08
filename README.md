# CrossByte

<p align="center">
  <img src="crossbyte.png" alt="CrossByte logo" width="160" />
</p>

CrossByte is a cross-platform Haxe runtime for networked, event-driven programs: servers, game servers, services
and tools. Sockets, HTTP, WebSocket, reliable UDP, WebRTC data channels, RPC, timers, threads, files, crypto,
compression, IPC and database clients share one event loop and one set of conventions.

It builds natively through hxcpp, and for the JVM, Node.js, HashLink, Neko and the Haxe interpreter. Where a target
lacks a feature, the member says so, usually through `isSupported` or `isAvailable()`.

## What it is good at

- Servers that hold many connections. Every limit on what one peer can make a server hold is on by default, and
  a server can spread its connections over several threads.
- Game servers: reliable UDP with delivery modes, opt-in encryption and one-copy fan-out, plus fixed-step
  simulation, spatial indexes and delta encoding.
- HTTP/1.1 and HTTP/2, clients and servers, WebSocket, and typed RPC over any connection.
- Peer-to-peer through NAT, including WebRTC data channels to and from browsers.
- Headless tools and backend services that want a runtime without an engine around it.

## Install

```sh
haxelib install crossbyte
```

Or track the repository:

```sh
haxelib git crossbyte https://github.com/dimensionscapeorg/crossbyte.git
```

Native (hxcpp) builds need the `production` branch of the
[`dimensionscape/hxcpp`](https://github.com/dimensionscape/hxcpp) fork, which has the socket, TLS and crypto support
CrossByte builds on; hxcpp 4.3.2 from haxelib does not.

```sh
haxelib git hxcpp https://github.com/dimensionscape/hxcpp.git production
```

The other targets need nothing more, except Node, which needs `hxnodejs`. The repository's tasks (tests, samples,
docs) run through the `aedifex` task runner: `haxelib install aedifex`.

## Quick start

A TCP echo server:

```haxe
import crossbyte.core.ServerApplication;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.net.ServerSocket;

class EchoServer extends ServerApplication {
	public static function main():Void {
		new EchoServer();
	}

	var server:ServerSocket;

	public function new() {
		super();
		addEventListener(Event.INIT, _ -> {
			server = new ServerSocket();
			server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> {
				var socket = event.socket;
				socket.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
					socket.writeUTFBytes(socket.readUTFBytes(socket.bytesAvailable));
					socket.flush();
				});
			});
			server.bind(9000);
			server.listen();
		});
	}
}
```

```sh
haxe -lib crossbyte -main EchoServer --cpp bin
```

`ServerApplication` makes the process's first runtime, which polls its sockets on the main thread and ticks 12 times
a second unless set (`ServerApplication.defaultTicksPerSecond`, or `crossByte.tps`). A socket that becomes ready
wakes it at once; timers and tick listeners wait for the next tick. Use `HostApplication` instead when another
framework owns the main loop and advances CrossByte from its own update.

## Features

### Runtimes, timers and threads

A runtime (`CrossByte`) is an event loop on one thread. It polls its sockets, runs its timers and delivers every
event its objects raise, on that thread. `CrossByte.make` starts another runtime on a thread of its own, and
`post` is the thread-safe way to hand it work:

```haxe
import crossbyte.Timer;
import crossbyte.core.CrossByte;

var simulation = CrossByte.make(DEFAULT, WHEEL);
simulation.post(() -> {
	// On the simulation's thread, with its own timers.
	Timer.setInterval(0, 1 / 60, () -> trace("step"));
});
```

Timers use a min-heap by default; `WHEEL` picks a timing wheel, for a runtime holding thousands of short timers it
re-arms constantly. A server can also spread its connections over several runtimes, one per core. See
[docs/runtime.md](docs/runtime.md) for timers, threads, spreading a server and the native garbage collector.

### TCP

`ServerSocket` and `Socket` are event-driven, with TLS. Every server limits what a peer can cost it:

```haxe
import crossbyte.net.RateLimiter;
import crossbyte.net.ServerSocket;

var server = new ServerSocket();
var joins = new RateLimiter(20, 60); // per address: a burst of 20, then one every 3 s
server.admit = (address, port) -> joins.tryAcquire(RateLimiter.addressKey(address));
server.maxConnections = 2000;       // 10,000 unless set
server.runtimeCount = 4;            // serve connections on four threads
server.bind(9000);
server.listen();
```

`admit` is asked about each connection before any work is done for it. [docs/limits.md](docs/limits.md) lists
every limit, its default, and what a connection costs in memory.

### HTTP

`HTTPServer` serves HTTP/1.1 and HTTP/2 on one port (`http2Enabled`), with static files, middleware, a `Router`,
compression, rate limiting, PHP and graceful `drain()`:

```haxe
import crossbyte.http.HTTPServer;
import crossbyte.http.HTTPServerConfig;
import crossbyte.http.Router;

var router = new Router();
router.get("/hello/:name", ctx -> ctx.handler.respond(200, "text/plain", 'Hello, ${ctx.params.get("name")}'));

var config = new HTTPServerConfig("0.0.0.0", 8080);
config.middleware.push(router.middleware());
var server = new HTTPServer(config);
```

`URLLoader` and `URLRequest` are the client, over HTTP/1.1 or HTTP/2. Each request carries its own limits and
deadlines:

```haxe
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.url.URLLoader;
import crossbyte.url.URLRequest;

var request = new URLRequest("https://api.example.com/report");
request.totalTimeout = 60000; // the whole load, in milliseconds
request.maxBodySize = 4 * 1024 * 1024;
var loader = new URLLoader();
loader.addEventListener(Event.COMPLETE, _ -> trace(loader.data));
loader.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> trace(e.text));
loader.load(request);
```

### WebSocket

`ServerWebSocket` accepts sessions and `WebSocket` connects to them, with TLS and permessage-deflate. A
`PreparedMessage` is encoded and framed once, then sent to as many sessions as you like:

```haxe
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.WebSocketMessageEvent;
import crossbyte.net.PreparedMessage;
import crossbyte.net.ServerWebSocket;
import crossbyte.net.WebSocket;

var server = new ServerWebSocket();
server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> {
	var session:WebSocket = cast event.socket;
	session.addEventListener(WebSocketMessageEvent.MESSAGE, message -> {
		// Every session hears what any one of them says.
		server.broadcast(PreparedMessage.text(message.text));
	});
});
server.bind(8080);
server.listen();
```

### Reliable UDP

`ReliableDatagramServerSocket` and `ReliableDatagramSocket` carry messages over UDP in reliable, unreliable or
sequenced delivery, with congestion control, NAT rebinding and opt-in encryption:

```haxe
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.net.DeliveryMode;
import crossbyte.net.PreparedDatagram;
import crossbyte.net.ReliableDatagramServerSocket;

var server = new ReliableDatagramServerSocket();
// Asked before the server holds anything for the session.
server.admit = (address, port, payload) -> payload.toString() == "ticket-42";
server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, event -> {
	var session = event.socket;
	session.addEventListener(DatagramSocketDataEvent.DATA, e -> session.send(e.data));
});
server.bind(7777);
server.listen();

// Later, every tick: one copy of the state, sent to every session.
function sendState(state:crossbyte.io.ByteArray):Void {
	server.broadcast(PreparedDatagram.of(state), null, DeliveryMode.sequenced(0));
}
```

[docs/reliable-udp.md](docs/reliable-udp.md) covers the handshake, players whose address changes, encryption, and
what a session and a message cost.

### WebRTC and NAT traversal

- `PeerConnection` and `DataChannel`: the full stack, ICE to SCTP over DTLS, interoperable with a browser's
  `RTCPeerConnection` in either signalling direction. Native only, since DTLS needs mbedTLS. A server holding many
  peers puts them on one port with `PeerConnectionHost`.
- `StunClient` and reflexive gathering, so a peer behind NAT learns the address the world sees, and RFC 5780's tests
  (`classifyMapping`, `classifyFiltering`) for what kind of NAT is in the way.
- `TurnClient` and relayed candidates for the peers no direct path reaches.
- Hole punching on the reliable UDP sockets, without a browser, with a TURN relay to fall back on
  (`ReliableDatagramServerSocket.allocateRelay`).

```haxe
// Given sendToPeer:crossbyte.net.rtc.PeerDescription->Void.
import crossbyte.net.LocalAddress;
import crossbyte.net.ice.IceCandidate;
import crossbyte.net.rtc.PeerConnection;

var connection = new PeerConnection(true);
connection.bind(0, "0.0.0.0");
LocalAddress.primary().then(address -> {
	connection.addLocalCandidate(IceCandidate.host(address, connection.localPort));
	sendToPeer(connection.description()); // and connection.connect(theirs) when it comes back
});
connection.ready.then(_ -> {
	var chat = connection.createDataChannel("chat");
	chat.opened.then(_ -> chat.send("hello"));
});
```

### RPC

Calls described as a Haxe interface, encoded and dispatched by code a macro generates: no reflection, no field
names on the wire. RPC runs over any `NetConnection` (TCP, WebSocket, reliable UDP, local IPC) on every target.

```haxe
import crossbyte.net.NetConnection;
import crossbyte.rpc.RPCCommands;
import crossbyte.rpc.RPCHandler;
import crossbyte.rpc.RPCSession;

interface ChatRoomContract {
	function say(room:String, text:String):Void;
	function join(room:String):Int;
}

@:rpcContract(ChatRoomContract)
class ChatRoomCommands extends RPCCommands {
	public function new() {}
}

class ChatRoomHandler extends RPCHandler implements ChatRoomContract {
	var members = new Map<String, Int>();

	public function new() {}

	public function say(room:String, text:String):Void {
		trace('[$room] $text');
	}

	public function join(room:String):Int {
		final count = (members.exists(room) ? members.get(room) : 0) + 1;
		members.set(room, count);
		return count;
	}
}
```

```haxe
var commands = new ChatRoomCommands();
var connection = new NetConnection("tcp://127.0.0.1:4000");
var session = new RPCSession(connection, commands);
connection.onReady = () -> {
	commands.say("lobby", "hello");
	commands.join("lobby").then(count -> trace('$count in the room'), message -> trace('could not join: $message'));
};
```

The [RPC guide](docs/rpc.md) covers the server side, what can be sent, errors, deadlines and the runtime lane.

### Data, storage and the rest

- **Databases.** SQLite natively. MySQL and MariaDB natively, through hxcpp's bundled client, and on the jvm
  through Connector/J. PostgreSQL natively through libpq, and on php through PDO. MongoDB over its wire protocol on
  hxcpp, the jvm, the interpreter, hl and neko. `ConnectionPool` and `AsyncDatabase` keep these blocking drivers
  off the runtime's thread. [docs/data.md](docs/data.md) has the details and limits.
- **Crypto.** Natively, from libsodium and BLAKE3 compiled in: `Aead` (XChaCha20-Poly1305), `KeyExchange` and
  `X25519`, `GenericHash` (BLAKE2b), `HKDF`, `Ed25519` and `Blake3`; from mbedTLS, RSA and ECDSA signatures
  (`PublicKeySignature`, `SignatureKey`). Elsewhere `isAvailable()` is false and they throw. `Argon2id` natively
  and on Node 24.7 or later; `BCrypt` everywhere, in Haxe, though hashing needs a secure random source. Secure random bytes natively, on the jvm, on Node, in a browser
  and on PHP; not on the interpreter, neko or HashLink.
- **Compression.** DEFLATE, GZIP, LZ4 and Brotli. LZ4 and Brotli are written in Haxe, and can use native backends
  instead (see Extensions).
- **IPC.** `LocalConnection`, `SharedChannel` and `SharedObject`, natively on Windows, Linux and macOS. On every
  other target they say so with `isSupported`, and throw when used.
- **Processes and workers.** `Worker`, task pools, and `NativeProcess`, which starts a child process and reads its
  output natively, on the jvm, HashLink, Neko and Node; not on the interpreter or in a browser.
- **Files and bytes.** File APIs, `ByteArray`, `ByteArrayInput` and `ByteArrayOutput`.
- **Data structures.** `ExpiringMap` for what a server keeps on a peer's behalf, bounded by time (`ttl`) and by
  count (`maxSize`, 100,000 unless set); `ObjectPool`, which keeps 10,000 free objects unless `maxFree` says
  otherwise; and for game servers `FixedStep`, `SpatialGrid`, `InterestSet`, `SequenceRing` and `ByteDelta`.

## Build defines

All optional, all off unless you pass them.

| Define | Effect |
| --- | --- |
| `crossbyte_brotli_native` | Brotli through the native backend from the `crossbyte-brotli` haxelib instead of the bundled Haxe implementation. |
| `crossbyte_lz4_native` | LZ4 through the native backend from the `crossbyte-lz4` haxelib instead of the bundled Haxe implementation. |
| `crossbyte_libuv_native` | Builds the libuv poll backend from the `crossbyte-libuv` haxelib (cpp only). Needs libuv's headers and library, and `LibuvPoll.install()` called before the first runtime is created; without the define `install()` returns false and the built-in backend is used. See that repository's README. |
| `crossbyte_no_http2` | Does not auto-register the bundled HTTP/2 backend. A backend registered through `HTTPBackendRegistry` still wins either way; this only stops the bundled one being picked up on its own. |
| `crossbyte_check_events` | Finds code that keeps an event, or the received bytes one carries, past its listener call (see `Event`). Every event and payload handed out for an arrival is made afresh and poisoned once the call returns: bytes overwritten with `0xDB`, length and position 0, fields cleared. For tests and debugging. |
| `crossbyte_fresh_events` | Makes every event and payload handed out for an arrival afresh, where a release build reuses one of each per socket, session or connection. A workaround for code that keeps them, until it copies what it keeps. |
| `crossbyte_keep_nofile` | Natively on Linux and macOS, keeps the process's limit on open descriptors as it started, rather than raising the soft limit to the hard one (see [docs/limits.md](docs/limits.md)). For a process that starts children which `select()` on descriptors below 1,024. |
| `precision_tick` | A runtime waits out the end of each frame in 1 ms sleeps, spinning the last fraction, rather than in one wait: closer frame timing for more CPU. |
| `timer_burst_catchup` | A heap timer that has fallen several intervals behind fires once for each interval it missed, rather than once. |
| `http_debug` | Logs each response line the HTTP client reads, through `Logger`. |
| `crossbyte_debug` | Keeps `crossbyte.io.File` out of `@:noDebug`, so its frames appear in stack traces. |

For example:

```sh
haxe -lib crossbyte -lib crossbyte-lz4 -D crossbyte_lz4_native -main Main --cpp bin
```

One of hxcpp's own matters to a server that holds a lot in memory: a native process can hold about 2 GB of objects,
and `-D HXCPP_GC_BIG_BLOCKS` doubles that. [docs/runtime.md](docs/runtime.md) explains, with the collector's pauses
and `CrossByte.collectWhenIdle`.

## Targets

Native builds, on Windows, Linux and macOS, have every feature. The other targets lack what needs a native library
(IPC, WebRTC, SQLite, and the libsodium, BLAKE3 and mbedTLS crypto) and a few things more: HashLink, Neko and the
interpreter have no secure random source, the interpreter has no UDP, and Node runs every runtime on one thread.
[docs/targets.md](docs/targets.md) lists what each target needs and what differs.

## Extensions

Features that need a native library live in sibling haxelibs, so the core needs none of them:

- `crossbyte-libuv`: a libuv poll backend, cheaper than the built-in one for many mostly idle connections;
- `crossbyte-brotli`: a native Brotli backend;
- `crossbyte-lz4`: a native LZ4 backend.

Each is turned on with its define (see Build defines).

## Samples

[samples/](samples/README.md) has small runnable programs: a TCP chat, a web server, HTTP/2, a server on several
cores, WebSocket echo, UDP and reliable UDP, RPC, the IPC classes, workers, a Windows service, and an authoritative
game server with bots that checks itself.

## Documentation

- [Runtime, timers and threads](docs/runtime.md)
- [What a peer can cost: server limits](docs/limits.md)
- [Reliable UDP](docs/reliable-udp.md)
- [RPC](docs/rpc.md)
- [Databases](docs/data.md)
- [Targets](docs/targets.md)
- [Testing, benchmarks and load tests](docs/testing.md)
- [Contributing](CONTRIBUTING.md) and [releasing](RELEASING.md)
- [Changelog](CHANGELOG.md)

The API reference is generated from the source with `aedifex task docs-api .`; every class documents its defaults,
limits and per-target differences at the member.
