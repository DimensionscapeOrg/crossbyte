package crossbyte.db.mongodb._internal;

/**
	An `Array<Dynamic>` whose elements keep the types they were given.

	On hxcpp an `Array<Dynamic>` made with `[]` picks its storage from what is
	put in it and widens as it goes: an Int64 and then a Float, in either
	order, and every Int64 in it is converted to a double. A BSON array
	holding `NumberLong(9007199254740993)` and `1.5` would come back holding
	9007199254740992, and a document's fields, kept in one, the same. This
	makes one over a plain array of objects, which stays as it is. Elsewhere
	an array literal already behaves that way.
**/
class ValueArray {
	public static inline function create():Array<Dynamic> {
		#if cpp
		return untyped __cpp__("::cpp::VirtualArray(::Array_obj< ::Dynamic >::__new(0,0))");
		#else
		return [];
		#end
	}
}
