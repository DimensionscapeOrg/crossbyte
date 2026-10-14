package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.errors.RangeError;
import crossbyte.events.TickEvent;
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
		The bytes sent on this connection that have not gone yet: over TCP and
		WebSocket what waits in the socket's output buffer (on Node, Node's
		queue too), over reliable UDP what the congestion window holds back,
		over local IPC what the peer has not taken. 0 for a connection of the
		application's own, which says nothing of its buffer.

		Over TCP what `send` writes in a pass on the runtime's thread counts
		until the pass ends, when it is handed to the system together.
	**/
	public var bytesPending(get, never):Int;

	@:noCompletion private function get_bytesPending():Int {
		return __bytesQueued();
	}

	/**
		How many bytes may wait unsent (`bytesPending`) before `onOutputHigh`
		is called: a peer falling behind, heard of before its transport's own
		limit closes the connection (`Reason.Overflow`). `0`, the default,
		calls nothing. Netty's write buffer water marks and Node's
		`highWaterMark` with its `drain` event are the same pair.

		Checked once what was sent has been handed to the system, so a burst
		the system takes whole is no backlog: over TCP at the end of the pass
		for the pass's sends (at once for a send from another thread), over
		WebSocket, reliable UDP and local IPC as each `send` returns. Once it
		is reached, `onOutputHigh` is called once, and then `onOutputDrained`
		once what waits has fallen to `outputLowWater` or below; after that,
		reaching it again calls `onOutputHigh` again. A server holding a
		stream of updates for each client skips the updates for one that is
		high and sends it the whole state once it has drained; see
		`NetConnection.outputHighWater`.

		Keep it under the transport's limit (a socket's
		`maxOutputBufferSize`, a reliable UDP session's 256 KB), or the
		connection is closed before it is reached.

		@throws RangeError If set below 0.
	**/
	public var outputHighWater(get, set):Int;

	/**
		Where what waits unsent has to fall to, once `outputHighWater` was
		reached, for `onOutputDrained` to be called: `0`, the default, waits
		for all of it to go. Keep it below `outputHighWater`.

		@throws RangeError If set below 0.
	**/
	public var outputLowWater(get, set):Int;

	/**
		Called once when what waits unsent reaches `outputHighWater`, on the
		thread that sent (the runtime's, for a send made there).
	**/
	public var onOutputHigh(get, set):Null<Void->Void>;

	/**
		Called once, after `onOutputHigh`, when what waits unsent has fallen
		to `outputLowWater`, on the connection's runtime. Not called for a
		connection that ends first. It may send.
	**/
	public var onOutputDrained(get, set):Null<Void->Void>;

	/**
		The marks and what watching them takes, made once any is set: a
		connection that sets none carries one empty field for them, and its
		sends compare it with null.
	**/
	@:noCompletion private var __marks:Null<OutputMarks> = null;

	@:noCompletion private inline function __outputMarks():OutputMarks {
		if (__marks == null) {
			__marks = new OutputMarks();
		}
		return __marks;
	}

	@:noCompletion private function get_outputHighWater():Int {
		return __marks == null ? 0 : __marks.high;
	}

	@:noCompletion private function set_outputHighWater(value:Int):Int {
		if (value < 0) {
			throw new RangeError('An output high water mark is 0 or more bytes, not $value.');
		}
		final marks:OutputMarks = __outputMarks();
		marks.high = value;
		if (value == 0 && marks.isHigh) {
			marks.isHigh = false;
			__watchOutput(false);
		}
		return value;
	}

	@:noCompletion private function get_outputLowWater():Int {
		return __marks == null ? 0 : __marks.low;
	}

	@:noCompletion private function set_outputLowWater(value:Int):Int {
		if (value < 0) {
			throw new RangeError('An output low water mark is 0 or more bytes, not $value.');
		}
		return __outputMarks().low = value;
	}

	@:noCompletion private function get_onOutputHigh():Null<Void->Void> {
		return __marks == null ? null : __marks.onHigh;
	}

	@:noCompletion private function set_onOutputHigh(value:Null<Void->Void>):Null<Void->Void> {
		return __outputMarks().onHigh = value;
	}

	@:noCompletion private function get_onOutputDrained():Null<Void->Void> {
		return __marks == null ? null : __marks.onDrained;
	}

	@:noCompletion private function set_onOutputDrained(value:Null<Void->Void>):Null<Void->Void> {
		return __outputMarks().onDrained = value;
	}

	/**
		Where a transport has handed what was sent to the system: one
		comparison with null for a connection with no marks.
	**/
	@:noCompletion private inline function __noteOutput():Void {
		if (__marks != null) {
			__checkOutputHigh();
		}
	}

	@:noCompletion private function __checkOutputHigh():Void {
		final marks:OutputMarks = __marks;
		if (marks.high <= 0 || marks.isHigh || __ended || __bytesQueued() < marks.high) {
			return;
		}
		marks.isHigh = true;
		__watchOutput(true);
		final told = marks.onHigh;
		if (told != null) {
			told();
		}
	}

	/**
		Some of what waited has gone: the transport's say, while
		`__watchOutput` has it watching. `onOutputDrained` is called once it
		is down to `outputLowWater`.
	**/
	@:noCompletion private function __outputMoved():Void {
		final marks:Null<OutputMarks> = __marks;
		if (marks == null || !marks.isHigh || __ended || __bytesQueued() > marks.low) {
			return;
		}
		marks.isHigh = false;
		__watchOutput(false);
		final told = marks.onDrained;
		if (told != null) {
			told();
		}
	}

	/**
		Starts or stops telling `__outputMoved` that output has moved, between
		`onOutputHigh` and `onOutputDrained` only. A transport that knows when
		its bytes go (a socket's `outputProgress`, a reliable session's
		window) overrides this; any other is asked at each tick of its
		runtime meanwhile.
	**/
	@:noCompletion public function __watchOutput(watching:Bool):Void {
		final marks:OutputMarks = __outputMarks();
		if (watching) {
			var runtime:Null<CrossByte> = CrossByte.__currentOrNull();
			if (runtime == null || marks.tickRuntime != null) {
				return;
			}
			if (marks.tick == null) {
				marks.tick = __onOutputTick;
			}
			marks.tickRuntime = runtime;
			runtime.addEventListener(TickEvent.TICK, marks.tick);
		} else if (marks.tickRuntime != null) {
			final runtime:CrossByte = marks.tickRuntime;
			marks.tickRuntime = null;
			runtime.removeEventListener(TickEvent.TICK, marks.tick);
		}
	}

	@:noCompletion private function __onOutputTick(_:TickEvent):Void {
		__outputMoved();
	}

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

	/**
		Whether `__sendWith` sends in a `DeliveryMode` of its own: a reliable
		UDP connection in its `DATAGRAM` mode. Every other has one way to
		send, and a sender asking for another sends as usual.
	**/
	@:noCompletion public function __takesDelivery():Bool {
		return false;
	}

	/** Sends `data` as `send` does, in `delivery`'s mode where `__takesDelivery` says it can. **/
	@:noCompletion public function __sendWith(data:ByteArray, delivery:DeliveryMode):Void {
		send(data);
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
		if (__marks != null && __marks.isHigh) {
			// Over: no drain is owed.
			__marks.isHigh = false;
			__watchOutput(false);
		}
		final observer = __closeObserver;
		if (observer != null && !__closeObserved) {
			__closeObserved = true;
			observer(reason);
		}
	}

	/**
		What an `ioError` tells the callbacks: `Reason.Timeout` for a deadline
		that passed, `Reason.Overflow` for output past its limit.
	**/
	@:noCompletion private static function __reasonOf(error:crossbyte.events.IOErrorEvent):Reason {
		return switch (error.errorId) {
			case crossbyte.events.IOErrorEvent.TIMEOUT_ERROR_ID: Reason.Timeout;
			case crossbyte.events.IOErrorEvent.OVERFLOW_ERROR_ID: Reason.Overflow;
			default: Reason.Error(error.text);
		}
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

/**
	A connection's output water marks, and what watching them takes; see
	`NetConnectionBase.outputHighWater`.
**/
@:noCompletion
@:dox(hide)
final class OutputMarks {
	public var high:Int = 0;
	public var low:Int = 0;
	public var onHigh:Null<Void->Void> = null;
	public var onDrained:Null<Void->Void> = null;
	// Whether `high` was reached and the drain is owed.
	public var isHigh:Bool = false;
	// The runtime ticking a connection that cannot say when its output
	// moves, and the tick, made once.
	public var tickRuntime:Null<CrossByte> = null;
	public var tick:Null<TickEvent->Void> = null;
	// A transport's own listener for its output moving, made once.
	public var progress:Null<crossbyte.events.OutputProgressEvent->Void> = null;
	// A reliable session's: what its window calls once drained, and whether
	// a pass flush is asked for to tell it.
	public var drained:Null<Void->Void> = null;
	public var drainQueued:Bool = false;

	public function new() {}
}
