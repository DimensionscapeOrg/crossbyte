package crossbyte.rpc._internal;

import crossbyte.utils.Hash;
import haxe.io.Bytes;

/**
	How an RPC method's name becomes the op that names it on the wire, and the
	check that no two methods of one surface share an op.

	An op is the 32-bit FNV-1a hash of the method's name, and nothing else --
	not the contract it was declared in -- so a method keeps its op wherever a
	contract that declares it is reused. Two different names can still hash
	alike (`glbvs` and `yacxa` do), and on one connection they would be one
	method. Compiled into the macros as well as the runtime, so the check the
	build makes is the one the tests exercise.
**/
class RPCOps {
	public static inline function opOf(name:String):Int {
		return Hash.fnv1a32(Bytes.ofString(name));
	}

	/**
		The first two of `names` that share an op, or `null` if none do. A
		name listed twice is one method reached twice, not a clash.
	**/
	public static function firstClash(names:Array<String>):Null<Array<String>> {
		final byOp:Map<Int, String> = new Map();
		for (name in names) {
			final op:Int = opOf(name);
			final other:Null<String> = byOp.get(op);
			if (other == null) {
				byOp.set(op, name);
			} else if (other != name) {
				return [other, name];
			}
		}
		return null;
	}
}
