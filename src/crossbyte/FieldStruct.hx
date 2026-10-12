package crossbyte;

import haxe.ds.StringMap;

@:noCompletion
private typedef BaseStruct<T = Dynamic> = StringMap<T>;

/**
 * A typed dynamic field bag backed by `StringMap`.
 *
 * `FieldStruct<T>` gives CrossByte a compact way to model dynamic, string-keyed
 * records while still constraining the value lane to `T`. It supports dot access,
 * bracket access, `exists`, `get`, `delete` and `clear`, and iteration over
 * keys or key/value pairs: `for (name => value in fields)`, or `keys()`,
 * `values()` and `entries()`.
 *
 * Any name is a key, `__proto__` included, on every target. A key named
 * like a member (`exists`, `get`, `delete`, `clear`, `keys`, `values`,
 * `entries`, `toObject`, `keyValueIterator`) is read and written with
 * brackets, `fields["keys"]`, where `fields.keys` is the method.
 *
 * A field read with a dot is a `Null<T>`: a key not there reads null, which
 * as an `Int` is 0 natively, on the jvm and on HashLink, and null elsewhere
 * (one more than it is NaN on JavaScript and throws on eval and Neko), so
 * ask `fields.exists(name)` first where that matters. Add
 * to a field with `fields.count += 1`: `fields.count++` does not compile, as
 * Haxe has no increment through a field it reads and writes by name.
 */
@:generic
@:callable
abstract FieldStruct<T = Dynamic>(BaseStruct<T>) {
	public static inline function iterator<T>(instance:FieldStruct<T>):KeyValueIterator<String, T> {
		return (cast instance : BaseStruct<T>).keyValueIterator();
	}

	public inline function new() {
		this = new BaseStruct();
	}

	/** Whether there is a field `field`. **/
	public inline function exists(field:String):Bool {
		return (cast this : BaseStruct<T>).exists(field);
	}

	/** The field `field`, or null when there is none. **/
	public inline function get(field:String):Null<T> {
		return (cast this : BaseStruct<T>).get(field);
	}

	/** Removes the field `field`, and says whether there was one. **/
	public inline function delete(field:String):Bool {
		return (cast this : BaseStruct<T>).remove(field);
	}

	/** Removes every field. **/
	public inline function clear():Void {
		(cast this : BaseStruct<T>).clear();
	}

	public inline function keys():Iterator<String> {
		return (cast this : BaseStruct<T>).keys();
	}

	public inline function values():Iterator<T> {
		return (cast this : BaseStruct<T>).iterator();
	}

	public inline function entries():KeyValueIterator<String, T> {
		return (cast this : BaseStruct<T>).keyValueIterator();
	}

	/** What `for (name => value in fields)` walks. **/
	public inline function keyValueIterator():KeyValueIterator<String, T> {
		return (cast this : BaseStruct<T>).keyValueIterator();
	}

	public inline function toObject():Object {
		var object:Object = new Object();
		for (entry in (cast this : BaseStruct<T>).keyValueIterator()) {
			object[entry.key] = entry.value;
		}
		return object;
	}

	@:op(a.b)
	private inline function __fieldRead(name:String):Null<T> {
		return this.get(name);
	}

	@:op(a.b)
	private inline function __fieldWrite(name:String, value:T):T {
		this.set(name, value);
		return value;
	}

	@:arrayAccess @:noCompletion public inline function __get(key:String):Null<T> {
		return this.get(key);
	}

	@:arrayAccess @:noCompletion public inline function __set(key:String, value:T):T {
		this.set(key, value);
		return value;
	}
}
