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
 * throws is never run a second time. The five are macros, so a call is made
 * from what it is given:
 *
 * - a function written where it is passed becomes the body of the loop, so
 *   no closure is made and nothing is boxed to call it;
 * - any other function of none to three arguments is evaluated once and
 *   called directly;
 * - an untyped `Function` or a `Dynamic` is asked how many arguments it
 *   takes and called through reflection, as is any callback given a
 *   `thisObject`.
 *
 * `sort` is a macro too, and puts a comparator written where it is passed
 * into the sort itself. Being macros, these six are not values:
 * `vector.forEach` alone does not compile, where `f -> vector.forEach(f)`
 * does. A vector held as `Dynamic` has them as methods.
 *
 * **A length given up front is not an initialised vector.** `new Vector<T>(n)`
 * and `length = n` grow with whatever the target fills an `Array` with, which
 * is `0` natively and on the jvm but `null` on the interpreter and
 * JavaScript. So `new Vector<Int>(3)` is three zeroes on one target and three
 * nulls on another: adding them throws on the interpreter and quietly gives
 * `NaN` on JavaScript, where ActionScript would fill a numeric vector with 0.
 * Write every element before reading it. A negative length is refused on
 * every target with `RangeError`.
 *
 * **What it costs.** Reading, writing, `length`, `for` loops and the methods
 * that take no callback are inlined where they are called, and where that
 * code names the element type it works on an array of that type. Natively,
 * an element of a `Vector<Int>` takes about 1.2 ns to read or write, against
 * 0.6 for an `Array<Int>`, and 0.8 ns in `for (item in vector)`; a
 * `Vector<Float>` reads as fast as an `Array<Float>`. `forEach` given a
 * function written in place costs about 2 ns an element, and `sort` given
 * one about 60 for a thousand elements, against 155 for an `Array`; `sort()`
 * of a `Vector<Int>` costs about 7. `pop`, `shift` and
 * `removeAt` take an element without boxing it, which an `Array`'s `pop` and
 * `shift` do, so a push and a pop together cost 8 ns, against 20 for an
 * `Array`. A function passed as a value costs about 30 ns a call natively,
 * where hxcpp boxes what it is passed. Code generic over `T`, and a
 * `Vector<Dynamic>`, reach the elements through hxcpp's dynamic array, which
 * boxes each one: 15 to 20 ns. On the jvm and JavaScript a `Vector` costs
 * what an `Array` does.
 *
 * Natively the elements are kept as the type the code reaching them names,
 * and converted to another when code naming that one reaches them. So a
 * `Vector<Int>` holds ints, as in ActionScript: a `null` put into one
 * through a `Vector<Dynamic>` or generic code reads back as `0` natively,
 * where other targets keep the `null`.
 */
@:forward(concat, splice, toLocaleString, toString)
abstract Vector<T>(VectorImpl<T>) from VectorImpl<T> to VectorImpl<T> {
	public var fixed(get, set):Bool;
	public var length(get, set):Int;

	public inline function new(length:Int = 0, fixed:Bool = false) {
		var items:Array<T> = [];
		if (length != 0) {
			if (length < 0) {
				VectorImpl.__negativeLength(length);
			}
			items.resize(length);
		}
		this = new VectorImpl<T>(items, fixed);
	}

	/**
		A new vector of `array`'s elements, as ActionScript's `Vector.<T>(array)`
		makes one. The array is copied, so neither changes the other.
	**/
	public static inline function ofArray<T>(array:Array<T>):Vector<T> {
		return new VectorImpl<T>(array.copy(), false);
	}

	/** A new array of this vector's elements. **/
	public inline function toArray():Array<T> {
		return this.__items().copy();
	}

	/**
		`for (item in vector)`: each element in order, at what an `Array`'s
		loop costs. As with an `Array`, an element pushed while the loop runs
		is reached, and one removed is not.
	**/
	public inline function iterator():VectorIterator<T> {
		return new VectorIterator<T>(this);
	}

	/** `for (index => item in vector)`, as `iterator` goes. **/
	public inline function keyValueIterator():VectorKeyValueIterator<T> {
		return new VectorKeyValueIterator<T>(this);
	}

	/**
		Whether `callback` answers `true` for every element, stopping at the
		first it does not.
	**/
	public macro function every(ethis:haxe.macro.Expr, callback:haxe.macro.Expr, ?thisObject:haxe.macro.Expr):haxe.macro.Expr {
		return crossbyte._internal.macro.VectorMacro.call(ethis, "__every", "__everyBy", callback, thisObject);
	}

	/** A new vector of the elements `callback` answers `true` for, in order. **/
	public macro function filter(ethis:haxe.macro.Expr, callback:haxe.macro.Expr, ?thisObject:haxe.macro.Expr):haxe.macro.Expr {
		return crossbyte._internal.macro.VectorMacro.call(ethis, "__filter", "__filterBy", callback, thisObject);
	}

	/** Calls `callback` for each element, in order. **/
	public macro function forEach(ethis:haxe.macro.Expr, callback:haxe.macro.Expr, ?thisObject:haxe.macro.Expr):haxe.macro.Expr {
		return crossbyte._internal.macro.VectorMacro.call(ethis, "__forEach", "__forEachBy", callback, thisObject);
	}

	/**
		A new vector of what `callback` returns for each element, in order.
		Typed by what the callback returns: an `Int` vector mapped to text is
		a `Vector<String>`. ActionScript's `map` keeps the element type, which
		a callback returning that type still does here.
	**/
	public macro function map(ethis:haxe.macro.Expr, callback:haxe.macro.Expr, ?thisObject:haxe.macro.Expr):haxe.macro.Expr {
		return crossbyte._internal.macro.VectorMacro.call(ethis, "__map", "__mapBy", callback, thisObject);
	}

	/**
		Whether `callback` answers `true` for any element, stopping at the
		first it does.
	**/
	public macro function some(ethis:haxe.macro.Expr, callback:haxe.macro.Expr, ?thisObject:haxe.macro.Expr):haxe.macro.Expr {
		return crossbyte._internal.macro.VectorMacro.call(ethis, "__some", "__someBy", callback, thisObject);
	}

	/**
		Sorts in place by `compare`, which answers a negative number, zero or
		a positive one as its first argument goes before, with or after its
		second, and returns this vector. Without one, numbers and strings go
		in ascending order and anything else in `Reflect.compare`'s.

		The sort is stable: elements `compare` calls equal keep their order.
		Like the callback methods it is a macro, so a comparator written where
		it is passed becomes part of the sort natively. One that throws leaves
		the vector as it was, but on JavaScript, which sorts in place.
	**/
	public macro function sort(ethis:haxe.macro.Expr, ?compare:haxe.macro.Expr):haxe.macro.Expr {
		return crossbyte._internal.macro.VectorMacro.sort(ethis, compare);
	}

	/**
		What `sort` becomes given a comparator written where it is called, or
		the typed one it is given for elements without one.

		`Array.sort` is not stable on every target: the interpreter's is not,
		and the jvm's is a quicksort, quadratic at worst. So JavaScript sorts
		with its own, which is stable (ES2019); the jvm with its own TimSort,
		on a copy written back once it is done; and every other target with
		`__merge`, which puts the comparator in the sort itself.
	**/
	@:noCompletion public inline function __sort(f:(T, T) -> Int):Vector<T> {
		#if js
		this.__items().sort(f);
		#elseif (jvm && !macro)
		__sortOnJvm(f);
		#else
		var items:Array<T> = this.__items();
		var count:Int = items.length;
		if (count > 1) {
			var sorted:Array<T> = __merge(items.copy(), items.copy(), f, 1);
			var x:Int = 0;
			while (x < count) {
				items[x] = sorted[x];
				x++;
			}
		}
		#end
		return this;
	}

	/**
		What `sort` becomes given a comparator that is a value. Natively,
		calling one boxes both elements every time, so each element is boxed
		once, the boxes are sorted (runs of eight by insertion, then merged),
		and the elements are put back from them. Elsewhere as `__sort`.
	**/
	@:noCompletion public inline function __sortCalling(f:(T, T) -> Int):Vector<T> {
		#if (cpp && !cppia && !macro)
		var items:Array<T> = this.__items();
		var count:Int = items.length;
		if (count > 1) {
			var boxes:Array<Null<T>> = [];
			boxes.resize(count);
			var x:Int = 0;
			while (x < count) {
				boxes[x] = items[x];
				x++;
			}
			// Each run of eight sorted by insertion first, stably, which takes
			// fewer calls of the comparator than merging it from ones.
			var call:(Null<T>, Null<T>) -> Int = cast f;
			var start:Int = 0;
			while (start < count) {
				var end:Int = count - start > 8 ? start + 8 : count;
				var a:Int = start + 1;
				while (a < end) {
					var item:Null<T> = boxes[a];
					var b:Int = a - 1;
					while (b >= start) {
						var order:Int = call(boxes[b], item);
						if (order <= 0) {
							break;
						}
						boxes[b + 1] = boxes[b];
						b--;
					}
					boxes[b + 1] = item;
					a++;
				}
				start = end;
			}
			var sorted:Array<Null<T>> = __merge(boxes, boxes.copy(), call, 8);
			// The boxes are read here, after the sort, which keeps them
			// reachable from this frame while the comparator runs and may
			// collect.
			x = 0;
			while (x < count) {
				items[x] = sorted[x];
				x++;
			}
		}
		return this;
		#else
		return __sort(f);
		#end
	}

	/**
		`sort()` of a `Vector<Int>`. Equal ints cannot be told apart, so the
		order of equal elements does not matter, and the target's own sort of
		plain values does: natively and on the jvm. `ascending` is the typed
		comparator for the rest.
	**/
	@:noCompletion public inline function __sortInts(ascending:(T, T) -> Int):Vector<T> {
		#if (cpp && !cppia && !macro)
		var items:Array<T> = this.__items();
		var sorted:Bool = untyped __cpp__("::crossbyte_vector_sort_values({0})", items);
		return sorted ? this : __sort(ascending);
		#elseif (jvm && !macro)
		var items:Array<T> = this.__items();
		var count:Int = items.length;
		var values:java.NativeArray<Int> = new java.NativeArray<Int>(count);
		var x:Int = 0;
		while (x < count) {
			values[x] = cast items[x];
			x++;
		}
		java.util.Arrays.sort(values);
		x = 0;
		while (x < count) {
			items[x] = cast values[x];
			x++;
		}
		return this;
		#else
		return __sort(ascending);
		#end
	}

	/** `sort()` of a `Vector<String>`; see `__sortInts`. Natively only. **/
	@:noCompletion public inline function __sortStrings(ascending:(T, T) -> Int):Vector<T> {
		#if (cpp && !cppia && !macro)
		var items:Array<T> = this.__items();
		var sorted:Bool = untyped __cpp__("::crossbyte_vector_sort_values({0})", items);
		return sorted ? this : __sort(ascending);
		#else
		return __sort(ascending);
		#end
	}

	/**
		A stable merge sort, bottom-up, of `from` by `f`, using `to` as space,
		from runs of `width` already in order: answers whichever of the two
		holds the result. It compares in one place only, so that a comparator
		written where `sort` is called is put in that place rather than called
		for every comparison.
	**/
	@:noCompletion private static inline function __merge<E>(from:Array<E>, to:Array<E>, f:(E, E) -> Int, width:Int):Array<E> {
		var count:Int = from.length;
		while (width < count) {
			var left:Int = 0;
			while (left < count) {
				var middle:Int = count - left > width ? left + width : count;
				var right:Int = count - middle > width ? middle + width : count;
				var i:Int = left;
				var j:Int = middle;
				var k:Int = left;
				while (k < right) {
					// From the left run while it lasts, unless the right run's
					// next goes strictly before it: so equal elements keep
					// their order. The order is read as an Int, which a
					// comparator called through Dynamic answers boxed.
					var fromLeft:Bool = i < middle;
					if (fromLeft && j < right) {
						var order:Int = f(from[i], from[j]);
						fromLeft = order <= 0;
					}
					if (fromLeft) {
						to[k] = from[i];
						i++;
					} else {
						to[k] = from[j];
						j++;
					}
					k++;
				}
				left = right;
			}
			var merged:Array<E> = to;
			to = from;
			from = merged;
			if (width > count - width) {
				break;
			}
			width += width;
		}
		return from;
	}

	#if (jvm && !macro)
	@:noCompletion private inline function __sortOnJvm(f:(T, T) -> Int):Void {
		var items:Array<T> = this.__items();
		var sorted:Array<T> = items.copy();
		java.util.Arrays.sort(@:privateAccess sorted.__a, 0, sorted.length, new VectorComparator<T>(f));
		var x:Int = 0;
		while (x < sorted.length) {
			items[x] = sorted[x];
			x++;
		}
	}
	#end

	@:noCompletion public inline function __sortBy(compare:(T, T) -> Int):Vector<T> {
		return this.sort(compare);
	}

	// What the five above become where they are called (see VectorMacro):
	// a loop calling a function of (item, index, vector), or the vector's
	// own method. Each loop walks the vector as that method does: never
	// past the length it started with, as in ActionScript, and never past
	// the length it has now, so a callback that shortens it is not handed
	// the elements that are no longer there.

	@:noCompletion public inline function __every(f:(T, Int, Vector<T>) -> Bool):Bool {
		var count:Int = get_length();
		var i:Int = 0;
		var all:Bool = true;
		while (i < count) {
			var items:Array<T> = this.__items();
			if (i >= items.length) {
				break;
			}
			if (!f(items[i], i, this)) {
				all = false;
				break;
			}
			i++;
		}
		return all;
	}

	@:noCompletion public inline function __filter(f:(T, Int, Vector<T>) -> Bool):Vector<T> {
		var out:Array<T> = [];
		var count:Int = get_length();
		var i:Int = 0;
		while (i < count) {
			var items:Array<T> = this.__items();
			if (i >= items.length) {
				break;
			}
			var item:T = items[i];
			if (f(item, i, this)) {
				out.push(item);
			}
			i++;
		}
		return new VectorImpl<T>(out, false);
	}

	@:noCompletion public inline function __forEach(f:(T, Int, Vector<T>) -> Void):Void {
		var count:Int = get_length();
		var i:Int = 0;
		while (i < count) {
			var items:Array<T> = this.__items();
			if (i >= items.length) {
				break;
			}
			f(items[i], i, this);
			i++;
		}
	}

	@:noCompletion public inline function __map<R>(f:(T, Int, Vector<T>) -> R):Vector<R> {
		var out:Array<R> = [];
		var count:Int = get_length();
		var i:Int = 0;
		while (i < count) {
			var items:Array<T> = this.__items();
			if (i >= items.length) {
				break;
			}
			out.push(f(items[i], i, this));
			i++;
		}
		return new VectorImpl<R>(out, false);
	}

	@:noCompletion public inline function __some(f:(T, Int, Vector<T>) -> Bool):Bool {
		var count:Int = get_length();
		var i:Int = 0;
		var any:Bool = false;
		while (i < count) {
			var items:Array<T> = this.__items();
			if (i >= items.length) {
				break;
			}
			if (f(items[i], i, this)) {
				any = true;
				break;
			}
			i++;
		}
		return any;
	}

	@:noCompletion public inline function __everyBy(callback:VectorCallback<T, Bool>, thisObject:Object):Bool {
		return this.every(callback, thisObject);
	}

	@:noCompletion public inline function __filterBy(callback:VectorCallback<T, Bool>, thisObject:Object):Vector<T> {
		return this.filter(callback, thisObject);
	}

	@:noCompletion public inline function __forEachBy(callback:VectorCallback<T, Void>, thisObject:Object):Void {
		this.forEach(callback, thisObject);
	}

	@:noCompletion public inline function __mapBy<R>(callback:VectorCallback<T, R>, thisObject:Object):Vector<R> {
		return this.map(callback, thisObject);
	}

	@:noCompletion public inline function __someBy(callback:VectorCallback<T, Bool>, thisObject:Object):Bool {
		return this.some(callback, thisObject);
	}

	@:arrayAccess @:noCompletion private inline function __arrayGet(index:Int):T {
		var items:Array<T> = this.__items();
		if (index < 0 || index >= items.length) {
			VectorImpl.__outOfRange(index, items.length);
		}
		return items[index];
	}

	@:arrayAccess @:noCompletion private inline function __arraySet(index:Int, value:T):T {
		var items:Array<T> = this.__items();
		if (index >= 0 && index < items.length) {
			items[index] = value;
		} else {
			if (index != items.length) {
				VectorImpl.__outOfRange(index, items.length);
			}
			if (this.__fixed) {
				VectorImpl.__lengthFixed();
			}
			items.push(value);
		}
		return value;
	}

	public inline function indexOf(searchElement:T, fromIndex:Int = 0):Int {
		return this.__items().indexOf(searchElement, fromIndex);
	}

	public inline function insertAt(index:Int, element:T):Void {
		if (this.__fixed) {
			VectorImpl.__lengthFixed();
		}
		this.__items().insert(index, element);
	}

	public inline function join(sep:String = ","):String {
		return this.__items().join(sep);
	}

	public inline function lastIndexOf(searchElement:T, fromIndex:Int = 0x7fffffff):Int {
		return this.__items().lastIndexOf(searchElement, fromIndex);
	}

	public inline function pop():T {
		if (this.__fixed) {
			VectorImpl.__lengthFixed();
		}
		var items:Array<T> = this.__items();
		#if (cpp && !cppia && !macro)
		return untyped __cpp__("::crossbyte_vector_take({0}, {1})", items, items.length - 1);
		#else
		return items.pop();
		#end
	}

	public inline function push(value:T):UInt {
		if (this.__fixed) {
			VectorImpl.__lengthFixed();
		}
		return this.__items().push(value);
	}

	public inline function removeAt(index:Int):T {
		if (this.__fixed) {
			VectorImpl.__lengthFixed();
		}
		var items:Array<T> = this.__items();
		if (index < 0 || index >= items.length) {
			// As `v[i]` does, rather than answering `null` for an index past
			// the end and taking one off the end for a negative one.
			VectorImpl.__outOfRange(index, items.length);
		}
		#if (cpp && !cppia && !macro)
		return untyped __cpp__("::crossbyte_vector_take({0}, {1})", items, index);
		#else
		return items.splice(index, 1)[0];
		#end
	}

	public inline function reverse():Vector<T> {
		this.__items().reverse();
		return this;
	}

	public inline function shift():T {
		if (this.__fixed) {
			VectorImpl.__lengthFixed();
		}
		var items:Array<T> = this.__items();
		#if (cpp && !cppia && !macro)
		return untyped __cpp__("::crossbyte_vector_take({0}, 0)", items);
		#else
		return items.shift();
		#end
	}

	public inline function slice(startIndex:Int = 0, endIndex:Int = 16777215):Vector<T> {
		return new VectorImpl<T>(this.__items().slice(startIndex, endIndex), false);
	}

	public inline function unshift(value:T):UInt {
		if (this.__fixed) {
			VectorImpl.__lengthFixed();
		}
		var items:Array<T> = this.__items();
		items.unshift(value);
		return items.length;
	}

	private inline function get_fixed():Bool {
		return this.__fixed;
	}

	private inline function set_fixed(value:Bool):Bool {
		return this.__fixed = value;
	}

	private inline function get_length():Int {
		#if (cpp && !cppia && !macro)
		var length:Int = untyped __cpp__("::crossbyte_vector_length({0})", this.__store);
		return length;
		#else
		return this.__items().length;
		#end
	}

	private inline function set_length(value:Int):Int {
		this.length = value;
		return value;
	}
}

/**
	A callback `every`, `filter`, `forEach`, `map` and `some` cannot call
	directly where they are called (see `Vector`): an untyped `Function` or a
	`Dynamic`, or any callback given a `thisObject`. A vector held as
	`Dynamic` takes its callbacks as these too.

	A function of a known arity converts to this on its own, and is called
	directly; an untyped `Function` converts too, and is called through
	reflection with as many of `(item, index, vector)` as it takes. Natively
	that costs about 70 ns an item, against 30 for a function called
	directly; on the jvm the two cost the same, since it calls a callback
	directly either way.
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

/**
	What `for (item in vector)` walks, made and taken apart where the loop is,
	so nothing is allocated. Each step reaches the elements anew, as `v[i]`
	does, so a loop sees what its body does to the vector.
**/
@:noCompletion
final class VectorIterator<T> {
	private final __vector:VectorImpl<T>;
	private var __items:Array<T>;
	private var __index:Int;

	public inline function new(vector:VectorImpl<T>) {
		__vector = vector;
		__items = null;
		__index = 0;
	}

	public inline function hasNext():Bool {
		__items = __vector.__items();
		return __index < __items.length;
	}

	public inline function next():T {
		return __items[__index++];
	}
}

/** What `for (index => item in vector)` walks; see `VectorIterator`. **/
@:noCompletion
final class VectorKeyValueIterator<T> {
	private final __vector:VectorImpl<T>;
	private var __items:Array<T>;
	private var __index:Int;

	public inline function new(vector:VectorImpl<T>) {
		__vector = vector;
		__items = null;
		__index = 0;
	}

	public inline function hasNext():Bool {
		__items = __vector.__items();
		return __index < __items.length;
	}

	public inline function next():{key:Int, value:T} {
		var index:Int = __index++;
		return {key: index, value: __items[index]};
	}
}

#if (jvm && !macro)
/** What `Vector.sort` hands the jvm's own sort, a stable TimSort. **/
@:noCompletion
final class VectorComparator<T> implements java.util.Comparator<T> {
	private final __compare:(T, T) -> Int;

	public function new(compare:(T, T) -> Int) {
		__compare = compare;
	}

	public function compare(a:T, b:T):Int {
		return __compare(a, b);
	}

	public function equals(other:Dynamic):Bool {
		return this == other;
	}
}
#end

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

/**
	What a `Vector` is at run time. Use it through `Vector`.

	Its elements are held untyped, in `__store`, and reached through
	`__items`, which answers them as an array of whatever element type the
	code calling it names.

	Natively the store is always a `cpp::VirtualArray`, the array hxcpp gives
	code that does not know the element type, so generic code and a
	`Vector<Dynamic>` use it as they find it. Code that names the type gets
	the typed array under it: in one comparison when the elements are already
	kept as that type, and otherwise after they are converted to it and the
	store is pinned to it, as hxcpp itself pins one an `Array` is made from.
	It never copies the elements away from the store, so a `Vector<Int>`
	passed as a `Vector<Dynamic>` is still the one vector, and a loop
	walking the store sees what a callback writes to it.
**/
@:noCompletion
#if (cpp && !cppia && !macro)
@:headerCode('
#include <typeinfo>

// The elements of a crossbyte.ds.Vector, as an array of ELEM_.
//
// The store is a cpp::VirtualArray, which generic code uses as it is. The
// typed array under it, once code naming ELEM_ has reached it, is kept in
// ioTyped, and ioKind is set to the address that stands for ELEM_, so
// reaching it again takes one comparison. From then the store is pinned
// (arrayFixed): generic code writing to it converts what it writes, rather
// than moving the elements to another array, so the typed array stays the
// store until code naming another type reaches it and converts them again.
template<typename ELEM_> struct crossbyte_vector_kind { static char id; };
template<typename ELEM_> char crossbyte_vector_kind<ELEM_>::id;

inline ::hx::Object *crossbyte_vector_object(::hx::Object *inObject) { return inObject; }
template<typename OBJ_>
inline ::hx::Object *crossbyte_vector_object(const ::hx::ObjectPtr<OBJ_> &inObject) { return inObject.mPtr; }

template<typename ELEM_, typename BOX_>
void crossbyte_vector_pin(::Array<ELEM_> &outItems, const BOX_ &inBox, ::Dynamic &ioStore, ::Dynamic &ioTyped, void *&ioKind)
{
	::cpp::VirtualArray_obj *store = static_cast< ::cpp::VirtualArray_obj *>(ioStore.mPtr);
	::hx::ArrayBase *base = store->base;
	if (base && typeid(*base) == typeid(::Array_obj<ELEM_>))
	{
		outItems.mPtr = static_cast< ::Array_obj<ELEM_> *>(base);
	}
	else
	{
		outItems = base ? ::Array<ELEM_>(::Dynamic(base)) : ::Array<ELEM_>(0, 0);
		store->base = outItems.mPtr;
		HX_OBJ_WB_GET(store, store->base);
	}
	store->store = ::hx::arrayFixed;
	ioTyped = outItems;
	HX_OBJ_WB_GET(::crossbyte_vector_object(inBox), ioTyped.mPtr);
	ioKind = &::crossbyte_vector_kind<ELEM_>::id;
}

template<typename ELEM_, typename BOX_>
inline void crossbyte_vector_items(::Array<ELEM_> &outItems, const BOX_ &inBox, ::Dynamic &ioStore, ::Dynamic &ioTyped, void *&ioKind)
{
	if (ioKind == &::crossbyte_vector_kind<ELEM_>::id)
		outItems.mPtr = static_cast< ::Array_obj<ELEM_> *>(ioTyped.mPtr);
	else
		::crossbyte_vector_pin<ELEM_>(outItems, inBox, ioStore, ioTyped, ioKind);
}

// Generic code, and Array<Dynamic>, which hxcpp makes a cpp::VirtualArray.
template<typename BOX_>
inline void crossbyte_vector_items(::cpp::VirtualArray &outItems, const BOX_ &, ::Dynamic &ioStore, ::Dynamic &, void *&)
{
	outItems.mPtr = static_cast< ::cpp::VirtualArray_obj *>(ioStore.mPtr);
}

// How many elements a store holds, which needs no typed array.
inline int crossbyte_vector_length(const ::Dynamic &inStore)
{
	return (int)static_cast< ::cpp::VirtualArray_obj *>(inStore.mPtr)->size();
}

// Removes the element at inIndex and answers it, or the default of the type
// where there is none. The pop and shift of an Array answer a Null<T>, so an
// int or a float they take is boxed on the way out; this takes it as it is.
template<typename ELEM_>
inline ELEM_ crossbyte_vector_take(::Array<ELEM_> &inItems, int inIndex)
{
	::Array_obj<ELEM_> *items = inItems.mPtr;
	int length = (int)items->length;
	if (inIndex < 0 || inIndex >= length)
		return ELEM_();
	ELEM_ value = ((ELEM_ *)items->GetBase())[inIndex];
	if (inIndex == length - 1)
		items->resize(inIndex);
	else
		items->RemoveElement(inIndex);
	return value;
}

inline ::Dynamic crossbyte_vector_take(::cpp::VirtualArray &inItems, int inIndex)
{
	if (inIndex < 0 || inIndex >= (int)inItems->size())
		return ::Dynamic();
	::Dynamic value = inItems->__get(inIndex);
	inItems->removeAt(inIndex);
	return value;
}

// Sorts plain values ascending with std::sort, which is right for ints and
// strings, whose equal elements cannot be told apart. Generic code, which has
// the dynamic array, answers false and sorts another way.
template<typename ELEM_>
inline bool crossbyte_vector_sort_values(::Array<ELEM_> &ioItems)
{
	ioItems->sortAscending();
	return true;
}

inline bool crossbyte_vector_sort_values(::cpp::VirtualArray &)
{
	return false;
}

// A store for the elements of a new vector: the cpp::VirtualArray it already
// is, or one pinned to the typed array it is.
inline ::Dynamic crossbyte_vector_store(const ::Dynamic &inItems)
{
	::cpp::VirtualArray_obj *store = dynamic_cast< ::cpp::VirtualArray_obj *>(inItems.mPtr);
	if (store)
		return store;
	return new ::cpp::VirtualArray_obj(dynamic_cast< ::hx::ArrayBase *>(inItems.mPtr), true);
}
')
#end
class VectorImpl<T> {
	public var fixed(get, set):Bool;
	public var length(get, set):Int;

	@:noCompletion public var __store:Dynamic;
	@:noCompletion public var __fixed:Bool;

	#if (cpp && !cppia && !macro)
	/** The typed array under the store, once code naming its type reached it. **/
	@:noCompletion public var __typed:Dynamic;

	/** What stands for the type of `__typed`; see the header code. **/
	@:noCompletion public var __kind:cpp.RawPointer<cpp.Void>;
	#end

	/** A vector of `items`, which it keeps rather than copies. **/
	@:noCompletion public function new(items:Dynamic, fixed:Bool) {
		#if (cpp && !cppia && !macro)
		__store = untyped __cpp__("::crossbyte_vector_store({0})", items);
		__typed = null;
		__kind = null;
		#else
		__store = items;
		#end
		__fixed = fixed;
	}

	/**
		The elements, as an array of `T`: of the type the calling code names,
		and the dynamic array natively where it names none.
	**/
	@:noCompletion public inline function __items():Array<T> {
		#if (cpp && !cppia && !macro)
		var items:Array<T> = null;
		untyped __cpp__("::crossbyte_vector_items({0}, {1}, {2}, {3}, {4})", items, this, __store, __typed, __kind);
		return items;
		#else
		return cast __store;
		#end
	}

	@:noCompletion public static function __outOfRange(index:Int, length:Int):Void {
		throw new RangeError('Index $index is out of range (length $length).');
	}

	@:noCompletion public static function __lengthFixed():Void {
		throw new RangeError("The Vector is fixed, so its length cannot change.");
	}

	@:noCompletion public static function __negativeLength(length:Int):Void {
		// `Array.resize` takes one: it is `Invalid_argument("Array.fill")` on
		// the interpreter, which no `catch` can hold, and drops elements off
		// the end on the jvm.
		throw new RangeError('Length $length is negative.');
	}

	/**
		A new vector of this one's items followed by each of `vectors`', as
		ActionScript's `concat` takes them.
	**/
	public function concat(...vectors:Vector<T>):Vector<T> {
		var out:Array<T> = __items().copy();
		for (vector in vectors) {
			if (vector == null) {
				continue;
			}
			for (item in (vector : VectorImpl<T>).__items()) {
				out.push(item);
			}
		}
		return new VectorImpl<T>(out, false);
	}

	public function every(callback:VectorCallback<T, Bool>, thisObject:Object = null):Bool {
		var items:Array<T> = __items();
		var f:Dynamic = __callback(callback);
		var arity:Int = __arityOf(callback, f, thisObject);
		// `every`, `filter`, `forEach`, `map` and `some` all walk the vector
		// this way: never past the length they started with, as in
		// ActionScript, and never past the length it has now, so a callback
		// that shortens it under the loop is not handed the elements that are
		// no longer there.
		var count:Int = items.length;
		var i:Int = 0;
		while (i < count && i < items.length) {
			var result:Dynamic = __call(f, thisObject, arity, items[i], i);
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
		var items:Array<T> = __items();
		var out:Array<T> = [];
		var f:Dynamic = __callback(callback);
		var arity:Int = __arityOf(callback, f, thisObject);
		var count:Int = items.length;
		var i:Int = 0;
		while (i < count && i < items.length) {
			var value:T = items[i];
			var result:Dynamic = __call(f, thisObject, arity, value, i);
			if (arity < 0) {
				arity = __resolvedArity;
			}
			if (result == true) {
				out.push(value);
			}
			i++;
		}
		return new VectorImpl<T>(out, false);
	}

	public function forEach(callback:VectorCallback<T, Void>, thisObject:Object = null):Void {
		var items:Array<T> = __items();
		var f:Dynamic = __callback(callback);
		var arity:Int = __arityOf(callback, f, thisObject);
		var count:Int = items.length;
		var i:Int = 0;
		while (i < count && i < items.length) {
			__call(f, thisObject, arity, items[i], i);
			if (arity < 0) {
				arity = __resolvedArity;
			}
			i++;
		}
	}

	/**
		A new vector of what `callback` returns for each item, in order. Typed
		by what the callback returns: an `Int` vector mapped to text is a
		`Vector<String>`. ActionScript's `map` keeps the element type, which a
		callback returning that type still does here.
	**/
	public function map<R>(callback:VectorCallback<T, R>, thisObject:Object = null):Vector<R> {
		var items:Array<T> = __items();
		var out:Array<R> = [];
		var f:Dynamic = __callback(callback);
		var arity:Int = __arityOf(callback, f, thisObject);
		var count:Int = items.length;
		var i:Int = 0;
		while (i < count && i < items.length) {
			out.push(cast __call(f, thisObject, arity, items[i], i));
			if (arity < 0) {
				arity = __resolvedArity;
			}
			i++;
		}
		return new VectorImpl<R>(out, false);
	}

	public function some(callback:VectorCallback<T, Bool>, thisObject:Object = null):Bool {
		var items:Array<T> = __items();
		var f:Dynamic = __callback(callback);
		var arity:Int = __arityOf(callback, f, thisObject);
		var count:Int = items.length;
		var i:Int = 0;
		while (i < count && i < items.length) {
			var result:Dynamic = __call(f, thisObject, arity, items[i], i);
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
		return (this : Vector<T>).__sortCalling(compare == null ? Reflect.compare : compare);
	}

	public function splice(startIndex:Int, deleteCount:UInt = 2147483647, ...items:T):Vector<T> {
		var array:Array<T> = __items();
		// Where the removal starts, counted back from the end for a negative
		// index and clamped to the vector. The items go back in at this same
		// place, so it is worked out before anything is removed: `insert`
		// reads a negative index against the length it is given, which the
		// removal has already changed.
		var start:Int = startIndex < 0 ? array.length + startIndex : startIndex;
		if (start < 0) {
			start = 0;
		}
		if (start > array.length) {
			start = array.length;
		}

		if (__fixed) {
			// Allowed only where it leaves the length as it is.
			var available:Int = array.length - start;
			var removing:Int = (deleteCount : Int) < 0 || (deleteCount : Int) > available ? available : (deleteCount : Int);
			if (removing != items.length) {
				__lengthFixed();
			}
		}

		var vec:Vector<T> = new VectorImpl<T>(array.splice(start, deleteCount), false);

		var insertIndex:Int = start;
		for (item in items) {
			array.insert(insertIndex++, item);
		}

		return vec;
	}

	// The methods `Vector` inlines where it is called, for a vector held as
	// `Dynamic`, which finds them here. Each is that same inlined code.

	public function indexOf(searchElement:T, fromIndex:Int = 0):Int {
		return (this : Vector<T>).indexOf(searchElement, fromIndex);
	}

	public function insertAt(index:Int, element:T):Void {
		(this : Vector<T>).insertAt(index, element);
	}

	public function join(sep:String = ","):String {
		return (this : Vector<T>).join(sep);
	}

	public function lastIndexOf(searchElement:T, fromIndex:Int = 0x7fffffff):Int {
		return (this : Vector<T>).lastIndexOf(searchElement, fromIndex);
	}

	public function pop():T {
		return (this : Vector<T>).pop();
	}

	public function push(value:T):UInt {
		return (this : Vector<T>).push(value);
	}

	public function removeAt(index:Int):T {
		return (this : Vector<T>).removeAt(index);
	}

	public function reverse():Vector<T> {
		return (this : Vector<T>).reverse();
	}

	public function shift():T {
		return (this : Vector<T>).shift();
	}

	public function slice(startIndex:Int = 0, endIndex:Int = 16777215):Vector<T> {
		return (this : Vector<T>).slice(startIndex, endIndex);
	}

	public function unshift(value:T):UInt {
		return (this : Vector<T>).unshift(value);
	}

	public function toLocaleString():String {
		return __items().toString();
	}

	public function toString():String {
		return __items().toString();
	}

	private inline function get_fixed():Bool {
		return __fixed;
	}

	private inline function set_fixed(value:Bool):Bool {
		return __fixed = value;
	}

	private inline function get_length():Int {
		return __items().length;
	}

	private function set_length(value:Int):Int {
		var items:Array<T> = __items();
		if (value < 0) {
			__negativeLength(value);
		}
		if (value != items.length && __fixed) {
			__lengthFixed();
		}
		items.resize(value);
		return value;
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
		#if macro
		return -1;
		#elseif js
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
		#if (jvm && !macro)
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

	#if (jvm && !macro)
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
