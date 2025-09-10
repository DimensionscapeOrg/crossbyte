package crossbyte.ds;

/**
 * A **growable** map structure with fast O(1) insert, remove, and access by handle.
 * Each element is associated with a generation-validated 32-bit handle to ensure safe access.
 *
 * Capacity grows in chunks up to `maxCapacity`. When no free slots remain:
 * - the map will attempt to grow (by `growthChunk`), and
 * - if already at `maxCapacity`, `insert()` throws `"SlotMap full"`.
 *
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

	inline function get_capacity():Int
		return __capacity;

	/**
	 * Upper bound for slots; cannot exceed `(1 << SlotHandle.INDEX_BITS)`.
	 */
	public final maxCapacity:Int;

	/**
	 * Number of slots to add when growing.
	 */
	public var growthChunk(default, null):Int;

	
	@:noCompletion private var __capacity:Int;
	@:noCompletion private var __values:Array<Null<T>>;
	@:noCompletion private var __gen:Array<Int>; 
	@:noCompletion private var __free:Array<Int>;

	/**
	 * Creates a new (growable) SlotMap.
	 *
	 * @param initialCapacity The initial number of slots to allocate (must be > 0).
	 * @param maxCapacity     Optional hard ceiling for total slots. Defaults to `(1 << SlotHandle.INDEX_BITS)`.
	 * @param growthChunk     Optional growth step (slots added when full). Defaults to 1024 (min 1).
	 */
	public inline function new(initialCapacity:Int, ?maxCapacity:Int, ?growthChunk:Int = 1024) {
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

		this.__capacity = initialCapacity;

		__values = [];
		__values[__capacity - 1] = null;
		__gen = [];
		__gen[__capacity - 1] = 0;
		for (i in 0...__capacity) {
			__values[i] = null;
			__gen[i] = 0;
		}

		__free = [];
		for (i in 0...__capacity) {
			__free.push(__capacity - 1 - i);
		}
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
		if (__free.length == 0) {
			growInternal(growthChunk);
			if (__free.length == 0) {
				throw "SlotMap full";
			}
		}
		var i:Int = __free.pop();
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
		if ((i | 0) < 0 || i >= __capacity) {
			return false;
		}

		if (__gen[i] != h.gen()) {
			return false;
		}

		__values[i] = null;
		__gen[i] = (__gen[i] + 1) | 0;
		__free.push(i);
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
		if ((i | 0) < 0 || i >= __capacity) {
			return null;
		}

		return (__gen[i] == h.gen()) ? __values[i] : null;
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
		if ((i | 0) < 0 || i >= __capacity) {
			return false;
		}

		if (__gen[i] != h.gen()) {
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
			var v:Null<T> = __values[i];
			if (v != null) {
				f(SlotHandle.make(i, __gen[i]), v);
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
	public inline function clear():Void {
		for (i in 0...__capacity) {
			if (__values[i] != null) {
				__gen[i] = (__gen[i] + 1) | 0;
			}

			__values[i] = null;
		}
		__free = [];
		for (i in 0...__capacity) {
			__free.push(__capacity - 1 - i);
		}

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

	inline function growInternal(additional:Int):Void {
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

		__values[newCap - 1] = null;
		__gen[newCap - 1] = 0;

		for (i in __capacity...newCap) {
			__values[i] = null;
			__gen[i] = 0;
		}
		for (i in __capacity...newCap) {
			var slot:Int = newCap - 1 - (i - __capacity);
			__free.push(slot);
		}

		__capacity = newCap;
	}
}
