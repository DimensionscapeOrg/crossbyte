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
	only memory does, and then only by the entries that have expired unswept.

	What it holds is one object per entry and nothing per `touch`. The
	entries are kept on a list in the order their deadlines fall, and a
	`touch` moves one to the end. It used to leave a queue position behind
	for every `set` and `touch`, collected only once everything ahead of it
	had expired, so a map held its touches times its ttl rather than its
	entries: 1,000 sessions touched 20 times a second with a 120 s ttl held
	2.4 million positions, 70 MB on the jvm, however small `maxSize` was.

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
	/**
		How many entries are held, not counting any that have expired
		unswept. Reading it walks the expired ones at the front, and drops
		nothing: `sweep` does that.
	**/
	public var length(get, never):Int;

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

	private var __entries:Map<K, ExpiringEntry<K, V>>;

	// Every entry held, expired or not, on a list in the order their
	// deadlines fall. The deadline is always `ttl` from when the entry was
	// set or touched, so that is the order they were last set or touched in,
	// and keeping it costs a relink to the end.
	private var __first:ExpiringEntry<K, V>;
	private var __last:ExpiringEntry<K, V>;
	private var __held:Int = 0;

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
	}

	private function get_length():Int {
		var now:Float = __clock();
		var expired:Int = 0;
		var entry:ExpiringEntry<K, V> = __first;
		while (entry != null && now >= entry.deadline) {
			expired++;
			entry = entry.next;
		}
		return __held - expired;
	}

	/** Adds or replaces a value, and starts its life over. **/
	public function set(key:K, value:V):Void {
		var now:Float = __clock();
		var entry = __entries.get(key);

		if (entry == null) {
			entry = new ExpiringEntry(key, value, now + ttl);
			__entries.set(key, entry);
			__append(entry);
			__held++;
		} else {
			entry.value = value;
			entry.deadline = now + ttl;
			__unlink(entry);
			__append(entry);
		}

		if (maxSize > 0 && __held > maxSize) {
			__evictOldest();
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
			__drop(entry);
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
			__drop(entry);
			return false;
		}

		entry.deadline = now + ttl;
		if (entry != __last) {
			__unlink(entry);
			__append(entry);
		}
		return true;
	}

	/**
		Takes an entry out without calling `onExpire`.

		@return Whether anything was held, live or otherwise.
	**/
	public function remove(key:K):Bool {
		var entry = __entries.get(key);
		if (entry == null) {
			return false;
		}

		__entries.remove(key);
		__unlink(entry);
		__held--;
		return true;
	}

	/**
		Drops everything whose time has passed.

		Walks only the entries that have expired, rather than the whole map --
		so calling it every tick costs what has actually expired since the
		last one.

		@return How many went.
	**/
	public function sweep(?now:Float):Int {
		var at:Float = now == null ? __clock() : now;
		var dropped:Int = 0;

		while (__first != null && at >= __first.deadline) {
			__drop(__first);
			dropped++;
		}

		return dropped;
	}

	/** Every key with a live entry, the one due soonest first. **/
	public function keys():Iterator<K> {
		var live:Array<K> = [];
		var now:Float = __clock();
		var entry:ExpiringEntry<K, V> = __last;

		// From the newest back: the live ones are all after the expired.
		while (entry != null && now < entry.deadline) {
			live.push(entry.key);
			entry = entry.previous;
		}
		live.reverse();
		return live.iterator();
	}

	/** Drops everything, without calling `onExpire`. **/
	public function clear():Void {
		__entries = new Map();
		__first = null;
		__last = null;
		__held = 0;
	}

	// ------------------------------------------------------------------

	private function __drop(entry:ExpiringEntry<K, V>):Void {
		__entries.remove(entry.key);
		__unlink(entry);
		__held--;
		onExpire(entry.key, entry.value);
	}

	/** Makes room by dropping whatever is closest to expiring. **/
	private function __evictOldest():Void {
		while (__held > maxSize && __first != null) {
			__drop(__first);
		}
	}

	private inline function __append(entry:ExpiringEntry<K, V>):Void {
		entry.previous = __last;
		entry.next = null;
		if (__last == null) {
			__first = entry;
		} else {
			__last.next = entry;
		}
		__last = entry;
	}

	private inline function __unlink(entry:ExpiringEntry<K, V>):Void {
		if (entry.previous == null) {
			__first = entry.next;
		} else {
			entry.previous.next = entry.next;
		}
		if (entry.next == null) {
			__last = entry.previous;
		} else {
			entry.next.previous = entry.previous;
		}
		entry.previous = null;
		entry.next = null;
	}
}

/** One held value, with when it stops counting and its neighbours in deadline order. **/
private class ExpiringEntry<K, V> {
	public var key:K;
	public var value:V;
	public var deadline:Float;
	public var previous:ExpiringEntry<K, V>;
	public var next:ExpiringEntry<K, V>;

	public function new(key:K, value:V, deadline:Float) {
		this.key = key;
		this.value = value;
		this.deadline = deadline;
	}
}
