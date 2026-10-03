package crossbyte._internal.php;

import haxe.io.Bytes;
import haxe.ds.StringMap;

/** What PHP answered: built from an object literal. */
@:structInit
final class PHPResponse {
	public var status:Int;
	// Lowercased keys.
	public var headers:StringMap<String>;
	public var body:Bytes;
}
