package crossbyte.ds;

import crossbyte.Function;
import crossbyte.Object;
import crossbyte.errors.RangeError;

/**
 * ActionScript's `Vector`: a dense, typed array whose length can be fixed.
 *
 * `v[i]` reads and writes an element on every target. As in ActionScript,
 * reading at or past `length` throws `RangeError`, writing at `length`
 * appends, and writing past it throws.
 *
 * **`fixed`** is enforced: while it is set, anything that would change the
 * length (`push`, `pop`, `shift`, `unshift`, `insertAt`, `removeAt`, a
 * `splice` that adds or removes, setting `length`) throws `RangeError`.
 *
 * **Callbacks** given to `every`, `filter`, `forEach`, `map` and `some` are
 * called with as many of `(item, index, vector)` as they take, and one that
 * throws is never run a second time.
 *
 * A callback is a `VectorCallback`: any function of none to three of those,
 * typed, which is called directly. An untyped `Function` still works, and is
 * called through reflection, as is any callback given a
 * `thisObject`.
 *
 * **A length given up front is not an initialised vector.** `new Vector<T>(n)`
 * and `length = n` grow with whatever the target fills an `Array` with, which
 * is `0` natively and on the jvm but `null` on the interpreter and
 * JavaScript. So `new Vector<Int>(3)` is three zeroes on one target and three
 * nulls on another: adding them throws on the interpreter and quietly gives
 * `NaN` on JavaScript, where ActionScript would fill a numeric vector with 0.
 * Write every element before reading it. A negative length is refused on
 * every target with `RangeError`.
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

/**
	A function `every`, `filter`, `forEach`, `map` and `some` call for each
	item: one taking none to three of `(item, index, vector)`, returning `R`.
	A function of a known arity converts to this on its own, and is then
	called directly; an untyped `Function` converts too, and is called
	through reflection with as many arguments as it takes.

	Called directly, an item costs about 17 ns, where `Reflect.callMethod`
	with an argument array made per item costs 64.
**/
abstract VectorCallback<T, R>(Dynamic) {
	@:from @:noCompletion private static inline function ofNone<T, R>(f:Void->R):VectorCallback<T, R> {
		return cast new VectorCall(0, f);
	}

	@:from @:noCompletion private static inline function ofItem<T, R>(f:T->R):VectorCallback<T, R> {
		return cast new VectorCall(1, f);
	}

	@:from @:noCompletion private static inline function ofItemIndex<T, R>(f:(T, Int)->R):VectorCallback<T, R> {
		return cast new VectorCall(2, f);
	}

	@:from @:noCompletion private static inline function ofAll<T, R>(f:(T, Int, Vector<T>)->R):VectorCallback<T, R> {
		return cast new VectorCall(3, f);
	}

	@:from @:noCompletion private static inline function ofFunction<T, R>(f:Function):VectorCallback<T, R> {
		return cast new VectorCall(-1, f);
	}
}

/** A callback and how many arguments it takes, or -1 when that is found by asking it. **/
@:noCompletion
final class VectorCall {
	public final arity:Int;
	public final callback:Dynamic;

	public function new(arity:Int, callback:Dynamic) {
		this.arity = arity;
		this.callback = callback;
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

	/**
		A new vector of this one's items followed by each of `vectors`', as
		ActionScript's `concat` takes them.
	**/
	public function concat(...vectors:Vector<T>):Vector<T> {
		var out:Array<T> = __array.copy();
		for (vector in vectors) {
			if (vector == null) {
				continue;
			}
			for (item in (vector : VectorImpl<T>).__array) {
				out.push(item);
			}
		}
		return __fromArray(out);
	}

	public function every(callback:VectorCallback<T, Bool>, thisObject:Object = null):Bool {
		var f:Dynamic = __callback(callback);
		var arity:Int = __arityOf(callback, f, thisObject);
		// `every`, `filter`, `forEach`, `map` and `some` all walk the vector
		// this way: never past the length they started with, as in
		// ActionScript, and never past the length it has now, so a callback
		// that shortens it under the loop is not handed the elements that are
		// no longer there.
		var count:Int = __array.length;
		var i:Int = 0;
		while (i < count && i < __array.length) {
			var result:Dynamic = __call(f, thisObject, arity, __array[i], i);
			if (arity < 0) {
				arity = __resolvedArity;
			}
			if (result != true) {
				return false;
			}
			i++;
		}
		return true;
	}

	public function filter(callback:VectorCallback<T, Bool>, thisObject:Object = null):Vector<T> {
		var out:Array<T> = [];
		var f:Dynamic = __callback(callback);
		var arity:Int = __arityOf(callback, f, thisObject);
		var count:Int = __array.length;
		var i:Int = 0;
		while (i < count && i < __array.length) {
			var value:T = __array[i];
			var result:Dynamic = __call(f, thisObject, arity, value, i);
			if (arity < 0) {
				arity = __resolvedArity;
			}
			if (result == true) {
				out.push(value);
			}
			i++;
		}
		return __fromArray(out);
	}

	public function forEach(callback:VectorCallback<T, Void>, thisObject:Object = null):Void {
		var f:Dynamic = __callback(callback);
		var arity:Int = __arityOf(callback, f, thisObject);
		var count:Int = __array.length;
		var i:Int = 0;
		while (i < count && i < __array.length) {
			__call(f, thisObject, arity, __array[i], i);
			if (arity < 0) {
				arity = __resolvedArity;
			}
			i++;
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

	public function map(callback:VectorCallback<T, Dynamic>, thisObject:Object = null):Vector<T> {
		var out:Array<T> = [];
		var f:Dynamic = __callback(callback);
		var arity:Int = __arityOf(callback, f, thisObject);
		var count:Int = __array.length;
		var i:Int = 0;
		while (i < count && i < __array.length) {
			out.push(cast __call(f, thisObject, arity, __array[i], i));
			if (arity < 0) {
				arity = __resolvedArity;
			}
			i++;
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
		if (index < 0 || index >= __array.length) {
			// As `v[i]` does, rather than answering `null` for an index past
			// the end and taking one off the end for a negative one.
			throw new RangeError('Index $index is out of range (length ${__array.length}).');
		}
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

	public function some(callback:VectorCallback<T, Bool>, thisObject:Object = null):Bool {
		var f:Dynamic = __callback(callback);
		var arity:Int = __arityOf(callback, f, thisObject);
		var count:Int = __array.length;
		var i:Int = 0;
		while (i < count && i < __array.length) {
			var result:Dynamic = __call(f, thisObject, arity, __array[i], i);
			if (arity < 0) {
				arity = __resolvedArity;
			}
			if (result == true) {
				return true;
			}
			i++;
		}
		return false;
	}

	/**
		Sorts in place by `compare`, which answers a negative number, zero or
		a positive one as its first argument goes before, with or after its
		second; by `Reflect.compare` when there is none.
	**/
	public function sort(?compare:(T, T) -> Int):Vector<T> {
		if (compare == null) {
			__array.sort(Reflect.compare);
		} else {
			__array.sort(compare);
		}
		return this;
	}

	public function splice(startIndex:Int, deleteCount:UInt = 2147483647, ...items:T):Vector<T> {
		// Where the removal starts, counted back from the end for a negative
		// index and clamped to the vector. The items go back in at this same
		// place, so it is worked out before anything is removed: `insert`
		// reads a negative index against the length it is given, which the
		// removal has already changed.
		var start:Int = startIndex < 0 ? __array.length + startIndex : startIndex;
		if (start < 0) {
			start = 0;
		}
		if (start > __array.length) {
			start = __array.length;
		}

		if (__fixed) {
			// Allowed only where it leaves the length as it is.
			var available:Int = __array.length - start;
			var removing:Int = (deleteCount : Int) < 0 || (deleteCount : Int) > available ? available : (deleteCount : Int);
			if (removing != items.length) {
				__checkNotFixed();
			}
		}

		var vec:Vector<T> = __fromArray(__array.splice(start, deleteCount));

		var insertIndex:Int = start;
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
		if (value < 0) {
			// `Array.resize` takes one: it is `Invalid_argument("Array.fill")`
			// on the interpreter, which no `catch` can hold, and drops
			// elements off the end on the jvm.
			throw new RangeError('Length $value is negative.');
		}
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

	/** The function a callback holds. **/
	@:noCompletion private static inline function __callback<T, R>(callback:VectorCallback<T, R>):Dynamic {
		var held:Dynamic = callback;
		return Std.isOfType(held, VectorCall) ? (cast held : VectorCall).callback : held;
	}

	/**
		How many arguments a callback takes: what its type said, when it said
		and no `thisObject` asks for reflection; otherwise asked of the target.
	**/
	@:noCompletion private static function __arityOf<T, R>(callback:VectorCallback<T, R>, f:Dynamic, thisObject:Object):Int {
		var held:Dynamic = callback;
		var known:Int = Std.isOfType(held, VectorCall) ? (cast held : VectorCall).arity : -1;
		if (known >= 0 && thisObject == null) {
			// Called directly; see __call.
			return known + 0x100;
		}
		return __arity(f);
	}

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
		if (arity >= 0x100) {
			// A callback whose arity its type gave: called directly, with no
			// argument array and no reflection.
			var f:Dynamic = callback;
			return switch (arity - 0x100) {
				case 0: f();
				case 1: f(value);
				case 2: f(value, index);
				default: f(value, index, this);
			}
		}
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
		arguments than the function takes (before running it, by throwing
		this string), while it pads one with fewer. So the arguments go from
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
	/**
		How many arguments a jvm callback takes.

		A function the compiler made declares an `invoke` of its own arity. A
		method reached through `Reflect` does not: it is a `haxe.jvm.Closure`,
		which declares only `invokeDynamic(Object[])` and holds the method it
		will call, so the count is read from that. Guessing it called a
		one-argument method with two, which threw
		`IllegalArgumentException`, and handed a three-argument one `null` for
		the vector.
	**/
	@:noCompletion private static function __jvmArity(callback:Function):Int {
		if (Std.isOfType(callback, jvm.Closure)) {
			return (cast callback : jvm.Closure).method.getParameterTypes().length;
		}

		var cls = java.Lib.toNativeType(Type.getClass(callback));
		if (cls != null) {
			var methods = cls.getDeclaredMethods();
			for (i in 0...methods.length) {
				if (methods[i].getName() == "invoke") {
					return methods[i].getParameterTypes().length;
				}
			}
		}
		// Nothing left to ask, which no callback the compiler or `Reflect`
		// makes reaches. Two is what a Vector callback most often takes.
		return 2;
	}
	#end
}
