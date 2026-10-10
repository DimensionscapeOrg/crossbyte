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
 *
 * **What an element costs.** Reading, writing, `length` and the methods that
 * take no callback are inlined where they are called, and where that code
 * names the element type it works on an array of that type. Natively a read
 * or a write of a `Vector<Int>` takes about 2 ns, against half of one for an
 * `Array`, and `pop`, `shift` and `removeAt` take an element without boxing
 * it, which an `Array`'s `pop` and `shift` do: a push and a pop together
 * cost about 9 ns, against 21 for an `Array`. Code generic over `T`, and a
 * `Vector<Dynamic>`, reach the elements through hxcpp's dynamic array, which
 * boxes each one: 15 to 20 ns. On the jvm the JIT takes the difference away.
 *
 * Natively the elements are kept as the type the code reaching them names,
 * and converted to another when code naming that one reaches them. So a
 * `Vector<Int>` holds ints, as in ActionScript: a `null` put into one
 * through a `Vector<Dynamic>` or generic code reads back as `0` natively,
 * where other targets keep the `null`.
 */
@:forward(concat, every, filter, forEach, map, some, sort, splice, toLocaleString, toString)
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
		#if (cpp && !cppia)
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
		#if (cpp && !cppia)
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
		#if (cpp && !cppia)
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
		#if (cpp && !cppia)
		return untyped __cpp__("::crossbyte_vector_length({0})", this.__store);
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
	A function `every`, `filter`, `forEach`, `map` and `some` call for each
	item: one taking none to three of `(item, index, vector)`, returning `R`.
	A function of a known arity converts to this on its own, and is then
	called directly; an untyped `Function` converts too, and is called
	through reflection with as many arguments as it takes.

	Natively, called directly, an item costs about 17 ns, where
	`Reflect.callMethod` with an argument array made per item costs about
	70. On the jvm the two cost the same, about a nanosecond: it calls a
	callback directly either way.
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
#if (cpp && !cppia)
@:headerCode('
#include <typeinfo>

// The elements of a crossbyte.ds.Vector store as an array of ELEM_. The store
// is a cpp::VirtualArray; when the array under it is not exactly an
// Array_obj<ELEM_>, its elements are converted to one, and the store is
// pinned to that, so generic code writing to it converts what it writes.
template<typename ELEM_>
::Array<ELEM_> crossbyte_vector_retype(::cpp::VirtualArray_obj *inStore)
{
	::Array<ELEM_> items = inStore->base ? ::Array<ELEM_>(::Dynamic(inStore->base)) : ::Array<ELEM_>(0, 0);
	inStore->base = items.mPtr;
	inStore->store = ::hx::arrayFixed;
	HX_OBJ_WB_GET(inStore, inStore->base);
	return items;
}

template<typename ELEM_>
inline void crossbyte_vector_items(::Array<ELEM_> &outItems, const ::Dynamic &inStore)
{
	::cpp::VirtualArray_obj *store = static_cast< ::cpp::VirtualArray_obj *>(inStore.mPtr);
	::hx::ArrayBase *base = store->base;
	if (base && typeid(*base) == typeid(::Array_obj<ELEM_>))
		outItems.mPtr = static_cast< ::Array_obj<ELEM_> *>(base);
	else
		outItems = ::crossbyte_vector_retype<ELEM_>(store);
}

// Generic code, and Array<Dynamic>, which hxcpp makes a cpp::VirtualArray.
inline void crossbyte_vector_items(::cpp::VirtualArray &outItems, const ::Dynamic &inStore)
{
	outItems.mPtr = static_cast< ::cpp::VirtualArray_obj *>(inStore.mPtr);
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

	/** A vector of `items`, which it keeps rather than copies. **/
	@:noCompletion public function new(items:Dynamic, fixed:Bool) {
		#if (cpp && !cppia)
		__store = untyped __cpp__("::crossbyte_vector_store({0})", items);
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
		#if (cpp && !cppia)
		var items:Array<T> = null;
		untyped __cpp__("::crossbyte_vector_items({0}, {1})", items, __store);
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
		if (compare == null) {
			__items().sort(Reflect.compare);
		} else {
			__items().sort(compare);
		}
		return this;
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
