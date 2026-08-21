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
	function clear(done:String->Void):Void;
	function close():Void;
}
