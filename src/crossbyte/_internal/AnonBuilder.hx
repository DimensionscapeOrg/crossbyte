package crossbyte._internal;

#if cpp
import sys.thread.Mutex;
#end

/**
	Builds anonymous objects of one shape -- one list of field names -- the
	way hxcpp builds an object literal.

	On hxcpp a literal such as `{a: 1, b: 2}` keeps its fields in fixed slots,
	ordered by the hash of their names and found by a binary search; an
	object made as `{}` and filled with `Reflect.setField` keeps every field
	in a hash map instead, allocated beside it, and every read is a lookup
	there. Rows and documents decoded from the wire were all of the second
	kind. Made here they are of the first: the slot order is worked out once
	for the shape, and each object then costs one allocation, and each field
	one store. Reading a field of one costs 38-51% less, and building and
	reading a row of 8 a quarter to a third less (the audit's SqlitePerf).

	Elsewhere it is `{}` and `Reflect.setField`: the jvm, JavaScript, hl,
	neko and eval have no such distinction to exploit.

	Use: make one builder per shape and keep it (per statement, per decoded
	document layout); for each object, `begin()`, then set **every** field
	once, by its index in `names`, then use the object. A field left unset
	on hxcpp holds `null` under an empty name, and the object's lookups are
	then unreliable. Fields added later with `Reflect.setField` or by
	assignment go to the object's hash map as usual.

	The shape falls back to `Reflect.setField` on hxcpp too when its names
	repeat (the last value wins, as before), when one is not ASCII (hxcpp
	looks fixed slots up by ASCII name only), when one is longer than
	`MAX_NAME_LENGTH`, or when the process has already made `MAX_NAMES`
	distinct names, or `MAX_NAME_CHARACTERS` characters of them, permanent:
	an object holds its field names without marking them for the collector,
	so a name in a fixed slot must never be collected, and names read from a
	peer would otherwise grow that set without bound.
**/
@:noCompletion
class AnonBuilder {
	/**
		How many distinct field names fixed-slot shapes may make permanent in
		one process, across every builder. Past it a new shape uses the hash
		map; shapes already made keep their slots.
	**/
	public static inline var MAX_NAMES:Int = 16384;

	/** The longest name a fixed slot takes, in characters. **/
	public static inline var MAX_NAME_LENGTH:Int = 128;

	/** How many characters of names, across every builder, may be made permanent. **/
	public static inline var MAX_NAME_CHARACTERS:Int = 1048576;

	/** The field names, in the order the setters index them. **/
	public var names(default, null):Array<String>;

	/** How many fields an object of this shape has. **/
	public var length(default, null):Int;

	/** Whether objects are built with fixed slots (hxcpp only). **/
	public var fixed(default, null):Bool = false;

	#if cpp
	// The slot each field goes in, by its index in `names`.
	@:noCompletion private var __slot:Array<Int>;
	// The names as the slots hold them: permanent, never collected.
	@:noCompletion private var __keys:Array<String>;

	@:noCompletion private static var __permanent:Map<String, Bool> = new Map();
	@:noCompletion private static var __permanentCount:Int = 0;
	@:noCompletion private static var __permanentCharacters:Int = 0;
	@:noCompletion private static final __lock:Mutex = new Mutex();
	#end

	public function new(names:Array<String>) {
		this.names = names.copy();
		length = names.length;
		#if cpp
		fixed = __fixSlots();
		#end
	}

	/**
		Whether this builder's shape is `count` names of `candidates`, from
		the first: how a decoder that meets field names one at a time finds
		out that a document has the layout it built a shape for before.
	**/
	public function matches(candidates:Array<String>, count:Int):Bool {
		if (count != length) {
			return false;
		}

		for (i in 0...count) {
			if (names[i] != candidates[i]) {
				return false;
			}
		}

		return true;
	}

	/** A new object of this shape, its fields to be set before it is used. **/
	public inline function begin():Dynamic {
		#if cpp
		return fixed ? untyped __cpp__("::hx::Anon_obj::Create({0})", length) : {};
		#else
		return {};
		#end
	}

	/** Sets field `field` (its index in `names`) of `object`, made by `begin()`. **/
	public inline function set(object:Dynamic, field:Int, value:Dynamic):Void {
		#if cpp
		if (fixed) {
			untyped __cpp__("((::hx::Anon_obj *)({0}.mPtr))->setFixed({1}, {2}, ::cpp::Variant({3}))", object, __slot[field], __keys[field], value);
		} else {
			Reflect.setField(object, names[field], value);
		}
		#else
		Reflect.setField(object, names[field], value);
		#end
	}

	/** `set` for an `Int`, held unboxed in its slot on hxcpp. **/
	public inline function setInt(object:Dynamic, field:Int, value:Int):Void {
		#if cpp
		if (fixed) {
			untyped __cpp__("((::hx::Anon_obj *)({0}.mPtr))->setFixed({1}, {2}, ::cpp::Variant((int){3}))", object, __slot[field], __keys[field], value);
		} else {
			Reflect.setField(object, names[field], value);
		}
		#else
		Reflect.setField(object, names[field], value);
		#end
	}

	/** `set` for a `Float`, held unboxed in its slot on hxcpp. **/
	public inline function setFloat(object:Dynamic, field:Int, value:Float):Void {
		#if cpp
		if (fixed) {
			untyped __cpp__("((::hx::Anon_obj *)({0}.mPtr))->setFixed({1}, {2}, ::cpp::Variant((double){3}))", object, __slot[field], __keys[field], value);
		} else {
			Reflect.setField(object, names[field], value);
		}
		#else
		Reflect.setField(object, names[field], value);
		#end
	}

	/** `set` for a `Bool`, held unboxed in its slot on hxcpp. **/
	public inline function setBool(object:Dynamic, field:Int, value:Bool):Void {
		#if cpp
		if (fixed) {
			untyped __cpp__("((::hx::Anon_obj *)({0}.mPtr))->setFixed({1}, {2}, ::cpp::Variant((bool){3}))", object, __slot[field], __keys[field], value);
		} else {
			Reflect.setField(object, names[field], value);
		}
		#else
		Reflect.setField(object, names[field], value);
		#end
	}

	/** `set` for a `String`, held without a box in its slot on hxcpp. **/
	public inline function setString(object:Dynamic, field:Int, value:String):Void {
		#if cpp
		if (fixed) {
			untyped __cpp__("((::hx::Anon_obj *)({0}.mPtr))->setFixed({1}, {2}, ::cpp::Variant({3}))", object, __slot[field], __keys[field], value);
		} else {
			Reflect.setField(object, names[field], value);
		}
		#else
		Reflect.setField(object, names[field], value);
		#end
	}

	/**
		The builder for `names` in `shapes`, the recent shapes a decoder has
		met, most recent last: one made before for the same names, or a new
		one, kept in place of the oldest when `shapes` holds `keep` already.
	**/
	public static function recent(shapes:Array<AnonBuilder>, names:Array<String>, keep:Int = 8):AnonBuilder {
		var count:Int = names.length;
		var i:Int = shapes.length;

		while (--i >= 0) {
			var shape:AnonBuilder = shapes[i];

			if (shape.matches(names, count)) {
				return shape;
			}
		}

		var made:AnonBuilder = new AnonBuilder(names);

		if (shapes.length >= keep) {
			shapes.shift();
		}

		shapes.push(made);
		return made;
	}

	#if cpp
	/**
		Works out the slots, in the order hxcpp's lookups expect: by the hash
		of each name, compared as a signed `int` as `Anon_obj` compares them.
		`String::hash()` answers unsigned, and ordered that way the binary
		search past the first five fields misses names whose hash has its top
		bit set: those fields read as absent.
	**/
	@:noCompletion private function __fixSlots():Bool {
		if (length == 0) {
			return false;
		}

		for (i in 0...length) {
			var name:String = names[i];

			if (name == null || name.length > MAX_NAME_LENGTH || !(untyped __cpp__("{0}.isAsciiEncoded()", name) : Bool)) {
				return false;
			}

			for (j in 0...i) {
				if (names[j] == name) {
					return false;
				}
			}
		}

		var keys:Array<String> = [];
		__lock.acquire();

		try {
			var fresh:Int = 0;
			var characters:Int = 0;

			for (name in names) {
				if (!__permanent.exists(name)) {
					fresh++;
					characters += name.length;
				}
			}

			if (__permanentCount + fresh > MAX_NAMES || __permanentCharacters + characters > MAX_NAME_CHARACTERS) {
				__lock.release();
				return false;
			}

			for (name in names) {
				if (!__permanent.exists(name)) {
					__permanent.set(name, true);
					__permanentCount++;
					__permanentCharacters += name.length;
				}

				keys.push(untyped __cpp__("{0}.makePermanent()", name));
			}
		} catch (e:Dynamic) {
			__lock.release();
			throw e;
		}

		__lock.release();

		var order:Array<Int> = [for (i in 0...length) i];
		var hashes:Array<Int> = [for (key in keys) (untyped __cpp__("(int){0}.hash()", key) : Int)];
		order.sort((a, b) -> hashes[a] < hashes[b] ? -1 : (hashes[a] > hashes[b] ? 1 : a - b));
		__slot = [for (_ in 0...length) 0];

		for (k in 0...length) {
			__slot[order[k]] = k;
		}

		__keys = keys;
		return true;
	}
	#end
}
