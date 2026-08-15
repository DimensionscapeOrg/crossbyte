package crossbyte._internal.deflatex.utils;

@:generic
class PriorityQueue<T:IComparable<T>> {
	private var nodes:Array<T>;
	private var nLength:UInt;

	public function new() {
		nodes = new Array<T>();
		nLength = 0;
	}

	public var length(get, never):UInt;

	function get_length():UInt {
		return nLength;
	}

	public function add(node:T) {
		nodes.push(node);
		// Capture-free comparator: a bound method reference here makes the
		// JVM backend emit a closure typed against the unspecialized generic
		// class, which fails Java 8 bytecode verification inside @:generic
		// specializations (same genjvm constraint as OrderedMap.iterator).
		nodes.sort((a:T, b:T) -> a.compareTo(b));
		nLength++;
	}

	public function remove():T {
		if (nLength == 0)
			return null;
		nLength--;
		return nodes.shift();
	}
}
