package crossbyte;

import haxe.ds.StringMap;

@:noCompletion
private typedef BaseStruct<T = Dynamic> = StringMap<T>;

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
