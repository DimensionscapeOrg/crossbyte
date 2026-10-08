package crossbyte.db.mongodb._internal;

import crossbyte.db.mongodb.bson.BsonBinary;
import crossbyte.db.mongodb.bson.BsonDateTime;
import crossbyte.db.mongodb.bson.BsonDocument;
import crossbyte.db.mongodb.bson.BsonInt64;
import crossbyte.db.mongodb.bson.BsonJavaScript;
import crossbyte.db.mongodb.bson.BsonRegex;
import crossbyte.db.mongodb.bson.BsonTimestamp;
import crossbyte.db.mongodb.bson.Decimal128;
import crossbyte.db.mongodb.bson.MaxKey;
import crossbyte.db.mongodb.bson.MinKey;
import crossbyte.db.mongodb.bson.ObjectId;
import crossbyte.errors.IOError;
#if cpp
import crossbyte._internal.AnonBuilder;
#end
import haxe.Int64;
import haxe.ds.Vector;
import haxe.io.Bytes;

/**
	Decodes BSON from bytes, checking every length it reads against the bytes
	that are actually there, so a malformed or hostile document is refused
	rather than read past its end.

	Documents become anonymous objects, or `BsonDocument`s with `ordered`.
	A field name is interned: a result set's documents almost always share
	their names, and a small table of those already made (checked against
	the bytes before it is trusted) spares a string per field per document.
	On hxcpp a document of a shape met before is made with fixed slots, as
	an object literal is; see `__shapedDocument`.
**/
class BsonReader {
	public static inline var MAX_DEPTH:Int = 200;

	/** Dates as `BsonDateTime` rather than `Date`, which is lossy on hl and neko. **/
	public var exactDates:Bool = false;

	/** Documents as `BsonDocument`, keeping their order, rather than anonymous objects. **/
	public var ordered:Bool = false;

	/**
		int64 values as `BsonInt64` rather than `haxe.Int64`, so their type
		survives being written back even on hxcpp, which boxes a small Int64
		as an `Int`.
	**/
	public var wrapInt64:Bool = false;

	@:noCompletion private var __bytes:Bytes;
	@:noCompletion private var __pos:Int = 0;
	@:noCompletion private var __names:Vector<String>;

	public function new() {}

	/**
		Decodes the document at `position`, which must end at or before `limit`.
		Answers the document; `position` after it is `end`.

		@throws IOError When the bytes are not a well-formed document.
	**/
	public function readDocument(bytes:Bytes, position:Int, limit:Int):Dynamic {
		__bytes = bytes;
		__pos = position;
		var document:Dynamic;

		try {
			document = __document(limit, 0, false);
		} catch (e:IOError) {
			__bytes = null;
			throw e;
		} catch (e:Dynamic) {
			// Whatever a target's string decoding throws at bytes that are not
			// UTF-8 (a RangeError on JavaScript) is the same malformed input, and
			// reads as it. One handler per document, not per string.
			__bytes = null;
			throw new IOError("Malformed BSON: " + Std.string(e));
		}

		__bytes = null;
		return document;
	}

	/** Where the last `readDocument` stopped. **/
	public var end(get, never):Int;

	private inline function get_end():Int {
		return __pos;
	}

	@:noCompletion private function __document(limit:Int, depth:Int, asArray:Bool):Dynamic {
		if (depth > MAX_DEPTH) {
			__fail('documents nest more than $MAX_DEPTH levels deep');
		}

		var bytes:Bytes = __bytes;
		var start:Int = __pos;

		if (start < 0 || start + 5 > limit) {
			__fail("a document runs past the end of its container");
		}

		var size:Int = bytes.getInt32(start);

		if (size < 5 || size > limit - start) {
			__fail('a document claims $size bytes where ${limit - start} remain');
		}

		var end:Int = start + size;

		if (bytes.get(end - 1) != 0) {
			__fail("a document does not end with a NUL");
		}

		#if cpp
		if (!asArray && !this.ordered && depth < SHAPED_DEPTHS) {
			return __shapedDocument(start, end, depth);
		}
		#end

		var array:Array<Dynamic> = null;
		var object:Dynamic = null;
		var ordered:BsonDocument = null;

		if (asArray) {
			array = ValueArray.create();
		} else if (this.ordered) {
			ordered = new BsonDocument();
		} else {
			object = {};
		}

		__pos = start + 4;
		var last:Int = end - 1;

		while (__pos < last) {
			var type:Int = bytes.get(__pos++);
			var nameStart:Int = __pos;
			var nameEnd:Int = __cstringEnd(last);
			var name:String = asArray ? null : __name(nameStart, nameEnd);
			__pos = nameEnd + 1;
			var value:Dynamic = __value(type, end, depth);

			if (asArray) {
				array.push(value);
			} else if (ordered != null) {
				ordered.add(name, value);
			} else {
				__setField(object, name, value);
			}
		}

		if (__pos != last) {
			__fail("a field runs into the end of its document");
		}

		__pos = end;
		return asArray ? array : (ordered != null ? ordered : object);
	}

	#if cpp
	/** How deep documents are made with fixed slots; deeper ones use the hash map. **/
	@:noCompletion private static inline var SHAPED_DEPTHS:Int = 16;

	/** The most fields a document made with fixed slots has. **/
	@:noCompletion private static inline var SHAPED_FIELDS:Int = 64;

	/**
		The longest field name, in bytes, a document made with fixed slots
		has: the length the name table interns to. A slot's name is kept for
		good, so this bounds what names from the server can pin.
	**/
	@:noCompletion private static inline var SHAPED_NAME:Int = 32;

	/** How many shapes each depth keeps, the most recently used first. **/
	@:noCompletion private static inline var SHAPES_PER_DEPTH:Int = 4;

	@:noCompletion private var __levels:Array<BsonLevel>;

	/**
		A plain document, made the way hxcpp makes an object literal: its
		fields in fixed slots, found by a binary search, rather than in a hash
		map allocated beside it and searched by hash: reading a field of one
		costs a third to a half less. The fields are read first, and the
		document is made once their names are known.

		The slot order is worked out once per shape (a list of names) and
		kept per depth: a reply's envelope, a batch's documents and their
		sub-documents each find theirs at the head of their depth's list. A
		shape is kept only once it has been met twice running at its depth,
		so documents of ever-new shapes, as a hostile server could send, cost
		a comparison of names each, never a new shape each; and only shapes
		of at most SHAPED_FIELDS names of at most SHAPED_NAME bytes, whose
		names AnonBuilder keeps for good. Anything else uses the hash map.
	**/
	@:noCompletion private function __shapedDocument(start:Int, end:Int, depth:Int):Dynamic {
		var bytes:Bytes = __bytes;

		if (__levels == null) {
			__levels = [];
		}

		while (__levels.length <= depth) {
			__levels.push(new BsonLevel());
		}

		var level:BsonLevel = __levels[depth];
		var names:Array<String> = level.names;
		var values:Array<Dynamic> = level.values;
		var count:Int = 0;
		var fits:Bool = true;
		__pos = start + 4;
		var last:Int = end - 1;

		while (__pos < last) {
			var type:Int = bytes.get(__pos++);
			var nameStart:Int = __pos;
			var nameEnd:Int = __cstringEnd(last);

			if (nameEnd - nameStart > SHAPED_NAME) {
				fits = false;
			}

			names[count] = __name(nameStart, nameEnd);
			__pos = nameEnd + 1;
			values[count] = __value(type, end, depth);
			count++;
		}

		if (__pos != last) {
			__fail("a field runs into the end of its document");
		}

		__pos = end;

		if (fits && count > 0 && count <= SHAPED_FIELDS) {
			var shape:AnonBuilder = level.find(names, count);

			if (shape != null) {
				var object:Dynamic = shape.begin();

				for (i in 0...count) {
					shape.set(object, i, values[i]);
					// Not kept here past the document, where a large value
					// would stay reachable from an idle connection.
					values[i] = null;
				}

				return object;
			}
		}

		var object:Dynamic = {};

		for (i in 0...count) {
			Reflect.setField(object, names[i], values[i]);
			values[i] = null;
		}

		return object;
	}
	#end

	@:noCompletion private function __value(type:Int, end:Int, depth:Int):Dynamic {
		var bytes:Bytes = __bytes;

		switch (type) {
			case 0x01:
				__need(8, end);
				var value:Float = bytes.getDouble(__pos);
				__pos += 8;
				return value;
			case 0x02:
				return __string(end);
			case 0x03:
				return __document(end, depth + 1, false);
			case 0x04:
				return __document(end, depth + 1, true);
			case 0x05:
				__need(5, end);
				var size:Int = bytes.getInt32(__pos);
				var subtype:Int = bytes.get(__pos + 4);

				if (size < 0 || size > end - __pos - 5) {
					__fail('binary data claims $size bytes where ${end - __pos - 5} remain');
				}

				var at:Int = __pos + 5;
				__pos = at + size;

				if (subtype == BsonBinary.GENERIC) {
					return bytes.sub(at, size);
				}

				if (subtype == BsonBinary.BINARY_OLD) {
					if (size < 4 || bytes.getInt32(at) != size - 4) {
						__fail("old-style binary data whose inner length does not match");
					}

					return new BsonBinary(subtype, bytes.sub(at + 4, size - 4));
				}

				return new BsonBinary(subtype, bytes.sub(at, size));
			case 0x06 | 0x0A:
				// Undefined, deprecated, reads as null like null itself.
				return null;
			case 0x07:
				__need(12, end);
				var id:ObjectId = new ObjectId(bytes.sub(__pos, 12));
				__pos += 12;
				return id;
			case 0x08:
				__need(1, end);
				return bytes.get(__pos++) != 0;
			case 0x09:
				__need(8, end);
				var millis:Int64 = Int64.make(bytes.getInt32(__pos + 4), bytes.getInt32(__pos));
				__pos += 8;
				return exactDates ? new BsonDateTime(millis) : Date.fromTime(crossbyte.db.mongodb._internal.Int64Float.toFloat(millis));
			case 0x0B:
				var patternEnd:Int = __cstringEnd(end);
				var pattern:String = __text(bytes, __pos, patternEnd - __pos);
				__pos = patternEnd + 1;
				var optionsEnd:Int = __cstringEnd(end);
				var options:String = __text(bytes, __pos, optionsEnd - __pos);
				__pos = optionsEnd + 1;
				return new BsonRegex(pattern, options);
			case 0x0C:
				// A DBPointer, deprecated: read as the DBRef it has become.
				var namespace:String = __string(end);
				__need(12, end);
				var pointer:Dynamic = {};
				Reflect.setField(pointer, "$ref", namespace);
				Reflect.setField(pointer, "$id", new ObjectId(bytes.sub(__pos, 12)));
				__pos += 12;
				return pointer;
			case 0x0D:
				return new BsonJavaScript(__string(end));
			case 0x0E:
				// A symbol, deprecated: its text.
				return __string(end);
			case 0x0F:
				__need(4, end);
				var total:Int = bytes.getInt32(__pos);
				var codeEnd:Int = __pos + total;

				if (total < 14 || total > end - __pos) {
					__fail("code with scope claims more bytes than its document has");
				}

				__pos += 4;
				var code:String = __string(codeEnd);
				var scope:Dynamic = __document(codeEnd, depth + 1, false);

				if (__pos != codeEnd) {
					__fail("code with scope whose parts do not add up to its length");
				}

				return new BsonJavaScript(code, scope);
			case 0x10:
				__need(4, end);
				var value:Int = bytes.getInt32(__pos);
				__pos += 4;
				return value;
			case 0x11:
				__need(8, end);
				var timestamp:BsonTimestamp = new BsonTimestamp(bytes.getInt32(__pos + 4), bytes.getInt32(__pos));
				__pos += 8;
				return timestamp;
			case 0x12:
				__need(8, end);
				var value:Int64 = Int64.make(bytes.getInt32(__pos + 4), bytes.getInt32(__pos));
				__pos += 8;

				if (wrapInt64) {
					return new BsonInt64(value);
				}

				return value;
			case 0x13:
				__need(16, end);
				var decimal:Decimal128 = new Decimal128(bytes.sub(__pos, 16));
				__pos += 16;
				return decimal;
			case 0xFF:
				return MinKey.VALUE;
			case 0x7F:
				return MaxKey.VALUE;
			default:
				__fail('unknown BSON type 0x${StringTools.hex(type, 2)}');
				return null;
		}
	}

	@:noCompletion private function __string(end:Int):String {
		__need(4, end);
		var bytes:Bytes = __bytes;
		var size:Int = bytes.getInt32(__pos);

		if (size < 1 || size > end - __pos - 4) {
			__fail('a string claims $size bytes where ${end - __pos - 4} remain');
		}

		var at:Int = __pos + 4;

		if (bytes.get(at + size - 1) != 0) {
			__fail("a string does not end with a NUL");
		}

		__pos = at + size;
		return size == 1 ? "" : __text(bytes, at, size - 1);
	}

	/** Where the C string starting at the current position ends: its NUL. **/
	@:noCompletion private inline function __cstringEnd(limit:Int):Int {
		var bytes:Bytes = __bytes;
		var at:Int = __pos;

		while (at < limit && bytes.get(at) != 0) {
			at++;
		}

		if (at >= limit) {
			__fail("a name or pattern is not terminated inside its document");
		}

		return at;
	}

	/**
		The field name in `[start, end)`, from the table of names already made
		when the bytes match one there. Only ASCII names are kept, which is
		what lets the comparison go character by character against bytes.
	**/
	@:noCompletion private function __name(start:Int, end:Int):String {
		var size:Int = end - start;

		if (size == 0) {
			return "";
		}

		var bytes:Bytes = __bytes;

		if (size <= 32) {
			var hash:Int = size;
			var ascii:Bool = true;

			for (i in start...end) {
				var b:Int = bytes.get(i);

				if (b >= 0x80) {
					ascii = false;
					break;
				}

				// Masked to 31 bits every step, so it stays small and exact
				// whatever an Int is: a double on JavaScript, 64 bits on php.
				hash = (hash * 31 + b) & 0x7FFFFFFF;
			}

			if (ascii) {
				if (__names == null) {
					__names = new Vector<String>(256);
				}

				var slot:Int = hash & 255;
				var known:String = __names[slot];

				if (known != null && known.length == size) {
					var same:Bool = true;

					for (i in 0...size) {
						if (StringTools.fastCodeAt(known, i) != bytes.get(start + i)) {
							same = false;
							break;
						}
					}

					if (same) {
						return known;
					}
				}

				var made:String = __text(bytes, start, size);
				__names[slot] = made;
				return made;
			}
		}

		return __text(bytes, start, size);
	}

	/**
		UTF-8 bytes as a string. `Bytes.getString` stops at the first NUL on
		JavaScript and on hl, and a BSON string may hold one: "a\0b" read back
		as "a". So on JavaScript through `TextDecoder`, which also does not
		throw a RangeError at bytes that are not UTF-8 as Haxe's decoding
		does; on hl by hand, when there is a NUL to get past.
	**/
	@:noCompletion private static inline function __text(bytes:Bytes, at:Int, length:Int):String {
		#if js
		return __decoder().decode((@:privateAccess bytes.b).subarray(at, at + length));
		#elseif hl
		return __hasNul(bytes, at, length) ? __decodeUtf8(bytes, at, length) : bytes.getString(at, length);
		#else
		return bytes.getString(at, length);
		#end
	}

	#if hl
	@:noCompletion private static function __hasNul(bytes:Bytes, at:Int, length:Int):Bool {
		for (i in at...at + length) {
			if (bytes.get(i) == 0) {
				return true;
			}
		}

		return false;
	}

	@:noCompletion private static function __decodeUtf8(bytes:Bytes, at:Int, length:Int):String {
		var out:StringBuf = new StringBuf();
		var i:Int = at;
		var end:Int = at + length;

		while (i < end) {
			var c:Int = bytes.get(i++);

			if (c < 0x80) {
				out.addChar(c);
			} else if (c >= 0xC2 && c < 0xE0 && i < end) {
				out.addChar(((c & 0x1F) << 6) | (bytes.get(i++) & 0x3F));
			} else if (c >= 0xE0 && c < 0xF0 && i + 1 < end) {
				out.addChar(((c & 0x0F) << 12) | ((bytes.get(i) & 0x3F) << 6) | (bytes.get(i + 1) & 0x3F));
				i += 2;
			} else if (c >= 0xF0 && c < 0xF5 && i + 2 < end) {
				out.addChar(((c & 0x07) << 18) | ((bytes.get(i) & 0x3F) << 12) | ((bytes.get(i + 1) & 0x3F) << 6) | (bytes.get(i + 2) & 0x3F));
				i += 3;
			} else {
				out.addChar(0xFFFD);
			}
		}

		return out.toString();
	}
	#end

	#if js
	@:noCompletion private static var __textDecoder:Dynamic;

	@:noCompletion private static function __decoder():Dynamic {
		if (__textDecoder == null) {
			__textDecoder = js.Syntax.code("new TextDecoder('utf-8')");
		}

		return __textDecoder;
	}
	#end

	@:noCompletion private static inline function __setField(object:Dynamic, name:String, value:Dynamic):Void {
		#if js
		if (name == "__proto__") {
			// Assigning it would replace the object's prototype rather than
			// add a field, which is how a document from a peer reshapes what
			// every lookup on the object finds.
			js.lib.Object.defineProperty(object, name, {
				value: value,
				enumerable: true,
				writable: true,
				configurable: true
			});
			return;
		}
		#end
		Reflect.setField(object, name, value);
	}

	@:noCompletion private inline function __need(count:Int, end:Int):Void {
		if (__pos + count > end) {
			__fail('a value needs $count bytes where ${end - __pos} remain');
		}
	}

	@:noCompletion private static function __fail(reason:String):Void {
		throw new IOError("Malformed BSON: " + reason + ".");
	}
}

#if cpp
/**
	What a `BsonReader` keeps for one depth of plain documents: room for the
	fields of the one being read, and the shapes met there.
**/
@:noCompletion
private class BsonLevel {
	@:noCompletion private static inline var SHAPES:Int = 4;

	/** The names and values of the document being read at this depth. **/
	public var names:Array<String> = [];

	// Not a literal []: on hxcpp that widens as values arrive, and would
	// turn an Int64 into a double beside a Float.
	public var values:Array<Dynamic> = ValueArray.create();

	// The shapes met here, the most recently used first.
	@:noCompletion private var __shapes:Array<AnonBuilder> = [];

	// The names of the last document no shape fitted, and how many.
	@:noCompletion private var __missed:Array<String> = [];
	@:noCompletion private var __missedCount:Int = -1;

	public function new() {}

	/**
		The shape of the first `count` of `names`: one kept, or one made now
		that the same names have come twice running; otherwise null, and the
		names are remembered for next time.
	**/
	public function find(names:Array<String>, count:Int):AnonBuilder {
		var shapes:Array<AnonBuilder> = __shapes;

		for (i in 0...shapes.length) {
			var shape:AnonBuilder = shapes[i];

			if (shape.matches(names, count)) {
				__toFront(shape, i);
				return shape;
			}
		}

		if (__missedCount == count) {
			var same:Bool = true;

			for (k in 0...count) {
				if (__missed[k] != names[k]) {
					same = false;
					break;
				}
			}

			if (same) {
				var shape:AnonBuilder = new AnonBuilder(names.slice(0, count));
				// The least recently used drops off the end.
				__toFront(shape, shapes.length < SHAPES ? shapes.push(shape) - 1 : SHAPES - 1);
				__missedCount = -1;
				return shape;
			}
		}

		for (k in 0...count) {
			__missed[k] = names[k];
		}

		__missedCount = count;
		return null;
	}

	/** Moves `shape`, now at `at`, to the front, the ones before it back one. **/
	@:noCompletion private inline function __toFront(shape:AnonBuilder, at:Int):Void {
		var shapes:Array<AnonBuilder> = __shapes;

		while (at > 0) {
			shapes[at] = shapes[at - 1];
			at--;
		}

		shapes[0] = shape;
	}
}
#end
