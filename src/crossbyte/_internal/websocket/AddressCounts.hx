package crossbyte._internal.websocket;

/**
	Connections still arriving, counted by the peer's address: what
	`ServerWebSocket.maxPendingHandshakesPerAddress` is held to.

	One per server, shared by a server spread over runtimes (its listener
	counts each connection as it accepts it, and the runtime the connection
	goes to lets go of it once its upgrade has ended), so taken under a lock
	where there are threads. An address is kept only while it has a
	connection arriving.
**/
@:noCompletion
class AddressCounts {
	private var __counts:haxe.ds.StringMap<Int> = new haxe.ds.StringMap();
	#if target.threaded
	private var __lock:sys.thread.Mutex = new sys.thread.Mutex();
	#end

	public function new() {}

	/**
		Counts one more connection arriving from `address`, unless `limit`
		are counted already; `limit` of 0 or less counts it whatever the
		count. Whether it was counted.
	**/
	public function claim(address:String, limit:Int):Bool {
		__acquire();
		var count:Null<Int> = __counts.get(address);
		var now:Int = count == null ? 0 : count;
		var room:Bool = limit <= 0 || now < limit;
		if (room) {
			__counts.set(address, now + 1);
		}
		__release();
		return room;
	}

	/** One connection from `address` has stopped arriving. **/
	public function release(address:String):Void {
		if (address == null) {
			return;
		}
		__acquire();
		var count:Null<Int> = __counts.get(address);
		if (count != null) {
			if (count <= 1) {
				__counts.remove(address);
			} else {
				__counts.set(address, count - 1);
			}
		}
		__release();
	}

	/** How many connections from `address` are arriving. **/
	public function count(address:String):Int {
		__acquire();
		var count:Null<Int> = __counts.get(address);
		__release();
		return count == null ? 0 : count;
	}

	/** Forgets every count: the server has stopped taking connections. **/
	public function clear():Void {
		__acquire();
		__counts.clear();
		__release();
	}

	private inline function __acquire():Void {
		#if target.threaded
		__lock.acquire();
		#end
	}

	private inline function __release():Void {
		#if target.threaded
		__lock.release();
		#end
	}
}
