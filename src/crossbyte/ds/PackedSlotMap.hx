package crossbyte.ds;

/**
 * A packed, growable slot map with fast O(1) insertion, removal, and access using generation-validated handles.
 * 
 * PackedSlotMap maintains a densely packed array of values, suitable for iteration and cache-friendly access.
 * Handles are automatically invalidated when the slot is reused, protecting against use-after-free errors.
 *
 * Freed slots are reused oldest first, as in `SlotMap`, so a slot's
 * generation comes round, and a handle kept past its entry's death can
 * alias, only after 2048 times as many inserts as there are free slots,
 * not after 2048 inserts. 
 * @param T The type of values stored in the map.
 */
final class PackedSlotMap<T> {

    /**
	 * The current number of active elements stored in the map.
	 */
	public var length(get, never):Int;

    /**
	 * The current allocated capacity of the map. This can grow over time.
	 */
	public var capacity(get, never):Int;

    /**
	 * The maximum number of elements this map can grow to hold.
	 * Cannot exceed the maximum indexable space of SlotHandle.
	 */
	public final maxCapacity:Int;

    /**
	 * The number of slots to grow by when additional capacity is needed.
	 * A larger value can reduce allocation overhead.
	 */
	public var growthChunk(default, null):Int;

	@:noCompletion private var __values:Array<T> = [];
	@:noCompletion private var __denseToSlot:Array<Int> = [];
	// Per slot: where its value sits in the dense arrays, or, for a free
	// slot, a negative number, -1 for the last free slot, and -2 - next
	// for one the next free slot follows. So the free slots queue in the
	// order they were freed without an array of their own, and a slot is
	// free exactly when this is negative, as the rest of the class asks.
	@:noCompletion private var __slotToDense:Array<Int> = [];
	@:noCompletion private var __gen:Array<Int> = [];
	@:noCompletion private var __freeHead:Int = -1;
	@:noCompletion private var __freeTail:Int = -1;

	@:noCompletion private inline function get_capacity():Int {
		return __slotToDense.length;
	}

	@:noCompletion private inline function get_length():Int {
		return __values.length;
	}

    /**
	 * Creates a new PackedSlotMap with a specified initial capacity.
	 *
	 * @param initialCapacity Initial number of slots to allocate. Must be greater than 0.
	 * @param maxCapacity Optional hard limit on total slot capacity. Defaults to maximum indexable range.
	 * @param growthChunk Optional number of slots to grow by when capacity is exceeded. Defaults to 1024.
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
		__reserve(initialCapacity);
	}

    /**
	 * Inserts a value into the map and returns a SlotHandle for it.
	 *
	 * @param v The value to insert.
	 * @return A generation-validated SlotHandle that can be used to retrieve or update the value.
	 * @throws Error if the map is full and cannot grow.
	 */
	public inline function insert(v:T):SlotHandle {
		if (__freeHead == -1) {
			__grow();
			if (__freeHead == -1) {
				throw "PackedSlotMap full";
			}
		}
		var slot:Int = __freeHead;
		var link:Int = __slotToDense[slot];
		__freeHead = link == -1 ? -1 : -2 - link;
		if (__freeHead == -1) {
			__freeTail = -1;
		}
		var d:Int = __values.length;

		__values.push(v);
		__denseToSlot.push(slot);
		__slotToDense[slot] = d;

		return SlotHandle.make(slot, __gen[slot]);
	}

    /**
	 * Retrieves a value by its handle, if still valid.
	 *
	 * @param h The SlotHandle to look up.
	 * @return The associated value, or `null` if the handle is stale or invalid.
	 */
	public inline function get(h:SlotHandle):Null<T> {
		var slot = h.index();
		if (slot < 0 || slot >= __slotToDense.length) {
			return null;
		}

		if (__gen[slot] != h.gen()) {
			return null;
		}

		var d:Int = __slotToDense[slot];
		return (d < 0) ? null : __values[d];
	}

    /**
	 * Updates a value by its handle.
	 *
	 * @param h The SlotHandle to update.
	 * @param v The new value to store.
	 * @return True if the value was successfully updated, false if the handle was invalid or stale.
	 */
	public inline function set(h:SlotHandle, v:T):Bool {
		var slot:Int = h.index();
		if (slot < 0 || slot >= __slotToDense.length) {
			return false;
		}

		if (__gen[slot] != h.gen()) {
			return false;
		}

		var d:Int = __slotToDense[slot];
		if (d < 0) {
			return false;
		}

		__values[d] = v;
		return true;
	}

    /**
	 * Removes a value by its handle, if still valid.
	 * 
	 * The last value is moved into the removed value's slot to keep the array packed.
	 *
	 * @param h The SlotHandle to remove.
	 * @return True if the value was removed, false if the handle was invalid or stale.
	 */
	public function remove(h:SlotHandle):Bool {
		var slot:Int = h.index();
		if (slot < 0 || slot >= __slotToDense.length) {
			return false;
		}

		if (__gen[slot] != h.gen()) {
			return false;
		}

		var d:Int = __slotToDense[slot];
		if (d < 0) {
			return false;
		}

		var last:Int = __values.length - 1;
		if (d != last) {
			__values[d] = __values[last];
			var movedSlot:Int = __denseToSlot[last];
			__denseToSlot[d] = movedSlot;
			__slotToDense[movedSlot] = d;
		}
		__values.pop();
		__denseToSlot.pop();

		__gen[slot] = (__gen[slot] + 1) & SlotHandle.GEN_MASK;
		__queueFree(slot);
		return true;
	}

    /**
	 * Returns an iterator over the values in the map.
	 *
	 * Order is not guaranteed to be stable over time due to compaction on removal.
	 *
	 * Removing the entry the loop is on is safe: the entry moved into its
	 * place is visited next. It was the value array's own iterator, which
	 * skipped that entry.
	 */
	public inline function iterator():PackedSlotMapIterator<T> {
		return new PackedSlotMapIterator<T>(this);
	}

    /**
	 * Iterates over all elements and applies a callback, passing both the handle and the value.
	 *
	 * The callback may remove the entry it is given: the entry moved into its
	 * place is called next. The loop counted the entries before it began, so
	 * a removal left it reading past the end.
	 *
	 * @param f A callback function with signature (handle, value).
	 */
	public inline function forEach(f:(SlotHandle, T) -> Void):Void {
		var i:Int = 0;
		while (i < __values.length) {
			var slot:Int = __denseToSlot[i];
			f(SlotHandle.make(slot, __gen[slot]), __values[i]);
			// Still here: on to the next. Gone: whatever took its place, if
			// anything did, has not been called yet.
			if (i < __denseToSlot.length && __denseToSlot[i] == slot) {
				i++;
			}
		}
	}

    /**
	 * Ensures the internal capacity is at least the given number of slots.
	 * 
	 * Will grow if necessary, up to the maximum capacity.
	 *
	 * @param target The minimum number of total slots required.
	 */
	public inline function ensureCapacity(target:Int):Void {
		if (target <= __slotToDense.length) {
			return;
		}

		__reserve(target - __slotToDense.length);
	}

    /**
	 * Clears all values from the map.
	 * 
	 * All handles are invalidated and future inserts will reuse freed slots.
	 */
	public function clear():Void {
		var cap:Int = this.capacity;
		for (slot in 0...cap) {
			if (__slotToDense[slot] >= 0) {
				__gen[slot] = (__gen[slot] + 1) & SlotHandle.GEN_MASK;
			}

			__slotToDense[slot] = slot + 1 < cap ? -2 - (slot + 1) : -1;
		}
		__freeHead = cap > 0 ? 0 : -1;
		__freeTail = cap - 1;
		__values.resize(0);
		__denseToSlot.resize(0);
	}

    /**
	 * Returns the slot index associated with a given dense array index.
	 * 
	 * @param i The dense index (0 to count-1).
	 * @return The internal slot index.
	 */
	public inline function slotAtDense(i:Int):Int {
		return __denseToSlot[i];
	}

    /**
	 * Returns the current generation value for a given slot index.
	 * 
	 * @param slot The slot index to query.
	 * @return The current generation for the slot, or -1 if out of bounds.
	 */
	public inline function currentGen(slot:Int):Int {
		return (slot >= 0 && slot < __gen.length) ? __gen[slot] : -1;
	}

	@:noCompletion private inline function __queueFree(slot:Int):Void {
		__slotToDense[slot] = -1;
		if (__freeTail == -1) {
			__freeHead = slot;
		} else {
			__slotToDense[__freeTail] = -2 - slot;
		}
		__freeTail = slot;
	}

	@:noCompletion private inline function __grow():Void {
		if (__slotToDense.length >= maxCapacity) {
			return;
		}

		var add:Int = growthChunk;
		var remaining:Int = maxCapacity - __slotToDense.length;
		if (add > remaining) {
			add = remaining;
		}

		__reserve(add);
	}

	@:noCompletion private inline function __reserve(additional:Int):Void {
		if (additional <= 0) {
			return;
		}
			
		var old:Int = __slotToDense.length;
		var want:Int = old + additional;
		if (want > maxCapacity) {
			want = maxCapacity;
		}
		if (want <= old) {
			return;
		}

		__slotToDense[want - 1] = 0;
		__gen[want - 1] = 0;

		for (i in old...want) {
			__gen[i] = 0;
			__queueFree(i);
		}
	}
}

/**
 * Walks a `PackedSlotMap`'s values in their current dense order, with the
 * entry just returned free to be removed: if another was moved into its
 * place, that place is visited again. Slots, not values, say whether it was,
 * two entries can hold one value.
 */
@:noCompletion
@:access(crossbyte.ds.PackedSlotMap)
class PackedSlotMapIterator<T> {
	private var __map:PackedSlotMap<T>;
	private var __next:Int = 0;
	private var __returnedAt:Int = -1;
	private var __returnedSlot:Int = 0;

	public inline function new(map:PackedSlotMap<T>) {
		__map = map;
	}

	public inline function hasNext():Bool {
		__settle();
		return __next < __map.__values.length;
	}

	public inline function next():T {
		__settle();
		__returnedAt = __next;
		__returnedSlot = __map.__denseToSlot[__next];
		return __map.__values[__next++];
	}

	private inline function __settle():Void {
		if (__returnedAt >= 0) {
			var slots:Array<Int> = __map.__denseToSlot;
			if (__returnedAt >= slots.length || slots[__returnedAt] != __returnedSlot) {
				__next = __returnedAt;
			}
			__returnedAt = -1;
		}
	}
}
