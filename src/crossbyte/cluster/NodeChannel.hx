package crossbyte.cluster;

import crossbyte.core.CrossByte;
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

	What is sent in one pass of the runtime's loop goes when the pass ends,
	in one write, as a `NetConnection`'s does; sent from another thread, or
	with no runtime running, it goes at once.

	It is a link to one peer and knows nothing about who that peer is. Which
	nodes to connect to is `Membership`'s answer, and what to send them is
	`Rendezvous`'s, neither of which this refers to.

	```haxe
	var link = NodeChannel.dial("10.0.0.7", 7100);
	link.onMessage = payload -> handle(payload);
	link.onUp = () -> catchUp();
	link.send(payload);
	link.poll();               // from the tick, for reconnects
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
	a gap is usually worse than one dropped: whether it should be resent,
	and against what state, is the caller's to decide, which is why `onUp`
	exists.
**/
class NodeChannel implements crossbyte.core._internal.PassFlush {
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
	// A message's length, big-endian, as `FrameCodec` frames it: written
	// ahead of the message itself, with no frame of its own made first.
	private var __header:ByteArray = null;
	// Whether the runtime will flush this pass's messages when it ends, and
	// the messages written in the pass until it has: if the link drops
	// first, they never went, and wait for it with the rest. Kept as they
	// were written, each behind its length, in a buffer of the channel's
	// own: what `send` was handed is the caller's again once it returns.
	private var __passQueued:Bool = false;
	private var __passBytes:ByteArray = null;
	private var __inPassCount:Int = 0;

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

		The message is `payload`'s bytes from 0 to its `length`, its position
		aside. They are copied before `send` returns, so `payload` is the
		caller's again at once, to change or reuse: a listener can forward
		the payload it was handed for its call alone, such as a datagram's
		`event.data`. What is held for the link, and what a pass wrote and
		takes back when the link fails before the pass ends, are those
		copies.

		@throws IOError When more than `maxQueuedBytes` is already waiting
		        and `overflowPolicy` is `THROW`.
	**/
	public function send(payload:ByteArray):Void {
		if (__closed) {
			throw new IOError("This node channel is closed.");
		}

		if (__up) {
			__write(payload, false);
			return;
		}

		__queue.push(__copyOf(payload));
		__queuedBytes += payload == null ? 0 : payload.length;
		__enforceQueueLimit();
	}

	/**
		Gives the link a chance to repair itself.

		Called from the tick. Nothing else here needs time, so a channel that
		is never polled still carries messages; it just never comes back
		after the far end goes away.

		It reads the time itself, from `haxe.Timer.stamp()`, the clock its
		retries are scheduled by.
	**/
	public function poll():Void {
		if (__closed || __up || !__dials || __retryAt < 0 || haxe.Timer.stamp() < __retryAt) {
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
		__forgetPass();
	}

	/** The runtime's call at the end of a pass: what the pass wrote goes now. **/
	@:noCompletion public function __flushPass():Void {
		__passQueued = false;
		if (__inPassCount == 0 || __socket == null) {
			return;
		}

		try {
			__socket.flush();
			__forgetPass();
		} catch (e:Dynamic) {
			__scheduleRetry(Std.string(e));
		}
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

	/**
		Writes one message to the link. `owned` says `payload` is already the
		channel's own copy, taken off the queue; otherwise it is the caller's,
		and anything kept of it is copied.
	**/
	private function __write(payload:ByteArray, owned:Bool):Void {
		try {
			var length:Int = payload == null ? 0 : payload.length;
			if (__header == null) {
				__header = new ByteArray();
				__header.length = 4;
			}
			var header:haxe.io.Bytes = __header;
			header.set(0, length >>> 24);
			header.set(1, (length >>> 16) & 0xFF);
			header.set(2, (length >>> 8) & 0xFF);
			header.set(3, length & 0xFF);
			__socket.writeBytes(__header, 0, 4);
			if (length > 0) {
				__socket.writeBytes(payload, 0, length);
			}

			if (__holdForPass()) {
				// The socket has copied it, but only the channel can take it
				// back if the link fails before the pass ends, so it keeps a
				// copy of its own rather than the caller's payload, whose bytes
				// may have changed by then.
				if (__passBytes == null) {
					__passBytes = new ByteArray();
				}
				__passBytes.writeBytes(__header, 0, 4);
				if (length > 0) {
					__passBytes.writeBytes(payload, 0, length);
				}
				__inPassCount++;
				return;
			}
			__socket.flush();
		} catch (e:Dynamic) {
			// It did not go, so it waits with everything else, behind what
			// the pass wrote before it.
			__requeuePass();
			__queue.push(owned ? payload : __copyOf(payload));
			__queuedBytes += payload == null ? 0 : payload.length;
			__scheduleRetry(Std.string(e));
		}
	}

	/** `payload`'s bytes, 0 to its length, in a `ByteArray` of the channel's own. **/
	private static function __copyOf(payload:ByteArray):ByteArray {
		var copy = new ByteArray();
		if (payload != null && payload.length > 0) {
			copy.writeBytes(payload, 0, payload.length);
		}
		return copy;
	}

	/**
		Whether what is written now can wait for the pass to end: on the
		runtime's own thread, while it runs. A socket whose limit throws is
		flushed at once, so the throw still reaches `send`.
	**/
	private function __holdForPass():Bool {
		if (__passQueued) {
			return true;
		}
		var runtime:CrossByte = @:privateAccess __socket.__runtime();
		if (runtime == null || @:privateAccess runtime.__didExit || CrossByte.__currentOrNull() != runtime) {
			return false;
		}
		if (__socket.outputOverflowPolicy == THROW && __socket.maxOutputBufferSize > 0) {
			return false;
		}
		__passQueued = true;
		@:privateAccess runtime.__queuePassFlush(this);
		return true;
	}

	/**
		the link, after whatever already waits, as a message that fails to
		go always does.
		go always did.
	**/
	private function __requeuePass():Void {
		if (__inPassCount > 0) {
			var pass:ByteArray = __passBytes;
			var bytes:haxe.io.Bytes = pass;
			var at:Int = 0;
			for (i in 0...__inPassCount) {
				var length:Int = (bytes.get(at) << 24) | (bytes.get(at + 1) << 16) | (bytes.get(at + 2) << 8) | bytes.get(at + 3);
				at += 4;
				var payload = new ByteArray();
				if (length > 0) {
					payload.writeBytes(pass, at, length);
					at += length;
				}
				__queue.push(payload);
				__queuedBytes += length;
			}
		}
		__forgetPass();
	}

	/**
		The pass's messages have gone, or will not be held: let go of them.
		Their buffer is kept for the next pass's, unless this one wrote more
		than `PASS_KEEP` bytes, which a link that is not busy should not
		hold on to.
	**/
	private function __forgetPass():Void {
		__inPassCount = 0;
		if (__passBytes != null) {
			if (__passBytes.length > PASS_KEEP) {
				__passBytes = null;
			} else {
				__passBytes.length = 0;
			}
		}
	}

	/** The most a pass's buffer keeps between passes: 64 KB. **/
	private static inline var PASS_KEEP:Int = 64 * 1024;

	private function __flushQueue():Void {
		// A cursor rather than taking the front off, which is a pass over
		// everything still queued for each message that leaves.
		while (__up && __queueAt < __queue.length) {
			var payload = __queue[__queueAt];
			__queue[__queueAt] = null;
			__queueAt++;
			__queuedBytes -= payload == null ? 0 : payload.length;
			__write(payload, true);
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
		var requeued:Bool = __inPassCount > 0;
		__requeuePass();
		__drop(reason);

		if (__socket != null) {
			// What the pass wrote waits for the next link, so it does not
			// also leave on this one as it closes.
			if (requeued) {
				@:privateAccess __socket.__discardOnClose = true;
			}
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
