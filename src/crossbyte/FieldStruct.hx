package crossbyte;

import haxe.ds.StringMap;

@:noCompletion
private typedef BaseStruct<T = Dynamic> = StringMap<T>;

/**
 * A typed dynamic field bag backed by `StringMap`.
 *
 * `FieldStruct<T>` gives CrossByte a compact way to model dynamic, string-keyed
 * records while still constraining the value lane to `T`. It supports dot access,
 * bracket access, and iteration over keys or key/value pairs.
 */
@:generic
@:callable
abstract FieldStruct<T = Dynamic>(BaseStruct<T>) {
	public static inline function clear<T>(instance:FieldStruct<T>):Void {
		(cast instance : BaseStruct<T>).clear();
	}

	public static inline function delete<T>(instance:FieldStruct<T>, field:String):Void {
		(cast instance : BaseStruct<T>).remove(field);
	}

	public static inline function get<T>(instance:FieldStruct<T>, field:String):Null<T> {
		return (cast instance : BaseStruct<T>).get(field);
	}

	public static inline function exists<T>(instance:FieldStruct<T>, field:String):Bool {
		return (cast instance : BaseStruct<T>).exists(field);
	}

	public static inline function iterator<T>(instance:FieldStruct<T>):KeyValueIterator<String, T> {
		return (cast instance : BaseStruct<T>).keyValueIterator();
	}

	public inline function new() {
		this = new BaseStruct();
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
