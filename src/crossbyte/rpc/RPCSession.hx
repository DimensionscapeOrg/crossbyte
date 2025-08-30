package crossbyte.rpc;

import crossbyte.rpc.RPCHandler;
import crossbyte.rpc.RPCCommands;
import crossbyte.net.INetConnection;
import crossbyte.events.EventDispatcher;
#if neko
import sys.thread.Mutex;
#else
import haxe.atomic.AtomicInt;
#end

@:access(crossbyte.rpc.RPCHandler)
@:access(crossbyte.rpc.RPCCommands)
class RPCSession<C:RPCCommands = Dynamic> extends EventDispatcher {
	public final sessionId:String = __getSessionId();
	public var connection(get, never):INetConnection;
	public var handler(get, set):RPCHandler;
	public var commands(get, set):C;

	private var __connection:INetConnection;
	private var __handler:RPCHandler;
	private var __commands:C;

	#if neko
	@:noCompletion private static var __sidCounter:Int = 0;
	@:noCompletion private static var __sidLock:Null<Mutex> = new Mutex();
	#else
	@:noCompletion private static var __sidCounter:AtomicInt = new AtomicInt(0);
	#end

	@:noCompletion private static inline function __getSessionId():String {
		#if (neko)
		__sidLock.acquire();
		var id:Int = ++__sidCounter;
		__sidLock.release();
		return Std.string(id);
		#else
		return Std.string(__sidCounter.add(1));
		#end
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
			}
			if (commands != null) {
				commands.__nc = __connection;
			}
		}

		return __commands;
	}

	@:noCompletion private inline function set_handler(handler:RPCHandler):RPCHandler {
		if (__handler != null && handler != __handler) {
			connection.startReceiving();
		}
		__handler = handler;
		if (handler != null) {
			connection.onData = __handler.this_socket_onData;
			connection.startReceiving();
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

	public function new(connection:INetConnection, ?commands:RPCCommands, ?handler:RPCHandler) {
		super();
		__connection = connection;
		this.commands = cast commands;
		this.handler = handler;
	}
}
