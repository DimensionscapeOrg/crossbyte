package crossbyte.ds;

/**
	A map whose entries stop being there after a while.

	For the things a server keeps on behalf of someone who may never come
	back: sessions, resumption tokens, pending handshakes, a cache of
	something expensive. Nothing else in `ds` evicts, so holding any of those
	meant a plain `Map` and a sweep the caller wrote, which is the shape that
	keeps entries for the life of the process when the sweep is forgotten.

	Bounded twice, and both matter. `ttl` bounds how long an entry stays;
	`maxSize` bounds how many there are, because time alone is not a bound
	when whoever is filling it can fill it faster than it drains. Reaching
	`maxSize` evicts whatever is closest to expiring.

	Expiry is not a timer. Nothing happens on its own: `sweep` does the work
	and a server calls it from its tick. Reading a single expired entry still
	reports it gone, so correctness does not depend on how often you sweep --
	only memory does.

	```haxe
	var sessions = new ExpiringMap<String, Session>(120, 50000);
	sessions.onExpire = (token, session) -> session.close();

	sessions.set(token, session);        // 120 seconds from now
	var live = sessions.get(token);      // null once it has passed
	sessions.touch(token);               // another 120 from now
	sessions.sweep();                    // called from the tick
	```
**/
@:generic
final class ExpiringMap<K:Dynamic, V> {
	/** How many entries are held, not counting any that have expired unswept. **/
	public var length(default, null):Int = 0;

	/** How long an entry lives from the moment it is set or touched. **/
	public var ttl(default, null):Float;

	/** The most entries held at once, or zero for no limit. **/
	public var maxSize(default, null):Int;

	/**
		Called for each entry as it goes, whether by time or by `maxSize`.

		Not called for an entry the caller removes itself, which the caller
		already knows about.
	**/
	public dynamic function onExpire(key:K, value:V):Void {}

	private var __entries:Map<K, ExpiringEntry<V>>;

	/**
		Keys in the order their deadlines fall.

		The deadline is always `ttl` from when the entry was stamped, so the
		order entries are stamped in is the order they expire in and `sweep`
		can stop at the first one still live. Touching a key stamps it again
		and leaves the old position behind; that position is recognised as
		stale by its stamp and skipped.
	**/
	private var __queue:Array<QueuedKey<K>>;

	/** How far `__queue` has been consumed; see `__compact`. **/
	private var __queueAt:Int = 0;

	private var __stamp:Int = 0;

	private var __clock:Void->Float;

	/**
		@param ttl How long an entry lives, in seconds.
		@param maxSize The most entries to hold at once; zero for no limit.
		@param clock Where the time comes from. Supply one in a test rather
		       than sleeping.
	**/
	public function new(ttl:Float, maxSize:Int = 0, ?clock:Void->Float) {
		if (ttl <= 0) {
			throw "ExpiringMap needs a positive ttl";
		}

		this.ttl = ttl;
		this.maxSize = maxSize < 0 ? 0 : maxSize;
		this.__clock = clock == null ? function():Float return haxe.Timer.stamp() : clock;
		this.__entries = new Map();
		this.__queue = [];
	}

	/** Adds or replaces a value, and starts its life over. **/
	public function set(key:K, value:V):Void {
		var existing = __entries.get(key);

		if (existing == null) {
			length++;
		}

		__stamp++;
		var now:Float = __clock();
		__entries.set(key, new ExpiringEntry(value, now + ttl, __stamp));
		__queue.push(new QueuedKey(key, __stamp));

		if (maxSize > 0 && length > maxSize) {
			__evictOldest(now);
		}
	}

	/**
		The value, or null once its time has passed.

		Does not extend anything. An entry that should live as long as it is
		being used wants `touch`, so that reading and extending stay separate
		decisions rather than one being a side effect of the other.
	**/
	public function get(key:K):Null<V> {
		var entry = __entries.get(key);

		if (entry == null) {
			return null;
		}

		if (__clock() >= entry.deadline) {
			__drop(key, entry);
			return null;
		}

		return entry.value;
	}

	/** Whether a live entry is held for this key. **/
	public function exists(key:K):Bool {
		return get(key) != null;
	}

	/** Starts an entry's life over. Returns false if there was nothing live. **/
	public function touch(key:K):Bool {
		var entry = __entries.get(key);

		if (entry == null) {
			return false;
		}

		var now:Float = __clock();

		if (now >= entry.deadline) {
			__drop(key, entry);
			return false;
		}

		__stamp++;
		entry.deadline = now + ttl;
		entry.stamp = __stamp;
		__queue.push(new QueuedKey(key, __stamp));
		return true;
	}

	/**
		Takes an entry out without calling `onExpire`.

		@return Whether anything was held, live or otherwise.
	**/
	public function remove(key:K):Bool {
		if (!__entries.exists(key)) {
			return false;
		}

		__entries.remove(key);
		length--;
		return true;
	}

	/**
		Drops everything whose time has passed.

		Walks only the entries that have expired, plus any positions left
		behind by `touch`, rather than the whole map -- so calling it every
		tick costs what has actually expired since the last one.

		@return How many went.
	**/
	public function sweep(?now:Float):Int {
		var at:Float = now == null ? __clock() : now;
		var dropped:Int = 0;

		while (__queueAt < __queue.length) {
			var queued = __queue[__queueAt];
			var entry = __entries.get(queued.key);

			// Gone already, or touched since and holding a later position.
			if (entry == null || entry.stamp != queued.stamp) {
				__queueAt++;
				continue;
			}

			if (at < entry.deadline) {
				break;
			}

			__queueAt++;
			__drop(queued.key, entry);
			dropped++;
		}

		__compact();
		return dropped;
	}

	/** Every key with a live entry. **/
	public function keys():Iterator<K> {
		var live:Array<K> = [];
		var now:Float = __clock();

		for (key in __entries.keys()) {
			var entry = __entries.get(key);

			if (entry != null && now < entry.deadline) {
				live.push(key);
			}
		}

		return live.iterator();
	}

	/** Drops everything, without calling `onExpire`. **/
	public function clear():Void {
		__entries = new Map();
		__queue = [];
		__queueAt = 0;
		length = 0;
	}

	// ------------------------------------------------------------------

	private function __drop(key:K, entry:ExpiringEntry<V>):Void {
		__entries.remove(key);
		length--;
		onExpire(key, entry.value);
	}

	/** Makes room by dropping whatever is closest to expiring. **/
	private function __evictOldest(now:Float):Void {
		while (length > maxSize && __queueAt < __queue.length) {
			var queued = __queue[__queueAt];
			var entry = __entries.get(queued.key);

			__queueAt++;

			if (entry == null || entry.stamp != queued.stamp) {
				continue;
			}

			__drop(queued.key, entry);
		}

		__compact();
	}

	/**
		Drops the consumed front of the queue.

		A cursor rather than taking entries off the front, which would be a
		pass over everything still queued for each entry that leaves.
	**/
	private function __compact():Void {
		if (__queueAt == 0) {
			return;
		}

		if (__queueAt >= __queue.length) {
			__queue = [];
			__queueAt = 0;
		} else if (__queueAt > 32 && __queueAt * 2 >= __queue.length) {
			__queue = __queue.slice(__queueAt);
			__queueAt = 0;
		}
	}
}

/** One held value, with when it stops counting and which position is current. **/
private class ExpiringEntry<V> {
	public var value:V;
	public var deadline:Float;
	public var stamp:Int;

	public function new(value:V, deadline:Float, stamp:Int) {
		this.value = value;
		this.deadline = deadline;
		this.stamp = stamp;
	}
}

/** A key's place in expiry order, and the stamp that says whether it is current. **/
private class QueuedKey<K> {
	public var key:K;
	public var stamp:Int;

	public function new(key:K, stamp:Int) {
		this.key = key;
		this.stamp = stamp;
	}
}
