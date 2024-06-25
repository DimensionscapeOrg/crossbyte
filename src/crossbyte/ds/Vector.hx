package crossbyte.ds;

import crossbyte.Function;
import crossbyte.Object;

/**
 * ...
 * @author Christopher Speciale
 */
class Vector<T> implements ArrayAccess<T> {
	private static function __fromArray<T>(arr:T):Vector<Dynamic> {
		var vec:Vector<Dynamic> = new Vector();
		vec.__array = cast arr;

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

	public inline function concat(...args):Vector<T> {
		var vec:Vector<T> = new Vector();
		return vec;
	}

	public inline function every(callback:Function, thisObject:Object = null):Bool {
		return false;
	}

	public inline function filter():Vector<T> {
		var vec:Vector<T> = new Vector();
		return vec;
	}

	public inline function forEach(callback:Function, thisObject:Object = null):Void {}

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

	public inline function map(callback:Function, thisObject:Object = null):Vector<T> {
		var vec:Vector<T> = new Vector();
		return vec;
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

	public inline function some(callback:Function, thisObject:Object = null):Bool {
		return false;
	}

	public inline function sort(sortBehavior:Dynamic):Vector<T> {
		var vec:Vector<T> = new Vector();
		return vec;
	}

	public inline function splice(startIndex:Int, deleteCount:UInt = 2147483647, ...items):Vector<T> {
		var vec:Vector<T> = __fromArray(__array.splice(startIndex, deleteCount));

		for (item in items) {
			__array.insert(startIndex, item);
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
}
