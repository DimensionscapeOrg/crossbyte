package crossbyte.net;

import crossbyte.io.ByteArray;
import crossbyte.net._internal.CloseObservable;

/** Shared base storage for concrete `NetConnection` transport adapters. */
abstract class NetConnectionBase implements CloseObservable {
	/**
		A slot for whatever the application wants this connection to carry.

		Untouched by the framework, and it goes when the connection does.
		Without one, an application holding per-connection state (a session,
		a player, a room membership) keeps a `Map` beside the connection and
		has to remember to remove the entry on close. Forgetting is not
		noisy: the connection is gone, the traffic stops, and the entry stays
		until the process does.

		Typed as `Any` rather than `Dynamic` so reading it back needs an
		explicit cast, and a wrong one is a compile error rather than a field
		access on whatever happened to be there.

		```haxe
		connection.userData = new Session(player);
		var session:Session = cast connection.userData;
		```
	**/
	public var userData:Any = null;

	/** Transport protocol implemented by the concrete adapter. */
	public var protocol:Protocol;
	/** Timestamp of the most recent inbound payload, in uptime seconds. */
	public var inTimestamp:Float = 0.0;
	/** Timestamp of the most recent outbound payload, in uptime seconds. */
	public var outTimestamp:Float = 0.0;

	/**
		Set by a reader that reads all it is handed during the call and keeps
		none of it, as an `RPCSession` reads its frames: a transport that
		copies each arrival so its application may keep it (a reliable UDP
		message) hands such a reader the arrival itself instead, valid only
		during the call.
	**/
	@:noCompletion public var __borrowsInput:Bool = false;

	/**
		The bytes written to this connection that wait unsent, where its
		transport keeps them itself (TCP and WebSocket): what a peer that has
		stopped reading makes this side hold. 0 where a transport bounds them
		itself (reliable UDP, local IPC) or cannot say.
	**/
	@:noCompletion public function __bytesPending():Int {
		return 0;
	}

	/** Whether `__bytesPending` can say anything but 0, so a sender that asks only asks those that can. **/
	@:noCompletion public var __holdsOutput:Bool = false;

	/**
		Whether `__bytesQueued` says how much of what was sent waits to go
		(TCP, WebSocket and reliable UDP), so that a sender with more to send
		than it should hand over at once can pace itself by it: an `RPCSession`
		sending a large answer in chunks.
	**/
	@:noCompletion public var __paces:Bool = false;

	/**
		The bytes sent on this connection that have not gone out yet: unsent
		in its buffer, or held back by a congestion window. 0 where it cannot
		say; see `__paces`.
	**/
	@:noCompletion public function __bytesQueued():Int {
		return __bytesPending();
	}

	/**
		The most `__bytesQueued` may reach before the transport's own
		`outputOverflowPolicy` acts (a reliable UDP session's
		`maxOutputBufferSize`), so a sender pacing itself stays under it; 0
		for none.
	**/
	@:noCompletion public function __queueLimit():Int {
		return 0;
	}

	/**
		The most bytes this connection holds unread, past which it stops
		reading until they are read (a TCP socket's `maxInputBufferSize`), so
		a reader waiting for more than that to arrive whole would wait for
		good. 0 for no such limit.
	**/
	@:noCompletion public function __inputCapacity():Int {
		return 0;
	}

	/**
		The most bytes one `send` carries: past it the send ends the
		connection (a reliable UDP session holding more than its
		`maxOutputBufferSize` for its window) or goes nowhere (local IPC's
		8 MiB message). 0 for no such limit.
	**/
	@:noCompletion public function __largestSend():Int {
		return 0;
	}

	/**
		Whether each `send` arrives as a message its peer may refuse past a
		size (a WebSocket's) while the peer reads them as one stream, so a
		large frame can go as several sends.
	**/
	@:noCompletion public var __sendsMessages:Bool = false;

	/**
		Has `room` called once, on the connection's thread, when what waits
		unsent (`__bytesQueued`) has gone under `below`: a paced sender that
		has stopped told when to go on, rather than asking at every tick.
		`false` where the transport cannot tell, and the sender asks.
	**/
	@:noCompletion public function __whenQueueUnder(below:Int, room:Void->Void):Bool {
		return false;
	}

	/**
		Sends `length` bytes of `data` from `offset`, as `send` sends the
		whole of a `ByteArray`, and copied as `send` copies: a sender sending
		part of a buffer in place. Copied here into one of its own for a
		connection that has nothing better.
	**/
	@:noCompletion public function __sendRange(data:ByteArray, offset:Int, length:Int):Void {
		final part = new ByteArray();
		part.writeBytes(data, offset, length);
		part.position = 0;
		send(part);
	}

	// Told as the connection ends, and as it becomes ready, before the
	// application's callbacks; see CloseObservable.
	@:noCompletion private var __closeObserver:Null<Reason->Void> = null;
	@:noCompletion private var __readyObserver:Null<Void->Void> = null;
	@:noCompletion private var __closeObserved:Bool = false;

	// Whether onClose has been told, after which nothing is; and what an
	// error or a timeout said, for the onClose that follows it.
	@:noCompletion private var __ended:Bool = false;
	@:noCompletion private var __failure:Null<Reason> = null;

	@:noCompletion public function __observeClose(observer:Null<Reason->Void>):Void {
		__closeObserver = observer;
	}

	@:noCompletion public function __observeReady(observer:Null<Void->Void>):Void {
		__readyObserver = observer;
	}

	/**
		Closes the connection, telling `onClose` `reason` rather than
		`Reason.Closed`: for a closer that knows more than that it closed:
		an `RPCSession` whose heartbeat heard nothing closes its connection as
		`Reason.Timeout`. `close()` is this with `Reason.Closed`. A connection
		CrossByte did not write has only its own `close()`, which this calls.
	**/
	@:noCompletion public function __closeWith(reason:Reason):Void {
		close();
	}

	/**
		Called by each transport wherever it ends: before `onClose`, and before
		an `onError` that stopped its reads. Once: an error followed by its
		close is one end.
	**/
	@:noCompletion private inline function __notifyClose(reason:Reason):Void {
		final observer = __closeObserver;
		if (observer != null && !__closeObserved) {
			__closeObserved = true;
			observer(reason);
		}
	}

	/** What an `ioError` tells the callbacks: `Reason.Timeout` for a deadline that passed. **/
	@:noCompletion private static function __reasonOf(error:crossbyte.events.IOErrorEvent):Reason {
		return error.errorID == crossbyte.events.IOErrorEvent.TIMEOUT_ERROR_ID ? Reason.Timeout : Reason.Error(error.text);
	}

	/**
		Called by each transport as it becomes ready, before `onReady`. A
		connection ready again (one an application wrote, taking another
		peer) has a new life, whose end is told in turn.
	**/
	@:noCompletion private inline function __notifyReady():Void {
		__closeObserved = false;
		final observer = __readyObserver;
		if (observer != null) {
			observer();
		}
	}

	/** Exposes the concrete transport wrapper. */
	public abstract function expose():Transport;
	/** Sends a payload over the transport. */
	public abstract function send(data:ByteArray):Void;
	/** Closes the transport. */
	public abstract function close():Void;
}
