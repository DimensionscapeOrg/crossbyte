# RPC

CrossByte's RPC turns method calls into frames on any `NetConnection` -- TCP,
WebSocket, reliable UDP or local IPC -- and back. The calls are typed and
checked at compile time: a macro writes the code that encodes each call and
the code that decodes and dispatches it, so a call costs a method's worth of
encoding rather than a round of reflection.

There are two lanes on one connection:

- **The compiled lane.** You describe the calls as Haxe methods; the build
  generates the rest. This is the one to use.
- **The runtime lane.** Calls named by a number and carrying an array of
  values, for when the set of calls is not known until run time.

RPC runs on every target CrossByte builds for except JavaScript. A session is
bound to a `NetConnection`, and a browser has none of its transports.

Every example on this page is typechecked by `node ci/doc-examples.js`, which
CI runs, in the order it appears: a later example uses what an earlier one
declared.

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

An `RPCSession` binds either or both to a connection. A server makes one per
client it accepts:

```haxe
import crossbyte.net.NetHost;
import crossbyte.rpc.RPCSession;

var host = new NetHost("tcp://127.0.0.1:4000", connection -> {
	new RPCSession(connection, null, new ChatHandler());
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

## One-way calls and requests

A method that returns `Void` is a *one-way* call: it is sent, and nothing
comes back -- not even word that it failed. Any other return type makes a
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

An argument that may be absent -- `?value:Int`, or `value:Null<Int>` -- costs
one more byte to say whether it is there. A return type is any of these, or
`Void`. Anything else fails the build, naming the method.

Because nothing on the wire names a field, the two ends must agree on each
method exactly: its name, its arguments in order, and their types. Build both
from one contract and they do.

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
fails the build rather than quietly answering nothing. It takes at most eight
arguments.

Two names are the protocol's own and cannot be RPC methods: `ping`, which
every session answers and uses for heartbeats, and `dispatch`. Neither can
`beforeCall` or `afterCall`, below.

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
else a handler throws -- a null access, a database error, a bug -- is the
handler failing, and the caller is told only `RPCError.INTERNAL_MESSAGE`, so a
stack trace or a file path never crosses to whoever made the call. The error
itself goes to the session's `onHandlerError`, which logs it unless you
replace it:

```haxe
// Given session:RPCSession<ChatCommands>.
session.onHandlerError = (op, method, error) -> {
	trace('handler ${method != null ? method : "for op " + op} failed: $error');
};
```

A one-way call has nobody to answer, so whatever it throws, `RPCError` or not,
goes to `onHandlerError`.

What does end a connection is a frame that cannot be read: longer than
`RPCHandler.MAX_FRAME_LEN` (8 MiB), for a method this side does not have, or
with arguments that do not decode or that run past the end of the frame.
Nothing after such a frame could be trusted to line up, so the session closes
the connection, and every call still waiting on it fails.

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

	override public function afterCall(method:String, requestId:Int, error:Dynamic):Void {
		if (error != null) {
			failures++;
		}
	}
}
```

`beforeCall` runs before the call's arguments are read, with the method's
name, the request's id -- 0 for a one-way call -- and the bytes the arguments
take, so refusing an oversized call costs nothing. Return `null` to let the
call run, or an `RPCError` to refuse it: a request is answered with its
message, and a one-way call is dropped. Refusing by returning rather than
throwing keeps a flood of refusals from costing an exception each.
`afterCall` runs once the method has run and its answer has been sent; `error`
is what it threw, or `null`. It is not given the result, which would mean
boxing every `Int` a handler returns.

The calls to the hooks are generated only into a handler that overrides them,
or whose ancestor does. A handler that overrides neither pays nothing for
them, and one that does pays a call each. What a hook throws counts as the
call failing, and is reported to `onHandlerError`.

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
as its own, and a contract's method can be implemented by an ancestor -- so a
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

Each call is identified on the wire by a 32-bit hash of its method's name.
Two names that hash alike would be one call, so a surface that has both --
however they came to be in it -- fails the build and names them. It also
means renaming a method changes the call: rename it on both ends together.

## The runtime lane

For calls chosen at run time -- a plugin's, a script's, a console's -- a
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
nobody registered is answered with an error; a one-way call to one is dropped.
`deregister` removes a handler.

A runtime handler fails the way a compiled one does -- an `RPCError`'s message
is the answer, anything else is `INTERNAL_MESSAGE` and goes to
`onHandlerError` -- and it has the same hooks, set on the session since there
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

The two lanes share a connection without seeing each other: a runtime number
and a compiled method's hash never collide.

## Sessions, heartbeats and pending calls

`start()` begins the session's bookkeeping and, when it has commands, its
heartbeat: a `ping` every `heartbeatInterval` milliseconds (45 seconds unless
set), and the connection closed if nothing arrives for `heartbeatTimeout`
(90 seconds). `stop()` ends both without closing the connection.

```haxe
// Given session:RPCSession<ChatCommands>, connection:crossbyte.net.NetConnection.
session.heartbeatInterval = 10000;
session.heartbeatTimeout = 30000;
session.start();

// A call still waiting when the connection goes is not failed by the close
// alone. Stopping the session fails every one of them.
connection.onClose = reason -> session.stop();
```

A call waiting on an answer fails when the session is stopped, when the
heartbeat gives up on the peer, and when the connection is ended over a frame
that cannot be read. The connection closing on its own does not yet fail it,
which is why the example stops the session in `onClose`: without that, a call
made just before the peer went away waits for good.
