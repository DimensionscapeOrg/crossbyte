package crossbyte.events;

import crossbyte.Object;

/**
	Base event payload for CrossByte dispatchers and typed event subclasses.

	## Copy it to keep it

	An event is valid only during the listener call it is handed to, and so
	is anything it carries that arrived from the network, the bytes of a
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

	What is handed out other than as an event or to a per-arrival hook
	stays the receiver's to keep: an RPC argument, a message a decoder
	returns, a request body, `NetConnection.onData`'s input, a member read
	later such as `ReliableDatagramSocket.connectPayload`.

	Two defines change how this is kept:

	- `-D crossbyte_fresh_events` makes every event and payload a new one,
	  as before 1.0, and reuses nothing: a workaround for code that keeps
	  them, until it copies instead.
	- `-D crossbyte_check_events` makes every one new too, and kills each
	  once the call that handed it out has returned: its bytes overwritten
	  with `0xDB`, its length and position set to 0, and the event's fields
	  cleared, strings null, numbers -1. Code that kept one then reads
	  poison, or reads nothing and throws, at the line that reads it: the
	  way to find the line that kept one.
**/
class Event {
	public static inline var TICK:EventType<Event> = "tick";
	public static inline var CLOSE:EventType<Event> = "close";

	/**
		The peer stopped sending, and the socket is staying open to write.

		Dispatched instead of `CLOSE` when a read ends in `Eof` under
		`PeerShutdownPolicy.HALF_OPEN`. `CLOSE` still follows later, when the
		socket is actually closed.
	**/
	public static inline var PEER_CLOSE:EventType<Event> = "peerClose";
	public static inline var CONNECT:EventType<Event> = "connect";
	public static inline var COMPLETE:EventType<Event> = "complete";
	public static inline var CANCEL:EventType<Event> = "cancel";
	public static inline var EXIT:EventType<Event> = "exit";
	public static inline var INIT:EventType<Event> = "init";

	/**
		The dispatcher the event is passing through now; see `target`.
	**/
	public var currentTarget(default, null):Object;

	/**
		The dispatcher the event was dispatched on: always an
		`IEventDispatcher`, typed `Object` as ActionScript types it.

		Assign it to the type it is for typed access,
		`var socket:Socket = event.target;`: which costs at most a type check
		of a few nanoseconds, natively, and nothing elsewhere: the object is
		the same one, and the assignment tells the compiler what it is. Reading
		fields through `Object` instead looks each one up by its name.
	**/
	public var target(default, null):Object;
	public var type(default, null):String;

	public function new(type:String) {
		this.type = type;
	}

	public function clone():Event {
		var event = new Event(type);
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}

	public function toString():String {
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

	/** Ready to be handed out again: dispatched afresh, as a new event is. **/
	@:noCompletion private inline function __retarget():Void {
		target = null;
		currentTarget = null;
	}
}
