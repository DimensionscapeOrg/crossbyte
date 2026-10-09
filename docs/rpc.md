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
`NetConnection` a session is given, so it goes wherever one does.

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

## One handler, many clients

A handler can serve any number of sessions, and usually should: a server's
rooms, queues and world are one set of state, and the handler that answers
for them is one object. Each call is answered on the connection it came in
on. While a method runs, the handler's `session` is the session whose call
it is, so a method can tell its callers apart:

- `session.data` holds whatever the application keeps per client (a
  player, a login), set when the session is made;
- `session.commands` calls that client back, if the session has commands;
- `session.connection` is its connection.

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

Each request makes its `RPCResponse`, about 150 bytes, and an answer that is a
number is boxed into it. For a call made every frame, each request method
has a twin ending in `Then`, which hands the answer to a *receiver* instead.
It makes nothing for the call, and an answer that is a number or a `Bool`
arrives unboxed, so the call and its answer allocate nothing at either end,
natively or on the JVM. A `String` or an object answer allocates only itself.

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
| `Int`, `Int8`, `UInt8`, `Int16`, `UInt16`, `UInt` | `RPCIntReceiver` | `onInt` |
| `Float`, `Float32` | `RPCFloatReceiver` | `onFloat` |
| `Bool` | `RPCBoolReceiver` | `onBool` |
| `String` | `RPCStringReceiver` | `onString` |
| anything else, and `Null<T>` of anything | `RPCValueReceiver<T>` | `onValue` |

An abstract over a number arrives as that number: an enum abstract over `Int`
through `onInt`. One object can receive the answers of every method that
answers with its type, and a class can implement several of these. The
`...Then` method returns the call's id, which the receiver is told with the
answer, so it can tell its calls apart.

Every call is told exactly once, through its answer or through `onFailure`,
which says why with an `RPCFailure`: `TimedOut` past the session's
`callTimeout`, `Cancelled`, `Stopped`, `Disconnected(reason)`, `Refused(message)`
for an `RPCError` from the other side, `Unsent(message)` for a call that could
not go, or `Unreadable(message)`. A call that cannot go at all (its connection
has ended, or it is over `maxFrameLength`) is told before its `...Then`
method returns. A receiver that throws is logged, and nothing else is
affected.

`session.cancelCall(call)` stops waiting for a call: its receiver is told
`Cancelled`, and its answer is dropped when it comes. It works for a future's
`requestId` too.

The receivers are interfaces rather than callbacks for a reason: natively a
function value passes its argument as an object, so an `Int->Void` callback
would box every answer it was given.

### What can be sent

Arguments and answers are encoded by type, with no field names or type tags
on the wire:

| Type | On the wire |
|---|---|
| `Int` | 4 bytes |
| `Float` | 8 bytes |
| `Bool` | 1 byte |
| `String` | a length, then UTF-8 |
| `haxe.io.Bytes` | a length, then the bytes |
| `crossbyte.rpc.Float32` (or `Single`) | 4 bytes, single precision |
| `crossbyte.rpc.Int8`, `UInt8` | 1 byte |
| `crossbyte.rpc.Int16`, `UInt16` | 2 bytes |
| `Array<T>`, `T` any of these | a count, then each element as its type is written |
| a class that implements `crossbyte.rpc.RPCStruct`, or an anonymous structure | its fields, one after another |
| an enum | its constructor's index, 1 byte (2 past 256 constructors), then that constructor's arguments |
| an abstract over any of these, such as `enum abstract Team(Int)` or `UInt` | as the type it abstracts |

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

An `Int` is always four bytes and a `Float` eight. Where a value needs less, a
signature says so with a compact type: `Float32` for a position or a speed,
seven significant digits; `UInt8` for a level, a set of flags; `Int16` for a
small signed delta; `UInt16` for a count. Each is an `Int` (or a `Float`)
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

The caller's `RPCResponse` then fails with `"A room needs a name."`. Anything
else a handler throws (a null access, a database error, a bug) is the
handler failing, and the caller is told only `RPCError.INTERNAL_MESSAGE`, so a
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

What does end a connection is a frame whose length cannot be trusted: shorter
than any frame, or longer than the session's `maxFrameLength` (8 MiB unless
set). Nothing after it would line up, so the session closes the connection,
and every call still waiting on it fails.

A frame too long is caught before it is sent as well: a request over the
sending session's `maxFrameLength` fails at once with an `ArgumentError` as its
`cause`, a one-way call throws one, and an answer too long is not sent: its
caller is answered `RPCError.INTERNAL_MESSAGE`, and `onHandlerError` is told.
Both ends of a connection should agree on the limit.

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
long one may wait is `handlerTimeout`; see Deadlines, below.

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

### What names a call

Each call is named on the wire by its *op*, a 32-bit hash (FNV-1a, as
`crossbyte.utils.Hash.fnv1a32` computes it) of its method's signature: the
method's name, the kinds of its arguments in order and, for a request, of its
answer.

```
signature := name "(" [ kind ("," kind)* ] ")" [ ":" kind ]
kind      := [ "?" ] ( "i32" | "bool" | "f64" | "utf8" | "bytes"
                     | "f32" | "i8" | "u8" | "i16" | "u16"
                     | "[" kind "]"
                     | "{" field ("," field)* "}"
                     | "<" ctor ("," ctor)* ">" )
field     := [ id "=" ] name ":" kind
ctor      := name [ "(" kind ("," kind)* ")" ]
```

`i32` is an `Int`, `bool` a `Bool`, `f64` a `Float`, `utf8` a `String` and
`bytes` a `haxe.io.Bytes`; `f32`, `i8`, `u8`, `i16` and `u16` are `Float32`,
`Int8`, `UInt8`, `Int16` and `UInt16`; an array is its element's kind in
brackets, a structure its fields in braces, in their order on the wire, each
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
every `heartbeatInterval` milliseconds (45 seconds unless set) when nothing
else has been sent, and the connection closed if nothing arrives for
`heartbeatTimeout` (90 seconds). Every session answers a ping, so a peer with
nothing to say is still heard from, and a server that only answers calls can
heartbeat its clients to find the ones that have vanished. A ping is not a
call: `beforeCall` and `afterCall` never see one. `stop()` ends the heartbeat
without closing the connection.

Started before its connection is up, the heartbeat begins once the connection
is ready; started again, it carries on as it was. When it times out, the calls
waiting fail saying so, and the connection is closed, which its `onClose`
hears once.

```haxe
// Given session:RPCSession<ChatCommands>, connection:crossbyte.net.NetConnection.
session.heartbeatInterval = 10000;
session.heartbeatTimeout = 30000;
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
capabilities it has (none are defined in 1.0), and a fingerprint of the
methods its commands call and one of those its handler answers. The hello goes
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

A feature added after 1.0 (a new kind of frame or of value, compression)
is used towards a peer only once its hello has declared it, so that a 1.0
session and a later one keep understanding each other.

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

## Deadlines

A peer that is still there can still leave a call unanswered. A call can be
given a deadline (the session's `callTimeout` for every call it makes, or
one of its own with `timeout`, in milliseconds), and past it the call fails
with an `RPCTimeoutError` as its `cause`. The connection is left as it was,
and an answer arriving later is dropped.

```haxe
// Given session:RPCSession<ChatCommands>, commands:ChatCommands.
import crossbyte.rpc.RPCTimeoutError;

session.callTimeout = 5000;

final joining = commands.join("lobby").timeout(2000);
joining.catchError(message -> {
	if (Std.isOfType(joining.cause, RPCTimeoutError)) {
		trace('no answer in time: $message');
	}
});
```

`timeout(0)` leaves a call no deadline. A call without one arms nothing and
costs nothing for it. The calls under `callTimeout` fall due in the order they
were made, so they wait in one queue a session, with one timer for all of them,
and a call answered leaves it at once: a deadline costs a call no allocation,
and no timer of its own, of which a runtime holds at most 524,288 at once. A
call given its own with `timeout` holds a timer of its own until it is
answered, as does one made after `callTimeout` was lowered, which would fall due
before the calls ahead of it.

A handler can be held to one as well. `handlerTimeout` is how long a call its
handler answers with a `Future` may wait for that future: past it the caller is
answered `RPCError.TIMEOUT_MESSAGE`, `onHandlerError` and `afterCall` are told
with an `RPCTimeoutError`, and the call gives up its place among the
`maxCallsWaiting`. Without it, a future that never completes holds that place
for as long as the connection lasts. These deadlines wait in a queue of their
own, as `callTimeout`'s do.

```haxe
// Given session:RPCSession<ChatCommands>.
session.handlerTimeout = 10000;
```

An `RPCTimeoutError` is an `RPCError`, so a handler forwarding a call that
timed out (as the hub above answers with an instance host's answer) tells
its own caller that it timed out, and reports it on its side too.
