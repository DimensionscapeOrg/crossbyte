package crossbyte._internal.http;

import crossbyte.core.CrossByte;
#if target.threaded
import sys.thread.Mutex;
#end

/**
	The bytes of request body the servers started with one configuration
	hold at once, across every connection and runtime, held to
	`HTTPServerConfig.maxRequestBodyMemory`.

	A connection takes room as body arrives (`take`), and gives it back once
	the request is answered or given up (`release`). One that finds no room
	waits for it, its `BodyRoomWaiter` queued: an HTTP/1.1 connection stops
	reading and an HTTP/2 one stops opening its window, so the client is held
	back by flow control while it waits. Room let go goes to the waiters in
	the order they came, each told on its own runtime.

	A lock is taken per call, as a configuration can be shared by servers on
	several runtimes' threads. Nothing is allocated under it: what allocates
	there can deadlock hxcpp's collector against a thread waiting on it.
**/
@:noCompletion
final class RequestBodyMemory {
	/**
		Room is given to a waiter only once this much of what it wants is
		free, or all of it: a waiter woken for a few bytes at a time would
		cost a wake for each.
	**/
	public static inline var MIN_GRANT:Int = 16 * 1024;

	// What maxRequestBodyMemory says, and the size of the largest body taken,
	// which always fits.
	private var __limit:Int = 0;
	private var __floor:Int = 0;
	// The two together: 0 and below for no limit.
	private var __cap:Int = 0;
	// Held now. A Float: forced charges may take it past the cap, and across
	// many connections past 2^31.
	private var __used:Float = 0.0;
	private var __head:Null<BodyRoomWaiter> = null;
	private var __tail:Null<BodyRoomWaiter> = null;
	#if target.threaded
	private final __lock:Mutex = new Mutex();
	#end

	/** Counted each time a connection starts waiting for room; set by a server with metrics. */
	public var waits:Null<crossbyte.metrics.Counter> = null;

	/** Counted each request refused for want of room at its deadline; set by a server with metrics. */
	public var refusals:Null<crossbyte.metrics.Counter> = null;

	public function new(limit:Int, floor:Int) {
		__limit = limit;
		__floor = floor;
		__cap = __capOf(limit, floor);
	}

	private static inline function __capOf(limit:Int, floor:Int):Int {
		return limit <= 0 ? 0 : (limit > floor ? limit : floor);
	}

	/** Whether anything is held to a limit at all. Read without the lock: a stale answer only takes or skips one count. */
	public var active(get, never):Bool;

	private inline function get_active():Bool {
		return __cap > 0;
	}

	/** Bytes held now. */
	public var held(get, never):Float;

	private function get_held():Float {
		__acquire();
		var used:Float = __used;
		__release();
		return used;
	}

	/** Sets the limit and the largest body, and gives any room that makes to the waiters. */
	public function configure(limit:Int, floor:Int):Void {
		__acquire();
		__limit = limit;
		__floor = floor;
		var was:Int = __cap;
		__cap = __capOf(limit, floor);
		var woken:Null<BodyRoomWaiter> = __cap <= 0 ? __drainAll() : (__cap > was || was <= 0 ? __serve() : null);
		__release();
		__wake(woken);
	}

	public inline function limit():Int {
		return __limit;
	}

	public inline function floor():Int {
		return __floor;
	}

	/**
		Takes up to `want` bytes of room, and says how much it took. Less
		than `want` queues `waiter` for the rest, unless it is queued
		already; while others are queued nothing is taken, so the room they
		wait for goes to them first. With no limit, all of `want` is taken,
		and counted all the same, so `held` says what is held either way.
	**/
	public function take(want:Int, waiter:BodyRoomWaiter):Int {
		if (want <= 0) {
			return 0;
		}
		__acquire();
		var given:Int = want;
		if (__cap > 0) {
			// A waiter queued already is woken for its room rather than taking
			// it here, and so is everyone while one is.
			given = 0;
			if (__head == null && !waiter.queued) {
				var room:Float = __cap - __used;
				if (room > 0) {
					given = room < want ? Std.int(room) : want;
				}
			}
		}
		__used += given;
		var queued:Bool = false;
		if (given < want && !waiter.queued) {
			waiter.want = want - given;
			waiter.queued = true;
			waiter.next = null;
			if (__tail == null) {
				__head = __tail = waiter;
			} else {
				__tail.next = waiter;
				__tail = waiter;
			}
			queued = true;
		}
		__release();
		if (queued && waits != null) {
			waits.inc();
		}
		return given;
	}

	/**
		Counts `bytes` held whatever room there is: what arrived before a
		connection could be stopped, or what a body grew to once decoded.
		Given back with `release`.
	**/
	public function charge(bytes:Int):Void {
		if (bytes <= 0) {
			return;
		}
		__acquire();
		__used += bytes;
		__release();
	}

	/** Gives back `bytes` taken or charged, and the room it makes to the waiters. */
	public function release(bytes:Int):Void {
		if (bytes <= 0) {
			return;
		}
		__acquire();
		__used -= bytes;
		if (__used < 0) {
			__used = 0.0;
		}
		var woken:Null<BodyRoomWaiter> = __serve();
		__release();
		__wake(woken);
	}

	/** What `waiter` has been given since it was last asked, which is now its holder's. */
	public function collect(waiter:BodyRoomWaiter):Int {
		__acquire();
		var given:Int = waiter.granted;
		waiter.granted = 0;
		__release();
		return given;
	}

	/** Takes `waiter` out of the queue, and gives back what it was given and has not collected. */
	public function cancel(waiter:BodyRoomWaiter):Void {
		__acquire();
		if (waiter.queued) {
			__unlink(waiter);
		}
		var given:Int = waiter.granted;
		waiter.granted = 0;
		__used -= given;
		if (__used < 0) {
			__used = 0.0;
		}
		var woken:Null<BodyRoomWaiter> = given > 0 ? __serve() : null;
		__release();
		__wake(woken);
	}

	/**
		Gives the room there is to the waiters in turn, each what it wants or
		as much as there is, while there is `MIN_GRANT` or all it wants, and
		takes them out of the queue. Under the lock, so they are told after,
		through the chain this returns.
	**/
	private function __serve():Null<BodyRoomWaiter> {
		var chain:Null<BodyRoomWaiter> = null;
		while (__head != null) {
			var waiter:BodyRoomWaiter = __head;
			var room:Float = __cap - __used;
			var least:Int = waiter.want < MIN_GRANT ? waiter.want : MIN_GRANT;
			if (room < least) {
				break;
			}
			var given:Int = room < waiter.want ? Std.int(room) : waiter.want;
			__used += given;
			waiter.granted += given;
			__unlink(waiter);
			chain = __chain(chain, waiter);
		}
		return chain;
	}

	/** Every waiter at once, the limit having been lifted: each is given what it wants. */
	private function __drainAll():Null<BodyRoomWaiter> {
		var chain:Null<BodyRoomWaiter> = null;
		while (__head != null) {
			var waiter:BodyRoomWaiter = __head;
			var wanted:Int = waiter.want;
			__used += wanted;
			waiter.granted += wanted;
			__unlink(waiter);
			chain = __chain(chain, waiter);
		}
		return chain;
	}

	/**
		Adds `waiter` to a chain of those to tell, unless it is on one already,
		still to be told by whoever made it: what it was given since is
		collected with the rest. Its own link, not the queue's, which its
		holder may queue it on again before it has been told.
	**/
	private static inline function __chain(chain:Null<BodyRoomWaiter>, waiter:BodyRoomWaiter):Null<BodyRoomWaiter> {
		if (waiter.toTell) {
			return chain;
		}
		waiter.toTell = true;
		waiter.nextToTell = chain;
		return waiter;
	}

	private function __unlink(waiter:BodyRoomWaiter):Void {
		var previous:Null<BodyRoomWaiter> = null;
		var at:Null<BodyRoomWaiter> = __head;
		while (at != null && at != waiter) {
			previous = at;
			at = at.next;
		}
		if (at == null) {
			waiter.queued = false;
			return;
		}
		if (previous == null) {
			__head = waiter.next;
		} else {
			previous.next = waiter.next;
		}
		if (__tail == waiter) {
			__tail = previous;
		}
		waiter.next = null;
		waiter.queued = false;
		waiter.want = 0;
	}

	/**
		Tells each waiter of a chain `__serve` made, on its runtime, outside
		the lock. One whose runtime has gone gives its room back.
	**/
	private function __wake(chain:Null<BodyRoomWaiter>):Void {
		var lost:Int = 0;
		while (chain != null) {
			// Taken off the chain under the lock, which another release may be
			// adding to it under.
			var waiter:BodyRoomWaiter = chain;
			__acquire();
			chain = waiter.nextToTell;
			waiter.nextToTell = null;
			waiter.toTell = false;
			__release();
			if (!waiter.tell()) {
				lost += collect(waiter);
			}
		}
		if (lost > 0) {
			release(lost);
		}
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

/**
	A connection waiting for room in a `RequestBodyMemory`: told with
	`onRoom` on `runtime` once it has been given some, which it takes with
	`collect`. Made once per connection and queued again as it needs.
**/
@:noCompletion
final class BodyRoomWaiter {
	public var want:Int = 0;
	public var granted:Int = 0;
	public var queued:Bool = false;
	public var next:Null<BodyRoomWaiter> = null;
	// On a chain of waiters to tell, and the next on it: see __chain.
	public var toTell:Bool = false;
	public var nextToTell:Null<BodyRoomWaiter> = null;

	private final __runtime:Null<CrossByte>;
	private final __onRoom:Void->Void;

	public function new(runtime:Null<CrossByte>, onRoom:Void->Void) {
		__runtime = runtime;
		__onRoom = onRoom;
	}

	/** Has `onRoom` called on its runtime; false when that runtime has gone. */
	public function tell():Bool {
		var runtime:Null<CrossByte> = __runtime != null ? __runtime : CrossByte.current();
		return runtime != null && runtime.post(__onRoom);
	}
}
