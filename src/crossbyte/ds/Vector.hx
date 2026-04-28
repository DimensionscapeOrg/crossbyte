package crossbyte.ds;

import crossbyte.Function;
import crossbyte.Object;

/**
 * ...
 * @author Christopher Speciale
 */
class Vector<T> implements ArrayAccess<T> {
	private static function __fromArray<T>(arr:Array<T>):Vector<T> {
		var vec:Vector<T> = new Vector();
		vec.__array = arr;

		return vec;
	}

	public var fixed(get, set):Bool;
	public var length(get, set):Int;

	private var __array:Array<T>;
	private var __fixed:Bool;
	private var __length:Int;

	public inline function new(length:Int = 0, fixed:Bool = false) {
		__array = [];
		this.length = length;
		this.fixed = fixed;
	}

	private inline function __set(key:Int, value:T):Void {
		__array[key] = value;
	}

	private inline function __get(key:Int):T {
		return __array[key];
	}

	public function concat(...args:Dynamic):Vector<T> {
		var out:Array<T> = __array.copy();
		for (arg in args) {
			if (Std.isOfType(arg, Vector)) {
				var vector:Vector<T> = cast arg;
				for (item in vector.__array) {
					out.push(item);
				}
			} else if (Std.isOfType(arg, Array)) {
				for (item in (cast arg : Array<T>)) {
					out.push(item);
				}
			} else {
				out.push(cast arg);
			}
		}
		var vec:Vector<T> = new Vector(out.length);
		vec.__array = out;
		return vec;
	}

	public function every(callback:Function, thisObject:Object = null):Bool {
		for (i in 0...__array.length) {
			if (!__invokePredicate(callback, thisObject, __array[i], i)) {
				return false;
			}
		}
		return true;
	}

	public function filter(callback:Function, thisObject:Object = null):Vector<T> {
		var out:Array<T> = [];
		for (i in 0...__array.length) {
			var value:T = __array[i];
			if (__invokePredicate(callback, thisObject, value, i)) {
				out.push(value);
			}
		}
		return __fromArray(out);
	}

	public function forEach(callback:Function, thisObject:Object = null):Void {
		for (i in 0...__array.length) {
			__invoke(callback, thisObject, __array[i], i);
		}
	}

	public inline function indexOf(searchElement:T, fromIndex:Int = 0):Int {
		return __array.indexOf(searchElement, fromIndex);
	}

	public inline function insertAt(index:Int, element:T):Void {
		__array.insert(index, element);
	}

	public inline function join(sep:String = ","):String {
		return __array.join(sep);
	}

	public inline function lastIndexOf(searchElement:T, fromIndex:Int = 0x7fffffff):Int {
		return __array.lastIndexOf(searchElement, fromIndex);
	}

	public function map(callback:Function, thisObject:Object = null):Vector<T> {
		var out:Array<T> = [];
		for (i in 0...__array.length) {
			out.push(cast __invoke(callback, thisObject, __array[i], i));
		}
		return __fromArray(out);
	}

	public inline function pop():T {
		return __array.pop();
	}

	public inline function push(arg:T):UInt {
		// for (arg in args){
		//	__array.push(arg);
		// }
		__array.push(arg);
		return __array.length;
	}

	public inline function removeAt(index:Int):T {
		return __array.splice(index, 1)[0];
	}

	public inline function reverse():Vector<T> {
		__array.reverse();
		return this;
	}

	public inline function shift():T {
		return __array.shift();
	}

	public inline function slice(startIndex:Int = 0, endIndex:Int = 16777215):Vector<T> {
		return __fromArray(__array.slice(startIndex, endIndex));
	}

	public function some(callback:Function, thisObject:Object = null):Bool {
		for (i in 0...__array.length) {
			if (__invokePredicate(callback, thisObject, __array[i], i)) {
				return true;
			}
		}
		return false;
	}

	public function sort(sortBehavior:Dynamic):Vector<T> {
		if (sortBehavior == null) {
			__array.sort(Reflect.compare);
		} else if (Reflect.isFunction(sortBehavior)) {
			__array.sort(cast sortBehavior);
		} else {
			throw "Vector sortBehavior must be a comparator function or null";
		}
		return this;
	}

	public inline function splice(startIndex:Int, deleteCount:UInt = 2147483647, ...items):Vector<T> {
		var vec:Vector<T> = __fromArray(__array.splice(startIndex, deleteCount));

		var insertIndex:Int = startIndex;
		for (item in items) {
			__array.insert(insertIndex++, cast item);
		}

		return vec;
	}

	public inline function toLocaleString():String {
		return __array.toString();
	}

	public inline function toString():String {
		return __array.toString();
	}

	public inline function unshift(arg:T):UInt {
		/*for (arg in args){
			__array.unshift(arg);
		}*/
		__array.unshift(arg);

		return __array.length;
	}

	private inline function get_fixed():Bool {
		return __fixed;
	}

	private inline function set_fixed(value:Bool):Bool {
		return __fixed = value;
	}

	private inline function get_length():Int {
		return __array.length;
	}

	private inline function set_length(value:Int):Int {
		__array.resize(value);
		return value;
	}

	@:noCompletion private function __invoke(callback:Function, thisObject:Object, value:T, index:Int):Dynamic {
		var owner:Dynamic = thisObject != null ? thisObject : null;
		var args2:Array<Dynamic> = [value, index];
		var args1:Array<Dynamic> = [value];

		try {
			return Reflect.callMethod(owner, callback, args2);
		} catch (_:Dynamic) {}
		try {
			return Reflect.callMethod(owner, callback, args1);
		} catch (_:Dynamic) {}
		return Reflect.callMethod(owner, callback, []);
	}

	@:noCompletion private function __invokePredicate(callback:Function, thisObject:Object, value:T, index:Int):Bool {
		return __invoke(callback, thisObject, value, index) == true;
	}
}
