package crossbyte.rpc;

import crossbyte.net.Reason;
import crossbyte.utils.Logger;
import crossbyte.core.CrossByte;
import crossbyte.utils.Bucket;
import crossbyte.utils.Hash;
import crossbyte.sys.System;
import crossbyte.rpc.RPCHandler;
import crossbyte.rpc.RPCCommands;
import crossbyte.net.NetConnection;
import crossbyte.events.EventDispatcher;
import crossbyte.io.ByteArrayInput;
import crossbyte.rpc._internal.RPCWire;
#if neko
import sys.thread.Mutex;
#elseif (cpp || hl || java || cs)
import haxe.atomic.AtomicInt;
#end

@:access(crossbyte.rpc.RPCHandler)
@:access(crossbyte.rpc.RPCCommands)
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
	@:noCompletion private var __heartbeatTimerHandle:Int;
	@:noCompletion private var __heartbeatInterval:Int = DEFAULT_HEARTBEAT_INTERVAL;
	@:noCompletion private var __heartbeatTimeout:Int = DEFAULT_HEARTBEAT_TIMEOUT;
	@:noCompletion private var __heartbeatPhase:Int;
	@:noCompletion private var __active:Bool = false;
	@:noCompletion private var __hasHeartbeat:Bool = false;
	@:noCompletion private var __timeoutSec:Float = 0.0;
	@:noCompletion private var __intervalSec:Float = 0.0;

	#if neko
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
		#if (neko)
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
		if (__active && !__hasHeartbeat) {
			__resumeHeartbeat();
		}
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
			}
			if (commands != null) {
				commands.__nc = __connection;
			} else if (__hasHeartbeat) {
				__stopHeartbeat();
			}
			if (__handler != null) {
				__handler.this_commands = commands;
			}
			__syncOnDataBinding();
		}

		return __commands;
	}

	@:noCompletion private inline function set_handler(handler:RPCHandler):RPCHandler {
		if (__handler != null && handler != __handler) {
			__handler.this_connection = null;
			__handler.this_commands = null;
		}
		__handler = handler;
		if (handler != null) {
			handler.this_connection = this.connection;
			handler.this_commands = __commands;
		}
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
		this.commands = commands;
		this.handler = handler;
	}

	@:noCompletion private inline function __syncOnDataBinding():Void {
		if (__handler != null) {
			__connection.onData = __handler.this_socket_onData;
			__connection.readEnabled = true;
			return;
		}

		if (__commands != null) {
			__connection.onData = __commands_socket_onData;
			__connection.readEnabled = true;
			return;
		}

		__connection.onData = input -> {};
		__connection.readEnabled = false;
	}

	@:noCompletion private inline function __commands_socket_onData(input:ByteArrayInput):Void {
		while (input.bytesAvailable >= 9) {
			final lenPos:Int = input.position;
			final payloadLen:Int = input.readInt();

			if (payloadLen < RPCWire.MIN_PAYLOAD_LEN || (RPCHandler.MAX_FRAME_LEN != 0 && payloadLen > RPCHandler.MAX_FRAME_LEN)) {
				input.position = input.length;
				return;
			}

			if (input.bytesAvailable < payloadLen) {
				input.position = lenPos;
				break;
			}

			final frameEnd:Int = input.position + payloadLen;
			final flags:Int = input.readByte();
			final op:Int = input.readInt();
			if (flags == RPCWire.FLAG_RESPONSE) {
				if (__commands != null) {
					__commands.__rpc_handle_response(op, input.readVarUInt(), input, false);
				}
			} else if (flags == (RPCWire.FLAG_RESPONSE | RPCWire.FLAG_ERROR)) {
				if (__commands != null) {
					__commands.__rpc_handle_response(op, input.readVarUInt(), input, true);
				}
			}
			input.position = frameEnd;
		}

		@:privateAccess final now:Float = Timer.tryGetTime();
		if (now >= 0.0) {
			__connection.inTimestamp = now;
		}
	}

	/**
	 * Starts session bookkeeping and enables heartbeats when a command surface is present.
	 *
	 * @return `true` if the underlying connection was already connected at start time.
	 */
	public inline function start():Bool {
		Logger.info('Session $sessionId started');
		var status:Bool = __connection.connected;
		this.__heartbeatPhase = __calculateHeartbeatPhase();
		if (status && commands != null) {
			__resumeHeartbeat();
		}

		__active = true;

		return status;
	}

	/** Stops heartbeat bookkeeping without closing the underlying connection. */
	public inline function stop():Void {
		__active = false;
		__stopHeartbeat();
	}

	@:noCompletion private inline function __stopHeartbeat():Void {
		Timer.clear(__heartbeatTimerHandle);
		__hasHeartbeat = false;
	}

	@:noCompletion private inline function __resumeHeartbeat():Void {
		Logger.info('Session $sessionId Heartbeat resumed');
		__hasHeartbeat = true;
		var jitter:Float = this.__heartbeatPhase / 1000;
		__intervalSec = this.__heartbeatInterval / 1000;
		Logger.info('With Jitter: $jitter and interval: $__intervalSec');
		Logger.separator();
		__timeoutSec = __heartbeatTimeout / 1000;
		this.__heartbeatTimerHandle = Timer.setInterval(jitter, __intervalSec, this.__onHeartbeat);
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

	@:noCompletion private inline function __onHeartbeat():Void {
		if (__validateSession()) {
			commands.ping();
		}
		Logger.info('Session $sessionId sent a Heartbeat');
	}

	@:noCompletion private inline function __validateSession():Bool {
		final now:Float = Timer.getTime();
		final lastIn:Float = __connection.inTimestamp;

		final base:Float = (lastIn > 0.0) ? lastIn : now;
		final due:Float = base + __timeoutSec;

		Logger.info('Validating session $sessionId');
		Logger.info('now=$now lastIn=$lastIn timeoutSec=$__timeoutSec nextDue=$due');
		Logger.info('Previous incoming message received at $lastIn; next due at $due');

		if (now >= due) {
			__disconnect(Reason.Timeout);
			return false;
		}
		Logger.separator();

		final lastOut:Float = __connection.outTimestamp;
		return now - lastOut >= __intervalSec;
	}

	@:noCompletion private inline function __disconnect(reason:Reason):Void {
		this.connection.close();
		this.connection.onClose(reason);
	}
}
