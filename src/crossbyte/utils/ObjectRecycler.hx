package crossbyte.utils;

/**
	Local recycler that batches objects before returning them to a shared pool.

	It keeps the last two objects recycled for the next two `get`s, and hands
	anything past that, and what it holds when drained, to its pool. An
	object is reset once, by the pool's `resetFunction`, as it is recycled.
**/
@:generic
final class ObjectRecycler<T:{}> {
	public var pool(default, null):ObjectPool<T>;

	@:noCompletion private var _l0:T = null;
	@:noCompletion private var _l1:T = null;

	public inline function new(pool:ObjectPool<T>) {
		this.pool = pool;
	}

	public inline function get():T {
		var obj:T = _l0;
		if (obj != null) {
			_l0 = _l1;
			_l1 = null;
			return obj;
		}
		obj = _l1;
		if (obj != null) {
			_l1 = null;
			return obj;
		}
		return pool.acquire();
	}

	/**
		Takes an object back, to hand out again or to give to the pool.

		An object it is already holding is refused on every build, since
		kept twice it would go to the next two `get`s at once. A debug build
		throws for it instead.

		@return Whether it was taken back: `false` for `null`, for an object
		        it holds already, or for one its pool refuses.
	**/
	public inline function recycle(object:T):Bool {
		var taken:Bool = false;
		if (object == null) {
			// Nothing to take.
		} else if (object == _l0 || object == _l1) {
			#if debug
			throw "ObjectRecycler: double-recycle of same object";
			#end
		} else if (_l0 == null || _l1 == null) {
			var func:T->Void = pool.resetFunction;
			if (func != null) {
				func(object);
			}
			if (_l0 == null) {
				_l0 = object;
			} else {
				_l1 = object;
			}
			taken = true;
		} else {
			taken = pool.release(object);
		}
		return taken;
	}

	/** Gives what it holds to its pool, already reset. **/
	public inline function drain():Void {
		var obj:T = _l0;
		if (obj != null) {
			_l0 = null;
			@:privateAccess pool.__release(obj, false);
		}
		obj = _l1;
		if (obj != null) {
			_l1 = null;
			@:privateAccess pool.__release(obj, false);
		}
	}

	public inline function localSize():Int {
		return (_l0 != null ? 1 : 0) + (_l1 != null ? 1 : 0);
	}
}
