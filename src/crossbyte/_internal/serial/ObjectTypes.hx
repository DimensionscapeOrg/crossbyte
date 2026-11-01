package crossbyte._internal.serial;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;

/**
	The classes and enums an HXSF read may make: none, unless the program
	allows them (`ByteArray.allowObjectClass` and `allowObjectEnum`).

	`haxe.Unserializer` resolves every class and enum a payload names, any
	compiled into the program, and makes an instance without its
	constructor, its fields set to whatever the payload says. A peer's
	object could then make one of a class whose methods trust what its
	constructor checked: natively, one reading memory by its own lengths.
	So a name not allowed is refused, before anything is made of it.
**/
@:noCompletion
class ObjectTypes {
	/** What `BoundedUnserializer` resolves through. **/
	public static final resolver:ObjectTypes = new ObjectTypes();

	// Replaced whole on every change, never changed in place: a read on
	// another thread holds the map it started with, never one half written.
	static var __classes:Map<String, Class<Dynamic>> = new Map();
	static var __enums:Map<String, Enum<Dynamic>> = new Map();

	public static function allowClass(type:Class<Dynamic>):Void {
		if (type == null) {
			throw new ArgumentError("A class to allow cannot be null.");
		}
		var next:Map<String, Class<Dynamic>> = __classes.copy();
		next.set(Type.getClassName(type), type);
		__classes = next;
	}

	public static function allowEnum(type:Enum<Dynamic>):Void {
		if (type == null) {
			throw new ArgumentError("An enum to allow cannot be null.");
		}
		var next:Map<String, Enum<Dynamic>> = __enums.copy();
		next.set(Type.getEnumName(type), type);
		__enums = next;
	}

	function new() {}

	public function resolveClass(name:String):Class<Dynamic> {
		var found:Null<Class<Dynamic>> = __classes.get(name);
		if (found == null) {
			throw new IOError('names class $name, which ByteArray.allowObjectClass has not allowed');
		}
		return found;
	}

	public function resolveEnum(name:String):Enum<Dynamic> {
		var found:Null<Enum<Dynamic>> = __enums.get(name);
		if (found == null) {
			throw new IOError('names enum $name, which ByteArray.allowObjectEnum has not allowed');
		}
		return found;
	}
}
