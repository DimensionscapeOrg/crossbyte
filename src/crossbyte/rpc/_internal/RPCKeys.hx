package crossbyte.rpc._internal;

/**
	What patches share at run time: counting a mask's bits.
**/
@:noCompletion
class RPCKeys {
	/** How many bits of `mask` are set: one step a set bit, the same arithmetic on every target. **/
	public static inline function bitCount(mask:Int):Int {
		var v:Int = mask;
		var count:Int = 0;
		while (v != 0) {
			v &= v - 1;
			count++;
		}
		return count;
	}
}
