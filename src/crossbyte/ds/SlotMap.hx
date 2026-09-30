package crossbyte.ds;

import haxe.ds.Vector;

/**
 * A **growable** map structure with fast O(1) insert, remove, and access by handle.
 * Each element is associated with a generation-validated 32-bit handle to ensure safe access.
 *
 * Capacity grows in chunks up to `maxCapacity`. When no free slots remain:
 * - the map will attempt to grow (by `growthChunk`), and
 * - if already at `maxCapacity`, `insert()` throws `"SlotMap full"`.
 *
 * **Freed slots are reused oldest first.** A handle kept after its entry
 * died aliases whatever holds its slot once the slot's generation has come
 * round, after 2048 reuses of that slot. The free list handed back the slot
 * freed last, so one entity despawned and another spawned each tick reused
 * one slot every time and wrapped it in 34 seconds at 60 Hz. Now a slot waits
 * behind every other free one, and its generation comes round only after
 * 2048 times as many inserts as there are free slots.
 *
 * `null` is a value like any other: an entry inserted as `null` is held,
 * counted, visited by `forEach` and invalidated by `clear()`.
 */
final class SlotMap<T> {
	/**
	 * The current number of active (non-removed) elements.
	 */
	public var length(default, null):Int = 0;

	/**
	 * Current allocated slot capacity (can grow up to `maxCapacity`).
	 */
	public var capacity(get, never):Int;

	@:noCompletion private inline function get_capacity():Int {
		return __capacity;
	}

	/**
	 * Upper bound for slots; cannot exceed `(1 << SlotHandle.INDEX_BITS)`.
	 */
	public final maxCapacity:Int;

	/**
	 * Number of slots to add when growing.
	 */
	public var growthChunk(default, null):Int;

	// Marks a held slot in `__link`; a free one holds the next free slot.
	@:noCompletion private static inline var HELD:Int = -2;

	@:noCompletion private var __capacity:Int;
	@:noCompletion private var __values:Array<Null<T>>;
	@:noCompletion private var __gen:Vector<Int>;
	// Per slot: HELD, or for a free slot the one freed after it, -1 for the
	// last. So the free slots queue in the order they were freed, and whether
	// a slot is held does not depend on what value it holds, it did, and an
	// entry inserted as null survived clear() with its handle still good.
	@:noCompletion private var __link:Vector<Int>;
	@:noCompletion private var __freeHead:Int = -1;
	@:noCompletion private var __freeTail:Int = -1;

	/**
	 * Creates a new (growable) SlotMap.
	 *
	 * @param initialCapacity The initial number of slots to allocate (must be > 0).
	 * @param maxCapacity     Optional hard ceiling for total slots. Defaults to `(1 << SlotHandle.INDEX_BITS)`.
	 * @param growthChunk     Optional growth step (slots added when full). Defaults to 1024 (min 1).
	 */
	public function new(initialCapacity:Int, ?maxCapacity:Int, ?growthChunk:Int = 1024) {
		if (initialCapacity <= 0) {
			throw "initialCapacity must be > 0";
		}

		var hardMax:Int = (1 << SlotHandle.INDEX_BITS);
		this.maxCapacity = (maxCapacity == null) ? hardMax : maxCapacity;
		if (this.maxCapacity > hardMax) {
			throw "maxCapacity exceeds handle index space";
		}

		if (initialCapacity > this.maxCapacity) {
			throw "initialCapacity > maxCapacity";
		}

		this.growthChunk = (growthChunk == null || growthChunk <= 0) ? 1 : growthChunk;

		__capacity = 0;
		__values = [];
		__gen = new Vector<Int>(0);
		__link = new Vector<Int>(0);
		growInternal(initialCapacity);
	}

	/**
	 * Inserts a value into the map and returns a handle referencing it.
	 *
	 * Attempts to grow if no free slots remain. Throws only if already at `maxCapacity`.
	 *
	 * @param v The value to insert.
	 * @return A SlotHandle that can be used to access or remove the value.
	 * @throws Error if the map is at max capacity and cannot grow.
	 */
	public inline function insert(v:T):SlotHandle {
		if (__freeHead == -1) {
			growInternal(growthChunk);
			if (__freeHead == -1) {
				throw "SlotMap full";
			}
		}
		var i:Int = __freeHead;
		__freeHead = __link[i];
		if (__freeHead == -1) {
			__freeTail = -1;
		}
		__link[i] = HELD;
		__values[i] = v;
		length++;
		return SlotHandle.make(i, __gen[i]);
	}

	/**
	 * Removes a value from the map by handle.
	 *
	 * @param h The handle referencing the entry to remove.
	 * @return True if removed successfully, false if the handle was invalid or stale.
	 */
	public inline function remove(h:SlotHandle):Bool {
		var i:Int = h.index();
		if (i >= __capacity || __link[i] != HELD || __gen[i] != h.gen()) {
			return false;
		}

		__values[i] = null;
		// Wrapped inside the handle's generation field. Counting past it left
		// the slot holding a number no handle could ever carry, so every
		// later remove of that slot failed and the entry was never freed,
		// a map that leaks one slot per 256 reuses, which on anything with
		// entity churn is a leak that never stops.
		__gen[i] = (__gen[i] + 1) & SlotHandle.GEN_MASK;
		__queueFree(i);
		length--;
		return true;
	}

	/**
	 * Retrieves a value by handle.
	 *
	 * @param h The handle referencing the desired value.
	 * @return The value if found and valid, or null if the handle is invalid or stale.
	 */
	public inline function get(h:SlotHandle):Null<T> {
		var i:Int = h.index();
		// A free slot holds null, so its generation matching is enough.
		return (i < __capacity && __gen[i] == h.gen()) ? __values[i] : null;
	}

	/**
	 * Updates a value in the map by handle.
	 *
	 * @param h The handle referencing the entry.
	 * @param v The new value to assign.
	 * @return True if updated successfully, false if the handle is invalid or stale.
	 */
	public inline function set(h:SlotHandle, v:T):Bool {
		var i:Int = h.index();
		if (i >= __capacity || __link[i] != HELD || __gen[i] != h.gen()) {
			return false;
		}

		__values[i] = v;
		return true;
	}

	/**
	 * Iterates over all live entries in the map.
	 *
	 * @param f A callback that receives each handle and value.
	 */
	public inline function forEach(f:(SlotHandle, T) -> Void):Void {
		for (i in 0...__capacity) {
			if (__link[i] == HELD) {
				f(SlotHandle.make(i, __gen[i]), __values[i]);
			}
		}
	}

	/**
	 * Ensures capacity is at least `target`. If already large enough, this is a no-op.
	 * May grow the map (once or multiple chunk steps) up to `maxCapacity`.
	 *
	 * @param target The desired minimum capacity.
	 */
	public inline function ensureCapacity(target:Int):Void {
		if (target <= __capacity) {
			return;
		}

		var need:Int = target - __capacity;
		growInternal(need);
	}

	/**
	 * Clears all entries from the map and invalidates all existing handles.
	 */
	public function clear():Void {
		for (i in 0...__capacity) {
			if (__link[i] == HELD) {
				// Kept inside the handle's generation field, as remove() keeps
				// it. Counted past it here, a slot at the top of its range held
				// a generation no handle could carry, so every entry put in it
				// after the clear() could never be read or removed again, the
				// leak remove() was fixed for, back by another door.
				__gen[i] = (__gen[i] + 1) & SlotHandle.GEN_MASK;
			}

			__values[i] = null;
			__link[i] = i + 1 < __capacity ? i + 1 : -1;
		}
		__freeHead = __capacity > 0 ? 0 : -1;
		__freeTail = __capacity - 1;
		length = 0;
	}

	/**
	 * Provides raw access to the internal value array.
	 * Unsafe: does not check generation. Use with caution.
	 *
	 * @param index The raw index of the slot.
	 * @return The value at the index, regardless of generation.
	 */
	public inline function getAtUnsafe(index:Int):Null<T> {
		return __values[index];
	}

	public inline function toString():String {
		return __values.toString();
	}

	public inline function getValues():Array<T> {
		return __values;
	}

	@:noCompletion private inline function __queueFree(i:Int):Void {
		__link[i] = -1;
		if (__freeTail == -1) {
			__freeHead = i;
		} else {
			__link[__freeTail] = i;
		}
		__freeTail = i;
	}

	function growInternal(additional:Int):Void {
		if (additional <= 0) {
			return;
		}

		if (__capacity >= maxCapacity) {
			return;
		}

		var newCap:Int = __capacity + additional;
		if (newCap > maxCapacity) {
			newCap = maxCapacity;
		}

		// The vectors double, so growing a chunk at a time copies each entry
		// a bounded number of times rather than once per chunk.
		if (newCap > __gen.length) {
			var room:Int = __gen.length * 2;
			if (room < newCap) {
				room = newCap;
			}
			if (room > maxCapacity) {
				room = maxCapacity;
			}
			var gen:Vector<Int> = new Vector<Int>(room);
			var link:Vector<Int> = new Vector<Int>(room);
			Vector.blit(__gen, 0, gen, 0, __capacity);
			Vector.blit(__link, 0, link, 0, __capacity);
			__gen = gen;
			__link = link;
		}

		__values[newCap - 1] = null;
		for (i in __capacity...newCap) {
			__values[i] = null;
			__gen[i] = 0;
			__queueFree(i);
		}

		__capacity = newCap;
	}
}
