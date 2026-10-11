package crossbyte.ds._internal;

#if (cpp && !cppia && !macro)
/**
	Carries the C++ that `NativeMap` names, in this class's own header. Kept,
	so the header is generated whenever this module is compiled, which every
	user of `NativeMap` makes it, and so are the map methods the templates
	call, which nothing in Haxe calls directly.
**/
@:keep
@:noCompletion
@:headerCode('
// A map held by a generic class, called through its own class.
//
// In a @:generic class a Map<K, V> is reached through haxe.IMap, whose
// methods take and give Dynamic: a String key, or an Int key or value past
// hxcpp\'s cache of small ones, is boxed by every call. Each specialization
// knows the map\'s class, and so does the C++ these templates are expanded
// in, where the call goes to that class\'s own typed method. StringMap,
// IntMap, ObjectMap and EnumValueMap each have exists, get, set and remove.
namespace crossbyte_ds_map
{
	template<typename MAP_, typename KEY_>
	inline bool has(MAP_ &inMap, const KEY_ &inKey) { return inMap->exists(inKey); }

	template<typename MAP_, typename KEY_>
	inline ::Dynamic get(MAP_ &inMap, const KEY_ &inKey) { return inMap->get(inKey); }

	template<typename MAP_, typename KEY_, typename VALUE_>
	inline void set(MAP_ &inMap, const KEY_ &inKey, const VALUE_ &inValue) { inMap->set(inKey, inValue); }

	template<typename MAP_, typename KEY_>
	inline bool remove(MAP_ &inMap, const KEY_ &inKey) { return inMap->remove(inKey); }

	// The Int held for a key, 0 for none. Through the map\'s typed read where
	// it has one (StringMap, IntMap and ObjectMap keep Ints unboxed), and
	// through get otherwise: EnumValueMap keeps every value boxed already, so
	// reading one makes nothing.
	template<typename MAP_, typename KEY_>
	inline auto intAt(MAP_ &inMap, const KEY_ &inKey, int) -> decltype(inMap->get_int(inKey)) { return inMap->get_int(inKey); }

	template<typename MAP_, typename KEY_>
	inline int intAt(MAP_ &inMap, const KEY_ &inKey, long)
	{
		::Dynamic held = inMap->get(inKey);
		return held.mPtr ? (int)held : 0;
	}

	// The 0 is an int, which prefers the typed read where it compiles.
	template<typename MAP_, typename KEY_>
	inline int intOf(MAP_ &inMap, const KEY_ &inKey) { return intAt(inMap, inKey, 0); }
}
')
class NativeMapCode {
	// Never run: what it names is what dead-code elimination keeps.
	private static function __keepCalled():Void {
		var strings = new haxe.ds.StringMap<Dynamic>();
		strings.set("", strings.get(""));
		strings.exists("") && strings.remove("");
		var ints = new haxe.ds.IntMap<Dynamic>();
		ints.set(0, ints.get(0));
		ints.exists(0) && ints.remove(0);
		var objects = new haxe.ds.ObjectMap<{}, Dynamic>();
		objects.set(strings, objects.get(strings));
		objects.exists(strings) && objects.remove(strings);
		var enums = new haxe.ds.EnumValueMap<EnumValue, Dynamic>();
		enums.set(haxe.io.Error.Blocked, enums.get(haxe.io.Error.Blocked));
		enums.exists(haxe.io.Error.Blocked) && enums.remove(haxe.io.Error.Blocked);
	}
}

/**
	A `Map` field of a `@:generic` class, called through the map's own class
	rather than `haxe.IMap`, so no key or value is boxed for the call. Pass
	the field itself: its type in each specialization is what picks the
	method.
**/
@:include("crossbyte/ds/_internal/NativeMapCode.h")
@:noCompletion
extern class NativeMap {
	@:native("::crossbyte_ds_map::has")
	static function has<M, K>(map:M, key:K):Bool;

	@:native("::crossbyte_ds_map::get")
	static function get<M, K>(map:M, key:K):Dynamic;

	@:native("::crossbyte_ds_map::set")
	static function set<M, K, V>(map:M, key:K, value:V):Void;

	@:native("::crossbyte_ds_map::remove")
	static function remove<M, K>(map:M, key:K):Bool;

	/** The Int held for `key`, or 0 when there is none: store the value plus one to tell them apart. **/
	@:native("::crossbyte_ds_map::intOf")
	static function intOf<M, K>(map:M, key:K):Int;
}
#end
