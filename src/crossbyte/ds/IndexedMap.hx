package crossbyte.ds;

/**
 * ...
 * @author Christopher Speciale
 */
class IndexedMap<T> {
	private var array:Array<T>;
	private var indexMap:Map<Int, Int>;

	public function new() {
		array = new Array<T>();
		indexMap = new Map<Int, Int>();
	}

	public function add(value:T, index:Int):Void {
		array[index] = value;
		indexMap.set(index, array.length - 1);
	}

	public function remove(index:Int):Void {
		var valueIndex:Int = indexMap.get(index);
		if (valueIndex != null) {
			array[valueIndex] = null;
			indexMap.remove(index);
		}
	}

	public function get(index:Int):Null<T> {
		var valueIndex:Int = indexMap.get(index);
		if (valueIndex != null) {
			return array[valueIndex];
		} else {
			return null;
		}
	}

	public function set(index:Int, value:T):Void {
		var valueIndex:Int = indexMap.get(index);
		if (valueIndex != null) {
			array[valueIndex] = value;
		} else {
			add(value, index);
		}
	}

	public function length():Int {
		return array.length;
	}

	public function toArray():Array<T> {
		return array;
	}

	public function clear():Void {
		array = new Array<T>();
		indexMap = new Map<Int, Int>();
	}
}
