# Events

CrossByte's events are those of [Emitter](https://github.com/dimensionscape/emitter) 2, the `emitter` haxelib
CrossByte depends on. Every class that raises events (a socket, a server, a runtime, a loader) is an
`EventDispatcher`, which is an `emitter.Emitter`, and every event is an `emitter.Event`. Graphaxe builds on the same
library, so a program that uses both has one kind of event and one way to listen.

## Listening

```haxe
// Given socket:crossbyte.net.Socket.
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;

socket.addEventListener(ProgressEvent.SOCKET_DATA, event -> trace(event.bytesLoaded + " bytes"));

var closing = socket.events.on(Event.CLOSE, _ -> trace("closed"));
closing.cancel();
```

An event type is an `EventType<T>`, which types its listener: a listener for `ProgressEvent.SOCKET_DATA` takes a
`ProgressEvent`, checked when it compiles.

The ActionScript names, `addEventListener`, `removeEventListener`, `hasEventListener`, `removeAllListeners` and
`dispatchEvent`, are Emitter's verbs `on`, `off`, `has`, `clear` and `dispatch`, which every dispatcher has under
`events`, and the two can be mixed. Emitter's do more:

- `events.on` and `events.once` answer with a `Subscription`, whose `cancel()` removes that listener, a lambda
  included.
- `events.once` listens for the next event only.
- `events.has(type, listener)` asks whether one listener listens.
- A dispatcher also carries typed signals, `events.emit(signal, ...)`, for notifications of your own that need no
  event object; Emitter's README shows them.

## The rules

- **Order.** Listeners run highest priority first (`addEventListener(type, listener, priority)`), and those of one
  priority in the order they were added.
- **A listener added again** for a type it already listens for is not added again, as in ActionScript: it keeps its
  place and runs once. The runtime, `CrossByte`, keeps each add instead (`allowDuplicates`): it holds a tick listener
  for each connection, timer and task, and adding one is not a search through the others.
- **Changes during a dispatch.** A dispatch takes the listeners as they are when it begins: one removed during it
  still runs for it, and one added waits for the next.
- **A listener that throws** ends the dispatch, and what it threw reaches the code that dispatched. The runtime's own
  events (`TICK`, `INIT`, `EXIT`) and a `Task`'s are contained instead: the failure is logged and dispatched as
  `UncaughtErrorEvent.UNCAUGHT_ERROR`, and the other listeners still run.
- **Threads.** A dispatcher belongs to its runtime's thread: add, remove and dispatch there, and hand work over from
  another thread with `CrossByte.post`.

## The target

`event.target` is the dispatcher the event was dispatched on, and `event.currentTarget` the one whose listeners are
running. Assign either to the class it is to use it as one:

```haxe
// Given server:crossbyte.net.ServerSocket.
import crossbyte.events.Event;
import crossbyte.net.ServerSocket;

server.addEventListener(Event.CLOSE, function(event:Event):Void {
	var closed:ServerSocket = event.target;
	trace("closed: " + closed.localPort);
});
```

Nothing checks the assignment: given another class, the variable holds that object on JavaScript, eval and Neko, is
null natively, and the assignment throws on the jvm and HashLink. `cast(event.target, ServerSocket)` checks what it
is first, and throws if it is not one. A type that is no dispatcher does not compile.

## Keeping an event

An event, and the bytes an arrival carries, are valid only during the listener call they are handed to: a socket
hands the same ones out again for what arrives next. A listener that wants something later copies it (the fields it
needs, `event.data.readBytes(copy)`, or `event.clone()`). The `Event` class says what is reused and how
`-D crossbyte_check_events` finds code that keeps one.

## Extending a class that dispatches

A subclass of one of CrossByte's classes overrides Emitter's hooks to act on listeners coming and going:
`listenersChanged(type, present)` for a type's first listener and its last, `listenerAdded` and `listenerRemoved`
for each. They hear every way of adding or removing, `events.on`, `events.once` and `removeAllListeners` included.
The ActionScript names are inline and cannot be overridden, and the verbs are reached through `events`, so a
subclass keeps names such as `clear`, `has` and `dispatch` for members of its own.
