# Runtimes, timers and threads

A CrossByte runtime (`CrossByte`) is an event loop on one thread. Everything an object does on a runtime (its
sockets, its handlers, its timers) runs on that runtime's thread, so code that keeps to one runtime needs no locks.

## Making runtimes

A program starts with one, made by its application class:

- `ServerApplication`: a poll-driven runtime on the main thread, for servers and daemons;
- `HostApplication`: for when another framework owns the main thread and advances CrossByte from its own loop;
- `Application`: the default loop.

`CrossByte.make` makes another runtime, on a thread of its own. `CrossByte.current()` is the runtime of the thread
you are on, and `post` is the one thread-safe way into a runtime from another thread:

```haxe
import crossbyte.core.CrossByte;

var net = CrossByte.make(POLL);
net.post(() -> trace("on the network runtime's thread"));
```

## Timers

Every runtime schedules its timers with a min-heap, and for almost every program that is the end of it. It orders
timers exactly, a one-millisecond delay costs what a six-hour delay costs, and thirty thousand recurring timers
still use well under a millisecond a frame.

The exception is a runtime holding thousands of short timers that it re-arms constantly: a deadline per connection,
a cooldown per entity. There the heap's `O(log n)` starts to show, and a timing wheel does better:

```haxe
import crossbyte.core.ServerApplication;

class MyServer extends ServerApplication {
	public function new() {
		super(WHEEL);
	}
}
```

The choice belongs to the runtime rather than the build, because a process usually has more than one, and they
rarely want the same answer. A simulation thread with a timer per entity and a network thread with a handful can
each have what suits them:

```haxe
var sim = CrossByte.make(DEFAULT, WHEEL);
var net = CrossByte.make(POLL, HEAP);
```

With one recurring timer per entity, the CPU spent per simulated second at sixty ticks:

| timers | heap | wheel |
| --- | --- | --- |
| 1,000 | 1ms | under 1ms |
| 10,000 | 10ms | 2ms |
| 30,000 | 44ms | 7ms |

Arming and cancelling is roughly twice as fast on the wheel.

The wheel has costs of its own. It covers a fixed span ahead of now, and anything scheduled past that span waits in
a list it rescans periodically, so if your timers are mostly long, you pay for work the heap never does: stay on the
heap. Timers due in the same tick fire in bucket order rather than by exact time, and a timer can be late by up to a
tick. It is never early.

In short: use the wheel when the scheduler shows up in a profile and your timers are many and short. Otherwise the
heap is already the right answer.

## Using more than one core

A server on one runtime uses one core, however many the machine has. A server can spread its connections over
several runtimes instead:

```haxe
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.net.ServerSocket;

var server = new ServerSocket();
// Four runtimes, each a thread of its own polling its sockets.
server.runtimes = [for (_ in 0...4) CrossByte.make(POLL)];
server.addEventListener(ServerSocketConnectEvent.CONNECT, function(event) {
	// Runs on the runtime this connection was handed to, and so does
	// everything the connection does from here on.
	var socket = event.socket;
	socket.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
		socket.writeUTFBytes(socket.readUTFBytes(socket.bytesAvailable));
		socket.flush();
	});
});
server.bind(9000);
server.listen();
```

The listener stays on the runtime that called `listen()`, and accepts. Each connection it accepts is handed, before
its TLS handshake, to one of `runtimes` in turn (passing over any that has exited), and belongs to that runtime for
its whole life: its socket is polled there, its events and deadlines run there, and so does the `connect` listener
that receives it. `runtimeCount = 4` makes the runtimes for you instead. `ServerWebSocket` takes the same settings,
and so does `HTTPServer`, through its configuration:

```haxe
// Given router:crossbyte.http.Router.
import crossbyte.http.HTTPServer;
import crossbyte.http.HTTPServerConfig;

var config = new HTTPServerConfig("0.0.0.0", 8080);
config.runtimeCount = 4;
config.middleware.push(router.middleware());
var server = new HTTPServer(config);
```

Each request is served on its connection's runtime, HTTP/1.1 and HTTP/2 alike. `maxConnections`, the rate limiter
and the metrics count every runtime's connections together, and `drain()`, `close()` and `stopAccepting()` cover all
of them.

What it buys, measured natively on Windows with small GETs from 64 kept-alive connections, the server held to eight
logical CPUs and the clients to eight others (`tests/scaling`):

| runtimes | HTTP/1.1 requests/s | HTTP/2 requests/s |
| --- | --- | --- |
| one (not spread) | 78,000 | 75,000 |
| 2 | 178,000 | 154,000 |
| 4 | 312,000 | 312,000 |

A server on one runtime pays nothing for the feature.

### Choosing the runtime

`selectRuntime` chooses the runtime instead, from the peer's address, and runs on the listener's runtime. A game
server that runs each match on a runtime of its own sends a player to the runtime that owns their match, so the
match's state is only ever touched from one thread:

```haxe
// Given matchRuntimes:Array<CrossByte>, joinMatch:crossbyte.net.WebSocket->Void.
import crossbyte.net.ServerWebSocket;

// What the matchmaker decided: the runtime each joining address's match runs on.
var joining:Map<String, CrossByte> = new Map();

var server = new ServerWebSocket();
server.runtimes = matchRuntimes;
server.selectRuntime = (address, port) -> joining.get(address);
server.addEventListener(ServerSocketConnectEvent.CONNECT, function(event) {
	// On the match's runtime: the match can be reached without a lock.
	joinMatch(cast event.socket);
});
```

An answer of `null`, or of a runtime that has exited, takes the next in turn.

### What runs where

Handlers that keep to their own connection need nothing. What several runtimes' handlers share (a table of players,
a cache, a counter, a database pool) is touched from several threads at once, and must be thread-safe or kept per
runtime: reach the runtime's own with `CrossByte.current()`, or hand work to one with `runtime.post(...)`. In
particular:

- `connect` listeners, an `HTTPServer`'s middleware, routes and hooks (`onError`, `onExpectContinue`,
  `rateLimitKey`), a `ServerWebSocket`'s `upgrade` and an SNI predicate run on each connection's runtime, several at
  once;
- `admit` and `selectRuntime` run on the listener's runtime alone;
- a `Router` is read-only once its routes are added, and safe to share;
- the server's own shared pieces are made safe for you: the limits and counts, `HTTPServerConfig.rateLimiter`
  (given a lock as the server starts), the metrics registry and the compression cache.

Add listeners and routes before `listen()`. `close()` on a connection from any thread is handed to its runtime, as
everywhere.

### One port per runtime on Linux

On Linux, `reusePort` gives each runtime a listening socket of its own on the port (`SO_REUSEPORT`), and the kernel
shares connections out, so no one runtime accepts for the others. It pays when connections arrive faster than one
thread accepts them. The kernel then decides where a connection goes, so `selectRuntime` is not asked, and each
runtime asks `admit` for itself. macOS and the BSDs take the option without sharing anything out, and Windows has
nothing like it; setting it there throws.

### Where it works

Natively and on the jvm each runtime is a thread, and they run at once. Neko's threads run at once too but contend
for its allocator: the server above, on neko, answered 1.4 times as many requests on two runtimes as on one, and no
more on four. HashLink runs them on threads as well. On the interpreter the runtimes take turns (two busy threads
take twice as long as one), so a spread server is served correctly and no faster. On Node every runtime shares one
thread, so a spread server is refused; run several processes there (Node's `cluster`).

### Threads or processes

Every runtime in a process shares one garbage collector, and a collection stops all of them at once: at high
allocation rates the pauses, not the cores, bound the throughput, and a latency-sensitive server sees every
runtime's pause. A process also fails as a whole (one handler's crash or one leak takes every runtime down) and has
one memory budget. Several processes behind a load balancer, or on Linux a server in each with `reusePort` set, all
on one port, give each its own collector and its own fate, at the price of sharing nothing without a network hop.

Spread a process over runtimes when connections need to reach shared state cheaply (a game world, a cache); use
processes when they do not.

## Memory and the native collector

hxcpp's collector numbers its 32 KB blocks in two bytes, so a native process can hold about 2 GB of objects and no
more: past that, an allocation stops the process with an access violation ("Memory exhausted" in a debug log).
Build with `-D HXCPP_GC_BIG_BLOCKS` for 64 KB blocks and twice that.

The collector also stops every thread while it marks, for a time that grows with what is live: about 0.2 ms a
megabyte of small objects. A game server at sixty ticks a second saw pauses of 50 to 70 ms every few seconds with
300 MB live, about 200 ms every twenty seconds with 1.1 GB, and up to 0.7 s with 2.4 GB. A runtime whose ticks must
stay inside a frame wants its live heap well under 100 MB, or the world held where the collector does not scan it.

Where a collection fits between two ticks, `CrossByte.collectWhenIdle` moves it there: the runtime learns how often
the collector runs, and makes the collection that is due in the gap before a tick instead. At thirty ticks a second
with 180 MB of small objects live, two collections in three left the ticks for the gaps between them; a collection
longer than two thirds of the gap stays where it falls. It is off by default, acts only in a runtime's own `DEFAULT`
or `POLL` loop, and does nothing on the jvm, JavaScript, HashLink, neko and the interpreter, whose collectors run on
their own terms. One collection stops every runtime in the process, so turn it on for one runtime only.
