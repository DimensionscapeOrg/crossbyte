package crossbyte.cluster;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.FrameCodec;
import crossbyte.net.OutputOverflowPolicy;
import crossbyte.net.Socket;

/**
	A link between two nodes that repairs itself.

	Every transport here already carries bytes between two machines. What a
	cluster needs on top is small and always the same: whole messages rather
	than bytes, a link that comes back after the far end restarts, and
	somewhere bounded to put what could not be sent while it was away.
	`LocalConnection` is this shape for two processes on one machine; this is
	its remote sibling.

	It is a link to one peer and knows nothing about who that peer is. Which
	nodes to connect to is `Membership`'s answer, and what to send them is
	`Rendezvous`'s -- neither of which this refers to.

	```haxe
	var link = NodeChannel.dial("10.0.0.7", 7100);
	link.onMessage = payload -> handle(payload);
	link.onUp = () -> catchUp();
	link.send(payload);
	link.poll(now);            // from the tick, for reconnects
	```

	An accepted connection is the same thing without the dialling:

	```haxe
	server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> {
		var link = NodeChannel.adopt(cast event.socket);
	});
	```

	## What it does not do

	It does not retry a message. A link that came back is not a link that
	kept its place in the conversation, and a cluster message replayed after
	a gap is usually worse than one dropped -- whether it should be resent,
	and against what state, is the caller's to decide, which is why `onUp`
	exists.
**/
class NodeChannel {
	/** How long after a failed attempt the first retry goes out. **/
	public static inline var MIN_RETRY:Float = 0.25;

	/** The longest it will ever wait between attempts. **/
	public static inline var MAX_RETRY:Float = 30.0;

	/** What it will hold for a peer that is away, before `overflowPolicy`. **/
	public static inline var DEFAULT_MAX_QUEUED:Int = 4 * 1024 * 1024;

	/** Whether messages can go right now. **/
	public var up(get, never):Bool;

	/** Bytes written while the link was down and not yet sent. **/
	public var bufferedAmount(get, never):Int;

	/** The most to hold for an absent peer. Zero for no limit. **/
	public var maxQueuedBytes:Int = DEFAULT_MAX_QUEUED;

	/** What to do when more than `maxQueuedBytes` is waiting. **/
	public var overflowPolicy:OutputOverflowPolicy = CLOSE;

	/** The largest message this will accept from the peer. **/
	public var maxMessageSize(default, null):Int;

	/** Called with each whole message. **/
	public dynamic function onMessage(payload:ByteArray):Void {}

	/** Called when the link becomes usable, including after a repair. **/
	public dynamic function onUp():Void {}

	/** Called when it stops being usable, with whatever was said about why. **/
	public dynamic function onDown(reason:String):Void {}

	private var __socket:Socket;
	private var __frames:FrameCodec;
	private var __host:String;
	private var __port:Int;
	private var __dials:Bool;
	private var __closed:Bool = false;
	private var __up:Bool = false;
	private var __retryAt:Float = -1;
	private var __retryDelay:Float = MIN_RETRY;
	private var __queue:Array<ByteArray> = [];
	private var __queueAt:Int = 0;
	private var __queuedBytes:Int = 0;

	/** A link this end opens, and reopens for as long as it is not closed. **/
	public static function dial(host:String, port:Int, maxMessageSize:Int = FrameCodec.DEFAULT_MAX_FRAME):NodeChannel {
		if (host == null || host == "") {
			throw new ArgumentError("A node channel needs a host to dial.");
		}

		var channel = new NodeChannel(maxMessageSize);
		channel.__dials = true;
		channel.__host = host;
		channel.__port = port;
		channel.__open();
		return channel;
	}

	/**
		A link over a connection that arrived.

		Not redialled when it drops: the peer opened it and the peer is the
		one that can open it again.
	**/
	public static function adopt(socket:Socket, maxMessageSize:Int = FrameCodec.DEFAULT_MAX_FRAME):NodeChannel {
		if (socket == null) {
			throw new ArgumentError("A node channel needs a socket to adopt.");
		}

		var channel = new NodeChannel(maxMessageSize);
		channel.__dials = false;
		channel.__socket = socket;
		channel.__listen();

		if (socket.connected) {
			channel.__markUp();
		}

		return channel;
	}

	private function new(maxMessageSize:Int) {
		this.maxMessageSize = maxMessageSize;
		this.__frames = new FrameCodec(maxMessageSize);
	}

	/**
		Sends one message, or holds it until the link is back.

		@throws IOError When more than `maxQueuedBytes` is already waiting
		        and `overflowPolicy` is `THROW`.
	**/
	public function send(payload:ByteArray):Void {
		if (__closed) {
			throw new IOError("This node channel is closed.");
		}

		if (__up) {
			__write(payload);
			return;
		}

		__queue.push(payload);
		__queuedBytes += payload == null ? 0 : payload.length;
		__enforceQueueLimit();
	}

	/**
		Gives the link a chance to repair itself.

		Called from the tick. Nothing else here needs time, so a channel that
		is never polled still carries messages -- it just never comes back
		after the far end goes away.
	**/
	public function poll(now:Float):Void {
		if (__closed || __up || !__dials || __retryAt < 0 || now < __retryAt) {
			return;
		}

		__retryAt = -1;
		__open();
	}

	/** Closes the link for good. It is not redialled after this. **/
	public function close():Void {
		if (__closed) {
			return;
		}

		__closed = true;
		__dials = false;
		__drop("closed");

		if (__socket != null) {
			try {
				__socket.close();
			} catch (_:Dynamic) {}

			__socket = null;
		}

		__queue = [];
		__queueAt = 0;
		__queuedBytes = 0;
	}

	// ------------------------------------------------------------------

	private function get_up():Bool {
		return __up && !__closed;
	}

	private function get_bufferedAmount():Int {
		return __queuedBytes;
	}

	private function __open():Void {
		if (__closed) {
			return;
		}

		__socket = new Socket();
		__listen();

		try {
			__socket.connect(__host, __port);
		} catch (e:Dynamic) {
			__scheduleRetry(Std.string(e));
		}
	}

	private function __listen():Void {
		__socket.addEventListener(Event.CONNECT, function(_):Void {
			__markUp();
		});
		__socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
			__read();
		});
		__socket.addEventListener(Event.CLOSE, function(_):Void {
			__scheduleRetry("the peer closed the connection");
		});
		__socket.addEventListener(IOErrorEvent.IO_ERROR, function(event:IOErrorEvent):Void {
			__scheduleRetry(event.text);
		});
	}

	private function __markUp():Void {
		if (__up || __closed) {
			return;
		}

		__up = true;
		// Back to the shortest wait, so a link that drops once does not
		// carry a long delay into the next time it needs one.
		__retryDelay = MIN_RETRY;
		__frames.reset();
		__flushQueue();
		onUp();
	}

	private function __read():Void {
		if (__socket == null) {
			return;
		}

		var incoming = new ByteArray();

		try {
			__socket.readBytes(incoming, 0, __socket.bytesAvailable);
		} catch (e:Dynamic) {
			__scheduleRetry(Std.string(e));
			return;
		}

		__frames.feed(incoming);

		while (true) {
			var message:ByteArray = null;

			try {
				message = __frames.next();
			} catch (e:IOError) {
				// The peer declared a message larger than this will take, so
				// the stream is no longer at a boundary that can be found.
				__scheduleRetry(e.message);
				return;
			}

			if (message == null) {
				return;
			}

			onMessage(message);
		}
	}

	private function __write(payload:ByteArray):Void {
		try {
			__socket.writeBytes(FrameCodec.encode(payload));
			__socket.flush();
		} catch (e:Dynamic) {
			// It did not go, so it waits with everything else.
			__queue.push(payload);
			__queuedBytes += payload == null ? 0 : payload.length;
			__scheduleRetry(Std.string(e));
		}
	}

	private function __flushQueue():Void {
		// A cursor rather than taking the front off, which is a pass over
		// everything still queued for each message that leaves.
		while (__up && __queueAt < __queue.length) {
			var payload = __queue[__queueAt];
			__queue[__queueAt] = null;
			__queueAt++;
			__queuedBytes -= payload == null ? 0 : payload.length;
			__write(payload);
		}

		if (__queueAt >= __queue.length) {
			__queue = [];
			__queueAt = 0;
			__queuedBytes = 0;
		} else if (__queueAt > 32 && __queueAt * 2 >= __queue.length) {
			__queue = __queue.slice(__queueAt);
			__queueAt = 0;
		}
	}

	/**
		Bounds what is held for a peer that is away.

		A link that queued everything until the far end came back would hold
		the whole outage in memory, and an outage has no length. Same bound
		and the same two policies as `Socket`.
	**/
	private function __enforceQueueLimit():Void {
		if (maxQueuedBytes <= 0 || __queuedBytes <= maxQueuedBytes) {
			return;
		}

		var message:String = "A node channel is holding " + __queuedBytes + " bytes for a peer that is not reading, "
			+ "which is past the " + maxQueuedBytes + " byte limit.";

		switch (overflowPolicy) {
			case CLOSE:
				onDown(message);
				close();

			case THROW:
				throw new IOError(message);
		}
	}

	private function __drop(reason:String):Void {
		if (!__up) {
			return;
		}

		__up = false;
		onDown(reason);
	}

	private function __scheduleRetry(reason:String):Void {
		__drop(reason);

		if (__socket != null) {
			try {
				__socket.close();
			} catch (_:Dynamic) {}

			__socket = null;
		}

		if (__closed || !__dials) {
			return;
		}

		__retryAt = haxe.Timer.stamp() + __retryDelay;
		// Backed off, so a peer that is down for an hour is not dialled four
		// times a second for an hour.
		__retryDelay = __retryDelay * 2;

		if (__retryDelay > MAX_RETRY) {
			__retryDelay = MAX_RETRY;
		}
	}
}
