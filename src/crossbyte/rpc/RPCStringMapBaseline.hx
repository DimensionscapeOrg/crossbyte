package crossbyte.rpc;

import crossbyte.errors.ArgumentError;
import crossbyte.rpc._internal.RPCKeys;
import haxe.ds.StringMap;

/**
	`RPCMapBaseline` for maps of `String` keys, which
	`RPCStringMapPatch.diffKeysWithin` reads and writes: the keys an observer
	holds, in the order maps put them on the wire, and the older value it
	still has for each whose update a budget deferred.

	**Threading.** None.
**/
final class RPCStringMapBaseline<V> {
	/** How many keys the observer holds. **/
	public var length(get, never):Int;

	/** How many of them hold a value older than their frame's, their last update deferred. **/
	public var staleCount(get, never):Int;

	@:noCompletion public final __keys:Array<String> = [];
	@:noCompletion public final __staleKeys:Array<String> = [];
	@:noCompletion public final __staleValues:Array<V> = [];
	@:noCompletion public final __spare:Array<V> = [];
	@:noCompletion public var __spareCount:Int = 0;
	@:noCompletion public var __frame:Null<StringMap<V>> = null;

	public function new() {}

	/**
		The `index`-th key the observer holds, in wire order.

		@throws RangeError If `index` is not below `length`.
	**/
	public function keyAt(index:Int):String {
		if (index < 0 || index >= __keys.length) {
			throw new crossbyte.errors.RangeError('Index $index is out of bounds (length ${__keys.length})');
		}
		return __keys[index];
	}

	/** Whether the observer holds `key`. **/
	public function has(key:String):Bool {
		return RPCKeys.indexOfString(__keys, key) >= 0;
	}

	/** Whether the observer holds `key` at a value older than the frame's: its update was deferred. **/
	public function isStale(key:String):Bool {
		return RPCKeys.indexOfString(__staleKeys, key) >= 0;
	}

	/**
		As `RPCMapBaseline.valueIn`: the value the observer holds under
		`key`, its stale one or `frame`'s; `null` when it holds none.

		@throws ArgumentError When `frame` is not the one it was made against.
	**/
	public function valueIn(key:String, frame:StringMap<V>):Null<V> {
		if (frame != __frame) {
			throw new ArgumentError("This baseline was made against another frame of values: give the frame of the tick it was sent at.");
		}
		if (RPCKeys.indexOfString(__keys, key) < 0) {
			return null;
		}
		final stale:Int = RPCKeys.indexOfString(__staleKeys, key);
		return stale >= 0 ? __staleValues[stale] : frame.get(key);
	}

	@:noCompletion public inline function __take(codec:RPCCodec<V>):V {
		if (__spareCount > 0) {
			__spareCount--;
			final value:V = __spare[__spareCount];
			__spare[__spareCount] = null;
			return value;
		}
		return codec.make();
	}

	@:noCompletion public inline function __keep(value:V):Void {
		if (__spareCount < __spare.length) {
			__spare[__spareCount] = value;
		} else {
			__spare.push(value);
		}
		__spareCount++;
	}

	private inline function get_length():Int {
		return __keys.length;
	}

	private inline function get_staleCount():Int {
		return __staleKeys.length;
	}
}
