# RPC

CrossByte's RPC turns method calls into frames on any `NetConnection` (TCP,
WebSocket, reliable UDP or local IPC) and back. The calls are typed and
checked at compile time: a macro writes the code that encodes each call and
the code that decodes and dispatches it, so a call costs a method's worth of
encoding rather than a round of reflection.

There are two lanes on one connection:

- **The compiled lane.** You describe the calls as Haxe methods; the build
  generates the rest. This is the one to use.
- **The runtime lane.** Calls named by a number and carrying an array of
  values, for when the set of calls is not known until run time.

RPC runs on every target CrossByte builds for, JavaScript included: the
portable test suite runs it on Node and in a browser. What carries it is the
`NetConnection` a session is given, so it goes wherever one does. PHP has no
sockets in CrossByte, so there RPC is its contracts, its codec and sessions
over a connection that is not a socket (see [targets.md](targets.md#php)).

A session writes every frame it sends (calls, answers, pings) in one
buffer of its own, and hands it to its connection's `send`, which copies what
it keeps before it returns: framing a call allocates nothing. Every transport
CrossByte ships copies. An `INetConnection` of your own must as well, since the
buffer holds the session's next frame as soon as `send` returns; built with
`-D crossbyte_check_events`, a session poisons each frame once it is sent, so
a connection that kept one sends garbage its tests will see.

Every example on this page compiles, in the order it appears: a later example
uses what an earlier one declared.

## A contract, both ends, and a connection

A *contract* is an interface that says what one side can ask of the other.
Its methods use plain types: the value a call answers with, not a wrapper
around it.

```haxe
import crossbyte.rpc.RPCCommands;
import crossbyte.rpc.RPCHandler;

interface ChatContract {
	function say(room:String, text:String):Void;
	function join(room:String):Int;
}
```

The side that makes the calls has a *commands* class. `@:rpcContract` gives it
a stub for each method of the contract, and turns every answer into an
`RPCResponse<T>`, since it arrives later:

```haxe
@:rpcContract(ChatContract)
class ChatCommands extends RPCCommands {
	public function new() {}
}
```

The side that answers has a *handler*, which implements the contract as an
ordinary class does. The build checks its signatures against the contract's.

```haxe
class ChatHandler extends RPCHandler implements ChatContract {
	// One count per room, for everyone: every client's session shares this
	// handler, so these are the server's rooms, not one client's.
	var members = new Map<String, Int>();

	public function new() {}

	public function say(room:String, text:String):Void {
		// `session` is the session whose call this is.
		trace('[$room] ${session.connection.remoteAddress}: $text');
	}

	public function join(room:String):Int {
		final count = (members.exists(room) ? members.get(room) : 0) + 1;
		members.set(room, count);
		return count;
	}
}
```

An `RPCSession` binds either or both to a connection. A server makes one per
client it accepts, and gives every one of them the same handler:

```haxe
import crossbyte.net.NetHost;
import crossbyte.rpc.RPCSession;

var chat = new ChatHandler();
var host = new NetHost("tcp://127.0.0.1:4000", connection -> {
	new RPCSession(connection, null, chat);
});
host.listen();
```

and a client makes one for its connection, and calls through the commands:

```haxe
import crossbyte.net.NetConnection;

var commands = new ChatCommands();
var connection = new NetConnection("tcp://127.0.0.1:4000");
var session = new RPCSession(connection, commands);

connection.onReady = () -> {
	commands.say("lobby", "hello");
	commands.join("lobby").then(count -> trace('$count in the room'), message -> trace('could not join: $message'));
};
```

The session takes over the connection's `onData`; leave it to the session.
Both ends can have both: a session with commands and a handler calls the
other side and answers it on one connection.

## Over each transport

A session works the same over every transport; only how the connection is
made differs:

| Transport | A client | A server |
|---|---|---|
| TCP | `new NetConnection("tcp://host:4000")` | `new NetHost("tcp://0.0.0.0:4000", ...)` |
| TLS over TCP | `"tls://host:4000"`, with `TLSOptions` for a private authority or a client certificate | `new NetHost("tls://0.0.0.0:4000", ...)` with its certificate and key in `TLSOptions` |
| WebSocket | `"ws://host:8080/rpc"`, or `"wss://..."` | `new NetHost("ws://0.0.0.0:8080", ...)`, or `"wss://..."` with `TLSOptions` |
| reliable UDP | `"rudp://host:7777"` | `new NetHost("rudp://0.0.0.0:7777", ...)` |
| reliable UDP, encrypted | a `ReliableDatagramSocket` with its `encryptionKey`, then `NetConnection.fromReliableDatagramSocket` | a `ReliableDatagramServerSocket` with `encryptionKeyFor`, then `NetHost.fromReliableDatagramServerSocket` |
| local IPC (native only) | `"local://name"` | a `LocalConnection` that listens on the name, then `NetConnection.fromLocalConnection` |

In a browser a connection is the page's own WebSocket, so a page dials
`ws://` or `wss://` (a `NetHost` made from one of those is its server) and
cannot listen. Over reliable UDP every frame goes as one reliable, ordered
message, split over datagrams when it is larger than one, unless the call is
given another mode. A `NetConnection`
or `NetHost` given a URI it cannot use throws an `ArgumentError` naming the
URI and the schemes it takes.

Links between hosts of one's own usually run on a private authority, and
prove both ends by certificate (mutual TLS): one `TLSOptions` names this
host's certificate and key, the authority to trust, and the authority a
dialler's certificate must come from, and serves both the host and the
connections it dials. The host reads who dialled it from the certificate:

```haxe
import crossbyte.net.Certificate;
import crossbyte.net.Key;
import crossbyte.net.TLSOptions;

function linkHosts(handler:ChatHandler):NetHost {
	var cluster = Certificate.fromFile("certs/cluster-ca.pem");
	var tls:TLSOptions = {
		certificate: Certificate.fromFile("certs/hub.pem"),
		key: Key.fromFile("certs/hub.key"),
		certAuthority: cluster,
		clientAuthority: cluster
	};
	var dialled = new NetConnection("tls://peer.internal:7000", null, null, null, null, false, tls);
	return new NetHost("tls://0.0.0.0:7000", connection -> {
		var peer = NetConnection.toSocket(connection).peerCertificate;
		trace("dialled by " + (peer == null ? "nobody known" : peer.commonName));
		new RPCSession(connection, null, handler);
	}, null, null, true, tls);
}
```

A call that the next one replaces (a snapshot, a delta, a position) need not
arrive, nor wait for what was lost before it. The commands' `delivery` sends
the next call in a `DeliveryMode` of its own over reliable UDP: `UNRELIABLE`,
or `sequenced(channel)`, which the other side drops when a newer one on its
channel has arrived first. Only the next call takes it, as with `within`, and
over a transport with one way to send (TCP, WebSocket, local IPC) it is
ignored. Such a call must fit one datagram, 1,200 bytes with its frame (less
in an encrypted session); a larger one throws, or for a request fails
`Unsent`. A request goes in the mode given and is answered reliably; one that
is lost is answered by nothing, so give it a deadline.

```haxe
// Given commands:ChatCommands.
import crossbyte.net.DeliveryMode;

commands.delivery(DeliveryMode.sequenced(0)).say("lobby", "where everyone is now");
```

A local IPC listener serves one peer at a time on its name, and takes the
next once that one has gone, so one session over it answers each in turn
(its hello is said again to each). Peers that must be served at once need a
name each.

```haxe
import crossbyte.ipc.LocalConnection;

function serveLocally(name:String, handler:ChatHandler):RPCSession<Dynamic> {
	var listener = new LocalConnection();
	listener.listen(name);
	return new RPCSession(NetConnection.fromLocalConnection(listener), null, handler);
}
```

## One handler, many clients

A handler can serve any number of sessions, and usually should: a server's
rooms, queues and world are one set of state, and the handler that answers
for them is one object. Each call is answered on the connection it came in
on. While a method runs, the handler's `session` is the session whose call
it is, so a method can tell its callers apart:

- `session.data` holds whatever the application keeps per client (a
  player, a login): a field of the session's, set when it is made or later;
- `session.commands` calls that client back, if the session has commands;
- `session.connection` is its connection.

A handler that calls its clients back names the kind of session it serves,
`RPCHandler<C, D>`, with the class of their commands and the type of their
`data`; its `session` is then typed, so `session.commands` calls the client
through its checked stubs and `session.data` is the application's own type.
A server keeps the sessions it calls, and drops each as its connection
closes:

```haxe
interface ListenerContract {
	function said(room:String, text:String):Void;
}

@:rpcContract(ListenerContract)
class ListenerCommands extends RPCCommands {
	public function new() {}
}

class RoomServer extends RPCHandler<ListenerCommands, String> implements ChatContract {
	final clients:Array<RPCSession<ListenerCommands, String>> = [];

	public function new() {}

	// Given to a NetHost as what it does with each connection it accepts.
	public function accept(connection:crossbyte.net.NetConnection):Void {
		final client = new RPCSession<ListenerCommands, String>(connection, new ListenerCommands(), this);
		client.data = "guest";
		clients.push(client);
		connection.onClose = _ -> clients.remove(client);
	}

	public function say(room:String, text:String):Void {
		// The caller's session, typed: the one this call came in on.
		for (client in clients) {
			if (client != session) {
				client.commands.said(room, '${session.data}: $text');
			}
		}
	}

	public function join(room:String):Int {
		return clients.length;
	}
}
```

A session whose commands are of another class refuses such a handler with
an `ArgumentError`, as it is given it. A handler that names no kind,
`extends RPCHandler`, serves sessions of any kind, and its `session` is an
`RPCSession<Dynamic, Dynamic>`, through which a call is not checked.

Each of those calls is framed for its own connection. A `NetHost` also
says which connection went, through its `onDisconnect`.

Between calls `session` is `null`. A method that answers later, with a
`Future` (below), is answered on its caller's connection whenever that
future completes; code that needs the caller after its method has returned
keeps `session` in a variable of its own.

A handler with state of its own per client, with nothing shared, can still be
made per session; it simply never sees another.

## One-way calls and requests

A method that returns `Void` is a *one-way* call: it is sent, and nothing
comes back, not even word that it failed. Any other return type makes a
*request*, and the stub returns an `RPCResponse<T>` that completes with the
answer or with an error message.

`RPCResponse<T>` is a `crossbyte.Future<T>`, so everything a future does, it
does:

```haxe
// Given commands:ChatCommands.
import crossbyte.rpc.RPCResponse;

var response = commands.join("lobby");

// A callback for each outcome...
response.then(count -> trace('joined, $count here'), message -> trace('failed: $message'));

// ...a transformed future...
response.map(count -> count > 10).then(crowded -> trace(crowded ? "busy room" : "quiet room"));

// ...or the events, for code that listens rather than chains.
response.addEventListener(RPCResponse.RESULT, _ -> trace('answered: ${response.result}'));
response.addEventListener(RPCResponse.ERROR, _ -> trace('failed: ${response.error}'));
```

Answers arrive on the thread that runs the connection's runtime, like every
other event of that connection.

### Calls that allocate nothing

Each request makes its `RPCResponse` (128 bytes natively, 80 on the JVM), and
an answer that is a number is boxed into it. For a call made every frame, each request method
has a twin ending in `Then`, which hands the answer to a *receiver* instead.
It makes nothing for the call, and an answer that is a number or a `Bool`
arrives unboxed, so the call and its answer allocate nothing at either end,
natively or on the JVM, an `Int64` included (on other targets an `Int64` is
an object). A `String` or an object answer allocates only itself.

A receiver implements the interface for the type of the answer:

```haxe
import crossbyte.rpc.RPCFailure;
import crossbyte.rpc.RPCIntReceiver;

class Lobby implements RPCIntReceiver {
	public function new() {}

	public function onInt(call:Int, count:Int):Void {
		trace('joined, $count here');
	}

	public function onFailure(call:Int, failure:RPCFailure):Void {
		switch (failure) {
			case TimedOut:
				trace("no answer in time");
			case Busy:
				trace("the server is busy; try again later");
			case Refused(message):
				trace('refused: $message');
			case _:
				trace('could not join: $failure');
		}
	}
}
```

```haxe
// Given commands:ChatCommands.
var lobby = new Lobby();
final call:Int = commands.joinThen("lobby", lobby);
```

| answer | receiver | told with |
|---|---|---|
| `Int`, `Int8`, `UInt8`, `Int16`, `UInt16`, `VarUInt`, `VarInt`, `UInt` | `RPCIntReceiver` | `onInt` |
| `Float`, `Float32` | `RPCFloatReceiver` | `onFloat` |
| `Bool` | `RPCBoolReceiver` | `onBool` |
| `String` | `RPCStringReceiver` | `onString` |
| `haxe.Int64` | `RPCInt64Receiver` | `onInt64` |
| anything else, and `Null<T>` of anything | `RPCValueReceiver<T>` | `onValue` |

An abstract over a number arrives as that number: an enum abstract over `Int`
through `onInt`. One object can receive the answers of every method that
answers with its type, and a class can implement several of these. The
`...Then` method returns the call's id, which the receiver is told with the
answer, so it can tell its calls apart.

Every call is told exactly once, through its answer or through `onFailure`,
which says why with an `RPCFailure`: `TimedOut` past its deadline (the
session's `requestTimeout`, or its own; see Deadlines), `Cancelled`, `Stopped`,
`Disconnected(reason)`, `Unsent(message)` for a call that could not go, or
`Unreadable(message)` for an answer this side could not read. When the other
side refused the call, the failure says what refused it:

| failure | the other side | its message |
|---|---|---|
| `Refused(message, code)` | its handler, with an `RPCError` | the error's, word for word; `code` its id, `null` for none |
| `UnknownMethod` | has no method for the call | `RPCError.UNKNOWN_METHOD_MESSAGE` |
| `UnreadableArguments` | could not read the call's arguments | `RPCError.UNREADABLE_MESSAGE` |
| `Busy` | had `maxCallsWaiting` calls waiting | `RPCError.BUSY_MESSAGE` |
| `NoHandler` | has nothing to answer calls | `RPCError.NO_HANDLER_MESSAGE` |
| `HandlerTimedOut` | its handler ran past `answerTimeout` | `RPCError.TIMEOUT_MESSAGE` |
| `HandlerFailed` | its handler threw something else | `RPCError.INTERNAL_MESSAGE` |
| `TooLarge` | could not take the call, or its answer, for its size | which limit (see "When a handler fails") |

What refused it decides the case, not the words: a handler that throws an
`RPCError` with the words of `RPCError.BUSY_MESSAGE` is `Refused`. A handler
refuses with one of these cases itself, as a gRPC handler answers with a
status code, through `RPCError.refusal`: thrown, returned from `beforeCall`, or
failing its future.

```haxe
class LimitedChatHandler extends ChatHandler {
	public var budget:Int = 100;

	public function new() {
		super();
	}

	override public function beforeCall(method:String, requestId:Int, payloadSize:Int):Null<RPCError> {
		// The caller is told Busy, its future's error "Slow down.".
		return budget-- > 0 ? null : RPCError.refusal(Busy, "Slow down.");
	}
}
```
 A
refusal the other side's session made is a single value, and allocates
nothing to be told. A call that cannot go at all (its connection
has ended, or it is over `maxFrameSize`) is told before its `...Then`
method returns. A receiver that throws is logged, and nothing else is
affected.

`session.cancelCall(call)` stops waiting for a call: its receiver is told
`Cancelled`, and its answer is dropped when it comes. It works for a future's
`requestId` too.

A call made with a future says why it failed the same way: its `failure` is
the `RPCFailure` a receiver would have been told, worked out as it is read
(`null` while it waits and once it has succeeded), so a caller can tell a
call that timed out from one that was refused, cancelled or cut off without
reading the words of its `error`:

```haxe
// Given commands:ChatCommands.
final joining = commands.join("lobby");
joining.catchError(_ -> switch (joining.failure) {
	case Disconnected(reason): trace('the server went: $reason');
	case UnknownMethod: trace('the server is of another version');
	case Refused(message): trace('refused: $message');
	case other: trace('failed: $other');
});
```

A handler that answers with a call the other side refused passes the
refusal on as it came: a hub whose backend was busy tells its own caller
`Busy`.

The receivers are interfaces rather than callbacks for a reason: natively a
function value passes its argument as an object, so an `Int->Void` callback
would box every answer it was given.

### What can be sent

Arguments and answers are encoded by type, with no field names or type tags
on the wire:

| Type | On the wire |
|---|---|
| `Int` | 4 bytes |
| `haxe.Int64` | 8 bytes, the low word first |
| `Float` | 8 bytes |
| `Bool` | 1 byte |
| `String` | a length, then UTF-8 |
| `haxe.io.Bytes` | a length, then the bytes |
| `crossbyte.rpc.Float32` (or `Single`) | 4 bytes, single precision |
| `crossbyte.rpc.Int8`, `UInt8` | 1 byte |
| `crossbyte.rpc.Int16`, `UInt16` | 2 bytes |
| `crossbyte.rpc.VarUInt`, `VarInt` | 1 to 5 bytes, a varint (`VarInt` zigzagged first) |
| `Array<T>`, `T` any of these | a count, then each element as its type is written |
| `Map<String, T>`, `Map<Int, T>` (or `StringMap<T>`, `IntMap<T>`), `T` any of these | a count, then each key and its value, in the keys' order |
| a class that implements `crossbyte.rpc.RPCStruct`, or an anonymous structure | its fields, one after another |
| an enum | its constructor's index, 1 byte (2 past 256 constructors), then that constructor's arguments |
| an abstract over any of these, such as `enum abstract Team(Int)` or `UInt` | as the type it abstracts |
| `RPCPatch<T>`, `RPCMapPatch<V>`, `RPCStringMapPatch<V>`, an argument or an answer | what changed since a base (see "Replicating state") |

An argument that may be absent (`?value:Int`, or `value:Null<Int>`) costs
one more byte to say whether it is there, whatever its kind (a compact number,
an array, a structure, an enum), and so does an element of an
`Array<Null<T>>`, a structure's field that may be absent and an enum
constructor's optional argument. An absent value is that byte alone. One that may not cannot be null: a call with a null
`String`, `Bytes` or array there, or inside an array, throws an
`ArgumentError` before anything is sent, and a handler answering null where
its type is not `Null<T>` fails the call as a throw does. A return type is
any of these, or `Void`. Anything else fails the build, naming the method.

Arrays nest (`Array<Array<Int>>` is a count of counts), and an array
arriving is the handler's to keep: each call's is made for it. Its count is
the sender's to choose, so it is checked against what is left of the frame,
at the least each element takes, before anything is made for it: a frame of
twenty bytes cannot ask for an array of two billion, and is answered as one
whose arguments could not be read.

```haxe
interface BoardContract {
	function mark(cells:Array<Int>, labels:Array<Null<String>>):Void;
	function rows():Array<Array<Int>>;
}
```

A map's entries go in the order of their keys, so one map is the same bytes
however it was built and whichever target wrote it: `Int` keys ascending,
`String` keys by their UTF-16 code units, as JSON's canonical form (RFC 8785)
orders names and as Haxe compares strings natively on the jvm and on
JavaScript, on every target. Its count is checked as an array's is, before
a map is made, and a reader takes entries in any order, a key given twice keeping its last
value, as protobuf's maps do. Keys are `String` or `Int`; any other key type
fails the build. Values are written straight from the map and read straight
into one made for the call, so natively a map of numbers or strings boxes
nothing for them; the writer copies the keys to sort them, one array a map.

```haxe
interface RealmContract {
	function label(realm:Int, labels:Map<String, String>):Void;
	function population():Map<Int, Int>;
}
```

An `Int` is always four bytes and a `Float` eight. Where a value needs less, a
signature says so with a compact type: `Float32` for a position or a speed,
seven significant digits; `UInt8` for a level, a set of flags; `Int16` for a
small signed delta; `UInt16` for a count; `VarUInt` for a tick, an
acknowledgement or an input sequence, numbers that grow without bound but stay
small for a long time (one byte to 127, two to 16,383, three to 2,097,151, five
at most, as protobuf's `uint32`), and `VarInt` for a signed one (zigzagged
first, as `sint32`: -64 to 63 in a byte). Each is an `Int` (or a `Float`)
wherever one is wanted, so arithmetic on them is `Int` arithmetic, and
comparisons compare the `Int` it holds. An `Int` assigned to one keeps its low
bits, as a cast to a byte or a short does in C (`var level:UInt8 = 300` holds
44), so what a value holds is what is sent and what arrives. A `Float32` is
Haxe's own `Single` where the target has one (natively, the jvm, HashLink),
rounded as it is assigned; on JavaScript, the interpreter and neko it is a
`Float`, rounded as it is sent. A contract may declare `Single` itself, and
builds then only for those targets.

```haxe
import crossbyte.rpc.Float32;
import crossbyte.rpc.Int16;
import crossbyte.rpc.UInt8;

interface MoveContract {
	// 4 + 4 + 2 + 1 bytes, where Floats and Ints would take 8 + 8 + 4 + 4.
	function move(x:Float32, y:Float32, turn:Int16, flags:UInt8):Void;
}
```

### Structures

A value with fields is a class that implements `RPCStruct`, or an anonymous
structure, named by a typedef or written out. Its reader and writer are
generated at compile time, once for each, with no reflection:

```haxe
import crossbyte.rpc.Float32;
import crossbyte.rpc.RPCStruct;
import crossbyte.rpc.UInt16;
import crossbyte.rpc.UInt8;

class Vec3 implements RPCStruct {
	public var x:Float32 = 0;
	public var y:Float32 = 0;
	public var z:Float32 = 0;

	public function new() {}
}

typedef Slot = {
	var item:Int;
	var count:UInt16;
}

class PlayerState implements RPCStruct {
	public var id:Int = 0;
	public var position:Vec3 = new Vec3();
	public var velocity:Vec3 = new Vec3();
	public var flags:UInt8 = 0;
	public var name:String = "";
	public var inventory:Array<Slot> = [];
	@:rpcSkip public var lastSeen:Float = 0; // not sent

	public function new() {}
}

interface WorldContract {
	function update(state:PlayerState):Void;
	function slots(id:Int):Array<Slot>;
}
```

On the wire a structure is its fields' values one after another, with no names,
tags or lengths and no byte for a field that cannot be absent, and one inside
another is read and written through the same frame, so nothing is made for it
but the value itself. The fields go in the order of their names, so moving a
declaration changes nothing; `@:field(n)` pins a field ahead of the named ones,
in the order of n (0 to 65535), as the `hxwire` library orders its fields. A
field that may be absent (`Null<T>`, or `@:optional` in a typedef) has a
byte before it saying whether it is there.

A class's fields are every `var` it and the classes it extends declare, private
ones included, except those marked `@:rpcSkip`. One that RPC does not carry, a
`final` field or a property fails the build, naming it, unless it is marked so.
A class is read by calling its constructor with no arguments, then setting each
field, so it needs one that takes none; and it must be public, since its reader
lives in a module of its own. An anonymous structure is read into locals and
made as an object literal. Neither may contain itself, directly or through
another: the build says so, and a tree is sent as a list of nodes.

A null where a structure has to be, or inside one, throws an `ArgumentError`
before anything is sent, as a null `String` does.

**Prefer a class for hot calls.** Natively a field of an anonymous structure is
read through a lookup by name, and a number in one is boxed. Measured natively
on a one-way call carrying `{id:Int, x:Float32, y:Float32, z:Float32,
flags:UInt8}`: as a class 50 ns and 40 bytes allocated (the object), as a
typedef 74 ns and 232 bytes; an array of eight, 106 ns and 456 bytes against
241 ns and 1,992. A class of numbers only is also written and read as one run
of bytes, and an array of them as one run, as an array of `Int`s is. A typedef
reads best where the structure is small or the call is not hot, and on
JavaScript, where both are plain objects.

A structure's layout (each field's pinned id, name and kind, in order) is
part of the op of every method that carries it, so renaming, retyping, adding,
removing or making absent a field changes the op, and a peer built from the
other version answers as for a method it does not have. Its name is not: a
class and a typedef with the same fields are one layout, and the two ends of a
call can use one each.

**Against packing by hand.** The `PlayerState` above, with eight inventory
slots, sent one-way and read into a `PlayerState` on the other side, both ends
counted: natively 130 ns and 592 bytes allocated, against 274 ns and
1,704 bytes when the same values are packed into a `Bytes` by hand, sent as a
`Bytes` argument and unpacked by hand, 105 ns of which is the packing alone;
on the jvm 189-205 ns and 544 bytes against 261-289 ns and 920. The frame is
99 bytes, against 102. With `Slot` a class rather than a typedef, as above,
natively; as a typedef the call is 181 ns and 1,296 bytes.

**With hxwire.** A class can implement both `hxwire.WireObject` and
`RPCStruct`: hxwire keeps its JSON and binary for storage, and RPC generates
its own writer and reader, which stream into the frame where hxwire's would
make a `Bytes` of their own. RPC reads `@:field(n)` and orders fields as
hxwire does, so for fields both carry and that cannot be absent (`Int`,
`Float`, `Bool`, `String`, `Bytes`, arrays of them, nested structures), the
call's arguments are byte for byte what hxwire's `toBinary()` makes. (A field
that may be absent differs: hxwire's byte says it is null, RPC's that it is
there.) Fields hxwire leaves alone, RPC has to be told to: mark them
`@:rpcSkip`. CrossByte does not depend on hxwire.

### Enums

A simple enum is its constructor's index: one byte, or two for an enum of more
than 256 constructors. An enum with arguments is the same index followed by
that constructor's arguments, each as its type is written (a tagged union, as
Rust's enums and protobuf's `oneof` are), so a message that is one of several
shapes is one argument rather than several methods or a hand-packed `Bytes`:

```haxe
import crossbyte.rpc.Float32;

enum Command {
	Stop;
	Walk(x:Float32, y:Float32);
	Say(text:String, ?to:Int);
}

interface CommandContract {
	function order(unit:Int, command:Command):Void;
}
```

`Walk(1, 2)` is 9 bytes: the index and two `Float32`s. An index past the
constructors makes a call that cannot be read, answered so. An enum's
constructors, in order, with their arguments' kinds, are part of the op, so
adding, removing, renaming or reordering a constructor changes it; renaming a
constructor's argument does not. An enum with type parameters, a private one,
and one that contains itself fail the build; so does an argument of a type RPC
does not carry.

Because nothing on the wire names a field, the two ends must agree on each
method exactly: its name, its arguments in order, and their types. Build both
from one contract and they do. If they do not (a client and a server built
from two versions of a method), the call finds no method, rather than one end
reading the other's bytes as its own; see "What names a call", below.

## Replicating state

A game server sends each player, every tick, the part of the world that player
sees: their own ship in full, the ships near them, what is flying. Most of it
is what the player already has. The compiled lane sends what changed since a
state both ends hold, typed and generated as the rest of it is:

- `RPCPatch<T>`: a structure as the fields that differ from a base.
- `RPCMapPatch<V>` (and `RPCStringMapPatch<V>`): a map of ids to structures as
  the keys removed, the entries added, and patches of those whose values
  differ.
- `@:quantize`, `@:range` and `@:rpcBits`: fields in as few bits as they need.
- `@:reuse`: an argument read into what the session keeps, so a call of
  structures allocates nothing.

The base is explicit: the sender names the state it diffs against, and the
receiver applies the patch to that state. Over a reliable connection that is
what was last sent; over reliable UDP's `sequenced` or `UNRELIABLE` delivery it
is the tick the client last acknowledged, as Quake 3 and Source do it, and a
lost datagram costs nothing but the next patch being against an older base.

### A structure as what changed

```haxe
import crossbyte.rpc.RPCMapPatch;
import crossbyte.rpc.RPCPatch;
import crossbyte.rpc.RPCStruct;
import crossbyte.rpc.UInt16;
import crossbyte.rpc.UInt8;
import crossbyte.rpc.VarUInt;

class OwnShip implements RPCStruct {
	public var lastSeq:VarUInt = 0; // the last input the server applied
	public var x:Float = 0;
	public var y:Float = 0;
	public var vx:Float = 0;
	public var vy:Float = 0;
	public var energy:Float = 0;
	public var aimSteps:UInt16 = 0;
	public var controls:UInt8 = 0;
	public var engineLocked:Bool = false;

	public function new() {}
}
```

A patch carries a bit for each field (whether it changed), then each that did,
whole: a `Float` eight bytes, a `UInt16` two. Values are absolute, never
differences, so a patch applied to the right base is exactly the sender's
value, whatever was lost before it. A nested structure is patched field by
field against the base's; an array, a map, a `String` or an enum goes whole
when it differs. Fields are compared as they go: a `Float32` at single
precision, NaN equal to NaN.

`diff(base, current)` works the patch out and answers it, to pass as the
argument. A `null` base sends the patch from the structure as its constructor
makes it (`isFull`), which applies to anything: what a joining client, or one
whose base has aged out, is sent. The received patch is the session's, reused
for every call, and valid only during the call; `apply(base, into)` makes the
sender's value:

```haxe
import crossbyte.ds.SequenceRing;
import crossbyte.rpc.RPCCodecs;

interface MatchContract {
	function own(tick:VarUInt, base:VarUInt, ship:RPCPatch<OwnShip>):Void;
}

@:rpcContract(MatchContract)
class MatchCommands extends RPCCommands {
	public function new() {}
}

class MatchClient extends RPCHandler implements MatchContract {
	// What was applied, by tick, for the patches to come.
	final frames = new SequenceRing<OwnShip>(32);

	public function new() {}

	public function own(tick:VarUInt, base:VarUInt, ship:RPCPatch<OwnShip>):Void {
		final from:Null<OwnShip> = ship.isFull ? null : frames.get(base);
		if (from == null && !ship.isFull) {
			return; // its base has aged out here: keep acknowledging, and the server sends a full one
		}
		final slot:Null<OwnShip> = frames.get((tick : Int) - frames.capacity);
		frames.put(tick, ship.apply(from, slot != null ? slot : new OwnShip()));
	}
}
```

```haxe
// Given commands:MatchCommands, sent:SequenceRing<OwnShip>, patch:RPCPatch<OwnShip>, ship:OwnShip, tick:Int, acked:Int.
// Per observer per tick: against what the client acknowledged, or a full one.
commands.delivery(crossbyte.net.DeliveryMode.sequenced(0)).own(tick, acked, patch.diff(sent.get(acked), ship));
final kept:Null<OwnShip> = sent.get(tick - sent.capacity);
sent.put(tick, RPCCodecs.of(OwnShip).copy(ship, kept != null ? kept : new OwnShip()));
```

Writing allocates nothing (the patch holds the two values until it is sent),
and neither does reading once the session has made its patch. A structure of
up to 64 fields can be patched.

### Keyed maps

A map of ids to structures goes as a map patch. Its keys go in three groups,
each ascending: the first a zigzag varint and each next the distance from the
one before, so ids that sit close together take a byte each, where an `Int` is
four. An entry both ends hold whose value is the same bytes is not sent, so a
value that never changes once made (a projectile) is only ever added and
removed.

```haxe
import crossbyte.ds.IdList;
import haxe.ds.IntMap;

class RemoteShip implements RPCStruct {
	public var x:Float32 = 0;
	public var y:Float32 = 0;
	public var aimSteps:UInt16 = 0;

	public function new() {}
}

interface ViewContract {
	function ships(tick:VarUInt, base:VarUInt, ships:RPCMapPatch<RemoteShip>):Void;
}

@:rpcContract(ViewContract)
class ViewCommands extends RPCCommands {
	public function new() {}
}
```

`diffKeys(baseValues, baseKeys, currentValues, currentKeys)` diffs views of
shared frames: one map of the world's values per tick, shared by every
observer, and an `IdList` of the ids each observer sees, in any order (grid
order is fine). Nothing is copied per observer, and nothing is allocated once
the patch's lists have grown:

```haxe
// Given commands:ViewCommands, patch:RPCMapPatch<RemoteShip>, world:IntMap<RemoteShip>, before:IntMap<RemoteShip>, seen:IdList, seeing:IdList, tick:Int, acked:Int.
commands.ships(tick, acked, patch.diffKeys(before, seen, world, seeing));
```

The client keeps its frames as a map and its keys, and `applyKeys` makes the
new frame from the one the patch names. A value already in the new frame
under a key is patched in place, and with `recycle` the values it drops serve
the next keys it gains, so a ring of frames allocates nothing once warm
(natively an `IntMap` makes a node for a key it did not hold, 56 bytes):

```haxe
// Given ships:RPCMapPatch<RemoteShip>, from:IntMap<RemoteShip>, fromKeys:IdList, into:IntMap<RemoteShip>, intoKeys:IdList.
ships.applyKeys(from, fromKeys, into, intoKeys, true);
```

`apply(base, into, recycle)` does the same for maps alone, and finds their keys
by iterating them, which allocates an iterator natively and on the jvm; into
the base itself it iterates nothing. One by one, `removed`, `addedKey(i)` and
`addedValue(i)`, `updatedKey(i)` and `applyUpdate(i, target)` give what
arrived. A base that lacks a key the patch removes or updates is refused,
naming the key: it is not the one the sender used. `sizeBound()` bounds a
patch's bytes, for a call that must fit one datagram.

### Within a budget

A view can hold more than a datagram carries, or more than an observer's
share of a server's bandwidth. `diffKeysWithin` takes the view in the
caller's order of priority (nearest first, say) and carries entries while
the patch stays within a given size. From the first that does not fit on,
the rest wait, as Unreal's replication fills a connection in priority order
and stops where it is saturated, so an entry never goes ahead of one ranked
higher. `deferred` lists those waiting, in order, and `isPartial` says
there are some. The patch only follows the order; working it out
(distance, relevance, how long an entry has waited) is the caller's.

Removals always go, counted first. They are a byte or two each, and one
left out would leave the observer showing something that is gone.

What the observer holds is then no longer the view, so the base is not a
list of keys but an `RPCMapBaseline`: the keys it holds, and for each whose
update was left out, a copy of the older value it still has. The diff
reads the baseline the observer acknowledged and writes the one it sends,
to be filed under the tick, so the record of what was sent is always what
was sent. An entry left out is owed until a patch carries it, however many
ticks that takes; one carried is not sent again until it changes. The rest
of what a baseline holds is read from the frame of values it was made
against, so the world's frames are kept at least as long as the
baselines:

```haxe
import crossbyte.rpc.RPCMapBaseline;

class Viewer {
	// What it was sent, by tick, and the tick its client last acknowledged.
	public final sent = new SequenceRing<RPCMapBaseline<RemoteShip>>(32);
	public final patch = new RPCMapPatch(RPCCodecs.of(RemoteShip));
	public var acked:Int = -1;

	public function new() {}
}
```

```haxe
// Given commands:ViewCommands, viewer:Viewer, frames:SequenceRing<IntMap<RemoteShip>>, nearestFirst:IdList, tick:Int.
// Against what the client acknowledged, or nothing once that has aged out.
final base:Null<RPCMapBaseline<RemoteShip>> = viewer.sent.get(viewer.acked);
final kept:Null<RPCMapBaseline<RemoteShip>> = viewer.sent.get(tick - viewer.sent.capacity); // about to age out: reused
final sent:RPCMapBaseline<RemoteShip> = kept != null ? kept : new RPCMapBaseline();
viewer.patch.diffKeysWithin(base == null ? null : frames.get(viewer.acked), base, frames.get(tick), nearestFirst, 1000, sent);
commands.delivery(crossbyte.net.DeliveryMode.sequenced(0)).ships(tick, viewer.acked, viewer.patch);
viewer.sent.put(tick, sent);
```

Over a reliable connection the base is always the last patch sent, so one
baseline does, written over itself, beside the frame before this one:

```haxe
// Given commands:ViewCommands, patch:RPCMapPatch<RemoteShip>, held:RPCMapBaseline<RemoteShip>, before:Null<IntMap<RemoteShip>>, world:IntMap<RemoteShip>, nearestFirst:IdList, tick:Int.
commands.ships(tick, tick - 1, patch.diffKeysWithin(before, before == null ? null : held, world, nearestFirst, 4000, held));
```

The client applies the patch as any other: what arrives is a smaller
patch, and its frame comes out as the baseline says. A far entry that
always loses to nearer ones waits forever unless its priority counts how
long it has waited, as Unreal's starvation does: each key in `deferred`
waited a tick more, and those carried (`addedKey`, `updatedKey`) none.

A budget that fits everything (known from the values' largest patch) writes
the bytes `diffKeys` writes and measures nothing. One that binds weighs the
entries up to the first that does not fit exactly, its key as its group
codes it and its patch by writing it, so the patch is never over the budget
and stops only at an entry that would pass it: one more write of each entry
carried. Neither allocates once its lists and the baselines' values have
grown. `RPCStringMapPatch` has the same, with `RPCStringMapBaseline`.

### Fewer bits

A structure marked `@:rpcBits`, or with a field marked `@:quantize` or
`@:range`, is in the *bit layout*: those fields, its `Bool`s, and whether each
field that may be absent is there, a bit each, go in a bit section before its
other fields.

```haxe
class BoltRules {
	public static inline final LIFETIME:Float = 4.2;
}

@:rpcBits
class Bolt implements RPCStruct {
	@:quantize(0, BoltRules.LIFETIME, 8) public var age:Float = 0;
	@:range(0, 1023) public var owner:Int = 0;
	@:quantize(-8192, 8192, 16) public var x:Float = 0;
	@:quantize(-8192, 8192, 16) public var y:Float = 0;
	public var piercing:Bool = false;

	public function new() {}
}
```

`@:quantize(min, max, bits)` sends a `Float` or `Float32` as one of 2^bits
evenly spaced points from `min` to `max`, both ends included: what arrives is
within half a step, and a value outside the range is clamped to it, as
`BitWriter.writeQuantized` does (a NaN is refused). `@:range(min, max)` sends an
integer in the bits its range needs, and refuses one outside it. The bounds are
number literals or static inline constants of a class, as above, and `+`, `-`,
`*`, `/` of those. Patches compare a quantized field by its step, so jitter
below one sends nothing. The bits are laid out as `BitWriter` lays them (the
first bit the lowest of the first byte), so a structure's bit section reads
back with a `BitReader`.

An array of a class whose fields are all bits is one run of bits, padded once,
where each element alone would pad its own: Stellar's last four inputs, 22
bits each, are 11 bytes.

### Arguments the session keeps

An argument marked `@:reuse` is read into one instance the session keeps, the
same each call and valid only during the call: a structure's fields set in
place, its nested structures and arrays too, an array's element instances
kept, a map cleared and refilled. On a handler's argument, on the handler class
(every structure, array and map argument it reads), or on a contract method,
naming its arguments (a typed interface keeps no argument metadata):

```haxe
@:rpcBits
class TurnInput implements RPCStruct {
	@:range(0, 63) public var controls:Int = 0;
	@:range(0, 65535) public var aimSteps:Int = 0;

	public function new() {}
}

interface InputContract {
	@:reuse(recent) function inputs(ack:VarUInt, newest:VarUInt, recent:Array<TurnInput>):Void;
}
```

Nothing changes on the wire. A handler that keeps such an argument past its
call keeps what the next call overwrites: copy what is kept
(`RPCCodecs.of(TurnInput).copy`). A call that arrives while another of the
session's is running (over a connection that delivers at once) reads into
instances of its own. Built with `-D crossbyte_check_events`, a
session sets what it kept to garbage when the call returns (numbers 0xDBDBDBDB,
floats NaN, strings a marker), so a handler that keeps one shows it at once;
`-D crossbyte_fresh_events` reads each call's afresh. Patches are always read
this way.

### From code that does not name the types

A replication layer that knows nothing of the game's types holds an
`RPCCodec<T>`, which the game hands it: `RPCCodecs.of(OwnShip)`. It makes,
copies and compares values, and writes and reads them and their patches as
bytes of their own. One value per observer, sent as patches against what that
observer acknowledged:

```haxe
import crossbyte.rpc.RPCCodec;

class Replicated<T> {
	final codec:RPCCodec<T>;
	final sent:SequenceRing<T>;
	final patch:RPCPatch<T>;

	public function new(codec:RPCCodec<T>, window:Int) {
		this.codec = codec;
		sent = new SequenceRing(window);
		patch = new RPCPatch(codec);
	}

	public function next(tick:Int, acked:Int, current:T):RPCPatch<T> {
		patch.diff(sent.get(acked), current); // aged out or never acknowledged: a full patch
		final slot:Null<T> = sent.get(tick - sent.capacity); // about to age out: reused
		sent.put(tick, codec.copy(current, slot != null ? slot : codec.make()));
		return patch;
	}
}
```

`RPCPatch.write(out)` and `read(input)`, and the same on map patches, give a
patch as bytes of its own: for a test, a recording, a resync frame kept for
later, or a patch carried in a `Bytes` argument. `codec.layout` is the hash of
a structure's layout, to keep beside a stored baseline. A contract carrying a
structure never goes through the interface, so a typed call pays no virtual
call.

### What it costs

Stellar's hot messages, driven by its simulation with bots (17 ships, each the
observer of the other 16, patched against the tick acknowledged two before),
per observer message (see [performance.md](performance.md#replication-beside-yggdrasils-codec-and-protobuf)):

| | bytes | made, natively | read, natively | allocated |
|---|---|---|---|---|
| typed patches, today's field types | 437 | 0.82 us | 0.82 us | 0 |
| typed patches, quantized | 276 | 1.21 us | 1.01 us | 0 |
| Yggdrasil's codec today | 546 | 5.6 us | 6.3 us | 18.8 KB (JVM) |
| protobuf (grpc-go's runtime, codec alone) | 613 | 3.7 us | 3.5 us | 7.3 KB |

On the design's tick (the own ship and 16 others with 3 of their 8 fields
changed) the quantized message is 216 bytes on the wire, against 557 through
Yggdrasil's codec and 423 through protobuf on a gRPC stream.

## Contracts or `@:rpc` methods

A contract is the usual way: one interface, shared by the side that calls and
the side that answers, so neither can drift from the other. Without one,
declare each call on each side with `@:rpc`:

```haxe
class ScoreCommands extends RPCCommands {
	public function new() {}

	@:rpc public function submit(player:String, score:Int):Void {}

	@:rpc public function best(player:String):RPCResponse<Int> {}
}

class ScoreHandler extends RPCHandler {
	var scores = new Map<String, Int>();

	public function new() {}

	@:rpc public function submit(player:String, score:Int):Void {
		if (!scores.exists(player) || scores.get(player) < score) {
			scores.set(player, score);
		}
	}

	@:rpc public function best(player:String):Int {
		return scores.exists(player) ? scores.get(player) : 0;
	}
}
```

The stubs' bodies are left empty: the build writes them. On the commands side
a request returns `RPCResponse<T>` explicitly; on the handler side it returns
`T`. A handler's `@:rpc` method has to declare its return type, since its
answer is encoded as that type; one that returns a value without declaring it
fails the build rather than quietly answering nothing.

Two names are the protocol's own and cannot be RPC methods: `ping`, which
every session answers and uses for heartbeats, and `dispatch`. Neither can
`beforeCall` or `afterCall`, below, nor `session`, the handler's view of who
is calling.

## When a handler fails

A handler method that throws answers its call with an error, and the
connection carries on. What the caller is told depends on what was thrown.

Throw an `RPCError` for a failure the caller should see. Its message is the
answer, word for word:

```haxe
import crossbyte.rpc.RPCError;

class RoomHandler extends RPCHandler {
	public function new() {}

	@:rpc public function enter(room:String):Int {
		if (room.length == 0) {
			throw new RPCError("A room needs a name.");
		}
		return 1;
	}
}
```

The caller's `RPCResponse` then fails with `"A room needs a name."`, and its
`failure` is `Refused("A room needs a name.")`. An `RPCError` given an id
carries it across as a code, so a caller can switch on it rather than on the
words: `throw new RPCError("No such room.", 3)` arrives as
`Refused("No such room.", 3)`, and the `RPCError` the caller's future fails
with has 3 as its `errorId`. An id of 0, the default, is no code.

```haxe
// Given commands:ChatCommands.
final entering = commands.join("attic");
entering.catchError(_ -> switch (entering.failure) {
	case Refused(_, 3): trace("there is no such room");
	case Refused(message, _): trace('refused: $message');
	case other: trace('failed: $other');
});
```

Anything
else a handler throws (a database error, a bug) is the handler failing, and the
caller is told only `RPCError.INTERNAL_MESSAGE` (its `failure` is
`HandlerFailed`), so a
stack trace or a file path never crosses to whoever made the call. The error
itself goes to the session's `onHandlerError`, which logs it unless you
replace it. It arrives as a `haxe.Exception`: what was thrown, if it was one,
and otherwise a `haxe.ValueException` holding what was thrown in its `value`,
with the stack in its `stack`:

```haxe
// Given session:RPCSession<ChatCommands>.
session.onHandlerError = (op, method, error) -> {
	trace('handler ${method != null ? method : "for op " + op} failed: $error');
};
```

A one-way call has nobody to answer, so whatever it throws, `RPCError` or not,
goes to `onHandlerError`.

A null access is a throw on the JVM, Node, the interpreter, HashLink and neko,
but natively it is not: a native build reads through the null and the process
stops, unless it was built with `-D HXCPP_CHECK_POINTER`, which makes it a
throw like any other at some cost to every field access. A native handler
checks for null itself.

A call this side cannot take is answered or passed over, and the connection
carries on. A request for a method its handler has not got (from a peer
built from another version of the contract, or one calling a method added
since, as in a rolling deploy) is answered `RPCError.UNKNOWN_METHOD_MESSAGE`,
and one whose arguments do not read (they run past the end of their frame,
or name more than it holds) is answered `RPCError.UNREADABLE_MESSAGE`; a one-way call of
either kind is dropped. An answer that does not read fails the call it
answers, and a frame of a kind the session does not know is passed over. Every
frame carries its length, so the next is read where it begins. The session's
`onUnreadableFrame` is told of each, and does nothing unless set; a server can
count them, and close a peer that sends too many:

```haxe
// Given session:RPCSession<ChatCommands>.
var unreadable = 0;
session.onUnreadableFrame = (op, requestId, reason) -> {
	trace('passed over a frame for op $op: $reason');
	if (++unreadable > 100) {
		session.close();
	}
};
```

A frame larger than this side takes (over its `maxFrameSize`, 8 MiB unless
set, or more than its connection holds to read whole, a TCP socket's
`maxInputBufferSize`, 16 MiB unless set) is refused as its head arrives and
read past as the rest does, and the connection carries on: a request is
answered `TooLarge`, with a message naming the limit; the call an answer was
for fails `TooLarge`; a one-way call is dropped; and `onUnreadableFrame` is
told. What does end a connection is a frame whose length cannot be trusted:
shorter than any frame, or one too large whose head is neither a call nor an
answer. Nothing after it would line up, so the session closes the
connection, and every call still waiting on it fails.

A frame too long is caught before it is sent as well: a request over the
sending session's `maxFrameSize` fails at once with an `ArgumentError` as its
`cause` (`Unsent`), a one-way call throws one, and an answer too long is not
sent: its caller is answered `TooLarge`, and `onHandlerError` is told. Both
ends of a connection should agree on the limit.

A server that should take only small calls, but sends large answers or
snapshots of its own, limits the two ways apart: `maxInboundFrameSize`
limits what arrives, and `maxFrameSize` then only what goes out. Until it is
set it reads as `maxFrameSize`, so a session that sets neither, or only
`maxFrameSize`, limits both ways alike.

```haxe
// Given session:RPCSession<ChatCommands>.
session.maxInboundFrameSize = 64 * 1024;
```

A frame has to fit its transport too. Over a WebSocket a large frame goes as
messages of 64 KiB, which the other side reads as one stream, so its peer's
`maxMessageSize` (1 MiB unless set) is no limit on it as long as it is 64 KiB
or more. Over reliable UDP a call larger than what the session may hold for
its window (`maxOutputBufferSize`, 256 KiB unless set) fails as it is made
(`Unsent`), and so does one over local IPC larger than its 8 MiB message,
where either would have ended the connection or gone nowhere; an answer that
large goes in pieces over reliable UDP (see "Large answers"), and over local
IPC its caller is answered `TooLarge`.

A request to a session with no handler to answer it (one with only commands,
calling out) is answered `RPCError.NO_HANDLER_MESSAGE`, and a one-way call to
one is dropped.

## Hooks: one place for every call

A handler can decide on each call before it runs, and see how each one went,
without touching every method. Override `beforeCall` to authorize, rate limit
or refuse, and `afterCall` to measure or audit:

```haxe
class GuardedChatHandler extends ChatHandler {
	public var callsLeft:Int = 1000;
	public var failures:Int = 0;

	public function new() {
		super();
	}

	override public function beforeCall(method:String, requestId:Int, payloadSize:Int):Null<RPCError> {
		if (payloadSize > 4096) {
			return new RPCError("Too large.");
		}
		if (callsLeft-- <= 0) {
			return new RPCError("Slow down.");
		}
		return null;
	}

	override public function afterCall(method:String, requestId:Int, error:Null<haxe.Exception>):Void {
		if (error != null) {
			failures++;
		}
	}
}
```

`beforeCall` runs before the call's arguments are read, with the method's
name, the request's id (0 for a one-way call) and the bytes the arguments
take, so refusing an oversized call costs nothing. Return `null` to let the
call run, or an `RPCError` to refuse it: a request is answered with its
message, and a one-way call is dropped. Refusing by returning rather than
throwing keeps a flood of refusals from costing an exception each.
`afterCall` runs once the method has run and its answer has been sent; `error`
is what it threw, as a `haxe.Exception` (wrapped in one when it was not one),
or `null`. It is not given the result, which would mean boxing every `Int`
a handler returns.

The calls to the hooks are generated only into a handler that overrides them,
or whose ancestor does. A handler that overrides neither pays nothing for
them, and one that does pays a call each. What a hook throws counts as the
call failing, and is reported to `onHandlerError`.

For a limit on how often a method is called, or on the size of its
arguments, `@:rpcLimit` (below) does it without a hook. Who may call at all
(signed in, with the roles and scopes a method asks for) is the
application's, in `beforeCall`.

## Limits per method

A method can say how often each client may call it and how large its
arguments may be, and every call over either is refused before it runs.
`@:rpcLimit` on the handler's method says so:

```haxe
import crossbyte.net.RateLimiter;

class MeteredChatHandler extends RPCHandler implements ChatContract {
	// Every session this handler serves shares it: a client's calls from all
	// of its connections, counted together.
	public var perClient:RateLimiter = new RateLimiter(50, 1.0);

	public function new() {}

	// Each client: ten messages a second, none over 2 KiB, and fifty a second
	// from its address however many connections it opens.
	@:rpcLimit(calls = 10, seconds = 1, bytes = 2048, byAddress = perClient)
	public function say(room:String, text:String):Void {}

	public function join(room:String):Int {
		return 1;
	}
}
```

- `calls` in `seconds` (1 unless given) is a token bucket for each session,
  as `RateLimiter` keeps one for each key: `calls` at once, refilling at
  `calls / seconds` a second. A call over it is refused `RPCFailure.Busy`, its
  message `RPCError.RATE_LIMITED_MESSAGE`: worth trying again later.
- `bytes` is the most its arguments may take, counted as `beforeCall`'s
  `payloadSize` counts them. A call over it is refused `RPCFailure.TooLarge`,
  its message `RPCError.TOO_LARGE_MESSAGE`, before a byte of the arguments is
  read.
- `byAddress` names a field of the handler holding a `RateLimiter`, and each
  call spends a token from that limiter's bucket for the session's remote
  address too (keyed by `RateLimiter.addressKey`, so an IPv6 client by its
  /64): a client opening more connections does not get more calls. The
  limiter's own numbers are the address's limit, and methods naming one
  limiter share its budget. The field is read as each call arrives, so it can
  be set after the handler is made, shared by the handlers of every session
  when each has its own, or `null` for none. A `RateLimiter` is used from one
  thread: a server spread over runtimes gives each runtime its own.

A request refused is answered so, and a one-way call refused is dropped.
Neither is told to `onHandlerError`, and neither reaches `beforeCall` or
`afterCall`: the limits come first, the size before the rate, so a call
refused for its size spends none of its rate, and one its address refuses
spends none of its session's.

The values are numbers, or static inline constants (the handler's own, as
`BURST`, or another class's, as `ChatRules.BURST`) and `+ - * /` of them, as
`@:quantize`'s bounds are, fixed when the handler is built. A limit read from
configuration as the server starts is a `RateLimiter` made from it, given
through `byAddress`, or checked in `beforeCall`. Who is calling (signed in,
with which roles) is the application's, in `beforeCall`, which runs once a
call is within its limits.

It goes on the handler's method, not the contract's or a commands class's: a
contract is what both sides share, a commands class only makes calls, and the
build refuses a limit on either. The runtime lane has no methods to mark; its
`beforeRuntimeCall` can ask a `RateLimiter` of the application's for each op.

On a handler class, `@:rpcLimit` is the limit of each method it answers that
has none of its own, inherited ones included, each with a bucket of its own.
A method's own replaces it whole, and `@:rpcLimit()` takes a method out of
it. A handler extending another answers the other's methods with their
limits:

```haxe
@:rpcLimit(calls = 20)
class CrowdedChatHandler extends ChatHandler {
	public function new() {
		super();
	}

	// Twenty calls a second to each method, but one join every ten seconds.
	@:rpcLimit(calls = 1, seconds = 10)
	override public function join(room:String):Int {
		return super.join(room);
	}
}
```

The buckets run on the runtime's clock, as deadlines do (see Deadlines,
below), and are made with a session's first limited call; a connection that
takes another peer (a `LocalConnection` listening again) starts its new peer
with full ones. A handler with no `@:rpcLimit` is built as it always was, and
pays nothing for them. A limited call allocates nothing, and pays a
comparison for its size and, for a rate, a look at the clock and its bucket:
in the RPC bench a one-way call from a stub to its handler takes 38 ns
natively and 45 with a rate limit and a size cap (19 and 25 on the jvm), and
75 limited by address as well (54 on the jvm), most of that the limiter's
clock and its look-up of the address.

## Answering later

A handler method can return `Future<T>` instead of `T`, and its caller is
answered once the future completes. It is for an answer that depends on
something slow: another service, a query, a queue that has not filled. A hub
that asks an instance host for a match answers its client with what the host
says:

```haxe
import crossbyte.Future;

class InstanceCommands extends RPCCommands {
	public function new() {}

	@:rpc public function allocate(region:String):RPCResponse<Int> {}
}

class HubHandler extends RPCHandler {
	final instances:InstanceCommands;

	public function new(instances:InstanceCommands) {
		this.instances = instances;
	}

	@:rpc public function joinMatch(region:String):Future<Int> {
		return instances.allocate(region);
	}
}
```

Nothing changes for the caller: its stub returns `RPCResponse<Int>` as it
would for a method returning `Int`, and on the wire the answer is an `Int`. In
a contract, a method answered later returns `Future<T>`, and its commands class
still gets a stub returning `RPCResponse<T>`.

For a future of its own, a handler makes a `Completer`, returns its `future`,
and completes it when it can: here, when four players are queued. One
handler serves every player's session, so the fourth player's call completes
all four futures, and each answer goes to the player who asked:

```haxe
import crossbyte.Completer;

class MatchQueueHandler extends RPCHandler {
	var queued:Array<Completer<Int>> = [];
	var nextMatch:Int = 1;

	public function new() {}

	@:rpc public function queue(player:String):Future<Int> {
		final place = new Completer<Int>();
		queued.push(place);
		if (queued.length == 4) {
			final match = nextMatch++;
			for (waiting in queued) {
				waiting.complete(match);
			}
			queued = [];
		}
		return place.future;
	}
}
```

A future that fails is answered as a throw is. `completer.fail(new
RPCError("No room."))` answers the caller `"No room."`; failing with anything
else answers `RPCError.INTERNAL_MESSAGE` and tells `onHandlerError`. A call to
another side that it refused with an `RPCError` fails with one, so the hub
above passes an instance host's refusal on to its client word for word.
`afterCall` runs when the future completes, with its failure, not when the
method returned.

A future complete already when the method returns (a cached answer) is
answered at once, costing no more than a plain answer. One completed later on
the session's own thread, as by an answer on another of its connections, is
answered then. One completed on another thread is handed to the session's
runtime and answered at its next tick, from its own thread, since a connection
is not thread-safe.

Each call waiting holds what it waits on, so a session limits how many may
wait at once: `maxCallsWaiting`, 256 unless set. A call past it is refused
before its method runs, with `RPCError.BUSY_MESSAGE`, as `beforeCall` refuses
one. If the connection ends while a call waits, its answer is dropped. How
long one may wait is `answerTimeout`; see Deadlines, below.

The runtime lane does the same for a registered handler that returns a
`Future`. Which of those answer later is not known until they run, so while
the limit is reached every runtime call is refused.

## Building surfaces from parts

A contract can extend other contracts; its commands class gets stubs for all
of their methods, and a handler for it answers all of them. A reusable piece
of protocol can be a contract of its own:

```haxe
interface PresenceContract {
	function online(user:String):Bool;
}

interface LobbyContract extends PresenceContract {
	function enterLobby(user:String):Int;
}
```

Handlers extend handlers, and commands classes extend commands classes, the
same way. A subclass answers, or can call, everything its parent does as well
as its own, and a contract's method can be implemented by an ancestor, so a
reusable handler can serve every contract built on its own:

```haxe
class PresenceHandler extends RPCHandler implements PresenceContract {
	var here = new Map<String, Bool>();

	public function new() {}

	public function online(user:String):Bool {
		return here.exists(user);
	}

	function arrive(user:String):Void {
		here.set(user, true);
	}
}

class LobbyHandler extends PresenceHandler implements LobbyContract {
	var entered:Int = 0;

	public function new() {
		super();
	}

	public function enterLobby(user:String):Int {
		arrive(user);
		return ++entered;
	}
}

@:rpcContract(PresenceContract)
class PresenceCommands extends RPCCommands {
	public function new() {}
}

@:rpcContract(LobbyContract)
class LobbyCommands extends PresenceCommands {
	public function new() {
		super();
	}
}
```

Hooks overridden in a shared base handler apply to every handler built on it.

Splitting a surface into parts this way is also how a very large one builds
for the jvm, where a class can hold about 640 methods and variables of its
own: a commands class takes two for each request method (`join` and
`joinThen`) and one for each one-way method, and a handler one for each
method. Past that, the build fails saying so; split the contract, and its
commands classes and handlers extend each other a part each.

### What names a call

Each call is named on the wire by its *op*, a 32-bit hash (FNV-1a, as
`crossbyte.utils.Hash.fnv1a32` computes it) of its method's signature: the
method's name, the kinds of its arguments in order and, for a request, of its
answer.

```
signature := name "(" [ kind ("," kind)* ] ")" [ ":" kind ]
kind      := [ "?" ] ( "i32" | "bool" | "f64" | "utf8" | "bytes"
                     | "f32" | "i8" | "u8" | "i16" | "u16" | "vu" | "vi"
                     | "[" kind "]"
                     | "[" ( "utf8" | "i32" ) ":" kind "]"
                     | [ "b" ] "{" field ("," field)* "}"
                     | "<" ctor ("," ctor)* ">"
                     | "~" struct
                     | "~[" ( "utf8" | "i32" ) ":" struct "]" )
field     := [ id "=" ] name ":" ( kind | bits )
bits      := "q" width "(" hex16 "," hex16 ")" | "r(" min "," max ")"
ctor      := name [ "(" kind ("," kind)* ")" ]
```

A structure in the bit layout is `b{...}`, its quantized fields `q16(...)`
with their bounds as the 16 hex digits of their IEEE 754 binary64 bits, and its
ranged ones `r(0,63)`. A patch of a structure is `~` before its kind, a map
patch `~[i32:{...}]`: a peer without patches, or with other bounds, finds no
method.

`i32` is an `Int`, `bool` a `Bool`, `f64` a `Float`, `utf8` a `String` and
`bytes` a `haxe.io.Bytes`; `f32`, `i8`, `u8`, `i16`, `u16`, `vu` and `vi` are
`Float32`, `Int8`, `UInt8`, `Int16`, `UInt16`, `VarUInt` and `VarInt`; an array is its element's kind in
brackets, a map its key's kind and its value's in brackets with a colon
between (`Map<String, Int>` is `[utf8:i32]`), a structure its fields in braces, in their order on the wire, each
with its pinned id if it has one, an enum its constructors in angle brackets,
in index order, each with its arguments' kinds, an abstract the kind of what
it abstracts,
and `?` one that may be absent, `Null<T>` or an optional argument.
`update(state:Vec3):Void`, `Vec3` above, is `update({x:f32,y:f32,z:f32})`, and
`order(unit:Int, command:Command):Void` is
`order(i32,<Stop,Walk(f32,f32),Say(utf8,?i32)>)`.
`join(room:String):Int` is `join(utf8):i32`;
`say(room:String, text:String):Void` is `say(utf8,utf8)`;
`mark(cells:Array<Int>, labels:Array<Null<String>>):Void` is
`mark([i32],[?utf8])`. A one-way call's
signature has no answer, and a method that is answered takes one-way calls
too: it runs, and its answer goes nowhere. `ping` is the hash of its name
alone.

A kind names a layout, not a type, so renaming an argument, or a typedef,
changes nothing: `(position:Coordinate)`, with `typedef Coordinate = Float`,
is `(f64)`. Renaming the method, reordering arguments of different kinds,
retyping one, adding or removing one, or letting one be absent changes the
op, and a peer built from the other version answers the call as one for a
method it does not have. Swapping two arguments of the same kind changes
nothing on the wire, and so not the op: rename the method too.

Two signatures that hash alike would be one call, so a surface that has both,
however they came to be in it, fails the build and names them.

## The runtime lane

For calls chosen at run time (a plugin's, a script's, a console's), a
session can register a handler for a number of your choosing, and call one by
number, with the arguments in an array:

```haxe
// Given session:RPCSession<ChatCommands>.
final ECHO = 100;
final LOG = 101;

// The side that answers.
session.register(ECHO, args -> args[0]);
session.register(LOG, args -> {
	trace(args.join(" "));
	return null;
});

// The side that calls.
session.request(ECHO, ["hello"]).then(value -> trace('echoed $value'));
session.call(LOG, ["one-way", 2, true]);
```

Values on this lane carry a tag each, so an array can mix them: `null`,
`Bool`, `Int`, `Float`, `String` and `haxe.io.Bytes`. A request to a number
nobody registered is answered `RPCError.UNKNOWN_METHOD_MESSAGE` by any
session, whether or not it has runtime handlers, and a one-way call to one
is dropped. A value whose tag the receiving side does not know makes a call it
cannot read, answered `RPCError.UNREADABLE_MESSAGE`, rather than a connection
it ends: a later release can add kinds of value. `deregister` removes a
handler.

A runtime handler fails the way a compiled one does (an `RPCError`'s message
is the answer, anything else is `INTERNAL_MESSAGE` and goes to
`onHandlerError`), and it has the same hooks, set on the session since there
is no class to override them in:

```haxe
// Given session:RPCSession<ChatCommands>.
session.beforeRuntimeCall = (op, requestId, payloadSize) -> op >= 1000 ? new RPCError("Not open to plugins.") : null;
session.afterRuntimeCall = (op, requestId, error) -> {
	if (error != null) {
		trace('runtime op $op failed');
	}
};
```

### Typed calls on the runtime lane

`call` and `request` take an `Array<Dynamic>`: an array made for each call,
and each number in it boxed. `runtimeCall` and `runtimeRequest` write the same
frame value by value, straight into the session's buffer:

```haxe
// Given session:RPCSession<ChatCommands>.
final MOVE = 102;
final ADD = 101;
session.runtimeCall(MOVE).float(1.5).float(2.5).string("run").send();
session.runtimeRequest(ADD).int(7).int(35).send().then(sum -> trace('sum $sum'));
```

The other side reads it as it reads `call`'s, so the two kinds interoperate
both ways. Each value goes under its method's tag: `float(2)` is a Float on
every target, where `call` sends a whole Float as an Int on JavaScript, the
jvm and HashLink. `string(null)` and `bytes(null)` send the lane's null, and
`value(v)` tags anything `call` carries, for a value whose type is known only
at run time.

A writer is valid until it is sent: it is the session's frame, being written.
Send it once; a writer used after it was sent or cancelled throws an
`IllegalOperationError`. One never sent keeps the session's buffer, and every
call after it is framed in a fresh one; `cancel()` gives it back. A request's
id is taken as it begins, and it waits for its answer only once sent.
On the answering side, `registerArgs` hands a handler an `RPCArgs` in place
of the array: typed getters that read each value where it lies in the frame,
checked against its tag.

```haxe
// Given session:RPCSession<ChatCommands>.
final MOVE = 102;
session.registerArgs(MOVE, args -> {
	trace(args.float(0) + args.float(1), args.string(2));
	return null;
});
```

`int(i)` reads an Int, `float(i)` a Float or an Int, `bool(i)`, `string(i)` and
`bytes(i)` their kinds or the lane's null, `isNull(i)`, `kind(i)` and
`value(i)` anything; `count` is how many there are. A value of another kind,
or an index past `count`, throws an `RPCError` that names it, so a request's
caller is answered with that message. The frame is read once before the
handler runs, and a call that does not read is answered
`RPCError.UNREADABLE_MESSAGE` as on `register`'s side. It answers as a
`register` handler does; registering an op either way replaces its handler.
The `RPCArgs` is the session's, handed to the next call too: read the
arguments during the call.

Natively, a one-way call of three Floats written with `runtimeCall` and read
with `registerArgs` takes 68 ns and allocates nothing, where `call` with an
array and a `register` handler takes 155 ns and 368 bytes; a request of two
Ints and its answer 172 ns and 240 bytes against 235 ns and 448. Either half
alone: the writer to a `register` handler 105 ns, `call` to a `registerArgs`
handler 114 ns. On the jvm, 48-55 ns and 24 bytes against 100-116 ns and
272.

The two lanes share a connection without seeing each other: a runtime number
and a compiled method's op never collide.

## Sessions, heartbeats and pending calls

`start()` begins the session's heartbeat, with commands or without: a `ping`
every `pingInterval` seconds (45 unless set) when nothing
else has been sent, and the connection closed if nothing arrives for
`idleTimeout` (90 seconds). Every session answers a ping, so a peer with
nothing to say is still heard from, and a server that only answers calls can
heartbeat its clients to find the ones that have vanished. A ping is not a
call: `beforeCall` and `afterCall` never see one. `stop()` ends the heartbeat
without closing the connection. A `pingInterval` of zero or less means
no heartbeat at all, and an `idleTimeout` of zero or less means pings
that never time the peer out.

Started before its connection is up, the heartbeat begins once the connection
is ready; started again, it carries on as it was. When it times out, the calls
waiting fail saying so, and the connection is closed, which its `onClose`
hears once.

```haxe
// Given session:RPCSession<ChatCommands>, connection:crossbyte.net.NetConnection.
session.pingInterval = 10;
session.idleTimeout = 30;
session.start();

// The connection's callbacks stay the application's: set them before or
// after the session, it hears of the close either way.
connection.onClose = reason -> trace('connection closed: $reason');
```

A call waiting on an answer fails as soon as none can come: when the
connection closes or a transport error stops its reads, when the session is
stopped, when the heartbeat gives up on the peer, when the connection is ended
over a frame whose length cannot be trusted, and when its answer does not
read. Its `RPCResponse` fails with a message saying which, so nothing waits for
good on a peer that has gone.

A call that cannot go at all fails as it is made: on a connection that has
ended, with the `Reason` it ended with as its `cause`; when the transport's
send throws, with what it threw; and through commands no session has bound,
with an `IllegalOperationError`. A one-way call on a connection that has ended
is dropped, as a one-way call's fate always is; one through commands with no
session throws.

A peer that sends calls and never reads their answers would make this side
hold every answer. Over TCP and WebSocket, once more than the session's
`maxOutputPending` (16 MiB unless set) waits unsent for its peer, the session
takes the peer to have stopped reading and closes the connection, its reason
saying so; reliable UDP and local IPC bound what waits themselves, and the
pieces of large answers waiting count on every transport.

### Large answers

An answer longer than the session's `chunkLength` (64 KiB unless set) goes in
pieces of that length, between the frames sent while it goes, as HTTP/2's
streams interleave: a small call made just after a large one is answered
without waiting for the whole of it. Natively over loopback TCP, while a 64 MB
answer was in flight a small call took 3 ms (p50) and 15 ms (p99) where it
took 56 and 98, and the large answer itself went as fast (850 MB/s against
700); with an 8 MB answer, 1.6 and 6.6 ms where it took 11 and 27. The pieces
go as the connection takes them: what it holds unsent is kept under four
pieces, so a frame behind a large answer waits for at most those, and what
waits behind them is the session's, counted toward `maxOutputPending`. Up to
four answers go at once, a piece each in turn, and the rest wait their turn.

Calls never go in pieces, so they arrive in the order they were made. An
answer in pieces is complete when its last piece is in, so a frame sent after
it can arrive before it does: a notification sent after a large answer can be
heard before that answer. An application that needs every frame in the order
it was sent sets `chunkLength` to `0`, and every answer goes whole.

Pieces go over TCP, WebSocket and reliable UDP, to a peer whose hello says it
reads them (every 1.0 session's does); to any other an answer goes whole.
Each answer in pieces counts toward the reader's `maxFrameSize`, which it
learns from the first piece, and the reader holds no more than a few times
what has arrived of it. An answer that is one `Bytes` is put together in that
`Bytes` itself, so its reader holds it once.

A call failed by its connection ending has the `Reason` it ended with as its
`cause`, and a call refused by the other side has an `RPCError`, so a caller
can tell a peer that has gone from a peer that said no. Over a WebSocket the
`Reason` is `Code` with the code and reason the peer closed with (1001 for
a server going away, 1008 for one refusing by policy), and `Closed` when the
connection ended with no code known.

### Hello

Every session says hello as its connection starts (at once on a connection
that is up already, as an accepted one is, or as one becomes ready), with the
protocol version it speaks (`RPCSession.PROTOCOL_VERSION`, 1), the
capabilities it has (in 1.0, reading a call's deadline and a cancel, see
"The handler's side of a deadline", and reading answers in pieces, see
"Large answers"), and a fingerprint of the
methods its commands call and one of those its handler answers. A session
given its handler or commands after it was made (a server that attaches a
handler to each session as it registers it) says hello again as it is given
them, once its connection is up, so its peer hears what it really has; given
the same again, it says nothing more. The hello goes
out ahead of the session's calls and nothing waits for it, so it costs no
round trip. The peer's sets `peerVersion`, `peerCapabilities`,
`peerCallsFingerprint` and `peerAnswersFingerprint`, and `onHello` is called;
they go back to 0 as the connection ends, and a session made by `dial` hears
a hello from each connection. A peer from before 1.0 says no hello, and its
version stays 0. The hello is a response frame under request id 0, as a pong
is, which a session from before 1.0 passes over.

Two sides built from the same methods, with the same signatures, have the same
fingerprints. They are for a log line, and never refuse anything:

```haxe
// Given session:RPCSession<ChatCommands>.
session.onHello = () -> {
	if (session.peerAnswersFingerprint != session.callsFingerprint) {
		trace('the server was built from other methods than these commands call');
	}
};
```

A feature (a new kind of frame or of value, compression) is used towards a
peer only once its hello has declared it, so that a 1.0 session and a later
one keep understanding each other. Calls made before the peer's hello has
arrived go without what it has not yet declared: a client's first calls,
made as its connection comes up, carry no deadline to the server.

## A client that comes back

A client that must survive its server restarting (a gateway in front of a
backend) dials with `RPCSession.dial` rather than making a connection itself.
The session dials again whenever its connection ends: at once, and then after
a wait that doubles from `MIN_REDIAL` to `MAX_REDIAL` while the server stays
away. Its commands, handler, `data` and heartbeat stay with it from one
connection to the next.

```haxe
// Given commands:ChatCommands.
var backend = RPCSession.dial("tcp://127.0.0.1:4000", commands);
backend.onUp = () -> trace("backend up");
backend.onDown = reason -> trace('backend down: $reason');

commands.join("lobby").then(count -> trace('$count in the room'), message -> {
	// While the backend is away a call fails at once, and its cause is the
	// Reason the backend went.
	trace('not now: $message');
});
```

While it is down (before its first connection, and between one and the next),
a call fails as it is made, with a `Reason` as its `cause`. `up` says whether
it is up now, `onUp` and `onDown` when it comes and goes, and `close()` ends it:
it dials no more. It makes its first attempt at the next tick, so callbacks set
after `dial` returns hear it.

`RPCSession.dialWith` dials the same way through a function that makes each
connection, for one `dial` cannot make from an address alone: `tls://` with
`TLSOptions` (a private authority, a client certificate), or a connection a
test builds. A function that throws is an attempt that failed.

```haxe
// Given commands:ChatCommands, authority:crossbyte.net.Certificate.
var secure = RPCSession.dialWith(() -> new NetConnection("tls://127.0.0.1:4001", null, null, null, null, false, {certAuthority: authority}),
	commands);
```

A peer that answers and says hello can still be one the application will not
use (another build, a check of its own that failed). Dialled again at once,
it would be dialled in a loop. `backOff()` ends the connection and counts it
as an attempt that failed: the next dial waits, and the wait goes on doubling
for as long as each connection is backed off, back to its shortest once one
ends that was not.

```haxe
// Given secure:RPCSession<ChatCommands>.
secure.onHello = () -> {
	if (secure.peerAnswersFingerprint != secure.callsFingerprint) {
		secure.backOff();
	}
};
```

## Deadlines

A peer that is still there can still leave a call unanswered. A call can be
given a deadline (the session's `requestTimeout` for every call it makes, or
one of its own with `within`, in seconds), and past it the call fails
with an `RPCTimeoutError` as its `cause`. The connection is left as it was,
and an answer arriving later is dropped.

```haxe
// Given session:RPCSession<ChatCommands>, commands:ChatCommands.
import crossbyte.rpc.RPCTimeoutError;

session.requestTimeout = 5;

final joining = commands.join("lobby").within(2);
joining.catchError(message -> {
	if (Std.isOfType(joining.cause, RPCTimeoutError)) {
		trace('no answer in time: $message');
	}
});
```

`within(0)` leaves a call no deadline. A call made with a receiver has no
`RPCResponse` to give one to, so a deadline of its own is given before it,
through the commands: `within(seconds)` gives the next call made through
them its deadline, in place of `requestTimeout` (`0` for none), and returns the
commands, so the call follows. It works for a future's call as well.

```haxe
// Given commands:ChatCommands.
commands.within(2).joinThen("lobby", new Lobby());
```

A call without a deadline arms nothing and costs nothing for it. Every
deadline a session's calls have, whatever its length, waits in one heap with
one timer for all of them, and a call answered leaves it at once: a deadline
costs a call no allocation, and no timer of its own, of which a runtime holds
at most 524,288 at once.

A handler can be held to one as well. `answerTimeout` is how long a call its
handler answers with a `Future` may wait for that future: past it the caller is
answered `RPCError.TIMEOUT_MESSAGE`, `onHandlerError` and `afterCall` are told
with an `RPCTimeoutError`, and the call gives up its place among the
`maxCallsWaiting`. Without it, a future that never completes holds that place
for as long as the connection lasts. These deadlines wait in a queue of their
own, as `requestTimeout`'s do.

```haxe
// Given session:RPCSession<ChatCommands>.
session.answerTimeout = 10;
```

An `RPCTimeoutError` is an `RPCError`, so a handler forwarding a call that
timed out (as the hub above answers with an instance host's answer) tells
its own caller that it timed out, and reports it on its side too.

### The handler's side of a deadline

A call's deadline, given before it goes (`requestTimeout`, or `within`),
goes with it, and a call its caller stops waiting for (cancelled with
`cancelCall`, or past a deadline given with `timeout` after it went) is
cancelled on the other side as well, as gRPC's are. A handler sees both
through `currentCall`, an `RPCCall`: its `deadline` and `timeRemaining`, and,
for a call it answers later, `cancelled`, `reason` and `onCancel`:

```haxe
import crossbyte.rpc.RPCCall;

class ReportHandler extends RPCHandler {
	public function new() {}

	@:rpc public function report(days:Int):Future<String> {
		final call:RPCCall = currentCall;
		final done = new Completer<String>();
		// Work in steps, and stop once the caller has stopped waiting.
		var step = 0;
		var timer = 0;
		timer = crossbyte.Timer.setInterval(0.01, 0.01, () -> {
			if (call.cancelled || ++step == days) {
				crossbyte.Timer.clear(timer);
				done.complete('$step days');
			}
		});
		call.onCancel = () -> trace('report stopped: ${call.reason}');
		return done.future;
	}
}
```

A call answered later ends early when its caller cancels it or its
caller's deadline passes (nothing is answered, since nobody waits, and
nothing is reported), when `answerTimeout` passes first (its caller is
answered `RPCError.TIMEOUT_MESSAGE`, as above), or when its connection ends.
Then `cancelled` is `true`, `onCancel` is called once, the call stops counting
against `maxCallsWaiting`, `afterCall` is told (with
`RPCError.CANCELLED_MESSAGE` or an `RPCTimeoutError`; not for a connection
ending, where it is told as the future completes, as before), and the future's
answer goes nowhere. A runtime handler reads `session.currentCall`.

A call's `data` holds whatever the application keeps for that call alone (a
request context, a start time, the user it acts for), set in `beforeCall` or
the method and read in `afterCall`. It stays with the call when it answers
later: `afterCall` runs with the call as its `currentCall`, and its session as
`session`, however many other calls the handler has run since, where state
kept on the handler would hold the last call's. Keep an object there: a bare
number or `Bool` is boxed natively and on the jvm, an allocation each time.

`currentCall` is made the first time it is read in a call: a handler that
never reads it costs nothing for it, and a deadline costs the call a few
bytes on the wire and nothing else. A call answered later whose handler never
read `currentCall`, with no deadline of its caller's and no `answerTimeout`,
has nothing to end it early, and waits for its future alone, as cheaply as
before: a cancel for it finds nothing to stop, and its answer, sent, is
dropped by its caller. A deadline given with `within` after a
call has gone stays on the caller's side: its handler does not see it, and
is told only once it passes. One that went with the call binds the handler
as it was sent, so a longer one given with `within` afterwards waits for an
answer that, past the first, does not come.

## On the wire

What a session sends, for a reader writing a peer of their own, or reading a
capture. Every frame is its length and then that many bytes, little-endian:

```
u32      length       of what follows
u8       flags
i32      op           the call's op, a runtime number, or a piece's stream
varuint  request id   on a request and an answer; none on a one-way call
...                   the arguments, the answer, or an error's message
```

| flags | the frame |
|---|---|
| `0x00` | a one-way call |
| `0x01` | a request; with `0x10`, the caller's deadline follows the request id, a varuint of milliseconds |
| `0x02` | an answer |
| `0x06` | an error answer: the message (a varuint length, then UTF-8), then a varuint code of what refused the call |
| `0x08` | with any of these, the runtime lane: values carry a tag each |
| `0x20` | a cancel: the caller has stopped waiting for the call it names (op and request id) |
| `0x40` | a piece of an answer, `0xC0` its last; see below |

The codes after an error answer's message say what refused the call, as
`RPCFailure` does: none or `0` its handler (`Refused`), `1` its handler
failing (`HandlerFailed`), `2` no such method (`UnknownMethod`), `3`
arguments that did not read (`UnreadableArguments`), `4` too many calls
waiting (`Busy`), `5` nothing to answer calls (`NoHandler`), `6` its handler
out of time (`HandlerTimedOut`), `7` larger than its reader takes (`TooLarge`). A code a reader does not know is the
handler's refusal, with its message. A handler's refusal whose `RPCError` has
an id writes its code `0` out and then the id, a varuint of its 32 bits: a
reader that does not know ids takes the `0` for the handler's refusal and
passes over the rest with the frame, and one that does reads the id as
`Refused(message, code)`. With no id, nothing follows the message.

A ping is a one-way call to op `0x165DF089` with no arguments, answered with
a pong: an answer under request id 0. The hello is an answer under request id
0 for op `0xADD0D102`: varuints of the protocol version (1) and the
capabilities (`1` reads a request's deadline and a cancel, `2` reads answers
in pieces), then two `i32` fingerprints, of the methods its commands call and
its handler answers. A reader takes what it knows of a hello and passes over
the rest, and a frame of a kind it does not know is passed over too: every
frame says where the next begins.

A call of one `Int` and its answer are 15 bytes each way over TCP, and over
WebSocket 21 out and 17 back, with its frame header and a client's mask. Those
are with a request id of two bytes: the id is a varuint, one byte for a
session's first 127 calls, two to its 16,383rd and three from there to 2^21,
so a long-lived session's calls are a byte larger each way. gRPC's unary call
of the same, over HTTP/2, is HEADERS and DATA each way and the answer's
trailers: with grpc-js 48 bytes out and 42 back; with grpc-go 35 and 41 when
many calls share a connection, and 80 and 86 one call at a time. A call of
4 KB each way is 13 bytes past its payload each way over TCP, at the same id
size, where gRPC's is 51 out and 44 back with grpc-js, and with grpc-go the
same as its small call: 35 and 41, or 80 and 86. A `Map<String, Int>` of 8
entries each way is 168 to 170 bytes a call and its answer, where protobuf's
`map<string, int32>` of the same is 229 to 320 with grpc-go and 246 to 247
with grpc-js; of 256 entries 5,439 to 5,458 against 6,250 to 6,340 and 6,270
to 6,299; with many calls in flight the server spends 0.88 and 23 us of
processor time on one, where grpc-go on one thread spends 10 and 94.
[performance.md](performance.md#rpc-beside-grpc) has how these were counted,
and what each call costs in time, maps included.

**Patches.** A structure's patch is a bit section and then a byte section:

```
bit section, the first bit the lowest of the first byte:
  1 bit     on an RPCPatch argument or answer only: set when it is full
  n bits    the mask: bit i for field i, in wire order
  per field that changed, in the bit layout: its presence bit if it may be
            absent, and its bits if it is a bit kind and there
  0-7 bits  zeros, to a whole byte
byte section, per field that changed (and is there), in wire order:
  a nested structure: its own patch, with no full bit, against the base's
  any other field: as a whole value of its kind is written
```

A map patch:

```
varuint  head        the removed count twice, plus 1 when full
varuint  added       count
varuint  updated     count
removed  keys, ascending
added    per entry, ascending: its key, then its value's patch from the default
updated  per entry, ascending: its key, then its value's patch from the base's
```

An `Int` key is the first of its group as a zigzag varint, and each after it a
varint of its distance from the one before, less one; a `String` key is
written whole, each group in the order maps order their keys. A structure in
the bit layout is its bit section (its presence bits, `Bool`s and quantized and
ranged fields, in wire order, padded to a byte) and then its other fields. An
array of one that is all bits is a varint count and one run of bits.

A piece of an answer:

```
u32      length       5 + the rest
u8       flags        0x40, or 0xC0 on the last piece
i32      stream       which answer it is a piece of
varuint  total        on the first piece only: the answer's frame length
...      the piece    the answer's frame after its length, in order
```

The pieces of one answer, joined, are its frame after its length, `total`
bytes in all: the first piece carries its flags and op, and the rest follow.
At most four answers go in pieces at once, one way on a connection; more,
pieces past `total`, an answer ending short of it, or a first piece that does
not begin an answer, end the connection.
