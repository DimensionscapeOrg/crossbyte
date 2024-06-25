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
		nodes.sort(doSort);
		nLength++;
	}

	public function remove():T {
		if (nLength == 0)
			return null;
		nLength--;
		return nodes.shift();
	}

	private function doSort(a:T, b:T):Int {
		return a.compareTo(b);
	}
}
