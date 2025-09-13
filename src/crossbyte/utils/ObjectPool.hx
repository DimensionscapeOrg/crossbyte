package crossbyte.utils;

import crossbyte.ds.Stack;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * ObjectPool is a generic object pool class.
 * It helps in reusing objects efficiently by managing a pool of reusable instances.
 *
 * @param T The type of objects to be pooled.
 */
@:generic
class ObjectPool<T:{}> {
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

	/**
	 * Creates a new object pool.
	 *
	 * @param objectFactory The function to create new instances of the pooled objects.
	 * @param resetFunction Optional The function used to reset our object.
	 * @param length Optional initial size of the pool.
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
		if (__free.length > 0) {
			var obj:T = __free.pop();
			#if debug
			if (__inUse.exists(obj))
				throw "ObjectPool: double-loan";
			__inUse.set(obj, true);
			#end
			return obj;
		}
		__created++;
		return objectFactory();
	}

	/**
	 * Releases an object back to the pool.
	 *
	 * @param obj The object to release.
	 */
	public inline function release(obj:T):Void {
		#if debug
		if (obj == null)
			throw "Released object cant be null";
		if (!__inUse.remove(obj))
			throw "ObjectPool: foreign or already-released object";
		#end
		var func:T->Void = resetFunction;
		if (func != null) {
			func(obj);
		}

		__free.push(obj);
	}

	/**
	 * Ensure at least n free objects are available
	 * 
	 * @param length 
	 */
	public inline function reserve(length:Int):Void {
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
	 *
	 * @param target 
	 * @return Int
	 */
	public inline function resizeCapacity(target:Int):Int {
		if (target < 0){
			target = 0;
		}
			
		var inUseNow:Int = __created - __free.length;
		if (target < inUseNow){
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
			}
		}
		return inUseNow + __free.length;
	}
}
