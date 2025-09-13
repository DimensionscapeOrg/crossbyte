package crossbyte.utils;

/**
 * ...
 * @author Christopher Speciale
 */
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

	public inline function recycle(object:T):Void {
		if (object == null)
			return;
		#if debug
		if (object == _l0 || object == _l1)
			throw "ObjectRecycler: double-recycle of same object";
		#end

		var func:T->Void = pool.resetFunction;
		if (_l0 == null) {
			if (func != null) {
				func(object);
			}

			_l0 = object;
			return;
		}
		if (_l1 == null) {
			if (func != null) {
				func(object);
			}

			_l1 = object;
			return;
		}

		pool.release(object);
	}

	public inline function drain():Void {
		var obj:T = _l0;
		if (obj != null) {
			_l0 = null;
			pool.release(obj);
		}
		obj = _l1;
		if (obj != null) {
			_l1 = null;
			pool.release(obj);
		}
	}

	public inline function localSize():Int {
		return (_l0 != null ? 1 : 0) + (_l1 != null ? 1 : 0);
	}
}
