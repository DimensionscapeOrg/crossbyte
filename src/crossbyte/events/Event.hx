package crossbyte.events;

/**
	CrossByte's events: an `emitter.Event`, from Emitter, the event library
	CrossByte is built on, with CrossByte's own event types on it (`TICK`,
	`CONNECT`, `CLOSE`, `EXIT` and the rest). Every event class here extends
	it, and so is an `emitter.Event`: a listener written for Emitter's events
	takes CrossByte's, and the other way round, so an application that uses
	Emitter itself, or a framework built on it, has one kind of event.

	`target` is the dispatcher the event was dispatched on, and
	`currentTarget` the one whose listeners are running. Assign either to
	the class it is to use it as one:

	```haxe
	// Given server:crossbyte.net.ServerSocket.
	import crossbyte.events.Event;
	import crossbyte.net.ServerSocket;

	server.addEventListener(Event.CLOSE, function(event:Event):Void {
		var closed:ServerSocket = event.target;
		trace("closed: " + closed.localPort);
	});
	```

	The object is the same one, and the assignment tells the compiler what
	it is. Nothing checks it, so it is for a listener that knows what it
	listens to: given another class, the variable holds that object on
	JavaScript, eval and Neko, is null natively, and the assignment throws
	on the jvm and HashLink. `cast(event.target, ServerSocket)` checks, and
	throws on every target if it is not one. A type that is no dispatcher
	does not compile. CrossByte's events do not bubble and are not
	cancelable: each is dispatched on the object it is about.

	## Copy it to keep it

	An event is valid only during the listener call it is handed to, and so
	is anything it carries that arrived from the network: the bytes of a
	`DatagramSocketDataEvent` or a `WebSocketMessageEvent`. The same goes for
	a payload handed to a hook called once per arrival, such as
	`ReliableDatagramServerSocket.onDatagram`. CrossByte may hand the same
	event and the same bytes out again for the next arrival: a server
	receiving thousands of messages a second makes no garbage for them, and
	the collector stops it that much less often.

	What is handed out again, released (one of each per socket, session or
	connection, filled again for each arrival): a `DatagramSocket`'s
	`DatagramSocketDataEvent` and its `data`; a `ReliableDatagramSocket`'s
	`DatagramSocketDataEvent` and the message it puts back together from
	fragments, and a stream's `ProgressEvent`; a `WebSocket`'s
	`WebSocketMessageEvent` and its `data`, and its `ProgressEvent`; a
	`Socket`'s `connect`, `close`, `ioError` and `socketData` events; and
	the payloads `TurnClient.onData` and `DtlsTransport.onMessage` are
	handed. Storage a payload grew past 16 KB is let go once its call has
	returned, and a socket that has received nothing holds none.

	So a listener that wants something later keeps a copy, not the event:

	```haxe
	// Given socket:crossbyte.net.DatagramSocket, inbox:Array<{from:String, bytes:crossbyte.io.ByteArray}>.
	import crossbyte.events.DatagramSocketDataEvent;
	import crossbyte.io.ByteArray;

	socket.addEventListener(DatagramSocketDataEvent.DATA, function(event:DatagramSocketDataEvent):Void {
		var bytes = new ByteArray();
		event.data.readBytes(bytes); // the bytes, copied out
		inbox.push({from: event.srcAddress, bytes: bytes}); // a field is copied by reading it
	});
	```

	or calls `clone()`, which copies what the event carries, its payload
	included, so a clone is always safe to keep. Queuing events to handle
	them at the next game tick is the case this is about: queue copies.

	Handing the payload to anything that reads it after the call returns
	keeps it just the same: a closure given to a timer, a `Future`,
	`CrossByte.post`, a `TaskPool` or an `AsyncDatabase`, which runs on
	another thread or later; an object stored to be written later. CrossByte's
	own APIs that take bytes and use them later copy them as they take them
	(every send, `URLLoader.load`, `File.save`, `Store.put`, an
	asynchronous `SQLiteStatement.execute`, `TypedWorker.run`), so the
	payload can go straight to those from inside the listener; a closure or
	a structure of your own holds a copy.

	What is handed out other than as an event or to a per-arrival hook
	stays the receiver's to keep: an RPC argument, a message a decoder
	returns, a request body, `NetConnection.onData`'s input, a member read
	later such as `ReliableDatagramSocket.connectPayload`.

	Two defines change how this is kept:

	- `-D crossbyte_fresh_events` makes every event and payload a new one
	  and reuses nothing: a workaround for code that keeps them, until it
	  copies instead.
	- `-D crossbyte_check_events` makes every one new too, and kills each
	  once the call that handed it out has returned: its bytes overwritten
	  with `0xDB`, its length and position set to 0, and the event's fields
	  cleared (strings null, numbers -1). Code that kept one then reads
	  poison, or reads nothing and throws, at the line that reads it: the
	  way to find the line that kept one.
**/
class Event extends emitter.Event {
	/** A runtime's tick: see `TickEvent`, which it is dispatched as. **/
	public static inline var TICK:EventType<Event> = "tick";

	/** Something closed: a socket, a server, a connection, a file. **/
	public static inline var CLOSE:EventType<Event> = "close";

	/**
		The peer stopped sending, and the socket is staying open to write.

		Dispatched instead of `CLOSE` when a read ends in `Eof` under
		`PeerShutdownPolicy.HALF_OPEN`. `CLOSE` still follows later, when the
		socket is actually closed.
	**/
	public static inline var PEER_CLOSE:EventType<Event> = "peerClose";
	/** Connected: a socket to its peer. A server's `connect` is a `ServerSocketConnectEvent`. **/
	public static inline var CONNECT:EventType<Event> = "connect";

	/** Something finished: a load, a transfer, a task. **/
	public static inline var COMPLETE:EventType<Event> = "complete";

	/** Something was cancelled. **/
	public static inline var CANCEL:EventType<Event> = "cancel";

	/** A runtime is exiting: dispatched once, after its last tick. **/
	public static inline var EXIT:EventType<Event> = "exit";

	/** A runtime is starting: dispatched once, before its first tick. **/
	public static inline var INIT:EventType<Event> = "init";

	/**
		@param type What happened: the name listeners are added for.
	**/
	public function new(type:String) {
		super(type);
	}

	/**
		A copy to keep: the same `type`, `target` and `currentTarget`. Each
		event class copies what it carries too, its payload included.
	**/
	override public function clone():Event {
		var event = new Event(type);
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}

	/** The event's type. **/
	override public function toString():String {
		return '$type';
	}

	/**
		Clears what this event says, once the call that handed it out has
		returned, under `-D crossbyte_check_events`: a subclass clears its
		own fields too. The type is left, so a kept event still says what
		it was.
	**/
	@:noCompletion private function __kill():Void {
		target = null;
		currentTarget = null;
	}

	/**
		Sets `target` and `currentTarget` to `dispatcher`, for an event
		CrossByte hands to listeners it calls itself rather than through a
		dispatch: a spread server's replicas calling the `connect` listeners
		added to it, a request handler telling a listener added late.
	**/
	@:noCompletion private inline function __targetAt(dispatcher:emitter.IEmitter):Void {
		target = dispatcher;
		currentTarget = dispatcher;
	}
}
