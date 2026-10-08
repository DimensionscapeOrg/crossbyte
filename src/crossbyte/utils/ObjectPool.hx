package crossbyte.utils;

import crossbyte.ds.Stack;
import crossbyte.errors.ArgumentError;

/**
 * ObjectPool is a generic object pool class.
 * It helps in reusing objects efficiently by managing a pool of reusable instances.
 *
 * **Releasing twice.** A debug build tracks every object it lends and throws
 * when one comes back twice or was never lent. A release build cannot afford
 * that tracking on every call, but it still refuses the two mistakes that
 * cost nothing to see: an object released twice in a row, and a release
 * when every object the pool made is already free, either of which would
 * have the next two `acquire`s hand one object to two owners. `release`
 * answers `false` for what it refused.
 *
 * **Bursts.** An object released is kept for the next `acquire` while fewer
 * than `maxFree` are free (10,000 unless set), and let go past that, so a
 * burst of a hundred thousand does not leave a hundred thousand behind for
 * good: memory the collector could never take back, and more for it to
 * walk at every collection, which on a native build is what a pause lasts
 * in proportion to. A reservation (`reserve`, the constructor's `length`,
 * `resizeCapacity`) raises `maxFree` to what it reserves, so the
 * objects asked for in advance are not let go after their first use.
 *
 * @param T The type of objects to be pooled.
 */
@:generic
final class ObjectPool<T:{}> {
	@:noCompletion private var __free:Stack<T>;
	@:noCompletion private var __created:Int = 0;
	#if debug
	@:noCompletion private var __inUse:haxe.ds.ObjectMap<{}, Bool> = new haxe.ds.ObjectMap();
	#end

	/**
	 * A factory function that creates new instances of the pooled objects.
	 * This function is used to populate the pool and to create new objects when needed.
	 */
	public var objectFactory:Void->T;

	/**
	 * A function to reset objects before they are released back to the pool.
	 * This function can be used to clear or initialize the state of objects.
	 */
	public var resetFunction:T->Void;

	/**
	 * The most free objects the pool keeps: 10,000 unless set, and raised to
	 * what `reserve`, the constructor's `length` or `resizeCapacity` reserve.
	 * A release past it is let go rather than kept, and no longer counts
	 * toward `capacity`. `0` keeps nothing; `0x7FFFFFFF` keeps every object
	 * released.
	 *
	 * What it bounds is memory held between bursts: at most `maxFree`
	 * objects, of whatever size `objectFactory` makes them, stay behind after
	 * the busiest moment. Set it to the most a quiet period should keep; a
	 * pool of large buffers wants it far lower.
	 *
	 * @throws ArgumentError When set below zero.
	 */
	public var maxFree(default, set):Int = 10000;

	/** 
	 * Objects currently free. 
	 */
	public var freeCount(get, never):Int;

	/** 
	 * Total created by this pool
	 */
	public var capacity(get, never):Int;

	/** 
	 * Estimated in-use count
	 */
	public var inUse(get, never):Int;

	@:noCompletion private inline function get_freeCount():Int {
		return __free.length;
	}

	@:noCompletion private inline function get_capacity():Int {
		return __created;
	}

	@:noCompletion private inline function get_inUse():Int {
		return __created - __free.length;
	}

	@:noCompletion private function set_maxFree(value:Int):Int {
		if (value < 0) {
			throw new ArgumentError('ObjectPool.maxFree must not be negative ($value).');
		}

		return maxFree = value;
	}

	/**
	 * Creates a new object pool.
	 *
	 * @param objectFactory The function to create new instances of the pooled objects.
	 * @param resetFunction Optional The function used to reset our object.
	 * @param length Optional initial size of the pool: that many objects are
	 *        made at once, and `maxFree` is raised to keep them if it is lower.
	 */
	public inline function new(objectFactory:Void->T, ?resetFunction:T->Void, ?length:Int) {
		this.objectFactory = objectFactory;
		this.resetFunction = resetFunction;
		__free = new Stack(length != null ? length : 0);

		if (length != null && length > 0) {
			reserve(length);
		}
	}

	/**
	 * Acquires an object from the pool.
	 * If no objects are available, it creates a new one using the factory function.
	 *
	 * @return T The acquired object.
	 */
	public inline function acquire():T {
		var obj:T;
		if (__free.length > 0) {
			obj = __free.pop();
		} else {
			__created++;
			obj = objectFactory();
		}

		#if debug
		if (__inUse.exists(obj))
			throw "ObjectPool: double-loan";
		__inUse.set(obj, true);
		#end

		return obj;
	}

	/**
	 * Releases an object back to the pool.
	 *
	 * @param obj The object to release.
	 * @return Whether it was taken back: `false` for an object released twice
	 *         in a row, or when everything the pool made is already free. A
	 *         debug build throws for those, and for any foreign or repeated
	 *         release, instead.
	 */
	public inline function release(obj:T):Bool {
		#if debug
		if (obj == null)
			throw "Released object cant be null";
		if (!__inUse.remove(obj))
			throw "ObjectPool: foreign or already-released object";
		#end
		var taken:Bool = __free.length < __created && (__free.length == 0 || __free.last() != obj);
		if (taken) {
			var func:T->Void = resetFunction;
			if (func != null) {
				func(obj);
			}

			if (__free.length < maxFree) {
				__free.push(obj);
			} else {
				__created--;
			}
		}
		return taken;
	}

	/**
	 * Ensure at least n free objects are available, and that the pool keeps
	 * that many: `maxFree` is raised to `length` if it is lower.
	 *
	 * @param length
	 */
	public inline function reserve(length:Int):Void {
		if (length > maxFree) {
			maxFree = length;
		}

		var need:Int = length - __free.length;
while (need > 0) {
			__free.push(objectFactory());
			__created++;
			need--;
		}
	}

	/**
	 * Set total logical capacity (inUse + free) to `target`.
	 * Never shrinks below current `inUse`. Returns the new capacity.
	 * `maxFree` is raised to the free objects this leaves, if it is lower.
	 *
	 * @param target 
	 * @return Int
	 */
	public inline function resizeCapacity(target:Int):Int {
		if (target < 0) {
			target = 0;
		}

		var inUseNow:Int = __created - __free.length;
		if (target < inUseNow) {
			target = inUseNow;
		}

		var wantFree:Int = target - inUseNow;
		var free:Int = __free.length;

		if (wantFree > free) {
			var need:Int = wantFree - free;
			while (need-- > 0) {
				__free.push(objectFactory());
				__created++;
			}
		} else if (wantFree < free) {
			var drop:Int = free - wantFree;
			while (drop-- > 0) {
				__free.pop();
				__created--;
			}
		}

		if (__free.length > maxFree) {
			maxFree = __free.length;
		}

		return inUseNow + __free.length;
	}
}
