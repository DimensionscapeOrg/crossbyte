package crossbyte.ds;

import crossbyte.Function;
import crossbyte.Object;
import crossbyte.errors.RangeError;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * ActionScript's `Vector`: a dense, typed array whose length can be fixed.
 *
 * `v[i]` reads and writes an element on every target. It was a class
 * implementing `ArrayAccess`, which only hxcpp honours: `v[i]` threw on eval
 * and the jvm and on JavaScript set a property of that name, so a write was
 * lost. As in ActionScript, reading at or past `length` throws `RangeError`,
 * writing at `length` appends, and writing past it throws.
 *
 * **`fixed`** is enforced: while it is set, anything that would change the
 * length -- `push`, `pop`, `shift`, `unshift`, `insertAt`, `removeAt`, a
 * `splice` that adds or removes, setting `length` -- throws `RangeError`.
 *
 * **Callbacks** given to `every`, `filter`, `forEach`, `map` and `some` are
 * called with as many of `(item, index, vector)` as they take. They were
 * called with two and, if that threw, again with one and then none -- so a
 * callback that threw was run a second time, missing its index.
 */
@:forward
abstract Vector<T>(VectorImpl<T>) from VectorImpl<T> to VectorImpl<T> {
	public inline function new(length:Int = 0, fixed:Bool = false) {
		this = new VectorImpl<T>(length, fixed);
	}

	@:arrayAccess private inline function __arrayGet(index:Int):T {
		return this.__get(index);
	}

	@:arrayAccess private inline function __arraySet(index:Int, value:T):T {
		this.__set(index, value);
		return value;
	}
}

/** What a `Vector` is at run time. Use it through `Vector`. **/
@:noCompletion
class VectorImpl<T> {
	private static function __fromArray<T>(arr:Array<T>):Vector<T> {
		var vec:VectorImpl<T> = new VectorImpl<T>();
		vec.__array = arr;

		return vec;
	}

	public var fixed(get, set):Bool;
	public var length(get, set):Int;

	private var __array:Array<T>;
	private var __fixed:Bool;

	public function new(length:Int = 0, fixed:Bool = false) {
		__array = [];
		this.length = length;
		this.fixed = fixed;
	}

	@:noCompletion public function __set(key:Int, value:T):Void {
		if (key == __array.length) {
			__checkNotFixed();
			__array.push(value);
		} else if (key < 0 || key > __array.length) {
			throw new RangeError('Index $key is out of range (length ${__array.length}).');
		} else {
			__array[key] = value;
		}
	}

	@:noCompletion public function __get(key:Int):T {
		if (key < 0 || key >= __array.length) {
			throw new RangeError('Index $key is out of range (length ${__array.length}).');
		}
		return __array[key];
	}

	public function concat(...args:Dynamic):Vector<T> {
		var out:Array<T> = __array.copy();
		for (arg in args) {
			if (Std.isOfType(arg, VectorImpl)) {
				var vector:VectorImpl<T> = cast arg;
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
		return __fromArray(out);
	}

	public function every(callback:Function, thisObject:Object = null):Bool {
		var arity:Int = __arity(callback);
		for (i in 0...__array.length) {
			var result:Dynamic = __call(callback, thisObject, arity, __array[i], i);
			if (arity < 0) {
				arity = __resolvedArity;
			}
			if (result != true) {
				return false;
			}
		}
		return true;
	}

	public function filter(callback:Function, thisObject:Object = null):Vector<T> {
		var out:Array<T> = [];
		var arity:Int = __arity(callback);
		for (i in 0...__array.length) {
			var value:T = __array[i];
			var result:Dynamic = __call(callback, thisObject, arity, value, i);
			if (arity < 0) {
				arity = __resolvedArity;
			}
			if (result == true) {
				out.push(value);
			}
		}
		return __fromArray(out);
	}

	public function forEach(callback:Function, thisObject:Object = null):Void {
		var arity:Int = __arity(callback);
		for (i in 0...__array.length) {
			__call(callback, thisObject, arity, __array[i], i);
			if (arity < 0) {
				arity = __resolvedArity;
			}
		}
	}

	public inline function indexOf(searchElement:T, fromIndex:Int = 0):Int {
		return __array.indexOf(searchElement, fromIndex);
	}

	public function insertAt(index:Int, element:T):Void {
		__checkNotFixed();
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
		var arity:Int = __arity(callback);
		for (i in 0...__array.length) {
			out.push(cast __call(callback, thisObject, arity, __array[i], i));
			if (arity < 0) {
				arity = __resolvedArity;
			}
		}
		return __fromArray(out);
	}

	public function pop():T {
		__checkNotFixed();
		return __array.pop();
	}

	public function push(arg:T):UInt {
		__checkNotFixed();
		__array.push(arg);
		return __array.length;
	}

	public function removeAt(index:Int):T {
		__checkNotFixed();
		return __array.splice(index, 1)[0];
	}

	public inline function reverse():Vector<T> {
		__array.reverse();
		return this;
	}

	public function shift():T {
		__checkNotFixed();
		return __array.shift();
	}

	public inline function slice(startIndex:Int = 0, endIndex:Int = 16777215):Vector<T> {
		return __fromArray(__array.slice(startIndex, endIndex));
	}

	public function some(callback:Function, thisObject:Object = null):Bool {
		var arity:Int = __arity(callback);
		for (i in 0...__array.length) {
			var result:Dynamic = __call(callback, thisObject, arity, __array[i], i);
			if (arity < 0) {
				arity = __resolvedArity;
			}
			if (result == true) {
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

	public function splice(startIndex:Int, deleteCount:UInt = 2147483647, ...items:T):Vector<T> {
		if (__fixed) {
			// Allowed only where it leaves the length as it is.
			var start:Int = startIndex < 0 ? __array.length + startIndex : startIndex;
			if (start < 0) {
				start = 0;
			}
			if (start > __array.length) {
				start = __array.length;
			}
			var available:Int = __array.length - start;
			var removing:Int = (deleteCount : Int) < 0 || (deleteCount : Int) > available ? available : (deleteCount : Int);
			if (removing != items.length) {
				__checkNotFixed();
			}
		}

		var vec:Vector<T> = __fromArray(__array.splice(startIndex, deleteCount));

		var insertIndex:Int = startIndex;
		for (item in items) {
			__array.insert(insertIndex++, item);
		}

		return vec;
	}

	public inline function toLocaleString():String {
		return __array.toString();
	}

	public inline function toString():String {
		return __array.toString();
	}

	public function unshift(arg:T):UInt {
		__checkNotFixed();
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

	private function set_length(value:Int):Int {
		if (value != __array.length) {
			__checkNotFixed();
		}
		__array.resize(value);
		return value;
	}

	private inline function __checkNotFixed():Void {
		if (__fixed) {
			throw new RangeError("The Vector is fixed, so its length cannot change.");
		}
	}

	// ------------------------------------------------------------------
	// Callbacks

	// The count the last `__call` of an unknown arity settled on.
	@:noCompletion private var __resolvedArity:Int = -1;

	/**
		How many arguments `callback` takes, where the target can say: -1
		where it cannot, which is eval.
	**/
	@:noCompletion private static function __arity(callback:Function):Int {
		#if js
		return untyped callback.length;
		#elseif cpp
		return untyped callback.__ArgCount();
		#elseif jvm
		return __jvmArity(callback);
		#elseif neko
		return untyped __dollar__nargs(callback);
		#else
		return -1;
		#end
	}

	/**
		Calls `callback` with as many of (value, index, this vector) as it
		takes: every one of them past three, and none of them for none.
	**/
	@:noCompletion private function __call(callback:Function, thisObject:Object, arity:Int, value:T, index:Int):Dynamic {
		if (arity < 0) {
			return __callUnknown(callback, thisObject, value, index);
		}
		#if jvm
		// The jvm's Reflect.callMethod cannot be trusted with a count that
		// does not match; this one does, but a direct call is surer still.
		var f:Dynamic = callback;
		return switch (arity) {
			case 0: f();
			case 1: f(value);
			case 2: f(value, index);
			default: f(value, index, this);
		}
		#else
		var args:Array<Dynamic> = switch (arity) {
			case 0: [];
			case 1: [value];
			case 2: [value, index];
			default: [value, index, this];
		}
		return Reflect.callMethod(thisObject, callback, args);
		#end
	}

	/**
		eval says nothing of a function's arity, and refuses a call with more
		arguments than the function takes -- before running it, by throwing
		this string -- while it pads one with fewer. So the arguments go from
		most to fewest, stepping down only on that refusal, and the count the
		first call runs with holds for the rest of the loop. A callback's own
		exception is never a reason to call it again.
	**/
	@:noCompletion private function __callUnknown(callback:Function, thisObject:Object, value:T, index:Int):Dynamic {
		var candidates:Array<Array<Dynamic>> = [[value, index, this], [value, index], [value], []];
		var arity:Int = 3;
		for (args in candidates) {
			try {
				var result:Dynamic = Reflect.callMethod(thisObject, callback, args);
				__resolvedArity = arity;
				return result;
			} catch (e:haxe.Exception) {
				#if eval
				if (e.message == "Something went wrong" && arity > 0) {
					arity--;
					continue;
				}
				#end
				throw e;
			}
		}
		return null;
	}

	#if jvm
	@:noCompletion private static function __jvmArity(callback:Function):Int {
		var cls = java.Lib.toNativeType(Type.getClass(callback));
		if (cls != null) {
			var methods = cls.getDeclaredMethods();
			for (i in 0...methods.length) {
				if (methods[i].getName() == "invoke") {
					return methods[i].getParameterTypes().length;
				}
			}
		}
		return 2;
	}
	#end
}
