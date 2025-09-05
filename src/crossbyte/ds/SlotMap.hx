package crossbyte.ds;

import haxe.ds.Vector;

/**
 * A 32-bit opaque handle that encodes both an index and a generation count.
 * Used to safely reference entries in a SlotMap, guarding against use-after-free bugs.
 *
 * @param v The raw 32-bit integer value of the handle.
 */
@:forward
abstract SlotHandle(Int) from Int to Int {
	/**
	 * Creates a new SlotHandle
	 *
	 */
	public inline function new(v:Int) {
		this = v;
	}

	/**
	 * Extract the index portion of this handle.
	 *
	 * @param capacity The maximum capacity of the associated SlotMap.
	 * @return The index portion, derived from the lower bits.
	 */
	public inline function index(capacity:Int):Int {
		var indexBits = neededBits(capacity - 1);
		return this & ((1 << indexBits) - 1);
	}

	/**
	 * Extract the generation portion of this handle.
	 *
	 * @param capacity The maximum capacity of the associated SlotMap.
	 * @return The generation value, derived from the upper bits.
	 */
	public inline function gen(capacity:Int):Int {
		var indexBits = neededBits(capacity - 1);
		return this >>> indexBits;
	}

	/**
	 * Constructs a new handle from the given index and generation.
	 *
	 * @param index The slot index.
	 * @param gen The generation count.
	 * @param capacity The capacity of the associated SlotMap.
	 * @return A SlotHandle encoding both values.
	 */
	public static inline function make(index:Int, gen:Int, capacity:Int):SlotHandle {
		var indexBits = neededBits(capacity - 1);
		return new SlotHandle((gen << indexBits) | index);
	}

	private static inline function neededBits(x:Int):Int {
		var n = 0, v = x;
		while (v > 0) {
			v >>>= 1;
			n++;
		}
		return (x <= 0) ? 1 : n;
	}
}

/**
 * A fixed-capacity map structure with fast O(1) insert, remove, and access by handle.
 * Each element is associated with a generation-validated 32-bit handle to ensure safe access.
 *
 */
final class SlotMap<T> {
	/**
	 * The total fixed capacity of this SlotMap.
	 */
	public final capacity:Int;

	/**
	 * The current number of active (non-removed) elements.
	 */
	public var count(default, null):Int = 0;

	private var values:Array<Null<T>>;
	private var gen:Vector<Int>; // per-slot generation
	private var free:Vector<Int>; // free stack
	private var top:Int;

	/**
	 * Creates a new SlotMap
	 *
	 * @param T The type of values stored in the map.
	 */
	public inline function new(capacity:Int) {
		if (capacity <= 0) {
			throw "capacity must be > 0";
		}

		this.capacity = capacity;

		values = new Array<Null<T>>();
		values[capacity - 1] = null;
		gen = new Vector<Int>(capacity);
		free = new Vector<Int>(capacity);

		for (i in 0...capacity) {
			values[i] = null;
			gen[i] = 0;
			free[i] = capacity - 1 - i;
		}
		top = capacity;
	}

	/**
	 * Inserts a value into the map and returns a handle referencing it.
	 *
	 * @param v The value to insert.
	 * @return A SlotHandle that can be used to access or remove the value.
	 * @throws Error if the map is at full capacity.
	 */
	public inline function insert(v:T):SlotHandle {
		if (top == 0) {
			throw "SlotMap full";
		}

		var i:Int = free[--top];
		values[i] = v;
		count++;
		return SlotHandle.make(i, gen[i], capacity);
	}

	/**
	 * Removes a value from the map by handle.
	 *
	 * @param h The handle referencing the entry to remove.
	 * @return True if removed successfully, false if the handle was invalid or stale.
	 */
	public inline function remove(h:SlotHandle):Bool {
		var i:Int = h.index(capacity);
		if ((i | 0) < 0 || i >= capacity) {
			return false;
		}

		if (gen[i] != h.gen(capacity)) {
			return false;
		}

		values[i] = null;
		gen[i] = (gen[i] + 1) | 0;
		free[top++] = i;
		count--;
		return true;
	}

	/**
	 * Retrieves a value by handle.
	 *
	 * @param h The handle referencing the desired value.
	 * @return The value if found and valid, or null if the handle is invalid or stale.
	 */
	public inline function get(h:SlotHandle):Null<T> {
		var i:Int = h.index(capacity);
		if ((i | 0) < 0 || i >= capacity) {
			return null;
		}

		return (gen[i] == h.gen(capacity)) ? values[i] : null;
	}

	/**
	 * Updates a value in the map by handle.
	 *
	 * @param h The handle referencing the entry.
	 * @param v The new value to assign.
	 * @return True if updated successfully, false if the handle is invalid or stale.
	 */
	public inline function set(h:SlotHandle, v:T):Bool {
		var i = h.index(capacity);
		if ((i | 0) < 0 || i >= capacity) {
			return false;
		}

		if (gen[i] != h.gen(capacity)) {
			return false;
		}

		values[i] = v;
		return true;
	}

	/**
	 * Iterates over all live entries in the map.
	 *
	 * @param f A callback that receives each handle and value.
	 */
	public inline function forEach(f:(SlotHandle, T) -> Void):Void {
		for (i in 0...capacity) {
			var v:Null<T> = values[i];
			if (v != null) {
				f(SlotHandle.make(i, gen[i], capacity), v);
			}
		}
	}

	/**
	 * Clears all entries from the map and invalidates all existing handles.
	 */
	public inline function clear():Void {
		for (i in 0...capacity) {
			values[i] = null;
			gen[i] = (gen[i] + 1) | 0;
			free[i] = capacity - 1 - i;
		}
		top = capacity;
		count = 0;
	}

	/**
	 * Provides raw access to the internal value array.
	 * Unsafe: does not check generation. Use with caution.
	 *
	 * @param index The raw index of the slot.
	 * @return The value at the index, regardless of generation.
	 */
	public inline function getAtUnsafe(index:Int):Null<T> {
		return values[index];
	}

	public inline function toString():String {
		return values.toString();
	}

	public inline function getValues():Array<T> {
		return values;
	}
}
