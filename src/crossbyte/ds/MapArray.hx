package crossbyte.ds;
import haxe.Constraints.IMap;
import haxe.ds.Map;
import haxe.ds.StringMap;

/**
 * ...
 * @author Christopher Speciale
 */
@:remove @:generic
class MapArray<K, V> {
    private var __map:Map<K, V>;
    private var __array:Array<K>;
	
	public var length(get, null):Int;

    public function new() {
        __map = new Map<K,V>();
        __array = new Array<K>();
    }
	
	public inline function exists(key:K):Bool{
		return __map.exists(key);
	}
	
    public inline function set(key:K, value:V):Void {
        if (!__map.exists(key)) {
            __array.push(key);
        }
		 
        __map.set(key, value);
    }

    public inline function get(key:K):Null<V> {
        return __map.get(key);
    }

    public inline function getByIndex(index:Int):Null<V> {
        var key = __array[index];
        return __map.get(key);
    }

    public inline function remove(key:K):Bool {
        var ret = __map.remove(key);
        if (ret) {
            __array.remove(key);
        }
        return ret;
    }

    public inline function clear():Void {
		__map.clear();
		__array = [];
    }

    private inline function get_length():Int {
        return __array.length;
    }

    public inline function keys():Array<K> {
        return __array.copy();
    }
	
	public inline function iterator():Iterator<V>{
		return __map.iterator();
	}
	
	public inline function keyValues():KeyValueIterator<K, V>{
		return __map.keyValueIterator();
	}
}