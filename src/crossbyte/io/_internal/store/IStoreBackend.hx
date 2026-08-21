package crossbyte.io._internal.store;

import crossbyte.io.ByteArray;

/**
 * What a `Store` needs from a target to exist there.
 *
 * Callback-shaped rather than returning `Future`, because a backend has no
 * business completing the future a caller holds -- `Store` owns that, and
 * owning it in one place is what keeps every target's error and success
 * behaviour identical rather than merely similar.
 */
interface IStoreBackend {
	function open(done:String->Void):Void;
	function get(key:String, done:(error:String, value:Null<ByteArray>) -> Void):Void;
	function put(key:String, value:ByteArray, done:String->Void):Void;
	function remove(key:String, done:String->Void):Void;
	function keys(prefix:Null<String>, done:(error:String, keys:Array<String>) -> Void):Void;

	/**
	 * Visits entries one at a time, stopping early when `visit` returns false.
	 *
	 * Separate from `keys` rather than built on it, because the whole point is
	 * that nothing holds every key -- or every value -- at once. A `forEach`
	 * implemented as `keys().map(get)` would allocate exactly what it exists to
	 * avoid.
	 */
	function forEach(prefix:Null<String>, visit:(key:String, value:ByteArray) -> Bool, done:String->Void):Void;
	function clear(done:String->Void):Void;
	function close():Void;
}
