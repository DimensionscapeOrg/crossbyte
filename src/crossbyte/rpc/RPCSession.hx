package crossbyte.rpc;

import crossbyte.net.Reason;
import crossbyte.utils.Logger;
import crossbyte.core.CrossByte;
import crossbyte.utils.Bucket;
import crossbyte.utils.Hash;
import crossbyte.sys.System;
import crossbyte.rpc.RPCHandler;
import crossbyte.rpc.RPCCommands;
import crossbyte.net.INetConnection;
import crossbyte.events.EventDispatcher;
import crossbyte.utils.Random;
#if neko
import sys.thread.Mutex;
#else
import haxe.atomic.AtomicInt;
#end

@:access(crossbyte.rpc.RPCHandler)
@:access(crossbyte.rpc.RPCCommands)
class RPCSession<C:RPCCommands = Dynamic, D = Dynamic> extends EventDispatcher {
	public static inline final DEFAULT_HEARTBEAT_INTERVAL:Int = 45000;
	public static inline final DEFAULT_HEARTBEAT_TIMEOUT:Int = 90000;
	public static inline final DEFAULT_HEARTBEAT_JITTER:Int = 5000;
	@:noCompletion private static final HEARTBEAT_SALT:Int = __getSalt();

	public final sessionId:Int = __getSessionId();
	public var connection(get, never):INetConnection;
	public var handler(get, set):RPCHandler;
	public var commands(get, set):C;
	public var heartbeatInterval(get, set):Int;
	public var heartbeatTimeout(get, set):Int;
	public var data:D;

	@:noCompletion private var __connection:INetConnection;
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
	#else
	@:noCompletion private static var __sidCounter:AtomicInt = new AtomicInt(0);
	#end

	@:noCompletion private static inline function __getSalt():Int {
		// TODO: load from persistant file if exists
		var id:String = System.getDeviceId();

		if (id != null) {
			id = StringTools.trim(id);
		}

		if (id == null || id.length == 0) {
			id = Random.randomString(16);
		}

		return Hash.fnv1a32String(id.toLowerCase());
	}

	@:noCompletion private static inline function __getSessionId():Int {
		#if (neko)
		__sidLock.acquire();
		var id:Int = ++__sidCounter;
		__sidLock.release();
		return id;
		#else
		return __sidCounter.add(1);
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
		}

		return __commands;
	}

	@:noCompletion private inline function set_handler(handler:RPCHandler):RPCHandler {
		if (__handler != null && handler != __handler) {
			__handler.this_connection = null;
			connection.readEnabled = true;
			handler.this_connection = this.connection;
		}
		__handler = handler;
		if (handler != null) {
			connection.onData = __handler.this_socket_onData;
			connection.readEnabled = true;
			handler.this_connection = this.connection;
		}

		return handler;
	}

	@:noCompletion private inline function get_connection():INetConnection {
		return __connection;
	}

	@:noCompletion private inline function get_handler():RPCHandler {
		return __handler;
	}

	@:noCompletion private inline function get_commands():C {
		return __commands;
	}

	public function new(connection:INetConnection, ?commands:C, ?handler:RPCHandler) {
		super();
		__connection = connection;
		this.commands = commands;
		this.handler = handler;
	}

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
