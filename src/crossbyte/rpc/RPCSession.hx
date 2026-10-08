package crossbyte.rpc;

import crossbyte._internal.system.timer.TimerHandle;

// Built for every target, JavaScript included: the portable suite runs RPC on
// Node and in a browser, where a NetConnection's Socket is a WebSocket.

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.io.ByteArray;
import crossbyte.net.INetConnection;
import crossbyte.net.Transport;
import crossbyte.net.Reason;
import crossbyte.utils.LogLevel;
import crossbyte.utils.Logger;
import crossbyte.core.CrossByte;
import crossbyte.Future;
import crossbyte.utils.Bucket;
import crossbyte.utils.Hash;
import crossbyte.sys.System;
import crossbyte.rpc.RPCHandler;
import crossbyte.rpc.RPCCommands;
import crossbyte.net.NetConnection;
import crossbyte.net.NetConnectionBase;
import crossbyte.events.EventDispatcher;
import crossbyte.io.ByteArrayInput;
import crossbyte.rpc._internal.RPCDeadlines;
import crossbyte.rpc._internal.RPCFrame;
import crossbyte.rpc._internal.RPCPendingCalls;
import crossbyte.rpc._internal.RPCWire;
import crossbyte.rpc._internal.RPCRuntimeCodec;
import haxe.ds.IntMap;
// haxe.atomic on hl needs HashLink 1.13, and Haxe 4.3 assumes 1.12 unless told
// otherwise with -D hl-ver: the counter takes neko's lock there rather than
// failing the build with "Atomic operations require HL 1.13+".
#if (neko || (hl && hl_ver < version("1.13.0")))
import sys.thread.Mutex;
#elseif (cpp || hl || java || cs)
import haxe.atomic.AtomicInt;
#end

@:access(crossbyte.rpc.RPCHandler)
@:access(crossbyte.rpc.RPCCommands)
@:access(crossbyte.rpc.RPCArgs)
/**
 * Binds an `RPCCommands` client surface and an optional `RPCHandler` to a live connection.
 *
 * `RPCSession` owns the wire-level framing hookup for request/response traffic,
 * forwards inbound calls to a handler, routes responses back to pending client
 * calls, and optionally maintains a heartbeat using the built-in `ping` path.
 */
class RPCSession<C:RPCCommands = Dynamic, D = Dynamic> extends EventDispatcher {
	/** Default interval between heartbeat pings in milliseconds. */
	public static inline final DEFAULT_HEARTBEAT_INTERVAL:Int = 45000;
	/** Default timeout window before a peer is considered dead, in milliseconds. */
	public static inline final DEFAULT_HEARTBEAT_TIMEOUT:Int = 90000;
	/** Default jitter bucket used to spread heartbeat start phases, in milliseconds. */
	public static inline final DEFAULT_HEARTBEAT_JITTER:Int = 5000;
	/** Default for `maxCallsWaiting`. */
	public static inline final DEFAULT_MAX_CALLS_WAITING:Int = 256;
	@:noCompletion private static final HEARTBEAT_SALT:Int = __getSalt();

	/** Process-local session identifier. */
	public final sessionId:Int = __getSessionId();
	/** Underlying transport connection used by this session. */
	public var connection(get, never):NetConnection;
	/** Optional server-side handler for inbound RPC calls. */
	public var handler(get, set):RPCHandler;
	/** Optional client-side command surface for outbound RPC calls and responses. */
	public var commands(get, set):C;
	/** Heartbeat interval in milliseconds. */
	public var heartbeatInterval(get, set):Int;
	/** Heartbeat timeout in milliseconds. */
	public var heartbeatTimeout(get, set):Int;
	/** Arbitrary user data attached to the session. */
	public var data:D;

	@:noCompletion private var __connection:NetConnection;
	@:noCompletion private var __handler:RPCHandler;
	@:noCompletion private var __commands:C;
	// TimerHandle.INVALID when no heartbeat is scheduled. Not 0: that is a real
	// handle, the first timer a scheduler hands out.
	@:noCompletion private var __heartbeatTimerHandle:Int = TimerHandle.INVALID;
	@:noCompletion private var __heartbeatInterval:Int = DEFAULT_HEARTBEAT_INTERVAL;
	@:noCompletion private var __heartbeatTimeout:Int = DEFAULT_HEARTBEAT_TIMEOUT;
	@:noCompletion private var __heartbeatPhase:Int;
	@:noCompletion private var __active:Bool = false;
	@:noCompletion private var __hasHeartbeat:Bool = false;
	@:noCompletion private var __timeoutSec:Float = 0.0;
	@:noCompletion private var __intervalSec:Float = 0.0;
	// When the heartbeat started, on the runtime's clock: what the peer is
	// judged to have been heard since, until something arrives.
	@:noCompletion private var __heardSince:Float = 0.0;
	@:noCompletion private var __runtimeHandlers:Null<IntMap<Array<Dynamic>->Dynamic>> = null;
	// Handlers registered with registerArgs, and the reader they are handed.
	@:noCompletion private var __runtimeArgHandlers:Null<IntMap<RPCArgs->Dynamic>> = null;
	@:noCompletion private var __args:Null<RPCArgs> = null;
	@:noCompletion private var __runtimeRequestIdSeed:Int = 0;
	@:noCompletion private var __runtimePendingResponseId:Int = 0;
	@:noCompletion private var __runtimePendingResponse:RPCResponse<Dynamic> = null;
	@:noCompletion private var __runtimePendingResponses:Null<RPCPendingCalls> = null;
	// How many handlers `__runtimeHandlers` holds, and how many calls
	// `__runtimePendingResponses` does. Asking a map whether it is empty
	// meant iterating it, and natively that copies every value first: done
	// on every runtime-lane call, so each call cost as much as the calls
	// still waiting.
	@:noCompletion private var __runtimeHandlerCount:Int = 0;
	@:noCompletion private var __runtimePendingCount:Int = 0;

	/**
	 * The most inbound calls, on both lanes together, that may wait on an
	 * answer at once: calls whose handler answered with a `Future` not yet
	 * complete. Each holds whatever it is waiting on, so without a limit a
	 * peer could make this side hold as much as it liked. A call past it is
	 * refused before its method runs (a request answered
	 * `RPCError.BUSY_MESSAGE`, a one-way call dropped), as `beforeCall`
	 * refuses one, and like a refusal it is not reported. On the runtime lane,
	 * where which handlers answer later is not known before they run, every
	 * call is refused while the limit is reached. `0` removes it.
	 */
	public var maxCallsWaiting:Int = DEFAULT_MAX_CALLS_WAITING;

	/** How many inbound calls are waiting on an answer now; see `maxCallsWaiting`. */
	public var callsWaiting(get, never):Int;

	/**
		How long, in milliseconds, each request this session makes (through
		its commands or with `request`) may wait for its answer before it
		fails with an `RPCTimeoutError`. `0`, as it starts, is no deadline: a
		call waits for as long as the connection lasts. A call can have a
		deadline of its own instead; see `RPCResponse.timeout`.

		Read as each call is made. A call with no deadline arms nothing. The
		calls given this one wait in a queue, in the order they were made, and
		one timer serves them all; a call answered leaves it at once. One
		made after it was lowered, which would fall due before the calls
		ahead of it, holds a timer of its own until it is answered.
	**/
	public var callTimeout:Int = 0;

	/**
		How long, in milliseconds, a call this session's handler answers with
		a `Future` may wait for that future. Past it the caller is answered
		`RPCError.TIMEOUT_MESSAGE`, `onHandlerError` is told with an
		`RPCTimeoutError`, `afterCall` sees the same, and the call stops
		counting against `maxCallsWaiting`; the future completing later
		answers nothing. `0`, as it starts, is no limit: a future that never
		completes holds its place among the calls waiting for as long as the
		connection lasts.

		Both lanes, and only calls answered later: a method answering at once
		has answered before any deadline could pass. Their deadlines wait in a
		queue, as `callTimeout`'s do, with one timer for all of them.
	**/
	public var handlerTimeout:Int = 0;

	/**
		The most bytes a frame may hold, after its 4-byte length: what this
		session will read, and what it will send. A frame read past it ends
		the connection, since nothing after it can be trusted to line up. A
		call past it fails before it is sent (a request's `RPCResponse` with
		an `ArgumentError` as its cause, a one-way call by throwing one), and
		an answer past it is not sent: its caller is answered
		`RPCError.INTERNAL_MESSAGE` and `onHandlerError` is told.

		8 MiB by default. Both ends of a connection should agree on it: a call
		larger than the other side's limit ends the connection there, failing
		every call waiting on it. `0` removes the limit.
	**/
	public var maxFrameLength:Int = RPCHandler.MAX_FRAME_LEN;

	@:noCompletion private var __callsWaiting:Int = 0;
	// Whether the connection's onData is this session's reader: READ_ON,
	// READ_OFF, or READ_UNSET before the first binding.
	@:noCompletion private static inline final READ_UNSET:Int = -1;
	@:noCompletion private static inline final READ_OFF:Int = 0;
	@:noCompletion private static inline final READ_ON:Int = 1;
	@:noCompletion private var __readState:Int = READ_UNSET;
	// Set once the connection has ended: an answer completing after that has
	// nobody to go to, and a call made after it fails at once, with the
	// reason it ended.
	@:noCompletion private var __ended:Bool = false;
	@:noCompletion private var __endReason:Null<Reason> = null;
	// Which of its connection's lives the session is on, advanced each time
	// the connection ends. A call answered later keeps the one it came in on,
	// and is answered only while it is still current: a connection that takes
	// another peer, as a listening LocalConnection does, must not hand that
	// peer the last one's answers.
	@:noCompletion private var __epoch:Int = 0;
	// The buffer every frame this session sends is written in, made with the
	// first; see __takeFrame. Always null under crossbyte_check_events and
	// crossbyte_fresh_events, which frame each send in a buffer of its own.
	@:noCompletion private var __frame:Null<RPCFrame> = null;
	#if (cpp || neko || hl || java || jvm || eval)
	@:noCompletion private static final __threadTokens:sys.thread.Tls<{}> = new sys.thread.Tls();
	#end

	#if (neko || (hl && hl_ver < version("1.13.0")))
	@:noCompletion private static var __sidCounter:Int = 0;
	@:noCompletion private static var __sidLock:Null<Mutex> = new Mutex();
	#elseif (cpp || hl || java || cs)
	@:noCompletion private static var __sidCounter:AtomicInt = new AtomicInt(0);
	#else
	@:noCompletion private static var __sidCounter:Int = 0;
	#end

	@:noCompletion private static inline function __getSalt():Int {
		// TODO: load from persistant file if exists
		var id:String = System.getDeviceId();

		if (id != null) {
			id = StringTools.trim(id);
		}

		if (id == null || id.length == 0) {
			id = "crossbyte-rpc";
		}

		return Hash.fnv1a32String(id.toLowerCase());
	}

	@:noCompletion private static inline function __getSessionId():Int {
		#if (neko || (hl && hl_ver < version("1.13.0")))
		__sidLock.acquire();
		var id:Int = ++__sidCounter;
		__sidLock.release();
		return id;
		#elseif (cpp || hl || java || cs)
		return __sidCounter.add(1);
		#else
		return ++__sidCounter;
		#end
	}

	@:noCompletion private inline function set_heartbeatInterval(value:Int):Int {
		return __heartbeatInterval = value;
	}

	@:noCompletion private inline function get_heartbeatInterval():Int {
		return __heartbeatInterval;
	}

	@:noCompletion private inline function set_heartbeatTimeout(value:Int):Int {
		return __heartbeatTimeout = value;
	}

	@:noCompletion private inline function get_heartbeatTimeout():Int {
		return __heartbeatTimeout;
	}

	@:noCompletion private inline function set_commands(commands:C):C {
		var same:Bool = (commands == __commands);

		#if debug
		if (!same && commands != null) {
			var bound = commands.__nc;
			if (bound != null && bound != __connection) {
				throw "Cannot bind RPCCommands: already bound to a different RPCSession.";
			}
		}
		#end

		if (!same) {
			var old = __commands;
			__commands = commands;

			if (old != null && old.__nc == __connection) {
				old.__nc = null;
				old.__session = null;
			}
			if (commands != null) {
				commands.__nc = __connection;
				commands.__session = cast this;
			}
			__syncOnDataBinding();
		}

		return __commands;
	}

	/**
		The handler is not told of this session here: it may serve others,
		and is bound to each only while that one's calls run. See
		`__safeHandlerOnData`.
	**/
	@:noCompletion private inline function set_handler(handler:RPCHandler):RPCHandler {
		__handler = handler;
		__syncOnDataBinding();

		return handler;
	}

	@:noCompletion private inline function get_connection():NetConnection {
		return __connection;
	}

	@:noCompletion private inline function get_handler():RPCHandler {
		return __handler;
	}

	@:noCompletion private inline function get_commands():C {
		return __commands;
	}

	public function new(connection:NetConnection, ?commands:C, ?handler:RPCHandler) {
		super();
		__connection = connection;
		__isUp = connection.connected;
		this.commands = commands;
		this.handler = handler;
		// Told as the connection ends, whenever and whether the application
		// sets onClose, so a call still waiting on an answer fails once the
		// connection goes. And told, the same way, as it becomes ready, for a
		// heartbeat started before it was.
		(connection : NetConnectionBase).__observeClose(__connectionEnded);
		(connection : NetConnectionBase).__observeReady(__connectionReady);
		// Connected already, as an accepted connection is: hello now. One not
		// yet says it as it becomes ready.
		if (__isUp) {
			__sendHello();
		}
	}

	/** The shortest wait before a session made by `dial` dials again, in seconds. **/
	public static inline final MIN_REDIAL:Float = 0.25;

	/** The longest, in seconds: the wait doubles from `MIN_REDIAL` each time a dial fails. **/
	public static inline final MAX_REDIAL:Float = 30.0;

	/**
		Called when the connection becomes ready: connected, or (for a
		listening `LocalConnection`, or a session made by `dial`) connected
		again. Not for a connection ready before the session was made, as an
		accepted one is.
	**/
	public dynamic function onUp():Void {}

	/**
		Called when a connection that was usable ends, with the reason its
		transport gave. The calls waiting on it have failed by then, with that
		reason as their `cause`.
	**/
	public dynamic function onDown(reason:Reason):Void {}

	/** Whether calls can go now: the connection is up and has not ended. **/
	public var up(get, never):Bool;

	@:noCompletion private inline function get_up():Bool {
		return __isUp && !__ended && __connection.connected;
	}

	/** The RPC protocol version a session of this build speaks, which its hello declares: 1 for 1.0. **/
	public static inline final PROTOCOL_VERSION:Int = RPCWire.VERSION;

	/**
		The protocol version the peer's hello declared: 1 for a peer of 1.0.

		Every session says hello as its connection starts (at once on one
		connected already, or as one becomes ready): a frame of its own sent
		ahead of its calls and never waited for. A peer from before 1.0 sends
		none, and its version stays 0, as it is until a hello arrives. Back to
		0 as the connection ends: a session made by `dial` hears a hello from
		each connection, and a listening `LocalConnection` from each peer.
	**/
	public var peerVersion(default, null):Int = 0;

	/**
		The capabilities the peer's hello declared, a bit each. None are
		defined in 1.0, so 0. A feature added after 1.0 (a flag, a kind of
		frame or of value, compression) is to be used towards a peer only
		once its hello has declared it.
	**/
	public var peerCapabilities(default, null):Int = 0;

	/**
		A fingerprint of the methods this session's commands call: their ops
		(see `RPCOps`), hashed in order, so that two sides built from the same
		methods with the same signatures have the same one. 0 with no
		commands. Its hello sends it, as `peerCallsFingerprint` on the other
		side.
	**/
	public var callsFingerprint(get, never):Int;

	/**
		A fingerprint of the methods this session's handler answers, as
		`callsFingerprint` is of what it calls. 0 with no handler, or one with
		a hand-written `dispatch`.
	**/
	public var answersFingerprint(get, never):Int;

	/** The peer's `callsFingerprint`, from its hello: 0 until one arrives. **/
	public var peerCallsFingerprint(default, null):Int = 0;

	/** The peer's `answersFingerprint`, from its hello: 0 until one arrives. **/
	public var peerAnswersFingerprint(default, null):Int = 0;

	/**
		Called when the peer's hello arrives, once a connection, with
		`peerVersion`, `peerCapabilities` and the peer's fingerprints set.

		The fingerprints are for a log line: two that differ say the sides
		were built from different methods (one has a method more, or a
		signature changed), not that any call will fail, and nothing is
		refused for it. A call for a method the other side has not got is
		answered `RPCError.UNKNOWN_METHOD_MESSAGE` whatever the fingerprints
		say.

		```haxe
		// Given session:RPCSession<ChatCommands>.
		session.onHello = () -> {
			if (session.peerAnswersFingerprint != session.callsFingerprint) {
				trace('the peer was built from other methods than these commands call');
			}
		};
		```
	**/
	public dynamic function onHello():Void {}

	@:noCompletion private function get_callsFingerprint():Int {
		return __commands != null ? __commands.__rpc_fingerprint() : 0;
	}

	@:noCompletion private function get_answersFingerprint():Int {
		return __handler != null ? __handler.__rpc_fingerprint() : 0;
	}

	/**
		Says hello: a response frame under request id 0, which answers no call
		(a session from before 1.0 passes over it, as it does a pong), with
		this side's protocol version, capabilities and fingerprints. Sent and
		never waited for: a call made next goes right behind it. A send that
		throws here is the connection's to report, not the start's.
	**/
	@:noCompletion private function __sendHello():Void {
		final framed:RPCFrame = __takeFrame(HELLO_ROOM, RPCWire.FLAG_RESPONSE, RPCWire.HELLO_OP, 0);
		framed.putVarUInt(0);
		framed.putVarUInt(RPCWire.VERSION);
		framed.putVarUInt(RPCWire.CAPABILITIES);
		framed.putInt(callsFingerprint);
		framed.putInt(answersFingerprint);
		try {
			__connection.send(framed.finish());
		} catch (_:Dynamic) {}
		__sent(framed);
	}

	/** A hello's frame at its longest: its length, flags and op, an id, the version and capabilities, two fingerprints. **/
	@:noCompletion private static inline final HELLO_ROOM:Int = 4 + 5 + 1 + 5 + 5 + 4 + 4;

	/**
		The peer's hello, in a frame ending at `frameEnd`: what this version
		knows of it is read, and what a later one appends passed over.
	**/
	@:noCompletion private function __helloArrived(input:ByteArrayInput, frameEnd:Int):Void {
		var version:Int = 0;
		var capabilities:Int = 0;
		var calls:Int = 0;
		var answers:Int = 0;
		try {
			version = input.readVarUInt();
			capabilities = input.readVarUInt();
			calls = input.readInt();
			answers = input.readInt();
			RPCWire.requireWithin(input, frameEnd);
		} catch (error:Dynamic) {
			__passedOver(RPCWire.HELLO_OP, 0, "a hello that could not be read: " + Std.string(error));
			return;
		}
		peerVersion = version;
		peerCapabilities = capabilities;
		peerCallsFingerprint = calls;
		peerAnswersFingerprint = answers;
		try {
			onHello();
		} catch (error:Dynamic) {
			Logger.error("RPCSession.onHello threw: " + Std.string(error));
		}
	}

	// Whether the connection has been ready since it last ended (from the
	// start, for one ready before the session was made), so that being told
	// twice, as a connection ready as the session takes it may tell it
	// again, is one onUp.
	@:noCompletion private var __isUp:Bool = false;

	// For a session made by dial(): where it dials, how long it waits before
	// the next attempt, and the timer waiting; and, for any session, whether
	// close() has ended it for good.
	@:noCompletion private var __dialUri:Null<String> = null;
	@:noCompletion private var __redialDelay:Float = MIN_REDIAL;
	@:noCompletion private var __redialTimer:Int = TimerHandle.INVALID;
	@:noCompletion private var __closed:Bool = false;

	/**
		A client session that dials `uri` (as `NetConnection` does, `tcp://`,
		`ws://`, `wss://`, `rudp://` or `local://`) and dials it again whenever
		its connection ends, until `close()`: at once after an end, then waiting
		from `MIN_REDIAL` up to `MAX_REDIAL` seconds, doubling, between attempts
		that fail.

		While it is down (before its first connection is up, and between one
		connection and the next), a call through it fails as it is made, with a
		`Reason` as its `cause`: why the last connection ended, or why the last
		attempt failed. A call waiting when a connection ends fails with that
		connection's reason. `onUp` and `onDown` say when it comes and goes, and
		`up` whether it is up now.

		Its `connection` is each connection in turn. Its commands, handler,
		`data` and hooks stay with it across them, and so does `start()`: a
		heartbeat runs on each connection while it is up. Made on the thread
		whose runtime will run it, which dials from its own timers.
	**/
	public static function dial<C:RPCCommands>(uri:String, ?commands:C, ?handler:RPCHandler):RPCSession<C, Dynamic> {
		final session = new RPCSession<C, Dynamic>(new Unconnected(uri), commands, handler);
		session.__dialUri = uri;
		session.__ended = true;
		session.__endReason = Reason.Error("Not connected to " + uri + " yet");
		// The first attempt at the next tick, not in here: a connect that
		// finishes as it is made (local IPC, or anything on eval) would
		// be up, and have told onUp, before the caller could set it.
		session.__redialTimer = Timer.setTimeout(0, session.__dial);
		return session;
	}

	/**
		Ends the session: it stops its heartbeat, dials no more if it was made
		by `dial`, and closes its connection, whose end its calls waiting and
		`onDown` hear as usual.
	**/
	public function close():Void {
		__closed = true;
		if (__redialTimer != TimerHandle.INVALID) {
			Timer.clear(__redialTimer);
			__redialTimer = TimerHandle.INVALID;
		}
		__active = false;
		__stopHeartbeat();
		try {
			__connection.close();
		} catch (_:Dynamic) {}
		// A connection whose close says nothing (some of an application's
		// own) has ended all the same.
		if (!__ended) {
			__connectionEnded(Reason.Closed);
		}
	}

	/** One attempt: a new connection to `__dialUri`, which the session moves to. **/
	@:noCompletion private function __dial():Void {
		__redialTimer = TimerHandle.INVALID;
		if (__closed) {
			return;
		}
		var connection:Null<NetConnection> = null;
		try {
			// A single try over local IPC, whose connect waits on this thread
			// for a listener: a dial never holds up the runtime waiting. 1 ms,
			// not 0, which LocalConnection takes for no deadline.
			connection = new NetConnection(__dialUri, null, null, null, null, false, 1);
		} catch (error:Dynamic) {
			// Refused as it was made: a local:// name nobody listens on.
			__endReason = Reason.Error("Could not connect to " + __dialUri + ": " + Std.string(error));
			__redialLater();
			return;
		}
		__moveTo(connection);
	}

	/** Dials again once the wait is up, and waits longer next time. **/
	@:noCompletion private function __redialLater():Void {
		if (__closed || __dialUri == null || __redialTimer != TimerHandle.INVALID) {
			return;
		}
		final delay:Float = __redialDelay;
		__redialDelay = __redialDelay * 2 > MAX_REDIAL ? MAX_REDIAL : __redialDelay * 2;
		__redialTimer = Timer.setTimeout(delay, __dial);
	}

	/**
		Lets go of the connection it had, which has ended, and takes
		`connection`: reads it, observes it, and binds its commands to it. The
		session stays down until `connection` says it is ready.
	**/
	@:noCompletion private function __moveTo(connection:NetConnection):Void {
		final old:NetConnectionBase = __connection;
		old.__observeClose(null);
		old.__observeReady(null);
		if (__readState == READ_ON) {
			try {
				__connection.onData = __noData;
				__connection.readEnabled = false;
			} catch (_:Dynamic) {}
		}
		__connection = connection;
		__readState = READ_UNSET;
		__isUp = false;
		if (__commands != null) {
			__commands.__nc = connection;
		}
		(connection : NetConnectionBase).__observeClose(__connectionEnded);
		(connection : NetConnectionBase).__observeReady(__connectionReady);
		__syncOnDataBinding();
		// Connected already (a connect that finishes as it is made, as on
		// eval) told whoever was listening before this was.
		if (connection.connected) {
			__connectionReady();
		}
	}

	/** The connection can carry no answer now, so nothing waiting on one gets it. **/
	@:noCompletion private function __connectionEnded(reason:Reason):Void {
		final wasUp:Bool = __isUp && !__ended;
		__isUp = false;
		__ended = true;
		__endReason = reason;
		// The peer that said hello has gone; the next says its own.
		peerVersion = 0;
		peerCapabilities = 0;
		peerCallsFingerprint = 0;
		peerAnswersFingerprint = 0;
		// `| 0` so it wraps on JavaScript as it does elsewhere.
		__epoch = (__epoch + 1) | 0;
		// Stopped, not forgotten: `start()` still stands, for a connection
		// that becomes ready again.
		__stopHeartbeat();
		__failAllPending("RPC connection closed: " + Std.string(reason), reason);
		if (wasUp) {
			try {
				onDown(reason);
			} catch (error:Dynamic) {
				Logger.error("RPCSession.onDown threw: " + Std.string(error));
			}
		}
		if (__dialUri != null && !__closed) {
			// At once after a connection that was up; later after an attempt
			// that never got that far.
			if (wasUp) {
				__redialDelay = MIN_REDIAL;
				__dial();
			} else {
				__redialLater();
			}
		}
	}

	/** Whether the connection is still on the life `epoch` names, and has not ended. **/
	@:noCompletion private inline function __isCurrent(epoch:Int):Bool {
		return epoch == __epoch && !__ended;
	}

	/**
	 * Asked before each inbound call on the runtime lane (to a handler
	 * added with `register`, or to an op with none), before its arguments are
	 * read: the op, the request's id (0 for a one-way call) and the bytes its
	 * arguments take. Return `null` to let it run, or an `RPCError` to refuse
	 * it: a request is answered with the error's message, and a one-way call
	 * is dropped. A refusal is not reported.
	 *
	 * What `RPCHandler.beforeCall` is for a compiled handler, which overrides
	 * it; a runtime handler has no class to override it in, so it is set
	 * here. Left `null`, as it starts, it costs a runtime call one check.
	 * What it throws counts as the call failing: the caller is answered with
	 * `RPCError.INTERNAL_MESSAGE` and `onHandlerError` is told.
	 */
	public var beforeRuntimeCall:Null<(op:Int, requestId:Int, payloadSize:Int) -> Null<RPCError>> = null;

	/**
	 * Told after each runtime call `beforeRuntimeCall` let through and a
	 * registered handler ran, once its answer, if it has one, has been sent:
	 * `error` is `null` when the handler returned, and what it threw when it
	 * did not, as a `haxe.Exception` (see `onHandlerError`). What
	 * `RPCHandler.afterCall` is for a compiled handler. What it throws goes to
	 * `onHandlerError` and changes nothing else.
	 */
	public var afterRuntimeCall:Null<(op:Int, requestId:Int, error:Null<haxe.Exception>) -> Void> = null;

	/**
	 * Told of whatever a handler threw that its caller will not hear about:
	 * anything but an `RPCError` from a request, whose caller is told only
	 * `RPCError.INTERNAL_MESSAGE`, and anything at all from a one-way call,
	 * which nobody is waiting on. For either lane: `method` is the compiled
	 * handler's method name, or `null` for a runtime handler, which has only
	 * its `op`.
	 *
	 * The connection has stayed up: a handler failing is not the peer
	 * sending something unreadable.
	 *
	 * Logs by default. Replace it to count failures, raise an alert or keep
	 * the stack. Whatever it throws is ignored, so a report failing cannot
	 * close the connection either.
	 *
	 * `error` is a `haxe.Exception`: what was thrown, if it was one (an
	 * `RPCError`, an `RPCTimeoutError`), and otherwise a `haxe.ValueException`
	 * holding what was thrown in its `value`, its `stack` there to read.
	 */
	public dynamic function onHandlerError(op:Int, method:Null<String>, error:haxe.Exception):Void {
		Logger.error('RPC handler ' + (method != null ? method : 'for op $op') + ' threw: ' + Std.string(error));
	}

	/**
	 * Registers a runtime RPC handler for the given operation code.
	 *
	 * Runtime handlers receive decoded arguments as an array of dynamic values. If
	 * the incoming frame expects a response, the return value is encoded and sent
	 * back to the caller. One-way runtime calls ignore the return value.
	 */
	public function register(op:Int, handler:Array<Dynamic>->Dynamic):RPCSession<C, D> {
		if (!__hasRuntimeHandler(op)) {
			__runtimeHandlerCount++;
		}
		if (__runtimeArgHandlers != null) {
			__runtimeArgHandlers.remove(op);
		}
		if (__runtimeHandlers == null) {
			__runtimeHandlers = new IntMap();
		}
		__runtimeHandlers.set(op, handler);
		__syncOnDataBinding();
		return this;
	}

	/**
		Registers a runtime handler for `op` that reads its arguments where
		they lie, through `RPCArgs`' typed getters (`args.int(0)`,
		`args.string(1)`) in place of the `Array<Dynamic>` that `register`
		builds: no array, and no number boxed. It answers as a `register`
		handler does: what it returns is the answer of a request (a `Future`
		answered once it completes), and nothing for a one-way call.

		The wire is the same as `register`'s, so either side can be either
		kind: a call from `call`, `request`, `runtimeCall` or `runtimeRequest`
		reaches it. Registering `op` again, either way, replaces its handler.
		The `RPCArgs` is valid only during the call; see there.
	**/
	public function registerArgs(op:Int, handler:RPCArgs->Dynamic):RPCSession<C, D> {
		if (!__hasRuntimeHandler(op)) {
			__runtimeHandlerCount++;
		}
		if (__runtimeHandlers != null) {
			__runtimeHandlers.remove(op);
		}
		if (__runtimeArgHandlers == null) {
			__runtimeArgHandlers = new IntMap();
		}
		__runtimeArgHandlers.set(op, handler);
		__syncOnDataBinding();
		return this;
	}

	/** Removes a previously registered runtime RPC handler, of either kind. */
	public function deregister(op:Int):Bool {
		if (!__hasRuntimeHandler(op)) {
			return false;
		}
		if (__runtimeHandlers != null) {
			__runtimeHandlers.remove(op);
		}
		if (__runtimeArgHandlers != null) {
			__runtimeArgHandlers.remove(op);
		}
		__runtimeHandlerCount--;
		if (!__hasRuntimeHandlers()) {
			__runtimeHandlers = null;
			__runtimeArgHandlers = null;
		}
		__syncOnDataBinding();
		return true;
	}

	@:noCompletion private inline function __hasRuntimeHandler(op:Int):Bool {
		return (__runtimeHandlers != null && __runtimeHandlers.exists(op)) || (__runtimeArgHandlers != null && __runtimeArgHandlers.exists(op));
	}

	/**
		A one-way runtime call written value by value into this session's
		frame, with no array and no boxing; see `RPCCallWriter`.

		```haxe
		// Given session:RPCSession<Dynamic, Dynamic>.
		session.runtimeCall(102).float(1.5).float(2.5).send();
		```

		Valid until it is sent: send it, or `cancel()` it.
	**/
	public function runtimeCall(op:Int):RPCCallWriter {
		return new RPCCallWriter(__startWriting(op, 0));
	}

	/**
		A runtime request written value by value into this session's frame;
		see `RPCRequestWriter`. Its `send()` returns the `RPCResponse<T>`, as
		`request` does.

		```haxe
		// Given session:RPCSession<Dynamic, Dynamic>.
		session.runtimeRequest(101).int(7).int(35).send().then(sum -> trace(sum));
		```
	**/
	public function runtimeRequest<T>(op:Int):RPCRequestWriter<T> {
		return new RPCRequestWriter<T>(__startWriting(op, __nextRuntimeRequestId()));
	}

	/** A frame begun for a writer: the session's, or a fresh one while that is taken. Its count goes in the byte kept after the head. **/
	@:noCompletion private function __startWriting(op:Int, requestId:Int):RPCFrame {
		final framed:RPCFrame = __takeFrame(RUNTIME_ROOM, RPCWire.FLAG_RUNTIME | (requestId != 0 ? RPCWire.FLAG_REQUEST : 0), op, requestId);
		framed.building = true;
		framed.owner = cast this;
		framed.op = op;
		framed.requestId = requestId;
		framed.count = 0;
		framed.countAt = framed.position;
		framed.putByte(0);
		return framed;
	}

	/** Sends a request a writer framed, waiting for its answer as `request` does. **/
	@:noCompletion private function __sendWrittenRequest<T>(requestId:Int, op:Int, framed:RPCFrame):RPCResponse<T> {
		final response = new RPCResponse<T>(requestId, op);
		response.__session = cast this;
		__trackRuntimeResponse(requestId, cast response);
		if (callTimeout > 0) {
			__queueDeadline(cast response, callTimeout);
		}
		__sendRequestFrame(response, framed);
		return response;
	}

	/**
		Sends a one-way runtime RPC call on the dynamic lane. Each argument is
		`null`, a `Bool`, an `Int`, a `Float`, a `String` or `haxe.io.Bytes`
		(a `ByteArray` among them, sent as its `length` bytes) and arrives
		as the same, `Bytes` for either of the last.

		@throws ArgumentError When the call is over `maxFrameLength`.
		@throws String When an argument is of a type the runtime lane does not carry.
	**/
	public function call(op:Int, ?args:Array<Dynamic>):Void {
		__sendCallFrame(__runtimeFrame(op, 0, args));
	}

	/**
	 * Sends a request/response runtime RPC call on the dynamic lane. Its
	 * arguments, and the answer, are of the types `call` carries.
	 *
	 * The response payload is decoded through the runtime codec and resolved into a
	 * normal `RPCResponse<T>`. A call that cannot go fails at once: over
	 * `maxFrameLength`, with an `ArgumentError` as its cause; on a connection
	 * that has ended, with the `Reason` it ended with; and when the send
	 * throws, with what it threw.
	 *
	 * @throws String When an argument is of a type the runtime lane does not carry;
	 * nothing is left waiting.
	 */
	public function request<T>(op:Int, ?args:Array<Dynamic>):RPCResponse<T> {
		final requestId = __nextRuntimeRequestId();
		// Framed before it waits, so an argument that cannot be sent leaves
		// nothing waiting for good.
		final framed = __runtimeFrame(op, requestId, args);
		final response = new RPCResponse<T>(requestId, op);
		response.__session = cast this;
		__trackRuntimeResponse(requestId, cast response);
		if (callTimeout > 0) {
			__queueDeadline(cast response, callTimeout);
		}
		__sendRequestFrame(response, framed);
		return response;
	}

	// The deadlines of the calls this session makes under `callTimeout`, made
	// with the first; see RPCDeadlines.
	@:noCompletion private var __deadlines:Null<RPCDeadlines> = null;
	// And of those its handler answers later under `handlerTimeout`.
	@:noCompletion private var __handlerDeadlines:Null<HandlerDeadlines> = null;

	/**
		Gives `response` the session's deadline, `milliseconds` from now, in
		the queue one timer keeps for all of them; one that would fall before
		the last queued (`callTimeout` lowered between calls) arms its own,
		rather than each call arming a timer of its own, a closure and a timer
		node a call.
	**/
	@:noCompletion private function __queueDeadline(response:RPCResponse<Dynamic>, milliseconds:Int):Void {
		var queue:Null<RPCDeadlines> = __deadlines;
		if (queue == null) {
			queue = __deadlines = new RPCDeadlines();
		}
		if (!queue.add(response, milliseconds, Timer.getTime())) {
			response.__arm(milliseconds);
		}
	}

	@:noCompletion private inline function __hasRuntimeHandlers():Bool {
		return __runtimeHandlerCount > 0;
	}

	@:noCompletion private function __hasRuntimePendingResponses():Bool {
		return __runtimePendingResponse != null || __runtimePendingCount > 0;
	}

	/**
		Whether the session reads its connection: while it has anything that
		reads (a handler, commands, runtime handlers or runtime calls
		waiting) or a heartbeat, which reads the answers to its pings. A
		session with none leaves what arrives unread until it has.

		Called as each of those changes, which on the runtime lane is every
		call; so the connection is told only when the answer changes.
	**/
	@:noCompletion private function __syncOnDataBinding():Void {
		final read:Bool = __handler != null || __commands != null || __active || __hasRuntimeHandlers() || __hasRuntimePendingResponses();
		final state:Int = read ? READ_ON : READ_OFF;
		if (state == __readState) {
			return;
		}
		__readState = state;
		if (read) {
			__connection.onData = __safeOnData;
			__connection.readEnabled = true;
		} else {
			__connection.onData = __noData;
			__connection.readEnabled = false;
		}
	}

	@:noCompletion private static function __noData(input:ByteArrayInput):Void {}

	/*
		A delivery, read here whatever the session has bound. A frame whose
		length cannot be trusted ends the connection, since nothing after it
		would line up; and so does a send that throws while a frame is
		answered, and anything a hand-written dispatch throws.

		The handler is bound to this session for as long as its calls run
		(a field write per call), and put back as it was once the delivery
		has been read. One handler can serve any number of sessions, so it
		answers on, and names as `session`, whichever is dispatching to it
		now. Put back rather than cleared: over a connection that delivers at
		once, a method running for this session can make a call that another
		session dispatches to the same handler before this one's method has
		returned.
	*/
	@:noCompletion private function __safeOnData(input:ByteArrayInput):Void {
		final handler = __handler;
		final outer:RPCSession<Dynamic, Dynamic> = handler != null ? handler.this_session : null;
		try {
			__readFrames(input);
		} catch (error:Dynamic) {
			if (handler != null) {
				handler.this_session = outer;
			}
			__terminateProtocol(Reason.Error("RPC frame could not be read: " + Std.string(error)));
			return;
		}
		if (handler != null) {
			handler.this_session = outer;
		}
	}

	/**
		Every whole frame in `input`, on both lanes.

		One reader for everything a session might have bound: a runtime call
		to a session with no runtime handlers is answered as the runtime lane
		answers, and a request with nothing to answer it is answered
		`RPCError.NO_HANDLER_MESSAGE`.

		Every frame carries its length, so one this session cannot read is
		passed over, and the next is read where it begins: a call for a
		method it has not got, or whose arguments do not read (a request
		answered saying so), an answer that does not read, and a frame of a
		kind it does not know. Each is told to `onUnreadableFrame`, so in a
		rolling deploy a client calling a method its server does not have yet
		stays connected. Only a length that cannot be trusted ends it.
	**/
	@:noCompletion private inline function __readFrames(input:ByteArrayInput):Void {
		final maxLength:Int = maxFrameLength;
		while (input.bytesAvailable >= 9) {
			final lenPos:Int = input.position;
			final payloadLen:Int = input.readInt();

			if (payloadLen < RPCWire.MIN_PAYLOAD_LEN || (maxLength > 0 && payloadLen > maxLength)) {
				throw "Invalid RPC frame length";
			}

			if (input.bytesAvailable < payloadLen) {
				input.position = lenPos;
				break;
			}

			final frameEnd:Int = input.position + payloadLen;
			final flags:Int = input.readByte();
			final op:Int = input.readInt();

			if ((flags & RPCWire.FLAG_RUNTIME) != 0) {
				__dispatchRuntimeFrame(flags, op, input, frameEnd);
			} else if (flags == 0 || flags == RPCWire.FLAG_REQUEST) {
				var requestId:Int = 0;
				var readable:Bool = true;
				if (flags != 0) {
					// Within the frame, or the frame is passed over: one too
					// short for its id took it from the next.
					try {
						requestId = input.readVarUInt();
						readable = input.position <= frameEnd;
					} catch (_:Dynamic) {
						readable = false;
					}
				}
				final handler = __handler;
				if (!readable) {
					__passedOver(op, 0, UNREADABLE_ID);
				} else if (requestId == 0 && op == RPCWire.PING_OP) {
					__pinged();
				} else if (handler != null) {
					handler.this_session = cast this;
					handler.this_frameEnd = frameEnd;
					handler.dispatch(op, input, requestId);
				} else {
					if (requestId != 0) {
						__sendCompiledError(op, requestId, RPCError.NO_HANDLER_MESSAGE);
					}
					__passedOver(op, requestId, "nothing answers calls on this connection");
				}
			} else if (flags == RPCWire.FLAG_RESPONSE || flags == (RPCWire.FLAG_RESPONSE | RPCWire.FLAG_ERROR)) {
				var requestId:Int = 0;
				var readable:Bool = true;
				try {
					requestId = input.readVarUInt();
					readable = input.position <= frameEnd;
				} catch (_:Dynamic) {
					readable = false;
				}
				final commands = __commands;
				if (!readable) {
					__passedOver(op, 0, UNREADABLE_ID);
				} else if (requestId != 0) {
					if (commands != null) {
						commands.__frameEnd = frameEnd;
						commands.__rpc_handle_response(op, requestId, input, flags != RPCWire.FLAG_RESPONSE);
					}
				} else if (op == RPCWire.HELLO_OP && flags == RPCWire.FLAG_RESPONSE) {
					__helloArrived(input, frameEnd);
				}
				// Otherwise id 0, which answers no call: a pong.
			} else {
				__passedOver(op, 0, "a frame of a kind this session does not know, flags 0x" + StringTools.hex(flags & 0xFF, 2));
			}

			input.position = frameEnd;
		}

		@:privateAccess final now:Float = Timer.tryGetTime();
		if (now >= 0.0) {
			__connection.inTimestamp = now;
		}
	}

	/** What `onUnreadableFrame` is told of a frame too short for its request id. **/
	@:noCompletion private static inline final UNREADABLE_ID:String = "a frame whose request id could not be read";

	/**
		Told of each frame this session could not read and passed over, the
		connection staying up: a call for a method it has not got (from a
		peer built from another version of the contract, or after a method
		was added, as in a rolling deploy), or for an op no runtime handler
		is registered under, or reaching a session with nothing to answer
		calls; a call whose arguments did not read; an answer whose value did
		not read; and a frame of a kind it does not know. `requestId` is a
		call's id (0 for a one-way call, and for a frame that is not a call),
		and `reason` says which it was.

		A request among them has been answered by then, with
		`RPCError.UNKNOWN_METHOD_MESSAGE`, `RPCError.UNREADABLE_MESSAGE` or
		`RPCError.NO_HANDLER_MESSAGE`, and the call an unreadable answer was
		for has failed; a one-way call has been dropped. Only a frame whose
		length cannot be trusted ends the connection.

		Does nothing unless set: a server can count them, and close a peer
		that sends too many. What it throws is ignored.
	**/
	public dynamic function onUnreadableFrame(op:Int, requestId:Int, reason:String):Void {}

	/** Tells `onUnreadableFrame` of a frame passed over. **/
	@:noCompletion private function __passedOver(op:Int, requestId:Int, reason:String):Void {
		try {
			onUnreadableFrame(op, requestId, reason);
		} catch (_:Dynamic) {}
	}

	/**
		A compiled call for a method the handler has not got: a request is
		answered `RPCError.UNKNOWN_METHOD_MESSAGE`, a one-way call dropped.
	**/
	@:noCompletion private function __unknownCall(op:Int, requestId:Int):Void {
		if (requestId != 0) {
			__sendCompiledError(op, requestId, RPCError.UNKNOWN_METHOD_MESSAGE);
		}
		__passedOver(op, requestId, "no method answers op 0x" + StringTools.hex(op, 8));
	}

	/**
		A call, on either lane, whose arguments did not read: a request is
		answered `RPCError.UNREADABLE_MESSAGE`, a one-way call dropped.
	**/
	@:noCompletion private function __unreadableCall(op:Int, requestId:Int, runtime:Bool, error:Dynamic):Void {
		if (requestId != 0) {
			if (runtime) {
				__sendRuntimeError(op, requestId, RPCError.UNREADABLE_MESSAGE);
			} else {
				__sendCompiledError(op, requestId, RPCError.UNREADABLE_MESSAGE);
			}
		}
		__passedOver(op, requestId, "the call's arguments could not be read: " + Std.string(error));
	}

	/**
		An answer, on either lane, whose value did not read: `response`, the
		call it answers if one waits, fails saying so, with what failed as
		its cause, not an `RPCError`, since it was this side's reading that
		failed and not the other side refusing.
	**/
	@:noCompletion private function __unreadableAnswer(op:Int, requestId:Int, response:Null<RPCResponse<Dynamic>>, error:Dynamic):Void {
		final message:String = "RPC answer could not be read: " + Std.string(error);
		if (response != null) {
			response.__fail(message, error);
		}
		__passedOver(op, requestId, message);
	}

	/**
		A ping arrived: answered with a pong, and the handler's `ping` told,
		if it has one. Not a call, so neither `beforeCall` nor `afterCall`
		sees it: a limit on calls must not refuse the heartbeat.
	**/
	@:noCompletion private function __pinged():Void {
		__answerPing();
		final handler = __handler;
		if (handler != null) {
			try {
				handler.ping();
			} catch (error:haxe.Exception) {
				__reportHandlerError(RPCWire.PING_OP, "ping", error);
			}
		}
	}

	/**
		One runtime frame, ending at `frameEnd`. Everything it carries is read,
		and checked to lie within it, before a handler runs or a caller is
		answered.
	**/
	@:noCompletion private function __dispatchRuntimeFrame(flags:Int, op:Int, input:ByteArrayInput, frameEnd:Int):Void {
		final runtimeFlags:Int = flags & ~RPCWire.FLAG_RUNTIME;
		final call:Bool = runtimeFlags == 0 || runtimeFlags == RPCWire.FLAG_REQUEST;
		if (!call && runtimeFlags != RPCWire.FLAG_RESPONSE && runtimeFlags != (RPCWire.FLAG_RESPONSE | RPCWire.FLAG_ERROR)) {
			__passedOver(op, 0, "a runtime frame of a kind this session does not know, flags 0x" + StringTools.hex(flags & 0xFF, 2));
			return;
		}
		var requestId:Int = 0;
		if (runtimeFlags != 0) {
			var readable:Bool = true;
			try {
				requestId = input.readVarUInt();
				readable = input.position <= frameEnd;
			} catch (_:Dynamic) {
				readable = false;
			}
			if (!readable) {
				__passedOver(op, 0, UNREADABLE_ID);
				return;
			}
		}
		if (call) {
			// Asked before the arguments are read, so a call refused for its
			// size costs nothing to refuse. Refused, the frame is passed over.
			if (beforeRuntimeCall != null && !__admitRuntimeCall(op, requestId, frameEnd - input.position)) {
				return;
			}
			// A value of a kind this side does not know makes a call it cannot
			// read, not a connection that has to end: a later release can add
			// kinds of value without disconnecting this one.
			final typed:Null<RPCArgs->Dynamic> = __runtimeArgHandlers != null ? __runtimeArgHandlers.get(op) : null;
			if (typed != null) {
				__invokeRuntimeArgs(op, typed, input, frameEnd, requestId);
				return;
			}
			var args:Array<Dynamic> = null;
			try {
				args = RPCRuntimeCodec.readArgs(input, frameEnd);
				RPCWire.requireWithin(input, frameEnd);
			} catch (error:Dynamic) {
				__unreadableCall(op, requestId, true, error);
				return;
			}
			__invokeRuntime(op, args, requestId);
			return;
		}
		final failed:Bool = runtimeFlags != RPCWire.FLAG_RESPONSE;
		var value:Dynamic = null;
		try {
			value = failed ? input.readVarUTF() : RPCRuntimeCodec.readValue(input, frameEnd);
			RPCWire.requireWithin(input, frameEnd);
		} catch (error:Dynamic) {
			__unreadableAnswer(op, requestId, __takeRuntimeResponse(requestId), error);
			return;
		}
		if (failed) {
			__rejectRuntimeResponse(op, requestId, value);
		} else {
			__resolveRuntimeResponse(op, requestId, value);
		}
	}

	/**
		A call to a handler registered with `registerArgs`: its arguments
		found where they lie and checked to lie within the frame (one that
		does not read is answered as `register`'s side answers it), then the
		handler run on the session's `RPCArgs`, and answered as
		`__invokeRuntime` answers.
	**/
	@:noCompletion private function __invokeRuntimeArgs(op:Int, handler:RPCArgs->Dynamic, input:ByteArrayInput, frameEnd:Int, requestId:Int):Void {
		var args:Null<RPCArgs> = __args;
		if (args == null || args.__busy) {
			args = new RPCArgs();
			if (__args == null) {
				__args = args;
			}
		}
		try {
			args.__read(input, frameEnd);
		} catch (error:Dynamic) {
			args.__done();
			__unreadableCall(op, requestId, true, error);
			return;
		}
		if (__atCallLimit()) {
			args.__done();
			if (requestId != 0) {
				__sendRuntimeError(op, requestId, RPCError.BUSY_MESSAGE);
			}
			return;
		}
		args.__busy = true;
		var failure:Null<haxe.Exception> = null;
		var later:Null<Future<Dynamic>> = null;
		try {
			final result = handler(args);
			if (Std.isOfType(result, Future)) {
				later = cast result;
			} else if (requestId != 0) {
				__sendRuntimeResponse(op, requestId, result);
			}
		} catch (error:haxe.Exception) {
			failure = error;
			__answerRuntimeFailure(op, requestId, error, __epoch);
		}
		args.__done();
		if (later != null) {
			final epoch:Int = __epoch;
			__settleOnThisThread(later, settled -> __settleRuntimeCall(op, requestId, settled, epoch));
			return;
		}
		__afterRuntimeCall(op, requestId, failure);
	}

	@:noCompletion private function __invokeRuntime(op:Int, args:Array<Dynamic>, requestId:Int):Void {
		final handler = (__runtimeHandlers != null) ? __runtimeHandlers.get(op) : null;
		if (handler == null) {
			if (requestId != 0) {
				__sendRuntimeError(op, requestId, RPCError.UNKNOWN_METHOD_MESSAGE);
			}
			__passedOver(op, requestId, "no runtime handler is registered for op " + op);
			return;
		}
		if (__atCallLimit()) {
			if (requestId != 0) {
				__sendRuntimeError(op, requestId, RPCError.BUSY_MESSAGE);
			}
			return;
		}

		var failure:Null<haxe.Exception> = null;
		var later:Null<Future<Dynamic>> = null;
		try {
			final result = handler(args);
			// A type check a call: the one thing answering later costs a
			// handler that does not.
			if (Std.isOfType(result, Future)) {
				later = cast result;
			} else if (requestId != 0) {
				__sendRuntimeResponse(op, requestId, result);
			}
		} catch (error:haxe.Exception) {
			// The caller is not sent `Std.string(error)`, whatever it holds
			// (a path, a query, a stack), and a one-way call does not
			// rethrow: the same rules as the compiled lane.
			failure = error;
			__answerRuntimeFailure(op, requestId, error, __epoch);
		}

		if (later != null) {
			final epoch:Int = __epoch;
			__settleOnThisThread(later, settled -> __settleRuntimeCall(op, requestId, settled, epoch));
			return;
		}
		__afterRuntimeCall(op, requestId, failure);
	}

	/**
		A runtime call whose handler answered with a future, now complete:
		answered while the connection is on the life, `epoch`, it came in on.
	**/
	@:noCompletion private function __settleRuntimeCall(op:Int, requestId:Int, settled:Future<Dynamic>, epoch:Int):Void {
		var failure:Null<haxe.Exception> = null;
		if (settled.succeeded) {
			if (requestId != 0 && __isCurrent(epoch)) {
				try {
					__sendRuntimeResponse(op, requestId, settled.result);
				} catch (error:haxe.Exception) {
					failure = error;
					__answerRuntimeFailure(op, requestId, error, epoch);
				}
			}
		} else {
			failure = __failureOf(settled);
			__answerRuntimeFailure(op, requestId, failure, epoch);
		}
		__afterRuntimeCall(op, requestId, failure);
	}

	/**
	 * A runtime call failed with `error`: a request is answered with an
	 * `RPCError`'s message, or `RPCError.INTERNAL_MESSAGE`, and whatever the
	 * caller is not told is reported.
	 */
	@:noCompletion private function __answerRuntimeFailure(op:Int, requestId:Int, error:haxe.Exception, epoch:Int):Void {
		final answer:Null<String> = __answerFor(error);
		if (requestId != 0 && __isCurrent(epoch)) {
			__sendRuntimeError(op, requestId, answer != null ? answer : RPCError.INTERNAL_MESSAGE);
		}
		if (__reported(answer, requestId, error)) {
			__reportHandlerError(op, null, error);
		}
	}

	/**
		Whether a call's failure is reported on this side: when its caller is
		not told what it was (anything but an `RPCError`, or anything from a
		one-way call), and when it timed out, which its caller is told and
		which is news here as well.
	**/
	@:noCompletion private static inline function __reported(answer:Null<String>, requestId:Int, error:haxe.Exception):Bool {
		return answer == null || requestId == 0 || (error is RPCTimeoutError);
	}

	/**
		A compiled call failed with `error`, where `answerable` says whether
		its caller can still be answered: a request is answered with an
		`RPCError`'s message, or `RPCError.INTERNAL_MESSAGE`, and whatever the
		caller is not told is reported. An `RPCError` for a caller who can no
		longer be told is neither.
	**/
	@:noCompletion private function __callFailed(op:Int, method:String, requestId:Int, error:haxe.Exception, answerable:Bool):Void {
		final answer:Null<String> = __answerFor(error);
		if (requestId != 0 && answerable) {
			__sendCompiledError(op, requestId, answer != null ? answer : RPCError.INTERNAL_MESSAGE);
		}
		if (__reported(answer, requestId, error)) {
			__reportHandlerError(op, method, error);
		}
	}

	/**
		A frame to write at most `room` bytes into, begun with its flags, op
		and request id: this session's buffer, or, when that one is being
		written or sent still, as when a handler calls or answers from inside
		a send that delivers at once, a fresh one. Every frame taken goes
		back through `__sent`, sent or not.

		A `ByteArrayOutput` of its own for each frame, a call's and its
		answer's alike, would be most of what a call allocates.
	**/
	@:noCompletion private inline function __takeFrame(room:Int, flags:Int, op:Int, requestId:Int):RPCFrame {
		var frame:Null<RPCFrame> = __frame;
		if (frame == null || frame.busy) {
			frame = __newFrame(room);
		}
		frame.busy = true;
		frame.begin(room, flags, op, requestId);
		return frame;
	}

	/** A frame for `__takeFrame` when the session's is in use or there is none; the first is kept. **/
	@:noCompletion private function __newFrame(room:Int):RPCFrame {
		final frame = new RPCFrame(room);
		#if !(crossbyte_check_events || crossbyte_fresh_events)
		if (__frame == null && frame.capacity <= RPCFrame.KEEP_LIMIT) {
			__frame = frame;
		}
		#end
		return frame;
	}

	/**
		Gives back a frame `__takeFrame` gave, once it has been sent or will
		not be: `send` has copied what it keeps, so it is this session's to
		write the next frame in. A buffer grown past `RPCFrame.KEEP_LIMIT` is
		let go. Under `-D crossbyte_check_events` it is poisoned instead, so
		a transport that kept it sends garbage.
	**/
	@:noCompletion private inline function __sent(frame:RPCFrame):Void {
		#if crossbyte_check_events
		frame.poison();
		#end
		frame.busy = false;
		if (frame.capacity > RPCFrame.KEEP_LIMIT && frame == __frame) {
			__frame = null;
		}
	}

	/** Sends `frame` and gives it back, whether the send returns or throws. **/
	@:noCompletion private inline function __sendFrame(frame:RPCFrame):Void {
		try {
			__connection.send(frame);
		} catch (error:Dynamic) {
			__sent(frame);
			throw error;
		}
		__sent(frame);
	}

	/**
		Sends a compiled call's answer, framed by the handler's generated code.
		One over `maxFrameLength` throws, which the call it answers takes for
		the handler failing: its caller is answered `RPCError.INTERNAL_MESSAGE`
		and `onHandlerError` is told.
	**/
	@:noCompletion private inline function __sendAnswer(framed:RPCFrame):Void {
		if (__oversized(framed)) {
			final message:String = __oversizedMessage("RPC answer", framed);
			__sent(framed);
			throw new ArgumentError(message);
		}
		// An answer for a connection that has ended (its handler closed it)
		// has nobody to go to.
		if (__ended) {
			__sent(framed);
		} else {
			__sendFrame(framed);
		}
	}

	/**
		Why a call made now cannot go, or `null` if it can: the connection has
		ended. The message for a caller, and the `Reason` it ended with as the
		cause.
	**/
	@:noCompletion private inline function __closedMessage():String {
		return "RPC connection closed: " + Std.string(__endReason);
	}

	/**
		Sends a request's frame, or fails `response` at once when it cannot go:
		the connection has ended, the frame is over `maxFrameLength`, or the
		send throws. Nothing is left waiting on an answer that cannot come.
	**/
	@:noCompletion private function __sendRequestFrame<T>(response:RPCResponse<T>, framed:RPCFrame):Void {
		var message:Null<String> = null;
		var cause:Dynamic = null;
		if (__oversized(framed)) {
			message = __oversizedMessage("RPC call", framed);
			cause = new ArgumentError(message);
		} else if (__ended) {
			message = __closedMessage();
			cause = __endReason;
		} else {
			try {
				__connection.send(framed);
			} catch (error:Dynamic) {
				message = "RPC call could not be sent: " + Std.string(error);
				cause = error;
			}
		}
		__sent(framed);
		if (message != null) {
			// Out of where it waits first, as a deadline takes it.
			if (response.__commands != null) {
				response.__commands.__takeResponse(response.requestId);
			} else {
				__takeRuntimeResponse(response.requestId);
			}
			response.__fail(message, cause);
		}
	}

	/**
		Sends a one-way call's frame. Over `maxFrameLength` it throws; on a
		connection that has ended it is dropped, since nobody is told what
		becomes of a one-way call.

		@throws ArgumentError When the call is over `maxFrameLength`.
	**/
	@:noCompletion private function __sendCallFrame(framed:RPCFrame):Void {
		if (__oversized(framed)) {
			final message:String = __oversizedMessage("RPC call", framed);
			__sent(framed);
			throw new ArgumentError(message);
		}
		if (__ended) {
			__sent(framed);
		} else {
			__sendFrame(framed);
		}
	}

	/** Whether `framed`, finished, holds more than `maxFrameLength` after its 4-byte length. **/
	@:noCompletion private inline function __oversized(framed:RPCFrame):Bool {
		return maxFrameLength > 0 && framed.payloadLength > maxFrameLength;
	}

	@:noCompletion private function __oversizedMessage(what:String, framed:RPCFrame):String {
		return what + " of " + framed.payloadLength + " bytes is over the " + maxFrameLength + "-byte RPC frame limit";
	}

	/** Answers a compiled request with an error; nothing, once the connection has ended. **/
	@:noCompletion private function __sendCompiledError(op:Int, requestId:Int, message:String):Void {
		if (__ended) {
			return;
		}
		__sendError(RPCWire.FLAG_RESPONSE | RPCWire.FLAG_ERROR, op, requestId, message);
	}

	/**
		Frames and sends an error answer. A message too long to send (an
		`RPCError`'s) is not the caller's to see in part, and is answered
		`RPCError.INTERNAL_MESSAGE` instead.
	**/
	@:noCompletion private function __sendError(flags:Int, op:Int, requestId:Int, message:String):Void {
		var framed:RPCFrame = __errorFrame(flags, op, requestId, message);
		if (__oversized(framed)) {
			__sent(framed);
			framed = __errorFrame(flags, op, requestId, RPCError.INTERNAL_MESSAGE);
		}
		__sendFrame(framed);
	}

	@:noCompletion private function __errorFrame(flags:Int, op:Int, requestId:Int, message:String):RPCFrame {
		final framed:RPCFrame = __takeFrame(4 + RPCWire.MIN_PAYLOAD_LEN + 5 + 5 + message.length * 3, flags, op, requestId);
		// Its id even when it is 0, which no answer has: an error answer is
		// always framed so.
		if (requestId == 0) {
			framed.putVarUInt(0);
		}
		framed.putString(message);
		return framed.finish();
	}

	@:noCompletion private inline function __afterRuntimeCall(op:Int, requestId:Int, failure:Null<haxe.Exception>):Void {
		if (afterRuntimeCall != null) {
			try {
				afterRuntimeCall(op, requestId, failure);
			} catch (error:haxe.Exception) {
				__reportHandlerError(op, null, error);
			}
		}
	}

	/** Whether `maxCallsWaiting` calls are waiting already. **/
	@:noCompletion private inline function __atCallLimit():Bool {
		return maxCallsWaiting > 0 && __callsWaiting >= maxCallsWaiting;
	}

	@:noCompletion private inline function get_callsWaiting():Int {
		return __callsWaiting;
	}

	/**
	 * Has `settle` run for `future` on this session's thread once it
	 * completes: at once if it has, or when it completes on this thread, and
	 * posted to this thread's runtime when it completes on another: a
	 * connection is not thread-safe, and neither is anything this does in
	 * answer. Until then the call counts against `maxCallsWaiting`.
	 *
	 * Called on this session's thread, from the dispatch of the call. A
	 * thread with no runtime has nothing to hand the answer to, so there it
	 * is settled on whichever thread completes the future.
	 */
	@:noCompletion private function __settleOnThisThread<T>(future:Future<T>, settle:Future<T>->Void):Void {
		// Under the future's lock, so what settle reads of one another thread
		// has just completed is that thread's, whole.
		if (future.__stateNow() != 0) {
			// Heard, so not reported as a failure nobody listened for, which a
			// future that failed before anyone could attach otherwise is.
			future.__failureObserved = true;
			settle(future);
			return;
		}
		__callsWaiting++;
		// With a `handlerTimeout`, settled by whichever of the future and the
		// deadline comes first, on this thread; without one, only the future
		// settles it, and nothing more is made for it.
		final finish:Void->Void = handlerTimeout > 0 ? new HandlerDeadline<T>(cast this, future, settle, handlerTimeout).finish : function():Void {
			__callsWaiting--;
			settle(future);
		};
		#if (cpp || neko || hl || java || jvm || eval)
		// Which thread this is, told apart by a token of its own rather than
		// by runtime: CrossByte.current() says which runtime a thread has,
		// and throws on a thread with none, where a future is often
		// completed; it cannot say which thread the completion came on. The
		// runtime is read here, on this session's thread, where it has one.
		final home:{} = __threadToken();
		var runtime:Null<CrossByte> = null;
		try {
			runtime = CrossByte.current();
		} catch (_:Dynamic) {}
		final arrived = function():Void {
			if (runtime != null && __threadToken() != home) {
				runtime.__post(finish);
			} else {
				finish();
			}
		};
		future.then(_ -> arrived(), _ -> arrived());
		#else
		future.then(_ -> finish(), _ -> finish());
		#end
	}

	#if (cpp || neko || hl || java || jvm || eval)
	@:noCompletion private static function __threadToken():{} {
		var token:Null<{}> = __threadTokens.value;
		if (token == null) {
			token = {};
			__threadTokens.value = token;
		}
		return token;
	}
	#end

	/**
		What a failed future failed with, as an exception: its cause, or else
		its message, wrapped in one when it is not one already.
	**/
	@:noCompletion private static function __failureOf<T>(future:Future<T>):haxe.Exception {
		return @:privateAccess haxe.Exception.caught(future.cause != null ? future.cause : future.error);
	}

	/** The failure a call answered later settles with when `handlerTimeout` passes first. **/
	@:noCompletion private static function __handlerTimedOut<T>():Future<T> {
		final timedOut = new Future<T>();
		// Read at once, by whoever settles with it: not a failure nobody heard.
		timedOut.__failureObserved = true;
		timedOut.__fail(RPCError.TIMEOUT_MESSAGE, new RPCTimeoutError());
		return timedOut;
	}

	/**
	 * Whether `beforeRuntimeCall` lets a call run. A refused request is
	 * answered with the refusal, and a hook that throws fails the call.
	 */
	@:noCompletion private function __admitRuntimeCall(op:Int, requestId:Int, payloadSize:Int):Bool {
		var refusal:Null<RPCError> = null;
		try {
			refusal = beforeRuntimeCall(op, requestId, payloadSize);
		} catch (error:haxe.Exception) {
			if (requestId != 0) {
				__sendRuntimeError(op, requestId, RPCError.INTERNAL_MESSAGE);
			}
			__reportHandlerError(op, null, error);
			return false;
		}
		if (refusal == null) {
			return true;
		}
		if (requestId != 0) {
			__sendRuntimeError(op, requestId, refusal.message != null ? refusal.message : RPCError.INTERNAL_MESSAGE);
		}
		return false;
	}

	/** An `RPCError`'s message, which its caller is meant to see, or `null`. **/
	@:noCompletion private static function __answerFor(error:haxe.Exception):Null<String> {
		final refusal:Null<RPCError> = Std.downcast(error, RPCError);
		return refusal != null ? refusal.message : null;
	}

	@:noCompletion private function __reportHandlerError(op:Int, method:Null<String>, error:haxe.Exception):Void {
		try {
			onHandlerError(op, method, error);
		} catch (_:Dynamic) {}
	}

	/**
		A runtime call's frame: a request with `requestId`, or a one-way call
		when it is 0.

		@throws String When an argument is of a type the runtime lane does not
		carry; nothing is held for it.
	**/
	@:noCompletion private function __runtimeFrame(op:Int, requestId:Int, args:Array<Dynamic>):RPCFrame {
		final framed:RPCFrame = __takeFrame(RUNTIME_ROOM, RPCWire.FLAG_RUNTIME | (requestId != 0 ? RPCWire.FLAG_REQUEST : 0), op, requestId);
		try {
			RPCRuntimeCodec.writeArgs(framed, args);
		} catch (error:Dynamic) {
			__sent(framed);
			throw error;
		}
		return framed.finish();
	}

	/** Room a runtime frame is begun with: it grows as its values are written. **/
	@:noCompletion private static inline final RUNTIME_ROOM:Int = 64;

	/** One over `maxFrameLength` throws, as `__sendAnswer` does. **/
	@:noCompletion private function __sendRuntimeResponse(op:Int, requestId:Int, value:Dynamic):Void {
		final framed:RPCFrame = __takeFrame(RUNTIME_ROOM, RPCWire.FLAG_RUNTIME | RPCWire.FLAG_RESPONSE, op, requestId);
		try {
			RPCRuntimeCodec.writeValue(framed, value);
		} catch (error:Dynamic) {
			__sent(framed);
			throw error;
		}
		framed.finish();
		if (__oversized(framed)) {
			final message:String = __oversizedMessage("RPC answer", framed);
			__sent(framed);
			throw new ArgumentError(message);
		}
		if (__ended) {
			__sent(framed);
		} else {
			__sendFrame(framed);
		}
	}

	@:noCompletion private function __sendRuntimeError(op:Int, requestId:Int, message:String):Void {
		if (__ended) {
			return;
		}
		__sendError(RPCWire.FLAG_RUNTIME | RPCWire.FLAG_RESPONSE | RPCWire.FLAG_ERROR, op, requestId, message);
	}

	@:noCompletion private function __trackRuntimeResponse(requestId:Int, response:RPCResponse<Dynamic>):Void {
		if (__runtimePendingResponse == null) {
			__runtimePendingResponseId = requestId;
			__runtimePendingResponse = response;
		} else {
			if (__runtimePendingResponses == null) {
				__runtimePendingResponses = new RPCPendingCalls();
			}
			// An id nothing waits under: see __nextRuntimeRequestId.
			__runtimePendingResponses.put(requestId, response);
			__runtimePendingCount++;
		}
		// A call waiting can only start the session reading.
		if (__readState != READ_ON) {
			__syncOnDataBinding();
		}
	}

	@:noCompletion private function __resolveRuntimeResponse<T>(op:Int, requestId:Int, value:T):Void {
		final response = __takeRuntimeResponse(requestId);
		if (response == null) {
			return;
		}
		if (response.op != op) {
			__answeredForAnotherOp(response, op);
			return;
		}
		(cast response : RPCResponse<T>).__resolve(value);
	}

	@:noCompletion private function __rejectRuntimeResponse(op:Int, requestId:Int, message:String):Void {
		final response = __takeRuntimeResponse(requestId);
		if (response == null) {
			return;
		}
		if (response.op != op) {
			__answeredForAnotherOp(response, op);
			return;
		}
		// The other side's handler meant its caller to see this, so it fails
		// with an RPCError: a handler here answering with this response passes
		// the message on, as it would one it threw.
		response.__fail(message, new RPCError(message));
	}

	/**
		A response under `response`'s id for another op, `op`, is not its
		answer, and its value is not of its type.

		Responses are matched by id and checked by op. Each caller numbers its
		calls from 1, so a peer answering one caller's call on another's
		connection would complete that caller's own call with the wrong answer
		(a `String` call resolved with an `Int`). The call fails instead, since
		the one answer it could have had is spent.
	**/
	@:noCompletion private static function __answeredForAnotherOp(response:RPCResponse<Dynamic>, op:Int):Void {
		response.__fail('RPC response for op $op does not answer call ${response.requestId}, which was for op ${response.op}', null);
	}

	@:noCompletion private function __takeRuntimeResponse(requestId:Int):RPCResponse<Dynamic> {
		var response:RPCResponse<Dynamic> = null;
		if (__runtimePendingResponse != null && requestId == __runtimePendingResponseId) {
			response = __runtimePendingResponse;
			__runtimePendingResponse = null;
			__runtimePendingResponseId = 0;
		} else if (__runtimePendingResponses != null) {
			response = __runtimePendingResponses.take(requestId);
			if (response != null) {
				__runtimePendingCount--;
			}
		}
		// One no longer waiting can only stop it, and only when nothing else
		// keeps it reading.
		if (__handler == null && __commands == null && !__active) {
			__syncOnDataBinding();
		}
		return response;
	}

	@:noCompletion private function __nextRuntimeRequestId():Int {
		do {
			// `| 0` so the increment wraps on JavaScript too; see
			// RPCCommands.__nextRequestId.
			__runtimeRequestIdSeed = (__runtimeRequestIdSeed + 1) | 0;
			if (__runtimeRequestIdSeed <= 0) {
				__runtimeRequestIdSeed = 1;
			}
		} while ((__runtimeRequestIdSeed == __runtimePendingResponseId)
			|| (__runtimePendingResponses != null && __runtimePendingResponses.has(__runtimeRequestIdSeed)));

		return __runtimeRequestIdSeed;
	}

	/**
	 * Rejects and clears every outstanding runtime `RPCResponse` with the given reason.
	 *
	 * Drains pending runtime request/response calls so callers are not left waiting on
	 * a reply that can no longer arrive. Must only be called on the owning thread.
	 */
	@:noCompletion private function __failAllRuntimePending(message:String, ?cause:Dynamic):Void {
		final pending = __runtimePendingResponse;
		if (pending != null) {
			__runtimePendingResponse = null;
			__runtimePendingResponseId = 0;
			pending.__fail(message, cause);
		}
		final waiting = __runtimePendingResponses;
		if (waiting != null) {
			__runtimePendingResponses = null;
			__runtimePendingCount = 0;
			waiting.failAll(message, cause);
		}
	}

	/**
	 * Rejects and clears every outstanding response on both the compiled command lane
	 * and the runtime lane.
	 *
	 * This is invoked when the session is stopped or the underlying connection closes,
	 * ensuring no `RPCResponse` is left perpetually uncompleted. Must only be called on
	 * the owning thread.
	 *
	 * `cause` is the `Reason` the connection ended with, when it did: a call that
	 * failed as its connection went carried a message and nothing a caller could
	 * decide by, and a gateway could not tell a backend gone from a refusal.
	 */
	@:noCompletion private function __failAllPending(message:String, ?cause:Dynamic):Void {
		// Every call it holds fails here, so the queue is let go of first.
		if (__deadlines != null) {
			__deadlines.clear();
		}
		if (__commands != null) {
			__commands.__failAllPending(message, cause);
		}
		__failAllRuntimePending(message, cause);
	}

	/**
	 * Starts the session's heartbeat: a `ping` every `heartbeatInterval`
	 * milliseconds when nothing else has been sent, and the connection
	 * closed when nothing has arrived for `heartbeatTimeout`. Every session
	 * answers a ping, so an idle peer is heard from all the same.
	 *
	 * A session with or without commands has one. Started before its
	 * connection is up, it begins once the connection is ready. Started
	 * again, it carries on as it was.
	 *
	 * @return `true` if the underlying connection was already connected at start time.
	 */
	public function start():Bool {
		final connected:Bool = __connection.connected;
		if (!__active) {
			__active = true;
			__heartbeatPhase = __calculateHeartbeatPhase();
			// It reads its connection now, whatever it has bound, to hear
			// the answers to its pings.
			__syncOnDataBinding();
		}
		if (connected && !__ended && !__hasHeartbeat) {
			__resumeHeartbeat();
		}
		return connected;
	}

	/**
		Stops the heartbeat `start()` began, without closing the connection,
		and fails every call this session has waiting on an answer (on
		both lanes) with "RPC session stopped": an answer arriving for one
		later is dropped. Calls made after this go out and are answered as
		usual. A session with nothing else to read for stops reading its
		connection.
	**/
	public function stop():Void {
		__active = false;
		__stopHeartbeat();
		__syncOnDataBinding();
		__failAllPending("RPC session stopped");
	}

	/**
		The connection has become ready: a heartbeat asked for before it was
		starts now, and a connection that had ended (a `LocalConnection`
		listening again, which takes its next peer on the same object) is
		answered on again.

		What was waiting from the last peer stays on its own life of the
		connection, and answers nobody.
	**/
	@:noCompletion private function __connectionReady():Void {
		if (__isUp) {
			return;
		}
		__isUp = true;
		if (__ended) {
			__ended = false;
			__endReason = null;
		}
		// Ahead of anything onUp sends.
		__sendHello();
		__redialDelay = MIN_REDIAL;
		if (__active && !__hasHeartbeat) {
			__resumeHeartbeat();
		}
		try {
			onUp();
		} catch (error:Dynamic) {
			Logger.error("RPCSession.onUp threw: " + Std.string(error));
		}
	}

	@:noCompletion private inline function __stopHeartbeat():Void {
		// Guard against clearing an unstarted/already-cleared handle, which keeps
		// stop() safe and idempotent even when no heartbeat was ever scheduled.
		// The sentinel is TimerHandle.INVALID, not 0: slot 0 of generation 0 is
		// handle 0, so with 0 as the sentinel a session whose heartbeat was the
		// scheduler's first timer could never be stopped.
		if (__heartbeatTimerHandle != TimerHandle.INVALID) {
			Timer.clear(__heartbeatTimerHandle);
			__heartbeatTimerHandle = TimerHandle.INVALID;
		}
		__hasHeartbeat = false;
	}

	/**
		Schedules the heartbeat, which is not running. Its phase spreads the
		sessions of one process across the interval, so a server's heartbeats
		do not all fall on one tick.

		What it has heard is counted from now as well as from the last
		arrival: a connection starts having heard nothing, at 0, so a peer
		that never sent a byte is timed out too.
	**/
	@:noCompletion private function __resumeHeartbeat():Void {
		__hasHeartbeat = true;
		__intervalSec = __heartbeatInterval / 1000;
		__timeoutSec = __heartbeatTimeout / 1000;
		__heardSince = Timer.getTime();
		__heartbeatTimerHandle = Timer.setInterval(__heartbeatPhase / 1000, __intervalSec, __onHeartbeat);
	}

	@:noCompletion private inline function __calculateHeartbeatPhase():Int {
		@:privateAccess
		var step:Int = Std.int(CrossByte.current().__tickInterval);
		var phase:Int = Bucket.phaseFromHash(__getHeartbeatKeyHash(), __heartbeatInterval, step);
		return phase;
	}

	@:noCompletion private inline function __getHeartbeatKeyHash():Int {
		var rAddr:String = (connection.remoteAddress == null ? "" : connection.remoteAddress);
		var lAddr:String = (connection.localAddress == null ? "" : connection.localAddress);
		var rPort:Int = connection.remotePort & 0xFFFF;
		var lPort:Int = connection.localPort & 0xFFFF;
		var key:String = rAddr + lAddr + rPort + lPort;
		var hash:Int = Hash.fnv1a32String(key);
		return Hash.combineHash32(HEARTBEAT_SALT, hash);
	}

	/**
		A beat: the connection closed if nothing has arrived for the timeout,
		and otherwise a ping if nothing has been sent for an interval.

		It logged five lines at INFO for every session on every beat.
	**/
	@:noCompletion private function __onHeartbeat():Void {
		if (__ended) {
			__stopHeartbeat();
			return;
		}
		final now:Float = Timer.getTime();
		final lastIn:Float = __connection.inTimestamp;
		final heard:Float = lastIn > __heardSince ? lastIn : __heardSince;
		if (now - heard >= __timeoutSec) {
			__timedOut(now - heard);
			return;
		}
		// An interval less a millisecond: the beat after a ping is an interval
		// after it, and the clock's rounding can put that a hair short (2.8 -
		// 1.8 is 0.99999999999999978), which would send a ping every other
		// beat: a session pinging at 45 seconds against a 90-second timeout
		// would hear its pongs 90 seconds apart, and could time out a healthy
		// peer.
		if (now - __connection.outTimestamp >= __intervalSec - BEAT_SLACK) {
			__sendPing();
		}
	}

	/** How much short of an interval since the last send still owes a ping; see `__onHeartbeat`. **/
	@:noCompletion private static inline final BEAT_SLACK:Float = 0.001;

	/** A ping: a one-way frame for `ping`, with no arguments. **/
	@:noCompletion private function __sendPing():Void {
		final framed:RPCFrame = __takeFrame(RPCWire.MIN_PAYLOAD_LEN + 4, 0, RPCWire.PING_OP, 0).finish();
		try {
			__connection.send(framed);
		} catch (_:Dynamic) {
			// A connection that can take nothing more says so as it ends,
			// which stops this. A beat does not throw out of the tick.
		}
		__sent(framed);
	}

	/**
		Answers a ping with a pong: a response frame for `ping` under request
		id 0, so a client heartbeating a server that only answers calls hears
		from it between calls.
	**/
	@:noCompletion private function __answerPing():Void {
		if (__ended) {
			return;
		}
		final framed:RPCFrame = __takeFrame(RPCWire.MIN_PAYLOAD_LEN + 5, RPCWire.FLAG_RESPONSE, RPCWire.PING_OP, 0);
		// Request id 0, which answers no call.
		framed.putVarUInt(0);
		__sendFrame(framed.finish());
	}

	/**
		Nothing has arrived for the heartbeat's timeout: the calls waiting
		fail, saying so, and the connection is closed, which tells the
		application once, with the reason its transport gives for a close.
	**/
	@:noCompletion private function __timedOut(silence:Float):Void {
		__stopHeartbeat();
		if (Logger.isEnabled(LogLevel.DEBUG)) {
			Logger.debug('RPC session $sessionId heard nothing for $silence s; closing its connection');
		}
		__failAllPending("RPC connection timed out: nothing arrived for " + __heartbeatTimeout + " ms", Reason.Timeout);
		// Closed as the timeout it is, so the connection's `onClose`, a host's
		// `onDisconnect` and this session's `onDown` hear `Timeout`, not the
		// `Closed` an application's own close() says.
		try {
			(__connection : NetConnectionBase).__closeWith(Reason.Timeout);
		} catch (_:Dynamic) {}
		// A connection whose close says nothing (some of an application's
		// own) has ended all the same.
		if (!__ended) {
			__connectionEnded(Reason.Timeout);
		}
	}

	@:noCompletion private inline function __terminateProtocol(reason:Reason):Void {
		__failAllPending("RPC connection terminated: " + Std.string(reason), reason);
		try {
			__connection.onError(reason);
		} catch (_:Dynamic) {}
		try {
			(__connection : NetConnectionBase).__closeWith(reason);
		} catch (_:Dynamic) {}
	}
}

/**
	A call answered later, held to its session's `handlerTimeout`: settled
	once, by the future completing or the deadline passing, whichever is
	first. Both are told on the session's thread.

	Without it, a future that never completed would hold its place among
	the calls waiting, and its caller, for as long as the connection lasted.
	An object of its own rather than state its closures share, which hxcpp
	would box a field at a time, and only for a session with a deadline.
**/
@:access(crossbyte.rpc.RPCSession)
@:access(crossbyte.Future)
private class HandlerDeadline<T> {
	/** `timer` while the deadline is in its session's `HandlerDeadlines`. **/
	public static inline final QUEUED:Int = -2;

	final session:RPCSession<Dynamic, Dynamic>;
	final future:Future<T>;
	final settle:Future<T>->Void;
	var settled:Bool = false;
	// A timer of its own, QUEUED while its session's queue holds it instead,
	// or TimerHandle.INVALID once neither does.
	var timer:Int = TimerHandle.INVALID;
	// Its place in that queue, and when it falls due there.
	public var previous:Null<HandlerDeadline<Dynamic>> = null;
	public var next:Null<HandlerDeadline<Dynamic>> = null;
	public var due:Float = 0.0;

	public function new(session:RPCSession<Dynamic, Dynamic>, future:Future<T>, settle:Future<T>->Void, milliseconds:Int) {
		this.session = session;
		this.future = future;
		this.settle = settle;
		var queue:Null<HandlerDeadlines> = session.__handlerDeadlines;
		if (queue == null) {
			queue = session.__handlerDeadlines = new HandlerDeadlines();
		}
		if (queue.add(cast this, milliseconds)) {
			timer = QUEUED;
		} else {
			timer = Timer.setTimeout(milliseconds / 1000, expire);
		}
	}

	/** The future has completed. **/
	public function finish():Void {
		if (settled) {
			return;
		}
		settled = true;
		if (timer == QUEUED) {
			session.__handlerDeadlines.remove(cast this);
		} else if (timer != TimerHandle.INVALID) {
			Timer.clear(timer);
		}
		timer = TimerHandle.INVALID;
		session.__callsWaiting--;
		settle(future);
	}

	public function expire():Void {
		timer = TimerHandle.INVALID;
		if (settled) {
			return;
		}
		settled = true;
		session.__callsWaiting--;
		settle(RPCSession.__handlerTimedOut());
	}
}

/**
	A session's `handlerTimeout` deadlines, in the order their calls came
	(which, with one timeout for all of them, is the order they fall due),
	and one timer for them all, set for the first, rather than a timer, a
	closure and a timer node for each call. A call settled leaves the list
	at once.

	The timer, when it fires, answers for the calls that are due, at the
	time a timer of their own would have fired, and is set for the next. A
	deadline that would fall before the last one (`handlerTimeout`
	lowered between calls) is not queued, and arms its own.
**/
@:access(crossbyte.rpc.RPCSession)
private class HandlerDeadlines {
	/** How much past its time the scheduler still counts a timer due: theirs, so these fall due with it. **/
	static inline final DUE_EPSILON:Float = 1e-9;

	var first:Null<HandlerDeadline<Dynamic>> = null;
	var last:Null<HandlerDeadline<Dynamic>> = null;
	var timer:Int = TimerHandle.INVALID;
	var firing:Bool = false;
	final fire:Void->Void;

	public function new() {
		fire = fired;
	}

	/** Queues `deadline`, `milliseconds` from now; `false`, queuing nothing, when it would fall before the last. **/
	public function add(deadline:HandlerDeadline<Dynamic>, milliseconds:Int):Bool {
		final now:Float = Timer.getTime();
		final due:Float = now + milliseconds / 1000;
		final tail:Null<HandlerDeadline<Dynamic>> = last;
		if (tail != null && due < tail.due) {
			return false;
		}
		deadline.due = due;
		deadline.previous = tail;
		if (tail != null) {
			tail.next = deadline;
		} else {
			first = deadline;
		}
		last = deadline;
		if (timer == TimerHandle.INVALID && !firing) {
			timer = Timer.setTimeout(due - now, fire);
		}
		return true;
	}

	public function remove(deadline:HandlerDeadline<Dynamic>):Void {
		final previous = deadline.previous;
		final next = deadline.next;
		if (previous != null) {
			previous.next = next;
		} else {
			first = next;
		}
		if (next != null) {
			next.previous = previous;
		} else {
			last = previous;
		}
		deadline.previous = null;
		deadline.next = null;
	}

	/** The timer: every call that is due is answered for, and the timer is set for the next. **/
	function fired():Void {
		timer = TimerHandle.INVALID;
		firing = true;
		final now:Float = Timer.getTime();
		var failed:Bool = false;
		var failure:Dynamic = null;
		while (first != null && first.due <= now + DUE_EPSILON) {
			final deadline = first;
			remove(deadline);
			try {
				deadline.expire();
			} catch (error:Dynamic) {
				// The rest are still answered for, and the timer set again,
				// before the scheduler hears of it.
				if (!failed) {
					failed = true;
					failure = error;
				}
			}
		}
		firing = false;
		if (first != null && timer == TimerHandle.INVALID) {
			timer = Timer.setTimeout(first.due - Timer.getTime(), fire);
		}
		if (failed) {
			throw failure;
		}
	}
}

/**
	What a session made by `RPCSession.dial` holds before its first
	connection: never connected, sending nothing, closing nothing.
**/
private class Unconnected extends NetConnectionBase implements INetConnection {
	public var remoteAddress(get, never):String;
	public var remotePort(get, never):Int;
	public var localAddress(get, never):String;
	public var localPort(get, never):Int;
	public var connected(get, never):Bool;
	public var readEnabled(get, set):Bool;
	public var onData(get, set):ByteArrayInput->Void;
	public var onClose(get, set):Reason->Void;
	public var onError(get, set):Reason->Void;
	public var onReady(get, set):Void->Void;

	final __uri:String;
	var __readEnabled:Bool = false;
	var __onData:ByteArrayInput->Void = null;
	var __onClose:Reason->Void = null;
	var __onError:Reason->Void = null;
	var __onReady:Void->Void = null;

	public function new(uri:String) {
		__uri = uri;
		protocol = TCP;
	}

	public function expose():Transport {
		return null;
	}

	public function send(data:ByteArray):Void {
		throw new IOError("Not connected to " + __uri);
	}

	public function close():Void {}

	inline function get_remoteAddress():String {
		return __uri;
	}

	inline function get_remotePort():Int {
		return 0;
	}

	inline function get_localAddress():String {
		return "";
	}

	inline function get_localPort():Int {
		return 0;
	}

	inline function get_connected():Bool {
		return false;
	}

	inline function get_readEnabled():Bool {
		return __readEnabled;
	}

	inline function set_readEnabled(value:Bool):Bool {
		return __readEnabled = value;
	}

	inline function get_onData():ByteArrayInput->Void {
		return __onData;
	}

	inline function set_onData(value:ByteArrayInput->Void):ByteArrayInput->Void {
		return __onData = value;
	}

	inline function get_onClose():Reason->Void {
		return __onClose;
	}

	inline function set_onClose(value:Reason->Void):Reason->Void {
		return __onClose = value;
	}

	inline function get_onError():Reason->Void {
		return __onError;
	}

	inline function set_onError(value:Reason->Void):Reason->Void {
		return __onError = value;
	}

	inline function get_onReady():Void->Void {
		return __onReady;
	}

	inline function set_onReady(value:Void->Void):Void->Void {
		return __onReady = value;
	}
}
